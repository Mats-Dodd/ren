(* Exhaustiveness: every `match` handles every case, and has no arm that
   can never match. It runs after type inference (infer.ml), because which
   type a pattern's constructor belongs to is found through the type of the
   value being matched, so it's only known once inference has found it.
   Inference records the constructor each pattern became, and this pass
   reads it (module-build.md, "In the compiler").

   Each problem is reported to the sink (diag.ml), and checking carries on
   with the next `match`. *)

open Ast
open Ast.Resolved

let sprintf = Printf.sprintf

type env = {
  types : (Path.t, Iface.type_decl) Hashtbl.t;
      (** every type the module can see, by path *)
  nodes : Infer.node Infer.Nodes.t;  (** what inference found in the function *)
  home : string;
  sink : Diag.sink;
}

(* ---- exhaustiveness ----

   Maranget's algorithm ("Warnings for pattern matching", 2007), the one
   OCaml and Rust use. Patterns are simplified to two shapes: [Any] (a
   wildcard or variable) and [Ctor] (a constructor with sub-patterns).
   Literals are constructors too: `true`/`false` of a two-constructor type,
   and each Int a constructor of a type with infinitely many.

   The rows of the match form a matrix, one pattern list per row. The key
   question, [useful rows q], asks: is there a value that [q] matches but no
   row does? An arm that isn't useful against the arms above it can never
   match. A match is exhaustive when a wildcard row wouldn't be useful. *)

(* A constructor of a pattern: its name, and the type it belongs to.
   [None] for an Int, which isn't one of a list of constructors. *)
type head = { name : string; owner : Path.t option }
type space = Any | Ctor of head * space list

let bool_path = Path.prelude "Bool"

let rec simplify env (p : pattern) =
  match p.pkind with
  | PWild | PVar _ -> Any
  | PInt n -> Ctor ({ name = string_of_int n; owner = None }, [])
  | PBool b -> Ctor ({ name = string_of_bool b; owner = Some bool_path }, [])
  | PCon (c, ps) ->
      let owner =
        match (Infer.Nodes.find p.pnode env.nodes).found with
        | Some (Ctor_of (path, _)) -> path
        | _ -> assert false (* inference found it, or reported an error *)
      in
      Ctor ({ name = c.name; owner = Some owner }, List.map (simplify env) ps)

let rec show_space = function
  | Any -> "_"
  | Ctor (c, []) -> c.name
  | Ctor (c, args) ->
      c.name ^ "(" ^ String.concat ", " (List.map show_space args) ^ ")"

let wilds n = List.init n (fun _ -> Any)

(* Every constructor of the type [c] belongs to, with its number of fields.
   [None] for Int, which has too many values to list. *)
let siblings env c =
  match c.owner with
  | Some p when p = bool_path ->
      let b name = { name; owner = Some bool_path } in
      Some [ (b "true", 0); (b "false", 0) ]
  | Some p -> (
      match Hashtbl.find env.types p with
      | { body = Sum cs; _ } ->
          Some
            (List.map
               (fun (k : Iface.ctor) ->
                 ({ name = k.cname; owner = Some p }, List.length k.cfields))
               cs)
      | _ -> None)
  | None -> None

(* The rows that still apply once we know the first value was built with
   constructor [c]: their first pattern is replaced by its [arity]
   sub-patterns, and rows starting with a different constructor drop out. *)
let specialize c arity rows =
  List.filter_map
    (function
      | Ctor (c', args) :: rest -> if c' = c then Some (args @ rest) else None
      | Any :: rest -> Some (wilds arity @ rest)
      | [] -> None)
    rows

(* The rows that apply when the first value is a constructor no row names. *)
let default rows =
  List.filter_map (function Any :: rest -> Some rest | _ -> None) rows

let head_ctors rows =
  List.sort_uniq compare
    (List.filter_map (function Ctor (c, _) :: _ -> Some c | _ -> None) rows)

(* The whole constructor list, if the first column names every constructor
   of its type. *)
let complete env heads =
  match heads with
  | [] -> None
  | c :: _ -> (
      match siblings env c with
      | Some all when List.for_all (fun (k, _) -> List.mem k heads) all ->
          Some all
      | _ -> None)

let rec useful env rows q =
  match q with
  | [] -> rows = []
  | Ctor (c, args) :: rest ->
      useful env (specialize c (List.length args) rows) (args @ rest)
  | Any :: rest -> (
      match complete env (head_ctors rows) with
      | Some all ->
          List.exists
            (fun (c, a) -> useful env (specialize c a rows) (wilds a @ rest))
            all
      | None -> useful env (default rows) rest)

(* Like [useful env rows (wilds n)], but returns the unmatched values found:
   [n] patterns that no row matches, or [None] if the rows cover everything. *)
let rec missing env rows n =
  if n = 0 then if rows = [] then Some [] else None
  else
    let heads = head_ctors rows in
    match complete env heads with
    | Some all ->
        List.find_map
          (fun (c, a) ->
            Option.map
              (fun w ->
                let args = List.filteri (fun i _ -> i < a) w in
                let rest = List.filteri (fun i _ -> i >= a) w in
                Ctor (c, args) :: rest)
              (missing env (specialize c a rows) (a + n - 1)))
          all
    | None ->
        Option.map
          (fun w ->
            (* name a constructor nobody handled, if there is a list of them *)
            let first =
              match Option.bind (List.nth_opt heads 0) (siblings env) with
              | Some all ->
                  let k, a =
                    List.find (fun (k, _) -> not (List.mem k heads)) all
                  in
                  Ctor (k, wilds a)
              | None -> Any
            in
            first :: w)
          (missing env (default rows) (n - 1))

let check_match env (e : expr) (subject : expr) arms =
  (* the type of the value being matched, for the message *)
  let column =
    match (Infer.Nodes.find subject.node env.nodes).ty with
    | Con (p, _) -> Some (Path.show ~home:env.home p)
    | Var _ | Fun _ | Error -> None
  in
  (* Arms with a guard might not match even when their pattern does, so they
     never count toward covering a case. *)
  let rows =
    List.fold_left
      (fun rows a ->
        let row = [ simplify env a.arm_pat ] in
        if not (useful env rows row) then
          Diag.error a.arm_pat.ploc
            ~help:"the arms above already match everything this one does"
            "this arm can never match";
        if a.arm_guard = None then rows @ [ row ] else rows)
      [] arms
  in
  (* Collect up to three missing cases, adding each one as a row so the next
     search finds a different one. *)
  let rec collect rows k =
    if k = 0 then []
    else
      match missing env rows 1 with
      | Some [ w ] -> w :: collect (rows @ [ [ w ] ]) (k - 1)
      | _ -> []
  in
  match collect rows 3 with
  | [] -> ()
  | first :: _ as ws ->
      let what =
        match column with
        | Some t -> sprintf "every `%s`" t
        | None -> "every possible value"
      in
      let notes =
        ("missing: " ^ String.concat ", " (List.map show_space ws))
        ::
        (if List.exists (fun a -> a.arm_guard <> None) arms then
           [
             "arms with an `if` guard don't count, since the guard may be false";
           ]
         else [])
      in
      let start = e.loc.start in
      let keyword = { e.loc with stop = { start with col = start.col + 5 } } in
      let help =
        match first with
        | Any -> "add a `_ =>` arm to cover the remaining values"
        | w ->
            sprintf "add an arm for `%s`, or a `_ =>` arm for the rest"
              (show_space w)
      in
      Diag.error keyword ~notes ~help
        (sprintf "this `match` doesn't handle %s" what)

(* ---- walking the program ---- *)

(* Run a check; if it finds a problem, report it and carry on. *)
let guard env f = Diag.recover env.sink ~default:() f

let rec check_expr env (e : expr) =
  match e.kind with
  | Int _ | Bool _ | Unit | Var _ -> ()
  | Unop (_, a) | Field (a, _) | Ref a -> check_expr env a
  | Binop (_, a, b) | Index (a, b) ->
      check_expr env a;
      check_expr env b
  | If (c, t, f) -> List.iter (check_expr env) (c :: t :: Option.to_list f)
  | Array xs -> List.iter (check_expr env) xs
  | Assign { target; value; _ } -> List.iter (check_expr env) [ target; value ]
  | For { iter; body; _ } -> List.iter (check_expr env) [ iter; body ]
  | Call (f, args) -> List.iter (check_expr env) (f :: args)
  | Lambda (_, body) -> check_expr env body
  | Block (stmts, last) ->
      List.iter
        (function
          | Let { value; _ } -> check_expr env value
          | Expr e -> check_expr env e)
        stmts;
      check_expr env last
  | Con (_, args) -> List.iter (fun (_, a) -> check_expr env a) args
  | Record (_, fields) -> List.iter (fun (_, v) -> check_expr env v) fields
  | Match (subject, arms) ->
      check_expr env subject;
      guard env (fun () -> check_match env e subject arms);
      List.iter
        (fun (a : arm) ->
          Option.iter (check_expr env) a.arm_guard;
          check_expr env a.arm_body)
        arms

(* [inferred] is what inference found in the module. *)
let program sink ~imports (r : Resolve.t) (inferred : Infer.t) =
  let types = Hashtbl.create 16 in
  List.iter
    (fun (td : Iface.type_decl) -> Hashtbl.replace types td.path td)
    (List.concat_map (fun (iface : Iface.t) -> iface.types) imports @ r.types);
  List.iter
    (function
      | Fn (f : fn_def) ->
          let nodes = List.assoc f.name.name inferred.nodes in
          check_expr { types; nodes; home = r.home; sink } f.body
      | Type _ | Import _ -> ())
    r.prog

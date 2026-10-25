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
  names : Path.t -> string;  (** how the module writes a type's name *)
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

(* A constructor of a pattern: its name, and what it belongs to: a type,
   or an error set, whose tags are like a sum type's constructors
   (errors.md, "Keeping an error"). [No_list] for an Int, which isn't one
   of a list of constructors, and for a tag of a set that's still open.

   A `match` with `fail` arms matches an outcome, which is a value or an
   error: [Outcome] is its two constructors, [value] and [fail], each with
   one field, the value or the error (errors.md, "Handling: `match`"). A
   value pattern, `_` too, is [value] of it, so `_` never matches an
   error; `fail _` is [fail] of anything. *)
type head = { name : string; owner : owner }

and owner =
  | Of_type of Path.t
  | Of_set of (string * int) list
  | No_list
  | Outcome

type space = Any | Ctor of head * space list

let bool_path = Path.prelude "Bool"
let result_path = Path.prelude "Result"
let value = { name = "value"; owner = Outcome }
let failed = { name = "fail"; owner = Outcome }

(* The tags of [t], an error set, each with its number of payload values:
   [None] if the set is still open. *)
let set_of (t : Ty.ty) =
  match t with
  | Errors { labels; tail = None } ->
      Some
        (List.map
           (fun (l : Ty.label) -> (l.name, List.length l.payload))
           labels)
  | _ -> None

let rec simplify env (p : pattern) =
  match p.pkind with
  | PWild | PVar _ -> Any
  | PInt n -> Ctor ({ name = string_of_int n; owner = No_list }, [])
  | PBool b -> Ctor ({ name = string_of_bool b; owner = Of_type bool_path }, [])
  | PCon (c, ps) ->
      let node = Infer.Nodes.find p.pnode env.nodes in
      let owner =
        match (node.ty, node.found) with
        | (Errors _ as t), _ -> (
            (* a tag, of a set inference settled: every tag it can hold *)
            match set_of t with
            | Some tags -> Of_set tags
            | None -> No_list)
        | _, Some (Ctor_of (path, _)) -> Of_type path
        | _ -> assert false (* inference found it, or reported an error *)
      in
      Ctor ({ name = c.name.name; owner }, List.map (simplify env) ps)
  | PFail _ | PFail_any | POr _ ->
      (* a whole arm's, which [outcomes] simplifies *)
      invalid_arg "Exhaust.simplify: a `fail` pattern inside another"

(* The rows an arm's pattern adds to the matrix of a `match` with `fail`
   arms: one per alternative of an or-pattern. *)
let rec outcomes env (p : pattern) =
  match p.pkind with
  | PFail (t, ps) ->
      let owner =
        match set_of (Infer.Nodes.find p.pnode env.nodes).ty with
        | Some tags -> Of_set tags
        | None -> No_list
      in
      [
        Ctor
          ( failed,
            [ Ctor ({ name = t.name; owner }, List.map (simplify env) ps) ] );
      ]
  | PFail_any -> [ Ctor (failed, [ Any ]) ]
  | POr ps -> List.concat_map (outcomes env) ps
  | _ -> [ Ctor (value, [ simplify env p ]) ]

let rec show_space = function
  | Any -> "_"
  | Ctor ({ owner = Outcome; name = "value" }, [ v ]) -> show_space v
  | Ctor ({ owner = Outcome; _ }, [ e ]) -> "fail " ^ show_space e
  | Ctor (c, []) -> c.name
  | Ctor (c, args) ->
      c.name ^ "(" ^ String.concat ", " (List.map show_space args) ^ ")"

let wilds n = List.init n (fun _ -> Any)

(* Every constructor of the type [c] belongs to, with its number of fields.
   [None] for Int, which has too many values to list. *)
let siblings env c =
  match c.owner with
  | Of_type p when p = bool_path ->
      let b name = { name; owner = Of_type bool_path } in
      Some [ (b "true", 0); (b "false", 0) ]
  | Of_type p -> (
      match Hashtbl.find env.types p with
      | { body = Sum cs; _ } ->
          Some
            (List.map
               (fun (k : Iface.ctor) ->
                 ({ name = k.cname; owner = Of_type p }, List.length k.cfields))
               cs)
      | _ -> None)
  | Of_set tags ->
      Some (List.map (fun (t, n) -> ({ name = t; owner = c.owner }, n)) tags)
  | Outcome -> Some [ (value, 1); (failed, 1) ]
  | No_list -> None

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

(* Check one `match`. [passes_on] says it's a `try match`, which passes on
   the errors its arms don't handle, so only its values have to be
   covered. *)
let check_match env ?(passes_on = false) (e : expr) (subject : expr) arms =
  (* the type of the value being matched, for the message *)
  let column =
    match (Infer.Nodes.find subject.node env.nodes).ty with
    | Con (p, _) -> Some (env.names p)
    | Var _ | Fun _ | Errors _ | Error -> None
  in
  (* With `fail` arms, each row is an outcome (see [owner]), and the error
     set they match is in each `fail` pattern's type *)
  let handles = Infer_expr.handles arms in
  let errors =
    match List.find_opt (fun a -> Infer_expr.is_fail a.arm_pat) arms with
    | Some a -> Some (Infer.Nodes.find a.arm_pat.pnode env.nodes).ty
    | None -> None
  in
  let rows_of (p : pattern) =
    if handles then List.map (fun s -> [ s ]) (outcomes env p)
    else [ [ simplify env p ] ]
  in
  (* Arms with a guard might not match even when their pattern does, so they
     never count toward covering a case. An or-pattern is a row for each
     alternative, and can match if one of them can. *)
  let rows =
    List.fold_left
      (fun rows a ->
        let alts = rows_of a.arm_pat in
        if not (List.exists (useful env rows) alts) then
          Diag.error a.arm_pat.ploc
            ~help:"the arms above already match everything this one does"
            "this arm can never match";
        if a.arm_guard = None then rows @ alts else rows)
      [] arms
  in
  (* a `try match` passes on any error its arms don't match *)
  let rows =
    if passes_on && handles then rows @ [ [ Ctor (failed, [ Any ]) ] ] else rows
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
  (* a missing `Err(_)` of a [Result] whose set is settled is each of its
     tags, which can be named, and so is a missing `fail _` of a set that's
     settled *)
  let result_tags =
    match (Infer.Nodes.find subject.node env.nodes).ty with
    | Con (p, [ _; t ]) when p = result_path -> set_of t
    | _ -> None
  in
  let fail_tags = Option.bind errors set_of in
  let each tags wrap =
    List.map
      (fun (name, n) -> wrap (Ctor ({ name; owner = Of_set tags }, wilds n)))
      tags
  in
  let expand = function
    | Ctor (({ name = "Err"; owner = Of_type p } as err), [ Any ])
      when p = result_path && result_tags <> None && result_tags <> Some [] ->
        each (Option.get result_tags) (fun t -> Ctor (err, [ t ]))
    | Ctor ({ owner = Outcome; name = "fail" }, [ Any ])
      when fail_tags <> None && fail_tags <> Some [] ->
        each (Option.get fail_tags) (fun t -> Ctor (failed, [ t ]))
    | w -> [ w ]
  in
  let missing = List.concat_map expand (collect rows 3) in
  let is_error = function
    | Ctor ({ owner = Outcome; name = "fail" }, _) -> true
    | _ -> false
  in
  match List.filteri (fun i _ -> i < 3) missing with
  | [] -> ()
  | first :: _ as ws ->
      let errors_missing = List.exists is_error ws in
      let values_missing = not (List.for_all is_error ws) in
      let what =
        match (column, errors_missing, values_missing) with
        | _, true, true -> "every value and error"
        | _, true, false -> "every error it can fail with"
        | Some t, _, _ -> sprintf "every `%s`" t
        | None, _, _ -> "every possible value"
      in
      let notes =
        ("missing: " ^ String.concat ", " (List.map show_space ws))
        ::
        (if List.exists (fun a -> a.arm_guard <> None) arms then
           [
             "arms with an `if` guard don't count, since the guard may be false";
           ]
         else [])
        @
        if errors_missing && fail_tags = None then
          [
            "it can fail with whatever a function it was passed fails with, so \
             only `fail _` matches all of it";
          ]
        else []
      in
      let start = e.loc.start in
      let keyword = { e.loc with stop = { start with col = start.col + 5 } } in
      let help =
        match first with
        | Any | Ctor ({ owner = Outcome; name = "value" }, [ Any ]) ->
            "add a `_ =>` arm to cover the remaining values"
        | Ctor ({ owner = Outcome; name = "fail" }, [ Any ]) ->
            "add a `fail _ =>` arm, or pass the errors on with `try match`"
        | w when is_error w ->
            sprintf
              "add an arm for `%s`, or a `fail _ =>` arm for the rest, or pass \
               them on with `try match`"
              (show_space w)
        | w ->
            sprintf "add an arm for `%s`, or a `_ =>` arm for the rest"
              (show_space w)
      in
      Diag.error keyword ~notes ~help
        (sprintf "this `match` doesn't handle %s" what)

(* A variable bound to an error, `Err(e)`, would make the error a value of
   its own (errors.md, "Keeping an error"), so it's matched by its tags. *)
let rec no_bound_errors env (p : pattern) =
  match p.pkind with
  | PVar b -> (
      match (Infer.Nodes.find p.pnode env.nodes).ty with
      | Errors _ ->
          Diag.report env.sink (Infer_msg.bound_error p.ploc b.ident.name)
      | _ -> ())
  | PCon (_, ps) | PFail (_, ps) | POr ps -> List.iter (no_bound_errors env) ps
  | PWild | PInt _ | PBool _ | PFail_any -> ()

(* ---- walking the program ---- *)

(* Run a check; if it finds a problem, report it and carry on. *)
let guard env f = Diag.recover env.sink ~default:() f

let rec check_expr env (e : expr) =
  match e.kind with
  | Int _ | Bool _ | Unit | Var _ -> ()
  | Try ({ kind = Match (subject, arms); _ } as m) ->
      check_match_expr env ~passes_on:true m subject arms
  | Unop (_, a) | Field (a, _) | Ref a | Try a | Attempt a -> check_expr env a
  | Fail (_, args) -> List.iter (fun (_, a) -> check_expr env a) args
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
  | Match (subject, arms) -> check_match_expr env e subject arms

and check_match_expr env ?passes_on e subject arms =
  check_expr env subject;
  List.iter (fun (a : arm) -> no_bound_errors env a.arm_pat) arms;
  guard env (fun () -> check_match env ?passes_on e subject arms);
  List.iter
    (fun (a : arm) ->
      Option.iter (check_expr env) a.arm_guard;
      check_expr env a.arm_body)
    arms

(* [inferred] is what inference found in the module, and [reachable] the
   interfaces of every module reachable through its imports. *)
let program sink ~reachable (r : Resolve.t) (inferred : Infer.t) =
  let types = Hashtbl.create 16 in
  List.iter
    (fun (td : Iface.type_decl) -> Hashtbl.replace types td.path td)
    (List.concat_map (fun (iface : Iface.t) -> iface.types) reachable @ r.types);
  List.iter
    (fun (f : fn_def) ->
      let nodes = List.assoc f.name.name inferred.nodes in
      check_expr { types; nodes; names = Resolve.type_name r; sink } f.body)
    (Ast.functions r.prog)

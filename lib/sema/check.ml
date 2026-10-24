(* Static checks, after name resolution (resolve.ml) and ahead of type
   inference (infer.ml). It checks what can be checked without knowing the
   types of expressions:

   - every constructor and record field mentioned exists, with the right
     number of arguments and the right labels
   - every `match` handles every case, and has no arm that can never match

   The second works without type inference because constructor names are
   unique across the program: a `Pro` pattern can only be matching a `Plan`,
   and the `type Plan` declaration lists every constructor a `Plan` can be.

   Each problem is reported to the sink (diag.ml), and checking carries on
   with the next declaration, constructor, record or `match`. *)

open Ast
open Ast.Resolved

let sprintf = Printf.sprintf
let plural n = if n = 1 then "" else "s"
let quote names = String.concat ", " (List.map (sprintf "`%s`") names)

type ctor_info = { owner : Iface.type_decl; ctor : Iface.ctor }

(* The types this module declares, and the ones its imports' interfaces do
   (iface.ml), by path; constructors by name. *)
type env = {
  types : (Path.t, Iface.type_decl) Hashtbl.t;
  ctors : (string, ctor_info) Hashtbl.t;
  sink : Diag.sink;
}

(* Run a check; if it finds a problem, report it and carry on. *)
let guard env f = Diag.recover env.sink ~default:() f

let no_duplicates env what (ids : ident list) =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (id : ident) ->
      match Hashtbl.find_opt seen id.name with
      | Some first ->
          Diag.report env.sink
            (Diag.make id.loc ~help:"rename one of them"
               ~labels:[ (first, sprintf "the first `%s` is here" id.name) ]
               (sprintf "there are two %s named `%s`" what id.name))
      | None -> Hashtbl.replace seen id.name id.loc)
    ids

let find_ctor env (c : ident) =
  match Hashtbl.find_opt env.ctors c.name with
  | Some info -> info
  | None ->
      Diag.error c.loc (sprintf "there's no constructor named `%s`" c.name)

let field_names (fs : Iface.field list) = List.map (fun f -> f.Iface.fname) fs

let check_arity (c : ident) loc (ctor : Iface.ctor) given =
  let n = List.length ctor.cfields in
  if n <> given then
    let help =
      match ctor.cfields with
      | [] -> sprintf "write `%s` with no parentheses" c.name
      | fs -> sprintf "its field%s: %s" (plural n) (quote (field_names fs))
    in
    Diag.error loc ~help
      (sprintf "`%s` has %d field%s but was given %d" c.name n (plural n) given)

(* ---- type declarations ---- *)

(* Record a type and its constructors, so later checks can look them up. *)
let declare env (td : Iface.type_decl) =
  Hashtbl.replace env.types td.path td;
  match td.body with
  | Record _ | Builtin -> ()
  | Sum cs ->
      List.iter
        (fun (c : Iface.ctor) ->
          guard env @@ fun () ->
          Option.iter
            (fun first ->
              Diag.error c.cloc
                ~help:"constructor names must be unique across all types"
                ~labels:
                  [
                    ( first.ctor.cloc,
                      sprintf "the first `%s` is here, in `%s`" c.cname
                        first.owner.path.name );
                  ]
                (sprintf "there are two constructors named `%s`" c.cname))
            (Hashtbl.find_opt env.ctors c.cname);
          Hashtbl.replace env.ctors c.cname { owner = td; ctor = c })
        cs

let check_type_def env (td : type_def) =
  let check_fields (fs : field list) =
    no_duplicates env "fields" (List.map (fun (f : field) -> f.field_name) fs)
  in
  match td.type_body with
  | Fields fs -> check_fields fs
  | Ctors cs ->
      List.iter (fun (c : tname ctor) -> check_fields c.ctor_fields) cs

(* ---- constructors and records ---- *)

let check_con env loc (c : ident) args =
  let { ctor; _ } = find_ctor env c in
  check_arity c loc ctor (List.length args);
  let labels = List.filter_map fst args in
  if labels <> [] then (
    if List.length labels <> List.length args then
      Diag.error loc
        (sprintf "label every field of `%s`, or none of them" c.name);
    List.iter2
      (fun (l : ident) (f : Iface.field) ->
        if l.name <> f.fname then
          Diag.error l.loc
            ~help:"labels are written in the order the fields are declared"
            (sprintf "expected the label `%s` here, found `%s`" f.fname l.name))
      labels ctor.cfields)

let sorted_names names = List.sort String.compare names

let check_record env loc (name : tname option) (fields : (ident * expr) list) =
  no_duplicates env "fields" (List.map fst fields);
  let given = sorted_names (List.map (fun ((f : ident), _) -> f.name) fields) in
  match name with
  | Some { tref = Param _; _ } ->
      (* resolve.ml only resolves a record's name to a declared type *)
      assert false
  | Some { tref = Named path; tloc } -> (
      let tn : ident = { name = path.name; loc = tloc } in
      match Hashtbl.find_opt env.types path with
      | None -> assert false (* resolve.ml found it *)
      | Some { body = Builtin; _ } ->
          Diag.error tn.loc (sprintf "`%s` isn't a record type" tn.name)
      | Some { body = Sum _; _ } ->
          Diag.error tn.loc ~help:"its values are made with its constructors"
            (sprintf "`%s` isn't a record type" tn.name)
      | Some { body = Record decl; _ } ->
          let declared = field_names decl in
          List.iter
            (fun ((f : ident), _) ->
              if not (List.mem f.name declared) then
                Diag.error f.loc
                  ~help:(sprintf "its fields: %s" (quote declared))
                  (sprintf "`%s` has no field named `%s`" tn.name f.name))
            fields;
          let missing =
            List.filter (fun d -> not (List.mem d given)) declared
          in
          if missing <> [] then
            Diag.error loc
              (sprintf "this `%s` is missing %s" tn.name (quote missing)))
  | None ->
      let matches =
        Hashtbl.fold
          (fun _ (td : Iface.type_decl) acc ->
            match td.body with
            | Record decl when sorted_names (field_names decl) = given ->
                td.path.name :: acc
            | _ -> acc)
          env.types []
      in
      (* When several types fit, inference picks one from how the record is
         used (infer.ml). *)
      if matches = [] then
        Diag.error loc
          ~help:
            "write the type's name before the `{` to see which fields are wrong"
          "no record type has exactly these fields"

(* ---- patterns ---- *)

(* The type a pattern can only be matching, when the pattern says. *)
let pattern_type env (p : pattern) =
  match p.pkind with
  | PInt _ -> Some "Int"
  | PBool _ -> Some "Bool"
  | PCon (c, _) ->
      Option.map
        (fun i -> i.owner.path.name)
        (Hashtbl.find_opt env.ctors c.name)
  | PWild | PVar _ -> None

(* Check a pattern against the type its position holds ([None]: unknown,
   such as a type parameter). *)
let rec check_pattern env expected (p : pattern) =
  (match (expected, pattern_type env p) with
  | Some want, Some got when want <> got ->
      Diag.error p.ploc
        (sprintf "expected a pattern for `%s`, but this one is a `%s`" want got)
  | _ -> ());
  match p.pkind with
  | PCon (c, args) ->
      let { ctor; _ } = find_ctor env c in
      check_arity c p.ploc ctor (List.length args);
      List.iter2
        (fun (f : Iface.field) arg ->
          let expected =
            match f.fty with
            | Con (path, _) -> Some path.name
            | Var _ | Fun _ | Error -> None
          in
          check_pattern env expected arg)
        ctor.cfields args
  | PWild | PVar _ | PInt _ | PBool _ -> ()

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

type space = Any | Ctor of string * space list

let rec simplify (p : pattern) =
  match p.pkind with
  | PWild | PVar _ -> Any
  | PInt n -> Ctor (string_of_int n, [])
  | PBool b -> Ctor (string_of_bool b, [])
  | PCon (c, ps) -> Ctor (c.name, List.map simplify ps)

let rec show_space = function
  | Any -> "_"
  | Ctor (c, []) -> c
  | Ctor (c, args) ->
      c ^ "(" ^ String.concat ", " (List.map show_space args) ^ ")"

let wilds n = List.init n (fun _ -> Any)

(* Every constructor of the type [c] belongs to, with its number of fields.
   [None] for Int, which has too many values to list. *)
let siblings env c =
  if c = "true" || c = "false" then Some [ ("true", 0); ("false", 0) ]
  else
    match Hashtbl.find_opt env.ctors c with
    | Some { owner = { body = Sum cs; _ }; _ } ->
        Some
          (List.map
             (fun (k : Iface.ctor) -> (k.cname, List.length k.cfields))
             cs)
    | _ -> None

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

let check_match env (e : expr) arms =
  (* All arms match the same value, so their patterns must agree on its type. *)
  let column = List.find_map (fun a -> pattern_type env a.arm_pat) arms in
  List.iter (fun a -> check_pattern env column a.arm_pat) arms;
  (* Arms with a guard might not match even when their pattern does, so they
     never count toward covering a case. *)
  let rows =
    List.fold_left
      (fun rows a ->
        let row = [ simplify a.arm_pat ] in
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
  | Con (c, args) ->
      guard env (fun () -> check_con env e.loc c args);
      List.iter (fun (_, a) -> check_expr env a) args
  | Record (name, fields) ->
      guard env (fun () -> check_record env e.loc name fields);
      List.iter (fun (_, v) -> check_expr env v) fields
  | Match (subject, arms) ->
      check_expr env subject;
      guard env (fun () -> check_match env e arms);
      List.iter
        (fun (a : arm) ->
          Option.iter (check_expr env) a.arm_guard;
          check_expr env a.arm_body)
        arms

let program sink ~imports (r : Resolve.t) =
  let env = { types = Hashtbl.create 16; ctors = Hashtbl.create 16; sink } in
  List.iter
    (fun (iface : Iface.t) -> List.iter (declare env) iface.types)
    imports;
  List.iter (declare env) r.types;
  List.iter
    (function
      | Type td -> check_type_def env td | Fn f -> check_expr env f.body)
    r.prog

(* Static checks: the first pass that runs before the program does, ahead of
   type inference (infer.ml). It checks what can be checked without knowing
   the types of expressions:

   - every type, constructor and record field mentioned exists, with the
     right number of arguments and the right labels
   - every `match` handles every case, and has no arm that can never match

   The second works without type inference because constructor names are
   unique across the program: a `Pro` pattern can only be matching a `Plan`,
   and the `type Plan` declaration lists every constructor a `Plan` can be.

   Each problem is reported to the sink (diag.ml), and checking carries on
   with the next declaration, constructor, record or `match`. *)

open Ast

let sprintf = Printf.sprintf
let plural n = if n = 1 then "" else "s"
let quote names = String.concat ", " (List.map (sprintf "`%s`") names)

type ctor_info = { owner : type_def; ctor : ctor }

type env = {
  types : (string, type_def) Hashtbl.t;
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

let check_arity (c : ident) loc (ctor : ctor) given =
  let n = List.length ctor.ctor_fields in
  if n <> given then
    let help =
      match ctor.ctor_fields with
      | [] -> sprintf "write `%s` with no parentheses" c.name
      | fs ->
          sprintf "its field%s: %s" (plural n)
            (quote (List.map (fun f -> f.field_name.name) fs))
    in
    Diag.error loc ~help
      (sprintf "`%s` has %d field%s but was given %d" c.name n (plural n) given)

(* ---- type declarations ---- *)

(* Check that a written type exists and has the right number of arguments.
   [params] are the type parameters in scope, like the `T` in `Option<T>`. *)
let rec check_ty env ~params (t : ty) =
  match t with
  | TyFn (ps, ret, _) ->
      List.iter (check_ty env ~params) ps;
      Option.iter (check_ty env ~params) ret
  | TyInout (t, _) -> check_ty env ~params t
  | TyName (id, args) -> (
      let name = id.name in
      let arity =
        if List.mem name params then Some 0
        else if Prelude.is_type name then
          Option.map
            (fun (t : Prelude.builtin_type) -> t.arity)
            (Prelude.find_type name)
        else
          Option.map
            (fun td -> List.length td.type_params)
            (Hashtbl.find_opt env.types name)
      in
      match arity with
      | None -> Diag.error id.loc (sprintf "there's no type named `%s`" name)
      | Some n ->
          let given = List.length args in
          if n <> given then
            Diag.error id.loc
              (sprintf "`%s` takes %d type argument%s but was given %d" name n
                 (plural n) given);
          List.iter (check_ty env ~params) args)

(* Record a type and its constructors, so later checks can look them up. *)
let declare env td =
  let name = td.type_name in
  if Prelude.is_type name.name then
    Diag.error name.loc ~help:"choose another name"
      (sprintf "`%s` is a built-in type" name.name);
  Option.iter
    (fun first ->
      Diag.error name.loc ~help:"rename one of them"
        ~labels:
          [ (first.type_name.loc, sprintf "the first `%s` is here" name.name) ]
        (sprintf "there are two types named `%s`" name.name))
    (Hashtbl.find_opt env.types name.name);
  Hashtbl.replace env.types name.name td;
  match td.type_body with
  | Fields _ -> ()
  | Ctors cs ->
      List.iter
        (fun c ->
          guard env @@ fun () ->
          Option.iter
            (fun first ->
              Diag.error c.ctor_name.loc
                ~help:"constructor names must be unique across all types"
                ~labels:
                  [
                    ( first.ctor.ctor_name.loc,
                      sprintf "the first `%s` is here, in `%s`" c.ctor_name.name
                        first.owner.type_name.name );
                  ]
                (sprintf "there are two constructors named `%s`"
                   c.ctor_name.name))
            (Hashtbl.find_opt env.ctors c.ctor_name.name);
          Hashtbl.replace env.ctors c.ctor_name.name { owner = td; ctor = c })
        cs

let check_type_def env td =
  no_duplicates env "type parameters" td.type_params;
  let params = List.map (fun (p : ident) -> p.name) td.type_params in
  let check_fields fs =
    no_duplicates env "fields" (List.map (fun f -> f.field_name) fs);
    List.iter
      (fun f -> guard env (fun () -> check_ty env ~params f.field_ty))
      fs
  in
  match td.type_body with
  | Fields fs -> check_fields fs
  | Ctors cs -> List.iter (fun c -> check_fields c.ctor_fields) cs

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
      (fun (l : ident) f ->
        if l.name <> f.field_name.name then
          Diag.error l.loc
            ~help:"labels are written in the order the fields are declared"
            (sprintf "expected the label `%s` here, found `%s`"
               f.field_name.name l.name))
      labels ctor.ctor_fields)

let sorted_names names = List.sort String.compare names

let check_record env loc (name : ident option) (fields : (ident * expr) list) =
  no_duplicates env "fields" (List.map fst fields);
  let given = sorted_names (List.map (fun ((f : ident), _) -> f.name) fields) in
  match name with
  | Some tn -> (
      match Hashtbl.find_opt env.types tn.name with
      | None -> Diag.error tn.loc (sprintf "there's no type named `%s`" tn.name)
      | Some { type_body = Ctors _; _ } ->
          Diag.error tn.loc ~help:"its values are made with its constructors"
            (sprintf "`%s` isn't a record type" tn.name)
      | Some { type_body = Fields decl; _ } ->
          let declared = List.map (fun f -> f.field_name.name) decl in
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
          (fun _ td acc ->
            match td.type_body with
            | Fields decl
              when sorted_names (List.map (fun f -> f.field_name.name) decl)
                   = given ->
                td.type_name.name :: acc
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
        (fun i -> i.owner.type_name.name)
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
      let { owner; ctor } = find_ctor env c in
      check_arity c p.ploc ctor (List.length args);
      let params = List.map (fun (i : ident) -> i.name) owner.type_params in
      List.iter2
        (fun f arg ->
          let expected =
            match f.field_ty with
            | TyName (id, _) when not (List.mem id.name params) -> Some id.name
            | TyName _ | TyFn _ | TyInout _ -> None
          in
          check_pattern env expected arg)
        ctor.ctor_fields args
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
    | Some { owner = { type_body = Ctors cs; _ }; _ } ->
        Some
          (List.map (fun k -> (k.ctor_name.name, List.length k.ctor_fields)) cs)
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

let check_params env ~params (ps : param list) =
  no_duplicates env "parameters" (List.map (fun p -> p.pname) ps);
  List.iter
    (fun p ->
      Option.iter (fun t -> guard env (fun () -> check_ty env ~params t)) p.pty)
    ps

(* [params] are the type parameters of the enclosing function, which its
   lambdas and `let` annotations can mention too. *)
let rec check_expr env ~params (e : expr) =
  let check_expr = check_expr ~params in
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
  | Lambda (ps, body) ->
      check_params env ~params ps;
      check_expr env body
  | Block (stmts, last) ->
      List.iter
        (function
          | Let { ty; value; _ } ->
              Option.iter
                (fun t -> guard env (fun () -> check_ty env ~params t))
                ty;
              check_expr env value
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
        (fun a ->
          Option.iter (check_expr env) a.arm_guard;
          check_expr env a.arm_body)
        arms

let program sink (prog : program) =
  let env = { types = Hashtbl.create 16; ctors = Hashtbl.create 16; sink } in
  let types =
    List.filter_map (function Type t -> Some t | Fn _ -> None) prog
  in
  let fns = List.filter_map (function Fn f -> Some f | Type _ -> None) prog in
  (* Declare every type before checking any, so types can refer to types
     declared further down the file. *)
  List.iter (fun td -> guard env (fun () -> declare env td)) types;
  List.iter (check_type_def env) types;
  no_duplicates env "functions" (List.map (fun f -> f.name) fns);
  List.iter
    (fun f ->
      if Prelude.is_fn f.name.name then
        Diag.report sink
          (Diag.make f.name.loc ~help:"choose another name"
             (sprintf "`%s` is a built-in function" f.name.name));
      no_duplicates env "type parameters" f.tparams;
      List.iter
        (fun (t : ident) ->
          if Prelude.is_type t.name || Hashtbl.mem env.types t.name then
            Diag.report sink
              (Diag.make t.loc ~help:"choose another name"
                 (sprintf "`%s` is already the name of a type" t.name)))
        f.tparams;
      let params = List.map (fun (t : ident) -> t.name) f.tparams in
      check_params env ~params f.params;
      Option.iter (fun t -> guard env (fun () -> check_ty env ~params t)) f.ret;
      check_expr env ~params f.body)
    fns

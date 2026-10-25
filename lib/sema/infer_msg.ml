(* The wording of inference's errors (infer_expr.ml, infer_top.ml): what
   explains a type mismatch beyond the two types themselves, and what to
   say when a lookup through a type finds nothing, or too much. *)

open Types

let sprintf = Printf.sprintf
let plural n = if n = 1 then "" else "s"
let quote names = String.concat ", " (List.map (sprintf "`%s`") names)

(* "a `Bool`", "an `Int`" *)
let article name =
  match name.[0] with
  | 'A' | 'E' | 'I' | 'O' | 'U' -> sprintf "an `%s`" name
  | _ -> sprintf "a `%s`" name

(* Where [found] and [expected] disagree on whether a function parameter is
   `inout`, the mode [found] has there. Error messages explain that, since
   the two types can otherwise look alike. *)
let rec mode_clash found expected =
  match (repr found, repr expected) with
  | TFun (p1, r1, _, _), TFun (p2, r2, _, _)
    when List.length p1 = List.length p2 ->
      let here =
        List.find_map
          (fun ((x : Types.param), (y : Types.param)) ->
            if x.mode <> y.mode then Some x.mode else mode_clash x.ty y.ty)
          (List.combine p1 p2)
      in
      if here <> None then here else mode_clash r1 r2
  | TCon (n1, a1), TCon (n2, a2) when n1 = n2 && List.length a1 = List.length a2
    ->
      List.find_map (fun (x, y) -> mode_clash x y) (List.combine a1 a2)
  | _ -> None

(* Notes for a mismatch between [found] and [expected] that the two types
   alone don't explain: the type parameters in them, and a parameter that's
   [inout] in one and not the other. Also the help that goes with the
   latter, unless the caller gave one. *)
let mismatch_notes ?help ~found ~expected () =
  let params =
    List.sort_uniq compare (List.map snd (skolems found @ skolems expected))
  in
  let clash = mode_clash found expected in
  let notes =
    List.map
      (fun t ->
        sprintf
          "`%s` is a type parameter, so this code has to work for every type \
           `%s` could be"
          t t)
      params
    @
    match clash with
    | Some Inout ->
        [
          "a function that changes its argument (`inout`) can't stand in for \
           one that only reads it: its caller wouldn't pass the argument with \
           `&`, so the change would be lost";
        ]
    | Some Read ->
        [
          "a function that only reads its argument can't stand in for one that \
           changes it (`inout`)";
        ]
    | None -> []
  in
  let help =
    match (help, clash) with
    | None, Some Inout ->
        Some
          "pass it only where the parameter's type says `fn(inout ...)`, or \
           call it directly"
    | h, _ -> h
  in
  (notes, help)

(* ---- lookups through a type ----

   [home] is the module being checked, so types are named as it would
   write them (path.ml). *)

let type_name ~home p = Path.show ~home p
let field_names (fs : Iface.field list) = List.map (fun f -> f.Iface.fname) fs

let no_ctor (c : Ast.ident) =
  Diag.make c.loc (sprintf "there's no constructor named `%s`" c.name)

(* Today constructor names are unique (resolve.ml), so this can't happen
   yet; it's what sharing them will report. *)
let ambiguous_ctor ~home (c : Ast.ident) owners =
  let full p = sprintf "`%s.%s`" (type_name ~home p) c.name in
  Diag.make c.loc
    ~help:
      (sprintf
         "annotate the value with the type you mean, like `let x: %s = %s`, so \
          `%s` is found through it"
         (type_name ~home (List.hd owners))
         c.name c.name)
    (sprintf "`%s` could be %s" c.name
       (String.concat " or " (List.map full owners)))

let ctor_arity loc (c : Ast.ident) (ctor : Iface.ctor) given =
  let n = List.length ctor.cfields in
  let help =
    match ctor.cfields with
    | [] -> sprintf "write `%s` with no parentheses" c.name
    | fs -> sprintf "its field%s: %s" (plural n) (quote (field_names fs))
  in
  Diag.make loc ~help
    (sprintf "`%s` has %d field%s but was given %d" c.name n (plural n) given)

let some_labels loc (c : Ast.ident) =
  Diag.make loc (sprintf "label every field of `%s`, or none of them" c.name)

let wrong_label (l : Ast.ident) (f : Iface.field) =
  Diag.make l.loc
    ~help:"labels are written in the order the fields are declared"
    (sprintf "expected the label `%s` here, found `%s`" f.fname l.name)

(* `Plan { ... }`, where `Plan` isn't a record *)
let not_a_record ~home loc (td : Iface.type_decl) =
  let help =
    match td.body with
    | Builtin ->
        "it's built in; only a type declared with fields, like `type Point = { \
         x: Int }`, is made with `Point { ... }`"
    | _ -> "its values are made with its constructors"
  in
  Diag.make loc ~help
    (sprintf "`%s` isn't a record type" (type_name ~home td.path))

let no_record_fits loc =
  Diag.make loc
    ~help:"write the type's name before the `{` to see which fields are wrong"
    "no record type has exactly these fields"

let several_records_fit ~home loc paths =
  Diag.make loc
    ~help:
      (sprintf "write the type's name first, like `%s { ... }`"
         (type_name ~home (List.hd paths)))
    (sprintf "these fields fit more than one type: %s"
       (quote (List.map (type_name ~home) paths)))

let no_such_field ~home (f : Ast.ident) path decl =
  Diag.make f.loc
    ~help:(sprintf "its fields: %s" (quote (field_names decl)))
    (sprintf "`%s` has no field named `%s`" (type_name ~home path) f.name)

let missing_fields ~home loc path missing =
  Diag.make loc
    (sprintf "this `%s` is missing %s" (type_name ~home path) (quote missing))

let needs_record (f : Ast.ident) shown =
  Diag.make f.loc
    (sprintf "`.%s` needs a record, but this is %s" f.name (article shown))

let no_record_has (f : Ast.ident) =
  Diag.make f.loc (sprintf "no record type has a field named `%s`" f.name)

(* `u.id` where `u`'s type isn't known yet, and several records have an
   `id`. [what] is the record's variable, if it is one. *)
let several_records_have ~home loc ?what (f : Ast.ident) paths =
  let what, help =
    match what with
    | Some x ->
        ( sprintf "`%s`" x,
          sprintf "annotate `%s` where it's defined, like `%s: %s`" x x
            (type_name ~home (List.hd paths)) )
    | None -> ("this", "add a type annotation to say which")
  in
  Diag.make loc ~help
    ~notes:
      [
        sprintf "`%s` is a field of %s" f.name
          (String.concat " and "
             (List.map (fun p -> sprintf "`%s`" (type_name ~home p)) paths));
        "a field is found through its record's type, which has to be known \
         where the field is used";
      ]
    (sprintf "can't tell which record type %s is" what)

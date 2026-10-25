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

   [names] says how the module being checked writes each type's name
   (Resolve.type_name). *)
let field_names (fs : Iface.field list) = List.map (fun f -> f.Iface.fname) fs

(* How to write the type [p] here: the import that's needed first, if any,
   and its name. A type of a module that isn't imported can't be written
   yet; imported, its alias would be the last part of its path. *)
let writing ~names ~can_name (p : Path.t) =
  if can_name p then ("", names p)
  else
    let alias =
      match String.rindex_opt p.home '/' with
      | Some i -> String.sub p.home (i + 1) (String.length p.home - i - 1)
      | None -> p.home
    in
    (sprintf "import `%s`, then " p.home, alias ^ "." ^ p.name)

(* The way to write a constructor [c] of the type [p] in full. *)
let write_ctor ~names ~can_name p c =
  let first, t = writing ~names ~can_name p in
  sprintf "%swrite `%s.%s`" first t c

(* [elsewhere] are the types that have [c] but can't be named bare here,
   like a type of a module that isn't imported by name. *)
let no_ctor ~names ~can_name (c : Ast.ident) elsewhere =
  match elsewhere with
  | [] ->
      Diag.make c.loc
        ~help:
          (sprintf
             "check the spelling, or declare it in a type, like `type Shape = \
              | %s`"
             c.name)
        (sprintf "there's no constructor named `%s`" c.name)
  | ps ->
      (* the types it can name, if there are any, since those need no new
         import *)
      let ps = match List.filter can_name ps with [] -> ps | named -> named in
      Diag.make c.loc
        ~help:
          (sprintf "%s, naming its type"
             (String.concat ", or "
                (List.map (fun p -> write_ctor ~names ~can_name p c.name) ps)))
        (sprintf "no type in scope here has a constructor named `%s`" c.name)

(* `Red`, where nothing says which type it's in, and more than one type
   that the module can name has a `Red` (module-build.md, "Found through a
   type"). *)
let ambiguous_ctor ~names (c : Ast.ident) owners =
  let full p = sprintf "`%s.%s`" (names p) c.name in
  Diag.make c.loc
    ~help:(sprintf "write %s, naming the type you mean" (full (List.hd owners)))
    (sprintf "`%s` could be %s" c.name
       (String.concat " or " (List.map full owners)))

(* ---- opaque types ---- *)

(* Another module's opaque type [p], looked inside: made, read, or used as
   what it's represented as, none of which this module can see. *)
let representation_private (p : Path.t) =
  ( sprintf "`%s`'s representation is private to `%s`" p.name p.home,
    sprintf "use a function from `%s` to make or read one" p.home )

let opaque_private loc (td : Iface.type_decl) =
  let msg, help = representation_private td.path in
  Diag.make loc ~help msg

(* What the module's own opaque type [td] is represented as, as the module
   writes it. *)
let representation ~names (td : Iface.type_decl) =
  match td.body with
  | Opaque (Some rep) ->
      let s : Ty.scheme =
        { ty = rep; names = List.mapi (fun i n -> (i, n)) td.params }
      in
      Ty.show (Ty.printer ~names s) rep
  | _ -> invalid_arg "Infer_msg.representation: not an opaque type"

(* The module's own opaque type [td], written where only a record or a sum
   type makes sense: it's its representation, which has to be written
   instead. [what] says what it was used as. *)
let opaque_own ~names loc (td : Iface.type_decl) what =
  let rep = representation ~names td in
  Diag.make loc
    ~help:
      (sprintf "here %s is %s, so write one of those instead"
         (article (names td.path))
         (article rep))
    (sprintf "`%s` is opaque, so it %s of its own" (names td.path) what)

(* `Light.Purple`, where `Light` has no `Purple`. With [expected], it's a
   bare `Purple` where a `Light` is expected. *)
let not_in_type ~names ?(expected = false) loc (c : Ast.ident)
    (td : Iface.type_decl) =
  let t = names td.path in
  let notes =
    if expected then [ sprintf "%s is expected here" (article t) ] else []
  in
  let msg, help =
    match td.body with
    | Sum cs ->
        ( sprintf "`%s` has no constructor named `%s`" t c.name,
          Some
            (sprintf "its constructors: %s"
               (quote (List.map (fun (k : Iface.ctor) -> k.cname) cs))) )
    | Record _ ->
        ( sprintf "`%s` is a record, so it has no constructors" t,
          Some (sprintf "make one with `%s { ... }`" t) )
    | Builtin ->
        ( sprintf "`%s` is built in, and has no constructors" t,
          Some "its values are written directly, like `1`, `true` or `[1, 2]`"
        )
    | Opaque None ->
        let msg, help = representation_private td.path in
        (msg, Some help)
    | Opaque (Some _) ->
        ( sprintf "`%s` is opaque, so it has no constructors of its own" t,
          Some
            (sprintf "here %s is %s, so write one of those instead" (article t)
               (article (representation ~names td))) )
    | Errors _ ->
        (* resolve.ml reports a set written as a type; this is for safety *)
        ( sprintf "`%s` is an error set, so it has no constructors" t,
          Some "a tag is written bare, after `fail`" )
  in
  Diag.make (Loc.span loc c.loc) ~notes ?help msg

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
let not_a_record ~names loc (td : Iface.type_decl) =
  match td.body with
  | Opaque None -> opaque_private loc td
  | Opaque (Some _) -> opaque_own ~names loc td "has no fields"
  | _ ->
      let help =
        match td.body with
        | Builtin ->
            "it's built in; only a type declared with fields, like `type Point \
             = { x: Int }`, is made with `Point { ... }`"
        | _ -> "its values are made with its constructors"
      in
      Diag.make loc ~help (sprintf "`%s` isn't a record type" (names td.path))

let no_record_fits loc =
  Diag.make loc
    ~help:"write the type's name before the `{` to see which fields are wrong"
    "no record type has exactly these fields"

let several_records_fit ~names loc paths =
  Diag.make loc
    ~help:
      (sprintf "write the type's name first, like `%s { ... }`"
         (names (List.hd paths)))
    (sprintf "these fields fit more than one type: %s"
       (quote (List.map names paths)))

let no_such_field ~names (f : Ast.ident) path decl =
  Diag.make f.loc
    ~help:(sprintf "its fields: %s" (quote (field_names decl)))
    (sprintf "`%s` has no field named `%s`" (names path) f.name)

let missing_fields ~names loc path missing =
  Diag.make loc
    ~help:
      (sprintf "give %s a value too, like `%s: ...`"
         (if List.length missing = 1 then "it" else "each")
         (List.hd missing))
    (sprintf "this `%s` is missing %s" (names path) (quote missing))

let needs_record (f : Ast.ident) shown =
  Diag.make f.loc
    (sprintf "`.%s` needs a record, but this is %s" f.name (article shown))

(* `u.id` where `u`'s type isn't known yet: what `u` is, if that helps say
   how to fix it. A variable, or the result of a function [g] that calls
   this one, which is seen only as its declaration describes it until both
   are checked (infer_top.ml). *)
type what = Named of string | Group_result of string

(* How to say that [what] is the record type [p]: what to call it in the
   message, the help, and any notes. *)
let say_which ~names ~can_name ?what p =
  let first, t = writing ~names ~can_name p in
  match what with
  | Some (Named x) ->
      ( sprintf "`%s`" x,
        sprintf "%sannotate `%s` where it's defined, like `%s: %s`" first x x t,
        [] )
  | Some (Group_result g) ->
      ( "this",
        sprintf "%sdeclare what `%s` returns, like `-> %s`" first g t,
        [
          sprintf
            "`%s` and this function call each other, so here `%s` is only what \
             its signature says"
            g g;
        ] )
  | None -> ("this", sprintf "%sadd a type annotation to say which" first, [])

let field_of_types ~names (f : Ast.ident) paths =
  [
    sprintf "`%s` is a field of %s" f.name
      (String.concat " and "
         (List.map (fun p -> sprintf "`%s`" (names p)) paths));
    "a field is found through its record's type, which has to be known where \
     the field is used";
  ]

(* `i.plan`, where `i`'s type isn't known yet and no record type the
   module can name bare has a `plan`. [elsewhere] are those that have one,
   which step 2 of the lookup doesn't look in. *)
let no_record_has ~names ~can_name ?what (f : Ast.ident) elsewhere =
  match elsewhere with
  | [] ->
      Diag.make f.loc (sprintf "no record type has a field named `%s`" f.name)
  | p :: _ ->
      let _, help, extra = say_which ~names ~can_name ?what p in
      Diag.make f.loc ~help
        ~notes:(field_of_types ~names f elsewhere @ extra)
        (sprintf "no record type in scope here has a field named `%s`" f.name)

(* `u.id` where `u`'s type isn't known yet, and several records have an
   `id`. *)
let several_records_have ~names loc ?what (f : Ast.ident) paths =
  let what, help, extra =
    say_which ~names ~can_name:(fun _ -> true) ?what (List.hd paths)
  in
  Diag.make loc ~help
    ~notes:(field_of_types ~names f paths @ extra)
    (sprintf "can't tell which record type %s is" what)

(* ---- dependencies ---- *)

(* [f]'s body uses [dep], which it doesn't declare; [call] is the first
   call that uses it. *)
let undeclared_use (f : Ast.Resolved.fn_def) dep call =
  let name = f.name.name in
  Diag.make f.name.loc
    ~labels:
      (match call with
      | Some l -> [ (l, sprintf "this call uses `%s`" dep) ]
      | None -> [])
    ~notes:
      [
        (if f.uses = None then
           "a public function without `uses` uses nothing, and its body is \
            checked against that"
         else sprintf "`%s`'s body can only use what its `uses` lists" name);
      ]
    ~help:
      (if f.uses = None then sprintf "add `uses %s`" dep
       else sprintf "add `%s` to its `uses`" dep)
    (sprintf "`%s` doesn't declare `%s`" name dep)

(* ---- methods ----

   [recv] is the receiver as it's written, `s` in `s.push(1)`, if it can be
   printed (Ast.source), and [call] the whole call, for a help that shows
   how to write it. *)

(* "`s`", or "its receiver" when the receiver can't be printed *)
let receiver recv =
  match recv with Some r -> sprintf "`%s`" r | None -> "its receiver"

(* `s.push(1)`, where `push` has `inout self` *)
let needs_amp loc ~recv ~call (m : string) =
  Diag.make loc
    ~notes:
      [
        (match recv with
        | Some r -> sprintf "`&` shows at the call that `%s` is changed" r
        | None -> "`&` shows at the call that the receiver is changed");
      ]
    ~help:
      (match call with
      | Some c -> sprintf "write `&%s`" c
      | None -> "write `&` before the call")
    (sprintf "`%s` changes %s, so the call needs `&`" m (receiver recv))

(* `&s.size()`, where `size` doesn't have `inout self`; or `&r.f()`, where
   `f` is a field *)
let not_changed loc ~recv (m : string) =
  Diag.make loc ~help:"remove the `&`"
    (sprintf "`%s` doesn't change %s" m
       (match recv with Some r -> sprintf "`%s`" r | None -> "its receiver"))

(* `s.grow()`, where `s`'s type [shown], declared in another module, has
   no public `grow` *)
let no_public_method (m : Ast.ident) ~shown (p : Path.t) =
  Diag.make m.loc
    ~help:(sprintf "if it's defined in `%s`, mark it `pub`" p.home)
    (sprintf "`%s` has no public `%s`" shown m.name)

(* `s.grow()`, where `s`'s type [shown] is the module's own, or built in,
   and has no `grow`. [methods] are the ones it has. *)
let no_method (m : Ast.ident) ~shown ~own ~type_name methods =
  let help =
    match methods with
    | _ :: _ -> Some (sprintf "its methods: %s" (quote methods))
    | [] when own ->
        Some (sprintf "declare it under `type %s`, with `self` first" type_name)
    | [] -> None
  in
  Diag.make m.loc ?help (sprintf "`%s` has no method named `%s`" shown m.name)

(* `t.of([1])`, where `of` is an associated function or value of [t]'s
   type, which is called, or used, after its type: [fix] *)
let not_a_method (m : Ast.ident) (kind : Iface.op_kind) ~fix =
  Diag.make m.loc ~help:(sprintf "write `%s`" fix)
    (match kind with
    | Value -> sprintf "`%s` isn't a method (it's an associated value)" m.name
    | Method | Function ->
        sprintf "`%s` isn't a method (it has no `self`)" m.name)

(* `s.peek`, where `peek` is a method, and isn't called. [item] is how to
   write it as a function, `Stack.peek`, and [changes] says whether it has
   `inout self`, so that the call is written with `&`. *)
let method_not_called (m : Ast.ident) ~recv ~item ~changes =
  Diag.make m.loc
    ~help:
      (sprintf "write `%s%s.%s()`, or use `%s` as a function"
         (if changes then "&" else "")
         (Option.value recv ~default:"x")
         m.name item)
    (sprintf "`%s` is a method, so it has to be called" m.name)

(* `s.of`, where `of` is an associated function or value, not a field *)
let item_not_field (m : Ast.ident) (kind : Iface.op_kind) ~item =
  Diag.make m.loc
    ~help:(sprintf "write `%s`" item)
    (sprintf "`%s` is %s, not a field" m.name
       (match kind with
       | Value -> "an associated value"
       | Method | Function -> "an associated function"))

(* `s.size()`, where `s`'s type isn't known yet, and several types the
   module can name have a `size`. [members] are those types, each with
   what its `size` is: "a field", "a method", ... *)
let several_have_member ~names loc ?what (m : Ast.ident) members =
  let paths = List.map fst members in
  let what, help, extra =
    say_which ~names ~can_name:(fun _ -> true) ?what (List.hd paths)
  in
  let types ps = String.concat " and " (List.map (sprintf "`%s`") ps) in
  let has =
    match List.sort_uniq compare (List.map snd members) with
    | [ kind ] ->
        sprintf "%s each have %s `%s`"
          (types (List.map (fun p -> names p) paths))
          kind m.name
    | _ ->
        String.concat ", and "
          (List.map
             (fun (p, kind) -> sprintf "`%s` has %s `%s`" (names p) kind m.name)
             members)
  in
  Diag.make loc ~help
    ~notes:
      ([
         has;
         "a method is found through its receiver's type, which has to be known \
          where it's called";
       ]
      @ extra)
    (sprintf "can't tell which type %s is" what)

(* `x.size()`, where `x`'s type isn't known yet and no type the module
   can name bare has a `size`. [elsewhere] are those that have a method
   named `size`, which step 2 of the lookup doesn't look in. *)
let no_type_has_method ~names ~can_name ?what (m : Ast.ident) elsewhere =
  let _, help, extra = say_which ~names ~can_name ?what (List.hd elsewhere) in
  Diag.make m.loc ~help
    ~notes:
      ([
         sprintf "`%s` is a method of %s" m.name
           (String.concat " and "
              (List.map (fun p -> sprintf "`%s`" (names p)) elsewhere));
         "a method is found through its receiver's type, which has to be known \
          where it's called";
       ]
      @ extra)
    (sprintf "no type in scope here has a method named `%s`" m.name)

(* ---- associated values ---- *)

(* The associated value [f]'s body uses [dep]; [call] is the first call
   that uses it. *)
let value_uses (f : Ast.Resolved.fn_def) dep call =
  Diag.make f.name.loc
    ~labels:
      (match call with
      | Some l -> [ (l, sprintf "this call uses `%s`" dep) ]
      | None -> [])
    ~notes:
      [
        "an associated value is made once, when the program starts, so it \
         can't use a dependency";
      ]
    ~help:
      (sprintf "make it an associated function, `fn %s() uses %s = ...`"
         (Ast.short_name f.name.name)
         dep)
    (sprintf "the associated value `%s` uses `%s`" f.name.name dep)

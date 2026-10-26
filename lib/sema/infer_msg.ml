(* The wording of inference's errors (infer_expr.ml, infer_top.ml): what
   explains a type mismatch beyond the two types themselves, and what to
   say when a lookup through a type finds nothing, or too much. *)

open Types

let sprintf = Printf.sprintf
let plural n = if n = 1 then "" else "s"
let code x = sprintf "`%s`" x
let quote names = String.concat ", " (List.map code names)

(* "`Short(Int)`", "`Short(Int)` and `Frozen`", "`A`, `B` and `C`" *)
let and_list items =
  match List.rev (List.map (sprintf "`%s`") items) with
  | [] -> ""
  | [ x ] -> x
  | last :: rest -> String.concat ", " (List.rev rest) ^ " and " ^ last

(* "a `Bool`", "an `Int`", and by the sound: "a `Unit`", "a `User`", but
   "an `Undo`", "an `Update`" *)
let article name =
  let starts p = String.starts_with ~prefix:p name in
  let vowel =
    match name.[0] with
    | 'A' | 'E' | 'I' | 'O' -> true
    | 'U' -> (starts "Un" && not (starts "Uni")) || starts "Up" || starts "Ul"
    | _ -> false
  in
  if vowel then sprintf "an `%s`" name else sprintf "a `%s`" name

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

(* Where [found] can fail with errors that [expected], a closed row, can't:
   those errors, and the ones it can. A function passed where its errors can't go looks much like
   what's wanted, since a message doesn't show a row's tail. *)
let rec errors_clash found expected =
  let pairs a b =
    if List.length a = List.length b then
      List.find_map (fun (x, y) -> errors_clash x y) (List.combine a b)
    else None
  in
  match (repr found, repr expected) with
  | TFun (p1, r1, e1, _), TFun (p2, r2, e2, _) -> (
      let wanted = row_names e2 in
      match
        List.filter
          (fun (l : label) -> not (List.mem l.name wanted))
          (fst (row_parts e1))
      with
      | _ :: _ as extra when row_tail e2 = None ->
          Some (extra, fst (row_parts e2))
      | _ -> pairs (r1 :: param_tys p1) (r2 :: param_tys p2))
  | TCon (n1, a1), TCon (n2, a2) when n1 = n2 -> pairs a1 a2
  | _ -> None

(* The labels named [name] in the error rows inside [t]. *)
let rec labels_named name t =
  let row r =
    List.filter (fun (l : label) -> l.name = name) (fst (row_parts r))
  in
  match repr t with
  | TFun (ps, r, e, _) ->
      row e @ List.concat_map (labels_named name) (r :: param_tys ps)
  | TCon (_, args) -> List.concat_map (labels_named name) args
  | TErrors e -> row e
  | TVar _ | TSkol _ | TError | TUses _ -> []

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
    | Dep _ ->
        ( sprintf "`%s` is a dependency, so it has no constructors" t,
          Some
            (sprintf
               "make an implementation of it with `%s { ... }`, giving each of \
                its operations"
               t) )
    | Handler _ ->
        ( sprintf "`%s` is a handler, so it has no constructors" t,
          Some (sprintf "describe one by calling it, `%s(...)`" t) )
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

let no_such_field ~names ?(what = "field") (f : Ast.ident) path decl =
  Diag.make f.loc
    ~help:(sprintf "its %ss: %s" what (quote (field_names decl)))
    (sprintf "`%s` has no %s named `%s`" (names path) what f.name)

(* `c.now`, where `c` is an implementation of the dependency [dep], which
   has the operation `now` or not: an implementation's operations are
   called on the dependency, `Clock.now()`, once it's installed, never read
   from it (deps.md, "Calling one"). *)
let op_of_value ~names (f : Ast.ident) dep (ops : Iface.field list) =
  let d = names dep in
  if List.exists (fun (o : Iface.field) -> o.fname = f.name) ops then
    Diag.make f.loc
      ~notes:
        [
          sprintf
            "a value of `%s` is an implementation of it: it's used by \
             installing it, with `with`, and then `%s.%s` calls it"
            d d f.name;
        ]
      ~help:(sprintf "call the installed one: `%s.%s(...)`" d f.name)
      (sprintf "`%s` is an operation of `%s`, so it isn't read from a value"
         f.name d)
  else
    Diag.make f.loc
      ~help:(sprintf "its operations: %s" (quote (field_names ops)))
      (sprintf "`%s` has no operation named `%s`" d f.name)

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

(* ---- mismatches ---- *)

(* What else explains a mismatch, found by looking inside the two types
   (Infer_report.unifies). Each says what it is with notes, and suggests
   a fix, unless something else did first. Types are as the message prints
   them. *)
type behind =
  | Needs_more of { ty : string; alone : bool }
      (** an implementation that needs more than the one wanted, of the type
          [ty]; [alone] if it's the whole type, not inside another, `Box<Rates>`
      *)
  | Shapes of string * string list
      (** the tag with two shapes, and the shapes *)
  | Fails_where_none of string list
      (** a function that fails with these where nothing can fail *)
  | Fails_beyond of string list * string list
      (** a function that fails with the first where only the second can *)
  | Private of Path.t  (** another module's opaque type *)
  | Taken_as_one of { handler : string; deps : string list; dep : string }
      (** a handler of [deps] where an implementation of [dep], one of them, is
          wanted, somewhere that wasn't known as it was made *)
  | Other_handler of { handler : string; deps : string list; dep : string }
      (** a handler of [deps], where an implementation of [dep], which isn't one
          of them, is wanted *)

let behind_note = function
  | Needs_more { ty; alone } ->
      (* `uses` after `->` is the function's, so a dependency's own is
         parenthesized; inside `Box<...>` it needs nothing *)
      let ty = if alone then sprintf "(%s)" ty else ty in
      ( [
          "an implementation's type says what it needs, so one that needs more \
           can't stand in for one that needs less";
        ],
        sprintf "say what it needs where its type is written: `%s`" ty )
  | Shapes (name, shapes) ->
      ( [
          sprintf
            "`%s` has two shapes here, %s: a tag is its name and its payload's \
             types, so these are two errors with one name"
            name (and_list shapes);
        ],
        "give one of them another name, where it fails" )
  | Fails_where_none extra ->
      ( [
          sprintf
            "this function can fail with %s, and the type wanted here can't \
             fail"
            (and_list extra);
          "a parameter whose type is inferred can fail only if it's called \
           with `try`";
        ],
        "pass its errors on with `try` where it's called, or handle them \
         inside it with `match`" )
  | Fails_beyond (extra, wanted) ->
      ( [
          sprintf
            "this function can fail with %s, and the type wanted here fails \
             only with %s"
            (and_list extra) (and_list wanted);
        ],
        "handle the others inside it with `match`" )
  | Private p ->
      let note, help = representation_private p in
      ([ note ], help)
  | Taken_as_one { handler; deps; dep } ->
      ( [
          sprintf
            "`%s` implements %s, so it's taken as just `%s` only where `%s` is \
             wanted as it's made"
            handler (and_list deps) dep dep;
        ],
        sprintf "say so where it's made: `let x: %s = %s(...)`" dep handler )
  | Other_handler { handler; deps; dep } ->
      ( [
          sprintf
            "`%s` is a handler for %s, so what its call describes implements \
             those, not `%s`"
            handler (and_list deps) dep;
        ],
        sprintf
          "give an implementation of `%s` here: a `%s { ... }`, or a handler \
           for `%s`"
          dep dep dep )

(* A mismatch between [found] and [expected], printed as [f] and [x], at
   [loc]: worded by [msg] if the caller has a way to say it, and explained
   by the caller's [notes] and [help] and by what's [behind] it. *)
let mismatch loc ?msg ~notes ?help ~labels ~found ~expected ~f ~x behind =
  let msg =
    match msg with
    | Some m -> m
    | None -> sprintf "expected `%s`, found `%s`" x f
  in
  let more, help = mismatch_notes ?help ~found ~expected () in
  let more, help =
    List.fold_left
      (fun (more, help) b ->
        let notes, h = behind_note b in
        (more @ notes, Some (Option.value help ~default:h)))
      (more, help) behind
  in
  Diag.make loc ?help ~notes:(notes @ more) ~labels msg

(* A type that would have to contain itself, `a = Array<a>`. *)
let contains_itself loc ~found ~expected =
  Diag.make loc
    ~notes:
      [
        sprintf "it would have to be `%s` and `%s` at the same time" expected
          found;
      ]
    "this value's type would have to contain itself"

(* ---- expressions ----

   A mismatch is worded by a function given both types as they're printed:
   the one found, [f], then the one expected, [x] (Infer_report.why). *)

(* What an `Int` is wanted for: a side of the operator [op], or an index. *)
type int_use = Operator of string | Indexing

let int_note = function
  | Operator op -> sprintf "`%s` works on `Int`s" op
  (* this reads oddly, but restructuring changes no message *)
  | Indexing -> "`an index` works on `Int`s"

(* What a `Bool` is wanted for. *)
type bool_use = Condition | Negated | Side of string | Guard | Asserted

let bool_note use =
  sprintf "%s has to be a `Bool`"
    (match use with
    | Condition -> "an `if` condition"
    | Negated -> "what `not` is applied to"
    | Side op -> sprintf "each side of `%s`" op
    | Guard -> "a guard"
    | Asserted -> "what an `assert` checks")

(* A statement of the function [c] threw away a value whose type wasn't
   known, which made it `Unit`: the label at the statement, and the
   help. *)
let forced_unit c =
  sprintf
    "`%s` throws this value away, and its type wasn't known, so it was taken \
     to be `Unit`"
    c

let forced_unit_help c =
  sprintf "if `%s` means to drop a value of any type there, write `let _ = ...`"
    c

let lambda_produces f x =
  sprintf "this lambda produces %s, but it has to produce %s" (article f)
    (article x)

let orelse_left f _ =
  sprintf "`orelse` takes an `Option` on its left, but this is %s" (article f)

let orelse_left_help =
  "`x orelse y` is the value in the `Option` `x`, or else `y`"

let orelse_right f x =
  sprintf "this is %s, but the `Option` on the left of `orelse` holds %s"
    (article f) (article x)

let orelse_right_help = "give a value of that type, or `fail` with an error"

(* `a == b`, where [op] is `==` or `!=` *)
let compares op f x =
  sprintf
    "`%s` compares two values of the same type, but this is %s and the left \
     side is %s"
    op (article f) (article x)

let this_is x = sprintf "this is %s" (article x)

let else_branch f x =
  sprintf "this `else` branch is %s, but the `then` branch is %s" (article f)
    (article x)

let then_branch x = sprintf "the `then` branch is %s" (article x)
let if_branches = "both branches of an `if` have to produce the same type"

let no_else f _ =
  sprintf "this `if` has no `else`, so it can't produce %s" (article f)

let no_else_help = "add an `else` branch for when the condition is false"

let element_before f x =
  sprintf "this element is %s, but the elements before it are %s" (article f)
    (article x)

let element_others f x =
  sprintf "this element is %s, but the others are %s" (article f) (article x)

let not_indexable f _ =
  sprintf "only an `Array` can be indexed, but this is %s" (article f)

let assigned f x =
  sprintf "this is %s, but it's being assigned to %s" (article f) (article x)

let not_iterable f _ =
  sprintf "a `for` loop goes over an `Array`, but this is %s" (article f)

(* The help for an error with two shapes, given the tag: one that comes
   from a `fail`, or from a `Result` or a `match` that passes it on. *)
let rename_fail _ = "give one of them another name"
let rename_where_in _ = "rename one of them where it comes in"

(* ---- calls ----

   [name] is the callee's name, if what's called is a function's name. *)

(* The callee as a message names it: "`print`", or "this". *)
let callee name = match name with Some n -> code n | None -> "this"

let wrong_arity loc name n given =
  Diag.make loc
    (sprintf "%s takes %d argument%s but was given %d" (callee name) n
       (plural n) given)

(* [shown] is the type of what's called *)
let not_a_function loc name shown =
  Diag.make loc
    (sprintf "%s is %s, not a function" (callee name) (article shown))

(* `take(&c.pop())`, where `take` changes its argument: the `&` is `c`'s.
   [arg] is the argument as written, and [call] the call in it. *)
let changes_call_result loc name ~arg ~call =
  Diag.make loc ~help:"put it in a `var` first, and pass that"
    ~notes:
      [
        sprintf
          "the `&` in `%s` marks the receiver the call changes, not the \
           argument"
          (Option.value arg ~default:"&x.m()");
      ]
    (sprintf
       "%s changes this argument, but %s is a call's result, not something it \
        can change"
       (callee name)
       (match call with Some c -> code c | None -> "it"))

(* An argument for an `inout` parameter without `&`; [var] is the variable
   it changes, if it's one. *)
let arg_needs_amp loc name ~var =
  Diag.make loc
    ~help:
      (match var with
      | Some x -> sprintf "write `&` before it, as in `&%s`" x
      | None -> "pass a variable, marked with `&`")
    ~notes:[ "`&` shows at the call that the argument is changed" ]
    (sprintf "%s changes this argument, so it needs `&`" (callee name))

let arg_not_changed loc name =
  Diag.make loc ~help:"remove the `&`"
    ~notes:[ "`&` marks an argument the call changes: an `inout` parameter" ]
    (sprintf "%s doesn't change this argument" (callee name))

(* ---- constructors and records ---- *)

(* Where the type a value has to have comes from: "`Shape`'s field `w`",
   "`Clock`'s operation `now`". *)
let part_of owner what part = sprintf "`%s`'s %s `%s`" owner what part

let two_fields (f : Ast.ident) first =
  Diag.make f.loc ~help:"remove one of them"
    ~labels:[ (first, sprintf "the first `%s` is here" f.name) ]
    (sprintf "there are two fields named `%s`" f.name)

(* The closure [var], given for an operation, fails with whatever its
   named row [row] stands for; the operation fails only with [declared]. *)
let named_row_help ~var ~row declared =
  sprintf
    "`%s` can fail with anything `..%s` stands for%s: write %s in place of `! \
     ..%s`"
    var row
    (match declared with
    | [] -> ", and the operation can't fail"
    | ds -> ", and the operation only with " ^ and_list ds)
    (match declared with
    | [] -> "nothing"
    | ds -> sprintf "`! %s`" (String.concat " | " ds))
    row

(* ---- `match` and patterns ---- *)

let arm_after f x =
  sprintf "this arm is %s, but the arms above it are %s" (article f) (article x)

let first_arm x = sprintf "the first arm is %s" (article x)

(* the variable [name] of one alternative of a pattern, `A(x) | B(x)` *)
let alternative name f x =
  sprintf "`%s` is %s here, but %s in the first alternative" name (article f)
    (article x)

let pattern_for f x =
  sprintf "expected a pattern for `%s`, but this one is %s" x (article f)

(* A statement's value [f], which isn't `Unit`. [callee] is the function
   called, if it's a call, and [implementation] whether [f] is an
   implementation, or a handler's description, which is for installing. *)
let thrown_away ~callee ~implementation f _ =
  match callee with
  | Some name when implementation ->
      sprintf "`%s` makes `%s`, and this throws it away" name f
  | Some name -> sprintf "`%s` returns `%s`, and this throws it away" name f
  | None -> sprintf "this is %s, and it's thrown away" (article f)

let thrown_away_help ~implementation =
  if implementation then
    "install it with `with`, or write `let _ = ...` if you mean to drop it"
  else "use it, or write `let _ = ...` if you mean to drop it"

(* ---- rows ---- *)

(* What uses a row of dependencies, for a message about it: "this call
   uses". *)
type user = Call_uses | Installing | Passing | With_body

let user = function
  | Call_uses -> "this call uses"
  | Installing -> "installing this needs"
  | Passing -> "passing this needs"
  | With_body -> "this `with`'s body uses"

(* [what] uses [labels], which what it's in can't, at [loc]. *)
let cant_use loc what labels =
  let shown =
    match labels with
    | [] -> "more than what it's in can"
    | ns ->
        (* this quotes each name twice (B4 in the stage's plan), which is
           kept while restructuring changes no message *)
        and_list (List.map code ns) ^ ", which what it's in can't"
  in
  Diag.make loc
    ~notes:
      [
        "a function or lambda uses everything its calls use, and everything \
         the implementations its `with`s install need, and the type of what \
         this is in says it can't use all of that";
      ]
    ~help:
      "say what it uses where its type is written, with `uses`, or leave the \
       type out and let it be inferred"
    (sprintf "%s %s" (user what) shown)

(* Code that can fail with [shown] where nothing can; [in_state] if it's a
   handler's state. *)
let cant_fail_here loc ~in_state shown =
  Diag.make loc
    ?notes:
      (if in_state then
         Some
           [
             "a handler's state is made where a `with` installs it, which \
              can't fail";
           ]
       else None)
    ?help:
      (if in_state then
         Some
           "handle it here, with `attempt` or a `match` with `fail` arms, or \
            make the value in an operation instead"
       else None)
    (sprintf "this can fail with %s, which isn't allowed here" shown)

(* The help for a tag a call brings in that's already in the set with
   another shape: rename it where it comes in. [call] is the call as it's
   written, [callee] its name, and [arity] how many values the tag's
   payload has. *)
let rename_call_tag ~call ~callee ~arity tag =
  let args =
    match List.init arity (fun i -> String.make 1 "abcdefgh".[i mod 8]) with
    | [] -> ""
    | xs -> "(" ^ String.concat ", " xs ^ ")"
  in
  match call with
  | Some c ->
      sprintf
        "rename one where it comes in: `try match %s` with the arm `fail %s%s \
         => fail %s%s%s`"
        c tag args
        (String.capitalize_ascii callee)
        tag args
  | None -> rename_where_in tag

(* What brings an error into a function, for a label at it. *)
type error_source = Call_fails | Fails | Result_holds | Match_leaves

let error_source = function
  | Call_fails -> "this call can fail with"
  | Fails -> "this fails with"
  | Result_holds -> "this `Result` holds"
  | Match_leaves -> "no arm of this `match` handles"

(* Why a `try` may cover nothing (Infer_rows.try_hint), for its help. *)
type try_hint =
  | Maybe_result of string
      (** the variable it's applied to, a [Result] whose type isn't known *)
  | Covers_right of string option * string option
      (** it covers everything to its right: all of that, and the [Result] on
          its left, as written *)
  | All_handled  (** a `try match` whose arms handle every error *)

let hint_help = function
  | Maybe_result x ->
      sprintf
        "if `%s` is a `Result`, say so where it's declared, as in `%s: \
         Result<Int, ! E>`: `try` fails with a `Result`'s error only once its \
         type is known"
        x x
  | Covers_right (all, left) ->
      sprintf
        "`try` covers everything to its right, so this is `try (%s)`: to fail \
         with the `Result`'s error first, write `(try %s)`"
        (Option.value all ~default:"...")
        (Option.value left ~default:"...")
  | All_handled ->
      "every error is handled here, so nothing is passed on: remove the `try`"

(* `Err(T(a))`, where [a] is [f] and `T` holds [x] *)
let tag_holds tag f x =
  sprintf "this is %s, but `%s` holds %s here" (article f) tag (article x)

let its_shape shown = sprintf "it's `%s`" shown

(* ---- handlers and `with` ---- *)

let arm_produces f x =
  sprintf "this arm produces %s, but it has to produce %s" (article f)
    (article x)

(* An arm for the operation [op] of [dep], which takes [n] arguments,
   with [given] parameters. *)
let arm_arity loc ~dep ~op n given =
  Diag.make loc
    ~help:(sprintf "give it %d parameter%s, one for each argument" n (plural n))
    (sprintf "`%s.%s` takes %d argument%s, but this has %d parameter%s" dep op n
       (plural n) given (plural given))

let call_outside name =
  sprintf "call %s outside the `with`, with all its arguments" (callee name)

(* `with r.w(a) in body`, where the method [m] has `inout self` *)
let wrapper_changes_receiver loc m =
  Diag.make loc
    ~notes:
      [
        "`with r.w(a) in body` calls `r.w(a, fn() => body)`, and a `with`'s \
         item can't change what it's called on";
      ]
    ~help:(call_outside (Some m))
    (sprintf "`%s` changes its receiver, so it can't wrap a body" m)

(* `with h(1) in`, where [name] takes [n] arguments, and makes the
   implementation [made] *)
let with_too_few loc name ~made n given =
  let name = callee name in
  Diag.make loc
    ~notes:
      [
        sprintf
          "%s makes an implementation, `%s`, which `with` installs once it's \
           called with all its arguments"
          name made;
      ]
    ~help:(sprintf "give %s all its arguments" name)
    (sprintf "%s takes %d argument%s but was given %d" name n (plural n) given)

(* `with h in`, where [h], written [src], of type [shown], makes an
   implementation when it's called *)
let with_uncalled loc src shown =
  Diag.make loc
    ~notes:
      [
        sprintf
          "`with` installs an implementation, and `%s` makes one when it's \
           called"
          src;
      ]
    ~help:(sprintf "call it: `with %s() in ...`" src)
    (sprintf "`with` installs an implementation, but this is %s" (article shown))

(* What a `with` was given that's neither an implementation nor a
   wrapper. *)
type with_item =
  | Unknown_var of string  (** a variable whose type isn't known here *)
  | Unknown  (** something else whose type isn't known *)
  | Known of string  (** something of this type *)

let cant_install loc item =
  Diag.make loc
    ~notes:
      [
        "`with` installs an implementation of a dependency around its body, or \
         passes its body to a wrapper, a function whose last parameter is the \
         body";
      ]
    ~help:
      (match item with
      | Unknown_var x ->
          sprintf "say what it is where it's declared, like `%s: Clock`" x
      | Unknown ->
          "install something whose type is known here, like `Clock.frozen(t)`, \
           or a handler's call"
      | Known _ ->
          "give it an implementation, like `Clock.frozen(t)`, or a wrapper's \
           call without its last argument, like `retry(3)`")
    (match item with
    | Unknown_var _ | Unknown ->
        "`with` can't tell what this installs: its type isn't known here"
    | Known shown ->
        sprintf
          "`with` installs an implementation, or wraps its body, but this is %s"
          (article shown))

(* `with w(a) in body`, where [name]'s last parameter is `inout` *)
let wrapper_changes_body loc name =
  Diag.make loc
    ~notes:
      [
        "`with w(a) in body` calls `w(a, fn() => body)`, and a lambda isn't a \
         place to change";
      ]
    ~help:(call_outside name)
    (sprintf "%s changes its last argument, so it can't take a body"
       (callee name))

let wrapper_body_note =
  "`with w(a) in body` calls `w(a, fn() => body)`, so the wrapper's last \
   parameter is a function of no parameters"

let wrapper_last name _ x =
  let name = callee name in
  sprintf "%s's last parameter is %s, but a `with` passes it its body, a `fn()`"
    name (article x)

(* The body of a `with` that the wrapper [name] is given changes [var], a
   variable from outside it. *)
let body_changes_outer loc ~wrapper ~var =
  Diag.make loc
    ~notes:
      [
        sprintf
          "`with` passes its body to %s as a lambda, `fn() => ...`, which \
           captures the values of the variables it uses when it's made, so \
           changing them would have no effect outside"
          (callee wrapper);
      ]
    ~help:"give the body's result back as its value instead"
    (sprintf
       "the body of this `with` can't change `%s`, a variable from outside it"
       var)

(* ---- what a module writes (infer_top.ml) ---- *)

(* How a transparent parameter would outlive its call. *)
type escape = As_value | Captured | Kept_by_handler

(* The transparent parameter [name] escapes. [dep] is the dependency it's
   an implementation of, if it's one, and [handler_deps] what the
   function's body implements, if it's a handler. *)
let not_transparent loc ~name ~dep ~handler_deps escape =
  let what =
    match escape with
    | As_value -> "is used as a value here"
    | Captured -> "is captured by a lambda that outlives the call"
    | Kept_by_handler ->
        "is kept by the handler, whose operations run where a `with` installs \
         it"
  in
  let msg = sprintf "`%s` %s, so it isn't transparent" name what in
  match dep with
  | None ->
      Diag.make loc
        ~notes:
          [
            "a parameter whose type is written `fn(...)` can only be called, \
             or passed straight to another function";
          ]
        ~help:
          (sprintf
             "to keep it, name its rows, `%s: fn(...) ! ..e uses ..d`, or \
              remove the type and let it be inferred"
             name)
        msg
  | Some d ->
      Diag.make loc
        ~notes:
          [
            sprintf
              "a parameter whose type is a dependency's, `%s`, can only be \
               installed, with `with`, or passed straight to another function, \
               so what it needs is what its function uses"
              d;
          ]
        ~help:
          (match handler_deps with
          | Some deps ->
              (* what it needs, the handler needs where it's installed *)
              sprintf
                "to keep it, name what it needs, `%s: %s uses ..d`, and say \
                 the handler needs that: `for %s uses ..d`"
                name d (String.concat ", " deps)
          | None ->
              sprintf "to keep it, name what it needs: `%s: %s uses ..d`" name d)
        msg

(* `Result<Int, Int>`, at [loc]: its second argument isn't an error set. *)
let result_needs_set loc =
  Diag.make loc
    ~notes:
      [ "a `Result` holds a value or an error, which `attempt` keeps there" ]
    ~help:"write an error set, after `!`: `Result<Int, ! NotFound>`"
    "`Result`'s second argument is an error set"

(* An error set written as an argument of [t], which isn't `Result`. *)
let set_not_taken loc t =
  Diag.make loc
    ~help:
      "an error set goes after `!` in a signature or a function type, or in \
       `Result<T, ! ...>`"
    (sprintf "`%s` doesn't take an error set" t)

(* The help for a tag with two shapes in one written set. *)
let rename_one = "rename one of them"

(* ---- what a group leaves to be checked (infer_top.ml) ---- *)

(* Why a call brings in a dependency it seems not to: the function it
   calls calls a closure inside a `with` of the dependency, [dep], that
   still gets it from outside (Infer_top.settle_installs). [fn] is that
   function. *)
type withheld =
  | Same_row of { fn : string; dep : string }
      (** what's called inside the `with` uses what [fn] itself does *)
  | Several_withs of { fn : string; dep : string }
      (** the closure is called inside more than one `with` *)

let withheld = function
  | Same_row { fn; dep } ->
      sprintf
        "in `%s`, what's called inside the `with` that installs `%s` uses what \
         `%s` itself does: a parameter whose type is written `fn(...)`, or a \
         closure that's called outside the `with` too, gets only what's \
         installed outside it"
        fn dep fn
  | Several_withs { fn; dep } ->
      sprintf
        "`%s` calls a closure inside more than one `with`, so the closure gets \
         only what's installed outside all of them, not the `%s` one of them \
         installs"
        fn dep

(* A row that includes a parameter's errors, at [loc], where it can't. *)
let param_fails_here loc =
  Diag.make loc
    ~help:
      "write what the function passed can fail with in its parameter's type, \
       after `!`"
    "this can fail with whatever a function it was passed fails with, which \
     isn't allowed here"

(* What a public function's rows can't do, kept where they're closed. *)
type closed = Cant_fail | Cant_use | Cant_fail_or_use | Cant_need

(* The transparent parameter that's kept so: one written `fn(...)`, the
   `self` of a dependency's method, or another of a dependency's type. *)
type kept = Fn_param | Dep_self of string | Dep_param of string

(* The transparent parameter [name] of [fn] is kept where its rows are
   closed. *)
let kept_closed loc ~name ~fn kept closed =
  let what =
    match closed with
    | Cant_fail -> "fail"
    | Cant_use -> "use anything"
    | Cant_fail_or_use -> "fail or use anything"
    | Cant_need -> "need anything"
  in
  let note, help =
    match kept with
    | Fn_param ->
        ( sprintf
            "a parameter whose type is written `fn(...)` passes what it fails \
             with and uses on to `%s`'s callers, but here it's passed to \
             something that keeps it as a function that can't %s"
            fn what,
          sprintf
            "to keep it, name its rows, `%s: fn(...) ! ..e uses ..d`, and \
             write them where it's kept"
            name )
    | Dep_self d ->
        ( sprintf
            "a dependency's `self` needs what its method uses, but here it's \
             kept as `%s`, which needs nothing"
            d,
          sprintf
            "to keep it, name what it needs where it's kept, `(%s uses ..d)`, \
             and add `uses ..d` to `%s`"
            d fn )
    | Dep_param d ->
        ( sprintf
            "a parameter whose type is a dependency's, `%s`, needs what its \
             function uses, but here it's passed to something that keeps it as \
             an implementation that needs nothing"
            d,
          sprintf
            "to keep it, name what it needs, `%s: %s uses ..d`, and write it \
             where it's kept"
            name d )
  in
  Diag.make loc ~notes:[ note ] ~help
    (sprintf "`%s` is kept where it can't %s, so it isn't transparent" name what)

(* `uses Clock, ..d`: what a function that lists [deps] would write to use
   the named row [n] as well. *)
let uses_written deps n = "uses " ^ String.concat ", " (deps @ [ ".." ^ n ])

(* [what] uses the named row [n], at [loc], but what it's in ends in
   [other] already. *)
let two_named_rows loc what ~other n =
  Diag.make loc
    ~notes:
      [
        sprintf
          "a row ends in at most one named row, and what this is in already \
           uses `..%s`, so `..%s` can't be added"
          other n;
      ]
    ~help:
      (sprintf "name the two rows alike, `..%s`, if they can stand for the same"
         other)
    (sprintf "%s `..%s`, but what this is in already uses `..%s`" (user what) n
       other)

(* [what] uses the named row [n] in [fn], which declares what it uses but
   not [n]: it names [other], or else would write [uses]. *)
let named_row_undeclared loc what n ~fn ~other ~uses =
  Diag.make loc
    ~notes:
      [
        sprintf
          "`..%s` stands for whatever the closure or implementation it names \
           uses, and a function that declares its dependencies declares that \
           too"
          n;
      ]
    ~help:
      (match other with
      | Some other ->
          sprintf
            "`%s` names one row, `..%s`, which is all it can name: name this \
             one `..%s` too, where it's written"
            fn other other
      | None -> sprintf "add it to what `%s` uses: `%s`" fn uses)
    (sprintf "%s `..%s`, which `%s` doesn't declare" (user what) n fn)

(* [what] uses the named row [n] where nothing can end in it. *)
let named_row_not_allowed loc what n =
  Diag.make loc
    ~notes:
      [
        sprintf
          "`..%s` stands for whatever the closure or implementation it names \
           uses, and what this is in can't use more than it lists"
          n;
      ]
    ~help:
      (sprintf
         "use it where `..%s` can go: in the function that names it, or in a \
          lambda whose type isn't written"
         n)
    (sprintf "%s `..%s`, which isn't allowed here" (user what) n)

(* A call of a closure that fails with the named row [n], in [fn], which
   declares its errors but not [n]. *)
let named_errors_undeclared loc n ~fn =
  Diag.make loc
    ~notes:
      [
        sprintf
          "`..%s` stands for whatever the closure it names fails with, and a \
           function that declares its errors declares that too"
          n;
      ]
    ~help:
      (sprintf "add `..%s` to what `%s` declares it fails with, after `!`" n fn)
    (sprintf "this can fail with `..%s`, which `%s` doesn't declare" n fn)

(* A `with`'s body uses [deps], which what's outside it can't. *)
let with_body_uses loc deps =
  Diag.make loc
    ~notes:
      [
        "a closure called in a `with`'s body is called with what's installed \
         outside it too, and this one is called where more is installed than \
         outside";
      ]
    ~help:
      "call the closure only inside the `with`, or install what it uses \
       outside it too"
    (sprintf "this `with`'s body uses %s, which what's outside it can't"
       (* this quotes each name twice (B4 in the stage's plan), which is kept
          while restructuring changes no message *)
       (and_list (List.map code deps)))

(* ---- implementations (infer_top.ml) ---- *)

(* How an implementation's operation could fail with no more than the
   operation [op] declares, for the help when it does. *)
type impl_fix =
  | Map_call of {
      try_ : bool;
      call : string option;
      tag : string;
      into : string;
    }
      (** a call, as written, that fails with [tag]: map it to [into] with
          `match`, with `try` if the call fails with more *)
  | Give_value  (** a `fail`, where [op] can't fail *)
  | Fail_instead of string  (** a `fail`, where [op] can fail with this *)
  | Wrap of { given : string option; tag : string; into : string option }
      (** a function given by name, as written: a lambda that calls it, and maps
          [tag] to [into], if [op] can fail, or else handles it *)
  | Handle_inside
  | Map_inside of string

(* The implementation of [op] can fail with [shown], which [op] can't: it
   can fail only with [declared], the tags' names. *)
let impl_fails_more loc ~op ~shown ~declared fix =
  let help =
    match fix with
    | Map_call { try_; call; tag; into } ->
        sprintf "map it: `%smatch %s` with the arm `fail %s => fail %s`"
          (if try_ then "try " else "")
          (Option.value call ~default:"...")
          tag into
    | Give_value -> sprintf "`%s` can't fail: give a value here instead" op
    | Fail_instead d ->
        sprintf "fail with what `%s` can instead: `fail %s`" op d
    | Wrap { given; tag; into } -> (
        let given = match given with Some s -> code s | None -> "it" in
        match into with
        | None ->
            sprintf
              "give a lambda that calls %s and handles what it fails with, \
               with `match` and `fail` arms"
              given
        | Some d ->
            sprintf
              "give a lambda that calls %s and maps what it fails with, with \
               `match` and `fail` arms, to what `%s` can: `fail %s => fail %s`"
              given op tag d)
    | Handle_inside ->
        "handle what it fails with inside it, with `match` and `fail` arms"
    | Map_inside d ->
        sprintf
          "map what it fails with inside it, with `match` and `fail` arms, to \
           what it can: `fail %s`"
          d
  in
  Diag.make loc
    ~says:(sprintf "fails with %s" shown)
    ~notes:
      [
        (match declared with
        | [] -> sprintf "`%s` can't fail" op
        | ds -> sprintf "`%s` can fail only with %s" op (and_list ds));
      ]
    ~help
    (sprintf "this implementation can fail with %s, and `%s` can't" shown op)

(* The implementation of [op] fails with [tag], whose payload [op]
   declares as [shape]. *)
let impl_other_shape loc ~op ~tag ~shape =
  Diag.make loc
    ~notes:[ sprintf "`%s` declares `%s`'s payload as `%s`" op tag shape ]
    ~help:(sprintf "fail with `%s` as the operation declares it" tag)
    (sprintf "this implementation fails with a different `%s`" tag)

(* The implementation of [op], which can fail only with [declared], fails
   with whatever the named row [n] stands for. *)
let impl_fails_named loc ~op ~declared n =
  Diag.make loc
    ~notes:
      [
        (match declared with
        | [] -> sprintf "`%s` can't fail" op
        | ds -> sprintf "`%s` can fail only with %s" op (and_list ds));
      ]
    ~help:"handle what it passes on inside it, with `match` and `fail` arms"
    (sprintf
       "this implementation can fail with anything `..%s` stands for, and `%s` \
        can't"
       n op)

(* ---- associated values, `main` and tests (infer_top.ml) ---- *)

(* The associated value [name] is made from itself, through [chain], which
   starts and ends with it. *)
let made_from_itself loc name chain =
  Diag.make loc
    ~notes:
      [
        "an associated value is made once, when the program starts, so it \
         can't need itself to be made";
      ]
    ~help:
      (if List.length chain = 2 then "make it without using itself"
       else "make one of them without the other")
    (sprintf "`%s` is made from itself: %s" name (String.concat " → " chain))

(* How to write a call of [name], of [arity] parameters, in a help. *)
let call_written name arity = if arity = 0 then name ^ "()" else name ^ "(...)"

(* What the runtime calls, installing exactly some dependencies around it:
   `main`, around which it installs [runtime], or the test [name]. *)
type runner =
  | Main of string list
  | Test of {
      name : string;  (** as it's written, quoted *)
      real : string list;  (** the built-ins it gets the real one of *)
      faked : string list;  (** and those it gets the test one of *)
      group : (string option * string) option;
          (** the group it's in, if it's a group's test: the module, if it's
              another one's, and the group's name *)
    }

(* [runner] uses [dep], which it isn't given, at [loc], or as [needs] say.
   [real] is the built-in whose test one [dep] controls, if the test gets
   the real one, which it can't control. [maker] makes an implementation of
   [dep], if something does, and [declared] says whether [dep] is declared
   at all, so something could implement it. [short] is [dep]'s own name. *)
let not_installed loc runner ~dep ~short ~real ~maker ~declared ~needs ~why =
  let inside, missing, only =
    match runner with
    | Main runtime ->
        ( "inside `main`",
          sprintf "nothing installs `%s` before `main`" dep,
          sprintf "the runtime installs only %s" (and_list runtime) )
    | Test t ->
        ( "inside the test",
          sprintf "nothing installs `%s` in the test %s" dep t.name,
          match (t.real, t.faked) with
          | [], faked ->
              sprintf "a test gets only the test %s, and what controls them"
                (and_list faked)
          | real, [] ->
              sprintf "this test gets only the real %s" (and_list real)
          | real, faked ->
              sprintf
                "this test gets only the real %s, and the test %s, and what \
                 controls %s"
                (and_list real) (and_list faked)
                (if List.length faked = 1 then "it" else "them") )
  in
  let notes =
    match (runner, real) with
    | Test _, Some d ->
        [
          sprintf "the test asks for the real `%s`, which `%s` can't control" d
            short;
        ]
    | _ -> []
  in
  let fix =
    match runner with
    | Main _ -> None
    | Test t -> (
        match (real, t.group) with
        | Some d, _ ->
            Some
              (sprintf "remove `%s` from the test's `uses`, to get the test one"
                 d)
        | None, None -> None
        | None, Some (None, g) ->
            (* a group's test is installed in the group's `with` *)
            Some
              (sprintf
                 "install one around each of its tests, in the group's `with`: \
                  `group %s(...) with %s =`%s"
                 g
                 (match maker with Some m -> m | None -> dep ^ " { ... }")
                 (if maker = None then
                    ", an implementation that gives each of its operations"
                  else ""))
        | None, Some (Some m, g) ->
            (* another module's group, which this one can't change *)
            Some
              (sprintf
                 "`%s.%s` is another module's group, so pass one in: give the \
                  group a parameter of type `%s` that its `with` installs, and \
                  pass an implementation to it here"
                 m g dep))
  in
  let help =
    match (fix, maker, declared) with
    | Some fix, _, _ -> fix
    | None, Some m, _ -> sprintf "install one %s: `with %s in ...`" inside m
    | None, None, true ->
        sprintf
          "install one %s, with `with`: an implementation is a `%s { ... }` \
           that gives each of its operations"
          inside dep
    | None, None, false ->
        sprintf "remove it: nothing can implement `%s` yet" dep
  in
  Diag.make loc
    ~labels:
      (List.map (fun (l, what) -> (l, sprintf "%s `%s`" (user what) dep)) needs)
    ~notes:(notes @ List.map withheld why)
    ~help ~says:only missing

(* ---- signatures (infer_top.ml) ---- *)

(* Where a function's body's type comes from: what's declared, [shown],
   as its type if it's an associated value ([value]), or its result. *)
let declared_type ~value name shown =
  if value then sprintf "`%s` is declared to have the type `%s`" name shown
  else sprintf "`%s` is declared to return `%s`" name shown

let returns_unit = "a public function without `->` returns `Unit`"

(* What a public function without `->` would write as its result, its
   body's type [found], for the help. *)
type result_help =
  | Write_found  (** [found] itself *)
  | Say_dep of string
      (** [found] is a handler of several dependencies, whose type can't be
          written: one of them, this one *)
  | Say_dep_inside of { handler : string; written : string }
      (** a handler of several dependencies is inside [found]: [found] with it
          written as one of them *)

let write_result found = function
  | Write_found -> sprintf "add `-> %s` to the signature" found
  | Say_dep d ->
      sprintf
        "say which of its dependencies it gives an implementation of, `-> %s`: \
         the type of a handler of several can't be written"
        d
  | Say_dep_inside { handler; written } ->
      sprintf
        "say which of its dependencies `%s` gives an implementation of, `-> \
         %s`: the type of a handler of several can't be written"
        handler written

(* [name], a function of a group that uses another of it, is used as [f]
   but made [x]. *)
let used_as name f x =
  sprintf "`%s` is used here as `%s`, but its definition makes it `%s`" name f x

(* Why it has to be one type: the group's functions, or its associated
   values and functions, are checked at one. *)
let group_type ~values =
  if values then
    "values and functions that need each other are checked at a single type"
  else "functions that call each other are checked at a single type"

(* [fn] would have to use [param], the type parameter of [other], which
   calls it, and is declared at [declared]. *)
let others_param loc ~fn ~other ~param ~declared =
  Diag.make loc
    ~labels:[ (declared, sprintf "`%s` is declared here" param) ]
    ~notes:
      [
        sprintf
          "`%s` and `%s` call each other, and functions that call each other \
           are checked at a single type"
          fn other;
      ]
    ~help:
      (sprintf "remove the type parameter from `%s`, or break the cycle" other)
    (sprintf "`%s` would have to use `%s`, the type parameter of `%s`" fn param
       other)

(* The public value [fn], named [name] where it's declared, without a
   type: it's [shown]. *)
let untyped_value loc ~name ~fn shown =
  Diag.make loc
    ~help:(sprintf "write `pub let %s: %s`" name shown)
    ~notes:[ "public values spell out their type" ]
    (sprintf "the public value `%s` has no type" fn)

(* The parameter [name] of the public function [fn], without a type: it's
   [shown]. *)
let untyped_param loc ~name ~fn shown =
  Diag.make loc
    ~help:(sprintf "write `%s: %s`" name shown)
    ~notes:[ "public functions spell out their full signature" ]
    (sprintf "the parameter `%s` of the public function `%s` has no type" name
       fn)

(* A test's last line, of the type [f], which isn't `Unit`; [is_bool]
   says whether it's a `Bool`, which `assert` would check. *)
let test_body f _ =
  sprintf "a test's body is `Unit`, but this is %s" (article f)

let test_passes = "a test passes unless it panics or fails"

let test_body_help ~is_bool =
  if is_bool then "to check it, write `assert` before it"
  else "check it with `assert`, or write `let _ = ...` if you mean to drop it"

(* A program without `main`, or whose `main` takes parameters. *)
let no_main loc =
  Diag.make loc ~help:"add `fn main() = ...`, which is where the program starts"
    "this program has no `main` function"

let main_params loc =
  Diag.make loc ~help:"remove the parameters" "`main` can't take parameters"

(* ---- dependencies ---- *)

(* [f]'s body uses [dep], which it doesn't declare; [call] is the first
   call that uses it, and [why] why, if it's one of [withheld]. *)
let undeclared_use ?(why = []) (f : Ast.Resolved.fn_def) dep call =
  let why = List.map withheld why in
  let name = Ast.fn_name f in
  Diag.make f.name.loc
    ~labels:
      (match call with
      | Some (l, what) -> [ (l, sprintf "%s `%s`" (user what) dep) ]
      | None -> [])
    ~notes:
      ((if f.uses = None then
          "a public function without `uses` uses nothing, and its body is \
           checked against that"
        else sprintf "`%s`'s body can only use what its `uses` lists" name)
      :: why)
    ~help:
      (if f.uses = None then sprintf "add `uses %s`" dep
       else sprintf "add `%s` to its `uses`" dep)
    (sprintf "`%s` doesn't declare `%s`" name dep)

(* A handler whose operations or state use [dep], which its `uses`
   doesn't list ([written] says whether it has one). *)
let undeclared_need ~written (f : Ast.Resolved.fn_def) dep call =
  let name = Ast.fn_name f in
  Diag.make f.name.loc
    ~labels:
      (match call with
      | Some (l, what) -> [ (l, sprintf "%s `%s`" (user what) dep) ]
      | None -> [])
    ~notes:
      [
        (if written then
           sprintf
             "`%s`'s operations and state can only use what its `uses` lists, \
              which is what a `with` that installs it needs"
             name
         else
           "a public handler without `uses` needs nothing, and its operations \
            and state are checked against that");
      ]
    ~help:
      (if written then sprintf "add `%s` to its `uses`" dep
       else sprintf "add `uses %s` after what it implements" dep)
    (sprintf "the handler `%s` doesn't declare that it needs `%s`" name dep)

(* The handler [f] uses [dep], one it implements, at [call]: in its arms
   that would be the next implementation out, which is `outer`'s. *)
let handler_uses_itself (f : Ast.Resolved.fn_def) dep call =
  Diag.make
    (match call with Some (l, _) -> l | None -> f.name.loc)
    ?says:(Option.map (fun (_, what) -> sprintf "%s `%s`" (user what) dep) call)
    ~labels:
      (match call with
      | Some _ ->
          [ (f.name.loc, sprintf "`%s` implements `%s`" (Ast.fn_name f) dep) ]
      | None -> [])
    ~notes:
      [
        sprintf
          "a handler's operations run with what's installed outside its \
           `with`, so `%s` here would be the next `%s` out, which comes with \
           `outer` (stage 10)"
          dep dep;
      ]
    ~help:
      (match call with
      | Some _ ->
          sprintf
            "call it outside the handler, install an implementation of `%s` \
             around the call with `with`, or implement `%s` with a record of \
             functions instead"
            dep dep
      | None -> sprintf "remove `%s` from its `uses`" dep)
    (sprintf "a handler for `%s` can't use `%s`" dep dep)

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
   type, which is called, or used, after its type, as [item], `Stack.of`.
   [args] are the call's arguments, as written, if they can be printed. *)
let not_a_method (m : Ast.ident) (kind : Iface.op_kind) ~item args =
  let fix =
    match (kind, args) with
    | Value, _ -> item
    | _, shown when List.for_all Option.is_some shown ->
        item ^ "(" ^ String.concat ", " (List.filter_map Fun.id shown) ^ ")"
    | _ -> item ^ "(...)"
  in
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
      | Some (l, what) -> [ (l, sprintf "%s `%s`" (user what) dep) ]
      | None -> [])
    ~notes:
      [
        "an associated value is made once, when the program starts, so it \
         can't use a dependency";
      ]
    ~help:
      (sprintf "make it an associated function, `fn %s() uses %s = ...`"
         f.name.name dep)
    (sprintf "the associated value `%s` uses `%s`" (Ast.fn_name f) dep)

(* ---- errors (errors.md) ---- *)

(* The associated value [f] can fail with [tag], shown as [shape]; [from]
   is the first place it comes from, and what it is. *)
let value_fails (f : Ast.Resolved.fn_def) ~tag ~shape from =
  Diag.make f.name.loc
    ~labels:
      (match from with
      | Some (l, what) -> [ (l, sprintf "%s `%s`" (error_source what) tag) ]
      | None -> [])
    ~notes:
      [
        "an associated value is made once, when the program starts, so nothing \
         could handle an error it failed with";
      ]
    ~help:
      (sprintf
         "handle it here with `match`, or make it an associated function, `fn \
          %s() ! %s = ...`"
         f.name.name shape)
    (sprintf "the associated value `%s` can fail with `%s`" (Ast.fn_name f) tag)

(* Where an error came from, for a message about another shape of it. *)
type origin =
  | From of string  (** a call, as it's written, or a named error set *)
  | This of string  (** this `fail`, `Result` or `match` *)
  | On_line of string * int  (** the `fail`, `Result` or `match` on a line *)
  | Signature  (** the function's signature *)
  | Earlier_call
  | Written_here  (** written in the error set itself *)

let origin = function
  | From x -> sprintf "from `%s`" x
  | This k -> sprintf "from this `%s`" k
  | On_line (k, n) -> sprintf "from the `%s` on line %d" k n
  | Signature -> "from the signature"
  | Earlier_call -> "from an earlier call"
  | Written_here -> "written here"

(* One error set would hold two shapes of the tag [name]: [old] is where
   the one already there came from and its shape, and [new_] the same for
   the one coming in. *)
let two_shapes loc name ~old:(old_from, old_shape) ~new_:(new_from, new_shape)
    ~help =
  Diag.make loc
    ~notes:
      [
        sprintf "%s: `%s`" (origin old_from) old_shape;
        sprintf "%s: `%s`" (origin new_from) new_shape;
        "a tag is its name and its payload's types, so these are two errors \
         with one name";
      ]
    ~help
    (sprintf "`%s` has two shapes here" name)

(* A variable bound to an error, `Err(e)`, would make the error a value of
   its own (errors.md, "Keeping an error"), so it's matched by its tags. *)
let bound_error loc name =
  Diag.make loc
    ~notes:[ "an error is a value only inside the `Result` that holds it" ]
    ~help:"match its tags, like `Err(NotFound(id))`, or ignore it with `Err(_)`"
    (sprintf "`%s` would hold an error, which isn't a value" name)

(* `Err(...)` around something that isn't a tag: an error isn't a value
   on its own (errors.md, "Keeping an error"). *)
let err_made loc =
  Diag.make loc
    ~notes:
      [
        "an error isn't a value on its own: `Err` holds one written as its \
         tag, or one that `attempt` kept";
      ]
    ~help:
      "write the tag inside it, `Err(NotFound(id))`, or keep what a call fails \
       with: `attempt f()`"
    "`Err` holds an error, written as its tag"

(* `try Err(X)`, which would fail with [X]: that's `fail X`. *)
let try_err loc tag =
  Diag.make loc
    ~notes:
      [
        "`try` passes on an error a `Result` already holds; `fail` is the way \
         to fail with one written in place";
      ]
    ~help:(sprintf "write `fail %s`" tag)
    "this `try` fails with the error it's given"

(* A tag pattern, or a tag written as a value ([value]), with the wrong
   number of payload patterns or values. *)
let tag_arity ?(value = false) loc (c : Ast.ident) want given =
  Diag.make loc
    (sprintf "`%s`'s payload has %d value%s, but this %s has %d" c.name want
       (plural want)
       (if value then "tag" else "pattern")
       given)

(* A tag pattern for an error the set doesn't have; [tags] are those it
   has, as shown. *)
(* How many single-character edits turn [a] into [b] (the Levenshtein
   distance), for a name that's probably a misspelling of another. *)
let distance a b =
  let n = String.length b in
  (* [prev.(j)] is the distance from the part of [a] seen so far to the
     first [j] characters of [b] *)
  let prev = Array.init (n + 1) Fun.id in
  String.iteri
    (fun i ca ->
      let diag = ref prev.(0) in
      prev.(0) <- i + 1;
      for j = 1 to n do
        let here = prev.(j) in
        prev.(j) <-
          min
            (min (prev.(j) + 1) (prev.(j - 1) + 1))
            (!diag + if ca = b.[j - 1] then 0 else 1);
        diag := here
      done)
    a;
  prev.(n)

(* The name among [names] that [name] is most likely a misspelling of:
   the nearest, if it's near enough. *)
let nearest name names =
  let near n =
    let d = distance (String.lowercase_ascii name) (String.lowercase_ascii n) in
    if d <= max 2 (String.length name / 3) && d < String.length name then
      Some (d, n)
    else None
  in
  match List.sort compare (List.filter_map near names) with
  | (_, n) :: _ -> Some n
  | [] -> None

(* [c] matched in an error set that doesn't hold it; [tags] are what it
   holds, each its name and how it's shown. *)
let not_an_error (c : Ast.ident) ?(arm = false) tags =
  (* a `fail` arm matches what a call fails with, a tag inside `Err(...)`
     what a [Result] holds *)
  let holds = if arm then "fail with" else "hold" in
  Diag.make c.loc
    ~notes:
      [
        (match tags with
        | [] when arm -> "it can't fail at all"
        | [] -> "it holds no errors at all"
        | tags -> sprintf "it can %s %s" holds (and_list (List.map snd tags)));
      ]
    ~help:
      (match nearest c.name (List.map fst tags) with
      | Some n ->
          sprintf
            "did you mean `%s`? A tag that's written wrong is a different error"
            n
      | None ->
          "check the spelling: a tag that's written wrong is a different error")
    (sprintf "`%s` isn't one of the errors this can %s" c.name holds)

(* [c] matched, or written as a value ([value]), in an error set that's
   open: it holds whatever the function passed as [param] fails with,
   which no name can be checked against. *)
let tag_in_open_set (c : Ast.ident) ?(arm = false) ?(value = false) ~param tags
    =
  let holds = if arm then "can fail with" else "holds" in
  Diag.make c.loc
    ~notes:
      [
        sprintf
          "this %s %swhatever the function passed as `%s` fails with, which \
           could be anything"
          holds
          (match tags with
          | [] -> ""
          | tags -> and_list (List.map snd tags) ^ " and ")
          param;
      ]
    ~help:
      (if value then
         sprintf
           "write the errors `%s` can fail with in its type, after `!`, or \
            `match` on this with an `Err(_)` arm"
           param
       else
         sprintf
           "match those with `%s`, or write the errors `%s` can fail with in \
            its type, after `!`"
           (if arm then "fail _" else "Err(_)")
           param)
    (sprintf "`%s` can't be %s here, because the errors this %s aren't known"
       c.name
       (if value then "written" else "matched")
       holds)

(* A call no marker covers, of [callee], which can fail with [tags], as
   shown; [name_loc] is where the callee is written. *)
let unhandled_call loc ~name_loc callee tags =
  Diag.make loc
    ~labels:[ (name_loc, sprintf "it can fail with %s" (and_list tags)) ]
    ~help:"pass the errors on with `try`, or handle them with `match`"
    (sprintf "`%s` can fail, and nothing handles it" callee)

(* The same, for a call of [callee] whose errors are those of the
   function passed as the parameter [param]. *)
let unhandled_param loc ~name_loc callee param =
  Diag.make loc
    ~labels:
      [
        ( name_loc,
          sprintf
            "it can fail with whatever the function passed as `%s` fails with"
            param );
      ]
    ~help:"pass the errors on with `try`, or handle them with `match`"
    (sprintf "`%s` can fail, and nothing handles it" callee)

(* An `attempt` of a call of [callee], a transparent parameter of the
   public function [fn], whose errors are [fn]'s own; or a `match` with
   `fail` arms of one, if [handled]. *)
let kept_passed_on loc ~name_loc callee ~fn ~handled =
  Diag.make loc
    ~labels:
      [
        ( name_loc,
          sprintf
            "its type is written `fn(...)`, so what it fails with is passed on \
             to whoever calls `%s`"
            fn );
      ]
    ~notes:
      [
        "a transparent parameter's errors are its function's own, which its \
         signature says it passes on";
      ]
    ~help:
      (sprintf
         "to %s them, name their row where `%s`'s type is written, as in `%s: \
          fn() ! ..e`, or pass them on with `try`"
         (if handled then "handle" else "keep")
         callee callee)
    (if handled then
       sprintf "`match` can't handle what `%s` fails with here" callee
     else sprintf "`attempt` can't keep what `%s` fails with here" callee)

(* A `try` or `attempt`, at [loc], that covers nothing that can fail;
   [hint] is why it may not, if something's known. *)
let covers_nothing ?hint loc keyword =
  let help = Option.map hint_help hint in
  Diag.make loc
    ~notes:
      [
        sprintf
          "`%s` marks the calls that can fail, so a reader can see where the \
           code can stop"
          keyword;
      ]
    ~help:(Option.value help ~default:(sprintf "remove the `%s`" keyword))
    "nothing here can fail"

(* A `fail` arm, at [loc], of a `match` whose subject can't fail. *)
let cannot_fail_arm loc =
  Diag.make loc
    ~notes:[ "a `fail` arm matches an error of what the `match` looks at" ]
    ~help:"remove the `fail` arms"
    "nothing here can fail, so this `fail` arm can never match"

(* How a message names the function [f]: `pub fn transfer`. *)
let fn_named (f : Ast.Resolved.fn_def) =
  sprintf "%sfn %s" (if f.pub then "pub " else "") (Ast.fn_name f)

(* [f]'s body can fail with [tag], shown as [shape], which its signature
   doesn't list; [from] is the first place it comes from, and what it is. *)
let undeclared_error (f : Ast.Resolved.fn_def) ~tag ~shape from =
  let fn = fn_named f in
  Diag.make f.name.loc
    ~labels:
      (match from with
      | Some (l, what) -> [ (l, sprintf "%s `%s`" (error_source what) tag) ]
      | None -> [])
    ~notes:
      [
        (if f.errors = None then
           sprintf
             "a public function without `!` can't fail, and its body is \
              checked against that"
         else
           sprintf "`%s` can only fail with what's after its `!`"
             (Ast.fn_name f));
      ]
    ~help:
      (if f.errors = None then
         sprintf "add `! %s` to its signature, or handle it here with `match`"
           shape
       else sprintf "add `%s` after `!`, or handle it here with `match`" shape)
    (sprintf "`%s` can fail with `%s`, but its signature doesn't say so" fn tag)

(* [f]'s signature lists [tag], written at [loc] (through the named set
   [via], if it's in one), but nothing in its body can fail with it. *)
let unused_error (f : Ast.Resolved.fn_def) ~tag ~via loc =
  Diag.make loc
    ~notes:
      ((match via with
         | Some set -> [ sprintf "`%s` is in `%s`" tag set ]
         | None -> [])
      @ [
          "a signature lists exactly what a function can fail with, so its \
           callers handle nothing that can't happen";
        ])
    ~help:
      (match via with
      | Some set ->
          sprintf "write the errors it can fail with in place of `%s`" set
      | None -> sprintf "remove `%s` from after `!`" tag)
    (sprintf "`%s` says it can fail with `%s`, but nothing in it can"
       (fn_named f) tag)

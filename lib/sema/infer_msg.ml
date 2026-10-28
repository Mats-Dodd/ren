(* The wording of inference's errors, all of it: infer_expr.ml and the
   modules beside it, and infer_top.ml, find what's wrong and pass it here
   as data (names, types as they're printed, locations, and variants for
   the kinds of things), and the functions here say it, building each
   error's message, notes and help. A mismatch's message is a function of
   the two types as printed, which Infer_report.unifies gives it. *)

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

(* "a `Bool`", "an `Int`" (diag.ml) *)
let article = Diag.article

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

(* Two error sets of `Result`s inside [found] and [expected], where one
   holds tags the other can't, being closed: those tags, and what the
   other holds. *)
let rec sets_clash found expected =
  let pairs a b =
    if List.length a = List.length b then
      List.find_map (fun (x, y) -> sets_clash x y) (List.combine a b)
    else None
  in
  let beyond e1 e2 =
    let have = row_names e2 in
    match
      List.filter
        (fun (l : label) -> not (List.mem l.name have))
        (fst (row_parts e1))
    with
    | _ :: _ as extra when row_tail e2 = None -> Some (extra, fst (row_parts e2))
    | _ -> None
  in
  match (repr found, repr expected) with
  | TErrors e1, TErrors e2 -> (
      match beyond e1 e2 with Some c -> Some c | None -> beyond e2 e1)
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
  | TImpl i -> row i.fails
  | TVar _ | TSkol _ | TError -> []

(* Notes for a mismatch between [found] and [expected] that the two types
   alone don't explain: the type parameters in them, and a parameter that's
   [inout] in one and not the other. Also the help that goes with the
   latter, unless the caller gave one. [type_params] is false when the
   caller's notes say what the type parameters are. *)
let mismatch_notes ?help ?(type_params = true) ~found ~expected () =
  let params =
    if not type_params then []
    else
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
          "a function that changes its argument (`&`) can't stand in for \
           one that only reads it: its caller wouldn't pass the argument with \
           `&`, so the change would be lost";
        ]
    | Some Read ->
        [
          "a function that only reads its argument can't stand in for one that \
           changes it (`&`)";
        ]
    | None -> []
  in
  let help =
    match (help, clash) with
    | None, Some Inout ->
        Some
          "pass it only where the parameter's type says `fn(&...)`, or \
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

(* The module [home]'s private item [name], used by a test, which sees
   what an importer sees (testing.md, "Tests are specifications"). Resolve
   reports what it can name; this is a member found through a value's
   type. *)
let private_in_test ?owner loc ~home name =
  (* a constructor is made `pub` with its type, [owner] *)
  let mark =
    match owner with
    | Some t -> sprintf "mark its type, `%s`, `pub`" t
    | None -> "mark it `pub`"
  in
  Diag.make loc
    ~notes:[ sprintf "a test is a specification of `%s`'s interface" home ]
    ~help:
      (sprintf "%s, or explore it in the console: `ren console %s`" mark home)
    (sprintf "`%s` is private, and a test sees what an importer sees" name)

(* Another module's opaque type [p], looked inside: made, read, or used as
   what it's represented as, none of which this module can see. With
   [test], it's the module's own, and a test, which sees what an importer
   sees (testing.md, "Tests are specifications"), looked inside it. *)
let representation_private ?(test = false) (p : Path.t) =
  if test then
    ( sprintf "`%s` is opaque, and a test sees what an importer sees" p.name,
      sprintf "explore it in the console: `ren console %s`" p.home )
  else
    ( sprintf "`%s`'s representation is private to `%s`" p.name p.home,
      sprintf "use a function from `%s` to make or read one" p.home )

let opaque_private ?(test = false) loc (td : Iface.type_decl) =
  let msg, help = representation_private ~test td.path in
  let notes =
    if test then
      [ sprintf "a test is a specification of `%s`'s interface" td.path.home ]
    else []
  in
  Diag.make loc ~notes ~help msg

(* What the module's own opaque type [td] is represented as, as the module
   writes it. *)
let representation ~names (td : Iface.type_decl) =
  match td.body with
  | Opaque (Rep rep) ->
      let s : Ty.scheme =
        {
          ty = rep;
          names = List.mapi (fun i n -> (i, n)) td.params;
          reqs = [];
          row_reqs = [];
          modes = [];
          defaults = [];
        }
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
let not_in_type ~names ?(expected = false) ?(test = false) loc (c : Ast.ident)
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
    | Dep _ | Dep_alias _ ->
        ( sprintf "`%s` is a dependency, so it has no constructors" t,
          Some
            (sprintf
               "an implementation of it is a handler, `handler h() for %s`, \
                with an arm for each operation under it, called as `h()`"
               t) )
    | Builtin ->
        ( sprintf "`%s` is built in, and has no constructors" t,
          Some "its values are written directly, like `1`, `true` or `[1, 2]`"
        )
    | Opaque (Hidden _) ->
        let msg, help = representation_private ~test td.path in
        (msg, Some help)
    | Opaque (Rep _) ->
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
    | [ { fty = Var _; _ } ] when given = 2 || given = 3 ->
        (* `Some(k, v)`, meant as a tuple (operators.md, "Tuples"), for a
           field of any type *)
        sprintf
          "to give it a tuple, put the tuple in parentheses of its own: \
           `%s((%s))`"
          c.name
          (if given = 2 then "a, b" else "a, b, c")
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
let not_a_record ~names ?(test = false) loc (td : Iface.type_decl) =
  match td.body with
  | Opaque (Hidden _) -> opaque_private ~test loc td
  | Opaque (Rep _) -> opaque_own ~names loc td "has no fields"
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
let op_of_value ~names ?recv (f : Ast.ident) dep (ops : Iface.field list) =
  let d = names dep in
  if List.exists (fun (o : Iface.field) -> o.fname = f.name) ops then
    Diag.make f.loc
      ~notes:
        [
          sprintf
            "a description of `%s` is called as a method, `%s.%s(...)`, which \
             installs it for the call"
            d
            (Option.value recv ~default:"h")
            f.name;
        ]
      ~help:
        (sprintf "call it: `%s.%s(...)`"
           (Option.value recv ~default:"h")
           f.name)
      (sprintf "`%s` is an operation of `%s`: an operation is called, not read"
         f.name d)
  else
    Diag.make f.loc
      ~help:(sprintf "its operations: %s" (quote (field_names ops)))
      (sprintf "`%s` has no operation named `%s`" d f.name)

(* ---- inline handlers (foundations.md, decision 3) ---- *)

(* `handler fn(...) => ...` where a description of [dep] is wanted, which
   has [n] operations, not one. *)
let inline_several loc ~dep n =
  Diag.make loc
    ~help:(sprintf "declare a handler with an arm for each: `handler name() for %s`"
       dep)
    (sprintf
       "an inline handler implements a dependency of one operation, and `%s` \
        has %d"
       dep n)

(* One where what's wanted isn't known to be a description of one
   dependency. *)
let inline_unknown loc =
  Diag.make loc
    ~help:"write the type it's kept as: `let h: D = handler fn(...) => ...`"
    "which dependency this inline handler implements isn't known here"

(* One that reads [name], a block, from where it's written: what it
   captures is copied into its description, which is data. *)
let inline_block loc name =
  Diag.make loc
    ~help:"pass the data it needs, or make the behaviour a dependency"
    (sprintf "an inline handler's captures are data, and `%s` is a block" name)

(* One that calls `next`, of [dep]. *)
let inline_next loc ~dep =
  Diag.make loc
    ~help:(sprintf "declare a handler `over %s` to call the one under it" dep)
    "an inline handler doesn't go over another, so it has no `next`"

(* An inline handler of [dep]'s operation [op], which takes [n]
   parameters, written with [given]. *)
let inline_arity loc ~dep ~op n given =
  Diag.make loc
    ~help:(sprintf "write one for each: `handler fn(%s) => ...`"
       (String.concat ", " (List.init n (fun i -> sprintf "x%d" (i + 1)))))
    (sprintf "`%s.%s` takes %d parameter%s, and this inline handler %d" dep op
       n (plural n) given)

(* `s.get()`, where `s` is a description whose state can fail to start
   (handlers.md, "State that can fail to start"): a method call installs it
   for the call, and one that can fail is installed with `with`, whose
   errors show. [call] is the operation's call, `Store.get()`. *)
let method_fails loc ~recv ~call =
  Diag.make loc
    ~help:(sprintf "install it: `with %s in %s`" recv call)
    (sprintf "`%s` can fail to start, so it isn't called as a method" recv)

(* `c.get(1)`, where `c` goes over another implementation of [dep],
   which only a `with` can put under it. *)
let method_over loc ~recv ~dep ~call =
  Diag.make loc
    ~help:(sprintf "install it over one: `with %s over %s in %s`" recv dep call)
    (sprintf "`%s` goes over another `%s`, so it isn't called as a method" recv
       dep)

(* `Users { get: fn(id) => id * 2 }`, a record literal of the dependency
   [dep]: [arms] are its fields as a handler's arms, `get(id) => id * 2`,
   and [name] a name for the handler (deps.md, "Implementations"). *)
let impl_record_made loc ~dep ~name arms =
  let head = sprintf "handler %s() for %s" name dep in
  Diag.make loc
    ~says:(sprintf "a record of `%s`'s operations" dep)
    ~notes:
      [
        "a record holds data, and code that's kept, like an implementation's \
         operations, is a handler";
      ]
    ~help:
      (match arms with
      | [] -> sprintf "write a handler: `%s`, with its arms under it" head
      | [ arm ] ->
          sprintf "write a handler, `%s`, with the arm `%s` under it" head arm
      | arm :: _ ->
          sprintf
            "write a handler, `%s`, with an arm for each operation under it, \
             like `%s`"
            head arm)
    (sprintf "an implementation of `%s` is a handler, not a record" dep)

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
  | Needs_more of { extra : string list; slot : string }
      (** a description that needs [extra] beyond what the type wanted lets it,
          whose `uses` is the most it may need (foundations.md, decision 3);
          [slot] is the type wanted with those added, as it's written *)
  | Can_fail of { ty : string; alone : bool }
      (** an implementation that can fail to start where one that can't is
          wanted, of the type [ty]; [alone] if it's the whole type, not inside
          another, `Box<Rates>` *)
  | Over_differs of { deps : string; over : bool }
      (** an implementation of [deps] that goes over another where one that
          doesn't is wanted, if [over], or the other way round (handlers.md,
          "`over`") *)
  | Shapes of string * string list
      (** the tag with two shapes, and the shapes *)
  | Fails_where_none of string list
      (** a function that fails with these where nothing can fail *)
  | Fails_beyond of string list * string list
      (** a function that fails with the first where only the second can *)
  | Holds_beyond of string list * string list
      (** a `Result` that can hold the first, where one that holds only the
          second, and no more, is wanted *)
  | Private of Path.t * bool
      (** another module's opaque type, or, [true], the module's own, in a test
          ([representation_private]) *)
  | Narrowed_only_written of {
      all : string;
      part : string;
      fix : string option;
    }
      (** an implementation of several dependencies, of type [all], and one of
          some of them, [part], which it's narrowed to only where a written type
          asks for that (deps.md, "Implementations"); [fix] is what the caller
          says to write, if it knows better than where it's made or passed *)
  | Other_handler of {
      all : string;
      deps : string list;
      dep : string;
      here : bool;
    }
      (** an implementation of [deps], of type [all], where one of [dep], which
          isn't among them, is wanted; or, if not [here], one of [dep] where
          that one, given first, is *)

let behind_note = function
  | Needs_more { extra; slot } ->
      ( [
          sprintf
            "a stored description's `uses` is the most it may need, and this \
             one needs %s too"
            (and_list extra);
        ],
        sprintf "add %s where the type is written: `%s`"
          (match extra with [ _ ] -> "it" | _ -> "them")
          slot )
  | Can_fail { ty; alone } ->
      (* `uses` after `->` is the function's, so a dependency's own is
         parenthesized; inside `Box<...>` it needs nothing *)
      let ty = if alone then sprintf "(%s)" ty else ty in
      ( [
          "an implementation's type says what it can fail to start with, so \
           one that can fail can't stand in for one that can't";
        ],
        sprintf "say it can fail where its type is written: `%s`" ty )
  | Over_differs { deps; over = true } ->
      ( [
          sprintf
            "an `over %s` goes over another `%s`, which it calls with `next`, \
             so it can't stand in for one that doesn't"
            deps deps;
        ],
        sprintf
          "write `over %s` where its type is written, and install it with \
           `over`"
          deps )
  | Over_differs { deps; over = false } ->
      ( [
          sprintf
            "a `%s` implements every operation itself, so it can't stand in \
             for an `over %s`, which goes over another"
            deps deps;
        ],
        sprintf
          "write `%s` where its type is written, or pass a handler declared \
           `over %s`"
          deps deps )
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
  | Holds_beyond (extra, wanted) ->
      ( [
          sprintf
            "a `Result` can hold %s here, and the other %s: what one can hold \
             is fixed once what made it is checked, so neither stands for the \
             other"
            (and_list extra)
            (if wanted = [] then "no error" else "only " ^ and_list wanted);
        ],
        "use `Result`s that can hold the same errors here, or `match` on one \
         instead" )
  | Private (p, test) ->
      let note, help = representation_private ~test p in
      ([ note ], help)
  | Narrowed_only_written { all; part; fix } ->
      ( [
          sprintf "`%s` is %s only where a written type asks for one" all
            (article part);
        ],
        match fix with
        | Some fix -> fix
        | None ->
            sprintf
              "write it where it's made or passed, `let x: %s = ...` or `fn \
               f(x: %s)`"
              part part )
  | Other_handler { all; deps; dep; here } ->
      ( [
          sprintf "%s is an implementation of %s, not of `%s`" (article all)
            (and_list deps) dep;
        ],
        let impl =
          if String.contains dep '&' then "a handler for each of them"
          else sprintf "a handler for `%s`" dep
        in
        if here then sprintf "give an implementation of `%s` here: %s" dep impl
        else
          sprintf "give an implementation of `%s` instead of the `%s`: %s" dep
            all impl )

(* A mismatch between [found] and [expected], printed as [f] and [x], at
   [loc]: worded by [msg] if the caller has a way to say it, and explained
   by the caller's [notes] and [help] and by what's [behind] it. *)
let mismatch loc ?msg ~notes ?help ~labels ?type_params ~found ~expected ~f ~x
    behind =
  let msg =
    match msg with
    | Some m -> m
    | None -> sprintf "expected `%s`, found `%s`" x f
  in
  let more, help = mismatch_notes ?help ?type_params ~found ~expected () in
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

(* What an `Int` is wanted for: a side of the operator [op], an index, or
   an end of a range. *)
type int_use = Operator of string | Indexing | Ranging

let int_note = function
  | Operator op -> sprintf "`%s` works on `Int`s" op
  (* this reads oddly, but restructuring changes no message *)
  | Indexing -> "`an index` works on `Int`s"
  | Ranging -> "a range, `a..b`, counts from one `Int` up to another"

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

(* The help for [written], code of the type [p], where a `Bool` has to
   be, which nothing else stands for (operators.md, "Conditions are
   `Bool`"): what to ask of it instead, if anything can be said. *)
let not_bool_help (p : Path.t) ~written =
  let w = Option.value written ~default:"x" in
  (* `(a + b).len()`, for a method called on an operator's result *)
  let w = if String.contains w ' ' then "(" ^ w ^ ")" else w in
  if
    p = Path.prelude "Array" || p = Path.prelude "Map" || p = Path.prelude "Set"
  then
    Some
      (sprintf "to ask whether it has anything in it, write `%s.len() > 0`" w)
  else if p = Path.prelude "Str" then
    Some (sprintf "to ask whether it has anything in it, write `%s != \"\"`" w)
  else if p = Path.prelude "Option" then
    Some
      (sprintf
         "to ask whether it holds a value, write `%s.is_some()`, or `match` it \
          to use the value"
         w)
  else None

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

(* A block [name] passed where its callee gives it dependencies its type
   doesn't list (Infer_expr.check): what it uses was found where it's
   written, so it can't take them. [param] says it's a parameter, not a
   `let`, and [expected] is the type it's passed as. *)
let block_lists_less =
  "a block is given only the dependencies its type lists, and this one's lists \
   fewer than its callee gives"

let block_lists_less_help ~name ~param expected =
  if param then sprintf "list them in `%s`'s type: `%s: %s`" name name expected
  else
    sprintf "write its type where it's written: `let %s: %s = fn ...`" name
      expected

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

(* an `if` whose branches are an implementation of several dependencies
   and one of some of them, [part] *)
let if_produces part =
  sprintf "say what the `if` produces: `let x: %s = if ...`" part

let if_branches = "both branches of an `if` have to produce the same type"

let no_else f _ =
  sprintf "this `if` has no `else`, so it can't produce %s" (article f)

let no_else_help = "add an `else` branch for when the condition is false"

let element_before f x =
  sprintf "this element is %s, but the elements before it are %s" (article f)
    (article x)

let not_indexable f _ =
  sprintf "only an `Array` can be indexed, but this is %s" (article f)

(* `x[a..b]` of what isn't an `Array`, a `Str` or `Bytes` *)
let not_sliceable f _ =
  sprintf "only an `Array`, a `Str` or `Bytes` can be sliced, but this is %s"
    (article f)

(* `m[k]`, where [m] is a `Map`: [map] and [key] as they're written, if
   they can be printed. *)
let map_indexed loc ~map ~key =
  Diag.make loc
    ~notes:[ "a key that isn't there is ordinary, so it's asked for" ]
    ~help:
      (match (map, key) with
      | Some m, Some k ->
          sprintf "write `%s.get(%s)`, which gives an `Option`" m k
      | _ -> "use `get`, which gives an `Option`")
    "a `Map` isn't indexed with `[]`"

let assigned f x =
  sprintf "this is %s, but it's being assigned to %s" (article f) (article x)

(* The help where an implementation of several is assigned to [var],
   whose type isn't written, and was one of some of them, [part]. *)
let assigned_var var part =
  sprintf "write `%s`'s type where it's declared: `var %s: %s = ...`" var var
    part

let not_iterable f _ =
  sprintf
    "a `for` loop goes over an `Array`, a `Map`, a `Set` or a cursor, but this \
     is %s"
    (article f)

(* `x = ...` in `for x in &c` over a cursor, where `&` is the cursor's:
   [x] is what it gave, a value of its own. *)
let cursor_elem_changed loc x =
  Diag.make loc
    ~notes:
      [
        "over a cursor, `&` is what advances the cursor, and each `" ^ x
        ^ "` is a value it gave";
      ]
    ~help:(sprintf "change a copy: `var y = %s`" x)
    (sprintf "changing `%s` changes nothing the loop goes over" x)

(* `for i, x in c` over a cursor, which has no places to number. *)
let cursor_index loc ~index =
  Diag.make loc
    ~notes:
      [
        "an index is where an element is in an array, a map or a set, and a \
         cursor gives each element without one";
      ]
    ~help:
      (sprintf "count them with a `var %s = 0`, and `%s += 1` at the end of \
                the body"
         index index)
    "a `for` over a cursor has no index"

(* `for x in c`, where [c]'s type has a `next`, [item], that isn't a
   cursor's. *)
let not_a_cursor loc ~item =
  Diag.make loc
    ~notes:
      [
        "a cursor's type has a method `next(inout self) -> Option<T>`, which \
         can't fail or use a dependency, and the loop goes over the `T`s it \
         gives";
      ]
    ~help:(sprintf "give `%s` that signature" item)
    (sprintf "a `for` loop goes over a cursor, but `%s` isn't a cursor's" item)

(* `for x in &m`, of a [what], a map or a set: its entries aren't places,
   since a key that changed would be in the wrong place. *)
let changes_entries loc ~what =
  Diag.make loc
    ~help:
      (if what = "map" then
         "go over a copy, `for (k, v) in m`, and `&m.set(k, ...)` what changes"
       else "go over a copy, `for x in s`, and `&s.add(...)` what changes")
    (sprintf "a `for` can't change a %s's %s in place" what
       (if what = "map" then "entries" else "members"))

(* `for (a, b) in &xs`, over an array, [over] as it's written: a loop
   that changes each element names it, the place it changes. *)
let changed_taken_apart loc ~over =
  let xs = Option.value over ~default:"xs" in
  Diag.make loc
    ~help:
      (sprintf
         "write `for x in &%s`, and change `x`; to read its parts, take it \
          apart inside the loop"
         xs)
    "a `for` that changes each element names it, and can't take it apart"

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

(* A tuple pattern, of the parts [ps], for a tuple of [n] parts: the
   pattern with a part for each, keeping the parts it has, and `_` for
   those it's missing. *)
let tuple_parts_help (ps : Ast.Resolved.pattern list) n =
  let rec shown (p : Ast.Resolved.pattern) =
    let args ps = "(" ^ String.concat ", " (List.map shown ps) ^ ")" in
    match p.pkind with
    | PVar b -> b.ident.name
    | PInt n -> Int64.to_string n
    | PBool b -> string_of_bool b
    | PCon (c, []) -> c.name.name
    | PCon (c, ps) -> c.name.name ^ args ps
    | PTuple ps -> args ps
    | PWild | PFail _ | PFail_any | PFail_in _ | POr _ -> "_"
  in
  let parts =
    List.init n (fun i ->
        match List.nth_opt ps i with Some p -> shown p | None -> "_")
  in
  sprintf "the tuple has %d parts, so take it apart with %d: `(%s)`" n n
    (String.concat ", " parts)

(* A tuple pattern for [shown], which isn't a tuple. *)
let not_a_tuple_help shown =
  sprintf "`%s` isn't a tuple, so name it whole instead, like `x`" shown

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

(* The help when what a function or lambda uses can't take the
   dependencies [deps], as its type says: it's used as a value of a type
   that lists what it uses, like an operation's block parameter, `fn()
   uses Clock`, since one whose own type
   is written, or a lambda's checked against one, isn't closed until it's
   checked. *)
let closed_uses_help deps =
  sprintf
    "add %s to the `uses` of the type it's used as, `fn() uses ...`, or \
     install %s around this, with `with`"
    (and_list deps)
    (match deps with [ _ ] -> "it" | _ -> "them")

(* [what] uses the dependencies [deps], as a message names them, which
   what it's in can't, at [loc]. *)
let cant_use loc what deps =
  let shown =
    match deps with
    | [] -> "more than what it's in can"
    | ns -> and_list ns ^ ", which what it's in can't"
  in
  Diag.make loc
    ~notes:
      [
        "a function or lambda uses everything its calls use, and everything \
         the implementations its `with`s install need, and the type of what \
         this is in says it can't use all of that";
      ]
    ~help:
      (if deps = [] then
         "add what it uses to the `uses` of the type it's used as, `fn() uses \
          ...`"
       else closed_uses_help deps)
    (sprintf "%s %s" (user what) shown)

(* Code that can fail with [shown] where nothing can. In a handler's
   state or `finally` ([in_state]), it's the handler, [who], `pub handler
   h`, that doesn't say it can: [after] is what's after its name, `over
   Sql`, where its `!` goes (handlers.md, "State that can fail to start").
*)
let cant_fail_here loc ~in_state shown =
  match in_state with
  | Some (who, after) ->
      Diag.make loc
        ~notes:
          [
            "a `with` that installs it fails with what its state and `finally` \
             fail with";
          ]
        ~help:(sprintf "add `! %s` after `%s`" shown after)
        (sprintf "%s doesn't say it can fail with `%s`" who shown)
  | None ->
      Diag.make loc
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
type error_source =
  | Call_fails
  | Install_fails
  | Fails
  | Result_holds
  | Match_leaves

let error_source = function
  | Call_fails -> "this call can fail with"
  | Install_fails -> "installing this can fail with"
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
  | Installs_only
      (** a `try with`, which covers only installing its items (compiler.md,
          "Stage 11a", "`try with`") *)

let hint_help = function
  | Installs_only -> "installing these can't fail: remove the `try`"
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

(* What a `with` was given that isn't an implementation. *)
type with_given =
  | Unknown  (** something whose type isn't known, but a variable's *)
  | Known of string  (** something of this type *)

let cant_install loc item =
  Diag.make loc
    ~notes:
      [
        "`with` installs an implementation of a dependency, a handler, around \
         its body";
      ]
    ~help:
      (match item with
      | Unknown ->
          "install something whose type is known here, like `Clock.frozen(t)`, \
           or a handler's call"
      | Known _ -> "give it an implementation, like `Clock.frozen(t)`")
    (match item with
    | Unknown ->
        "`with` can't tell what this installs: its type isn't known here"
    | Known shown ->
        sprintf "`with` installs an implementation, but this is %s"
          (article shown))

(* `with retry(3) in body`: [name], the item's function, takes a block,
   and [call] is the item called with the body as one, `try retry(3) fn()
   => ...`. *)
let wrapper_in_with loc name call =
  Diag.make loc ~says:"takes a block"
    ~notes:
      [
        sprintf
          "%s is a function that runs a block, so it's called with the body as \
           one"
          (callee name);
      ]
    ~help:(sprintf "call it: `%s`" call)
    "`with` installs only handlers"

(* `with c in`, where nothing has said what the variable [var] is, which
   could install one dependency or several: [fix] is its declaration with a
   type written, `fn run(c: Clock)` (deps.md, "Implementations"), if it's a
   parameter or a `let`'s, or [""] if what to write can't be guessed *)
let with_unknown loc ~var ~fix =
  Diag.make loc ~says:"its type isn't written"
    ~help:
      (match fix with
      | Some "" ->
          sprintf "write `%s`'s type, the dependencies it implements" var
      | Some fix -> sprintf "write it: `%s`" fix
      | None ->
          "write the type of what it installs where that's made or passed in, \
           as a `let`'s or a parameter's")
    (sprintf "`with` can't tell what `%s` installs" var)

(* ---- a `with` is a set (handlers.md) ----

   Items are written as they're shown in the source, [src] or a name, so a
   help can write them. *)

(* An item, at [loc], installs [deps], which the item at [first] did: [all]
   is what the first is, if it's a handler of several, `Clock &
   TestClock`; [chain], if one of them goes over what's outside, the two
   as one chain. *)
let installed_twice loc ~deps ~first ~chain ~all =
  let dep = List.hd deps in
  Diag.make loc ~says:"and again here"
    ~labels:
      [
        ( first,
          match all with
          | Some all -> sprintf "is a `%s`" all
          | None -> sprintf "installs `%s`" dep );
      ]
    ~notes:
      [ "a `with` installs each dependency once, so its order never matters" ]
    ~help:
      (match chain with
      | Some chain -> sprintf "put one over the other: `%s`" chain
      | None ->
          sprintf
            "to put one in front of another, use a handler declared `over %s`"
            (String.concat " & " deps))
    (sprintf "this `with` installs %s twice" (and_list deps))

(* Two items of a `with`, [a] at [loc] and [b] at [bloc], each needing what
   the other installs: [a] needs [a_needs], and [b] [b_needs]. *)
let needs_each_other loc ~a ~a_needs ~bloc ~b ~b_needs =
  Diag.make loc
    ~says:(sprintf "needs `%s`, which `%s` installs" a_needs b)
    ~labels:[ (bloc, sprintf "needs `%s`, which `%s` installs" b_needs a) ]
    ~notes:
      [
        "an item's needs are met by the other items in its `with`, installed \
         around it, so two can't each need the other";
      ]
    ~help:"install one of them in a `with` around this one"
    (sprintf "`%s` and `%s` in this `with` each need what the other installs" a
       b)

(* [link], an implementation of [deps] declared `over` them, installed with
   nothing under it. *)
(* `with h as A`, where [h] doesn't implement what [A] names
   (compiler.md, "Generic dependencies"). *)
let installed_as_wrong loc ~link ~as_ ~implements =
  Diag.make loc
    ~help:
      (sprintf "`%s` implements `%s`: install it as `%s` or as an alias of it"
         link implements
         (match String.index_opt implements '<' with
         | Some i -> String.sub implements 0 i ^ "<...>"
         | None -> implements))
    (sprintf "`%s` can't be installed as `%s`" link as_)

(* `as` after a chain, or after an item that goes over what's outside:
   only one implementation is installed as an alias. *)
let as_on_chain loc ~link =
  Diag.make loc
    ~help:
      "install the chain without `as`, or make its top the one implementation \
       of the item"
    (sprintf "`as` follows one implementation, and `%s` is part of a chain" link)

(* A call of a generic dependency's operation, [call], whose instance
   isn't known: [candidates] are the instances it could be, shown, if
   any. *)
let which_instance loc ~dep ~call ~candidates =
  Diag.make loc
    ~help:(sprintf "say what its result is: `let xs: Array<Int> = %s`" call)
    (match candidates with
    | [] -> sprintf "which `%s` `%s` calls isn't known" dep call
    | cs ->
        sprintf "which `%s` `%s` calls isn't known: %s" dep call
          (String.concat " or " (List.map (sprintf "`%s`") cs)))

(* A `with`'s item [src], a description of a generic dependency at open
   types, whose body uses two or more instances of it. *)
let which_installed loc ~dep ~src ~uses =
  let first = match uses with u :: _ -> u | [] -> dep in
  Diag.make loc
    ~help:
      (sprintf
         "say which, with a written type: `let l: %s = %s`, then `with l in`"
         first src)
    (sprintf "which `%s` `%s` installs isn't known: the body uses %s" dep src
       (and_list uses))

let over_nothing loc ~link ~deps =
  Diag.make loc
    ~help:
      (sprintf
         "say what it goes over: `%s over %s` for the one installed outside \
          this `with`, or another implementation of it after `over`"
         link deps)
    (sprintf "`%s` goes over %s, so it's installed with `over`" link
       (article deps))

(* [link], an implementation of [deps] not declared `over` them, with
   [under] under it, at [uloc]. [param] says it's a parameter whose type
   is written, `w: Users`, which is where it would say so. *)
let not_over ?(param = false) loc ~link ~name ~deps ~uloc =
  Diag.make loc
    ~labels:[ (uloc, "is under it") ]
    ~notes:
      [
        "only a handler declared `over` a dependency goes over another \
         implementation of it";
      ]
    ~help:
      (if param then
         sprintf "say in its type that it goes over one: `%s: over %s`" name
           deps
       else sprintf "install one of them, or declare `%s` `over %s`" name deps)
    (sprintf "`%s` doesn't go over %s, so nothing goes under it" link
       (article deps))

(* [link] goes over [deps], and [under], at [loc], isn't an implementation
   of all of them: it's of [is]. *)
let not_one_under loc ~link ~deps ~under =
  Diag.make loc
    ~help:(sprintf "put %s under it" (article deps))
    (sprintf "`%s` goes over %s, and `%s` isn't one" link (article deps) under)

(* [link] goes over all of [deps], and is installed over only [named] of
   them, at [loc]: the rest would have nothing under them. *)
let over_some loc ~link ~deps ~named =
  Diag.make loc
    ~says:(sprintf "names only %s" (and_list named))
    ~help:(sprintf "write `%s over %s`" link (String.concat " & " deps))
    (sprintf "`%s` goes over %s, so it's installed over %s" link (and_list deps)
       (if List.length deps = 2 then "both" else "all of them"))

(* ---- `finally` (handlers.md, "When a `with` ends") ---- *)

let finally_params loc n =
  Diag.make loc ~help:"`finally(r) => ...`"
    (sprintf
       "`finally` takes one parameter, the result of what it covers, but this \
        has %d"
       n)

(* In an operation's arm, where what it covers, the rest of the arm, is
   of a type it knows. *)
let finally_gives f x =
  sprintf "`finally` produces %s, but it has to give the arm's value, %s"
    (article f) (article x)

(* [result] is the type of the body's result, as it's printed: giving
   that back is said so, not with the type, whose parameters the code
   never wrote *)
let finally_produces ~result r f _ =
  if f = result then
    if r = "_" then
      "`finally` gives back the body's result, but it has to give back its \
       value"
    else
      sprintf
        "`finally` gives back the body's result, `%s`, but it has to give back \
         its value"
        r
  else
    sprintf "`finally` produces %s, but it has to give back the body's value"
      (article f)

(* [r] is what its parameter is named, `_` if it isn't *)
let finally_produces_note r =
  if r = "_" then
    "it's given the body's result, and what it produces is the `with`'s"
  else
    sprintf
      "it's given the body's result, `%s`, and what it produces is the `with`'s"
      r

let finally_produces_help r =
  if r = "_" then
    "name the result, `finally(r) =>`, and give back `v` from `Ok(v)`, or \
     fail: `try r`"
  else sprintf "give back `v` from `Ok(v)`, or fail: `try %s`" r

(* A `finally` that uses [req] of the body's value, at [loc]: that's any
   type, so it has none. *)
let finally_needs loc req ~op =
  Diag.make loc
    ~notes:
      [ "the body's value can be any type, and `finally` has to work for each" ]
    ~help:"give it back as it is, or show it with `print`"
    (match req with
    | "eq" | "hash" -> "`finally` can't compare the body's value"
    | "ord" -> "`finally` can't order the body's value"
    | _ -> sprintf "`finally` can't use `%s` on the body's value" op)

(* Two items of an array, an implementation of several dependencies and one
   of some of them, which a written element type would narrow to that:
   [this], at [loc], is of the type [this_ty], and the first, at
   [first_loc], of [first_ty]. [fix] is the `let` to write, holding
   [part]s. *)
let items_differ loc ~this_ty ~first_loc ~first_ty ~name ~part =
  Diag.make loc
    ~says:(sprintf "is `%s`" this_ty)
    ~labels:[ (first_loc, sprintf "is `%s`" first_ty) ]
    ~help:
      (sprintf "say what the list holds: `let %s: Array<%s> = ...`" name part)
    "the items in this list have different types"

(* `h.count()`, where [h], written [recv], is an implementation of several
   dependencies, of type [all], and more than one of them, [deps], has
   [name] *)
let member_of_several_deps loc ~recv ~all ~name ~deps =
  Diag.make loc
    ~notes:
      [
        sprintf "%s is an implementation of %s, and each of them has `%s`"
          (article all) (and_list deps) name;
      ]
    ~help:
      (sprintf "say which it is where it's made or passed: `let r: %s = %s`"
         (List.hd deps) recv)
    (sprintf "`%s` is a member of %s %s" name
       (match deps with [ _; _ ] -> "both" | _ -> "each of")
       (and_list deps))

(* `&h.reset()`, where [h], written [recv], is an implementation of
   several dependencies, of type [all], and [name] is a method of one of
   them, [dep], that changes its receiver: narrowing [h] to [dep] there
   would write a plain [dep] back into it *)
let changes_one_of_several loc ~recv ~all ~name ~dep =
  Diag.make loc
    ~notes:
      [
        sprintf "`%s` changes a `%s`, and `%s` is %s" name dep recv
          (article all);
      ]
    ~help:(sprintf "change a `%s` of its own: `var r: %s = %s`" dep dep recv)
    (sprintf "`%s` can't change `%s`, which implements more than `%s`" name recv
       dep)

(* ---- what a module writes (infer_top.ml) ---- *)

(* The parameter [name], of the dependency [dep]'s type, is used as a
   value here: it's transparent, so it can only be installed or passed
   straight on. [handler_deps] are what the function's body implements,
   if it's a handler. *)
let not_transparent loc ~name ~dep ~handler_deps =
  Diag.make loc
    ~notes:
      [
        sprintf
          "a parameter whose type is a dependency's, `%s`, can only be \
           installed, with `with`, or passed straight to another function, so \
           what it needs is what its function uses"
          dep;
      ]
    ~help:
      (match handler_deps with
      | Some deps ->
          (* what it needs, the handler needs where it's installed *)
          sprintf
            "to keep it, name what it needs, `%s: %s uses ..d`, and say the \
             handler needs that: `for %s uses ..d`"
            name dep (String.concat ", " deps)
      | None ->
          sprintf "to keep it, name what it needs: `%s: %s uses ..d`" name dep)
    (sprintf "`%s` is used as a value here, so it isn't transparent" name)

(* ---- blocks are second-class (foundations.md, "Lambdas are blocks") ---- *)

(* A place a block can't be: where it would outlive the call it's passed
   to, or be chosen at run time. *)
type block_place =
  | In_record
  | In_payload of string  (** a constructor's, by its name *)
  | In_error  (** an error's payload *)
  | In_array
  | In_tuple
  | In_type_arg  (** a type argument, as written *)
  | Branch  (** the value of an `if` or a `match` *)
  | Returned  (** a function's or a block's result *)
  | In_var
  | In_state  (** a handler's state *)
  | In_value of string  (** an associated value, by its name *)
  | Represented  (** what an opaque type is represented as *)
  | Compared  (** an operand of `==` or `!=` *)
  | Past_with  (** the value of a `with`, which ends before it runs *)
  | Past_lines  (** the value of an indented block, after its lines *)
  | Elsewhere

let block_lives = "a block lives only as long as the call it's passed to"

(* A block, at [loc], in [place]: [written] says [loc] is a type written
   there, not an expression. *)
let block_kept ~written loc place =
  let header, help =
    match place with
    | In_record ->
        ( (if written then "a record can't hold a block"
           else "a block can't be stored in a record"),
          "hold data instead, an enum to `match` on, or a handler's \
           description, and pass the block to the call that runs it" )
    | In_payload c ->
        ( (if written then sprintf "`%s`'s payload can't hold a block" c
           else sprintf "a block can't be stored in `%s`" c),
          "hold data instead, and pass the block to the call that runs it" )
    | In_error ->
        ( "an error can't hold a block",
          "put the data the block would need in the error instead" )
    | In_array ->
        ( "a block can't be stored in an array",
          "store data instead, an enum, and `match` on it where the function \
           is called" )
    | In_tuple ->
        ( "a block can't be stored in a tuple",
          "pass the block as an argument of its own" )
    | In_type_arg ->
        ( "a type argument can't be a block",
          "pass the block as a parameter of its own, `f: fn(...)`" )
    | Branch ->
        ( "a block can only be called or passed where it's written",
          "call the block in each branch: `if c then f(x) else g(x)`" )
    | Returned ->
        ( "a block can't be returned",
          "take the block's arguments as parameters too, and return what it \
           gives" )
    | In_var ->
        ( "a `var` can't hold a block",
          "bind it with `let`: `let f = fn() => ...`" )
    | In_state ->
        ( "a handler's state can't hold a block",
          "keep data in the state, and call a function from the operation" )
    | In_value v ->
        ( "an associated value can't hold a block",
          sprintf "make it a function: `fn %s(...)`" v )
    | Represented ->
        ( "a type can't be represented as a block",
          "represent it as data, or as a dependency's type" )
    | Compared ->
        ( "a block can only be called or passed, not compared",
          "compare what it returns instead" )
    | Past_with ->
        ( "a block can't outlive the `with` it's written in",
          "put the `with` inside the block, `fn() => with ... in ...`, or call \
           the block inside the `with`" )
    | Past_lines ->
        ( "a block can't be the value of an indented block",
          "move the lines before it into the block, or ahead of where it's used"
        )
    | Elsewhere ->
        ( "a block can only be called or passed where it's written",
          "call it here, or pass it straight to a function" )
  in
  Diag.make loc
    ~says:(if written then "a block's type" else "a block")
    ~notes:[ block_lives ] ~help header

(* A scope, or a task's handle: blocks too (foundations.md, decision 2,
   rule D), good only inside the `Async.scope` call that made the scope.
   [Handle] is a task's, its type as it's written, `Task<Int>`. *)
type handle = Scope_of | Handle of string

(* [h], at [loc], in [place], where a block can't be either; [written]
   says [loc] is a type written there. A dependency's operation's
   parameter is [Elsewhere], said as one. *)
let handle_kept ?(op = false) ~written loc h place =
  let what = match h with Scope_of -> "a scope" | Handle _ -> "a task's handle" in
  let good =
    match h with
    | Scope_of -> "a scope is only good inside its `Async.scope` call"
    | Handle _ -> "a task's handle is only good inside its scope"
  in
  let help =
    match h with
    | Scope_of -> "pass it to the functions that spawn into it"
    | Handle _ -> "keep what the task makes instead: `t.join()`"
  in
  let shown = match h with Scope_of -> "Scope" | Handle t -> t in
  let header, help, notes =
    match place with
    | _ when op ->
        ( sprintf "an operation's parameter can't be %s" what,
          help,
          [ "an operation can be called from another task" ] )
    | In_record -> (sprintf "a record can't hold %s" what, help, [ good ])
    | In_payload c -> (sprintf "`%s`'s payload can't hold %s" c what, help, [ good ])
    | In_error -> (sprintf "an error can't hold %s" what, help, [ good ])
    | In_type_arg | In_array | In_tuple ->
        ( sprintf "`%s` can't be a type argument: %s" shown good,
          (match h with
          | Scope_of -> help
          | Handle _ ->
              "keep what the tasks make instead: `Async.map` gives every \
               result, in order"),
          [] )
    | Returned -> (
        match h with
        | Handle _ ->
            ( sprintf "a task's handle can't be returned: %s"
                "it's only good inside its scope",
              "return what the task makes: `t.join()`",
              [] )
        | Scope_of ->
            ( "a scope can't be returned: it's only good inside its \
               `Async.scope` call",
              help,
              [] ))
    | In_var -> (sprintf "a `var` can't hold %s" what, help, [ good ])
    | In_state -> (sprintf "a handler's state can't hold %s" what, help, [ good ])
    | In_value _ -> (sprintf "an associated value can't hold %s" what, help, [ good ])
    | Represented -> (sprintf "a type can't be represented as %s" what, help, [ good ])
    | Compared -> (sprintf "%s can't be compared" what, help, [ good ])
    | Branch | Past_with | Past_lines | Elsewhere ->
        ( sprintf "%s can only be passed, or bound with `let` to a call that \
                   makes it" what,
          help,
          [ good ] )
  in
  Diag.make loc
    ~says:(if written then sprintf "%s's type" what else what)
    ~notes ~help header

(* What a `let` is given that isn't a block written there: one named,
   or chosen between two by an `if` or a `match`, named if they are. *)
type not_literal = Let_named of string | Let_chosen of string * string

(* `let [name] = e`, where [e] is a block of [arity] parameters that
   isn't one written there. *)
let let_not_literal loc ~name ~arity how =
  (* its parameters, named for the help *)
  let xs =
    String.concat ", "
      (match arity with
      | 1 -> [ "x" ]
      | 2 -> [ "x"; "y" ]
      | 3 -> [ "x"; "y"; "z" ]
      | n -> List.init n (fun i -> sprintf "x%d" (i + 1)))
  in
  let help =
    match how with
    | Let_named f ->
        sprintf
          "pass `%s` where it's needed, or write `let %s = fn(%s) => %s(%s)`" f
          name xs f xs
    | Let_chosen (f, g) ->
        sprintf
          "choose inside one block: `let %s = fn(%s) => if ... then %s(%s) \
           else %s(%s)`"
          name xs f xs g xs
  in
  Diag.make loc ~says:"not a `fn` written here"
    ~notes:
      [
        "a `let` names one block, so the code it runs is known where it's \
         called";
      ]
    ~help "`let` binds one block written right there"

(* A handler's parameter [name], at [loc], whose type has a block in it;
   or, without [name], a block given to a handler's parameter. *)
(* A handler's parameter, [name], that's a scope or a task's handle, [h]
   (rule D). *)
let handler_param_handle ~name loc h =
  Diag.make loc
    ~says:(sprintf "`%s` is %s" name (match h with Scope_of -> "a scope" | Handle _ -> "a task's handle"))
    ~notes:
      [
        "a handler's description is a value, which can outlive the scope its \
         tasks are in";
      ]
    ~help:"spawn into the scope where it's given, and pass the handler what the tasks make"
    "a handler's parameters are data"

let handler_param_block ?name loc =
  Diag.make loc
    ~says:
      (match name with
      | Some n -> sprintf "`%s` is a block" n
      | None -> "a block")
    ~notes:
      [
        "a handler's description is a value, which can outlive the call that \
         made it";
      ]
    ~help:"pass the data, or make the behaviour a dependency"
    "a handler's parameters are data"

(* A block, at [loc], given where the type variable [tvar] of what's
   called stands for it. *)
let generic_block loc ~tvar =
  Diag.make loc ~says:"a block"
    ~notes:
      [ "a type variable stands for data, which can be stored or returned" ]
    ~help:"pass a block only to a parameter written `fn(...)`"
    (match tvar with
    | Some t -> sprintf "a generic `%s` can't be a block" t
    | None -> "a generic type can't be a block")

(* A named row, `..[row]`, written on a block's type, at [loc]. *)
let block_row_named loc ~row =
  Diag.make loc
    ~says:(sprintf "`..%s` names them" row)
    ~notes:
      [
        "a block is only called, never kept, so what it fails with and uses is \
         what the call it's passed to does";
      ]
    ~help:(sprintf "leave `..%s` out of the block's type" row)
    "a block's errors and dependencies aren't named"

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

(* ---- what a group leaves to be checked (solve.ml, infer_declared.ml) ---- *)

(* Why a call brings in a dependency it seems not to: the function it
   calls calls something inside a `with` of the dependency, [dep], that
   still gets it from outside (Solve.install). [fn] is that function. *)
type withheld =
  | Same_row of { fn : string; dep : string }
      (** what's called inside the `with` uses what [fn] itself does *)

let withheld = function
  | Same_row { fn; dep } ->
      sprintf
        "in `%s`, what's called inside the `with` that installs `%s` uses what \
         `%s` itself does: a function that calls `%s` back gets only what's \
         installed outside the `with`"
        fn dep fn fn

(* A row that includes a parameter's errors, at [loc], where it can't. *)
let param_fails_here loc =
  Diag.make loc
    ~help:
      "write what the function passed can fail with in its parameter's type, \
       after `!`"
    "this can fail with whatever a function it was passed fails with, which \
     isn't allowed here"

(* The transparent parameter that's kept where what it needs is closed:
   the `self` of a dependency's method, or another of a dependency's
   type. *)
type kept = Dep_self of string | Dep_param of string

(* The transparent parameter [name] of [fn] is kept where it can't need
   anything. *)
let kept_needing_nothing loc ~name ~fn kept =
  let note, help =
    match kept with
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
    (sprintf
       "`%s` is kept where it can't need anything, so it isn't transparent" name)

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

(* A `with`'s body, or a block ([block]), uses the dependencies [deps], as
   a message names them, which what's outside it, where it's written,
   can't: what it calls uses the row of the function it's in
   ([same_row]), or what it's in was closed by its type. *)
let with_body_uses loc ~block ~same_row deps =
  let what = if block then "this block" else "this `with`'s body" in
  let msg = sprintf "%s uses %s, which what's outside it can't" what in
  if same_row then
    Diag.make loc
      ~notes:
        [
          "what's called here uses what the function it's in does, which gets \
           only what's installed outside";
        ]
      ~help:"install what it uses outside it too"
      (msg (and_list deps))
  else
    Diag.make loc
      ~notes:
        [
          "a function or block uses everything its `with`s' bodies and its \
           blocks use, but what they install or are given, and the type of \
           what this is in says it can't use all of that";
        ]
      ~help:(closed_uses_help deps)
      (msg (and_list deps))

(* ---- implementations (solve.ml) ---- *)

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
  | Console of { real : string list; faked : string list }
      (** a `ren console` session, which gets the real built-ins [real], and the
          test ones [faked] *)
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
    | Console c ->
        ( "in the line",
          sprintf "nothing installs `%s` in the console" dep,
          match c.real with
          | [] ->
              sprintf
                "the console gets only the test %s, and what controls them"
                (and_list c.faked)
          | real ->
              sprintf "the console gets only the real %s, and the test %s"
                (and_list real) (and_list c.faked) )
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
    | Main _ | Console _ -> None
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
                 (match maker with Some m -> m | None -> "h()")
                 (if maker = None then
                    sprintf ", for a handler `h` for `%s`" dep
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
          "install one %s, with `with`: `with h() in ...`, for a handler `h` \
           for `%s`"
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
let write_result found = sprintf "add `-> %s` to the signature" found

(* [name], a function of a group that uses another of it, is used as [f]
   but made [x]. *)
let used_as name f x =
  sprintf "`%s` is used here as `%s`, but its definition makes it `%s`" name f x

(* [name], of a group, whose result is an implementation of several
   dependencies, used where [part], some of them, is wanted. *)
let write_group_result name part =
  sprintf "write `%s`'s result, `-> %s`, which narrows it there" name part

(* The same, used where its parameter [n], counted from 1, is one of
   [part]. *)
let write_group_param name n part =
  let nth =
    match n with
    | 1 -> "first"
    | 2 -> "second"
    | 3 -> "third"
    | n -> sprintf "%dth" n
  in
  sprintf "write the type of `%s`'s %s parameter, `%s`, which narrows it there"
    name nth part

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

(* ---- requirements (operators.md, "Equality, hashing and `show`") ---- *)

(* Why a type has no `==` (Infer_reqs): what in it is a function, as far
   as a message says. *)
type no_eq =
  | Is_function  (** it's a function itself *)
  | Has_function of string  (** a function type in it, shown *)
  | Field_function of string * string * string
      (** a field of a type in it, by the type's name, the record's or the
          constructor's, and the field's, whose type has a function in it: the
          type can have `==` through a `key` *)
  | Implementation of string
      (** it's, or there's in it, an implementation of the dependency named, or
          of several, `Rates & RateCalls` *)
  | Opaque_hidden of string
      (** it's, or there's in it, another module's opaque type, named, that's
          represented as something with a function in it *)

(* [shown] has no `==`, at [loc]: compared there with [op], `==` or `!=`,
   or given to [by], which compares what it's given (operators.md,
   "Generic code"). If [failed], [shown] are the errors something given to
   [by] fails with, which it compares, kept by `attempt`. *)
let no_eq loc ~shown ~req ~op ~by ~failed why =
  (* `==`, or `hash`, which a `Map`'s key needs *)
  let needed = if req = "hash" then "hash" else "==" in
  let msg =
    match by with
    | None -> sprintf "`%s` has no `%s`" shown op
    | Some f -> sprintf "`%s` has no `%s`, which `%s` needs" shown needed f
  in
  let inside =
    match why with
    | Is_function -> []
    | Has_function f -> [ sprintf "it has `%s` in it" f ]
    | Field_function (_, t, f) ->
        [ sprintf "the field `%s` of `%s` has a function in it" f t ]
    | Implementation d ->
        [
          sprintf
            "an implementation of `%s` is its operations, which are functions" d;
        ]
    | Opaque_hidden t ->
        [
          sprintf
            "`%s` is opaque, and its module represents it with a function in it"
            t;
        ]
  in
  let help =
    match (by, why) with
    | _, Field_function (t, _, _) ->
        sprintf
          "give `%s` a key, which says what makes two the same: `fn key(self) \
           -> K = ...`"
          t
    | Some f, _ ->
        sprintf "give `%s` something it can %s, without a function in it" f
          (if req = "hash" then "hash" else "compare")
    | None, Is_function ->
        "a function can't be compared: compare what it returns instead"
    | None, Implementation _ -> "compare what its operations return instead"
    | None, Opaque_hidden _ ->
        "compare something its module's functions tell you about it instead"
    | None, _ -> "compare the parts of it that have no function in them"
  in
  let kept =
    match by with
    | Some f when failed ->
        [ sprintf "`%s` compares what something it's given fails with" f ]
    | _ -> []
  in
  Diag.make loc ~help
    ~notes:
      (kept
      @ (match why with
        | Field_function _ ->
            "a type with a function in it has `==` and `hash` only through its \
             `key`"
        | _ -> "a type with a function in it has no `==` or `hash`")
        :: inside)
    msg

(* ---- operators (operators.md) ---- *)

(* How a requirement is written where it's used: `add` is `+`, `ord` is
   `<`, and an associated value is itself, `zero`. *)
let req_symbol = function
  | "eq" -> "=="
  | "ord" -> "<"
  | "add" -> "+"
  | "sub" | "neg" -> "-"
  | "mul" -> "*"
  | "div" -> "/"
  | "rem" -> "%"
  | r -> r

(* Why a type has no order (Infer_reqs): it's ordered only by its `key`,
   or it isn't ordered at all. *)
type no_ord =
  | Unordered_record of string  (** a record, named *)
  | Unordered_sum of string  (** a sum type with fields, named *)
  | Unordered_prelude of string
      (** a sum type with fields the prelude declares, named, which a program
          can't give a key: `Option` *)
  | Unordered_opaque of string * bool
      (** another module's opaque type, named, without a key; or, with [true],
          the module's own, compared by a test, which sees what an importer sees
      *)
  | Unordered_key of string * string
      (** a type, named, with a key, whose type, shown, has no order *)
  | Unordered_table of string  (** a `Map` or a `Set` *)
  | Unordered  (** anything else: an array, `Unit`, `Bytes`, a function *)

(* What a generic function [f] does with what it's given, for the note
   under an error at a call of it that gives it a type without that:
   `sum` uses `+` on its `T` (util.ren:4). [tparam] is the type
   parameter's name, if it has one, and [at] where [f] uses it, if it's
   the module's own function. *)
let uses_note ~f ~op ~tparam ~at =
  let where =
    match at with
    | Some (l : Loc.t) -> sprintf " (%s:%d)" l.file l.start.line
    | None -> ""
  in
  match tparam with
  | Some t -> sprintf "`%s` uses `%s` on its `%s`%s" f op t where
  | None -> sprintf "`%s` uses `%s` on what it's given here%s" f op where

(* [shown] has no order, at [loc]: compared there with [op], `<`, or
   given to [by], which compares what it's given; [uses] says how
   (uses_note). *)
let no_ord loc ~shown ~op ~by ~uses why =
  let msg =
    match by with
    | None -> sprintf "`%s` has no `%s`" shown op
    | Some f -> sprintf "`%s` has no `<`, which `%s` needs" shown f
  in
  let key t = sprintf "give `%s` a key: `fn key(self) -> K = ...`" t in
  let note, help =
    match why with
    | Unordered_record t ->
        ( [
            "a record is ordered only by its `key`, so that reordering its \
             fields can't change a sort";
          ],
          Some (key t) )
    | Unordered_sum t ->
        ( [
            "a sum type with fields is ordered only by its `key`, so that \
             reordering them can't change a sort";
          ],
          Some (key t) )
    | Unordered_prelude t ->
        ( [
            sprintf
              "a sum type with fields is ordered only by its `key`, and `%s` \
               has none"
              t;
          ],
          None )
    | Unordered_opaque (t, false) ->
        ( [ "another module's opaque type is ordered only by its `key`" ],
          Some (sprintf "give `%s` a key in its module" t) )
    | Unordered_opaque (t, true) ->
        ( [
            "a test sees what an importer sees, and to an importer an opaque \
             type is ordered only by its `key`";
          ],
          Some (key t) )
    | Unordered_key (t, k) ->
        ( [
            sprintf "`%s` is ordered by its key, %s, which has no order" t
              (article k);
          ],
          Some
            (sprintf
               "make `%s`'s key something ordered, such as an `Int` or a `Str`"
               t) )
    | Unordered_table t ->
        ( [
            sprintf
              "a `%s` keeps the order its %s were added in, but two aren't \
               ordered"
              t
              (if t = "Map" then "keys" else "members");
          ],
          None )
    | Unordered -> ([], None)
  in
  (* `sort`, `min` and `max` of what has no order: `sort_by` sorts by
     something it has, which is the help, or a note beside a key's *)
  let by_ =
    match Option.map (String.split_on_char '.') by with
    | Some [ ("Array" | "Map" | "Set"); (("sort" | "min" | "max") as m) ] ->
        Some
          (sprintf "`%s_by`, which %s by what a function gives each" m
             (if m = "sort" then "sorts" else "compares"))
    | _ -> None
  in
  let help, note =
    match (help, by_) with
    | None, Some b -> (Some (sprintf "use %s" b), note)
    | Some _, Some b -> (help, note @ [ sprintf "or use %s" b ])
    | _, None -> (help, note)
  in
  Diag.make loc ?help ~notes:(Option.to_list uses @ note) msg

(* [shown] has no [op], `+`, or no associated value [op], `zero`, at
   [loc], or given to [by], which uses it; [uses] says how (uses_note).
   [Str]'s `+` is `concat`. [other] says [shown] has an [op], but not one
   that takes another [shown], which is the one generic code uses. *)
(* What a sized type is for, when one is used as a number. *)
let sized_storage shown =
  sprintf
    "`%s` is for storage: reading one gives %s, which arithmetic is done in"
    shown
    (if shown = Sized.name F32 then "a `Float`" else "an `Int`")

let no_op ?hidden ?(test = false) ?(other = false) loc ~shown ~op ~by ~uses =
  let what =
    if other then sprintf "`%s` that takes %s" op (article shown)
    else sprintf "`%s`" op
  in
  let msg =
    match by with
    | None -> sprintf "`%s` has no %s" shown what
    | Some f -> sprintf "`%s` has no %s, which `%s` needs" shown what f
  in
  (* another module's opaque type, used as what it's represented as *)
  let notes, help =
    match (hidden, shown, op) with
    | Some p, _, _ ->
        let note, help = representation_private ~test p in
        ([ note ], Some help)
    | None, "Str", "+" -> ([], Some "join two strings with `a.concat(b)`")
    (* `sum` of what has no `+`: `count` and `reduce` say what adding
       them up would mean *)
    | None, "Bool", ("+" | "zero")
      when Option.fold ~none:false ~some:(String.ends_with ~suffix:".sum") by ->
        ([], Some "to count those that are `true`, use `count(fn(b) => b)`")
    (* a sized type's: add them up as what they read as *)
    | None, _, ("+" | "zero")
      when Option.fold ~none:false ~some:(String.ends_with ~suffix:".sum") by
           && List.exists (fun k -> Sized.name k = shown) Sized.all ->
        let zero = if shown = Sized.name F32 then "0.0" else "0" in
        ( [ sized_storage shown ],
          Some (sprintf "add them up as you read them: `reduce(%s, fn(acc, x) => acc + x)`" zero) )
    | None, _, ("+" | "zero")
      when Option.fold ~none:false ~some:(String.ends_with ~suffix:".sum") by ->
        ( [],
          Some
            "add up something each one has with `reduce(init, fn(acc, x) => \
             ...)`, or `map` them to numbers first" )
    | None, _, _ when other ->
        ( [
            sprintf
              "in generic code, `%s` takes the same type on both sides and \
               makes it"
              op;
          ],
          None )
    | None, _, _ when List.exists (fun k -> Sized.name k = shown) Sized.all ->
        ([ sized_storage shown ], None)
    | None, _, _ -> ([], None)
  in
  Diag.make loc ?help ~notes:(Option.to_list uses @ notes) msg

(* `a +% b` where [a] isn't an `Int`, of type [shown]. *)
let no_wrapping loc ~shown ~op =
  let plain = String.sub op 0 1 in
  Diag.make loc
    ~notes:[ "the wrapping operators, `+%`, `-%` and `*%`, are `Int`'s" ]
    ~help:
      (if shown = "Float" then sprintf "a `Float` doesn't wrap: use `%s`" plain
       else sprintf "use `%s`, or wrap `Int`s" plain)
    (sprintf "`%s` has no `%s`" shown op)

(* A literal number stored into a sized type it doesn't fit in. *)
let literal_doesnt_fit loc k ~written =
  Diag.make loc
    ~notes:[ "a sized type keeps a number in fewer bits than an `Int`" ]
    ~help:"give the place a type that holds it, or an `Int`"
    (Sized.doesnt_fit k (code written))

(* The result of a wrapping operator stored into a `UInt64`, whose values
   stop at `Int`'s largest (sized.ml). *)
let wrapped_into_uint64 loc ~op =
  Diag.make loc
    ~notes:
      [
        sprintf "`%s` wraps at `Int`'s 64 bits, and half of what it makes is \
                 negative" op;
        "a `UInt64` holds what an `Int` can that isn't negative";
      ]
    ~help:"keep a 64-bit hash or checksum in an `Int`"
    (if op = "shl" then "a `shl`'s result can't be stored in a `UInt64`"
     else "a wrapping operator's result can't be stored in a `UInt64`")

(* `x.shl(k)` or `x.shr(k)`, [op], with a literal [k] outside 0 to 63,
   which would panic every time (foundations.md, decision 15). *)
let shift_out_of_range loc ~op ~k =
  let help =
    if Int64.compare k 0L < 0 then
      sprintf "a shift is by 0 to 63; to shift the other way, use `%s`"
        (if op = "shl" then "shr" else "shl")
    else if op = "shl" then "a shift is by 0 to 63; to make 0, write `0`"
    else "a shift is by 0 to 63; `shr(63)` makes 0, or -1 if it's negative"
  in
  Diag.make loc ~help (sprintf "`%s` by %Ld always panics" op k)

(* `a op b` where [left], [a]'s type, has no [op] taking [right], [b]'s:
   an operator is found on its left side's type, chosen by its right
   side's (operators.md). [numbers] says both are numbers, which never
   convert by themselves, and [help] what to write instead, if anything
   can be said. *)
let no_op_taking loc ~left ~op ~right ~numbers ?help () =
  let notes =
    if numbers then [ "numbers never convert by themselves" ]
    else [ sprintf "`%s` is found on its left side's type, `%s`" op left ]
  in
  Diag.make loc ?help ~notes
    (sprintf "`%s` has no `%s` that takes %s" left op (article right))

(* The help for [no_op_taking] on two numbers: a literal on the right
   written as the left's type, `x * 2.0`, or else one of them
   converted. *)
let convert_help ~written = sprintf "convert one: `%s`" written
let float_literal_help ~written = sprintf "write it as a `Float`: `%s`" written

(* The help for a `with numeric` type [ty] and a literal number, `price +
   5`: [written] are the ways to make one of the type of it, `price +
   Money.cents(5)`, by each function that makes one. *)
let made_help ~ty written =
  sprintf "make %s of it: %s" (article ty)
    (String.concat " or " (List.map code written))

(* The other way round, `now + Duration.seconds(5)`, for `+` and `*`,
   where the right side's type has the operator taking the left's. *)
let swap_help ~written = sprintf "write it the other way round: `%s`" written

(* `a op b` where [left] has several [op]s and [b]'s type isn't known
   yet, so which one it is can't be told. *)
let which_overload loc ~left ~op =
  Diag.make loc
    ~help:"say what the right side is, with a type on the variable it's in"
    (sprintf
       "can't tell which `%s` of `%s` this is: the right side's type isn't \
        known yet"
       op left)

(* An operator written for several types on its right, [name], called
   by name with other than one argument. *)
let wrong_arity_overload loc ~name =
  Diag.make loc
    (sprintf "`%s` takes one argument, which says which `%s` it is" name name)

(* A `with numeric` type, [left], times one of its own: only scaling by
   what it's represented as, [rep], is given. *)
let numeric_mul loc ~left ~rep =
  Diag.make loc
    ~notes:
      [
        sprintf
          "`with numeric` gives `%s` `*` only by %s, so `%s * %s` isn't a `%s`"
          left (article rep) left left left;
      ]
    ~help:
      (sprintf
         "if it's a product, write it on `%s`: `pub fn mul(self, b: %s) -> \
          Area = ...`"
         left left)
    (sprintf "`%s` has no `*` that takes a `%s`" left left)

(* A `with numeric` type divided, [op] `/` or `%`, without a `div` or
   `rem` of its own: a division says how it rounds. *)
let numeric_div loc ~left ~rep ~op ~meth =
  Diag.make loc
    ~notes:
      [
        sprintf "`with numeric` gives no `%s`: a division says how it rounds" op;
      ]
    ~help:
      (sprintf "write it on `%s`: `pub fn %s(self, n: %s) -> %s = ...`" left
         meth rep left)
    (sprintf "`%s` has no `%s`" left op)

(* `x op= v`, [written], where `x op v` makes [made], not [target],
   what the place holds, as types are printed: the message. *)
let op_assign_makes ~written ~made ~target =
  sprintf "`%s` makes %s, not %s" written (article made) (article target)

(* A member of a type parameter other than `zero` or `one`. *)
let through_param loc ~name =
  Diag.make loc
    ~help:"call a function that takes it, or give the function a parameter"
    ~notes:[ sprintf "`%s` stands for whatever type the function's given" name ]
    "through a type parameter, only `zero` and `one` can be reached"

(* A member with a reserved name, [name], whose body does [what] it
   can't. *)
let reserved_impure loc ~name ~what =
  Diag.make loc
    ~notes:
      [
        (match name with
        | "key" -> "a key runs wherever two values are compared"
        | "show" -> "`show` runs wherever a value is shown"
        | _ ->
            "an operator has no `try` in front, so it can't fail or use \
             anything");
      ]
    (sprintf "`%s` can't %s" name what)

(* A public open type, [owner], keeps a rule (module-build.md, "A type
   that keeps rules is opaque"): its member [name] changes it, [`Changes],
   or can refuse to make one, [`Refuses]. [record] is whether it's a
   record, rather than a sum type, and [hide] the help, [hide_fields] or
   [hide_ctors]. *)
let keeps_rules loc ~owner ~name ~record ~hide how =
  let note =
    match (how, record) with
    | `Changes, true ->
        "anyone can change an open type's fields, so a method that changes it \
         is either a second way to do that, or a rule nobody else has to \
         follow"
    | `Changes, false ->
        "anyone can make an open type's values, so a method that changes one \
         is either a second way to do that, or a rule nobody else has to \
         follow"
    | `Refuses, _ ->
        sprintf
          "anyone can make an open type's values without calling `%s`, so what \
           it checks isn't a rule"
          name
  in
  let what =
    match how with
    | `Changes -> "can't change it"
    | `Refuses -> "can't refuse to make one"
  in
  Diag.make loc ~notes:[ note ] ~help:hide
    (sprintf "`%s` is open, so `%s` %s" owner name what)

(* The help for a record: the type, written opaque, [written]. *)
let hide_fields ~written = sprintf "hide its fields: `%s`" written

(* The help for a sum type: its constructors in a private type, [state],
   which the type, [written], is opaque over. *)
let hide_ctors ~state ~written =
  sprintf
    "hide its constructors: declare them in a private type, `%s`, and make \
     this `%s`"
    state written

(* The key of the type [owner] leads back to [owner]: comparing two would
   never end. *)
let key_loops loc ~owner =
  Diag.make loc
    ~notes:
      [
        sprintf
          "two `%s`s are compared by their keys, so comparing those would \
           compare `%s`s again, and never end"
          owner owner;
      ]
    ~help:"make the key of what's in it, its fields, rather than itself"
    (sprintf "the key of `%s` leads back to `%s`" owner owner)

(* An associated value that needs something of its type's parameter,
   `T.zero`, which it can't: it's made once, before anything says what
   `T` is (operators.md, flag S). *)
let value_needs loc ~value ~what =
  Diag.make loc
    ~notes:
      [ "an associated value is made once, before anything says what `T` is" ]
    ~help:"make it a function, which is given its types each time it's called"
    (sprintf "the associated value `%s` can't use `%s` of a type parameter"
       value what)

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
let undeclared_use ?(why = []) ?(notes = []) ?alias (f : Ast.Resolved.fn_def) dep
    call =
  let why = List.map withheld why @ notes in
  let name = Ast.fn_name f in
  match alias with
  | Some (a, op) ->
      (* it declares an alias of this instance, a dependency of its own
         (compiler.md, "Generic dependencies") *)
      Diag.make f.name.loc
        ~labels:
          (match call with
          | Some (l, what) -> [ (l, sprintf "%s `%s`" (user what) dep) ]
          | None -> [])
        ~help:
          (sprintf
             "`%s` is a dependency of its own, with `%s`'s operations: %sadd \
              `uses %s`"
             a dep
             (match op with
             | Some op -> sprintf "call `%s.%s`, or " a op
             | None -> "")
             dep)
        (sprintf "`%s` doesn't declare `%s`" name dep)
  | None ->
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
   that would be the one under it, which a handler declared [over] it
   reaches with `next` (handlers.md, "`next`"): [next] is the call to
   write instead, `next.get`, and the one written, `Users.get`, if it's
   of an operation. *)
let handler_uses_itself (f : Ast.Resolved.fn_def) dep ~over ?next call =
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
           `with`, so `%s` here would be the one under it"
          dep;
      ]
    ~help:
      (match call with
      | Some _ when over -> (
          match next with
          | Some (call, written) ->
              sprintf "call the one under it through `next`: `%s` for `%s`" call
                written
          | None -> sprintf "call the one under it through `next`, not `%s`" dep
          )
      | Some _ ->
          sprintf
            "declare it `over %s`, and call the one under it through `next`" dep
      | None -> sprintf "remove `%s` from its `uses`" dep)
    (sprintf "a handler %s `%s` can't use `%s`"
       (if over then "over" else "for")
       dep dep)

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
   `f` is a field. [returns] is what it returns, if that isn't `Unit`, and
   [keep] the assignment that keeps it, when it's a new value of the
   receiver's type: `xs = xs.sort()`. *)
let not_changed loc ~recv ?returns ?keep (m : string) =
  let help =
    match (returns, keep) with
    | Some t, Some k ->
        sprintf "remove the `&`; `%s` returns a new `%s`, so keep it: `%s`" m t
          k
    | Some t, None -> sprintf "remove the `&`, and use the `%s` it returns" t
    | None, _ -> "remove the `&`"
  in
  Diag.make loc ~help
    (sprintf "`%s` doesn't change %s" m
       (match recv with Some r -> sprintf "`%s`" r | None -> "its receiver"))

(* The operators `with numeric` gives a type, by the name of the method
   each would be on `Int` (operators.md): a numeric type has the operator,
   with no method behind it. *)
let numeric_operators =
  [ ("add", "+"); ("sub", "-"); ("neg", "-"); ("mul", "*") ]

(* `m.add(n)`, where [shown] is a `with numeric` type, which has `+` but
   no `add`; [written] is the call with the operator [op], if it can be
   shown *)
let numeric_method (m : Ast.ident) ~shown ~op ~written =
  Diag.make m.loc
    ~notes:
      [
        sprintf "`with numeric` gives `%s` the operator `%s`, not a method"
          shown op;
      ]
    ?help:(Option.map (sprintf "write the operator: `%s`") written)
    (sprintf "`%s` has no method `%s`" shown m.name)

(* `s.grow()`, where `s`'s type [shown], declared in another module, has
   no public `grow` *)
let no_public_method ?(test = false) (m : Ast.ident) ~shown (p : Path.t) =
  if test then private_in_test m.loc ~home:p.home m.name
  else
    Diag.make m.loc
      ~help:(sprintf "if it's defined in `%s`, mark it `pub`" p.home)
      (sprintf "`%s` has no public `%s`" shown m.name)

(* Names other languages give a collection's methods, each with the one
   Ren gives it: there's one name for each (operators.md, "The collection
   methods"). `find` takes a function, and `index` finds where a value is,
   so `s.find(":")` means `index`. *)
let other_names =
  [
    ("filter", "select");
    ("inject", "reduce");
    ("fold", "reduce");
    ("length", "len");
    ("size", "len");
    ("contains", "includes");
    ("include", "includes");
    ("has", "includes");
    ("detect", "find");
    ("collect", "map");
    ("find", "index");
    ("index_of", "index");
  ]

(* `s.grow()`, where `s`'s type [shown] is the module's own, or built in,
   and has no `grow`. [methods] are the ones it has. *)
let no_method ?slice (m : Ast.ident) ~shown ~own ~type_name methods =
  let renamed =
    List.find_opt
      (fun (other, ren) -> other = m.name && List.mem ren methods)
      other_names
  in
  let help =
    match (renamed, methods) with
    | _ when m.name = "par_map" ->
        (* there's no `par_map` (foundations.md, decision 7) *)
        Some
          "`Async.map(xs) fn(x) => ...` runs on every core when its block uses \
           no dependencies"
    | _ when m.name = "slice" && slice <> None ->
        (* `s.slice(a, b)`, which `s[a..b]` replaced (foundations.md,
           decision 17): [slice] is it, as written *)
        Some (sprintf "slice it: `%s`" (Option.get slice))
    | Some ("find", ren), _ ->
        Some
          (sprintf
             "to find where something is, use `%s`; a `find` takes a function"
             ren)
    | Some (_, ren), _ -> Some (sprintf "Ren calls it `%s`" ren)
    | None, _ :: _ -> Some (sprintf "its methods: %s" (quote methods))
    | None, [] when own ->
        Some (sprintf "declare it under `type %s`, with `self` first" type_name)
    | None, [] -> None
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

(* What a member is, by its kind, or a field if it has none. *)
let member_kind (kind : Iface.op_kind option) =
  match kind with
  | Some Method -> "a method"
  | Some Function -> "an associated function"
  | Some Value -> "an associated value"
  | None -> "a field"

(* `s.size()`, where `s`'s type isn't known yet, and several types the
   module can name have a `size`. [members] are those types, each with
   what its `size` is (see [member_kind]). *)
let several_have_member ~names loc ?what (m : Ast.ident) members =
  let members = List.map (fun (p, k) -> (p, member_kind k)) members in
  let paths = List.map fst members in
  (* the module's own type, if one has it, sooner than a built-in one,
     which says less *)
  let example =
    match
      List.find_opt (fun (p : Path.t) -> p.home <> Path.prelude_home) paths
    with
    | Some p -> p
    | None -> List.hd paths
  in
  let what, help, extra =
    say_which ~names ~can_name:(fun _ -> true) ?what example
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

(* The same, in a `finally`, whose result [r] holds the `with`'s body's
   error, which it can only pass on (handlers.md, "When a `with` ends") *)
let bound_body_error loc name ~r =
  Diag.make loc
    ~notes:
      [
        "`finally` is given the body's error to pass on, not to look at: it \
         could be whatever the body fails with";
      ]
    ~help:(sprintf "match it with `Err(_)`, and pass it on with `try %s`" r)
    (sprintf "`%s` would hold the body's error, which isn't a value" name)

(* `fail Cancelled` outside a `finally` (compiler.md, "Stage 11a",
   "Cancellation") *)
let fail_cancelled loc =
  Diag.make loc
    ~notes:
      [
        "a task is cancelled from outside it, and only a `finally` sees it: \
         it isn't an error, so `attempt` can't keep it";
      ]
    ~help:"a cancelled task stops by itself; to stop early, return"
    "`Cancelled` isn't an error a program can fail with"

(* [c] matched in a `finally`'s result [r], which holds the `with`'s body's
   error, whatever that is *)
let tag_in_body_error (c : Ast.ident) ~arm ~r =
  Diag.make c.loc
    ~notes:
      [
        "`finally` is given the body's error to pass on, not to look at: it \
         could be whatever the body fails with";
      ]
    ~help:
      (sprintf "match it with `%s`, and pass it on with `try %s`"
         (if arm then "fail _" else "Err(_)")
         r)
    (sprintf
       "`%s` can't be matched here, because the body's errors aren't known"
       c.name)

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

(* `try Err(X)`, which would fail with [X], as written: that's `fail X`. *)
let try_err loc tag =
  let tag = Option.value tag ~default:"..." in
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

(* What the `attempt` at [loc] keeps holds tags written inside `Err` in
   another function, in a `Result` of their own, that nothing it covers
   fails with (B5): its `Result` met that one, and the two became one
   type. [extra] are those tags, as shown, each with where it's written;
   [written] all the tags that `Result` holds, and [fails] what the calls
   the `attempt` covers fail with. *)
let kept_written loc ~extra ~written ~fails =
  let names = List.map fst extra in
  Diag.make loc
    ~labels:
      (List.map
         (fun (tag, at) ->
           ( at,
             sprintf
               "`%s` is written here, in a `Result` that holds exactly the \
                tags written in it"
               tag ))
         extra)
    ~notes:
      [
        sprintf
          "its `Result` is used as one made with `Err`, which holds %s, but \
           what an `attempt` keeps is what the calls it covers fail with%s, \
           and nothing more"
          (and_list written)
          (if fails = [] then "" else ", " ^ and_list fails);
      ]
    ~help:
      (sprintf
         "keep the two `Result`s apart, or write the type of the function that \
          makes the one with `Err`, with %s in its `Result`: what an `attempt` \
          keeps can be a declared `Result`, which can hold more"
         (code ("! " ^ String.concat " | " written)))
    (sprintf "this `attempt` can't keep %s: nothing it covers fails with %s"
       (and_list names)
       (if List.length names = 1 then "it" else "them"))

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

(* The same, for installing the items of a `with`, at its keyword [loc],
   [item] the first that can fail: a `with` is marked as a call that can
   fail is (compiler.md, "Stage 11a", "`try with`"). *)
let unhandled_install loc item tags =
  Diag.make loc
    ~says:(sprintf "it can fail with %s" (and_list tags))
    ~help:"write `try with`, or handle its errors with `match`"
    (sprintf "installing `%s` can fail, and nothing handles it" item)

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
         "to %s them, write what it fails with where `%s`'s type is written, \
          as in `%s: fn() ! Bad`, or pass them on with `try`"
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
      ((if f.errors = None then sprintf "add `! %s` to its signature" shape
        else sprintf "add `%s` after `!`" shape)
      ^
      match from with
      | Some (_, Install_fails) ->
          (* a `with` isn't a call a `match` can look at *)
          sprintf
            ", or handle it with a `match` around the `with`, `match with ... \
             in ...`, and an arm `fail %s => ...`"
            tag
      | _ -> ", or handle it here with `match`")
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

(* ---- `over any`, `Tags` and `retry` (compiler.md, "`over any` and
   `retry`") ---- *)

(* "`a`", "`a` and `b`", "`a`, `b` and `c`" *)
let and_list xs =
  match List.rev (List.map (sprintf "`%s`") xs) with
  | [] -> ""
  | [ x ] -> x
  | last :: before -> String.concat ", " (List.rev before) ^ " and " ^ last

(* [link], a handler `over any`, installed over nothing: what the body
   uses, [deps], says what it's likely to go over. *)
let any_over_nothing loc ~link ~dep =
  Diag.make loc
    ~notes:
      [
        "it goes over whatever it's installed over, and with nothing after \
         `over`, that's nothing";
      ]
    ~help:
      (sprintf
         "say what it goes over: `%s over %s` for the one installed outside \
          this `with`, or another implementation after `over`"
         link dep)
    (sprintf "`%s` goes over another implementation, so it's installed with \
              `over`" link)

(* [link], a handler `over any`, installed over [under], which implements
   [deps], more than one. *)
let any_over_several loc ~link ~under ~deps =
  Diag.make loc
    ~notes:[ sprintf "`%s` implements %s" under (and_list deps) ]
    ~help:
      (sprintf "install it over one of them: `%s over %s`" link
         (List.hd deps))
    (sprintf "`%s` goes over any one dependency, and `%s` implements %d" link
       under (List.length deps))

(* [link], a handler `over any`, that can fail with [tag] itself, through
   `call.fail`, which the operations [missing] of what it's installed over,
   [dep], don't declare. *)
let any_undeclared loc ~link ~tag ~dep ~missing =
  Diag.make loc
    ~notes:
      [
        "an operation fails only with the errors its dependency declares, \
         whatever is installed for it";
      ]
    ~help:
      (sprintf
         "install it over a dependency whose every operation can fail with \
          `%s`, or write a handler `over %s`"
         tag dep)
    (sprintf "`%s` can fail with `%s`, which %s %s" link tag
       (and_list (List.map (fun op -> dep ^ "." ^ op) missing))
       (if List.length missing = 1 then "doesn't declare" else "don't declare"))

(* [link], a handler `over any`, installed over [dep], whose operation
   [op] takes a block, which `call.args` can't hold. *)
let any_block_arg loc ~link ~dep ~op =
  Diag.make loc
    ~notes:
      [
        "`call.args` holds an operation's arguments as a value, and a block \
         is never held in one";
      ]
    ~help:(sprintf "write a handler `over %s`" dep)
    (sprintf "`%s` can't go over `%s`: `%s.%s` takes a block" link dep dep op)

(* [link], a handler `over any`, which compares, hashes or orders what
   an operation takes or gives, installed over [dep], a generic dependency,
   for which that isn't built. *)
let any_compared_generic loc ~link ~dep =
  Diag.make loc
    ~notes:
      [
        "a handler `over any` that compares `call.args` or what \
         `call.forward()` gives isn't built yet over a generic dependency";
      ]
    ~help:(sprintf "show them instead, `show(call.args)`, or write a handler `over %s`" dep)
    (sprintf "`%s` compares what `%s`'s operations take or give" link dep)

(* [link], a handler `over any`, which needs [req] of what an operation
   takes or gives, installed over a dependency whose operation [op] [what]
   (takes or gives) a [ty], which hasn't it. *)
let any_lacks loc ~link ~op ~what ~req ~ty =
  let does, op_sym =
    match req with
    | "eq" -> ("compares", "`==`")
    | "hash" -> ("hashes", "hash")
    | "ord" -> ("orders", "order")
    | r -> ("uses `" ^ r ^ "` on", "`" ^ r ^ "`")
  in
  let thing, its =
    if what = "takes" then ("`call.args`", "arguments")
    else ("what `call.forward()` gives", "result")
  in
  Diag.make loc
    ~notes:[ sprintf "`%s` %s `%s`, which has no %s" op what ty op_sym ]
    ~help:(sprintf "show it instead, `show(%s)`"
             (if what = "takes" then "call.args" else "r"))
    (sprintf "`%s` %s %s, and `%s`'s %s can't be" link does thing op its)

(* A handler `over any`, [link], made somewhere other than where it's
   installed: it's specialized for what it's installed over, which is
   known only there. *)
let any_not_made_here loc ~link =
  Diag.make loc
    ~notes:
      [
        "a handler `over any` is made for the dependency it's installed over, \
         which only the `with` says";
      ]
    ~help:"call the handler in the `with`: `with logged() over ...`"
    (sprintf "`%s` is a handler `over any`, made somewhere else" link)

(* A function, [name], that gives a handler `over any` it didn't make
   itself, as its result. *)
let any_returned loc ~name =
  Diag.make loc
    ~notes:
      [
        "a handler `over any` is made for the dependency it's installed over, \
         which only the `with` that installs it says";
      ]
    ~help:"call the handler in the `with` that installs it"
    (sprintf "`%s` gives a handler `over any`, which only its handler makes"
       name)

(* [what], `call.args` or what `call.forward()` gives, used as something
   it isn't known to be. *)
let any_opaque loc ~what =
  Diag.make loc
    ~notes:
      [
        "the arm runs for every operation of whatever it's installed over, so \
         it's the same arm whatever its arguments and result are";
      ]
    ~help:"write a handler `over` the dependency to read its arguments"
    (sprintf "`%s` can only be shown, compared and recorded" what)

(* The arm of a handler `over any` giving something other than what its
   operation gives. *)
let any_result loc =
  Diag.make loc
    ~notes:
      [
        "the arm gives what the operation gives, and only `call.forward()` \
         has a value of that type";
      ]
    ~help:"end it in `try call.forward()`, or fail with `call.fail(e)`"
    "this arm gives something other than its operation's result"

(* A `var` of a handler `over any`, [name], that keeps [what]: each
   operation's is a type of its own. *)
let any_kept loc ~name ~what =
  Diag.make loc
    ~notes:
      [
        sprintf
          "`%s` is a different type for each operation, and the state is \
           shared by them all"
          what;
      ]
    ~help:"keep something derived from it instead, `show(call.args)`"
    (sprintf "`%s` keeps `%s`, which only lasts the call" name what)

(* A parameter of `Tags`, [param], of [fn], given without its name. [arg]
   is what was written. *)
let tags_unnamed loc ~fn ~param ~arg =
  Diag.make loc
    ~notes:[ "a parameter of `Tags` is the only one passed by name" ]
    ~help:(sprintf "write `%s: %s`" param arg)
    (if fn = "retry" then
       sprintf "`%s`, the errors `retry` tries again, is written with its name"
         param
     else
       sprintf "`%s`, the errors `%s` is given, is written with its name" param
         fn)

(* An argument of [fn] passed by name, [name], to a parameter that isn't
   of `Tags`. [arg] is the value. *)
let named_not_tags loc ~name ~arg =
  Diag.make loc
    ~help:(sprintf "a name goes only before a parameter of `Tags`: write `%s`" arg)
    (sprintf "`%s` isn't passed by name" name)

(* An argument passed by the name [given], to the parameter of `Tags`
   named [param]. *)
let tags_misnamed loc ~given ~param =
  Diag.make loc
    ~help:(sprintf "write `%s: ...`" param)
    (sprintf "this parameter is `%s`, not `%s`" param given)

(* [fn] called without its parameter of `Tags`, [param]. [call] is the
   call with it written, naming what it can fail with. *)
let tags_missing loc ~fn ~param ~call =
  Diag.make loc
    ~help:(sprintf "name them: `%s`" call)
    (if fn = "retry" then
       sprintf "`retry` takes `%s:`, the errors it tries again" param
     else sprintf "`%s` takes `%s:`, the errors it's given" fn param)

(* [fn], given [tag] in [param], which [what], the block or the call,
   can't fail with; it can fail with [can]. *)
let tags_cant_fail loc ~fn ~param ~tag ~what ~can =
  Diag.make loc
    ?help:
      (match can with
      | [] -> None
      | can ->
          Some
            (sprintf "name what it can fail with: %s"
               (String.concat ", " (List.map (sprintf "`%s`") can))))
    (sprintf "`%s` is given `%s: %s`, and %s can't fail with `%s`" fn param tag
       what tag)

(* ---- parameters with defaults (compiler.md, "Stage 11a", "The surface") ---- *)

(* [arg], given by position where only [param], which has a default, is
   left for it. *)
let default_by_position loc ~param ~arg =
  Diag.make loc
    ~help:(sprintf "write `%s: %s`" param arg)
    (sprintf "`%s` has a default, so it's given by name" param)

(* An argument given by the name [given], which [fn] has no parameter of
   that takes one: [names] are those it does. *)
let no_param_named loc ~fn ~given ~names =
  Diag.make loc
    ?help:
      (match names with
      | [] -> None
      | ns ->
          Some
            (sprintf "its parameters given by name: %s"
               (String.concat ", " (List.map (sprintf "`%s`") ns))))
    (sprintf "`%s` has no parameter named `%s`" fn given)

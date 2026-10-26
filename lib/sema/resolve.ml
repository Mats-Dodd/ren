(* Name resolution: the pass that finds everything found through scope
   (module-build.md, "In the compiler"). It runs right after parsing, and
   turns the parser's tree, where a name is the string that was written,
   into the resolved tree (ast.ml), where it says what it refers to:

   - a variable or function used as a value is a local (a [binder], shared
     by every use of it), a top-level function (a [Path.t]), or a function
     built into the compiler. A function of another module is written with
     that module's alias in front, `util.double`, and only its public
     functions can be: Resolve sees the module's interface, not its source.
     The prelude's functions, and the module's own, are written bare.
   - a type's name is a declared type (a [Path.t]): the module's own, the
     prelude's, another module's public type imported by name
     (`import rows.{Row}`), or one written with its module's alias,
     `rows.Row`. Or it's one of the type parameters in scope. A constructor
     written after its type, `Light.Red`, gets that type's path.
   - a named error set, `type Refusal = ! ...`, is in scope like a type,
     and only ever written after `!` (or in `Result<T, ! ...>`). A name
     after `!` is the set, if one of that name is in scope, and otherwise
     a tag: tags are structural, so they resolve to nothing (ast.ml).
   - each member of a type is resolved as a function named
     after its type, `Stack.push`, with the type's parameters in scope and
     `self`, its first parameter if it's a method, of the type (ast.ml).
     An item written after its type, `Stack.of` or `stack.Stack.empty`, is
     found through scope too: the type is, and the item is in its
     declaration. A method called with a dot, `s.push(1)`, is found
     through `s`'s type, by inference.
   - a dependency, `dep Clock = ...`, is in scope like a type. A name after
     `uses` is one, and an operation written after it, `Clock.now`, is a
     [Dep_op]: a call of it calls whatever implementation is installed.
   - a handler, `handler h(...) for Rates = ...`, is a function whose body
     is its state and arms. Each arm is an operation of exactly one of the
     dependencies after `for`, and each operation has one. It gives its
     dependency's type, or, if it implements several, a type named after
     it, which no one can write, so it's in no scope.

   Along the way it reports every name that doesn't exist, types given the
   wrong number of arguments, names declared twice, a local or function
   with the name of an imported module, public declarations that
   mention a private type, opaque types represented as themselves, and
   `self` anywhere but first in a method; an error set used as a type, a
  type used as an error set, an error written twice in one set, named
  error sets that include themselves, and alternatives of a pattern that
  bind different names; among a type's members, two
   with the same name, or an item with a field's name; and an item written
   after a type that doesn't have it, `Stack.grow`, or has it privately,
   in another module.
   Imports nothing uses are reported once inference is done
   ([unused_imports]). Later passes never look a name up: inference reads
   a binder's id, mut.ml its kind.

   Constructors and record fields aren't found here: they're found through
   a type (infer_lookup.ml), so two types can have constructors of the same
   name.

   Each problem is reported to the sink (diag.ml), and resolution carries
   on: a name that doesn't exist resolves to something harmless, since the
   driver stops after this pass if it reported anything. *)

open Ast
module Env = Map.Make (String)

let sprintf = Printf.sprintf
let plural n = if n = 1 then "" else "s"

(* Every import must be used (module-build.md, "Found through scope"): its
   alias, or a type it imports by name. Whether a type imported by name is
   used isn't known here, though: `Red`, written bare, can be a constructor
   of an imported `Color` that step 2 of a lookup through a type finds
   (infer_lookup.ml). So this pass records what it saw used, and
   [unused_imports] reports the rest once inference is done. *)
type import_use = {
  import : import;
  alias_used : bool;  (** whether its alias is written anywhere *)
  names : ident list;  (** the names in its `.{}` that imported a type *)
  unseen : ident list;  (** those of [names] that are never written *)
}

type t = {
  home : string;
  prog : Resolved.program;
  types : Iface.type_decl list;
      (** the types the module declares, in the order it declares them *)
  calls : Path.t list Path.Map.t;
      (** each function, by its path, and the top-level functions its body uses:
          the members written after their type included *)
  methods : Path.t list Path.Map.t;
      (** each function, by its path, and the methods of the module's own types
          it calls with a dot that can be told here, which inference needs to
          have checked first: for `s.push(1)`, `Stack.push` if `s` is written to
          be a `Stack`. The others are found through `s`'s type, by inference,
          which adds them to the call graph as it finds them (infer_top.ml). A
          method whose signature is written out in full ([Ast.spelled]) isn't
          one: its declaration is its type, before it's checked. *)
  scope : (string * Path.t) list;
      (** the types written bare here, by name, sorted: the prelude's, those
          imported by name and the module's own *)
  aliases : (string * string) list;
      (** each module imported, with its alias here, in import order *)
  import_uses : import_use list;
      (** what of each import the module uses, by name (see [unused_imports]) *)
}

(* How module [r] writes the type [p]: the shortest way it can. Bare if
   it's in scope; with its module's alias in front, `stripe.Client`, if
   that module is imported; otherwise in full, `billing/invoice.Invoice`,
   which can't be written there, but says exactly which type it is. A type
   from a module that isn't imported can still turn up, through a field
   or a function's result. *)
let type_name (r : t) (p : Path.t) =
  match (List.assoc_opt p.name r.scope, List.assoc_opt p.home r.aliases) with
  | Some q, _ when q = p -> p.name
  | None, _ when p.home = r.home ->
      (* a handler's type, named after it, which is never written, so it's
         in no scope: a type's name starts with a capital *)
      p.name
  | _, Some alias -> alias ^ "." ^ p.name
  | _ -> Path.full p

(* How module [r] writes the top-level function or value [p]: bare if it's
   its own or the prelude's; with its module's alias in front,
   `util.double`, if not; and a member after its type, written as
   [type_name] writes it, `Stack.of` or `stack.Stack.of`. *)
let value_name (r : t) (p : Path.t) =
  match p.member with
  | Some m -> type_name r (Path.owner p) ^ "." ^ m.mname
  | None when p.home = r.home || p.home = Path.prelude_home -> p.name
  | None -> (
      match List.assoc_opt p.home r.aliases with
      | Some alias -> alias ^ "." ^ p.name
      | None -> Path.full p)

(* Whether module [r] can write the type [p] at all: it's in scope, or its
   module is imported. *)
let can_name (r : t) (p : Path.t) =
  List.assoc_opt p.name r.scope = Some p || List.mem_assoc p.home r.aliases

type env = {
  sink : Diag.sink;
  home : string;
  types : (string, Path.t * int) Hashtbl.t;
      (** every type in scope, with how many type arguments it takes *)
  values : (string, name) Hashtbl.t;  (** every top-level function in scope *)
  imports : (import * Iface.t) list;
      (** each module the module imports, in the order it imports them *)
  ifaces : Iface.t list;
      (** the interfaces of every module it imports, the prelude's included *)
  own_ops : (string, (string * Iface.op_kind) list * string list) Hashtbl.t;
      (** the members of each of the module's own types, by the type's name, in
          source order, and its fields *)
  own_sets : (string, unit) Hashtbl.t;
      (** the module's own named error sets, by name *)
  own_numeric : (string, unit) Hashtbl.t;
      (** the module's own `with numeric` types, by name *)
  own_deps : (string, string list) Hashtbl.t;
      (** the module's own dependencies, by name, each with its operations *)
  modules : (import * Iface.t) Env.t;  (** the same, by alias *)
  used : (string, unit) Hashtbl.t;  (** the aliases used *)
  used_types : (Path.t, unit) Hashtbl.t;
      (** the types used that are another module's: an import nothing uses is an
          error *)
}

(* Where a type is written, which says what rows it can name, `..e` and
   `..d` (ast.ml): a function's signature names them, and its body can
   write only those, in a lambda's parameters and a `let`'s type. A type's
   declaration can't name any yet. [Signature] collects them as they're
   named, each with what kind of row it is and where it's first named. *)
type row_kind = Error_row | Dep_row
type named = (string * (row_kind * Loc.t)) list
type rows = Signature of named ref | Body of named | Declaration

(* What one expression can see. [fn] is shared by the whole top-level
   function: a record with [mutable] fields is the same record in every
   copy of the [scope] that holds it. *)
type scope = {
  locals : binder Env.t;
  tparams : string list;  (** the type parameters in scope, in order *)
  rows : named;
      (** the rows the function's signature names, `..d` (see [rows]) *)
  depth : int;  (** how many lambdas deep *)
  fn : fn_state;
}

and fn_state = {
  mutable last_id : int;  (** the last binder id handed out *)
  mutable calls : Path.t list;
  mutable dots : (string * Path.t option) list;
      (** the names called with a dot, `s.push(1)`, each with its receiver's
          type, if it's written (see [receiver_type]) *)
  mutable typed : (int * Path.t) list;
      (** the locals whose type is written, by binder id, with that type *)
}

let report env ?help ?notes ?labels loc msg =
  Diag.report env.sink (Diag.make ?help ?notes ?labels loc msg)

(* `_` names nothing, so there can be any number of them: `fn f(_, _)` *)
let no_duplicates env what (ids : ident list) =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (id : ident) ->
      match Hashtbl.find_opt seen id.name with
      | _ when id.name = "_" -> ()
      | Some first ->
          report env id.loc ~help:"rename one of them"
            ~labels:[ (first, sprintf "the first `%s` is here" id.name) ]
            (sprintf "there are two %s named `%s`" what id.name)
      | None -> Hashtbl.replace seen id.name id.loc)
    ids

(* A local or a top-level function can't have the name of an imported
   module: then `stripe.charge` is always the module's, decided by scope
   alone (module-build.md, "Found through scope"). *)
let not_an_alias env (id : ident) =
  match Env.find_opt id.name env.modules with
  | Some (i, _) ->
      report env id.loc
        ~help:"rename it, or import the module `as` something else"
        ~labels:[ (i.alias.loc, sprintf "`%s` is imported here" id.name) ]
        (sprintf "`%s` is the name of an imported module" id.name)
  | None -> ()

(* `self` is a parameter of a method, and of nothing else: the parser
   lets it be any parameter, so that this can say why it can't. [help]
   says what to do instead. *)
let not_self env ~help (p : Parsed.param) =
  if p.pname.name = "self" then
    report env p.pname.loc ~help
      "`self` is only a parameter of a method, declared under its type"

let bind env sc (id : ident) bound =
  not_an_alias env id;
  sc.fn.last_id <- sc.fn.last_id + 1;
  let b = { id = sc.fn.last_id; ident = id; bound; depth = sc.depth } in
  (* `_`, as in `let _ = ...`, names nothing: the value is dropped *)
  if id.name = "_" then (b, sc)
  else (b, { sc with locals = Env.add id.name b sc.locals })

(* ---- types ---- *)

(* The named error sets module [items] can see, for Iface: its own, and
   those of the modules it imports. A payload can be a function type that
   names a set, so a set's errors are made with this lookup too; [making]
   are the sets being made, so a set named inside its own payload isn't
   made forever. *)
let sets env (items : Resolved.program) : Iface.sets =
  let making = ref [] in
  let rec sets (p : Path.t) =
    if p.home <> env.home then
      Iface.sets_of
        (List.concat_map (fun (i : Iface.t) -> i.types) env.ifaces)
        p
    else if List.mem p !making then None
    else
      List.find_map
        (function
          | Type { type_name; type_body = Errors es; _ }
            when type_name.name = p.name ->
              making := p :: !making;
              let errs = Iface.declared_errors ~sets es in
              making := List.filter (( <> ) p) !making;
              Some errs
          | _ -> None)
        items
  in
  sets

(* Whether [p] is a named error set, `type Refusal = ! ...`, rather than a
   type of values: one of the module's own, or another module's, which its
   interface says. *)
let is_set env (p : Path.t) =
  if p.home = env.home then Hashtbl.mem env.own_sets p.name
  else
    match List.find_opt (fun (i : Iface.t) -> i.home = p.home) env.ifaces with
    | Some iface -> (
        match Iface.find_type iface p.name with
        | Some { body = Errors _; _ } -> true
        | _ -> false)
    | None -> false

(* The operations of [p], if it's a dependency, `dep Clock = ...`: one of
   the module's own, or another module's, which its interface says. *)
let dep_ops env (p : Path.t) =
  if p.home = env.home then Hashtbl.find_opt env.own_deps p.name
  else
    match List.find_opt (fun (i : Iface.t) -> i.home = p.home) env.ifaces with
    | Some iface -> (
        match Iface.find_type iface p.name with
        | Some { body = Dep ops; _ } ->
            Some (List.map (fun (o : Iface.field) -> o.fname) ops)
        | _ -> None)
    | None -> None

(* The type named [name] in scope, and how many type arguments it takes. *)
let find_type env name =
  let found = Hashtbl.find_opt env.types name in
  Option.iter
    (fun ((p : Path.t), _) ->
      if p.home <> env.home then Hashtbl.replace env.used_types p ())
    found;
  found

let rec index_of x i = function
  | y :: rest -> if x = y then Some i else index_of x (i + 1) rest
  | [] -> None

(* Where a type's name is written, its module's alias included. *)
let tyname_loc (t : tyname) =
  match t.tmod with Some m -> Loc.span m.loc t.tid.loc | None -> t.tid.loc

(* Where a type is written: where it starts, for a named one. *)
let written_loc : Parsed.ty -> Loc.t = function
  | TyName (t, _) -> tyname_loc t
  | TyFn (_, _, _, _, l) | TyImpl (_, _, l) | TyInout (_, l) | TyTuple (_, l) ->
      l
  | TyErrors es -> es.eloc

(* An error set's name, `Refusal`, written where only a type of values
   makes sense. [what] says what it was used as. *)
let not_a_type env loc ~what (t : tyname) =
  report env loc ~help:"an error set is only written after `!`"
    (sprintf "`%s` is an error set, so %s" (show_tyname t) what)

(* The type [t] names, and how many type arguments it takes: one in scope,
   or, written `alias.T`, a public type of the module imported as [alias].
   [params] are the type parameters in scope. A name that doesn't exist is
   reported, and gives [None]. *)
let find_named env ~params (t : tyname) =
  match t.tmod with
  | None -> (
      match index_of t.tid.name 0 params with
      | Some i -> Some (Param i, 0)
      | None -> (
          match find_type env t.tid.name with
          | Some (p, n) -> Some (Named p, n)
          | None ->
              report env t.tid.loc
                (sprintf "there's no type named `%s`" t.tid.name);
              None))
  | Some alias -> (
      match Env.find_opt alias.name env.modules with
      | None ->
          report env alias.loc
            ~help:
              (sprintf "import it at the top of the file, like `import %s`"
                 alias.name)
            (sprintf "there's no module imported as `%s`" alias.name);
          None
      | Some ((i : import), iface) -> (
          Hashtbl.replace env.used i.alias.name ();
          match Iface.find_type iface t.tid.name with
          | Some d -> Some (Named d.path, List.length d.params)
          | None ->
              (* a private type isn't in the interface, so it can't be told
                 apart from one that doesn't exist *)
              report env t.tid.loc ~help:"if it's defined there, mark it `pub`"
                (sprintf "`%s` has no public type `%s`" iface.home t.tid.name);
              None))

(* The declared type [t] names, where only a declared type makes sense: a
   record literal's, or the type a constructor is written after. [what]
   says what a type parameter can't be used as. *)
let declared_type env ~params ~what (t : tyname) =
  match find_named env ~params t with
  | Some (Named p, _) when is_set env p ->
      not_a_type env (tyname_loc t) ~what t;
      None
  | Some (Named p, _) -> Some { tref = Named p; tloc = tyname_loc t }
  | Some (Param _, _) ->
      report env (tyname_loc t)
        ~help:"it stands for any type at all; name a declared type instead"
        (sprintf "`%s` is a type parameter, so %s" t.tid.name what);
      None
  | None -> None

(* The dependencies after a function's `uses`, resolved: each one is a
   dependency in scope, `dep Clock = ...`, or another module's, written
   after its alias, `store.Users`, or one the prelude only names so far,
   like `Net`; and each is written once. One that isn't is reported, and
   left out. *)
let uses env (deps : tyname list) : tname list =
  let in_scope () =
    let declared =
      Hashtbl.fold
        (fun name ((p : Path.t), _) acc ->
          if dep_ops env p <> None then name :: acc else acc)
        env.types []
    in
    List.sort_uniq String.compare (declared @ Prelude.dependencies)
  in
  let no_such (d : tyname) =
    Diag.report env.sink
      (Diag.make (tyname_loc d)
         ~notes:
           [
             sprintf "the dependencies in scope are: %s"
               (String.concat ", " (List.map (sprintf "`%s`") (in_scope ())));
           ]
         ~help:"use one of those, or declare it with `dep`"
         (sprintf "there's no dependency named `%s`" (show_tyname d)));
    None
  in
  let not_a_dep (d : tyname) =
    report env (tyname_loc d)
      ~help:
        "a dependency is declared with `dep`, and lists the operations a \
         function can call on it"
      (sprintf "`%s` is a type, not a dependency" (show_tyname d));
    None
  in
  let resolve (d : tyname) =
    match d.tmod with
    | None -> (
        match Hashtbl.find_opt env.types d.tid.name with
        | Some (p, _) when dep_ops env p <> None ->
            ignore (find_type env d.tid.name);
            Some p
        | Some _ -> not_a_dep d
        | None when List.mem d.tid.name Prelude.dependencies ->
            Some (Path.prelude d.tid.name)
        | None -> no_such d)
    | Some _ -> (
        match find_named env ~params:[] d with
        | Some (Named p, _) when dep_ops env p <> None -> Some p
        | Some _ -> not_a_dep d
        | None -> None)
  in
  let seen = Hashtbl.create 4 in
  List.filter_map
    (fun (d : tyname) ->
      let loc = tyname_loc d in
      match resolve d with
      | None -> None
      | Some p -> (
          match Hashtbl.find_opt seen p with
          | Some first ->
              report env loc ~help:"remove one of them"
                ~labels:
                  [ (first, sprintf "the first `%s` is here" (show_tyname d)) ]
                (sprintf "`%s` is in `uses` twice" (show_tyname d));
              None
          | None ->
              Hashtbl.replace seen p loc;
              Some { tref = Named p; tloc = loc }))
    deps

(* The named row [n], written as a row of kind [kind]. *)
let row_name env ~rows kind (n : ident) =
  let what = function
    | Error_row -> "what something fails with"
    | Dep_row -> "what something uses"
  in
  let clash first k =
    report env n.loc
      ~labels:[ (first, sprintf "here it names %s" (what k)) ]
      ~notes:
        [ "a row is a list of errors or a list of dependencies, never both" ]
      ~help:"give the two rows two names"
  in
  match rows with
  | Signature named -> (
      match List.assoc_opt n.name !named with
      | Some (k, first) when k <> kind ->
          clash first k
            (sprintf "`..%s` names %s here, and %s elsewhere in this signature"
               n.name (what kind) (what k))
      | Some _ -> ()
      | None -> named := !named @ [ (n.name, (kind, n.loc)) ])
  | Body named -> (
      match List.assoc_opt n.name named with
      | Some (k, first) when k <> kind ->
          clash first k
            (sprintf "`..%s` names %s in the signature, not %s" n.name (what k)
               (what kind))
      | Some _ -> ()
      | None ->
          report env n.loc
            ~notes:
              [
                "a named row stands for what a closure or an implementation \
                 that comes into or out of the function does, so the signature \
                 names it";
              ]
            ~help:(sprintf "name `..%s` in the function's signature" n.name)
            (sprintf "there's no `..%s` in this function's signature" n.name))
  | Declaration ->
      report env n.loc
        ~notes:
          [
            "only a function's signature names a row, for now (deps.md, \
             \"Implementations\")";
          ]
        ~help:
          "to keep a closure in a type, make its type a type parameter, `type \
           Button<F> = { on_click: F }`, which a signature can write \
           `Button<fn() uses ..d>`"
        (sprintf "a declaration can't name a row, `..%s`" n.name)

(* A `uses` written in a type, resolved: its dependencies, and the row it
   ends in, if it names one. *)
let uses_of env ~rows (u : Parsed.uses) : Resolved.uses =
  Option.iter (row_name env ~rows Dep_row) u.dtail;
  { deps = uses env u.deps; dtail = u.dtail; uloc = u.uloc }

(* A written type, with its names resolved. [params] are the type
   parameters in scope, like the `T` in `Option<T>`. A type with an error
   is reported once, and its arguments aren't looked at. [arg] says it's a
   type argument, the one place an error set can be written as a type:
   `Result<T, ! Short | Frozen>`. Which type takes one is for inference to
   say. *)
let rec ty env ~params ?(rows = Declaration) ?(arg = false) (t : Parsed.ty) :
    Resolved.ty =
  match t with
  | TyFn (ps, ret, errs, u, l) ->
      let ps = List.map (ty env ~params ~rows) ps in
      let ret = Option.map (ty env ~params ~rows) ret in
      let errs = Option.map (errors env ~params ~rows) errs in
      TyFn (ps, ret, errs, Option.map (uses_of env ~rows) u, l)
  | TyInout (t, l) -> TyInout (ty env ~params ~rows t, l)
  | TyTuple (ts, l) -> TyTuple (List.map (ty env ~params ~rows) ts, l)
  | TyImpl ((_ :: _ :: _ as ts), u, l) -> (
      (* several dependencies joined, `Clock & TestClock`: each has to be
         one, and each is written once *)
      let u = Option.map (uses_of env ~rows) u in
      let deps =
        List.fold_left
          (fun deps (t : tyname) ->
            match find_named env ~params t with
            | Some (Named p, _) when dep_ops env p <> None -> (
                match
                  List.find_opt (fun (d : tname) -> d.tref = Named p) deps
                with
                | Some _ ->
                    report env (tyname_loc t) ~help:"remove one"
                      (sprintf "`%s` is joined with `&` twice" (show_tyname t));
                    deps
                | None -> deps @ [ { tref = Named p; tloc = tyname_loc t } ])
            | Some _ ->
                report env (tyname_loc t)
                  ~help:
                    (sprintf
                       "`%s` isn't one: an implementation of several \
                        dependencies is the one value of this type"
                       (show_tyname t))
                  "only a dependency's type can be joined with `&`";
                deps
            | None -> deps)
          [] ts
      in
      match deps with
      | [] -> TyName ({ tref = Named (Path.prelude "Unit"); tloc = l }, [])
      | deps -> TyImpl (deps, u, l))
  | TyImpl (ts, u, l) -> (
      let t = List.hd ts in
      let u = Option.map (uses_of env ~rows) u in
      match find_named env ~params t with
      | Some (Named p, _) when dep_ops env p <> None ->
          TyImpl ([ { tref = Named p; tloc = tyname_loc t } ], u, l)
      | found ->
          if found <> None then
            report env (tyname_loc t)
              ~help:
                "remove the `uses`: only an implementation of a dependency \
                 needs something"
              (sprintf "`%s` isn't a dependency, so it needs nothing"
                 (show_tyname t));
          TyName
            ( {
                tref =
                  (match found with
                  | Some (tref, _) -> tref
                  | None -> Named (Path.make env.home t.tid.name));
                tloc = tyname_loc t;
              },
              [] ))
  | TyErrors es ->
      if not arg then
        report env es.eloc
          ~help:
            "an error set goes after `!` in a signature or a function type; \
             the one type that holds one is `Result<T, ! ...>`"
          "an error set isn't a type of values";
      TyErrors (errors env ~params ~rows es)
  | TyName (t, args) -> (
      let named tref = { tref; tloc = tyname_loc t } in
      let given = List.length args in
      match find_named env ~params t with
      | None -> TyName (named (Named (Path.make env.home t.tid.name)), [])
      | Some (Named p, _) when is_set env p ->
          not_a_type env (tyname_loc t) ~what:"it isn't a type of values" t;
          TyName (named (Named p), [])
      | Some (tref, n) when n <> given ->
          (* `Box<fn() uses Clock, Console>` is two arguments: in one, a
             `uses` list ends at a comma *)
          let ends_in_uses : Parsed.ty -> bool = function
            | TyFn (_, _, _, Some _, _) | TyImpl (_, Some _, _) -> true
            | _ -> false
          in
          let help =
            if given > n && List.exists ends_in_uses (List.tl (List.rev args))
            then
              Some
                "in a type argument, a `uses` list ends at a comma: to list \
                 several dependencies, put the type in parentheses, `Box<(fn() \
                 uses Clock, Console)>`"
            else None
          in
          report env (tyname_loc t) ?help
            (sprintf "`%s` takes %d type argument%s but was given %d"
               (show_tyname t) n (plural n) given);
          TyName (named tref, [])
      | Some (Named p, _) when dep_ops env p <> None ->
          (* a dependency's type is an implementation's, which needs what
             it's written to need: nothing, here *)
          TyImpl ([ named (Named p) ], None, tyname_loc t)
      | Some (tref, _) ->
          TyName (named tref, List.map (ty env ~params ~rows ~arg:true) args))

(* An error set as written, after `!`, with its names resolved. A bare
   name with no payload is the named error set of that name, if one is in
   scope (a type parameter's name is never one), and otherwise a tag; a
   name after a module, `bank.Refusal`, has to be a set. Each error is
   written once. *)
and errors env ~params ?(rows = Declaration) (es : Parsed.errors) :
    Resolved.errors =
  Option.iter (row_name env ~rows Error_row) es.etail;
  let set_in_scope (t : ident) =
    if List.mem t.name params then None
    else
      match Hashtbl.find_opt env.types t.name with
      | Some (p, _) when is_set env p ->
          (* noted as used, as any type found in scope is *)
          ignore (find_type env t.name);
          Some p
      | _ -> None
  in
  let error : Parsed.error -> Resolved.error = function
    | Tag (t, []) when set_in_scope t <> None ->
        Set { tref = Named (Option.get (set_in_scope t)); tloc = t.loc }
    | Tag (t, ps) ->
        Tag
          ( t,
            List.map
              (fun (p : tyname payload) ->
                { p with payload_ty = ty env ~params ~rows p.payload_ty })
              ps )
    | Set n -> (
        match find_named env ~params n with
        | Some (Named p, _) when is_set env p ->
            Set { tref = Named p; tloc = tyname_loc n }
        | Some _ ->
            report env (tyname_loc n)
              ~help:
                (sprintf
                   "name an error set, declared with `type X = ! ...`; a tag \
                    is written bare, `%s`"
                   n.tid.name)
              (sprintf "`%s` is a type, not an error set" (show_tyname n));
            Tag (n.tid, [])
        | None -> Tag (n.tid, []))
  in
  let name : Parsed.error -> ident = function
    | Tag (t, _) -> t
    | Set n -> { name = show_tyname n; loc = tyname_loc n }
  in
  (* a tag as its shape: its name and its payload's types *)
  let shape : Parsed.error -> string option = function
    | Tag (t, []) -> Some t.name
    | Tag (t, ps) ->
        Some
          (t.name ^ "("
          ^ String.concat ", "
              (List.map
                 (fun (p : tyname payload) -> Ast.show_ty p.payload_ty)
                 ps)
          ^ ")")
    | Set _ -> None
  in
  let seen = Hashtbl.create 8 in
  List.iter
    (fun e ->
      let id = name e in
      match Hashtbl.find_opt seen id.name with
      | Some (first, first_shape) -> (
          match (first_shape, shape e) with
          | Some a, Some b when a <> b ->
              Diag.report env.sink
                (Diag.make id.loc
                   ~labels:[ (first, sprintf "`%s` is here" a) ]
                   ~notes:
                     [
                       "a tag is its name and its payload's types, so these \
                        are two errors with one name";
                     ]
                   ~help:"give one of them another name"
                   (sprintf "`%s` has two shapes in this error set" id.name))
          | _ ->
              report env id.loc ~help:"remove one of them"
                ~labels:[ (first, sprintf "the first `%s` is here" id.name) ]
                (sprintf "`%s` is in this error set twice" id.name))
      | None -> Hashtbl.replace seen id.name (id.loc, shape e))
    es.errs;
  { errs = List.map error es.errs; etail = es.etail; eloc = es.eloc }

let ty_opt env ~params ?rows = Option.map (ty env ~params ?rows)

(* The named type [t] is, if it's written, `b: Bag`: then a method called
   on [b] can only be one of [Bag]'s (see [receiver_type]). *)
let note_type sc (b : binder) (t : Resolved.ty option) =
  match t with
  | Some (TyName ({ tref = Named p; _ }, _)) ->
      sc.fn.typed <- (b.id, p) :: sc.fn.typed
  | _ -> ()

let param env sc ?rows bound (p : Parsed.param) : Resolved.param * scope =
  let rows = Option.value rows ~default:(Body sc.rows) in
  let pty = ty_opt env ~params:sc.tparams ~rows p.pty in
  let b, sc = bind env sc p.pname bound in
  note_type sc b pty;
  ({ pname = b; pty; pmode = p.pmode }, sc)

(* The type of [r], the receiver of a dot call, if it's written where [r]
   is: a local whose type is written, `self` included, or a record
   literal, `Bag { ... }.size()`. *)
let receiver_type sc (r : Resolved.expr) =
  match r.kind with
  | Var (Local b) -> List.assoc_opt b.id sc.fn.typed
  | Record (Some { tref = Named p; _ }, _) -> Some p
  | _ -> None

let params env sc ?rows bound ps =
  let ps, sc =
    List.fold_left
      (fun (acc, sc) (p : Parsed.param) ->
        let p, sc = param env sc ?rows (bound p) p in
        (p :: acc, sc))
      ([], sc) ps
  in
  (List.rev ps, sc)

(* ---- expressions ---- *)

(* The public function [f] of the imported module [iface], written
   `alias.f`. A private function isn't in the interface, so it can't be
   told apart from one that doesn't exist. *)
let qualified env sc ((i : import), (iface : Iface.t)) (f : ident) =
  Hashtbl.replace env.used i.alias.name ();
  let p = Path.make iface.home f.name in
  if Iface.find_value iface f.name = None then
    report env f.loc ~help:"if it's defined there, mark it `pub`"
      (sprintf "`%s` has no public `%s`" iface.home f.name)
  else sc.fn.calls <- p :: sc.fn.calls;
  Global p

(* The member [f] of the type [t], written `Stack.of`, or with the type's
   module in front, `stack.Stack.of`: the type is found through scope, and
   the item in its declaration. Another module's type lists only its public
   items, so a private one can't be told apart from one that doesn't
   exist. An associated value is a [Global_value]; the rest are functions. *)
let item env sc (t : tyname) (f : ident) =
  let assoc = f.name = "zero" || f.name = "one" in
  match (t.tmod, index_of t.tid.name 0 sc.tparams) with
  | None, Some i when assoc ->
      (* `T.zero`: whatever the function's given for `T` has *)
      Assoc_value (Param i, f.name)
  | None, Some _ ->
      Diag.report env.sink (Infer_msg.through_param f.loc ~name:t.tid.name);
      Global (Path.make env.home f.name)
  | _ -> (
      match
        declared_type env ~params:sc.tparams ~what:"it has no members" t
      with
      | None -> Global (Path.make env.home f.name)
      | Some { tref = Param _; _ } ->
          (* [declared_type] gives only a declared type *)
          assert false
      | Some { tref = Named p; _ } -> (
          let shown = show_tyname t in
          let decl =
            Option.bind
              (List.find_opt (fun (i : Iface.t) -> i.home = p.home) env.ifaces)
              (fun iface -> Iface.find_type iface p.name)
          in
          let declared () =
            ( List.map
                (fun (o : Iface.op) -> (o.oname, o.okind))
                (Option.fold ~none:[] ~some:Iface.public_members decl),
              [] )
          in
          (* the prelude's own source finds a built-in type's members,
         `Str.from_utf8`, in the intrinsics *)
          let items, fields =
            if p.home = env.home then
              match Hashtbl.find_opt env.own_ops p.name with
              | Some own -> own
              | None -> declared ()
            else declared ()
          in
          let path = Path.member p f.name in
          let ops = Option.value (dep_ops env p) ~default:[] in
          (* a built-in method, `Array.len`: built into the compiler, not a
         function of the program *)
          let builtin =
            if p.home = Path.prelude_home then Prelude.find path else None
          in
          match (List.assoc_opt f.name items, builtin) with
          | _ when List.mem f.name ops ->
              (* `Clock.now`: an operation, which calls the implementation
             installed where it's called (one a handler calls of what it
             implements is reported by infer_declared.ml); resolve.ml
             reports one that's also a member's name *)
              Dep_op (p, f.name)
          | Some _, Some x -> Intrinsic x
          | Some _, None
            when List.length (List.filter (fun (n, _) -> n = f.name) items) > 1
            ->
              (* an operator written for several types on its right: which
                 one is told by what's on the right, which `V.add` alone
                 doesn't say *)
              report env f.loc
                ~help:
                  (sprintf "write it as an operator, `a %s b`, or `a.%s(b)`"
                     (Infer_msg.req_symbol f.name)
                     f.name)
                ~notes:
                  [
                    sprintf
                      "`%s.%s` is written for more than one type on its right"
                      shown f.name;
                  ]
                (sprintf "`%s.%s` can't say which `%s` it is" shown f.name
                   f.name);
              Global path
          | Some kind, None ->
              sc.fn.calls <- path :: sc.fn.calls;
              if kind = Value then Global_value path else Global path
          | None, _
            when assoc
                 && (p = Path.prelude "Int"
                    || p = Path.prelude "Float"
                    || f.name = "zero"
                       &&
                       if p.home = env.home then
                         Hashtbl.mem env.own_numeric p.name
                       else
                         Option.fold ~none:false
                           ~some:(fun (d : Iface.type_decl) ->
                             d.numeric <> None)
                           decl) ->
              (* a number's `zero` and `one`, and a `with numeric` type's
             `zero`, which it has without writing it *)
              Assoc_value (Named p, f.name)
          | None, _ when p.home <> env.home && p.home <> Path.prelude_home ->
              report env f.loc
                ~help:(sprintf "if it's defined in `%s`, mark it `pub`" p.home)
                (sprintf "`%s` has no public `%s`" shown f.name);
              Global path
          | None, _ ->
              (* the module's own type, or a built-in one, which has every item
             it will ever have *)
              let quoted ns =
                String.concat ", " (List.map (sprintf "`%s`") ns)
              in
              report env f.loc
                ?help:
                  (match items with
                  | _ when ops <> [] ->
                      Some
                        (sprintf "its operations: %s%s" (quoted ops)
                           (if items = [] then ""
                            else
                              sprintf "; its members: %s"
                                (quoted (List.map fst items))))
                  | _ when List.mem f.name fields ->
                      Some
                        (sprintf
                           "`%s` is a field, so it's read from a value, like \
                            `x.%s`"
                           f.name f.name)
                  | [] when p.home = env.home ->
                      Some (sprintf "declare it under `type %s`" shown)
                  | [] -> None
                  | _ ->
                      Some
                        (sprintf "its members: %s"
                           (String.concat ", "
                              (List.map (fun (n, _) -> sprintf "`%s`" n) items))))
                (sprintf "`%s` has no %s named `%s`" shown
                   (if ops = [] then "member" else "operation or member")
                   f.name);
              Global path))

(* What the name [x] refers to. [what] words the error when it's nothing:
   "variable", or "function" for the name being called. *)
let lookup env sc loc ~what x =
  match Env.find_opt x sc.locals with
  | Some b -> Local b
  | None -> (
      match Hashtbl.find_opt env.values x with
      | Some (Global p as name) ->
          sc.fn.calls <- p :: sc.fn.calls;
          name
      | Some name -> name
      | None ->
          (* a public function of an imported module is written with its
             alias, so that every call says where it goes *)
          let elsewhere =
            List.filter
              (fun (_, iface) -> Iface.find_value iface x <> None)
              env.imports
          in
          (match elsewhere with
          | [] when x = "_" ->
              report env loc
                ~help:"give the value a name, `let x = ...`, to use it"
                "`_` drops a value, so it can't be read"
          | [] when x = "self" ->
              report env loc
                ~help:
                  "make `self` the first parameter of a function declared \
                   under its type"
                "there's no `self` here: only a method has one"
          | [] -> (
              (* `len(xs)`: a built-in type's method, called the old way *)
              let builtin =
                List.find_map
                  (fun (t : Prelude.builtin_type) ->
                    List.find_map
                      (fun m ->
                        if Intrinsic.member_name m = x then
                          Some (t.name, Prelude.scheme m)
                        else None)
                      t.methods)
                  Prelude.types
              in
              match builtin with
              | Some (t, scheme) ->
                  (* `&` if it changes its receiver, `...` if it takes
                     more than its receiver *)
                  let amp, rest =
                    match scheme.ty with
                    | Fun (self :: ps, _, _, _, _) ->
                        ( (if self.mode = Inout then "&" else ""),
                          if ps = [] then "" else "..." )
                    | _ -> ("", "")
                  in
                  report env loc
                    ~help:
                      (sprintf
                         "`%s` is a method of `%s`, so it's called with a dot: \
                          `%sxs.%s(%s)`"
                         x t amp x rest)
                    (sprintf "there's no %s named `%s`" what x)
              | None ->
                  report env loc (sprintf "there's no %s named `%s`" what x))
          | _ ->
              (* the import isn't unused, it's used wrongly, and this says
                 how to fix that *)
              List.iter
                (fun ((i : import), _) ->
                  Hashtbl.replace env.used i.alias.name ())
                elsewhere;
              report env loc
                ~help:
                  (sprintf "write %s"
                     (String.concat " or "
                        (List.map
                           (fun ((i : import), _) ->
                             sprintf "`%s.%s`" i.alias.name x)
                           elsewhere)))
                (sprintf "`%s` isn't defined here" x));
          Global (Path.make env.home x))

(* The variables a pattern binds, left to right, so that `P(x, x)` can be
   reported: otherwise the second `x` would quietly hide the first. *)
let rec pattern_vars (p : Parsed.pattern) =
  match p.pkind with
  | PWild | PInt _ | PBool _ | PFail_any -> []
  | PVar x -> [ x ]
  | PCon (_, ps) | PFail (_, ps) | PTuple ps -> List.concat_map pattern_vars ps
  | POr ps ->
      (* each alternative binds the same names (see [pattern]) *)
      Option.fold ~none:[] ~some:pattern_vars (List.nth_opt ps 0)

(* A constructor: the type it's written after, if any, resolved. A bare one
   is found through a type by inference. *)
let ctor_ref env sc (c : Parsed.ctor_ref) : Resolved.ctor_ref =
  {
    qual =
      Option.bind c.qual
        (declared_type env ~params:sc.tparams ~what:"it has no constructors");
    name = c.name;
  }

(* A pattern, and the scope its names are bound in. [same] are the
   binders the first alternative of an or-pattern bound, which the names
   of the others are: `fail Short(_, by) | fail Late(by)` binds one `by`. *)
let rec pattern env ?(same = Env.empty) sc (p : Parsed.pattern) :
    Resolved.pattern * scope =
  let patterns sc ps =
    let ps, sc =
      List.fold_left
        (fun (acc, sc) p ->
          let p, sc = pattern env ~same sc p in
          (p :: acc, sc))
        ([], sc) ps
    in
    (List.rev ps, sc)
  in
  let kind, sc =
    match p.pkind with
    | PWild -> (PWild, sc)
    | PInt n -> (PInt n, sc)
    | PBool b -> (PBool b, sc)
    | PFail_any -> (PFail_any, sc)
    | PVar x -> (
        match Env.find_opt x.name same with
        | Some b -> (PVar b, { sc with locals = Env.add x.name b sc.locals })
        | None ->
            let b, sc = bind env sc x By_pattern in
            (PVar b, sc))
    | PCon (c, ps) ->
        let ps, sc = patterns sc ps in
        (PCon (ctor_ref env sc c, ps), sc)
    | PFail (t, ps) ->
        let ps, sc = patterns sc ps in
        (PFail (t, ps), sc)
    | PTuple ps ->
        let ps, sc = patterns sc ps in
        (PTuple ps, sc)
    | POr [] -> assert false (* the parser makes one of two or more *)
    | POr (first :: rest) ->
        let first', inner = pattern env sc first in
        let bound = pattern_vars first in
        let has (vars : ident list) (x : ident) =
          List.exists (fun (y : ident) -> y.name = x.name) vars
        in
        let help = "bind the same names in every alternative" in
        (* a name only some alternatives bind is reported, and bound
           anyway, so its uses aren't reported too *)
        let rest, inner =
          List.fold_left
            (fun (acc, inner) (alt : Parsed.pattern) ->
              let vars = pattern_vars alt in
              no_duplicates env "pattern variables" vars;
              List.iter
                (fun (x : ident) ->
                  if not (has bound x) then
                    report env x.loc ~help
                      (sprintf
                         "`%s` is bound by this alternative, but not by the \
                          first one"
                         x.name))
                vars;
              List.iter
                (fun (y : ident) ->
                  if not (has vars y) then
                    report env alt.ploc ~help
                      ~labels:[ (y.loc, sprintf "`%s` is bound here" y.name) ]
                      (sprintf
                         "this alternative doesn't bind `%s`, which the first \
                          one does"
                         y.name))
                bound;
              let alt, inner = pattern env ~same:inner.locals inner alt in
              (alt :: acc, inner))
            ([], inner) rest
        in
        (POr (first' :: List.rev rest), inner)
  in
  ({ pkind = kind; ploc = p.ploc; pnode = p.pnode }, sc)

(* The pattern of a `let` or a `for`, of names, `_` and tuples (the
   parser sees to that), whose names are bound as [bound] says: a loop's
   are its loop variables. *)
let rec binding env sc bound (p : Parsed.pattern) : Resolved.pattern * scope =
  let kind, sc =
    match p.pkind with
    | PVar x ->
        let b, sc = bind env sc x bound in
        (PVar b, sc)
    | PTuple ps ->
        let ps, sc =
          List.fold_left
            (fun (acc, sc) p ->
              let p, sc = binding env sc bound p in
              (p :: acc, sc))
            ([], sc) ps
        in
        (PTuple (List.rev ps), sc)
    | PWild -> (PWild, sc)
    | PInt _ | PBool _ | PCon _ | PFail _ | PFail_any | POr _ ->
        (* the parser lets only names, `_` and tuples through *)
        assert false
  in
  ({ pkind = kind; ploc = p.ploc; pnode = p.pnode }, sc)

(* `Stack.of`, which the parser reads as the field `of` of a constructor
   `Stack`, is a member of the type when `Stack` names a type.
   Otherwise it is what it was read as: `Admin.rank`, a method of the
   constructor `Admin`. *)
let as_item env sc (e : Parsed.expr) : Parsed.expr =
  match e.kind with
  | Field ({ kind = Con ({ qual = None; name }, []); _ }, f)
    when index_of name.name 0 sc.tparams <> None
         || Hashtbl.mem env.types name.name ->
      { e with kind = Var (Item ({ tmod = None; tid = name }, f)) }
  | _ -> e

let rec expr env sc (e : Parsed.expr) : Resolved.expr =
  let e = as_item env sc e in
  let go = expr env sc in
  let kind : Resolved.expr_kind =
    match e.kind with
    | Int n -> Int n
    | Float f -> Float f
    | Bool b -> Bool b
    | Str s -> Str s
    | Unit -> Unit
    | Var (Bare x) -> Var (lookup env sc e.loc ~what:"variable" x)
    | Var (Item (t, f)) -> Var (item env sc t f)
    | Unop (op, a, n) -> Unop (op, go a, n)
    | Binop (op, a, b, n) ->
        let a = go a in
        Binop (op, a, go b, n)
    | If (c, t, f) ->
        let c = go c in
        let t = go t in
        If (c, t, Option.map go f)
    | Call (f, args) ->
        let f =
          let f = as_item env sc f in
          match f.kind with
          | Var (Bare x) ->
              {
                kind = Var (lookup env sc f.loc ~what:"function" x);
                loc = f.loc;
                node = f.node;
              }
          | Field ({ kind = Var (Bare m); _ }, _) when Env.mem m env.modules ->
              go f
          | Field (_, m) -> (
              (* `s.push(1)`: which type's `push` is found by inference *)
              let f = go f in
              match f.kind with
              | Field (r, _) ->
                  sc.fn.dots <- (m.name, receiver_type sc r) :: sc.fn.dots;
                  f
              | _ -> f)
          | _ -> go f
        in
        Call (f, List.map go args)
    | Lambda (ps, body) ->
        no_duplicates env "parameters"
          (List.map (fun (p : Parsed.param) -> p.pname) ps);
        List.iter (not_self env ~help:"choose another name") ps;
        let ps, inner =
          (* an `inout` lambda parameter is an error (mut.ml), but binding it
             as one keeps its uses from being reported a second time *)
          params env
            { sc with depth = sc.depth + 1 }
            (fun (p : Parsed.param) ->
              if p.pmode = Inout then By_inout else By_lambda)
            ps
        in
        Lambda (ps, expr env inner body)
    | Block (stmts, last) ->
        let stmts, sc = block_stmts env sc stmts in
        Block (stmts, expr env sc last)
    | Con (c, args) ->
        let c = ctor_ref env sc c in
        Con (c, List.map (fun (l, a) -> (l, go a)) args)
    | Record (name, fields) ->
        let name =
          Option.map
            (fun (t : tyname) ->
              match
                declared_type env ~params:sc.tparams
                  ~what:"it can't make a record" t
              with
              | Some n -> n
              | None ->
                  {
                    tref = Named (Path.make env.home t.tid.name);
                    tloc = tyname_loc t;
                  })
            name
        in
        Record (name, List.map (fun (f, v) -> (f, go v)) fields)
    | Field ({ kind = Var (Bare m); _ }, f) when Env.mem m env.modules ->
        Var (qualified env sc (Env.find m env.modules) f)
    | Field (r, f) -> Field (go r, f)
    | Match (subject, arms) ->
        let subject = go subject in
        Match
          ( subject,
            List.map
              (fun (a : Parsed.arm) : Resolved.arm ->
                no_duplicates env "pattern variables" (pattern_vars a.arm_pat);
                let arm_pat, sc = pattern env sc a.arm_pat in
                let arm_guard = Option.map (expr env sc) a.arm_guard in
                { arm_pat; arm_guard; arm_body = expr env sc a.arm_body })
              arms )
    | Array xs -> Array (List.map go xs)
    | Tuple xs -> Tuple (List.map go xs)
    | Index (a, i) ->
        let a = go a in
        Index (a, go i)
    | Ref a -> Ref (go a)
    | Assign
        {
          target = { kind = Var (Bare "_"); loc; _ } as target;
          op;
          value;
          onode;
        } ->
        report env loc
          ~help:"write `let _ = ...` to drop a value, or assign to a `var`"
          "`_` names nothing, so it can't be assigned to";
        (* the placeholder an unknown name gets: nothing after this pass
           runs once it has reported an error *)
        let target =
          { target with kind = Var (Global (Path.make env.home "_")) }
        in
        Assign { target; op; value = go value; onode }
    | Assign { target; op; value; onode } ->
        let target = go target in
        Assign { target; op; value = go value; onode }
    | For { pat; over; body } ->
        let bound =
          match over with
          | Each { kind = Ref _; _ } -> By_ref_loop
          | Each _ | Range _ -> By_loop
        in
        let over : Resolved.over =
          match over with
          | Each iter -> Each (go iter)
          | Range (lo, hi) ->
              let lo = go lo in
              Range (lo, go hi)
        in
        no_duplicates env "loop variables" (pattern_vars pat);
        let pat, inner = binding env sc bound pat in
        For { pat; over; body = expr env inner body }
    | Fail (t, args) ->
        (match Hashtbl.find_opt env.types t.name with
        | Some (p, _) when is_set env p ->
            Diag.report env.sink
              (Diag.make t.loc
                 ~notes:
                   [
                     "an error set holds the tags a function can fail with, \
                      and `fail` fails with one of them";
                   ]
                 ~help:"fail with one of its tags"
                 (sprintf "`%s` is an error set, not a tag" t.name))
        | _ -> ());
        Fail (t, List.map (fun (l, a) -> (l, go a)) args)
    | Try a -> Try (go a)
    | Attempt a -> Attempt (go a)
    | Assert a -> Assert (go a)
    | With { item; body; lam } ->
        let item = go item in
        With { item; body = go body; lam }
    | Handler _ ->
        (* the parser makes one only the body of a handler, which
           [handler_body] resolves *)
        assert false
  in
  { kind; loc = e.loc; node = e.node }

(* A block's statements, and the scope after them. *)
and block_stmts env sc (stmts : Parsed.stmt list) =
  let stmts, sc =
    List.fold_left
      (fun (acc, sc) (s : Parsed.stmt) ->
        match s with
        | Let { name; ty = t; value; mut } ->
            if mut && name.name = "_" then
              report env name.loc ~help:"write `let _ = ...`"
                "`var _` names nothing, so nothing can change it";
            let value = expr env sc value in
            let t = ty_opt env ~params:sc.tparams ~rows:(Body sc.rows) t in
            let b, sc = bind env sc name (if mut then By_var else By_let) in
            (match (t, value.kind) with
            | None, Record (Some n, _) ->
                (* `let b = Bag { ... }` is a `Bag` *)
                note_type sc b (Some (TyName (n, [])))
            | _ -> note_type sc b t);
            (Let { name = b; ty = t; value; mut } :: acc, sc)
        | Let_tuple { pat; value } ->
            let value = expr env sc value in
            no_duplicates env "variables" (pattern_vars pat);
            let pat, sc = binding env sc By_let pat in
            (Let_tuple { pat; value } :: acc, sc)
        | Expr e -> (Expr (expr env sc e) :: acc, sc))
      ([], sc) stmts
  in
  (List.rev stmts, sc)

(* The body of the handler [name] (ast.ml, [Handler]): the dependencies
   after `for`, each a declared one with operations, once; its state; and
   its arms, each the implementation of an operation of exactly one of
   them, a [Dep_op], and every operation implemented once. The state is
   bound as deep as the arms' bodies, so an arm can change it (mut.ml). *)
let handler_body env sc (name : ident) ~needs (e : Parsed.expr) :
    Resolved.expr_kind =
  match e.kind with
  | Handler { deps; state; arms; _ } ->
      let seen = Hashtbl.create 4 in
      let deps =
        List.filter_map
          (fun (d : tyname) ->
            (* [uses] reports a name that isn't a dependency *)
            match uses env [ d ] with
            | [ ({ tref = Named p; tloc } as t) ] -> (
                match (Hashtbl.find_opt seen p, dep_ops env p) with
                | Some first, _ ->
                    report env tloc ~help:"remove one of them"
                      ~labels:
                        [
                          ( first,
                            sprintf "the first `%s` is here" (show_tyname d) );
                        ]
                      (sprintf "`%s` is after `for` twice" (show_tyname d));
                    None
                | None, None ->
                    report env tloc
                      ~notes:
                        [
                          sprintf
                            "`%s` is only a name so far: what it can do comes \
                             in a later stage"
                            (show_tyname d);
                        ]
                      ~help:"remove it from the `for` list"
                      (sprintf
                         "`%s` has no operations, so a handler can't implement \
                          it"
                         (show_tyname d));
                    None
                | None, Some _ ->
                    Hashtbl.replace seen p tloc;
                    Some (p, t))
            | _ -> None)
          deps
      in
      let state, sc = block_stmts env sc state in
      let ops (p : Path.t) = Option.value (dep_ops env p) ~default:[] in
      let shown (p : Path.t) = sprintf "`%s`" p.name in
      let given = Hashtbl.create 8 in
      let arm (a : Parsed.handler_arm) : Resolved.handler_arm =
        let op = a.arm_name.name in
        let arm_op =
          match
            List.filter (fun ((p : Path.t), _) -> List.mem op (ops p)) deps
          with
          | [ ((p : Path.t), _) ] -> (
              match Hashtbl.find_opt given (p, op) with
              | Some first ->
                  report env a.arm_name.loc ~help:"remove one of them"
                    ~labels:[ (first, sprintf "the first `%s` is here" op) ]
                    (sprintf "`%s` is implemented twice" op);
                  Dep_op (p, op)
              | None ->
                  Hashtbl.replace given (p, op) a.arm_name.loc;
                  Dep_op (p, op))
          | [] when deps = [] ->
              (* what it implements was reported already *)
              Global (Path.make env.home op)
          | [] ->
              let all =
                List.concat_map
                  (fun ((p : Path.t), _) ->
                    List.map (fun o -> sprintf "`%s.%s`" p.name o) (ops p))
                  deps
              in
              report env a.arm_name.loc
                ?help:
                  (match all with
                  | [] -> None
                  | all ->
                      Some
                        (sprintf "the operations it implements: %s"
                           (String.concat ", " all)))
                (sprintf "%s %s no operation named `%s`"
                   (String.concat " and "
                      (List.map (fun (p, _) -> shown p) deps))
                   (if List.length deps = 1 then "has" else "have")
                   op);
              (* the placeholder an unknown name gets (see [lookup]) *)
              Global (Path.make env.home op)
          | owners ->
              (* it's none of theirs, but it's not missing from any *)
              List.iter
                (fun ((p : Path.t), _) ->
                  Hashtbl.replace given (p, op) a.arm_name.loc)
                owners;
              report env a.arm_name.loc
                ~notes:
                  [
                    sprintf
                      "an arm implements an operation by its name, so `%s` \
                       could be either"
                      op;
                  ]
                ~help:"implement them in two handlers"
                (sprintf "%s %s have an operation named `%s`"
                   (String.concat " and "
                      (List.map (fun (p, _) -> shown p) owners))
                   (if List.length owners = 2 then "both" else "all")
                   op);
              Global (Path.make env.home op)
        in
        let arm_impl =
          match a.arm_impl.kind with
          | Lambda (ps, body) ->
              no_duplicates env "parameters"
                (List.map (fun (p : Parsed.param) -> p.pname) ps);
              List.iter (not_self env ~help:"choose another name") ps;
              let ps, inner =
                params env sc
                  (fun (p : Parsed.param) ->
                    if p.pmode = Inout then By_inout else By_lambda)
                  ps
              in
              {
                kind = Lambda (ps, expr env inner body);
                loc = a.arm_impl.loc;
                node = a.arm_impl.node;
              }
          | _ -> (* the parser makes each arm a lambda *) assert false
        in
        { arm_op; arm_name = a.arm_name; arm_impl }
      in
      let arms = List.map arm arms in
      (* every operation of every dependency is implemented *)
      List.iter
        (fun ((p : Path.t), _) ->
          match
            List.filter (fun o -> not (Hashtbl.mem given (p, o))) (ops p)
          with
          | [] -> ()
          | missing ->
              report env name.loc
                ~help:
                  (sprintf "add %s"
                     (String.concat ", "
                        (List.map
                           (fun o -> sprintf "`%s(...) => ...`" o)
                           missing)))
                (sprintf "the handler `%s` doesn't implement %s" name.name
                   (String.concat ", "
                      (List.map (fun o -> sprintf "`%s.%s`" p.name o) missing))))
        deps;
      Handler { deps = List.map snd deps; needs; state; arms }
  | _ -> assert false

(* ---- declarations ---- *)

(* An opaque type is represented as another type, which can be another of
   the module's opaque types, but following them must reach a type that
   isn't one: otherwise `type A = opaque B` and `type B = opaque A` would
   say nothing about what either is. *)
let no_opaque_cycles env (items : Resolved.program) =
  let reps = Hashtbl.create 8 in
  List.iter
    (function
      | Type ({ type_body = Opaque { rep = t; _ }; _ } as td) ->
          Hashtbl.replace reps td.type_name.name t
      | Fn _ | Type _ | Import _ | Testing _ -> ())
    items;
  (* the opaque type of this module that [t] is, if it's one *)
  let opaque (t : Resolved.ty) =
    match t with
    | TyName ({ tref = Named p; _ }, _) when p.home = env.home ->
        Option.map (fun rep -> (p.name, rep)) (Hashtbl.find_opt reps p.name)
    | _ -> None
  in
  (* the types of a cycle already reported, so a cycle is reported once,
     from whichever of its types comes first *)
  let reported = ref [] in
  List.iter
    (function
      | Type ({ type_body = Opaque { rep = t; _ }; _ } as td)
        when not (List.mem td.type_name.name !reported) ->
          let start = td.type_name in
          (* [seen]: the opaque types followed so far, the last one first *)
          let rec follow seen t =
            match opaque t with
            | Some (n, _) when n = start.name ->
                let chain = List.rev (n :: seen) in
                reported := seen @ !reported;
                report env start.loc
                  ~help:"represent one of them as a type that isn't opaque"
                  (sprintf "`%s` is represented as itself: %s" n
                     (String.concat " → " chain))
            | Some (n, _) when List.mem n seen ->
                ()
                (* a cycle `start` leads to but isn't in: reported from
                      the cycle's own types *)
            | Some (n, rep) -> follow (n :: seen) rep
            | None -> ()
          in
          follow [ start.name ] t
      | Fn _ | Type _ | Import _ | Testing _ -> ())
    items

(* A named error set can include others, but never itself, by way of
   others or not: `type A = ! B | X` and `type B = ! A` would leave no tag
   either is made of. Sets of other modules can't include this module's,
   which imports them, so a cycle is always among the module's own. *)
let no_set_cycles env (items : Resolved.program) =
  let sets = Hashtbl.create 8 in
  List.iter
    (function
      | Type ({ type_body = Errors es; _ } as td) ->
          Hashtbl.replace sets td.type_name.name es
      | Fn _ | Type _ | Import _ | Testing _ -> ())
    items;
  (* the module's own sets [n] includes directly, in the order written *)
  let includes n =
    match Hashtbl.find_opt sets n with
    | Some (es : Resolved.errors) ->
        List.filter_map
          (function
            | Set { tref = Named p; _ } when p.home = env.home -> Some p.name
            | _ -> None)
          es.errs
    | None -> []
  in
  (* a way from [n] back to [goal], if there is one: the sets on it,
     ending with [goal] *)
  let rec back ~seen goal n =
    List.find_map
      (fun m ->
        if m = goal then Some [ m ]
        else if Hashtbl.mem seen m then None
        else (
          Hashtbl.replace seen m ();
          Option.map (fun way -> m :: way) (back ~seen goal m)))
      (includes n)
  in
  (* the sets of a cycle already reported, so a cycle is reported once,
     from whichever of its sets comes first *)
  let reported = ref [] in
  List.iter
    (function
      | Type ({ type_body = Errors _; _ } as td)
        when not (List.mem td.type_name.name !reported) -> (
          let n = td.type_name.name in
          match back ~seen:(Hashtbl.create 8) n n with
          | Some way ->
              reported := way @ !reported;
              report env td.type_name.loc
                ~help:
                  (if way = [ n ] then "remove it from its own list"
                   else "remove one of these sets from the one that includes it")
                (sprintf "`%s` includes itself: %s" n
                   (String.concat " → " (n :: way)))
          | None -> ())
      | Fn _ | Type _ | Import _ | Testing _ -> ())
    items

(* A function: a top-level one, or, with [owner], one of that type's
   members. A member has the type's parameters in scope, before its
   own, and is named after the type, `Stack.push` (ast.ml); its first
   parameter can be `self`, which has the type, `Stack<T>`. `self` is no
   other parameter. *)
let fn_def env ?(owner : Parsed.type_def option) (f : Parsed.fn_def) :
    Resolved.fn_def * Path.t list * (string * Path.t option) list =
  let outer = match owner with Some td -> td.type_params | None -> [] in
  let tparams = outer @ f.tparams in
  no_duplicates env "type parameters" tparams;
  List.iter
    (fun (t : ident) ->
      if Hashtbl.mem env.types t.name then
        report env t.loc ~help:"choose another name"
          (sprintf "`%s` is already the name of a type" t.name))
    f.tparams;
  no_duplicates env "parameters"
    (List.map (fun (p : Parsed.param) -> p.pname) f.params);
  List.iteri
    (fun i (p : Parsed.param) ->
      if p.pname.name = "self" then (
        (match (owner, i) with
        | None, _ ->
            not_self env p
              ~help:
                "choose another name, or move the function under its type, \
                 indented, to make it a method"
        | Some _, 0 -> ()
        | Some _, _ ->
            report env p.pname.loc ~help:"move it to the front"
              "`self` has to be the first parameter");
        match (owner, p.pty) with
        | Some td, Some t ->
            report env (written_loc t) ~help:"remove the type"
              (sprintf "`self` is always a `%s`, so its type isn't written"
                 td.type_name.name)
        | _ -> ()))
    f.params;
  (* where `self` is written, if it's the first parameter of a member,
     and so has the type *)
  let self =
    match (owner, f.params) with
    | Some _, p :: _ when p.pname.name = "self" -> Some p.pname.loc
    | _ -> None
  in
  (* the rows the signature names, as they're named *)
  let named = ref [] in
  let rows = Signature named in
  let sc =
    {
      locals = Env.empty;
      tparams = List.map (fun (t : ident) -> t.name) tparams;
      rows = [];
      depth = 0;
      fn = { last_id = 0; calls = []; dots = []; typed = [] };
    }
  in
  let ps, inner =
    params env sc ~rows
      (fun p -> match p.pmode with Inout -> By_inout | Read -> By_param)
      (* `self`'s type is the owner's, never what's written *)
      (List.map
         (fun (p : Parsed.param) ->
           if p.pname.name = "self" then { p with pty = None } else p)
         f.params)
  in
  let ps =
    match (owner, self, ps) with
    | Some td, Some loc, p :: rest ->
        let owner = Path.make env.home td.type_name.name in
        let owner_ty : Resolved.ty =
          match td.type_body with
          | Dep _ ->
              (* a dependency's `self` is an implementation, which needs what
                 its method uses, as `c: Clock` does *)
              TyImpl ([ { tref = Named owner; tloc = loc } ], None, loc)
          | Fields _ | Ctors _ | Opaque _ | Errors _ | Builtin ->
              TyName
                ( { tref = Named owner; tloc = loc },
                  List.mapi
                    (fun i _ -> TyName ({ tref = Param i; tloc = loc }, []))
                    td.type_params )
        in
        note_type sc p.pname (Some owner_ty);
        { p with pty = Some owner_ty } :: rest
    | _ -> ps
  in
  let ret = ty_opt env ~params:sc.tparams ~rows f.ret in
  let errs = Option.map (errors env ~params:sc.tparams ~rows) f.errors in
  let deps = Option.map (uses_of env ~rows) f.uses in
  let body, ret, deps =
    match f.body.kind with
    | Handler _ -> (
        (* a handler's function uses nothing, and gives the handler's type,
           which needs what its `uses` says; a private one's needs, if not
           written, are inferred *)
        List.iter
          (fun (p : Resolved.param) ->
            if p.pmode = Inout then
              report env p.pname.ident.loc ~help:"remove the `inout`"
                ~notes:
                  [
                    "calling a handler describes it, and each `with` that \
                     installs it keeps its parameters, so there's nothing to \
                     write back";
                  ]
                "a handler's parameter can't be `inout`")
          ps;
        (* what it needs is written in its signature, which can name a
           row: `handler h(f: fn() uses ..d) for N uses ..d` *)
        let needs =
          match f.body.kind with
          | Handler { needs; _ } -> Option.map (uses_of env ~rows) needs
          | _ -> None
        in
        let kind =
          handler_body env { inner with rows = !named } f.name ~needs f.body
        in
        let body : Resolved.expr = { f.body with kind } in
        let none = Some { deps = []; dtail = None; uloc = f.name.loc } in
        (* a handler gives an implementation of its dependencies: one's
           type, or the type that lists several *)
        let own =
          match kind with
          | Handler { deps; _ } ->
              List.map (fun (d : tname) -> { d with tloc = f.name.loc }) deps
          | _ -> []
        in
        match kind with
        | Handler { needs; _ } when (f.pub || needs <> None) && own <> [] ->
            (body, Some (TyImpl (own, needs, f.name.loc)), none)
        | _ -> (body, None, none))
    | _ -> (expr env { inner with rows = !named } f.body, ret, deps)
  in
  ( { f with tparams; params = ps; ret; errors = errs; uses = deps; body },
    List.sort_uniq compare sc.fn.calls,
    List.sort_uniq compare sc.fn.dots )

(* ---- reserved members ----

   A member with a reserved name is what a type does with an operator,
   `add` for `+`, an associated value, `zero`, its `key`, which says what
   equal means and so how its values are hashed and ordered, or its
   `show` (operators.md). Each is decided once, from its signature, so
   the signature is written in full: what an operator takes and gives,
   and that it doesn't fail or use a dependency, since `a + b` has no
   `try` in front (infer_top.ml checks its body keeps to that). On a
   public type it's public too, since it changes what `==` or `+` means in
   every module that uses the type. *)

(* The operator each operator method is, `add` for `+`, and the one
   [`-a`] is. *)
let operator_symbol = function
  | "add" -> "+"
  | "sub" -> "-"
  | "mul" -> "*"
  | "div" -> "/"
  | "rem" -> "%"
  | "neg" -> "-a"
  | m -> m

let binary_operators = [ "add"; "sub"; "mul"; "div"; "rem" ]

(* The reserved members of [td], as written, checked. *)
let reserved env (td : Parsed.type_def) =
  let tname = td.type_name.name in
  let own =
    tname
    ^
    match td.type_params with
    | [] -> ""
    | ps ->
        "<" ^ String.concat ", " (List.map (fun (p : ident) -> p.name) ps) ^ ">"
  in
  let numeric =
    match td.type_body with
    | Opaque { numeric = Some _; _ } -> true
    | _ -> false
  in
  List.iter
    (fun (o : Parsed.op) ->
      let f = o.op_fn in
      let name = f.name.name in
      let at = f.name.loc in
      let written_ret () = f.ret <> None in
      let others () =
        match f.params with
        | (s : Parsed.param) :: rest when s.pname.name = "self" -> Some (s, rest)
        | _ -> None
      in
      (* what a well-formed one looks like *)
      let shape () =
        match name with
        | "neg" -> sprintf "pub fn neg(self) -> %s = ..." own
        | "key" -> "fn key(self) -> K = ..."
        | "show" -> "pub fn show(self) -> Str = ..."
        | "zero" | "one" -> sprintf "pub let %s: %s = ..." name own
        | _ -> sprintf "pub fn %s(self, b: %s) -> %s = ..." name own own
      in
      let wrong why =
        report env at
          ~help:(sprintf "write `%s`" (shape ()))
          (sprintf "`%s` is reserved for %s, so %s" name
             (match name with
             | "key" -> "what equal means"
             | "show" -> "how a value is shown"
             | "zero" | "one" -> "an associated value"
             | _ -> sprintf "`%s`" (operator_symbol name))
             why)
      in
      let pure () =
        if f.errors <> None then wrong "it can't fail"
        else if f.uses <> None then wrong "it can't use a dependency"
      in
      let method_with n =
        match (o.op_kind, others ()) with
        | Op_value, _ -> wrong "it's a method"
        | Op_fn, None -> wrong "it's a method"
        | Op_fn, Some (s, rest) ->
            if s.pmode = Inout then wrong "it can't change `self`"
            else if List.length rest <> n then
              wrong
                (if n = 0 then "it takes only `self`"
                 else "it takes `self` and one more")
            else if
              (not (written_ret ()))
              || List.exists (fun (p : Parsed.param) -> p.pty = None) rest
            then wrong "its signature is written in full"
            else if List.exists (fun (p : Parsed.param) -> p.pmode = Inout) rest
            then wrong "it can't change what it's given"
            else pure ()
      in
      (match name with
      | "eq" | "hash" | "compare" ->
          report env at ~help:"write `fn key(self) -> K = ...`"
            (sprintf "`%s` can't be written: what equal means comes from `key`"
               name)
      | _ when List.mem name binary_operators -> method_with 1
      | "neg" | "key" | "show" -> method_with 0
      | "zero" | "one" -> (
          match (o.op_kind, f.ret) with
          | Op_fn, _ -> wrong "it's a value, written with `let`"
          | Op_value, None -> wrong "its type is written"
          | Op_value, Some _ -> ())
      | _ -> ());
      (* what `with numeric` gives already *)
      (if numeric then
         let gives =
           match name with
           | "add" | "sub" -> Some (sprintf "its `%s`" (operator_symbol name))
           | "neg" -> Some "its `-a`"
           | "zero" -> Some "its `zero`"
           | "key" -> Some "its `==` and its order"
           | _ -> None
         in
         match gives with
         | Some g ->
             report env at
               ~help:(sprintf "remove `%s`" name)
               (sprintf "`with numeric` gives `%s` %s already" tname g)
         | None -> ());
      (* a public type's are public *)
      if
        td.type_pub && (not f.pub)
        && List.mem name ("neg" :: "show" :: "zero" :: "one" :: binary_operators)
      then
        report env at
          ~help:
            (sprintf "write `pub %s`"
               (if o.op_kind = Op_value then "let" else "fn"))
          ~notes:
            [
              sprintf "it says what `%s` does in every module that uses `%s`"
                (match name with
                | "show" -> "show"
                | "zero" | "one" -> tname ^ "." ^ name
                | _ -> operator_symbol name)
                tname;
            ]
          (sprintf "`%s` of the public type `%s` has to be public" name tname))
    td.type_ops

(* What a reserved member's type is, where [reserved] can't tell from
   what's written: a type's own `show` makes a [Str], since it's how a
   value of it is shown wherever one is, and its `zero` and `one` are
   values of it (operators.md). *)
let reserved_types env (td : Resolved.type_def) =
  let own = Path.make env.home td.type_name.name in
  let written =
    own.name
    ^
    match td.type_params with
    | [] -> ""
    | ps ->
        "<" ^ String.concat ", " (List.map (fun (p : ident) -> p.name) ps) ^ ">"
  in
  List.iter
    (fun (o : Resolved.op) ->
      let f = o.op_fn in
      let name = f.name.name in
      match (name, o.op_kind, f.ret) with
      | "show", Op_fn, Some (TyName ({ tref = Named p; _ }, []))
        when p = Path.prelude "Str" ->
          ()
      | "show", Op_fn, Some _ ->
          report env f.name.loc ~help:"write `pub fn show(self) -> Str = ...`"
            "`show` is reserved for how a value is shown, so it makes a `Str`"
      | ("zero" | "one"), Op_value, Some (TyName ({ tref = Named p; _ }, _))
        when p = own ->
          ()
      | ("zero" | "one"), Op_value, Some _ ->
          report env f.name.loc
            ~help:(sprintf "write `pub let %s: %s = ...`" name written)
            (sprintf "`%s` is reserved for an associated value, so it's a `%s`"
               name written)
      | _ -> ())
    td.type_ops

(* An operator written more than once is one for each type on its right,
   told apart by that type's name (operators.md): two that take the same
   one can't be told apart. *)
let overloads env (td : Resolved.type_def) =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (o : Resolved.op) ->
      let f = o.op_fn in
      match f.params with
      | [ _; { pty = Some (TyName ({ tref = Named q; _ }, _)); _ } ]
        when List.mem f.name.name binary_operators -> (
          match Hashtbl.find_opt seen (f.name.name, q) with
          | Some first ->
              report env f.name.loc ~help:"remove one of them"
                ~labels:[ (first, "the first is here") ]
                (sprintf "`%s` has two `%s` that take %s" td.type_name.name
                   (operator_symbol f.name.name)
                   (Infer_msg.article q.name))
          | None -> Hashtbl.replace seen (f.name.name, q) f.name.loc)
      | _ -> ())
    td.type_ops

(* A type declaration, and its members: each item resolved as a
   function (see [fn_def]), with its path, the top-level functions it uses
   and the names it calls with a dot. *)
let type_def env (td : Parsed.type_def) :
    Resolved.type_def
    * (Path.t * Path.t list * (string * Path.t option) list) list =
  no_duplicates env "type parameters" td.type_params;
  let no_duplicate_fields (fs : Parsed.field list) =
    no_duplicates env "fields"
      (List.map (fun (f : Parsed.field) -> f.field_name) fs)
  in
  (match td.type_body with
  | Fields fs -> no_duplicate_fields fs
  | Ctors cs ->
      List.iter (fun (c : Parsed.ctor) -> no_duplicate_fields c.ctor_fields) cs
  | Dep ops ->
      no_duplicates env "operations"
        (List.map (fun (f : Parsed.field) -> f.field_name) ops)
  | Opaque _ | Errors _ | Builtin -> ());
  let params = List.map (fun (p : ident) -> p.name) td.type_params in
  let field (f : Parsed.field) : Resolved.field =
    { field_name = f.field_name; field_ty = ty env ~params f.field_ty }
  in
  let type_body : tname type_body =
    match td.type_body with
    | Fields fs -> Fields (List.map field fs)
    | Ctors cs ->
        Ctors
          (List.map
             (fun (c : Parsed.ctor) : Resolved.ctor ->
               {
                 ctor_name = c.ctor_name;
                 ctor_fields = List.map field c.ctor_fields;
               })
             cs)
    | Opaque { rep; numeric } ->
        let rep = ty env ~params rep in
        (* only a number's operators can be given *)
        (match (numeric, rep) with
        | Some _, TyName ({ tref = Named p; _ }, [])
          when p = Path.prelude "Int" || p = Path.prelude "Float" ->
            ()
        | Some at, _ ->
            report env at ~help:"write it by hand: `pub fn add(self, b: ...)`"
              "`with numeric` is for an opaque `Int` or `Float`"
        | None, _ -> ());
        Opaque { rep; numeric }
    | Errors es -> Errors (errors env ~params es)
    | Dep ops -> Dep (List.map field ops)
    | Builtin -> Builtin
  in
  let tname = td.type_name.name in
  (* each item has a name of its own, which isn't a field's: `s.items`
     would be one or the other *)
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (o : Parsed.op) ->
      let id = o.op_fn.name in
      match Hashtbl.find_opt seen id.name with
      | Some _ when List.mem id.name binary_operators ->
          (* one for each type on its right: [overloads] *)
          ()
      | Some first ->
          report env id.loc ~help:"rename one of them"
            ~labels:[ (first, sprintf "the first `%s` is here" id.name) ]
            (sprintf "`%s` has two members named `%s`" tname id.name)
      | None -> Hashtbl.replace seen id.name id.loc)
    td.type_ops;
  reserved env td;
  (* and so does a dependency's operation: `Clock.now` would be one or the
     other *)
  (match td.type_body with
  | Dep ops ->
      List.iter
        (fun (o : Parsed.op) ->
          let id = o.op_fn.name in
          match
            List.find_opt
              (fun (f : Parsed.field) -> f.field_name.name = id.name)
              ops
          with
          | Some op ->
              Diag.report env.sink
                (Diag.make id.loc ~help:"rename one of them"
                   ~labels:
                     [
                       ( op.field_name.loc,
                         sprintf "the operation `%s` is here" id.name );
                     ]
                   ~notes:
                     [
                       sprintf
                         "`%s.%s` has to mean one thing: calling the installed \
                          implementation's `%s`, or this member"
                         tname id.name id.name;
                     ]
                   (sprintf "`%s` has an operation and a member both named `%s`"
                      tname id.name))
          | None -> ())
        td.type_ops
  | Fields _ | Ctors _ | Opaque _ | Errors _ | Builtin -> ());
  (match td.type_body with
  | Fields fs ->
      List.iter
        (fun (o : Parsed.op) ->
          let id = o.op_fn.name in
          match
            List.find_opt
              (fun (f : Parsed.field) -> f.field_name.name = id.name)
              fs
          with
          | Some f ->
              let what =
                match (o.op_kind, o.op_fn.params) with
                | Op_value, _ -> "an associated value"
                | Op_fn, p :: _ when p.pname.name = "self" -> "a method"
                | Op_fn, _ -> "an associated function"
              in
              report env id.loc ~help:"rename one of them"
                ~labels:
                  [
                    (f.field_name.loc, sprintf "the field `%s` is here" id.name);
                  ]
                (sprintf "`%s` has a field and %s both named `%s`" tname what
                   id.name)
          | None -> ())
        td.type_ops
  | Ctors _ | Opaque _ | Errors _ | Dep _ | Builtin -> ());
  let type_ops, calls =
    List.split
      (List.map
         (fun (o : Parsed.op) ->
           let f, calls, dots = fn_def env ~owner:td o.op_fn in
           ( { op_kind = o.op_kind; op_fn = f },
             (Ast.fn_path env.home f, calls, dots) ))
         td.type_ops)
  in
  let td = { td with type_body; type_ops } in
  overloads env td;
  reserved_types env td;
  (td, calls)

(* ---- what a public declaration can mention ----

   A public function's signature and a public type's fields are part of
   the module's interface, and the interface holds no private types
   (iface.ml). A dependent can't do anything with a type it can't see, so
   neither can mention one. [private_] holds the module's private types,
   by name, with where each is declared. *)

(* Every type named in [t], with where it's named, left to right. *)
let rec named_in (t : Resolved.ty) =
  match t with
  | TyName ({ tref = Named p; tloc }, args) ->
      (p, tloc) :: List.concat_map named_in args
  | TyName ({ tref = Param _; _ }, args) -> List.concat_map named_in args
  | TyFn (ps, ret, errs, u, _) ->
      List.concat_map named_in ps
      @ Option.fold ~none:[] ~some:named_in ret
      @ Option.fold ~none:[] ~some:named_in_errors errs
      @ Option.fold ~none:[] ~some:named_in_uses u
  | TyImpl (ds, u, _) ->
      List.filter_map
        (fun (d : tname) ->
          match d.tref with Named p -> Some (p, d.tloc) | Param _ -> None)
        ds
      @ Option.fold ~none:[] ~some:named_in_uses u
  | TyInout (t, _) -> named_in t
  | TyTuple (ts, _) -> List.concat_map named_in ts
  | TyErrors es -> named_in_errors es

(* The dependencies a `uses` lists. *)
and named_in_uses (u : Resolved.uses) =
  List.filter_map
    (fun (d : tname) ->
      match d.tref with Named p -> Some (p, d.tloc) | Param _ -> None)
    u.deps

(* The same, in an error set: the named sets it includes, and the types in
   its tags' payloads. *)
and named_in_errors (es : Resolved.errors) =
  List.concat_map
    (function
      | Tag (_, ps) ->
          List.concat_map
            (fun (p : Resolved.payload) -> named_in p.payload_ty)
            ps
      | Set { tref = Named p; tloc } -> [ (p, tloc) ]
      | Set { tref = Param _; _ } -> [])
    es.errs

(* Report each private type of [named], the types named somewhere and
   where. [say] words the error for each one. *)
let no_private_named env ~private_ ~say named =
  List.iter
    (fun ((p : Path.t), loc) ->
      if p.home = env.home then
        match Hashtbl.find_opt private_ p.name with
        | Some decl ->
            report env loc
              ~help:(sprintf "mark `%s` `pub`" p.name)
              ~labels:
                [
                  (decl, sprintf "`%s` is declared here, without `pub`" p.name);
                ]
              (sprintf "%s, which is private to this module" (say p))
        | None -> ())
    named

(* Report each private type in [t]. [whole] words the error when [t] is
   that type, [inside] when it's somewhere in [t]. *)
let no_private env ~private_ ~whole ~inside (t : Resolved.ty) =
  let is_whole p =
    match t with TyName ({ tref = Named q; _ }, _) -> p = q | _ -> false
  in
  no_private_named env ~private_ (named_in t) ~say:(fun (p : Path.t) ->
      if is_whole p then whole p.name else inside p.name)

(* Report each private type in the error set [es]: a set it includes, which
   [set] words, or a type in a tag's payload, which [tag] words, given the
   tag's name. *)
let no_private_errors env ~private_ ~set ~tag (es : Resolved.errors) =
  List.iter
    (function
      | Tag ((t : ident), ps) ->
          List.iter
            (fun (p : Resolved.payload) ->
              no_private_named env ~private_ (named_in p.payload_ty)
                ~say:(fun (q : Path.t) -> tag t.name q.name))
            ps
      | Set _ as e ->
          no_private_named env ~private_
            (named_in_errors { es with errs = [ e ] })
            ~say:(fun (q : Path.t) -> set q.name))
    es.errs

let no_leaks env ~private_ ~groups (items : Resolved.program) =
  let fn_ (f : Resolved.fn_def) =
    let kind = if Ast.is_handler f then "handler" else "fn" in
    let check ~verb t =
      no_private env ~private_ t
        ~whole:(sprintf "`pub %s %s` %s `%s`" kind (Ast.fn_name f) verb)
        ~inside:
          (sprintf "`pub %s %s`'s signature mentions `%s`" kind (Ast.fn_name f))
    in
    List.iter
      (fun (p : Resolved.param) -> Option.iter (check ~verb:"takes") p.pty)
      f.params;
    (match f.ret with
    | Some (TyImpl (_, needs, _)) when Ast.is_handler f ->
        (* what it implements [handler] checks; what it needs is its own *)
        Option.iter
          (fun u ->
            no_private_named env ~private_ (named_in_uses u)
              ~say:(fun (p : Path.t) ->
                sprintf "`pub handler %s` needs `%s`" (Ast.fn_name f) p.name))
          needs
    | ret -> Option.iter (check ~verb:"returns") ret);
    Option.iter
      (no_private_errors env ~private_
         ~set:(sprintf "`pub fn %s` can fail with `%s`" (Ast.fn_name f))
         ~tag:(sprintf "`pub fn %s`'s error `%s` mentions `%s`" (Ast.fn_name f)))
      f.errors;
    Option.iter
      (fun u ->
        no_private_named env ~private_ (named_in_uses u)
          ~say:(fun (p : Path.t) ->
            sprintf "`pub fn %s` uses `%s`" (Ast.fn_name f) p.name))
      f.uses
  in
  (* an associated value is a function of no parameters (ast.ml) *)
  let value (f : Resolved.fn_def) =
    Option.iter
      (no_private env ~private_
         ~whole:(sprintf "`pub let %s` is a `%s`" (Ast.fn_name f))
         ~inside:(sprintf "`pub let %s`'s type mentions `%s`" (Ast.fn_name f)))
      f.ret
  in
  (* a public handler's interface says what it implements *)
  let handler (f : Resolved.fn_def) =
    match f.body.kind with
    | Handler { deps; _ } ->
        no_private_named env ~private_
          (List.filter_map
             (fun (d : tname) ->
               match d.tref with Named p -> Some (p, d.tloc) | Param _ -> None)
             deps)
          ~say:(fun (p : Path.t) ->
            sprintf "`pub handler %s` implements `%s`" (Ast.fn_name f) p.name)
    | _ -> ()
  in
  (* a public group's parameters, which each of its tests' functions
     has; each error is reported once, however many tests it has *)
  let group g (f : Resolved.fn_def) =
    List.iter
      (fun (p : Resolved.param) ->
        Option.iter
          (no_private env ~private_
             ~whole:(sprintf "`pub group %s` takes `%s`" g)
             ~inside:(sprintf "`pub group %s`'s parameters mention `%s`" g))
          p.pty)
      f.params
  in
  List.iter
    (function
      | Fn (f : Resolved.fn_def) when f.pub ->
          handler f;
          fn_ f
      | Fn f when List.mem_assoc f.name.name groups ->
          group (List.assoc f.name.name groups) f
      | Type (td : Resolved.type_def) when td.type_pub -> (
          (* a public type's public items are in the interface too *)
          List.iter
            (fun (o : Resolved.op) ->
              if o.op_fn.pub then
                match o.op_kind with
                | Op_fn -> fn_ o.op_fn
                | Op_value -> value o.op_fn)
            td.type_ops;
          let t = td.type_name.name in
          let field (fd : Resolved.field) =
            no_private env ~private_ fd.field_ty
              ~whole:(sprintf "`pub type %s` has a field of type `%s`" t)
              ~inside:
                (sprintf "`pub type %s`'s field `%s` mentions `%s`" t
                   fd.field_name.name)
          in
          let ctor (c : tname ctor) (fd : Resolved.field) =
            let c = c.ctor_name.name in
            no_private env ~private_ fd.field_ty
              ~whole:(sprintf "`pub type %s`'s constructor `%s` holds `%s`" t c)
              ~inside:
                (sprintf "`pub type %s`'s constructor `%s` mentions `%s`" t c)
          in
          match td.type_body with
          | Fields fs -> List.iter field fs
          | Ctors cs -> List.iter (fun c -> List.iter (ctor c) c.ctor_fields) cs
          | Dep ops ->
              List.iter
                (fun (fd : Resolved.field) ->
                  no_private env ~private_ fd.field_ty
                    ~whole:
                      (sprintf "`pub dep %s`'s operation `%s` is a `%s`" t
                         fd.field_name.name)
                    ~inside:
                      (sprintf "`pub dep %s`'s operation `%s` mentions `%s`" t
                         fd.field_name.name))
                ops
          | Opaque _ | Builtin ->
              (* its representation isn't in the interface, so it can be a
                 private type *)
              ()
          | Errors es ->
              no_private_errors env ~private_ es
                ~set:(sprintf "`pub type %s` includes `%s`" t)
                ~tag:(sprintf "`pub type %s`'s error `%s` mentions `%s`" t))
      | Fn _ | Type _ | Import _ | Testing _ -> ())
    items

(* What isn't used is reported once: the whole import, or one of the types
   it names, or the name after its `as`. [found] are the types step 2 of a
   lookup found, so each one's import by name is used. *)
let unused_imports sink (r : t) ~found =
  let report ?help loc msg = Diag.report sink (Diag.make ?help loc msg) in
  List.iter
    (fun u ->
      let i = u.import in
      let unused =
        List.filter
          (fun (n : ident) -> not (List.mem (Path.make i.path n.name) found))
          u.unseen
      in
      let last = List.nth i.segments (List.length i.segments - 1) in
      if
        (not u.alias_used) && unused = u.names && (u.names <> [] || i.names = [])
      then
        report i.iloc ~help:"remove it"
          (sprintf "`%s` is imported but never used" i.path)
      else (
        List.iter
          (fun (n : ident) ->
            report n.loc ~help:"remove it"
              (sprintf "`%s` is imported but never used" n.name))
          unused;
        (* `as x` wasn't needed: the types it imports are used by name *)
        if (not u.alias_used) && i.alias.loc <> last.loc then
          report i.alias.loc
            ~help:(sprintf "remove the `as %s`" i.alias.name)
            (sprintf "`%s` is never used" i.alias.name)))
    r.import_uses

(* The method of the module's own types, declared in [items], that a dot
   call of [m] calls (see [t.methods]), if it can be told from its
   receiver's type [known], when that's written. A receiver of another
   module's type calls none of them. Inside its module an opaque type is
   also what it's represented as, so a receiver of one that has no [m]
   itself may call any of them: which one is left to inference, as it is
   when the receiver's type isn't written. *)
let dot_callees ~home (items : Resolved.program) (m, known) =
  let types =
    List.filter_map
      (function
        | Type (td : Resolved.type_def) -> Some td
        | Fn _ | Import _ | Testing _ -> None)
      items
  in
  let method_ (td : Resolved.type_def) =
    List.find_opt
      (fun (o : Resolved.op) ->
        o.op_fn.name.name = m
        &&
        match (o.op_kind, o.op_fn.params) with
        | Op_fn, p :: _ -> p.pname.ident.name = "self"
        | _ -> false)
      td.type_ops
  in
  let callees (td : Resolved.type_def) =
    match method_ td with
    | Some o when not (Ast.spelled o.op_fn) -> [ Ast.fn_path home o.op_fn ]
    | Some _ | None -> []
  in
  let own (p : Path.t) =
    List.find_opt
      (fun (td : Resolved.type_def) ->
        p.home = home && td.type_name.name = p.name)
      types
  in
  match Option.map own known with
  | Some (Some td) -> (
      match (method_ td, td.type_body) with
      | None, Opaque _ -> []
      | _ -> callees td)
  | Some None | None -> []

let program sink ~home ~imports ?(groups = []) (prog : Parsed.program) =
  (* tests are functions by now (test_items.ml); any left are ignored *)
  let prog = List.filter (function Testing _ -> false | _ -> true) prog in
  (* each import, with the interface of the module it imports; the driver
     passes the interface of every module the program imports *)
  let imported =
    List.filter_map
      (function
        | Import (i : import) ->
            Some (i, List.find (fun (m : Iface.t) -> m.home = i.path) imports)
        | Fn _ | Type _ | Testing _ -> None)
      prog
  in
  let env =
    {
      sink;
      home;
      types = Hashtbl.create 16;
      values = Hashtbl.create 16;
      imports = imported;
      ifaces = imports;
      own_ops = Hashtbl.create 8;
      own_numeric = Hashtbl.create 8;
      own_sets = Hashtbl.create 8;
      own_deps = Hashtbl.create 8;
      modules =
        List.fold_left
          (fun acc ((i : import), iface) -> Env.add i.alias.name (i, iface) acc)
          Env.empty imported;
      used = Hashtbl.create 8;
      used_types = Hashtbl.create 8;
    }
  in
  (* what's in scope bare: the prelude, which every module imports
     without asking, and the module's own names. Another module's are
     written with its alias. *)
  let prelude =
    List.filter (fun (m : Iface.t) -> m.home = Path.prelude_home) imports
  in
  (* the types in scope: the prelude's, then those imported by name, then
     this module's own, so types can refer to types declared further down
     the file *)
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (d : Iface.type_decl) ->
          Hashtbl.replace env.types d.path.name (d.path, List.length d.params))
        iface.types)
    prelude;
  let imported_type name =
    List.find_map (fun iface -> Iface.find_type iface name) prelude
  in
  (* each type imported by name, `.{Plan}`, by its name, with where it's
     imported *)
  let by_name = Hashtbl.create 8 in
  List.iter
    (fun ((i : import), iface) ->
      List.iter
        (fun (n : ident) ->
          match
            (Iface.find_type iface n.name, Hashtbl.find_opt by_name n.name)
          with
          | None, _ ->
              report env n.loc ~help:"if it's defined there, mark it `pub`"
                (sprintf "`%s` has no public type `%s`" i.path n.name)
          | Some _, Some ((first : ident), _) ->
              report env n.loc ~help:"import only one of them by name"
                ~labels:[ (first.loc, sprintf "the first `%s` is here" n.name) ]
                (sprintf "there are two types imported as `%s`" n.name)
          | Some d, None ->
              Hashtbl.replace by_name n.name (n, d.path);
              Hashtbl.replace env.types n.name (d.path, List.length d.params))
        i.names)
    env.imports;
  List.iter
    (function
      | Type (td : Parsed.type_def) ->
          let kind (o : Parsed.op) : Iface.op_kind =
            match (o.op_kind, o.op_fn.params) with
            | Op_value, _ -> Value
            | Op_fn, p :: _ when p.pname.name = "self" -> Method
            | Op_fn, _ -> Function
          in
          let fields =
            match td.type_body with
            | Fields fs ->
                List.map (fun (f : Parsed.field) -> f.field_name.name) fs
            | Ctors _ | Opaque _ | Errors _ | Dep _ | Builtin -> []
          in
          (match td.type_body with
          | Errors _ -> Hashtbl.replace env.own_sets td.type_name.name ()
          | Opaque { numeric = Some _; _ } ->
              Hashtbl.replace env.own_numeric td.type_name.name ()
          | Dep ops ->
              if not (Hashtbl.mem env.own_deps td.type_name.name) then
                Hashtbl.replace env.own_deps td.type_name.name
                  (List.map (fun (f : Parsed.field) -> f.field_name.name) ops)
          | Fields _ | Ctors _ | Opaque _ | Builtin -> ());
          (* a built-in type's members are its intrinsics, then those its
             declaration writes *)
          let built_in =
            match (td.type_body, imported_type td.type_name.name) with
            | Builtin, Some d ->
                List.map
                  (fun (o : Iface.op) -> (o.oname, o.okind))
                  (Iface.members d)
            | _ -> []
          in
          if not (Hashtbl.mem env.own_ops td.type_name.name) then
            Hashtbl.replace env.own_ops td.type_name.name
              ( built_in
                @ List.map
                    (fun (o : Parsed.op) -> (o.op_fn.name.name, kind o))
                    td.type_ops,
                fields )
      | Fn _ | Import _ | Testing _ -> ())
    prog;
  let first_local = Hashtbl.create 16 in
  List.iter
    (function
      | Type (td : Parsed.type_def) -> (
          let name = td.type_name in
          match
            (imported_type name.name, Hashtbl.find_opt first_local name.name)
          with
          | Some { body = Builtin; params; _ }, _
            when home = Path.prelude_home && td.type_body = Builtin
                 && List.length params = List.length td.type_params ->
              (* the prelude's source writes a built-in type's other
                 members: `pub type Array<T> = builtin` (ast.ml) *)
              ()
          | Some { body = Builtin; _ }, _ ->
              report env name.loc ~help:"choose another name"
                (sprintf "`%s` is a built-in type" name.name)
          | Some { path; body; _ }, _ when path.home = Path.prelude_home ->
              (* the prelude's source isn't the program's, so there's no
                 first one to point at *)
              report env name.loc ~help:"choose another name"
                ~notes:
                  [
                    "the prelude's types and dependencies, like `Option`, \
                     `Time` and `Clock`, can be named in every module";
                  ]
                (sprintf "the prelude already has a %s named `%s`"
                   (match body with Dep _ -> "dependency" | _ -> "type")
                   name.name)
          | Some { loc = first; _ }, _ ->
              report env name.loc ~help:"rename one of them"
                ~labels:
                  (List.map
                     (fun l -> (l, sprintf "the first `%s` is here" name.name))
                     (Option.to_list first))
                (sprintf "there are two types named `%s`" name.name)
          | None, Some first ->
              report env name.loc ~help:"rename one of them"
                ~labels:[ (first, sprintf "the first `%s` is here" name.name) ]
                (sprintf "there are two types named `%s`" name.name)
          | None, None when Hashtbl.mem by_name name.name ->
              let (imp : ident), _ = Hashtbl.find by_name name.name in
              report env name.loc
                ~help:
                  (sprintf "rename it, or stop importing `%s` by name" name.name)
                ~labels:[ (imp.loc, sprintf "`%s` is imported here" name.name) ]
                (sprintf "`%s` is already the name of an imported type"
                   name.name)
          | None, None ->
              Hashtbl.replace first_local name.name name.loc;
              Hashtbl.replace env.types name.name
                (Path.make home name.name, List.length td.type_params))
      | Fn _ | Import _ | Testing _ -> ())
    prog;
  (* the functions in scope: the prelude's, then this module's own *)
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (v : Iface.value) ->
          let name =
            match Prelude.find (Path.make iface.home v.vname) with
            | Some x -> Intrinsic x
            | _ -> Global (Path.make iface.home v.vname)
          in
          Hashtbl.replace env.values v.vname name)
        iface.values)
    prelude;
  let fns =
    List.filter_map
      (function
        | Fn (f : Parsed.fn_def) -> Some f
        | Type _ | Import _ | Testing _ -> None)
      prog
  in
  (* a handler is a function of its parameters, so it shares their names *)
  let seen = Hashtbl.create 16 in
  let what (f : Parsed.fn_def) =
    if Ast.is_handler f then "handler" else "function"
  in
  List.iter
    (fun (f : Parsed.fn_def) ->
      let id = f.name in
      match Hashtbl.find_opt seen id.name with
      | Some (first, w) ->
          report env id.loc ~help:"rename one of them"
            ~labels:
              [
                ( first,
                  if w = what f then sprintf "the first `%s` is here" id.name
                  else sprintf "the %s `%s` is here" w id.name );
              ]
            (if w = what f then sprintf "there are two %ss named `%s`" w id.name
             else sprintf "a %s and a %s are both named `%s`" w (what f) id.name)
      | None -> Hashtbl.replace seen id.name (id.loc, what f))
    fns;
  List.iter
    (fun (f : Parsed.fn_def) ->
      if Hashtbl.mem env.values f.name.name then
        report env f.name.loc ~help:"choose another name"
          (sprintf "`%s` is already a function in the prelude" f.name.name);
      not_an_alias env f.name)
    fns;
  List.iter
    (fun (f : Parsed.fn_def) ->
      Hashtbl.replace env.values f.name.name
        (Global (Path.make home f.name.name)))
    fns;
  let items, calls =
    List.split
      (List.map
         (function
           | Type td ->
               let td, calls = type_def env td in
               (Type td, calls)
           | Fn f ->
               let f', calls, dots = fn_def env f in
               (Fn f', [ (Ast.fn_path home f', calls, dots) ])
           | Import i -> (Import i, [])
           | Testing _ -> (* left out above *) assert false)
         prog)
  in
  let private_ = Hashtbl.create 8 in
  List.iter
    (function
      | Type (td : Resolved.type_def) when not td.type_pub ->
          Hashtbl.replace private_ td.type_name.name td.type_name.loc
      | Fn _ | Type _ | Import _ | Testing _ -> ())
    items;
  no_leaks env ~private_ ~groups items;
  no_opaque_cycles env items;
  no_set_cycles env items;
  let types =
    List.filter_map
      (function
        | Type td ->
            let d = Iface.of_type_def ~home ~sets:(sets env items) td in
            (* a built-in type the prelude writes members of has its
               intrinsics too *)
            Some
              (match (td.type_body, imported_type td.type_name.name) with
              | Builtin, Some (intrinsic : Iface.type_decl)
                when intrinsic.body = Builtin ->
                  Iface.join intrinsic d
              | _ -> d)
        | Fn _ | Import _ | Testing _ -> None)
      items
  in
  (* [imported n] says whether the name [n] in `.{}` imported a type; one
     that didn't was reported already *)
  let imported (n : ident) =
    match Hashtbl.find_opt by_name n.name with
    | Some ((first : ident), _) -> first.loc = n.loc
    | None -> false
  in
  let import_uses =
    List.map
      (fun ((i : import), _) ->
        let names = List.filter imported i.names in
        {
          import = i;
          alias_used = Hashtbl.mem env.used i.alias.name;
          names;
          unseen =
            List.filter
              (fun (n : ident) ->
                not (Hashtbl.mem env.used_types (Path.make i.path n.name)))
              names;
        })
      env.imports
  in
  let scope =
    Hashtbl.fold (fun name (p, _) acc -> (name, p) :: acc) env.types []
    |> List.sort compare
  in
  {
    home;
    prog = items;
    types;
    calls =
      Path.Map.of_list
        (List.map (fun (f, calls, _) -> (f, calls)) (List.concat calls));
    methods =
      Path.Map.of_list
        (List.map
           (fun (f, _, dots) ->
             ( f,
               List.sort_uniq compare
                 (List.concat_map (dot_callees ~home items) dots) ))
           (List.concat calls));
    scope;
    aliases =
      List.map (fun ((i : import), _) -> (i.path, i.alias.name)) env.imports;
    import_uses;
  }

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
  wirings : Iface.wiring list;
      (** the module's wirings, flattened, in the order they're declared *)
  through : (int * Loc.t, Path.t) Hashtbl.t;
      (** each member function of a dependency called through an alias of it,
          `Events.items()` for `dep Events = Chan<Event>`, by the node of the
          member as written, `Events.items`, with the alias: it runs with the
          alias's implementation as its dependency's (compiler.md, "Services
          stage", step 5) *)
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
  own_tests : (string, unit) Hashtbl.t;
      (** the test items in scope bare, by name: the module's own, `test fn`,
          and the prelude's, `replay` *)
  own_private : (string, unit) Hashtbl.t;
      (** the module's own private items that aren't test items, which a test
          doesn't see: its functions by name, its types' members by `Type.name`,
          and its types by name, each after `type `. One is taken out once a
          test's use of it is reported (see [check_private]) *)
  mutable in_test : bool;
      (** whether the function being resolved is test code, which sees the
          module as an importer does (testing.md, "Tests are specifications") *)
  sees_all : bool;
      (** whether test code sees everything, as it does when `ren console`
          checks the program, so a test that reaches past the interface doesn't
          keep the console shut *)
  own_deps : (string, string list) Hashtbl.t;
      (** the module's own dependencies, by name, each with its operations *)
  own_aliases : (string, tyname) Hashtbl.t;
      (** the module's own aliases of a dependency, `dep Jobs = Chan<Job>`, by
          name, each with the name of the one it names *)
  named_ctors : (string, string) Hashtbl.t;
      (** each by-name constructor of a sum type in scope bare, by its name,
          with the sum's name: which a bare `Name { ... }` can also mean (see
          [braces_name]) *)
  sums : (string, unit) Hashtbl.t;  (** the sum types in scope bare, by name *)
  own_sums : (string, Iface.ctor list) Hashtbl.t;
      (** the module's own sum types, by name, with their constructors, which
          a variant type is one of ([variant_type]) *)
  modules : (import * Iface.t) Env.t;  (** the same, by alias *)
  used : (string, unit) Hashtbl.t;  (** the aliases used *)
  used_types : (Path.t, unit) Hashtbl.t;
      (** the types used that are another module's: an import nothing uses is an
          error *)
  wirings : (string, Iface.wiring) Hashtbl.t;
      (** the module's own wirings, by name, flattened ([wiring_shape]) *)
  wiring_defs : (string, Parsed.wiring_def) Hashtbl.t;
      (** and as they're written *)
  services : (string, service) Hashtbl.t;
      (** the module's own services, by name ([service_items]) *)
  installs : (Loc.t, unit) Hashtbl.t;
      (** where a `with` or a wiring installs a service, `Kv(cfg)`, by where
          that's written: the only place a service's name is called
          ([installed]) *)
  through : (int * Loc.t, Path.t) Hashtbl.t;
      (** each member function of a dependency written through an alias of
          it, `Events.items` for `dep Events = Chan<Event>`, by its node, with
          the alias ([t.through]) *)
  not_data : (string, string * string) Hashtbl.t;
      (** the module's own dependencies that have no `D.Call`, by name, each
          with an operation that isn't data and why ([call_types]) *)
}

(* A service of the module (language.md §4), as its members see it: its
   members' names, and what each member takes first, its parameters, then
   its state ([service_items]): for each, whether it's passed `inout`, as
   a `var` of its state is. *)
and service = { members : string list; passes : bool list }

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
  loop : loop_at;  (** where a `break` would go *)
  fn : fn_state;
  next : next_in;
      (** whether the code is a handler's, and which: in one declared `over` a
          dependency, `next` is the implementation under it (handlers.md,
          "`next`") *)
}

(* Where a `break` in the code being resolved would go: nowhere; to the
   innermost `while` or `for` around it; or nowhere, since the loop around
   it is outside the block it's in, which can't jump out of the call it's
   passed to, or outside the `with` it's in, whose handlers are given
   what its body ends in. *)
and loop_at = No_loop | In_loop | Loop_outside | Loop_past_with

(* What `next` is in the code being resolved: nothing, outside a handler;
   in a handler for these dependencies, nothing either, but a message says
   how to get one; in a handler over these, the implementation under it. *)
and next_in =
  | No_next
  | In_for of string * Path.t list  (** the handler's name, and its `for` *)
  | In_over of string * Path.t list  (** the handler's name, and its `over` *)
  | In_inline
      (** in an inline handler, which has none, and whose dependency is known
          only to inference, which says so (Infer_expr, [inline_handler]) *)
  | In_any of string * int
      (** in the arm of a handler `over any`, [h]: it has no `next`, but the
          call it runs for, the local of this id, `call` in `call => ...`
          (compiler.md, "`over any` and `retry`") *)

and fn_state = {
  mutable last_id : int;  (** the last binder id handed out *)
  mutable calls : Path.t list;
  mutable dots : (string * Path.t option) list;
      (** the names called with a dot, `s.push(1)`, each with its receiver's
          type, if it's written (see [receiver_type]) *)
  mutable typed : (int * Path.t) list;
      (** the locals whose type is written, by binder id, with that type *)
  test : bool;
      (** whether the function is test code (ast.ml), which alone can use a test
          item *)
  mutable made : int;
      (** the last node this pass numbered in the function, for what a wiring
          is flattened into ([use_wiring]): below -1, apart from the parser's
          and Test_items' *)
  mutable member_of : (string * service * binder list option) option;
      (** the service the function is a member of, if it's one, and the
          parameters it shares, the function's first, which a call of
          another member passes on ([service_items]); or [None] for them
          in the handler the service is made with, whose own code is its
          state's, set up before any member can run *)
}

let report env ?help ?notes ?labels loc msg =
  Diag.report env.sink (Diag.make ?help ?notes ?labels loc msg)

(* [written], one of the module's private items, is used by test code,
   which sees what an importer sees (testing.md, "Tests are
   specifications"). *)
let private_in_test env loc written =
  report env loc
    ~notes:[ sprintf "a test is a specification of `%s`'s interface" env.home ]
    ~help:
      (sprintf "mark it `pub`, or explore it in the console: `ren console %s`"
         env.home)
    (sprintf "`%s` is private, and a test sees what an importer sees" written)

(* Whether test code is using the module's own private item [key] (see
   [own_private]), reported at [loc] as [written]. It's reported at its
   first use only: the fix, marking it `pub` or exploring it instead, is
   the same at every one, so it's taken out of [own_private] then. *)
let check_private env loc ~key written =
  if env.in_test && Hashtbl.mem env.own_private key then (
    private_in_test env loc written;
    Hashtbl.remove env.own_private key)

(* A name bound inside a handler declared `over` a dependency, or one of
   its parameters, that's `next`, which is the implementation under it
   there (handlers.md, "`next`"). *)
let next_bound env loc =
  report env loc ~help:"choose another name"
    "`next` is the implementation under this handler, so nothing in it can be \
     named `next`"

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
  (match sc.next with
  | In_over _ when id.name = "next" -> next_bound env id.loc
  | In_over _ | In_for _ | In_inline | In_any _ | No_next -> ());
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
let rec dep_ops ?(depth = 0) env (p : Path.t) =
  (* an alias has the operations of the one it names; one that names
     itself, through others or not, is reported where it's declared
     ([type_def]), and has none *)
  if depth > 16 then None
  else if p.home = env.home then
    match Hashtbl.find_opt env.own_deps p.name with
    | Some ops -> Some ops
    | None -> (
        match Hashtbl.find_opt env.own_aliases p.name with
        | Some t -> (
            match alias_target env t with
            | Some q -> dep_ops ~depth:(depth + 1) env q
            | None -> None)
        | None -> None)
  else
    match List.find_opt (fun (i : Iface.t) -> i.home = p.home) env.ifaces with
    | Some iface -> (
        match Iface.find_type iface p.name with
        | Some { body = Dep ops; _ } ->
            Some (List.map (fun (o : Iface.field) -> o.fname) ops)
        | Some { body = Dep_alias d; _ } ->
            dep_ops ~depth:(depth + 1) env d.dpath
        | _ -> None)
    | None -> None

(* The path of the dependency an alias of the module's own names, found
   quietly: [type_def] reports a name that isn't one. *)
and alias_target env (t : tyname) =
  match t.tmod with
  | None -> Option.map fst (Hashtbl.find_opt env.types t.tid.name)
  | Some m -> (
      match Env.find_opt m.name env.modules with
      | Some (_, iface) ->
          Option.map
            (fun (d : Iface.type_decl) -> d.path)
            (Iface.find_type iface t.tid.name)
      | None -> None)

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
  | TyName (t, _) | TyVariant (t, _, _) -> tyname_loc t
  | TyFn (_, _, _, _, l)
  | TyImpl { impl_loc = l; _ }
  | TyInout (_, l)
  | TyTuple (_, l) ->
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
          | Some (p, n) ->
              if p.home = env.home then
                check_private env t.tid.loc ~key:("type " ^ p.name) p.name;
              Some (Named p, n)
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

(* The constructors of the sum type at [p], the module's own or an
   imported one's; [None] if it isn't a sum, or its representation is
   hidden here. *)
let sum_ctors env (p : Path.t) : Iface.ctor list option =
  if p.home = env.home then Hashtbl.find_opt env.own_sums p.name
  else
    match
      List.find_map
        (fun (i : Iface.t) ->
          if i.home = p.home then Iface.find_type i p.name else None)
        (env.ifaces @ List.map (fun (_, (_, i)) -> i) (Env.bindings env.modules))
    with
    | Some { body = Sum cs; _ } -> Some cs
    | _ -> None

(* The variant type [t].[c] names, `Order.Placed` (compiler.md, "Data
   stage", "Variant types"): [t] a sum type, [c] one of its constructors,
   with named fields. Whether it does; what's wrong is reported. *)
let variant_type env (t : tyname) (found : tref) (c : ident) =
  let shown = show_tyname t in
  match found with
  | Param _ ->
      report env (tyname_loc t)
        ~help:"a variant type is one of a sum's, like `Order.Placed`"
        (sprintf "`%s` isn't a sum type, so it has no variants" shown);
      false
  | Named p -> (
      match sum_ctors env p with
      | None ->
          report env (tyname_loc t)
            ~help:"a variant type is one of a sum's, like `Order.Placed`"
            (sprintf "`%s` isn't a sum type, so it has no variants" shown);
          false
      | Some cs -> (
          match List.find_opt (fun (k : Iface.ctor) -> k.cname = c.name) cs with
          | Some k when k.cnamed -> true
          | Some k ->
              let arg =
                match k.cfields with
                | { fname = ""; _ } :: _ | [] -> "x"
                | f :: _ -> f.fname
              in
              report env c.loc
                ~help:
                  (if k.cfields = [] then
                     sprintf "match it where it's matched, `%s => ...`" c.name
                   else
                     sprintf "take its field out where it's matched, `%s(%s) => ...`"
                       c.name arg)
                (sprintf
                   "`%s.%s` isn't a type: only a variant with named fields has \
                    one"
                   shown c.name);
              false
          | None ->
              let named =
                List.filter_map
                  (fun (k : Iface.ctor) -> if k.cnamed then Some k.cname else None)
                  cs
              in
              let help =
                match Infer_msg.nearest c.name (List.map (fun (k : Iface.ctor) -> k.cname) cs) with
                | Some n -> Some (sprintf "did you mean `%s`?" n)
                | None when named = [] ->
                    Some
                      (sprintf
                         "none of `%s`'s variants has named fields, so it has \
                          no variant types"
                         shown)
                | None ->
                    Some
                      (sprintf "its variants with named fields: %s"
                         (String.concat ", "
                            (List.map (fun n -> "`" ^ n ^ "`") named)))
              in
              report env c.loc ?help
                (sprintf "`%s` has no variant `%s`" shown c.name);
              false))

(* `D.Call` written as a type, `Doc.Call` (compiler.md, "Services stage",
   "`D.Call`"): with [t] a dependency, its sum of calls, if every one of
   its operations is data, and otherwise which isn't, reported; with [t]
   one of the type parameters [params], generic code's, `Call<D>` here,
   which only a handler's `call` clause's parameter is written as
   (Infer_handlers.call_clause). [None] if [t] is neither, for the caller
   to report as any `T.Call`. *)
let calls_type env ~params (t : tyname) (c : ident) args : Resolved.ty option =
  let loc = tyname_loc t in
  let unit () = TyName ({ tref = Named (Path.prelude "Unit"); tloc = loc }, []) in
  match (t.tmod, index_of t.tid.name 0 params) with
  | None, Some i ->
      (* `D.Call`, a call of any of [D]'s operations, whatever it gives;
         `D.Call<R>` and `D.Call<R, ! E>`, one that gives R and fails with
         at most E, none if they aren't written *)
      let tloc = Loc.span loc c.loc in
      let rest =
        match args with
        | [] -> []
        | [ r ] -> [ r; TyErrors { errs = []; etail = None; eloc = tloc } ]
        | [ r; e ] -> [ r; e ]
        | _ ->
            report env loc
              (sprintf "`%s.Call` takes at most 2 type arguments but was given %d"
                 (show_tyname t) (List.length args));
            []
      in
      Some
        (TyName
           ( { tref = Named Ty.generic_call; tloc },
             TyName ({ tref = Param i; tloc = loc }, []) :: rest ))
  | _ -> (
      match find_named env ~params t with
      | Some (Named p, n) when dep_ops env p <> None -> (
          let cp = Ty.call_path p in
          let iface () =
            List.find_opt (fun (i : Iface.t) -> i.home = p.home) env.ifaces
          in
          let found =
            if p.home = env.home then Hashtbl.mem env.types cp.name
            else
              match iface () with
              | Some i -> Iface.find_type i cp.name <> None
              | None -> false
          in
          if found then (
            let given = List.length args in
            if given > n && given <= n + 2 then
              (* what a call gives and fails with is in a concrete call's
                 type, and checked where generic code's `D.Call<R ! E>`
                 meets it, `post`'s `D.Call<()>` (Types.calls); it isn't
                 written of a dependency's own calls, since the
                 interface a function is seen through by other modules
                 keeps only `Doc.Call` *)
              report env loc
                ~help:
                  "build the call where it's posted, and take what it's built \
                   from instead"
                (sprintf
                   "what a call of `%s` gives and fails with isn't written: \
                    `%s.Call` is a call of any of its operations, and \
                    `D.Call<R ! E>` is generic code's"
                   (show_tyname t) (show_tyname t))
            else if n <> given then
              report env loc
                (sprintf "`%s.Call` takes %d type argument%s but was given %d"
                   (show_tyname t) n (plural n) given);
            Some
              (TyName
                 ( { tref = Named cp; tloc = Loc.span loc c.loc },
                   List.filteri (fun i _ -> i < n) args )))
          else
            (* which operation isn't data, and why *)
            let reason =
              if p.home = env.home then Hashtbl.find_opt env.not_data p.name
              else
                match Option.bind (iface ()) (fun i -> Iface.find_type i p.name) with
                | Some { body = Dep ops; _ } ->
                    List.find_map
                      (fun (o : Iface.field) ->
                        match o.fty with
                        | Fun (ps, r, _, _) ->
                            let block (t : Ty.ty) =
                              match t with Fun _ -> true | _ -> false
                            in
                            if List.exists (fun (q : Ty.param) -> q.mode = Inout) ps
                            then Some (o.fname, "changes an argument")
                            else if List.exists (fun (q : Ty.param) -> block q.ty) ps
                            then Some (o.fname, "takes a block")
                            else if block r then Some (o.fname, "gives a block")
                            else None
                        | _ -> None)
                      ops
                | _ -> None
            in
            let shown = show_tyname t in
            report env (Loc.span loc c.loc)
              ~help:
                "a call is a value only where every argument and result is data: no block, and no argument the operation changes"
              (match reason with
              | Some (op, why) ->
                  sprintf
                    "`%s.Call` needs every operation of `%s` to be data, and `%s` %s"
                    shown shown op why
              | None ->
                  sprintf "`%s.Call` needs every operation of `%s` to be data"
                    shown shown);
            Some (unit ()))
      | _ -> None)

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
                "a named row stands for what an implementation that comes into \
                 or out of the function does, so the signature names it";
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
        ~help:(sprintf "leave `..%s` out" n.name)
        (sprintf "a declaration can't name a row, `..%s`" n.name)

(* A written type, with its names resolved. [params] are the type
   parameters in scope, like the `T` in `Option<T>`. A type with an error
   is reported once, and its arguments aren't looked at. [arg] says it's a
   type argument, the one place an error set can be written as a type:
   `Result<T, ! Short | Frozen>`. Which type takes one is for inference to
   say. *)
let rec ty env ~params ?(rows = Declaration) ?(arg = false) ?(tags = false)
    (t : Parsed.ty) : Resolved.ty =
  match t with
  | TyFn (ps, ret, errs, u, l) ->
      (* a block's type never names a row: what it fails with and uses is
         what the call it's passed to does *)
      let unnamed (n : ident option) =
        Option.iter
          (fun (n : ident) ->
            Diag.report env.sink (Infer_msg.block_row_named n.loc ~row:n.name))
          n;
        None
      in
      let errs =
        Option.map
          (fun (es : Parsed.errors) -> { es with etail = unnamed es.etail })
          errs
      and u =
        Option.map
          (fun (u : Parsed.uses) -> { u with dtail = unnamed u.dtail })
          u
      in
      let ps = List.map (ty env ~params ~rows) ps in
      let ret = Option.map (ty env ~params ~rows) ret in
      let errs = Option.map (errors env ~params ~rows) errs in
      TyFn (ps, ret, errs, Option.map (uses_of env ~params ~rows) u, l)
  | TyInout (t, l) -> TyInout (ty env ~params ~rows t, l)
  | TyTuple (ts, l) -> TyTuple (List.map (ty env ~params ~rows) ts, l)
  | TyVariant (t, c, args)
    when c.name = "Call"
         && (t.tmod = None && index_of t.tid.name 0 params <> None
            || match alias_target env t with
               | Some p -> dep_ops env p <> None
               | None -> false) ->
      let args = List.map (ty env ~params ~rows ~arg:true) args in
      Option.get (calls_type env ~params t c args)
  | TyVariant (t, c, args) -> (
      (* the sum's name, as a [TyName]'s, then the variant: a variant type
         has its sum's type arguments *)
      let named tref = { tref; tloc = tyname_loc t } in
      match find_named env ~params t with
      | None -> TyName (named (Named (Path.make env.home t.tid.name)), [])
      | Some (tref, n) ->
          let given = List.length args in
          if variant_type env t tref c && n <> given then
            report env (tyname_loc t)
              (sprintf "`%s` takes %d type argument%s but was given %d"
                 (show_tyname t) n (plural n) given);
          TyVariant (named tref, c, List.map (ty env ~params ~rows ~arg:true) args))
  | TyImpl { impl_deps = ts; impl_over; impl_errors; impl_uses; impl_loc = l }
    -> (
      let u = Option.map (uses_of env ~params ~rows) impl_uses in
      let es = Option.map (errors env ~params ~rows) impl_errors in
      let impl deps : Resolved.ty =
        TyImpl
          {
            impl_deps = deps;
            impl_over;
            impl_errors = es;
            impl_uses = u;
            impl_loc = l;
          }
      in
      (* a dependency's own type arguments, as many as it takes *)
      let at (t : tyname dep_ref) p n : tname dep_ref option =
        let given = List.length t.dargs in
        if n <> given then (
          report env (tyname_loc t.dep)
            (sprintf "`%s` takes %d type argument%s but was given %d"
               (show_tyname t.dep) n (plural n) given);
          None)
        else
          Some
            {
              dep = { tref = Named p; tloc = tyname_loc t.dep };
              dargs = List.map (ty env ~params ~rows ~arg:true) t.dargs;
            }
      in
      match ts with
      | _ :: _ :: _ -> (
          (* several dependencies joined, `Clock & TestClock`: each has to
             be one, and each is written once *)
          let deps =
            List.fold_left
              (fun (deps, seen) (t : tyname dep_ref) ->
                match find_named env ~params t.dep with
                | Some (Named p, n) when dep_ops env p <> None -> (
                    let key = (p, List.map show_ty t.dargs) in
                    if List.mem key seen then (
                      report env (tyname_loc t.dep) ~help:"remove one"
                        (sprintf "`%s` is joined with `&` twice" (show_dep t));
                      (deps, seen))
                    else
                      match at t p n with
                      | Some d -> (deps @ [ d ], key :: seen)
                      | None -> (deps, seen))
                | Some _ ->
                    report env (tyname_loc t.dep)
                      ~help:
                        (sprintf
                           "`%s` isn't one: an implementation of several \
                            dependencies is the one value of this type"
                           (show_tyname t.dep))
                      "only a dependency's type can be joined with `&`";
                    (deps, seen)
                | None -> (deps, seen))
              ([], []) ts
            |> fst
          in
          match deps with
          | [] -> TyName ({ tref = Named (Path.prelude "Unit"); tloc = l }, [])
          | deps -> impl deps)
      | { dep = t; _ } :: _ -> (
          match find_named env ~params t with
          | Some (Named p, n) when dep_ops env p <> None -> (
              match at (List.hd ts) p n with
              | Some d -> impl [ d ]
              | None ->
                  TyName ({ tref = Named (Path.prelude "Unit"); tloc = l }, []))
          | Some (Param i, _)
            when (not impl_over) && impl_uses = None && impl_errors <> None
                 && List.length ts = 1 && (List.hd ts).dargs = [] ->
              (* `(D ! ..e)`, [D] a type parameter that stands for a
                 description: what it fails to start with, named
                 (compiler.md, "Services stage", "Actors (step 7)") *)
              impl [ { dep = { tref = Param i; tloc = tyname_loc t }; dargs = [] } ]
          | found ->
              (if found <> None then
                 let shown = show_tyname t in
                 if impl_over then
                   report env (tyname_loc t)
                     ~help:
                       "remove the `over`: only an implementation of a \
                        dependency goes over another"
                     (sprintf "`%s` isn't a dependency, so nothing goes over it"
                        shown)
                 else if impl_uses <> None then
                   report env (tyname_loc t)
                     ~help:
                       "remove the `uses`: only an implementation of a \
                        dependency needs something"
                     (sprintf "`%s` isn't a dependency, so it needs nothing"
                        shown)
                 else
                   report env (tyname_loc t)
                     ~help:
                       "remove the `!`: only an implementation of a dependency \
                        is installed"
                     (sprintf
                        "`%s` isn't a dependency, so it can't fail to be \
                         installed"
                        shown));
              TyName
                ( {
                    tref =
                      (match found with
                      | Some (tref, _) -> tref
                      | None -> Named (Path.make env.home t.tid.name));
                    tloc = tyname_loc t;
                  },
                  [] ))
      | [] -> (* the parser always reads one *) assert false)
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
      | Some (Named p, _) when p = Path.prelude "Tags" && not tags ->
          (* `Tags` is given by name at a call, and is never a value
             (compiler.md, "`over any` and `retry`") *)
          report env (tyname_loc t)
            ~notes:
              [
                "it's a set of error tags, given by name where the function \
                 is called, `on: DbDown`, and never a value";
              ]
            ~help:"write it as the type of a named function's parameter"
            "`Tags` is only the type of a function's parameter";
          TyName (named (Named p), [])
      | Some (Named p, _) when is_set env p ->
          not_a_type env (tyname_loc t) ~what:"it isn't a type of values" t;
          TyName (named (Named p), [])
      | Some (tref, n) when n <> given ->
          (* `Box<Clock uses Os, Console>` is two arguments: in one, a
             `uses` list ends at a comma *)
          let ends_in_uses : Parsed.ty -> bool = function
            | TyFn (_, _, _, Some _, _) | TyImpl { impl_uses = Some _; _ } ->
                true
            | _ -> false
          in
          let help =
            if given > n && List.exists ends_in_uses (List.tl (List.rev args))
            then
              Some
                "in a type argument, a `uses` list ends at a comma: to list \
                 several dependencies, put the type in parentheses, \
                 `Box<(Clock uses Os, Console)>`"
            else None
          in
          report env (tyname_loc t) ?help
            (sprintf "`%s` takes %d type argument%s but was given %d"
               (show_tyname t) n (plural n) given);
          TyName (named tref, [])
      | Some (Named p, _) when dep_ops env p <> None ->
          (* a dependency's type is an implementation's, which needs what
             it's written to need: nothing, here *)
          TyImpl
            {
              impl_deps =
                [
                  {
                    dep = named (Named p);
                    dargs = List.map (ty env ~params ~rows ~arg:true) args;
                  };
                ];
              impl_over = false;
              impl_errors = None;
              impl_uses = None;
              impl_loc = tyname_loc t;
            }
      | Some (tref, _) ->
          TyName (named tref, List.map (ty env ~params ~rows ~arg:true) args))

(* The dependencies after a function's `uses`, resolved: each one is a
   dependency in scope, `dep Clock = ...`, or another module's, written
   after its alias, `store.Users`, or one the prelude only names so far,
   like `Net`; a generic one is given its type arguments, `Chan<Int>`; and
   each is written once, at those types. One that isn't is reported, and
   left out. *)
and uses env ~params ?(rows = Declaration) (deps : tyname dep_ref list) :
    tname dep_ref list =
  let in_scope () =
    let declared =
      Hashtbl.fold
        (fun name ((p : Path.t), _) acc ->
          (* not the runtime's `Instances`, which no `uses` names *)
          match dep_ops env p with
          | Some (_ :: _) -> name :: acc
          | Some [] | None -> acc)
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
  (* its path, and how many type arguments it takes *)
  let resolve (d : tyname) =
    match d.tmod with
    | None -> (
        match Hashtbl.find_opt env.types d.tid.name with
        | Some (p, n) when dep_ops env p <> None ->
            ignore (find_type env d.tid.name);
            if p.home = env.home then
              check_private env d.tid.loc ~key:("type " ^ p.name) p.name;
            Some (p, n)
        | Some _ -> not_a_dep d
        | None when List.mem d.tid.name Prelude.dependencies ->
            Some (Path.prelude d.tid.name, 0)
        | None -> no_such d)
    | Some _ -> (
        match find_named env ~params:[] d with
        | Some (Named p, n) when dep_ops env p <> None -> Some (p, n)
        | Some _ -> not_a_dep d
        | None -> None)
  in
  let seen = Hashtbl.create 4 in
  List.filter_map
    (fun (d : tyname dep_ref) ->
      let loc = tyname_loc d.dep in
      match
        if d.dep.tmod = None && d.dargs = [] then index_of d.dep.tid.name 0 params
        else None
      with
      | Some i ->
          (* a type parameter that stands for a description: the one
             dependency that's of (compiler.md, "Services stage", "Actors
             (step 7)") *)
          Some { dep = { tref = Param i; tloc = loc }; dargs = [] }
      | None ->
      match resolve d.dep with
      | None -> None
      | Some (_, n) when n <> List.length d.dargs ->
          let given = List.length d.dargs in
          report env loc
            ~help:
              (if given = 0 then
                 sprintf "give it %s: `%s<Int>`"
                   (if n = 1 then "its type" else "its types")
                   (show_tyname d.dep)
               else "give it as many as it's declared with")
            (sprintf "`%s` takes %d type argument%s but was given %d"
               (show_tyname d.dep) n (plural n) given);
          None
      | Some (p, _) -> (
          let key = (p, List.map show_ty d.dargs) in
          match Hashtbl.find_opt seen key with
          | Some first ->
              report env loc ~help:"remove one of them"
                ~labels:
                  [ (first, sprintf "the first `%s` is here" (show_dep d)) ]
                (sprintf "`%s` is in `uses` twice" (show_dep d));
              None
          | None ->
              Hashtbl.replace seen key loc;
              Some
                {
                  dep = { tref = Named p; tloc = loc };
                  dargs = List.map (ty env ~params ~rows ~arg:true) d.dargs;
                }))
    deps

(* A `uses` written in a type, resolved: its dependencies, and the row it
   ends in, if it names one. *)
and uses_of env ~params ~rows (u : Parsed.uses) : Resolved.uses =
  Option.iter (row_name env ~rows Dep_row) u.dtail;
  { deps = uses env ~params ~rows u.deps; dtail = u.dtail; uloc = u.uloc }

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
        (* a private set of the module's own is hidden from test code, as
           any private type is *)
        check_private env t.loc ~key:("type " ^ t.name) t.name;
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

let ty_opt env ~params ?rows ?tags = Option.map (ty env ~params ?rows ?tags)

(* The named type [t] is, if it's written, `b: Bag`: then a method called
   on [b] can only be one of [Bag]'s (see [receiver_type]). *)
let note_type sc (b : binder) (t : Resolved.ty option) =
  match t with
  | Some (TyName ({ tref = Named p; _ }, _)) ->
      sc.fn.typed <- (b.id, p) :: sc.fn.typed
  | _ -> ()

(* A default, [d], of a parameter whose type is [t]: a variant written
   bare is a constructor of that type, which its sum is then, so a call in
   any module finds it, as `Kill.Tree` (Infer_env.literal_kind). One
   written after another type is refused; one of a type that isn't
   written, or isn't a sum, is inference's to refuse, where it checks the
   default against the parameter's type. *)
let default_of env (t : Resolved.ty option) ((lit, loc, node) as d) =
  match lit with
  | Ast.LCtor c -> (
      match t with
      | Some (TyName ({ tref = Named sum; _ }, _)) ->
          (match c.cqual with
          | Some q when q <> Path.local sum ->
              report env loc
                ~help:(sprintf "write `%s.%s`, or give it where it's called" (Path.local sum) c.cname.name)
                (sprintf "a default is a value of its parameter's type, `%s`, and `%s.%s` isn't one"
                   (Path.local sum) q c.cname.name)
          | _ -> ());
          (LCtor { c with csum = Some sum }, loc, node)
      | _ -> d)
  | _ -> d

let param env sc ?rows ?(top = false) ?(defaults = top) ?(makers = false) bound
    (p : Parsed.param) :
    Resolved.param * scope =
  let rows = Option.value rows ~default:(Body sc.rows) in
  (* a named function's parameter may be of `Tags` *)
  let pty = ty_opt env ~params:sc.tparams ~rows ~tags:top p.pty in
  let b, sc = bind env sc p.pname bound in
  note_type sc b pty;
  (* a mode, and a default, are a named function's (compiler.md, "Stage
     11a", "The surface") *)
  let pblock =
    match p.pblock with
    | Ordinary -> Ast.Ordinary
    | m when top -> m
    (* a handler's maker, `actors(h: spawned fn(k: K) -> D)`: given a
       function's name, which keeps nothing (compiler.md, "Services stage",
       "Actors (step 7)") *)
    | Spawned when makers -> Spawned
    | m ->
        report env p.pname.loc ~help:"remove it"
          (sprintf "`%s` marks a block parameter of a function"
             (if m = Concurrent then "concurrent" else "spawned"));
        Ordinary
  in
  (match p.pdefault with
  | Some (_, at, _) when not defaults ->
      report env at ~help:"remove it, and give it where it's called"
        "only a named function's parameter has a default"
  | _ -> ());
  ( {
      pname = b;
      pty;
      pmode = p.pmode;
      pblock;
      pdefault = (if defaults then Option.map (default_of env pty) p.pdefault else None);
    },
    sc )

(* The type of [r], the receiver of a dot call, if it's written where [r]
   is: a local whose type is written, `self` included, or a record
   literal, `Bag { ... }.size()`. *)
let receiver_type sc (r : Resolved.expr) =
  match r.kind with
  | Var (Local b) -> List.assoc_opt b.id sc.fn.typed
  | Record (Some { tref = Named p; _ }, _)
  | Update { target = Some (Into_type { tref = Named p; _ }); _ } ->
      Some p
  | _ -> None

let params env sc ?rows ?top ?defaults ?makers bound ps =
  let ps, sc =
    List.fold_left
      (fun (acc, sc) (p : Parsed.param) ->
        let p, sc = param env sc ?rows ?top ?defaults ?makers (bound p) p in
        (p :: acc, sc))
      ([], sc) ps
  in
  (List.rev ps, sc)

(* ---- expressions ---- *)

(* [written], a test item of the module [home], is used by code that
   isn't a test's (ast.ml, [fn_def.test]). *)
let test_item env loc ~home written =
  report env loc
    ~notes:
      [
        (if home = Path.prelude_home then
           "the prelude has it for tests only, and `ren run` leaves it out"
         else
           sprintf
             "a test item isn't part of `%s`'s interface, and `ren run` leaves \
              it out"
             home);
      ]
    ~help:
      (if home = Path.prelude_home then
         "call it from a test; outside one, `ren replay <file.journal>` \
          replays a recording"
       else "call it from a test, or remove `test` from its declaration")
    (sprintf "`%s` is a test item, so only a test can use it" written)

(* The public function [f] of the imported module [iface], written
   `alias.f`. A private function isn't in the interface, so it can't be
   told apart from one that doesn't exist. *)
let qualified env sc ((i : import), (iface : Iface.t)) (f : ident) =
  Hashtbl.replace env.used i.alias.name ();
  let p = Path.make iface.home f.name in
  (match (Iface.find_value iface f.name, Iface.find_test iface f.name) with
  | Some _, _ -> sc.fn.calls <- p :: sc.fn.calls
  | None, Some _ ->
      (* one of its public test items, which only a test can use *)
      if not sc.fn.test then
        test_item env f.loc ~home:iface.home (i.alias.name ^ "." ^ f.name);
      sc.fn.calls <- p :: sc.fn.calls
  | None, None when Iface.find_wiring iface f.name <> None ->
      report env f.loc
        ~help:(sprintf "install it: `with %s.%s in ...`" i.alias.name f.name)
        "a wiring isn't a value"
  | None, None ->
      report env f.loc ~help:"if it's defined there, mark it `pub`"
        (sprintf "`%s` has no public `%s`" iface.home f.name));
  Global p

(* The member [f] of the type [t], written `Stack.of`, or with the type's
   module in front, `stack.Stack.of`: the type is found through scope, and
   the item in its declaration. Another module's type lists only its public
   items, so a private one can't be told apart from one that doesn't
   exist. An associated value is a [Global_value]; the rest are functions. *)
(* The dependency [p] is an alias of, `Chan<Event>` for `dep Events =
   Chan<Event>`, through aliases of aliases, if it's one. *)
let rec alias_of ?(depth = 0) env (p : Path.t) =
  if depth > 16 then None
  else
    let target =
      if p.home = env.home then
        Option.bind (Hashtbl.find_opt env.own_aliases p.name) (alias_target env)
      else
        match List.find_opt (fun (i : Iface.t) -> i.home = p.home) env.ifaces with
        | Some iface -> (
            match Iface.find_type iface p.name with
            | Some { body = Dep_alias d; _ } -> Some d.dpath
            | _ -> None)
        | None -> None
    in
    match target with
    | Some q -> (
        match alias_of ~depth:(depth + 1) env q with
        | Some r -> Some r
        | None -> Some q)
    | None -> None

(* The member functions [p] has, if it's a type: its own, or another
   module's public ones. *)
let members_of env (p : Path.t) =
  if p.home = env.home then
    match Hashtbl.find_opt env.own_ops p.name with
    | Some (items, _) -> List.map fst items
    | None -> []
  else
    match List.find_opt (fun (i : Iface.t) -> i.home = p.home) env.ifaces with
    | Some iface -> (
        match Iface.find_type iface p.name with
        | Some decl -> List.map (fun (o : Iface.op) -> o.oname) (Iface.public_members decl)
        | None -> [])
    | None -> []

let item env sc ?node (t : tyname) (f : ident) =
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
      | Some { tref = Named p; _ }
        when (not (List.mem f.name (Option.value (dep_ops env p) ~default:[])))
             &&
             match alias_of env p with
             | Some q -> List.mem f.name (members_of env q)
             | None -> false ->
          (* a member function of the dependency an alias names, called
             through the alias, `Events.items()`: it's the dependency's, run
             with the alias's implementation (Infer, Lower) *)
          let q = Option.get (alias_of env p) in
          let path = Path.member q f.name in
          sc.fn.calls <- path :: sc.fn.calls;
          (* by its node and where it's written: a node is numbered
             within its function *)
          Option.iter (fun n -> Hashtbl.replace env.through n p) node;
          Global path
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
              if p.home = env.home then
                check_private env f.loc
                  ~key:(p.name ^ "." ^ f.name)
                  (shown ^ "." ^ f.name);
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
          | None, _ when p = Path.prelude "Str" && f.name = "concat" ->
              (* `Str.concat(a, b)`, which `+` replaced (strings.md) *)
              Diag.report env.sink (Infer_msg.str_concat f.loc);
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
          if Hashtbl.mem env.own_tests x && not sc.fn.test then
            test_item env loc ~home:p.home x;
          if p.home = env.home then check_private env loc ~key:x x;
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
          | [] when Hashtbl.mem env.wiring_defs x ->
              (* a wiring is installed, never kept or called (language.md
                 §5) *)
              report env loc
                ~help:(sprintf "install it: `with %s in ...`" x)
                "a wiring isn't a value"
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
          | [] when x = "outer" && sc.next <> No_next && sc.next <> In_inline
                    && (match sc.next with In_any _ -> false | _ -> true)
            ->
              (* the README's early sketch, `outer.get(id)` *)
              let ds =
                match sc.next with
                | In_for (_, ds) | In_over (_, ds) -> ds
                | In_inline | In_any _ | No_next -> []
              in
              let call =
                match
                  List.concat_map
                    (fun p -> Option.value (dep_ops env p) ~default:[])
                    ds
                with
                | op :: _ -> sprintf "`next.%s(...)`" op
                | [] -> "`next.op(...)`"
              in
              report env loc
                ~help:
                  (match sc.next with
                  | In_for (h, ds) ->
                      sprintf
                        "declare it `handler %s(...) over %s`, and call the \
                         one under it with `next`: %s"
                        h
                        (String.concat " & "
                           (List.map (fun (p : Path.t) -> p.name) ds))
                        call
                  | In_over _ | In_inline | In_any _ | No_next ->
                      sprintf "call the one under it with `next`: %s" call)
                (sprintf "there's no %s named `outer`" what)
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
                    | Fun (self :: ps, _, _, _) ->
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
  | PWild | PInt _ | PBool _ | PStr _ | PFail_any | PFail_in _ -> []
  | PVar x -> [ x ]
  | PSeq q ->
      List.concat_map pattern_vars q.front
      @ Option.to_list (Option.bind q.middle (fun r -> r.rname))
      @ List.concat_map pattern_vars q.back
  | PAs (q, x) -> pattern_vars q @ [ x ]
  | PCon (_, ps) | PFail (_, ps) | PTuple ps -> List.concat_map pattern_vars ps
  | PRecord (_, fs) | PCon_named (_, fs) ->
      List.concat_map (fun (_, q) -> pattern_vars q) fs.fpats
  | POr ps ->
      (* each alternative binds the same names (see [pattern]) *)
      Option.fold ~none:[] ~some:pattern_vars (List.nth_opt ps 0)

(* ---- `Tags`, and `call` in a handler `over any` (compiler.md,
   "`over any` and `retry`") ---- *)

let tags_path = Path.prelude "Tags"

(* Whether the local [b] is a parameter of type `Tags`, which isn't a
   value: it's matched, `fail on => ...`, or passed on, `on: on`. *)
let is_tags sc (b : binder) = List.assoc_opt b.id sc.fn.typed = Some tags_path

(* [x], a `Tags` parameter, used as a value. *)
let tags_used env loc x =
  report env loc
    ~notes:[ sprintf "`%s` is a set of error tags, given by name at a call" x ]
    ~help:
      (sprintf "match it, `fail %s => ...`, or pass it on, `%s: %s`" x x x)
    (sprintf "`%s` isn't a value" x)

(* Whether [x], written here, is the call that the arm of a handler `over
   any` runs for, its own name for it, and not a local bound since. *)
let is_call sc x =
  match (sc.next, Env.find_opt x sc.locals) with
  | In_any (_, id), Some b -> b.id = id
  | _ -> false

(* [x], the call of a handler `over any`, used some way other than
   through: as `next` is, it can't be kept, passed or returned. *)
let call_kept env loc x =
  report env loc
    ~notes:
      [
        sprintf
          "`%s` is the operation this arm runs for, while it runs, and it \
           can't be kept"
          x;
      ]
    ~help:
      (sprintf
         "use `%s.forward()`, `%s.fail(e)`, `%s.name` or `%s.args` where \
          they're needed"
         x x x x)
    (sprintf "`%s` can only be used through" x);
  Global (Path.make env.home x)

(* A constructor: the type it's written after, if any, resolved. A bare one
   is found through a type by inference. *)
let ctor_ref env sc (c : Parsed.ctor_ref) : Resolved.ctor_ref =
  {
    qual =
      Option.bind c.qual
        (declared_type env ~params:sc.tparams ~what:"it has no constructors");
    name = c.name;
  }

(* The record type named before a `{`, in a literal, an update or a
   pattern: `User { ... }`. *)
let record_name env sc (t : tyname) =
  match declared_type env ~params:sc.tparams ~what:"it can't make a record" t with
  | Some n -> n
  | None -> { tref = Named (Path.make env.home t.tid.name); tloc = tyname_loc t }

(* What a bare `Name { ... }` is, in a value, an update or a pattern
   (compiler.md, "Data stage", "The grammar"): the record type [Name] if a
   type of that name is in scope, and otherwise the by-name constructor
   [Name], which inference finds through a type, as it finds a bare
   constructor. A type in scope that's also a by-name constructor of a sum
   the module can name bare is refused, never picked, unless the type is
   that sum, or another sum, which has no fields to build: `type Point = |
   Point { x: Int, y: Int }`. A name with its module in front, `rows.Row {
   ... }`, is always a record's. With [update], it's an update's target,
   which, left out, is the base's type (Infer_expr.infer_update), so the
   help says that. *)
type braced = Braced_type of tname | Braced_ctor of Resolved.ctor_ref

let braces_name ?(update = false) env sc (t : tyname) =
  let name = t.tid.name in
  let is_type =
    index_of name 0 sc.tparams <> None || Hashtbl.mem env.types name
  in
  match (t.tmod, Hashtbl.find_opt env.named_ctors name) with
  | Some _, _ -> Braced_type (record_name env sc t)
  | None, None when is_type -> Braced_type (record_name env sc t)
  | None, None -> Braced_ctor { qual = None; name = t.tid }
  | None, Some sum when is_type && not (Hashtbl.mem env.sums name) ->
      report env t.tid.loc
        ~help:
          (if update then
             sprintf
               "write `%s.%s { ..base }` for the constructor, or `{ ..base }` \
                with the type left out for the base's own type"
               sum name
           else
             sprintf
               "write `%s.%s { ... }` for the constructor, or `{ ... }` with \
                the type left out for the record"
               sum name)
        (sprintf "`%s` is a record type here, and a constructor of `%s` too"
           name sum);
      Braced_type (record_name env sc t)
  | None, Some _ -> Braced_ctor { qual = None; name = t.tid }

(* A pattern, and the scope its names are bound in, each bound as [how]
   says: a loop's are its loop variables. [same] are the binders the
   first alternative of an or-pattern bound, which the names of the others
   are: `Pro(n) | Team(n)` binds one `n`. *)
let rec pattern env ?(how = By_pattern) ?(same = Env.empty) sc
    (p : Parsed.pattern) : Resolved.pattern * scope =
  let pattern env ?(same = same) sc p = pattern env ~how ~same sc p in
  let name sc (x : ident) =
    match Env.find_opt x.name same with
    | Some b -> (b, { sc with locals = Env.add x.name b sc.locals })
    | None -> bind env sc x how
  in
  let patterns sc ps =
    let ps, sc =
      List.fold_left
        (fun (acc, sc) p ->
          let p, sc = pattern env sc p in
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
    | PStr s -> (PStr s, sc)
    | PSeq q ->
        (* the pieces in front, the rest's name, then the pieces after,
           left to right *)
        let front, sc = patterns sc q.front in
        let middle, sc =
          match q.middle with
          | Some { rname = Some x; rloc } ->
              let b, sc = name sc x in
              (Some { rname = Some b; rloc }, sc)
          | Some { rname = None; rloc } -> (Some { rname = None; rloc }, sc)
          | None -> (None, sc)
        in
        let back, sc = patterns sc q.back in
        (PSeq { q with front; middle; back }, sc)
    | PFail_any -> (PFail_any, sc)
    | PFail_in x -> (
        (* `fail on`: [on] is a parameter of type `Tags`, and the pattern
           binds nothing *)
        match Env.find_opt x.name sc.locals with
        | Some b when is_tags sc b -> (PFail_in b, sc)
        | _ ->
            report env x.loc
              ~help:
                (sprintf
                   "match each tag, like `fail NotFound`, or keep the whole \
                    outcome as a value with `attempt`, and match `Err(%s)`"
                   x.name)
              "a `fail` pattern can't bind the whole error to a name";
            (PFail_any, sc))
    | PVar x ->
        let b, sc = name sc x in
        (PVar b, sc)
    | PAs (q, x) ->
        let q, sc = pattern env sc q in
        let b, sc = name sc x in
        (PAs (q, b), sc)
    | PCon (c, ps) ->
        let ps, sc = patterns sc ps in
        (PCon (ctor_ref env sc c, ps), sc)
    | PCon_named (c, fs) ->
        let qs, sc = patterns sc (List.map snd fs.fpats) in
        let fpats = List.combine (List.map fst fs.fpats) qs in
        (PCon_named (ctor_ref env sc c, { fs with fpats }), sc)
    | PFail (t, ps) ->
        let ps, sc = patterns sc ps in
        (PFail (t, ps), sc)
    | PTuple ps ->
        let ps, sc = patterns sc ps in
        (PTuple ps, sc)
    | PRecord (t, fs) -> (
        let qs, sc = patterns sc (List.map snd fs.fpats) in
        let fpats = List.combine (List.map fst fs.fpats) qs in
        match Option.map (braces_name env sc) t with
        | Some (Braced_ctor c) -> (PCon_named (c, { fs with fpats }), sc)
        | Some (Braced_type t) -> (PRecord (Some t, { fs with fpats }), sc)
        | None -> (PRecord (None, { fs with fpats }), sc))
    | POr [] -> assert false (* the parser makes one of two or more *)
    | POr (first :: rest) ->
        (* `fail on` takes what its tags are, which an alternative beside
           it would only repeat or add to *)
        List.iter
          (fun (alt : Parsed.pattern) ->
            match alt.pkind with
            | PFail_in x ->
                report env alt.ploc
                  ~help:
                    (sprintf
                       "give it an arm of its own, `fail %s => ...`, and the \
                        other errors theirs"
                       x.name)
                  (sprintf "`fail %s` is an arm's whole pattern" x.name)
            | _ -> ())
          (first :: rest);
        let first', inner = pattern env sc first in
        let bound = pattern_vars first in
        let has (vars : ident list) (x : ident) =
          List.exists (fun (y : ident) -> y.name = x.name) vars
        in
        let help = "bind the same names in every alternative" in
        (* "`n` is bound in `Pro(n)` but not in `Free`", either way round;
           a name only some alternatives bind is reported, and bound
           anyway, so its uses aren't reported too *)
        let unbound (x : ident) ~(in_ : Parsed.pattern) ~(not_in : Parsed.pattern) =
          report env x.loc ~help
            (sprintf "`%s` is bound in `%s` but not in `%s`" x.name
               (show_pattern in_) (show_pattern not_in))
        in
        let rest, inner =
          List.fold_left
            (fun (acc, inner) (alt : Parsed.pattern) ->
              let vars = pattern_vars alt in
              no_duplicates env "pattern variables" vars;
              List.iter
                (fun x -> if not (has bound x) then unbound x ~in_:alt ~not_in:first)
                vars;
              List.iter
                (fun y ->
                  if not (has vars y) then
                    unbound { y with loc = alt.ploc } ~in_:first ~not_in:alt)
                bound;
              let alt, inner = pattern env ~same:inner.locals inner alt in
              (alt :: acc, inner))
            ([], inner) rest
        in
        (POr (first' :: List.rev rest), inner)
  in
  ({ pkind = kind; ploc = p.ploc; pnode = p.pnode }, sc)

(* The pattern of a `let`, a `for` or a block's parameter, whose names are
   bound as [bound] says: a loop's are its loop variables. Exhaust checks
   it always matches, or that a `let ... else` might not (compiler.md,
   "Data stage", "Patterns that always match"). *)
let binding env sc bound (p : Parsed.pattern) = pattern env ~how:bound sc p

(* Whether [e], the `else` of a `let ... else`, leaves: it's a `fail`, a
   `break` or a `todo`, which panics, or a block whose last line leaves,
   an `if` with an `else` whose branches both do, or a `match` whose every
   arm does. Ren has no `return`, and no other expression a program writes
   panics with any type (compiler.md, "Data stage", "`let ... else`"). *)
let rec leaves (e : Parsed.expr) =
  match e.kind with
  | Fail _ | Break | Todo -> true
  | Block (_, last) -> leaves last
  | If (_, t, Some f) -> leaves t && leaves f
  | Match (_, arms) -> List.for_all (fun (a : Parsed.arm) -> leaves a.arm_body) arms
  | _ -> false

(* The line a block ends in, which is where it doesn't leave. *)
let rec last_line (e : Parsed.expr) =
  match e.kind with Block (_, l) -> last_line l | _ -> e

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

(* ---- `next` (handlers.md, "`next`") ---- *)

(* Whether `next` here isn't a local: one named so is reported where it's
   bound, inside a handler over a dependency, and anywhere else it's just
   a name. *)
let next_free env sc =
  (not (Env.mem "next" sc.locals)) && not (Hashtbl.mem env.values "next")

(* `next` used some way other than calling an operation through it, in a
   handler over [over]: it can't be kept. [called] is the operation it was
   read for, `next.get` uncalled. *)
let next_kept env loc over ?called () =
  let op =
    match called with
    | Some op -> op
    | None -> (
        match
          List.concat_map
            (fun p -> Option.value (dep_ops env p) ~default:[])
            over
        with
        | op :: _ -> op
        | [] -> "op")
  in
  report env loc
    ~notes:
      [
        "`next` is the implementation under this one while an operation runs, \
         and it can't be kept";
      ]
    ~help:(sprintf "call it where it's needed: `next.%s(...)`" op)
    "`next` can only be called through";
  Global (Path.make env.home "next")

(* `next` outside a handler over a dependency, where there isn't one. In
   an inline handler, inference says so, once it knows the dependency:
   the placeholder is what it looks for. *)
let no_next env sc loc =
  if sc.next <> In_inline then
  report env loc
    ~help:
      (match sc.next with
      | In_for (h, deps) ->
          let ds =
            String.concat " & " (List.map (fun (p : Path.t) -> p.name) deps)
          in
          sprintf
            "declare it `handler %s(...) over %s`, to reach the `%s` under it" h
            ds ds
      | In_any _ ->
          "in a handler `over any`, `call.forward()` calls the operation \
           under it"
      | In_over _ | In_inline | No_next ->
          "only a handler declared `over` another implementation has a `next`")
    "`next` is only in a handler declared `over` a dependency";
  Global (Path.make env.home "next")

(* The operation [op] of the implementation a handler [h] goes over,
   [over], called as `next.op(...)`, or `next(d).op(...)` for the one of
   them [d] names, which is needed when two have one of that name. *)
let next_op env (h, over) (d : Parsed.expr option) (op : ident) : name =
  let ops (p : Path.t) = Option.value (dep_ops env p) ~default:[] in
  let shown (p : Path.t) = sprintf "`%s`" p.name in
  let placeholder = Global (Path.make env.home "next") in
  let among =
    match d with
    | None -> Some over
    | Some { kind = Con ({ qual = None; name }, []); loc; _ } -> (
        match find_type env name.name with
        | Some (p, _) when List.mem p over -> Some [ p ]
        | _ ->
            report env loc
              ~help:
                (sprintf "name one of what it goes over: %s"
                   (String.concat " or "
                      (List.map
                         (fun (p : Path.t) -> sprintf "`next(%s)`" p.name)
                         over)))
              (sprintf "`%s` doesn't go over `%s`" h name.name);
            None)
    | Some d ->
        report env d.loc
          ~help:
            (sprintf "name one of what it goes over: %s"
               (String.concat " or "
                  (List.map
                     (fun (p : Path.t) -> sprintf "`next(%s)`" p.name)
                     over)))
          "`next(...)` takes the name of a dependency the handler goes over";
        None
  in
  match among with
  | None -> placeholder
  | Some among -> (
      match List.filter (fun p -> List.mem op.name (ops p)) among with
      | [ p ] -> Next_op (p, op.name)
      | [] ->
          let all =
            match among with
            | [ p ] -> List.map (sprintf "`%s`") (ops p)
            | ps ->
                List.concat_map
                  (fun (p : Path.t) ->
                    List.map (fun o -> sprintf "`%s.%s`" p.name o) (ops p))
                  ps
          in
          report env op.loc
            ?help:
              (match all with
              | [] -> None
              | all ->
                  Some
                    (sprintf "%s operations: %s"
                       (if List.length among = 1 then "its" else "their")
                       (String.concat ", " all)))
            (sprintf "%s %s no operation `%s`"
               (String.concat " and " (List.map shown among))
               (if List.length among = 1 then "has" else "have")
               op.name);
          placeholder
      | first :: _ as owners ->
          report env op.loc
            ~help:(sprintf "say which: `next(%s).%s(...)`" first.name op.name)
            (sprintf "%s both have `%s`, so `next.%s` could be either"
               (String.concat " and " (List.map shown owners))
               op.name op.name);
          placeholder)

(* [f], the callee of a call, if it's an operation called through `next`
   in a handler over a dependency: `next.get` or `next(A).get`. *)
let next_callee env sc (f : Parsed.expr) =
  match (sc.next, f.kind) with
  | In_over (h, o), Field ({ kind = Var (Bare "next"); _ }, op)
    when next_free env sc ->
      Some (next_op env (h, o) None op)
  | ( In_over (h, o),
      Field ({ kind = Call ({ kind = Var (Bare "next"); _ }, [ d ]); _ }, op) )
    when next_free env sc ->
      Some (next_op env (h, o) (Some d) op)
  | _ -> None

(* ---- wirings (language.md §5) ----

   A wiring is flattened where it's used. Its shape ([Iface.wiring]) is
   made once, from its declaration ([wiring_fns]): each link of each of
   its items, flattened, is a function of the module that takes the
   wiring's parameters it reads, `live$1(url: Str) = pg_db(url)`, which
   makes the link's implementation, so another module can use a `pub`
   wiring whose items name what it can't see (compiler.md, "Services
   stage", "Wirings"). A `with` that lists it, `with live(u) in body`,
   is then

     let url = u                                    (each argument once,
     with live$1(url), live$2(), live$3() in body    before any item)

   each item knowing the wirings it came through ([with_item.from]), whose
   `provides` inference enforces at the body. A link that's one of the
   wiring's parameters, `db` in `wiring app(db: Db) ... = db, ...`, is
   the argument itself: a parameter of a dependency's type used as a value
   isn't transparent, so no function could pass it back. *)

(* A `with` item that names a wiring: its shape, or [None] if the wiring
   is broken (a cycle, reported), how it's written, `live` or
   `app.live`, the import it's written through if it's another module's,
   and its arguments. *)
type wiring_ref = {
  shape : Iface.wiring option;
  written : string;
  through : (import * Iface.t) option;
  args : Parsed.expr list;
  rloc : Loc.t;
}

(* The wiring the item [it] names, if it names one: `live`, `live(url)`,
   or another module's, `app.live(url)`, alone, not in a chain. [local]
   says what's a local, which is never a wiring, and [own] finds one of
   the module's own. *)
let wiring_ref env ~local ~own (it : Parsed.with_item) =
  match it.chain with
  | [ { link; _ } ] -> (
      let named (f : Parsed.expr) args =
        match f.kind with
        | Var (Bare n) when (not (local n)) && Hashtbl.mem env.wiring_defs n
          ->
            Some { shape = own n; written = n; through = None; args; rloc = link.loc }
        | Field ({ kind = Var (Bare m); _ }, n) when not (local m) -> (
            match Env.find_opt m env.modules with
            | Some ((_, iface) as imp) -> (
                match Iface.find_wiring iface n.name with
                | Some w ->
                    Some
                      {
                        shape = Some w;
                        written = m ^ "." ^ n.name;
                        through = Some imp;
                        args;
                        rloc = link.loc;
                      }
                | None -> None)
            | None -> None)
        | _ -> None
      in
      match link.kind with Call (f, args) -> named f args | _ -> named link [])
  | _ -> None

(* What's wrong with how the item [r] names its wiring: anything around
   it, or the wrong number of arguments. *)
let wiring_written env (it : Parsed.with_item) (r : wiring_ref) =
  if it.under <> [] || it.alias <> None then
    report env it.iloc
      ~help:
        (sprintf "list `%s` alone, and put `over` or `as` on its items" r.written)
      "a wiring is installed as its items: nothing goes under it, and it \
       isn't installed `as` anything";
  List.iter
    (fun (a : Parsed.expr) ->
      match a.kind with
      | Named (n, _) ->
          report env n.loc ~help:"give it by position"
            "a wiring's arguments are given in order"
      | _ -> ())
    r.args;
  match r.shape with
  | Some w when List.length r.args <> List.length w.wparams ->
      let n = List.length w.wparams in
      report env r.rloc
        ~help:
          (sprintf "give it %s: `%s(%s)`"
             (if n = 1 then "one" else string_of_int n)
             r.written
             (String.concat ", " w.wparams))
        (sprintf "`%s` takes %d argument%s, but this gives it %d" r.written n
           (plural n) (List.length r.args))
  | _ -> ()

(* The `with` item [it], which names the wiring [r], flattened (see
   above): the `let`s that bind its arguments, each once, in order, then
   its items, each link a call of the function made of it, or the
   argument passed on. [go] resolves an argument where the `with` is. *)
let use_wiring env sc ~go (it : Parsed.with_item) (r : wiring_ref) =
  wiring_written env it r;
  let fresh () =
    sc.fn.made <- sc.fn.made - 1;
    sc.fn.made
  in
  (* the wiring's own `with`, which its function checks ([wiring_fns]),
     points at each item where the wiring lists it; a `with` that lists
     the wiring, at the wiring's name there *)
  let own = it.iloc = (match r.shape with Some w -> w.wdeclared | None -> it.iloc) in
  let at = ref r.rloc in
  let mk kind : Resolved.expr = { kind; loc = !at; node = fresh () } in
  (match r.through with
  | Some ((i : import), _) -> Hashtbl.replace env.used i.alias.name ()
  | None -> check_private env r.rloc ~key:("wiring " ^ r.written) r.written);
  match r.shape with
  | None -> ([], [])
  | Some w ->
      (* each argument a local, its own if it's one already: reading a
         local twice is reading it once *)
      let bound =
        List.mapi
          (fun i (a : Parsed.expr) ->
            let a = match a.kind with Named (_, v) -> v | _ -> a in
            match a.kind with
            | Var (Bare x) when Env.mem x sc.locals ->
                ignore (go a);
                (Env.find x sc.locals, None)
            | _ ->
                let value = go a in
                (* named for the parameter it's given to, which no code
                   sees: only the items read it *)
                sc.fn.last_id <- sc.fn.last_id + 1;
                let name =
                  Option.value (List.nth_opt w.wparams i) ~default:"_"
                in
                ( {
                    id = sc.fn.last_id;
                    ident = { name; loc = a.loc };
                    bound = By_let;
                    depth = sc.depth;
                  },
                  Some value ))
          r.args
      in
      let arg i =
        match List.nth_opt bound i with
        | Some (b, _) -> mk (Var (Local b))
        | None -> mk Unit (* the wrong number, reported *)
      in
      let home =
        match r.through with Some (_, iface) -> iface.home | None -> env.home
      in
      let link (l : Iface.link) : Resolved.with_link =
        let link =
          match l with
          | Passed i -> arg i
          | Made (f, used) ->
              let p = Path.make home f in
              sc.fn.calls <- p :: sc.fn.calls;
              mk (Call (mk (Var (Global p)), List.map arg used))
        in
        { link; knode = fresh () }
      in
      let via =
        { wiring = r.written; declared = w.wdeclared; provides = w.wprovides }
      in
      let items =
        List.map
          (fun (wi : Iface.wired_item) : Resolved.with_item ->
            if own then at := wi.wloc;
            {
              chain = List.map link wi.links;
              under = wi.wunder;
              alias = wi.walias;
              iloc = (if own then wi.wloc else it.iloc);
              from = wi.wvia @ [ via ];
            })
          w.witems
      in
      ( List.filter_map
          (fun (b, value) ->
            Option.map
              (fun value : Resolved.stmt ->
                Let { name = b; ty = None; value; mut = false })
              value)
          bound,
        items )

(* ---- services (language.md §4), where they're used ----

   A service is a `dep`, a handler of the service's name and a function
   for each member ([service_items], below). Where it's used, three
   things are its own: a `with` or a wiring installs it by calling the
   handler, `Kv(cfg)`, which reads as a constructor and is the only place
   its name is called; a member calls another directly, `call(req)`,
   which passes on the parameters they share; and a member's
   `Kv.get(k)`, which would reach the `Kv` installed outside, is
   refused. *)

(* A node for an expression this pass makes in the function (see
   [fn_state.made]). *)
let fresh sc =
  sc.fn.made <- sc.fn.made - 1;
  sc.fn.made

let is_capital s = s <> "" && Char.uppercase_ascii s.[0] = s.[0] && s.[0] <> '_'

(* Whether [x], where it's read, is another member of the service the
   function is a member of: not a local, which hides it. *)
let member_named sc x =
  (not (Env.mem x sc.locals))
  &&
  match sc.fn.member_of with
  | Some (_, s, _) -> List.mem x s.members
  | None -> false

(* A member [x] of the service [sname] called, or read, in its state, which
   is set up before any of them can run: each takes the state. *)
let member_in_state env loc ~sname x =
  report env loc
    ~notes:
      [
        sprintf
          "`%s`'s functions are given its state, which is still being set up \
           here"
          sname;
      ]
    ~help:"set it up here, or with a function outside the service"
    (sprintf "`%s` is a function of `%s`, which its state can't call" x sname)

(* The handler the service [name] is made with, if [name], in scope bare,
   is a service's: the module's own, unless a constructor of its own
   sums has that name, which it then is, or one imported by name, whose
   module has a public handler of its name, which only a service makes
   (a handler's name is otherwise lowercase). *)
let service_named env name =
  match Hashtbl.find_opt env.types name with
  | Some ((p : Path.t), _) when p.home = env.home ->
      let ctor =
        Hashtbl.fold
          (fun _ cs found ->
            found || List.exists (fun (c : Iface.ctor) -> c.cname = name) cs)
          env.own_sums false
      in
      if Hashtbl.mem env.services name && not ctor then Some p else None
  | Some (p, _) -> (
      match List.find_opt (fun (i : Iface.t) -> i.home = p.home) env.ifaces with
      | Some iface when Iface.find_value iface name <> None ->
          Some (Path.make p.home name)
      | _ -> None)
  | None -> None

(* The link [e] of a `with`'s item or a wiring's is where a service may
   be installed: `Kv(cfg)` or `kv.Kv(cfg)`, which [expr] makes a call of
   its handler there, and refuses anywhere else. *)
let installed env (e : Parsed.expr) =
  match e.kind with
  | Con ({ qual = None; _ }, _) -> Hashtbl.replace env.installs e.loc ()
  | Call ({ kind = Field ({ kind = Var (Bare _); _ }, _); loc; _ }, _) ->
      Hashtbl.replace env.installs loc ()
  | _ -> ()

(* The service [written] used where it isn't installed: [called], as
   `Kv(cfg)`, or as a value, `Kv`. *)
let not_installed env loc ~written ~called =
  if called then
    report env loc
      ~notes:
        [
          "a `with` item is never a value, so `" ^ written
          ^ "(...)` there can't be read as a constructor";
        ]
      ~help:(sprintf "install it where it's used: `with %s(...) in ...`" written)
      (sprintf "`%s(...)` installs a service, so it's written in a `with` or a \
                wiring"
         written)
  else
    report env loc
      ~help:
        (sprintf "install it, `with %s(...) in ...`, and call its operations: \
                  `%s.op(...)`"
           written written)
      "a service isn't a value"

let rec expr env sc (e : Parsed.expr) : Resolved.expr =
  let e = as_item env sc e in
  let go = expr env sc in
  let kind : Resolved.expr_kind =
    match e.kind with
    | Int n -> Int n
    | Float f -> Float f
    | Bool b -> Bool b
    | Str s -> Str s
    | Interp ps ->
        Interp (List.map (function Ast.Lit t -> Ast.Lit t | Hole h -> Hole (go h)) ps)
    | Unit -> Unit
    | Var (Bare "next") when next_free env sc -> (
        match sc.next with
        | In_over (_, over) -> Var (next_kept env e.loc over ())
        | In_for _ | In_inline | In_any _ | No_next ->
            Var (no_next env sc e.loc))
    | Field ({ kind = Var (Bare "next"); _ }, op)
      when next_free env sc
           && match sc.next with In_over _ -> true | _ -> false -> (
        (* `next.get` not called *)
        match sc.next with
        | In_over (_, over) -> Var (next_kept env e.loc over ~called:op.name ())
        | In_for _ | In_inline | In_any _ | No_next -> assert false)
    | Var (Bare x) when is_call sc x -> Var (call_kept env e.loc x)
    | Field ({ kind = Var (Bare x); _ }, f) when is_call sc x -> (
        match f.name with
        | "args" | "name" -> Var (Call_op f.name)
        | "forward" | "fail" -> Var (call_kept env e.loc x)
        | _ ->
            report env f.loc
              ~help:
                (sprintf
                   "it has `%s.forward()`, `%s.fail(e)`, `%s.name` and \
                    `%s.args`"
                   x x x x)
              (sprintf "`%s` has no `%s`" x f.name);
            Var (Global (Path.make env.home x)))
    | Call
        ( { kind = Field ({ kind = Var (Bare x); _ }, f); loc = floc; node = fnode },
          args )
      when is_call sc x && (f.name = "forward" || f.name = "fail") -> (
        match (f.name, args) with
        | "forward", [] ->
            Call ({ kind = Var (Call_op "forward"); loc = floc; node = fnode }, [])
        | "forward", a :: _ ->
            report env a.loc
              ~help:(sprintf "write `%s.forward()`" x)
              (sprintf
                 "`%s.forward()` passes the operation's own arguments, so it \
                  takes none"
                 x);
            Unit
        | _, [ { kind = Con ({ qual = None; name }, cargs); _ } ] ->
            (* `call.fail(Down)` is `fail Down` *)
            (go { e with kind = Fail (name, cargs) }).kind
        | _ ->
            report env e.loc
              ~help:(sprintf "name a tag, and its payload: `%s.fail(Down)`" x)
              (sprintf "`%s.fail(...)` takes the error to fail with" x);
            Unit)
    | Var (Bare x) when member_named sc x ->
        let sname, _, passed = Option.get sc.fn.member_of in
        if passed = None then member_in_state env e.loc ~sname x
        else
        report env e.loc
          ~help:(sprintf "call it in a block: `fn(...) => %s(...)`" x)
          (sprintf "`%s` is a function of `%s`, so it's called, not passed" x
             sname);
        Var (Global (Path.make env.home (sname ^ "$" ^ x)))
    | Var (Bare x) ->
        let v = lookup env sc e.loc ~what:"variable" x in
        (match v with Local b when is_tags sc b -> tags_used env e.loc x | _ -> ());
        Var v
    | Named (n, ({ kind = Var (Bare x); _ } as a))
      when match Env.find_opt x sc.locals with
           | Some b -> is_tags sc b
           | None -> false ->
        (* `on: on` passes a `Tags` parameter on *)
        Named
          (n, { kind = Var (Local (Env.find x sc.locals)); loc = a.loc; node = a.node })
    | Named (n, a) -> Named (n, go a)
    | Tag_set es -> Tag_set (errors env ~params:sc.tparams es)
    | Var (Item (t, f))
      when t.tmod = None
           &&
           match sc.fn.member_of with
           | Some (sname, _, Some _) -> sname = t.tid.name
           | Some (_, _, None) | None -> false ->
        (* `Kv.get` would go to the `Kv` installed outside, and a member
           shares its service's `uses`, which never names the service *)
        report env e.loc
          ~notes:
            [
              sprintf
                "`%s.%s` calls the `%s` installed where the call is, which \
                 isn't this one"
                t.tid.name f.name t.tid.name;
            ]
          ~help:(sprintf "call it directly: `%s(...)`" f.name)
          (sprintf "a function of `%s` calls another directly" t.tid.name);
        Var (item env sc ~node:(e.node, e.loc) t f)
    | Var (Item (t, f)) -> Var (item env sc ~node:(e.node, e.loc) t f)
    | Unop (op, a, n) -> Unop (op, go a, n)
    | Binop (op, a, b, n) ->
        let a = go a in
        Binop (op, a, go b, n)
    | If (c, t, f) ->
        let c = go c in
        let t = go t in
        If (c, t, Option.map go f)
    | Call (f, args) when next_callee env sc f <> None ->
        (* an operation of the implementation under this handler *)
        let op = Option.get (next_callee env sc f) in
        Call ({ kind = Var op; loc = f.loc; node = f.node }, List.map go args)
    | Call (({ kind = Var (Bare x); _ } as f), args) when member_named sc x ->
        (* another member of the service, given the parameters and the
           state they share first, a `var` by `&`: a direct call in the
           same operation, which keeps the instance it has (see
           [service_items]) *)
        let sname, s, shared = Option.get sc.fn.member_of in
        let p = Path.make env.home (sname ^ "$" ^ x) in
        sc.fn.calls <- p :: sc.fn.calls;
        let passed b inout : Resolved.expr =
          let var : Resolved.expr =
            { kind = Var (Local b); loc = f.loc; node = fresh sc }
          in
          if inout then { kind = Ref var; loc = f.loc; node = fresh sc } else var
        in
        let args = List.map go args in
        (match shared with
        | Some shared ->
            Call
              ( { kind = Var (Global p); loc = f.loc; node = f.node },
                List.map2 passed shared s.passes @ args )
        | None ->
            member_in_state env f.loc ~sname x;
            Call ({ kind = Var (Global p); loc = f.loc; node = f.node }, args))
    | Call (f, args) ->
        let f =
          let f = as_item env sc f in
          match f.kind with
          | Var (Bare "next") when next_free env sc -> go f
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
            {
              sc with
              depth = sc.depth + 1;
              loop = (if sc.loop = No_loop then No_loop else Loop_outside);
            }
            (fun (p : Parsed.param) ->
              if p.pmode = Inout then By_inout else By_lambda)
            ps
        in
        Lambda (ps, expr env inner body)
    | Inline_handler l ->
        (* its arm, a lambda, with no `next` *)
        Inline_handler (expr env { sc with next = In_inline } l)
    | Block (stmts, last) ->
        let stmts, sc = block_stmts env sc stmts in
        Block (stmts, expr env sc last)
    | Con ({ qual = None; name }, args) when service_named env name.name <> None
      -> (
        (* `Kv(cfg)`: a service, made as a handler is, where a `with` or a
           wiring installs it ([installed]) *)
        let p = Option.get (service_named env name.name) in
        match Hashtbl.find_opt env.installs e.loc with
        | Some () ->
            if p.home = env.home then
              check_private env name.loc ~key:name.name name.name;
            sc.fn.calls <- p :: sc.fn.calls;
            let arg (label, a) : Resolved.expr =
              let a = go a in
              match label with
              | None -> a
              | Some n -> { kind = Named (n, a); loc = a.loc; node = fresh sc }
            in
            Call
              ( { kind = Var (Global p); loc = name.loc; node = fresh sc },
                List.map arg args )
        | None ->
            not_installed env e.loc ~written:name.name ~called:(e.loc <> name.loc);
            Unit)
    | Con (c, args) ->
        let c = ctor_ref env sc c in
        Con (c, List.map (fun (l, a) -> (l, go a)) args)
    | Record (name, fields) -> (
        let fields = List.map (fun (f, v) -> (f, expr env sc v)) fields in
        match Option.map (braces_name env sc) name with
        | Some (Braced_ctor c) -> Con_named (c, fields)
        | Some (Braced_type t) -> Record (Some t, fields)
        | None -> Record (None, fields))
    | Con_named (c, fields) ->
        let c = ctor_ref env sc c in
        Con_named (c, List.map (fun (f, v) -> (f, go v)) fields)
    | Update { target; base; fields } ->
        (* the base first, then the fields, as they're evaluated *)
        let target =
          Option.map
            (function
              | Into_type t -> (
                  match braces_name ~update:true env sc t with
                  | Braced_ctor c -> Into_ctor c
                  | Braced_type t -> Into_type t)
              | Into_ctor c -> Into_ctor (ctor_ref env sc c))
            target
        in
        let base = go base in
        Update
          { target; base; fields = List.map (fun (f, v) -> (f, go v)) fields }
    | Field ({ kind = Var (Bare m); _ }, f)
      when Env.mem m env.modules && is_capital f.name -> (
        (* `kv.Kv(cfg)`, which the parser makes a call of `kv.Kv`: another
           module's service, installed only where a `with` or a wiring
           does ([installed]) *)
        let ((_, iface) as imp) = Env.find m env.modules in
        let written = m ^ "." ^ f.name in
        match Iface.find_value iface f.name with
        | Some _ when Hashtbl.mem env.installs e.loc ->
            Var (qualified env sc imp f)
        | Some _ ->
            not_installed env e.loc ~written ~called:true;
            Var (qualified env sc imp f)
        | None ->
            Hashtbl.replace env.used m ();
            report env e.loc
              ~help:
                (sprintf
                   "write one of its constructors after it, like `%s.Name`, or \
                    a record, `%s { ... }`"
                   written written)
              (sprintf "`%s` is a type, so it can't be used as a value" written);
            Var (Global (Path.make iface.home f.name)))
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
    | Slice (a, lo, hi) ->
        let a = go a in
        let lo = go lo in
        Slice (a, lo, go hi)
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
    | For { index; pat; over; body } ->
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
        no_duplicates env "loop variables"
          (List.concat_map pattern_vars (Option.to_list index @ [ pat ]));
        (* the index is never changed, even with `&`: it's where the
           element is (mut.ml) *)
        let index, sc =
          match index with
          | Some i ->
              let i, sc = binding env sc By_index i in
              (Some i, sc)
          | None -> (None, sc)
        in
        let pat, inner = binding env sc bound pat in
        For
          { index; pat; over; body = expr env { inner with loop = In_loop } body }
    | While { cond; body } ->
        let inner = { sc with loop = In_loop } in
        let cond = expr env inner cond in
        While { cond; body = expr env inner body }
    | Break ->
        (match sc.loop with
        | In_loop -> ()
        | No_loop ->
            report env e.loc
              ~help:
                "remove it: to end a function early, put what comes after in \
                 an `if ... else`"
              ~notes:[ "`break` leaves the `while` or `for` it's written in" ]
              "`break` is only inside a loop"
        | Loop_outside ->
            report env e.loc
              ~notes:[ "a block runs during the call it's passed to" ]
              ~help:"return a `Bool` from the block, and `break` after the call"
              "a block can't `break` out of the loop it's written in"
        | Loop_past_with ->
            report env e.loc
              ~notes:
                [
                  "the handlers a `with` installs are given what its body ends \
                   in, and a `break` ends in nothing";
                ]
              ~help:"end the `with`'s body with a `Bool`, and `break` after it"
              "a `break` can't leave a `with`");
        Break
    | Todo -> Todo
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
    | Pipe { subject; step } ->
        (* a step's function is found as a call's, but a field of a value,
           which the parser can't tell from a module's function, isn't
           one: a step is a function by name (language.md §8) *)
        let rec call (s : Parsed.expr) =
          match s.kind with Try c | Attempt c -> call c | _ -> s
        in
        (match (call step).kind with
        | Call ({ kind = Field ({ kind = Var (Bare x); _ }, m); loc; _ }, _)
          when Env.mem x sc.locals && not (Env.mem x env.modules) ->
            report env loc
              ~help:
                (sprintf "name it first: `let %s = %s.%s`, then `|> %s`"
                   m.name x m.name m.name)
              (sprintf
                 "a step is a function by name, and `%s.%s` is a field of `%s`"
                 x m.name x)
        | _ -> ());
        (* the subject first, as it's evaluated *)
        let subject = go subject in
        Pipe { subject; step = go step }
    | Piped -> Piped
    | Assert a -> Assert (go a)
    | Release a -> Release (go a)
    | With { items; body } ->
        let item (i : Parsed.with_item) : Resolved.with_item =
          {
            chain =
              List.map
                (fun (l : Parsed.with_link) ->
                  installed env l.link;
                  { l with link = go l.link })
                i.chain;
            under = uses env ~params:sc.tparams i.under;
            alias =
              (match i.alias with
              | Some d -> (
                  match uses env ~params:sc.tparams [ d ] with
                  | [ d ] -> Some d
                  | _ -> None)
              | None -> None);
            iloc = i.iloc;
            from = [];
          }
        in
        (* a wiring, flattened into its items, its arguments bound first *)
        let lets = ref [] in
        let items =
          List.concat_map
            (fun (i : Parsed.with_item) ->
              match
                wiring_ref env
                  ~local:(fun n -> Env.mem n sc.locals)
                  ~own:(Hashtbl.find_opt env.wirings) i
              with
              | Some r ->
                  let bound, items = use_wiring env sc ~go i r in
                  lets := !lets @ bound;
                  items
              | None -> [ item i ])
            items
        in
        let loop = if sc.loop = In_loop then Loop_past_with else sc.loop in
        let with_ : Resolved.expr_kind =
          With { items; body = expr env { sc with loop } body }
        in
        if !lets = [] then with_
        else (
          sc.fn.made <- sc.fn.made - 1;
          Block (!lets, { kind = with_; loc = e.loc; node = sc.fn.made }))
    | Handler _ ->
        (* the parser makes one only the body of a handler, which
           [handler_body] resolves *)
        assert false
  in
  { kind; loc = e.loc; node = e.node }

(* A block's statements, and the scope after them. A `finally` is one of
   them only in a handler's state or an operation's arm, [finally]. *)
and block_stmts ?(finally = false) env sc (stmts : Parsed.stmt list) =
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
            | None, (Record (Some n, _) | Update { target = Some (Into_type n); _ })
              ->
                (* `let b = Bag { ... }` is a `Bag` *)
                note_type sc b (Some (TyName (n, [])))
            | _ -> note_type sc b t);
            (Let { name = b; ty = t; value; mut } :: acc, sc)
        | Let_pattern { pat; value; else_ } ->
            let value = expr env sc value in
            (* the `else` runs where the pattern didn't match, so it sees
               nothing the pattern binds *)
            let else_ = Option.map (expr env sc) else_ in
            (match s with
            | Let_pattern { else_ = Some e; _ } when not (leaves e) ->
                report env (last_line e).loc
                  ~help:"end it with `fail`, `break` or `todo`"
                  "the `else` of a `let ... else` has to leave"
            | _ -> ());
            no_duplicates env "variables" (pattern_vars pat);
            let pat, sc = binding env sc By_let pat in
            (Let_pattern { pat; value; else_ } :: acc, sc)
        | Expr e -> (Expr (expr env sc e) :: acc, sc)
        | Finally f ->
            if not finally then
              report env
                {
                  f.loc with
                  stop = { f.loc.start with col = f.loc.start.col + 7 };
                }
                ~notes:
                  [
                    "it covers what comes after it there: the state below it \
                     and the body of each `with` that installs the handler, or \
                     the rest of the arm";
                  ]
                ~help:
                  "use `attempt` on what it should cover, and act on the \
                   `Result` after"
                "a `finally` is only in a handler: among its state, or in an \
                 operation's arm";
            (Finally (arm_lambda ~arm:false env sc f) :: acc, sc))
      ([], sc) stmts
  in
  (List.rev stmts, sc)

(* A handler's arm, or a `finally`: a lambda, whose parameters are bound
   beside the handler's state, or the arm's. An arm's body, [arm], can
   have `finally`s among its statements. *)
and arm_lambda ?(arm = true) env sc (l : Parsed.expr) : Resolved.expr =
  match l.kind with
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
      let body =
        match body.kind with
        | Block (stmts, last) ->
            let stmts, inner = block_stmts ~finally:arm env inner stmts in
            {
              kind = Block (stmts, expr env inner last);
              loc = body.loc;
              node = body.node;
            }
        | _ -> expr env inner body
      in
      { kind = Lambda (ps, body); loc = l.loc; node = l.node }
  | _ -> (* the parser makes each arm a lambda *) assert false

(* "`a`", "`a` or `b`", "`a`, `b` or `c`" *)
let or_list = function
  | [] -> ""
  | [ one ] -> one
  | all ->
      let rev = List.rev all in
      String.concat ", " (List.rev (List.tl rev)) ^ " or " ^ List.hd rev

(* The body of the handler [name] (ast.ml, [Handler]): the dependencies
   after `for` or `over`, each a declared one with operations, once; its
   state, with its `finally`s; and its arms, each the implementation of an
   operation of exactly one of them, a [Dep_op], and every operation
   implemented once, unless it goes over another implementation, which
   does the rest. The state is bound as deep as the arms' bodies, so an
   arm can change it (mut.ml). In one over a dependency, `next` is the
   implementation under it (handlers.md, "`next`"). *)
let rec handler_body env sc (name : ident) ~needs (e : Parsed.expr) :
    Resolved.expr_kind =
  match e.kind with
  | Handler
      {
        deps = [ { dep = { tmod = None; tid = d }; dargs = [] } ];
        over = false;
        any = false;
        fails;
        state;
        arms;
        _;
      }
    when index_of d.name 0 sc.tparams <> None ->
      (* `handler striped<D>(h: D, ...) for D`: a handler of whatever
         dependency [D] is an implementation of, which a call of it gives
         it, one `call` clause its every operation (compiler.md, "Services
         stage", "Stripes"). It's made for each dependency it's given, as
         a handler `over any` is for each it's installed over *)
      let i = Option.get (index_of d.name 0 sc.tparams) in
      let fails = Option.map (errors env ~params:sc.tparams) fails in
      let sc = { sc with next = In_for (name.name, []) } in
      let state, sc = block_stmts ~finally:true env sc state in
      let one_clause loc =
        report env loc
          ~notes:
            [
              sprintf
                "it implements whatever dependency `%s` is, whose operations aren't known here"
                d.name;
            ]
          ~help:"write one arm, its `call` clause: `call(c) => ...`"
          (sprintf "`%s` is a handler for `%s`, so its one arm is `call(c) => ...`"
             name.name d.name)
      in
      let clause (a : Parsed.handler_arm) =
        match a.arm_impl.kind with
        | Lambda ([ p ], _) when a.arm_name.name = "call" && p.pname.loc <> a.arm_name.loc -> true
        | _ -> false
      in
      let arms : Resolved.handler_arm list =
        match List.filter clause arms with
        | (a : Parsed.handler_arm) :: rest ->
            List.iter
              (fun (b : Parsed.handler_arm) -> if b != a then one_clause b.arm_name.loc)
              (List.filter (fun b -> not (clause b)) arms @ rest);
            [
              {
                arm_op = Call_op "clause";
                arm_name = a.arm_name;
                arm_impl = arm_lambda env sc a.arm_impl;
              };
            ]
        | [] ->
            List.iter (fun (b : Parsed.handler_arm) -> one_clause b.arm_name.loc) arms;
            if arms = [] then one_clause name.loc;
            []
      in
      Handler
        {
          deps = [ { dep = { tref = Param i; tloc = d.loc }; dargs = [] } ];
          over = false;
          any = false;
          fails;
          needs;
          state;
          arms;
        }
  | Handler { deps; over; any; fails; state; arms; _ } ->
      let after = if over then "over" else "for" in
      let seen = Hashtbl.create 4 in
      let deps =
        List.filter_map
          (fun (d : tyname dep_ref) ->
            (* [uses] reports a name that isn't a dependency *)
            let d' = d in
            let d = d.dep in
            match uses env ~params:sc.tparams [ d' ] with
            | [ ({ dep = { tref = Named p; tloc }; _ } as t) ] -> (
                match (Hashtbl.find_opt seen p, dep_ops env p) with
                | Some first, _ ->
                    report env tloc ~help:"remove one of them"
                      ~labels:
                        [
                          ( first,
                            sprintf "the first `%s` is here" (show_tyname d) );
                        ]
                      (sprintf "`%s` is after `%s` twice" (show_tyname d) after);
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
                      ~help:(sprintf "remove it from after `%s`" after)
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
      let sc =
        let paths = List.map fst deps in
        {
          sc with
          next =
            (if over then In_over (name.name, paths)
             else In_for (name.name, paths));
        }
      in
      (* what it goes over it needs already *)
      if over then
        Option.iter
          (fun (u : Resolved.uses) ->
            List.iter
              (fun ({ dep = d; _ } : tname dep_ref) ->
                match d.tref with
                | Named p when List.mem_assoc p deps ->
                    report env d.tloc
                      ~help:(sprintf "remove `%s` from its `uses`" p.name)
                      (sprintf
                         "`%s` is what it goes over, so it isn't listed in \
                          `uses`"
                         p.name)
                | _ -> ())
              u.deps)
          needs;
      let fails = Option.map (errors env ~params:sc.tparams) fails in
      let state, sc = block_stmts ~finally:true env sc state in
      let ops (p : Path.t) = Option.value (dep_ops env p) ~default:[] in
      let shown (p : Path.t) = sprintf "`%s`" p.name in
      let given = Hashtbl.create 8 in
      (* `call(c) => ...`, or a merge's `call(c, a, b) => ...`: the `call`
         clause, a lambda of the call, which runs for each operation the
         handler doesn't write an arm for, or folds two of their results
         (compiler.md, "Services stage", "`D.Call`"), unless an operation
         is named `call` *)
      let is_clause (a : Parsed.handler_arm) =
        a.arm_name.name = "call"
        && (match a.arm_impl.kind with
           | Lambda ([ p ], _) -> p.pname.loc <> a.arm_name.loc
           | Lambda (_, _) -> true
           | _ -> false)
        && not (List.exists (fun ((p : Path.t), _) -> List.mem "call" (ops p)) deps)
      in
      let clause (a : Parsed.handler_arm) : Resolved.handler_arm =
        (match a.arm_impl.kind with
        | Lambda (([ _ ] | [ _; _; _ ]), _) -> ()
        | _ ->
            report env a.arm_name.loc
              ~help:
                "write `call(c) => ...` to run for each operation it doesn't \
                 implement, or `call(c, a, b) => ...` to fold two results of \
                 the call `c`"
              "a `call` clause takes the call, and for a fold its two results");
        if over then
          report env a.arm_name.loc
            ~help:"write it in a handler `for` the dependency"
            "a handler that goes `over` another doesn't write a `call` clause";
        { arm_op = Call_op "clause"; arm_name = a.arm_name; arm_impl = arm_lambda env sc a.arm_impl }
      in
      let arm (a : Parsed.handler_arm) : Resolved.handler_arm =
        let op = a.arm_name.name in
        (* `Console.write(line) => ...` names its dependency, which has to
           be one it implements *)
        let deps =
          match a.arm_op with
          | Item (d, _) -> (
              match
                List.filter (fun ((p : Path.t), _) -> p.name = d.tid.name) deps
              with
              | [] ->
                  report env d.tid.loc
                    ~help:
                      (sprintf "it implements %s"
                         (String.concat " and "
                            (List.map (fun (p, _) -> shown p) deps)))
                    (sprintf "this handler doesn't implement `%s`" d.tid.name);
                  []
              | named -> named)
          | Bare _ -> deps
        in
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
                ~help:
                  (sprintf "say which dependency's it is: %s"
                     (String.concat " or "
                        (List.map
                           (fun ((p : Path.t), _) ->
                             sprintf "`%s.%s(...) => ...`" p.name op)
                           owners)))
                (sprintf "%s %s have an operation named `%s`"
                   (String.concat " and "
                      (List.map (fun (p, _) -> shown p) owners))
                   (if List.length owners = 2 then "both" else "all")
                   op);
              Global (Path.make env.home op)
        in
        {
          arm_op;
          arm_name = a.arm_name;
          arm_impl = arm_lambda env sc a.arm_impl;
        }
      in
      (* `call => ...`, the arm of a handler `over any` *)
      let any_arm (a : Parsed.handler_arm) =
        match a.arm_impl.kind with
        | Lambda ([ p ], _) -> p.pname.loc = a.arm_name.loc
        | _ -> false
      in
      let arms =
        if any then any_arms env sc name arms ~any_arm
        else (
          List.iter
            (fun (a : Parsed.handler_arm) ->
              if any_arm a && a.arm_name.name = "task" then
                (* async.md's `task =>` is gone: a handler's background work
                   is a task beside its `with`'s body (foundations.md,
                   decision 7) *)
                report env a.arm_name.loc
                  ~help:
                    "run one beside the `with`'s body that calls one of the \
                     handler's operations: `with h() in Async.beside(task) \
                     fn() => ...`"
                  "a handler has no task of its own"
              else if any_arm a then
                report env a.arm_name.loc
                  ~help:
                    (sprintf
                       "declare it `handler %s(...) over any`, or implement \
                        an operation by its name: `%s(...) => ...`"
                       name.name
                       (match List.concat_map (fun (p, _) -> ops p) deps with
                       | op :: _ -> op
                       | [] -> "op"))
                  (sprintf "`%s => ...` is the arm of a handler `over any`"
                     a.arm_name.name))
            arms;
          List.map
            (fun a -> if is_clause a then clause a else arm a)
            (List.filter (fun a -> not (any_arm a)) arms))
      in
      let clauses =
        List.filter
          (fun (a : Resolved.handler_arm) -> a.arm_op = Call_op "clause")
          arms
      in
      (match clauses with
      | _ :: (b : Resolved.handler_arm) :: _ ->
          report env b.arm_name.loc ~help:"remove one of them"
            "a handler has one `call` clause"
      | _ -> ());
      (match (clauses, deps) with
      | _ :: _, _ :: _ :: _ ->
          report env (List.hd clauses).arm_name.loc
            ~help:"write it in a handler of one dependency"
            "a handler of several dependencies doesn't write a `call` clause"
      | _ -> ());
      (* every operation of every dependency is implemented, unless it goes
         over another implementation, which does the rest, or it has a
         `call` clause, which runs for the rest, or folds *)
      (if not over && clauses = [] then
         let missing =
           List.concat_map
             (fun ((p : Path.t), _) ->
               List.filter_map
                 (fun o ->
                   if Hashtbl.mem given (p, o) then None
                   else if List.length deps = 1 then Some (sprintf "`%s`" o)
                   else Some (sprintf "`%s.%s`" p.name o))
                 (ops p))
             deps
         in
         match missing with
         | [] -> ()
         | missing ->
             let ds =
               String.concat " & "
                 (List.map (fun ((p : Path.t), _) -> p.name) deps)
             in
             report env name.loc
               ~notes:
                 [
                   "a handler implements every operation, unless it goes \
                    `over` another implementation, which then does the rest";
                 ]
               ~help:
                 (sprintf
                    "write them, or declare it `over %s` if another `%s` \
                     should handle them"
                    ds ds)
               (sprintf "`%s` doesn't implement %s" name.name (or_list missing)));
      Handler
        { deps = List.map snd deps; over; any; fails; needs; state; arms }
  | _ -> assert false

(* The arms of the handler [name] declared `over any`: one, `call =>
   body`, whose body is a lambda of no parameters, with [call] bound in it
   as the call it runs for, which is only used through ([is_call]). Its
   [arm_op] is [Call_op "any"]. `call.forward()` is called once at most on
   any path through it ([forwards]). *)
and any_arms env sc (name : ident) arms ~any_arm =
  let one_arm loc =
    report env loc
      ~notes:
        [
          "it goes over whatever dependency it's installed over, and its one \
           arm runs for every operation of it";
        ]
      ~help:"write one arm, `call => ...`, and read `call.name` for which it is"
      (sprintf "`%s` goes over any dependency, so it has one arm, `call => ...`"
         name.name)
  in
  match List.filter any_arm arms with
  | [] ->
      List.iter (fun (a : Parsed.handler_arm) -> one_arm a.arm_name.loc) arms;
      if arms = [] then one_arm name.loc;
      []
  | (a : Parsed.handler_arm) :: rest ->
      List.iter
        (fun (b : Parsed.handler_arm) ->
          if b != a then one_arm b.arm_name.loc)
        (List.filter (fun b -> not (any_arm b)) arms @ rest);
      let body =
        match a.arm_impl.kind with Lambda (_, body) -> body | _ -> assert false
      in
      let b, inner = bind env sc a.arm_name By_lambda in
      let inner = { inner with next = In_any (name.name, b.id) } in
      let body : Resolved.expr =
        match body.kind with
        | Block (stmts, last) ->
            let stmts, inner = block_stmts ~finally:true env inner stmts in
            {
              kind = Block (stmts, expr env inner last);
              loc = body.loc;
              node = body.node;
            }
        | _ -> expr env inner body
      in
      forwards env a.arm_name.name body;
      [
        {
          arm_op = Call_op "any";
          arm_name = a.arm_name;
          arm_impl = { kind = Lambda ([], body); loc = a.arm_impl.loc; node = a.arm_impl.node };
        };
      ]

(* `call.forward()` runs the operation under the handler, so it's called
   once at most on any path through the arm [body]: never in a loop or a
   block, which could call it again, and once in a sequence, or in each
   branch of an `if` or a `match`. The second is reported. *)
and forwards env x (body : Resolved.expr) =
  let report_at loc =
    report env loc
      ~help:
        (sprintf
           "keep what it gave: `let r = attempt %s.forward()`, and `try r` \
            where it's needed"
           x)
      (sprintf
         "`%s.forward()` runs the operation under this one, so it's called \
          once at most"
         x)
  in
  (* how many times [e] can call it on one path, given [before] already
     have; [again] says it's inside a loop or a block, where once is
     already more than once *)
  let rec go ~again before (e : Resolved.expr) =
    match e.kind with
    | Call ({ kind = Var (Call_op "forward"); _ }, []) ->
        if before >= 1 || again then report_at e.loc;
        before + 1
    | If (c, t, f) ->
        let n = go ~again before c in
        max (go ~again n t) (match f with Some f -> go ~again n f | None -> n)
    | Match (subject, arms) ->
        let n = go ~again before subject in
        List.fold_left
          (fun m (a : Resolved.arm) ->
            let k =
              match a.arm_guard with Some g -> go ~again n g | None -> n
            in
            max m (go ~again k a.arm_body))
          n arms
    | While { cond; body } ->
        let n = go ~again:true before cond in
        go ~again:true n body
    | For { over; body; _ } ->
        let n =
          match over with
          | Each it -> go ~again before it
          | Range (lo, hi) -> go ~again (go ~again before lo) hi
        in
        go ~again:true n body
    | Lambda (_, b) | Inline_handler b -> go ~again:true before b
    | Block (stmts, last) ->
        (* a `let ... else`'s `else` is another path, which leaves the
           block *)
        let left = ref 0 in
        let n =
          List.fold_left
            (fun n (s : Resolved.stmt) ->
              match s with
              | Let { value; _ } | Expr value -> go ~again n value
              | Let_pattern { value; else_; _ } ->
                  let n = go ~again n value in
                  Option.iter (fun e -> left := max !left (go ~again n e)) else_;
                  n
              | Finally f -> go ~again:true n f)
            before stmts
        in
        max !left (go ~again n last)
    | _ -> List.fold_left (fun n c -> go ~again n c) before (children e)
  in
  ignore (go ~again:false 0 body)

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
      | Fn _ | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
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
      | Fn _ | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
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
      | Fn _ | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
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
      | Fn _ | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
    items

(* Whether the written type [t] mentions the type parameter [name]. *)
let rec mentions name (t : Parsed.ty) =
  let in_errors (es : Parsed.errors) =
    List.exists
      (function
        | Tag (_, ps) ->
            List.exists
              (fun (p : tyname payload) -> mentions name p.payload_ty)
              ps
        | Set _ -> false)
      es.errs
  in
  let in_uses (u : Parsed.uses) = List.exists (dep_mentions name) u.deps in
  match t with
  | TyName (n, args) | TyVariant (n, _, args) ->
      (n.tmod = None && n.tid.name = name) || List.exists (mentions name) args
  | TyFn (ps, ret, es, u, _) ->
      List.exists (mentions name) ps
      || Option.fold ~none:false ~some:(mentions name) ret
      || Option.fold ~none:false ~some:in_errors es
      || Option.fold ~none:false ~some:in_uses u
  | TyImpl { impl_deps; impl_errors; impl_uses; _ } ->
      List.exists (dep_mentions name) impl_deps
      || Option.fold ~none:false ~some:in_errors impl_errors
      || Option.fold ~none:false ~some:in_uses impl_uses
  | TyInout (t, _) -> mentions name t
  | TyTuple (ts, _) -> List.exists (mentions name) ts
  | TyErrors es -> in_errors es

and dep_mentions name (d : tyname dep_ref) = List.exists (mentions name) d.dargs

(* What a type parameter can be written to need, `T has eq`: what an
   operator or `show` asks of a type (infer_reqs.ml) *)
let requirements =
  [
    "eq";
    "hash";
    "ord";
    "show";
    "add";
    "sub";
    "mul";
    "div";
    "rem";
    "neg";
    "zero";
    "one";
  ]

(* A function's type parameters, checked against how its signature uses
   them. One a `uses` names has to be fixed by what the function is given
   or gives: at a call, nothing else says which instance it uses
   (compiler.md, "Generic dependencies"). A handler's are its
   dependencies', the `T` of `for Log<T>`, which installing it fixes. *)
let check_tparams env (f : Parsed.fn_def) =
  List.iter
    (fun ((t : string), (r : ident)) ->
      if not (List.mem r.name requirements) then
        report env r.loc
          ~help:
            (sprintf "one of %s"
               (String.concat ", " (List.map (sprintf "`%s`") requirements)))
          (sprintf "`%s` isn't something `%s` can need" r.name t))
    f.tneeds;
  match f.body.kind with
  | Handler { deps; _ } ->
      List.iter
        (fun (t : ident) ->
          (* or, `handler striped<D>(h: D) for D`, what it implements
             (handler_body) *)
          let named (d : tyname dep_ref) = d.dep.tmod = None && d.dep.tid.name = t.name in
          if not (List.exists (fun d -> dep_mentions t.name d || named d) deps) then
            report env t.loc
              ~help:
                (sprintf
                   "a handler's type parameters are its dependencies': remove \
                    `<%s>`"
                   t.name)
              (sprintf "`%s` isn't a type parameter of `%s`" t.name
                 (String.concat " & "
                    (List.map (fun (d : tyname dep_ref) -> show_dep d) deps))))
        f.tparams
  | _ -> (
      match f.uses with
      | None -> ()
      | Some u ->
          List.iter
            (fun (t : ident) ->
              let given =
                List.exists
                  (fun (p : Parsed.param) ->
                    Option.fold ~none:false ~some:(mentions t.name) p.pty)
                  f.params
                || Option.fold ~none:false ~some:(mentions t.name) f.ret
              in
              if List.exists (dep_mentions t.name) u.deps && not given then
                report env t.loc
                  ~help:
                    (sprintf
                       "make `%s` a parameter's or the result's type, or name \
                        the dependency at one type: `uses %s`"
                       t.name
                       (match List.find_opt (dep_mentions t.name) u.deps with
                       | Some d -> show_tyname d.dep ^ "<Int>"
                       | None -> "Int"))
                  (sprintf "nothing `%s` is given fixes `%s`" f.name.name t.name))
            f.tparams)

(* A function: a top-level one, or, with [owner], one of that type's
   members. A member has the type's parameters in scope, before its
   own, and is named after the type, `Stack.push` (ast.ml); its first
   parameter can be `self`, which has the type, `Stack<T>`. `self` is no
   other parameter. *)
(* The lowest node numbered in [e], or -1: [wiring_fns] numbers what it
   makes below zero, so what a `with` in it flattens is numbered below
   that ([fn_state.made]). *)
let rec lowest_node (e : Parsed.expr) =
  let own =
    match e.kind with
    | With { items; _ } ->
        List.fold_left
          (fun m (i : Parsed.with_item) ->
            List.fold_left (fun m (l : Parsed.with_link) -> min m l.knode) m i.chain)
          e.node items
    | _ -> e.node
  in
  List.fold_left (fun m c -> min m (lowest_node c)) (min (-1) own) (Ast.children e)

let fn_def env ?(owner : Parsed.type_def option) (f : Parsed.fn_def) :
    Resolved.fn_def * Path.t list * (string * Path.t option) list =
  let outer = match owner with Some td -> td.type_params | None -> [] in
  let tparams = outer @ f.tparams in
  (* test code sees what an importer sees, but in the console *)
  env.in_test <- f.test && not env.sees_all;
  no_duplicates env "type parameters" tparams;
  check_tparams env f;
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
  (* a parameter with a default comes after those without, but before the
     blocks given last (compiler.md, "Stage 11a", "The surface"), so a
     call's positional arguments read in order: `Async.produce(cap: 2, f)
     fn(items) => ...` (compiler.md, "Services stage", step 5) *)
  (let block (q : Parsed.param) =
     match q.pty with Some (TyFn _) -> true | _ -> false
   in
   let rec before_blocks = function
     | q :: rest when block q -> before_blocks rest
     | qs -> qs
   in
   let ps = List.rev (before_blocks (List.rev f.params)) in
   let rec check = function
     | (q : Parsed.param) :: rest when q.pdefault <> None -> (
         match
           List.rev
             (List.filter (fun (r : Parsed.param) -> r.pdefault = None) rest)
         with
         | last :: _ ->
             report env q.pname.loc
               ~help:(sprintf "move `%s` after `%s`" q.pname.name last.pname.name)
               "a parameter with a default comes after those without"
         | [] -> ())
     | _ :: rest -> check rest
     | [] -> ()
   in
   check ps);
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
      loop = No_loop;
      fn =
        {
          last_id = 0;
          calls = [];
          dots = [];
          typed = [];
          test = f.test;
          made = lowest_node f.body;
          member_of = None;
        };
      next =
        (match f.body.kind with
        | Handler { over = true; _ } ->
            (* the dependencies are resolved with its body, but a parameter
               named `next` is reported now *)
            In_over (f.name.name, [])
        | _ -> No_next);
    }
  in
  let ps, inner =
    (* a function's parameter may be of `Tags`, but not a handler's: it's
       made for the dependency it's installed over, if it's `over any` *)
    params env sc ~rows
      ~top:(match f.body.kind with Handler _ -> false | _ -> true)
      (* a handler's may have a default, as a function's: `striped(h, by:
         By = Key, ...)` (compiler.md, "Services stage", "Stripes") *)
      ~defaults:true
      ~makers:(match f.body.kind with Handler _ -> true | _ -> false)
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
              TyImpl
                {
                  impl_deps =
                    [
                      {
                        dep = { tref = Named owner; tloc = loc };
                        dargs =
                          List.mapi
                            (fun i _ ->
                              TyName ({ tref = Param i; tloc = loc }, []))
                            td.type_params;
                      };
                    ];
                  impl_over = false;
                  impl_errors = None;
                  impl_uses = None;
                  impl_loc = loc;
                }
          | Dep_alias _ ->
              TyImpl
                {
                  impl_deps =
                    [ { dep = { tref = Named owner; tloc = loc }; dargs = [] } ];
                  impl_over = false;
                  impl_errors = None;
                  impl_uses = None;
                  impl_loc = loc;
                }
          | Fields _ | Ctors _ | Opaque _ | Opaque_fields _ | Errors _ | Builtin
            ->
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
  (* a service's member, `Kv$get`, a name only [service_items] gives,
     shares the service's parameters, its first *)
  (match String.index_opt f.name.name '$' with
  | Some i when owner = None && is_capital f.name.name -> (
      let sname = String.sub f.name.name 0 i in
      match Hashtbl.find_opt env.services sname with
      | Some s ->
          sc.fn.member_of <-
            Some
              ( sname,
                s,
                Some
                  (List.filteri
                     (fun j _ -> j < List.length s.passes)
                     (List.map (fun (p : Resolved.param) -> p.pname) ps)) )
      | None -> ())
  | _ when owner = None && is_capital f.name.name -> (
      (* the handler a service is made with, whose state can't call its
         members yet *)
      match Hashtbl.find_opt env.services f.name.name with
      | Some s -> sc.fn.member_of <- Some (f.name.name, s, None)
      | None -> ())
  | _ -> ());
  let ret = ty_opt env ~params:sc.tparams ~rows f.ret in
  let errs = Option.map (errors env ~params:sc.tparams ~rows) f.errors in
  let deps = Option.map (uses_of env ~params:sc.tparams ~rows) f.uses in
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
           row: `handler h(c: Clock uses ..d) for N uses ..d` *)
        let needs =
          match f.body.kind with
          | Handler { needs; _ } ->
              Option.map (uses_of env ~params:sc.tparams ~rows) needs
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
              List.map
                (fun (d : tname dep_ref) ->
                  { d with dep = { d.dep with tloc = f.name.loc } })
                deps
          | _ -> []
        in
        match kind with
        | Handler { over; fails; needs; _ }
          when (f.pub || needs <> None || fails <> None) && own <> [] ->
            ( body,
              Some
                (TyImpl
                   {
                     impl_deps = own;
                     impl_over = over;
                     impl_errors = fails;
                     impl_uses = needs;
                     impl_loc = f.name.loc;
                   }),
              none )
        | _ -> (body, None, none))
    | _ -> (expr env { inner with rows = !named } f.body, ret, deps)
  in
  env.in_test <- false;
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
  | Fields fs | Opaque_fields fs -> no_duplicate_fields fs
  | Ctors cs ->
      List.iter (fun (c : Parsed.ctor) -> no_duplicate_fields c.ctor_fields) cs
  | Dep ops ->
      no_duplicates env "operations"
        (List.map (fun (f : Parsed.field) -> f.field_name) ops)
  | Opaque _ | Errors _ | Dep_alias _ | Builtin -> ());
  let params = List.map (fun (p : ident) -> p.name) td.type_params in
  let field (f : Parsed.field) : Resolved.field =
    let field_ty = ty env ~params f.field_ty in
    (* an operation's defaults are its parameters', at their types *)
    let op_defaults =
      match field_ty with
      | TyFn (ps, _, _, _, _) ->
          List.map
            (fun (i, n, d) -> (i, n, default_of env (List.nth_opt ps i) d))
            f.op_defaults
      | _ -> []
    in
    {
      field_name = f.field_name;
      field_ty;
      field_default = f.field_default;
      op_defaults;
      op_params = f.op_params;
    }
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
                 ctor_named = c.ctor_named;
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
    | Opaque_fields fs -> Opaque_fields (List.map field fs)
    | Errors es -> Errors (errors env ~params es)
    | Dep ops -> Dep (List.map field ops)
    | Dep_alias d -> (
        (* what it names is a dependency, at all of its types, and not
           another alias: an alias is found by its own name, and installs
           what implements the one it names (compiler.md, "Generic
           dependencies") *)
        match uses env ~params:[] [ d ] with
        | [ ({ dep = { tref = Named p; tloc }; _ } as r) ] -> (
            let alias =
              if p.home = env.home then Hashtbl.mem env.own_aliases p.name
              else
                match
                  List.find_opt
                    (fun (i : Iface.t) -> i.home = p.home)
                    env.ifaces
                with
                | Some iface -> (
                    match Iface.find_type iface p.name with
                    | Some { body = Dep_alias _; _ } -> true
                    | _ -> false)
                | None -> false
            in
            match alias with
            | true ->
                report env tloc
                  ~help:
                    (sprintf "name the dependency `%s` is an alias of"
                       (show_tyname d.dep))
                  (sprintf "`%s` is an alias itself, so it can't be aliased"
                     (show_tyname d.dep));
                Dep []
            | false -> Dep_alias r)
        | _ -> Dep [])
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
  | Fields _ | Ctors _ | Opaque _ | Opaque_fields _ | Errors _ | Dep_alias _
  | Builtin ->
      ());
  (* an opaque record's method can share its field's name, and read it,
     `pub fn balance(self) -> Money = self.balance`: outside its module
     there's only the method, and inside, `a.balance` is the field and
     `a.balance()` the method. Unless the field holds a function, which
     `a.f()` would call too. *)
  let accessor (o : Parsed.op) (f : Parsed.field) =
    match (td.type_body, o.op_kind, o.op_fn.params, f.field_ty) with
    | Opaque_fields _, Op_fn, p :: _, (TyName _ | TyTuple _)
      when p.pname.name = "self" ->
        true
    | _ -> false
  in
  (match td.type_body with
  | Fields fs | Opaque_fields fs ->
      List.iter
        (fun (o : Parsed.op) ->
          let id = o.op_fn.name in
          match
            List.find_opt
              (fun (f : Parsed.field) -> f.field_name.name = id.name)
              fs
          with
          | Some f when accessor o f -> ()
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
  | Ctors _ | Opaque _ | Errors _ | Dep _ | Dep_alias _ | Builtin -> ());
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
  | TyName ({ tref = Named p; tloc }, args)
  | TyVariant ({ tref = Named p; tloc }, _, args) ->
      (p, tloc) :: List.concat_map named_in args
  | TyName ({ tref = Param _; _ }, args)
  | TyVariant ({ tref = Param _; _ }, _, args) ->
      List.concat_map named_in args
  | TyFn (ps, ret, errs, u, _) ->
      List.concat_map named_in ps
      @ Option.fold ~none:[] ~some:named_in ret
      @ Option.fold ~none:[] ~some:named_in_errors errs
      @ Option.fold ~none:[] ~some:named_in_uses u
  | TyImpl { impl_deps = ds; impl_errors = es; impl_uses = u; _ } ->
      named_in_deps ds
      @ Option.fold ~none:[] ~some:named_in_errors es
      @ Option.fold ~none:[] ~some:named_in_uses u
  | TyInout (t, _) -> named_in t
  | TyTuple (ts, _) -> List.concat_map named_in ts
  | TyErrors es -> named_in_errors es

(* The dependencies a `uses` lists, and the types they're given. *)
and named_in_uses (u : Resolved.uses) = named_in_deps u.deps

and named_in_deps ds =
  List.concat_map
    (fun (d : tname dep_ref) ->
      (match d.dep.tref with Named p -> [ (p, d.dep.tloc) ] | Param _ -> [])
      @ List.concat_map named_in d.dargs)
    ds

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

(* ---- blocks in written types (foundations.md, "Lambdas are blocks") ----

   A block lives only as long as the call it's passed to, so a type that
   holds data can't have one in it: a record's field, a constructor's or
   an error's payload, a type argument, a tuple, a function's result or
   an associated value. A parameter may be a block, and so may a
   dependency's operation's, but not a handler's: a handler's parameters
   are data, since its description is a value. A `let`'s annotation may
   be a block's type: whether its value is one written there is checked
   once inference knows which expressions are blocks (infer_top.ml,
   [check_blocks]). *)

(* Where a written type is, for an error. *)
let written_at : Resolved.ty -> Loc.t = function
  | TyName ({ tloc; _ }, _) | TyVariant ({ tloc; _ }, _, _) -> tloc
  | TyFn (_, _, _, _, l)
  | TyImpl { impl_loc = l; _ }
  | TyInout (_, l)
  | TyTuple (_, l) ->
      l
  | TyErrors es -> es.eloc

(* Whether a written type is a scope, which rule D keeps where a block is
   kept. A task has no handle (concurrency.md, "The tree side"). *)
let rec written_handle (t : Resolved.ty) =
  match t with
  | TyName ({ tref = Named p; _ }, []) when p = Path.prelude "Scope" ->
      Some Infer_msg.Scope_of
  | TyInout (t, _) -> written_handle t
  | _ -> None

let no_kept_blocks env (items : Resolved.program) =
  let kept loc place =
    Diag.report env.sink (Infer_msg.block_kept ~written:true loc place)
  in
  (* a scope, written where a block can't be (rule D, compiler.md,
     "Stage 11a", "The checker") *)
  let kept_handle ?op loc h place =
    if env.home <> Path.prelude_home then
      Diag.report env.sink (Infer_msg.handle_kept ?op ~written:true loc h place)
  in
  (* [t], where data goes, [place]: a block in it is reported, the
     outermost one *)
  let rec data place (t : Resolved.ty) =
    match t with
    | TyFn (_, _, _, _, l) -> kept l place
    | TyName ({ tloc; _ }, _) when written_handle t <> None ->
        kept_handle tloc (Option.get (written_handle t)) place
    | _ -> inner t
  (* the types in [t], which may itself be a block *)
  and inner (t : Resolved.ty) =
    match t with
    | TyName (_, args) | TyVariant (_, _, args) ->
        List.iter (data In_type_arg) args
    | TyTuple (ts, _) -> List.iter (data In_tuple) ts
    | TyFn (ps, ret, es, _, _) ->
        List.iter inner ps;
        Option.iter (data Returned) ret;
        Option.iter errors es
    | TyImpl { impl_errors = es; _ } -> Option.iter errors es
    | TyInout (t, _) -> inner t
    | TyErrors es -> errors es
  and errors (es : Resolved.errors) =
    List.iter
      (function
        | Tag (_, ps) ->
            List.iter
              (fun (p : Resolved.payload) -> data In_error p.payload_ty)
              ps
        | Set _ -> ())
      es.errs
  in
  (* a family's handle, `Family<K, D>`, written in [t]: it's good only in
     the state of the handler that opened it, whose operations are where
     its waits and its instances' `finally`s may run (compiler.md,
     "Services stage", "Step 9, soundness"), so it can't leave through an
     operation, a dependency's type argument or a handler's parameter *)
  let family_in place (t : Resolved.ty) =
    let rec find (t : Resolved.ty) =
      match t with
      | TyName ({ tref = Named p; tloc; _ }, _) when p = Path.prelude "Family" -> Some tloc
      | TyName (_, ts) | TyVariant (_, _, ts) | TyTuple (ts, _) -> List.find_map find ts
      | TyFn (ps, ret, _, _, _) -> List.find_map find (ps @ Option.to_list ret)
      | TyInout (t, _) -> find t
      | TyImpl _ | TyErrors _ -> None
    in
    if env.home <> Path.prelude_home then
      Option.iter (fun loc -> Diag.report env.sink (Infer_msg.family_kept loc place)) (find t)
  in
  let rec has_block (t : Resolved.ty) =
    match t with
    | TyFn _ -> true
    | TyName (_, ts) | TyVariant (_, _, ts) | TyTuple (ts, _) ->
        List.exists has_block ts
    | TyInout (t, _) -> has_block t
    | TyImpl _ | TyErrors _ -> false
  in
  (* the types a function's body writes: its blocks' parameters' and its
     `let`s' *)
  let rec expr (e : Resolved.expr) =
    let stmt = function
      | Let { ty = Some t; _ } -> inner t
      | Let _ | Let_pattern _ | Expr _ | Finally _ -> ()
    in
    (match e.kind with
    | Lambda (ps, _) ->
        List.iter (fun (p : Resolved.param) -> Option.iter inner p.pty) ps
    | Block (stmts, _) | Handler { state = stmts; _ } -> List.iter stmt stmts
    | _ -> ());
    List.iter expr (Ast.children e)
  in
  let fn ?(value = false) (f : Resolved.fn_def) =
    List.iter
      (fun (p : Resolved.param) ->
        (match p.pty with
        | Some t when Ast.is_handler f -> family_in `Handler_param t
        | _ -> ());
        match p.pty with
        | Some t when Ast.is_handler f && has_block t && p.pblock <> Spawned ->
            let name = p.pname.ident in
            Diag.report env.sink
              (Infer_msg.handler_param_block ~name:name.name
                 (Loc.span name.loc (written_at t)))
        | Some t when Ast.is_handler f && written_handle t <> None ->
            let name = p.pname.ident in
            Diag.report env.sink
              (Infer_msg.handler_param_handle ~name:name.name
                 (Loc.span name.loc (written_at t))
                 (Option.get (written_handle t)))
        | Some t -> inner t
        | None -> ())
      f.params;
    (* a dependency it uses whose type argument is a family's handle,
       `uses Chan<Family<K, D>>`, which a handler could send it through *)
    Option.iter
      (fun (u : _ Ast.uses) ->
        List.iter (fun (d : _ Ast.dep_ref) -> List.iter (family_in `Dep_arg) d.dargs) u.deps)
      f.uses;
    Option.iter (data (if value then In_value f.name.name else Returned)) f.ret;
    Option.iter errors f.errors;
    expr f.body
  in
  List.iter
    (function
      | Fn f -> fn f
      | Type td ->
          let field place (fd : Resolved.field) = data place fd.field_ty in
          (match td.type_body with
          | Fields fs | Opaque_fields fs -> List.iter (field In_record) fs
          | Ctors cs ->
              List.iter
                (fun (c : Resolved.ctor) ->
                  List.iter (field (In_payload c.ctor_name.name)) c.ctor_fields)
                cs
          | Opaque { rep; _ } -> data Represented rep
          | Errors es -> errors es
          | Dep ops ->
              (* an operation is a function, which may take a block, but
                 not a scope: another task can call it *)
              List.iter
                (fun (fd : Resolved.field) ->
                  (match fd.field_ty with
                  | TyFn (ps, _, _, _, _) ->
                      List.iter
                        (fun (q : Resolved.ty) ->
                          match written_handle q with
                          | Some h -> kept_handle ~op:true (written_at q) h Elsewhere
                          | None -> ())
                        ps
                  | _ -> ());
                  family_in `Op fd.field_ty;
                  inner fd.field_ty)
                ops
          | Dep_alias d -> List.iter (family_in `Dep_arg) d.dargs
          | Builtin -> ());
          List.iter
            (fun (o : Resolved.op) -> fn ~value:(o.op_kind = Op_value) o.op_fn)
            td.type_ops
      | Import _ | Testing _ | Wiring _ | Service _ -> ())
    items

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
    | Some (TyImpl { impl_errors = fails; impl_uses = needs; _ })
      when Ast.is_handler f ->
        (* what it implements [handler] checks; what it needs, and how it
           can fail, are its own *)
        Option.iter
          (fun u ->
            no_private_named env ~private_ (named_in_uses u)
              ~say:(fun (p : Path.t) ->
                sprintf "`pub handler %s` needs `%s`" (Ast.fn_name f) p.name))
          needs;
        Option.iter
          (no_private_errors env ~private_
             ~set:
               (sprintf "`pub handler %s` can fail with `%s`" (Ast.fn_name f))
             ~tag:
               (sprintf "`pub handler %s`'s error `%s` mentions `%s`"
                  (Ast.fn_name f)))
          fails
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
        no_private_named env ~private_ (named_in_deps deps)
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
          | Dep_alias d ->
              no_private_named env ~private_ (named_in_deps [ d ])
                ~say:(fun (p : Path.t) ->
                  sprintf "`pub dep %s` names `%s`" t p.name)
          | Opaque _ | Opaque_fields _ | Builtin ->
              (* its representation isn't in the interface, so it can be a
                 private type *)
              ()
          | Errors es ->
              no_private_errors env ~private_ es
                ~set:(sprintf "`pub type %s` includes `%s`" t)
                ~tag:(sprintf "`pub type %s`'s error `%s` mentions `%s`" t))
      | Fn _ | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
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
        | Fn _ | Import _ | Testing _ | Wiring _ | Service _ -> None)
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

(* The name of the function a wiring's own `with` is checked in
   ([wiring_fns]), and the wiring a function of that name checks. *)
let check_fn name = name ^ "$wiring"

(* The service the function [f] is a member of, `Kv` for `Kv$get`: a
   name only [service_items] gives. *)
let service_member (f : Path.t) =
  match (f.member, String.index_opt f.name '$') with
  | None, Some i when is_capital f.name -> Some (String.sub f.name 0 i)
  | _ -> None

(* Whether the function [f] is the handler a service is made with, named
   as the service is, which no other function can be. *)
let service_handler (f : Path.t) =
  f.member = None && is_capital f.name && not (String.contains f.name '$')

let checked_wiring (f : Path.t) =
  let suffix = "$wiring" in
  if f.member = None && (not (is_capital f.name)) && String.ends_with ~suffix f.name then
    Some (String.sub f.name 0 (String.length f.name - String.length suffix))
  else None

(* The module's wirings [defs], flattened into their shapes, in
   [env.wirings], and the functions that makes: one for each link
   ([use_wiring], above), and one for each wiring, its own `with`, which
   is how inference checks it as it checks a function:

     fn live$wiring(url: Str) = try with live(url) in ()

   what it uses is the wiring's `uses`, and what it fails with its `!`,
   written for a `pub` one, inferred for a private one; the `try`, whose
   node is Test_items' [passed_on], needn't cover anything, since a
   wiring may start without failing. Nothing calls it, and Lower drops
   it. A wiring that lists itself, through any number of others, is
   reported once, at the first of the loop, and has no shape. *)
let wiring_fns env (defs : Parsed.wiring_def list) =
  let made = ref [] in
  let broken = Hashtbl.create 4 in
  let rec shape ~visiting (w : Parsed.wiring_def) =
    let name = w.wname.name in
    match Hashtbl.find_opt env.wirings name with
    | Some s -> Some s
    | None when Hashtbl.mem broken name -> None
    | None when List.mem name visiting ->
        (* [visiting] is the way here, most recent first *)
        let rec upto acc = function
          | x :: _ when x = name -> x :: acc
          | x :: rest -> upto (x :: acc) rest
          | [] -> acc
        in
        let loop = upto [] visiting in
        List.iter (fun n -> Hashtbl.replace broken n ()) loop;
        let first = List.hd loop in
        let at =
          match Hashtbl.find_opt env.wiring_defs first with
          | Some d -> d.wname.loc
          | None -> w.wname.loc
        in
        report env at
          ~help:"a wiring can list another, but not one that lists it"
          (sprintf "`%s` lists itself: %s" first
             (String.concat " → " (loop @ [ first ])));
        None
    | None -> (
        let params = List.map (fun (p : Parsed.param) -> p.pname.name) w.wparams in
        let index n =
          let rec go i = function
            | p :: _ when p = n -> Some i
            | _ :: rest -> go (i + 1) rest
            | [] -> None
          in
          go 0 params
        in
        (* the parameters [e] reads, by their places *)
        let reads (e : Parsed.expr) =
          let rec go acc (e : Parsed.expr) =
            let acc =
              match e.kind with
              | Var (Bare x) -> (
                  match index x with Some i -> i :: acc | None -> acc)
              | _ -> acc
            in
            List.fold_left go acc (Ast.children e)
          in
          List.sort_uniq compare (go [] e)
        in
        let count = ref 0 in
        (* the link [body], as a function of what it reads, or a
           parameter passed on *)
        let link_fn (body : Parsed.expr) : Iface.link =
          installed env body;
          match body.kind with
          | Var (Bare p) when index p <> None -> Passed (Option.get (index p))
          | _ ->
              incr count;
              let fname = sprintf "%s$%d" name !count in
              let used = reads body in
              made :=
                Fn
                  {
                    pub = false;
                    name = { name = fname; loc = w.wname.loc };
                    tparams = [];
                    tneeds = [];
                    params =
                      List.filteri (fun i _ -> List.mem i used)
                        (List.map
                           (fun (p : Parsed.param) -> { p with pdefault = None })
                           w.wparams);
                    ret = None;
                    errors = None;
                    uses = None;
                    body;
                    owner = None;
                    overload = 0;
                    test = false;
                    loc = body.loc;
                  }
                :: !made;
              Made (fname, used)
        in
        let fresh = ref (-1) in
        let mk loc kind : Parsed.expr =
          decr fresh;
          { kind; loc; node = !fresh }
        in
        let own n =
          Option.bind (Hashtbl.find_opt env.wiring_defs n)
            (shape ~visiting:(name :: visiting))
        in
        let items =
          List.concat_map
            (fun (it : Parsed.with_item) ->
              match
                wiring_ref env ~local:(fun n -> index n <> None) ~own it
              with
              | Some r -> (
                  wiring_written env it r;
                  match r.shape with
                  | None -> []
                  | Some inner ->
                      (* each of its links, given this one's arguments *)
                      let callee f : Parsed.expr_kind =
                        match r.through with
                        | None -> Var (Bare f)
                        | Some ((i : import), _) ->
                            Field
                              ( mk r.rloc (Var (Bare i.alias.name)),
                                { name = f; loc = r.rloc } )
                      in
                      let arg i = List.nth_opt r.args i in
                      List.map
                        (fun (wi : Iface.wired_item) : Iface.wired_item ->
                          {
                            wi with
                            links =
                              List.map
                                (function
                                  | Iface.Passed i -> (
                                      match arg i with
                                      | Some a -> link_fn a
                                      | None -> Iface.Passed 0
                                      (* the wrong number, reported *))
                                  | Made (f, used) ->
                                      link_fn
                                        (mk r.rloc
                                           (Call
                                              ( mk r.rloc (callee f),
                                                List.filter_map arg used ))))
                                wi.links;
                            wvia =
                              wi.wvia
                              @ [
                                  {
                                    wiring = r.written;
                                    declared = inner.wdeclared;
                                    provides = inner.wprovides;
                                  };
                                ];
                            wloc = it.iloc;
                          })
                        inner.witems)
              | None ->
                  [
                    {
                      links =
                        List.map
                          (fun (l : Parsed.with_link) -> link_fn l.link)
                          it.chain;
                      wunder = uses env ~params:[] it.under;
                      walias =
                        Option.bind it.alias (fun d ->
                            match uses env ~params:[] [ d ] with
                            | [ d ] -> Some d
                            | _ -> None);
                      wvia = [];
                      wloc = it.iloc;
                    };
                  ])
            w.witems
        in
        (* a cycle met inside reports itself; this one is broken then too *)
        if Hashtbl.mem broken name then None
        else
          let s : Iface.wiring =
            {
              wname = name;
              wpub = w.wpub;
              wparams = params;
              wprovides = Iface.dep_paths (uses env ~params:[] w.provides);
              witems = items;
              wdeclared = w.wname.loc;
              wwritten = [];
            }
          in
          Hashtbl.replace env.wirings name s;
          Some s)
  in
  List.iter
    (fun (w : Parsed.wiring_def) ->
      List.iter
        (fun (p : Parsed.param) ->
          Option.iter
            (fun (_, l, _) ->
              report env l ~help:"give it in the `with` that lists the wiring"
                "a wiring's parameter has no default")
            p.pdefault)
        w.wparams;
      match shape ~visiting:[] w with
      | None -> ()
      | Some _ ->
          let loc = w.wname.loc in
          let none_used = { deps = []; dtail = None; uloc = loc } in
          let no_errors = { errs = []; etail = None; eloc = loc } in
          let node = ref (-1) in
          let mk kind : Parsed.expr =
            decr node;
            { kind; loc; node = !node }
          in
          let listed =
            match w.wparams with
            | [] -> mk (Var (Bare w.wname.name))
            | ps ->
                mk
                  (Call
                     ( mk (Var (Bare w.wname.name)),
                       List.map
                         (fun (p : Parsed.param) -> mk (Var (Bare p.pname.name)))
                         ps ))
          in
          decr node;
          let item : Parsed.with_item =
            {
              chain = [ { link = listed; knode = !node } ];
              under = [];
              alias = None;
              iloc = loc;
              from = [];
            }
          in
          let with_ = mk (With { items = [ item ]; body = mk Unit }) in
          made :=
            Fn
              {
                pub = false;
                name = { name = check_fn w.wname.name; loc };
                tparams = [];
                tneeds = [];
                params =
                  List.map
                    (fun (p : Parsed.param) -> { p with pdefault = None })
                    w.wparams;
                ret = None;
                errors =
                  (if w.wpub then Some (Option.value w.werrors ~default:no_errors)
                   else w.werrors);
                uses =
                  (if w.wpub then Some (Option.value w.wuses ~default:none_used)
                   else w.wuses);
                body = { with_ with kind = Try with_; node = Test_items.passed_on };
                owner = None;
                overload = 0;
                test = false;
                loc = w.wloc;
              }
            :: !made)
    defs;
  List.rev !made

(* ---- services (language.md §4), declared ----

   A service is exactly a `dep` and a handler, and its members are
   functions the handler's arms call (compiler.md, "Services stage",
   "Step 2b"):

     pub service Kv(c: Cfg) uses Http ! E =
       pub fn get(k: Key) -> Str ! KvError = ...
       fn call(req: Request) -> Response ! KvError = ...

   is

     pub dep Kv =
       get: fn(Key) -> Str ! KvError
     pub handler Kv(c: Cfg) for Kv uses Http ! E =
       get(k) => try Kv$get(c, k)
     fn Kv$get(c: Cfg, k: Key) -> Str ! KvError uses Http = ...
     fn Kv$call(c: Cfg, req: Request) -> Response ! KvError uses Http = ...

   The handler is named as the service is, and each member after it and a
   `$`: names no one can write, so neither meets a name of the program's
   (nor `--release`'s, which names an arm it lifts `handler.op`), and a
   message about a member names it as `Kv.get` (Ast.fn_name). Each member takes
   the service's parameters first, and its `uses` is the service's, a
   bound each keeps to, or inferred for a private service, so what the
   members need is required where the service is installed (deps.md).
   A member is a function, not an arm, so members call each other in any
   order, recursively too ([expr] passes the shared parameters on).

   Its state, `var n: Int = 0` and the rest, is the handler's, set up by
   each `with` that installs it, and given to each member after the
   parameters: a `var` `inout`, a `let` by value, under its own name, so
   `n += 1` in a member changes the instance's `n`. An arm passes `&n`;
   a member calling another passes its own `&n` on. That's sound with
   nothing new (compiler.md, "Step 2b (state)"): a member is a direct
   call inside the arm that keeps the instance, never an operation that
   takes it again, and what it's given is checked as any `&` argument
   is. A state's type is written, or a literal's, since a member's
   parameter needs one to find its methods. A `pub fn`'s result
   and errors are as written, `()` and none if left out, as a public
   function's are, since they're the dependency's operation. *)
let service_items env (s : Parsed.service_def) : Parsed.program =
  let sname = s.sname.name in
  let shared = List.map (fun (p : Parsed.param) -> p.pname.name) s.sparams in
  let writes (u : Parsed.uses) =
    String.concat ", " (List.map (fun (d : tyname dep_ref) -> show_tyname d.dep) u.deps)
  in
  no_duplicates env "functions in a service"
    (List.map (fun (m : Parsed.fn_def) -> m.name) s.members);
  List.iter
    (fun (m : Parsed.fn_def) ->
      (match m.uses with
      | Some u ->
          let all =
            match s.suses with Some su -> writes su ^ ", " ^ writes u | None -> writes u
          in
          report env u.uloc
            ~notes:
              [
                sprintf
                  "what its functions need is required where `%s` is \
                   installed, so it's written once, on `%s`"
                  sname sname;
              ]
            ~help:
              (sprintf "move it to the service's: `service %s(...) uses %s`"
                 sname all)
            (sprintf "`%s` shares `%s`'s `uses`, so it doesn't write its own"
               m.name.name sname)
      | None -> ());
      if m.pub then (
        if m.tparams <> [] then
          report env m.name.loc
            ~help:"make it a function of its own, outside the service"
            (sprintf
               "`%s` is an operation of `%s`, so it can't take type parameters"
               m.name.name sname);
        List.iter
          (fun (p : Parsed.param) ->
            if p.pty = None then
              report env p.pname.loc
                ~help:(sprintf "write its type: `%s: T`" p.pname.name)
                (sprintf
                   "`%s` is an operation of `%s`, so its parameters have \
                    types"
                   m.name.name sname)
            else if p.pmode = Inout then
              report env p.pname.loc
                ~help:"take it, and return what it becomes"
                (sprintf
                   "`%s` is an operation of `%s`, so its parameter can't be \
                    `inout`"
                   m.name.name sname))
          m.params))
    s.members;
  let ops = List.filter (fun (m : Parsed.fn_def) -> m.pub) s.members in
  if ops = [] then
    report env s.sname.loc
      ~help:"mark the functions its callers call `pub fn`"
      (sprintf "`%s` has no operations: a service's operations are its `pub \
                fn`s"
         sname);
  (* its state, each `let` and `var` a parameter of every member, by
     value or `inout`: its type written, or a literal's *)
  let state =
    List.filter_map
      (fun (st : Parsed.stmt) ->
        match st with
        | Let { name; ty; value; mut } -> (
            let named n : Parsed.ty =
              TyName ({ tmod = None; tid = { name = n; loc = name.loc } }, [])
            in
            let rec literal (v : Parsed.expr) =
              match v.kind with
              | Int _ -> Some (named "Int")
              | Float _ -> Some (named "Float")
              | Bool _ -> Some (named "Bool")
              | Str _ | Interp _ -> Some (named "Str")
              | Unop (_, a, _) -> literal a
              | _ -> None
            in
            match (ty, literal value) with
            | Some t, _ | None, Some t -> Some (name, Some t, mut)
            | None, None ->
                report env name.loc
                  ~notes:
                    [
                      sprintf
                        "each of `%s`'s functions is given its state, as a \
                         parameter, and a parameter's type is written"
                        sname;
                    ]
                  ~help:
                    (sprintf "write it: `%s %s: T = ...`"
                       (if mut then "var" else "let")
                       name.name)
                  (sprintf "`%s` is `%s`'s state, so its type is written"
                     name.name sname);
                (* still given, so its uses aren't reported too *)
                Some (name, None, mut))
        | Let_pattern { pat; _ } ->
            report env pat.ploc
              ~help:"name it, and take it apart where it's used"
              (sprintf
                 "`%s`'s state is given to its functions by name, so it isn't \
                  taken apart"
                 sname);
            None
        | Expr _ | Finally _ -> None)
      s.sstate
  in
  Hashtbl.replace env.services sname
    {
      members = List.map (fun (m : Parsed.fn_def) -> m.name.name) s.members;
      passes =
        List.map (fun _ -> false) s.sparams
        @ List.map (fun (_, _, mut) -> mut) state;
    };
  (* what this makes is numbered below the parser's, in the handler *)
  let fresh = ref 0 in
  let mk loc kind : Parsed.expr =
    decr fresh;
    { kind; loc; node = !fresh }
  in
  let unit loc : Parsed.ty =
    TyName ({ tmod = None; tid = { name = "Unit"; loc } }, [])
  in
  (* an operation's result and errors, as a `pub fn`'s are *)
  let ret (m : Parsed.fn_def) =
    match m.ret with Some t -> t | None -> unit m.name.loc
  in
  let errs (m : Parsed.fn_def) : Parsed.errors =
    match m.errors with
    | Some es -> es
    | None -> { errs = []; etail = None; eloc = m.name.loc }
  in
  let dep : Parsed.type_def =
    {
      type_pub = s.spub;
      type_name = s.sname;
      type_params = [];
      type_body =
        Dep
          (List.map
             (fun (m : Parsed.fn_def) : Parsed.field ->
               {
                 field_name = m.name;
                 field_ty =
                   TyFn
                     ( List.filter_map
                         (fun (p : Parsed.param) -> p.pty)
                         m.params,
                       Some (ret m),
                       m.errors,
                       None,
                       m.loc );
                 field_default = None;
                 (* a parameter's default is the operation's, as a
                    dependency's operation writes one *)
                 op_defaults =
                   List.concat
                     (List.mapi
                        (fun i (p : Parsed.param) ->
                          match p.pdefault with
                          | Some d -> [ (i, p.pname.name, d) ]
                          | None -> [])
                        m.params);
                 op_params =
                   List.filter_map
                     (fun (p : Parsed.param) ->
                       Option.map (fun _ -> p.pname.name) p.pty)
                     m.params;
               })
             ops);
      type_ops = [];
    }
  in
  let arm (m : Parsed.fn_def) : Parsed.handler_arm =
    let at = m.name.loc in
    let var n = mk at (Var (Bare n)) in
    let call =
      mk at
        (Call
           ( var (sname ^ "$" ^ m.name.name),
             List.map var shared
             @ List.map
                 (fun ((n : ident), _, mut) ->
                   if mut then mk at (Ref (var n.name)) else var n.name)
                 state
             @ List.map (fun (p : Parsed.param) -> var p.pname.name) m.params ))
    in
    {
      arm_op = Bare m.name.name;
      arm_name = m.name;
      arm_impl =
        mk at
          (Lambda
             ( List.map
                 (fun (p : Parsed.param) -> { p with pty = None; pdefault = None })
                 m.params,
               if m.errors = None then call else mk at (Try call) ));
    }
  in
  let handler : Parsed.fn_def =
    {
      pub = s.spub;
      name = s.sname;
      tparams = [];
      tneeds = [];
      params = s.sparams;
      ret = None;
      errors = None;
      uses = None;
      body =
        mk s.sname.loc
          (Handler
             {
               deps = [ { dep = { tmod = None; tid = s.sname }; dargs = [] } ];
               over = false;
               any = false;
               fails = s.serrors;
               needs = s.suses;
               state = s.sstate;
               arms = List.map arm ops;
             });
      owner = None;
      overload = 0;
      test = false;
      loc = s.sloc;
    }
  in
  let member (m : Parsed.fn_def) : Parsed.item =
    Fn
      {
        m with
        pub = false;
        name = { name = sname ^ "$" ^ m.name.name; loc = m.name.loc };
        params =
          List.map (fun (p : Parsed.param) -> { p with pdefault = None }) s.sparams
          @ List.map
              (fun ((n : ident), t, mut) : Parsed.param ->
                {
                  pname = n;
                  pty = t;
                  pmode = (if mut then Inout else Read);
                  pblock = Ordinary;
                  pdefault = None;
                })
              state
          @ m.params;
        ret = (if m.pub then Some (ret m) else m.ret);
        errors = (if m.pub then Some (errs m) else m.errors);
        (* a public service's members are checked against its `uses`, none
           if it writes none, as a public handler's arms are, so what one
           needs that isn't there is reported where it's used
           (infer_declared.ml) *)
        uses =
          (match s.suses with
          | Some u -> Some u
          | None when s.spub -> Some { deps = []; dtail = None; uloc = s.sname.loc }
          | None -> None);
      }
  in
  (Type dep :: Fn handler :: List.map member s.members)

(* ---- `D.Call` (compiler.md, "Services stage", "`D.Call`") ----

   For each dependency whose operations are all data, the compiler writes
   `D.Call`, a sum with a case per operation, the operation's name in
   upper camel case, its parameters as fields by name: the calls of `D`
   as values (formats.md, "Dependencies as data"). It's written beside the
   dependency, public if it is, before anything is resolved, so it's an
   ordinary sum from here on: built, matched, compared and shown as any
   is. *)

(* Why the operation [f] isn't data, if it isn't: it takes a block, or
   changes an argument, or gives a block. A description or a handle
   among its arguments isn't caught here: only what the parser can see
   is (compiler.md, "Where this stage may differ"). *)
let not_data (f : Parsed.field) =
  match f.field_ty with
  | TyFn (ps, ret, _, _, _) -> (
      let rec block : Parsed.ty -> bool = function
        | TyFn _ -> true
        | TyTuple (ts, _) -> List.exists block ts
        | TyName (_, ts) | TyVariant (_, _, ts) -> List.exists block ts
        | _ -> false
      in
      match
        List.find_opt
          (fun (t : Parsed.ty) ->
            match t with TyInout _ -> true | t -> block t)
          ps
      with
      | Some (TyInout _) -> Some "changes an argument"
      | Some _ -> Some "takes a block"
      | None -> (
          match ret with
          | Some t when block t -> Some "gives a block"
          | _ -> None))
  | _ -> Some "isn't an operation"

(* [prog] with each dependency's `D.Call` after it, for those whose
   operations are all data. A parameter written without a name is a field
   named by its place, `_1`. *)
let call_types env (prog : Parsed.program) =
  List.concat_map
    (fun (item : Parsed.item) ->
      match item with
      | Type ({ type_body = Dep ops; _ } as td)
        when List.exists (fun f -> not_data f <> None) ops ->
          (match
             List.find_map
               (fun (f : Parsed.field) ->
                 Option.map (fun why -> (f.field_name.name, why)) (not_data f))
               ops
           with
          | Some reason -> Hashtbl.replace env.not_data td.type_name.name reason
          | None -> ());
          [ item ]
      | Type ({ type_body = Dep (_ :: _ as ops); _ } as td) ->
          let case (f : Parsed.field) : Parsed.ctor =
            let ps =
              match f.field_ty with TyFn (ps, _, _, _, _) -> ps | _ -> []
            in
            let loc = f.field_name.loc in
            let ctor_fields =
              List.mapi
                (fun i (t : Parsed.ty) : Parsed.field ->
                  let name =
                    match List.nth_opt f.op_params i with
                    | Some n when n <> "" -> n
                    | _ -> sprintf "_%d" (i + 1)
                  in
                  {
                    field_name = { name; loc };
                    field_ty = t;
                    field_default = None;
                    op_defaults = [];
                    op_params = [];
                  })
                ps
            in
            {
              ctor_name = { name = Ty.call_case f.field_name.name; loc };
              ctor_fields;
              ctor_named = ctor_fields <> [];
            }
          in
          [
            item;
            Type
              {
                type_pub = td.type_pub;
                type_name =
                  { td.type_name with name = td.type_name.name ^ ".Call" };
                type_params = td.type_params;
                type_body = Ctors (List.map case ops);
                type_ops = [];
              };
          ]
      | item -> [ item ])
    prog

let program sink ~home ~imports ?(groups = []) ?(sees_all = false)
    (prog : Parsed.program) =
  (* tests are functions by now (test_items.ml); any left are ignored *)
  let prog = List.filter (function Testing _ -> false | _ -> true) prog in
  (* each import, with the interface of the module it imports; the driver
     passes the interface of every module the program imports *)
  let imported =
    List.filter_map
      (function
        | Import (i : import) ->
            Some (i, List.find (fun (m : Iface.t) -> m.home = i.path) imports)
        | Fn _ | Type _ | Testing _ | Wiring _ | Service _ -> None)
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
      through = Hashtbl.create 4;
      own_numeric = Hashtbl.create 8;
      own_tests = Hashtbl.create 8;
      own_private = Hashtbl.create 16;
      in_test = false;
      sees_all;
      own_sets = Hashtbl.create 8;
      own_deps = Hashtbl.create 8;
      own_aliases = Hashtbl.create 8;
      named_ctors = Hashtbl.create 8;
      sums = Hashtbl.create 8;
      own_sums = Hashtbl.create 8;
      modules =
        List.fold_left
          (fun acc ((i : import), iface) -> Env.add i.alias.name (i, iface) acc)
          Env.empty imported;
      used = Hashtbl.create 8;
      used_types = Hashtbl.create 8;
      wirings = Hashtbl.create 8;
      wiring_defs = Hashtbl.create 8;
      services = Hashtbl.create 8;
      installs = Hashtbl.create 8;
      not_data = Hashtbl.create 4;
    }
  in
  (* each service, a `dep`, a handler and its members' functions from
     here on, where it's written (see [service_items]) *)
  let prog =
    List.concat_map
      (function Service s -> service_items env s | item -> [ item ])
      prog
  in
  (* each dependency's sum of calls, `D.Call`, beside it (see
     [call_types]) *)
  let prog = if home = Path.prelude_home then prog else call_types env prog in
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
            | Fields fs | Opaque_fields fs ->
                List.map (fun (f : Parsed.field) -> f.field_name.name) fs
            | Ctors _ | Opaque _ | Errors _ | Dep _ | Dep_alias _ | Builtin ->
                []
          in
          (* what a test doesn't see: a private type, and a private
             member; an operator and a `key` are public wherever their
             type is *)
          if not td.type_pub then
            Hashtbl.replace env.own_private ("type " ^ td.type_name.name) ();
          List.iter
            (fun (o : Parsed.op) ->
              if not o.op_fn.pub then
                Hashtbl.replace env.own_private
                  (td.type_name.name ^ "." ^ o.op_fn.name.name)
                  ())
            td.type_ops;
          (match td.type_body with
          | Errors _ -> Hashtbl.replace env.own_sets td.type_name.name ()
          | Opaque { numeric = Some _; _ } ->
              Hashtbl.replace env.own_numeric td.type_name.name ()
          | Dep ops ->
              if not (Hashtbl.mem env.own_deps td.type_name.name) then
                Hashtbl.replace env.own_deps td.type_name.name
                  (List.map (fun (f : Parsed.field) -> f.field_name.name) ops)
          | Dep_alias d ->
              if not (Hashtbl.mem env.own_aliases td.type_name.name) then
                Hashtbl.replace env.own_aliases td.type_name.name d.dep
          | Fields _ | Ctors _ | Opaque _ | Opaque_fields _ | Builtin -> ());
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
      | Fn _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
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
      | Fn _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
    prog;
  (* the sum types in scope bare, and their by-name constructors, which a
     bare `Name { ... }` can mean ([braces_name]) *)
  Hashtbl.iter
    (fun name ((p : Path.t), _) ->
      let ctors =
        if p.home = home then
          List.find_map
            (function
              | Type ({ type_body = Ctors cs; _ } as td : Parsed.type_def)
                when td.type_name.name = p.name ->
                  Hashtbl.replace env.own_sums p.name
                    (List.map
                       (fun (c : Parsed.ctor) : Iface.ctor ->
                         {
                           cname = c.ctor_name.name;
                           cnamed = c.ctor_named;
                           cloc = c.ctor_name.loc;
                           cfields =
                             List.map
                               (fun (f : Parsed.field) : Iface.field ->
                                 {
                                   fname = f.field_name.name;
                                   fty = Ty.Error;
                                   fdefault = None;
                                   fdefaults = [];
                                 })
                               c.ctor_fields;
                         })
                       cs);
                  Some
                    (List.filter_map
                       (fun (c : Parsed.ctor) ->
                         if c.ctor_named then Some c.ctor_name.name else None)
                       cs)
              | _ -> None)
            prog
        else
          match
            List.find_map
              (fun (i : Iface.t) ->
                if i.home = p.home then Iface.find_type i p.name else None)
              env.ifaces
          with
          | Some { body = Sum cs; _ } ->
              Some
                (List.filter_map
                   (fun (c : Iface.ctor) -> if c.cnamed then Some c.cname else None)
                   cs)
          | _ -> None
      in
      (* a dependency's `D.Call` is named only with its dependency's name
         in front, so its constructors are never bare *)
      Option.iter
        (fun cs ->
          if Ty.call_dep p = None then (
            Hashtbl.replace env.sums name ();
            List.iter (fun c -> Hashtbl.replace env.named_ctors c name) cs))
        ctors)
    env.types;
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
        iface.values;
      (* and its test items, `replay`, which only test code can use *)
      List.iter
        (fun (v : Iface.value) ->
          Hashtbl.replace env.values v.vname
            (Global (Path.make iface.home v.vname));
          Hashtbl.replace env.own_tests v.vname ())
        iface.tests)
    prelude;
  (* the wirings, each made functions (see [wiring_fns]), which are the
     module's from here on *)
  let wiring_defs =
    List.filter_map (function Wiring w -> Some w | _ -> None) prog
  in
  List.iter
    (fun (w : Parsed.wiring_def) ->
      let n = w.wname in
      (match Hashtbl.find_opt env.wiring_defs n.name with
      | Some (first : Parsed.wiring_def) ->
          report env n.loc ~help:"rename one of them"
            ~labels:[ (first.wname.loc, sprintf "the first `%s` is here" n.name) ]
            (sprintf "there are two wirings named `%s`" n.name)
      | None -> Hashtbl.replace env.wiring_defs n.name w);
      if not w.wpub then Hashtbl.replace env.own_private ("wiring " ^ n.name) ())
    wiring_defs;
  let prog =
    List.filter (function Wiring _ -> false | _ -> true) prog
    @ wiring_fns env wiring_defs
  in
  let fns =
    List.filter_map
      (function
        | Fn (f : Parsed.fn_def) -> Some f
        | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> None)
      prog
  in
  List.iter
    (fun (f : Parsed.fn_def) ->
      match Hashtbl.find_opt env.wiring_defs f.name.name with
      | Some w ->
          report env f.name.loc ~help:"rename one of them"
            ~labels:[ (w.wname.loc, sprintf "the wiring `%s` is here" f.name.name) ]
            (sprintf "a wiring and a %s are both named `%s`"
               (if Ast.is_handler f then "handler" else "function")
               f.name.name)
      | None -> ())
    fns;
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
        (Global (Path.make home f.name.name));
      if f.test then Hashtbl.replace env.own_tests f.name.name ()
      else if not f.pub then Hashtbl.replace env.own_private f.name.name ())
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
           | Testing _ | Wiring _ | Service _ -> (* left out above *) assert false)
         prog)
  in
  let private_ = Hashtbl.create 8 in
  List.iter
    (function
      | Type (td : Resolved.type_def) when not td.type_pub ->
          Hashtbl.replace private_ td.type_name.name td.type_name.loc
      | Fn _ | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
    items;
  no_leaks env ~private_ ~groups items;
  no_opaque_cycles env items;
  no_set_cycles env items;
  no_kept_blocks env items;
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
        | Fn _ | Import _ | Testing _ | Wiring _ | Service _ -> None)
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
    wirings =
      List.filter_map
        (fun (w : Parsed.wiring_def) -> Hashtbl.find_opt env.wirings w.wname.name)
        wiring_defs;
    through = env.through;
  }

(* How each link function of the module's wirings is written where its
   wiring lists it, `pg_db(url)`, by its name, for a message: its body,
   as the module writes it, or, for a link of a wiring listed inside
   another, `live$3() = core$1()`, the inner one's link, as written
   there, which [other] says for another module's. *)
let written (r : t) ~(other : Path.t -> string option) =
  let bodies = Hashtbl.create 16 in
  List.iter
    (function
      | Fn (f : Resolved.fn_def) -> Hashtbl.replace bodies f.name.name f.body
      | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> ())
    r.prog;
  let is_link (p : Path.t) =
    p.member = None && String.contains p.name '$' && checked_wiring p = None
    && service_member p = None
  in
  let rec text name =
    match Hashtbl.find_opt bodies name with
    | None -> None
    | Some (body : Resolved.expr) -> (
        match body.kind with
        | Call ({ kind = Var (Global p); _ }, _) when is_link p ->
            if p.home = r.home then text p.name else other p
        | _ -> Ast.source ~type_name:(type_name r) ~value_name:(value_name r) body)
  in
  List.concat_map
    (fun (w : Iface.wiring) ->
      List.concat_map
        (fun (wi : Iface.wired_item) ->
          List.filter_map
            (function
              | Iface.Made (f, _) ->
                  Some (f, Option.value (text f) ~default:"this")
              | Passed _ -> None)
            wi.links)
        w.witems)
    r.wirings

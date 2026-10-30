(* Interfaces: what one module tells the modules that use it (see
   iface.ml). A module is checked against the interfaces of the modules it
   imports, never their source.

   An interface holds a module's public types, with their constructors,
   fields and public members, and the type scheme of each of its public
   functions, all in canonical form (ty.ml). Nothing private is in it. It's
   made from the module's declarations, and from what inference found each
   public function needs of its type parameters ([of_module]). *)

type field = { fname : string; fty : Ty.ty }

(* One of a named error set's errors, as it's declared: a tag, with its
   payload's types, or another named set, which stands for all of its own. *)
type error = Tag of string * Ty.ty list | Set of Path.t
(* A sum type's constructor: its fields, and whether they're by name,
   [cnamed], `Rect { w: Int, h: Int }`, or else positional, one at most,
   whose name, `off` in `Flat(off: Money)`, only documents it, and is [""]
   if it isn't written (compiler.md, "Data stage", "By-name variants"). *)
type ctor = { cname : string; cfields : field list; cnamed : bool; cloc : Loc.t }

type body =
  | Builtin  (** built into the compiler, like [Int] *)
  | Record of field list
  | Sum of ctor list
  | Opaque of opaque  (** an opaque type, [type UserId = opaque Int] *)
  | Errors of error list
      (** a named error set, [type Refusal = ! Short(by: Money) | Frozen], which
          is no type of values *)
  | Dep of field list
      (** a dependency, [dep Clock = ...]: its operations, each a function type
          that fails with exactly what it's written to fail with, and uses
          nothing; a generic one's name its parameters as [Var]s *)
  | Dep_alias of Ty.dep
      (** an alias, [dep Jobs = Chan<Job>]: a dependency of its own, with the
          operations of the one it names, at those types *)

(* An opaque type's representation in its own module's view of it, or
   in its interface, hidden but for whether it has `==`: it hasn't if what
   it's represented as has a function in it. *)
and opaque = Rep of Ty.ty | Hidden of { eq : bool }

(* A member of a type (ast.ml): a method, which has `self`, an associated
   function, which doesn't, or an associated value. *)
type op_kind = Method | Function | Value

type op = {
  oname : string;  (** as it's written: [push] *)
  onum : int;
      (** its place among its type's members, counting from 0 in source order,
          which messages list them in *)
  opub : bool;
  okind : op_kind;
  oscheme : Ty.scheme;
      (** a function's type scheme, `self` its first parameter if it's a method;
          a value's type. The type's parameters are its first variables' names.
      *)
}

type type_decl = {
  path : Path.t;
  params : string list;
      (** the type parameters' names; field types refer to the [i]th as [Var i]
      *)
  body : body;
  members : op Path.Map.t;
      (** its members, each by its path (path.ml): every item in its own
          module's view of it, only the public ones in its interface *)
  numeric : Ty.ty option;
      (** for an opaque type `with numeric`, what it's represented as, `Int` or
          `Float`, which even its interface says: another module adds two and
          scales one by that (operators.md, "Number types") *)
  opaque : bool;
      (** whether it's declared `opaque`: [opaque Int], whose own module's view
          has its representation, [Opaque (Rep _)], or [opaque { ... }], a
          [Record] there. Its interface hides either, as [Opaque (Hidden _)] *)
  loc : Loc.t option;  (** where it's declared; [None] for a built-in *)
}

(* A public function, by its name. *)
type value = {
  vname : string;
  scheme : Ty.scheme;
  vparams : string list;
      (** its parameters' names, which a message about an argument passed by
          name names *)
}

(* A wiring (language.md §5), as a `with` that lists it needs it: its
   items, flattened, each a chain of links, top first, each a function of
   the wiring's module Resolve made, `live$1`, which makes the link's
   implementation from those of the wiring's parameters it's given, by
   their places, or one of its parameters, passed on (resolve.ml,
   "Wirings"). What's installed under it, and as
   what, are an item's as written; [wvia] are the wirings it came
   through inside this one, innermost first. [wwritten] is how each
   function's link is written in the wiring that lists it, `pg_db(url)`,
   for a message: the driver fills it in for an interface. *)
type link = Made of string * int list | Passed of int

type wired_item = {
  links : link list;
  wunder : Ast.tname Ast.dep_ref list;
  walias : Ast.tname Ast.dep_ref option;
  wvia : Ast.via list;
  wloc : Loc.t;  (** the item, in the wiring that lists it *)
}

type wiring = {
  wname : string;
  wpub : bool;
  wparams : string list;
  wprovides : Path.t list;
  witems : wired_item list;
  wdeclared : Loc.t;  (** its name, where it's declared *)
  wwritten : (string * string) list;
}

type t = {
  home : string;  (** the module this is the interface of *)
  types : type_decl list;  (** in the order they're declared *)
  values : value list;
  tests : value list;
      (** its test code that another module's tests can call: its public test
          items, `pub test fn`, and its public groups' tests (driver.ml). Only
          test code sees them, so `ren run` never needs them *)
  wirings : wiring list;
      (** its public wirings: their link functions are among [values], with
          the types inference found for them (driver.ml) *)
}

(* The type, or function, of that name in the interface, if it has one. *)
val find_type : t -> string -> type_decl option
val find_value : t -> string -> value option

(* The public test item of that name, or a public group's test, if the
   interface has one. *)
val find_test : t -> string -> value option

(* The public wiring of that name, if the interface has one. *)
val find_wiring : t -> string -> wiring option

(* The member of that name of a type, if it has one: the first, if it's
   an operator written for several types on its right. *)
val find_member : type_decl -> string -> op option

(* Every member of that name of a type, with its path: one for each type
   on an operator's right, and one for anything else. *)
val find_members : type_decl -> string -> (Path.t * op) list

(* The operators that are methods, by their requirement's name: `add`,
   `sub`, `mul`, `div`, `rem` and `neg`. *)
val operators : string list

(* Every requirement a type variable can have: `eq`, `hash`, `ord`, the
   operators, `zero` and `one`. *)
val requirements : string list

(* A type's `key`, if it has one: its path, and the key's type, the
   type's parameters [Var]s. *)
val key : type_decl -> (Path.t * Ty.ty) option

(* The member of a type that gives it a requirement, `add` or `zero`, if
   one does: an operator that takes one of the type and gives one, `neg`
   that takes only `self`, or a value of the type. *)
val provider : type_decl -> string -> (Path.t * op) option

(* A type's members, in source order. *)
val members : type_decl -> op list

(* The members of a type another module can call: all but a private
   `key`, which an interface carries only for `==` and order. *)
val public_members : type_decl -> op list

(* ---- named error sets ---- *)

(* Where to find each named error set's errors, as it declares them, by its
   path: [None] if the path isn't a named set. *)
type sets = Path.t -> error list option

(* The named sets among some types. *)
val sets_of : type_decl list -> sets

(* Every tag some errors stand for, in order, each with the named set it
   came through, if any: a named set stands for all of its own, and the
   sets it includes for theirs. A set is expanded once even if it's
   included twice, and never inside itself. *)
val tags : sets:sets -> error list -> (Ty.label * Path.t option) list

(* ---- dependencies ---- *)

(* The operations of a dependency at its type arguments: a generic one's,
   its [Var]s replaced by them, and an alias's, those of the one it names.
   The function finds a type's declaration. [None] if it isn't a
   dependency, or is given the wrong number of type arguments. *)
val dep_fields : (Path.t -> type_decl option) -> Ty.dep -> field list option

(* What the alias at a path names, if it's one. *)
val alias_of : (Path.t -> type_decl option) -> Path.t -> Ty.dep option

(* Whether a path is a dependency's, generic or an alias. *)
val is_dep : (Path.t -> type_decl option) -> Path.t -> bool

(* ---- from a module's declarations ---- *)

(* The labels of the dependencies a `uses` lists, sorted, each once, with
   their type arguments. [sets] says what a named error set in one stands
   for. *)
val dep_labels : ?sets:sets -> Ast.tname Ast.dep_ref list -> Ty.label list

(* The dependencies a `uses` lists, or an implementation's type joins with
   `&`, as written, with their type arguments. *)
val deps_of : sets:sets -> Ast.tname Ast.dep_ref list -> Ty.dep list

(* Just their paths. *)
val dep_paths : Ast.tname Ast.dep_ref list -> Path.t list

(* An error set as written, as declared errors: each tag with its
   payload's types, its fields' names dropped. *)
val declared_errors : sets:sets -> Ast.Resolved.errors -> error list

(* The same as a row's labels: named sets expanded, sorted, each tag once
   (the first, if one has two shapes). *)
val of_errors : sets:sets -> Ast.Resolved.errors -> Ty.label list

(* A function's type scheme from its signature alone, as inference reads
   it too. A parameter written `fn(...)`, a block, fails with what the
   function does, and uses just what its type lists; one of a dependency's
   type is transparent: its rows are the function's own. *)
val signature : ?closed:bool -> sets:sets -> Ast.Resolved.fn_def -> Ty.scheme

(* Whether the block parameters of the function at a path can't fail, as
   a spawned one can't, though their types don't say: `Async.race`'s,
   and `Async.until`'s condition.
   [signature] closes them with [closed]. *)
val closed_blocks : Path.t -> bool

(* A named function's block parameters that aren't ordinary, and its
   parameters with defaults, by their place among [ps], as a scheme keeps
   them (Ty.scheme's [modes] and [defaults]). *)
val modes_of : Ast.Resolved.param list -> (int * Ty.block_mode) list

val defaults_of : Ast.Resolved.param list -> (int * string * Ast.literal) list

(* A type declared in module [home], with all its members. *)
val of_type_def : home:string -> sets:sets -> Ast.Resolved.type_def -> type_decl

(* The dependencies a function implements, if it's a `handler`: calling
   it gives an implementation of each, of the type that lists them
   (Ty.impl). *)
val handler_deps : Ast.Resolved.fn_def -> Ty.dep list option

(* The interface of module [home], from its declarations: every public
   type, with its public members and an opaque type's representation left
   out, and every public function's signature. [sets] are the named error
   sets it can see. What a public function or member needs of its type
   parameters isn't declared, so [needs] gives what inference found, by
   its path, as its scheme's [reqs] and [row_reqs]; and [has_eq] whether
   each opaque type has `==`, which its hidden representation decides.
   A handler `over any`'s type lists what its arm fails with itself,
   which only inference knows, so [found] gives its scheme. *)
val of_module :
  home:string ->
  sets:sets ->
  needs:(Path.t -> (int * string) list * (int * string) list) ->
  has_eq:(Path.t -> bool) ->
  found:(Path.t -> Ty.scheme) ->
  Ast.Resolved.program ->
  t

(* The built-in type [a] with the members its declaration in the
   prelude's source, [b], writes: `pub type Array<T> = builtin`. *)
val join : type_decl -> type_decl -> type_decl

(* Two interfaces of the same module as one: the prelude is part Ren
   source, part built into the compiler. A type in both is [join]ed. *)
val union : t -> t -> t

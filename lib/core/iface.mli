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
type ctor = { cname : string; cfields : field list; cloc : Loc.t }

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
          nothing *)

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
  loc : Loc.t option;  (** where it's declared; [None] for a built-in *)
}

(* A public function, by its name. *)
type value = { vname : string; scheme : Ty.scheme }

type t = {
  home : string;  (** the module this is the interface of *)
  types : type_decl list;  (** in the order they're declared *)
  values : value list;
}

(* The type, or function, of that name in the interface, if it has one. *)
val find_type : t -> string -> type_decl option
val find_value : t -> string -> value option

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

(* ---- from a module's declarations ---- *)

(* The labels of the dependencies a `uses` lists, sorted, each once. *)
val dep_labels : Ast.tname list -> Ty.label list

(* The dependencies a `uses` lists, or an implementation's type joins with
   `&`, as written. *)
val dep_paths : Ast.tname list -> Path.t list

(* An error set as written, as declared errors: each tag with its
   payload's types, its fields' names dropped. *)
val declared_errors : sets:sets -> Ast.Resolved.errors -> error list

(* The same as a row's labels: named sets expanded, sorted, each tag once
   (the first, if one has two shapes). *)
val of_errors : sets:sets -> Ast.Resolved.errors -> Ty.label list

(* A function's type scheme from its signature alone, as inference reads
   it too. A parameter written `fn(...)` with no named row, or with a
   dependency's type, is transparent: its rows are the function's own. *)
val signature : sets:sets -> Ast.Resolved.fn_def -> Ty.scheme

(* A type declared in module [home], with all its members. *)
val of_type_def : home:string -> sets:sets -> Ast.Resolved.type_def -> type_decl

(* The dependencies a function implements, if it's a `handler`: calling
   it gives an implementation of each, of the type that lists them
   (Ty.impl). *)
val handler_deps : Ast.Resolved.fn_def -> Path.t list option

(* The interface of module [home], from its declarations: every public
   type, with its public members and an opaque type's representation left
   out, and every public function's signature. [sets] are the named error
   sets it can see. What a public function or member needs of its type
   parameters isn't declared, so [needs] gives what inference found, by
   its path, as its scheme's [reqs] and [row_reqs]; and [has_eq] whether
   each opaque type has `==`, which its hidden representation decides. *)
val of_module :
  home:string ->
  sets:sets ->
  needs:(Path.t -> (int * string) list * (int * string) list) ->
  has_eq:(Path.t -> bool) ->
  Ast.Resolved.program ->
  t

(* Two interfaces of the same module as one: the prelude is part Ren
   source, part built into the compiler. *)
val union : t -> t -> t

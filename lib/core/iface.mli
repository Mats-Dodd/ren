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
  | Opaque of Ty.ty option
      (** an opaque type, [type UserId = opaque Int]: [Some] representation in
          its own module's view of it, [None] in its interface *)
  | Errors of error list
      (** a named error set, [type Refusal = ! Short(by: Money) | Frozen], which
          is no type of values *)
  | Dep of field list
      (** a dependency, [dep Clock = ...]: its operations, each a function type
          that fails with exactly what it's written to fail with, and uses
          nothing *)
  | Handler of Path.t list
      (** the type of a handler of several dependencies, named after the
          `handler` declaration whose function gives one: a description of an
          implementation of each of these dependencies. Its one argument is what
          it needs (deps.md, "Implementations") *)

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

(* The member of that name of a type, if it has one. *)
val find_member : type_decl -> string -> op option

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

(* The dependencies a function implements, if it's a `handler`. *)
val handler_deps : Ast.Resolved.fn_def -> Path.t list option

(* The type calling a `handler` gives: its dependency's, if it has one,
   or its own, named after it, if it has several. [None] for any other
   function. *)
val handler_type : home:string -> Ast.Resolved.fn_def -> Path.t option

(* The type a `handler` of several dependencies declares; [None] for one
   of one dependency, or any other function. *)
val of_handler : home:string -> Ast.Resolved.fn_def -> type_decl option

(* The interface of module [home], from its declarations: every public
   type, with its public members and an opaque type's representation left
   out, and every public function's signature. [sets] are the named error
   sets it can see. What a public function or member needs of its type
   parameters isn't declared, so [needs] gives what inference found, by
   its path, as its scheme's [reqs]. *)
val of_module :
  home:string ->
  sets:sets ->
  needs:(Path.t -> (int * string) list) ->
  Ast.Resolved.program ->
  t

(* Two interfaces of the same module as one: the prelude is part Ren
   source, part built into the compiler. *)
val union : t -> t -> t

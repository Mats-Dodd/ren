(* Type inference (see infer.ml). Every type error is reported to the sink,
   and what it returns means nothing if there were any.

   [imports] are the interfaces of the modules it imports (iface.ml), the
   prelude's included, and [reachable] those of every module reachable
   through them, whose types it can meet. [entry], when
   given, is the file of the module the program starts in, which has to
   have a `main`. [tests] are the module's tests, each a function by now
   (test_items.ml): what the runtime installs around each is checked as it
   is for `main`. [bodies] are the functions whose body is a test's,
   which has to be `Unit`. *)

(* What a lookup through a type found, or what else inference decided
   about an expression or pattern that a later pass needs, so it never
   decides it again. *)
type found =
  | Field_of of Path.t  (** a field access: the record type the field is in *)
  | Ctor_of of Path.t * string
      (** a constructor, in an expression or a pattern: its type, and its name
      *)
  | Error_tag
      (** a tag inside `Err(...)`, written as a value or matched: one of the
          errors a [Result] holds, not a constructor *)
  | Method_of of Path.t
      (** a method called with a dot, at the [x.m] of [x.m(...)]: the method's
          function, [Stack.push] *)
  | Installs of Path.t
      (** a `with` whose item is an implementation of this dependency, a record
          or a handler's description *)
  | Installs_handler of Path.t list
      (** a `with` whose item describes a handler of these dependencies, all of
          which it installs *)
  | Wraps  (** a `with` whose item is a wrapper, which its body is passed to *)
  | Handles  (** a `match` that handles errors: one with `fail` arms *)
  | Fail_arm
      (** a `fail` arm's pattern, which matches an error rather than a value *)
  | Unwraps
      (** `try r`, where [r] is a [Result]: what's in it if it's `Ok`, and if
          it's `Err`, its error again *)

(* Maps keyed by node id (ast.ml). [Map.Make (Int)] is a functor: a module
   that takes a module (here [Int], which says how to compare keys) and
   returns one, a map with that kind of key. Unlike a hash table, a map's
   order is fixed by its keys. *)
module Nodes : Map.S with type key = int

(* An expression or pattern: its type, and what a lookup found there. *)
type node = {
  ty : Ty.ty;
  found : found option;
  as_dep : Path.t option;
      (** a handler of several dependencies where a value of one of their types
          is wanted: that one, which it's taken as a description of *)
  targs : Ty.args option;
      (** a use of a top-level function, a member, an associated value or an
          intrinsic: the type arguments it picked, the n-th for its scheme's
          [Var n] (Ty.args) *)
}

(* What inference found, in canonical form (ty.ml). A function's scheme and
   its nodes' types number their variables together. *)
type t = {
  schemes : Ty.scheme Path.Map.t;
      (** each function's type scheme, by its path: a member's is its type's,
          and which member it is (path.ml) *)
  values : Path.t list;
      (** the module's associated values, in the order they're made when the
          program starts: each after every value it uses *)
  nodes : node Nodes.t Path.Map.t;
      (** each function's expressions and patterns, by its path, then node id *)
  in_scope : Path.t list;
      (** the types step 2 of a lookup through a type found (infer_lookup.ml),
          sorted: the import by name of each one is used *)
}

val program :
  Diag.sink ->
  imports:Iface.t list ->
  reachable:Iface.t list ->
  ?entry:string ->
  ?tests:Test_items.test list ->
  ?bodies:string list ->
  Resolve.t ->
  t

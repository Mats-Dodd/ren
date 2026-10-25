(* Type inference (see infer.ml). Every type error is reported to the sink,
   and what it returns means nothing if there were any.

   [imports] are the interfaces of the modules it imports (iface.ml), the
   prelude's included, and [reachable] those of every module reachable
   through them, whose types it can meet. [entry], when
   given, is the file of the module the program starts in, which has to
   have a `main`. *)

(* What a lookup through a type found. *)
type found =
  | Field_of of Path.t  (** a field access: the record type the field is in *)
  | Ctor_of of Path.t * string
      (** a constructor, in an expression or a pattern: its type, and its name
      *)
  | Method_of of Path.t
      (** a method called with a dot, at the [x.m] of [x.m(...)]: the method's
          function, [Stack.push] *)

(* Maps keyed by node id (ast.ml). [Map.Make (Int)] is a functor: a module
   that takes a module (here [Int], which says how to compare keys) and
   returns one, a map with that kind of key. Unlike a hash table, a map's
   order is fixed by its keys. *)
module Nodes : Map.S with type key = int

(* An expression or pattern: its type, and what a lookup found there. *)
type node = { ty : Ty.ty; found : found option }

(* What inference found, in canonical form (ty.ml). A function's scheme and
   its nodes' types number their variables together. *)
type t = {
  schemes : (string * Ty.scheme) list;
      (** each function's type scheme, in source order *)
  values : string list;
      (** the module's associated values, in the order they're made when the
          program starts: each after every value it uses *)
  nodes : (string * node Nodes.t) list;
      (** each function's expressions and patterns, by node id *)
  in_scope : Path.t list;
      (** the types step 2 of a lookup through a type found (infer_expr.ml),
          sorted: the import by name of each one is used *)
}

val program :
  Diag.sink ->
  imports:Iface.t list ->
  reachable:Iface.t list ->
  ?entry:string ->
  Resolve.t ->
  t

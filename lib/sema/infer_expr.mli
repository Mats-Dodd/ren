(* Inferring the types of expressions (see infer_expr.ml): the core of
   it, which infer_top.ml checks each function's body with. *)

open Infer_env

(* [e]'s type, from [e] alone, recorded by its node id, as it's used: a
   sized type's value is read as its wide type. *)
val infer : env -> ctx -> Ast.Resolved.expr -> Types.ty

(* Check an expression against the type it's expected to have,
   explaining a mismatch with [why]. [written] is the type written there,
   if one is, usually the same: an implementation of several dependencies
   is narrowed to it. A sized type's value is read as its wide type, and
   one stored into a sized type that's expected, unless [exact]. *)
val check :
  env ->
  ctx ->
  ?why:Infer_report.why ->
  ?written:Types.ty ->
  ?exact:bool ->
  Ast.Resolved.expr ->
  Types.ty ->
  unit

(* A statement: a `let`'s variable gets its type, and an expression's value
   is thrown away, which is checked once the group is done (solve.ml). *)
val stmt : env -> ctx -> Ast.Resolved.stmt -> unit

(* The functions above, for Infer_handlers.handler, which a handler's body
   is checked with. *)
val core : Infer_handlers.core

(* Whether a function pins an instance of a keyed instance family for a
   block: the family's own pins, `Instances.pin`, and a dependency's
   member that runs a block given the dependency a type variable names,
   `Actors.at` (compiler.md, "Services stage", "Actors (step 7)"). *)
val pins_for_a_block : env -> Path.t -> bool

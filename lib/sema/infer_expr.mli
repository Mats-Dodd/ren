(* Inferring the types of expressions (see infer_expr.ml): the core of
   it, which infer_top.ml checks each function's body with. *)

open Infer_env

(* [e]'s type, from [e] alone, recorded by its node id. *)
val infer : env -> ctx -> Ast.Resolved.expr -> Types.ty

(* Check an expression against the type it's expected to have,
   explaining a mismatch with [why]. *)
val check :
  env -> ctx -> ?why:Infer_report.why -> Ast.Resolved.expr -> Types.ty -> unit

(* A statement: a `let`'s variable gets its type, and an expression's value
   is thrown away, which is checked once the group is done
   ([dropped_values]). *)
val stmt : env -> ctx -> Ast.Resolved.stmt -> unit

(* The functions above, for Infer_handlers.handler, which a handler's body
   is checked with. *)
val core : Infer_handlers.core

(* Check every value the group threw away is `Unit` (see [Infer_env.drop]).
   One whose type is still unknown becomes `Unit`, and is kept in the
   environment's [forced]. *)
val dropped_values : env -> unit

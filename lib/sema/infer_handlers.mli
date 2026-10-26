(* Handlers and `with` (see infer_handlers.ml; deps.md). *)

open Infer_env

(* The core of inference, from infer_expr.ml, which [handler] and [with_]
   check their parts with: passed in, since infer_expr.ml calls them, and
   two files can't each refer to the other. *)
type core = {
  infer : env -> ctx -> Ast.Resolved.expr -> Types.ty;
  check :
    env -> ctx -> ?why:Infer_report.why -> Ast.Resolved.expr -> Types.ty -> unit;
  stmt : env -> ctx -> Ast.Resolved.stmt -> unit;
  infer_call :
    env ->
    ctx ->
    ?changed:Loc.t ->
    ?tr:Types.ty ->
    Ast.Resolved.expr ->
    Ast.Resolved.expr ->
    Ast.Resolved.expr list ->
    Types.ty;
  call_with :
    env ->
    ctx ->
    Ast.Resolved.expr ->
    Ast.Resolved.expr ->
    Types.ty ->
    Ast.Resolved.expr list ->
    Types.ty;
  check_args :
    env ->
    ctx ->
    name:string option ->
    ?callee:Path.t ->
    Types.param list ->
    Ast.Resolved.expr list ->
    unit;
}

(* The type the body of a handler of these dependencies gives, the
   context's function's: the dependency's, if it implements one, or its
   own, named after it. *)
val handler_type : ctx -> Ast.tname list -> Path.t

(* The type an expression of the first type has where a value of the
   second is wanted: a handler of several dependencies, where one of
   theirs is wanted, is taken as that one, which lowering is told. *)
val taken_as :
  env -> ctx -> Ast.Resolved.expr -> Types.ty -> Types.ty -> Types.ty

(* What the parameters of a type being made, its declaration's, stand for
   where a value of the last type is wanted, as far as they're
   implementations. *)
val hint : env -> Iface.type_decl -> Types.ty list -> Types.ty -> unit

(* A handler's body: its state and its arms, which use [needs], checked
   once the group is done against what's [declared], if anything is. *)
val handler :
  core ->
  env ->
  ctx ->
  Ast.Resolved.stmt list ->
  Ast.Resolved.handler_arm list ->
  needs:Types.row ->
  declared:string list option ->
  unit

(* `with item in body`, the first expression, given its item and body and
   the node id its body's lambda is recorded at: whether it installs or
   wraps is found here, and kept for lowering. *)
val with_ :
  core ->
  env ->
  ctx ->
  Ast.Resolved.expr ->
  Ast.Resolved.expr ->
  Ast.Resolved.expr ->
  int ->
  Types.ty

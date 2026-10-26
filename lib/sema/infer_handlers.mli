(* Handlers and `with` (see infer_handlers.ml; deps.md). *)

open Infer_env

(* The core of inference, from infer_expr.ml, which [handler] and [with_]
   check their parts with: passed in, since infer_expr.ml calls them, and
   two files can't each refer to the other. *)
type core = {
  infer : env -> ctx -> Ast.Resolved.expr -> Types.ty;
  check :
    env ->
    ctx ->
    ?why:Infer_report.why ->
    ?written:Types.ty ->
    Ast.Resolved.expr ->
    Types.ty ->
    unit;
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
    written:bool list ->
    Types.param list ->
    Ast.Resolved.expr list ->
    unit;
}

(* The dependencies a handler of these implements, whose type its body
   gives (Types.impl_type). *)
val handler_deps : Ast.tname list -> Path.t list

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

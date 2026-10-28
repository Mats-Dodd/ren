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
val handler_deps : env -> ctx -> Ast.tname Ast.dep_ref list -> Types.dep list

(* The same, for a handler whose type is made where it's written: one
   `over any` ([any]) lists the dependency that stands for whichever it's
   installed over, with the tags its arm fails with as a row of its own
   (compiler.md, "`over any` and `retry`"). *)
val own_deps :
  env -> ctx -> any:bool -> Ast.tname Ast.dep_ref list -> Types.dep list

(* A handler's body, the expression given, which implements [own] (as
   [own_deps] gives them): its state, arms and `finally`, which use [needs]
   and fail with [fails], checked once the group is done against what's
   [declared], if anything is. *)
val handler :
  core ->
  env ->
  ctx ->
  Ast.Resolved.expr ->
  own:Types.dep list ->
  needs:Types.row ->
  fails:Types.row ->
  declared:Types.label list option ->
  unit

(* An inline handler, the first expression, `handler fn(...) => ...`, of
   the lambda given, where a description of the dependency given is
   wanted (foundations.md, decision 3): its type, a description that can
   need more, or [TError] once something's reported. *)
val inline_handler :
  core -> env -> ctx -> Ast.Resolved.expr -> Ast.Resolved.expr -> Types.dep ->
  Types.ty

(* `with a, b over c in body`, the first expression, given its items and
   body: what each link is, and the order they're installed in, are found
   here, and kept for lowering. *)
val with_ :
  core ->
  env ->
  ctx ->
  Ast.Resolved.expr ->
  Ast.Resolved.with_item list ->
  Ast.Resolved.expr ->
  Types.ty

(* What a function declares, checked against what its body was found to
   do once its group is solved (see infer_declared.ml): what it uses,
   what it fails with, what a handler needs, and the rows it names. *)

open Ast.Resolved
open Infer_env

(* The dependencies a function declares, sorted, or [None] if it's a
   private function that leaves them to inference. [is_value] says
   whether a function is an associated value, which uses nothing. *)
val declared_uses :
  env ->
  is_value:(fn_def -> bool) ->
  tparams:Types.ty list ->
  ?named:(string * Types.row) list ->
  fn_def ->
  Types.label list option

(* Whether a function declares what it uses: [declared_uses] isn't
   [None]. *)
val declares_uses : is_value:(fn_def -> bool) -> fn_def -> bool

(* The errors a function declares, as labels, or [None] if it's a private
   function that leaves them to inference; [tparams] are what its type
   parameters stand for. *)
val declared_errors :
  env ->
  is_value:(fn_def -> bool) ->
  tparams:Types.ty list ->
  fn_def ->
  Types.label list option

(* Whether the runtime installs a dependency around `main`. *)
val runtime_dep : Path.t -> bool

(* Why a call, which brings in a dependency, does: what [withheld] says of
   the function it calls and that dependency. *)
val withheld_notes :
  withheld list -> Types.label -> call option -> Infer_msg.withheld list

(* A function that names its own errors' row, `! ..e`, fails with it. *)
val own_errors : env -> checked -> unit

(* A function that names its own `uses` row ends it in that, and one that
   declares its errors but not a named row a closure it calls fails with is
   reported. *)
val own_rows : env -> is_value:(fn_def -> bool) -> checked -> unit

(* A function does what it declares, and a handler, among [needs], needs
   no more than it declares; [withheld] explains a message about a call
   that brings in a dependency. *)
val check_declared :
  env ->
  is_value:(fn_def -> bool) ->
  withheld:withheld list ->
  needs:handler_needs list ->
  checked ->
  unit

(* Rows and effects (see infer_rows.ml): what code fails with, `!`, and
   what it uses, `uses`, as calls, `fail`s, markers and implementations add
   to them. What a row learns only once its group is done is kept in the
   environment, for infer_top.ml to finish. *)

open Infer_env

(* What an implementation needs, copied for one place it's used, which
   [what] says (see [Infer_env.copy]). *)
val copy_needs :
  env -> loc:Loc.t -> what:Infer_msg.user -> Types.row -> Types.row

(* A type, or if it's an implementation, one that may need more than it
   does: where one that needs more is allowed, one that needs less will
   do. *)
val widen : env -> loc:Loc.t -> Types.ty -> Types.ty

(* What the code a context is in has already added to its handler, for a
   message about an error that's there, and where it came from if it's
   none of them. *)
val sources_of : ctx -> source list * Infer_msg.origin

(* Add the errors of the first row, what's new here, to the second. One
   error with two shapes is reported: [here] says where the new one comes
   from, [sources] where the old one may have, and [fix] is the help, given
   the tag. *)
val add_errors :
  env ->
  loc:Loc.t ->
  here:Infer_msg.origin ->
  sources:source list * Infer_msg.origin ->
  fix:(string -> string) ->
  Types.row ->
  Types.row ->
  unit

(* The same by inclusion (see [Infer_env.inclusion]): with the function
   given, an [add_errors] waiting for its two rows, now, and with what the
   first row learns later once the group is done. *)
val include_errors :
  env ->
  ctx ->
  loc:Loc.t ->
  (Types.row -> Types.row -> unit) ->
  Types.row ->
  Types.row ->
  unit

(* Add what a call's callee uses, or what an implementation a `with`
   installs needs ([needs]), to the dependencies of the function or lambda
   the context is in. *)
val use_row :
  env -> ctx -> loc:Loc.t -> ?needs:bool -> ?callee:Path.t -> Types.row -> unit

(* Join what's used at [loc] to what the function or lambda it's in uses,
   or say it can't use all of that. [what] says what uses it: a call, a
   `with`. *)
val join_uses :
  env -> loc:Loc.t -> what:Infer_msg.user -> Types.row -> Types.row -> unit

(* A call, [call], of [fn], named [ename] in messages: it adds the callee's
   errors, the first row, to whatever marks it, and its dependencies, the
   second, to the caller's (errors.md, "Marking"). [target] is the
   function of the group it calls, and [callee] the top-level function, if
   it's one. *)
val absorb :
  env ->
  ctx ->
  call:Ast.Resolved.expr ->
  ename:string ->
  fn:Ast.Resolved.expr ->
  ?target:Path.t ->
  ?callee:Path.t ->
  Types.row ->
  Types.row ->
  unit

(* The first [n] characters of a location, a keyword at its start. *)
val keyword : Loc.t -> int -> Loc.t

(* A new marker, kept for the checks at the end of the group. *)
val marker : env -> marker_kind -> Loc.t -> marker

(* Why a `try` of an expression of a type that isn't a [Result] may cover
   nothing, if there's something to say. *)
val try_hint :
  env -> ctx -> Ast.Resolved.expr -> Types.ty -> Infer_msg.try_hint option

(* Whether a pattern is a `fail` pattern, which matches an error, and
   whether a `match` handles errors: whether it has a `fail` arm. *)
val is_fail : Ast.Resolved.pattern -> bool
val handles : ('a, Ast.binder, Ast.tname) Ast.arm list -> bool

(* The error set of `Err(tag(payload))`, given the payload's types and
   expressions, where a value of type [expected] is wanted. *)
val err_row :
  env ->
  ctx ->
  Ast.ident ->
  (Types.ty * Ast.Resolved.expr) list ->
  expected:Types.ty ->
  Types.row

(* What the `try` of a `try match`, the marker, passes on: the errors of
   the subject, the row, that no arm handles. *)
val pass_on :
  env ->
  ctx ->
  marker ->
  Ast.Resolved.expr ->
  ('a, Ast.binder, Ast.tname) Ast.arm list ->
  Types.row ->
  unit

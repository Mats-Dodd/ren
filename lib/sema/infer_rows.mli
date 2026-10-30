(* Rows and effects (see infer_rows.ml): what code fails with, `!`, and
   what it uses, `uses`, as calls, `fail`s, markers and implementations add
   to them. What a row learns only once its group is done is left to the
   constraint solver (solve.ml). *)

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

(* The same, read when it's called, which can be once the group is done,
   without what the function says the code being checked adds itself. *)
val sources_later :
  ctx -> this:(source -> bool) -> unit -> source list * Infer_msg.origin

(* Add the errors of the first row, what's new here, to the second. One
   error with two shapes is reported: [here] says where the new one comes
   from, [sources] where the old one may have, read only then, and [fix]
   is the help, given the tag. *)
val add_errors :
  env ->
  loc:Loc.t ->
  here:Infer_msg.origin ->
  sources:(unit -> source list * Infer_msg.origin) ->
  fix:(string -> string) ->
  Types.row ->
  Types.row ->
  unit

(* Report that adding the errors of the row given to another failed, with
   the exception given (Unify), as [add_errors] does: [before] are the
   labels the other row had. *)
val add_failed :
  env ->
  loc:Loc.t ->
  here:Infer_msg.origin ->
  sources:source list * Infer_msg.origin ->
  fix:(string -> string) ->
  before:Types.label list ->
  Types.row ->
  exn ->
  unit

(* The same as [add_errors] by inclusion (see [Infer_env.inclusion]): now,
   and with what the first row learns later, once the group is done, by
   the constraint solver (solve.ml). [without] are tags it doesn't add,
   and [sources] gives the [sources] of [add_errors] when it's called. *)
val include_errors :
  env ->
  ctx ->
  loc:Loc.t ->
  here:Infer_msg.origin ->
  sources:(unit -> source list * Infer_msg.origin) ->
  fix:(string -> string) ->
  ?without:string list ->
  Types.row ->
  Types.row ->
  unit

(* A row of errors with only its labels, without the tags given. *)
val without : string list -> Types.row -> Types.row

(* Add what a call's callee uses, or what an implementation a `with`
   installs needs ([needs]), to the dependencies of the function or lambda
   the context is in. [op] is the operation called, if it's a
   dependency's. *)
val use_row :
  env ->
  ctx ->
  loc:Loc.t ->
  ?needs:bool ->
  ?callee:Path.t ->
  ?op:string ->
  ?shown:string ->
  Types.row ->
  unit

(* Join what's used at [loc] to what the function or lambda it's in uses,
   or say it can't use all of that. [what] says what uses it: a call, a
   `with`. *)
val join_uses :
  env -> loc:Loc.t -> what:Infer_msg.user -> Types.row -> Types.row -> unit

(* The calls being checked that are a chain's steps, by node, which
   [absorb] marks as one ([Infer_env.ecall]'s [estep]). *)
val chain_steps : (int, unit) Hashtbl.t

(* A call, [call], of [fn], named [ename] in messages: it adds the callee's
   errors, the first row, to whatever marks it, and its dependencies, the
   second, to the caller's (errors.md, "Marking"). [target] is the
   function of the group it calls, and [callee] the top-level function, if
   it's one. [install] says it's a link of a `with` being installed, not a
   call. *)
val absorb :
  env ->
  ctx ->
  call:Ast.Resolved.expr ->
  ename:string ->
  fn:Ast.Resolved.expr ->
  ?install:bool ->
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
   whether a `match` handles errors: whether it has a `fail` arm. Only
   inference asks: it records the answers ([Handles], [Fail_arm]), which
   later passes read. *)
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

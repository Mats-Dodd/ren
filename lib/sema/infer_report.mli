(* Reporting what inference finds wrong (see infer_report.ml): names as a
   message writes them, and a mismatch between the type some code has and
   the type it needs, explained. *)

open Infer_env

(* How the module prints types, and writes the name of the type [p]. *)
val printer : env -> Types.printer
val type_name : env -> Path.t -> string

(* A name as it's written, `Stack.push`, and without its type's name if
   it's a member, `push`. *)
val name_of : Ast.name -> string
val short_of : Ast.name -> string

(* The function a call calls: its name, if it's a function's name, for a
   message; and its own name, without a type's: `push`. *)
val callee_name : Ast.Resolved.expr -> string option
val short_callee : Ast.Resolved.expr -> string

(* Report an error. *)
val report : env -> Diag.t -> unit

(* Report an error about reaching the type's representation or fields:
   in test code, about its own module's opaque type, at the first use
   only. *)
val report_rep : env -> Iface.type_decl -> Diag.t -> unit

(* Report an error about test code reaching for one of its module's own
   items it can't see, by its path, an opaque type's or a private
   method's: at the first use only. *)
val report_test_once : env -> Path.t -> Diag.t -> unit

(* An expression's last line, which produces its value, and where it is. *)
val result_of : Ast.Resolved.expr -> Ast.Resolved.expr
val result_loc : Ast.Resolved.expr -> Loc.t

(* The variables a pattern binds, each where it's bound. *)
val binders : Ast.Resolved.pattern -> (Ast.binder * Loc.t) list

(* How to explain a mismatch with an expected type: [msg] words the error,
   [help] suggests a fix and [labels] point at other code, each given both
   types printed (the one found, then the one expected); [notes] say where
   the expectation comes from. [narrowed_help], if it's given, is the help
   where the two are an implementation of several dependencies and one of
   some of them, given that one's type, printed. [type_params] is whether a
   note says what a type parameter in either type is. It's Infer_env's,
   which a constraint can carry. *)
type why = Infer_env.why = {
  msg : (string -> string -> string) option;
  notes : string list;
  help : (string -> string -> string) option;
  narrowed_help : (string -> string) option;
  labels : string -> string -> (Loc.t * string) list;
  type_params : bool;
}

val explain :
  ?msg:(string -> string -> string) ->
  ?notes:string list ->
  ?help:(string -> string -> string) ->
  ?narrowed_help:(string -> string) ->
  ?labels:(string -> string -> (Loc.t * string) list) ->
  ?type_params:bool ->
  unit ->
  why

(* No explanation beyond the types themselves. *)
val plain : why

(* Report that [found] (what the code has) didn't unify with [expected]
   (what it needs), at the location given, explained with [why], and by
   [behind] before what's found inside the two types: the exception is how
   unifying them failed (Unify). *)
val mismatch :
  env ->
  why ->
  Loc.t ->
  ?behind:Infer_msg.behind list ->
  found:Types.ty ->
  expected:Types.ty ->
  exn ->
  unit

(* Unify [found] with [expected], and say whether that worked; if not, the
   mismatch is reported, as [mismatch] does. *)
val unifies : env -> why -> Loc.t -> found:Types.ty -> expected:Types.ty -> bool

(* The same, explained with these, whatever came of it. *)
val unify_at :
  env ->
  ?msg:(string -> string -> string) ->
  ?notes:string list ->
  ?help:string ->
  ?labels:(string -> string -> (Loc.t * string) list) ->
  Loc.t ->
  found:Types.ty ->
  expected:Types.ty ->
  unit

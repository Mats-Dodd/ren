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

(* The function a call calls, as a message names it: "`print`", or "this"
   if it's something else; and its own name, without a type's: `push`. *)
val callee_name : Ast.Resolved.expr -> string
val short_callee : Ast.Resolved.expr -> string

(* Report an error. [fail] reports one and carries on, giving the code it's
   about the type [TError]. *)
val report : env -> Diag.t -> unit

val fail :
  env ->
  ?help:string ->
  ?notes:string list ->
  ?labels:(Loc.t * string) list ->
  Loc.t ->
  string ->
  Types.ty

(* An expression's last line, which produces its value, and where it is. *)
val result_of : Ast.Resolved.expr -> Ast.Resolved.expr
val result_loc : Ast.Resolved.expr -> Loc.t

(* The variables a pattern binds, each where it's bound. *)
val binders : Ast.Resolved.pattern -> (Ast.binder * Loc.t) list

(* How to explain a mismatch with an expected type: [msg] words the error,
   [help] suggests a fix and [labels] point at other code, each given both
   types printed (the one found, then the one expected); [notes] say where
   the expectation comes from. *)
type why = {
  msg : (string -> string -> string) option;
  notes : string list;
  help : (string -> string -> string) option;
  labels : string -> string -> (Loc.t * string) list;
}

val explain :
  ?msg:(string -> string -> string) ->
  ?notes:string list ->
  ?help:(string -> string -> string) ->
  ?labels:(string -> string -> (Loc.t * string) list) ->
  unit ->
  why

(* No explanation beyond the types themselves. *)
val plain : why

(* Unify [found] (what the code has) with [expected] (what it needs), and
   say whether that worked; if not, the mismatch is reported at the
   location given, explained with [why]. *)
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

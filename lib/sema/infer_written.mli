(* Types as a module writes them, turned into the checker's types (see
   infer_written.ml). [tvars] (or [tparams]) are what the type parameters
   in scope stand for, in order, and [named] the rows the function's
   signature names, `..d`. *)

open Infer_env

(* The labels of a written error set, after `!`: each named set expanded. *)
val error_labels :
  env -> tvars:Types.ty list -> Ast.Resolved.errors -> Types.label list

(* A written type, as a checker type. [row] makes the rows of written
   function types and implementations that aren't written: fresh in a
   parameter, [closed] in a declaration or a return type. *)
val convert :
  env ->
  tvars:Types.ty list ->
  ?named:(string * Types.row) list ->
  row:(unit -> Types.row) ->
  Ast.Resolved.ty ->
  Types.ty

val closed : unit -> Types.row

(* A parameter's type: as written, or a fresh variable. [own] are the rows
   a transparent parameter of a top-level function gets, its function's
   errors and dependencies. *)
val param_type :
  env ->
  tparams:Types.ty list ->
  ?named:(string * Types.row) list ->
  ?own:Types.row * Types.row ->
  Ast.Resolved.param ->
  Types.param

(* The prelude's [Result] and [Option]. *)
val result_path : Path.t
val option_path : Path.t

(* A type declaration's type, at fresh variables for its parameters, and
   those variables. *)
val instance : env -> Iface.type_decl -> Types.ty * Types.ty list

(* A field's type, given what the type's parameters stand for. *)
val field_type : Infer_env.env -> tvars:Types.ty list -> Iface.field -> Types.ty

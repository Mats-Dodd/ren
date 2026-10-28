(* Types as a module writes them, turned into the checker's types (see
   infer_written.ml). [tvars] (or [tparams]) are what the type parameters
   in scope stand for, in order, and [named] the rows the function's
   signature names, `..d`. *)

open Infer_env

(* The labels of a written error set, after `!`: each named set expanded. *)
val error_labels :
  env -> tvars:Types.ty list -> Ast.Resolved.errors -> Types.label list

(* The dependencies a `uses` lists, or an implementation's type joins, with
   their type arguments as checker types. *)
val written_deps :
  env -> tvars:Types.ty list -> Ast.tname Ast.dep_ref list -> Types.dep list

(* The row a written `uses` lists, each dependency once, ending in the row
   it names, if it names one of [named]. *)
val written_uses :
  env ->
  tvars:Types.ty list ->
  named:(string * Types.row) list ->
  Ast.Resolved.uses ->
  Types.row

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
   errors and dependencies: a block's errors are its function's, and its
   dependencies are what its type lists. *)
val param_type :
  env ->
  tparams:Types.ty list ->
  ?named:(string * Types.row) list ->
  ?own:Types.row * Types.row ->
  Ast.Resolved.param ->
  Types.param

(* The prelude's [Result] and [Option]. *)
val result_path : Path.t

(* The prelude's `Tags` (compiler.md, "`over any` and `retry`"). *)
val tags_path : Path.t
val option_path : Path.t

(* A type declaration's type, at fresh variables for its parameters, and
   those variables. *)
val instance : env -> Iface.type_decl -> Types.ty * Types.ty list

(* A field's type, given what the type's parameters stand for. *)
val field_type : tvars:Types.ty list -> Iface.field -> Types.ty

(* Whether a parameter's or a field's type, as it was made from a
   declaration or a scheme, is written there, not a variable: looked at
   itself, not at what inference has linked it to. Only a written type
   narrows an implementation of several dependencies (Infer_expr.narrow). *)
val is_written : Types.ty -> bool

(* Which parameters of a call's callee, of the type given, have a type
   written: [callee], one of the module's functions, has to write each in
   its declaration too. [skip] are those before the ones given, a method's
   `self`. *)
val written_params :
  env ->
  ?callee:Path.t ->
  ?skip:int ->
  Types.ty ->
  Types.param list ->
  bool list

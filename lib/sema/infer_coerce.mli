(* A handler of several dependencies taken as one of them (see
   infer_coerce.ml; deps.md, "Implementations"). *)

open Infer_env

(* Whether a type is a handler of several dependencies' own. *)
val several : env -> Types.ty -> bool

(* A value of the first type, where one of the second is wanted: if it's a
   handler of several dependencies and that's one of theirs, which one,
   and the type it's taken as. *)
val as_one : env -> Types.ty -> Types.ty -> (Path.t * Types.ty) option

(* The type an expression of the first type has where a value of the
   second is wanted, which is known: a handler of several dependencies,
   where one of theirs is wanted, is taken as that one, which lowering is
   told. *)
val taken_as :
  env -> ctx -> Ast.Resolved.expr -> Types.ty -> Types.ty -> Types.ty

(* Decide a coercion the solver was left, now that what's wanted is known
   or never will be. *)
val coerce : env -> coerce -> unit

(* Give an expression of the first type where a value of the second is
   wanted, explaining a mismatch with [why]: unify them, taking a handler
   of several dependencies as one of them, once what's wanted is known. *)
val give :
  env -> ctx -> why -> Ast.Resolved.expr -> Types.ty -> Types.ty -> unit

(* Before a type is looked into: if it's a variable a handler of several
   dependencies was given to, and nothing has said what it is since,
   it's the handler's type now. *)
val settle : env -> Types.ty -> unit

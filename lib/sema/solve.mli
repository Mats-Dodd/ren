(* The constraint solver (see solve.ml, and compiler.md, "The constraint
   solver"): it decides what checking a group's bodies left to decide
   once the group is done, the environment's pending constraints
   (Infer_env.constr), and reports each that fails. *)

open Infer_env

(* Which of them to decide: the uses of the group's functions by each
   other and the values thrown away ([Equalities]), what each place an
   implementation is used needs ([Needs]), or what each error set holds,
   the rules of markers and what implementations' operations fail with
   ([Error_rows]), or which rows end in a named
   row ([Named_rows]), given the group's functions that declare what they
   use, by the variable their row ends in. Other passes still run between
   them. *)
type stage =
  | Equalities
  | Needs
  | Error_rows
  | Named_rows of (int * Ast.Resolved.fn_def) list

(* Decide every pending constraint of the stage given, and take it off
   the environment's list. [is_value] says whether a top-level function
   is an associated value, which a use joins by its result. *)
val solve : env -> is_value:(Path.t -> bool) -> stage -> unit

(* Add to each pending copy of what an implementation needs what it has
   learned since, leaving them pending: what a `with` that installs it
   finds its body needs depends on them (infer_top.ml). *)
val copies : env -> unit

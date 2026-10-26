(* The constraint solver (see solve.ml, and compiler.md, "The constraint
   solver"): it decides what checking a group's bodies left to decide
   once the group is done, the environment's pending constraints
   (Infer_env.constr), and reports each that fails. *)

open Infer_env

(* Which of them to decide: the uses of the group's functions by each
   other and the values thrown away ([Equalities]), or what each error set
   holds ([Error_rows]). Other passes still run between the two. *)
type stage = Equalities | Error_rows

(* Decide every pending constraint of the stage given, and take it off
   the environment's list. [is_value] says whether a top-level function
   is an associated value, which a use joins by its result. *)
val solve : env -> is_value:(Path.t -> bool) -> stage -> unit

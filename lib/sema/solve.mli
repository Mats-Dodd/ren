(* The constraint solver (see solve.ml, and compiler.md, "The constraint
   solver"): it decides what checking a group's bodies left to decide
   once the group is done, the environment's pending constraints
   (Infer_env.constr), and reports each that fails. *)

open Infer_env

(* Decide every pending constraint, and take them off the environment's
   list. [is_value] says whether a top-level function is an associated
   value, which a use joins by its result, and [withheld] why each
   function of an earlier group still gets a dependency from outside
   (Infer_env.withheld), which a message about a call of it explains with.
   It returns why each function of this group does, which the solver
   finds as it decides what each `with` installs. *)
val solve :
  env -> is_value:(Path.t -> bool) -> withheld:withheld list -> withheld list

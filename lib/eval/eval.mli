(* The interpreter's interface (see eval.ml). *)

(* A running program failed: division by zero, an index out of bounds. *)
exception Panic of Loc.t * string

(* Run a lowered program's `main`, returning its result. The program is
   its modules in Core, in order: the prelude, then the user's file, whose
   `main` it starts from. Raises [Panic]. *)
val run : Core.program list -> Value.t

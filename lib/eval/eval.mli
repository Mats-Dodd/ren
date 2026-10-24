(* The interpreter's interface (see eval.ml). *)

(* A running program failed: division by zero, an index out of bounds. *)
exception Panic of Loc.t * string

(* Run a checked program's `main`, returning its result. Raises [Panic]. *)
val run : Ast.program -> Value.t

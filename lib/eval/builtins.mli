(* The prelude's built-in functions, as they run (see builtins.ml); each
   one's type is prelude.ml's. *)

(* Raised by a built-in function that panics, with what to say. *)
exception Panic of string

(* Raised by a built-in function that fails, with its error. *)
exception Fail of Value.t

(* What `ren run file.ren -- args` was given after the `--`: what the
   real [Os.args] gives back. *)
val args : string list ref

(* Run the built-in function [x] on its arguments: its result, and the final value of every
   parameter, which the interpreter writes back for the arguments passed
   with `&`. `show` isn't run here: the interpreter shows a value through
   its type itself. *)
val run :
  Intrinsic.t -> dicts:Value.dict list -> Value.t list -> Value.t * Value.t list

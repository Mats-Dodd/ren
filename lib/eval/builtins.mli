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

(* ---- `ren console`'s journal ---- *)

(* What the built-ins that touch the world (the real `Clock`, `Fs`, ...)
   gave a console session's lines, in order: a session runs again from its
   first line for each new one (driver.ml), and the lines it kept are given
   back what they were given, so the world is asked only for the new
   line's. *)
type journal

val new_journal : unit -> journal

(* Run [f], one run of the session, with its journal. *)
val replaying : journal -> (unit -> 'a) -> 'a

(* Keep what the run that just ended was given: its line is kept. *)
val keep : journal -> unit

(* The prelude's built-in functions, as they run (see builtins.ml); each
   one's type is prelude.ml's. *)

(* Raised by a built-in function that panics, with what to say. *)
exception Panic of string
exception Panic_help of { msg : string; help : string }

(* Raised by a built-in function that fails, with its error. *)
exception Fail of Value.t

(* Slices (foundations.md, decision 17), each a copy, as the
   interpreter's values are: `v[from..to]`, panicking (with [Panic]) as
   every build does if the range ends before it starts, isn't in [v], or
   cuts a string's character; the halves of `v.split_at(n)`; [v] with a
   range replaced; and two halves joined. Each works on an [Array], a [Str]
   and [Bytes]. *)
val slice_value : Value.t -> int64 -> int64 -> Value.t
val split_halves : Value.t -> int64 -> Value.t * Value.t
val splice : Value.t -> int64 -> int64 -> Value.t -> Value.t
val join : Value.t -> Value.t -> Value.t

(* The test `Random`'s generator: the state after a state, and a number
   from 0 below [below] from one, panicking if [below] isn't above 0. *)
val seeded_next : int64 -> int64
val seeded_int : int64 -> int64 -> int64

(* What `ren run file.ren -- args` was given after the `--`: what the
   real [Os.args] gives back. *)
val args : string list ref

(* Run the built-in function [x] on its arguments: its result, and the final value of every
   parameter, which the interpreter writes back for the arguments passed
   with `&`. `show` isn't run here: the interpreter shows a value through
   its type itself. [tys] are what its type variables stand for, and
   [made] the tag of where it's called, for a NaN it makes (nan.ml). *)
val run :
  Intrinsic.t ->
  dicts:Value.dict list ->
  tys:Ty.ty list ->
  made:(unit -> int) ->
  Value.t list ->
  Value.t * Value.t list

(* The real `Proc.run` of [cmd] with [args], as the prelude's private
   `ProcOutcome`: found on `PATH`, started, and waited for with [wait],
   given its process, which the interpreter's scheduler does
   (Sched.wait_pid). *)
val run_program :
  wait:(int -> Unix.process_status) -> string -> string list -> Value.t

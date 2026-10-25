(* The interpreter's interface (see eval.ml). *)

(* A running program failed: division by zero, an index out of bounds. *)
exception Panic of Loc.t * string

(* `main` failed with this error, and nothing handled it: the error, shown
   through its type (shown.ml). *)
exception Uncaught of string

(* An `assert` at [loc] failed: a panic, which shows the two sides of an
   `assert a == b`, each through its type. *)
exception Assert_failed of { loc : Loc.t; sides : (string * string) option }

(* Run a lowered program's `main`, returning its result. The program is
   its modules in Core, in order: the prelude, then the user's file, whose
   `main` it starts from. Raises [Panic], or [Uncaught]. *)
val run : Core.program list -> Value.t

(* ---- tests ---- *)

(* A program's functions, and its associated values, made: what tests
   run in. Raises [Panic], or [Uncaught] if making a value fails. *)
type ctx

val load : Core.program list -> ctx

(* How a test ended. *)
type outcome =
  | Passed
  | Failed of string  (** with this error, which nothing handled, shown *)
  | Panicked of exn  (** a [Panic], or an [Assert_failed] *)

(* Run the test whose function is [fn] (test_items.ml), with a fresh
   instance of the test implementation of each built-in dependency, or
   the real one, for those named in [real] (`Clock`, `Fs`, ...); the test
   `Random` starts from [seed]. Returns how it ended, and what it wrote to
   the test `Console`. *)
val run_test :
  ctx -> fn:Path.t -> real:string list -> seed:int -> outcome * string list

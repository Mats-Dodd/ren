(* The interpreter's interface (see eval.ml). *)

(* What a panic's help suggests for an `Int` operation that overflowed:
   the wrapping method [meth] instead, `wrapping_add`, on what's at
   [recv] and what's at [arg], as the source writes them; driver.ml
   makes the help from the source, with the method's operator, `n +% 1`,
   where it has one. *)
type wrap = { meth : string; recv : Loc.t; arg : Loc.t option }

(* A running program failed: division by zero, an index out of bounds, an
   `Int` that overflowed. Its notes say more, the task it was in, if it
   isn't `main` or a test, first among them; and it can have a help of
   its own, which may name the receiver at [recv] as it's written, for
   each `\002` in it (Driver.recv_help). *)
exception Panic of {
  loc : Loc.t;
  msg : string;
  wrap : wrap option;
  notes : string list;
  help : string option;
  recv : Loc.t option;
}

(* `main` failed with this error, and nothing handled it: the error, shown
   through its type (shown.ml), and as a journal writes it (journal.ml);
   and the path of the task it came from, if it came from one. *)
exception Uncaught of { shown : string; written : string; from : string option }

(* An `assert` at [loc] failed: a panic, which shows the two sides of an
   `assert a == b`, each through its type, with what they share left out
   (shown.ml, [sides]). *)
exception Assert_failed of { loc : Loc.t; sides : (string * string) option }

(* A replay went differently from its recording, at the program's call
   [loc], as [differs] says (journal.ml). *)
exception Went_differently of { loc : Loc.t; differs : Journal.differs }

(* How `ren run` starts the program: on the real implementations of the
   built-in dependencies; recording a journal, with its recorder over
   each of them; or replaying one, with its replayer in place of them
   (handlers.md, "The journal"). *)
type start = Real | Record of Journal.t | Replay of Journal.t

(* Run a lowered program's `main`, returning its result. The program is
   its modules in Core, in order: the prelude, then the user's file, whose
   `main` it starts from, as [start] says ([Real] if it's not given).
   [trace] gets each call of an operation (`ren run --trace`). Raises
   [Panic], [Uncaught], or [Went_differently]. *)
val run : ?start:start -> ?trace:Trace.t -> Core.program list -> Value.t

(* ---- tests ---- *)

(* A program's functions, and its associated values, made: what tests
   run in. Raises [Panic], or [Uncaught] if making a value fails. *)
type ctx

val load : Core.program list -> ctx

(* How a test ended. *)
type outcome =
  | Passed
  | Failed of string  (** with this error, which nothing handled, shown *)
  | Panicked of exn
      (** a [Panic], an [Assert_failed], a replay that [Went_differently], or a
          journal's entry that can't be read ([Diag.Error]) *)

(* Run the test whose function is [fn] (test_items.ml), with a fresh
   instance of the test implementation of each built-in dependency, or
   the real one, for those named in [real] (`Clock`, `Fs`, ...); the test
   `Random` starts from [seed]. Returns how it ended, and what it wrote to
   the test `Console`. *)
val run_test :
  ?dir:string ->
  ctx ->
  fn:Path.t ->
  real:string list ->
  seed:int ->
  outcome * string list

(* Run the function [fn], of no parameters, as [run_test] runs a test: what
   it gave, or, if it didn't, how it ended; and what it wrote to the test
   `Console`. [dir] is the folder of the file [fn] is in, which a test's
   `replay(file)` finds its journal from. `ren console` runs its session
   this way (driver.ml), with its [journal], whose recorder is put over
   each built-in dependency. [record_order] also observes the scheduler
   in that journal; [root] lets the conformance runner enter an unchanged
   main as [main], while ordinary tests keep their [test] path. Neither
   option changes the installed handlers or the seed. *)
val run_installed :
  ?dir:string ->
  ?journal:Journal.t ->
  ?record_order:bool ->
  ?root:string ->
  ctx ->
  fn:Path.t ->
  real:string list ->
  seed:int ->
  (Value.t, outcome) result * string list

(* A value of the type [t], as it's written, through its type: what `ren
   console` shows of what a line gave. *)
val show : ctx -> Ty.ty -> Value.t -> string

(* The fixed build budget counts each expression dispatch exactly once,
   including expressions handled directly in tail position. *)
val build_step_limit : int
exception Build_limit of { name : string; steps : int; limit : int }

(* Compute all build roots with empty evidence and replace their bodies by
   immutable typed constants, before any native specialization. *)
val build :
  ?limit:int -> ?uses_traces:(Loc.t * string list) list ->
  Core.program list -> Core.program list

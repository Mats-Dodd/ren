(* Release builds' specialization (see specialize.ml): the program's
   modules, the prelude first and the entry last, with what `$start`
   reaches specialized, each copy in the module of what it was copied
   from. The result is Core: Core Lint checks it, and the interpreter
   runs it as it runs the program. *)

(* What it made: copies of functions, blocks lifted, `with`s whose
   handler is known, and calls past the budget, given the function as
   it's written. *)
type stats = { copies : int; blocks : int; handlers : int; over_budget : int }

(* [budget] is the most copies of one function, 64 unless it's said. *)
val program : ?budget:int -> Core.program list -> Core.program list * stats

(* Release builds' specialization (see specialize.ml): the program's
   modules, the prelude first and the entry last, with what `$start`
   reaches specialized, each copy in the module of what it was copied
   from. The result is Core: Core Lint checks it, and the interpreter
   runs it as it runs the program. *)

(* What it made: copies of functions, blocks lifted, `with`s whose
   handler is known, and calls past the size budget, given the function
   as it's written, with what each calls and where ([notes]), which a
   build reports. *)
type stats = {
  copies : int;
  blocks : int;
  handlers : int;
  past_budget : int;
  notes : (Path.t * Loc.t) list;
}

(* [budget] is how much Core, in expression nodes, the copies made may
   add up to: unless it's said, 8 times the program's own, and at least
   a million. *)
val program : ?budget:int -> Core.program list -> Core.program list * stats

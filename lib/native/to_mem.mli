(* Core to Mem IR (see to_mem.ml), for the native slice's first-order
   subset. *)

(* [what] isn't in the native slice yet, at [loc]: "a block", which the
   driver reports as an error that says to use `ren run`. *)
exception Unsupported of Loc.t * string

(* The program [modules], the prelude first and the entry last, with its
   `$start`: what `$start` reaches, in Mem IR. Raises [Unsupported] at the
   first code outside the subset. *)
val program : Core.program list -> Mem.program

(* Inlining for reuse (see inline.ml): a release build's call of a small
   function that builds, inlined where the caller would otherwise free a
   reuse token after it, after Koka's inlining of rbtree's `balance`. *)

(* The most a callee may cost, by Koka's measure. *)
val budget : int

(* The calls a program Perceus and reuse placed freed a token after,
   unused, of the size the callee builds: each caller's name and the
   call's result's id. *)
val sites : Mem.program -> (string * int) list

(* The program as to_mem.ml made it, with those calls inlined where the
   callee is small and simple enough. *)
val program : (string * int) list -> Mem.program -> Mem.program

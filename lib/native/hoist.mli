(* Hoisting (see hoist.ml): a loop's arrays made unique once before it,
   and indexed through their buffers inside it, where the exclusivity
   rule and Perceus's counts say nothing else can reach them. *)
val program : Mem.program -> Mem.program

(* Every variable a statement mentions itself, not in its blocks: what it
   reads, and what it defines or changes. *)
val mentions : Mem.stmt -> Mem.var list

(* The ids of the variables a block defines, and the labels of the
   loops, joins and catches in it. *)
val defined : Mem.block -> Set.Make(Int).t * Set.Make(Int).t

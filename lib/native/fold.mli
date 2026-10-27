(* Folding (see fold.ml): a release build's functions whose Mem is the
   same, but for their names, the numbers of structs laid out alike and
   the sites of panics that say the same, made one function, each call
   of the others a call of it. *)
val program : Mem.program -> Mem.program

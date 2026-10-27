(* Reuse (see reuse.ml): an object that dies where one as big is built,
   its memory used for the new one if it's unique, after Koka's
   ParcReuse.hs and Lean's ResetReuse.lean. *)
val program : Mem.program -> Mem.program

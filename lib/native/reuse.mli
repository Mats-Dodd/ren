(* Reuse (see reuse.ml): an object that dies where one as big is built,
   its memory used for the new one if it's unique, after Koka's
   ParcReuse.hs and Lean's ResetReuse.lean. *)
val program : Mem.program -> Mem.program

(* How many fields the object each reuse token of a function was made
   of had, by the token's id. *)
val token_sizes : Mem.fn -> (int, int) Hashtbl.t

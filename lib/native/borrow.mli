(* Borrow inference (see borrow.ml): which parameters each function
   borrows, carried in [Mem.fn.modes], after Lean's InferBorrow.lean. *)
val infer : Mem.program -> Mem.program

(* Borrow inference (see borrow.ml): which parameters each function
   borrows, carried in [Mem.fn.modes], after Lean's InferBorrow.lean. *)
val infer : Mem.program -> Mem.program

(* Whether a function's callers all know it by name, so its parameters'
   modes are inferred: not `$start`, nor a block's, a handler's or an
   associated value's code. *)
val inferred : Mem.program -> Mem.fn -> bool

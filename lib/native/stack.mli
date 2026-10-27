(* Stack promotion (see stack.ml): each object a function builds that
   never outlives the call, kept in its frame instead of on the heap,
   listed in [Mem.fn.stack]. Between Perceus's counting and reuse. *)
val program : Mem.program -> Mem.program

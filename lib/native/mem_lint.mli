(* Mem Lint (see mem_lint.ml): check that a Mem IR program's layouts
   agree, that every variable is defined before it's used, and that its
   control and its counting are well formed. Anything wrong is a bug in
   the compiler, and fails with [Failure]. *)
val program : Mem.program -> unit

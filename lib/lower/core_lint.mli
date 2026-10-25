(* Core Lint (see core_lint.ml): check that a lowered module's types fit
   together. [imports] are the interfaces the module sees. Anything wrong
   is a bug in the compiler, and fails with [Failure]. *)
val program : imports:Iface.t list -> Core.program -> unit

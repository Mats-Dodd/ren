(* Core Lint (see core_lint.ml): check that a lowered module's types fit
   together, and that its evidence is threaded (evidence.ml). [imports]
   are the interfaces the module sees, and [linked] the program's modules,
   threaded. Anything wrong is a bug in the compiler, and fails with
   [Failure]. *)
val program :
  imports:Iface.t list -> linked:Core.program list -> Core.program -> unit

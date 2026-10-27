(* Core Lint (see core_lint.ml): check that a lowered module's types fit
   together, and that its evidence is threaded. [imports] are the
   interfaces the module sees, and [linked] the program's modules.
   Anything wrong is a bug in the compiler, and fails with
   [Failure]. *)
val program :
  imports:Iface.t list -> linked:Core.program list -> Core.program -> unit

(* The audit [program] makes of the world (handlers.md, "The journal"):
   an intrinsic that reaches the world is called only by the real
   implementation of the dependency it's an operation of, and
   `journal_load` only by test code. *)
val world : Core.program -> unit

(* The check [program] makes of what a release build's specialization
   says (specialize.ml) in the function [f]: a cell parameter only in a
   function the specializer made, and a direct call of an operation, or
   of a function that knows a handler, only where the same handler is
   known. [fns] are the program's functions, by path. *)
val specialized : fns:(Path.t, Core.fn_def) Hashtbl.t -> Core.fn_def -> unit

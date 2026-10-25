(* Lowering (see lower.ml): a resolved, type-checked module, in Core. It
   reads the types and lookups inference found ([Infer.t]), and expects a
   module that passed every check. *)
val program : Resolve.t -> Infer.t -> Core.program

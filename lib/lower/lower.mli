(* Lowering (see lower.ml): a resolved, type-checked module, in Core. It
   reads the types and lookups inference found ([Infer.t]), and expects a
   module that passed every check. *)
val program : Resolve.t -> Infer.t -> Core.program

(* What the runtime runs, given the entry's `main`: a function named
   [start_name] that installs the real implementation of each built-in
   dependency `main` uses, and calls it (deps.md, "`main`"). *)
val start : Core.fn_def -> Core.fn_def
val start_name : string

(* The built-in dependencies a `main` uses, which the runtime installs
   around it. *)
val main_uses : Core.fn_def -> Path.t list

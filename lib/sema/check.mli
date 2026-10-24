(* Static checks that need no types (see check.ml): names and shapes of
   types, constructors and records, and exhaustive matches. Every problem
   is reported to the sink. *)
val program : Diag.sink -> Ast.program -> unit

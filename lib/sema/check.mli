(* Static checks that need no types (see check.ml): names and shapes of
   types, constructors and records, and exhaustive matches. Raises
   [Diag.Error] on the first problem. *)
val program : Ast.program -> unit

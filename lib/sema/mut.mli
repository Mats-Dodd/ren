(* Mutability checks (see mut.ml): what may change, and through which name.
   Raises [Diag.Error] on the first problem. *)
val program : Ast.program -> unit

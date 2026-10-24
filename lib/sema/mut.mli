(* Mutability checks (see mut.ml): what may change, and through which name.
   Every problem is reported to the sink. [imports] are the interfaces the
   module can see (iface.ml). *)
val program : Diag.sink -> imports:Iface.t list -> Ast.program -> unit

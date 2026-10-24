(* Mutability checks (see mut.ml): what may change, and through which name.
   Every problem is reported to the sink. *)
val program : Diag.sink -> Resolve.t -> unit

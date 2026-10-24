(* Static checks that need no types (see check.ml): constructors, records,
   and exhaustive matches. Every problem is reported to the sink. [imports]
   are the interfaces the module sees (iface.ml). *)
val program : Diag.sink -> imports:Iface.t list -> Resolve.t -> unit

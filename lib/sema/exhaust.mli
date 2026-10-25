(* Exhaustiveness (see exhaust.ml): every `match` handles every case, and
   has no arm that can never match. Every problem is reported to the sink.
   [imports] are the interfaces the module sees (iface.ml), and [Infer.t]
   is what inference found in it. *)
val program : Diag.sink -> imports:Iface.t list -> Resolve.t -> Infer.t -> unit

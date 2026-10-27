(* Exclusivity (see excl.ml): while a place is being changed, nothing else
   uses it, and a block never runs inside itself. Runs after inference, one
   walk per function. [reachable] are the interfaces of every module
   reachable through its imports (iface.ml), whose types say which values
   are copied, and [Infer.t] is what inference found in the module. Every
   problem is reported to the sink. *)
val program :
  Diag.sink -> reachable:Iface.t list -> Resolve.t -> Infer.t -> unit

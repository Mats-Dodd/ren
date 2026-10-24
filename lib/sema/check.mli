(* Static checks that need no types (see check.ml): names and shapes of
   types, constructors and records, and exhaustive matches. Every problem
   is reported to the sink. [home] is the module being checked, and
   [imports] the interfaces it can see (iface.ml). *)
val program :
  Diag.sink -> home:string -> imports:Iface.t list -> Ast.program -> unit

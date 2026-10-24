(* Type inference (see infer.ml). Returns each function's type scheme, in
   canonical form (ty.ml), in source order. Every type error is reported to
   the sink, and the schemes mean nothing if there were any.

   [home] is the module being checked and [imports] the interfaces it can
   see (iface.ml). [entry], when given, is the file of the module the
   program starts in, which has to have a `main`. *)
val program :
  Diag.sink ->
  home:string ->
  imports:Iface.t list ->
  ?entry:string ->
  Ast.program ->
  (string * Ty.scheme) list

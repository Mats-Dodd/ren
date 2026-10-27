(* Mem IR to one C file, the runtime in it (see emit_c.ml). [site_pieces]
   is what a panic at a site prints, in pieces, with a [Hole] where its
   message goes, which the driver renders as `ren run` would. *)
val program :
  ?restrict:bool ->
  site_pieces:(Mem.site -> Diag.piece list) ->
  Mem.program ->
  string

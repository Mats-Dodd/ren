(* Mem IR to one C file, the runtime in it (see emit_c.ml). [site_pieces]
   is what a panic at a site prints, in pieces, with a [Hole] where its
   message goes, which the driver renders as `ren run` would. [release]
   says it's a release build's, which tags no NaN (ren_rt.h, "NaN"). *)
val program :
  ?restrict:bool ->
  ?release:bool ->
  site_pieces:(Mem.site -> Diag.piece list) ->
  Mem.program ->
  string

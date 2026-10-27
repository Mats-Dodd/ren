(* Mem IR to one C file, the runtime in it (see emit_c.ml). [site_text]
   is what's printed before and after the message of a panic at a site,
   which the driver renders as `ren run` would. *)
val program :
  ?restrict:bool ->
  site_text:(Mem.site -> string * string) ->
  Mem.program ->
  string

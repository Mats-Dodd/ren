(* Mem IR to C (see emit_c.ml). [site_pieces] is what a panic at a site
   prints, in pieces, with a [Hole] where its message goes, which the
   driver renders as `ren run` would. *)

(* One C file, the runtime in it: a release build's. [release] says
   it's a release build's, which tags no NaN (ren_rt.h, "NaN"). *)
val program :
  ?restrict:bool ->
  ?release:bool ->
  site_pieces:(Mem.site -> Diag.piece list) ->
  Mem.program ->
  string

(* A debug build's C (foundations.md, decision 13): ren_rt.h, the
   runtime's unit, which includes it, and the program's units, each a
   name and its C, a few for each of the [jobs] that compile them, which
   include no system header, declare only what they use of each other,
   and say with `#line` which line of Ren each line comes from. *)
type units = {
  header : string;
  runtime : string;
  program : (string * string) list;
}

val units :
  jobs:int -> site_pieces:(Mem.site -> Diag.piece list) -> Mem.program -> units

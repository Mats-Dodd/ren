(* An .mli file is a module's interface: it lists what other modules may
   use, and everything else in lexer.ml stays private. The compiler checks
   that lexer.ml provides each of these with a matching type. *)

(* Source text to tokens, with the layout tokens (INDENT, DEDENT, NEWLINE)
   that make indentation significant. Raises [Diag.Error] on a character or
   layout Ren doesn't allow. *)
val tokenize : file:string -> string -> (Token.t * Loc.t) array

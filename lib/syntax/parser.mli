(* The parser's interface (see lexer.mli for what an .mli is). *)

(* Tokens to the syntax tree. Raises [Diag.Error] on a syntax error. *)
val parse_program : (Token.t * Loc.t) array -> Ast.program

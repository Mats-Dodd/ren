(* The parser's interface (see lexer.mli for what an .mli is). *)

(* Tokens to the syntax tree. A syntax error is reported to the sink, and
   parsing carries on at the next top-level item; the result then leaves
   out the items that had errors. *)
val parse_program : Diag.sink -> (Token.t * Loc.t) array -> Ast.program

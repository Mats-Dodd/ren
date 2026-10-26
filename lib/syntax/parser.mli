(* The parser's interface (see lexer.mli for what an .mli is). *)

(* Tokens to the syntax tree. A syntax error is reported to the sink, and
   parsing carries on at the next top-level item; the result then leaves
   out the items that had errors. With [prelude], the prelude's source is
   being parsed, which alone can declare a built-in type's members,
   `pub type Array<T> = builtin` (ast.ml, [Builtin]). *)
val parse_program :
  ?prelude:bool -> Diag.sink -> (Token.t * Loc.t) array -> Ast.Parsed.program

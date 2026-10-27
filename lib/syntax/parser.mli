(* The parser's interface (see lexer.mli for what an .mli is). *)

(* Tokens to the syntax tree. A syntax error is reported to the sink, and
   parsing carries on at the next top-level item; the result then leaves
   out the items that had errors. With [prelude], the prelude's source is
   being parsed, which alone can declare a built-in type's members,
   `pub type Array<T> = builtin` (ast.ml, [Builtin]). *)
val parse_program :
  ?prelude:bool -> Diag.sink -> (Token.t * Loc.t) array -> Ast.Parsed.program

(* One line of `ren console`: a `let`, a `var` or an expression, as a
   line of a function's body, its nodes numbered on from [node]; returns
   it, and the last node it numbered. *)
val parse_session_line :
  Diag.sink -> (Token.t * Loc.t) array -> node:int -> Ast.Parsed.stmt * int

(* `()`, at [loc], numbered after [node]. *)
val session_unit : Loc.t -> node:int -> Ast.Parsed.expr

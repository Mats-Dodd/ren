(* Tokens produced by the lexer. [@@deriving show] generates [show : t -> string]
   for debugging (used by `ren tokens`). *)

type t =
  | INT of int
  | IDENT of string
  (* keywords *)
  | FN
  | PUB
  | LET
  | VAR
  | INOUT
  | FOR
  | IN
  | IF
  | THEN
  | ELSE
  | TRUE
  | FALSE
  | TYPE
  | MATCH
  | IMPORT
  | AS
  | USES
  | OPAQUE
  | SELF
  | NOT
  | FAIL
  | TRY
  | ATTEMPT
  | ORELSE
  (* punctuation *)
  | LPAREN
  | RPAREN
  | LBRACE
  | RBRACE
  | LBRACKET
  | RBRACKET
  | COMMA
  | DOT
  | PIPE
  | FATARROW
  | COLON
  | ARROW
  | EQ
  | PLUSEQ
  | MINUSEQ
  | STAREQ
  | AMP
  | BANG
  (* operators *)
  | PLUS
  | MINUS
  | STAR
  | SLASH
  | PERCENT
  | EQEQ
  | NEQ
  | LT
  | LE
  | GT
  | GE
  | AMPAMP
  | PIPEPIPE
  (* layout: see lexer.ml *)
  | NEWLINE
  | INDENT
  | DEDENT
  | EOF
[@@deriving show { with_path = false }]

(* How a token is spelled in source, for error messages. *)
let to_string = function
  | INT n -> string_of_int n
  | IDENT s -> s
  | FN -> "fn"
  | PUB -> "pub"
  | LET -> "let"
  | VAR -> "var"
  | INOUT -> "inout"
  | FOR -> "for"
  | IN -> "in"
  | IF -> "if"
  | THEN -> "then"
  | ELSE -> "else"
  | TRUE -> "true"
  | FALSE -> "false"
  | TYPE -> "type"
  | MATCH -> "match"
  | IMPORT -> "import"
  | AS -> "as"
  | USES -> "uses"
  | OPAQUE -> "opaque"
  | SELF -> "self"
  | NOT -> "not"
  | FAIL -> "fail"
  | TRY -> "try"
  | ATTEMPT -> "attempt"
  | ORELSE -> "orelse"
  | LPAREN -> "("
  | RPAREN -> ")"
  | LBRACE -> "{"
  | RBRACE -> "}"
  | LBRACKET -> "["
  | RBRACKET -> "]"
  | DOT -> "."
  | PIPE -> "|"
  | FATARROW -> "=>"
  | COMMA -> ","
  | COLON -> ":"
  | ARROW -> "->"
  | EQ -> "="
  | PLUSEQ -> "+="
  | MINUSEQ -> "-="
  | STAREQ -> "*="
  | AMP -> "&"
  | BANG -> "!"
  | PLUS -> "+"
  | MINUS -> "-"
  | STAR -> "*"
  | SLASH -> "/"
  | PERCENT -> "%"
  | EQEQ -> "=="
  | NEQ -> "!="
  | LT -> "<"
  | LE -> "<="
  | GT -> ">"
  | GE -> ">="
  | AMPAMP -> "&&"
  | PIPEPIPE -> "||"
  | NEWLINE -> "newline"
  | INDENT -> "indent"
  | DEDENT -> "dedent"
  | EOF -> "end of file"

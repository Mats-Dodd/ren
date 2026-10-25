(* Tokens produced by the lexer. [@@deriving show] generates [show : t -> string]
   for debugging (used by `ren tokens`). *)

type t =
  | INT of int
  | STR of string  (** a string literal's contents, its escapes undone *)
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
  | DEP
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
  | WITH
  | HANDLER
  (* punctuation *)
  | LPAREN
  | RPAREN
  | LBRACE
  | RBRACE
  | LBRACKET
  | RBRACKET
  | COMMA
  | DOT
  | DOTDOT
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

(* A string as it's written, in quotes, with its escapes. *)
let show_str s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\\' -> Buffer.add_string b "\\\\"
      | '"' -> Buffer.add_string b "\\\""
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* How a token is spelled in source, for error messages. *)
let to_string = function
  | INT n -> string_of_int n
  | STR s -> show_str s
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
  | DEP -> "dep"
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
  | WITH -> "with"
  | HANDLER -> "handler"
  | LPAREN -> "("
  | RPAREN -> ")"
  | LBRACE -> "{"
  | RBRACE -> "}"
  | LBRACKET -> "["
  | RBRACKET -> "]"
  | DOT -> "."
  | DOTDOT -> ".."
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

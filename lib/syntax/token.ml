(* Tokens produced by the lexer. [@@deriving show] generates [show : t -> string]
   for debugging (used by `ren tokens`). *)

(* [s], a number as [%g] writes it, [1.5e+20] or [1e-10], with its digits
   written out instead, [150000000000000000000] or [0.0000000001]: a Ren
   literal has no exponent. *)
let without_exponent s =
  match String.index_opt s 'e' with
  | None -> s
  | Some e ->
      let mantissa = String.sub s 0 e in
      let exp =
        int_of_string (String.sub s (e + 1) (String.length s - e - 1))
      in
      let neg = mantissa.[0] = '-' in
      let mantissa =
        if neg then String.sub mantissa 1 (String.length mantissa - 1)
        else mantissa
      in
      (* the digits, and how many of them come before the point *)
      let whole, frac =
        match String.index_opt mantissa '.' with
        | Some i ->
            ( String.sub mantissa 0 i,
              String.sub mantissa (i + 1) (String.length mantissa - i - 1) )
        | None -> (mantissa, "")
      in
      let digits = whole ^ frac and point = String.length whole + exp in
      let n = String.length digits in
      let body =
        if point <= 0 then "0." ^ String.make (-point) '0' ^ digits
        else if point >= n then digits ^ String.make (point - n) '0'
        else
          String.sub digits 0 point ^ "." ^ String.sub digits point (n - point)
      in
      (if neg then "-" else "") ^ body

(* A float as it's written: the shortest form that reads back as the
   same number, as a Ren literal, with a `.` so it can't be taken for an
   `Int` and no exponent, which a literal can't have; and `inf` and
   `-inf` for the infinities. There's no `NaN` to write (operators.md,
   "`Int` and `Float`"). *)
let show_float f =
  if Float.is_integer f && Float.abs f < 1e16 then Printf.sprintf "%.1f" f
  else if f = Float.infinity then "inf"
  else if f = Float.neg_infinity then "-inf"
  else
    (* the fewest digits that read back as [f] *)
    let rec go digits =
      let s = Printf.sprintf "%.*g" digits f in
      if digits >= 17 || float_of_string s = f then s else go (digits + 1)
    in
    let s = without_exponent (go 1) in
    if String.contains s '.' then s else s ^ ".0"

type t =
  | INT of (Int64.t[@printer fun fmt n -> Format.fprintf fmt "%Ld" n])
      (** an `Int` literal: 64 bits, as an `Int` is *)
  | FLOAT of
      (float[@printer fun fmt f -> Format.pp_print_string fmt (show_float f)])
      (** a `Float` literal, [1.5] *)
  | STR of string  (** a string literal's contents, its escapes undone *)
  | STR_HEAD of string
      (** an interpolated string's text before its first hole: the hole's
          tokens come next, then a [STR_MID] or a [STR_TAIL] (lexer.ml,
          [lex_string]) *)
  | STR_MID of string  (** its text between two holes *)
  | STR_TAIL of string  (** its text after its last hole *)
  | BYTES of string
      (** a bytes literal's bytes, `b"\r\n"`'s, its escapes undone: it has
          no holes (lexer.ml, [lex_string]) *)
  | IDENT of string
  (* keywords *)
  | FN
  | YIELD
  | RETURN
  | PUB
  | LET
  | VAR
  | INOUT
  | FOR
  | WHILE
  | BREAK
  | TODO
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
  | OVER
  | FINALLY
  | TEST
  | GROUP
  | ASSERT
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
  | PLUSPERCENTEQ
  | MINUSPERCENTEQ
  | STARPERCENTEQ
  | AMP
  | BANG
  (* operators *)
  | PLUS
  | MINUS
  | STAR
  | SLASH
  | PERCENT
  | PLUSPERCENT
  | MINUSPERCENT
  | STARPERCENT
  | EQEQ
  | NEQ
  | LT
  | LE
  | GT
  | GE
  | AMPAMP
  | PIPEPIPE
  | PIPEGT  (** [|>], the pipe (language.md §8) *)
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
  | INT n -> Int64.to_string n
  | FLOAT f -> show_float f
  | STR s -> show_str s
  | STR_HEAD s ->
      let q = show_str s in
      String.sub q 0 (String.length q - 1) ^ "\\{"
  | STR_MID s ->
      let q = show_str s in
      "}" ^ String.sub q 1 (String.length q - 2) ^ "\\{"
  | STR_TAIL s ->
      let q = show_str s in
      "}" ^ String.sub q 1 (String.length q - 1)
  | BYTES s -> "b" ^ show_str s
  | IDENT s -> s
  | FN -> "fn"
  | YIELD -> "yield"
  | RETURN -> "return"
  | PUB -> "pub"
  | LET -> "let"
  | VAR -> "var"
  | INOUT -> "inout"
  | FOR -> "for"
  | WHILE -> "while"
  | BREAK -> "break"
  | TODO -> "todo"
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
  | OVER -> "over"
  | FINALLY -> "finally"
  | TEST -> "test"
  | GROUP -> "group"
  | ASSERT -> "assert"
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
  | PLUSPERCENTEQ -> "+%="
  | MINUSPERCENTEQ -> "-%="
  | STARPERCENTEQ -> "*%="
  | AMP -> "&"
  | BANG -> "!"
  | PLUS -> "+"
  | MINUS -> "-"
  | STAR -> "*"
  | SLASH -> "/"
  | PERCENT -> "%"
  | PLUSPERCENT -> "+%"
  | MINUSPERCENT -> "-%"
  | STARPERCENT -> "*%"
  | EQEQ -> "=="
  | NEQ -> "!="
  | LT -> "<"
  | LE -> "<="
  | GT -> ">"
  | GE -> ">="
  | AMPAMP -> "&&"
  | PIPEPIPE -> "||"
  | PIPEGT -> "|>"
  | NEWLINE -> "newline"
  | INDENT -> "indent"
  | DEDENT -> "dedent"
  | EOF -> "end of file"

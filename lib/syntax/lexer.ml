(* Lexer: source text -> tokens.

   Ren is indentation-sensitive, so besides ordinary tokens the lexer emits
   layout tokens, the same trick Python uses:

     INDENT   a line is indented further than the one before (a block opens)
     DEDENT   a line is indented less (one DEDENT per block that closes)
     NEWLINE  a new line at the same indentation (separates statements)

   So this:                becomes:
     fn f() =                FN f ( ) = INDENT
       let x = 1               LET x = 1 NEWLINE
       x                       x DEDENT
     fn g() = 2              NEWLINE FN g ( ) = 2 EOF

   Inside parentheses, brackets or braces, line breaks and indentation are ignored so long
   argument lists can wrap freely. Blank and comment-only lines are skipped.

   An indented line that starts with `uses` or with an error set's `!`
   continues the signature above it, so it gets no layout token at all:

     pub fn load(id: Int) -> User
         ! NotFound | Timeout
         uses Console =
       body *)

open Token

let keywords =
  [
    ("fn", FN);
    ("pub", PUB);
    ("let", LET);
    ("var", VAR);
    ("inout", INOUT);
    ("for", FOR);
    ("in", IN);
    ("if", IF);
    ("then", THEN);
    ("else", ELSE);
    ("true", TRUE);
    ("false", FALSE);
    ("type", TYPE);
    ("dep", DEP);
    ("match", MATCH);
    ("import", IMPORT);
    ("as", AS);
    ("uses", USES);
    ("opaque", OPAQUE);
    ("self", SELF);
    ("not", NOT);
    ("fail", FAIL);
    ("try", TRY);
    ("attempt", ATTEMPT);
    ("orelse", ORELSE);
    ("with", WITH);
    ("handler", HANDLER);
    ("test", TEST);
    ("group", GROUP);
    ("assert", ASSERT);
  ]

let is_digit c = c >= '0' && c <= '9'

let is_ident_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

let is_ident_char c = is_ident_start c || is_digit c

let tokenize ~file (src : string) : (Token.t * Loc.t) array =
  let len = String.length src in
  (* Mutable lexer state. [bol] is the index where the current line begins,
     so the column of index [i] is [i - bol + 1]. *)
  let i = ref 0 and line = ref 1 and bol = ref 0 in
  let depth =
    ref 0
    (* open parentheses *)
  in
  let indents =
    ref [ 0 ]
    (* stack of enclosing indentation widths *)
  in
  let at_line_start = ref true in
  let toks =
    ref []
    (* built in reverse, flipped at the end *)
  in

  let pos () = { Loc.line = !line; col = !i - !bol + 1 } in
  let peek k = if !i + k < len then src.[!i + k] else '\000' in
  let emit tok start =
    toks := (tok, { Loc.file; start; stop = pos () }) :: !toks
  in
  let error ?help start msg =
    Diag.error ?help { Loc.file; start; stop = pos () } msg
  in

  (* Called at the first token of each line (outside parentheses): compare its
     indentation with the enclosing block's and emit layout tokens. *)
  let layout () =
    let col = !i - !bol in
    let here = pos () in
    if !toks = [] then (
      if col > 0 then error here "the first line can't be indented")
    else if col > List.hd !indents then (
      indents := col :: !indents;
      emit INDENT here)
    else (
      while col < List.hd !indents do
        indents := List.tl !indents;
        emit DEDENT here
      done;
      if col <> List.hd !indents then
        error ~help:"indent it to match the lines above it" here
          "this line's indentation doesn't line up with any enclosing block";
      emit NEWLINE here)
  in

  (* Does the line starting here continue a signature: is it indented
     more than the block it's in, and does it start with the word `uses` or
     with the `!` of an error set (not `!=`)? A `!` after `=` opens a
     block instead: a named error set written one `|` per line,
     `type E =` then `! A` indented under it. *)
  let continues () =
    let starts_uses =
      !i + 4 <= len
      && String.sub src !i 4 = "uses"
      && not (is_ident_char (peek 4))
    in
    let after_eq = match !toks with (EQ, _) :: _ -> true | _ -> false in
    let starts_errors = peek 0 = '!' && peek 1 <> '=' && not after_eq in
    !i - !bol > List.hd !indents && (starts_uses || starts_errors)
  in

  (* A string literal, `"Ren\n"`: its contents, with each escape undone.
     It ends on the line it starts on; `\n` writes a line break. *)
  let lex_string start =
    incr i;
    let b = Buffer.create 16 in
    let rec go () =
      if !i >= len || peek 0 = '\n' then
        error
          ~help:"close it with `\"` on this line; write `\\n` for a line break"
          start "this string isn't closed"
      else
        match peek 0 with
        | '"' -> incr i
        | '\\' -> (
            let esc = pos () in
            incr i;
            match peek 0 with
            | ('n' | 't' | '\\' | '"') as c ->
                incr i;
                Buffer.add_char b
                  (match c with 'n' -> '\n' | 't' -> '\t' | c -> c);
                go ()
            | c ->
                if c <> '\n' && !i < len then incr i;
                error
                  ~help:
                    "the escapes are `\\n`, `\\t`, `\\\"` and `\\\\`, which \
                     writes a backslash"
                  esc
                  (if c = '\n' || !i >= len then
                     "a `\\` at the end of a line escapes nothing"
                   else Printf.sprintf "`\\%c` isn't an escape" c))
        | c ->
            Buffer.add_char b c;
            incr i;
            go ()
    in
    go ();
    (* a `Str` is always UTF-8 *)
    if not (String.is_valid_utf_8 (Buffer.contents b)) then
      error ~help:"save the file as UTF-8" start "this string isn't UTF-8";
    emit (STR (Buffer.contents b)) start
  in

  let lex_token c start =
    let advance_by n tok =
      i := !i + n;
      emit tok start
    in
    if is_digit c then (
      let s = !i in
      while is_digit (peek 0) || peek 0 = '_' do
        incr i
      done;
      (* `1_000_000` is allowed; drop the underscores before converting *)
      let text =
        String.sub src s (!i - s)
        |> String.split_on_char '_' |> String.concat ""
      in
      match int_of_string_opt text with
      | Some n -> emit (INT n) start
      | None -> error start "this number is too big to fit in an `Int`")
    else if c = '"' then lex_string start
    else if is_ident_start c then (
      let s = !i in
      while is_ident_char (peek 0) do
        incr i
      done;
      let text = String.sub src s (!i - s) in
      emit
        (Option.value (List.assoc_opt text keywords) ~default:(IDENT text))
        start)
    else
      match (c, peek 1) with
      | '-', '>' -> advance_by 2 ARROW
      | '=', '=' -> advance_by 2 EQEQ
      | '=', '>' -> advance_by 2 FATARROW
      | '!', '=' -> advance_by 2 NEQ
      | '<', '=' -> advance_by 2 LE
      | '+', '=' -> advance_by 2 PLUSEQ
      | '-', '=' -> advance_by 2 MINUSEQ
      | '*', '=' -> advance_by 2 STAREQ
      | '>', '=' -> advance_by 2 GE
      | '&', '&' -> advance_by 2 AMPAMP
      | '|', '|' -> advance_by 2 PIPEPIPE
      | '.', '.' -> advance_by 2 DOTDOT
      | '(', _ ->
          incr depth;
          advance_by 1 LPAREN
      | ')', _ ->
          depth := max 0 (!depth - 1);
          advance_by 1 RPAREN
      | '{', _ ->
          incr depth;
          advance_by 1 LBRACE
      | '}', _ ->
          depth := max 0 (!depth - 1);
          advance_by 1 RBRACE
      | '[', _ ->
          incr depth;
          advance_by 1 LBRACKET
      | ']', _ ->
          depth := max 0 (!depth - 1);
          advance_by 1 RBRACKET
      | '&', _ -> advance_by 1 AMP
      | '!', _ -> advance_by 1 BANG
      | '.', _ -> advance_by 1 DOT
      | '|', _ -> advance_by 1 PIPE
      | ',', _ -> advance_by 1 COMMA
      | ':', _ -> advance_by 1 COLON
      | '=', _ -> advance_by 1 EQ
      | '+', _ -> advance_by 1 PLUS
      | '-', _ -> advance_by 1 MINUS
      | '*', _ -> advance_by 1 STAR
      | '/', _ -> advance_by 1 SLASH
      | '%', _ -> advance_by 1 PERCENT
      | '<', _ -> advance_by 1 LT
      | '>', _ -> advance_by 1 GT
      | _ ->
          incr i;
          error start (Printf.sprintf "unexpected character `%c`" c)
  in

  while !i < len do
    let c = src.[!i] in
    let start = pos () in
    if c = '\n' then (
      incr i;
      incr line;
      bol := !i;
      at_line_start := true)
    else if c = ' ' || c = '\r' then incr i
    else if c = '\t' then (
      incr i;
      error ~help:"use spaces instead" start "tabs aren't allowed in Ren source")
    else if c = '/' && peek 1 = '/' then
      while !i < len && src.[!i] <> '\n' do
        incr i
      done
    else (
      if !at_line_start && !depth = 0 && not (continues ()) then layout ();
      at_line_start := false;
      lex_token c start)
  done;

  (* Close any blocks still open at the end of the file. *)
  let eof = pos () in
  List.iter (fun _ -> emit DEDENT eof) (List.tl !indents);
  emit EOF eof;
  Array.of_list (List.rev !toks)

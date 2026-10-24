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

   Inside parentheses, line breaks and indentation are ignored so long
   argument lists can wrap freely. Blank and comment-only lines are skipped. *)

open Token

let keywords =
  [
    ("fn", FN);
    ("pub", PUB);
    ("let", LET);
    ("if", IF);
    ("then", THEN);
    ("else", ELSE);
    ("true", TRUE);
    ("false", FALSE);
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
      | '!', '=' -> advance_by 2 NEQ
      | '<', '=' -> advance_by 2 LE
      | '>', '=' -> advance_by 2 GE
      | '(', _ ->
          incr depth;
          advance_by 1 LPAREN
      | ')', _ ->
          depth := max 0 (!depth - 1);
          advance_by 1 RPAREN
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
      if !at_line_start && !depth = 0 then layout ();
      at_line_start := false;
      lex_token c start)
  done;

  (* Close any blocks still open at the end of the file. *)
  let eof = pos () in
  List.iter (fun _ -> emit DEDENT eof) (List.tl !indents);
  emit EOF eof;
  Array.of_list (List.rev !toks)

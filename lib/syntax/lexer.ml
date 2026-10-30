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

   Inside parentheses, brackets or braces, line breaks and indentation are
   ignored so long argument lists can wrap freely, except in a lambda's
   body: a `=>` that ends a line inside brackets, followed by a line
   indented further than the block around the brackets, opens a block
   there, which ends at a line indented less, at a `,` that goes on to the
   next argument or field, or at the closing bracket:

     R { f: fn(x) =>         R { f : FN ( x ) => INDENT
           let y = x + 1           LET y = x + 1 NEWLINE
           y * 2,                  y * 2 DEDENT ,
         g: 2 }                  g : 2 }

   Blank and comment-only lines are skipped.

   An indented line that starts with `uses` or with an error set's `!`
   continues the signature above it, and one after a line that ends in
   `,` continues that line, a list of `with` items or of dependencies, so
   neither gets a layout token at all:

     pub fn load(id: Int) -> User
         ! NotFound | Timeout
         uses Console =
       with Clock.frozen(t),
           retry(3) in
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
    ("while", WHILE);
    ("break", BREAK);
    ("todo", TODO);
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
    ("over", OVER);
    ("finally", FINALLY);
    ("test", TEST);
    ("group", GROUP);
    ("assert", ASSERT);
  ]

let is_digit c = c >= '0' && c <= '9'

let is_ident_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

let is_ident_char c = is_ident_start c || is_digit c

(* What the lexer is inside, innermost first: a block, where line breaks
   are layout, or a bracket, where they're ignored. A block knows how far
   it's indented, and whether its line is in the middle of a list of
   `with` items or of dependencies, where a `,` goes on with the list.
   ([mutable] lets that field change in place.) *)
type frame = Block of block | Bracket
and block = { indent : int; mutable listing : bool }

let tokenize ~file (src : string) : (Token.t * Loc.t) array =
  let len = String.length src in
  (* Mutable lexer state. [bol] is the index where the current line begins,
     so the column of index [i] is [i - bol + 1]. *)
  let i = ref 0 and line = ref 1 and bol = ref 0 in
  let frames =
    ref [ Block { indent = 0; listing = false } ]
    (* the file is a block, indented 0 *)
  in
  (* Are line breaks layout here, outside brackets or in a lambda's block
     inside them? *)
  let in_block () = match !frames with Block _ :: _ -> true | _ -> false in
  (* How far the innermost block is indented. *)
  let current () =
    match List.find (function Block _ -> true | Bracket -> false) !frames with
    | Block b -> b.indent
    | Bracket -> 0
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
  let last_tok () = match !toks with (tok, _) :: _ -> Some tok | [] -> None in

  (* Called at the first token of each line in a block: compare its
     indentation with the enclosing block's and emit layout tokens. A line
     indented less than a lambda's block inside brackets closes it, and
     goes on inside the brackets, with no NEWLINE. *)
  let open_block col =
    frames := Block { indent = col; listing = false } :: !frames;
    emit INDENT (pos ())
  in
  let layout () =
    let col = !i - !bol in
    let here = pos () in
    if !toks = [] then (
      if col > 0 then error here "the first line can't be indented")
    else if col > current () then open_block col
    else
      let rec close () =
        match !frames with
        | Block b :: rest when col < b.indent ->
            frames := rest;
            emit DEDENT here;
            close ()
        | _ -> ()
      in
      close ();
      match !frames with
      | Block b :: _ ->
          if col <> b.indent then
            error ~help:"indent it to match the lines above it" here
              "this line's indentation doesn't line up with any enclosing block";
          b.listing <- false;
          emit NEWLINE here
      | Bracket :: _ ->
          (* back inside the brackets, the line goes on with them, so it
             starts with the `,` before the next argument or field, or with
             the closing bracket; anything else is a line of the lambda's
             body that's indented too little *)
          if not (List.mem (peek 0) [ ','; ')'; ']'; '}' ]) then
            error
              ~help:
                "indent it to match the lines above it; to end the lambda \
                 there, start the line with `,` or the closing bracket"
              here
              "this line's indentation doesn't line up with the lambda's body \
               above it"
      | [] -> ()
  in

  (* Called at the first token of each line inside brackets: after a `=>`
     that ended the line before, a line indented further than the
     innermost block opens a block, a lambda's body. *)
  let bracket_layout () =
    let col = !i - !bol in
    if last_tok () = Some FATARROW && col > current () then open_block col
  in

  (* Is the innermost block a lambda's block inside brackets, where a `,`
     that isn't in the middle of a list of `with` items or dependencies
     ends the lambda and goes on to the next argument or field? *)
  let ends_lambda () =
    match !frames with
    | Block b :: _ -> (not b.listing) && List.mem Bracket !frames
    | _ -> false
  in

  (* A closing bracket closes the lambdas' blocks still open inside it,
     then the bracket. One without an opening bracket is left to the
     parser. *)
  let close_lambdas start =
    let rec close () =
      match !frames with
      | Block _ :: rest ->
          frames := rest;
          emit DEDENT start;
          close ()
      | _ -> ()
    in
    close ()
  in
  let close_bracket start =
    if List.mem Bracket !frames then (
      close_lambdas start;
      frames := List.tl !frames)
  in

  (* Does the line starting here continue the one before: is it indented
     more than the block it's in, and does it start with the word `uses` or
     with the `!` of an error set (not `!=`), or does the line before end
     in `,`? A `!` after `=` opens a block instead: a named error set
     written one `|` per line, `type E =` then `! A` indented under it. *)
  let continues () =
    let starts_uses =
      !i + 4 <= len
      && String.sub src !i 4 = "uses"
      && not (is_ident_char (peek 4))
    in
    let after_eq = match !toks with (EQ, _) :: _ -> true | _ -> false in
    let starts_errors = peek 0 = '!' && peek 1 <> '=' && not after_eq in
    let after_comma = last_tok () = Some COMMA in
    !i - !bol > current () && (starts_uses || starts_errors || after_comma)
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

  (* A number in hex, `0x82F6_3B78`, or binary, `0b1010` (foundations.md,
     decision 15). It's a number, not a pattern of bits, so it has to fit
     an `Int` as a decimal one does: `0xFFFF_FFFF_FFFF_FFFF` is too big,
     and 2^63 is let through only for the parser to allow after a `-`, as
     a decimal one is. Its value is all that's kept: nothing after the
     lexer knows its base. *)
  let lex_based start =
    let prefix = peek 1 in
    let hex = prefix = 'x' || prefix = 'X' in
    let base, name, example =
      if hex then (16, "hex", "0xFF") else (2, "binary", "0b1010")
    in
    (* the bits a digit is *)
    let bits = if hex then 4 else 1 in
    let digit c =
      match c with
      | '0' .. '9' when Char.code c - Char.code '0' < base ->
          Some (Char.code c - Char.code '0')
      | 'a' .. 'f' when hex -> Some (Char.code c - Char.code 'a' + 10)
      | 'A' .. 'F' when hex -> Some (Char.code c - Char.code 'A' + 10)
      | _ -> None
    in
    i := !i + 2;
    if prefix = 'X' || prefix = 'B' then
      error
        ~help:(Printf.sprintf "write `%s`" example)
        start
        (Printf.sprintf "a %s number starts with `0%c`, in lower case" name
           (Char.lowercase_ascii prefix));
    if digit (peek 0) = None then
      error
        ~help:(Printf.sprintf "write its digits, `%s`" example)
        start
        (Printf.sprintf "a %s number needs a digit after `0%c`" name prefix);
    (* the value, as long as it's at most 2^63, which [Int64] holds as
       [Int64.min_int]; past that it's too big, whatever follows *)
    let n = ref 0L and too_big = ref false in
    let rec go () =
      match digit (peek 0) with
      | Some d ->
          (if !too_big then ()
           else if !n = Int64.min_int then too_big := true
           else if Int64.compare !n (Int64.shift_left 1L (63 - bits)) > 0 then
             too_big := true
           else
             (* [m] is at most 2^63, and a multiple of [base]: below 2^63,
                [m + d] is at most [Int64.max_int]; at it, only a 0 keeps
                it there *)
             let m = Int64.shift_left !n bits in
             if m <> Int64.min_int then n := Int64.add m (Int64.of_int d)
             else if d = 0 then n := m
             else too_big := true);
          incr i;
          go ()
      | None when peek 0 = '_' ->
          incr i;
          go ()
      | None -> ()
    in
    go ();
    (* a digit or letter run on into it isn't a digit of its base: `0b102` *)
    if is_ident_char (peek 0) then (
      let at = pos () in
      let bad = peek 0 in
      incr i;
      error
        ~help:
          (if hex then "a hex number is written with `0` to `9` and `a` to `f`, `0xFF`"
           else "a binary number is written with `0` and `1`, `0b1010`")
        at
        (Printf.sprintf "`%c` isn't a %s digit" bad name));
    if !too_big then
      error
        ~help:
          "the largest `Int` is `0x7FFF_FFFF_FFFF_FFFF`; for all 64 bits set, \
           write `-1`"
        start "this number is too big to fit in an `Int`";
    emit (INT !n) start
  in

  let lex_token c start =
    let advance_by n tok =
      i := !i + n;
      emit tok start
    in
    if c = '0' && List.mem (peek 1) [ 'x'; 'X'; 'b'; 'B' ] then lex_based start
    else if is_digit c then (
      let s = !i in
      while is_digit (peek 0) || peek 0 = '_' do
        incr i
      done;
      (* a `.` and a digit after it make it a `Float`, `1.5`; `1..3` is a
         range and `1.show()` a call, as before *)
      let is_float = peek 0 = '.' && is_digit (peek 1) in
      if is_float then (
        incr i;
        while is_digit (peek 0) || peek 0 = '_' do
          incr i
        done);
      (* `1_000_000` is allowed; drop the underscores before converting *)
      let text =
        String.sub src s (!i - s)
        |> String.split_on_char '_' |> String.concat ""
      in
      if is_float then
        match float_of_string_opt text with
        | Some f when Float.is_finite f -> emit (FLOAT f) start
        | _ -> error start "this number is too big for a `Float`"
      else
        match (Int64.of_string_opt text, Int64.of_string_opt ("-" ^ text)) with
        | Some n, _ -> emit (INT n) start
        (* 2^63, which fits only after a `-`: the smallest `Int`. It's
           [Int64.min_int] here, and the parser lets it through only right
           after a `-` ([Parser.too_big]) *)
        | None, Some n when n = Int64.min_int -> emit (INT n) start
        | _ -> error start "this number is too big to fit in an `Int`")
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
      (* the wrapping operators, `+%`, and their assignments, `+%=` *)
      | '+', '%' when peek 2 = '=' -> advance_by 3 PLUSPERCENTEQ
      | '-', '%' when peek 2 = '=' -> advance_by 3 MINUSPERCENTEQ
      | '*', '%' when peek 2 = '=' -> advance_by 3 STARPERCENTEQ
      | '+', '%' -> advance_by 2 PLUSPERCENT
      | '-', '%' -> advance_by 2 MINUSPERCENT
      | '*', '%' -> advance_by 2 STARPERCENT
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
          frames := Bracket :: !frames;
          advance_by 1 LPAREN
      | ')', _ ->
          close_bracket start;
          advance_by 1 RPAREN
      | '{', _ ->
          frames := Bracket :: !frames;
          advance_by 1 LBRACE
      | '}', _ ->
          close_bracket start;
          advance_by 1 RBRACE
      | '[', _ ->
          frames := Bracket :: !frames;
          advance_by 1 LBRACKET
      | ']', _ ->
          close_bracket start;
          advance_by 1 RBRACKET
      | '&', _ -> advance_by 1 AMP
      | '!', _ -> advance_by 1 BANG
      | '.', _ -> advance_by 1 DOT
      | '|', _ -> advance_by 1 PIPE
      | ',', _ ->
          (* a `,` after a lambda's block inside brackets closes it first,
             as a closing bracket does *)
          if ends_lambda () then close_lambdas start;
          advance_by 1 COMMA
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
      if !at_line_start then
        if not (in_block ()) then bracket_layout ()
        else if not (continues ()) then layout ();
      at_line_start := false;
      lex_token c start;
      (* note whether the innermost block's line is in a list of `with`
         items or dependencies: from `with` or `uses` up to the `in`, `=`
         or `=>` after it *)
      match (!frames, last_tok ()) with
      | Block b :: _, Some (WITH | USES) -> b.listing <- true
      | Block b :: _, Some (IN | EQ | FATARROW) -> b.listing <- false
      | _ -> ())
  done;

  (* Close any blocks still open at the end of the file. *)
  let eof = pos () in
  List.iter
    (function Block b when b.indent > 0 -> emit DEDENT eof | _ -> ())
    !frames;
  emit EOF eof;
  Array.of_list (List.rev !toks)

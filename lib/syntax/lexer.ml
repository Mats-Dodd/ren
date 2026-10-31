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
         body

   Nor does an indented line that starts with `|>`, a chain's next step,
   or with `.` and a name, the next stage over a cursor (language.md §8):

     order
       |> try validate
       |> try place *)

open Token

let keywords =
  [
    ("fn", FN);
    ("yield", YIELD);
    ("return", RETURN);
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
  (* this file's character literals are the ones read now *)
  Hashtbl.filter_map_inplace
    (fun (l : Loc.t) w -> if l.file = file then None else Some w)
    Ast.char_literals;
  Hashtbl.filter_map_inplace
    (fun (l : Loc.t) w -> if l.file = file then None else Some w)
    Ast.bytes_literals;
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
     written one `|` per line, `type E =` then `! A` indented under it.
     A line starting with `|>`, a chain's next step, or with `.` and a
     name, the next stage over a cursor, continues too (language.md §8,
     "Grammar and layout"): no line started with either before, so nothing
     that parsed changes. `..` and `.0` aren't a name after a `.`. *)
  let continues () =
    let starts_uses =
      !i + 4 <= len
      && String.sub src !i 4 = "uses"
      && not (is_ident_char (peek 4))
    in
    let after_eq = match !toks with (EQ, _) :: _ -> true | _ -> false in
    let starts_errors = peek 0 = '!' && peek 1 <> '=' && not after_eq in
    let after_comma = last_tok () = Some COMMA in
    let starts_step = peek 0 = '|' && peek 1 = '>' in
    let starts_stage = peek 0 = '.' && is_ident_start (peek 1) in
    !i - !bol > current ()
    && (starts_uses || starts_errors || after_comma || starts_step
      || starts_stage)
  in

  (* A string literal, `"Ren\n"`: its contents, with each escape undone
     (strings.md, "Literals"). The escapes are `\n`, `\t`, `\r`, `\0`,
     `\"`, `\\` and `\u{...}`, a code point; `\x41`, a byte, is only in a
     `b"..."`, since in a `Str` it could make invalid UTF-8. A `"..."`
     ends on the line it starts on; `\n` writes a line break.

     A hole, `"jobs/\{job}"`, holds an expression (strings.md, "Building
     strings"; compiler.md, "Bytes stage, part two", "The API"). The
     string's text before the first hole is a [STR_HEAD], the hole's
     tokens follow, then the text up to the next hole, a [STR_MID], and
     after the last, a [STR_TAIL]; a string with no hole is a [STR]. A
     hole's expression is found first, to its matching `}`, counting
     braces and skipping the strings and character literals in it, on
     the string's line, and then lexed as any code is, in brackets, so
     a string in it may have holes of its own. `\\{` is a backslash and
     a brace, and a brace alone is text. `\{x=}` is `x=\{x}`, for a name
     or a path.

     Three things change that, alone or together (compiler.md, "Bytes
     stage, part two", "Step 5b, as built"):

     - `"""`: the text starts on the line after it and ends before the
       line of the closing `"""`, whose indentation is taken off every
       line; a blank line may be shorter. A `\` at the end of a line
       joins it to the next, and a `"` is text. However many lines it
       has, it's one token, so the layout rule never sees inside it.
     - `#`s around it, `#"..."#`: it's raw. Its escape is `\` and as
       many `#`s, `\#n` and the hole `\#{x}`, so `\` alone is text, and
       it ends at a quote with as many `#`s after it.
     - `b` before it, `b"\r\n"`: a [BYTES], the UTF-8 of the text as
       written, plus a byte for each `\x`. It has no holes. *)
  (* [lex_token], below, which a hole's code is lexed with *)
  let lex_token_ref = ref (fun (_ : char) (_ : Loc.pos) -> ()) in
  (* whether [s] is a name, or names with `.` between them, `u.name` *)
  let is_path s =
    s <> ""
    && List.for_all
         (fun w -> w <> "" && is_ident_start w.[0] && String.for_all is_ident_char w)
         (String.split_on_char '.' s)
  in
  let is_hex c =
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
  in
  (* where index [k] of the line being lexed is *)
  let pos_of k = { Loc.line = !line; col = k - !bol + 1 } in
  let error_at ?help start stop msg = Diag.error ?help { Loc.file; start; stop } msg in
  (* The escapes, for a help: [lead] is how one starts, `\`, or `\#` in a
     raw string; [quote] the quote one writes. *)
  let escapes_help ~lead ~quote ~bytes ~in_char =
    let e s = "`" ^ lead ^ s ^ "`" in
    Printf.sprintf
      "the escapes%s are %s, %s, %s, %s, %s, %s, which writes a backslash, \
       and %s, a code point%s"
      (if in_char then " in a character literal" else "")
      (e "n") (e "t") (e "r") (e "0") (e (String.make 1 quote)) (e "\\")
      (e "u{E9}")
      (if bytes then Printf.sprintf ", and %s, a byte" (e "x41") else "")
  in
  (* The escape whose letter is at [!i], its `\` at [e0]: what it writes,
     added to [b]. *)
  let escape b ~lead ~quote ~bytes ~in_char e0 =
    let add ch =
      incr i;
      Buffer.add_char b ch
    in
    match peek 0 with
    | 'n' -> add '\n'
    | 't' -> add '\t'
    | 'r' -> add '\r'
    | '0' -> add '\000'
    | '\\' -> add '\\'
    | c when c = quote -> add c
    | 'u' ->
        (* a code point, `\u{E9}`: 1 to 6 hex digits, a scalar value *)
        incr i;
        let help = "a code point is written in hex, `\\u{E9}` for é, `\\u{1F600}` for 😀" in
        if peek 0 <> '{' then
          error ~help (pos_of e0) (Printf.sprintf "`%su` needs its code point in braces" lead);
        incr i;
        let d0 = !i in
        while is_hex (peek 0) do
          incr i
        done;
        let digits = String.sub src d0 (!i - d0) in
        if peek 0 <> '}' || digits = "" then (
          if peek 0 <> '\n' && !i < len then incr i;
          error ~help (pos_of e0)
            (Printf.sprintf "`%su{...}` holds a code point, 1 to 6 hex digits" lead));
        incr i;
        let written = String.sub src e0 (!i - e0) in
        let scalar =
          "a code point is `\\u{0}` to `\\u{10FFFF}`, but not `\\u{D800}` to \
           `\\u{DFFF}`, the surrogates"
        in
        if String.length digits > 6 then
          error ~help:"the last code point is `\\u{10FFFF}`" (pos_of e0)
            (Printf.sprintf "`%s` has %d hex digits; a code point has at most 6"
               written (String.length digits));
        let n = int_of_string ("0x" ^ digits) in
        if n >= 0xD800 && n <= 0xDFFF then
          error ~help:scalar (pos_of e0)
            (Printf.sprintf "`%s` is a surrogate, not a character" written);
        if n > 0x10FFFF then
          error ~help:scalar (pos_of e0)
            (Printf.sprintf "`%s` is past the last code point, `\\u{10FFFF}`" written);
        Buffer.add_utf_8_uchar b (Uchar.of_int n)
    | 'x' ->
        (* a byte, `\x0A`, two hex digits, in a `b"..."` only *)
        incr i;
        let h0 = !i in
        while !i - h0 < 2 && is_hex (peek 0) do
          incr i
        done;
        let hh = String.sub src h0 (!i - h0) in
        if not bytes then
          error
            ~help:
              (if String.length hh = 2 then
                 Printf.sprintf
                   "write the code point, `%su{%X}`; `%sx%s` writes a byte only \
                    in a `b\"...\"`"
                   lead (int_of_string ("0x" ^ hh)) lead hh
               else "write a code point as `\\u{E9}`; a byte is written `\\x41` only in a `b\"...\"`")
            (pos_of e0)
            (Printf.sprintf "`%sx%s` writes a byte, and %s" lead hh
               (if in_char then "a character literal is a code point"
                else "a `Str` is UTF-8"));
        if String.length hh < 2 then
          error ~help:"a byte is two hex digits, `\\x00` to `\\xFF`" (pos_of e0)
            (Printf.sprintf "`%sx` takes two hex digits" lead);
        Buffer.add_char b (Char.chr (int_of_string ("0x" ^ hh)))
    | c ->
        if c <> '\n' && !i < len then incr i;
        error
          ~help:(escapes_help ~lead ~quote ~bytes ~in_char)
          (pos_of e0)
          (if c = '\n' || !i >= len then
             Printf.sprintf "a `%s` at the end of a line escapes nothing" lead
           else Printf.sprintf "`%s%c` isn't an escape" lead c)
  in
  (* the string whose quote is at [!i]: [hashes] `#`s before it (and as
     many after its closing quote), [bytes] whether a `b` came first, the
     literal written from [s0], at [start] *)
  let rec lex_string ?(bytes = false) ?(hashes = 0) ?(s0 = !i) start =
    let lead = "\\" ^ String.make hashes '#' in
    let hashes_text = String.make hashes '#' in
    (* whether [hashes] `#`s start at [k] *)
    let hashes_at k =
      let rec go j = j >= hashes || (k + j < len && src.[k + j] = '#' && go (j + 1)) in
      go 0
    in
    let at_escape () = peek 0 = '\\' && hashes_at (!i + 1) in
    (* whether a closing triple quote, and its `#`s, starts at [k] *)
    let closes_multi k =
      k + 2 < len && src.[k] = '"' && src.[k + 1] = '"' && src.[k + 2] = '"'
      && hashes_at (k + 3)
    in
    let multi = peek 1 = '"' && peek 2 = '"' in
    let b = Buffer.create 16 in
    (* whether a hole has been lexed yet: the next text is a [STR_MID],
       not a [STR_HEAD] *)
    let holes = ref false in
    (* this string's text so far, checked: a `Str` is always UTF-8 *)
    let text () =
      let t = Buffer.contents b in
      if (not bytes) && not (String.is_valid_utf_8 t) then
        error ~help:"save the file as UTF-8" start "this string isn't UTF-8";
      Buffer.clear b;
      t
    in
    let newline () =
      incr i;
      incr line;
      bol := !i
    in
    (* one piece of the text at [!i], not a line break: an escape, a
       hole, or a character as it is *)
    let rec one () =
      if at_escape () then (
        let e0 = !i in
        i := !i + 1 + hashes;
        if peek 0 = '{' then (
          if bytes then (
            i := !i + 1;
            error
              ~help:
                (Printf.sprintf
                   "`Bytes` has no `show` to put into one; to write values as \
                    bytes, see formats.md. A backslash and a brace are written `%s{`"
                   (if hashes = 0 then "\\\\" else "\\"))
              (pos_of e0) "a `b\"...\"` literal has no holes");
          hole e0 (!i + 1))
        else escape b ~lead ~quote:'"' ~bytes ~in_char:false e0)
      else (
        Buffer.add_char b (peek 0);
        incr i)
    (* the hole whose `\{` is at [e0], its code starting at [from]: the
       text before it, then its tokens *)
    and hole e0 from =
      let at = pos_of e0 in
      let stop =
        match hole_end from with
        | Some k -> k
        | None ->
            i := from;
            error at "this hole has no `}`"
      in
      let inside = String.sub src from (stop - from) in
      let code = String.trim inside in
      if code = "" then (
        i := stop + 1;
        error
          ~help:"a brace is written `{`, and a backslash and a brace `\\\\{`"
          at "an empty hole: `\\{}` holds an expression");
      (* `\{x=}` is `x=\{x}`: the `=` isn't `==`'s, `!=`'s, `<=`'s or `>=`'s *)
      let n = String.length code in
      let named =
        code.[n - 1] = '='
        && (n = 1 || not (String.contains "=!<>" code.[n - 2]))
      in
      let until =
        if not named then stop
        else
          let path = String.trim (String.sub code 0 (n - 1)) in
          if not (is_path path) then (
            i := stop + 1;
            error
              ~help:"write the text before it yourself: `\"sum=\\{a + b}\"`"
              at "only a name or a path can come before `=` in a hole");
          Buffer.add_string b (path ^ "=");
          (* the hole's code ends at its `=` *)
          from + String.rindex inside '='
      in
      emit (if !holes then STR_MID (text ()) else STR_HEAD (text ())) start;
      holes := true;
      i := from;
      frames := Bracket :: !frames;
      let rec tokens () =
        while !i < until && peek 0 = ' ' do
          incr i
        done;
        if !i < until then (
          !lex_token_ref (peek 0) (pos ());
          tokens ())
      in
      tokens ();
      (* the hole's own bracket: those inside it are balanced *)
      close_bracket (pos ());
      i := stop + 1
    in
    (* `"..."`, on one line *)
    let single () =
      incr i;
      let rec go () =
        if !i >= len || peek 0 = '\n' then
          error
            ~help:
              (Printf.sprintf
                 "close it with `\"%s` on this line; write `%sn` for a line break"
                 hashes_text lead)
            start "this string isn't closed"
        else if peek 0 = '"' && hashes_at (!i + 1) then i := !i + 1 + hashes
        else (
          one ();
          go ())
      in
      go ()
    in
    (* `"""`, its lines up to the closing `"""`'s, without its indentation *)
    let mid_help () =
      Printf.sprintf
        "end the line first; to write `\"\"\"` in the text, escape a quote: `%s\"\"\"`"
        lead
    in
    let multi_line () =
      let closing =
        Printf.sprintf "close it with `\"\"\"%s` on a line of its own" hashes_text
      in
      i := !i + 3;
      while peek 0 = ' ' || peek 0 = '\r' do
        incr i
      done;
      if !i >= len then error ~help:closing start "this string isn't closed";
      if peek 0 <> '\n' then
        error ~help:"start its text on the next line" (pos ())
          "a `\"\"\"` string's text starts on the line after the `\"\"\"`";
      newline ();
      (* the closing line: where it starts, its indentation, its number *)
      let rec find j ln =
        let k = ref j in
        while !k < len && (src.[!k] = ' ' || src.[!k] = '\t') do
          incr k
        done;
        if closes_multi !k then Some (j, String.sub src j (!k - j), ln)
        else
          match String.index_from_opt src !k '\n' with
          | Some e -> find (e + 1) (ln + 1)
          | None -> None
      in
      let close_at, indent, close_line =
        match if !i < len then find !i !line else None with
        | Some c -> c
        | None -> (
            (* the mistake is a closing triple quote after text on its
               line, if there's one *)
            let rec mid k =
              if k >= len then None else if closes_multi k then Some k else mid (k + 1)
            in
            match mid !i with
            | Some k ->
                let ln = ref !line and lb = ref !bol in
                String.iteri
                  (fun j c -> if j >= !i && j < k && c = '\n' then (incr ln; lb := j + 1))
                  src;
                error_at ~help:(mid_help ())
                  { line = !ln; col = k - !lb + 1 }
                  { line = !ln; col = k - !lb + 4 + hashes }
                  "the closing `\"\"\"` goes on a line of its own"
            | None -> error ~help:closing start "this string isn't closed")
      in
      let n = String.length indent in
      let spaces_only = "indent the lines and the closing `\"\"\"` alike, with spaces" in
      if String.contains indent ' ' && String.contains indent '\t' then
        error_at ~help:spaces_only
          { line = close_line; col = 1 }
          { line = close_line; col = n + 1 }
          "the closing `\"\"\"`'s indentation mixes tabs and spaces";
      (* whether a line break, `\n` or `\r\n`, is at [k] *)
      let breaks k =
        k < len && (src.[k] = '\n' || (src.[k] = '\r' && k + 1 < len && src.[k + 1] = '\n'))
      in
      let first = ref true and joined = ref false in
      while !i < close_at do
        (* a line's start: the closing line's indentation taken off *)
        if not (!first || !joined) then Buffer.add_char b '\n';
        first := false;
        joined := false;
        let k = ref !i in
        while !k < len && (src.[!k] = ' ' || src.[!k] = '\t') do
          incr k
        done;
        let ws = !k - !i in
        if ws >= n && String.sub src !i n = indent then i := !i + n
        else if breaks !k then i := !k
        else (
          (* how far its indentation agrees with the closing line's *)
          let rec agree j =
            if j < ws && j < n && src.[!i + j] = indent.[j] then agree (j + 1) else j
          in
          let here = { Loc.line = !line; col = 1 } and stop = { Loc.line = !line; col = ws + 1 } in
          if agree 0 = ws then
            error_at
              ~help:
                (Printf.sprintf
                   "indent it at least as far as the closing `\"\"\"` on line %d, \
                    which sets the string's indentation"
                   close_line)
              here stop "this line is indented less than the closing `\"\"\"`"
          else
            error_at ~help:spaces_only here stop
              "this line's indentation mixes tabs and spaces");
        (* the line's text, to its line break *)
        let rec go () =
          match peek 0 with
          | '\n' -> newline ()
          | '\r' when peek 1 = '\n' ->
              (* `\r\n` is a line break, as `\n` is *)
              incr i;
              go ()
          | '"' when closes_multi !i ->
              let at = pos () in
              i := !i + 3 + hashes;
              error_at ~help:(mid_help ()) at (pos ())
                "the closing `\"\"\"` goes on a line of its own"
          | '\\' when at_escape () && breaks (!i + 1 + hashes) ->
              (* `\` at the end of a line joins the next to it *)
              i := !i + 1 + hashes;
              if peek 0 = '\r' then incr i;
              newline ();
              joined := true
          | _ ->
              one ();
              go ()
        in
        go ()
      done;
      i := close_at + n + 3 + hashes
    in
    if multi then multi_line () else single ();
    let t = text () in
    if bytes then (
      emit (BYTES t) start;
      Hashtbl.replace Ast.bytes_literals (snd (List.hd !toks)) (String.sub src s0 (!i - s0)))
    else emit (if !holes then STR_TAIL t else STR t) start

  (* Where the hole whose code starts at [j] ends, its `}`, if it ends on
     its line: braces counted, strings and character literals skipped. *)
  and hole_end j =
    let rec go p depth =
      if p >= len || src.[p] = '\n' then None
      else
        match src.[p] with
        | '"' -> Option.bind (string_end (p + 1)) (fun q -> go q depth)
        | '#' -> (
            (* a raw string, `#"..."#` *)
            let q = ref p in
            while !q < len && src.[!q] = '#' do
              incr q
            done;
            if !q < len && src.[!q] = '"' then
              Option.bind (raw_end (!q + 1) (!q - p)) (fun q -> go q depth)
            else go (p + 1) depth)
        | '\'' -> Option.bind (char_end (p + 1)) (fun q -> go q depth)
        | '{' -> go (p + 1) (depth + 1)
        | '}' -> if depth = 0 then Some p else go (p + 1) (depth - 1)
        | _ -> go (p + 1) depth
    in
    go j 0

  (* Just past the string whose text starts at [p], with the holes in it,
     if it ends on its line. *)
  and string_end p =
    if p >= len || src.[p] = '\n' then None
    else
      match src.[p] with
      | '"' -> Some (p + 1)
      | '\\' when p + 1 < len && src.[p + 1] = '{' ->
          Option.bind (hole_end (p + 2)) (fun k -> string_end (k + 1))
      | '\\' -> string_end (p + 2)
      | _ -> string_end (p + 1)

  (* Just past the raw string with [n] `#`s whose text starts at [p], if
     it ends on its line. *)
  and raw_end p n =
    if p >= len || src.[p] = '\n' then None
    else if src.[p] = '"' && p + n < len && String.sub src (p + 1) n = String.make n '#'
    then Some (p + 1 + n)
    else raw_end (p + 1) n

  (* Just past the character literal whose text starts at [p]. *)
  and char_end p =
    if p >= len || src.[p] = '\n' then None
    else
      match src.[p] with
      | '\'' -> Some (p + 1)
      | '\\' -> char_end (p + 2)
      | _ -> char_end (p + 1)

  (* A character literal, `'a'`: an `Int`, its code point (strings.md,
     "Characters"), with a string's escapes, `\'` writing the quote, and no `\x`.
     Whether one is stored where a byte is, as a non-ASCII one can't be,
     is the checker's, which finds it by its spelling (infer_expr.ml,
     [stored]). *)
  and lex_char start =
    let s0 = !i in
    incr i;
    let b = Buffer.create 4 in
    let rec go () =
      if !i >= len || peek 0 = '\n' then
        error ~help:"close it with `'` on this line" start
          "this character literal isn't closed"
      else
        match peek 0 with
        | '\'' -> incr i
        | '\\' ->
            let e0 = !i in
            incr i;
            escape b ~lead:"\\" ~quote:'\'' ~bytes:false ~in_char:true e0;
            go ()
        | c ->
            Buffer.add_char b c;
            incr i;
            go ()
    in
    go ();
    let t = Buffer.contents b in
    if not (String.is_valid_utf_8 t) then
      error ~help:"save the file as UTF-8" start
        "this character literal isn't UTF-8";
    (* its code points *)
    let rec points k acc =
      if k >= String.length t then List.rev acc
      else
        let d = String.get_utf_8_uchar t k in
        points (k + Uchar.utf_decode_length d) (Uchar.utf_decode_uchar d :: acc)
    in
    match points 0 [] with
    | [ u ] ->
        emit (INT (Int64.of_int (Uchar.to_int u))) start;
        Hashtbl.replace Ast.char_literals (snd (List.hd !toks)) (String.sub src s0 (!i - s0))
    | [] ->
        error ~help:"a character literal holds one code point, `'a'`" start
          "an empty character literal"
    | us ->
        error
          ~help:
            (Printf.sprintf "text is written in double quotes: `%s`"
               (Token.show_str t))
          start
          (Printf.sprintf
             "`%s` holds %d code points; a character literal holds one"
             (String.sub src s0 (!i - s0))
             (List.length us))
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
    (* `#"..."#`, a raw string; `b"..."` and `b#"..."#`, bytes *)
    else if c = '#' || (c = 'b' && (peek 1 = '"' || peek 1 = '#')) then (
      let s0 = !i in
      let bytes = c = 'b' in
      let k = ref (if bytes then 1 else 0) in
      while peek !k = '#' do
        incr k
      done;
      if peek !k = '"' then (
        let hashes = !k - if bytes then 1 else 0 in
        i := !i + !k;
        lex_string ~bytes ~hashes ~s0 start)
      else if bytes then (
        (* the name `b`, then `#` *)
        incr i;
        emit (IDENT "b") start)
      else (
        incr i;
        error ~help:"a raw string is written `#\"...\"#`" start
          "unexpected character `#`"))
    else if c = '\'' then lex_char start
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
      (* the pipe, before `|` alone, which sum types' lines, error sets
         and or-patterns look for (language.md §8) *)
      | '|', '>' -> advance_by 2 PIPEGT
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

  lex_token_ref := lex_token;
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

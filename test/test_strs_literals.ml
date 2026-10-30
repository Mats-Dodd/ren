(* The bytes stage's part two, step 5b, literals (strings.md, "Literals";
   compiler.md, "Bytes stage, part two", "Step 5b, as built"), in the
   interpreter, plain and `--release`: the escapes `\r`, `\0` and
   `\u{...}` in every string and character literal, `\x` in `b"..."`
   only, `b"..."` itself, `"""` strings with the closing `"""`'s
   indentation taken off, `#` raw strings, every form with the others,
   and the lexer's errors with their help. bench/strs/literals.ren runs
   the same literals in every native build. *)

open Helpers

(* ---- the escapes ---- *)

let%expect_test "`\\r`, `\\0` and `\\u{...}` in a string, and in a character literal" =
  run
    {|
fn main() uses Console =
  let line = "GET / HTTP/1.1\r\n"
  print(line.byte_len())
  print(line.bytes().u8(14))
  print("a\0b".byte_len())
  print("\u{48}\u{e9}\u{65E5}\u{1F600}")
  print("\u{48}\u{e9}\u{65E5}\u{1F600}".byte_len())
  print("\u{000041}" == "A")
  print(['\r', '\0', '\u{E9}', '\u{1F600}', '\u{0}'])
|};
  [%expect {|
    16
    13
    3
    Hé日😀
    10
    true
    [13, 0, 233, 128512, 0]
    ()
    |}]

let%expect_test "`b\"...\"` is the UTF-8 of its text, and a byte for each `\\x`" =
  run
    {|
fn show_bytes(b: Bytes) -> Str =
  var out = ""
  var i = 0
  while i < b.len()
    if i > 0 then out += " "
    out += show(b.u8(i))
    i += 1
  out

fn main() uses Console =
  let crlf = b"\r\n"
  print(show_bytes(crlf))
  print(show_bytes(b"\x00\x01\xFF\x7f"))
  print(show_bytes(b"é\u{E9}"))
  print(show_bytes(b"{\"a\": \\ }"))
  print(b"" == Bytes.of([]))
  print(b"ok" == "ok".bytes())
  print(crlf == Bytes.of([13, 10]))
  print(attempt Str.from_utf8(b"caf\xC3\xA9"))
  print(attempt Str.from_utf8(b"caf\xC3"))
|};
  [%expect {|
    13 10
    0 1 255 127
    195 169 195 169
    123 34 97 34 58 32 92 32 125
    true
    true
    true
    Ok("café")
    Err(InvalidUtf8(3, true))
    ()
    |}]

(* ---- multi-line strings ---- *)

let%expect_test "`\"\"\"`: the closing `\"\"\"`'s indentation comes off every line, and the text has no last line break" =
  run
    {|
fn main() uses Console =
  let name = "Ren"
  let body = """
    {
      "name": "\{name}",
      "tags": ["a", "b"]
    }
    """
  print(body)
  print(body.byte_len())
  let two = """
      deeper
    and not
    """
  print(two)
  let ended = """
    a line, and a line break after it

    """
  print(ended.byte_len())
  print("""
    """.byte_len())
|};
  [%expect {|
    {
      "name": "Ren",
      "tags": ["a", "b"]
    }
    41
      deeper
    and not
    34
    0
    ()
    |}]

let%expect_test "`\"\"\"`: a blank line may be shorter, `\\` at a line's end joins it, escapes and holes as in `\"...\"`" =
  run
    {|
fn main() uses Console =
  let n = 2
  let s = """
      one \
    two\tthree \{n * 3} \{n=}

    "quoted", ""twice"", \"""
    tail\u{21}
    """
  print(s)
  print(s.byte_len())
|};
  [%expect {|
      one two	three 6 n=2

    "quoted", ""twice"", """
    tail!
    53
    ()
    |}]

let%expect_test "`\"\"\"` is one token: the layout rule doesn't look inside it, nor at its closing line" =
  run
    {|
fn page(title: Str) -> Str =
  let s = """
<p>
  \{title}
</p>
"""
  s

fn main() uses Console =
  print(page("hi"))
  print("""
    a
    """.byte_len() + 1)
  if true then
    print("""
      inside
      """)
|};
  [%expect {|
    <p>
      hi
    </p>
    2
    inside
    ()
    |}]

(* ---- raw ---- *)

let%expect_test "`#` strings are raw: `\\#` escapes, `\\#{x}` is a hole, and more `#`s let in `\"#`" =
  run
    {|
fn main() uses Console =
  let who = "you"
  print(#"\d{3}-\d{4}"#)
  print(#"\n is two characters; \#n is a line break"#)
  print(#"a "quoted" word, ask \#{who}, \#{who=}, \{who}"#)
  print(##"it holds "# and \#{who}, but \##{who} is a hole"##)
  print(#"\#r\#0\#u{E9}\#t|\#\|\#""#.bytes() == Bytes.of([13, 0, 0xC3, 0xA9, 9, 0x7C, 0x5C, 0x7C, 0x22]))
  print(#""#.byte_len())
|};
  [%expect {|
    \d{3}-\d{4}
    \n is two characters;
     is a line break
    a "quoted" word, ask you, who=you, \{who}
    it holds "# and \#{who}, but you is a hole
    true
    0
    ()
    |}]

let%expect_test "every form together: `#\"\"\"`, `b#\"...\"#`, `b\"\"\"` and `b#\"\"\"`" =
  run
    {|
fn main() uses Console =
  let who = "Ren"
  let doc = #"""
    "\n" means newline. Ask \#{who}.
      \d+ \#t|
    """#
  print(doc)
  print(b#"\x41\#x41"#.len())
  let req = b"""
    GET / HTTP/1.1\r
    Host: example.com\r
    \r

    """
  print(req.len())
  print(req.u8(14))
  print(b#"""
    \r\#r
    """#.len())
  print(##"""
    a """# b
    """##)
|};
  [%expect {|
    "\n" means newline. Ask Ren.
      \d+ 	|
    5
    37
    13
    3
    a """# b
    ()
    |}]

(* ---- the errors ---- *)

let%expect_test "`\\x` in a `Str`, or a character literal: the help writes the `\\u{...}`" =
  check_error {|
fn main() uses Console = print("A is \x41")
|};
  check_error {|
fn main() uses Console = print("\xE9")
|};
  check_error {|
fn main() uses Console = print('\x41')
|};
  check_error {|
fn main() uses Console = print(b"\x4")
|};
  [%expect {|
    error: `\x41` writes a byte, and a `Str` is UTF-8
      ┌─ test.ren:1:38
    1 │ fn main() uses Console = print("A is \x41")
      │                                      ^^^^
      help: write the code point, `\u{41}`; `\x41` writes a byte only in a `b"..."`
    error: `\xE9` writes a byte, and a `Str` is UTF-8
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\xE9")
      │                                 ^^^^
      help: write the code point, `\u{E9}`; `\xE9` writes a byte only in a `b"..."`
    error: `\x41` writes a byte, and a character literal is a code point
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print('\x41')
      │                                 ^^^^
      help: write the code point, `\u{41}`; `\x41` writes a byte only in a `b"..."`
    error: `\x` takes two hex digits
      ┌─ test.ren:1:34
    1 │ fn main() uses Console = print(b"\x4")
      │                                  ^^^
      help: a byte is two hex digits, `\x00` to `\xFF`
    |}]

let%expect_test "a bad `\\u`: no braces, not hex, more than 6 digits, a surrogate, past 10FFFF" =
  check_error {|
fn main() uses Console = print("\uE9")
|};
  check_error {|
fn main() uses Console = print("\u{zz}")
|};
  check_error {|
fn main() uses Console = print("\u{}")
|};
  check_error {|
fn main() uses Console = print("\u{1234567}")
|};
  check_error {|
fn main() uses Console = print("\u{D800}")
|};
  check_error {|
fn main() uses Console = print('\u{DFFF}')
|};
  check_error {|
fn main() uses Console = print("\u{110000}")
|};
  [%expect {|
    error: `\u` needs its code point in braces
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\uE9")
      │                                 ^^
      help: a code point is written in hex, `\u{E9}` for é, `\u{1F600}` for 😀
    error: `\u{...}` holds a code point, 1 to 6 hex digits
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\u{zz}")
      │                                 ^^^^
      help: a code point is written in hex, `\u{E9}` for é, `\u{1F600}` for 😀
    error: `\u{...}` holds a code point, 1 to 6 hex digits
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\u{}")
      │                                 ^^^^
      help: a code point is written in hex, `\u{E9}` for é, `\u{1F600}` for 😀
    error: `\u{1234567}` has 7 hex digits; a code point has at most 6
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\u{1234567}")
      │                                 ^^^^^^^^^^^
      help: the last code point is `\u{10FFFF}`
    error: `\u{D800}` is a surrogate, not a character
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\u{D800}")
      │                                 ^^^^^^^^
      help: a code point is `\u{0}` to `\u{10FFFF}`, but not `\u{D800}` to `\u{DFFF}`, the surrogates
    error: `\u{DFFF}` is a surrogate, not a character
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print('\u{DFFF}')
      │                                 ^^^^^^^^
      help: a code point is `\u{0}` to `\u{10FFFF}`, but not `\u{D800}` to `\u{DFFF}`, the surrogates
    error: `\u{110000}` is past the last code point, `\u{10FFFF}`
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\u{110000}")
      │                                 ^^^^^^^^^^
      help: a code point is `\u{0}` to `\u{10FFFF}`, but not `\u{D800}` to `\u{DFFF}`, the surrogates
    |}]

let%expect_test "`\\{` in a `b\"...\"`: bytes have no holes, and the help points to formats.md; in a raw one it's text" =
  check_error {|
fn main() uses Console = print(b"GET \{path}")
|};
  check_error {|
fn main() uses Console = print(b#"GET \#{path}"#)
|};
  run {|
fn main() uses Console = print(b#"GET \{path}"#.len())
|};
  [%expect {|
    error: a `b"..."` literal has no holes
      ┌─ test.ren:1:38
    1 │ fn main() uses Console = print(b"GET \{path}")
      │                                      ^^
      help: `Bytes` has no `show` to put into one; to write values as bytes, see formats.md. A backslash and a brace are written `\\{`
    error: a `b"..."` literal has no holes
      ┌─ test.ren:1:39
    1 │ fn main() uses Console = print(b#"GET \#{path}"#)
      │                                       ^^^
      help: `Bytes` has no `show` to put into one; to write values as bytes, see formats.md. A backslash and a brace are written `\{`
    11
    ()
    |}]

let%expect_test "an escape a raw string doesn't have, and one that isn't closed" =
  check_error {|
fn main() uses Console = print(#"a \#q"#)
|};
  check_error {|
fn main() uses Console = print(#"a "b")
|};
  check_error {|
fn main() uses Console = print("\q")
|};
  check_error {|
fn main() uses Console = print(b"\q")
|};
  [%expect {|
    error: `\#q` isn't an escape
      ┌─ test.ren:1:36
    1 │ fn main() uses Console = print(#"a \#q"#)
      │                                    ^^^
      help: the escapes are `\#n`, `\#t`, `\#r`, `\#0`, `\#"`, `\#\`, which writes a backslash, and `\#u{E9}`, a code point
    error: this string isn't closed
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print(#"a "b")
      │                                ^^^^^^^^
      help: close it with `"#` on this line; write `\#n` for a line break
    error: `\q` isn't an escape
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\q")
      │                                 ^^
      help: the escapes are `\n`, `\t`, `\r`, `\0`, `\"`, `\\`, which writes a backslash, and `\u{E9}`, a code point
    error: `\q` isn't an escape
      ┌─ test.ren:1:34
    1 │ fn main() uses Console = print(b"\q")
      │                                  ^^
      help: the escapes are `\n`, `\t`, `\r`, `\0`, `\"`, `\\`, which writes a backslash, and `\u{E9}`, a code point, and `\x41`, a byte
    |}]

let%expect_test "a `\"\"\"` line indented less than the closing `\"\"\"`" =
  check_error
    {|
fn main() uses Console =
  print("""
      one
     two
      """)
|};
  [%expect {|
    error: this line is indented less than the closing `"""`
      ┌─ test.ren:4:1
    4 │      two
      │ ^^^^^
      help: indent it at least as far as the closing `"""` on line 5, which sets the string's indentation
    |}]

let%expect_test "a `\"\"\"` whose indentation mixes tabs and spaces" =
  check_error "fn main() uses Console =\n  print(\"\"\"\n  \tone\n \t two\n  \t\"\"\")\n";
  check_error "fn main() uses Console =\n  print(\"\"\"\n  one\n \t\"\"\")\n";
  check_error "fn main() uses Console =\n  print(\"\"\"\n\t\tone\n\t two\n\t\t\"\"\")\n";
  [%expect {|
    error: the closing `"""`'s indentation mixes tabs and spaces
      ┌─ test.ren:5:1
    5 │   	""")
      │ ^^^
      help: indent the lines and the closing `"""` alike, with spaces
    error: the closing `"""`'s indentation mixes tabs and spaces
      ┌─ test.ren:4:1
    4 │  	""")
      │ ^^
      help: indent the lines and the closing `"""` alike, with spaces
    error: this line's indentation mixes tabs and spaces
      ┌─ test.ren:4:1
    4 │ 	 two
      │ ^^
      help: indent the lines and the closing `"""` alike, with spaces
    |}]

let%expect_test "`\"\"\"`: text after the opening, a closing that isn't on its own line, one never closed" =
  check_error
    {|
fn main() uses Console =
  print("""one
    """)
|};
  check_error
    {|
fn main() uses Console =
  print("""
    one """)
|};
  check_error
    {|
fn main() uses Console =
  print("""
    one
|};
  check_error
    {|
fn main() uses Console =
  print(#"""
    one
    """)
|};
  [%expect {|
    error: a `"""` string's text starts on the line after the `"""`
      ┌─ test.ren:2:12
    2 │   print("""one
      │            ^
      help: start its text on the next line
    error: the closing `"""` goes on a line of its own
      ┌─ test.ren:3:9
    3 │     one """)
      │         ^^^
      help: end the line first; to write `"""` in the text, escape a quote: `\"""`
    error: this string isn't closed
      ┌─ test.ren:2:9
    2 │   print("""
      │         ^^^
      help: close it with `"""` on a line of its own
    error: this string isn't closed
      ┌─ test.ren:2:9
    2 │   print(#"""
      │         ^^^^
      help: close it with `"""#` on a line of its own
    |}]

let%expect_test "a `b\"...\"` is `Bytes`, not a `Str`" =
  check_error {|
fn main() uses Console = print(b"ok".byte_len())
|};
  check_error {|
fn f(s: Str) -> Int = s.byte_len()
fn main() uses Console = print(f(b"ok"))
|};
  [%expect {|
    error: `Bytes` has no method named `byte_len`
      ┌─ test.ren:1:38
    1 │ fn main() uses Console = print(b"ok".byte_len())
      │                                      ^^^^^^^^
      help: its methods: `len`, `at`, `copy`, `split_at`, `add`, `ascii_lower`, `index`, `starts_with`, `ends_with`, `split`, `trim`, `ascii_upper`, `u8`, `i8`, `u16_le`, `u16_be`, `i16_le`, `i16_be`, `u32_le`, `u32_be`, `i32_le`, `i32_be`, `u64_le`, `u64_be`, `i64_le`, `i64_be`, `set_u8`, `set_i8`, `set_u16_le`, `set_u16_be`, `set_i16_le`, `set_i16_be`, `set_u32_le`, `set_u32_be`, `set_i32_le`, `set_i32_be`, `set_u64_le`, `set_u64_be`, `set_i64_le`, `set_i64_be`, `set_varuint`, `set_varint`, `cursor`, `includes`, `strip_prefix`, `strip_suffix`, `split_once`, `lines`, `fields`, `replace`
    error: expected `Str`, found `Bytes`
      ┌─ test.ren:2:34
    2 │ fn main() uses Console = print(f(b"ok"))
      │                                  ^^^^^
    |}]

let%expect_test "an `assert` shows a `b\"...\"` and a raw string as written" =
  test
    {|
test "bytes" =
  let b = b"\r\n"
  assert b == b"\n\r"
|};
  [%expect {|
    test.ren
      ✗ bytes

    ──── bytes ── test.ren:3
      │
    3 │   assert b == b"\n\r"
      │          ^^^^^^^^^^^^
      │
      left:  <bytes 0d 0a>
      right: <bytes 0a 0d>
                     ^ differs here

      seed 1940 · rerun: ren test test.ren --only "bytes" --seed 1940

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "the tokens: one for each literal, whatever its form" =
  tokens
    {|
fn f() = (b"\r\n", #"\d"#, """
  two
  lines
  """, '\u{E9}')
|};
  [%expect {| FN (IDENT "f") LPAREN RPAREN EQ LPAREN (BYTES "\r\n") COMMA (STR "\\d") COMMA (STR "two\nlines") COMMA (INT 233) RPAREN EOF |}]

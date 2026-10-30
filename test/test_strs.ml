(* The bytes stage's part two in the interpreter (compiler.md, "Bytes
   stage, part two", "The tests"): what bench/strs.t's programs don't say,
   the whole of each error with its help, each panic with its help line,
   and `InvalidUtf8`'s payload.

     s1  the boundary: `InvalidUtf8(at, incomplete)`, `from_utf8_lossy`
     s2  strings.md's API, the parts that are code, and interpolation
     s5  the rest of strings.md's API table, and `count()`

   Steps 3 and 4, appending in place and representation B, change
   nothing `ren run` prints: their tests are bench/strs.t's, which
   counts what native builds allocate and runs the `+=` report.

   A test still to land runs through [until] (helpers.ml), as
   test_bytes.ml's do: [want] is the whole output of a program that runs,
   [says] the lines an error or a panic has to hold, its headline and its
   help. Its [%expect] holds today's output after `(until sN)`. When the
   program prints what's wanted, the test fails until the step turns it
   on: written plainly, with the target in its [%expect]. A test whose
   program works already is written plainly, and holds what the stage
   mustn't change. *)

open Helpers

(* ---- s1: the boundary ---- *)

let%expect_test "[s1] `InvalidUtf8` says where the bytes went wrong, and whether the end cut a character" =
  run
    {|
fn main() uses Console =
  print(attempt Str.from_utf8(Bytes.of([0x61, 0xC0, 0x80])))
  print(attempt Str.from_utf8(Bytes.of([0x61, 0xF0, 0x9F, 0x98])))
  print(attempt Str.from_utf8(Bytes.of([0x61, 0xF0, 0x9F, 0x98, 0x61])))
  print(attempt Str.from_utf8(Bytes.of([0x6F, 0x6B])))
|};
  [%expect {|
    Err(InvalidUtf8(1, false))
    Err(InvalidUtf8(1, true))
    Err(InvalidUtf8(1, false))
    Ok("ok")
    ()
    |}]

let%expect_test "[s1] a decoder working chunk by chunk tells invalid from not finished, by the payload" =
  run
    {|
fn feed(b: Bytes) uses Console =
  match attempt Str.from_utf8(b)
    Ok(s) => print(s)
    Err(InvalidUtf8(at, incomplete)) =>
      if incomplete then
        let s = attempt Str.from_utf8(b[0..at])
        match s
          Ok(t) => print("\{t} then \{b.len() - at} bytes kept")
          Err(_) => print("?")
      else print("invalid at \{at}")

fn main() uses Console =
  feed(Bytes.of([0xE6, 0x97, 0xA5, 0xE6, 0x9C, 0xAC, 0xE8]))
  feed(Bytes.of([0x61, 0x62, 0xFF]))
|};
  [%expect {|
    日本 then 1 bytes kept
    invalid at 2
    ()
    |}]

let%expect_test "[s1] `from_utf8_lossy` writes one U+FFFD for each maximal invalid subpart, and keeps a byte order mark" =
  run
    {|
fn main() uses Console =
  print(Str.from_utf8_lossy(Bytes.of([0x61, 0xE2, 0x82, 0x62])))
  print(Str.from_utf8_lossy(Bytes.of([0x61, 0xED, 0xA0, 0x80, 0x62])))
  print(Str.from_utf8_lossy(Bytes.of([0x61, 0xF0, 0x9F, 0x98])))
  print(Str.from_utf8_lossy(Bytes.of([0xFF])))
  print(Str.from_utf8_lossy(Bytes.of([0xEF, 0xBB, 0xBF])).byte_len())
|};
  [%expect {|
    a�b
    a���b
    a�
    �
    3
    ()
    |}]

(* ---- s2: the API, and interpolation ---- *)

let%expect_test "[s2] `len` on a `Str` asks which unit" =
  check_error
        {|
fn short(name: Str) -> Bool = name.len() <= 20
fn main() = ()
|};
  [%expect {|
    error: `Str` has no `len`: bytes, or characters?
      ┌─ test.ren:1:36
    1 │ fn short(name: Str) -> Bool = name.len() <= 20
      │                                    ^^^
      help: bytes: `name.byte_len()`; code points: `name.chars().count()`;
            what a reader sees as characters: `unicode.graphemes(name).count()`
      help: `name.is_empty()` asks whether it has any
    |}]

let%expect_test "[s2] a `Str` can't be indexed" =
  check_error
        {|
fn at(s: Str, i: Int) -> Int = s[i]
fn main() = ()
|};
  [%expect {|
    error: a `Str` can't be indexed: `s[i]` would be a byte
      ┌─ test.ren:1:32
    1 │ fn at(s: Str, i: Int) -> Int = s[i]
      │                                ^^^^
      help: a byte: `s.bytes().u8(i)`; a slice: `s[i..j]`; characters: `s.chars()`
    |}]

let%expect_test "[s2] `lower` is now `ascii_lower`" =
  check_error
        {|
fn key(s: Str) -> Str = s.lower()
fn main() = ()
|};
  [%expect {|
    error: `s.lower()` is now `s.ascii_lower()`
      ┌─ test.ren:1:27
    1 │ fn key(s: Str) -> Str = s.lower()
      │                           ^^^^^
      help: for every script's case, `unicode.lower(s)`
    |}]

let%expect_test "[s2] `concat` is gone, for `+` and `join`" =
  check_error
        {|
fn both(a: Str, b: Str) -> Str = a.concat(b)
fn main() = ()
|};
  check_error
        {|
fn both(a: Str, b: Str) -> Str = Str.concat(a, b)
fn main() = ()
|};
  [%expect {|
    error: `concat` is gone: strings are joined with `+`
      ┌─ test.ren:1:36
    1 │ fn both(a: Str, b: Str) -> Str = a.concat(b)
      │                                    ^^^^^^
      help: `a + b`; in a loop, `out += s`; many at once, `xs.join(sep)`
    error: `concat` is gone: strings are joined with `+`
      ┌─ test.ren:1:38
    1 │ fn both(a: Str, b: Str) -> Str = Str.concat(a, b)
      │                                      ^^^^^^
      help: `a + b`; in a loop, `out += s`; many at once, `xs.join(sep)`
    |}]

let%expect_test "[s2] a character literal that isn't one byte can't be a `UInt8`" =
  check_error
        {|
fn main() =
  let e: UInt8 = 'é'
  ()
|};
  check_error
        {|
fn tag() -> UInt8 = '😀'
fn main() = ()
|};
  [%expect {|
    error: `'é'` isn't a byte: it's 2 bytes in UTF-8
      ┌─ test.ren:2:18
    2 │   let e: UInt8 = 'é'
      │                  ^^^^
      help: compare text as text: `c == "é"`
    error: `'😀'` isn't a byte: it's 4 bytes in UTF-8
      ┌─ test.ren:1:21
    1 │ fn tag() -> UInt8 = '😀'
      │                     ^^^^^^
      help: compare text as text: `c == "😀"`
    |}]

let%expect_test "[s2] a character literal holds one code point" =
  check_error
        {|
fn main() =
  let x = 'ab'
  ()
|};
  check_error
        {|
fn main() =
  let x = ''
  ()
|};
  [%expect {|
    error: `'ab'` holds 2 code points; a character literal holds one
      ┌─ test.ren:2:11
    2 │   let x = 'ab'
      │           ^^^^
      help: text is written in double quotes: `"ab"`
    error: an empty character literal
      ┌─ test.ren:2:11
    2 │   let x = ''
      │           ^^
      help: a character literal holds one code point, `'a'`
    |}]

let%expect_test "[s2] a hole holds an expression, and ends with its `}`" =
  check_error
        {|
fn main() uses Console = print("a \{} b")
|};
  check_error
        {|
fn main() uses Console = print("a \{1 + 2")
|};
  [%expect {|
    error: an empty hole: `\{}` holds an expression
      ┌─ test.ren:1:35
    1 │ fn main() uses Console = print("a \{} b")
      │                                   ^^^
      help: a brace is written `{`, and a backslash and a brace `\\{`
    error: this hole has no `}`
      ┌─ test.ren:1:35
    1 │ fn main() uses Console = print("a \{1 + 2")
      │                                   ^^
    |}]

let%expect_test "[s2] a slice that ends inside a character panics, and names `char_floor`" =
  run_error
        {|
fn main() uses Console =
  var line = ""
  for _ in 0..1023
    line += "a"
  line += "é"
  print(line[0..line.char_floor(1024)].byte_len())
  print(line[0..1024])
|};
  run_error
        {|
fn main() uses Console =
  let w = "aé日"
  print(w.char_floor(4))
  print(w[1..4])
|};
  [%expect {|
    1023
    error: panic: slice 0 to 1024 ends inside a character
      ┌─ test.ren:7:9
    7 │   print(line[0..1024])
      │         ^^^^^^^^^^^^^
      help: to cut at most 1024 bytes, end at `line.char_floor(1024)`
    3
    error: panic: slice 1 to 4 ends inside a character
      ┌─ test.ren:4:9
    4 │   print(w[1..4])
      │         ^^^^^^^
      help: to cut at most 3 bytes, end at `w.char_floor(4)`
    |}]

let%expect_test "[s2] a slice that starts inside a character panics, and names both boundaries" =
  run_error
        {|
fn main() uses Console =
  let line = "aé日"
  print(line.char_ceil(2))
  print(line[2..6])
|};
  [%expect {|
    3
    error: panic: slice 2 to 6 starts inside a character
      ┌─ test.ren:4:9
    4 │   print(line[2..6])
      │         ^^^^^^^^^^
      help: to start where a character does, use `line.char_floor(2)` or `line.char_ceil(2)`
    |}]

let%expect_test "[s2] `split_at` inside a character panics as its first half's slice would" =
  run_error
        {|
fn main() uses Console =
  var w = "aé"
  print(w.byte_len())
  &w.split_at(2) fn(&a, &b) =>
    print(a)
|};
  [%expect {|
    3
    error: panic: slice 0 to 2 ends inside a character
      ┌─ test.ren:4:4
    4 │   &w.split_at(2) fn(&a, &b) =>
      │    ^^^^^^^^^^^^^^^^^^^^^^^^^^^
      help: to cut at most 2 bytes, end at `w.char_floor(2)`
    |}]

let%expect_test "[s2] `code()` panics on a string that isn't one code point" =
  run_error
        {|
fn main() uses Console =
  let w = "ab"
  print(w.byte_len())
  print(w.code())
|};
  run_error
        {|
fn main() uses Console =
  let w = ""
  print(w.is_empty())
  print(w.code())
|};
  [%expect {|
    2
    error: panic: `code()` takes one code point, and this string has 2
      ┌─ test.ren:4:9
    4 │   print(w.code())
      │         ^^^^^^^^
      help: for each code point: `for c in w.chars()`, and `c.code()`
    true
    error: panic: `code()` takes one code point, and this string is empty
      ┌─ test.ren:4:9
    4 │   print(w.code())
      │         ^^^^^^^^
    |}]

let%expect_test "[s2] `Str.of_code` panics on what isn't a Unicode scalar value" =
  List.iter run_error
    [
      {|
fn main() uses Console = print(Str.of_code(0xDFFF))
|};
      {|
fn main() uses Console = print(Str.of_code(0x110000))
|};
      {|
fn main() uses Console = print(Str.of_code(-1))
|};
    ];
  [%expect {|
    error: panic: `Str.of_code(57343)` isn't a Unicode scalar value
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print(Str.of_code(0xDFFF))
      │                                ^^^^^^^^^^^^^^^^^^^
      help: a scalar value is 0 to 0x10FFFF, but not 0xD800 to 0xDFFF, the surrogates
    error: panic: `Str.of_code(1114112)` isn't a Unicode scalar value
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print(Str.of_code(0x110000))
      │                                ^^^^^^^^^^^^^^^^^^^^^
      help: a scalar value is 0 to 0x10FFFF, but not 0xD800 to 0xDFFF, the surrogates
    error: panic: `Str.of_code(-1)` isn't a Unicode scalar value
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print(Str.of_code(-1))
      │                                ^^^^^^^^^^^^^^^
      help: a scalar value is 0 to 0x10FFFF, but not 0xD800 to 0xDFFF, the surrogates
    |}]

let%expect_test "[s2] `char_floor` and `char_ceil` outside the string panic, as `split_at` does" =
  run_error
        {|
fn main() uses Console = print("aé".char_floor(4))
|};
  run_error
        {|
fn main() uses Console = print("aé".char_ceil(-1))
|};
  [%expect {|
    error: panic: `char_floor` 4 is out of bounds for a string of length 3
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print("aé".char_floor(4))
      │                                ^^^^^^^^^^^^^^^^^^^
    error: panic: `char_ceil` -1 is out of bounds for a string of length 3
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print("aé".char_ceil(-1))
      │                                ^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s2] a hole goes through its type's own `show`" =
  run
        {|
type Money = { cents: Int }
  pub fn show(self) -> Str =
    let c = self.cents % 100
    "$\{self.cents / 100}.\{if c < 10 then "0" else ""}\{c}"

fn main() uses Console =
  let m = Money { cents: 1250 }
  print("price: \{m}, \{1 + 1} of them")
|};
  [%expect {|
    price: $12.50, 2 of them
    ()
    |}]

let%expect_test "[s2] `+=` through `inout`, on a shared string and on a slice, means what it says" =
  run
        {|
fn bang(inout s: Str) =
  s += "!"

fn main() uses Console =
  var s = "a"
  let kept = s
  s += "b"
  bang(&s)
  print(s)
  print(kept)
  let base = "hello"
  var h = base[0..3]
  bang(&h)
  print(h)
  print(base)
|};
  [%expect {|
    ab!
    a
    hel!
    hello
    ()
    |}]

(* `Bytes` keeps `len`, where there's one unit. *)
let%expect_test "[s2] `Bytes` keeps `len`" =
  run
    {|
fn main() uses Console = print(Bytes.of([1, 2, 3]).len())
|};
  [%expect {|
    3
    () |}]

(* ---- s5: the rest of the API ---- *)

let%expect_test "[s5] `len`'s help compiles: `chars().count()`" =
  until "s5"
    ~want:{|
5
5
true
()
|}
    (fun () ->
      run
        {|
fn main() uses Console =
  let name = "héllo"
  print(name.chars().count())
  print(name.chars().count(fn(c) => c != "x"))
  print(name.byte_len() == 6)
|});
  [%expect {|
    (until s5)
    error: `Chars` has no method named `count`
      ┌─ test.ren:3:22
    3 │   print(name.chars().count())
      │                      ^^^^^
      help: its methods: `next`

    error: `Chars` has no method named `count`
      ┌─ test.ren:4:22
    4 │   print(name.chars().count(fn(c) => c != "x"))
      │                      ^^^^^
      help: its methods: `next`
    |}]

let%expect_test "[s5] `line_col` of an offset outside the string, or inside a character, panics" =
  until "s5"
    ~says:[ "error: panic: `line_col` 30 is out of bounds for a string of length 23" ]
    (fun () ->
      run_error
        {|
fn main() uses Console =
  let text = "first\nsé😀cond\nthird"
  print(text.line_col(0))
  print(text.line_col(30))
|});
  until "s5"
    ~says:
      [
        "error: panic: `line_col` 8 is inside a character";
        "help: the character it's in starts at `text.char_floor(8)`";
      ]
    (fun () ->
      run_error
        {|
fn main() uses Console =
  let text = "first\nsé😀cond\nthird"
  print(text.line_col(7))
  print(text.line_col(8))
|});
  [%expect {|
    (until s5)
    error: `Str` has no method named `line_col`
      ┌─ test.ren:3:14
    3 │   print(text.line_col(0))
      │              ^^^^^^^^
      help: its methods: `byte_len`, `index`, `split`, `trim`, `starts_with`, `add`, `bytes`, `ascii_lower`, `copy`, `split_at`, `char_floor`, `char_ceil`, `code`, `is_empty`, `chars`

    error: `Str` has no method named `line_col`
      ┌─ test.ren:4:14
    4 │   print(text.line_col(30))
      │              ^^^^^^^^
      help: its methods: `byte_len`, `index`, `split`, `trim`, `starts_with`, `add`, `bytes`, `ascii_lower`, `copy`, `split_at`, `char_floor`, `char_ceil`, `code`, `is_empty`, `chars`
    (until s5)
    error: `Str` has no method named `line_col`
      ┌─ test.ren:3:14
    3 │   print(text.line_col(7))
      │              ^^^^^^^^
      help: its methods: `byte_len`, `index`, `split`, `trim`, `starts_with`, `add`, `bytes`, `ascii_lower`, `copy`, `split_at`, `char_floor`, `char_ceil`, `code`, `is_empty`, `chars`

    error: `Str` has no method named `line_col`
      ┌─ test.ren:4:14
    4 │   print(text.line_col(8))
      │              ^^^^^^^^
      help: its methods: `byte_len`, `index`, `split`, `trim`, `starts_with`, `add`, `bytes`, `ascii_lower`, `copy`, `split_at`, `char_floor`, `char_ceil`, `code`, `is_empty`, `chars`
    |}]

let%expect_test "[s5] `replace` of the empty string panics, as `split` of it does" =
  until "s5"
    ~says:[ "error: panic: `replace` needs a string to replace that isn't empty" ]
    (fun () ->
      run_error
        {|
fn main() uses Console = print("abc".replace("", "-"))
|});
  [%expect {|
    (until s5)
    error: `Str` has no method named `replace`
      ┌─ test.ren:1:38
    1 │ fn main() uses Console = print("abc".replace("", "-"))
      │                                      ^^^^^^^
      help: its methods: `byte_len`, `index`, `split`, `trim`, `starts_with`, `add`, `bytes`, `ascii_lower`, `copy`, `split_at`, `char_floor`, `char_ceil`, `code`, `is_empty`, `chars`
    |}]

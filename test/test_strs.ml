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
  until "s1"
    ~want:
      {|
Err(InvalidUtf8(1, false))
Err(InvalidUtf8(1, true))
Err(InvalidUtf8(1, false))
Ok("ok")
()
|}
    (fun () ->
      run
        {|
fn main() uses Console =
  print(attempt Str.from_utf8(Bytes.of([0x61, 0xC0, 0x80])))
  print(attempt Str.from_utf8(Bytes.of([0x61, 0xF0, 0x9F, 0x98])))
  print(attempt Str.from_utf8(Bytes.of([0x61, 0xF0, 0x9F, 0x98, 0x61])))
  print(attempt Str.from_utf8(Bytes.of([0x6F, 0x6B])))
|});
  [%expect {|
    (until s1)
    Err(InvalidUtf8)
    Err(InvalidUtf8)
    Err(InvalidUtf8)
    Ok("ok")
    ()
    |}]

let%expect_test "[s1] a decoder working chunk by chunk tells invalid from not finished, by the payload" =
  until "s1"
    ~want:
      {|
日本 then 1 bytes kept
invalid at 2
()
|}
    (fun () ->
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
|});
  [%expect {|
    (until s1)
    error: `\{` isn't an escape
      ┌─ test.ren:8:27
    8 │           Ok(t) => print("\{t} then \{b.len() - at} bytes kept")
      │                           ^^
      help: the escapes are `\n`, `\t`, `\"` and `\\`, which writes a backslash
    |}]

let%expect_test "[s1] `from_utf8_lossy` writes one U+FFFD for each maximal invalid subpart, and keeps a byte order mark" =
  until "s1"
    ~want:
      {|
a�b
a���b
a�
�
3
()
|}
    (fun () ->
      run
        {|
fn main() uses Console =
  print(Str.from_utf8_lossy(Bytes.of([0x61, 0xE2, 0x82, 0x62])))
  print(Str.from_utf8_lossy(Bytes.of([0x61, 0xED, 0xA0, 0x80, 0x62])))
  print(Str.from_utf8_lossy(Bytes.of([0x61, 0xF0, 0x9F, 0x98])))
  print(Str.from_utf8_lossy(Bytes.of([0xFF])))
  print(Str.from_utf8_lossy(Bytes.of([0xEF, 0xBB, 0xBF])).byte_len())
|});
  [%expect {|
    (until s1)
    error: `Str` has no member named `from_utf8_lossy`
      ┌─ test.ren:2:13
    2 │   print(Str.from_utf8_lossy(Bytes.of([0x61, 0xE2, 0x82, 0x62])))
      │             ^^^^^^^^^^^^^^^
      help: its members: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`, `from_utf8`

    error: `Str` has no member named `from_utf8_lossy`
      ┌─ test.ren:3:13
    3 │   print(Str.from_utf8_lossy(Bytes.of([0x61, 0xED, 0xA0, 0x80, 0x62])))
      │             ^^^^^^^^^^^^^^^
      help: its members: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`, `from_utf8`

    error: `Str` has no member named `from_utf8_lossy`
      ┌─ test.ren:4:13
    4 │   print(Str.from_utf8_lossy(Bytes.of([0x61, 0xF0, 0x9F, 0x98])))
      │             ^^^^^^^^^^^^^^^
      help: its members: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`, `from_utf8`

    error: `Str` has no member named `from_utf8_lossy`
      ┌─ test.ren:5:13
    5 │   print(Str.from_utf8_lossy(Bytes.of([0xFF])))
      │             ^^^^^^^^^^^^^^^
      help: its members: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`, `from_utf8`

    error: `Str` has no member named `from_utf8_lossy`
      ┌─ test.ren:6:13
    6 │   print(Str.from_utf8_lossy(Bytes.of([0xEF, 0xBB, 0xBF])).byte_len())
      │             ^^^^^^^^^^^^^^^
      help: its members: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`, `from_utf8`
    |}]

(* ---- s2: the API, and interpolation ---- *)

let%expect_test "[s2] `len` on a `Str` asks which unit" =
  until "s2"
    ~says:
      [
        "error: `Str` has no `len`: bytes, or characters?";
        "help: bytes: `name.byte_len()`; code points: `name.chars().count()`;";
        "what a reader sees as characters: `unicode.graphemes(name).count()`";
        "help: `name.is_empty()` asks whether it has any";
      ]
    (fun () ->
      check_error
        {|
fn short(name: Str) -> Bool = name.len() <= 20
fn main() = ()
|});
  [%expect {|
    (until s2)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[s2] a `Str` can't be indexed" =
  until "s2"
    ~says:
      [
        "error: a `Str` can't be indexed: `s[i]` would be a byte";
        "help: a byte: `s.bytes().u8(i)`; a slice: `s[i..j]`; characters: `s.chars()`";
      ]
    (fun () ->
      check_error
        {|
fn at(s: Str, i: Int) -> Int = s[i]
fn main() = ()
|});
  [%expect {|
    (until s2)
    error: only an `Array` can be indexed, but this is a `Str`
      ┌─ test.ren:1:32
    1 │ fn at(s: Str, i: Int) -> Int = s[i]
      │                                ^
    |}]

let%expect_test "[s2] `lower` is now `ascii_lower`" =
  until "s2"
    ~says:
      [
        "error: `s.lower()` is now `s.ascii_lower()`";
        "help: for every script's case, `unicode.lower(s)`";
      ]
    (fun () ->
      check_error
        {|
fn key(s: Str) -> Str = s.lower()
fn main() = ()
|});
  [%expect {|
    (until s2)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[s2] `concat` is gone, for `+` and `join`" =
  until "s2"
    ~says:
      [
        "error: `concat` is gone: strings are joined with `+`";
        "help: `a + b`; in a loop, `out += s`; many at once, `xs.join(sep)`";
      ]
    (fun () ->
      check_error
        {|
fn both(a: Str, b: Str) -> Str = a.concat(b)
fn main() = ()
|});
  until "s2"
    ~says:
      [
        "error: `concat` is gone: strings are joined with `+`";
        "help: `a + b`; in a loop, `out += s`; many at once, `xs.join(sep)`";
      ]
    (fun () ->
      check_error
        {|
fn both(a: Str, b: Str) -> Str = Str.concat(a, b)
fn main() = ()
|});
  [%expect {|
    (until s2)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    (until s2)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[s2] a character literal that isn't one byte can't be a `UInt8`" =
  until "s2"
    ~says:
      [
        "error: `'é'` isn't a byte: it's 2 bytes in UTF-8";
        "help: compare text as text: `c == \"é\"`";
      ]
    (fun () ->
      check_error
        {|
fn main() =
  let e: UInt8 = 'é'
  ()
|});
  until "s2"
    ~says:
      [
        "error: `'😀'` isn't a byte: it's 4 bytes in UTF-8";
        "help: compare text as text: `c == \"😀\"`";
      ]
    (fun () ->
      check_error
        {|
fn tag() -> UInt8 = '😀'
fn main() = ()
|});
  [%expect {|
    (until s2)
    error: unexpected character `'`
      ┌─ test.ren:2:18
    2 │   let e: UInt8 = 'é'
      │                  ^
    (until s2)
    error: unexpected character `'`
      ┌─ test.ren:1:21
    1 │ fn tag() -> UInt8 = '😀'
      │                     ^
    |}]

let%expect_test "[s2] a character literal holds one code point" =
  until "s2"
    ~says:
      [
        "error: `'ab'` holds 2 code points; a character literal holds one";
        "help: text is written in double quotes: `\"ab\"`";
      ]
    (fun () ->
      check_error
        {|
fn main() =
  let x = 'ab'
  ()
|});
  until "s2"
    ~says:
      [
        "error: an empty character literal";
        "help: a character literal holds one code point, `'a'`";
      ]
    (fun () ->
      check_error
        {|
fn main() =
  let x = ''
  ()
|});
  [%expect {|
    (until s2)
    error: unexpected character `'`
      ┌─ test.ren:2:11
    2 │   let x = 'ab'
      │           ^
    (until s2)
    error: unexpected character `'`
      ┌─ test.ren:2:11
    2 │   let x = ''
      │           ^
    |}]

let%expect_test "[s2] a hole holds an expression, and ends with its `}`" =
  until "s2"
    ~says:
      [
        "error: an empty hole: `\\{}` holds an expression";
        "help: a brace is written `{`, and a backslash and a brace `\\\\{`";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Console = print("a \{} b")
|});
  until "s2"
    ~says:[ "error: this hole has no `}`" ]
    (fun () ->
      check_error
        {|
fn main() uses Console = print("a \{1 + 2")
|});
  [%expect {|
    (until s2)
    error: `\{` isn't an escape
      ┌─ test.ren:1:35
    1 │ fn main() uses Console = print("a \{} b")
      │                                   ^^
      help: the escapes are `\n`, `\t`, `\"` and `\\`, which writes a backslash
    (until s2)
    error: `\{` isn't an escape
      ┌─ test.ren:1:35
    1 │ fn main() uses Console = print("a \{1 + 2")
      │                                   ^^
      help: the escapes are `\n`, `\t`, `\"` and `\\`, which writes a backslash
    |}]

let%expect_test "[s2] a slice that ends inside a character panics, and names `char_floor`" =
  until "s2"
    ~says:
      [
        "error: panic: slice 0 to 1024 ends inside a character";
        "help: to cut at most 1024 bytes, end at `line.char_floor(1024)`";
      ]
    (fun () ->
      run_error
        {|
fn main() uses Console =
  var line = ""
  for _ in 0..1023
    line += "a"
  line += "é"
  print(line[0..line.char_floor(1024)].byte_len())
  print(line[0..1024])
|});
  until "s2"
    ~says:
      [
        "error: panic: slice 1 to 4 ends inside a character";
        "help: to cut at most 3 bytes, end at `w.char_floor(4)`";
      ]
    (fun () ->
      run_error
        {|
fn main() uses Console =
  let w = "aé日"
  print(w.char_floor(4))
  print(w[1..4])
|});
  [%expect {|
    (until s2)
    error: `Str` has no `+`
      ┌─ test.ren:4:5
    4 │     line += "a"
      │     ^^^^^^^^^^^
      help: join two strings with `a.concat(b)`

    error: `Str` has no `+`
      ┌─ test.ren:5:3
    5 │   line += "é"
      │   ^^^^^^^^^^^^
      help: join two strings with `a.concat(b)`

    error: `Str` has no method named `char_floor`
      ┌─ test.ren:6:22
    6 │   print(line[0..line.char_floor(1024)].byte_len())
      │                      ^^^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`

    error: `Str` has no method named `byte_len`
      ┌─ test.ren:6:40
    6 │   print(line[0..line.char_floor(1024)].byte_len())
      │                                        ^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    (until s2)
    error: `Str` has no method named `char_floor`
      ┌─ test.ren:3:11
    3 │   print(w.char_floor(4))
      │           ^^^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    |}]

let%expect_test "[s2] a slice that starts inside a character panics, and names both boundaries" =
  until "s2"
    ~says:
      [
        "error: panic: slice 2 to 6 starts inside a character";
        "help: to start where a character does, use `line.char_floor(2)` or `line.char_ceil(2)`";
      ]
    (fun () ->
      run_error
        {|
fn main() uses Console =
  let line = "aé日"
  print(line.char_ceil(2))
  print(line[2..6])
|});
  [%expect {|
    (until s2)
    error: `Str` has no method named `char_ceil`
      ┌─ test.ren:3:14
    3 │   print(line.char_ceil(2))
      │              ^^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    |}]

let%expect_test "[s2] `split_at` inside a character panics as its first half's slice would" =
  until "s2"
    ~says:
      [
        "error: panic: slice 0 to 2 ends inside a character";
        "help: to cut at most 2 bytes, end at `w.char_floor(2)`";
      ]
    (fun () ->
      run_error
        {|
fn main() uses Console =
  var w = "aé"
  print(w.byte_len())
  &w.split_at(2) fn(&a, &b) =>
    print(a)
|});
  [%expect {|
    (until s2)
    error: `Str` has no method named `byte_len`
      ┌─ test.ren:3:11
    3 │   print(w.byte_len())
      │           ^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    |}]

let%expect_test "[s2] `code()` panics on a string that isn't one code point" =
  until "s2"
    ~says:
      [
        "error: panic: `code()` takes one code point, and this string has 2";
        "help: for each code point: `for c in w.chars()`, and `c.code()`";
      ]
    (fun () ->
      run_error
        {|
fn main() uses Console =
  let w = "ab"
  print(w.byte_len())
  print(w.code())
|});
  until "s2"
    ~says:[ "error: panic: `code()` takes one code point, and this string is empty" ]
    (fun () ->
      run_error
        {|
fn main() uses Console =
  let w = ""
  print(w.is_empty())
  print(w.code())
|});
  [%expect {|
    (until s2)
    error: `Str` has no method named `byte_len`
      ┌─ test.ren:3:11
    3 │   print(w.byte_len())
      │           ^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`

    error: `Str` has no method named `code`
      ┌─ test.ren:4:11
    4 │   print(w.code())
      │           ^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    (until s2)
    error: `Str` has no method named `is_empty`
      ┌─ test.ren:3:11
    3 │   print(w.is_empty())
      │           ^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`

    error: `Str` has no method named `code`
      ┌─ test.ren:4:11
    4 │   print(w.code())
      │           ^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    |}]

let%expect_test "[s2] `Str.of_code` panics on what isn't a Unicode scalar value" =
  let says n =
    [
      Printf.sprintf "error: panic: `Str.of_code(%s)` isn't a Unicode scalar value" n;
      "help: a scalar value is 0 to 0x10FFFF, but not 0xD800 to 0xDFFF, the surrogates";
    ]
  in
  List.iter
    (fun (n, src) -> until "s2" ~says:(says n) (fun () -> run_error src))
    [
      ("57343", {|
fn main() uses Console = print(Str.of_code(0xDFFF))
|});
      ("1114112", {|
fn main() uses Console = print(Str.of_code(0x110000))
|});
      ("-1", {|
fn main() uses Console = print(Str.of_code(-1))
|});
    ];
  [%expect {|
    (until s2)
    error: `Str` has no member named `of_code`
      ┌─ test.ren:1:36
    1 │ fn main() uses Console = print(Str.of_code(0xDFFF))
      │                                    ^^^^^^^
      help: its members: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`, `from_utf8`
    (until s2)
    error: `Str` has no member named `of_code`
      ┌─ test.ren:1:36
    1 │ fn main() uses Console = print(Str.of_code(0x110000))
      │                                    ^^^^^^^
      help: its members: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`, `from_utf8`
    (until s2)
    error: `Str` has no member named `of_code`
      ┌─ test.ren:1:36
    1 │ fn main() uses Console = print(Str.of_code(-1))
      │                                    ^^^^^^^
      help: its members: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`, `from_utf8`
    |}]

let%expect_test "[s2] `char_floor` and `char_ceil` outside the string panic, as `split_at` does" =
  until "s2"
    ~says:[ "error: panic: `char_floor` 4 is out of bounds for a string of length 3" ]
    (fun () ->
      run_error
        {|
fn main() uses Console = print("aé".char_floor(4))
|});
  until "s2"
    ~says:[ "error: panic: `char_ceil` -1 is out of bounds for a string of length 3" ]
    (fun () ->
      run_error
        {|
fn main() uses Console = print("aé".char_ceil(-1))
|});
  [%expect {|
    (until s2)
    error: `Str` has no method named `char_floor`
      ┌─ test.ren:1:38
    1 │ fn main() uses Console = print("aé".char_floor(4))
      │                                      ^^^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    (until s2)
    error: `Str` has no method named `char_ceil`
      ┌─ test.ren:1:38
    1 │ fn main() uses Console = print("aé".char_ceil(-1))
      │                                      ^^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    |}]

let%expect_test "[s2] a hole goes through its type's own `show`" =
  until "s2"
    ~want:{|
price: $12.50, 2 of them
()
|}
    (fun () ->
      run
        {|
type Money = { cents: Int }
  pub fn show(self) -> Str =
    let c = self.cents % 100
    "$\{self.cents / 100}.\{if c < 10 then "0" else ""}\{c}"

fn main() uses Console =
  let m = Money { cents: 1250 }
  print("price: \{m}, \{1 + 1} of them")
|});
  [%expect {|
    (until s2)
    error: `\{` isn't an escape
      ┌─ test.ren:4:7
    4 │     "$\{self.cents / 100}.\{if c < 10 then "0" else ""}\{c}"
      │       ^^
      help: the escapes are `\n`, `\t`, `\"` and `\\`, which writes a backslash
    |}]

let%expect_test "[s2] `+=` through `inout`, on a shared string and on a slice, means what it says" =
  until "s2"
    ~want:
      {|
ab!
a
hel!
hello
()
|}
    (fun () ->
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
|});
  [%expect {|
    (until s2)
    error: `Str` has no `+`
      ┌─ test.ren:2:3
    2 │   s += "!"
      │   ^^^^^^^^
      help: join two strings with `a.concat(b)`

    error: `Str` has no `+`
      ┌─ test.ren:7:3
    7 │   s += "b"
      │   ^^^^^^^^
      help: join two strings with `a.concat(b)`
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
    error: `Str` has no method named `chars`
      ┌─ test.ren:3:14
    3 │   print(name.chars().count())
      │              ^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`

    error: `Str` has no method named `chars`
      ┌─ test.ren:4:14
    4 │   print(name.chars().count(fn(c) => c != "x"))
      │              ^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`

    error: `Str` has no method named `byte_len`
      ┌─ test.ren:5:14
    5 │   print(name.byte_len() == 6)
      │              ^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
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
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`

    error: `Str` has no method named `line_col`
      ┌─ test.ren:4:14
    4 │   print(text.line_col(30))
      │              ^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    (until s5)
    error: `Str` has no method named `line_col`
      ┌─ test.ren:3:14
    3 │   print(text.line_col(7))
      │              ^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`

    error: `Str` has no method named `line_col`
      ┌─ test.ren:4:14
    4 │   print(text.line_col(8))
      │              ^^^^^^^^
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
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
      help: its methods: `len`, `index`, `split`, `trim`, `starts_with`, `concat`, `bytes`, `lower`, `copy`, `split_at`
    |}]

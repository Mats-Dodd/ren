(* The bytes stage's part two, step 2, beyond test_strs.ml's s2: what the
   step chose where strings.md was silent (compiler.md, "Bytes stage,
   part two", "Where this stage may differ"), each in the interpreter.
   bench/strs.t runs the programs that print natively too. *)

open Helpers

let%expect_test "`\\{x=}` writes the name or the path, `=`, then the value" =
  run
    {|
type User = { name: Str, age: Int }

fn main() uses Console =
  let n = 21
  let u = User { name: "Ada", age: 36 }
  print("\{n=}")
  print("got \{u.name=} and \{u.age=}!")
  print("\{ n = }")
|};
  [%expect {|
    n=21
    got u.name=Ada and u.age=36!
    n=21
    ()
    |}]

let%expect_test "`\\{e=}` takes only a name or a path" =
  check_error
    {|
fn main() uses Console = print("\{1 + 2=}")
|};
  [%expect {|
    error: only a name or a path can come before `=` in a hole
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print("\{1 + 2=}")
      │                                 ^^^^^^^^^
      help: write the text before it yourself: `"sum=\{a + b}"`
    |}]

let%expect_test "a comparison ending a hole isn't `\\{x=}`" =
  run
    {|
fn main() uses Console =
  let n = 2
  print("\{n == 2} \{n != 2} \{n >= 2}")
|};
  [%expect {|
    true false true
    ()
    |}]

let%expect_test "a character literal's escapes, and one that isn't closed" =
  run
    {|
fn main() uses Console =
  print(['\n', '\t', '\\', '\'', '"', ' '])
|};
  check_error
    {|
fn main() uses Console = print('\q')
|};
  check_error
    {|
fn main() uses Console = print('a)
|};
  [%expect {|
    [10, 9, 92, 39, 34, 32]
    ()
    error: `\q` isn't an escape
      ┌─ test.ren:1:33
    1 │ fn main() uses Console = print('\q')
      │                                 ^^
      help: the escapes in a character literal are `\n`, `\t`, `\r`, `\0`, `\'`, `\\`, which writes a backslash, and `\u{E9}`, a code point
    error: this character literal isn't closed
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print('a)
      │                                ^^^
      help: close it with `'` on this line
    |}]

let%expect_test "an ASCII character literal is a byte, and a `UInt8` of one prints its number" =
  run
    {|
fn main() uses Console =
  let q: UInt8 = 'Q'
  let tags: Array<UInt8> = ['a', 'b']
  print(q)
  print(tags)
  match "\"".bytes().u8(0)
    '"' => print("a quote")
    _ => print("something else")
|};
  [%expect {|
    81
    [97, 98]
    a quote
    ()
    |}]

let%expect_test "`Bytes` has `+`, `+=` and `ascii_lower`, and keeps `len`" =
  run
    {|
fn main() uses Console =
  var b = "AB".bytes()
  b += "Cd".bytes()
  print(b.ascii_lower())
  print((b + Bytes.of([0xFF])).len())
|};
  [%expect {|
    <bytes 61 62 63 64>
    5
    ()
    |}]

let%expect_test "a cursor made `from` a base says every offset from it, its errors' too" =
  run
    {|
fn read(inout c: ByteCursor) -> Int ! FormatError = try &c.u64_le()
fn skip(inout c: ByteCursor, n: Int) ! FormatError = try &c.skip(n)

fn main() uses Console =
  var c = Bytes.of([1, 2, 3, 4, 5, 6, 7, 0xFF]).cursor(from: 4096)
  print(attempt skip(&c, 9))
  print(attempt read(&c))
  print(c.at())
|};
  [%expect {|
    Err(Short(4096, 1))
    Err(Malformed(4096, "", "18376663423120507393 is more than an `Int` holds"))
    4096
    ()
    |}]

let%expect_test "`join` of none, one and an empty one, and a hole of every width" =
  run
    {|
fn main() uses Console =
  let none: Array<Str> = []
  print("[\{none.join(",")}] [\{["a"].join(",")}] [\{["", ""].join(",")}]")
  print("\{"é"}\{"日"}\{"😀"}".byte_len())
|};
  [%expect {|
    [] [a] [,]
    9
    ()
    |}]

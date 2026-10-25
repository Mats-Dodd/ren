(* Running programs: the interpreter (eval.ml), value semantics and panics. *)

open Helpers

let%expect_test "fib(30) runs (Stage 1 milestone)" =
  run
    {|
fn fib(n: Int) -> Int =
  if n < 2 then n else fib(n - 1) + fib(n - 2)

fn main() -> Int =
  fib(30)
|};
  [%expect {| 832040 |}]

let%expect_test "blocks, let, multi-line if, print" =
  run
    {|
fn main() =
  let x = 10
  let y =
    let z = x * 2
    z + 1
  print(y)
  if y > 20 then
    print(1)
  else
    print(0)
  y % 4
|};
  [%expect {|
    21
    1
    1
    |}]

let%expect_test "arguments can wrap inside parentheses" =
  run
    {|
fn add3(a: Int, b: Int, c: Int) -> Int = a + b + c

fn main() -> Int =
  add3(
    1,
    2,
    3,
  )
|};
  [%expect {| 6 |}]

let%expect_test "division by zero panics" =
  run {|
fn main() = 10 / (5 - 5)
|};
  [%expect
    {|
    error: panic: division by zero
      ┌─ test.ren:1:13
    1 │ fn main() = 10 / (5 - 5)
      │             ^^^^^^^^^^^^
    |}]

let%expect_test "seat_limit from the README runs" =
  run
    (plan_types
   ^ {|
fn seat_limit(p: Plan) -> Int =
  match p
    Free          => 1
    Pro(seats)    => seats
    Enterprise(_) => 1_000_000

fn main() -> Int =
  let u = User { id: 1, plan: Pro(seats: 5) }
  seat_limit(u.plan)
|}
    );
  [%expect {| 5 |}]

let%expect_test "records: punning, field access, equality ignores field order" =
  run
    (plan_types
   ^ {|
fn main() =
  let id = 7
  let plan = Enterprise(contract: 42)
  let u = { id, plan }
  print(u)
  print(u.plan)
  print(u == User { plan: Enterprise(42), id: 7 })
  print(u.plan == Free)
|}
    );
  [%expect
    {|
    User { id: 7, plan: Enterprise(42) }
    Enterprise(42)
    true
    false
    ()
    |}]

let%expect_test "multi-line types, single-line sum types, block arms" =
  run
    {|
type Point = {
  x: Int,
  y: Int,
}

type Bit = Zero | One

fn flip(b: Bit) -> Bit =
  match b
    Zero => One
    One =>
      let z = Zero
      z

fn main() =
  print(Point { x: 1, y: 2 }.y)
  print(flip(Zero))
  print(flip(flip(Zero)))
|};
  [%expect {|
    2
    One
    Zero
    ()
    |}]

let%expect_test "Option comes from the prelude; guards" =
  run
    {|
fn describe(o: Option<Int>) -> Int =
  match o
    Some(n) if n > 100 => 100
    Some(n) => n
    None => 0

fn main() =
  print(describe(Some(5)))
  print(describe(Some(value: 500)))
  print(describe(None))
|};
  [%expect {|
    5
    100
    0
    ()
    |}]

(* lambdas *)

let%expect_test "lambdas, closures, functions as values" =
  let src =
    {|
fn double(x) = x * 2

fn apply(o, f) =
  match o
    Some(v) => Some(f(v))
    None => None

fn compose(f, g) = fn(x) => g(f(x))

fn main() =
  let n = 10
  print(apply(Some(5), fn(x) => x + n))
  let inc_then_double = compose(fn(x) => x + 1, double)
  print(inc_then_double(4))
  print(compose(double, double)(1))
  let ignore = fn(_) => ()
  ignore(3)
  print(double)
|}
  in
  run src;
  [%expect {|
    Some(15)
    10
    4
    <fn double>
    ()
    |}];
  types src;
  [%expect
    {|
    fn double(x: Int) -> Int
    fn apply<T, U>(o: Option<T>, f: fn(T) -> U uses ..d) -> Option<U> uses ..d
    fn compose<T, U, V>(f: fn(T) -> U uses ..d, g: fn(U) -> V uses ..d) -> (fn(T) -> V uses ..d)
    fn main() uses Console
    |}]

let%expect_test "trailing lambdas" =
  run
    {|
fn twice(f) =
  let _ = f()
  f()

fn main() =
  twice() fn() =>
    print(1)
    print(2)
  let r = twice() fn() => 5
  r
|};
  [%expect {|
    1
    2
    1
    2
    5
    |}]

let%expect_test "&& and || run their right side only when it's needed" =
  run
    {|
fn loud(b: Bool) -> Bool =
  print(b)
  b

fn main() =
  print(loud(false) && loud(true))
  print(loud(true) || loud(false))
  print(loud(true) && not loud(false))
  not (1 == 2) && 3 > 2 || false
|};
  [%expect
    {|
    false
    false
    true
    true
    true
    false
    true
    true
    |}]

let%expect_test "normalize(&scores) works" =
  run
    {|
// Stage 4: `var`, `inout`, `&` and value semantics.

type Point = { x: Int, y: Int }

// Shift every score so the lowest is 0. `inout` updates the caller's array.
fn normalize(inout xs: Array<Int>) =
  var low = xs[0]
  for x in xs
    if x < low then low = x
  for x in &xs
    x -= low

fn nudge(inout p: Point, dx: Int) =
  p.x += dx

fn sum(xs) =
  var total = 0
  for x in xs
    total += x
  total

fn main() =
  var scores = [13, 11, 12]
  let before = scores                  // a value, not a reference
  normalize(&scores)                   // `&`: this call changes `scores`
  &scores.push(10)
  print(scores)
  print(before)                        // unchanged
  print(sum(scores))

  var p = Point { x: 1, y: 2 }
  let q = p
  nudge(&p, 10)
  p.y = 0
  print(p)
  print(q)

  var n = 1
  let get = fn() => n                  // captures n's value now
  n = 2
  print(get())
|};
  [%expect
    {|
    [2, 0, 1, 10]
    [13, 11, 12]
    13
    Point { x: 11, y: 0 }
    Point { x: 1, y: 2 }
    1
    ()
    |}]

let%expect_test "nested places and for &" =
  run
    {|
type P = { x: Int, y: Int }
fn swap(inout a: Int, inout b: Int) =
  let t = a
  a = b
  b = t
fn main() =
  var grid = [[1, 2], [3, 4]]
  grid[1][0] = 9
  var ps = [P { x: 1, y: 1 }, P { x: 2, y: 2 }]
  for p in &ps
    p.x *= 5
  swap(&ps[0].x, &ps[0].y)
  print(ps)
  grid
|};
  [%expect {|
    [P { x: 1, y: 5 }, P { x: 10, y: 2 }]
    [[1, 2], [9, 4]]
    |}]

let%expect_test "index out of bounds" =
  run {|
fn main() =
  let xs = [1]
  xs[3]
|};
  [%expect
    {|
    error: panic: index 3 is out of bounds for an array of length 1
      ┌─ test.ren:3:3
    3 │   xs[3]
      │   ^^^^^
    |}]

(* anything a pass raises that isn't a diagnostic or a panic is a bug in the
   compiler, and says so *)

let%expect_test "an internal compiler error names its pass" =
  report "" (fun () -> Ren.Driver.pass "infer" (fun () -> failwith "boom"));
  [%expect
    {|
    internal compiler error in infer: Failure("boom")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "strings: literals, ==, show and print" =
  run
    {|
fn main() =
  print("Ren")
  print("tab\there")
  print(show(42) == "42")
  print(show(Some(true)))
  print("a" != "b")
  print(["x", "y\n"])
  show([1, 2])
|};
  [%expect
    {|
    Ren
    tab	here
    true
    Some(true)
    true
    ["x", "y\n"]
    "[1, 2]"
    |}]

(* ---- strings and bytes ----

   A string's indices are byte offsets: `é` and `ö` are two bytes each. *)

let%expect_test "a string's length, slices and search, in bytes" =
  run
    {|
fn main() =
  let s = "héllo, wörld"
  print(s.len())
  print(s.slice(0, 3))
  print(s.slice(8, 14))
  print(s.slice(4, 4) == "")
  print(s.find("w"))
  print(s.find("ö"))
  print(s.find(""))
  s.find("z")
|};
  [%expect {|
    14
    hé
    wörld
    true
    Some(8)
    Some(9)
    Some(0)
    None
    |}]

let%expect_test "a slice out of bounds panics, as an index does" =
  run {|
fn main() = "Ren".slice(1, 4)
|};
  [%expect {|
    error: panic: slice 1 to 4 is out of bounds for a string of length 3
      ┌─ test.ren:1:13
    1 │ fn main() = "Ren".slice(1, 4)
      │             ^^^^^^^^^^^^^^^^^
    |}];
  run {|
fn main() = "Ren".slice(-1, 2)
|};
  [%expect {|
    error: panic: slice -1 to 2 is out of bounds for a string of length 3
      ┌─ test.ren:1:13
    1 │ fn main() = "Ren".slice(-1, 2)
      │             ^^^^^^^^^^^^^^^^^^
    |}];
  run {|
fn main() = "Ren".slice(2, 1)
|};
  [%expect {|
    error: panic: slice 2 to 1 ends before it starts
      ┌─ test.ren:1:13
    1 │ fn main() = "Ren".slice(2, 1)
      │             ^^^^^^^^^^^^^^^^^
    |}]

(* a slice that cut a character would make a string that isn't UTF-8 *)
let%expect_test "a slice inside a character panics" =
  run {|
fn main() = "né".slice(0, 2)
|};
  [%expect {|
    error: panic: slice 0 to 2 ends inside a character
      ┌─ test.ren:1:13
    1 │ fn main() = "né".slice(0, 2)
      │             ^^^^^^^^^^^^^^^^^
    |}];
  run {|
fn main() = "né".slice(2, 3)
|};
  [%expect {|
    error: panic: slice 2 to 3 starts inside a character
      ┌─ test.ren:1:13
    1 │ fn main() = "né".slice(2, 3)
      │             ^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "split, trim, starts_with and concat" =
  run
    {|
fn main() =
  print("a,b,,c".split(","))
  print("a, b".split(", "))
  print("abc".split(","))
  print("".split(","))
  print("ä→ö".split("→"))
  print("  hi there \t\n".trim())
  print("héllo".starts_with("hé"))
  print("héllo".starts_with("e"))
  print("".starts_with(""))
  "wör".concat("ld").concat("")
|};
  [%expect {|
    ["a", "b", "", "c"]
    ["a", "b"]
    ["abc"]
    [""]
    ["ä", "ö"]
    hi there
    true
    false
    true
    "wörld"
    |}]

let%expect_test "splitting on nothing panics" =
  run {|
fn main() = "abc".split("")
|};
  [%expect {|
    error: panic: `split` needs a separator that isn't empty
      ┌─ test.ren:1:13
    1 │ fn main() = "abc".split("")
      │             ^^^^^^^^^^^^^^^
    |}]

let%expect_test "a string's bytes, and back" =
  run
    {|
fn main() =
  let b = "hé".bytes()
  print(b)
  print(b.len())
  print(b == "hé".bytes())
  print(attempt Str.from_utf8(b))
  match Str.from_utf8("".bytes())
    s => s
    fail InvalidUtf8 => "not UTF-8"
|};
  [%expect {|
    <bytes 68 c3 a9>
    3
    true
    Ok("hé")
    ""
    |}]

(* No program can make bytes that aren't UTF-8 yet, until `Fs` reads
   them, so this asks the built-in itself. *)
let%expect_test "from_utf8 fails with InvalidUtf8" =
  let from_utf8 = Option.get (Ren.Prelude.find_fn "Str.from_utf8") in
  List.iter
    (fun b ->
      match from_utf8.eval [ Ren.Value.VBytes b ] with
      | v, _ -> print_endline (Ren.Value.show v)
      | exception Ren.Prelude.Fail err ->
          print_endline ("fails: " ^ Ren.Value.show err))
    [ "caf\xc3\xa9"; "caf\xc3"; "\xff"; "\xed\xa0\x80" ];
  [%expect {|
    "café"
    fails: InvalidUtf8
    fails: InvalidUtf8
    fails: InvalidUtf8
    |}]

let%expect_test "from_utf8 is fallible" =
  run {|
fn main() = Str.from_utf8("x".bytes())
|};
  [%expect {|
    error: `Str.from_utf8` can fail, and nothing handles it
      ┌─ test.ren:1:13
    1 │ fn main() = Str.from_utf8("x".bytes())
      │             ^^^^^^^^^^^^^^^^^^^^^^^^^^
      │             ------------- it can fail with `InvalidUtf8`
      help: pass the errors on with `try`, or handle them with `match`
    |}];
  types {|
fn decode(b: Bytes) = try Str.from_utf8(b)
fn main() = ()
|};
  [%expect {|
    fn decode(b: Bytes) -> Str ! InvalidUtf8
    fn main()
    |}]

let%expect_test "a path" =
  run
    {|
fn main() =
  let src = Path.of("src")
  print(src.join("main.ren").show())
  print(Path.of("src/").join("main.ren"))
  print(src.join("lib").join("a.ren"))
  print(src.join("/etc"))
  print(Path.of("").join("a"))
  src.show()
|};
  [%expect {|
    src/main.ren
    src/main.ren
    src/lib/a.ren
    /etc
    a
    "src"
    |}]

let%expect_test "a path isn't a string" =
  run {|
fn main() = Path.of("src").len()
|};
  [%expect {|
    error: `Path` has no method named `len`
      ┌─ test.ren:1:28
    1 │ fn main() = Path.of("src").len()
      │                            ^^^
      help: its methods: `join`, `show`
    |}];
  run {|
fn main() =
  let p: Path = "src"
  p
|};
  [%expect {|
    error: expected `Path`, found `Str`
      ┌─ test.ren:2:17
    2 │   let p: Path = "src"
      │                 ^^^^^
      = `Path`'s representation is private to `prelude`
      help: use a function from `prelude` to make or read one
    |}]

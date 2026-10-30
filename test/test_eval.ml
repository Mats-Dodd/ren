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
  run_error {|
fn main() = 10 / (5 - 5)
|};
  [%expect
    {|
    error: panic: division by zero
      ┌─ test.ren:1:13
    1 │ fn main() = 10 / (5 - 5)
      │             ^^^^^^^^^^^^
    |}]

let%expect_test "`/` and `%` round toward zero" =
  run
    {|
fn main() uses Console =
  print(-7 / 2)
  print(-7 % 2)
  print(7 / -2)
  print(-7.5 % 2.0)
  print(10 % (5 - 5))
|};
  [%expect
    {|
    -3
    -1
    -3
    -1.5
    error: panic: division by zero
      ┌─ test.ren:6:9
    6 │   print(10 % (5 - 5))
      │         ^^^^^^^^^^^^
    |}]

let%expect_test "infinity stays, and a NaN panics where it is shown, saying where it was made" =
  run
    {|
fn main() uses Console =
  let inf = 1.0 / 0.0
  print(inf > 1000000.0)
  print(-inf)
  print(inf - inf)
|};
  [%expect
    {|
    true
    -inf
    error: panic: `show` of a NaN made at test.ren:5:9
      ┌─ test.ren:5:3
    5 │   print(inf - inf)
      │   ^^^^^^^^^^^^^^^^
    |}]

let%expect_test "wrapping is a method" =
  run
    {|
fn main() uses Console =
  let big = 9223372036854775807
  print(big.wrapping_add(1))
  print((0 - big - 1).wrapping_sub(1))
  print(big.wrapping_mul(2))
  print((0 - big - 1).wrapping_neg())
|};
  [%expect
    {|
    -9223372036854775808
    9223372036854775807
    -2
    -9223372036854775808
    ()
    |}]

(* `hash` has no use in Ren until `Map` and `Set` (stage 9b), so the walk's
   is tested here: it agrees with `==`, by a key too *)
let%expect_test "a hash agrees with ==" =
  let open Ren in
  let email = Path.make "test" "Email" in
  let types = Walk.types_of [] in
  let cx : Walk.cx =
    {
      types;
      key =
        (fun p _ v ->
          match v with
          | Value.VStr s when p = email ->
              Some (Ty.str, Value.VStr (String.lowercase_ascii s))
          | _ -> None);
    }
  in
  let same t a b =
    Printf.printf "%b %b\n" (Walk.equal cx t a b)
      (Walk.hash cx t a = Walk.hash cx t b)
  in
  same Ty.float (VFloat 0.0) (VFloat (-0.0));
  same Ty.float (VFloat 1.5) (VFloat 2.5);
  same (Ty.array Ty.int)
    (Value.array [| VInt 1L; VInt 2L |])
    (Value.array [| VInt 1L; VInt 2L |]);
  same (Ty.Con (email, [])) (VStr "Ann@X") (VStr "ann@x");
  same (Ty.Con (email, [])) (VStr "Ann@X") (VStr "bob@x");
  (* an error says its payload's types itself, whatever type it's
     walked as, so its payload goes through their keys *)
  let bad t x = Value.VTag { name = "Bad"; args = [ x ]; tys = [ t ] } in
  same (Ty.Var 0) (bad Ty.float (VFloat (-0.0))) (bad Ty.float (VFloat 0.0));
  same (Ty.Var 0) (bad Ty.float (VFloat 1.0)) (bad Ty.float (VFloat 0.0));
  same (Ty.Var 0)
    (bad (Ty.Con (email, [])) (VStr "Ann@X"))
    (bad (Ty.Con (email, [])) (VStr "ann@x"));
  (* a value nothing says the type of is compared by its shape, and
     hashed by it, -0.0 and 0.0 the same there too *)
  let some x =
    Value.VCon { ty = Path.prelude "Option"; name = "Some"; args = [ x ] }
  in
  same (Ty.Var 0) (some (VFloat (-0.0))) (some (VFloat 0.0));
  same (Ty.Var 0) (some (VFloat 1.0)) (some (VFloat 0.0));
  [%expect
    {|
    true true
    false false
    true true
    true true
    false false
    true true
    false false
    true true
    true true
    false false
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
  let u = User { id: 1, plan: Pro(5) }
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
  let plan = Enterprise(42)
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
  print(describe(Some(500)))
  print(describe(None))
|};
  [%expect {|
    5
    100
    0
    ()
    |}]

(* lambdas *)

let%expect_test "blocks, and functions passed as arguments" =
  let src =
    {|
fn double(x) = x * 2

fn apply(o, f) =
  match o
    Some(v) => Some(f(v))
    None => None

fn main() =
  let n = 10
  print(apply(Some(5), fn(x) => x + n))
  print(apply(Some(5), double))
  let ignore = fn(_) => ()
  ignore(3)
|}
  in
  run src;
  [%expect {|
    Some(15)
    Some(10)
    ()
    |}];
  types src;
  [%expect
    {|
    fn double(x: Int) -> Int
    fn apply<T, U>(o: Option<T>, f: fn(T) -> U) -> Option<U>
    fn main() uses Console
    |}]

let%expect_test "a block can't be returned" =
  run
    {|
fn double(x) = x * 2
fn compose(f, g) = fn(x) => g(f(x))

fn main() = print(compose(double, double)(1))
|};
  [%expect
    {|
    error: a block can't be returned
      ┌─ test.ren:2:20
    2 │ fn compose(f, g) = fn(x) => g(f(x))
      │                    ^^^^^^^^^^^^^^^^ a block
      = a block lives only as long as the call it's passed to
      help: take the block's arguments as parameters too, and return what it gives
    |}]

let%expect_test "a function can't be printed" =
  run {|
fn double(x) = x * 2

fn main() = print(double)
|};
  [%expect
    {|
    error: a generic `T` can't be a block
      ┌─ test.ren:3:19
    3 │ fn main() = print(double)
      │                   ^^^^^^ a block
      = a type variable stands for data, which can be stored or returned
      help: pass a block only to a parameter written `fn(...)`
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
  let get = fn() => n                  // a block reads `n` when it runs
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
    2
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
  [%expect
    {|
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
  print(s[0..3])
  print(s[8..14])
  print(s[4..4] == "")
  print(s.index("w"))
  print(s.index("ö"))
  print(s.index(""))
  s.index("z")
|};
  [%expect
    {|
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
fn main() = "Ren"[1..4]
|};
  [%expect
    {|
    error: panic: slice 1 to 4 is out of bounds for a string of length 3
      ┌─ test.ren:1:13
    1 │ fn main() = "Ren"[1..4]
      │             ^^^^^^^^^^^
    |}];
  run {|
fn main() = "Ren"[-1..2]
|};
  [%expect
    {|
    error: panic: slice -1 to 2 is out of bounds for a string of length 3
      ┌─ test.ren:1:13
    1 │ fn main() = "Ren"[-1..2]
      │             ^^^^^^^^^^^^
    |}];
  run {|
fn main() = "Ren"[2..1]
|};
  [%expect
    {|
    error: panic: slice 2 to 1 ends before it starts
      ┌─ test.ren:1:13
    1 │ fn main() = "Ren"[2..1]
      │             ^^^^^^^^^^^
    |}]

(* a slice that cut a character would make a string that isn't UTF-8 *)
let%expect_test "a slice inside a character panics" =
  run {|
fn main() = "né"[0..2]
|};
  [%expect
    {|
    error: panic: slice 0 to 2 ends inside a character
      ┌─ test.ren:1:13
    1 │ fn main() = "né"[0..2]
      │             ^^^^^^^^^^^
    |}];
  run {|
fn main() = "né"[2..3]
|};
  [%expect
    {|
    error: panic: slice 2 to 3 starts inside a character
      ┌─ test.ren:1:13
    1 │ fn main() = "né"[2..3]
      │             ^^^^^^^^^^^
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
  [%expect
    {|
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
  [%expect
    {|
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
    fail InvalidUtf8(_, _) => "not UTF-8"
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
  List.iter
    (fun b ->
      match
        Ren.Builtins.run Ren.Intrinsic.Str_from_utf8 ~dicts:[] ~tys:[]
          ~made:(fun () -> 0)
          [ Ren.Value.VBytes b ]
      with
      | v, _ -> print_endline (Ren.Value.show v)
      | exception Ren.Builtins.Fail err ->
          print_endline ("fails: " ^ Ren.Value.show err))
    [ "caf\xc3\xa9"; "caf\xc3"; "\xff"; "\xed\xa0\x80" ];
  [%expect
    {|
    "café"
    fails: InvalidUtf8(3, true)
    fails: InvalidUtf8(0, false)
    fails: InvalidUtf8(0, false)
    |}]

let%expect_test "from_utf8 is fallible" =
  run {|
fn main() = Str.from_utf8("x".bytes())
|};
  [%expect
    {|
    error: `Str.from_utf8` can fail, and nothing handles it
      ┌─ test.ren:1:13
    1 │ fn main() = Str.from_utf8("x".bytes())
      │             ^^^^^^^^^^^^^^^^^^^^^^^^^^
      │             ------------- it can fail with `InvalidUtf8(Int, Bool)`
      help: pass the errors on with `try`, or handle them with `match`
    |}];
  types {|
fn decode(b: Bytes) = try Str.from_utf8(b)
fn main() = ()
|};
  [%expect {|
    fn decode(b: Bytes) -> Str ! InvalidUtf8(Int, Bool)
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
  [%expect
    {|
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
  [%expect
    {|
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
  [%expect
    {|
    error: expected `Path`, found `Str`
      ┌─ test.ren:2:17
    2 │   let p: Path = "src"
      │                 ^^^^^
      = `Path`'s representation is private to `prelude`
      help: use a function from `prelude` to make or read one
    |}]

(* ---- calls, deep and long ---- *)

let%expect_test "a loop written as recursion runs in constant stack" =
  run
    {|
fn count(n: Int, acc: Int) -> Int =
  if n == 0 then acc else count(n - 1, acc + n)
fn main() -> Int = count(1000000, 0)
|};
  [%expect {| 500000500000 |}]

let%expect_test "recursion with no end panics, and soon" =
  run_error
    {|
fn down(n: Int) -> Int = 1 + down(n + 1)
fn main() -> Int = down(0)
|};
  [%expect
    {|
    error: panic: the stack overflowed: a function called itself too deeply
      ┌─ test.ren:2:4
    2 │ fn main() -> Int = down(0)
      │    ^^^^
    |}]

let%expect_test "an associated value that calls too deeply panics" =
  run_error
    {|
fn deep(n: Int) -> Int = if n == 0 then 0 else 1 + deep(n - 1)
type Box = { v: Int }
  let big: Box = Box { v: deep(200000) }
fn main() -> Int = Box.big.v
|};
  [%expect
    {|
    error: panic: the stack overflowed: a function called itself too deeply
      ┌─ test.ren:3:7
    3 │   let big: Box = Box { v: deep(200000) }
      │       ^^^
    |}]

let%expect_test "`ren test` reports a value that calls too deeply as a panic" =
  (* its values are made before any test runs, outside them all *)
  test
    {|
fn deep(n: Int) -> Int = if n == 0 then 0 else 1 + deep(n - 1)
pub type Box = { v: Int }
  pub let big: Box = Box { v: deep(200000) }
test "uses big" =
  assert Box.big.v == 0
|};
  [%expect
    {|
    error: panic: the stack overflowed: a function called itself too deeply
      ┌─ test.ren:3:11
    3 │   pub let big: Box = Box { v: deep(200000) }
      │           ^^^
    |}]

let%expect_test "a call that ends a function still writes back what it changed"
    =
  run
    {|
fn len_of(xs: Array<Int>) -> Int = xs.len()
fn add_two(inout xs: Array<Int>) -> Int =
  &xs.push(1)
  &xs.push(2)
  len_of(xs)
fn main() =
  var xs = [0]
  print(add_two(&xs))
  print(xs)
|};
  [%expect {|
    3
    [0, 1, 2]
    ()
    |}]

let%expect_test "a panic in a built-in called last is where it's called" =
  run_error
    {|
fn cut(s: Str) -> Str = s[3..1]
fn main() = print(cut("abc"))
|};
  [%expect
    {|
    error: panic: slice 3 to 1 ends before it starts
      ┌─ test.ren:1:25
    1 │ fn cut(s: Str) -> Str = s[3..1]
      │                         ^^^^^^^
    |}]

(* An `Int` is 64 bits, and overflowing it panics (operators.md, "`Int`
   and `Float`"): the help names the method that wraps. *)
let%expect_test "an Int overflowing panics" =
  run
    {|
fn main() =
  let n = 9223372036854775807
  print(n - 1)
  print(n.wrapping_add(1))
  print(n + 1)
|};
  [%expect
    {|
    9223372036854775806
    -9223372036854775808
    error: panic: `+` overflowed: 9223372036854775807 + 1
      ┌─ test.ren:5:9
    5 │   print(n + 1)
      │         ^^^^^
      help: if wrapping is what you mean, write `n +% 1`
    |}];
  run {|
fn main() = print(-(-9223372036854775808))
|};
  [%expect
    {|
    error: panic: `-` overflowed: -(-9223372036854775808)
      ┌─ test.ren:1:19
    1 │ fn main() = print(-(-9223372036854775808))
      │                   ^^^^^^^^^^^^^^^^^^^^^^^
      help: if wrapping is what you mean, write `(-9223372036854775808).wrapping_neg()`
    |}];
  run {|
fn main() =
  var n = 4611686018427387904
  n *= 2
  print(n)
|};
  [%expect
    {|
    error: panic: `*` overflowed: 4611686018427387904 * 2
      ┌─ test.ren:3:3
    3 │   n *= 2
      │   ^^^^^^
      help: if wrapping is what you mean, write `n *%= 2`
    |}];
  run {|
fn main() = print(-9223372036854775808 / -1)
|};
  [%expect
    {|
    error: panic: `/` overflowed: -9223372036854775808 / -1
      ┌─ test.ren:1:19
    1 │ fn main() = print(-9223372036854775808 / -1)
      │                   ^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

(* The smallest `Int` is written whole, though 2^63 alone doesn't fit
   (Parser.too_big). *)
let%expect_test "the smallest Int is a literal" =
  run
    {|
fn main() =
  let n = -9223372036854775808
  print(n)
  print(n == -9223372036854775807 - 1)
  match n
    -9223372036854775808 => print("the smallest")
    _ => print("another")
|};
  [%expect {|
    -9223372036854775808
    true
    the smallest
    ()
    |}];
  run {|
fn main() = print(1 - 9223372036854775808)
|};
  [%expect
    {|
    error: this number is too big to fit in an `Int`
      ┌─ test.ren:1:23
    1 │ fn main() = print(1 - 9223372036854775808)
      │                       ^^^^^^^^^^^^^^^^^^^
      help: the smallest `Int` is `-9223372036854775808`
    |}]

(* A Float is shown as a literal that reads back as it: a literal has no
   exponent, so neither does what's shown (Token.show_float). *)
let%expect_test "a big or small Float is shown without an exponent" =
  run
    {|
fn main() =
  print(100000000.0 * 1000000000000.0)
  print(0.0 - 1.5 / 10000000000.0)
  print(100000000000000000000.0 == 100000000.0 * 1000000000000.0)
  print(-0.00000000015 == 0.0 - 1.5 / 10000000000.0)
|};
  [%expect
    {|
    100000000000000000000.0
    -0.00000000015
    true
    true
    ()
    |}]

let%expect_test "a NaN is carried and panics where it is observed" =
  run
    {|
fn main() =
  print(1.5 * 2.0)
  print(0.1 + 0.2)
  print(1.0 / 0.0)
  print(-0.0 == 0.0)
  print(2.0.sqrt())
  print(Float.of(3) / 2.0)
  print(2.5.round())
  print((0.0 - 2.5).truncate())
  print(0.0 / 0.0)
|};
  [%expect
    {|
    3.0
    0.30000000000000004
    inf
    true
    1.4142135623730951
    1.5
    3
    -2
    error: panic: `show` of a NaN made at test.ren:10:9
       ┌─ test.ren:10:3
    10 │   print(0.0 / 0.0)
       │   ^^^^^^^^^^^^^^^^
    |}];
  run {|
fn main() = print((0.0 - 1.0).sqrt())
|};
  [%expect
    {|
    error: panic: `show` of a NaN made at test.ren:1:19
      ┌─ test.ren:1:13
    1 │ fn main() = print((0.0 - 1.0).sqrt())
      │             ^^^^^^^^^^^^^^^^^^^^^^^^^
    |}];
  run {|
fn main() = print((1.0 / 0.0).round())
|};
  [%expect
    {|
    error: panic: `round` of inf doesn't fit in an `Int`
      ┌─ test.ren:1:19
    1 │ fn main() = print((1.0 / 0.0).round())
      │                   ^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "a generic function shows what its type variables stand for" =
  (* each is passed, hidden, by its caller: through a closure it makes, a
     function used as a value, a handler it installs, and a
     type's own `show`, of a type that's generic too *)
  run
    {|
type Acc = { id: Int }
type Box<T> = { v: T }
  fn show(self) -> Str = show(["box", show(self.v)])
dep Log =
  put: fn(s: Str)

fn sh<T>(x: T) -> Str = show(x)
fn later<T>(x: T) -> Str = run_it(fn() => show([x]))
fn run_it(f: fn() -> Str) -> Str = try f()
fn apply<A, B>(f: fn(A) -> B, x: A) -> B = try f(x)
fn logged<T>(x: T) uses Console =
  with logging(x) in
    Log.put("put")

fn main() uses Console =
  let a = Acc { id: 1 }
  print(sh(a))
  print(later(a))
  print(apply(sh, Some(a)))
  logged(a)
  print(Box { v: a })
  print(sh(Box { v: Box { v: "s" } }))

handler logging(x) for Log =
  put(s) => print([show(x), s])
|};
  [%expect
    {|
    Acc { id: 1 }
    [Acc { id: 1 }]
    Some(Acc { id: 1 })
    ["Acc { id: 1 }", "put"]
    ["box", "Acc { id: 1 }"]
    ["box", "Box { v: \"s\" }"]
    ()
    |}]

let%expect_test
    "an `assert` in a generic function shows its sides by their type" =
  run
    {|
type Acc = { id: Int }
fn same<T>(x: T, y: T) = assert x == y
fn main() = same(Some(Acc { id: 3 }), Some(Acc { id: 4 }))
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:2:33
    2 │ fn same<T>(x: T, y: T) = assert x == y
      │                                 ^^^^^^
      = left:  Some(Acc { id: 3 })
      = right: Some(Acc { id: 4 })
    |}]

(* ---- equality, through requirements' dictionaries ---- *)

let%expect_test "a generic function compares through the dictionary it's given"
    =
  (* `same` is compiled once, and given `eq` of whatever it's used at:
     `Int`'s, `Str`'s, or one derived from a type's declaration, which
     `both` builds from the one it was given for its own `U` *)
  run
    {|
type Box<T> = { v: T }
fn same(a, b) = a == b
fn differ(a, b) = a != b
fn both<U>(a: U, b: U) -> Bool = same(a, b) && same(Box { v: b }, Box { v: a })
fn main() uses Console =
  print([same(1, 1), same(1, 2), same("a", "a"), same(true, false)])
  print([same((), ()), differ("a", "b"), differ(3, 3)])
  print([both(1, 1), both(1, 2), both(Box { v: "a" }, Box { v: "a" })])
  print([both([1, 2], [1, 2]), both([1, 2], [1]), both([[1]], [[2]])])
  print([same(Some(1), Some(1)), same(Some(1), None)])
|};
  [%expect
    {|
    [true, false, true, false]
    [true, true, false]
    [true, false, true]
    [true, false, false]
    [true, false]
    ()
    |}]

let%expect_test "nested records, sums and arrays are compared field by field" =
  run
    {|
type Point = { x: Int, y: Int }
type Shape =
  | Dot(at: Point)
  | Line { from: Point, to: Point }
  | Many(shapes: Array<Shape>)
type Tree<T> =
  | Leaf
  | Node { left: Tree<T>, value: T, right: Tree<T> }
type Tagged<T> = { tag: Str, items: Array<Option<T>> }
fn same(a, b) = a == b
fn leaf(x) = Node { left: Leaf, value: x, right: Leaf }
fn main() uses Console =
  let p = Point { x: 1, y: 2 }
  let q = Point { x: 1, y: 3 }
  print([same(Dot(p), Dot(p)), same(Dot(p), Dot(q)), same(Dot(p), Line { from: p, to: p })])
  let many = Many([Dot(p), Many([Line { from: p, to: q }])])
  print(same(many, Many([Dot(p), Many([Line { from: p, to: q }])])))
  print(same(many, Many([Dot(p), Many([Line { from: q, to: p }])])))
  let left = Node { left: leaf(1), value: 2, right: Leaf }
  print([same(leaf(p), leaf(p)), same(left, Node { left: Leaf, value: 2, right: leaf(1) })])
  let t = Tagged { tag: "a", items: [Some(leaf("x")), None] }
  let u = Tagged { tag: "a", items: [Some(leaf("y")), None] }
  print([same(t, t), same(t, u)])
  let b = Tagged { tag: "b", items: [Some(1)] }
  print(b == Tagged { tag: "b", items: [Some(1)] })
|};
  [%expect
    {|
    [true, false, false]
    true
    false
    [true, false]
    [true, false]
    true
    ()
    |}]

let%expect_test "Results are compared with their errors' payloads" =
  run
    {|
type Point = { x: Int, y: Int }
fn find(n: Int) -> Int ! Short(Point) | Gone =
  if n > 1 then fail Short(Point { x: n, y: 0 })
  else if n == 1 then fail Gone
  else 0
fn same(a, b) = a == b
fn count<T>(xs: Array<T>, x: T) -> Int =
  let is = fn(y: T) => y == x
  var n = 0
  for y in xs
    if is(y) then n += 1
  n
fn main() uses Console =
  let short2 = attempt find(2)
  let gone = attempt find(1)
  print([same(short2, attempt find(2)), same(short2, attempt find(3))])
  print([same(gone, short2), same(attempt find(0), attempt find(0))])
  print(short2 != gone)
  print(count([short2, gone, short2, attempt find(0)], attempt find(2)))
|};
  [%expect {|
    [true, false]
    [false, true]
    true
    2
    ()
    |}]

let%expect_test "an `assert ==` in a generic function uses its dictionary" =
  run_error
    {|
type Box<T> = { v: T }
fn check<T>(a: T, b: T) =
  assert a == b
fn main() =
  check(Box { v: [Some(1)] }, Box { v: [Some(1)] })
  check(Box { v: [Some(1)] }, Box { v: [None] })
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:3:10
    3 │   assert a == b
      │          ^^^^^^
      = left:  Box { v: [Some(1)] }
      = right: Box { v: [None] }
    |}]

let%expect_test "== can't panic" =
  (* comparing anything with a function in it, a handler, or an
     implementation of a dependency, directly or through a generic
     function, is an error before the program runs, so the interpreter
     never meets one *)
  let lacks src =
    match Ren.Driver.check ~file src with
    | _ -> raise (No_error "expected `==` to be refused")
    | exception e
      when Ren.Driver.render_error ~sources:(fun _ -> None) e <> None ->
        print_endline "refused"
  in
  lacks "fn inc(x: Int) -> Int = x + 1\nfn main() = inc == inc";
  lacks
    "fn same(a, b) = a == b\n\
     fn inc(x: Int) -> Int = x + 1\n\
     fn main() = same([Some(inc)], [None])";
  lacks
    "type R = { f: Clock }\n\
     fn same(a, b) = a == b\n\
     fn main() = same(Ok(R { f: Clock.frozen(Time.epoch) }), Err(Gone))";
  lacks
    "dep D =\n\
    \  get: fn() -> Int\n\
     handler d() for D =\n\
    \  get() => 1\n\
     fn main() = d() == d()";
  (* and a tag holding one, in the errors of a function given to one that
     compares what it fails with *)
  lacks
    "fn same(a, b) = a == b\n\
     fn bad() = if true then fail Bad(fn() => 1) else 1\n\
     fn twice(g) = same(attempt g(), attempt g())\n\
     fn main() = twice(bad)";
  lacks
    "fn cmp(g) = (attempt g()) == (attempt g())\n\
     fn bad() = if true then fail Bad(fn() => 1) else 1\n\
     fn main() = cmp(bad)";
  [%expect
    {|
    refused
    refused
    refused
    refused
    refused
    refused
    |}];
  (* nor an opaque type of another module that's represented as one,
     which its interface says, though it hides the representation *)
  check_error_files
    [
      ( "main.ren",
        {|
import a
fn same(x, y) = x == y
fn main() = same(a.mk(), a.mk()) || a.Id.of(1) == a.Id.of(1)
|}
      );
      ( "a.ren",
        {|
pub type F = opaque Clock
pub fn mk() -> F = Clock.frozen(Time.epoch)
pub type Pair = { n: Int, f: F }
pub type Id = opaque Pair
  pub fn of(n: Int) -> Id = Pair { n: n, f: mk() }
|}
      );
    ];
  [%expect
    {|
    error: `a.F` has no `==`, which `same` needs
      ┌─ main.ren:3:18
    3 │ fn main() = same(a.mk(), a.mk()) || a.Id.of(1) == a.Id.of(1)
      │                  ^^^^^^
      = a type with a function in it has no `==` or `hash`
      = `a.F` is opaque, and its module represents it with a function in it
      help: give `same` something it can compare, without a function in it

    error: `a.Id` has no `==`
      ┌─ main.ren:3:37
    3 │ fn main() = same(a.mk(), a.mk()) || a.Id.of(1) == a.Id.of(1)
      │                                     ^^^^^^^^^^^^^^^^^^^^^^^^
      = a type with a function in it has no `==` or `hash`
      = `a.Id` is opaque, and its module represents it with a function in it
      help: compare something its module's functions tell you about it instead
    |}]

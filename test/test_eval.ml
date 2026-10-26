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
  List.iter
    (fun b ->
      match Ren.Builtins.run Ren.Intrinsic.Str_from_utf8 [ Ren.Value.VBytes b ] with
      | v, _ -> print_endline (Ren.Value.show v)
      | exception Ren.Builtins.Fail err ->
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

(* ---- calls, deep and long ---- *)

let%expect_test "a loop written as recursion runs in constant stack" =
  run {|
fn count(n: Int, acc: Int) -> Int =
  if n == 0 then acc else count(n - 1, acc + n)
fn main() -> Int = count(1000000, 0)
|};
  [%expect {| 500000500000 |}]

let%expect_test "recursion with no end panics, and soon" =
  run_error {|
fn down(n: Int) -> Int = 1 + down(n + 1)
fn main() -> Int = down(0)
|};
  [%expect {|
    error: panic: the stack overflowed: a function called itself too deeply
      ┌─ test.ren:2:4
    2 │ fn main() -> Int = down(0)
      │    ^^^^
    |}]

let%expect_test "an associated value that calls too deeply panics" =
  run_error {|
fn deep(n: Int) -> Int = if n == 0 then 0 else 1 + deep(n - 1)
type Box = { v: Int }
  let big: Box = Box { v: deep(200000) }
fn main() -> Int = Box.big.v
|};
  [%expect {|
    error: panic: the stack overflowed: a function called itself too deeply
      ┌─ test.ren:3:7
    3 │   let big: Box = Box { v: deep(200000) }
      │       ^^^
    |}]

let%expect_test "`ren test` reports a value that calls too deeply as a panic" =
  (* its values are made before any test runs, outside them all *)
  test {|
fn deep(n: Int) -> Int = if n == 0 then 0 else 1 + deep(n - 1)
type Box = { v: Int }
  let big: Box = Box { v: deep(200000) }
test "uses big" =
  assert Box.big.v == 0
|};
  [%expect {|
    error: panic: the stack overflowed: a function called itself too deeply
      ┌─ test.ren:3:7
    3 │   let big: Box = Box { v: deep(200000) }
      │       ^^^
    |}]

let%expect_test "a call that ends a function still writes back what it changed" =
  run {|
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
  run_error {|
fn cut(s: Str) -> Str = s.slice(3, 1)
fn main() = print(cut("abc"))
|};
  [%expect {|
    error: panic: slice 3 to 1 ends before it starts
      ┌─ test.ren:1:25
    1 │ fn cut(s: Str) -> Str = s.slice(3, 1)
      │                         ^^^^^^^^^^^^^
    |}]

(* Overflow panics in stage 9 (operators.md, "`Int` and `Float`"); until
   then an `Int` is OCaml's, 63 bits, and wraps. *)
let%expect_test "an Int wraps at 63 bits, for now" =
  run {|
fn main() =
  print(4611686018427387903 + 1)
  print(0 - 4611686018427387903 - 2)
|};
  [%expect {|
    -4611686018427387904
    4611686018427387903
    ()
    |}]

let%expect_test "a generic function shows what its type variables stand for" =
  (* each is passed, hidden, by its caller: through a closure it makes, a
     function used as a value, a record of lambdas it installs, and a
     type's own `show`, of a type that's generic too *)
  run
    {|
type Acc = { id: Int }
type Box<T> = { v: T }
  fn show(self) -> Str = show(["box", show(self.v)])
dep Log =
  put: fn(s: Str)

fn sh<T>(x: T) -> Str = show(x)
fn later<T>(x: T) -> fn() -> Str = fn() => show([x])
fn apply<A, B>(f: fn(A) -> B, x: A) -> B = try f(x)
fn logged<T>(x: T) uses Console =
  with Log { put: fn(s) => print([show(x), s]) } in
    Log.put("put")

fn main() uses Console =
  let a = Acc { id: 1 }
  print(sh(a))
  print(later(a)())
  print(apply(sh, Some(a)))
  logged(a)
  print(Box { v: a })
  print(sh(Box { v: Box { v: "s" } }))
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

let%expect_test "an `assert` in a generic function shows its sides by their type" =
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

let%expect_test "a generic associated value knows nothing of its type" =
  (* it's made once, when the program starts, with nothing to say what
     `T` stands for, so a value of it is shown by its shape alone, whether
     through `show` itself or a lambda that calls it (compiler.md,
     "Deviations") *)
  run
    {|
type Acc = { id: Int }
type Box<T> = { v: T }
  pub let lam: fn(T) -> Str = fn(x) => show(x)
  pub let shower: fn(T) -> Str = show

fn main() uses Console =
  print(Box.lam(Acc { id: 1 }))
  print(Box.shower(Acc { id: 1 }))
|};
  [%expect {|
    { id: 1 }
    { id: 1 }
    ()
    |}]

(* ---- equality, through requirements' dictionaries ---- *)

let%expect_test "a generic function compares through the dictionary it's given" =
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
  let f = same
  print([f(Some(1), Some(1)), f(Some(1), None)])
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
  | Line(from: Point, to: Point)
  | Many(shapes: Array<Shape>)
type Tree<T> =
  | Leaf
  | Node(left: Tree<T>, value: T, right: Tree<T>)
type Tagged<T> = { tag: Str, items: Array<Option<T>> }
fn same(a, b) = a == b
fn leaf(x) = Node(Leaf, x, Leaf)
fn main() uses Console =
  let p = Point { x: 1, y: 2 }
  let q = Point { x: 1, y: 3 }
  print([same(Dot(p), Dot(p)), same(Dot(p), Dot(q)), same(Dot(p), Line(p, p))])
  let many = Many([Dot(p), Many([Line(p, q)])])
  print(same(many, Many([Dot(p), Many([Line(p, q)])])))
  print(same(many, Many([Dot(p), Many([Line(q, p)])])))
  let left = Node(leaf(1), 2, Leaf)
  print([same(leaf(p), leaf(p)), same(left, Node(Leaf, 2, leaf(1)))])
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
  [%expect
    {|
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

let%expect_test "where nothing says what T is, values compare by shape" =
  (* a generic associated value is made once, with no dictionary for its
     `T` (core.ml, [Global_value]), and so is given one that compares by
     the values' shape, which only an opaque type of another module can
     make reach a function: inference rules out anything else *)
  run
    {|
type Point = { x: Int, y: Int }
type Box<T> = { v: T }
  pub let eqf: fn(T, T) -> Bool = fn(a, b) => a == b
fn main() uses Console =
  print([Box.eqf(1, 1), Box.eqf(Point { x: 1, y: 2 }, Point { x: 1, y: 2 })])
  print([Box.eqf([Some("a")], [Some("b")]), Box.eqf(Ok(1), Err(Oops))])
|};
  [%expect
    {|
    [true, true]
    [false, false]
    ()
    |}]

let%expect_test "== can't panic, but through another module's opaque type" =
  (* comparing anything with a function in it, a handler, or an
     implementation of a dependency, directly or through a generic
     function, is an error before the program runs, so the interpreter
     never meets one; the one way it still can is an opaque type of
     another module that's represented as one, which inference can't look
     inside (compiler.md, "Deviations") *)
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
    "type R = { f: fn() -> Int }\n\
     fn same(a, b) = a == b\n\
     fn main() = same(Ok(R { f: fn() => 1 }), Err(Gone))";
  lacks
    "dep D =\n\
    \  get: fn() -> Int\n\
     fn d() = D { get: fn() => 1 }\n\
     fn main() = d() == d()";
  [%expect {|
    refused
    refused
    refused
    refused
    |}];
  run_files
    [
      ( "main.ren",
        {|
import a
fn same(x, y) = x == y
fn main() = same(a.mk(), a.mk())
|}
      );
      ("a.ren", {|
pub type F = opaque fn(Int) -> Int
pub fn mk() -> F = fn(x: Int) => x
|});
    ];
  [%expect {|
    error: panic: these can't be compared: they're of an opaque type from another module that's represented as a function, or holds one, and a function has no `==`. Compare something else about them instead
      ┌─ main.ren:2:17
    2 │ fn same(x, y) = x == y
      │                 ^^^^^^
    |}]

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
    { id: 7, plan: Enterprise(42) }
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
    fn apply<T, U>(o: Option<T>, f: fn(T) -> U) -> Option<U>
    fn compose<T, U, V>(f: fn(T) -> U ! ..e uses ..d, g: fn(U) -> V ! ..e uses ..d) -> (fn(T) -> V ! ..e uses ..d)
    fn main() uses Io
    |}]

let%expect_test "trailing lambdas" =
  run
    {|
fn twice(f) =
  f()
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
    { x: 11, y: 0 }
    { x: 1, y: 2 }
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
    [{ x: 1, y: 5 }, { x: 10, y: 2 }]
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

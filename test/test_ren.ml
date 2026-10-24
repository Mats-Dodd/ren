(* Expect tests. Each test prints something, and [%expect] holds what it
   should print. Workflow:

     dune runtest     shows a diff if output changed
     dune promote     accepts the new output into this file

   Leave [%expect {||}] empty when writing a new test, then promote. *)

open Ren

let file = "test.ren"

(* Test sources start with a newline for readability; drop it so line numbers
   in error messages match what you'd see in a real file. *)
let clean src =
  if String.starts_with ~prefix:"\n" src then
    String.sub src 1 (String.length src - 1)
  else src

let report src f =
  try f () with Diag.Error d -> print_string (Diag.render ~src d)

let run src =
  let src = clean src in
  report src (fun () -> print_endline (Eval.show_value (Driver.run ~file src)))

let tokens src =
  let src = clean src in
  report src (fun () ->
      print_endline (Driver.dump_tokens (Driver.tokens ~file src)))

let ast src =
  let src = clean src in
  report src (fun () ->
      List.iter
        (fun f -> print_endline (Ast.show_item f))
        (Driver.parse ~file src))

let types src =
  let src = clean src in
  report src (fun () -> List.iter print_endline (Driver.types ~file src))

(* ---- running programs ---- *)

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

(* ---- lexing and parsing ---- *)

let%expect_test "layout tokens" =
  tokens {|
fn f() =
  let x = 1
  x
fn g() = 2
|};
  [%expect
    {| FN (IDENT "f") LPAREN RPAREN EQ INDENT LET (IDENT "x") EQ (INT 1) NEWLINE (IDENT "x") DEDENT NEWLINE FN (IDENT "g") LPAREN RPAREN EQ (INT 2) EOF |}]

let%expect_test "precedence and associativity" =
  ast {|
fn main() = 1 + 2 * 3 - -4 / 2 < 10 - 3 - 2
|};
  [%expect
    {| (fn main () (< (- (+ 1 (* 2 3)) (/ (neg 4) 2)) (- (- 10 3) 2))) |}]

(* ---- errors ---- *)

let%expect_test "chained comparison" =
  ast {|
fn main() = 1 < 2 < 3
|};
  [%expect
    {|
    error: comparisons can't be chained
      ┌─ test.ren:1:19
    1 │ fn main() = 1 < 2 < 3
      │                   ^
      help: split it into two comparisons
    |}]

let%expect_test "if without else" =
  ast {|
fn main() =
  if true then 1
|};
  [%expect
    {|
    error: this `if` has no `else`
      ┌─ test.ren:2:3
    2 │   if true then 1
      │   ^^
      help: add an `else` branch: `if` produces a value, so both branches are needed
    |}]

let%expect_test "block ending in let" =
  ast {|
fn main() =
  let x = 1
|};
  [%expect
    {|
    error: this block ends with a `let`, so it has no value
      ┌─ test.ren:2:7
    2 │   let x = 1
      │       ^
      help: add the value this block should produce as its last line
    |}]

let%expect_test "bad dedent" =
  ast {|
fn main() =
    let x = 1
  x
|};
  [%expect
    {|
    error: this line's indentation doesn't line up with any enclosing block
      ┌─ test.ren:3:3
    3 │   x
      │   ^
      help: indent it to match the lines above it
    |}]

let%expect_test "unknown function" =
  run {|
fn main() = fbi(3)
|};
  [%expect
    {|
    error: there's no function named `fbi`
      ┌─ test.ren:1:13
    1 │ fn main() = fbi(3)
      │             ^^^
    |}]

let%expect_test "wrong number of arguments" =
  run {|
fn add(a: Int, b: Int) -> Int = a + b
fn main() = add(1)
|};
  [%expect
    {|
    error: `add` takes 2 arguments but was given 1
      ┌─ test.ren:2:13
    2 │ fn main() = add(1)
      │             ^^^^^^
    |}]

let%expect_test "type mismatch" =
  run {|
fn main() = 1 + true
|};
  [%expect
    {|
    error: expected `Int`, found `Bool`
      ┌─ test.ren:1:17
    1 │ fn main() = 1 + true
      │                 ^^^^
      = `+` works on `Int`s
    |}]

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

let%expect_test "missing main" =
  run {|
fn helper() = 1
|};
  [%expect
    {|
    error: this program has no `main` function
      ┌─ test.ren:1:1
    1 │ fn helper() = 1
      │ ^
      help: add `fn main() = ...`, which is where the program starts
    |}]

(* ---- Stage 2: records, sum types, match ---- *)

let plan_types =
  {|
type Plan =
  | Free
  | Pro(seats: Int)
  | Enterprise(contract: Int)

type User = { id: Int, plan: Plan }
|}

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

let%expect_test "ast of a type and a match" =
  ast
    {|
type Shape = | Circle(r: Int) | Square(side: Int)
fn area(s: Shape) -> Int =
  match s
    Circle(r) if r > 0 => 3 * r * r
    Square(n) => n * n
    _ => 0
|};
  [%expect
    {|
    (type Shape (Circle r:Int) (Square side:Int))
    (fn area (s) (match s (Circle(r) if (> r 0) => (* (* 3 r) r)) (Square(n) => (* n n)) (_ => 0)))
    |}]

(* exhaustiveness: the Stage 2 milestone *)

let%expect_test "missing case" =
  run
    (plan_types
   ^ {|
fn seat_limit(p: Plan) -> Int =
  match p
    Free       => 1
    Pro(seats) => seats

fn main() -> Int = seat_limit(Free)
|}
    );
  [%expect
    {|
    error: this `match` doesn't handle every `Plan`
      ┌─ test.ren:9:3
    9 │   match p
      │   ^^^^^
      = missing: Enterprise(_)
      help: add an arm for `Enterprise(_)`, or a `_ =>` arm for the rest
    |}]

let%expect_test "several missing cases" =
  run (plan_types ^ {|
fn main() -> Int =
  match Free
    Free => 1
|});
  [%expect
    {|
    error: this `match` doesn't handle every `Plan`
      ┌─ test.ren:9:3
    9 │   match Free
      │   ^^^^^
      = missing: Pro(_), Enterprise(_)
      help: add an arm for `Pro(_)`, or a `_ =>` arm for the rest
    |}]

let%expect_test "missing nested case" =
  run
    (plan_types
   ^ {|
fn f(o: Option<Plan>) -> Int =
  match o
    Some(Free) => 1
    Some(Pro(_)) => 2
    None => 0

fn main() -> Int = f(None)
|}
    );
  [%expect
    {|
    error: this `match` doesn't handle every `Option`
      ┌─ test.ren:9:3
    9 │   match o
      │   ^^^^^
      = missing: Some(Enterprise(_))
      help: add an arm for `Some(Enterprise(_))`, or a `_ =>` arm for the rest
    |}]

let%expect_test "guarded arms don't count" =
  run
    (plan_types
   ^ {|
fn f(p: Plan) -> Int =
  match p
    Free => 0
    Pro(n) if n > 1 => n
    Enterprise(_) => 1

fn main() -> Int = f(Free)
|}
    );
  [%expect
    {|
    error: this `match` doesn't handle every `Plan`
      ┌─ test.ren:9:3
    9 │   match p
      │   ^^^^^
      = missing: Pro(_)
      = arms with an `if` guard don't count, since the guard may be false
      help: add an arm for `Pro(_)`, or a `_ =>` arm for the rest
    |}]

let%expect_test "Int and Bool matches" =
  run
    {|
fn f(n: Int) -> Int =
  match n
    0 => 1
    -1 => 2

fn main() -> Int = f(0)
|};
  [%expect
    {|
    error: this `match` doesn't handle every `Int`
      ┌─ test.ren:2:3
    2 │   match n
      │   ^^^^^
      = missing: _
      help: add a `_ =>` arm to cover the remaining values
    |}];
  run {|
fn main() -> Int =
  match true
    true => 1
|};
  [%expect
    {|
    error: this `match` doesn't handle every `Bool`
      ┌─ test.ren:2:3
    2 │   match true
      │   ^^^^^
      = missing: false
      help: add an arm for `false`, or a `_ =>` arm for the rest
    |}];
  run {|
fn main() -> Int =
  match 3 > 2
    true => 1
    false => 0
|};
  [%expect {| 1 |}]

let%expect_test "arm that can never match" =
  run
    (plan_types ^ {|
fn main() -> Int =
  match Free
    _ => 0
    Free => 1
|});
  [%expect
    {|
    error: this arm can never match
       ┌─ test.ren:11:5
    11 │     Free => 1
       │     ^^^^
       help: the arms above already match everything this one does
    |}];
  run
    (plan_types
   ^ {|
fn main() -> Int =
  match Pro(3)
    Pro(_) => 0
    Pro(5) => 1
    _ => 2
|}
    );
  [%expect
    {|
    error: this arm can never match
       ┌─ test.ren:11:5
    11 │     Pro(5) => 1
       │     ^^^^^^
       help: the arms above already match everything this one does
    |}]

(* name and shape errors *)

let%expect_test "unknown constructor" =
  run (plan_types ^ {|
fn main() = print(Basic)
|});
  [%expect
    {|
    error: there's no constructor named `Basic`
      ┌─ test.ren:8:19
    8 │ fn main() = print(Basic)
      │                   ^^^^^
    |}];
  run
    (plan_types
   ^ {|
fn main() -> Int =
  match Free
    Basic => 1
    _ => 0
|});
  [%expect
    {|
    error: there's no constructor named `Basic`
       ┌─ test.ren:10:5
    10 │     Basic => 1
       │     ^^^^^
    |}]

let%expect_test "constructor arity and labels" =
  run (plan_types ^ {|
fn main() = print(Pro(1, 2))
|});
  [%expect
    {|
    error: `Pro` has 1 field but was given 2
      ┌─ test.ren:8:19
    8 │ fn main() = print(Pro(1, 2))
      │                   ^^^^^^^^^
      help: its field: `seats`
    |}];
  run (plan_types ^ {|
fn main() = print(Free(1))
|});
  [%expect
    {|
    error: `Free` has 0 fields but was given 1
      ┌─ test.ren:8:19
    8 │ fn main() = print(Free(1))
      │                   ^^^^^^^
      help: write `Free` with no parentheses
    |}];
  run (plan_types ^ {|
fn main() = print(Pro(seat: 5))
|});
  [%expect
    {|
    error: expected the label `seats` here, found `seat`
      ┌─ test.ren:8:23
    8 │ fn main() = print(Pro(seat: 5))
      │                       ^^^^
      help: labels are written in the order the fields are declared
    |}];
  run {|
type P = Pt(x: Int, y: Int)
fn main() = print(Pt(x: 1, 2))
|};
  [%expect
    {|
    error: label every field of `Pt`, or none of them
      ┌─ test.ren:2:19
    2 │ fn main() = print(Pt(x: 1, 2))
      │                   ^^^^^^^^^^^
    |}]

let%expect_test "pattern of the wrong type" =
  run
    (plan_types
   ^ {|
fn main() -> Int =
  match Free
    Free => 1
    true => 0
|});
  [%expect
    {|
    error: expected a pattern for `Plan`, but this one is a `Bool`
       ┌─ test.ren:11:5
    11 │     true => 0
       │     ^^^^
    |}];
  run
    (plan_types
   ^ {|
fn main() -> Int =
  match Pro(1)
    Pro(Free) => 1
    _ => 0
|});
  [%expect
    {|
    error: expected a pattern for `Int`, but this one is a `Plan`
       ┌─ test.ren:10:9
    10 │     Pro(Free) => 1
       │         ^^^^
    |}]

let%expect_test "record literal errors" =
  run (plan_types ^ {|
fn main() = print(User { id: 1 })
|});
  [%expect
    {|
    error: this `User` is missing `plan`
      ┌─ test.ren:8:19
    8 │ fn main() = print(User { id: 1 })
      │                   ^^^^^^^^^^^^^^
    |}];
  run (plan_types ^ {|
fn main() = print(User { id: 1, plan: Free, name: 2 })
|});
  [%expect
    {|
    error: `User` has no field named `name`
      ┌─ test.ren:8:45
    8 │ fn main() = print(User { id: 1, plan: Free, name: 2 })
      │                                             ^^^^
      help: its fields: `id`, `plan`
    |}];
  run (plan_types ^ {|
fn main() = print({ id: 1 })
|});
  [%expect
    {|
    error: no record type has exactly these fields
      ┌─ test.ren:8:19
    8 │ fn main() = print({ id: 1 })
      │                   ^^^^^^^^^
      help: write the type's name before the `{` to see which fields are wrong
    |}];
  run {|
type A = { x: Int }
type B = { x: Int }
fn main() = print({ x: 1 })
|};
  [%expect
    {|
    error: these fields fit more than one type: `A`, `B`
      ┌─ test.ren:3:19
    3 │ fn main() = print({ x: 1 })
      │                   ^^^^^^^^
      help: write the type's name first, like `A { ... }`
    |}];
  run (plan_types ^ {|
fn main() = print(Plan { seats: 1 })
|});
  [%expect
    {|
    error: `Plan` isn't a record type
      ┌─ test.ren:8:19
    8 │ fn main() = print(Plan { seats: 1 })
      │                   ^^^^
      help: its values are made with its constructors
    |}]

let%expect_test "type declaration errors" =
  run {|
type User = { id: UserId }
fn main() = 1
|};
  [%expect
    {|
    error: there's no type named `UserId`
      ┌─ test.ren:1:19
    1 │ type User = { id: UserId }
      │                   ^^^^^^
    |}];
  run {|
type Box = { inner: Option }
fn main() = 1
|};
  [%expect
    {|
    error: `Option` takes 1 type argument but was given 0
      ┌─ test.ren:1:21
    1 │ type Box = { inner: Option }
      │                     ^^^^^^
    |}];
  run {|
type A = | Same
type B = | Same
fn main() = 1
|};
  [%expect
    {|
    error: there are two constructors named `Same`
      ┌─ test.ren:2:12
    2 │ type B = | Same
      │            ^^^^
      help: constructor names must be unique across all types
    |}];
  run {|
type Int = { x: Bool }
fn main() = 1
|};
  [%expect
    {|
    error: `Int` is a built-in type
      ┌─ test.ren:1:6
    1 │ type Int = { x: Bool }
      │      ^^^
      help: choose another name
    |}];
  run {|
type plan = Free
fn main() = 1
|};
  [%expect
    {|
    error: a type name must start with a capital letter
      ┌─ test.ren:1:6
    1 │ type plan = Free
      │      ^^^^
      help: write `Plan`
    |}]

(* ---- Stage 3: type inference ---- *)

let%expect_test "private functions need no annotations (Stage 3 milestone)" =
  let src =
    plan_types
    ^ {|
fn double(x) = x * 2

fn first_or(o, d) =
  match o
    Some(v) => v
    None => d

fn is_even(n) = if n == 0 then true else is_odd(n - 1)
fn is_odd(n) = if n == 0 then false else is_even(n - 1)

fn limit(u) =
  match u.plan
    Free => 1
    Pro(n) => n
    Enterprise(_) => 1_000

fn main() =
  print(double(21))
  print(first_or(Some(3), 0))
  print(first_or(None, true))
  print(is_even(10))
  print(limit({ id: 1, plan: Pro(4) }))
|}
  in
  types src;
  [%expect
    {|
    fn double(x: Int) -> Int
    fn first_or<T>(o: Option<T>, d: T) -> T
    fn is_even(n: Int) -> Bool
    fn is_odd(n: Int) -> Bool
    fn limit(u: User) -> Int
    fn main() uses Io
    |}];
  run src;
  [%expect {|
    42
    3
    true
    true
    4
    ()
    |}]

let%expect_test "explicit type parameters" =
  types
    {|
fn id<T>(x: T) -> T = x
fn pair<A, B>(a: A, b: B, pick: Bool) -> Option<A> =
  if pick then Some(a) else None
fn main() = id(1) + id(2)
|};
  [%expect
    {|
    fn id<T>(x: T) -> T
    fn pair<A, B>(a: A, b: B, pick: Bool) -> Option<A>
    fn main() -> Int
    |}];
  types {|
fn f<T>(x: T) -> Int = x
fn main() = 1
|};
  [%expect
    {|
    error: expected `Int`, found `T`
      ┌─ test.ren:1:24
    1 │ fn f<T>(x: T) -> Int = x
      │                        ^
      = `f` is declared to return `Int`
      = `T` is a type parameter, so this code has to work for every type `T` could be
    |}];
  types {|
fn f<T>(x: T) = x.id
type R = { id: Int }
fn main() = 1
|};
  [%expect
    {|
    error: `.id` needs a record, but this is a `T`
      ┌─ test.ren:1:19
    1 │ fn f<T>(x: T) = x.id
      │                   ^^
    |}]

let%expect_test "type errors are caught before running" =
  run {|
fn main() =
  print(1)
  if true then 1 else false
|};
  [%expect
    {|
    error: this `else` branch is a `Bool`, but the `then` branch is an `Int`
      ┌─ test.ren:3:23
    3 │   if true then 1 else false
      │                       ^^^^^
      = both branches of an `if` have to produce the same type
    |}];
  run {|
fn add(a, b) = a + b
fn main() = add(1, true)
|};
  [%expect
    {|
    error: expected `Int`, found `Bool`
      ┌─ test.ren:2:20
    2 │ fn main() = add(1, true)
      │                    ^^^^
    |}];
  run {|
fn main() =
  match 1
    1 => 1
    _ => false
|};
  [%expect
    {|
    error: this arm is a `Bool`, but the arms above it are an `Int`
      ┌─ test.ren:4:10
    4 │     _ => false
      │          ^^^^^
    |}];
  run {|
fn main() =
  match Some(1)
    Some(true) => 1
    _ => 2
|};
  [%expect
    {|
    error: expected a pattern for `Int`, but this one is a `Bool`
      ┌─ test.ren:3:10
    3 │     Some(true) => 1
      │          ^^^^
    |}];
  run {|
fn main() =
  let x = 3
  x(1)
|};
  [%expect
    {|
    error: `x` is an `Int`, not a function
      ┌─ test.ren:3:3
    3 │   x(1)
      │   ^
    |}];
  run {|
fn main() = 1 == true
|};
  [%expect
    {|
    error: `==` compares two values of the same type, but this is a `Bool` and the left side is an `Int`
      ┌─ test.ren:1:18
    1 │ fn main() = 1 == true
      │                  ^^^^
    |}];
  run {|
fn main() = y + 1
|};
  [%expect
    {|
    error: there's no variable named `y`
      ┌─ test.ren:1:13
    1 │ fn main() = y + 1
      │             ^
    |}];
  run {|
fn f(x) = f
fn main() = 1
|};
  [%expect
    {|
    error: this value's type would have to contain itself
      ┌─ test.ren:1:11
    1 │ fn f(x) = f
      │           ^
      = it would have to be `_` and `fn(_) -> _` at the same time
    |}];
  run {|
fn main(x) = 1
|};
  [%expect
    {|
    error: `main` can't take parameters
      ┌─ test.ren:1:9
    1 │ fn main(x) = 1
      │         ^
      help: remove the parameters
    |}]

let%expect_test "functions that call each other share one type" =
  types {|
fn g(x) = f(x)
fn f<T>(x: T) -> T = g(x)
fn main() = 1
|};
  [%expect
    {|
    error: `g` would have to use `T`, the type parameter of `f`
      ┌─ test.ren:1:4
    1 │ fn g(x) = f(x)
      │    ^
      = `g` and `f` call each other, and functions that call each other are checked at a single type
      help: remove the type parameter from `f`, or break the cycle
    |}];
  types {|
fn g(x) = f(x)
fn f(x) = g(x)
fn main() = 1
|};
  [%expect
    {|
    fn g<T, U>(x: T) -> U
    fn f<T, U>(x: T) -> U
    fn main() -> Int
    |}]

let%expect_test "public functions spell out their signature" =
  types {|
pub fn f(x) -> Int = x + 1
fn main() = 1
|};
  [%expect
    {|
    error: the parameter `x` of the public function `f` has no type
      ┌─ test.ren:1:10
    1 │ pub fn f(x) -> Int = x + 1
      │          ^
      = public functions spell out their full signature
      help: write `x: Int`
    |}];
  types {|
pub fn f(x: Int) = x + 1
fn main() = 1
|};
  [%expect
    {|
    error: expected `Unit`, found `Int`
      ┌─ test.ren:1:20
    1 │ pub fn f(x: Int) = x + 1
      │                    ^^^^^
      = a public function without `->` returns `Unit`
      help: add `-> Int` to the signature
    |}];
  types {|
pub fn show(x: Int) = print(x)
fn main() = show(1)
|};
  [%expect {|
    pub fn show(x: Int) uses Io
    fn main() uses Io
    |}]

(* which record a field belongs to *)

let admin_types =
  {|
type User = { id: Int, name: Int }
type Admin = { id: Int, level: Int }
|}

let%expect_test "a field only one record has decides the type" =
  types (admin_types ^ {|
fn level(a) = a.level
fn main() = 1
|});
  [%expect {|
    fn level(a: Admin) -> Int
    fn main() -> Int
    |}]

let%expect_test "a shared field waits for the rest of the function" =
  types
    (admin_types
   ^ {|
fn score(a) =
  let x = a.id
  a.level + x
fn main() = 1
|});
  [%expect {|
    fn score(a: Admin) -> Int
    fn main() -> Int
    |}]

let%expect_test "a shared field nothing pins down is an error" =
  types (admin_types ^ {|
fn get_id(u) = u.id
fn main() = 1
|});
  [%expect
    {|
    error: can't tell which record type `u` is
      ┌─ test.ren:4:16
    4 │ fn get_id(u) = u.id
      │                ^
      = `id` is a field of `Admin` and `User`
      help: annotate `u` where it's defined, like `u: Admin`
    |}];
  types (admin_types ^ {|
fn get_id(u: User) = u.id
fn main() = 1
|});
  [%expect {|
    fn get_id(u: User) -> Int
    fn main() -> Int
    |}]

let%expect_test "field errors" =
  run
    (plan_types
   ^ {|
fn main() =
  let u = User { id: 1, plan: Free }
  u.name
|});
  [%expect
    {|
    error: `User` has no field named `name`
       ┌─ test.ren:10:5
    10 │   u.name
       │     ^^^^
       help: its fields: `id`, `plan`
    |}];
  run {|
fn main() = 1.x
|};
  [%expect
    {|
    error: `.x` needs a record, but this is an `Int`
      ┌─ test.ren:1:15
    1 │ fn main() = 1.x
      │               ^
    |}];
  run {|
fn f(r) = r.nope
fn main() = 1
|};
  [%expect
    {|
    error: no record type has a field named `nope`
      ┌─ test.ren:1:13
    1 │ fn f(r) = r.nope
      │             ^^^^
    |}]

let%expect_test "an untyped record literal takes the type it's used as" =
  run
    {|
type A = { x: Int }
type B = { x: Int }
fn take(a: A) -> Int = a.x + 1
fn main() = take({ x: 1 })
|};
  [%expect {| 2 |}]

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

let%expect_test "ast of lambdas and function types" =
  ast
    {|
fn run(f: fn(Int) -> Bool, g: fn(x: Int)) = f(1)
fn main() =
  let h = fn(x, y: Int) => x + y
  run(fn(n) => n > 0) fn(_) =>
    ()
  h(1, 2)(3)
|};
  [%expect
    {|
    (fn run (f g) (call f 1))
    (fn main () (block (let h (lambda (x y:Int) (+ x y))) (call run (lambda (n) (> n 0)) (lambda (_) ())) (call (call h 1 2) 3)))
    |}]

let%expect_test "lambda parse errors" =
  ast {|
fn main() = fn x => x
|};
  [%expect
    {|
    error: expected `(` to start a lambda, found `x`
      ┌─ test.ren:1:16
    1 │ fn main() = fn x => x
      │                ^
      help: functions are defined at the top level; a lambda is `fn(x) => ...`
    |}]

(* rows: dependencies flow through calls and transparent parameters *)

let%expect_test "dependencies flow through transparent parameters" =
  types
    {|
fn twice(f: fn()) =
  f()
  f()

fn shout() = print(1)

fn quiet() = twice(fn() => ())
fn loud() = twice(fn() => print(1))
fn louder() = twice(shout)
fn main() = 1
|};
  [%expect
    {|
    fn twice(f: fn())
    fn shout() uses Io
    fn quiet()
    fn loud() uses Io
    fn louder() uses Io
    fn main() -> Int
    |}]

let%expect_test "a function stored in a record uses nothing" =
  run
    {|
type Button = { on_click: fn() }
fn main() = Button { on_click: fn() => print(1) }
|};
  [%expect
    {|
    error: expected `fn()`, found `fn() uses Io`
      ┌─ test.ren:2:32
    2 │ fn main() = Button { on_click: fn() => print(1) }
      │                                ^^^^^^^^^^^^^^^^
      = `Button`'s field `on_click`
    |}];
  run
    {|
type Button = { on_click: fn() -> Int }
fn main() =
  let b = Button { on_click: fn() => 4 }
  b.on_click()
|};
  [%expect {| 4 |}]

let%expect_test "a parameter written as fn(...) must stay transparent" =
  types
    {|
type Button = { on_click: fn() }
fn mk(f: fn()) = Button { on_click: f }
fn main() = 1
|};
  [%expect
    {|
    error: `f` is used as a value here, so it isn't transparent
      ┌─ test.ren:2:37
    2 │ fn mk(f: fn()) = Button { on_click: f }
      │                                     ^
      = a parameter whose type is written `fn(...)` can only be called, or passed straight to another function
      help: remove the type from `f` and let it be inferred, so its errors and dependencies are tracked wherever it goes
    |}];
  types {|
fn keep(f: fn()) = fn() => f()
fn main() = 1
|};
  [%expect
    {|
    error: `f` is captured by a lambda that outlives the call, so it isn't transparent
      ┌─ test.ren:1:20
    1 │ fn keep(f: fn()) = fn() => f()
      │                    ^^^^^^^^^^^
      = a parameter whose type is written `fn(...)` can only be called, or passed straight to another function
      help: remove the type from `f` and let it be inferred, so its errors and dependencies are tracked wherever it goes
    |}];
  (* following the help: inferred, its dependencies show up as ..d *)
  types {|
fn keep(f) = fn() => f()
fn main() = keep(fn() => print(1))()
|};
  [%expect
    {|
    fn keep<T>(f: fn() -> T ! ..e uses ..d) -> (fn() -> T ! ..e uses ..d)
    fn main() uses Io
    |}];
  (* passing it on, directly or inside a lambda, is fine *)
  types
    {|
fn twice(f: fn()) =
  f()
  f()
fn four(f: fn()) =
  twice(f)
  twice(fn() => f())
fn main() = 1
|};
  [%expect
    {|
    fn twice(f: fn())
    fn four(f: fn())
    fn main() -> Int
    |}]

(* the row unifier on its own *)

let%expect_test "row unification" =
  let open Types in
  let row labels tail =
    List.fold_right (fun l r -> RExtend (l, r)) labels tail
  in
  let show r =
    let pr = printer ~show_tail:(fun _ -> true) () in
    match show_row pr ~prefix:"" ~sep:", " ~kind:"d" r with
    | "" -> "<>"
    | s -> "<" ^ s ^ ">"
  in
  let try_unify a b =
    match Unify.unify_row a b with
    | () -> print_endline (show a ^ " = " ^ show b)
    | exception Unify.Mismatch -> print_endline "mismatch"
    | exception Unify.Infinite -> print_endline "infinite"
  in
  (* order doesn't matter *)
  try_unify (row [ "Io"; "Clock" ] REmpty) (row [ "Clock"; "Io" ] REmpty);
  (* an open row grows to supply what's missing *)
  let r1 = fresh_row () and r2 = fresh_row () in
  try_unify (row [ "Io" ] r1) (row [ "Clock" ] r2);
  (* a closed row can't *)
  try_unify (row [ "Io" ] REmpty) (row [ "Clock" ] (fresh_row ()));
  try_unify REmpty (row [ "Io" ] (fresh_row ()));
  (* the same tail with different labels can't be made equal *)
  let r = fresh_row () in
  try_unify (row [ "Io" ] r) (row [ "Clock" ] r);
  (* a row can't contain itself *)
  let r = fresh_row () in
  try_unify r (row [ "Io" ] r);
  [%expect
    {|
    <Clock, Io> = <Clock, Io>
    <Clock, Io, ..d> = <Clock, Io, ..d>
    mismatch
    mismatch
    mismatch
    infinite
    |}]

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
    error: `+` can't be used on `Int` and `Bool`
      ┌─ test.ren:1:13
    1 │ fn main() = 1 + true
      │             ^^^^^^^^
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

(* Lexing and parsing: layout tokens, the shape of the tree, syntax
   errors. *)

open Helpers

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

(* after a syntax error, parsing picks up at the next top-level item *)

let%expect_test "syntax errors in two functions" =
  ast {|
fn f() = 1 < 2 < 3
fn g() =
  let x = 1 +
  x
fn main() = 1
|};
  [%expect
    {|
    error: comparisons can't be chained
      ┌─ test.ren:1:16
    1 │ fn f() = 1 < 2 < 3
      │                ^
      help: split it into two comparisons

    error: expected an expression, found a new line
      ┌─ test.ren:4:3
    4 │   x
      │   ^
    |}]

(* imports *)

let%expect_test "the four forms of import" =
  ast
    {|
import util
import billing/stripe as pay
import shop/plan.{Plan, User}
import shop/plan.{Plan} as p
fn main() = 1
|};
  [%expect
    {|
    (import util as util)
    (import billing/stripe as pay)
    (import shop/plan (Plan User) as plan)
    (import shop/plan (Plan) as p)
    (fn main () 1)
    |}]

let%expect_test "an import after a function" =
  ast {|
fn main() = 1
import util
|};
  [%expect
    {|
    error: imports go at the top of the file
      ┌─ test.ren:2:1
    2 │ import util
      │ ^^^^^^^^^^^
      help: move it above the file's first function or type
    |}]

let%expect_test "a module's name is snake_case" =
  ast {|
import billing/StripeApi
fn main() = 1
|};
  [%expect
    {|
    error: `StripeApi` can't name a module: module names are snake_case
      ┌─ test.ren:1:16
    1 │ import billing/StripeApi
      │                ^^^^^^^^^
      help: write `stripe_api`, and rename its file or folder to match
    |}]

let%expect_test "an alias is snake_case too" =
  ast {|
import billing/stripe as Pay
fn main() = 1
|};
  [%expect
    {|
    error: `Pay` can't name a module: module names are snake_case
      ┌─ test.ren:1:26
    1 │ import billing/stripe as Pay
      │                          ^^^
      help: write `pay`
    |}]

let%expect_test "only types can be imported by name" =
  ast {|
import billing/stripe.{charge}
fn main() = 1
|};
  [%expect
    {|
    error: only types can be imported by name, and `charge` isn't one
      ┌─ test.ren:1:24
    1 │ import billing/stripe.{charge}
      │                        ^^^^^^
      help: remove it, and write `stripe.charge` where it's used
    |}]

let%expect_test "an import can't be pub" =
  ast {|
pub import util
fn main() = 1
|};
  [%expect
    {|
    error: an import can't be `pub`
      ┌─ test.ren:1:5
    1 │ pub import util
      │     ^^^^^^
      help: remove the `pub`: a module can't pass on what it imports
    |}]

let%expect_test "a type or constructor can be qualified" =
  (* a lowercase name before a capitalized one is a module's alias; a
     capitalized one before another is a type *)
  ast
    {|
type Order = { client: stripe.Client, plans: Array<billing.Plan> }
fn main() =
  let a = Light.Red
  let b = billing.Plan.Pro(seats: 2)
  let c = rows.Row { id: 1 }
  match b
    billing.Plan.Free => Plan.Free
    Plan.Pro(n) => user.plan
|};
  [%expect
    {|
    (type Order (fields client:stripe.Client plans:Array<billing.Plan>))
    (fn main () (block (let a (con Light.Red)) (let b (con billing.Plan.Pro seats=2)) (let c (record rows.Row id=1)) (match b (billing.Plan.Free => (con Plan.Free)) (Plan.Pro(n) => (. user plan)))))
    |}]

let%expect_test "another module's type isn't a value" =
  ast {|
fn main() = billing.Plan
|};
  [%expect
    {|
    error: `billing.Plan` is a type, so it can't be used as a value
      ┌─ test.ren:1:13
    1 │ fn main() = billing.Plan
      │             ^^^^^^^^^^^^
      help: write one of its constructors after it, like `billing.Plan.Name`, or a record, `billing.Plan { ... }`
    |}]

let%expect_test "uses, on the signature's line or the next" =
  ast
    {|
fn f() -> Int uses Io, Clock = 1
pub fn g(x: Int) -> Int
    uses Io =
  x
fn h() = 2
|};
  [%expect
    {|
    (fn f () (uses Io Clock) 1)
    (fn g (x) (uses Io) x)
    (fn h () 2)
    |}]

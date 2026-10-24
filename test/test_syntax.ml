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

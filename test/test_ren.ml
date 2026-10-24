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

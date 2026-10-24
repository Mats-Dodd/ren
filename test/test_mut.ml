(* Mutability checks (mut.ml): what may change, and exclusivity. *)

open Helpers

let%expect_test "assigning to a let" =
  run {|
fn main() =
  let x = 1
  x = 2
  x
|};
  [%expect
    {|
    error: `x` is a `let`, so it can't be changed
      ┌─ test.ren:3:3
    3 │   x = 2
      │   ^
      help: declare it with `var` to change it
    |}]

let%expect_test "assigning to a parameter" =
  run {|
fn f(n: Int) =
  n = 2
fn main() = f(1)
|};
  [%expect
    {|
    error: `n` is a parameter, so it can't be changed
      ┌─ test.ren:2:3
    2 │   n = 2
      │   ^
      help: mark it `inout` to change the caller's value, or copy it with `var n = n`
    |}]

let%expect_test "assigning to a pattern variable" =
  run {|
fn main() =
  match Some(1)
    Some(n) => n = 2
    None => ()
|};
  [%expect
    {|
    error: `n` is bound by a pattern, so it can't be changed
      ┌─ test.ren:3:16
    3 │     Some(n) => n = 2
      │                ^
      help: copy it with `var n = n` and change the copy
    |}]

let%expect_test "assigning to a loop variable" =
  run {|
fn main() =
  for x in [1, 2]
    x = 3
|};
  [%expect
    {|
    error: `x` is a loop variable, so it can't be changed
      ┌─ test.ren:3:5
    3 │     x = 3
      │     ^
      help: loop with `for x in &...` to change the elements
    |}]

let%expect_test "assigning to a function" =
  run {|
fn f() = 1
fn main() =
  f = 2
|};
  [%expect
    {|
    error: `f` is a function, not a variable
      ┌─ test.ren:3:3
    3 │   f = 2
      │   ^
    |}]

let%expect_test "& on a let" =
  run {|
fn bump(inout n: Int) =
  n += 1
fn main() =
  let a = 1
  bump(&a)
|};
  [%expect
    {|
    error: `a` is a `let`, so it can't be changed
      ┌─ test.ren:5:9
    5 │   bump(&a)
      │         ^
      help: declare it with `var` to change it
    |}]

let%expect_test "& on something that isn't a place" =
  run {|
fn bump(inout n: Int) =
  n += 1
fn main() =
  bump(&1)
|};
  [%expect
    {|
    error: `&` needs a variable it can change
      ┌─ test.ren:4:9
    4 │   bump(&1)
      │         ^
      help: only a variable, or a field or element of one, can be changed
    |}]

let%expect_test "& outside a call" =
  run {|
fn main() =
  var a = 1
  let b = &a
  b
|};
  [%expect
    {|
    error: `&` can't be used here
      ┌─ test.ren:3:11
    3 │   let b = &a
      │           ^^
      = `&` marks an argument a call changes, or the array a `for` loop changes
      help: remove the `&`
    |}]

let%expect_test "swap(&a, &a)" =
  run
    {|
fn swap(inout a: Int, inout b: Int) =
  let t = a
  a = b
  b = t
fn main() =
  var a = 1
  swap(&a, &a)
|};
  [%expect
    {|
    error: `a` is passed with `&` twice in this call
      ┌─ test.ren:7:12
    7 │   swap(&a, &a)
      │            ^^
      │        -- passed with `&` here
      = an argument passed with `&` has to be the only way the call can reach that value
    |}]

let%expect_test "an inout argument can't also be read" =
  run
    {|
fn f(inout xs: Array<Int>, ys: Array<Int>) =
  push(&xs, len(ys))
fn main() =
  var xs = [1]
  f(&xs, xs)
|};
  [%expect
    {|
    error: this call changes `xs`, so no other argument can use it
      ┌─ test.ren:5:10
    5 │   f(&xs, xs)
      │          ^^
      │     --- passed with `&` here
      = an argument passed with `&` has to be the only way the call can reach that value
      help: copy it with `let` first if the call should see the value `xs` had before
    |}]

let%expect_test "a lambda can't change a captured variable" =
  run {|
fn main() =
  var n = 1
  let f = fn() => n = 2
  f()
|};
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
      ┌─ test.ren:3:19
    3 │   let f = fn() => n = 2
      │                   ^
      = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "lambdas can't take inout parameters" =
  run {|
fn main() =
  let f = fn(inout x) => x
  f
|};
  [%expect
    {|
    error: lambdas can't take `inout` parameters yet
      ┌─ test.ren:2:20
    2 │   let f = fn(inout x) => x
      │                    ^
      help: use a top-level function for this
    |}]

let%expect_test "a for & loop locks its array" =
  run {|
fn main() =
  var xs = [1, 2]
  for x in &xs
    push(&xs, x)
|};
  [%expect
    {|
    error: `xs` is being changed by the `for` loop around this
      ┌─ test.ren:4:11
    3 │   for x in &xs
      │            --- the loop changes `xs` here
    4 │     push(&xs, x)
      │           ^^
      help: inside the loop, use `x`
    |}]

let%expect_test "independent errors are all reported" =
  run
    {|
fn main() =
  let x = 1
  x = 2
  var n = 1
  let f = fn() => n = 2
  f()
|};
  [%expect
    {|
    error: `x` is a `let`, so it can't be changed
      ┌─ test.ren:3:3
    3 │   x = 2
      │   ^
      help: declare it with `var` to change it

    error: a lambda can't change `n`, a variable from outside it
      ┌─ test.ren:5:19
    5 │   let f = fn() => n = 2
      │                   ^
      = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

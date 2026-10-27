(* Mutability checks (mut.ml), what may change, and exclusivity (excl.ml),
   that nothing is used while it's being changed. *)

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
      help: pass `a` with `&` once; a second value it changes needs a `var` of its own
    |}]

let%expect_test "an inout argument can't also be read" =
  run
    {|
fn f(inout xs: Array<Int>, ys: Array<Int>) =
  &xs.push(ys.len())
fn main() =
  var xs = [1]
  f(&xs, xs)
|};
  [%expect
    {|
    error: `xs` is passed with `&` and read by the same call
      ┌─ test.ren:5:10
    5 │   f(&xs, xs)
      │          ^^ read for the whole call
      │     --- passed with `&` here
      = an argument passed with `&` has to be the only way the call can reach that value
      help: read it into a `let` before the call, `let before = xs`, and pass that
    |}]

let%expect_test "a block changes a variable it captures" =
  (* it captures by reference: the change is seen outside it *)
  run
    {|
fn main() uses Console =
  var n = 1
  let f = fn() => n = 2
  f()
  print(n)
|};
  [%expect {|
    2
    ()
    |}]

let%expect_test "a block that changes a variable, passed beside it with &" =
  run
    {|
fn bump_with(inout n: Int, f: fn()) =
  n += 1
  try f()

fn main() =
  var n = 1
  let f = fn() => n = 2
  bump_with(&n, f)
|};
  [%expect
    {|
    error: `n` is changed by this block and passed with `&` to the same call
      ┌─ test.ren:7:19
    7 │   let f = fn() => n = 2
      │                   ^ changed here
    8 │   bump_with(&n, f)
      │             -- passed with `&` here
      │                 - the block runs here
      = a block runs during the call it's passed to
      help: change `n` in one place: pass the block's change as a value, or apply it after the call
    |}]

let%expect_test "a block that changes a variable, called inside a for & over it"
    =
  run
    {|
fn main() =
  var xs = [1, 2]
  let f = fn() => &xs.push(3)
  for x in &xs
    f()
    x += 1
|};
  [%expect
    {|
    error: `xs` is changed by this block while the loop changes it
      ┌─ test.ren:3:20
    3 │   let f = fn() => &xs.push(3)
      │                    ^^ changed here
    4 │   for x in &xs
      │            --- changed for the whole loop
    5 │     f()
      │     - the block runs here
      = a block runs during the call it's passed to
      help: inside the loop, use `x`
    |}]

let%expect_test "blocks can't take inout parameters" =
  run {|
fn main() =
  let f = fn(inout x) => x
  f
|};
  [%expect
    {|
    error: blocks can't take `inout` parameters yet
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
    &xs.push(x)
|};
  [%expect
    {|
    error: `xs` is being changed by the `for` loop around this
      ┌─ test.ren:4:6
    3 │   for x in &xs
      │            --- the loop changes `xs` here
    4 │     &xs.push(x)
      │      ^^
      help: inside the loop, use `x`
    |}]

let%expect_test "independent errors are all reported" =
  run
    {|
fn main() =
  let x = 1
  x = 2
  let f = fn() => x
  let b = &f
  f()
|};
  [%expect
    {|
    error: `x` is a `let`, so it can't be changed
      ┌─ test.ren:3:3
    3 │   x = 2
      │   ^
      help: declare it with `var` to change it

    error: `&` can't be used here
      ┌─ test.ren:5:11
    5 │   let b = &f
      │           ^^
      = `&` marks an argument a call changes, or the array a `for` loop changes
      help: remove the `&`
    |}]

let%expect_test "an inout block parameter is reported once" =
  (* the parameter is still bound as `inout`, so changing it isn't also
     reported as changing a read-only parameter *)
  run {|
fn main() =
  let f = fn(inout n) => n += 1
  f
|};
  [%expect
    {|
    error: blocks can't take `inout` parameters yet
      ┌─ test.ren:2:20
    2 │   let f = fn(inout n) => n += 1
      │                    ^
      help: use a top-level function for this
    |}]

let%expect_test "a help writes not and && back as they're written" =
  run
    {|
fn main() =
  var xs = [true]
  let a = true
  xs.push(not a && a == (not a))
  xs.len()
|};
  [%expect
    {|
    error: `push` changes `xs`, so the call needs `&`
      ┌─ test.ren:4:3
    4 │   xs.push(not a && a == (not a))
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = `&` shows at the call that `xs` is changed
      help: write `&xs.push(not a && a == (not a))`
    |}]

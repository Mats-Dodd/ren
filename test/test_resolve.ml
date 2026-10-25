(* Name resolution (resolve.ml): what each name refers to. Most of its
   errors (unknown names and types, names declared twice) are tested with
   the pass that used to report them, in test_check.ml and
   test_infer.ml. *)

open Helpers

let%expect_test "a name that doesn't exist stops before type checking" =
  (* inference never sees code whose names didn't resolve, so the type
     error isn't reported until the name is fixed *)
  run {|
fn main() =
  let x = 1 + true
  print(y)
|};
  [%expect
    {|
    error: there's no variable named `y`
      ┌─ test.ren:3:9
    3 │   print(y)
      │         ^
    |}]

let%expect_test "every unknown type is reported in one run" =
  run {|
type Box = { inner: Option }
fn f(x: Thing) = x
fn main() = f(1)
|};
  [%expect
    {|
    error: `Option` takes 1 type argument but was given 0
      ┌─ test.ren:1:21
    1 │ type Box = { inner: Option }
      │                     ^^^^^^

    error: there's no type named `Thing`
      ┌─ test.ren:2:9
    2 │ fn f(x: Thing) = x
      │         ^^^^^
    |}]

let%expect_test "a name means the closest binding of it" =
  (* the second `x` is a new variable, which can change *)
  run {|
fn main() =
  let x = 1
  var x = x + 1
  x += 1
  x
|};
  [%expect {| 3 |}];
  (* the lambda's `f` is its own parameter, not `call`'s, so `call`'s `f`
     isn't captured *)
  types
    {|
fn call(f: fn()) =
  let id = fn(f) => f
  f()
fn main() = call(fn() => ())
|};
  [%expect {|
    fn call(f: fn())
    fn main()
    |}]

let%expect_test "a lambda can't have two parameters with the same name" =
  run {|
fn main() =
  let f = fn(x, x) => x
  print(f(1, 2))
|};
  [%expect
    {|
    error: there are two parameters named `x`
      ┌─ test.ren:2:17
    2 │   let f = fn(x, x) => x
      │                 ^
      │              - the first `x` is here
      help: rename one of them
    |}]

let%expect_test "a pattern can't bind the same name twice" =
  run
    {|
type Pair = P(a: Int, b: Int)
fn main() =
  match P(1, 2)
    P(x, x) => print(x)
|};
  [%expect
    {|
    error: there are two pattern variables named `x`
      ┌─ test.ren:4:10
    4 │     P(x, x) => print(x)
      │          ^
      │       - the first `x` is here
      help: rename one of them
    |}]

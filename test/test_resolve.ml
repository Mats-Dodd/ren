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

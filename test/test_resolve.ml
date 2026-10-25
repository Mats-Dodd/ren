(* Name resolution (resolve.ml): what each name refers to, and names
   declared twice. Some of its errors (unknown variables and functions) are
   tested in test_infer.ml, with the pass that used to report them. *)

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
    1 │ type A = | Same
      │            ---- the first `Same` is here, in `A`
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

let%expect_test "a duplicate points at the first one" =
  run {|
fn f() = 1
fn f() = 2
fn main() = 1
|};
  [%expect
    {|
    error: there are two functions named `f`
      ┌─ test.ren:2:4
    1 │ fn f() = 1
      │    - the first `f` is here
    2 │ fn f() = 2
      │    ^
      help: rename one of them
    |}];
  (* the first one can be in the prelude, which has no source to show *)
  run {|
type Option = { x: Int }
fn main() = 1
|};
  [%expect
    {|
    error: there are two types named `Option`
      ┌─ test.ren:1:6
    1 │ type Option = { x: Int }
      │      ^^^^^^
      = the first `Option` is here: <prelude>:1:6
      help: rename one of them
    |}]

let%expect_test "a prelude function's name can't be reused" =
  run {|
fn print(x) = x
fn main() = 1
|};
  [%expect
    {|
    error: `print` is already a function in the prelude
      ┌─ test.ren:1:4
    1 │ fn print(x) = x
      │    ^^^^^
      help: choose another name
    |}]

let%expect_test "a file can't be named prelude.ren" =
  (* its module would be the prelude's own *)
  let src = "fn main() = 1\n" in
  report src (fun () ->
      print_endline (Ren.Value.show (Ren.Driver.run ~file:"prelude.ren" src)));
  [%expect
    {|
    error: a file can't be named `prelude.ren`: that's the name of the module every program imports
      ┌─ prelude.ren:1:1
    1 │ fn main() = 1
      │ ^
      help: rename the file
    |}]

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
  try f()
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
      = the first `Option` is here: <prelude>:1:10
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
  report_files
    [ ("prelude.ren", src) ]
    (fun () ->
      print_endline (Ren.Value.show (Ren.Driver.run ~file:"prelude.ren" src)));
  [%expect
    {|
    error: a file can't be named `prelude.ren`: that's the name of the module every program imports
      ┌─ prelude.ren:1:1
    1 │ fn main() = 1
      │ ^
      help: rename the file
    |}]

(* ---- error sets (errors.md) ---- *)

let%expect_test "until stage 6.4, fail patterns are reported where they're used"
    =
  (* the rest of error handling is checked (test_errors.ml) *)
  run
    {|
fn f() = fail Bad
fn main() =
  match f()
    _ => ()
    fail _ => ()
|};
  [%expect
    {|
    error: `fail` patterns arrive later in stage 6
      ┌─ test.ren:5:5
    5 │     fail _ => ()
      │     ^^^^^^
      help: for now, keep the outcome with `attempt` and match the `Result`: `Err(Short(_, by))`
    |}]

let%expect_test "a named error set is found through scope, and tags aren't" =
  (* `Refusal` is the set, and `Late` and `Frozen` are tags: nothing
     declares them *)
  run
    {|
type Refusal = ! Short(by: Int) | Frozen
type Late = { days: Int }
type TransferError = ! Refusal | Late | SameAccount(Late)
fn main() = ()
|};
  [%expect {| () |}]

let%expect_test "another module's named error sets" =
  (* imported by name, or written after the module: either way the import
     is used *)
  let bank =
    ( "bank.ren",
      {|
pub type Refusal = ! Short(by: Int) | Frozen
pub type TransferError = ! Refusal | SameAccount
type Secret = ! Hidden
|}
    )
  in
  run_files
    [
      ( "main.ren",
        {|
import bank.{Refusal}
import bank as b
type Mine = ! Refusal | b.TransferError
fn main() = ()
|}
      );
      bank;
    ];
  [%expect {| () |}];
  (* a private one can't be told apart from one that doesn't exist *)
  run_files
    [
      ("main.ren", {|
import bank
type Mine = ! bank.Secret
fn main() = ()
|});
      bank;
    ];
  [%expect
    {|
    error: `bank` has no public type `Secret`
      ┌─ main.ren:2:20
    2 │ type Mine = ! bank.Secret
      │                    ^^^^^^
      help: if it's defined there, mark it `pub`
    |}]

let%expect_test "an error set isn't a type of values" =
  run
    {|
type Refusal = ! Short(by: Int) | Frozen
type Hold = { why: Refusal, also: ! Frozen }
fn main() =
  let r = Refusal.Short(1)
  ()
|};
  [%expect
    {|
    error: `Refusal` is an error set, so it isn't a type of values
      ┌─ test.ren:2:20
    2 │ type Hold = { why: Refusal, also: ! Frozen }
      │                    ^^^^^^^
      help: an error set is only written after `!`

    error: an error set isn't a type of values
      ┌─ test.ren:2:35
    2 │ type Hold = { why: Refusal, also: ! Frozen }
      │                                   ^^^^^^^^
      help: an error set goes after `!` in a signature or a function type; the one type that holds one is `Result<T, ! ...>`

    error: `Refusal` is an error set, so it has no constructors
      ┌─ test.ren:4:11
    4 │   let r = Refusal.Short(1)
      │           ^^^^^^^
      help: an error set is only written after `!`
    |}]

let%expect_test "a type of values isn't an error set" =
  run_files
    [
      ("main.ren", {|
import bank
fn f() ! bank.Account = ()
fn main() = ()
|});
      ("bank.ren", {|
pub type Account = { id: Int }
|});
    ];
  [%expect
    {|
    error: `bank.Account` is a type, not an error set
      ┌─ main.ren:2:10
    2 │ fn f() ! bank.Account = ()
      │          ^^^^^^^^^^^^
      help: name an error set, declared with `type X = ! ...`; a tag is written bare, `Account`
    |}]

let%expect_test "an error is written once in a set" =
  run
    {|
type Refusal = ! Short(by: Int) | Frozen
type Twice = ! Refusal | Frozen | Refusal | Frozen(Int)
fn main() = ()
|};
  [%expect
    {|
    error: `Refusal` is in this error set twice
      ┌─ test.ren:2:35
    2 │ type Twice = ! Refusal | Frozen | Refusal | Frozen(Int)
      │                                   ^^^^^^^
      │                ------- the first `Refusal` is here
      help: remove one of them

    error: `Frozen` is in this error set twice
      ┌─ test.ren:2:45
    2 │ type Twice = ! Refusal | Frozen | Refusal | Frozen(Int)
      │                                             ^^^^^^
      │                          ------ the first `Frozen` is here
      help: remove one of them
    |}]

let%expect_test "a named error set can't include itself" =
  run
    {|
type A = ! B | Oops
type B = ! Fine | C
type C = ! A
type D = ! D
fn main() = ()
|};
  [%expect
    {|
    error: `A` includes itself: A → B → C → A
      ┌─ test.ren:1:6
    1 │ type A = ! B | Oops
      │      ^
      help: remove one of these sets from the one that includes it

    error: `D` includes itself: D → D
      ┌─ test.ren:4:6
    4 │ type D = ! D
      │      ^
      help: remove it from its own list
    |}]

let%expect_test "a public signature names no private error set" =
  run
    {|
type Money = opaque Int
type Refusal = ! Short(by: Int) | Frozen
pub type TransferError = ! Refusal | Late(Money)
pub fn debit(m: Int) ! Refusal | Short(by: Money) = ()
fn main() = ()
|};
  [%expect
    {|
    error: `pub type TransferError` includes `Refusal`, which is private to this module
      ┌─ test.ren:3:28
    2 │ type Refusal = ! Short(by: Int) | Frozen
      │      ------- `Refusal` is declared here, without `pub`
    3 │ pub type TransferError = ! Refusal | Late(Money)
      │                            ^^^^^^^
      help: mark `Refusal` `pub`

    error: `pub type TransferError`'s error `Late` mentions `Money`, which is private to this module
      ┌─ test.ren:3:43
    1 │ type Money = opaque Int
      │      ----- `Money` is declared here, without `pub`
    3 │ pub type TransferError = ! Refusal | Late(Money)
      │                                           ^^^^^
      help: mark `Money` `pub`

    error: `pub fn debit` can fail with `Refusal`, which is private to this module
      ┌─ test.ren:4:24
    2 │ type Refusal = ! Short(by: Int) | Frozen
      │      ------- `Refusal` is declared here, without `pub`
    4 │ pub fn debit(m: Int) ! Refusal | Short(by: Money) = ()
      │                        ^^^^^^^
      help: mark `Refusal` `pub`

    error: `pub fn debit`'s error `Short` mentions `Money`, which is private to this module
      ┌─ test.ren:4:44
    1 │ type Money = opaque Int
      │      ----- `Money` is declared here, without `pub`
    4 │ pub fn debit(m: Int) ! Refusal | Short(by: Money) = ()
      │                                            ^^^^^
      help: mark `Money` `pub`
    |}]

let%expect_test "each alternative of a fail pattern binds the same names" =
  run
    {|
fn g() = 1
fn main() =
  match g()
    _ => 0
    fail Short(_, by) | fail Late(by) => by
    fail Frozen(id) | fail Gone => id
    fail Odd | fail Even(n) => n
|};
  [%expect
    {|
    error: this alternative doesn't bind `id`, which the first one does
      ┌─ test.ren:6:23
    6 │     fail Frozen(id) | fail Gone => id
      │                       ^^^^^^^^^
      │                 -- `id` is bound here
      help: bind the same names in every alternative

    error: `n` is bound by this alternative, but not by the first one
      ┌─ test.ren:7:26
    7 │     fail Odd | fail Even(n) => n
      │                          ^
      help: bind the same names in every alternative
    |}]

(* Static checks (check.ml): exhaustive matches, and the names and shapes of
   types, constructors and records. *)

open Helpers

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
    |}];
  run {|
fn main() = print(Int { })
|};
  [%expect
    {|
    error: `Int` isn't a record type
      ┌─ test.ren:1:19
    1 │ fn main() = print(Int { })
      │                   ^^^
      help: it's built in; only a type declared with fields, like `type Point = { x: Int }`, is made with `Point { ... }`
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

let%expect_test "independent errors are all reported" =
  run
    (plan_types
   ^ {|
fn limit(p: Plan) -> Int =
  match p
    Free => 1
fn main() = print(Basic)
|}
    );
  [%expect
    {|
    error: this `match` doesn't handle every `Plan`
      ┌─ test.ren:9:3
    9 │   match p
      │   ^^^^^
      = missing: Pro(_), Enterprise(_)
      help: add an arm for `Pro(_)`, or a `_ =>` arm for the rest

    error: there's no constructor named `Basic`
       ┌─ test.ren:11:19
    11 │ fn main() = print(Basic)
       │                   ^^^^^
    |}]

let%expect_test "later passes don't run once one finds errors" =
  (* the type error in `main` would be found by inference, which never runs *)
  run (plan_types ^ {|
fn main() =
  print(Basic)
  1 + true
|});
  [%expect
    {|
    error: there's no constructor named `Basic`
      ┌─ test.ren:9:9
    9 │   print(Basic)
      │         ^^^^^
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

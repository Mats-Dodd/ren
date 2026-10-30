(* Exhaustiveness (exhaust.ml): every `match` handles every case, and has
   no arm that can never match. *)

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
      help: add the missing arms, or a `_ =>` arm for the rest:
        Enterprise(_) => todo
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
      help: add the missing arms, or a `_ =>` arm for the rest:
        Pro(_) => todo
        Enterprise(_) => todo
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
      help: add the missing arms, or a `_ =>` arm for the rest:
        Some(Enterprise(_)) => todo
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
      help: add the missing arms, or a `_ =>` arm for the rest:
        Pro(_) => todo
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
      help: add a `_ =>` arm to cover the remaining values:
        _ => todo
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
      help: add the missing arms, or a `_ =>` arm for the rest:
        false => todo
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

let%expect_test "independent errors are all reported" =
  run
    (plan_types
   ^ {|
fn limit(p: Plan) -> Int =
  match p
    Free => 1
fn main() =
  match true
    true => print(1)
|}
    );
  [%expect
    {|
    error: this `match` doesn't handle every `Plan`
      ┌─ test.ren:9:3
    9 │   match p
      │   ^^^^^
      = missing: Pro(_), Enterprise(_)
      help: add the missing arms, or a `_ =>` arm for the rest:
        Pro(_) => todo
        Enterprise(_) => todo

    error: this `match` doesn't handle every `Bool`
       ┌─ test.ren:12:3
    12 │   match true
       │   ^^^^^
       = missing: false
       help: add the missing arms, or a `_ =>` arm for the rest:
        false => todo
    |}]

let%expect_test "exhaustiveness isn't checked once inference finds errors" =
  (* it reads the constructor inference found for each pattern, so it never
     sees code with a type error *)
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
    error: there's no constructor named `Basic`
       ┌─ test.ren:11:19
    11 │ fn main() = print(Basic)
       │                   ^^^^^
       help: check the spelling, or declare it in a type, like `type Shape = | Basic`
    |}]

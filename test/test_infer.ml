(* Type inference (infer.ml): inferred signatures, type errors, rows, and
   what's found through a type: a field's record, a constructor, a record
   literal's type. *)

open Ren
open Helpers

let%expect_test "if without else" =
  run {|
fn main() =
  if true then 1
|};
  [%expect
    {|
    error: this `if` has no `else`, so it can't produce an `Int`
      ┌─ test.ren:2:16
    2 │   if true then 1
      │                ^
      help: add an `else` branch for when the condition is false
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
    error: expected `Int`, found `Bool`
      ┌─ test.ren:1:17
    1 │ fn main() = 1 + true
      │                 ^^^^
      = `+` works on `Int`s
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

let%expect_test "private functions need no annotations (Stage 3 milestone)" =
  let src =
    plan_types
    ^ {|
fn double(x) = x * 2

fn first_or(o, d) =
  match o
    Some(v) => v
    None => d

fn is_even(n) = if n == 0 then true else is_odd(n - 1)
fn is_odd(n) = if n == 0 then false else is_even(n - 1)

fn limit(u) =
  match u.plan
    Free => 1
    Pro(n) => n
    Enterprise(_) => 1_000

fn main() =
  print(double(21))
  print(first_or(Some(3), 0))
  print(first_or(None, true))
  print(is_even(10))
  print(limit({ id: 1, plan: Pro(4) }))
|}
  in
  types src;
  [%expect
    {|
    fn double(x: Int) -> Int
    fn first_or<T>(o: Option<T>, d: T) -> T
    fn is_even(n: Int) -> Bool
    fn is_odd(n: Int) -> Bool
    fn limit(u: User) -> Int
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    42
    3
    true
    true
    4
    ()
    |}]

let%expect_test "explicit type parameters" =
  types
    {|
fn id<T>(x: T) -> T = x
fn pair<A, B>(a: A, b: B, pick: Bool) -> Option<A> =
  if pick then Some(a) else None
fn main() = id(1) + id(2)
|};
  [%expect
    {|
    fn id<T>(x: T) -> T
    fn pair<A, B>(a: A, b: B, pick: Bool) -> Option<A>
    fn main() -> Int
    |}];
  types {|
fn f<T>(x: T) -> Int = x
fn main() = 1
|};
  [%expect
    {|
    error: expected `Int`, found `T`
      ┌─ test.ren:1:24
    1 │ fn f<T>(x: T) -> Int = x
      │                        ^
      = `f` is declared to return `Int`
      = `T` is a type parameter, so this code has to work for every type `T` could be
    |}];
  types {|
fn f<T>(x: T) = x.id
type R = { id: Int }
fn main() = 1
|};
  [%expect
    {|
    error: `.id` needs a record, but this is a `T`
      ┌─ test.ren:1:19
    1 │ fn f<T>(x: T) = x.id
      │                   ^^
    |}]

let%expect_test "type errors are caught before running" =
  run {|
fn main() =
  print(1)
  if true then 1 else false
|};
  [%expect
    {|
    error: this `else` branch is a `Bool`, but the `then` branch is an `Int`
      ┌─ test.ren:3:23
    3 │   if true then 1 else false
      │                       ^^^^^
      │                - the `then` branch is an `Int`
      = both branches of an `if` have to produce the same type
    |}];
  run {|
fn add(a, b) = a + b
fn main() = add(1, true)
|};
  [%expect
    {|
    error: expected `Int`, found `Bool`
      ┌─ test.ren:2:20
    2 │ fn main() = add(1, true)
      │                    ^^^^
    |}];
  run {|
fn main() =
  match 1
    1 => 1
    _ => false
|};
  [%expect
    {|
    error: this arm is a `Bool`, but the arms above it are an `Int`
      ┌─ test.ren:4:10
    3 │     1 => 1
      │          - the first arm is an `Int`
    4 │     _ => false
      │          ^^^^^
    |}];
  run {|
fn main() =
  match Some(1)
    Some(true) => 1
    _ => 2
|};
  [%expect
    {|
    error: expected a pattern for `Int`, but this one is a `Bool`
      ┌─ test.ren:3:10
    3 │     Some(true) => 1
      │          ^^^^
    |}];
  run {|
fn main() =
  let x = 3
  x(1)
|};
  [%expect
    {|
    error: `x` is an `Int`, not a function
      ┌─ test.ren:3:3
    3 │   x(1)
      │   ^
    |}];
  run {|
fn main() = 1 == true
|};
  [%expect
    {|
    error: `==` compares two values of the same type, but this is a `Bool` and the left side is an `Int`
      ┌─ test.ren:1:18
    1 │ fn main() = 1 == true
      │                  ^^^^
      │             - this is an `Int`
    |}];
  run {|
fn main() = y + 1
|};
  [%expect
    {|
    error: there's no variable named `y`
      ┌─ test.ren:1:13
    1 │ fn main() = y + 1
      │             ^
    |}];
  run {|
fn f(x) = f
fn main() = 1
|};
  [%expect
    {|
    error: this value's type would have to contain itself
      ┌─ test.ren:1:11
    1 │ fn f(x) = f
      │           ^
      = it would have to be `_` and `fn(_) -> _` at the same time
    |}];
  run {|
fn main(x) = 1
|};
  [%expect
    {|
    error: `main` can't take parameters
      ┌─ test.ren:1:9
    1 │ fn main(x) = 1
      │         ^
      help: remove the parameters
    |}]

let%expect_test "functions that call each other share one type" =
  types {|
fn g(x) = f(x)
fn f<T>(x: T) -> T = g(x)
fn main() = 1
|};
  [%expect
    {|
    error: `g` would have to use `T`, the type parameter of `f`
      ┌─ test.ren:1:4
    1 │ fn g(x) = f(x)
      │    ^
    2 │ fn f<T>(x: T) -> T = g(x)
      │      - `T` is declared here
      = `g` and `f` call each other, and functions that call each other are checked at a single type
      help: remove the type parameter from `f`, or break the cycle
    |}];
  types {|
fn g(x) = f(x)
fn f(x) = g(x)
fn main() = 1
|};
  [%expect
    {|
    fn g<T, U>(x: T) -> U
    fn f<T, U>(x: T) -> U
    fn main() -> Int
    |}]

let%expect_test "public functions spell out their signature" =
  types {|
pub fn f(x) -> Int = x + 1
fn main() = 1
|};
  [%expect
    {|
    error: the parameter `x` of the public function `f` has no type
      ┌─ test.ren:1:10
    1 │ pub fn f(x) -> Int = x + 1
      │          ^
      = public functions spell out their full signature
      help: write `x: Int`
    |}];
  types {|
pub fn f(x: Int) = x + 1
fn main() = 1
|};
  [%expect
    {|
    error: expected `Unit`, found `Int`
      ┌─ test.ren:1:20
    1 │ pub fn f(x: Int) = x + 1
      │                    ^^^^^
      = a public function without `->` returns `Unit`
      help: add `-> Int` to the signature
    |}];
  types {|
pub fn say(x: Int) uses Console = print(x)
fn main() = say(1)
|};
  [%expect
    {|
    pub fn say(x: Int) uses Console
    fn main() uses Console
    |}]

(* which record a field belongs to *)

let admin_types =
  {|
type User = { id: Int, name: Int }
type Admin = { id: Int, level: Int }
|}

let%expect_test "a field only one record has decides the type" =
  types (admin_types ^ {|
fn level(a) = a.level
fn main() = 1
|});
  [%expect {|
    fn level(a: Admin) -> Int
    fn main() -> Int
    |}]

let%expect_test "a shared field needs its record's type known first" =
  (* `a.level` would settle it, but it comes later: inference reads left to
     right and never waits *)
  types
    (admin_types
   ^ {|
fn score(a) =
  let x = a.id
  a.level + x
fn main() = 1
|});
  [%expect
    {|
    error: can't tell which record type `a` is
      ┌─ test.ren:5:11
    5 │   let x = a.id
      │           ^
      = `id` is a field of `Admin` and `User`
      = a field is found through its record's type, which has to be known where the field is used
      help: annotate `a` where it's defined, like `a: Admin`
    |}]

let%expect_test "a lambda takes its parameters' types from where it's going" =
  (* `apply`'s first argument says what `T` is, so its second, a lambda, is
     checked knowing its parameter is a `User` or an `Admin`, and `.id` is
     found through that *)
  run
    (admin_types
   ^ {|
fn apply<T>(x: T, f: fn(T) -> Int) -> Int = try f(x)
fn main() =
  print(apply(User { id: 1, name: 2 }, fn(u) => u.id))
  print(apply(Admin { id: 3, level: 4 }, fn(a) => a.id + a.level))
|}
    );
  [%expect {|
    1
    7
    ()
    |}];
  (* on its own, nothing says what the lambda's parameter is *)
  run
    (admin_types
   ^ {|
fn main() =
  let get = fn(u) => u.id
  print(get(User { id: 1, name: 2 }))
|}
    );
  [%expect
    {|
    error: can't tell which record type `u` is
      ┌─ test.ren:5:22
    5 │   let get = fn(u) => u.id
      │                      ^
      = `id` is a field of `Admin` and `User`
      = a field is found through its record's type, which has to be known where the field is used
      help: annotate `u` where it's defined, like `u: Admin`
    |}]

let%expect_test "results don't depend on the order functions are checked in" =
  (* `f` and `g` call each other, so they're checked together, one body
     after the other. Each body sees the other function only as its
     declaration describes it, so whichever comes first, `u.id` can't be
     found: nothing written says what `u` is. *)
  let f = {|
fn f(u, n) = if n == 0 then 0 else g(u, n - 1) + u.id|} in
  let g = {|
fn g(v, n) = if n == 0 then v.level else f(v, n - 1)|} in
  types (admin_types ^ f ^ g ^ "\nfn main() = 1\n");
  types (admin_types ^ g ^ f ^ "\nfn main() = 1\n");
  [%expect
    {|
    error: can't tell which record type `u` is
      ┌─ test.ren:4:50
    4 │ fn f(u, n) = if n == 0 then 0 else g(u, n - 1) + u.id
      │                                                  ^
      = `id` is a field of `Admin` and `User`
      = a field is found through its record's type, which has to be known where the field is used
      help: annotate `u` where it's defined, like `u: Admin`
    error: can't tell which record type `u` is
      ┌─ test.ren:5:50
    5 │ fn f(u, n) = if n == 0 then 0 else g(u, n - 1) + u.id
      │                                                  ^
      = `id` is a field of `Admin` and `User`
      = a field is found through its record's type, which has to be known where the field is used
      help: annotate `u` where it's defined, like `u: Admin`
    |}];
  (* an annotation on `g` is part of its declaration, so `f` sees it *)
  let g =
    {|
fn g(v: Admin, n: Int) -> Int = if n == 0 then v.level else f(v, n - 1)|}
  in
  types (admin_types ^ f ^ g ^ "\nfn main() = 1\n");
  types (admin_types ^ g ^ f ^ "\nfn main() = 1\n");
  [%expect
    {|
    fn f(u: Admin, n: Int) -> Int
    fn g(v: Admin, n: Int) -> Int
    fn main() -> Int
    fn g(v: Admin, n: Int) -> Int
    fn f(u: Admin, n: Int) -> Int
    fn main() -> Int
    |}]

let%expect_test "a shared field nothing pins down is an error" =
  types (admin_types ^ {|
fn get_id(u) = u.id
fn main() = 1
|});
  [%expect
    {|
    error: can't tell which record type `u` is
      ┌─ test.ren:4:16
    4 │ fn get_id(u) = u.id
      │                ^
      = `id` is a field of `Admin` and `User`
      = a field is found through its record's type, which has to be known where the field is used
      help: annotate `u` where it's defined, like `u: Admin`
    |}];
  types (admin_types ^ {|
fn get_id(u: User) = u.id
fn main() = 1
|});
  [%expect {|
    fn get_id(u: User) -> Int
    fn main() -> Int
    |}]

let%expect_test "field errors" =
  run
    (plan_types
   ^ {|
fn main() =
  let u = User { id: 1, plan: Free }
  u.name
|});
  [%expect
    {|
    error: `User` has no field named `name`
       ┌─ test.ren:10:5
    10 │   u.name
       │     ^^^^
       help: its fields: `id`, `plan`
    |}];
  run {|
fn main() = 1.x
|};
  [%expect
    {|
    error: `.x` needs a record, but this is an `Int`
      ┌─ test.ren:1:15
    1 │ fn main() = 1.x
      │               ^
    |}];
  run {|
fn f(r) = r.nope
fn main() = 1
|};
  [%expect
    {|
    error: no record type has a field named `nope`
      ┌─ test.ren:1:13
    1 │ fn f(r) = r.nope
      │             ^^^^
    |}]

let%expect_test "an untyped record literal takes the type it's used as" =
  run
    {|
type A = { x: Int }
type B = { x: Int }
fn take(a: A) -> Int = a.x + 1
fn main() = take({ x: 1 })
|};
  [%expect {| 2 |}]

(* constructors and record literals, found through a type *)

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
      help: check the spelling, or declare it in a type, like `type Shape = | Basic`
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
    error: `Plan` has no constructor named `Basic`
       ┌─ test.ren:10:5
    10 │     Basic => 1
       │     ^^^^^
       = a `Plan` is expected here
       help: its constructors: `Free`, `Pro`, `Enterprise`
    |}]

(* module-build.md, "Found through a type" *)
let light_suit =
  {|
type Light = Red | Yellow | Green
type Suit  = Red | Black

fn next(l: Light) -> Light =
  match l
    Red    => Green           // the subject is a Light, and so is the result
    Yellow => Red
    Green  => Yellow
|}

let%expect_test "two types can share a constructor's name" =
  run
    (light_suit
   ^ {|
fn main() = print(Red)        // nothing says which `Red`
|});
  [%expect
    {|
    error: `Red` could be `Light.Red` or `Suit.Red`
       ┌─ test.ren:10:19
    10 │ fn main() = print(Red)        // nothing says which `Red`
       │                   ^^^
       help: write `Light.Red`, naming the type you mean
    |}];
  run
    (light_suit
   ^ {|
fn main() =
  let s: Suit = Red
  print(next(Red))
  print(Light.Red)
  print(s == Suit.Red)
|}
    );
  [%expect {|
    Green
    Red
    true
    ()
    |}]

let%expect_test "a constructor written after its type" =
  run
    (light_suit
   ^ {|
fn red(l: Light) -> Bool =
  match l
    Light.Red => true
    _ => false
fn main() = red(Light.Red)
|}
    );
  [%expect {| true |}];
  run
    (light_suit
   ^ {|
fn main() =
  print(next(Light.Purple))
  print(next(Suit.Red))
|});
  [%expect
    {|
    error: `Light` has no constructor named `Purple`
       ┌─ test.ren:11:14
    11 │   print(next(Light.Purple))
       │              ^^^^^^^^^^^^
       help: its constructors: `Red`, `Yellow`, `Green`

    error: expected `Light`, found `Suit`
       ┌─ test.ren:12:14
    12 │   print(next(Suit.Red))
       │              ^^^^^^^^
    |}];
  run
    {|
type User = { id: Int }
fn main() =
  print(User.Some)
  print(Int.Zero)
|};
  [%expect
    {|
    error: `User` is a record, so it has no constructors
      ┌─ test.ren:3:9
    3 │   print(User.Some)
      │         ^^^^^^^^^
      help: make one with `User { ... }`

    error: `Int` is built in, and has no constructors
      ┌─ test.ren:4:9
    4 │   print(Int.Zero)
      │         ^^^^^^^^
      help: its values are written directly, like `1`, `true` or `[1, 2]`
    |}];
  run {|
fn f<T>(x: T) = T.Some
fn main() = 1
|};
  [%expect
    {|
    error: `T` is a type parameter, so it has no constructors
      ┌─ test.ren:1:17
    1 │ fn f<T>(x: T) = T.Some
      │                 ^
      help: it stands for any type at all; name a declared type instead
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
      help: give it a value too, like `plan: ...`
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

let%expect_test "every type error is reported, constructors' too" =
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
      help: check the spelling, or declare it in a type, like `type Shape = | Basic`

    error: expected `Int`, found `Bool`
       ┌─ test.ren:10:7
    10 │   1 + true
       │       ^^^^
       = `+` works on `Int`s
    |}]

(* rows: dependencies flow through calls and transparent parameters *)

let%expect_test "dependencies flow through transparent parameters" =
  types
    {|
fn twice(f: fn()) =
  try f()
  try f()

fn shout() = print(1)

fn quiet() = twice(fn() => ())
fn loud() = twice(fn() => print(1))
fn louder() = twice(shout)
fn main() = 1
|};
  [%expect
    {|
    fn twice(f: fn())
    fn shout() uses Console
    fn quiet()
    fn loud() uses Console
    fn louder() uses Console
    fn main() -> Int
    |}]

let%expect_test "a function stored in a record uses nothing" =
  run
    {|
type Button = { on_click: fn() }
fn main() = Button { on_click: fn() => print(1) }
|};
  [%expect
    {|
    error: expected `fn()`, found `fn() uses Console`
      ┌─ test.ren:2:32
    2 │ fn main() = Button { on_click: fn() => print(1) }
      │                                ^^^^^^^^^^^^^^^^
      = `Button`'s field `on_click`
    |}];
  run
    {|
type Button = { on_click: fn() -> Int }
fn main() =
  let b = Button { on_click: fn() => 4 }
  b.on_click()
|};
  [%expect {| 4 |}]

let%expect_test "a parameter written as fn(...) must stay transparent" =
  types
    {|
type Button = { on_click: fn() }
fn mk(f: fn()) = Button { on_click: f }
fn main() = 1
|};
  [%expect
    {|
    error: `f` is used as a value here, so it isn't transparent
      ┌─ test.ren:2:37
    2 │ fn mk(f: fn()) = Button { on_click: f }
      │                                     ^
      = a parameter whose type is written `fn(...)` can only be called, or passed straight to another function
      help: remove the type from `f` and let it be inferred, so its errors and dependencies are tracked wherever it goes
    |}];
  types {|
fn keep(f: fn()) = fn() => f()
fn main() = 1
|};
  [%expect
    {|
    error: `f` is captured by a lambda that outlives the call, so it isn't transparent
      ┌─ test.ren:1:20
    1 │ fn keep(f: fn()) = fn() => f()
      │                    ^^^^^^^^^^^
      = a parameter whose type is written `fn(...)` can only be called, or passed straight to another function
      help: remove the type from `f` and let it be inferred, so its errors and dependencies are tracked wherever it goes

    error: `f` can fail, and nothing handles it
      ┌─ test.ren:1:28
    1 │ fn keep(f: fn()) = fn() => f()
      │                            ^^^
      │                            - it can fail with whatever the function passed as `f` fails with
      help: pass the errors on with `try`, or handle them with `match`
    |}];
  (* following the help: inferred, its dependencies show up as ..d *)
  types {|
fn keep(f) = fn() => f()
fn main() = keep(fn() => print(1))()
|};
  [%expect
    {|
    fn keep<T>(f: fn() -> T uses ..d) -> (fn() -> T uses ..d)
    fn main() uses Console
    |}];
  (* passing it on, directly or inside a lambda, is fine *)
  types
    {|
fn twice(f: fn()) =
  try f()
  try f()
fn four(f: fn()) =
  try twice(f)
  try twice(fn() => try f())
fn main() = 1
|};
  [%expect
    {|
    fn twice(f: fn())
    fn four(f: fn())
    fn main() -> Int
    |}]

(* the row unifier on its own *)

let%expect_test "row unification" =
  let open Types in
  let st = new_state () in
  let row labels tail =
    List.fold_right (fun l r -> RExtend (dep l, r)) labels tail
  in
  let show r =
    let pr = printer ~show_tail:(fun _ -> true) ~names:Path.full st in
    match show_row pr ~prefix:"" ~sep:", " ~kind:"d" r with
    | "" -> "<>"
    | s -> "<" ^ s ^ ">"
  in
  let try_unify a b =
    match Unify.unify_row st a b with
    | () -> print_endline (show a ^ " = " ^ show b)
    | exception Unify.Mismatch -> print_endline "mismatch"
    | exception Unify.Infinite -> print_endline "infinite"
  in
  (* order doesn't matter *)
  try_unify
    (row [ "Console"; "Clock" ] REmpty)
    (row [ "Clock"; "Console" ] REmpty);
  (* an open row grows to supply what's missing *)
  let r1 = fresh_row st and r2 = fresh_row st in
  try_unify (row [ "Console" ] r1) (row [ "Clock" ] r2);
  (* a closed row can't *)
  try_unify (row [ "Console" ] REmpty) (row [ "Clock" ] (fresh_row st));
  try_unify REmpty (row [ "Console" ] (fresh_row st));
  (* the same tail with different labels can't be made equal *)
  let r = fresh_row st in
  try_unify (row [ "Console" ] r) (row [ "Clock" ] r);
  (* a row can't contain itself *)
  let r = fresh_row st in
  try_unify r (row [ "Console" ] r);
  [%expect
    {|
    <Clock, Console> = <Clock, Console>
    <Clock, Console, ..d> = <Clock, Console, ..d>
    mismatch
    mismatch
    mismatch
    infinite
    |}]

let%expect_test "inout in signatures" =
  types
    {|
fn bump(inout n) =
  n += 1
fn apply(f: fn(inout Int), inout x: Int) =
  try f(&x)
fn main() =
  var a = 1
  apply(bump, &a)
|};
  [%expect
    {|
    fn bump(inout n: Int)
    fn apply(f: fn(inout Int), inout x: Int)
    fn main()
    |}]

let%expect_test "inout is part of a function's type" =
  (* if `ap` could take `bump`, `ap` would call it without `&` and the push
     would be lost *)
  run
    {|
fn bump(inout xs: Array<Int>) = &xs.push(1)
fn ap(f, x) = f(x)
fn main() =
  var xs = [0]
  ap(bump, &xs)
  print(xs)
|};
  [%expect
    {|
    error: expected `fn(_) -> _`, found `fn(inout Array<Int>)`
      ┌─ test.ren:5:6
    5 │   ap(bump, &xs)
      │      ^^^^
      = a function that changes its argument (`inout`) can't stand in for one that only reads it: its caller wouldn't pass the argument with `&`, so the change would be lost
      help: pass it only where the parameter's type says `fn(inout ...)`, or call it directly

    error: `ap` doesn't change this argument
      ┌─ test.ren:5:12
    5 │   ap(bump, &xs)
      │            ^^^
      = `&` marks an argument the call changes: an `inout` parameter
      help: remove the `&`
    |}];
  run
    {|
fn apply(f: fn(inout Int), inout x: Int) = try f(&x)
fn main() =
  var a = 1
  apply(fn(n) => (), &a)
|};
  [%expect
    {|
    error: expected `fn(inout Int)`, found `fn(_)`
      ┌─ test.ren:4:9
    4 │   apply(fn(n) => (), &a)
      │         ^^^^^^^^^^^
      = a function that only reads its argument can't stand in for one that changes it (`inout`)
    |}]

let%expect_test "an inout argument needs &" =
  run
    {|
fn bump(inout n: Int) =
  n += 1
fn main() =
  var a = 1
  bump(a)
  a
|};
  [%expect
    {|
    error: `bump` changes this argument, so it needs `&`
      ┌─ test.ren:5:8
    5 │   bump(a)
      │        ^
      = `&` shows at the call that the argument is changed
      help: write `&` before it, as in `&a`
    |}]

let%expect_test "& on a parameter that isn't inout" =
  run {|
fn id(n: Int) -> Int = n
fn main() =
  var a = 1
  id(&a)
|};
  [%expect
    {|
    error: `id` doesn't change this argument
      ┌─ test.ren:4:6
    4 │   id(&a)
      │      ^^
      = `&` marks an argument the call changes: an `inout` parameter
      help: remove the `&`
    |}]

let%expect_test "an if without else is Unit" =
  run {|
fn main() -> Int =
  if true then 1
|};
  [%expect
    {|
    error: this `if` has no `else`, so it can't produce an `Int`
      ┌─ test.ren:2:16
    2 │   if true then 1
      │                ^
      help: add an `else` branch for when the condition is false
    |}]

let%expect_test "&&, || and not work on Bools" =
  types {|
fn both(a, b) = a && not b || b
fn main() = both(true, false)
|};
  [%expect
    {|
    fn both(a: Bool, b: Bool) -> Bool
    fn main() -> Bool
    |}];
  types {|
fn main() =
  let a = 1 && true
  let b = false || 2
  not 3
|};
  [%expect
    {|
    error: expected `Bool`, found `Int`
      ┌─ test.ren:2:11
    2 │   let a = 1 && true
      │           ^
      = each side of `&&` has to be a `Bool`

    error: expected `Bool`, found `Int`
      ┌─ test.ren:3:20
    3 │   let b = false || 2
      │                    ^
      = each side of `||` has to be a `Bool`

    error: expected `Bool`, found `Int`
      ┌─ test.ren:4:7
    4 │   not 3
      │       ^
      = what `not` is applied to has to be a `Bool`
    |}]

let%expect_test "array type errors" =
  run {|
fn main() = [1, true]
|};
  [%expect
    {|
    error: this element is a `Bool`, but the elements before it are an `Int`
      ┌─ test.ren:1:17
    1 │ fn main() = [1, true]
      │                 ^^^^
    |}]

let%expect_test "assignment type errors" =
  run {|
fn main() =
  var x = 1
  x = true
|};
  [%expect
    {|
    error: this is a `Bool`, but it's being assigned to an `Int`
      ┌─ test.ren:3:7
    3 │   x = true
      │       ^^^^
    |}]

let%expect_test "for needs an array" =
  run {|
fn main() =
  for x in 3
    print(x)
|};
  [%expect
    {|
    error: a `for` loop goes over an `Array`, but this is an `Int`
      ┌─ test.ren:2:12
    2 │   for x in 3
      │            ^
    |}]

(* every independent error, and none that follow from one already reported *)

let%expect_test "independent type errors are all reported" =
  run
    {|
fn f() = 1 + true
fn g() = if 1 then 2 else 3
fn main() = f() == true
|};
  [%expect
    {|
    error: expected `Int`, found `Bool`
      ┌─ test.ren:1:14
    1 │ fn f() = 1 + true
      │              ^^^^
      = `+` works on `Int`s

    error: expected `Bool`, found `Int`
      ┌─ test.ren:2:13
    2 │ fn g() = if 1 then 2 else 3
      │             ^
      = an `if` condition has to be a `Bool`

    error: `==` compares two values of the same type, but this is a `Bool` and the left side is an `Int`
      ┌─ test.ren:3:20
    3 │ fn main() = f() == true
      │                    ^^^^
      │             --- this is an `Int`
    |}]

let%expect_test "an error isn't reported again where its value goes" =
  run
    {|
fn main() =
  let s = 5[0]
  let t = s + 1
  print(s.name)
  if s then s(1) else t
|};
  [%expect
    {|
    error: only an `Array` can be indexed, but this is an `Int`
      ┌─ test.ren:2:11
    2 │   let s = 5[0]
      │           ^
    |}];
  run {|
fn main() =
  let n = missing
  n.size + n(1)
|};
  [%expect
    {|
    error: there's no variable named `missing`
      ┌─ test.ren:2:11
    2 │   let n = missing
      │           ^^^^^^^
    |}]

let%expect_test "inference records what it found through a type" =
  (* for each function, every expression's type and what each lookup found,
     by node id: the same program gives equal tables every time *)
  let src =
    clean
      (admin_types
     ^ {|
fn main() =
  let u = { id: 1, name: 2 }
  match Some(u.name)
    Some(n) => print(n)
    None => ()
|}
      )
  in
  let first = Driver.inferred ~file src in
  ignore (Driver.inferred ~file (clean {|
fn main() = print(Some(true))
|}));
  let second = Driver.inferred ~file src in
  print_endline
    (string_of_bool
       (List.equal
          (fun (a, x) (b, y) -> a = b && Infer.Nodes.equal ( = ) x y)
          first.nodes second.nodes));
  let path (p : Path.t) = p.home ^ "." ^ p.name in
  Infer.Nodes.iter
    (fun _ (n : Infer.node) ->
      match n.found with
      | Some (Field_of p) -> print_endline ("field of " ^ path p)
      | Some (Ctor_of (p, c)) ->
          print_endline ("constructor " ^ c ^ " of " ^ path p)
      | Some (Method_of p) -> print_endline ("method " ^ path p)
      | Some (Installs p) -> print_endline ("installs " ^ path p)
      | Some Wraps -> print_endline "wraps"
      | None -> ())
    (List.assoc "main" second.nodes);
  [%expect
    {|
    true
    field of test.User
    constructor Some of prelude.Option
    constructor Some of prelude.Option
    constructor None of prelude.Option
    |}]

let%expect_test "a public function's interface comes from its signature" =
  (* the interface is built from declarations alone; for a public function
     it's the same type inference finds for it. A parameter written
     `fn(...)` is transparent, so its rows are the function's; any other
     function type in a parameter is closed. A transparent parameter shares
     the function's row, labels and all, so `logged`'s `Console` shows on both. *)
  let src =
    clean
      {|
pub fn twice(f: fn()) =
  try f()
  try f()
pub fn say(x: Int) uses Console = print(x)
pub fn logged(f: fn()) uses Console =
  try f()
  print(1)
pub fn app(f: fn(fn() -> Int) -> Int) -> Int = try f(fn() => 1)
pub fn maybe(f: Option<fn()>) =
  match f
    Some(g) => g()
    None => ()
fn main() = twice(fn() => say(1))
|}
  in
  let iface = Driver.interface ~file src in
  let schemes = Driver.schemes ~file src in
  List.iter
    (fun (v : Iface.value) ->
      let pr =
        Ty.printer ~show_tail:(fun _ -> true) ~names:Path.full v.scheme
      in
      Printf.printf "%s: %s (%s)\n" v.vname (Ty.show pr v.scheme.ty)
        (if List.assoc v.vname schemes = v.scheme then "as inferred"
         else "differs from inference"))
    iface.values;
  [%expect
    {|
    twice: fn(fn() ! ..e uses ..d) ! ..e uses ..d (as inferred)
    say: fn(Int) ! ..e uses Console, ..d (as inferred)
    logged: fn(fn() ! ..e uses Console, ..d) ! ..e uses Console, ..d (as inferred)
    app: fn(fn(fn() -> Int) -> Int ! ..e uses ..d) -> Int ! ..e uses ..d (as inferred)
    maybe: fn(Option<fn()>) ! ..e uses ..d (as inferred)
    |}]

let%expect_test "a function type inside a parameter is closed" =
  (* only a parameter written `fn(...)` is transparent; any other function
     type in a signature uses and fails with nothing, as in a declaration,
     so the body is checked at the type the interface shows *)
  run
    {|
pub fn maybe(f: Option<fn()>) =
  match f
    Some(g) => g()
    None => ()
fn main() = maybe(Some(fn() => print(1)))
|};
  [%expect
    {|
    error: expected `Option<fn()>`, found `Option<fn() uses Console>`
      ┌─ test.ren:5:19
    5 │ fn main() = maybe(Some(fn() => print(1)))
      │                   ^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "calling a stored closure leaves the caller open" =
  (* a closed `fn()` adds nothing to its caller's errors and dependencies,
     so `main` can still use `Console` after calling `g` *)
  let src =
    {|
type B = { f: fn() }
fn g(b: B) = b.f()
fn main() =
  print(1)
  g(B { f: fn() => () })
|}
  in
  types src;
  run src;
  [%expect {|
    fn g(b: B)
    fn main() uses Console
    1
    ()
    |}]

let%expect_test "a misspelled field is reported once" =
  run
    {|
type A = { id: Int, name: Int }
fn main() = print(A { id: 1, nam: 2 }.id)
|};
  [%expect
    {|
    error: `A` has no field named `nam`
      ┌─ test.ren:2:30
    2 │ fn main() = print(A { id: 1, nam: 2 }.id)
      │                              ^^^
      help: its fields: `id`, `name`
    |}]

let%expect_test "functions that call each other see each other as declared" =
  (* inside `f`, `g` is only what its signature says, so its result's
     record type isn't known there; declaring it fixes that *)
  let src ret =
    Printf.sprintf
      {|
type A = { id: Int, name: Int }
type B = { id: Int, age: Int }
fn f(n) = if n == 0 then 0 else g(n).id
fn g(n)%s = if n == 0 then A { id: 1, name: 2 } else A { id: f(n - 1), name: 0 }
fn main() = print(f(3))
|}
      ret
  in
  run (src "");
  run (src " -> A");
  [%expect
    {|
    error: can't tell which record type this is
      ┌─ test.ren:3:33
    3 │ fn f(n) = if n == 0 then 0 else g(n).id
      │                                 ^^^^
      = `id` is a field of `A` and `B`
      = a field is found through its record's type, which has to be known where the field is used
      = `g` and this function call each other, so here `g` is only what its signature says
      help: declare what `g` returns, like `-> A`
    0
    ()
    |}]

let%expect_test "inferred types are canonical" =
  (* the same program gives equal types, even after checking another
     program in the same process: no counter carries over between
     compilations, and variables are numbered by where they appear *)
  let src =
    clean
      {|
fn map_option(o, f) =
  match o
    Some(v) => Some(f(v))
    None => None
fn pick<A, B>(a: A, b: B) -> A = a
fn main() = print(map_option(Some(1), fn(n) => n + 1))
|}
  in
  let first = Driver.schemes ~file src in
  ignore
    (Driver.schemes ~file
       (clean {|
fn other(x, y, z) = x
fn main() = other(1, true, ())
|}));
  let second = Driver.schemes ~file src in
  print_endline (string_of_bool (first = second));
  (* `pick` keeps the names it declared; the other variables have none *)
  List.iter
    (fun (name, (s : Ty.scheme)) ->
      Printf.printf "%s: %s\n" name
        (String.concat ", "
           (List.map (fun (n, h) -> Printf.sprintf "%d=%s" n h) s.names)))
    second;
  [%expect {|
    true
    map_option:
    pick: 0=A, 1=B
    main:
    |}]

(* ---- what a function declares it uses ---- *)

let%expect_test "a dependency that doesn't exist" =
  types {|
fn f() uses Console, Disk = 1
fn main() = f()
|};
  [%expect
    {|
    error: there's no dependency named `Disk`
      ┌─ test.ren:1:22
    1 │ fn f() uses Console, Disk = 1
      │                      ^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Net`, `Random`, `Unsafe`
      help: use one of those, or declare it with `dep`
    |}]

let%expect_test "a public function declares what it uses" =
  (* the error points at the first call that brings the dependency in,
     even through a private function that inferred it *)
  types
    {|
fn log(x: Int) = print(x)
pub fn load(x: Int) -> Int =
  let y = x + 1
  log(y)
  print(y)
  y
fn main() = load(1)
|};
  [%expect
    {|
    error: `load` doesn't declare `Console`
      ┌─ test.ren:2:8
    2 │ pub fn load(x: Int) -> Int =
      │        ^^^^
    4 │   log(y)
      │   ------ this call uses `Console`
      = a public function without `uses` uses nothing, and its body is checked against that
      help: add `uses Console`
    |}]

let%expect_test "a public function stored as a value in its own body" =
  (* storing `f` as a `fn()` closes the rows of that use of it, not those
     its declaration gives it *)
  types
    {|
type H = { h: fn() }
pub fn f() =
  let x = H { h: f }
  ()
fn main() = f()
|};
  [%expect {|
    pub fn f()
    fn main()
    |}]

let%expect_test "a pure call before the one that uses something" =
  (* `pure` and `len` are called first, but they don't use `Console`: once
     their open rows are joined to `go`'s, those rows have what `go` uses,
     which mustn't make them the call to blame *)
  types
    {|
fn pure(n) = n + 1
pub fn go(n: Int) -> Int =
  let a = pure(n)
  let b = [n].len()
  print(a + b)
  a
fn main() = go(1)
|};
  [%expect
    {|
    error: `go` doesn't declare `Console`
      ┌─ test.ren:2:8
    2 │ pub fn go(n: Int) -> Int =
      │        ^^
    5 │   print(a + b)
      │   ------------ this call uses `Console`
      = a public function without `uses` uses nothing, and its body is checked against that
      help: add `uses Console`
    |}]

let%expect_test "a private function's uses are checked if it writes them" =
  types
    {|
fn tick() uses Clock = print(1)
fn quiet() = print(2)
fn main() =
  tick()
  quiet()
|};
  [%expect
    {|
    error: `tick` doesn't declare `Console`
      ┌─ test.ren:1:4
    1 │ fn tick() uses Clock = print(1)
      │    ^^^^
      │                        -------- this call uses `Console`
      = `tick`'s body can only use what its `uses` lists
      help: add `Console` to its `uses`
    |}]

let%expect_test "declaring more than the body uses is allowed" =
  (* the interface says what's declared, so the body can start using it
     later without changing the interface *)
  types
    {|
pub fn later() uses Console, Clock = ()
pub fn now(x: Int) -> Int
    uses Console =
  print(x)
  x
fn main() =
  later()
  now(1)
|};
  [%expect
    {|
    pub fn later() uses Clock, Console
    pub fn now(x: Int) -> Int uses Console
    fn main() -> Int uses Clock, Console
    |}]

let%expect_test
    "a transparent parameter's uses flow through a declared function" =
  run
    {|
pub fn twice(f: fn()) uses Console =
  print(0)
  try f()
  try f()
fn main() = twice(fn() => print(1))
|};
  [%expect {|
    0
    1
    1
    ()
    |}]

let%expect_test "a use found when a group's functions are joined" =
  (* `ping` sees `pong` as declared until both are checked; only then is
     it known that `pong`'s body uses `Console` *)
  types
    {|
pub fn ping(n: Int) -> Int uses Clock =
  if n == 0 then 0 else pong(n - 1)
fn pong(n) =
  print(n)
  ping(n)
fn main() = ping(3)
|};
  [%expect
    {|
    error: `ping` doesn't declare `Console`
      ┌─ test.ren:1:8
    1 │ pub fn ping(n: Int) -> Int uses Clock =
      │        ^^^^
    2 │   if n == 0 then 0 else pong(n - 1)
      │                         ----------- this call uses `Console`
      = `ping`'s body can only use what its `uses` lists
      help: add `Console` to its `uses`
    |}]

(* ---- nothing is dropped (errors.md, "Nothing is dropped") ---- *)

let%expect_test "a statement's value has to be Unit" =
  run
    {|
type Bag = { xs: Array<Int> }
  fn add(inout self, x: Int) -> Option<Int> =
    &self.xs.push(x)
    None

fn count(xs: Array<Int>) -> Int = xs.len()

fn main() =
  var b = Bag { xs: [1] }
  &b.add(2)
  count(b.xs)
  b.xs.len() + 1
  if b.xs.len() == 0 then 1 else 2
  for x in b.xs
    x * 2
  ()
|};
  [%expect
    {|
    error: `add` returns `Option<Int>`, and this throws it away
       ┌─ test.ren:10:3
    10 │   &b.add(2)
       │   ^^^^^^^^^
       help: use it, or write `let _ = ...` if you mean to drop it

    error: `count` returns `Int`, and this throws it away
       ┌─ test.ren:11:3
    11 │   count(b.xs)
       │   ^^^^^^^^^^^
       help: use it, or write `let _ = ...` if you mean to drop it

    error: this is an `Int`, and it's thrown away
       ┌─ test.ren:12:3
    12 │   b.xs.len() + 1
       │   ^^^^^^^^^^^^^^
       help: use it, or write `let _ = ...` if you mean to drop it

    error: this is an `Int`, and it's thrown away
       ┌─ test.ren:13:3
    13 │   if b.xs.len() == 0 then 1 else 2
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       help: use it, or write `let _ = ...` if you mean to drop it

    error: this is an `Int`, and it's thrown away
       ┌─ test.ren:15:5
    15 │     x * 2
       │     ^^^^^
       help: use it, or write `let _ = ...` if you mean to drop it
    |}]

let%expect_test "let _ drops a value on purpose" =
  run
    {|
fn main() =
  let xs = [1, 2]
  let _ = xs.len() + 1
  let _ = 3
  xs
|};
  [%expect {| [1, 2] |}];
  run {|
fn main() =
  let _ = 1
  _
|};
  [%expect
    {|
    error: `_` drops a value, so it can't be read
      ┌─ test.ren:3:3
    3 │   _
      │   ^
      help: give the value a name, `let x = ...`, to use it
    |}]

let%expect_test "a dropped call of the same group is checked once it's joined" =
  types
    {|
fn even(n) = if n == 0 then true else odd(n - 1)
fn odd(n) =
  even(n)
  if n == 0 then false else even(n - 1)
fn main() = odd(3)
|};
  [%expect
    {|
    error: `even` returns `Bool`, and this throws it away
      ┌─ test.ren:3:3
    3 │   even(n)
      │   ^^^^^^^
      help: use it, or write `let _ = ...` if you mean to drop it
    |}]

let%expect_test "a dropped value nothing pins down is Unit" =
  types {|
fn twice(f) =
  f()
  f()
fn main() = twice() fn() => ()
|};
  [%expect {|
    fn twice(f: fn() uses ..d) uses ..d
    fn main()
    |}]

let%expect_test "a mismatch with a dropped value made Unit points back at it" =
  (* the caller can't see why `apply` wants a `Unit`, so the error shows
     the statement that made it one; `let _ =` keeps it generic *)
  types
    {|
fn apply(f, x) =
  f(x)
  ()
fn keep(f, x) =
  let _ = f(x)
  ()
fn main() =
  keep(fn(n) => n + 1, 2)
  apply(fn(n) => n + 1, 2)
|};
  [%expect
    {|
    error: this lambda produces an `Int`, but it has to produce a `Unit`
      ┌─ test.ren:9:18
    2 │   f(x)
      │   ---- `apply` throws this value away, and its type wasn't known, so it was taken to be `Unit`
    9 │   apply(fn(n) => n + 1, 2)
      │                  ^^^^^
      help: if `apply` means to drop a value of any type there, write `let _ = ...`
    |}]

let%expect_test "a and an go by the sound" =
  types
    {|
type User = { id: Int }
type Undo = { id: Int }
fn make(f: fn() -> User, g: fn() -> Undo) = ()
fn main() = make(fn() => 1, fn() => 2)
|};
  [%expect
    {|
    error: this lambda produces an `Int`, but it has to produce a `User`
      ┌─ test.ren:4:26
    4 │ fn main() = make(fn() => 1, fn() => 2)
      │                          ^

    error: this lambda produces an `Int`, but it has to produce an `Undo`
      ┌─ test.ren:4:37
    4 │ fn main() = make(fn() => 1, fn() => 2)
      │                                     ^
    |}]

let%expect_test "an empty error set is written `!`, as it's printed" =
  types
    {|
fn h(r: Result<Int, ! X>) = match r
  Ok(n) => Ok(n)
  Err(X) => Ok(0)
fn k(r: Result<Int, !>) -> Result<Int, !> = r
fn main() = ()
|};
  [%expect
    {|
    fn h(r: Result<Int, ! X>) -> Result<Int, !>
    fn k(r: Result<Int, !>) -> Result<Int, !>
    fn main()
    |}]

let%expect_test "a string is a Str" =
  types
    {|
fn name() = "Ren"
fn same(a, b) = a == b
fn label(n: Int) -> Str = show(n)
fn main() = same(name(), label(1))
|};
  [%expect
    {|
    fn name() -> Str
    fn same<T>(a: T, b: T) -> Bool
    fn label(n: Int) -> Str
    fn main() -> Bool
    |}];
  types {|
fn main() = "1" == 1
|};
  [%expect
    {|
    error: `==` compares two values of the same type, but this is an `Int` and the left side is a `Str`
      ┌─ test.ren:1:20
    1 │ fn main() = "1" == 1
      │                    ^
      │             --- this is a `Str`
    |}]

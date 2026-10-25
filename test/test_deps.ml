(* Dependencies (deps.md): declaring one with `dep`, calling its
   operations, implementations, and what the runtime installs. *)

open Helpers

let%expect_test "a dependency lists its operations, then its members" =
  ast
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
  save: fn(u: Int) ! Conflict

  pub fn none() -> Users = Users { get: fn(_) => None, save: fn(_) => () }
|};
  [%expect
    {| (pub dep Users (ops get:fn(Int) -> Option<Int> save:fn(Int) ! Conflict) (members (pub (fn none () (record Users get=(lambda (_) (con None)) save=(lambda (_) ())))))) |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
  save: fn(u: Int) ! Conflict

  pub fn none() -> Users = Users { get: fn(_) => None, save: fn(_) => () }

fn main() = 1
|};
  [%expect
    {|
    pub dep Users
      get: fn(Int) -> Option<Int>
      save: fn(Int) ! Conflict
      pub fn none() -> Users
    fn main() -> Int
    |}]

let%expect_test "calling an operation adds its dependency to uses" =
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
  save: fn(u: Int) ! Conflict

fn find(id: Int) = Users.get(id)
fn store(u) = try Users.save(u)
fn both(u: Int) =
  let _ = find(u)
  try store(u)
pub fn declared(id: Int) -> Option<Int> uses Users = Users.get(id)
fn main() = 1
|};
  [%expect
    {|
    pub dep Users
      get: fn(Int) -> Option<Int>
      save: fn(Int) ! Conflict
    fn find(id: Int) -> Option<Int> uses Users
    fn store(u: Int) ! Conflict uses Users
    fn both(u: Int) ! Conflict uses Users
    pub fn declared(id: Int) -> Option<Int> uses Users
    fn main() -> Int
    |}]

let%expect_test "a public function lists the dependencies its calls use" =
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

pub fn find(id: Int) -> Option<Int> =
  let first = Users.get(id)
  first
fn main() = 1
|};
  [%expect
    {|
    error: `find` doesn't declare `Users`
      ┌─ test.ren:4:8
    4 │ pub fn find(id: Int) -> Option<Int> =
      │        ^^^^
    5 │   let first = Users.get(id)
      │               ------------- this call uses `Users`
      = a public function without `uses` uses nothing, and its body is checked against that
      help: add `uses Users`
    |}]

let%expect_test "an operation's errors are marked as any call's" =
  types
    {|
dep Users =
  save: fn(u: Int) ! Conflict

fn store(u: Int) = Users.save(u)
fn main() = 1
|};
  [%expect
    {|
    error: `Users.save` can fail, and nothing handles it
      ┌─ test.ren:4:20
    4 │ fn store(u: Int) = Users.save(u)
      │                    ^^^^^^^^^^^^^
      │                    ---------- it can fail with `Conflict`
      help: pass the errors on with `try`, or handle them with `match`
    |}]

let%expect_test "an operation and a member can't share a name" =
  types
    {|
dep Timer =
  now: fn() -> Int

  pub fn now() -> Int = 0
fn main() = 1
|};
  [%expect
    {|
    error: `Timer` has an operation and a member both named `now`
      ┌─ test.ren:4:10
    2 │   now: fn() -> Int
      │   --- the operation `now` is here
    4 │   pub fn now() -> Int = 0
      │          ^^^
      = `Timer.now` has to mean one thing: calling the installed implementation's `now`, or this member
      help: rename one of them
    |}]

let%expect_test "two operations with one name" =
  types {|
dep Timer =
  now: fn() -> Int
  now: fn() -> Bool
fn main() = 1
|};
  [%expect
    {|
    error: there are two operations named `now`
      ┌─ test.ren:3:3
    2 │   now: fn() -> Int
      │   --- the first `now` is here
    3 │   now: fn() -> Bool
      │   ^^^
      help: rename one of them
    |}]

let%expect_test "what a dependency's declaration can't be" =
  ast {|
dep Timer =
  now: Int
|};
  [%expect
    {|
    error: `now` is an operation, so its type is a function's, but this is `Int`
      ┌─ test.ren:2:8
    2 │   now: Int
      │        ^^^
      help: write its type as a function's, like `now: fn() -> Int`
    |}];
  ast {|
dep Timer =
  pub fn zero() -> Int = 0
|};
  [%expect
    {|
    error: `Timer` has no operations: a dependency lists them first
      ┌─ test.ren:2:3
    2 │   pub fn zero() -> Int = 0
      │   ^^^
      help: list its operations first, like `now: fn() -> Time`, then its members
    |}];
  ast
    {|
dep Timer =
  now: fn() -> Int

  pub fn zero() -> Int = 0
  sleep: fn(ms: Int)
|};
  [%expect
    {|
    error: expected `fn`, `let` or an operator, in `Timer`'s members, found `sleep`
      ┌─ test.ren:5:3
    5 │   sleep: fn(ms: Int)
      │   ^^^^^
      help: a dependency's operations come first, before its members
    |}];
  ast {|
dep Timer = now: fn() -> Int
|};
  [%expect
    {|
    error: expected the operations of `Timer`, found `now`
      ┌─ test.ren:1:13
    1 │ dep Timer = now: fn() -> Int
      │             ^^^
      help: put each of its operations on a line of its own, indented under it, like `now: fn() -> Time`
    |}];
  ast {|
dep Box<T> =
  get: fn() -> T
|};
  [%expect
    {|
    error: a dependency can't take type parameters
      ┌─ test.ren:1:8
    1 │ dep Box<T> =
      │        ^
      help: remove them
    |}]

let%expect_test "uses names a dependency" =
  types {|
fn f() uses Int = 1
fn g() uses Nope = 1
fn main() = 1
|};
  [%expect
    {|
    error: `Int` is a type, not a dependency
      ┌─ test.ren:1:13
    1 │ fn f() uses Int = 1
      │             ^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: there's no dependency named `Nope`
      ┌─ test.ren:2:13
    2 │ fn g() uses Nope = 1
      │             ^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Net`, `Random`, `Unsafe`
      help: use one of those, or declare it with `dep`
    |}]

let%expect_test "an implementation is a record of its operations" =
  types
    {|
dep Timer =
  now: fn() -> Int
  sleep: fn(ms: Int)

fn frozen(at: Int) -> Timer = Timer { now: fn() => at, sleep: fn(_) => () }
fn main() = frozen(0)
|};
  [%expect
    {|
    dep Timer
      now: fn() -> Int
      sleep: fn(Int)
    fn frozen(at: Int) -> Timer
    fn main() -> Timer
    |}];
  types
    {|
dep Timer =
  now: fn() -> Int
  sleep: fn(ms: Int)

fn half() = Timer { now: fn() => 1 }
fn typo() = Timer { now: fn() => 1, slep: fn(_) => () }
fn wrong() = Timer { now: fn() => true, sleep: fn(_) => () }
fn main() = 1
|};
  [%expect
    {|
    error: this `Timer` is missing `sleep`
      ┌─ test.ren:5:13
    5 │ fn half() = Timer { now: fn() => 1 }
      │             ^^^^^^^^^^^^^^^^^^^^^^^^
      help: give it a value too, like `sleep: ...`

    error: `Timer` has no operation named `slep`
      ┌─ test.ren:6:37
    6 │ fn typo() = Timer { now: fn() => 1, slep: fn(_) => () }
      │                                     ^^^^
      help: its operations: `now`, `sleep`

    error: this lambda produces a `Bool`, but it has to produce an `Int`
      ┌─ test.ren:7:35
    7 │ fn wrong() = Timer { now: fn() => true, sleep: fn(_) => () }
      │                                   ^^^^
      = `Timer`'s operation `now`
    |}]

let%expect_test "an operation isn't read from an implementation" =
  types
    {|
dep Timer =
  now: fn() -> Int

fn read(c: Timer) = c.now
fn call(c: Timer) = c.now()
fn other(c: Timer) = c.later()
fn main() = 1
|};
  [%expect
    {|
    error: `now` is an operation of `Timer`, so it isn't read from a value
      ┌─ test.ren:4:23
    4 │ fn read(c: Timer) = c.now
      │                       ^^^
      = a value of `Timer` is an implementation of it: it's used by installing it, with `with`, and then `Timer.now` calls it
      help: call the installed one: `Timer.now(...)`

    error: `now` is an operation of `Timer`, so it isn't read from a value
      ┌─ test.ren:5:23
    5 │ fn call(c: Timer) = c.now()
      │                       ^^^
      = a value of `Timer` is an implementation of it: it's used by installing it, with `with`, and then `Timer.now` calls it
      help: call the installed one: `Timer.now(...)`

    error: `Timer` has no operation named `later`
      ┌─ test.ren:6:24
    6 │ fn other(c: Timer) = c.later()
      │                        ^^^^^
      help: its operations: `now`
    |}];
  types {|
dep Timer =
  now: fn() -> Int

fn main() = Timer.later()
|};
  [%expect
    {|
    error: `Timer` has no operation or member named `later`
      ┌─ test.ren:4:19
    4 │ fn main() = Timer.later()
      │                   ^^^^^
      help: its operations: `now`
    |}]

let%expect_test "another module's dependency" =
  types_files
    [
      ( "main.ren",
        {|
import store

pub fn find(id: Int) -> Option<Int> uses store.Users = store.Users.get(id)
fn look(id: Int) = store.Users.get(id)
fn main() = 1
|}
      );
      ("store.ren", {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
|});
    ];
  [%expect
    {|
    -- store
    pub dep Users
      get: fn(Int) -> Option<Int>

    -- main
    pub fn find(id: Int) -> Option<Int> uses store.Users
    fn look(id: Int) -> Option<Int> uses store.Users
    fn main() -> Int
    |}]

let%expect_test "a public signature can't use a private dependency" =
  types
    {|
dep Users =
  get: fn(id: Int) -> Option<Int>

pub fn find(id: Int) -> Option<Int> uses Users = Users.get(id)
fn main() = 1
|};
  [%expect
    {|
    error: `pub fn find` uses `Users`, which is private to this module
      ┌─ test.ren:4:42
    1 │ dep Users =
      │     ----- `Users` is declared here, without `pub`
    4 │ pub fn find(id: Int) -> Option<Int> uses Users = Users.get(id)
      │                                          ^^^^^
      help: mark `Users` `pub`
    |}]

let%expect_test "the runtime installs only the built-in dependencies main uses"
    =
  run {|
fn main() =
  print(1)
  Console.write("written")
|};
  [%expect {|
    1
    written
    ()
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

  pub fn none() -> Users = Users { get: fn(_) => None }

fn main() uses Users, Console =
  print(Users.get(1))
|};
  [%expect
    {|
    error: nothing installs `Users` before `main`
      ┌─ test.ren:6:16
    6 │ fn main() uses Users, Console =
      │                ^^^^^
      = the runtime installs only `Clock`, `Random` and `Console`
      help: install one inside `main`: `with Users.none() in ...`
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

fn mem_users(ids: Array<Int>) -> Users = Users { get: fn(id) => None }
fn find(id: Int) = Users.get(id)

fn main() = print(find(1))
|};
  [%expect
    {|
    error: nothing installs `Users` before `main`
      ┌─ test.ren:7:4
    7 │ fn main() = print(find(1))
      │    ^^^^
      │                   ------- this call uses `Users`
      = the runtime installs only `Clock`, `Random` and `Console`
      help: install one inside `main`: `with mem_users(...) in ...`
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

fn main() uses Net = print(Users.get(1))
|};
  [%expect
    {|
    error: `main` doesn't declare `Console`
      ┌─ test.ren:4:4
    4 │ fn main() uses Net = print(Users.get(1))
      │    ^^^^
      │                      ------------------- this call uses `Console`
      = `main`'s body can only use what its `uses` lists
      help: add `Console` to its `uses`

    error: `main` doesn't declare `Users`
      ┌─ test.ren:4:4
    4 │ fn main() uses Net = print(Users.get(1))
      │    ^^^^
      │                            ------------ this call uses `Users`
      = `main`'s body can only use what its `uses` lists
      help: add `Users` to its `uses`

    error: nothing installs `Net` before `main`
      ┌─ test.ren:4:16
    4 │ fn main() uses Net = print(Users.get(1))
      │                ^^^
      = the runtime installs only `Clock`, `Random` and `Console`
      help: remove it: nothing can implement `Net` yet
    |}]

let%expect_test "an operation that fails, called with try" =
  types
    {|
pub dep Users =
  save: fn(u: Int) ! Conflict | Full

fn store(u: Int) = try Users.save(u)
fn handled(u: Int) =
  match Users.save(u)
    _ => true
    fail Conflict => false
    fail Full => false
fn main() = 1
|};
  [%expect
    {|
    pub dep Users
      save: fn(Int) ! Conflict | Full
    fn store(u: Int) ! Conflict | Full uses Users
    fn handled(u: Int) -> Bool uses Users
    fn main() -> Int
    |}]

let%expect_test "the real Clock and Random" =
  run
    {|
fn main() uses Clock, Random, Console =
  let start = Clock.instant()
  Clock.sleep(Duration.ms(1))
  print(Clock.instant().not_before(start))
  print(Clock.now().after(Time.epoch))
  print(Random.int(10) < 10)
  Random.int(0)
|};
  [%expect
    {|
    true
    true
    true
    error: panic: `Random.int` needs a number above 0 to stay below, not 0
      ┌─ test.ren:7:3
    7 │   Random.int(0)
      │   ^^^^^^^^^^^^^
    |}]

let%expect_test "time, with methods" =
  run
    {|
fn main() =
  let t = Time.epoch.plus(Duration.minutes(5)).plus(Duration.seconds(1))
  print(t.after(Time.epoch))
  print(t == Time.epoch.plus(Duration.ms(301000)))
  let i = Instant.zero.plus(Duration.ms(5))
  print(i.since(Instant.zero) == Duration.ms(5))
  print(Instant.zero.before(i))
|};
  [%expect {|
    true
    true
    true
    true
    ()
    |}]

let%expect_test "the world is reached only through a dependency" =
  types {|
fn main() = clock_now()
|};
  [%expect
    {|
    error: there's no function named `clock_now`
      ┌─ test.ren:1:13
    1 │ fn main() = clock_now()
      │             ^^^^^^^^^
    |}];
  types {|
fn main() = Clock.real
|};
  [%expect
    {|
    error: `Clock` has no operation or member named `real`
      ┌─ test.ren:1:19
    1 │ fn main() = Clock.real
      │                   ^^^^
      help: its operations: `now`, `instant`, `sleep`; its members: `frozen`
    |}]

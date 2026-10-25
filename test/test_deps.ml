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
dep Clock =
  now: fn() -> Int

  pub fn now() -> Int = 0
fn main() = 1
|};
  [%expect
    {|
    error: `Clock` has an operation and a member both named `now`
      ┌─ test.ren:4:10
    2 │   now: fn() -> Int
      │   --- the operation `now` is here
    4 │   pub fn now() -> Int = 0
      │          ^^^
      = `Clock.now` has to mean one thing: calling the installed implementation's `now`, or this member
      help: rename one of them
    |}]

let%expect_test "two operations with one name" =
  types {|
dep Clock =
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
dep Clock =
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
dep Clock =
  pub fn zero() -> Int = 0
|};
  [%expect
    {|
    error: `Clock` has no operations: a dependency lists them first
      ┌─ test.ren:2:3
    2 │   pub fn zero() -> Int = 0
      │   ^^^
      help: list its operations first, like `now: fn() -> Time`, then its members
    |}];
  ast
    {|
dep Clock =
  now: fn() -> Int

  pub fn zero() -> Int = 0
  sleep: fn(ms: Int)
|};
  [%expect
    {|
    error: expected `fn`, `let` or an operator, in `Clock`'s members, found `sleep`
      ┌─ test.ren:5:3
    5 │   sleep: fn(ms: Int)
      │   ^^^^^
      help: a dependency's operations come first, before its members
    |}];
  ast {|
dep Clock = now: fn() -> Int
|};
  [%expect
    {|
    error: expected the operations of `Clock`, found `now`
      ┌─ test.ren:1:13
    1 │ dep Clock = now: fn() -> Int
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
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Io`, `Net`, `Random`, `Unsafe`
      help: use one of those, or declare it with `dep`
    |}]

let%expect_test "an implementation is a record of its operations" =
  types
    {|
dep Clock =
  now: fn() -> Int
  sleep: fn(ms: Int)

fn frozen(at: Int) -> Clock = Clock { now: fn() => at, sleep: fn(_) => () }
fn main() = frozen(0)
|};
  [%expect
    {|
    dep Clock
      now: fn() -> Int
      sleep: fn(Int)
    fn frozen(at: Int) -> Clock
    fn main() -> Clock
    |}];
  types
    {|
dep Clock =
  now: fn() -> Int
  sleep: fn(ms: Int)

fn half() = Clock { now: fn() => 1 }
fn typo() = Clock { now: fn() => 1, slep: fn(_) => () }
fn wrong() = Clock { now: fn() => true, sleep: fn(_) => () }
fn main() = 1
|};
  [%expect
    {|
    error: this `Clock` is missing `sleep`
      ┌─ test.ren:5:13
    5 │ fn half() = Clock { now: fn() => 1 }
      │             ^^^^^^^^^^^^^^^^^^^^^^^^
      help: give it a value too, like `sleep: ...`

    error: `Clock` has no operation named `slep`
      ┌─ test.ren:6:37
    6 │ fn typo() = Clock { now: fn() => 1, slep: fn(_) => () }
      │                                     ^^^^
      help: its operations: `now`, `sleep`

    error: this lambda produces a `Bool`, but it has to produce an `Int`
      ┌─ test.ren:7:35
    7 │ fn wrong() = Clock { now: fn() => true, sleep: fn(_) => () }
      │                                   ^^^^
      = `Clock`'s operation `now`
    |}]

let%expect_test "an operation isn't read from an implementation" =
  types
    {|
dep Clock =
  now: fn() -> Int

fn read(c: Clock) = c.now
fn call(c: Clock) = c.now()
fn other(c: Clock) = c.later()
fn main() = 1
|};
  [%expect
    {|
    error: `now` is an operation of `Clock`, so it isn't read from a value
      ┌─ test.ren:4:23
    4 │ fn read(c: Clock) = c.now
      │                       ^^^
      = a value of `Clock` is an implementation of it: it's used by installing it, with `with`, and then `Clock.now` calls it
      help: call the installed one: `Clock.now(...)`

    error: `now` is an operation of `Clock`, so it isn't read from a value
      ┌─ test.ren:5:23
    5 │ fn call(c: Clock) = c.now()
      │                       ^^^
      = a value of `Clock` is an implementation of it: it's used by installing it, with `with`, and then `Clock.now` calls it
      help: call the installed one: `Clock.now(...)`

    error: `Clock` has no operation named `later`
      ┌─ test.ren:6:24
    6 │ fn other(c: Clock) = c.later()
      │                        ^^^^^
      help: its operations: `now`
    |}];
  types {|
dep Clock =
  now: fn() -> Int

fn main() = Clock.later()
|};
  [%expect
    {|
    error: `Clock` has no operation or member named `later`
      ┌─ test.ren:4:19
    4 │ fn main() = Clock.later()
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

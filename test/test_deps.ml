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
  (* a record's field under it is the same mistake, the other way round *)
  ast {|
type R = { a: Int }
  b: Int
|};
  [%expect
    {|
    error: expected `fn`, `let` or an operator, in `R`'s members, found `b`
      ┌─ test.ren:2:3
    2 │   b: Int
      │   ^
      help: a record's fields go in its braces, `{ ... }`
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
fn b() uses users.lookup = 1
fn main() = 1
|};
  [%expect
    {|
    error: a dependency's name must start with a capital letter
      ┌─ test.ren:1:19
    1 │ fn b() uses users.lookup = 1
      │                   ^^^^^^
      help: write `Lookup`
    |}];
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
      │                ^^^^^ the runtime installs only `Clock`, `Random` and `Console`
    7 │   print(Users.get(1))
      │         ------------ this call uses `Users`
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
      │    ^^^^ the runtime installs only `Clock`, `Random` and `Console`
      │                   ------- this call uses `Users`
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

    error: nothing installs `Users` before `main`
      ┌─ test.ren:4:4
    4 │ fn main() uses Net = print(Users.get(1))
      │    ^^^^ the runtime installs only `Clock`, `Random` and `Console`
      │                            ------------ this call uses `Users`
      help: install one inside `main`, with `with`: an implementation is a `Users { ... }` that gives each of its operations

    error: nothing installs `Net` before `main`
      ┌─ test.ren:4:16
    4 │ fn main() uses Net = print(Users.get(1))
      │                ^^^ the runtime installs only `Clock`, `Random` and `Console`
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

let%expect_test "an operation is called, not changed or made" =
  types {|
fn main() =
  Clock.now = 1
|};
  [%expect
    {|
    error: `Clock.now` is an operation of a dependency, not a variable
      ┌─ test.ren:2:3
    2 │   Clock.now = 1
      │   ^^^^^^^^^
      help: call it, `Clock.now(...)`; what it does is changed by installing another implementation, with `with`
    |}];
  types {|
fn main() uses Clock = &Clock.now()
|};
  [%expect
    {|
    error: `Clock.now` is a dependency's operation, and its call never takes `&`
      ┌─ test.ren:1:24
    1 │ fn main() uses Clock = &Clock.now()
      │                        ^^^^^^^^^^^^
      = what an operation changes belongs to the implementation installed for it, a handler's state say, which isn't a value the caller holds
      help: remove the `&`
    |}];
  types
    {|
dep Users =
  get: fn(id: Int) -> Option<Int>

fn main() = Users.Foo
|};
  [%expect
    {|
    error: `Users` is a dependency, so it has no constructors
      ┌─ test.ren:4:13
    4 │ fn main() = Users.Foo
      │             ^^^^^^^^^
      help: make an implementation of it with `Users { ... }`, giving each of its operations
    |}]

let%expect_test "the prelude's names are taken" =
  types
    {|
type Time = { at: Int }
dep Clock =
  now: fn() -> Int
fn main() = 1
|};
  [%expect
    {|
    error: the prelude already has a type named `Time`
      ┌─ test.ren:1:6
    1 │ type Time = { at: Int }
      │      ^^^^
      = the prelude's types and dependencies, like `Option`, `Time` and `Clock`, can be named in every module
      help: choose another name

    error: the prelude already has a dependency named `Clock`
      ┌─ test.ren:2:5
    2 │ dep Clock =
      │     ^^^^^
      = the prelude's types and dependencies, like `Option`, `Time` and `Clock`, can be named in every module
      help: choose another name
    |}]

(* ---- how it runs (deps.md, "How it runs") ----

   Each dependency a function uses is a hidden parameter in Core, its
   evidence, which each call passes on. A local prints as its name and id,
   and so does evidence, named after its dependency. *)

let%expect_test "each dependency a function uses is a parameter of it" =
  core
    {|
fn stamp() = Clock.now()
fn main() uses Clock, Console =
  let t = stamp()
  print(t.after(Time.epoch))
|};
  [%expect
    {|
    (fn stamp () (uses Clock/1) (dep-call Clock.now Clock/1))
    (fn main () (uses Clock/2 Console/3)
      (let t/1 (call stamp (uses Clock/2))
        (call print (call Time.after t/1 Time.epoch) (uses Console/3))))
    (fn $start ()
      (with Clock/1 Clock.real
        (with Console/2 Console.real (call main (uses Clock/1 Console/2)))))
    |}]

let%expect_test "a lambda takes its evidence where it's called" =
  core
    {|
fn later() uses Clock =
  let _ = Clock.now()
  fn() => Clock.now()
fn main() uses Clock =
  let f = later()
  f()
|};
  [%expect
    {|
    (fn later () (uses Clock/2)
      (let _/1 (dep-call Clock.now Clock/2)
        (lambda () (captures) (uses Clock/3) (dep-call Clock.now Clock/3))))
    (fn main () (uses Clock/2)
      (let f/1 (call later (uses Clock/2)) (call f/1 (uses Clock/2))))
    (fn $start () (with Clock/1 Clock.real (call main (uses Clock/1))))
    |}]

let%expect_test "a function over closures has a copy for what they use" =
  core
    {|
fn twice(f: fn()) =
  try f()
  try f()
fn quiet() = twice(fn() => ())
fn main() uses Console =
  twice(fn() => print(1))
  quiet()
|};
  [%expect
    {|
    (fn twice (f/1) (seq (call f/1) (call f/1)))
    (fn quiet () (call twice (lambda () (captures) ())))
    (fn main () (uses Console/1)
      (seq
        (call twice[Console]
          (lambda () (captures) (uses Console/2) (call print 1 (uses Console/2)))
          (uses Console/1))
        (call quiet)))
    (fn twice[Console] (f/1) (uses Console/2)
      (seq (call f/1 (uses Console/2)) (call f/1 (uses Console/2))))
    (fn $start () (with Console/1 Console.real (call main (uses Console/1))))
    |}];
  (* the copy is in the module of what it copies *)
  core_files
    [
      ( "main.ren",
        {|
import lib
fn main() uses Console = lib.twice(fn() => print(1))
|} );
      ("lib.ren", {|
pub fn twice(f: fn()) =
  try f()
  try f()
|});
    ];
  [%expect
    {|
    -- lib
    (fn twice (f/1) (seq (call f/1) (call f/1)))
    (fn twice[Console] (f/1) (uses Console/2)
      (seq (call f/1 (uses Console/2)) (call f/1 (uses Console/2))))

    -- main
    (fn main () (uses Console/1)
      (call twice[Console]
        (lambda () (captures) (uses Console/2) (call print 1 (uses Console/2)))
        (uses Console/1)))
    (fn $start () (with Console/1 Console.real (call main (uses Console/1))))
    |}];
  run_files
    [
      ( "main.ren",
        {|
import lib
fn main() uses Console = lib.twice(fn() => print(1))
|} );
      ("lib.ren", {|
pub fn twice(f: fn()) =
  try f()
  try f()
|});
    ];
  [%expect {|
    1
    1
    ()
    |}];
  (* a copy for a dependency the copied function's module can't see: lib
     doesn't import main, where Users is declared *)
  let files =
    [
      ( "main.ren",
        {|
import lib
dep Users =
  get: fn(id: Int) -> Int
fn look() = lib.twice(fn() => Users.get(1))
fn main() uses Console = print(1)
|}
      );
      ( "lib.ren",
        {|
pub fn twice(f: fn() -> Int) -> Int =
  let _ = try f()
  try f()
|}
      );
    ]
  in
  core_files files;
  [%expect
    {|
    -- lib
    (fn twice (f/1) (let _/2 (call f/1) (call f/1)))
    (fn twice[main.Users] (f/1) (uses main.Users/3)
      (let _/2 (call f/1 (uses main.Users/3)) (call f/1 (uses main.Users/3))))

    -- main
    (fn look () (uses main.Users/1)
      (call twice[main.Users]
        (lambda () (captures) (uses main.Users/2)
          (dep-call main.Users.get main.Users/2 1))
        (uses main.Users/1)))
    (fn main () (uses Console/1) (call print 1 (uses Console/1)))
    (fn $start () (with Console/1 Console.real (call main (uses Console/1))))
    |}];
  run_files files;
  [%expect {|
    1
    ()
    |}]

let%expect_test "a function used as a value takes what its type there names" =
  core
    {|
fn one() = 1
fn apply(f: fn() -> Int) -> Int = try f()
fn main() uses Console =
  print(apply(one))
  let write = Console.write
  write("written")
|};
  [%expect
    {|
    (fn one () 1)
    (fn apply (f/1) (call f/1))
    (fn main () (uses Console/2)
      (seq
        (call print
          (call apply[Console] (lambda () (captures) (uses Console/3) (call one))
            (uses Console/2))
          (uses Console/2))
        (let write/1
          (lambda ($x/4) (captures) (uses Console/5)
            (dep-call Console.write Console/5 $x/4))
          (call write/1 "written" (uses Console/2)))))
    (fn apply[Console] (f/1) (uses Console/2) (call f/1 (uses Console/2)))
    (fn $start () (with Console/1 Console.real (call main (uses Console/1))))
    |}];
  run
    {|
fn one() = 1
fn apply(f: fn() -> Int) -> Int = try f()
fn main() uses Console =
  print(apply(one))
  let write = Console.write
  write("written")
|};
  [%expect {|
    1
    written
    ()
    |}]

(* An associated value is made once, at startup, so it can't be given the
   evidence of where it's used: one whose type has a row variable gets a
   copy made for what each use gives it, as a function does. *)
let%expect_test "an associated value used where a dependency is gets a copy" =
  let src =
    {|
type T = { n: Int }
  let one = fn() => 1
  let f = fn(g) => g()
fn twice(g) = g() + g()
fn main() uses Console =
  print(T.one())
  print(twice(T.one))
  T.f(fn() => print(3))
|}
  in
  core src;
  [%expect
    {|
    (fn T.one () (lambda () (captures) 1))
    (fn T.f () (lambda (g/1) (captures) (call g/1)))
    (fn twice (g/1) (+ (call g/1) (call g/1)))
    (fn main () (uses Console/1)
      (seq (call print (call T.one[Console] (uses Console/1)) (uses Console/1))
        (seq
          (call print (call twice[Console] T.one[Console] (uses Console/1))
            (uses Console/1))
          (call T.f[Console]
            (lambda () (captures) (uses Console/2)
              (call print 3 (uses Console/2)))
            (uses Console/1)))))
    (fn T.one[Console] () (lambda () (captures) (uses Console/1) 1))
    (fn twice[Console] (g/1) (uses Console/2)
      (+ (call g/1 (uses Console/2)) (call g/1 (uses Console/2))))
    (fn T.f[Console] ()
      (lambda (g/1) (captures) (uses Console/2) (call g/1 (uses Console/2))))
    (fn $start () (with Console/1 Console.real (call main (uses Console/1))))
    |}];
  run src;
  [%expect {|
    1
    2
    3
    ()
    |}];
  (* Core Lint catches a value used at a type that takes other evidence
     than it was made with: here a copy is made as the original was *)
  let unthreaded name check =
    let src = clean src in
    report src (fun () ->
        let open Ren in
        let linked = Driver.linked ~file src in
        let entry = List.nth linked (List.length linked - 1) in
        let original =
          List.find (fun (f : Core.fn_def) -> f.path.name = name) entry.fns
        in
        let entry =
          {
            entry with
            fns =
              List.map
                (fun (g : Core.fn_def) ->
                  if g.path.name = name ^ "[Console]" then
                    { original with path = g.path }
                  else g)
                entry.fns;
          }
        in
        check linked entry)
  in
  let lint linked entry =
    Ren.Driver.pass "lint" (fun () ->
        Ren.Core_lint.program ~imports:[] ~linked entry)
  in
  unthreaded "T.one" lint;
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:6:9: `T.one[Console]` is used at `fn() -> Int uses Console, ..d`, which takes evidence for [Console], but its scheme's `fn() -> Int ! ..e uses ..d` takes it for []: it should be a copy")
      = this is a bug in the Ren compiler, not in your program
    |}];
  unthreaded "T.f" lint;
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:8:3: `T.f[Console]` is used at `fn(fn() uses Console, ..d) uses Console, ..d`, which takes evidence for [Console], but its scheme's `fn(fn() -> T uses ..d) -> T ! ..e uses ..d` takes it for []: it should be a copy")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* and eval, which `ren run` doesn't lint first, says which call it was *)
  unthreaded "T.one" (fun linked entry ->
      ignore
        (Ren.Driver.pass "eval" (fun () ->
             Ren.Eval.run (List.rev (entry :: List.tl (List.rev linked))))));
  [%expect
    {|
    internal compiler error in eval: Failure("bug: checking or lowering let through a call of a lambda (its body at test.ren:2) passing 1 evidence, which takes 0")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* `with` arrives with its syntax in 7.3; this is the Core it lowers to.
   The closure is made where one clock is installed, and called where
   another is, which it uses. *)
let%expect_test "a closure uses the implementation installed where it's called"
    =
  let src =
    clean
      {|
fn later() uses Clock =
  let _ = Clock.now()
  fn() => Clock.now()
fn frozen_at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn main() uses Clock =
  let f = later()
  let _ = frozen_at(0)
  f()
|}
  in
  report src (fun () ->
      let open Ren in
      let linked = Driver.linked ~file src in
      let entry = List.nth linked (List.length linked - 1) in
      let fn_ name =
        List.find (fun (f : Core.fn_def) -> f.path.name = name) entry.fns
      in
      let later = fn_ "later" and frozen_at = fn_ "frozen_at" in
      let loc = later.loc in
      let clock = Ty.Con (Path.prelude "Clock", []) in
      let ev id : Core.var = { id; name = "Clock"; ty = clock } in
      let global (f : Core.fn_def) = Core.mk (Global f.path) f.scheme.ty loc in
      let frozen minutes =
        Core.mk
          (Call
             (global frozen_at, [ Value (Core.mk (Int minutes) Ty.int loc) ], []))
          clock loc
      in
      let closure_ty =
        match later.scheme.ty with Fun (_, t, _, _) -> t | _ -> assert false
      in
      let time =
        match closure_ty with Fun (_, t, _, _) -> t | _ -> assert false
      in
      let f : Core.var = { id = 3; name = "f"; ty = closure_ty } in
      (* with Clock.frozen at 0 minutes, make the closure; with it at 5,
         call it *)
      let body =
        Core.mk
          (With
             {
               ev = ev 1;
               impl = frozen 0;
               body =
                 Core.mk
                   (Let
                      ( f,
                        Core.mk
                          (Call (global later, [], [ ev 1 ]))
                          closure_ty loc,
                        Core.mk
                          (With
                             {
                               ev = ev 2;
                               impl = frozen 5;
                               body =
                                 Core.mk
                                   (Call (Core.local f loc, [], [ ev 2 ]))
                                   time loc;
                             })
                          time loc ))
                   time loc;
             })
          time loc
      in
      print_endline (Core.show body);
      let start =
        {
          (fn_ Evidence.start_name) with
          body;
          scheme = { ty = Fun ([], time, Ty.closed, Ty.closed); names = [] };
        }
      in
      let entry =
        {
          entry with
          fns =
            List.map
              (fun (g : Core.fn_def) ->
                if g.path = start.path then start else g)
              entry.fns;
        }
      in
      let modules = List.rev (entry :: List.tl (List.rev linked)) in
      print_endline (Value.show (Eval.run modules)));
  [%expect
    {|
    (with Clock/1 (call frozen_at 0)
      (let f/3 (call later (uses Clock/1))
        (with Clock/2 (call frozen_at 5) (call f/3 (uses Clock/2)))))
    300000
    |}]

(* Core Lint checks the evidence is threaded: a module with a dependency
   `D` of one operation, and a `main` that takes evidence for it *)
let lint_evidence body =
  let open Ren in
  let loc = Loc.point ~file 1 1 in
  let d = Path.make "test" "D" in
  let int_fn : Ty.ty = Fun ([], Ty.int, Ty.closed, Ty.closed) in
  let uses_d : Ty.row =
    { labels = [ Ty.label (Ty.dep_label d) ]; tail = None }
  in
  let ev id : Core.var = { id; name = "D"; ty = Con (d, []) } in
  let op ev =
    Core.mk
      (Dep_call
         {
           dep = d;
           op = "op";
           fty = Fun ([], Ty.int, Ty.closed, uses_d);
           impl = ev;
           args = [];
         })
      Ty.int loc
  in
  let main : Core.fn_def =
    {
      path = Path.make "test" "main";
      params = [];
      evidence = [ ev 1 ];
      scheme = { ty = Fun ([], Ty.int, Ty.closed, uses_d); names = [] };
      body = body ~loc ~ev ~op ~uses_d ~int_fn;
      loc;
    }
  in
  report "" (fun () ->
      Driver.pass "lint" (fun () ->
          Core_lint.program ~imports:[] ~linked:[]
            {
              home = "test";
              types =
                [
                  {
                    path = d;
                    params = [];
                    body = Dep [ { fname = "op"; fty = int_fn } ];
                    members = [];
                    loc = None;
                  };
                ];
              fns = [ main ];
              values = [];
            }))

let%expect_test "Core Lint checks evidence is threaded" =
  (* clean: the operation is called on the function's evidence *)
  lint_evidence (fun ~loc:_ ~ev ~op ~uses_d:_ ~int_fn:_ -> op (ev 1));
  [%expect {||}];
  (* evidence that isn't in scope *)
  lint_evidence (fun ~loc:_ ~ev ~op ~uses_d:_ ~int_fn:_ -> op (ev 2));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D` (2) is passed for `test.D`, but isn't in scope here")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a lambda that keeps the evidence of the function it's made in *)
  lint_evidence (fun ~loc ~ev ~op ~uses_d:_ ~int_fn ->
      let f =
        Ren.Core.mk
          (Lambda
             { params = []; evidence = []; captures = []; body = op (ev 1) })
          int_fn loc
      in
      Ren.Core.mk (Call (f, [], [])) Ren.Ty.int loc);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D` (1) is passed for `test.D`, but isn't in scope here")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* one whose evidence isn't what its type uses *)
  lint_evidence (fun ~loc ~ev ~op ~uses_d ~int_fn:_ ->
      let f =
        Ren.Core.mk
          (Lambda
             { params = []; evidence = []; captures = []; body = op (ev 1) })
          (Fun ([], Ren.Ty.int, Ren.Ty.closed, uses_d))
          loc
      in
      Ren.Core.mk (Call (f, [], [ ev 1 ])) Ren.Ty.int loc);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: a lambda takes evidence for [], but should for [test.D]")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* evidence an inner `With` shadows *)
  lint_evidence (fun ~loc ~ev ~op ~uses_d:_ ~int_fn ->
      let d = (ev 2).ty in
      let one =
        Ren.Core.mk
          (Lambda
             {
               params = [];
               evidence = [];
               captures = [];
               body = Ren.Core.mk (Int 1) Ren.Ty.int loc;
             })
          int_fn loc
      in
      let impl =
        Ren.Core.mk (Record (Ren.Path.make "test" "D", [ ("op", one) ])) d loc
      in
      Ren.Core.mk (With { ev = ev 2; impl; body = op (ev 1) }) Ren.Ty.int loc);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D` (1) is passed for `test.D`, but isn't the innermost installed")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a call that doesn't pass what its callee takes *)
  lint_evidence (fun ~loc ~ev ~op ~uses_d ~int_fn:_ ->
      let f =
        Ren.Core.mk
          (Lambda
             {
               params = [];
               evidence = [ ev 2 ];
               captures = [];
               body = op (ev 2);
             })
          (Fun ([], Ren.Ty.int, Ren.Ty.closed, uses_d))
          loc
      in
      Ren.Core.mk (Call (f, [], [])) Ren.Ty.int loc);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: a call passes 0 evidence, but its callee takes [test.D]")
      = this is a bug in the Ren compiler, not in your program
    |}]

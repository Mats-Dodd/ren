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

   Every function and lambda takes one hidden parameter, its evidence: the
   vector of what's installed where it's called. Every call passes the
   caller's on, and a call of an operation finds its implementation in
   it. A local prints as its name and id, and so does evidence, `ev`: a
   function's or lambda's after its parameters, a call's right after
   `call`. *)

let%expect_test "every call passes the caller's evidence on" =
  core
    {|
fn stamp() = Clock.now()
fn double(n: Int) = n * 2
fn main() uses Clock, Console =
  let t = stamp()
  print(t.after(Time.epoch))
  print(double(2))
|};
  [%expect
    {|
    (fn stamp () ev/1 (dep-call ev/1 Clock.now))
    (fn double (n/1) ev/2 (* n/1 2))
    (fn main () ev/2
      (let t/1 (call ev/2 stamp)
        (seq (call ev/2 print (call ev/2 Time.after t/1 Time.epoch))
          (call ev/2 print (call ev/2 double 2)))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Clock Clock.real)
        (with ev/3 (extend ev/2 Console Console.real) (call ev/3 main))))
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
    (fn later () ev/2
      (let _/1 (dep-call ev/2 Clock.now)
        (lambda () (captures) ev/3 (dep-call ev/3 Clock.now))))
    (fn main () ev/2 (let f/1 (call ev/2 later) (call ev/2 f/1)))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Clock Clock.real) (call ev/2 main)))
    |}]

(* There are no copies of a function for what its callers' closures use:
   `twice` passes `f` its own evidence, whatever is in it. *)
let%expect_test "a function over closures passes them its evidence" =
  let src =
    {|
fn twice(f: fn()) =
  try f()
  try f()
fn quiet() = twice(fn() => ())
fn main() uses Console =
  twice(fn() => print(1))
  quiet()
|}
  in
  core src;
  [%expect
    {|
    (fn twice (f/1) ev/2 (seq (call ev/2 f/1) (call ev/2 f/1)))
    (fn quiet () ev/1 (call ev/1 twice (lambda () (captures) ev/2 ())))
    (fn main () ev/1
      (seq (call ev/1 twice (lambda () (captures) ev/2 (call ev/2 print 1)))
        (call ev/1 quiet)))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    1
    1
    ()
    |}];
  let files =
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
    ]
  in
  core_files files;
  [%expect
    {|
    -- lib
    (fn twice (f/1) ev/2 (seq (call ev/2 f/1) (call ev/2 f/1)))

    -- main
    (fn main () ev/1
      (call ev/1 twice (lambda () (captures) ev/2 (call ev/2 print 1))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run_files files;
  [%expect {|
    1
    1
    ()
    |}]

let%expect_test "an operation used as a value calls it where it's called" =
  let src =
    {|
fn one() = 1
fn apply(f: fn() -> Int) -> Int = try f()
fn main() uses Console =
  print(apply(one))
  let write = Console.write
  write("written")
|}
  in
  core src;
  [%expect
    {|
    (fn one () ev/1 1)
    (fn apply (f/1) ev/2 (call ev/2 f/1))
    (fn main () ev/2
      (seq (call ev/2 print (call ev/2 apply one))
        (let write/1
          (lambda ($x/3) (captures) ev/4 (dep-call ev/4 Console.write $x/3))
          (call ev/2 write/1 "written"))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    1
    written
    ()
    |}]

(* An associated value is made once, at startup, with nothing installed. A
   closure in one is called like any other, with its caller's evidence. *)
let%expect_test "a closure in an associated value gets its caller's evidence" =
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
    (fn T.one () ev/1 (lambda () (captures) ev/2 1))
    (fn T.f () ev/2 (lambda (g/1) (captures) ev/3 (call ev/3 g/1)))
    (fn twice (g/1) ev/2 (+ (call ev/2 g/1) (call ev/2 g/1)))
    (fn main () ev/1
      (seq (call ev/1 print (call ev/1 T.one))
        (seq (call ev/1 print (call ev/1 twice T.one))
          (call ev/1 T.f (lambda () (captures) ev/2 (call ev/2 print 3))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    1
    2
    3
    ()
    |}]

(* What the first try at threading evidence, which passed one parameter
   per dependency and made copies of functions for them, got wrong. Each
   runs now. *)

let%expect_test "closures in values, and pure lambdas, run where more is used" =
  run
    {|
type T = { n: Int }
  let one = fn() => 1
fn main() uses Console =
  print(T.one())
|};
  [%expect {|
    1
    ()
    |}];
  (* a value whose type is shared with the closure it holds *)
  run
    {|
fn twice_ret(f) =
  let _ = f()
  f
type T = { n: Int }
  let v = twice_ret(fn() => 1)
fn main() uses Console =
  print(T.v())
|};
  [%expect {|
    1
    ()
    |}];
  (* a pure lambda passed from a `main` that uses several dependencies,
     and a closure that takes a closure *)
  run
    {|
fn twice_gen(f, x) = f(f(x))
fn drive(run: fn(fn() -> Int) -> Int) -> Int = try run(fn() => 20)
fn main() uses Clock, Console, Random =
  print(twice_gen(fn(x) => x + 1, 1))
  print(drive(fn(g) => g() + 1))
  let _ = Clock.now()
  print(Random.int(1))
|};
  [%expect {|
    3
    21
    0
    ()
    |}]

(* `with` arrives with its syntax in 7.3. Until then, this runs a program
   from a `$start` written in Core, as `with` will lower to: [body] makes
   its body from the functions of the entry ([fn_]), around the evidence
   `$start` takes, ev/1. Core Lint checks it, then it runs. *)
let run_start files body =
  let files, file, src, load = program files in
  report_files files (fun () ->
      let open Ren in
      let linked = Driver.linked ~lint:true ~load ~file src in
      let entry = List.nth linked (List.length linked - 1) in
      let fn_ name =
        List.find (fun (f : Core.fn_def) -> f.path.name = name) entry.fns
      in
      let start = fn_ Lower.start_name in
      let body = body ~fn_ ~loc:start.loc in
      print_endline (Core.show body);
      let start =
        {
          start with
          body;
          scheme = { ty = Fun ([], body.ty, Ty.closed, Ty.closed); names = [] };
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
      Driver.pass "lint" (fun () -> Core_lint.program ~imports:[] ~linked entry);
      let modules = List.rev (entry :: List.tl (List.rev linked)) in
      print_endline
        (Value.show (Driver.pass "eval" (fun () -> Eval.run modules))))

(* Core for a call of [f], of no parameters but [args], with the evidence
   [ev], and for installing [impl] for [dep] around [body]. *)
let call ~loc ?(args = []) (f : Ren.Core.fn_def) ev =
  let ret = match f.scheme.ty with Fun (_, t, _, _) -> t | t -> t in
  Ren.Core.mk
    (Call
       ( Ren.Core.mk (Global f.path) f.scheme.ty loc,
         List.map (fun a -> Ren.Core.Value a) args,
         Ren.Core.evidence ev ))
    ret loc

let install ~loc dep ~impl ev (body : Ren.Core.expr) =
  Ren.Core.mk
    (With
       {
         ev = Ren.Core.evidence (ev + 1);
         outer = Ren.Core.evidence ev;
         dep;
         impl;
         body;
       })
    body.ty loc

let%expect_test "a closure over another module's dependency runs" =
  (* lib doesn't import main, where Users is declared: `twice` passes `f`
     the evidence it's given, whatever is in it *)
  run_start
    [
      ( "main.ren",
        {|
import lib
dep Users =
  get: fn(id: Int) -> Int
fn users() -> Users = Users { get: fn(id) => id * 10 }
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
    (fun ~fn_ ~loc ->
      install ~loc
        (Ren.Path.make "main" "Users")
        ~impl:(call ~loc (fn_ "users") 1)
        1
        (call ~loc (fn_ "look") 2));
  [%expect
    {|
    (with ev/2 (extend ev/1 main.Users (call ev/1 users)) (call ev/2 look))
    10
    |}]

(* The closure is made where one clock is installed, and called where
   another is, which it uses. *)
let%expect_test "a closure uses the implementation installed where it's called"
    =
  run_start
    [
      ( "test.ren",
        {|
fn later() uses Clock =
  let _ = Clock.now()
  fn() => Clock.now()
fn frozen_at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn main() uses Clock =
  let _ = later()
  frozen_at(0)
|}
      );
    ]
    (fun ~fn_ ~loc ->
      let open Ren in
      let clock = Path.prelude "Clock" in
      let frozen minutes ev =
        call ~loc (fn_ "frozen_at")
          ~args:[ Core.mk (Int minutes) Ty.int loc ]
          ev
      in
      let later = fn_ "later" in
      let closure_ty =
        match later.scheme.ty with Fun (_, t, _, _) -> t | t -> t
      in
      let time = match closure_ty with Fun (_, t, _, _) -> t | t -> t in
      let f : Core.var = { id = 4; name = "f"; ty = closure_ty } in
      (* with Clock.frozen at 0 minutes, make the closure; with it at 5,
         call it *)
      install ~loc clock ~impl:(frozen 0 1) 1
        (Core.mk
           (Let
              ( f,
                call ~loc later 2,
                install ~loc clock ~impl:(frozen 5 2) 2
                  (Core.mk
                     (Call (Core.local f loc, [], Core.evidence 3))
                     time loc) ))
           time loc));
  [%expect
    {|
    (with ev/2 (extend ev/1 Clock (call ev/1 frozen_at 0))
      (let f/4 (call ev/2 later)
        (with ev/3 (extend ev/2 Clock (call ev/2 frozen_at 5)) (call ev/3 f/4))))
    300000
    |}]

(* Evidence threaded wrongly is a bug in the compiler. Core Lint catches
   it, and `ren run`, which doesn't lint, has the interpreter say which
   call it was, rather than fail somewhere inside OCaml. *)
let%expect_test "evidence threaded wrongly is a compiler bug, named" =
  let files =
    [
      ("test.ren", {|
fn stamp() = Clock.now()
fn main() uses Clock = stamp()
|});
    ]
  in
  (* a call passing evidence that isn't in scope *)
  run_start files (fun ~fn_ ~loc -> call ~loc (fn_ "main") 7);
  [%expect
    {|
    (call ev/7 main)
    internal compiler error in lint: Failure("Core Lint: in `$start`, at test.ren:2:4: a call of `main` is given `ev` (7), but the evidence in scope is `ev` (1)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a call of a function that uses what nothing installs *)
  run_start files (fun ~fn_ ~loc -> call ~loc (fn_ "main") 1);
  [%expect
    {|
    (call ev/1 main)
    internal compiler error in lint: Failure("Core Lint: in `$start`, at test.ren:2:4: a call of `main` uses `Clock`, which is neither used here, by `fn()`, nor installed")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* and the same, run without linting first *)
  let src = clean (snd (List.hd files)) in
  let unlinted body =
    report src (fun () ->
        let open Ren in
        let linked = Driver.linked ~file src in
        let entry = List.nth linked (List.length linked - 1) in
        let fn_ name =
          List.find (fun (f : Core.fn_def) -> f.path.name = name) entry.fns
        in
        let start = fn_ Lower.start_name in
        let start = { start with body = body ~fn_ ~loc:start.loc } in
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
        ignore (Driver.pass "eval" (fun () -> Eval.run modules)))
  in
  unlinted (fun ~fn_ ~loc -> call ~loc (fn_ "main") 7);
  [%expect
    {|
    internal compiler error in eval: Failure("bug: checking or lowering let through a call of `main` with evidence that isn't in scope")
      = this is a bug in the Ren compiler, not in your program
    |}];
  unlinted (fun ~fn_ ~loc -> call ~loc (fn_ "main") 1);
  [%expect
    {|
    internal compiler error in eval: Failure("bug: checking or lowering let through a call of `Clock.now` where nothing installs `Clock`")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* Core Lint checks the evidence is threaded: a module with a dependency
   `D` of one operation, and a `main` that uses it, whose evidence is
   ev/1 *)
let lint_evidence body =
  let open Ren in
  let loc = Loc.point ~file 1 1 in
  let d = Path.make "test" "D" in
  let int_fn : Ty.ty = Fun ([], Ty.int, Ty.closed, Ty.closed) in
  let uses_d : Ty.row =
    { labels = [ Ty.label (Ty.dep_label d) ]; tail = None }
  in
  let op ev =
    Core.mk
      (Dep_call
         {
           dep = d;
           op = "op";
           fty = Fun ([], Ty.int, Ty.closed, uses_d);
           ev = Core.evidence ev;
           args = [];
         })
      Ty.int loc
  in
  let lambda ?(uses = Ty.closed) ev body =
    Core.mk
      (Lambda { params = []; ev = Core.evidence ev; captures = []; body })
      (Fun ([], Ty.int, Ty.closed, uses))
      loc
  in
  let call f ev = Core.mk (Call (f, [], Core.evidence ev)) Ty.int loc in
  let main : Core.fn_def =
    {
      path = Path.make "test" "main";
      params = [];
      ev = Core.evidence 1;
      scheme = { ty = Fun ([], Ty.int, Ty.closed, uses_d); names = [] };
      body = body ~loc ~op ~lambda ~call ~uses_d;
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
  (* clean: the operation finds `D` in the function's evidence, and a
     lambda's in its own *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d ->
      call (lambda ~uses:uses_d 2 (op 2)) 1);
  [%expect {||}];
  (* evidence that isn't in scope *)
  lint_evidence (fun ~loc:_ ~op ~lambda:_ ~call:_ ~uses_d:_ -> op 2);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` is given `ev` (2), but the evidence in scope is `ev` (1)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a call that doesn't pass the evidence in scope *)
  lint_evidence (fun ~loc ~op:_ ~lambda ~call ~uses_d:_ ->
      call (lambda 2 (Ren.Core.mk (Int 1) Ren.Ty.int loc)) 2);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: a call is given `ev` (2), but the evidence in scope is `ev` (1)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a lambda that keeps the evidence of the function it's made in *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d ->
      call (lambda ~uses:uses_d 2 (op 1)) 1);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` is given `ev` (1), but the evidence in scope is `ev` (2)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* an operation of a dependency the lambda it's in doesn't use *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d:_ ->
      call (lambda 2 (op 2)) 1);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` uses `test.D`, which is neither used here, by `fn()`, nor installed")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* evidence an inner `With` extends *)
  lint_evidence (fun ~loc ~op ~lambda ~call:_ ~uses_d:_ ->
      let d = Ren.Path.make "test" "D" in
      let impl =
        Ren.Core.mk
          (Record (d, [ ("op", lambda 3 (Ren.Core.mk (Int 1) Ren.Ty.int loc)) ]))
          (Con (d, []))
          loc
      in
      Ren.Core.mk
        (With
           {
             ev = Ren.Core.evidence 2;
             outer = Ren.Core.evidence 1;
             dep = d;
             impl;
             body = op 1;
           })
        Ren.Ty.int loc);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` is given `ev` (1), but the evidence in scope is `ev` (2)")
      = this is a bug in the Ren compiler, not in your program
    |}]

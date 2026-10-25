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

let%expect_test
    "main's help suggests only an implementation that can be installed" =
  (* one that needs what it implements would need one installed before it *)
  types
    {|
dep Log =
  put: fn(n: Int)
fn doubling() = Log { put: fn(n) => Log.put(n * 2) }
fn main() uses Log =
  Log.put(1)
|};
  [%expect
    {|
    error: nothing installs `Log` before `main`
      ┌─ test.ren:4:16
    4 │ fn main() uses Log =
      │                ^^^ the runtime installs only `Clock`, `Random` and `Console`
    5 │   Log.put(1)
      │   ---------- this call uses `Log`
      help: install one inside `main`, with `with`: an implementation is a `Log { ... }` that gives each of its operations
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

let%expect_test "a closure over another module's dependency runs" =
  (* lib doesn't import main, where Users is declared: `twice` passes `f`
     the evidence it's given, whatever is in it *)
  let files =
    [
      ( "main.ren",
        {|
import lib
dep Users =
  get: fn(id: Int) -> Int
fn users() -> Users = Users { get: fn(id) => id * 10 }
fn look() = lib.twice(fn() => Users.get(1))
fn main() uses Console = print(with users() in look())
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
    (fn twice (f/1) ev/3 (let _/2 (call ev/3 f/1) (call ev/3 f/1)))

    -- main
    (fn users () ev/2 (record (get: (lambda (id/1) (captures) ev/3 (* id/1 10)))))
    (fn look () ev/1
      (call ev/1 twice
        (lambda () (captures) ev/2 (dep-call ev/2 main.Users.get 1))))
    (fn main () ev/1
      (call ev/1 print
        (with ev/2 (extend ev/1 main.Users (call ev/1 users)) (call ev/2 look))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run_files files;
  [%expect {|
    10
    ()
    |}]

(* The closure is made where one clock is installed, and called where
   another is, which it uses. *)
let%expect_test "a closure uses the implementation installed where it's called"
    =
  let src =
    {|
fn later() uses Clock =
  let _ = Clock.now()
  fn() => Clock.now()
fn frozen_at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn main() uses Console =
  let f = with frozen_at(0) in later()
  print(with frozen_at(5) in f())
|}
  in
  core src;
  [%expect
    {|
    (fn later () ev/2
      (let _/1 (dep-call ev/2 Clock.now)
        (lambda () (captures) ev/3 (dep-call ev/3 Clock.now))))
    (fn frozen_at (minutes/1) ev/2
      (call ev/2 Clock.frozen
        (call ev/2 Time.plus Time.epoch (call ev/2 Duration.minutes minutes/1))))
    (fn main () ev/2
      (let f/1
        (with ev/3 (extend ev/2 Clock (call ev/2 frozen_at 0)) (call ev/3 later))
        (call ev/2 print
          (with ev/4 (extend ev/2 Clock (call ev/2 frozen_at 5)) (call ev/4 f/1)))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    300000
    ()
    |}]

(* A program run from a `$start` written in Core: [body] makes its body
   from the functions of the entry ([fn_]), around the evidence `$start`
   takes, ev/1. Core Lint checks it, then it runs. *)
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

(* Core for a call of [f], of no parameters, with the evidence [ev]. *)
let call ~loc (f : Ren.Core.fn_def) ev =
  let ret = match f.scheme.ty with Fun (_, t, _, _) -> t | t -> t in
  Ren.Core.mk
    (Call (Ren.Core.mk (Global f.path) f.scheme.ty loc, [], Ren.Core.evidence ev))
    ret loc

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
          (Con (d, [ Uses Ren.Ty.closed ]))
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

(* ---- `with` (deps.md, "`with`") ---- *)

let%expect_test "with's syntax" =
  ast
    {|
fn main() =
  with Clock.frozen(t), counting(1) in
    body()
  with retry(3) in try f()
  g(with a in 1, 2)
|};
  [%expect
    {| (fn main () (block (with (call (. (con Clock) frozen) t) (with (call counting 1) (call body))) (with (call retry 3) (try (call f))) (call g (with a 1) 2))) |}];
  ast {|
fn main() = with a b in 1
|};
  [%expect
    {|
    error: expected `,` or `in` after what `with` installs, found `b`
      ┌─ test.ren:1:20
    1 │ fn main() = with a b in 1
      │                    ^
      help: write what it installs, then `in`, then the code it's installed around
    |}];
  (* what a signature writes: what an implementation needs, what a
     function type uses, and named rows *)
  types
    {|
fn f(c: Clock uses Random, ..d, g: fn(Int) -> Int ! Bad | ..e uses Clock) -> (Clock uses Random, ..d)
    ! ..e
    uses ..d =
  c
fn h(k: Option<fn() uses Clock>, m: (Int)) = 1
fn main() = 1
|};
  [%expect
    {|
    fn f(c: Clock uses Random, ..d, g: fn(Int) -> Int ! Bad | ..e uses Clock) -> (Clock uses Random, ..d) ! ..e uses ..d
    fn h(k: Option<fn() uses Clock>, m: Int) -> Int
    fn main() -> Int
    |}];
  (* `with` is a keyword now *)
  ast {|
fn with() = 1
|};
  [%expect
    {|
    error: expected a name, found `with`
      ┌─ test.ren:1:4
    1 │ fn with() = 1
      │    ^^^^
    |}]

let%expect_test "with installs around its body, and the innermost wins" =
  let src =
    {|
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn stamp() = Clock.now()
fn main() uses Console =
  print(with at(1) in stamp())
  print(with at(1), at(2) in stamp())
  with at(3) in
    print(stamp())
    print(with at(4) in stamp())
    print(stamp())
|}
  in
  types src;
  [%expect
    {|
    fn at(minutes: Int) -> Clock
    fn stamp() -> Time uses Clock
    fn main() uses Console
    |}];
  core src;
  [%expect
    {|
    (fn at (minutes/1) ev/2
      (call ev/2 Clock.frozen
        (call ev/2 Time.plus Time.epoch (call ev/2 Duration.minutes minutes/1))))
    (fn stamp () ev/1 (dep-call ev/1 Clock.now))
    (fn main () ev/1
      (seq
        (call ev/1 print
          (with ev/2 (extend ev/1 Clock (call ev/1 at 1)) (call ev/2 stamp)))
        (seq
          (call ev/1 print
            (with ev/3 (extend ev/1 Clock (call ev/1 at 1))
              (with ev/4 (extend ev/3 Clock (call ev/3 at 2)) (call ev/4 stamp))))
          (with ev/5 (extend ev/1 Clock (call ev/1 at 3))
            (seq (call ev/5 print (call ev/5 stamp))
              (seq
                (call ev/5 print
                  (with ev/6 (extend ev/5 Clock (call ev/5 at 4))
                    (call ev/6 stamp)))
                (call ev/5 print (call ev/5 stamp))))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect
    {|
    60000
    120000
    180000
    240000
    180000
    ()
    |}]

let%expect_test "with removes what it installs from the body's uses" =
  types
    {|
dep Users =
  get: fn(id: Int) -> Int
fn none() -> Users = Users { get: fn(_) => 0 }
fn find() = Users.get(1)
fn found() = with none() in find()
pub fn public() -> Int = with none() in find()
fn main() = 1
|};
  [%expect
    {|
    dep Users
      get: fn(Int) -> Int
    fn none() -> Users
    fn find() -> Int uses Users
    fn found() -> Int
    pub fn public() -> Int
    fn main() -> Int
    |}]

let%expect_test "a with's body uses no more than what's outside it" =
  (* a closure called both inside a `with` and outside it, a closure
     parameter called inside one, and a dependency parameter installed
     inside another: each uses what's outside, which is less than the
     body can *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn run_at(f: fn() -> Int) -> Int = with at(1) in try f()
fn run_inferred(f) = with at(1) in try f()
fn convert(r: Rates) = with Clock.frozen(Time.epoch) in with r in Rates.usd_to(4)
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn local() uses Console =
  let k = fn() => print(Clock.now())
  with at(2) in k()
  with at(3) in
    k()
    with Rates { usd_to: fn(c) => c } in k()
fn main() uses Console, Clock =
  let pure = fn() => 5
  print(with at(1) in pure())
  print(pure())
  print(run_at(fn() => 6))
  print(run_inferred(fn() => Clock.now()))
  print(convert(timed()))
  local()
|}
  in
  types src;
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    fn at(minutes: Int) -> Clock
    fn run_at(f: fn() -> Int) -> Int
    fn run_inferred<T>(f: fn() -> T ! ..e uses Clock, ..d) -> T ! ..e uses ..d
    fn convert(r: Rates) -> Int
    fn timed() -> (Rates uses Clock, ..d)
    fn local() uses Console
    fn main() uses Clock, Console
    |}];
  run src;
  [%expect
    {|
    5
    5
    6
    60000
    0
    120000
    180000
    180000
    ()
    |}];
  (* a closure parameter called inside a `with`: an inferred one may use
     what it installs, and one whose type is written transparent passes
     everything it uses on (deps.md, "Deviations") *)
  types
    {|
fn inferred(f) = with Clock.frozen(Time.epoch) in try f()
fn written(f: fn() -> Time) -> Time = with Clock.frozen(Time.epoch) in try f()
fn main() uses Console =
  print(inferred(fn() => Clock.now()))
  print(written(fn() => Clock.now()))
|};
  [%expect
    {|
    error: `main` doesn't declare `Clock`
      ┌─ test.ren:3:4
    3 │ fn main() uses Console =
      │    ^^^^
    5 │   print(written(fn() => Clock.now()))
      │         ---------------------------- this call uses `Clock`
      = `main`'s body can only use what its `uses` lists
      = in `written`, what's called inside the `with` that installs `Clock` uses what `written` itself does: a parameter whose type is written `fn(...)`, or a closure that's called outside the `with` too, gets only what's installed outside it
      help: add `Clock` to its `uses`
    |}];
  (* a signature that says so, called where the caller uses the same
     dependency itself *)
  run
    {|
fn run_at(f: fn() -> Int uses Clock, ..d) -> Int uses ..d =
  with Clock.frozen(Time.epoch) in f()
fn main() uses Console, Clock =
  print(run_at(fn() => if Clock.now().after(Time.epoch) then 1 else 2))
|};
  [%expect {|
    2
    ()
    |}];
  (* a function calling itself, or one of its group, inside a `with` *)
  run
    {|
dep Log =
  put: fn(n: Int)
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn logger(base: Int) = Log { put: fn(n) => print(base + n) }
fn walk(n: Int) =
  if n > 0 then
    print(Clock.now())
    with at(n) in walk(n - 1)
fn ping(n: Int) =
  if n > 0 then
    Log.put(n)
    with logger(n * 100) in pong(n - 1)
fn pong(n: Int) =
  if n > 0 then
    Log.put(n)
    ping(n - 1)
fn main() uses Console =
  with at(7) in walk(3)
  with logger(0) in ping(4)
|};
  [%expect
    {|
    420000
    180000
    120000
    4
    403
    402
    201
    ()
    |}]

let%expect_test "what an implementation needs is part of its type" =
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn fixed() -> Rates = Rates { usd_to: fn(c) => c }
pub fn stored() -> Rates uses Clock = timed()
fn convert() = with timed() in Rates.usd_to(1)
pub fn public() -> Int = with timed() in Rates.usd_to(1)
fn main() = 1
|};
  [%expect
    {|
    error: expected `Rates`, found `Rates uses Clock`
      ┌─ test.ren:5:39
    5 │ pub fn stored() -> Rates uses Clock = timed()
      │                                       ^^^^^^^
      = `stored` is declared to return `Rates`
      = an implementation's type says what it needs, so one that needs more can't stand in for one that needs less
      help: say what it needs where its type is written: `(Rates uses Clock)`

    error: `public` doesn't declare `Clock`
      ┌─ test.ren:7:8
    7 │ pub fn public() -> Int = with timed() in Rates.usd_to(1)
      │        ^^^^^^
      │                               ------- installing this needs `Clock`
      = a public function without `uses` uses nothing, and its body is checked against that
      help: add `uses Clock`
    |}];
  (* the `uses` after a type name is what an implementation needs, and in
     a result it's parenthesized *)
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
pub fn timed() -> (Rates uses Clock) =
  Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
pub fn convert(r: Rates uses Clock) -> Int uses Clock = 1
fn main() = 1
|};
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub fn timed() -> (Rates uses Clock)
    pub fn convert(r: Rates uses Clock) -> Int uses Clock
    fn main() -> Int
    |}];
  types {|
fn f(x: Int uses Clock) = 1
fn main() = 1
|};
  [%expect
    {|
    error: `Int` isn't a dependency, so it needs nothing
      ┌─ test.ren:1:9
    1 │ fn f(x: Int uses Clock) = 1
      │         ^^^
      help: remove the `uses`: only an implementation of a dependency needs something
    |}]

(* An implementation's operations run with what's installed where it's
   installed: the clock at 1 minute, not the one at 0 *)
let%expect_test "an implementation that needs more, inside another type" =
  types
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int
type Box<T> = { it: T }
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn boxed() -> Box<Rates> = Box { it: timed() }
fn main() = 1
|};
  [%expect
    {|
    error: expected `Box<Rates>`, found `Box<Rates uses Clock>`
      ┌─ test.ren:5:28
    5 │ fn boxed() -> Box<Rates> = Box { it: timed() }
      │                            ^^^^^^^^^^^^^^^^^^^
      = `boxed` is declared to return `Box<Rates>`
      = an implementation's type says what it needs, so one that needs more can't stand in for one that needs less
      help: say what it needs where its type is written: `Box<Rates uses Clock>`
    |}]

let%expect_test "an implementation's needs are fixed where it's installed" =
  run
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn main() uses Console =
  with at(1) in
    with timed() in
      with at(0) in
        print(Rates.usd_to(100))
        print(Clock.now())
|};
  [%expect {|
    100
    0
    ()
    |}]

let%expect_test "an operation can fail with fewer errors, never more" =
  types
    {|
dep Http =
  get_rate: fn(c: Int) -> Int ! Timeout
dep Rates =
  usd_to: fn(c: Int) -> Int ! RateUnavailable
fn live() = Rates { usd_to: fn(c) => try Http.get_rate(c) }
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:5:38
    5 │ fn live() = Rates { usd_to: fn(c) => try Http.get_rate(c) }
      │                                      ^^^^^^^^^^^^^^^^^^^^ fails with `Timeout`
      = `Rates.usd_to` can fail only with `RateUnavailable`
      help: map it: `match Http.get_rate(c)` with the arm `fail Timeout => fail RateUnavailable`
    |}];
  types
    {|
dep Http =
  get_rate: fn(c: Int) -> Int ! Timeout | Gone
dep Rates =
  usd_to: fn(c: Int) -> Int ! RateUnavailable
dep Plain =
  get: fn() -> Int
fn live() = Rates { usd_to: fn(c) => try Http.get_rate(c) }
fn plain() = Plain { get: fn() => try Http.get_rate(1) }
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Gone` and `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:7:38
    7 │ fn live() = Rates { usd_to: fn(c) => try Http.get_rate(c) }
      │                                      ^^^^^^^^^^^^^^^^^^^^ fails with `Gone` and `Timeout`
      = `Rates.usd_to` can fail only with `RateUnavailable`
      help: map what it fails with inside it, with `match` and `fail` arms, to what it can: `fail RateUnavailable`

    error: this implementation can fail with `Gone` and `Timeout`, and `Plain.get` can't
      ┌─ test.ren:8:35
    8 │ fn plain() = Plain { get: fn() => try Http.get_rate(1) }
      │                                   ^^^^^^^^^^^^^^^^^^^^ fails with `Gone` and `Timeout`
      = `Plain.get` can't fail
      help: handle what it fails with inside it, with `match` and `fail` arms
    |}];
  (* an ordinary function's call: its row is open where it's called, which
     isn't more errors, so the help says `match` *)
  types
    {|
fn get(c: Int) -> Int ! Timeout = if c > 0 then c else fail Timeout
dep Rates =
  usd_to: fn(c: Int) -> Int ! RateUnavailable
fn live() = Rates { usd_to: fn(c) => try get(c) }
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:4:38
    4 │ fn live() = Rates { usd_to: fn(c) => try get(c) }
      │                                      ^^^^^^^^^^ fails with `Timeout`
      = `Rates.usd_to` can fail only with `RateUnavailable`
      help: map it: `match get(c)` with the arm `fail Timeout => fail RateUnavailable`
    |}];
  (* following the help, and an operation that fails with less *)
  run
    {|
dep Http =
  get_rate: fn(c: Int) -> Int ! Timeout
dep Rates =
  usd_to: fn(c: Int) -> Int ! RateUnavailable
fn http(up: Bool) -> Http =
  Http { get_rate: fn(c) => if up then c * 2 else fail Timeout }
fn ask(c: Int) =
  match Http.get_rate(c)
    fail Timeout => fail RateUnavailable
    r => r
fn live() = Rates { usd_to: fn(c) => try ask(c) }
fn fixed() -> Rates = Rates { usd_to: fn(_) => 3 }
fn main() uses Console =
  print(attempt with http(true), live() in Rates.usd_to(5))
  print(attempt with http(false), live() in Rates.usd_to(5))
  print(attempt with fixed() in Rates.usd_to(5))
|};
  [%expect {|
    Ok(10)
    Err(RateUnavailable)
    Ok(3)
    ()
    |}]

let%expect_test "with installs an implementation or wraps its body" =
  types {|
fn bad() = with 3 in 1
fn unknown(c) = with c in 1
fn main() = 1
|};
  [%expect
    {|
    error: `with` installs an implementation, or wraps its body, but this is an `Int`
      ┌─ test.ren:1:17
    1 │ fn bad() = with 3 in 1
      │                 ^
      = `with` installs an implementation of a dependency around its body, or passes its body to a wrapper, a function whose last parameter is the body
      help: give it an implementation, like `Clock.frozen(t)`, or a wrapper's call without its last argument, like `retry(3)`

    error: `with` can't tell what this installs: its type isn't known here
      ┌─ test.ren:2:22
    2 │ fn unknown(c) = with c in 1
      │                      ^
      = `with` installs an implementation of a dependency around its body, or passes its body to a wrapper, a function whose last parameter is the body
      help: say what it is where it's declared, like `c: Clock`
    |}]

let%expect_test "a wrapper is passed the body" =
  let src =
    {|
fn flaky(n: Int) -> Int ! Boom =
  if n < 3 then fail Boom else n

fn retry(n: Int, body: fn() -> Int) -> Int =
  let r = attempt body()
  if n <= 1 then try r
  else
    match r
      Ok(v) => v
      Err(_) => try retry(n - 1, body)

fn twice(body: fn() -> Int) -> Int = try body() + try body()

pub fn safe() -> Int = with retry(3) in 1

fn main() uses Console =
  print(attempt with retry(3) in try flaky(2))
  print(attempt with retry(3) in try flaky(4))
  print(with twice in 21)
|}
  in
  types src;
  [%expect
    {|
    fn flaky(n: Int) -> Int ! Boom
    fn retry(n: Int, body: fn() -> Int) -> Int
    fn twice(body: fn() -> Int) -> Int
    pub fn safe() -> Int
    fn main() uses Console
    |}];
  core src;
  [%expect
    {|
    (fn flaky (n/1) ev/2 (if (< n/1 3) (fail (tag Boom)) n/1))
    (fn retry (n/1 body/2) ev/5
      (let r/3
        (handle (call ev/5 body/2) ($value/6 => (con Ok $value/6))
          (fail $error/7 => (con Err $error/7)))
        (if (<= n/1 1)
          (match r/3 ((Ok $value/8) => $value/8)
            ((Err $error/9) => (fail $error/9)))
          (match r/3 ((Ok v/4) => v/4)
            ((Err _) => (call ev/5 retry (- n/1 1) body/2))))))
    (fn twice (body/1) ev/2 (+ (call ev/2 body/1) (call ev/2 body/1)))
    (fn safe () ev/1 (call ev/1 retry 3 (lambda () (captures) ev/2 1)))
    (fn main () ev/1
      (seq
        (call ev/1 print
          (handle
            (call ev/1 retry 3 (lambda () (captures) ev/2 (call ev/2 flaky 2)))
            ($value/3 => (con Ok $value/3))
            (fail $error/4 => (con Err $error/4))))
        (seq
          (call ev/1 print
            (handle
              (call ev/1 retry 3 (lambda () (captures) ev/5 (call ev/5 flaky 4)))
              ($value/6 => (con Ok $value/6))
              (fail $error/7 => (con Err $error/7))))
          (call ev/1 print (call ev/1 twice (lambda () (captures) ev/8 21))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    Err(Boom)
    Ok(4)
    42
    ()
    |}]

let%expect_test "a method is a wrapper too" =
  run
    {|
type W = { n: Int }
  fn wrap(self, body: fn() -> Int) -> Int = self.n * (try body())
  fn times(n: Int, body: fn() -> Int) -> Int = n + (try body())
fn main() uses Console =
  let w = W { n: 3 }
  print(with w.wrap() in 5)
  print(with W.times(3) in 5)
  print(with w.wrap(), w.wrap() in 2)
  print(attempt with w.wrap() in fail Nope)
|};
  [%expect {|
    15
    8
    18
    Err(Nope)
    ()
    |}];
  types
    {|
type W = { n: Int }
  fn wrap(self, body: fn() -> Int) -> Int = self.n * (try body())
  fn bump(inout self, body: fn() -> Int) -> Int = try body()
fn main() uses Console =
  var w = W { n: 3 }
  print(with w.wrap in 5)
  print(with w.bump() in 5)
|};
  [%expect
    {|
    error: `wrap` is a method, so it has to be called
      ┌─ test.ren:6:16
    6 │   print(with w.wrap in 5)
      │                ^^^^
      help: write `w.wrap()`, or use `W.wrap` as a function

    error: `bump` changes its receiver, so it can't wrap a body
      ┌─ test.ren:7:14
    7 │   print(with w.bump() in 5)
      │              ^^^^^^^^
      = `with r.w(a) in body` calls `r.w(a, fn() => body)`, and a `with`'s item can't change what it's called on
      help: call `bump` outside the `with`, with all its arguments
    |}]

let%expect_test "what a wrapper can't be" =
  types
    {|
fn grab(n: Int, inout body: fn() -> Int) -> Int = 1
fn intish(n: Int, body: Int) -> Int = body
fn twice(body: fn() -> Int) -> Int = try body() + try body()
fn main() =
  var n = 1
  let a = with grab(1) in 2
  let b = with intish(3) in 2
  let c = with twice in
    n += 1
    n
  a + b + c
|};
  [%expect
    {|
    error: `grab` changes its last argument, so it can't take a body
      ┌─ test.ren:6:16
    6 │   let a = with grab(1) in 2
      │                ^^^^^^^
      = `with w(a) in body` calls `w(a, fn() => body)`, and a lambda isn't a place to change
      help: call `grab` outside the `with`, with all its arguments

    error: `intish`'s last parameter is an `Int`, but a `with` passes it its body, a `fn()`
      ┌─ test.ren:7:16
    7 │   let b = with intish(3) in 2
      │                ^^^^^^^^^
      = `with w(a) in body` calls `w(a, fn() => body)`, so the wrapper's last parameter is a function of no parameters
      help: call `intish` outside the `with`, with all its arguments

    error: the body of this `with` can't change `n`, a variable from outside it
      ┌─ test.ren:9:5
    9 │     n += 1
      │     ^
      = `with` passes its body to `twice` as a lambda, `fn() => ...`, which captures the values of the variables it uses when it's made, so changing them would have no effect outside
      help: give the body's result back as its value instead
    |}]

(* ---- parameters of a dependency's type ---- *)

let%expect_test "a parameter of a dependency's type is transparent" =
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn convert(r: Rates) = with r in Rates.usd_to(1)
fn passed(r: Rates) = convert(r)
pub fn public(r: Rates) -> Int = with r in Rates.usd_to(1)
fn caller() = passed(timed())
fn main() = 1
|};
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    fn timed() -> (Rates uses Clock, ..d)
    fn convert(r: Rates) -> Int
    fn passed(r: Rates) -> Int
    pub fn public(r: Rates) -> Int
    fn caller() -> Int uses Clock
    fn main() -> Int
    |}];
  types
    {|
type Box = { c: Clock }
fn keep(c: Clock) -> Clock = c
fn boxed(c: Clock) = Box { c }
fn main() = 1
|};
  [%expect
    {|
    error: `c` is used as a value here, so it isn't transparent
      ┌─ test.ren:2:30
    2 │ fn keep(c: Clock) -> Clock = c
      │                              ^
      = a parameter whose type is a dependency's, `Clock`, can only be installed, with `with`, or passed straight to another function, so what it needs is what its function uses
      help: to keep it, name what it needs: `c: Clock uses ..d`

    error: `c` is used as a value here, so it isn't transparent
      ┌─ test.ren:3:28
    3 │ fn boxed(c: Clock) = Box { c }
      │                            ^
      = a parameter whose type is a dependency's, `Clock`, can only be installed, with `with`, or passed straight to another function, so what it needs is what its function uses
      help: to keep it, name what it needs: `c: Clock uses ..d`
    |}]

let%expect_test "a dependency parameter that's kept names its row" =
  run
    {|
pub fn id(c: Clock uses ..d) -> (Clock uses ..d) = c
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn main() uses Console =
  print(with id(at(2)) in Clock.now())
|};
  [%expect {|
    120000
    ()
    |}];
  types
    {|
fn install(c: Clock uses ..d) -> Time uses Console = with c in Clock.now()
fn main() = 1
|};
  [%expect
    {|
    error: installing this needs `..d`, which `install` doesn't declare
      ┌─ test.ren:1:59
    1 │ fn install(c: Clock uses ..d) -> Time uses Console = with c in Clock.now()
      │                                                           ^
      = `..d` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: add it to what `install` uses: `uses Console, ..d`
    |}]

(* ---- named rows ---- *)

let%expect_test "a closure that's kept names its rows" =
  let src =
    {|
type Button<F> = { on_click: F }

fn keep(f: fn() -> Int ! ..e uses ..d) -> (fn() -> Int ! ..e uses ..d) = f
fn mk(f: fn() -> Int ! ..e uses ..d) -> Button<fn() -> Int ! ..e uses ..d> =
  Button { on_click: f }
fn press(b: Button<fn() -> Int ! ..e uses ..d>) -> Int ! ..e uses ..d =
  let f = b.on_click
  try f()
fn tick() -> Int ! Late uses Console =
  print(1)
  fail Late

fn main() uses Console =
  print(press(mk(fn() => 3)))
  let g = keep(tick)
  print(attempt g())
  print(attempt press(mk(tick)))
|}
  in
  types src;
  [%expect
    {|
    fn keep(f: fn() -> Int ! ..e uses ..d) -> (fn() -> Int ! ..e uses ..d)
    fn mk(f: fn() -> Int ! ..e uses ..d) -> Button<fn() -> Int ! ..e uses ..d>
    fn press(b: Button<fn() -> Int ! ..e uses ..d>) -> Int ! ..e uses ..d
    fn tick() -> Int ! Late uses Console
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    3
    1
    Err(Late)
    1
    Err(Late)
    ()
    |}]

let%expect_test "what a function does with a named row, it declares" =
  types
    {|
pub fn calls(f: fn() -> Int uses ..d) -> Int = f()
pub fn fails(f: fn() -> Int ! ..e) -> Int ! Bad = try f()
fn listed(f: fn() -> Int uses ..d) uses Console = f()
fn other(f: fn() -> Int uses ..d, g: fn() -> Int uses ..x) uses ..d =
  f() + g()
fn main() = 1
|};
  [%expect
    {|
    error: this call uses `..d`, which `calls` doesn't declare
      ┌─ test.ren:1:48
    1 │ pub fn calls(f: fn() -> Int uses ..d) -> Int = f()
      │                                                ^^^
      = `..d` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: add it to what `calls` uses: `uses ..d`

    error: this can fail with `..e`, which `fails` doesn't declare
      ┌─ test.ren:2:55
    2 │ pub fn fails(f: fn() -> Int ! ..e) -> Int ! Bad = try f()
      │                                                       ^^^
      = `..e` stands for whatever the closure it names fails with, and a function that declares its errors declares that too
      help: add `..e` to what `fails` declares it fails with, after `!`

    error: this call uses `..d`, which `listed` doesn't declare
      ┌─ test.ren:3:51
    3 │ fn listed(f: fn() -> Int uses ..d) uses Console = f()
      │                                                   ^^^
      = `..d` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: add it to what `listed` uses: `uses Console, ..d`

    error: this call uses `..x`, which `other` doesn't declare
      ┌─ test.ren:5:9
    5 │   f() + g()
      │         ^^^
      = `..x` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: `other` names one row, `..d`, which is all it can name: name this one `..d` too, where it's written
    |}];
  types
    {|
type Button = { on_click: fn() }
fn mk(f: fn() uses ..d) = Button { on_click: fn() => f() }
fn both(f: fn() uses ..d, g: fn() uses ..x) =
  f()
  g()
fn main() = 1
|};
  [%expect
    {|
    error: this call uses `..d`, which isn't allowed here
      ┌─ test.ren:2:54
    2 │ fn mk(f: fn() uses ..d) = Button { on_click: fn() => f() }
      │                                                      ^^^
      = `..d` stands for whatever the closure or implementation it names uses, and what this is in can't use more than it lists
      help: use it where `..d` can go: in the function that names it, or in a lambda whose type isn't written

    error: this call uses `..x`, but what this is in already uses `..d`
      ┌─ test.ren:5:3
    5 │   g()
      │   ^^^
      = a row ends in at most one named row, and what this is in already uses `..d`, so `..x` can't be added
      help: name the two rows alike, `..d`, if they can stand for the same
    |}]

let%expect_test "only a signature names a row" =
  types
    {|
type Button = { on_click: fn() uses ..d }
fn body() =
  let g: fn() uses ..q = fn() => ()
  g
fn kinds(f: fn() ! ..d, g: fn() uses ..d) = 1
fn main() = 1
|};
  [%expect
    {|
    error: a declaration can't name a row, `..d`
      ┌─ test.ren:1:39
    1 │ type Button = { on_click: fn() uses ..d }
      │                                       ^
      = only a function's signature names a row, for now (deps.md, "Implementations")
      help: to keep a closure in a type, make its type a type parameter, `type Button<F> = { on_click: F }`, which a signature can write `Button<fn() uses ..d>`

    error: there's no `..q` in this function's signature
      ┌─ test.ren:3:22
    3 │   let g: fn() uses ..q = fn() => ()
      │                      ^
      = a named row stands for what a closure or an implementation that comes into or out of the function does, so the signature names it
      help: name `..q` in the function's signature

    error: `..d` names what something uses here, and what something fails with elsewhere in this signature
      ┌─ test.ren:5:40
    5 │ fn kinds(f: fn() ! ..d, g: fn() uses ..d) = 1
      │                                        ^
      │                      - here it names what something fails with
      = a row is a list of errors or a list of dependencies, never both
      help: give the two rows two names
    |}]

(* A public wrapper can't infer its body's rows, so it names them: what
   `attempt` keeps, and passes on with `try`, is `..e` *)
let%expect_test "a public wrapper names its body's rows" =
  let src =
    {|
fn flaky(n: Int) -> Int ! Boom =
  if n < 3 then fail Boom else n
pub fn retry(n: Int, body: fn() -> Int ! ..e uses ..d) -> Int ! ..e uses ..d =
  let r = attempt body()
  if n <= 1 then try r
  else
    match r
      Ok(v) => v
      Err(_) => try retry(n - 1, body)
pub fn safe() -> Int ! Boom = with retry(3) in try flaky(2)
fn main() uses Console =
  print(attempt safe())
  print(with retry(2) in 7)
|}
  in
  types src;
  [%expect
    {|
    fn flaky(n: Int) -> Int ! Boom
    pub fn retry(n: Int, body: fn() -> Int) -> Int
    pub fn safe() -> Int ! Boom
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    Err(Boom)
    7
    ()
    |}]

let%expect_test "a dependency's self is an implementation" =
  (* `self` needs what its method uses, as `c: N` does, and a receiver
     that needs less will do *)
  run
    {|
dep N =
  get: fn() -> Int

  fn fixed(n: Int) -> N = N { get: fn() => n }
  fn same(self, k: Int) -> N = self
  fn scaled(self, k: Int) -> (N uses N) = N { get: fn() => (with self in N.get()) * k }
fn main() uses Console =
  let b = N.fixed(7).same(3)
  let base = N.fixed(7)
  print(with N.fixed(1) in with base.scaled(3) in N.get())
  print(with b in N.get())
|};
  [%expect {|
    21
    7
    ()
    |}];
  (* a public one names what it needs where it's kept *)
  run
    {|
pub dep N =
  get: fn() -> Int

  pub fn fixed(n: Int) -> N = N { get: fn() => n }
  pub fn same(self, k: Int) -> (N uses ..d) uses ..d = self
  pub fn scaled(self, k: Int) -> (N uses ..d) uses ..d = N { get: fn() => (with self in N.get()) * k }
fn main() uses Console =
  print(with N.fixed(7).same(1).scaled(3) in N.get())
|};
  [%expect {|
    21
    ()
    |}];
  types
    {|
pub dep N =
  get: fn() -> Int

  pub fn fixed(n: Int) -> N = N { get: fn() => n }
  pub fn same(self, k: Int) -> N = self
fn noisy() -> Int uses Console =
  print(0)
  5
fn loud() -> (N uses Console) = N { get: fn() => noisy() }
fn main() =
  let b = loud().same(3)
  1
|};
  [%expect
    {|
    error: `self` is kept where it can't need anything, so it isn't transparent
      ┌─ test.ren:5:15
    5 │   pub fn same(self, k: Int) -> N = self
      │               ^^^^
      = a dependency's `self` needs what its method uses, but here it's kept as `N`, which needs nothing
      help: to keep it, name what it needs where it's kept, `(N uses ..d)`, and add `uses ..d` to `N.same`

    error: expected `N`, found `N uses Console`
       ┌─ test.ren:11:11
    11 │   let b = loud().same(3)
       │           ^^^^^^
       = an implementation's type says what it needs, so one that needs more can't stand in for one that needs less
       help: say what it needs where its type is written: `(N uses Console)`
    |}]

let%expect_test "a transparent parameter kept where its rows close" =
  (* the interface says what the parameter fails with and uses is the
     function's; kept as a plain `fn() -> Int`, it can't be *)
  types
    {|
pub type Box<R> = { r: R }
pub fn store_fn(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d> = Box { r: f }
pub fn sneakyf(f: fn() -> Int) -> Box<fn() -> Int> = store_fn(f)
pub dep Rates =
  usd_to: fn(Int) -> Int
pub fn keep(r: Rates uses ..d) -> Box<Rates uses ..d> = Box { r: r }
pub fn sneaky(r: Rates) -> Box<Rates> = keep(r)
fn main() = 1
|};
  [%expect
    {|
    error: `f` is kept where it can't fail or use anything, so it isn't transparent
      ┌─ test.ren:3:16
    3 │ pub fn sneakyf(f: fn() -> Int) -> Box<fn() -> Int> = store_fn(f)
      │                ^
      = a parameter whose type is written `fn(...)` passes what it fails with and uses on to `sneakyf`'s callers, but here it's passed to something that keeps it as a function that can't fail or use anything
      help: to keep it, name its rows, `f: fn(...) ! ..e uses ..d`, and write them where it's kept

    error: `r` is kept where it can't need anything, so it isn't transparent
      ┌─ test.ren:7:15
    7 │ pub fn sneaky(r: Rates) -> Box<Rates> = keep(r)
      │               ^
      = a parameter whose type is a dependency's, `Rates`, needs what its function uses, but here it's passed to something that keeps it as an implementation that needs nothing
      help: to keep it, name what it needs, `r: Rates uses ..d`, and write it where it's kept
    |}];
  (* named, they're fine *)
  types
    {|
pub type Box<R> = { r: R }
pub fn store_fn(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d> = Box { r: f }
pub fn fine(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d> = store_fn(f)
fn main() = 1
|};
  [%expect
    {|
    pub fn store_fn(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d>
    pub fn fine(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d>
    fn main() -> Int
    |}]

let%expect_test "why a closure in a with still needs what it installs" =
  types
    {|
dep N =
  get: fn() -> Int

fn fixed(n: Int) -> N = N { get: fn() => n }
fn run_two(f) = (with fixed(1) in f()) + (with fixed(2) in f())
fn main() uses Console =
  print(run_two(fn() => N.get()))
|};
  [%expect
    {|
    error: nothing installs `N` before `main`
      ┌─ test.ren:6:4
    6 │ fn main() uses Console =
      │    ^^^^ the runtime installs only `Clock`, `Random` and `Console`
    7 │   print(run_two(fn() => N.get()))
      │         ------------------------ this call uses `N`
      = `run_two` calls a closure inside more than one `with`, so the closure gets only what's installed outside all of them, not the `N` one of them installs
      help: install one inside `main`: `with fixed(...) in ...`
    |}];
  types
    {|
dep N =
  get: fn() -> Int

type A = { n: Int }
  fn wrap(self, body: fn() -> Int) -> Int = with N { get: fn() => self.n } in try body()
fn main() uses Console =
  let a = A { n: 3 }
  print(with a.wrap() in N.get())
|};
  [%expect
    {|
    error: nothing installs `N` before `main`
      ┌─ test.ren:6:4
    6 │ fn main() uses Console =
      │    ^^^^ the runtime installs only `Clock`, `Random` and `Console`
    8 │   print(with a.wrap() in N.get())
      │              -------- this call uses `N`
      = in `A.wrap`, what's called inside the `with` that installs `N` uses what `A.wrap` itself does: a parameter whose type is written `fn(...)`, or a closure that's called outside the `with` too, gets only what's installed outside it
      help: install one inside `main`, with `with`: an implementation is a `N { ... }` that gives each of its operations
    |}]

let%expect_test "an operation given by name, or as a named row" =
  types
    {|
dep N =
  get: fn() -> Int ! Low

fn helper() -> Int ! High =
  fail High
fn f3() -> N = N { get: helper }
fn f4(g: fn() -> Int ! ..e uses ..d) -> (N uses ..d) = N { get: g }
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `High`, and `N.get` can't
      ┌─ test.ren:6:25
    6 │ fn f3() -> N = N { get: helper }
      │                         ^^^^^^ fails with `High`
      = `N.get` can fail only with `Low`
      help: give a lambda that calls `helper` and maps what it fails with, with `match` and `fail` arms, to what `N.get` can: `fail High => fail Low`

    error: expected `fn() -> Int ! Low`, found `fn() -> Int ! ..e uses ..d`
      ┌─ test.ren:7:65
    7 │ fn f4(g: fn() -> Int ! ..e uses ..d) -> (N uses ..d) = N { get: g }
      │                                                                 ^
      = `N`'s operation `get`
      help: `g` can fail with anything `..e` stands for, and the operation only with `Low`: write `! Low` in place of `! ..e`
    |}]

let%expect_test "an implementation a function makes can need anything" =
  (* `ren types` shows its open row, which written back keeps it so *)
  let src =
    {|
dep N =
  get: fn() -> Int

fn noisy() -> Int uses Console =
  print(0)
  5
fn loud() -> (N uses Console) = N { get: fn() => noisy() }
fn fixed(n: Int) = N { get: fn() => n }
fn written(n: Int) -> (N uses ..d) = N { get: fn() => n }
fn pick(b: Bool) -> (N uses Console) = if b then written(1) else loud()
fn main() uses Console =
  print(with pick(true) in N.get())
  print(with fixed(2) in N.get())
|}
  in
  types src;
  [%expect
    {|
    dep N
      get: fn() -> Int
    fn noisy() -> Int uses Console
    fn loud() -> (N uses Console)
    fn fixed(n: Int) -> (N uses ..d)
    fn written(n: Int) -> (N uses ..d)
    fn pick(b: Bool) -> (N uses Console)
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    1
    2
    ()
    |}]

(* ---- handlers ---- *)

let rates =
  {|
dep Rates =
  usd_to: fn(c: Int) -> Int

dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  var calls = 0
  usd_to(_) =>
    calls += 1
    rate
  count() => calls

fn convert(n: Int) uses Rates = n * Rates.usd_to(1)
|}

let%expect_test "a handler implements several dependencies sharing one state" =
  ast rates;
  [%expect
    {|
    (dep Rates (ops usd_to:fn(Int) -> Int))
    (dep RateCalls (ops count:fn() -> Int))
    (fn counting_rates (rate) (handler (for Rates RateCalls) (var calls 0) (usd_to (lambda (_) (block (+= calls 1) rate))) (count (lambda () calls))))
    (fn convert (n) (uses Rates) (* n (call (. (con Rates) usd_to) 1)))
    |}];
  let src =
    rates
    ^ {|
fn main() uses Console =
  with counting_rates(3) in
    print(convert(2))
    print(convert(5))
    print(RateCalls.count())
|}
  in
  types src;
  [%expect
    {|
    dep Rates
      usd_to: fn(Int) -> Int
    dep RateCalls
      count: fn() -> Int
    handler counting_rates(rate: Int) for Rates, RateCalls
    fn convert(n: Int) -> Int uses Rates
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    6
    15
    2
    ()
    |}]

let%expect_test "each with makes a fresh instance" =
  run
    (rates
   ^ {|
fn calls() uses Rates, RateCalls =
  let _ = convert(1)
  RateCalls.count()

fn main() uses Console =
  let h = counting_rates(2)
  with h in
    print(calls())
    print(calls())
  with h in
    print(calls())
  with counting_rates(2), counting_rates(5) in
    print(calls())
    print(convert(1))
|}
    );
  [%expect {|
    1
    2
    1
    1
    5
    ()
    |}]

let%expect_test "a handler is a record of closures over shared cells" =
  core
    (rates
   ^ {|
fn main() uses Console = with counting_rates(3) in print(convert(2))
|}
    );
  [%expect
    {|
    (fn counting_rates (rate/1) ev/4
      (handler (captures rate/1) ev/5
        (let calls/2 0
          (let $calls/6 (cell calls/2)
            (instance
              (test.Rates:
                (record
                  (usd_to:
                    (lambda (_/3) (captures rate/1 $calls/6) ev/7
                      (let calls/2 (get-cell $calls/6)
                        (let $result/8 (seq (= calls/2 (+ calls/2 1)) rate/1)
                          (seq (set-cell $calls/6 calls/2) $result/8)))))))
              (test.RateCalls:
                (record
                  (count:
                    (lambda () (captures $calls/6) ev/9
                      (let calls/2 (get-cell $calls/6) calls/2))))))))))
    (fn convert (n/1) ev/2 (* n/1 (dep-call ev/2 test.Rates.usd_to 1)))
    (fn main () ev/1
      (with ev/2
        (extend ev/1 (test.Rates test.RateCalls) (call ev/1 counting_rates 3))
        (call ev/2 print (call ev/2 convert 2))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}]

let%expect_test "what a handler needs is fixed where it's installed" =
  (* its state is made, and its operations run, with what's installed
     outside its `with`: the inner `Base` doesn't change them *)
  let src =
    {|
dep Base =
  n: fn() -> Int

dep N =
  get: fn() -> Int

handler offset() for N =
  let start = Base.n()
  var seen = 0
  get() =>
    seen += 1
    start * 100 + Base.n() * 10 + seen

fn base(n: Int) -> Base = Base { n: fn() => n }

fn main() uses Console =
  with base(1), offset(), base(2) in
    print(N.get())
    print(N.get())
    print(Base.n())
|}
  in
  types src;
  [%expect
    {|
    dep Base
      n: fn() -> Int
    dep N
      get: fn() -> Int
    handler offset() for N uses Base
    fn base(n: Int) -> Base
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    111
    112
    2
    ()
    |}]

let%expect_test "what a handler needs is needed where it's installed" =
  let src =
    {|
dep N =
  get: fn() -> Int

handler noisy() for N =
  get() =>
    print(1)
    2

fn get() = with noisy() in N.get()
fn main() = get()
|}
  in
  types src;
  [%expect
    {|
    dep N
      get: fn() -> Int
    handler noisy() for N uses Console
    fn get() -> Int uses Console
    fn main() -> Int uses Console
    |}]

let%expect_test "a public handler says what it needs" =
  types
    {|
pub dep N =
  get: fn() -> Int

pub handler quiet(n: Int) for N =
  get() => n

pub handler noisy(n: Int) for N
    uses Console =
  get() =>
    print(n)
    n

fn main() = 1
|};
  [%expect
    {|
    pub dep N
      get: fn() -> Int
    pub handler quiet(n: Int) for N
    pub handler noisy(n: Int) for N uses Console
    fn main() -> Int
    |}];
  types
    {|
pub dep N =
  get: fn() -> Int

pub handler forgot(n: Int) for N =
  var last = 0
  get() =>
    print(n)
    last = n
    n

handler partly() for N uses Clock =
  let start = Random.int(10)
  get() => start

fn main() = 1
|};
  [%expect
    {|
    error: the handler `forgot` doesn't declare that it needs `Console`
      ┌─ test.ren:4:13
    4 │ pub handler forgot(n: Int) for N =
      │             ^^^^^^
    7 │     print(n)
      │     -------- this call uses `Console`
      = a public handler without `uses` needs nothing, and its operations and state are checked against that
      help: add `uses Console` after what it implements

    error: the handler `partly` doesn't declare that it needs `Random`
       ┌─ test.ren:11:9
    11 │ handler partly() for N uses Clock =
       │         ^^^^^^
    12 │   let start = Random.int(10)
       │               -------------- this call uses `Random`
       = `partly`'s operations and state can only use what its `uses` lists, which is what a `with` that installs it needs
       help: add `Random` to its `uses`
    |}]

let%expect_test "an arm fails with no more than its operation declares" =
  types
    {|
dep N =
  get: fn() -> Int ! Low

fn high() -> Int ! High = fail High

handler wrong() for N =
  get() => try high()

fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `High`, and `N.get` can't
      ┌─ test.ren:7:12
    7 │   get() => try high()
      │            ^^^^^^^^^^ fails with `High`
      = `N.get` can fail only with `Low`
      help: map it: `match high()` with the arm `fail High => fail Low`
    |}]

let%expect_test "an arm takes its operation's arguments" =
  types
    {|
dep B =
  z: fn(n: Int) -> Int

handler arity() for B =
  z() => 2

handler typed() for B =
  z(n: Bool) => 2

fn main() = 1
|};
  [%expect
    {|
    error: `B.z` takes 1 argument, but this has 0 parameters
      ┌─ test.ren:5:3
    5 │   z() => 2
      │   ^
      help: give it 1 parameter, one for each argument

    error: expected `fn(Int) -> Int`, found `fn(Bool) -> Int`
      ┌─ test.ren:8:3
    8 │   z(n: Bool) => 2
      │   ^^^^^^^^^^^^^^^
      = `B`'s operation `z`
    |}]

let%expect_test "a failing arm still changes its state" =
  run
    {|
dep N =
  get: fn() -> Int ! Low

handler counted() for N =
  var calls = 0
  get() =>
    calls += 1
    if calls < 3 then fail Low else calls

fn main() uses Console =
  with counted() in
    print(attempt N.get())
    print(attempt N.get())
    print(attempt N.get())
|};
  [%expect {|
    Err(Low)
    Err(Low)
    Ok(3)
    ()
    |}]

let%expect_test "an arm changes its state through `&` too" =
  (* a method or function that takes the `var` with `&` writes it back, and
     so does the arm, even when it fails afterwards *)
  run
    {|
dep N =
  next: fn() -> Int ! Low

type C = { v: Int }
  fn inc(inout self) = self.v += 1

fn bump(inout x: Int) = x += 1

handler h() for N =
  var arr = [0]
  var n = 0
  var c = C { v: 0 }
  next() =>
    &arr.push(1)
    bump(&n)
    &c.inc()
    if n == 2 then fail Low else arr.len() * 100 + n * 10 + c.v

fn main() uses Console =
  with h() in
    print(attempt N.next())
    print(attempt N.next())
    print(attempt N.next())
|};
  [%expect {|
    Ok(211)
    Err(Low)
    Ok(433)
    ()
    |}]

let%expect_test "what a handler's declaration can't be" =
  types
    {|
dep A =
  x: fn() -> Int
  y: fn() -> Int

dep B =
  x: fn() -> Int
  z: fn(n: Int) -> Int

type T = { a: Int }

handler missing() for A =
  x() => 1

handler unknown() for A =
  x() => 1
  y() => 2
  w() => 3

handler twice() for A =
  x() => 1
  x() => 2
  y() => 3

handler both() for A, B =
  x() => 1
  y() => 2
  z(n) => n

handler not_dep() for T, A, A =
  x() => 1
  y() => 2

handler net() for Net =
  get() => 1

handler change(inout n: Int) for A =
  x() => n
  y() => n

handler itself() for A =
  x() => A.y()
  y() => 2

fn main() = 1
|};
  [%expect
    {|
    error: the handler `missing` doesn't implement `A.y`
       ┌─ test.ren:11:9
    11 │ handler missing() for A =
       │         ^^^^^^^
       help: add `y(...) => ...`

    error: `A` has no operation named `w`
       ┌─ test.ren:17:3
    17 │   w() => 3
       │   ^
       help: the operations it implements: `A.x`, `A.y`

    error: `x` is implemented twice
       ┌─ test.ren:21:3
    20 │   x() => 1
       │   - the first `x` is here
    21 │   x() => 2
       │   ^
       help: remove one of them

    error: `A` and `B` both have an operation named `x`
       ┌─ test.ren:25:3
    25 │   x() => 1
       │   ^
       = an arm implements an operation by its name, so `x` could be either
       help: implement them in two handlers

    error: `T` is a type, not a dependency
       ┌─ test.ren:29:23
    29 │ handler not_dep() for T, A, A =
       │                       ^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `A` is after `for` twice
       ┌─ test.ren:29:29
    29 │ handler not_dep() for T, A, A =
       │                             ^
       │                          - the first `A` is here
       help: remove one of them

    error: `Net` has no operations, so a handler can't implement it
       ┌─ test.ren:33:19
    33 │ handler net() for Net =
       │                   ^^^
       = `Net` is only a name so far: what it can do comes in a later stage
       help: remove it from the `for` list

    error: a handler's parameter can't be `inout`
       ┌─ test.ren:36:22
    36 │ handler change(inout n: Int) for A =
       │                      ^
       = calling a handler describes it, and each `with` that installs it keeps its parameters, so there's nothing to write back
       help: remove the `inout`

    error: a handler for `A` can't call `A.y`
       ┌─ test.ren:41:10
    41 │   x() => A.y()
       │          ^^^
       = a handler's operations run with what's installed outside its `with`, but calling the next `A` out from inside a handler for it comes with `outer` (stage 9)
       help: call it outside the handler, or implement `A` with a record of functions instead
    |}]

let%expect_test "a lambda in an arm can't change the handler's state" =
  types
    {|
dep A =
  x: fn() -> Int

handler h() for A =
  var n = 0
  x() =>
    let f = fn() => n += 1
    n += 1
    n

fn main() = 1
|};
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
      ┌─ test.ren:7:21
    7 │     let f = fn() => n += 1
      │                     ^
      = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "a handler's state comes before its arms" =
  ast
    {|
dep A =
  x: fn() -> Int

handler h() for A =
  x() => 1
  var n = 0

handler g for A =
  x() => 1

handler f() =
  x() => 1
|};
  [%expect
    {|
    error: a handler's state comes first, before its operations
      ┌─ test.ren:6:3
    6 │   var n = 0
      │   ^^^
      help: move it above the handler's first operation

    error: expected `(` after the handler's name, found `for`
      ┌─ test.ren:8:11
    8 │ handler g for A =
      │           ^^^
      help: write its parameters, `handler g() for ...`, even if it has none

    error: expected `for` and the dependencies it implements, found `=`
       ┌─ test.ren:11:13
    11 │ handler f() =
       │             ^
       help: say what it implements: `handler f(...) for Clock =`
    |}]

let%expect_test "main is told a handler can install what it uses" =
  types (rates ^ {|
fn main() uses Rates, Console = print(convert(1))
|});
  [%expect
    {|
    error: nothing installs `Rates` before `main`
       ┌─ test.ren:16:16
    16 │ fn main() uses Rates, Console = print(convert(1))
       │                ^^^^^ the runtime installs only `Clock`, `Random` and `Console`
       │                                       ---------- this call uses `Rates`
       help: install one inside `main`: `with counting_rates(...) in ...`
    |}]

let%expect_test "another module's handler" =
  let files =
    [
      ( "main.ren",
        {|
import fx

fn main() uses Console =
  with fx.counting(4) in
    print(fx.Rates.usd_to(1) + fx.Rates.usd_to(1))
    print(fx.RateCalls.count())
|}
      );
      ( "fx.ren",
        {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

pub handler counting(rate: Int) for Rates, RateCalls =
  var calls = 0
  usd_to(c) =>
    calls += 1
    c * rate
  count() => calls
|}
      );
    ]
  in
  types_files files;
  [%expect
    {|
    -- fx
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub dep RateCalls
      count: fn() -> Int
    pub handler counting(rate: Int) for Rates, RateCalls

    -- main
    fn main() uses Console
    |}];
  run_files files;
  [%expect {|
    8
    2
    ()
    |}]

let%expect_test "a handler's state is made where it's installed, and can't fail"
    =
  types
    {|
dep N =
  get: fn() -> Int

fn bad() -> Int ! Oops = fail Oops

handler h() for N =
  var n = try bad()
  get() => n

fn main() = 1
|};
  [%expect
    {|
    error: this can fail with Oops, which isn't allowed here
      ┌─ test.ren:7:15
    7 │   var n = try bad()
      │               ^^^^^
      = a handler's state is made where a `with` installs it, which can't fail
      help: handle it here, with `attempt` or a `match` with `fail` arms, or make the value in an operation instead
    |}]

let%expect_test "a handler that keeps a closure names its row" =
  let src =
    {|
pub dep N =
  get: fn() -> Int

handler inferred(f) for N =
  var n = 0
  get() =>
    n += f()
    n

pub handler written(f: fn() -> Int uses ..d) for N uses ..d =
  get() => f()

fn loud() -> Int uses Console =
  print(9)
  1

fn main() uses Console =
  with inferred(fn() => 2) in
    print(N.get())
    print(N.get())
  with written(loud) in
    print(N.get())
|}
  in
  types src;
  [%expect
    {|
    pub dep N
      get: fn() -> Int
    handler inferred(f: fn() -> Int uses ..d) for N uses ..d
    pub handler written(f: fn() -> Int uses ..d) for N uses ..d
    fn loud() -> Int uses Console
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    2
    4
    9
    1
    ()
    |}]

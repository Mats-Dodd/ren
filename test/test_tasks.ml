(* Tasks (foundations.md, decisions 2 and 7 to 11): this file is stage
   11a's specification, as test_descriptions.ml was 10d's.

   Each test's name starts with a tag, `[sN accept]` or `[sN reject]`. N is
   the step of the 11a plan that lands it (compiler.md, "Stage 11a"):

     s1  rules B to D, `try with`, the two holes, and the surface they
         need: parameters with defaults, a block without parentheses,
         `concurrent` and `spawned`
     s2  `Async.scope`, `spawn`, `start` and the handle, `replace`,
         cancellation, and task paths
     s3  `until`, `tick`, `yield`, `timeout`, `race`, `isolate`, `map`,
         `each` and `both`
     s4  operations that don't interleave
     s5  `single` and `sim` as handlers, and virtual time
     s8  the standard library, `sync`

   Steps 6 and 7, the journal and `Net`, are specified by the programs in
   bench/11a/tasks (bench/tasks.t), and the milestone too.

   A test still to land runs through [until] (helpers.ml), which holds
   what the step makes of it: [want], the whole output of a program that
   runs, or [says], the lines an error or a panic has to hold, its
   headline and its help. Its [%expect] holds today's output after
   `(until sN)`. When the program prints what's wanted, the test fails
   until it's turned on: written plainly, with the target in its
   [%expect].

   A program run with [run] is `ren run`'s, on `Async.single()`, whose
   order is fixed (compiler.md, "Scheduling"): the body of a scope runs
   until it waits, then its tasks in the order they were started. One
   run with [test] is `ren test`'s, on `sim`, and asserts only what holds
   under every schedule. *)

open Helpers

(* ---- s1: the surface the checker needs ---- *)

let%expect_test "[s1 accept] a parameter with a default, given by name or left out" =
  until "s1"
    ~want:{|
20
6
()
|}
    (fun () ->
      run
        {|
fn scaled(n: Int, by: Int = 10) -> Int = n * by

fn main() uses Console =
  print(scaled(2))
  print(scaled(2, by: 3))
|});
  [%expect {|
    (until s1)
    error: expected `,` or `)`, found `=`
      ┌─ test.ren:1:27
    1 │ fn scaled(n: Int, by: Int = 10) -> Int = n * by
      │                           ^
    |}]

let%expect_test "[s1 reject] a default given by position" =
  until "s1"
    ~says:
      [ "error: `by` has a default, so it's given by name"; "help: write `by: 3`" ]
    (fun () ->
      check_error
        {|
fn scaled(n: Int, by: Int = 10) -> Int = n * by
fn main() uses Console = print(scaled(2, 3))
|});
  [%expect {|
    (until s1)
    error: expected `,` or `)`, found `=`
      ┌─ test.ren:1:27
    1 │ fn scaled(n: Int, by: Int = 10) -> Int = n * by
      │                           ^
    |}]

let%expect_test "[s1 reject] a default that isn't a literal" =
  until "s1"
    ~says:
      [
        "error: a parameter's default is a literal: a number, a `Bool` or a \
         string";
        "help: give it where it's called instead";
      ]
    (fun () ->
      check_error
        {|
fn scaled(n: Int, by: Int = n) -> Int = n * by
fn main() uses Console = print(scaled(2))
|});
  [%expect {|
    (until s1)
    error: expected `,` or `)`, found `=`
      ┌─ test.ren:1:27
    1 │ fn scaled(n: Int, by: Int = n) -> Int = n * by
      │                           ^
    |}]

let%expect_test "[s1 reject] a default before a parameter without one" =
  until "s1"
    ~says:
      [
        "error: a parameter with a default comes after those without";
        "help: move `by` after `n`";
      ]
    (fun () ->
      check_error
        {|
fn scaled(by: Int = 10, n: Int) -> Int = n * by
fn main() uses Console = print(scaled(n: 2))
|});
  [%expect {|
    (until s1)
    error: expected `,` or `)`, found `=`
      ┌─ test.ren:1:19
    1 │ fn scaled(by: Int = 10, n: Int) -> Int = n * by
      │                   ^
    |}]

let%expect_test "[s1 reject] a parameter given by a name it doesn't have" =
  until "s1"
    ~says:
      [
        "error: `scaled` has no parameter named `times`";
        "help: its parameters given by name: `by`";
      ]
    (fun () ->
      check_error
        {|
fn scaled(n: Int, by: Int = 10) -> Int = n * by
fn main() uses Console = print(scaled(2, times: 3))
|});
  [%expect {|
    (until s1)
    error: expected `,` or `)`, found `=`
      ┌─ test.ren:1:27
    1 │ fn scaled(n: Int, by: Int = 10) -> Int = n * by
      │                           ^
    |}]

let%expect_test "[s1 accept] a block given without parentheses" =
  until "s1"
    ~want:{|
42
()
|}
    (fun () ->
      run
        {|
fn twice(f: fn() -> Int) -> Int = f() + f()

fn main() uses Console =
  print(twice fn() => 21)
|});
  [%expect {|
    (until s1)
    error: expected `,` or `)`, found `fn`
      ┌─ test.ren:4:15
    4 │   print(twice fn() => 21)
      │               ^^
    |}]

let%expect_test "[s1 accept] a block parameter's mode is part of its signature" =
  (* written on public functions, inferred on private ones *)
  until "s1" ~checks:true
    ~says:
      [
        "fn fan_out(xs: Array<Int>, f: concurrent fn(Int) -> Int) -> \
         Array<Int> uses Async";
        "fn start(s: Scope, body: spawned fn()) uses Async";
        "fn doubled(xs: Array<Int>, f: concurrent fn(Int) -> Int) -> \
         Array<Int> uses Async";
      ]
    (fun () ->
      types
        {|
pub fn fan_out(xs: Array<Int>, f: concurrent fn(Int) -> Int) -> Array<Int> uses Async =
  Async.map(xs, f)

pub fn start(s: Scope, body: spawned fn()) uses Async = s.spawn(body)

fn doubled(xs: Array<Int>, f: fn(Int) -> Int) -> Array<Int> uses Async =
  Async.map(xs, f)
fn main() = ()
|});
  [%expect {|
    (until s1)
    error: a type name must start with a capital letter
      ┌─ test.ren:1:35
    1 │ pub fn fan_out(xs: Array<Int>, f: concurrent fn(Int) -> Int) -> Array<Int> uses Async =
      │                                   ^^^^^^^^^^
      help: write `Concurrent`

    error: a type name must start with a capital letter
      ┌─ test.ren:4:30
    4 │ pub fn start(s: Scope, body: spawned fn()) uses Async = s.spawn(body)
      │                              ^^^^^^^
      help: write `Spawned`
    |}]

let%expect_test "[s1 reject] a mode on what isn't a block parameter" =
  until "s1"
    ~says:
      [
        "error: `concurrent` marks a block parameter of a function";
        "help: remove it";
      ]
    (fun () ->
      check_error
        {|
fn f(n: concurrent Int) -> Int = n
fn main() uses Console = print(f(1))
|});
  [%expect {|
    (until s1)
    error: a type name must start with a capital letter
      ┌─ test.ren:1:9
    1 │ fn f(n: concurrent Int) -> Int = n
      │         ^^^^^^^^^^
      help: write `Concurrent`
    |}]

(* ---- s1: rule B, a parameter's mode ---- *)

let%expect_test "[s1 reject] a block parameter passed on to `Async.map`, unmarked" =
  until "s1"
    ~says:
      [
        "error: `f` runs on several tasks at once in `Async.map`, but \
         `fan_out` doesn't say it can";
        "help: mark the parameter: `f: concurrent fn(Int) -> Int`";
      ]
    (fun () ->
      check_error
        {|
pub fn fan_out(xs: Array<Int>, f: fn(Int) -> Int) -> Array<Int> uses Async =
  Async.map(xs, f)
fn main() = ()
|});
  [%expect {|
    (until s1)
    error: there's no constructor named `Async`
      ┌─ test.ren:2:3
    2 │   Async.map(xs, f)
      │   ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s1 reject] a block parameter spawned, unmarked" =
  until "s1"
    ~says:
      [
        "error: `body` is spawned as a task here, but `start` doesn't say it \
         can be";
        "help: mark the parameter: `body: spawned fn()`";
      ]
    (fun () ->
      check_error
        {|
pub fn start(s: Scope, body: fn()) uses Async = s.spawn(body)
fn main() = ()
|});
  [%expect {|
    (until s1)
    error: there's no type named `Scope`
      ┌─ test.ren:1:17
    1 │ pub fn start(s: Scope, body: fn()) uses Async = s.spawn(body)
      │                 ^^^^^
    |}]

let%expect_test "[s1 reject] a concurrent block parameter spawned" =
  until "s1"
    ~says:
      [
        "error: `body` is concurrent, so it can't be spawned";
        "help: mark the parameter `spawned` instead";
      ]
    (fun () ->
      check_error
        {|
pub fn start(s: Scope, body: concurrent fn()) uses Async = s.spawn(body)
fn main() = ()
|});
  [%expect {|
    (until s1)
    error: a type name must start with a capital letter
      ┌─ test.ren:1:30
    1 │ pub fn start(s: Scope, body: concurrent fn()) uses Async = s.spawn(body)
      │                              ^^^^^^^^^^
      help: write `Concurrent`
    |}]

(* ---- s1: what a task's block can touch ---- *)

let%expect_test "[s1 reject] a variable a spawned task reads, changed in the scope" =
  (* foundations.md, decision 2's own error *)
  until "s1"
    ~says:
      [
        "error: `n` can't change while a spawned task reads it";
        "help: copy it for the task, `let m = n`, or change it after the scope";
      ]
    (fun () ->
      check_error
        {|
fn log(n: Int) uses Console = print(n)

fn main() uses Console, Async =
  var n = 0
  Async.scope fn(s) =>
    s.spawn fn() => log(n)
    n += 1
|});
  [%expect {|
    (until s1)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:5:15
    5 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s1 reject] a block that runs on several tasks at once changes a variable" =
  until "s1"
    ~says:
      [
        "error: `total` can't change in a block that runs on several tasks at \
         once";
        "help: give back what each one makes, and add them up after: \
         `Async.map(xs) fn(x) => ...`, then `.sum()`";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Console, Async =
  var total = 0
  let xs = Async.map([1, 2]) fn(x) =>
    total += x
    x
  print(total + xs.len())
|});
  [%expect {|
    (until s1)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:1:25
    1 │ fn main() uses Console, Async =
      │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:3:12
    3 │   let xs = Async.map([1, 2]) fn(x) =>
      │            ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s1 reject] a spawned task changes a variable" =
  until "s1"
    ~says:
      [
        "error: a spawned task can't change `seen`, which it only reads";
        "help: change it through a handler's operation, or give it back: \
         `t.join()` has what the task returned";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Console, Async =
  var seen = 0
  Async.scope fn(s) =>
    s.spawn fn() => seen += 1
  print(seen)
|});
  [%expect {|
    (until s1)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:3:15
    3 │   Async.scope fn(s) =>
      │               ^^
    |}]

(* ---- s1: rule D, a scope and a handle are blocks too ---- *)

let%expect_test "[s1 reject] a task's handle returned" =
  until "s1"
    ~says:
      [
        "error: a task's handle can't be returned: it's only good inside its \
         scope";
        "help: return what the task makes: `t.join()`";
      ]
    (fun () ->
      check_error
        {|
fn first(s: Scope) -> Task<Int> uses Async = s.start fn() => 1
fn main() uses Async = Async.scope fn(s) => first(s).cancel()
|});
  [%expect {|
    (until s1)
    error: expected a new line, found `fn`
      ┌─ test.ren:1:54
    1 │ fn first(s: Scope) -> Task<Int> uses Async = s.start fn() => 1
      │                                                      ^^

    error: expected a new line, found `fn`
      ┌─ test.ren:2:36
    2 │ fn main() uses Async = Async.scope fn(s) => first(s).cancel()
      │                                    ^^
    |}]

let%expect_test "[s1 reject] a scope kept in a record" =
  until "s1"
    ~says:
      [
        "error: a record can't hold a scope";
        "help: pass it to the functions that spawn into it";
      ]
    (fun () ->
      check_error
        {|
type Holder = { s: Scope }
fn main() = ()
|});
  [%expect {|
    (until s1)
    error: there's no type named `Scope`
      ┌─ test.ren:1:20
    1 │ type Holder = { s: Scope }
      │                    ^^^^^
    |}]

let%expect_test "[s1 reject] tasks' handles kept in an array" =
  until "s1"
    ~says:
      [
        "error: `Task<Int>` can't be a type argument: a task's handle is only \
         good inside its scope";
        "help: keep what the tasks make instead: `Async.map` gives every \
         result, in order";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    let ts = [s.start fn() => 1, s.start fn() => 2]
    print(ts.len())
|});
  [%expect {|
    (until s1)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^
    |}]

(* ---- s1: blocks that can't fail ---- *)

let%expect_test "[s1 reject] a spawned task that can fail" =
  until "s1"
    ~says:
      [
        "error: a spawned task can't fail, or one task's failure would stop \
         all the others";
        "help: handle them in the task: `match attempt handle(1)`";
      ]
    (fun () ->
      check_error
        {|
fn handle(n: Int) -> Int ! Bad = if n > 0 then n else fail Bad

fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print(try handle(1))
|});
  [%expect {|
    (until s1)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:4:15
    4 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s1 reject] a branch of `race` that can fail" =
  until "s1"
    ~says:
      [
        "error: a branch of `race` can't fail, or a failure could leave the \
         race waiting on the other";
        "help: make the failure a value inside it: `attempt get(1)`; to try \
         again until one succeeds, use `retry`";
      ]
    (fun () ->
      check_error
        {|
fn get(n: Int) -> Int ! Gone = if n > 0 then n else fail Gone

fn main() uses Console, Async =
  print(Async.race(fn() => try get(1), fn() => 2))
|});
  [%expect {|
    (until s1)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:3:25
    3 │ fn main() uses Console, Async =
      │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:4:9
    4 │   print(Async.race(fn() => try get(1), fn() => 2))
      │         ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

(* ---- s1: `try with` ---- *)

let tx_src =
  {|
dep Sql =
  set: fn(n: Int) ! DbDown
  begin: fn() ! DbDown
  commit: fn() ! DbDown

handler mem_sql() for Sql =
  var n = 0
  set(m) => n = m
  begin() => ()
  commit() => ()

handler transaction() over Sql ! DbDown =
  let _ = try next.begin()
  finally(r) =>
    try next.commit()
    try r

handler plain() over Sql =
  set(m) => try next.set(m)
|}

let%expect_test "[s1 reject] a `with` that can fail, unmarked" =
  until "s1"
    ~says:
      [
        "error: installing `transaction()` can fail, and nothing handles it";
        "help: write `try with`, or handle its errors with `match`";
      ]
    (fun () ->
      check_error
        (tx_src
        ^ {|
fn store(k: Int) ! DbDown uses Sql =
  with transaction() over Sql in
    try Sql.set(k)

fn main() = ()
|}));
  [%expect {|
    (until s1)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[s1 reject] `try with` marks the installation, not the body" =
  (* the body's call is a place the code can stop, so it has a `try` of
     its own *)
  until "s1"
    ~says:
      [
        "error: `Sql.set` can fail, and nothing handles it";
        "help: pass the errors on with `try`, or handle them with `match`";
      ]
    (fun () ->
      check_error
        (tx_src
        ^ {|
fn store(k: Int) ! DbDown uses Sql =
  try with transaction() over Sql in
    Sql.set(k)

fn main() = ()
|}));
  [%expect {|
    (until s1)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[s1 reject] `try with` where installing can't fail" =
  until "s1"
    ~says:
      [
        "error: nothing here can fail";
        "help: installing these can't fail: remove the `try`";
      ]
    (fun () ->
      check_error
        (tx_src
        ^ {|
fn store(k: Int) ! DbDown uses Sql =
  try with plain() over Sql in
    try Sql.set(k)

fn main() = ()
|}));
  [%expect {|
    (until s1)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

(* ---- s1: the two holes, and what's gone ---- *)

let%expect_test "[s1 reject] a function that spawns uses `Async`" =
  (* `s.spawn` waits while its scope is full *)
  until "s1"
    ~says:
      [
        "error: `start` doesn't declare `Async`";
        "`s.spawn` waits while its scope is full, so it uses `Async`";
        "help: add `uses Async`";
      ]
    (fun () ->
      check_error {|
pub fn start(s: Scope) = s.spawn fn() => ()
fn main() = ()
|});
  [%expect {|
    (until s1)
    error: expected a new line, found `fn`
      ┌─ test.ren:1:34
    1 │ pub fn start(s: Scope) = s.spawn fn() => ()
      │                                  ^^
    |}]

let%expect_test "[s1 reject] a handler's own task" =
  (* async.md's `task =>` is gone: background work is a task beside the
     `with` *)
  until "s1"
    ~says:
      [
        "error: a handler has no task of its own";
        "help: spawn one beside the `with`, into an `Async.scope` outside it, \
         that calls one of the handler's operations";
      ]
    (fun () ->
      check_error
        {|
dep Metrics =
  record: fn(n: Int)

handler batched() for Metrics uses Clock =
  var pending: Array<Int> = []
  record(n) => &pending.push(n)
  task =>
    Clock.sleep(Duration.seconds(10))
fn main() = ()
|});
  [%expect {|
    (until s1)
    error: `task => ...` is the arm of a handler `over any`
      ┌─ test.ren:7:3
    7 │   task =>
      │   ^^^^
      help: declare it `handler batched(...) over any`, or implement an operation by its name: `record(...) => ...`
    |}]

(* ---- s2: scopes and tasks ---- *)

let%expect_test "[s2 accept] a scope waits for its tasks" =
  (* the body runs until it waits, at its end, then each task in the
     order it was spawned *)
  until "s2"
    ~want:{|
body
a
b
after
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print("a")
    s.spawn fn() => print("b")
    print("body")
  print("after")
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s2 accept] `spawn` waits while `max` tasks run" =
  until "s2"
    ~want:{|
between
a
body
b
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  Async.scope(max: 1) fn(s) =>
    s.spawn fn() => print("a")
    print("between")
    s.spawn fn() => print("b")
    print("body")
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:3:13
    3 │     s.spawn fn() => print("a")
      │             ^^
    |}]

let%expect_test "[s2 accept] a variable bound inside the scope is copied into each task" =
  (* rule C: `i` isn't the frame's that calls `Async.scope`, so each task
     gets it as it was when it was spawned, and it can change after *)
  until "s2"
    ~want:{|
0
1
2
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    var i = 0
    while i < 3
      s.spawn fn() => print(i)
      i += 1
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s2 accept] a task's handle joins it" =
  until "s2"
    ~want:{|
Some(42)
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    let t = s.start fn() => 6 * 7
    print(t.join())
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s2 accept] a task cancelled before it runs never runs" =
  until "s2"
    ~want:{|
None
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    let t = s.start fn() => print("never")
    t.cancel()
    print(t.join())
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s2 accept] a cancelled task stops at its next call, and `finally` sees it" =
  (* the task is asleep when it's cancelled, so its wait ends; the
     handler's `finally` is given `Err(Cancelled)`, and `try r` goes on
     cancelling *)
  until "s2"
    ~want:{|
started
cancelled
after
()
|}
    (fun () ->
      run
        {|
dep Log =
  note: fn(s: Str)

handler logged() for Log uses Console =
  finally(r) =>
    match r
      Err(Cancelled) => print("cancelled")
      _ => print("done")
    try r
  note(s) => print(s)

fn main() uses Console, Async, Clock =
  Async.scope fn(s) =>
    let t = s.start fn() =>
      with logged() in
        Log.note("started")
        Clock.sleep(Duration.seconds(60))
        Log.note("never")
    Clock.sleep(Duration.ms(5))
    t.cancel()
  print("after")
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
       ┌─ test.ren:13:15
    13 │   Async.scope fn(s) =>
       │               ^^
    |}]

let%expect_test "[s2 accept] `replace` cancels the task under its key" =
  until "s2"
    ~want:{|
second
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async, Clock =
  Async.scope fn(s) =>
    s.replace("k") fn() =>
      Clock.sleep(Duration.seconds(60))
      print("first")
    Clock.sleep(Duration.ms(5))
    s.replace("k") fn() => print("second")
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s2 accept] a scope whose body fails cancels its tasks" =
  until "s2"
    ~want:{|
Err(Stop)
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async, Clock =
  let r = attempt Async.scope fn(s) =>
    s.spawn fn() =>
      Clock.sleep(Duration.seconds(60))
      print("never")
    Clock.sleep(Duration.ms(5))
    fail Stop
  print(r)
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:31
    2 │   let r = attempt Async.scope fn(s) =>
      │                               ^^
    |}]

let%expect_test "[s2 accept] a task beside a `with` is cancelled when its body ends" =
  (* decision 7's background work: the ticker is spawned in the `with`'s
     body into the scope outside it, so when the body ends the `with`
     cancels it, then runs its `finally`: three ticks, at 100, 200 and
     300 ms, then the body ends at 350 *)
  until "s2"
    ~want:{|
ticks: 3
after
()
|}
    (fun () ->
      run
        {|
dep Ticks =
  tick: fn()

handler ticks() for Ticks uses Console =
  var n = 0
  finally(r) =>
    print("ticks: ".concat(show(n)))
    try r
  tick() => n += 1

fn main() uses Console, Async, Clock =
  Async.scope fn(s) =>
    with ticks() in
      s.spawn fn() =>
        while true
          Clock.sleep(Duration.ms(100))
          Ticks.tick()
      Clock.sleep(Duration.ms(350))
  print("after")
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
       ┌─ test.ren:12:15
    12 │   Async.scope fn(s) =>
       │               ^^
    |}]

let%expect_test "[s2 reject] a panic in a task says which task" =
  until "s2"
    ~says:
      [
        "error: panic: index 3 is out of bounds for an array of length 1";
        "= in the task main/main:0";
      ]
    (fun () ->
      run_error
        {|
fn boom(xs: Array<Int>) -> Int = xs[3]

fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print(boom([1]))
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:4:15
    4 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s2 reject] a scope that can start no task" =
  until "s2"
    ~says:
      [
        "error: panic: `Async.scope`'s `max` is 0, so it couldn't start a task";
        "help: `max:` is at least 1";
      ]
    (fun () ->
      run_error
        {|
fn main() uses Console, Async =
  Async.scope(max: 0) fn(s) => s.spawn fn() => print(1)
|});
  [%expect {|
    (until s2)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:40
    2 │   Async.scope(max: 0) fn(s) => s.spawn fn() => print(1)
      │                                        ^^
    |}]

let%expect_test "[s2 reject] failing with `Cancelled`" =
  until "s2"
    ~says:
      [
        "error: `Cancelled` isn't an error a program can fail with";
        "help: a cancelled task stops by itself; to stop early, return";
      ]
    (fun () ->
      check_error {|
fn stop() ! Cancelled = fail Cancelled
fn main() = ()
|});
  [%expect {|
    (until s2)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

(* ---- s3: the rest of `Async` ---- *)

let%expect_test "[s3 accept] `Async.until` waits for an operation's state" =
  (* the first task waits in `Gate.wait`, letting go of the gate; the
     second's `open` releases it with the condition holding, so the first
     goes on *)
  until "s3"
    ~want:{|
opening
through
done
()
|}
    (fun () ->
      run
        {|
dep Gate =
  wait: fn()
  open: fn()

handler gate() for Gate uses Async =
  var opened = false
  wait() => Async.until(fn() => opened)
  open() => opened = true

fn main() uses Console, Async =
  with gate() in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Gate.wait()
        print("through")
      s.spawn fn() =>
        print("opening")
        Gate.open()
  print("done")
|});
  [%expect {|
    (until s3)
    error: expected the end of the line, found `fn`
       ┌─ test.ren:12:17
    12 │     Async.scope fn(s) =>
       │                 ^^
    |}]

let%expect_test "[s3 accept] `tick` and `yield`" =
  until "s3"
    ~want:{|
a
body
b
c
after the tick
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print("a")
    Async.yield()
    print("body")
    s.spawn fn() => print("b")
    s.spawn fn() => print("c")
    Async.tick()
    print("after the tick")
|});
  [%expect {|
    (until s3)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s3 accept] a timeout gives `Timeout`, or the body's result" =
  until "s3"
    ~want:{|
Err(Timeout)
Ok(2)
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async, Clock =
  let r = attempt Async.timeout(Duration.ms(20)) fn() =>
    Clock.sleep(Duration.seconds(10))
    1
  print(r)
  print(attempt Async.timeout(Duration.seconds(10)) fn() => 2)
|});
  [%expect {|
    (until s3)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:1:25
    1 │ fn main() uses Console, Async, Clock =
      │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:2:19
    2 │   let r = attempt Async.timeout(Duration.ms(20)) fn() =>
      │                   ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`

    error: there's no constructor named `Async`
      ┌─ test.ren:6:17
    6 │   print(attempt Async.timeout(Duration.seconds(10)) fn() => 2)
      │                 ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 accept] a timeout never reports `Timeout` for work that finished" =
  (* the body has finished when the deadline passes, and its handler's
     `finally`, the commit, runs shielded past it *)
  until "s3"
    ~want:{|
committed
Ok(7)
()
|}
    (fun () ->
      run
        {|
dep Db =
  put: fn(x: Int)

handler slow_commit() for Db uses Clock, Console =
  var kept = 0
  finally(r) =>
    Clock.sleep(Duration.ms(50))
    print("committed")
    try r
  put(x) => kept = x

fn main() uses Console, Async, Clock =
  let r = attempt Async.timeout(Duration.ms(20)) fn() =>
    with slow_commit() in
      Db.put(1)
      7
  print(r)
|});
  [%expect {|
    (until s3)
    error: nothing installs `Async` before `main`
       ┌─ test.ren:12:25
    12 │ fn main() uses Console, Async, Clock =
       │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
       help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
       ┌─ test.ren:13:19
    13 │   let r = attempt Async.timeout(Duration.ms(20)) fn() =>
       │                   ^^^^^
       help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 accept] deadlines carry down" =
  (* the inner timeout runs to the outer's sooner deadline *)
  until "s3"
    ~want:{|
Err(Timeout)
true
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async, Clock =
  let start = Clock.instant()
  let r = attempt Async.timeout(Duration.ms(20)) fn() =>
    try Async.timeout(Duration.seconds(10)) fn() =>
      Clock.sleep(Duration.seconds(5))
      1
  print(r)
  print(Clock.instant() - start < Duration.seconds(1))
|});
  [%expect {|
    (until s3)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:1:25
    1 │ fn main() uses Console, Async, Clock =
      │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:3:19
    3 │   let r = attempt Async.timeout(Duration.ms(20)) fn() =>
      │                   ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`

    error: there's no constructor named `Async`
      ┌─ test.ren:4:9
    4 │     try Async.timeout(Duration.seconds(10)) fn() =>
      │         ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 accept] `race` gives the first to finish" =
  until "s3"
    ~want:{|
fast
()
|}
    (fun () ->
      run
        {|
fn after(ms: Int, what: Str) -> Str uses Clock =
  Clock.sleep(Duration.ms(ms))
  what

fn main() uses Console, Async, Clock =
  print(Async.race(fn() => after(200, "slow"), fn() => after(5, "fast")))
|});
  [%expect {|
    (until s3)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:5:25
    5 │ fn main() uses Console, Async, Clock =
      │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:6:9
    6 │   print(Async.race(fn() => after(200, "slow"), fn() => after(5, "fast")))
      │         ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 accept] `isolate` makes a panic a value" =
  until "s3"
    ~want:
      {|
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}
    (fun () ->
      run
        {|
fn boom(xs: Array<Int>) -> Int = xs[5]

fn main() uses Console, Async =
  print(attempt Async.isolate fn() => boom([1]))
|});
  [%expect {|
    (until s3)
    error: expected `,` or `)`, found `fn`
      ┌─ test.ren:4:31
    4 │   print(attempt Async.isolate fn() => boom([1]))
      │                               ^^
    |}]

let%expect_test "[s3 accept] `map` keeps the order, and its first failure wins" =
  until "s3"
    ~want:{|
[30, 10, 20]
Err(Bad(2))
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  print(Async.map([3, 1, 2]) fn(x) => x * 10)
  print(attempt Async.map([1, 2, 3]) fn(x) => if x == 2 then fail Bad(x) else x)
|});
  [%expect {|
    (until s3)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:1:25
    1 │ fn main() uses Console, Async =
      │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:2:9
    2 │   print(Async.map([3, 1, 2]) fn(x) => x * 10)
      │         ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`

    error: there's no constructor named `Async`
      ┌─ test.ren:3:17
    3 │   print(attempt Async.map([1, 2, 3]) fn(x) => if x == 2 then fail Bad(x) else x)
      │                 ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 accept] `each` and `both`" =
  until "s3"
    ~want:{|
1
2
(1, "two")
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  Async.each([1, 2]) fn(x) => print(x)
  print(Async.both(fn() => 1, fn() => "two"))
|});
  [%expect {|
    (until s3)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:1:25
    1 │ fn main() uses Console, Async =
      │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:2:3
    2 │   Async.each([1, 2]) fn(x) => print(x)
      │   ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`

    error: there's no constructor named `Async`
      ┌─ test.ren:3:9
    3 │   print(Async.both(fn() => 1, fn() => "two"))
      │         ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 reject] `Async.until` outside an operation" =
  until "s3"
    ~says:
      [
        "error: `Async.until` waits for a handler's state to change, so it's \
         only written in one of its operations";
        "help: move the wait into an operation of the handler whose state it \
         reads";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Async =
  let ready = true
  Async.until(fn() => ready)
|});
  [%expect {|
    (until s3)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:1:16
    1 │ fn main() uses Async =
      │                ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:3:3
    3 │   Async.until(fn() => ready)
      │   ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 reject] `Async.until`'s condition uses a dependency" =
  until "s3"
    ~says:
      [
        "error: `Async.until`'s condition can't use `Clock`";
        "help: read it in the operation, before the wait";
      ]
    (fun () ->
      check_error
        {|
dep Gate =
  wait: fn()

handler gate(at: Time) for Gate uses Async, Clock =
  wait() => Async.until(fn() => Clock.now() > at)
fn main() = ()
|});
  [%expect {|
    (until s3)
    error: there's no constructor named `Async`
      ┌─ test.ren:5:13
    5 │   wait() => Async.until(fn() => Clock.now() > at)
      │             ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 reject] an isolated block changes a variable outside it" =
  until "s3"
    ~says:
      [
        "error: an isolated block can't change `n`, which is outside it";
        "help: give it back as the block's result: `let n = try \
         Async.isolate fn() => ...`";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Console, Async =
  var n = 0
  let r = attempt Async.isolate fn() => n += 1
  print(n)
|});
  [%expect {|
    (until s3)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:3:33
    3 │   let r = attempt Async.isolate fn() => n += 1
      │                                 ^^
    |}]

let%expect_test "[s3 reject] `Async.isolate` of a block parameter" =
  until "s3"
    ~says:
      [
        "error: `Async.isolate` takes a block written here, not `f`";
        "help: write the block: `Async.isolate fn() => f()`";
      ]
    (fun () ->
      check_error
        {|
fn guarded(f: fn() -> Int) -> Int ! Panicked(msg: Str) uses Async =
  try Async.isolate(f)
fn main() = ()
|});
  [%expect {|
    (until s3)
    error: `fn guarded` says it can fail with `Panicked`, but nothing in it can
      ┌─ test.ren:1:37
    1 │ fn guarded(f: fn() -> Int) -> Int ! Panicked(msg: Str) uses Async =
      │                                     ^^^^^^^^
      = a signature lists exactly what a function can fail with, so its callers handle nothing that can't happen
      help: remove `Panicked` from after `!`

    error: there's no constructor named `Async`
      ┌─ test.ren:2:7
    2 │   try Async.isolate(f)
      │       ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 reject] `each`'s block gives a value" =
  until "s3"
    ~says:
      [
        "error: `Async.each`'s block gives an `Int`, which `each` would throw \
         away";
        "help: use `Async.map` to keep the results, or end the block with `()`";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Async =
  Async.each([1, 2]) fn(x) => x * 2
|});
  [%expect {|
    (until s3)
    error: nothing installs `Async` before `main`
      ┌─ test.ren:1:16
    1 │ fn main() uses Async =
      │                ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Async` yet

    error: there's no constructor named `Async`
      ┌─ test.ren:2:3
    2 │   Async.each([1, 2]) fn(x) => x * 2
      │   ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`
    |}]

let%expect_test "[s3 reject] there's no `par_map`" =
  until "s3"
    ~says:
      [
        "error: `Array<Int>` has no method named `par_map`";
        "`Async.map(xs) fn(x) => ...` runs on every core when its block uses \
         no dependencies";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Console =
  print([1, 2].par_map(fn(x) => x * 2))
|});
  [%expect {|
    (until s3)
    error: `Array<Int>` has no method named `par_map`
      ┌─ test.ren:2:16
    2 │   print([1, 2].par_map(fn(x) => x * 2))
      │                ^^^^^^^
      help: its methods: `len`, `push`, `sort`, `copy`, `split_at`, `get`, `first`, `last`, `map`, `flat_map`, `select`, `reject`, `find`, `index`, `any`, `all`, `count`, `includes`, `each`, `reduce`, `sum`, `min`, `max`, `min_by`, `max_by`, `sort_by`, `group_by`, `partition`, `tally`, `uniq`, `zip`, `with_index`, `take`, `drop`, `reverse`
    |}]

let%expect_test "[s3 reject] every task waiting, with nothing to wake one" =
  until "s3"
    ~says:
      [
        "error: panic: every task is waiting, and nothing can wake one";
        "main waits in `Async.until`";
      ]
    (fun () ->
      run_error
        {|
dep Gate =
  wait: fn()

handler gate() for Gate uses Async =
  wait() => Async.until(fn() => false)

fn main() uses Console, Async =
  with gate() in
    Gate.wait()
|});
  [%expect {|
    (until s3)
    error: there's no constructor named `Async`
      ┌─ test.ren:5:13
    5 │   wait() => Async.until(fn() => false)
      │             ^^^^^
      help: check the spelling, or declare it in a type, like `type Shape = | Async`

    error: nothing installs `Async` before `main`
      ┌─ test.ren:7:25
    7 │ fn main() uses Console, Async =
      │                         ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
    8 │   with gate() in
      │        ------ installing this needs `Async`
      help: remove it: nothing can implement `Async` yet
    |}]

(* ---- s4: operations that don't interleave ---- *)

let%expect_test "[s4 accept] an operation keeps its instance across its own calls" =
  (* each deposit reads the balance, sleeps, and writes it: the second
     waits for the first to return, so neither is lost *)
  until "s4"
    ~want:{|
20
()
|}
    (fun () ->
      run
        {|
dep Acct =
  deposit: fn(n: Int)
  balance: fn() -> Int

handler slow_acct() for Acct uses Clock =
  var b = 0
  deposit(n) =>
    let old = b
    Clock.sleep(Duration.ms(5))
    b = old + n
  balance() => b

fn main() uses Console, Async =
  with slow_acct() in
    Async.scope fn(s) =>
      s.spawn fn() => Acct.deposit(10)
      s.spawn fn() => Acct.deposit(10)
    print(Acct.balance())
|});
  [%expect {|
    (until s4)
    error: expected the end of the line, found `fn`
       ┌─ test.ren:15:17
    15 │     Async.scope fn(s) =>
       │                 ^^
    |}]

let%expect_test "[s4 reject] a block passed to an operation calls back into it" =
  until "s4"
    ~says:
      [
        "error: a block passed to `Tally.change` can't use `Tally`, which it \
         would wait for while `Tally.change` runs it";
        "help: call it before `Tally.change`, outside the block";
      ]
    (fun () ->
      check_error
        {|
dep Tally =
  change: fn(f: fn(&Int))
  get: fn() -> Int

handler counts() for Tally =
  var c = 0
  change(f) =>
    var x = c
    f(&x)
    c = x
  get() => c

fn main() uses Console =
  with counts() in
    Tally.change(fn(&x) => x = Tally.get() + 1)
    print(Tally.get())
|});
  [%expect {|
    (until s4)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

(* ---- s5: the runtime as a handler, and virtual time ---- *)

let%expect_test "[s5 accept] tasks sleep at once, in virtual time" =
  until "s5"
    ~want:
      {|
test.ren
  ✓ two tasks sleep at once
  ✓ tasks wake in the order of their deadlines

2 passed
[exit 0]
|}
    (fun () ->
      test
        {|
test "two tasks sleep at once" =
  Async.scope fn(s) =>
    s.spawn fn() => Clock.sleep(Duration.minutes(60))
    s.spawn fn() => Clock.sleep(Duration.minutes(30))
  assert Clock.now() == Time.epoch + Duration.minutes(60)

test "tasks wake in the order of their deadlines" =
  Async.scope fn(s) =>
    s.spawn fn() =>
      Clock.sleep(Duration.seconds(3))
      print("three")
    s.spawn fn() =>
      Clock.sleep(Duration.seconds(1))
      print("one")
  assert TestConsole.output() == ["one", "three"]
|});
  [%expect {|
    (until s5)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^

    error: expected the end of the line, found `fn`
      ┌─ test.ren:8:15
    8 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s5 accept] a runtime installed by hand" =
  until "s5"
    ~want:{|
in a task
()
|}
    (fun () ->
      run
        {|
import sim

fn main() uses Console =
  with sim.scheduler(7) in
    Async.scope fn(s) =>
      s.spawn fn() => print("in a task")
|});
  [%expect {|
    (until s5)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:5:17
    5 │     Async.scope fn(s) =>
      │                 ^^
    |}]

let%expect_test "[s5 reject] a runtime installed while other tasks run" =
  until "s5"
    ~says:
      [
        "error: panic: `Async.single()` is installed while other tasks run";
        "help: install it once, around `main`'s body: `ren run` installs \
         `Async.single()` itself, and `ren test` a `sim.scheduler`";
      ]
    (fun () ->
      run_error
        {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print("a")
    with Async.single() in print("b")
|});
  [%expect {|
    (until s5)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:2:15
    2 │   Async.scope fn(s) =>
      │               ^^
    |}]

let%expect_test "[s5 reject] a module of a program's own named `sim`" =
  until "s5"
    ~says:[ "error: `sim` is the standard library's" ]
    (fun () ->
      check_error_files
        [
          ("main.ren", {|
import sim

fn main() = sim.go()
|});
          ("sim.ren", {|
pub fn go() = ()
|});
        ]);
  [%expect {|
    (until s5)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

(* ---- s8: the standard library ---- *)

let%expect_test "[s8 accept] a channel's send waits while it's full" =
  until "s8"
    ~want:{|
1
2
()
|}
    (fun () ->
      run
        {|
import sync.{Chan}

fn main() uses Console, Async =
  with sync.channel(1) in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Chan.send(1)
        Chan.send(2)
        Chan.close()
      var going = true
      while going
        match Chan.recv()
          Some(x) => print(x)
          None => going = false
|});
  [%expect {|
    (until s8)
    error: expected the end of the line, found `fn`
      ┌─ test.ren:5:17
    5 │     Async.scope fn(s) =>
      │                 ^^
    |}]

let%expect_test "[s8 accept] `keyed` sends each call to an instance by its key" =
  until "s8"
    ~want:{|
2
1
()
|}
    (fun () ->
      run
        {|
import sync

dep Counts =
  add: fn(key: Str)
  get: fn(key: Str) -> Int

handler counts() for Counts =
  var m: Map<Str, Int> = Map.of([])
  add(k) => &m.set(k, m.get(k).unwrap_or(0) + 1)
  get(k) => m.get(k).unwrap_or(0)

fn main() uses Console, Async =
  with sync.keyed(4, counts()) in
    Counts.add("a")
    Counts.add("b")
    Counts.add("a")
    print(Counts.get("a"))
    print(Counts.get("b"))
|});
  [%expect {|
    (until s8)
    error: there's no module `sync`
      ┌─ test.ren:1:8
    1 │ import sync
      │        ^^^^
      = it would be the file `sync.ren`
      help: check the module's name, or create its file
    |}]

let%expect_test "[s8 reject] `keyed` of what isn't a handler's description" =
  until "s8"
    ~says:
      [
        "error: `keyed` takes a handler's description, and `16` is an `Int`";
        "help: describe the handler whose instances it keeps: `keyed(16, \
         accounts())`";
      ]
    (fun () ->
      check_error
        {|
import sync

fn main() uses Console =
  with sync.keyed(4, 16) in print(1)
|});
  [%expect {|
    (until s8)
    error: there's no module `sync`
      ┌─ test.ren:1:8
    1 │ import sync
      │        ^^^^
      = it would be the file `sync.ren`
      help: check the module's name, or create its file
    |}]

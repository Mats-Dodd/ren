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
     s7  `sim.net()`, the network a test gets
     s8  the standard library, `sync`
     s9  what the review found (compiler.md, "Step 9, as built")

   Step 6, the journal, is specified by test_journal.ml and the programs
   in bench/11a/tasks (bench/tasks.t), and the milestone too; step 7's
   server is examples/server, and the real `Net` is examples/net.t's.

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
  run
    {|
fn scaled(n: Int, by: Int = 10) -> Int = n * by

fn main() uses Console =
  print(scaled(2))
  print(scaled(2, by: 3))
|};
  [%expect {|
    20
    6
    ()
    |}]

let%expect_test "[s1 reject] a default given by position" =
  check_error
    {|
fn scaled(n: Int, by: Int = 10) -> Int = n * by
fn main() uses Console = print(scaled(2, 3))
|};
  [%expect {|
    error: `by` has a default, so it's given by name
      ┌─ test.ren:2:42
    2 │ fn main() uses Console = print(scaled(2, 3))
      │                                          ^
      help: write `by: 3`
    |}]

let%expect_test "[s1 reject] a default that isn't a literal" =
  check_error
    {|
fn scaled(n: Int, by: Int = n) -> Int = n * by
fn main() uses Console = print(scaled(2))
|};
  [%expect {|
    error: a parameter's default is a literal, or a variant written bare
      ┌─ test.ren:1:29
    1 │ fn scaled(n: Int, by: Int = n) -> Int = n * by
      │                             ^
      help: give it where it's called instead
    |}]

let%expect_test "[s1 reject] a default before a parameter without one" =
  check_error
    {|
fn scaled(by: Int = 10, n: Int) -> Int = n * by
fn main() uses Console = print(scaled(n: 2))
|};
  [%expect {|
    error: a parameter with a default comes after those without
      ┌─ test.ren:1:11
    1 │ fn scaled(by: Int = 10, n: Int) -> Int = n * by
      │           ^^
      help: move `by` after `n`
    |}]

let%expect_test "[s1 reject] a parameter given by a name it doesn't have" =
  check_error
    {|
fn scaled(n: Int, by: Int = 10) -> Int = n * by
fn main() uses Console = print(scaled(2, times: 3))
|};
  [%expect {|
    error: `scaled` has no parameter named `times`
      ┌─ test.ren:2:42
    2 │ fn main() uses Console = print(scaled(2, times: 3))
      │                                          ^^^^^
      help: its parameters given by name: `by`
    |}]

let%expect_test "[s1 accept] a block given without parentheses" =
  run
    {|
fn twice(f: fn() -> Int) -> Int = try f() + f()

fn main() uses Console =
  print(twice fn() => 21)
|};
  [%expect {|
    42
    ()
    |}]

let%expect_test "[s1 accept] a block parameter's mode is part of its signature" =
  (* written on public functions, inferred on private ones *)
  types
    {|
pub fn fan_out(xs: Array<Int>, f: concurrent fn(Int) -> Int) -> Array<Int> uses Async =
  try Async.map(xs, f)

pub fn start(s: Scope, body: spawned fn()) uses Async = s.spawn(body)

fn doubled(xs: Array<Int>, f: fn(Int) -> Int) -> Array<Int> uses Async =
  try Async.map(xs, f)
fn main() = ()
|};
  [%expect {|
    pub fn fan_out(xs: Array<Int>, f: concurrent fn(Int) -> Int) -> Array<Int> uses Async
    pub fn start(s: Scope, body: spawned fn()) uses Async
    fn doubled(xs: Array<Int>, f: concurrent fn(Int) -> Int) -> Array<Int> uses Async
    fn main()
    |}]

let%expect_test "[s1 reject] a mode on what isn't a block parameter" =
  check_error
    {|
fn f(n: concurrent Int) -> Int = n
fn main() uses Console = print(f(1))
|};
  [%expect {|
    error: `concurrent` marks a block parameter of a function
      ┌─ test.ren:1:9
    1 │ fn f(n: concurrent Int) -> Int = n
      │         ^^^^^^^^^^
      help: remove it
    |}]

(* ---- s1: rule B, a parameter's mode ---- *)

let%expect_test "[s1 reject] a block parameter passed on to `Async.map`, unmarked" =
  check_error
    {|
pub fn fan_out(xs: Array<Int>, f: fn(Int) -> Int) -> Array<Int> uses Async =
  try Async.map(xs, f)
fn main() = ()
|};
  [%expect {|
    error: `f` runs on several tasks at once in `Async.map`, but `fan_out` doesn't say it can
      ┌─ test.ren:2:21
    2 │   try Async.map(xs, f)
      │                     ^
      = a block that runs on several tasks at once can only read what it captures
      help: mark the parameter: `f: concurrent fn(Int) -> Int`
    |}]

let%expect_test "[s1 reject] a block parameter spawned, unmarked" =
  check_error
    {|
pub fn start(s: Scope, body: fn()) uses Async = s.spawn(body)
fn main() = ()
|};
  [%expect {|
    error: `body` is spawned as a task here, but `start` doesn't say it can be
      ┌─ test.ren:1:57
    1 │ pub fn start(s: Scope, body: fn()) uses Async = s.spawn(body)
      │                                                         ^^^^
      = a spawned block runs until its scope ends, and can only read what it captures
      help: mark the parameter: `body: spawned fn()`
    |}]

let%expect_test "[s1 reject] a concurrent block parameter spawned" =
  check_error
    {|
pub fn start(s: Scope, body: concurrent fn()) uses Async = s.spawn(body)
fn main() = ()
|};
  [%expect {|
    error: `body` is concurrent, so it can't be spawned
      ┌─ test.ren:1:68
    1 │ pub fn start(s: Scope, body: concurrent fn()) uses Async = s.spawn(body)
      │                                                                    ^^^^
      help: mark the parameter `spawned` instead
    |}]

(* ---- s1: what a task's block can touch ---- *)

let%expect_test "[s1 reject] a variable a spawned task reads, changed in the scope" =
  (* foundations.md, decision 2's own error *)
  check_error
    {|
fn log(n: Int) uses Console = print(n)

fn main() uses Console, Async =
  var n = 0
  Async.scope fn(s) =>
    s.spawn fn() => log(n)
    n += 1
|};
  [%expect {|
    error: `n` can't change while a spawned task reads it
      ┌─ test.ren:7:5
    6 │     s.spawn fn() => log(n)
      │                         - read until `Async.scope` ends
    7 │     n += 1
      │     ^
      = a spawned task reads what it captures from the frame that called `Async.scope` where it is, until the scope ends
      help: copy it for the task, `let m = n`, or change it after the scope
    |}]

let%expect_test "[s1 reject] a block that runs on several tasks at once changes a variable" =
  check_error
    {|
fn main() uses Console, Async =
  var total = 0
  let xs = Async.map([1, 2]) fn(x) =>
    total += x
    x
  print(total + xs.len())
|};
  [%expect {|
    error: `total` can't change in a block that runs on several tasks at once
      ┌─ test.ren:4:5
    4 │     total += x
      │     ^^^^^ changed here
      = a block that runs on several tasks at once can only read what it captures
      help: give back what each one makes, and add them up after: `Async.map(xs) fn(x) => ...`, then `.sum()`
    |}]

let%expect_test "[s1 reject] a spawned task changes a variable" =
  check_error
    {|
fn main() uses Console, Async =
  var seen = 0
  Async.scope fn(s) =>
    s.spawn fn() => seen += 1
  print(seen)
|};
  [%expect {|
    error: a spawned task can't change `seen`, which it only reads
      ┌─ test.ren:4:21
    4 │     s.spawn fn() => seen += 1
      │                     ^^^^ changed here
      = a spawned task only reads what it captures, while other tasks run
      help: change it through a handler's operation, or give it back: `t.join()` has what the task returned
    |}]

(* ---- s1: rule D, a scope and a handle are blocks too ---- *)

let%expect_test "[s1 reject] a task's handle returned" =
  check_error
    {|
fn first(s: Scope) -> Task<Int> uses Async = s.start fn() => 1
fn main() uses Async = Async.scope fn(s) => first(s).cancel()
|};
  [%expect {|
    error: a task's handle can't be returned: it's only good inside its scope
      ┌─ test.ren:1:23
    1 │ fn first(s: Scope) -> Task<Int> uses Async = s.start fn() => 1
      │                       ^^^^ a task's handle's type
      help: return what the task makes: `t.join()`
    |}]

let%expect_test "[s1 reject] a scope kept in a record" =
  check_error
    {|
type Holder = { s: Scope }
fn main() = ()
|};
  [%expect {|
    error: a record can't hold a scope
      ┌─ test.ren:1:20
    1 │ type Holder = { s: Scope }
      │                    ^^^^^ a scope's type
      = a scope is only good inside its `Async.scope` call
      help: pass it to the functions that spawn into it
    |}]

let%expect_test "[s1 reject] tasks' handles kept in an array" =
  check_error
    {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    let ts = [s.start fn() => 1, s.start fn() => 2]
    print(ts.len())
|};
  [%expect {|
    error: `Task<Int>` can't be a type argument: a task's handle is only good inside its scope
      ┌─ test.ren:3:14
    3 │     let ts = [s.start fn() => 1, s.start fn() => 2]
      │              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ a task's handle
      help: keep what the tasks make instead: `Async.map` gives every result, in order

    error: `Task<Int>` can't be a type argument: a task's handle is only good inside its scope
      ┌─ test.ren:4:11
    4 │     print(ts.len())
      │           ^^^^^^ a task's handle
      help: keep what the tasks make instead: `Async.map` gives every result, in order
    |}]

(* ---- s1: blocks that can't fail ---- *)

let%expect_test "[s1 reject] a spawned task that can fail" =
  check_error
    {|
fn handle(n: Int) -> Int ! Bad = if n > 0 then n else fail Bad

fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print(try handle(1))
|};
  [%expect {|
    error: a spawned task can't fail, or one task's failure would stop all the others
      ┌─ test.ren:5:13
    5 │     s.spawn fn() => print(try handle(1))
      │             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      │                     -------------------- can fail with Bad
      help: handle them in the task: `match attempt handle(1)`
    |}]

let%expect_test "[s1 reject] a branch of `race` that can fail" =
  check_error
    {|
fn get(n: Int) -> Int ! Gone = if n > 0 then n else fail Gone

fn main() uses Console, Async =
  print(Async.race(fn() => try get(1), fn() => 2))
|};
  [%expect {|
    error: a branch of `race` can't fail, or a failure could leave the race waiting on the other
      ┌─ test.ren:4:20
    4 │   print(Async.race(fn() => try get(1), fn() => 2))
      │                    ^^^^^^^^^^^^^^^^^^
      │                            ---------- can fail with Gone
      help: make the failure a value inside it: `attempt get(1)`; to try again until one succeeds, use `retry`
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
  check_error
    (tx_src
      ^ {|
fn store(k: Int) ! DbDown uses Sql =
  with transaction() over Sql in
    try Sql.set(k)

fn main() = ()
|});
  [%expect {|
    error: installing `transaction()` can fail, and nothing handles it
       ┌─ test.ren:22:3
    22 │   with transaction() over Sql in
       │   ^^^^ it can fail with `DbDown`
       help: write `try with`, or handle its errors with `match`
    |}]

let%expect_test "[s1 reject] `try with` marks the installation, not the body" =
  (* the body's call is a place the code can stop, so it has a `try` of
     its own *)
  check_error
    (tx_src
      ^ {|
fn store(k: Int) ! DbDown uses Sql =
  try with transaction() over Sql in
    Sql.set(k)

fn main() = ()
|});
  [%expect {|
    error: `Sql.set` can fail, and nothing handles it
       ┌─ test.ren:23:5
    23 │     Sql.set(k)
       │     ^^^^^^^^^^
       │     ------- it can fail with `DbDown`
       help: pass the errors on with `try`, or handle them with `match`
    |}]

let%expect_test "[s1 reject] `try with` where installing can't fail" =
  check_error
    (tx_src
      ^ {|
fn store(k: Int) ! DbDown uses Sql =
  try with plain() over Sql in
    try Sql.set(k)

fn main() = ()
|});
  [%expect {|
    error: nothing here can fail
       ┌─ test.ren:22:3
    22 │   try with plain() over Sql in
       │   ^^^
       = `try` marks the calls that can fail, so a reader can see where the code can stop
       help: installing these can't fail: remove the `try`
    |}]

(* ---- s1: the two holes, and what's gone ---- *)

let%expect_test "[s1 reject] a function that spawns uses `Async`" =
  (* `s.spawn` waits while its scope is full *)
  check_error {|
pub fn start(s: Scope) = s.spawn fn() => ()
fn main() = ()
|};
  [%expect {|
    error: `start` doesn't declare `Async`
      ┌─ test.ren:1:8
    1 │ pub fn start(s: Scope) = s.spawn fn() => ()
      │        ^^^^^
      │                          ------------------ this call uses `Async`
      = a public function without `uses` uses nothing, and its body is checked against that
      = `s.spawn` waits while its scope is full, so it uses `Async`
      help: add `uses Async`
    |}]

let%expect_test "[s1 reject] a handler's own task" =
  (* async.md's `task =>` is gone: background work is a task beside the
     `with` *)
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
|};
  [%expect {|
    error: a handler has no task of its own
      ┌─ test.ren:7:3
    7 │   task =>
      │   ^^^^
      help: run one beside the `with`'s body that calls one of the handler's operations: `with h() in Async.beside(task) fn() => ...`
    |}]

(* ---- s2: scopes and tasks ---- *)

let%expect_test "[s2 accept] a scope waits for its tasks" =
  (* the body runs until it waits, at its end, then each task in the
     order it was spawned *)
  run
    {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print("a")
    s.spawn fn() => print("b")
    print("body")
  print("after")
|};
  [%expect {|
    body
    a
    b
    after
    ()
    |}]

let%expect_test "[s2 accept] `spawn` waits while `max` tasks run" =
  run
    {|
fn main() uses Console, Async =
  Async.scope(max: 1) fn(s) =>
    s.spawn fn() => print("a")
    print("between")
    s.spawn fn() => print("b")
    print("body")
|};
  [%expect {|
    between
    a
    body
    b
    ()
    |}]

let%expect_test "[s2 accept] a variable bound inside the scope is copied into each task" =
  (* rule C: `i` isn't the frame's that calls `Async.scope`, so each task
     gets it as it was when it was spawned, and it can change after *)
  run
    {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    var i = 0
    while i < 3
      s.spawn fn() => print(i)
      i += 1
|};
  [%expect {|
    0
    1
    2
    ()
    |}]

let%expect_test "[s2 accept] a task's handle joins it" =
  run
    {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    let t = s.start fn() => 6 * 7
    print(t.join())
|};
  [%expect {|
    Some(42)
    ()
    |}]

let%expect_test "[s2 accept] a task cancelled before it runs never runs" =
  run
    {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    let t = s.start fn() => print("never")
    t.cancel()
    print(t.join())
|};
  [%expect {|
    None
    ()
    |}]

let%expect_test "[s2 accept] a cancelled task stops at its next call, and `finally` sees it" =
  (* the task is asleep when it's cancelled, so its wait ends; the
     handler's `finally` is given `Err(Cancelled)`, and `try r` goes on
     cancelling *)
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
|};
  [%expect {|
    started
    cancelled
    after
    ()
    |}]

let%expect_test "[s2 accept] `replace` cancels the task under its key" =
  run
    {|
fn main() uses Console, Async, Clock =
  Async.scope fn(s) =>
    s.replace("k") fn() =>
      Clock.sleep(Duration.seconds(60))
      print("first")
    Clock.sleep(Duration.ms(5))
    s.replace("k") fn() => print("second")
|};
  [%expect {|
    second
    ()
    |}]

let%expect_test "[s2 accept] a scope whose body fails cancels its tasks" =
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
|};
  [%expect {|
    Err(Stop)
    ()
    |}]

let%expect_test "[s2 accept] a task beside a `with`'s body is cancelled when it ends" =
  (* decision 7's background work: the ticker is spawned into the
     background of the `with`'s body, so when the body ends it's
     cancelled, and then the `with` runs its `finally`: three ticks, at
     100, 200 and 300 ms, then the body ends at 350. In virtual time,
     since a real timer can wake tens of milliseconds late (macOS
     coalesces them). Spawned into a scope outside the `with` instead,
     it's the compile error of test_services.ml's s3 *)
  run
    {|
import sim

dep Ticks =
  tick: fn()

handler ticks() for Ticks uses Console =
  var n = 0
  finally(r) =>
    print("ticks: " + show(n))
    try r
  tick() => n += 1

fn main() uses Console =
  with sim.scheduler(1) in
    with sim.clock() in
      ticking()

fn ticking() uses Console, Async, Clock =
  with ticks() in
    Async.background fn(bg) =>
      bg.spawn fn() =>
        while true
          Clock.sleep(Duration.ms(100))
          Ticks.tick()
      Clock.sleep(Duration.ms(350))
  print("after")
|};
  [%expect {|
    ticks: 3
    after
    ()
    |}]

let%expect_test "[s2 reject] a panic in a task says which task" =
  run_error
    {|
fn boom(xs: Array<Int>) -> Int = xs[3]

fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print(boom([1]))
|};
  [%expect {|
    error: panic: index 3 is out of bounds for an array of length 1
      ┌─ test.ren:1:34
    1 │ fn boom(xs: Array<Int>) -> Int = xs[3]
      │                                  ^^^^^
      = in the task main/main:0
    |}]

let%expect_test "[s2 reject] a scope that can start no task" =
  run_error
    {|
fn main() uses Console, Async =
  Async.scope(max: 0) fn(s) => s.spawn fn() => print(1)
|};
  [%expect {|
    error: panic: `Async.scope`'s `max` is 0, so it couldn't start a task
      ┌─ test.ren:2:3
    2 │   Async.scope(max: 0) fn(s) => s.spawn fn() => print(1)
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      help: `max:` is at least 1
    |}]

let%expect_test "[s2 reject] failing with `Cancelled`" =
  check_error
    {|
fn stop() ! Cancelled = fail Cancelled
fn main() = ()
|};
  [%expect {|
    error: `Cancelled` isn't an error a program can fail with
      ┌─ test.ren:1:25
    1 │ fn stop() ! Cancelled = fail Cancelled
      │                         ^^^^^^^^^^^^^^
      = a task is cancelled from outside it, and only a `finally` sees it: it isn't an error, so `attempt` can't keep it
      help: a cancelled task stops by itself; to stop early, return
    |}]

(* What step 2 settled beyond the specification's tests (compiler.md,
   "Stage 11a", "Step 2, as built"). *)

let%expect_test "[s2 accept] an arm's `finally` sees a cancel, as `Err(Cancelled)`" =
  (* the task is cancelled while the arm waits in the clock under it:
     the arm's `finally` runs (Core's `Covered`), and the cancel goes on *)
  run
    {|
dep Store =
  save: fn(n: Int)

handler slow() for Store uses Clock =
  save(n) => Clock.sleep(Duration.seconds(60))

handler logged() over Store uses Console =
  save(n) =>
    finally(r) =>
      match r
        Ok(_) => print("saved")
        Err(Cancelled) => print("cancelled while saving")
    next.save(n)

fn main() uses Console, Async, Clock =
  with logged() over slow() in
    Async.scope fn(s) =>
      let t = s.start fn() => Store.save(1)
      Clock.sleep(Duration.ms(5))
      t.cancel()
      print(t.join())
|};
  [%expect {|
    cancelled while saving
    None
    ()
    |}]

let%expect_test "[s2 accept] cancelling a task cancels the tasks of its scopes" =
  run
    {|
fn main() uses Console, Async, Clock =
  Async.scope fn(s) =>
    let t = s.start fn() =>
      Async.scope fn(inner) =>
        inner.spawn fn() =>
          Clock.sleep(Duration.seconds(60))
          print("never: the inner task")
        Clock.sleep(Duration.seconds(60))
        print("never: the outer task")
    Clock.sleep(Duration.ms(5))
    t.cancel()
    print(t.join())
  print("after")
|};
  [%expect {|
    None
    after
    ()
    |}]

let%expect_test "[s2 accept] a cancelled task runs until its next dependency call" =
  (* no preemption: `main` and `t` both wait for `u`, and are woken in
     that order when it ends, so `t` is asked to stop after its wait has
     ended, while it waits for its turn. It isn't stopped then, since its
     wait gave what it waited for: it runs on, and stops at its next
     call, `print`, which never happens *)
  run
    {|
fn main() uses Console, Async, Clock =
  Async.scope fn(s) =>
    let u = s.start fn() => Clock.sleep(Duration.ms(5))
    let t = s.start fn() =>
      let _ = u.join()
      let n = 6 * 7
      print(n)
      n
    let _ = u.join()
    t.cancel()
    print(t.join())
  print("after")
|};
  [%expect {|
    None
    after
    ()
    |}]

let%expect_test "[s2 accept] a cancel after a task has ended changes nothing" =
  (* `t` was spawned first, so it runs first, to its end *)
  run
    {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    let t = s.start fn() =>
      print("t")
      6 * 7
    s.spawn fn() => t.cancel()
    print("body")
    print(t.join())
  print("after")
|};
  [%expect {|
    body
    t
    Some(42)
    after
    ()
    |}]

let%expect_test "[s2 accept] a `finally` runs past a cancel, until the cleanup deadline" =
  (* the handler's `finally` is shielded, so its sleep isn't cancelled
     at once; 5 seconds after the cancel, the deadline, it is, and the
     rest of the `finally` never runs. Under `sim`, in virtual time, which
     takes none of the test's: the cancel at 5 ms, the deadline at 5005 *)
  run
    {|
import sim

dep Log =
  note: fn(s: Str)

handler slow() for Log uses Clock, Console =
  finally(r) =>
    print("cleaning")
    Clock.sleep(Duration.seconds(60))
    print("never: the cleanup ran past its deadline")
    try r
  note(s) => print(s)

fn main() uses Console =
  with sim.scheduler(1) in
    with sim.clock() in
      cancelled()

fn cancelled() uses Console, Async, Clock =
  let began = Clock.instant()
  Async.scope fn(s) =>
    let t = s.start fn() =>
      with slow() in
        Log.note("working")
        Clock.sleep(Duration.seconds(60))
    Clock.sleep(Duration.ms(5))
    t.cancel()
    print(t.join())
  print(Clock.instant() - began == Duration.ms(5005))
|};
  [%expect {|
    working
    cleaning
    None
    true
    ()
    |}]

let%expect_test "[s2 accept] `replace` waits for the task it cancels" =
  (* the first task is cancelled while it sleeps, and its `finally` runs
     to its end before the second task starts; the second's `finally`
     sleeps too, while the task under the string's key runs *)
  run
    {|
dep Log =
  note: fn(s: Str)

handler logs(name: Str) for Log uses Clock, Console =
  finally(r) =>
    Clock.sleep(Duration.ms(5))
    print(name + " cleaned up")
    try r
  note(s) => print(name + ": " + s)

fn main() uses Console, Async, Clock =
  Async.scope fn(s) =>
    s.replace(1) fn() =>
      with logs("first") in
        Log.note("working")
        Clock.sleep(Duration.seconds(60))
    Clock.sleep(Duration.ms(5))
    s.replace(1) fn() =>
      with logs("second") in
        Log.note("working")
    // a key of another type is another key
    s.replace("1") fn() => print("a string's")
|};
  [%expect {|
    first: working
    first cleaned up
    second: working
    a string's
    second cleaned up
    ()
    |}]

let%expect_test "[s2 accept] `fail Cancelled` in a `finally` goes on cancelling" =
  (* nothing asked the task to stop, but its `finally` goes on as if
     something had: the task ends as a cancelled one does *)
  run
    {|
dep Log =
  note: fn(s: Str)

handler stopping() for Log uses Console =
  finally(r) =>
    print("stopping")
    fail Cancelled
  note(s) => print(s)

fn main() uses Console, Async =
  Async.scope fn(s) =>
    let t = s.start fn() =>
      with stopping() in
        Log.note("working")
        1
    print(t.join())
|};
  [%expect {|
    working
    stopping
    None
    ()
    |}]

let%expect_test "[s2 accept] a task spawned in a handler's arm is labelled by it" =
  run_error
    {|
dep Pool =
  run: fn(n: Int)

handler pool() for Pool uses Async, Console =
  run(n) =>
    Async.scope fn(s) =>
      s.spawn fn() =>
        let xs = [1]
        print(xs[n])

fn main() uses Console, Async =
  with pool() in
    Pool.run(3)
|};
  [%expect {|
    error: panic: index 3 is out of bounds for an array of length 1
      ┌─ test.ren:9:15
    9 │         print(xs[n])
      │               ^^^^^
      = in the task main/pool.run:0
    |}]

let%expect_test "[s2 reject] a task a test spawns is the test's" =
  (* a test is the root task `test`, and the label of its code too *)
  test
    {|
fn main() = ()

test "a task panics" =
  Async.scope fn(s) =>
    s.spawn fn() =>
      let xs = [1]
      print(xs[2])
|};
  [%expect {|
    test.ren
      ✗ a task panics

    ──── a task panics ── test.ren:7
      │
    7 │       print(xs[2])
      │             ^^^^^
      │
      panic: index 2 is out of bounds for an array of length 1
      = in the task test/test:0

      seed 5919 · rerun: ren test test.ren --only "a task" --seed 5919

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "[s2 reject] every task waits for room in a full scope" =
  run_error
    {|
fn main() uses Console, Async =
  Async.scope(max: 1) fn(s) =>
    s.spawn fn() =>
      s.spawn fn() => print("never")
|};
  [%expect {|
    error: panic: every task is waiting, and nothing can wake one
      ┌─ test.ren:2:3
    2 │   Async.scope(max: 1) fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = main waits for its scope's tasks at test.ren:2:3
      = main/main:0 waits for room in its scope at test.ren:4:7
    |}]

let%expect_test "[s2 reject] a `finally` that names each error names `Cancelled` too" =
  check_error
    {|
dep Store =
  save: fn(n: Int) ! Short

handler counted() over Store uses Console =
  save(n) =>
    finally(r) =>
      match r
        Ok(_) => print("saved")
        Err(Short) => print("short")
      try r
    try next.save(n)

fn main() = ()
|};
  [%expect {|
    error: this `match` doesn't handle every `Result`
      ┌─ test.ren:7:7
    7 │       match r
      │       ^^^^^
      = missing: Err(Cancelled)
      help: add the missing arms, or a `_ =>` arm for the rest:
            Err(Cancelled) => todo
    |}]

(* ---- s3: the rest of `Async` ---- *)

let%expect_test "[s3 accept] `Async.until` waits for an operation's state" =
  (* the first task waits in `Gate.wait`, letting go of the gate; the
     second's `open` releases it with the condition holding, so the first
     goes on *)
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
|};
  [%expect {|
    opening
    through
    done
    ()
    |}]

let%expect_test "[s3 accept] `tick` and `yield`" =
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
|};
  [%expect {|
    a
    body
    b
    c
    after the tick
    ()
    |}]

let%expect_test "[s3 accept] a timeout gives `Timeout`, or the body's result" =
  run
    {|
fn main() uses Console, Async, Clock =
  let r = attempt Async.timeout(Duration.ms(20)) fn() =>
    Clock.sleep(Duration.seconds(10))
    1
  print(r)
  print(attempt Async.timeout(Duration.seconds(10)) fn() => 2)
|};
  [%expect {|
    Err(Timeout)
    Ok(2)
    ()
    |}]

let%expect_test "[s3 accept] a timeout never reports `Timeout` for work that finished" =
  (* the body has finished when the deadline passes, and its handler's
     `finally`, the commit, runs shielded past it *)
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
|};
  [%expect {|
    committed
    Ok(7)
    ()
    |}]

let%expect_test "[s3 accept] deadlines carry down" =
  (* the inner timeout runs to the outer's sooner deadline *)
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
|};
  [%expect {|
    Err(Timeout)
    true
    ()
    |}]

let%expect_test "[s3 accept] `race` gives the first to finish" =
  run
    {|
fn after(ms: Int, what: Str) -> Str uses Clock =
  Clock.sleep(Duration.ms(ms))
  what

fn main() uses Console, Async, Clock =
  print(Async.race(fn() => after(200, "slow"), fn() => after(5, "fast")))
|};
  [%expect {|
    fast
    ()
    |}]

let%expect_test "[s3 accept] `isolate` makes a panic a value" =
  run
    {|
fn boom(xs: Array<Int>) -> Int = xs[5]

fn main() uses Console, Async =
  print(attempt Async.isolate fn() => boom([1]))
|};
  [%expect {|
    Err(Panicked("index 5 is out of bounds for an array of length 1"))
    ()
    |}]

let%expect_test "[s3 accept] `map` keeps the order, and its first failure wins" =
  run
    {|
fn main() uses Console, Async =
  print(Async.map([3, 1, 2]) fn(x) => x * 10)
  print(attempt Async.map([1, 2, 3]) fn(x) => if x == 2 then fail Bad(x) else x)
|};
  [%expect {|
    [30, 10, 20]
    Err(Bad(2))
    ()
    |}]

let%expect_test "[s3 accept] `each` and `both`" =
  run
    {|
fn main() uses Console, Async =
  Async.each([1, 2]) fn(x) => print(x)
  print(Async.both(fn() => 1, fn() => "two"))
|};
  [%expect {|
    1
    2
    (1, "two")
    ()
    |}]

let%expect_test "[s3 reject] `Async.until` outside an operation" =
  check_error
    {|
fn main() uses Async =
  let ready = true
  Async.until(fn() => ready)
|};
  [%expect {|
    error: `Async.until` waits for a handler's state to change, so it's only written in one of its operations
      ┌─ test.ren:3:3
    3 │   Async.until(fn() => ready)
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^
      help: move the wait into an operation of the handler whose state it reads
    |}]

let%expect_test "[s3 reject] `Async.until`'s condition uses a dependency" =
  check_error
    {|
dep Gate =
  wait: fn()

handler gate(at: Time) for Gate uses Async, Clock =
  wait() => Async.until(fn() => Clock.now() > at)
fn main() = ()
|};
  [%expect {|
    error: `Async.until`'s condition can't use `Clock`
      ┌─ test.ren:5:33
    5 │   wait() => Async.until(fn() => Clock.now() > at)
      │                                 ^^^^^^^^^^^
      = it's checked again each time the handler is released, so it can only read the handler's state
      help: read it in the operation, before the wait
    |}]

let%expect_test "[s3 reject] an isolated block changes a variable outside it" =
  check_error
    {|
fn main() uses Console, Async =
  var n = 0
  let r = attempt Async.isolate fn() => n += 1
  print(n)
|};
  [%expect {|
    error: an isolated block can't change `n`, which is outside it
      ┌─ test.ren:3:41
    3 │   let r = attempt Async.isolate fn() => n += 1
      │                                         ^ changed here
      = nothing it changed is seen after a panic, so it changes only what it returns, and what it changes through operations
      help: give it back as the block's result: `let n = try Async.isolate fn() => ...`
    |}]

let%expect_test "[s3 reject] `Async.isolate` of a block parameter" =
  check_error
    {|
fn guarded(f: fn() -> Int) -> Int ! Panicked(msg: Str) uses Async =
  try Async.isolate(f)
fn main() = ()
|};
  [%expect {|
    error: `Async.isolate` takes a block written here, not `f`
      ┌─ test.ren:2:21
    2 │   try Async.isolate(f)
      │                     ^
      help: write the block: `Async.isolate fn() => f()`
    |}]

let%expect_test "[s3 reject] `each`'s block gives a value" =
  check_error
    {|
fn main() uses Async =
  Async.each([1, 2]) fn(x) => x * 2
|};
  [%expect {|
    error: `Async.each`'s block gives an `Int`, which `each` would throw away
      ┌─ test.ren:2:31
    2 │   Async.each([1, 2]) fn(x) => x * 2
      │                               ^^^^^
      help: use `Async.map` to keep the results, or end the block with `()`
    |}]

let%expect_test "[s3 reject] there's no `par_map`" =
  check_error
    {|
fn main() uses Console =
  print([1, 2].par_map(fn(x) => x * 2))
|};
  [%expect {|
    error: `Array<Int>` has no method named `par_map`
      ┌─ test.ren:2:16
    2 │   print([1, 2].par_map(fn(x) => x * 2))
      │                ^^^^^^^
      help: `Async.map(xs) fn(x) => ...` runs on every core when its block uses no dependencies
    |}]

let%expect_test "[s3 reject] every task waiting, with nothing to wake one" =
  run_error
    {|
dep Gate =
  wait: fn()

handler gate() for Gate uses Async =
  wait() => Async.until(fn() => false)

fn main() uses Console, Async =
  with gate() in
    Gate.wait()
|};
  [%expect {|
    error: panic: every task is waiting, and nothing can wake one
      ┌─ test.ren:5:13
    5 │   wait() => Async.until(fn() => false)
      │             ^^^^^^^^^^^^^^^^^^^^^^^^^^
      = main waits in `Async.until` at test.ren:5:13
    |}]

(* ---- s3: adversarial cases (compiler.md, "Step 3, as built") ---- *)

let%expect_test "[s3 accept] `Async.until` reads the state as it is, and the arm goes on from it" =
  (* a semaphore of one: each `acquire` that waited reads `free` again
     once it's woken, so none takes a permit another already took, and
     what the arm changed before it waited, `waited`, isn't lost *)
  run
    {|
dep Sem =
  acquire: fn()
  release: fn()
  free: fn() -> Int

handler sem(n: Int) for Sem uses Async =
  var free = n
  var waited = 0
  acquire() =>
    waited += 1
    Async.until(fn() => free > 0)
    free -= 1
  release() => free += 1
  free() => free * 100 + waited

fn work(name: Str) uses Sem, Console, Async =
  Sem.acquire()
  print((name, "in", Sem.free()))
  Async.yield()
  print((name, "out"))
  Sem.release()

fn main() uses Console, Async =
  with sem(1) in
    Async.scope fn(s) =>
      s.spawn fn() => work("a")
      s.spawn fn() => work("b")
      s.spawn fn() => work("c")
    print(Sem.free())
|};
  [%expect {|
    ("a", "in", 1)
    ("a", "out")
    ("b", "in", 3)
    ("b", "out")
    ("c", "in", 3)
    ("c", "out")
    103
    ()
    |}]

let%expect_test "[s3 accept] each release wakes the first waiter whose condition holds" =
  (* two tickets for three waiters, the third cancelled while it waits *)
  run
    {|
dep Gate =
  wait: fn(name: Str)
  open: fn()

handler gate() for Gate uses Async, Console =
  var tickets = 0
  wait(name) =>
    Async.until(fn() => tickets > 0)
    tickets -= 1
    print(name)
  open() => tickets += 1

fn main() uses Console, Async =
  with gate() in
    Async.scope fn(s) =>
      s.spawn fn() => Gate.wait("first")
      s.spawn fn() => Gate.wait("second")
      let t = s.start fn() => Gate.wait("third")
      s.spawn fn() =>
        Gate.open()
        Gate.open()
        t.cancel()
  print("done")
|};
  [%expect {|
    first
    second
    done
    ()
    |}]

let%expect_test "[s3 accept] a cancel ends a wait in `Async.until`, and the arm's `finally` runs" =
  run
    {|
dep Gate =
  wait: fn()

handler gate() for Gate uses Async, Console =
  wait() =>
    finally(r) =>
      print("given back")
      match r
        Ok(v) => v
        Err(_) => ()
    Async.until(fn() => false)

fn main() uses Console, Async =
  with gate() in
    Async.scope fn(s) =>
      let t = s.start fn() => Gate.wait()
      s.spawn fn() => t.cancel()
  print("done")
|};
  [%expect {|
    given back
    done
    ()
    |}]

let%expect_test "[s3 reject] a panic in `Async.until`'s condition is its waiter's" =
  run_error
    {|
dep Gate =
  wait: fn()
  open: fn()

handler gate() for Gate uses Async =
  var n = 0
  wait() => Async.until(fn() => [1][n] > 1)
  open() => n = 3

fn main() uses Console, Async =
  with gate() in
    Async.scope fn(s) =>
      s.spawn fn() => Gate.wait()
      s.spawn fn() => Gate.open()
|};
  [%expect {|
    error: panic: index 3 is out of bounds for an array of length 1
      ┌─ test.ren:7:33
    7 │   wait() => Async.until(fn() => [1][n] > 1)
      │                                 ^^^^^^
      = in the task main/main:0
    |}]

let%expect_test "[s3 reject] `Async.until` of a block bound elsewhere" =
  (* it's checked again as other tasks release the instance, so it has
     to read the state's cells, which only a block written there does *)
  check_error
    {|
dep Gate =
  wait: fn()

handler gate() for Gate uses Async =
  var open = false
  wait() =>
    let ready = fn() => open
    Async.until(ready)
fn main() = ()
|};
  [%expect {|
    error: `Async.until` takes a block written here, not `ready`
      ┌─ test.ren:8:17
    8 │     Async.until(ready)
      │                 ^^^^^
      help: write the block: `Async.until fn() => ready()`
    |}]

let%expect_test "[s3 accept] a timeout in a `finally` bounds its own body" =
  (* the outer timeout's body has finished, so its `finally`'s wait is
     shielded from it; the inner timeout began in the `finally`, so it
     isn't *)
  run
    {|
dep Slow =
  nothing: fn()

handler slow() for Slow uses Clock, Console, Async =
  finally(r) =>
    let inner = attempt Async.timeout(Duration.ms(10)) fn() =>
      Clock.sleep(Duration.seconds(3))
    print(inner)
    try r
  nothing() => ()

fn main() uses Console, Async, Clock =
  let start = Clock.instant()
  let r = attempt Async.timeout(Duration.ms(10)) fn() =>
    with slow() in
      1
  print(r)
  print(Clock.instant() - start < Duration.seconds(1))
|};
  [%expect {|
    Err(Timeout)
    Ok(1)
    true
    ()
    |}]

let%expect_test "[s3 accept] a timeout cancels the tasks of a scope inside it" =
  run
    {|
fn main() uses Console, Async, Clock =
  let r = attempt Async.timeout(Duration.ms(10)) fn() =>
    Async.scope fn(s) =>
      s.spawn fn() =>
        Clock.sleep(Duration.seconds(3))
        print("never")
      s.spawn fn() => print("ran")
  print(r)
|};
  [%expect {|
    ran
    Err(Timeout)
    ()
    |}]

let%expect_test "[s3 accept] `isolate` cleans up what was installed inside it" =
  (* a handler installed inside sees the panic as a cancel, and a scope
     inside cancels its tasks *)
  run
    {|
dep Db =
  put: fn(x: Int)

handler noisy() for Db uses Console =
  finally(r) =>
    match r
      Ok(_) => print("finally: ok")
      Err(_) => print("finally: err")
    try r
  put(x) => print(x)

fn main() uses Console, Async =
  let r = attempt Async.isolate fn() =>
    with noisy() in
      Db.put(1)
      let xs = [1]
      xs[4]
  print(r)
  let r2 = attempt Async.isolate fn() =>
    Async.scope fn(s) =>
      s.spawn fn() =>
        Async.yield()
        print("never")
      let xs = [1]
      xs[4]
  print(r2)
|};
  [%expect {|
    1
    finally: err
    Err(Panicked("index 4 is out of bounds for an array of length 1"))
    Err(Panicked("index 4 is out of bounds for an array of length 1"))
    ()
    |}]

let%expect_test "[s3 reject] a panic in an operation of an instance installed outside an isolate ends the program" =
  (* its state could be half changed (foundations.md, decision 8) *)
  run_error
    {|
dep Outer =
  boom: fn() -> Int

handler outer() for Outer =
  var n = 0
  boom() =>
    n += 1
    let xs = [1]
    xs[n + 3]

fn main() uses Console, Async =
  with outer() in
    print(attempt Async.isolate fn() => Outer.boom())
|};
  [%expect {|
    error: panic: index 4 is out of bounds for an array of length 1
      ┌─ test.ren:9:5
    9 │     xs[n + 3]
      │     ^^^^^^^^^
    |}]

let%expect_test "[s3 reject] an isolated block calls a block it was given" =
  check_error
    {|
fn guarded(f: fn() -> Int) -> Int ! Panicked(msg: Str) uses Async =
  try Async.isolate fn() => (try f()) + 1
fn main() = ()
|};
  [%expect {|
    error: an isolated block can't call `f`, a block it was given
      ┌─ test.ren:2:34
    2 │   try Async.isolate fn() => (try f()) + 1
      │                                  ^
      = a block it was given can change its caller's variables
      help: call it before the isolate, and isolate what uses what it gives
    |}]

let%expect_test "[s3 reject] an error `main` fails with says the task it came from" =
  run_error
    {|
fn main() ! Bad(n: Int) uses Console, Async =
  print(try Async.map([1, 2, 3]) fn(x) => if x == 2 then fail Bad(x) else x)
|};
  [%expect {|
    error: Bad(2)
      = from the task main/main:1
    |}]

let%expect_test "[s3 accept] the first failure wins, the other is cancelled" =
  (* `slow` has finished when `get` fails, so its `finally` runs on,
     shielded, and fails too: that's written to stderr, a warning, and
     the error is `get`'s *)
  run
    {|
dep Db =
  get: fn() -> Int ! Down
  slow: fn() -> Int ! Bad

handler db() for Db uses Clock =
  get() =>
    Clock.sleep(Duration.ms(5))
    fail Down
  slow() =>
    finally(r) =>
      Clock.sleep(Duration.ms(20))
      match r
        Ok(_) => fail Bad
        Err(_) => 0
    1

fn main() uses Console, Async, Clock =
  with db() in
    print(attempt Async.both(fn() => try Db.get(), fn() => try Db.slow()))
|};
  [%expect {|
    warning: main/main:1 failed too, with `Bad`, while it was being cancelled
    warning: main/main:1 failed too, with `Bad`, while it was being cancelled
    Err(Down)
    ()
    |}]

let%expect_test "[s3 accept] `map` runs `max` at once, and `race` cancels the loser" =
  run
    {|
fn main() uses Console, Async =
  print(Async.map([1, 2, 3, 4], max: 2) fn(x) =>
    print(("start", x))
    Async.yield()
    x * 2)
  print(Async.race(fn() => 1, fn() =>
    Async.yield()
    print("never")
    2))
|};
  [%expect {|
    ("start", 1)
    ("start", 2)
    ("start", 3)
    ("start", 4)
    [2, 4, 6, 8]
    1
    ()
    |}]

let%expect_test "[s3 reject] `map`'s `max` is 0" =
  run_error
    {|
fn main() uses Console, Async =
  print(Async.map([1], max: 0) fn(x) => x)
|};
  [%expect {|
    error: panic: `Async.map`'s `max` is 0, so it couldn't start a task
      ┌─ test.ren:2:9
    2 │   print(Async.map([1], max: 0) fn(x) => x)
      │         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      help: `max:` is at least 1
    |}]

(* ---- s4: operations that don't interleave ---- *)

let%expect_test "[s4 accept] an operation keeps its instance across its own calls" =
  (* each deposit reads the balance, sleeps, and writes it: the second
     waits for the first to return, so neither is lost. (Step 0 left
     `Clock` out of `main`'s `uses`, which this needs.) *)
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

fn main() uses Console, Async, Clock =
  with slow_acct() in
    Async.scope fn(s) =>
      s.spawn fn() => Acct.deposit(10)
      s.spawn fn() => Acct.deposit(10)
    print(Acct.balance())
|};
  [%expect {|
    20
    ()
    |}]

let%expect_test "[s4 reject] a block passed to an operation calls back into it" =
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
|};
  [%expect {|
    error: a block passed to `Tally.change` can't use `Tally`, which it would wait for while `Tally.change` runs it
       ┌─ test.ren:15:32
    15 │     Tally.change(fn(&x) => x = Tally.get() + 1)
       │                                ^^^^^^^^^^^
       = a block passed to an operation gets its dependencies only from its parameter's type
       help: call it before `Tally.change`, outside the block
    |}]

let%expect_test "[s4 reject] a block passed to an operation uses what its type doesn't list" =
  (* the operation holds its instance while it runs the block, so the
     block gets only what the operation gives it, its parameter's type *)
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

fn shown(inout x: Int) uses Console = print(x)

fn main() uses Console =
  with counts() in
    Tally.change(fn(&x) =>
      x += 1
      print(x))
    Tally.change(shown)
|};
  [%expect {|
    error: a block passed to `Tally.change` can't use `Console`, which its parameter's type doesn't list
       ┌─ test.ren:19:7
    19 │       print(x))
       │       ^^^^^^^^
       = a block passed to an operation gets its dependencies only from its parameter's type
       help: list it in the parameter's type, `fn(&Int) uses Console`, or call it before `Tally.change`, outside the block

    error: a block passed to `Tally.change` can't use `Console`, which its parameter's type doesn't list
       ┌─ test.ren:20:18
    20 │     Tally.change(shown)
       │                  ^^^^^
       = a block passed to an operation gets its dependencies only from its parameter's type
       help: list it in the parameter's type, `fn(&Int) uses Console`, or call it before `Tally.change`, outside the block
    |}]

let%expect_test "[s4 accept] a block passed to an operation uses what its type lists" =
  run
    {|
dep Tally =
  change: fn(f: fn(&Int) uses Console)
  get: fn() -> Int

handler counts() for Tally uses Console =
  var c = 0
  change(f) =>
    var x = c
    f(&x)
    c = x
  get() => c

fn main() uses Console =
  with counts() in
    Tally.change(fn(&x) =>
      x += 1
      print(x))
    print(Tally.get())
|};
  [%expect {|
    1
    1
    ()
    |}]

let%expect_test "[s4 accept] callers wait for an instance in use, first come first" =
  (* each `note` prints, sleeps and prints: they don't interleave, and
     they go in the order they were called *)
  run
    {|
dep Log =
  note: fn(who: Str)
  lines: fn() -> Array<Str>

handler slow_log() for Log uses Clock, Console =
  var seen: Array<Str> = []
  note(who) =>
    print(who)
    Clock.sleep(Duration.ms(2))
    &seen.push(who)
    print("done")
  lines() => seen

fn main() uses Console, Async, Clock =
  with slow_log() in
    Async.scope fn(s) =>
      s.spawn fn() => Log.note("a")
      s.spawn fn() => Log.note("b")
      Log.note("main")
      s.spawn fn() => Log.note("c")
    print(Log.lines())
|};
  [%expect {|
    main
    done
    a
    done
    b
    done
    c
    done
    ["main", "a", "b", "c"]
    ()
    |}]

let%expect_test "[s4 accept] a handler with no state takes no lock" =
  (* `echo` keeps nothing, so its operations interleave, as they always
     could: nothing it keeps can be lost *)
  run
    {|
dep Echo =
  say: fn(who: Str)

handler echo() for Echo uses Clock, Console =
  say(who) =>
    print(who)
    Clock.sleep(Duration.ms(2))
    print("done")

fn main() uses Console, Async, Clock =
  with echo() in
    Async.scope fn(s) =>
      s.spawn fn() => Echo.say("a")
      s.spawn fn() => Echo.say("b")
|};
  [%expect {|
    a
    b
    done
    done
    ()
    |}]

let%expect_test "[s4 accept] a handler that keeps a resource takes a lock" =
  (* no `var`, but its operations use a value of an opaque type, a
     resource, which they keep from each other's tasks *)
  run
    {|
type Session = opaque Int

fn connect() -> Session = 1

dep Db =
  query: fn(who: Str)

handler db(c: Session) for Db uses Clock, Console =
  query(who) =>
    print(who)
    print(c)
    Clock.sleep(Duration.ms(2))
    print("done")

fn main() uses Console, Async, Clock =
  with db(connect()) in
    Async.scope fn(s) =>
      s.spawn fn() => Db.query("a")
      s.spawn fn() => Db.query("b")
|};
  [%expect {|
    a
    Session(1)
    done
    b
    Session(1)
    done
    ()
    |}]

let%expect_test "[s4 accept] `Async.until` lets go of the instance while it waits" =
  (* `take` waits in `Async.until` holding nothing, so the `put`s get in;
     each release checks its condition *)
  run
    {|
dep Box =
  put: fn(x: Int)
  take: fn() -> Int

handler slot() for Box uses Async, Console =
  var items: Array<Int> = []
  put(x) =>
    &items.push(x)
    print(x)
  take() =>
    Async.until(fn() => items.len() > 0)
    let x = items[0]
    items = items[1..items.len()]
    x

fn main() uses Console, Async =
  with slot() in
    Async.scope fn(s) =>
      s.spawn fn() => print(Box.take() + Box.take())
      s.spawn fn() => Box.put(1)
      s.spawn fn() => Box.put(2)
|};
  [%expect {|
    1
    2
    3
    ()
    |}]

let%expect_test "[s4 accept] a waiter whose condition holds comes before the callers queued" =
  (* `take` waits; the first `put` sleeps holding the instance, and the
     second queues for it; when the first returns, `take`'s condition
     holds, so it goes on first *)
  run
    {|
dep Box =
  put: fn(x: Int)
  take: fn() -> Int

handler slot() for Box uses Async, Clock, Console =
  var items: Array<Int> = []
  put(x) =>
    print(x)
    Clock.sleep(Duration.ms(2))
    &items.push(x)
  take() =>
    Async.until(fn() => items.len() > 0)
    print("take goes on")
    items[0]

fn main() uses Console, Async, Clock =
  with slot() in
    Async.scope fn(s) =>
      s.spawn fn() => print(Box.take())
      s.spawn fn() => Box.put(1)
      s.spawn fn() => Box.put(2)
|};
  [%expect {|
    1
    take goes on
    1
    2
    ()
    |}]

let%expect_test "[s4 accept] a caller cancelled while it waits for the instance never gets in" =
  run
    {|
dep Gate =
  hold: fn()
  pass: fn(who: Str)

handler gate() for Gate uses Clock, Console =
  var n = 0
  hold() =>
    Clock.sleep(Duration.ms(5))
    n += 1
  pass(who) =>
    n += 1
    print(who)

fn main() uses Console, Async, Clock =
  with gate() in
    Async.scope fn(s) =>
      s.spawn fn() => Gate.hold()
      let t = s.start fn() => Gate.pass("cancelled, so never")
      s.spawn fn() => Gate.pass("second in line")
      Async.yield()
      t.cancel()
|};
  [%expect {|
    second in line
    ()
    |}]

let%expect_test "[s4 accept] a waiter cancelled in `Async.until` has the instance back for its `finally`" =
  (* `take` is cancelled while `slow` holds the instance: its arm's
     `finally` waits until `slow` has returned, so it never runs inside
     another operation *)
  run
    {|
dep Box =
  take: fn() -> Int
  slow: fn()

handler slot() for Box uses Async, Clock, Console =
  var items: Array<Int> = []
  take() =>
    finally(r) =>
      print("take's finally")
      match r
        Ok(v) => v
        Err(_) => 0
    Async.until(fn() => items.len() > 0)
    items[0]
  slow() =>
    print("slow starts")
    Clock.sleep(Duration.ms(5))
    print("slow ends")

fn main() uses Console, Async, Clock =
  with slot() in
    Async.scope fn(s) =>
      let t = s.start fn() => print(Box.take())
      s.spawn fn() => Box.slow()
      s.spawn fn() => t.cancel()
  print("done")
|};
  [%expect {|
    slow starts
    slow ends
    take's finally
    done
    ()
    |}]

let%expect_test "[s4 reject] a block parameter calls back into the operation running it" =
  (* Infer sees only a block written at the operation's call; one passed
     on through `bump` reaches it at run time, where a shared instance's
     operation calling back into itself could never go on *)
  run_error
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

fn bump(f: fn(&Int)) uses Tally = Tally.change(f)

fn main() uses Console, Async =
  with counts() in
    Async.scope fn(s) =>
      s.spawn fn() => print(Tally.get())
      bump(fn(&x) => x = Tally.get() + 1)
|};
  [%expect {|
    error: panic: `Tally.get` calls back into the instance its own task is in, so it would wait for itself
       ┌─ test.ren:19:26
    19 │       bump(fn(&x) => x = Tally.get() + 1)
       │                          ^^^^^^^^^^^
       = an operation keeps its instance until it returns, and this task is in one of its operations
       help: a block passed to an operation gets its dependencies only from its parameter's type: call it before the operation, outside the block
    |}]

(* ---- s5: the runtime as a handler, and virtual time ---- *)

let%expect_test "[s5 accept] tasks sleep at once, in virtual time" =
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
|};
  [%expect {|
    test.ren
      ✓ two tasks sleep at once
      ✓ tasks wake in the order of their deadlines

    2 passed
    [exit 0]
    |}]

let%expect_test "[s5 accept] a runtime installed by hand" =
  run
    {|
import sim

fn main() uses Console =
  with sim.scheduler(7) in
    Async.scope fn(s) =>
      s.spawn fn() => print("in a task")
|};
  [%expect {|
    in a task
    ()
    |}]

let%expect_test "[s5 reject] a runtime installed while other tasks run" =
  run_error
    {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print("a")
    with Async.single() in print("b")
|};
  [%expect {|
    error: panic: `Async.single()` is installed while other tasks run
      ┌─ test.ren:4:5
    4 │     with Async.single() in print("b")
      │     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = a runtime runs every task of its `with`, so it's installed where no other task runs yet
      help: install it once, around `main`'s body: `ren run` installs `Async.single()` itself, and `ren test` a `sim.scheduler`
    |}]

let%expect_test "[s5 reject] a module of a program's own named `sim`" =
  check_error_files
    [
      ("main.ren", {|
import sim

fn main() = sim.go()
|});
      ("sim.ren", {|
pub fn go() = ()
|});
    ];
  [%expect {|
    error: `sim` is the standard library's
      ┌─ main.ren:1:8
    1 │ import sim
      │        ^^^
      = `import sim` finds the standard library's, not a file
      help: rename the file `sim.ren`, and the imports of it
    |}]

let%expect_test "[s5 accept] `sim`'s order is drawn from its seed, the same each time" =
  (* two seeds, two orders; the same seed again, the same order *)
  run
    {|
import sim

fn three() uses Console, Async =
  Async.scope fn(s) =>
    s.spawn fn() => print("a")
    s.spawn fn() => print("b")
    s.spawn fn() => print("c")

fn main() uses Console =
  with sim.scheduler(1) in three()
  print("-")
  with sim.scheduler(2) in three()
  print("-")
  with sim.scheduler(1) in three()
|};
  [%expect {|
    c
    b
    a
    -
    b
    a
    c
    -
    c
    b
    a
    ()
    |}]

let%expect_test "[s5 accept] `--seeds` finds the lost update, and `--seed` replays it" =
  (* a read with one operation and a write with another: another task's
     deposit can come in between under some schedules, which `--seeds`
     tries one after another, stopping at the first that fails *)
  let src =
    {|
pub dep Account =
  balance: fn() -> Int
  set: fn(b: Int)

pub handler account() for Account =
  var b = 0
  balance() => b
  set(n) => b = n

pub fn deposit(n: Int) uses Account =
  let b = Account.balance()
  Account.set(b + n)

test "two deposits both land" =
  with account() in
    Async.scope fn(s) =>
      s.spawn fn() => deposit(10)
      s.spawn fn() => deposit(10)
    assert Account.balance() == 20
|}
  in
  (* seeds 5 to 8 pass; 9 is the first that loses one *)
  test ~seed:5 ~seeds:100 src;
  [%expect {|
    test.ren
      ✗ two deposits both land

    ──── two deposits both land ── test.ren:19
       │
    19 │     assert Account.balance() == 20
       │            ^^^^^^^^^^^^^^^^^^^^^^^
       │
       left:  10
       right: 20
              ^ differs here

       seed 9 · rerun: ren test test.ren --only "two deposits" --seed 9

    0 passed, 1 failed
    [exit 1]
    |}];
  (* the same again, from its seed alone *)
  test ~seed:9 src;
  [%expect {|
    test.ren
      ✗ two deposits both land

    ──── two deposits both land ── test.ren:19
       │
    19 │     assert Account.balance() == 20
       │            ^^^^^^^^^^^^^^^^^^^^^^^
       │
       left:  10
       right: 20
              ^ differs here

       seed 9 · rerun: ren test test.ren --only "two deposits" --seed 9

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "[s5 accept] a test passes under every seed it's run with" =
  test ~seeds:200
    {|
pub dep Ledger =
  balance: fn() -> Int
  add: fn(n: Int)

pub handler ledger() for Ledger =
  var b = 0
  balance() => b
  add(n) => b = b + n

test "two adds both land" =
  with ledger() in
    Async.scope fn(s) =>
      s.spawn fn() => Ledger.add(10)
      s.spawn fn() => Ledger.add(10)
    assert Ledger.balance() == 20

test "a tick lets every task that could run, run first" =
  Async.scope fn(s) =>
    s.spawn fn() => print("a")
    s.spawn fn() => print("b")
    Async.tick()
    assert TestConsole.output().len() == 2

test "advancing the clock wakes a sleeper it passes" =
  Async.scope fn(s) =>
    s.spawn fn() =>
      Clock.sleep(Duration.seconds(10))
      print("woke")
    // the task runs, and sleeps, while this one waits
    Clock.sleep(Duration.ms(1))
    TestClock.advance(Duration.seconds(10))
  assert Clock.now() == Time.epoch + Duration.ms(10001)
  assert TestConsole.output() == ["woke"]

test "a timeout's deadline is virtual too" =
  let r = attempt Async.timeout(Duration.seconds(30)) fn() =>
    Clock.sleep(Duration.minutes(60))
  assert r == Err(Timeout)
  assert Clock.instant() == Instant.zero + Duration.seconds(30)
|};
  [%expect {|
    test.ren
      ✓ two adds both land
      ✓ a tick lets every task that could run, run first
      ✓ advancing the clock wakes a sleeper it passes
      ✓ a timeout's deadline is virtual too

    4 passed, each under 200 seeds
    [exit 0]
    |}]

let%expect_test "[s5 accept] a task's numbers don't depend on the order tasks ran in" =
  (* the same test `Random` seed, two schedules: each task draws from a
     stream of its own, from the seed and its path *)
  test ~seed:7
    {|
import sim

pub dep Log =
  put: fn(name: Str, n: Int)
  get: fn(name: Str) -> Int

pub handler log() for Log =
  var m: Map<Str, Int> = Map.of([])
  put(name, n) => &m.set(name, n)
  get(name) => m.get(name).unwrap_or(-1)

pub fn draws() -> (Int, Int) uses Async, Random =
  with log() in
    Async.scope fn(s) =>
      s.spawn fn() => Log.put("a", Random.int(1000) * 1000 + Random.int(1000))
      s.spawn fn() => Log.put("b", Random.int(1000) * 1000 + Random.int(1000))
    (Log.get("a"), Log.get("b"))

test "under one schedule" =
  let d = with sim.scheduler(1) in draws()
  assert d == (28871, 22289)

test "under another" =
  let d = with sim.scheduler(2) in draws()
  assert d == (28871, 22289)
|};
  [%expect {|
    test.ren
      ✓ under one schedule
      ✓ under another

    2 passed
    [exit 0]
    |}]

(* ---- s7: `sim.net()` ---- *)

let%expect_test "[s7 accept] a test's network: a connection's bytes, both ways" =
  (* the client connects before anything listens, and waits; what's
     written is read once, up to `max` at a time; and once the other side
     has closed, a read gives nothing *)
  test ~seeds:200
    {|
import sim.{SimNet}

test fn here() -> Addr = Addr { host: "127.0.0.1", port: 80 }

test "there and back" =
  try Async.scope fn(s) =>
    s.spawn fn() =>
      match attempt SimNet.connect(here())
        Ok(c) =>
          match attempt Net.write(c, "ping".bytes())
            _ => ()
          match attempt Net.read(c, 10)
            Ok(b) => assert b == "pong".bytes()
            Err(_) => assert false
          Net.close(c)
        Err(_) => assert false
    let l = try Net.listen(here())
    let c = try Net.accept(l)
    assert try Net.read(c, 2) == "pi".bytes()
    assert try Net.read(c, 10) == "ng".bytes()
    try Net.write(c, "pong".bytes())
    assert try Net.read(c, 10) == "".bytes()
    Net.close(c)
|};
  [%expect {|
    test.ren
      ✓ there and back

    1 passed, each under 200 seeds
    [exit 0]
    |}]

let%expect_test "[s7 accept] how `sim.net()` fails" =
  test
    {|
import sim.{SimNet}

test fn here() -> Addr = Addr { host: "127.0.0.1", port: 80 }

test "a second listener at one address" =
  let _ = try Net.listen(here())
  assert attempt Net.listen(here()) == Err(InUse(here()))

test "a closed connection" =
  try Async.scope fn(s) =>
    s.spawn fn() =>
      match attempt SimNet.connect(here())
        Ok(c) => Net.close(c)
        Err(_) => ()
    let l = try Net.listen(here())
    let c = try Net.accept(l)
    assert try Net.read(c, 10) == "".bytes()
    assert attempt Net.write(c, "late".bytes()) == Err(Closed)
    Net.close(c)
    assert attempt Net.read(c, 10) == Err(Closed)

test "a read of nothing" =
  try Async.scope fn(s) =>
    s.spawn fn() =>
      match attempt SimNet.connect(here())
        Ok(c) => Net.close(c)
        Err(_) => ()
    let l = try Net.listen(here())
    let c = try Net.accept(l)
    assert attempt Net.read(c, 0) == Err(NetFailed("a read takes at least 1 byte, or it couldn't tell that from the end"))

test "a signal sent before `accept_until` waits is kept for it" =
  let l = try Net.listen(here())
  SimNet.signal(Signal.term)
  assert try Net.accept_until(l, Signal.term) == None
  assert try Net.accept_until(l, Signal.term) == None
  assert attempt SimNet.connect(here()) == Err(Refused(here()))
  assert attempt Net.accept(l) == Err(Closed)

test "another signal stops nothing" =
  let l = try Net.listen(here())
  SimNet.signal(Signal.interrupt)
  match Async.timeout(Duration.seconds(1)) fn() => attempt Net.accept_until(l, Signal.term)
    _ => assert false
    fail Timeout => assert Clock.now() == Time.epoch + Duration.seconds(1)
|};
  [%expect {|
    test.ren
      ✓ a second listener at one address
      ✓ a closed connection
      ✓ a read of nothing
      ✓ a signal sent before `accept_until` waits is kept for it
      ✓ another signal stops nothing

    5 passed
    [exit 0]
    |}]

let%expect_test "[s7 accept] a `finally` running at the cleanup deadline has one of its own" =
  (* the signal at 1 s: the connection is cancelled at 6 s, in its sleep,
     and its `with`'s `finally`, shielded, is cut off 5 s later, at 11 s *)
  test ~seeds:100
    {|
import sim.{SimNet}

test fn here() -> Addr = Addr { host: "127.0.0.1", port: 80 }

pub dep Tidy =
  nothing: fn()

pub handler tidy() for Tidy uses Clock =
  finally(r) =>
    Clock.sleep(Duration.minutes(1))
    try r
  nothing() => ()

test fn serve() ! NetError uses Net, Clock, Async =
  let l = try Net.listen(here())
  Async.scope fn(s) =>
    var open = true
    while open
      match attempt Net.accept_until(l, Signal.term)
        Ok(Some(_)) =>
          s.spawn fn() =>
            with tidy() in
              Clock.sleep(Duration.minutes(1))
        _ => open = false

test "the cleanup deadline" =
  try Async.scope fn(s) =>
    s.spawn fn() =>
      match attempt serve()
        _ => ()
    let _ = try SimNet.connect(here())
    Clock.sleep(Duration.seconds(1))
    SimNet.signal(Signal.term)
  assert Clock.now() == Time.epoch + Duration.seconds(11)
|};
  [%expect {|
    test.ren
      ✓ the cleanup deadline

    1 passed, each under 100 seeds
    [exit 0]
    |}]

(* ---- s8: the standard library ---- *)

let%expect_test "[s8 accept] a channel's send waits while it's full" =
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
|};
  [%expect {|
    1
    2
    ()
    |}]

let%expect_test "[s8 accept] a channel's items, from two senders, each once and in order" =
  (* a channel of 2 between two senders and a receiver: under every
     schedule, each item is received once, each sender's in the order it
     sent them, and `None` once it's closed and empty *)
  test ~seeds:200
    {|
import sync.{Chan}

pub dep Nums = Chan<Int>

test "what two senders send is received once each, in each one's order" =
  with sync.channel(2) as Nums in
    var got: Array<Int> = []
    Async.scope fn(s) =>
      s.spawn fn() =>
        Async.scope fn(t) =>
          t.spawn fn() =>
            for i in 0..5
              Nums.send(i)
          t.spawn fn() =>
            for i in 10..15
              Nums.send(i)
        Nums.close()
      var going = true
      while going
        match Nums.recv()
          Some(x) => &got.push(x)
          None => going = false
    assert got.len() == 10
    assert got.select(fn(x) => x < 10) == [0, 1, 2, 3, 4]
    assert got.select(fn(x) => x >= 10) == [10, 11, 12, 13, 14]
|};
  [%expect {|
    test.ren
      ✓ what two senders send is received once each, in each one's order

    1 passed, each under 200 seeds
    [exit 0]
    |}]

let%expect_test "[s8 accept] a send on a closed channel panics" =
  run_error
    {|
import sync.{Chan}

fn main() uses Console, Async =
  with sync.channel(1) in
    Chan.close()
    print(Chan.recv())
    Chan.send(1)
|};
  [%expect {|
    None
    error: panic: a send on a closed channel
      ┌─ test.ren:7:5
    7 │     Chan.send(1)
      │     ^^^^^^^^^^^^
    |}]

let%expect_test "[s8 accept] a semaphore and a limit: at most n calls at once" =
  (* a call that fails, and one that's cancelled while it runs, gives its
     permit back, since `limit` gives it back in a `finally` *)
  test ~seeds:300
    {|
import sync

pub dep Work =
  run: fn(n: Int) -> Int ! Bad(n: Int)

pub dep Gauge =
  enter: fn()
  leave: fn()
  most: fn() -> Int

test handler gauge() for Gauge =
  var now = 0
  var top = 0
  enter() =>
    now += 1
    if now > top then top = now
  leave() => now -= 1
  most() => top

// each call takes 10 ms, and an odd one fails
test handler slow() for Work uses Gauge, Clock =
  run(n) =>
    Gauge.enter()
    Clock.sleep(Duration.ms(10))
    Gauge.leave()
    if n % 2 == 1 then fail Bad(n)
    n

test "at most three calls at once, and a failure gives its permit back" =
  with gauge(), sync.semaphore(3), sync.limit() over slow() in
    Async.each([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) fn(n) =>
      match attempt Work.run(n)
        _ => ()
    assert Gauge.most() == 3
    assert Clock.now() == Time.epoch + Duration.ms(40)

test "a cancelled call gives its permit back" =
  with gauge(), sync.semaphore(1), sync.limit() over slow() in
    let r = attempt Async.timeout(Duration.ms(5)) fn() => try Work.run(2)
    assert r == Err(Timeout)
    assert try Work.run(4) == 4
|};
  [%expect {|
    test.ren
      ✓ at most three calls at once, and a failure gives its permit back
      ✓ a cancelled call gives its permit back

    2 passed, each under 300 seeds
    [exit 0]
    |}]

let%expect_test "[s8 accept] a semaphore of 0 permits panics when one's asked for" =
  run_error
    {|
import sync.{Semaphore}

fn main() uses Async =
  with sync.semaphore(0) in
    Semaphore.acquire()
|};
  [%expect {|
    error: panic: a semaphore has at least 1 permit, so it can give one
      ┌─ test.ren:5:5
    5 │     Semaphore.acquire()
      │     ^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s8 accept] a permit given back that wasn't taken panics" =
  run_error
    {|
import sync.{Semaphore}

fn main() uses Async =
  with sync.semaphore(1) in
    Semaphore.release()
|};
  [%expect {|
    error: panic: a semaphore's permit given back that wasn't taken
      ┌─ test.ren:5:5
    5 │     Semaphore.release()
      │     ^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s8 accept] a batcher fetches one round's keys in one call" =
  (* the flusher waits for a key, lets every task ask for theirs, and
     fetches them together; a key asked for again is answered from what
     was fetched; and one the fetch didn't give is a panic in the task
     that asked for it *)
  test ~seeds:300
    {|
import sync.{Batcher, Fetch}

pub dep Names = Batcher<Int, Str>

// what each fetch was asked for
pub dep Asked =
  saw: fn(keys: Array<Int>)
  all: fn() -> Array<Array<Int>>

test handler asked() for Asked =
  var calls: Array<Array<Int>> = []
  saw(keys) => &calls.push(keys)
  all() => calls

// the name of each number but 13, which it hasn't
test handler names() for Fetch<Int, Str> uses Asked =
  fetch(keys) =>
    Asked.saw(keys)
    var m: Map<Int, Str> = Map.empty
    for k in keys
      if k != 13 then &m.set(k, "n" + show(k))
    m

// the flusher, beside the body of the batcher's `with`
pub fn flushing() uses Names, Async =
  while true
    Names.asked()
    Async.tick()
    Names.flush()

test "what's asked for in one round is fetched in one call" =
  with asked(), names() in
    with sync.batcher() as Names in
      Async.beside(fn() => flushing()) fn() =>
        let got = Async.map([3, 1, 2, 1]) fn(k) => Names.get(k)
        assert got == ["n3", "n1", "n2", "n1"]
        assert Names.get(2) == "n2"
    // in the order the tasks asked, which the schedule decides
    assert Asked.all().len() == 1
    assert Asked.all()[0].sort() == [1, 2, 3]

test "a key the fetch doesn't give panics" =
  with asked(), names() in
    with sync.batcher() as Names in
      Async.beside(fn() => flushing()) fn() =>
        assert Names.get(13) == "n13"
|};
  [%expect {|
    test.ren
      ✓ what's asked for in one round is fetched in one call
      ✗ a key the fetch doesn't give panics

    ──── a key the fetch doesn't give panics ── test.ren:46
       │
    46 │         assert Names.get(13) == "n13"
       │                ^^^^^^^^^^^^^
       │
       panic: `Fetch.fetch` didn't give a value for a key it was asked for

       seed 7573 · rerun: ren test test.ren --only "a key" --seed 7573

    1 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "[s8 accept] `sim.proc()`: programs at once, and those cancelled while they ran" =
  test ~seeds:300
    {|
import sim.{Run, SimProc}

pub fn go(cmd: Str) ! Failed(cmd: Str) | ProcError uses Proc =
  let code = try Proc.run(cmd, [])
  if code != 0 then fail Failed(cmd)

test fn takes(cmd: Str, code: Int, s: Int) -> Run =
  Run { command: Command { cmd: cmd, args: [] }, code: code, takes: Duration.seconds(s) }

test "two programs at once take the longer one's time" =
  with sim.proc([takes("a", 0, 2), takes("b", 0, 3)]) in
    try Async.each(["a", "b", "c"]) fn(c) => try go(c)
    assert TestProc.ran().len() == 3
    assert SimProc.killed() == []
  assert Clock.now() == Time.epoch + Duration.seconds(3)

test "one that fails stops the other, which is killed" =
  with sim.proc([takes("a", 1, 2), takes("b", 0, 10)]) in
    let r = attempt Async.each(["a", "b"]) fn(c) => try go(c)
    assert r == Err(Failed("a"))
    assert TestProc.ran().len() == 2
    assert SimProc.killed() == [Command { cmd: "b", args: [] }]
  assert Clock.now() == Time.epoch + Duration.seconds(2)
|};
  [%expect {|
    test.ren
      ✓ two programs at once take the longer one's time
      ✓ one that fails stops the other, which is killed

    2 passed, each under 300 seeds
    [exit 0]
    |}]

let%expect_test "[s8 accept] what an arm's `finally` changes of the state, cancelled, is kept" =
  (* the arm's copies of the state are written back however it ends,
     cancelled too (lower.ml, [with_cells]) *)
  run
    {|
dep D =
  go: fn()
  seen: fn() -> Int

handler h() for D uses Async, Clock =
  var n = 0
  go() =>
    finally(out) =>
      match out
        Ok(_) => ()
        Err(_) => n += 1
    Clock.sleep(Duration.seconds(5))
  seen() => n

fn main() uses Console, Async, Clock =
  with h() in
    Async.scope fn(s) =>
      let t = s.start fn() => D.go()
      Clock.sleep(Duration.seconds(1))
      t.cancel()
    print(D.seen())
|};
  [%expect {|
    1
    ()
    |}]

let%expect_test "[s8 accept] a waiter cancelled in `Async.until` starts its `finally` from the state as it is" =
  (* both tasks push to the state; `y`, waiting, is cancelled when `x`
     fails, and its arm writes back its copies at its end: they're read
     again after its wait, however it ends, so `x`'s push isn't lost *)
  test ~seeds:300
    {|
pub dep Log =
  enter: fn(name: Str) ! Failed
  all: fn() -> Array<Str>

// `x` fails once both have entered; `y` waits for what never comes
test handler log() for Log uses Async =
  var names: Array<Str> = []
  enter(name) =>
    &names.push(name)
    if name == "x" then
      Async.until fn() => names.len() == 2
      fail Failed
    Async.until fn() => names.len() > 2
  all() => names

test "both entered" =
  with log() in
    let r = attempt Async.each(["x", "y"]) fn(n) =>
      Async.yield()
      try Log.enter(n)
    assert r == Err(Failed)
    assert Log.all().len() == 2
|};
  [%expect {|
    test.ren
      ✓ both entered

    1 passed, each under 300 seeds
    [exit 0]
    |}]

(* ---- s9: what the review found ---- *)

let%expect_test "[s9 reject] a task started in a scope that has ended" =
  (* a task of the outer scope captured the inner one in its body: once
     the inner scope has ended, nothing can start in it, or the new task
     would outlive it *)
  run_error
    {|
fn main() uses Console, Async, Clock =
  Async.scope fn(o) =>
    Async.scope fn(i) =>
      o.spawn fn() =>
        Clock.sleep(Duration.ms(10))
        i.spawn fn() => print("late")
    print("inner done")
  print("outer done")
|};
  [%expect {|
    inner done
    error: panic: a task is started in a scope that has ended
      ┌─ test.ren:6:9
    6 │         i.spawn fn() => print("late")
      │         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = in the task main/main:0
      = a task never outlives its scope, so nothing starts in one that has ended
      help: spawn it in a scope that's still running: the task's own, or one outside it
    |}]

let%expect_test "[s9 accept] a scope still waiting for its tasks takes more" =
  (* the inner scope's body has ended, but not its task, so a task of the
     outer scope can still start one in it, which it waits for too *)
  run
    {|
fn main() uses Console, Async, Clock =
  Async.scope fn(o) =>
    Async.scope fn(i) =>
      i.spawn fn() => Clock.sleep(Duration.ms(50))
      o.spawn fn() =>
        Clock.sleep(Duration.ms(10))
        i.spawn fn() => print("in time")
    print("inner done")
  print("outer done")
|};
  [%expect {|
    in time
    inner done
    outer done
    ()
    |}]

let%expect_test "[s9 accept] two tasks replacing one key at once leave one task under it" =
  (* each `replace` waits for the task it cancels; the one woken second
     finds the first's new task under the key, and cancels that too *)
  test ~seeds:300
    {|
pub dep Count =
  enter: fn()
  leave: fn()
  most: fn() -> Int

test handler count() for Count =
  var n = 0
  var m = 0
  enter() =>
    n += 1
    if n > m then m = n
  leave() => n -= 1
  most() => m

pub dep Inside =
  nothing: fn()

// counts the task in while it runs, and out however it ends
test handler inside() for Inside uses Count =
  let entered = Count.enter()
  finally(r) =>
    Count.leave()
    try r
  nothing() => ()

test fn work() uses Count, Clock =
  with inside() in
    Clock.sleep(Duration.ms(30))

test "one task under a key" =
  with count() in
    Async.scope fn(s) =>
      s.replace("k") fn() => work()
      Async.scope fn(t) =>
        t.spawn fn() => s.replace("k") fn() => work()
        t.spawn fn() => s.replace("k") fn() => work()
    assert Count.most() == 1
|};
  [%expect {|
    test.ren
      ✓ one task under a key

    1 passed, each under 300 seeds
    [exit 0]
    |}]

let%expect_test "[s9 reject] a block bound by `let` and passed to an operation calls back into it" =
  (* it's checked as one written at the call is: the operation holds its
     instance while it runs the block *)
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
    let g = fn(&x) => x = Tally.get() + 1
    Tally.change(g)
    print(Tally.get())
|};
  [%expect {|
    error: a block passed to `Tally.change` can't use `Tally`, which it would wait for while `Tally.change` runs it
       ┌─ test.ren:15:27
    15 │     let g = fn(&x) => x = Tally.get() + 1
       │                           ^^^^^^^^^^^
       = a block passed to an operation gets its dependencies only from its parameter's type
       help: call it before `Tally.change`, outside the block
    |}]

let%expect_test "[s9 reject] a block bound by `let` and passed to an operation uses what its type doesn't list" =
  (* `X.run` holds `X` while `g` waits for `Y`, which a task in `Y.poke`
     holds while it waits for `X`: refused, rather than the deadlock *)
  check_error
    {|
dep X =
  run: fn(f: fn())
  get: fn() -> Int
dep Y =
  poke: fn()

handler hx() for X =
  var n = 0
  run(f) =>
    f()
    n += 1
  get() => n

handler hy() for Y uses X =
  var seen = 0
  poke() => seen = X.get()

fn main() uses Async =
  with hx() in
    with hy() in
      let g = fn() => Y.poke()
      Async.scope fn(s) =>
        s.spawn fn() => X.run(g)
        s.spawn fn() => Y.poke()
|};
  [%expect {|
    error: a block passed to `X.run` can't use `Y`, which its parameter's type doesn't list
       ┌─ test.ren:21:23
    21 │       let g = fn() => Y.poke()
       │                       ^^^^^^^^
       = a block passed to an operation gets its dependencies only from its parameter's type
       help: list it in the parameter's type, `fn() uses Y`, or call it before `X.run`, outside the block
    |}]

let d_handler =
  {|
dep D =
  op: fn() -> Int

handler h() for D uses Console =
  var n = 0
  finally(r) =>
    print("h ends")
    try r
  op() =>
    n += 1
    n
|}

let%expect_test "[s9 reject] a task spawned outside a `with` by a task inside its body can't reach it" =
  (* the `with`'s body is main's, but the spawn into `o` is made by a task
     of `i`, and by a task of a task's: each is in the `with`'s body, and
     its block can reach `D`, so it could call `D.op` after `h`'s
     `finally` (decision 7). 11a cancelled them when the body ended *)
  check_error
    (d_handler
   ^ {|
fn main() uses Console, Async, Clock =
  Async.scope fn(o) =>
    with h() in
      Async.scope fn(i) =>
        i.spawn fn() =>
          o.spawn fn() =>
            Clock.sleep(Duration.ms(50))
            print(D.op())
          Async.scope fn(j) =>
            j.spawn fn() =>
              o.spawn fn() =>
                Clock.sleep(Duration.ms(50))
                print(D.op())
      print("with body done")
    print("with done")
  print("outer done")
|});
  [%expect {|
    error: this task can reach `D`, installed inside the scope it's spawned into
       ┌─ test.ren:18:11
    15 │     with h() in
       │     ----------- `D` is installed here, inside the scope
    18 │           o.spawn fn() =>
       │           ^^^^^^^
       help: open the scope inside the `with`: `with h() in Async.scope fn(o) => ...`, or run it beside the body with `Async.beside`

    error: this task can reach `D`, installed inside the scope it's spawned into
       ┌─ test.ren:23:15
    15 │     with h() in
       │     ----------- `D` is installed here, inside the scope
    23 │               o.spawn fn() =>
       │               ^^^^^^^
       help: open the scope inside the `with`: `with h() in Async.scope fn(o) => ...`, or run it beside the body with `Async.beside`
    |}]

let%expect_test "[s9 reject] a task's task spawned through helpers outside a `with` panics at the spawn" =
  (* the same spawns made by helpers that are handed `o`, which only the
     run time sees: the spawn is in the `with`'s body all the same, its
     spawner's spawner's, so it's refused there (Sched.inner's
     [context]) *)
  run_error
    (d_handler
   ^ {|
fn later(o: Scope) uses D, Clock, Console, Async =
  o.spawn fn() =>
    Clock.sleep(Duration.ms(50))
    print(D.op())

fn main() uses Console, Async, Clock =
  Async.scope fn(o) =>
    with h() in
      Async.scope fn(i) =>
        i.spawn fn() =>
          Async.scope fn(j) =>
            j.spawn fn() => later(o)
      print("with body done")
    print("with done")
  print("outer done")
|});
  [%expect {|
    error: panic: this task can reach `D`, installed inside the scope it's spawned into
       ┌─ test.ren:14:3
    14 │   o.spawn fn() =>
       │   ^^^^^^^^^^^^^^^
       = in the task main/main:0/main:0
       help: open the scope inside the `with`
    |}]

let%expect_test "[s9 accept] a task spawned outside a `with` that can't reach it outlives it" =
  (* what it can reach is installed outside the scope, so it may: the
     scope waits for it, after the `with` has ended *)
  run
    (d_handler
   ^ {|
fn later(o: Scope) uses Clock, Console, Async =
  o.spawn fn() =>
    Clock.sleep(Duration.ms(50))
    print("later")

fn main() uses Console, Async, Clock =
  Async.scope fn(o) =>
    with h() in
      Async.scope fn(i) =>
        i.spawn fn() => later(o)
      print("with body done")
    print("with done")
  print("outer done")
|});
  [%expect {|
    with body done
    h ends
    with done
    later
    outer done
    ()
    |}]

let%expect_test "[s9 reject] a task's task spawned outside a `with` it was spawned beside" =
  (* `sa`'s task could reach `D` through the task it spawns into `sc`,
     so its own spawn is refused; and so is that one *)
  check_error
    (d_handler
   ^ {|
fn main() uses Console, Async, Clock =
  Async.scope fn(sc) =>
    Async.scope fn(sa) =>
      with h() in
        sa.spawn fn() =>
          sc.spawn fn() =>
            Clock.sleep(Duration.ms(50))
            print(D.op())
        Clock.sleep(Duration.ms(10))
        print("with body done")
      print("with done")
  print("outer done")
|});
  [%expect {|
    error: this task can reach `D`, installed inside the scope it's spawned into
       ┌─ test.ren:17:9
    16 │       with h() in
       │       ----------- `D` is installed here, inside the scope
    17 │         sa.spawn fn() =>
       │         ^^^^^^^^
       help: open the scope inside the `with`: `with h() in Async.scope fn(sa) => ...`, or run it beside the body with `Async.beside`

    error: this task can reach `D`, installed inside the scope it's spawned into
       ┌─ test.ren:18:11
    16 │       with h() in
       │       ----------- `D` is installed here, inside the scope
    18 │           sc.spawn fn() =>
       │           ^^^^^^^^
       help: open the scope inside the `with`: `with h() in Async.scope fn(sc) => ...`, or run it beside the body with `Async.beside`
    |}]

let%expect_test "[s9 reject] a helper that spawns a task that spawns: refused at the first spawn" =
  run_error
    (d_handler
   ^ {|
fn start(sa: Scope, sc: Scope) uses D, Clock, Console, Async =
  sa.spawn fn() =>
    sc.spawn fn() =>
      Clock.sleep(Duration.ms(50))
      print(D.op())

fn main() uses Console, Async, Clock =
  Async.scope fn(sc) =>
    Async.scope fn(sa) =>
      with h() in
        start(sa, sc)
        Clock.sleep(Duration.ms(10))
        print("with body done")
      print("with done")
  print("outer done")
|});
  [%expect {|
    error: panic: this task can reach `D`, installed inside the scope it's spawned into
       ┌─ test.ren:14:3
    14 │   sa.spawn fn() =>
       │   ^^^^^^^^^^^^^^^^
       help: open the scope inside the `with`
    |}]

let%expect_test "[s9 reject] a wait that closes a cycle is a panic at once, though another task runs" =
  (* a block parameter passed on to an operation isn't checked by the
     no-deadlock rule: `via`'s task holds `X` and waits for `Y`, whose
     task waits for `X`. The third task keeps the run from being all
     waits, as a server's accept loop does, so the deadlock panic would
     never come; the wait that closes the cycle is the panic *)
  run_error
    {|
dep Y =
  poke: fn()

dep X =
  run: fn(f: fn())

handler xh() for X uses Clock =
  var n = 0
  run(f) =>
    n += 1
    Clock.sleep(Duration.ms(50))
    f()

handler yh() for Y uses X, Clock =
  var m = 0
  poke() =>
    m += 1
    Clock.sleep(Duration.ms(50))
    X.run(fn() => ())

fn via(f: fn()) uses X = X.run(f)

fn main() uses Console, Clock, Async =
  with xh() in
    with yh() in
      Async.scope fn(s) =>
        s.spawn fn() => via(fn() => Y.poke())
        s.spawn fn() => Y.poke()
        s.spawn fn() =>
          Clock.sleep(Duration.seconds(60))
          print("never")
|};
  [%expect {|
    error: panic: `X.run` would wait for a task that waits for this one, so neither could go on
       ┌─ test.ren:19:5
    19 │     X.run(fn() => ())
       │     ^^^^^^^^^^^^^^^^^
       = in the task main/main:1
       = main/main:1 waits for `X`, which another task is in, holding `Y` (yh.poke)
       = main/main:0 waits for `Y`, which another task is in at test.ren:27:37, holding `X` (xh.run)
       help: a block passed to an operation gets its dependencies only from its parameter's type: call it before the operation, outside the block
    |}]

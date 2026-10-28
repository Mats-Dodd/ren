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
    error: a parameter's default is a literal: a number, a `Bool` or a string
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
      help: spawn one beside the `with`, into an `Async.scope` outside it, that calls one of the handler's operations
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope(max: 1) fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
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
    error: `Cancelled` can't be matched here, because the body's errors aren't known
      ┌─ test.ren:7:11
    7 │       Err(Cancelled) => print("cancelled")
      │           ^^^^^^^^^
      = `finally` is given the body's error to pass on, not to look at: it could be whatever the body fails with
      help: match it with `Err(_)`, and pass it on with `try r`
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:19
    2 │   let r = attempt Async.scope fn(s) =>
      │                   ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
       ┌─ test.ren:12:3
    12 │   Async.scope fn(s) =>
       │   ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:4:3
    4 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope(max: 0) fn(s) => s.spawn fn() => print(1)
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
       ┌─ test.ren:12:5
    12 │     Async.scope fn(s) =>
       │     ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.timeout` isn't built yet: stage 11a, step 3
      ┌─ test.ren:2:19
    2 │   let r = attempt Async.timeout(Duration.ms(20)) fn() =>
      │                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.timeout` isn't built yet: stage 11a, step 3
       ┌─ test.ren:13:19
    13 │   let r = attempt Async.timeout(Duration.ms(20)) fn() =>
       │                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.timeout` isn't built yet: stage 11a, step 3
      ┌─ test.ren:3:19
    3 │   let r = attempt Async.timeout(Duration.ms(20)) fn() =>
      │                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.race` isn't built yet: stage 11a, step 3
      ┌─ test.ren:6:9
    6 │   print(Async.race(fn() => after(200, "slow"), fn() => after(5, "fast")))
      │         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.isolate` isn't built yet: stage 11a, step 3
      ┌─ test.ren:4:17
    4 │   print(attempt Async.isolate fn() => boom([1]))
      │                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.map` isn't built yet: stage 11a, step 3
      ┌─ test.ren:2:9
    2 │   print(Async.map([3, 1, 2]) fn(x) => x * 10)
      │         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: panic: `Async.each` isn't built yet: stage 11a, step 3
      ┌─ test.ren:2:3
    2 │   Async.each([1, 2]) fn(x) => print(x)
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
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
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
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
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
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
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
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
    error: this lambda produces an `Int`, but it has to produce a `Unit`
      ┌─ test.ren:2:31
    2 │   Async.each([1, 2]) fn(x) => x * 2
      │                               ^^^^^
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
    error: panic: `Async.until` isn't built yet: stage 11a, step 3
      ┌─ test.ren:5:13
    5 │   wait() => Async.until(fn() => false)
      │             ^^^^^^^^^^^^^^^^^^^^^^^^^^
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
    error: `main` doesn't declare `Clock`
       ┌─ test.ren:13:4
    13 │ fn main() uses Console, Async =
       │    ^^^^
    14 │   with slow_acct() in
       │        ----------- installing this needs `Clock`
       = `main`'s body can only use what its `uses` lists
       help: add `Clock` to its `uses`
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
    test.ren
      ✗ two tasks sleep at once
      ✗ tasks wake in the order of their deadlines

    ──── two tasks sleep at once ── test.ren:2
      │
    2 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
      │
      panic: `Async.scope` isn't built yet: stage 11a, step 2

      seed 2542 · rerun: ren test test.ren --only "two tasks" --seed 2542

    ──── tasks wake in the order of their deadlines ── test.ren:8
      │
    8 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
      │
      panic: `Async.scope` isn't built yet: stage 11a, step 2

      seed 9439 · rerun: ren test test.ren --only "tasks wake" --seed 9439

    0 passed, 2 failed
    [exit 1]
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
    error: there's no module `sim`
      ┌─ test.ren:1:8
    1 │ import sim
      │        ^^^
      = it would be the file `sim.ren`
      help: check the module's name, or create its file
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
    error: panic: `Async.scope` isn't built yet: stage 11a, step 2
      ┌─ test.ren:2:3
    2 │   Async.scope fn(s) =>
      │   ^^^^^^^^^^^^^^^^^^^^
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
    error: there's no module `sync`
      ┌─ test.ren:1:8
    1 │ import sync.{Chan}
      │        ^^^^
      = it would be the file `sync.ren`
      help: check the module's name, or create its file
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

# Concurrency

How a Ren program does several things at once: waiting on many calls,
running a server, working in the background, and computing on every core.
It's the stage after [handlers.md](handlers.md) on the
[roadmap](README.md#roadmap), and it builds on `with`, `over`, `next` and
`finally` from there. How the calls reach the kernel is in
[runtime-io.md](runtime-io.md).

Ren's concurrency is [Effect](https://effect.website/)'s, written in
direct style. `T ! E uses R` is already Effect's `Effect<A, E, R>`, so
there's nothing to wrap: no `async`, no `await`, no generators, and no
colored functions. Programs behave as if they run on one thread. Where
more threads help, the runtime adds them where no program can tell.

## What it has to do

1. **No task outlives the call that started it.** Concurrency is
   structured, so a function that returns has nothing still running.
2. **Shared state can't race.** There are no locks to forget and no data
   races, without giving up shared mutable state.
3. **Cancellation can't be swallowed, can't lose a result, and can't stop
   cleanup.** These are the three ways it breaks elsewhere.
4. **Everything has a limit.** Every way of starting tasks is bounded.
5. **A concurrent test gives the same answer every time,** and a failing
   interleaving replays exactly ([vision.md](vision.md)).

## The whole surface

```ren
Async.map(xs) fn(x) => ...                         // results, in order
Async.each(xs) fn(x) => ...                        // no results, each freed as it finishes
Async.both(fn() => a, fn() => b)                   // a pair
Async.timeout(d) fn() => ...                       // ! Timeout
Async.group(max: n, drain: d) fn(g) => g.spawn fn() => ...   // tasks started one at a time
with Async.limit(n) over Dep in                    // at most n calls to Dep at once
xs.par_map(f)                                      // f is pure: runs on every core
```

| | Results | A failure |
|---|---|---|
| `Async.map` | a list, in order | cancels the rest |
| `Async.each` | none | cancels the rest |
| `Async.both` | a pair | cancels the other |
| `Async.timeout` | the body's | `! Timeout`, and the body is cancelled |
| `Async.group` | none | tasks can't fail |
| `Async.limit(n) over Dep` | a handler, not a task | — |
| `xs.par_map` | a list, in order | cancels the rest |

`Async` is a dependency like `Clock`, and these are its operations, so a
signature says `uses Async` and the code says `Async.map`. The lambdas they
take are transparent ([README](README.md#3-functions)): their errors and
dependencies flow into the caller.

- **`map` and `each` run 64 at once by default,** and `max:` changes it.
- **`each`'s function returns `()`.** If it returns a value, that's an
  error whose help says `map`, so no result is thrown away without
  being written.
- **`group` must be given its `max`.** When it's full, `spawn` waits,
  which is backpressure for free.
- **A task in a `group` can't fail.** A group's tasks are independent,
  like a server's connections, and one connection's failure must not stop
  the others:

```
error: a task in a group can't fail, or one connection's failure would stop all the others
  ┌─ server.ren:7:15
  │
7 │       g.spawn fn() => try handle(conn)
  │                       ^^^^^^^^^^^^^^^^ can fail with BadRequest | DbDown
  │
  = help: handle them in the task: `match attempt handle(conn)`
```

- **`par_map` is parallelism, not concurrency.** Its function must be
  pure, so it gives the same answer on 1 core or 64. That's why it's an
  ordinary list method that needs no `uses Async`, and it works in a
  script or a test. Using a dependency in it is an error that points at
  the other word:

```
error: `par_map` runs its function on every core, so the function can't use deps
  ┌─ build.ren:12:30
  │
12│   files.par_map(fn(f) => { Clock.now(); sha256(f) })
  │                            ^^^^^^^^^^^ uses Clock
  │
  = help: to run tasks that use deps at the same time, use `Async.map`
```

- **`Async.limit(n) over Dep`** is a built-in handler that wraps any
  dependency, and makes each of its calls wait for one of `n` slots. It's
  built in because a handler can't make a caller wait for a slot, and it
  works over any dependency. A limit on each `map` doesn't bound the
  system (a `map` inside a `map` is 64 × 64), so the bound that matters
  belongs on the scarce thing: the connections, the requests per second,
  the database.

## The four rules

1. **No task outlives the call that started it.**
2. **A failure cancels the tasks beside it.** The first failure is the
   result. If another task fails for real while being cancelled, its
   error goes to the trace and the journal. It's never dropped silently,
   and it never joins the error type.
3. **A handler's state is touched by one task at a time between
   dependency calls.**
4. **Everything has a limit.**

### Shared state is a handler

Rule 3 makes every handler an actor. State that tasks share lives in a
handler, and reading it and updating it with no dependency call in
between is atomic:

```ren
dep Seen =
  claim: fn(url: Url) -> Bool        // true the first time a url is claimed

handler seen_set() for Seen =
  var seen: Set<Url> = Set.empty
  claim(url) =>
    if seen.includes(url) then false
    else
      &seen.add(url)
      true
```

Two tasks can't both claim the same URL, and there's no lock. Races
between tasks are still possible, but only at a dependency call, because
that's the only place another task can come in. Those are exactly the
points the test scheduler varies (below).

### State that changed during a call

That's Swift's actor reentrancy problem: state read before a dependency
call may have been changed by another task by the time the call returns.
Swift leaves it to the programmer. Ren's compiler sees every dependency
call in a handler, so it catches the pattern, where a value read before a
call is written back after it:

```
warning: `cache` may have changed during `next.save`
  ┌─ cache.ren:14:5
  │
12│     let old = cache.get(u.id)
  │               --------------- read here
13│     try next.save(u)
  │         ------------ another task can run here
14│     &cache.set(u.id, merge(old, u))
  │     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ and written here, from the old read
  │
  = help: read it again after the call
```

The test scheduler finds the same race at runtime. The warning finds it
before the code runs.

### Tasks always run concurrently

Tasks started together always run concurrently, never one after the
other. Zig separates code that *may* run concurrently from code that
*must*, because a producer and a consumer run one after the other
deadlock. Ren only has the second kind, and the test scheduler keeps the
guarantee too, so channels can be added later without a new kind of
task.

## Cancellation

Cancellation is where structured concurrency breaks in other languages,
and Ren has a rule for each way.

- **It happens at dependency calls.** A task that's cancelled stops at its
  next dependency call, and code after it doesn't run.
- **It can't be swallowed.** Cancellation isn't an error. `try`,
  `attempt` and `orelse` can't see it, and it's never in an error row.
  Kotlin's `runCatching` and Python's `except BaseException` catch it by
  accident, so a cancelled task keeps going. In Ren, only `finally` sees
  it, as `fail Cancelled`. When cancellation was the cause, what `finally`
  returns is thrown away, so cleanup can't turn a cancel into a success.
- **It never loses a result.** A dependency call that finished is never
  thrown away. A cancel that arrives as a read completes lands at the
  task's next call, so every operation is cancel-safe. In Rust,
  `select!` can drop a read whose data already arrived.
- **It never stops cleanup.** `finally` runs shielded, so its own
  dependency calls (a rollback) run even though the task was cancelled.
  It runs under a cleanup deadline, so cleanup can't hang forever. Trio
  calls this shielding and Kotlin calls it `NonCancellable`. In both you
  have to remember it, and in Ren it's always on.
- **It waits.** Cancelling a call waits until the kernel lets go of its
  buffer ([runtime-io.md](runtime-io.md#cancelling-waits-for-the-kernel)).
  Cancelling a `Proc.run` kills the program, then waits for it to exit,
  so a cancelled build never leaves processes behind.
- **A timeout never reports `Timeout` for work that finished.** Once the
  body has finished and its `finally` is running, the timeout waits for
  it and returns its result. Without that, a timeout during a commit
  would report `Timeout` for a transfer that happened, and the caller
  would retry it. A timeout can overrun by up to the cleanup deadline.
  It's late, but it never lies.
- **Deadlines carry down.** A timeout inside a timeout runs to the sooner
  of the two, and the deadline reaches every `Net` call made under it.
- **On `SIGTERM`, the runtime cancels `main`,** so shutting down is
  cancellation, and every `finally` runs.

## Tasks in handlers

A handler can run a task that lives exactly as long as the `with` that
installed it. It's how a cache refreshes, a pool checks its connections
and metrics are flushed:

```ren
pub handler batched(every: Duration) over Metrics uses Clock, Async =
  var pending: Array<Sample> = []
  record(s) => &pending.push(s)
  task =>
    loop
      Clock.sleep(every)
      let batch = pending
      pending = []
      try next.send(batch)
  finally(r) =>
    try next.send(pending)         // the task has stopped, so this is the last batch
    try r
```

**What happens, in order:**

1. **Setup:** the `var` lines run, and they may fail.
2. **Start:** the task starts once *every* item in the `with` has finished
   setup, and runs alongside the body.
3. **The body finishes, or fails:** the task is cancelled, and the `with`
   waits for it to stop.
4. **`finally(r)`** runs once the task has stopped, which is what makes
   the last flush above safe.

**The rules:**

- **A task that fails cancels the body** (rule 2: the task and the body
  are siblings), and `finally` sees the task's error. A lease keeper that
  loses its lease stops the work this way. A task that should carry on
  through failures says so with `attempt`.
- **A task that returns** just ends, and the body carries on.
- **Its errors and dependencies join the `with`'s,** like setup's. A
  handler with a task writes `Async` in its `uses`, because concurrency
  shows in a signature, as errors do.
- **It returns `()`,** reaches the implementation it's over through
  `next`, and holds the handler between its dependency calls, like an
  operation. Here, `record` can't run between `let batch = pending` and
  `pending = []`, so no sample is lost.
- **One task per handler.** Two things at once is `Async.both` inside it.
- **`task` is a contextual keyword.** It means a task only where an
  operation could go in a handler, so it stays usable as a name
  everywhere else. An operation is always written with parentheses, so a
  bare `task =>` can't be mistaken for one.

A loop that makes no dependency call would hold the handler forever:

```
error: this task never lets the handler's operations run
  ┌─ metrics.ren:6:5
  │
6 │     loop
  │     ^^^^ this loop makes no dep call
  │
  = an operation can only run while the task is waiting on a dep call
  = help: wait inside the loop, for example `Clock.sleep(every)`
```

`try r` is the short form of a `finally` that only cleans up: `r` is a
Result, and `try` passes its error on. It needs no new rule.

## Tests are deterministic

`ren test` runs every test on a deterministic scheduler with virtual time.

- **`Clock.sleep` advances virtual time instantly.** A test that sleeps
  for five minutes takes no real time.
- **The same test always interleaves the same way.** Tasks that wake at
  the same virtual moment wake in a fixed order, and every world
  dependency is a test one, so a concurrent test can't be flaky.
- **`ren test --seeds 1000`** runs each test under 1,000 different
  schedules. The scheduler changes the order only at dependency calls,
  the only places the order can matter. A failing seed is printed, and
  `ren test --seed 7412` replays it exactly.

This brings forward the first part of the simulation scheduler from stage
15. The rest of it (simulated networks and disks that fail, crashes, and
exploring every interleaving) stays there.

## Five programs

Each one tested a different part of the design. The rules above are what
they needed.

### A server that shuts down gracefully

```ren
pub fn serve(addr: Addr) ! NetError uses Net, Console, Async =
  let listener = try Net.listen(addr)
  Async.group(max: 10_000, drain: Duration.seconds(10)) fn(g) =>
    loop
      let conn = try listener.accept()
      g.spawn fn() =>
        match attempt handle(conn)
          Ok(_) => ()
          fail e => Console.error("request failed: " + show(e))

fn main() ! NetError uses Net, Console, Async =
  serve(Addr.parse("0.0.0.0:8080"))
```

- **Plain shutdown needs no code.** `SIGTERM` cancels `main`.
- **`drain:` makes it graceful.** A cancelled group first stops its own
  body (the accept loop), then lets its tasks run for up to `drain`, and
  only then cancels them.

```ren
test "shutdown lets a request in flight finish" =
  with sim_net([slow_request(Duration.seconds(3))]) in
    let r = attempt Async.timeout(Duration.seconds(1)) fn() => serve(addr)
    assert r == fail Timeout
    assert SimNet.responses_sent() == 1
    assert TestClock.elapsed() == Duration.seconds(3)
```

### A crawler

```ren
fn crawl(url: Url, depth: Int) -> Array<Page> uses Http, Seen, Async =
  if depth == 0 || not Seen.claim(url) then []
  else
    match attempt Http.get(url)
      fail _ => []
      Ok(page) =>
        let below = Async.map(page.links) fn(link) => crawl(link, depth - 1)
        var pages = [page]
        for p in below.flat_map(fn(ps) => ps)
          &pages.push(p)
        pages

fn main() uses Http, Console, Async =
  with seen_set(), Async.limit(16) over Http in
    let pages = crawl(Url.parse("https://example.com"), 3)
    print(pages.len())
```

- `Seen.claim` is atomic without a lock (rule 3).
- Skipping pages that fail is `attempt`, not a separate error policy.
- The map inside a map is bounded where it matters: 16 requests at once,
  however deep the crawl goes.

### The `just`, running independent recipes at once

```ren
fn run_all(plan: Array<Array<Recipe>>) ! ProcError | Failed uses Proc, Console, Async =
  for level in plan                    // each level depends only on earlier ones
    Async.each(level, max: Os.cpus()) fn(r) => try run(r)
```

```ren
test "a failing recipe stops the others" =
  with test_proc(["cc": exits(1, after: Duration.seconds(2)),
                  "fmt": exits(0, after: Duration.seconds(10))]) in
    let r = attempt run_all([[cc, fmt]])
    assert r == fail Failed("cc")
    assert TestProc.killed() == ["fmt"]
    assert TestClock.elapsed() == Duration.seconds(2)
```

Virtual time lets the test check when the cancellation happened, not just
that it did.

### A transfer under a timeout

```ren
fn transfer(t: Transfer) ! DbDown | Short | Timeout uses Sql, Async =
  Async.timeout(Duration.seconds(2)) fn() =>
    with transaction() over Sql in
      try debit(t.from, t.amount)
      try credit(t.to, t.amount)
```

- **A timeout during `credit`:** the query is cancelled, and `finally`
  sees `fail Cancelled` and rolls back, shielded. The result is `fail
  Timeout`, and nothing moved.
- **A timeout during `commit`:** the commit is in `finally`, so it
  finishes. The timeout waits for it and reports the transfer.

```ren
test "a timeout during commit still reports the commit" =
  with mem_sql(commit_takes: Duration.seconds(3)) in
    let r = attempt transfer(t)
    assert r == Ok(())
    assert MemSql.balance(t.to) == t.amount
```

A request that reached the database but whose answer was lost is a
different problem, and every language has it. The answer is an
idempotency key, the way TigerBeetle's transfers carry ids.

### Prices, refreshed in the background

```ren
pub handler refreshing(every: Duration) over Prices uses Clock, Async =
  var table = try next.all()
  task =>
    loop
      Clock.sleep(every)
      table = try next.all()
  get(item) => table.get(item)
```

```ren
test "a failed refresh stops the work" =
  with refreshing(Duration.minutes(1)) over flaky_prices(fail_after: 1) in
    let r = attempt { Clock.sleep(Duration.minutes(5)); Prices.get("tea") }
    assert r == fail PricesDown
```

`get` never sees a half-updated table: the swap has no dependency call in
it. A refresh that fails stops the program's work, because a cache that
can't refresh is serving data no one checked. Keeping the stale table
instead is `match attempt next.all()`.

## How it runs

- **One loop.** Every task is a fiber on one thread. That's Effect's
  model, and Node's, and what TigerBeetle does. It's what makes rule 3
  free and replay cheap: the journal records the order completions
  arrived, and nothing else is needed.
- **Preemption.** A long pure computation is paused at loop back-edges so
  it can't starve the other tasks. Effect's runtime does the same, yielding
  every 2,048 operations. If a task is paused partway through a handler
  operation, the handler stays busy until it resumes, so rule 3 holds.
  The task isn't waiting on anything but CPU time, so this can't
  deadlock. Pure code can't tell when it was paused, so programs can't
  tell either. It costs a check at each loop back-edge, about 1–2% in
  tight loops, as in Go.
- **`par_map` on every core.** Its pure function runs on worker threads.
  A value is marked as shared across threads when it's sent to one, and
  only marked values pay for atomic reference counts. Lean 4 does this.
- **A loop per core, later.** For the [2× bar](vision.md), servers will
  run a loop per core, each with its own ring and sockets. A handler
  lives on the loop that installed it, and a call to it from another core
  is a message to that loop. A dependency call is already a point where
  the task waits, so no program changes, and each loop replays from its
  own journal. That's Seastar's model.
- **A C call runs on a worker thread.** An `extern` function is assumed to
  block, the way a C library doing synchronous I/O does, so it runs on a
  worker and the loop carries on. `extern ... nonblocking` marks the fast
  ones, like `crc32`, which run inline. Go does this for cgo calls, and
  Loom's pinned virtual threads show what happens without it.
- **Errors and panics show the task path.** In Rust, JavaScript and
  Python, a stack trace from inside a task ends at the scheduler. Ren
  knows the task tree, so a failure shows how it was reached:
  `main → serve → group task 4812 → handle → Users.get`. `--trace` and
  the journal use the same path.
- **In the interpreter,** fibers use OCaml 5's effect handlers, through Eio
  as [runtime-io.md](runtime-io.md#the-primitive-layer) planned.

## Effect, translated

| Effect | Ren |
|---|---|
| `Effect.forEach(xs, f, { concurrency: 64 })` | `Async.map(xs) fn(x) => ...` |
| `Effect.forEach(..., { discard: true })` | `Async.each` |
| `Effect.all([a, b], { concurrency: 2 })` | `Async.both` |
| `Effect.timeout` | `Async.timeout` |
| `Effect.forkScoped`, `FiberSet` | `Async.group` |
| `Effect.makeSemaphore`, `withPermits` | `Async.limit(n) over Dep` |
| interruption, `onInterrupt`, `ensuring`, `acquireRelease` | `finally`, which sees `fail Cancelled` |
| `Layer.scoped` with `forkScoped` | a handler's `task` |
| `Ref`, `SynchronizedRef` | handler state |
| `Layer`, `provide` | `with`, `over` |
| `TestClock` | virtual time in every test |

Left out on purpose:

- **Fibers as values** (`fork`, `Fiber.join`). A task is never a value,
  for structured concurrency and the no-cycles invariant. `group` covers
  what they're used for.
- **Daemon fibers** (`forkDaemon`), which aren't structured.
- **Several variants of each operation.** Ren keeps one of each.

The rest is borrowed from elsewhere:

- **Trio:** structured concurrency's nurseries, and shielded cleanup.
- **Kotlin:** `SupervisorJob`, which is why group tasks are independent.
  Its swallowed `CancellationException` is the bug Ren rules out.
- **Java's `StructuredTaskScope`:** failure cancels the rest.
- **Go's `errgroup.SetLimit`:** bounded fan-out.
- **Rust's cancellation-safety problems:** the reason a finished call is
  never thrown away.
- **Seastar:** the loop per core.
- **Lean 4:** marking values shared across threads.
- **Zig's `std.Io`:** I/O chosen by `main` and passed down, which `uses`
  and `with` already do. Also the line between code that may run
  concurrently and code that must.
- **Koka:** async as a library on effect handlers, and effect
  polymorphism. `uses` is a color, but a polymorphic one, so `map` takes
  any lambda and libraries never split into sync and async.
- **Eio:** direct style on OCaml 5's effects, with switches as scopes.
  Its catchable `Cancelled` is another bug Ren rules out.

## Pitfalls elsewhere

| Language | Pitfall | Ren |
|---|---|---|
| JavaScript | colored functions; a floating promise; unhandled rejections; `AbortController` passed by hand; `Promise.all` unbounded | no colors; tasks aren't values; cancellation is automatic; `map` is bounded |
| Python | sync and async worlds; `create_task` collected if not held; `CancelledError` swallowed; a blocking call freezes the loop | no colors; tasks aren't values; cancellation can't be caught; C calls run on workers |
| Rust | colored; `Pin`; `'static` on spawn; cancellation safety; no async drop; competing runtimes | structured, so no `'static`; every call cancel-safe; `finally` makes calls; one runtime, and it's a handler |
| Go | goroutine leaks; `ctx` passed by hand; channel deadlocks; data races | structured; deadlines carry down; no channels yet; no data races |
| Kotlin | `CancellationException` swallowed; `GlobalScope` escapes | cancellation can't be caught; nothing escapes |
| Swift | actor reentrancy; the `Sendable` migration | the reentrancy warning; nothing like `Sendable` to write |
| Java | virtual threads pinned in `synchronized`; `ThreadLocal`'s cost | C calls run on workers; `with` is a scoped value |
| C# | `ConfigureAwait`; sync-over-async deadlocks | no colors |
| Erlang | unbounded mailboxes | everything has a limit |

Almost all of these come from five causes: colored functions, tasks as
values, cancellation as an exception that can be caught, queues with no
limit, and cleanup that can't wait. Ren has none of them.

## What changes elsewhere

- **The README:** `async.par_map` becomes `Async.map`, and
  `async.timeout` becomes `Async.timeout`.
- **[handlers.md](handlers.md):**
  - `finally` also runs when the body is cancelled, and sees `fail
    Cancelled`. It runs shielded, under a cleanup deadline.
  - A `with`'s errors include those of its handlers' tasks.
- **[runtime-io.md](runtime-io.md):** "Fibers and `Async` on the ring"
  now means this design.

## Done when

- The five programs above are in `examples/`, with their tests, and pass
  under `ren test` and `ren test --seeds 1000`.
- A test that sleeps for an hour of virtual time finishes in
  milliseconds.
- The `just` runs independent recipes at once, kills the rest when one
  fails, and records and replays byte for byte with `ren replay`.
- Each of the four errors above is a one-line refusal test, and the
  reentrancy warning catches the README's `cached` race.
- A failure inside a task shows its task path.

## Later

- **Streams for `each`.** Once lazy sequences exist ([operators.md](operators.md#deferred)),
  `Async.each(listener.connections(), max: 10_000)` pulls the next item
  only when a slot frees. That covers most servers, and leaves `group`
  for starting different kinds of tasks.
- **`race`,** for hedged reads, when a real program needs it.
- **Channels:** bounded, with a send that waits when full.
- **Restart policies,** like Erlang's supervisors. Until then, it's
  `attempt` or `retry` inside a task.
- **Per-core handlers** (`with per_core(cached(ttl)) over ...`), if a
  shared handler becomes a bottleneck across loops.
- **The rest of the simulation scheduler** (stage 17): failing networks
  and disks, crashes, and checking every interleaving.

## Open questions

- **How long is the cleanup deadline,** and can a `with` set its own?
- **What's `map`'s default limit?** 64 is a starting point, not a
  measurement.
- **Can the compiler tell a task loop that only calls pure code,**
  beyond the simple case of a `loop` with no dependency call?

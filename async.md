# Concurrency

How a Ren program does several things at once: waiting on many calls,
running a server, working in the background, and computing on every core.
It's stage 11a on the [roadmap](README.md#roadmap), and it builds on
`with`, `over`, `next` and `finally` from [handlers.md](handlers.md) and
on blocks from [foundations.md](foundations.md). How the calls reach the
kernel is in [runtime-io.md](runtime-io.md).

> **Status:** built in the interpreter, `ren run` and `ren test`, with
> the standard library's `sim` and `sync` (stage 11a, steps 1 to 8, reviewed in step 9); the
> sequential parts build natively too. This document follows
> foundations.md, decisions 2 and 7 to 11, which replaced the first
> version of this design ("What changed", below). What each step built
> is in [compiler.md](compiler.md#stage-11a).

Ren's concurrency is [Effect](https://effect.website/)'s, written in
direct style. `T ! E uses R` is already Effect's `Effect<A, E, R>`, so
there's nothing to wrap: no `async`, no `await`, no generators, and no
colored functions. Code is written as if it runs on one thread, and
where more threads help, the runtime adds them where no program can
tell.

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
Async.scope fn(s) => s.spawn fn() => ...          // tasks started one at a time
let t = s.start fn() => ...                       // and its handle: t.join(), t.cancel()
Async.scope(max: n) fn(s) => ...                  // spawn waits while n run
Async.map(xs) fn(x) => ...                         // results, in order
Async.each(xs) fn(x) => ...                        // no results
Async.produce(cap: n, fn() => ...) fn(items) => ... // a producer task; its sends are a stream
Async.both(fn() => a, fn() => b)                   // a pair
Async.race(fn() => a, fn() => b)                   // the first to finish
Async.timeout(d) fn() => ...                       // ! Timeout
Async.isolate fn() => ...                          // ! Panicked(msg)
Async.until(fn() => cond)                          // in an operation: wait for its state
Async.tick()                                       // let what can run, run
Async.yield()                                      // let others go first
with sync.semaphore(n), sync.limit() over Dep in   // at most n calls to Dep at once
```

| | Results | A failure |
|---|---|---|
| `Async.scope` | its body's | its tasks can't fail; the body's cancels them |
| `Async.map` | a list, in order | cancels the rest |
| `Async.each` | none | cancels the rest |
| `Async.both` | a pair | cancels the other |
| `Async.race` | the first to finish | its branches can't fail |
| `Async.timeout` | the body's | `! Timeout`, and the body is cancelled |
| `Async.isolate` | the body's | a panic becomes `! Panicked(msg)` |

`Async` is a dependency like `Clock`, so a signature says `uses Async`
and the code says `Async.map`. Its two operations are `yield` and
`tick`, and the rest are its functions, as `Fs.read_str` is one of
`Fs`'s. The blocks they take are transparent: their errors and
dependencies flow into the caller, and their dependencies are found
where they're written ([foundations.md](foundations.md#5-dependencies-are-found-where-a-block-is-written)).

- **A scope starts tasks one at a time.** `s.spawn` starts one, and
  `s.start` starts one and gives its handle, `t`, which can `t.join()`
  it, for what it returned, or `t.cancel()` it. `s.replace(key) fn() => ...` cancels the task already
  running under that key first, and waits for it: one refresh per user,
  say. Two tasks replacing one key at once still leave one task under
  it. A scope that has ended starts nothing: a task of an outer scope
  that captured it and spawns into it panics, since the new task would
  outlive it.
- **Everything is bounded.** `spawn` waits while `max` of the scope's
  tasks run, which is a server's backpressure, and `map` and `each` run
  `max` at once. The default is std's, 64 in their signatures, so a
  server writes `max: 10_000`.
- **`map` and `each` take any pull argument,** as `for` does: an
  array, a named cursor as `&r`, a pipeline or a generator. They pull
  the next item on the caller's task, only when a slot frees, so memory
  is bounded by `max`, and `map` keeps order: a finished result behind
  a slow head keeps its slot ([streams.md](streams.md#concurrency-and-time)).
- **`each`'s block returns `()`.** If it returns a value, that's an
  error whose help says `map`, so no result is thrown away without
  being written.
- **There's no `par_map`.** `Async.map` over a block that uses no
  dependencies may run on every core; it's the same call either way.
- **Wrappers are calls:** `Async.timeout(d) fn() => ...`, `Async.race`,
  and `retry(n, on: Tags)`. `with` installs only handlers.
- **A producer that needs a task runs in the consumer's scope.**
  `Async.produce(cap: Int = 16, f) fn(items) => ...` runs `f` on a task, which
  sends through a `Send<T>` dependency the call installs, not a channel
  value it holds (decision 5). `cap` is the backpressure. When the body
  ends, by finishing, `break` or a failure, the producer is cancelled
  and waited for. `Async.map_pull(src, max:, f) fn(results) => ...` has
  the same shape ([streams.md](streams.md#concurrency-and-time)).

## The rules

1. **No task outlives the call that started it.**
2. **A failure cancels the tasks beside it, and the first one wins.** If
   another task fails for real while being cancelled, its error goes to
   stderr and the journal. It's never dropped silently, and it never
   joins the error type.
3. **A handler's state is touched by one operation at a time,** until it
   returns or waits in `Async.until`.
4. **Everything has a limit.**

### A spawned task can't fail

A scope's tasks are independent, like a server's connections, and one
connection's failure must not stop the others. So a task's block can't
fail with an error, and handles what it can fail with itself:

```
error: a spawned task can't fail, or one task's failure would stop all the others
  ┌─ server.ren:7:15
  │
7 │       s.spawn fn() => try handle(conn)
  │                       ^^^^^^^^^^^^^^^^ can fail with BadRequest | DbDown
  │
  = help: handle them in the task: `match attempt handle(conn)`
```

`race`'s branches can't fail either, so the first to finish is the first
to succeed, and a branch that fails can't leave the race waiting on the
other: a server's `race(read_request, wait_for_shutdown)` would hold a
closed connection until shutdown. A branch that can fail is an error
whose help says to write `attempt` inside it; retrying until one
succeeds is `retry`'s job.

### What a task can touch

Tasks share mutable state only through handlers, and a block a task
runs only reads what it captures (foundations.md, decision 2):

- **A block passed to `s.spawn` reads what it captures until the scope
  ends,** so a variable it reads can't change meanwhile:

  ```
  error: `n` can't change while a spawned task reads it
     │ s.spawn fn() => log(n)
     │                     - read until `Async.scope` ends
     │ n += 1
     │ ^^^^^^
     help: copy it for the task, `let m = n`, or change it after the scope
  ```

- **It captures by reference only the variables of the frame that
  called `Async.scope`.** The rest are copied when it's spawned: a
  loop's variable inside the scope, a helper's locals. So `for conn in
  ...` gives each task its own `conn`.
- **A block passed to `map`, `each`, `both` or `race` runs on several
  tasks at once,** so it reads what it captures and changes nothing; it
  gives back what it makes instead.
- **A parameter's mode is part of its type.** A function that passes a
  block parameter on to `Async.map` marks it, `f: concurrent fn(T) ->
  U`, and one that spawns it, `body: spawned fn()`. A public signature
  says it; a private one is inferred.
- **A scope and a task's handle are blocks too.** They're passed and
  used, never stored or returned, so nothing can reach a task after its
  scope.

### Shared state is a handler

Rule 3 makes every handler an actor. State that tasks share lives in a
handler, and **an operation keeps its instance until it returns**, across
its own calls to handlers installed outside it. Another task that calls
it meanwhile waits its turn:

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

Two tasks can't both claim the same URL, and there's no lock to write.
**State read before a dependency call is still the state after it,** so
an invariant that spans the call needs no flag:

```ren
handler cached(ttl: Duration) over Users uses Clock =
  var cache: Map<UserId, (User, Time)> = Map.empty
  save(u) =>
    &cache.remove(u.id)
    try next.save(u)        // no other operation of `cached` runs meanwhile
```

Races between tasks are still possible, but only **between
operations**: a task that reads with one operation, lets another task
run, and writes with a second has lost the other's update. The fix is
one operation that does both, and the test scheduler finds the bug
(below):

```ren
dep Account =
  balance: fn() -> Int
  set: fn(b: Int)
  add: fn(n: Int)          // the fix: read and write in one operation

fn deposit(n: Int) uses Account =
  let b = Account.balance()
  Account.set(b + n)       // another task's deposit can come in between
```

- **What it costs:** one slow call, an fsync, serializes that handler's
  operations. A handler that wants its calls to overlap splits an
  operation in two, "reserve" and "complete", as `sync.semaphore`'s
  `acquire` and `release` are.
- **No deadlock waiting for an instance.** An operation can only call
  handlers installed outside it, so a task takes instances inner to
  outer and waits for instances can't form a cycle. Waits of other
  kinds, `Async.until` or a channel inside an operation, can
  (foundations.md, decision 10). A block passed to an operation gets its dependencies only from
  its parameter's type, so it can't call back into the instance running
  it.
- **The exclusion is skipped where nothing can race.** An instance no
  spawned task can reach, or whose handler keeps no state, takes no
  lock, so a program with no tasks pays nothing.

### Waiting for state: `Async.until`

**`Async.until(cond)` is the one way to wait,** written in an
operation. The condition reads only the handler's state. If it doesn't
hold, the operation lets go of the instance and waits, and the condition
is checked again each time the instance is released; the runtime
resumes the first waiter whose condition holds. No wakeup can be lost,
and there's no `if` where a `while` belongs. The condition is a block
written in the call; it uses no dependency, and can't fail, since it's
checked where the instance is released, by whichever task releases it:

```ren
pub handler channel<T>(cap: Int) for Chan<T> uses Async =
  var items: Array<T> = []
  var closed = false
  send(x) =>
    Async.until fn() => closed || items.len() < cap
    if closed then lib_panic("a send on a closed channel")
    &items.push(x)
  recv() =>
    Async.until fn() => closed || items.len() > 0
    if items.len() == 0 then None
    else
      let x = items[0]
      items = items.drop(1)
      Some(x)
  close() => closed = true
```

`Async.tick()` returns once every task that could run when it was called
has run until it waits. That's the batching point: a batcher's `get`
adds its key and waits until it's been fetched, and a task beside it
waits for a key to be asked for, `Batcher.asked()`, then ticks, then
calls `Batcher.flush()`, so every key asked for in one round goes in
one fetch.

### What tasks share: `sync`

The standard library's `sync`, found by `import sync`, is written in Ren
over `Async.until`, but for `keyed`:

| | What it is |
|---|---|
| `sync.channel(cap)` for `Chan<T>` | `send` waits while it's full, `recv` while it's empty and open, `None` once it's closed and empty; a send on a closed channel panics. A channel is a dependency, `dep Events = Chan<Event>`, and `Events.items()` is an ordinary function of `Chan<T>` in `sync`, as `Fs.read_str` is a function of `Fs`: a cursor whose `next` is `recv` |
| `sync.semaphore(n)` for `Semaphore` | `acquire` waits while no permit is free, `release` gives one back |
| `sync.limit() over any` | each call takes a permit of the `Semaphore` outside it, is passed on, and gives it back in a `finally`, however it ends |
| `sync.batcher()` for `Batcher<K, V>` | `get(k)` waits until a `flush` has fetched `k` through the `Fetch<K, V>` outside it, with every key asked for since the last |
| `sync.keyed(n, h)` | `n` instances of the handler `h` describes, each call sent to one by its first argument's key: calls on keys in different instances overlap |

```ren
with sync.semaphore(16), sync.limit() over Web in crawl(root, 3)

Async.scope fn(s) =>
  with sync.batcher() as Users in
    s.spawn fn() =>
      while true
        Users.asked()
        Async.tick()
        Users.flush()
    serve()
```

`limit` keeps no state, so it takes no lock; the semaphore's `acquire`
is what waits, in `Async.until`, which lets go of the semaphore
meanwhile. That's why it's two items: an operation keeps its instance
across its own `call.forward()`, so a `limit(n)` that counted in its own
state would let one call through at a time.

## Cancellation

Cancellation is where structured concurrency breaks in other languages,
and Ren has a rule for each way.

- **It happens at dependency calls.** A task that's cancelled stops at its
  next dependency call, and code after it doesn't run; a task waiting
  stops waiting. A task cancelled before it starts never runs.
- **It can't be swallowed.** Cancellation isn't an error. `try`,
  `attempt` and `orelse` can't see it, and it's never in an error row.
  Kotlin's `runCatching` and Python's `except BaseException` catch it by
  accident, so a cancelled task keeps going. In Ren, only `finally` sees
  it, as `Err(Cancelled)`. When cancellation was the cause, what `finally`
  returns is thrown away, so cleanup can't turn a cancel into a success.
- **It never loses a result.** A dependency call that finished is never
  thrown away. A cancel that arrives as a read completes lands at the
  task's next call, so every operation is cancel-safe. In Rust,
  `select!` can drop a read whose data already arrived.
- **It never stops cleanup.** `finally` runs shielded, so its own
  dependency calls (a rollback) run even though the task was cancelled.
  It runs under a cleanup deadline, 5 seconds, so cleanup can't hang
  forever. Trio calls this shielding and Kotlin calls it
  `NonCancellable`. In both you have to remember it, and in Ren it's
  always on.
- **A `finally` covers everything after the point it's written,**
  inside an operation too, so a cancelled caller gives back what it took.
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
- **On `SIGTERM`,** a server waiting in `Net.accept_until(l,
  Signal.term)` stops accepting, and what's in flight has the cleanup
  deadline to finish. A program that waits for no signal has `main`
  cancelled, so plain shutdown is cancellation, and every `finally` runs.

## A panic ends the program

Unless it's inside `Async.isolate fn() => ...`, which gives
`Err(Panicked(msg))` to an `attempt`. Isolation applies only when no
handler installed outside the block was in the middle of an operation;
otherwise the program still ends, since that handler's state is
half-changed. When a panic is contained, the `finally`s of handlers
installed inside the block run, given `Err(Cancelled)`, and the tasks
of scopes inside it are cancelled and waited for. An isolated block
can't change a variable from outside it: it returns its result, and
anything else it changes, it changes through an operation, so nothing
it wrote after the fault can be seen. For the same reason it's written
where it's isolated, and can't call a block it was given, which could
change its caller's variables. (A panic in a task spawned inside it
still ends the program, for now.)

## Background work is a task beside the `with`

A handler has no task of its own. A cache's refresh, a pool's checks
and a metrics flush are a task spawned beside the `with`: in its body,
into a scope outside it, calling one of the handler's operations. **When
the body ends, the `with` cancels the tasks that can reach its handler
and were spawned into a scope outside it, and waits for them,** before
its `finally` runs. So the task lives exactly as long as the `with`,
and never calls a handler that's gone:

```ren
pub dep Metrics =
  record: fn(s: Sample)
  flush: fn()

pub handler batched() for Metrics uses Exporter =
  var pending: Array<Sample> = []
  finally(r) =>
    Exporter.send(pending)     // the flusher has stopped, so this is the last batch
    try r
  record(s) => &pending.push(s)
  flush() =>
    Exporter.send(pending)     // `record` can't run while this does
    pending = []

fn serve_with_metrics() uses Exporter, Clock, Async =
  Async.scope fn(s) =>
    with batched() in
      s.spawn fn() =>
        while true
          Clock.sleep(Duration.seconds(10))
          Metrics.flush()
      serve()
```

**What happens, in order:** the `with` installs the handler; its body
starts the flusher in the scope outside, beside the rest of the body;
when `serve` returns, the `with` cancels the flusher, which stops at its
next call, and waits for it; then its `finally` sends what's left, and
the scope ends. A `flush` holds the instance until it returns, so no
sample is lost between `Exporter.send(pending)` and `pending = []`.
A task spawned into the scope from outside any `with`, as a server's
connections are, isn't cancelled when the scope's body ends: the scope
waits for it. It's the same for a spawn made by a task of a scope inside
the `with`'s body, or by that task's tasks: their spawn is in the body
too, so what they spawn into a scope outside it, able to reach the
handler, is cancelled with the rest.

## Tests are deterministic

`ren test` runs every test on `sim`, a deterministic scheduler with
virtual time; `ren run` runs `main` on `Async.single()`, one thread, in
real time.

- **The runtime is a handler,** installed with `with` as any other:
  `with Async.single() in run()`, `with sim.scheduler(seed) in
  serve()`. The runtime installs one around `main` and each test, so
  programs rarely write it.
- **`Clock.sleep` advances virtual time instantly.** A test that sleeps
  for an hour takes no real time, and tasks that sleep wake in the order
  of their deadlines.
- **The same test always interleaves the same way.** The scheduler
  chooses which task runs next from a tape seeded by the test's seed,
  and every world dependency is a test one, so a concurrent test can't
  be flaky.
- **`ren test --seeds 1000`** runs each test under 1,000 different
  schedules. The scheduler changes the order only at dependency calls
  on shared state and where tasks wait, the only places the order can
  matter. A failing seed is printed, and `ren test --seed 7412` replays
  it exactly.

```
$ ren test --seeds 200
main.ren
  ✗ two deposits both land
...
   left:  10
   right: 20
...
   seed 3815 · rerun: ren test . --only "two deposits" --seed 3815
```

A test that passes under all of them is counted so: `4 passed, each
under 1000 seeds`. `sim` is the standard library's module, found by
`import sim`: `sim.scheduler(seed)` is the runtime, and `sim.clock()`
the clock in its virtual time, which `ren test` installs for `Clock`;
`sim.net()` is a network in memory, which it installs for `Net`; and
`sim.proc(runs)` is programs that take virtual time, each its `Run`'s
`takes`, two tasks' at once, with `SimProc.killed()` the ones cancelled
while they ran.

This brings forward the first part of the simulation scheduler from stage
15. The rest of it (simulated networks and disks that fail, crashes, and
exploring every interleaving) stays there.

## Five programs

Each one tested a different part of the design. The rules above are what
they needed. Each is in `examples/`, with its tests, which pass under
`ren test --seeds 1000`: [examples/server](examples/server),
[examples/crawler](examples/crawler), [examples/just](examples/just),
[examples/transfer](examples/transfer) and
[examples/refresh](examples/refresh); [examples/net.t](examples/net.t)
runs a server on the real `Net` and sends it SIGTERM.

### A server that shuts down gracefully

```ren
pub fn serve(addr: Addr) ! NetError uses Net, Console, Async =
  let listener = try Net.listen(addr)
  try Async.scope(max: 10_000) fn(s) =>
    var open = true
    while open
      match try Net.accept_until(listener, Signal.term)
        Some(conn) =>
          s.spawn fn() =>
            match attempt handle(conn)
              Ok(_) => ()
              Err(_) => Console.error("request failed")
        None => open = false
```

- **Shutting down is the loop's end.** `accept_until` gives `None` once
  `SIGTERM` comes, the loop ends, and the scope waits for the
  connections in flight. They have the cleanup deadline to finish, and
  are cancelled after it.
- **One connection's failure is its own.** A spawned task can't fail,
  so `handle`'s errors are handled in the task.

```ren
// `here()` is the address the test's server listens on, and
// `run_server()` runs `serve` there, handling what it fails with
test "shutdown lets a request in flight finish" =
  with sim.net() in
    try Async.scope fn(s) =>
      s.spawn fn() => run_server()
      let c = try SimNet.connect(here())
      try Net.write(c, "slow".bytes())
      Clock.sleep(Duration.seconds(1))
      SimNet.signal(Signal.term)
      assert try Net.read(c, 100) == "done".bytes()
      assert Clock.now() == Time.epoch + Duration.seconds(3)
```

### A crawler

```ren
fn crawl(url: Str, depth: Int) -> Array<Page> uses Web, Seen, Async =
  if depth == 0 || not Seen.claim(url) then []
  else
    match attempt Web.get(url)
      Err(_) => []
      Ok(page) =>
        let below = Async.map(page.links) fn(link) => crawl(link, depth - 1)
        var pages = [page]
        for p in below.flat_map(fn(ps) => ps)
          &pages.push(p)
        pages

fn crawl_site(root: Str) -> Int uses Web, Async =
  with seen_set(), sync.semaphore(16), sync.limit() over Web in
    crawl(root, 3).len()
```

- `Seen.claim` is atomic without a lock (rule 3).
- Skipping pages that fail is `attempt`, not a separate error policy.
- The map inside a map is bounded where it matters: 16 requests at once,
  however deep the crawl goes. `limit` is an `over any` handler with no
  state, so it takes no lock, over a semaphore whose `acquire` waits in
  `Async.until`.

### The `just`, running independent recipes at once

```ren
fn run_all(plan: Array<Array<Recipe>>) ! ProcError | Failed uses Proc, Console, Async =
  for level in plan                    // each level depends only on earlier ones
    try Async.each(level, max: 8) fn(r) => try run(r)
```

```ren
test "a failing recipe stops the others" =
  with sim.proc([Run { command: cc, code: 1, takes: Duration.seconds(2) },
                 Run { command: fmt, code: 0, takes: Duration.seconds(10) }]) in
    let r = attempt run_all([[recipe("cc"), recipe("fmt")]])
    assert r == Err(Failed("cc"))
    assert SimProc.killed() == [fmt]
    assert Clock.now() == Time.epoch + Duration.seconds(2)
```

Virtual time lets the test check when the cancellation happened, not just
that it did. It runs, with its tests, in [examples/just](examples/just):
`plan.levels` puts each recipe in the level after its dependencies',
and the real `Proc.run` waits for its program as a task waits, so a
level's programs run at once. Cancelling one kills its program, SIGTERM
and then SIGKILL after the cleanup deadline, and waits for it to exit.
[examples/just.t](examples/just.t) runs it on a real justfile, and
records and replays a run of recipes at once, byte for byte.

### A transfer under a timeout

```ren
fn transfer(t: Transfer) ! DbDown | Short | Timeout uses Sql, Async =
  try Async.timeout(Duration.seconds(2)) fn() =>
    try with transaction() over Sql in
      try debit(t.from, t.amount)
      try credit(t.to, t.amount)
```

- **A timeout during `credit`:** the query is cancelled, and `finally`
  sees `Err(Cancelled)` and rolls back, shielded. The result is `fail
  Timeout`, and nothing moved.
- **A timeout during `commit`:** the commit is in `finally`, so it
  finishes. The timeout waits for it and reports the transfer.
- **`try with`:** the transaction's setup, `begin`, and its commit can
  fail, so its `with` is marked as any call that can fail is.

```ren
test "a timeout during commit still reports the commit" =
  with mem_sql(commit_takes: Duration.seconds(3)) in
    let r = attempt transfer(t)
    assert r == Ok(())
    assert try balance(t.to) == t.amount
```

It runs, with its tests, in [examples/transfer](examples/transfer).

A request that reached the database but whose answer was lost is a
different problem, and every language has it. The answer is an
idempotency key, the way TigerBeetle's transfers carry ids.

### Prices, refreshed in the background

```ren
pub dep Prices =
  get: fn(item: Str) -> Option<Int>
  refresh: fn() ! PricesDown

pub handler refreshing() for Prices ! PricesDown uses Supplier =
  var table = try Supplier.all()
  get(item) => table.get(item)
  refresh() => table = try Supplier.all()

fn shop() ! PricesDown uses Supplier, Clock, Async =
  Async.scope fn(s) =>
    try with refreshing() in
      s.spawn fn() =>
        while true
          Clock.sleep(Duration.minutes(1))
          match attempt Prices.refresh()
            Ok(_) => ()
            Err(_) => ()       // keep the table we have
      serve_customers()
```

`get` never sees a half-updated table: `refresh` holds the instance
while it asks the supplier and swaps the table in. The refresher is a
task beside the `with`, so it stops when the shop's work is done. A
refresh that fails keeps the stale table here; one that should stop the
shop would make the failure the body's, say through an operation the
body waits on. It runs, with its tests, in
[examples/refresh](examples/refresh).

## How it runs

- **One scheduler a run, and the runtime is its policy.** Every task is
  a fiber. `single` runs one thread in real time, first come first
  served; `sim` runs virtual time, choosing from a seeded tape;
  `work_stealing` and `per_core` come with many cores (stage 11b). The
  rules don't change with the runtime, only the cost, so code runs
  unchanged on any.
- **No preemption.** A task runs until it waits. A long computation
  holds its thread; on many cores the others carry on.
- **Errors and panics show the task path.** In Rust, JavaScript and
  Python, a stack trace from inside a task ends at the scheduler. Ren
  knows the task tree, so a failure says which task it was in:
  `main/serve:4812/handle:0`, the label of each spawn site and its
  ordinal. `--trace` and the journal use the same path, so a journal
  survives edits that move lines.
- **The journal names the task of each call,** and records each poll
  that brought completions, so a run on `single` replays exactly. A
  journal as a test follows its recorded order while it can, then the
  seeded tape takes over ([handlers.md](handlers.md#the-journal)).
- **Many cores, later.** Values a task shares are marked shared and
  counted atomically from then on; data for every core is built in an
  arena; reads that take no lock are `Mem.snapshot`
  ([foundations.md](foundations.md#10-many-cores)).
- **In the interpreter,** fibers are OCaml 5's effect continuations, and
  the scheduler is the interpreter's own.

## Effect, translated

| Effect | Ren |
|---|---|
| `Effect.forEach(xs, f, { concurrency: 64 })` | `Async.map(xs) fn(x) => ...` |
| `Effect.forEach(..., { discard: true })` | `Async.each` |
| `Effect.all([a, b], { concurrency: 2 })` | `Async.both` |
| `Effect.race` | `Async.race`, whose branches can't fail |
| `Effect.timeout` | `Async.timeout` |
| `Effect.forkScoped`, `FiberSet` | `Async.scope` and `s.spawn` |
| `Effect.makeSemaphore`, `withPermits` | `sync.semaphore(n)`, `sync.limit() over Dep` |
| `Queue.bounded` | `sync.channel(n)` |
| interruption, `onInterrupt`, `ensuring`, `acquireRelease` | `finally`, which sees `Err(Cancelled)` |
| `Layer.scoped` with `forkScoped` | a task spawned beside the `with` |
| `Ref`, `SynchronizedRef` | handler state |
| `Layer`, `provide` | `with`, `over` |
| `TestClock` | virtual time in every test |

Left out on purpose:

- **Fibers as values** (`fork`, `Fiber.join`). A task's handle is a
  block: it's used inside its scope and never kept, for structured
  concurrency and the no-cycles invariant.
- **Daemon fibers** (`forkDaemon`), which aren't structured.
- **Several variants of each operation.** Ren keeps one of each.

The rest is borrowed from elsewhere:

- **Trio:** structured concurrency's nurseries, and shielded cleanup.
- **Kotlin:** `SupervisorJob`, which is why a scope's tasks are
  independent. Its swallowed `CancellationException` is the bug Ren
  rules out.
- **Java's `StructuredTaskScope`:** failure cancels the rest.
- **Go's `errgroup.SetLimit`:** bounded fan-out.
- **Rust's cancellation-safety problems:** the reason a finished call is
  never thrown away.
- **Swift's actors,** as what not to do: letting other operations in at
  every call made actor code read like JavaScript `async` code, with bugs
  the source doesn't show.
- **Zig's `std.Io`:** I/O chosen by `main` and passed down, which `uses`
  and `with` already do.
- **Koka:** async as a library on effect handlers, and effect
  polymorphism. `uses` is a color, but a polymorphic one, so `map` takes
  any block and libraries never split into sync and async.
- **Eio:** direct style on OCaml 5's effects, with switches as scopes.
  Its catchable `Cancelled` is another bug Ren rules out.
- **FoundationDB and TigerBeetle:** deterministic simulation.

## Pitfalls elsewhere

| Language | Pitfall | Ren |
|---|---|---|
| JavaScript | colored functions; a floating promise; unhandled rejections; `AbortController` passed by hand; `Promise.all` unbounded | no colors; tasks aren't values; cancellation is automatic; `map` is bounded |
| Python | sync and async worlds; `create_task` collected if not held; `CancelledError` swallowed; a blocking call freezes the loop | no colors; tasks aren't values; cancellation can't be caught |
| Rust | colored; `Pin`; `'static` on spawn; cancellation safety; no async drop; competing runtimes | structured, so no `'static`; every call cancel-safe; `finally` makes calls; one runtime, and it's a handler |
| Go | goroutine leaks; `ctx` passed by hand; channel deadlocks; data races | structured; deadlines carry down; a deadlock is a panic that names each waiting task; no data races |
| Kotlin | `CancellationException` swallowed; `GlobalScope` escapes | cancellation can't be caught; nothing escapes |
| Swift | actor reentrancy; the `Sendable` migration | operations don't interleave; nothing like `Sendable` to write |
| Java | virtual threads pinned in `synchronized`; `ThreadLocal`'s cost | no locks to hold; `with` is a scoped value |
| C# | `ConfigureAwait`; sync-over-async deadlocks | no colors |
| Erlang | unbounded mailboxes | everything has a limit |

Almost all of these come from five causes: colored functions, tasks as
values, cancellation as an exception that can be caught, queues with no
limit, and cleanup that can't wait. Ren has none of them.

## What changed

This document was first written before foundations.md, which changed it
(foundations.md, "What it reverses"):

- **`Async.group(max:, drain:)` is `Async.scope(max:)`,** and a drain is
  the cleanup deadline after `accept_until` stops.
- **A handler has no task of its own.** `task =>` in a handler is gone;
  background work is a task spawned beside the `with`, into a scope
  outside it, which the `with` cancels when its body ends.
- **Operations don't interleave.** Another task's operation could once
  run on a handler at each dependency call, and a warning caught state
  read before a call and written after it. Now an operation keeps its
  instance until it returns or waits in `Async.until`, so that warning,
  and the README's `cached` race it caught, are gone.
- **`Async.limit(n) over Dep` is `sync.limit()` over a
  `sync.semaphore(n)`,** in Ren.
- **No `par_map`, and no preemption.**
- **`race` exists, and its branches can't fail.** `retry` takes the
  errors it retries, `retry(n, on: DbDown)`.
- **A `with` whose setup or `finally` can fail is `try with`.**
- **The runtime is a handler,** `with Async.single()` or `with
  sim.scheduler(seed)`.

## Done when

- The five programs above are in `examples/`, with their tests, and pass
  under `ren test` and `ren test --seeds 1000`.
- A test that sleeps for an hour of virtual time finishes in
  milliseconds.
- The `just` runs independent recipes at once, kills the rest when one
  fails, and records and replays byte for byte with `ren replay`.
- Each error above is a one-line refusal test.
- `ren test --sim --seeds` finds a lost update between two operations
  and replays it by seed, and the README's `cached` passes under every
  seed.
- A failure inside a task shows its task path.

## Later

- **Streams for `each` and `map`,** decided in streams.md, wait for
  generators (stage 11c): `Async.each(Net.connections(listener), max:
  10_000)` pulls the next item only when a slot frees.
- **Restart policies,** like Erlang's supervisors. Until then, it's
  `attempt` or `retry` inside a task.
- **Many cores** (stage 11b): `work_stealing`, `per_core` and `pinned`,
  arenas, `Mem.snapshot` and lock-free handlers.
- **The rest of the simulation scheduler** (after 11a's `sim`): failing
  networks and disks, crashes, and checking every interleaving.

## Open questions

- **Can a `with` set its own cleanup deadline?** It's 5 seconds, fixed,
  for now.
- **What's `map`'s default limit?** 64 is a starting point, not a
  measurement.
- **Whether `both` gets a "runs once" marker,** so its blocks can each
  change a variable of their own.

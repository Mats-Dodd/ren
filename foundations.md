# Foundations: blocks, dispatch, tasks and memory

This is the design record for how Ren treats functions as values, how a
call finds its code, how tasks run on many cores, and what that gives the
compiler. It was decided on 2026-10-26, after the research and design
rounds summarized at the end, and amended on 2026-10-27 with what the
native slice measured: decisions 14 to 16 are new, and 2, 4, 8, 10 and
13 changed. It was amended again the same day from nine research spikes
and three programs written against it: decision 17 is new, and 3, 4,
7, 8, 10, 13, 14 and 15 changed. It reverses parts of [deps.md](deps.md),
[handlers.md](handlers.md), [async.md](async.md) and
[compiler.md](compiler.md). Those documents keep describing what's built
today, and each is updated by the stage that implements its part of this
record ([Staging](#staging)).

## The bet

**Code flows down the stack, data flows anywhere, and behaviour that
varies is a handler.**

Every mechanism in Ren keeps that shape:

| Mechanism | Lives as long as |
|---|---|
| A block (Ren's only lambda) | the call it's passed to |
| An `&` access | an interval the syntax fixes: a call, a loop, a scope |
| A task | the scope that started it, which waits for it |
| A handler operation | a function call: handlers resume at most once, in tail position |
| A suspended frame | its task, in memory the scope already owns |
| A value | as long as it's used, counted by Perceus |
| A handler description | a value: code named by its handler, plus data copied in |

Only values outlive the call that made them, and values are data. So
lifetimes come from the program's structure and nobody writes them down,
the code a call can reach is known by name, and frames exist only where a
function can suspend.

It's aimed at three things Rust gets wrong for the programs Ren is for:
compile time, the split between `dyn` and generics, and colored functions
with their split between Rayon and Tokio. And it keeps what Effect gives a
program, typed errors and requirements, dependency injection, structured
concurrency, in direct style.

**The programmer never holds an address, so representation is the
compiler's choice.** Values have no identity a program can see, and
nothing hands out a pointer into one. So the compiler may keep a value
unboxed or boxed, pack its fields, keep a slice as a root and a range,
lay an array out by field, or build data in an arena's chunks, and no
program can tell. The rule that keeps this true: **no feature exposes
an address or an identity outside `trust`.**

## Decisions

### 1. Lambdas are blocks

A lambda is a **block**. It can be passed as an argument, bound to a
local with `let`, and called. It can't be stored in a record, a
collection or handler state, and it can't be returned. Named functions
are passed the same way.

- A block is called only during the call it's passed to. The one
  exception is a block passed to `s.spawn`, which runs until the
  `Async.scope` that made `s` ends.
- A block captures by reference, and may change an outer `var`.
  [Exclusivity](#2-one-exclusivity-rule) keeps that sound.
- Blocks can't be bound with `var`, and a `let` binds one literal block.

```ren
var tries = 0
try retry(3, on: DbDown) fn() =>
  tries += 1
  with sql.transaction() over Sql in
    transfer(from, to, amount)
```

`let f = fn() => n + 1; n += 5; f()` is 6: a block reads `n` when it
runs. Before 10c step 5 it was 1.

**What it gives the compiler.** Every block at a call site is either a
literal or a parameter of the enclosing function, so blocks only travel
down the call stack. A block's environment is the frame it was written
in. Release builds specialize a higher-order function for each block, as
Rust does for closures, so the block inlines and nothing is allocated.
Debug builds pass a code pointer and a frame pointer. Neither needs
lambda sets or any flow analysis.

### 2. One exclusivity rule

While a place is being changed, nothing else may access it. A **place**
is a variable followed by fields and indices. Different fields don't
overlap, any two indices may, and a place overlaps its prefixes.

| Access | Kind | Lasts |
|---|---|---|
| A copied value (`Int`, a record of scalars) | read | an instant |
| A counted value passed to a parameter that only reads it | read | the call |
| `&p` as an argument or receiver | write | the call, from after the arguments are evaluated |
| `p = e`, `p += e` | write | an instant, after `e` |
| `for x in p` | read | an instant: a snapshot, or a borrow if the body doesn't touch `p` |
| `for x in &p` | write | the loop |
| A block passed to an ordinary parameter | each captured place, as the block uses it | the call |
| A block passed to a concurrent parameter (`Async.map`) | read; a write is an error | the call |
| A block passed to `s.spawn` | read | the `Async.scope` call that made `s` |
| Inside a handler arm, any dependency call or block-parameter call | write of all the handler's state | that call |

Two overlapping accesses in one task, at least one a write, are a compile
error. Blocks passed to the same call don't conflict with each other,
unless one goes to a concurrent or spawn parameter.

Four rules make that sound, and each is checked from signatures:

- **A. No nesting.** A block parameter, or a block that captures one,
  can't be passed to a call of a block parameter. Without this, a block
  can run inside itself and write a place twice at once. A recursive
  combinator like `fix` becomes a named recursive function.
- **B. Concurrency is part of a parameter's type.** A block parameter
  can't be passed on to a concurrent parameter, or to `spawn`, unless
  it's marked so. Public signatures say it, and private ones are
  inferred.
- **C. A spawned block captures by reference only the variables of the
  frame that calls `Async.scope`.** Everything else is copied: loop
  variables inside the scope, a helper's locals and parameters.
- **D. A scope and a task handle are blocks too.** They can't be stored
  or returned.

The check is **fully static**. Swift checks exclusivity at run time only
for escaping closures, class properties and globals, and Ren has none of
them. It's **one walk per function**: intervals come from the syntax, and
a caller needs to know only whether each block parameter is ordinary,
concurrent or spawned. There's no dataflow and no lifetime inference.

What the optimizer gets: an `&` parameter aliases nothing else the
callee can see, not another parameter, a capture, or handler state.
That's a fact about the slot. The buffer in it can still be shared
(`let a = xs; f(&xs, a)`), so changing a buffer in place keeps Perceus's
one-compare uniqueness check, but **once per loop, not once per write**:
when a loop makes no new reference to the array, the slot fact means
nothing else can, so the check and any copy move to the loop's entry and
the loop indexes the buffer directly. That's the measured payoff (fannkuch
went from 2.44× Rust's cycles to 0.98×). Loads aren't reloaded across
stores to another `&` array either, which `restrict` on the buffers
says; that's worth about 5%, and only where a loop writes two arrays.

The errors read in one sentence each:

```
error: `n` can't change while a spawned task reads it
   │ s.spawn fn() => log(n)
   │                     - read until `Async.scope` ends
   │ n += 1
   │ ^^^^^^
   help: copy it for the task, `let m = n`, or change it after the scope
```

### 3. A handler description is the only stored code

A **handler description** is a handler's name and its arguments,
`frozen(t)`: a recipe that `with` turns into an instance. Descriptions
are values, as they are today. Under this record they're the only values
that carry code, and they carry it by name.

- A description's arguments are data. They can't hold a block, `next`,
  or an instance, so a description never carries state: each `with`
  builds fresh state from it.
- An inline handler for a dependency with one operation captures data by
  copy: `handler fn(req) => respond(req, body)` is a `Route`.
- A chain, `a over b`, isn't a value in v1. Store the parts and write
  `with a over b`.
- **A stored description's `uses` is an upper bound.** A handler that
  needs fewer dependencies fits a slot whose type lists more:
  `Router<(Api uses Db, Cache)>` holds `health()`, which uses nothing.
  Dispatch over the closed set still knows each handler's exact row.
  Without it, every route in a table has to declare every dependency any
  route uses. Decided for 10d; today's error says the opposite of what's
  happening ("one that needs more can't stand in for one that needs
  less"), and its direction is fixed now.

A **stateless handler**, with no `var`, no `finally`, no setup that can
fail and no `next`, can also be called as a method, without a `with`.
That's Ren's answer to `dyn Trait`:

```ren
dep Shape = area: fn() -> Float
handler circle(r: Float) for Shape = area() => 3.14 * r * r
handler square(s: Float) for Shape = area() => s * s

let shapes: Array<Shape> = [circle(1.0), square(2.0)]
let total = shapes.map(fn(s) => s.area()).sum()
```

An enum and a dependency answer opposite sides of one question. Adding a
variant to an enum means editing every `match`, and adding an operation
is one function. Adding a handler is one declaration anywhere, and
adding an operation means editing every handler. Use an enum when you own
all the variants, and a dependency when others add them.

### 4. Static dispatch, in a closed world

Release builds see the whole program, so the handlers `for D` are a known
set, and a call to an operation of `D` can only reach that set.

**The promise: a closed, listed set, lowered to the fastest code.**
Every dispatch goes to handlers the compiler knows and
`ren build --explain-dispatch D` lists, site by site, with the lowering
it chose and why. Which lowering depends on how many handlers reach the
call, after release narrows them:

- **One handler: a direct call,** which inlines. That's almost every
  `with`, after specialization. A dependency with one handler in the
  program has no tag at all.
- **Two to four: the arms inline,** as compare-and-branch, not a jump
  table.
- **More than four: a call through a static table** of the set's arms,
  indexed by the description's tag. For a dependency with one operation,
  the tag is the arm's code pointer. That's an indirect call, but to a
  closed, listed set.

Measured on an M4 (research/dispatch.md): one handler costs 0.88 ns a
call against Rust's `dyn` at 1.15; two to four handlers, shuffled, 2.8
to 4.8 ns against `dyn`'s 5.5 to 7.5 and Go's interfaces' 6 to 8.2; a
handler chosen from config and called in a loop, 0.77 ns, or 0.29 when
the loop vectorizes. Above four, an inline jump table was 5 to 15%
slower than a vtable call, and up to 53% slower in a recursive
interpreter, and an out-of-line switch function was slower everywhere;
the table call tied or beat the vtable (8.26 against 9.03 ns at 32
handlers). Rust's enum loses where the switch does, so it's the
lowering, not the closed world.

- **Ren clones loops per handler itself.** Release clones a `with`'s
  body, or a loop over a description that doesn't change, once for each
  handler a runtime value could be, when there are four or fewer and the
  code fits a budget, and never across a suspension. clang at -O2,
  Ren's release level, never unswitches: the switch stays in the loop,
  2.7× slower in one that would vectorize. A description is immutable,
  so its tag can't change in the loop; Ren knows that and clang doesn't.
- **Dispatch that recurses through its own dependency** calls through the
  table, never one switch function holding every arm.
- **A description's size depends on the build.** Debug builds make it a
  tag and up to three words of captured data, anything larger or
  recursive boxed, and the tag a pointer to a record of the handler's
  functions, so each module compiles alone. That's a vtable, but debug
  evidence already is one. Release numbers the tags and sizes a
  description to its dependency's largest handler, up to about eight
  words, before boxing anything: Rust's layout cost nothing measured in
  streaming loops, where boxing a five-word payload cost 6 to 12% when a
  tenth of the elements had one, and 30 to 90% when half did.
- An optional release-only analysis narrows which handlers reach a
  parameter or field. It's invisible to typing and never runs in debug.
- Polymorphic recursion that makes descriptions without bound is an
  error, as in Embedded Swift.

**How far specialization goes.** Measured, it grows code linearly, a
constant 1.25× the debug build's C, and shrinks machine code to 0.55×
of the unspecialized program, since blocks and handlers inline away.
So there's no per-function cap on copies: the one the native slice had
(64) was reached at about ten modules of ordinary code, and its fallback
was larger than what it saved. Instead:

- Identical emitted functions are folded into one.
- A generic function whose body only moves its values, with no `==`,
  `show`, hashing or other operation that depends on the type, is
  specialized per layout, not per type, as Go and Swift share code. One
  that uses such an operation is shared per layout too, with the type's
  descriptor as a parameter, as release `==` already walks it; it's
  specialized per type only where release emits code specialized for
  the operation.
- A whole-program size budget may make a call box its arguments
  instead; that's a dispatch, so it's reported as a build note, never
  silent.

**Combinations of types.** On generic code that makes generic code at
new types, the shape that makes Rust's builds explode, copies grow as
Rust's instances do, polynomially or exponentially as the program's
types do, at 0.2 to 0.75× of rustc's count (research/combinatorial.md).
Blocks are a constant factor: a block never enters a type, so generic
code downstream of one is shared across call sites (5 copies a site
against Rust's 20 on adapter chains), but code that wraps a block at
each layer makes a copy per literal, as Rust makes one per closure type
(4,082 against 4,080). **Representation is the lever.** Everything that
isn't a small value is one boxed word, so sharing per layout collapses
the copies that types multiply: 1,030 functions to 18, and 1,475 to 22,
which Rust's by-value layouts can't do. Copies made per block don't
fold, and only the budget bounds them.

There are no dynamically loaded Ren plugins. C function pointers, inside
`trust`, are the one indirect call left.

### 5. Dependencies are found where a block is written

A block's dependencies come from where it's written, except those listed
in its parameter's type, which the callee provides:

```ren
fn with_fake_net(body: fn() uses Net) = with fake_net() in body()
```

So a wrapper can't handle a block's calls by accident, and a helper that
installs something for its body says so. Since 10c step 4 this is
what runs (deps.md, "How it runs").

### 6. Dependencies can be generic

`dep Chan<T>`, `dep Jobs = Chan<Job>`, `with channel() as Jobs`. Channels,
`Batcher<K, V>`, pools and caches are written once, in the standard
library, not once per dependency or in the runtime.

### 7. Structured tasks

```ren
Async.scope fn(s) =>
  for conn in Net.accept_until(Signal.term) =>
    s.spawn fn() => handle(conn)
```

- `s.spawn` starts a task. Its handle can cancel or join it inside the
  scope. `s.replace(key) fn() => ...` cancels the task already under that
  key.
- A spawned task can't fail with an unhandled error.
- **One way to wait: `Async.until(cond)`.** The condition reads only the
  handler's own state, and is checked again when the handler is released.
  The runtime resumes the first waiter whose condition holds. No wakeup
  can be lost, and there's no `if` where a `while` belongs.
- **`Async.tick()`** returns once every task that was runnable when it was
  called has run until it waits. That's the batching point.
- **`Async.yield()`** lets others run. There's no preemption.
- **Wrappers are calls:** `retry(n, on: Tags)`, `timeout(d)`, and
  `race(a, b)`. `with` installs only handlers.
- **`retry` names what it retries.** `on:` is required and takes one or
  more error tags, `on: DbDown` or `on: DbDown | Timeout`, checked
  against the block's errors when compiling. Any other error leaves at
  once; after `n` tries, the last error leaves.
- **`race`'s branches can't fail.** So the first to finish is the first
  to succeed, and a branch that fails can't leave the race waiting on
  the other: a server's `race(read_request, wait_for_shutdown)` would
  otherwise hold a closed connection until shutdown. A branch that can
  fail is an error whose help says to write `attempt` inside it, which
  makes the failure a value. Retrying until success is `retry`'s job.
- **A `with` whose setup or `finally` can fail is written `try with`,**
  as every other call that can fail is written with `try`, with the
  same fix-it. `with db.transaction() in ...` can fail with `DbDown` or
  `Conflict`, and inside a `retry(3, on: Conflict)` it's the error the
  retry exists for.
- **`Async.map` over a block that uses no dependencies runs on every
  core.** There's no `par_map`.
- **`handler ... over any`** intercepts every operation of a dependency:
  `call.forward()` at most once and never stored, `call.args` and
  `call.result` for recording, `call.fail(e)` with only the operation's
  declared errors. `limit`, the recorder, replay and fault injection are
  Ren code. There's no reflection: `call.args` and `call.result` are
  opaque, and can only be shown, compared and encoded to and from the
  journal, by functions the compiler derives for each dependency. An
  `over any` handler is specialized per dependency it wraps, so it's
  static dispatch like any other.
- **A `finally` covers everything after the point it's written,**
  including inside an operation, so a cancelled caller gives back what it
  took.

### 8. A panic ends the program

Unless it's inside `Async.isolate fn() => ...`, which gives
`Err(Panicked(msg))`. Isolation applies only when no handler installed
outside the task was in the middle of an operation; otherwise the program
still ends. When a panic is contained, the `finally`s of handlers
installed inside the task run, and its values are leaked, not dropped,
with the leak logged. So no landing pads constrain the optimizer.

An isolated block can't change a variable from outside it: it returns
its result, and anything else it changes, it changes through a
dependency operation. So nothing the block wrote after the fault can be
seen. An arena's body keeps the same rule (decision 10).

### 9. The runtime is a handler

`Async` is a dependency, so the scheduler is installed with `with`, as
Zig passes its `Io` in:

```ren
with Async.work_stealing(cores: 8) in serve()   // the default
with Async.per_core() in serve()                // one scheduler per core
with Async.single() in run()                    // one thread
with Async.pinned() in hot_loop()               // this subtree stays on one thread
with sim.scheduler(seed) in serve()             // tests
```

- **The rules don't change with the runtime.** Every program is checked
  against many cores, so code runs unchanged on any runtime, and only the
  cost differs. Libraries never name one.
- **The cost follows the runtime.** Nothing is marked shared where no
  task can run on another thread, so counts stay plain and locks are
  skipped. Release specializes for the runtime `main` installs, so under
  `Async.single()` the atomic paths aren't compiled at all.
- **The world follows it too.** The real `Fs` and `Net` get their event
  source, io_uring, kqueue or a thread pool, from the runtime.
- v1 ships `single`, `work_stealing`, `per_core` and `sim`. A runtime
  written by users would be a later interface inside `trust`.

### 10. Many cores

Tasks share mutable state only through handlers, spawned blocks read
what they capture, and values have value semantics. So data races can't
happen, with nothing to annotate.

**Handler operations don't interleave.**

- **An operation keeps its instance until it returns.** It holds it
  across its own calls to handlers installed outside it, and lets go
  early only at `Async.until`, which is a condition variable. Other
  callers queue for the instance as tasks: a thread never blocks while
  its task is parked, so across threads it costs what a plain lock does
  uncontended, about 5 to 20 ns. So state read before a dependency call
  is still the state after it, and an invariant that spans the call
  needs no flag.
- **Why.** Letting other operations in at every dependency call, as
  Swift's reentrant actors do, made handler code read like JavaScript
  `async` code, with bugs the source doesn't show. A key-value store's
  writer, written against the earlier rule (research/paper-programs.md),
  needed three fixes: two puts claimed one offset, a record written
  during an fsync was published as durable, and two overlapping syncs
  published out of order.
- **What it costs:** one slow call, an fsync, serializes that handler's
  operations. For the writer that's what's wanted. A handler that wants
  its calls to overlap splits an operation in two, "reserve" and
  "complete".
- **No deadlock.** An operation can only call handlers installed outside
  it, so a task takes instances inner to outer, and waits can't form a
  cycle. That holds with two rules: a block passed to an operation gets
  dependencies only from its parameter's type, and handlers in one
  `with` can't use each other in a cycle.
- **The exclusion is skipped unless the instance is shared.** Spawning a
  task marks the handlers it can reach. A handler with no `var` and no
  `let` of a C or opaque type needs none. The real world handlers queue
  per file.

**Memory crosses tasks four ways, and only two are free.**

- **Borrows of captures are free.** What a spawned block captures lives
  in the frame that called `Async.scope`, and a handler's `let`s and
  parameters live as long as its `with`; no task outlives either. So
  tasks read them as borrows, which count nothing.
- **A task's result moves free at its join.** The task has finished, so
  nothing else holds what it made, and the join costs a release and an
  acquire. Moving any other unique value isn't free: the objects inside
  it may still be the sender's, so it's marked. Measured, marking costs
  about 3 ns an object, and a marked list then copies on every change (a
  `map` over it 4.6× slower).
- **Otherwise an object is marked shared, one way, as Lean does.** What a
  spawned block keeps of its captures, the state of a shared handler and
  a value written into it, a published version, a value sent on a
  channel: each is marked once and for good, and counted atomically from
  then on. A shared object costs what Rust's `Arc` costs, and one counted
  from every core at once doesn't scale.
- **Or it's built in an arena** (below), the explicit tool for big data
  read from every core.

**Nothing that exists is frozen.** An earlier version of this decision
froze a scope's state for its lifetime, counts set to a value nothing
changes, and restored them after. Measured (research/freeze.md), the
walk costs about a read of the data, 5 to 66 cycles an object; it can't
wait for a steal, since every region with two tasks on two workers was
stolen from; and freezing late loses counts, so it isn't sound. Whether
data is cheap to share is decided when it's born.

**Arenas: `with Mem.arena() in body`.** The body allocates in chunks
that belong to the arena.

- **An arena changes cost, never meaning.** Values leave it only by
  copy: its result, and the arguments a handler installed outside it
  keeps. What such a handler's operation returns is copied in. The body
  can't change a variable from outside it, as with `Async.isolate`.
  Inside, objects are counted as usual, so a build changes them in
  place.
- **It's sealed when it's shared.** When a task scope opens inside it, or
  a value is stored into a shared handler installed in it, every chunk
  made since the last seal is sealed: one store per chunk. After that its
  objects are never counted again and a write copies them, so every core
  reads it as it reads borrowed data. Its first seal marks shared what
  the body captured from outside. It stays sealed until it ends, since
  copies taken while sealed weren't counted.
- **Tasks allocate in their own part of it,** and it ends all at once,
  with one pass over its chunks that releases what they hold outside.
- **Copy-in, not adoption.** An outer operation's result is copied in,
  not held by the arena until it ends. Holding it cost 150 MB after a
  million requests in one arena, against 1.7 MB copied in, which costs
  about 7% of a 4,000-cycle request.
- **It's a tool for sharing, not an allocator.** At 8 threads, a server
  whose requests copy config strings ran at 0.82 to 0.99× of pure
  borrowing in an arena, against 0.02 to 0.08× with the strings marked
  shared and 0.03 to 0.12× for Rust's `Arc`. Sealing a 1M-entry map
  costs 0.008 ms where marking it shared costs 83, and ending it 11 ms
  where dropping it costs 108. On one thread a per-request arena was 4
  to 13% slower than the heap, since Perceus with free lists already
  frees promptly.
- **A server's hot config is an arena the program builds,** with
  `with Mem.arena()` in its own code. The runtime never moves data into
  one by itself.
- The runtime's rules for arenas, marking and crossing are in
  [compiler.md](compiler.md#the-runtime-model).

**Hot state is sharded, and reads can take no lock.**

- **A hot handler with state is a queue.** `keyed(n, h) over any`, a
  standard-library handler, keeps `n` instances of `h` and sends each
  operation to one by its first parameter's `key`; an operation with no
  key goes to every instance. A hot counter is the standard library's
  striped counter, a line per worker.
- **Handler operations aren't compiled to atomics.** Uncontended, an
  atomic gains nothing (2.4 ns for a spin lock against 2.7 for an atomic
  add on an M4), and contended, the striped counter beats it (34 against
  13 million operations a second at 8 threads). Its rules would have
  been the most special-cased in the model.
- **Reads that take no lock: `snapshot(v)`,** a standard-library
  handler. `read` lends the current version to a block whose row is
  closed and empty, so it can't suspend and can't keep what it borrowed;
  `publish` and `update` swap in a new version, writers serialized
  against each other only. A read is one load: no lock, no count. The
  runtime frees an old version once every worker has passed a
  scheduling point, which no read block contains (QSBR, as Linux's RCU
  and BEAM's schedulers do it). What leaves a read block is copied out,
  up to a budget past which it's counted as shared; returning a hot
  entry by count instead was 37× slower. Measured at 8 readers, 80 to
  99% of borrowed reads, 13 to 20× reads under the handler's lock, and near
  Rust's arc-swap and crossbeam-epoch. Two rules make it sound: `s.spawn`
  carries `Async` in its row, since it can wait, and no code reached from
  a call with an empty row runs a scheduling point.
- **Atomics are fields of a lock-free handler.** A `lockfree handler`
  whose state is only `Atomic` fields of `Int`, `Bool`, `Float` or an
  enum, and `let`s, runs its arms without the instance's exclusion. Its
  operations, `load`, `store`, `swap`, `cas` and the `fetch_` family,
  are all sequentially consistent, as Go's are, so a run is still some
  order of operations, and under `sim` every access is a scheduling
  point. Weaker orderings, fences, and anything that hands out an
  address are `trust`: they're where `sim`'s guarantee stops.

The native slice measured why this matters: an object counted from 8
threads at once scales as Rust's `Arc` does, which on data hot in cache
falls to 2 to 12% of one thread's throughput; borrowed, or in a sealed
arena, the same data scales to the machine's limit. Marking objects
shared costs 1 to 4% on one thread. What still collapses, and the
documentation names as traps: many tasks updating one shared map by
copying its path, a small value copied per request from shared data
that isn't in a sealed arena, values read out of a shared handler's
`var` state, and many tasks keeping slices of one shared buffer, each
of which counts its root.

### 11. Determinism

Tasks touch each other only through handler operations, so a run on many
cores is equal to some order of those operations, and a test on one
thread can reach every behaviour.

- Every world effect is a dependency operation: closes on cancel or
  panic, timers, and C callbacks, which post completions to a runtime
  queue.
- Resources are closed in a `finally` or an operation, never when a count
  reaches zero.
- Completions arrive at counted poll points, and the journal records each
  poll.
- `Async.tick()` is a barrier across workers.
- The journal orders entries per handler instance, plus program order in
  each task. A handler that skips its lock needs no entries. Which of two
  parallel failures came first, and when a cancellation was seen, are
  recorded.
- The tape has typed streams: scheduler choices, `Random` split per task,
  and faults.
- A task's path is the label of its spawn site and an ordinal in that
  scope (`main/accept:7/handle:0`), so a journal survives edits.
- A journal becomes a test as world answers plus a schedule prefix:
  replay follows the recorded order while it can, then the seeded tape
  explores.

### 12. Frames and generators

- Only a function whose `uses` reaches a dependency can suspend, so only
  those get frames that outlive the native stack. There's no `async`
  keyword: the row already says it.
- Each task allocates its frames from a stack-like bump allocator, as
  Swift's tasks do. Recursion across a suspension just pushes another
  frame. Release may inline small child frames when sizes are known.
- `gen fn` compiles to a cursor, a value whose fields are data, for pull
  iteration: zip, merge, lookahead. A cursor owns its inputs. A `gen fn`
  can't take a block, since the cursor would keep it. Generators come
  after tasks.

### 13. Two builds

- **Debug builds never specialize.** Generics pass dictionaries, handlers
  pass evidence, blocks are a pair of pointers, and small values
  (decision 14) are boxed where they meet generic code. Each module
  compiles alone and incrementally.
- **Release specializes** in a whole-program back half, cached by
  content per function and specialization.
- Nothing in the front half is whole-program. That's the rule that keeps
  the edit loop fast, and why lambda sets leave the type checker.
- **Debug builds use tcc, now.** clang -O0 on the one C file Ren writes
  was 77% of a debug build. tcc compiles the same C 12 to 24 times
  faster, its code runs at clang -O0's speed or up to 1.8 times slower,
  and lldb steps through it (research/backend.md). It needs four things
  of the emitter: fallbacks for clang's overflow builtins; C in
  translation units of moderate size, a module or a partition, never one
  file, since tcc's `-g` is superlinear in a unit's size; no system
  headers in a module's unit (they were 6.7 of tcc's 8.1 ms a unit); and
  `#line` directives, so a debugger steps through Ren, not C. Units
  compile in parallel, cached by each module's content.
- **cproc with QBE was rejected.** Its code is about twice tcc's speed,
  but it compiles 2.1 to 2.4 times slower than clang -O0 and writes no
  line information.
- **Release by default comes from clang -O2 in parallel, not from a fast
  backend.** No small backend's code comes near -O2's (3.4 to 54 times
  slower). -O2 per module or partition, in parallel, with a cache, builds
  the same code: base-500k in 19.7 s as 32 units on 16 cores, against
  about 321 s as one file. An edit recompiles one module's partition.
- **Ren's own backend comes later,** for what tcc can't give: Mach-O
  objects, so ld64 links an edit in about 0.2 s against tcc's 1.6 to
  4.1 s; debug code without -O0's spills; and debug information about
  Ren rather than its C. Sized against Roc's dev backend, it's about 8 to
  12k lines of OCaml a target.
- **What's left for debug builds faster than Go is the front half.**
  With tcc, the backend is 10 to 20% of a debug build and the front
  half, on one core, 80 to 90%. Ren already uses 2.5 to 6 times less CPU
  than `go build` (base-500k: 19 CPU-seconds against 117); Go wins on
  wall clock by running on many cores. So the front half runs per
  module, in parallel, which the rule above already allows.

### 14. Koka's memory model, Rust's generics

Ren counts like Koka and Lean, Perceus with borrow inference and reuse,
but specializes generics like Rust and Swift where they box: an `Int` in
a `T` field is an `Int`, not a pointer.

- **What it costs.** Whether a field holds an object depends on the
  value, not the type, so an object's header carries a mask of which
  fields are objects, not a count of them, and fields in generic types
  can't be reordered or packed around the type parameter. Debug builds
  need layouts passed to generic code. Release builds must specialize to
  be fast.
- **What it buys.** Arrays of `Int`, `Float` and small records hold them
  unboxed, which Lean can't do for a user's type; that's why array loops
  reach Rust's speed.
- **Small values are values.** A type that isn't recursive and whose
  largest variant fits in a tag and three words, the size of a handler
  description, is passed and stored by value, as Koka does for `maybe`
  and tuples: `Option`, `Result`, tuples and small records allocate
  nothing and count nothing but the objects inside them. `Option` of an
  object is a pointer that may be null. Recursive types and anything
  larger are boxed.
- **Small values cover what frames did.** Keeping an object that never
  escapes in its function's frame (H8, stack.ml) was how release builds
  made temporaries allocate nothing. After small values, it added
  nothing measurable: 1.00× the cycles on every benchmark and on H8's
  kernels. It was also the one memory state Mem Lint didn't check,
  which let a leak through. So it goes.
- **Reuse goes deep.** Reuse follows Koka: a node that dies drops and
  reuses the nodes inside it too, a small builder (`balance`) is inlined
  where a freed node can go into what it builds, and a rebuild writes
  only the fields that changed. A persistent red-black tree allocates
  one node an insertion, as a mutable one does. It's an optimization,
  not a guarantee.
- **Taken from Lean and Koka, and built.** An element taken out of an
  array while it's changed, so `grid[i][j] = x` and a `map` over arrays
  of arrays change the inner arrays in place (Lean's swap-out: a grid's
  100 million allocations became 103); scalar fields packed together
  after the object fields (Lean's: rbtree's peak memory 203.2 to
  169.6 MB); and recursion that builds a structure after its call
  compiled to a loop (Koka's tail recursion modulo cons: building a
  list by recursion, peak memory 97.4 to 25.5 MB, with no stack).
- **Indices are a library.** `Id<T>` and `Pool<T>`, opaque types over an
  `Int` and an array of small records, give Roc's and Zig's
  arrays-and-indices pattern, with an id that can't be used on another
  kind of pool, and a pool of plain records saves and loads as arrays (a
  1M-entry map loads in 3 ms, against 120 to 180 ms to rebuild it).
  Arenas indexed this way were rejected: they'd need two versions of
  every function an arena's body reaches, or a test on every field
  access, and indices can't name the outside objects an arena's records
  hold.
- **The runtime:** an 8-byte header (a 32-bit count, a tag, a field
  count and a mask of which fields hold objects) and an allocator with
  free lists per size, which made every allocating benchmark faster than
  Rust's. The count says the object's state: positive for one thread's,
  negative for shared, zero for never counted (statics, sealed arena
  data), and a band below shared for arena objects, so the inline paths
  test one sign and every other state costs code that never meets it
  nothing. References are 8 bytes; 32-bit ones are an open question.
  The whole model, four states and seven rules, is in
  [compiler.md](compiler.md#the-runtime-model).

### 15. Arithmetic

`Int` and `Float` are the only types arithmetic is done in. A fault
panics, at the same point in every build: an `Int` overflow where it
happens, a NaN where it's observed.

- **Overflow is checked at each operation.** Reporting it late, when a
  loop with no effects leaves, was built (late.ml, behind REN_LATE),
  measured, and dropped: it made no loop vectorize, and it slowed the
  loops it changed, inout by 18% and a running sum of squares by 29%. A
  panic that says which operation overflowed, with what operands, needs
  a call that records them at each site, and a branch to a call keeps
  clang from vectorizing; a flag alone can't say which, and a checked
  running sum can't be vectorized at all, since whether a prefix
  overflowed isn't known from the lanes' sums. So a loop that wants
  lanes uses the wrapping operators, which vectorize, or, later, narrow
  lanes where the compiler proves the values fit. The cost stays: a
  running `Int` sum is 4.45× Rust's, whose release build wraps, and it's
  the largest cost left in the benchmarks.
- **Wrapping operators** `+%`, `-%`, `*%` are for hashes, checksums and
  random number generators. They wrap at the width of the sized integer
  their result is stored into, and otherwise at 64 bits: `h = h *%
  16777619` into a `UInt32` keeps 32 bits, and `let x = h *% k` is an
  `Int`, wrapped at 64, whatever `h` is. Storing a wrapping result into
  a `UInt64` is an error, since half of what wrapping at 64 bits makes
  is negative; a 64-bit hash stays an `Int`.
- **Bits:** `xor`, `bit_and` and `bit_or`, and the shifts `x.shl(k)`
  and `x.shr(k)`; and literals in hex, binary and with underscores,
  `0x82F63B78`, `0b1010`, `1_000_000`. A CRC written today divides by
  256 for a shift. Bits shifted out are lost, as in Rust and Go, so
  there's no separate wrapping form: `shl` wraps by the rule `*%`
  follows, and a shift amount outside 0 to 63 panics. `shr` is
  arithmetic on signed types and logical on unsigned ones. The shifts
  and literals are decided, not built.
- **A NaN is checked where it's observed, not where it's made.**
  Arithmetic and stores carry it; comparing it, `match`ing on it,
  converting it to an `Int` or a `Str`, hashing it, or passing it to a
  dependency operation panics. So no program acts on a NaN, and none
  reaches the journal. Debug and release builds check at the same points;
  a debug build's message also says where the NaN was made. Measured,
  checking every operation was 31% of nbody's cycles; checked where
  observed, nbody went from 2.37× Rust's time to 1.62×.
- **Sized integers are for storage.** `Int8`, `Int16`, `Int32`, `UInt8`,
  `UInt16`, `UInt32`, `UInt64` and `Float32` are types of fields and
  array elements. Reading one gives an `Int` (or `Float`); storing into
  one checks that it fits. Later, where the compiler proves values fit,
  a loop computes in narrow lanes.
- **`Float` arithmetic keeps its order.** A sum of `Float`s that a
  vector unit adds in lanes would depend on the machine's width, and a
  journal recorded on one machine has to replay on another. So
  `xs.sum()` on `Float`s is defined as a fixed tree, eight lanes added
  pairwise, the same on every machine, which also vectorizes and is
  more accurate than adding left to right. Measured, a million-`Float`
  sum ran 35× faster than the checked chain it replaced.
- **Tables are computed while building.** A top-level `let` is a value
  fixed into the binary ([shapes.md](shapes.md)), so a CRC table or a
  parser's tables cost nothing when the program runs. It's on the list
  of performance work, as `comptime` is for Zig, with no keyword.

### 16. Loops

- **Loops that don't index don't check bounds.** `for x in &xs`,
  `for i, x in &xs` (the index and the element), and `zip` over several
  arrays, a cursor, compile to one bounds check per loop. Other indexing
  is checked, and range analysis removes what it can.
- **The compiler may choose an array's layout.** Arrays are values, and
  nothing hands out a pointer into one's elements, so an array of
  records could be stored as one array per field, which vectorizes. Not
  built; no feature may give out such a pointer ([the
  principle](#the-bet)).
- Explicit vector types, as Zig's `@Vector`, come later if loops need
  them.

### 17. Slices are values

A slice of a `Str`, `Bytes` or `Array`, `xs[a..b]`, is an ordinary
value of the same type, as Roc's seamless slices are; there's no
`Slice` type. It's a root, the counted owner of the
buffer, and a range. It can be stored, returned and kept in records,
and it has value semantics; writing to it copies its range first, as
writing to any shared value does. A slice of a slice has the first
one's root. A cursor is a value holding a slice, so a cursor that
borrows its input needs no lifetime.

- **What doesn't escape costs nothing.** A slice of a parameter the
  function borrows doesn't count its root: it's a part of its root, as a
  field read is, counted only if the root is consumed while it lives.
  So the second-class view this record once asked for is there, but the
  compiler derives it and nobody writes it. Measured (research/slices.md),
  a parser that split log lines into fields, 24M slices in all,
  allocated and counted nothing, at 0.96× the cycles of the same parser
  written with offsets.
- **What's kept costs one count.** A slice is a small value (decision
  14), kept inline in records and arrays, and each kept slice is one
  count on its root. Tokens and page records that kept their slices
  cost 1.09× to 1.17× of offsets inline, against 1.5× to 2.5× with each
  slice a heap object, about what copying costs. Offsets into a buffer
  remain the fastest way to keep many.
- **A slice keeps its whole root alive.** `copy()` gives one its own
  buffer, and is free on an owner. Debug builds report roots kept alive
  mostly by small slices, and where those were made: eight 8 MiB files
  of which 80 KB of keys were kept held 67 MB.
- **A mutable view is `&` on a range,** `f(&xs[a..b])`: a write of `xs`
  for the call, as `&xs[i]` is. Two ranges of one array in one call
  overlap, as two indices do, so no exclusivity rule changes.
  `xs.split_at(n, fn(&lo, &hi) => ...)` and
  `Async.chunks(&xs, k) fn(&c) => ...` give a block disjoint ranges as
  places of its own, changed in place. They need blocks that take
  `inout` parameters (10d).
- **A `Str` slice panics if it cuts a character.** The slices `split`,
  `index`, `trim` and `lines` make are at boundaries they found, and
  don't check; `Bytes` never checks.
- **Across tasks,** a task's slices of what it borrowed from its
  captures are free. A slice it keeps counts its root, which is then
  shared, so many tasks keeping slices of one buffer is the hot-root
  trap of decision 10: keep offsets, or `copy()`.

## What's given up

- **Stored closures.** Grammars, schemas and routers built at run time
  become enums with an interpreter, or handler descriptions. A pull
  adapter can't carry user code, and turning a recursive producer into a
  pull sequence needs a task.
- **Generic lazy pipelines.** An adapter over any cursor needs a trait,
  and a `map(f)` cursor needs a stored block, so `xs.map(f).select(p)`
  is eager, and a pull pipeline is a `gen fn` written for its element
  types. It's also why Rust's nested adapter types, which drive its
  build times, have no counterpart.
- **Multishot continuations.** No backtracking or probabilistic
  programming as a library. `gen` and async are built in.
- **An open world.** No Ren code loaded after compiling.
- **Some `both(fn() => a += 1, fn() => b += 1)`.** It's safe, but needs a
  "runs once" marker, deferred.
- **Free sharing of changing data across cores.** A shared handler with
  state queues its callers, and one slow operation serializes the rest;
  a value shared outside an arena costs atomic counts. Immutable handler
  state and sealed arenas don't.
- **Release build time.** Specializing costs what it costs in Rust, paid
  only in release. Measured, copies grow like Rust's instances on
  generic code that makes generic code at new types, polynomially or
  exponentially as the program's types do, at a fifth to three quarters
  of Rust's count, since a block is never part of a type; sharing per
  layout collapses the copies types make, and code that wraps blocks at
  each layer is bounded only by the budget, as a closure-heavy Rust
  program is.
- **Arithmetic in sized types.** Sized integers are for storage; wrapping
  operators are the only arithmetic at a width.
- **Vectorized checked sums.** An `Int` overflow panics where it happens,
  so a loop whose sum is checked runs one lane at a time; `+%` is the
  way to ask for lanes.
- **Addresses:** pointers into arrays, a value's identity, and anything
  else that would fix a representation, outside `trust`; and outer
  variables changed by an isolated block or an arena's body.

## What it isn't

- **Not Rust:** no lifetime annotations, `Send`, `Sync`, `Pin`, `dyn`, or
  async functions.
- **Not Koka:** no heap-allocated continuations for general effects.
- **Not Go:** no shared memory between tasks, no unstructured goroutines,
  no preemption.
- **Not Erlang:** no heap per task, no copied messages, no supervisor
  trees in the language.
- **Not Effect:** no effects as values, no fiber interpreter.
- **Not OxCaml:** no modes for users to write. Blocks are the only lambda.

Rejected after research: preemption, a heap per task, linear and unique
types, `atomic` blocks, wakeups that carry values, a `map` that goes
parallel when its block happens to be pure, and finding a block's
dependencies where it's called. And after the native slice: freezing
data that already exists, keeping objects in frames, overflow reported
late, handler operations compiled to atomics, arenas that hold outer
results by adoption, arenas of indices, cproc and QBE for debug builds,
and 32-bit references as the default.

## What it reverses

| Today | Becomes |
|---|---|
| A lambda can't change an outer `var` | A block can, checked by exclusivity |
| Lambdas can be kept: stored, returned, in records (`Button`, `..d` rows in type arguments) | Blocks only. Stored code is a handler description |
| A lambda can't call `next` | That rule goes |
| Handler parameters can be functions | Data only |
| Wrappers go in `with`: `with retry(3) over timeout(d) in` | Calls: `try retry(3, on: DbDown) fn() => ...` |
| A lambda's dependencies are found where it's called | Where it's written, except its parameter type's |
| Lambda sets in function types (stage 10.0) | Gone from the type checker. Release may narrow switches |
| A dependency can't take type parameters | Generic dependencies |
| `Async.limit` and the recorder are built in | `over any` handlers in Ren |
| `par_map` | `Async.map` over a block with no dependencies |
| Preemption at loop back-edges (async.md) | None |
| `race` takes the first to finish; `retry(n)` retries any error | `race`'s branches can't fail, so the first to finish succeeded; `retry(n, on: Tags)` |
| Another task's operation can run on a handler at each dependency call, and a warning catches state read across one (async.md) | An operation keeps its instance until it returns or waits in `Async.until` |
| A `with` whose setup can fail is written `with` | `try with` |
| The journal has no task column | A task path column, answers keyed by task |
| A `Float` operation that makes a NaN panics | A NaN panics where it's observed |

## Staging

1. **10c, blocks.** Blocks with exclusivity and rules A to D; wrappers out
   of `with`, with a fix-it; lexical lookup; `while` and `break`; cursors
   and `for` over them; `finally` where it's written; lambda sets out of
   the type checker; the deps.md, handlers.md and README sections on
   kept lambdas rewritten. Landed so far: wrappers and record
   implementations out of `with` (step 2), and blocks second-class
   (step 3): a block is only called, passed, or the value of a `let` of
   one literal `fn`; written types, generics and handler parameters hold
   none; Infer checks it after inference and Core Lint again. Lexical
   lookup (step 4): a block captures the evidence where it's written, and
   its callee provides only what its parameter's type lists, none if the
   type isn't written; `next` in a block runs. Capture by reference
   (step 5): a block shares its frame's cells, and one exclusivity pass
   after inference, one walk per function, checks the table in decision
   2 and rule A, with ordinary the only parameter mode. Additions
   (step 6): `while` and `break`, cursors and `for` over them, and
   `finally` as a statement where it's written, among a handler's state
   or in an operation's arm. So 10c built everything in this item but
   rules B to D, which land with 11a, since 11a makes the concurrent and
   spawned parameters they're about.
2. **The native slice.** A C backend from Core for the sequential
   subset, and the benchmarks in vision.md measured against Rust and
   Go, to put numbers on the memory and dispatch bet before tasks and
   many cores build on it. It landed with more than the naive backend
   planned, so the hypotheses could be measured at all: the benchmarks
   in Ren, Rust and Go (bench/native); Mem IR, the C runtime and `ren
   build`, each binary checked against `ren run` under the sanitizers;
   the debug strategy, descriptors for generic code, blocks as a code
   and a stack environment, evidence and handler descriptions; Perceus,
   borrow inference, precise counting, reuse and arrays changed in
   place, the naive counting kept as `--rc naive`; and release builds
   that specialize per type, block and known handler, with unboxed
   records and `restrict` (compiler.md, "Native slice"). The numbers
   are in [bench/native/RESULTS.md](bench/native/RESULTS.md). After the
   experiments that followed (map in place, deep reuse, the header and
   allocator, frames, hoisted array checks, counting across cores), all
   merged: blocks and known handlers cost what a loop and a call do;
   Perceus counts 12 to 137 times less than naive counting; six of the
   seven programs run within 2× of Rust's time, five faster than it
   (0.24× to 0.75×), fannkuch equal and nbody 2.39× for its NaN checks;
   memory is within 1.5× of Rust's everywhere; and debug builds are
   slower than `go build`, most of it clang at -O0. Decisions 2, 4, 10,
   13 to 16 were amended from these numbers.
   **Follow-ups, done:** the release build in linear time; panic
   messages interned; specialization without the per-function cap and
   identical functions folded (decision 4); small values as values,
   packed scalar fields, swap-out and tail recursion modulo cons
   (decision 14); wrapping operators, NaN where observed, sized storage
   integers and `Float` sums (decision 15); `for i, x in &xs` and `zip`
   (decision 16). Late overflow was built and is off (decision 15).
   Every benchmark is now within 2× of Rust's time, inout at 1.67× and
   nbody at 1.61× the furthest. **Close-out, done:** debug builds
   compile with tcc in parallel units with `#line` (decision 13): 500k
   lines in 18 s against `go build`'s 15.2 s, so H6 still misses by
   1.18×, in the single-core front half; frames (stack.ml) and late
   overflow removed (decisions 14 and 15).
3. **10d, descriptions.** Generic dependencies; handler descriptions as
   the only stored code, inline handlers, stateless handlers as methods;
   a stored description's `uses` as an upper bound, and the error's
   direction fixed; `over any`; `retry(n, on:)`; blocks that take
   `inout` parameters, which `split_at` and `Async.chunks` need.
   **Done**, in the interpreter and natively, with dispatch lowered as
   decision 4 says (at Rust's `dyn` on six of seven kernels, the
   interpreter kernel at 1.53×) and `--explain-dispatch`. **Gaps, not
   built yet:**
   - Slices are a heap object each, 2.2 to 5.6× Rust's slices (pages
     the furthest), and Ren's byte and string handling is 2.6 to 2.8×
     Rust's even with offsets (bench/native/RESULTS.md, "Slices").
     Decision 17's inline slice (two or three words in records and
     arrays) and the uncounted view of a borrowed parameter's slice
     need a representation change across the backend. They land with
     strings, when the `just` builds natively, where the cost shows.
   - Descriptions are always boxed: release doesn't size one to its
     dependency's largest handler, and a one-handler description still
     carries a tag (decision 4).
   - Only loops are cloned per handler; a `with` body over an unchanging
     description isn't (decision 4).
   - Inline handlers are lowered where they're written, not lifted.
   - Debug builds compile an `over any` handler once per dependency it
     wraps, rather than once.
   - `==` on `call.args` over a generic dependency is an error, not
     built; an imported `over any` handler that compares args can still
     crash the compiler.
   - `as` on a chain (`with a over b as Jobs`) is an error.
   - An `over any` handler over an operation that takes a block is
     refused.
4. **11a, tasks.** Rules B to D; `Async.scope`, `spawn` and its handle,
   keyed spawn, `until`, `tick`, `yield`, `timeout`, `race` with branches
   that can't fail, `isolate`; handler operations that don't interleave;
   `try with`; the runtime as a handler with `single` and `sim`; the
   tape, poll points, task paths, journal version 2, journals as tests
   with a schedule prefix; the standard library's channel, semaphore,
   `Batcher` and `keyed(n, h) over any`. Two holes in the spec to close
   here: `s.spawn` carries `Async` in its caller's row, since it can
   wait; and no code reached from a call with an empty row runs a
   scheduling point.
5. **11b, many cores.** `work_stealing`, `per_core` and `pinned`; the
   runtime model of [compiler.md](compiler.md#the-runtime-model): the
   shared mark and atomic counts on shared objects, a heap per thread
   with frees returned to the heap they came from, the current heap a
   pointer each task holds; arenas, sealed when shared, with copy-in;
   `snapshot` and its reclamation; lock-free handlers with `Atomic`
   fields; the striped counter.
6. **11c, generators** and the stream library on them.
7. **Native, stages 13 and 14.** The task frame allocator; the build
   notes; the front half run per module in parallel; release built with
   clang -O2 per module in parallel, cached by content. Specialization
   per block and per handler, and most of the memory work, are built
   (item 2), and dispatch with `--explain-dispatch` (item 3).

The interpreter runs tasks on OCaml effects throughout, so 10c to 11c
need no native code.

## Open questions

- The size budget for cloning a `with` body per handler.
- Whether `both` gets a "runs once" marker.
- What a runtime written by users looks like.
- Where folding and sharing per layout run (on Mem IR before C, or on
  the C), and whether the size budget counts copies, C, or machine code.
- Whether choosing an array's layout (decision 16) pays, and when.
- **Allocation the compiler guarantees.** Reuse is an optimization
  (decision 14): `ren build --explain-alloc` to show which allocations
  were reused or kept, and which values were copied crossing an arena
  or a read block, and a Koka-style `fip` marker that makes a function
  that would allocate an error, for hot paths.
- **Compressed references.** Object fields as 32-bit offsets from one
  reserved range, as the JVM, V8 and Koka's `c64c` target do, bring
  trees to Rust's memory (a binary-trees node 24 bytes to 16; rbtree
  and binary-trees peak memory 1.24× and 1.47× Rust's to 1.00× and
  0.98×). Measured on an M4 they cost 3 to 17% of cycles, and 2.2× on
  rbtree, whose hot pointer chasing loses the processor's load
  prediction to the one-instruction decode. They also cap every
  object, strings included, at 16 or 32 GB, which a storage engine
  can outgrow, and an ahead-of-time compiler can't choose at startup.
  So the default stays 64-bit. A whole-program build flag is the form
  if a program needs it; x86-64 is unmeasured.
- **How an arena's data outlives its `with`.** A server's config built
  in an arena is read while the server runs, but its handlers, which
  change, live outside the arena and are sized by the config. Whether
  `let cfg = with Mem.arena() in build()` keeps the arena alive, sealed,
  as long as `cfg` is (research/paper-programs.md), or the serving loop
  runs inside the arena, isn't decided.
- **Ending an arena without its pass.** The pass that releases what an
  arena holds outside it costs about 15 cycles an object; an arena that
  provably holds nothing outside could skip it.
- **Arrays of small values that hold objects,** which slices kept in
  records need: an array's elements counted by a mask, as a
  constructor's fields are, which every runtime walk has to learn.
- **The cost of returning memory to its owner** on every free across
  threads (one load, as mimalloc's), unmeasured.
- **Whether a slice is two words or three.** Two (a root, a 32-bit
  offset and length) keeps a record of a slice and a field a small
  value; three (Roc's and Go's) saves a load a read.
- **Snapshots under load.** How a CPU-bound task that never suspends
  reports quiescence (counted poll points), and whether a publish can
  avoid writing counts that readers read: counted versions fall to 80%
  of borrowed reads at a publish every 10 µs, as `Arc` does.

A storage engine, the flagship in [vision.md](vision.md#what-ren-is-for),
needed four designs. Two are now decided, and two are open:

- **Views into buffers: decided,** as slices that are values (decision
  17). The view that needs no lifetime is one the compiler finds.
- **Reads that take no lock: decided,** at three levels (decision 10):
  `snapshot`'s reads, measured near Rust's arc-swap; sharded and striped
  state; and `Atomic` fields, sequentially consistent, with weaker
  orderings in `trust`.
- **Explicit layout,** open, for formats on disk and on the wire: field
  order, alignment, byte order. A type that declares one opts out of the
  layout the compiler may choose (decision 16).
- **Control over allocation,** open: memory allocated up front, and the
  guarantee above. Arenas are decided (decision 10), as a tool for
  sharing, not an allocator.

## Where it came from

Four complete designs were written against seven benchmarks: batching, a
channel with `select`, a retry around a transaction, a server's graceful
shutdown, a merge that changes outer variables, a refresh task, and
deterministic tests with a production journal. Four judges scored them
for ergonomics against Effect, what the optimizer gets, simplicity, and
testing. Three threads then checked this record's riskiest parts:
dispatch as tagged unions, locks on many cores, and exclusivity, with 38
adversarial programs. Two sweeps checked what blocks lose, one against
Effect v4's modules. Then stage 10c built the blocks decisions, and the
native slice measured the memory and dispatch bet against Rust and Go;
six experiments on it (arrays in loops, `map`, reuse, frames, the header
and allocator, counting across cores) and one on release builds gave
the numbers decisions 2, 4, 10 and 13 to 16 were amended from. Nine
research spikes followed, on freezing, arenas, one runtime model, reads
that take no lock, slices, dispatch over descriptions, combinations of
types, compressed references and the debug backend, and three programs,
a task runner, a bank's HTTP API and a key-value store, were written
against the whole record; decisions 3, 4, 7, 10, 13, 14, 15 and 17 come
from them.

It leans on Effect, Koka, Effekt (second-class blocks), Roc (lambda sets
and their split between builds, seamless slices), Swift (exclusivity,
task allocation, and actor reentrancy, as what not to do), Hylo, Lean
(counts marked shared), Verona (lock ordering), Zig (`Io` passed in,
`inline else`), Linux's RCU and BEAM (quiescent-state reclamation),
mimalloc (frees returned to their heap), TigerBeetle and FoundationDB
(simulation).

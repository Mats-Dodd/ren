# Foundations: blocks, dispatch, tasks and memory

This is the design record for how Ren treats functions as values, how a
call finds its code, how tasks run on many cores, and what that gives the
compiler. It was decided on 2026-10-26, after the research and design
rounds summarized at the end. It reverses parts of [deps.md](deps.md),
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
one-compare uniqueness check.

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
set. A call to an operation of `D` is one of two things:

- **Direct**, where the handler is known: almost every `with`, after
  specialization. It inlines.
- **A switch over that set**, where the handler was chosen at run time,
  in an `Array<Shape>`, a router, or from config. Every arm is visible,
  so arms inline and the compiler can prove some can't happen. A
  dependency with one handler in the program has no tag at all.

A description is a tag and up to three words of captured data, with
anything larger or recursive boxed, in every build. Debug builds make the
tag a pointer to a record of the handler's functions, so each module
compiles alone. That's a vtable, but debug evidence already is one.
Release builds number the tags and narrow the layout to what the program
has.

**The promise:** release has no hidden or open-ended indirect calls.
Every dispatch is direct or a switch the compiler can see through, and
anything else is named in a build note. A switch with many arms compiles
to a jump table, which costs a branch like a vtable call. The wins are
the inlined arms, no allocation, and the single-handler case.

- Release may clone a `with`'s body for each handler a runtime value
  could be, when there are four or fewer and the code fits a budget, and
  never across a suspension. Otherwise it switches on each call.
- An optional release-only analysis narrows which handlers reach a
  parameter or field. It's invisible to typing and never runs in debug.
- Polymorphic recursion that makes descriptions without bound is an
  error, as in Embedded Swift.
- `ren build --explain-dispatch D` lists the handlers and every switch.

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
  `race(a, b)`, which returns the first success. `with` installs only
  handlers.
- **`Async.map` over a block that uses no dependencies runs on every
  core.** There's no `par_map`.
- **`handler ... over any`** intercepts every operation of a dependency:
  `call.forward()` at most once and never stored, `call.args` and
  `call.result` for recording, `call.fail(e)` with only the operation's
  declared errors. `limit`, the recorder, replay and fault injection are
  Ren code.
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

- **A handler operation runs alone until it suspends.** Across threads
  that's a lock per handler instance. A thread never holds one while its
  task is parked, so a plain lock does, about 5 to 20 ns uncontended.
- **The lock is skipped unless the instance is shared.** Spawning a task
  marks the handlers it can reach. A handler with no `var` and no
  `let` of a C or opaque type needs none. The real world handlers lock
  per file.
- **No deadlock.** An operation can only call handlers installed outside
  it, so locks are always taken inner to outer. That holds with two
  rules: a block passed to an operation gets dependencies only from its
  parameter's type, and handlers in one `with` can't use each other in a
  cycle.
- **Counts are atomic only on shared objects.** An object a task keeps
  from its capture, the state of a shared handler, or a value written
  into it, is marked shared, as Lean does. Borrows across tasks touch no
  counts.
- **Immutable handler state is free to read from any core.** A handler's
  `let`s and parameters live as long as its `with`, and no task outlives
  that, so tasks read and copy from them without counting. Only the
  `with` body's result is copied out when it ends.
- A hot handler with state is a queue. Keyed handlers, one instance per
  key, shard it.

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
  pass evidence, blocks are a pair of pointers. Each module compiles
  alone and incrementally.
- **Release specializes** in a whole-program back half, cached by
  content per function and specialization.
- Nothing in the front half is whole-program. That's the rule that keeps
  the edit loop fast, and why lambda sets leave the type checker.

## What's given up

- **Stored closures.** Grammars, schemas and routers built at run time
  become enums with an interpreter, or handler descriptions. A pull
  adapter can't carry user code, and turning a recursive producer into a
  pull sequence needs a task.
- **Multishot continuations.** No backtracking or probabilistic
  programming as a library. `gen` and async are built in.
- **An open world.** No Ren code loaded after compiling.
- **Some `both(fn() => a += 1, fn() => b += 1)`.** It's safe, but needs a
  "runs once" marker, deferred.
- **Free sharing of changing data across cores.** A shared handler with
  state costs atomics and a lock; immutable handler state doesn't.
- **Release build time.** Specializing costs what it costs in Rust, paid
  only in release.

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
dependencies where it's called.

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
| `race` takes the first to finish; `retry(n)` retries any error | First success; `retry(n, on: Tags)` |
| The journal has no task column | A task path column, answers keyed by task |

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
   2 and rule A, with ordinary the only parameter mode. Rules B to D
   land with 11a, which makes concurrent and spawned parameters.
2. **10d, descriptions.** Generic dependencies; handler descriptions as
   the only stored code, inline handlers, stateless handlers as methods;
   `over any`; `retry(n, on:)`.
3. **11a, tasks.** Rules B to D; `Async.scope`, `spawn` and its handle,
   keyed spawn, `until`, `tick`, `yield`, `timeout`, `race`, `isolate`;
   the runtime as a handler with `single` and `sim`; the tape, poll
   points, task paths, journal version 2, journals as tests with a
   schedule prefix; the standard library's channel, semaphore and
   `Batcher`.
4. **11b, many cores.** `work_stealing`, `per_core` and `pinned`; handler
   locks and the shared mark; atomic counts on shared objects; immutable
   handler state read without counting.
5. **11c, generators** and the stream library on them.
6. **Native, stages 13 and 14.** The task frame allocator, specialization
   per block and per handler, the dispatch switches and the build notes.

The interpreter runs tasks on OCaml effects throughout, so 10c to 11c
need no native code.

## Open questions

- How a cursor that borrows its input would work without lifetimes, if
  owning turns out too costly.
- The size budget for cloning a `with` body per handler.
- Whether `both` gets a "runs once" marker.
- What a runtime written by users looks like.

## Where it came from

Four complete designs were written against seven benchmarks: batching, a
channel with `select`, a retry around a transaction, a server's graceful
shutdown, a merge that changes outer variables, a refresh task, and
deterministic tests with a production journal. Four judges scored them
for ergonomics against Effect, what the optimizer gets, simplicity, and
testing. Three threads then checked this record's riskiest parts:
dispatch as tagged unions, locks on many cores, and exclusivity, with 38
adversarial programs. Two sweeps checked what blocks lose, one against
Effect v4's modules.

It leans on Effect, Koka, Effekt (second-class blocks), Roc (lambda sets
and their split between builds), Swift (exclusivity, task allocation,
actor reentrancy), Hylo, Lean (counts marked shared), Verona (lock
ordering), Zig (`Io` passed in, `inline else`), TigerBeetle and
FoundationDB (simulation).

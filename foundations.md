# Foundations: blocks, dispatch, tasks and memory

This is the design record for how Ren treats functions as values, how a
call finds its code, how tasks run on many cores, and what that gives the
compiler. It was decided on 2026-10-26, after the research and design
rounds summarized at the end, and amended on 2026-10-27 with what the
native slice measured: decisions 14 to 16 are new, and 2, 4, 8, 10 and
13 changed. It reverses parts of [deps.md](deps.md),
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
  that uses such an operation is specialized per type, since sharing it
  would need a dictionary of indirect calls.
- A whole-program size budget may make a call box its arguments
  instead; that's a dispatch, so it's reported as a build note, never
  silent.

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

An isolated block can't change a variable from outside it: it returns
its result, and anything else it changes, it changes through a
dependency operation. So nothing the block wrote after the fault can be
seen, which is what lets arithmetic report its panic late (decision 15).

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
- **The scope is the region.** What a spawned block captures lives in
  the frame that called `Async.scope`, and a handler's `let`s and
  parameters live as long as its `with`; no task outlives either. So
  tasks read them as borrows, which count nothing, and that state is
  **frozen** for the region's lifetime: its counts are set to a value
  nothing changes (Lean's persistent objects), so a copy inside a task
  costs nothing either. When the region ends its counts are restored.
  What leaves it, a task's result or a value stored somewhere that
  outlives it, is **copied out**, deep, where it points into frozen
  state.
- **Freezing is the runtime's job, and costs a walk.** Marking and
  restoring walk the frozen data, so it happens only where data really
  crosses cores: never under `single()` or `sim`, for what crosses cores
  under `per_core()`, and when a task is stolen under `work_stealing()`,
  not when it's spawned. Most tasks are never stolen.

The native slice measured why this matters: an object counted from 8
threads at once scales as Rust's `Arc` does, which on data hot in cache
falls to 2 to 12% of one thread's throughput; borrowed or frozen, the
same data scales to the machine's limit. Marking objects shared costs 1
to 4% on one thread. What still collapses, and the documentation names
as traps: many tasks updating one shared map by copying its path, a
small value copied per request from state that isn't frozen, and values
read out of a shared handler's `var` state.
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
  pass evidence, blocks are a pair of pointers, and small values
  (decision 14) are boxed where they meet generic code. Each module
  compiles alone and incrementally.
- **Release specializes** in a whole-program back half, cached by
  content per function and specialization.
- Nothing in the front half is whole-program. That's the rule that keeps
  the edit loop fast, and why lambda sets leave the type checker.
- **The debug backend isn't clang.** Measured, Ren's front half runs at
  about 40,000 lines a second on one core, and clang -O0 on the one C
  file it writes is 77% of a debug build. So debug builds get tcc or a
  backend of Ren's own, C (or code) per module compiled in parallel, and
  a cache keyed by each module's content, so an edit rebuilds what it
  touched. Release keeps clang, per module or partition, in parallel.

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
- **What never escapes lives in the frame.** In release builds, an
  object that isn't returned, stored or raised, and is only lent to
  parameters that keep nothing, lives in its function's frame, and a
  function that returns one object it builds can build it in its
  caller's. Second-class blocks make a call through a block as clear to
  this analysis as a direct one, which Go can't see through. Measured,
  this applies where a program has temporaries, and rarely in code that
  builds structures, which keeps what it builds; small values as values
  cover more.
- **Reuse goes deep.** Reuse follows Koka: a node that dies drops and
  reuses the nodes inside it too, a small builder (`balance`) is inlined
  where a freed node can go into what it builds, and a rebuild writes
  only the fields that changed. A persistent red-black tree allocates
  one node an insertion, as a mutable one does. It's an optimization,
  not a guarantee.
- **Taken from Lean and Koka, still to build.** An element taken out of
  an array while it's changed, so `grid[i][j] = x` and a `map` over
  arrays of arrays change the inner arrays in place (Lean's swap-out);
  scalar fields packed together after the object fields (Lean); and
  recursion that builds a structure after its call compiled to a loop
  (Koka's tail recursion modulo cons).
- **The runtime:** an 8-byte header (a 32-bit count, its sign the
  shared mark, a tag and the field mask) and an allocator with free
  lists per size, which made every allocating benchmark faster than
  Rust's.

### 15. Arithmetic

`Int` and `Float` are the only types arithmetic is done in. A fault
still panics; the rules say where it may be reported, so loops can
vectorize.

- **Overflow is reported late, in loops with no effects.** In a loop
  whose calls all have an empty `uses` row, an `Int` overflow may be
  reported when the loop leaves, or at the end of each run of 1,024
  iterations, instead of where it happens. A pending overflow is
  reported before any other panic, so the panic is the same. Nothing
  the loop wrote after the overflow can be seen: it made no dependency
  calls, the program then ends, and an isolated block can't change outer
  variables (decision 8).
- **Wrapping operators** `+%`, `-%`, `*%` wrap at their operands'
  width, for hashes, checksums and random number generators.
- **A NaN is checked where it's observed, not where it's made.**
  Arithmetic and stores carry it; comparing it, `match`ing on it,
  converting it to an `Int` or a `Str`, hashing it, or passing it to a
  dependency operation panics. So no program acts on a NaN, and none
  reaches the journal. Debug and release builds check at the same points;
  a debug build's message also says where the NaN was made. Measured,
  checking every operation was 31% of nbody's cycles.
- **Sized integers are for storage.** `Int8`, `Int16`, `Int32`, `UInt8`,
  `UInt16`, `UInt32`, `UInt64` and `Float32` are types of fields and
  array elements. Reading one gives an `Int` (or `Float`); storing into
  one checks that it fits. The wrapping operators work at their width:
  `h *% 16777619` on a `UInt32` wraps at 32 bits. Where the compiler
  proves values fit, a loop computes in narrow lanes.
- **`Float` arithmetic keeps its order.** A sum of `Float`s that a
  vector unit adds in lanes would depend on the machine's width, and a
  journal recorded on one machine has to replay on another. So
  `xs.sum()` on `Float`s is defined as a fixed tree, eight lanes added
  pairwise, the same on every machine, which also vectorizes and is
  more accurate than adding left to right.

### 16. Loops

- **Loops that don't index don't check bounds.** `for x in &xs`,
  `for i, x in &xs` (the index and the element), and `zip` over several
  arrays, a cursor, compile to one bounds check per loop. Other indexing
  is checked, and range analysis removes what it can.
- **The compiler may choose an array's layout.** Arrays are values, and
  nothing hands out a pointer into one's elements, so an array of
  records could be stored as one array per field, which vectorizes. Not
  built; no feature may give out such a pointer.
- Explicit vector types, as Zig's `@Vector`, come later if loops need
  them.

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
  only in release. Measured, the code grows linearly and the time is
  clang's; what grows like Rust's, generic code making generic code at
  new types, wasn't measured yet.
- **Arithmetic in sized types.** Sized integers are for storage; wrapping
  operators are the only arithmetic at a width.
- **Pointers into arrays,** and outer variables changed by an isolated
  block.

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
| An `Int` overflow panics where it happens | In a loop with no effects, it may be reported when the loop leaves |
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
   **Follow-ups, next:** the release build's four quadratic costs;
   panic messages interned; specialization without the per-function cap
   (decision 4); small values as values, packed scalar fields, swap-out
   and tail recursion modulo cons (decision 14); late overflow, wrapping
   operators, NaN where observed, sized storage integers and `Float`
   sums (decision 15); `for i, x in &xs` and `zip` (decision 16); and
   the loops that then vectorize, measured.
3. **10d, descriptions.** Generic dependencies; handler descriptions as
   the only stored code, inline handlers, stateless handlers as methods;
   `over any`; `retry(n, on:)`.
4. **11a, tasks.** Rules B to D; `Async.scope`, `spawn` and its handle,
   keyed spawn, `until`, `tick`, `yield`, `timeout`, `race`, `isolate`;
   the runtime as a handler with `single` and `sim`; the tape, poll
   points, task paths, journal version 2, journals as tests with a
   schedule prefix; the standard library's channel, semaphore and
   `Batcher`.
5. **11b, many cores.** `work_stealing`, `per_core` and `pinned`; handler
   locks and the shared mark; atomic counts on shared objects; scopes and
   `with`s as frozen regions, frozen by the runtime, with copy-out;
   a heap per thread.
6. **11c, generators** and the stream library on them.
7. **Native, stages 13 and 14.** The task frame allocator, the dispatch
   switches over descriptions and the build notes; the debug backend
   that isn't clang, and modules compiled in parallel and cached by
   content. Specialization per block and per handler is built (item 2).

The interpreter runs tasks on OCaml effects throughout, so 10c to 11c
need no native code.

## Open questions

- How a cursor that borrows its input would work without lifetimes, if
  owning turns out too costly.
- The size budget for cloning a `with` body per handler.
- Whether `both` gets a "runs once" marker.
- What a runtime written by users looks like.
- What freezing's walks cost on a realistic shared structure, against
  how often tasks are stolen.
- How specialization grows on generic code that makes generic code at
  new types, which is what makes Rust's grow.
- Whether choosing an array's layout (decision 16) pays, and when.
- **Allocation the compiler guarantees.** Reuse and frames are
  optimizations (decision 14): `ren build --explain-alloc` to show
  which allocations were reused, framed or kept, and a Koka-style `fip`
  marker that makes a function that would allocate an error, for hot
  paths.

A storage engine, the flagship in [vision.md](vision.md#what-ren-is-for),
needs four designs that don't exist yet:

- **Views into buffers.** Parsing a record out of a page without
  copying it is where Rust's lifetimes pay. Ren's likely answer is the
  trick blocks use, applied to data: a view (an array, an offset and a
  length) is second-class, lent to a call and never stored or returned,
  so it needs no lifetime. It's the same question as a cursor that
  borrows its input, and it may touch the exclusivity rule, so it's
  the first of the four to settle.
- **Explicit layout** for formats on disk and on the wire: field order,
  alignment, byte order. A type that declares one opts out of the
  layout the compiler may choose (decision 16).
- **Control over allocation:** arenas, memory allocated up front, and
  the guarantee above.
- **Reads that take no lock.** Storage engines read hot structures with
  RCU, seqlocks and atomics. A frozen region is close to RCU's read
  side, and publishing a new snapshot is a handler operation; whether
  that's fast enough for a hot index is unmeasured. `trust` and C are
  the fallback.

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
the numbers decisions 2, 4, 10 and 13 to 16 were amended from.

It leans on Effect, Koka, Effekt (second-class blocks), Roc (lambda sets
and their split between builds), Swift (exclusivity, task allocation,
actor reentrancy), Hylo, Lean (counts marked shared), Verona (lock
ordering), Zig (`Io` passed in, `inline else`), TigerBeetle and
FoundationDB (simulation).

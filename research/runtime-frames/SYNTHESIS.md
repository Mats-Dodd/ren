# Runtime frames research: synthesis

This pulls together seven prior-art tracks on how Ren compiles code that can
suspend, and what runs under it:

- [r1-colouring.md](r1-colouring.md): colouring by inference (Zig, Koka,
  Effekt, OxCaml, Go, Lean 4, Roc, and the explicit colours of Swift, Kotlin
  and Rust)
- [r2-stackless-frames.md](r2-stackless-frames.md): stackless frames emitted
  as C (Swift's async lowering, C++20 coroutines, Kotlin, Rust's poll, the
  C-hosted systems), with fast-path measurements
- [r3-stackful-vs-stackless.md](r3-stackful-vs-stackless.md): idle memory,
  migration, WASM, backtraces and profiling, with measurements
- [r4-frame-allocation.md](r4-frame-allocation.md): Swift's task allocator,
  LIFO under Ren's generators and scopes, sizing
- [r5-short-locks-and-cancellation.md](r5-short-locks-and-cancellation.md):
  locks for handlers that never suspend, and cancellation only at scheduling
  points
- [r6-drivers-in-language.md](r6-drivers-in-language.md): drivers written in
  the language itself (Go's netpoller, TigerBeetle, Zig `std.Io`, tokio,
  monoio, glommio, Seastar)
- [r7-foreign-calls.md](r7-foreign-calls.md): `foreign fn` and `blocking
  foreign fn` (Zig, Rust, cgo, Swift, Koka, Lean, OCaml 5, Inko, Pony)

It builds on [research/runtime/SYNTHESIS.md](../runtime/SYNTHESIS.md) (below,
"runtime SYNTHESIS") and doesn't repeat it. It reviews the four proposals in
the brief:

1. plain or suspending, decided per specialization;
2. stackless frames on a per-task LIFO frame stack;
3. drivers are Ren;
4. `foreign fn` and `blocking foreign fn` in `trust`.

Where two tracks disagree, this file says so and picks one. The section
"Citations checked" at the end lists what I re-read in source myself.
Measurements "here" were taken on the owner's M4 Max, shared with other
agents at a load average of 3 to 11, so read them as ratios.

## The verdict in one paragraph

The shape is right, and the prior art supports it more strongly than
expected. Stackless frames win on every axis that matters to Ren, and
decisively on WASM: the hand-lowered prototype runs on plain wasm32 at 1.5×
native, where Asyncify adds 55% to code size and 15 to 49% to code that never
suspends (r3 §4). The trampoline beats Rust-style re-polling by 2.6× at depth
16 (r2 §6), no `musttail` is needed (which matters, since tcc ignores it), and
the frame stack is LIFO for everything except a pulled recursive `yield
from`. Drivers really can be plain code: no driver studied ever suspends. But
proposal 1 conflates two things. **A scheduling point**, where the runtime may
act, is meaning: `sim` draws from its tape there, the journal records there,
and cancellation lands there. **A colour**, whether a call may return
PENDING, is only a calling convention. Points must be the same set in every
build and under every scheduler, or a seed from a debug build won't replay in
release. Colours may differ. Once that's split, three of the proposal's
sentences are wrong as written: "taking a handler whose operations never
suspend is a short lock, never a suspension" (it hides the between-operation
races `sim` is promised to find, and makes decision 10's parked waiters
impossible); "a test fake compiles to plain code" (only a stateless or
unshared one); and the implied claim that debug builds can colour per
specialization (they don't specialize). Separately, the prototype's calling
convention is the wrong one to emit: it costs 3.4 ns a level against 0.4 ns
for a register convention (r2 §6). Proposals 3 and 4 hold up, with additions:
three more pieces in the non-Ren core, a closure form of `blocking`, and
typed rules for callbacks.

---

## 1. Proposal 1: plain or suspending, per specialization

### Confirmed

- **Colouring after specialization is what Koka does.** It specializes first
  (`koka/src/Compile/Optimize.hs:93`) and decides which functions to
  transform second (`:114`), by effect type: an open effect tail means
  transformed (`koka/src/Core/Core.hs:856-863`). Its cost on the path that
  doesn't yield is one branch after each effectful call
  (`koka/kklib/include/kklib.h:470-475`, checked). Ren's version is the same
  idea at a coarser grain: a frame, not a branch, and only where a scheduling
  point is reachable.
- **It's Asyncify's analysis.** Asyncify instruments only functions that can
  reach an import that may unwind, propagating backwards through the call
  graph (`binaryen-asyncify/Asyncify.cpp:535-661`), and its weak spot is
  indirect calls (`canIndirectChangeState`, `:537`). Ren's closed world
  (decision 4) removes that weak spot in release.
- **What killed Zig's inferred colours isn't present in Ren.** Zig's stage-1
  async inferred a function's colour and frame size, and broke on function
  pointers in an open world (`callconv(.Async)`), on recursion, and on
  debugging (r1 §1, from the web: zig#6025, #23367). Zig's replacement,
  `std.Io`, is stackful fibers behind a vtable, and its io_uring fibers now
  reserve 60 MiB each (`zig-cb/lib/std/Io/Uring.zig:256`). Decision 4 leaves
  Ren one indirect call, the C function pointer in `trust`, which is always
  plain (below).
- **Plain code never spans a suspension,** so a parked task has nothing on any
  native stack and can move between workers (r3 §3). That falls out of the
  lowering, not out of a rule anyone must remember.
- **Cancellation only at scheduling points, and no preemption,** matches
  every cooperative system studied: Trio, Swift, Kotlin, Eio, tokio
  (r5 §10-14).

### Wrong

**1a. Scheduling points and colours are two things, and the proposal makes
them one.** compiler.md already defines points by meaning, finer than the
row: "a scheduling point is each place a task can wait, and each call of an
operation of a shared, exclusive instance … before the call"
(`compiler.md:4505-4507`, checked), with sharing marked at run time by `spawn`
(`compiler.md:4700-4704`). If points followed colours instead, they'd differ
between debug and release (debug can't specialize), between `sim` and
`single`, and between a fake and a real handler. Then:

- a `sim` seed would draw from its tape at different places in each build, so
  a seed found in debug wouldn't reproduce in release;
- a journal recorded in one build wouldn't replay in the other;
- runtime SYNTHESIS §2.8's counted budget, which `single` replays with no
  journal entry, would count differently.

**Fix: define the points by meaning, the same in every build and under every
scheduler, and let a colour over-approximate them.** The points are:

- a world call (`Async.submit`);
- an `Async` wait: `until`, `yield`, `tick`, a scope's end, room in a scope or
  in a bounded queue;
- `release`;
- a call of an operation of an instance that is **shared** (the run-time mark)
  and **exclusive** (its handler keeps state).

A function is suspending-coloured if it can reach one. The runtime acts only
at points, so code compiled as suspending that reaches no point never sees
the runtime. Decision 12's sentence "only a function whose `uses` reaches a
dependency can suspend" becomes a description of the debug colour (r1 §9.0).

**1b. "Taking a handler whose operations never suspend is a short lock, never
a suspension" is wrong for shared instances.** async.md's own example shows
it (r5 §9.3):

```ren
fn deposit(n: Int) uses Account =
  let b = Account.balance()
  Account.set(b + n)       // another task's deposit can come in between
```

Under the proposal, `Account`'s operations never suspend, so `deposit` is
plain, with no point between the two calls. On `per_core`, another worker's
task can take `Account` there, and the lost update happens. Under `sim`,
built with the same colours, nothing can run there, so the race async.md
promises "the test scheduler finds" is never found. And decision 10 says
waiters "queue for the instance as tasks: a thread never blocks while its
task is parked" (foundations.md:536-538), which a plain caller can't do: it
has no frame to park.

The two tracks split on the fix. r5 keeps the short lock in release and makes
shared takes points only in `sim` and debug builds. r1 colours a
may-be-shared exclusive take as suspending in every build. **I side with r1,
on numbers r5 didn't have.** r5 rejected the frame because the prototype's
nested call measured about 31 ns, 20× the 1.4 ns lock. r2 then showed that
cost is the prototype's calling convention, not the frame: with the register
convention a suspending call that doesn't suspend costs 0.4 ns a level over
plain C at -O2 (r2 §6). At that price, colouring shared takes as suspending:

- keeps one point set and one colouring under every scheduler, so `sim` tests
  the code that ships (r1 §9.1);
- keeps decision 10's rule true: on contention, the take spins briefly and
  then parks the *task*, so a long hold (r5 measured a waiter starved for 16
  to 75 ms behind a 100 µs holder with an unfair parking lock, or a whole
  core burned spinning) queues tasks instead of stalling every worker that
  touches the instance;
- costs a CAS (1.4 ns, r5 §8) plus about 0.4 ns a frame level when
  uncontended.

What it costs instead: most server code becomes suspending, since a handler
installed in `main` above `Async.each` is may-be-shared. That's more resume
functions and spill paths in the binary. Experiment X3 below measures it, and
if code size or speed suffers, r5's split (thread lock in release, a point in
`sim` and debug) is the fallback. Either way, r5's rules S1 and S2 stand: the
holder of a take whose operations can't suspend never parks (assert it), and
the take is one CAS storing the worker id, so a same-worker hit is decision
10's "a task taking an instance it already holds panics" at no cost.

Under `single`, the take still can't be contended unless an operation of that
instance holds it across a suspension, so the point is a flag test that does
nothing (`compiler.md:5349`). The frame is paid and never used. That's the
price of one colouring for `sim` and production.

**1c. "A test fake (e.g. a frozen Clock) compiles to plain code."** True for a
fake with no `var`, or one no spawned task reaches. A stateful fake that tasks
share (`sim.clock()`, a counter) is a point by 1a, under every runtime. Say
so, or readers will expect every fake to be free (r1 §9.5).

**1d. Debug builds can't colour per specialization.** They pass evidence,
dictionaries and code-and-frame-pointer blocks (decision 13). A call through
evidence can't know whether the handler at the other end suspends. See 1e's
debug rule.

### Missing

**1e. The debug colour (r1 §9.3).** Colour by the row, with three details:

- A function is suspending if its inferred row has a concrete dependency, or
  if it calls a block or function parameter whose row is open. **Not "if its
  row is open":** every Ren function type ends in `..d`, so Koka's test would
  colour every function.
- Every evidence entry uses the suspending convention. A plain handler gets an
  adapter that runs it and returns DONE, with a frame size of 0. That's
  Swift's implicit conversion from sync to async, done as an adapter.
- A plain caller may call a suspending-convention callee when the block it
  passes has a closed, empty row: `map(xs, fn(x) => x + 1)` can't return
  PENDING, so the caller asserts DONE. That keeps the `Mem.snapshot` rule
  ("no code reached from a call with an empty row runs a scheduling point")
  true by typing, in both builds.

Measured with tcc: the adapter adds 1.9 ns a call, and a callee that pushes
its own frame adds 6.1 ns. Over the repo's examples and benches, about a third
of static call sites would use the suspending convention (r1 §9.3). The
alternatives were two entry points per function, which is Swift's `reasync`
answer (`swift-evolution/proposals/0533-reasync-macros.md:738-757`) and
doubles the C that tcc compiles, or real stacks per task in debug only, which
measured 18 ns a round trip against 15.8 for stackless, gives ordinary lldb
backtraces, and puts two kinds of task in the core. Row colours are the
recommendation; real stacks are the experiment if lldb proves painful.

**1f. Recursion: least fixed point over strongly connected components** of the
specialized call graph. A component is suspending if any member reaches a
point. `f` calling only `f` is plain. That's Roc's algorithm on
specializations (`roc/design.md:1181-1222`). It's finite because unbounded
polymorphic recursion is already an error (decision 4).

**1g. C function pointers and callbacks.** A C function pointer is always
plain: C can't return PENDING. A Ren function given to C must have a closed,
empty row, checked by type in both builds, not "plain after specialization",
which debug can't know (r1 §9.6). That covers r7's three cases at once. A
callback that needs the world posts a completion to a standing world call
(decision 11). Swift refuses `async` C entry points outright (r7 §4, checked
with Swift 6.0.3).

**1h. Colour is part of the specialization's identity.** Sharing per layout
(decision 4) and release's cache must key on it. A table call with more than
four arms uses one convention for all arms, adapting the plain ones, and
`--explain-dispatch` should say which (r1 §9.4). An edit that makes a leaf
call `Clock` recolours its callers up to `main`, the same cascade inlining
already causes (r1 §9.7).

**1i. Wording that has to change elsewhere:**

- runtime SYNTHESIS §2.8: the budget counts **points** as 1a defines them,
  never suspending-convention calls. Its motivating example, "a loop of
  `memtable.put` never yields", needs restating: a `put` on an instance no
  spawn reaches is now plain, so that loop has no points at all, and the
  budget can't see it (r5 §15).
- async.md:397, "it happens at dependency calls", becomes "at scheduling
  points" (r5).

---

## 2. Proposal 2: stackless frames on a per-task LIFO frame stack

### Confirmed

- **Stackless over stackful, on Ren's axes** (r3 §8):
  - **WASM, decisively.** The prototype runs unmodified on wasm32 at 1.52 to
    1.58× native. Asyncify on the same module costs +55% size and 15 to 49%
    on code that never unwinds; stackful coroutines built on Asyncify cost
    about 32 ns a switch plus 34 to 130% on every instrumented function
    (measured, r3 §4).
  - **Switch.** A minimal hand-written arm64 stack switch is 18.5 to 32.9 ns a
    round trip; the prototype's channel round trip, operations included, is
    16.2 ns (r3 §2). Stackful isn't faster even at its floor.
  - **Idle memory.** Measured here: an OCaml 5.4 fiber 757 B, a Swift task
    1,483 B, an idle Go TCP goroutine 4.2 KB of stack (r3 §1). The prototype's
    parked task is 128 B. For flottning the win is 2 to 3× in total, not 30×,
    because the kernel's own socket state is the floor (r3 §1.7; that figure
    is from memory).
  - **Migration.** Nothing is on a native stack at a suspension, so there are
    no stack maps to keep and nothing to pin.
- **The trampoline, not re-polling from the root.** At depth 16 with eight
  wakes an operation, Rust-style re-polling took 275 ns against 102 to 105 for
  the trampoline (r2 §6). tokio polls from the task's root on every wake
  (`tokio/tokio/src/runtime/task/core.rs:365-387`).
- **The C stack stays bounded, with no `musttail`.** Every suspension returns
  PENDING to `step()`, and every resume starts a fresh call from it, so the C
  stack is `step()` plus the deepest chain of inline completions: measured
  constant over 2M resumes (r2 §7). Swift needs `musttail`
  (`swift/lib/IRGen/IRGenModule.cpp:575-582`) because its callees return by
  tail-calling their parent's continuation. Ren has a direct-return fast path,
  so it doesn't. That matters, because **tcc accepts `musttail` and ignores
  it**: mutual recursion with it segfaulted under tcc (r2 §7).
- **Swift ships this allocator, and enforces LIFO with a fatal error:**
  "freed pointer was not the last allocation"
  (`swift/stdlib/public/runtime/StackAllocator.h:401-412`, checked). Swift
  keeps LIFO by structure: `async let`'s child lives in space reserved in the
  parent's frame (640 B, `swift/include/swift/ABI/MetadataValues.h:69`), and
  group children are separate tasks. Ren's scopes map onto that exactly
  (r4 §1).
- **Generators keep LIFO, because `yield` appears only in a generator's own
  body** (`streams.md:322`, checked). At a yield none of the generator's callee
  frames is live, so pulled generators, zipped or not, are fixed slots that
  are never above the stack top across a yield (r4 §3's table).
- **A cancel flag per task, set by an eager walk,** read with one load at each
  point, checked before a call starts and never after its result. Swift
  (`swift/stdlib/public/Concurrency/TaskStatus.cpp:1449-1475`), Trio
  (`trio/src/trio/_core/_run.py:477-503`), Eio
  (`eio/lib_eio/core/cancel.ml:134-146`) and Go's context all walk eagerly, and
  Ren must visit parked tasks anyway to cancel their calls (r5 §17).
- **A shielded `finally` under a deadline, on by default.** No other system
  has both by default: Trio composes them, and Swift added shields only in 6.4
  (SE-0504), without a deadline (r5 §16).

### Wrong

**2a. The prototype's `CALL` must not be what release emits.** It costs
3.4 ns a level against plain C's 0.8 at clang -O2, and the cost isn't the
frame bump. It's memory traffic through the task: the result goes through
`t->result`, `t->top` is stored twice a call, `t->sp` is loaded and stored,
and locals live in the frame (r2 §6;
`experiments/runtime-p2/switch/c/ren_single.c:124-145, 323-331`).
**Fix: a register convention,** `ren_ret fn(task*, frame*, char *sp,
uint64_t in)` returning `{status, value}` in two registers:

- `sp` is a C local passed down; callee frames bump from it;
- locals are C locals, spilled to the frame only on the way out of a
  suspension and reloaded at a cold dispatch;
- headers (`resume`, `parent`) are written only on the PENDING path;
- only the innermost suspender writes `t->top`.

That costs 0.4 ns a level over plain C (20.0 against 14.0 ns at depth 16),
against Swift's 7 and C++ coroutines' 23 without heap elision (r2 §6). Under
tcc every convention is slow and they're within about 15% of each other, so
one convention serves both builds.

**2b. The frame header.** Drop `task`: it's always an argument. Replace
`size` with a saved `sp`, so a frame's stack top is what it saved, not its
address plus its size. Add a `flags` word with a "first in an overflow chunk"
bit, so the trampoline retires chunks without comparing against the task on
every return (r2 §8). That's 32 B: `resume`, `parent`, `state`, `flags`,
`sp`.

**2c. The prototype's `frame_pop` assigns `t->sp = f`**
(`ren_single.c:135-136`). That assumes one stack per task, and silently
corrupts a frame on any other stack (2d). With 2a's convention nothing pops:
a callee's frame disappears when its caller stops using `csp`.

**2d. "A recursive `yield from` that must pull runs on one frame stack the
consumer owns" (decision 12).** Read as the consumer's task stack, it breaks:
a pulled recursive generator keeps its delegation chain alive across yields,
and the chain's length changes at run time. Two zipped tree walkers interleave
their chains on one stack, and the first one to shrink frees memory under the
other (r4 §3). **Fix: each pulled recursive generator owns a private frame
stack, held by its hidden local.** With 2a's per-frame `sp`, two stacks per
task cost the trampoline nothing.

**2e. "Ends once" can't rest on the frame's terminal state.** A finished frame
is reused at the same address by the next call, so a stale resume aimed at its
pointer would run someone else's state machine with a plausible state. Swift's
`UnsafeContinuation` has exactly this hole (r2 §9). **Fix: nothing outside a
task holds a frame pointer.** A reply addresses `(task, call id, generation)`,
the core checks the generation, and only then resumes. A terminal state in the
frame is a debug assertion.

### Missing

**2f. A static frame-stack bound per task body.** Release sees the whole
program, so it can compute each task body's deepest chain of suspending frames
when that chain has no recursion across a suspension, and give the task an
inline segment that size, with no bounds checks. Without it, the prototype's
4 KiB overflow chunk (`ren_single.c:101, 113-123`) makes a three-frame idle
connection cost about 4.2 KB, the same as a goroutine (r3 §1.6). Cap the
inline segment at about 256 B, so a rare deep path doesn't fatten every parked
task (r4 §4). Debug has no whole program: use a 256 B default.

**2g. Keep one spare chunk.** The prototype frees an overflow chunk as soon as
it empties, so a call just past the inline segment, in a loop, mallocs and
frees 4 KiB each time: 23.2 against 5.4 ns (r2 §6). Swift keeps emptied slabs
(`StackAllocator.h:71-74, 278-291`). Keep the most recent spare, and free it
when the task parks, so idle tasks stay small. Grow chunks geometrically for
recursion, to 64 KiB.

**2h. Frame sizes the caller can't see.** Through debug evidence, or into a
generic generator's hidden local, the callee's frame size isn't known at the
caller's compile time. **Fix: Swift's async function pointer,** `{resume fn,
frame size}` (`swift/include/swift/ABI/Executor.h:405-414`, checked), as the
code half of every debug block and evidence entry. The caller bumps the size
it reads there, and a plain adapter's size is 0. In release the size is a
constant, and a generator's frame is a field of its consumer's (r4 §3).

**2i. Worker threads need full-size native stacks,** 8 MiB, set explicitly.
Inline completions run on the native stack, and macOS gives secondary threads
512 KiB by default (r2 §7; that figure is from memory). This belongs in the
default host's `ren_thread_init`.

**2j. A resume-site table** `{resume fn, state, file, line, fn name}`,
emitted by the compiler as part of the compiler–runtime ABI. It's what a
panic's backtrace, a task dump, `ren bt` in lldb and a sampling profiler need
to name the suspension point, since a sampled native stack shows only
`step()` and the innermost resume function. With it, a task's logical stack is
a walk of `parent` pointers from `t->top`. Swift chains its async contexts the
same way (`swift/include/swift/ABI/Task.h:1077-1094`). tcc's DWARF already lets
lldb print frame structs and walk the chain at Ren source lines (r3 §5). Name
the frame structs in the emitted C, so lldb shows `serve_frame`, not an
unnamed struct.

**2k. Depth limits.** Plain recursion runs on the native stack and suspending
recursion on frame stacks, and debug and release colour some functions
differently, so the same program overflows at different depths in the two
builds. Decision 13 already wants the pushed and pulled forms of a recursive
`yield from` to share a limit. **Fix:** a stack overflow is one panic, "stack
overflow in `<fn>`", in every convention. Give both stacks the same byte limit
(8 MiB), and state that the exact depth isn't meaning (r1 §9.2, r4 §4).

**2l. The `finally` deadline, in detail** (r5 §16):

- it's the `finally`'s own cancel scope, cancelled at 5 s, and armed lazily at
  the first park, since the core reads no clock and most `finally`s never
  wait;
- nested `finally`s inside an expired cleanup get no fresh 5 s each;
- a scope opened in a `finally` starts uncancelled, as SE-0504 says;
- plain code in a `finally` overruns the deadline. Document it.

---

## 3. Proposal 3: drivers are Ren

### Confirmed

- **A driver never suspends.** TigerBeetle flushes a full submission queue
  inline (`tigerbeetle/src/io/linux.zig:211-227`), as Zig
  (`zig/lib/std/Io/IoUring.zig:1489-1496`) and monoio do. With Ren's pull ABI
  it's simpler still: the driver pulls only the calls it has room for, so
  leftover calls wait in the core's queue with their tasks already parked. "A
  full ring is a full mailbox" holds, and the waiter is always the task (r6
  §5.1).
- **A driver uses no world dependency, so it's plain** by proposal 1's rules,
  in both builds, as long as `Async.submit` is a core verb and not a dependency
  in the driver's row (r1 §9.6).
- **Writing the driver in the language works, in a restricted dialect.** Go's
  netpoller is Go with five runtime-only escapes: no write barriers, memory
  outside the GC heap, linknamed entry points, raw syscalls on the system stack,
  and atomics on raw words (`go/src/runtime/netpoll.go:74-76, 491-494`). Ren's
  `trust` plus "plain" covers four. The fifth, memory the kernel holds a
  pointer to, is runtime-io.md's "a call belongs to whoever answers it until
  its reply".
- **`Async.submit` and `ren_poll_call` are two halves of one model.**
  `Async.submit` is the point: the core offers the call to `answer_now`
  inline; otherwise it queues the call and parks the task, and the host loop
  pulls it with `ren_poll_call` between `ren_run`s (r6 §5.3). runtime.md should
  say it in one sentence.

### Wrong

**3a. "The host's hooks are leaves" isn't enforceable as written.**
`answer_now` is driver Ren code running inside `ren_run` on a task's native
stack, so "never blocks" and "never calls `ren_*`" are comments. Both the host
loop and `answer_now` are plain, and "plain" means "can't suspend", not "won't
block". **Fix** (r6 §5.3-5.4):

- driver code runs in three contexts with different rules: the host loop (may
  block: that's its sleep), `answer_now` (must not block), and pool threads
  (may block, must not touch tasks). Mark foreign functions `blocking` (r7) and
  reject a `blocking` foreign call reachable from a hook;
- the core handle is a type that isn't data, as instances aren't
  (foundations.md:83-90), so no task or hook can hold it and call `ren_run`;
- `ren_run` asserts it isn't re-entered, in debug builds, as TigerBeetle
  asserts `!run_for_ns_active` (`tigerbeetle/src/io/linux.zig:77`, checked).

### Missing

**3b. Three more pieces in the non-Ren core** (r6 §6):

- **a thread-entry trampoline,** since a thread made by a bare
  `pthread_create` into Ren has no thread context (Go keeps a spare M for the
  same reason, `go/src/runtime/proc.go:1955-1956`);
- **fixed signal dispositions and a crash handler.** User signals arrive as
  `Signal` replies from signalfd or `EVFILT_SIGNAL`, so no Ren code ever runs
  in a handler;
- **teardown order:** `ren_kill` makes the driver close its rings before frame
  stacks are freed, or the kernel writes into freed frames.

**3c. What `trust` must add for a driver:** atomics with explicit orderings and
fences on raw pointers into mmap'd memory (liburing's ring head and tail,
`liburing/src/include/liburing/barrier.h`), C-layout records at fixed
addresses, and plain Ren functions usable as C function pointers for host hooks
and thread entries.

**3d. `main`'s scheduler must be static.** The driver entry wraps `main`, so
the compiler must read `main`'s outermost `with Async.X()` at compile time. A
`main` that chooses its scheduler at run time is rejected in 1.0 (r6 §5.4).

---

## 4. Proposal 4: foreign calls in `trust`

### Confirmed

- **`foreign fn` is a direct C call.** Ren emits C, so it gets the C ABI,
  structs by value and variadics with no marshalling: 1.16 ns a call against
  cgo's 23 to 25 ns (measured here, r7). cgo pays because every call enters a
  syscall state so the P can be handed off (`go/src/runtime/cgocall.go:9-27`).
- **`blocking foreign fn` as a world call answered by the driver's pool.** It
  folds into proposal 1 (the caller reaches a point, so it suspends) and into
  the journal. Every runtime with user-level concurrency marks blocking calls or
  repairs the damage afterwards; Pony did neither and just fixed scheduler
  threads parked in a blocking `read` (`ponyc/.release-notes/0.67.0.md:193-205`).
- **A blocking call can't be cancelled once running.** Retract it while it's
  queued; abandon it at the cleanup deadline (r7 §8.7, runtime SYNTHESIS
  decision 3).

### Wrong

**4a. "A plain foreign call in task code is unrecordable" (runtime SYNTHESIS
§2.10) is too blunt.** Most plain foreign calls are pure: crc32, zstd,
SHA-256, `memcmp`, libm. **Fix: a plain `foreign fn` is pure by `trust`
assertion,** and replay calls it again. C that reads or changes the world
goes through a driver or is `blocking`, and is journaled. `ren why --unsafe`
lists the foreign functions, and a diverging debug replay names the ones on
its path (r7 §8.5).

### Missing

**4b. The closure form.** The prior art's unit of blocking work is a function,
not one C call: tokio's `spawn_blocking(f)`, Eio's `run_in_systhread`. Two
`blocking foreign fn` calls in a row may land on different pool threads, so
errno, OpenSSL's error queue or a thread-bound SQLite connection split across
them. **Fix: `blocking fn`,** a plain Ren function with an empty row and data
in and out, run whole on one pool thread as one world call (r7 §8.1).

**4c. Ownership, in four rules** (r7 §8.2-8.6):

- counted Ren values cross only borrowed, never owned or kept, and the compiler
  keeps them alive until the return, or until the reply for a `blocking` call
  (Lean's `@&`, `lean4/src/include/lean/lean.h:207-211`; Koka passes them owned
  by default);
- C produces data only into a lent `inout` buffer; there's no C API to Ren's
  heap in 1.0;
- a `blocking` result must be data, never a pointer, or replay can't answer it.
  A call that returns a handle is a driver's job, mapped to an id;
- errno is read on the calling thread immediately after the call, as OCaml
  learned (`oxcaml/runtime/signals.c:227-260`), and travels in the reply for a
  `blocking` call. An abandoned call's lent buffers move to a leak list until
  its late reply, or ASan reports a use-after-free (r7 E-F4).

**4d. The pool hop is expensive.** About 5 µs a round trip on macOS when both
sides sleep, 150 ns if both spin (measured here, r7 §9). A `stat` on a warm
cache takes about 1 to 2 µs (from memory). So the driver may run a call it
knows is fast inline through `answer_now`, as compio's `Decision` does, and
`blocking` is never a default.

**4e. Headers.** errno and liburing's API are macros and `static inline`
functions, but decision 13 keeps system headers out of a module's unit. **Fix:
`foreign include "liburing.h"` in a `trust` module compiles in its own unit,**
so only that unit pays, and std ships shims for errno and similar (r7).

**4f. A migration obligation.** A `foreign fn` returns holding no OS lock and
no thread-affine state the rest of the task relies on, since the task may
resume on another worker. Thread-affine libraries go behind a homed service or
`Async.pinned()` (r3, point 4).

---

## 5. The C, as I'd recommend it

One calling convention for both builds (2a). The only differences between
debug/tcc and release/clang are where a frame size comes from and what gets
inlined. These are sketches of the shape, not final names.

### The core's header

```c
typedef struct ren_task  ren_task;
typedef struct ren_frame ren_frame;
typedef struct { uintptr_t st; uint64_t v; } ren_ret;   /* two registers on arm64 and x86-64 */
enum { REN_DONE = 0, REN_PENDING = 1 };
typedef ren_ret (*ren_resume)(ren_task *, ren_frame *, char *sp, uint64_t in);

struct ren_frame {            /* 32 B */
  ren_resume resume;          /* written on the PENDING path only */
  ren_frame *parent;          /* ditto */
  uint32_t   state;           /* 0 fresh; 1..n suspension points */
  uint32_t   flags;           /* REN_FIRST_IN_CHUNK */
  char      *sp;              /* this frame's stack top when it suspended */
};

/* Swift's AsyncFunctionPointer: the code half of a debug block or evidence entry. */
typedef struct { ren_resume fn; uint32_t frame_size; uint32_t site; } ren_fdesc;

static inline char *ren_bump(ren_task *t, char *sp, uint32_t size, char **out) {
  if (REN_UNLIKELY(sp + size > t->limit)) return ren_grow(t, size, out);  /* out of line; reuses the spare chunk */
  *out = sp; ((ren_frame *)sp)->flags = 0;
  return sp + size;
}
```

### An emitted resume function

A Ren function that reads a stream to its end and counts bytes. `read` reaches
a world call, so it's suspending.

```c
typedef struct count_frame { ren_frame h; Reader src; int64_t total; } count_frame;

ren_ret count_resume(ren_task *t, ren_frame *hf, char *sp, uint64_t in) {
  count_frame *f = (count_frame *)hf;
  Reader src; int64_t total; ren_ret r;
  if (REN_UNLIKELY(f->h.state != 0)) goto dispatch;
  src = f->src;                              /* arguments: the caller wrote them */
  total = 0;
  for (;;) {
    {                                        /* let n = try src.read() */
      read_frame *c;
      char *csp = ren_bump(t, sp, sizeof(read_frame), (char **)&c);
      c->h.state = 0; c->src = src;
      r = read_resume(t, &c->h, csp, 0);
      if (REN_UNLIKELY(r.st == REN_PENDING)) {
        c->h.resume = read_resume; c->h.parent = &f->h;
        f->src = src; f->total = total;      /* spill only what's live */
        f->h.state = 1; f->h.sp = sp;
        return r;
      }
    }
  s1:
    if (REN_IS_ERR(r.v)) return r;           /* `try`: Cancelled is an ordinary error */
    if (r.v == 0) break;
    total += (int64_t)r.v;
  }
  return (ren_ret){REN_DONE, (uint64_t)total};

dispatch:                                    /* cold: reload, then enter the body */
  src = f->src; total = f->total;
  switch (f->h.state) {
  case 1: r.v = in; goto s1;
  default: REN_ASSERT_NOT_ENDED(hf);          /* debug: panics; release: unreachable */
  }
}
```

**The bottom handler,** the only code that writes `t->top`:

```c
ren_ret net_read_bottom(ren_task *t, ren_frame *hf, char *sp, uint64_t in) {
  net_read_frame *f = (net_read_frame *)hf;
  if (f->h.state == 1) return (ren_ret){REN_DONE, in};   /* resumed with the reply */
  if (REN_UNLIKELY(t->cancelled)) return ren_err(REN_E_CANCELLED);  /* before a call starts, never after */
  ren_call c = { .op = NET_READ, .len = sizeof f->args, .body = &f->args };
  ren_ret r = ren_submit(t, &c);              /* core: answer_now inline → DONE; else queue it, PENDING */
  if (r.st == REN_PENDING) { f->h.state = 1; f->h.sp = sp; t->top = &f->h; }
  return r;
}
```

### The core's trampoline and reply path

```c
static void ren_step(ren_task *t, uint64_t in) {   /* runs on a worker, inside ren_run */
  ren_frame *f = t->top;
  for (;;) {
    ren_ret r = f->resume(t, f, f->sp, in);
    if (r.st == REN_PENDING) return;               /* the new suspender set t->top */
    ren_frame *p = f->parent;
    if (REN_UNLIKELY(f->flags & REN_FIRST_IN_CHUNK)) ren_chunk_retire(t, f);  /* keeps one spare */
    if (!p) { ren_task_finish(t, r.v); return; }
    t->top = f = p;
    in = r.v;
  }
}

int ren_reply(ren_core *c, const ren_reply *rp) {  /* any thread */
  ren_slot *s = &c->slots[rp->id & REN_SLOT_MASK];
  if (s->gen != (uint32_t)(rp->id >> 32) || !s->waiter) return REN_RELEASE;  /* ends once */
  s->reply = *rp;
  ren_ready_push(c, s->waiter->home, s->waiter);   /* home worker's queue; wake it if parked */
  return REN_ACCEPTED;
}
```

The step that delivers a reply is the one the journal records as
`Deliver(reply, step)` (runtime SYNTHESIS §2.4). Under `sim`, `ren_step` is
preceded by `Sched.Call.Pick` at each point.

### Debug/tcc versus release/clang

| | debug, tcc | release, clang -O2 |
|---|---|---|
| a call through evidence or a block | `ren_fdesc *d`: bump `d->frame_size`, call `d->fn` | a direct call to the known resume function, or inlined |
| a plain handler through evidence | an adapter with `frame_size` 0 that returns DONE | inlined plain code |
| a generator's hidden local | bumped at the `let`, sized by its descriptor | a field of the consumer's frame struct |
| the bounds check in `ren_bump` | always | dropped where the task's inline segment covers the static bound |
| callee states | its own resume function | small callees' states join the caller's switch |
| `REN_ASSERT_NOT_ENDED` | a panic | `__builtin_unreachable()` |
| `#line` and named frame structs | yes | yes |

Two things about tcc to keep in mind: it returns the 16-byte `ren_ret` through
memory, which is part of why every convention costs about the same under it;
and it doesn't inline `static inline` functions, so `ren_bump`'s fast path
must be emitted as an expression or macro. As an out-of-line function, a frame
push measured 11.6 against 8.6 ns (r1 §9.3).

---

## 6. Open decisions for the owner

Twelve decisions, each with a recommendation.

1. **Are scheduling points defined by meaning, identically in every build and
   scheduler, with colours as an over-approximation?** *Recommend yes* (1a).
   It's what keeps a seed and a journal portable between debug, release and
   the interpreter. *Tradeoff:* a load and a test at each may-be-shared take,
   even in release, for the run-time shared mark.

2. **How is a take of a may-be-shared exclusive instance compiled?**
   *Recommend: suspending-coloured in every build;* a CAS when uncontended; a
   short spin, then the task parks on contention. *Tradeoff:* most server code
   becomes suspending, so more resume functions and spill paths, at about
   0.4 ns a frame level. The alternative (r5's) is a thread lock in release,
   with a point only in `sim` and debug builds. It's cheaper in code size, but
   `sim` then tests different C than production, a long hold stalls every
   worker that touches the instance, and decision 10's "a thread never blocks
   while its task is parked" must be rewritten. Experiment X3 decides. Either
   way, rewrite "a short lock, never a suspension".

3. **The debug colour.** *Recommend colouring by the row,* with adapters in
   evidence and descriptors for frame sizes (1e). *Tradeoff:* about 2 to 6 ns
   on a third of static debug call sites, and state-machine backtraces in
   lldb. Real stacks per task in debug give ordinary backtraces at the same
   speed, but put two kinds of task in the core.

4. **One register calling convention for both builds.** *Recommend yes* (2a).
   *Tradeoff:* tcc is about 10% slower with it than with the prototype's;
   clang is 3× faster. Two conventions would double the emitter's lowering.

5. **Static frame-stack sizing, an inline cap and one spare chunk.**
   *Recommend:* the static bound where there's no recursion across a
   suspension, capped at 256 B; one spare chunk freed when the task parks;
   geometric chunks for recursion (2f, 2g). *Tradeoff:* one more whole-program
   fact in release, and a chunk allocation on rare deep paths. At 100k idle
   connections the 256 B cap is 25 MB.

6. **Each pulled recursive generator owns a frame stack.** *Recommend
   rewording decision 12 to say so* (2d). *Tradeoff:* a second stack per such
   generator, against corrupting memory under `zip`.

7. **Depth limits: one byte limit for native and frame stacks, and exact depth
   isn't meaning.** *Recommend yes* (2k). *Tradeoff:* the pushed and pulled
   forms of a recursive generator, and debug and release, overflow at depths
   that differ by a small factor. Exact equality needs a depth counter on every
   recursive call.

8. **Long plain loops: what makes them cancellable?** *Recommend:* nothing
   automatic; the stall watchdog names them; std's `Async.yield()` checks the
   cancel bit on every call and yields only when the budget is spent, as
   tokio's `consume_budget` does (r5 §15). Calling it puts `Async` in the row,
   so the cost is paid only where it's written. *Tradeoff:* a pure kernel that
   should be cancellable must be chunked by a suspending caller. Reject
   compiler-inserted loop checks (measured at up to 2× in a vectorizable loop,
   r5 §15). Defer a plain `Async.cancelled()` read: it needs journaling when it
   flips.

9. **A resume-site table and a backtrace format as part of the compiler–runtime
   ABI.** *Recommend yes* (2j), with `ren bt` as an lldb script and a runtime
   sampler writing pprof after 11b. *Tradeoff:* one table per build, and perf
   and Instruments users still see only native stacks.

10. **Ring access: Ren with ordered atomics in `trust`, or a C shim?**
    *Recommend Ren* (r6). It's what makes "drivers are open" true, and it's
    about a dozen ordering sites. *Tradeoff:* every driver author must get
    acquire and release right on raw memory; a roughly 200-line C shim is
    easier to audit. glommio's `Relaxed` sleep flag (runtime SYNTHESIS §2.7)
    shows how easy it is to get wrong.

11. **Foreign calls: plain `foreign fn` pure by assertion, a `blocking fn`
    closure form, typed callback rules, and `foreign include` in its own
    unit.** *Recommend all four* (4a, 4b, 1g, 4e). *Tradeoff:* a wrong purity
    assertion breaks replay silently, though a diverging replay names the
    foreign calls on its path; the closure form's body is opaque to the journal
    except at its boundary.

12. **`main`'s scheduler chosen at compile time.** *Recommend yes,* rejecting a
    run-time choice in 1.0 (3d). *Tradeoff:* a program that wants `single`
    under a flag must be built twice.

Not on the list, because the evidence settled them: the trampoline over
re-polling and over `musttail`; stackless over stackful; one resume function
per suspending function with a cold dispatch, not one function per state (tcc
has no `musttail`, and clang still vectorized an inner loop inside the
dispatched body, r2 §8); late replies addressed by call id and generation;
the eager cancel walk.

---

## 7. Experiments

Each has a predicted result, so a miss means something.

| # | What | Predicted | Settles |
|---|---|---|---|
| **X1** | Rewrite `ren_single.c`'s `pingpong_nested` in the register convention, on the cloud Xeon as before | the nested round trip drops from about 31 ns to within 20% of the inlined `pingpong`'s 16 to 18 | decision 4 |
| **X2** | Point-set equality: the services benches (lost update, breaker) under `sim`, seeds 1 to 1000, in the interpreter, a debug build and a release build; diff the journals | identical while points are 1a's; different the moment release drops the shared-mark test for an inlined handler | decision 1 |
| **X3** | Colour shared takes as suspending in a flottning-shaped server (memtable `put`, unstriped, 8 workers): count functions that change colour, binary size, throughput uncontended; then a 100 µs hold folded into `put` | under 3% throughput difference and under 10% code growth uncontended; with the long hold, task parking keeps other workers' CPU under 10% where thread spinning burns them, and without Go's 1 ms hand-off a parked waiter starves for milliseconds | decision 2 |
| **X4** | Emit the row-coloured debug convention for `bench/services` and the examples | +3 to 8% debug run time; above 15% argues for real stacks in debug | decision 3 |
| **X5** | Static frame bound: a three-frame idle chain (serve → read → recv) with 32 B of locals each, today's 4 KiB chunks against an inline segment sized to the chain | about 4,200 B against about 290 B per parked task | decision 5 |
| **X6** | Two recursive tree walkers under `zip`, on one shared frame stack and then on a stack each | the shared version corrupts at the first out-of-order shrink (caught by guard checks); per-generator stacks pass at under 5% overhead | decision 6 |
| **X7** | Spare-chunk hysteresis in `ren_single.c` | the boundary case drops from 23 ns to within 1 ns of the in-segment 5.4 ns; `park` bytes and the depth-1000 check unchanged | decision 5 |
| **X8** | A 1 GB checksum chunked at 64 KiB with one `Async.yield()` a chunk, against the unchunked loop; then a cancel mid-run | under 0.5% overhead; cancel latency of one chunk, 10 to 20 µs | decision 8 |
| **X9** | `ren bt`: an lldb Python script walking `t->top` and the resume-site table, on a tcc build of the prototype | about 50 to 100 lines, working on tcc's DWARF | decision 9 |
| **X10** | A Ren-shaped io_uring driver in C, written as the compiler would emit it (plain functions, C11 atomics on raw pointers, a mock `ren_poll_call`), against liburing on a loopback ping-pong | within 5% of liburing at clang -O2; zero mallocs after warm-up at 10k calls in flight | decision 10 |
| **X11** | The pool hop on Linux: a futex pool, replies via eventfd and via `MSG_RING` into a sleeping io_uring worker; plus `stat` and `open` inline against the pool on a warm cache | 3 to 8 µs a hop when both sides sleep; inline `stat` 3 to 5× faster than the pool | decision 11, 4d |
| **X12** | A plain `foreign fn` that sleeps 50 ms in task code under `per_core` with `DEFER_TASKRUN` | same-worker I/O waits the full 50 ms; other workers unaffected; the watchdog names the call site within one interval | runtime SYNTHESIS decision 5 |

X1, X3 and X5 are the ones to run first: they decide the convention, the
colour of shared takes, and idle memory, and each is a small change to the
existing prototype.

---

## Citations checked

**Re-read in source by me** for this synthesis:

- Swift's allocator traps a non-LIFO free: "freed pointer was not the last
  allocation" (`swift/stdlib/public/runtime/StackAllocator.h:401-412`).
- Swift's `AsyncFunctionPointer` is `{Function, ExpectedContextSize}`
  (`swift/include/swift/ABI/Executor.h:405-414`).
- Koka's `kk_yielding(ctx)` is one unlikely branch on a context field
  (`koka/kklib/include/kklib.h:470-475`).
- Ren's own definition of a scheduling point includes each call of an
  operation of a shared, exclusive instance (`compiler.md:4505-4507`).
- `yield` appears only in a generator's own body (`streams.md:322`).
- TigerBeetle asserts its loop isn't re-entered
  (`tigerbeetle/src/io/linux.zig:77`).
- Asyncify's `ModuleAnalyzer` and its `canIndirectChangeState` flag
  (`binaryen-asyncify/Asyncify.cpp:535-575`).

**Not re-checked by me:**

- **Go's 1 ms mutex starvation threshold.** r5 cites
  `go/src/internal/sync/mutex.go:31-55`, but that path isn't in the sparse Go
  clone as I found it. The claim matches Go's source as I remember it.
- **Kotlin.** Read from GitHub, not a local clone (r5).
- **Zig's stage-1 async rules and the reasons it was removed.** From the web
  and from memory (r1).
- **The rest, as marked in each track:** the kernel's per-socket memory
  (r3), macOS's 512 KiB secondary-thread stack (r2), parking_lot and Linux's
  adaptive mutexes (r5), signalfd's mask across `exec` (r6), and Linux pool-hop
  costs (r7). Each is from memory and is an experiment's job.

**Side effects on shared state:**

- r2/r4 and r3 widened the sparse checkouts of `/tmp/ren-refs/swift` and
  `/tmp/ren-refs/openjdk`.
- r1 rebuilt the stale `bin/main.exe` in `_build` to count rows.
- No tracked file outside this directory was edited.

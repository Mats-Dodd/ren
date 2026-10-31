# The runtime

What a Ren runtime is: the interface between compiled code and the
scheduler, the promises it keeps, and what it's free to choose. One
line says it:

> **The language owns meaning; the runtime owns time, order and place.**

> **Status:** proposed. It builds on [concurrency.md](concurrency.md)
> and the prior-art research in [research/runtime/SYNTHESIS.md](research/runtime/SYNTHESIS.md),
> and in [research/runtime-frames/SYNTHESIS.md](research/runtime-frames/SYNTHESIS.md),
> and it frames foundations.md decision 9 and the runtime core stage. The
> core is C ([experiments/native-lang/SYNTHESIS.md](experiments/native-lang/SYNTHESIS.md));
> everything around it is Ren. Lock
> mechanics, memory and the record layout are
> [compiler.md](compiler.md#the-runtime-model)'s.

## The stack

```
meaning      work is a tree: calls own tasks, families own posted calls.
(language)   Anything that crosses an owner is a D.Call: data, not code.
─────────────── the contract: the orders the language promises
core         time, order and place, over three nouns:
(sans-I/O)   tasks · instances · queues of D.Calls
─────────────── D.Call out, D.Reply in
drivers      the world: Clock, Net, Fs, Proc; real, sim, replay, hosted
(Ren, trust) plain code: a driver uses no world dependency
─────────────── the host ABI, nine functions
host         threads, rings, event loops, a JS isolate
```

- **One runtime per program,** installed by `main`: `with
  Async.per_core() in serve()`. `Async.pinned()` is the only nesting.
- **The core does no I/O and reads no clock.** Everything it needs from
  the world is a call it hands out and a reply it's given, so the same
  core runs on io_uring, kqueue, a test's tape or a JS event loop.
- **Schedulers are a closed set** for 1.0: `single`, `per_core` (the
  default), `work_stealing` and `sim`. **Drivers are open:** a user
  writes one inside `trust`.

## Three nouns

The core keeps three kinds of thing, and compiled code reaches it only
through their verbs.

| Noun | What it is | Verbs |
|---|---|---|
| **Task** | a node in the work tree, owned by a scope | spawn into a scope (waiting while its `max:` run); wait for a scope's tasks; cancel a subtree; park and wake |
| **Instance** | a handler's state, touched by one operation at a time | take and release for one call; `release` mid-operation for one call; `until(cond)`, checked again at each release |
| **Queue** | a bounded queue of `D.Call`s to an owner, at a place | push, waiting for room; deliver in order, one operation each; drain when the owner ends, or drop when it's cancelled |

- **A family is the three together:** a map from key to an instance and
  its queue, with make, pin, evict and list (decision 18). It's one of
  the runtime's privileged handlers; which to evict and how many to
  keep are a library's.
- **Everything else is std,** written in Ren over these: `both`,
  `race`, `map`, `each`, `timeout`, `beside`, `background`, `produce`,
  `sync`'s channels and semaphores, `actors`, `striped`. `timeout` is a
  `race` against a `Clock` call; `race` is a scope, an instance's state
  and `until`.

## One way to talk: a queue

**The world is the outermost family.** Every wait in a family points
outward ([concurrency.md](concurrency.md#no-deadlock-by-one-rule)),
and the world is where every chain of waits ends. So the core has one
way for work to cross an owner: a `D.Call` pushed to a bounded queue.

| What crosses | Into | A reply? |
|---|---|---|
| a world call, `Net.read(conn, buf)` | the driver's queue | yes, `D.Reply` |
| an operation through `at`, on another place | the key's queue at its home | yes |
| a `post` | the key's queue at its home | no |

- **A full ring is a full mailbox.** An io_uring submission queue with
  no room and a key's mailbox at `mailbox:` are the same condition, and
  both wait for room.
- **Time is a world call,** `Clock.Call.SleepUntil(t)`, answered by the
  driver. The core never sees time except as a reply.
- **A call belongs to whoever answers it until its reply,** so `inout`
  buffers move to the driver and back, and a cancel doesn't free them
  early.
- **A cancelled task waits for its reply.** The cancel is a call too;
  the driver answers the original `Done` or `Cancelled`. A reply nobody
  waits for is released, and the journal records it.
- **A driver may answer at once,** inline, and nothing can tell.

## The contract

The language promises these orders, and only these:

1. Calls from one task to one key run in the order they were made.
2. An instance runs one operation at a time.
3. A scope ends after its tasks, and a call that returns is done.
4. `finally`s run in reverse creation order; families end innermost
   first, draining when their body returns.
5. A cancelled task waits for its reply.
6. `until(cond)` resumes only when `cond` holds, and no wakeup is lost.

**Every other order is the runtime's to choose,** and that's exactly
what `sim` explores: which task runs next, which waiter takes a
released instance, which sampled actor is evicted, when a reply lands.
`sim` is the deterministic scheduler plus a sim driver that answers
`Sched.Call.Pick` from a seeded tape. A runtime is correct if it keeps
the list; `sim` covers everything off it.

## Scheduling points and colours

Two things that look alike, kept apart:

- **A scheduling point is meaning.** It's where `sim` draws from its
  tape, where a recording journals the order, and where a cancel lands.
  The set is the same in the interpreter, in debug and in release, under
  every scheduler, or a seed found in one build won't replay in another.
  It's the interpreter's set, built in 11a: every wait (a world call,
  `until`, `yield`, `tick`, a scope's end, room in a queue, taking an
  instance someone else holds), and **every call of an operation of a
  shared, exclusive instance**, before the call: one a spawned task can
  reach, whose handler keeps state. That's where two tasks' order can be
  seen, and where `sim` finds a lost update between two operations.
- **A colour is a calling convention:** whether a call can return
  pending in this build. **A function is coloured if it can wait in this
  build.** Release decides per specialization, since dispatch is static
  over a closed world; debug, which doesn't specialize, decides by the
  inferred row. A colour may over-approximate the waits, never miss one.

So a point needn't be a wait. Under `per_core`, an uncontended take and
a lock-free handler's operation are plain code: they're points only to
`sim`, which stops there, and to a recording, which journals the order
of shared takes so a run on sixteen cores replays on one. A stateless
handler, or one no other task can reach, is neither, so a test's
`Clock.frozen` costs nothing.

- **A plain function never stops.** Cancellation lands only at
  points; plain code is never interrupted. A long plain loop holds its
  core: the stall watchdog names it, heavy pure work goes to `Async.map`,
  and `Async.yield()` checks for a cancel on every call and yields only
  when the budget is spent. The compiler inserts nothing.
- **A shared take under `per_core` runs in place when the instance is
  free, and is served at its home core when it's held.** A shared,
  exclusive instance is a family of one key with a home core. An
  operation that finds it free takes it with one compare-and-swap and
  runs on its own core. One that finds it held, or whose task still has
  a call to it unanswered, is a `D.Call` pushed to the home's queue and
  answered: the same queue as a post or a world call, first in, first
  out, with no lock moving between cores. Three rules keep it sound:
  - **Order:** a task with a call to the instance in flight ships its
    next one too, so one task's calls are never reordered.
  - **No starving:** when the home fails to take the instance it closes
    the in-place path, so its queue waits at most one in-place
    operation.
  - **A short retry:** a take that finds one in-place holder retries for
    up to 300 ns before shipping, which keeps the tail near a lock's.

  Rare sharing costs what a thread lock does (0.2 to 0.3 µs a shared
  operation, against 10 to 17 µs shipping every one); under contention
  it ships, matching shipping's throughput, 5× a thread lock's; with a
  100 µs hold other workers' work keeps flowing where a thread lock
  starved a waiter for 1.6 s. Its one risk is a holder the OS takes off
  its core, which stalls the instance for that operation; under heavy
  machine load some contended runs fell to a quarter of shipping, and
  keeping the instance at its home briefly after a failed take is the
  knob for it (experiments/runtime-frames/, X3, X3b and X3c).
- **The `per_core` scheduler drains its incoming queue at every
  scheduling point and runs tasks just resumed first,** which cuts a
  shipped operation's wait under light contention from 130 to 10 µs, and
  **a worker spins about 5 µs before it sleeps,** without which a home
  spends its time waking sleepers and throughput halves.
- **Under `work_stealing`,** where tasks move between cores anyway, a
  contended take parks the task, and after a waiter has waited 1 ms a
  release hands the instance to it directly, so no waiter starves.
- **So a shared plain handler under `per_core` is a family of one key,**
  with a home core. State every core hits belongs in `striped(by:
  Worker)`, and `ren review` says so for a shared, exclusive handler
  called from many tasks.

## How code meets the core: frames

**A frame is a call that hasn't answered.** Each coloured function
compiles to a frame, holding what lives across a wait, and one resume
function, a switch on where it waited. The calling convention is one
register convention for both builds: a call takes the task, the frame
and the frame stack's top, and returns a status and a value in two
registers. Under clang it cuts a nested round trip from 32 to 19 ns;
under tcc it makes a single frame's switch about a third slower, which
debug builds accept rather than emit two conventions.

- **The fast path is an ordinary call.** A callee runs at once and
  returns done or pending. If nothing waits, a driver answering inline
  included, the chain is nested C calls plus a bump per frame: about
  0.4 ns a level over plain C.
- **Frames live on a per-task stack,** bump-allocated, sized statically
  where no recursion crosses a wait (capped at 256 B inline), with one
  spare chunk kept while the task runs and freed when it parks: a parked
  task costs 240 B, against 4,208 B with 4 KiB chunks, and a call at a
  chunk's edge 4 ns, against 22 ns that allocates. Calls nest, so frames are last in, first out. A
  pulled generator's frame is a hidden local of its consumer's; a pulled
  *recursive* generator gets a frame stack of its own, so `zip` over two
  can't interleave their frames.
- **A reply resumes the innermost frame.** When it finishes, the core's
  loop resumes its parent: a trampoline, so the C stack stays shallow
  and nothing needs `musttail`, which tcc ignores. Nothing re-polls from
  the root.
- **The tree is in memory.** A task holds its frame stack, its
  innermost frame, its scope, its path and a cancel flag; a scope holds
  its owner's frame, a count of its tasks, `max:`, the first error and a
  cancelled flag.
- **Ends once is the call id's generation.** Frame addresses are reused,
  so a reply finds its frame by id, and one for a frame that ended is
  released.
- **Cancel walks the subtree eagerly** and sets each flag; at its next
  point a task's call returns `Cancelled`, or sends a cancel and waits
  for the reply. A `finally` masks the flag: shielded cleanup, under the
  deadline. A panic ends the program: nothing unwinds, and there are no
  landing pads.
- **Depth** is one byte limit for native and frame stacks; the exact
  depth at which recursion overflows isn't meaning.
- **A table maps each resume site to its source line,** part of the
  compiler's interface with the core, for backtraces (`ren bt`) and the
  profiler.

## Drivers are Ren

**The world has one primitive: `Async.submit(call) -> reply`,** inside
`trust`. A world dependency's bottom handler is the `trust` code that
calls it, which is what "the bottom handler is the boundary" means:

```ren
trust handler real_fs() for Fs =
  read(f, &buf) => Async.submit(Fs.Call.Read { f, buf: &buf })
```

Nothing else may submit, so no code reaches the world past the
handlers installed above it, and `sim` and `over` see every call.

- **A driver is Ren in `trust`,** answering the world's calls by calling
  the OS through foreign calls. It uses no world dependency, because it
  is the world, so it compiles to plain code by the rule above. io_uring,
  kqueue, epoll and the sim driver are Ren; the sim driver is the same
  source as `sim.fs` and `sim.net`. A driver reaches a ring through
  ordered atomics on raw memory, in `trust`.
- **The host loop is Ren too:** start the core, make the worker threads
  (the host may; the core never does), then run, hand calls to the
  kernel, wait, reply.
- **The core is the only part that isn't Ren,** and it's C: tasks and
  scopes, frame stacks, instances, queues, the scheduler policies, the
  journal writer, the host ABI, a thread-entry trampoline, the signal
  settings and a crash handler.
- **Foreign calls, in `trust`:** a `foreign fn` is a plain C call, pure
  by assertion, which a driver makes inline; a `blocking fn` block runs
  on the driver's pool thread as one world call, so errno and
  thread-locals stay on one thread, and its result is data a replay can
  answer; a callback into Ren needs an empty row, checked by type;
  `foreign include` compiles in its own C file. Foreign memory is
  borrowed for the call, never kept.
- **`main`'s scheduler is chosen when compiling.** A `sim` build is a
  different specialization from a `per_core` one; what they share is
  the set of points.

## What's journaled: time and order, and place only when it's read

The core writes the journal, through the host's `journal` hook: each
choice it made, each world call and its reply, each post. **Place isn't
journaled, because a program can't observe it unless it asks:** which
core ran a task, where a key lives, whether `at` moved the task or
shipped each call. So a journal recorded on sixteen cores replays on
one, by construction.

**Asking is an observation, and observations are recorded.**
`Async.worker()` is public, and its answer is journaled like any other
choice the runtime made: `sim` draws it from the tape, and a replay
gives it back. So `striped(by: Worker)` needs no privilege, and a user
library may read the worker too. Its results may depend on it only as
far as its merge erases it (decision 18's split law).

## Places

A place is where tasks run and keys live: a core under `per_core`, the
thread of an `Async.pinned`, a Web Worker, an isolate. **A place either
shares memory with the others or doesn't**, and that one property is all
the abstraction needs:

- **Shared memory** (threads): a value crosses by reference, marked
  shared. An `at` block sends each operation to the key's home and
  back; the compiler moves the task there instead when the block makes
  about 8 operations or more (X3b: moving is 0.16× shipping at one
  operation, 0.51× at four, 1.70× at sixteen). A home runs moved-in
  tasks fairly beside its own, or they starve it.
- **No shared memory** (Web Workers, isolates): a value crosses as data,
  copied; a frame can't move, so an `at` sends each operation to the
  key's place and back.

Both work because of structured actors: what crosses a place is a
`D.Call`, which is data with no block in it, and a task never outlives
its call, so no frame needs to follow work anywhere.

## The host ABI

The host drives the core through nine functions, sketched in
[SYNTHESIS.md §3](research/runtime/SYNTHESIS.md#3-revised-abi-sketch);
names and signatures are the runtime core stage's:

| Function | Does |
|---|---|
| `ren_start(config, main, host, ctx)` | makes a core; no globals |
| `ren_thread_init(core, worker, stack)` | binds a worker to this OS thread |
| `ren_run(core, worker, steps)` | runs up to `steps`; `RUNNING`, `IDLE` or `DONE` |
| `ren_poll_call(core, worker, out)` | takes the next call for the driver |
| `ren_reply(core, reply)` | gives a reply, from any thread; `ACCEPTED` or `RELEASE` |
| `ren_stop(core)` | cancels everything, and keeps draining until `DONE` |
| `ren_kill(core)` | drops everything with no `finally` (a `sim` crash) |
| `ren_free(core)` | frees it |
| `ren_progress(core, worker)` | a counter for the host's stall watchdog |

- **The runtime never makes a thread.** A worker is a thread the host
  made, bound with `ren_thread_init`, one ring each.
- **Every driver has one loop:** run, take calls into the kernel or the
  JS runtime, sleep until a completion, a timer or a wake, and hand
  back replies.
- **The host's hooks are leaves:** `wake`, `answer_now`, `pages` and
  `journal` never call back into the core. Keeping that true needs
  foreign calls marked `blocking` and a core handle no task can hold.

## What it isn't

- **Not a place for meaning.** Nothing a program can observe depends on
  the runtime: only cost, and which of the free orders a run took.
- **Not BEAM.** No supervisors, no preemption, no mailboxes without a
  bound, no messages inside a family.
- **Not swappable mid-program.** One runtime a program, and `pinned` the
  only nesting.

## Open

- The core's own record layout, shared with the journal and the hosted
  wire: the runtime core stage.
- A user-written scheduler: later, inside `trust`, against this page.
- The core's wake, cancel and reply protocol: model-checked in
  research/runtime-core-model/, which found a use after free at every
  wake and a lost wake on a retracted call in SPEC §B, and gives eight
  rules the core keeps. The runtime core stage builds to them.

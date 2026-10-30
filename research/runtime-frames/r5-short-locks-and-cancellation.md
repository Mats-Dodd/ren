# R5: short locks for non-suspending handlers, and cancellation only at scheduling points

Track R5 of the runtime-frames research. It stress-tests two sentences of
proposal point 1:

- "Taking a handler whose operations never suspend is a short lock, never a
  suspension."
- "Cancellation lands only at scheduling points; plain code is never
  interrupted (no preemption)."

It also tests the cancellation half of point 2: "Cancel sets a flag on the
subtree … a `finally` masks the flag (shielded cleanup under a 5 s
deadline)."

It builds on research/runtime/r6-scheduling.md (fairness, budgets,
preemption) and SYNTHESIS.md §2.2, §2.6, §2.8 and §2.9, and does not repeat
them.

Sources, read at these commits unless marked otherwise:

- Swift `1006dea` (2026-10-26), `/tmp/ren-refs/swift`. This is a sparse
  clone. `stdlib/public/Synchronization` isn't checked out, so I read it
  with `git show HEAD:<path>`.
- swift-evolution `4e7c32c` (2026-10-23), `/tmp/ren-refs/swift-evolution`
- Go `6c49ac3` (2026-10-26), `/tmp/ren-refs/go`. This is also sparse.
  `src/internal/sync/mutex.go` and `src/context/context.go` were read with
  `git show HEAD:<path>`.
- tokio `6470b5e` (2026-10-29), `/tmp/ren-refs/tokio`
- loom (tokio's model checker) `948c8cc`, `/tmp/ren-refs/loom`
- Trio `9f2df4e` (2026-10-29), `/tmp/ren-refs/trio`. `docs/` was read with
  `git show`.
- Eio `1fa7762` (2026-10-16), `/tmp/ren-refs/eio`
- Effect `a461561` (4.x), `/tmp/ren-refs/effect`. This is v4 only, never
  effect-v3.
- Seastar `b3d3270` (2026-10-29), `/tmp/ren-refs/seastar`
- kotlinx.coroutines `0245fe3e` (develop). It isn't in `/tmp/ren-refs`. I
  fetched two files from GitHub raw into the scratchpad:
  `kotlinx-coroutines-core/common/src/sync/Mutex.kt` and
  `docs/topics/coroutines-cancellation.md`. They are cited as `kx:` below.
- parking_lot and the Linux kernel aren't cloned. What I say about them is
  **from memory, unverified**.

Measurements were made here on the M4 Max (16 cores), which other agents
were sharing. The load average was 4 to 11 during the runs. The code is in
the scratchpad dir `…/scratchpad/r5-short-locks/` (`locks.c`,
`loopcheck.c`), built with `clang -O2`.

---

# Part A: the short-lock rule

## 1. Swift: actors park the task, `Mutex` blocks the thread, and the type system keeps them apart

**An actor hop is a try-lock, then a park.** `swift_task_switchImpl` runs
inline if no switch is needed (`swift/stdlib/public/Concurrency/Actor.cpp:2680-2684`).
Otherwise it tries to take the default actor's lock with
`tryAssumeThreadForSwitch` → `tryLock(false)` (`Actor.cpp:2559-2571`,
`2696-2716`). If that fails, it enqueues the task on the actor and gives up
the thread (`Actor.cpp:2719-2725`). A contended actor never spins, and it
never blocks a thread. That is possible only because every cross-actor call
is `await`, so the caller always has a frame to park.

**The exception proves the point.** In the task-to-thread model, used for
embedded targets, `SWIFT_CONCURRENCY_ACTORS_AS_LOCKS` is 1
(`Actor.cpp:67-71`). There, "all threads which are contending will block
synchronously, no job queue is needed" (`Actor.cpp:1345-1355`). When there
are no parkable tasks, an actor becomes a blocking mutex.

**`Mutex` (SE-0433) is the short lock, and it is enforced by a synchronous
closure.**

- `withLock` takes a non-`async` closure. The proposal rejects plain
  `lock()` and `unlock()` because a suspension point between them would
  unlock on a different thread. It concludes: "Calling `withLock` in an
  asynchronous function is _okay_ because … there will not be any
  suspension points between the calls"
  (`swift-evolution/proposals/0433-mutex.md:296-309`).
- The doc comment says it "block[s] threads attempting to acquire the lock"
  (`0433-mutex.md:79`).
- On Darwin it is `os_unfair_lock` (`stdlib/public/Synchronization/Mutex/DarwinImpl.swift:20-47`).
- On Linux it is a futex. It spins in a bounded way (`spinTries` 20). Once
  more than `maxActiveSpinners` (4) threads are waiting, new arrivals skip
  the spin and go straight to sleep (`LinuxImpl.swift:81-91, 115-137, 187`).

**Lesson for Ren.** Swift has Ren's two locks: a lock that parks the task
(the actor) and a lock that blocks the thread (`Mutex`). The type system
decides which one a caller gets. A caller that might wait on an actor is
`async` and can park. A `Mutex` body can't suspend, so blocking the thread
is bounded by the body. Ren's proposal computes the same split from the
handler's body. The difference is that in Swift the *programmer* chose
`Mutex` and so accepted thread blocking. In Ren the compiler chooses, so the
user never sees that a "handler" became a thread-blocking lock.

## 2. Go: two locks, and the 1 ms rule verified

**`sync.Mutex` parks the goroutine.** It spins only a little first. It
spins only when all of these hold: the machine is multicore, other Ps are
running, the local run queue is empty, and fewer than `active_spin` = 4
rounds have passed (`go/src/runtime/proc.go:8014-8027`). Each round is
`procyield(active_spin_cnt)` = 30 PAUSEs (`proc.go:8031-8033`;
`lock_spinbit.go:54-55`). After that it parks on a semaphore.

**Starvation mode at 1 ms: verified.** r6 left this unverified, since
`sync/` wasn't checked out. It is now in `src/internal/sync/mutex.go:31-55`:

> "If a waiter fails to acquire the mutex for more than 1ms, it switches
> mutex to the starvation mode. In starvation mode ownership of the mutex is
> directly handed off from the unlocking goroutine to the waiter at the front
> of the queue."

`starvationThresholdNs = 1e6` (`mutex.go:55`), and it is checked at
`mutex.go:150`. The waiter goes back to normal mode when it is last in the
queue or waited less than 1 ms. "Normal mode has considerably better
performance … Starvation mode is important to prevent pathological cases of
tail latency" (`mutex.go:49-53`). That is the model behind decision 10's
"fair, not FIFO", and it is now confirmed in source.

**The runtime's own `mutex` blocks the M (thread).** It never parks the
goroutine.

- `lock2` bumps `m.locks`, tries a speculative swap, spins with the
  "spin bit" so that only one M spins at a time, and then `semasleep`s the
  thread (`runtime/lock_spinbit.go:28-46, 164-194`).
- Holding one forbids scheduling: `schedule()` throws
  `"schedule: holding locks"` (`proc.go:4158-4160`), and so does `stopm`
  (`proc.go:3004-3005`). A runtime lock held across a park is a crash, not a
  bug class.

**Lesson for Ren.** Go's runtime lock has exactly the invariant the proposal
wants for short locks: the holder never parks while holding, enforced by a
check where the scheduler is entered. Go keeps it for runtime code that is
written by hand with care. Ren would apply it to user handlers chosen by the
compiler.

## 3. tokio: "use std `Mutex` unless held across `.await`"

- **The guidance** (`tokio/src/sync/mutex.rs:24-50`): "it is ok and often
  preferred to use the ordinary `Mutex` from the standard library in
  asynchronous code. The feature that the async mutex offers over the
  blocking mutex is the ability to keep it locked across an `.await` point.
  This makes the async mutex more expensive …"
- **For shared I/O resources,** the same comment recommends "a task to
  manage the IO resource, and to use message passing" (`mutex.rs:47-50`).
  That is an actor, which is Ren's family plus `at`.
- **tokio's async `Mutex` is FIFO** (`mutex.rs:20-22`). Kotlin's is too:
  "suspended callers are resumed in first-in-first-out order" (`kx:Mutex.kt:56, 100`).
  Ren's "fair, not FIFO" follows Go instead.
- **A blocking-lock wait stalls the whole worker.** tokio's answer to a long
  blocking section is `block_in_place`, which hands the worker's queue to a
  fresh thread (`runtime/scheduler/multi_thread/worker.rs:365`). Ren has no
  equivalent, and per runtime.md the runtime never makes a thread.

**Lesson.** The whole Rust async ecosystem runs on the proposal's rule:
take a thread lock when the section can't suspend. The rule's known failure
is the same one the measurements below show, a long section under a
blocking lock. tokio users meet it as "my worker stalled".

## 4. Kotlin: `Mutex` suspends, and a non-suspending `lock` isn't a cancel point

- **`Mutex.lock` is `suspend` and non-reentrant:** "invoking [lock] even from
  the same thread/coroutine that currently holds the lock still suspends the
  invoker" (`kx:Mutex.kt:15-16`). So re-entry deadlocks, where Ren panics.
- **"Note that this function does not check for cancellation when it is not
  suspended"** (`kx:Mutex.kt:51`). An uncontended take is not a cancellation
  point even though it is a `suspend` call. This is the closest prior art to
  "a short lock is not a scheduling point".
- **From memory, unverified here:** JVM `synchronized` pins a virtual thread
  in Loom before JDK 24. R3 covers Loom's pinning. It is the same trap as
  §8 below, a thread-level lock that can't release its carrier.

## 5. parking_lot, futexes, adaptive mutexes (from memory, unverified)

- **parking_lot** spins a few times with exponential back-off, then yields
  the thread, then parks in a global hash table of queues. It is "eventually
  fair": an unlock is forced fair on average about every 0.5 ms. That is the
  same idea as Go's 1 ms, implemented with a timer instead of a waiter's
  measured wait.
- **Solaris adaptive mutexes and Linux `mutex_spin_on_owner`** spin *only
  while the owner is running on a CPU*, and sleep otherwise. Their premise
  is that a holder who is running will release soon, while a holder who is
  descheduled won't.

**Ren gets that premise by construction.** A short lock's holder can't park
while it holds the lock, because nothing in the operation is a scheduling
point. So the holder is always on a CPU, unless the OS deschedules its
thread or it takes a page fault. Spinning is the right first move. The open
question is how long a hold can be, which is §8.

## 6. Seastar: no cross-core locks at all

Seastar is shard-per-core. Cross-core work is a message (`submit_to`).
Inside a shard, mutual exclusion is cooperative: nothing else on the shard
runs until a continuation returns. A long continuation is caught by
`need_preempt()`, a task-quota flag that the code checks itself
(`seastar/include/seastar/core/preempt.hh:66-72`; `coroutine::maybe_yield`,
`include/seastar/core/coroutine.hh:287`), and it is reported by the
blocked-reactor detector (`src/core/reactor.cc:1088-1098`).

**Lesson.** Under Ren's `per_core`, an instance used only by one worker's
tasks has the same property for free. Its non-suspending operations can't
interleave with each other on that worker, so it is never contended. That
includes `striped(by: Worker)` stripes and family instances reached through
`at`, which crosses places only as a `D.Call` (runtime.md, "One way to talk").
The short lock costs something only for a plain `with`-installed stateful
handler reached directly by tasks on more than one worker, for example a
global `seen_set`, or flottning's memtable if it isn't striped.

## 7. loom: a model checker makes every lock acquire a branch

loom's `Mutex::acquire_lock` calls `branch_acquire`
(`loom/src/rt/mutex.rs:44-47`; `rt/object.rs:333-344`). That is a point where
the checker may switch threads. If the lock is held, the thread is marked
blocked. To explore orders, a checker needs a switch point at every acquire,
uncontended ones included.

Ren's own `sim` already says the same thing. A scheduling point is "each
call of an operation of a shared, exclusive instance … before the call,
since that's where the order of two tasks can be seen"
(`compiler.md:4502-4507`). Section 9 shows why this conflicts with point 1.

## 8. Measured here: what a short lock costs, and the trap

**Uncontended take and release,** 50 M iterations, three runs, which agreed
within 2%. The command was `./locks u`.

| | ns/op |
|---|---|
| empty loop | 0.39 |
| TTAS spin lock (`xchg` acquire, store release) | 1.44 |
| `atomic_fetch_add` (seq_cst) | 2.70 |
| `os_unfair_lock` | 2.70 |
| `pthread_mutex` | 6.40 |

Decision 10 says "2.4 ns for a spin lock against 2.7 for an atomic add on
an M4" (foundations.md:668). The atomic figure reproduces. The spin lock
here is faster, 1.4 ns, probably because of the `xchg` acquire. Decision
10's "5 to 20 ns" for an uncontended take across threads is pessimistic for
the lock word itself. Cross-core cache-line transfer of the instance's
state is a separate cost, and I didn't measure it.

**Contended: the holder runs a plain loop under the lock.** A holder
thread repeats: take, spin `hold` µs, release, then 2 µs of work outside the
lock. A waiter thread takes the lock 2,000 times. The table shows the
waiter's wait per take, wall time and its own CPU time, with its own work
subtracted. The command was `./locks c`, run twice under load.

| hold | strategy | wait/take (run 1) | CPU burned | wait/take (run 2) |
|---|---|---|---|---|
| 1 µs | spin | 0.6 µs | 99% | 0.7 µs |
| 1 µs | park (`os_unfair_lock`) | 3.0 µs | 62% | 1.2 µs |
| 1 µs | spin ≤1000, then park | 0.7 µs | 100% | 0.6 µs |
| 100 µs | spin | 52 µs | 100% | 312 µs (40%) |
| 100 µs | park (`os_unfair_lock`) | **16,000 µs** | 3% | **34,000 µs** |
| 100 µs | spin ≤1000, then park | 186 µs | 1% | **75,000 µs** |

Three findings.

1. **Spinning through a long hold burns a whole core for the whole hold.**
   With 100 µs holds and N waiters, N cores do nothing useful. Every task
   queued on those workers waits too. Their completions also wait, since
   each worker owns its ring (SYNTHESIS §2.9).
2. **An unfair parking lock starves the parked waiter.** It waited 160 to
   340× the hold. The releasing holder takes the lock again within its 2 µs
   gap, before the kernel has woken the waiter. `os_unfair_lock` is unfair
   by design. This is exactly the case Go's 1 ms starvation hand-off exists
   for. **A "fair, not FIFO" short lock needs Go's rule (or parking_lot's)
   built in, not just a bounded spin.**
3. **For holds of a microsecond, everything works.** Spinning is best, and
   parking adds microseconds of wake-up latency.

So the short lock is right when holds are short, and pathological when they
aren't. **The compiler can't tell which.** "Never suspends" says nothing
about duration. A handler whose `put` sorts a 1 MB buffer, or rebuilds an
index when it fills, is non-suspending and long.

## 9. The Ren-specific questions

### 9.1 A plain caller meets a held instance on another core

The caller has no frame, so it can't park its task. It can spin or block
its OS thread, and nothing else. That contradicts decision 10 as written:
"Other callers queue for the instance as tasks: a thread never blocks while
its task is parked" (foundations.md:536-538). Under the proposal that
sentence is true only for instances whose operations can suspend. **For a
short lock, the waiter blocks its thread.**

Is that acceptable? Compare it with what Ren already accepts:

- **Ren already accepts plain stalls.** A plain computation already holds
  its worker for its whole length (async.md:780-781; no preemption). The
  holder's own worker is stalled for the hold anyway.
- **Contention spreads the stall.** A short lock lets one long hold stall
  *every* worker that touches the instance, instead of one. That is the new
  hazard. It is bounded by the hold: one operation's plain computation,
  times the number of waiters ahead in the queue.
- **There is no deadlock.** The holder never waits for anything (it can't
  suspend), so a thread blocked on a short lock always makes progress
  eventually. Inner-to-outer ordering (decision 10) still holds. One
  non-suspending operation can call another handler's non-suspending
  operation, so short locks nest, but only outward.

**Recommendation: accept it, with five rules attached.**

- **S1. Holder never parks.** This is structural. A debug build asserts it,
  as Go's `schedule: holding locks` does.
- **S2. Uncontended path.** The take is one CAS that stores the worker id.
  If it fails and the owner is *this* worker, the holder must be this same
  task, because nothing else on this worker can run between that take and
  its release. So it panics, which is decision 10's "a task taking an
  instance it already holds panics", at zero cost.
- **S3. Contended path.** Spin a bounded number of times, about the same as
  Swift (20 rounds) or Go (4 × 30 PAUSE), so roughly 1 to 2 µs. Then block
  the thread on the lock word: futex on Linux, `os_sync_wait_on_address` or
  `__ulock` on Darwin, `WaitOnAddress` on Windows. Go's 1 ms starvation
  hand-off applies. Decision 10's "fair, not FIFO" then holds for short
  locks too.
- **S4. Visibility.** The core counts, per instance, the time threads spent
  blocked on it, and long holds. `ren_progress` already gives the host
  watchdog a per-worker counter (runtime.md, host ABI). Extend the report
  with "worker 3 blocked 40 ms on `memtable` held by
  `main/serve:12/handle:0`". The fix it should point to is decision 18's
  `striped` or `actors`.
- **S5. A suspending caller may park the task instead.** When the call site
  is in a function that is already suspending, the compiler may make the
  contended path a suspension: try-lock, and on failure park the task and
  queue on the instance. This is Swift's actor hop. It changes only cost,
  never meaning, so it is a runtime and compiler choice, not a rule. It
  doesn't help the common case, where the caller is a plain helper like
  `deposit`.

**Rejected: "a shared instance makes its callers suspending."** It would
keep decision 10's sentence true. But every function that touches a shared
handler, including flottning's `memtable.put` path, would get a frame and a
`PENDING` check for a lock that is free about 99% of the time. Nested child
frames measured about 31 ns in the p2 prototype (brief). That is 20 times
the 1.4 ns lock. It would also make colour depend on spawn reachability,
which is a property of the `with` site, not of the handler. That breaks
"colours are computed per specialization" unless specialization keys on
sharedness.

**Rejected: "every take of a shared instance is a scheduling point" in
native builds.** It has the same cost, and also makes every such call a
cancellation point and a budget tick.

### 9.2 Does `per_core` share non-suspending handlers at all?

Yes. `per_core` doesn't home plain `with` instances. Only family instances
have homes (runtime.md, Places; decision 18). A handler installed in `main`
above the spawns is reachable from every core. Decision 10's "the exclusion
is skipped unless the instance is shared" (foundations.md:582-585) removes
the lock only when no spawned task can reach the handler. On a per-core
runtime, "shared" should mean **reachable from tasks on more than one
worker**, and that is not knowable statically under `per_core`: spawn
placement is the runtime's choice. So every instance reachable from a
spawned task pays S2's CAS. That is 1.4 ns plus a cache-line transfer when
the instance moves between cores, which isn't measured here.

### 9.3 `sim` and the short lock: point 1 is wrong as stated

In a single-threaded `sim`, a short-lock take is never contended, because
nothing runs between take and release. That part is sound. Operations on
one instance are atomic with respect to each other on every runtime, so
`sim` misses no order *inside* an operation.

**It misses the orders *between* two operations.** async.md's own example
shows this (async.md:250-266):

```ren
fn deposit(n: Int) uses Account =
  let b = Account.balance()
  Account.set(b + n)       // another task's deposit can come in between
```

- `Account`'s operations never suspend, so under point 1 `deposit` is
  **plain**, with no scheduling point between `balance` and `set`.
- On `per_core`, another worker's task *can* take `Account` between the two
  calls, so the lost update happens natively.
- On `sim`, built with the same colours, nothing can run there. So the bug
  async.md promises "the test scheduler finds" is **never found**.

compiler.md:4504-4507 already makes these calls scheduling points under
`sim`, but the frame model can't switch away from plain code.

**Fix: colours depend on the build's scheduler.** In a `sim` build (and in
any build a test runs under `sim`), a call of an operation of a shared,
exclusive instance is a scheduling point. So functions that reach one are
suspending there and plain natively.

- **Precedent.** loom swaps every lock for a branch point (§7). Go's `-race`
  build changes scheduling (`proc.go:7542`, via r6). Ren's `lockfree`
  handlers are already "under `sim` every access is a scheduling point"
  (foundations.md:690-691).
- **Tradeoff.** `sim` runs different C than production for those
  functions. Meaning is unchanged, since `sim` only adds switch points the
  contract already allows. But a codegen bug in the plain path can't be
  found by `sim`.
- The debug build, which "never specializes" and passes handler evidence
  (decision 13), must colour conservatively anyway. A call through evidence
  to an unknown handler is suspending. So the debug build may simply *be*
  the `sim` colouring.

---

# Part B: cancellation only at scheduling points

## 10. Trio: every Trio async call is a checkpoint, even when it doesn't block

- **The rule** (Trio `docs/source/reference-core.rst:84-101`): "Regular
  (synchronous) functions never contain any checkpoints. If you call an
  async function provided by Trio … and it doesn't raise an exception, then
  it *always* acts as a checkpoint." Trio deliberately makes non-blocking
  calls checkpoints, so that cancellation points are predictable from the
  source.
- **`checkpoint()`** schedules first, then checks: "The scheduler is what
  checks timeouts and converts them into cancellations. So by doing the
  schedule point first, we ensure that the cancel point has the most
  up-to-date info" (`src/trio/_core/_run.py:3017-3052`).
- **`checkpoint_if_cancelled()`** is the cheap variant. It reads a flag and
  switches only if cancelled (`_run.py:3055-3075`).
- **For CPU-bound code** the docs say: "`await trio.sleep(0)` is an
  idiomatic way to execute a checkpoint" and `assert_checkpoints` tests for
  one (`reference-core.rst:191-196`). Without enough checkpoints a task is
  "hogging the run loop" (`reference-core.rst:48-57`).
- **Propagation is an eager walk.** `CancelStatus` objects form a tree that
  mirrors the cancel scopes, and `recalculate` walks it depth-first, pushing
  `effectively_cancelled` down to the tasks at the leaves and waking each
  one (`_run.py:337-363, 477-503`). A shielded scope stops the walk
  (`_run.py:473, 512`). A checkpoint then reads one cached boolean.
- **Cleanup under a deadline** is written by the user:
  `with move_on_after(CLEANUP_TIMEOUT, shield=True)` in the `finally`. When
  that deadline expires, the cleanup's own calls are cancelled at their next
  checkpoint (`reference-core.rst:442-460`). Trio can't stop plain code in a
  shielded `finally` either.

## 11. Swift: cooperative, an eager walk, and shields (now)

- **Cooperative** (`Concurrency/Task.swift:224-234`): "a function that
  doesn't specifically check for cancellation will run to completion
  normally." Code polls with `Task.isCancelled` or `checkCancellation()`
  (`TaskCancellation.swift:355-365, 418`), and `withTaskCancellationHandler`
  installs a callback that runs immediately on cancel
  (`TaskCancellation.swift:77`).
- **`swift_task_cancel` sets an atomic bit with a CAS.** Then, under the
  status-record lock, it walks the records: child tasks are cancelled
  recursively, task groups cancel their children, and cancellation handlers
  run (`TaskStatus.cpp:1449-1475, 1555-1594`). The walk is eager and
  O(subtree), and checking is one load.
- **Shields arrived in Swift 6.4** (SE-0504,
  `swift-evolution/proposals/0504-task-cancellation-shields.md:1-8`).
  `withTaskCancellationShield` hides the flag from `isCancelled` and stops
  propagation into children spawned inside the shield (`0504:69-130`). It
  also suppresses handlers registered inside the shield (`0504:154-176`).
  The runtime's walk skips records inside the outermost shield
  (`TaskStatus.cpp:1014-1060, 1414-1440`).
- **The motivation is Ren's "it never stops cleanup"** (`0504:22-45`):
  cleanup code that checks `isCancelled` and skips the action. Swift
  pairs shields with `async` `defer` (`0504:309-321`). **There is no
  deadline:** a shielded cleanup can hang forever. Swift also gained
  `withDeadline` (`Task+Deadline.swift:22-41`), but the two don't compose
  into a "cleanup budget".

## 12. Kotlin: suspension points, `yield()`, `NonCancellable`

- **The rule** (`kx:coroutines-cancellation.md:157-170`): "coroutine
  cancellation is _cooperative_. Coroutines react to cancellation only when
  they cooperate by suspending or checking for cancellation explicitly." Also:
  "A call to a `suspend` function is a suspension point, but it doesn't
  always suspend". The docs then describe the check as happening "if the
  coroutine suspends there".
- **For CPU loops** the docs recommend `yield()` (`:228-236`): "In
  CPU-intensive computations … call the `yield()` function periodically …
  it also ensures that the coroutine checks for cancellation regularly."
  `isActive` and `ensureActive()` are the non-yielding checks, and the docs
  discourage them unless hogging the thread is intended (`:271-280`).
- **Cleanup** uses `nonCancellable { … }` (formerly
  `withContext(NonCancellable)`) inside `finally` (`:437-486`). It has no
  built-in deadline.

## 13. Eio: a context tree, an eager walk, `Fiber.check`, `Cancel.protect`

- **The walk.** `cancel_internal` marks the context tree `Cancelling`
  depth-first, skipping protected subtrees, and collects every fiber. Then
  `cancel` calls each fiber's `cancel_fn` (`lib_eio/core/cancel.ml:130-172`).
  It must be called from the context's own domain (`cancel.ml:148-152`).
- **The check.** `Fiber.check ()` performs `Get_context` and raises if the
  state isn't `On` (`fiber.ml:171-173`; `cancel.ml:69-73`). "Many
  operations automatically check this before starting", and "this check is
  typically done when starting an operation, not at the end"
  (`eio__core.mli:315-317, 537-539`).
- **`Cancel.protect`** runs `fn` in a protected context. Neither the new
  context nor the parent is checked after it returns, "to make sure the
  caller has a chance to handle the result" (`cancel.ml:122-128`). It has
  no deadline.

## 14. Go, Effect v4, tokio

- **Go has no task cancellation at all.** `context.Context` is a value
  that is passed by hand. Cancelling it walks `children` eagerly
  (`src/context/context.go:15-24, 574-578`). Code polls `ctx.Done()`, and
  a goroutine that never looks never stops. Go's preemption is for
  fairness, not cancellation (r6).
- **Effect v4 checks interruption at every op.**
  - `interruptUnsafe` sets `_deferredInterrupt` if the fiber is running and
    interruptible (`packages/effect/src/internal/effect.ts:591-611`).
  - The run loop checks that flag at every primitive
    (`effect.ts:676-679`), and calls `shouldYield` on the same count
    (`effect.ts:680-689`; `Scheduler.ts:198-200`, `MaxOpsBeforeYield` =
    2048 at `Scheduler.ts:294-297`).
  - Children are interrupted when their parent ends, through an
    `interruptChildren` walk (`effect.ts:639-645, 829-832`).
  - `uninterruptible` regions flip `fiber.interruptible` (`effect.ts:1242`,
    `2291`).
  - An `Effect.sync(() => longLoop())` is one op, so Effect has Ren's plain
    loop problem exactly.
- **tokio cancels by drop at `.await`.** `abort` takes effect at the next
  poll, and `spawn_blocking` tasks "cannot be aborted because they are not
  async" (`tokio/src/runtime/task/abort.rs:14-18, 41-46`). For CPU loops,
  `consume_budget().await` "can be used in order to insert optional yield
  points into long computations … without redundantly yielding to the
  runtime each time" (`task/coop/consume_budget.rs:1-23`). It yields only
  when the 128-unit budget is exhausted (`coop/mod.rs:104-117`).

**Across all seven systems, nobody cancels plain code.** The fixes are
always the same two: an explicit check the programmer writes (Trio
`sleep(0)`, Kotlin `yield`, tokio `consume_budget`, Seastar `maybe_yield`,
Swift `checkCancellation`), and, in the systems that have it, a stall
report. The only exceptions are runtimes that check at every operation of
an interpreter (Effect, BEAM). They pay for it everywhere, and Ren reversed
exactly that (foundations.md:1456).

## 15. The long plain loop in Ren

**The budget doesn't reach it.** SYNTHESIS §2.8's counted budget fires *at*
scheduling points. Point 1 also removes the scheduling points from the case
§2.8 was written for. "A loop of `memtable.put` never yields" assumed that
`put` is a scheduling point that doesn't wait. Under point 1, `put` on a
non-suspending memtable is a short lock and **not** a scheduling point, so
that loop becomes a plain loop. It has no budget tick and no cancel check,
and it is invisible to `sim` (§9.3). The budget still matters for loops
over inline-answered world calls and suspending handlers. §2.8's motivating
example should be re-stated.

**What a counted check costs,** measured here with
`clang -O2 loopcheck.c && ./loopcheck`. The loop sums a 4,096-element array
20,000 times, with three runs that agreed within 1%.

| variant | ns/iter | vs plain |
|---|---|---|
| plain | 0.40 | 1.00× |
| (c) counted check: `--budget == 0 → call` | 0.78 | 1.98× |
| (c) counted check with live values spilled to a frame | 0.86 | 2.18× |
| (d) a relaxed load of a cancel flag | 0.78 | 1.97× |

This loop is a worst case: the check stops the loop from being vectorized.
Go's design doc reports 7.8% geomean for loop checks across real code (r6).
The first async.md estimated 1 to 2%. A counted check isn't a small cost in
exactly the kernels (sum, scan, checksum, compress) where flottning spends
its CPU.

**The options:**

- **(a) Nothing; document it; the watchdog reports it.** This costs zero.
  Cancel latency is unbounded, but visible: the stall detector names the
  task path (SYNTHESIS §2.9). It is the right default for code that is
  plain.
- **(b) `Async.yield()` in std.** It is a scheduling point and puts `Async`
  in the row, so the enclosing function becomes suspending. Make it tokio's
  `consume_budget`, not Trio's `sleep(0)`. It always checks cancellation
  (one load), and it yields only when the budget is spent. So calling it on
  every iteration costs a decrement, a load and a branch, plus the frame
  the function now has. This keeps point 1 intact: plain code stays plain,
  and code that wants to be interruptible says so, in its row. It fits
  decision 20: it is a std function over a runtime verb.
- **(c) Compiler-inserted counted checks in loops of suspending functions
  that contain no scheduling point.** Measured at up to 2×, it changes
  where cancellation lands without the source showing it, and it covers
  only half the problem: a plain helper's loop called from that function is
  still unchecked. Reject it. It is the loop-preemption rule foundations.md
  reversed, re-entering by the back door.
- **(d) `Async.cancelled() -> Bool`, a plain flag read.** It needs no frame,
  so a pure kernel could stop early and stay plain. The costs:
  - the read is an observation, so it must be journaled, on the first
    `true` with the task's check count, for replay (decision 11 already
    records "when a cancellation was seen");
  - it puts `Async` into a row whose function never suspends, which blurs
    "a row with `Async` can wait";
  - the user must then return something, and cancellation "can't be
    swallowed" only because the next scheduling point raises it.

  Defer it. Chunking with (b) gets the same latency.

**Recommendation: (a) + (b).** The `Mem.snapshot` rule ("no code reached
from a call with an empty row runs a scheduling point",
foundations.md:684-685) stays true, because (b) puts `Async` in the row.
Proposal point 1 stays true. The cost of interruptibility is paid only
where it is written.

## 16. Shielded `finally` under a 5 s deadline

| | Masks the cancel | Deadline on cleanup | What happens when it runs out |
|---|---|---|---|
| Trio | `shield=True` scope (user writes) | `move_on_after(T, shield=True)` (user writes) | cleanup's calls get `Cancelled` at their next checkpoint |
| Kotlin | `nonCancellable {}` (user writes) | none built in | — |
| Swift | `withTaskCancellationShield` (6.4, user writes) | none | — |
| Eio | `Cancel.protect` (user writes) | none | — |
| Ren (async.md:410-414) | always, in every `finally` | 5 s, always | SYNTHESIS decision 3: abandon pending calls, journal `Release`, poison streams |

Ren is the only system where both the shield and the deadline are on by
default. Trio is the only one with a deadline at all, and only by
composition. That is the design async.md claims, and it holds up. Four
refinements:

1. **The deadline is a cancel scope of the `finally`'s own,** shielded
   from outside and cancelled at 5 s, as Trio composes it. When it fires,
   the cleanup's pending calls get cancel-and-wait (SYNTHESIS §2.2). Calls
   the kernel won't cancel are abandoned and released (SYNTHESIS
   decision 3). The cleanup is then *cancelled again*, and its own nested
   `finally`s get no new 5 s each. Otherwise nested cleanups multiply the
   bound. Say so explicitly.
2. **Plain code in `finally` overruns.** The deadline lands only at
   scheduling points, so a `finally` that computes for 30 s takes 30 s.
   That is consistent with (a) above. Document it rather than fix it.
3. **Arm the timer lazily.** The core reads no clock, so the deadline is a
   `Clock` call (runtime.md: "Time is a world call"). Arming one per
   `finally` would put a timer submit on every cancelled path. Most
   `finally`s are plain, like `close` or `release`. So arm the deadline
   only when the `finally` first parks. A `finally` that never waits costs
   nothing.
4. **Children spawned in a `finally` must not inherit the cancel.** Swift's
   SE-0504 rule (`0504:95-130`) is that the shield also stops propagation
   into new children. Under eager propagation (§17), a scope opened in a
   `finally` starts uncancelled, under the cleanup deadline's scope.

## 17. Cancel as a flag: walk on cancel, or check ancestors at each point?

All four systems with trees walk eagerly at cancel time: Swift
(`TaskStatus.cpp:1449-1475`), Trio (`_run.py:477-503`), Eio
(`cancel.ml:134-146`), Go's context (`context.go:574`). Checking is one
load of the task's own state. No system checks ancestors lazily at every
point. That would cost O(depth) at every scheduling point, and scheduling
points far outnumber cancels.

**Ren must walk anyway.** A parked task has to be woken so that its pending
call is cancelled (runtime.md: "A cancelled task waits for its reply").
Waking requires visiting the task. So:

- **Each task has a `cancelled` bit in its header**, set by the walk, and
  read with one relaxed load at every scheduling point. It is checked
  *before* starting a call, never after a result has arrived, so a
  completed call is never lost (async.md "It never loses a result"; Eio
  "when starting an operation"; Trio schedules first, then checks).
- **The walk stops at shielded `finally` scopes** (Trio `_run.py:512`;
  Swift's outermost-shield skip, `TaskStatus.cpp:1414-1440`).
- **On `per_core`, the walk crosses cores.** Setting the bit is an atomic
  store into a task that another worker owns. Waking a parked task, or
  sending its driver a `Cancel { id }`, is a message to that task's home
  worker (SYNTHESIS §2.6). Eio forbids cross-domain cancel
  (`cancel.ml:148-152`). Swift takes a per-task status lock. Ren's version
  is: set the bits anywhere, route the wakes home.
- **The order a cancel is seen in is journaled** (decision 11), at the
  scheduling point that observed it. The walk itself isn't journaled.

---

# What this means for Ren

## Proposal point 1: plain or suspending, per specialization

**Confirmed: a non-suspending handler's take is a thread-level lock, not a
suspension.** Swift's `Mutex` (`0433-mutex.md:296-309`), tokio's guidance
(`sync/mutex.rs:24-35`) and Go's runtime lock (`proc.go:4158-4160`) all
draw the same line: a lock never held across a suspension is a thread lock.
Measured, the uncontended cost is 1.4 ns (spin) or 2.7 ns
(`os_unfair_lock`).

**Wrong: decision 10's "a thread never blocks while its task is parked".**
For a short lock, a plain caller has no frame, so on contention it blocks
its thread.

- **Fix:** rewrite decision 10's bullet as rules S1 to S5 (§9.1):
  - the holder never parks (asserted);
  - the take is a CAS storing the worker id, and a same-worker hit panics;
  - on contention, a bounded spin (about 1 to 2 µs), then a futex or ulock
    on the lock word, with Go's 1 ms hand-off;
  - per-instance blocked time goes into the stall report;
  - a call site that is already suspending may park the task instead.
- The hand-off is not optional. Measured, an unfair parking lock starved a
  waiter for 16 to 75 ms behind a 100 µs holder.

**Missing: the trap of a long short lock.** "Never suspends" isn't "short".
A 100 µs hold makes every contending worker spin, burning 100% CPU, or
park, starving without hand-off.

- **Fix:** document it as a trap next to decision 10's list, with the fix
  being `striped` or `actors`, and report it in the watchdog. Don't try to
  bound hold time in the compiler.

**Wrong as stated: `sim` can't find between-operation races in plain
code.** async.md's `deposit` example becomes plain, so `sim` never switches
between `balance` and `set`, while `per_core` can interleave there.

- **Fix:** colours depend on the scheduler build. Under `sim` (and in debug
  builds, which must colour conservatively through evidence anyway), a call
  of an operation of a shared, exclusive instance is a scheduling point, as
  compiler.md:4504-4507 already says. "Colours are computed" becomes
  "computed per specialization *and per scheduler build*".

**Wrong: async.md's "It happens at dependency calls"** (async.md:397). Under
point 1, a call to a non-suspending handler isn't a cancellation point.

- **Fix:** "at scheduling points". Kotlin's `Mutex.lock` does the same thing
  ("does not check for cancellation when it is not suspended",
  `kx:Mutex.kt:51`).
- The tradeoff: Trio chose the opposite, every library call is a
  checkpoint, so that cancel points are predictable. Ren gives that up for
  plain code.

**Missing: SYNTHESIS §2.8's motivating example changes.** A `memtable.put`
loop on a non-suspending memtable is now a plain loop. The budget never
sees it.

- **Fix:** restate §2.8 for loops over inline world calls and suspending
  handlers. The plain case falls to (a) and (b) below.

## Proposal point 2: cancel as a flag, shielded `finally`

**Confirmed: a flag per task, set by an eager walk of the subtree, read with
one load at each scheduling point.** Every tree-shaped system does this
(Swift, Trio, Eio, Go context), and Ren must visit parked tasks anyway to
cancel their calls. Check before starting a call, never after a result.

**Confirmed: `finally` shielded by default under a deadline.** No other
system does both by default. Trio composes it, and Swift only just added
shields (SE-0504, 6.4) without a deadline. Missing details:

- the deadline is a nested cancel scope, armed lazily at the first park;
- nested `finally`s inside an expired cleanup get no fresh 5 s;
- scopes opened in a `finally` start uncancelled;
- plain code in a `finally` overruns the deadline, which is documented.

## Candidate open decisions

1. **The cancel point for plain loops.**
   - **Recommend:** (a) the watchdog report, plus (b) a std
     `Async.yield()` with `consume_budget` semantics: it checks the cancel
     bit every call and yields only when the budget is spent.
   - **Tradeoff:** a pure kernel that wants to be cancellable must be
     chunked by its suspending caller. Reject compiler-inserted loop checks
     (measured up to 2× in a vectorizable loop). Defer
     `Async.cancelled()` (d): it needs journaling on the flip, and it blurs
     what `Async` in a row means.
2. **The contended short lock blocks the thread (S3) or makes callers
   suspending.**
   - **Recommend** blocking the thread with Go's hand-off.
   - **Tradeoff:** one long hold can stall many workers, against a frame on
     every shared-handler caller, which is about 20× the lock's cost.
3. **`sim` colouring.**
   - **Recommend:** a shared exclusive take is a scheduling point in `sim`
     and debug builds, and a CAS in release builds.
   - **Tradeoff:** `sim` exercises different C than production for those
     functions.
4. **What "shared" means under `per_core`.**
   - **Recommend:** keep decision 10's static test, "reachable from a
     spawned task", for the lock's existence. Rely on S2's 1.4 ns CAS for
     the case where the instance is shared but all its callers run on one
     worker.
   - **Tradeoff:** there is no free path for an instance shared only in
     principle.

## Experiments worth running

- **E-SL1, a short lock under real contention.** flottning's memtable
  `put`, unstriped, from 8 workers.
  - Hypotheses: with holds under 1 µs, throughput is within 20% of striped
    and wait CPU stays under 10%. With a 100 µs hold, for example a flush
    folded into `put`, p99 latency for every worker rises to at least the
    hold times the queue depth.
  - Compare three versions: spin only, spin then park without hand-off
    (prediction: ms-scale starvation as in §8), and Go's 1 ms hand-off
    (prediction: p99 bounded near 1 ms plus the hold).
- **E-SL2, colour drift.** Compile flottning and the examples twice,
  native and `sim` colouring.
  - Count the functions that change colour.
  - Prediction: under 10% of suspending functions, concentrated in callers
    of shared handlers like `deposit`.
  - Then check whether `sim` finds `examples/breaker`'s lost update and the
    `deposit` race only in `sim` colouring (prediction: yes, and never in
    native colouring).
- **E-SL3, the cost of `Async.yield()` in a hot loop.** A checksum over
  1 GB, chunked at 64 KiB with one `Async.yield()` a chunk.
  - Prediction: under 0.5% overhead, and cancel latency of one chunk, about
    10 to 20 µs.
  - Compare per-iteration `Async.yield()`. Prediction: about 2× the loop,
    as in §15's measured check, plus the frame.
- **E-SL4, cancel fan-out.** Cancel a scope of 100k parked tasks spread over
  8 workers.
  - Predictions: the bit-setting walk costs about 5 to 10 ns per task
    (around 1 ms in total), and is dominated by routing a `Cancel { id }`
    per pending world call to each home worker.
  - Check that no wake is lost when a reply races the walk.

# R3: where effect systems and green threads meet the kernel

Track R3 of the runtime research. It looks at five systems where a
user-level concurrency model has to reach real I/O: OCaml 5 Eio, Java's
virtual threads (Loom), Go's runtime, Zig's new `std.Io`, and Effect v4.
For each I asked five questions. Where is the bottom handler? How does the
world reach code? What happens to a blocking foreign call? How do you test
against a fake world? What do the authors regret? The answers are mapped
onto Ren's agreed model: a sans-I/O core, drivers, `D.Call` and `D.Reply`,
the journal, and the `blocking` rule.

Sources, all read at these commits unless marked otherwise:

- Eio `1fa7762` (2026-10-16), `/tmp/ren-refs/eio`
- OpenJDK `6ded68f` (2026-10-30), sparse clone at `/tmp/ren-refs/openjdk`.
  `/tmp/ren-refs/loom` is tokio's Rust `loom` model checker, not Java's.
- Go `6c49ac3` (2026-10-26), `/tmp/ren-refs/go`
- Zig `738d2be` (2025-11-26), `/tmp/ren-refs/zig`. This is older than the
  0.16.0 release, so I checked the release notes on the web as well.
- Effect `a461561`, version 4.0.6, `/tmp/ren-refs/effect`

---

## 1. Eio (OCaml 5)

### The bottom handler

Each domain runs one deep effect handler: `Sched.run`'s `effc` in
`lib_eio_linux/sched.ml:333-403`. It is the closest prior art to Ren's
"the bottom handler is the boundary". Fibers perform a few effects:

- `Suspend`, `Fork` and `Get_context`, which are portable
  (`sched.ml:358-371`)
- the backend's own `Enter`, which carries a closure
  `t -> 'a Suspended.t -> unit` (`sched.ml:57-60, 94-96`)
- `Run_in_systhread` (`sched.ml:396-401`)

The world operation is not data. `Enter` carries an OCaml closure that
writes an SQE straight into the ring (for example `enqueue_readv`,
`sched.ml:291-297`). So no value exists that a journal could record. The
request is code that runs inside the scheduler. This is the main way Ren's
model differs from Eio's, and Ren's choice is better: Eio has tracing
(`runtime_events`) but no record or replay.

The scheduler reads the clock itself. It calls `Mtime_clock.now ()` at
`sched.ml:175`, and the thread pool's idle reaper does too
(`lib_eio/unix/thread_pool.ml:127`). Ren passes `now_ns` into `ren_run`
instead, which is cleaner.

io_uring setup uses `SINGLE_ISSUER | DEFER_TASKRUN | TASKRUN_FLAG`, falling
back when that fails (`sched.ml:460-464`). It requires `MSG_RING`, Linux
5.18 or later, or it falls back to `Eio_posix` (`sched.ml:481-483`).
`Eio_main` makes that choice at run time (`doc/rationale.md:64-75`). Cross-domain wakeups
use an eventfd guarded by a `need_wakeup` atomic (`sched.ml:39-50, 69-83`).
Eio's run queue is a lock-free queue that other domains may push into.
There is no work stealing: each domain is its own island (`Domain_mgr`,
`lib_eio_linux/eio_linux.ml:40-62`), and Eio spawns the domain threads
itself.

### Cancellation

There is a per-domain tree of contexts (`lib_eio/core/cancel.ml:8-30`).
While a fiber is in an operation it holds a `cancel_fn`. A cancel replaces
it with `ignore` and calls it (`cancel.ml:151-172`). For io_uring the
cancel function submits `IORING_OP_ASYNC_CANCEL`
(`sched.ml:111-150`). The comment at `sched.ml:120-136` lays out the race.
The cancel's own CQE is dropped, including `ENOENT` and `EALREADY`
(`sched.ml:258-264`).

The important detail is at `sched.ml:246-255`. If the original operation
completes with a non-negative result after a cancel was requested, Eio
delivers the result. It reports `Cancelled` only when the operation itself
failed. A completed read is never thrown away by the scheduler. Eio's
README admits the consequence for races: with `Fiber.first` over two
io_uring reads, "the kernel may have already performed both reads… and one
result is thrown away" (`README.md:290-296`).

Closing a file descriptor while an operation is in flight is handled by
`Rcfd`, a reference-counted fd where the last user closes it
(`lib_eio/unix/rcfd.mli:1-60`). `remove` refuses to be cancelled "since it
takes ownership of the FD and that would be leaked".

### The world

The world is passed as capabilities. `Eio_main.run` hands `main` an `env`
object: `net`, `fs`, `cwd`, `clock`, `mono_clock`, `secure_random`,
`process_mgr`, `domain_mgr` and stdio (`lib_eio/unix/eio_unix.mli:110-145`).
The README design note puts it this way: "all authority starts at
`Eio_main.run`" (`README.md:460-497`). The capability discipline is only a
convention, though:

- `Eio_unix.sleep` exists "without having to plumb `mono_clock`"
  (`eio_unix.mli:66-70`).
- The README concedes that "OCaml is not a capability language, code can
  ignore Eio".
- "Passing env" warns that env is too powerful to pass around and suggests
  narrowing it by hand (`README.md:1813-1850`).

### Blocking calls

Blocking calls must be marked explicitly, with `Eio_unix.run_in_systhread`
(`thread_pool.ml:116-135`). The pool is unbounded: "creates a new system
thread if all threads are busy, it does not wait" (`eio_unix.mli:72-78`).
Idle threads are dropped after about 20 ms. Cancellation is checked only
before submission (`thread_pool.ml:116-121`). Once a job is running it
cannot be cancelled, and its result goes back to the fiber. The posix
backend sends about 16 file-system operations through it, including
`openat`, `mkdir`, `readdir` and `fsync` (`lib_eio_posix/low_level.ml:23`
and its callers). So an epoll fallback needs a blocking pool for files. On
Linux, io_uring keeps only a few operations, such as `getaddrinfo` and
`read_dir` (`lib_eio_linux/low_level.ml:456-742`).

### Testing with a fake world

`Eio_mock.Backend` is a scheduler with no I/O. Because no wake-up can come
from elsewhere, it "can reliably detect deadlock"
(`lib_eio/mock/backend.mli:1-12`). Its mock clocks "advance automatically
when there is nothing left to do" (`backend.mli:21-25`). Fake resources are
separate (`Eio_mock.Flow`, `Net`, `Clock`). The README's determinism note
says fibers in a domain are scheduled deterministically, so with
deterministic mocks the tests are deterministic (`README.md:1567-1587`).

### What Eio regrets

- **Objects, replaced in v0.12.** `doc/rationale.md:64-148` argues that
  objects were the best tool for resources, and then: "in order for Eio to
  be widely accepted… we no longer use objects". The replacement is a
  value plus an extensible GADT for looking up interfaces, and "the
  compiler can't check that the resource really implements all the
  interfaces its phantom type suggests". The changelog is at
  `CHANGES.md:565-579`.
- **Exactly-once racing is unreliable** under completion I/O, as above.
- **Determinism stops at the domain boundary and at `Eio_unix` and
  `Low_level`** (`README.md:1586-1587`).

---

## 2. Java virtual threads (Loom)

### The bottom handler

There isn't really one. Blocking points in the JDK, such as `NioSocketImpl`
and locks, check `Thread.isVirtual()` and change their behaviour. A socket
read sets the fd non-blocking and calls `Poller.poll`, which parks the
virtual thread (`sun/nio/ch/NioSocketImpl.java:166-207, 274-303`). Pollers
are a pluggable group with three modes:

- system threads
- virtual-thread pollers, the default on Linux when continuations are
  supported
- a poller per carrier

These are in `sun/nio/ch/Poller.java:71-123` and
`linux/.../DefaultPollerProvider.java:38-52`. The virtual-thread poller
mode cites Karsten and Barghi's "User-level Threading: Have Your Cake and
Eat It Too" (2020). It integrates polling into scheduling, which is the
same idea as Ren polling inside `ren_run`. Linux uses epoll only; the
sparse tree has no io_uring.

### The world

The world is ambient: `java.io`, `java.nio` and `System.nanoTime`. The
scheduler is ambient too: one static `ForkJoinPool` with FIFO mode,
parallelism set to the number of CPUs and `maxPoolSize` of at least 256
(`java/lang/VirtualThread.java:65, 1330-1356`). A custom scheduler exists
in the code but is reachable only from tests:
`VirtualThreadBuilder(Executor scheduler)` is marked "invoked by tests"
(`java/lang/ThreadBuilders.java:213-222`). JEP 444 ships no public
scheduler interface (https://openjdk.org/jeps/444).

### Blocking calls

Loom handles them with **compensation**. `jdk.internal.misc.Blocker.begin`
and `end` wrap operations that can't unmount, such as many file-system
calls and `Object.wait`. They work like a `ForkJoinPool.ManagedBlocker`:
"the pool can be expanded to support additional parallelism during the
blocking operation" (`jdk/internal/misc/Blocker.java:31-93`). JEP 444
describes this as "temporarily expanding the parallelism of the scheduler",
capped by `jdk.virtualThreadScheduler.maxPoolSize`.

Pinning is different. If a continuation has a native frame or is in a
critical section, it can't yield (`jdk/internal/vm/Continuation.java:58-62`).
A pinned park blocks the carrier itself (`VirtualThread.java:776-855`) and
emits a JFR `jdk.VirtualThreadPinned` event. Compensation does **not**
cover pinning (JEP 444).

### Testing with a fake world

There is nothing built in. The scheduler hook is test-only, and time and
I/O are ambient.

### What Loom regrets

- **`synchronized` pinned carriers.** This was the major production
  complaint and was fixed by JEP 491 in JDK 24
  (https://openjdk.org/jeps/491). JEP 491 rejects "more carriers" as the
  general cure: "If many virtual threads were to block inside a
  synchronized method then no value of parallelism would help."
- **Native frames, class initialisers, and FFM upcalls that block still
  pin** (JEP 491). These cases are deferred "if they prove to be
  problematic".
- **Diagnostics had to change.** `jdk.tracePinnedThreads` was removed and
  replaced by a JFR event (JEP 491).
- **Thread-local caching broke.** Libraries that pooled expensive objects
  in thread locals had to change (JEP 444).

---

## 3. Go

### The bottom handler

It is the runtime scheduler, and network I/O is readiness-based. A
goroutine parks in `netpollblock` (`runtime/netpoll.go:548-583`). Workers
poll epoll from `findRunnable`: non-blocking at `proc.go:3515` and blocking
at `proc.go:3773` when they are idle. `sysmon` also polls if nobody has
for 10 ms (`proc.go:6629-6634`). Cancellation of network I/O is through
**deadlines**, not cancel requests: `poll_runtime_pollSetDeadline` and
`pollUnblock` (`netpoll.go:372, 452`). A blocking syscall can't be
cancelled at all. Go never adopted io_uring
(https://github.com/golang/go/issues/31908; this is from memory, I didn't
re-read the thread).

### The world

The world is ambient (`os`, `net`, `time`). Nothing is passed.

### Blocking calls

Go uses **optimistic handoff**. Every syscall and cgo call is bracketed by
`entersyscall` and `exitsyscall` (`proc.go:4624-4648, 4782, 4928`).
`cgocall` does the same "so that the scheduler knows to create another M"
(`cgocall.go:134-175`). The worker keeps its P during the call. `sysmon`,
a dedicated thread with no P that sleeps 20 µs to 10 ms
(`proc.go:6549-6569`), retakes the P after at least one sysmon tick of
about 20 µs and hands it to another thread (`retake`, `proc.go:6693-6788`;
`handoffp`, `proc.go:3140`). The same loop preempts goroutines that run
longer than `forcePreemptNS` = 10 ms (`proc.go:6691, 6716-6727`). There is
also a pessimistic `entersyscallblock` that hands off immediately
(`proc.go:4836`). The cost is threads: `maxmcount` defaults to 10,000, and
exceeding it is fatal (`proc.go:875`). Callbacks from C re-enter through
`cgocallbackg` and `reentersyscall` (`cgocall.go:311`, `proc.go:4648`).

### Testing with a fake world

Go's answer is `testing/synctest`, a retrofit. A "bubble" is a set of
goroutines with **fake time** that advances only when every goroutine in
it is **durably blocked** (`runtime/synctest.go:13-37`). What counts as
durably blocked is a closed list: sleep, channel operations within the
bubble, `sync.Cond`, select and a few others (`runtime2.go:1389-1403`).
**Blocking on I/O, syscalls or a mutex is not durable**, so tests have to
replace the network with in-memory pipes. The runtime cannot tell an
external wake-up from an internal one, because the world isn't a value.

### What Go regrets

From the code's own comments:

- **Ps stuck in syscalls** are what sysmon exists to fix.
- **Windows synchronous pipe I/O deadlocks** without an eager handoff
  (`cgocall.go:162-170`).
- **The 10,000-thread limit** is a known way for programs blocked in
  syscalls to fall over.

From memory, unverified: cgo's per-call overhead, and the long fight over
`GOMAXPROCS` in containers, which was fixed in Go 1.25 (see
`sysmonUpdateGOMAXPROCS`, `proc.go:7193`).

---

## 4. Zig `std.Io`

### The bottom handler

It is a single vtable passed explicitly as `io: Io` (`lib/std/Io.zig:563-710`).
**The one interface covers scheduling and the world together:**

- task creation: `async`, `concurrent`, `await`, `cancel`, groups and
  `select`
- synchronisation: mutex and condition
- files, directories, `now` and `sleep`, and sockets

Implementations:

- `Io.Threaded` is the default and the only one marked feature-complete.
- `Io.Evented` is M:N with stack switching and experimental.
- `Io.Uring` and `Io.Kqueue` are proofs of concept.
- `Io.failing` supports no operations.

The status of each comes from the 0.16.0 release notes
(https://ziglang.org/download/0.16.0/release-notes.html). In my clone the
`IoUring.zig` file is a work-stealing fiber loop with one ring per thread
(`Io/IoUring.zig:11-40`).

There are two useful distinctions. **`async` may run inline**: "It is
legal for Io implementations to implement async calls simply by directly
calling the function". **`concurrent` must get real concurrency or fail**
with `error.ConcurrencyUnavailable` (`Io.zig:563-594`; release notes). This
matches Ren's `answer_now`, which says a driver may answer inline.

### Cancellation

Cancellation is an error value, `error.Canceled` (`Io.zig:712-715`). The
release notes set the discipline: "Only the logic that made the cancelation
request can soundly ignore an `error.Canceled`". Otherwise you propagate
it, call `recancel()`, or use `swapCancelProtection()`. `Io.Threaded`
cancels a thread blocked in a syscall by sending it a signal: `requestCancel`
calls `pthread_kill` or `tgkill(SIGIO)` (`Io/Threaded.zig:100-112`). The
syscall returns `EINTR`, and the loop re-checks with `checkCancel`
(`Threaded.zig:889-891, 1082…`).

### The world, blocking calls and testing

The world is an explicit parameter. `main` receives it through
`std.process.Init`, known as "Juicy Main" (release notes). Under
`Threaded`, every call is a blocking call on a pool thread, so there is no
special rule for foreign calls: any C call is just a call. Under `Evented`,
a blocking foreign call stalls a fiber's thread. I found no Zig mechanism
for it beyond "use `Threaded`". For tests there is `std.testing.io`, like
`testing.allocator`, plus `Io.failing`. There is no simulated world or
replay.

### What Zig regrets

So far:

- the evented and io_uring backends aren't ready after a full release cycle
  (release notes)
- `Threaded.init_single_threaded` is described as a "non-ideal workaround"

---

## 5. Effect v4

### The bottom handler

Effect has two layers. `Effect.callback(register)` is the primitive
asynchronous boundary (`packages/effect/src/internal/effect.ts:1185-1230`).
`register` gets `resume` and an optional `AbortSignal`, and may return a
cancel effect. A synchronous `resume` inside `register` is taken inline
without yielding (`effect.ts:1199-1207`). That is `answer_now` again.

After an interrupt, `resumed = true`, so **a late resume is silently
dropped** (`effect.ts:1200, 1210-1219`). The interrupt waits for the
registered cancel effect, run as an uninterruptible finalizer
(`effect.ts:1232-1247`). Anything the late value owned is lost unless the
cancel effect handled it.

The scheduler is a service (`Scheduler.ts:34-85`):

```ts
interface Scheduler {
  executionMode: "sync" | "async"
  shouldYield(fiber): boolean
  makeDispatcher(): SchedulerDispatcher
}
```

The yield budget is an operation count, `MaxOpsBeforeYield`
(`Scheduler.ts:199, 294`). That is the same as Ren's `budget` argument to
`ren_run`.

### The world

The world is split, and the split is deliberate:

- **`Clock`, `Random` and `Scheduler` are `Context.Reference`s.** They are
  services with a default value, so they never appear in `R`
  (`Clock.ts:192`, `Random.ts:72`, `Context.ts:315-344`). The default
  `ClockImpl` calls `Date.now()` and `setTimeout` (`effect.ts:6346-6371`).
- **`FileSystem` is a real `Context.Service`.** It is tracked in `R` and
  provided by `@effect/platform-*` (`FileSystem.ts:486`).

So in Effect, time and randomness are ambient with an override, and only
heavy I/O is a dependency.

### Blocking calls

JavaScript has none. Node's own blocking is libuv's thread pool, outside
Effect.

### Testing with a fake world

- `TestClock` must be advanced by hand. It also warns "when a test appears
  to be waiting on time without advancing it" and needs its layer to
  install a tracking scheduler. A clock "from `make` by hand does not
  install the tracking scheduler" (`testing/TestClock.ts:1-50`). Clock and
  scheduler turn out to be coupled.
- `FileSystem.makeNoop` and `layerNoop` give partial fakes
  (`FileSystem.ts:654, 787`).
- `TestConsole` and `TestCrypto` exist too.

### What Effect regrets

A gotcha is documented right in the scheduler, and it bears directly on
Ren's hosted driver. "On Cloudflare Workers, request-owned scheduler timers
can be discarded, leaving shared fibers suspended. Use `new
MixedScheduler("sync")`… Sync mode does not yield to the event loop"
(`Scheduler.ts:163-170`). A host can own and discard the timers the
runtime relies on.

---

## Comparison

| | Bottom handler | Is the request data? | World passed as | Blocking foreign call | Fake world | Does the core read a clock? |
|---|---|---|---|---|---|---|
| Eio | per-domain effect handler | no, a closure | capability object (`env`), with ambient escape hatches | explicit `run_in_systhread`, unbounded, not cancellable | mock backend, auto-advancing clock, deadlock detection | yes |
| Loom | JDK library code that checks `isVirtual` | no | ambient | compensation by growing the pool; pinning not covered | none (scheduler hook only in tests) | yes |
| Go | runtime and netpoll | no | ambient | optimistic handoff through sysmon | synctest bubble; time only, I/O not durable | yes |
| Zig | `Io` vtable | no, a function call | explicit parameter, one big interface | it's just a call (`Threaded`); signal cancel | `testing.io`, `failing` | inside `Io` |
| Effect v4 | `callback` plus `Scheduler` service | no | services; clock and random are defaults outside `R` | not applicable | `TestClock` advanced by hand, noop layers | default service |
| **Ren** | driver below the core | **yes, `D.Call`** | dependency in the row | `blocking`, answered by the driver's pool and journaled | sim driver, replay driver | **no, `now_ns` is passed in** |

No system studied makes the request a value. That is the property that
lets Ren have a journal and replay, and every one of them lacks both. The
closest is Zig's vtable. With one vtable call per operation, a recording
`Io` wrapper is possible, but it would have to be written per function.

---

## What the mapping shows

**Ren's bottom handler is Eio's scheduler handler with the closure turned
into data.** Eio shows the cut works in practice: one handler per worker,
a run queue other threads push into, and an eventfd or `need_wakeup` flag
for wake-ups. Eio's `Enter of closure` is exactly what stops it from
journaling. Ren's `ren_poll_call` returning a `ren_call` value is the fix.

**Every system's scheduler reads the clock, and every fake-time system
paid for it.** Go needed a runtime-level bubble. Effect's `TestClock`
needs its own scheduler. Eio's mock has to own both. Ren passing `now_ns`
in and asking `ren_poll_deadline` is the clean form of what Eio's mock and
Go's synctest compute: advance time when nothing is runnable. Synctest
also shows why Ren's version is stronger. Go can't treat I/O as durably
blocked because I/O isn't a value. In Ren every outstanding wait is a
known call held by the driver, so the sim driver knows the program is
idle.

**Late replies.** The three systems handle a completion that races a
cancel in three ways:

- Eio delivers the completed result.
- Effect drops it.
- Ren releases it.

Release is right for resources: fds and buffers. But it **loses data on
stream sockets**. A `recv` that finished has consumed bytes from the
kernel, and releasing the buffer doesn't put them back. That is Eio's
"`Fiber.first` is not reliable" warning. The model needs a rule for this.

**Blocking calls: Ren sits with Eio and Zig, explicit, not Go or Loom,
implicit.** Go and Loom accept any call and repair the damage afterwards:
sysmon retakes the P, or the pool grows. Both have hard edges:

- Go's thread cap is fatal.
- Loom's pinning isn't compensated.
- JEP 491's warning that "no value of parallelism would help".

Eio and Zig make the blocking call visible. That matches the owner's taste
and the journal. The cost Eio shows is an unbounded pool and calls that
can't be cancelled.

**A foreign call that isn't marked `blocking` but blocks is Ren's version
of pinning.** It stalls a worker, and nothing compensates. Loom answers
with a diagnostic event; Go answers with sysmon. Ren needs at least the
diagnostic.

**With io_uring there is a second hazard.** Eio sets up its rings with
`DEFER_TASKRUN`, and Ren's E-series will want the same for speed.
Completions for a ring are then processed only when its own thread enters
the kernel. A worker stuck in a long, unmarked foreign call therefore
strands every I/O completion on its ring. No other worker can reap them.
Go's answer is sysmon's 10 ms global poll, but that needs a shared poller.

---

## What Ren should take, refuse, or still decide

1. **Take the data cut.** Keep `ren_poll_call` and `ren_reply` carrying
   `D.Call` and `D.Reply` values. All five systems lack replay because
   their requests are closures or function calls (Eio `sched.ml:57-60`;
   Zig `Io.zig:563`). This is the model's biggest advantage. Don't trade
   it away for speed: no "fast path" that runs a closure in the driver
   and skips the value.

2. **The model is MISSING a rule for a completed reply that races a
   cancel.** Proposed rule:
   - If the reply arrives before the task has observed the cancel, it is
     **delivered**, as in Eio (`sched.ml:246-255`). Cancel then surfaces
     at the task's next suspension.
   - The driver **releases** a reply only when its task has gone: the
     scope ended or the task was unwound.
   - A released reply that consumed bytes from a stream, `recv` or
     `read` on a pipe or socket, **poisons that handle**. Later reads
     fail with a "torn" error rather than silently skipping data. The
     journal records the release, so replay reproduces the tear.

   Without this, `Async.race` over two reads loses data with no sign, as
   Eio documents (`README.md:290-296`).

3. **Rename and narrow "the runtime never creates threads" to "the core
   never creates threads."** The real driver has to own threads:
   - a blocking pool, which Eio's posix fallback needs for about 16
     file-system calls
   - possibly a reaper (see item 6)

   Eio and Go both create threads freely. The ABI has nowhere for a host
   to supply pool threads. Either add `ren_host.spawn`, or say plainly
   that drivers are free to make threads. On hosted targets (JSPI) the
   driver must refuse `blocking` calls or route them to a Worker.

4. **Bound the blocking pool, and make cancel of a running blocking call
   explicit.** Eio's pool is unbounded and can't be cancelled once a job
   starts (`thread_pool.ml:116-135`). Go's thread cap is fatal at 10,000
   (`proc.go:875`). For Ren:
   - The pool has a size. Excess calls queue as world calls, which the
     journal already handles.
   - Cancel of a running `blocking` call is a request the driver can't
     always honour. The result is released when the call returns, and the
     journal records it.
   - Signal interruption, as Zig's `Threaded` does (`Threaded.zig:100-112`),
     can be an opt-in per call, since it is only safe for system calls
     that tolerate `EINTR`, not for arbitrary C.

5. **Add a pinning diagnostic.** A foreign call that isn't marked
   `blocking` and runs long is Ren's pinning (Loom
   `VirtualThread.java:833-855`, JFR `VirtualThreadPinned`). The host
   already sees `ren_run` overrun its budget. Give the real driver a debug
   watchdog that names the call site of the foreign call, the way Go's
   sysmon uses `forcePreemptNS` = 10 ms. The core still never reads a
   clock; the watchdog lives in the driver.

6. **Decide how per-worker rings deal with a stuck worker. This is a
   possible FLAW in "one ring per worker".** With `DEFER_TASKRUN`
   (Eio `sched.ml:461`), completions on a stuck worker's ring wait until
   that worker returns. The options:
   - (a) Accept it, since items 4 and 5 make stalls rare and visible.
   - (b) Don't use `DEFER_TASKRUN` for rings whose calls can be stolen.
   - (c) Go's model: a global reaper polls stranded rings after N ms
     (`proc.go:6629-6634`).

   Experiment E5 should measure (a) against (b).

7. **Take Zig's `async` and `concurrent` split as a driver-level fact, not
   a language one.** `answer_now` is Zig's "legal to call directly"
   (`Io.zig:563-570`). Ren already says the journal can't tell the
   difference. Keep it. Also state the inverse: a call that *needs*
   concurrency is a spawn in a scope, never a hint to the driver.

8. **Take Effect's operation budget and Eio's auto-advancing mock clock;
   refuse Effect's untracked `Clock`.** In Effect, `Clock` and `Random`
   are `Context.Reference` defaults outside `R` (`Clock.ts:192`), which
   is convenient, but it hides the world. Ren tracks them as dependencies
   and makes time a reply. That's stricter and right. Two things still
   need deciding:
   - Does `Async.timeout` carry `Clock` in its row, or is the timer
     purely `Async`'s?
   - The sim driver should advance time on idle by default (Eio mock
     `backend.mli:21-25`; Go synctest), not by hand as `TestClock` does.

9. **Make the hosted driver own timers, never borrow request-scoped ones.**
   Effect's Cloudflare gotcha (`Scheduler.ts:163-170`) is a warning for
   the JSPI and Workers design. Host timers tied to a request can vanish.
   The ABI's `ren_poll_deadline` already lets the host decide how to
   wake. Write down that a hosted driver must re-arm from
   `ren_poll_deadline` on every entry, and must treat a lost timer as a
   spurious wake, not a hang.

10. **Refuse Loom's and Go's ambient world and implicit compensation.**
    Loom's custom scheduler stayed test-only
    (`ThreadBuilders.java:217-218`). Go needed a runtime retrofit
    (synctest) to fake even time. Both follow from an ambient world. Ren's
    rule that the world is dependencies in the row, chosen by `main`, is
    the Eio and Zig line, without Eio's escape hatches (`Eio_unix.sleep`,
    the raw `Unix` module). Keep it free of escape hatches. A `trust`
    driver is the only door.

11. **Refuse one big world interface (Zig's vtable).** Zig puts
    scheduling, locks, files, net and time in one `Io`. Ren's split of
    `Async` from `Fs`, `Net`, `Clock` and the rest is better for
    auditing, for the reasons runtime-io.md already gives. Eio's v0.12
    retreat from objects to "a value plus an interface lookup" is what a
    dynamically dispatched, capability-style world converges to. Ren gets
    the same thing statically from `D.Call` and closed-world dispatch.

12. **Take Eio's `Rcfd` rule for closing a handle with calls in flight.**
    Eio's rule is that closing a handle with operations in flight marks
    it closing, and the last user closes it (`rcfd.mli:1-60`). This
    belongs in Ren's driver, together with release. Closing a handle that
    has outstanding calls sends cancels, and the fd is closed when the
    last reply is released. That avoids the fd-reuse corruption `Rcfd`
    describes, and it is what experiment E3 should check under ASan.

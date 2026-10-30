# R6: drivers written in the language itself

Proposal point 3 says drivers are Ren. The world's one primitive is
`Async.submit(call) -> reply`. A world dependency's bottom handler is
Ren inside `trust` that builds a `D.Call` and submits it. A driver
(io_uring, kqueue, epoll, sim) is Ren in `trust` that reaches the OS
through foreign calls; because it uses no world dependency it compiles
to plain code. The host loop is Ren too. Only the core (tasks, scopes,
frame stacks, instances, bounded queues, scheduler policies, the
journal writer, the nine-function ABI) is not Ren.

This file asks what a driver written in its own runtime's language had
to give up in the systems that already do it, and checks the proposal
against that list. It builds on research/runtime/r2-completion-io.md
(buffers, cancel, rings) and r3-effects-kernel.md (bottom handlers,
blocking calls), which already cover monoio, glommio, tokio-uring,
Seastar, Eio, TigerBeetle and Zig at the kernel boundary. Those findings
are cited, not redone.

Sources, read at these commits:

- Go `6c49ac3` (2026-10-26), sparse clone of `src/runtime` only
- Zig `738d2be` (2025-11-26)
- TigerBeetle `0450c32` (2026-10-14)
- tokio `6470b5e` (2026-10-29). mio is not cloned; tokio's use of it is.
- monoio `8675e94` (2026-10-15), glommio `8434815` (2025-04-21)
- Seastar `b3d3270` (2026-10-29), liburing `c6da613` (2026-10-27)

Measured here: Apple M4 Max laptop, shared with other agents (load
average 3 to 7 during runs), tcc 0.9.28rc `e23dabe`.

## The short version

- **Every system that writes its driver in its own language writes it
  in a restricted dialect.** Go's poller is ordinary Go with five
  runtime-only escapes: no write barriers, memory outside the GC heap,
  `linkname`d entry points, raw syscalls on the system stack, and
  atomics on raw words. TigerBeetle and Zig are restricted only by
  convention. Ren's `trust` plus "plain" covers four of Go's five. The
  fifth, memory the kernel holds a pointer to, is the one Ren must spell
  out.
- **A driver never needs to suspend.** Every driver studied handles a
  full submission queue by flushing it to the kernel inline, a
  non-blocking syscall. With Ren's pull ABI it's simpler still: the
  driver pulls calls only while it has room, so a full ring leaves calls
  in the core's queue and their tasks are already parked. "A full ring
  is a full mailbox" is right, and the waiter is the task, never the
  driver.
- **`Async.submit` and `ren_poll_call` aren't two models. They're the
  two halves of one.** `Async.submit` is the scheduling point. It tries
  `answer_now` inline (the fast path, run inside `ren_run` on the
  task's stack), and otherwise queues the call and parks the task. The
  host loop pulls queued calls with `ren_poll_call` between `ren_run`s.
  So driver code runs in three contexts with different rules, and the
  language has to tell them apart.
- **The layering main → host loop → `ren_run` → tasks is sound** if
  two rules hold: the core handle is a value only the driver entry
  receives (Ren has no globals, so a task can't reach it), and `ren_run`
  asserts it isn't re-entered (TigerBeetle's `run_for_ns_active`).
- **What must stay out of Ren:** signal handlers, the entry trampoline
  for any thread that will run Ren code, and C callbacks from threads
  Ren didn't make. Signals come in through signalfd or `EVFILT_SIGNAL`
  as world replies, so no Ren code runs in a handler.
- **What a driver needs from the language that `trust` doesn't yet
  name:** atomics with acquire/release/relaxed orderings and fences
  on raw pointers into mmap'd memory (liburing's ring head and tail), C
  function pointers to Ren functions (the host hooks and thread
  entries), and C-layout records at fixed addresses (a `pthread_mutex_t`,
  an `io_uring_sqe`).

---

## 1. Go: the netpoller is Go, in a dialect

The netpoller's portable half is `runtime/netpoll.go` (733 lines); each
platform adds about 185 (`netpoll_epoll.go`, `netpoll_kqueue.go`). It's
the best evidence that a driver can be written in its runtime's own
language, and the clearest list of what that costs.

**What it had to give up:**

1. **No write barriers, and no allocation from the GC heap.**
   `netpollready` "may run while the world is stopped, so write barriers
   are not allowed" and is marked `//go:nowritebarrier`
   (`netpoll.go:491-494`). `netpoll` is called from `sysmon`, which
   "always runs without a P" and is `//go:nowritebarrierrec`
   (`proc.go:6546-6549`, call at `:6634`), and from
   `startTheWorldWithSema` (`proc.go:1765-1767`).
2. **Memory the kernel points at lives outside the heap.** A `pollDesc`
   is `sys.NotInHeap` with "No heap pointers" (`netpoll.go:74-76`).
   They come from `persistentalloc` in 4 KiB blocks that are never
   freed, because they "can be referenced only from epoll/kqueue
   internals" (`:71`, `:689-714`). The epoll event's data word holds the
   raw pointer (`netpoll_epoll.go:25-34`).
3. **A generation tag on every kernel-held pointer.** The data word is a
   tagged pointer of `pd` and `fdseq`, and an event whose tag doesn't
   match the descriptor's current one is dropped
   (`netpoll_epoll.go:21-34`, `:182`). That's the generation in Ren's
   call id.
4. **Privileged entry points.** The poller's API reaches `internal/poll`
   only through `//go:linkname` (`netpoll.go:211-451`). Ordinary
   packages can't call it.
5. **Raw syscalls, on the system stack.** On Darwin every libc call
   goes through `libcCall`, which is `//go:nosplit` and switches to the
   OS-allocated g0 stack (`sys_libc.go:14-20`; `kevent` at
   `sys_darwin.go:418-426`). On Linux it's raw `EpollWait`.
6. **Atomics on raw words, by hand.** `rg` and `wg` are a CAS state
   machine (`pdNil`, `pdReady`, `pdWait`, or a `*g`) that must never
   lose a ready notification (`netpoll.go:60-68`, `:520-583`). The wake
   is an eventfd with a CAS so concurrent breaks write once
   (`netpoll_epoll.go:80-103`).
7. **Signals never run Go code that allocates, blocks or locks.**
   `sigtrampgo` is `nosplit` and `nowritebarrierrec`
   (`signal_unix.go:434-441`). `sigsend` "runs from the signal handler,
   so it's limited in what it can do". The handler only sets bits that
   a goroutine reads later, and "Most synchronization primitives are not
   available from the signal handler (it cannot block, allocate memory,
   or use locks)" (`sigqueue.go:5-9`, `:68-71`).

**What maps onto Ren and what doesn't.**

- Items 1 and 7 come from a moving, concurrent GC, but the same rule
  appears for Ren in other forms. A signal handler can't touch
  reference counts or the allocator. A callback on a thread with no Ren
  context can't allocate.
- Item 2 is the one Ren must say out loud. Kernel-held memory must not
  move and must outlive its last completion. In Ren that's the task's
  frame (which never moves, since frame stacks grow in linked chunks)
  or a buffer the call lends (r2 §1).
- Item 5 vanishes. Ren's plain code already runs on the native thread
  stack (proposal point 1), so a foreign call is a C call with no stack
  switch. That's a real win of the stackless design.
- Item 6 belongs to the core in Ren, not the driver. Go's driver touches
  the goroutine's park state directly. Ren's driver only calls
  `ren_reply`, and the core owns the park/wake handshake. That removes
  the hardest code from the driver.

## 2. TigerBeetle: the whole driver in Zig, by convention

`src/io/linux.zig` (1896 lines) and `darwin.zig` (1223 lines) are the
whole driver, single-threaded, with completion callbacks.

- **No allocation after startup.** A `Completion` is an intrusive struct
  owned by the caller: `io`, `result`, a queue link, the `operation`
  union, a context pointer and a callback (`linux.zig:374-384`). Its
  address is the SQE's `user_data` (`:459`). The kernel holds a pointer
  to caller memory, and the caller must keep it alive until the
  callback. Nothing checks that.
- **Completions run off a queue, never inline from the reaper:** "to
  avoid recursion through `flush_submissions()` and
  `flush_completions()`, unbounded stack usage, and confusing stack
  traces" (`linux.zig:176-198`). That's Ren's rule that the core's
  trampoline resumes parents, not the driver.
- **A full SQ is flushed inline.** `enqueue` catches
  `SubmissionQueueFull`, logs "consider resizing", flushes and retries
  (`linux.zig:211-227`). **A full CQ blocks:** on `EBUSY` it calls
  `flush_completions(1)`, a wait, and notes "enforcing timeout here is
  impossible" (`:146-160`). Only the second can make a driver wait, and
  only in the host loop.
- **No kernel cancel at all.** There's no `ASYNC_CANCEL` anywhere in the
  tree. The grid's `cancel` drops work it hasn't submitted (`read_queue`,
  `write_queue`) and then waits until `read_iops.executing() == 0 and
  write_iops.executing() == 0` (`vsr/grid.zig:589-640`). That's "cancel
  waits" in its plainest form: retract what's queued, wait out what's in
  flight. It is what r2 §1 recommends for the core (glommio's
  `Enqueued`).
- **A re-entrancy guard.** `run` and `run_for_ns` both
  `assert(!self.run_for_ns_active)` (`linux.zig:77`, `:96`).
- **The driver reads the clock** (`time.monotonic()`, `:103-111`). Ren's
  core doesn't, but its driver will, which is fine.

## 3. Zig std.Io: Threaded and the io_uring loop

`Io/IoUring.zig` (1497 lines) is an M:N fiber loop with one ring per
thread; `Threaded.zig` (6259 lines) is the pool. r3 §4 covers the
interface. What matters here is what they needed beyond plain Zig.

- **Hand-written assembly for the context switch**
  (`IoUring.zig:607-806`, aarch64 and x86_64) and `callconv(.naked)`
  entry functions. Ren's stackless frames need none of it.
- **The thread pool calls `std.Thread.spawn` itself**
  (`Threaded.zig:545`, `:595`, `:717`, `:774`), and the fiber loop does
  too (`IoUring.zig:348`). Both take a thread-safe allocator (`:11-12`).
- **A full SQ is flushed inline:** `getSqe` loops `submit_and_wait(0)`
  until a slot frees (`IoUring.zig:1489-1496`).
- **Cross-thread cancel goes to the owning ring.** `cancel` posts a
  `MSG_RING` with `-EINTR` to the ring of the thread running the
  target; that thread then submits `ASYNC_CANCEL` on its own ring
  (`IoUring.zig:963-993`, `:427-440`). This is r2 §4's "home worker"
  requirement, solved the same way.
- **A signal handler in Zig.** `Threaded` installs
  `doNothingSignalHandler`, a `callconv(.c)` Zig function with an empty
  body, for `SIGIO` and `SIGPIPE`, so a `tgkill` interrupts a blocking
  syscall with `EINTR` (`Threaded.zig:138-151`, `:6255`). Zig can do
  this because nothing in Zig runs implicitly. A Ren function body may
  run reference-count operations Perceus inserted, so an empty-looking
  Ren handler isn't obviously safe.
- **Explicit atomics with orderings everywhere:** `.acquire`,
  `.release`, `.acq_rel`, `.monotonic`, `.seq_cst`
  (`IoUring.zig:219-259`, `:502-512`, `:970-999`).

## 4. tokio, monoio, glommio, Seastar: what is the runtime's own

| | Driver | Runtime's own | SQ full | Grows? |
|---|---|---|---|---|
| tokio | `io/driver.rs` over mio: `turn` polls and dispatches tokens (`:185-240`) | the scheduler; timers (`time/wheel`); the signal driver; the blocking pool | n/a (readiness) | slab of `ScheduledIo` |
| monoio | `driver/uring/mod.rs` | the executor; timers | submit inline (`:439-441`); on `EBUSY`/`EAGAIN`, reap and retry (`:398-420`) | op `Slab` (`:90`, `:587`) |
| glommio | `sys/uring.rs` | the executor; three rings per executor (r2 §4) | an unbounded `VecDeque` of pending SQEs (`:644-657`) | yes |
| Seastar | `reactor_backend.cc` behind an abstract `reactor_backend` (`reactor_backend.hh:212-242`) | the reactor: tasks, timers, signals, smp queues, the stall detector | n/a here | yes |

Notes:

- **tokio's signal handler is Rust** but restricted by hand: "Flag that
  our specific signal was received (e.g. store an atomic flag)" and
  "Wake up the driver by writing a byte to a pipe ... Those two
  operations should both be async-signal safe" (`signal/unix.rs:245-259`).
  The I/O driver sees `TOKEN_SIGNAL` (`runtime/io/driver.rs:108-109`,
  `:215-218`).
- **Seastar's signal handler** only does a relaxed `fetch_or` of a bit
  (`reactor.cc:770-773`), and the reactor runs the C++ handler later
  from its poll loop (`:754-767`). Its cross-core wake skips a SeqCst
  fence and instead uses an expedited `membarrier` on the sleep path,
  with only a compiler fence at the waker: "This is read-after-write,
  which wants memory_order_seq_cst, but we insert that barrier using
  systemwide_memory_barrier() because seq_cst is so expensive"
  (`reactor.cc:3806-3817`; `systemwide_memory_barrier.cc:48-63`). That's
  `trust`-level fence work no ordinary Ren code should see.
- **Seastar's backend returns futures** (`reactor_backend.hh:230-242`),
  so its driver resumes tasks directly. Ren's narrower cut, data out and
  `ren_reply` in, is why a Ren driver needs no task-state atomics (§1,
  item 6).
- **tokio's `ScheduledIo` packs readiness and a driver tick into one
  atomic word** with `AcqRel` CAS (`scheduled_io.rs:104-107`,
  `:218-240`). It's the same stale-event guard as Go's `fdseq`.

Across all four, the runtime's own parts are the same: the scheduler,
timers, signal plumbing, thread creation, and cross-thread wake with its
fences. The proposal puts all of these in the core except timers (a
world call, answered by the driver; SYNTHESIS §2.1) and thread creation
(the driver's, r2 §8 and r3 item 3). Both placements are consistent
with the prior art.

---

## 5. Stress points for "a driver is plain Ren"

### 5.1 Does a driver ever suspend?

No. The evidence:

- **SQ full.** TigerBeetle, Zig and monoio flush inline with a
  non-blocking `io_uring_enter` (§2, §3, §4). glommio queues the
  overflow in user space. None suspends a task.
- **With Ren's pull ABI the driver never sees "full".** The host loop
  drains `ren_poll_call` only while it has SQE slots. The calls it
  doesn't take stay in the core's per-worker queue, and their tasks are
  already parked at `Async.submit`. That queue is where runtime.md's "a
  full ring is a full mailbox" lives. If the queue is bounded and full,
  the *task* waits for room, which is a scheduling point the task was
  already at.
- **CQ overflow** (`EBUSY`): reap, then resubmit (monoio). In Ren the
  host loop does that between `ren_run`s. With `IORING_FEAT_NODROP` the
  kernel keeps overflowed CQEs, so nothing is lost (r2 §7, Seastar's
  required features).
- **`answer_now` must never wait for room.** If it can't answer with
  what it has, it returns "not answered" and the call is queued. That's
  already the SYNTHESIS §2.7 rule ("never blocks").

So proposal point 3's "a driver compiles to plain code automatically" is
**confirmed for suspension**. A driver can't suspend because it has
nothing to suspend on: it has no `Async` in its row.

### 5.2 Does a driver allocate, or take locks other threads hold?

- **Allocation is fine, and often avoidable.** Ren's call id is
  `slot:32 | generation:32` (SYNTHESIS §3), so an io_uring driver can
  put the call id itself in `user_data`. Then it needs **no op table**.
  The buffer's `(ptr, len)` is in the call body, which lives in the
  parked task's frame. That's TigerBeetle's zero-allocation shape with
  the core's slot table as the `Completion` pool. An epoll driver needs
  per-fd queues (compio, r2 §6), and a timer heap grows with sleepers.
  Sizing both to the core's slot capacity keeps them bounded. Plain Ren
  allocation in the host loop or a pool thread is ordinary allocation
  and needs no rule.
- **Locks:** the blocking pool's queue (a mutex and condvar or a futex)
  and `ren_reply` from pool threads. The pool's lock is the driver's
  own, used only by its own threads, so it can't deadlock against the
  core. But Ren must be able to hold a `pthread_mutex_t` at a fixed
  address, which today it can't express (§6).

### 5.3 Where driver code runs: the three contexts

`Async.submit` reconciles the two shapes in the proposal:

```
task code ──► bottom handler (Ren, trust) ──► Async.submit(call)      [scheduling point]
                                                │
                       ┌────────────────────────┴───────────────────────┐
                       ▼                                                ▼
      core calls host.answer_now(call)                   core queues the call,
      (driver Ren code, inline, on the                   the task parks (PENDING)
       task's native stack, inside ren_run)                             │
          answered → DONE, no suspension             host loop: ren_poll_call → SQE
                                                     … io_uring_enter …
                                                     CQE → ren_reply → core wakes task
```

So a driver's code runs in three contexts with different rules:

| Context | Thread | May block the thread? | May call | Must not |
|---|---|---|---|---|
| **A. host loop** | a worker, between `ren_run`s | yes: `io_uring_enter`, `kevent`, `epoll_wait` are its sleep | `ren_run`, `ren_poll_call`, `ren_reply`, foreign calls | be reached from a task |
| **B. `answer_now`** | a worker, inside `ren_run`, on the task's stack | **no** | foreign calls that return at once | any `ren_*`; wait for anything |
| **C. pool thread** | a thread the driver made | yes, that's its job | foreign calls, `ren_reply` | touch any task's state |

Plus a fourth, **D. a signal handler**, where no Ren code runs (§5.6).

What tells A from B? The proposal's colour rule doesn't. Both are plain
code, and "plain" means "can't suspend", not "won't block". The
difference is whether the foreign calls it makes may block, and only
the declaration of the foreign function knows that. This is why r7's
`blocking foreign fn` annotation matters to drivers too: the compiler
can then reject a `blocking` foreign call reached from an `answer_now`
hook. Without it, B's "never blocks" is a comment.

### 5.4 Is main → host loop → `ren_run` → tasks sound?

The order on one OS thread is:

```
C main (core's crt0)
  └─ driver entry: plain Ren, trust           ← chosen statically from main's outermost `with Async.X()`
       └─ ren_start(config, ren_main, host)    ← core
       └─ loop: ren_run(core, w, steps)        ← core
                  └─ task resume fns           ← compiled Ren (suspending or plain)
                       └─ Async.submit → host.answer_now   ← driver Ren, context B
            ren_poll_call / io_uring_enter / ren_reply      ← driver Ren, context A
```

It's sound if a task can never call `ren_run` or anything in context A.
Two rules make that true:

1. **The core handle is a value only the driver entry gets.** `ren_start`
   returns it to the driver entry, and nothing passes it to a task. Ren
   has no globals (README, "A single hole, such as an unchecked FFI call
   or a global ..."), so a task can't reach a `Core` it wasn't given. A
   bottom handler talks to the core only through `Async.submit`, which
   needs no handle because it's the core's own verb.
2. **`ren_run` asserts it isn't re-entered** for a worker, as
   TigerBeetle asserts `!run_for_ns_active` (`linux.zig:77`, `:96`) and Go
   throws "findRunnable: netpoll with spinning" (`proc.go:3757`).
   In debug builds only.

Rule 1 needs `trust` to stop a library from smuggling the handle: a
`Core` must not be storable in a handler's state or captured by a
spawned block. The simplest form is a type that is not data (it can't
cross a `D.Call`, can't be sent, can't be captured), which Ren already
has for instances (foundations.md:83-90). That makes it a typing rule,
not a runtime check.

One wrinkle the proposal hasn't stated: **`with Async.per_core() in
serve()` is written inside `main`, but the driver entry must run before
`main`'s first task does.** So the compiler must find `main`'s outermost
`with Async.X()` statically (it can: dispatch is closed-world) and emit
the entry around it. A `main` that picks its scheduler at run time
(`if flag then per_core else single`) has to be either rejected or
compiled with both entries. Worth one line in runtime.md.

### 5.5 A completion for a cancelled op, and buffers the kernel owns

From r2 §1-2, briefly:

- A cancel produces two CQEs in either order, and the target's may be a
  success. The buffer is the kernel's until the **last** CQE (the
  notification for zero-copy send, the one without `F_MORE` for
  multishot).
- Eio's model fits Ren: the cancelled task stays parked until its own
  completion, so its `inout` buffer is alive because its owner is still
  waiting. No heap hand-off, no `Ignored` state, no reference counts.
- A success after a cancel is delivered, not released. Release is only
  for replies with no waiter. The core decides; the driver acts
  (`ren_reply` returns `ACCEPTED` or `RELEASE`).
- A cancel must go to the call's home ring (`cancel.c:39-44`). Zig's
  `MSG_RING` plus `-EINTR` forwarding (§3) is a working pattern for it.

**What a Ren driver needs from the language for this:**

- **The bottom handler turns an `inout` buffer into `(ptr, len)` inside
  the call body.** That's an address, so it's `trust`. The lifetime is
  "until this call's reply", which no type in Ren expresses. It holds
  by the runtime rules: the frame doesn't move, the task can't resume
  before the reply, and cancel waits. So the audit point is the bottom
  handler, and it's one per world operation, all in std.
- **The driver receives raw pointers.** It must not keep one past the
  reply. Nothing checks that either. A debug driver can poison the
  `(ptr, len)` range after the reply to catch a late write.
- **`ren_kill` must close the rings before the core frees frames.**
  `ren_kill` drops tasks without `finally` (SYNTHESIS §2.6). If it frees
  the frame stacks while the kernel still holds pointers into them,
  that's compio's heap corruption (r2 §1, `iour/mod.rs:59-74`). So
  `ren_kill` must hand the driver a "close everything" step first, and
  that ordering is the ABI's, not the driver author's.

### 5.6 Signals

A signal handler can't be Ren. Ren code can run reference-count
operations and allocation that the source doesn't show, and neither is
async-signal-safe. Every system above keeps its handler to "set a bit,
write a byte" (Go, tokio, Seastar), and Zig manages an empty handler only
because nothing in Zig is implicit.

The way out is to need no handler:

- **Linux: signalfd.** Block the signal in every thread and read
  `signalfd_siginfo` records from an fd, which the io_uring driver reads
  like any other fd. (From memory: the mask must be set **before** any
  thread is created, since threads inherit it, and child processes
  inherit a blocked mask through `exec`, so `Proc.run` must reset it,
  for instance with `posix_spawnattr_setsigmask`.)
- **macOS and BSD: `EVFILT_SIGNAL`** reports signals on the kqueue. It
  coexists with handlers, and the signal can be set to `SIG_IGN` so the
  default action doesn't kill the process (from memory).
- **So `Signal` is a world dependency answered by the driver:** a
  standing `Signal.Call.Next` whose replies are the signals. It's
  journaled like any reply, so replay sees the same signal at the same
  point.

What remains for C is a short fixed list, all the core's:

- `SIGPIPE` set to `SIG_IGN` (and `MSG_NOSIGNAL` on sends, as
  TigerBeetle does, `linux.zig:435`);
- a crash handler for stack overflow on the native stack (plain code
  recursing deeply) that prints the task path;
- an empty `SIGIO`-style handler, only if a pool ever interrupts a
  blocking syscall with `EINTR`, as Zig's `Threaded` does. r3 item 4
  says opt-in only, so likely not in 1.0;
- a stall-detector timer signal, if the watchdog ever samples a stack
  as Seastar's does (`reactor.cc:3435-3438`). The SYNTHESIS watchdog
  reads `ren_progress` from another thread instead, which needs no
  signal.

### 5.7 Threads

runtime.md says "The runtime never makes a thread. A worker is a thread
the host made." r3 item 3 already narrowed that to "the core never
makes a thread". The driver makes worker threads and pool threads.

Making a thread from Ren means calling `pthread_create` with a C
function pointer, and that pointer is the problem. The new thread
starts with no Ren thread context: no `ren_thread_init`, no allocator
cache, no current worker. Ren code that runs before that setup may not
allocate. Go needs an "extra M" for exactly this case: "Create an extra M
for callbacks on threads not created by Go" (`proc.go:1955-1956`,
`needm` at `:2401`).

**Fix:** the core provides the trampoline. Something like
`ren_thread_start(core, kind, entry, arg)`. It calls `pthread_create`
on a C function that runs `ren_thread_init` (for a worker) or a minimal
Ren-context init (for a pool thread), then calls the Ren entry. The
driver still decides when and how many threads to make, so "the core
never makes a thread" holds in spirit: the core only provides the
doorway. The alternative is to let a Ren `extern "C"` function run
before any init. That needs a "no allocation, no counts" dialect checked
by the compiler, and it's more language for one call site.

### 5.8 Fences and atomics

What liburing does on the ring, which a Ren io_uring driver must do too:

- **SQ tail:** a plain store without SQPOLL, `smp_store_release`
  with it (`queue.c:263-273`). The kernel reads SQEs after the tail.
- **SQ head:** a relaxed `READ_ONCE`, "doesn't need to be load_acquire,
  since the kernel doesn't store to the submission queue"
  (`queue.c:275-281`).
- **CQ tail:** `smp_load_acquire`; **CQ head:** `smp_store_release`
  (`liburing.h:463`, `:504`, `:1794`, `:1893`).
- **SQPOLL wakeup check:** a full `smp_mb` between the tail store and the
  flags read (`queue.c:27-34`).
- **Buffer rings:** `smp_store_release` of the tail (`liburing.h:2033`).

All of them are defined over `stdatomic.h` on raw addresses into mmap'd
memory (`barrier.h`). Decision 10 already puts "weaker orderings,
fences, and anything that hands out an address" in `trust`
(foundations.md:690-694). The gap is the shape. Ren's atomics are
**fields of a lock-free handler**, all SC. The driver needs
**operations on a raw pointer** with an ordering argument: `load(p,
acquire)`, `store(p, v, release)`, `load(p, relaxed)`, `fence(seq_cst)`.

tcc handles C11 atomics without system headers beyond `stdatomic.h`,
but lowers them to calls (`___atomic_load_4`, `___atomic_store_4`,
`_atomic_thread_fence`, measured here: `tcc -c at.c && nm at.o`, at.c in
scratchpad `r6-drivers/`). That's correct and slow, which is fine in a
debug build.

The alternative is to keep the ring access in C, as liburing's own
static inline functions, and give Ren `io_uring_get_sqe` and
`io_uring_cq_advance` as foreign calls. That's smaller and safer, but
liburing's API is mostly `static inline` in a header, so it needs a C
shim compiled into the driver (r7 §8), and then the "driver is Ren"
line moves down by about 200 lines of C.

---

## 6. What the language must add for a Ren driver

Collected from §1 to §5. Everything is inside `trust`:

| Need | Why | Prior art |
|---|---|---|
| raw pointers and `(ptr, len)` from an `inout` buffer | call bodies carry kernel-bound buffers | TigerBeetle `Completion`, Go `pollDesc` |
| atomic load/store/RMW on a raw pointer with an ordering, and fences | ring head/tail, wake flags | liburing `barrier.h`; Zig `@atomicLoad(.., .acquire)` |
| C-layout records at a fixed address | `io_uring_sqe`, `pthread_mutex_t`, `kevent`, `sigset_t` | formats (decision 19) give layout; a fixed address is new |
| a Ren function as a C function pointer, plain, C-typed params | host hooks (`wake`, `answer_now`, `journal`), thread entries | Zig `callconv(.c)`, Swift `@c` (SE-0495) |
| `blocking` on foreign declarations | to reject a blocking call in `answer_now` (§5.3) | r7 |
| the core handle as non-data | stop a task reaching the host loop (§5.4) | instances are already non-data |

And what stays in the core, in C, Rust or Zig, beyond the proposal's list:

- **the thread-entry trampoline** (§5.7);
- **the fixed signal dispositions and the crash handler** (§5.6);
- **teardown order in `ren_kill`**: drivers close rings before frames
  are freed (§5.5);
- the park/wake handshake and its fences (already the core's: SYNTHESIS
  §2.7).

What doesn't need to stay out of Ren: the ring `mmap` itself. It's a
foreign call that returns a pointer, done once at start, and nothing
about it is timing-sensitive. Probing for io_uring and falling back (r2
§7) is plain driver code too.

---

## What this means for Ren

### Proposal point 3, "drivers are Ren"

**Confirmed: a driver compiles to plain code and never needs to
suspend.** Go's netpoller is ordinary Go in a dialect, TigerBeetle's and
Zig's drivers are ordinary Zig, and none of them waits on a full ring
from a task (TigerBeetle `linux.zig:211-227`, Zig `IoUring.zig:1489-1496`,
monoio `uring/mod.rs:439-441`). With Ren's pull ABI the driver pulls only
what it can submit, so the core's queue absorbs a full ring and the task
is already parked.

**Confirmed: the core's list is nearly right.** The runtime-owned parts
across tokio, monoio, glommio and Seastar are the scheduler, timers,
signals, thread creation and cross-thread wake. Ren moves timers to the
driver (SYNTHESIS §2.1) and thread creation to the driver (r3 item 3).
Both are consistent with what the prior art does.

**Missing: the non-Ren part needs three more things.** Fix: add to
runtime.md's core list:

1. **the thread-entry trampoline** (`ren_thread_start`), since a thread
   created by a bare `pthread_create` into Ren has no context, the same
   reason Go keeps an "extra M" (`proc.go:1955-1956`);
2. **the fixed signal dispositions and a crash handler.** User signals
   arrive as `Signal` world replies from signalfd or `EVFILT_SIGNAL`, so
   no Ren code ever runs in a handler;
3. **teardown order:** `ren_kill` makes the driver close its rings
   before frame stacks are freed.

**Wrong as written: "the host's hooks are leaves" isn't enforceable
without types.** `answer_now` is driver Ren code running inside
`ren_run` on the task's stack. "Never blocks" and "never calls `ren_*`"
are comments today. Fix: (a) mark foreign functions `blocking` (r7) and
reject a `blocking` foreign call reachable from a hook; (b) make the
core handle non-data, so a hook or task can't hold it; (c) assert
non-re-entry in `ren_run` in debug builds (TigerBeetle
`linux.zig:77`, `:96`).

**Missing: `Async.submit` is the reconciling verb, and runtime.md
should say so.** One sentence: "`Async.submit` is a scheduling point.
The core offers the call to `answer_now`; if it isn't answered, the call
is queued for `ren_poll_call` and the task parks." Then the two ABI
shapes stop looking like two models.

**Missing: `main`'s scheduler must be static.** The driver entry wraps
`main`, so the compiler must read `main`'s outermost `with Async.X()`
at compile time. A run-time choice either compiles both entries or is
rejected. Recommend: reject in 1.0.

### Candidate open decisions

1. **Ring access in Ren or in a C shim?**
   - Recommendation: **Ren, with raw-pointer atomics in `trust`.**
     It's what makes "drivers are open" true for users, and it's about
     a dozen ordering sites (§5.8).
   - Tradeoff: every driver author must get acquire/release right on
     raw memory, where glommio's `Relaxed` sleep flag already looks
     wrong (r2 §5). A shim is about 200 lines of C that is easier to
     audit.
2. **What `trust` atomics look like.**
   - Recommendation: **free functions on `Ptr<T>` taking an ordering
     (`relaxed`, `acquire`, `release`, `acq_rel`, `seq_cst`), plus
     `fence(order)`,** mapping one-to-one onto C11. Keep decision 10's
     SC `Atomic` fields as the only atomics outside `trust`.
   - Tradeoff: two atomic surfaces. But a field-based API can't name a
     word in mmap'd kernel memory.
3. **Can a Ren function be a C callback before thread init?**
   - Recommendation: **no.** All threads enter Ren through the core's
     trampoline. C callbacks from foreign threads are r7's rule: post a
     completion only.
   - Tradeoff: one extra C function in the core, versus a checked
     no-allocation dialect in the language.
4. **Signal handling: handlers or fds?**
   - Recommendation: **fds only for user signals** (signalfd,
     `EVFILT_SIGNAL`), with the mask set in the driver entry before any
     thread exists, and reset in `Proc.run`'s children.
   - Tradeoff: a C library that installs its own handler or unblocks
     signals on its thread breaks signalfd delivery. That's a `trust`
     hazard to document, not to solve.

### Experiments worth running

- **E-D1: a Ren-shaped io_uring driver in C, written as the Ren compiler
  would emit it.** Plain functions only: the call id in `user_data`, no
  op table, pulls from a mock `ren_poll_call`, and ring access through
  C11 atomics on raw pointers. Compare with liburing's inline functions
  on a 1-byte `recv` loopback ping-pong. **Predicted:** within 5% of
  liburing under clang -O2. Under tcc, 1.5 to 3 times slower on the
  ring operations because each atomic is a call, which is invisible
  next to a syscall (about 1 µs).
- **E-D2: allocation count.** Run E-D1 at 10k concurrent calls and
  count `malloc`s after warm-up. **Predicted:** zero for io_uring, as in
  TigerBeetle. For the epoll fallback, zero once per-fd queues are
  sized to the core's slot capacity.
- **E-D3: signalfd under the driver.** SIGINT and SIGTERM delivered as
  `Signal.Call.Next` replies while 8 workers and a 4-thread pool run.
  Then spawn a child and check its signal mask. **Predicted:**
  delivered with no handler. The child inherits the blocked mask unless
  it's reset (from memory; this is what the experiment checks).
- **E-D4: re-entry guard.** A `trust` test that tries to call the host
  loop from a task must fail to compile (non-data core handle). A debug
  build must panic on `ren_run` re-entry. **Predicted:** both are
  cheap; the assert is one load and compare per `ren_run`.

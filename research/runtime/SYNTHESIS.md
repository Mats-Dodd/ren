# Runtime research: synthesis

This pulls together the six prior-art tracks in this directory:

- [r1-sans-io.md](r1-sans-io.md): sans-I/O cores (quinn-proto, str0m, rustls, h11, h2, s2n-quic)
- [r2-completion-io.md](r2-completion-io.md): completion I/O (compio, monoio, glommio, tokio-uring, Seastar, Eio, TigerBeetle, the kernel)
- [r3-effects-kernel.md](r3-effects-kernel.md): effects meeting the kernel (Eio, Loom, Go, Zig `std.Io`, Effect v4)
- [r4-journals-replay.md](r4-journals-replay.md): journals, replay and simulation (Restate, Temporal, Durable Task, rr, FoundationDB, TigerBeetle, madsim, turmoil, shuttle)
- [r5-hosted-wasm.md](r5-hosted-wasm.md): hosted runtimes and WASM (JSPI, the Component Model, trio, libuv, Go wasm, Kotlin/Wasm, workerd, wasmtime)
- [r6-scheduling.md](r6-scheduling.md): scheduler internals (tokio, Go, BEAM, Loom, rayon, Seastar, glommio, FoundationDB, Effect v4)

It reviews the agreed runtime model and the draft C ABI. Where a report's claim
drives a recommendation here, I re-checked the citation against the source;
the section "Citations checked" at the end lists what I confirmed and what I
couldn't.

## The verdict in one paragraph

The model's shape is right, and on one point no prior system matches it.
Requests as values, a sans-I/O core, drivers as the bottom handler,
completion-shaped calls, and a buffer that belongs to the driver until the
reply all hold up. None of the twenty-odd systems studied makes the world
request a value, and that is why none of them can both replay and swap
drivers. The draft ABI has four real faults:

1. Time enters the core twice.
2. Rule 4 (release late replies) would break async.md's promise that
   cancellation never loses a result.
3. "A worker is any thread" conflicts with how io_uring rings bind to threads.
4. The journal can't be written by drivers, because only the core knows when
   a reply was delivered.

The ABI is also missing things every mature runtime has:

- call identity, and the worker that issued each call;
- cancel as a call;
- a way to return buffers;
- teardown;
- a journal sink;
- a counted budget;
- a world poll on a count, not only when idle.

Each fix below is small, and together they make the model more consistent
with its own sentences.

---

## 1. Confirmed: what the prior art supports

**The sans-I/O cut, with pull-based output.** quinn-proto's split is
`handle_event` in, `poll_transmit` out and `poll_timeout` for the deadline
(`quinn/quinn-proto/src/connection/mod.rs:392,466,1145`). It is the draft's
`ren_reply`, `ren_poll_call` and `ren_poll_deadline`. s2n-quic runs one core
under tokio, a seeded test executor, turmoil and XDP
(`s2n-quic/quic/s2n-quic-core/src/endpoint/mod.rs:92-137`,
`s2n-quic-platform/src/io/{tokio,testing,turmoil,xdp}.rs`). That is "one core,
many drivers" shipping today. Pull gives backpressure for free: a driver
whose queue is full simply stops pulling (R1 §1).

**Requests as data is Ren's unique asset.** Eio's bottom handler is the
closest relative: one effect handler per domain, a run queue other threads
push into, and an eventfd wake (`eio/lib_eio_linux/sched.ml:333-403`, `:39-83`).
But its world request is a closure (`Enter`, `sched.ml:57-60`), and Zig's is a
vtable call (`zig/lib/std/Io.zig:563`). Neither can journal. R3's comparison
table shows no system studied that has both a value-shaped request and replay.
The one rule here: no "fast path" may skip the `D.Call` value.

**The buffer belongs to the driver until the reply (rule 3).** Every working
completion runtime arrived at this, usually after shipping the bug first
(compio `key.rs:109-118`, tokio-uring `Lifecycle::Ignored`, monoio `MaybeFd`;
R2 §1). The Component Model's `stream.read` states the same rule for WASI 0.3
(R5). Ren can keep the buffer in the waiting task's frame, as Eio does, rather
than copying Rust's heap hand-off. Rust needs that hand-off only because drop
can't wait.

**Completion-shaped requests, with a readiness fallback that emulates them.**
compio's poll driver gives each op a `Decision` of `Completed`, `Wait` or
`Blocking` (`compio-driver/src/sys/driver/poll/op.rs:13-27`). These map one to
one onto `answer_now`, readiness emulation and the blocking pool, and the
core needs none of it. The epoll fallback is mandatory, not optional. Docker
25's default seccomp profile (moby #46762), Google production, ChromeOS and
Android all block io_uring. TigerBeetle's server has no fallback and broke
under Docker 25 (R2 §7).

**One ring per worker (rule 6)** is the idiom everywhere: compio, monoio,
glommio, Seastar, tokio-uring and Eio. The liburing man page discourages
sharing a ring.

**Drivers may answer inline (`answer_now`).** Zig says it is "legal for Io
implementations to implement async calls simply by directly calling the
function" (`Io.zig:563-594`). Effect takes a synchronous `resume` inline
(`effect/packages/effect/src/internal/effect.ts:1199-1207`). libuv's
`uv_backend_timeout` returning 0 is the same idea.

**"Time is a reply" is what every simulator and durable-execution system
does.** FoundationDB's `Sim2::now()` is a field, advanced to the next timer
when nothing is ready (`foundationdb/fdbrpc/sim2.cpp:1240,1593-1601`). In
Temporal and Restate, timers are commands and firings are notifications.
workerd freezes `Date.now()` between I/O
(`workerd/src/workerd/io/io-context.h:200-212`). Systems that let the
scheduler read the clock paid for it:

- Go needed `synctest` retrofitted into the runtime, and it still can't treat
  I/O as durably blocked (`go/src/runtime/synctest.go:13-37`).
- Effect's `TestClock` needs its own scheduler (`testing/TestClock.ts:1-50`).
- Ren is stricter than Effect v4 here. Effect keeps `Clock` and `Random` out
  of `R` (`Clock.ts:192`), and that is the right thing to refuse.

**Stackless frames (decision 12) are what make hosted runtimes possible.**
`ren_run` can return to JS between steps with nothing on the wasm stack. The
Component Model's stackless callback ABI returns EXIT, YIELD or WAIT
(`component-model/design/mvp/Concurrency.md`, around 1325-1343). Those are
`done`, `running` and `idle`. Go's wasm port shows the cost of the other
path: resume points in every function, and no async preemption
(`go-wasm/wasmobj.go:280-300`, `go/src/runtime/preempt_wasm.s`). JSPI works
(Chrome 137, Firefox 153, Safari 27; Node 24.22 without a flag, checked
locally by R5), but Ren needs it only for `blocking` foreign calls.

**"The runtime never creates threads" is exactly right for the web.**
Emscripten pre-creates Worker pools because a Worker can't start
synchronously. The host makes N Web Workers, and each calls
`ren_run(core, i, ...)` (R5).

**Explicit `blocking` beats implicit compensation.** Go retakes a stuck P
through sysmon and dies at 10,000 threads (`go/src/runtime/proc.go:875`).
Loom grows its pool but can't compensate for pinning, and JEP 491 says "no
value of parallelism would help". Eio and Zig make the blocking call visible,
as Ren does (R3).

**No preemption of pure code.** Every deterministic system counts rather than
times its switches: BEAM reductions, Effect ops, tokio budget units, rr's
branch ticks, FoundationDB's seeded counter in simulation. Ren can't preempt
code with an empty row in any case: it has no frame, and a scheduling point
there would break `Mem.snapshot`'s rule (foundations.md:630-632). Go measured
7.8% for loop-check preemption before choosing signals. The reversal at
foundations.md:1369 stands (R6).

**Decision 10 and the keyed family have outside support.** Durable Objects'
input gate is "an operation keeps its instance until it returns". Their output
gate fixes the very "published as durable before fsync" bug decision 10 cites
(`workerd/src/workerd/io/io-gate.h:6-20`).

**Two layers of chaos.** str0m's `Netem` and s2n-quic's `havoc` are
themselves sans-I/O machines. That matches "scoped chaos is a handler over a
dependency; world chaos is the sim driver" (R1 §5).

---

## 2. Wrong or missing, with fixes

Ordered by how much they change the model.

### 2.1 Time enters the core twice (WRONG)

`ren_run(…, now_ns, …)` hands the core a clock reading, and `Clock` replies
hand it another. If the core uses `now_ns` to fire timers, the core is reading
a clock, and replay depends on when the driver happened to call `ren_run`.
R1 and R4 both flag this. R3 and R6 call `now_ns` "cleaner than Eio" and keep
it, but only in comparison with reading a clock directly.

There is also a bug that follows `ren_poll_deadline` everywhere: a deadline at
or before `now` makes the driver spin. Examples are str0m #863, #1017 and
#1052 (`str0m/CHANGELOG.md:58,96,184`), str0m's own harness forcing time
forward (`tests/common.rs:122-127`), and Go's wasm host re-calling `resume()`
in a loop (`go-wasm/wasm_exec.js:285-291`).

**Fix: timers are world calls.** `Clock.Call.SleepUntil { t }` is answered
by the driver, and a fired timer is its reply.

- `now_ns` and `ren_poll_deadline` leave the ABI.
- The real driver keeps the timer wheel (or uses `IORING_OP_TIMEOUT`). The
  sim driver jumps virtual time to its earliest pending sleep when `ren_run`
  returns `idle` (FoundationDB, quinn's `Pair::step`, Eio's mock). The replay
  driver answers from the journal.
- The hosted driver arms `setTimeout` from its own sleeps. That also settles
  R3's warning that Cloudflare can discard request-owned timers
  (`effect/packages/effect/src/Scheduler.ts:163-170`): the timers belong to
  the driver, which re-arms them.
- Wall time (`Clock.now`) stays an inline `answer_now` reply. Monotonic time
  is used only by `SleepUntil`. Both are journaled.

The cost is that a timeout becomes a call plus a cancel. R1's "deadline as a
field of a call" (Go's `SetReadDeadline`, io_uring link timeouts) is the
optimization, but don't add it until E2 shows a need. R2 also argues against
link timeouts for `Async.timeout` in 1.0.

### 2.2 Rule 4 is the wrong default, and the model has no rule for a reply racing a cancel (WRONG)

Rule 4 says "a late reply is released by the driver". async.md:316-319 says
"It never loses a result… a cancel that arrives as a read completes lands at
the task's next call", and runtime-io.md:65-80 says "cancelling waits for the
kernel". These conflict. The prior art splits three ways:

- Eio delivers a non-negative result even after a cancel, and reports
  `Cancelled` only when the operation itself failed
  (`eio/lib_eio_linux/sched.ml:246-255`, checked).
- Effect drops a late resume (`internal/effect.ts:1200-1219`, checked).
- tokio-uring leaks the fd of a late `accept` (R2 §2).

Releasing a reply doesn't undo its effect. A WAL write that completed after
its cancel has happened, and releasing its reply only means the writer never
learns its offset moved. A `recv` that completed has consumed bytes from the
socket, which is Eio's documented `Fiber.first` hazard (`eio/README.md:290-296`).

**Fix: cancellation waits, and the reply goes to the waiter.**

- A cancelled task stays parked until its call's final reply. "Final" means
  the CQE without `F_MORE` for multishot, and the notification CQE for a
  zero-copy send.
- That reply is delivered: either the real result, or `Cancelled`. The task
  sees the cancel at its next call, as async.md already says.
- Release is only for replies **nobody waits for**:
  - calls abandoned when the 5 s cleanup deadline expires;
  - teardown, kill and panic;
  - multishot leftovers;
  - the driver's own speculative work.
- A released reply that consumed stream bytes **poisons that handle**: later
  reads fail as torn rather than silently skipping data (R3 item 2).
- **The core decides and the driver acts.** `ren_reply` returns `ACCEPTED` or
  `RELEASE`, because only the core knows whether a waiter remains and only
  the driver knows how to close an fd or return a buffer. This is compio's
  `set_result` contract (`sys/driver/iour/op.rs:61-74`) split along the
  sans-I/O line.
- **A cancel the driver hasn't pulled yet is retracted in the core,** with no
  round trip, as glommio does for ops still in its `Enqueued` state.
- **Name the reply states** after the Component Model's terminal states
  (`Concurrency.md`, around 779-835): `Done(result)` and `Cancelled` (the call
  had no effect). Release is the core's answer to the driver, not a third
  state the task sees.

### 2.3 "A worker is any thread calling `ren_run`" (WRONG as written)

`IORING_SETUP_SINGLE_ISSUER` makes the kernel fail submissions from any other
task with `-EEXIST` (`liburing/man/io_uring_setup.2:293-309`, checked), and
`DEFER_TASKRUN` requires it. Eio uses both (`sched.ml:460-464`).

**Fix: the core never creates threads, and a worker id is bound to one OS
thread for life.**

- The binding happens at `ren_thread_init` or the first `ren_run`. A debug
  build asserts that the thread never changes.
- An io_uring driver creates rings `R_DISABLED` and enables each on its
  worker's thread.
- Every host studied fits this: Web Workers, a native pool, workerd's single
  thread.
- Also state **one `ren_run` per worker at a time** (R5 item 7).

The rule as worded is also contradicted by Ren's own native slice. It runs
`main` "on a thread with a 1 GiB stack" (compiler.md:1566-1571, checked). The
fix is to say that the *default host*, Ren's own `main` binary, creates the
worker threads and their stacks, while the core only takes a stack. On wasm
the shadow stack is small and overflow isn't trapped, so the frame limit must
come from the host per worker. That needs a `ren_thread_init(core, worker,
stack_lo, stack_size)`.

**Drivers may create threads.** The blocking pool and io-wq (kernel threads)
are the driver's, and both are explicit limits:

- the pool has a size, and excess `blocking` calls queue;
- the driver sets `IORING_REGISTER_IOWQ_MAX_WORKERS`.

Eio's pool is unbounded (`eio_unix.mli:72-78`), and Go's thread cap is fatal.
BEAM's split of dirty schedulers into CPU and I/O
(`erts/doc/references/erl_cmd.md:940-994`) suggests two pool sizes later.

### 2.4 The journal can't be the drivers' job (MISSING)

Restate's protocol says "on replay the SDK MUST observe the same relative
order" of notifications
(`sdk-shared-core/docs/service-invocation-protocol.md:155`, checked).
Decision 11's "the journal records each poll" says the same. Replies arrive
through `ren_reply` from any thread, so their **arrival** order is noise. The
**delivery** step is what replay needs, and only the core knows it.

**Fix: the core writes the journal through a sink in `ren_host`.**

- Entries: `Call`, `Deliver(reply, step)`, `Cancel`, `Release`, `Choice`
  and `End`.
- An `answer_now` reply goes through the same path, so the journal can't tell
  inline from queued, as the model wants.
- **The cancel race is decided at delivery and journaled.** Replay must force
  the same outcome, so the replay driver answers with the recorded state
  (`Done` or `Cancelled`) rather than racing.
- **Header:** build fingerprint, scheduler, worker count, driver kind and
  kernel features, bytes policy. A replay under a different build warns, then
  stays strict. This is Restate's immutable deployments, not Temporal's
  `patched()`.
- **The bytes policy is per direction.** Inputs (reply bytes, including bytes
  written into an `inout` buffer, which rr records as `memWrites`) are stored.
  Outputs (call bytes) are hashed. A journal without its inputs is
  *check-only*, and `ren replay` refuses it at load (Restate's "ephemeral
  command" rule).
- **Divergence has kinds.** Report whether a call differs (with an argument
  diff, or a hash), a delivery point differs, the run ended early or late,
  the build differs, or a schedule diverged at an unrecorded lock-free or
  snapshot access. Always give the task path and call site.
- **A determinism self-check:** keep a rolling digest of entries, run the
  seed twice, and report the first difference (madsim `rand.rs:63-85`,
  FoundationDB's unseed).

This also settles R1's worry that `budget` leaks into behaviour, as quinn's
transmit bound leaked into congestion control. If the core records the step
at which each reply is delivered, where `ren_run` stopped doesn't matter to
replay.

**Scheduler choices are calls too** (R4 item 4). The deterministic scheduler
asks `Sched.Call.Pick { runnable: [task path] }` inline at each place where
order is visible. The seed answers it (sim), the journal answers it (replay),
or FIFO does (`single`). That is shuttle's whole scheduler interface
(`shuttle/shuttle-engine/src/scheduler/mod.rs:75-101`). It folds
`sim.scheduler(seed)` into the two axes: one deterministic scheduler, with
the sim driver supplying both world answers and choices. That is the model's
own picture, made literal.

**Servers journal per unit.** Every durable-execution system journals one
invocation or workflow, never a process (R4 §3). A whole-program journal is
for CLIs, tests and bug reports. For flottning the useful journal is one
request's subtree, through `recorder over <shared dep>`. Write this down now,
so nobody expects `ren run --record` on a server to produce a replayable file
of reasonable size.

### 2.5 Calls need identity, a home worker and a lane (MISSING)

- **Identity:** a 64-bit id made of a slot and a generation, so a late reply
  can't hit a reused slot (the io_uring `user_data` ABA problem, R1 item 5).
- **Home worker:** `io_cancel_req_match` returns false when
  `req->ctx != cd->ctx` (`linux-iouring/cancel.c:43`, checked). A cancel only
  finds requests in its own ring, so cancels and lease returns must be pulled
  by the worker that submitted the call, not the one running the cancelling
  task. Remote replies wake the task onto its home worker's queue or the
  injection queue, never the replying thread's (tokio's `schedule_task`).
- **Lane:** the inbound event the call's task tree descends from. workerd
  throws "Cannot perform I/O on behalf of a different request"
  (`workerd/src/workerd/io/io-context.c++:1977-1983`, checked). The Component
  Model asks for "guest task affinity" (`Concurrency.md:1486`). Ren already
  has the data: the head of the task path. It costs one field now, and
  retrofitting it later would change the layout.
- **Wire layout:** a defined byte layout for `ren_call` and `ren_reply` that a
  JS or WASI driver can decode. Make it **the journal's record format**: one
  encoding for the journal, the hosted ABI and a dependency-as-protocol's
  wire (R5 item 3). Have the compiler emit a descriptor so JS drivers can be
  generated.

### 2.6 Cancel, lease return and teardown have no carrier (MISSING)

- **Cancel** is a call kind, `Cancel { id }`, pulled through `ren_poll_call`
  on the home worker.
- **Lease return.** With provided buffers, a network receive carries no
  buffer, and its reply carries a lease the driver chose:
  `Net.Call.Recv { conn, max }` → `Net.Reply.Chunk(lease)`. At 100k idle
  connections this costs a shared pool instead of 6.4 GB (R2 §3, the
  arithmetic is R2's). The lease must go back to the ring that owns it, from
  whichever worker dropped it.
  - It is a call kind `Return { lease }` with no reply, routed to the home
    worker. It isn't journaled as a world call.
  - `ENOBUFS` is the driver's backpressure (re-arm the receive, or poll
    first), never a user error.
  - The epoll driver allocates on `EPOLLIN`, which gives the same memory
    profile.
- **Close must cancel.** Closing an fd doesn't cancel io_uring requests on it
  (`io_uring_cancelation.7`). The driver's `Close` submits
  `ASYNC_CANCEL_FD | ALL` on the home ring first, and the fd is closed when
  its last reply has been handled (Eio's `Rcfd`, `rcfd.mli:1-60`). The sim
  driver must model this too, so tests can't pass on semantics the real
  driver lacks.
- **Teardown.**
  - `ren_stop` cancels everything, then the host keeps running and draining
    until `done`, and only then closes rings. compio corrupted its heap by
    getting this order wrong (`sys/driver/iour/mod.rs:59-74`), and
    tokio-uring hangs on drop (#102).
  - `done` still has to be drained. rustls appends alerts after an error,
    and h11 needs `send_failed` (R1 item 11).
  - `ren_kill` drops a core **without** running `finally`, so the sim driver
    can model a crash and discard un-fsynced writes.
  - `ren_start` must hold **no global state**, so a whole flottning cluster
    can run in one process, as FoundationDB, TigerBeetle, turmoil and madsim
    all do (R4 §7).

### 2.7 Wake, drain and reply-to-tick contracts (MISSING as rules)

- **`wake` and `answer_now` are leaf callbacks.** Neither may call any
  `ren_*` function, and `answer_now` must not block. In JS, re-entering
  `ren_run` corrupts the scheduler. Under JSPI, a JS frame that calls into
  wasm traps a suspension (R5, checked locally).
- **`wake` is a sticky, idempotent permit,** called by the core only for a
  parked worker, under a SeqCst sleep/wake handshake. All three Rust runtimes
  skip the syscall when the target is awake. glommio's `Relaxed` flag looks
  like a lost-wakeup window (`glommio/src/sys/mod.rs:309-349`); that is R2's
  reading of the code, not a confirmed bug.
- **Every `ren_reply` leads to a tick.** The core calls `wake(home)` if that
  worker is parked. trio needed `force_guest_tick_asap` for exactly this
  (`trio/src/trio/_core/_run.py:765-782`).
- **Drain contract** (str0m's six steps, `str0m/src/lib.rs:151-166`):
  1. call `ren_run`;
  2. pull `ren_poll_call` until it returns false, the single "drained"
     signal;
  3. only then sleep.

  A driver may hold a pulled call and submit it later (quinn's
  `buffered_transmit`). A debug build asserts the driver drained.

### 2.8 Fairness: a counted budget, and polling the world on a count (MISSING, and one spec bug)

- **Budget.** Handler operations on uncontended instances, and `answer_now`
  replies, never wait. So a loop of `memtable.put` never yields. This is
  tokio's always-ready socket problem, which coop's budget of 128 solved
  (`tokio/src/task/coop/mod.rs:104-117`, checked).
  - **Fix:** after B consecutive scheduling points that didn't wait, the
    next one **where the task holds no instance** yields to the back of the
    queue, after a world poll. It never goes into the LIFO slot.
  - B is a parameter of the scheduler constructor, as Effect makes
    `MaxOpsBeforeYield` (2048) a reference.
  - It is a count, so `single` replays it with no journal entry.
  - Count only outermost dependency calls, so `over any` wrappers don't
    double-count.
- **Spec bug:** `single` polls I/O and timers only "when no task can run"
  (compiler.md:4490-4495, checked). Under steady load, two tasks waking each
  other keep the queue non-empty forever, and no completion is ever taken in.
  Go checks the global queue every 61 schedticks for exactly this
  (`go/src/runtime/proc.go:3459-3469`, checked), and tokio has
  `event_interval`. **Fix:** take in replies every K steps as well as on
  idle, at counted poll points that are already journaled.
- **`ren_run`'s `budget` counts steps, never time.** A host that wants time
  slices passes small budgets and reads its own clock. A step can't be
  interrupted, so a hosted CPU limit kills a long pure call rather than
  pausing it. wasmtime's epochs or fuel can pause the whole instance from
  outside without changing Ren's meaning. Ship neither for 1.0.
- **Work stealing** (R6):
  - a LIFO slot for instance hand-off, capped at 3 polls per tick and sharing
    the waker's budget, but **stealable** with Go's short back-off;
  - steal half from a random victim;
  - at most half the workers searching at once;
  - a fixed 61-tick injection-queue check, which is deterministic, rather
    than tokio's time-tuned interval.
- **`sim` draws B and K from the tape,** so no program comes to depend on the
  constants (FoundationDB yields after a random 1 to 150 calls,
  `sim2.cpp:1311-1321`).
- **No priorities in 1.0.** Strict priorities invert against decision 10's
  instances, and FoundationDB ended up with about 75 levels. flottning's
  compaction-versus-requests need is TigerBeetle-style pacing in plain Ren.

### 2.9 What a never-yielding pure call still breaks (MISSING)

Decision 9's "on many cores the others carry on" is true for tasks. It is not
true for replies or for memory.

- **Replies trapped on a hog's ring.** With one ring per worker under
  `DEFER_TASKRUN`, completions on a stuck worker's ring wait until that
  worker returns, even if other workers are idle (R2 §4, R3, R6). Go and
  tokio avoid this with a shared poller; Seastar and glommio accept it.
- **`Mem.snapshot` reclamation stalls everywhere.** QSBR frees a version once
  every worker passes a scheduling point (foundations.md:624-626). BEAM
  admits only "threads that behave well" to thread progress
  (`otp/erts/emulator/beam/erl_thr_progress.c:31-62`).
- **Stalls are invisible.** Add a host watchdog over a per-worker progress
  counter, like Seastar's 25 ms detector. It reports the task path, or the
  call site of an unmarked slow foreign call, which is Ren's version of
  Loom's pinning. It changes nothing, so replay is unaffected, and the core
  still reads no clock.

Decisions 5 and 6 below choose what to do about the first two.

### 2.10 Smaller items that must land somewhere

- **Detect io_uring once at `ren_start` and fall back whole** on `ENOSYS`,
  `EPERM` or a missing op. Log why, using TigerBeetle's messages as the model
  (`tigerbeetle/src/io/linux.zig:46-57`). Give an environment override, and
  record the chosen driver in the journal header. Set one kernel floor, 6.1
  for `DEFER_TASKRUN`, instead of branching per feature.
- **`Fs` must expose durability:** `sync` and `sync_dir`. On macOS `sync` is
  `F_FULLFSYNC` (`tigerbeetle/src/io/darwin.zig:1115-1122`), or flottning's
  WAL isn't durable there. The sim driver needs this to model torn and lost
  writes.
- **`pages` may fail and is never undone.** wasm memory only grows, and
  workerd caps an isolate at 128 MB, so a failure must be a clean
  out-of-memory, not a trap. `ren_run` reports when memory grew, because
  growth detaches JS views (verified locally by R5).
- **Inbound events are replies to a standing call** (`Http.Call.Next`), and
  the response is a call. This keeps hosted inbound traffic inside the five
  functions and the journal.
- **`main` asks rather than tells.** The host may clamp `workers`, so
  `work_stealing(cores: 8)` under a one-worker host runs as `single`.
  `per_core` fails at start rather than degrading.
- **A foreign call outside the journal.** A `trust` foreign call that is
  neither `blocking` nor a driver call is unrecordable. Mark the journal
  header "contains unrecorded foreign effects".
- **Refuse for 1.0:**
  - SQPOLL as a default;
  - zero-copy send;
  - IOPOLL rings;
  - Asyncify, except as a fallback flag;
  - priorities;
  - signal preemption;
  - Temporal-style `patched()`;
  - recording every lock-free or snapshot access to promise exact parallel
    replay. rr refused that cost. Under `work_stealing`, replay world answers
    and locked-handler order exactly, and report the rest as a schedule
    divergence.

---

## 3. Revised ABI sketch

Nine functions instead of five. Each addition answers one item above. Time is
gone from the core.

```c
/* One record format: the journal's, the hosted wire's, and this struct's. */
typedef struct {
  uint64_t id;        /* slot:32 | generation:32; never reused while live      */
  uint16_t worker;    /* home worker: cancels and returns are pulled here      */
  uint16_t kind;      /* REN_CALL | REN_CANCEL | REN_RETURN                     */
  uint32_t lane;      /* inbound event the task tree descends from (0 = none)  */
  uint32_t task;      /* task path id, for traces and the stall report         */
  uint32_t op;        /* dependency << 16 | operation                          */
  uint32_t len;       /* encoded D.Call body; buffers are (ptr,len) inside it  */
  const void *body;
} ren_call;

typedef struct {
  uint64_t id;
  uint32_t state;     /* REN_DONE | REN_CANCELLED (had no effect)              */
  uint32_t len;       /* encoded D.Reply body (may carry a lease)              */
  const void *body;
} ren_reply;

typedef struct {
  /* Leaf callbacks: must never call ren_*. */
  void  (*wake)(void *host, int worker);   /* any thread; sticky, idempotent; only for a parked worker */
  bool  (*answer_now)(void *host, int worker, const ren_call *, ren_reply *out); /* worker thread; never blocks */
  void *(*pages)(void *host, size_t n);    /* may return NULL; never undone */
  void  (*journal)(void *host, int worker, const void *entry, size_t len); /* NULL = not recording */
} ren_host;

typedef struct {
  int workers;            /* what the host allows; main's scheduler may be clamped to it */
  const char *build_id;   /* journal header */
  uint32_t journal_policy;/* inputs: inline | side-store | hash | none; outputs: hash | none */
} ren_config;

ren_core *ren_start(const ren_config *, int (*main)(void), const ren_host *, void *host); /* no globals */
void      ren_thread_init(ren_core *, int worker, void *stack_lo, size_t stack_size);   /* binds worker to this thread */
int       ren_run(ren_core *, int worker, uint32_t steps);  /* RUNNING | IDLE | DONE, | REN_GREW */
bool      ren_poll_call(ren_core *, int worker, ren_call *out); /* drain until false */
int       ren_reply(ren_core *, const ren_reply *);         /* any thread; ACCEPTED | RELEASE; wakes the home worker */
void      ren_stop(ren_core *);   /* cancel everything; keep running and draining until DONE */
void      ren_kill(ren_core *);   /* drop with no finally (sim crash); the driver discards un-synced state */
void      ren_free(ren_core *);
uint64_t  ren_progress(ren_core *, int worker);  /* any thread, read-only; for the host's stall watchdog */
```

What went away:

- `now_ns`, because timers are `Clock.Call.SleepUntil`;
- `ren_poll_deadline`, because the driver holds every sleep.

What it implies:

- **One driver loop shape**, the same for io_uring, epoll, kqueue, sim,
  replay and JS:
  1. call `ren_run(worker, steps)`;
  2. pull calls into the kernel or the JS runtime;
  3. sleep until a completion, the driver's earliest timer, or a wake;
  4. pass each completion to `ren_reply`, and act on `RELEASE`.
- **`sim` is a driver plus `Sched.Call.Pick`.** When `ren_run` returns
  `IDLE` and the sim driver has no runnable completion, it advances virtual
  time to its earliest sleep. If there is none, it reports a deadlock naming
  the parked tasks, as s2n-quic's stall guard does
  (`s2n-quic-platform/src/io/testing.rs:170-195`).

A shortcut for the task-path field: `task` can be an index into a table the
core exposes, which is the "way to read the current task's path" R6 asks for.

---

## 4. Open decisions for the owner

Eight decisions, each with a recommendation.

1. **Do timers become world calls, dropping `now_ns` and
   `ren_poll_deadline`?** *Recommend yes.* It makes "time is a reply" true
   with no exception, removes the busy-loop bug class from the core, and
   makes sim, replay and hosted timers fall out. *Tradeoff:* a timeout costs
   a call and a cancel, and the core can no longer batch timers in its own
   heap. E2 measures this. If it's too slow, add a deadline field on calls,
   not a clock in the core.

2. **Does cancellation wait and deliver (Eio), with release only for replies
   nobody waits for?** *Recommend yes.* It restores async.md's "never loses a
   result" and runtime-io.md's "cancelling waits", and a completed WAL write
   is always reported. *Tradeoff:* cancel latency is bounded by the kernel. A
   regular-file read or an fsync can't be cancelled once it reaches the
   device, so the cleanup deadline must cover it (decision 3).

3. **Does a call still pending at the 5 s cleanup deadline get abandoned and
   released?** This covers a blocking-pool call, or a disk read the kernel
   won't cancel. *Recommend abandon:* journal a `Release`, count a metric, and
   poison the handle if it is a stream. *Tradeoff:* the call's effect may
   still happen after the program has moved on. The alternative is hanging
   shutdown on a stuck NFS read. Signal interruption (Zig's `tgkill(SIGIO)`,
   `Io/Threaded.zig:100-112`) can be an opt-in per call later.

4. **Is a worker id bound to one OS thread for life?** *Recommend yes*, via
   `ren_thread_init` or the first `ren_run`. *Tradeoff:* a host can't move a
   worker between threads. No host studied wants to, and io_uring's
   `SINGLE_ISSUER` forbids it. Reword the model as "the core never creates
   threads; drivers and the default host may, within stated limits".

5. **Replies stuck behind a hog's ring: accept for 1.0, or engineer it
   away?** *Recommend accepting and reporting it,* with the stall watchdog,
   chunked `Async.map`, and the counted budget, and measuring it in E5.
   - Keep the ABI neutral: replies go through `ren_reply`, so a driver may
     later reap a stuck peer's ring under a lock, or drop `DEFER_TASKRUN`,
     without changing the core.
   - *Tradeoff:* tail latency for tasks whose calls went out on a busy
     worker, which Go and tokio avoid with a shared poller at the cost of
     contention.

6. **`Mem.snapshot` reclamation: keep QSBR, or switch to epochs announced on
   read?** *Recommend epochs*, crossbeam-style `pin` on entering a read block,
   with an idle worker counting as quiescent. *Tradeoff:* a store per read
   block, against unbounded garbage behind any long pure call. R6 cites an
   earlier Ren measurement placing QSBR near crossbeam-epoch anyway. I
   haven't re-checked that number.

7. **Journal: per-direction bytes, and whole-program versus per-unit?**
   *Recommend:*
   - inputs stored and outputs hashed by default;
   - whole-program journals for CLIs, tests and bug reports;
   - per-request journals via `recorder over` for servers;
   - flushing at each `idle` return and at panic, accepting that a SIGKILL
     loses the buffered tail.

   *Tradeoff:* a server's `--record` won't produce one replayable file, and
   flushing per entry would cost too much for flottning.

8. **Add lanes and the fixed record layout now, though hosted support comes
   later?** *Recommend yes.* Both are cheap fields today and a breaking
   change later, and the layout being the journal format pays off
   immediately in E1 and E7. *Tradeoff:* one more 32-bit field per call, and
   committing early to an encoding that decision 19's formats must then
   serve.

Deliberately not on this list:

- **Fault points keyed by call site (BUGGIFY).** These belong to the sim
  design the owner is doing later. The building block, a stable call-site
  identity, already exists in task paths.
- **Shares or latency classes.** Not for 1.0.

---

## 5. The experiments, revised

The plan in `experiments/runtime-p3/` holds up. Most changes follow from the
ABI revisions. One experiment is added, and none are dropped.

| # | Change | Why |
|---|---|---|
| **E1** prototype core | **Change.** Build against the revised ABI: no `now_ns`, `SleepUntil` as a call, the core writing the journal with `Deliver(step)`, `ren_reply` returning `ACCEPTED`/`RELEASE`, `ren_stop` and `ren_kill`. Add: (a) the drain-contract asserts; (b) a double-run digest check under the replay driver; (c) a forced reply/cancel race that replays to the same outcome; (d) two cores in one process with no shared globals. | These are the decisions above; E1 is where they're proven to compose. |
| **E2** world-call cost | **Change.** Keep the comparison against raw liburing and the inline `Clock.now` against the vDSO. Add: (a) `Async.timeout` as `SleepUntil` plus a cancel, against an in-core timer heap; (b) the cost of the counted budget decrement per scheduling point. | Decision 1's tradeoff, and R6's budget, which BEAM's `dec; jl` suggests is near zero. |
| **E3** cancel storm | **Change.** Test the waiting-cancel semantics. A write that completes after its cancel must report success. Multishot leftovers are released. `Close` cancels by fd before closing. Abandonment at the cleanup deadline releases fds. `ren_stop` tears down in the right order. Check both orders of the two CQEs. Keep ASan and the fd-leak check. | Rule 4's rewrite, and the `Rcfd` close rule. |
| **E4** provided buffers at 100k idle connections | **Keep, sharpen.** Report Ren's pool, the kernel's per-request state and the socket buffers separately. Include a lease returned from another worker, `ENOBUFS` recovery, and the epoll driver allocating on `EPOLLIN`. | R2 §3; per-request kernel state is from memory and needs measuring. |
| **E5** cross-worker wake | **Extend.** Add: (a) a 100 ms pure call on one worker, measuring reply latency for tasks whose calls are on its ring, under `DEFER_TASKRUN`, `COOP_TASKRUN` and peer reaping; (b) `SEND_MSG_RING` (6.13) from a pool thread with no ring; (c) posting the reply itself through `MSG_RING`; (d) a lost-wakeup stress test of the SeqCst handshake. | Decision 5, and rule 6's real cost. |
| **E6** io_uring vs epoll | **Extend.** Add the detection path: run under Docker 25's default seccomp profile and with `io_uring_disabled=2`, and check that the fallback is chosen, logged and recorded in the header. Also cap io-wq for the WAL's fsyncs. | R2 §7: the fallback is the main path for many deployments. |
| **E7** journal cost | **Change the variants:** inputs stored and outputs hashed (the proposed default); full bytes; side-store by content hash; off. Also measure flushing per poll against flushing per idle return. | R4: "full versus metadata only" is the wrong split. |
| **E8** WASM and JS | **Change the focus.** Drive the core from JS **without** JSPI first, with plain synchronous `ren_run`, a `MessageChannel` wake and memory growth detaching views. Then add JSPI for one `blocking` foreign call only. In workerd, test a standing `Next` call with lanes, and check whether plain wasm Workers get JSPI (unverified). | R5: JSPI isn't how Ren suspends, so testing it as the main path would test the wrong thing. |
| **E9** fairness and reclamation *(new)* | (a) Show the `single` starvation bug: two tasks ping-ponging under load while a completion waits, then fix it with a K-step poll. (b) A `memtable.put` loop over an uncontended instance, with and without budget B. (c) Garbage growth from `Mem.snapshot` behind a 1 s pure call, under QSBR and under epoch announce. | R6 raised three fairness questions with no experiment. (c) decides decision 6. |

None should be dropped. E8 shrinks in importance for 1.0 (flottning is
native), but it is the only check that the ABI really can be hosted, and that
was the reason for designing the ABI now.

---

## Citations checked

**Confirmed against source** for this synthesis:

- Eio delivers a non-negative result after a cancel (`eio/lib_eio_linux/sched.ml:246-255`).
- An io_uring cancel matches only its own ring (`linux-iouring/cancel.c:43`, `:237`).
- `SINGLE_ISSUER` fails other tasks with `-EEXIST` (`liburing/man/io_uring_setup.2:293-309`).
- Effect drops a late resume (`effect/packages/effect/src/internal/effect.ts:1200-1219`).
- Restate's notification-order rule (`sdk-shared-core/docs/service-invocation-protocol.md:155`).
- tokio's coop budget of 128 (`tokio/tokio/src/task/coop/mod.rs:104-117`).
- Go's 61-tick global-queue check (`go/src/runtime/proc.go:3459-3469`).
- workerd's cross-request I/O error (`io-context.c++:1977-1983`).
- The Component Model's `EXIT`/`YIELD`/`WAIT` codes and guest task affinity
  (`Concurrency.md`). The content is confirmed, but R5's line range for the
  callback codes, 1145-1177, is off: the codes are around 1325-1343, and
  affinity is at 1486.
- In Ren's own docs:
  - `single` polls only when idle (`compiler.md:4490-4495`);
  - the 1 GiB stack thread (`compiler.md:1566-1571`);
  - "never loses a result" and "it waits" (`async.md:316-331`);
  - "cancelling waits for the kernel" (`runtime-io.md:65-80`);
  - the preemption reversal (`foundations.md:1369`).

**Not verified by me, and marked so in the reports:**

- glommio's `Relaxed` lost-wakeup window (R2's reading, not a confirmed bug);
- the kernel's bookkeeping per pending request;
- the zero-copy size threshold;
- Seastar's `foreign_ptr`;
- libuv's and tokio's pool sizes;
- Go's io_uring issue;
- cgo overhead;
- JEP 444's wording on time sharing;
- Go's 1 ms mutex starvation threshold;
- Asyncify's overhead numbers;
- whether plain wasm Workers get JSPI;
- the Restate TypeScript SDK running the shared core as WASM;
- R6's earlier Ren measurement of QSBR against crossbeam-epoch (decision 6
  leans on it lightly).

Whether dropping `DEFER_TASKRUN` (for `COOP_TASKRUN`) actually frees a
hog's completions is untested; E5(a) settles it.

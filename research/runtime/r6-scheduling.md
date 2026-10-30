# R6: Scheduler internals: fairness, preemption, budgets

Track R6 of the runtime research. The question: what happens when a task
never yields, and what Ren's 1.0 schedulers (deterministic, work_stealing,
per_core) should do about fairness, preemption and budgets, given that every
run must replay from its journal and that the core is driven through
`ren_run(core, worker, now_ns, budget)`.

Sources are the clones in `/tmp/ren-refs` (tokio, go, otp, rayon, seastar,
glommio, foundationdb, effect v4, rr, tigerbeetle) plus the JDK's
`ForkJoinPool.java` and `VirtualThread.java`, fetched from openjdk/jdk master
into `/tmp/ren-refs/jdk-fj/`. Line numbers are against those checkouts. Where
a claim comes from memory, it says so.

## Where Ren stands today

- **No preemption.** "A task runs until it waits. A long computation holds its
  thread; on many cores the others carry on" (async.md:631-632;
  foundations.md:398). The first async.md had preemption at loop back-edges,
  "yielding every 2,048 operations" like Effect, for about 1 to 2% in tight
  loops (`git show 426295c:async.md`, lines 394-401). foundations.md reversed
  it: "Preemption at loop back-edges (async.md) | None" (foundations.md:1369).
- **Only code that can wait has a frame.** "Only a function whose `uses`
  reaches a dependency can suspend, so only those get frames that outlive the
  native stack" (foundations.md:690-691). Pure code runs on the native stack
  and can't be switched away from without a stackful mechanism Ren doesn't
  have.
- **`Mem.snapshot` reclaims by QSBR.** "The runtime frees an old version once
  every worker has passed a scheduling point" (foundations.md:624-626).
- **`single`'s order** is one FIFO run queue, and "when no task can run, the
  scheduler waits for the earliest timer or I/O" (compiler.md:4476-4495). It
  polls the world only when idle.
- **`sim`** switches at every scheduling point, choosing from the tape
  (compiler.md:4502-4510).

The rest of this report is about the gaps those five facts leave.

## What the prior art does

### tokio (multi-thread scheduler)

- **Coop budget.** Each task gets a budget of 128 per poll
  (`tokio/src/task/coop/mod.rs:104-117`). Each operation on a tokio resource
  decrements it, and once it is spent the resource reports `Pending` even when
  it is ready (`poll_proceed`, `coop/mod.rs:343-364`). The problem it solves:
  a loop over an always-ready socket or channel never yields (module docs,
  `coop/mod.rs:8-31`). The blog reports tail latencies falling by "almost 3x"
  (https://tokio.rs/blog/2020-04-preemption). `consume_budget()` lets
  CPU-heavy user code take part (`task/coop/consume_budget.rs:25-39`), and
  `unconstrained` opts out. The budget is a count, not time, so it is
  deterministic.
- **The blog's reasons for not preempting.** Rust's async gives executors no
  way to inject yield points. Tokio also chose not to auto-detect blocked
  workers and add threads, because heuristic thread pools "stutter" (same
  post).
- **LIFO slot.** A task woken by the running task goes into a one-element
  slot that runs next, which helps message-passing locality
  (`scheduler/multi_thread/worker.rs:113-127`). It is capped at 3 polls per
  tick to stop two tasks ping-ponging forever (`worker.rs:266-270`,
  `worker.rs:752-762`). The capped polls share the task's coop budget
  (`worker.rs:735-746`). A yield never goes to the LIFO slot
  (`schedule_local`, `worker.rs:1379-1405`).
- **The LIFO slot can't be stolen, and that keeps biting.** `block_in_place`
  has to move the slot's task back into the stealable queue before handing
  its core away (`worker.rs:480-486`, CHANGELOG #6596). Stealing from the slot
  was added in 1.51.0 (#7431) and reverted in 1.51.2/1.52.2 "due to its
  performance impact" (`tokio/CHANGELOG.md:346-349`, 485-492, 525). The
  latency-versus-throughput trade on this one slot is still unsettled after
  six years.
- **Global queue fairness.** The worker checks the injection queue first
  every `global_queue_interval` ticks. That interval self-tunes to roughly
  200 µs of work divided by an EWMA of poll time, clamped to 2..127
  (`worker.rs:1084-1150`; `stats.rs:31-37`, 56-68). The current-thread
  runtime polls I/O every 61 ticks, "copied from golang"
  (`runtime/builder.rs:280-285`). The multi-thread runtime runs maintenance,
  a zero-timeout park that drives I/O and timers, every `event_interval`
  ticks (`worker.rs:803-820`).
- **Stealing.** A thief takes half the victim's queue (`queue.rs:487-488`) and
  starts at a random victim (`worker.rs:1161-1190`). No more than half the
  workers may search at once, to avoid a thundering herd (`idle.rs:108-119`).
  The local queue holds 256 tasks (`queue.rs:63`).
- **`yield_now` is deferred until after the driver has been polled**, so a
  yielding loop can't starve I/O (`task/yield_now.rs:49-55`).
- **`block_in_place`** hands the worker's core to another thread so the
  current thread can block (`worker.rs:365` ff.).

### Go

- **P/M/G.** `runnext` is Go's LIFO slot. It "shares the same time slice as
  the current goroutine", and only sysmon's preemption stops a ping-pong pair
  starving everyone. Without sysmon, runnext is disabled
  (`runtime/proc.go:7546-7565`). Thieves may take runnext, but back off about
  3 µs first, so a P that readied a G and is about to block can run it itself
  (`proc.go:7740-7760`).
- **Global queue every 61 schedticks**, "otherwise two goroutines can
  completely occupy the local runqueue by constantly respawning each other"
  (`proc.go:3459-3469`).
- **sysmon** is a thread the runtime creates. It sleeps 20 µs, backing off to
  10 ms (`proc.go:6549-6570`). `retake` preempts a G that has run on one
  schedtick for `forcePreemptNS` = 10 ms. The time slice is per P, so a
  runnext chain counts as one slice. retake also takes the P back from a G
  stuck in a syscall (`proc.go:6689-6760`).
- **Preemption** works by poisoning the stack guard, which the next function
  prologue catches, plus an async signal, SIGURG, since Go 1.14
  (`proc.go:6929-6965`; `preempt.go:7-50`; `signal_unix.go:74`). Async
  preemption needs "async safe points": a conservative scan of stack and
  registers, enough stack to inject a call, and no runtime locks held
  (`preempt.go:384-398`).
- **Why signals and not loop checks.** The design doc reports that loop
  preemption caused "unacceptable slow-downs in tight loops", and gives 7.8%
  geomean for the fault-based variant against Go 1.9
  (https://github.com/golang/proposal/blob/master/design/24543-non-cooperative-preemption.md).
- **Randomization for testing.** `randomizeScheduler = raceenabled`
  (`proc.go:7542`): under `-race`, runnext is skipped at random to shake out
  order bugs.
- From memory, unverified (`sync/` isn't in the clone): `sync.Mutex` switches
  to FIFO handoff ("starvation mode") once a waiter has waited 1 ms. That is
  the model behind decision 10's "fair, not FIFO".

### BEAM

- **Reductions.** A process is switched out after `CONTEXT_REDS` = 4000
  reductions (`erts/emulator/beam/erl_vm.h:47`). The JIT emits `dec FCALLS;
  jl` on every call and return (`beam/jit/x86/instr_call.cpp:68-71`) and at
  function entry (`emit_i_test_yield`, `instr_common.cpp:3233-3253`). This is
  compiler-inserted, counted preemption, and it is cheap because Erlang loops
  are recursive calls, so the call check covers every loop.
- **Priorities.** There are four: max, high, normal and low. Low shares the
  normal queue but runs only every 8th time (`RESCHEDULE_LOW`,
  `erl_process.h:373`; `erl_process.c:3957-3972`).
- **Native code must cooperate.** A NIF or driver callback should return
  within about 1 ms and report its share with `enif_consume_timeslice`
  (`erts/doc/references/erl_nif.md:400-406`, 1081-1105;
  `erl_driver.md:1838-1846`). Otherwise it is marked dirty and runs on dirty
  CPU schedulers (by default as many as normal schedulers) or dirty I/O
  schedulers (10 by default) (`erts/doc/references/erl_cmd.md:940-994`).
- **Thread progress, BEAM's QSBR, works only because of preemption.** "Only
  threads that behave well can be allowed to be managed. A managed thread
  should update its thread progress frequently." Schedulers are managed;
  async threads running user driver code are not, "since they cannot
  guarantee a frequent update". Sleeping threads count as having progressed
  (`beam/erl_thr_progress.c:31-62`).

### Loom (virtual threads) and ForkJoinPool

- Virtual threads run on a `ForkJoinPool` in async (FIFO) mode. Parallelism
  is the number of cores, `maxPoolSize` is max(parallelism, 256), and
  `minRunnable` is parallelism/2 (`jdk-fj/VirtualThread.java:1330-1355`).
- There is no time slicing. JEP 444 says the scheduler "does not currently
  implement time sharing for virtual threads" (from memory of the JEP text).
  `disableSuspendAndPreempt` refers to JVMTI suspension and pinning
  (`VirtualThread.java:1234-1240`).
- Blocking is handled by compensation: `managedBlock` adds a carrier thread
  while one blocks (`ForkJoinPool.java:4306-4313`). Owner pops are LIFO or
  FIFO by mode; steals are FIFO from randomized victims
  (`ForkJoinPool.java:220-221`, 285-290).

### Rayon

- Workers are LIFO by default, or FIFO with `breadth_first`
  (`rayon-core/src/registry.rs:246-253`).
- A thread waiting on a `join` latch runs other jobs, local or stolen, on its
  own stack until the latch is set (`registry.rs:780-815`). So the joiner can
  be held up by an unrelated long job it stole. That is fine for pure
  fork-join and wrong for a thread that also owes I/O.

### Seastar

- **`need_preempt()`** compares two words: head != tail of a
  `preemption_monitor` laid out like the Linux aio completion ring, "so we
  can have the kernel preempt a task by queuing a completion event"
  (`include/seastar/core/preempt.hh:29-35`, 49-72). A timer, the task quota,
  makes the kernel write that completion. Tasks and loops poll the flag
  cooperatively.
- **Defaults.** `task-quota-ms` is 0.5. `max-task-backlog` is 1000; above it,
  I/O is ignored. `blocked-reactor-notify-ms` is 25
  (`src/core/reactor.cc:4062-4067`).
- **The task loop** checks for preemption after each task, so at least one
  runs (`reactor.cc:2773-2808`).
- **Scheduling groups** are scheduled by vruntime weighted by shares,
  CFS-style (`reactor.cc:3262-3310`, `set_shares` 1080-1083). A run over
  2× the quota is counted as a quota violation (`reactor.cc:1086-1099`).
- **The stall detector**, a POSIX timer or perf event, prints a backtrace
  when the reactor makes no progress for 25 ms (`reactor.cc:1222-1350`). It
  only reports; it changes nothing.
- **Debug builds** run a random but bounded number of tasks between I/O
  checks (`preempt.hh:81-96`) and can shuffle the task queue
  (`SEASTAR_SHUFFLE_TASK_QUEUE`, `reactor.cc:2814`).

### Glommio

- **`need_preempt`** is the same trick on io_uring: the head and tail of the
  latency ring's completion queue (`glommio/src/reactor.rs:208-210`).
- **Latency classes.** `Latency::Matters(d)` gives a task queue its own ring
  and shortens the preempt timer to the minimum `d` over active queues;
  `NotImportant` uses the default of 100 ms (`lib.rs:480-498`;
  `executor/mod.rs:73`, 404-414). The preempt timer is coalesced with user
  timers and re-armed on leaving the wait (`sys/uring.rs:1765-1800`).
- **Shares** between task queues work as in Seastar.

### FoundationDB (Flow)

- **Real network.** `check_yield` returns true when a higher-priority task is
  ready, when the stack is deep, or when TSC time since the slice began
  passes `TSC_YIELD_TIME` = 1,000,000 cycles (`flow/Net2.cpp:1856-1890`;
  `flow/Knobs.cpp:233`).
- **Simulation.** `check_yield` returns true after a random 1..150 calls
  drawn from the deterministic RNG, or by buggify at 1%
  (`fdbrpc/sim2.cpp:1311-1321`). So the yield decision is time-based in
  production and seeded in simulation. Real runs are not replayed.
- **Priorities.** About 75 named levels (`flow/include/flow/TaskPriority.h`,
  from line 26). They show where per-subsystem priorities end up.

### Effect v4

- Every fiber yields after `MaxOpsBeforeYield` = 2048 operations
  (`packages/effect/src/Scheduler.ts:189-200`, 285-296; the run loop at
  `internal/effect.ts:679-690`).
- The budget is a Context reference, a dependency, and can be tuned or
  disabled (`PreventSchedulerYield`).
- It is a deterministic count.

### rr and TigerBeetle

- **rr** replays preemption deterministically by counting "ticks", retired
  conditional branches read from hardware counters. The default slice is
  2,500,000 ticks, about 50 ms (`rr/src/Scheduler.h:49-84`). It shows that
  preemption at arbitrary instructions can be replayed only if it is counted
  in a deterministic unit.
- **TigerBeetle** has no tasks to preempt. It bounds work by construction:
  compaction is split into "beats" of a "bar", a fixed slice of work per
  commit (`docs/internals/lsm.md:44-62`; `lsm_compaction_ops = 4`,
  `src/config.zig:262`). Pacing is deterministic and lives in the
  application.

## Three ways to stop a hog, and which survive replay

| Mechanism | Who | Where it can switch | Deterministic? |
|---|---|---|---|
| Signal or async preemption | Go | almost any instruction | no; replay needs rr-style counters |
| Counted checks the compiler inserts | BEAM (calls), Effect (ops), first async.md (back-edges) | at the checks | yes, if the count is the unit |
| Cooperative budget at library yield points | tokio (128), FDB sim | at resource operations | yes, if counted in operations |
| Time-flag checked cooperatively | Seastar, Glommio, FDB real | at checks | no; the moment depends on the clock |
| Report only (stall detector) | Seastar, Go's sysmon traces | nowhere | doesn't affect the run |

**Count, not time.** For replay, the unit has to be a count of something the
program does. Every system that is deterministic counts: BEAM reductions,
Effect ops, tokio budget units, rr branches, FDB sim's seeded counter. The
time-based ones, Go, Seastar, Glommio and FDB real, would need every
preemption point journaled. FDB doesn't try; real runs aren't replayable.
Ren's journal can record polls but not "this task was switched at instruction
X of a pure loop", so the count must sit at a point the journal can already
name.

**Ren can't preempt pure code anyway.** It has no frame to save, and a
scheduling point inside pure code would break the `Mem.snapshot` rule that
"no code reached from a call with an empty row runs a scheduling point"
(foundations.md:630-632). Go's async safe points need stack maps and
register scanning for every instruction (`preempt.go:384-398`), the opposite
of "few decisive rules". Signal preemption is refused on three counts: no
frames, it breaks QSBR, and it can't be replayed.

**So Ren's line is the one its rows already draw.** Code that can wait can be
made to wait. Code that can't wait runs to the end. This rule falls out of
decision 12; it adds no new mechanism.

## The budget Ren needs anyway: always-ready scheduling points

Tokio's problem exists in Ren even without preemption, and in a worse form:

- **Handler operations rarely wait.** An operation on an uncontended instance
  returns without waiting (decision 10). So a loop of `memtable.put` calls,
  or a `for` over a cursor whose operations hit a cache, never waits. That is
  flottning's hot path.
- **Inline answers wait for nothing.** A driver answering inline through
  `answer_now`, for time, random or replay, makes world calls that also never
  wait.
- **The task runs until its loop ends.** In such a loop, nothing ever
  returns control to the scheduler.

Tokio's answer, a budget decremented at resource operations, maps onto Ren
exactly: decrement at scheduling points. It is deterministic, so `single`
replays it with no journal entry, since it is a pure function of the program's
own steps. `sim` already switches at every scheduling point, so the budget
only narrows what the real schedulers do.

Two details from tokio matter:

- **A forced yield goes to the back of the queue and is deferred past a world
  poll.** It must not go to the LIFO slot (`worker.rs:1386-1390`;
  `yield_now.rs:49-55`). Otherwise the yielding task runs straight again and
  I/O still starves.
- **Count at leaves, not wrappers.** Tokio's comment on placing yield points
  (`coop/mod.rs:82-90`) is about not double-counting nested futures. In Ren
  the compiler places them, so only the outermost dependency call counts. An
  `over any` wrapper's `call.forward()` is the same call, not a second one.

One interaction with decision 10 needs a ruling: should a forced yield happen
while the task holds an instance? BEAM preempts anywhere, but it has no
user-level locks. Yielding while holding an instance makes everyone queued on
it wait out the yield too: a convoy. The simple rule is that **the budget is
paid only at a scheduling point where the task holds no instance.**

- **Inside an operation, the task keeps running.** It is already serializing
  that instance's callers, and decision 10 accepted that cost ("one slow call
  serializes that handler's operations").
- **`release` counts as holding none.** `release` lets the instance go for
  its call, so a scheduling point inside it holds no instance.

## The world must be polled on a count too

`single`'s spec polls timers and I/O only "when no task can run"
(compiler.md:4490-4495). Under constant load, which a server always has, two
tasks waking each other through `Async.until` or a channel keep the queue
non-empty forever. No completion is ever taken in, and no timer fires. Go
fixed exactly this case with the 61-tick check (`proc.go:3459-3469`), and
tokio with `event_interval` (`builder.rs:280-285`; `worker.rs:803-820`).

The fix: take in replies, and check the global or injection queue, every *N*
steps as well as when idle. With Ren's ABI this falls out:

- **`ren_run` returns `running`** when its `budget` is spent.
- **The host polls between calls.** It runs the driver,
  `ren_poll_call`/`ren_reply`, before calling `ren_run` again.
- **A long `ren_run` takes replies in itself** every *K* steps, *K* counted
  and therefore deterministic, at a counted poll point the journal already
  records (decision 11: "Completions arrive at counted poll points, and the
  journal records each poll").

## What a never-yielding pure computation breaks, besides latency

This is the part the current model is missing.

1. **The worker's own ring.** With one io_uring per worker, the completions
   for tasks whose calls went out on worker W's ring are reaped by W's
   thread. If W is in a 2-second pure computation, those tasks wait 2 s,
   even when other workers are idle and could steal them. Their work is
   stealable, but their *replies* aren't.
   - Go avoids this: netpoll is global and any P polls it in `findRunnable`.
   - So does tokio: whichever worker parks drives the shared I/O driver.
   - Seastar and Glommio accept it, because they are shared-nothing by
     design.
2. **`Mem.snapshot` reclamation stalls everywhere.** QSBR frees a version
   only after every worker passes a scheduling point. A worker in a long pure
   call passes none, so every core's garbage piles up behind it. BEAM states
   the precondition outright: only "threads that behave well" (that is,
   preemptible ones) take part in thread progress
   (`erl_thr_progress.c:31-41`). Ren uses QSBR without preemption, which
   breaks that precondition.
3. **Hosted runtimes.** A Worker or JSPI host gives a CPU-time limit per
   event. `ren_run(budget)` can't return in the middle of a pure call, so a
   long one is killed by the host, not paused.

Decision 9's "on many cores the others carry on" is true for *tasks*. Items 1
and 2 say it isn't true for *replies* and *memory*.

## Work-stealing details that matter for tail latency

- **The LIFO slot (`runnext`) is right for decision 10's handoffs.** When an
  operation ends and hands the instance to a waiter, the waiter runs next on
  the same core with warm caches. Cap it as tokio does (3 per tick), make it
  share the waker's budget, and never put a yield in it.
- **Make every waiting task stealable, including the slot.** Tokio keeps the
  slot unstealable and has paid for it in `block_in_place`, the 1.51 attempt
  and the revert. Go makes runnext stealable with a short back-off
  (`proc.go:7740-7760`). Ren tasks are heap frames, so there is no reason to
  pin the slot. The 3 µs back-off is the detail to copy.
- **Steal half from a random victim, cap searchers at half the workers, and
  check the injection queue every *N* ticks** (tokio `queue.rs:487-488`,
  `idle.rs:108-119`; Go 61). All three are standard and cheap.
- **Remote replies need a home.** `ren_reply` is "any thread". The woken task
  should go to the injection queue, or to the queue of the worker that
  submitted the call, as tokio's `schedule_task` does for remote wakes. It
  should not go to the replying thread's queue.
- **A joiner shouldn't run unrelated work on its stack.** Rayon's waiting
  joiner runs stolen jobs on its stack (`registry.rs:780-815`). For Ren's
  `Async.map` over a pure block, that is fine among chunks of the same map.
  It is not fine for a worker that is also the only reaper of its ring
  (item 1 above). Split pure maps into bounded chunks and take replies in
  between chunks. A long pure `map` then becomes as interruptible as a loop
  of scheduling points, for free.

## Priorities and latency classes

- **The options.** BEAM has four classes with low run 1 in 8. Seastar and
  Glommio have shares, proportional rather than strict, and Glommio adds a
  latency class that shortens the preemption timer. FDB has about 75 strict
  priorities. Tokio and Go have none.
- **Shares compose; strict priorities don't.** Shares degrade gracefully.
  Strict priorities bring priority inversion, and with decision 10's
  instances a low-priority task holding an instance blocks a high one: the
  classic inversion, which needs priority inheritance to fix. FDB's list
  shows where per-subsystem priorities end up.
- **flottning's real need is foreground requests versus background
  compaction and flush.** TigerBeetle meets it without a scheduler feature,
  by pacing compaction in beats (`lsm.md:44-62`). In Ren that is plain code:
  a compaction loop doing a fixed slice per beat, plus `Async.yield()`.

## Recommendation for 1.0

1. **No preemption of code that can't wait.** This keeps decision 12, QSBR's
   soundness and replay. State it as the rule: *a task switches only at a
   scheduling point; code with an empty row has none.*
2. **A counted budget at scheduling points.** After *B* consecutive
   scheduling points that didn't wait, the next one where the task holds no
   instance yields to the back of the queue, after a world poll. *B* is a
   parameter of the scheduler handler, `Async.work_stealing(cores: 8, budget:
   128)`, as Effect makes `MaxOpsBeforeYield` a reference. It is deterministic,
   so `single` replays it without journal entries and `sim` subsumes it.
3. **`ren_run(budget)` counts steps, never time.** A step is one task resumed
   until it waits or pays its budget. The host gets time-slicing by passing
   small budgets and reading its own clock between calls, which is what JSPI
   and Workers need. `now_ns` stays input for timers only.
4. **Poll the world on a count.** Take replies and check the injection queue
   every *K* steps inside `ren_run`, not only when idle. Each poll is a
   counted poll point, already journaled.
5. **Report stalls; don't act on them.** Add an atomic per-worker step
   counter and the current task's path, readable from any thread. A host
   watchdog, Seastar's 25 ms detector in Ren's form, prints the task path of
   a worker that stops counting. It changes nothing, so it can't break
   replay. The runtime still never creates a thread: the watchdog is the
   host's.
6. **Long pure work is spelled.** `Async.map` over a pure block splits into
   bounded chunks with polls between them. A single monolithic pure call is
   the user's to split. The stall report names it.

## What Ren should take, refuse, or still decide

1. **Take: the counted scheduling-point budget (tokio 128, Effect 2048, BEAM
   4000 reductions).** It ties to `ren_run` and decision 10. It is MISSING
   from the model, and needed even without preemption, because handler
   operations on uncontended instances and `answer_now` replies never wait.
   Make it a parameter of the scheduler constructors. Count only outermost
   dependency calls, so `over any` wrappers don't double-count. Experiment E2
   or a new one should measure the counter's cost; BEAM's `dec; jl` suggests
   it is near zero.
2. **Take: forced yields go to the back of the queue after a world poll,
   never into the LIFO slot** (tokio `yield_now`, `schedule_local`). This
   applies to `Async.yield()` too. compiler.md's `single` order says only "to
   the queue's end", so add "after the world is polled".
3. **Fix (WRONG in the current spec): `single` polls the world only when no
   task can run** (compiler.md:4490-4495). Poll every *K* steps as well, as Go
   (61) and tokio (`event_interval`) do. Otherwise a server under steady load
   never takes in a completion.
4. **Decide: `ren_run`'s `budget` unit is steps.** It then serves native,
   replay and JSPI alike, and the core still never reads a clock. Document
   that a step can't be interrupted, so hosted CPU limits kill a long pure
   call rather than pause it.
5. **Refuse: signal or async preemption and back-edge checks in pure code.**
   They need frames Ren doesn't have and break `Mem.snapshot`'s
   no-scheduling-point rule. They also can't be replayed without rr-style
   counters. Go paid 7.8% for its loop variant before choosing signals. Keep
   foundations.md:1369's reversal, and record this reason in it.
6. **Decide: is a budget yield allowed while holding an instance?**
   Recommendation: no, pay it at the next point that holds none, so a yield
   never convoys an instance's queue. That fits decision 10's "an operation
   keeps its instance until it returns".
7. **MISSING: replies can be trapped behind a hog.** One ring per worker
   means a worker stuck in pure code can't reap completions that other,
   idle, workers could run. The options:
   - (a) a peer may drain a stalled worker's completion queue under a
     per-ring lock (the driver's business, outside the core);
   - (b) route replies through the core's injection queue, which happens
     already for `ren_reply`, and require drivers not to depend on the
     submitting thread to reap;
   - (c) accept it, as Seastar and Glommio do, and document it.

   Go and tokio both avoid the problem with a shared poller. Add it to E5 or
   E6: a 100 ms pure call on one worker, and the reply latency of tasks on
   its ring.
8. **MISSING: a long pure call stalls `Mem.snapshot` reclamation on every
   core.** BEAM lets only preemptible threads take part in thread progress
   (`erl_thr_progress.c:31-41`). The options:
   - (a) switch reads to announce-on-entry, epoch style (crossbeam-epoch
     `pin`), so a worker outside a read block never holds reclamation back.
     This costs a store per read; the earlier measurement put Ren near
     crossbeam-epoch anyway;
   - (b) keep QSBR and have long pure calls mark their worker offline. The
     compiler can't know which calls are long, so this means it does so for
     every call into an empty row above some size;
   - (c) accept and report.

   Recommend (a). A worker idle in `ren_run` must count as quiescent either
   way, as BEAM's sleeping threads do.
9. **Take: the LIFO slot for instance handoff and wakes, capped at 3 and
   sharing the waker's budget, but stealable,** with Go's short back-off,
   because Ren tasks are heap frames. Tokio's unstealable slot is the one
   part of its design it keeps revisiting.
10. **Take: steal half from a random victim, cap searchers at half the
    workers, and check the global or injection queue every *N* ticks.** For
    *N*, take Go's fixed 61 or tokio's tuning to about 200 µs of work. A
    fixed count is deterministic; the tuned one is time-based. Choose the
    fixed count for 1.0.
11. **Take: a stall detector as a host watchdog over a per-worker progress
    counter** (Seastar `blocked-reactor-notify-ms` = 25). It reports the
    task path, which Ren already has, and changes no scheduling. Add two ABI
    functions: `uint64_t ren_progress(ren_core *, int worker)` and a way to
    read the current task's path. Both are any-thread and read-only.
12. **Take: `sim` randomizes where budgets fall.** FDB's sim yields after a
    random 1..150 (`sim2.cpp:1311-1321`), Go randomizes runnext under
    `-race`, and Seastar shuffles in debug. Ren's `sim` already switches at
    every scheduling point. Make sure it also draws K-step world polls and
    budget yields from the tape, so no program comes to depend on *B* or *K*.
13. **Refuse for 1.0: priorities.** Strict priorities invert against decision
    10's instances, and FDB shows the sprawl. flottning's compaction-versus-
    requests need is met by TigerBeetle-style pacing in plain Ren.
14. **Decide later: shares, not priorities, if a latency class is ever
    needed.** That would be Seastar or Glommio shares on a scope,
    `Async.scope(shares: 100)`, with Glommio's lesson that a latency class
    shortens the budget rather than reordering queues. Keep it out of the
    1.0 ABI, but don't make `ren_run`'s queues assume a single class.
15. **Take: `blocking` foreign calls as world calls answered by the driver's
    pool.** This is already better than Go's `retake` and tokio's
    `block_in_place`: no worker is ever stuck in a syscall, so Ren needs no
    sysmon. BEAM's dirty-NIF split, CPU versus I/O, suggests the driver's
    pool may want two sizes: *cores* for CPU-heavy foreign calls and a fixed
    number (BEAM uses 10) for blocking I/O. Decide when flottning's
    compression or checksum foreign calls appear.

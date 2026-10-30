# R4: Journals, durable execution, record/replay and simulation

Track R4 of the runtime research. It asks what Ren's journal, its replay driver and its sim driver should learn from systems that already record, replay and simulate. Ren's model is in the brief: a journal is the list of calls and replies, replay is a driver, sim is a driver, time is a reply, and the bytes policy is configurable.

Sources read. Clones are in `/tmp/ren-refs`; the ones added for this track are `sdk-shared-core`, `restate`, `sdk-core`, `sdk-go`, `madsim`, `turmoil`, `shuttle` and `durabletask-go`. Line numbers are against those shallow clones as of 2026-10-29. Anything marked *(memory)* comes from memory and was not checked against source.

---

## 1. What each system records

| System | Unit journaled | Records inputs | Records schedule | Records outputs |
|---|---|---|---|---|
| Restate | one invocation | yes: notifications, completions and signals | the **relative order** of notifications | yes, as commands, compared on replay |
| Temporal | one workflow execution | yes: events in the history | no; the dispatcher is deterministic | yes, as commands matched against events |
| Durable Task | one orchestration | yes: history events | no | name and sequence number only |
| rr | a process tree | syscall results, memory writes, signals | yes: every context switch, at a tick count | no (they replay by themselves) |
| FDB sim2, TigerBeetle VOPR, madsim, turmoil | nothing; the seed *is* the record | made from the seed | made from the seed | — |
| shuttle | a `Schedule`: a seed plus task choices | the random draws | yes, every choice | — |

**Restate is closest to Ren.** Its protocol journal is "an ordered sequence of two kinds of messages": **Commands**, the operations the invocation performed, and **Notifications**, the completions and signals delivered *to* it (`sdk-shared-core/docs/service-invocation-protocol.md:144-157`). The key rule is on line 155: "The relative ordering of notifications delivered by the runtime … is significant: on replay the SDK MUST observe the same relative order it observed when processing." Calls and replies alone are not enough. The **order in which replies were delivered** is part of the journal. This is the same thing as decision 11's "records each poll".

The SDK side is a sans-I/O state machine with no sockets: `notify_input(bytes)`, `take_output() -> bytes`, `sys_call`, `sys_sleep`, `sys_run`, `do_await`, `take_notification` (`sdk-shared-core/src/lib.rs`, `trait VM`, around lines 484-625). It has the same shape as Ren's `ren_poll_call` and `ren_reply`. *(memory)* The TypeScript SDK runs this crate compiled to WASM, so a sans-I/O core driven by a JS host is shipping today. Temporal has the same split: a Rust `sdk-core` drives each language SDK through a C bridge (`sdk-core/crates/sdk-core-c-bridge`, `sdk-core/ARCHITECTURE.md:9-20`), polling "activations" and completing them with commands.

Restate also has **ephemeral commands**, whose result is never journaled. They are allowed only "in a context where its effect is recorded otherwise, typically within a `ctx.run`" (`service-invocation-protocol.md:399-424`). This is exactly the rule for Ren's "metadata only" bytes policy, covered in section 3.

**Temporal records no schedule.** The Go SDK runs every workflow coroutine on one dispatcher, in a fixed order, until all are blocked (`sdk-go/internal/internal_workflow.go:1283-1323`, `ExecuteUntilAllBlocked`). Given the same history, the interleaving comes out the same. That works because a workflow is single-threaded and cooperative, which is Ren's position under `single`.

**rr records the schedule because it must.** It runs every thread on one core and writes each context switch as a `sched` frame carrying a per-task tick count, the retired conditional branches (`rr/src/rr_trace.capnp:333-356`; scheduling policy at `rr/src/Scheduler.h:24-61`). It records syscall results *and the memory the kernel wrote* (`memWrites`, `rr_trace.capnp:343`), because a syscall's output is a buffer. Ren's `Fs.Call.Read { into: buf }` is the same case: the reply's content includes the bytes written into `buf`. rr needs hardware counters only because it preempts. **Ren has no preemption, so every delivery happens at a poll point.** That puts rr's hardest problem, placing asynchronous events precisely, out of scope by construction.

## 2. Time is a reply: everybody agrees

- FDB `Sim2::now()` returns a field, and the run loop advances that field to the next timer when nothing is ready (`foundationdb/fdbrpc/sim2.cpp:1240`, `1593-1601`). `timer()` deliberately runs up to 0.1s ahead of `now()` (`sim2.cpp:1242-1246`), so code can't assume the two clocks agree. A buggified delay adds jitter to 25% of delays (`sim2.cpp:1284-1288`).
- TigerBeetle injects `Time` as an interface with `monotonic` and `realtime` (`tigerbeetle/src/stdx/time.zig:17-38`). `TimeSim` adds clock drift as a linear, periodic, step or non-ideal offset (`time.zig:198-240`). The VOPR then tests Marzullo clock sync against skewed clocks. Time can be wrong in more ways than "later".
- Temporal's `workflow.Now()` is the timestamp of the workflow-task event, and Durable Task's `CurrentUtcDateTime` works the same way *(memory)*. Timers are commands, and `TimerFired` is a history event.
- madsim intercepts libc `clock_gettime` and `getrandom` so that a third-party crate can't escape (`madsim/madsim/src/sim/time/system_time.rs:40-81`, `sim/rand.rs:197`).

**The conflict in Ren's draft ABI:** `ren_run(core, worker, now_ns, budget)` hands the core a clock reading, and `ren_poll_deadline` asks the core for a deadline. If the core uses `now_ns` to decide which timers fire, the core is reading a clock, and `now_ns` has to be journaled. Temporal and Restate both make a timer a command whose firing is a notification. Ren can do the same: `sleep_until` is a world call (`Clock.Call.SleepUntil { t }`), and a fired timer is its reply. The driver keeps the timer wheel; under io_uring that is `IORING_OP_TIMEOUT`, or a wheel checked once per loop. Replay then needs no special case for time, and the sim driver advances virtual time when `ren_run` returns `idle`, exactly as FDB's run loop does.

## 3. Bulk bytes and journal size

- **Temporal** hard-limits a history at 51,200 events or 50 MB and warns at 10,240 events or 10 MB (https://docs.temporal.io/workflow-execution/limits). The answer to growth is `ContinueAsNew`: a new history that starts from a state you carry over. *(memory)* Each payload blob is limited to 2 MB. The Go SDK exposes the server's hint as `GetContinueAsNewSuggested` (`sdk-go/internal/workflow.go:1562-1569`).
- **Durable Task** keeps large payloads out of the history. It writes them to a payload store (Azure Blob, a shared filesystem, or memory) and puts a reference in the history (`durabletask-go/payload/doc.go`, `payload/file.go`).
- **Restate** sets a per-deployment `journal_retention` (`restate/crates/types/src/endpoint_manifest.rs:40-63`). Journals are per invocation, so they are bounded by the unit of work.
- **rr** chooses per mapping how the bytes come back. `source: zero | trace | file(backingFileName)` (`rr_trace.capnp:203-212`) means the bytes are zero, are copied into the trace, or are a file that was **cloned (reflink) or hard-linked** into the trace directory instead of copied (`rr/src/TraceStream.cc:1015-1060`). `rr pack` later makes the trace self-contained. Chunks are Brotli-compressed (`rr_trace.capnp:174-177`).

Two lessons follow for Ren's configurable policy.

1. **Inputs and outputs differ.** The bytes a program *read* (an `Fs.read` or `Net.recv` reply) are needed to replay. The bytes it *wrote* (an `Fs.write` call's buffer) are needed only to compare, and a hash compares just as well. For flottning, WAL writes are outputs and network reads are inputs. A policy of "full bytes or metadata only" is the wrong split. It should be per direction: **inputs stored, outputs hashed** by default.
2. **"Metadata only" can't replay. It can only check.** Restate's ephemeral rule says it plainly: an unrecorded result is usable only where its effect is recorded some other way. A journal whose read bytes were dropped is a trace for diagnosis, and `ren replay` should refuse it up front ("this journal was recorded with inputs: none") rather than diverge halfway through.

**The unit of journaling is the bigger question.** Every durable-execution system journals **one unit of work** (an invocation, a workflow, an orchestration), never a whole long-running process. A whole-process journal of a server is as big as a WAL and grows forever. You also can't replay it from the middle without a snapshot, which is what ContinueAsNew provides. Ren already has the tool for per-unit journals: decision 11's "recording a user's own dependencies … plain Ren over `over any`". A `recorder over Store` around one connection's task subtree journals that request with the shared store as its boundary, the way Restate treats state access as commands.

## 4. Detecting divergence

| System | What is compared | How it is reported |
|---|---|---|
| Restate | command header; payload unless `ignore_payload_equality` (`sdk-shared-core/src/vm/transitions/journal.rs:34`, `1025-1040`) | `570 JOURNAL_MISMATCH` with index and diff, "code paths taken during the previous execution and … this execution" (`src/vm/errors.rs:71`, `203-249`); a separate error for an `await` added without a new revision (`errors.rs:256-310`) |
| Temporal | command type and id against the next event; payloads are not compared (`sdk-core/crates/sdk-core/src/worker/workflow/machines/workflow_machines.rs:1029-1050`) | `nondeterminism!("No command scheduled for event …")` |
| Durable Task | activity name, version and sequence number (`durabletask-go/task/orchestrator.go:1283-1297`) | "a previous execution called CallActivity for '%s' … but the current execution doesn't have a matching action"; a late, unmatched completion is silently dropped (a TODO at `orchestrator.go:1302-1306`) |
| rr | registers and ticks at every event (`rr/src/ReplaySession.cc:870-945`) | "Replay diverged", with a register dump |
| FDB | a final random draw, the "unseed", from a second run with the same seed (`foundationdb/fdbserver/fdbserver.cpp:2395-2402`) | the unseeds differ |
| madsim | a log of a hash of (RNG state xor sim time) at every random draw, checked on a second run (`madsim/madsim/src/sim/rand.rs:63-85`; `runtime/mod.rs:178-200`) | "non-determinism detected at {time}", at the first draw that differs |

Ren's handlers.md design already beats most of these: strict replay compares dependency, operation **and arguments**, and points at the call site. What the prior art adds:

- **Compare large arguments by hash.** Restate makes payload comparison optional because payloads are big and sometimes unstable to serialize (`PayloadOptions::unstable_serialization`, `src/lib.rs:43`).
- **Name the kind of divergence.** Restate has a separate message for "an `await` was added", which in Ren is a new poll point. Ren should tell apart *a call differs*, *a delivery point differs*, *the program ended early or late*, and *the journal was recorded under a different build*.
- **Check the simulator itself.** The FDB and madsim double run is nearly free with a journal: hash each entry into a rolling digest, run the same seed twice, and compare digests. madsim reports the *first* differing point, not just the end. Ren's sim driver needs this to trust its own determinism, for example a `HashMap` with a random seed inside a `trust` library.

## 5. Surviving code changes

- **Temporal** uses patch markers. `patched(id)` records a marker command, and on replay the outcome follows the table at `sdk-core/crates/sdk-core/src/worker/workflow/machines/patch_state_machine.rs:1-20`. It adds deprecate_patch for cleaning up afterwards, and worker versioning pins executions to builds.
- **Restate** refuses in-code versioning altogether. Deployments are immutable, "requests start and end on the same version", "no version compatibility logic is needed", and a fix goes in by pausing the invocation and resuming it on a new deployment, provided the fix stays compatible with the entries already executed (https://docs.restate.dev/operate/versioning).
- **Durable Task** includes the activity version in its match (`versionsMatchReplayHistory`, `orchestrator.go:1288`). *(memory)* It recommends deploying versions side by side.

Ren's journal is a debugging and test artifact, not a resumable execution, so Restate's answer fits. **A journal names the build it came from.** Replaying under a different build gives a warning, then strict replay, and the test-fixture mode compares outputs as a diff (already in handlers.md). Task paths (`main/accept:7/handle:0`) and instance names (`docs[DocId(7)]#3`) are the right stable keys, and they're better than Temporal's sequence numbers, which shift when a call is added. Temporal's `patched()` is the price of durable execution resuming across deploys. Ren doesn't need it in 1.0, and if it ever wants durable execution, that belongs in a std library over `recorder`.

## 6. Replaying a multithreaded run

No system here replays parallel execution *in parallel*. rr serializes everything onto one core. FDB, TigerBeetle, madsim and turmoil run every simulated node on one thread (turmoil `crates/turmoil/src/sim.rs:418-460`; madsim picks a random ready task, `sim/task/mod.rs:263-264`). shuttle replaces the scheduler and records every choice.

For Ren this means:

- A journal recorded on `single`, `pinned`, or `per_core` with no cross-core sharing replays exactly from calls, replies and delivery points.
- Under `work_stealing`, the *place* (which worker ran which task) is the runtime's business and doesn't need recording. The *order* of operations on each shared handler instance does need recording, and decision 11 already says so. Locked handlers make that cheap: one sequence number per acquisition. **Lock-free handler operations and `Mem.snapshot` reads are the gap.** Recording which version a snapshot read saw, or the order of `cas` operations, costs an entry per access, which is the cost rr refused. The honest 1.0 rule: a `work_stealing` journal replays world answers exactly and locked-handler order exactly, replays on the deterministic scheduler (N virtual workers on one thread), and reports a divergence at a lock-free or snapshot access as *a schedule divergence, not a code change*. Decision 11's "then the seeded tape explores" takes over from there.
- Replies arrive through `ren_reply` from any thread, so the **arrival** order is noise. The **delivery** point, the step of `ren_run` at which a task first sees the reply, is what gets journaled. That means the core writes the journal, not the driver (section 8, item 1).

## 7. What a simulator is built from

From FDB, TigerBeetle, turmoil, madsim and shuttle, the smallest set of pieces is:

1. **One seed that splits into typed streams.** This is Ren's tape. FDB's `deterministicRandom()` is one stream; madsim even seeds std's `HashMap` (`rand.rs:45-49`).
2. **Schedule control at a single choke point.** shuttle's whole interface is `next_task(runnable, current, is_yielding)` plus `next_u64()` (`shuttle/shuttle-engine/src/scheduler/mod.rs:75-101`). Its PCT scheduler needs task *identities*, not just a count, to assign priorities. The schedule serializes to a short string for replay (`scheduler/serialization.rs:88-140`).
3. **Virtual time that jumps when idle,** as in FDB's run loop (above). turmoil's simulated io_uring gives each operation its own completion time, so "out-of-order completion falls out naturally" (`turmoil/crates/turmoil-io-uring/src/lib.rs:1-15`). That is exactly a completion-shaped sim driver.
4. **Fault points inside the code, not only at the world.** FDB's `BUGGIFY` decides once per run, per `file:line`, whether a site is active (25%), then fires it with some probability (`foundationdb/flow/include/flow/Buggify.h:52-92`). It's used to shrink buffers and force rare paths, not only for I/O errors. madsim copies it (`madsim/src/sim/buggify.rs`). It needs a **stable site identity**.
5. **Crash and restart of a node** without running its cleanup: FDB `killProcess` and `rebootProcess` (`fdbrpc/include/fdbrpc/simulator.h:119-121`), turmoil `crash` and `bounce` (`sim.rs:163-200`), TigerBeetle `crash_probability` and `restart_probability` (`vopr.zig:203-206`).
6. **A disk that knows what is durable.** Writes stay pending until fsync. On a crash they're lost or torn, and a file whose directory entry wasn't synced disappears: turmoil-fs `crash` (`turmoil/crates/turmoil-fs/src/lib.rs:1090-1130`), FDB `AsyncFileNonDurable` (`fdbrpc/include/fdbrpc/AsyncFileNonDurable.h:97-140`). TigerBeetle adds misdirected writes and a "fault atlas" that injects only the faults a correct cluster *can* recover from (`tigerbeetle/src/testing/storage.zig:1-60`, `76-79`), so the simulator doesn't report false failures.
7. **A network that can clog, partition, lose and delay:** turmoil `hold`, `partition`, `repair` and `fail_rate` (`crates/turmoil/src/lib.rs:323-360`, `top.rs:537-545`), FDB clogging (`sim2.cpp:192-264`).
8. **Swarm testing and a liveness phase.** VOPR picks the fault *parameters* themselves from the seed (`options_swarm`, `vopr.zig:374`). After the safety phase it stops the faults and requires a core of replicas to converge (`vopr.zig:263-350`). A sim that only checks safety misses stuck systems.
9. **Many nodes in one process.** FDB, TigerBeetle, turmoil and madsim all run a whole cluster in one OS process. That requires **no global state in the runtime or in compiled programs.**
10. **A determinism self-check** (section 4).
11. **Assertions that guide the search.** Antithesis adds "sometimes" assertions and reachability, plus a fully deterministic hypervisor that branches timelines from interesting states (https://antithesis.com/docs/introduction/how_antithesis_works/, https://antithesis.com/docs/using_antithesis/sdk/). Its SDK turns into no-ops outside Antithesis. That is a good model for Ren's `sim` std module: real code paths with simulation hooks that cost nothing in a real run.

## 8. What `trust` and FFI break (rr's lesson)

rr records at the syscall boundary because it's the narrowest point every source of nondeterminism passes through for an *unmodified* binary. Anything that crosses it some other way can't be recorded: memory shared with an unrecorded process (rr refuses it), `rdtsc`, and `cpuid` (trapped and patched). Ren's boundary is the bottom handler, which is narrower and typed. A `trust` foreign function that reads the clock, keeps its own threads, or uses a randomly seeded hash table bypasses it in the same way. Making `blocking` foreign calls world calls covers the blocking case. Other foreign code with side effects is unrecordable, and the journal should say so. rr records its environment's assumptions in the trace header, for example `ticksSemantics` and the CPU feature state (`rr_trace.capnp:36-77`).

---

## What Ren should take, refuse, or still decide

**Take**

1. **The core writes the journal; drivers don't.** Calls and replies are not enough. Restate's ordered notifications and decision 11's poll records both say the *delivery point* of each reply must be recorded, and only the core knows it. The cancel-versus-reply race is also settled inside the core. **Missing from the ABI:** a journal sink, either `void (*journal)(void *host, const ren_entry *)` in `ren_host` or a `ren_poll_entry(core, worker, out)` ring that the host drains. Entries: `Call`, `Deliver(reply, at step)`, `Cancel`, `Release`, `Choice` (item 4), `End`.
2. **Timers are calls; drop `now_ns` from `ren_run`.** `Clock.Call.SleepUntil` is answered by the driver: the real driver uses its timer wheel or `IORING_OP_TIMEOUT`, the sim driver advances virtual time on `idle`, and the replay driver answers from the journal. `ren_poll_deadline` goes away, since the driver already holds every deadline. If `now_ns` stays for scheduling heuristics, it must never change meaning, and that can't be checked, so drop it. **The draft ABI is wrong here:** it lets the core read time.
3. **The bytes policy is set per direction, not as full versus metadata.** Inputs (reply bytes, including the bytes written into an `inout` buffer, which rr records as `memWrites`) are stored by default, and outputs (call bytes) are hashed. Storage modes: `inline | side-store by content hash (rr's clone/hardlink, Durable Task's payload store) | hash only | none`. A journal whose inputs weren't stored is marked *check-only*, and `ren replay` refuses it at load, not halfway through.
4. **Scheduler choices are replies.** In the deterministic scheduler, each place the order can matter becomes an inline world call, `Sched.Call.Pick { runnable: [task path] }`, answered through `answer_now`: by the seed (sim), by the journal (replay), or FIFO (real). This is shuttle's `next_task` plus `next_u64`, and it puts the tape inside the same journal as everything else. It must carry task **identities**, so PCT-style choosers can work later.
5. **The journal header names the build fingerprint, scheduler, worker count, driver kind and bytes policy.** A replay under a different build warns, then stays strict. Restate's immutable deployments, not Temporal's `patched()`.
6. **Divergence has kinds.** The report says whether a call differs (with an argument diff, or a hash for large arguments), a delivery point differs (an `Async.until` or poll was added or removed), the run ended early or late, the build differs, or it's a schedule divergence at an unrecorded lock-free or snapshot access. It always gives the task path and the call site.
7. **A determinism self-check from day one.** Keep a rolling digest of journal entries. `ren test --check-determinism` runs a seed twice and reports the first entry that differs, as madsim does. It's cheap, and it catches a `trust` library that leaks nondeterminism.
8. **Per-unit journals for servers.** The whole-program journal is for CLIs, tests and bug reports. For flottning, the useful journal is one connection or request subtree, recorded with `recorder over <shared dep>`, which is how Restate and Temporal bound their journals. Write this down now, so nobody expects `ren run --record` on a server to produce a replayable file of reasonable size.

**Refuse**

9. **A Temporal-style `patched()` or version API in the language.** Ren's journals aren't resumed across deploys. If durable execution ever comes, it's a std library over `recorder`.
10. **Recording every lock-free or snapshot access under `work_stealing` to promise exact parallel replay.** rr refused that cost, and so should Ren. Promise exact replay for world answers and locked-handler order, and report the rest honestly (§6).
11. **Comparing whole payloads always.** Hash large arguments and outputs.

**Still decide**

12. **Several cores in one process, and crash.** A flottning cluster sim, like FDB, TigerBeetle and turmoil, runs several programs in one OS process. **Missing:** a guarantee that `ren_start` can be called several times with no shared global state, both in the runtime and in the compiler's top-level `let`s, plus a `ren_kill(core)` that drops a core without running `finally`, so the sim driver can then discard un-fsynced writes. `ren_start`'s `int (*main)(void)` is fine, since per-node arguments are world replies.
13. **The `Fs` call set must expose durability:** `sync`, `sync_dir`, and write versus durable. Without it the sim driver can't model torn or lost writes, and flottning's WAL can't be tested (turmoil-fs, FDB `AsyncFileNonDurable`, TigerBeetle's storage).
14. **Fault points inside code (BUGGIFY).** They need a stable site identity. Ren has call-site labels from task paths, so a std `sim.maybe()` over `Random` keyed by site is enough, provided the language exposes the site as a value. Decide whether that identity is a general primitive (decision 20, rule 3).
15. **How the cancel race is journaled.** When a reply and a cancel cross, the core decides "delivered" or "released" at the delivery step and journals that decision. Replay then has to *force* the same outcome, so the replay driver must be able to return a reply to a cancel it would otherwise have released. Check that `ren_reply` after a cancel is defined both ways.
16. **Flushing the journal.** A panic is the last entry, but a SIGKILL or OOM loses the buffered tail. Decide whether recording flushes per entry (slow), per poll, or stays buffered with that loss accepted. Restate's `REQUESTED_ACK` is the durable-execution version, which Ren doesn't need.
17. **`trust` FFI.** A foreign call that isn't `blocking` and isn't a driver call is outside the journal. Decide whether the journal header marks such a run as "contains unrecorded foreign effects", or whether a recorded build refuses them.

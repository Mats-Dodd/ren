# Brief: the runtime core stage, part two (many cores)

You're putting Ren's runtime on many cores: the `per_core` scheduler
with home cores and the hybrid take, `work_stealing`, `pinned`, the
memory model's shared paths (the shared mark, atomic counts, per-thread
heaps with frees returned home), io_uring and the second real driver,
`striped` and `actors` on many cores, the stall watchdog's report, and
phase two of the experiments on the real runtime, ending in a server
benchmark against Go and Rust. It's foundations.md Staging item 8, part
two. Part one (briefs/stage-runtime-core.md) built the core on one
core; part three is arenas, snapshots and `Atomic` fields (don't start
it).

Ren is a systems language whose compiler is written in OCaml. Work on
`main`. This brief is self-contained: it names everything you need in
the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**This stage starts when runtime core part one has landed,** and
generators part two has too, since both change the native runtime.
Check their final reports in compiler.md first.

**Nothing here changes meaning.** A program's output, its panics and
its journal under `sim` are what they were on one core. Many cores
change cost and which free order a run takes, and the journal records
the order.

## Read first

- **runtime.md**, all of it, and especially "A shared take under
  `per_core`" (the hybrid take and its three rules), "Places" (`at`
  shipping each operation, or moving the task for about 8 or more),
  the `per_core` scheduler's drain and spin, "Under `work_stealing`",
  and "What's journaled" (place isn't, unless it's read).
- **briefs/stage-runtime-core.md**, and part one's section and progress
  log in compiler.md ("Runtime core stage"): the core's files, verbs,
  conformance harness and what was left.
- **experiments/runtime-frames/RESULTS.md**, X3, X3b and X3c, and
  **x3c/README.md** (the hybrid's word, rules and proofs): your
  reference implementations and the numbers to hit.
- **research/runtime-core-model/MODEL.md**: the eight rules, and its
  "Limits": the model is sequentially consistent, so memory orders need
  their own check.
- **experiments/native-lang/**: SPEC.md §A (the Chase-Lev deque, with
  every ordering), SYNTHESIS.md §2 (what TSan and GenMC catch), and the
  lost-wake hangs the Rust and Zig cores had.
- **compiler.md**, "The runtime model": the four count states, rules U,
  B, H, M and J, one current heap a task, and what Mem Lint checks.
  Rules X and D, arenas and snapshots, are part three's.
- **foundations.md**: decision 10 (sharing; exclusion skipped unless
  shared), decision 18 (actors and stripes) and its table of what each
  runtime does, "On many cores, decided now", and Staging item 6's
  experiments (P2 to P5, S1 to S4, K1, K2, K4, the cache three ways).
- **concurrency.md**: families, home cores, `per_core` as the default.
- **runtime-io.md**: io_uring, linked operations, leased buffers.
- **module-build.md**, "Incremental by construction".
- **bench/native/README.md** for how to measure.

## Scope

**In:**

1. **`per_core`:** one worker per host thread, one ring each; a key's
   home from its `ren_carry` hash; the hybrid take with its three rules
   (a task with a call in flight to the instance ships its next one; a
   failed take at the home closes the in-place path; a 300 ns retry
   while one in-place holder holds it); `at` shipping each operation,
   or moving the task when the compiler sees about 8 operations or
   more, the choice per block; moved-in tasks run fairly beside the
   home's own; the inbound queue drained at every scheduling point,
   tasks just resumed run first; a worker spinning about 5 µs before it
   sleeps; the stickiness knob after a failed take, off by default.
2. **`work_stealing`:** SPEC §A's deque; a contended take parks the
   task, and a release hands the instance to a waiter that has waited
   1 ms.
3. **`pinned`:** `Async.pinned()`, a thread of its own for opaque C
   resources, the only nesting of runtimes.
4. **The memory model's shared paths:** the shared mark (rule M) at
   every marking point, atomic counts on shared objects, per-thread
   heaps with frees returned through the owner's delayed-free list
   (rule H), one current heap a task, joins with release and acquire
   (rule J), and Mem Lint's checks for them. Under `single` and `sim`
   none of it is compiled, as today.
5. **Families on many cores:** `striped` and `actors` as decision 18's
   table says for `per_core` and `work_stealing`; setup and an
   eviction's `finally` at the key's home; sampled eviction the same
   choice however keys are spread; `Async.worker()` answered by the
   real worker and journaled.
6. **Drivers:** io_uring on Linux, with batched submission and the
   linked write-then-sync; and whichever of kqueue or epoll-as-
   completion part one didn't build. Leased buffers returned to the
   pool when their count reaches zero, a post to the world.
7. **The stall watchdog's report:** a worker whose progress counter
   hasn't moved names the task and the resume site's line, as
   runtime.md says; `Async.yield()` checks the budget.
8. **Memory orders, checked:** the deque, park and wake, the hybrid
   take's word and the delayed-free list, under TSan, and under a
   weak-memory checker (GenMC on the C) for the parts the FizzBee model
   couldn't reach.
9. **Phase two of the experiments,** on the real runtime: P3, S1, K1b,
   the cache three ways, P2, P4, P5, S2, S3, S4, K4 (foundations.md,
   Staging item 6), and X3c's collapse under heavy load, with the
   stickiness knob measured.
10. **The server benchmark** against Go and Rust: examples/server's
    shape over real sockets, throughput and p99 at 1 to 16 workers.

**Out (don't start them):**

- Arenas, `Mem.snapshot`, read blocks, `Atomic` fields, rules X and D
  (part three).
- Hosted and JS drivers, Web Workers and places without shared memory.
- A user-written scheduler.
- TLS and HTTP (stage 12 and 13).

## Working beside the other stages

**Stage 12a** (the shape machinery) and **stage 12b** may be on `main`
at the same time.

- **Yours:** lib/native/runtime/ (the schedulers, the shared paths of
  the count and the heaps, the drivers), the native lowering of `at`'s
  ship-or-move choice and of marking points, Mem Lint's new checks,
  bench/native's runtime and server benchmarks, tests you add.
- **Theirs, don't touch:** stage 12's front end (top-level and
  signature `let`, shapes, looks, the doors, templates), the prelude's
  contents, std's `json`, `cli`, `shape`, `http` and the rest of 12b.
- **The interpreter is the reference.** Change lib/eval/ only if part
  one's conformance harness needs a new kind of comparison, never its
  semantics. If the reference is wrong, stop and say so in the
  progress log.
- **Shared files** (to_mem.ml, emit_c.ml, specialize.ml, mem_lint.ml,
  ren_rt.c): add your cases; don't move, rename or restructure code
  there.
- **New tests go in new files.** Don't rewrite existing tests.
- **Rebase before every push.** If a conflict touches their work, keep
  theirs and redo yours on top.

## Steps

Do them in order. After each step THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, baseline, tests first.** Add a "Runtime core stage, part
   two" section to compiler.md. In it, settle:
   - **The workers and the host loop on many threads:** who makes the
     threads (the host, never the core), one ring each, and how
     `ren_thread_init` binds them.
   - **The hybrid take's word** as x3c/README.md gives it, in the core's
     C, and where its three rules sit.
   - **`at`'s choice:** how the compiler counts a block's operations,
     and what it emits for ship and for move.
   - **Marking points:** each one rule M lists, where the compiler
     emits `Mark_shared`, and how Mem Lint checks it.
   - **The heaps:** chunk ownership, the delayed-free list, the current
     heap pointer and when it's swapped.
   - **The memory-order checks:** which code runs under GenMC, with
     what harness and bounds.

   **Baseline:** part one's numbers on this machine; X3, X3b and X3c's
   models rebuilt and run here, as the reference each scheduler is held
   to; examples/server under Go and Rust twins (write them, as
   bench/native's twins are written).

   **Tests,** marked skipped or expected to fail until their step:
   test/test_runtime_core_2.ml with `until "m1"` ... `until "m7"`, and
   bench/runtime_core_2.t. At least:
   - every conformance test from part one, under `per_core` and
     `work_stealing` on 2, 4 and 8 workers: the same output and panics,
     and a journal recorded on 8 workers that replays on 1;
   - X3c's ordering test with posted puts: no task's calls reordered,
     and the in-flight rule's mutant reordering them;
   - the no-starvation rule: the home's queue waits at most one in-place
     operation;
   - a shared object freed on a thread that didn't allocate it, back to
     its owner's heap, under the debug runtime's rule H assertion;
   - an unmarked object reaching another thread, which Mem Lint refuses;
   - the stall watchdog naming a long plain loop by its line;
   - every family test from the services stage on many cores, by output
     and by replay;
   - TSan clean over the whole suite on many cores.

1. **`per_core`, with the hybrid take.** Scope 1, with scope 4's
   shared paths it needs.
   **Done when** m1 is on; part one's conformance tests pass under
   `per_core` on 2 to 8 workers; and X3c's scenarios on the real
   runtime keep its ratios: rare sharing near a thread lock's wait,
   contention near shipping's throughput, background work flowing past
   a 100 µs hold.

2. **The memory model's shared paths, complete.** Scope 4: marking,
   atomic counts, per-thread heaps, joins, Mem Lint's checks.
   **Done when** m2 is on, under ASan, UBSan and TSan, and the
   sequential benchmarks under `single` haven't moved past noise.

3. **`work_stealing` and `pinned`.** Scope 2 and 3.
   **Done when** m3 is on; the conformance tests pass under
   `work_stealing`; X3's parking numbers hold on the real runtime; and
   an opaque C resource stays on its pinned thread.

4. **Families on many cores, and the watchdog.** Scope 5 and 7.
   **Done when** m4 is on; examples/docs passes a thousand seeds under
   `sim` and its tests under `per_core` and `work_stealing`; the cache
   three ways runs against Rust's dashmap and moka.

5. **The drivers.** Scope 6.
   **Done when** m5 is on, and examples/server's tests pass natively on
   io_uring and on the other driver, each on its OS, with batched
   submission measured.

6. **Memory orders, and phase two.** Scope 8 and 9.
   **Done when** m6 is on: GenMC finds no violation within its bounds,
   and its harness fails on a weakened ordering (a mutant per checked
   path); and every experiment's prediction is reported hit or miss
   with its numbers, beside the prototype's.

7. **The server benchmark.** Scope 10.
   **Done when** m7 is on, and throughput and p99 at 1 to 16 workers are
   reported against Go and Rust. vision.md's bar is within 2× of
   Rust; where it's missed, the gap is explained with a profile.

8. **Review your own work** with three lenses:
   - **Soundness:** the eight rules on many threads, the hybrid's three
     rules, rule M at every marking point, rule H on every free, TSan
     and GenMC.
   - **Meaning:** does anything a program sees depend on the scheduler,
     the worker count or where a key lives? Does every journal replay
     on one core?
   - **Docs and tooling:** README's status and roadmap row, compiler.md,
     runtime.md's status line, bench/native/RESULTS.md.
   Fix what blocks; list the rest with its severity.

## The interpreter and native

The interpreter is the meaning, on one task at a time. What must agree:
every output and panic, every journal under `sim` for the same seed,
and every replay of a journal recorded natively on many cores, in the
interpreter and natively on one. What needn't: timings, which free
order a real run took, where keys lived.

## Risks

- **A preempted in-place holder** stalls its instance: X3c saw some
  rounds fall to a quarter of shipping under heavy load. Measure it on
  the real runtime under load, with the stickiness knob, and report;
  don't turn it on by default without the owner.
- **Memory orders.** The model can't see them, and the Zig core's hang
  was likely one. TSan finds races, not every weak-memory reordering:
  GenMC is the check that does.
- **Marking points missed.** An object reaching another thread
  unmarked is a silent use-after-free. Mem Lint's check is the guard;
  test each point it lists.
- **Fairness at the home.** Moved-in tasks must not starve the home's
  own; X3c's 100 µs case starved the home's connections under both H
  and HY. Measure the home's own latency, not only throughput.
- **The session's OS.** io_uring needs Linux and may be blocked in a
  container; say in the final report which drivers ran where.

## THE CHECKS

As in briefs/stage-runtime-core.md, "THE CHECKS", including its edit
test, plus TSan over the runtime tests on many cores. **Never weaken or
delete a test to get green.**

**Measuring.** Name the machine, its cores (performance and efficiency)
and its load. Interleave, report medians and spread, and put every
number in bench/native/RESULTS.md with the commands that reproduce it.
Compare to the experiments' ratios, not their nanoseconds.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results
  untrustworthy. Note others in your final report.
- **Do NOT edit foundations.md, language.md, runtime.md or
  concurrency.md.** If they're wrong or underspecified, make a choice,
  record it in compiler.md's section, and list it in your final report.
- **Committing:** on main, explicit `git add` paths, never `git add
  -A`; never the root `dune` file's local changes, prior-art.md, or
  anything under .claude/; every message ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push after
  each green step.
- **Keep a progress log** at the end of compiler.md's section.

## Decided

Record these in the spec; don't reopen them.

- **`per_core` is the default;** a shared take there is the hybrid,
  with its three rules.
- **`at` ships each operation or moves the task,** the compiler's
  choice per block, moving at about 8 operations or more.
- **Under `work_stealing`, a contended take parks,** with a 1 ms
  handoff.
- **The runtime never makes a thread;** one ring per worker.
- **Place isn't journaled unless it's read;** a journal from many cores
  replays on one.
- **Exclusion is skipped unless shared;** under `single` and `sim` the
  shared paths aren't compiled.
- **The eight rules of MODEL.md** hold on every scheduler.

## Final report

End with: per step, what was built, the commits, and the choices you
made where the spec was silent; whether each "Done when" holds, with
the numbers, the experiments' predictions beside them, Go's and Rust's
columns, and the commands; which drivers ran on which OS; what's
unfinished or unsound, with its severity; and which checks couldn't
run.

# Brief: the runtime core stage, part one (one core)

You're building Ren's runtime natively: the C core of
[runtime.md](../runtime.md), the frames compiled code meets it with,
tasks, instances and families on one core, the journal in its binary
form, the `sim` and `single` schedulers, and the drivers, written in
Ren inside `trust`. It's foundations.md Staging item 8, part one. Part
two is many cores; part three is arenas, snapshots and `Atomic` fields
(both outlined at the end, don't start them).

Ren is a systems language whose compiler is written in OCaml. Work on
`main`. This brief is self-contained: it names everything you need in
the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**The interpreter is the reference.** Every step ends with the native
build agreeing with it: the same output, the same panics, and under
`sim` the same journal, byte for byte, for the same seed.

## The interface is settled

runtime.md fixes the line between the core and the language, and this
stage builds to it without reopening it:

- **The core is C, and does no I/O.** Tasks and scopes, frame stacks,
  instances, queues, families' maps, the scheduler policies, the
  journal's order writer, the host ABI's nine functions. Everything
  else is Ren: drivers, the host loop, `Async`'s combinators, `actors`,
  `striped`.
- **The call record:** a 32-byte header the core owns (id and
  generation, kind `Call | Post | Cancel | Reply`, state, `to`, `task`,
  `lane`, `shape`, `len`) and a body the language owns, the `D.Call`
  value, whose tag is the operation. One reply per call.
- **`ren_carry`:** a table of functions per type the core carries
  (hash, eq, drop, encode, decode, size, shape hash), emitted from
  `ren_desc`. The core never walks a Ren value.
- **Ren reaches the core only through verbs.** The core runs Ren only
  to resume a frame, to start one with a dependency's dispatcher, or to
  ask a leaf (a `ren_carry` function, `until`'s condition) with an
  empty row. A verb that needs program code run (setup, a `finally`)
  returns it to its caller.
- **The journal** is the core's order records and the recorder's
  content records, for world calls only, joined by call id; binary on
  disk; journal v3's text is a view, `ren journal show`.
- **Incremental by construction** (module-build.md): nothing this stage
  emits holds a number the whole program assigned. `ren_carry`s and
  dispatchers are named by shape hash; resume sites by their line
  within their declaration; a callee bumps its own frame; colour is an
  interface fact.

## Read first

- **runtime.md**, all of it. It's the spec.
- **concurrency.md**: the rule, ends once, the tree side, families,
  rule 3, "No deadlock by one rule".
- **channels.md**: admission, transfer and terminal state, which the
  native queues keep as the interpreter's do.
- **module-build.md**, "In the compiler" and "Incremental by
  construction": the seven rules and the edit test.
- **research/runtime-core-model/MODEL.md**: the FizzBee model of the
  core's wake, cancel and reply protocol, its counterexamples, and the
  **eight rules the core keeps**. Every counterexample becomes a test.
- **experiments/native-lang/**: SYNTHESIS.md (why C), SPEC.md (§B, the
  core as specified, with the model's corrections to apply), c/ (a
  working core, drivers and a journal: your starting point, not code to
  paste; it predates the call record and `ren_carry`), and c/NOTES.md.
- **experiments/runtime-frames/RESULTS.md** and
  **research/runtime-frames/SYNTHESIS.md**: the register calling
  convention (X1), frame stacks (X5), the per_core results (X3, X3b,
  X3c) that part two builds.
- **compiler.md**: "The runtime model" (counts, states, the shared
  mark), "Native slice", "Stage 11a" (the interpreter's tasks, the
  point set, `sim`'s tape), "Services stage" (families, posts, rule 3,
  sampled eviction, journal version 3), "Specialization" (the two known
  breaks of the incremental rules; don't copy them).
- **handlers.md**, "The journal"; **testing.md** on `--sim --seeds`
  and replay; **async.md**, "The whole surface"; **deps.md**, "How it
  runs".
- **foundations.md**: decisions 9 (the runtime), 10 (sharing), 12
  (frames), 13 (two builds), 18 (actors and stripes), 20 (rule 4,
  optimizations are invisible).
- **bench/native/README.md** for how to measure.

## Scope

**In:**

1. **The language for drivers.** `trust` items and blocks; `foreign fn`
   (a plain C call, pure by assertion), `blocking fn` (run on the
   driver's pool thread as one world call), `foreign include`;
   `Async.submit(call) -> reply`, inside `trust` only; a callback into
   Ren needs an empty row, checked by type. Each refusal with its help.
   The real world dependencies become `trust` handlers that call
   `submit`, in the interpreter too, where the OCaml primitives answer
   it.
2. **The journal, binary.** Order records and content records in one
   file, the shape table by hash in its header, written by the
   interpreter and natively alike; `ren journal show` prints today's v3
   text from it, byte for byte; a post's line keeps its order and call
   id. Content is encoded by the `bin` look formats.md describes,
   derived from the type's structure until stage 12 builds looks.
3. **The core in C,** under lib/native/runtime/: the header, `ren_carry`,
   the verbs of tasks, instances, queues and families, the nine
   functions, the eight rules, ends once by generation.
4. **Frames.** The register convention (status and value in two
   registers) in both builds; per-task frame stacks, statically sized
   up to 256 B, one spare chunk kept while running; the trampoline; the
   resume-site table, lines relative to their declaration; colours,
   per specialization in release and by row in debug.
5. **Tasks natively:** `Async.scope(max:)`, `spawn`, the eager cancel
   walk, shielded `finally` under the deadline, `until`, `yield`,
   `tick`, and std's `timeout`, `race`, `isolate`, `both`, `map`,
   `each`, `beside`, `background`, `produce` as Ren over the verbs.
   A panic ends the program; nothing unwinds.
6. **Instances and families natively, on one core:** take, release,
   `release` mid-operation; the family map in C over `ren_carry`; pin
   handing back setup and `finally`; posts with a per-key mailbox; `at`,
   `at_all`; rule 3's run-time backstop; sampled eviction as the core's
   journaled choice, policy as data (`max:`, the sample, `chaos:`);
   `striped` and `actors` over them. Dispatchers and `ren_carry`s as
   copies keyed by shape hash.
7. **Schedulers `single` and `sim`,** chosen for `main` when compiling;
   `sim` drawing `Sched.Call.Pick` and eviction from its tape exactly
   as the interpreter does.
8. **Drivers in Ren:** the sim driver (the same source as `sim.fs`,
   `sim.net` and the sim clock), the replay driver, and one real driver
   for the OS the session runs on (kqueue on macOS; on Linux, epoll
   wrapped as completion, since containers often block io_uring), with
   the host loop in Ren, for `Clock`, `Net`, `Fs` and `Proc`. The stall
   watchdog's counter.
9. **The edit test,** as module-build.md describes it, over what this
   stage emits.

**Out (don't start them):**

- `per_core`, `work_stealing`, `pinned`; home cores, shipping, the
  hybrid take; the shared mark switched on; atomic counts; per-thread
  heaps (part two).
- io_uring, and the second real driver (part two).
- Arenas, `Mem.snapshot`, `Atomic` fields (part three).
- Pulled generators that use a dependency (11c part two), and hosted
  or JS drivers.
- Fixing specialize.ml's two known breaks. Don't add a third.

## Working beside the other stages

The **generators stage** (briefs/stage-generators.md, part one) may be
on `main` at the same time, and **bytes part two** may be finishing.

- **Yours:** lib/native/runtime/ (new files for the core; ren_rt.c only
  where the core meets it, the count and the frame stack), the
  lowering of coloured functions and of `Async`, `Instances` and
  families natively, lib/eval/journal.ml and the journal's format, the
  `trust` and `foreign` front end, the drivers and the host loop in
  std, `ren journal show`, tests and kernels you add.
- **Theirs, don't touch:**
  - generators: the streams module, `gen fn`, `yield`, the
    interpreter's generator frames, push lowering, `merge` and
    `expand` in std, `Fs.line_reader`. They refuse a pulled
    generator that uses a dependency until part two; leave that
    refusal alone;
  - bytes part two: ren_rt's string and byte code, `Str` and `Bytes`
    layout, the interpreter's `VStr` and `VBytes`, string literals.
- **The interpreter's scheduler** (lib/eval/sched.ml, family.ml) is the
  reference. Change it only to route world calls through `submit` and
  to write the binary journal; never to make the native build's job
  easier. If the reference is wrong, record it in the progress log and
  stop for the owner.
- **Shared files** (ast.ml, parser.ml, lower.ml, to_mem.ml, emit_c.ml,
  prelude.ml, std_lib.ml, builtins.ml, infer_*.ml, eval.ml): add your
  cases; don't move, rename or restructure code there. If you need a
  change that would, stop and say so in the progress log.
- **New tests go in new files.** Don't rewrite existing tests.
- **Rebase before every push.** If a conflict touches their work, keep
  theirs and redo yours on top.

## Steps

Do them in order. After each step THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, baseline, tests first.** Add a "Runtime core stage" section
   to compiler.md. In it, settle:
   - **The core's files and its C interface:** each verb's signature,
     the header and `ren_carry` as runtime.md gives them, what a verb
     that hands work back returns, and how the slice's ren_rt.c and the
     core share the count and the frame stack without a second copy
     of either.
   - **How a coloured function lowers:** its frame, its resume
     function, the register convention under clang and tcc, where a
     scheduling point is emitted, and how the point set is kept equal
     to the interpreter's.
   - **The journal's binary layout:** order records, content records,
     the header's shape table, and the `bin` derivation for content,
     with a note on how stage 12's looks will replace the derivation
     without changing its bytes for types that don't declare one.
   - **`trust` and `foreign`:** the grammar, what `trust` permits, the
     checks, and every compile error with its help.
   - **The edit test:** its fixture programs, what "the output
     declaration by declaration" is for this stage's emitted C, and
     how it runs in CI.

   **Baseline:** bench/native's sequential kernels before the stage
   (none may regress past noise); the interpreter's times for the 11a
   and services programs under `--sim --seeds 1000`; experiments X1's
   nested round trip and X5's parked-task bytes, rebuilt on this
   machine, as the numbers step 4 is held to.

   **Tests,** marked skipped or expected to fail until their step:
   test/test_runtime_core.ml with `until "c1"` ... `until "c6"`, and
   bench/runtime_core.t (native debug, release, the sanitizers, tcc).
   The conformance harness: for a program and a seed range, run it
   under `sim` in the interpreter and natively, and compare the
   journals byte for byte. At least:
   - every counterexample in MODEL.md as a C test of the core, failing
     with its rule removed (a build flag), passing with it;
   - ends once: a late reply released, a reused slot's old generation
     refused, a cancelled task waiting for its reply;
   - cancel down a tree, the first error up, a shielded `finally`
     under the deadline, a panic ending the program with its journal
     entry;
   - every family test from the services stage, natively, by journal;
   - rule 3's backstop natively, with the interpreter's message;
   - every `trust` and `foreign` error with its help;
   - the edit test on two fixtures, one generic and one with a family;
   - channels.md's "Required composition cases", natively, by journal,
     as each native feature arrives: the admission commit point under
     a racing cancel, terminal state that needs no queue room, close
     racing blocked senders and receivers, a family's drain posting
     outward, and the actor-and-channel cycle, which `sim` must report
     as a deadlock with a seed that replays.

1. **The language for drivers.** Scope 1. The world behind
   `Async.submit` in the interpreter, answered by its OCaml primitives;
   the real handlers as `trust` handlers in the prelude or std.
   **Done when** c1 is on, and every existing test, journal and example
   passes unchanged with the world behind `submit`.

2. **The journal, binary.** Scope 2, in the interpreter first, so the
   native build has a reference to match.
   **Done when** c2 is on; every journal test passes through `ren
   journal show`, its text byte for byte today's; a journal replays in
   another build through its shape table; and a type that changed
   fails the version check with a message that names it.

3. **The core in C.** Scope 3, tested from C with a harness host, no
   compiled Ren yet: the model's counterexamples, ends once, the nine
   functions, under ASan and UBSan, and TSan with two host threads
   replying.
   **Done when** c3 is on, and every counterexample fails with its
   rule off and passes with it on.

4. **Frames and tasks natively.** Scope 4, 5 and 7 under `sim` and
   `single`, with the sim driver from scope 8.
   **Done when** c4 is on; test_tasks' programs and the 11a programs
   match the interpreter's journals across a thousand seeds; the lost
   update is found natively by the interpreter's seed and replays; a
   nested round trip costs within 10% of X1's 20.7 ns on this machine's
   rebuild of X1, and a parked task within 10% of X5's 240 B, or the
   gap is explained with numbers.

5. **Instances and families natively.** Scope 6.
   **Done when** c5 is on; examples/docs passes a thousand seeds under
   chaos natively with journals equal to the interpreter's;
   bench/services' lost-update seed is 4702 natively, and memory's
   9904; sampled eviction draws what the interpreter draws.

6. **A real driver, and the programs.** Scope 8: the real driver and
   the host loop, in Ren.
   **Done when** c6 is on; examples/server's tests pass natively against
   the real driver and under `sim`; the `just` as written, its recipes
   at once, builds natively and its tests pass against the native
   build; a run recorded natively replays in the interpreter, and one
   recorded in the interpreter replays natively.

7. **The edit test, and review your own work.** Scope 9 as a gate in
   THE CHECKS from here on. Then three lenses:
   - **Soundness:** the eight rules, ends once, the cancel race, every
     place that wakes a task holding a reference, Mem Lint and the
     sanitizers.
   - **The line:** does the core read any Ren value, run any Ren code
     but a frame or a leaf, or know any type? Does any emitted name or
     id depend on the whole program?
   - **Docs and tooling:** README's status and roadmap row, compiler.md,
     runtime.md's status line, the grammar for `trust` and `foreign`.
   Fix what blocks; list the rest with its severity.

## The interpreter and native

What must agree, and the conformance harness checks: every output and
its order, every panic and where, every journal under `sim` for the
same seed, byte for byte, and every replay in either direction. What
needn't: timings, addresses, and which free order a real run took,
which the journal records.

## Risks

- **The point set.** If the native build has one scheduling point more
  or fewer than the interpreter, seeds stop matching everywhere at
  once. Emit points from the same predicate the interpreter uses, and
  make the harness's first diff name the call where they part.
- **The binary journal touches every journal test.** The view must give
  today's text exactly, or step 2 rewrites tests, which isn't allowed.
- **`trust` creep.** It's the boundary of what can reach the world.
  Keep its surface to what drivers need, and test the refusals.
- **The register convention under tcc.** Two-register returns are a
  struct return; measure tcc's cost and accept it as runtime.md says,
  don't emit two conventions.
- **The slice's runtime and the core.** One count, one frame stack,
  one allocator. A second copy of any is a bug.
- **The session's OS.** A cloud session is Linux, where kqueue can't
  run and io_uring may be blocked: build and test the driver the OS
  has, keep the driver's code behind the same Ren interface, and say
  in the final report which drivers ran where.

## THE CHECKS

All must pass before any commit:

- `dune build`
- `dune test --force`, with `REN_TCC` set (tools/tcc.sh), or bench/*.t
  are skipped
- `make -C editors/tree-sitter-ren check`
- `_build/default/bin/main.exe test` inside each of examples/bank,
  examples/prices, examples/just, examples/ledger, examples/crawler,
  examples/refresh, examples/server, examples/transfer, examples/docs,
  examples/breaker and examples/checkout
- from step 7, the edit test

Setup, portability and flakes are as the bytes stage's brief says
(briefs/stage-bytes.md, "THE CHECKS"): journal.t's timing tests flake
under load; rerun and report, never loosen. **Never weaken or delete a
test to get green.**

**Measuring.** Name the machine and its load. Interleave, report
medians and spread, and put every number in bench/native/RESULTS.md
with the commands that reproduce it. Compare to your own baseline and
to the experiments' ratios, not their nanoseconds.

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

- **The core is C; drivers and the host loop are Ren in `trust`.**
- **The call record, `ren_carry`, the verbs and the two ways the core
  runs Ren** are runtime.md's.
- **One reply per call; posts are a kind; a defect isn't.**
- **The family's map is the core's, over descriptors; which sampled
  instance is evicted is the core's journaled choice.**
- **The journal keeps the world's content and everyone's order;** v3's
  text is a view.
- **The eight rules of MODEL.md,** among them: a waker holds a
  reference across its wake, a retraction wakes its worker, `ren_stop`
  notifies every live task, only `deliver` frees an op.
- **The interpreter is the reference;** journals equal under `sim` is
  the conformance test.
- **Nothing emitted holds a program-wide number.**

## Final report

End with: per step, what was built, the commits, and the choices you
made where the spec was silent; whether each "Done when" holds, with
the numbers and the commands; which drivers ran on which OS; what's
unfinished or unsound, with its severity; and which checks couldn't
run.

---

## Later parts (outline only)

**Part two, many cores.** `per_core` with home cores, the hybrid take
and its three rules, shipping `at` and moving the task for long blocks,
the inbound drain at every point, the 5 µs spin; `work_stealing` with
parking and the 1 ms handoff; `pinned`; the shared mark switched on,
atomic counts, per-thread heaps with frees returned home; io_uring and
the second real driver; `striped` and `actors` on many cores; the
stall watchdog's report. Phase two of the experiments on the real
runtime; a journal recorded on many cores replays on one; a server
benchmark against Go and Rust.

**Part three, memory that tasks share.** Arenas, `with Mem.arena()`,
sealed when shared, with copy-in; `Mem.snapshot` and its reclamation;
lock-free handlers with `Atomic` fields.

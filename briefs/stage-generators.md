# Brief: the generators stage (11c, part one)

You're building generators and pipelines: `gen fn`, `yield`, chains
over cursors as blocks, the default set of stages, "ends once", and the
two stream combinators `Async.merge` and `Async.expand`. The design is
[streams.md](../streams.md), placed in Ren's concurrency model by
[concurrency.md](../concurrency.md). It's part one of foundations.md
Staging item 9. Part two, a generator that uses a dependency pulled
natively (its suspended frame), and `produce`, `merge` and `expand`
natively, waits for the runtime core, because it needs the core's task
frames.

Ren is a systems language whose compiler is written in OCaml. Work on
`main`. This brief is self-contained: it names everything you need in
the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**This stage can start now.** Other sessions are on `main` at the same
time; see "Working beside the other stages".

## The line between part one and part two

**A pushed generator needs no frame of its own.** A chain whose head is
a `gen fn` call and whose consumer is a `for` or a built-in sink is
compiled with the generator's body folded in where it yields, and its
`finally` runs as an ordinary unwind (streams.md, "Pushed when it can
be"). That's sequential code, so it builds natively today, even when
the generator uses a dependency. **A pure generator's frame is data,**
a record of values, so a value cursor builds natively today too.

Only a generator that uses a dependency **and is pulled** (by `zip`, by
a pipeline passed to a function, by stepping it by hand) needs a frame
that suspends across a dependency call. That's part two. Until then
`ren build` refuses it as it refuses `Async.scope` today, with an error
that says it waits for the runtime core.

## Read first

- **streams.md**, all of it. It's the spec: the seven rules, cursors,
  pipelines, `gen fn`, stopping, errors, concurrency and time, the
  default set, cost, the compiler errors, the programs.
- **concurrency.md**: "The rule", "Ends once", "The tree side" and
  "Streams: calls that answer many times". A stream is a call that
  answers many times, and every test you write of a generator's end is
  a test of the tree: cancellation down, errors up, returned means done.
- **channels.md**: the contracts under `produce`, `merge` and `expand`;
  this stage keeps the ones in "From channels.md", below.
- **research/streams/experiments/e2-prototype.md** and
  **e2/prototype.diff**: a working spike of rules 1 to 4 in the
  interpreter (one-shot fibers for effectful generators, a replay
  cursor for pure ones, chains rewritten into ordinary Ren). It
  recognizes chains by spelling, not by type, and lists its shortcuts
  and the four places the design doesn't simply fall out. Use it as a
  map, not as code to paste.
- **research/streams/scope-end/README.md** and **scope-end.diff**:
  rule 5 in 23 lines, closing a named frame at its scope's end through
  Core's `Finally`, and the contained-panic fix it needed.
- **research/streams/experiments/synthesis.md** and **e3**,
  **e4-composition.md**: the cost models behind streams.md's "Cost"
  table, and how they were measured.
- **foundations.md**: decisions 1 (blocks), 2 (exclusivity), 5
  (dependencies found where a block is written), 7 (the combinators),
  12 (frames and generators), 13 (two builds; depth limits), 17
  (slices), 20 (the language/std boundary; rule 4, optimizations are
  invisible).
- **compiler.md**: the 10c, 10d and 11a sections (blocks, descriptions,
  tasks), and how `for` over a cursor is lowered today in
  lib/lower/lower.ml and natively.
- **async.md**, "The whole surface": `produce`, `map_pull`, `each` and
  `map` over any pull argument, as built in 11a; `merge` and `expand`
  as designed.
- **bench/native/README.md** for how to measure.

## Scope

**In:**

1. **`gen fn`, `yield`, `yield from`** (streams.md, "Producers"), in
   the lexer, parser, checker and interpreter, with tree-sitter's
   grammar and corpus and Zed's highlights.
2. **Rule 2, data or block, read from the inferred `uses` row:** a
   call is a value cursor when its parameters are data and its frame
   holds no instance across a `yield` (no dependency in its inferred
   row, no `with` open, no `inout`); otherwise it's a block whose frame
   is a hidden local of the caller. A value cursor's type is
   `walk.Cursor`.
3. **Pipelines as blocks** (streams.md, "Code: pipelines"): a chain
   over a cursor is a block the compiler writes where the chain is;
   `&r.map(f)` on a named head; `let`-bound pipelines; passing one to
   a block parameter. **Chains are recognized by type,** not spelling
   (streams.md, "Open"), and messages never name hidden locals. A line
   that begins with `.`, indented further, continues the line above.
4. **The default set** (streams.md, "The standard library"),
   transforming, shaping and consuming, on every cursor; the receiver
   decides eager or lazy; stage names reserved on types with a `next`;
   `merge_by`, `scan` and `dedup_by` written as `gen fn` stages.
5. **Stopping** (rule 5): a frame's `finally(r)` runs at its binding's
   scope end by any exit; `Ok`, `Err(e)` or `Err(Cancelled)`;
   abandonment is a cancel; never stepped means never run.
6. **Ends once** (concurrency.md): a generator keeps how it ended, and
   every later step says so, per the table: `None`, the same `e` again,
   or a panic after a cancel.
7. **Errors** (streams.md, "Errors"): `for x in try src`; a stage's
   failure flows into the step and the `for`'s error names the stage;
   every compiler error in streams.md's "Compiler errors", with its
   help.
8. **`Async.merge(a, b, ..., cap:) fn(items) => ...`** and
   **`Async.expand(roots, max:) fn(x) => children`**, in the
   interpreter, written in std over `scope` and the queue `produce`
   already uses. `merge`'s sources are separate arguments; a run-time
   list of sources is data. `expand` doesn't dedupe. Both follow
   channels.md's contracts ("From channels.md", below).
9. **Natively:**
   - a pure generator's frame as a value: a value cursor that copies
     as data;
   - push lowering of a chain headed by a `gen fn`, into a `for` or a
     built-in sink, including generators that use dependencies,
     `break` and `return` leaving through a control value, `finally`
     as an unwind;
   - pull of a pure generator and of the built-in stages;
   - recursive `yield from` on one frame stack the consumer owns,
     never boxing a child frame, with a recursive call's depth limit
     pushed or pulled;
   - each `&` held across a `yield` re-checking uniqueness on resume.
10. **Resources as families, proved on `Fs`** (concurrency.md,
    "Streams"; streams.md rule 6), in the interpreter, under `real_fs`
    and `mem_fs`:
    - `Fs.line_reader(p)`, a reader that's data: an id, its
      incarnation and an offset, read with `pread`;
    - `Fs`'s open files as a family keyed by id, its cap as `max:`;
    - a reader whose file was evicted reopens it (it holds the path);
      one whose `with` ended fails with a typed `Closed`; a copy reads
      from where it was copied;
    - `Fs.lines(p)`, the use-here generator with a `finally`;
    - the family's end closes leftovers, so there's no handle table
      and no close rule.

**Out (don't start them):**

- **Part two:** a generator that uses a dependency, pulled natively;
  `produce`, `merge`, `expand` and `map_pull` natively. All wait for
  the runtime core.
- **Resources as families beyond `Fs`** (`Db`, `Net`, `Sql`): stage 12.
- **`stream.time`** (`batch(within:)`, `debounce`, `throttle`,
  `sample`): stage 12.
- **Everything in streams.md's "Later":** fusion through a user stage,
  `map(unordered: true)`, `broadcast`, a conflating channel, a dynamic
  N-way merge and an erased `Cursor<T>`, snapshotting pure frames.
- **`Net.frames`** and formats views over a stream: they need bytes
  part two and 7b part two.

## Working beside the other stages

The **runtime core** stage and **bytes part two**
(briefs/stage-bytes-2.md) may be on `main` at the same time, and the
services stage may be finishing.

- **Yours:** a new streams module in lib/syntax or lib/lower for chain
  recognition and the generator rewrite; `gen fn`, `yield` and `yield
  from` in the lexer, parser and AST; the classification of rule 2 in
  the checker; the interpreter's generator frames (fibers, replay
  cursors) in a new module beside eval.ml; the push lowering and pure
  frames natively; the default set in the prelude; `Async.merge` and
  `Async.expand` in std; `Fs.line_reader` and `Fs.lines`; tests and
  kernels you add.
- **Theirs, don't touch:**
  - the runtime core: everything under lib/native/runtime/ that's
    about tasks, the scheduler, drivers and the host ABI, task frames,
    and how tasks are lowered natively. If you need a frame that
    suspends, stop: that's part two;
  - bytes part two: ren_rt's string and byte code, `Str` and `Bytes`
    layout in to_mem.ml, emit_c.ml and Mem Lint, the interpreter's
    `VStr` and `VBytes`, the lexer's string literals;
  - services: lib/eval/sched.ml, lib/eval/family.ml, `actors`,
    `striped` and `sim` in std.
  `Async.merge` and `Async.expand` call `scope` and the queue through
  their existing interfaces; don't change sched.ml.
- **Shared files** (ast.ml, parser.ml, lower.ml, to_mem.ml, emit_c.ml,
  prelude.ml, std_lib.ml, builtins.ml, infer_*.ml, eval.ml): add your
  cases and constructors; don't move, rename or restructure code there.
  If you need a change that would, stop and say so in the progress log.
- **New tests go in new files.** Don't rewrite existing tests.
- **Rebase before every push.** If a conflict touches their work, keep
  theirs and redo yours on top. If a check goes red because of their
  commits, record it in the progress log and don't fix their work.

## Steps

Do them in order. After each step THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, baseline, tests first.** Add a "Generators stage" section to
   compiler.md. In it, settle:
   - **The AST** for `gen fn`, `yield`, `yield from`, and how a chain
     reaches Core: as the prototype did, a rewrite into ordinary Ren
     that resolve, inference, exclusivity and Core Lint check
     unchanged, or a Core node; say which and why.
   - **Chain recognition by type:** which receivers make a chain, how
     a stage name is told from a user's method (reserved names), and
     what the hover and errors say instead of hidden locals.
   - **Rule 2's classification** from the inferred row, and where in
     inference it runs, so a `gen fn` that declares no `uses` but calls
     `print` is a block.
   - **The frame** in each build: the interpreter's fiber and replay
     cursor; natively, a pure frame as a value and a pushed generator
     as an unwind. **The ends-once state** in each.
   - **Every compile error** this stage adds, with its help, worded
     from streams.md's.

   **Baseline:** bench/native/streams, the five workloads of
   streams.md's "Cost" table (map → select → take; a recursive tree
   walk; a user stage, `dedup_by`; `zip`; a pipeline passed to a
   function), written in Ren today as hand loops, with Rust and Go
   twins written as streams.md's columns were. Measured as bench/native
   measures, interleaved, medians and spread.

   **Tests,** marked skipped or expected to fail until their step:
   test/test_generators.ml with `until "g1"` ... `until "g5"`, and
   bench/generators.t (the interpreter, native debug, release under the
   sanitizers, tcc, `ren run --release`). At least:
   - every `finally(r)` outcome, by each exit (falling off, `break`,
     `return`, failure, cancel, a contained panic), on a temporary and
     on a named frame that resumes after `break`;
   - each row of the ends-once table, stepped again after it ended;
   - never stepped means never run (a transaction's `BEGIN` at the
     first step);
   - rule 2 both ways, including a declared row that's empty and an
     inferred one that isn't;
   - every compile error with its help;
   - two `&r` heads in one call; stepping the source between a
     pipeline's steps; lookahead lost after `break`;
   - a recursive `yield from` at its depth limit, pushed and pulled;
   - a copy of a value cursor as an honest fork;
   - `merge` and `expand` under `sim` across seeds: cancellation goes
     down to every producer, the first failure wins, the call returns
     only when its tasks have ended, and a journal replays;
   - channels.md's "Required composition cases" that part one can
     reach: a consumer exiting while its producer is blocked on a full
     queue; cancellation racing a send or a receive (exactly one
     outcome commits, nothing consumed twice or lost); close racing
     blocked senders and receivers; a producer failing with values
     buffered; one `merge` source failing while others are blocked; a
     named generator resumed after `break` and finalized at its
     binding's scope end; and an `expand` whose every worker returns
     children at once, which progresses and never waits to enqueue;
   - `Fs.line_reader` under `mem_fs`: resume after `break`, a copy,
     eviction under a small `max:`, `Closed` after the `with`.

1. **The front end and the interpreter.** Scope 1, 2, 5, 6 and 7 for
   `gen fn` without chains: lexer, parser, checker, the interpreter's
   frames (one-shot fibers for blocks, replay for value cursors), rule
   5 through Core's `Finally` as scope-end.diff did, ends once, the
   errors, the grammar and Zed.
   **Done when** g1 is on: every generator test runs in `ren run`.

2. **Pipelines and the default set.** Scope 3 and 4: chains by type,
   the continuation line, the default set, reserved stage names, eager
   and lazy receivers, an eager chain with no dependency compiled
   through the same composed block so it allocates no arrays.
   **Done when** g2 is on, and the `just`'s tests pass unchanged.

3. **`merge` and `expand`.** Scope 8, in the interpreter, over `scope`
   and the queue.
   **Done when** g3 is on: the tree tests above pass under `sim` across
   a thousand seeds, and a recorded run replays.

4. **Natively.** Scope 9: pure frames as values, push lowering, pull of
   pure generators and built-in stages, recursion on one frame stack;
   `ren build` refusing a pulled generator that uses a dependency, with
   its error. Mem Lint and the sanitizers over all of it.
   **Done when** g4 is on; `ren run` and every native build agree on
   every test; and the five workloads match the cost the C models
   predicted, within 10% of the hand loop where streams.md's table
   says push or composed pull equals it (1.01, 0.97, 1.01, 1.07 or
   1.17 for `zip`, 1.02), with any shortfall explained with numbers and
   Rust's and Go's columns beside it.

5. **Resources as families, on `Fs`, and the programs.** Scope 10, then
   streams.md's programs: "Tail a log, and resume after a marker" over
   `Fs.line_reader`, and "Rows in a transaction" over a `Sql` fake
   written in Ren in the test. "Frames, with errors at stream offsets"
   runs if `Net.frames` and byte cursors are on `main`; otherwise say
   it waits.
   **Done when** g5 is on, and both programs run in `ren run`, and
   natively where they're pushed.

6. **Review your own work** with three lenses:
   - **Soundness:** exclusivity across steps and across a `yield`, the
     uniqueness re-check on resume, a frame that outlives what it
     captured, ends once in both builds, Mem Lint and the sanitizers.
   - **The spec and the tree:** does it match streams.md's seven rules
     and concurrency.md's, and does each "Done when" hold? Is every
     generator's end a call's end?
   - **Docs and tooling:** README's status and roadmap row, compiler.md,
     stdlib.md's "what's built" table, the grammar.
   Fix what blocks; list the rest with its severity.

## From channels.md

[channels.md](../channels.md) states the contracts the queues under
`produce`, `merge` and `expand` keep. Its obligations for this stage:

- **Admission has one commit point.** A send cancelled before it has no
  effect; after it, the queue owns the value, and the combinator
  releases what's never consumed. The same for a receive: cancelled
  before it commits, it consumes nothing.
- **Terminal state is kept apart from the buffer.** Ending, failing or
  being cancelled never needs room in a full queue, and teardown never
  needs the departed consumer to make room.
- **`merge`'s failure order is `produce`'s:** the first producer failure
  the scheduler records cancels the other producers; values already
  admitted are consumed, then the source ends with that failure. A
  sibling's send racing the cancel counts only if it committed. If the
  consumer exits first, the remaining values are abandoned and the
  producers awaited, not drained. No global order across sources is
  promised.
- **`expand`'s frontier** (decided; record it in compiler.md):
  - a worker's block returns its children as a value, and the call
    appends them to its frontier: appending isn't a wait, so no worker
    ever blocks enqueueing children, and saturation can't deadlock;
  - the frontier is a stack, depth first, so it holds about depth ×
    branching items, not a whole level;
  - it's done when nothing is running and the frontier is empty;
  - its memory is the program's own, the arrays its blocks returned;
    there's no `pending:` bound, and nothing is ever dropped.
- **Name each bound for what it bounds:** `cap:` buffered values, `max:`
  running workers, `mailbox:` queued calls per key.

Where channels.md is a proposal beyond this (general channel close
rules, selection, endpoint capabilities), it isn't this stage's: don't
build it.

## The interpreter and native

The interpreter is the meaning; push lowering and pure frames are
invisible (decision 20, rule 4). What must agree, and
bench/generators.t checks in every build: every item and its order,
every `finally(r)` and when it runs, every ends-once answer, every
error and panic, and the depth limit.

## Risks

- **Chain recognition by type** is the step the prototype skipped.
  Reserved stage names collide with user methods; test a user type
  that defines `map` without a `next`, and one that tries to with.
- **Rule 2 at the wrong time.** Classifying before the row is inferred
  makes a hidden `print` a value cursor. Test it.
- **Copying by replay is quadratic** for a backtracking consumer; fine
  for this stage, but say so in compiler.md and measure one case.
- **Push and pull must mean the same,** down to when `finally` runs and
  the depth limit. The differential tests are the guard.
- **Code size.** Push lowering inlines; report the emitted C's size for
  the five workloads and the just, before and after.

## THE CHECKS

All must pass before any commit:

- `dune build`
- `dune test --force`, with `REN_TCC` set (tools/tcc.sh), or bench/*.t
  are skipped
- `make -C editors/tree-sitter-ren check`
- `_build/default/bin/main.exe test` inside each of examples/bank,
  examples/prices, examples/just, examples/ledger, examples/crawler,
  examples/refresh, examples/server and examples/transfer

Setup, portability and flakes are as the bytes stage's brief says
(briefs/stage-bytes.md, "THE CHECKS"): journal.t's timing tests flake
under load; rerun and report, never loosen. **Never weaken or delete a
test to get green.**

**Measuring.** Name the machine. Ren and its twins interleaved, medians
and spread, every number in bench/native/RESULTS.md with the commands
that reproduce it. streams.md's numbers are C models on an M4 Max:
compare your results to your own baseline and to its ratios, not its
nanoseconds.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results
  untrustworthy. Note others in your final report.
- **Do NOT edit foundations.md, language.md, streams.md or
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

- **A stream is a call that answers many times,** owned by the scope
  that binds it; generators add nothing to the runtime.
- **Rule 2 from the inferred row:** pure frames are data, the rest are
  blocks.
- **Every computation ends once;** a generator's every later step says
  how it ended.
- **Push when it can be,** never boxing a child frame; one depth limit
  for pushed and pulled.
- **`merge` takes its sources as arguments** and runs a producer per
  source into one bounded queue; **`expand` doesn't dedupe** (a crawler
  keeps a `Seen` handler).
- **`expand`'s frontier is the call's own stack of returned children,**
  depth first, never a wait; **`merge` consumes what was admitted before
  it reports the first failure** ("From channels.md").
- **Resources are families;** proved on `Fs` here, the rest of std in
  stage 12.
- **No comprehension syntax, no async iterator, no affine cursors, no
  `Emit` dependency, no stream error operators** (streams.md, "Left
  out").

## Final report

End with: per step, what was built, the commits, and the choices you
made where the spec was silent; whether each "Done when" holds, with
the numbers before and after, the twins' numbers, and the commands;
code size before and after; what's unfinished or unsound, with its
severity; and which checks couldn't run.

# Brief: the generators stage, part two (11c, pulled and native)

You're finishing generators natively: a generator that uses a
dependency and is pulled, its frame suspending across a dependency call
on the runtime core; `merge`, `expand` and `map_pull` natively; `Fs`'s
resources as families natively; and the cost table measured on Ren's own
output. Part one (briefs/stage-generators.md) built the language, the
interpreter, push lowering and pure frames, and refused the rest in
`ren build` with an error saying it waits for the runtime core. This
part removes that refusal.

Ren is a systems language whose compiler is written in OCaml. Work on
`main`. This brief is self-contained: it names everything you need in
the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**This stage starts when generators part one and runtime core part one
have both landed.** Check their final reports in compiler.md first.

## What changes from part one

**A pulled generator's frame is a frame like any other,** on the
runtime core's terms (runtime.md, "How code meets the core: frames"):

- **Its frame is a hidden local of its consumer's.** It lives in the
  consumer's frame, and a step is a call of its resume function with the
  consumer's task, so a step that waits for a dependency call parks the
  consumer's task, and the reply resumes the generator's frame, then
  the consumer's.
- **A pulled recursive generator gets a frame stack of its own,** so
  `zip` over two recursive walks can't interleave their frames. Child
  frames are never boxed.
- **A step that can wait is coloured;** colour is part of the
  generator's interface, as for any function (module-build.md,
  "Incremental by construction").
- **Stopping, ends once and the depth limit mean what they mean in the
  interpreter.** A cancel that lands while a step waits ends the
  generator (streams.md rule 7); its `finally` runs at its binding's
  scope end with `Err(Cancelled)`, shielded under the deadline.

## Read first

- **briefs/stage-generators.md**, and part one's section and progress
  log in compiler.md ("Generators stage"): what's built, the choices
  made where the spec was silent, and what was left.
- **briefs/stage-runtime-core.md**, and its section and progress log in
  compiler.md ("Runtime core stage"): the core's verbs, the frame
  convention, the conformance harness, and what was left.
- **streams.md**, all of it, and especially "Pushed when it can be",
  "Stopping", "Concurrency and time", "Cost" and "Programs".
- **runtime.md**: "Scheduling points and colours", "How code meets the
  core: frames", "The call record".
- **concurrency.md**: "Ends once", "Streams: calls that answer many
  times"; **channels.md**: admission, terminal state, and its
  composition cases.
- **module-build.md**, "Incremental by construction".
- **bench/native/README.md** and part one's bench/native/streams.

## Scope

**In:**

1. **Pulled generators that use a dependency, natively:** by `zip`, by
   a pipeline passed to a function, by stepping by hand; their frames on
   the consumer's frame, steps that wait, the cancel walk reaching a
   waiting step, `finally` at the binding's scope end, ends once, each
   `&` held across a `yield` re-checked on resume. `ren build`'s refusal
   from part one goes, and so does its error.
2. **Recursive pulled generators on a frame stack of their own,**
   natively, with a recursive call's depth limit, and `zip` over two of
   them.
3. **`merge`, `expand` and `map_pull` natively,** std's Ren over the
   core's verbs, as part one wrote them for the interpreter, keeping
   channels.md's contracts: one commit point per send and receive,
   terminal state apart from the buffer, `merge`'s failure order,
   `expand`'s frontier. (`produce` is the runtime core's, part one.)
4. **`Fs`'s resources as families, natively:** `Fs.line_reader`,
   `Fs.lines`, eviction and reopening, `Closed` after the `with`, the
   family's end closing leftovers.
5. **The programs natively:** streams.md's "Tail a log, and resume
   after a marker" and "Rows in a transaction"; "Frames, with errors at
   stream offsets" if `Net.frames` and byte cursors are on `main`.
6. **The cost table on Ren's own output:** streams.md's five workloads
   pushed and pulled, natively in release, plus the effectful cases
   part one couldn't build: `zip` over two generators that use a
   dependency, and a pulled recursive walk that reads a file.

**Out (don't start them):**

- `stream.time` (`batch(within:)`, `debounce`, `throttle`, `sample`)
  and resources beyond `Fs` (`Db`, `Net`, `Sql`): stage 12.
- Many cores: generators stay on the consumer's task, so nothing here
  needs them; runtime core part two may be on `main` at the same time.
- Everything in streams.md's "Later".

## Working beside the other stages

**Runtime core part two** (many cores) and **stage 12a** (the shape
machinery) may be on `main` at the same time.

- **Yours:** the native lowering of pulled generators (frames as hidden
  locals, their own frame stacks, resume functions for steps), the
  removal of part one's refusal, `merge`, `expand` and `map_pull`
  natively, `Fs`'s resources natively, bench/native/streams, tests you
  add.
- **Theirs, don't touch:**
  - runtime core part two: the schedulers beyond `single` and `sim`,
    the shared mark and atomic counts, per-thread heaps, io_uring, home
    cores. Use the core's verbs as part one left them; if you need a
    new verb, stop and say so in the progress log;
  - stage 12a: top-level and signature `let`, shapes, looks, the
    doors, templates, the prelude's contents, std's `json`, `cli` and
    `shape`.
- **Shared files** (lower.ml, to_mem.ml, emit_c.ml, specialize.ml,
  prelude.ml, std_lib.ml): add your cases; don't move, rename or
  restructure code there.
- **New tests go in new files.** Don't rewrite existing tests.
- **Rebase before every push.** If a conflict touches their work, keep
  theirs and redo yours on top.

## Steps

Do them in order. After each step THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, baseline, tests first.** Add a "Generators stage, part two"
   section to compiler.md. In it, settle:
   - **A pulled frame's layout:** where it sits in the consumer's
     frame, what its resume function takes and returns under the core's
     convention, and how a step's wait resumes it and then the consumer.
   - **A recursive generator's frame stack:** who owns it, when it's
     made and freed, and how the depth limit is checked against a
     recursive call's.
   - **Cancel and stopping:** what the cancel walk does to a waiting
     step, where `finally` runs, and the ends-once state in the frame.
   - **Exclusivity across a suspended step:** the uniqueness re-check
     on resume when the step waited.

   **Baseline:** part one's bench/native/streams numbers, re-run on this
   machine, and the interpreter's times for every generator test under
   `--sim --seeds 1000`.

   **Tests,** marked skipped or expected to fail until their step:
   test/test_generators_2.ml with `until "p1"` ... `until "p5"`, and
   bench/generators_2.t (native debug, release, the sanitizers, tcc).
   Every native test is also run through the runtime core's conformance
   harness: the same journal as the interpreter under `sim`, byte for
   byte. At least:
   - every test of part one's that `ren build` refused, now natively;
   - a step cancelled while it waits, by `Async.timeout` and by a
     sibling's failure: the generator ends, its `finally` sees
     `Err(Cancelled)`, a later step panics as ends once says;
   - `zip` over two generators that each wait, and over two recursive
     walks, neither interleaving the other's frames;
   - a recursive pulled walk at its depth limit, equal to the pushed
     one's;
   - a `&` held across a waiting step, with the re-check on resume;
   - channels.md's composition cases natively, as part one ran them in
     the interpreter;
   - `Fs.line_reader` natively: resume after `break`, a copy, eviction
     under a small `max:`, `Closed` after the `with`.

1. **Pulled generators that use a dependency.** Scope 1.
   **Done when** p1 is on: every generator test runs natively, with
   journals equal to the interpreter's across a thousand seeds, and
   `ren build` refuses no generator.

2. **Recursion on its own frame stack.** Scope 2.
   **Done when** p2 is on, and the recursive walk pulled costs within
   10% of the hand loop, as streams.md's table predicts (1.03), with no
   frame boxed.

3. **`merge`, `expand` and `map_pull` natively.** Scope 3.
   **Done when** p3 is on: the tree tests and channels.md's cases pass
   natively across a thousand seeds with equal journals, and a recorded
   run replays in either build.

4. **Resources on `Fs`, and the programs.** Scope 4 and 5.
   **Done when** p4 is on, and both programs run natively, with their
   tests passing against the native build.

5. **The cost table.** Scope 6, against the C models' ratios and part
   one's baseline, with Rust's and Go's columns beside them.
   **Done when** p5 is on, and every workload is within 10% of the hand
   loop where streams.md's table says push or composed pull equals it,
   or the gap is explained with numbers.

6. **Review your own work** with three lenses:
   - **Soundness:** frames that outlive what they captured, the
     re-check on resume, ends once in both builds, the cancel race at a
     waiting step, Mem Lint and the sanitizers.
   - **The spec and the tree:** streams.md's seven rules natively, and
     every generator's end a call's end.
   - **Docs and tooling:** README's status and roadmap row, compiler.md,
     streams.md's "Cost" numbers (the measured ones beside the models'),
     stdlib.md's "what's built" table.
   Fix what blocks; list the rest with its severity.

## The interpreter and native

The interpreter is the meaning. What must agree, and the conformance
harness checks: every item and its order, every `finally(r)` and when
it runs, every ends-once answer, every error and panic, the depth
limit, and every journal under `sim` for the same seed.

## Risks

- **Two frame stacks for one task.** A recursive generator's stack and
  its consumer's must never be confused at a wait: the core resumes the
  innermost frame, and that frame may be on either. Test a wait inside
  a recursive step inside a `zip`.
- **The re-check on resume** is the soundness edge; a step that waited
  is where another task may have changed what a `&` pointed at.
- **Cost.** A pulled step that waits is the expensive path; one that
  doesn't must be as cheap as part one's pure pull. Measure both.

## THE CHECKS

As in briefs/stage-runtime-core.md, "THE CHECKS", including its edit
test from its step 7 on. **Never weaken or delete a test to get
green.**

**Measuring.** Name the machine and its load. Interleave, report
medians and spread, and put every number in bench/native/RESULTS.md
with the commands that reproduce it.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results
  untrustworthy. Note others in your final report.
- **Do NOT edit foundations.md, language.md, streams.md,
  concurrency.md, runtime.md or channels.md,** except streams.md's
  "Cost" numbers in step 6. If they're wrong or underspecified, make a
  choice, record it in compiler.md's section, and list it in your
  final report.
- **Committing:** on main, explicit `git add` paths, never `git add
  -A`; never the root `dune` file's local changes, prior-art.md, or
  anything under .claude/; every message ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push after
  each green step.
- **Keep a progress log** at the end of compiler.md's section.

## Decided

Record these in the spec; don't reopen them.

- **A pulled generator's frame is a hidden local of its consumer's; a
  pulled recursive generator has a frame stack of its own; child frames
  are never boxed.**
- **Generators stay on the consumer's task;** they add nothing to the
  runtime but frames.
- **One depth limit, pushed or pulled.**
- **channels.md's contracts** under `merge`, `expand` and `map_pull`,
  as part one decided them.
- **The interpreter is the reference;** journals equal under `sim`.

## Final report

End with: per step, what was built, the commits, and the choices you
made where the spec was silent; whether each "Done when" holds, with
the numbers before and after, the twins' numbers, and the commands;
what's unfinished or unsound, with its severity; and which checks
couldn't run.

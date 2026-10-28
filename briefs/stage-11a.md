# Brief: stage 11a, tasks

You're building stage 11a of Ren: structured tasks, the runtime as a
handler with `single` and `sim`, handler operations that don't
interleave, and a thin `Net`. Ren is a systems language whose compiler
is written in OCaml. Work on `main`. This brief is self-contained: it
names everything you need in the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

## Read first

- **foundations.md** is the signed-off design. Decisions 2 (rules B to
  D), 7 (structured tasks), 8 (`isolate`), 9 (the runtime is a handler),
  10 (only "Handler operations don't interleave" and the parts on
  marking that 11a needs), 11 (determinism), and Staging item 4, which
  is this stage's scope. "What it reverses" lists what changed from the
  older docs. Build these as written. If something is unsound or can't
  be built, stop and say so instead of inventing a different design.
- **async.md** came before foundations.md. Where they disagree,
  foundations.md wins (see "What it reverses"). Still useful in async.md:
  cancellation, the five programs, "Done when", and the error texts.
- **README.md**: the 11a row of the roadmap and its milestone; and
  "Dependencies", whose race passage (around "A handler's state is
  exclusive between dependency calls") is stale.
- **handlers.md, deps.md, testing.md, runtime-io.md**: what's built
  today, and the journal (10b).
- **compiler.md**: the 10c and 10d sections show how a stage is
  specified and then built. Follow that shape.
- foundations.md cites `research/*.md` files that aren't in the repo.
  You don't need them: the decisions record what they found.

## Decisions made after foundations.md (don't reopen)

These are already in foundations.md and the README. They're repeated
here because they're new:

1. **The milestone:** a server shuts down gracefully, and
   `ren test --sim --seeds` finds a **lost update between two
   operations** (a caller reads with one operation, another task runs,
   the caller writes with a second) and replays it by seed. The README's
   old `cached` race can't happen any more: an operation keeps its
   instance across its own calls to `next`. **Drop** async.md's warning
   about state read before a dependency call and written after it.
2. **A handler has no task of its own.** async.md's `task =>` in a
   handler is gone. Background work is a task spawned beside the `with`
   that calls one of the handler's operations, and the scope cancels it
   when the body ends. Rewrite async.md's `batched` example that way.
3. **`Async.scope(max: n)`:** `spawn` waits while `n` of the scope's
   tasks are running. The default is 64, as `Async.map`'s is.
   `Async.group` is gone.
4. **`Net` is a super-thin TCP layer:** `listen`, `accept` (and
   `accept_until`, for shutdown), `read`, `write` and `close`, with a
   real implementation and an in-memory `sim.net` for tests. No HTTP, no
   DNS, no TLS, and no failing networks (the rest of the simulator comes
   later).
5. **Defaults:**
   - The cleanup deadline is 5 s, fixed for now.
   - `Async.map`, `each`, `both` and `timeout` stay.
   - `limit` is Ren code: an `over any` handler using `Async.until`.
   - Journals become version 2, with a task path column. Re-record the
     existing journals (examples/just/tests/build.journal), and make
     replaying a version-1 journal an error with a help line.
6. **Earlier decisions:**
   - Handler operations don't interleave: an operation keeps its
     instance until it returns, or until it waits in `Async.until`.
   - `race`'s branches can't fail; the help line suggests `attempt`.
   - A `with` whose setup or `finally` can fail is written `try with`.
   - Keyed handlers are a library: `keyed(n, h) over any`.
   - There's no preemption, and no `par_map`: `Async.map` over a block
     with no dependencies may run on every core (in 11a, one core is
     fine).
   - Two spec holes to close: `s.spawn` carries `Async` in its caller's
     row; and no code reached from a call with an empty row runs a
     scheduling point.

## Interpreter first, natively where sequential

- Tasks run in the interpreter (`ren run`, `ren test`) on OCaml 5
  effects: a scheduler of your own, with fibers as effect
  continuations.
  - `Async.single()` is the real runtime: one thread, real time, real
    I/O through `Unix` (`select` or `poll`). Don't add a dependency
    unless it clearly pays; Eio is allowed if it does.
  - `sim.scheduler(seed)` is deterministic: virtual time, choices drawn
    from a seeded tape at dependency calls. `ren test` uses it.
    `ren test --seeds N` and `--seed S` work.
- The sequential parts build natively too, in debug and release:
  - `try with`, `keyed` and `Async.until` with no other task, if cheap;
  - the `limit` handler, if it needs no tasks.
- A native build of a program that spawns says, in an error with a help
  line, that tasks aren't native yet.
- The interpreter and native builds must agree on everything both run.
  Add cases to bench/build.t for the sequential parts.

## Steps

Do them in order. After each step, THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, tests first.** Add a "Stage 11a" section to compiler.md that
   settles every detail the later steps need. Then rewrite async.md to
   match foundations.md and the decisions above, and fix the stale
   README race passage. Then write the test programs, marked skipped or
   expected to fail until the step that builds them (as 10c and 10d
   did):
   - the five async.md programs as examples/ with tests;
   - the error messages, each a one-line refusal test;
   - the lost-update program for the milestone.
1. **Rules B to D, `try with`, and the two spec holes.** These are
   checker work, and `try with` is built natively too.
2. **`Async.scope(max:)`, `spawn` and its handle (cancel, join),
   `s.replace(key)`.** Also cancellation at dependency calls, as
   async.md specifies: it can't be caught; only `finally` sees it, as
   `Err(Cancelled)`; it's shielded; and the cleanup deadline applies. A
   failure cancels a task's siblings, and the first failure wins. Errors
   and panics show the task path.
3. **The rest of `Async`:** `until`, `tick`, `yield`, `timeout`
   (deadlines carry down; it never reports `Timeout` for work that
   finished), `race`, `isolate`, `map`, `each` and `both`.
4. **Operations that don't interleave.** Callers queue for an instance
   that's in use. `Async.until` inside an operation lets go of the
   instance and waits. The exclusion is skipped for instances no spawned
   task can reach.
5. **`single` and `sim` as handlers** (`with Async.single() in`,
   `with sim.scheduler(seed) in`), virtual time for `Clock` under `sim`,
   `ren test --seeds/--seed`. A test that sleeps for an hour of virtual
   time finishes in milliseconds.
6. **Journal version 2:**
   - task paths (`main/accept:7/handle:0`);
   - answers keyed by task;
   - poll points;
   - a journal as a test with a schedule prefix: replay follows the
     recorded order while it can, then the seeded tape takes over;
   - `ren replay` byte for byte for the concurrent `just`.
7. **`Net` and `sim.net`,** and the graceful-shutdown server example:
   `accept_until(Signal.term)`, then in-flight connections finish under
   the cleanup deadline.
8. **The standard library, in Ren where it can be:**
   - channel (bounded, a send that waits when full);
   - semaphore;
   - `Batcher`;
   - `keyed(n, h) over any`;
   - `limit(n) over any`.
   Then finish the five programs and the milestone, and the `just`
   running independent recipes at once (killing the rest when one
   fails).
9. **Review your own work** with three lenses:
   - **Soundness:** adversarial programs for cancellation, `finally`,
     the queueing of operations, `race`, `timeout`, `isolate`, rules B
     to D, and seeds that must replay identically.
   - **The spec:** does it match foundations.md, does the README's
     milestone hold, and does async.md's "Done when" hold (as amended
     above)?
   - **Docs and tooling:** async.md, handlers.md, deps.md, testing.md,
     README, compiler.md, the grammar and corpus, Zed queries.
   Fix what blocks; list the rest with its severity.

## Language changes go through the whole pipeline

Every language change goes through:
- the lexer and parser;
- types and Core;
- the interpreter;
- native, where sequential;
- the tree-sitter grammar and its corpus (`editors/tree-sitter-ren`);
- Zed queries (`editors/zed`);
- error messages with help lines;
- the docs that describe it.

Grammar and editor support is first-class: don't hack it in.

## THE CHECKS

All must pass before any commit:

- `dune build`
- `dune test --force` (includes bench/build.t's sanitizer and tcc
  builds)
- `make -C editors/tree-sitter-ren check`
- `_build/default/bin/main.exe test` inside each of examples/bank,
  examples/prices, examples/just and examples/ledger, and in each new
  example

**Setup:**
- OCaml 5.x with opam: `opam install dune ppx_deriving ppx_expect`.
- clang, with AddressSanitizer and UBSan.
- node and npm, for tree-sitter.
- python3.
- tcc: `tools/tcc.sh`. It was measured on arm64 macOS; if it won't
  build here, say so.

The repo was developed on macOS. If a check fails at the start before
you change anything, fix it when it's a portability bug in the repo
(and say so). Otherwise record exactly which checks you couldn't run.
**Never weaken or delete a test to get green.**

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results untrustworthy.
  Note others in your final report.
- **Do NOT edit foundations.md.** If it's wrong or underspecified, make
  a choice, record it in compiler.md's 11a section, and list it in your
  final report.
- **Committing:**
  - Commit on main with explicit `git add` paths, never `git add -A`.
  - Never commit the root `dune` file's local changes, prior-art.md, or
    anything under .claude/.
  - End every commit message with
    `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Push to main after each green step. If you can't push to main, push
    a branch named `stage-11a` and say so.
- **Keep a progress log** at the end of compiler.md's 11a section
  (step, commit, what's done, what's left), so a resumed session can
  pick up where it stopped.

## Final report

End with:
- **Per step:** what was built, the commits, and the choices you made
  where the spec was silent.
- **Whether the milestone holds,** with the commands that show it.
- **What's unfinished or unsound,** with its severity.
- **Which checks couldn't run** in this environment.

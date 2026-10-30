# Brief: the services stage

You're building the services stage of Ren (foundations.md Staging item
6, "Services and concurrency"): wirings and the pipe, the follow-ups
11a left, the parts of streams.md that need tasks but not generators,
and `striped` and `actors`, the two standard-library services that let
a program keep many stateful things. Ren is a systems language whose
compiler is written in OCaml. Work on `main`. This brief is
self-contained: it names everything you need in the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**Start once the data stage is merged to `main`** (briefs/stage-data.md).
It changes the parser, the type checker, patterns and every variant
with several fields; this stage changes the parser too (`|>`, `wiring`,
`release`), and its new Ren code uses the data stage's forms. If it
isn't merged when you start, stop and say so.

## Goal

A server written the way language.md says: a composition root named
as a wiring, workflows as pipes with a `try` on each failing step,
background work that can't outlive its handler, and documents held as
actors, one per key, evicted under a cap, all tested deterministically
under `sim`, with chaos eviction finding what lives only in memory and
seeds finding a lost update split over two operations of one actor.

## Read first

- **foundations.md**: Staging item 6 is this stage's scope and its
  "Done when"; item 4 lists 11a's follow-ups. Decision 7 (the compile
  error for a task that reaches a handler installed inside its scope,
  `Async.beside`, `Async.background`, a background failure cancelling
  the body), decision 10 ("`release` lets go for one call", "No
  deadlock waiting for an instance", "Hot state is striped or split
  by key"), decision 11 (the journal and the tape), and **decision 18,
  all of it**: most of this stage. Decision 2's table, whose
  handler-state row is narrowed to `Async.until`, `release` and
  block-parameter calls (research/decision-11/ has the model that
  checked it).
- **language.md**: §4 (services), **§5 (wirings, all of it)**, **§8
  (the pipe, all of it, with its grammar and errors)**, **§11 (data
  or actors, the document server, stripes, policies as data)**, "A
  program, end to end", and §2's "Calls have one by-name form" (a
  parameter with a default is given by name). Build these as written.
  If something is unsound or can't be built, stop and say so instead of
  inventing a different design.
- **streams.md**, "Concurrency and time" (`Async.each` and `Async.map`
  over pull arguments, `Async.produce` with `Send<T>`, channels as
  dependencies with `items()`), "Seven rules" (rule 3, pull
  parameters; rule 7, waiting is an operation), "Open" and "What it
  changes" (the async.md row). Read it; don't edit it.
- **async.md**: "The whole surface", "Shared state is a handler",
  "What tasks share: `sync`", "Background work is a task beside the
  `with`" (the rule 11a built, which this stage replaces).
- **compiler.md**: "Stage 11a", especially "Where 11a may differ from
  foundations.md", "Step 8, as built" (how `keyed` is built in, which
  `striped` replaces and `actors` follows), "Step 9, as built" and the
  11a progress log's notes; "Parameters with defaults" (step 1 of 11a);
  and the data stage's section, which shows how a stage is specified
  and built.
- **README.md**, the "services" row of the roadmap; **testing.md**,
  "A test's tasks run on `sim`" and "The journal is a test".
- Code you'll live in: lib/eval/sched.ml (the scheduler, `sim`'s tape,
  instance queues), lib/eval/eval.ml (`Dep_call`, `With`, `VKeyed`),
  lib/core/std_lib.ml (`sync`, `sim`), lib/core/prelude.ml (`Async`,
  `Proc`), lib/eval/journal.ml, the exclusivity pass (excl.ml), and
  lexer.ml's `continues()`.

## What's decided

Each is decided; cite it in the spec, don't re-argue it.

1. **Wirings** (language.md §5, "The rules" and "Errors"): `[pub]
   wiring name(params) provides Ds [uses Ds] [! Es] = items`, flattened
   where it's used into one `with` set; `provides` always written and
   limiting only what the body calls; `uses` and `!` inferred for a
   private wiring, written for a `pub` one, direct needs only; not a
   value; items only; wirings combine and nest; parameters carry config
   and descriptions; plain `with` still exposes everything; teardown in
   reverse install order. Every error in §5's list, each with its fix-it,
   and `ren explain-wiring`. Left out: `but`, overrides, sealed wirings.
2. **The pipe** (language.md §8): `x |> f(a)` is `f(x, a)`; targets
   decided by the parser alone; values only, no `&`; no blocks as steps;
   `|>` into the subject's own method is an error; each link one term;
   `orelse` may follow a chain; **every link is `[try | attempt] term`,
   and `|>` ends the reach of `try` and `attempt`**; the grammar,
   the line continuation of `|>` and of a leading `.` (streams.md's
   addition to §8), all-or-nothing formatting, and every error in §8.
3. **11a's follow-ups** (decision 7, decision 10, Staging item 4):
   - a task that can reach a handler installed inside the scope it's
     spawned into is a compile error, with the help that opens the
     scope inside the `with`; the run time checks what a scope passed
     to a helper hides; this replaces the built rule that cancels such
     tasks when the `with`'s body ends;
   - `Async.beside(task) fn() => body` and `Async.background fn(bg) =>
     body`: the body ends, then the background is cancelled and waited
     for, then the handler's `finally`; a background failure cancels
     the body and is its error;
   - `release` on one call, `try release next.get(id)`: the instance is
     let go of for that call and taken back after, queueing like any
     caller; `sim` switches tasks at every `release`, which is how a
     stale read across one is found: by a seed, not by a warning or an
     error (Ren has no warnings). Advice for it in `ren review` is
     later, with `ren review`;
   - decision 10's deadlock rules: `sim` names the instances a parked
     task holds, and a task taking an instance it already holds panics
     rather than hangs;
   - `Proc.run(cmd, args, kill: Tree | Child)`, `Tree` by default,
     which kills the process group, closing 11a's known hole.
4. **From streams.md, what needs tasks but not generators:**
   - `Async.each` and `Async.map` take a pull argument (rule 3): a
     collection by snapshot, a temporary data cursor as itself, a named
     data cursor as `&r` (decision 2's new row: a write, held for the
     call), and a channel's `items()`. They pull on the caller's task
     only when a slot frees; `max:` 64 by default; `map` keeps order.
   - **Channels are dependencies**, `dep Events = Chan<Event>`, and
     `Events.items()` is a cursor the compiler derives, whose `next` is
     `Events.recv()`, typed by the dependency's name.
   - **`Async.produce(cap: Int = 16, f) fn(items) => body`** runs `f` on a task
     in the consumer's scope; `f` sends with `Send.send(x)` through a
     `Send<T>` dependency the call installs (decision 5), not a channel
     it holds; `cap` is the backpressure; when the body ends, by
     finishing, `break` or a failure, the producer is cancelled and
     waited for; a failure in the producer ends the stream with it.
5. **`striped`** (decision 18, language.md §11 "Stripes" and "Policies
   are data"): one function, `striped(h, n: Int = 16, by: Key)`, keeps
   n instances; `by: Worker` with `n` given is a compile error, since
   the workers decide the stripes. An operation whose
   first parameter has a `key` goes to one stripe (`by: Key`, the
   default); `by: Worker` gives the caller's worker's stripe and takes
   no n; a keyless operation runs on every stripe, and one that returns
   a value is folded with `merge:` (`Sum`, `Max`, `Min`, `Concat`,
   `Custom(m)`, m a stateless handler for the derived `Merge<D>`), left
   to right in stripe order. There's no default `merge:`: a `striped`
   without one refuses, at compile time, a keyless operation that
   returns a value; not an atomic snapshot; the split law, with
   at least two virtual workers under `sim`, routing from the tape. **It
   replaces `sync.keyed`, which goes.**
6. **`actors`** (decision 18, language.md §11 "Actors are a service"):
   `Actors<K, D> ! E` as a dependency, `E` the errors of making an
   actor (`dep Docs = Actors<DocId, Doc> ! StoreDown`), which the
   handler's setup must fit, as any handler fits its dependency;
   `actors(h, max: Int = 10_000, evict: Lru, mailbox: Int = 10_000)`
   with `h` a handler
   whose one parameter is the key and whose other dependencies come
   from the `with` set; `Docs.at(k) fn() => body` installs k's actor as
   `D` for the block, pins it, and makes it on demand, setup's errors
   being `at`'s, waiters on one key's setup sharing its error, a
   cancelled setup retried by the waiters; each operation takes the
   actor for one call; eviction under `max:`, of the least recently
   released evictable actor, the victim's `finally` on the caller's
   task, waiting when none is evictable; never evicting one that's
   pinned, running or waited for; `evict_idle(d)`, `evict(k)`, `each`
   (live actors in creation order, pinning each, not use), `count()`
   and made and evicted counts; `finally` can't fail; `at` inside `at`
   of the same family is a compile error, and a full family fails with
   `Full` where waiting could close a cycle; **`post` is Erlang's
   cast** (decision 18): `Docs.post(k).op(args)` puts one operation of
   `D`, its arguments evaluated when posted and copied as data, in k's
   mailbox, and returns; only an operation that returns `()` and can't
   fail can be posted (anything else is a compile error with help);
   **a post makes its actor as `at` does**, so its only errors are
   setup's, `try Docs.post(k).op(args)`, queued mail counts as waiting
   for the actor (never evicted), a delivery never runs setup, and an
   actor made for a post goes past `max:` when none is evictable
   instead of waiting; posts from one task to one actor run in order,
   each as one operation, on a task the family's `with` owns, the
   mailbox belonging to the key so order survives eviction; an actor
   names its own family in its handler's `uses` and may only `post` to
   it, never `at`; back-pressure is at the family's edge: **every call
   from outside is metered**, a post and an operation called through
   `at` (before it takes the actor) both wait while the family's mail
   is over `mailbox:`; a sibling's post never waits, and **past twice
   `mailbox:` it panics** (a chain reaction is runaway recursion);
   debug builds and `sim` report each family's high-water mark; posts
   are journaled as data; **teardown drains** queued posts, then runs
   the `finally`s; research/actors-post/ is the FizzBee model of these
   rules, and its counterexamples are tests;
   `evict: Lru` by default; teardown in reverse creation order;
   partitions with their own map, exact LRU and a cap of `max / parts`,
   so a journal from one thread replays on many; under `sim`, eviction
   only through `max:`, `evict_idle` and `evict`, and
   `sim.scheduler(seed, evict: AnyIdle)` as opt-in chaos at any
   scheduling point; the journal naming an actor `docs[DocId(7)]#3`.
7. **Interpreter first, as tasks are** (Staging item 6). What's
   sequential also builds natively and agrees with `ren run`: wirings
   and the pipe are front-end only, and `release` with no other task is
   a plain call. What starts tasks is refused by `ren build` as 11a
   refuses `Async.scope`. `actors` and `striped` are built in, as `keyed`
   is (a handler can't keep instances of another), and refused natively
   as `keyed` is, unless that's cheap.
8. **Decision 2's handler-state row is narrowed** to `Async.until`,
   `release` and block-parameter calls, so an actor loops over a reader
   kept in its state while each step calls other services. Build it in
   excl.ml in step 4, with `release`.
9. **Defaults** (language.md §2, "Calls have one by-name form"): a
   parameter given by name always has a default. A default may be a
   literal or a variant with no fields (`kill: Kill = Tree`, `evict:
   Evict = Lru`, `by: By = Key`), a small extension to the parser and
   Lower in step 0.

## Decided after the draft

Record these in the spec; don't reopen them.

- **Sequencing:** after the data stage is merged.
- **By-name arguments:** defaults only, a variant with no fields
  allowed as one (What's decided 9); `max: Int = 10_000`, `mailbox: Int
  = 10_000`, `cap: Int = 16`, `n: Int = 16`; no default `merge:`.
- **`striped`:** one function, `striped(h, n: Int = 16, by: Key)`.
- **Stale reads after `release`:** found by `sim`'s seeds; no warning.
- **`Docs.at`'s errors:** declared on the family, `Actors<K, D> ! E`.
  `Full` is in `at`'s errors only where the checker sees that waiting
  could close a cycle.
- **`post`:** Erlang's cast, as What's decided 6 says.
- **`Async.produce`'s `items`** is a block parameter, `fn() ->
  Option<T>`, looped with `for p in try items` and passed on as a block.
  `Async.map_pull` lands here, in `produce`'s shape.
- **Pull arguments now:** collections, temporary data cursors, `&r`, a
  hand-written `fn() -> Option<T>` block, and a channel's `items()`,
  a block whose step is `Events.recv()`.
- **A trailing block in a pipe** only in the last link.
- **The journal:** actors add made, evicted and posted lines, and an
  operation names `docs[DocId(7)]#3`; that's version 3, and recorded
  journals are recorded again.
- **`sim` chooses fairly** among an instance's waiters and arrivals,
  from the tape, landing in step 4 with `release`.
- **Partitions now,** so a journal replays across cores: `parts: Int =
  4`, the same under every runtime (`single`, `sim`, many cores), since
  the count decides which actor is evicted; the journal records it.
- **`Lfu`** later; `Lru` only.
- **Native:** wirings, the pipe and `release` with no other task build
  natively; `beside`, `background`, `produce`, `striped` and `actors`
  are interpreter-only, refused by `ren build` as `keyed` is.
- **Decision 7's run-time half:** a panic at the spawn.
- **`Async.background`'s tasks** may fail; the first failure cancels the
  body and is its error, as `beside`'s is.
- **The milestone** uses a line protocol over `sim.net` and an `Op`
  that appends; "runs" means its tests pass under `--seeds 1000` with
  `evict: AnyIdle`.
- **`sim` has two virtual workers** for `by: Worker`.
- **`Merge<D>`'s `Custom(m)`** takes a stateless handler of the derived
  `Merge<D>`. Decision 18's `fn(a, b) => ...` shorthand is the inline
  handler form a one-operation dependency already has; nothing new.

## Working beside bytes part two

The second bytes stage (briefs/stage-bytes-2.md) runs on `main` at the
same time. It owns strings' runtime and native layout; this stage owns
the front end's new forms and the interpreter's scheduler.

- **Yours:** wirings and `|>` in the parser and checker; the lexer's
  `continues()`; lib/eval/sched.ml; `With` and `Dep_call` in eval.ml;
  std_lib.ml's `sync`, `sim`, `striped` and `actors`; excl.ml; the
  journal.
- **Theirs, don't touch:** ren_rt.c and ren_rt.h's string and byte
  code; `to_mem.ml`, `emit_c.ml` and Mem Lint where `Str` and `Bytes`
  are laid out; the interpreter's `VStr` and `VBytes`; the lexer's
  string and character literals.
- **Shared files** (parser.ml, lower.ml, prelude.ml, builtins.ml,
  infer_expr.ml): add your cases and entries; don't move, rename or
  restructure code there. If you need a change that would, stop and say
  so in the progress log.
- **New tests go in new files,** and new Ren code avoids names that
  stage changes: write `s.byte_len()` only once it lands, and until then
  avoid `len` on a `Str` in new code (use `Bytes`' `len` or none), and
  avoid `s.lower()`.
- **Rebase before every push.** If a conflict touches their work, keep
  theirs and redo yours on top. If a check goes red because of their
  commits, not yours, record it in the progress log and don't fix their
  work.

## Steps

Do them in order. After each step, THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, inventory, tests first.** Add a "Services stage" section to
   compiler.md that settles what the later steps need: the grammar for
   `wiring`, `|>` and `release`, and how `try`'s parser stops at `|>`;
   how a wiring is flattened in Resolve and Infer, and where `provides`
   is enforced; how `Send<T>`, `Chan<T>`'s `items()`, `Actors<K, D>` and
   `Merge<D>` are declared or derived; the representation of a family
   (partitions, the LRU, pins, mailboxes, incarnations) in the
   scheduler; which journal lines are new and whether that's version 3;
   and "Decided after the draft". Inventory
   every site that changes: users of `sync.keyed`, of the background
   rule 11a built (examples/refresh, async.md's metrics flusher, tests
   in test_tasks.ml), of `Async.map`'s `Array`-only parameter, of
   `Proc.run`. Then write the tests, behind `until "sN"` as 11a's were,
   in a new test/test_services.ml: one per feature, one-line refusal
   tests for every new error, and in bench/services/ the programs below,
   marked `not yet`: the document server, its lost-update test and its
   chaos-eviction test.
   *Done when* the section records every decision above and the tests
   exist and fail for the reason their step will fix.
1. **The pipe,** through the whole pipeline, natively too, with
   `.` and `|>` continuation lines in the lexer and the tree-sitter
   scanner. Rewrite the README's and language.md's end-to-end shapes as
   examples that run.
   *Done when* each §8 error is a refusal test, `differential.py`
   agrees on chains, and bench/build.t builds a chain natively.
2. **Wirings,** through the whole pipeline, natively too, with every
   §5 error and `ren explain-wiring`. Move examples that repeat a `with`
   list, or wrap one in a function that takes a block (bank, shop,
   ledger, server), to wirings, with their tests split the way §5's
   "Tests" says.
   *Done when* language.md's end-to-end program runs as written (but
   for `http.serve`), a test splits a wiring, and no example keeps the
   function-that-takes-a-block pattern §5 says wirings replace.
3. **Background work:** the compile error for a task that reaches a
   handler installed inside its scope, with the run time's check where a
   helper hides which scope is inner; `Async.beside` and
   `Async.background`; the built cancel rule removed. Move
   examples/refresh and async.md's metrics flusher to `Async.beside`.
   *Done when* the pool ordering of decision 7 (work drains, background
   stops, `finally` runs) is a test, a background failure cancelling
   the body is a test, and nothing still relies on the old rule.
4. **`release` and `Proc.run(kill:)`:** `release` in an arm, queueing
   on the way back, a scheduling point under `sim`, the arm's copies of
   its state written back before and read again after (as 11a's
   `until_released` does); decision 2's row narrowed in excl.ml; a
   task re-taking an instance it holds panics, and `sim` names the
   instances a parked task holds; a circuit breaker example whose test fails under seeds without
   `release` and passes with it. `kill: Tree` puts the child in a
   process group of its own and kills the group; `sim.proc`'s
   `killed()` reports which. `sim`'s fair choice among an instance's
   waiters and arrivals, from the tape, lands here too.
   *Done when* `sh -c "sleep 5; true"` cancelled leaves no `sleep`
   (examples/just.t), the breaker's test holds under `--seeds 1000`, an
   actor-shaped handler loops over a reader in its state while calling
   another service (accepted), and the `until` deadlock of decision 10
   shows the instances held under `sim`.
5. **Pull arguments, channels and producers:** `Async.each` and
   `Async.map` over the pull arguments in "What's decided" 4, with the
   `&r` row in the exclusivity pass; `Chan<T>`'s `items()`;
   `Async.produce` with `Send<T>`, and `Async.map_pull` in its shape.
   Move the crawler to `Async.produce`
   if it reads better (async.md's crawler), and the server to
   `Async.each` over its connections if a cursor of them exists without
   generators.
   *Done when* each is a test under `--seeds 1000`, a `break` in
   `produce`'s body cancels and waits for the producer, and a producer
   blocked at `cap` makes progress as the consumer takes.
6. **`striped`,** built in where `keyed` was, with `by: Key`,
   `by: Worker` (two virtual workers under `sim`, routing from the
   tape), keyless broadcast and `merge:`, `Merge<D>` derived and
   `Custom(m)` checked as a stateless description; `sync.keyed` removed
   and its tests moved. A test shows the split law: a program whose
   result depends on routing beyond what the merge erases fails under
   some seed.
   *Done when* language.md §11's `striped` lines run, and nothing names
   `keyed`.
7. **`actors`,** built in: `Actors<K, D> ! E`, `at` with setup and its
   declared errors, pinning, partitions and LRU eviction under `max:`,
   `evict`, `evict_idle`, `each`, `count` and the counts, the
   no-deadlock rules (`at` in `at`, `Full`), `finally` that can't fail,
   teardown order; `sim.scheduler(seed, evict: AnyIdle)`; the journal's
   actor names with incarnations, recorded and replayed. Then **`post`**,
   as What's decided 6 says.
   *Done when* each rule in decision 18's `actors` list has a test, a
   journal of a run that evicts and remakes a key replays byte for
   byte, and `post` has tests that: arguments are evaluated at the post
   (a `var` changed after it doesn't change the message); posting an
   operation that returns a value, or can fail, is refused; posts from
   one task to one actor run in order under `--seeds 1000`; an actor
   can `post` to its own family and `at` on it is refused; two actors
   posting to each other past `mailbox:` don't deadlock while an
   outside poster waits; the high-water mark is reported; a run with
   posts replays from its journal; and research/actors-post/README.md's
   counterexamples, in Ren, each behave as the fixed rules say: a post
   from inside `at` while the mailbox is full and its target isn't live
   completes (no deadlock); a session looping an `at` operation that
   posts to a sibling is held at the edge; a chain reaction panics past
   twice `mailbox:` with the high-water mark; a post whose setup fails
   returns setup's error and loses nothing; teardown with posts queued
   delivers them before the `finally`s.
8. **The milestone.** examples/docs: language.md §11's document server
   behind a wiring, sessions over `sim.net`, a test store, and tests
   that every subscriber sees one order of edits and that the store
   holds the final text. Then:
   - it passes `ren test --seeds 1000` with `evict: AnyIdle`;
   - a variant that keeps the text only in memory (no write-through)
     fails under chaos eviction, and the seed reproduces it;
   - a variant that reads with one operation and writes with another
     inside one `Docs.at` block fails `ren test --sim --seeds` with a
     lost update, replays by `--seed`, and the one-operation fix passes
     under every seed.
   Add these to bench/tasks.t's milestone, as 11a's lost update is.
9. **Review your own work** with three lenses:
   - **Soundness:** adversarial programs for wirings (flattening that
     duplicates or hides, a cycle through a wiring, `provides` bypassed
     through an item's own body), the pipe (`try` reach, `orelse`,
     continuation lines inside brackets), background work (a helper
     handed the inner scope, a background task spawning), `release`
     (state read across it, a `release` inside `until`'s condition),
     `produce` (a producer that fails while the body is blocked, a body
     that breaks while the producer is at `cap`), stripes (a merge whose
     result depends on stripe order), and actors (eviction during
     setup, a post to a key being evicted, `at` on a key whose `finally`
     is running, a full family reached from an actor, a cancelled caller
     paying for an eviction, teardown with posts in flight).
   - **The spec:** does it match foundations.md, language.md and
     streams.md, and does "Done when" hold?
   - **Docs and tooling:** async.md (its background section and its
     "Later" line on streams for `each` and `map` are stale), stdlib.md,
     testing.md, the README's status and roadmap row, language.md's
     "What Ren has today" table, compiler.md, the grammar and corpus,
     Zed queries.
   Fix what blocks; list the rest with its severity.

**Done when** language.md §11's document server runs under `sim` with
`evict: AnyIdle`, and `ren test --sim --seeds` finds a lost update split
over two operations of one actor and replays it by seed (Staging item
6), with the end-to-end program of language.md running with its wiring
and its pipe.

## Language changes go through the whole pipeline

Every language change goes through:
- the lexer and parser;
- Resolve, types and Core, with Core Lint;
- the interpreter;
- native, debug and release, for what's sequential;
- the tree-sitter grammar and its corpus (`editors/tree-sitter-ren`),
  with `differential.py` agreeing with the compiler's parser;
- Zed queries (`editors/zed`);
- error messages with help lines;
- the docs that describe it.

Grammar and editor support is first-class: don't hack it in.

## THE CHECKS

All must pass before any commit:

- `dune build`
- `dune test --force` (includes bench/build.t's sanitizer and tcc
  builds, and bench/tasks.t)
- `make -C editors/tree-sitter-ren check`
- `_build/default/bin/main.exe test` inside each of examples/bank,
  examples/prices, examples/just, examples/ledger, examples/crawler,
  examples/refresh, examples/server and examples/transfer, and in each
  new example (examples/docs at least)
- `_build/default/bin/main.exe test --seeds 1000` in examples/crawler,
  examples/refresh, examples/server, examples/transfer and
  examples/docs

**Setup:**
- OCaml 5.x with opam: `opam install dune ppx_deriving ppx_expect`.
- clang, with AddressSanitizer and UBSan.
- node and npm, for tree-sitter.
- python3.
- tcc: `tools/tcc.sh`.

If a check fails at the start before you change anything, fix it when
it's a portability bug in the repo (and say so). Otherwise record
exactly which checks you couldn't run. **Never weaken or delete a test
to get green.** Tests that check real-time ordering are sensitive to a
loaded machine (examples/journal.t flakes under load); if one flakes,
rerun it, and report it rather than loosening it. `dune test --force`
skips bench crams unless `REN_TCC` is set; set it.

## What not to touch

- **streams.md, strings.md, prior-art.md**, and the root `dune` file's
  local changes. Never commit anything under .claude/.
- **foundations.md and language.md's design sections.** If they're
  wrong or underspecified, make a choice, record it in compiler.md's
  services section under "Where this stage may differ", and list it in
  your final report. The one exception is language.md's "What Ren has
  today" table.
- **Native record and variant layout, slices, `Map`'s representation:**
  the data and bytes stages own them.
- **The scheduler's single-thread design.** No threads, no atomics, no
  marking: that's 11b.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results untrustworthy.
  Note others in your final report. 11a's known low items (a block
  parameter passed on to an operation isn't checked statically,
  `Unix.select`'s descriptor limit, a panic in a task inside
  `Async.isolate`) stay unless a step needs them.
- **Committing:**
  - Commit on main with explicit `git add` paths, never `git add -A`.
  - End every commit message with
    `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Push to main after each green step. If you can't push to main, push
    a branch named `stage-services` and say so.
- **Keep a progress log** at the end of compiler.md's services section
  (step, commit, what's done, what's left), so a resumed session can
  pick up where it stopped.

## Risks

- **The parser is shared with the data stage.** `|>`, `wiring` and
  `release` land after by-name variants, `..` and `as` patterns; `as`
  now has a pattern meaning beside `with h as Dep`, and wirings put
  `as` inside an item list (`actors(doc, max: 50_000) as Docs`).
- **`try`'s reach changes.** Stopping `try` and `attempt` at `|>` is a
  parser change under every existing `try`; the corpus and
  `differential.py` are where a slip shows.
- **Continuation lines.** A line starting with `.` continuing the one
  above is new to the lexer and to tree-sitter's external scanner, and
  must not swallow a line that starts a new statement.
- **Built-ins that are standard library.** `striped` and `actors` are
  OCaml in the interpreter, as `keyed` is; their rules (eviction,
  pins, mailboxes, partitions) are a second scheduler inside the first.
  Keep them in their own module, beside sched.ml, with the same
  journal and tape hooks.
- **Eviction runs code on someone else's task.** A victim's `finally`
  runs on the caller that pays for it, which can itself be cancelled
  while it runs; it's shielded, as 11a's `finally`s are, under the
  cleanup deadline.
- **Chaos eviction multiplies schedules.** `evict: AnyIdle` at every
  scheduling point makes 1000 seeds slower; measure the milestone's run
  time and say it.
- **The journal format.** Actor names, incarnations and posts may need
  version 3; examples/just/tests/build.journal and any other recorded
  journal would be recorded again, as 11a did for version 2.
- **`Proc.run(kill: Tree)`** needs a child in its own process group;
  OCaml's `Unix.create_process` can't, so it's `fork`, `setsid` or
  `setpgid`, and `execvp`, which must not run OCaml code between fork
  and exec beyond that.
- **The doc server needs things other stages own:** `conn.ops()` is a
  framed reader (formats, strings), `text.apply(op)` an editing
  model. Write the milestone's version with the smallest stand-ins
  (a line protocol over `sim.net`, an `Op` that appends), and say so.

## Deliberately out

- **Generators and the stream library** (stage 11c): `gen fn`,
  `yield`, pipelines over cursors, user stages, `stream.time`'s `batch(within:)`,
  `debounce`, `throttle` and `sample`, readers that hold an id,
  incarnation and offset (streams.md rule 6), `Net.frames`, and closing
  a named pipeline at its scope's end (streams.md, "Open").
- **Many cores** (stage 11b): `work_stealing`, `per_core` and `pinned`,
  locks on partitions and stripes, padding, fair handoff measured,
  marking, arenas, `snapshot`, lock-free handlers.
- **Phase one of the many-cores experiments** (K3, P1, P3, S1, K1 and
  K2, the cache three ways): they run alongside this stage, on the M4
  Max, in experiments/, not in this brief.
- **Actors' open items** (decision 18): `Docs.at_all(keys)`; containing
  a panic in an actor under `Async.isolate`; `expire:` and `weigh:`,
  designed with the server milestone; a `place:` parameter.
- **Wirings left out by §5:** `but`, `replace`, memoization by identity,
  sealed wirings, two copies of a sub-graph.
- **The pipe's later items:** calling a type's own method mid-chain.
- `Table`, `Pool`, formats, `ren review` and its hints, methods on one
  variant.

## Final report

End with:
- **Per step:** what was built, the commits, and the choices you made
  where the spec was silent.
- **Whether "Done when" holds,** with the commands that show it, the
  seeds that found the lost update and the in-memory loss, and how long
  the milestone's 1000 seeds take.
- **What's unfinished or unsound,** with its severity.
- **Which checks couldn't run** in this environment.

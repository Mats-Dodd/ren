# Structured actors: what the design changes

An audit of every place in the repository the structured-actors design
touches, made before writing `structured-actors.md`. Nothing here is
edited yet. Line numbers are as of 2026-10-30.

## The design, in brief

1. Calls own their work (scopes and the combinators); scopes are anonymous.
2. `post` hands work to a family and waits only for room in **that key's**
   mailbox (per-key bound). A posted operation can't fail; setup's errors
   are the poster's.
3. **An `at` block holds its family; while it's held, you can't reach
   that family or one installed inside it.** Operations keep this by
   construction (a handler's `uses` resolve outside its install), so
   only `at` blocks need a check. Calls and mail flow outward along the
   install DAG, so waits have no cycles. (MODEL.md: the looser "not F itself" deadlocks three ways; the
   strict rule makes decision 18's pin/`Full` rule and "delivery past
   `max:`" unnecessary.)
4. A family's `with` drains when its body returns. If it's cancelled,
   running operations are cancelled, queued mail is dropped, and the
   `finally`s see `Err(Cancelled)`; the drain isn't shielded.
5. A panic ends the program (decision 8).

Plus, from the same discussion: `s.start` and `s.replace` go; `beside` is
std over `scope`; "ends once" for generators; `per_core` is the default
runtime, with `at`'s mechanism under it decided by experiment; keys are
spread over cores by the runtime and `parts:` goes; eviction is K1b's
sampled eviction under one global `max:`, carried out on the victim's
home core; `at_all` is in v1, with `at` on a held key allowed inside it;
`mailbox:` defaults to 64 per key.

## Already built (this is not docs only)

Services stage steps 6 and 7 built the keyed instance family, `actors` and
`post` in the interpreter (commits `261287d`, `07434ed`, `e8c9e02`). 11a
built `s.start` and `s.replace`. Generators (11c) are not built, so "ends
once" is a doc change only.

| Where | What's there | Change |
|---|---|---|
| `lib/eval/family.ml` (784 lines) | queues, delivery tasks, the edge's meter against one `mailbox:` per family, sibling posts that never wait, the 2× panic and high-water mark, delivery past `max:`, drain | per-key bound, and every post waits for room; remove the meter on `at` operations, the sibling path, the 2× panic, the high-water mark, delivery past `max:` and the partitions; exact LRU becomes sampled eviction; drain stays on a normal end, and a cancelled `with` drops queued mail; add `at_all` and the held-key rule |
| `lib/sema/infer_*.ml`, `resolve.ml` | an actor may name its own family in `uses`; Infer marks operations that reach `pin` (through what they call) and refuses them inside the same family's block or handler arms; a run-time panic backstops what a helper hid | handler arms need no new check: an actor naming its own family in `uses` becomes the ordinary "cycle in one `with` set" error. Extend `at`-in-`at`'s check to `at` blocks reaching F or a family installed inside it, by `at` or `post`, with the same run-time backstop (a depth check against the held family) |
| `lib/core/prelude.ml` | `actors(doc, max:, mailbox:, evict:, chaos:, parts:)` | `mailbox:` now means per key, default 64; `parts:` goes; `evict: Lru` documented as sampled |
| `lib/eval/journal.ml` | `posted` lines; journal version 3 | probably unchanged; check that the high-water lines go |
| `lib/test_runner.ml` | `ren test` reports each family's high-water mark | remove, or keep as a plain per-key queue statistic |
| `lib/eval/sched.ml`, `eval.ml` | `s.start`, the task handle, `s.replace` | remove `start`, `Task<T>`, `join`/`cancel` on handles, and `replace` |
| `test/test_services.ml` s7 | `post` tests at 3518 (an actor posts to its own family), 3580 (two actors posting past `mailbox:`), 3612 (chain reaction panics), 3639 (post from inside `at`, target not live), 3664 (session `at` posting to a sibling, held at the edge), 3695 (high-water mark) | 3518, 3580, 3612 and 3664 become refusals ("can't post to `Docs` from inside it"); 3639 becomes a refusal if same family, or is rewritten across two families; 3695 goes. Keep 3366–3493, 3539, 3564, 3727 and 3848–3867 |
| `test/test_actors.ml` | 12 tests of decision 18's rules | review against the per-key bound |
| `test/test_tasks.ml` | `s.start` (274, 305, 548, 561, 589) and `s.replace` (610–614), including their refusals | remove, or turn into "no such method" tests if useful |
| `examples/server/main.ren:101` | `let server = s.start fn() => run_server()` in a test | rewrite with `Async.both`, or a scope and an assertion after it |
| `editors/tree-sitter-ren/test/corpus/actors.txt` | grammar corpus for actors | check for any sibling-post example |

## Docs

### foundations.md

| Lines | What | Change |
|---|---|---|
| 347–432, decision 7 | `s.spawn` with handle (`cancel`/`join`), `s.replace(key)`; `Async.beside` and `Async.background` | handles and `replace` go; scopes are anonymous; note `beside`/`background` as std over `scope` (decision 20) |
| 448–472, decision 9 | `work_stealing` "the default" | `per_core` is the default |
| 932–1100, decision 18 | the family's soundness rules: "a delivery may go past the library's bound", "every call from outside is metered", "a sibling's post past twice the bound panics"; `actors`: Siblings (an actor names its own family and may `post` to it), Back-pressure at the edge, A chain reaction panics, the "No deadlock" paragraph ("a sibling's post never waits, which is what makes actors posting to each other in a cycle safe"); Open: `at_all`, `isolate` in actors | rewrite the post rules to the five rules above; per-key `mailbox:`; delete Siblings, edge metering and the chain-reaction panic; restate No deadlock as "no reaching a family from inside it, plus inner-to-outer"; drop the `isolate`-in-actors open item (panic ends the program); keep `at_all` open |
| 1128–1140, "On many cores" | "No home core. … Shipping operations to a home core, as Seastar does, costs a hop" | reverse under `per_core`: `post` goes to the key's home core (by partition); `at`'s mechanism decided by experiment |
| 1484, 1506, 1526, 1545, 1594 (Staging) | stage text for beside/background, home-core experiments, 11b's runtimes | update the default and home-core wording |
| 1618–1686, Open questions | "Actors' open items" | update |

### language.md

| Lines | What | Change |
|---|---|---|
| 304–306 (summary table) | the keyed family's `post`; the Actors row, including "`at` in…", sibling posts and `Full` | update the rules row |
| 1289–1479, §11 | "An actor can't `at` its own family, only `post` to it"; "`post` is Erlang's cast … An actor posts to its siblings by naming its family in `uses`. Every call from outside … waits while the family's mail is over its `mailbox:` bound; a sibling's post never waits, and past twice the bound it panics" | "An actor can't reach its own family"; `post` waits for room in its key's mailbox; cross-family example (`Index` outside `Docs`) instead of a sibling post |

### async.md

| Lines | What | Change |
|---|---|---|
| 38–53, "The whole surface" | `s.start`, `t.join()`, `t.cancel()` | remove |
| 72–83 | `s.start`, `s.replace(key)` | remove; point keyed work at families |
| 166–168 | "A scope and a task's handle are blocks too" | scopes only |
| 361–407, "Background work is a task beside the `with`" | the older form: a task spawned into an outer scope, cancelled by the `with` | already superseded by decision 7's `Async.beside`; make consistent and say `beside` is std over `scope` |
| 623–633, 760–762, "How it runs" and "Later" | `work_stealing` and `per_core` "later" | `per_core` the default |
| 668–674, "Left out on purpose" | fibers as values, daemon fibers | add: task handles kept past the call; messages inside a family |

### streams.md

| Lines | What | Change |
|---|---|---|
| 359–372 | `finally(r)` sees why it ended; "A finished generator gives `None`, but stepping one that was cancelled panics" | "ends once": the frame keeps `r`; every later step replays it: `Ok` → `None`, `Err(e)` → fails with `e`, `Err(Cancelled)` → panic; a generator never stepped never runs. Say that never answering again is the frame's promise, not the cursor protocol's |

### compiler.md

Built-stage records are history, so leave them as they are, except:

| Lines | What | Change |
|---|---|---|
| 11425–11910, "Services stage" | the family, actors and post as built | leave as the record; add a later stage entry for the change |
| 5927–5961, 10276–10339, 12854–12865 | post, mailbox and the 2× panic in summaries and tables | leave as history, or mark as superseded |
| 4318–4872, 11126 | `s.start` and `s.replace` as built in 11a | history |

### README.md and briefs

| Where | What | Change |
|---|---|---|
| README.md:1160–1162 | the services and 11b rows | 11b: `per_core` first |
| briefs/stage-services.md:140–152, 203–221, 277–283, 455–468, 635–650 | the services brief's post rules and tests, as built | history; a new brief for the change if it's run as a stage |
| briefs/stage-11a.md:115–118 | `s.replace` | history |

### Research (leave, link from the new doc)

- `research/actors-post/`: the first model and the holes that motivated everything.
- `research/actor-origins/`: LANDSCAPE.md (prior art) and MODEL.md (origins, fuel and the outbox: the road not taken, and the evidence that messages within a family need runtime accounting).
- `experiments/origin-counters/`: the counting costs, if messages within a family ever come back.
- `research/streams/stress-test/programs/10-streams-and-actors.md` and `research/streams/experiments/e1-*`: programs that use `post` and `Docs.each`; check whether any posts to its own family.

## Settled in the design doc

- **"A delivery may exceed `max:`"** goes (MODEL.md).
- **The per-key bound** keeps the name `mailbox:` and defaults to 64.
- **The high-water report** becomes a per-key queue depth in `sim` and
  debug builds.

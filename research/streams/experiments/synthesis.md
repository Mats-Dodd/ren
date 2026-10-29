# Streams: synthesis of E1–E4 and the two judges

Inputs: amendments.md, e1-programs.md (13 programs), e2-prototype.md
(interpreter spike), e3/RESULTS.md + e3/VERIFY.md (C models, measured),
e4-composition.md (composition audit), judge-coherence.md,
judge-ergonomics.md. Group A is decided. This file recommends a call
on everything else.

## 1. Verdict

**Group A holds, and needs two sentences changed.** E2 compiled
pipelines as the blocks the compiler would write, and today's checker
refused every soundness counterexample (keep, drive, consume, chosen,
stored, returned, concurrent) with its existing messages. The only
checker change was 3 lines, for a `try` the compiler writes. E1 wrote
13 programs with no exception to the rules: 7 read better than the best
twin, 5 the same and 1 worse (the lexer, which needs byte offsets kept
by hand). E3 shows the cost model holds: a chain composed where it's
written runs at hand-loop speed. The two revisions:

- **A2's "pure" means the inferred row, not the written one.** E2's
  `sneaky` declared no `uses`, called `print`, became a storable value
  cursor and ran. Restated: *a `gen fn` call gives a value when its
  parameters are all data and nothing it holds across a `yield` is an
  instance: no dependency in its inferred row, no `with` open, no
  place (`inout`). Errors don't count. Otherwise the call gives a
  block.* A block that the frame composes over its own data, such as
  program 11's `tokens` holding a `semis` pipeline over a pure `lex`,
  is part of the frame and copies with it. This keeps E1's best result
  (wrapping a pipeline in a pure `gen fn` makes it a value again).
  E4's shorter wording, "a frame holding only data is data", would have
  lost that result (Erg item 4), so it isn't used as the rule.
- **The cost figure is 1,300–1,900 lines, not 450.** The 450 was the
  generator runtime alone, which came to 118 lines in eval.ml plus
  about 70 more. Recognising and composing chains, choosing value or
  block from the row, the pull coercion and the messages make up the
  rest. That's still under the 2,400–4,400 lines of the draft made
  sound, so A1 stands.

## 2. Decisions 3–14

### Decision 3: spelling a named effectful generator

| Option | E1 (programs) | Coherence | Ergonomics |
|---|---|---|---|
| (a) `let g = follow(p)`; `for l in try g`, `g.take(20)`, `try g()` | won 2 programs (rebinding) | **1st**, medium-high | 2nd |
| (b) `var g`; `&g` | won 4 programs (use site) | rejected (first `var` block, cleanup at `=`) | 3rd |
| (c) `let g`; `&g` at each step | proposed | rejected (`&` gets a second meaning) | **1st**, about 60% |

**Call: (a).**
- A1, decided today, already spells it this way: `let errors = &r.map(..)`, then `for e in try errors`.
- A block parameter is stepped with no `&`. Under (a) a local pipeline and a pipeline parameter read the same.
- (c) would need `&` on a `let` for blocks only. A `let`-bound value cursor still can't take `&` (decision 2), so (c) trades the "a block never takes `&`" error for a "`&` on a `let` only if it's code" exception. That isn't fewer rules.
- The visible difference between `var r = Fs.line_reader(p)` and `let g = follow(p)` carries information: you can keep the first and not the second.
- Cost accepted: in program 13, `rs.take(20)` inside a loop reads as "the first 20 again" to C# and Kotlin eyes. The hover says "steps `rs`". A `.stage` on a bare `let` name is always a block being stepped, because a named value cursor without `&` is an error, so the compiler can never misread it.
- Hand-stepping is `try g()`, which is what calling a block looks like. Don't add `.next()` on blocks.
- **Condition:** (a) rests on closing a named pipeline when its scope ends, which E2 didn't build. Build it before freezing.

### Stopping early (4, 5, 12)

| # | Call | Evidence | Where the judges split |
|---|---|---|---|
| 4 | **`Err(Cancelled)`.** On abandonment the cancel rule applies whole: the `finally` runs and its result is thrown away. | E2 g4/g5: rollback on `break`, commit on a full loop. errors.md: only a `finally` sees `Cancelled`. | They agree. Document that a `.take(10)` rolls back a writing generator. |
| 5 | **The generator ends. A later step on a generator that was cancelled panics. A block given to a racing operation (`Async.timeout`, `race`, `until`) can't step a pipeline from outside it** (rule 7: a pipeline isn't an operation). Drop `next(within:)`, which is `Async.timeout(d) fn() => &r.next()` over a data reader. | Erg: with `None`, a timed-out pipeline looks like a clean end of stream, so data is lost silently. Coh: it's safe only with the check. | Coh: `None` + check. Erg: panic + `ren review`. **Both together:** the check catches the visible case, and the panic makes the hidden case loud. A finished generator still gives `None`, so the protocol doesn't change. |
| 12 | **A leased chunk is an ordinary root (decision 17).** Debug report, a pool metric and `ren review` advice. Under pool pressure the runtime moves a held chunk to the heap, an unshared root at a safepoint. Reverse strings.md's sentence. | A compile error needs provenance tracking that no other value has. Positions relative to the value make the move invisible, which strings.md already allows ("what the compiler may do"). Program 02's pool can't stall. | They agree, against the amendment. Medium: it reverses a sentence decided today. |

### Concurrency and time (6, 7, 9, 11)

| # | Call | Evidence | Split |
|---|---|---|---|
| 6 | **`max:` defaults to 64** | Decision 7 and async.md already say so, and pulling only when a slot frees bounds memory | None. A per-host limit is `Http`'s job |
| 7 | **Time operators take a source whose step is one operation.** Channels qualify. A library reader qualifies only if it promises to update `inout self` in place before each suspension. Ship channels first. A generator goes on a channel through `Async.produce` | async.md: operations are cancel-safe. Erg: `Net.frames` makes several reads per `next` | Erg doubts the wider form. Resolved by stating it as the reader's promise |
| 9 | **An installed `Send<T>` dependency** | Decision 5: those listed in its parameter's type, which the callee provides. An `out` value would be a held instance | None. It moves together with decision 6's `Send`/`Recv` split |
| 11 | **Narrow decision 2's handler-state row** to `Async.until`, `release` and block-parameter calls, **gated on a soundness check** (a FizzBee model of service cycles A→B→A under decision 10) | Programs 09 and 10 need copy-out, copy-in dances without it | None. Both say medium, and the check is the gate |

### Compiler (8, 10, 13, 14)

| # | Call | Evidence | Split |
|---|---|---|---|
| 8 | **In the design now:** base push, and eager fusion of pure collection chains. **Later:** folding user `gen fn` stages into the push. | E3: pulling a flat composed chain costs 1.00–1.06×. Full fusion through a `gen fn` bought nothing (1.02× once loop shape is fixed). Push is the guarantee that doesn't depend on clang's inliner. Eager fusion saves the intermediate arrays (not measured). | Judges: "push and fusion now". E3 narrows it. Fusion through a stage has no measurable payoff, so it's not worth 200–400 lines yet. |
| 10 | **Reversed: push recursive producers natively.** When one must pull, lower `yield from` to one frame stack owned by the consumer, with the child's first step run inline. Never box child frames. **A recursive `yield from` has the depth limit of a recursive call, pushed or pulled.** | Verified: boxed 13.4× (8.1× with the box reused), frame stack 1.08×, push 1.00×. | E4 and Coh: push recursion would overflow only when pushed, which breaks decision 13. Resolved: both lowerings share one depth limit, so meaning can't differ. |
| 13 | **One-shot fibers for effectful generators; replay to copy pure ones** | E2: 118 lines, g1–g5 pass | Note: replay is O(position) per copy, so program 11's backtracking becomes quadratic in the interpreter. The native backend copies frames. |
| 14a | `if` between pipelines is an error, with "choose inside one block" | `Let_chosen` fires today | — |
| 14b | Stage names are reserved on types with `next`, chosen by type, not spelling. Renames: `skip`→`drop`, `skip_while`→`drop_while`, `chunks(n)`→`batch(n)`, `chunk_while`→`batch_while`, `split_lines`→`lines`. `count`'s predicate is optional, decided once for the whole vocabulary | E2 test_ops collision. operators.md already says `drop` | — |
| 14c | Document lookahead loss, plus a `ren review` warning when the head is a stored reader or one stepped through `&` | Program 09 silently drops an entry per page | — |
| 14d | An N-way merge uses data readers for now | No program needed more | — |

**Smaller calls:**
- **Two `&r` heads in one call: drop the rule.** A pipeline is a block, and blocks passed to the same call don't conflict (decision 2). E2 shows this is sound. (Coh: drop. Erg: keep. The yardstick decides.)
- **The fix-it "`let c = r` then `&c.map(f)`": drop it.** Readers hold `(id, incarnation, offset)`, and the service checks the offset, so a stale copy fails, typed. That's decision 18 applied to a position.
- **The library ships two forms:** a use-here generator with a `finally` (`Fs.lines`, `Db.query`) and a keep-form data reader (`Fs.line_reader`). File readers hold a path and an offset, and `Fs` caches file descriptors with a `max:`. This closes E1's leak, where `break` holds a file open until the handler ends.
- **User stages chain with `|>`**, not `.`. That's language.md §8. Add `merge_by` to the default set.

## 3. Measurements (E3, checked by VERIFY)

| Workload | Push | Pull (composed, inlined) | Other lowerings | Rust | Go |
|---|---|---|---|---|---|
| W1 map/select/take | 1.00 ✓ | 1.01 ✓ | 1.22 with two `next` calls not inlined ✓ | 1.39 (**0.97** with libc memchr) | push 1.11, `iter.Pull` 1.31 |
| W2 tree walk | 1.00 ✓ | — | boxed 13.4 ✓, box reused 8.1 ✓, frame stack **1.08** (E3's 1.46 was pessimistic) | stack 0.94, boxed 15.4 | push 1.58, Pull 3.85 |
| W3 user `dedup_by` | 1.01 ✓ (stage pushed, source pulled) | 1.06 ✓ | full fusion 1.22, **1.02** with plain locals | 0.93 | Pull 9.9 |
| W4 `zip` | ~1.10 (one side pushed) | **1.25** (E3 said 1.14) | 1.86 with the zip block not inlined | 0.90 | Pull 25.7 / 53 |
| W5 passed to a user fn | 1.00 | 1.02 ✓ (specialized or indirect) | — | 1.38–1.51 (**1.01** with memchr) | 1.07 |

Ratios are against a hand-written C loop. ✓ means VERIFY reproduced the
figure within about 5%. Bold marks a number VERIFY changed. **Not
confirmed:** E3's W2 frame stack (1.46, too high), W4 pulled on both
sides (1.14, too low), and "faster than Rust on W1 and W5", which is
libc memchr, not streams.

**What it means:**
- **"The obvious code is the fast code" holds for streams.** It holds because a chain is composed where it's written (decision 1). Push and pull of a flat chain both equal the hand loop. Ren is level with Rust (within ±10%) and doesn't beat it.
- **Pull costs about 1 ns per item only when a `next` isn't inlined.** Push is the guarantee for the cases where that happens.
- **The one trap is a boxed recursive `yield from`, at 13×.** That's the same trap as Rust's `Box<dyn>` and Python's `yield from`, and decision 10 removes it.
- **`zip` costs about 25% on 1.5 ns items,** against 25–53× for Go's `iter.Pull`.
- **Caveats:** these are hand-written C models, not Ren output. Reference counting isn't modelled, and it would hurt the pulled W2 more. The generators are small: many `yield`s, or a `finally` or `with`, push pull toward the not-inlined rows.

## 4. What the prototype proved

- **Soundness: no new checks were needed.** Nine cases were refused by existing checks, each quoted in E2: generic `T` can't be a block; a block can't be stored or returned; rule A; `consume(.., &limit)`; `Let_chosen`; a concurrent block writing `r`. A pure gen fn stored in a record and copied forks honestly. `yield` inside `with transaction()` commits on a full loop and rolls back on `break`.
- **Native for free:** a `for` over a chain rewrote to a plain `while` and compiled with `ren build`, with no backend work.
- **Cost:** the spike is 875 lines (616 of them the rewrite). The runtime is 118. The full interpreter path is estimated at 1,300–1,900.
- **What doesn't simply fall out:** stage names collide with methods (→ 14b); a value cursor where a block is expected is a type error (→ rule 3 in §5); purity from the inferred row (→ §1); two `&r` heads compile (→ drop the rule).
- **Not built:** closing a named pipeline at scope end, closing on the consumer's failure or cancel, the uniqueness re-check on resume, `for i, x` over a pipeline, native `gen fn`. Messages leak hidden names (`$taken28`, `$frame45`).
- **A pre-existing bug blocks the native work:** `for x in job.rest` over a cursor in a record field crashes lowering on the base commit too. Fix it before native `gen fn`.

## 5. Streams in seven rules

| # | Rule | Reuses |
|---|---|---|
| 1 | **A stream is data or code.** Data is a value with `next` (a value cursor or a library reader), and you can keep it. Code is a block `fn() -> Option<T>` (a pipeline, an effectful generator), and you pass it down. | the bet; decisions 1, 17 |
| 2 | **A `gen fn` call is a value when its parameters are data and its frame holds no instance across a `yield`,** read from the inferred row (no dependency, no `with` open, no `inout`; errors don't count). Otherwise the call is a block whose frame is a hidden local. *Gives:* `gen fn` may take blocks (user stages), `yield` inside `with`, no `gen` operations, no `inout` ban. | decisions 12, 1, 5, 10 |
| 3 | **What `for` takes, a pull parameter takes, written the same way.** A temporary goes as itself, a named data cursor as `&r`, a collection by snapshot, a block as itself. A chain's head follows the same rule. `&` marks a data place, and a block never takes `&`. *Gives:* the `&r` head, the missing-`&` error, sinks taking blocks, `Async.map(xs)` and `Async.map(&r)`, decision 3 (a). | decisions 2, 16 |
| 4 | **A block-typed local has one definition, made here.** `let` binds a literal block, a chain, or a call that gives a block. It can't be chosen with `if`, stored or returned. *Gives:* `Let_chosen`, per-step exclusivity, specialization and push where the chain is written, eager fusion. | decision 1 |
| 5 | **A generator's frame is a scope, like a `with`.** Its `finally` runs when the binding's scope ends, by any exit; a temporary's scope is its statement. Being stopped from outside is `Err(Cancelled)`: shielded, under the cleanup deadline, its result thrown away. Never at a count dropping to zero. | `with`; errors.md; async.md; decision 11 |
| 6 | **A resource belongs to its service; a reader holds `(id, incarnation, offset)`.** A copy reads from where it was copied, or fails, typed. A `with`'s value can't be a cursor of the dependency it installs. The library ships a use-here generator and a keep-form reader. | the bet; decisions 7, 17, 18; strings.md positions |
| 7 | **Waiting is an operation.** Anything that races a timer or a task takes a source whose step is one operation. A task feeding it is on the page (`Async.produce`) and sends through an installed `Send<T>`. `max:` defaults to 64. A pipeline isn't an operation, so it can't be raced. | async.md cancel-safety; decisions 5, 6, 7 |

Removed from the amendments as consequences or as unneeded: two-heads
conflict, the `inout` ban, yield-in-`with` and no-`gen`-operations as
rules of their own, `next(within:)`, three cleanup points, the leased
compile error, and the copy fix-it. Added: the panic on stepping a
cancelled generator (decision 5), and the lookahead warning, which is
advice only.

## 6. Conflicts with decided docs

| Doc / place | Conflict | Change |
|---|---|---|
| foundations.md decision 1 | "a `let` binds one literal block" | "…one block made here: a literal, a chain, or a call that gives a block" |
| foundations.md decision 2, table | no row for a pull argument or `&r` head | add a row: an `&r` head or pull argument writes `r` at each step, held for the call (rule 3). Handler-state row: narrow it once decision 11's check passes |
| foundations.md decision 3 | a description's arguments "can't hold … `next`" | "can't hold a block or an instance". A pure cursor is data |
| foundations.md decision 12 | frames follow `uses`, nothing on `gen fn` kind | add rule 2, read from the inferred row |
| foundations.md decision 13 | — | add: a recursive `yield from` has one depth limit, pushed or pulled |
| strings.md Retention | leased slice: "compile error … `.copy()` fix" | "an ordinary root; debug report; the runtime may copy it out under pool pressure" |
| strings.md help text | `s.chars().count()` against operators.md's `count(f)` | make the predicate optional across the vocabulary, decided in operators.md |
| operators.md | `drop(n)`, `count(f)` | streams adopts `drop`/`drop_while`; operators.md records the optional predicate |
| async.md | `Async.map(xs)` over arrays; `max:` default; `produce`'s `out` | `Async.map` takes any pull argument (rule 3); `produce` installs `Send<T>`; `map_pull` in `produce` shape; no `next(within:)` |
| async.md / decision 6 | channels as values | channels are `Send<T>`/`Recv<T>` dependencies; `Events.items()` derived |
| errors.md | `Cancelled` only for tasks | add: abandonment (`break`, `take`) is `Cancelled` to a generator's `finally`, result thrown away |
| runtime-io.md | leased buffers | the pool may copy a held chunk out; add a pool metric |
| stdlib.md | cursors, layer 3; `ByteCursor.skip` | two forms per resource (`Fs.lines`/`Fs.line_reader`, `Db.query`); readers hold `(id, incarnation, offset)`; `Fs` caches file descriptors; add `merge_by`, `scan`, `dedup_by`, `batch_while`, `Net.frames` |
| language.md §8 | `continues()` tokens | a line starting with `.`, indented further, continues the line above |

## 7. Outline for the revised streams.md

1. **What it has to do.** Properties, with property 2 (cleanup at points the syntax fixes) and "users write their own stages" added.
2. **The seven rules.** §5 above, one example each.
3. **Data: cursors you keep.** The `next` protocol; value cursors from pure `gen fn`s; library readers with `(id, incarnation, offset)`; positions (strings.md).
4. **Code: pipelines.** A chain is a block; `let`, `for`, passing it down; the `&r` head; lookahead; `|>` for user stages; the `.` continuation.
5. **Producers: `gen fn`.** Value or block by rule 2; `yield`, `yield from try`; user stages (`dedup_by`, `merge_by`); `yield` in `with` (program 07).
6. **Stopping.** `break`, `take`, scope end, cancel; `finally(r)`; a cancel mid-step; a race can't step a pipeline.
7. **Errors.** `try` on the `for`; recoverable items as values; the `for`'s error names the stage.
8. **Concurrency and time.** `Async.map`/`each` (`max: 64`, ordered window); `produce` with `Send<T>`; channels and `Events.items()`; time operators over a one-operation source; `Clock`, virtual time, replay.
9. **The library.** Stage list (with the renames); sinks; the two forms per resource.
10. **Cost.** Composed where written; push; recursion on a frame stack; the E3 table; what pulls (`zip`, a non-inlined `next`).
11. **Where Ren stands.** The corrected prior-art claims (amendments §3, plus E3 against Rust and Go).
12. **What it changes, what's given up, later.** §6 above. Given up: storable generic adapters, storing effectful generators. Later: fusion through user stages, `unordered`, broadcast, an erased `Cursor<T>` for N-way merge.
13. **Worked programs:** 01, 06, 07, 08, 11 (the lexer composition), 12.

## 8. Open risks

| Risk | Why it matters | Mitigation |
|---|---|---|
| Closing a named pipeline at scope end isn't built | Decision 3 (a) and rule 5 rest on it | Build it in the interpreter before freezing |
| Narrowing decision 2's handler row may be unsound under service cycles | It changes foundations | Run a FizzBee model or probe first. Until then, actors copy out and back in |
| The panic on stepping a cancelled generator is a new outcome for `next` | It may surprise users | Static race check first; the panic only backstops hidden cases |
| Runtime copy-out of leased chunks | Needs a safepoint and roots that aren't shared; latency spikes | Copy unshared roots only; report it in the pool metric |
| E3 is C models with no reference counting and small generators | Pull rows may be optimistic for real `gen fn`s | Re-measure on Ren's native output once `gen fn` lowers |
| The push control-value protocol (`break`/`return` through the body) is untested | Needed for decisions 8 and 10 | First native `gen fn` test set |
| Replay copies are quadratic for backtracking | The interpreter is slow on program 11 | Snapshot pure frames later |
| `walk.Cursor` naming (E4 seam 8) is still a new namespace form | It's a small new mechanism | Decide with the erased `Cursor<T>` later; keep `walk.Cursor` for now |
| Decision 3 (a) costs readability at the use site (program 13) | A newcomer reads `rs.take(20)` as "the first 20 again" | Hover "steps `rs`"; teach it with `let f = fn() => n += 1` |
| The lowering crash on `for x in job.rest` | Blocks native value cursors | Fix it before native `gen fn` work |
| Chain recognition must be type-directed (the spike matched by spelling) | Collisions with user methods | Rule 14b, chosen by type |

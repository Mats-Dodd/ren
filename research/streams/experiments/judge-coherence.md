# Judge: coherence of the amended streams design after E1, E2 and E4

Inputs: amendments.md (§2 and §4), e1-programs.md, e2-prototype.md,
e4-composition.md. Group A is decided: (1) a pipeline is a block;
(2) calling a `gen fn` follows its signature.

The yardstick: a few decisive rules that compose. A second rule for one
thing is a cost. A rule that falls out of an existing one is the goal.

## 1. Headline

- **Group A holds.** E2 compiled it: every soundness counterexample was
  refused by a check that already exists, and the only checker change
  was 3 lines. E1 wrote 13 programs with no exception to the rules.
  E4 reduced the 38 amendment rules to seven, each of which reuses a
  decision. That is the strongest evidence the owner could get, short of
  shipping it, that "a stream is data or code, and the code kind is a
  block" is one idea and not a mechanism.
- **Two parts of group A are stated slightly wrong** (§2 items 1 and 2).
  Both can be fixed with a sentence, and neither needs a new mechanism.
- **Decision 3: (a), `let g = follow(p)` with no `&`.** E1's tally favours
  `&` at the use site, but both `&` options make a local pipeline spelled
  differently from a pipeline *parameter*. That is two rules for one
  thing (§3).
- **Decision 12 should reverse the amendment.** A leased chunk is an
  ordinary root, and the runtime can copy it out when the pool is under
  pressure. The amendment's compile error needs a provenance analysis that
  no other value has. strings.md's Retention sentence changes with it.

## 2. What the experiments show is wrong

Ordered by how much it matters.

1. **A2 "follows its signature" has to mean "follows its inferred `uses`
   row".** E2 finding 3: `sneaky` had no written `uses` but called
   `print`. It became a value cursor and ran. Stored, it would replay
   outside its `with`. Because of decision 5 a block's dependencies are
   found where it is written, so they aren't in its type. The rule E4
   states, "a frame that holds only data is data", is the correct form.
   It also covers a `with` open across a `yield`, which installs a handler
   instance even when the generator's row is otherwise empty, and an
   `inout` parameter. Errors do not count. A pure `gen fn` with `!
   LexError` is still a value: program 11's `lex` depends on it, and a
   failed `next` is ordinary data flow. E2's "uses and errors" goes too
   far. **Fix:** state A2 as "a call gives a value when everything live
   across its `yield`s is data, read from the inferred row. Otherwise it
   gives a block." Callers stop compiling when a body change adds a use,
   which already happens for any row today.
2. **"Two `&r` heads over one place in one call conflict" is new, not
   derived.** E4 lists it as falling out, but E2 shows it doesn't.
   `both(&r.take(2), &r.take(2))` compiles and is sound, because decision
   2 lets blocks passed to the same call share captures. **Drop the
   rule.** Two closures that capture one `var` and are passed to one call
   behave the same way, so it isn't a special stream hazard. That is one
   less rule.
3. **The interpreter costs about 1,300 to 1,900 lines, not 450**
   (E2). The 450 covers only the runtime (fibers and frames), which came
   to 118 lines plus about 70. The rest goes to recognising and composing
   chains in infer and lower, choosing value or block from the row, the
   coercion, and messages. This is still well under the 2,400 to 4,400
   lines of the draft made sound, so it doesn't change A1. But
   amendments.md and decision 13 should quote the real figure.
4. **The amendment's fix-it "`let c = r` then `&c.map(f)` steps a copy"
   is wrong twice.** `&` on a `let` is illegal (decision 2), so it has to
   be `var c = r`. And it means two things: for a `pread` file reader it
   forks, and for a socket it consumes `r`'s bytes (E4 seam 4). **Fix:**
   drop the second fix-it, or adopt E4's reader `(id, incarnation,
   offset)`, where the service checks the offset so that a stale copy
   fails with a typed error. I'd adopt the offset check. It is decision
   18's incarnation check applied to a position, and strings.md already
   needs the offset as the reader's base.
5. **The push condition "recursion moves to the native stack" breaks
   decision 13** ("cost, never meaning"). A deep tree would overflow when
   pushed and not when pulled. See decision 10.
6. **"An effectful generator is cleaned up at three points" is one rule,
   not three.** E4's rule 5 says a generator's frame is a scope, as a
   `with` is. Abandonment is `Err(Cancelled)`, so the cancel rule applies
   whole and the `finally`'s result is thrown away (E4 seam 9). As
   written, "runs in the consumer's row" suggests a failed rollback after
   `break` reaches the consumer. It doesn't, just as it doesn't after a
   timeout.
7. **A ban on `inout` in a `gen fn` is unnecessary.** Under item 1, a
   place isn't data, so an `inout` parameter makes the call a block, held
   for its binding's scope exactly as `&r.map(..)` is (E4 seam 3). The
   ban, the `yield`-in-`with` rule and the "no `gen` operations" rule all
   become consequences.
8. **A value cursor passed where a block is expected is a type error
   today** (E2 finding 2). It needs a rule, and E4's rule 3 is the right
   one: "what `for` takes, a pull parameter takes, written the same way".
   That one rule covers a temporary, a named `&r`, an array (by
   snapshot) and a block. It replaces three ad hoc coercions, so it is a
   net reduction even though it's new.
9. **Pre-existing bug, not design:** E2 found that `for x in job.rest`
   over a cursor held in a record field crashes lowering on the base
   commit too. It blocks the "value cursors are storable" half of A2 in
   native code, so fix it before native `gen fn` work. Per the
   design-phase rule, it only needs fixing because it blocks a design
   measurement.

Nothing the experiments found contradicts A1. The four "doesn't simply
fall out" items in E2 are spelling-based recognition (a prototype
shortcut), item 8, item 1 and item 2.

## 3. Decision 3: how a named effectful generator is spelled

**Recommend (a): `let g = follow(p)`, then `for l in try g`,
`g.take(20)`, `try g()`. Confidence: medium-high.**

The deciding evidence comes from what A1 already fixed, not from E1's
tally:

- **A local and a parameter must be spelled the same.** A sink is written
  `fn index_all(rows: fn() -> Option<Row>)`, and its body says `for row
  in try rows`, with no `&`, because a block parameter can't take one.
  Under (a), `let g = follow(p)` and a parameter `g` read identically.
  Under (b) or (c), a pipeline gets `&` when it's a local and not when
  it's a parameter. That is two spellings for one kind.
- **Calling a gen fn and writing a chain have to agree.** A1 already
  writes `let errors = &r.map(..)` and then `for e in try errors`. A
  `gen fn` call that uses a dependency is the same kind of thing (A2).
  If (b) or (c) put `&` on `g` but not on `errors`, that's a second rule.
  If they put it on both, you get `&errors` after `&r`, a doubled marker
  that says nothing new.
- **(b) is the first `var`-bound block.** E1 found the semantic cost:
  `g = follow(q)` would have to close a file or roll back a transaction
  at an `=`, which is the drop-time cleanup decision 11 and the
  amendments just removed. Making it "a `var` you can't assign" is a
  special case.
- **(c) gives `&` a second meaning**, "a named stream being stepped", on
  a binding that isn't a place. The draft was marked down for exactly
  this.

**The strongest objection** is E1's use-site evidence. `(b)` read better
in 4 of 6 programs. `&errs.count()` shows that it uses `errs` up, and in
program 13, `rs.take(20)` inside a loop reads as "the first 20 again" to
someone coming from C# or Kotlin. That cost is real. In mitigation, the
compiler never gets it wrong: `c.take(..)` on a named *value* cursor is
an error, so a `.stage` on a bare `let` name is always a block being
stepped. The confusion is a newcomer's, and the lesson is one Ren already
teaches: calling a block twice gives two results (`let f = fn() => n +=
1`). The hover can say "steps `rs`". Do not add a `.next()` method on
blocks; `g()` is what calling a block looks like.

**What (a) shows that (b) hides:** the visible difference between `var r
= Fs.line_reader(p)` and `let g = follow(p)` is real information. You can
keep the first and store it. You can't do either with the second.

## 4. Decisions 4 to 14

| # | Recommend | Reason (evidence) | Strongest objection | Conf. |
|---|---|---|---|---|
| 4 | **`Err(Cancelled)`** in `finally(r)` on abandonment | errors.md already says `Cancelled` means "stopped from outside, only a `finally` sees it". E2 g4/g5 ran it: rollback on `break`, commit on a full loop. Apply the cancel rule whole: the result is thrown away (§2 item 6) | A consumer's `take(10)` is ordinary, but a `finally` that logs "cancelled" will log on every early stop. Precision is lost, and so is the report of a rollback that failed after `break` | high |
| 5 | **A cancel mid-`next` ends the generator; later steps give `None`** | A cancel unwinds the frame through its `finally`s (async.md). A finished generator gives `None`, so no new tag goes in every row. Drop `next(within:)` (E4 seam 7): it's `Async.timeout(d) fn() => &r.next()` over a data reader | **The hole:** `Async.timeout` around one step of a *pipeline* kills it, and the next `g()` returns `None`, which looks like a clean end: silent truncation. Close it with E4 rule 7 ("a pipeline isn't an operation, so it can't be raced"), stated as a check: a racing block can't step a captured pipeline. Without that check, I'd drop to medium-low | medium |
| 6 | **`max:` defaults to 64** | Decision 7 and async.md already say 64. Pulling only when a slot frees bounds memory, so "needs a limit" gave a false reason | 64 concurrent requests to one host is impolite as a silent default (Eth, Erg). That is a library policy question (`Http`'s per-host limit), not a reason for `Async.map` to have two rules | high |
| 7 | **Time operators take a source whose step is one operation** (a channel receiver is the common case); a generator goes on a channel through `Async.produce` | Cancel-safety is a property of operations (async.md). It puts the task on the page, and it is the same fact as 5 and 9 (E4 rule 7) | A line reader whose `next` may take *several* reads (no newline yet) isn't one operation. State that "one operation" is the reader's promise, true of channels and of a `pread` with the partial line kept in the service. Program 08's generator case costs one `produce` line | high |
| 8 | **Put push through one-input stages and eager fusion of pure collection chains in the design now.** Build them with native `gen fn` | Neither adds a language rule. "Later" would mean a second, faster spelling (`.cursor()`), which breaks "the obvious code is the fast code". E2: a `for` over a chain fused natively for free | It costs 400 to 800 more lines on top of 1,300 to 1,900, and the push twin's control-value protocol for `break` and `return` is untested. "In the design" is cheap. Building it is real work | high (design), medium (schedule) |
| 9 | **The producer sends through an installed `Send<T>` dependency** | Decision 5: "those listed in its parameter's type, which the callee provides". An `out` value is a held channel instance, against the bet | It depends on channels being `Send<T>` and `Recv<T>` dependencies (decision 6). If that split isn't settled, `produce` and the time operators (7) have to move together | high |
| 10 | **Push only non-recursive producers at first.** When push takes recursion, it goes on the task's frame allocator, never the native stack | Decision 13: push and pull must fail the same way. Pulled recursive `yield from` is boxed on the heap. The amendment's "recursion moves to the native stack" is wrong (§2 item 5) | `walk_dir` (05), the commonest recursive generator, pays O(depth) per item until then. That is a cost difference, which is allowed, not a meaning difference | high |
| 11 | **Narrow decision 2's handler-state row** to `Async.until`, `release` and block-parameter calls | The row predates decision 10, under which an operation keeps its instance until it returns, so a dependency call can't re-enter and change this handler's state. Program 09 needed copy-out, copy-back without it, and so does every actor that keeps a reader | It amends foundations, not streams. It needs a soundness check that no cycle of services (A calls B, B calls A) can re-enter A. Under decision 10 that cycle waits or errors, but confirm it with the model checker or a probe before changing decision 2 | medium |
| 12 | **A leased chunk is an ordinary root** (decision 17): debug report, `ren review` advice, a pool metric, and the runtime moves a held chunk's bytes to the heap under pool pressure. Change strings.md's Retention sentence | The amendment's compile error needs provenance tracking that exists for no other value. strings.md's own rule is "write `.copy()` on what you keep; debug reports". Value-relative positions make the move invisible. Program 02's pool can no longer stall | It reverses a sentence decided today, and it is "a copy behind your back" with a latency spike at an unpredictable time. strings.md already allows "what the compiler may do without telling you", and the alternative is a stalled server | medium |
| 13 | **One-shot fibers for effectful generators** in the interpreter; **replay to copy pure value cursors** for now | E2 built both in 118 lines of `eval.ml`, and g1 to g5 pass. It is the compiler's choice, and replay is deterministic because the cursor is pure | Replay costs O(position) per copy. Program 11's backtracking parser (`let saved = p` per statement) becomes quadratic in the interpreter. That's acceptable for a debugging tool, but note it, and give pure frames a snapshot later | high (fibers), medium (replay) |
| 14a | **Choosing between pipelines with `if` is an error** with "choose inside one block" | E2: `Let_chosen` already fires | Tag dispatch may be wanted later, and it can be added if needed | high |
| 14b | **Reserve stage names on cursor types**, keyed by type ("has `next`"), not by spelling, **with E4's renames** (`skip` to `drop`, `chunks(n)` to `batch(n)`, `split_lines` to `lines`, one `count`) | E2 test_ops shows the collision. operators.md already says `drop`. The rename also frees `ByteCursor.skip` | The `count()` and `count(f)` question is still open. Pick one. I'd allow an optional block on vocabulary methods once, for all receivers, rather than a second name | medium-high |
| 14c | **Document lookahead loss and add a `ren review` warning**, with no `peek` stage | `&` means "this is the cursor"; what a stage consumed is gone, as with any write. E1 program 09: silent loss across pages between a stored reader and `take(n)`. The compiler knows which stages look ahead | It is a warning, not a guarantee: a user `gen fn` that looks ahead has to be marked or inferred | high |
| 14d | **An N-way merge uses data readers for now** | Rule 1: an `Array` holds data. E4's erased `Cursor<T>` (decision 4's dispatch) can come later for a uniform array | It is one of the "Later" items a storage engine wants first | high |

## 5. E1's other findings, judged

- **"User stages can't be dotted" is not a seam.** language.md §8
  already decided `.` for the receiver's own vocabulary and `|>` for
  everyone else's functions, and collections work the same way. `lex(src)
  |> semis` is the composed spelling. Adding extension methods would be
  the special case. Most of the lexer's "worse" result is `byte_len`
  bookkeeping, and `Str.Chars.at()` fixes that.
- **Two library forms (`Fs.lines` as a generator, `Fs.line_reader` as
  data) are the bet's split, not "two of everything".** Code is for use
  where you are, data is for keeping. Name the generator form for the
  call people write first. Combine it with E4's "a reader never owns its
  resource" (file readers hold a path and an offset; `Fs` caches file
  descriptors with a `max:`). A kept reader then can't leak a file
  descriptor. A database cursor, which really does hold server state,
  should ship only in generator form, and be kept as a position you query
  again from.
- **"Wrapping a pipeline in a pure, value-taking `gen fn` makes it a
  value again" (program 11) is the best sign that A2 composes.** Keep it
  as a worked example in streams.md. It depends on item 1 in §2:
  `tokens` is a value because its frame holds only a `Str` and a
  value-cursor frame.
- **A `for` holds its reader, so a body that needs the offset has to step
  by hand** (program 12). This is consistent with strings.md's refusal of
  `for at, x`. Teach the idiom (`frames.at()` with `while`); don't add a
  form.
- **E1's `PROPOSAL:` library names** (`Bytes +=`, `Format<T>` as a value,
  `Net.read(max:)`, `frames.at()`, `Str.Chars.at()`, `ByteCursor.str(n)`,
  `Fs.line_reader(follow:)`, `read_str()`, `Str.Chars`) are all library
  surface that follows existing naming. `Bytes +=` should match `Str`.
  The one language change, a format length that bounds the frame (`len:
  UInt32 = rest`), belongs to formats.md and should be judged there.

## 6. Net rule count after this judgement

Seven rules (E4 §1), with these edits:

- rule 2 reads its answer from the inferred row;
- rule 3 is the single coercion;
- rule 5 includes the thrown-away result.

Removed from the amendments: two-heads-conflict, the `inout` ban,
yield-in-`with` as its own rule, `gen` operations as their own rule,
`next(within:)`, three cleanup points, the leased-slice compile error,
and the copy fix-it. Added: the "can't race a pipeline" check (decision
5) and the lookahead review warning (14c, advice only).

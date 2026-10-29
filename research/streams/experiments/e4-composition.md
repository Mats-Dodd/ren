# E4: composition audit of the amended streams design

Input: amendments.md §2 with group A decided (a pipeline is a block; a
`gen fn` call follows its signature). Checked against foundations.md
(decisions 1–19 and the bet), language.md §3 and §8, async.md
(cancellation, `Async.map`), errors.md, runtime-io.md (leased buffers),
stdlib.md (cursors, layer 3), operators.md (the collection vocabulary)
and strings.md.

The yardstick: each rule should be an existing rule applied, not a new
one. Verdicts: **falls out** (an existing rule already implies it),
**generalize** (a stream-only rule that should be stated once for the
whole language), **seam** (two rules for one thing, or streams and
another doc disagree), **new** (a real addition; say what it buys).

## 1. Ren streams in seven rules

Everything in amendments.md §2 follows from these seven, plus rules
that already exist (errors as `Result` items, `try`, `Clock`). Each one
reuses a decision; none is a mechanism only streams have.

1. **Code flows down, data flows anywhere** (the bet). A stream is one
   of two things. *Data* is a value with `next`: a value cursor or a
   library reader, which you can keep. *Code* is a block,
   `fn() -> Option<T>`: a pipeline or an effectful generator, which you
   pass down. There is one protocol, and the split is the bet's own
   split. *Reuses: the bet, decision 1, decision 17 ("a cursor is a
   value holding a slice").*

2. **A frame that holds only data is data.** Calling a `gen fn` gives a
   value when everything live across its `yield`s is data. If it uses a
   dependency, takes a block or a place, or has a `with` open across a
   `yield`, the call gives a block whose frame is a hidden local of the
   caller. *Reuses: decision 12 (frames follow `uses`), decision 1 (a
   value can't hold a block), the bet (no stored instances).* This is
   decided rule (2) stated by its reason. It also *derives* three
   amendments that are listed as separate rules today: "a `gen fn`
   can't take `inout`", "`yield` inside `with` only for effectful
   generators", and "a handler operation can't be `gen`" (decision 10:
   an operation keeps its instance until it returns).

3. **What `for` takes, a pull parameter takes, written the same way.**
   A temporary goes as it is. A named cursor needs `&` (it's stepped,
   which is a write of it for the interval). A collection goes by
   snapshot. A block goes as it is. A chain's head is written the same
   way. *Reuses: decision 2's `&p` row and decision 16.* It derives the
   `&r`-head rule, the missing-`&` error on named places only, "two
   `&r` heads conflict", "sinks take `fn() -> Option<T>`",
   `Async.map(xs)` over an array next to `Async.map(&r)`, and
   decision 3 below. **`&` marks a data place; a block never takes
   `&`.**

4. **A block-typed local has one definition, written here.** `let`
   binds a literal block, a chain, or a call that gives a block. It
   can't be chosen with `if`, stored or returned. *Reuses: decision 1
   and the reason behind it: one definition site is what lets release
   builds specialize a block without flow analysis.* It derives
   "pipelines can't be stored", `Let_chosen`, per-step exclusivity (the
   existing rule for a `let`-bound block), push and fusion where the
   chain is written, and eager fusion of pure collection chains. All of
   these are the compiler's work, not new rules.

5. **A generator's frame is a scope, as a `with` is.** Its `finally`
   runs when its binding's scope ends, by any exit. A temporary's scope
   is its statement. Being stopped from outside is `Err(Cancelled)`,
   and the `finally` is shielded and under the cleanup deadline. It
   never runs at a count dropping to zero. *Reuses: the `with` rule,
   errors.md ("only a `finally` sees `Cancelled`"), async.md
   (shielding, deadline), decision 11.* The amendment's three cleanup
   points (`break` over a temporary, end of scope, cancel) are this one
   rule, seen three ways.

6. **A resource belongs to its service; a reader holds
   `(id, incarnation, offset)`.** A copy of a reader is a second reader
   at the same position. Reading from a position the service has moved
   past fails with a typed error, as using a stale incarnation does.
   The offset is the reader's base for reports (strings.md, Positions).
   *Reuses: the bet's instance half, decision 18 (incarnations),
   decision 7 (static check where the nesting is visible, run-time
   check where it isn't), strings.md (`from:` and `at`), decision 17
   (a leased chunk is an ordinary root).*

7. **Waiting is an operation.** Anything that races a timer or another
   task takes a source whose step is one operation: a channel's `recv`,
   or a reader's `next`. Every operation is already cancel-safe
   (async.md). A task that feeds such a source is on the page,
   `Async.produce`, and its sending is a dependency installed for its
   block, `Send<T>`. Concurrency is bounded by `max:`, default 64.
   *Reuses: async.md (operations are cancel-safe), decision 5 ("those
   listed in its parameter's type, which the callee provides"),
   decision 7 (`max:` 64).* It derives the time operators' shape,
   `map_pull` becoming `produce`-shaped, `Events.items()`, and why a
   pipeline can't be raced: a pipeline isn't an operation.

Two sentences carry the whole design: **a stream is data or code, as
everything in Ren is; and the code kind is a block, so the block rules
are the stream rules.**

## 2. Every rule, and how it composes

| # | Rule (amendments §2) | Composes with | Verdict |
|---|---|---|---|
| 1 | Cursor protocol: `next(inout self) -> Option<T>`, `for x in &c` | stdlib.md, decision 2 | falls out (exists) |
| 2 | A pipeline is a block, composed where written | decision 1 | decided; falls out |
| 3 | `let` binds "one literal block or one chain" | decision 1 | **generalize**: "one block made here", which covers effectful `gen fn` calls too (§3, seam 1) |
| 4 | Pipelines can't be stored, returned or chosen with `if` | decision 1, `Let_chosen` | falls out |
| 5 | `&r.map(f)` steps `r`; bare `r.map(f)` on a named cursor is an error; a temporary head needs no `&` | decision 2 `&p` row | falls out of seven-rules rule 3, but the fix-it is a **seam** (seam 4) |
| 6 | Two `&r` heads over one place in one call conflict | decision 2 | falls out |
| 7 | Sinks take `fn() -> Option<T>`; no `next` requirement | language.md §3 | falls out; needs rule 3 to say how an array or `&r` is passed (seam 2) |
| 8 | Stage vocabulary belongs to the pull type; stage names reserved on cursor types | operators.md, stdlib layer 3 | **seam** (seam 5) |
| 9 | Eager pure collection chains fuse | strings.md property 5 | compiler's business; falls out |
| 10 | Exclusivity per step = the `let`-block rule; a pipeline passed to a call holds captures for the call | decision 2 | falls out |
| 11 | A `.` line indented further continues | language.md §8 `continues()` | falls out: one more token beside `|>`, `uses`, `!`, `,` |
| 12 | `gen fn` call follows the signature | decision 12 | decided; state it by its reason (seven-rules rule 2) |
| 13 | Value cursor type is named `walk.Cursor` | none | **new** naming form (seam 8) |
| 14 | Effectful generators: deps found where the frame is made | decision 5 | falls out |
| 15 | A `gen fn` may take a block | decision 12 (amends it) | falls out of rule 2 |
| 16 | `yield from try child(..)`; box only recursive `yield from` | errors.md, decision 14 | falls out / compiler |
| 17 | Push through one-input stages, with stated conditions | decision 13 ("cost, never meaning") | compiler; one meaning-level condition (decision 10 below) |
| 18 | An `&` held across a `yield` re-checks uniqueness on resume | decision 2's hoisted check | falls out if stated as "a `yield` ends the interval a check is hoisted over" |
| 19 | A `gen fn` can't take `inout`; a handler op can't be `gen` | decision 10, rule 2 | **derive**: `inout` makes the call block-kind instead of being banned (seam 3) |
| 20 | `finally(r)` sees `Ok` / `Err(e)` / `Err(Cancelled)` | errors.md, async.md | falls out (decision 4) |
| 21 | A cancel mid-`next` ends the generator; service cursors offer `next(within:)` | async.md | first half falls out; `next(within:)` is a **special case** (decision 5 below) |
| 22 | Cleanup at three points; shielded; deadline; consumer's row | decision 11, `with` | **collapse** to one rule (seven-rules rule 5); the "consumer's row" clause needs the cancel rule's "a `finally`'s result is thrown away" stated for abandonment |
| 23 | Backstop: handles register with their handler | decision 11, the bet | falls out (the service owns the resource), but see seam 6 on leaks |
| 24 | Resource cursors hold ids and offsets | the bet, strings.md positions | falls out; **seam** on copies (seam 4) |
| 25 | Ids carry incarnation → typed `Closed` | decision 18 (`docs[DocId(7)]#3`) | falls out |
| 26 | With-escape: a `with`'s value can't be a cursor type of the dep it installs | decision 7 | falls out: decision 7's own two tiers (static where visible, run time where hidden) |
| 27 | `Net.frames(conn, fmt)` | strings.md (library cursors carry their base) | falls out |
| 28 | `yield` only in the generator's own body, never in a `fn` literal or `finally` | decision 1 (a block can't suspend the generator around it) | falls out; one syntactic rule covers `Async.scope`, `retry`, `timeout` |
| 29 | Operation parameters can't take a pipeline | decision 10 | falls out |
| 30 | `Async.produce` with a `Send<T>` dependency | decision 5, decision 6 | falls out (decision 9 below); unify with time operators (seam 7) |
| 31 | `Async.each` / `map`: ordered window, pulled on the caller's task, `max:` | decision 7, rule B | falls out |
| 32 | `map_pull` in `produce` shape | rule 7 | falls out |
| 33 | Channels: compiler-derived `Events.items()` | decision 7's "functions the compiler derives for each dependency" | falls out (precedent: `call.args` encoders) |
| 34 | Time operators take a channel receiver | async.md cancel-safety | falls out, **generalize** to "a source whose step is one operation" |
| 35 | Stdlib adds `scan`, `dedup_by`, `chunk_while`, `Net.frames` | operators.md names | **seam** on names (seam 5) |
| 36 | Narrow decision 2's handler-state row | decision 10 | falls out (decision 11 below) |
| 37 | Lookahead loss documented | `&` semantics | falls out |
| 38 | Leased slice kept past its turn: compile error + `.copy()` | strings.md Retention, decision 17 | **seam** (seam 6) |

## 3. Seams, with the smallest unification and its cost

### Seam 1. `let` binds "a literal or a chain": a list that will keep growing

Decision 1 says "a `let` binds one literal block". The amendment adds
"or one chain", and decided rule (2) silently adds a third case,
`let g = follow(p)`. The reason behind all three is the same: a local
block has exactly one definition the compiler can see.

- **Unify:** decision 1 becomes "a `let` binds one block made here: a
  literal, a chain, or a call that gives a block". `Let_chosen` is the
  only refusal.
- **Cost:** none. It's one sentence, and it's the reason decision 1
  gives already.

### Seam 2. How does an array, a named cursor or a pipeline reach a parameter `fn() -> Option<T>`?

Sinks take a block (rule 7), but async.md writes `Async.map(xs)` and
`Async.map(page.links)` over arrays, the amendment writes `index_all`
over a pipeline, and nothing says what `index_all(r)` or
`index_all(&r)` does with a named cursor. Without a rule, these become
three ad hoc coercions.

- **Unify:** seven-rules rule 3: an argument to a pull parameter is
  written as it would be after `for ... in`. `&r` is the block
  `fn() => &r.next()`, holding `r` for the call, which is decision 2's
  `&p` row unchanged. An array goes by snapshot, as `for x in xs` does.
- **Cost:** one rule, and it replaces three. Coercing a collection to a
  block is the one implicit step. It's the same one `for` already
  takes.

### Seam 3. `inout` on a `gen fn` is banned, but the `&r` head is exactly that

The amendment bans `inout` parameters on `gen fn`s. Yet `&r.map(f)`,
the built-in stage, is a block-kind generator holding a place for its
binding's scope. A user stage that wanted the same thing would take
`inout src: Reader`, which is refused, and has to take a block
instead. That works, through seam 2, but the ban is a second rule
where rule 2 already gives the answer.

- **Unify:** a place is not data, so an `inout` parameter makes the
  call block-kind, held for the binding's scope as `&r` is. The ban
  remains only for value cursors, where rule 2 already gives it.
- **Cost:** none in the checker, since it's the `&r`-head interval.
  Optional: you can simply keep the ban, because seam 2 gives users
  the same power through a block parameter.

### Seam 4. "Steps a copy" means two things, now in the fix-it

The amendment fixes program 06's trap, where the same text means two
things depending on how the cursor stores its state. But the second
fix-it for bare `r.map(f)` reintroduces the trap: "`let c = r` then
`&c.map(f)` steps a copy". For a `pread` file reader that's an
independent reader. For a socket reader it consumes the socket under
`r`. The amendment admits this ("the hazard is aliasing").

- **Unify:** a resource reader holds `(id, incarnation, offset)`, and
  the service checks the offset. A file reader's offset is a `pread`
  position, so a copy really forks. A socket reader whose offset is
  behind the connection's fails with a typed error (`Moved`, or reuse
  `Closed`), exactly as a stale incarnation does. "A copy reads from
  where it was copied, or fails, typed" then holds for every cursor.
  This is decision 18's incarnation check, applied to the position.
- **Cost:** one compare per `next` in the service, and one tag in
  socket readers' rows. The offset is needed anyway, because strings.md
  says library readers carry their base for `at`. The offset is that
  base.

### Seam 5. The vocabulary disagrees with operators.md and layer 3

- **`skip` against `drop`.** operators.md decided `take(n)`, `drop(n)`
  on collections ("one name for each"). streams' stages say `take`,
  `skip`, `skip_while`. "One vocabulary, two receivers" breaks on its
  second word.
- **`skip` against `ByteCursor.skip(n)`.** Layer 3's
  `try &c.skip(n)` is a fallible read. If the byte cursor ever gets a
  `next`, then "stage names are reserved on cursor types" refuses it.
- **`count()` against `count(f)`.** operators.md has `count(f)`.
  strings.md's error help writes `s.chars().count()`, so streams need
  `count()` with no block. That's two arities for one name.
- **`chunks(n)` against `Net.chunks(conn)`.** These are two meanings of
  one word, and the timed `batch(max:, within:)` is a third name for
  grouping.
- **`split_lines` against `lines`.** The draft's generator writes
  `chunk.split_lines()`, but strings.md's API is `lines`.

**Unify:** rename the stages `skip` and `skip_while` to `drop` and
`drop_while`. That fixes both of the first two items, and the
reservation then touches no existing member. Make `count(f)` the only
form, so the help becomes `s.chars().count(fn(_) => true)`. Or, if
that reads badly, decide that a block parameter may be optional, once,
for every vocabulary method. Use `batch(n)`, `batch_while(f)` and timed
`batch(max:, within:)` for grouping, and keep `chunks` for leased byte
chunks. Use `lines` everywhere. **Cost:** renames only. The stage list
in streams.md and two lines in strings.md change. Whether the
reservation is needed at all depends on method resolution: if a type's
own member shadows the vocabulary, the reservation is unnecessary but
`r.map` becomes ambiguous to a reader. Keep the reservation; the
renames make it collision-free today.

### Seam 6. Leased chunk retention: strings.md already decided streams' open decision 12

strings.md's Retention says that a slice of a leased chunk "follows the
streams rule: a compile error with a `.copy()` fix where the keep is
visible, and a debug report where it isn't". So decided text points
at an undecided rule. The compile error is the one place where `Bytes`
would need to know where its bytes came from: a provenance analysis
that exists for no other value. strings.md's own general rule for
retention is "write `.copy()` on what you keep; debug reports; no
automatic rule".

- **Unify (the version that falls out):** a leased chunk is an
  ordinary root (decision 17). Retention is the same trap, with the
  same remedy and the same debug report, plus a pool metric. When the
  pool runs dry, the runtime may move a held chunk's bytes to the heap
  and give the slot back. strings.md made that invisible: positions
  are relative to the value, and no program holds an address. A leased
  root is already a header that points at pool memory, so the move is
  one `memcpy` and one pointer swap, on unshared roots only.
- **Cost:** one sentence in strings.md changes, and it reverses the
  amendment's "a copy found behind your back" objection. strings.md
  already allows exactly that ("what the compiler may do without
  telling you"). A runtime fallback replaces a compile error. You can
  still keep the error as `ren review` advice (language.md §10), which
  is where advice lives.
- **Leak corollary (rule 23):** a stored data reader that's never
  closed holds its fd until its handler's `with` ends. Decision 11
  forbids closing it at a drop. Under seven-rules rule 6 the fix falls
  out: a file reader holds a path and an offset, and `Fs` keeps an fd
  cache with a `max:`, as `actors` does. A socket reader's id belongs
  to the task serving the connection. A reader never owns its
  resource.

### Seam 7. Three special shapes for "waiting on a source"

`next(within:)` on service cursors, time operators "taking a channel
receiver", and `Send<T>` for `produce` are each stated alone. They are
one fact: an operation is cancel-safe, and a pipeline isn't one.

- **Unify:** seven-rules rule 7. A time operator takes any data cursor
  whose `next` is one operation. A channel receiver is the common case,
  and `Fs` and `Net` readers also qualify. `next(within:)` is
  `Async.timeout(d) fn() => &r.next()`, which is already cancel-safe.
  If channels become `Send<T>` plus `Recv<T>` (decision 6), then
  `produce` installs one and time operators read the other.
- **Cost:** you drop one method (`next(within:)`), and the
  heartbeat-with-timeout idiom gets one line longer.

### Seam 8. Naming a value cursor's type, `walk.Cursor`

This is a new namespace form, a type scoped under a function, and
nothing else in Ren has one. The nearest precedent is decision 3's "an
enum the compiler writes".

- **Smallest:** keep `walk.Cursor` and say it's the one place a
  function names a type. Or reuse decision 4's lowering for an erased
  `Cursor<T>`: the closed set of pure `gen fn`s yielding `T`, dispatched
  as a description is. That also gives the "later" N-way merge,
  `Array<Cursor<Entry>>`.
- **Cost:** the erased form adds a dispatch per `next`, reported as
  dispatch is. **Watch:** decision 3 says a description's arguments
  "can't hold ... `next`". Under R a pure cursor is data whose copy is
  an honest fork, so that ban needs restating as "can't hold a block
  or an instance" (a reader's id is data, and the with-escape rule
  covers it). Otherwise a handler can't be configured with a cursor
  over its seed data.

### Seam 9. Two exits, two error policies

For a task, a `finally` that runs because of a cancel has its result
thrown away (async.md). For abandonment at `break`, the amendment says
cleanup "runs in the consumer's row", which suggests a failed rollback
reaches the consumer.

- **Unify:** abandonment is `Err(Cancelled)` (decision 4), so the
  cancel rule applies whole: the `finally` still runs its calls, and
  its result is thrown away. "Consumer's row" means only the `uses`
  row. On a normal end, the `finally`'s errors go through the `for`'s
  `try`, as usual.
- **Cost:** a rollback that fails after `break` isn't reported, just as
  it isn't after a timeout. That's consistent, and it's the existing
  behaviour.

### Where strings.md and streams agree (no seam)

- **Value-relative positions and `cursor(from:)`.** A user framing
  generator carries `base` in a `var` and makes
  `buf.cursor(from: base)`; library readers carry it. Errors' `at`
  stays for reports.
- **`chars()` yielding `Str`.** It's a pure library value cursor:
  `for c in s.chars()` is a temporary head, `let cs = s.chars()` then
  `for c in &cs` steps it, and `s.chars().count(..)` is a chain with a
  sink. Rules 3 and 4 cover it with nothing added.
- **`+=` in place.** A stage that captures `out` reads it only at its
  step, so `out` is unique at the body's `+=`. A generator that yields
  slices of a buffer it keeps appending to makes that buffer shared,
  and the next `+=` copies. strings.md's debug report ("a `+=` in a
  loop that copied because its string was shared") already names this.
  It's worth one example in streams.md.
- **`try` reach.** In a `.` chain, a step's `try` sits inside its
  block. The head's `try` is errors.md's normal reach. Neither one
  conflicts with `|>`'s per-link `try`.

## 4. Open decisions 3–14: which option falls out

| # | Decision | Falls out | Adds a rule | Why |
|---|---|---|---|---|
| 3 | Spelling of a named effectful generator | **`let g = follow(p)`, `for l in try g`** | `var g` + `&g` | Rule 3: `&` marks a data place, and a block never takes `&`. It reads exactly like `let errors = &r.map(..)` then `for e in try errors`. `var g` breaks decision 1 ("blocks can't be bound with `var`") and makes `&` mean two things. Resuming after `break` works the same, since the frame is a local. The visual difference from `var r = Fs.line_reader(p)` is the information: one you can keep, one you can't. |
| 4 | Abandonment in `finally(r)` | **`Err(Cancelled)`** | `Stopped` | errors.md: `Cancelled` is "stopped from outside, only `finally` sees it". A `break` is that. `Stopped` adds a tag and makes every rollback match two. Add seam 9's clarification. |
| 5 | Cancel mid-`next` | **ends; later `next`s give `None`** | typed `Ended` | A cancel unwinds the frame through its `finally`s (async.md), and a finished generator gives `None`. `Ended` adds a tag to every row. Drop `next(within:)` (seam 7). |
| 6 | `max:` default | **64** | required | Decision 7 and async.md already say 64. Required means amending both. (Actors' required `max:` is a different reason: an unbounded set of instances.) |
| 7 | Time operators' shape | **a source whose step is one operation** (channel receiver) | consumer-block shape | Cancel-safety is a property of operations (async.md), and rule 7 puts tasks on the page. The block shape hides a task and is the only place a stream operator would open one. |
| 8 | Push and eager fusion now | **now** | Later, with `.cursor()` as a documented fast path | Neither adds a language rule. "Later" adds a second, faster spelling, which breaks strings.md's "the obvious code is the fast code". |
| 9 | `produce`'s producer sends through | **an installed `Send<T>`** | `out` value | Decision 5: "those listed in its parameter's type, which the callee provides". `out` is a held channel instance, against the bet. |
| 10 | Pushed recursion | either (staging) | none | Decision 13's "cost, never meaning" fixes the invariant: push and pull must have the same depth behaviour. Pull-first is fine as staging. When push takes recursion, it goes on the task's frame allocator (decision 12), never the native stack, or a deep tree would overflow only when pushed. |
| 11 | Narrow decision 2's handler-state row | **yes** | keep | The row predates decision 10. An operation keeps its instance and calls only outward handlers, so a dependency call can't re-enter. Only `Async.until`, `release` and block-parameter calls can let state change. Keeping it is the special case. |
| 12 | Leased slice kept | **an ordinary root (decision 17) + debug report; runtime copy-out under pool pressure** | compile error by provenance | See seam 6. Note that strings.md already chose the compile error, so either way one doc changes. |
| 13 | Interpreter generators | either | none | This is the compiler's choice. Replaying to copy a pure cursor is deterministic because it's pure. |
| 14a | `if` between pipelines is an error | **yes** | — | Decision 1, `Let_chosen` |
| 14b | Stage names reserved on cursor types | yes, with the renames in seam 5 | — | Collision-free once `skip` becomes `drop` |
| 14c | Lookahead loss documented | **yes** | a `peek` stage | `&` gives the cursor; what the stage consumed is gone, as for any write |
| 14d | N-way merge over data readers | **yes** | — | Rule 1; seam 8's `Cursor<T>` if a uniform array is wanted |

**Count.** For 3 to 9, 11 and 14, one option falls out of an existing
rule and the other adds one. 10 and 13 are the compiler's business, and
the invariant for 10 is decision 13's. Decision 12 is the one where
the amendment's recommendation adds a mechanism, and it's also the one
already pre-empted by strings.md.

## 5. Net changes this audit proposes beyond amendments.md

1. State decided rule (2) by its reason: "a frame that holds only data
   is data". Delete the separate `inout`, `yield`-in-`with` and `gen`
   operation rules as consequences.
2. Add rule 3 ("what `for` takes, a pull parameter takes"). It replaces
   three coercions.
3. Collapse the three cleanup points into "a generator's frame is a
   scope". Apply the cancel rule's thrown-away result to abandonment.
4. Readers hold `(id, incarnation, offset)` and the service checks the
   offset, so "a copy" means one thing. File readers hold a path, and
   `Fs` caches fds with a `max:`.
5. Rename `skip`/`skip_while` → `drop`/`drop_while`, `chunks(n)` →
   `batch(n)`, `chunk_while` → `batch_while`, `split_lines` → `lines`.
   Settle `count()` against `count(f)`.
6. Drop `next(within:)`. Time operators take any source whose step is
   one operation.
7. Settle leased retention in one place: either strings.md's sentence
   stands (a compile error, new provenance analysis) or it becomes
   "an ordinary root, copied out by the runtime under pool pressure".
8. Restate decision 3's "a description can't hold `next`" as "can't
   hold a block or an instance".

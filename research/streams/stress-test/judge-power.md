# Judge: power, soundness and cost

Lens: does streams.md cover what real programs need (servers, storage
engines, CLIs, the compiler itself) without escape hatches; is every rule
sound under foundations.md; what does it cost to build and to run.

Inputs: streams.md (draft, not decided), probe-soundness, probe-feasibility,
probe-ethos, probe-prior-art, alt-1 (what a pipeline is), alt-2 (what a
generator cursor is), programs 01 to 10. Cross-checked against
foundations.md decisions 2, 7, 11, 12 and "What's given up".

## Verdict in one paragraph

The draft picks the right shape: one kind of stream (the cursor), no
colours because of `uses`, `gen fn` as the producer, `Clock` for time, a
small library, no hot streams, no schedulers. Its two load-bearing
mechanisms don't survive as written, though. **Pipelines as "a value that
holds a block"** need a kind on type variables, a `next` requirement with
an associated type and two associated rows, a new debug layout and a new
specialization key: about 2,400 to 4,400 lines of high-risk work (alt-1
A), and without the kind it is unsound (probe-soundness 2a and 2b). And
**cleanup at a drop** contradicts decision 11 outright, runs at a point
Perceus picks, runs twice on copies, and can't be built (no drops in the
interpreter, no evidence or error channel in `ren_drop`). Both have a fix
that is *smaller* than the draft and *more* powerful: **a pipeline is a
block** (alt-1 B), and **a generator that uses a dependency, or takes a
block or `&`, is a frame, block-kind, cleaned up at syntactic points;
a pure one is a storable value** (alt-2 R). Together they delete the
`next` requirement, the type-variable kind, the drop rule, relative
addressing for most generators and the interpreter's Core state machine,
and they add user-written lazy stages, `merge_by`, and yield inside a
transaction, which the draft can't express. The remaining power gap is
narrow and named: a stream over a resource that must be *kept* (in a
record, an array, actor state, across requests) is written as a data
cursor (ids and offsets, a `next` method), not a generator.

## Power check: the four kinds of program

Read against the recommended design (B + R), not the draft.

| Program kind | Need | Covered? |
|---|---|---|
| Server | accept loop with a bound, per-connection framing, per-item timeout, cleanup on disconnect | Yes. `Async.each(listener.connections(), max:)`, `Net.frames(conn, fmt)`, `Async.timeout` inside the block, frame cursors closed at the end of the handler's scope. Open: leased chunks pinned by kept slices can drain the pool and stall the server (programs/02 item 3). |
| Server | per-client stream kept across requests (paging, subscriptions, replication followers) | Yes, as a data cursor in handler state (programs/09's `Tail`, about ten lines), not a generator. Needs the narrowed handler-state row (see Concurrency) to step it without a copy-out dance. |
| Storage engine | range scan, k-way merge of memtable plus N SSTables, compaction in a task | Two inputs: `merge_by` as a user `gen fn` over blocks (alt-1 P2). **N dynamic inputs:** blocks and frames can't sit in an `Array`, so the merge takes `Array<SstReader>` (a data cursor) or an ADT of source kinds. A scan *returned* to a caller is a data cursor or a block-taking function. Compaction creates its generators inside the spawned task. No escape hatch, but the generator stops being the tool once the stream is kept or counted dynamically. |
| CLI | lines, CSV, directory walk, tail, early stop | Yes, and Ren reads best here (programs/01, 05, 06). |
| The compiler itself | a lexer stored in a parser record, peeking, pure passes over arrays | Yes. A pure `gen fn` lexer is a value cursor and can be a field (`lex.Cursor`). Eager array chains in passes should fuse (see "One vocabulary, two receivers"), or the obvious pass is the slow one. |
| Transaction-scoped streams | rows read inside a transaction, consumer can `break` and roll back | The draft refuses it (`yield` inside `with`); R allows it, with rollback from `finally(r)` seeing `Err(Cancelled)` (programs/07). |
| Time | debounce, batch, throttle over arbitrary sources, tested under `sim` | Only if the operators take the consumer-block shape or a channel source (probe-prior-art F1, programs/08). As written, unbuildable over a pipeline. |

## Section by section

### What it has to do — keep, amend two items

- Keep 1, 3, 4, 6, 7, 8.
- **Property 2 (cleanup exactly when the consumer stops)** is true only for
  a temporary. For a named cursor the draft's own first example makes
  `break` resumable. Change to: "cleanup when the consumer stops: at the
  end of a `for` over a temporary, at the end of the scope of the binding
  for a named one, and on cancel. Never at a drop." (alt-2 R.)
- **Property 5** ("no yielding from inside a concurrency scope") becomes the
  general rule under Producers below.

### Where Ren stands — change (claims), no design impact

Not this judge's lens beyond one point: the table promises things the
mechanisms under it don't deliver as written (cleanup on `break` for named
cursors, "allocates nothing" for helpers consumed by `.take`). Rewrite it
after the mechanisms are settled. Prior-art corrections are in
probe-prior-art (Kotlin isn't one-kind; deterministic time isn't unique,
replay from production is; RFC 3550's lesson is that iterators shouldn't be
copyable).

### One kind of stream: the cursor — keep, with two changes

- **Keep** the cursor as `next(inout self) -> Option<T>`, structurally
  reached by `for`, failing and using dependencies in its row. That's the
  10c restriction lifted, 150 to 300 lines, low risk (probe-feasibility).
- **Change:** "one kind" bends once, honestly. A generator's cursor is a
  *frame* (scoped) or a *value* (storable), decided by its signature (alt-2
  R). It's the same split decision 12 already makes for suspension, so
  it's one line drawn twice, not a new axis. Say so in the doc.
- **Keep** "backpressure is implicit". Add the leased-buffer caveat: a slice
  kept past the body's turn pins its chunk (programs/02 item 3). Decide:
  copy out at the keep point, or a debug error. (Open; runtime-io's call.)

### Pipelines: a value that holds a block is a block — change to "a pipeline is a block"

**Change to alt-1 option B.** A chain over a cursor is a block,
`fn() -> Option<T>`, composed by the compiler where the chain is written.
Stage state (`take`'s count, `zip`'s pending item, a block-taking
generator's frame) is a hidden local of that frame, captured like any
local.

Why, on this lens:

- **Soundness.** The draft's rule fails three existing checks on its own
  flagship example (`let` of a non-literal, `&` on a `let`, `var` of a
  block) and is unsound through generics without a new kind
  (probe-soundness §1, 2a, 2b: `keep`, `drive`). Under B all three
  counterexamples are rejected by checks that exist today. The only new
  rows are restrictions: an `&r` head is held like `for x in &r`, and two
  `&r` heads over one place in one call conflict.
- **Power.** B *adds* what the draft can't do: user-written lazy stages
  (`dedup_by`, `scan`, `chunk_while`, a protocol framer taking a parse
  block) and two-input stages with a key (`merge_by`), by letting a `gen fn`
  that takes a block give a pipeline (probe-prior-art F2, programs/04 and
  09). Under the draft the default set is the ceiling.
- **What B gives up:** a storable generic adapter over *any* cursor
  (`Peekable<C>` in a record). foundations.md already gave that up, and no
  paper program needs it. A storable adapter over a known cursor type is
  still a `gen fn` or a record.
- **Cost.** 1,150 to 2,100 lines, mostly medium risk, against the draft's
  2,400 to 4,400, mostly high (alt-1, side by side). Release fusion is the
  existing per-block specialization, since every pipeline reaches a sink as
  a block parameter, so it survives decision 13's partitions the way any
  higher-order call does. Debug is one indirect call per item into the
  composed block, cheaper than the draft's shared adapters with dictionary
  calls.
- **The source rule** (needed under any option): `&r.map(f)` steps `r`; a
  bare `r.map(f)` on a named cursor is an error with two fix-its; a
  temporary head needs no `&`. After a `break`, `r` has advanced by what the
  pipeline pulled, lookahead included (document it under `take_while`,
  `windows`, `zip`).
- **Open:** choosing between two pipelines with `if` is an error
  (`Let_chosen`), with "choose inside one block" as the help. That's
  common in CLIs (`if verbose`), so measure how often it bites before
  adding tag dispatch.

#### One vocabulary, two receivers — keep the names, change the cost

Keep shared names, with the receiver deciding. But the obvious chain is
`orders.select(p).map(f).sum()` on an array, and it allocates two arrays,
which breaks property 8 in exactly the code the compiler itself and most
programs write (probe-ethos M1). **Change:** an eager chain on a
collection whose blocks use no dependency and write no captured place
compiles through the same composed block as a lazy one, ending in the
materializing sink. Both facts are already known (rows, exclusivity), and
the chain is syntax, so it's B's composition reused: a few hundred lines,
no flow analysis. Effect order and `try` placement only differ when a
block has effects, and then it stays eager, as written.

#### `next` joins the built-in requirements — drop

Under B, sinks and adapters take `fn() -> Option<T>`; errors and uses flow
through the block parameter's tail as `retry`'s do. The draft's version is
the first requirement with an associated type and two associated rows,
600 to 1,000 lines of high-risk sema, plus method-table dictionaries in
debug (probe-feasibility F4), plus blanket methods on every type with a
`next`, which §7 forbids. Dropping it keeps §3's set closed and unchanged.
Remaining rule: stage names are reached structurally on cursor types, as
`for` reaches `next`, and a cursor type declaring a member with a stage
name is an error.

#### Exclusivity, step by step — change: it's the existing `let`-block rule

Under B there's nothing new. A `for` over a pipeline calls the block per
step, and a `let`-bound block's captures are accessed where it's called
(excl.ml's existing rule). Passed to a call, a pipeline holds its captures
*for the call*, as any block does. The draft's "an instant" wording,
applied to calls, is unsound (probe-soundness §3, the `consume(p, &limit)`
case), so the doc must not state it generally. `Async.map`'s source being
pulled on the caller's task is then *checked*, not stated: an
ordinary-mode block parameter can't be handed to a spawn.

#### Pipelines and the pipe — keep

`.` for stages, `|>` for workflow steps that take a pipeline. Under B the
value through the pipe is a block whose head says `&r`, so §8's "no `&`
through a pipe" holds. Add a lexer rule for a line beginning with `.`, as
`|>` has (programs/06 item 4); every real pipeline wants one stage per
line.

### Producers: `gen fn` — change the cursor kind; keep the rest

**Change to alt-2 R.** A `gen fn` whose `uses` is empty and whose
parameters are values gives a **value cursor**: data, storable,
returnable, copyable as an honest fork. Any other `gen fn` (uses a
dependency, takes a block, takes `&`) gives a **frame cursor**: block-kind,
bound once, looped, passed down, never copied, stored, returned or given
to a task. Dependencies are found where the frame is created (decision 5
applied to frames), which closes programs/07's rebinding hole.

Why, on this lens:

- **Soundness.** It's the only option in alt-2 that is sound under
  decisions 2, 5, 7, 11 and 12 with no undecidable trigger. Copies of a
  frame holding a buffer or a pending `finally` can't happen, so the double
  close, the duplicated framer leftovers (probe-soundness §8) and the
  hoisted-uniqueness break (§4) are gone for every generator that touches
  a resource. Value cursors keep one cheap rule: each `&` held across a
  `yield` re-checks uniqueness on resume.
- **Power.** It allows `yield` inside `with` (rows in a transaction,
  programs/07) and block or `&` parameters (`merge_by(&a, &b, key)`). It
  costs storing a dependency-using generator, which becomes a data cursor
  (programs/09's `Tail`). That's the bet's own line for instances.
- **Cost.** Frames never copy, so the interpreter can use OCaml 5 one-shot
  fibers (about 300 lines) and copy pure value cursors by replay (about 150
  more), instead of a 1,500 to 2,500-line Core state machine before 11c
  ships anything. Natively, frames go in the task's bump allocator with no
  COW and no rebase. Value cursors need the Mem-level state machine
  (1,200 to 2,000 lines), but that lowering is needed for pulled frames
  anyway, so the extra is the counted heap home and COW.
- **Kind visible at the boundary.** It's the `uses` every public signature
  already writes, so nothing about a body silently changes a caller.

Keep:

- `gen fn` as the producer, no `Emit` dependency, no comprehension syntax.
- `yield from`, but box only when the delegation is recursive (a cycle);
  otherwise the child is a field (programs/09 item 2). Require `yield from
  try` when the child can fail (programs/05 item 1).
- Name the value cursor's type `walk.Cursor` (alt-2 Q6). A frame's type
  is never written in a field.
- Drop "A `gen fn` can't take a block": under B and R it gives a pipeline
  or a frame.

#### Pushed when it can be — keep, and move push-through-stages out of Later

Keep the Go-style push for a `gen fn` consumed by a `for`. **Change:**
pushing through one-input stages (`map`, `select`, `take`, `take_while`,
`skip`, `with_index`, `flat_map`, `chunks`) and into built-in sinks is
part of the plan, not later. Otherwise extracting a helper and adding
`.take(10)` turns one loop into a resumed state machine per item
(programs/05 item 2, programs/09), against property 8. It's syntactic (one
chain), 200 to 400 lines over the base push pass (alt-1 rule 8). Only a
two-input stage or a pipeline passed to a user function pulls, and the
hover says so.

State the four hidden conditions push needs (probe-feasibility F8): no
push when the consumer's body itself yields; the push twin owns its
parameters, or borrow inference lends a buffer the body mutates; `break`
and `return` go through a control-value protocol; and recursion.
**Open:** a pushed recursive walk recurses on the native stack, so a
10⁶-deep tree overflows where pull wouldn't. Pick: push only
non-recursive producers, or run pushed recursion on the task's frame
allocator.

#### Blocks inside a generator's frame — change

Under R, frames are never copied, so relative addressing is needed only
for value cursors, which are pure and take no blocks, so their blocks can
only capture their own frame. Keep the rule for value cursors only (200
to 400 lines shrink to the value-cursor case).

### Errors — keep, with three additions

- Keep `for x in try &c`, a failure ending the stream after cleanup,
  per-item recoverable errors as `Result` items, no error operators.
  programs/06 shows this is the best-reading part of the design.
- **Add:** a generator's `finally(r)` sees `Ok` if it returned, `Err(e)` if
  it failed, `Err(Cancelled)` if abandoned (by `break` on a temporary, the
  end of its binding's scope, or cancel). A transaction rolls back on
  `break`, as C# and Go do (programs/07 item 2).
- **Add:** cancelling a generator's `next` mid-step ends the cursor, its
  `finally` runs, and later `next`s give `None`. Deadlines on a single
  `next` are `next(within:)` on service cursors, which are cancel-safe
  already (probe-prior-art F6). Without this, every time operator and
  heartbeat has undefined behaviour.
- **Add:** the error message names the stage a lazy failure came from
  ("`next` can fail with `ParseError`, from the `map` on line 12").

### Cleanup — change

Delete the drop bullet and the paragraph defending dependency calls at a
drop. It contradicts decision 11 ("never when a count reaches zero"),
moves with borrow inference so a debug journal stops replaying in
release, suspends in functions decision 12 gives no frame, has no error
channel, runs twice on copies, and can't be implemented in the
interpreter or in `ren_drop` (probe-soundness §5, probe-feasibility F1).
Replace with R's three syntactic points, each an unwind: shielded, under
the cleanup deadline, in the consumer's row. Backstop: handles register
with their handler, which closes leftovers when its `with` ends.

### Cursors over resources — keep the principle, change four rules

- **Keep** "a resource's state belongs to its service; only ids and
  offsets in the cursor". Under R it's the rule for *storable* resource
  cursors, and it's the answer to the one power gap (kept or dynamically
  counted streams).
- **Change** "`for x in c` without `&` is an error" to apply only to named
  places. On a temporary the `&` is noise (programs/05, 06), and the rule
  would break today's `for (x, y) in xs.zip(ys)`. Fix the reason given:
  for an id-backed cursor, stepping a copy *consumes* the socket, so the
  hazard is aliasing, not "left at the start".
- **Add:** ids carry their instance's incarnation; use on another
  instance, or after the `with` ended, fails with a typed `Closed`. And a
  `with` body's value can't be a cursor type of the dependency the `with`
  installs (decision 7's rule, given to values). That makes programs/07's
  `let rows = with tx in Sql.rows(q)` a compile error.
- **Add:** `Net.frames(conn, fmt)` reads `Short.need` into one buffer. Not
  for soundness under R, but for cost: the hand-written `buf ++ chunk`
  framer is quadratic for a large frame over small chunks (programs/02
  item 2), and every protocol server writes it.

### Concurrency

#### Generators stay on the consumer's task — keep, change the `yield` rule

Keep "`next` runs on the consumer's task". **Change** the list to one rule:
`yield` appears only in the generator's own body, not inside any `fn`
literal and not in a `finally`. The list misses `xs.each`, `Docs.at`,
`snapshot.read`, `Async.isolate`, and anything a library adds
(probe-soundness §7, probe-feasibility F9). **Allow** `yield` inside
`with` for frame generators (R): the instance is held exactly as long as
the `with` would be.

Also: no `gen` handler operations, and operation parameters can't take a
pipeline or a frame (programs/10 item 2), since decision 10's deadlock
argument needs blocks kept out of operations.

**Change (outside streams.md, but streams make it the normal case):**
narrow decision 2's "a dependency call inside a handler arm writes all
the handler's state" to `Async.until`, `release` and block-parameter
calls, the places the instance can actually be re-entered. As it stands,
no handler or actor can loop over a resource cursor it keeps, since every
such `next` is a dependency call (probe-soundness §2e, programs/10). The
workaround (`var c = state.r; ...; state.r = c`) is ceremony for a
hazard decision 10 already rules out.

#### Async.produce — keep, change `out`

Keep the shape: the consumer's block brackets the producer's task, which
is the only sound way to give a stream a task. **Change** `out` from a
held value to a dependency the call installs for the producer block,
`Send<T>` (probe-ethos B4, decision 5's "those listed in its parameter's
type, which the callee provides"). Channels are `dep`s, and the bet
forbids holding an instance. Document that a producer holding a pin or a
lease while it sends holds it for as long as the consumer takes
(programs/10 item 3).

#### Many items at once — keep, settle three points

- Keep `Async.each` and `Async.map` over any cursor, pulling only when a
  slot frees. It's the server's accept loop and the crawler, and it's
  right.
- **Window semantics:** ordered `Async.map` keeps a window of `max`
  including finished results waiting behind a slow head, so memory is
  bounded (Rust `buffered`, Java `mapConcurrent`). Say it.
- **The limit:** drop the "needs a limit" error and use decision 7's
  default of 64 for cursors too. Pulling only when a slot frees already
  bounds it; the error's reason ("every item could be in flight") is
  false under that rule, and one call with two defaults is the receiver
  deciding again.
- **`Async.map_pull` changes** to the block shape produce has:
  `Async.map_pull(src, max: 16, fn(u) => fetch(u)) fn(results) => ...`. As
  written it hides a scope whose cancel-and-wait lands at a drop, and its
  concurrent block reads captures between `next`s, a data race the static
  check misses (programs/03 item 1, probe-ethos M4).

#### Channels are cursors — change spelling

`for m in &inbox` needs a value, and a channel is a `dep`. Use a
compiler-derived `Inbox.items()`: a zero-field cursor whose `next` is
`Inbox.recv()`, typed per dependency name so two `Chan<Event>` aliases
don't mix (programs/08 items 2 and 3).

### Time — change the operators' shape

Keep "every operator takes its time from `Clock`", and the replay claim.
**Change:** `debounce`, `batch(within:)`, `throttle`, `sample` and `merge`
must race the next item against a timer. Over a generator, that cancels
it mid-step and kills it, so every real implementation (Kotlin, Effect)
pulls upstream on a second task. Give each operator either a channel
source, or the consumer-block shape: `stream.time.debounce(src, d)
fn(settled) => for e in try settled ...` (probe-prior-art F1, programs/08
item 1). The rule is one sentence: every stream with tasks behind it is a
produce shape. **Open:** a conflating channel (drop oldest, keep newest)
for telemetry and `sample`; channels that only block can't express it.

### The standard library — keep the size, adjust the set

- Keep the default set and the left-out list (hot flows, schedulers,
  error operators, implicit chunking).
- Under B, users write their own stages, so the set needn't grow to cover
  everything. Add `scan` and `dedup_by`, which nearly every stream program
  wants, and `Net.frames` / `Fs.lines` as the library's resource cursors.
- Move `Async.map_pull` and the time operators to the block shapes above.

### Compiler errors — keep the style, change the set

- **Keep:** stored pipeline → `gen fn` (with "or a data cursor" when the
  generator uses a dependency); `for` over a named cursor without `&`;
  `next` can fail; `yield` inside a block.
- **Delete:** "a `gen fn` can't take a block" (now legal) and "`Async.map`
  needs a limit" (default 64).
- **Add:** a frame cursor copied, stored, returned or spawned ("`follow`
  uses `Fs`, so its cursor lives in this scope; pass `&r`, or keep a
  reader, which is data"); a cursor leaving the `with` that serves it; two
  `&r` heads over one place; a bare `r.map(f)` on a named cursor; choosing
  between two pipelines.

### What it changes — change

Rows to drop: rule D extended to "any value holding a block", and `next`
joining §3. Rows to add: decision 1, "a `let` binds one literal block or
one chain"; decision 12, "a `gen fn` that uses a dependency or takes a
block or `&` is a frame, cleaned up at syntactic points; a pure one is a
value"; decision 2, the `&r`-head row and the narrowed handler-state row;
decision 7, the with-escape rule for values. And foundations.md "What's
given up" changes from "generic lazy pipelines" to "storable generic
adapters over any cursor, and storing a generator that uses a
dependency".

### Left out — keep, amend one line

Keep all items. "Affine or unique cursors" stays out: frames are
block-kind, not affine, and value cursors copy honestly. Add "storable
generators that use a dependency" to the list, with the data-cursor
answer.

### Later — change

- Move "fusion through a `gen fn` whose consumer is a pipeline" into the
  plan (see Pushed).
- Keep `unordered: true` and broadcast as later.
- Add: N-way merge over a dynamic set of sources, if a storage-engine
  program shows the data-cursor form is too heavy.

### Evidence — keep

Prior-art fixes per probe-prior-art. No design impact.

## Cost, as amended

Lines of OCaml, from probe-feasibility and alt-1 and alt-2's figures:

| Piece | Draft | Amended (B + R) |
|---|---|---|
| Syntax, failing cursors, `gen fn` typing, `yield` placement | 850–1,500 | same |
| `next` requirement with associated rows | 600–1,000, high | **0** |
| Second-class pipelines through type variables | 600–1,200, high | **0** (chain composition 500–800, medium) |
| Source rule, `Let_chosen`, `for` over a pull block | 200–400 | 150–300 |
| Frame or value kind from the signature, cleanup points, with-escape | n/a (drop rule unbuildable) | 400–700, medium |
| Interpreter generators | 1,500–2,500 Core state machine, high | **about 450** (fibers plus replay) |
| Push, and push through one-input stages | 400–700 | 600–1,100 |
| Native generator frames | 1,200–2,000, high | same lowering; frames in the bump allocator, COW only for values |
| Debug pipelines and `next` dictionaries | 500–900 | **0** (code and frame, existing) |
| Release fusion | 500–900, high (SRoA or new key) | **0** (existing per-block specialization) |
| Relative addressing | 200–400 | value cursors only |
| Async.each, map, produce, map_pull | 300–500 | same |
| Eager array-chain fusion | n/a | 200–400 |

Roughly 4,500 to 7,500 lines against the draft's 6,000 to 10,000 plus the
unbuildable drop rule, with the high-risk rows cut from five to two
(native frames, push). Staging is unchanged in shape: the interpreter has
everything at 11c; natively, pure generators and pushed loops come first,
and generators that use `Fs` or `Net` wait for stage 13's frame allocator
(probe-feasibility F11).

Runtime, release:

- a chain, a pushed generator, or a pushed user stage: one loop, nothing
  allocated;
- a two-input stage or a pulled frame: one `switch` per item, the frame on
  the task's bump allocator;
- a stored value cursor: a counted heap frame, COW on a shared step, one
  compare per held `&` per `next`;
- a recursive pulled `yield from`: O(depth) per item.

Debug: one indirect call per item per chain.

## Top 5 recommendations, ranked

1. **Cleanup only at syntactic points; generators that use a dependency
   are frames (alt-2 R).** This is the one place the draft is unsound and
   unbuildable at once, and it touches the most signed decisions (2, 5, 7,
   11, 12). The fix also *gains* power (yield inside a transaction, block
   and `&` parameters on generators) and cuts the interpreter from a
   1,500 to 2,500-line state machine to about 450 lines of fibers.
   Owner decisions: `Err(Cancelled)` vs a distinct `Stopped` for
   abandonment; the trigger stays `uses` (no `scoped` marker).

2. **A pipeline is a block, `fn() -> Option<T>`, composed where the chain
   is written; drop the `next` requirement (alt-1 B).** It makes the
   flagship example legal under existing rules, rejects every soundness
   counterexample with checks that exist today, gives users lazy stages
   and `merge_by`, keeps §3 closed, and removes 2,000 to 4,000 lines of
   high-risk sema and backend work. The price is storable generic
   adapters over any cursor, which foundations.md already gave up.

3. **Every stream that has tasks behind it takes `Async.produce`'s
   shape:** `map_pull`, `debounce`, `batch(within:)`, `throttle`, `sample`,
   `merge` take a consumer block (or a channel source), and `produce`'s
   `out` becomes an installed `Send<T>`. As written, the time operators
   can't be built over a pipeline, and `map_pull` hides a scope and a
   data race. Pair it with "cancelling `next` mid-step ends the cursor"
   and `next(within:)` on service cursors.

4. **Make the obvious way the fast way on both receivers:** push through
   one-input stages and into sinks now, not later, and fuse eager array
   chains whose blocks are pure. Both reuse B's chain composition, cost
   400 to 800 lines together, and fix the two cost cliffs every program
   hits (extracting a helper and adding `.take`; `xs.select(p).map(f)` on
   an array, which is what the compiler's own passes will write).

5. **Finish "resource state belongs to its service", since it's the answer
   to the remaining power gap:** incarnation-tagged ids with a typed
   `Closed`, the with-escape rule for cursor values, handles registered
   with their handler as a backstop, `Net.frames(conn, fmt)` against the
   quadratic framer, and narrowing decision 2's handler-state row so an
   actor can step a cursor it keeps. Servers and storage engines keep
   streams across requests and over dynamic sets of files; under R that's
   a data cursor, and these rules make it sound and cheap.

## Open for the owner

- The leased-chunk pinning problem (a kept slice stalls the pool):
  copy out at the keep point, or a debug error.
- Recursive push on the native stack: push only non-recursive producers,
  or give pushed recursion the task allocator.
- Choosing between two pipelines with `if`: an error with "choose inside
  one block" now, tag dispatch later if it bites.
- A conflating channel policy for telemetry and `sample`.
- Dynamic N-way merge: confirm the data-cursor form (`Array<SstReader>`) is
  acceptable, or plan an ADT-of-sources helper, before a storage engine is
  written.

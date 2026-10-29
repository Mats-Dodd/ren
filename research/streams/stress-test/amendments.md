# streams.md: amendments from the stress test

Inputs: streams.md (the candidate, not decided), probe-soundness,
probe-feasibility, probe-ethos, probe-prior-art, programs 01–10, alt-1
(what a pipeline is), alt-2 (what a generator's cursor is), and the three
judges (ergonomics, ethos, power/soundness/cost). Short names below:
**B** = alt-1's "a pipeline is a block"; **R** = alt-2's "a generator that
suspends is a frame, a resource is an id"; **B+R** = the two merged, as
judge-ethos reconciles them.

## 1. Verdict

The skeleton is right, and every reviewer kept it: one kind of stream
(the cursor), no colours because suspension follows `uses`, `gen fn` as
the producer, `try` on the `for`, recoverable errors as `Result` items,
`Clock` for time, a small library, and no hot flows, schedulers or error
operators. Where a stream is made and used in one place (programs 01, 05,
06, 07A, 08, 10A), Ren reads as well as or better than Kotlin, C#, Go,
Elixir and Rust. Two of the load-bearing mechanisms don't hold up as
written:

- **"A value that holds a block is a block."** The flagship example
  breaks three existing rules: `let` of a non-literal, `&` on a `let`,
  and a block bound with `var`. Passing pipelines through generics is
  unsound unless type variables get a new kind. `next` would become a
  requirement with an associated type and two rows. That's about
  2,400–4,400 lines of high-risk work.
- **`finally` at a Perceus drop.** It contradicts decision 11 outright.
  It runs at a point the optimizer picks, runs twice on copies, and can't
  be built in either the interpreter or `ren_drop`.

Both have a fix that is smaller and more powerful, and it uses
mechanisms that already exist:

- a pipeline *is* a block;
- a generator that uses a dependency or takes a block is one too, while
  a pure generator is storable data;
- cleanup runs only at points the syntax fixes.

With that change, users can write their own lazy stages (`merge_by`,
`dedup_by`, `scan`), `yield` inside a transaction works, the `next`
requirement and the type-variable kind both go, and the interpreter
needs about 450 lines instead of a 1,500–2,500-line state machine.
Section 3 of language.md and decision 11 stay unamended. The price is
that a generator using a dependency can't be stored. You store its
position as data instead (an id and an offset), which is the line the
bet already draws for instances.

## 2. Amendments

Each one has: the verdict, the change, the program that shows why, and
who supports it. Judges: **Erg**, **Eth**, **Pow**. Probes: **Snd**,
**Fea**, **PEth**, **PA**.

### What it has to do: change

- **Property 2** becomes "cleanup when the consumer stops: a loop over a
  temporary closes it at `break`; a named stream closes at the end of its
  binding's scope; on cancel. Never at a drop." As written, property 2
  contradicts the doc's own resume example.
- **Add a property:** users can write their own lazy stages.

```ren
var r = follow(path)
for line in try &r
  if line == "--- boot ---" then break   // the draft promises both "finally runs at break"
                                         // and "r stays where it stopped"
```

Program 01, item 3. Supported by: Erg, Eth, Pow, PA F4, Fea F2.

### Where Ren stands: change (claims only)

Use the corrected rows in §3 below. The design doesn't depend on them,
but the Kotlin and C# readers this table is aimed at will know these
facts. Supported by: PA, Erg, Eth.

### One kind of stream, the cursor: keep, adding one sentence and one caveat

- **Keep:** no async iterator, and the `uses` row is the only
  difference. It's the strongest section.
- **Add this sentence:** "One protocol, `next`, with two kinds of
  value: data you can keep (a value cursor or a library reader) and
  blocks you pass down (a pipeline or an effectful generator). The split
  follows `uses`, the line decision 12 already draws for suspension."
- **Add a backpressure caveat:** a slice kept past the body's turn holds
  its leased chunk. This is open (decision 12 below).

Supported by: Eth, Pow, Erg; program 02, item 3.

### Pipelines: change to "pipelines are blocks"

**The rule.** A chain over a cursor (`src.stage(..).stage(..)`) is a
block, `fn() -> Option<T>`, that the compiler writes where the chain is.
A stage's state (`take`'s counter, `zip`'s pending item) is a hidden
local of that frame, which the block captures.

- **What a pipeline can do:** be bound with `let` (decision 1 becomes
  "one literal block *or one chain*"), be looped over with no `&`, be
  stepped by hand, and be passed to a block parameter.
- **What it can't do:** be stored, returned, or chosen between with
  `if` (`Let_chosen`, help: "choose inside one block").
- Rules A–D, exclusivity, per-block specialization, and debug's code
  plus frame all apply unchanged.

```ren
var r = Fs.line_reader(path)
let errors = &r.map(parse).select(fn(e) => e.level == Error).take(100)
for e in try errors            // a call per step; `r` is written for the loop
  try alert(e)
  if e.fatal then break
for line in try &r             // goes on after the last line `errors` pulled
  Console.print(line)
```

Under the draft this example breaks three rules. Under B it breaks
none: `errors` is a `let`-bound block that writes `r` and `take$n` as
captures, which is `let f = fn() => n += 1`. All three soundness
counterexamples (`keep`, `drive`, `consume(.., &limit)`) are rejected by
checks that exist today (alt-1, "Counterexamples under B"). Supported
by: Erg #1, Eth #2, Pow #2, Snd §1–3, Fea F3, PEth B2–B3.

### The source of a pipeline: change

- **`&r.map(f)` steps `r`.** It's held the way `for x in &r` holds it,
  wherever the pipeline is looped over or passed.
- **`r.map(f)` on a named cursor is an error,** with two fix-its:
  `&r.map(f)` steps `r`; `let c = r` then `&c.map(f)` steps a copy.
- **A temporary head needs no `&`.** For example, `Db.rows(q).map(f)`.
- **The missing-`&` error applies only to named places.** That covers
  both `for x in r` and a chain head. `for n in walk(t)`, `for row in try
  Db.rows(q)` and today's `for (x, y) in xs.zip(ys)` stay legal.
- **Lookahead:** after a `break`, `r` has also lost whatever the
  pipeline looked ahead at (`take_while`, `windows`, `zip`). Document
  it, as Rust documents `by_ref().take_while`.
- **Two `&r` heads over one place in one call conflict.**

```ren
var lines = Fs.line_reader(path)
let Some(head) = try &lines.next() else fail NoHeader
lines.with_index().map(...)   // draft: steps a copy for a pread reader, the original for a socket
```

Program 06, item 1: the same text means two things depending on how the
cursor's author stored its state. Erg ranks this the worst newcomer
trap. Supported by: Erg, Eth, Pow, Snd §1, Fea F7.

### `next` joins the built-in requirements: change (drop it)

- **Sinks take a block.** A sink or user function that takes "any
  stream" takes `rows: fn() -> Option<T>`. Its errors and uses flow
  through the block parameter, as `retry`'s do.
- **The stage vocabulary belongs to the pull type.** On cursor types it's
  reached structurally, as `for` reaches `next`.
- **Stage names are reserved.** A cursor type can't declare a member
  named after a stage (`map`, `count`, ...).

```ren
pub fn index_all(rows: fn() -> Option<Row>) uses Search ! SearchDown =
  for row in try rows
    try Search.put(row)
// draft: index_all<block C has next -> Row ! e uses u>(rows: C), the heaviest signature in Ren
```

Section 3 stays closed. Under the draft, `next` would be the withdrawn
`T has area` idea for one name, and a second answer to "do this with any
type". Supported by: Eth, Pow, Erg, Fea F4, PA F7, PEth M2.

### One vocabulary, two receivers: keep the names, change the cost

Keep "the receiver decides". Add: **an eager chain on a collection whose
blocks use no dependency and write no captured place compiles through the
same composed block**, ending in the materializing sink. No program can
tell the difference, and `orders.select(p).map(f).sum()`, the chain
everyone writes first and the compiler's own passes write, stops
allocating two arrays. When a block has effects, the chain stays eager as
written. The work reuses B's chain composition: 200–400 lines. Supported
by: Pow, Eth, Erg, PEth M1.

### Exclusivity, step by step: change (no longer a new rule)

Under B it's the existing rule for a `let`-bound block: captures are
accessed at each call, which is each step. A pipeline passed to a call
holds its captures **for the call**. The draft's "an instant" wording,
applied to calls, is unsound:

```ren
consume(xs.cursor().select(fn(x) => x < limit), &limit)   // must be an error, as it is for blocks
```

Keep the `limit` example as an illustration. `Async.map` and
`Async.each` then pull their source on the caller's task, and that's
checked rather than just stated: an ordinary block parameter can't be
handed to a spawn. Supported by: Snd §3, Pow, Eth.

### Pipelines and the pipe: keep, and add a layout rule

- **Keep:** `.` for stages, `|>` for steps from elsewhere. The value
  through the pipe is a block whose head shows the `&`, so §8's "no `&`
  through a pipe" still holds.
- **Add:** a line that begins with `.`, indented further, continues the
  line above, as `|>` does.

Program 06, item 4: every real chain wants one stage per line.
Supported by: Erg, Eth, Pow.

### Producers, `gen fn`: change what a call gives (B+R)

> Calling a `gen fn` gives a **value cursor** if the `gen fn` uses no
> dependency and takes only values. Otherwise the call is a
> **pipeline**: a block whose state, the generator's frame, is a hidden
> local of the caller.

- **Value cursors are data.** They're storable and returnable, and a
  copy is an honest fork. Name the type `walk.Cursor`.
- **Effectful or block-taking generators follow the block rules.** They
  can't be copied, stored, returned or spawned. Their dependencies are
  found where the frame is created (decision 5), which closes program
  07's rebinding hole.
- **Delete the "a `gen fn` can't take a block" error.** A `gen fn` that
  takes a block is how users write stages.
- **Delete "the one way to write a producer."** Say "the way to write a
  producer with control flow; a record with `next` is how a stream's
  position is kept as data."
- **`yield from try child(..)`** when the child can fail (program 05,
  item 1).
- **Box only recursive `yield from`.** A non-recursive child is a field
  (program 09, item 2).

```ren
gen fn merge_by<T, K>(a: fn() -> Option<T>, b: fn() -> Option<T>, key: fn(T) -> K) -> T = ...
try merge_by(Db.rows(q).map(Event.from_row), Fs.line_reader(p).map(parse_event), fn(e) => e.at)
  .take(1000).to_array()
// draft: refused twice (mapped sources are blocks; the comparator is a block)

gen fn dedup_by<T, K>(src: fn() -> Option<T>, key: fn(T) -> K) -> T =
  var last: Option<K> = None
  for x in try src
    let k = key(x)
    if Some(k) != last then
      last = Some(k)
      yield x
```

Programs 04 (use 3) and 09 (step 6): under the draft, the default set is
a ceiling users can't extend. Kotlin, C#, Go, Elixir, Rust and Effekt
all let users write stages. Supported by: Erg #2 ("the single biggest
ergonomic gain available"), Eth #3, Pow #1–2, PA F2, alt-1 rule 7, alt-2
R.

### Pushed when it can be: keep, and move "fusion through a `gen fn`" out of Later

- **Push through one-input stages now.** A chain whose head is a `gen
  fn` call and whose consumer is a `for` or a built-in sink is pushed,
  with every one-input stage folded into the body. Only a two-input
  stage or a pipeline passed to a user function pulls, and the hover
  says "pulled: zip".
- **State the conditions push needs:**
  - no push when the consumer's body itself yields;
  - the push twin owns its parameters;
  - `break` and `return` go through a control-value protocol;
  - recursion moves to the native stack (decision 10).
- **Credit decision 1, not Go,** for the no-allocation guarantee. Go's
  rewrite allocates when it isn't inlined.

```ren
for e in try walk_dir(root).select(big).take(10)   // draft: silently a pulled state machine, O(depth)/item
for e in try errors_since(p, Warn, t0).take(10)    // draft: extracting a helper changed the cost
```

Programs 05 (item 2) and 09: the two most ordinary edits, adding
`.take` and extracting a helper, change the cost under the draft. That
goes against property 8. The fix costs 200–400 lines over the base push
pass. Supported by: Pow #4, Eth #5, Erg #2, PEth M3, Fea F8.

### Blocks inside a generator's frame: change

Effectful generators are never copied, so they need no relative
addressing. Keep the rule for value cursors only, and add: **each `&`
held across a `yield` re-checks uniqueness on resume**, one compare per
held `&` per `next`. Without it, a hoisted uniqueness check breaks value
semantics (probe-soundness §4, `bumped`). Also: a `gen fn` can't take
`inout` parameters, and a handler operation can't be `gen`. Supported
by: Snd §4, Pow, Eth.

### Errors: keep, with three additions

- **The `finally` sees why the generator ended.** `finally(r)` sees
  `Ok` if it returned, `Err(e)` if it failed, and `Err(Cancelled)` if
  it was abandoned or cancelled. So a transaction rolls back on `break`,
  as in C# and Go (program 07, item 2).
- **A cancel mid-`next` ends the generator.** Its `finally` runs and
  later `next`s give `None`. Service cursors offer `next(within:)`,
  which is cancel-safe (PA F6, program 08).
- **The `for`'s error names the stage:** "`next` can fail with
  `BadLine`, from the `map` on line 12" (PEth m5).

Keep `try` inside a stage *and* on the `for`, and show it once in the
doc so it doesn't look doubled (program 06, item 5). Supported by: Pow,
Eth, Erg.

### Cleanup: change

- **Delete the drop trigger** and the Swift paragraph that defends
  dependency calls at a drop.
- **Cleanup runs at three points, each an unwind:**
  - the end of a `for` over a temporary, or of the statement that holds
    a sink;
  - the end of the binding's scope for a named stream;
  - cancel.

  Each is shielded, falls under the cleanup deadline, and runs in the
  consumer's row.
- **Backstop:** handles register with their handler, which closes
  leftovers when its `with` ends.

```ren
type Job = { id: Int, src: Lines }
fn retire(jobs: Array<Job>, id: Int) -> Array<Job> =   // pure
  jobs.reject(fn(j) => j.id == id)    // draft: the drop runs `f.close()`, an Fs call, in a pure fn
```

Under B+R, `Lines` (it uses `Fs`) can't be in a record, so this can't be
written. The draft's version breaks decision 11 ("never when a count
reaches zero") and decision 12 (it suspends with no frame). It has no
error channel and closes twice on copies (`let h = g`). It also moves
with borrow inference, so a debug build's journal stops replaying in
release. Supported by: all three judges (Eth's #1, Pow's #1), Snd §5,
Fea F1, PA F5, PEth B1.

### Cursors over resources: keep the principle, change the rules

- **Keep:** "a resource's state belongs to its service; ids and offsets
  in the cursor." Under B+R it's the rule for *storable* resource
  cursors, and it's the answer to "keep a stream per client".
- **The `&` error applies to named places only** (see above). Fix the
  reason it gives: for an id-backed cursor, stepping a copy *consumes*
  the socket, so the hazard is aliasing.
- **Ids carry their instance's incarnation.** Using one on another
  instance, or after its `with` ended, fails with a typed `Closed`.
- **The with-escape rule:** a `with` body's value can't be a cursor type
  of the dependency that `with` installs. That's decision 7, given to
  values.
- **Ship `Net.frames(conn, fmt)`.** It reads `Short.need` into one
  buffer.

```ren
let rows = try with sql.transaction() over Sql in Sql.rows(q, c)   // draft: compiles; next runs on the pool
for msg in try Net.frames(conn, PgMessage.wire)                    // replaces a 20-line framer whose
  ...                                                              // `buf ++ c` is quadratic
```

Programs 07D and 02 (items 1–2). Supported by: Pow #5, Erg #5, Eth, Snd
§8.

### Concurrency, where `yield` can go: change

- **One rule replaces the list:** `yield` appears only in the
  generator's own body, never inside a `fn` literal and never in a
  `finally`.
- **Allow `yield` inside `with`** for effectful generators, which are
  block-kind and so can't outlive it.
- **Operation parameters can't take a pipeline or an effectful
  generator** (decision 10).

```ren
gen fn summaries() -> Summary uses Docs =
  Docs.each(fn() => yield Doc.summary())   // draft: not on the list; pins an actor across a yield

pub gen fn orders_in_tx(c: CustomerId) -> Order uses Sql ! DbDown | Conflict | BadRow =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try Sql.rows(q, c)
      yield try Order.from_row(row)          // draft: refused; now legal; break rolls back
```

Programs 10 (B1) and 07 (B). Supported by: Snd §7, Fea F9, all three
judges.

### `Async.produce`: keep the shape, change `out`

The producer gets a `Send<T>` dependency that the call installs
(decision 5: "those listed in its parameter's type"), not a held channel
value. Document that a producer holding a pin, lock or lease while it
sends holds it for as long as the consumer takes (program 10, B2).
Supported by: PEth B4, Pow, Erg, Eth.

### `Async.each` and `Async.map`: keep, and settle three points

- **The ordered window:** a finished result waiting behind a slow head
  keeps its slot, so memory is bounded by `max`. This is the same as
  Rust's `buffered` and Java's `mapConcurrent`.
- **The source is pulled on the caller's task** (checked under B).
- **`max:`** is decision 6 below.

PA F8, program 03.

### `Async.map_pull`: change to the `produce` shape

```ren
Async.map_pull(sitemap_urls(p), max: 16, fn(u) => try fetch_or_skip(u)) fn(results) =>
  for r in try results
    ...
```

As written, the cursor it returns hides a scope whose cancel-and-wait
lands at a drop. Its concurrent block also reads captures between
`next`s, a data race the static check misses (program 03, item 1).
Supported by: PEth M4, all three judges.

### Channels are cursors: change the spelling

A channel is a `dep`, so there's no `inbox` value. Use a cursor the
compiler derives per alias, `Events.items()`, whose `next` is
`Events.recv()`. It's typed by dependency name, so `dep Audit =
Chan<Event>` doesn't mix with `Events` (program 08, items 2–3).
Supported by: Erg, Eth, Pow.

### Time: change the shape and the claim

`debounce`, `batch(within:)`, `throttle` and `sample` race "the next
item" against a timer. Over a generator, that cancels it mid-step and
kills it, which is why Kotlin and Effect both pull upstream on a second
task.

- **These four take a channel receiver.** `recv` is cancel-safe, so no
  hidden task is needed, and the common case stays one line:
  `stream.time.debounce(Queries.items(), Duration.ms(300))`.
- **A generator source goes on a channel first,** through
  `Async.produce`, so the task is on the page.
- **`merge` takes the `produce` shape.**
- **Replace the claim:** see §3.

Program 08, item 1. Supported by: PA F1, Erg (channel receiver), Pow
(either form), Eth (block shape). The form is decision 7 below.

### The standard library: keep the size, adjust the set

- **Add:** `scan`, `dedup_by`, `chunk_while` (it flushes at the end),
  and `Net.frames`. Now that users can write stages, the set can stay
  the size of Elixir's.
- **Move:** `map_pull`, `merge` and the time operators to the shapes
  above.
- **Open:** a conflating channel (drop oldest, keep newest), which
  `sample` and telemetry need.

Supported by: Erg, Pow, PA.

### Compiler errors: keep the style, update the set

- **Keep** the "stored / returned / captured by a task → `gen fn`"
  error. Add "or a data reader" when the generator uses a dependency.
- **Delete:**
  - "a `gen fn` can't take a block";
  - "`Async.map` needs a limit", if decision 6 goes to the default.
- **Add:**
  - "`follow` uses `Fs`, so its stream lives in this scope. To keep a
    position, keep a reader (`Fs.line_reader`), which is data";
  - "`Sql.Rows` can't leave the `with` that installs `Sql`";
  - "`yield` inside a block";
  - bare `r.map(f)` on a named cursor, with both fix-its;
  - two `&r` heads over one place;
  - "a pipeline can't be chosen with `if`";
  - `.filter(` suggests `.select(`.

### What it changes: change

- **Drop these rows:** rule D widened to "any value holding a block",
  and `next` joining §3.
- **Add these rows:**
  - decision 1: "a `let` binds one literal block or one chain";
  - decision 12: "a `gen fn` that uses a dependency or takes a block is
    block-kind, cleaned up at syntactic points; a pure one is a value";
  - decision 2: the `&r`-head row;
  - decision 7: the with-escape rule for values;
  - async.md: the `max:` default, per decision 6.
- **"What's given up"** changes from "generic lazy pipelines" to
  "storable generic adapters over any cursor (`Peekable<C>` in a
  record), and storing a generator that uses a dependency".
- **Outside streams.md, but streams make it the normal case:** narrow
  decision 2's "a dependency call inside a handler arm writes all the
  handler's state" to `Async.until`, `release` and block-parameter
  calls. As written, no actor can loop over a resource cursor it keeps,
  since every `next` is a dependency call (Snd §2e, program 10). This
  is decision 11 below.

### Left out: keep, and add one line

Affine cursors stay out: effectful generators are block-kind, not affine,
and value cursors copy honestly. Add "storable generators that use a
dependency (keep a reader instead)".

### Later: change

- **Move into the plan:** fusion through a `gen fn`.
- **Keep as later:** `unordered: true` and broadcast.
- **Add:** a dynamic N-way merge (memtable plus N SSTables). Blocks and
  frames can't sit in an `Array`, so today it takes `Array<SstReader>`,
  a data cursor (Pow, power check).

## 3. Corrected prior-art claims

- **"One kind of stream: Kotlin, Elixir."** Replace with: *"Elixir; Go
  (`iter.Seq` covers slices and sockets alike); Java on virtual threads.
  Kotlin is not: `Sequence` (whose builder is `@RestrictsSuspension`)
  and `Flow` are two kinds with two operator sets."* Add Kotlin to the
  "two of everything" table: `Sequence` / `Flow`, `yield` / `emit`. Drop
  "the one most languages can't add after the fact", since Loom removed
  Java's split after the fact.
- **"Cleanup when `break` runs: C#, JavaScript, Go, Elixir … yes."**
  Replace Ren's cell with: *"yes for a loop over a temporary; a named
  cursor resumes after `break` and closes at the end of its scope (Rust's
  `by_ref` model, with the close point fixed by syntax)."*
- **"Rust, at the cost of `Pin`, closure types and build times."**
  Replace with: *"Rust, Swift `lazy`, C++20 ranges, at the cost of
  closure types in every adapter's type and the build times that
  follow."* `Pin` is about futures, not iterator adapters. Also drop
  "Rust's speed without … nested adapter types": per foundations.md,
  code that wraps blocks at each layer is bounded by the specialization
  budget too.
- **"A bounded, ordered concurrent map … Elixir's `Task.async_stream`."**
  Replace with: *"Elixir's `Task.async_stream`, Java's
  `Gatherers.mapConcurrent`, Effect's `mapEffect({concurrency})`, Rust's
  `buffered(n)` (which stalls when not polled)."* Elixir's per-item
  timeout is an option, not a composition.
- **"Time operators deterministic in tests: nobody."** Replace the row
  and the Time paragraph with: *"Like Effect's `TestClock` and Go's
  `testing/synctest`, time comes from `Clock`. Unlike them, nothing can
  bypass it, the schedule is explored over seeds, and a failing
  production run replays from its journal."* Kotlin's `runTest` virtual
  time is first-party, and Turbine is only an assertion helper.
- **Swift row of "two of everything".** Replace with: *"`Sequence` and
  `AsyncSequence`; the basic operators are in both, and merge, zip and
  the time operators are in a separate package."*
- **Effekt and rule A (Producers).** Replace with: *"Effekt's push stages
  pass blocks to named functions, which rule A allows. What Ren can't
  take is its pull side, `zip`, which stores a boxed continuation
  (`stream.effekt:272`), and a second way to write producers."*
- **RFC 3550.** Replace with: *"Rust's RFC 3550 calls `Range` being an
  `Iterator` a mistake because it makes `Copy` hazardous: copyable
  iterators are the trap. In Ren only pure value cursors copy, and a
  copy is an honest fork."*
- **"Pushed … the way Go 1.23 compiles range over a function."** Keep
  the analogy, but add: *"Go's rewrite allocates when the iterator isn't
  inlined and panics on iterators that ignore `false`. Ren's guarantee
  comes from decision 1, since blocks are specialized per call, and
  `yield` is syntax."*
- **Python PEP 525 in "the bugs that can't happen".** This only holds
  once the drop trigger is gone, since that bug *is* an effectful
  finalizer running at a drop. Keep it after the Cleanup change. Drop
  the Swift "hidden await" defence.
- **SE-0516.** Replace "lifetime-bounded iteration" with *"iteration by
  `Span` batches for noncopyable elements"*. Ren covers this with
  leased chunks.
- **C# `yield` in `finally` (CS1625).** Add it beside PEP 789 as prior
  art for the `yield` placement rule.

## 4. Decisions for the owner

1. **What is a pipeline?** I recommend **a block, `fn() -> Option<T>`,
   composed where the chain is written** (B). The alternative is the
   draft made sound: a new kind on type variables, `next` with an
   associated type and rows, and a copy rule.
   - What B gives up: storable generic adapters over any cursor.
   - What it affects: decision 1 (`let` binds one chain), rule D, §3,
     compiler size (1,150–2,100 lines against 2,400–4,400), and debug
     and release fusion.
2. **What does calling a `gen fn` give?** I recommend **following the
   signature**: a value cursor if it's pure and takes only values,
   otherwise a pipeline whose frame is a hidden local (B+R). The
   alternatives are:
   - every generator storable (the draft, unsound);
   - an explicit `scoped gen fn` marker, which nothing needs yet.

   It affects storing effectful streams (09 becomes a data reader),
   `yield` inside `with`, user stages, and interpreter cost.
3. **How is a named effectful generator spelled?** I recommend **`let g
   = follow(p)` with `for l in try g`, no `&`**. `&` marks a data place;
   a block's hidden state isn't one, and decision 1 holds. The
   alternative is `var g` plus `&g`, so it reads like `var r =
   Fs.line_reader(p)`, at the cost of the first `var`-bound block. This
   is the closest call in the set. It affects teaching and the "resume
   after `break`" idiom.
4. **What does abandonment look like to `finally(r)`?** I recommend
   **`Err(Cancelled)`**: a transaction rolls back on `break` for free.
   The alternative is a distinct `Stopped`, which is more precise and
   needs every rollback to match it. It affects program 07 and
   `with`-based handlers.
5. **What does a cancel mid-`next` do?** I recommend that it **ends the
   generator and later `next`s give `None`**. The alternative is a
   typed `Ended` in every row. It affects time operators, heartbeats
   and `next(within:)`.
6. **What is the `max:` default?** I recommend **64 everywhere**, as
   decision 7 and async.md say. Pulling only when a slot frees already
   bounds memory, so the draft's "needs a limit" error gives a false
   reason. The alternative is required everywhere (Eth, Erg), which
   means amending decision 7 and async.md. Either way, one call
   shouldn't have two rules.
7. **What shape do the time operators take?** I recommend **a channel
   receiver for `debounce`, `batch(within:)`, `throttle` and `sample`**:
   flat and cancel-safe. A generator source is put on a channel with
   `Async.produce`, and `merge` takes the `produce` shape. The
   alternative is the consumer-block shape for all of them
   (`debounce(src, d) fn(qs) => ...`), which is uniform but adds an
   indent to every use. It affects `stream.time` and program 08.
8. **When does push through one-input stages, and eager fusion of pure
   collection chains, enter the plan?** I recommend **now, in the
   design**. Both reuse B's chain composition, about 400–800 lines
   together. The alternative is Later, with `.cursor()` documented as the
   fast path. It affects property 8, programs 05 and 09, and the
   compiler's own passes.
9. **How does `Async.produce`'s producer send?** I recommend **an
   installed `Send<T>` dependency**. The alternative is the draft's `out`
   value, which is a held channel instance and against the bet. It
   affects decision 6 and the `produce` signature.
10. **Where does a pushed recursive generator recurse?** I recommend
    **pushing only non-recursive producers at first**: a self-recursive
    `yield from` pulls. The alternative is running pushed recursion on
    the task's frame allocator. It affects stack-overflow behaviour on
    deep trees, the one way push and pull can be told apart.
11. **Should decision 2's handler-state row be narrowed?** I recommend
    **yes, to `Async.until`, `release` and block-parameter calls**.
    The alternative is keeping the row, and actors copy a cursor out
    and back in around every loop. It affects foundations.md decision 2
    and program 10.
12. **What happens to a leased slice kept past the body's turn?** I
    recommend **a compile error with a `.copy()` fix-it where the keep
    is visible, plus a debug report otherwise**. The alternative is the
    compiler copying out silently at the keep point, which is a copy
    found behind your back. This one belongs to runtime-io.md. It
    affects program 02, where 10k connections stall the pool.
13. **What do the interpreter's generators run on?** I recommend
    **one-shot fibers for effectful generators, and replay to copy pure
    value cursors**, about 450 lines. The alternative is a Core state
    machine first, 1,500–2,500 lines and high risk. It affects when 11c
    can ship.
14. **Minor defaults, to confirm together:**
    - choosing between pipelines with `if` is an error with "choose
      inside one block", with tag dispatch if it bites;
    - stage names are reserved on cursor types;
    - lookahead loss is documented, not given a peek;
    - a dynamic N-way merge uses data readers for now.

## 5. Appendix: the design at its best

Written to the amended design.

### CSV with errors per line as values (program 06), against Rust's `csv`

```ren
pub fn summarize(path: Path) -> Totals ! FsError | NoHeader | Misaligned | TooManyBad
    uses Fs =
  var lines = Fs.line_reader(path)
  let Some(head) = try &lines.next() else fail NoHeader
  let h = try Header.parse(head)
  try &lines.with_index()
    .map(fn((i, l)) => try parse_line(i + 2, l, h))   // -> Result<Trade, BadLine> ! Misaligned
    .reduce(Totals.empty, fn(t, r) => try t.absorb(r))
```

```rust
let mut rdr = csv::Reader::from_path(path)?;
let mut t = Totals::default();
for (i, rec) in rdr.deserialize::<Trade>().enumerate() {
    let line = i + 2;
    match rec {
        Ok(tr) => t.add(tr),
        Err(e) => match e.kind() {
            csv::ErrorKind::UnequalLengths { .. } | csv::ErrorKind::Io(_) =>
                return Err(Fatal::Misaligned(line, e)),
            _ => { if t.bad.len() >= 1000 { return Err(Fatal::TooManyBad) }
                   t.bad.push(BadLine { line, why: e.to_string() }); }
        },
    }
}
Ok(t)
```

The fatal/recoverable split is in `parse_line`'s signature, not in a
`match` on error kinds at the use site. That's 8 lines against 16, and
`&lines` says the header was consumed from the same reader.

### Rows in a transaction, reusable, with `break` (program 07), against C#

```ren
pub gen fn orders_in_tx(c: CustomerId) -> Order uses Sql ! DbDown | Conflict | BadRow =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try Sql.rows(q, c)
      yield try Order.from_row(row)

for o in try orders_in_tx(c)
  if o.total > limit then break        // finally(r) sees Err(Cancelled): rollback
  try w.write_line(o.csv())
```

```csharp
async IAsyncEnumerable<Order> OrdersInTx(long c,
    [EnumeratorCancellation] CancellationToken ct = default) {
    await using var conn = await ds.OpenConnectionAsync(ct);
    await using var tx = await conn.BeginTransactionAsync(IsolationLevel.RepeatableRead, ct);
    await using var cmd = new NpgsqlCommand(q, conn, tx) { Parameters = { new() { Value = c } } };
    await using var rd = await cmd.ExecuteReaderAsync(ct);
    while (await rd.ReadAsync(ct)) yield return Order.From(rd);
    await tx.CommitAsync(ct);
}
await foreach (var o in OrdersInTx(c)) { if (o.Total > limit) break; ... }
```

This has the same shape as C# and Go, without the token plumbing. And
when the consumer's writes must join the transaction, Ren's version A
(the consumer owns the `with`) puts them in it by indentation. C# can't,
and Spring does it through a hidden context.

### Debounce, tested on virtual time and replayed (program 08), against Kotlin

```ren
fn searcher() ! SearchDown uses Queries, Search, Results, Clock, Async =
  for q in stream.time.debounce(Queries.items(), Duration.ms(300))
    Results.show(try Search.run(q))

test "a burst collapses to its last query" =
  with sync.channel(16) as Queries, recorded_results() in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Queries.send("r"); Clock.sleep(Duration.ms(100))
        Queries.send("re"); Clock.sleep(Duration.ms(100))
        Queries.send("ren"); Clock.sleep(Duration.ms(1000))
        Queries.send("rust"); Queries.close()
      var seen = []
      for q in stream.time.debounce(Queries.items(), Duration.ms(300))
        &seen.push((Clock.now() - Time.epoch, q))
      assert seen == [(Duration.ms(500), "ren"), (Duration.ms(1200), "rust")]

test "yesterday's incident" =
  with replay("tests/incident-2026-10-28.journal") in try flusher()
```

```kotlin
fun searcher(queries: ReceiveChannel<String>) =
    queries.receiveAsFlow().debounce(300.milliseconds).map { search(it) }

@Test fun burstCollapses() = runTest {
    val ch = Channel<String>(16)
    launch { ch.send("r"); delay(100); ch.send("re"); delay(100); ch.send("ren"); delay(1000); ch.send("rust"); ch.close() }
    val seen = ch.receiveAsFlow().debounce(300).map { currentTime to it }.toList()
    assertEquals(listOf(500L to "ren", 1200L to "rust"), seen)
}
```

The two are about as long. Ren adds schedule exploration (`ren test
--seeds 1000`) and replay of a production journal, and has no
`Dispatchers.IO` escape from virtual time. Because `recv` is
cancel-safe, a hand-written `batch` can't drop an item; Kotlin's prompt
cancellation can.

### Merge two transformed sorted streams with a key (program 04), against Kotlin

```ren
try merge_by(Db.rows(q).map(Event.from_row),
             Fs.line_reader(path).map(parse_event),
             fn(e) => e.at)
  .take(1000).to_array()
// merge_by: a 15-line user gen fn over two pull blocks (§2, Producers)
```

```kotlin
fun <T> merge(a: Flow<T>, b: Flow<T>, cmp: Comparator<T>): Flow<T> = flow {
    coroutineScope {
        val ca = a.produceIn(this); val cb = b.produceIn(this)
        var x = ca.receiveCatching().getOrNull(); var y = cb.receiveCatching().getOrNull()
        while (x != null || y != null) {
            if (y == null || (x != null && cmp.compare(x, y) <= 0)) { emit(x!!); x = ca.receiveCatching().getOrNull() }
            else { emit(y); y = cb.receiveCatching().getOrNull() }
        }
        ca.cancel(); cb.cancel()
    }
}
```

Kotlin's Flow is push-only, so a sorted merge costs two coroutines and
two channels. Go's `iter.Pull` costs a coroutine switch per item. In Ren
both sources are pulled by direct calls, `merge_by` is specialized per
block, and both sources' `finally`s run at the end of the statement.
This is the program the cursor design exists for, and the draft couldn't
write it.

# Judge: ergonomics

Lens: read the ten paper programs side by side with Kotlin, C#, Go, Elixir
and Rust. Where does Ren read best, where worst, what does a newcomer trip
on, and would a Kotlin or C# programmer feel at home?

Inputs: streams.md (the candidate), programs/01 to 10, probe-ethos,
probe-prior-art, probe-soundness, probe-feasibility, alt-1 (what a
pipeline is; recommends **B**, "pipelines are blocks") and alt-2 (what a
generator cursor is; recommends **R**, "a generator that suspends is a
frame, a resource is an id").

## The short version

The core reads very well. On the programs where a stream is made and
consumed in one place, Ren is the shortest or the clearest of the six
languages, usually both: 01, 05, 06, 07A, 08 and 10A3. What the draft
gets right ergonomically is real: one `try` on the `for` instead of
Rust's `Result` threaded through every adapter; fatal against
recoverable in the signature; `gen fn` with `yield from` instead of Go's
`bool` threading or C#'s nested `foreach`; no `flowOn`, `Dispatchers`,
`[EnumeratorCancellation]` or `ConfigureAwait`; a bounded `Async.map`
instead of Kotlin's `async` + `buffer` + `await` folklore; debounce
tests with no scheduler plumbing.

It reads worst in three places, and each one is the first thing a Kotlin
or C# programmer reaches for:

1. **Returning or factoring out a pipeline** (09 step 2). In Kotlin you
   return a `Flow<T>`, and in C# an `IAsyncEnumerable<T>`. In Ren it's an
   error, and the fix (a `gen fn`) is fine, but under the draft it costs
   the fusion, and the result's type has no name (09 step 5).
2. **Writing your own stage** (`merge_by`, `dedup_by`, `scan`: 04 use 3,
   09 step 6). Kotlin has extension functions on `Flow`, C# has extension
   methods with `yield return`, Go has `func(iter.Seq) iter.Seq`, and
   Rust has itertools. Under the draft it's impossible to do lazily.
3. **The `&` and the copy question.** `for e in try &follow(p).map(...)`
   puts `try &` on every loop, including temporaries where `&` says
   nothing. And `r.map(parse)` silently steps either a copy or the
   original, depending on how the cursor's author stored its state
   (01 item 3, 06 item 1). That is the worst trap in the draft for a
   newcomer, because nothing on the page or in the type says which.

Both alternatives fix all three: alt-1 B for pipelines, alt-2 R for
generators. They also make the doc shorter, which is a good ergonomic
sign. I recommend both, with a few ergonomic adjustments below.

## Side by side: who reads best per program

| Program | Best reader | Ren under the draft | Ren under B + R |
|---|---|---|---|
| 01 tail a log | **Ren** (Kotlin close) | producer like Kotlin's `flow {}` with no dispatcher; `try` once; resume after `break`, which Kotlin can't do without a channel | same, with no `&` on temporaries, and the close point is defined |
| 02 pg framing | Rust tokio-util (Ren's format is better per kind) | formats beat everyone on per-kind decoding, but every program hand-writes the accumulate-and-retry loop, and `buf ++ c` is quadratic | with `Net.frames(conn, PgMessage.wire)` it's **one line, best in class** |
| 03 crawler | **Ren** for the policy, Elixir for brevity | the typed fatal/skip policy is the best; `map_pull` hides a scope; skip vs fatal needs a second function | `map_pull` in `produce` shape: one more indent, honest |
| 04 merge two sorted | Rust itertools (1 line) | can't take a comparator or a mapped source; a `gen fn` per source | `merge_by(a, b, fn(e) => e.at)` with mapped sources: on par with Go and Kotlin, cheaper than both |
| 05 tree walk | **Ren** | 4 lines, push cost; but `.select().take()` silently pulls at O(depth) | push through one-input stages: same cost both ways |
| 06 CSV | **Ren** | 8 lines against 15 to 16; the copy-vs-borrow fork after reading the header | `&lines.with_index()...`: the source is on the page |
| 07 rows in a tx | **Ren** for 7A; C# and Go for the reusable one | 7A is the best of all five; the reusable version is refused and falls back to a block with `Go`/`Stop` | `yield` inside `with` is legal, and `break` rolls back: on par with C# and Go, and 7A stays best |
| 08 debounce, batch | Rx for brevity, **Ren** for tests and replay | `Events.items()` doesn't exist; time ops over a generator are unbuildable | time ops over a channel receiver: flat, cancel-safe |
| 09 stored pipeline | Kotlin and C# | refused, then unfused, then an unnamed type, then no user stage | `gen fn` stays fused when it's consumed by a `for` or a sink; a stored *suspending* generator becomes a record with `next` (R's price) |
| 10 actors | Elixir for B, **Ren** for A2, A3, A4 | `yield` in `Docs.each` isn't forbidden, but it must be | one rule: no `yield` inside a block |

## Would a Kotlin or C# programmer feel at home?

**Kotlin: mostly yes.**

- `gen fn` is `flow {}` / `sequence {}`, with `yield` for `emit`.
- `xs.cursor().select(...)` is `xs.asSequence().filter(...)`: the
  receiver decides eager or lazy, which is Kotlin's own model.
- `take` ending the producer and running its `finally` is Flow's
  abort-at-`emit`.
- `Async.produce(cap:)` is `channelFlow { send() }` / `produceIn`. With
  probe-ethos B4's `uses Send<Page>` instead of an `out` value, it's
  even closer, since Kotlin's `send` is on an implicit receiver too.

**C#: yes for producers, no for return types.** `yield return` is
`yield`, and `foreach` + `break` disposing is the temporary's
behaviour. But C# programmers return `IAsyncEnumerable<T>` and LINQ
chains everywhere.

**The culture shocks, ranked:**

1. **"Can't return this."** Every Kotlin and C# helper returns a
   stream. The error message and its fix-it carry the whole weight
   here. The draft's error is good. It's only acceptable if the
   `gen fn` it suggests costs the same (push through stages) and its
   type can be written (`errors_since.Cursor`).
2. **`&` and `try` on the loop header.** `for e in try &x` is three
   tokens before the source. `try` earns its place, since it's Ren's
   error model. `&` on a temporary doesn't.
3. **No extension operators.** It's fixed by "a `gen fn` that takes a
   block gives a pipeline". The stages are then calls or `|>` steps, not
   methods (§7), which is a smaller shock.
4. **`select`/`reject` for `filter`/`Where`.** It's already settled by
   `Array` (Ruby's `Enumerable`). Not reopening it, but the error for
   `.filter(` should suggest `.select(`.

**Where Ren beats them both:**

- **One kind of stream.** There's no `Sequence`/`Flow` split, and no
  `IEnumerable`/`IAsyncEnumerable` with two LINQs.
- **No context or cancellation plumbing.** No `flowOn`, no
  `CancellationToken`, no "Flow invariant is violated" at run time.
- **Failures are typed and visible.** Kotlin and C# decide fatal
  against skip by testing the exception's type at run time (03).
- **Transactions.** 7A puts the consumer's writes in the producer's
  transaction by indentation. Spring does it through a hidden context.
- **Resuming after `break`.** Kotlin needs a hot channel.
- **Tests and replay.** No test dispatcher, schedule exploration over
  seeds, and replay of a production journal.

## Newcomer trip list (what to fix, or teach in the error)

| Trip | Where | Fix |
|---|---|---|
| `r.map(f)` steps a copy or the original, depending on the cursor's author | 01.3, 06.1, 09.5 | B: `&r.map(f)` on a named place; plain `r.map(f)` is an error with two fix-its |
| `&` required on a temporary | 05.4, 06.2 | `&` only on named places (B rule 2) |
| `let errors = ...` then `for e in try &errors` breaks three rules | 01.4, 06.3 | B: `let` binds a chain; `for e in try errors` |
| The helper extracted from a pipeline is slower | 05.2, 09 | push through one-input stages now (B rule 8) |
| The `finally` of a named cursor runs at an optimizer-chosen drop | 01.1, 05.3 | R: at the end of the `var`'s scope, `Err(Cancelled)` |
| A `gen fn` copied mid-stream closes its file twice | 01.5, 05.3 | R: a frame cursor can't be copied; a pure one forks honestly |
| A `with` around `yield` is refused, though C# and Go allow it | 07B | R |
| The cursor escaping a `with` compiles and breaks at run time | 07D | R's with-escape error |
| `yield` inside `Docs.each`/`xs.each` isn't on the list | 10 B1 | one rule: not inside a block or `finally` |
| `yield from walk_dir(c)` fails without a marker | 05.1 | `yield from try walk_dir(c)` |
| `try` inside a stage and `try` on the `for` look doubled | 06.5 | keep both; teach it once in the doc; the `for`'s error names the stage ("from the `map` on line 12") |
| A one-stage-per-line chain doesn't parse | 06.4 | a line starting with `.`, indented further, continues the line above, as `\|>` does (§8) |
| A slice kept from a leased chunk pins a pool buffer, and the server stalls | 02.3 | open; at least a debug-build error at the keep point |
| Two `.next()` spellings (`&c.next()` on a cursor, `p()` on a pipeline under B) | alt-1 B | spell both `p.next()` (alt-1 offers it as cosmetic; I'd take it: one way to step) |

## Verdicts, section by section

### What it has to do — **change**

- Keep properties 1, 3, 4, 5, 6, 7 and 8.
- Restate property 2 as two plain rules:
  - a loop over a temporary closes it at `break`;
  - a named cursor closes at the end of its `var`'s scope.

  That's R, and the honest version of probe-prior-art F4.
- Add a property the survey found and the draft lacks: **users can write
  their own lazy stages** (prior-art F2). It's what Kotlin, Elixir, Go and
  Effekt all have, and it's what decides whether the default set is a floor
  or a ceiling.

### Where Ren stands — **change**

- Apply probe-prior-art's corrections:
  - Kotlin goes in the "two of everything" table (`Sequence` against
    `Flow`), not in "one kind";
  - drop "nobody" from the time row. The claim is "time can't escape
    `Clock`, plus replay from production";
  - `Pin` is about futures, not iterator adapters.
- This matters for ergonomics, not pedantry: the Kotlin and C# readers
  this table is written for will know these facts, and stop trusting the
  rest.

### One kind of stream: the cursor — **keep**

The strongest section, and the one a newcomer gets at once. The resume
example stays, with B's spelling. Backpressure: add that a slice kept past
the body's turn holds its lease (02.3).

### Pipelines: a value that holds a block is a block — **change to alt-1 B, "pipelines are blocks"**

- A chain is a block the compiler writes where the chain is.
- `let p = chain` binds it, and `for x in try p` loops over it.
- The head is `&r` for a named cursor, and bare for a temporary.
- Users never see a kind on type variables, an associated type or a
  `<block C has next -> Row ! e uses u>` signature. Under A, that
  signature would be the heaviest in the language, on every generic sink.
- Under B a sink is `rows: fn() -> Option<Row>`, which a Go programmer
  reads at once.

Ergonomically, B wins on every program. It's also what makes the
flagship example legal.

**Sub-sections:**

- **One vocabulary, two receivers: keep.** It's Kotlin's `List` against
  `asSequence()`, so it's familiar. Add probe-ethos M1: a pure eager chain
  on a collection (no `uses` in its blocks, no writes to captured places)
  fuses into one loop. Then the chain everyone writes first,
  `orders.select(...).map(...).sum()`, isn't the slow one, and laziness is
  for when it's observable. Kotlin needs an IDE inspection for this, and
  Ren can just do it.
- **`next` joins the built-in requirements: drop** (alt-1 B). The stage
  vocabulary is the pull type's, reached structurally on cursors as `for`
  reaches `next`. A cursor type can't declare `map` or `count`, so `.`
  never means two things.
- **Exclusivity, step by step: keep, reworded** as the existing rule for
  a `let`-bound block. Nothing new for users to learn: the `limit` example
  just works.
- **Pipelines and the pipe: keep, and add two things:**
  - the `.`-leading line continuation (06.4);
  - one sentence on user stages after `|>`:
    `(&r.map(parse) |> dedup_by(fn(e) => e.code)).take(10)` needs
    parentheses, because §8 says a chain ends its expression. Teach the
    `let` form, `let d = dedup_by(&r.map(parse), fn(e) => e.code)` and
    then `d.take(10)`, as the idiom. Leave relaxing §8 open until real code
    hits it.
- **No comprehension syntax: keep.**

### Producers: `gen fn` — **keep the core, change the rules (alt-2 R plus alt-1 B rule 7)**

- **Keep:** `gen fn` as the one way to write a producer with control
  flow, `yield from`, and the "when to use which" paragraph. The syntax
  reads better than any counterpart.
- **Change: a `gen fn` that takes a block gives a pipeline** (both
  alternatives reach this independently). This is how users write
  `merge_by`, `dedup_by` and `scan`, and the "a `gen fn` can't take a
  block" error disappears. It's the single biggest ergonomic gain
  available.
- **Change: a `gen fn` whose `uses` reaches a dependency gives a frame
  cursor** (R):
  - it can't be copied or stored;
  - its cleanup runs at syntactic points.

  For a newcomer the trigger is ideal, since it's the `uses` line they
  already wrote. **The price is 09's per-client stored tail.** Kotlin and
  C# store such streams freely, and Ren makes you store a record with a
  `next`. Accept it only if the library ships storable readers for the
  common resources (`Fs.LineReader`, a `Tail`, `Net` readers). Then
  "keep a position" is ordinary data, and the error's help can name the
  reader.
- **Change: name the type,** `walk.Cursor` (R, Q6), and let a
  non-recursive `yield from` stay unboxed (09.2).
- **Pushed when it can be: change.** Push through one-input stages now,
  not later (B rule 8, probe-ethos M3). The hover says "pulled: zip"
  where pull is forced. Without this, extracting a helper (the most
  ordinary refactor) silently changes the cost.
- **Blocks inside a generator's frame: drop for frames** (R removes the
  need). Keep it for value cursors only, if they keep the state machine.

### Errors — **keep, with three additions**

- `yield from try child(...)`.
- Cancelling a generator mid-`next` ends it, and later `next`s give
  `None` (R Q4).
- The `for`'s "`next` can fail" error names the stage that fails.

The section is the best-reading part of the design, judging by 01, 03
and 06. Leave the "two-layer policy" friction in 03.2
(`attempt(on: Server | Timeout)`) to errors.md, as a later question.

### Cleanup — **change to R**

- Cleanup runs at three points: the end of a loop over a temporary, the
  end of a named cursor's `var` scope, and a cancel. All are unwinds, and
  `finally(r)` sees `Err(Cancelled)` when the generator is abandoned, so
  a transaction rolls back on `break` as C# and Go do.
- Delete the drop bullet and the Swift paragraph.
- For a Kotlin or C# reader this is `use {}` and `await using` with no
  keyword: easy to learn and easy to see.
- Keep "the bugs elsewhere can't happen", minus the PEP 525 claim, which
  only holds once drop-time cleanup is gone.

### Cursors over resources — **keep the principle, change the rules**

- **Keep:** "state in the service, ids and offsets in the cursor".
- **Change:**
  - the `&` error applies only to named places (B);
  - fix the RFC 3550 citation (its lesson is that iterators shouldn't
    copy);
  - add R's with-escape compile error, and incarnations as the run-time
    backstop;
  - **add `Net.frames(conn, fmt)`** (02). It turns the hardest program in
    the set into the best-reading one, and removes a quadratic `buf ++ c`
    from the obvious code.

### Concurrency — **keep the shape, make the tasks visible and the common case flat**

- **Generators stay on the consumer's task: keep.** Replace the `yield`
  list with one rule: "not inside a block or a `finally`" (R, 10.1), and
  allow `with` (R).
- **`Async.produce`: keep.** Use `uses Send<T>` for the producer instead
  of an `out` value (probe-ethos B4). It reads like Kotlin's
  `channelFlow`, and channels stay dependencies. The doc should show the
  layout for a call with a block argument *and* a trailing block. Today
  `Async.produce(cap: 16, fn(out) => ...) fn(pages) =>` reads awkwardly
  when the producer is more than one line (03, 07 C2).
- **Many items at once:** keep `Async.each` and `Async.map` with `max:`
  required. That reads better than async.md's default of 64 (03.3), so
  update async.md. State the ordered-window semantics: a finished result
  waiting behind a slow one keeps its slot (prior-art F8).
- **`Async.map_pull`: change to the `produce` shape,**
  `Async.map_pull(src, max: 16, fn(u) => fetch(u)) fn(results) => ...`
  (03.1, probe-ethos M4). It costs one indent against Kotlin and Elixir,
  but buys a scope you can see and sound exclusivity.
- **Channels are cursors: change.** `for m in Jobs.items()`, a
  compiler-derived cursor per channel alias (08.2 and 08.3). That's as
  short as Go's `range ch` and Kotlin's `for (m in ch)`.

### Time — **change**

- Correct the claim (prior-art).
- **Make the operators take a channel receiver:**
  `for q in try stream.time.debounce(Queries.items(), Duration.ms(300))`.
  - 08 shows this is correct with no hidden task, because `recv` is
    cancel-safe, and it stays flat, as Kotlin's `.debounce(300)` is.
  - To debounce a generator or a pipeline, put it on a channel first
    with `Async.produce`, so the task is on the page.
  - This keeps the common case (events arrive on a channel) one line,
    and avoids a continuation-form `debounce(src, d) fn(qs) => ...` on
    every use.
- Keep `merge` (of live sources) in the `produce` shape, since it needs
  tasks either way.

### The standard library — **change**

- Add `scan`, `dedup_by`, `chunk_by` / `chunk_while` (with a flush at the
  end), and `Net.frames`. Elixir's `Stream` has them, and 06, 08 and 09
  wanted them.
- With user stages possible, the set can stay Elixir-sized: users can
  write the rest.
- Keep the left-out list.
- **Open:** an overflow policy (`conflate`, keep-newest) for telemetry and
  UI streams. Kotlin and Swift have one, and `sample` needs it internally.

### Compiler errors — **keep the style, update the set**

These are the best thing in the doc for newcomers. Changes:

- **Drop** "a `gen fn` can't take a block".
- **Narrow** the missing-`&` error to named places, with B's two fix-its
  (`&r.map(f)` steps `r`; `let c = r` then `&c.map(f)` steps a copy).
- **Add:**
  - "`follow` uses `Fs`, so its cursor can't be copied or stored", with
    help that names the storable reader;
  - "`Sql.Rows` can't leave the `with` that installs `Sql`";
  - "`yield` inside a block".
- **Keep** the "returned / stored / captured by a task" error and its
  `gen fn` fix-it, unchanged. It's the most important teaching error in
  the design.

### What it changes — **change** to match

- Rule D and §3 are no longer amended.
- Decision 1's `let` gains "or one chain".
- Decision 2's table gains R's interval row.
- async.md's `Async.map` default goes.

### Left out — **keep**

Affine cursors stay out. R's frames are block-kind, not affine.

### Later — **change**

Fusion through a `gen fn` moves into the plan. `unordered: true` and
broadcast stay later.

### Evidence — **change**

Apply probe-prior-art's citation fixes: Effekt and rule A, RFC 3550,
SE-0516, and Go's push lowering.

## Top 5 recommendations, ranked

1. **Pipelines are blocks, with the source written explicitly**
   (alt-1 B).
   - `&r.map(f)` on a named cursor; a bare temporary head; `&` required
     only on named places; `let p = chain`; `for x in try p`.
   - It removes `try &` from most loop headers and the silent
     copy-or-borrow fork, the worst newcomer trap in the draft.
   - Sinks get plain signatures (`rows: fn() -> Option<Row>`) instead of
     a kind and an associated type.
   - Spell hand-stepping `p.next()` on both cursors and pipelines, so
     there's one way to step.
2. **Users can write lazy stages: a `gen fn` that takes a block gives a
   pipeline.** With it, push through one-input stages now. This closes
   the largest gap against Kotlin, C#, Go and Rust (`merge_by`,
   `dedup_by`, `scan`; 04 and 09). It also keeps an extracted helper as
   fast as the inline chain, which is the refactor every Kotlin or C#
   programmer will make on day one.
3. **Generators that use a dependency are frames** (alt-2 R).
   - Cleanup runs at visible points, with `Err(Cancelled)` on `break`,
     so a transaction rolls back.
   - `yield` inside a `with` is legal, so 07's reusable transaction
     stream reads like C#'s and Go's.
   - A cursor can't escape its `with`.
   - Value cursors get a name (`walk.Cursor`).
   - Pay for it by shipping storable library readers, so "keep a
     position per client" (09) is ordinary data, not a hand-written
     state machine.
4. **Concurrency you can see, with the common case kept flat.**
   - `stream.time` operators take a channel receiver
     (`Jobs.items()`): flat and cancel-safe.
   - `map_pull` and `merge` take the `produce` shape.
   - `Async.produce`'s producer `uses Send<T>`.
   - One rule for `yield`: not inside a block or a `finally`.
   - `max:` is required, and the ordered window is stated.
5. **Make the bytes and layout stories best in class.**
   - Ship `Net.frames(conn, fmt)`, which makes 02 one line where Rust
     needs a `Decoder` and Go a hand loop.
   - Add the `.`-leading line continuation, so multi-line chains parse
     and format like Kotlin's and C#'s.
   - Fuse pure eager chains on collections, so the chain people write
     first is the fast one.

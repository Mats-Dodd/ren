# Judge: fit with the ethos

Lens: one mechanism per question, nothing found behind your back, the
obvious way is the fast way, explicit over magic, not clever. Read
against streams.md (the candidate, not decided), the four probes, alt-1
(what a pipeline is), alt-2 (what a generator's cursor may be) and the
ten paper programs.

## Verdict in one paragraph

The draft's spine fits the ethos well. It has one kind of stream (the
cursor), no colours because of `uses`, producers written as `gen fn`,
time taken from `Clock`, no comprehension, no Emit dependency, and no
hot flows or schedulers. Its trouble is in the joints. In four places
it either adds a second mechanism to a question Ren already answers, or
does something you can't see:

1. **`next` as a requirement** adds a second answer to "do this for any
   type", beside blocks (§3).
2. **Effectful `finally` at a Perceus drop** is cleanup found behind
   your back, and it breaks decision 11.
3. **Pipelines that copy their source silently,** so the meaning
   depends on how the cursor's author stored its state.
4. **Concurrent stream operators that hide a task scope** (`map_pull`,
   `debounce`, `merge`).

Alt-1's option B (a pipeline *is* a block) and alt-2's R (whether a
generator's cursor is a frame or a value follows from its signature)
fix all four with existing mechanisms. **But the two alternatives
contradict each other, and they have to be merged before either goes
into the doc** (see "Reconciling alt-1 B and alt-2 R" below). Merged,
they leave fewer mechanisms than the draft, and fewer rules than
foundations.md has today.

---

## Counting the ways

"Ways" means distinct mechanisms a programmer has to choose between for
one question, not methods in the library.

### After the draft

| Question | Ways in the draft | Ethos problem |
|---|---|---|
| **Make:** write a producer with control flow | `gen fn`; a hand-written type with `next` | Two ways, which is fine: they answer different questions. But "`gen fn` is the one way" overstates it (probe-ethos m2) |
| **Make:** a stream over a collection | `xs.cursor()` | — |
| **Make:** a stream fed by tasks | `Async.produce`, `Async.map_pull`, `merge`, `debounce`, `batch(within:)` | Three different shapes. `produce` brackets its scope with a block; `map_pull` and the time operators return a cursor holding a hidden scope (probe-ethos M4, programs 03 and 08) |
| **Make:** a queue | a channel "as a cursor", `for m in &inbox` | A channel is a dependency (decision 6), so `inbox` isn't a value the program has (probe-ethos B4) |
| **Transform** with a built-in stage | `.map` and the rest on a cursor (lazy), the same names on a collection (eager) | One vocabulary, two meanings, chosen by an inferred type (M1) |
| **Transform** with my own lazy stage | **none**: a `gen fn` can't take a block, and a function can't return a pipeline | The built-in vocabulary is a ceiling users can't reach (prior-art F2, programs 04 and 09) |
| **Transform,** stored | a `gen fn` with no block | — |
| **Transform,** concurrently | `Async.map` (eager), `Async.map_pull` (lazy, hidden scope) | One hides a scope |
| **Consume** | `for x in &c`, `for x in &temp()`, sinks (`.sum()`), `&c.next()` by hand, `Async.each` and `Async.map`, a parameter `C has next`, `\|>` | `&` on a temporary is noise. The pipe carries a hidden `&r` (probe-soundness §1) |
| **Generic over any stream** | the `next` requirement **and** blocks | **Two mechanisms for §1's "do this with any type"** |
| **Who cleans up** | `finally` at the end of a loop; at a drop; on cancel; and the service's `with` | One trigger is at a point Perceus chooses |
| **Can this stream be kept?** | a pipeline can't; a `gen fn` can, including over a socket with a buffer in its frame | The answer is "yes" exactly where copies are unsound (alt-2 Q1, Q2) |

**Tally:** 7 ways to make (4 mechanisms), 5 ways to transform, one of
them missing for users, 7 ways to consume, **2 mechanisms for generic
code**, **3 cleanup triggers, one of them hidden**, and 3 shapes for
concurrent streams.

### After alt-1 B alone (a pipeline is a block)

- **Generic over any stream:** blocks only (`rows: fn() -> Option<T>`).
  The `next` requirement goes away, and so does the kind on type
  variables. §3 doesn't change.
- **Your own lazy stage:** a `gen fn` that takes a block gives a
  pipeline. That's the same mechanism as the built-in stages, so the
  ceiling is gone.
- **Source:** `&r.map(f)` is a write of `r` you can see. A temporary
  head needs no `&`. The missing-`&` error applies only to named
  places.
- **"Exclusivity, step by step"** stops being a new rule. It's the
  existing rule for a `let`-bound block's captures.
- **Unchanged:** cleanup, generator copies and concurrent shapes. Alt-1
  leaves these "to other points".

### After alt-2 R alone (the cursor's kind follows from the signature)

- **Who cleans up:** syntactic points only, plus the service as a
  backstop. The hidden trigger goes.
- **Can this be kept?** A generator is kept if it's pure and takes only
  values. Otherwise it's frame-kind, under rule D's restrictions. The
  kind is read off `uses`, which is already on every public signature,
  so nothing new is found behind your back.
- **`yield` inside `with`:** becomes legal, so program 07's library
  version can be written.
- **The `yield` ban:** one rule ("not inside any block or `finally`")
  replaces the list.
- **Unchanged:** keeps the `next` requirement and "the frame kind on
  type variables, which pipelines need anyway". Alt-1 B deletes exactly
  that.

### After B and R merged (recommended)

| Question | One answer |
|---|---|
| Write a producer | `gen fn` |
| Keep a stream's position as data (store it, put it in a map) | a record with `next`: an id and an offset, "model with data". The library's `Fs.line_reader`, `Net.chunks`, `Db.rows` and `xs.cursor()` are this |
| A stream fed by tasks | one shape: `Async.produce(src…) fn(out) => …`; `map_pull`, `merge` and the time operators take the same block-bracketed form |
| A queue | a channel, which is a dependency; `Jobs.items()` is a library cursor over it |
| Transform where consumed | `.stage(...)` on the pull type; a user stage is a `gen fn` that takes a block |
| Transform, kept | a pure `gen fn` with value parameters (a value cursor), or a record |
| Generic over any stream | a block parameter, `fn() -> Option<T>` |
| Consume | `for`, a sink, `Async.each` or `Async.map`, or passing it down as a block |
| Who cleans up | `finally`, at a point the syntax fixes; the service's `with` as backstop |
| Can this be kept? | the block rule (rule D), for pipelines and effectful generators alike |
| Eager or lazy | the head: a collection is eager, a cursor head (`&r`, a cursor-returning call) is lazy |

**Tally:** 4 ways to make (gen fn, record, task-backed, channel), each
for a different question. 2 ways to transform (a stage, or a `gen fn`
as a stage). 4 ways to consume. **One mechanism for generic code, one
cleanup rule, one concurrent shape.** That's fewer than the draft on
every row, and §3, decision 1's spirit and decision 11 hold unamended.

---

## Reconciling alt-1 B and alt-2 R

R says a frame cursor "can be passed down as `&g`, including to `C has
next`", and that its block kind "pipelines need anyway". B deletes both
`C has next` and the kind on type variables. Taken literally, R
reintroduces what B removes.

The way out is already in B's rule 7: "a `gen fn` that takes a block
gives a pipeline, its frame a hidden local of the caller". Extend that
trigger to R's:

> **Calling a `gen fn` gives a value cursor if the `gen fn` uses no
> dependency and takes only values. Otherwise the call is a pipeline:
> a block whose state, the generator's frame, is a hidden local of the
> caller.**

Then:

- **R's "frame cursor" and B's "pipeline" are one thing.** There's one
  block kind, checked by the rules that exist (decision 1 widened to
  "one literal block or one chain", rules A–D, and per-block
  specialization). It's passed down as `fn() -> Option<T>`, not
  through a type variable.
- **R's cleanup points come free.** A hidden local's frame ends where
  the enclosing scope ends, so `finally` runs at the end of the `for`
  over a temporary, at the end of the statement holding a sink, at the
  end of the scope of the `let` that binds it, or on cancel. Every one
  is an unwind.
- **R's "dependencies are found where the frame is made"** is decision
  5 for blocks, unchanged.
- **Value cursors** (pure, value parameters) stay storable data. They
  need only the resume re-check from probe-soundness §4 (one compare
  per `&` held across a `yield`).

**One spelling question remains,** and the owner should settle it. A
named effectful generator becomes `let g = follow(p)`, and `for l in try
g` resumes where the last loop stopped, with no `&`. That's honest under
decision 1, because `g` never changes and its hidden frame does, just as
`let f = fn() => n += 1` changes `n`. But it reads differently from
`var r = Fs.line_reader(p)` and `for l in try &r`.

- **Recommended:** keep the one rule, "`&` marks a data place being
  changed; a block's state is never a place you name".
- **The alternative:** allow `var` for this one block kind, so both
  read alike. That breaks decision 1's "blocks can't be bound with
  `var`" for a cosmetic gain.

---

## Section by section

| Section | Verdict | To what, and why |
|---|---|---|
| **What it has to do** | **change** | Property 2 can't hold as written for a named cursor that resumes (prior-art F4, feasibility F2). Restate it: "a loop over a temporary cleans up at `break`; a named stream cleans up when its scope ends, never at a point the optimizer picks". Property 6 also needs one line: a pipeline holds blocks, and none are kept. Property 8 holds only with recommendation 5 below |
| **Where Ren stands** | **change** | Move Kotlin from "one kind" to "two of everything" (`Sequence` and `Flow`). Replace the time row's "nobody" with what's actually unique: the same `Clock` in production and in tests, nothing can bypass it, and a run replays from its journal (prior-art; program 08). The cleanup row is "yes" only once the cleanup change is made |
| **One kind of stream: the cursor** | **keep, with one honest sentence** | No async iterator, and `uses` as the only difference, is the strongest fit with the ethos in the draft. Add: "a stream is either data you can keep (a value cursor) or a block you pass down (a pipeline, or an effectful generator)". The split follows `uses`, which decision 12 already uses for suspension, so it's the same line drawn in a second place, not a new one (alt-2 R) |
| **Pipelines: a value that holds a block is a block** | **change** to "**pipelines are blocks**" (alt-1 B) | The draft's rule needs a kind on type variables, `var` blocks and `&` on a `let`, which are three new mechanisms presented as "the checks blocks already have" (probe-soundness §1 and §2, probe-ethos B2 and B3). Under B, a chain is a literal block the compiler writes where the chain is. `&r.map(f)` makes the write of `r` visible, and `r.map(f)` on a named cursor is an error with two fix-its. C (syntax only) fails the paper programs |
| — *One vocabulary, two receivers* | **keep the shared names; change the cost rule** | Is "the receiver decides" behind your back? Mostly no: `.` always resolves through the type (§7). But effect order and where the `try` goes do change with an inferred type. Two changes keep it honest: (a) under B, lazy needs a cursor head you can see (`&r`, or a call that returns a cursor); (b) an eager chain on a collection whose blocks use no dependency and write no captured place fuses into one loop, since nothing can observe the difference (probe-ethos M1). Then the obvious `orders.select(p).map(f).sum()` is also the fast one |
| — *`next` joins the built-in requirements* | **change: drop it** (alt-1 B) | It's the first requirement with outputs and rows, and it's the "`T has area`" idea §3 withdrew, applied to one name. It's also a second mechanism beside blocks for "do this with any stream". With B, a sink takes `fn() -> Option<T>`, as §3 says a generic algorithm takes its operation. The exception isn't worth it, because nothing needs it. B's rule 6 (a cursor type can't declare a stage's name) is the price of reaching the stages structurally, as `for` reaches `next`. Say it plainly |
| — *Exclusivity, step by step* | **change: delete as a new rule** | Under B it's the existing rule for a `let`-bound block's captures: at each call, which is each step, and for the whole call when the pipeline is passed (probe-soundness §3 shows the draft's wording is unsound once a pipeline is passed). Keep the `limit` example as an illustration |
| — *Pipelines and the pipe* | **keep** | `.` for stages and `\|>` for steps from elsewhere fits §7 and §8. Under B the value through the pipe is a block whose head shows the `&`, so §8's "no `&` through a pipe" still holds; give that one sentence. Add a layout rule: a line beginning with `.` continues the chain, as `\|>` does (program 06) |
| — *No comprehension syntax* | **keep** | |
| **Producers: `gen fn`** | **change** (merged B and R) | A `gen fn` that's pure and takes only values gives a storable value cursor. One that uses a dependency or takes a block gives a pipeline. That removes the "a `gen fn` can't take a block" error and adds user-written stages (`dedup_by`, `scan`, `merge_by`), which is programs 04 and 09's main complaint. Rename "the one way to write a producer" to "the way to write a producer with control flow; a record with `next` is how a stream's position is kept as data". Add `yield from try` for a delegated generator that can fail (program 05). Name a value cursor's type, e.g. `walk.Cursor` (alt-2 Q6). Box `yield from` only for recursion (program 09) |
| — *Pushed when it can be* | **keep, and extend** | Push through one-input stages now, not "later" (recommendation 5). Two caveats from probe-feasibility F8 go in a sentence: the push twin's parameters are owned, and recursion moves to the stack. The second is the one thing a program can observe, and it should be said |
| — *Blocks inside a generator's frame* | **change** | Under the merge, effectful generators are never copied, so they need no relative addressing. Pure value cursors keep it and add the resume re-check (probe-soundness §4). It's an implementation note either way |
| **Errors** | **keep** | `for x in try c` and "a failure ends the stream; recoverable errors are values" fits ethos rule 3 well (program 06 is the cleanest of its comparison set). Add three things: an error from a lazy stage is reported at the `for` "from the `map` on line N" (probe-ethos m5); a cancelled `next` ends a generator and later calls give `None` (prior-art F6); and `next(within:)` on service cursors, for deadlines that never cut a generator mid-step |
| **Cleanup** | **change** (alt-2 R) | Delete the drop trigger, and the paragraph defending dependency calls at a drop. It's a close when a count reaches zero (decision 11), at a point Perceus moves (last use, not scope end), with no error channel, and twice on copies. That's the most "behind your back" thing in the draft. Keep loop end, scope end and cancel, each an unwind. `finally(r)` sees `Err(Cancelled)` when the stream is abandoned, so a transaction rolls back on `break` (program 07). The Python, Java, Clojure and Haskell bug list still holds after the change |
| **Cursors over resources** | **change** | The `&` error applies only to named places, so `for row in try Db.rows(q)` needs none. "State in the service, ids in the cursor" is right; carry it through: ids carry their instance's incarnation; a `with` body can't return a cursor over the dependency it installs (decision 7's rule, for values; program 07 D); handles register with their handler as a backstop. Fix the RFC 3550 citation, whose lesson is that copyable iterators are the hazard; under the merge, only pure cursors copy, so it now supports the design |
| **Concurrency — generators stay on the consumer's task** | **change** | Replace the `yield` list with one rule: "`yield` only in the generator's own body, not inside any block or `finally`" (probe-soundness §7, feasibility F9, program 10). Allow `yield` inside `with` for effectful generators (R), since they can't escape. The PEP 789 point stands for scopes |
| — *`Async.produce`* | **keep the shape; change `out`** | It's the right shape: the scope is the call, and its end is on the page. But `out` is a held channel instance. Make it a channel dependency the call installs for the producer block (decision 5's "listed in its parameter's type"), so `crawl` says in its `uses` that it sends (probe-ethos B4). Note in the docs that pins held while sending wait for the consumer (program 10, B2) |
| — *Many items at once* | **keep `each` and `map`; change `map_pull`** | `Async.map_pull` returns a cursor with a scope in it, so its cancel-and-wait happens at a drop, and its concurrent block's reads aren't bounded by any syntax (program 03). Give it `produce`'s shape: `Async.map_pull(src, max: 16, fn(u) => …) fn(results) => …`. State that `each` and `map` pull their source on the caller's task. Under B this is checked, because the source is an ordinary block parameter. State the ordered window: a finished result waiting behind a slow one keeps its slot, so memory is bounded by `max` (prior-art F8) |
| — *`max:`* | **open** | It's required here, but decision 7 defaults it to 64. One call shouldn't have two rules. My lean is required everywhere, since that's more explicit; otherwise, 64 everywhere |
| — *Channels are cursors* | **change** | A channel is a dependency, so `for m in Jobs.items()` is a library cursor over it, and its type names the dependency (program 08, item 3) |
| **Time** | **change** | `debounce`, `batch(within:)`, `throttle`, `sample` and `merge` race "the next item" against a timer, so they need the source on a task (prior-art F1, program 08). That means they take the `produce` shape, not `.` methods on a pipeline. Keep "every one takes its time from `Clock`". Replace "no other language can test `debounce`" with the replay claim |
| **The standard library** | **keep, slightly smaller** | The default set and "left out on purpose" fit the ethos. Under B, users can write `scan` and `dedup_by` as `gen fn` stages, so the default set doesn't have to grow to cover them. Move `map_pull`, `merge` and the time operators under the one concurrent shape. Add `Net.frames(conn, fmt)` from formats.md, because the hand-written `buf ++ chunk` framer is quadratic: the obvious way there is the slow way (program 02). Program 02's leased slice pinning a pool buffer is **open**; it belongs in runtime-io.md |
| **Compiler errors** | **change, to match** | Drop "a `gen fn` can't take a block". Add: "`r.map(f)` on a named cursor: write `&r.map(f)` to step `r`, or `let c = r` to step a copy"; "`follow`'s stream uses `Fs`, so it can't be stored: keep its position as data (`Fs.line_reader`)"; "`Sql.Rows` can't leave the `with` that installs `Sql`"; "a pipeline can't be chosen with `if`: choose inside one block". The fix-it style is exactly right |
| **What it changes** | **change** | Rule D and §3 are no longer amended. Decision 1 gains "a `let` binds one literal block or one chain". Decision 11 is *kept*, not bent. Add a row to decision 2's table for an `&r` head ("a write, wherever the pipeline is stepped or passed") |
| **Left out** | **keep** | Including "affine or unique cursors": the merge doesn't need them (alt-2 C contradicts foundations.md and doesn't fix drops) |
| **Later** | **change** | Move "fusion through a `gen fn` whose consumer is a pipeline" into the plan (recommendation 5). Keep `unordered: true` and broadcast as later |
| **Evidence** | **change** | Apply the prior-art corrections: Kotlin's split; virtual time in Go `synctest`, `runTest`, Effect `TestClock`; Effekt's real obstacles (a stored boxed continuation for zip, and "one way"), not rule A; Go's push rewrite allocates when it isn't inlined, so Ren's no-allocation guarantee comes from decision 1. These change claims, not the design |

---

## Top 5 recommendations, ranked

1. **Cleanup only at points the syntax fixes.** Delete the drop
   trigger. A `finally` runs when a loop over a temporary ends, when
   the statement holding a sink ends, when the scope of the binding
   ends, or on cancel. Each is an unwind, and `finally(r)` sees
   `Err(Cancelled)` when the stream is abandoned. The service's `with`
   closes anything left over.
   - *Why first:* it's the only point where the draft does what the
     ethos forbids outright: an effect, possibly a failing and
     suspending one, at a place the optimizer picks. It also
     contradicts signed decision 11.
   - *Source:* alt-2 R; probe-soundness §5; feasibility F1.

2. **Pipelines are blocks** (alt-1 B), and `next` doesn't join the
   requirements.
   - A chain is a literal block, `fn() -> Option<T>`.
   - `&r.map(f)` shows the write of `r`, and a temporary head needs no
     `&`.
   - The `&` error applies only to named places.
   - A `let` binds one block or one chain.
   - Generic sinks take a block parameter.
   - *Why:* it removes a second mechanism for "do this with any type",
     a kind on type variables, and a new debug layout. It's also the
     difference between about 1,100–2,100 and 2,400–4,400 lines of
     compiler. "The checks blocks already have" becomes true.

3. **Whether a generator is kept follows its signature, merged with
   2.**
   - A pure `gen fn` with value parameters gives a value cursor:
     storable, and a copy is an honest fork.
   - Any other `gen fn` call is a pipeline, whose frame is a hidden
     local of the caller. That covers one that uses a dependency or
     takes a block.
   - `yield` may sit inside `with`, but not inside any block or
     `finally`.
   - A stream over a resource that must be kept is a record (an id and
     an offset), with incarnations and the `with`-escape rule.
   - *Why:* one mechanism (the block rule) answers "can this be kept?"
     for pipelines and generators alike. The kind is visible in `uses`,
     which is already written. User-written lazy stages and
     rows-in-a-transaction fall out. Say plainly that "one kind of
     stream" now means one *protocol*, with two kinds of value: data
     you keep, and blocks you pass down.

4. **One shape for every stream with tasks behind it.**
   - `Async.produce`, `map_pull`, `merge`, `debounce`, `batch(within:)`,
     `throttle` and `sample` all take their consumer as a block:
     `op(src, …) fn(out) => for x in try out …`.
   - Channels stay dependencies, and `Jobs.items()` is their cursor.
   - `produce`'s sender is a channel dependency the call installs, not
     a held value.
   - `Async.each` and `Async.map` pull on the caller's task.
   - *Why:* the draft spells "this stream has tasks behind it" three
     ways, and two of them hide a scope whose cancel-and-wait lands at
     a drop. With one shape, the scope is always on the page.

5. **Make the obvious form the fast one, everywhere it can be.**
   - Push through one-input stages from the start, not "later", so
     `walk(t).select(p).take(10)` and an extracted `gen fn` helper
     stay one loop.
   - Fuse eager collection chains whose blocks use nothing and write
     nothing captured.
   - Ship `Net.frames(conn, fmt)`, so framing isn't a quadratic
     `buf ++ chunk`.
   - Show "pulled: zip" or "pulled: passed to `index_all`" on hover
     and in `ren review` where pull is forced.
   - *Why:* the paper programs found three cost cliffs on the most
     ordinary edits: extracting a helper (09), adding a `.select` to a
     tree walk (05), and writing a framer (02). Ethos rule 4 is the
     one the draft states as its own property 8.

### Decisions for the owner

- **Merge B and R as above?** The trade is that effectful generators
  can't be stored. You keep their state as a record. That's the line
  the bet already draws for instances.
- **The spelling of a named effectful generator:** `let g = follow(p)`
  with no `&` (recommended, since decision 1 holds), or `var g` and
  `&g` to match data cursors.
- **`max:`:** required everywhere, or 64 everywhere.
- **Abandonment:** `Err(Cancelled)` (rolls back for free) or a
  separate `Stopped`.
- **Eager fusion of pure collection chains:** adopt it now, or leave
  `.cursor()` as the documented fast path until a measurement says
  otherwise.

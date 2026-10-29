# Probe: the prior-art claims in streams.md

Read-only probe of `/Users/matthewdodd/Documents/code/ren/streams.md` (untracked draft, treated as **not decided**).
Sources: clones in `/tmp/ren-refs` (effect, effect-v3, effekt, koka, swift (Concurrency only), swift-evolution, go (runtime + cmd only), flix, lean4, eio) and official docs/RFCs fetched on 2026-10-29. Kotlin, Elixir, RxJS, Reactor and .NET are not cloned; cited from official docs and source on GitHub.

Verdicts: **holds**, **overclaimed**, **wrong**. Severity follows the task: *breaks* = unsound or unbuildable as written; *major* = real design or ergonomic problem; *minor* = the claim is off but the design doesn't depend on it.

---

## 1. Claim by claim

### "Where Ren stands" table

| Row | Verdict | Correction | Source |
|---|---|---|---|
| One kind of stream: "Kotlin, Elixir" have it | **wrong for Kotlin**, holds for Elixir | Kotlin has `Iterable` (eager), `Sequence` (`sequence { yield() }`, `@RestrictsSuspension`, so no suspending calls inside) and `Flow` (`flow { emit() }`), each with its own operator set. That's the sync/async split by another name. The best matches are **Go** (no colours; `iter.Seq` covers slices and sockets alike), **Java with Loom** (a blocking `Iterator`/`Stream` over a socket is fine on a virtual thread), **OCaml 5/Eio** and **Zig**. Java also shows a split *can* be removed after the fact, which goes against "the one most languages can't add after the fact". | kotlinx `SequenceBuilder` is `@RestrictsSuspension`; Go `iter` package docs; JEP 444 |
| Cleanup when `break` runs: C#, JS, Go, Elixir | **holds for those four, but Ren isn't in their group** (see finding F4) | C#'s `foreach` disposes the enumerator on `break`. JS `for-of` calls `return()` on `break`, which closes a generator **even one held in a variable**. Ren's `for x in &r` leaves `r` open and resumable, so cleanup waits for the drop. That's Rust's `for x in &mut it` model, and CPython's refcounted model for sync generators, which the table lists as "Not". | ECMA-262 IteratorClose; C# spec §13.9.5 |
| Lazy, fused, allocating nothing: "Rust, at the cost of `Pin`, closure types and build times" | **overclaimed** | `Pin` has nothing to do with `Iterator` adapters: it applies only to futures, streams and self-referential state. Swift's `lazy` sequences, C++20 ranges, Zig iterators and GHC's fusion also specialise to a loop. The draft's own claim ("Rust's speed without ... the nested adapter types that slow its builds") goes against foundations.md "What's given up": *"code that wraps blocks at each layer is bounded only by the budget, as a closure-heavy Rust program is"*. A pipeline is exactly code that wraps blocks at each layer. | foundations.md:1076-1084 |
| Bounded, ordered concurrent map with a per-item timeout: "Elixir's `Task.async_stream`" alone | **overclaimed** | Others have it too: Java 24 `Gatherers.mapConcurrent(n, f)` (JEP 485, ordered, bounded, on virtual threads; it's even in the draft's Evidence), Rust `StreamExt::buffered(n)` + `tokio::time::timeout`, Akka `mapAsync(parallelism)`, Reactor `flatMapSequential(f, concurrency)`, Effect `Stream.mapEffect(f, {concurrency: n})`, which is ordered and has `unordered: true`, the same as the draft's "Later" item. Elixir's per-item timeout is an *option* (default 5000 ms, `on_timeout: :kill_task`), not a composition. | hexdocs Task.async_stream; JEP 485; Effect `Stream.ts` |
| Time operators deterministic in tests: "nobody: Kotlin needs Turbine and virtual time" | **wrong** | (1) `kotlinx-coroutines-test`'s `runTest` skips `delay` and has `advanceTimeBy`, `runCurrent` and `advanceUntilIdle`, so `debounce` tests run deterministically. Turbine is an assertion helper, not virtual time. (2) RxJS `TestScheduler.run` marble tests ship in `rxjs/testing`. (3) Reactor's `StepVerifier.withVirtualTime`. (4) RxJava's `TestScheduler` passed to `debounce(t, unit, scheduler)`, which is exactly Ren's "takes a `Clock`", in core RxJava. (5) **Go 1.25 `testing/synctest`**: fake time in the runtime for every goroutine in a bubble, with no library at all (`runtime/synctest.go`: `now int64 // current fake time`). (6) Tokio `#[tokio::test(start_paused = true)]`. (7) .NET 8 `TimeProvider` + `FakeTimeProvider`. (8) **Effect does exactly Ren's design.** `Stream.debounce` does `const clock = yield* Clock` (effect `Stream.ts:8296`), and `testing/TestClock.ts` drives it. What's unique to Ren is **replay from a production journal**, plus the fact that time *can't* escape the virtual clock (Kotlin's docs warn that `Dispatchers.IO`/`Default` don't use virtual time). | kotlinlang.org kotlinx-coroutines-test docs; `/tmp/ren-refs/go/src/runtime/synctest.go:13-18`; `/tmp/ren-refs/effect/packages/effect/src/Stream.ts:8287-8296`, `testing/TestClock.ts` |

The tagline "streams you can replay from production" holds. "Nobody else tests time deterministically" doesn't.

### "Two of everything" table

| Row | Verdict |
|---|---|
| JavaScript: iterator helpers only on the sync side | holds (ES2025 sync helpers; async iterator helpers are still a proposal) |
| C#: two LINQs | holds (System.Linq.Async, now `System.Linq.AsyncEnumerable` in .NET 10) |
| Rust: `Iterator`/`Stream` | holds |
| Swift: "algorithms in a separate package" | partly: `map`, `filter`, `compactMap`, `flatMap`, `prefix`, `reduce` etc. are in the stdlib (SE-0298). Only merge, zip, debounce etc. are in swift-async-algorithms |
| Python | holds |
| *(missing)* Kotlin | `Sequence` vs `Flow`, `yield` vs `emit`: it belongs **in** this table, not in "who has one kind" |

### Cleanup section, "the bugs the survey found elsewhere can't happen"

- **Java `Files.lines`, Clojure lazy seq after `with-open`, Haskell lazy IO:** hold. Ren has no lazy I/O that outlives a lexical scope.
- **Python async generators "finalized later in another context" (PEP 525):** **overclaimed.** That bug comes from an effectful (`await`ing) finaliser running at a drop point that isn't a suspension context. Ren copies the cause: "A `finally` that runs at a drop can call dependencies". Ren's drop happens at last use (Perceus), possibly inside a function whose `uses` lacks the dependency, inside a `trust` arena, or at an **actor eviction** (foundations.md bet table: an actor lives "until it's evicted"). An evicted actor holding a socket cursor in its state runs that cursor's `finally` in another context: the PEP 525 bug. See F5.
- **Swift's "hidden await" worry:** cited correctly (`swift-evolution/proposals/0298-asyncsequence.md:323-332`). But Ren's answer, "the drop point is the end of a scope you can see", contradicts foundations.md:40, where a value lives "as long as it's used, counted by Perceus". Perceus drops after **last use**, not at scope end. That's Koka's garbage-free property, and Swift's ARC has the same non-lexical lifetimes (hence `withExtendedLifetime`). Rust keeps drops lexical *because* `Drop` has side effects.

### Concurrency section

- **"Kotlin's context preservation, checked statically":** holds as an analogy. Kotlin throws `IllegalStateException: Flow invariant is violated` at run time.
- **`yield` banned in scopes/`finally` as "PEP 789, prevented at compile time":** holds. More prior art: C# has had **CS1625** ("Cannot yield in the body of a finally clause") and CS1626 (no `yield return` in a `try` with `catch`) since C# 2.0, and Kotlin forbids `emit` from another coroutine context.
- **Rust's buffered futures stall, Oxide "futurelock":** holds. RFD 609 names `FuturesOrdered`/`FuturesUnordered` polled via `next()` while the task awaits something else, which is what `buffered` is built on, and recommends `JoinSet` (real tasks), which is Ren's choice.
- **"Async.each/Async.map ... This is Elixir's `Task.async_stream`":** mostly holds, with one difference. `async_stream` is lazy and its result is a stream; Ren's `Async.map` collects, and `Async.map_pull` is the lazy one.

### Time section: "No other language studied can test `debounce` without a library for virtual time"

**Wrong.** Go 1.25 `testing/synctest` is standard library *and* runtime: fake time with no library, and `time.Sleep` is the clock. Kotlin's and Rx's virtual schedulers are first-party. Effect, one of Ren's own references, already injects `Clock` into `debounce`. Suggested wording: *"Like Effect's `TestClock` and Go's `synctest`, time comes from `Clock`; unlike them, nothing can bypass it, and a failing run replays from its journal."*

### Standard library sizes

- **Effect `Stream` 235 exports, ~12,300 lines:** holds for the clone (v4 main, 12,289 lines, 235 exports). Effect v3, which most users run, has 309 exports (`effect-v3/.../Stream.ts`).
- **"Rx's 400 operators":** that's about RxJava's `Observable` method count with overloads. RxJS has ~100 operators. It's still a fair contrast.
- **"The size of Elixir's `Stream`":** holds (~35 functions vs. the draft's ~30).

### Evidence section

All cited clone paths exist (`koka/samples/handlers/yield.kk`, `flix/.../Iterator.flix`, `lean4/.../Stream.lean`, `eio/lib_eio/stream.mli`, `effekt/libraries/common/stream.effekt`, `effekt/examples/pos/stream_pull.effekt`, SE-0516). Two corrections:

- **Effekt and rule A (Producers section):** **overclaimed.** Effekt's library composes push stages by passing blocks to *named* functions (`limit(n){stream}` → `boundary { returning::limit{stream} }`, `stream.effekt:82-84`), which rule A allows. Rule A only bites for higher-order composition of stages (`def pipe{stage}{s} = stage{ s }`). Effekt's `map`/`takeWhile` handlers resume at most once in tail position, which Ren's handlers allow. The real obstacles are (a) zip/pull needs a **stored boxed continuation** (`stream.effekt:272`: `k = box { resume(()) }`), which Ren can't express, and (b) "one way". Those are good reasons on their own, so cite them and drop the rule A argument.
- **"RFC 3550 calls its copyable-looking `Range` iterator 'widely considered to be a mistake'":** **misread, and the lesson cuts the other way.** The RFC says Range *being an `Iterator`* is the mistake "because it makes implementing `Copy` for those types hazardous". Rust's lesson is that **iterators should not be copyable**. Ren cursors copy like any value (see F3).
- **SE-0516 (now `Iterable`, implemented in Swift 6.4):** it isn't really "lifetime-bounded iteration". It's iteration by **`Span` batches** for noncopyable/nonescapable elements, chosen partly for speed. See "What the best designs did" below.
- **"Pushed when it can be ... compiled the way Go 1.23 compiles range over a function":** **overclaimed.** Go turns the loop body into a synthesised closure passed as `yield`. Inlining happens only when the iterator function is inlinable, and the closure can heap-allocate. Ren's guarantee ("no state machine and nothing allocated") comes from decision 1 (blocks are second-class and specialised per call site), not from Go. Go also needs run-time panics for iterators that ignore `yield`'s `false` result; Ren's `yield`-as-syntax avoids that. Both points are worth stating.

---

## 2. Findings that affect the design

### F1. Time operators can't be built over a pipeline as written (breaks)

`debounce`, `batch(within:)`, `sample`, `throttle` with a trailing edge, and a per-stream `timeout` must **race the upstream `next` against a timer**. Every surveyed implementation does it with a second task pulling upstream into a channel:

- Kotlin `Delay.kt`: `debounceInternal` = `scopedFlow { val values = produce { collect { send(it) } } ... }`; `sample` uses `produce(capacity = CONFLATED)`; `timeout` uses `produceIn`.
- Effect `Stream.ts:8299-8350`: `debounce` does `Effect.forkIn(scope)` and `Effect.raceFirst(Effect.sleep(...), ...)`.

In Ren, an upstream that's a pipeline "can't be captured by a spawned block". The single-task alternative, `Async.race` on `src.next()` against `Clock.sleep`, cancels the losing `next`. Under async.md's cancellation, that unwinds the generator frame mid-step, so the stream is closed (F6). So `r.map(parse).debounce(d)` is unbuildable unless the upstream is a `gen fn` handed to `Async.produce`, which the draft doesn't say.

**Fix:** state that the `stream.time` operators take a `gen fn` cursor (storable) or open their own `Async.produce` scope in continuation form (`debounce(src, d) fn(events) => ...`). Or let a pipeline be *moved* into a scope's producer task when the scope is opened by the same call that consumes it (rule C already copies values into spawned blocks; a pipeline's blocks would need to be marked concurrent per rule B).

### F2. No user-defined lazy adapter (major)

A stage that takes a block is compiler-provided ("a cursor's methods that take a block return a pipeline"), and "a `gen fn` can't take a block". So a user can't write `dedup_by(f)`, `scan(init, f)`, `chunk_while(f)`, a protocol-specific `frames(r, parse_header)` or any `transform`, generically and lazily. Every praised design allows it:

- Kotlin: `fun <T,R> Flow<T>.myOp(f: ...) = flow { collect { emit(f(it)) } }`, plus `transform {}`.
- Elixir: `Stream.transform/3,4`, `Stream.chunk_while/4` with an `after` flush.
- Go: `func Map[T,U](s iter.Seq[T], f func(T) U) iter.Seq[U]`.
- Effekt: any function taking `{f}` and `{stream}` blocks.

That makes the default set the ceiling. And the set lacks `scan`, `dedup`, `chunk_by`, `chunk_while`, `concat` and `intersperse`, which Elixir's `Stream` has.

**Fix:** *"A `gen fn` that takes a block gives a pipeline"*. The result is block-holding, so it follows the pipeline rules (let, loop, pass down; never store or return), and the existing error still points to the block-free `gen fn` when storage is needed. It's one rule, and it reuses the "a value that holds a block is a block" rule the draft already adds.

### F3. Copyable cursors are the hazard RFC 3550 describes (major)

"A generator's cursor copies like any value", and "copying the cursor copies the id: two names for one connection". Take a `gen fn` that splits a socket's chunks into lines and is copied mid-chunk. Both copies hold the same remaining lines of the current chunk in their frames (so those lines are delivered twice), then share the socket (so later lines go to one copy or the other). A file cursor copy is independent (`pread`); a socket cursor copy is aliased. **Whether a copy forks or aliases depends on the resource, and nothing in the type says which.**

Prior art: Rust's RFC 3550 (iterators shouldn't be `Copy`); C#'s mutable-struct enumerators (`List<T>.Enumerator`) are a well-known source of bugs when copied; Swift's `IteratorProtocol` docs warn against advancing copies; JS generators are reference objects.

**Fix:** make copying a cursor an error outside `trust`, with an explicit `fork()` only where it's meaningful (array and file cursors). Perceus moves keep passing and returning cheap. Alternatively, keep copies but make a copy of a resource-backed or `gen fn` cursor a compile error. This doesn't need affine types in general, only "cursors don't implicitly copy", the way scopes and tasks don't.

### F4. "Cleanup the moment you `break`" isn't what a resumable cursor gives (major)

Property 2 and the table promise C#/JS-style close-on-`break`. But the first example in the doc makes `break` resumable (`r` stays where it stopped), so a named cursor's `finally` runs at its drop, not at the `break`. That's the Rust and CPython model. Only a temporary (`for x in &gen()`) closes at `break`. C# and JS chose the opposite trade (close on `break`), and JS makes resuming impossible by design.

**Fix:** say both rules plainly: "a loop over a temporary closes it at `break`; a loop over a named cursor leaves it open until its drop or an explicit `close`". Consider an explicit `r.close()` for named resource cursors (Go's `iter.Pull` returns `stop`; C# has `DisposeAsync`).

### F5. Effectful `finally` at a Perceus drop (major)

Swift rejected async cancel at loop exit as "too much to hide" (SE-0298:332). Swift still has no async `deinit`. Rust has no async drop. Python needed PEP 525 hooks and `aclosing`. The draft allows dependency calls at drop, and two things are left unresolved:

- **When:** Perceus drops after last use (foundations.md:40), not at "the end of the scope". The point moves with borrow inference and reuse, and can differ between the debug and release builds (decision 13). A `flush` or `release` running at an optimiser-chosen point breaks "nothing found behind your back", and possibly replay determinism across builds.
- **Where:** the dropping function must be able to suspend and must have the cursor's `uses` in its row. Otherwise the frame rule (decision 12: "only a function whose `uses` reaches a dependency can suspend") is violated. Actor eviction and arena teardown are drops in "another context".

**Fix:** give cursors with a `finally` **lexical drop** (scope end, as Rust's `Drop` does), and make the cursor's `uses` part of its type so whoever holds or drops it carries the row. Otherwise make the drop-time `finally` non-suspending and require an explicit `close` for effectful cleanup. Decide what eviction does with a cursor in actor state (probably: an actor's state can't hold a cursor with a `finally`).

### F6. Timeouts and cancellation around a single `next` are unspecified (major)

A heartbeat ("no frame in 30 s → ping") or a read deadline needs a timeout on one `next`. async.md makes every *dependency call* cancel-safe, but a `gen fn` cursor's `next` is a resumable frame. A timeout that fires mid-`next` unwinds that frame, so is the cursor then closed, poisoned, or still resumable? Rust learned this the hard way (tokio documents cancel safety per method, and `select!` on `stream.next()` is only safe for some streams). Kotlin's `Flow.timeout` ends the flow. C#'s `MoveNextAsync().WaitAsync(t)` leaves the enumerator in an undefined state. There's also an exclusivity question: does `Async.timeout(d) fn() => c.next()` capture `&c` in a block passed to a concurrent parameter, which rule B forbids?

**Fix:** decide that cancelling a `gen fn`'s `next` ends that cursor (its `finally` runs, and later `next`s give `None`/`Cancelled`), and offer `next(within: d)` on resource cursors whose service supports deadlines (sockets, channels), so a timeout never cuts a generator mid-step.

### F7. `next` as a requirement needs row-polymorphic requirements (major)

Today's built-in requirements are pure (`==`, `hash`, `add`, ...). `next` is the first one with `inout self`, a `uses` row and an error row. "One kind of stream" holds only if `take<C has next>` is **polymorphic over `next`'s `uses` and errors**. That's exactly what Kotlin lacked (`Sequence` operators can't suspend) and what Rust's effect-generics work is trying to add; Koka, Effekt and Flix do it with row polymorphism. The draft doesn't say this, and compiler.md's dictionary-passing debug builds would have to treat every adapter over an unknown cursor as possibly suspending (it needs a frame).

**Fix:** state that the requirement carries row variables (`take<C has next ! E uses U>`, or inferred and hidden), and that debug builds give such generic adapters frames. Measure the cost.

### F8. Ordered bounded `Async.map`: slots and head-of-line blocking (major)

"Pull the next item only when a slot frees" plus "keeps order" leaves a question open: does a finished result waiting behind a slow first item hold its slot? In Rust's `buffered(n)`, Java's `mapConcurrent(n)` and Akka's `mapAsync(n)`, **yes**: the window is n including finished-but-unemitted results, so memory stays bounded and one slow item stalls the rest. Elixir's `ordered: true` "may need to buffer", so memory isn't bounded by `max`. Pick one and say so. The window semantics match "bounded by default".

### Smaller points (minor)

- **Overflow policies:** Kotlin's `conflate`/`BufferOverflow.DROP_OLDEST`, Swift's `AsyncStream` `bufferingNewest(n)` and Go's `select { default: }` cover telemetry and UI streams where blocking the producer is wrong. `sample` needs a conflated channel internally (Kotlin's `Delay.kt`). The draft's channels only block. Also note that Swift's `AsyncStream` default is `.unbounded` (`AsyncStream.swift:301`), which supports the draft's "capacity is explicit" stance.
- **Kotlin's `buffer`/`flowOn`:** these insert concurrency *mid-pipeline* without restructuring code, and fuse adjacent channels. Ren needs `Async.produce` plus a rewrite of the upstream into a `gen fn` (F1). That's a deliberate trade, but the stated rationale ("concurrency is decided by tasks") should acknowledge the cost.
- **`yield from` cost:** naive delegation is O(depth) per item (Python's PEP 380 chain, JS `yield*`). C# never added `yield foreach`, and F#'s `seq { yield! }` needs compiler flattening. A tree walk of depth d resumes d frames per node unless the cursor jumps straight to the innermost delegate. State which one Ren does.
- **SE-0516 `Iterable`:** Swift moved to iterating by `Span`, not per element, for speed. Ren's byte cursors already yield leased chunks and parse with formats, so it's covered, but per-element `next` over records decoded from a chunk should compile to a slice loop, and that's worth a measurement.
- **Go `iter.Pull`:** Go keeps push as the primitive and gets pull from a runtime coroutine (`runtime/coro.go`) with an explicit `stop`. Ren's choice is the reverse (pull as the primitive, push as an optimisation). It's sound, but the doc should say what an abandoned pull-mode generator costs: its frame is held until the drop.
- **Elixir `Stream.resource`:** the start/next/after triple maps one-to-one onto a `gen fn` with `finally`. Holds.
- **C# cancellation:** `[EnumeratorCancellation]` and `WithCancellation` are the ugliness Ren's structured cancellation avoids. That's a real win worth one line.

---

## 3. What the best designs did that the draft misses

| Design | What it got right | Draft status |
|---|---|---|
| Kotlin `transform`, Elixir `Stream.transform`, Go `iter.Seq` adapters | users write their own lazy operators | missing (F2) |
| Kotlin `buffer` + `flowOn` fusion, `conflate` | concurrency mid-pipeline; overflow policy | partly (`Async.produce`); no overflow policy |
| Kotlin and Effect time operators | run on a forked upstream collector | not addressed (F1) |
| Rust: iterators not `Copy` (RFC 3550); tokio cancel-safety docs | cursor copies and cancelled `next` | missing (F3, F6) |
| Go `iter.Pull` returns `stop`; C# `DisposeAsync` | explicit close for a cursor kept past the loop | missing (F4) |
| Swift: no async deinit; Rust: lexical `Drop` | effectful cleanup only at visible points | contradicted (F5) |
| Effect `TestClock`, Go `synctest` | virtual time with no test-only operators | Ren matches it; the claim of uniqueness should go |
| Effekt push/pull duality | push for producers and filters, pull (boxed continuation) for zip | Ren's `gen fn` plus pull cursors cover it; drop the rule A argument |
| Java `mapConcurrent`, Rust `buffered` | ordered window semantics | unspecified (F8) |
| Swift `Iterable` (SE-0516) | batch iteration by `Span` | covered by leased chunks; worth measuring |

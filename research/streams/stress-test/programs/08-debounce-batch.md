# 08. Debounce and batch events from a channel, under `sim`, and replayed

The job: request handlers post `Event`s into a channel. One consumer
(a) batches them, at most 100 or 200 ms after the first of a batch,
whichever first, and writes each batch to a store; (b) separately,
"search as you type": a stream of queries is debounced, so only a query
followed by 300 ms of quiet is run. Test both on virtual time, and
replay a production run from its journal.

## Ren, per the draft

Using the draft's `stream.time` operators as the draft lists them:

```ren
dep Events = Chan<Event>

fn flusher() ! StoreDown uses Events, Store, Clock, Async =
  for batch in try &stream.time.batch(Events.items(), max: 100, within: Duration.ms(200))
    try Store.write_many(batch)

fn searcher() ! SearchDown uses Queries, Search, Results, Clock, Async =
  for q in try &stream.time.debounce(Queries.items(), Duration.ms(300))
    Results.show(try Search.run(q))
```

`Events.items()` is my guess: the draft says "a channel is a cursor:
`for m in &inbox`", but channels are dependencies (decision 6, `dep
Chan<T>`, `with sync.channel(16) as Events`), and the program never holds
an instance, so there's no `inbox` value to loop over. Something has to
make a cursor value whose `next` calls `Events.recv()`.

### How `batch` and `debounce` can be written

They're a `gen fn` with a timed receive. Each `Async.timeout` opens and
closes inside one `next`, so no `yield` sits inside it:

```ren
gen fn batch<T>(src: Recv<T>, max: Int, within: Duration) -> Array<T>
    uses Clock, Async =
  var src = src
  loop
    let Some(first) = &src.next() else return
    var b = [first]
    let deadline = Clock.now() + within
    while b.len() < max
      match attempt Async.timeout(deadline - Clock.now()) fn() => &src.next()
        Ok(Some(x)) => &b.push(x)
        Ok(None) => break                       // closed: flush and end below
        Err(Timeout) => break
    yield b

gen fn debounce<T>(src: Recv<T>, quiet: Duration) -> T uses Clock, Async =
  var src = src
  var pending: Option<T> = None
  loop
    match pending
      None =>
        let Some(x) = &src.next() else return
        pending = Some(x)
      Some(p) =>
        match attempt Async.timeout(quiet) fn() => &src.next()
          Ok(Some(x)) => pending = Some(x)
          Ok(None) => yield p; return
          Err(Timeout) => yield p; pending = None
```

About 30 lines for both. They are correct **only because `src` is a
channel receiver**: async.md promises that a cancelled call "never loses
a result", so a `recv` that the timeout cancels either got nothing or
lands its item.

### The test, on virtual time

```ren
test "a burst collapses to its last query" =
  with sync.channel(16) as Queries, recorded_results() in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Queries.send("r"); Clock.sleep(Duration.ms(100))
        Queries.send("re"); Clock.sleep(Duration.ms(100))
        Queries.send("ren"); Clock.sleep(Duration.ms(1000))
        Queries.send("rust")
        Queries.close()
      var seen = []
      for q in &stream.time.debounce(Queries.items(), Duration.ms(300))
        &seen.push((Clock.now() - Time.epoch, q))
      assert seen == [(Duration.ms(500), "ren"), (Duration.ms(1200), "rust")]

test "a batch closes at 100 or at 200 ms" =
  with sync.channel(256) as Events in
    Async.scope fn(s) =>
      s.spawn fn() =>
        for i in 0..250 => Events.send(Event(i))
        Clock.sleep(Duration.ms(50)); Events.send(Event(250))
        Events.close()
      let sizes = stream.time.batch(Events.items(), max: 100, within: Duration.ms(200))
        .map(fn(b) => b.len()).to_array()
      assert sizes == [100, 100, 51]

test "yesterday's incident" =
  with replay("tests/incident-2026-10-28.journal") in
    try flusher()
```

`ren test --seeds 1000` runs each under 1,000 schedules. Note `Time.epoch`
is `sim.clock()`'s start; `Clock.sleep` takes no real time.

## Counterparts

**Kotlin Flow + kotlinx-coroutines-test** (the strongest: `debounce` is
built in, and `runTest` gives virtual time with no extra library):

```kotlin
fun searcher(queries: ReceiveChannel<String>) =
    queries.receiveAsFlow().debounce(300.milliseconds).map { search(it) }

// batching isn't built in (there is no time-window chunk); the usual hand-written one:
fun <T> ReceiveChannel<T>.batches(max: Int, within: Duration): Flow<List<T>> = flow {
    while (true) {
        val first = receiveCatching().getOrNull() ?: break
        val b = mutableListOf(first)
        withTimeoutOrNull(within) {
            while (b.size < max) b += receiveCatching().getOrNull() ?: return@withTimeoutOrNull
        }
        emit(b)
    }
}

@Test fun burstCollapses() = runTest {
    val ch = Channel<String>(16)
    launch { ch.send("r"); delay(100); ch.send("re"); delay(100); ch.send("ren"); delay(1000); ch.send("rust"); ch.close() }
    val seen = ch.receiveAsFlow().debounce(300).map { currentTime to it }.toList()
    assertEquals(listOf(500L to "ren", 1200L to "rust"), seen)
}
```

About 20 lines for the same coverage minus replay. Two caveats: Kotlin's
`receive` has a *prompt cancellation* guarantee, so an element taken
just as `withTimeoutOrNull` fires can be lost unless the channel has
`onUndeliveredElement`; and its `debounce` is implemented with a
`produce` coroutine plus `select { onReceive; onTimeout }`
(kotlinx-coroutines `flow/operators/Delay.kt`), i.e. a task, which is
the thing the draft says only `merge` needs.

**C#, System.Reactive:** `events.Buffer(TimeSpan.FromMilliseconds(200), 100)`
and `queries.Throttle(TimeSpan.FromMilliseconds(300))` (Rx.NET's
`Throttle` is debounce), tested with `Microsoft.Reactive.Testing`'s
`TestScheduler.AdvanceBy`. Two lines of production code, the most
concise, but push-based, a second stream kind beside `IAsyncEnumerable`,
and every time operator must be given the scheduler to be testable.

**Go 1.25:** hand-written `select { case e := <-ch: ...; case <-timer.C: ... }`
loops, about 25 lines for both, tested with **`testing/synctest`**,
whose bubbles run on a fake clock (`runtime/synctest.go:18`, `now int64
// current fake time`, in the Go clone). Standard library, no extra
package.

## Comparison

- **Production code:** Ren with library operators is 6 lines, as short
  as Kotlin; only Rx is shorter. The hand-written operators are as long
  as Go's and Kotlin's.
- **Where Ren reads better:** the test needs no test dispatcher, no
  `currentTime`, no scheduler parameter: `Clock` is a dependency, so the
  operators are on virtual time just by being tested, and the schedule
  is explored over 1,000 seeds, which none of the others do. **The
  replay test is unique to Ren** and is the honest headline: "yesterday's
  incident, replayed, deterministically". Cancel-safety of `recv` makes
  the hand-written `batch` correct where Kotlin's twin can drop an item.
- **Where it reads worse:** nothing in the operators; the friction is
  the channel-as-cursor gap below.

## What the draft forbids or leaves unclear

1. **Time operators over an arbitrary cursor need a task, so they can't
   be cursor methods.** `batch` and `debounce` above must race "the next
   item" against a timer. Over a channel that's a cancel-safe `recv`.
   Over a `gen fn` cursor, `Async.timeout` around `next` cancels the
   generator mid-step: its `finally` runs and it's gone, so the next
   batch finds a dead source. (The draft doesn't define what cancelling
   a `next` does to a generator at all.) The only general
   implementation, Kotlin's too, puts the source on its own task. In Ren
   that's `Async.produce`, a scope; a `gen fn` can't yield inside a
   scope, and a pipeline can't keep a scope open after the call that
   built it returns. **So either `batch`/`debounce`/`throttle`/`sample`
   take only a channel receiver, or they're block-taking scopes,**
   `stream.time.debounce(src, d) fn(qs) => for q in try &qs ...`. The
   draft says only `merge` needs tasks; that's true only if the source
   is a channel. It should state the signature.
2. **Channels as cursors.** "A channel is a cursor: `for m in &inbox`"
   needs a value. With `dep Events = Chan<Event>` there's none.
   Proposal: the compiler-derived `Events.items()` (or `Chan<T>`'s
   `items()` member, as `Async`'s functions are members), giving a
   `Recv<T>`, a zero-field cursor whose `next` is `Events.recv()`. Same
   for `Async.produce`'s `out`: is it a value, a block-kind sender, or a
   dependency installed for the producer block? The draft writes
   `fn(out) => crawl(root, out)` as if it were a value, which a channel
   instance can't be.
3. **A generic stdlib operator over "some channel".** `batch<T>(src:
   Recv<T>)` works if `Recv<T>`'s `next` resolves `Chan<T>` from the
   caller. But with aliases (`dep Events = Chan<Event>`, `dep Audit =
   Chan<Event>`), two channels of one element type are two
   dependencies; a `Recv<Event>` must remember *which*, or `batch`
   reads the wrong one. So `items()` has to be per alias, and `Recv`'s
   type must name the dependency (`Recv<Events>`), which makes the
   cursor's type carry a dependency name: new.
4. **The "nobody tests debounce deterministically" claim is
   overstated.** Kotlin's `runTest` virtual time is in the official
   kotlinx-coroutines-test (Turbine is only for assertions); Go 1.25's
   `testing/synctest` is in the standard library; Rx.NET has
   `TestScheduler`. What only Ren has is (a) virtual time with no
   scheduler plumbing *and* schedule exploration over seeds, and (b)
   replay of a production run. The draft should claim those.

## Soundness doubts

- **Cancelling `next`.** Point 1: if a library or user wraps a
  generator's `next` in `Async.timeout`, `race` or `Async.map`'s
  per-item cancel, the generator is unwound. That's sound (its
  `finally` runs) but it silently ends the stream, and a later `next`
  must return `None` or panic; the draft should pick. C#'s answer: the
  enumerator is disposed and further `MoveNextAsync` is undefined;
  Kotlin's: the flow is cancelled. "Returns `None`" is the Ren-shaped
  answer.
- **Replay** is sound: the timer is a `Clock` operation in the
  consumer's task (the generator runs on it), the channel is Ren code
  over `Async.until`, so the journal holds every choice. Good.

# Streams: cursors, pipelines and producers

How a Ren program produces, transforms and consumes sequences that
arrive over time: lines of a file, rows of a query, chunks from a
socket, connections on a listener, pages from a crawl. It's the stream
library that stage 11c builds on generators, and it amends
[foundations.md](foundations.md) (rule D of decision 2, decision 12,
and "What's given up": generic lazy pipelines),
[stdlib.md](stdlib.md#streams-cursors-first) ("Streams: cursors
first"), and [language.md §3](language.md#3-generic-code-no-user-defined-interfaces)
(the closed set of built-in requirements).

**Status.** Decided on 2026-10-29, from two research passes: which
languages got stream ergonomics right, and how to get lazy, fused
pipelines without stored closures or traits. The documents it amends
keep their current text until they're updated to match. Items marked
**later** are noted so they aren't lost. Nothing here is implemented
beyond cursors and `for` over them (stage 10c).

## Contents

- [What it has to do](#what-it-has-to-do)
- [Where Ren stands](#where-ren-stands)
- [One kind of stream: the cursor](#one-kind-of-stream-the-cursor)
- [Pipelines: a value that holds a block is a block](#pipelines-a-value-that-holds-a-block-is-a-block)
- [Producers: `gen fn`](#producers-gen-fn)
- [Errors](#errors)
- [Cleanup](#cleanup)
- [Cursors over resources](#cursors-over-resources)
- [Concurrency](#concurrency)
- [Time](#time)
- [The standard library](#the-standard-library)
- [Compiler errors](#compiler-errors)
- [What it changes](#what-it-changes)
- [Left out](#left-out)
- [Later](#later)
- [Evidence](#evidence)

## What it has to do

The survey of streams across languages found five properties that
separate the designs people praise from the ones they patch:

1. **One kind of stream.** Not a synchronous iterator beside an
   asynchronous one, with two sets of combinators.
2. **Cleanup exactly when the consumer stops.** A `break` closes the
   file, then and there, not when a collector gets to it.
3. **Lazy, fused pipelines.** `map`, `select` and `take` over a stream
   without building a collection at each step, compiled to one loop.
4. **Bounded concurrency by default.** A concurrent map has a limit, keeps
   order unless asked not to, and composes with a timeout per item.
5. **A small core,** and no yielding from inside a concurrency scope.

And Ren's own:

6. **No stored closures and no user traits** (foundations.md decisions 1
   and 3, language.md §3). Nothing here takes those back.
7. **Deterministic and replayable.** A stream's effects go through
   dependencies, so a stream runs under `sim` and replays from a journal
   like everything else.
8. **The obvious way is the fast way.** The pipeline you'd write first
   is the one that allocates nothing.

## Where Ren stands

| Property | Who has it | Ren |
|---|---|---|
| One kind of stream | Kotlin, Elixir. *Not* JavaScript, C#, Rust, Swift, Python, which all split sync from async | yes: there are no function colors, so a socket's cursor and an array's are the same kind of thing |
| Cleanup when `break` runs | C#, JavaScript, Go, Elixir. *Not* Python, Java, Clojure, early Haskell, each of which needed patches | yes: Perceus drops are deterministic |
| Lazy, fused, allocating nothing | Rust, at the cost of `Pin`, closure types and build times | yes: pipelines are blocks, specialized like Rust's adapters |
| A bounded, ordered concurrent map with a timeout per item | Elixir's `Task.async_stream` | yes: `Async.map` and `Async.each` with `max:` |
| Time operators deterministic in tests | nobody: Kotlin needs Turbine and virtual time | yes: they take `Clock`, so they run under `sim` and replay |

**One stream type, lazy pipelines that allocate nothing, cleanup the
moment you `break`, bounded concurrency by default, and streams you can
replay from production.**

## One kind of stream: the cursor

A **cursor** is any value with a method `next(inout self) -> Option<T>`,
and `for x in &c` calls it until it gives `None` (stdlib.md, since
stage 10c). A `break` leaves the cursor where it stopped, and the next
loop goes on from there:

```ren
var r = Fs.line_reader(path)
for line in try &r
  if line == "---" then break        // `r` stays where it stopped
  try Index.add(parse(line))
for line in try &r                   // this loop goes on from there
  &body.push(line)
```

**There's no asynchronous iterator.** A function suspends only if its
`uses` reaches a dependency (foundations.md decision 12), so a cursor
whose `next` reads a socket is an ordinary cursor whose `next` uses
`Net`. An array's cursor, a file's lines, a query's rows, a socket's
chunks and a listener's connections are the same kind of thing, written,
consumed and transformed the same way. The only difference is the
`uses` row.

That's the property the survey ranked first, and it's the one most
languages can't add after the fact:

| Language | Two of everything |
|---|---|
| JavaScript | iterators and async iterators, `for of` and `for await`; iterator helpers only on the sync side |
| C# | `IEnumerable` and `IAsyncEnumerable`, two LINQs |
| Rust | `Iterator` and `Stream`, `StreamExt` beside the iterator adapters |
| Swift | `Sequence` and `AsyncSequence`, algorithms in a separate package |
| Python | generators and async generators, `for` and `async for` |

**Backpressure is implicit.** Nothing is pulled until the loop body
finishes with the item before, and leased buffers go back to the pool
when the body's turn ends ([runtime-io.md](runtime-io.md)). A queue
exists only where a program writes one: a channel with a capacity.

## Pipelines: a value that holds a block is a block

foundations.md gave up lazy pipelines: a lazy `map(f)` cursor has to
keep `f`, and blocks can't be kept. Rule D of decision 2 already has
the way out, for scopes and task handles: "a scope and a task handle are
blocks too. They can't be stored or returned." Streams extend it:

> **A value that holds a block is a block.** It can be bound with `let`,
> looped over, passed down, zipped and chained. It can't be stored or
> returned.

So pipelines are lazy and fused:

```ren
var r = Fs.line_reader(path)
let errors = r.map(parse).select(fn(e) => e.level == Error).take(100)
for e in try &errors
  try alert(e)

let total = orders.cursor().select(fn(o) => o.paid).map(Order.total).sum()

for a, b in &left.map(norm).zip(right.map(norm))
  ...
```

- **A cursor's methods that take a block return a pipeline:** a cursor
  that holds the block and the cursor it reads. Nothing runs until
  something pulls from it.
- **What a pipeline can do:** be bound with `let`, be a `for`'s source,
  be passed to a parameter, be the receiver of the next stage, and be
  zipped. **What it can't:** be stored in a record, an array or a map,
  be returned, or be captured by a spawned block. Its type says it
  holds a block, so the checks are the ones blocks already have.
- **A pipeline that must be stored, returned or given to a task is a
  `gen fn`.** That's the line, and the error that enforces it says so.
- **Release builds compile a pipeline into one loop.** Each stage is
  specialized for its block, and each `next` inlined, as Rust's
  iterator adapters are. That's Rust's speed without closure types,
  `Pin`, or the nested adapter types that slow its builds, since a
  block is never part of a type. Debug builds pass each stage its
  block as code and frame, through shared adapters.

### One vocabulary, two receivers

The methods are the ones `Array` already has, from Ruby's `Enumerable`
(language.md, README). **The receiver decides eager or lazy:**

| Receiver | `x.map(f)` gives | Runs |
|---|---|---|
| `Array`, `Map`, `Set` | an `Array` (a `Map`, a `Set`) | now, all of it |
| a cursor | a pipeline | as it's pulled |

`xs.cursor()` gives a cursor over a collection, so `xs.map(f)` and
`xs.cursor().map(f)` are the eager and lazy forms of one operation.
That's Elixir's `Enum` and `Stream`, the design the survey praised
most, with the receiver deciding instead of the module. It isn't a
second way to do one thing: the names are shared, and the type says
which.

### `next` joins the built-in requirements

Adapters are generic over any cursor, so they need `next` of their
element type. **`next` joins the closed set of built-in requirements**
in language.md §3, beside `==`, ordering, `hash`, the operators, `zero`,
`one` and `show`. `for` already depends on it structurally. It's
inferred like the others, shown on hover (`take<C has next>`), and users
still can't write requirements of their own. It's the one widening of
§3's set.

### Exclusivity, step by step

A stage's block runs at each `next`, and `next` takes turns with the
loop body in one task. So **a pipeline's blocks access what they
capture at each step, an instant, not across the whole loop.** The body
may change a place a stage reads between steps:

```ren
var limit = 10
for x in &xs.cursor().select(fn(x) => x < limit)
  if x == 3 then limit = 5          // fine: the stage reads `limit` at its next step
```

Without this, ordinary pipelines would fail the check. With it, the
check is still one walk from the syntax (decision 2).

### Pipelines and the pipe

A pipeline stage is a method of the cursor, so it's written with `.`:
it's the cursor's vocabulary (language.md §7). `|>` still joins
workflow steps from other modules, and a step can take a pipeline as
its first argument, since a pipeline can be passed down:

```ren
r.map(parse).select(valid)
  |> try search.index_all          // index_all(rows: C) where C has next
```

**No comprehension syntax.** A `for ... where ... yield` form would be
a second way to write the same pipeline.

## Producers: `gen fn`

A **generator** is a function marked `gen` that yields items. Calling
one gives a cursor:

```ren
gen fn lines(path: Str) -> Str uses Fs ! FsError =
  let f = try Fs.open(path)
  finally f.close()
  for chunk in try &f.chunks()
    for line in chunk.split_lines()
      yield line

gen fn walk(t: Tree) -> Node =
  yield t.node
  for c in t.children
    yield from walk(c)
```

- **`gen fn` is the one way to write a producer.** There's no `Emit`
  dependency, as Koka, Unison and Effekt write generators: that would
  be a second way, and Effekt's way of composing emitted streams passes
  a block that captures block parameters to a block parameter, which
  rule A forbids.
- **It compiles to a cursor,** a value whose fields are data (decision
  12), so it can be stored, returned, put in a record and given to a
  task.
- **`yield from` delegates, recursively.** The child cursor is kept as
  data, boxed like a recursive enum's field. Tree walks no longer need
  a task.
- **A `gen fn` can't take a block,** since the cursor would keep it
  (decision 12). It can build and loop over pipelines in its own body.
- **When to use which:** a pipeline for transforming a stream where
  it's consumed; a `gen fn` for a stream that's stored, returned or
  handed on, or a producer with real control flow.

### Pushed when it can be

A `gen fn` consumed directly by a `for` is compiled the way Go 1.23
compiles `range` over a function: **the loop body is inlined where the
producer yields**, `break` ends the producer, and its `finally` runs as
an ordinary unwind. There's no state machine and nothing allocated.
When the generator is bound to a `var`, zipped, stored or passed on, it
compiles to a cursor. The choice is the compiler's, made from where the
call's value goes, and no program can tell.

### Blocks inside a generator's frame

A generator's body can hold a pipeline across a `yield`, and the
pipeline's blocks point into the generator's frame, which is part of
the cursor. Copying the cursor mustn't leave those blocks pointing at
the old frame, which is Rust's `Pin` problem. So blocks written in a
generator's body address their frame relatively, and a generator's
cursor copies like any value. It's an implementation rule, not one
programs see.

## Errors

```ren
for row in try &Db.rows(q)
  try ingest(row)
```

- **`for x in try &c`** marks that each `next` can fail. It's the same
  rule as `try` on each step in a pipe (language.md §8): the place a
  stream can stop is on the page.
- **A failure ends the stream** and is passed on, after the cursor's
  cleanup, as C#, Swift and JavaScript do.
- **An error to recover from per item is a value:** a cursor of
  `Result`s, as Elixir's `{:ok, v}` and `{:exit, r}` items are. There
  are no `catch` or `retry` operators on streams; `retry(n, on:)` is a
  function over a block, as it is everywhere else.
- A block in a stage can fail, and its errors flow into the pipeline's
  `next`, as a block's errors flow into the call it's passed to.

## Cleanup

A `finally` in a `gen fn` runs:

- when a loop over it ends, by finishing, `break`, `return` or a failure;
- when the cursor is dropped, which Perceus makes deterministic: at the
  end of the scope that held the last reference, not when a collector
  gets there;
- when the task is cancelled, shielded and under the cleanup deadline
  (async.md).

**A `finally` that runs at a drop can call dependencies:** flush a
socket, close a file, release a lease. Swift's designers worried that
this hides an `await` at the end of a loop. In Ren the `finally` is in
the producer's source, and the drop point is the end of a scope you
can see, so it's explicit where it's written.

The bugs the survey found elsewhere can't happen: Python's async
generators finalized later in another context (PEP 525, `aclosing`),
Java's `Files.lines` leaking without try-with-resources, Clojure's lazy
seq read after `with-open` closed its file, Haskell's lazy IO.

## Cursors over resources

**`for x in c` without `&` is an error on a cursor.** It stepped a copy
and left `c` at the start, which is right for an array and wrong for a
socket: you can't rewind a connection. Rust's RFC 3550 calls its
copyable-looking `Range` iterator "widely considered to be a mistake".
Collections keep `for x in xs`, and a fix-it adds `&`.

**A resource's state belongs to its service, not to the cursor.** No
affine or unique types are needed (foundations.md rejected them):

- **A socket's cursor holds a connection id,** data like an `Id<T>`, and
  its `next` is a `Net` operation on that id. Copying the cursor copies
  the id: two names for one connection, which is honest, as two
  variables can hold one path. Unread bytes are the runtime's leased
  buffers, not the cursor's, so two copies never see diverging
  buffers.
- **A file's reader keeps its offset as data** and reads with `pread`,
  so a copy really is an independent reader from that point.
- **A query's rows** are a cursor id on the database's service, like a
  socket's.

The rule for anyone writing a cursor over a resource: keep the
resource's state in the dependency, and only ids and offsets in the
cursor.

## Concurrency

### Generators stay on the consumer's task

- **`next` runs on the consumer's task, with the consumer's
  dependencies.** A cursor's `uses` is its `next`'s. That's Kotlin's
  "context preservation", checked statically instead of at run time.
- **`yield` can't appear inside `Async.scope`, `Async.beside`,
  `Async.timeout`, `Async.race`, `retry`, a `with`, or a `finally`.**
  It's a compile error. A generator suspended at a `yield` inside one
  would leave its scope open in the consumer's frame, and cancel the
  wrong task: Python's PEP 789, prevented at compile time.

### A producer that needs tasks runs in the consumer's scope

```ren
Async.produce(cap: 16, fn(out) => crawl(root, out)) fn(pages) =>
  for p in try &pages
    try index(p)
```

- The producer runs as a task in a scope the consumer opens, sending
  into `out`. `pages` is a cursor over what it sends.
- When the body ends, by finishing, `break` or a failure, the producer
  is cancelled and waited for. A failure in the producer ends the
  stream with it.
- **`cap` is the backpressure:** the producer waits while `cap` items
  are unread. It's a real task, so it makes progress while the body
  runs, and can't stall the way Rust's buffered futures do when
  nothing polls them (Oxide's "futurelock").
- **It replaces `Async.pull`** (stdlib.md), which recursive producers
  needed; `yield from` now covers those without a task.

### Many items at once

```ren
try Async.each(listener.connections(), max: 10_000) fn(conn) =>
  try Async.timeout(Duration.seconds(30)) fn() => serve(conn)

let pages = try Async.map(urls.cursor(), max: 16) fn(u) => fetch(u)
```

- **`Async.each` and `Async.map` take any cursor,** pull the next item
  only when a slot frees, and are **bounded by `max:`.** `Async.map`
  keeps order. This is Elixir's `Task.async_stream`, and async.md's
  "streams for `each`".
- **A timeout per item is composed,** `Async.timeout` inside the block,
  not an option on the stream.
- **A stage whose output is a stream,** `Async.map_pull(src, max: 16)
  fn(x) => ...`, gives a cursor of results in order. It's a sharp tool,
  in `stream`.

### Channels are cursors

A channel's `recv` gives `None` once it's closed and empty
(async.md), so a channel is a cursor: `for m in &inbox`. A channel with
a capacity is the one place a program writes a queue.

## Time

`stream.time` holds the operators that depend on time: `batch(max:,
within:)`, `debounce`, `throttle`, `sample`, and `merge`, which needs
tasks. **Every one takes its time from `Clock`,** so under `sim` it runs
on the simulated clock, deterministically, and a run that went wrong
replays from its journal. No other language studied can test
`debounce` without a library for virtual time.

## The standard library

**The default set,** on every cursor:

- transforming: `map`, `select`, `reject`, `take_while`, `skip_while`,
  `flat_map`, `with_index`
- shaping: `take`, `skip`, `chunks(n)`, `windows(n)`, `zip`
- consuming: `sum`, `reduce`, `count`, `any`, `all`, `find`, `first`,
  `min`, `max`, `to_array()`
- concurrent: `Async.each` and `Async.map` with `max:`
- producing: `gen fn`, `xs.cursor()`, channels

**Sharp tools,** in `stream` and `stream.time`: `Async.produce`,
`Async.map_pull`, `merge`, `batch`, `debounce`, `throttle`, `sample`.

**Left out on purpose:**

- hot, shared and state flows (Kotlin's `SharedFlow` and `StateFlow`):
  state that many read is a handler, with `Async.until`;
- subscribe and dispose objects;
- operators that choose schedulers (`subscribeOn`, `publishOn`,
  `flowOn`): concurrency is decided by tasks;
- `catch`, `retry` and `onErrorResume` operators;
- implicit chunking: bytes already come in leased chunks, and records
  use `chunks(n)`;
- any operator whose meaning depends on whether a stream is hot or
  cold.

The module stays the size of Elixir's `Stream`, not Effect's, whose
`Stream` alone has 235 exports, or Rx's 400 operators.

## Compiler errors

Each points at the line and has a fix-it:

```
error: `errors` holds a block, so it can't be stored
  self.pending = r.map(parse).select(valid)
                 ^^^^^^^^^^^^^^^^^^^^^^^^^^
  = a pipeline holds the blocks its stages were given, and blocks are never kept
  help: write it as a `gen fn`, which can be stored:
          gen fn valid_records(r: Lines) -> Record =
            for line in try &r
              let rec = parse(line)
              if valid(rec) then yield rec
```

The same error, with "returned", for a pipeline returned from a
function, and with "captured by a task" for one a spawned block uses.

```
error: `for` over a cursor steps it in place
  for line in r
              ^
  = without `&`, the loop would step a copy and leave `r` where it was
  help: `for line in &r`
```

```
error: `yield` inside `Async.timeout`
  Async.timeout(d) fn() =>
    yield next_page()
    ^^^^^
  = the generator would stop here with the timeout's scope open in its consumer
  help: give the consumer the scope: `Async.produce(cap: 1, fn(out) => ...)`,
        or time each item where it's consumed
```

```
error: a `gen fn` can't take a block
  gen fn mapped(r: Lines, f: fn(Str) -> Rec) -> Rec =
                          ^^^^^^^^^^^^^^^^^^
  = its cursor would keep `f`
  help: call a named function inside it, or use a pipeline where it's consumed:
        `r.map(f)`
```

```
error: `next` can fail, and nothing handles it
  for row in &Db.rows(q)
             ^^^^^^^^^^^ it can fail with `DbDown`
  help: `for row in try &Db.rows(q)`
```

```
error: `Async.map` over a cursor needs a limit
  Async.map(urls.cursor()) fn(u) => fetch(u)
  = a cursor may not end, so every item could be in flight at once
  help: `Async.map(urls.cursor(), max: 16)`
```

## What it changes

| Today | Becomes |
|---|---|
| No lazy generic pipelines; `xs.map(f).select(p)` is eager (foundations.md, "What's given up") | Pipelines on cursors are lazy and fused; on collections, eager. A pipeline is a block |
| Rule D: scopes and task handles are blocks | And any value that holds a block |
| The built-in requirements: `==`, ordering, `hash`, operators, `zero`, `one`, `show` | And `next` |
| `Async.pull(seq)` runs a recursive producer on a task | `yield from` for recursion; `Async.produce(cap:)` for producers that need tasks |
| `for x in c` steps a copy of a cursor | An error on a cursor; collections keep it |
| A producer that owns the loop, `Fs.each_line(path) fn(line) => ...`, has no `for` sugar | `gen fn`, pushed into a `for` when consumed directly |
| `Async.each(listener.connections(), max:)` is "later" (async.md) | `Async.each` and `Async.map` take any cursor, with `max:` |

## Left out

- **Stored closures,** in any form. Pipelines are blocks.
- **User-defined requirements.** `next` is built in.
- **An `Emit` dependency** as a second way to write producers.
- **Comprehension syntax.**
- **A separate asynchronous iterator.**
- **Affine or unique cursors.** Resource state belongs to services.
- **Hot streams, schedulers, and error operators** ([The standard
  library](#the-standard-library)).

## Later

- **`Async.map(unordered: true)`,** results as they finish, if a program
  needs it.
- **Splitting a stream to several consumers** (Effect's and Rx's
  `broadcast`): a channel per consumer today.
- **Fusion through a `gen fn`** whose consumer is a pipeline: pushing the
  pipeline's stages into the generator's yield points.

## Evidence

Two research passes on 2026-10-29, using the clones in `/tmp/ren-refs`
and published sources. Repository paths were read in the session; the
rest are from official docs and proposals.

**Ergonomics across languages**

- Kotlin Flow: cold flows, `emit` and `collect`, `take` aborting so the
  producer's `finally` runs, `buffer`, `conflate`, `flowOn`,
  `flatMapMerge(concurrency =)`; complaints about its many kinds of
  flow and the context-preservation error.
- C# `IAsyncEnumerable` and `await foreach`, `DisposeAsync` on `break`,
  `[EnumeratorCancellation]`, System.Linq.Async, `System.Threading.Channels`,
  `Parallel.ForEachAsync`.
- JavaScript async generators and `for await`, `return()` on `break`,
  ES2025 iterator helpers (sync only).
- Python PEP 525 and 533, `contextlib.aclosing`, and PEP 789:
  https://peps.python.org/pep-0789/.
- Rust `Stream` and `StreamExt`, `Pin`, async closures in 1.85,
  cancellation by drop, the async vision story on buffered streams,
  and Oxide's futurelock: https://rfd.shared.oxide.computer/rfd/609.
  RFC 3550 on `Range`:
  https://github.com/rust-lang/rfcs/blob/master/text/3550-new-range.md.
- Swift `AsyncSequence` (SE-0298), typed failures (SE-0421), the
  removed `cancel()`: `/tmp/ren-refs/swift-evolution/proposals/0298-asyncsequence.md:194-332`;
  `AsyncStream`'s unbounded default:
  `/tmp/ren-refs/swift/stdlib/public/Concurrency/AsyncStream.swift:68`;
  lifetime-bounded iteration:
  `/tmp/ren-refs/swift-evolution/proposals/0516-borrowing-sequence.md`.
- Go 1.23 `iter.Seq`, the `range` body rewritten into `yield`, and
  `iter.Pull`.
- Elixir `Enum` and `Stream`, `Stream.resource`, `Task.async_stream`,
  GenStage, Flow and Broadway.
- Effect `Stream`:
  `/tmp/ren-refs/effect/packages/effect/src/Stream.ts`, about 12,300
  lines and 235 exports.
- Java Streams, `Files.lines`, JEP 485 Gatherers' `mapConcurrent`;
  Reactor and RxJava.
- Haskell conduit, pipes and streamly; Clojure lazy seqs, transducers
  and core.async's `pipeline`; OCaml `Seq` and
  `/tmp/ren-refs/eio/lib_eio/stream.mli`; Zig's `next() ?T` iterators.

**Pipelines without stored closures**

- Effekt, second-class blocks: push streams as an `emit` effect with
  adapters taking blocks, pull with a `next` effect, and push to pull
  storing a boxed continuation:
  `/tmp/ren-refs/effekt/libraries/common/stream.effekt` (lines 30, 82,
  117, 199-211, 274), `examples/pos/stream_pull.effekt`.
- Koka generators as an effect:
  `/tmp/ren-refs/koka/samples/handlers/yield.kk`, `basic.kk:111`;
  Unison's `Stream` ability.
- Flix iterators as closures bounded by a region:
  `/tmp/ren-refs/flix/main/src/library/Iterator.flix`. Lean's `Stream`
  and `for` over it: `/tmp/ren-refs/lean4/src/Init/Data/Stream.lean`.
- Coutts, Leshchinskiy and Stewart, stream fusion; Kiselyov et al.,
  "Stream Fusion, to Completeness" (POPL 2017).
- Reynolds' defunctionalization, Roc and Morphic's lambda sets:
  `/tmp/ren-refs/papers/roc.txt`, prior-art.md §5.

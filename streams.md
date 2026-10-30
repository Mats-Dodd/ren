# Streams: cursors, pipelines and producers

How a Ren program produces, transforms and consumes sequences that
arrive over time: lines of a file, rows of a query, frames from a
socket, connections on a listener, pages from a crawl. It's the stream
library that stage 11c builds on generators. It amends
[foundations.md](foundations.md) decisions 1, 2, 3, 12 and 13 and "What's
given up", [async.md](async.md), [errors.md](errors.md),
[runtime-io.md](runtime-io.md), [stdlib.md](stdlib.md#streams-cursors-first)
("Streams: cursors first") and [language.md §8](language.md#8-the-pipe-and-try-on-each-step).

**Status.** Decided on 2026-10-29, from two research passes (which
languages got stream ergonomics right, and how to get lazy, fused
pipelines without stored closures or traits), then a stress test: ten
programs, four probes, two alternative designs, three judges, and a
second round of experiments (thirteen programs against Kotlin, C#, Go
and Rust, a prototype in the interpreter, push and pull measured on C
models, and an audit of how the rules compose). The documents it amends
keep their current text until they're updated to match. Nothing here is
implemented beyond cursors and `for` over them (stage 10c). What it
still rests on is marked **open**; items marked **later** are noted so
they aren't lost.

**A stream is a call that answers many times.** It isn't a third kind
of thing beside calls and families: each relationship around it has a
shape, and the shape decides its owner
([concurrency.md](concurrency.md#streams-calls-that-answer-many-times)).
One-to-one is a loop on the consumer's task; many-to-one is a
combinator the call owns (`zip`, `chain`, `merge`); one-to-many needs
names, so it's a channel or a family.

## Contents

- [What it has to do](#what-it-has-to-do)
- [Where Ren stands](#where-ren-stands)
- [Seven rules](#seven-rules)
- [Data: cursors you keep](#data-cursors-you-keep)
- [Code: pipelines](#code-pipelines)
- [Producers: `gen fn`](#producers-gen-fn)
- [Stopping](#stopping)
- [Errors](#errors)
- [Concurrency and time](#concurrency-and-time)
- [The standard library](#the-standard-library)
- [Cost](#cost)
- [Compiler errors](#compiler-errors)
- [Programs](#programs)
- [What it changes](#what-it-changes)
- [Left out](#left-out)
- [Open](#open)
- [Later](#later)
- [Evidence](#evidence)

## What it has to do

The survey of streams across languages found five properties that
separate the designs people praise from the ones they patch:

1. **One kind of stream.** Not a synchronous iterator beside an
   asynchronous one, with two sets of combinators.
2. **Cleanup at a point the syntax fixes.** A loop over a temporary
   closes it at `break`. A named stream closes at the end of its
   binding's scope, so it can resume after a `break`. Never when a
   collector, or a reference count, gets to it.
3. **Lazy, fused pipelines.** `map`, `select` and `take` over a stream
   without building a collection at each step, compiled to one loop.
4. **Bounded concurrency by default.** A concurrent map has a limit, keeps
   order unless asked not to, and composes with a timeout per item.
5. **A small core,** which users extend with stages of their own.

And Ren's own:

6. **No stored closures and no user traits** (foundations.md decisions 1
   and 3, language.md §3). Nothing here takes those back.
7. **Deterministic and replayable.** A stream's effects go through
   dependencies, so a stream runs under `sim` and replays from a journal
   like everything else.
8. **The obvious way is the fast way.** The pipeline you'd write first
   allocates nothing and runs at the speed of the loop you'd write by
   hand.

## Where Ren stands

| Property | Who has it | Ren |
|---|---|---|
| One kind of stream | Elixir; Go (`iter.Seq` covers slices and sockets alike); Java on virtual threads. *Not* Kotlin (`Sequence` and `Flow`), JavaScript, C#, Rust, Swift, Python | yes: there are no function colours, so a socket's cursor and an array's are the same kind of thing |
| Cleanup when `break` runs | C#, JavaScript, Go, Elixir. *Not* Python, Java, Clojure, early Haskell, each of which needed patches | yes for a loop over a temporary; a named stream resumes after `break` and closes at the end of its scope (Rust's `by_ref`, with the close point fixed by syntax) |
| Lazy, fused, allocating nothing | Rust, Swift `lazy`, C++20 ranges, at the cost of closure types in every adapter's type and the build times that follow | yes: a pipeline is a block, composed where it's written |
| Users write their own lazy stages | Kotlin, C#, Go, Elixir, Rust | yes: a `gen fn` that takes a block |
| A bounded, ordered concurrent map | Elixir's `Task.async_stream`, Java's `Gatherers.mapConcurrent`, Effect's `mapEffect({concurrency})`, Rust's `buffered(n)` (which stalls when not polled) | yes: `Async.map` and `Async.each`, `max:` 64 by default |
| Time operators deterministic in tests | Effect's `TestClock`, Go's `testing/synctest`, Kotlin's `runTest` | the same, and nothing can bypass `Clock`, schedules are explored over seeds, and a failing production run replays from its journal |

## Seven rules

The design follows from seven rules. Each reuses a decision Ren already
made, and the rest of this document is what they give.

| # | Rule | Reuses |
|---|---|---|
| 1 | **A stream is data or code.** Data is a value with `next`, a value cursor or a library reader, and you can keep it. Code is a block, `fn() -> Option<T>`, a pipeline or an effectful generator, and you pass it down. | the bet; decisions 1, 17 |
| 2 | **A `gen fn` call is data when its parameters are data and its frame holds no instance across a `yield`:** no dependency in its inferred `uses` row, no `with` open, no `inout`. Errors don't count. Otherwise the call is a block whose frame is a hidden local of the caller. | decisions 12, 1, 5, 10 |
| 3 | **A pull parameter takes what `for` takes, written the same way.** A temporary goes as itself, a named data cursor as `&r`, a collection by snapshot, a block as itself. A chain's head follows the same rule. `&` marks a data place, and a block never takes `&`. | decisions 2, 16 |
| 4 | **A block-typed local has one definition, made here.** `let` binds a literal block, a chain, or a call that gives a block. It can't be chosen with `if`, stored or returned. | decision 1 |
| 5 | **A generator's frame is a scope, like a `with`.** Its `finally` runs when its binding's scope ends, by any exit; a temporary's scope is its statement. Being stopped from outside is `Err(Cancelled)`. Never at a count dropping to zero. | `with`; errors.md; async.md; decision 11 |
| 6 | **A resource is a family's.** A reader is data, an id and an offset; the open resource lives in its service, in a family keyed by that id. A copy reads from where it was copied, or fails, typed. | the bet; decisions 7, 17, 18; strings.md positions |
| 7 | **Waiting is an operation.** Anything that races a timer or a task takes a source whose step is one operation. A pipeline isn't one, so it can't be raced. | async.md's cancel safety; decisions 5, 6, 7 |

## Data: cursors you keep

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
`uses` reaches a dependency (decision 12), so a cursor whose `next` reads
a socket is an ordinary cursor whose `next` uses `Net`. An array's
cursor, a file's lines, a query's rows and a listener's connections are
the same kind of thing. The only difference is the `uses` row.

Most languages have two of everything instead: JavaScript's iterators
and async iterators, C#'s two LINQs, Rust's `Iterator` and `Stream`,
Kotlin's `Sequence` and `Flow`, Swift's `Sequence` and `AsyncSequence`,
Python's `for` and `async for`.

**`for x in c` without `&` is an error on a named cursor.** It would
step a copy and leave `c` where it was. Collections keep `for x in xs`,
and temporaries need no `&`: `for row in try Db.rows(q)`,
`for n in walk(t)`.

**Resources are families: state in the service, ids and offsets in the
reader** (rule 6). A service's open resources, its open files, database
cursors and socket buffers, are a family keyed by id
([concurrency.md](concurrency.md#streams-calls-that-answer-many-times)).
No affine or unique types are needed (foundations.md rejected them), and
there's no separate handle table and no close rule:

- **A file's reader** holds a path and an offset, and reads with `pread`.
  The open file is an entry in `Fs`'s family, and the family's `max:` is
  the cap on open files.
- **A socket's reader** holds a connection id; unread bytes are the
  runtime's leased buffers, kept by the connection's entry, not the
  reader.
- **A query's rows** are a cursor id on the database's service, an
  entry in its family.
- **An entry has an incarnation, as an actor does.** A reader whose
  resource was evicted, or whose family's `with` ended, fails with a
  typed `Closed`, and the leftovers are closed by the family's end.
- **A copy reads from where it was copied, or fails, typed.** The service
  checks the offset, so two names for one connection can't silently
  interleave. Rust's RFC 3550 calls `Range` being an `Iterator` a
  mistake because copyable iterators are a trap; in Ren only data
  cursors copy, and a copy is an honest fork or a typed failure.
- **A `with`'s value can't be a reader of the dependency it installs**
  (decision 7, given to values): a `Sql.Rows` can't leave the
  transaction that made it.

**Positions** are strings.md's: a reader that knows where its bytes sit
in the stream reports stream offsets. `Net.frames(conn, Msg.wire)`
carries its base, so a malformed frame's `at` is its byte in the
connection.

**Backpressure is implicit.** Nothing is pulled until the loop body
finishes with the item before, and leased buffers go back to the pool
when the body's turn ends ([runtime-io.md](runtime-io.md)). A slice of a
leased chunk kept past its turn is an ordinary root (decision 17). Under
pool pressure the runtime may move a held chunk to the heap, which
positions relative to the value make invisible; debug builds report it,
and the pool's metrics count it. A queue exists only where a program
writes one: a channel with a capacity.

## Code: pipelines

foundations.md gave up lazy pipelines: a lazy `map(f)` cursor would have
to keep `f`, and blocks can't be kept. They come back without keeping
anything:

> **A pipeline is a block.** A chain over a cursor,
> `src.stage(..).stage(..)`, is a block `fn() -> Option<T>` that the
> compiler writes where the chain is. A stage's state, `take`'s counter
> or `zip`'s pending item, is a hidden local of that frame, which the
> block captures.

```ren
var r = Fs.line_reader(path)
let errors = &r.map(parse).select(fn(e) => e.level == Error).take(100)
for e in try errors            // a call per step; `r` is stepped for the loop
  try alert(e)
  if e.fatal then break
for line in try &r             // goes on after the last line `errors` pulled
  Console.print(line)

let total = orders.cursor().select(fn(o) => o.paid).map(Order.total).sum()
```

- **What a pipeline can do:** be bound with `let`, be looped over, be
  stepped by hand (`try errors()`), and be passed to a block parameter.
  **What it can't:** be stored, returned, or chosen between with `if`.
  These are the checks blocks already have; the prototype needed no new
  one.
- **The head.** `&r.map(f)` steps the named cursor `r`, held the way
  `for x in &r` holds it, wherever the pipeline is looped over or passed.
  A temporary head needs no `&`. `r.map(f)` on a named cursor is the
  missing-`&` error (rule 3).
- **A named pipeline is spelled like a block:** `let`, no `&`, called to
  step it. `let errors = ...` then `for e in try errors` reads the way a
  pipeline parameter does. `errors.take(20)` inside a loop takes the
  *next* 20, and the hover says "steps `errors`".
- **Lookahead.** After a `break`, `r` has also lost what the pipeline
  looked ahead at (`take_while`, `windows`, `zip`), as Rust documents for
  `by_ref().take_while`. `ren review` warns when the head is a stored
  reader or one stepped through `&`.
- **Exclusivity, step by step.** A `let`-bound block accesses its
  captures at each call, which is each step, so the body may change a
  place a stage reads between steps. A pipeline passed to a call holds
  its captures for the call (decision 2), so
  `consume(xs.cursor().select(fn(x) => x < limit), &limit)` is an error,
  as it is for any block.

### One vocabulary, two receivers

The methods are the ones `Array` already has, from Ruby's `Enumerable`.
**The receiver decides eager or lazy:** on an `Array`, `Map` or `Set`, `map`
runs now and gives a collection; on a cursor it gives a pipeline that
runs as it's pulled.
`xs.map(f)` and `xs.cursor().map(f)` are the eager and lazy forms of one
operation, as Elixir's `Enum` and `Stream` are. An eager chain whose
blocks use no dependency and write no captured place compiles through
the same composed block, ending in its sink, so
`orders.select(p).map(f).sum()` allocates no arrays. No program can tell.

Stage names are reserved on types with a `next`, chosen by type: a
cursor type can't declare a member named `map` or `count`. That's the
price of method syntax on the cursor protocol, which the language owns
because `for` needs it; the names are in foundations.md decision 20's
closed list.

### Pipelines and the pipe

Built-in stages are the cursor's methods, written with `.`. A user's
stage is a function, and joins with `|>`, as any step from elsewhere does
(language.md §8):

```ren
lex(src)
  |> semis
  |> try parser.statements
```

A line that begins with `.`, indented further, continues the line above,
as `|>` does, so a chain can put one stage on a line.

**No comprehension syntax.** A `for ... where ... yield` form would be a
second way to write the same pipeline.

## Producers: `gen fn`

A **generator** is a function marked `gen` that yields items:

```ren
gen fn walk(t: Tree) -> Node =
  yield t.node
  for c in t.children
    yield from walk(c)

gen fn rows(q: Query) -> Row uses Db ! DbDown =
  let cur = try Db.open_cursor(q)
  finally(r) =>
    Db.close(cur)
    try r
  while true
    let page = try Db.fetch(cur, 500)
    if page.is_empty() then return
    for row in page
      yield row
```

**What a call gives follows rule 2.** `walk` is pure and takes only
values, so `walk(t)` is a **value cursor**: data, storable, returnable,
and a copy is an honest fork. Its type is `walk.Cursor`. `rows` uses
`Db`, so `rows(q)` is a **block**: its frame is a hidden local of the
caller, it can't be stored or returned, and its dependencies are found
where the frame is made (decision 5).

- **Purity is read from the inferred row,** not the written one. A
  `gen fn` that declares no `uses` but calls `print` is a block.
- **A frame that composes a pipeline over its own data is still data.**
  Wrapping a pipeline in a pure `gen fn` makes it a value again.
- **To keep a live stream past a function, keep its position:** a reader
  (`Db.rows`), which is data. That's the line the bet draws for
  instances, and the error says so.

### Users write stages

A `gen fn` may take a block, and that's how a stage is written:

```ren
gen fn dedup_by<T, K>(src: fn() -> Option<T>, key: fn(T) -> K) -> T =
  var last: Option<K> = None
  for x in try src
    let k = key(x)
    if Some(k) != last then
      last = Some(k)
      yield x
```

A value cursor goes to a block parameter as itself (rule 3), so
`dedup_by(walk(t), Node.name)`, `dedup_by(&r, f)` and
`dedup_by(Db.rows(q), f)` all work. `merge_by`, `scan` and `dedup_by`
ship in the default set, written this way.

### `yield`

- **`yield` appears only in the generator's own body,** never inside a
  `fn` literal and never in a `finally`. That prevents Python's PEP 789
  and C#'s CS1625 at compile time: a generator can't stop with a
  timeout's scope open in its consumer.
- **`yield` may sit inside a `with`.** A generator holding a `with` open
  is a block, so it can't outlive it. A transaction across `yield`s
  commits when the generator finishes and rolls back when it's abandoned
  ([Rows in a transaction](#rows-in-a-transaction)).
- **`yield from try child(..)`** when the child can fail.
- **Each `&` held across a `yield` re-checks uniqueness on resume,** one
  compare per held place per step, so a hoisted check can't break value
  semantics.

### Pushed when it can be

A chain whose head is a `gen fn` call and whose consumer is a `for` or a
built-in sink is **pushed**: the generator's body runs with the
one-input stages and the loop body folded in where it yields, `break`
and `return` leave it through a control value, and its `finally` runs as
an ordinary unwind. There's no state machine and nothing allocated. A
two-input stage, or a pipeline passed to a user function, **pulls**, and
the hover says "pulled: zip".

Built-in stages keep push fusion, and the reason is measured, not a
privilege: a user stage pulled ran at 1.01 to 1.05× the hand loop
(below), so fusing it buys almost nothing today. The lowering isn't
std's: it's promised to any one-input stage written as a `gen fn`,
std's or a user's, when it's built (rule 4 of decision 20: an
optimization, invisible). The guarantee comes from decision 1,
since blocks are specialized per call; Go's rewrite of `range` over a
function allocates when the iterator isn't inlined.

**Recursion is pushed too.** When a recursive `yield from` must pull, it
runs on one frame stack the consumer owns, with the child's first step
run inline; child frames are never boxed. **A recursive `yield from`
has the depth limit of a recursive call, pushed or pulled,** so the two
lowerings can't differ in meaning (decision 13).

## Stopping

A generator's frame is a scope (rule 5). Its `finally` runs:

- when a loop over a temporary ends, or the statement that holds a sink;
- when the scope of the `let` that names it ends, by any exit;
- when its task is cancelled, shielded and under the cleanup deadline
  (async.md).

A generator that was never stepped has run none of its body, so it has
no `finally` to run: a transaction's `BEGIN` happens at the first step.
Several generators in one scope close in reverse order, as `with`s do.
**A generator may hold a `with` across a `yield`,** a transaction across
rows, and the `with` ends with the generator, inside the consumer's
scope. If it installs a family, the family ends there too: a consumer's
`break` drains or cancels it, as it would any `with` in the generator.
In the interpreter this is the cleanup node `with` already uses, wrapped
around the rest of the block that names the generator.

Never when a count drops to zero (decision 11): a drop moves with borrow
inference, runs twice on copies, and has no error channel.

**`finally(r)` sees why it ended:** `Ok` if the generator returned,
`Err(e)` if it failed, `Err(Cancelled)` if it was abandoned, by `break`,
`take` or `find`, or cancelled. Abandonment is a cancel, so the
`finally`'s own result is thrown away. A transaction rolls back on
`break` for free, as in C# and Go, and a `.take(10)` over a writing
generator rolls it back.

**A cancel mid-step ends the generator.** Its `finally` runs.

**A generator ends once, keeps how it ended, and every later step says
so.** It's one row of a rule for every computation, calls, posted calls
and actors too ([concurrency.md](concurrency.md#ends-once)). How it
ended is what its `finally(r)` was given:

| How it ended | `finally` saw | Every later step |
|---|---|---|
| it returned | `Ok` | `None` |
| it failed with `e` | `Err(e)` | fails with `e` again |
| it was cancelled | `Err(Cancelled)` | panics: only a `finally` can get here |
| it was never stepped | nothing; its body never ran | as a task cancelled before it starts |

So every stream is fused by construction: a timed-out stream can't pass
for a clean end, and a wrapper, `zip` or `merge`, never has to remember
that what it wraps is done (Wuyts' [missing
state](https://blog.yoshuawuyts.com/the-future-trait-has-a-missing-state)).
Answering the same way forever is a promise of a generator's frame, not
of the cursor protocol: a reader at an offset can say `None` and be
asked again later, as reading a growing file does. A block given to a racing
operation (`Async.timeout`, `race`, `until`) can't step a pipeline from
outside it: a pipeline isn't an operation (rule 7). To time each step,
time it over a reader, `Async.timeout(d) fn() => &r.next()`.

**Backstop:** an open resource is an entry in its service's family, so
the family's end closes leftovers. The bugs the survey found elsewhere can't happen: Python's async
generators finalized later in another context (PEP 525, `aclosing`),
Java's `Files.lines` leaking without try-with-resources, Clojure's lazy
seq read after `with-open` closed its file, Haskell's lazy IO.

## Errors

```ren
for row in try Db.rows(q)
  try ingest(row)
```

- **`for x in try src`** marks that each step can fail. It's the same
  rule as `try` on each step of a pipe (language.md §8): the place a
  stream can stop is on the page.
- **A failure ends the stream** and is passed on after its cleanup, as
  C#, Swift and JavaScript do.
- **An error to recover from per item is a value:** a cursor of a sum
  type or of `attempt` `Result`s, as Elixir's `{:ok, v}` items are.
  There are no `catch` or `retry` operators on streams; `retry(n, on:)`
  is a function over a block, as it is everywhere else.
- **A stage's block can fail,** and its errors flow into the pipeline's
  step, as a block's errors flow into the call it's passed to. The
  `for`'s error names the stage: "`next` can fail with `BadLine`, from
  the `map` on line 12". A `try` inside the stage and one on the `for`
  aren't doubled: the first is the stage's call, the second the loop's
  step.

## Concurrency and time

**Generators stay on the consumer's task.** A step runs with the
consumer's dependencies: Kotlin's "context preservation", checked
statically. A pipeline is a block, so a block that runs on several tasks
can't step one.

**Many items at once:**

```ren
try Async.each(Net.connections(listener)) fn(conn) =>
  try Async.timeout(Duration.seconds(30)) fn() => serve(conn)

let pages = try Async.map(urls, max: 16) fn(u) => fetch(u)
```

- **`Async.each` and `Async.map` take any pull argument** (rule 3), pull
  the next item only when a slot frees, and are bounded by **`max:`,
  64 by default** (decision 7, async.md). Pulling only when a slot frees
  is what bounds memory.
- **`Async.map` keeps order.** A finished result waiting behind a slow
  head keeps its slot, so memory is bounded by `max`, as Rust's
  `buffered` and Java's `mapConcurrent` are.
- **The source is pulled on the caller's task.**
- **A timeout per item is composed,** `Async.timeout` inside the block,
  not an option on the stream.

**A producer that needs tasks runs in the consumer's scope:**

```ren
Async.produce(cap: 16, fn() => crawl(root)) fn(pages) =>
  for p in try pages
    try index(p)
```

- `crawl` sends with `Send.send(p)`, through a `Send<T>` dependency the
  call installs (decision 5), not a channel value it holds.
- When the body ends, by finishing, `break` or a failure, the producer is
  cancelled and waited for. A failure in the producer ends the stream
  with it.
- **`cap` is the backpressure.** The producer is a real task, so it makes
  progress while the body runs, and can't stall the way Rust's buffered
  futures do when nothing polls them (Oxide's "futurelock"). A producer
  that holds a pin, a lock or a lease while it sends holds it as long as
  the consumer takes.
- `Async.map_pull(src, max: 16, f) fn(results) => ...` has the same
  shape: a stage whose results are a stream, with its tasks living
  exactly as long as the consumer block.

**Merging gives items as they're ready:**

```ren
Async.merge([a, b], cap: 16) fn(items) =>
  for x in try items
    try handle(x)
```

- **Its sources run at once,** so each gets a producer task, all
  feeding one bounded queue, `cap:`, and the call owns them all. When
  the body ends, they're cancelled and waited for, as `produce`'s is.
- **Merging is producing, on the page.** A suspended step can't be
  raced without ending its generator (rule 7), so the tasks a merge
  needs are written where it's called, not hidden in a combinator.
- **`zip` and `chain` need no task:** they pull their sources one at a
  time on the consumer's task. Every stream is fused (Stopping), so
  none of them fuses by hand.

**Channels.** A channel is a dependency, `dep Events = Chan<Event>`, and
`Events.items()` is an ordinary function of `Chan<T>` in `sync`, as
`Fs.read_str` is a function of `Fs`: a cursor whose `next` is
`Events.recv()`. Nothing about it is derived. It's typed by the
dependency's name, so two channels of one element type don't mix.

**Time.** `stream.time` holds `batch(max:, within:)`, `debounce`,
`throttle` and `sample`. Each races "the next item" against a timer, so
each **takes a source whose step is one operation:** a channel's
`items()`, or a library reader that updates itself in place before each
suspension. Over a generator, the race would cancel it mid-step and end
it, which is why Kotlin and Effect pull upstream on a second task. Ren
puts that task on the page: a generator goes on a channel through
`Async.produce`, or several through `Async.merge`.

```ren
fn searcher() ! SearchDown uses Queries, Search, Results, Clock, Async =
  for q in stream.time.debounce(Queries.items(), Duration.ms(300))
    Results.show(try Search.run(q))
```

Every operator takes its time from `Clock`, so under `sim` it runs on
the simulated clock, schedules are explored over seeds, and a run that
went wrong replays from its journal.

**Actors** loop over a reader they keep in their state: decision 2's
handler-state row covers only `Async.until`, `release` and
block-parameter calls, so a step that calls another service holds none
of the actor's state. A model of service cycles under decision 10 found
it sound (research/decision-11/).

## The standard library

**The default set,** on every cursor:

- transforming: `map`, `select`, `reject`, `take_while`, `drop_while`,
  `flat_map`, `with_index`, `scan`, `dedup_by`
- shaping: `take`, `drop`, `batch(n)`, `batch_while`, `windows(n)`,
  `zip`, `merge_by`
- consuming: `sum`, `reduce`, `count` (its predicate optional), `any`,
  `all`, `find`, `first`, `min`, `max`, `to_array()`
- concurrent: `Async.each` and `Async.map` with `max:`, `Async.merge`
  with `cap:`
- producing: `gen fn`, `xs.cursor()`, `Events.items()`

`drop` is operators.md's name, so `skip` and `skip_while` go, and
`chunks` becomes `batch`, keeping "chunk" for bytes. `batch_while`
flushes what it holds at the end. A chunk's lines are `chunk.lines()`,
strings.md's name.

**Two forms per resource:** a use-here generator with a `finally`
(`Fs.lines(p)`, `Db.query(q)`), and a reader you can keep, which is data
(`Fs.line_reader(p)`, `Db.rows(q)`, `Net.frames(conn, fmt)`).
`Net.frames` reads `Short.need` into one buffer, so nobody writes a
framer whose `buf + chunk` is quadratic.

**Sharp tools,** in `stream` and `stream.time`: `Async.produce`,
`Async.map_pull`, `batch(within:)`, `debounce`, `throttle`, `sample`.

**Left out on purpose:** hot, shared and state flows (state many read is
a handler, with `Async.until`); subscribe and dispose objects;
operators that choose schedulers; `catch`, `retry` and `onErrorResume`
operators; implicit chunking; anything whose meaning depends on whether
a stream is hot or cold. The module stays the size of Elixir's `Stream`,
not Effect's, whose `Stream` has 235 exports, or Rx's 400 operators.

## Cost

Measured on C models of what Ren's compiler would emit, against a
hand-written C loop, medians of 11 runs, checked by a second agent and
re-run:

| Workload | Push | Pull, composed where written | Other lowerings | Rust | Go |
|---|---|---|---|---|---|
| map → select → take | 1.01 | 0.99 | 1.22 with `next` not inlined | 0.97 | push 1.11, `iter.Pull` 1.31 |
| recursive tree walk | 0.97 | 1.03 on one frame stack | **13.0 with child frames boxed** | stack 0.94, boxed 15.4 | push 1.58, `iter.Pull` 3.85 |
| a user stage, `dedup_by` | 1.01 | 1.05 | — | 0.93 | `iter.Pull` 9.9 |
| `zip` | 1.07, one side pushed | 1.17 | 1.86 with the zip block not inlined | 0.90 | `iter.Pull` 25.7 |
| a pipeline passed to a function | 1.02 | 1.02 | — | 1.01 | 1.07 |

- **The obvious code is the fast code,** because a chain is composed
  where it's written (decision 1). Push and pull of a flat chain both
  equal the hand loop. Ren is level with Rust, not faster: the Rust
  column gives Rust libc's `memchr`, as the C models use; with its own,
  Rust's line splitting is 1.39 and 1.51.
- **Pull costs about a nanosecond a step only when a `next` isn't
  inlined.** Push is the guarantee for those cases.
- **The one trap is a boxed recursive `yield from`,** the trap of Rust's
  `Box<dyn>` and Python's `yield from`. Ren never boxes child frames.
- **Fusing a user stage into the push bought nothing** (1.02 once the
  loop's shape is fixed), so it's **later**, and when it lands it's the
  same lowering built-in stages get, for any one-input `gen fn` stage.
- These are models without reference counting, with small generators.
  They're re-measured on Ren's own output once `gen fn` lowers natively.

The interpreter runs an effectful generator on a one-shot fiber (OCaml 5
effects) and copies a pure one by replaying it to its position; the
native build copies frames.

## Compiler errors

```
error: `rows(q)` uses `Db`, so its stream lives in this scope
  self.pending = rows(q)
                 ^^^^^^^ a block, which can't be stored
  = a generator that uses a dependency runs in its caller's frame
  help: to keep a position, keep a reader, which is data: `Db.rows(q)`
```

The same error, with "returned", for a stream returned from a function,
and with "a `gen fn`" in the help for a pipeline over data.

```
error: a pipeline steps a named cursor in place
  let errs = r.select(bad)
             ^ `r` is a cursor
  help: `&r.select(bad)`
```

```
error: `let` binds one pipeline written right there
  let rows = if all then &r.select(any) else &r.select(p)
  help: choose inside one stage: `&r.select(fn(x) => all || p(x))`
```

```
error: `yield` inside a block
  Async.timeout(d) fn() =>
    yield next_page()
    ^^^^^
  = the generator would stop here with the timeout's scope open in its consumer
  help: time the step where it's consumed, or put the producer on a task:
        `Async.produce(cap: 1, fn() => ...)`
```

```
error: `next` can fail, and nothing handles it
  for row in Db.rows(q)
             ^^^^^^^^^^ it can fail with `DbDown`, from `Db.rows`
  help: `for row in try Db.rows(q)`
```

```
error: `Sql.Rows` can't leave the `with` that installs `Sql`
```

`.filter(` suggests `.select(`, and `.skip(` suggests `.drop(`.

## Programs

Three of the thirteen programs written against this design
(research/streams/).

### Tail a log, and resume after a marker

`follow(path)` is a `gen fn` that uses `Fs` and `Clock`: it waits at the
end of the file and carries a partial line, so a call to it is a block.

```ren
fn first_errors(path: Path) -> Array<Entry> =
  try follow(path)
    .map(parse)
    .select(fn(e) => e.level == Error)
    .take(100)
    .to_array()
  // pushed: the 100th error leaves `follow`'s loop, its `finally` closes the file

fn sections(path: Path) uses Fs, Clock, Console =
  let lines = follow(path)
  for line in try lines
    if line == "--- boot ---" then break
  for e in try lines.map(parse).select(fn(e) => e.level == Error)
    Console.print(e.msg)
  // `follow`'s `finally` runs here, at the end of `lines`' scope
```

### Rows in a transaction

```ren
pub gen fn orders_in_tx(c: CustomerId) -> Order uses Sql ! DbDown | Conflict | BadRow =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try Sql.rows("select * from orders where customer = $1", c)
      yield try Order.from_row(row)

fn first_big(c: CustomerId, limit: Money) -> Option<Order> =
  try orders_in_tx(c).find(fn(o) => o.total > limit)
  // found early: the transaction's `finally` sees Err(Cancelled) and rolls back

fn preview_then_export(c: CustomerId, w: Writer) uses Sql, Fs, Confirm, Console =
  let orders = orders_in_tx(c)
  for o in try orders.take(5)                        // BEGIN at the first step
    Console.print(o.summary())
  if not try Confirm.ask("export the rest?") then return   // ROLLBACK at scope end
  for o in try orders                                // the same snapshot
    try w.write_line(o.csv())
  // COMMIT: the generator finished
```

Inside a transaction, `Sql.rows` reads through a named portal in
batches, so other statements can run between steps.

### Frames, with errors at stream offsets

```ren
gen fn legacy_rows(body: Bytes, base: Int) -> Row ! FormatError =   // pure: a value cursor
  var c = body.cursor(from: base)                    // offsets count from `base` (strings.md)
  while c.left() > 0
    let id = try &c.varuint()
    let name = try &c.str(try &c.varuint())
    yield Row { id, name }

pub fn replicate(conn: Conn) ! NetError | FormatError | NoHello | Gap(at: Int) | StoreDown
    uses Net, Store =
  var frames = Net.frames(conn, Msg.wire)            // data: conn id, one buffer, its base
  let Some(Hello(_)) = try &frames.next() else fail NoHello
  var want = try Store.last_seq() + 1
  while true
    let start = frames.at()                          // a stream offset, for reports
    let Some(m) = try &frames.next() else return     // EOF between frames: a clean end
    match m
      Batch(seq, ops) =>
        if seq != want then fail Gap(start)
        try Store.apply(ops)
        want += 1
      Legacy(body) =>
        for row in try legacy_rows(body, start + 5)         // after `len` and `kind`
          try Store.put_row(row)
      Bye => return
      Hello(_) => fail Malformed(start, "Msg", "a second Hello")
```

A truncated frame at EOF is `Short(at, need)` with `at` in the stream.

## What it changes

| Today | Becomes |
|---|---|
| foundations.md, "What's given up": generic lazy pipelines | given up instead: storable generic adapters over any cursor (`Peekable<C>` in a record), and storing a generator that uses a dependency |
| decision 1: a `let` binds one literal block | one block made here: a literal, a chain, or a call that gives a block |
| decision 2's table | adds a row: an `&r` head or pull argument steps `r` at each step, held for the call. The handler-state row narrows to `Async.until`, `release` and block-parameter calls |
| decision 3: a description's arguments can't hold `next` | can't hold a block or an instance; a value cursor is data |
| decision 12 | adds rule 2, read from the inferred row |
| decision 13 | a recursive `yield from` has one depth limit, pushed or pulled |
| async.md | `Async.each` and `Async.map` take any pull argument, `max:` 64 by default; `produce` installs `Send<T>`; `map_pull` takes the consumer-block shape; channels are dependencies with `items()` |
| errors.md | abandonment (`break`, `take`) is `Cancelled` to a generator's `finally`, its result thrown away |
| runtime-io.md | the pool may move a held leased chunk to the heap; a pool metric counts it |
| stdlib.md | `Async.pull` goes (`yield from` and `Async.produce`); two forms per resource; readers hold an id and an offset, and a service's open resources are a family keyed by id; the default set above |
| language.md §8 | a line starting with `.`, indented further, continues the line above |
| operators.md | `count`'s predicate is optional across the vocabulary |

## Left out

- **Stored closures,** in any form. A pipeline is a block.
- **User-defined requirements.** Sinks take a block, `rows: fn() ->
  Option<T>`, so `next` never joins language.md §3.
- **Storing a generator that uses a dependency.** Keep a reader.
- **An `Emit` dependency** as a second way to write producers. Effekt's
  push stages pass blocks to named functions, which rule A allows; what
  Ren can't take is its pull side, `zip`, which stores a boxed
  continuation.
- **Comprehension syntax.**
- **A separate asynchronous iterator.**
- **Affine or unique cursors.** Generators that use dependencies are
  blocks; data cursors copy honestly.
- **`next(within:)`.** Time a step over a reader.
- **Hot streams, schedulers and error operators.**

## Open

- **Chain recognition is by type,** not by spelling as in the prototype,
  and messages must not name hidden locals (`$frame45`).

## Later

- **Fusion through a user `gen fn` stage,** if a program shows a gain.
- **`Async.map(unordered: true)`,** results as they finish.
- **Splitting a stream to several consumers** (`broadcast`): a channel
  per consumer today.
- **A conflating channel** (keep the newest), which `sample` and
  telemetry want.
- **A dynamic N-way merge** over frames, for a memtable and N tables.
  Blocks can't sit in an `Array`, so today it merges `Array<SstReader>`,
  data cursors. An erased `Cursor<T>` would be decided with it, and with
  `walk.Cursor`'s naming.
- **Snapshotting pure frames** in the interpreter, since copying by
  replay is quadratic for a backtracking parser.

## Evidence

Research in research/streams/: the survey, the stress test (ten
programs, probes of soundness, feasibility, ethos and prior art, two
alternative designs, three judges, and the amendments they produced),
and the second round: thirteen programs against Kotlin, C#, Go, Rust and
Elixir, the interpreter prototype (about 875 lines; the generator
runtime is 118 of them, and the whole interpreter path is estimated at
1,300–1,900), the push and pull models with their verification, and
the composition audit that gave the seven rules. Of the thirteen
programs, seven read better than the best twin, five the same, and one
worse (a lexer, which keeps byte offsets by hand). None needed an
exception to the rules.

**Sources:** Kotlin `Flow`, `Sequence` and `runTest`; C#
`IAsyncEnumerable`, `DisposeAsync` on `break` and CS1625; JavaScript's
`return()` on `break`; Python PEPs 525, 533 and 789; Rust `Stream`,
`by_ref`, RFC 3550 and Oxide's futurelock
(https://rfd.shared.oxide.computer/rfd/609); Swift SE-0298, SE-0421 and
SE-0516; Go 1.23 `iter.Seq`, `iter.Pull` and `testing/synctest`; Elixir
`Stream`, `Task.async_stream` and GenStage; Effect `Stream`
(`/tmp/ren-refs/effect/packages/effect/src/Stream.ts`, 235 exports) and
`TestClock`; Java's `Files.lines` and JEP 485; Effekt's second-class
streams (`/tmp/ren-refs/effekt/libraries/common/stream.effekt`, lines
30–274); Koka, Unison, Flix and Lean; stream fusion (Coutts,
Leshchinskiy and Stewart; Kiselyov et al., POPL 2017); Roc's lambda sets.

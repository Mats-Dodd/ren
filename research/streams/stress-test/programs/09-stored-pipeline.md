# 09. A pipeline that has to be stored or returned: the move to `gen fn`

The job: a log service lets clients page through "error entries in this
file since time T". Each client's position must survive between
requests, so the stream is stored in the service's state, keyed by
client. A config flag decides whether the source is a file read once or
a followed (tailed) file. And a helper that builds the pipeline is
reused by two consumers.

## Ren, per the draft

### Step 1: the pipeline, where it's consumed. Fine.

```ren
var r = Fs.line_reader(path)
for e in try &r.map(Entry.parse).select(fn(e) => e.level >= min && e.at >= since)
  try out.send(e)
```

### Step 2: factor it into a helper. Refused.

```ren
fn errors_since(path: Path, min: Level, since: Time) =
  Fs.line_reader(path).map(Entry.parse).select(fn(e) => e.level >= min && e.at >= since)
// error: a pipeline holds the blocks its stages were given, so it can't be returned
```

### Step 3: the move to `gen fn`

```ren
gen fn errors_since(path: Path, min: Level, since: Time) -> Entry
    uses Fs ! FsError | Malformed =
  for e in try &Fs.line_reader(path).map(Entry.parse).select(fn(e) => e.level >= min && e.at >= since)
    yield e
```

The move is mechanical: add `gen`, a return type that is the element,
and `for e in ... yield e`. The block in `select` captures `min` and
`since`, which are now the generator's own fields. That reads well.

### Step 4: the config flag

```ren
gen fn entries(path: Path, follow: Bool) -> Str uses Fs, Clock ! FsError =
  if follow then yield from tail(path) else yield from Fs.line_reader(path)
```

A plain `fn` can't return "either cursor": they're two types, and
there's no `dyn`. So the choice goes inside a generator and each arm
delegates. Per the draft, the child of `yield from` is "kept as data,
boxed like a recursive enum's field", so this costs a box and a call
through it per item, though nothing here is recursive.

### Step 5: store it, per client

```ren
dep Pages =
  page: fn(c: ClientId, n: Int) -> Array<Entry> ! FsError | Malformed

handler paged(path: Path, min: Level) for Pages uses Fs, Clock =
  var open: Map<ClientId, ???> = Map.empty          // what is the type of errors_since(...)?
  page(c, n) =>
    var cur = open.get(c) orelse errors_since(path, min, Clock.now() - Duration.hours(1))
    let out = try &cur.take(n).to_array()            // hmm: take(n) is a pipeline over `cur`
    open = open.set(c, cur)
    out
```

The `???` is the problem. The draft never says what type a `gen fn`'s
call has. Without a name, the record field, the map's value type and
the dependency's operation signature can't be written. Options I can
see:

- **A nominal type per generator:** `gen fn errors_since` declares the
  type `ErrorsSince` (or `errors_since.Cursor`), as a closure-free state
  machine. Then `Map<ClientId, ErrorsSince>` works.
- **A generic field:** `handler paged<C>(...)` doesn't help, the handler
  makes the cursor itself, and a handler's state type isn't a parameter.
- **An ADT the user writes:** `type Source = | Once(ReadOnce) | Tailed(Tail)`
  with a hand-written `next` that matches. That's the `dyn` the
  language gave up, written by hand, and fine when it's needed; but it
  shouldn't be needed for one generator.

`take(n)` over a stored cursor also needs care: `cur.take(n)` holds
`cur` (copy or borrow? see 06-csv.md), and after `to_array()` I need
`cur` to have advanced by `n`. If the pipeline holds a copy of a file
reader, `cur` didn't move and the next page repeats this one.

### Step 6: a reusable lazy stage that takes a block. Impossible.

Two consumers want "dedupe consecutive entries by a key", with
different keys. In a pipeline it would be `.dedup_by(fn(e) => e.code)`,
but that's not in the default set. The user can't add it:

- a `gen fn dedup_by<C>(src: C, key: fn(Entry) -> Code)` can't take a
  block;
- a method on the cursor type can't be added (no adding methods to
  someone else's type, language.md §7);
- a `fn` returning a pipeline can't return it.

So a user-written lazy stage can only be parameterised by data: write
an ADT `Key = | ByCode | ByHost` and match on it, or go eager.

## Counterparts

**Rust** (strongest for "fused and returned"):

```rust
fn errors_since(path: &Path, min: Level, since: Time)
    -> io::Result<impl Iterator<Item = Result<Entry, Malformed>>> {
    let r = BufReader::new(File::open(path)?);
    Ok(r.lines().map(|l| Entry::parse(&l?))
        .filter(move |e| matches!(e, Ok(e) if e.level >= min && e.at >= since)))
}
struct Paged { open: HashMap<ClientId, Box<dyn Iterator<Item = Result<Entry, Malformed>> + Send>> }
```

The helper returns a fused `impl Iterator`; storing it heterogeneously
needs `Box<dyn ...>`; a reusable `dedup_by` is an extension trait (or
itertools' `dedup_by_key`). 9 lines, and every "impossible" in step 6
is possible.

**Kotlin Flow** (simplest to store): `fun errorsSince(...): Flow<Entry>
= lines(path).map(Entry::parse).filter { it.level >= min && it.at >=
since }` and `val open = mutableMapOf<ClientId, ReceiveChannel<Entry>>()`
(a cold `Flow` restarts per `collect`, so keeping a *position* means
`produceIn(scope)`, a channel and a coroutine per client). A user stage
is `fun <T, K> Flow<T>.dedupBy(key: (T) -> K) = flow { ... }`.

**C#:** `IAsyncEnumerable<Entry> ErrorsSince(...)` returning a LINQ
chain (`System.Linq.Async`), stored as `IAsyncEnumerator<Entry>` in a
`Dictionary<ClientId, IAsyncEnumerator<Entry>>`. A user stage is an
extension method with `async IAsyncEnumerable` and `yield return`.

## Comparison

- **The move to `gen fn` itself is good:** 3 lines, mechanical, and the
  fix-it in the draft writes it. Ren's generator is fully owned data, so
  storing it in handler state is safe without `Send`/`Pin`/lifetimes,
  where Rust needs `Box<dyn Iterator + Send + 'static>` and Kotlin
  needs a coroutine per client to keep a position.
- **Worse than all three** at: naming the stored type (step 5),
  returning one of two streams (step 4: a box per `yield from`), and
  user-written lazy stages with a block (step 6).
- **A cost cliff on refactoring.** Step 1 is one fused loop. Step 3
  consumed by a `for` is pushed, still fused. But `errors_since(...)
  .take(10)` makes the generator a pulled cursor, a state machine with a
  resume per item, and the draft lists "fusion through a `gen fn` whose
  consumer is a pipeline" as **later**. Extracting a helper, the most
  ordinary refactoring, changes the cost; Rust's `impl Iterator` doesn't.
  That's against "the obvious way is the fast way".

## What the draft forbids or leaves unclear

1. **The type of a generator's cursor** has no name or syntax. Needed
   for every store and return the draft says `gen fn` is *for*.
2. **`yield from` boxes even when not recursive.** Box only when the
   child is the generator itself or a cycle; otherwise the child's state
   is a field of the parent (it's a closed, known type). Same as a
   non-recursive enum field.
3. **How the standard library writes `map`.** A block-holding cursor
   returned from `map` is exactly what users are forbidden to return. If
   `map` is built in, the set of lazy block-taking stages is closed,
   which should be said, and the default set should grow the usual
   missing ones (`scan`, `dedup_by`, `group_by` adjacent, `intersperse`,
   `chunk_by`), because users can't. If it's written in Ren, the
   mechanism (a function whose result is a block-kind value, inlined
   into its caller) is user-reachable, and could simply be allowed: **a
   function whose result is a pipeline is a block too** (it only travels
   down: its result is bound, looped, or passed on in the caller's
   frame), provided its blocks don't point into the returning
   function's frame; see the doubt below.

## Soundness doubts

- **Returning a pipeline whose blocks capture the returning function's
  frame** is unsound in general (the frame is gone), which is why the
  draft forbids it. The only safe version is one where the function is
  always inlined into its caller (a macro-like "inline fn"), or where
  captures are copied into the pipeline. The first is cheap to specify
  and costs nothing at run time; the second is a stored closure. If the
  standard library's adapters need either, say which.
- **Stored cursors and dependencies.** The stored `errors_since` cursor
  holds a file id issued by the `Fs` that served the first `page`. Each
  later `page` resumes it under whatever `Fs` is outside the `paged`
  handler then. In one program that's the same instance, so this is
  fine here; but the draft gives no rule that makes it so (see 07, D).

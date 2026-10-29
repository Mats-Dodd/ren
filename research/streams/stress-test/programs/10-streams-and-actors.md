# 10. Streaming inside an actor (language.md §11)

Two jobs on the collaborative editor's `Docs` family:

- **A.** An actor operation consumes a stream: importing a document's
  history from a file of ops, applied to the actor's text as one
  operation, so nobody sees half an import.
- **B.** `Docs.each` over the family produces a stream: a nightly
  report that streams every live document's summary into a file.

## Ren, per the draft

```ren
dep Doc =
  edit: fn(op: Op) -> Version ! StoreDown
  summary: fn() -> Summary
  import: ???                                       // see A1
dep Docs = Actors<DocId, Doc>
```

### A1. The operation is given the stream: not expressible

```ren
  import: fn(ops: ???) -> Version ! StoreDown | Malformed
```

What type is `ops`? A pipeline is a block, and per compiler.md's 11a
notes, operations take neither blocks nor type parameters ("the
functions that take blocks and are generic can't be operations, which
take neither"). A generic `C has next` is a type parameter. A `gen fn`
cursor has no nameable type (see 09). So an operation can't take a
stream unless the stream's type is a concrete, named cursor:
`Fs.LineReader` works, `r.map(Op.parse)` doesn't.

Even if it could: the blocks inside a pipeline were written in the
caller and find their dependencies there (decision 5), but decision 10's
no-deadlock argument needs "a block passed to an operation gets
dependencies only from its parameter's type". A pipeline whose
`select` block calls `Doc.summary()`, passed to `Doc.import` inside
`Docs.at(id)`, calls back into the actor its operation already holds.
The draft says a pipeline's "checks are the ones blocks already have";
that must include this one, and the operation's parameter would then
have to state the pipeline's `uses`.

### A2. The operation makes the stream itself: fine

```ren
handler doc(id: DocId) for Doc uses Store, Fs, Conns =
  var text = try Store.load(id)
  ...
  import(path) =>
    for op in try &Fs.line_reader(path).map(Op.parse)
      text = text.apply(op)
    try Store.save(id, text)
    text.version
```

Holds the actor for the whole file, which is what's wanted (one
operation) and what decision 10 says it costs (other callers of this
key queue; other keys don't). The pipeline's block is written in the
arm, so its dependencies are the handler's: no deadlock question.

### A3. The caller streams, one operation per chunk

```ren
fn import(id: DocId, path: Path) ! StoreDown | Malformed | FsError uses Docs, Fs =
  try Docs.at(id) fn() =>
    for ops in try &Fs.line_reader(path).map(Op.parse).chunks(500)
      try Doc.edit_all(ops)
```

Not atomic (others interleave between chunks) but bounded memory, and
the actor never runs file I/O. A good shape, and it reads well.

### A4. Fan-in with `post`

```ren
for (id, op) in try &Net.ops(conn)
  Docs.post(id) fn() => Doc.edit(op)        // mailbox bounds the stream; posts can't fail
```

The cleanest of all: a stream fanned into actors, backpressure from
the bounded mailbox. But `Doc.edit` can fail with `StoreDown` and a
posted block "can't fail", so it needs `attempt` or a `match` inside, and
the error goes nowhere unless the program writes it somewhere.

### B1. A generator over `Docs.each`: refused (or should be)

```ren
gen fn summaries() -> Summary uses Docs =
  Docs.each(fn() => yield Doc.summary())
```

The draft's forbidden list for `yield` is `Async.scope`, `beside`,
`timeout`, `race`, `retry`, `with` and `finally`. `Docs.each` and
`Docs.at` aren't on it, but they must be: `each` pins the actor, and a
generator suspended there leaves the pin (and `each`'s own frame) in a
stored cursor. More generally, the draft never says whether `yield` can
appear inside **any** block. If it can, the function the block was
passed to (`Docs.each`, or a pure `xs.each`) must itself be suspendable
inside the generator's frame, and a function whose `uses` doesn't reach
a dependency has no frame to suspend (decision 12). It has to be: **`yield`
only at the generator's own level, never inside a block.**

### B2. `Async.produce`

```ren
fn nightly(out: Path) ! FsError uses Docs, Fs, Async =
  var w = try Fs.create(out)
  finally w.close()
  Async.produce(cap: 64, fn(tx) => Docs.each(fn() => tx.send(Doc.summary()))) fn(sums) =>
    for s in try &sums
      try w.write_line(s.csv())
```

Works under the draft's rules. Two notes: the producer task pins each
actor while it waits on `tx.send` with a full buffer, so a slow file
keeps one actor unevictable for as long as the consumer is slow; and if
the consumer's body calls `Docs.at` on a family at `max:` with every
other actor pinned, it waits for a slot the producer won't release until
the consumer reads: a wait cycle decision 18's rules don't cover
(they cover `at` inside `at`, not a pin held across a channel send).

### B3. Eager, the honest default

```ren
fn nightly(out: Path) ! FsError uses Docs, Fs =
  var all: Array<Summary> = []
  Docs.each(fn() => &all.push(Doc.summary()))
  var w = try Fs.create(out)
  finally w.close()
  for s in all
    try w.write_line(s.csv())
```

At `max: 50_000` that's a few MB, and pins each actor only for one call.
I'd write this.

## Counterparts

**Elixir, GenServer + Registry + Stream** (the strongest: actors are
native, and a stream into a process is just messages):

```elixir
# A: the process consumes a stream it opens itself
def handle_call({:import, path}, _from, doc) do
  text = path |> File.stream!() |> Stream.map(&Op.parse!/1) |> Enum.reduce(doc.text, &Text.apply(&2, &1))
  :ok = Store.save(doc.id, text)
  {:reply, text.version, %{doc | text: text}}
end

# A4: fan-in
Stream.each(ops, fn {id, op} -> GenServer.cast(via(id), {:edit, op}) end) |> Stream.run()

# B: every live doc, as a stream
Registry.select(Docs.Registry, [{{:"$1", :"$2", :_}, [], [:"$2"]}])
|> Stream.map(&GenServer.call(&1, :summary))
|> Stream.map(&Summary.csv/1)
|> Stream.into(File.stream!(out))
|> Stream.run()
```

A, A4 and B in about 12 lines. Elixir can *send* a `Stream` value
(a struct of closures) to a process, but it runs in the receiver with
the sender's closures, which is A1's hazard, unchecked. `cast` has an
unbounded mailbox, so A4 has no backpressure.

**C#, Orleans 7+**, whose grain methods can return `IAsyncEnumerable<T>`:

```csharp
public interface IDoc : IGrainWithStringKey {
    Task<int> Import(string path);                 // A2 shape: the grain opens the file
    IAsyncEnumerable<Op> History();                // a grain *producing* a stream
}
```

But there's no "every live grain" enumeration (by design: grains are
virtual), so B needs a separate index grain, and the stream a grain
returns is pulled across the wire in batches.

## Comparison

- **A2, A3, A4, B3** are Ren at its best: short, the costs are on the
  page (one operation holds the actor, `post` bounds the mailbox), and
  the rules are the ones actors already have. A3 reads better than
  Elixir's equivalent.
- **A1** (an operation given a stream) and **B1** (a generator over the
  family) are where Ren can't say what Elixir and Orleans can. A1 is
  fine to refuse; B1 should be refused *explicitly*.
- **B2** works but shows how `Async.produce` composes with pins: the
  first place in these programs where a stream adds a wait the actor
  rules didn't anticipate.

## What the draft forbids or leaves unclear

1. **`yield` inside any block.** The forbidden list should be a rule,
   not a list: `yield` is allowed only in the generator's own body,
   outside every block. That covers `Docs.each`, `Docs.at`, `xs.each`,
   `retry`, and anything a library adds.
2. **Pipelines passed to operations.** Either "a pipeline can be passed
   to a parameter" excludes operation parameters (consistent with
   11a's rule that operations take no blocks), or the parameter's type
   states the pipeline's `uses`, as decision 10 requires of blocks. The
   draft should say which.
3. **Pins held across a channel send.** If `Async.produce` stays, its
   docs should say that a producer that pins actors, holds locks or
   leases while it sends is holding them for as long as the consumer
   takes, and `ren review` could flag a `send` inside `Docs.each`/`at`.

## Soundness doubts

- **A1**: a pipeline's block reaching the actor its receiving operation
  holds would be a single-task deadlock (or, with a re-entrancy check,
  a panic). The current block rule prevents it only if pipelines are
  treated as blocks *at operation boundaries* too.
- **B2**: a wait cycle between a family slot and a channel slot, outside
  decision 18's inner-to-outer argument. Rare (needs a full family with
  every other actor pinned), but the "no deadlock" claim isn't true of
  every program that combines `Async.produce` and `Docs`.

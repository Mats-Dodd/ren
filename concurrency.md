# Concurrency

How concurrent work is shaped in Ren, who owns it, and how it ends. It
unifies Yoshua Wuyts' five arguments into one set of rules:
[tree-structured concurrency](https://blog.yoshuawuyts.com/tree-structured-concurrency)
is what makes cancellation, errors and ordering compose;
[tasks are the wrong abstraction](https://blog.yoshuawuyts.com/tasks-are-the-wrong-abstraction),
and concurrency is composing computations;
[actors, not detached tasks](https://blog.yoshuawuyts.com/replacing-tasks-with-actors),
are how work runs after a function returns;
[a finished computation should say so](https://blog.yoshuawuyts.com/the-future-trait-has-a-missing-state);
and [streams are classified by cardinality](https://blog.yoshuawuyts.com/streams-concurrency).

> **Status:** decided. The families half is applied to the docs, and the
> interpreter follows in the services stage's step 10. The rest (the
> rule, ends once everywhere, combinators as the surface, `merge`,
> resources as families) is decided here and is being carried into
> [async.md](async.md), [streams.md](streams.md) and
> [foundations.md](foundations.md). The families' changes are listed in
> [research/structured-actors/AUDIT.md](research/structured-actors/AUDIT.md)
> and model-checked in
> [research/structured-actors/MODEL.md](research/structured-actors/MODEL.md).
> The runtime under it is [runtime.md](runtime.md).

## The rule: the shape decides the owner

**Concurrency is a relationship between computations, and its shape
decides its owner.**

| Relationship | Shape | Needs names? | Owner | In Ren |
|---|---|---|---|---|
| one-to-one | a list | no | the call | a call; `for x in s` |
| many-to-one | a tree | no | the call | `both`, `race`, `map`, `each`, `zip`, `chain`, `merge` |
| one-to-many | a tree whose receivers are named | yes | a family | a channel; a fan-out by key |
| many-to-many | a graph | yes | a family | actors; an event bus |

> **If the work combines into the call that asked for it, it's a tree:
> a combinator owns it, and it's done when the call returns. If others
> must reach it by name, it's a graph: a family owns it, reached by key
> and drained when its `with` ends. Every computation ends once and
> says how.**

It's the last clause of [the bet](foundations.md#the-bet), "work is a
tree": every piece of concurrent work has an owner and ends before it.
A task is code, so it never outlives its call; work outlives its call
only as data, a `D.Call` with no block in it, posted to a family
reached by name. That's "code flows down the stack, data flows
anywhere", applied to work.

There are two owners and no third: no detached task, no handle kept
past its call, no pool nobody owns. A detached task is Wuyts'
"dangling" node, and an actor is his fix for it, "a reachable task pool
with a locality that can be managed", whose root is the program's
`with`, not the process. His properties hold on both sides:

| | A call's work | A family's work |
|---|---|---|
| **Cancellation goes down** | at dependency calls; `finally` is shielded | a family's mail outlives its poster; the family's `with` drains it, or drops it when cancelled |
| **Errors go up** | a failure cancels the work beside it, and the first one wins | a posted operation can't fail; setup's errors are the poster's |
| **Returned means done** | when the call returns | when the family's `with` ends |
| **A run replays** | task paths name each task by its place in the tree | a post is a `D.Call` value, journaled as data, delivered in order per key |

### The line: reached by name

Scopes are blocks, passed down and never stored, so a call's work is
reachable only inside that call, and the line between the owners draws
itself:

| Work | Reached by name? | Owner |
|---|---|---|
| a server's connections | no | `Async.each` over the listener |
| a metrics flush, a cache refresh, a pool's health check | no | `Async.beside` |
| fan-out inside a request | no | `map`, `both`, `race` |
| an open file, a database cursor, a connection's buffers | yes, by id | the service's family |
| a document edited from many sessions | yes, by `DocId` | a family |
| a refresh per user, asked for by any request | yes, by `UserId` | a family |

## Ends once

Wuyts' missing state: a future that's finished has no state that says
so, and every wrapper pays for it, which is why Rust's `select!` needs
every stream fused by hand. **In Ren every computation ends once, keeps
how it ended, and every later question says so.**

| Computation | Ends once as |
|---|---|
| a call to a dependency | its id has a generation, so a late reply can't land on a new call; a reply nobody waits for is released |
| a stream's frame, a generator | the table below |
| a posted call | it runs once, or is dropped with its family's cancel, and the journal says which |
| an actor | an incarnation, `docs[DocId(7)]#3`; an id from an ended one fails with `Closed` |

A generator keeps exactly what its `finally(r)` was given:

| How it ended | `finally` saw | Every later step |
|---|---|---|
| it returned | `Ok` | `None` |
| it failed with `e` | `Err(e)` | fails with `e` again |
| it was cancelled | `Err(Cancelled)` | panics: only a `finally` can get here |
| it was never stepped | nothing; its body never ran | as a task cancelled before it starts |

So every stream is fused by construction, and `merge` and `zip` need no
fusing. Answering the same way forever is a promise of a frame, not of
the cursor protocol: a reader at an offset can say `None` and be asked
again later, as reading a growing file does.

## The tree side: combinators, not tasks

Tasks are the wrong abstraction for a program to write. **Concurrency
is a combinator over calls and streams, and parallelism is a property
of the work,** not a `spawn`:

| | One answer: a call | Many answers: a stream |
|---|---|---|
| **one after another** | `a(); b()` | `for x in s`; `chain` |
| **all of them** | `both`, `map` | `zip` |
| **the first** | `race`, `timeout` | `take(1)` of a `merge` |
| **as they're ready** | | `merge` |
| **each, at most n at once** | `map(max:)` | `each(src, max:)`, Wuyts' `for par` |
| **beside the body** | `beside` | `produce` |

- **A server is `each`.** `try Async.each(Net.connections(l), max:
  10_000) fn(conn) => serve(conn)`: bounded, a connection's failure its
  own, done when the listener ends.
- **Parallelism is a property.** `Async.map` over a block that uses no
  dependency runs on every core (decision 7). There's no `par_map` and
  no `spawn_blocking`.
- **Work that finds more work** (a crawler) is a combinator too:
  `Async.expand(roots, max: 16) fn(url) => try links(url)` runs each
  item's call at most 16 at once, feeds what it returns back in, and
  is done when nothing is left. The recursion is the tree.
- **`scope` and `spawn` are the layer std writes these on,** as `trust`
  code is the layer under safe code. They stay public, since a program
  may write a combinator std doesn't have (decision 20, rule 2), and
  they're anonymous: `s.spawn` gives nothing back, and there's no
  `s.start`, no task handle, no `s.replace`. A handle kept to be joined
  later is the start of reaching work by name. "Cancel the last one" in
  one call is `race(query, next_input)` in a loop; "the latest wins"
  across calls is a family whose operation skips what's redundant.
- **The four things the rest is written over** are a handler (state,
  one operation at a time), a scope (anonymous work owned by a call), a
  family (keyed handlers owned by a `with`) and `Async.until` (the one
  way to wait). Everything above, with `sync`'s channels and
  semaphores, `striped` and `actors`' policies, is std (decision 20),
  and in the runtime these are the three nouns of
  [runtime.md](runtime.md#three-nouns).

## Streams: calls that answer many times

**A stream is a call that answers many times.** It's not a third kind
of thing: it obeys the rule above, by the shape of each relationship.

- **One-to-one is a loop.** `for x in try s` steps it on the consumer's
  task, and a generator's frame is owned by the scope that binds it, as
  a `with` is. It ends with that scope, its `finally` shielded, its
  errors at the consumer's step (streams.md, rules 1 to 5).
- **Many-to-one is a combinator, owned by the call.** `zip` and `chain`
  pull their sources one at a time on the consumer's task, so they need
  no task. **`merge` gives items as they're ready,** so its sources must
  run at once: each gets a producer task feeding one bounded queue,
  `cap:`, and the call owns them all. A suspended step can't be raced
  without ending its generator (streams.md, rule 7), so merging *is*
  producing, on the page:
  `Async.merge(a, b, cap: 16) fn(items) => for x in try items ...`.
  Its sources are separate arguments, as `both`'s and `race`'s are,
  since a block can't sit in an array; a list of sources known only at
  run time has to be data: value cursors, readers or channels.
- **One-to-many needs names, so it's a family.** A channel is a
  dependency, `dep Events = Chan<Event>`, installed by a `with` that
  owns it; a fan-out to named receivers is a family keyed by receiver.
- **Concurrent processing is `each`.** Pulling the next item only when a
  slot frees is what bounds memory.
- **A generator never crosses tasks by itself.** It stays on its
  consumer's task; `produce` and `merge` are the crossings, written on
  the page, where Kotlin and Effect would start a hidden second task.
- **Resources are families.** A reader is data, an id and an offset,
  and the state it reads (an open file, a database cursor, a socket's
  buffers) lives in its service, reached by that id. So a service's
  open resources are a family keyed by id: its incarnation is the
  actor's, `Fs`'s cap on open files is `max:`, a reader whose resource
  was evicted or ended fails with a typed `Closed`, and the leftovers
  are closed by the family's end. There's no separate handle table and
  no close rule.
- **A generator may hold a `with` across a `yield`,** a transaction
  across rows, and the `with` ends with the generator, inside the
  consumer's scope. If the `with` installs a family, that family ends
  there too: a consumer's `break` drains or cancels it, as it would any
  `with` in the generator.

## The graph side: families

What [language.md §11](language.md#11-many-stateful-things-data-or-actors)
and decision 18 describe, with the post rules replaced by five:

1. **Calls own their work,** through the combinators above.
2. **`post` hands a call to a family, and waits only for room in its
   key's mailbox.** The bound is per key, `mailbox:` (default 64), so a
   slow key holds up only its own posters, and a family's mail is at
   most `max:` × `mailbox:`. The post returns once the call is queued,
   and queued mail runs unless the family is cancelled (rule 4).
   The posted operation can't fail, an ordinary type rule on `post`'s
   parameter: "`Doc.edit` can fail with `StoreDown`; handle it inside the
   operation, or call it with `Docs.at`". The post makes its actor, so
   setup's errors are the post's: `try Docs.post(k, Doc.Call.Edit { op })`.
3. **An `at` block holds its family. While it's held, you can't reach
   that family or one installed inside it.** Operations keep this rule
   by construction: a handler's `uses` resolve at its install, from the
   `with`s outside it, so an operation of F can only reach families
   installed outside F, and an actor naming its own family is the
   ordinary cycle in one `with` set. Only an `at` block, which runs the
   caller's code, needs a check. It's the one `at` inside `at` has today:
   Infer refuses it where the `with` is in sight, and the run time panics
   where a helper hid it.
4. **A family's `with` drains when its body returns.** Queued mail is
   delivered (and may post outward), then the actors' `finally`s run, in
   reverse creation order. Families end innermost first. **If the `with`
   is cancelled, cancellation goes down:** running operations are
   cancelled at their next dependency call, queued mail that hasn't
   started is dropped, and the `finally`s see `Err(Cancelled)`. A drain
   isn't shielded. A graceful shutdown is a body that returns when it's
   asked to; a drain with a limit is the whole `with` inside
   `Async.timeout`. Mail is not durable; the store is.
5. **A panic ends the program,** as everywhere (decision 8).

Order holds as before: posts from one task to one key run in the order
posted, each as one operation, on a task the family owns. The mailbox
belongs to the key, so order survives eviction, and an actor with mail
is never evicted.

```ren
dep Postings =
  changed: fn(doc: DocId, words: Set<Word>)
  has: fn(doc: DocId, word: Word) -> Bool

dep Doc =
  edit: fn(op: Op) -> Version ! StoreDown

handler doc(id: DocId) for Doc uses Store, Index =
  var text = try Store.load(id)              // runs when the actor is made
  edit(op) =>
    text = text.apply(op)
    try Store.save(id, text)                 // write-through
    try Index.post(shard_of(id), Postings.Call.Changed { doc: id, words: text.words() })
    text.version

dep Index = Actors<Shard, Postings> ! StoreDown
dep Docs = Actors<DocId, Doc> ! StoreDown

pub wiring live(url: Str) provides Docs uses Net ! StoreDown =
  pg_store(url), actors(postings, max: 64) as Index, actors(doc, max: 50_000) as Docs
```

`Index` is installed outside `Docs`, so a document's operation may post
to it. An index operation can't reach `Docs`: `postings` would need
`uses Docs`, and Docs isn't installed outside it. A block run with
`Index.at` can't reach `Docs` either: that's rule 3's check.

A test that wants posted work finished ends the family's `with`, which
drains, and then asserts. That's "returned means done", with no extra
operation for it:

```ren
test "an edit reaches the index" =
  with mem_store(), actors(postings, max: 4) as Index in
    with actors(doc, max: 4) as Docs in
      try Docs.at(d1) fn() => Doc.edit(insert("hello"))
    // the inner `with` has drained, so the post has run
    assert try Index.at(shard_of(d1)) fn() => Postings.has(d1, "hello")
```

## No deadlock, by one rule

Every wait in a family is outward: a post waits for room in an outer
family's key, an `at` waits for an outer family's slot, an operation
waits to take an outer actor. Families form a DAG by install order, so
the waits can't close a cycle. That's decision 10's inner-to-outer rule,
the one handlers already have, applied to families.

The rule replaces three of decision 18's:

- **The rule for waiting for a slot while pinning, and its `Full`
  error.** Under rule 3 it never fires: the model gives the same
  graphs, state for state, with it turned off.
- **"A delivery may go past `max:`."** Eager setup and "an actor with
  mail is never evicted" mean a key with mail always has a live actor,
  so a delivery never makes one.
- **The sibling post that never waits, the edge's meter, and the panic
  past twice `mailbox:`.** There are no sibling posts.

The weaker reading, "not F itself", deadlocks three ways, one through
each kind of wait, and one of them no error rule can fix
([MODEL.md](research/structured-actors/MODEL.md)).

## Several keys at once

An operation that spans two keys of one family, moving text between
documents or money between accounts, runs from outside the family.
`at_all` holds several keys for one block, so it's in v1:

```ren
Docs.at_all([from, to]) fn() =>
  let text = Docs.at(from) fn() => Doc.cut(range)
  Docs.at(to) fn() => Doc.insert(at, text)
```

- **It holds the keys in sorted order,** so two `at_all`s over the same
  keys can't wait on each other.
- **Inside it, `at` on a key it holds doesn't wait,** so it's allowed and
  names which actor the ambient `Doc` means. `at` on any other key of the
  family is rule 3's refusal. Keys are values, so "holds" is checked at
  run time, and a miss panics.

## Why there's no mail inside a family

Decision 18 let an actor post to its own family. That's Erlang's model,
and it's where every hard problem came from:

- Mail inside a family can form cycles, and a cycle in mail is
  recursion. An operation that posts twice around a cycle grows without
  end, so the first design needed a panic past twice the mailbox bound.
- That global cap panics under legitimate load. With 20,001 sessions
  that each pass the edge, then save, then post once, a correct program
  panics at std's default bound ([actor-origins
  MODEL.md](research/actor-origins/MODEL.md), step 1).
- Bounding it properly means charging every message to the outside call
  that caused it, with a budget per cause, termination detection, and an
  outbox to make the budget deterministic. That's
  [research/actor-origins/](research/actor-origins/), checked and
  measured: it works, its parts each have prior art (Ethereum's gas,
  Dijkstra–Scholten, X10's `finish`, TigerBeetle's admission), and it's
  a BEAM-sized runtime.

Rule 3 removes the cause instead of bounding it. What's given up is
actors of one family messaging each other: relays, gossip, ping-pong.
Separate concerns become separate families (`Docs` and `Index` above),
and a protocol that should run forever is a `while` loop in a task
beside the families, where it can be seen and cancelled. If a later Ren
wants mail inside a family, research/actor-origins/ is the checked
design to pick up.

## Many cores

**`per_core` is the default runtime** (decision 9). Each core runs its
own scheduler, and tasks don't move between cores.

- **A family's keys are spread over the cores; how is the runtime's
  choice.** Nothing a program sees depends on it: order is per key, and
  the eviction victim is the same however a family is split
  ([K1b](experiments/runtime-p2/SYNTHESIS.md)), so a journal from one
  thread replays on sixteen. `parts:` leaves `actors`. This reverses
  decision 18's "no home core".
- **A post goes to the key's home core.** A post is a `D.Call` value, so
  delivering it is one push to that core's queue, as Seastar's
  cross-core queues are. A post that makes its actor waits for the home
  core to run setup and answer.
- **Eviction is decided by the family and carried out at home.** One
  global `max:`; a full family evicts the oldest-used of a few sampled
  instances with no pin and no mail, and the victim's home core runs its
  `finally`. The post that needed the room waits for that answer. It
  can't close a cycle: the victim holds nothing and nothing waits on it.
- **`at` keeps its meaning; how it runs is the runtime's.** Its block is
  the caller's code, so either each operation is sent to the home core
  and answered, one round trip per operation, or the task moves to the
  home core for the block, two hops however many operations it makes.
  The runtime experiments decide, and the compiler can choose per block.
  Programs can help, as Seastar's do, by routing a connection to the
  core of the document it edits.

## What it replaces

In short, from [AUDIT.md](research/structured-actors/AUDIT.md):

| Where | What goes | What it becomes |
|---|---|---|
| async.md, decision 7 | `s.start`, the task handle, `s.replace` | anonymous scopes; `beside` and `background` are std |
| decision 9 | `work_stealing` as the default | `per_core` |
| decision 18, language.md §11 | sibling posts, the edge's meter, the panic past twice `mailbox:`, the high-water mark, the pin rule and `Full`, delivery past `max:`, `parts:`, exact LRU, "no home core" | rules 2 to 5; a per-key `mailbox:` of 64; `at_all` in v1; sampled eviction under one `max:`; home cores under `per_core`; a per-key queue depth in `sim` and debug builds |
| streams.md | "stepping one that was cancelled panics"; handle tables and close rules | ends once, for every computation; `merge`; resources as families |
| async.md's surface | `s.spawn` as how a program starts work | combinators over calls and streams; `scope` is std's layer; `Async.expand` for work that finds work |
| the interpreter | the family's meter, sibling path and 2× panic; `start` and `replace` | a per-key bound that every post waits on; rule 3 in Infer beside `at`'s check |
| test_services.ml s7 | the sibling-post tests | refusals, or rewritten across two families |

## What it isn't

- **Not Erlang.** No supervisors, no restart policies, no messages
  between actors of one family, no unbounded mailboxes. A panic is a bug,
  and it ends the program.
- **Not tasks as values.** No handle outlives its call, nothing spawns
  into a pool nobody owns, and a program writes combinators, not
  spawns.
- **Not a new kind of waiting.** `post` waits for room as a bounded
  channel's send does, and every wait points outward.

## Open questions

- **How does `at` run under `per_core`?** The runtime experiments.
- **`Async.expand`'s name and shape,** and whether it dedupes or leaves
  that to a `Seen` handler.

Settled while writing this: `mailbox:` keeps its name and defaults to
64 per key; the high-water report becomes a per-key queue depth in `sim`
and debug builds; `at_all` is in v1.

## Where it came from

- Yoshua Wuyts: [tree-structured concurrency](https://blog.yoshuawuyts.com/tree-structured-concurrency),
  [replacing background tasks with actors](https://blog.yoshuawuyts.com/replacing-tasks-with-actors),
  [tasks are the wrong abstraction](https://blog.yoshuawuyts.com/tasks-are-the-wrong-abstraction),
  [the missing future state](https://blog.yoshuawuyts.com/the-future-trait-has-a-missing-state),
  [streams concurrency](https://blog.yoshuawuyts.com/streams-concurrency).
- [research/actors-post/](research/actors-post/): the first model of
  `post`, and its four holes.
- [research/actor-origins/](research/actor-origins/): the prior-art
  landscape, and the origins design, checked: the road not taken.
- [experiments/origin-counters/](experiments/origin-counters/): what
  counting causes across cores costs.
- [research/structured-actors/](research/structured-actors/): the model
  of these rules, and the audit.
- Seastar's service groups ("nested calls must form a DAG"), the
  precedent for rule 3.

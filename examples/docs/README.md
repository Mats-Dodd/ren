# Docs

language.md §11's document server, the services stage's milestone
(compiler.md, "Services stage", step 8): each document is an actor, one
per key, made on demand from what the store holds and evicted under a
cap; a session is a connection that opens a document, joins it, sends
its edits and leaves. Its tests run under a thousand seeds with chaos
eviction, so nothing a document needs lives only in its actor.

```
ren test docs --seeds 1000    # its four tests, each under a thousand schedules, with chaos
ren run docs/main.ren         # serves on 127.0.0.1:8080, documents kept under docs/
```

| File | What's in it |
|---|---|
| `main.ren` | `Store`, `Conns` and `Doc`, the services; `doc(id)`, a document, made from the store, which saves each edit before it sends it; `Docs`, the family; `fs_store` and `net_conns`; the wirings `documents(max, chaos)` and `live(dir)`; a session's line protocol, `session` and `serve`; and the tests, over `mem_store`, `seen_conns` and `sim.net()` |

## What to look at

**A document is an actor.** `dep Docs = Actors<DocId, Doc> ! StoreDown`
says what making one fails with, its handler's setup, which loads its
text. `try Docs.at(DocId(name)) fn() => ...` runs a session's block with
that document's actor installed as `Doc`, making it if it isn't live;
each `Doc.edit(op)` inside takes the actor for one call. Past `max:`,
the least recently released actor is evicted, its `finally` run on the
caller's task.

**Every edit is written through.** `edit` saves the text before it sends
the line to the subscribers, so an evicted document made again has every
edit, and every subscriber sees the edits in the order the store has
them: "every subscriber sees one order of edits" compares each
subscriber's lines with the store's and with each other's.

**Chaos is a parameter.** The tests install `documents(2, true)`, the
family with `chaos: true`, which evicts, at each call into it, the
evictable actors `Random` picks from the seed's tape. A document that
kept its text only in memory would lose it under some seed:
`bench/services/memory` is that server, and a seed finds the loss and
replays it. A session that read the text with one operation and wrote
it with another would lose a concurrent edit: `bench/services/lost_update`
is that one, and `ren test --sim --seeds` finds it. bench/tasks.t runs
all three.

**The composition root is two wirings.** `documents(max, chaos)` is the
family over a `Store` and a `Conns` from outside; `live(dir)` is the
server's, a store of files, the network and `documents(50_000, false)`.
A test lists `documents(2, true)` beside `sim.net()`, `mem_store()` and
`seen_conns()`, the split language.md §5's "Tests" describes. `actors`
uses `Random`, for chaos, so the wirings name it.

**Two stand-ins,** for what other stages build: the protocol is lines,
not frames (the document's name on the first, `+text` for each edit,
then `bye`, answered `done N`), and an `Op` appends a line, where a real
editor would have an editing model.

It runs in the interpreter only: `ren build` refuses the family, as it
refuses tasks.

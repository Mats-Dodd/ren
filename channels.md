# Channels and actor handoff built on generators

**Status: proposed, 2026-10-30;** its obligations for the generators
stage, and `expand`'s frontier, are decided (briefs/stage-generators.md,
"From channels.md"), and its composition cases are in the runtime core's
conformance tests. Builds on [streams.md](streams.md),
[concurrency.md](concurrency.md), [async.md](async.md), and the
[generators stage](briefs/stage-generators.md). It adds communication
contracts and a validation plan; it does not supersede the decided
generator rules or expand that stage into a runtime rewrite.

Generators describe how values are produced. Scoped combinators introduce
concurrent production. Channels transfer values between tasks, and actor
families own accepted calls addressed to keyed state. These fit one
ownership model: calls own tasks, generator bindings own frames, and
families own posted calls.

The proposal is to keep this surface and make admission, cancellation,
completion, and cleanup agree beneath it. Ordinary generators remain
sequential. A queue appears at an explicit concurrency boundary.

## Existing foundations

These are already specified, not new features proposed here:

| Construct | Execution and ownership |
| --- | --- |
| `gen fn`, pipelines | Run on the consuming task; a generator frame belongs to its binding's scope. |
| `zip`, `chain` | Pull sources sequentially; introduce no producer task. |
| `Async.produce` | Owns a producer task and bounded queue for the duration of its consumer block. |
| `Async.merge` | Owns a producer per source, feeding one bounded queue. |
| `Async.each`, `Async.map` | Pull only when a worker slot is available. |
| `Events.items()` | A cursor whose step is the named dependency's `recv()`. |
| Family `post` | Waits for admission; the family owns the accepted call afterward. |

For example, the generator below needs neither a queue nor a task:

```ren
gen fn walk(t: Tree) -> Node =
  yield t.node
  for c in t.children
    yield from walk(c)
```

Demand comes from the consumer. Push lowering may fold production and
consumption into ordinary sequential code. `yield` is not a send, and
`yield from` is not a spawn.

Independent progress is explicit, using the existing specified form:

```ren
Async.produce(cap: 16, fn() => crawl(root)) fn(pages) =>
  for p in try pages
    try index(p)
```

`crawl` sends through the installed `Send<T>` dependency. The call owns
the producer and waits for it on exit. `cap:` permits bounded progress
ahead of the consumer.

## Public interfaces

Keep channels as named dependencies. The current interface is:

```ren
pub dep Chan<T> =
  send: fn(x: T)
  recv: fn() -> Option<T>
  close: fn()
```

`dep Events = Chan<Event>` gives communication an identity, and
`Events.items()` plugs it into ordinary cursor processing. There is no
second iterator protocol for channels. A channel's `items()` cursor does
not itself own the sending tasks.

For scoped combinators, expose only the capabilities participants need:
the producer gets `Send<T>`, the consumer gets its pull source, and the
combinator owns termination. `produce` already follows this pattern.
Do not add first-class endpoint handles or automatic endpoint reference
counting as a prerequisite for the generator stage.

The existing explicit `Chan.close()` remains available. Whether general
channels should later expose separate send, receive, and close
capabilities is an API question to settle after the shared contract is
modeled. This proposal does not change closed-send panic into a typed
error, or add zero-capacity rendezvous channels; both would be separate
surface changes.

## Ownership and stopping

The scope that installs a channel owns its state. The scopes that start
tasks own those tasks. Sharing a channel does not transfer task ownership.

```text
produce call
├── bounded queue
├── producer task
└── consumer body

consumer body exits
    → cancel remaining producer work
    → wait for producer cleanup
    → release remaining queue contents
    → return from the call
```

A loop over a general `Events.items()` cannot cancel arbitrary producers
when it stops: it does not own them. The surrounding application or
combinator must arrange their termination. A general channel's scope
must not wait indefinitely for an abandoned buffer to become empty.

Generator lifetime remains determined by its binding:

```ren
let lines = follow(path)
for line in try lines
  if line == "--- boot ---" then break
for line in try lines
  Console.print(line)
```

The first `break` leaves `lines` resumable. Abandonment at the binding's
scope end cancels its frame. A temporary generator closes at its
statement's end. Preserve the existing ends-once results and `finally`
ordering in both pushed and pulled execution.

Different owners require different completion rules:

| Event | Required behavior |
| --- | --- |
| Explicit channel close | Reject new sends under the existing API; let receivers drain buffered values, then return `None`. Wake blocked operations so they observe closure. |
| All producers in a combinator finish | End its source after accepted values have been consumed. Track producer completion explicitly. |
| Consumer block exits | Cancel and await tasks owned by that combinator; release unconsumed values. |
| Family body returns normally | Execute accepted calls, then finalize actors, following the existing family drain order. |
| Family is cancelled | Cancel running work, drop queued calls that have not started, and finalize. |

A mailbox has an executor; a generic channel may have no remaining
consumer. Consequently, family drain and channel teardown are not the
same operation. Queue emptiness also does not establish that an actor's
running operation has completed.

## Transfer and cancellation

Each send or post needs one admission commit point. Before it, the
operation has not transferred its payload. After it, the destination is
responsible for the accepted payload, including cleanup if it is never
processed. This is responsibility for that transfer, not a new unique
ownership rule for Ren values.

```text
waiting for admission
    ├── cancellation wins → no transfer
    └── admission commits → destination owns the accepted transfer
                               ├── consume or execute
                               └── discard during cancellation
```

Proposed contract: a communication operation reported as cancelled
before transfer must have no transfer effect. If admission commits first,
record it as committed; do not relabel it as an uncommitted cancellation.
A containing task can still be cancelled before its caller observes the
result. Cancellation of that task does not retract an accepted post.

The corresponding receive rule is that cancellation before the receive
commits consumes no item. If it commits and its task subsequently exits,
the task's cleanup owns the received value. This is essential for
selection and resource-bearing payloads.

These are proposed guarantees to verify against the interpreter and
native reply protocol. They do not authorize retrying external effects
on cancellation or imply exactly-once execution across crashes.

Keep the stages distinct:

```text
admitted → started → completed → externally committed
```

`post` establishes admission, not successful processing or durability.
The existing restriction on typed failures from posted operations stays.

## Errors and buffered values

Preserve `produce`'s specified behavior: deliver what its producer sent,
then report the producer's failure. A consumer failure instead cancels
the producer. Neither path may leave child tasks behind.

For `merge`, propose the same observable ordering: the first producer
failure recorded by the scheduler cancels sibling producers, preserves
already admitted values for consumption, then ends the source with that
failure. A sibling send racing cancellation is included only if it
commits. If the consumer exits first, abandon the remaining values and
await cleanup instead of forcing a drain.

This makes the merge policy explicit where the source documents need
reconciliation. Preserve the call's existing first-failure rule when
consumer failure races producer failure; scheduler order selects the
first failure and replay reproduces it.

Store terminal state separately from buffered data. Completion, failure,
and cancellation must not require inserting a sentinel into an already
full queue. In particular, teardown must not need the departed consumer
to make room for a terminal message.

## Actor integration and wait dependencies

When work is addressed to an actor, use its existing mailbox:

```ren
try Docs.post(id, Doc.Call.Edit { op })
```

Do not automatically insert a channel and forwarding task before every
actor. Introduce such a stage only when it performs useful work, such as
batching or transforming values. Keep per-key admission and the existing
outward family dependency rule.

There are three different structures to validate:

- The ownership tree determines cancellation, joining, and cleanup.
- The communication graph determines who can exchange values.
- The wait graph determines whose progress depends on whom.

A tree-shaped owner does not make arbitrary communication deadlock-free.
For example, this schematic dependency cycle must be investigated:

```text
actor A's operation waits for Q.recv()
producer waits for an operation on A before Q.send(value)
```

Installing Q outside A alone does not show that the producer can run.
Whether this cycle is expressible depends on family checks, handler-state
rules, and what an operation retains while suspended.

Preserve the generator specification's support for actors retaining data
readers. Do not introduce a blanket ban on actor reads, or silently
release actor serialization at every channel wait. Model the actual
semantics first, including helpers, `at` pins, `release`, and retained
resources. If a new effect restriction is necessary, specify it as a
separate language change with concrete accepted and rejected examples.

The existing [structured actor model](research/structured-actors/MODEL.md)
checks bounded scenarios and explicitly excludes cancellation and other
operations. Its results are not a proof of general channel composition.

## Selection and timed consumption

Preserve streams rule 7: a timed or raced source step must be one
operation. Cancelling an arbitrary generator step may end that generator;
a pipeline is not automatically safe to race.

`produce` and `merge` provide explicit task boundaries for generators
whose output needs independently timed consumption. The proposed queue
protocol should also support eventual selection:

```text
register receive and deadline alternatives
commit exactly one winner
withdraw losing registrations without consuming their items
```

Ordinary task racing does not establish that only one receive commits.
Model the commit protocol before adding public selection syntax. General
multi-channel selection and the deferred time operators are not required
to complete the current generator stage.

## Bounds and recursive work

Name each bound precisely. `cap:` bounds buffered values; `max:` bounds
concurrent worker slots; family `mailbox:` bounds queued calls per key.
None alone bounds all retained memory:

```text
retained payloads = buffered + executing + held by blocked senders
                    + pending replies + producer prefetch
```

Keep `each` and `map`'s pull-on-free-slot behavior. For merge, account for
each producer's in-flight value in addition to the shared buffer. FIFO
admission, per-source order, scheduling fairness, and completion order
are separate properties; do not promise a global source order for merge.

`expand` needs special treatment because workers discover more work.
Every worker must not be able to block trying to enqueue children while
only those workers can drain the queue. Completion means no running work
and no pending work, not a momentarily empty queue.

**Decided:** a worker's block returns its children as a value, and the
call appends them to its frontier, a stack, depth first. Appending isn't
a wait, so no worker blocks enqueueing children; it's done when nothing
runs and the frontier is empty; the frontier's memory is the arrays the
program returned, said plainly, with no `pending:` bound and nothing
dropped. What follows is the question that decision answers.

Before implementing `expand`, choose and document how pending children
are represented and admitted. Arbitrarily large returned child collections
cannot acquire a total memory bound merely from `max:`. The design must
either state that frontier storage is separately unbounded, introduce an
explicit bound with defined behavior, or use a traversal policy with
documented storage costs. Moving the frontier into suspended continuations
does not make its memory disappear. No silent dropping or unlimited
worker spawning is an acceptable escape from queue saturation.

## Runtime integration

Use the existing handler, scope, family, and `Async.until` machinery.
Channels remain standard-library abstractions; generators add no separate
scheduler. The native implementation uses the core's parking, wakeup,
cancellation, and reply rules when that core is available.

Distinguish the runtime's queues of `D.Call` envelopes from an application
channel's buffer of values. A runtime call may invoke a channel operation
that waits on the application buffer. They share lifecycle contracts, not
necessarily storage, capacity, or one literal queue implementation.

Expose sufficient scheduling events to reproduce admission, transfer,
terminal state, and cancellation outcomes under `sim` and replay. Do not
fix the exact journal record layout in this proposal. Real multicore
tests remain necessary for synchronization and memory-safety properties
that deterministic scheduling alone does not establish.

## Delivery and validation

The generators stage can proceed. Its immediate integration obligations
are narrow: preserve binding lifetimes, use existing queue interfaces,
join owned producers on exit, and settle `expand`'s saturation behavior.
Record any ambiguity in that stage's `compiler.md` progress section rather
than silently changing the decided source specifications.

The follow-on work is:

1. Model transfer, close, cancellation, and producer completion alongside
   family admission. Include actor/channel dependency cycles and state
   the bounds and excluded behaviors of the model.
2. Align interpreter queue behavior with the accepted contract. Resolve
   any differing error and cancellation behavior explicitly before
   changing public APIs.
3. Apply the same contract to native tasks and queues after the runtime
   core provides suspending frames. Preserve the generator brief's
   division between part one and part two.
4. Add selection and capability refinements only after their protocols
   have been modeled and tested.

Required composition cases:

| Scenario | Assertion |
| --- | --- |
| Consumer exits while producer is blocked on a full queue | Producer wakes for cancellation, cleanup finishes, and the call returns without a surviving task. |
| Cancellation races send or receive | Exactly one transfer outcome commits; no item is consumed twice or silently lost between owners. |
| Close races blocked senders and receivers | Every waiter observes a defined outcome; buffered values remain drainable. |
| Producer fails with buffered values | Accepted values precede the failure unless the consumer exits and abandons them. |
| One merge source fails while others are blocked | Siblings terminate; terminal state needs no queue capacity; the first failure is stable under replay. |
| Named generator is partially consumed | It resumes after `break` and finalizes at its binding's scope end. |
| Actor delivery posts outward during family drain | Inner-to-outer shutdown preserves the accepted outer work. |
| Actor waits on a channel whose producer needs that actor | Establish rejection or exhibit the wait cycle; do not count it as deadlock-free merely because owners form a tree. |
| Branching expand saturates all workers and pending storage | It progresses under its documented policy or reports an explicit limit, never silently deadlocks or drops children. |
| Competing receive alternatives become ready together | Future selection commits one receive and withdraws the others. |

Run applicable cases across simulation seeds and replay failing schedules.
Compare interpreter and native outcomes as each native feature becomes
available. Cleanup, failure ordering, and admission outcomes are part of
the observable contract, not implementation details.

## Prior art informing the proposal

- [Wuyts on replacing tasks with actors](https://blog.yoshuawuyts.com/replacing-tasks-with-actors/):
  an enclosing owner for work handed off by shorter-lived requests.
- [Ox actors](https://ox.softwaremill.com/latest/utils/actors.html):
  scoped actors and distinct waits for mailbox admission and results.
- [Trio channels](https://trio.readthedocs.io/en/stable/reference-core.html):
  precise channel cancellation and directional endpoint lifetime.
- [Concurrent ML](https://ecommons.cornell.edu/entities/publication/de1206e6-3dfb-48b9-99e2-f3146d25e507):
  composing synchronization alternatives before committing one.
- [Manifest Deadlock-Freedom for Shared Session Types](https://www.cs.cmu.edu/~balzers/publications/manifest_deadlock_freedom.pdf):
  synchronization dependencies must be considered alongside resource
  acquisition order. Its proof applies to its calculus, not directly to Ren.

The proposal adopts these lessons within Ren's existing generator,
dependency, and family model. It does not add supervision, durable
mailboxes, actor reentrancy, or a separate asynchronous stream system.

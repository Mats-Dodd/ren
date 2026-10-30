# FizzBee check of `post` (foundations.md decision 18)

**Verdict: `post` as written is not sound.** The claim that siblings can't
deadlock holds: a sibling post never waits, and that's exactly why. FIFO
holds, and eviction doesn't lose a queued post as long as the mailbox
belongs to the key and not to the actor. Four things fail:

1. **A deadlock that decision 18's "No deadlock" doesn't cover.** A task
   that pins an actor and then posts from outside can wait on the mailbox
   bound while its pin holds the slot the mailbox needs to drain.
2. **The edge doesn't bound memory.** An `at` block's operations post to
   siblings without waiting, and only `post` is metered at the edge. A
   long session alone fills the mailboxes without bound.
3. **A chain reaction is unbounded.** An operation that posts twice
   along a cycle doubles the in-family mail with every hop. No rule at
   the edge can stop that.
4. **A post whose actor can't be set up has no outcome.** The post can't
   fail, so the design has to drop it, retry it forever, or panic. All
   three are bad.

A small set of fixes makes every case pass, and the chain reaction then
ends in a panic instead of running out of memory. See
[Recommendations](#recommendations).

Spec: `post.fizz`. Reproduce with `run.sh`, which prints each result and a
condensed trace (`trace.py`).

## What the model is

- **The family.** `Docs = Actors<K, D>` with 2 or 3 keys, `max:` of 1 or 2
  (always fewer than the keys, so eviction happens), and `mailbox:` of 1
  or 2. A mailbox is a FIFO per key. Its total is what the bound counts.
- **Outside tasks** run small programs:
  - `Docs.post(k).op()`;
  - `Docs.at(k) fn() => ...`, with one call, a loop of calls (a session's
    `for op in conn.ops() => Doc.edit(op)`), or a `post` inside the block.
- **Deliveries.** There is one delivery task per key, owned by the
  family's `with`. It runs the head of k's mailbox as one operation,
  making the actor if it isn't live. Making an actor past `max:` evicts
  some evictable actor, chosen freely, which covers LRU and LFU. If none
  is evictable, the maker waits.
- **Holding** follows decision 10. Each operation takes its actor for one
  call, so deliveries and `at` callers interleave between calls. An `at`
  block pins its actor.
- **Operations** post to siblings as they run:
  - `ping` → `pong` → `nop`: a two-hop cycle;
  - `fan`: one post to every sibling;
  - `loop`: ping-pong forever, with one message in flight;
  - `double`: two posts to the next key, a chain reaction;
  - `notify`: an `at` operation that tells a sibling.
- **Chaos.** `CHAOS` evicts any evictable actor at any point, as
  `sim.scheduler(evict: AnyIdle)` does.
- **Setup failure.** Some keys' setup may fail, nondeterministically, or
  always (`SETUP_DOWN`).
- **Invariants and coverage.**
  - Deadlock detection is on.
  - `FifoPerPosterActor`: each (poster task, actor) pair's posts run in
    order, with none skipped.
  - `NoLostPost` and `EveryAcceptedPostRan`, checked when the family ends.
  - `OutsidePostsWithinBound`: outside posts queued are at most `mailbox`.
  - `Bounded`: everything queued is at most a ceiling.
  - `MaxRespected` and `NoPanic`.
  - Coverage: the family can end, and an actor with queued posts does
    get evicted.

## Results

| Run | Result |
|---|---|
| **Decision 18 as written** | |
| 2 keys, max 1: an outside ping-pong cycle, a post, and an `at` whose op notifies a sibling | PASS, 379 states |
| 3 keys, max 2, mailbox 2: fan-out from a delivery and from an `at` op, plus ping-pong | PASS, 17,759 states |
| The same with chaos eviction (an actor with queued posts is evicted, and a delivery makes it again) | PASS, 484 states |
| The same, with queued posts making an actor unevictable | PASS, 232 states |
| Siblings ping-pong while the outside fills the mailbox (the claimed no-deadlock case) | PASS, 1,682 states |
| A post inside `at` to a sibling that isn't live, with the family full | **FAIL, deadlock** |
| `double`, a chain reaction | **FAIL, Bounded** (grows without limit) |
| A session `at` loop whose op notifies a sibling | **FAIL, Bounded** (grows without limit) |
| `loop`, perpetual ping-pong | Bounded holds; **the family never ends** |
| Setup fails under a delivery, policy drop | **FAIL, NoLostPost** |
| Setup fails under a delivery, policy panic | **FAIL, NoPanic** (one failed load ends the program) |
| Setup down for good, policy retry | **The family never ends**, and outside posters starve |
| Teardown drops what is queued | **FAIL, EveryAcceptedPostRan** |
| **Alternatives decision 18 already rules out** | |
| The mailbox lives in the actor (eviction takes it) | FAIL, NoLostPost |
| Sibling posts wait at the bound: two actors ping-pong | FAIL, deadlock |
| Sibling posts wait at the bound: an actor posts to itself | FAIL, deadlock |
| **The proposed rules** (`FIX` in run.sh) | |
| The 2-key base, the 3-key fan-out, chaos, post inside `at`, the session loop, an actor full of its own mail | all PASS (839, 15,444, 1,086, 51, 539 and 127 states) |
| Setup fails for a post, from outside and from a sibling | PASS, 1,078 states (the error reaches the poster, and nothing is lost) |
| `loop`, perpetual ping-pong | the family never ends (expected: see Teardown) |
| `double`, a chain reaction | FAIL, NoPanic: it panics at `mailbox + headroom` instead of growing |

FIFO per (poster, actor) never failed in any run. It needs the two things
the model gives it: one delivery task per key, and a mailbox that outlives
the actor.

## Counterexamples, in Ren terms

**1. Posting while pinned: a deadlock.** `max:` is 1 here. At scale it
happens when every slot is pinned by a session that posts while the
mailbox is full.

```ren
// task 1
Docs.post(b).touch()             // the mailbox is now full; b isn't live
// task 2
try Docs.at(a) fn() =>           // pins a: the family is now full
  Docs.post(b).touch()           // a post from outside: waits for the mailbox
```

b's delivery has to make b, which needs a slot. The only slot is a, and
task 2 pins it. Task 2 waits for the mailbox, which waits for b's
delivery, which waits for task 2's slot. Decision 18 already forbids this
shape for slots: a pinning task gets `Full` instead of waiting. A
mailbox wait is a second edge that rule doesn't see.

**2. A session fills the mailbox (Bounded).**

```ren
handler doc(id: DocId) for Doc uses Docs =
  edit(op) => ...; Docs.post(index_of(id)).changed(id)  // a sibling post: never waits
try Docs.at(id) fn() =>
  for op in conn.ops() => Doc.edit(op)                  // not metered at the edge
```

Each `edit` is an operation called from outside, and each queues one post
that never waits. The edge meters only `post`, so one fast client grows
the index's mailbox without limit. "In-family posts are caused by outside
work" is true, but `at` is outside work the edge doesn't count.

**3. A chain reaction (Bounded).** `double(x) => Docs.post(next).double(x);
Docs.post(next).double(x)`. One outside post gives 1, 2, 4, ... queued
posts, and none of them waits. The run.sh trace passes the ceiling of 6 within six deliveries.
Fan-out of 1 around a cycle (`loop`) stays at one message, but never
stops.

**4. Setup under a post.** A post to a key that isn't live is made by
its delivery, and `doc`'s setup is `try Store.load(id)`. If the store is
down there's nobody to give `StoreDown` to:

- **drop** loses an accepted post;
- **panic** ends the program over a store outage, which decision 8
  reserves for bugs;
- **retry** keeps the post queued forever while the store is down, so the
  family can't end, and outside posters starve once the bound is reached.

This is a design hole.

**5. Waiting sibling posts (why "never waits" is right).** A's operation
waits to post to B while holding A. The queue is full of posts for A, and
only A's delivery can drain them. It also happens with one actor posting
to itself. This confirms decision 18's rule.

## Teardown: drain

Decision 18 says posts run "on a task the family's `with` owns". Decision
7 says a scope waits for its tasks, and the journal records posts as
data. Together they imply **drain**: when the body returns, queued posts
run (and may post more), and then the `finally`s run in reverse creation
order. Dropping them makes "accepted" meaningless, and the model shows
it (EveryAcceptedPostRan). The cost is that a perpetual cycle (`loop`)
keeps the family from ending, as a task that never returns keeps its
scope open. `sim` should report it at the end ("family end waiting on
mail: `docs[3]` ⇄ `docs[4]`").

## Recommendations

Each is the smallest rule that closes its hole. The model checks all of
them together (`FIX`).

1. **An actor made for a post may go past `max:`, as long as nothing is
   evictable** (`DELIVERY_OVER_MAX`). This closes deadlock 1, and the
   mailbox wait never depends on a slot. The excess is bounded by the
   keys that have queued posts, so the family holds at most
   `max + mailbox + headroom` actors. The alternative is a post from a
   pinning task that doesn't wait, but that reopens hole 2.
2. **The edge meters every call that comes in from outside, not just
   `post`** (`AT_METER`). An operation called through `at` from outside
   waits before it takes the actor while the family is over `mailbox`,
   exactly as an outside post does. It only holds a pin while it waits,
   which rule 1 makes safe. The compiler can limit this to operations
   that post. Outside-caused mail is then at most `mailbox`, plus at most
   one operation's posts per live actor, since each actor runs one
   operation at a time.
3. **Past a hard cap, a sibling post panics** (`SIB="panic_over"`,
   `mailbox + headroom`; suggested default: 2 × `mailbox`). Mail between
   siblings is recursion, and a chain reaction is unbounded recursion, so
   it ends like a stack overflow, with the high-water mark that debug
   builds and `sim` already report. Waiting deadlocks (counterexample 5),
   dropping loses posts, and a post can't fail, so a panic is the only
   bound left. A static alternative is to reject cycles in the family's
   op→posted-op graph. It also rejects `loop` and relays with a hop
   count, so it isn't proposed.
4. **`post` makes its actor, as `at` does** (`EAGER`). Setup's errors
   become `post`'s, `try Docs.post(k).edit(op)`, when the family declares
   them. They are the only errors a post can have, and a sibling's post
   handles them in the operation that posts. Queued posts count as
   waiting for the actor (decision 18 already lists "waited for"), so an
   actor with mail is never evicted, and a delivery never runs setup.
   This closes hole 4 and stops the remake churn the chaos runs show. A
   post still holds nothing.
5. **Teardown drains** (above). Write it next to "Teardown runs the
   actors' `finally`s".
6. **Scope "No deadlock" to say which waits it covers:** slots, plus the
   mailbox once rule 1 is in. Write down that sibling posts never waiting
   is what makes cycles safe.

## Limits

- Two or three keys, one or two outside tasks, and bounds of 1 or 2.
- Setup is instant (its waiters aren't modelled).
- Victims are chosen freely, which over-approximates LRU.
- Sequence numbers are mod 4, and the FIFO check requires the exact next
  number, so a skipped post would also be caught.
- Liveness isn't checked with fairness. "The family never ends" is the
  `FamilyEnds` reachability check failing, and "starve" is read from the
  stuck states.
- Partitions (`parts:`), many cores and `Docs.each` aren't modelled.
  Cross-family posts aren't either: an actor can only post to its own
  family.

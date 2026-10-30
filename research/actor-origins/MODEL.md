# FizzBee check of origins (an alternative to decision 18's mailbox meter)

(The outbox and split-fuel proposal is checked in the last section,
[Outbox and split fuel](#outbox-and-split-fuel).)

**Verdict.**

- **The suspected bug is real.** Under the adopted rules (actors-post's
  `FIX`), more concurrent `at` sessions than `mailbox:` panic the program
  with no runaway cause. Three sessions with `mailbox: 1` are enough.
  Each passes the edge gate while mail is 0, suspends in `Store.save`,
  and then posts once to a sibling. The third post finds 2 = 2 × `mailbox`
  queued and panics. At std's default (`mailbox: 10_000`), 20,001
  sessions that pass the gate together do the same. That's the 25k-sessions case.
- **Origins pass everything they were asked to pass.** That covers the
  load case, every actors-post scenario, chaos eviction, both nesting
  cases and `settled()`. `double` and `loop` end in a fuel panic instead
  of growing without bound or keeping the family from ending.
  OriginRefcountExact, SettledSound and the mail bound hold everywhere.
  So do FIFO, NoLostPost, EveryAcceptedPostRan and MaxRespected. Deadlock
  detection finds nothing. With fairness, the liveness runs show that
  every terminating program ends its family and that every `settled()`
  returns.
- **No new hole in the agreed design.** Two things to write down:
  - The one alternative tried, a sibling post that opens its own origin
    (LANDSCAPE §9 Q3's "this post starts a new origin"), deadlocks at
    once. Carrying the sender's origin isn't a convenience. It's what
    keeps the interior from waiting.
  - Fuel counts every hop, so a legitimate chain longer than F panics.
    That's sizing, not soundness, but `ping → pong → nop` already needs
    F ≥ 2.
- **The bound is tighter than the one asked for.** Fuel is charged when
  a post is made, not when its operation starts. So an origin's queued
  mail is at most max(1, F), and the family's mail is at most
  INFLIGHT · max(1, F). The "+ live actors × one op's posts" slack that
  the old meter needed is gone.

Spec: `origins.fizz` (a copy of `actors-post/post.fizz` with origins
added; the old modes are still there). Reproduce with `run.sh`. It prints
each result with the expected result in brackets, and a condensed trace
for failures (`trace.py`).

## What the model is

Everything in actors-post/README.md's "What the model is" still holds:
2 to 4 keys, one delivery task per key, `max:`, the per-key mailbox,
eviction chosen freely, chaos, setup failure, and outside tasks running
`post`, `at`, `call`, `calls` and `end`. This model adds:

- **`ORIGINS=True`** replaces the mailbox meter and the headroom panic.
  `EAGER` and `DELIVERY_OVER_MAX` from the FIX stay on. Teardown drains,
  as before.
- **Origins** are slots `0..INFLIGHT-1`, each `{owner, rc, used}`. A slot
  is reused once its origin closes.
  - An outside `post` opens one when its message is queued (rc = 1).
  - An outside `call` of an op that can post opens one when it takes
    the actor (rc = 1, held by the running op). A `nop` call opens none
    and doesn't wait.
  - Both wait, as a `require`, for a free slot. They wait in the same
    atomic step that takes the actor or queues the message, so nothing
    else waits for a slot.
  - A sibling post carries its sender's origin. It never waits: rc += 1
    and used += 1. Delivery hands the message's reference to the
    operation that runs it. When an operation returns, rc -= 1, after
    the posts it made were counted. At rc = 0 the origin closes.
  - The post that would make `used` exceed `FUEL` panics, naming the
    origin.
- **An I/O step.** `edit` is `[io Store.save, post next nop]`. The op
  suspends between taking the actor, which is where the edge gate is
  checked, and its post. (The actors-post model already let other tasks
  run between those two steps; the explicit step makes Step 1 read like
  the real handler.)
- **`settled()`** is a program step. It is implemented on the refcount:
  it waits until no open origin has this task as owner. Every message and
  running op also records its root task, independently of the refcount.
  When `settled()` returns, the model checks against that ground truth
  that nothing this task caused is still queued or running.
- **`SIB_ORIGIN="new"`**, the alternative: a sibling post opens a fresh
  origin and waits at the edge for a slot.

### Invariants and coverage

| Property | Kind | Meaning |
|---|---|---|
| FifoPerPosterActor, NoLostPost, EveryAcceptedPostRan, MaxRespected, NoPanic, EagerKeepsMailedActorsLive | always | as in actors-post |
| OutsidePostsWithinBound | always | queued outside posts ≤ INFLIGHT (≤ `mailbox` in the old modes) |
| Bounded | always | origins: mail ≤ INFLIGHT·F + live actors × most posts one op makes; old modes: ≤ CEIL |
| OriginMailWithinFuel | always | the tighter bound: each origin's queued mail ≤ max(1, F) |
| OriginRefcountExact | always | rc = the origin's queued mail + its running ops, and no mail or op carries a closed origin |
| SettledSound | always | when `settled()` returns, nothing its caller caused is queued or running |
| deadlock detection | always | on in every run |
| FamilyEnds, SiblingPostSetupFails, SettledWaitsOnQueuedMail, SettledReturns, PinnedPosterWaitsFullFamily | exists | coverage: the run reaches the interesting state (each is switched on by a `COVER_*` knob where it applies) |
| FamilyEventuallyEnds, SettledEventuallyReturns | eventually always | liveness under weak fairness of Outside, Deliver, Teardown and Finallys (run.sh's `live` runs) |

**Checking the checker.** Three mutants run in scratch, each against a
small program. All were caught:

- `settled()` not waiting: SettledSound fails.
- A sibling post without rc += 1: OriginRefcountExact fails.
- No fuel check on `double`: OriginMailWithinFuel fails.

## Results

Sizes: `max:` 1 or 2 (3 for the load case), 2 to 4 keys, 1 to 3 outside
tasks, INFLIGHT 1 to 3, FUEL 1 or 2 (default INFLIGHT=1, FUEL=2). State
counts are unique states.

| Scenario | Adopted rules (FIX) | Origins |
|---|---|---|
| **Load** (step 1): 3 sessions on keys 0 to 2, each `edit` saves and then posts once | **FAIL, NoPanic** (mailbox 1, headroom 1) | PASS: 1,795 (INFLIGHT 1, F 1); 33,600 (INFLIGHT 3, F 1) |
| BASE: ping-pong, a post, an `at` op that notifies | PASS, 839 | PASS, 171; INFLIGHT 2: 1,337 |
| FAN3: 3 keys, fan-out from a delivery and from an `at` op | PASS, 15,444 | PASS (INFLIGHT 2), 10,171 |
| BASE with chaos eviction | PASS, 1,086 | PASS, 292 |
| FAN3 with chaos eviction | (not run) | PASS, 1,586 |
| PINPOST: post inside `at`, family full | PASS, 51 | PASS, 40 |
| SESSION: an `at` loop whose op notifies | PASS, 539 | PASS, 279; INFLIGHT 2: 1,248 |
| SELFFULL: an actor full of its own mail | PASS, 127 | PASS, 29 |
| PINGPONG: two cycles, `max: 2` | PASS, 1,682 | PASS (INFLIGHT 2), 647 |
| FAILKEY: setup fails for an outside post | PASS, 44 | PASS, 23 |
| FAILSIB: setup fails for an outside and a sibling post | PASS, 1,078 | PASS (INFLIGHT 2), 1,939 |
| CHAIN `double` | FAIL, NoPanic at `mailbox + headroom` | **FAIL, NoPanic: origin out of fuel** (expected) after 2 posts |
| PERPETUAL `loop` | the family never ends (FamilyEnds unreachable) | **FAIL, NoPanic: origin out of fuel** (expected) on hop F + 1 |
| NEST1: a pinning task posts from outside; family full, the only slot taken | PASS, 277 | PASS, 153 (the state is reached) |
| NEST2: two pinning tasks, 3 keys, `max: 2`, each calling and posting | (not run) | PASS, 845 (the state is reached) |
| SETTLED: `post ping; settled()` | n/a | PASS, 23: waits while `pong` is queued, then returns |
| SETTLED2: `settled()` after a post, and inside an `at` block after a call | n/a | PASS, 484 |
| Liveness, terminating programs (BASE, NEST2, SETTLED2, Load) | n/a | PASS, IsLive |
| PINGPONG with F = 1 | n/a | FAIL, NoPanic (sizing: the chain is 2 hops) |
| Sibling post opens a new origin (`SIB_ORIGIN="new"`) | n/a | **FAIL, deadlock** |

FIFO per (poster, actor), NoLostPost and EveryAcceptedPostRan never fail
in either mode.

## Counterexamples, in Ren terms

**1. Legitimate load panics under the adopted rules (step 1).**
`mailbox: 1`, so the cap is 2.

```ren
handler doc(id: DocId) for Doc uses Store, Docs =
  edit(op) =>
    try Store.save(id, op)                                   // suspends
    Docs.post(next(id), Doc.Call.Changed { id })             // sibling post: never waits
// three connections, on docs 0, 1 and 2
try Docs.at(id) fn() => Doc.edit(op)
```

```
T0 calls edit on 0          mail 0 < mailbox: passes the gate
T0 does Store.save
T1 calls edit on 1          mail 0: passes
T1 does Store.save
T2 calls edit on 2          mail 0: passes
T0 posts to 1               mail 1
T1 posts to 2               mail 2
T2 posts to 3               mail 2 = 2 x mailbox: PANIC
```

The gate checks mail *now*. Every operation that passes it can add mail
*later*. The rule's own bound is "mailbox, plus one operation's posts per
live actor", and the live actors here are the sessions' pinned docs. It
assumes the cap is above that, but the cap is 2 × `mailbox` and the live
actors can number up to `max:`. With `max: 50_000` and `mailbox: 10_000`,
20,001 edits that pass the gate while mail is low and are in `Store.save`
together panic the program. Nothing is wrong with the program.

**2. Origins: the same load.** With INFLIGHT=1 the second and third
`edit` calls wait at the edge until the first edit's post has been
delivered. With INFLIGHT=3 all three run, and each origin spends one
unit of fuel. In both, mail ≤ INFLIGHT, with no panic. The knob that
admits work, INFLIGHT, is the same one that bounds it, so admitting
more load can't make the bound unsound.

**3. `double` and `loop` panic on fuel.** F = 2.

```
T0 post(0).double           origin 0 opens, rc 1
D0 runs double, posts double to 1 twice     used 2, rc 3
D1 runs double, posts double to 0           used would be 3: PANIC origin 0 out of fuel
```

`loop` panics on its third hop. Under the adopted rules `loop` kept the
family open forever. With origins it ends in a panic that names one
origin. That is the stated design ("only the edge starts a cause"), and
it is the Lambda and Cloudflare choice, with the same cost: a deliberate
relay or heartbeat inside one family has to be restarted from outside.

**4. The rejected alternative: a sibling post opens its own origin.**

```ren
ping() => Docs.post(next(self()), Doc.Call.Pong {})   // with SIB_ORIGIN="new"
```

```
T0 post(0).ping             origin 0 opens: the only slot
D0 runs ping                holds origin 0 until it returns
D0 posts pong               needs a new origin: waits for a slot. DEADLOCK
```

This is actors-post's counterexample 5 (waiting sibling posts) in
origin form. Any rule that lets the interior open origins has to make
that open never wait, and then the interior can start causes without
bound again. So a "fresh origin" escape hatch for perpetual protocols
can't come from inside the family. It has to come from a task outside,
for example a ticker that posts each round from `Async.beside`.

## Questions the model answers (from LANDSCAPE §9)

- **Q1, the unit.** One origin per outside call: a post, or one op of an
  `at` block. This model-checks clean. A session's `at` block holds no
  origin between calls, so it doesn't pin a slot and `settled()` can't be
  kept open by the session itself.
- **Q6, nesting.** A task that pins an actor and then waits for an
  origin slot can't deadlock (NEST1, NEST2), for two reasons. Everything
  that holds a slot is mail or a running op, and neither waits: mail goes
  past `max:` (`DELIVERY_OVER_MAX`) and runs on a pinned actor between
  its calls. And an op that holds an origin never makes an outside call
  to its own family. So origin slots need no inner-to-outer rule inside
  one family. The rule still matters across families (not modelled).
- **Q11, teardown.** "Wait for every open origin" and "drain" coincide.
  OriginRefcountExact makes "no open origin" equivalent to "no mail and
  no running op from outside", and Finallys checks both.
- **Q13.** Yes: at these sizes the model shows no panic under INFLIGHT·F
  with legitimate fan-out (FAN3, PINGPONG, Load), and a panic under
  `double` and `loop`.

## Limits

- Small sizes: 2 to 4 keys, 1 to 3 outside tasks, `max:` 1 to 3,
  INFLIGHT 1 to 3, F 1 or 2. Sequence numbers are mod 4 (as in
  actors-post).
- **Cross-family posts aren't modelled.** An actor posts only to its own
  family. A post into another family would open an origin at that
  family's edge and wait for it while holding the sender's actor and
  origin. That's safe only if families form a DAG by install order
  (decision 10), which this model can't check.
- **State-mediated causality isn't modelled.** An op's posts are a fixed
  function of the op, never of state that other origins left behind.
  Charging the running origin keeps the bound sound in that case too,
  since every post is charged to some open origin. But diagnosis would
  name the wrong cause, and fuel can run out on an origin that "did
  nothing" (LANDSCAPE §7, pitfall 3).
- Slots are canonical (the smallest free one). Ids carry no meaning, and
  INFLIGHT bounds open origins, not origins ever made.
- Liveness uses weak fairness per action, not per task, and is checked
  only for terminating programs. A `calls` session loops forever by
  design. Starvation of one outside task at a busy edge isn't checked.
- The cost of the refcount on many cores (Q8), cancellation of a
  poster's scope, setup waiters, `parts:`, `Docs.each` and per-origin
  timeouts aren't modelled.
- `settled()` is checked for the caller's own origins only. The model
  doesn't ask whether their effects are visible (Q10).

---

# Outbox and split fuel

The proposal: an operation's posts are buffered and leave together, in the
order made, when the operation ends (on return, failure or cancellation).
Fuel is split. An outside origin's first delivery carries F. An op that ends
with fuel r and k outbox posts panics if k > r. Otherwise each post is
charged 1 and r − k is divided among the k posts, remainder to the earliest.
Optionally, close is detected by credit (weight-throwing) instead of the
refcount. Everything else is as in origins.

**Verdict.**

- **Sound, and it does what was asked.** Every origins scenario gives the
  same verdict under `OUTBOX=True, FUEL_MODE="split"`. That covers the load
  case, BASE, FAN3, PINPOST, SESSION, SELFFULL, PINGPONG, FAILKEY, FAILSIB,
  chaos, NEST1, NEST2, SETTLED and SETTLED2. CHAIN `double` and PERPETUAL
  `loop` end in a fuel panic, and liveness holds for terminating programs.
  FIFO per (poster, actor), NoLostPost, OriginRefcountExact, SettledSound
  and the new AllMadePostsDelivered never fail.
- **A relay pays 1 per hop.** A relay of L hops passes when L ≤ F and
  panics when L > F. It panics at the same op in every interleaving, even
  with another origin running alongside. That holds whether the panic is
  raised when the op ends or at its (r+1)th post. The two-branch tree
  `split2` also panics at one fixed op under split fuel. Under pooled fuel
  the same tree panics on whichever branch posts second-to-last, which
  depends on the schedule. So split is deterministic and pooled is not,
  and the model checks both claims.
- **The bound holds and is tight.** In-family mail is at most INFLIGHT·F
  in every run, and FAN3 reaches exactly INFLIGHT·F = 4.
- **Cancellation and failure mid-op lose nothing.** An `at` caller is
  cancelled in `Store.save` with a post already in its outbox, or an op
  fails after posting. In both cases the outbox leaves, and each post is
  delivered exactly once, in order.
- **Credit close is exact.** Credit closes an origin exactly when the
  refcount reaches 0, plus the time to deliver the weight returns already
  sent. Weight is conserved, and a total weight of W = F never underflows.
  That checks origin-counters' claim that "the product of fan-outs ≤ F"
  for end-of-op splitting at these sizes.
- **New hole: the outbox can be observed, by waiting.** An op that posts
  and then waits, through anything outside the family, for an effect of
  that post deadlocks. Under eager send it completes. No *safety* result
  is new: an outbox run is an eager run in which delivery happens to be
  slow. What changes is *progress*. A sibling post now behaves like a
  self-post until its op ends.
  - **Smallest fix (checked):** the outbox also leaves at every suspension
    point (`FLUSH="suspend"`), with the op's continuation counted as one
    more party in the split. Everything above still passes with it, and so
    does the waiting op.
  - **Cost of the fix:** an op that posts and then suspends gives part of
    its fuel away early. `save2` (post, save, post) needs F = 3 instead of
    2. An op that posts once per I/O round halves its fuel each round,
    which brings back origin-counters' W5 problem for ops of that shape.
    The weight bound also grows from W = F to 2^F.
  - **My read:** keep the end-of-op flush and state the rule: "an op's posts
    leave when it ends; an op that waits for an effect of its own post
    deadlocks, as it would for a post to itself." Take the fix only if
    flottning has an op that posts and then polls for the result.

Reproduce with `run.sh`, which takes about 30 minutes in all. The new sections start at "outbox + split fuel".
Each result is printed with its expected result in brackets.

## What the model adds

| Knob | Values | Meaning |
|---|---|---|
| `OUTBOX` | False / True | An op's posts go to an outbox and leave when it ends. Each post gets its sequence number when it is made, so FIFO checks the order they were made in. Setup's error (`EAGER`) still comes back at the post. An actor that an outbox targets can't be evicted, just as one with queued mail can't. |
| `FUEL_MODE` | pooled / split | split: messages and running ops carry fuel; the arithmetic above |
| `SPLIT_PANIC` | end / post | split: panic when the op ends (as proposed), or at its (r+1)th post |
| `CLOSE` | refcount / credit | credit: each origin starts with W = `WEIGHT` (0 means F) at its first delivery or op. When an op ends with k > 0 posts, it splits its weight among them, remainder to the earliest. An op that ends with no posts sends a return to the origin's home. Returns are in flight (`Ctrl`, any order) until delivered, and the origin closes when all W is back. The refcount is kept as a ghost. |
| `FLUSH` | end / suspend | suspend (the fix): the outbox also leaves at each `io` step, and the continuation is the last party in the split |
| `CANCEL` | | An `at` caller can be cancelled while its op is in `io`. The op ends there, its outbox leaves, the task unpins, and the rest of its program is skipped. |
| ops | `h0`–`h6`, `split2`, `two`, `save2`, `savefail`, `mark`, `await` | `hN` is an N-hop relay. `split2` is two 1-hop branches. `savefail` is post, save, fail. `await` posts `mark` to the next key, then polls an outside store until that key has marked it. |
| `PANIC_AT` | [root, depth, key, op] | NoPanic becomes "any panic is at this op". PanicIsInevitable says no run ends the family, and PanicReached says the panic happens |
| `MUTANT` | order / split / credit / cancel_drop | checks that the checker catches each break |

New properties: InFamilyMailWithinBound (in-family mail ≤ INFLIGHT·F),
FuelConserved (an origin's posts so far, plus the fuel its mail and running
ops carry, ≤ F), CreditConserved, CreditClosesWithRefcount (an open origin
whose refcount is 0 has a return in flight), WeightNeverUnderflows,
AllMadePostsDelivered (at the end, every sequence number given out was
delivered), and the coverage checks BoundReached, CancelledWithOutbox and
FailedWithOutbox.

## Results

Unique states. "Pooled" is the origins column above, with eager send and
pooled fuel. Every row passes or fails as expected in all four new
columns.

| Scenario | Pooled | Split + outbox | + credit close | + fix (`FLUSH=suspend`) | fix + credit |
|---|---|---|---|---|---|
| Load, INFLIGHT 1, F 1 | 1,795 | 1,370 | 1,713 | 1,370 | 1,713 |
| Load, INFLIGHT 3, F 1 | 33,600 | 19,246 | 53,745 | 19,246 | 53,745 |
| BASE | 171 | 109 | 132 | 109 | 132 |
| BASE, INFLIGHT 2 | 1,337 | 887 | 1,453 | 887 | 1,453 |
| FAN3, INFLIGHT 2 (reaches INFLIGHT·F) | 10,171 | 4,717 | 11,516 | 4,717 | 11,516 |
| BASE, chaos | 292 | 210 | 306 | 210 | 306 |
| FAN3, chaos | 1,586 | 949 | 1,885 | 949 | 1,885 |
| PINPOST | 40 | 40 | 57 | 40 | 57 |
| SESSION | 279 | 247 | 342 | 247 | 342 |
| SESSION, INFLIGHT 2 | 1,248 | 1,119 | 2,287 | 1,119 | 2,287 |
| SELFFULL | 29 | 19 | 23 | 19 | 23 |
| PINGPONG, INFLIGHT 2 | 647 | 409 | 622 | 409 | 622 |
| FAILKEY | 23 | 23 | 30 | 23 | 30 |
| FAILSIB, INFLIGHT 2 | 1,939 | 1,411 | 2,942 | 1,411 | 2,942 |
| CHAIN `double` | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** |
| PERPETUAL `loop` | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** |
| NEST1 | 153 | 88 | 104 | 88 | 104 |
| NEST2 | 845 | 405 | 475 | 405 | 475 |
| SETTLED | 23 | 13 | 14 | 13 | 14 |
| SETTLED2 | 484 | 306 | 421 | 306 | 421 |
| PINGPONG, F 1 | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** |
| relay h3, F 3 (L = F) | — | 37 | 40 | 37 | 40 |
| relay h4, F 3 (L > F) | — | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** | **FAIL, fuel** |
| RELAYDET: h3 at F 2 beside another origin, one panic site | — | 1,151 | 1,433 | 1,151 | 1,433 |
| TREE: `split2` at F 3, one panic site | **FAIL**: the site varies | 813 | 1,128 | 813 | 1,128 |
| CANCEL mid-op, outbox non-empty (under the fix it already left at the I/O) | PASS, 40 | 32 | 42 | 32 | 69 |
| op FAILS mid-op, outbox non-empty (likewise) | PASS, 526 | 297 | 451 | 411 | 2,764 |

The FAIL rows fail on NoPanic with "origin out of fuel" in every column.
PINGPONG at F = 1 is sizing again, since ping → pong → nop needs 2 hops.
The liveness runs also pass under split + outbox (BASE, NEST2, SETTLED2,
Load), and under credit (SETTLED2, FAN3).

- **The outbox shrinks the state space.** Split + outbox explores fewer
  states than pooled, for example 109 against 171 for BASE. An op's posts
  become one step instead of k.
- **The fix costs nothing where nothing posts before a suspension.** Its
  columns match the proposal's state for state on every shared scenario,
  because no op in them posts before its I/O.

Contrasts and probes:

| Check | Pooled (eager send) | Split + outbox | Fix |
|---|---|---|---|
| `split2` tree, F = 3: one fixed panic site | **FAIL**: the site depends on the schedule | PASS, 813 | PASS, 813 (credit 1,128) |
| Cancelled in `Store.save` with a post in the outbox | PASS, 40 | PASS, 32 (credit 42) | PASS, 32 (credit 69): the outbox left at the save |
| Op fails after posting | PASS, 526 | PASS, 297 (credit 451) | PASS, 411 (credit 2,764) |
| `await` posted from outside | PASS, 53 | **FAIL, deadlock** | PASS, 38 (credit 59) |
| `await` called through `at` | PASS, 69 | **FAIL, deadlock** | PASS, 57 (credit 102) |
| `save2` at F = 2 | — | PASS, 31 | **FAIL, NoPanic**: the post before the save took the fuel |
| `await` at F = 1, credit with W = F | — | — | **FAIL, WeightNeverUnderflows**; W = 2 passes |

Mutants. Each runs in run.sh and each is caught:

| Mutant | Caught by |
|---|---|
| The outbox leaves backwards | FifoPerPosterActor: `two`'s second post is delivered first |
| No charge of 1 per post: children share all of r | FuelConserved, on `ping`'s first hop (used 1 + carried 2 > F = 2) |
| Credit weight copied to each child instead of split | CreditConserved. With that check off, OriginRefcountExact: the origin closes while `two`'s second `nop` is queued |
| A cancelled op's outbox is dropped | AllMadePostsDelivered |

## Counterexamples, in Ren terms

**1. The deadlock the outbox adds.** It needs an op that waits, through
something outside the family, for an effect of its own post.

```ren
handler doc(id: DocId) for Doc uses Store, Docs =
  publish() =>
    Docs.post(next(id), Doc.Call.Mark {})       // buffered in the outbox
    loop                                          // waits for the sibling's effect
      if try Store.get(marked(next(id))) then break
// the sibling
  mark() => try Store.put(marked(id), true)
```

```
D0 runs publish             posts mark to 1: into the outbox, not to 1
D0 polls Store.get          not marked. The poll suspends, and the outbox stays
...                         forever: mark is only sent when publish ends
```

Under eager send, `mark` is queued at once, D1 runs it, and the poll sees
it. Under the fix, the outbox leaves at the first `Store.get`. Nothing
else in the language can see the difference:

- An actor can't `at` its own family.
- `settled()` returns only after the origin closes, and that is after the
  op ends in every mode. Called inside an op, it waits on that op's own
  reference, so it deadlocks either way.
- `Docs.each` and tests call ops through `at` and see actors only between
  ops. To learn "B has the mail but A's op hasn't ended", a task has to
  hear from A mid-op through some medium. That is this counterexample
  with the waiting moved to another task: it can only *wait* for
  something the outbox withholds, never see a result that eager send
  couldn't produce.
- Latency is still visible. A post leaves when its op ends, not when it
  was made.

**2. Pooled fuel isn't replayable; split is.** F = 3, keys 0 to 2.

```
T0 post(0).split2           origin 0
D0 split2 posts h1 to 1 and to 2          used 2
D1 h1 posts h0 / D2 h1 posts h0           pooled: whichever posts second is the 4th post and panics
```

Under split fuel, `split2` ends with r = 3 and k = 2. Branch 1 gets 1 + 1
and branch 2 gets 1 + 0. So branch 2's `h1` panics, branch 1's never does,
and that is the same in every interleaving.

**3. The fix's price.** `save2` posts, saves, and posts again, at F = 2. At
the save, the outbox (1 post) leaves. The remaining 1 is split between the
post and the continuation, remainder to the earliest. The post gets 1 and
the continuation 0. The second post then panics. Under end-of-op flush,
the op ends with r = 2 and k = 2, and both posts go.

## Limits

- The same sizes and limits as the origins model above. In addition:
- FIFO is checked per (poster task, actor). Per (sending actor, actor)
  follows from it, because one actor's ops are serial and each flushes
  atomically when it ends. That isn't checked separately.
- The determinism check is per scenario: one fixed panic site, under
  every interleaving the model explores. It isn't a proof for all
  programs. The argument for all programs is origin-counters' P8: an op's
  fuel is a function of its causal path.
- Credit returns go straight to a "home". The model doesn't batch them per
  pass, and doesn't model cores.
- The observability argument covers what Ren has today: posts, `at`,
  `settled()`, `Docs.each` and services. Any future primitive that lets an
  op wait on in-family state would need the same check.

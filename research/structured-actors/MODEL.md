# FizzBee check of structured actors

**Verdict.**

- **The design holds if rule 2 is read strictly.** The strict reading: from
  inside family F, meaning an F operation or an F `at` block, you can reach
  only families installed *outside* F (`NEST="outer"`). Under that reading
  every scenario passes:
  - deadlock detection finds nothing;
  - FIFO per (poster, key), NoLostPost and EveryAcceptedPostRan (checked at
    teardown) hold;
  - mail per key stays ≤ CAP, and mail per family ≤ `max:` × CAP;
  - MaxRespected holds with no exception;
  - setup errors reach the poster or caller, and nothing is queued for them;
  - liveness: the families always end once the outside programs end.

  There's no panic state anywhere in the model. All four old
  counterexamples pass or can't be written.
- **New hole: the loose reading deadlocks.** The loose reading bans only F
  itself, so an `Index.at` block could reach `Docs`, which is installed
  inside Index. That's how rule 2 and AUDIT.md word it ("no `at` and no
  `post` to F from an F operation, an F `at` block, or anything they
  call"). Under it there are three deadlocks, one through each kind of wait:
  - **Waiting for a slot.** Decision 18's pin rule catches this one.
  - **Waiting for mailbox room.** The pin rule as stated doesn't cover it.
    Extending it (`PIN_MAIL`) fixes it, but then `post` can fail with
    `Full`.
  - **Waiting to take an actor for one call.** No `Full` rule can fix it.

  **The smallest fix is the strict rule 2, checked.** All three programs
  become compile errors.
- **With the strict rule, the pin rule isn't needed.** Every wait points
  outward, so the pin rule never fires. Turning it off (`PIN_RULE=False`)
  gives the same graphs, state for state. Mutant (c) can only fail under
  the loose reading.
- **Delivery past `max:` isn't needed.** Eager setup plus "an actor with
  mail is never evicted" means a key with mail always has a live actor, so
  a delivery never makes an actor. Even with eager setup turned off, no
  deadlock appears without the exception.

## What's modelled

`actors.fizz`, about 600 lines. Reproduce with `./run.sh`
(`./run.sh design|old|live|mutants` runs one section). It prints each
result with the expected result in brackets, and a condensed trace for
failures (`trace.py`).

- **Families** come in install order, `ORDER`, outermost first. The default
  is `Log > Index > Docs`. Each has `KEYS` keys (2, or 3 in the load case),
  `max:` 1 by default (2 or 3 in some runs) and `CAP` 1. Each key has a
  mailbox and one delivery task, which the family owns.
- **Programs and ops** use the same steps:
  - `post F k op` (`posts` is a loop);
  - `at F k` … `end`;
  - `call op` (`calls` is a loop);
  - `io`, a suspension point.

  Outside tasks run programs. Ops run on deliveries, or on the `at` caller's
  task. An op takes its actor for that one call. Ops may post outward or
  `at` outward, before or after an `io`. A Docs op can `at` Index whose op
  `at`s Log.
- **Rule 2 is the compiler's check.** `ProgramsLegal` walks every program
  and every op reachable from it. `NEST` picks the reading: `outer`
  (strict) or `notself` (loose).
- **post.** Eager setup runs first: the post makes the actor, evicting any
  evictable one (a superset of LRU) or waiting for a slot. Then the post
  waits for room in key k's mailbox and queues. It returns once the call is
  queued. A setup failure (`FAIL_KEYS`, chosen fresh on each attempt) goes
  to the poster: nothing is queued and the step moves on. `at` makes the
  actor the same way and pins it. A failed `at` skips its block.
- **Eviction.** An actor that's pinned, running an op, or has queued mail is
  never evicted. `CHAOS` evicts any evictable actor at any point.
- **Teardown.** It starts when every outside program has finished. The
  innermost family that hasn't ended waits until its mail is drained (its
  deliveries may post outward), then ends. Then the next family out.

### Properties

| Property | Kind | Meaning |
|---|---|---|
| ProgramsLegal | always | the programs pass rule 2 (a failure means "the compiler refuses this") |
| FifoPerPosterKey | always | posts from one task to one key are delivered in the order posted |
| NoLostPost | always | no accepted post is dropped |
| EveryAcceptedPostRan | always | an ended family has delivered everything it accepted |
| NoPostToEndedFamily | always | teardown order is safe |
| MailPerKeyWithinCap | always | mail per key ≤ CAP |
| MailWithinLiveOrQueuedKeys | always | family mail ≤ (live or queued keys) × CAP |
| MailWithinMaxTimesCap | always | family mail ≤ `max:` × CAP, which follows from MailImpliesLive |
| MaxRespected | always | live actors ≤ `max:`, with no exception |
| MailImpliesLive | always | a key with queued mail has a live actor (eager setup, never evicted) |
| NoHeadOfLineBlocking | always | no post waits while its own key's mailbox has room |
| NoPanic | always | the design has no panic state, and the model has none to reach |
| deadlock detection | always | on in every run |
| AllFamiliesEnd, PinnerWaitsOnFullMailbox, OpWaitsOnFullMailbox, WaitsForSlot, SetupErrorReachesCaller, FullReturned, MailboxFull | exists | coverage: the run reaches the interesting state (switched on by `COVER`) |
| FamiliesEventuallyEnd | eventually always | liveness under weak fairness (the `live` runs) |

## Results

State counts are unique states.

| Scenario | What it exercises | Result |
|---|---|---|
| BASE | ops post outward with I/O before or after; `at` → op `at` Index → op `at` Log; a post from an `at` block | PASS, 1,791 |
| PINPOST | pin Docs0, post twice to a full Index0; another task waits for a Docs slot | PASS, 227 |
| OPCHAIN | a Docs op posts to a full Index key while Index ops `at` Log, whose one slot is pinned | PASS, 3,293 |
| SLOTPIN | every Docs slot pinned while posts to a non-live Docs key wait | PASS, 585 |
| LOOPS | a poster loop and an `at` session loop whose op posts outward; `max: 2`; chaos eviction | PASS, 23,215 |
| SWAP | the other install order (Docs outside Index); Index ops post to Docs | PASS, 966 |
| SWAP_ILLEGAL | a Docs op naming Index when Index is inside Docs | refused (ProgramsLegal) |
| FAILKEY | setup failure under an outside post, under a post from a Docs op, and under an `at` | PASS, 3,832 |
| Liveness (PINPOST, OPCHAIN, SLOTPIN, SWAP, FAILKEY, LOAD) | the families end whenever the programs do | all PASS, IsLive |

**The old counterexamples, replayed:**

| Old counterexample | Now |
|---|---|
| **Load**: 3 sessions, more than CAP, each op does I/O and then posts to one Index key (Index `max: 1`) | PASS, 7,329. The later posts wait for room in Index0; nothing panics |
| **Pin-then-post**: posts inside `at` to a family with no free slot, and to a full key | PASS, 332 |
| **Chain reaction** (`double` posts twice into its own family) | can't be written: ProgramsLegal refuses it. A chain is at most one hop per family, outward |
| **Setup failure under a post** | PASS (FAILKEY): the error reaches the op or task that posted, and nothing is queued |

**Mutants:**

| Mutant | Expected | Result |
|---|---|---|
| (a) post into the same family, waiting for room | deadlock | **DEADLOCK** |
| (a′) post into the same family, not waiting | unbounded mail | **FAIL MailPerKeyWithinCap** (2 > 1 after one delivery of `double`) |
| (b) one bound per family (FAMCAP 1) instead of per key | head-of-line blocking | **FAIL NoHeadOfLineBlocking** |
| (c) no pin rule, strict rule 2 | — | PASS ×4 (PINPOST, OPCHAIN, SLOTPIN, PINFULL), identical state counts: the rule is implied |
| (c) no pin rule, loose rule 2 | deadlock | **DEADLOCK** (NESTIN) |
| (c) the pin rule, loose rule 2 | — | NESTIN PASS (`Full` reached); NESTMAIL **DEADLOCK**; with PIN_MAIL, NESTMAIL PASS but NESTCALL **DEADLOCK** |
| (c) the fix: strict rule 2 | refused | NESTIN, NESTMAIL and NESTCALL are refused (ProgramsLegal) |
| (d) no eager setup, setup fails at delivery | lost post | **FAIL NoLostPost** |
| (d) no eager setup | mail for a dead key | **FAIL MailImpliesLive**; and **FAIL MailWithinMaxTimesCap**: mail is bounded by keys × CAP, not `max:` × CAP |

## Counterexamples in Ren terms

**(a) Posting into your own family, with waiting.** `max: 2`, CAP 1.
`poke` is `Docs.post(id + 1, Doc.Call.Nop)`.

```ren
Docs.post(0, poke); Docs.post(1, poke); Docs.post(0, nop); Docs.post(1, nop)
```

Docs0's delivery takes `poke` and starts it, and so does Docs1's. The
outside task refills both mailboxes with `nop`. Each `poke` now waits for
room in the other key's mailbox, and that room only appears when the other
`poke` returns. Without the wait (a′), `double` queues two posts to one key
with CAP 1, so the bound is gone: the old chain reaction.

**(b) One bound for the family.** With FAMCAP 1, a task posts `nop` to
Docs0. A second task's `Docs.post(1, nop)` now waits, even though Docs1's
mailbox is empty. That's one state in, so every slow key delays every
other key.

**(c) The loose reading of rule 2: three deadlocks.** `Index` is installed
outside `Docs`, and each has `max: 1`.

1. *Slot (NESTIN, without the pin rule).*

   ```ren
   T0: Index.at(0) fn() => Docs.at(0) fn() => ()
   T1: Docs.at(1)  fn() => Index.at(1) fn() => ()
   ```

   This is a lock-order inversion. Decision 18's pin rule gives T0 `Full`
   instead, and the run passes.
2. *Mailbox (NESTMAIL, with the pin rule as stated).* `look1` is a Docs op,
   `Index.at(1) fn() => Index.nop()`.

   ```ren
   Docs.post(0, look1)                          // Docs0's delivery starts it
   Docs.post(0, look1)                          // Docs0's mailbox is now full
   Index.at(0) fn() => Docs.post(0, nop)        // pins Index0, waits for room in Docs0
   ```

   The running `look1` waits for an Index slot, which it's allowed to do:
   Index is outside Docs. The only slot is pinned by T0, and T0 waits on
   Docs0's mailbox. Extending the pin rule to mailbox waits (`PIN_MAIL`)
   makes T0's post fail with `Full` instead. But that gives `post` an error
   besides setup's.
3. *Taking the actor for a call (NESTCALL, with PIN_MAIL too).*

   ```ren
   Docs.post(0, look1)
   Index.at(0) fn() => Docs.at(0) fn() => Doc.nop()
   ```

   Docs0's delivery runs `look1` and waits for an Index slot, which T0
   pins. T0 waits to take Docs0 for `nop`. There's no slot or mailbox here
   for a `Full` rule to act on.

**The fix**, checked: inside F (its ops, its `at` blocks, and anything they
call), only families installed outside F can be reached. All three programs
become compile errors. This is decision 10's inner-to-outer rule applied
to blocks as well as handlers. Its cost to programs: you open outer
families inside inner ones, `Docs.at(d) fn() => Index.at(i) ...`, and
never the other way round.

**(d) No eager setup.** `Docs.post(1, nop)` queues for a key with no actor.
The delivery's setup fails, and there's no one to give the error to, so the
post is lost. Separately, the posts to `n` distinct keys that aren't live
queue `n` × CAP calls, however small `max:` is. The family's memory then
follows the key space, which the network chooses.

## Delivery past `max:`

**It isn't needed. Drop it.**

- **With eager setup**, MailImpliesLive holds in every run, so a delivery
  never makes an actor and never waits for a slot. MaxRespected holds with
  no exception.
- **Without eager setup**, deliveries do wait for slots. Even then no
  deadlock appears (three runs, including mail for a key that isn't live
  while the family is full and pinned). A delivery holds nothing while it
  waits. The slots it waits for are held by pins, running ops and actors
  with mail. Under the strict rule 2 those only wait outward, or drain.

## Limits

- Bounds are small: 2–3 families, 2–3 keys, `max:` 1–3, CAP 1, 1–3
  outside tasks, and short programs. FIFO uses sequence numbers mod 4
  (mod 3 in LOOPS).
- Eviction picks any evictable actor, which is a superset of LRU.
- The compiler check is modelled on the programs as written. Helpers and
  closures that hide an `at` or `post` aren't modelled; AUDIT.md's "anything
  they call" marking covers them.
- Not modelled: cancellation, supervision (a panic ends the program),
  `each`, `evict_idle`, `settled()`, setup that suspends, and several
  callers waiting on one key's setup.
- Liveness runs only on programs without loops. Programs with loops are
  checked for safety and deadlock only.
- One op runs per call, and the `at` caller's task runs it. A delivery's
  posts count as posts from the key's delivery task for FIFO.

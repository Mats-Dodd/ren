# FizzBee check of the runtime core's protocol

**Verdict.**

- **SPEC §B, as written, has two bugs.** Both show up in small cases.
  - **A use after free at every place that wakes a task.** `deliver`
    stores the reply, frees the slot and the op, and then calls
    `notify(t)`. Once the reply is stored, the task can run on another
    worker, finish and be freed before that `notify`. The task only has to
    be in a run queue already, and SPEC §B.5 allows that ("a task can be
    resumed by any `ren_notify` before its reply arrives"). The cancel
    walk's notify is enough. The same window is at three other places:
    the last child leaving a scope notifies the owner; an instance release
    hands off to a waiter and then notifies it; and any `until` signal
    (W2's turn word) that's set before its notify. All four fail
    `NoUseAfterFree`. The slice's workloads already keep the rule by hand
    at the last three: W1's children each hold a reference to the root,
    and W2's shared state holds both players. The core's own `deliver`
    holds none, and no test exercises it (native-lang SYNTHESIS §3).
  - **A lost wake on a retraction.** `ren_poll_call` retracts a call that
    was cancelled before it was pulled. It pushes the `Cancelled` reply
    to its own inbox and wakes no one. The worker has already returned
    `IDLE`, so its driver sleeps forever with the reply in the inbox.
    This fails `NoLostWake` with every worker parked and nothing in
    flight. **This is the Rust `t_cancel` hang.** C and Zig wake the
    worker there (each one's NOTES.md, departure 1). Rust's
    `poll_call` (`experiments/native-lang/rust/core/src/sched.rs:725-740`)
    doesn't. That's the one place the three cores differ on this path.
- **One more gap: `ren_stop` doesn't wake parked tasks.** It cancels the
  op slots and wakes the workers, and that's all. A task parked on an
  `until()` (W2's turn) never runs again to see that it's stopping. If
  its peer leaves first, the run never ends (DEADLOCK). W2 hides this:
  its player notifies its peer on the way out. A Ren program can't be
  asked to do that. Waking only the tasks parked at that moment isn't
  enough either: a task that has just decided to park, and hasn't yet,
  is missed, and it hangs the same way (mutant). `ren_stop` has to
  `ren_notify` every live task, which sets NOTIFIED on a running one.
- **With three rules added, everything holds.** The rules are: the ref
  rule, the retraction wake and a stop walk (see "The rules"). Then every
  scenario passes, including the ones that make each bug above:
  - no use after free and no double free;
  - a stale reply is never `ACCEPTED`, and a stale cancel never hits a
    reused slot;
  - an `ACCEPTED` reply always has a waiter;
  - a cancelled task waits for its reply;
  - ends once, and a scope ends after its tasks;
  - an instance has at most one holder, and no waiter is lost;
  - no lost wake;
  - liveness: every worker's loop exits, with or without `ren_stop`.
- **Every mutant fails as expected:** P4's double free; P3's stale reply
  `ACCEPTED`, and its cancel-side twin; a notify before the store (a lost
  wake); a park with no re-check (a lost wake); the old rule 4 (a
  cancelled task leaves with its call still out); a take that parks
  without re-checking (a lost waiter); and a stop that wakes only the
  tasks parked at that moment (a hang).
- **The Zig W2 hang is not explained.** No interleaving of the protocol
  loses a wake in W2's shape. That covers ping-pong through `ren_notify`,
  with and without a `YIELD` through the injector, with a spurious wake,
  and under `ren_stop`. W2 makes no world calls and holds its own
  references, so neither bug above can touch it. Zig's park, wake,
  notify and task-word code reads the same as SPEC's. The model is sequentially consistent, so the cause, if
  it's in the core, is below it: memory ordering (Zig's deque replaces
  SPEC's fences with SC accesses, §A.3), or the driver's eventfd wait.
  It hung 8 times in 15 in one loaded window, then 0 times in 100+,
  which also points away from the protocol.

## Counterexamples, condensed

Read `W1.dlv2` as "worker 1 took the step at pc `dlv2`". `T1:P@0.2`
means task T1 is PARKED at instruction 0, sub-step 2. `s2=CU/1` is slot 2
in state CANCEL_UNPULLED at generation 1.

**1. `deliver` touches a freed task** (CALL: T1 makes a world call, T2
runs the scope's cancel walk).

```
W0  T2's walk flags T1 and notifies it: T1 PARKED -> QUEUED on W0
W0  T2 cancels T1's call: s2 ISSUED -> CANCEL_UNPULLED; T2 ends
W1  poll retracts it: s2 -> REPLIED, Cancelled into W1's inbox
W1  dlv1: store aw.state = Cancelled, free slot 2 and the op
W0  runs T1 (it was queued): sees the reply, ends, DONE, freed
W1  dlv2: notify(T1)                       -> use after free
```

The same with no cancel at all: a spurious notify queues T1 while its
reply is being delivered (SPUR).

**2. The scope's end touches a freed owner.** T1 leaves the scope:
`count` goes to 0 and it picks up the owner, R, to notify. Before it
notifies, R is woken from outside and runs. R sees `count == 0`, ends,
and is freed. Then T1's notify(R) is a use after free.

**3. The instance handoff touches a freed waiter.** T1's take finds T2
holding the instance, so T1 queues itself and parks. T2 releases and
hands it to T1: `held = T1`. Before T2's notify(T1), T1 is woken from
outside and runs. It sees it holds the instance, releases it, ends and
is freed. Then T2's notify is a use after free.

**4. The retraction is lost** (RETRACT: T1 issues a call and cancels it in
the same step, as `t_cancel` (b) does).

```
W0  T1: ren_world -> s0 ISSUED; ren_cancel -> s0 CANCEL_UNPULLED; T1 parks
W0  pick: nothing; try_park -> IDLE
W0  poll: retract: s0 -> REPLIED, Cancelled into W0's inbox; no wake
W0  wait: blocks (no permit, nothing in flight)
W1  pick: nothing -> IDLE -> wait: blocks       -> NoLostWake, then DEADLOCK
```

In `t_cancel`, (a), (b) and (c) run at once. The hang needs (b)'s worker
to have nothing else in flight on its driver: no timer, no read. At one
worker, (a)'s read and the sleeps are on the same driver, and their
completions wake it, so the retraction is delivered late but delivered.
At 8 workers, (b) can land alone on a worker. That fits a hang 2-3 times
in 200, only at 8 workers, with "every worker parked, no timer armed".

**5. `ren_stop` leaves a task parked on an `until`** (PING under STOP,
SPEC's stop). Stop lands. T2 is at `await_turn`, sees it's stopping and
ends without giving the turn. T1 is parked waiting for the turn. The stop
walk cancels slots only, so nothing wakes T1. Every worker parks:
DEADLOCK.

**The mutants**, in one line each:

- **P4.** The retraction's reply is delivered with `had_cancel` set, so
  `on_cancel_done` frees the op and `deliver` frees it again: a double
  free.
- **P3.** T1's first call is in slot 2 at generation 1. Its second call
  reuses slot 2 at generation 2. A late duplicate reply for generation 1
  is `ACCEPTED` into generation 2.
- **P3, cancel side.** The walk reads T1's pending id (slot 2, gen 1).
  T1's reply lands, and T1 enters its `finally` and calls again (slot 2,
  gen 2). The walk's `cancel_slot(gen 1)` then cancels the `finally`'s
  call, which should be masked.
- **Notify before the store.** T1 is already QUEUED (the walk's
  notify), so `deliver`'s notify only sets the NOTIFIED flag. T1 runs,
  and its `xchg(RUNNING)` clears the flag. It sees no reply yet, and its
  PARK CAS succeeds. Then `deliver` stores the reply. T1 is parked with
  its reply, and no one will wake it.
- **Park without a re-check** (replies from any thread). A reply lands in
  W1's inbox after W1's pick found nothing and before its `parked = 1`.
  The replier sees `parked == 0` and doesn't wake it. W1 parks for good
  with the reply in its inbox.
- **Old rule 4** (a cancelled task leaves at once). T1 is flagged and
  notified while its call is ISSUED, and it resumes with `Cancelled`
  while the call is still the driver's.
- **A stop that wakes only parked tasks.** T1 checks `await_turn`: not
  stopping, not its turn, so it decides to park. The stop lands and
  queues every PARKED task; T1 is still RUNNING, so it's skipped. T1's
  PARK CAS succeeds. T2 sees it's stopping and leaves without giving the
  turn. DEADLOCK.
- **A take that parks without a re-check.** T1's CAS fails (T2 holds).
  T2 releases with no waiters queued, so the instance is free. T1 then
  queues itself and parks on a free instance.

## What's modelled

`core.fizz`, about 950 lines. Reproduce with `./run.sh`
(`./run.sh design|spec|mutants|live` runs one section). It prints each
result with the expected result in brackets, and a condensed trace for
failures (`trace.py`).

- **Workers.** Two, each running SPEC §C.1's driver loop around §B.4's
  `ren_run`: run, pull calls until `ren_poll_call` is false, wait, reap
  completions through `ren_reply`, and back. A worker parks with §B.6's
  `try_park`: announce `parked = 1` and `idle + 1`, then re-check the
  inbox, the injector, every deque and `done`. `host.wake` is a sticky,
  idempotent permit; the driver's wait blocks until it or a completion
  arrives. `wake_worker`, `wake_one` and `wake_all` are §B.6's.
- **Tasks.** The root R spawns T1 and T2 into one scope, then waits for
  the scope to end. Each child runs a short program (see the top of
  `core.fizz`). The task word is §B.2's: QUEUED, RUNNING, PARKED, DONE
  and the NOTIFIED flag; `notify` queues the task only if it saw PARKED
  without the flag; a PARK whose CAS fails re-queues. A task's frame is
  its program counter and sub-step: the innermost frame waits on the
  call, and finishing it resumes the parent (the next instruction).
- **Calls.** Each worker owns two slots. An id is slot and generation.
  A slot goes FREE, ISSUED, PULLED or CANCEL_UNPULLED, CANCEL_PULLED,
  REPLIED, and back to FREE with the next generation, exactly as §B.3's
  table. A task's next call reuses the slot. `answer_now` may answer
  inline (INLINE).
- **The world.** It completes any pulled call, at any time: `Done`, or
  `Cancelled` if a cancel reached it (the original's reply is the final
  one). By default the home driver calls `ren_reply`; with
  `REPLY="any"` the world's own thread does, then wakes the home worker
  as a separate step. `DUP` adds one late duplicate of a reply.
- **Cancel.** The walk visits each child under the scope's lock: it sets
  the flag, notifies the child, and reads its pending call id. Outside
  the lock it cancels that id with `cancel_slot`. A flagged task checks
  the flag before a call starts, never after, and a `finally` masks it.
  A cancelled task waits for its call's reply (`Done` or `Cancelled`).
- **The instance.** One shared instance. A take is a CAS; on contention
  the taker, under the wait-queue lock, either finds it free and takes it
  or sets HAS_WAITERS, queues itself and parks. A release with no waiters
  is a CAS to free; with waiters, it hands off to the first, under the
  lock, then notifies it.
- **`ren_stop`.** `stopping = 1`, then cancel every slot that isn't free,
  then `wake_all`. `ren_world` checks `stopping` after publishing, as
  SPEC's Dekker pair does. `STOP_WALK="notify"` adds the fix: also
  `ren_notify` every live task. `STOP_WALK="parked"` queues only the
  tasks that are PARKED at that moment.
- **Freeing.** A task is freed when it's DONE and its last reference is
  dropped. The core holds one; `REF` adds the waker's. An op is freed by
  `deliver` (or inline). Touching a freed task or op, or freeing twice,
  is recorded and fails an invariant.
- **Spurious wakes.** The cancel walk's notify is one. `SPURIOUS` adds
  one more, from outside, of any parked task.

### Properties

| Property | Kind | Meaning |
|---|---|---|
| NoUseAfterFree | always | nothing touches a freed task or op |
| NoDoubleFree | always | an op or a task is freed once |
| StaleReplyNeverAccepted | always | a reply for an old generation is never `ACCEPTED` |
| StaleCancelNeverHits | always | a cancel for an old generation never cancels the slot's new call |
| AcceptedOnlyWithWaiter | always | an `ACCEPTED` reply has a live task waiting for that id; the rest are `RELEASE`d |
| CancelledTaskWaitsForReply | always | while a call is the driver's (or replied, not yet delivered), its task waits on it |
| EndsOnce | always | a call is delivered once, a task ends once, and a DONE task never runs |
| ScopeEndsAfterItsTasks | always | the root passes its scope's end only when every child has ended |
| InstanceHeldByOne | always | at most one task believes it holds the instance, and it's the holder |
| NoLostWaiter | always | a free instance has no one queued on it |
| NoLostWake | always | when every worker is asleep for good, no task is queued, no inbox, outbox or cancel queue holds anything, and no parked task's condition already holds |
| deadlock detection | always | on in every run |
| Cover_* | exists | coverage: the run reaches the race it's for (switched on by `COVER`) |
| AllExit | eventually always | every worker's driver loop exits (the `live` runs) |

## Results

State counts are unique states. `./run.sh` takes about 35 minutes with
its four sections run side by side (design 33, live 20, mutants 12,
spec 8, on a 16-core Mac).

**The design** (SPEC §B with the ref rule, the retraction wake and, under
`ren_stop`, the stop notify):

| Scenario | What it exercises | Result |
|---|---|---|
| CALL | a sibling's cancel walk races T1's call: flag, notify (a spurious resume), cancel by id; the reply races the cancel; a retraction | PASS, 36,118 |
| FINALLY | the same, then a call inside a `finally` that reuses T1's slot at the next generation | PASS, 48,832 |
| RETRACT | issue and cancel in one step (`t_cancel` (b)) | PASS, 1,442 |
| RETRACT2 | the same with another task's call in flight | PASS, 14,626 |
| DUPS | two calls in a row and one late duplicate reply (stale after the slot's reuse) | PASS, 22,848; the stale and duplicate replies are `RELEASE`d |
| INLINE | `answer_now` answers some calls inline | PASS, 9,822 |
| INST | two takers of one instance: CAS, park, handoff, a spurious wake | PASS, 26,205 |
| PING | W2: ping-pong through a turn word and `ren_notify` | PASS, 6,813 |
| PING + SPURIOUS | the same with an outside wake | PASS, 27,109 |
| PINGY | W2 with a `YIELD` through the injector after each give | PASS, 9,211 |
| STOPS | `ren_stop` at any point around a call | PASS, 54,579 |
| PING + STOP | `ren_stop` during W2 | PASS, 129,948 |
| SPUR | an outside wake of a task whose call is out | PASS, 11,249 |
| CALL, RETRACT2, STOPS with `REPLY="any"` | `ren_reply` and its wake on another thread | PASS, 62,504 / 29,130 / 76,059 |
| Liveness: CALL, FINALLY, RETRACT2, INST, PING, STOPS, PING + STOP | every worker's loop exits | all PASS, IsLive |

**SPEC §B as written:**

| Run | Result |
|---|---|
| CALL, SPEC's `deliver` | **FAIL NoUseAfterFree**: trace 1 |
| SPUR, SPEC's `deliver` | **FAIL NoUseAfterFree**: the same window, from any spurious wake |
| the ref rule everywhere but the scope's end | **FAIL NoUseAfterFree**: trace 2 |
| ... everywhere but the instance handoff | **FAIL NoUseAfterFree**: trace 3 |
| ... and a W2 give whose notifier holds no reference (W2 holds one) | **FAIL NoUseAfterFree** |
| PING under SPEC's `ren_stop` | **DEADLOCK**: trace 5 |
| RETRACT, RETRACT2, and `ren_stop` around one call, with no retraction wake | **FAIL NoLostWake** ×3: trace 4 (`ren_stop`'s own cancel retracts too) |

**Mutants** (each on top of the design):

| Mutant | Expected | Result |
|---|---|---|
| P4: the cancel path frees the op too | double free | **FAIL NoDoubleFree** |
| P3: no generation check in `ren_reply` | stale reply accepted | **FAIL StaleReplyNeverAccepted** |
| P3: no generation check in `cancel_slot` | a stale cancel hits the reused slot | **FAIL StaleCancelNeverHits** |
| `deliver` notifies before the store | lost wake | **FAIL NoLostWake** |
| `try_park` without the re-check (replies from any thread) | lost wake | **FAIL NoLostWake** |
| old rule 4: a cancelled task leaves at once | leaves with its call out | **FAIL CancelledTaskWaitsForReply** |
| a take that parks without re-checking | lost waiter | **FAIL NoLostWaiter** |
| `ren_stop` queues only the tasks PARKED at that moment | hang | **DEADLOCK** |

## The rules

These are what the core must keep. The first three are new; the rest
are in SPEC already, and each has a mutant that shows what breaks
without it.

1. **A waker holds a reference to the task across its wake.** Whoever
   makes a task's wait come true and then notifies it takes a reference
   before the store that makes it true, and drops it after the notify.
   That's `deliver` (before `st(aw.state)`), the last child leaving a
   scope (before `count` reaches 0), an instance handoff (before
   `held = waiter`), and every `until` signal. The order in `deliver`
   is: `rc_dup(t)`; store the reply; free the slot and the op; `notify(t)`;
   `rc_drop(t)`. The alternative is to make the store and the wake one
   RMW on the task's word, so the waker touches the task afterwards only
   when it saw PARKED (then the task can't run until the waker queues
   it). Notifying before the store is not a fix: it's a lost wake
   (mutant).
2. **A retraction is a reply, so it wakes its worker.** `ren_poll_call`
   calls `wake_worker(w)` after pushing a retracted call's `Cancelled`
   to its own inbox. SPEC's pseudocode needs the line; the Rust core
   needs the fix.
3. **`ren_stop` cancels the task tree, not only the slots.** Besides
   cancelling every slot, it calls `ren_notify` on every live task, as a
   cancel walk does, so a task parked on an `until` runs and sees it's
   stopping. It must be a notify (fetch_or NOTIFIED), not "queue the ones
   that are PARKED": a task between its last check and its PARK CAS is
   missed by the second, and its CAS then fails under the first.
4. **Deliver is the only free of an op.** A cancel never frees, and the
   retraction goes through `deliver` too (P4).
5. **Both `ren_reply` and `cancel_slot` check the generation**, in the
   same CAS as the state (P3, both sides).
6. **Park re-checks after announcing.** `parked = 1`, `idle + 1`, then a
   full check of the inbox, the injector and every deque. Anyone who
   makes work visible checks `parked` after (§B.6's Dekker pair).
7. **A cancelled task waits for its reply** (§2.2). Release is only for
   replies with no waiter.
8. **A contended take re-checks under the queue lock** before it queues
   and parks; a release with waiters hands off under the same lock.

## Limits

- Bounds are small: 2 workers, 2 slots each, a root and 2 children,
  1-3 calls, one instance, programs of 1-4 instructions.
- **The model is sequentially consistent.** Every step is an atomic
  action. It checks the protocol, not the memory orders that implement it
  (§A's deque, the fences, Zig's SC-access substitution). Those need
  GenMC or loom, as native-lang SYNTHESIS §2 says.
- Steps that nothing else can tell apart are merged: `wake_one` is one
  step, and so are a task's last step and its DONE handling.
- The deque is abstract: the owner takes the bottom, a thief the top,
  and a steal never aborts. The K-poll, the step budget (`STEPS`, off by
  default), the journal and `ren_kill` aren't modelled.
- One scope, no nesting. The walk covers one level; a deeper tree only
  repeats it.
- Frames are a program counter. Address reuse is modelled through slot
  generations, which is where §2e says ends-once must rest.
- `ren_reply` from any thread is one replier thread (`REPLY="any"`), not
  many.
- Liveness runs only on the bigger scenarios: CALL, FINALLY, RETRACT2,
  INST, PING, STOPS and PING under STOP.

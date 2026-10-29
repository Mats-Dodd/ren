# Task 2: FizzBee check of streams.md open decision 11

**Verdict: the narrowed row is sound under decision 10 as written.** No
extra restriction is needed. The check confirms that both `release` and
`Async.until` have to stay in the row. It also found a deadlock that
happens under the current rule and the narrowed rule alike, which
decision 10's "No deadlock" bullet doesn't cover. It is described below.

Spec: `open-items/t2/handler_state.fizz`. Reproduce with `open-items/t2/run.sh`,
which prints a condensed trace for each run with `trace.py`.

## What the model is

- **Services.** C, B and A are installed outermost first. A is an actor
  whose state holds a reader `r` at position `pos`.
- **Task 1, `A.scan`.** It runs `for x in &self.r`, holding a write of
  `self.r` for the whole loop and stepping it in place. Under the current
  rule it runs the copy-out dance instead: `let r = self.r`, step `r`,
  then write `self.r = r`. The loop body is one of three things: a
  dependency call `B.work()`, `release B.work()`, or `Async.until(flag)`.
- **`B.work`.** It may do nothing, call C, `release` itself around a call
  to C, or wait in `Async.until`. When the static rule is switched off, it
  may also call back into A directly (A → B → A, depth 2) or through C
  (A → B → C → A, depth 3).
- **Task 2.** It pokes A (an operation that writes `self.r` and sets A's
  flag), signals B, or does both through A (`A.pokesig`, which is A then B).
- **Instances follow decision 10.** An instance is held until the
  operation returns or reaches `release` or `until`. The queue is fair:
  the checker may pick any waiter. Instances are not re-entrant.
- **The compiler is the `accepted()` function.** It applies decision 2's
  overlap check with the chosen row. Init picks every program that
  `accepted()` passes, so each run covers all of them.
- **Invariants.** No two live writers of `self.r`. No lost update: the
  final `pos` equals every step and poke that was applied. The loop never
  finds `pos` moved under it (no stale reads). No task waits on an
  instance it already holds. Deadlock detection is on.

## Results

| Run | Result |
|---|---|
| Current rule (copy dance) | PASS, 1,186 states |
| **Narrowed rule** (in-place `&self.r` across `B.work()`, with B calling C, releasing around C, or waiting in until while task 2 signals it) | **PASS**, 2,474 states. With 3 steps, 3,279 |
| Narrowed without `release` in the row | FAIL, NoTwoWriters |
| Narrowed without `until` in the row | FAIL, NoTwoWriters |
| Either rule, with B waiting in `Async.until` and B's waker going through A | FAIL, deadlock |
| Either rule, with cycles allowed (depth 2 or 3) and non-re-entrant instances | FAIL, NoReentryWait (the task waits on itself) |
| Narrowed rule, with cycles allowed and re-entrant instances | FAIL, NoTwoWriters |
| Current rule, with cycles allowed and re-entrant instances | FAIL, NoLostUpdate |

## Why it holds

While A's operation is inside `B.work()`, only two things could touch
A's state:

1. **Another task.** It queues for A, because the operation keeps A
   until it returns (decision 10).
2. **This task coming back into A.** That needs a path from B back to A.
   B and C are installed outside A, so they can't name A. A block gets
   dependencies only from its parameter's type. Handlers in one `with`
   can't form a cycle, and an actor can't use its own family except
   through `post`.

So a cycle never type-checks. If one did, the task would wait on itself
and never return, which is the "waits or errors" outcome. It would never
race.

The cycle runs also show that the current rule protects nothing extra.
With re-entrant instances, its copy dance loses updates. In this trace,
`copyin` writes 2 over a `pos` of 20, which held two pokes made through
B → A. So decision 2's current row and decision 10's instance rule rest
on the same guarantee. Narrowing the row adds no new risk.

## Counterexamples, in Ren terms

**`release` or `until` taken out of the row (NoTwoWriters).** This is the
smallest failure:

```ren
for line in try &self.r
  try release B.work()   // A is let go here
// meanwhile task 2 runs A.poke, which steps self.r: two writers of r
```

Trace: T1 takes A, steps `r` to 1, and lets go of A. T2 takes A and
steps `r`, and the violation fires. The same happens with
`Async.until(...)` in place of the `release`. Both must stay in the row.

**Nested `until` (deadlock, under both rules):**

```ren
// in A's handler
for x in &self.r           // or the copy dance; same result
  B.work()                 // B is installed outside A
// in B's handler
fn work() = Async.until(fn() => ready)
// task 2
A.pokesig()                // takes A, then calls B.signal(), which sets `ready`
```

Trace: T1 takes A, steps `r`, calls `B.work`, takes B, and lets go of B
at `until`. T2 waits for A. T1 still holds A and waits for B's `ready`,
which only T2 can set. This is the nested-monitor lockout: `until` lets go
of the instance it's in, not the ones the task holds further in. Waiting
on a channel receive (decision 6) inside an outer service has the same
shape. Narrowing the row doesn't cause it and doesn't make it worse. It
is a gap in decision 10's "No deadlock" claim, which covers only waits
for an instance.

## Smallest restriction

**For decision 11, none.** Adopt the narrowed row as streams.md proposes
it. It is sound exactly while decision 10's static rules forbid every
path from an outer handler back into an inner one, and instances are not
re-entrant. Writing that dependency into decision 2's paragraph would
help.

Separately from decision 11, decision 10 should change in two places:

- **Scope the "No deadlock" claim.** It should cover waits for an
  instance, not condition waits. Then either document the lockout above,
  or have `sim` report "every task is parked, and T1 holds A while it
  waits in B's `until`". The cheapest fix is for `sim` to name the held
  instances.
- **Make re-entry a runtime panic.** A task taking an instance it
  already holds is impossible by construction. It should panic, not wait
  forever.

## Limits of the model

- Two tasks, three services, and 2 or 3 loop steps.
- Block-parameter calls aren't modeled. They stay in the row unchanged.
- `post` mailboxes and `Docs.at` pinning aren't modeled either. Decision
  18's `Full` rule covers the mailbox cycle.
- The fair queue is modeled as a free choice among waiters, which
  includes every order a fair queue could pick.

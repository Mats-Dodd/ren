# Breaker

A circuit breaker over a backend that can be slow and can be down:
after `limit` failures in a row it opens, and fails with `Open` at once,
without asking the backend, until a success closes it again. It was
written for the services stage's step 4, `release` (foundations.md,
decision 10, "`release` lets go for one call"; compiler.md, "Services
stage").

```
ren run breaker/main.ren          # Ok("item 1"), Err(Down), Err(Down), Err(Open)
ren test breaker --seeds 1000     # its tests, under a thousand schedules
```

| File | What's in it |
|---|---|
| `main.ren` | `Backend` and `Breaker`; `breaker(limit)`, the handler that counts failures; `flaky`, a backend that's down for a negative id; `main`; and the tests, over `timed`, a backend that takes `id` milliseconds to answer |

## What to look at

**An operation keeps its instance until it returns,** so a breaker that
asked the backend inside its operation would make every caller wait for
the slowest answer: one slow call, and the fast ones queue behind it.
`bench/services/breaker_held` is that breaker, and `ren test --seeds`
finds a seed where "a slow answer doesn't hold up a fast one" fails.

**`release` lets go for one call.** `attempt release Backend.fetch(id)`
lets the other callers in while the backend answers, then takes the
instance back, queueing like any caller. The breaker holds it only to
read and change its count.

**What it read is read again after.** The arm's `failures` is written
back before the call and read again after it, so `failures += 1` adds
to what the other callers counted meanwhile: "failures at once all
count" holds under every seed. A count read into a `let` before the call
and written back after it would lose the others', and since `sim`
switches tasks at `release`, a seed finds that too; Ren gives no
warning for it.

**The tests read virtual time.** `timed` sleeps `id` milliseconds of
`sim`'s clock, so the slow and the fast call overlap in a test that
takes no real time, and which one starts first is the seed's.

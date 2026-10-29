# Tasks

Stage 11a's programs, waiting here until their steps land them in
`examples/`: the five of [async.md](../../../async.md), the
`just`'s concurrent part, and the milestone, each a folder with its
tests and, in `expected`, what `ren test` prints there once its step
has landed ([compiler.md](../../../compiler.md#stage-11a), "The tests").
[bench/tasks.t](../../tasks.t) runs each and says whether it's as specified
yet.

```
cd bench/11a/tasks/crawler && ren test             # under one schedule
cd bench/11a/tasks/crawler && ren test --seeds 1000
```

| Folder | What's in it | Lands in |
|---|---|---|
| `server` | a server that serves each connection in a task, and on SIGTERM stops accepting and gives what's in flight the cleanup deadline; tests on `sim.net()` | step 7, landed: [examples/server](../../../examples/server) |
| `crawler` | a crawler: each page's links crawled at once, every url claimed once through a handler, and at most 16 requests at a time, with `sync.semaphore` and `sync.limit` | step 8 |
| `just` | `run_all`, a plan's levels one after another and each level's recipes at once, the first failure killing the rest; tests on `sim.proc` | step 8, then folded into [examples/just](../../../examples/just) |
| `transfer` | a transfer under `Async.timeout`, inside a transaction installed with `try with`, whose commit in its `finally` overruns the timeout and is still reported | step 5, landed: [examples/transfer](../../../examples/transfer) |
| `refresh` | prices refreshed by a task spawned beside the `with`, which cancels it when its body ends | step 5, landed (it needed only virtual time): [examples/refresh](../../../examples/refresh) |
| `lost_update` | the milestone: two deposits, each a read and then a write, one of them lost under some seeds, which `ren test --sim --seeds 200` finds and `--seed` replays; the same with one operation, which can't lose one; and the README's `cached`, which can't race any more | holds since step 5 (bench/tasks.t's `milestone`); it stays here, since its first test fails on purpose |
| `journal` | a version 1 journal, refused once journals are version 2 | step 6 (as specified) |

## What to look at

**A spawned task can't fail.** The server's connections handle their
own errors with `match attempt handle(conn)`, so one connection's
failure never stops another.

**A task beside a `with` is its background work.** In `refresh`, the
refresher is spawned in the `with`'s body into the scope outside it, so
it can call `Prices.refresh()`, and the `with` cancels it when its body
ends.

**Tests run in virtual time.** `Clock.sleep` takes no real time under
`sim`, and the tests check when things happened: the transfer reported
at 3.04 seconds, after its commit; the stuck request cut off at 6, the
signal's second plus the cleanup deadline.

**What holds under every schedule.** Every test here passes under a
thousand seeds but `lost_update`'s first, which is the bug: `deposit`
reads with one operation and writes with another, and the scheduler
can run the other task in between. `add`, one operation, can't lose a
deposit, since an operation keeps its instance until it returns.

# P3: handing off against barging

Phase one of the many-cores experiments (foundations.md, Staging). Decision 10
says an instance's queue is "fair, not first in first out": the runtime may let
a running task take a free instance before a parked one, as Go's mutex does, so
long as no waiter is passed over without bound. P3 measures what that buys.

**Prediction:** strict FIFO handoff loses 3x the throughput to barging with a
1 ms starvation guard.

## What's modelled

- **One handler instance:** an owner word (`state`: bit 0 held, bits 1.. the
  number of queued waiters), a waiter queue behind a small spinlock, and the
  handler's state (a counter and 16 words). Only the holder touches the state,
  plainly (no atomics), which is what "an operation keeps its instance until
  it returns" gives. An `in_cs` flag aborts if two tasks are ever inside.
- **64 tasks on N worker threads, green-thread style.** Not 64 OS threads,
  because decision 10 says "a thread never blocks while its task is parked":
  a task that can't take the instance is put on the instance's waiter queue
  and its worker runs another task. A task is a state machine (an operation
  holds nothing on a stack across the wait here, so its phase is its
  continuation); that skips a stack switch (~tens of ns) Ren's runtime would
  pay per park and resume.
- **Scheduler, Go's shape:** a run queue per worker plus a `runnext` slot,
  stealing (the victim's `runnext` only on the last spin round, as Go delays
  it), 64 spin rounds when out of work, then the worker parks on a condition
  variable; making a task runnable wakes an idle worker only if none is
  spinning (`wakep`), and a worker that stops spinning wakes another.
- **Each task loops:** about `out_ns` of work outside (1 us), ask for the
  instance, an operation of about `cs_ns` on the instance's state, release,
  then yield to the back of its worker's queue (so all 64 tasks take part).
- **fifo:** an arrival takes the instance only if it's free and nobody waits.
  Release hands the still-held instance to the head waiter and puts it in the
  releasing worker's `runnext`, so it runs next on that core. That's the
  kindest placement for FIFO (no cross-core wake when it can be avoided), so
  this isn't a strawman.
- **barge:** release frees the instance and wakes the head waiter into
  `runnext` (at most one woken waiter outstanding, Go's `mutexWoken`). Any
  task may take a free instance; a woken waiter that loses requeues at the
  head, keeping its age. **Guard:** at release, if the head waiter has waited
  more than 1 ms (`--guard-us`), it gets a direct handoff, as in fifo. This is
  checked at release rather than by Go's "starving mode" flag; the bound is
  the same (1 ms plus one operation plus scheduling).
- **Not modelled:** spinning on the instance before parking (Go spins a few
  times; neither variant here does), `release` for one call, `Async.until`,
  `sim`'s tape. No thread pinning: macOS has none. All threads run at
  `QOS_CLASS_USER_INTERACTIVE`, which steers them to the 12 P-cores; at 16
  workers some run on E-cores.

## Measures

Throughput (operations a second; timed mode counts operations finished
before the stop flag), and wait: from asking for the instance to holding it,
including time parked and time runnable but not yet run. Waits go into a
log-linear histogram (16 sub-buckets a power of two, ~6% precision); clock is
`mach_absolute_time`, 41.7 ns a tick on Apple silicon, so waits under ~40 ns
read as 0 or 40. `guard_handoff_frac` is the share of operations that were a
guard handoff.

## Checks (every run)

The sum of every task's operations, the histogram's count and the instance's
counter agree; in fixed-ops mode (`--ops K`) the counter is 64·K for both
modes and both languages. The state words are the affine map
`x -> x*M + (j+1)` applied counter·rounds times, checked in closed form, so a
lost or torn update shows. The instance ends free with an empty queue; fifo
never takes a guard handoff. `run.sh --quick` also runs the C under
ThreadSanitizer (clean), with the guard at 50 us so the handoff path runs.

## Files

- `p3.c`: C implementation (clang -O2).
- `rust/src/main.rs`: Rust port (release, std only), same algorithm, same
  output line with `impl=rust`.
- `build.sh` (`--tsan` adds `bin/p3c_tsan`), `run.sh --quick` (smoke and
  checks), `run.sh` (full sweep: impl x cs_ns {100,500,2000} x workers
  {4,8,12,16} x mode, 5 reps of 1 s, ~4 min; env `REPS MS WORKERS CS OUT`).

Output, one line per configuration (medians over reps; max is the max):

    p3 impl=c mode=barge workers=12 tasks=64 cs_ns=200 out_ns=1000 reps=5 ops_per_s=1.12e+06 wait_p50_ns=320 wait_p99_ns=155648 wait_max_ns=184958 guard_handoff_frac=0.0000 ok=1

## Fidelity notes

- Operation lengths are calibrated loops; C and Rust land within ~3% for the
  operation and ~15% for the outside work.
- The smoke runs were on a loaded machine (other experiments running). Seen
  there, not measurements: at 4 workers the two modes are about equal and
  runs are bimodal (the instance saturates or doesn't); at 12 to 16 workers
  barge ran 2.5 to 3.5x fifo, with fifo's p50 wait 150 to 230 us against
  barge's ~0.3 us, but barge's p99 was close to fifo's.

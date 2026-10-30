# Spin budget for hops to a parked owner

Runtime phase 2. Under `per_core` an operation runs on its instance's home
core, and the caller hops. Phase 1 (P1) measured a hop at 105 to 385 ns
with both sides spinning and 4 to 8 µs with them parked. Neither is the
policy a runtime would ship. A real worker spins for a while, then parks.
This experiment sweeps how long it spins.

The question: which spin budget gives the lowest p99 hop latency without
burning more than X% CPU at idle-ish loads? And if no single budget serves
every load, which adaptive rule does?

Status: built and smoke-tested only. No timed run yet. The predictions
below were written before any measurement.

## Files

- `c/spin.c`: the harness. It reuses P1's code: the instance and `op_run`,
  Vyukov's MPSC inbox, the Dekker-style sleeping word and the ulock.
- `build.sh`: builds `bin/spin` (-O2) and `bin/spin_tsan`.
- `commands.sh`: prints the matrix, one config per line, in a fixed
  shuffled order.
- `measure.sh`: runs the matrix one config at a time, one process each.
- `analyze.py`: tables from a results file.
- `results/`: output. `tsan.log` is from the last TSan run.

## What the harness models

N workers, each one a `per_core` worker. Each worker is home to one
instance and runs one task. The task loops:

1. Sleep for an arrival gap. The gap is exponential with mean `--gap-ns`
   (0 means back to back). The worker is idle while its task sleeps.
2. Hop to a random other worker's instance. The message lives in the
   task's frame and is pushed on the owner's inbox. The owner runs the
   operation (`op_run`, calibrated to `--service-ns`) and writes the
   reply.
3. Wait for the reply.

A worker always serves its own inbox, also while its task waits for a
reply or sleeps. So two workers hopping to each other can't deadlock, as
in a real runtime. When a worker has nothing to do, it waits for an event:
a message, its reply, or its task's timer. That is where the policy comes
in. The worker spins up to a budget, checking for events, then parks on
its sleeping word (the ulock, with a timeout if a timer is due). Whoever
publishes an event (a push or a reply) wakes the worker if it is asleep.

There are two kinds of wait:

- **reply wait**: the task is blocked on a hop. The wait is roughly the
  service time plus the time to reach the owner.
- **idle wait**: the task is asleep. The wait ends at the next message or
  at the timer.

### Policies

| Policy | Rule |
|---|---|
| `fixed B` | spin B, then park. `--budget-ns` sets both kinds; `--reply-spin-ns` and `--idle-spin-ns` set one each. `inf` never parks |
| `ema` | glibc's adaptive mutex, in time: budget = min(cap, 2·ema + 100 ns), then ema += (min(wait, budget) − ema)/8. A parked wait counts as the full budget |
| `pred` | the proposed rule. An EMA of the true wait, per kind. "True" is timed to when the event happened (the reply finished, the message was pushed, the timer fell due), not to when a parked worker noticed it. Spin min(cap, 2·ema) if ema ≤ cap, else park at once. cap should be about the cost of a park and wake (Karlin's 2-competitive rule) |
| `go` | Go's gates. A reply wait spins up to cap only if another worker is awake (`sync.Mutex`'s "another P is running"). An idle wait spins up to cap only if 2·spinning < awake workers (`findrunnable`) |

For the adaptive policies `--budget-ns` is the cap.

### Output and checks

One line per run:

```
SPIN tag=run policy= reply_spin_ns= idle_spin_ns= service_ns= iters= gap_ns= workers=
     window_ms= hops= hops_per_s= hop_p50_ns= hop_p99_ns= hop_p999_ns= reach_p50_ns=
     reach_p99_ns= cpu_ns_per_hop= util= work_util= waste= spin_ns_per_hop= spin_hit=
     parks_per_hop= wakes_per_hop= csw_per_hop= checked_hops= ok|FAIL
```

- **hop**: from the push to the caller seeing the reply. It includes any
  inbox work the caller did meanwhile, as a real task's latency would.
- **reach**: from the push to the owner starting the operation, i.e.
  queueing plus wake-up.
- p50, p99 and p99.9 come from exact merged histograms (16 buckets per
  power of two, so about 6% resolution). Hops are counted only if they
  start in the 400 ms window, after 50 ms of warm-up.
- **cpu_ns_per_hop**: process CPU (getrusage, user + system) over the
  window, divided by the hops. Main sleeps during the window.
- **util** = CPU / (wall × workers). **work_util** = hops × service /
  (wall × workers). **waste** = util − work_util: the share of all
  workers' capacity spent on spinning, syscalls and switches.
- **spin_hit**: the share of waits that ended while spinning.
- **parks, wakes, csw per hop**: parks, wake syscalls, and context
  switches.

Each run checks:

- every reply equals mix64(token);
- each instance's op count and order-free token sum equal what the
  callers sent it;
- hops equal operations served;
- every inbox is empty at the end;
- no hang (the run fails if workers don't exit within 10 s of stop).

`--check` runs ten small configs across every policy. ThreadSanitizer is
clean on `--check` (`results/tsan.log`).

## The matrix (810 configs)

1. **Fixed sweep (450)**: budget ∈ {0, 100 ns, 500 ns, 1, 2, 5, 10, 20,
   50 µs, inf} × service ∈ {100 ns, 1 µs, 10 µs} × gap ∈ {0, 1, 5, 20,
   100 µs} × workers ∈ {2, 8, 16}.
2. **Which wait the spin pays on (90)**: reply-only (idle 0) and idle-only
   (reply 0), at service 1 µs and 8 workers, every finite budget and gap.
3. **Adaptive (270)**: `ema`, `pred`, `go` × cap ∈ {5, 20 µs} × the same
   45 service, gap and worker cells.

`analyze.py` picks, per cell, the budget with the lowest p99 among those
whose waste is at most X above budget 0's waste in the same cell. The
default X is 0.05, i.e. 5% of all workers' capacity; `--x` changes it.
"Idle-ish" means gap ≥ 20 µs. Then it asks which single budget is within
10% of that best p99 in most cells, and how each adaptive rule does.

## Why the comparisons are fair

- Every policy runs the same harness, the same queue, the same wake
  protocol and the same operation. Only `budget_for` and `learn` differ.
- Each config is its own process, run one at a time, in a fixed shuffled
  order, so drift on the shared machine doesn't line up with a budget.
- One calibration (`--calibrate`) is used for the whole run, so a
  service time means the same number of iterations everywhere.
- CPU, hops and latency all cover the same window.
- B = 0 is P1's `hop_park_both`, and inf is `hop_spin`, so both ends tie
  back to phase 1.
- Waste is relative to B = 0 in the same cell. Parking isn't free: in the
  smoke runs it cost about 2.5 to 7 µs of CPU per hop, in syscalls and
  switches.

## Predictions (written before measuring)

1. **B = 0** (park at once): hop p50 is 5 to 8 µs plus service, and p99
   is 10 to 15 µs, at every gap. That's two wake-ups per hop at idle, one
   for the owner and one for the caller. CPU is 3 to 8 µs per hop. Back to
   back at 2 workers and 100 ns, throughput is about 0.3 to 0.4 M hops/s.
2. **inf** (never park): hop p50 is 300 to 450 ns plus service at 2 and
   8 workers, and util is about 1.0 at every gap. At 100 µs gaps that is
   about 95% waste. At 16 workers, spinners outnumber the free P cores (E
   cores and other agents), and preemption pushes p99 to tens of µs.
3. **Reply waits** need a budget above service + reach (about 0.3 µs).
   p99 falls from about 10 µs to under 1 µs, plus service, at B = 500 ns
   to 1 µs for 100 ns service, at 2 µs for 1 µs service, and at 20 µs for
   10 µs service (10 µs is marginal, with about half the waits parking).
   Reply-only spin gives most of the gain back to back. Its cost is
   bounded by the service time, so its waste stays within X at every gap.
4. **Idle waits at 20 and 100 µs gaps**: a budget B keeps the owner awake
   for roughly a share 1 − exp(−B/gap) of arrivals. That is under 40% for
   every B ≤ 50 µs at a 100 µs gap. So p99 stays at the parked level
   (≥ 8 µs) for every finite budget, while waste grows about as B/gap per
   idle wait (about 10 to 20% at B = 10 µs, gap 100 µs). At idle-ish
   loads, no idle spin within X improves p99. The best admissible config
   is reply spin plus an idle spin of 0 to 1 µs.
5. **Gaps of 1 to 5 µs**: here idle spinning pays. B ≥ 2 × gap catches
   most arrivals, and p99 drops about 10×. It costs no more CPU than
   parking, because a park and wake costs about as much CPU as spinning
   through the gap. Spinning stops paying at about the park-and-wake CPU
   cost, a 5 to 10 µs gap.
6. **No single budget serves all.** The best fixed budget is 2 to 5 µs
   for 100 ns and 1 µs service back to back, about 20 µs for 10 µs
   service, and 0 to 1 µs for idle waits at 100 µs gaps. The best single
   budget (about 5 µs) is within 10% of the best p99 in only 50 to 60% of
   cells.
7. **Adaptive rules**:
   - `pred` at cap 5 µs is within 10% and within X in at least 80% of
     cells. Its misses are 10 µs service, where 2·ema exceeds the cap.
     Cap 20 µs fixes that but overspins at 5 to 20 µs gaps.
   - `ema` (glibc) overspins at idle-ish loads. Parked waits count as the
     full budget, so ema climbs to the cap, and it breaks X at 100 µs gaps.
   - `go` acts like B = 0 on idle waits at idle-ish loads (few awake, so
     no spinners), which is good for CPU. Its reply spin stays on while the
     owner is awake. It comes close to `pred`, with worse p99 at 5 to 20 µs
     gaps.
8. **Workers**: 2 and 8 workers behave alike per hop at idle. Back to
   back, 8 workers add queueing at the owner, since each worker gets about
   one hop per cycle. 16 workers reach the E cores: p99 is 1.5 to 3×
   worse, and spinning policies suffer most.
9. **reach p99** for a parked owner is 4 to 8 µs, P1's number.

**The rule this should support:** spin on a wait only if its predicted
length is under the cost of a park and wake (about 5 µs on macOS), and
then for twice the prediction. Predict each kind of wait (reply, idle)
separately, from when events happened. Reply waits nearly always qualify,
and idle waits qualify only under load.

## How to run

```
cd /Users/matthewdodd/Documents/code/ren/experiments/runtime-p2/spin
./build.sh                 # bin/spin (-O2), bin/spin_tsan
./measure.sh --quick       # --check, TSan --check, 3 short configs (smoke)
./measure.sh               # full matrix, one config at a time, ~8 min
./measure.sh --reps 3      # three passes, ~25 min (recommended)
python3 analyze.py results/full-<stamp>.txt            # X = 0.05
python3 analyze.py results/full-<stamp>.txt --x 0.10
```

A single config by hand:

```
./bin/spin --policy fixed --budget-ns 2000 --service-ns 1000 --gap-ns 20000 --workers 8 \
  --warm-ms 50 --window-ms 400 --ns-per-iter $(./bin/spin --calibrate)
./bin/spin --policy fixed --reply-spin-ns 2000 --idle-spin-ns 0 ...   # reply-only
```

Run the full mode alone. The machine is shared, and parked wake-ups move
by microseconds with load.

## Fidelity: what's uncertain

- **No pinning on macOS.** QoS user-interactive only steers threads
  toward P cores. 16 workers on 12 P cores will use E cores.
- **One task per worker.** A real worker blocked on a reply would run
  another task, not spin. So at high load the reply-spin numbers are an
  upper bound on CPU cost, and a lower bound on latency for workers with
  other work to do.
- **The timer is a timed ulock wait.** A real runtime's timer wheel would
  differ. Short timed parks on macOS overshoot, which stretches small gaps
  at B = 0. Gaps are untimed, so this changes throughput, not hop latency.
- **pred's event clock for messages** is the latest producer's push time,
  a single word on the producers' line. With several messages queued it
  overestimates the wait slightly.
- **C only.** P1 showed the C and Rust versions agree. The question here
  is policy, not language.

## Cloud machine (Linux) port

On Linux `c/spin.c` uses `clock_gettime(CLOCK_MONOTONIC)` (ticks are ns),
`FUTEX_WAIT/WAKE_PRIVATE` for the sleeping word, `pause` as the spin hint,
timer slack 1 ns (the 50 µs default would stretch every timed park), and pins
worker i to CPU i when there are at least as many CPUs as workers, so a caller
and its owner are never on one core. With more workers than CPUs nothing is
pinned (`pin=0` on the line). The cloud machine has 4 vCPUs, so
`measure-cloud.sh` runs the matrix with workers {2, 4, 8} and section 2 at 4
workers; 8 is oversubscribed by construction. See `results/README.md`.

```
./build.sh                                   # under flock -s
./measure.sh --quick                         # under flock -s; TSan log -> results/cloud/tsan.log
./measure-cloud.sh --shard 0/2               # each config under flock -x, 7 reps, re-runs, NOISY
./measure-cloud.sh --shard 1/2 --resume <stamp>
python3 analyze.py results/cloud/full-<stamp>.txt --wait-workers 4
```

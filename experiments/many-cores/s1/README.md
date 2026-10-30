# S1 (with S2 and a light S3): stripes against atomics

Phase one of the many-cores experiments (foundations.md, Staging). S1's question:
what does a hot counter's `add` cost at 1, 2, 4, 8, 12 and 16 workers when it's one
instance, stripes per worker (locked, and not), or a single atomic?
**Prediction: stripes 5x the others at 16.** S2 (padding stripes to 64 or 128 bytes)
is the `pad` axis. With `--reader 1`, a light S3: a merge's latency while workers write.

## What's modelled, and how it maps to Ren

| variant | Ren | what the prototype does |
|---|---|---|
| `one_lock` | one `counter()` handler shared by every task (decision 10) | instance = `{lock word, count}`. Taking the instance is a CAS on the word (acquire); letting go is a release store. Contended, it spins 128 times, then `sched_yield`s. Barging is allowed, so it's fair-not-FIFO **without** the starvation guard (P3 measures that). |
| `one_unfair` | the same, if waiters park in the OS | the same instance with `os_unfair_lock`. Not Ren's design (Ren parks tasks, not threads). It's a reference for "park instead of spin". |
| `atomic` | a `lockfree handler` with one `Atomic Int` field | `fetch_add` seq_cst (decision 10 makes lockfree ops sequentially consistent). On the M4 this is `ldaddal`. |
| `stripe_lock` | `striped(counter(), by: Worker, merge: Sum)` under `work_stealing` | one locked instance per worker, at `pad` bytes apart. The worker's add takes its own stripe's lock, which is uncontended except when the merge takes it. |
| `stripe_owner` | the same under `per_core`: "a stripe per core, never locked across threads" | the owner does a relaxed load plus a relaxed store (no read-modify-write, no lock). The merge reads each stripe with an acquire load. That's race-free and TSan-clean. |

- **The merge** (the keyless `get`, `merge: Sum`) visits the stripes in stripe order.
  For `stripe_lock` it takes each stripe's instance in turn, as an operation on a stripe
  does. For `stripe_owner` it does a plain load. As decision 18 says, it isn't an atomic
  snapshot. The single-instance variants read under their lock, or with one load.
- **Padding (S2).** `pad=0` packs the stripes at their natural size: 16 B for locked
  (8 to a 128 B line) and 8 B for owner-only. `64` and `128` give each stripe that
  many bytes. **The M4's cache line is 128 B** (`hw.cachelinesize`), so on this machine
  64 is still false sharing between pairs.
- **Workers** are OS threads, one per worker, all started together behind a barrier.
  Each runs `add` in a loop and checks the stop flag every 256 adds. `--work K`
  puts K steps of register-only work between adds (default 0, which is the worst case
  for contention).
- **Cores.** Every thread sets `QOS_CLASS_USER_INTERACTIVE`, which macOS prefers to
  schedule on P cores. There's no pinning. There are 12 P cores and 4 E cores, so the
  12- and 16-worker runs include E cores. With `--reader 1` there's one extra thread,
  so 16 workers plus the reader is 17 threads on 16 CPUs.
- **Timing.** Throughput is (sum of every worker's adds) / (wall time from the
  barrier's release to the last join), in million adds a second. Each merge is timed
  with `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` (C) or `Instant` (Rust). Both tick at
  24 MHz, so **merge p50/p99 are quantized to about 41.7 ns**. `read_mean_ns` (the
  reader's wall time divided by its merges) is the finer number for short merges.

## Checks (every run)

- The merge after the join equals the sum of the adds each worker counted for itself.
- Each stripe's count equals its own worker's adds (the split law, `by: Worker`).
- With a reader: successive merges never go backwards, and none exceeds the final total.
- `run.sh --quick` also runs every variant once under `-fsanitize=thread` (C, 4
  workers plus the reader). Any failure makes the binary exit non-zero and the run
  print `QUICK FAILED`.

## Build and run

```
./build.sh          # bin/s1_c (clang -O2), bin/s1_c_tsan, bin/s1_rust (cargo --release, LTO, no deps)
./run.sh --quick    # smoke: all variants x {1,4,16} workers x reader {0,1}, 20 ms, both langs, plus TSan (~11 s)
./run.sh            # full: also tees to results/s1-<timestamp>.txt
```

The full run covers 2 languages × reader {0, 1} × 9 variant/pad configurations × 6
worker counts = 216 lines. Each line is `REPS` (7) runs of `MS` (300) ms, so it takes
about 8 minutes. Run it alone on the machine. You can override `REPS`, `MS`, `WORKERS`,
`LANGS`, `READER` and `WORK` from the environment. One binary call also works:
`bin/s1_c --variant stripe_lock --pad 128 --workers 8 --reps 7 --ms 300 --reader 1`.

## Output

There's one line per configuration, as space-separated `key=value` pairs:

```
exp=s1 lang=c variant=stripe_lock pad=128 workers=16 reader=1 work=0 reps=7 ms=300 mops_median=... mops_min=... mops_max=... read_p50_ns=... read_p99_ns=... read_mean_ns=... ok=1
```

`mops_*` are the median, min and max over the reps of total adds a second (millions).
The `read_*` fields appear only with `reader=1`: each is the median over the reps of
that rep's merge-latency p50, p99 and mean. `pad` is 0 for the non-striped variants.

## Fidelity caveats

- **No tasks.** A worker is a thread, and a contended `one_lock` spins and yields
  rather than parking a task and running another. So the single instance is a
  *thread-lock* model of decision 10's queue. Its cost under contention (cache-line
  ping-pong on the lock word and the count) is the part S1 is about. The task queue's
  extra cost belongs to P1 and P3.
- **The Ren lock** has no starvation guard and no waiter queue, so it's the
  barging-only end of "fair, not FIFO".
- **Stripes made on their worker** (S4, and the `work_stealing` row of decision 18)
  aren't modelled. The stripes live in one 128-aligned block, with `pad` as the only
  layout knob. On the M4's unified memory, only line separation should matter.
- **The add with zero work** is the best case for stripes and the worst for one
  instance. Use `WORK=` to see how the ratio narrows.
- **The C and Rust codegen differ** on the owner-only loop: Rust's single-worker
  owner-only add comes out faster. Compare variants within one language.
- Early smoke numbers (20 ms, meaningless as measurements) already show the
  prediction's direction, but with ratios far above 5×. At pad 0, false sharing
  collapses stripes to near `atomic`'s throughput.

# Many-cores phase one: independent verification

This file checks RESULTS.md. I read every experiment's sources against foundations.md
decisions 10 and 18 and compiler.md's "The runtime model", then re-ran each
headline configuration on the same M4 Max, on 2026-10-29 between 19:22 and 20:06.

- **How it ran:** one job at a time. Before each job the driver waited for the
  1-minute load to reach 3 or below. Every job started at a load of 2.4 to 2.9.
- **Scripts:** `verify-run.sh` and `verify-run2.sh` (the second pass). Their logs are
  `verify-driver.log` and `verify-driver2.log`.
- **Output:** raw files and logs are in `<id>/verify/`. Nothing in `results/` was
  touched.
- **Threads:** every thread runs at `QOS_CLASS_USER_INTERACTIVE`, as in the originals.
- **Checks:** every configuration printed `ok=1`.

**Noise.** Other agents kept starting jobs during the runs. The load at the end of a
job reached 9 to 12, and 41 once, during S1. Absolute throughput moves 30 to 50%
between passes. For example, K3 edge at 8 workers measured 6.7 M/s, then 4.7 M/s.
Ratios between variants within one pass are stable to about 10%. Read the absolute
numbers here and in RESULTS.md as ±40%, and compare ratios.

## Fidelity

I found no strawman, and no variant does less work than another. Synchronisation is
correct: the originals pass TSan, and so do my copies. The models match the documents:

- **K3:** Lean-encoded counts, rule U, rule M, and per-thread heaps with remote frees.
- **P1:** the hop is a message on a home core's MPSC queue.
- **P3:** a Go-shaped scheduler, with FIFO handoff placed in `runnext`.
- **S1:** stripes per worker, merged in stripe order.
- **K1 and cache3:** partitions with a lock, a map, an exact LRU by release, and a cap
  of max/parts. Pins are under the partition lock, and the actor's lock is taken for
  each call.

I tested two places where a model might have been unfair:

1. **K3's lock.** RESULTS.md calls the `os_unfair_lock` column "the Ren model". It isn't
   decision 10's lock. Under contention `os_unfair_lock` parks the waiters at once and
   lets the releasing thread take the lock again. In effect one thread runs, so the
   shared variant's 48 cache lines rarely move between cores.
   - Decision 10 describes Go's mutex instead: barging, a short spin, then park.
   - `k3/verify/k3_hybrid.c` adds that lock (`--lock hybrid --spin N`, using an
     os_sync ulock). It also raises the 62 limit on `--subs-cap` and `--chunks`, which
     came from the 64-word size classes.
2. **P3's FIFO.** The original wakes another worker when it puts the handed-off task in
   `runnext`. That wake happens while the instance is owned by a task that isn't
   running yet.
   - `p3/verify/p3_fixed.c --runnext-nowake 1` skips that wake in both modes.
   - **The result didn't change (within 9%), so P3 was fair.**

## Results

**K3: the conclusion holds, but its size doesn't.**
- At 8 workers, edge/shared was 1.73× with `os_unfair_lock` (the original measured
  1.67×), 1.16× with spin (original 1.31×), and 13.8× with Rust's Mutex (original
  12.9×).
- With the Go-shaped lock it was 7.8× and 6.5× in two passes at a spin budget of 64,
  and 6.7× and 6.4× at a budget of 1000. At 16 workers it was 12 to 15×.
- With `os_unfair_lock`, the ratio grows with state size:
  - 1.4 to 2.0× at 8 subs;
  - 1.7 to 2.9× at 32 subs;
  - 7.1 to 9.6× at 128 subs.
- With the Go-shaped lock it is 4.1 to 10× across the whole size grid.
- At 1 worker it is 8.3×.
- Edge wins in every cell.
- **Correction:** "1.5 to 2× in Ren's model, not 3×" doesn't hold. The ratio depends on
  the lock: 1.2 to 1.7× with locks that serialise onto one thread, and 6 to 8× with
  decision 10's barging spin-then-park lock. The prediction of 3× is met or exceeded
  under the lock decision 10 describes. Marking at the edge stands, more firmly than
  RESULTS.md says.

**P1: holds.**
- Taking the instance costs 0.5 to 0.7 ns over a call.
- A spinning hop costs 105 to 385 ns.
- A parked hop costs 5.7 to 8.2 µs from cold (original 7.0 to 7.5 µs) and 3.9 to
  5.5 µs with both sides parked. That is 2.9 to 4× the predicted 2 µs.

**P3: throughput holds, and one claim about tails is wrong.**
- Barge/fifo in C, second pass:
  - 1.98× at 100 ns and 8 workers;
  - 3.42× at 12 workers;
  - 4.03× at 16 workers;
  - 1.97× at 500 ns and 12 workers.

  These are close to the original 1.9, 3.5, 3.7 and 2.0. The first pass ran under load
  of up to 11.5, so I set it aside.
- **Correction:** "barging's p99 wait is never worse than FIFO's" is false. At 4 to 8
  workers barging's p99 is worse, and the original data already showed it:

  | case | barge p99 | fifo p99 | source |
  |---|---|---|---|
  | 8 workers, 100 ns | 115 µs | 102 µs | my rerun |
  | 8 workers, 100 ns | 123 µs | 106 µs | original |
  | 8 workers, 500 ns | 139 µs | 115 µs | original |
  | 4 workers | 0.25 µs | 0.12 µs | original |

  Barging's p99 is better only at 12 to 16 workers. Its p50 is better everywhere.

**S1: holds.**
- With no work between adds, padded stripes at 16 workers ran at 4156 to 4806 M/s,
  against `atomic`'s 17.6 to 18.3. That is 236 to 263×, not "400×".
- With 100 steps of work between adds:
  - C: 7.4× (original 8.0×);
  - Rust, locked stripes: 2.8× (original 3.3×);
  - Rust, stripes only their owner writes: 3.7× (original 4.7×).
- S3, the merge with a reader running:
  - locked stripes took 0.34 to 0.58 ms. The original C figure was 2.1 to 3.1 ms, so
    read it as "a fraction of a millisecond to milliseconds".
  - stripes only their owner writes took 0.54 to 0.61 µs;
  - `atomic` took 0.25 µs.
- C `one_lock` at 16 workers measured 244 M/s, which is the barging artifact RESULTS.md
  already notes.

**K1: holds.**
- 64 partitions with uniform keys at 16 workers gave 34 to 40 M/s, against 79 to 129 at
  1 worker.
- Under Zipf, 64 partitions gave 5 M/s with the spin lock and 14 M/s with the OS lock.
- Rust is within 10% of C.

**K2: holds exactly.** The rerun is identical to the original, and C equals Rust.

**cache3: the ranking holds, and the margins are larger.**
- With the 50 µs fetch at 16 workers, `striped16` gave 11.6 M/s (C) and 12.0 M/s (Rust).
- `one` gave 4.1 to 4.3 M/s, so `striped16` is 2.7 to 2.8× `one` (original 2.1×).
- `actors_p16` and `actors_p64` gave 7.2 to 8.9 M/s, so `striped16` is 1.3 to 1.6×
  `actors` (original 1.2 to 1.35×).
- moka gave 3.3 M/s, so `striped16` is 3.6× moka (original 2.7×).
- `one_hold` gave 1.0 to 1.1 M/s.
- With no fetch, `actors` costs 19% more than `striped` on a single hit (24.8 against
  30.5 M/s), against 20% in RESULTS.md.

**Minor.** In cache3, the prefill for `striped` evicts each overfull stripe's hottest
keys, because keys are prefilled hottest first. `actors` skips the extra keys instead.
The effect is under 1% of operations, and it goes against `striped`, which wins anyway.

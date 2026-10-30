# Many-cores phase one: results

Apple M4 Max (12 P + 4 E cores, 16 logical CPUs), macOS 15 (Darwin 24.1).
Everything was run on 2026-10-29 between 17:01 and 19:08, one job at a time,
by `run-serial.sh`. The driver's own log is `serial-driver-20261029.log`.

Every thread asks for `QOS_CLASS_USER_INTERACTIVE`. That steers threads
toward the performance cores but doesn't pin them, since macOS has no
pinning API. Runs with 13 to 16 workers use efficiency cores.

Raw output for each experiment is in `<id>/results/*-20261029-165750.txt`.
The `.log` next to each file records the command, the load average at start
and at end, and the duration.

Every configuration in every run printed `ok=1`, or passed its checks.

## Load, and how much to trust it

The machine was shared with other agents and a browser. Before each job the
driver waited, up to 15 minutes, for the 1-minute load average to drop to 3
or below.

The load average at the end of each job mostly reflects the job's own 16
threads. The figure that tells you about other work is the load at start.

| job | load at start (1/5/15 min) | duration | note |
|---|---|---|---|
| k3 full | 2.69 / 4.40 / 3.79 | 370 s | |
| k3 state size | 2.78 / 4.53 / 4.85 | 196 s | |
| p1 full (11 reps) | 2.44 / 4.22 / 4.77 | 83 s | |
| p3 full (7 reps) | 2.84 / 4.00 / 4.64 | 358 s | |
| s1 full (7 reps) | 3.20 / 4.50 / 5.24 | 552 s | ran anyway after the 15-minute wait |
| s1 WORK=100 | 5.27 / 5.19 / 6.21 | 134 s | ran anyway after the 15-minute wait, the noisiest start |
| k1k2 full (7 reps) | 4.74 / 5.32 / 6.03 | 307 s | ran anyway after the 15-minute wait |
| cache3 full (7 reps) | 6.27 / 5.84 / 6.06 | 284 s | ran anyway after the 15-minute wait |
| cache3 `--fetch-us 0` | 4.98 / 4.78 / 5.82 | 112 s | ran anyway after the 15-minute wait |

The background load was a browser plus other agents, about 1 to 3 cores. The
runs at 12 and 16 workers are the ones it affects: there, a busy core can't
be avoided.

---

## K3, marking

**Prediction:** at 8 workers, marking only at the edge gives 3× the
operations a second of marking all shared state. This decides decision
10's open question.

**Results,** in Mops/s, median of 7 runs of 1 s. The defaults are 32 subs
and 16 chunks of 64 bytes.

| workers | C edge (unfair) | C shared (unfair) | ratio | C ratio (spin) | Rust edge (Mutex) | Rust shared (Arc, Mutex) | ratio | Rust ratio (spin) |
|---|---|---|---|---|---|---|---|---|
| 1 | 38.6 | 4.75 | 8.1× | 8.5× | 23.2 | 5.40 | 4.3× | 4.7× |
| 2 | 17.3 | 2.41 | 7.2× | 1.7× | 14.8 | 3.38 | 4.4× | 1.1× |
| 4 | 8.78 | 2.83 | 3.1× | 1.2× | 5.93 | 0.74 | 8.1× | 0.78× |
| **8** | **4.82** | **2.88** | **1.67×** | 1.31× | **4.76** | **0.37** | **12.9×** | 1.0× |
| 12 | 6.05 | 2.88 | 2.10× | 2.66× | 5.89 | 0.38 | 15.7× | 1.5× |
| 16 | 4.21 | 2.88 | 1.46× | 2.77× | 4.70 | 0.30 | 15.4× | 1.5× |

**State size at 8 workers.** Rows give subs, columns give chunks; each cell
is the edge/shared ratio.

| subs \ chunks | C (unfair): 4 | C: 16 | Rust (Mutex): 4 | Rust: 16 | Rust: 64 |
|---|---|---|---|---|---|
| 8 | 2.25× | 1.66× | 6.0× | 11.3× | 10.1× |
| 32 | 1.80× | 1.72× | 13.8× | 13.1× | 12.5× |
| 128 | — | — | 15.6× | 14.2× | 12.9× |

The C binary refuses `--subs-cap` or `--chunks` above 62, a limit built into
the harness. Those cells printed usage and are missing; they weren't
rerun.

**Did it hold?**
- **Not in the Ren model (C): 1.67× at 8 workers, against the predicted 3×.**
  Edge wins at every worker count and every state size, and wins by 8× with
  one worker.
- Under contention, both variants are limited by the lock. With the unfair
  lock, `shared` levels off at 2.88 M/s from 4 to 16 workers.
- **Rust's `Arc`, never changed in place, far exceeds the prediction:
  13× at 8.** Its `shared` path contends on the system allocator. Ren's
  heap per thread avoids that, so this ratio overstates what Ren would see.
- **Noisy:**
  - The spin-lock rows are unstable: C spin is non-monotonic, and Rust spin
    is about 1× from 2 to 8 workers.
  - C edge with the unfair lock rises from 4.8 at 8 workers to 6.0 at 12.
    This looks like barging changing who holds the lock.
  - `os_unfair_lock`'s p99 is in the tens of µs in every row.
- **Reading:** marking at the edge is the better choice. Its advantage
  under contention is about 1.5 to 2× in Ren's model, not 3×.

## P1, the cost of a hop

**Prediction:** taking the instance costs 5 to 20 ns over a call. A hop
costs about 300 ns with the home core spinning and about 2 µs with it
parked.

**Results:** overhead over `call`, in ns, median of 11 reps.

| variant | C, 0 ns work | C, 100 ns | C, 10 µs | Rust, 0 ns | Rust, 100 ns | Rust, 10 µs | p50 at 0 ns work (C / Rust) |
|---|---|---|---|---|---|---|---|
| take | 0.85 | ~0 | 0.26 | 1.13 | 0.12 | ~0 | 0 / 0 |
| hop_spin | 243 | 205 | 174 | 313 | 216 | 183 | 333 / 333 |
| hop_park (warm, back to back) | 457 | 359 | 383 | 543 | 444 | 365 | 2750 / 542 |
| hop_park_cold (home core asleep) | 7005 | 7451 | 7039 | 7479 | 7339 | 7405 | 6750 / 6708 |
| hop_park_both | 4952 | 4827 | 6086 | 4992 | 4785 | 6169 | 4667 / 4708 |
| hop_condvar | 4997 | 4881 | 6547 | 4971 | 5063 | 6710 | 4875 / 4875 |

**Did it hold?**
- **Taking: yes, and cheaper than predicted.** It costs 0 to 3 ns, against
  the predicted 5 to 20 ns. That is the best case, with the lock word
  staying in this core's cache.
- **Spinning hop: yes.** It costs 170 to 310 ns against the predicted
  ~300 ns, and less with more work, as the hop overlaps it.
- **Parked hop: no.** Waking a home core that is really asleep costs about
  7 µs, 3.5× the predicted 2 µs.
  - Waking with both sides parked, or through a condvar, costs about 5 µs.
  - Back-to-back parking costs only ~0.4 to 0.5 µs on average, because the
    thread hasn't really slept.
  - C `hop_park`'s p50 of 2.75 µs, against its mean of 0.46 µs, shows it
    is bimodal.
- **Reading:** a scheduler should spin before it parks. Parked wakeups on
  macOS cost 5 to 7 µs.

## P3, handing off against barging

**Prediction:** strict FIFO handoff gives about 3× less throughput than
barging with a 1 ms starvation guard. There are 64 tasks on one instance.

**Results:** throughput in Mops/s (median of 7 runs of 1 s), barge/fifo
ratio, and p50/p99 wait in µs. Outside work is 1000 ns.

| op (cs) | workers | C fifo | C barge | C ratio | Rust ratio | C wait p50 fifo / barge | C wait p99 fifo / barge |
|---|---|---|---|---|---|---|---|
| 100 ns | 4 | 3.31 | 3.30 | 1.0× | 1.0× | 0.04 / 0.04 | 0.12 / 0.25 |
| 100 ns | 8 | 0.77 | 1.47 | 1.9× | 2.1× | 78 / 0.37 | 106 / 123 |
| 100 ns | 12 | 0.39 | 1.37 | **3.5×** | **4.2×** | 156 / 0.32 | 238 / 131 |
| 100 ns | 16 | 0.32 | 1.18 | **3.7×** | **4.3×** | 188 / 0.29 | 410 / 172 |
| 500 ns | 4 | 1.22 | 1.21 | 1.0× | 1.0× | 49 / 51 | 53 / 55 |
| 500 ns | 8 | 0.66 | 0.88 | 1.3× | 1.6× | 94 / 106 | 115 / 139 |
| 500 ns | 12 | 0.40 | 0.82 | 2.0× | 2.6× | 147 / 115 | 221 / 164 |
| 500 ns | 16 | 0.32 | 0.57 | 1.8× | 2.4× | 188 / 139 | 377 / 221 |
| 2000 ns | 4–16 | 0.36–0.44 | 0.36–0.44 | 1.0–1.04× | 0.96–1.1× | ~140–170 both | ~155–210 both |

The guard handed over at most 0.04% of releases at 1 ms. The worst single
wait was 29 ms, in Rust's fifo at 16 workers and C's barge at 16.

**Did it hold?**
- **Partly.** Barging gives the predicted 3× or more only for short
  operations (100 ns) at 12 or more workers: 3.5 to 4.3×.
  - At 500 ns it gives 1.3 to 2.6×.
  - At 2 µs it makes no difference, since the instance is saturated either
    way.
  - At 4 workers, 1.0× everywhere.
- **Tail latency:** barging's p99 wait is never worse than FIFO's, and is
  often better. Its p50 drops from hundreds of µs to about 0.3 µs.
- **Reading:** barging plus a guard should be the default. It is never worse.

## S1, stripes against atomics (and S2 padding, S3 merge)

**Prediction:** at 16 workers, stripes give 5× the throughput of the
others.

**Results, no work between adds:** Mops/s, median of 7 runs of 300 ms, no
reader.

| variant | C, 1 worker | C, 8 | C, 16 | Rust, 1 | Rust, 8 | Rust, 16 |
|---|---|---|---|---|---|---|
| one_lock (CAS, spin then yield) | 550 | 25.6 | 110.6* | 567 | 12.2 | 6.8 |
| one_unfair | 287 | 79.5 | 106.6 | 323 | 100 | 85.8 |
| atomic (seq_cst add) | 371 | 16.4 | 12.0 | 371 | 16.8 | 15.1 |
| stripe_lock, pad 0 | 541 | 22.8 | 25.4 | 530 | 34.2 | 26.8 |
| stripe_lock, pad 64 | 540 | 2278 | 2492 | 534 | 2301 | 2855 |
| stripe_lock, pad 128 | 539 | 3806 | **4775** | 532 | 3408 | **5038** |
| stripe_owner, pad 0 | 849 | 5966 | 7823 | 1169 | 8554 | 3347† |
| stripe_owner, pad 128 | 844 | 6203 | **8531** | 1155 | 7711 | **9721** |

\* C `one_lock` jumps at 16 workers because the spin-then-yield lock barges:
one thread re-takes the lock repeatedly. It's an artifact of unfairness, not
a scaling result.

† Rust `stripe_owner` at pad 0 and 16 workers varied widely. Pad 64 gave
7810.

**Results with WORK=100 between adds:** a dependent chain of 100 steps, a
more realistic gap between adds. 7 reps.

| variant | C, 16 | Rust, 16 | C ratio to atomic | Rust ratio to atomic |
|---|---|---|---|---|
| one_lock | 9.07 | 2.08 | 0.7× | 0.18× |
| one_unfair | 7.19 | 5.28 | 0.6× | 0.45× |
| atomic | 13.0 | 11.7 | 1× | 1× |
| stripe_lock, pad 0 | 25.2 | 18.4 | 1.9× | 1.6× |
| stripe_lock, pad 128 | 104.0 | 38.9 | **8.0×** | **3.3×** |
| stripe_owner, pad 128 | 103.0 | 55.1 | **7.9×** | **4.7×** |

Workers at 1 worker: C 6.5, Rust 2.6 to 3.8 Mops/s. Rust's busy loop compiles
slower, so compare variants within one language.

**Merge latency (S3):** `read_mean_ns` at 16 workers, with the reader on.
- `atomic`: 342 ns (C).
- `stripe_owner`: 0.76 to 2.3 µs.
- `stripe_lock`: 2.1 to 3.1 ms in C, and 0.14 to 0.55 ms in Rust. Taking 16
  contended stripe locks in turn starves the reader.

**Did it hold?**
- **Yes, and by far more than predicted when padded.**
  - With no work between adds, padded stripes give 400× `atomic` and 43×
    `one_lock` or `one_unfair`.
  - With 100 steps of work between adds, the ratio is 3.3 to 8×, around the
    predicted 5×.
- **S2:**
  - Stripes at pad 0 are no better than one atomic.
  - Pad 64 isn't enough on the M4, whose cache line is 128 bytes: it gives
    50 to 80% of pad 128.
  - **Pad 128 is required.**
- **S3:**
  - Merging locked stripes while workers write costs milliseconds.
  - Stripes only their owner writes merge in about 1 µs.

## K1 and K2, partitions

**Prediction for K1:** none numeric. It measures the cost of `at` on a hit,
and how that scales with 1, 8 and 64 partitions.

**K1 results:** Mops/s, median of 7 runs of 200 ms, 10k keys. The p99 of one
`at` is in ns.

| lock / dist | parts | 1 worker | 8 workers | 16 workers | p99 at 8 | p99 at 16 |
|---|---|---|---|---|---|---|
| C spin, uniform | 1 | 107 | 4.48 | 0.84 | 26.8 µs | 630 µs |
| C spin, uniform | 8 | 106 | 12.0 | 6.98 | 5.3 µs | 35.8 µs |
| C spin, uniform | 64 | 121 | 38.5 | 25.1 | 0.88 µs | 2.4 µs |
| C os, uniform | 1 | 66 | 6.55 | 7.64 | 30 µs | 49 µs |
| C os, uniform | 64 | 65 | 38.3 | 26.7 | 1.5 µs | 3.4 µs |
| C spin, zipf | 64 | 114 | 11.3 | 5.44 | 10 µs | 45 µs |
| C os, zipf | 64 | 66 | 13.3 | 13.9 | 9.1 µs | 25.5 µs |
| Rust spin, uniform | 64 | 116 | 39.4 | 28.7 | 0.83 µs | 2.2 µs |
| Rust os, zipf | 64 | 67 | 15.4 | 14.0 | 8.5 µs | 27 µs |

The full grid is in the raw file. Rust is within ±10% of C everywhere.

**K1 findings:**
- **An uncontended hit costs** about 8 to 9 ns with the spin lock and about
  15 ns with `os_unfair_lock`. That is three lock takes: pin, call, unpin.
- **Partitions:** 64 partitions give 6 to 30× the throughput of one under
  uniform keys.
  - **Even so, every multi-worker configuration's total throughput is below
    one worker's.** The partition lock's cache line moves between cores on
    every hit.
  - **Zipf(1.1):** 64 partitions barely help (5 to 15 Mops/s), because the
    hot keys share a few partitions and their actors.
  - At 16 workers on Zipf, the spin lock collapses to 5 Mops/s; the OS lock
    holds 14.

**Prediction for K2:** under uniform keys, a cap per partition wastes under
2% against one global cap.

**K2 results:** extra misses, as a percentage of all accesses.

| dist | max | parts | universe = max | 1.1 × max | 1.25 × | ≥ 1.5 × |
|---|---|---|---|---|---|---|
| uniform | 1k | 8 | 3.53 | 0.25 | ~0 | ~0 |
| uniform | 1k | 64 (caps 15–16) | **8.52** | **4.31** | 1.74 | ≤ 0.2 |
| uniform | 10k | 8 | 1.41 | 0.06 | ~0 | ~0 |
| uniform | 10k | 64 | **3.64** | 0.60 | ~0 | ~0 |
| uniform | 100k | 8 | 0.30 | ~0 | ~0 | ~0 |
| uniform | 100k | 64 | 0.87 | ~0 | ~0 | ~0 |
| zipf | 1k | 64 | 0.98 | 1.08 | 0.76 | 0.31–0.39 |
| zipf | 10k | 64 | 0.09 | 0.18 | 0.08 | ≤ 0.04 |
| zipf | 100k | 8 or 64 | 0 | ≤ 0.01 | ≤ 0.01 | ≤ 0.003 |

C and Rust agree exactly. K2 is deterministic and has no timing.

**Did it hold?**
- **Yes, everywhere except where the working set is about max and
  max/parts is small.**
  - When the key universe is 1.5 × max or larger, the waste is at most
    0.2%.
  - At universe = max, the per-partition cap misses 1.4 to 8.5% of
    accesses, while the global cap misses none. The exception is 100k,
    where it misses under 1%.
- The waste tracks max/parts: caps of about 15 are bad, and caps of 1.5k or
  more are fine. The default for `parts:` should keep max/parts at least in
  the hundreds.

## The same cache three ways

**Prediction:** none numeric. It compares throughput and p99 at 1 to 16
workers against Rust's `dashmap` and `moka`.

**Results with a 50 µs fetch (spin), 20k keys, Zipf(1.1), cap 16k:**
Mops/s, median of 7 reps. The p99 over hits only is in µs.

| variant | 1 worker | 4 | 8 | 16 | hit % at 16 | p99 at 16 | p99 of hits at 16 |
|---|---|---|---|---|---|---|---|
| C one_hold | 0.82 | 1.01 | 1.06 | 1.10 | 98.3 | 50.7 µs | 0.37 |
| C one | 0.82 | 3.90 | 5.53 | 5.48 | 98.8 | 53.8 µs | 29.4 |
| C striped16 | 0.77 | 3.89 | 7.50 | **11.6** | 98.5 | 50.2 µs | **2.4** |
| C striped_hold16 | 0.77 | 1.58 | 2.25 | 3.43 | 98.9 | 78.8 µs | 76.8 |
| C actors_p16 | 0.90 | 4.02 | 7.09 | 9.82 | 98.5 | 50.7 µs | 9.7 |
| C actors_p64 | 0.92 | 4.04 | 7.26 | 8.60 | 98.7 | 50.7 µs | 14.7 |
| Rust striped16 | 0.77 | 3.79 | 7.60 | 11.4 | 98.5 | 50.2 µs | 2.2 |
| Rust actors_p16 | 0.90 | 4.01 | 6.94 | 8.28 | 98.5 | 50.7 µs | 20.2 |
| Rust one_hold | 0.82 | 0.98 | 1.03 | 1.09 | 98.9 | **246 µs** | 246 |
| Rust dashmap (unbounded) | 2.11 | 15.4 | 31.4 | 23.1 | **99.85** | 8.4 µs | 7.5 |
| Rust moka | 0.77 | 3.51 | 4.82 | 4.22 | 98.5 | 55.3 µs | 26.6 |

**Results with `--fetch-us 0`,** which measures only the structure's own
cost. Mops/s.

| variant | C, 1 worker | C, 8 | C, 16 | Rust, 1 | Rust, 8 | Rust, 16 |
|---|---|---|---|---|---|---|
| one / one_hold | 45.0 / 45.4 | 5.0 / 5.6 | 6.4 / 6.9 | 44.5 / 44.2 | 2.9 / 3.3 | 5.0 / 5.1 |
| striped16 | 45.9 | 13.6 | **15.4** | 42.8 | 11.1 | 12.5 |
| actors_p16 | 37.3 | 9.6 | 9.6 | 32.9 | 5.3 | 7.1 |
| actors_p64 | 35.9 | 9.6 | 11.4 | 33.8 | 6.6 | 9.0 |
| dashmap | — | — | — | 49.6 | 27.8 | 20.5 |
| moka | — | — | — | 8.8 | 4.6 | 5.3 |

**Findings:**
- **Holding the lock across a fetch is the disaster case.**
  - `one_hold` stays flat at about 1.1 Mops/s from 1 to 16 workers.
  - Rust's `one_hold` has a p99 of 246 µs.
  - `striped_hold` reaches only 3.4 Mops/s.
- **`striped` by key is the best Ren design here:**
  - 11.6 Mops/s at 16 workers;
  - 2.1× the single handler that releases the lock for the fetch;
  - 1.2 to 1.35× `actors`;
  - 2.7× moka;
  - the best p99 over hits, 2.4 µs.
- **`actors` costs about 20% more on a single uncontended hit** (37 against
  45 Mops/s with no fetch). That is the three lock takes K1 also shows.
  Under contention it reaches 60 to 75% of `striped`'s throughput.
- **`actors` coalesces misses, so it fetches fewer times.** At one worker
  this puts it ahead on throughput: 0.90 against 0.82.
- **dashmap is not like-for-like.** It is unbounded, so its hit rate is
  99.9% against about 98.5%, and it skips most fetches. With no fetch it
  is 1.3 to 1.6× `striped16`, which shows the gap between Ren's model and a
  sharded concurrent map without LRU.
- **Noisy:**
  - dashmap fell from 31 Mops/s at 8 workers to 23 at 16.
  - The rows at 16 workers include efficiency cores and the background load
    (6.3 at start).
- **p99 overall is about 50 µs in every variant.** The fetch sets it, so read
  the p99 over hits instead.

---

## Summary against foundations.md's predictions

| experiment | predicted | measured | held? |
|---|---|---|---|
| K3 | edge 3× shared at 8 workers | C (Ren model): 1.67× (1.3 to 2.3× across lock and state size); Rust `Arc`: 13× | **No** for Ren's model. Edge still wins everywhere, so the edge marking stands. |
| P1, take | 5 to 20 ns over a call | 0 to 3 ns | yes, better than predicted |
| P1, hop spinning | about 300 ns | 170 to 310 ns | yes |
| P1, hop parked | about 2 µs | about 7 µs from cold; 5 µs with both sides parked | **no, 3.5×** |
| P3 | barge plus 1 ms guard 3× fifo | 3.5 to 4.3× at a 100 ns op with 12 or more workers; 1.3 to 2.6× at 500 ns; 1× at 2 µs or 4 workers | partly: holds for short ops under heavy contention, and barging is never worse |
| S1 | stripes 5× the others at 16 | 3.3 to 8× `atomic` with work between adds; 400× with none (pad 128) | yes, and only with 128-byte padding |
| K2 | cap per partition wastes under 2% on uniform keys | ≤ 0.2% when the universe is at least 1.5 × max; 1.4 to 8.5% at universe = max with small caps | yes, except at universe ≈ max with max/parts ≤ 1.5k |
| K1, cache3 | none numeric | see above | 64 partitions never beat one worker's throughput; `striped` beats `actors` by 1.2 to 1.6× |

## Harness notes

- Every run completed. No harness bug stopped a run, and nothing was
  changed.
- The C binary of K3 accepts `--subs-cap` and `--chunks` only up to 62.
  The state-size cells with 64 chunks or 128 subs therefore have Rust only.
- `s1/run.sh` also writes its own copy of each run to `s1/results/s1-*.txt`,
  which duplicates `full-*.txt` and `work100-*.txt`.
- `k1k2/run.sh` writes the K2 tables to `bin/k2_full_{c,rust}.txt`. Its run
  checked that C and Rust agree, and they did.

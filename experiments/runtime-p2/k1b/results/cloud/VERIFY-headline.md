# K1b headline: independent re-run

machine: cloud (experiments/MACHINE-cloud.md: 4 vCPUs, KVM, Xeon @ 2.10 GHz)

Re-run on 2026-10-30, 12:55 to 13:04 UTC. Raw lines, every attempt included:
`verify-headline-raw.txt`.

## Method

- **Rebuilt from source** into `build-verify/headline/`, under `flock -s /tmp/ren-bench/lock`:
  `clang -O2 -Wall -Wextra c/k1b.c -pthread -lm` and
  `cargo build --release --target-dir build-verify/headline/target`. The existing `bin/` was not used.
- **Every config:** `--k 5 --lock spin --max 10000 --reps 7 --ms 1000 --warm-ms 300 --qos p`. Each
  timed run ran alone under `flock -x /tmp/ren-bench/lock`. load1 was recorded at the start and end
  of each run. It ranged from 0.16 to 2.69, partly from this run's own 4-worker configs.
- **Spread rule:** spread = (max - min) / median. Above 10%, the config was re-run, up to 3 attempts
  in all. If every attempt stayed above 10%, it is marked **NOISY**. For a NOISY config the table
  shows each attempt's median. Otherwise it shows the first attempt under 10%.
- I read `headline-20261030-122017.txt` only after all of these runs had finished.

## Harness review (source read before running)

- **Throughput.** In C and Rust, mops = the sum of every worker's `ops` / (t1 - t0).
  - t0 is taken after every thread has reported ready, just before `go` is released.
  - t1 is taken right after `stop` is set.
  - Workers poll `stop` every 16 ops. At most 15 ops per worker land after t1, which is negligible.
- **Concurrency.** Workers spin on `go`, so they really do run concurrently. Threads are created
  per rep, outside the timed window.
- **Warm-up.** Rep -1 is untimed and excluded from mops, hits, misses and retries. The `evictions`
  count is cumulative and includes the warm-up, as PLAN documents.
- **b's hit path matches PLAN.** Per hit:
  - a lock-free acquire probe of the shard table;
  - one `fetch_add` pin on the instance's line, then an EV/key check;
  - the instance's TTAS lock, `state++`, and a relaxed stamp store;
  - unlock, then a `fetch_sub` unpin.

  No partition or shard lock is taken on a hit. The shard lock is only in `miss_bc` and
  `evict_one`. a_lru does take the partition lock twice, plus the instance lock. Rust `at_bc` is the
  same algorithm.
- **Universe 2 counts.** `hits + misses == ops` is checked every rep. `verify()` checks
  live + evicted state = all ops, nothing pinned at rest, the slot-to-table bijection, and a's caps
  and LRU lists. Every line reported ok=1, with no FAIL.
  - Hit rates are about 0.90 on zipf99 and 0.50 on uniform. That matches max/U = 0.5.
  - Universe 0.9 had hit_rate 1.0000 and 0 evictions everywhere, so it really is hits only.
- **Harness issues found.** None that would bias the reported numbers. Observations:
  1. **1-worker runs are inherently noisy on this guest.** Every w1 config gave a 10 to 32% spread
     even with 1000 ms reps. 4-worker configs were mostly 6 to 14%. The original file also flags
     most w1 lines `noisy=1`, and some of the headline's claimed values come from noisy lines:
     - a_lru uniform 0.9 w1 (23.26)
     - b_sampled uniform 0.9 w1 (28.33)
     - a_lru uniform 2 w4 (2.55)
     - c_clock uniform 2 w4 (1.96)
  2. **The original headline ran at higher load.** Its load1 at start was mostly 2.5 to 5, against
     the "run on an idle machine" in `measure-cloud.sh`. Even so, the numbers agree with this re-run.
  3. **Retries vs PLAN prediction 11.** This is not a headline claim. Under uniform eviction at 4
     workers, retries/misses is 0.31 for b and 0.33 for c. That is above PLAN prediction 11's
     "under 20% of misses". On zipf99 it is 0.13 to 0.17.

## Point claims (C unless noted)

| claim | claimed | re-run median [min..max] | spread | verdict |
|---|---|---|---|---|
| u0.9 uniform a_lru w1 | 23 | NOISY: 22.93 [18.50..25.67], 24.96 [21.75..27.51], 24.80 [22.92..25.61] | 31%, 23%, 11% | within-noise (medians +0 to +9%) |
| u0.9 uniform a_lru w4 | 6.8 | 6.83 [6.50..7.12] | 9.1% | confirmed within 10% (+0.4%) |
| u0.9 uniform b_sampled w1 | 28 | NOISY: 25.87 [23.50..27.71], 27.41 [23.98..30.23], 25.09 [23.92..26.48] | 16%, 23%, 10.2% | within-noise (medians -2 to -10%, lower) |
| u0.9 uniform b_sampled w4 | 50.5 | 51.56 [48.70..53.19] (attempt 1: 49.22, 14%) | 8.7% | confirmed within 10% (+2.1%) |
| u0.9 uniform c_clock w4 | 51 | 52.98 [51.01..54.14] | 5.9% | confirmed within 10% (+3.9%) |
| u0.9 zipf99 a_lru w4 | 5.2 | 5.33 [5.00..5.50] (attempt 1: 5.92, 11%) | 9.4% | confirmed within 10% (+2.5%) |
| u0.9 zipf99 b_sampled w1 | 32.9 | NOISY: 30.80 [28.02..33.05], 30.51 [27.89..34.22], 31.14 [24.81..34.12] | 16%, 21%, 30% | within-noise (medians -5 to -7%) |
| u0.9 zipf99 b_sampled w4 | 25.0 | NOISY: 26.66 [25.39..28.37], 23.53 [21.97..27.75], 26.86 [25.57..31.43] | 11%, 25%, 22% | within-noise (medians -6 to +7%) |
| u2 zipf99 a_lru w4 | 4.5 | 4.62 [4.39..4.82] (attempt 1: 4.44, 10.6%) | 9.3% | confirmed within 10% (+2.7%) |
| u2 zipf99 b_sampled w4 | 11.2 | NOISY: 11.06 [10.84..12.26], 9.44 [9.15..10.77], 11.05 [10.52..11.65] | 13%, 17%, 10.2% | within-noise (2 of 3 medians within 1.3%; one at -16%) |
| u2 zipf99 c_clock w4 | 6.8 | NOISY: 6.78 [6.39..7.33], 6.68 [6.49..7.20], 6.94 [6.52..7.42] | 14%, 11%, 13% | within-noise (medians within 2%) |
| u2 uniform a_lru w4 | 2.55 | 2.41 [2.25..2.48] | 9.5% | confirmed within 10% (-5.5%) |
| u2 uniform b_sampled w4 | 3.1 | 3.02 [2.91..3.20] | 9.6% | confirmed within 10% (-2.6%) |
| u2 uniform c_clock w4 | 1.96 | NOISY: 1.91 [1.84..2.04], 1.96 [1.70..2.05], 1.60 [1.54..1.81] | 10.5%, 18%, 17% | within-noise (2 of 3 medians within 3%; one at -18%) |
| Rust u0.9 uniform b_sampled w4 | 53.3 | 53.04 [51.02..55.27] | 8.0% | confirmed within 10% (-0.5%) |

Supporting 1-worker runs for derived claim (iii), all NOISY. Each cell lists the three attempts'
medians.

| u2 config | w1 medians |
|---|---|
| zipf99 a_lru | 19.72, 20.49, 22.39 |
| zipf99 b_sampled | 21.33, 22.21, 20.91 |
| zipf99 c_clock | 22.68, 21.23, 21.56 |
| uniform a_lru | 13.07, 12.52, 13.20 |
| uniform b_sampled | 9.77, 10.77, 10.42 |
| uniform c_clock | 9.83, 9.88, 10.33 |

## Derived claims

| claim | claimed | re-run | verdict |
|---|---|---|---|
| (i) b w4 ≥ 4× a w4, uniform hits | 7.4× | 51.56 / 6.83 = 7.55× (range 7.2 to 7.9× over attempts) | confirmed |
| (i) b w4 ≥ 4× a w4, zipf99 hits | 4.8× | 26.66 / 5.33 = 5.0×; over all attempt pairs 3.97 to 5.04× | confirmed, but the margin is thin: the worst pairing (b 23.53 / a 5.92) is just under 4× |
| (ii) b uniform hits: w4 beats w1 | 1.78× | 51.56 / (25.09 to 27.41) = 1.88 to 2.05× | confirmed (slightly larger ratio, because w1 came out lower) |
| (ii) b zipf99 hits: w4 below w1 | 0.76× | (23.53 to 26.86) / (30.51 to 31.14) = 0.76 to 0.88× | confirmed (< 1 in every pairing) |
| (iii) u2: no variant's w4 beats its w1 | holds | zipf99: a 4.6 vs 20 to 22, b 9.4 to 11.1 vs 21 to 22, c 6.7 to 6.9 vs 21 to 23. uniform: a 2.41 vs 12.5 to 13.2, b 3.02 vs 9.8 to 10.8, c 1.6 to 1.96 vs 9.8 to 10.3 | confirmed by a wide margin (w4 is 0.15 to 0.5× of w1) |
| (iv) u2 uniform: c_clock w4 < a_lru w4 | 1.96 < 2.55 | 1.60 to 1.96 vs 2.41 (c is 19 to 34% slower) | confirmed |

## Verdict

1. All 15 point claims reproduce. 8 are confirmed within 10% on a run under 10% spread. The other 7
   are NOISY on this guest (every 1-worker config, and b/c at w4 under zipf99), and their medians
   bracket the claimed value or fall within about 10% of it.
2. All four derived claims hold. (i) on zipf99 is the weakest: about 4.4 to 5.0× typical, and just
   under 4× in the single worst pairing of attempts.
3. The harness is honest: the timed window, concurrency, warm-up exclusion, b's hit path and the
   miss/eviction accounting are as PLAN describes. Treat the 1-worker absolutes as ±10%.

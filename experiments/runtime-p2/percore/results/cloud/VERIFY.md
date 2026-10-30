# percore: independent verification of the cloud headlines

**Machine: `cloud`** (experiments/MACHINE-cloud.md): 4 vCPUs, KVM, Intel Xeon @ 2.10 GHz, no SMT, Linux 6.18.44. Run on 2026-10-30.
This is not the macOS reference. The macOS files in `results/` were not touched.

## Method

- **Binary.** I rebuilt from `c/percore.c` into `build-verify/percore` with `clang -O2 -Wall -Wextra -pthread ... -lm`, under `flock -s`. These are the flags `build.sh` uses. The binaries in `bin/` were not used.
- **Runs.** Every configuration ran as one `flock -x /tmp/ren-bench/lock` acquisition with 7 reps. The 1-minute load from /proc/loadavg was recorded at the start and end of each configuration. Across all configurations it ranged from 0.35 to 6.22. The values after the oversubscribed runs are mostly the lagging average of our own 5 to 8 threads.
- **Re-runs.** Every configuration with spread > 10% was re-run twice more (tries r2 and r3).
- **Raw data.** `verify-pass1.txt` and `verify-pass2.txt` hold the raw reps. `../../verify-analyze.py` prints the medians.
- **Correctness.** All 280 reps had `ok=1`. Throughput mode under skew gave one `keyset_sum` and one `work_sum` across work_stealing, per_core and place_at_spawn, so all three runtimes did identical work.
- **Calibration.** `--calibrate --work-us 200 --pin on`, run 3×, gave 46 608 to 47 155 iterations. The `--work-iters 46208` used by the headlines is consistent with that. With 46208, the measured chunk mean was 202 to 209 µs. With 44683 (the `_long` runs) it was 193 µs.

Verdicts:
- **confirmed**: my median is within 10% of the claim and my best try is not NOISY.
- **within-noise**: the medians agree, but I could not get a non-NOISY try, so the claim should not be a headline.
- **disagrees**: as stated in the row.

## Source review

I found **no bug that invalidates a number.** I checked the following:

- **Latency is open-loop.** It runs from the scheduled Poisson arrival (`t_go + xarr`) to completion, so time a request waits unclaimed counts and there is no coordinated omission.
- **Throughput is measured correctly.** It is total requests over `t_go` → last completion, for every variant.
- **The pure work is real.** `pure_work` is a dependent `mix64` chain whose result is accumulated into `work_sum` and printed, so it cannot be eliminated. The measured `work_us_mean` (~200 µs) confirms it ran.
- **Threads start together.** They start within µs of each other: `start_lag` is reported, and the barrier yields and then spins to a common `t_go`.
- **Pinning is as described.** Pinning is on when threads ≤ 4 CPUs under `--pin auto`. `--pin on` with 8 threads puts 2 per CPU.
- **place_at_spawn's throughput cap is real.** A heavy task leaves its worker's `load` when it is submitted to the pool, so the workers keep claiming arrivals and the pool queue grows. Throughput is capped at about pool size × (1 / (0.05 × 200 µs)), which is 0.1 M per pool thread. That is exactly what H3 and H4 show.

Caveats that affect how to read the numbers:

1. **Percentiles are lower bounds.** They are the lower edges of log-linear histogram buckets (32 per octave, ~3% wide), so they read low by up to 3%. "heavy p50 196.6 µs" means the bucket [196.6, 200.7) µs. A difference of one bucket (196.6 against 200.7) is resolution, not signal.
2. **The 25%-skew comparison is biased.** H6 (work_stealing) and H7 (place_at_spawn 2+2) are not like-for-like:
   - H6 uses `--work-iters 46208` and 100k requests per stream. H7 uses `44683` and 400k.
   - In my runs the place_at_spawn chunks were ~7% shorter (193 µs against ~207 µs).
   - This biases all-request p99 and heavy latency in place_at_spawn's favour. place_at_spawn's all-request p99 is still higher, so the direction holds, but the gap (213 against 254 µs) is understated.
3. **The latency headlines come from NOISY configurations.** In latency mode, SUMMARY's own gate metric is light p99. That metric was NOISY in every latency configuration, theirs and mine, so each latency configuration is NOISY by its own rule. H6, H7 and H8 report other metrics from those NOISY configurations. My re-runs show those metrics are less stable than the claimed spreads suggest (see below).

## Results

| # | claim | claimed | re-run median [min..max] (spread) per try | verdict |
|---|---|---|---|---|
| 1 | skewed thr, work_stealing | 0.340 [0.332..0.366] | 0.328 [0.315..0.336] (0.064) | confirmed (−3.5%) |
| 2 | skewed thr, per_core (0.59× ws) | 0.201 [0.199..0.214] | 0.194 [0.186..0.199] (0.067); ratio 0.59× | confirmed (−3.5%) |
| 3 | skewed thr, pas 3+1 (0.29×) | 0.098 [0.097..0.101] | 0.097 [0.094..0.101] (0.072); ratio 0.30× | confirmed |
| 4 | skewed thr, pas 2+2 (0.57×) | 0.193 [0.188..0.198] | 0.195 [0.192..0.206] (0.072); ratio 0.59× | confirmed |
| 5 | even thr, pas 3+1 | 0.674 [0.653..0.694] (0.061) | 0.656 (0.223 NOISY); 0.679 [0.549..0.736] (0.275 NOISY); 0.636 [0.563..0.676] (0.178 NOISY) | within-noise: medians within 6%, but NOISY on all 3 tries, so not a headline. 2+2: 0.726 NOISY (claim 0.664). 4+4: 0.646 NOISY (claim 0.600). ws: 0.684 NOISY. |
| 6 | skewed 25%, ws: light p50 / all p99 / heavy p50 | 1.02 µs / 213 µs / 196.6 µs | light p50 1.15 (0.28 N), 1.09 (0.15 N), 1.09 [1.02..1.15] (0.12 N); all p99 221 (13.3 N), 213 (0.17 N), **213 [213..217] (0.02)**; heavy p50 200.7, 196.6, 196.6 (0.02) | within-noise: all p99 and heavy p50 confirmed. Light p50 is +7% and NOISY on all 3 tries. The claimed spread of 0.06 did not reproduce. |
| 7 | skewed 25%, pas 2+2 `_long`: light p50 / all p99 / heavy p50 | 1.22 µs / 254 µs / 196.6 µs | 1.18 [1.15..1.22] (0.054); 246 [234..254] (0.083); 196.6 [192.5..196.6] (0.021) | confirmed (−3%). Light p99 21.0 µs, NOISY (SUMMARY: 24.6). |
| 8 | even 25%, light p50: ws 2.37 against pas 3+1 2.69 | ws 2.37 (0.08); pas 2.69 (0.10) | ws: 2.37 (0.19 N), 2.43 (0.105 N), **2.43 [2.43..2.62] (0.079)**. pas 3+1: 2.69 (0.12 N), 2.62 (0.12 N), **2.37 [2.37..2.50] (0.054)** | **disagrees.** The ws number is confirmed. pas 3+1's only non-NOISY try is 2.37 µs, 12% below the claim and *below* ws's 2.43. The claimed ws < pas ordering (+13%) does not reproduce. It is within run-to-run variation. |
| 9 | pc_spin collapses at 5 threads | w5 0.233, w6 0.211, w8 on 0.227, w8 auto 0.213; w4 ~1.4–1.5 NOISY | w5 0.247 [0.238..0.259] (0.085). w6 0.217 / 0.208 / 0.212 (all NOISY, 0.10–0.12). w8 on 0.211 [0.207..0.225] (0.085). w8 auto 0.218 [0.214..0.232] (0.083). w4 off 1.398 (N), w4 auto 1.478 (N). | confirmed: values within 7%, collapse 6–7×. w6 is NOISY on all 3 tries. |
| 10 | pc_spin_if4 w4 → w8, 5.7× (both non-NOISY) | 3.133 (0.097) → 0.552 (0.062) | w4: 3.668 (0.227 N), 3.292 (0.244 N), 3.185 (0.198 N). w8: 0.595 (0.113 N), **0.564 [0.546..0.595] (0.087)**, 0.558 (0.106 N). | within-noise: w8 confirmed (+2%). w4 is NOISY on all 3 tries (medians +2% to +17%), so "both non-NOISY" did not reproduce. The collapse ratio is 5.6–6.5×. |
| 11 | pc_park does not collapse, 4 → 8 | 0.157 → 0.202 | w4 0.159 (0.164 N), 0.162 [0.150..0.165] (0.093), 0.163 (0.092). w8 0.209 [0.198..0.215] (0.081). | confirmed (+3%) |

## Against PLAN.md

These measurements disagree with the PLAN.md predictions. They agree with the other agent's numbers.

- **E3** predicted work_stealing ≈ per_core within 1.3× on skewed throughput. Measured: per_core is 0.59× work_stealing.
- **E1** predicted pas 3+1 at 0.6–0.8× work_stealing on even throughput. Measured: about 0.96× (0.656 against 0.684, both NOISY). It is better than predicted.
- **E2** predicted work_stealing light p99 under 10 µs at even load, 25%. Measured: 47 to 80 µs (NOISY).

## What this means for the question

**Confirmed: place_at_spawn's throughput under skew is capped by its pool.**
- pas 3+1 is about 0.3× work_stealing and pas 2+2 about 0.6×.
- per_core loses about 40% of work_stealing's throughput.

**The latency picture at 25% skewed load holds in direction.**
- The two runtimes' light p50 is close: about 1.1 µs for work_stealing and 1.2 µs for place_at_spawn 2+2.
- place_at_spawn's light p99 is lower: 21 µs against 46 to 76 µs. These figures are NOISY, but in all three of my ws tries, every pas rep (max 23.6 µs) was below every ws rep (min 36.9 µs).
- place_at_spawn's all-request p99 is higher, and that holds even with the chunk-length bias in its favour.

**Not supported:** the claim that place_at_spawn 3+1 has a worse light p50 than work_stealing at even load. That difference is run-to-run variation on this VM.

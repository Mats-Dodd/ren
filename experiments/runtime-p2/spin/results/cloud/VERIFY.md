# spin: independent verification of the cloud headlines (machine `cloud`)

**Machine: `cloud`** (see `experiments/MACHINE-cloud.md`): KVM guest, 4 vCPUs Intel Xeon @ 2.10 GHz, no SMT,
Linux 6.18.44, clang 18.1.3 `-O2`. Run 2026-10-30, 11:31 to about 11:45 UTC.

I'm a second agent checking another agent's claims. I didn't use its logs or `SUMMARY.md` as evidence. I only
read them afterwards, to compare.

## Method

- **Rebuild.** I copied `c/spin.c` and the scripts (`build.sh`, `commands.sh`, `measure-cloud.sh`,
  `oversub-cloud.sh`, `cloudstats.py`, `cloudtable.py`) to `spin/build/verify/` (git-ignored). I rebuilt there with
  `flock -s /tmp/ren-bench/lock ./build.sh`, then ran `bin/spin --check` under `flock -s`, which printed `CHECK ok`.
  The new binary has the same sha256 as the other agent's `bin/spin` (`2738ee63…`). The build is reproducible,
  so the binary they measured is the one this source produces.
- **Runs.** Each claim's command was re-run from `build/verify/`, with `RESULTS` pointed at a separate directory.
  - Every configuration was one `flock -x` acquisition.
  - The 1-minute load from `/proc/loadavg` was recorded at the start and end of each configuration (`load1` columns).
  - 7 reps per configuration, each a separate process. A configuration was re-run up to twice if its gate spread was
    over 10%, and marked NOISY if it was still over.
  - The driver is `verify-20261030/runall.sh`. Load ranged from 1.17 to 4.70 across all configurations.
- **Raw output** is in `results/cloud/verify-20261030/` (`H1-*`, `H2-*`, `H3-*`, `H4a-*`, `H4b-*`,
  `H5-oversub-verify.txt`). Each file has a `machine=cloud` header.
- **Verdict scale.**
  - *confirmed*: my median is within 10% of the claimed median, and the qualitative statement holds.
  - *within-noise*: the medians agree, but the gate status (ok vs NOISY) did not reproduce.
  - *disagrees*: a number or statement did not hold.

## Source review: does it measure what the claims say?

I read `c/spin.c` (749 lines) and the scripts. I found no bug that invalidates a number. What I checked:

- **Timing.** A hop's latency runs from just before `q_push` to after `wait_for` returns, in the caller's clock.
  `CLOCK_MONOTONIC` is in ns (tick_ns = 1). The histogram records only hops that start inside the window
  (`g_measuring`). There is a 50 ms warm-up before the window.
- **Throughput and CPU** come from `snap()` and `getrusage(RUSAGE_SELF)` taken around the same `sleep_ms(window)`.
  `util = cpu/(wall·N)`. The main thread is in that rusage, but it sleeps, so its share is negligible.
- **No dead-code elimination.** `op_run` is `noinline`, and every result is checked against `mix64(token)`.
  Per-instance op counts and token sums are also checked, and `served == hops`. All runs ended `ok`.
- **Concurrency.** Each worker is a pthread. With N ≤ 4 and `--pin auto`, worker i is pinned to CPU i (`pin=1` on
  each SPIN line). The threads start together through `g_start`.
- **Percentiles.** The histogram has 64 linear buckets, then 16 per octave, and reports the bucket midpoint. The
  percentile is `ceil(p·n)`-th order, which is correct.
  - Resolution is about 4 to 6% per bucket. A 10% gate is therefore only 2 to 3 buckets wide.
  - The same quantisation explains the "7995 [7995..7995] 0%" p99s in H5. The 8 ms bucket is 512 µs wide, so a
    spread of 0 there means the values landed in one bucket, not that they were equal.
  - This is a resolution caveat, not a bug.
- **Caveat on `--pin auto` vs `--pin off`.** For N > 4 CPUs, `--pin auto` pins nothing. So at W = 5 and 6,
  `auto` and `off` are the same placement, not two independent controls. The claim's wording is consistent
  with this.
- **Calibration.** `ns_per_iter` differs between invocations: 1.548 to 1.588 here, against 1.39 or so in the
  other agent's runs (100 ns gives 63 to 72 iterations). So a "1 µs service" means about ±10% different work
  between the two runs. This is too small to move any verdict below.

## Verdicts

### H1: idle CPU burn (gap 100 µs, service 1 µs, W = 4, gate util/waste/cpu)

**Values: confirmed. The X = 0.05 classification of pred cap 20: disagrees.**

| config | claimed util | rerun util median [min..max] | Δ | status |
|---|---|---|---|---|
| B=0 | 0.263 | 0.271 [0.258..0.279] | +3% | ok |
| 100 ns | 0.269 | 0.268 [0.262..0.276] | 0% | ok |
| 500 ns | 0.281 | 0.273 [0.267..0.284] | −3% | ok |
| 1 µs | 0.277 | 0.280 [0.263..0.290] | +1% | ok |
| 2 µs | 0.288 | 0.295 [0.274..0.303] | +3% | **NOISY** |
| 5 µs | 0.333 | 0.330 [0.286..0.341] | −1% | **NOISY** |
| 10 µs | 0.380 | 0.383 [0.372..0.386] | +1% | ok |
| 20 µs | 0.464 | 0.473 [0.458..0.477] | +2% | ok |
| 50 µs | 0.656 | 0.659 [0.637..0.669] | 0% | ok |
| inf | 0.985 | 0.987 [0.972..0.996] | 0% | ok |
| ema 5 | 0.330 | 0.334 | +1% | ok |
| ema 20 | 0.463 | 0.466 | +1% | ok |
| pred 5 | 0.271 | 0.266 | −2% | ok |
| pred 20 | 0.312 | 0.328 [0.315..0.338] | +5% | ok |
| go 5 | 0.301 | 0.311 | +3% | **NOISY** |
| go 20 | 0.375 | 0.376 [0.363..0.384] | 0% | ok |
| CPU/hop, B=0 | 40.9 µs | 44.1 [42.4..46.2] µs | +8% | |
| CPU/hop, inf | 105.1 µs | 103.4 [102.1..108.6] µs | −2% | |

Every median reproduces within 10%. Three configurations (2 µs, 5 µs, go 5) failed the gate in my run, though they
passed in theirs.

On the X = 0.05 allowance, the waste delta over B = 0 is what the PLAN's rule uses:

- **pred cap 20 breaks it in my run: +0.055 waste (+0.056 util).** The claim says it stays within. Even in the other
  agent's own data the delta is +0.048, so this is a borderline case, not a robust "within X".
- Fixed 5 µs (+0.059 here, +0.069 theirs) and ema cap 5 (+0.062 / +0.067) **also break X in both runs**. The claim
  doesn't mention either. Its wording "≥10 µs … break, ≤2 µs … stay within" leaves 5 µs out.
- Budgets ≤ 2 µs, pred 5 and go 5 stay within X in my run too. go 20 and ema 20 break it: confirmed.

### H2: p99 back to back (gap 0, service 1 µs, W = 4, 2 s window)

**Confirmed (medians). Gate status partly did not reproduce.**

| config | claimed | rerun |
|---|---|---|
| inf | p99 12.0 [11.5..12.5], 1.22 M/s, 3.22 µs CPU | p99 **11.5** [11.5..12.0] ok, 1.23 M/s, 3.19 µs |
| go cap 20 | 12.0 [11.5..12.5], 1.23 M/s, 3.06 µs | 12.5 [12.0..13.6], 1.19 M/s, 3.09 µs, **NOISY**. Its H4 re-run passed at 12.0 [11.5..12.5], ok |
| pred cap 20 | 50.2 [48.1..52.2], 654 k/s | 48.1 [46.1..50.2] ok, 665 k/s |
| ema cap 20 | 60.4 [58.4..62.5], 445 k/s | 60.4 [58.4..67.6], 434 k/s, **NOISY** |

The ratios hold: pred/inf is 4.2× and ema/inf is 5.3×. go cap 20 ties never-park within one histogram bucket. In
this run, ema cap 20 did not pass the gate.

### H3: p99 at idle-ish load, fixed 20 µs (gap 100 µs, 2 s window)

**Disagrees.**

- Claimed: p99 92.2 [88.1..96.3] µs, ok, CPU 63.6 µs/hop.
- Rerun: p99 **108.5 [96.3..143.4] µs, NOISY after 3 tries** (spread 43%). CPU is 65.4 µs/hop, which agrees (+3%).
- The p99 median is 18% higher than claimed, and the config did not pass the gate. So it isn't a reproducible
  headline.
- The qualitative conclusion still holds. At gap 100 µs every finite budget sits at a parked p99 of about
  92 to 125 µs (my 400 ms H1 runs), and no finite spin budget improves it. Only inf (17.9 µs) does.
- That conclusion rests on NOISY p99s, not on a headline-grade number.

### H4: which rule wins

**go cap 20 numbers: confirmed. The "pred cap 20 within X (+0.04)" part: disagrees. Conclusion: confirmed, and stronger.**

- go cap 20 at gap 0 has p99 12.0 [11.5..12.5] µs, ok. That exactly matches the claim.
- go cap 20 util at gap 100 µs is 0.384 [0.365..0.390] in this run, ok, and 0.376 in the H1 run. The claim is
  0.375 [0.357..0.386].
- The delta over B = 0 is +0.10 to +0.11, which breaks X. Confirmed.
- pred cap 20 is +0.055 to +0.056 in my run, so it **breaks X** too. The claim says it stays within at +0.04, and
  its own data shows +0.048.
- So "no rule met both goals on this machine" holds even more strongly. Under X = 0.05, no adaptive rule with a
  20 µs cap is admissible at idle.

### H5: oversubscription collapse above 4 workers (service 100 ns, gap 0)

**Within-noise. Medians reproduce; the "(ok)" statuses mostly did not.**

| config | claimed | rerun |
|---|---|---|
| inf W=4 auto | 2.87 M/s (NOISY p99) | 2.70 M/s [2.50..3.08], NOISY (−6%). With `off`: 3.03 M/s, NOISY |
| inf W=5 auto | 4 k/s, p99 7995 [7995..7995], ok | 4 k/s, p99 7995 [7995..7995], **NOISY** (CPU/hop spread 17%) |
| inf W=5 off | NOISY, same medians | 4 k/s, 7995, ok |
| inf W=5 wrap | 4 k/s, 7995 [7995..8258], ok | 4 k/s, 7995 [7995..7995], ok |
| inf W=6, all pin modes | 2 k/s, all ok | 2 k/s, p99 7995 in every mode. Only `wrap` was ok; `auto` and `off` were **NOISY** |
| B=5 µs W=5 off | 274 k [252..283], p99 116.7 [112.6..116.7], ok | 266 k [234..284], p99 116.7 [112.6..124.9], **NOISY** |

- The collapse to about 4 k hops/s and an 8 ms p99 at exactly W = 5 reproduces with every pin mode, including
  4 workers wrapped onto 4 CPUs. B = 5 µs degrades (about 250 to 280 k/s, p99 about 117 µs) instead of collapsing.
  The "oversubscription, not pinning" reading holds.
- I did **not** check "B = 0 has no collapse": the claim's own filter (`inf|5000`) leaves B = 0 out.

## Against the PLAN (said plainly)

These are not regressions in the harness. They are what the machine does, and they disagree with the PLAN's
predictions:

- **Prediction 1.** For B = 0 at a 100 µs gap, the PLAN predicted CPU of 3 to 8 µs/hop and p99 of 10 to 15 µs.
  I measured **44 µs/hop** and a p99 of about **100 to 125 µs**. The p50 is 33.8 µs, against a predicted 5 to 8 µs
  plus service.
- **Prediction 2.** For never-park, the PLAN predicted p50 of 300 to 450 ns plus service. At gap 0 and 1 µs
  service I measured 2.4 µs, about 1.4 µs above service.
- **Prediction 7.** The PLAN said pred cap 5 would be within X. It is, here. But pred cap 20 also breaks X at
  gap 100 µs, by a small margin. That is the overspin the PLAN predicted for cap 20, which it only expected at
  5 to 20 µs gaps.

## Code issues

None that invalidate a number. Caveats:

- The p99 is coarse (16 buckets per octave, about 6%), so the 10% gate is 2 to 3 buckets wide.
- At N > 4, `pin auto` and `pin off` are the same placement.
- `ns_per_iter` is re-calibrated on every invocation (±3% here). That slightly changes what "1 µs service" means
  between runs.

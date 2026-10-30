# spin: cloud results (machine `cloud`)

**Machine: `cloud`**, as described in `experiments/MACHINE-cloud.md`: a KVM guest with 4 vCPUs (Intel Xeon @ 2.10 GHz, no SMT), Linux 6.18.44, glibc 2.39, clang 18.1.3 `-O2`.
Run on 2026-10-30, 06:35 to 10:30 UTC. The other agents' benchmarks shared the
machine through `/tmp/ren-bench/lock`. Every timed configuration ran under
`flock -x`, one configuration per acquisition. Builds and `--check` ran under
`flock -s`.

Sources were rebuilt from clean first (`rm -rf bin build target; flock -s ... ./build.sh`).
`bin/spin --check` passed (CHECK ok). TSan for this build is in `results/cloud/tsan.log`
(from the port; gcc 13 libtsan).

## Files

| file | what |
|---|---|
| `summary-20261030-063521.txt` / `full-` / `raw-` | main sweep (`measure-cloud.sh`), 400 ms window, gate = hop_p99 and cpu/hop spread |
| `summary-20261030-0905-w2000.txt` / `full-` / `raw-` | 16 headline configs repeated with a **2 s** window (`WINDOW_MS=2000`), same gate |
| `summary-20261030-idleburn.txt` / `full-` / `raw-` | idle-burn configs (gap 100 µs), gate = **util, waste, cpu/hop** (`GATE=util,waste,cpu_ns_per_hop`) |
| `oversub-20261030-063521.txt` | oversubscription control (`oversub-cloud.sh`): workers 2..8 × pin auto/off/wrap |
| `analyze-20261030-063521*.txt` | `analyze.py --wait-workers 4`, as is / `--keep-noisy` / `--keep-noisy --x 0.30` |

Each config: 7 runs (separate processes). The value is the median, shown as
`median [min..max] spread`, with spread = (max−min)/median. A config whose gate
spread was above 10% was re-run up to 2 more times. If it was still above 10%, the last
try is kept and marked **NOISY**. NOISY configs are not used as headlines.

## Coverage: the full matrix was NOT completed

In the 4 h available the lock was shared with the percore agent's long benchmarks,
which held it about 2/3 of the time. Almost every config also needed all 3 tries (see
"Noise"). So the 810-config matrix did not finish. Configs were run in priority order:

| part of the matrix | done |
|---|---|
| workers = 4 (pinned, one worker per vCPU), sections 1 (fixed), 2 (reply-only / idle-only) and 3 (adaptive) | **325 / 325, complete** (the matrix's 330 lines hold 5 duplicates: reply 0 / idle 0 appears twice per gap) |
| workers = 2, sections 1 and 3 | 26 / 240 (partial, the order was commands.sh's shuffled order) |
| workers = 8, sections 1 and 3 (oversubscribed) | 4 / 240 (partial) |
| oversubscription control, back to back, 100 ns service, B ∈ {0, 5 µs, inf}, workers 2,3,4,5,6,8 × pin auto/off/wrap | 45 / 45 |
| 2 s window repeat of 16 headline configs | 16 / 16 |
| idle-burn gate repeat (gap 100 µs, all 10 fixed budgets and 6 adaptive) | 16 / 16 |

To finish the rest (it appends to the same files and skips what is done):

```
cd /home/user/ren/experiments/runtime-p2/spin
./measure-cloud.sh --shard 0/2 --resume 20261030-063521   # run_in_background
./measure-cloud.sh --shard 1/2 --resume 20261030-063521   # run_in_background, concurrently
```

## Load

The 1-minute load (`/proc/loadavg`) was recorded at the start and end of every
configuration. It is in every row of the tables below, and as `load1_start=` /
`load1_end=` on every SPIN line. Across all configs it ranged from **1.66 to 6.61**. This box
has only 4 vCPUs, so a 4-worker spinning benchmark makes load ≈ 4 by itself.
Between my configurations the percore agent's benchmarks ran (never at the same
time, because of the exclusive lock). Load above 4 means queued runnable threads.
It came mostly from oversubscribed configs and the decaying tail of the previous holder's run.

## Noise: why nearly everything is NOISY

334 of the 355 main-sweep configs are NOISY. In almost all of them it is **hop_p99** that
fails the gate. cpu/hop is usually within 10% (see the `CPU µs/hop` column). Two causes,
stated plainly:

1. The p99 histogram has 16 buckets per power of two, about 6% per bucket. A p99 that
   moves by 2 buckets across 7 runs already fails a 10% gate.
2. The run-to-run variation is real, not too few samples. Repeating with a 5× longer
   window (2 s, stamp `0905-w2000`) still left 11 of 16 NOISY with similar spreads
   (for example B=0, gap 100 µs: 25% at 2 s, against 26% at 400 ms). Parked wake-ups on this
   KVM guest vary by tens of µs from run to run.

So for this machine, **p99 headlines exist only where a config passed**. For the
idle-CPU question I re-ran the gap 100 µs configs with the gate set to the CPU metrics
that the headline actually reports (util, waste, cpu/hop). All 16 passed.

## Changes made during the measurement

- `c/spin.c`: new `--pin auto|off|wrap` flag for the oversubscription control.
  `auto` is the default and the old behaviour (pin worker i to CPU i iff
  workers ≤ CPUs). `off` never pins. `wrap` pins worker i to CPU i mod CPUs. The line's
  `pin=` field is 0/1/2 (2 = wrapped). Rebuilt under `flock -s`, and `--check` passes.
- `oversub-cloud.sh` (new): the control sweep. Same lock, 7 reps, and the same
  re-run/NOISY rule via `cloudstats.py`. Env: `RESULTS`, `FILTER`, `NPI`, `REPS`.
- `cloudtable.py` (new): prints the markdown tables below from a summary/oversub file.
- `measure-cloud.sh` bug fix: the final `# done:` line was appended to the summary
  file, so every `--resume` added another one. It now goes to stderr only. The
  stray lines were removed from the summaries.
- Note on `--filter`: it is an awk ERE on the bin/spin argument line, e.g.
  `'budget-ns.*workers 4$'` (the line has `--workers`, not ` workers`).

## Headlines (only configs that passed the gate; each line is reproducible)

All headlines are at **workers = 4** (one pinned worker per vCPU) and **service 1 µs**,
unless stated otherwise. Verifier commands write to a scratch directory and take the same locks.

**H1. Idle CPU burn per spin budget** (gap 100 µs, the PLAN's idle-ish load; stamp
`idleburn`, gate util/waste/cpu, all `ok`). util = CPU / (wall × workers); B=0 is
park-at-once.

| budget | util (share of 4 vCPUs) | waste − waste(B=0) | CPU µs/hop | hops/s |
|---|---|---|---|---|
| 0 | 0.263 [0.259..0.267] | 0 | 40.9 [39.4..41.9] | 26k |
| 100 ns | 0.269 [0.262..0.277] | +0.00 | 42.6 [41.4..43.6] | 25k |
| 500 ns | 0.281 [0.277..0.290] | +0.01 | 45.1 [43.9..48.2] | 25k |
| 1 µs | 0.277 [0.274..0.283] | +0.01 | 44.4 [42.8..45.6] | 25k |
| 2 µs | 0.288 [0.282..0.292] | +0.02 | 45.7 [44.4..46.1] | 25k |
| 5 µs | 0.333 [0.324..0.342] | +0.07 | 51.1 [49.0..51.9] | 26k |
| 10 µs | 0.380 [0.376..0.390] | +0.11 | 56.7 [54.6..58.5] | 27k |
| 20 µs | 0.464 [0.452..0.480] | +0.20 | 64.0 [63.1..65.3] | 29k |
| 50 µs | 0.656 [0.633..0.663] | +0.39 | 81.4 [79.6..84.7] | 32k |
| inf | 0.985 [0.967..0.992] | +0.72 | 105.1 [103.8..109.4] | 38k |
| ema cap 5 µs | 0.330 [0.322..0.338] | +0.06 | 51.5 [49.5..52.5] | 26k |
| ema cap 20 µs | 0.463 [0.434..0.471] | +0.20 | 63.7 [62.7..64.5] | 29k |
| pred cap 5 µs | 0.271 [0.268..0.279] | +0.01 | 42.9 [41.9..45.1] | 25k |
| pred cap 20 µs | 0.312 [0.310..0.323] | +0.04 | 47.4 [45.1..48.5] | 27k |
| go cap 5 µs | 0.301 [0.284..0.308] | +0.03 | 47.4 [46.2..48.0] | 26k |
| go cap 20 µs | 0.375 [0.357..0.386] | +0.11 | 56.5 [55.0..58.1] | 26k |

Even park-at-once burns **26% of the machine** at this "idle-ish" load (4 workers, each
hopping every ~100 µs + hop time): **41 µs of CPU per hop**, with 2.4 parks per hop.
Within the PLAN's X = 0.05 allowance, budgets ≤ 2 µs, pred (both caps) and go cap 5 µs
pass; 5 µs is borderline; ema cap 20 µs, go cap 20 µs and every fixed budget ≥ 10 µs fail.
The p99 of these same configs is NOISY (spread 26–525%), so it is not a headline.

Reproduce:
```
cd /home/user/ren/experiments/runtime-p2/spin && GATE=util,waste,cpu_ns_per_hop RESULTS=/tmp/spin-verify ./measure-cloud.sh --filter 'budget-ns [0-9inf]+ --service-ns 1000 --gap-ns 100000 --workers 4$' && python3 cloudtable.py /tmp/spin-verify/summary-*.txt
```

**H2. p99 hop latency, back to back** (gap 0; 2 s window, stamp `0905-w2000`).
These configs passed:

| config | hop p99 µs | hop p50 µs | hops/s | CPU µs/hop |
|---|---|---|---|---|
| fixed inf (never park) | **12.0 [11.5..12.5]** | 2.4 | 1.22 M | 3.22 [3.13..3.28] |
| go cap 20 µs | **12.0 [11.5..12.5]** | 2.4 | 1.23 M | 3.06 [2.95..3.13] |
| pred cap 20 µs | **50.2 [48.1..52.2]** | 2.5 | 654 k | 4.41 [4.20..4.56] |
| ema cap 20 µs | **60.4 [58.4..62.5]** | 2.8 | 445 k | 5.64 [5.40..5.70] |

The fixed budgets 0, 2, 5 and 20 µs at the same point were **NOISY** (medians 79.9, 79.9,
35.8 and 13.1 µs; see the table), so they are not headlines. They show the same step:
B ≤ 2 µs runs fully parked (p50 25–27 µs, ~130–155 k hops/s); B ≥ 5 µs runs spinning
(p50 2.4 µs, ~1.0–1.2 M hops/s).

Reproduce:
```
cd /home/user/ren/experiments/runtime-p2/spin && WINDOW_MS=2000 RESULTS=/tmp/spin-verify ./measure-cloud.sh --filter '(fixed --budget-ns inf|go --budget-ns 20000|pred --budget-ns 20000|ema --budget-ns 20000) --service-ns 1000 --gap-ns 0 --workers 4$' && python3 cloudtable.py /tmp/spin-verify/summary-*.txt
```

**H3. p99 hop latency at the idle-ish load** (gap 100 µs, 2 s window). Only one config
passed: fixed 20 µs, **p99 92.2 [88.1..96.3] µs**, CPU 63.6 µs/hop. Every other budget
at gap 100 µs was NOISY, with p99 medians of 80 to 143 µs for all finite budgets and
14.6–20 µs for inf (inf costs util 0.985, H1). No finite budget brings the idle-ish p99
below ~80 µs.

Reproduce:
```
cd /home/user/ren/experiments/runtime-p2/spin && WINDOW_MS=2000 RESULTS=/tmp/spin-verify ./measure-cloud.sh --filter 'fixed --budget-ns 20000 --service-ns 1000 --gap-ns 100000 --workers 4$' && python3 cloudtable.py /tmp/spin-verify/summary-*.txt
```

**H4. Which budget / adaptive rule wins.**
- By the PLAN's own rule (lowest p99 among budgets whose waste is ≤ X = 0.05 above B=0's,
  `analyze.py --keep-noisy`, workers 4): **no spin that actually spins wins anywhere.** Back to back,
  B ≥ 5 µs raises waste by 0.2–0.5. That happens because it serves 8–10× more hops, even though its CPU **per hop** is
  4× lower (H2: 3.2 µs against 12.8 µs at B=0). So the "best admissible" budget is 0–2 µs, which
  behaves like park-at-once (p99 ~70–125 µs), in every W=4 cell. The best single budgets are
  100 ns / 500 ns, within 10% of the best in 11–12 of 18 cells; 5 µs is within 10% in 1 of 15 (these counts
  also include the few W = 2 / 8 cells that ran).
  Among adaptive rules, pred cap 5 µs scores best (9/16) **only because it almost always parks**
  (its 2·ema is above the 5 µs cap). These rankings rest on NOISY p99s and are not headlines.
- On the configs that passed: **go cap 20 µs** is the best rule. Back to back it equals never-park
  (p99 12.0 µs, 1.23 M hops/s, H2). At idle it burns util 0.375 against 0.985 for never-park (H1).
  But it is +0.11 over B=0 at idle, so it breaks the PLAN's X = 0.05. **pred cap 20 µs** stays
  within X at idle (+0.04, H1), but back to back it is 4× worse than go (p99 50.2 µs, 654 k hops/s, H2).
  No rule met both "p99 near the best" and "within X" here.

**H5. Throughput collapse above 4 workers is oversubscription of this 4-vCPU machine.**
Back to back, service 100 ns (`oversub-cloud.sh`). Never-park (inf) runs at 2.87 M hops/s at 4 workers (NOISY on p99, throughput
2.43–3.07 M). At **5 workers** it falls to **4 k hops/s, p99 7995 µs [7995..7995]** (`ok`), and
the same holds pinned-wrapped (worker 5 shares CPU 0: 4 k hops/s, p99 7995 [7995..8258] µs, `ok`) and
unpinned (NOISY, same medians). At 6 workers it is 2 k hops/s (auto, off and wrap all `ok`). The collapse
starts exactly at 5 = CPUs + 1, and pinning does not change it, so it comes from the
number of spinning threads exceeding the vCPUs. A spinner that never parks holds its vCPU until the
scheduler preempts it (p99 ≈ 8 ms here), and its partner waits that long. A finite budget degrades
instead of collapsing: B = 5 µs at 5 workers unpinned gives 274 k [252..283] hops/s, p99 116.7
[112.6..116.7] µs (`ok`), against 2.6 M at 4 workers. Park-at-once has no collapse at all
(77 k → 137 k → 164 k → 215 k hops/s at 2/4/5/8 workers, NOISY). Pinned vs unpinned at ≤ 4
workers makes no difference beyond noise (e.g. B = 0, W = 4: 137 k vs 140 k).

Reproduce (5 and 6 workers, inf and 5 µs, all pin modes, plus 4 for reference):
```
cd /home/user/ren/experiments/runtime-p2/spin && RESULTS=/tmp/spin-verify FILTER='budget-ns (inf|5000) .*--workers (4|5|6) ' ./oversub-cloud.sh verify && python3 cloudtable.py /tmp/spin-verify/oversub-verify.txt
```

## Against PLAN.md's predictions

The predictions were written for macOS (M4 Max). The cloud matrix uses workers 2/4/8
instead of 2/8/16. Comparisons here are at W = 4 unless stated.

| # | prediction | cloud result | verdict |
|---|---|---|---|
| 1 | B=0: hop p50 5–8 µs + service, p99 10–15 µs, CPU 3–8 µs/hop, 0.3–0.4 M hops/s at 2 workers / 100 ns back to back | (service ≤ 1 µs) p50 **25–34 µs**, p99 **72–125 µs**, CPU **11–13 µs/hop** back to back and **41 µs/hop** at gap 100 µs (H1); 2 workers / 100 ns back to back: **77 k hops/s** (NOISY) | **Disagrees**, 4–5× slower on p50, ~8× on p99, ~4× lower throughput |
| 2 | inf: p50 300–450 ns + service at 2 and 8 workers, util ≈ 1.0, ~95% waste at 100 µs gaps; at 16 workers preemption pushes p99 to tens of µs | p50 0.8 µs (2 workers) and 1.1 µs (4 workers) at 100 ns service; 2.4 µs at 1 µs service, 4 workers. util 0.985, waste 0.97 at gap 100 µs. Above the core count p99 is **8 ms**, not tens of µs (H5) | p50 **disagrees** (about 2× higher); util/waste **agree**; oversubscribed p99 **disagrees** (~1000× worse; this machine has no spare cores at all) |
| 3 | reply waits need B > service + reach (~0.3 µs); p99 < 1 µs + service at B = 2 µs for 1 µs service; reply-only gives most of the gain back to back, within X | At gap 0 / 1 µs service, B = 2 µs still runs fully parked (p50 24 µs, p99 80 µs). It takes B ≥ 5 µs, and p99 never gets under 10 µs (12.0 µs at inf, H2). Reply-only spin does give all of the back-to-back gain (reply-only 20 µs: p99 12.0 µs, same as both), but it is **not** within X (waste +0.26) | Budget threshold and p99 level **disagree**; "reply-only gives the gain back to back" **agrees**; "within X" **disagrees** |
| 4 | gaps 20 and 100 µs: no finite budget improves p99 (stays ≥ 8 µs, parked); waste grows ~B/gap (10–20% at B = 10 µs, gap 100 µs); best admissible = reply spin + idle 0–1 µs | All finite budgets at gap 100 µs: p99 80–143 µs (NOISY), no improvement; B = 10 µs adds util +0.117 (H1); best admissible under X = 0.05 is 100 ns (2 µs at 10 µs service) | **Agrees** in shape; the parked p99 level is ~10× the predicted ≥ 8 µs |
| 5 | gaps 1–5 µs: B ≥ 2 × gap gives ~10× lower p99 at no more CPU than parking; spinning stops paying at a 5–10 µs gap | gap 1 µs: B = 10 µs p99 10.5 µs against 84 µs at B = 0 (8×), CPU/hop 4.2 against 35 µs. Gap 5 µs: B = 20 µs p99 7.8 against 80 µs, CPU/hop 7.7 against 34.6 µs (NOISY). It still pays per hop at a **20 µs** gap (B = 50 µs: CPU/hop 23 against 34.5 µs, p99 23 against 88 µs) | 10× gain at 1–5 µs **agrees**; the crossover **disagrees**, it is above 20 µs here, because park+wake costs ~30–40 µs of CPU per hop on this guest |
| 6 | no single budget; the best single budget (~5 µs) is within 10% in 50–60% of cells | Under X = 0.05 every budget ≥ 5 µs is inadmissible almost everywhere; 5 µs is within 10% of the best in 1/15 cells; 100 ns–500 ns in 11–12/18 | "No single budget" **agrees**; "~5 µs best" **disagrees** |
| 7a | pred cap 5 µs within 10% and X in ≥ 80% of cells | 9/16 (56%), and only by parking almost always | **Disagrees** |
| 7b | ema overspins at idle and breaks X at 100 µs gaps | ema cap 20 µs: +0.20 util at gap 100 µs (H1); cap 5 µs: +0.06 | **Agrees** |
| 7c | go behaves like B = 0 on idle waits at idle-ish loads; close to pred, with worse p99 at 5–20 µs gaps | go cap 5 µs at gap 100 µs: +0.03 util (≈ B = 0, agrees); go cap 20 µs: +0.11 (not ≈ B = 0). Back to back, go cap 20 µs is **much better** than pred cap 20 µs (p99 12.0 against 50.2 µs, H2) | **Mixed**: cap 5 µs agrees; cap 20 µs and the go-vs-pred ordering **disagree** |
| 8 | 2 and 8 workers alike at idle; 16 workers (E cores) 1.5–3× worse p99 | Not testable as written (W = 2/8 mostly not run). Above 4 workers this machine collapses for never-park (H5) | n/a / see H5 |
| 9 | reach p99 for a parked owner 4–8 µs | B = 0, gap 100 µs: reach p50 19–20 µs, p99 **60–88 µs**; back to back reach p99 36 µs | **Disagrees**, ~10× |
| rule | spin only if the predicted wait < park+wake cost (~5 µs on macOS) | Park+wake here is ~25–35 µs of latency and ~12–40 µs of CPU per hop, so the cap would have to be ~20–50 µs. Even at cap 20 µs pred loses to go back to back (H2) | The 5 µs figure **does not transfer** to this machine |

## Against the macOS results

There are **no macOS timed results for spin** in `spin/results/`: only `tsan.log` (TSan
on `--check`). PLAN.md says "No timed run yet", and the git history has no
`full-*.txt`. So no cloud number can be compared with a measured macOS number. The
only macOS figures are PLAN.md's predictions and its smoke-run note ("parking cost about
2.5 to 7 µs of CPU per hop"). Against that note, parking here costs **11–13 µs of CPU per
hop back to back and ~41 µs per hop at gap 100 µs** (2.4 parks per hop), 2–15× more.

## Tables: every configuration

Columns: `median [min..max] spread` over the kept try's 7 runs. Times in µs, waste is a
fraction of 4 workers' capacity, `try` is which of up to 3 tries was kept, and **NOISY**
means the gate spread was still > 10% after 3 tries.

### Main sweep, workers = 4 (complete), stamp 20261030-063521, 400 ms window

| policy | reply/idle spin | svc µs | gap µs | W | hop p50 µs | hop p99 µs | hop p99.9 µs | CPU µs/hop | hops/s | waste | load1 start→end | try | status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fixed | 0 | 0.1 | 0 | 4 | 26.1 [25.1..28.2] 12% | 75.8 [67.6..79.9] 16% | 303.1 [143.4..385.0] 80% | 11.87 [11.50..12.89] 12% | 134k [124k..143k] 14% | 0.40 [0.39..0.41] 3% | 2.68→2.68 | 3 | **NOISY** |
| fixed | 100 | 0.1 | 0 | 4 | 27.1 [26.1..27.1] 4% | 84.0 [71.7..124.9] 63% | 483.3 [129.0..1605.6] 306% | 12.30 [12.06..13.56] 12% | 128k [113k..138k] 19% | 0.40 [0.37..0.41] 10% | 6.47→6.47 | 3 | **NOISY** |
| fixed | 500 | 0.1 | 0 | 4 | 26.1 [25.1..27.1] 8% | 71.7 [67.6..79.9] 17% | 249.9 [159.7..573.4] 166% | 11.94 [11.32..12.42] 9% | 141k [134k..150k] 12% | 0.42 [0.41..0.43] 3% | 2.91→2.91 | 3 | **NOISY** |
| fixed | 1000 | 0.1 | 0 | 4 | 21.0 [1.6..21.0] 92% | 67.6 [58.4..71.7] 20% | 241.7 [108.5..737.3] 260% | 8.82 [6.29..9.18] 33% | 198k [191k..284k] 47% | 0.44 [0.41..0.46] 11% | 2.61→2.56 | 3 | **NOISY** |
| fixed | 2000 | 0.1 | 0 | 4 | 1.1 [1.1..1.2] 11% | 48.1 [44.0..50.2] 13% | 92.2 [75.8..116.7] 44% | 2.92 [2.34..3.09] 26% | 748k [733k..1019k] 38% | 0.55 [0.53..0.57] 8% | 4.82→4.59 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 4 | 1.1 [1.1..1.1] 6% | 3.3 [2.9..4.2] 41% | 44.0 [37.9..50.2] 28% | 1.28 [1.26..1.31] 4% | 2832k [2744k..2984k] 8% | 0.84 [0.83..0.87] 5% | 3.82→3.84 | 3 | **NOISY** |
| fixed | 10000 | 0.1 | 0 | 4 | 1.1 [1.0..1.1] 14% | 3.8 [3.0..4.2] 32% | 37.9 [29.2..54.3] 66% | 1.27 [1.17..1.34] 14% | 2831k [2686k..2980k] 10% | 0.84 [0.76..0.89] 16% | 4.10→3.93 | 3 | **NOISY** |
| fixed | 20000 | 0.1 | 0 | 4 | 1.1 [1.0..1.1] 10% | 3.0 [2.8..4.2] 49% | 29.2 [17.9..46.1] 96% | 1.31 [1.18..1.38] 15% | 2839k [2581k..3257k] 24% | 0.87 [0.81..0.90] 10% | 4.62→4.41 | 3 | **NOISY** |
| fixed | 50000 | 0.1 | 0 | 4 | 1.1 [1.0..1.1] 11% | 2.9 [2.6..3.1] 18% | 18.9 [15.1..26.1] 58% | 1.24 [1.19..1.35] 13% | 3134k [2888k..3226k] 11% | 0.88 [0.88..0.90] 3% | 2.81→2.81 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 4 | 1.1 [1.0..1.1] 14% | 2.8 [2.5..3.3] 28% | 17.9 [16.1..23.0] 39% | 1.29 [1.20..2.15] 73% | 3037k [1840k..3271k] 47% | 0.91 [0.89..0.94] 6% | 2.91→2.91 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 1 | 4 | 26.1 [25.1..26.1] 4% | 79.9 [71.7..88.1] 20% | 385.0 [352.3..671.7] 83% | 33.08 [32.06..33.60] 5% | 74k [70k..76k] 8% | 0.61 [0.59..0.62] 6% | 3.09→3.09 | 3 | **NOISY** |
| fixed | 100 | 0.1 | 1 | 4 | 25.1 [25.1..26.1] 4% | 75.8 [64.5..241.7] 234% | 901.1 [303.1..4325.4] 446% | 29.81 [28.83..31.23] 8% | 78k [55k..84k] 37% | 0.58 [0.43..0.61] 30% | 2.65→2.65 | 3 | **NOISY** |
| fixed | 500 | 0.1 | 1 | 4 | 26.1 [25.1..26.1] 4% | 79.9 [64.5..112.6] 60% | 401.4 [116.7..1998.8] 469% | 24.48 [23.71..25.90] 9% | 93k [82k..98k] 17% | 0.56 [0.53..0.58] 10% | 4.82→4.82 | 3 | **NOISY** |
| fixed | 1000 | 0.1 | 1 | 4 | 25.1 [25.1..26.1] 4% | 75.8 [71.7..92.2] 27% | 319.5 [129.0..516.1] 121% | 19.30 [19.06..20.15] 6% | 114k [106k..115k] 8% | 0.55 [0.53..0.55] 3% | 2.19→2.18 | 3 | **NOISY** |
| fixed | 2000 | 0.1 | 1 | 4 | 2.4 [1.6..13.1] 482% | 64.5 [60.4..75.8] 24% | 241.7 [124.9..385.0] 108% | 10.40 [9.69..10.63] 9% | 209k [203k..218k] 7% | 0.53 [0.52..0.55] 6% | 2.80→2.82 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 1 | 4 | 0.9 [0.9..1.1] 15% | 5.2 [4.7..14.6] 188% | 58.4 [54.3..75.8] 37% | 2.49 [2.42..2.73] 13% | 1432k [1292k..1530k] 17% | 0.85 [0.83..0.89] 7% | 2.95→2.95 | 3 | **NOISY** |
| fixed | 10000 | 0.1 | 1 | 4 | 1.0 [0.9..1.1] 18% | 4.5 [2.6..6.8] 93% | 56.3 [32.3..92.2] 106% | 2.53 [2.34..2.84] 20% | 1483k [1261k..1596k] 23% | 0.88 [0.86..0.92] 8% | 4.50→4.46 | 3 | **NOISY** |
| fixed | 20000 | 0.1 | 1 | 4 | 0.9 [0.9..1.1] 19% | 4.0 [2.6..5.2] 65% | 33.8 [22.0..67.6] 135% | 2.44 [2.31..2.60] 12% | 1553k [1369k..1696k] 21% | 0.92 [0.84..0.94] 10% | 2.12→2.27 | 3 | **NOISY** |
| fixed | 50000 | 0.1 | 1 | 4 | 0.9 [0.9..1.0] 10% | 3.6 [2.5..5.0] 68% | 27.1 [24.1..84.0] 221% | 2.44 [2.38..2.50] 5% | 1564k [1463k..1622k] 10% | 0.91 [0.87..0.93] 6% | 3.75→3.75 | 3 | **NOISY** |
| fixed | inf | 0.1 | 1 | 4 | 0.9 [0.9..1.1] 25% | 3.3 [2.5..3.8] 39% | 31.2 [21.0..67.6] 149% | 2.63 [2.40..2.79] 15% | 1482k [1371k..1629k] 17% | 0.94 [0.92..0.95] 3% | 4.44→4.44 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 5 | 4 | 25.1 [24.1..28.2] 16% | 71.7 [67.6..217.1] 209% | 573.4 [208.9..3473.4] 569% | 33.36 [31.89..38.37] 19% | 68k [51k..72k] 31% | 0.57 [0.49..0.58] 16% | 4.51→4.39 | 3 | **NOISY** |
| fixed | 100 | 0.1 | 5 | 4 | 26.1 [25.1..26.1] 4% | 88.1 [75.8..120.8] 51% | 802.8 [258.0..1081.3] 103% | 33.79 [32.64..34.47] 5% | 65k [65k..70k] 8% | 0.55 [0.54..0.57] 6% | 3.87→3.87 | 3 | **NOISY** |
| fixed | 500 | 0.1 | 5 | 4 | 25.1 [24.1..26.1] 8% | 84.0 [71.7..104.4] 39% | 671.7 [176.1..1540.1] 203% | 31.36 [30.40..32.58] 7% | 70k [68k..75k] 10% | 0.57 [0.54..0.58] 7% | 3.19→3.19 | 3 | **NOISY** |
| fixed | 1000 | 0.1 | 5 | 4 | 26.1 [25.1..26.1] 4% | 96.3 [84.0..385.0] 313% | 901.1 [639.0..4325.4] 409% | 31.91 [31.54..32.70] 4% | 69k [52k..73k] 30% | 0.56 [0.41..0.58] 30% | 4.85→4.85 | 3 | **NOISY** |
| fixed | 2000 | 0.1 | 5 | 4 | 25.1 [24.1..26.1] 8% | 75.8 [67.6..84.0] 22% | 225.3 [116.7..770.0] 290% | 28.57 [27.64..30.61] 10% | 83k [76k..88k] 15% | 0.60 [0.58..0.62] 6% | 2.56→2.56 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 5 | 4 | 1.4 [1.2..1.5] 19% | 67.6 [64.5..67.6] 4% | 208.9 [167.9..319.5] 72% | 16.74 [15.67..17.14] 9% | 163k [158k..169k] 7% | 0.68 [0.66..0.68] 4% | 3.16→3.23 | 1 | ok |
| fixed | 10000 | 0.1 | 5 | 4 | 0.9 [0.9..1.0] 10% | 50.2 [48.1..56.3] 16% | 116.7 [108.5..225.3] 100% | 8.89 [8.76..9.47] 8% | 375k [336k..385k] 13% | 0.83 [0.77..0.84] 8% | 3.86→3.87 | 3 | **NOISY** |
| fixed | 20000 | 0.1 | 5 | 4 | 0.9 [0.8..0.9] 14% | 5.2 [4.0..8.4] 84% | 71.7 [50.2..108.5] 81% | 6.45 [6.39..6.55] 2% | 585k [575k..612k] 6% | 0.94 [0.92..0.97] 5% | 2.12→2.12 | 3 | **NOISY** |
| fixed | 50000 | 0.1 | 5 | 4 | 0.9 [0.9..1.0] 14% | 4.2 [3.1..6.3] 74% | 50.2 [31.2..135.2] 207% | 6.49 [6.34..6.69] 5% | 584k [544k..608k] 11% | 0.93 [0.90..0.97] 8% | 3.40→3.40 | 3 | **NOISY** |
| fixed | inf | 0.1 | 5 | 4 | 0.9 [0.9..1.0] 10% | 4.0 [2.4..6.3] 97% | 46.1 [27.1..96.3] 150% | 6.67 [6.41..7.12] 11% | 590k [547k..619k] 12% | 0.97 [0.96..0.98] 2% | 3.30→3.35 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 20 | 4 | 28.2 [26.1..30.2] 14% | 84.0 [84.0..112.6] 34% | 368.6 [208.9..933.9] 197% | 35.97 [33.11..38.88] 16% | 51k [48k..54k] 12% | 0.45 [0.44..0.47] 5% | 5.62→5.41 | 3 | **NOISY** |
| fixed | 100 | 0.1 | 20 | 4 | 27.1 [26.1..29.2] 11% | 120.8 [84.0..129.0] 37% | 1278.0 [270.3..2687.0] 189% | 34.80 [33.44..36.88] 10% | 50k [48k..52k] 8% | 0.44 [0.40..0.46] 14% | 3.86→3.79 | 3 | **NOISY** |
| fixed | 500 | 0.1 | 20 | 4 | 26.1 [26.1..28.2] 8% | 88.1 [79.9..108.5] 33% | 516.1 [434.2..1146.9] 138% | 33.60 [33.33..38.41] 15% | 54k [47k..56k] 16% | 0.45 [0.45..0.46] 4% | 4.72→4.72 | 3 | **NOISY** |
| fixed | 1000 | 0.1 | 20 | 4 | 26.1 [25.1..27.1] 8% | 84.0 [71.7..112.6] 49% | 671.7 [352.3..1802.2] 216% | 33.54 [31.76..34.13] 7% | 55k [54k..59k] 10% | 0.46 [0.45..0.47] 5% | 2.13→2.12 | 3 | **NOISY** |
| fixed | 2000 | 0.1 | 20 | 4 | 26.1 [25.1..28.2] 12% | 88.1 [79.9..116.7] 42% | 368.6 [286.7..1409.0] 304% | 34.70 [34.17..38.30] 12% | 57k [51k..59k] 14% | 0.49 [0.48..0.50] 3% | 3.82→3.68 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 20 | 4 | 18.9 [13.6..21.0] 39% | 75.8 [71.7..84.0] 16% | 286.7 [208.9..1146.9] 327% | 32.40 [30.88..33.69] 9% | 69k [65k..72k] 11% | 0.55 [0.53..0.56] 5% | 2.18→2.18 | 3 | **NOISY** |
| fixed | 10000 | 0.1 | 20 | 4 | 3.0 [2.9..3.9] 34% | 71.7 [67.6..92.2] 34% | 385.0 [241.7..671.7] 112% | 29.84 [29.45..31.88] 8% | 87k [77k..88k] 13% | 0.65 [0.61..0.65] 6% | 5.51→5.23 | 3 | **NOISY** |
| fixed | 20000 | 0.1 | 20 | 4 | 1.1 [1.0..1.1] 14% | 75.8 [67.6..79.9] 16% | 434.2 [135.2..737.3] 139% | 28.29 [27.46..29.15] 6% | 113k [105k..115k] 9% | 0.78 [0.76..0.81] 6% | 2.50→2.50 | 3 | **NOISY** |
| fixed | 50000 | 0.1 | 20 | 4 | 0.9 [0.8..1.0] 18% | 26.1 [24.1..75.8] 198% | 200.7 [92.2..573.4] 240% | 22.23 [22.16..23.74] 7% | 170k [146k..176k] 17% | 0.94 [0.86..0.97] 11% | 2.91→3.00 | 3 | **NOISY** |
| fixed | inf | 0.1 | 20 | 4 | 0.9 [0.8..0.9] 11% | 5.5 [1.8..11.5] 176% | 129.0 [24.1..540.7] 400% | 22.23 [21.27..23.46] 10% | 178k [165k..188k] 13% | 0.98 [0.96..0.99] 3% | 4.32→4.32 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 100 | 4 | 35.8 [32.3..37.9] 16% | 124.9 [96.3..151.6] 44% | 901.1 [352.3..1409.0] 117% | 44.74 [41.42..49.66] 18% | 24k [23k..26k] 11% | 0.27 [0.26..0.29] 11% | 3.05→3.05 | 3 | **NOISY** |
| fixed | 100 | 0.1 | 100 | 4 | 32.3 [31.2..33.8] 8% | 100.4 [84.0..124.9] 41% | 868.4 [385.0..1212.4] 95% | 41.60 [39.37..43.12] 9% | 25k [25k..26k] 6% | 0.26 [0.26..0.27] 3% | 3.40→3.28 | 3 | **NOISY** |
| fixed | 500 | 0.1 | 100 | 4 | 32.3 [32.3..33.8] 5% | 104.4 [100.4..176.1] 72% | 1474.6 [385.0..4325.4] 267% | 42.02 [41.17..45.20] 10% | 25k [19k..26k] 26% | 0.26 [0.21..0.27] 24% | 3.70→3.70 | 3 | **NOISY** |
| fixed | 1000 | 0.1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 108.5 [79.9..135.2] 51% | 573.4 [286.7..3473.4] 556% | 43.97 [41.19..46.04] 11% | 25k [20k..26k] 22% | 0.28 [0.23..0.28] 20% | 3.86→3.63 | 3 | **NOISY** |
| fixed | 2000 | 0.1 | 100 | 4 | 32.3 [31.2..33.8] 8% | 100.4 [96.3..129.0] 33% | 639.0 [499.7..1146.9] 101% | 44.97 [44.49..45.32] 2% | 26k [26k..26k] 2% | 0.29 [0.28..0.29] 2% | 3.99→3.75 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 100 | 4 | 31.2 [31.2..32.3] 3% | 104.4 [84.0..303.1] 210% | 868.4 [417.8..1736.7] 152% | 47.75 [47.05..48.92] 4% | 27k [25k..27k] 10% | 0.32 [0.30..0.32] 9% | 3.57→3.52 | 3 | **NOISY** |
| fixed | 10000 | 0.1 | 100 | 4 | 30.2 [29.2..32.3] 10% | 112.6 [75.8..270.3] 173% | 1081.3 [270.3..1933.3] 154% | 54.93 [52.55..57.05] 8% | 27k [25k..29k] 14% | 0.37 [0.35..0.38] 6% | 2.51→2.55 | 3 | **NOISY** |
| fixed | 20000 | 0.1 | 100 | 4 | 15.1 [15.1..16.9] 12% | 96.3 [71.7..116.7] 47% | 466.9 [217.1..1802.2] 340% | 62.66 [61.35..63.80] 4% | 29k [29k..31k] 6% | 0.47 [0.45..0.47] 5% | 4.85→4.85 | 3 | **NOISY** |
| fixed | 50000 | 0.1 | 100 | 4 | 1.1 [1.1..1.2] 11% | 62.5 [48.1..75.8] 44% | 606.2 [417.8..901.1] 80% | 78.83 [77.28..79.69] 3% | 33k [33k..34k] 3% | 0.66 [0.65..0.66] 1% | 4.29→4.29 | 3 | **NOISY** |
| fixed | inf | 0.1 | 100 | 4 | 0.9 [0.8..1.0] 14% | 18.9 [9.5..233.5] 1182% | 737.3 [286.7..1540.1] 170% | 103.41 [101.99..110.60] 8% | 38k [36k..39k] 8% | 0.99 [0.97..0.99] 2% | 4.27→4.27 | 3 | **NOISY** |
| fixed | 0 | 1 | 0 | 4 | 27.1 [27.1..28.2] 4% | 84.0 [79.9..112.6] 39% | 483.3 [303.1..966.7] 137% | 12.78 [12.61..13.44] 6% | 127k [114k..130k] 13% | 0.38 [0.34..0.38] 11% | 3.58→3.46 | 3 | **NOISY** |
| fixed | 100 | 1 | 0 | 4 | 27.1 [26.1..29.2] 11% | 84.0 [71.7..96.3] 29% | 434.2 [116.7..802.8] 158% | 13.14 [12.23..13.72] 11% | 125k [118k..135k] 14% | 0.37 [0.37..0.39] 7% | 2.00→2.08 | 3 | **NOISY** |
| fixed | 500 | 1 | 0 | 4 | 27.1 [27.1..29.2] 8% | 79.9 [71.7..84.0] 15% | 286.7 [217.1..737.3] 181% | 12.94 [12.69..13.65] 7% | 131k [124k..134k] 8% | 0.39 [0.38..0.39] 3% | 2.83→2.85 | 3 | **NOISY** |
| fixed | 1000 | 1 | 0 | 4 | 27.1 [26.1..28.2] 8% | 79.9 [71.7..100.4] 36% | 352.3 [225.3..737.3] 145% | 13.68 [12.74..14.10] 10% | 130k [123k..140k] 13% | 0.41 [0.39..0.41] 5% | 2.05→2.05 | 3 | **NOISY** |
| fixed | 2000 | 1 | 0 | 4 | 24.1 [22.0..26.1] 17% | 79.9 [71.7..96.3] 31% | 335.9 [151.6..933.9] 233% | 11.79 [10.75..13.33] 22% | 157k [142k..184k] 27% | 0.44 [0.41..0.45] 10% | 2.95→2.95 | 3 | **NOISY** |
| fixed | 5000 | 1 | 0 | 4 | 2.2 [2.2..2.5] 11% | 24.1 [22.0..28.2] 26% | 71.7 [58.4..79.9] 30% | 2.98 [2.97..3.14] 6% | 1204k [1143k..1218k] 6% | 0.60 [0.58..0.62] 6% | 2.53→2.53 | 3 | **NOISY** |
| fixed | 10000 | 1 | 0 | 4 | 2.4 [2.4..2.5] 5% | 15.1 [13.1..20.0] 46% | 92.2 [71.7..112.6] 44% | 3.19 [3.07..3.30] 7% | 1129k [1086k..1198k] 10% | 0.62 [0.60..0.64] 6% | 5.03→5.03 | 3 | **NOISY** |
| fixed | 20000 | 1 | 0 | 4 | 2.4 [2.2..2.5] 11% | 12.0 [11.0..12.5] 13% | 62.5 [33.8..112.6] 126% | 3.12 [2.87..3.24] 12% | 1174k [1099k..1338k] 20% | 0.63 [0.59..0.66] 11% | 3.44→3.56 | 3 | **NOISY** |
| fixed | 50000 | 1 | 0 | 4 | 2.4 [2.2..2.4] 5% | 11.5 [11.0..12.5] 13% | 44.0 [30.2..108.5] 178% | 2.98 [2.90..3.09] 6% | 1272k [1122k..1341k] 17% | 0.63 [0.59..0.64] 8% | 2.73→2.84 | 3 | **NOISY** |
| fixed | inf | 1 | 0 | 4 | 2.4 [2.2..2.4] 5% | 10.5 [10.0..11.5] 15% | 31.2 [24.1..37.9] 44% | 3.00 [2.88..3.28] 13% | 1318k [1182k..1383k] 15% | 0.66 [0.65..0.67] 4% | 2.67→2.86 | 3 | **NOISY** |
| fixed | 0 | 1 | 1 | 4 | 28.2 [26.1..30.2] 14% | 84.0 [75.8..96.3] 24% | 499.7 [270.3..1278.0] 202% | 35.08 [32.58..37.57] 14% | 70k [64k..76k] 16% | 0.59 [0.56..0.61] 7% | 1.93→2.01 | 3 | **NOISY** |
| fixed | 100 | 1 | 1 | 4 | 26.1 [26.1..27.1] 4% | 75.8 [67.6..92.2] 32% | 639.0 [258.0..966.7] 111% | 29.81 [29.13..31.02] 6% | 78k [75k..83k] 10% | 0.56 [0.56..0.58] 5% | 3.86→3.86 | 3 | **NOISY** |
| fixed | 500 | 1 | 1 | 4 | 26.1 [24.1..27.1] 12% | 71.7 [62.5..75.8] 19% | 385.0 [241.7..868.4] 163% | 24.75 [23.30..25.37] 8% | 90k [85k..99k] 16% | 0.54 [0.52..0.55] 7% | 1.90→1.90 | 3 | **NOISY** |
| fixed | 1000 | 1 | 1 | 4 | 28.2 [27.1..29.2] 7% | 88.1 [71.7..104.4] 37% | 639.0 [167.9..1474.6] 204% | 22.29 [21.80..23.24] 6% | 94k [88k..98k] 11% | 0.50 [0.47..0.52] 10% | 2.95→2.95 | 3 | **NOISY** |
| fixed | 2000 | 1 | 1 | 4 | 24.1 [22.0..24.1] 8% | 75.8 [71.7..92.2] 27% | 434.2 [233.5..704.5] 108% | 14.76 [14.09..15.41] 9% | 143k [131k..149k] 13% | 0.49 [0.47..0.50] 6% | 3.74→3.74 | 3 | **NOISY** |
| fixed | 5000 | 1 | 1 | 4 | 2.0 [1.9..2.1] 11% | 31.2 [28.2..37.9] 31% | 79.9 [67.6..143.4] 95% | 4.39 [4.22..4.60] 9% | 818k [726k..865k] 17% | 0.68 [0.64..0.70] 9% | 2.43→2.55 | 3 | **NOISY** |
| fixed | 10000 | 1 | 1 | 4 | 1.9 [1.9..2.1] 12% | 10.5 [8.4..12.5] 39% | 71.7 [60.4..92.2] 44% | 4.18 [3.90..4.41] 12% | 886k [849k..965k] 13% | 0.71 [0.69..0.72] 4% | 2.40→2.53 | 3 | **NOISY** |
| fixed | 20000 | 1 | 1 | 4 | 2.0 [1.9..2.0] 3% | 8.4 [7.3..12.0] 56% | 79.9 [56.3..96.3] 50% | 4.11 [4.04..4.17] 3% | 885k [874k..935k] 7% | 0.70 [0.67..0.72] 6% | 2.15→2.30 | 3 | **NOISY** |
| fixed | 50000 | 1 | 1 | 4 | 1.9 [1.8..2.0] 7% | 8.1 [7.3..12.5] 65% | 56.3 [42.0..92.2] 89% | 4.05 [3.99..4.14] 4% | 923k [886k..957k] 8% | 0.71 [0.68..0.72] 7% | 3.91→3.92 | 3 | **NOISY** |
| fixed | inf | 1 | 1 | 4 | 2.0 [1.9..2.0] 7% | 7.8 [6.8..12.0] 67% | 39.9 [23.0..124.9] 255% | 4.22 [4.06..4.61] 13% | 938k [842k..981k] 15% | 0.76 [0.75..0.76] 2% | 4.96→4.88 | 3 | **NOISY** |
| fixed | 0 | 1 | 5 | 4 | 26.1 [26.1..27.1] 4% | 79.9 [75.8..100.4] 31% | 540.7 [270.3..1032.2] 141% | 34.64 [33.63..35.12] 4% | 64k [64k..67k] 6% | 0.55 [0.53..0.56] 5% | 3.15→2.98 | 3 | **NOISY** |
| fixed | 100 | 1 | 5 | 4 | 26.1 [26.1..27.1] 4% | 92.2 [79.9..100.4] 22% | 639.0 [417.8..1474.6] 165% | 33.93 [32.96..34.35] 4% | 65k [64k..69k] 8% | 0.54 [0.53..0.55] 4% | 3.54→3.54 | 3 | **NOISY** |
| fixed | 500 | 1 | 5 | 4 | 27.1 [27.1..28.2] 4% | 79.9 [79.9..92.2] 15% | 450.6 [335.9..483.3] 33% | 34.36 [33.42..35.72] 7% | 67k [65k..69k] 6% | 0.56 [0.55..0.56] 2% | 4.95→4.95 | 3 | **NOISY** |
| fixed | 1000 | 1 | 5 | 4 | 28.2 [27.1..28.2] 4% | 88.1 [84.0..92.2] 9% | 737.3 [573.4..999.4] 58% | 34.12 [32.00..34.90] 8% | 66k [63k..71k] 12% | 0.55 [0.48..0.56] 14% | 3.69→3.63 | 1 | ok |
| fixed | 2000 | 1 | 5 | 4 | 25.1 [25.1..26.1] 4% | 96.3 [79.9..167.9] 92% | 868.4 [483.3..2162.7] 193% | 29.64 [27.98..30.84] 10% | 75k [69k..82k] 17% | 0.54 [0.52..0.57] 9% | 2.93→3.01 | 3 | **NOISY** |
| fixed | 5000 | 1 | 5 | 4 | 2.9 [2.9..3.1] 9% | 67.6 [64.5..75.8] 17% | 233.5 [233.5..434.2] 86% | 18.02 [17.78..18.67] 5% | 145k [137k..154k] 12% | 0.64 [0.59..0.65] 9% | 2.50→2.62 | 3 | **NOISY** |
| fixed | 10000 | 1 | 5 | 4 | 1.8 [1.8..1.9] 7% | 54.3 [50.2..54.3] 8% | 143.4 [92.2..249.9] 110% | 10.18 [9.94..10.46] 5% | 325k [321k..342k] 6% | 0.76 [0.73..0.77] 5% | 4.18→4.16 | 2 | ok |
| fixed | 20000 | 1 | 5 | 4 | 1.8 [1.7..1.8] 7% | 7.8 [6.5..13.6] 90% | 108.5 [67.6..233.5] 153% | 7.68 [7.53..7.83] 4% | 492k [449k..513k] 13% | 0.83 [0.76..0.84] 11% | 2.79→2.79 | 3 | **NOISY** |
| fixed | 50000 | 1 | 5 | 4 | 1.8 [1.7..1.8] 7% | 7.8 [5.8..12.0] 80% | 124.9 [42.0..335.9] 235% | 7.82 [7.51..8.16] 8% | 482k [441k..527k] 18% | 0.82 [0.78..0.86] 9% | 3.54→3.57 | 3 | **NOISY** |
| fixed | inf | 1 | 5 | 4 | 1.8 [1.8..1.8] 4% | 7.8 [6.5..12.0] 70% | 96.3 [62.5..151.6] 93% | 8.11 [7.75..8.45] 9% | 482k [458k..513k] 12% | 0.86 [0.85..0.87] 2% | 5.46→5.46 | 3 | **NOISY** |
| fixed | 0 | 1 | 20 | 4 | 28.2 [27.1..29.2] 7% | 88.1 [84.0..104.4] 23% | 540.7 [217.1..1671.2] 269% | 34.52 [32.93..35.54] 8% | 52k [50k..54k] 8% | 0.43 [0.42..0.44] 6% | 3.47→3.28 | 3 | **NOISY** |
| fixed | 100 | 1 | 20 | 4 | 28.2 [26.1..29.2] 11% | 96.3 [79.9..135.2] 57% | 704.5 [352.3..1081.3] 103% | 34.55 [33.28..36.33] 9% | 51k [50k..55k] 10% | 0.44 [0.42..0.44] 5% | 2.64→2.50 | 3 | **NOISY** |
| fixed | 500 | 1 | 20 | 4 | 27.1 [26.1..28.2] 8% | 84.0 [75.8..100.4] 29% | 241.7 [151.6..770.0] 256% | 34.30 [33.15..38.45] 16% | 55k [48k..56k] 15% | 0.45 [0.44..0.46] 4% | 3.65→3.59 | 3 | **NOISY** |
| fixed | 1000 | 1 | 20 | 4 | 27.1 [26.1..28.2] 8% | 75.8 [71.7..92.2] 27% | 385.0 [143.4..802.8] 171% | 34.20 [32.68..36.85] 12% | 56k [52k..58k] 11% | 0.46 [0.44..0.47] 5% | 2.64→2.64 | 3 | **NOISY** |
| fixed | 2000 | 1 | 20 | 4 | 27.1 [26.1..28.2] 8% | 96.3 [84.0..135.2] 53% | 704.5 [540.7..999.4] 65% | 35.58 [34.29..37.52] 9% | 55k [50k..56k] 12% | 0.47 [0.46..0.48] 5% | 3.35→3.32 | 3 | **NOISY** |
| fixed | 5000 | 1 | 20 | 4 | 22.0 [20.0..25.1] 23% | 79.9 [71.7..1867.8] 2249% | 434.2 [319.5..3866.6] 817% | 33.74 [32.51..36.58] 12% | 66k [35k..69k] 51% | 0.53 [0.31..0.54] 43% | 3.32→3.32 | 3 | **NOISY** |
| fixed | 10000 | 1 | 20 | 4 | 4.2 [3.9..4.7] 20% | 75.8 [67.6..88.1] 27% | 466.9 [225.3..802.8] 124% | 31.33 [30.25..31.67] 4% | 81k [75k..88k] 16% | 0.62 [0.57..0.64] 11% | 2.83→2.92 | 3 | **NOISY** |
| fixed | 20000 | 1 | 20 | 4 | 1.8 [1.8..2.0] 10% | 67.6 [60.4..71.7] 17% | 286.7 [124.9..639.0] 179% | 27.91 [27.26..28.59] 5% | 114k [108k..121k] 12% | 0.78 [0.75..0.80] 6% | 4.56→4.52 | 3 | **NOISY** |
| fixed | 50000 | 1 | 20 | 4 | 1.8 [1.7..1.8] 7% | 23.0 [21.0..37.9] 73% | 208.9 [100.4..639.0] 258% | 23.01 [22.87..23.35] 2% | 166k [150k..170k] 12% | 0.91 [0.83..0.93] 11% | 2.20→2.20 | 3 | **NOISY** |
| fixed | inf | 1 | 20 | 4 | 1.8 [1.7..1.8] 7% | 13.1 [6.0..24.1] 138% | 159.7 [129.0..671.7] 340% | 23.22 [22.84..25.66] 12% | 170k [151k..173k] 13% | 0.94 [0.93..0.95] 2% | 2.94→3.02 | 3 | **NOISY** |
| fixed | 0 | 1 | 100 | 4 | 33.8 [33.8..33.8] 0% | 112.6 [92.2..120.8] 26% | 704.5 [385.0..1933.3] 220% | 42.43 [40.65..43.38] 6% | 25k [24k..26k] 6% | 0.26 [0.26..0.26] 3% | 3.98→3.66 | 3 | **NOISY** |
| fixed | 100 | 1 | 100 | 4 | 31.2 [30.2..33.8] 12% | 96.3 [71.7..143.4] 74% | 966.7 [225.3..1605.6] 143% | 40.30 [38.30..41.57] 8% | 26k [25k..27k] 6% | 0.25 [0.25..0.26] 4% | 2.20→2.27 | 3 | **NOISY** |
| fixed | 500 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 120.8 [75.8..167.9] 76% | 1081.3 [217.1..3997.7] 350% | 43.87 [41.19..45.21] 9% | 25k [21k..26k] 20% | 0.26 [0.24..0.27] 14% | 4.88→4.88 | 3 | **NOISY** |
| fixed | 1000 | 1 | 100 | 4 | 32.3 [32.3..33.8] 5% | 124.9 [84.0..671.7] 470% | 999.4 [319.5..5373.9] 506% | 44.31 [42.18..46.48] 10% | 25k [22k..26k] 18% | 0.27 [0.25..0.28] 11% | 2.73→2.75 | 3 | **NOISY** |
| fixed | 2000 | 1 | 100 | 4 | 33.8 [33.8..33.8] 0% | 108.5 [84.0..151.6] 62% | 639.0 [241.7..835.6] 93% | 45.75 [44.76..47.02] 5% | 25k [25k..26k] 5% | 0.29 [0.28..0.29] 3% | 2.73→2.73 | 3 | **NOISY** |
| fixed | 5000 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 112.6 [84.0..167.9] 74% | 868.4 [450.6..4325.4] 446% | 51.34 [49.07..51.89] 6% | 26k [24k..27k] 11% | 0.32 [0.30..0.33] 8% | 3.38→3.11 | 3 | **NOISY** |
| fixed | 10000 | 1 | 100 | 4 | 31.2 [30.2..32.3] 7% | 104.4 [92.2..270.3] 171% | 1278.0 [516.1..5898.2] 421% | 56.24 [54.38..59.87] 10% | 26k [24k..28k] 15% | 0.35 [0.35..0.38] 9% | 3.47→3.35 | 3 | **NOISY** |
| fixed | 20000 | 1 | 100 | 4 | 15.6 [15.1..16.1] 7% | 88.1 [71.7..96.3] 28% | 704.5 [352.3..999.4] 92% | 62.03 [61.20..63.40] 4% | 30k [29k..31k] 6% | 0.46 [0.45..0.46] 3% | 2.98→2.74 | 3 | **NOISY** |
| fixed | 50000 | 1 | 100 | 4 | 2.1 [2.0..2.1] 4% | 88.1 [79.9..116.7] 42% | 671.7 [286.7..901.1] 92% | 80.74 [79.77..81.77] 2% | 33k [32k..33k] 3% | 0.65 [0.64..0.66] 2% | 2.41→2.41 | 3 | **NOISY** |
| fixed | inf | 1 | 100 | 4 | 1.8 [1.7..2.0] 18% | 16.1 [6.3..25.1] 117% | 868.4 [401.4..1278.0] 101% | 104.53 [103.47..105.66] 2% | 38k [37k..38k] 3% | 0.97 [0.97..0.98] 1% | 3.95→3.95 | 3 | **NOISY** |
| fixed | 0 | 10 | 0 | 4 | 42.0 [42.0..42.0] 0% | 135.2 [124.9..143.4] 14% | 639.0 [225.3..1409.0] 185% | 21.98 [21.30..22.31] 5% | 81k [79k..86k] 8% | 0.24 [0.24..0.25] 5% | 2.00→2.00 | 3 | **NOISY** |
| fixed | 100 | 10 | 0 | 4 | 44.0 [42.0..46.1] 9% | 143.4 [135.2..176.1] 29% | 802.8 [450.6..2555.9] 262% | 23.00 [22.78..23.66] 4% | 77k [73k..79k] 8% | 0.25 [0.24..0.26] 8% | 2.69→2.63 | 3 | **NOISY** |
| fixed | 500 | 10 | 0 | 4 | 46.1 [44.0..48.1] 9% | 143.4 [135.2..151.6] 11% | 385.0 [217.1..516.1] 78% | 24.19 [23.51..25.25] 7% | 77k [73k..79k] 8% | 0.27 [0.27..0.28] 4% | 3.88→3.73 | 3 | **NOISY** |
| fixed | 1000 | 10 | 0 | 4 | 42.0 [39.9..42.0] 5% | 143.4 [129.0..167.9] 27% | 704.5 [286.7..1343.5] 150% | 22.82 [22.18..23.33] 5% | 81k [77k..85k] 9% | 0.26 [0.25..0.27] 6% | 4.74→4.52 | 3 | **NOISY** |
| fixed | 2000 | 10 | 0 | 4 | 39.9 [37.9..42.0] 10% | 135.2 [112.6..143.4] 23% | 704.5 [176.1..2064.4] 268% | 23.21 [22.02..24.03] 9% | 83k [77k..92k] 19% | 0.28 [0.26..0.28] 6% | 3.91→3.91 | 3 | **NOISY** |
| fixed | 5000 | 10 | 0 | 4 | 39.9 [37.9..39.9] 5% | 135.2 [124.9..143.4] 14% | 401.4 [270.3..737.3] 116% | 25.63 [25.08..26.25] 5% | 87k [82k..89k] 8% | 0.34 [0.33..0.34] 3% | 4.46→4.34 | 3 | **NOISY** |
| fixed | 10000 | 10 | 0 | 4 | 32.3 [31.2..33.8] 8% | 135.2 [135.2..143.4] 6% | 499.7 [303.1..770.0] 93% | 26.47 [25.59..27.45] 7% | 101k [92k..106k] 13% | 0.42 [0.39..0.44] 12% | 2.08→2.08 | 2 | ok |
| fixed | 20000 | 10 | 0 | 4 | 17.9 [16.9..18.9] 11% | 120.8 [112.6..143.4] 25% | 434.2 [270.3..540.7] 62% | 21.79 [21.21..23.30] 10% | 161k [150k..167k] 11% | 0.48 [0.46..0.50] 8% | 4.03→4.03 | 3 | **NOISY** |
| fixed | 50000 | 10 | 0 | 4 | 16.9 [16.9..18.9] 12% | 100.4 [84.0..108.5] 24% | 270.3 [176.1..639.0] 171% | 20.77 [20.01..21.09] 5% | 185k [175k..196k] 11% | 0.49 [0.47..0.51] 7% | 2.51→2.63 | 3 | **NOISY** |
| fixed | inf | 10 | 0 | 4 | 18.9 [17.9..18.9] 5% | 92.2 [88.1..108.5] 22% | 270.3 [192.5..434.2] 89% | 21.30 [20.42..22.35] 9% | 185k [176k..194k] 10% | 0.52 [0.51..0.54] 7% | 2.54→2.65 | 3 | **NOISY** |
| fixed | 0 | 10 | 1 | 4 | 37.9 [37.9..39.9] 5% | 116.7 [104.4..135.2] 26% | 450.6 [270.3..868.4] 133% | 41.66 [40.13..42.22] 5% | 56k [55k..58k] 6% | 0.45 [0.44..0.45] 2% | 3.71→3.65 | 3 | **NOISY** |
| fixed | 100 | 10 | 1 | 4 | 39.9 [37.9..39.9] 5% | 120.8 [112.6..143.4] 25% | 671.7 [249.9..2064.4] 270% | 39.68 [38.87..40.84] 5% | 57k [55k..59k] 8% | 0.43 [0.41..0.44] 8% | 3.65→3.65 | 3 | **NOISY** |
| fixed | 500 | 10 | 1 | 4 | 39.9 [37.9..44.0] 15% | 124.9 [112.6..151.6] 31% | 516.1 [417.8..1081.3] 129% | 34.70 [32.81..37.32] 13% | 63k [59k..67k] 14% | 0.38 [0.37..0.40] 7% | 2.66→2.66 | 3 | **NOISY** |
| fixed | 1000 | 10 | 1 | 4 | 42.0 [39.9..42.0] 5% | 129.0 [120.8..151.6] 24% | 450.6 [434.2..868.4] 96% | 31.25 [30.11..32.72] 8% | 68k [63k..70k] 10% | 0.36 [0.34..0.36] 6% | 3.01→3.09 | 3 | **NOISY** |
| fixed | 2000 | 10 | 1 | 4 | 42.0 [39.9..44.0] 10% | 143.4 [135.2..184.3] 34% | 835.6 [450.6..3735.6] 393% | 28.34 [26.98..29.15] 8% | 72k [61k..76k] 22% | 0.33 [0.29..0.33] 13% | 2.83→2.76 | 3 | **NOISY** |
| fixed | 5000 | 10 | 1 | 4 | 39.9 [37.9..39.9] 5% | 135.2 [124.9..151.6] 20% | 573.4 [303.1..1081.3] 136% | 27.55 [26.70..28.06] 5% | 80k [78k..86k] 10% | 0.35 [0.33..0.36] 10% | 3.90→3.83 | 3 | **NOISY** |
| fixed | 10000 | 10 | 1 | 4 | 32.3 [29.2..33.8] 14% | 135.2 [129.0..151.6] 17% | 450.6 [270.3..933.9] 147% | 28.68 [27.19..29.22] 7% | 94k [93k..103k] 11% | 0.44 [0.43..0.45] 4% | 3.46→3.42 | 3 | **NOISY** |
| fixed | 20000 | 10 | 1 | 4 | 15.1 [14.6..15.6] 7% | 116.7 [108.5..135.2] 23% | 483.3 [319.5..704.5] 80% | 23.93 [23.54..24.90] 6% | 147k [137k..150k] 8% | 0.51 [0.49..0.52] 5% | 3.85→3.87 | 3 | **NOISY** |
| fixed | 50000 | 10 | 1 | 4 | 13.6 [13.1..14.1] 8% | 79.9 [71.7..92.2] 26% | 233.5 [135.2..671.7] 230% | 22.39 [21.91..23.01] 5% | 172k [158k..181k] 14% | 0.53 [0.51..0.54] 5% | 2.27→2.27 | 3 | **NOISY** |
| fixed | inf | 10 | 1 | 4 | 13.6 [13.1..14.1] 8% | 79.9 [71.7..84.0] 15% | 417.8 [167.9..639.0] 113% | 23.17 [21.96..24.14] 9% | 170k [160k..181k] 12% | 0.56 [0.54..0.58] 6% | 2.57→2.68 | 3 | **NOISY** |
| fixed | 0 | 10 | 5 | 4 | 39.9 [35.8..39.9] 10% | 116.7 [108.5..225.3] 100% | 802.8 [434.2..3211.3] 346% | 43.92 [40.51..44.25] 8% | 51k [44k..55k] 21% | 0.42 [0.36..0.44] 18% | 3.59→3.59 | 3 | **NOISY** |
| fixed | 100 | 10 | 5 | 4 | 39.9 [37.9..42.0] 10% | 129.0 [112.6..176.1] 49% | 704.5 [352.3..1933.3] 224% | 42.83 [42.21..45.71] 8% | 50k [49k..52k] 7% | 0.42 [0.40..0.43] 8% | 5.11→5.11 | 3 | **NOISY** |
| fixed | 500 | 10 | 5 | 4 | 37.9 [35.8..39.9] 11% | 108.5 [104.4..151.6] 43% | 368.6 [217.1..1867.8] 448% | 39.83 [38.42..43.54] 13% | 56k [49k..58k] 16% | 0.41 [0.41..0.43] 4% | 2.83→2.84 | 3 | **NOISY** |
| fixed | 1000 | 10 | 5 | 4 | 42.0 [39.9..42.0] 5% | 129.0 [112.6..167.9] 43% | 770.0 [225.3..1081.3] 111% | 43.18 [42.78..44.46] 4% | 52k [49k..53k] 6% | 0.43 [0.42..0.45] 7% | 2.08→2.08 | 3 | **NOISY** |
| fixed | 2000 | 10 | 5 | 4 | 39.9 [37.9..42.0] 10% | 120.8 [116.7..143.4] 22% | 466.9 [184.3..1540.1] 290% | 41.93 [39.99..42.43] 6% | 55k [52k..57k] 10% | 0.43 [0.41..0.44] 6% | 2.69→2.69 | 3 | **NOISY** |
| fixed | 5000 | 10 | 5 | 4 | 37.9 [37.9..37.9] 0% | 124.9 [120.8..159.7] 31% | 1343.5 [466.9..1736.7] 94% | 37.16 [36.28..38.04] 5% | 63k [61k..66k] 8% | 0.43 [0.42..0.44] 5% | 6.47→6.19 | 3 | **NOISY** |
| fixed | 10000 | 10 | 5 | 4 | 27.1 [26.1..28.2] 8% | 116.7 [108.5..124.9] 14% | 417.8 [249.9..802.8] 132% | 31.89 [30.90..32.31] 4% | 92k [87k..94k] 8% | 0.50 [0.48..0.51] 4% | 3.83→3.84 | 3 | **NOISY** |
| fixed | 20000 | 10 | 5 | 4 | 13.6 [13.1..14.1] 8% | 96.3 [79.9..108.5] 30% | 303.1 [176.1..573.4] 131% | 26.82 [26.05..27.87] 7% | 134k [124k..144k] 15% | 0.58 [0.55..0.59] 6% | 5.41→5.22 | 3 | **NOISY** |
| fixed | 50000 | 10 | 5 | 4 | 12.5 [12.5..13.1] 4% | 71.7 [58.4..75.8] 24% | 303.1 [192.5..901.1] 234% | 25.74 [24.65..26.04] 5% | 148k [139k..157k] 12% | 0.57 [0.54..0.59] 9% | 5.02→4.94 | 3 | **NOISY** |
| fixed | inf | 10 | 5 | 4 | 13.1 [12.5..13.1] 4% | 71.7 [64.5..75.8] 16% | 401.4 [176.1..540.7] 91% | 26.97 [25.77..29.05] 12% | 145k [135k..155k] 14% | 0.62 [0.61..0.64] 5% | 3.70→3.73 | 3 | **NOISY** |
| fixed | 0 | 10 | 20 | 4 | 42.0 [39.9..44.0] 10% | 124.9 [116.7..225.3] 87% | 671.7 [368.6..1867.8] 223% | 44.65 [42.90..46.43] 8% | 41k [39k..43k] 8% | 0.35 [0.35..0.37] 6% | 2.42→2.42 | 3 | **NOISY** |
| fixed | 100 | 10 | 20 | 4 | 42.0 [42.0..44.0] 5% | 135.2 [124.9..286.7] 120% | 1081.3 [352.3..2293.8] 180% | 44.75 [43.72..45.48] 4% | 41k [39k..42k] 8% | 0.35 [0.34..0.36] 7% | 3.65→3.52 | 3 | **NOISY** |
| fixed | 500 | 10 | 20 | 4 | 42.0 [39.9..44.0] 10% | 135.2 [112.6..143.4] 23% | 770.0 [671.7..1146.9] 62% | 43.99 [42.38..46.52] 9% | 42k [40k..43k] 8% | 0.36 [0.35..0.37] 5% | 6.61→6.61 | 3 | **NOISY** |
| fixed | 1000 | 10 | 20 | 4 | 39.9 [39.9..42.0] 5% | 124.9 [112.6..143.4] 25% | 671.7 [516.1..1671.2] 172% | 43.55 [42.48..45.19] 6% | 43k [42k..45k] 6% | 0.36 [0.35..0.37] 6% | 4.31→4.29 | 3 | **NOISY** |
| fixed | 2000 | 10 | 20 | 4 | 39.9 [39.9..42.0] 5% | 124.9 [112.6..385.0] 218% | 573.4 [270.3..3997.7] 650% | 45.71 [43.37..46.14] 6% | 43k [35k..46k] 24% | 0.38 [0.31..0.39] 20% | 2.51→2.47 | 3 | **NOISY** |
| fixed | 5000 | 10 | 20 | 4 | 39.9 [37.9..42.0] 10% | 129.0 [116.7..151.6] 27% | 606.2 [401.4..1409.0] 166% | 48.65 [46.28..51.83] 11% | 44k [42k..47k] 13% | 0.43 [0.42..0.44] 3% | 4.30→4.19 | 3 | **NOISY** |
| fixed | 10000 | 10 | 20 | 4 | 31.2 [30.2..32.3] 7% | 112.6 [108.5..124.9] 14% | 606.2 [434.2..2162.7] 285% | 46.12 [45.87..47.75] 4% | 56k [52k..57k] 9% | 0.51 [0.49..0.51] 5% | 4.79→4.79 | 3 | **NOISY** |
| fixed | 20000 | 10 | 20 | 4 | 13.1 [11.5..14.1] 20% | 100.4 [84.0..129.0] 45% | 434.2 [241.7..1032.2] 182% | 43.44 [41.01..45.92] 11% | 75k [68k..82k] 18% | 0.63 [0.61..0.65] 6% | 3.96→3.96 | 3 | **NOISY** |
| fixed | 50000 | 10 | 20 | 4 | 11.0 [10.5..11.0] 5% | 60.4 [58.4..75.8] 29% | 352.3 [176.1..606.2] 122% | 38.09 [37.00..39.07] 5% | 102k [94k..103k] 9% | 0.70 [0.69..0.72] 5% | 2.51→2.51 | 3 | **NOISY** |
| fixed | inf | 10 | 20 | 4 | 11.0 [10.5..11.5] 9% | 50.2 [48.1..96.3] 96% | 303.1 [159.7..671.7] 169% | 38.33 [37.24..41.79] 12% | 103k [93k..106k] 13% | 0.73 [0.72..0.74] 3% | 3.74→3.74 | 3 | **NOISY** |
| fixed | 0 | 10 | 100 | 4 | 44.0 [42.0..44.0] 5% | 135.2 [120.8..225.3] 77% | 999.4 [516.1..1736.7] 122% | 50.86 [47.54..52.19] 9% | 23k [22k..24k] 7% | 0.23 [0.22..0.24] 6% | 2.27→2.25 | 3 | **NOISY** |
| fixed | 100 | 10 | 100 | 4 | 44.0 [42.0..48.1] 14% | 124.9 [108.5..151.6] 34% | 737.3 [286.7..1736.7] 197% | 50.74 [49.23..53.81] 9% | 23k [22k..24k] 5% | 0.23 [0.23..0.25] 7% | 2.57→2.57 | 3 | **NOISY** |
| fixed | 500 | 10 | 100 | 4 | 46.1 [44.0..46.1] 4% | 135.2 [124.9..176.1] 38% | 966.7 [352.3..1933.3] 164% | 53.45 [51.50..55.88] 8% | 23k [22k..23k] 8% | 0.24 [0.24..0.25] 4% | 4.08→4.08 | 3 | **NOISY** |
| fixed | 1000 | 10 | 100 | 4 | 44.0 [42.0..44.0] 5% | 143.4 [104.4..176.1] 50% | 1146.9 [540.7..2064.4] 133% | 51.32 [49.64..53.26] 7% | 23k [21k..24k] 12% | 0.24 [0.22..0.25] 10% | 6.37→5.94 | 3 | **NOISY** |
| fixed | 2000 | 10 | 100 | 4 | 42.0 [39.9..44.0] 10% | 120.8 [104.4..143.4] 32% | 770.0 [270.3..1343.5] 139% | 52.25 [50.14..55.98] 11% | 24k [23k..25k] 9% | 0.25 [0.25..0.26] 5% | 2.43→2.32 | 3 | **NOISY** |
| fixed | 5000 | 10 | 100 | 4 | 42.0 [42.0..44.0] 5% | 112.6 [96.3..159.7] 56% | 540.7 [176.1..1474.6] 240% | 58.65 [57.36..60.39] 5% | 24k [24k..25k] 3% | 0.29 [0.28..0.30] 6% | 3.78→3.78 | 3 | **NOISY** |
| fixed | 10000 | 10 | 100 | 4 | 42.0 [39.9..44.0] 10% | 120.8 [104.4..167.9] 52% | 1278.0 [270.3..3211.3] 230% | 66.41 [66.01..72.59] 10% | 24k [21k..25k] 17% | 0.35 [0.33..0.35] 6% | 2.26→2.08 | 3 | **NOISY** |
| fixed | 20000 | 10 | 100 | 4 | 29.2 [26.1..30.2] 14% | 104.4 [92.2..135.2] 41% | 1146.9 [176.1..1867.8] 148% | 76.98 [75.34..79.19] 5% | 27k [25k..27k] 7% | 0.44 [0.43..0.45] 5% | 6.26→6.00 | 3 | **NOISY** |
| fixed | 50000 | 10 | 100 | 4 | 11.0 [11.0..11.5] 5% | 88.1 [79.9..116.7] 42% | 417.8 [335.9..2064.4] 414% | 91.23 [90.28..93.49] 4% | 31k [29k..31k] 6% | 0.62 [0.60..0.63] 5% | 2.39→2.19 | 3 | **NOISY** |
| fixed | inf | 10 | 100 | 4 | 10.5 [10.5..10.5] 0% | 42.0 [31.2..50.2] 45% | 1343.5 [401.4..1867.8] 109% | 114.91 [113.20..123.98] 9% | 34k [32k..35k] 10% | 0.90 [0.90..0.91] 1% | 2.83→2.93 | 3 | **NOISY** |
| ema | cap 5000 | 0.1 | 0 | 4 | 1.1 [1.1..1.2] 11% | 39.9 [37.9..48.1] 26% | 75.8 [64.5..135.2] 93% | 2.28 [2.06..2.74] 30% | 1093k [854k..1264k] 38% | 0.59 [0.55..0.62] 12% | 2.96→2.80 | 3 | **NOISY** |
| ema | cap 20000 | 0.1 | 0 | 4 | 1.1 [1.1..1.1] 6% | 44.0 [42.0..48.1] 14% | 92.2 [88.1..129.0] 44% | 2.58 [2.21..2.73] 20% | 912k [832k..1090k] 28% | 0.57 [0.54..0.59] 9% | 3.21→3.11 | 3 | **NOISY** |
| ema | cap 5000 | 0.1 | 1 | 4 | 1.2 [1.1..1.4] 20% | 62.5 [58.4..79.9] 34% | 167.9 [120.8..319.5] 118% | 8.41 [8.20..8.79] 7% | 286k [262k..292k] 10% | 0.59 [0.56..0.60] 6% | 3.97→3.97 | 3 | **NOISY** |
| ema | cap 20000 | 0.1 | 1 | 4 | 1.2 [1.2..1.2] 5% | 62.5 [60.4..64.5] 7% | 192.5 [116.7..286.7] 88% | 8.39 [8.22..8.63] 5% | 277k [260k..283k] 8% | 0.58 [0.55..0.59] 6% | 2.00→2.08 | 1 | ok |
| ema | cap 5000 | 0.1 | 5 | 4 | 2.1 [1.9..2.6] 35% | 67.6 [62.5..75.8] 20% | 217.1 [100.4..639.0] 248% | 18.26 [17.31..19.09] 10% | 146k [137k..158k] 14% | 0.66 [0.63..0.68] 7% | 2.18→2.16 | 3 | **NOISY** |
| ema | cap 20000 | 0.1 | 5 | 4 | 1.2 [1.1..1.2] 11% | 64.5 [60.4..71.7] 18% | 200.7 [120.8..335.9] 107% | 14.32 [13.78..14.71] 6% | 186k [174k..197k] 13% | 0.66 [0.63..0.68] 6% | 3.54→3.58 | 3 | **NOISY** |
| ema | cap 5000 | 0.1 | 20 | 4 | 16.9 [13.6..18.9] 32% | 75.8 [67.6..84.0] 22% | 270.3 [167.9..540.7] 138% | 31.45 [30.47..32.62] 7% | 70k [68k..74k] 8% | 0.55 [0.54..0.56] 3% | 2.92→2.84 | 3 | **NOISY** |
| ema | cap 20000 | 0.1 | 20 | 4 | 1.2 [1.1..1.2] 5% | 75.8 [71.7..84.0] 16% | 368.6 [124.9..933.9] 219% | 28.23 [28.11..29.10] 4% | 96k [80k..99k] 20% | 0.68 [0.58..0.70] 17% | 2.47→2.35 | 3 | **NOISY** |
| ema | cap 5000 | 0.1 | 100 | 4 | 32.3 [32.3..33.8] 5% | 124.9 [112.6..233.5] 97% | 901.1 [671.7..3342.3] 296% | 50.95 [49.55..51.90] 5% | 26k [25k..26k] 5% | 0.33 [0.31..0.33] 6% | 3.47→3.35 | 3 | **NOISY** |
| ema | cap 20000 | 0.1 | 100 | 4 | 16.1 [15.6..16.9] 8% | 79.9 [75.8..143.4] 85% | 770.0 [192.5..1867.8] 218% | 61.35 [60.23..63.04] 5% | 30k [28k..30k] 8% | 0.45 [0.44..0.46] 5% | 2.26→2.16 | 3 | **NOISY** |
| ema | cap 5000 | 1 | 0 | 4 | 2.6 [2.6..2.8] 5% | 54.3 [52.2..56.3] 8% | 124.9 [84.0..233.5] 120% | 5.28 [5.18..5.34] 3% | 476k [452k..491k] 8% | 0.51 [0.49..0.53] 8% | 2.48→2.52 | 3 | ok |
| ema | cap 20000 | 1 | 0 | 4 | 2.8 [2.5..2.8] 9% | 56.3 [52.2..56.3] 7% | 124.9 [92.2..258.0] 133% | 5.36 [4.98..5.46] 9% | 474k [457k..516k] 12% | 0.52 [0.50..0.53] 7% | 2.39→2.39 | 2 | ok |
| ema | cap 5000 | 1 | 1 | 4 | 2.4 [2.2..2.4] 5% | 60.4 [56.3..64.5] 14% | 159.7 [92.2..200.7] 68% | 8.71 [8.47..9.09] 7% | 300k [287k..311k] 8% | 0.58 [0.57..0.60] 6% | 2.52→2.52 | 3 | **NOISY** |
| ema | cap 20000 | 1 | 1 | 4 | 2.4 [2.4..2.5] 5% | 62.5 [60.4..62.5] 3% | 167.9 [120.8..217.1] 57% | 8.84 [8.77..8.95] 2% | 299k [294k..307k] 4% | 0.59 [0.57..0.60] 5% | 2.55→2.50 | 1 | ok |
| ema | cap 5000 | 1 | 5 | 4 | 3.3 [3.1..3.6] 16% | 75.8 [67.6..96.3] 38% | 368.6 [270.3..540.7] 73% | 18.84 [18.36..20.04] 9% | 141k [125k..147k] 15% | 0.63 [0.59..0.64] 7% | 2.86→2.79 | 3 | **NOISY** |
| ema | cap 20000 | 1 | 5 | 4 | 2.1 [2.0..2.1] 8% | 67.6 [58.4..108.5] 74% | 159.7 [100.4..573.4] 296% | 14.84 [14.07..15.41] 9% | 189k [175k..208k] 17% | 0.65 [0.63..0.68] 7% | 4.76→4.62 | 3 | **NOISY** |
| ema | cap 5000 | 1 | 20 | 4 | 22.0 [21.0..23.0] 9% | 100.4 [79.9..249.9] 169% | 933.9 [434.2..2687.0] 241% | 34.52 [33.35..35.62] 7% | 63k [58k..64k] 10% | 0.52 [0.49..0.54] 10% | 3.11→2.94 | 3 | **NOISY** |
| ema | cap 20000 | 1 | 20 | 4 | 2.0 [2.0..2.2] 14% | 75.8 [71.7..88.1] 22% | 286.7 [184.3..606.2] 147% | 29.42 [28.70..30.90] 8% | 96k [92k..100k] 9% | 0.69 [0.67..0.70] 4% | 3.87→3.87 | 3 | **NOISY** |
| ema | cap 5000 | 1 | 100 | 4 | 33.8 [33.8..35.8] 6% | 124.9 [88.1..151.6] 51% | 1278.0 [270.3..1671.2] 110% | 52.95 [50.72..59.69] 17% | 25k [21k..26k] 20% | 0.32 [0.31..0.34] 9% | 2.34→2.34 | 3 | **NOISY** |
| ema | cap 20000 | 1 | 100 | 4 | 16.9 [16.9..16.9] 0% | 116.7 [104.4..176.1] 61% | 966.7 [606.2..1933.3] 137% | 63.38 [62.69..63.73] 2% | 28k [26k..29k] 10% | 0.44 [0.41..0.46] 10% | 2.97→2.73 | 3 | **NOISY** |
| ema | cap 5000 | 10 | 0 | 4 | 39.9 [37.9..42.0] 10% | 129.0 [120.8..143.4] 18% | 466.9 [225.3..770.0] 117% | 25.90 [25.18..26.84] 6% | 85k [81k..91k] 12% | 0.34 [0.33..0.34] 4% | 3.91→3.92 | 3 | **NOISY** |
| ema | cap 20000 | 10 | 0 | 4 | 18.9 [17.9..20.0] 11% | 124.9 [116.7..135.2] 15% | 483.3 [303.1..540.7] 49% | 22.77 [22.21..23.60] 6% | 145k [130k..152k] 16% | 0.47 [0.41..0.48] 15% | 3.43→3.48 | 3 | **NOISY** |
| ema | cap 5000 | 10 | 1 | 4 | 39.9 [39.9..42.0] 5% | 135.2 [129.0..143.4] 11% | 516.1 [303.1..639.0] 65% | 28.21 [27.78..28.99] 4% | 79k [77k..83k] 7% | 0.37 [0.36..0.37] 2% | 4.92→4.85 | 3 | **NOISY** |
| ema | cap 20000 | 10 | 1 | 4 | 16.9 [15.1..16.9] 11% | 129.0 [100.4..200.7] 78% | 417.8 [233.5..3604.5] 807% | 27.06 [24.82..27.51] 10% | 123k [91k..142k] 42% | 0.53 [0.39..0.54] 28% | 3.64→3.64 | 3 | **NOISY** |
| ema | cap 5000 | 10 | 5 | 4 | 37.9 [35.8..37.9] 5% | 120.8 [112.6..124.9] 10% | 483.3 [270.3..1212.4] 195% | 35.93 [35.23..37.00] 5% | 67k [65k..69k] 6% | 0.44 [0.42..0.44] 4% | 4.44→4.25 | 3 | **NOISY** |
| ema | cap 20000 | 10 | 5 | 4 | 14.6 [14.1..15.6] 10% | 96.3 [92.2..120.8] 30% | 417.8 [225.3..671.7] 107% | 29.74 [29.12..31.62] 8% | 116k [107k..122k] 13% | 0.58 [0.55..0.59] 6% | 2.76→2.86 | 3 | **NOISY** |
| ema | cap 5000 | 10 | 20 | 4 | 37.9 [35.8..39.9] 11% | 143.4 [112.6..1032.2] 641% | 1409.0 [1081.3..3866.6] 198% | 45.94 [44.86..48.14] 7% | 46k [35k..48k] 30% | 0.41 [0.33..0.42] 22% | 3.01→3.01 | 3 | **NOISY** |
| ema | cap 20000 | 10 | 20 | 4 | 13.1 [12.5..14.1] 12% | 104.4 [88.1..135.2] 45% | 368.6 [233.5..1278.0] 283% | 43.85 [41.99..44.75] 6% | 73k [72k..78k] 9% | 0.63 [0.58..0.64] 9% | 3.70→3.64 | 3 | **NOISY** |
| ema | cap 5000 | 10 | 100 | 4 | 46.1 [42.0..48.1] 13% | 143.4 [129.0..208.9] 56% | 1081.3 [671.7..2424.8] 162% | 62.88 [58.62..65.36] 11% | 23k [21k..24k] 11% | 0.29 [0.29..0.30] 4% | 3.24→3.22 | 3 | **NOISY** |
| ema | cap 20000 | 10 | 100 | 4 | 29.2 [29.2..30.2] 4% | 129.0 [108.5..176.1] 52% | 1032.2 [401.4..2064.4] 161% | 78.27 [77.83..79.40] 2% | 26k [25k..26k] 5% | 0.44 [0.43..0.45] 5% | 4.87→4.72 | 3 | **NOISY** |
| pred | cap 5000 | 0.1 | 0 | 4 | 17.9 [1.5..26.1] 137% | 67.6 [58.4..75.8] 26% | 200.7 [108.5..286.7] 89% | 7.88 [5.47..11.10] 72% | 216k [151k..332k] 84% | 0.42 [0.41..0.45] 7% | 2.83→2.83 | 3 | **NOISY** |
| pred | cap 20000 | 0.1 | 0 | 4 | 1.1 [1.1..1.2] 11% | 37.9 [32.3..39.9] 20% | 79.9 [67.6..100.4] 41% | 1.93 [1.68..2.04] 19% | 1496k [1305k..1700k] 26% | 0.67 [0.63..0.70] 10% | 3.93→3.93 | 3 | **NOISY** |
| pred | cap 5000 | 0.1 | 1 | 4 | 21.0 [20.0..26.1] 29% | 67.6 [64.5..75.8] 17% | 200.7 [184.3..401.4] 108% | 11.11 [10.76..13.51] 25% | 171k [136k..179k] 25% | 0.47 [0.45..0.48] 6% | 4.26→4.08 | 3 | **NOISY** |
| pred | cap 20000 | 0.1 | 1 | 4 | 1.1 [1.0..1.1] 11% | 56.3 [50.2..60.4] 18% | 167.9 [88.1..270.3] 108% | 6.23 [5.96..6.54] 9% | 416k [383k..464k] 19% | 0.64 [0.60..0.68] 13% | 3.86→3.86 | 3 | **NOISY** |
| pred | cap 5000 | 0.1 | 5 | 4 | 25.1 [23.0..26.1] 12% | 75.8 [64.5..75.8] 15% | 303.1 [192.5..516.1] 107% | 28.00 [26.18..28.92] 10% | 81k [77k..86k] 12% | 0.56 [0.55..0.56] 2% | 1.80→1.97 | 3 | **NOISY** |
| pred | cap 20000 | 0.1 | 5 | 4 | 1.1 [1.0..1.1] 4% | 62.5 [56.3..75.8] 31% | 233.5 [112.6..540.7] 183% | 12.05 [11.62..12.31] 6% | 243k [213k..261k] 20% | 0.72 [0.65..0.75] 14% | 3.07→2.91 | 3 | **NOISY** |
| pred | cap 5000 | 0.1 | 20 | 4 | 26.1 [26.1..28.2] 8% | 88.1 [71.7..104.4] 37% | 737.3 [217.1..999.4] 106% | 33.79 [32.27..36.10] 11% | 53k [50k..56k] 12% | 0.45 [0.44..0.46] 4% | 3.95→3.71 | 3 | **NOISY** |
| pred | cap 20000 | 0.1 | 20 | 4 | 1.2 [1.1..1.4] 22% | 79.9 [67.6..92.2] 31% | 434.2 [286.7..1212.4] 213% | 30.10 [28.78..31.25] 8% | 90k [86k..100k] 15% | 0.69 [0.65..0.72] 11% | 1.67→1.78 | 3 | **NOISY** |
| pred | cap 5000 | 0.1 | 100 | 4 | 32.3 [32.3..33.8] 5% | 129.0 [96.3..159.7] 49% | 802.8 [606.2..2687.0] 259% | 41.70 [40.82..45.58] 11% | 25k [23k..26k] 8% | 0.26 [0.25..0.27] 7% | 1.89→1.89 | 3 | **NOISY** |
| pred | cap 20000 | 0.1 | 100 | 4 | 20.0 [20.0..21.0] 5% | 84.0 [75.8..184.3] 129% | 704.5 [368.6..2424.8] 292% | 43.62 [42.66..44.75] 5% | 28k [26k..29k] 11% | 0.31 [0.28..0.31] 10% | 3.88→3.88 | 3 | **NOISY** |
| pred | cap 5000 | 1 | 0 | 4 | 26.1 [25.1..26.1] 4% | 71.7 [67.6..135.2] 94% | 286.7 [167.9..671.7] 176% | 12.11 [11.52..12.84] 11% | 136k [123k..146k] 17% | 0.38 [0.36..0.39] 6% | 2.96→2.96 | 3 | **NOISY** |
| pred | cap 20000 | 1 | 0 | 4 | 2.5 [2.5..2.6] 5% | 48.1 [44.0..50.2] 13% | 112.6 [92.2..167.9] 67% | 4.27 [4.18..4.49] 7% | 656k [641k..707k] 10% | 0.55 [0.52..0.57] 10% | 3.01→3.01 | 3 | **NOISY** |
| pred | cap 5000 | 1 | 1 | 4 | 26.1 [24.1..31.2] 28% | 75.8 [71.7..104.4] 43% | 335.9 [217.1..999.4] 233% | 14.13 [13.13..16.80] 26% | 125k [103k..142k] 31% | 0.42 [0.41..0.43] 6% | 4.29→4.29 | 3 | **NOISY** |
| pred | cap 20000 | 1 | 1 | 4 | 2.1 [2.1..2.1] 0% | 52.2 [50.2..54.3] 8% | 129.0 [96.3..208.9] 87% | 7.15 [7.01..7.33] 4% | 401k [372k..415k] 11% | 0.62 [0.59..0.64] 8% | 4.41→4.41 | 3 | ok |
| pred | cap 5000 | 1 | 5 | 4 | 27.1 [26.1..29.2] 11% | 88.1 [75.8..96.3] 23% | 258.0 [233.5..868.4] 246% | 30.87 [29.33..33.53] 14% | 73k [68k..77k] 12% | 0.54 [0.53..0.55] 4% | 4.02→3.94 | 3 | **NOISY** |
| pred | cap 20000 | 1 | 5 | 4 | 1.9 [1.8..2.0] 10% | 64.5 [58.4..64.5] 10% | 270.3 [167.9..516.1] 129% | 12.75 [12.34..12.89] 4% | 232k [211k..250k] 17% | 0.68 [0.62..0.71] 12% | 2.35→2.35 | 1 | ok |
| pred | cap 5000 | 1 | 20 | 4 | 28.2 [28.2..29.2] 4% | 92.2 [84.0..104.4] 22% | 639.0 [368.6..1736.7] 214% | 35.24 [34.66..36.37] 5% | 51k [45k..52k] 14% | 0.44 [0.40..0.45] 11% | 2.07→2.07 | 3 | **NOISY** |
| pred | cap 20000 | 1 | 20 | 4 | 2.1 [2.0..2.1] 4% | 67.6 [62.5..79.9] 26% | 671.7 [135.2..1212.4] 160% | 29.53 [29.25..30.23] 3% | 96k [89k..102k] 14% | 0.68 [0.65..0.72] 10% | 3.60→3.60 | 3 | **NOISY** |
| pred | cap 5000 | 1 | 100 | 4 | 35.8 [33.8..37.9] 11% | 129.0 [116.7..192.5] 59% | 1409.0 [770.0..6160.4] 383% | 44.33 [42.43..46.89] 10% | 24k [22k..24k] 11% | 0.26 [0.25..0.27] 10% | 2.29→2.27 | 3 | **NOISY** |
| pred | cap 20000 | 1 | 100 | 4 | 22.0 [20.0..22.0] 9% | 108.5 [75.8..135.2] 55% | 540.7 [192.5..1671.2] 274% | 46.63 [44.24..48.57] 9% | 27k [26k..29k] 9% | 0.31 [0.30..0.32] 5% | 4.37→4.37 | 3 | **NOISY** |
| pred | cap 5000 | 10 | 0 | 4 | 42.0 [42.0..42.0] 0% | 143.4 [135.2..143.4] 6% | 704.5 [450.6..1081.3] 90% | 21.78 [21.44..22.19] 4% | 80k [79k..83k] 4% | 0.24 [0.23..0.25] 7% | 3.76→3.62 | 2 | ok |
| pred | cap 20000 | 10 | 0 | 4 | 18.9 [18.9..20.0] 5% | 124.9 [120.8..135.2] 12% | 450.6 [303.1..802.8] 111% | 22.39 [22.14..22.98] 4% | 147k [136k..152k] 10% | 0.45 [0.43..0.47] 9% | 2.74→2.76 | 3 | **NOISY** |
| pred | cap 5000 | 10 | 1 | 4 | 42.0 [39.9..44.0] 10% | 143.4 [129.0..200.7] 50% | 1146.9 [368.6..1409.0] 91% | 24.34 [22.50..24.74] 9% | 74k [69k..82k] 18% | 0.26 [0.25..0.27] 7% | 2.21→2.21 | 3 | **NOISY** |
| pred | cap 20000 | 10 | 1 | 4 | 16.1 [15.6..16.9] 8% | 108.5 [100.4..116.7] 15% | 303.1 [176.1..704.5] 174% | 25.07 [24.36..25.54] 5% | 139k [129k..143k] 10% | 0.51 [0.49..0.54] 11% | 2.57→2.69 | 3 | **NOISY** |
| pred | cap 5000 | 10 | 5 | 4 | 39.9 [37.9..42.0] 10% | 135.2 [112.6..143.4] 23% | 770.0 [385.0..966.7] 76% | 39.53 [37.20..43.70] 16% | 54k [47k..59k] 21% | 0.40 [0.39..0.40] 2% | 1.73→1.83 | 3 | **NOISY** |
| pred | cap 20000 | 10 | 5 | 4 | 15.1 [14.6..15.6] 7% | 108.5 [92.2..120.8] 26% | 540.7 [184.3..704.5] 96% | 29.10 [28.08..30.10] 7% | 116k [112k..123k] 10% | 0.54 [0.53..0.59] 11% | 2.07→2.07 | 3 | **NOISY** |
| pred | cap 5000 | 10 | 20 | 4 | 39.9 [37.9..39.9] 5% | 108.5 [104.4..385.0] 258% | 573.4 [225.3..3735.6] 612% | 42.17 [40.10..44.05] 9% | 44k [36k..46k] 21% | 0.35 [0.30..0.36] 17% | 4.03→3.71 | 3 | **NOISY** |
| pred | cap 20000 | 10 | 20 | 4 | 22.0 [17.9..25.1] 33% | 124.9 [100.4..159.7] 48% | 835.6 [352.3..1212.4] 103% | 45.59 [44.22..47.50] 7% | 58k [54k..66k] 22% | 0.53 [0.49..0.57] 16% | 3.89→3.89 | 3 | **NOISY** |
| pred | cap 5000 | 10 | 100 | 4 | 46.1 [44.0..46.1] 4% | 151.6 [135.2..208.9] 49% | 1474.6 [639.0..3211.3] 174% | 52.21 [51.07..52.92] 4% | 22k [21k..23k] 6% | 0.23 [0.23..0.24] 6% | 3.54→3.34 | 3 | **NOISY** |
| pred | cap 20000 | 10 | 100 | 4 | 44.0 [44.0..48.1] 9% | 135.2 [129.0..352.3] 165% | 671.7 [401.4..1933.3] 228% | 55.02 [53.35..56.87] 6% | 22k [22k..23k] 6% | 0.25 [0.24..0.26] 6% | 3.74→3.60 | 3 | **NOISY** |
| go | cap 5000 | 0.1 | 0 | 4 | 1.1 [1.1..1.1] 6% | 4.7 [2.8..22.0] 407% | 52.2 [28.2..75.8] 91% | 1.31 [1.20..1.54] 26% | 2744k [2138k..3228k] 40% | 0.83 [0.77..0.89] 14% | 2.16→2.16 | 3 | **NOISY** |
| go | cap 20000 | 0.1 | 0 | 4 | 1.1 [1.0..1.1] 14% | 3.4 [2.6..4.5] 55% | 22.0 [15.6..46.1] 138% | 1.29 [1.14..1.35] 17% | 2994k [2752k..3392k] 21% | 0.87 [0.82..0.91] 10% | 3.76→3.78 | 3 | **NOISY** |
| go | cap 5000 | 0.1 | 1 | 4 | 1.3 [1.3..1.4] 5% | 64.5 [60.4..75.8] 24% | 159.7 [104.4..368.6] 165% | 8.74 [8.38..9.45] 12% | 280k [234k..296k] 22% | 0.61 [0.55..0.61] 11% | 3.04→3.04 | 3 | **NOISY** |
| go | cap 20000 | 0.1 | 1 | 4 | 1.1 [1.1..1.2] 11% | 56.3 [50.2..58.4] 14% | 151.6 [92.2..192.5] 66% | 8.11 [7.92..8.49] 7% | 398k [337k..441k] 26% | 0.81 [0.71..0.86] 19% | 2.21→2.36 | 3 | **NOISY** |
| go | cap 5000 | 0.1 | 5 | 4 | 14.1 [11.0..14.6] 26% | 75.8 [64.5..88.1] 31% | 368.6 [192.5..802.8] 166% | 23.30 [21.41..23.69] 10% | 109k [104k..124k] 18% | 0.64 [0.61..0.66] 7% | 4.13→4.12 | 3 | **NOISY** |
| go | cap 20000 | 0.1 | 5 | 4 | 1.4 [1.3..1.5] 13% | 62.5 [60.4..64.5] 7% | 225.3 [159.7..450.6] 129% | 18.24 [17.73..18.58] 5% | 178k [171k..184k] 7% | 0.81 [0.79..0.82] 4% | 4.59→4.54 | 2 | ok |
| go | cap 5000 | 0.1 | 20 | 4 | 22.0 [22.0..23.0] 5% | 84.0 [71.7..92.2] 24% | 516.1 [208.9..1212.4] 194% | 32.87 [31.78..33.21] 4% | 63k [61k..65k] 6% | 0.51 [0.50..0.52] 4% | 2.22→2.12 | 3 | **NOISY** |
| go | cap 20000 | 0.1 | 20 | 4 | 7.0 [6.8..7.3] 7% | 71.7 [67.6..75.8] 11% | 319.5 [159.7..802.8] 201% | 31.93 [31.28..32.84] 5% | 82k [79k..86k] 8% | 0.66 [0.63..0.67] 7% | 3.39→3.39 | 3 | **NOISY** |
| go | cap 5000 | 0.1 | 100 | 4 | 32.3 [32.3..33.8] 5% | 112.6 [88.1..120.8] 29% | 671.7 [270.3..1146.9] 130% | 47.10 [45.21..48.74] 8% | 26k [25k..27k] 6% | 0.30 [0.30..0.31] 4% | 3.92→3.76 | 3 | **NOISY** |
| go | cap 20000 | 0.1 | 100 | 4 | 22.0 [21.0..23.0] 9% | 96.3 [75.8..108.5] 34% | 639.0 [200.7..1540.1] 210% | 53.10 [51.42..54.27] 5% | 28k [27k..29k] 7% | 0.37 [0.36..0.37] 5% | 2.89→2.74 | 3 | **NOISY** |
| go | cap 5000 | 1 | 0 | 4 | 2.5 [2.4..2.5] 5% | 32.3 [25.1..39.9] 46% | 88.1 [71.7..112.6] 46% | 3.26 [3.10..3.46] 11% | 1056k [924k..1135k] 20% | 0.60 [0.57..0.61] 6% | 2.08→2.08 | 3 | **NOISY** |
| go | cap 20000 | 1 | 0 | 4 | 2.4 [2.2..2.4] 5% | 12.5 [11.0..12.5] 12% | 71.7 [44.0..79.9] 50% | 3.08 [2.92..3.13] 7% | 1213k [1183k..1327k] 12% | 0.63 [0.61..0.64] 6% | 2.13→2.28 | 3 | **NOISY** |
| go | cap 5000 | 1 | 1 | 4 | 2.4 [2.2..2.4] 5% | 60.4 [58.4..67.6] 15% | 167.9 [129.0..270.3] 84% | 8.49 [8.26..8.87] 7% | 305k [273k..327k] 18% | 0.58 [0.54..0.59] 10% | 3.55→3.58 | 3 | **NOISY** |
| go | cap 20000 | 1 | 1 | 4 | 2.1 [2.0..2.1] 8% | 50.2 [46.1..54.3] 16% | 143.4 [88.1..417.8] 230% | 7.31 [7.09..7.42] 5% | 486k [394k..510k] 24% | 0.75 [0.63..0.78] 20% | 2.15→2.30 | 3 | **NOISY** |
| go | cap 5000 | 1 | 5 | 4 | 20.0 [16.9..20.0] 15% | 79.9 [67.6..92.2] 31% | 450.6 [176.1..802.8] 139% | 23.68 [22.56..24.62] 9% | 107k [99k..113k] 13% | 0.61 [0.59..0.62] 6% | 3.70→3.70 | 3 | **NOISY** |
| go | cap 20000 | 1 | 5 | 4 | 2.2 [2.2..2.4] 6% | 62.5 [60.4..64.5] 7% | 233.5 [192.5..385.0] 82% | 18.39 [18.04..19.03] 5% | 180k [170k..185k] 8% | 0.78 [0.76..0.79] 4% | 3.28→3.28 | 2 | ok |
| go | cap 5000 | 1 | 20 | 4 | 26.1 [24.1..26.1] 8% | 92.2 [84.0..159.7] 82% | 606.2 [434.2..2293.8] 307% | 35.20 [33.70..36.03] 7% | 59k [53k..62k] 15% | 0.50 [0.45..0.51] 12% | 5.67→5.46 | 3 | **NOISY** |
| go | cap 20000 | 1 | 20 | 4 | 7.6 [7.6..8.4] 12% | 79.9 [71.7..124.9] 67% | 802.8 [286.7..999.4] 89% | 33.11 [32.49..34.46] 6% | 77k [62k..83k] 27% | 0.63 [0.52..0.65] 21% | 2.81→2.83 | 3 | **NOISY** |
| go | cap 5000 | 1 | 100 | 4 | 33.8 [33.8..35.8] 6% | 129.0 [96.3..184.3] 68% | 1540.1 [1081.3..2555.9] 96% | 48.38 [47.53..52.35] 10% | 25k [23k..25k] 9% | 0.29 [0.29..0.30] 4% | 3.90→3.82 | 3 | **NOISY** |
| go | cap 20000 | 1 | 100 | 4 | 23.0 [22.0..24.1] 9% | 88.1 [75.8..286.7] 240% | 704.5 [208.9..1081.3] 124% | 54.20 [52.87..55.66] 5% | 27k [27k..28k] 5% | 0.37 [0.36..0.38] 3% | 2.59→2.59 | 3 | **NOISY** |
| go | cap 5000 | 10 | 0 | 4 | 37.9 [35.8..39.9] 11% | 124.9 [120.8..135.2] 12% | 417.8 [233.5..704.5] 113% | 24.92 [24.06..25.92] 7% | 90k [86k..93k] 8% | 0.34 [0.33..0.34] 4% | 4.53→4.32 | 3 | **NOISY** |
| go | cap 20000 | 10 | 0 | 4 | 17.9 [16.9..18.9] 11% | 116.7 [112.6..120.8] 7% | 319.5 [241.7..483.3] 76% | 21.54 [21.10..22.41] 6% | 163k [157k..172k] 9% | 0.48 [0.45..0.49] 9% | 2.56→2.56 | 2 | ok |
| go | cap 5000 | 10 | 1 | 4 | 39.9 [37.9..39.9] 5% | 135.2 [124.9..233.5] 80% | 516.1 [335.9..966.7] 122% | 27.45 [26.68..27.92] 4% | 82k [77k..86k] 11% | 0.36 [0.34..0.36] 7% | 3.54→3.42 | 3 | **NOISY** |
| go | cap 20000 | 10 | 1 | 4 | 14.6 [13.6..14.6] 7% | 104.4 [88.1..124.9] 35% | 540.7 [167.9..2293.8] 393% | 23.75 [22.06..24.05] 8% | 144k [133k..169k] 25% | 0.51 [0.44..0.52] 15% | 2.81→2.81 | 3 | **NOISY** |
| go | cap 5000 | 10 | 5 | 4 | 37.9 [35.8..39.9] 11% | 143.4 [108.5..516.1] 284% | 835.6 [217.1..1409.0] 143% | 37.55 [35.19..40.70] 15% | 62k [53k..70k] 28% | 0.43 [0.41..0.44] 8% | 2.54→2.66 | 3 | **NOISY** |
| go | cap 20000 | 10 | 5 | 4 | 14.6 [14.1..15.1] 7% | 104.4 [84.0..116.7] 31% | 385.0 [192.5..671.7] 125% | 29.43 [28.59..31.17] 9% | 117k [112k..128k] 14% | 0.58 [0.55..0.59] 8% | 3.89→3.90 | 3 | **NOISY** |
| go | cap 5000 | 10 | 20 | 4 | 42.0 [39.9..44.0] 10% | 135.2 [129.0..143.4] 11% | 606.2 [368.6..1343.5] 161% | 49.72 [47.77..51.65] 8% | 43k [40k..44k] 8% | 0.42 [0.41..0.43] 5% | 2.50→2.54 | 3 | **NOISY** |
| go | cap 20000 | 10 | 20 | 4 | 16.9 [16.9..17.9] 6% | 112.6 [104.4..151.6] 42% | 704.5 [335.9..1671.2] 190% | 46.14 [45.90..48.06] 5% | 63k [58k..65k] 11% | 0.57 [0.55..0.58] 6% | 2.42→2.54 | 3 | **NOISY** |
| go | cap 5000 | 10 | 100 | 4 | 42.0 [42.0..42.0] 0% | 120.8 [108.5..143.4] 29% | 737.3 [466.9..1474.6] 137% | 55.12 [54.62..56.59] 4% | 24k [23k..24k] 3% | 0.27 [0.26..0.28] 4% | 2.23→2.21 | 3 | **NOISY** |
| go | cap 20000 | 10 | 100 | 4 | 37.9 [35.8..37.9] 5% | 143.4 [112.6..249.9] 96% | 1146.9 [540.7..1998.8] 127% | 66.25 [65.64..67.47] 3% | 25k [24k..26k] 9% | 0.36 [0.34..0.36] 7% | 3.64→3.51 | 3 | **NOISY** |
| fixed | 0/0 | 1 | 0 | 4 | 26.1 [26.1..27.1] 4% | 71.7 [67.6..96.3] 40% | 225.3 [135.2..671.7] 238% | 12.28 [11.89..12.89] 8% | 135k [121k..139k] 14% | 0.38 [0.36..0.39] 9% | 2.72→2.66 | 3 | **NOISY** |
| fixed | 0/100 | 1 | 0 | 4 | 27.1 [26.1..28.2] 8% | 79.9 [71.7..96.3] 31% | 450.6 [176.1..1032.2] 190% | 12.69 [12.22..13.01] 6% | 128k [121k..134k] 10% | 0.37 [0.35..0.39] 8% | 2.90→2.91 | 3 | **NOISY** |
| fixed | 0/500 | 1 | 0 | 4 | 27.1 [26.1..28.2] 8% | 79.9 [71.7..120.8] 62% | 606.2 [233.5..868.4] 105% | 12.74 [12.49..13.10] 5% | 126k [120k..132k] 10% | 0.37 [0.36..0.38] 5% | 5.38→5.19 | 3 | **NOISY** |
| fixed | 0/1000 | 1 | 0 | 4 | 28.2 [27.1..29.2] 7% | 79.9 [71.7..88.1] 20% | 499.7 [176.1..966.7] 158% | 12.94 [12.40..13.65] 10% | 125k [115k..135k] 16% | 0.37 [0.36..0.39] 7% | 2.08→2.16 | 3 | **NOISY** |
| fixed | 0/2000 | 1 | 0 | 4 | 28.2 [26.1..29.2] 11% | 79.9 [75.8..92.2] 20% | 466.9 [258.0..704.5] 96% | 13.04 [12.41..13.98] 12% | 124k [117k..125k] 7% | 0.38 [0.35..0.39] 8% | 2.37→2.37 | 3 | **NOISY** |
| fixed | 0/5000 | 1 | 0 | 4 | 26.1 [25.1..28.2] 12% | 75.8 [64.5..84.0] 26% | 466.9 [159.7..966.7] 173% | 12.38 [11.76..13.27] 12% | 131k [120k..142k] 17% | 0.37 [0.37..0.38] 5% | 2.14→2.13 | 3 | **NOISY** |
| fixed | 0/10000 | 1 | 0 | 4 | 28.2 [27.1..30.2] 11% | 84.0 [75.8..88.1] 15% | 385.0 [241.7..671.7] 112% | 13.43 [12.82..14.20] 10% | 120k [119k..128k] 8% | 0.38 [0.37..0.39] 6% | 1.76→1.76 | 3 | **NOISY** |
| fixed | 0/20000 | 1 | 0 | 4 | 27.1 [27.1..28.2] 4% | 75.8 [67.6..88.1] 27% | 303.1 [167.9..434.2] 88% | 12.49 [12.31..12.99] 6% | 130k [124k..136k] 9% | 0.37 [0.37..0.38] 3% | 1.87→1.87 | 3 | **NOISY** |
| fixed | 0/50000 | 1 | 0 | 4 | 27.1 [27.1..30.2] 11% | 79.9 [71.7..96.3] 31% | 352.3 [129.0..671.7] 154% | 12.87 [12.48..14.31] 14% | 127k [114k..133k] 15% | 0.38 [0.37..0.39] 6% | 2.08→2.16 | 3 | **NOISY** |
| fixed | 100/0 | 1 | 0 | 4 | 26.1 [26.1..29.2] 12% | 75.8 [67.6..88.1] 27% | 286.7 [208.9..639.0] 150% | 12.40 [12.15..13.43] 10% | 133k [119k..136k] 12% | 0.38 [0.36..0.38] 6% | 1.74→1.68 | 3 | **NOISY** |
| fixed | 500/0 | 1 | 0 | 4 | 27.1 [26.1..29.2] 11% | 84.0 [75.8..88.1] 15% | 417.8 [352.3..573.4] 53% | 13.35 [12.86..14.08] 9% | 126k [120k..131k] 9% | 0.39 [0.39..0.39] 1% | 2.52→2.52 | 3 | **NOISY** |
| fixed | 1000/0 | 1 | 0 | 4 | 27.1 [26.1..29.2] 11% | 75.8 [75.8..88.1] 16% | 368.6 [225.3..999.4] 210% | 13.75 [12.97..14.18] 9% | 123k [121k..137k] 13% | 0.40 [0.39..0.41] 6% | 1.86→1.95 | 3 | **NOISY** |
| fixed | 2000/0 | 1 | 0 | 4 | 25.1 [25.1..26.1] 4% | 84.0 [75.8..100.4] 29% | 450.6 [368.6..1146.9] 173% | 12.14 [11.64..13.06] 12% | 151k [135k..160k] 17% | 0.43 [0.40..0.43] 9% | 3.35→3.35 | 3 | **NOISY** |
| fixed | 5000/0 | 1 | 0 | 4 | 2.4 [2.4..2.5] 5% | 35.8 [27.1..42.0] 41% | 100.4 [79.9..143.4] 63% | 3.27 [3.19..3.63] 14% | 1048k [850k..1085k] 22% | 0.59 [0.54..0.61] 13% | 1.52→1.52 | 3 | **NOISY** |
| fixed | 10000/0 | 1 | 0 | 4 | 2.4 [2.2..2.4] 5% | 13.1 [12.0..14.1] 16% | 71.7 [64.5..84.0] 27% | 3.00 [2.92..3.16] 8% | 1216k [1090k..1281k] 16% | 0.62 [0.57..0.64] 11% | 5.32→5.21 | 3 | **NOISY** |
| fixed | 20000/0 | 1 | 0 | 4 | 2.4 [2.2..2.5] 11% | 12.0 [11.0..13.6] 21% | 62.5 [33.8..84.0] 80% | 3.10 [2.87..3.19] 10% | 1238k [1116k..1311k] 16% | 0.64 [0.59..0.66] 11% | 2.51→2.47 | 3 | **NOISY** |
| fixed | 50000/0 | 1 | 0 | 4 | 2.4 [2.2..2.5] 11% | 12.0 [10.5..14.1] 30% | 42.0 [29.2..120.8] 218% | 3.13 [2.86..3.27] 13% | 1177k [1125k..1350k] 19% | 0.64 [0.63..0.66] 5% | 2.76→2.86 | 3 | **NOISY** |
| fixed | 0/0 | 1 | 1 | 4 | 27.1 [26.1..29.2] 11% | 88.1 [67.6..104.4] 42% | 417.8 [192.5..1867.8] 401% | 34.43 [33.03..36.91] 11% | 71k [62k..75k] 18% | 0.59 [0.55..0.60] 9% | 2.18→2.18 | 3 | **NOISY** |
| fixed | 0/100 | 1 | 1 | 4 | 28.2 [27.1..28.2] 4% | 88.1 [75.8..151.6] 86% | 540.7 [401.4..1278.0] 162% | 31.97 [31.15..32.77] 5% | 73k [70k..75k] 7% | 0.57 [0.55..0.58] 5% | 3.52→3.56 | 3 | **NOISY** |
| fixed | 0/500 | 1 | 1 | 4 | 28.2 [27.1..29.2] 7% | 84.0 [67.6..159.7] 110% | 802.8 [143.4..3604.5] 431% | 26.93 [25.00..27.36] 9% | 81k [68k..91k] 29% | 0.52 [0.44..0.55] 21% | 3.00→3.08 | 3 | **NOISY** |
| fixed | 0/1000 | 1 | 1 | 4 | 27.1 [26.1..28.2] 8% | 79.9 [71.7..92.2] 26% | 483.3 [303.1..1081.3] 161% | 21.07 [20.66..21.73] 5% | 96k [90k..99k] 9% | 0.48 [0.46..0.49] 7% | 2.25→2.25 | 3 | **NOISY** |
| fixed | 0/2000 | 1 | 1 | 4 | 27.1 [26.1..27.1] 4% | 75.8 [71.7..79.9] 11% | 286.7 [249.9..606.2] 124% | 16.35 [15.89..16.59] 4% | 116k [110k..119k] 7% | 0.44 [0.43..0.45] 4% | 3.02→2.94 | 3 | **NOISY** |
| fixed | 0/5000 | 1 | 1 | 4 | 27.1 [26.1..29.2] 11% | 88.1 [71.7..176.1] 119% | 417.8 [241.7..466.9] 54% | 14.79 [13.83..15.25] 10% | 118k [113k..125k] 10% | 0.40 [0.39..0.41] 4% | 1.87→1.87 | 3 | **NOISY** |
| fixed | 0/10000 | 1 | 1 | 4 | 28.2 [27.1..30.2] 11% | 84.0 [79.9..88.1] 10% | 483.3 [286.7..835.6] 114% | 14.73 [14.11..15.45] 9% | 116k [111k..120k] 8% | 0.40 [0.38..0.41] 7% | 2.60→2.64 | 3 | ok |
| fixed | 0/20000 | 1 | 1 | 4 | 28.2 [28.2..30.2] 7% | 79.9 [75.8..104.4] 36% | 319.5 [249.9..1146.9] 281% | 14.61 [14.29..15.76] 10% | 113k [111k..122k] 9% | 0.40 [0.38..0.41] 9% | 4.87→4.87 | 3 | **NOISY** |
| fixed | 0/50000 | 1 | 1 | 4 | 26.1 [26.1..28.2] 8% | 75.8 [71.7..100.4] 38% | 335.9 [249.9..999.4] 223% | 13.99 [13.56..14.79] 9% | 124k [113k..128k] 12% | 0.40 [0.39..0.40] 4% | 3.62→3.49 | 3 | **NOISY** |
| fixed | 100/0 | 1 | 1 | 4 | 27.1 [25.1..27.1] 8% | 71.7 [67.6..92.2] 34% | 319.5 [217.1..802.8] 183% | 32.52 [31.45..33.08] 5% | 75k [72k..79k] 9% | 0.60 [0.58..0.60] 4% | 3.91→3.91 | 3 | **NOISY** |
| fixed | 500/0 | 1 | 1 | 4 | 27.1 [26.1..28.2] 8% | 71.7 [67.6..79.9] 17% | 450.6 [176.1..540.7] 81% | 33.71 [33.23..35.84] 8% | 73k [69k..76k] 10% | 0.60 [0.59..0.62] 4% | 3.04→2.96 | 3 | **NOISY** |
| fixed | 1000/0 | 1 | 1 | 4 | 26.1 [25.1..27.1] 8% | 67.6 [64.5..79.9] 23% | 303.1 [200.7..966.7] 253% | 33.03 [31.66..33.74] 6% | 77k [75k..81k] 7% | 0.62 [0.61..0.62] 3% | 2.69→2.72 | 3 | **NOISY** |
| fixed | 2000/0 | 1 | 1 | 4 | 27.1 [25.1..29.2] 15% | 79.9 [67.6..286.7] 274% | 499.7 [217.1..1081.3] 173% | 34.61 [32.20..38.80] 19% | 76k [60k..82k] 29% | 0.62 [0.57..0.64] 12% | 4.85→4.70 | 3 | **NOISY** |
| fixed | 5000/0 | 1 | 1 | 4 | 21.0 [20.0..22.0] 10% | 67.6 [64.5..75.8] 17% | 352.3 [208.9..573.4] 103% | 30.49 [29.68..32.07] 8% | 96k [88k..98k] 11% | 0.71 [0.69..0.71] 3% | 3.53→3.40 | 3 | **NOISY** |
| fixed | 10000/0 | 1 | 1 | 4 | 6.5 [6.0..7.3] 20% | 67.6 [60.4..79.9] 29% | 499.7 [192.5..966.7] 155% | 28.59 [27.50..29.85] 8% | 110k [106k..120k] 13% | 0.78 [0.74..0.80] 8% | 2.68→2.79 | 3 | **NOISY** |
| fixed | 20000/0 | 1 | 1 | 4 | 4.2 [3.8..4.7] 23% | 54.3 [48.1..58.4] 19% | 217.1 [151.6..335.9] 85% | 26.63 [25.09..27.46] 9% | 139k [133k..149k] 12% | 0.89 [0.88..0.90] 3% | 3.31→3.31 | 3 | **NOISY** |
| fixed | 50000/0 | 1 | 1 | 4 | 3.4 [3.0..3.5] 15% | 39.9 [35.8..46.1] 26% | 450.6 [335.9..1146.9] 180% | 25.82 [24.70..27.01] 9% | 145k [133k..146k] 9% | 0.90 [0.85..0.93] 9% | 2.23→2.38 | 3 | **NOISY** |
| fixed | 0/0 | 1 | 5 | 4 | 28.2 [27.1..29.2] 7% | 84.0 [79.9..88.1] 10% | 540.7 [249.9..671.7] 78% | 37.15 [36.03..37.97] 5% | 62k [60k..64k] 6% | 0.56 [0.55..0.57] 2% | 2.35→2.41 | 2 | ok |
| fixed | 0/100 | 1 | 5 | 4 | 27.1 [26.1..28.2] 8% | 79.9 [71.7..84.0] 15% | 499.7 [192.5..671.7] 96% | 33.96 [32.59..36.01] 10% | 67k [63k..70k] 11% | 0.55 [0.54..0.56] 5% | 2.55→2.55 | 3 | **NOISY** |
| fixed | 0/500 | 1 | 5 | 4 | 27.1 [26.1..28.2] 8% | 88.1 [71.7..108.5] 42% | 385.0 [303.1..1146.9] 219% | 33.98 [31.81..34.95] 9% | 65k [63k..70k] 11% | 0.54 [0.53..0.56] 5% | 6.19→5.78 | 3 | **NOISY** |
| fixed | 0/1000 | 1 | 5 | 4 | 26.1 [25.1..27.1] 8% | 79.9 [71.7..96.3] 31% | 319.5 [200.7..868.4] 209% | 30.94 [29.66..32.84] 10% | 71k [69k..74k] 8% | 0.54 [0.52..0.55] 5% | 2.61→2.61 | 3 | **NOISY** |
| fixed | 0/2000 | 1 | 5 | 4 | 27.1 [26.1..30.2] 15% | 84.0 [71.7..100.4] 34% | 540.7 [335.9..802.8] 86% | 29.07 [27.54..31.77] 15% | 75k [70k..78k] 12% | 0.53 [0.52..0.54] 4% | 4.59→4.46 | 3 | **NOISY** |
| fixed | 0/5000 | 1 | 5 | 4 | 27.1 [26.1..28.2] 8% | 84.0 [75.8..92.2] 20% | 352.3 [241.7..770.0] 150% | 24.53 [23.12..25.31] 9% | 84k [82k..93k] 12% | 0.51 [0.49..0.51] 5% | 3.55→3.51 | 3 | **NOISY** |
| fixed | 0/10000 | 1 | 5 | 4 | 25.1 [25.1..25.1] 0% | 84.0 [75.8..92.2] 20% | 606.2 [385.0..1933.3] 255% | 19.47 [18.97..19.55] 3% | 102k [95k..104k] 10% | 0.47 [0.43..0.48] 11% | 2.35→2.48 | 3 | **NOISY** |
| fixed | 0/20000 | 1 | 5 | 4 | 27.1 [26.1..28.2] 8% | 84.0 [75.8..96.3] 24% | 573.4 [450.6..2293.8] 321% | 18.86 [18.04..19.45] 8% | 104k [93k..111k] 18% | 0.46 [0.42..0.47] 10% | 2.94→2.86 | 3 | **NOISY** |
| fixed | 0/50000 | 1 | 5 | 4 | 25.1 [24.1..26.1] 8% | 71.7 [67.6..84.0] 23% | 540.7 [200.7..704.5] 93% | 17.22 [17.13..17.90] 4% | 114k [107k..120k] 12% | 0.46 [0.45..0.48] 7% | 6.08→5.91 | 3 | **NOISY** |
| fixed | 100/0 | 1 | 5 | 4 | 27.1 [26.1..28.2] 8% | 88.1 [71.7..96.3] 28% | 835.6 [120.8..1671.2] 186% | 35.60 [33.76..38.52] 13% | 62k [59k..69k] 17% | 0.55 [0.53..0.57] 6% | 2.18→2.18 | 3 | **NOISY** |
| fixed | 500/0 | 1 | 5 | 4 | 29.2 [27.1..31.2] 14% | 104.4 [88.1..270.3] 174% | 434.2 [319.5..3211.3] 666% | 38.91 [36.55..41.53] 13% | 60k [53k..62k] 16% | 0.56 [0.47..0.59] 21% | 5.27→5.08 | 3 | **NOISY** |
| fixed | 1000/0 | 1 | 5 | 4 | 27.1 [27.1..28.2] 4% | 88.1 [79.9..108.5] 33% | 516.1 [200.7..835.6] 123% | 36.80 [35.68..37.67] 5% | 64k [62k..65k] 4% | 0.57 [0.56..0.58] 5% | 2.69→2.69 | 3 | **NOISY** |
| fixed | 2000/0 | 1 | 5 | 4 | 26.1 [25.1..27.1] 8% | 79.9 [71.7..88.1] 20% | 417.8 [319.5..999.4] 163% | 34.92 [33.58..36.16] 7% | 70k [66k..72k] 9% | 0.59 [0.58..0.59] 3% | 2.12→2.12 | 3 | **NOISY** |
| fixed | 5000/0 | 1 | 5 | 4 | 25.1 [24.1..26.1] 8% | 104.4 [84.0..120.8] 35% | 737.3 [368.6..868.4] 68% | 38.97 [37.08..39.86] 7% | 67k [65k..69k] 6% | 0.63 [0.62..0.65] 4% | 2.45→2.57 | 3 | **NOISY** |
| fixed | 10000/0 | 1 | 5 | 4 | 7.6 [7.0..7.8] 10% | 67.6 [60.4..96.3] 53% | 200.7 [124.9..2949.1] 1407% | 33.05 [30.30..34.45] 12% | 90k [73k..99k] 29% | 0.73 [0.58..0.74] 21% | 5.22→5.22 | 3 | **NOISY** |
| fixed | 20000/0 | 1 | 5 | 4 | 6.8 [6.3..7.6] 19% | 71.7 [67.6..75.8] 11% | 385.0 [225.3..639.0] 107% | 33.75 [31.80..36.35] 14% | 94k [89k..100k] 12% | 0.77 [0.77..0.79] 3% | 2.27→2.25 | 3 | **NOISY** |
| fixed | 50000/0 | 1 | 5 | 4 | 5.5 [4.7..5.5] 14% | 54.3 [50.2..62.5] 23% | 417.8 [286.7..1409.0] 269% | 31.98 [31.24..33.02] 6% | 104k [98k..111k] 13% | 0.81 [0.78..0.84] 7% | 3.66→3.60 | 3 | **NOISY** |
| fixed | 0/0 | 1 | 20 | 4 | 27.1 [27.1..28.2] 4% | 79.9 [75.8..104.4] 36% | 516.1 [241.7..1081.3] 163% | 33.42 [33.01..35.86] 8% | 54k [51k..55k] 8% | 0.44 [0.42..0.44] 5% | 3.38→3.38 | 3 | **NOISY** |
| fixed | 0/100 | 1 | 20 | 4 | 28.2 [27.1..29.2] 7% | 88.1 [79.9..104.4] 28% | 737.3 [606.2..2064.4] 198% | 34.35 [33.04..35.52] 7% | 52k [49k..54k] 9% | 0.44 [0.41..0.44] 7% | 3.01→3.01 | 3 | **NOISY** |
| fixed | 0/500 | 1 | 20 | 4 | 29.2 [26.1..31.2] 18% | 104.4 [75.8..208.9] 127% | 606.2 [225.3..966.7] 122% | 35.63 [32.16..37.44] 15% | 51k [48k..56k] 15% | 0.44 [0.42..0.45] 8% | 2.21→2.21 | 3 | **NOISY** |
| fixed | 0/1000 | 1 | 20 | 4 | 28.2 [27.1..29.2] 7% | 96.3 [75.8..135.2] 62% | 639.0 [270.3..1671.2] 219% | 35.28 [33.66..36.23] 7% | 51k [49k..55k] 13% | 0.44 [0.43..0.45] 6% | 2.56→2.44 | 3 | **NOISY** |
| fixed | 0/2000 | 1 | 20 | 4 | 29.2 [28.2..29.2] 4% | 104.4 [88.1..200.7] 108% | 868.4 [192.5..1933.3] 200% | 35.83 [34.92..37.49] 7% | 51k [48k..53k] 11% | 0.45 [0.42..0.46] 11% | 2.99→2.91 | 3 | **NOISY** |
| fixed | 0/5000 | 1 | 20 | 4 | 27.1 [26.1..28.2] 8% | 84.0 [75.8..104.4] 34% | 417.8 [200.7..1605.6] 336% | 34.97 [33.04..35.10] 6% | 57k [53k..60k] 12% | 0.47 [0.46..0.48] 6% | 2.42→2.42 | 3 | **NOISY** |
| fixed | 0/10000 | 1 | 20 | 4 | 26.1 [25.1..27.1] 8% | 96.3 [79.9..401.4] 334% | 1032.2 [270.3..4849.7] 444% | 33.95 [32.66..34.51] 5% | 61k [46k..64k] 31% | 0.49 [0.37..0.51] 28% | 2.90→2.90 | 3 | **NOISY** |
| fixed | 0/20000 | 1 | 20 | 4 | 25.1 [23.0..26.1] 12% | 96.3 [79.9..176.1] 100% | 737.3 [303.1..1146.9] 114% | 32.65 [31.67..33.68] 6% | 68k [63k..73k] 15% | 0.54 [0.51..0.56] 9% | 3.67→3.67 | 3 | **NOISY** |
| fixed | 0/50000 | 1 | 20 | 4 | 22.0 [20.0..22.0] 9% | 71.7 [60.4..71.7] 16% | 303.1 [241.7..1081.3] 277% | 30.30 [29.54..30.66] 4% | 83k [82k..88k] 7% | 0.61 [0.60..0.63] 5% | 4.77→4.71 | 3 | **NOISY** |
| fixed | 100/0 | 1 | 20 | 4 | 28.2 [27.1..29.2] 7% | 92.2 [79.9..116.7] 40% | 639.0 [417.8..1032.2] 96% | 34.34 [32.80..35.72] 8% | 52k [49k..55k] 10% | 0.43 [0.43..0.45] 4% | 4.02→3.94 | 3 | **NOISY** |
| fixed | 500/0 | 1 | 20 | 4 | 28.2 [27.1..29.2] 7% | 84.0 [79.9..112.6] 39% | 573.4 [159.7..1474.6] 229% | 34.38 [33.20..36.12] 8% | 53k [49k..54k] 9% | 0.44 [0.43..0.45] 6% | 5.48→5.20 | 3 | **NOISY** |
| fixed | 1000/0 | 1 | 20 | 4 | 29.2 [28.2..30.2] 7% | 84.0 [79.9..108.5] 34% | 540.7 [176.1..2293.8] 392% | 36.24 [35.65..38.68] 8% | 51k [45k..53k] 15% | 0.46 [0.43..0.47] 9% | 1.88→1.89 | 3 | **NOISY** |
| fixed | 2000/0 | 1 | 20 | 4 | 28.2 [27.1..30.2] 11% | 92.2 [79.9..100.4] 22% | 770.0 [401.4..1146.9] 97% | 37.77 [35.14..39.93] 13% | 50k [46k..55k] 17% | 0.47 [0.44..0.47] 7% | 3.46→3.46 | 3 | **NOISY** |
| fixed | 5000/0 | 1 | 20 | 4 | 25.1 [24.1..27.1] 12% | 79.9 [75.8..92.2] 20% | 401.4 [176.1..704.5] 132% | 36.14 [34.05..38.57] 12% | 57k [54k..59k] 10% | 0.50 [0.49..0.51] 4% | 6.49→6.13 | 3 | **NOISY** |
| fixed | 10000/0 | 1 | 20 | 4 | 12.5 [11.0..13.6] 20% | 84.0 [75.8..100.4] 29% | 499.7 [270.3..966.7] 139% | 36.40 [34.37..37.01] 7% | 60k [59k..64k] 8% | 0.54 [0.52..0.54] 3% | 3.97→3.81 | 3 | **NOISY** |
| fixed | 20000/0 | 1 | 20 | 4 | 11.5 [11.0..12.0] 9% | 88.1 [75.8..92.2] 19% | 516.1 [368.6..1032.2] 129% | 38.88 [37.04..40.78] 10% | 62k [60k..64k] 7% | 0.59 [0.56..0.59] 5% | 2.17→2.17 | 3 | **NOISY** |
| fixed | 50000/0 | 1 | 20 | 4 | 10.0 [10.0..10.5] 5% | 62.5 [56.3..67.6] 18% | 319.5 [233.5..540.7] 96% | 36.35 [36.00..37.29] 4% | 71k [70k..72k] 3% | 0.63 [0.62..0.64] 2% | 4.18→4.18 | 3 | **NOISY** |
| fixed | 0/0 | 1 | 100 | 4 | 33.8 [33.8..35.8] 6% | 104.4 [84.0..143.4] 57% | 737.3 [233.5..2064.4] 248% | 43.63 [42.23..45.64] 8% | 25k [24k..26k] 7% | 0.26 [0.25..0.27] 9% | 3.86→3.86 | 3 | **NOISY** |
| fixed | 0/100 | 1 | 100 | 4 | 33.8 [33.8..35.8] 6% | 104.4 [96.3..401.4] 292% | 606.2 [286.7..2424.8] 353% | 43.06 [42.18..44.53] 5% | 25k [22k..26k] 12% | 0.26 [0.24..0.27] 8% | 3.52→3.32 | 3 | **NOISY** |
| fixed | 0/500 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 96.3 [88.1..868.4] 811% | 1081.3 [450.6..2555.9] 195% | 42.24 [41.28..45.59] 10% | 25k [22k..26k] 15% | 0.26 [0.25..0.26] 7% | 2.27→2.25 | 3 | **NOISY** |
| fixed | 0/1000 | 1 | 100 | 4 | 35.8 [33.8..37.9] 11% | 104.4 [84.0..135.2] 49% | 639.0 [208.9..1212.4] 157% | 44.94 [42.39..48.10] 13% | 25k [24k..26k] 9% | 0.27 [0.27..0.28] 6% | 1.82→1.82 | 3 | **NOISY** |
| fixed | 0/2000 | 1 | 100 | 4 | 35.8 [33.8..37.9] 11% | 143.4 [112.6..499.7] 270% | 737.3 [368.6..1867.8] 203% | 49.64 [45.50..53.00] 15% | 24k [22k..25k] 15% | 0.28 [0.28..0.30] 6% | 1.64→1.59 | 3 | **NOISY** |
| fixed | 0/5000 | 1 | 100 | 4 | 32.3 [32.3..35.8] 11% | 100.4 [88.1..129.0] 41% | 802.8 [286.7..1933.3] 205% | 46.46 [45.78..49.96] 9% | 26k [25k..26k] 7% | 0.30 [0.28..0.30] 6% | 3.82→3.52 | 3 | **NOISY** |
| fixed | 0/10000 | 1 | 100 | 4 | 32.3 [31.2..33.8] 8% | 100.4 [84.0..135.2] 51% | 802.8 [319.5..1802.2] 185% | 51.62 [49.90..54.49] 9% | 26k [23k..27k] 14% | 0.33 [0.31..0.34] 7% | 2.36→2.33 | 3 | **NOISY** |
| fixed | 0/20000 | 1 | 100 | 4 | 31.2 [29.2..32.3] 10% | 96.3 [75.8..120.8] 47% | 704.5 [192.5..1736.7] 219% | 61.15 [59.07..62.79] 6% | 27k [26k..27k] 6% | 0.40 [0.39..0.40] 3% | 2.93→2.77 | 3 | **NOISY** |
| fixed | 0/50000 | 1 | 100 | 4 | 23.0 [22.0..24.1] 9% | 104.4 [79.9..143.4] 61% | 1146.9 [368.6..2064.4] 148% | 80.14 [78.42..80.71] 3% | 28k [26k..29k] 11% | 0.55 [0.52..0.57] 9% | 1.94→1.94 | 3 | **NOISY** |
| fixed | 100/0 | 1 | 100 | 4 | 35.8 [33.8..35.8] 6% | 112.6 [104.4..176.1] 64% | 737.3 [450.6..2555.9] 286% | 44.32 [42.43..45.34] 7% | 24k [23k..25k] 10% | 0.26 [0.25..0.27] 7% | 2.84→2.62 | 3 | **NOISY** |
| fixed | 500/0 | 1 | 100 | 4 | 33.8 [33.8..35.8] 6% | 104.4 [84.0..159.7] 72% | 999.4 [208.9..2162.7] 196% | 44.16 [42.38..45.57] 7% | 25k [24k..26k] 9% | 0.27 [0.26..0.27] 5% | 1.88→1.81 | 3 | **NOISY** |
| fixed | 1000/0 | 1 | 100 | 4 | 35.8 [33.8..35.8] 6% | 135.2 [116.7..167.9] 38% | 1540.1 [368.6..2949.1] 168% | 45.92 [43.30..49.86] 14% | 24k [22k..25k] 12% | 0.27 [0.24..0.27] 13% | 2.82→2.82 | 3 | **NOISY** |
| fixed | 2000/0 | 1 | 100 | 4 | 33.8 [31.2..33.8] 8% | 100.4 [84.0..151.6] 67% | 516.1 [270.3..3473.4] 621% | 43.81 [41.04..45.16] 9% | 25k [22k..27k] 17% | 0.27 [0.24..0.28] 14% | 3.45→3.25 | 3 | **NOISY** |
| fixed | 5000/0 | 1 | 100 | 4 | 35.8 [33.8..35.8] 6% | 116.7 [96.3..135.2] 33% | 933.9 [450.6..1343.5] 96% | 47.48 [46.06..48.52] 5% | 25k [25k..26k] 4% | 0.29 [0.28..0.30] 5% | 2.24→2.24 | 3 | **NOISY** |
| fixed | 10000/0 | 1 | 100 | 4 | 33.8 [32.3..35.8] 11% | 100.4 [79.9..159.7] 80% | 1933.3 [516.1..2424.8] 99% | 48.45 [46.54..52.25] 12% | 26k [24k..26k] 8% | 0.31 [0.28..0.31] 9% | 2.10→2.09 | 3 | **NOISY** |
| fixed | 20000/0 | 1 | 100 | 4 | 21.0 [21.0..22.0] 5% | 135.2 [104.4..159.7] 41% | 1409.0 [540.7..2424.8] 134% | 47.92 [46.44..50.03] 8% | 27k [24k..28k] 14% | 0.31 [0.28..0.32] 12% | 1.71→1.57 | 3 | **NOISY** |
| fixed | 50000/0 | 1 | 100 | 4 | 21.0 [21.0..22.0] 5% | 96.3 [75.8..151.6] 79% | 516.1 [417.8..1278.0] 167% | 47.29 [46.24..50.37] 9% | 28k [27k..29k] 8% | 0.33 [0.32..0.34] 4% | 4.15→3.90 | 3 | **NOISY** |

### Main sweep, workers = 2 and 8 (partial), stamp 20261030-063521

Workers 8 is unpinned and oversubscribed (8 threads on 4 vCPUs): these rows describe this machine, not the runtime.

| policy | reply/idle spin | svc µs | gap µs | W | hop p50 µs | hop p99 µs | hop p99.9 µs | CPU µs/hop | hops/s | waste | load1 start→end | try | status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fixed | 20000 | 0.1 | 0 | 2 | 0.8 [0.7..0.9] 28% | 1.3 [1.2..1.7] 39% | 14.6 [13.1..26.1] 90% | 0.93 [0.82..1.03] 22% | 2112k [1885k..2370k] 23% | 0.87 [0.85..0.88] 4% | 5.91→5.91 | 3 | **NOISY** |
| fixed | 50000 | 0.1 | 1 | 2 | 0.9 [0.8..1.0] 29% | 1.6 [1.2..9.5] 529% | 16.9 [13.1..27.1] 83% | 2.32 [2.05..2.60] 24% | 856k [759k..933k] 20% | 0.94 [0.88..0.95] 8% | 3.65→3.65 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 5 | 2 | 22.0 [20.0..24.1] 19% | 64.5 [64.5..79.9] 24% | 241.7 [100.4..434.2] 138% | 31.95 [31.09..34.70] 11% | 37k [33k..38k] 12% | 0.59 [0.52..0.60] 14% | 1.77→1.77 | 3 | **NOISY** |
| fixed | 2000 | 0.1 | 20 | 2 | 23.0 [20.0..23.0] 13% | 79.9 [75.8..96.3] 26% | 286.7 [192.5..2162.7] 687% | 33.46 [31.35..34.22] 9% | 29k [26k..31k] 18% | 0.49 [0.42..0.50] 15% | 3.65→3.36 | 3 | **NOISY** |
| fixed | 100 | 0.1 | 100 | 2 | 31.2 [30.2..32.3] 7% | 84.0 [75.8..96.3] 24% | 319.5 [176.1..671.7] 155% | 41.26 [39.11..42.23] 8% | 13k [13k..14k] 5% | 0.27 [0.26..0.28] 5% | 4.63→4.63 | 3 | **NOISY** |
| fixed | 500 | 0.1 | 100 | 2 | 33.8 [31.2..33.8] 8% | 116.7 [88.1..135.2] 40% | 639.0 [286.7..2687.0] 376% | 44.89 [41.59..46.77] 12% | 13k [11k..13k] 18% | 0.28 [0.24..0.29] 18% | 4.24→3.98 | 3 | **NOISY** |
| fixed | 2000 | 0.1 | 100 | 2 | 31.2 [29.2..32.3] 10% | 88.1 [75.8..100.4] 28% | 270.3 [192.5..1278.0] 401% | 45.07 [41.18..46.27] 11% | 13k [13k..14k] 6% | 0.30 [0.29..0.31] 6% | 3.78→3.56 | 3 | **NOISY** |
| fixed | 10000 | 0.1 | 100 | 2 | 30.2 [18.9..31.2] 41% | 88.1 [75.8..92.2] 19% | 352.3 [319.5..1278.0] 272% | 54.15 [52.32..59.37] 13% | 14k [13k..15k] 10% | 0.39 [0.38..0.39] 4% | 3.96→3.81 | 3 | **NOISY** |
| fixed | 500 | 1 | 0 | 2 | 26.1 [25.1..27.1] 8% | 56.3 [48.1..62.5] 26% | 192.5 [92.2..319.5] 118% | 10.45 [10.23..12.12] 18% | 88k [74k..89k] 17% | 0.41 [0.40..0.42] 5% | 2.82→2.68 | 3 | **NOISY** |
| fixed | 0 | 1 | 1 | 2 | 24.1 [23.0..25.1] 8% | 58.4 [56.3..60.4] 7% | 225.3 [124.9..516.1] 174% | 30.48 [29.72..32.01] 8% | 42k [39k..43k] 8% | 0.61 [0.61..0.62] 3% | 4.44→4.25 | 1 | ok |
| fixed | 500 | 1 | 5 | 2 | 24.1 [23.0..26.1] 13% | 67.6 [64.5..75.8] 17% | 270.3 [135.2..540.7] 150% | 31.20 [30.38..33.87] 11% | 37k [35k..38k] 10% | 0.57 [0.55..0.58] 4% | 1.68→1.63 | 3 | **NOISY** |
| fixed | 1000 | 1 | 20 | 2 | 27.1 [25.1..27.1] 8% | 88.1 [79.9..100.4] 23% | 385.0 [241.7..770.0] 137% | 36.82 [35.08..38.34] 9% | 26k [25k..27k] 10% | 0.46 [0.45..0.47] 4% | 2.02→1.94 | 3 | **NOISY** |
| fixed | inf | 10 | 0 | 2 | 10.5 [10.5..10.5] 0% | 26.1 [25.1..27.1] 8% | 92.2 [67.6..184.3] 127% | 11.20 [10.83..11.47] 6% | 178k [167k..182k] 8% | 0.11 [0.08..0.12] 44% | 5.57→5.29 | 2 | ok |
| fixed | 100 | 10 | 1 | 2 | 44.0 [42.0..46.1] 9% | 92.2 [88.1..100.4] 13% | 303.1 [135.2..1081.3] 312% | 41.05 [38.88..42.84] 10% | 29k [25k..30k] 16% | 0.44 [0.42..0.45] 8% | 4.87→4.56 | 3 | **NOISY** |
| fixed | 5000 | 10 | 1 | 2 | 44.0 [42.0..46.1] 9% | 92.2 [75.8..167.9] 100% | 319.5 [151.6..2064.4] 599% | 28.66 [27.43..31.16] 13% | 41k [37k..43k] 15% | 0.38 [0.37..0.39] 6% | 2.11→2.10 | 3 | **NOISY** |
| fixed | 20000 | 10 | 1 | 2 | 10.5 [10.5..10.5] 0% | 52.2 [46.1..56.3] 20% | 225.3 [88.1..270.3] 81% | 21.39 [20.77..22.56] 8% | 89k [81k..93k] 13% | 0.50 [0.50..0.51] 3% | 3.77→3.77 | 3 | **NOISY** |
| fixed | 5000 | 10 | 20 | 2 | 39.9 [39.9..44.0] 10% | 108.5 [92.2..499.7] 376% | 540.7 [225.3..1146.9] 170% | 47.12 [45.37..50.13] 10% | 23k [18k..25k] 29% | 0.44 [0.37..0.44] 17% | 1.70→1.56 | 3 | **NOISY** |
| fixed | 10000 | 10 | 20 | 2 | 26.1 [23.0..27.1] 16% | 92.2 [92.2..100.4] 9% | 208.9 [120.8..434.2] 150% | 44.50 [43.10..45.92] 6% | 31k [30k..32k] 8% | 0.53 [0.53..0.54] 3% | 6.13→6.13 | 1 | ok |
| fixed | inf | 10 | 20 | 2 | 10.5 [9.5..10.5] 10% | 26.1 [24.1..33.8] 37% | 71.7 [44.0..208.9] 230% | 33.58 [31.92..34.95] 9% | 59k [56k..63k] 10% | 0.70 [0.69..0.70] 3% | 3.73→3.59 | 3 | **NOISY** |
| fixed | 0 | 10 | 100 | 2 | 44.0 [42.0..48.1] 14% | 120.8 [108.5..143.4] 29% | 606.2 [176.1..1540.1] 225% | 52.38 [50.20..55.95] 11% | 12k [11k..12k] 4% | 0.24 [0.24..0.26] 11% | 2.98→2.74 | 3 | **NOISY** |
| fixed | 100 | 10 | 100 | 2 | 42.0 [42.0..44.0] 5% | 108.5 [96.3..116.7] 19% | 540.7 [192.5..1343.5] 213% | 50.45 [49.14..51.75] 5% | 12k [12k..12k] 6% | 0.24 [0.24..0.25] 3% | 3.03→2.87 | 3 | **NOISY** |
| fixed | 100 | 10 | 5 | 8 | 62.5 [60.4..62.5] 3% | 241.7 [208.9..270.3] 25% | 933.9 [606.2..2162.7] 167% | 44.69 [43.58..45.38] 4% | 70k [67k..73k] 8% | 0.30 [0.29..0.31] 5% | 4.25→4.39 | 3 | **NOISY** |
| fixed | 500 | 10 | 5 | 8 | 62.5 [60.4..64.5] 7% | 225.3 [217.1..286.7] 31% | 1278.0 [483.3..2162.7] 131% | 43.87 [42.05..45.01] 7% | 71k [67k..75k] 11% | 0.30 [0.29..0.31] 6% | 3.55→3.82 | 3 | **NOISY** |
| ema | cap 20000 | 0.1 | 20 | 2 | 0.9 [0.8..1.1] 34% | 64.5 [58.4..67.6] 14% | 100.4 [75.8..286.7] 210% | 24.94 [24.12..25.76] 7% | 58k [54k..60k] 11% | 0.71 [0.69..0.72] 4% | 2.38→2.27 | 3 | **NOISY** |
| ema | cap 20000 | 1 | 5 | 2 | 1.8 [1.7..1.8] 7% | 52.2 [50.2..54.3] 8% | 104.4 [84.0..151.6] 65% | 13.35 [13.05..13.51] 3% | 114k [110k..116k] 5% | 0.70 [0.68..0.72] 5% | 2.24→2.24 | 3 | ok |
| ema | cap 20000 | 0.1 | 100 | 8 | 26.1 [24.1..31.2] 28% | 225.3 [184.3..258.0] 33% | 802.8 [450.6..1212.4] 95% | 62.09 [59.84..64.01] 7% | 46k [43k..48k] 11% | 0.35 [0.34..0.36] 4% | 4.16→4.16 | 3 | **NOISY** |
| pred | cap 20000 | 0.1 | 0 | 2 | 0.8 [0.7..1.0] 37% | 23.0 [12.5..25.1] 54% | 39.9 [29.2..44.0] 37% | 1.02 [0.89..1.21] 32% | 1657k [1422k..1979k] 34% | 0.77 [0.75..0.80] 7% | 5.52→5.24 | 3 | **NOISY** |
| pred | cap 5000 | 1 | 1 | 2 | 1.8 [1.2..1.9] 36% | 46.1 [39.9..50.2] 22% | 75.8 [62.5..104.4] 55% | 6.70 [5.36..7.62] 34% | 231k [164k..268k] 45% | 0.59 [0.54..0.66] 20% | 3.66→3.45 | 3 | **NOISY** |
| go | cap 20000 | 0.1 | 5 | 2 | 24.1 [23.0..25.1] 8% | 71.7 [64.5..71.7] 10% | 192.5 [135.2..434.2] 155% | 21.73 [21.13..22.25] 5% | 50k [48k..51k] 7% | 0.54 [0.53..0.54] 2% | 2.80→2.65 | 1 | ok |
| go | cap 5000 | 1 | 0 | 8 | 30.2 [29.2..31.2] 7% | 135.2 [124.9..167.9] 32% | 385.0 [270.3..999.4] 189% | 14.44 [14.26..15.25] 7% | 224k [207k..237k] 14% | 0.38 [0.35..0.39] 12% | 4.16→4.47 | 3 | **NOISY** |

### Headline repeat with a 2 s window, stamp 20261030-0905-w2000

| policy | reply/idle spin | svc µs | gap µs | W | hop p50 µs | hop p99 µs | hop p99.9 µs | CPU µs/hop | hops/s | waste | load1 start→end | try | status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fixed | 0 | 1 | 0 | 4 | 27.1 [27.1..29.2] 8% | 79.9 [75.8..84.0] 10% | 286.7 [249.9..417.8] 59% | 12.87 [12.49..13.40] 7% | 127k [122k..129k] 6% | 0.38 [0.37..0.38] 4% | 2.69→2.50 | 3 | **NOISY** |
| fixed | 2000 | 1 | 0 | 4 | 25.1 [24.1..26.1] 8% | 79.9 [71.7..88.1] 20% | 303.1 [225.3..352.3] 42% | 12.23 [11.40..12.67] 10% | 154k [150k..169k] 12% | 0.44 [0.43..0.44] 3% | 2.62→2.54 | 3 | **NOISY** |
| fixed | 5000 | 1 | 0 | 4 | 2.4 [2.4..2.5] 5% | 35.8 [32.3..42.0] 27% | 92.2 [79.9..112.6] 36% | 3.31 [3.24..3.57] 10% | 1009k [894k..1076k] 18% | 0.59 [0.57..0.60] 6% | 2.63→2.78 | 3 | **NOISY** |
| fixed | 20000 | 1 | 0 | 4 | 2.4 [2.2..2.5] 11% | 13.1 [11.0..14.1] 24% | 75.8 [44.0..96.3] 69% | 3.12 [2.88..3.19] 10% | 1190k [1148k..1298k] 13% | 0.63 [0.61..0.63] 4% | 2.77→3.04 | 3 | **NOISY** |
| fixed | inf | 1 | 0 | 4 | 2.4 [2.4..2.5] 5% | 12.0 [11.5..12.5] 8% | 42.0 [37.9..46.1] 20% | 3.22 [3.13..3.28] 5% | 1220k [1201k..1260k] 5% | 0.68 [0.67..0.69] 2% | 2.54→2.86 | 1 | ok |
| fixed | 0 | 1 | 100 | 4 | 33.8 [33.8..35.8] 6% | 116.7 [100.4..129.0] 25% | 835.6 [671.7..1278.0] 72% | 43.37 [42.59..44.72] 5% | 25k [24k..25k] 4% | 0.26 [0.26..0.27] 2% | 5.01→3.90 | 3 | **NOISY** |
| fixed | 2000 | 1 | 100 | 4 | 33.8 [33.8..35.8] 6% | 124.9 [104.4..208.9] 84% | 1474.6 [999.4..3211.3] 150% | 48.62 [45.97..50.25] 9% | 24k [23k..25k] 11% | 0.29 [0.28..0.29] 5% | 2.36→2.05 | 3 | **NOISY** |
| fixed | 5000 | 1 | 100 | 4 | 33.8 [32.3..35.8] 11% | 112.6 [104.4..135.2] 27% | 1032.2 [516.1..1540.1] 99% | 52.11 [49.56..54.42] 9% | 26k [24k..26k] 8% | 0.32 [0.32..0.33] 2% | 3.33→2.89 | 3 | **NOISY** |
| fixed | 20000 | 1 | 100 | 4 | 16.9 [15.6..16.9] 8% | 92.2 [88.1..96.3] 9% | 835.6 [671.7..1032.2] 43% | 63.64 [62.31..65.01] 4% | 29k [29k..30k] 2% | 0.46 [0.45..0.46] 2% | 1.82→2.07 | 1 | ok |
| fixed | inf | 1 | 100 | 4 | 1.8 [1.8..1.8] 4% | 20.0 [18.9..31.2] 62% | 1212.4 [639.0..1736.7] 90% | 106.58 [105.13..107.52] 2% | 37k [36k..38k] 3% | 0.97 [0.97..0.98] 1% | 3.10→3.24 | 3 | **NOISY** |
| ema | cap 20000 | 1 | 0 | 4 | 2.8 [2.6..2.9] 9% | 60.4 [58.4..62.5] 7% | 135.2 [112.6..192.5] 59% | 5.64 [5.40..5.70] 5% | 445k [432k..461k] 6% | 0.51 [0.50..0.52] 3% | 2.69→2.69 | 1 | ok |
| ema | cap 20000 | 1 | 100 | 4 | 16.9 [16.1..16.9] 4% | 88.1 [75.8..108.5] 37% | 737.3 [540.7..1540.1] 136% | 63.32 [62.33..64.31] 3% | 29k [28k..30k] 5% | 0.46 [0.45..0.46] 2% | 2.15→2.04 | 3 | **NOISY** |
| pred | cap 20000 | 1 | 0 | 4 | 2.5 [2.5..2.6] 5% | 50.2 [48.1..52.2] 8% | 100.4 [92.2..129.0] 37% | 4.41 [4.20..4.56] 8% | 654k [622k..696k] 11% | 0.56 [0.53..0.56] 4% | 3.38→3.31 | 2 | ok |
| pred | cap 20000 | 1 | 100 | 4 | 21.0 [21.0..22.0] 5% | 96.3 [88.1..100.4] 13% | 802.8 [335.9..1540.1] 150% | 46.90 [46.47..48.06] 3% | 27k [26k..28k] 5% | 0.31 [0.30..0.32] 6% | 1.68→1.66 | 3 | **NOISY** |
| go | cap 20000 | 1 | 0 | 4 | 2.4 [2.2..2.5] 11% | 12.0 [11.5..12.5] 8% | 62.5 [56.3..67.6] 18% | 3.06 [2.95..3.13] 6% | 1233k [1226k..1287k] 5% | 0.64 [0.62..0.65] 6% | 2.59→2.90 | 3 | ok |
| go | cap 20000 | 1 | 100 | 4 | 24.1 [24.1..25.1] 4% | 108.5 [92.2..124.9] 30% | 770.0 [516.1..966.7] 58% | 56.67 [55.13..56.88] 3% | 27k [26k..27k] 4% | 0.37 [0.37..0.37] 2% | 2.44→2.58 | 3 | **NOISY** |

### Idle burn, gate util/waste/cpu, stamp 20261030-idleburn

| policy | reply/idle spin | svc µs | gap µs | W | hop p50 µs | hop p99 µs | hop p99.9 µs | CPU µs/hop | hops/s | waste | load1 start→end | try | status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fixed | 0 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 79.9 [79.9..112.6] 41% | 483.3 [176.1..1081.3] 187% | 40.87 [39.37..41.93] 6% | 26k [25k..26k] 4% | 0.26 [0.25..0.26] 3% | 3.38→3.19 | 1 | ok |
| fixed | 100 | 1 | 100 | 4 | 33.8 [33.8..33.8] 0% | 100.4 [88.1..135.2] 47% | 802.8 [258.0..1278.0] 127% | 42.56 [41.37..43.55] 5% | 25k [25k..26k] 3% | 0.26 [0.26..0.27] 6% | 2.47→2.43 | 1 | ok |
| fixed | 500 | 1 | 100 | 4 | 33.8 [33.8..37.9] 12% | 104.4 [96.3..129.0] 31% | 352.3 [303.1..1278.0] 277% | 45.13 [43.91..48.16] 9% | 25k [24k..25k] 6% | 0.27 [0.27..0.28] 5% | 2.18→2.09 | 1 | ok |
| fixed | 1000 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 129.0 [96.3..176.1] 62% | 1146.9 [671.7..1802.2] 99% | 44.38 [42.82..45.60] 6% | 25k [24k..26k] 6% | 0.27 [0.27..0.28] 3% | 2.00→2.00 | 1 | ok |
| fixed | 2000 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 112.6 [96.3..151.6] 49% | 1343.5 [639.0..1736.7] 82% | 45.73 [44.41..46.09] 4% | 25k [24k..26k] 6% | 0.28 [0.28..0.29] 3% | 2.67→2.54 | 1 | ok |
| fixed | 5000 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 96.3 [84.0..116.7] 34% | 450.6 [143.4..1867.8] 383% | 51.05 [48.99..51.94] 6% | 26k [25k..27k] 6% | 0.33 [0.32..0.34] 6% | 2.93→2.85 | 1 | ok |
| fixed | 10000 | 1 | 100 | 4 | 32.3 [29.2..33.8] 14% | 108.5 [84.0..135.2] 47% | 901.1 [319.5..1802.2] 164% | 56.65 [54.56..58.45] 7% | 27k [26k..28k] 5% | 0.37 [0.37..0.38] 4% | 3.17→2.99 | 1 | ok |
| fixed | 20000 | 1 | 100 | 4 | 16.1 [15.6..16.1] 3% | 92.2 [79.9..184.3] 113% | 639.0 [233.5..1081.3] 133% | 63.98 [63.05..65.34] 4% | 29k [28k..30k] 6% | 0.46 [0.44..0.47] 6% | 2.52→2.40 | 1 | ok |
| fixed | 50000 | 1 | 100 | 4 | 2.1 [2.0..2.4] 20% | 88.1 [67.6..129.0] 70% | 704.5 [401.4..1933.3] 217% | 81.43 [79.63..84.72] 6% | 32k [30k..33k] 10% | 0.65 [0.63..0.65] 4% | 2.38→2.51 | 2 | ok |
| fixed | inf | 1 | 100 | 4 | 1.8 [1.7..1.8] 4% | 14.6 [7.3..84.0] 525% | 835.6 [417.8..1998.8] 189% | 105.11 [103.80..109.41] 5% | 38k [35k..38k] 7% | 0.98 [0.96..0.98] 2% | 2.24→2.38 | 1 | ok |
| ema | cap 5000 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 112.6 [92.2..124.9] 29% | 802.8 [417.8..2064.4] 205% | 51.46 [49.46..52.52] 6% | 26k [25k..27k] 8% | 0.32 [0.32..0.33] 5% | 1.88→1.88 | 2 | ok |
| ema | cap 20000 | 1 | 100 | 4 | 16.1 [16.1..16.9] 5% | 96.3 [84.0..116.7] 34% | 770.0 [286.7..1540.1] 163% | 63.66 [62.66..64.45] 3% | 29k [27k..30k] 11% | 0.46 [0.43..0.46] 8% | 2.16→2.16 | 1 | ok |
| pred | cap 5000 | 1 | 100 | 4 | 33.8 [33.8..35.8] 6% | 96.3 [88.1..135.2] 49% | 483.3 [270.3..1671.2] 290% | 42.89 [41.94..45.14] 8% | 25k [24k..26k] 6% | 0.27 [0.26..0.27] 4% | 2.16→1.98 | 1 | ok |
| pred | cap 20000 | 1 | 100 | 4 | 22.0 [21.0..23.0] 9% | 108.5 [92.2..159.7] 62% | 1032.2 [573.4..1802.2] 119% | 47.39 [45.09..48.52] 7% | 27k [26k..28k] 7% | 0.30 [0.30..0.32] 4% | 2.03→1.95 | 2 | ok |
| go | cap 5000 | 1 | 100 | 4 | 33.8 [32.3..33.8] 4% | 104.4 [92.2..192.5] 96% | 1212.4 [540.7..2293.8] 145% | 47.40 [46.22..48.04] 4% | 26k [24k..26k] 8% | 0.29 [0.28..0.30] 8% | 2.66→2.66 | 1 | ok |
| go | cap 20000 | 1 | 100 | 4 | 24.1 [24.1..26.1] 8% | 108.5 [92.2..120.8] 26% | 1278.0 [434.2..2818.1] 186% | 56.47 [55.04..58.14] 6% | 26k [25k..28k] 8% | 0.37 [0.35..0.38] 8% | 2.37→2.37 | 1 | ok |

### Oversubscription control (service 100 ns, gap 0), oversub-20261030-063521.txt

pin: auto = pin worker i to CPU i iff workers ≤ 4 (unpinned above 4); off = never pinned; wrap = worker i on CPU i mod 4.

| policy | reply/idle spin | svc µs | gap µs | W | pin | hop p50 µs | hop p99 µs | hop p99.9 µs | CPU µs/hop | hops/s | waste | load1 start→end | try | status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fixed | 0 | 0.1 | 0 | 2 | auto | 24.1 [24.1..26.1] 8% | 52.2 [48.1..62.5] 28% | 167.9 [88.1..450.6] 216% | 11.03 [10.23..11.73] 14% | 77k [71k..86k] 19% | 0.43 [0.41..0.43] 6% | 3.91→3.67 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 2 | off | 25.1 [23.0..25.1] 8% | 60.4 [54.3..67.6] 22% | 270.3 [112.6..606.2] 183% | 11.31 [10.47..11.54] 10% | 74k [73k..81k] 10% | 0.42 [0.40..0.43] 8% | 4.78→4.55 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 2 | auto | 0.8 [0.3..0.9] 73% | 1.2 [1.0..1.6] 53% | 22.0 [14.1..33.8] 90% | 0.91 [0.55..1.03] 52% | 2085k [1739k..3502k] 84% | 0.82 [0.80..0.86] 8% | 2.99→2.83 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 2 | off | 0.8 [0.7..1.0] 38% | 1.2 [1.1..2.0] 72% | 33.8 [24.1..35.8] 35% | 0.90 [0.83..1.16] 37% | 2024k [1661k..2270k] 30% | 0.84 [0.81..0.88] 9% | 4.24→4.24 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 2 | auto | 0.8 [0.7..0.9] 26% | 1.2 [1.1..1.5] 38% | 13.6 [13.1..17.9] 36% | 0.88 [0.81..0.98] 20% | 2234k [2007k..2464k] 20% | 0.87 [0.86..0.90] 4% | 3.72→3.72 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 2 | off | 0.8 [0.7..0.9] 24% | 1.2 [1.1..1.4] 22% | 13.6 [12.0..15.6] 26% | 0.95 [0.84..1.01] 18% | 2087k [1969k..2338k] 18% | 0.88 [0.86..0.90] 4% | 3.64→3.51 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 3 | auto | 23.0 [22.0..24.1] 9% | 79.9 [75.8..84.0] 10% | 225.3 [151.6..606.2] 202% | 10.85 [10.52..11.20] 6% | 108k [106k..115k] 9% | 0.39 [0.38..0.40] 6% | 3.78→3.78 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 3 | off | 24.1 [24.1..26.1] 8% | 88.1 [84.0..96.3] 14% | 270.3 [192.5..540.7] 129% | 11.68 [11.47..12.45] 8% | 101k [96k..106k] 10% | 0.40 [0.38..0.41] 7% | 3.49→3.45 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 3 | auto | 1.1 [0.9..1.2] 27% | 3.1 [2.6..4.2] 51% | 33.8 [23.0..35.8] 38% | 1.26 [1.12..1.47] 27% | 2264k [1950k..2513k] 25% | 0.89 [0.86..0.90] 5% | 3.13→3.12 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 3 | off | 1.1 [1.0..1.1] 11% | 3.5 [3.0..4.7] 49% | 46.1 [35.8..60.4] 53% | 1.29 [1.20..1.38] 14% | 2135k [1865k..2337k] 22% | 0.85 [0.79..0.87] 9% | 3.68→3.47 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 3 | auto | 1.1 [1.0..1.1] 11% | 3.0 [2.6..3.4] 26% | 18.9 [16.9..29.2] 65% | 1.25 [1.20..1.37] 14% | 2394k [2141k..2480k] 14% | 0.91 [0.90..0.91] 2% | 3.63→3.66 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 3 | off | 1.1 [1.1..1.2] 11% | 3.1 [2.9..3.8] 29% | 20.0 [17.9..22.0] 20% | 1.33 [1.25..1.42] 13% | 2218k [2047k..2395k] 16% | 0.91 [0.89..0.92] 2% | 4.57→4.44 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 4 | auto | 25.1 [25.1..26.1] 4% | 75.8 [67.6..79.9] 16% | 540.7 [208.9..966.7] 140% | 11.40 [11.14..11.81] 6% | 137k [130k..144k] 10% | 0.39 [0.37..0.40] 7% | 3.30→3.19 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 4 | off | 25.1 [25.1..26.1] 4% | 71.7 [67.6..108.5] 57% | 270.3 [200.7..933.9] 271% | 11.47 [11.20..11.92] 6% | 140k [124k..145k] 15% | 0.40 [0.37..0.40] 10% | 3.67→3.67 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 4 | auto | 1.1 [1.1..1.2] 11% | 4.2 [3.6..4.7] 26% | 46.1 [42.0..52.2] 22% | 1.36 [1.28..1.42] 11% | 2635k [2538k..2866k] 12% | 0.83 [0.82..0.85] 4% | 3.79→3.81 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 4 | off | 1.1 [1.0..1.1] 11% | 5.2 [4.5..16.1] 222% | 62.5 [52.2..79.9] 44% | 1.33 [1.27..1.52] 19% | 2510k [2048k..2756k] 28% | 0.77 [0.73..0.81] 10% | 3.96→3.88 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 4 | auto | 1.1 [1.1..1.1] 6% | 3.4 [2.8..4.5] 51% | 25.1 [17.9..33.8] 63% | 1.36 [1.28..1.59] 23% | 2871k [2427k..3066k] 22% | 0.90 [0.90..0.91] 1% | 3.52→3.52 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 4 | off | 1.1 [1.0..1.1] 11% | 3.4 [2.8..3.9] 34% | 20.0 [17.9..28.2] 51% | 1.36 [1.23..1.41] 14% | 2864k [2763k..3225k] 16% | 0.91 [0.90..0.92] 2% | 3.28→3.33 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 5 | auto | 26.1 [25.1..27.1] 8% | 96.3 [88.1..100.4] 13% | 368.6 [217.1..540.7] 88% | 11.05 [10.61..11.56] 9% | 164k [157k..172k] 9% | 0.36 [0.35..0.36] 4% | 5.97→5.97 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 5 | off | 28.2 [27.1..30.2] 11% | 108.5 [100.4..120.8] 19% | 499.7 [385.0..1032.2] 130% | 12.10 [11.54..12.90] 11% | 148k [129k..154k] 17% | 0.35 [0.31..0.36] 13% | 4.43→4.24 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 5 | wrap | 27.1 [25.1..27.1] 8% | 104.4 [96.3..120.8] 24% | 483.3 [270.3..868.4] 124% | 11.54 [10.86..12.04] 10% | 155k [144k..166k] 14% | 0.36 [0.34..0.36] 4% | 3.76→3.62 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 5 | auto | 4.0 [3.4..5.2] 46% | 124.9 [116.7..129.0] 10% | 352.3 [200.7..540.7] 96% | 8.86 [8.30..9.60] 15% | 253k [226k..278k] 21% | 0.44 [0.42..0.46] 7% | 6.44→6.25 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 5 | off | 3.5 [3.3..3.9] 18% | 116.7 [112.6..116.7] 4% | 233.5 [225.3..368.6] 61% | 8.27 [8.05..8.57] 6% | 274k [252k..283k] 11% | 0.44 [0.43..0.46] 7% | 4.52→4.31 | 3 | ok |
| fixed | 5000 | 0.1 | 0 | 5 | wrap | 4.0 [3.8..4.7] 24% | 129.0 [116.7..143.4] 21% | 286.7 [217.1..770.0] 193% | 8.57 [8.49..9.25] 9% | 262k [228k..270k] 16% | 0.44 [0.42..0.45] 8% | 3.67→3.70 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 5 | auto | 1.2 [1.1..1.3] 15% | 7995.4 [7995.4..7995.4] 0% | 11796.5 [7995.4..15990.8] 68% | 1006.64 [995.27..1088.15] 9% | 4k [4k..4k] 9% | 0.79 [0.77..0.79] 3% | 3.31→3.44 | 1 | ok |
| fixed | inf | 0.1 | 0 | 5 | off | 1.2 [1.1..1.2] 11% | 7995.4 [7995.4..7995.4] 0% | 11796.5 [7995.4..13893.6] 50% | 1018.41 [922.50..1051.11] 13% | 4k [4k..4k] 11% | 0.79 [0.77..0.80] 4% | 3.63→3.74 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 5 | wrap | 1.2 [1.1..1.3] 16% | 7995.4 [7995.4..8257.5] 3% | 12320.8 [7995.4..15990.8] 65% | 986.74 [958.14..1042.74] 9% | 4k [4k..4k] 8% | 0.79 [0.78..0.79] 1% | 3.76→3.86 | 1 | ok |
| fixed | 0 | 0.1 | 0 | 6 | auto | 29.2 [27.1..30.2] 10% | 112.6 [104.4..129.0] 22% | 450.6 [303.1..933.9] 140% | 11.98 [11.29..12.33] 9% | 169k [164k..178k] 8% | 0.34 [0.33..0.34] 5% | 3.15→3.15 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 6 | off | 28.2 [27.1..29.2] 7% | 104.4 [96.3..120.8] 24% | 303.1 [184.3..704.5] 172% | 11.42 [11.12..12.12] 9% | 181k [169k..190k] 12% | 0.34 [0.34..0.35] 4% | 2.98→2.98 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 6 | wrap | 28.2 [27.1..29.2] 7% | 108.5 [100.4..120.8] 19% | 335.9 [225.3..835.6] 182% | 11.47 [11.27..12.01] 6% | 181k [169k..187k] 10% | 0.34 [0.33..0.35] 6% | 4.77→4.77 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 6 | auto | 18.9 [16.9..21.0] 22% | 124.9 [116.7..124.9] 7% | 434.2 [233.5..540.7] 71% | 11.28 [10.63..11.94] 12% | 228k [197k..245k] 21% | 0.43 [0.39..0.44] 11% | 3.48→3.48 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 6 | off | 16.1 [15.1..18.9] 24% | 116.7 [116.7..124.9] 7% | 417.8 [241.7..639.0] 95% | 10.40 [10.29..11.18] 9% | 246k [232k..257k] 10% | 0.43 [0.42..0.44] 4% | 3.70→3.89 | 1 | ok |
| fixed | 5000 | 0.1 | 0 | 6 | wrap | 18.9 [16.9..24.1] 38% | 124.9 [116.7..159.7] 34% | 573.4 [270.3..2293.8] 353% | 11.19 [11.02..13.39] 21% | 222k [166k..238k] 32% | 0.41 [0.37..0.44] 18% | 3.72→3.74 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 6 | auto | 2.0 [1.8..3.9] 103% | 7995.4 [7995.4..7995.4] 0% | 11796.5 [8257.5..15990.8] 66% | 1599.72 [1577.51..1710.61] 8% | 2k [2k..3k] 8% | 0.66 [0.65..0.66] 2% | 3.54→3.54 | 3 | ok |
| fixed | inf | 0.1 | 0 | 6 | off | 2.1 [1.8..8.1] 298% | 7995.4 [7995.4..7995.4] 0% | 11796.5 [11796.5..17301.5] 47% | 1625.19 [1566.19..1696.26] 8% | 2k [2k..2k] 6% | 0.66 [0.65..0.66] 2% | 3.52→3.52 | 2 | ok |
| fixed | inf | 0.1 | 0 | 6 | wrap | 4.2 [2.8..6.3] 83% | 7995.4 [7995.4..7995.4] 0% | 12320.8 [8257.5..15990.8] 63% | 1695.17 [1666.36..1705.93] 2% | 2k [2k..2k] 4% | 0.66 [0.65..0.67] 2% | 3.88→4.05 | 3 | ok |
| fixed | 0 | 0.1 | 0 | 8 | auto | 31.2 [29.2..33.8] 15% | 120.8 [112.6..135.2] 19% | 434.2 [335.9..770.0] 100% | 11.83 [11.24..12.78] 13% | 215k [193k..227k] 16% | 0.32 [0.31..0.32] 4% | 4.24→4.46 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 8 | off | 32.3 [31.2..33.8] 8% | 129.0 [116.7..176.1] 46% | 466.9 [241.7..933.9] 148% | 12.43 [12.23..13.20] 8% | 199k [193k..210k] 9% | 0.32 [0.30..0.32] 7% | 3.67→3.78 | 3 | **NOISY** |
| fixed | 0 | 0.1 | 0 | 8 | wrap | 30.2 [30.2..31.2] 3% | 116.7 [108.5..135.2] 23% | 671.7 [217.1..1540.1] 197% | 11.96 [11.76..12.51] 6% | 215k [192k..226k] 16% | 0.32 [0.30..0.33] 11% | 3.14→3.29 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 8 | auto | 26.1 [25.1..27.1] 8% | 120.8 [112.6..135.2] 19% | 401.4 [184.3..1081.3] 224% | 12.86 [12.44..13.41] 8% | 259k [240k..269k] 11% | 0.41 [0.38..0.42] 10% | 5.65→5.84 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 8 | off | 28.2 [26.1..29.2] 11% | 151.6 [129.0..167.9] 26% | 639.0 [368.6..1409.0] 163% | 13.87 [13.14..14.61] 11% | 223k [205k..254k] 22% | 0.39 [0.35..0.41] 17% | 5.40→5.28 | 3 | **NOISY** |
| fixed | 5000 | 0.1 | 0 | 8 | wrap | 26.1 [25.1..29.2] 16% | 129.0 [116.7..319.5] 157% | 671.7 [208.9..1146.9] 140% | 13.08 [12.66..14.49] 14% | 243k [216k..268k] 22% | 0.40 [0.38..0.42] 10% | 4.54→4.82 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 8 | auto | 7995.4 [4128.8..7995.4] 48% | 11796.5 [7995.4..13369.3] 46% | 15990.8 [11796.5..20447.2] 54% | 2264.42 [2159.73..2376.34] 10% | 2k [2k..2k] 9% | 0.49 [0.49..0.50] 2% | 4.52→4.80 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 8 | off | 7209.0 [3997.7..7995.4] 56% | 11796.5 [11796.5..15990.8] 36% | 15990.8 [11796.5..36700.2] 156% | 2271.31 [2213.75..2337.87] 6% | 2k [2k..2k] 7% | 0.49 [0.48..0.50] 4% | 4.52→4.52 | 3 | **NOISY** |
| fixed | inf | 0.1 | 0 | 8 | wrap | 7995.4 [7995.4..7995.4] 0% | 9175.0 [7995.4..11796.5] 41% | 11796.5 [11796.5..15990.8] 36% | 2217.65 [2125.01..2322.21] 9% | 2k [2k..2k] 10% | 0.49 [0.49..0.50] 2% | 3.93→3.93 | 3 | **NOISY** |

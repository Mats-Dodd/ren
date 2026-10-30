# percore — cloud results summary

**Machine: `cloud`** (claude.ai cloud container, experiments/MACHINE-cloud.md): 4 vCPUs (KVM, Intel Xeon @ 2.10 GHz, no SMT), Linux 6.18.44, clang 18.1.3 at -O2 (TSan build with gcc 13.3.0). Measured 2026-10-30, 06:33–11:05 UTC.
This is **not** the macOS reference. The macOS (Apple M4 Max) files are the ones directly in `results/`, and they are unchanged.

Every configuration ran alone under `flock -x /tmp/ren-bench/lock`, one configuration per lock acquisition, with 7 reps. Spread is (max−min)/median of the gate metric. A configuration with spread > 10% was re-run up to twice more. If it was still above 10%, the try with the smallest spread was kept and marked **NOISY**. The gate metric is Mops/s for the closed-loop matrix and for throughput mode, and light-request p99 for latency mode. Correctness checks passed everywhere: 0 rep lines with `ok=0` in every file, 0 keyset mismatches in the base matrix, and one `keyset_sum` and one `work_sum` per load across all runtimes in the extension. Smoke and TSan were clean before every run (`smoke-*.log`).

## Files

| file | contents | configs | NOISY | 1-min load (start/end of each config, min..max) | steal ticks (sum) | timed s |
|---|---|---|---|---|---|---|
| `measure-20261030-063328.txt` | extension: throughput mode + latency at 25/50/75% (`measure-cloud.sh ext`) | 40 | 33 | 2.20..6.83 | 12662 | 2456 |
| `measure-20261030-073608.txt` | oversubscription check (`measure-cloud.sh oversub`, added in this step) | 25 | 15 | 2.08..6.26 | 4277 | 1141 |
| `measure-20261030-080128.txt` | extension, skewed latency, 4× longer runs (`_long`, 400k req/stream) | 6 | 6 | 3.04..4.08 | 9078 | 1990 |
| `measure-20261030-083705.txt` | base matrix, uniform, ws_* variants | 48 | 39 | 1.66..6.00 | 7671 | 1826 |
| `measure-20261030-093149.txt` | base matrix, uniform, pc_* variants | 48 | 29 | 1.48..6.49 | 5500 | 1430 |
| `measure-20261030-100954.txt` | base matrix, zipf, ws_* variants | 48 | 43 | 1.47..4.77 | 4535 | 1185 |
| `measure-20261030-103543.txt` | base matrix, zipf, pc_* variants | 48 | 28 | 1.07..6.57 | 5016 | 1356 |

Each file has a `LOAD` line per try with `load1_start`/`load1_end` from /proc/loadavg and the steal ticks for that try. The per-config load is also in the tables below. **How to read the load:** the 1-minute load average lags. A value of 3 to 6 at the start of a configuration is mostly the previous benchmark's 4 to 8 busy threads, ours or another agent's, still in the average. Nothing else ran during a configuration, because the exclusive lock was held.

**Hypervisor steal is the dominant noise source.** Summed /proc/stat steal is about 1.1 to 1.3% of vCPU time across the runs. The `--gap-probe` in each extension header shows one pinned spinner per vCPU losing its CPU 13 to 74 times per 400 ms, for up to 4.1 ms at a time (`# GAP` lines). This is why most short closed-loop configurations and **every latency-mode configuration** are NOISY. 4× longer runs did not fix it: the `_long` spreads were 0.15 to 0.67, against 0.21 to 0.86 for the short runs.

## Script bugs fixed in this step

1. `measure-cloud.sh` ran `flock -x $LOCK "$0" --one ...` after `cd "$(dirname "$0")"`. With a relative invocation (`percore/measure-cloud.sh`), `$0` no longer resolved, and every configuration failed with "No such file". The first attempt produced only failures and was deleted. **Fix:** the script resolves its absolute path first (`SELF`).
2. Added `oversub` mode, for the oversubscription check below.
3. Added `XTHR=0`, `XWSM_<load>` and `XTAG` to `ext`, so latency configurations can be re-run at the same offered rates without re-running throughput mode. These were used for the `_long` runs.

No change to `c/percore.c`.

## Reproducing

All commands run from `experiments/runtime-p2/percore`. First run `flock -s /tmp/ren-bench/lock ./build.sh`, then one configuration (7 reps) under the exclusive lock:

    flock -x /tmp/ren-bench/lock sh -c 'for i in 1 2 3 4 5 6 7; do ./bin/percore ARGS; done' | grep -oE ' (mops|light_p50_ns|light_p99_ns|light_p999_ns|p99_ns|sustained)=[0-9.]+' | paste - - - - - -

The exact ARGS for every configuration are in the `.cmds` file next to each result file. Skewed runs use `--work-iters 46208`, the calibrated 200 µs chunk from the header of measure-20261030-063328. The `_long` runs used 44683, calibrated again at that time.

## The answer: does place_at_spawn + a stealing pool recover work_stealing's tail latency?

**For light requests under skewed load: yes, and it does better than work_stealing, as long as the pool keeps up. For everything else: no.**

- **Skewed load (Zipf 0.99, 5% of requests run a ~200 µs chunk), light-request p99.**
  - At 25% of work_stealing's throughput: place_at_spawn 19.5 µs (3+1) and 20.0 µs (2+2), against work_stealing's 44.0 µs. In the `_long` re-run: 20.5 and 24.6 µs against 53.2 µs.
  - At 50%: 2+2 gives 32.8 µs against 200.7 µs. In `_long`: 28.2 µs against 184.3 µs.
  - That is 2 to 6.5× lower. In both sessions, **every one of the 7 reps** of place_at_spawn was below **every one of the 7 reps** of work_stealing:
    - 25%: pas [16.9..25.1] µs against ws [39.9..49.2] µs; `_long` [18.4..26.1] against [49.2..62.5].
    - 50%: pas_2p2 [23.0..51.2] against ws [163.8..237.6]; `_long` [21.0..39.9] against [159.7..233.5].
  - All of these configurations are **NOISY** (light-p99 spreads 0.15 to 0.86), so by the rules none of them is a headline. The ordering is still not in doubt.
- **Skewed load, light p999: not recovered.** The ranges overlap and are steal-dominated:
  - 25%: pas_2p2 0.80 ms against ws 0.79 ms.
  - 50%: 1.47 ms against 2.62 ms, with per-rep ranges of [0.52..1.97] and [0.54..3.54] ms.
- **Skewed load, all requests and heavy requests: worse.**
  - Overall p99 at 25%: 270 µs for 2+2 against 213 µs for ws. At 50%: 1.18 ms against 0.28 ms.
  - Heavy p99 at 50%: 7.2 ms for 2+2 against 0.49 ms for ws. Heavy requests queue for 2 pool threads.
  - The 3+1 split cannot sustain 50% at all (cap 98k req/s), so its heavy latency grows without bound: heavy p50 0.87 s.
- **Throughput under skew: place_at_spawn loses.** 3+1 manages 0.098 Mreq/s and 2+2 0.193, against ws at 0.340, a 0.29× and 0.57× ratio.
- **Even load (no chunks): not recovered.**
  - Light p50 is close: ws 2.37 µs, 3+1 2.69 µs, 2+2 2.69 µs.
  - Light p99 at 25% is worse: 278 µs for 3+1 and 754 µs for 2+2, against ws at 58 µs. All NOISY, with overlapping ranges (ws [35..459] µs).
  - At 50% and 75%, every runtime's light p99 is 1 to 40 ms. That is vCPU steal plus queueing, and it does not separate the designs. At 75%, 2+2 and 4+4 do not sustain the offered rate.
- **Oversubscribed 4+4 does not recover the tail.** Light p99 under skew is 25 µs at 25% but 483 µs at 50%, against ws at 200 µs. At even load it is no better than ws.

**per_core is clearly the worst tail under skew.**
- Light p99 is 4.1 ms at 25% and 12.3 ms at 50%.
- Light p50 is 213 µs at 50%: a light request waits behind a 200 µs chunk on its home or owner core.
- It does not sustain 75%.

## Headlines (non-NOISY numbers only)

| # | claim | median [min..max] | spread | config / file |
|---|---|---|---|---|
| H1 | Skewed throughput, work_stealing | 0.340 [0.332..0.366] Mreq/s | 0.100 | x_skewed_thr_ws, 063328 |
| H2 | Skewed throughput, per_core | 0.201 [0.199..0.214] Mreq/s | 0.075 | x_skewed_thr_pc, 063328 |
| H3 | Skewed throughput, place_at_spawn 3+1 | 0.098 [0.097..0.101] Mreq/s | 0.041 | x_skewed_thr_pas_3p1, 063328 |
| H4 | Skewed throughput, place_at_spawn 2+2 | 0.193 [0.188..0.198] Mreq/s | 0.052 | x_skewed_thr_pas_2p2, 063328 |
| H5 | Even throughput, place_at_spawn 3+1 / 2+2 / 4+4 | 0.674 [0.653..0.694] / 0.664 [0.655..0.715] / 0.600 [0.570..0.626] Mreq/s | 0.061 / 0.090 / 0.093 | x_even_thr_pas_*, 063328 |
| H6 | Skewed 25%, work_stealing: light p50 / all-request p99 / heavy p50 | 1.02 [0.96..1.02] µs / 213 [209..213] µs / 196.6 [196.6..196.6] µs | 0.06 / 0.02 / 0.00 | x_skewed_lat25_ws, 063328 |
| H7 | Skewed 25%, place_at_spawn 2+2 (`_long`): light p50 / all-request p99 / heavy p50 | 1.22 [1.18..1.25] µs / 254 [246..270] µs / 196.6 [196.6..196.6] µs | 0.05 / 0.10 / 0.00 | x_skewed_lat25_pas_2p2_long, 080128 |
| H8 | Even 25%, light p50: work_stealing / place_at_spawn 3+1 | 2.37 [2.30..2.50] µs / 2.69 [2.56..2.82] µs | 0.08 / 0.10 | x_even_lat25_{ws,pas_3p1}, 063328 |
| H9 | Oversubscription: pc_spin (50/50 uniform) at 5 / 6 / 8 threads on 4 vCPUs, pinned or not | 0.233 [0.219..0.238] / 0.211 [0.200..0.217] / 0.227 [0.209..0.230] (8 pinned 2 per CPU) / 0.213 [0.206..0.222] (8 unpinned) Mops/s | 0.08 / 0.08 / 0.09 / 0.08 | o_pc_spin_*_w5/w6/w8_pinon, b_pc_spin_g50_uniform_w8 |
| H10 | Oversubscription: pc_spin_if4 (5/95 zipf), 4 → 8 threads | 3.133 [3.040..3.344] → 0.552 [0.548..0.582] Mops/s (5.7× collapse) | 0.097 / 0.062 | b_pc_spin_if4_g5_zipf_w4 / _w8, 103543 |
| H11 | Oversubscription: pc_park (50/50 uniform) does *not* collapse: 4 → 8 threads | 0.157 [0.151..0.160] → 0.202 [0.197..0.210] Mops/s | 0.057 / 0.064 | b_pc_park_g50_uniform_w4 / _w8, 093149 |

### Throughput and latency for the three runtimes (all the numbers asked for; NOISY entries flagged)

Throughput mode is the `--rate 0` runs. Latency is in µs, as the median of 7 reps, measured from arrival to completion.

| load | runtime | throughput Mreq/s | light p50 | light p99 | light p999 | all p50* | all p99 | all p999 |
|---|---|---|---|---|---|---|---|---|
| even | work_stealing | 0.774 [0.678..0.797] **NOISY** | 2.4 @25% · 2.4 @50% | 58 @25% · 1049 @50% **NOISY** | 1933 @25% · 4588 @50% **NOISY** | = light | = light | = light |
| even | per_core | 2.382 [2.053..2.542] **NOISY** | 2.2 · 2.0 (NOISY at 25%) | 1835 · 2359 **NOISY** | 5636 · 4850 **NOISY** | = light | = light | = light |
| even | place_at_spawn 3+1 | 0.674 [0.653..0.694] | 2.7 · 2.8 (NOISY at 50%) | 279 · 1606 **NOISY** | 2818 · 5112 **NOISY** | = light | = light | = light |
| even | place_at_spawn 2+2 | 0.664 [0.655..0.715] | 2.7 · 3.8 **NOISY** | 754 · 1376 **NOISY** | 7602 · 3473 **NOISY** | = light | = light | = light |
| skewed | work_stealing | 0.340 [0.332..0.366] | 1.0 @25% · 1.1 @50% (NOISY) | 44 @25% · 201 @50% **NOISY** | 786 · 2621 **NOISY** | ≈ light | 213 · 279 (NOISY at 50%) | 852 · 2687 **NOISY** |
| skewed | per_core | 0.201 [0.199..0.214] | 2.1 · 213 **NOISY** | 4129 · 12321 **NOISY** | 11797 · 15204 **NOISY** | ≈ light | 4129 · 12321 **NOISY** | 11797 · 15204 **NOISY** |
| skewed | place_at_spawn 3+1 | 0.098 [0.097..0.101] | 1.2 · 1.2 (50%: not sustained) | 19.5 · 26.6 **NOISY** | 410 · 1606 **NOISY** | ≈ light | 1737 · 1.4 s(!) | 7340 · 1.7 s(!) |
| skewed | place_at_spawn 2+2 | 0.193 [0.188..0.198] | 1.0 · 1.0 (NOISY at 25%) | 20.0 · 32.8 **NOISY** | 803 · 1475 **NOISY** | ≈ light | 270 · 1180 **NOISY** | 1344 · 6160 **NOISY** |

\*With 95% light requests the all-request p50 is the light p50. Even load has no heavy requests. `(!)` means not sustained: the offered 170k req/s exceeds the 3+1 cap, so the queue grows for the whole run. In throughput mode, latency is queueing from t=0 and is not reported. Even-load latency at 75% and skewed at 75% are in the full table. At 75%, every place_at_spawn split and per_core fail to sustain under skew, and 2+2 and 4+4 fail under even load.

## Oversubscription check (4 vCPUs)

The question is whether the collapse above N workers comes from oversubscribing this 4-vCPU machine or from the design. It comes from oversubscription, and it hits only the spinning per_core variants. All configurations are 50/50 uniform, Mops/s, median [min..max]. Configurations without a file name are from `measure-20261030-073608`.

| variant | 3 thr (pinned) | 4 thr pinned (base) | 4 thr unpinned | 5 thr | 6 thr | 8 thr pinned 2/CPU | 8 thr unpinned (base) |
|---|---|---|---|---|---|---|---|
| pc_spin | 1.095* | 1.530* [1.343..1.606] | 1.439* [1.322..1.642] | **0.233** [0.219..0.238] | **0.211** | **0.227** | **0.213** |
| pc_spin_if4 | 1.662* | 2.272* [1.914..2.510] | 2.393* | **0.589** [0.559..0.611] | 0.534* | 0.432* | **0.481** |
| pc_park | 0.139 | 0.157 | 0.158 | 0.166 | 0.177 | 0.214 | 0.202 |
| ws_sharded | 0.608* | 0.811* | 0.747* | 0.916* | 0.895* | 1.184* | 1.003 |
| ws_one | 0.237* | 0.254 | 0.251* | 0.300* | 0.311 | 0.386* | 0.341* |

(* = NOISY)

- **The collapse starts at exactly 5 threads.** pc_spin falls 6.2× from 4 threads to 5 threads, and pc_spin_if4 falls 3.9×. Both collapsed values are non-NOISY, and their ranges are far below the 4-thread minimum.
- **Pinning does not matter.** 4 threads unpinned is as fast as 4 pinned, and 8 threads pinned two per CPU collapses exactly like 8 unpinned.
- **The parking variants do not collapse.** pc_park and the work_stealing variants keep rising slowly up to 8 threads.

So the collapse is caused by running more threads than vCPUs. A spinning per_core home core that is descheduled stalls every core that hops to it. That is a property of spinning per_core under oversubscription, but on 4 vCPUs it appears at 5 threads only because the machine has 4 vCPUs. It is not a general cliff in the design at "N workers".

## Against PLAN.md's predictions

### Extension (E1–E6)

| pred | predicted | measured on cloud | verdict |
|---|---|---|---|
| E1 | ws and pc within 1.5×, **ws wins** by 1.1–1.5× (even load, throughput) | pc 2.382 against ws 0.774 Mreq/s: **pc is 3.1× faster**. Both NOISY, but the ranges are disjoint. ws's cpu/wall is 2.67: its workers park on the shard locks. | **Disagrees** |
| E1 | pas_3p1 0.6–0.8× ws, pas_2p2 0.4–0.55×, pas_4p4 0.5–0.9× | 0.87×, 0.86× and 0.78×. place_at_spawn is closer to ws than predicted, because ws itself is slow here. | 3p1 and 2p2 **disagree** (higher); 4p4 agrees |
| E2 | ws light p50 1–3 µs, p99 < 10 µs, p999 10–50 µs | p50 2.4 µs; p99 58 µs at 25% and 1.05 ms at 50%; p999 1.9 ms (all NOISY) | p50 agrees; **p99 and p999 disagree** by 6–100× |
| E2 | pc p50 0.3–1 µs above ws; pc p99 within 2× of ws | pc p50 is 0.2 µs *below* ws (2.18 against 2.37); pc p99 1.8 ms against 58 µs (31×) | **Disagrees**, as the port agent expected (vCPU steal stalls all cores) |
| E2 | pas within 1.5× of ws on p50 and p99 | p50 1.13× (agrees); p99 4.8× for 3+1 and 13× for 2+2 at 25% (NOISY) | p50 agrees; **p99 disagrees** |
| E2 | pas_2p2 may not sustain 75% | not sustained; 4+4 also not | agrees |
| E3 | ws ≈ pc ≈ 250–380k req/s, within 1.3× | ws 340k (in range); **pc 201k, so ws/pc = 1.69×** | ws agrees; **pc disagrees** |
| E3 | pas_3p1 80–110k, pas_2p2 160–210k, pas_4p4 0.7–1.0× ws | 98k, 193k, 0.81× (4p4 NOISY) | agrees |
| E4 | ws light p99 < 20 µs at 25%, 10–100 µs at 50%; p999 20–150 µs at 25%, 100–250 µs at 50% | p99 44 µs at 25% and 201 µs at 50%; p999 0.79 ms at 25% and 2.6 ms at 50% (NOISY) | **Disagrees**: 2× higher on p99, 5–10× on p999 |
| E4 | pc light p99 150–250 µs at 25%; at 50% p50 > 10 µs, p99 200–400 µs, p999 300–800 µs; ≥ 5× ws | 4.1 ms at 25%; at 50% p50 213 µs, p99 12.3 ms, p999 15.2 ms; ≥ 60× ws | direction and "≥ 5×" agree; **magnitudes disagree** (10–30× worse than predicted) |
| E4 | pas light p99 < 10 µs, p999 < 50 µs, and ≥ 2× better than ws at 50% | p99 19.5–33 µs; p999 0.4–1.5 ms; 6.1× better than ws at 50% (2+2) | **p99 and p999 levels disagree**; the "≥ 2× better than ws" claim **agrees** |
| E4 | 3+1 can't sustain 50%; unsustained light latency stays low | not sustained; light p99 26.6 µs while heavy p50 is 0.87 s | agrees |
| E4 | pas_4p4 light p99 within 0.5–2× ws; p999 no better than ws | 0.57× at 25% and 2.4× at 50%; p999 1.5× and 1.3× worse | p99 agrees at 25%, **disagrees** at 50%; p999 agrees |
| E5 | ws heavy p50 ≈ 200–220 µs | 196.6 µs (the calibrated chunk measured ~197 µs) | 2% below the range: **disagrees slightly** |
| E5 | pas_2p2 heavy p99 ≥ 2× ws at 50% | 7.2 ms against 0.49 ms (14.7×) | agrees |
| E5 | overall p99 ≥ 200 µs everywhere | yes (minimum: ws at 25%, 213 µs) | agrees |
| E5 | at 75% only ws, pc and maybe pas_4p4 sustain | ws sustains; **pc does not** (0.202 achieved of 0.254 offered); pas_4p4 does not | **Disagrees** for pc |
| E6 | pas recovers and beats ws's light tail if the pool is big enough; pays in throughput and heavy latency | light p99: yes (2–6.5×); light p999: no (overlapping, steal-bound); throughput and heavy latency: paid as predicted | agrees for p99, **disagrees for p999** |
| E6 | a fixed split doesn't recover the overall tail at ≥ 50% | overall p99 1.18 ms against 0.28 ms | agrees |
| E6 | 4+4 lands near ws, not below | below at 25% (25 against 44 µs), 2.4× worse at 50% | mixed |
| E6 | per_core clearly worst under skew | yes | agrees |

### Original matrix (1, 2, 4, 8 workers; predictions 6 and the 12/16-worker parts cannot be tested on 4 vCPUs)

| pred | measured on cloud | verdict |
|---|---|---|
| 1. 1 worker: all within 25%; ws_keyed fastest by up to 20% | max/min at w1: uniform 95/5 1.18, 50/50 1.21, 5/95 1.28; zipf 95/5 1.26, 50/50 1.17, 5/95 1.42. ws_keyed is fastest only at zipf 95/5 (2.101). Under uniform keys ws_one is fastest (0.955 against ws_keyed's 0.809 at 95/5). | **Disagrees** in 3 of 6 cells; ws_keyed is not generally fastest |
| 2. ws_one peaks at 2–4 workers at 3–4 M/s | ws_one peaks at **1** worker (0.96 uniform, 2.04 zipf) and falls 4× at w2 (0.24). It never comes near 3 M/s. It is not the worst p99 at w8 (ws_worker and pc_spin_if4 are). | **Disagrees** |
| 3. ws_worker never best; at 5/95 within 1.3× of ws_keyed | Never best at w ≥ 2 (agrees). 5/95 w4: uniform 1.45×, zipf 1.26×. | agrees except 5/95 uniform |
| 4. 95/5: ws_keyed ≈ ws_sharded within 20% | w4 uniform 95/5: ws_keyed 1.978, ws_sharded 1.022 (1.9×) | **Disagrees** |
| 5. ws_sharded beats pc_spin (inflight 1) at every mix from 2 workers up, by 1.2–2× | **pc_spin beats ws_sharded at w2 and w4 at every mix and distribution** (narrowest: zipf 95/5 w4, 1.954 against 1.888, both NOISY), e.g. 50/50 uniform w4: 1.530 against 0.811. ws_sharded wins only at w8, which is oversubscribed (1.003 against 0.213). | **Disagrees** (the decision-2 prediction is reversed at w ≤ 4 on this machine) |
| 7. pc_park 5–20× below pc_spin; pc_park_if4 2–4× pc_park; pc_park p50 4–8 µs | 9.7× (w4) and 5.5× (w2); pc_park_if4 4.4× pc_park (w4); pc_park p50 6.4 µs (w2) and 20.5 µs (w4) | ratio agrees; **if4 slightly above; p50 at w4 disagrees** |
| 8. pc_spin_if4 1.2–2× pc_spin from w4; at 5/95 w ≥ 8 matches ws_sharded | 1.49× (uniform 50/50 w4) and 1.77× (zipf); at 5/95 w8 0.475 against ws_sharded 1.057 | first part agrees; **second disagrees** (w8 is oversubscribed) |
| 9. pc_spin cpu/wall ≈ N | 1.0, 1.95, 3.66 at w1, w2, w4 | agrees |
| 10. ws_sharded p50 300–700 ns; pc_spin p50 = op + 150–400 ns | ws_sharded p50 1.06 µs (w1) and 1.79 µs (w4); pc_spin 1.06 µs (w1) and 1.82 µs (w4) | **Disagrees**: everything is 2–3× slower than the M4-based guess. pc_spin's hop cost is not visible as an added p50. |
| 11. Zipf costs sharded variants 1.3–2×; pc_spin/ws_sharded ratio unchanged within 20% | Zipf is **faster** than uniform for every variant except pc_park and pc_park_if4, which are equal within 3% (ws_sharded w4 50/50: 1.357 against 0.811). pc_spin/ws_sharded is 1.89 (uniform) against 1.30 (zipf), a 31% change. | **Disagrees** |

## Against the macOS reference (results/measure-20261029-224937.txt)

The macOS reference run is mostly broken. 336 of its 428 rep lines are `crashed=1 ok=0`: they are usage errors, and `.err` contains the usage text 1344 times. Only `ws_one` has a full matrix. The other variants have scattered valid lines, labelled with workers=5 or 10. Also, macOS has no extension (no place_at_spawn, no skewed or open-loop runs), so **there is no macOS reference for the main question**. Where the two can be compared:

- **ws_one is 2.2× slower on cloud at 1 worker** (0.955 against 2.08 Mops/s, uniform 95/5). It is also not flat with workers: on macOS ws_one stays at 1.5–1.9 Mops/s from 1 to 16 workers, while on cloud it drops 4× at 2 workers (0.24) and recovers only to 0.40 at 8. This disagrees with macOS's shape, not only its scale.
- **pc_spin against ws_sharded is reversed.** On macOS (10 workers, 95/5 uniform) ws_sharded beat pc_spin, 11.8 against 7.9 Mops/s. On cloud at 4 workers, pc_spin beats ws_sharded 1.68× (1.719 against 1.022). This does not match macOS.
- **pc_park:** 0.52–0.70 Mops/s with p50 7–18 µs on macOS, against 0.12–0.16 Mops/s with p50 6–20 µs on cloud (w2–w4). Lower throughput on cloud, similar p50 range.
- **pc_spin_if4 against pc_spin** (5/95, macOS w10): 12.8 against 7.5 (1.7×). Cloud w4: 1.39× (uniform) and 1.83× (zipf). Same direction.

## Every configuration

All values are the median [min..max] over the 7 reps of the kept try. *tries* is kept try/3. *spread* is for the gate metric. In the extension tables, (sp) is the spread of that latency metric. Latency is in µs. Throughput-mode rows have no latency columns, because there latency is queueing from t=0.

### Extension

From `results/cloud/measure-20261030-063328.txt` (40 configurations).

| config | gate | gate median [min..max] | spread | NOISY | tries | achieved Mreq/s | light p50 µs (sp) | light p99 µs (sp) | light p999 µs (sp) | heavy p50 µs | heavy p99 µs | all p99 µs | all p999 µs | sustained | load1 start→end | steal ticks |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| x_even_thr_ws | mops | 0.774 [0.678..0.797] | 0.154 | NOISY | 3/3 | 0.774 | – | – | – | – | – | – | – | (thr mode) | 2.48→2.59 | 64 |
| x_even_thr_pc | mops | 2.382 [2.053..2.542] | 0.205 | NOISY | 2/3 | 2.382 | – | – | – | – | – | – | – | (thr mode) | 2.71→2.81 | 23 |
| x_even_thr_pas_3p1 | mops | 0.674 [0.653..0.694] | 0.061 |  | 2/3 | 0.674 | – | – | – | – | – | – | – | (thr mode) | 2.72→2.78 | 46 |
| x_even_thr_pas_2p2 | mops | 0.664 [0.655..0.715] | 0.090 |  | 2/3 | 0.664 | – | – | – | – | – | – | – | (thr mode) | 2.75→2.94 | 68 |
| x_even_thr_pas_4p4 | mops | 0.600 [0.570..0.626] | 0.093 |  | 3/3 | 0.600 | – | – | – | – | – | – | – | (thr mode) | 3.70→4.06 | 64 |
| x_skewed_thr_ws | mops | 0.340 [0.332..0.366] | 0.100 |  | 1/3 | 0.340 | – | – | – | – | – | – | – | (thr mode) | 4.38→4.32 | 44 |
| x_skewed_thr_pc | mops | 0.201 [0.199..0.214] | 0.075 |  | 1/3 | 0.201 | – | – | – | – | – | – | – | (thr mode) | 4.13→4.25 | 74 |
| x_skewed_thr_pas_3p1 | mops | 0.098 [0.097..0.101] | 0.041 |  | 1/3 | 0.098 | – | – | – | – | – | – | – | (thr mode) | 4.20→3.90 | 146 |
| x_skewed_thr_pas_2p2 | mops | 0.193 [0.188..0.198] | 0.052 |  | 1/3 | 0.193 | – | – | – | – | – | – | – | (thr mode) | 3.67→3.51 | 98 |
| x_skewed_thr_pas_4p4 | mops | 0.275 [0.266..0.308] | 0.153 | NOISY | 1/3 | 0.275 | – | – | – | – | – | – | – | (thr mode) | 3.82→4.44 | 75 |
| x_even_lat25_ws | light p99 | 58.4 [34.8..458.8] | 7.263 | NOISY | 1/3 | 0.193 | 2.4 (0.08) | 58.4 (7.26) | 1933.3 (1.13) | – | – | 58.4 | 1933.3 | yes | 4.68→4.16 | 182 |
| x_even_lat25_pc | light p99 | 1835.0 [1278.0..3145.7] | 1.018 | NOISY | 2/3 | 0.193 | 2.2 (0.12) | 1835.0 (1.02) | 5636.1 (3.45) | – | – | 1835.0 | 5636.1 | yes | 3.25→3.62 | 192 |
| x_even_lat25_pas_3p1 | light p99 | 278.5 [59.4..589.8] | 1.904 | NOISY | 3/3 | 0.193 | 2.7 (0.10) | 278.5 (1.90) | 2818.0 (1.78) | – | – | 278.5 | 2818.0 | yes | 3.19→3.55 | 214 |
| x_even_lat25_pas_2p2 | light p99 | 753.7 [167.9..1900.5] | 2.299 | NOISY | 3/3 | 0.193 | 2.7 (0.12) | 753.7 (2.30) | 7602.2 (1.47) | – | – | 753.7 | 7602.2 | yes | 3.67→3.77 | 212 |
| x_even_lat25_pas_4p4 | light p99 | 516.1 [237.6..819.2] | 1.127 | NOISY | 2/3 | 0.193 | 2.6 (0.10) | 516.1 (1.13) | 2752.5 (0.87) | – | – | 516.1 | 2752.5 | yes | 4.97→5.97 | 201 |
| x_even_lat50_ws | light p99 | 1048.6 [344.1..3276.8] | 2.797 | NOISY | 1/3 | 0.386 | 2.4 (0.11) | 1048.6 (2.80) | 4587.5 (1.10) | – | – | 1048.6 | 4587.5 | yes | 5.94→5.17 | 101 |
| x_even_lat50_pc | light p99 | 2359.3 [1376.3..4718.6] | 1.417 | NOISY | 3/3 | 0.386 | 2.0 (0.08) | 2359.3 (1.42) | 4849.7 (1.74) | – | – | 2359.3 | 4849.7 | yes | 3.49→3.43 | 118 |
| x_even_lat50_pas_3p1 | light p99 | 1605.6 [622.6..3276.8] | 1.653 | NOISY | 3/3 | 0.386 | 2.8 (0.19) | 1605.6 (1.65) | 5111.8 (1.24) | – | – | 1605.6 | 5111.8 | yes | 2.74→3.03 | 90 |
| x_even_lat50_pas_2p2 | light p99 | 1376.3 [868.4..3211.3] | 1.702 | NOISY | 2/3 | 0.386 | 3.8 (0.29) | 1376.3 (1.70) | 3473.4 (0.89) | – | – | 1376.3 | 3473.4 | yes | 2.89→2.98 | 80 |
| x_even_lat50_pas_4p4 | light p99 | 2818.0 [1507.3..4718.6] | 1.140 | NOISY | 1/3 | 0.386 | 3.0 (0.15) | 2818.0 (1.14) | 6684.7 (2.13) | – | – | 2818.0 | 6684.7 | yes | 2.78→3.95 | 104 |
| x_even_lat75_ws | light p99 | 7340.0 [1605.6..20972] | 2.638 | NOISY | 1/3 | 0.578 | 5.5 (2.40) | 7340.0 (2.64) | 8388.6 (2.55) | – | – | 7340.0 | 8388.6 | yes | 5.19→4.70 | 66 |
| x_even_lat75_pc | light p99 | 2818.0 [786.4..15729] | 5.302 | NOISY | 1/3 | 0.578 | 2.0 (0.17) | 2818.0 (5.30) | 6553.6 (3.74) | – | – | 2818.0 | 6553.6 | yes | 3.50→3.58 | 82 |
| x_even_lat75_pas_3p1 | light p99 | 12845 [1900.5..42992] | 3.199 | NOISY | 3/3 | 0.578 | 6.1 (0.98) | 12845 (3.20) | 16515 (2.77) | – | – | 12845 | 16515 | yes | 3.18→3.16 | 60 |
| x_even_lat75_pas_2p2 | light p99 | 39846 [13107..75497] | 1.566 | NOISY | 3/3 | 0.576 | 39.9 (68.58) | 39846 (1.57) | 41943 (1.56) | – | – | 39846 | 41943 | NO | 2.84→3.03 | 74 |
| x_even_lat75_pas_4p4 | light p99 | 142606 [36700..276824] | 1.684 | NOISY | 1/3 | 0.556 | 27787 (4.83) | 142606 (1.68) | 142606 (1.70) | – | – | 142606 | 142606 | NO | 2.79→3.38 | 73 |
| x_skewed_lat25_ws | light p99 | 44.0 [39.9..49.2] | 0.209 | NOISY | 1/3 | 0.085 | 1.0 (0.06) | 44.0 (0.21) | 786.4 (1.43) | 196.6 | 303.1 | 213.0 | 852.0 | yes | 3.90→2.48 | 153 |
| x_skewed_lat25_pc | light p99 | 4128.8 [1212.4..6553.6] | 1.294 | NOISY | 1/3 | 0.085 | 2.1 (0.58) | 4128.8 (1.29) | 11796 (1.30) | 204.8 | 4063.2 | 4128.8 | 11796 | yes | 3.11→3.51 | 191 |
| x_skewed_lat25_pas_3p1 | light p99 | 19.5 [16.9..21.0] | 0.211 | NOISY | 2/3 | 0.085 | 1.2 (0.05) | 19.5 (0.21) | 409.6 (23.58) | 671.7 | 9175.0 | 1736.7 | 7340.0 | yes | 3.62→3.79 | 178 |
| x_skewed_lat25_pas_2p2 | light p99 | 20.0 [17.4..25.1] | 0.385 | NOISY | 1/3 | 0.085 | 1.0 (0.11) | 20.0 (0.38) | 802.8 (9.10) | 200.7 | 753.7 | 270.3 | 1343.5 | yes | 3.92→3.91 | 228 |
| x_skewed_lat25_pas_4p4 | light p99 | 25.1 [18.9..33.8] | 0.592 | NOISY | 1/3 | 0.085 | 1.2 (0.14) | 25.1 (0.59) | 1179.6 (2.12) | 217.1 | 2162.7 | 385.0 | 1933.3 | yes | 3.71→5.61 | 200 |
| x_skewed_lat50_ws | light p99 | 200.7 [163.8..237.6] | 0.367 | NOISY | 1/3 | 0.169 | 1.1 (0.20) | 200.7 (0.37) | 2621.4 (1.14) | 196.6 | 491.5 | 278.5 | 2687.0 | yes | 6.24→5.38 | 91 |
| x_skewed_lat50_pc | light p99 | 12321 [5505.0..23593] | 1.468 | NOISY | 2/3 | 0.169 | 213.0 (0.23) | 12321 (1.47) | 15204 (1.22) | 401.4 | 12321 | 12321 | 15204 | yes | 3.87→3.67 | 102 |
| x_skewed_lat50_pas_3p1 | light p99 | 26.6 [22.0..30.7] | 0.327 | NOISY | 2/3 | 0.098 | 1.2 (0.05) | 26.6 (0.33) | 1605.6 (2.56) | 872415 | 1677722 | 1375732 | 1677722 | NO | 3.40→3.48 | 155 |
| x_skewed_lat50_pas_2p2 | light p99 | 32.8 [23.0..51.2] | 0.859 | NOISY | 1/3 | 0.169 | 1.0 (0.09) | 32.8 (0.86) | 1474.6 (0.98) | 426.0 | 7209.0 | 1179.6 | 6160.4 | yes | 3.82→3.65 | 99 |
| x_skewed_lat50_pas_4p4 | light p99 | 483.3 [213.0..770.0] | 1.153 | NOISY | 3/3 | 0.169 | 1.2 (0.11) | 483.3 (1.15) | 3342.3 (0.55) | 450.6 | 6815.7 | 2359.3 | 5898.2 | yes | 4.83→5.65 | 77 |
| x_skewed_lat75_ws | light p99 | 1081.3 [720.9..3735.6] | 2.788 | NOISY | 3/3 | 0.254 | 4.7 (0.51) | 1081.3 (2.79) | 3080.2 (2.05) | 213.0 | 1310.7 | 1081.3 | 3080.2 | yes | 5.28→4.80 | 71 |
| x_skewed_lat75_pc | light p99 | 411042 [360710..469762] | 0.265 | NOISY | 1/3 | 0.202 | 184549 (0.30) | 411042 (0.27) | 419430 (0.28) | 184549 | 411042 | 411042 | 419430 | NO | 4.75→4.59 | 82 |
| x_skewed_lat75_pas_3p1 | light p99 | 30.7 [26.1..94.2] | 2.217 | NOISY | 3/3 | 0.098 | 1.2 (0.11) | 30.7 (2.22) | 319.5 (6.65) | 1241514 | 2415919 | 1979711 | 2415919 | NO | 3.59→3.82 | 120 |
| x_skewed_lat75_pas_2p2 | light p99 | 33.8 [29.7..122.9] | 2.758 | NOISY | 3/3 | 0.197 | 1.1 (0.12) | 33.8 (2.76) | 933.9 (3.13) | 226492 | 444596 | 360710 | 444596 | NO | 3.17→3.44 | 81 |
| x_skewed_lat75_pas_4p4 | light p99 | 3735.6 [2293.8..4718.6] | 0.649 | NOISY | 3/3 | 0.224 | 1.2 (0.32) | 3735.6 (0.65) | 7209.0 (0.67) | 150995 | 394265 | 255853 | 385876 | NO | 4.30→5.12 | 90 |

From `results/cloud/measure-20261030-080128.txt` (6 configurations).

| config | gate | gate median [min..max] | spread | NOISY | tries | achieved Mreq/s | light p50 µs (sp) | light p99 µs (sp) | light p999 µs (sp) | heavy p50 µs | heavy p99 µs | all p99 µs | all p999 µs | sustained | load1 start→end | steal ticks |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| x_skewed_lat25_ws_long | light p99 | 53.2 [49.2..62.5] | 0.250 | NOISY | 2/3 | 0.085 | 1.2 (0.05) | 53.2 (0.25) | 1409.0 (2.63) | 192.5 | 319.5 | 208.9 | 1441.8 | yes | 3.76→3.98 | 681 |
| x_skewed_lat25_pas_3p1_long | light p99 | 20.5 [18.4..22.5] | 0.200 | NOISY | 2/3 | 0.085 | 1.3 (0.10) | 20.5 (0.20) | 483.3 (13.04) | 483.3 | 9175.0 | 1179.6 | 5898.2 | yes | 3.66→3.97 | 629 |
| x_skewed_lat25_pas_2p2_long | light p99 | 24.6 [22.5..26.1] | 0.146 | NOISY | 2/3 | 0.085 | 1.2 (0.05) | 24.6 (0.15) | 753.7 (0.97) | 196.6 | 622.6 | 254.0 | 966.7 | yes | 3.90→3.99 | 682 |
| x_skewed_lat50_ws_long | light p99 | 184.3 [159.7..233.5] | 0.400 | NOISY | 3/3 | 0.170 | 1.2 (0.24) | 184.3 (0.40) | 2162.7 (2.45) | 192.5 | 450.6 | 249.9 | 2293.8 | yes | 3.92→3.98 | 336 |
| x_skewed_lat50_pas_3p1_long | light p99 | 25.6 [22.0..30.2] | 0.320 | NOISY | 3/3 | 0.102 | 1.3 (0.07) | 25.6 (0.32) | 589.8 (4.60) | 3019899 | 6174015 | 4966056 | 6039798 | NO | 3.78→3.97 | 400 |
| x_skewed_lat50_pas_2p2_long | light p99 | 28.2 [21.0..39.9] | 0.673 | NOISY | 1/3 | 0.170 | 1.1 (0.09) | 28.2 (0.67) | 884.7 (2.64) | 335.9 | 3276.8 | 671.7 | 1998.8 | yes | 3.81→3.04 | 268 |

### Oversubscription check

From `results/cloud/measure-20261030-073608.txt` (25 configurations).

| config | Mops/s median [min..max] | spread | NOISY | tries | p50 µs | p99 µs | cpu/wall | load1 start→end | steal ticks |
|---|---|---|---|---|---|---|---|---|---|
| o_ws_one_g50_uniform_w3_pinauto | 0.237 [0.218..0.274] | 0.236 | NOISY | 2/3 | 2.9 | 159.7 | 1.50 | 2.23→2.16 | 64 |
| o_ws_one_g50_uniform_w4_pinoff | 0.251 [0.237..0.265] | 0.112 | NOISY | 2/3 | 3.8 | 172.0 | 2.02 | 2.32→2.38 | 73 |
| o_ws_one_g50_uniform_w5_pinauto | 0.300 [0.282..0.317] | 0.117 | NOISY | 2/3 | 3.1 | 180.2 | 2.26 | 2.30→2.56 | 96 |
| o_ws_one_g50_uniform_w6_pinauto | 0.311 [0.292..0.316] | 0.077 |  | 1/3 | 3.2 | 204.8 | 2.39 | 2.70→3.54 | 122 |
| o_ws_one_g50_uniform_w8_pinon | 0.386 [0.346..0.403] | 0.148 | NOISY | 3/3 | 2.0 | 204.8 | 2.16 | 3.47→3.40 | 108 |
| o_ws_sharded_g50_uniform_w3_pinauto | 0.608 [0.557..0.629] | 0.118 | NOISY | 2/3 | 1.9 | 42.0 | 2.07 | 3.22→3.20 | 19 |
| o_ws_sharded_g50_uniform_w4_pinoff | 0.747 [0.683..0.806] | 0.165 | NOISY | 3/3 | 2.0 | 45.1 | 2.68 | 3.58→3.65 | 24 |
| o_ws_sharded_g50_uniform_w5_pinauto | 0.916 [0.849..0.954] | 0.115 | NOISY | 1/3 | 1.7 | 65.5 | 2.89 | 3.59→3.52 | 33 |
| o_ws_sharded_g50_uniform_w6_pinauto | 0.895 [0.815..0.950] | 0.151 | NOISY | 2/3 | 1.8 | 90.1 | 3.01 | 3.35→3.54 | 41 |
| o_ws_sharded_g50_uniform_w8_pinon | 1.184 [1.170..1.294] | 0.105 | NOISY | 3/3 | 1.4 | 108.5 | 3.20 | 4.17→4.76 | 47 |
| o_pc_spin_g50_uniform_w3_pinauto | 1.095 [1.056..1.268] | 0.194 | NOISY | 1/3 | 1.7 | 6.8 | 2.83 | 4.62→4.41 | 19 |
| o_pc_spin_g50_uniform_w4_pinoff | 1.439 [1.322..1.642] | 0.222 | NOISY | 3/3 | 1.8 | 8.7 | 3.69 | 3.81→3.82 | 19 |
| o_pc_spin_g50_uniform_w5_pinauto | 0.233 [0.219..0.238] | 0.082 |  | 1/3 | 3.3 | 143.4 | 2.80 | 3.68→4.02 | 114 |
| o_pc_spin_g50_uniform_w6_pinauto | 0.211 [0.200..0.217] | 0.081 |  | 1/3 | 4.4 | 147.5 | 3.04 | 3.94→4.53 | 175 |
| o_pc_spin_g50_uniform_w8_pinon | 0.227 [0.209..0.230] | 0.093 |  | 2/3 | 14.1 | 159.7 | 3.57 | 5.23→6.26 | 254 |
| o_pc_park_g50_uniform_w3_pinauto | 0.139 [0.133..0.141] | 0.058 |  | 3/3 | 17.9 | 49.2 | 1.25 | 2.78→2.47 | 103 |
| o_pc_park_g50_uniform_w4_pinoff | 0.158 [0.152..0.167] | 0.095 |  | 1/3 | 20.5 | 59.4 | 1.70 | 2.59→2.44 | 115 |
| o_pc_park_g50_uniform_w5_pinauto | 0.166 [0.155..0.170] | 0.090 |  | 1/3 | 22.5 | 88.1 | 1.90 | 2.57→2.81 | 163 |
| o_pc_park_g50_uniform_w6_pinauto | 0.177 [0.170..0.181] | 0.062 |  | 1/3 | 25.1 | 102.4 | 2.13 | 2.90→3.80 | 193 |
| o_pc_park_g50_uniform_w8_pinon | 0.214 [0.203..0.223] | 0.093 |  | 1/3 | 27.1 | 114.7 | 2.59 | 3.74→5.04 | 201 |
| o_pc_spin_if4_g50_uniform_w3_pinauto | 1.662 [1.430..1.915] | 0.292 | NOISY | 1/3 | 2.9 | 16.9 | 2.84 | 5.20→5.02 | 15 |
| o_pc_spin_if4_g50_uniform_w4_pinoff | 2.393 [2.083..2.589] | 0.211 | NOISY | 2/3 | 2.9 | 18.9 | 3.77 | 4.10→4.10 | 13 |
| o_pc_spin_if4_g50_uniform_w5_pinauto | 0.589 [0.559..0.611] | 0.088 |  | 1/3 | 3.5 | 225.3 | 3.12 | 3.73→3.87 | 56 |
| o_pc_spin_if4_g50_uniform_w6_pinauto | 0.534 [0.514..0.572] | 0.109 | NOISY | 3/3 | 4.4 | 213.0 | 3.27 | 3.83→4.08 | 82 |
| o_pc_spin_if4_g50_uniform_w8_pinon | 0.432 [0.391..0.452] | 0.141 | NOISY | 1/3 | 23.0 | 335.9 | 3.37 | 4.00→4.30 | 139 |

### Original matrix (closed loop, 200k ops per worker, 1M keys)

From `results/cloud/measure-20261030-083705.txt` (48 configurations).

| config | Mops/s median [min..max] | spread | NOISY | tries | p50 µs | p99 µs | cpu/wall | load1 start→end | steal ticks |
|---|---|---|---|---|---|---|---|---|---|
| b_ws_one_g95_uniform_w1 | 0.955 [0.864..0.996] | 0.138 | NOISY | 1/3 | 0.9 | 2.5 | 1.00 | 3.32→3.14 | 4 |
| b_ws_worker_g95_uniform_w1 | 0.918 [0.854..0.993] | 0.151 | NOISY | 3/3 | 0.9 | 2.7 | 1.00 | 2.78→2.64 | 9 |
| b_ws_keyed_g95_uniform_w1 | 0.809 [0.742..0.898] | 0.193 | NOISY | 2/3 | 1.0 | 3.1 | 0.99 | 2.51→2.39 | 9 |
| b_ws_sharded_g95_uniform_w1 | 0.853 [0.837..0.986] | 0.175 | NOISY | 1/3 | 0.9 | 3.2 | 1.00 | 2.53→2.53 | 5 |
| b_ws_one_g95_uniform_w2 | 0.237 [0.229..0.256] | 0.114 | NOISY | 1/3 | 2.0 | 112.6 | 1.20 | 2.96→2.68 | 37 |
| b_ws_worker_g95_uniform_w2 | 0.314 [0.269..0.342] | 0.232 | NOISY | 1/3 | 3.2 | 45.1 | 1.50 | 2.62→2.45 | 28 |
| b_ws_keyed_g95_uniform_w2 | 1.383 [1.223..1.482] | 0.187 | NOISY | 3/3 | 1.0 | 10.8 | 1.84 | 2.09→2.00 | 10 |
| b_ws_sharded_g95_uniform_w2 | 0.413 [0.381..0.446] | 0.157 | NOISY | 2/3 | 1.7 | 41.0 | 1.37 | 2.18→2.09 | 25 |
| b_ws_one_g95_uniform_w4 | 0.321 [0.301..0.351] | 0.156 | NOISY | 1/3 | 2.4 | 135.2 | 2.09 | 2.27→2.48 | 100 |
| b_ws_worker_g95_uniform_w4 | 0.311 [0.276..0.328] | 0.167 | NOISY | 1/3 | 6.5 | 69.6 | 2.85 | 2.79→2.78 | 122 |
| b_ws_keyed_g95_uniform_w4 | 1.978 [1.611..2.124] | 0.259 | NOISY | 3/3 | 1.2 | 16.9 | 3.24 | 2.71→2.81 | 25 |
| b_ws_sharded_g95_uniform_w4 | 1.022 [0.983..1.127] | 0.141 | NOISY | 3/3 | 1.4 | 35.8 | 2.75 | 2.99→3.15 | 28 |
| b_ws_one_g95_uniform_w8 | 0.401 [0.368..0.430] | 0.155 | NOISY | 1/3 | 2.2 | 213.0 | 2.85 | 2.74→3.31 | 154 |
| b_ws_worker_g95_uniform_w8 | 0.222 [0.214..0.234] | 0.090 |  | 3/3 | 10.5 | 376.8 | 3.05 | 5.84→5.67 | 313 |
| b_ws_keyed_g95_uniform_w8 | 1.761 [1.561..1.846] | 0.162 | NOISY | 3/3 | 1.2 | 88.1 | 3.28 | 4.86→5.03 | 45 |
| b_ws_sharded_g95_uniform_w8 | 1.330 [1.206..1.457] | 0.189 | NOISY | 2/3 | 1.3 | 106.5 | 3.26 | 4.29→4.46 | 53 |
| b_ws_one_g50_uniform_w1 | 0.845 [0.740..0.868] | 0.151 | NOISY | 3/3 | 1.0 | 3.5 | 1.00 | 3.58→3.58 | 4 |
| b_ws_worker_g50_uniform_w1 | 0.780 [0.700..0.806] | 0.136 | NOISY | 2/3 | 1.0 | 4.1 | 0.99 | 3.14→3.14 | 14 |
| b_ws_keyed_g50_uniform_w1 | 0.698 [0.646..0.786] | 0.201 | NOISY | 1/3 | 1.1 | 4.4 | 1.00 | 2.75→2.61 | 8 |
| b_ws_sharded_g50_uniform_w1 | 0.743 [0.710..0.757] | 0.063 |  | 1/3 | 1.1 | 4.4 | 0.99 | 2.27→2.17 | 7 |
| b_ws_one_g50_uniform_w2 | 0.197 [0.194..0.216] | 0.112 | NOISY | 3/3 | 2.5 | 131.1 | 1.19 | 2.22→2.10 | 51 |
| b_ws_worker_g50_uniform_w2 | 0.253 [0.238..0.281] | 0.170 | NOISY | 3/3 | 3.1 | 56.3 | 1.36 | 1.88→1.83 | 48 |
| b_ws_keyed_g50_uniform_w2 | 1.065 [0.957..1.116] | 0.149 | NOISY | 2/3 | 1.3 | 16.1 | 1.80 | 2.01→1.93 | 12 |
| b_ws_sharded_g50_uniform_w2 | 0.329 [0.311..0.355] | 0.134 | NOISY | 3/3 | 2.1 | 49.2 | 1.34 | 1.96→1.96 | 29 |
| b_ws_one_g50_uniform_w4 | 0.254 [0.248..0.266] | 0.071 |  | 1/3 | 3.5 | 176.1 | 1.99 | 1.89→2.15 | 105 |
| b_ws_worker_g50_uniform_w4 | 0.320 [0.309..0.336] | 0.084 |  | 2/3 | 6.3 | 71.7 | 2.67 | 2.51→2.51 | 106 |
| b_ws_keyed_g50_uniform_w4 | 1.643 [1.455..1.664] | 0.127 | NOISY | 1/3 | 1.4 | 20.5 | 3.18 | 2.19→2.34 | 20 |
| b_ws_sharded_g50_uniform_w4 | 0.811 [0.741..0.855] | 0.141 | NOISY | 1/3 | 1.8 | 42.0 | 2.69 | 2.55→2.43 | 35 |
| b_ws_one_g50_uniform_w8 | 0.341 [0.302..0.361] | 0.173 | NOISY | 2/3 | 2.7 | 245.8 | 2.64 | 3.99→4.06 | 206 |
| b_ws_worker_g50_uniform_w8 | 0.216 [0.201..0.226] | 0.116 | NOISY | 1/3 | 11.5 | 303.1 | 3.24 | 4.05→4.73 | 307 |
| b_ws_keyed_g50_uniform_w8 | 1.287 [1.228..1.330] | 0.079 |  | 3/3 | 1.5 | 116.7 | 3.18 | 2.89→2.83 | 65 |
| b_ws_sharded_g50_uniform_w8 | 1.003 [0.936..1.028] | 0.092 |  | 1/3 | 1.7 | 124.9 | 3.28 | 2.82→3.54 | 62 |
| b_ws_one_g5_uniform_w1 | 0.752 [0.556..0.779] | 0.297 | NOISY | 3/3 | 1.1 | 4.1 | 0.98 | 2.91→2.76 | 7 |
| b_ws_worker_g5_uniform_w1 | 0.664 [0.573..0.710] | 0.206 | NOISY | 1/3 | 1.2 | 4.7 | 0.99 | 2.54→2.41 | 11 |
| b_ws_keyed_g5_uniform_w1 | 0.587 [0.539..0.728] | 0.322 | NOISY | 2/3 | 1.3 | 5.5 | 1.00 | 2.54→2.42 | 12 |
| b_ws_sharded_g5_uniform_w1 | 0.599 [0.530..0.620] | 0.150 | NOISY | 1/3 | 1.4 | 5.4 | 1.00 | 2.58→2.45 | 9 |
| b_ws_one_g5_uniform_w2 | 0.177 [0.164..0.185] | 0.119 | NOISY | 3/3 | 2.9 | 155.6 | 1.19 | 2.86→2.45 | 48 |
| b_ws_worker_g5_uniform_w2 | 0.511 [0.488..0.529] | 0.080 |  | 2/3 | 1.7 | 32.8 | 1.49 | 2.91→2.69 | 23 |
| b_ws_keyed_g5_uniform_w2 | 0.747 [0.728..0.820] | 0.123 | NOISY | 2/3 | 1.8 | 18.4 | 1.72 | 2.31→2.28 | 14 |
| b_ws_sharded_g5_uniform_w2 | 0.283 [0.266..0.296] | 0.106 | NOISY | 1/3 | 2.6 | 53.2 | 1.34 | 2.05→1.89 | 28 |
| b_ws_one_g5_uniform_w4 | 0.225 [0.212..0.242] | 0.133 | NOISY | 1/3 | 5.6 | 208.9 | 1.93 | 2.08→2.17 | 97 |
| b_ws_worker_g5_uniform_w4 | 0.838 [0.784..0.886] | 0.122 | NOISY | 1/3 | 1.5 | 48.1 | 2.74 | 2.88→2.46 | 31 |
| b_ws_keyed_g5_uniform_w4 | 1.212 [1.140..1.301] | 0.133 | NOISY | 1/3 | 1.8 | 29.7 | 3.04 | 1.90→1.83 | 30 |
| b_ws_sharded_g5_uniform_w4 | 0.655 [0.625..0.678] | 0.081 |  | 3/3 | 2.1 | 49.2 | 2.61 | 2.37→2.54 | 43 |
| b_ws_one_g5_uniform_w8 | 0.304 [0.290..0.313] | 0.076 |  | 3/3 | 3.1 | 278.5 | 2.44 | 4.69→4.53 | 163 |
| b_ws_worker_g5_uniform_w8 | 0.650 [0.610..0.695] | 0.131 | NOISY | 1/3 | 2.0 | 204.8 | 3.31 | 4.32→4.18 | 100 |
| b_ws_keyed_g5_uniform_w8 | 1.219 [1.198..1.343] | 0.119 | NOISY | 1/3 | 1.7 | 118.8 | 3.25 | 3.84→3.40 | 46 |
| b_ws_sharded_g5_uniform_w8 | 1.057 [0.986..1.158] | 0.163 | NOISY | 3/3 | 1.7 | 120.8 | 3.32 | 4.24→4.03 | 59 |

From `results/cloud/measure-20261030-093149.txt` (48 configurations).

| config | Mops/s median [min..max] | spread | NOISY | tries | p50 µs | p99 µs | cpu/wall | load1 start→end | steal ticks |
|---|---|---|---|---|---|---|---|---|---|
| b_pc_spin_g95_uniform_w1 | 0.853 [0.755..0.972] | 0.254 | NOISY | 1/3 | 0.9 | 2.8 | 1.00 | 3.19→3.19 | 3 |
| b_pc_park_g95_uniform_w1 | 0.839 [0.753..0.878] | 0.149 | NOISY | 2/3 | 0.9 | 2.9 | 1.00 | 2.37→2.26 | 5 |
| b_pc_spin_if4_g95_uniform_w1 | 0.883 [0.832..1.009] | 0.200 | NOISY | 1/3 | 0.9 | 2.8 | 1.01 | 2.43→2.43 | 4 |
| b_pc_park_if4_g95_uniform_w1 | 0.921 [0.631..0.974] | 0.372 | NOISY | 3/3 | 0.9 | 2.7 | 1.00 | 2.36→2.26 | 3 |
| b_pc_spin_g95_uniform_w2 | 0.742 [0.674..0.819] | 0.195 | NOISY | 2/3 | 1.7 | 5.9 | 1.95 | 2.24→2.22 | 11 |
| b_pc_park_g95_uniform_w2 | 0.127 [0.124..0.135] | 0.087 |  | 2/3 | 5.8 | 34.8 | 0.96 | 1.88→1.73 | 56 |
| b_pc_spin_if4_g95_uniform_w2 | 1.197 [1.123..1.385] | 0.219 | NOISY | 3/3 | 2.0 | 12.3 | 1.92 | 2.29→2.27 | 13 |
| b_pc_park_if4_g95_uniform_w2 | 0.606 [0.506..0.659] | 0.252 | NOISY | 3/3 | 2.6 | 35.8 | 1.43 | 2.50→2.46 | 15 |
| b_pc_spin_g95_uniform_w4 | 1.719 [1.569..1.764] | 0.113 | NOISY | 2/3 | 1.6 | 6.8 | 3.69 | 2.79→2.89 | 16 |
| b_pc_park_g95_uniform_w4 | 0.166 [0.158..0.172] | 0.084 |  | 1/3 | 19.5 | 55.3 | 1.67 | 2.82→2.57 | 113 |
| b_pc_spin_if4_g95_uniform_w4 | 2.506 [2.358..2.624] | 0.106 | NOISY | 2/3 | 2.8 | 16.1 | 3.72 | 2.97→3.05 | 15 |
| b_pc_park_if4_g95_uniform_w4 | 0.665 [0.652..0.701] | 0.074 |  | 3/3 | 16.1 | 53.2 | 2.31 | 2.99→2.91 | 35 |
| b_pc_spin_g95_uniform_w8 | 0.223 [0.213..0.239] | 0.117 | NOISY | 3/3 | 14.6 | 163.8 | 3.59 | 5.53→6.47 | 222 |
| b_pc_park_g95_uniform_w8 | 0.211 [0.202..0.215] | 0.062 |  | 2/3 | 28.2 | 116.7 | 2.61 | 5.18→5.05 | 175 |
| b_pc_spin_if4_g95_uniform_w8 | 0.509 [0.496..0.546] | 0.098 |  | 1/3 | 21.5 | 303.1 | 3.60 | 4.89→5.62 | 96 |
| b_pc_park_if4_g95_uniform_w8 | 0.579 [0.560..0.598] | 0.066 |  | 2/3 | 31.7 | 151.6 | 3.21 | 4.78→5.76 | 85 |
| b_pc_spin_g50_uniform_w1 | 0.759 [0.658..0.773] | 0.152 | NOISY | 2/3 | 1.1 | 3.3 | 1.00 | 4.70→4.40 | 7 |
| b_pc_park_g50_uniform_w1 | 0.772 [0.716..0.812] | 0.124 | NOISY | 3/3 | 1.0 | 3.1 | 1.00 | 3.29→3.11 | 9 |
| b_pc_spin_if4_g50_uniform_w1 | 0.707 [0.637..0.786] | 0.211 | NOISY | 3/3 | 1.1 | 4.2 | 1.00 | 2.95→2.80 | 11 |
| b_pc_park_if4_g50_uniform_w1 | 0.758 [0.690..0.806] | 0.153 | NOISY | 3/3 | 1.1 | 3.5 | 0.99 | 2.32→2.32 | 7 |
| b_pc_spin_g50_uniform_w2 | 0.691 [0.622..0.725] | 0.149 | NOISY | 1/3 | 1.8 | 6.3 | 1.95 | 2.27→2.25 | 13 |
| b_pc_park_g50_uniform_w2 | 0.125 [0.119..0.129] | 0.080 |  | 1/3 | 6.4 | 36.9 | 0.98 | 1.94→1.76 | 53 |
| b_pc_spin_if4_g50_uniform_w2 | 1.150 [1.016..1.196] | 0.157 | NOISY | 2/3 | 2.2 | 13.6 | 1.91 | 1.67→1.70 | 15 |
| b_pc_park_if4_g50_uniform_w2 | 0.554 [0.503..0.609] | 0.191 | NOISY | 3/3 | 2.8 | 34.8 | 1.41 | 1.63→1.74 | 23 |
| b_pc_spin_g50_uniform_w4 | 1.530 [1.343..1.606] | 0.172 | NOISY | 3/3 | 1.8 | 7.3 | 3.66 | 1.77→1.71 | 25 |
| b_pc_park_g50_uniform_w4 | 0.157 [0.151..0.160] | 0.057 |  | 1/3 | 20.5 | 59.4 | 1.66 | 1.61→2.13 | 172 |
| b_pc_spin_if4_g50_uniform_w4 | 2.272 [1.914..2.510] | 0.262 | NOISY | 1/3 | 3.0 | 17.9 | 3.69 | 2.28→2.17 | 19 |
| b_pc_park_if4_g50_uniform_w4 | 0.686 [0.630..0.717] | 0.127 | NOISY | 3/3 | 15.6 | 50.2 | 2.35 | 2.22→2.34 | 35 |
| b_pc_spin_g50_uniform_w8 | 0.213 [0.206..0.222] | 0.075 |  | 2/3 | 15.1 | 172.0 | 3.59 | 5.24→6.49 | 264 |
| b_pc_park_g50_uniform_w8 | 0.202 [0.197..0.210] | 0.064 |  | 1/3 | 28.7 | 120.8 | 2.58 | 6.13→5.78 | 226 |
| b_pc_spin_if4_g50_uniform_w8 | 0.481 [0.465..0.492] | 0.056 |  | 2/3 | 23.0 | 311.3 | 3.53 | 5.99→6.08 | 161 |
| b_pc_park_if4_g50_uniform_w8 | 0.539 [0.525..0.565] | 0.074 |  | 1/3 | 32.3 | 176.1 | 3.19 | 5.91→5.95 | 106 |
| b_pc_spin_g5_uniform_w1 | 0.726 [0.621..0.790] | 0.233 | NOISY | 1/3 | 1.1 | 3.8 | 1.00 | 5.79→5.41 | 7 |
| b_pc_park_g5_uniform_w1 | 0.738 [0.693..0.844] | 0.205 | NOISY | 2/3 | 1.1 | 3.6 | 0.98 | 3.55→3.35 | 12 |
| b_pc_spin_if4_g5_uniform_w1 | 0.736 [0.643..0.850] | 0.281 | NOISY | 3/3 | 1.1 | 3.9 | 1.00 | 2.91→2.76 | 7 |
| b_pc_park_if4_g5_uniform_w1 | 0.744 [0.736..0.808] | 0.097 |  | 3/3 | 1.1 | 3.6 | 0.98 | 2.37→2.26 | 10 |
| b_pc_spin_g5_uniform_w2 | 0.603 [0.560..0.658] | 0.163 | NOISY | 1/3 | 2.0 | 7.8 | 1.94 | 2.26→2.22 | 20 |
| b_pc_park_g5_uniform_w2 | 0.119 [0.117..0.127] | 0.084 |  | 1/3 | 7.4 | 36.9 | 0.99 | 2.08→1.93 | 50 |
| b_pc_spin_if4_g5_uniform_w2 | 1.087 [0.916..1.144] | 0.210 | NOISY | 3/3 | 2.4 | 14.1 | 1.93 | 2.03→2.03 | 15 |
| b_pc_park_if4_g5_uniform_w2 | 0.526 [0.499..0.569] | 0.133 | NOISY | 2/3 | 3.1 | 39.9 | 1.44 | 1.87→1.89 | 21 |
| b_pc_spin_g5_uniform_w4 | 1.375 [1.293..1.515] | 0.161 | NOISY | 3/3 | 1.9 | 9.5 | 3.75 | 2.29→2.18 | 16 |
| b_pc_park_g5_uniform_w4 | 0.151 [0.142..0.155] | 0.086 |  | 2/3 | 21.5 | 61.4 | 1.68 | 2.42→2.27 | 132 |
| b_pc_spin_if4_g5_uniform_w4 | 1.910 [1.863..2.188] | 0.170 | NOISY | 1/3 | 3.3 | 21.0 | 3.69 | 2.33→2.46 | 18 |
| b_pc_park_if4_g5_uniform_w4 | 0.651 [0.628..0.699] | 0.109 | NOISY | 3/3 | 15.9 | 53.2 | 2.32 | 2.86→2.96 | 39 |
| b_pc_spin_g5_uniform_w8 | 0.209 [0.202..0.220] | 0.086 |  | 1/3 | 15.6 | 176.1 | 3.59 | 2.96→5.27 | 264 |
| b_pc_park_g5_uniform_w8 | 0.206 [0.200..0.212] | 0.058 |  | 1/3 | 28.2 | 118.8 | 2.59 | 5.17→5.32 | 228 |
| b_pc_spin_if4_g5_uniform_w8 | 0.475 [0.453..0.493] | 0.084 |  | 2/3 | 23.0 | 311.3 | 3.52 | 5.77→5.75 | 148 |
| b_pc_park_if4_g5_uniform_w8 | 0.523 [0.502..0.537] | 0.067 |  | 1/3 | 32.8 | 176.1 | 3.14 | 5.75→5.27 | 105 |

From `results/cloud/measure-20261030-100954.txt` (48 configurations).

| config | Mops/s median [min..max] | spread | NOISY | tries | p50 µs | p99 µs | cpu/wall | load1 start→end | steal ticks |
|---|---|---|---|---|---|---|---|---|---|
| b_ws_one_g95_zipf_w1 | 2.036 [1.682..2.245] | 0.277 | NOISY | 3/3 | 0.2 | 2.9 | 1.01 | 4.18→3.92 | 5 |
| b_ws_worker_g95_zipf_w1 | 1.887 [1.483..2.082] | 0.317 | NOISY | 1/3 | 0.2 | 3.1 | 1.00 | 3.92→3.69 | 7 |
| b_ws_keyed_g95_zipf_w1 | 2.101 [1.768..2.290] | 0.248 | NOISY | 2/3 | 0.1 | 2.8 | 1.00 | 3.51→3.31 | 8 |
| b_ws_sharded_g95_zipf_w1 | 1.738 [1.433..2.057] | 0.359 | NOISY | 2/3 | 0.2 | 3.2 | 1.00 | 3.04→3.04 | 5 |
| b_ws_one_g95_zipf_w2 | 0.605 [0.539..0.634] | 0.157 | NOISY | 2/3 | 0.5 | 51.2 | 1.25 | 2.89→2.90 | 17 |
| b_ws_worker_g95_zipf_w2 | 0.512 [0.494..0.524] | 0.059 |  | 3/3 | 1.0 | 37.9 | 1.39 | 2.55→2.39 | 11 |
| b_ws_keyed_g95_zipf_w2 | 2.285 [1.951..2.348] | 0.174 | NOISY | 3/3 | 0.3 | 12.3 | 1.69 | 2.45→2.34 | 12 |
| b_ws_sharded_g95_zipf_w2 | 0.869 [0.764..0.897] | 0.153 | NOISY | 3/3 | 0.5 | 28.7 | 1.36 | 1.94→1.94 | 22 |
| b_ws_one_g95_zipf_w4 | 0.716 [0.664..0.793] | 0.180 | NOISY | 2/3 | 0.7 | 84.0 | 2.12 | 1.82→1.93 | 31 |
| b_ws_worker_g95_zipf_w4 | 0.460 [0.417..0.496] | 0.172 | NOISY | 3/3 | 2.9 | 56.3 | 2.66 | 2.58→2.44 | 67 |
| b_ws_keyed_g95_zipf_w4 | 3.836 [3.198..4.018] | 0.214 | NOISY | 2/3 | 0.3 | 14.3 | 3.14 | 2.61→2.72 | 14 |
| b_ws_sharded_g95_zipf_w4 | 1.888 [1.710..2.041] | 0.175 | NOISY | 1/3 | 0.5 | 27.6 | 2.67 | 2.84→2.69 | 18 |
| b_ws_one_g95_zipf_w8 | 0.906 [0.821..1.003] | 0.201 | NOISY | 1/3 | 0.7 | 139.3 | 2.86 | 2.64→3.02 | 62 |
| b_ws_worker_g95_zipf_w8 | 0.300 [0.277..0.306] | 0.097 |  | 1/3 | 6.5 | 245.8 | 3.14 | 3.23→3.86 | 206 |
| b_ws_keyed_g95_zipf_w8 | 3.440 [3.010..3.574] | 0.164 | NOISY | 1/3 | 0.3 | 50.2 | 3.21 | 3.86→3.82 | 23 |
| b_ws_sharded_g95_zipf_w8 | 2.582 [2.325..2.690] | 0.141 | NOISY | 2/3 | 0.4 | 69.6 | 3.12 | 3.37→3.18 | 23 |
| b_ws_one_g50_zipf_w1 | 1.658 [1.430..1.873] | 0.267 | NOISY | 2/3 | 0.2 | 3.3 | 1.00 | 2.85→2.70 | 8 |
| b_ws_worker_g50_zipf_w1 | 1.708 [1.339..1.935] | 0.349 | NOISY | 3/3 | 0.2 | 3.3 | 1.00 | 2.60→2.60 | 9 |
| b_ws_keyed_g50_zipf_w1 | 1.687 [1.502..1.939] | 0.259 | NOISY | 2/3 | 0.2 | 3.5 | 1.01 | 2.50→2.38 | 7 |
| b_ws_sharded_g50_zipf_w1 | 1.632 [1.479..1.972] | 0.302 | NOISY | 1/3 | 0.2 | 3.3 | 1.01 | 2.25→2.25 | 4 |
| b_ws_one_g50_zipf_w2 | 0.493 [0.434..0.527] | 0.189 | NOISY | 3/3 | 0.8 | 57.3 | 1.25 | 2.10→2.08 | 25 |
| b_ws_worker_g50_zipf_w2 | 0.469 [0.418..0.490] | 0.154 | NOISY | 3/3 | 1.2 | 41.0 | 1.37 | 2.04→1.88 | 23 |
| b_ws_keyed_g50_zipf_w2 | 1.691 [1.510..1.772] | 0.155 | NOISY | 1/3 | 0.5 | 14.6 | 1.70 | 1.89→1.82 | 12 |
| b_ws_sharded_g50_zipf_w2 | 0.724 [0.689..0.801] | 0.155 | NOISY | 2/3 | 0.8 | 29.7 | 1.38 | 1.73→1.75 | 15 |
| b_ws_one_g50_zipf_w4 | 0.626 [0.589..0.658] | 0.110 | NOISY | 2/3 | 1.2 | 84.0 | 2.22 | 1.61→1.52 | 49 |
| b_ws_worker_g50_zipf_w4 | 0.496 [0.481..0.514] | 0.067 |  | 3/3 | 2.0 | 59.4 | 2.60 | 2.03→2.10 | 52 |
| b_ws_keyed_g50_zipf_w4 | 2.450 [2.327..2.879] | 0.225 | NOISY | 1/3 | 0.6 | 17.9 | 3.03 | 2.09→2.01 | 17 |
| b_ws_sharded_g50_zipf_w4 | 1.357 [1.182..1.468] | 0.211 | NOISY | 2/3 | 0.8 | 32.8 | 2.61 | 2.71→2.82 | 28 |
| b_ws_one_g50_zipf_w8 | 0.739 [0.685..0.788] | 0.139 | NOISY | 1/3 | 1.1 | 155.6 | 2.93 | 2.62→3.73 | 59 |
| b_ws_worker_g50_zipf_w8 | 0.334 [0.312..0.360] | 0.144 | NOISY | 2/3 | 3.1 | 229.4 | 3.17 | 4.14→4.08 | 169 |
| b_ws_keyed_g50_zipf_w8 | 2.474 [2.260..2.644] | 0.155 | NOISY | 3/3 | 0.6 | 69.6 | 3.15 | 4.28→4.02 | 43 |
| b_ws_sharded_g50_zipf_w8 | 2.172 [2.139..2.207] | 0.031 |  | 1/3 | 0.6 | 77.8 | 3.17 | 3.94→4.33 | 32 |
| b_ws_one_g5_zipf_w1 | 1.752 [1.673..1.838] | 0.094 |  | 3/3 | 0.2 | 3.1 | 1.00 | 3.52→3.52 | 5 |
| b_ws_worker_g5_zipf_w1 | 1.709 [1.612..1.894] | 0.165 | NOISY | 2/3 | 0.2 | 3.2 | 1.02 | 3.52→3.52 | 3 |
| b_ws_keyed_g5_zipf_w1 | 1.707 [1.314..1.937] | 0.365 | NOISY | 2/3 | 0.2 | 3.3 | 1.02 | 3.16→2.99 | 7 |
| b_ws_sharded_g5_zipf_w1 | 1.434 [1.318..1.594] | 0.192 | NOISY | 3/3 | 0.3 | 3.8 | 1.01 | 2.77→2.63 | 4 |
| b_ws_one_g5_zipf_w2 | 0.464 [0.403..0.497] | 0.203 | NOISY | 2/3 | 0.9 | 61.4 | 1.25 | 2.50→2.34 | 28 |
| b_ws_worker_g5_zipf_w2 | 1.337 [1.219..1.374] | 0.116 | NOISY | 1/3 | 0.5 | 16.9 | 1.55 | 2.24→2.14 | 13 |
| b_ws_keyed_g5_zipf_w2 | 1.484 [1.348..1.558] | 0.142 | NOISY | 1/3 | 0.6 | 15.4 | 1.68 | 2.03→2.03 | 20 |
| b_ws_sharded_g5_zipf_w2 | 0.657 [0.620..0.696] | 0.116 | NOISY | 2/3 | 0.8 | 31.2 | 1.36 | 1.88→1.81 | 22 |
| b_ws_one_g5_zipf_w4 | 0.497 [0.463..0.537] | 0.149 | NOISY | 1/3 | 1.3 | 102.4 | 2.06 | 1.76→1.88 | 73 |
| b_ws_worker_g5_zipf_w4 | 1.371 [1.217..1.507] | 0.212 | NOISY | 3/3 | 0.8 | 33.8 | 2.73 | 1.91→1.77 | 38 |
| b_ws_keyed_g5_zipf_w4 | 1.733 [1.507..1.841] | 0.193 | NOISY | 2/3 | 1.1 | 26.6 | 2.98 | 1.95→1.87 | 34 |
| b_ws_sharded_g5_zipf_w4 | 1.206 [1.039..1.320] | 0.233 | NOISY | 3/3 | 0.9 | 36.9 | 2.57 | 1.97→1.98 | 36 |
| b_ws_one_g5_zipf_w8 | 0.600 [0.544..0.628] | 0.140 | NOISY | 1/3 | 1.2 | 176.1 | 2.78 | 1.98→2.47 | 122 |
| b_ws_worker_g5_zipf_w8 | 1.140 [1.096..1.253] | 0.138 | NOISY | 1/3 | 1.0 | 139.3 | 3.19 | 3.33→3.95 | 80 |
| b_ws_keyed_g5_zipf_w8 | 1.616 [1.502..1.726] | 0.139 | NOISY | 1/3 | 1.1 | 102.4 | 3.27 | 3.06→3.30 | 47 |
| b_ws_sharded_g5_zipf_w8 | 1.710 [1.594..1.872] | 0.163 | NOISY | 1/3 | 0.8 | 90.1 | 3.10 | 3.41→3.60 | 45 |

From `results/cloud/measure-20261030-103543.txt` (48 configurations).

| config | Mops/s median [min..max] | spread | NOISY | tries | p50 µs | p99 µs | cpu/wall | load1 start→end | steal ticks |
|---|---|---|---|---|---|---|---|---|---|
| b_pc_spin_g95_zipf_w1 | 1.662 [1.390..1.882] | 0.296 | NOISY | 1/3 | 0.2 | 3.5 | 1.00 | 2.46→2.46 | 8 |
| b_pc_park_g95_zipf_w1 | 1.983 [1.905..2.107] | 0.102 | NOISY | 3/3 | 0.2 | 2.7 | 1.00 | 1.41→1.41 | 5 |
| b_pc_spin_if4_g95_zipf_w1 | 1.809 [1.610..2.032] | 0.233 | NOISY | 3/3 | 0.2 | 3.2 | 1.00 | 1.25→1.25 | 3 |
| b_pc_park_if4_g95_zipf_w1 | 1.651 [1.474..2.048] | 0.348 | NOISY | 2/3 | 0.2 | 3.3 | 1.00 | 1.19→1.19 | 5 |
| b_pc_spin_g95_zipf_w2 | 1.237 [1.164..1.335] | 0.138 | NOISY | 1/3 | 1.1 | 5.1 | 1.96 | 1.18→1.24 | 13 |
| b_pc_park_g95_zipf_w2 | 0.134 [0.131..0.139] | 0.060 |  | 1/3 | 5.4 | 35.8 | 0.91 | 1.36→1.32 | 45 |
| b_pc_spin_if4_g95_zipf_w2 | 2.061 [1.698..2.124] | 0.207 | NOISY | 3/3 | 1.5 | 8.7 | 1.96 | 1.10→1.09 | 14 |
| b_pc_park_if4_g95_zipf_w2 | 0.648 [0.615..0.695] | 0.123 | NOISY | 3/3 | 2.0 | 33.8 | 1.19 | 1.18→1.23 | 21 |
| b_pc_spin_g95_zipf_w4 | 1.954 [1.541..2.077] | 0.274 | NOISY | 1/3 | 1.3 | 6.5 | 3.71 | 1.23→1.46 | 19 |
| b_pc_park_g95_zipf_w4 | 0.158 [0.154..0.163] | 0.057 |  | 1/3 | 20.0 | 57.3 | 1.59 | 1.85→2.13 | 140 |
| b_pc_spin_if4_g95_zipf_w4 | 3.643 [3.062..3.948] | 0.243 | NOISY | 2/3 | 2.0 | 11.5 | 3.75 | 2.00→1.92 | 15 |
| b_pc_park_if4_g95_zipf_w4 | 0.729 [0.702..0.748] | 0.063 |  | 1/3 | 15.9 | 50.2 | 2.08 | 1.71→1.91 | 41 |
| b_pc_spin_g95_zipf_w8 | 0.234 [0.229..0.242] | 0.056 |  | 1/3 | 13.1 | 159.7 | 3.56 | 1.77→4.44 | 257 |
| b_pc_park_g95_zipf_w8 | 0.216 [0.207..0.221] | 0.065 |  | 1/3 | 27.6 | 116.7 | 2.53 | 3.91→4.40 | 240 |
| b_pc_spin_if4_g95_zipf_w8 | 0.545 [0.532..0.591] | 0.108 | NOISY | 3/3 | 20.0 | 278.5 | 3.60 | 5.32→5.86 | 102 |
| b_pc_park_if4_g95_zipf_w8 | 0.627 [0.599..0.653] | 0.086 |  | 1/3 | 31.2 | 151.6 | 3.24 | 5.86→5.83 | 84 |
| b_pc_spin_g50_zipf_w1 | 1.459 [1.263..1.529] | 0.182 | NOISY | 1/3 | 0.2 | 3.7 | 0.98 | 5.83→5.44 | 10 |
| b_pc_park_g50_zipf_w1 | 1.624 [1.307..1.708] | 0.247 | NOISY | 2/3 | 0.2 | 3.2 | 1.01 | 2.27→2.17 | 3 |
| b_pc_spin_if4_g50_zipf_w1 | 1.601 [1.285..1.744] | 0.287 | NOISY | 2/3 | 0.2 | 3.5 | 0.99 | 1.60→1.60 | 9 |
| b_pc_park_if4_g50_zipf_w1 | 1.652 [1.459..1.818] | 0.217 | NOISY | 1/3 | 0.2 | 3.4 | 1.01 | 1.55→1.55 | 5 |
| b_pc_spin_g50_zipf_w2 | 1.070 [0.896..1.143] | 0.231 | NOISY | 2/3 | 1.2 | 5.9 | 1.93 | 1.51→1.55 | 15 |
| b_pc_park_g50_zipf_w2 | 0.131 [0.128..0.140] | 0.092 |  | 2/3 | 6.0 | 36.9 | 0.91 | 1.25→1.38 | 48 |
| b_pc_spin_if4_g50_zipf_w2 | 1.994 [1.873..2.288] | 0.208 | NOISY | 1/3 | 1.5 | 9.0 | 1.94 | 1.35→1.35 | 10 |
| b_pc_park_if4_g50_zipf_w2 | 0.672 [0.624..0.720] | 0.143 | NOISY | 3/3 | 2.1 | 33.8 | 1.26 | 1.34→1.31 | 11 |
| b_pc_spin_g50_zipf_w4 | 1.763 [1.613..1.959] | 0.196 | NOISY | 2/3 | 1.3 | 8.7 | 3.61 | 1.52→1.72 | 21 |
| b_pc_park_g50_zipf_w4 | 0.153 [0.147..0.160] | 0.085 |  | 1/3 | 20.5 | 61.4 | 1.61 | 1.83→2.29 | 122 |
| b_pc_spin_if4_g50_zipf_w4 | 3.122 [3.055..3.380] | 0.104 | NOISY | 1/3 | 2.2 | 13.6 | 3.74 | 2.29→2.18 | 16 |
| b_pc_park_if4_g50_zipf_w4 | 0.682 [0.659..0.726] | 0.098 |  | 2/3 | 16.4 | 53.2 | 2.11 | 2.08→1.91 | 49 |
| b_pc_spin_g50_zipf_w8 | 0.225 [0.221..0.236] | 0.067 |  | 1/3 | 13.8 | 167.9 | 3.54 | 1.91→5.16 | 240 |
| b_pc_park_g50_zipf_w8 | 0.215 [0.210..0.230] | 0.093 |  | 1/3 | 27.1 | 112.6 | 2.56 | 5.16→5.63 | 208 |
| b_pc_spin_if4_g50_zipf_w8 | 0.540 [0.533..0.574] | 0.076 |  | 2/3 | 20.0 | 286.7 | 3.56 | 5.00→5.12 | 85 |
| b_pc_park_if4_g50_zipf_w8 | 0.628 [0.605..0.667] | 0.099 |  | 1/3 | 31.2 | 147.5 | 3.21 | 5.12→4.84 | 93 |
| b_pc_spin_g5_zipf_w1 | 1.230 [1.076..1.498] | 0.343 | NOISY | 2/3 | 0.3 | 4.1 | 1.01 | 4.84→4.53 | 7 |
| b_pc_park_g5_zipf_w1 | 1.515 [1.247..1.651] | 0.267 | NOISY | 3/3 | 0.2 | 3.5 | 1.01 | 3.99→3.75 | 7 |
| b_pc_spin_if4_g5_zipf_w1 | 1.558 [1.149..1.766] | 0.396 | NOISY | 2/3 | 0.2 | 3.3 | 1.01 | 3.53→3.53 | 9 |
| b_pc_park_if4_g5_zipf_w1 | 1.617 [1.396..1.766] | 0.229 | NOISY | 2/3 | 0.2 | 3.3 | 1.01 | 3.32→3.14 | 6 |
| b_pc_spin_g5_zipf_w2 | 1.005 [0.894..1.040] | 0.145 | NOISY | 2/3 | 1.2 | 6.4 | 1.95 | 3.05→2.96 | 13 |
| b_pc_park_g5_zipf_w2 | 0.126 [0.124..0.136] | 0.095 |  | 1/3 | 5.8 | 37.9 | 0.91 | 2.80→2.26 | 51 |
| b_pc_spin_if4_g5_zipf_w2 | 2.099 [1.614..2.190] | 0.274 | NOISY | 1/3 | 1.5 | 8.2 | 1.99 | 2.04→2.04 | 7 |
| b_pc_park_if4_g5_zipf_w2 | 0.612 [0.548..0.641] | 0.152 | NOISY | 3/3 | 2.3 | 34.8 | 1.23 | 1.88→1.89 | 16 |
| b_pc_spin_g5_zipf_w4 | 1.716 [1.438..1.913] | 0.277 | NOISY | 3/3 | 1.3 | 8.2 | 3.61 | 1.98→1.99 | 24 |
| b_pc_park_g5_zipf_w4 | 0.160 [0.155..0.167] | 0.075 |  | 2/3 | 20.0 | 56.3 | 1.63 | 2.31→2.24 | 95 |
| b_pc_spin_if4_g5_zipf_w4 | 3.133 [3.040..3.344] | 0.097 |  | 3/3 | 2.2 | 12.3 | 3.83 | 1.81→1.99 | 10 |
| b_pc_park_if4_g5_zipf_w4 | 0.710 [0.676..0.754] | 0.110 | NOISY | 1/3 | 16.1 | 48.1 | 2.12 | 1.99→2.00 | 38 |
| b_pc_spin_g5_zipf_w8 | 0.226 [0.215..0.230] | 0.066 |  | 3/3 | 13.8 | 163.8 | 3.59 | 6.07→6.57 | 224 |
| b_pc_park_g5_zipf_w8 | 0.218 [0.214..0.222] | 0.037 |  | 2/3 | 27.1 | 112.6 | 2.57 | 5.48→5.57 | 185 |
| b_pc_spin_if4_g5_zipf_w8 | 0.552 [0.548..0.582] | 0.062 |  | 1/3 | 20.0 | 258.0 | 3.53 | 4.48→5.08 | 109 |
| b_pc_park_if4_g5_zipf_w8 | 0.627 [0.603..0.662] | 0.094 |  | 3/3 | 30.7 | 151.6 | 3.23 | 6.38→5.93 | 108 |

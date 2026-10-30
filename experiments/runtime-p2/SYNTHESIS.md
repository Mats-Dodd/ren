# Runtime phase 2 (Phase A): synthesis

What K1b, percore (with the owner's skewed-load and place_at_spawn
extension), spin and switch say about foundations.md decisions 9, 10 and
18 and about briefs/stage-services.md step 7. Nothing here is applied to
the documents. Sections 2 and 3 are proposed text for the owner.

## 0. Machine and method

- **Machine: `cloud`** ([experiments/MACHINE-cloud.md](../MACHINE-cloud.md)):
  a KVM guest with **4 vCPUs** (Intel Xeon @ 2.10 GHz, no SMT, 1 NUMA
  node), Linux 6.18.44, clang 18.1.3, gcc 13.3, go 1.24.7, rustc 1.97.0.
  More than 4 busy threads is oversubscribed by construction.
- **macOS** numbers are the owner's Apple M4 Max (12P+4E) runs in each
  experiment's `results/` (phase 2) and experiments/many-cores (phase 1).
  They are quoted beside the cloud numbers and labelled. **Verdicts below
  use cloud numbers only.**
- **Serialisation.** Every timed configuration ran alone under
  `flock -x /tmp/ren-bench/lock` (one configuration per acquisition);
  builds, smoke runs and TSan ran under `flock -s`. The 1-minute load from
  `/proc/loadavg` is recorded at the start and end of every configuration
  in the result files.
- **Statistics.** At least 7 repetitions per configuration; median
  [min..max]. Spread = (max − min)/median. Above 10% the configuration was
  re-run up to twice more; if still above 10% it is **NOISY** and is not a
  headline.
- **Verification.** Each experiment's headlines were re-run by an
  independent agent from a separate build (`results/cloud/VERIFY.md`).
  Where VERIFY disagrees with SUMMARY, the verified number is used and the
  disagreement is named (section 7).
- **Noise on this machine is high.** Hypervisor steal takes 1.1 to 1.3% of
  vCPU time, in gaps of up to 4.1 ms per vCPU (percore's `--gap-probe`).
  NOISY counts: percore 193 of 263 configurations, spin 334 of 355 (main
  sweep), switch 25 of 30 unpinned and 18 of 30 pinned. foundations.md's
  Staging item 6 already said phase one should run "on the M4 Max, not on
  cloud machines, whose shared cores make these numbers noise". The cloud
  runs bear that out, and most latency tails below are NOISY.

Sources: [k1b/results/cloud/](k1b/results/cloud/) (headline grid and VERIFY-headline.md; see 1a),
[percore/results/cloud/SUMMARY.md](percore/results/cloud/SUMMARY.md),
[spin/results/cloud/SUMMARY.md](spin/results/cloud/SUMMARY.md),
[switch/results/cloud/SUMMARY.md](switch/results/cloud/SUMMARY.md), each
with its VERIFY.md, and each experiment's PLAN.md.

## 1. K1b: the hit path and eviction

The three variants (k1b/PLAN.md): **a_lru**, phase 1's partitions, each with
an exact LRU and a cap of max/parts (three lock round trips per `at`);
**b_sampled**, where `take` stores a use stamp and a full family evicts the
oldest of k = 3, 5 or 10 sampled unpinned slots, under one global cap;
**c_clock**, where `take` stores a use bit and a CLOCK hand picks the victim.

### 1a. Which cloud runs exist

The deterministic sections finished (sim, parts, mem). The full threaded
grid (`throughput-20261030-063029.txt`, 576 configurations at 200 ms)
stopped after 13 lines and is kept only as a record. The orchestrator then
ran a reduced grid, `measure-cloud.sh headline`, at 1000 ms a rep:
`headline-20261030-122017.txt`, 104 configurations, 0 failures, 52 NOISY.
It covers C and Rust, a/b/c, zipf99 and uniform, max 10k, hits only
(U = 0.9) and under real eviction (U = 2), at 1, 2, 4 and 8 workers, plus
sampled k = 3 and 10 under eviction. An independent agent re-ran 15 point
claims and 4 derived claims from its own build
(`results/cloud/VERIFY-headline.md`): all reproduce, 8 within 10% on clean
runs, 7 NOISY with medians on the claim. The extras (os lock, parts sweep)
were not run on cloud.

### 1b. Hit rate under eviction (cloud, verified)

These are single-threaded simulator hit rates on one recorded trace per
workload. They are not hit rates from the threaded harness. All 32 cloud
traces are bit-identical to macOS, and C = Rust on all 32. VERIFY confirmed
this over 7 reps, with clang and gcc.

Points against exact LRU, worst case over zipf99 and zipf70, max 10k and 50k,
U = 1.25, 2, 4 and 10:

| policy | Zipf (worst) | scan (range) | uniform | PLAN 13/14 bound | held? |
|---|---|---|---|---|---|
| sampled k=10 | −0.23 | −0.05 .. −0.09 | ±0.04 | within 0.3 | yes |
| sampled k=5 | −0.55 | −0.11 .. +0.23 | ±0.08 | within 1 | yes |
| sampled k=3 | −1.12 | **+0.55 .. +1.84** | ±0.04 | within 2 | yes, and best on scan |
| CLOCK | −1.15 | −0.56 .. −0.79 | ±0.03 | within 1.5 | yes |
| plru (a) | −0.02 .. +0.03 | ±0.01 | ±0.02 | within 0.1 at U ≥ 2 | yes, but see below |

Example: zipf99 at max 10k and U = 2 gives lru 90.10%, s10 −0.09, s5 −0.31,
clock −0.42 and s3 −0.70.

Caveat (VERIFY): `sim.c` and `sim.rs` hard-code parts = 8. PLAN and the
scripts say the derived default (32 at max 50k). So the plru column at max
50k was simulated with 8 partitions, on both machines. The other policies do
not read parts.

### 1c. Throughput on the hit path (cloud, verified)

Spin lock, max 10k, k = 5, Mops/s, C (Rust within 10% unless noted).
N = NOISY. Verified medians from VERIFY-headline.md in brackets where they
were re-run.

**Hits only (U = 0.9, hit rate 1.0, 0 evictions):**

| keys | workers | a_lru | b_sampled | c_clock | b/a |
|---|---|---|---|---|---|
| uniform | 1 | 23.3 N | 28.3 N | 30.1 N | 1.22 |
| uniform | 2 | 7.42 | 32.9 | 31.5 | 4.4 |
| uniform | 4 | **6.79** (6.83) | **50.5** (51.6) | **51.0** (53.0) | **7.4** (7.55) |
| uniform | 8 (oversub) | 3.57 | 39.7 N | 40.3 N | 11 |
| zipf99 | 1 | 26.8 N | 32.9 (30.8 N) | 30.5 N | 1.22 |
| zipf99 | 2 | 6.64 | 27.8 | 27.3 N | 4.2 |
| zipf99 | 4 | **5.21** (5.33) | **25.0** (26.7 N) | 26.5 | **4.8** (5.0) |
| zipf99 | 8 (oversub) | 2.79 | 19.4 N | 19.8 N | 6.9 |

Rust b_sampled, uniform, 4 workers: 53.3 (53.0 verified).

**Under real eviction (U = 2; hit rate 0.90 on zipf99, 0.50 on uniform):**

| keys | workers | a_lru | b_sampled k=5 | c_clock | b k=3 | b k=10 |
|---|---|---|---|---|---|---|
| zipf99 | 1 | 22.0 N | 21.7 N | 21.3 | 22.2 N | 21.3 N |
| zipf99 | 4 | **4.49** (4.62) | **11.2** (11.1 N) | **6.81** (6.78 N) | 10.9 N | 10.9 |
| uniform | 1 | 12.7 N | 10.1 N | 9.77 N | 10.8 N | 8.47 |
| uniform | 4 | **2.55** N (2.41) | **3.13** (3.02) | **1.96** N (1.91 N) | 2.63 N | 2.54 |

- **Hits: sampled (b) and CLOCK (c) scale where a_lru collapses.** At 4
  workers b is 7.4× a on uniform keys and 4.8× on zipf99 (worst verified
  pairing 3.97×). b and c are within 6% of each other on every hit cell.
- **Do N workers beat one?** On uniform hits, yes: b at 4 workers is 1.78×
  b at 1 (verified 1.88 to 2.05×). On zipf99 hits, **no**: 0.76× (verified
  0.76 to 0.88×), because the hottest instances' lines still move on every
  take. a_lru stays at 0.18 to 0.29× of one worker on every load.
- **Under eviction nothing scales.** No variant's 4-worker total beats its
  own 1-worker total (0.15 to 0.5×, verified). b still leads a at 4
  workers: 2.5× on zipf99, but only 1.2× on uniform with half the accesses
  missing. The miss path (shard write lock, sampling, claim) is the cost
  there, not the hit.
- **CLOCK under eviction is worse than sampling, and on uniform worse than
  exact LRU** (1.96 against 2.55 at 4 workers; verified 1.60 to 1.96
  against 2.41). The global hand is a contended line. So CLOCK loses on the
  axis it was meant to win.
- **k under eviction:** k = 3, 5 and 10 are within 10% of each other on
  zipf99 at 4 workers. On uniform, k = 5 is 1.2× k = 3 and k = 10.
- **Retries** (claims that lost a race and resampled) are 31 to 33% of
  misses under uniform eviction at 4 workers for b and c, against PLAN 11's
  < 20%; 13 to 17% on zipf99.
- **Cloud single-worker throughput is about half of macOS** (a_lru 27
  against 64 Mops/s), and every 1-worker cell is NOISY on this machine even
  at 1000 ms reps: read 1-worker absolutes as ±10%.

macOS (phase 2, k1b/results/analysis.txt), for reference only:

- 1 worker: b/a = 1.25 to 1.52 on hits; b/a = 0.78 on scan.
- 16 workers against 1, uniform: b 1.75 to 3.38×, a 0.14 to 0.51×.
  So b16/a16 = 8.9 to 27.9.
- 16 workers against 1, zipf99: b 0.14 to 0.23×, a 0.08 to 0.16×.
  So b16/a16 = 2.3 to 3.4.
- p99 at 16 workers, uniform: b 167 to 333 ns, a 4.2 to 34.7 µs.
- c is within 10% of b on 67 of 72 hit-path cells.

Cloud and macOS agree in shape: b/a is 4 to 8× by 4 workers on hits,
uniform hits scale with b, zipf99 hits don't scale with anything.

### 1d. Verdict

- **Hit rate (cloud): sampled eviction is good enough.** k = 5 is never more
  than 0.55 points below exact LRU, and it beats LRU on scans. CLOCK is
  within 1.15 points. Both meet the PLAN's bounds.
- **Hit-path throughput (cloud, verified): "the runtime records each use,
  the library samples the victim" wins.** At 4 workers b is 7.4× exact
  LRU-per-partition on uniform hits and 4.8× on zipf99 hits, and 1.2 to
  2.5× under real eviction. CLOCK matches b on hits but loses to b under
  eviction everywhere, and to exact LRU on uniform eviction. **Pick
  sampled k = 5, not CLOCK.**
- **Do N workers now beat one?** On uniform hits, yes (b: 1.8 to 2.0× at 4
  workers). On zipf99 hits, no (0.76 to 0.88×), on cloud as on macOS. Under
  eviction, no variant does. The hit path is fixed; hot keys and the miss
  path are not.
- **Does `parts:` still pick the victim?** Under b and c, no. The victim
  sequence is identical at parts 1, 8 and 64, and VERIFY extended this to
  parts 2 and 32 at all four universes (32/32). Under a it changes in every
  case. This invariance holds by construction (the sampler reads only the
  slab), so it tests the shard table, not the policy, and it covers the
  simulator, not threaded k1b.c.
- **Is `parts:` needed as a user-facing knob?** No, for meaning: under b
  the victim depends only on the trace and the sampling RNG, so a journal
  replays at any parts and any thread count as long as the RNG comes from
  the tape. For performance, macOS shows b's hit path is flat in parts
  (parts 1/8/64 within 4%, P8). Cloud has no parts sweep, and no
  miss-regime data, which is where the shard write lock is taken. So
  `parts` becomes a map-sharding detail the runtime picks.
- **Memory (cloud = macOS):** one 128-byte line per instance costs +3.6 MB
  (+129%) at 50k actors with 32 B of state. With 256 B of state it costs
  +5.2 MB (+37%). The map adds 31.5 B per instance. PLAN 17 to 19 held.

## 2. Proposed change to briefs/stage-services.md, Steps, step 7

**Gate: met.** The gate was "b at 4 workers ahead of a at 4 workers on
uniform keys" on cloud. It is 7.4× ahead on hits (verified 7.55×) and 1.2×
under eviction. Both halves (hit rate and scaling) are now cloud-verified.
Two things the text below does not promise, because cloud shows they are
false: hot keys (Zipf 0.99) still do less at 4 workers than at one, and a
miss-heavy family does not scale.

**Current text (step 7, first sentence):**

> 7. **`actors`,** in Ren in std over the family: `Actors<K, D> ! E`,
>    `at` with setup and its declared errors, pinning, partitions and LRU
>    eviction under `max:`, `evict`, `evict_idle`, `each`, `count` and the
>    counts, the no-deadlock rules (`at` in `at`, `Full`), `finally` that
>    can't fail, teardown order; `chaos: true`; the journal's names with
>    incarnations, recorded and replayed.

**Proposed text:**

> 7. **`actors`,** in Ren in std over the family: `Actors<K, D> ! E`,
>    `at` with setup and its declared errors; pinning with one atomic on
>    the instance; **eviction under one global `max:` by sampling**. The
>    family's `take` stores the worker's use stamp in the instance, which
>    is the only write a hit makes. A full family evicts the oldest-stamped
>    of 5 unpinned instances, sampled with `Random` (from the tape under
>    `sim`), and an instance being claimed is skipped, never waited for.
>    `actors` has **no partitions in its meaning and no `parts:`
>    parameter**. The family shards its map's write lock as the runtime
>    chooses, and no victim depends on that choice. Also: `evict`,
>    `evict_idle`, `each`, `count` and the counts; the no-deadlock rules
>    (`at` in `at`, `Full`); `finally` that can't fail; teardown order;
>    `chaos: true`; the journal's names with incarnations, recorded and
>    replayed.

**Add to step 7's *Done when*:**

> a run that evicts replays byte for byte from its journal at 1 and 4
> workers and at two map shardings, and its victim sequence is the same at
> each (experiments/runtime-p2/k1b, `k1b_parts`).

Consequential edits, named but not drafted here:

- What's decided 5: drop "partitions with their own map and cap".
- What's decided 8: "of the least recently released evictable actor"
  becomes "of the oldest-used of a sample of evictable actors". The stamp
  is taken at `take` (use), not at release.
- foundations.md decision 18: drop the partitions bullet ("Each has its own
  lock, map, exact LRU and a cap of `max / parts`"). `evict: Lru` stays as
  the name, documented as sampled LRU, within 0.55 points of exact LRU in
  K1b's traces.

## 3. Proposed text for foundations.md decision 9: what each runtime costs

Insert after "v1 ships `single`, `work_stealing`, `per_core` and `sim`."
Numbers are from `cloud`; macOS is given where it was measured.

> - **What each costs.** Measured on a 4-vCPU cloud guest (Xeon 2.1 GHz,
>   KVM), and on an M4 Max where noted (experiments/runtime-p2,
>   experiments/many-cores):
>   - **A task switch under `single`** costs about 5 ns: an add and a
>     yield, 5.2 ns, against 3.2 for hand-written C. A round trip through a
>     one-slot channel, two switches, takes 16 to 18 ns. A parked task is
>     128 bytes. Go at `GOMAXPROCS=1` takes 388 ns a round trip and 837 ns
>     to wake a parked goroutine, and tokio's current-thread runtime takes
>     401 ns a round trip (195 with a `!Send` channel). (M4: smoke runs
>     only, Go 248 ns and tokio 232 ns a round trip.)
>   - **A hop to an owner that is spinning** takes 1.1 µs at the median for
>     a 100 ns operation and 2.4 µs for a 1 µs one, with a p99 of 12 µs and
>     3.2 µs of CPU a hop. (M4, phase 1: 105 to 385 ns.)
>   - **A hop to an owner that has parked** takes 25 to 27 µs at the
>     median, and 70 to 125 µs at p99. It costs 12 to 13 µs of CPU a hop
>     back to back, and 41 to 44 µs at one hop per 100 µs. (M4, phase 1:
>     4 to 8 µs.)
>   - **`per_core` against `work_stealing`,** in flottning's kernel on
>     4 cores:
>     - With even keys and no long calls, spinning `per_core` ran 1.0 to
>       1.9× `work_stealing` in closed loop, and 3.1× open loop.
>     - Under skew (Zipf 0.99, 5% of requests doing 200 µs of pure work)
>       it ran 0.59× `work_stealing`. Its light requests' p99 rose to 4 to
>       12 ms, against 44 to 201 µs, because a core running pure work or
>       losing its vCPU stalls every core that hops to it.
>     - With more threads than cores, spinning `per_core` loses 6× of its
>       throughput, so `per_core` fails at start rather than oversubscribe.
>   - **Placing effectful tasks at spawn, with a stealing pool for pure
>     work,** was measured and is not shipped:
>     - Under skew it cut light requests' p99 2 to 6.5× below
>       `work_stealing`'s while the pool kept up.
>     - It capped throughput at the pool's size: 0.3× with one pool thread
>       of four, and 0.6× with two.
>     - It raised the p99 over all requests (270 against 213 µs at a
>       quarter load, 1.18 against 0.28 ms at half).
>     - It did not lower p99.9.
>   - **The spin budget is the runtime's constant, not the program's,**
>     and `sim` draws it from the tape as it draws B and K.
>     - Under 5 µs, spinning behaved as parking at once.
>     - Go's gate (spin only while another worker is awake), capped at
>       20 µs, matched never parking back to back: p99 12 µs.
>     - At one hop per 100 µs per worker that gate burned 0.375 of the
>       machine, against 0.263 for parking at once and 0.985 for never
>       parking.
>     - No rule tried was both near the best p99 and within 5% of parking
>       at once at idle.
>     - (M4: not measured.)

Status of each number:

- **Task switch.** fanout_yield ren_c 5.22 ns and raw_c 3.26 ns are
  confirmed. The 16 to 18 ns round trip is NOISY in both full runs; one
  verified pinned try passed at 16.36 ns.
- **Go and tokio.** Confirmed: Go park wake 810 to 837 ns, tokio 385 to
  402 ns, tokio local 195 to 197 ns.
- **Spinning hop.** The 2.4 µs p50 and 12 µs p99 are confirmed (spin H2,
  at 1 µs service). The 1.1 µs at 100 ns service is NOISY on p99 only.
- **Parked hop.** The latencies are NOISY on p99. The CPU per hop is
  within 10% in every run. The 41 to 44 µs figure is confirmed (H1).
- **per_core.**
  - Closed loop: pc_spin 1.53 against ws_sharded 0.81 Mops/s at 50/50
    uniform, 4 workers, both NOISY. pc_spin is ahead at every mix and
    distribution at 2 and 4 workers, 1.03 to 1.89×.
  - Open loop: 2.38 against 0.77, both NOISY, with disjoint ranges.
  - Skewed throughput: the 0.59× is confirmed. The skewed tails are NOISY.
  - The collapse is confirmed.
- **place_at_spawn.** Throughput is confirmed. The light-p99 ordering is
  NOISY but held in every rep of every session, and in VERIFY. The
  all-request p99 is confirmed and biased in place_at_spawn's favour
  (section 4).
- **Spin.** The util figures are confirmed. "No rule met both" is
  strengthened by VERIFY (section 7).

## 4. percore extension: work_stealing, per_core and place_at_spawn

Kernel: flottning-shaped (skip-list memtable and WAL, 4 shards), open loop
with Poisson arrivals. Latency runs from arrival to completion.

- **Loads.** *Even* is 50/50 get/put on uniform keys. *Skewed* is Zipf
  0.99 keys with 5% of requests first running a ~200 µs dependent `mix64`
  chain.
- **place_at_spawn** places each effectful task on the least-loaded worker
  at spawn, and it never moves. Pure work goes to a separate pool of FIFOs
  that steal from each other.
- **Splits on 4 vCPUs:** 3+1 and 2+2 (workers + pool threads), and 4+4
  (oversubscribed).
- **Offered latency loads** are 25% and 50% of work_stealing's throughput
  for that load.

Throughput is Mreq/s. Latency is in µs, the median of 7 reps. Values are the
SUMMARY's; VERIFY re-runs are in section 7.

| load | runtime | throughput | light p50 25% · 50% | light p99 25% · 50% | light p999 25% · 50% | all p99 25% · 50% |
|---|---|---|---|---|---|---|
| even | work_stealing | 0.774 NOISY (VERIFY 0.684 NOISY) | 2.4 · 2.4 | 58 · 1049 N | 1933 · 4588 N | = light |
| even | per_core | 2.382 NOISY | 2.2 · 2.0 | 1835 · 2359 N | 5636 · 4850 N | = light |
| even | pas 3+1 | 0.674 (VERIFY 0.636 to 0.679, all NOISY) | 2.7 · 2.8 | 279 · 1606 N | 2818 · 5112 N | = light |
| even | pas 2+2 | 0.664 (VERIFY 0.726 NOISY) | 2.7 · 3.8 | 754 · 1376 N | 7602 · 3473 N | = light |
| skewed | work_stealing | **0.340** (VERIFY 0.328) | 1.0 · 1.1 | 44 · 201 N | 786 · 2621 N | **213** · 279 |
| skewed | per_core | **0.201** (VERIFY 0.194) | 2.1 · 213 | 4129 · 12321 N | 11797 · 15204 N | 4129 · 12321 N |
| skewed | pas 3+1 | **0.098** (VERIFY 0.097) | 1.2 · 1.2 (50% not sustained) | 19.5 · 26.6 N | 410 · 1606 N | 1737 · 1.4 s (not sustained) |
| skewed | pas 2+2 | **0.193** (VERIFY 0.195) | 1.0 · 1.0 | 20.0 · 32.8 N | 803 · 1475 N | 270 · 1180 N |
| skewed | pas 4+4 (8 threads) | 0.275 NOISY | — | 25 · 483 N | — | — |

N = NOISY. Bold = confirmed by VERIFY.

- **Skewed heavy p50:** work_stealing 196.6 µs, which is the chunk itself.
- **Skewed heavy p99 at 50%:** pas 2+2 7.2 ms against work_stealing 0.49 ms.
- **pas 3+1 cannot sustain 50% under skew.** Its pool caps it near 0.1 M
  req/s per pool thread, which VERIFY confirmed from the source.

**Does place_at_spawn plus a stealing pool recover work stealing's tail
latency?**

- **For light requests' p99 under skew: yes, and it beats work stealing,
  while the pool keeps up.**
  - At 25% load: 19.5 to 24.6 µs against 44 to 53 µs.
  - At 50% load (2+2): 28 to 33 µs against 184 to 201 µs.
  - Every config is NOISY, but in every session every one of the 7
    place_at_spawn reps was below every one of the 7 work_stealing reps.
    VERIFY reproduced the ordering: 21 µs against 46 to 76 µs, with no
    overlap.
- **For everything else: no.**
  - p999 of light requests overlaps work_stealing's and is bound by vCPU
    steal (0.80 against 0.79 ms at 25%).
  - p99 over all requests is worse: 254 to 270 µs against 213 µs at 25%,
    and 1.18 ms against 0.28 ms at 50%.
  - p99 of heavy requests is 14.7× worse at 50%.
  - Throughput under skew is 0.29 to 0.30× (3+1) and 0.57 to 0.59× (2+2).
  - Even load is not recovered either. Light p50 is a tie: SUMMARY had
    work_stealing 2.37 µs against pas 2.69 µs, and VERIFY's clean try has
    pas at 2.37 µs, so the gap is run-to-run variation. Light p99 is worse
    and NOISY (279 to 754 µs against 58 µs).
  - Oversubscribing to 4+4 doesn't help (483 µs against 201 µs at 50%
    skewed).
- **The 25% comparison is biased toward place_at_spawn** (VERIFY). Its
  `_long` run used ~193 µs chunks and 400k requests, against ~207 µs and
  100k for work_stealing. place_at_spawn's all-request p99 is still the
  higher one, so the direction holds and the gap is understated.
- **per_core has the worst tail under skew by far.** Light requests wait
  behind a 200 µs chunk on their home or owner core: light p50 is 213 µs
  at 50%. It does not sustain 75%.

**Original closed-loop matrix (1, 2, 4 and 8 workers).**

- pc_spin beats ws_sharded at 2 and 4 workers at every mix and
  distribution. PLAN 5 predicted ws_sharded would win by 1.2 to 2×, so it
  is reversed. ws_sharded wins only at 8 workers, which is oversubscribed.
- ws_one peaks at 1 worker (0.96 Mops/s) and drops 4× at 2 workers.
- Zipf is faster than uniform for every variant except pc_park and
  pc_park_if4, which are equal.
- Most of these configs are NOISY (139 of 192).

## 5. Collapse check: the machine or the design?

The core count is 4. **Every throughput collapse above 4 workers comes from
the machine: more spinning threads than vCPUs.** The spin-free and parking
variants do not collapse. The one loss from scaling inside 4 workers is the
design (K1b's a_lru).

| experiment | ≤ 4 threads | 5+ threads | pinning | verdict |
|---|---|---|---|---|
| percore pc_spin (50/50 uniform) | 1.53 pinned / 1.44 unpinned (both NOISY) | 0.233 at 5, 0.211 at 6, 0.227 at 8 pinned two per CPU, 0.213 at 8 unpinned | makes no difference | oversubscription: 6 to 7× collapse at exactly 5 (confirmed) |
| percore pc_spin_if4 (5/95 zipf) | 3.13 at 4 (VERIFY: NOISY, 3.19 to 3.67) | 0.552 at 8 (VERIFY 0.564) | — | oversubscription: 5.6 to 6.5× |
| percore pc_park | 0.157 at 4 | 0.202 at 8 | — | **no collapse** (confirmed) |
| percore ws_sharded, ws_one | rising | rising to 8 | — | no collapse |
| spin, never park (100 ns, back to back) | 2.87 M hops/s at 4 (NOISY) | 4 k at 5, p99 8 ms; 2 k at 6 | auto, off and wrap the same | oversubscription: a spinner holds its vCPU until it is preempted |
| spin, B = 5 µs | 2.6 M at 4 | 266 to 274 k at 5, p99 117 µs | — | degrades, doesn't collapse |
| spin, B = 0 | 137 k at 4 | 164 k at 5, 215 k at 8 (NOISY) | — | no collapse |
| K1b a_lru (zipf99) | **5.48 at 4 = 0.18× of 1 worker** | 2.79 at 8, 1.62 at 16 (NOISY) | the pinned/taskset check did not run | the loss from 1 to 4 is the **design**, within the core count. The further halving to 8 is unverified |
| switch | single-threaded throughout | — | pinned is 11 to 27% faster on 9 of 30 configs, confounded with load | n/a |

What the design must take from this:

- Spinning, whether `per_core`'s or a never-park spin budget, turns
  oversubscription into a collapse.
- research/runtime/SYNTHESIS.md §2.10 already says "`per_core` fails at
  start rather than degrading". This is the measured reason.
- A finite spin budget turns the collapse into a degradation.

## 6. Contradictions

Each is stated as measured. None is explained away.

**Against the agreed model and phase 1's proposed text.**

1. **Phase 1's "a waiter spins a short budget before parking" doesn't pay
   on cloud at short budgets.** The proposed text was for decision 10, citing
   Go's 4 × 30 pauses.
   - Budgets ≤ 2 µs behave exactly like parking at once: p50 24 to 27 µs.
   - Spinning helps only at ≥ 5 µs.
   - A park and wake costs 25 to 35 µs of latency here, against the 4 to
     8 µs phase 1 measured on the M4. The 5 µs park+wake figure behind
     spin's `pred` rule does not transfer.
2. **"No home core" (decision 18), and phase 1's "a home core costs 100× a
   take", don't predict the flottning kernel on cloud.**
   - At 2 and 4 workers spinning `per_core` beats `work_stealing`'s
     sharded layout at every mix (closed loop), and by 3.1× open loop on
     even load (NOISY).
   - `work_stealing`'s workers park on the shard locks (cpu/wall 2.67).
   - Under skew `per_core` loses (0.59×) and its tail is the worst.
   - So the ranking depends on the load, not only on the hop's price.
3. **Phase 1's "N workers do less than one" persists for a_lru on cloud**
   (0.18× at 4 workers). b fixes it for uniform hits (1.8 to 2.0×) but not
   for zipf99 hits (0.76 to 0.88×) and not under eviction (0.15 to 0.5×
   for every variant).
5. **CLOCK was expected to tie sampling.** It ties on hits and loses under
   eviction (0.6× b on zipf99, and below exact LRU on uniform), because
   the hand is one global contended counter.
4. **The model's work_stealing reasoning holds for throughput under skew**
   (it beats both alternatives), but its tail is not the best for light
   requests. place_at_spawn's light p99 is 2 to 6.5× lower.

**Against PLAN predictions.**

- **K1b**
  - P1: b/a at 1 worker is 1.22× on cloud (both NOISY), against 1.5 to 2×.
  - P11: retries are 31 to 33% of misses under uniform eviction at 4
    workers, against < 20%.
  - Cloud single-worker a_lru is 0.48× macOS.
  - From macOS: P2's "b at 16 workers ≥ 6× b at 1" fails (max 3.38×).
    P2's "b16 ≥ 4× a16" fails on zipf99 (2.3 to 3.4×). P4's "b's zipf99
    p99 ≥ 3× lower than a's" fails (2.0 to 2.5×).
  - P13 to P16 held.
- **percore**
  - E1: per_core 3.1× faster than work_stealing at even load, against
    work_stealing ahead by 1.1 to 1.5×. pas 3+1 is 0.87 to 0.96× of
    work_stealing, against 0.6 to 0.8×.
  - E2: work_stealing p99 and p999 are 6 to 100× above the prediction.
    per_core p99 is 31× work_stealing's, against within 2×. pas p99 is 4.8
    to 13× work_stealing's, against within 1.5×.
  - E3: work_stealing/per_core is 1.69×, against within 1.3×.
  - E4: absolute tails are far above the prediction (work_stealing light
    p99 44 and 201 µs, against < 20 and 10 to 100 µs; p999 in ms, against
    tens of µs).
  - E5: work_stealing heavy p50 196.6 µs is 2% under 200 to 220 µs, at
    bucket resolution. per_core does not sustain 75%.
  - E6: holds for light p99, fails for p999.
  - Original matrix: 1, 2, 4, 5, 10 and 11 disagree (5 reversed). 7 (ratio),
    8 (first part) and 9 agree. 6 and the 12/16-worker parts can't be tested
    on 4 vCPUs.
- **spin**
  - (1): B = 0 p50 is 25 to 34 µs against 5 to 8. p99 is 72 to 125 µs
    against 10 to 15. CPU is 11 to 13 µs a hop against 3 to 8.
  - (2): never-park p50 is about 2× the prediction. Oversubscribed p99 is
    8 ms, against tens of µs.
  - (3): a 2 µs reply spin does not help a 1 µs service.
  - (5): spinning still pays at a 20 µs gap; the crossover was predicted
    at 5 to 10 µs.
  - (6): 5 µs is not the best single budget (best in 1 of 15 cells).
  - (7a): pred cap 5 scores 56%, against ≥ 80%.
  - (7c): go cap 20 beats pred cap 20 by 4× on back-to-back p99.
  - (9): parked reach p99 is 36 to 88 µs, against 4 to 8.
  - (4), (7b) and the shape of (5) agree. (8) was not tested.
- **switch**
  - The falsifiers hold: ren_c/raw_c is 2.24 to 2.33× on pingpong (NOISY
    medians) and 1.4× on park wake, under 3×. A parked task is 128 B,
    under 256 B.
  - Go and tokio are above every predicted range:
    - Go: pingpong 388 to 400 ns (150 to 300), spawn_join 436 to 486
      (200 to 350), park wake 810 to 991 (150 to 300), fanout_yield 194
      to 209 (25 to 50).
    - tokio: pingpong 385 to 402 (150 to 300), park wake 183 to 219 (60
      to 150).
  - raw_c park wake 6.8 to 8.5 ns is above 2 to 5, and raw_c fanout
    0.48 ns is below 0.5 to 1.5.
  - PLAN's prose says ren is about 10× under Go and tokio. On cloud it is
    21 to 24× on pingpong and about 35× on spawn_join, because Go and
    tokio were slower than predicted.

**Against macOS.**

- **percore.** The macOS reference is mostly broken: 336 of 428 rep lines
  are usage errors, and there was no extension run, so the main question
  has no macOS reference.
  - ws_one is 2.2× slower on cloud at 1 worker. It falls 4× at 2 workers,
    where macOS stays flat at 1.5 to 1.9.
  - pc_spin against ws_sharded is reversed: macOS (10 workers) had
    ws_sharded ahead, 11.8 against 7.9. Cloud (4 workers) has pc_spin
    ahead, 1.72 against 1.02.
- **switch.** macOS has a smoke file only. Cloud Go/tokio pingpong is about
  1.6× the smoke numbers. The ren_c/raw_c ratio is 2.3× on cloud against
  3.2× in the smoke.
- **spin.** No macOS timed run exists. Against PLAN's macOS smoke note
  (parking costs 2.5 to 7 µs of CPU a hop), cloud costs 11 to 13 µs back to
  back and about 41 µs at a 100 µs gap.
- **K1b.**
  - Hit rates: identical.
  - Hit-path throughput at 1 worker: about half of macOS.
  - a_lru 4 workers / 1 worker: 0.18× on cloud, against macOS (C,
    zipf99, max 10k) 0.25× at 4 workers and 0.08× at 16.

## 7. Verification table

Verdicts are VERIFY's: *confirmed* (within 10%, not NOISY), *within-noise*
(the medians agree, but no clean try), *disagrees*.

| exp | headline | reported | re-run | verdict |
|---|---|---|---|---|
| k1b | parts fingerprint (s3/s5/s10/clock invariant, plru changes) | 8/8 ok | 8/8 in 7 reps; 32/32 at all U, parts 1/2/8/32/64 | confirmed |
| k1b | sim bit-identical to macOS, C = Rust | 32/32 | 32/32 (C, Rust, gcc, other agent's run) | confirmed ("under real eviction" overstates: simulator only) |
| k1b | b4/a4 uniform hits | 7.4× (50.5 / 6.79) | 7.55× (51.6 / 6.83) | confirmed |
| k1b | b4/a4 zipf99 hits | 4.8× (25.0 / 5.21) | 5.0× (26.7 N / 5.33); 3.97× worst pairing | confirmed, thin margin |
| k1b | b uniform hits, 4 workers / 1 | 1.78× | 1.88 to 2.05× | confirmed |
| k1b | b zipf99 hits, 4 workers / 1 | 0.76× | 0.76 to 0.88× | confirmed |
| k1b | U = 2: no variant's 4-worker total beats its 1-worker | holds | 0.15 to 0.5× for all six | confirmed |
| k1b | U = 2 uniform: c4 < a4 | 1.96 N < 2.55 N | 1.60 to 1.96 < 2.41 | confirmed |
| k1b | Rust b uniform hits w4 | 53.3 | 53.0 | confirmed |
| percore | skewed thr, ws | 0.340 [0.332..0.366] | 0.328 [0.315..0.336] | confirmed |
| percore | skewed thr, pc (0.59× ws) | 0.201 | 0.194, 0.59× | confirmed |
| percore | skewed thr, pas 3+1 (0.29×) | 0.098 | 0.097, 0.30× | confirmed |
| percore | skewed thr, pas 2+2 (0.57×) | 0.193 | 0.195, 0.59× | confirmed |
| percore | even thr, pas 3+1 | 0.674 (sp 0.061) | 0.636 to 0.679, NOISY on all 3 tries | within-noise: not a headline |
| percore | skewed 25%, ws: light p50 / all p99 / heavy p50 | 1.02 / 213 / 196.6 µs | 1.09 NOISY / 213 / 196.6 | within-noise (all p99 and heavy p50 confirmed) |
| percore | skewed 25%, pas 2+2 `_long` | 1.22 / 254 / 196.6 µs | 1.18 / 246 / 196.6 | confirmed (not like-for-like with ws) |
| percore | even 25% light p50: ws 2.37 < pas 3+1 2.69 | 2.37 / 2.69 | ws 2.43; pas clean try 2.37 | **disagrees**: no gap; used as a tie above |
| percore | pc_spin collapses at 5 threads | 0.233 / 0.211 / 0.227 / 0.213 | 0.247 / 0.208 to 0.217 / 0.211 / 0.218 | confirmed |
| percore | pc_spin_if4 4 → 8, both clean | 3.133 → 0.552 | 3.19 to 3.67 NOISY → 0.564 | within-noise (collapse 5.6 to 6.5×) |
| percore | pc_park no collapse | 0.157 → 0.202 | 0.162 → 0.209 | confirmed |
| spin | H1 idle burn per budget | B=0 0.263 … inf 0.985; CPU/hop 40.9 | 0.271 … 0.987; CPU/hop 44.1 | confirmed (2 µs, 5 µs, go5 NOISY in re-run) |
| spin | H1/H4 pred cap 20 within X = 0.05 | +0.049 | +0.055 to +0.056 | **disagrees**: breaks X; so do fixed 5 µs and ema5 |
| spin | H2 back-to-back p99: inf = go20 12.0, pred20 50.2, ema20 60.4 | as stated | 11.5 / 12.0 to 12.5 / 48.1 / 60.4 NOISY | confirmed |
| spin | H3 fixed 20 µs at gap 100 µs, p99 92.2 | 92.2 ok | 108.5, NOISY (43%) | **disagrees**: not a headline; CPU 65.4 µs/hop agrees |
| spin | H4 go cap 20: p99 12.0, util 0.375 | as stated | 12.0; 0.376 to 0.384 | confirmed; "no rule met both" strengthened |
| spin | H5 collapse above 4 is oversubscription | 4 k hops/s at W=5 in every pin mode | same medians within 6%; several "ok" now NOISY | within-noise |
| switch | Go pingpong | 388.05 / pinned 398.52 | 379.51 / 400.15 | confirmed |
| switch | tokio pingpong | 401.33 / 385.08 | 402.11 / 384.78 | confirmed |
| switch | tokio pingpong_local | 194.63 | 197.27 | confirmed |
| switch | Go spawn+join | 485.60 / 465.96 | 444.03 / 436.36 | confirmed (systematically 6 to 9% lower) |
| switch | tokio spawn_batch m64 | 204.49 | 207.55 | confirmed |
| switch | ren_c fanout_yield | 5.22 | 5.16 | confirmed (includes 0.1 spawn per op) |
| switch | raw_c fanout_yield | 3.26 | 3.24 | confirmed |
| switch | raw_c park wake (clean headline) | 7.01 (9.4%) | 8.54 / 8.04, NOISY; 11 of 12 tries NOISY overall | **disagrees**: NOISY, not a headline |
| switch | Go park wake | 836.74 | 810.61 | confirmed |
| switch | ren_c parked task size | 128 B | 128 B | confirmed |
| switch | (not headline) ren_c pingpong | 18.12 / 17.06 NOISY | 16.38 NOISY / 16.36 clean | within-noise |
| switch | (not headline) ren_c spawn_join; spawn_batch m64 | 13.59; 8.57 NOISY | 15.46; 8.53 NOISY | within-noise |
| switch | (not headline) ren_c park wake | 11.12 / 9.90 NOISY | 9.94 clean / 9.51 NOISY | within-noise |
| switch | (not headline) raw_c pingpong; ratio < 3× | 7.81 / 7.32 NOISY; 2.32× | 7.32 / 7.22 NOISY; 2.24 to 2.27× | within-noise |

**Harness caveats from VERIFY that change how numbers read.**

- **percore.** Percentiles are bucket lower edges (~3% low).
- **spin.**
  - Its histogram has 16 buckets per octave, so the 10% gate is 2 to 3
    buckets wide.
  - With `--pin auto` and W > 4, auto and off are the same placement.
- **switch.**
  - fanout times include spawning the tasks.
  - tokio numbers carry a counting allocator's atomics.
  - The script keeps the best of three tries, which favours lucky tries.
- **k1b.** sim hard-codes parts = 8. The parts invariance is true by
  construction.

No harness bug invalidating a number was found in any experiment.

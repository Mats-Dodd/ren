# K1b early results

Measured 2026-10-29, 21:04 to 22:49, on the M4 Max. Nothing else of ours ran at the same time.
Every threaded row is 7 reps of 200 ms after a 200 ms warm-up. Each number is the median.
Raw lines are in `results/*-20261029-*.txt`. The full analysis is in `results/analysis.txt` (`python3 -I analyze.py results`).
The checks passed on all 660 threaded rows (`ok=1`). C and Rust agreed bit for bit on all 32 simulator traces.
The victims of s3, s5, s10 and clock did not change with parts, in all 8 cases. plru's did, as expected.

Load was high. The median 1-minute load was 3.1 (range 2.5 to 8.1), and 310 of 576 throughput rows started above 3.
48 of 660 rows are noisy: their max minus min is more than 25% of the median. Most are scan rows, or uniform rows at 12 and 16 workers.
Read absolute numbers as ±40%. The ratios that decide anything below are 2× or more.

## The answer for step 7

**The use stamp fixes phase 1's problem. 16 workers on b do 9 to 16× what 16 workers do on a.**
On uniform keys at 16 workers, a does 8 Mops/s at max 10k and 24 at 50k. b does 122 and 210.
a gets slower as workers are added: 16 workers do 0.14 to 0.5× one worker. b never falls below one worker on uniform keys.

**Sampled eviction costs almost no hits.** k=5 is within 0.55 points of exact LRU everywhere. k=10 is within 0.23 points.

**But b does not scale past one cluster.** b peaks at 4 workers (233 to 242 Mops/s, 3.5× one worker). At 8 workers it drops by a third, then stays flat.
The M4 Max's P cores share an L2 in clusters of 6. Past one cluster, a hit on an instance last written on the other cluster pays a cross-cluster line transfer.
This is the instance line, not the bookkeeping. PLAN.md says that's what to look at next: per_core placement.

**Hot keys are the other limit.** On Zipf 0.99 every variant collapses past 4 workers. b falls from 88 to 17 Mops/s at max 10k. a falls from 64 to 5.
b is still 3.4× a there. os_unfair_lock helps b 2.3× at 16 workers (38 against 17 Mops/s), because waiters sleep instead of fighting over the line.

So the plan's first branch holds: build `take` to store a use stamp, and let `actors` evict by sampling with k=5. The RNG comes from the tape under `sim`.
Partitions leave `actors`' meaning. `parts:` becomes a map-sharding detail. It no longer changes which key is evicted.

## Headline table

| # | prediction | measured | held? |
|---|---|---|---|
| 1 | 1 worker, C: b is 1.5–2× a at 10k, ~1.3× at 50k; b at 4–6 ns | b/a 1.25–1.37 at 10k, 1.29–1.52 at 50k; b at 11–16 ns, a at 16–21 ns | no at 10k, yes at 50k; ns wrong |
| 2 | uniform: b at 16w ≥ 6× b at 1w; a at 16w ≤ 1.5× a at 1w; **b16 ≥ 4× a16 (decides step 7)** | b 16w/1w 1.75 (10k), 3.38 (50k); a 0.14, 0.49; **b16/a16 15.8 (10k), 8.9 (50k)** | **decider held**; b's scaling did not |
| 3 | Zipf 0.99: b 16w/1w 1.5–3×; a under 1× | b 0.19–0.23; a 0.08–0.15 | no for b; yes for a |
| 4 | 16w p99: b, c under 300 ns uniform; a over 1 µs; zipf99 b ≥ 3× lower than a | uniform b 333 ns (10k), 167 ns (50k); a 4.2–35 µs; zipf99 b 20–23 µs, a 39–58 µs (2.0–2.5×) | mostly; zipf99 part no |
| 5 | b and c within 10% on hits | 67 of 72 hit rows (scan excluded) | yes |
| 6 | Rust within 15% of C | 99 of 144. a: 44/48. b and c: Rust is ~10% faster in the median, up to 1.7× | partly (Rust faster, not slower) |
| 7 | os lock costs a little alone; a falls further under contention; b barely changes | alone: os costs 11–24%. At 16w os beats spin: a 1.0–1.4×, b 1.0–2.4× | first part yes, rest no |
| 8 | a improves with parts; b flat within 10% | a: parts 64 vs 1 is 4.9–24×. b: within 4%, except one noisy row (uniform, 16w, parts 8: 207 vs 134) | yes |
| 9 | miss path, 1 worker, uniform u=2: a beats b(k=5) by 10–30%; k=10 costs more than k=3 | a/b 1.24 at both sizes; k3 19 vs k10 17 Mops/s | yes |
| 10 | ≥8 workers, u=2: b ahead of a; c behind b | b/a 1.0–4.1 (tie on uniform, ahead on zipf and scan); c/b 0.47–0.85 | partly; c part yes |
| 11 | retries under 20% of misses | up to 2.35 retries a miss at 16w, max 10k; 0.08–0.54 at 50k | no |
| 12 | uniform hit rate = max/U ± 0.3 pt | within 0.18 pt | yes |
| 13 | zipf: k10 within 0.3 pt of LRU, k5 within 1, k3 within 2, clock within 1.5 | k10 −0.23, k5 −0.55, k3 −1.12, clock −1.15 at worst | yes |
| 14 | scan: sampled and clock within 2 pt of LRU or better; k3 best | k3 +0.55 to +1.84, k5 −0.11 to +0.23, clock −0.56 to −0.79 | yes |
| 15 | plru within 0.1 pt of LRU (up to 1 at U=1.25) | within 0.03 pt everywhere | yes |
| 16 | s*/clock victims independent of parts; plru not | 8 of 8 ok=1 | yes |
| 17 | 50k × 32 B: 6.4 MB vs 2.8 MB (+129%) | 6.4 vs 2.8 MB (+128.6%); footprint agrees | yes |
| 18 | 50k × 256 B: 19.2 vs 14.0 MB (+37%) | 19.2 vs 14.0 MB (+37.1%) | yes |
| 19 | map ~31 B an instance | 31.5 B | yes |

## Things the plan didn't expect

- **The miss path's retries are high.** At 16 workers and max 10k, b retries 2.35 times a miss. The harness counts failed claims, busy victim shards and stale reads together, so the split isn't known.
  Throughput still matches a there, so this costs little now. It would grow with more workers. More shards for the map's write lock is the likely fix; it's untested.
- **The single-worker hit is 11 to 16 ns, not 4 to 6.** a is 16 to 21 ns, about twice phase 1's 8 to 9 ns. The harness does more per `at` than phase 1's: a stream read, a hash and a probe.
  The ratio is what matters, and b is 1.25 to 1.5× a.
- **Under hot-key contention os_unfair_lock beats the spin lock** by up to 2.4×. A runtime's instance lock should park, as phase 1's hybrid lock does.
- **CLOCK's global hand hurts at 8+ workers on misses** (0.47 to 0.85× b). So sampling, not CLOCK.

## Rows not to trust

No row failed a correctness check. These rows are noisy (spread over 25%) and shouldn't be read alone:
uniform at 12 and 16 workers on b and c at max 10k; most scan rows at max 50k; c_clock on scan at 12 and 16 workers.
The 16-worker uniform b number at max 10k ranges from 120 to 213 Mops/s across reps. Even its minimum is 15× a.

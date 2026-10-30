# K1b: the keyed instance family's hit path and eviction

Runtime phase 2. This decides how briefs/stage-services.md step 7 builds
`actors`: "partitions and LRU eviction under `max:`" as decision 18 says
now, or "the runtime records each use, the library chooses the victim".

The runtime model agreed today: the language owns meaning; the runtime
owns time, order and place. The keyed instance family is a runtime
primitive. Its `take` records each use. Which instance to evict is the
library's (`actors`, `striped`, a third party's).

Phase 1 (experiments/many-cores, K1) found the hit path is the cost. An
`at` is three lock round trips, two on the partition's line. At 16
workers, 64 partitions still did less work in total than one worker.
SYNTHESIS.md asked for K1b: a cheaper hit, and whether 16 workers then
beat one.

Status: built and smoke-tested only. No measurement has been run.

## Files

| file | what |
|---|---|
| `c/common.h`, `rust/src/common.rs` | phase 1's generator, hash and Zipf, plus the K1b workloads. Same bits in both |
| `c/k1b.c`, `rust/src/bin/k1b.rs` | threaded: variants a, b, c; throughput and p50/p99 of one `at` |
| `c/sim.c`, `rust/src/bin/sim.rs` | single-threaded, deterministic: hit rate of every policy on one trace |
| `c/mem.c` | memory: one cache line per instance at 50k actors |
| `build.sh` | `clang -O2` and `cargo --release` into `bin/`; `--tsan` adds `bin/k1b_c_tsan` |
| `measure.sh` | every configuration as its own command, one at a time, one line each |

## The three variants

Every variant uses the same instance: one 128-byte line holding its lock,
a pin word, its key, a use stamp and its state. The operation is the same
in all three: take the instance's lock, add 1 to the state, let go. So the
only differences are the map, the pin and the LRU bookkeeping.

**a_lru: phase 1's `actors` model.** This is many-cores/k1k2/c/k1.c, with
misses added. A family is `parts` partitions. Each has a lock, an
open-addressing map, an exact LRU list and a cap of max/parts. One `at`:

1. Lock the partition, find k, pin it. Pinning 0 to 1 unlinks it from the
   LRU list. Unlock.
2. Take the instance's lock for one call. Let go.
3. Lock the partition, unpin. Unpinning 1 to 0 pushes it at the
   most-recently-released end. Unlock.

A miss, under the partition lock, evicts the partition's LRU tail when the
partition is at its cap. The victim's `finally` runs on the caller.

**b_sampled: "touch is the runtime's, choose is the library's".**

1. Read the shard's map with no lock (see "The read-mostly map").
2. Pin with one atomic add on the instance's own line. If the evicting bit
   is set, or the instance no longer holds k, unpin and look again.
3. Take the instance's lock. Store the use stamp with a relaxed store.
   Let go. Unpin with an atomic subtract.

So a hit writes only the instance's line. The map's lines are read-shared.

A miss takes its shard's writer lock and rechecks. While the family has
fewer than max instances, it takes a fresh slot. When it's full, it
samples K slots with a seeded RNG (K = 3, 5, 10). It skips pinned ones,
and evicts the one with the oldest stamp. It claims the victim with
CAS(pin word, 0, EVICTING), which fails if anyone holds a pin. If the
victim lives in another shard, it try-locks that shard. If that fails it
gives the claim back and samples again, so it never waits holding a lock.
The cap is one global max, not per partition.

The stamp is the runtime's per-worker clock (`mach_absolute_time`, 24 MHz),
refreshed every 16 calls. A runtime keeps such a clock per worker anyway.
Two uses less than about 16 calls apart can tie. At max = 10k, an evicted
instance was last used thousands of calls ago, so ties don't change
choices. The simulator uses the access's index, an exact clock.

**c_clock.** As b, but the take stores a use bit (1), and a full family
runs a CLOCK hand: a global atomic counter over the slots. A set bit is
cleared and passed, and the first clear bit that can be claimed is the
victim. One difference from textbook CLOCK: if the victim's shard is
busy, the claim is given back and the hand moves on. That victim survives
this sweep.

### The read-mostly map (b, c)

Each shard is an open-addressing table with linear probing and
backward-shift delete. Only writers change it, under the shard's lock.
Readers probe it with acquire loads and take no lock.

It isn't a sharded reader-writer lock. A reader-writer lock's readers
write its counter, so every hit would move that line between cores, which
is phase 1's problem again. It's closer to a seqlock, but the reader
checks at the instance, not with a version per shard:

- A reader may see a torn or stale table. It never trusts the slot it
  finds. It pins the slot, backs off if EVICTING is set, then checks the
  slot's key is still k.
- An evictor claims a slot with CAS 0 to EVICTING. It clears EVICTING with
  a release `fetch_and` after it has written the new key.
- The pin word's read-modify-writes are totally ordered. So a reader's pin
  either makes the claim fail, sees EVICTING, or sees the new key.
- A reader that misses by mistake (the table was mid-shift) takes the miss
  path. That locks the shard and rechecks, so it finds the key.

Only the miss path, under the shard's lock, adds a key to a shard. So one
key never has two slots.

### Does parts still pick the victim under b?

It shouldn't. Under b and c, `parts` shards only the map's write lock. The
victim is chosen from the slab of slots, by RNG and stamps (or the hand),
and never reads the map. So the same trace and seed evict the same keys at
any `parts`. This is by construction. `measure.sh parts` checks it: the
victim sequence's fingerprint (`vh_*`) at parts 1, 8 and 64 must be equal
for s3, s5, s10 and clock. Under a (`plru`) it changes with parts, as K2
found.

This matters for decision 18. "Each partition has its own exact LRU and a
cap of max/parts" is what makes a journal replay on any number of threads
today. Under b, replay needs the victim choice to depend only on the
schedule, the clock and `Random`, and not on `parts` or the thread count.
That holds if the sampling RNG comes from the tape under `sim`.

## Workloads

Keys come from per-worker streams, made before timing (2^19 keys each, the
same seeds as phase 1).

- `zipf99`: Zipf(0.99) over universe U. `zipf70`: Zipf(0.7) over U.
- `uniform`: uniform over U.
- `scan`: half Zipf(0.99) over U, half a cyclic loop over 1.5 × max keys,
  disjoint from the hot keys. The loop is larger than max, so exact LRU
  never hits on it. In the threaded runs, each worker's loop starts at a
  different offset.

U = universe × max. Threaded runs use two universes:

- `0.9` is **the hit path.** Every key fits, so after the warm-up rep
  almost every access is a hit. a's partitions are capped at max/parts, so
  0.9 leaves room for hash imbalance. scan still misses.
- `2` is **the miss regime.** Half the keys can't be resident.

The simulator uses universes 1.25, 2, 4 and 10.

max = 10,000 and 50,000. parts is phase 1's suggested default, the largest
power of two at most max/1024 (8 and 32), unless `--parts` is given.
Workers: 1, 2, 4, 8, 12, 16.

## Why each comparison is fair

- **Same instance layout.** All three use one line per instance, with the
  lock and state in it. Only the bookkeeping differs.
- **Same operation, streams, seeds, locks and parts.** The `spin` lock is
  phase 1's TTAS with `isb`. `os` is `os_unfair_lock`. The lock kind is
  one predictable branch, the same in every variant.
- **Same timing as phase 1.** Each run has one untimed warm-up rep, then
  5 reps of 200 ms. It reports the median Mops/s, the min and the max.
  One `at` in 16 is timed with `mach_absolute_time`. Its tick is 41.7 ns,
  so p50 under contention is meaningful but uncontended p50 reads 42 or
  83. Use Mops/s for the uncontended cost.
- **Same threads.** `QOS_CLASS_USER_INTERACTIVE`, as phase 1. Runs at 13
  to 16 workers use efficiency cores.
- **Each variant's real policy.** a keeps exact LRU per partition, with a
  cap per partition. b and c keep one global cap. Each is what it would
  ship.
- **Hit rate comes from the simulator, not the threaded runs.** Threaded
  hit rates depend on interleaving and on streams wrapping. The simulator
  runs every policy on one recorded trace, single-threaded. It uses the
  same slab-plus-sharded-table structure, and the C and Rust must agree
  bit for bit.
- **C and Rust both.** These are the same algorithm with the same atomics
  and orderings. Rust uses `UnsafeCell` where the C uses plain fields
  under a lock.

## Correctness checks

Every check runs after every rep, with the workers joined. A failed check
prints `FAIL:` on stderr and exits non-zero. Otherwise the line ends in
`ok=1`.

- hits + misses = operations.
- The sum of live states plus the states of evicted instances (added up
  in `finally`) equals every operation ever run. So no operation was lost
  or ran on a dead instance.
- Nothing is pinned or claimed at rest.
- Slots and table entries are a bijection: each live slot's key maps back
  to that slot, and each shard's entry count matches its count. The total
  is the number of slots, at most max.
- a: each partition is at or below its cap, and its LRU list holds
  exactly its instances.
- Simulator: the same checks per policy. C and Rust print identical lines
  (`k1b_sim_agree`). s* and clock victims are independent of parts
  (`k1b_parts ... ok=1`).
- ThreadSanitizer: `bin/k1b_c_tsan`, every variant, 4 workers, parts 1
  and 8, scan at universe 2 (so eviction races are exercised). Run by
  `./measure.sh --smoke`. It was clean on 2026-10-29.
- mem: alignment, and the written bytes read back.

## Predictions

These were written before any measurement. While building, I saw these
only as checks that the code worked: 10 to 20 ms threaded smoke runs, the
simulator at max 10,000 and universe 2, and mem's arithmetic. The
simulator predictions for max 10,000 and universe 2 aren't blind.

**Hit path, threaded (universe 0.9).**

1. **One worker, C, spin:** b and c do 1.5 to 2× a's Mops/s. That's one
   lock round trip plus two atomics on one line, against three lock
   round trips on two lines. Phase 1's a was 8 to 9 ns an `at`. I expect
   b at 4 to 6 ns at max 10k. At 50k, more of the time is cache misses
   into a 6.4 MB slab, so the gap is nearer 1.3×.
2. **Scaling on uniform keys:** b and c at 16 workers do at least 6× one
   worker. A hit writes only its instance's line, and with 10k to 50k
   instances, two workers rarely touch the same line. a stays near phase
   1: 16 workers do at most 1.5× one worker at the derived parts (8, 32).
   **This is the result that decides step 7.** If b at 16 workers isn't
   at least 4× a, the use-stamp design doesn't fix phase 1's problem.
3. **Zipf(0.99):** the hot keys' lines move between cores in every
   variant. b at 16 workers does 1.5 to 3× one worker, and a does under
   1×. Zipf(0.7) lands between Zipf(0.99) and uniform.
4. **p99 at 16 workers:** b and c stay under 300 ns on uniform keys. a is
   over 1 µs, as phase 1. On zipf99, b's p99 is at least 3× lower than
   a's.
5. **b and c are within 10%** on the hit path. They differ only in the
   value stored.
6. **Rust is within 15% of C** in every hit-path configuration.
7. **os_unfair_lock** costs a little uncontended (phase 1: 15 ns against
   8 to 9). Under contention a with os parks, and its Mops/s falls further.
   b barely changes, because its one lock is rarely contended on uniform
   keys.
8. **parts on the hit path:** a improves with parts (phase 1). b doesn't
   change with parts on hits, within 10%, because readers write nothing in
   the shard.

**Miss regime, threaded (universe 2, and scan).**

9. **One worker:** a's miss is O(1): unlink the tail. b's miss reads K
   random instance lines to sample, about 5 L2 or DRAM reads. So a beats b
   (k=5) by 10 to 30% at one worker on uniform at universe 2, and k=10
   costs more than k=3.
10. **At 8 or more workers,** b is ahead of a. The misses parallelize
    across shards, and the hits stay cheap. c falls behind b at 8 or more
    workers on uniform and scan, because every hand step is a
    `fetch_add` on one global line.
11. `retries` grows with workers in b and c (failed claims, busy victim
    shards, stale reads). It stays under 20% of misses.

**Hit rates (simulator: deterministic, the same trace for every policy).**

12. **Uniform:** every policy gets max/U ± 0.3 percentage points. This is
    a sanity check.
13. **Zipf(0.99) and Zipf(0.7):** sampled k=10 is within 0.3 points of
    exact LRU, k=5 within 1 point and k=3 within 2 points. CLOCK is
    within 1.5 points. The gap grows as U grows toward 10 × max, and
    stays under 2 points for k=5.
14. **scan:** exact LRU gets nothing on the loop half. Sampled and CLOCK
    keep part of the loop by chance, so they match LRU within 2 points
    or beat it slightly. k=3 does best on scan, because it's the most
    random.
15. **plru (a) against lru:** within 0.1 points at U ≥ 2 × max, and up
    to 1 point at 1.25 (K2).
16. **parts:** `vh_s3`, `vh_s5`, `vh_s10` and `vh_clock` are identical at
    parts 1, 8 and 64 for every workload. `vh_plru` differs.

**Memory (arithmetic; mem confirms it with phys_footprint).** The
instance header is lock 4 + pin 4 + key 8 + stamp 8 = 24 B.

17. At 50k actors with 32 B of state: one line each is 6.4 MB, against
    2.8 MB packed (+3.6 MB, +129%).
18. At 50k actors with 256 B of state: 19.2 MB, against 14.0 MB packed
    (+5.2 MB, +37%). The state is 280 B with the header, so it pads to 3
    lines.
19. The map adds about 31 B per instance at parts 32 (1.6 MB at 50k).
    So the line costs at most 104 B per instance, about 5 MB at 50k. For
    flottning-sized families this is small next to the state.

### What would change the plan

- If 2 and 4 hold, and 13 holds for k=5: step 7 builds the family's
  `take` to store a use stamp, and `actors` evicts by sampling (k=5, RNG
  from the tape under `sim`). Partitions stop being part of `actors`'
  meaning. `parts:` becomes a map-sharding detail the runtime picks, and
  decision 18's "each has its own exact LRU and a cap of max/parts" goes.
- If b's hit path scales but sampled hit rates miss by more than 2
  points: keep the stamp, and choose by CLOCK or larger k.
- If b doesn't scale: the cost isn't the LRU bookkeeping. Look at the
  instance line itself (per_core placement, the next experiment).

## How to run

```
./build.sh --tsan                # bin/k1b_c bin/k1b_rust bin/sim_c bin/sim_rust bin/mem_c (+ bin/k1b_c_tsan)
./measure.sh --smoke             # TSan once, tiny configs, C = Rust on the simulator. Not timing.
./measure.sh --list              # every command a full run executes (754), one per line
./measure.sh sim parts mem       # deterministic sections: about 2 minutes
./measure.sh throughput          # 576 threaded runs, about 15 minutes
./measure.sh extras              # 84 runs: os lock, k = 3 and 10, parts 1/8/64
./measure.sh                     # all of the above, in that order
```

Environment: `REPS` (5), `MS` (200), `WARM_MS` (200), `WORKERS`
(1,2,4,8,12,16), `QOS` (p). `LOAD_MAX` (4): before each threaded run, wait
up to `LOAD_WAIT` seconds (300) while the 1-minute load average is above
it. The machine is shared, so each threaded line gets `load1=` appended.

Results go to `results/<section>-<stamp>.txt`, one line per configuration.
`results/<section>-<stamp>.log` holds each command, its load average and
any failure. The script exits non-zero if any configuration failed.

A single configuration, for example:

```
bin/k1b_c --variant b_sampled --k 5 --lock spin --dist zipf99 --max 10000 --universe 0.9 \
  --workers 16 --reps 5 --ms 200 --warm-ms 200 --qos p
bin/sim_c --dist scan --max 50000 --universe 2 --parts 1
bin/mem_c --layout line --n 50000 --state 256
```

The output fields:

- `k1b`: `lang variant k lock dist max universe parts workers reps ms
  mops_median mops_min mops_max at_p50_ns at_p99_ns hit_rate hits misses
  evictions retries ok`. `evictions` counts from the start, warm-up
  included.
- `k1b_sim`: `hit_<p>`, `hits_<p>`, `ev_<p>` and `vh_<p>` for each policy
  p in lru, plru, s3, s5, s10, clock. The hit rate is measured after a
  warm-up of max(10 × max, 4 × U) accesses, over 20 × max accesses.
- `k1b_mem`: `layout n state sizeof side bytes per_instance
  over_packed_bytes over_packed_pct footprint_delta table_bytes
  table_per_instance ok`.

mem is C only. The Rust layout is the same `repr(C, align(128))`.

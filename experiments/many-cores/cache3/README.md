# The same cache three ways

This is phase one of the many-cores experiments (foundations.md, Staging):
a read-mostly cache whose misses fetch, written as one handler, as
`striped` by key and as `actors`, and compared with Rust's dashmap and
moka. It measures throughput and latency at 1, 2, 4, 8, 12 and 16
workers on the M4 Max.

```
./build.sh          # bin/cache3_c (clang -O2), bin/cache3_c_tsan, bin/cache3_rust (release)
./run.sh --quick    # smoke + correctness, a few seconds; exits non-zero on failure
./run.sh            # full: REPS=5 OPS=200000 WORKERS="1 2 4 8 12 16" EXTRA="..."
```

Full mode prints one line per (impl, variant, workers) as `key=value`
tokens:
`impl variant workers reps ops mops_median mops_min mops_max p50_ns p99_ns
p999_ns p99_hit_ns hit_pct misses fetches coalesced dup_fills evictions
resident fetch_avg_us checksum ok`. Throughput is the median over reps.
Each percentile is the median of the per-rep percentiles. `p99_hit_ns`
covers only the operations that hit, which shows whether hits wait behind
misses. The overall p99 is a miss whenever more than 1% of operations
miss, as they do here.

## Workload (identical in C and Rust)

- **Keys and access pattern.** 20,000 keys, Zipf(1.1), capacity 16,000.
  Each run starts with the 16,000 hottest keys preloaded, then each worker
  runs `OPS` operations from its own deterministic stream (splitmix64).
- **Read/write mix.** 95% `get(k)` and 5% `update(k)`. An update is a
  read-modify-write: on a miss it fetches first, then stamps the value.
- **Steady-state hit rate.** About 98% with one LRU. Split caps lower it
  (see below). `--keys/--cap/--zipf` move it.
- **The fetch.** A 50 µs fetch is a **spin** on `mach_absolute_time`
  (the default). A 50 µs `nanosleep` on this macOS takes about 250 µs
  from a normal thread because of timer slack, so it isn't usable. The
  `--fetch sleep` option exists and reports the real mean as
  `fetch_avg_us`. Each worker runs one task, so a parked worker would
  have nothing else to run anyway.
- **Threads.** Workers are pthreads at `QOS_CLASS_USER_INTERACTIVE`,
  which prefers P-cores. macOS can't pin threads, so above 12 workers
  some run on E-cores.
- **Timing.** Latency is timed per operation with `mach_absolute_time`,
  whose tick is 41.7 ns. It goes into a log-linear histogram with about
  1.5% buckets.

## Variants, and how they map to Ren

| variant | Ren program | model |
|---|---|---|
| `one_hold` | `with cache(store) as Cache`, where `get` calls `store.fetch(k)` | one instance: an `os_unfair_lock` (C) or `parking_lot::Mutex` (Rust) plus the state, which is a chained hash map with an exact intrusive LRU. Decision 10: the operation **keeps the instance across the fetch**. |
| `one` | the same handler, with `release store.fetch(k)` | lock, then miss, **unlock, fetch, relock**, then look the key up again, since state may have changed under `release`. If it's there, that counts as a `dup_fill` and the fetch is discarded. |
| `striped16`, `striped_hold16` | `striped(cache(store), n: 16, by: Key)` | 16 of the instances above, each padded to 128 B, routed by `mix64(key) % 16`. Each has its own LRU and a cap of 16,000/16. |
| `actors_p16`, `actors_p64` | `actors(entry, max: 16_000, parts: P)` with `try Cache.at(k) fn() => Entry.get()` | 16 or 64 partitions, each with a lock, a map, an exact LRU by last release and a cap of max/P. `at`: lock the partition, then find and pin, or evict the least recently released unpinned actor, insert a pinned actor in setup and unlock. **Setup is the fetch.** Callers that find the actor still in setup pin it and wait on the partition's condvar, which counts as `coalesced`. The operation takes the actor's own lock for one call. Leaving `at` locks the partition again to unpin and move the actor to the front. A victim's `finally` (a `free`) runs on the caller's task after the partition lock is dropped. |
| `dashmap` | (baseline) | `DashMap` with the same hasher. A miss fetches outside any shard lock, then calls `entry().or_insert`. It is **unbounded**: there is no eviction, so its hit rate is higher and it is not like-for-like. |
| `moka` | (baseline) | `moka::sync::Cache` with `max_capacity` 16,000 and the same hasher. It uses `get_with`, which coalesces concurrent misses, and an update calls `insert` after `get_with`. TinyLFU admission gives it a different hit rate. Coalesced waiters count as hits, and evictions aren't counted. |

Rust runs the same Ren variants with `parking_lot`. parking_lot barges
and hands off fairly every ~0.5 ms, which is closer to decision 10's
"fair, not first in first out, no waiter passed over without bound" than
macOS's `os_unfair_lock`. That lock barges and has no starvation guard,
and it is what the C uses.

## Correctness checks (every run, every rep; `ok=1`)

- **Value integrity.** Every value read carries `key`, `check(key)` and
  `stamp_chk(key, stamp)`. A torn or misrouted value is counted as `bad`.
- **Checksum.** The sum of `check` over all reads is fixed by the op
  streams, so it must be the same across reps, variants and C/Rust. The
  `--quick` mode asserts this for all 14 configs at 1 and 4 workers.
- **Counters.**
  - `hits + misses + coalesced == ops`
  - `fetches == misses`. For actors this means one fetch per setup.
  - `prefilled + inserts - evictions == resident`
  - `resident <= cap`. dashmap is the exception.
- **ThreadSanitizer.** `--quick` runs every C variant under ThreadSanitizer
  and reports it clean.

## Fidelity: what's uncertain

- **One thread per worker, one task per thread.** A waiter blocks or
  parks its thread inside the OS lock, where Ren would park the task and
  run another, so this doesn't model task switches. For actors' setup
  waits, a condvar stands in for parking.
- **The C lock is not Ren's fair lock.** `os_unfair_lock` can starve a
  waiter, and the C has no 1 ms guard. The Rust side's `parking_lot` is
  the closer model.
- **Actors pay three lock acquisitions per hit:** the partition to pin,
  the actor for the operation, and the partition again to unpin and touch
  the LRU. That follows decision 18 as written ("locked partitions, an
  actor's lock per call"; LRU by *release*). An implementation that pins
  with an atomic and touches the LRU lazily would be cheaper, and that is
  a design choice, not settled.
- **`one` and `striped` with `release` don't coalesce misses.** Two
  callers missing one key both fetch (`dup_fills`), because that is what
  the straightforward Ren handler does. Coalescing would need a pending
  set and `Async.until`. Actors coalesce for free through setup.
- **Split caps lower the hit rate.** A cap of max/n per stripe or
  partition loses hit rate (98% → ~95–97% on short runs) because hot keys
  aren't spread evenly. That is K2's question, and it shows here as extra
  misses, so compare `hit_pct` alongside throughput. Use
  `EXTRA="--fetch-us 0"` to isolate the cost of the structure itself.
- **What isn't modelled.** Values are 32-byte plain structs that are
  copied out, so there is no refcounting and no shared marking (K3's
  question). Ren's state map would be a Ren `Table`. The C mallocs each
  entry, and the Rust uses a slab.
- **Unbounded dashmap.** It isn't a cache, so it isn't a like-for-like
  baseline.

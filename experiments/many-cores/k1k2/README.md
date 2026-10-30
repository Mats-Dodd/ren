# K1 and K2: an actors family's partitions

Phase one of the many-cores experiments (foundations.md, Staging). These
are prototypes of the `actors` service's runtime (decision 18), in C
(`clang -O2`) and Rust (release, no crates), on the M4 Max.

```
./build.sh            # bin/k1_c bin/k2_c bin/k1_rust bin/k2_rust (--tsan adds bin/k1_c_tsan)
./run.sh --quick      # smoke: builds with TSan, runs it once, checks C and Rust K2 agree
./run.sh              # full: one key=value line per configuration on stdout
```

Full-mode knobs are environment variables: `REPS` (5), `MS` (200 per
rep), `KEYS` (10000 live actors), `WORKERS` (`1,2,4,8,12,16`), `QOS`
(`p`, `e`, `none`). The binaries take the same as flags (`--workers`,
`--parts`, `--dist`, `--lock`, `--keys`, `--reps`, `--ms`, `--qos`;
K2: `--max`, `--parts`, `--factors`, `--warm`, `--measure`).

## K1: `at(k)` on a hit

What `try Docs.at(k) fn() => Doc.op()` costs when k's actor is live, at
1 to 16 workers, with 1, 8 and 64 partitions, keys uniform or Zipf(1.1)
over 10,000 live actors.

**The model.** A family is `parts` partitions, each 128-byte aligned,
with its own lock, open-addressing map (key to actor) and exact LRU list
(decision 18, "A family is split into partitions"). The partition is
`hash(k) >> 32 mod parts`. An actor is a 128-byte-aligned struct: the
instance's lock and its state (decision 10's exclusion), plus `pins`
and LRU links that its partition's lock guards. One `at` is:

1. **Enter:** lock the partition, look k up, pin. Pinning 0 to 1 takes
   the actor off the LRU list, since a pinned actor isn't evictable, so
   the list holds exactly the evictable actors. Unlock.
2. **Body:** one operation, which takes the actor's instance for one
   call (decision 10, decision 18's "Holding"), adds 1 to its state and
   lets go.
3. **Exit:** lock the partition, unpin. Unpinning 1 to 0 pushes it at
   the most-recently-released end, so the tail is "the least recently
   released actor that's evictable", exactly. Unlock.

So a hit is three lock round trips, two of them on the partition. Two
lock kinds, both in both languages: `spin` (test-and-test-and-set,
`isb` while waiting, what a runtime's short internal lock would be) and
`os` (`os_unfair_lock`, which parks; the Rust calls the same C function).

**Output.** `k1 lang lock dist parts workers keys reps ms mops_median
mops_min mops_max at_p50_ns at_p99_ns`: throughput of whole `at`s over
`REPS` reps of `MS` ms, and the latency of one `at` in 16, timed with
`mach_absolute_time`. Its tick is 41.7 ns on this machine, so p50 of an
uncontended `at` (about 15 to 25 ns) reads 0 or 42: use `mops` for the
uncontended cost and the percentiles for contention tails.

**Threads.** Workers set `QOS_CLASS_USER_INTERACTIVE` (`QOS=p`, the
default), which macOS schedules on performance cores first; there's no
pinning API. At 16 workers four must run on efficiency cores. `QOS=e`
(`QOS_CLASS_BACKGROUND`) confines them to efficiency cores.

**Checks, every rep:** the sum of actors' states grew by exactly the
`at`s counted; no actor is left pinned; each partition's LRU list walks
to exactly its actor count, and they sum to the family. The C runs once
under ThreadSanitizer in `--quick` (both locks, 1 and 8 partitions).

## K2: a cap per partition against one global cap

Decision 18 gives each partition a cap of `max / parts` (the remainder
spread one each over the first partitions, so the total is `max`). K2
runs one trace of keys through one exact LRU with cap `max` and through
`parts` exact LRUs (8 and 64), and counts misses and evictions after a
warmup (12 × the key universe, enough to touch every uniform key). The
universe is `factor × max` for factors 1.0 to 10; keys uniform or
Zipf(1.1). Single-threaded and deterministic: the C and Rust share the
generator, hash and Zipf table bit for bit, and `run.sh` fails if their
counts differ.

**Output.** `k2 dist max parts cap_per_part universe accesses
global_misses part_misses global_evictions part_evictions
global_resident part_resident ... extra_miss_pct_of_global
extra_miss_pct_of_accesses`. The waste is `part_misses - global_misses`,
as a share of the global misses and of all accesses.

**Smoke results (max 1k/10k; the full run adds 100k).** For uniform keys
the waste is only where the working set is about `max`: at universe =
max the global cache stops missing and the partitions keep missing (3.5%
of accesses at 8 parts, 8.5% at 64 for max 1k; 1.4% and 3.6% at 10k),
since a partition's share of keys is binomial, so some overflow while
others sit part empty (resident 96% and 92%). At 1.1 × max it's 0.1 to
4% of accesses (1 to 46% of the global misses; the high end is 64 parts
at max 1k). From 1.5 × max on it's within ±0.5% of the global
misses, the trace's noise: the prediction holds there. Zipf(1.1)'s
global miss rate is low (0.6 to 5%), so the same few hundred extra
misses are a large *relative* waste but a small absolute one: at max
10k with 8 parts, 0 to 4% more misses (under 0.04% of accesses); with
64 parts, 10 to 17% more (under 0.2% of accesses); at max 1k with 64
parts (caps of 15), 95 to 174% more, about 1% of accesses. It fades by
1.5 × max as uniform's does.

## Fidelity to Ren's design, and what's uncertain

- **Exact LRU forces the partition lock on exit too.** Unpinning must
  move the actor in the list, so a hit takes the partition lock twice.
  A runtime could pin with an atomic on the actor and order releases
  lazily (a CLOCK bit or per-worker buffers, as Caffeine does), but then
  LRU isn't exact and `sim`'s eviction order isn't the runtime's. K1
  measures the design as written.
- **The body is one trivial operation.** A real `at` runs user code
  between enter and exit, which spreads partition traffic out; K1 is
  the worst case for the partition lock.
- **Waiters spin or park in the OS, not as Ren tasks.** Decision 10's
  instance queue parks *tasks* and is fair with barging; neither lock
  here is fair, and no task scheduler is modelled. Under Zipf the hot
  actor's lock is the bottleneck, which is a property of the key, not
  of the partitions.
- **Actors are padded to a 128-byte line,** so neighbours never share
  one; a heap of differently sized actors would sometimes.
- **K2 has no pins**, so every actor is always evictable; in a real
  family pinned actors make the global and the partitioned caps both
  wait or fail with `Full`, which K2 doesn't count.
- **`parts:`'s default from `max:` isn't decided;** K2 shows that
  caps of 15 (64 parts at max 1k) waste far more than caps of 125, so
  the default should keep `max / parts` large, perhaps at least a few
  hundred.

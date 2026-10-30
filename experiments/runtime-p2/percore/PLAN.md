# percore: per_core against work_stealing on a flottning-shaped kernel

Runtime phase 2. This experiment informs the runtime model's open question 2: does per_core
earn a place in 1.0? The model says "the language owns meaning; the
runtime owns time, order and place". Under `work_stealing` an operation
runs in the caller, which takes the instance's lock. Under `per_core` the
instance has a home core, and the caller hops to it. Phase 1 priced the
pieces: a take costs 0.5 to 3 ns, a spinning hop 105 to 385 ns, and a parked
hop 4 to 8 µs. This experiment puts them in a real kernel.

Status: built and smoke-tested only. No timing runs yet. The predictions
below were written before measuring.

## The kernel

flottning is a key-value store with a WAL, a memtable, a CLI and an HTTP server. The kernel is the
store's core:

- **Clients** issue `put(k, v)` and `get(k)`. Each worker runs one
  client in a closed loop over a pre-generated trace. Traces depend only
  on (seed, mix, dist, workers), so every variant runs the same requests.
- **Keys** are 1 to 2^20. The even keys are preloaded, so 512k entries
  exist at the start. Odd keys exist only once a put has written them.
- **Memtable:** an ordered map, a skip list (p = 1/4, up to 24 levels) in
  its own bump arena. It keeps the highest sequence number per key.
- **WAL:** a put appends (key, seq, value) to an in-memory buffer. The
  append assigns the seq. A group commits every `--group` appends (64)
  or when its first append is `--group-us` old (100 µs). Commit copies
  the group into the log and checksums it. `--fsync` also does a
  `pwrite` and `F_FULLFSYNC` per group. It's off by default.
- **put** = WAL append, then memtable insert. **get** = memtable lookup.
- A put returns after its append. It doesn't wait for its group to
  commit. So group commit sets the flush rate, not the put latency.
  RocksDB's default (no sync per write) works this way too.
- **Mixes:** 95/5, 50/50 and 5/95 get/put. **Keys:** uniform, or Zipf
  0.99. Under Zipf the hottest key gets 6.2% of requests, and the top 10
  get 18%.
- Values are 8 bytes. Under per_core a hop copies only a small message.
  Bigger values would add copying to the hops. That isn't measured here.

## Variants

Each variant has one binary and one `--variant` flag. All are C. I
skipped Rust because it isn't cheap here. Nearly all the code is runtime
machinery: the MPSC queue, ulock parking, the hybrid lock and QoS. A Rust
copy would be a line-by-line port. It would add no information, because
it carries no allocator or `Arc` story like K3's.

| variant | runtime | memtable | WAL | a request |
|---|---|---|---|---|
| `ws_one` | work_stealing | one instance, hybrid lock | one instance, hybrid lock | takes the WAL, then the memtable, in the caller |
| `ws_worker` | work_stealing + `striped(by: Worker)` | a stripe per worker, locked, padded | one shared instance | put: the caller's own stripe. get: **checks every stripe** and keeps the highest seq (the merge) |
| `ws_keyed` | work_stealing + `striped(by: Key(n: 16))` | 16 stripes **routed by key hash**, locked, padded | one shared instance | takes the WAL, then one stripe |
| `ws_sharded` | work_stealing, per_core's layout | a shard per worker, routed by the same hash as per_core | **a segment per shard**, under the shard's one lock | takes one shard lock, runs where it is |
| `pc_spin` | per_core | a shard per core, owned, no locks | a segment per core, owned | local key: runs inline. Other key: a **hop** to the owner's inbox; the reply comes back on the caller's inbox |
| `pc_park` | per_core | as `pc_spin` | as `pc_spin` | as `pc_spin` |

Notes:

- **Lock.** It's phase 1's hybrid lock (`k3/verify/k3_hybrid.c`): barge,
  spin `--lock-spin` polls (64), then park on the word with
  `os_sync_wait_on_address`. It has no 1 ms starvation guard; P3 found
  the guard fired on under 0.05% of releases.
- **Hop.** It's P1's Vyukov intrusive MPSC queue and its Dekker-style
  sleeping flag. Each core is both a client and a server. While its own
  request is away, the core keeps draining its inbox. So a core doesn't
  sit idle while it serves others. That's how Seastar works, and it's what
  a per_core Ren worker would do with a suspended task.
- **Idle under per_core.** If a core has no message to handle and
  no request it can issue, it is idle:
  - `pc_spin` polls its inbox `--spin` times (1000 isb, a few µs), then
    parks. This is the "spin-then-park waiter".
  - `pc_park` parks at once. This is the "pure park" waiter.
  - A sender wakes a parked owner. A reply wakes a parked requester.
- **`--inflight M`** (per_core only) gives each core M client tasks.
  `pc_spin_if4` and `pc_park_if4` in `measure.sh` use M = 4. A
  work_stealing worker has exactly one client: a lock wait is short, so
  in this C model extra tasks per worker have no counterpart. Compare
  `*_if4` with work_stealing only as "what pipelining buys per_core". It
  isn't a same-load comparison.
- **Sequence numbers.** The shared WAL hands out global seqs, so
  `ws_worker`'s highest-seq merge is exact. A sharded WAL hands out seqs
  per segment, which works because a key lives in exactly one segment.
- **fsync** (`--fsync`) runs inside the WAL operation, so it holds the
  WAL instance. That follows decision 10: "one slow call, an fsync,
  serializes that handler's operations". Under per_core it also blocks
  that core's gets. Under work_stealing it blocks only callers that queue on
  that WAL. It's off in the matrix. See "Optional" below.
- **No pinning on macOS.** Every thread runs at
  `QOS_CLASS_USER_INTERACTIVE`, as in phase 1. That prefers P cores but
  doesn't pin. So at 13 to 16 workers some threads run on E cores, and
  any thread can migrate. per_core's "home core" really means a home
  thread.

## Why each comparison is fair

- **Same requests.** Traces are fixed per (seed, mix, dist, workers),
  and `trace_sum` prints their hash. Every variant must end with the same
  set of present keys, `keyset_sum`. `measure.sh` checks this.
- **Same thread count.** N workers means N threads in every variant.
  Under per_core those threads are both clients and servers. Nothing gets
  an extra server thread.
- **Same data structure and op cost.** Every variant uses the same skip
  list, arena, WAL code and value function.
- **`pc_*` vs `ws_sharded` is the clean runtime comparison.** They have
  the same shards, hash, segments and preload placement. The only
  difference is how the caller reaches a shard: a lock where it is, or a
  hop to the shard's home. That is decision 2.
- **`ws_one`, `ws_worker` and `ws_keyed`** are the layouts a program would
  get from `std` without writing a sharded store: one handler,
  `striped(by: Worker)` and `striped(by: Key)`. They show what the
  layout costs on its own, apart from the runtime.
- **What's not equal.**
  - per_core touches its shard on one core, so its tree stays warm in
    that core's cache. That's the advantage per_core exists for, so it
    counts.
  - per_core fills its memtable on the home thread. work_stealing fills
    it on the main thread. Apple silicon has no NUMA, so this only
    affects which cache starts warm.
  - Sharded layouts get smaller trees: 1M/N keys instead of 1M, so one
    or two fewer levels. `ws_sharded` gets the same benefit, so
    `ws_sharded` vs `pc_*` stays equal on this point.
- **Wall time** runs from the start barrier until the last worker
  finishes its own trace. Trace generation, preload and checking aren't
  timed. **CPU time** comes from `getrusage` over the same interval. It
  includes the per_core spinning that keeps going after a core's own
  trace ends.

## Correctness checks, every run

Each line ends with `ok=1` or `ok=0`. `ok=0` also prints `FAIL` lines on stderr.

- Every get that hits returns `valfn(key, seq)`. A get of an even key
  never misses, because preloaded keys are never removed.
- gets + puts equals the trace length. puts equals the WAL record count
  equals the trace's put count, segment by segment.
- Each WAL segment's seqs have no gaps. Every record's value is
  `valfn(key, seq)`. The checksum computed at commit matches a recompute.
  In a sharded WAL, every record belongs to the right segment.
- **Replay.** The log is replayed into "highest seq per key". Every key
  in the universe is then looked up in the final memtable(s), the way a
  get would. The key's presence, seq and value must match the replay.
- Every skip list is sorted at every level, and its node count is
  right. Except in `ws_worker`, nodes equal the keys present.
- Under per_core, the hops sent equal the hops served.
- Across variants, `keyset_sum` is equal at each (mix, dist, workers).
- ThreadSanitizer: `smoke.sh` runs every variant, including an
  `--fsync` run per runtime, under `-fsanitize=thread` on a small config.
  It's clean.

## Output

One line per run:

```
PC lang=c variant=pc_spin get_pct=50 dist=zipf theta=0.99 workers=8 inflight=1 stripes=8 keys=1048576
  ops_per_worker=200000 group=64 group_us=100 fsync=0 spin=1000 lock_spin=0 wall_ms= mops= p50_ns= p99_ns=
  get_p50_ns= get_p99_ns= put_p50_ns= put_p99_ns= cpu_ms= cpu_per_wall= hops_per_req= lock_slow_per_req=
  lock_parks_per_req= idle_parks_per_req= wakes_per_req= gets= hits= misses= puts= flushes= keys_present=
  nodes= trace_sum= keyset_sum= qos=user_interactive ok=1
```

- `mops` is total requests divided by wall time.
- The percentiles are per request: from issue to result, including the hop
  and the reply. They come from a log-linear histogram with about 3%
  resolution. The timer ticks every 41.67 ns.
- `cpu_per_wall` is the average number of busy cores.
- `hops_per_req` should be about (N-1)/N under per_core, and 0 under
  work_stealing.
- `lock_slow_per_req` counts contended takes, and `lock_parks_per_req`
  counts takes that went to sleep. `idle_parks_per_req` counts per_core
  parks. `wakes_per_req` counts both kinds of wake syscall.
- `stripes` is the number of stripes or shards. For per_core it's the
  core count.

## Predictions (written before measuring)

The only numbers seen so far come from one 4-worker build check: 50/50,
Zipf, 20k requests per worker. They were ws_one 3.4, ws_worker 3.3,
ws_keyed 9.7, pc_spin 7.2 and pc_park 0.6 M requests/s. That run came
before `ws_sharded` existed. Everything below is a prediction.

1. **1 worker:** all variants are within 25% of each other. There are no
   hops and no contention. `ws_keyed` and the sharded variants have small
   trees, but at N = 1 the sharded ones have a single tree, so `ws_keyed`
   is the fastest by up to 20%. `pc_*` and `ws_sharded` are within 10%.
2. **ws_one** peaks at 2 to 4 workers, around 3 to 4 M/s, then stays flat
   or falls. Its parks per request grow with workers. Among the spinning
   variants it has the worst p99 at 8 or more workers.
3. **ws_worker** is never the best. At 95/5, every get costs N lock
   takes and N lookups, so at 16 workers it falls below `ws_one`. At
   5/95 it's within 1.3× of `ws_keyed`, because both are capped by the
   shared WAL lock.
4. **The shared WAL caps puts.** At 95/5, `ws_keyed` and `ws_sharded` are
   within 20% of each other. At 5/95 with 8 or more workers,
   `ws_sharded` is at least 1.5× `ws_keyed`.
5. **Decision 2: `pc_spin` against `ws_sharded`, inflight 1.** I expect
   `ws_sharded` to win at every mix from 2 to 12 workers, by 1.2 to 2×.
   With N shards and N workers contention is low, so a take is mostly
   the uncontended 1 to 3 ns. `pc_spin` pays a 100 to 400 ns hop on
   (N-1)/N of its requests, on top of a 300 to 700 ns operation. The gap
   is smallest at 5/95, about 1.0 to 1.3×. Puts write tree nodes, and
   per_core keeps those lines in one cache while `ws_sharded` moves them
   between cores. I don't expect `pc_spin` to pass `ws_sharded` at
   inflight 1 in any configuration on uniform keys.
6. **E cores hurt per_core more.** From 12 to 16 workers, `pc_spin`'s
   ratio to `ws_sharded` gets at least 1.3× worse. A home core that
   lands on an E core slows every request that hops to it. Under
   `ws_sharded`, a slow thread slows only its own requests.
7. **pc_park** is 5 to 20× below `pc_spin` at inflight 1, with a p50 of
   4 to 8 µs, which is P1's parked hop. Its `cpu_per_wall` is the lowest
   of all variants, but it uses the most CPU per request, because of the
   syscalls. `pc_park_if4` is 2 to 4× `pc_park`.
8. **Pipelining** helps per_core: `pc_spin_if4` is 1.2 to 2× `pc_spin`
   from 4 workers up. At 5/95 with 8 or more workers it matches or beats
   `ws_sharded` (inflight 1). That's a different load, so it shows what
   per_core needs (many requests in flight per core). It doesn't make
   per_core cheaper per request.
9. **CPU:** `pc_spin`'s `cpu_per_wall` is about N in every
   configuration, because idle cores spin. The work_stealing variants
   are about N until they park. At 16 workers, `ws_one` drops below N.
10. **Latency:** `ws_sharded`'s p50 is about one operation, 300 to 700 ns.
    `pc_spin`'s p50 is one operation plus 150 to 400 ns. At 16 workers,
    `pc_spin`'s p99 is more than 3× better than `ws_one`'s, and within
    1.5× of `ws_sharded`'s.
11. **Zipf 0.99:** with 16 shards, the shard holding key 1 gets about
    12% of requests: 6.2% from key 1 and 1/16 of the rest. That's about 2×
    its fair share. So `ws_sharded`, `ws_keyed` and `pc_*` lose 1.3 to 2×
    against uniform keys at 16 workers. `ws_one` barely changes, since it
    is already serialized. The hot shard affects per_core as much as
    `ws_sharded`: `pc_spin`/`ws_sharded` under Zipf is within 20% of that ratio under uniform keys.

**Where I expect each variant to win, and why:**
- **`ws_sharded`** wins most of the matrix. Taking the lock where the
  caller is costs little, and it doesn't burn idle cores.
- **`ws_keyed`** is close behind for reads. It's the best layout a
  program gets from `std` without writing a sharded store itself.
- **`pc_spin`** comes closest to winning on write-heavy mixes with many
  requests in flight. That's the case where keeping a shard's lines in one
  cache matters. It loses with one request in flight, on E cores, and
  on CPU.
- **`pc_park`** wins nothing on throughput or latency. It shows why a
  per_core runtime has to spin.

If prediction 5 holds, per_core stays out of 1.0. It should come back
only when a flottning measurement with deep pipelines (prediction 8)
or big per-shard state shows a win.

## How to run

```sh
cd experiments/runtime-p2/percore
./build.sh            # bin/percore (-O2), bin/percore_tsan
./smoke.sh            # every variant once, small; TSan on all of them; exits 1 on a failed check or race
./measure.sh          # the full matrix, one run at a time, 3 reps
./measure.sh --reps 5
```

The full matrix has 8 variants (`ws_one ws_worker ws_keyed ws_sharded
pc_spin pc_park pc_spin_if4 pc_park_if4`), 3 mixes (95, 50 and 5 percent
gets), 2 distributions (uniform and zipf) and 6 worker counts (1, 2, 4,
8, 12 and 16). That's 288 configurations, and 864 runs at 3 reps. Expect
30 to 60 minutes; `pc_park` at 16 workers is the slowest. Results go to
`results/measure-<time>.txt`, and the exact commands to
`results/measure-<time>.cmds`. Narrow the matrix with environment
variables:

```sh
VARIANTS="ws_sharded pc_spin" MIXES=5 DISTS=uniform WORKERS="8 16" ./measure.sh --reps 5
```

Each run is one command, for example:

```sh
./bin/percore --variant ws_sharded --get-pct 5 --dist uniform --workers 8 --ops 200000 --keys 1048576 --seed 42
./bin/percore --variant pc_spin    --get-pct 5 --dist uniform --workers 8 --ops 200000 --keys 1048576 --seed 42
./bin/percore --variant pc_spin    --get-pct 5 --dist uniform --workers 8 --ops 200000 --keys 1048576 --seed 42 --inflight 4
```

**Optional, not in the matrix.** The real-fsync variant. Use a big
`--group-us`, so groups close on count and not on a timer that every
fsync would trip:

```sh
for v in ws_keyed ws_sharded pc_spin; do
  ./bin/percore --variant $v --get-pct 50 --workers 8 --ops 20000 --fsync --group 256 --group-us 100000 --dir "$TMPDIR"
done
```

## Known gaps

- Puts don't wait for durability, so group commit's latency cost isn't
  measured. A put that waits for its group needs a waiter on the commit
  in both runtimes. That's the follow-up if flottning wants synchronous
  puts.
- A parked per_core core doesn't flush its group on the timer. The
  group commits at the next append, or at the end. It doesn't affect
  throughput, since puts don't wait.
- There are no range scans. flottning's ordered memtable exists for
  scans. Under any hash-sharded layout, a scan has to visit every shard,
  and under per_core that's N hops. That's a cost per_core would pay that
  this kernel doesn't show.
- Clients are closed loops with no think time, so this is peak load. At
  low load, `pc_spin` spins idle cores, and `pc_park` pays a wake on
  almost every hop.
- No pinning, and the machine is shared with other agents. Read absolute
  numbers as ±40% (phase 1). Compare ratios within one pass.

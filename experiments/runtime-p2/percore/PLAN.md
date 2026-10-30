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

## Cloud port (Linux, machine `cloud`)

Phase A runs this experiment on the cloud machine (`experiments/MACHINE-cloud.md`:
4 vCPUs, KVM, Xeon 2.1 GHz, no SMT, Linux 6.18). The files directly in
`results/` are the macOS reference (Apple M4 Max) and stay as they are.
Cloud results go to `results/cloud/`.

What changed for Linux (all in `c/percore.c`, behind `#if defined(__APPLE__)`;
the macOS path is unchanged):

- **Parking.** `os_sync_wait_on_address` / `os_sync_wake_by_address_any`
  become `futex(FUTEX_WAIT_PRIVATE)` / `futex(FUTEX_WAKE_PRIVATE, 1)` on the
  same 32-bit words. The hybrid lock and the per_core sleeping flag are
  otherwise identical.
- **Spin hint.** `isb` becomes `pause` on x86. On this machine one `pause`
  costs about 12 ns (measured while porting, `relax_ns` in every output
  line), so `--spin 1000` is a ~12 µs spin window, not "a few µs" as on the
  M4. I kept the poll count, not the time, so the code is the same; read
  `pc_spin` on cloud as a longer spin-then-park.
- **Timer.** `mach_absolute_time` (41.67 ns ticks) becomes
  `clock_gettime(CLOCK_MONOTONIC)` in ns (clocksource `tsc`, vDSO, ~26 ns a
  call measured while porting). Histograms keep their ~3% log-linear
  buckets; on Linux the bucket unit is 1 ns.
- **QoS → pinning.** There is no QoS class on Linux. Instead every thread
  is pinned with `sched_setaffinity`, thread t to the t-th CPU the process
  may use, **when the run has no more threads than CPUs** (`--pin auto`, the
  default; `--pin on|off` override). per_core's "home core" is then a real
  core. Every variant gets the same pinning, so pinning is not a difference
  between runtimes. Runs with more threads than CPUs (8 workers on 4 vCPUs,
  or place_at_spawn 4+4) are left unpinned for the scheduler to balance.
  Output lines carry `os=`, `pin=`, `ncpu=` and `qos=none`.
- **fsync.** `F_FULLFSYNC` becomes `fdatasync`.
- **Build.** `-pthread -lm`. clang 18 on this machine has no compiler-rt
  sanitizer runtimes, so `build.sh` builds the TSan binary with gcc 13 when
  clang's TSan cannot link.
- **Worker counts.** The machine has 4 vCPUs. `measure-cloud.sh` runs the
  original matrix at 1, 2 and 4 workers, plus 8 as the one oversubscribed
  point. 12 and 16 workers are not run: on 4 vCPUs they only measure
  time-slicing. So predictions 6 (E cores) and the 12/16-worker parts of
  2, 3, 9, 10 and 11 cannot be checked here; read them at 4 (and 8) workers.

## Extension: skewed load and place_at_spawn (Phase A, the owner's request)

The owner asked for two additions: (1) a skewed load, Zipf 0.99 on keys
with 5% of requests also doing ~200 µs of pure CPU work, and (2) a third
runtime, **place_at_spawn**. In place_at_spawn, effectful tasks go to the
least-loaded worker when spawned and never move, and pure CPU work goes to
a separate pool that steals. The question: does place_at_spawn plus a
stealing pool for pure work recover work stealing's tail latency?

The closed-loop clients above can't answer that. With one client per
worker nothing ever queues behind a slow request, and at saturation nobody
is idle, so nobody steals. So the extension is a separate **open-loop task
model** in the same binary, on the same kernel (skip list, WAL, preload,
traces, checks):

- **Arrivals.** `--conns` streams (4). Stream c's i-th request is the same
  trace entry as before (same generator, same `trace_sum`). It arrives at a
  Poisson time with total rate `--rate` req/s, or at t=0 with `--rate 0`
  (the throughput mode: everything is queued at the start and the runtime
  drains it). A request is claimed from its stream only once it has
  arrived. **Latency runs from the arrival time to completion**, so time
  spent waiting to be claimed counts (no coordinated omission).
- **Heavy requests.** With `--heavy-pct 5`, 5% of requests (from their own
  RNG stream, so the key trace is unchanged) first run `pure_work`, a
  dependent chain of `mix64` for `--work-iters` iterations, and then do
  their put or get. `--calibrate --work-us 200` finds the iteration count
  for 200 µs on this machine (the median of 11 timed runs, then 21 timed
  chunks as a check). `measure-cloud.sh` runs the calibration once under
  the exclusive lock, writes it into the result header, and passes the
  same `--work-iters` to every run. Each run also prints the measured mean
  chunk length (`work_us_mean`) and `work_sum`, which must match across
  runtimes.
- **Layout.** All three runtimes use the sharded layout: `--shards 4`
  shards, each a memtable and a WAL segment, routed by `part_of`, so the
  same keys land on the same shards everywhere.
- **Stream ownership.** Stream c belongs to worker c mod workers. Its
  unclaimed arrivals are that worker's queue.

The three runtimes:

| variant | effectful tasks | pure work (200 µs chunks) | data |
|---|---|---|---|
| `work_stealing` | run to completion where claimed. A worker claims from its own streams; **an idle worker steals arrived requests from the other streams** | inline, in the task | shard lock, taken where the task runs |
| `per_core` | run on the stream's home core and never move; up to `--inflight` (4) per core | inline on the home core; **the core serves no hops meanwhile** | the KV op **hops** to the owner core (no locks) |
| `place_at_spawn` | at spawn, placed on the **least-loaded worker** (fewest runnable tasks; ties go to the spawning worker), if it has fewer than `--inflight` (4); never moves | **submitted to a separate `--pool`**: one FIFO per pool thread, round-robin submit, idle pool threads steal from the others' FIFOs. The task suspends, then resumes on its home worker | shard lock, taken on the home worker |

Any place_at_spawn worker spawns: it claims arrived requests from its own
streams, then from any stream, and places them. Idle loops in all three
runtimes spin `--spin` polls, then `sched_yield` each round. They never
park, so no wakeups are needed, and an oversubscribed thread gives its CPU
away. CPU time is therefore about all threads busy in every runtime. That
is a known cost, and it's equal across the three.

**Pool sizing on 4 cores.** In the main comparison busy threads never
exceed 4, matching the 4 workers of `work_stealing` and `per_core`:

- `pas_3p1`: 3 workers + 1 pool thread.
- `pas_2p2`: 2 workers + 2 pool threads.
- `pas_4p4`: 4 workers + 4 pool threads, the **oversubscribed** variant
  (8 threads, unpinned). Pool threads take whatever CPU the workers leave.

Under the skewed load, pure work is most of the CPU. Per request it averages
0.05 × 200 = 10 µs, against ~1 µs for the KV op. So a fixed split
caps place_at_spawn's throughput at what the pool can do:
- 3+1: ~1/(10 µs) ≈ 100k req/s.
- 2+2: ≈ 200k req/s.
- work_stealing and per_core use all 4 cores for whatever comes, so they
  can do ≈ 4/11 µs ≈ 360k req/s.

That's arithmetic, not a measurement, and it's why the oversubscribed
variant is in.

**Loads.**
- *even*: 50/50 get/put, uniform keys, no pure work.
- *skewed*: 50/50, Zipf 0.99, 5% heavy, 200 µs chunks.

**Configurations.**
- Throughput mode (`--rate 0`) for all five runtime configs (`ws`, `pc`,
  `pas_3p1`, `pas_2p2`, `pas_4p4`).
- Latency mode at offered loads of 25%, 50% and 75% of work_stealing's
  median throughput-mode result for that load. `measure-cloud.sh` measures
  that first, in the same pass.
- A latency run whose achieved rate is below 97% of offered is marked
  `sustained=0`. Its latency mostly measures a growing queue.

**Samples.**
- even: 4 × 250k = 1M requests a run.
- skewed: 4 × 100k = 400k requests a run, of which ~20k are heavy.

So the light-request p999 rests on ≥ 380k samples a run. The heavy p999 rests
on ~20k samples, about 20 in the tail, so it's indicative only. Percentiles
come from the log-linear histogram (32 sub-buckets per power of two, ~3%,
HDR-style) over every request, per run. Reported numbers are the median
over ≥ 7 runs.

Output fields added to every line:
- `p999_ns`.
- `light_p50/p99/p999_ns`: requests without pure work.
- `heavy_p50/p99/p999_ns`: requests with pure work.
- `samples`, `light_samples`, `heavy_samples`.
- `rate_rps`, `sched_ms`, `lag_ms`, `sustained`.
- `work_iters`, `work_us_mean`, `work_sum`.
- `steals_per_req`, `placed_remote_per_req`, `yields_per_req`.
- `relax_ns`, `os`, `pin`, `ncpu`.

**Overall p99 under skew is set by the heavy requests by construction.**
5% of requests take ≥ 200 µs, so in every runtime the overall p99 and
p999 are heavy requests. The question "does it recover the tail" is
therefore read on the **light** requests' p99/p999 (the 95% that do no
pure work), with the heavy requests' latency reported beside it.

### Extension predictions (written before measuring, during porting)

The only numbers seen so far are the porting probes: `pause` ≈ 12 ns,
`clock_gettime` ≈ 26 ns. Nothing below has been measured.

E1. **Even load, throughput mode.**
- `work_stealing` and `per_core` are within 1.5× of each other. per_core
  pays a hop on 3/4 of requests (cross-core lines on this Xeon cost
  ~100–200 ns each way) but runs 4 requests in flight per core.
- I expect `work_stealing` to win, by 1.1–1.5×.
- `pas_3p1` is 0.6–0.8× `work_stealing`: 3 workers do the effectful work,
  and the pool thread idles.
- `pas_2p2` is 0.4–0.55×.
- `pas_4p4` is 0.5–0.9×: four idle pool threads yield-loop against the
  workers.

E2. **Even load, latency** at 25–75% of work_stealing's throughput.
- `work_stealing` light p50 is 1–3 µs, p99 under 10 µs, and p999 10–50 µs
  (timer ticks and preemption).
- `per_core` p50 is 0.3–1 µs above `work_stealing` (the hop), with p99
  within 2×.
- `place_at_spawn` (3+1, 2+2) is within 1.5× of `work_stealing` on p50 and
  p99 as long as it sustains the load.
- `pas_2p2` may not sustain 75%.

E3. **Skewed load, throughput mode.**
- `work_stealing` ≈ `per_core` ≈ 250–380k req/s, within 1.3× of each other.
  The work is CPU-bound and both use all 4 cores.
- `pas_3p1` ≈ 80–110k req/s and `pas_2p2` ≈ 160–210k req/s: the pool caps
  them.
- `pas_4p4` comes within 0.7–1.0× of `work_stealing`.

E4. **Skewed load, light-request tail, at 25% and 50%.**
- `work_stealing`: a light request waits behind pure work only when all
  4 workers are inside chunks, because any idle worker steals the arrival.
  - At 25%, light p99 is under 20 µs and p999 is 20–150 µs.
  - At 50%, light p99 is 10–100 µs and p999 is 100–250 µs.
- `per_core`: a light request waits whenever its home core, or the owner
  core it hops to, is inside a chunk. At 50%, that's roughly half the time.
  - At 25%, light p99 is 150–250 µs.
  - At 50%, light p50 is above 10 µs, p99 is 200–400 µs and p999 is
    300–800 µs.
  - That is, per_core's light p99 is at least 5× `work_stealing`'s at
    both loads. This is head-of-line blocking, and it is what the
    extension is meant to show.
- `pas_2p2` and `pas_3p1`, while the pool keeps up: workers never run
  chunks, so light requests see only ~1 µs KV ops on 2–3 mostly idle
  workers.
  - Light p99 is under 10 µs and p999 under 50 µs, **better than
    work_stealing's by 2× or more at 50%**.
  - But 3+1 can't sustain 50% (≈180k req/s against a ≈100k cap), and
    2+2 is near its cap at 50%.
  - An unsustained run's light latency stays low, since the workers
    aren't the bottleneck. Its heavy latency grows without bound.
- `pas_4p4`: pool threads share cores with the workers. A light request
  that lands on a core running a pool thread waits for that chunk (up to
  200 µs) or for the scheduler. So light p99 is within 0.5–2× of
  `work_stealing`, and p999 is no better than `work_stealing`'s.

E5. **Skewed load, heavy requests and overall tail.**
- `work_stealing` heavy p50 is ≈ 200–220 µs.
- `pas_2p2` heavy p99 is ≥ 2× `work_stealing`'s at 50%, from pool queueing
  (2 servers near 90% busy).
- Overall p99 is ≥ 200 µs everywhere (it's a heavy request).
- At 75%, only `work_stealing`, `per_core` and maybe `pas_4p4` sustain the
  load.

E6. **The answer I expect.**
- place_at_spawn with a separate stealing pool **recovers, and beats,
  work_stealing's tail for light requests** as long as the pool has
  enough threads for the pure demand. On 4 cores it pays for that with
  throughput, a hard cap of pool size × 100k req/s, and with heavy
  request latency.
- With 4 cores and a fixed non-oversubscribed split, it does not recover
  work_stealing's overall tail at 50% load or above.
- Oversubscribing (4+4) gets throughput back but gives the light tail
  back to the scheduler, so it lands near work_stealing, not below it.
- per_core is clearly worst on the light tail under skew. That is the
  argument for keeping pure work off a per_core home core.

### How to run (cloud)

```sh
cd experiments/runtime-p2/percore
flock -s /tmp/ren-bench/lock ./smoke.sh     # build, every variant once, TSan (gcc)
./measure-cloud.sh                          # everything; each config under flock -x
./measure-cloud.sh ext                      # only the extension
./measure-cloud.sh base                     # only the original matrix (1 2 4 8 workers)
```

`measure-cloud.sh` writes `results/cloud/measure-<time>.txt` (every rep
line, plus a `CFG` summary line per configuration) and `.cmds` / `.err`.
Each configuration is one `flock -x` acquisition with ≥ 7 reps. The
1-minute load from `/proc/loadavg` is recorded at the start and end. The
script prints median/min/max and spread. If the spread is above 10% it
re-runs the configuration (up to 2 more times), and if it is still above
10% it marks it `NOISY`.

The spread metric is `mops` for the original matrix and for throughput
mode, and `light_p99_ns` for latency mode. In latency mode the achieved rate
is the offered rate by construction, so the latency is what varies. The
spreads of the other headline numbers are printed too.

### Port findings (seen while porting, after the predictions above were written)

These came from smoke and diagnostic runs (small, under the shared lock),
not from timed measurements. They don't change the predictions, but they
change how to read the results.

- **Start barrier bug, fixed.** The workers' start barrier spun on `go`.
  With 4 pinned workers on 4 vCPUs that starved the unpinned main thread
  between `t_go = now()` and `go = 1`, so every core started ~6 ms late,
  and that counted as latency and wall time. The macOS run (16 cores, 4–16
  workers) rarely hit this. Now waiting threads `sched_yield`, the main
  thread sets `t_go` 2 ms ahead, every thread spins until then, and each
  line reports `start_lag_us` (0.1 µs in the smoke runs). `cpu_ms` starts
  at `t_go`. This affects the original variants too: on cloud their
  `wall_ms` no longer includes the start skew.
- **Hypervisor steal is large on this VM.** One pinned spinner per vCPU
  loses its CPU in 0.1–9 ms gaps, tens of times per 400 ms, about 1–5% of
  wall time per vCPU (`--gap-probe`; `/proc/stat` steal grows by 1–5
  ticks of 10 ms per 0.4 s run). `measure-cloud.sh` records a gap probe in
  the header and steal ticks per configuration.
- **per_core amplifies steal into stalls of the whole system.** In the
  open-loop smoke at 300k req/s, even load, per_core's light p99 was
  1.4–8 ms, while work_stealing's was ~12 µs and place_at_spawn's ~11–15
  µs. Slow requests come in 1–2 ms windows on **all four cores at once**.
  When one core loses its vCPU, every other core's `--inflight` slots fill
  with hops to that core's shard within a few µs, and then those cores
  stop claiming arrivals too. Under work_stealing a lost vCPU delays only
  the one request it was running, and the others steal its arrivals.
  That is a real property of per_core on a host that steals vCPUs, not a
  harness bug: decrementing the slots requires the owner core to run.
  But it means **per_core's cloud tail will mostly measure vCPU steal,
  under even load too**. So prediction E2 ("per_core p99 within 2× of
  work_stealing") will probably fail here for that reason, apart from the
  200 µs chunks.
- **Calibration:** `pure_work` costs ~4.1–4.5 ns per iteration, so 200 µs
  is ~46–50k iterations. Repeated calibrations varied by up to 8% under the
  shared lock. `measure-cloud.sh` takes the median of 3 under the
  exclusive lock and records them.
- **Expect NOISY latency configs.** Gated on light p99, steal can push a
  run's tail by milliseconds. In a 20k-sample script test, latency-mode
  spreads were far above 10%. The full runs have 400k–1M samples per run,
  which should help, but some latency configurations may stay NOISY. Then
  the honest reading is "within steal noise on this machine".

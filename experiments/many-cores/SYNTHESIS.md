# Many-cores phase one: synthesis

What phase one says about foundations.md decisions 10 and 18, built from
[RESULTS.md](RESULTS.md) (the first runs) and [VERIFY.md](VERIFY.md) (an
independent reading of the sources and a rerun). Where they differ, VERIFY's
number is used. Apple M4 Max, 12 P and 4 E cores, macOS; every thread at
`QOS_CLASS_USER_INTERACTIVE`, which prefers P cores but doesn't pin, so
runs at 13 to 16 workers include E cores. Background load from other agents
moved absolute throughput by 30 to 50% between passes: **read absolute
numbers as ±40% and compare ratios**, which held to about 10% within a pass.

Nothing here is applied to the documents. Section 5 is proposed text for the
owner to approve.

## 1. Each experiment against its prediction

| exp | prediction | verified result | held? |
|---|---|---|---|
| **K3**, marking | marking at the edge does 3× the ops/s of marking the state shared, at 8 workers | edge wins in every cell. At 8 workers: 6.4 to 7.8× with decision 10's lock (barge, short spin, park; `k3/verify/k3_hybrid.c`), 4.1 to 10× across the state-size grid, 12 to 15× at 16 workers, 8.3× at 1 worker. With `os_unfair_lock`, which serialises onto one thread, only 1.2 to 2.9× (7 to 9.6× at 128 subs) | **yes, under the lock decision 10 describes.** RESULTS.md's "1.5 to 2×, not 3×" measured the wrong lock |
| **P1**, take | taking the instance costs 5 to 20 ns over a call | 0.5 to 3 ns (lock line in this core's cache); about 3 ns a take inside K1's three-take `at` | yes, better |
| **P1**, hop spinning | ~300 ns | 105 to 385 ns | yes |
| **P1**, hop parked | ~2 µs | 5.7 to 8.2 µs from cold; 3.9 to 5.5 µs with both sides parked | **no, 3 to 4× worse** |
| **P3**, barge vs FIFO | FIFO handoff loses 3× to barging with a 1 ms guard (64 tasks, one instance) | 3.4 to 4.0× at 100 ns ops and 12 to 16 workers; 2.0× at 8 workers or 500 ns; 1.0× at 4 workers or 2 µs ops. The guard fired on ≤0.04% of releases. Barging's p50 wait is better everywhere (0.3 µs against 80 to 190 µs); its p99 is **worse** at 4 to 8 workers (115 vs 102 µs, 139 vs 115 µs) and better at 12 to 16 | **partly:** holds for short ops under heavy contention, never loses throughput; RESULTS.md's "p99 never worse" is wrong |
| **S1**, stripes vs atomic | stripes 5× the others at 16 workers | with 100 steps of work between adds: 7.4× (C), 2.8× (Rust, locked), 3.7× (Rust, owner-only). With no work: 236 to 263×. Unpadded stripes are no better than one atomic | **yes, only padded to 128 bytes** |
| **S2**, padding | (second tier) | pad 0 ≈ atomic; pad 64 gives 50 to 80% of pad 128; the M4's line is 128 B | answered: pad to the cache line, 128 B here |
| **S3**, merge latency | (second tier) | owner-only stripes 0.5 to 0.6 µs; atomic 0.25 µs; locked stripes 0.3 to 3 ms with writers running | answered, light |
| **K1**, `at` on a hit | none numeric | 8 to 9 ns uncontended (spin lock), 15 ns (`os_unfair_lock`): three lock takes. 64 partitions give 6 to 30× one partition on uniform keys, yet 16 workers total (34 to 40 M/s) stay **below one worker** (79 to 129 M/s). Zipf(1.1): 64 partitions barely help (5 to 14 M/s) | n/a; the hit path is the cost |
| **K2**, cap per partition | under 2% extra misses on uniform keys | ≤0.2% once the key universe is ≥1.5 × max; 1.4 to 8.5% at universe = max when max/parts is ≤1.5k; under 1% at max/parts ≥1.5k. Deterministic; C = Rust exactly | **yes**, except a working set ≈ max with small per-partition caps |
| **cache3** | none numeric | 50 µs fetch, Zipf, 16 workers: `striped16` 11.6 to 12.0 M/s = 2.7 to 2.8× `one` (releases across the fetch), 1.3 to 1.6× `actors`, 3.6× moka; best p99 over hits (2.4 µs). `one_hold` flat at ~1.1 M/s from 1 to 16 workers. `actors` costs ~19% more per uncontended hit, and coalesces misses | n/a; ranking is clear |

## 2. K3: decision 10's open marking question

**Recommendation: mark at the edge.** A shared handler's state keeps plain
(local) counts, since only the task holding the instance reaches it. What's
marked shared is only what crosses the instance's edge: an argument the
state keeps, and a result that shares the state's structure. This is Rust's
`Mutex<T>` needing only `T: Send`.

Evidence:

- Edge wins in every configuration measured: every worker count (1 to 16),
  every lock, every state size, C and Rust.
- With no contention it's 8.3× (1 worker). That is rule U: a marked object
  is never unique, so every `push` and `apply` on marked state copies, and
  counts each element atomically twice (copy, then the old version's drop).
  Contention isn't needed for the loss.
- Under the lock decision 10 actually specifies (barging, a short spin, then
  park, as Go's mutex), 6.4 to 7.8× at 8 workers and 12 to 15× at 16:
  marked state's copies and atomic counts are done while the lock is held,
  so they lengthen the critical section everyone queues behind, and the
  copied lines move between cores with each holder.
- The ratio grows with the state an operation touches (7 to 9.6× at 128
  subs even under the serialising lock), so the cost of marking the state
  scales with exactly the state actors exist to hold.
- Rust's `Arc`-everything model shows 13.8×, but it also pays the system
  allocator; Ren's heap per thread (rule H) avoids that, so the Ren-model C
  number is the one to cite.

One trap to document with it: a result that shares the state's structure
is marked when it crosses the edge, so the state's object becomes shared and
the next change copies it once. That's the "values read out of a shared
handler's `var` state" trap decision 10 already names.

## 3. Handoff, placement, stripes, actors and partitions

| default | today | evidence | verdict |
|---|---|---|---|
| **No home core** (decision 18) | callers take the instance where they are; `place:` later | take: 0.5 to 3 ns. Hop: 105 to 385 ns spinning, 4 to 8 µs parked. A home core costs 100× a take while spinning and 2,000× parked | **keep**, now with numbers. `place:` has no case unless an operation's state is too big to move between caches, which P2 would show |
| **Fair, not FIFO** (decision 10) | barging allowed, no waiter passed over without bound | barge/FIFO 3.4 to 4× at short ops and ≥12 workers, never below 1×; the 1 ms guard fired on ≤0.04% of releases; p50 wait 300× better; p99 10 to 20% worse at 4 to 8 workers, better at 12 to 16 | **keep**, and name the guard: 1 ms |
| **Spin, then park** (decision 10 says "as Go's mutex"; not spelled out) | implicit | a parked wakeup costs 4 to 8 µs on macOS, against 0.1 to 0.4 µs for a spinning handoff; K3's barge-spin-park lock is what produced edge's 6 to 8×, while `os_unfair_lock` (parks at once) serialised onto one thread | **change: state it.** A waiter spins a bounded budget (Go's is 4 rounds of 30 pauses; 64 to 1000 spins gave the same K3 result) before parking its task |
| **`striped` padding** (decision 18 says "padded" only for `by: Worker` under `work_stealing`) | partial | unpadded stripes ≈ one atomic; 64 B pads give 50 to 80%; 128 B (Apple's line) needed | **change:** every stripe, under every multi-core runtime, padded to the target's cache line |
| **`striped` n = 16** | `by: Key(n: 16)` | `striped16` was the best cache at 16 workers. No other n measured | **keep**; sweep n in phase two |
| **`stripe` merge** | stripes visited one at a time, not a snapshot | owner-only stripes merge in ~0.5 µs; locked stripes take 0.3 to 3 ms with writers running, since the merge queues on each contended stripe in turn | **keep** for `per_core`; **measure more** for `work_stealing` `by: Worker`: can an operation with an empty row (it can't suspend, so can't migrate mid-operation) skip the stripe's lock, as `per_core` does? |
| **`actors` hit path** | partition lock to pin, actor lock per call, partition lock to unpin and touch an exact LRU by release | 3 lock takes, ~20% over `striped` uncontended; at 16 workers 64 partitions still total less than one worker, because the partition line moves on every hit | **measure more** (K1b): pin with an atomic and touch the LRU lazily or per-worker batched, keeping "exact LRU by release" or relaxing it to "LRU within a bound". Semantics (`sim`, journals) don't depend on it |
| **`parts:`** | decision 18: "default comes from `max:`, never from the core count"; services stage built `parts: Int = 4` | K2: waste tracks max/parts; ≥1.5k a partition costs under 1% even at universe = max, ~150 costs 3.6 to 8.5%. K1: more partitions scale better (64 ≫ 8 ≫ 1) on uniform keys; Zipf hot keys don't spread anyway | **change, after one run:** derive it as decision 18 already says, e.g. the largest power of two ≤ max/1024, clamped to 1 to 64 (10_000 → 8, 50_000 → 32). Four is safe for waste but leaves throughput on the table at `max:` ≥ 10_000; K1 and cache3 at parts 4/8/16/32 settle the constant |
| **cap = max / parts, exact LRU each** | decision 18 | K2 holds except where the working set ≈ max | **keep**, and document "size `max:` at 1.5× the working set" |

## 4. The cache three ways: which to write

As language.md §11's guidance would put it:

- **Never hold the instance across the fetch.** A cache handler whose `get`
  calls `Store.fetch` without `release` serializes every caller behind every
  miss: flat at ~1 M ops/s from 1 to 16 workers, with a p99 of 246 µs in Rust; held per stripe, 3.4 M/s with a p99 of hits of 77 µs.
  It's decision 10's "one slow call serializes the handler", and a cache is
  the case `release` exists for.
- **One handler, with `release` around the fetch:** a cache used by a few
  tasks, or one whose invariants span keys (one exact LRU, one global cap,
  a total size). It's the simplest, it re-checks after `release` (a second
  caller's fill wins), and it's fine to 4 workers (3.9 M/s, within 1.0× of
  the others); past 8 it levels off at about a third of `striped`.
- **`striped(cache(store), by: Key)`:** the default for a hot, read-mostly
  cache of independent keys. Fastest at 8 workers and above (2.7×
  one handler, 1.3 to 1.6× `actors`, 3.6× moka at 16 workers) and the best
  latency for hits. Its costs: each stripe's cap is max/n, so size `max:`
  at 1.5× the working set (K2), and two callers missing one key both fetch
  unless the handler keeps a pending set.
- **`actors(entry, max:)`:** when an entry is an entity, not a value: its
  own setup and `finally`, its own I/O, state bigger than one value, or
  fetches expensive enough that duplicates matter. Setup is the fetch, so
  concurrent misses on one key coalesce for free (ahead of `striped` at one
  worker, 0.90 vs 0.82 M/s). It pays about 20% more per hit and reaches 60
  to 75% of `striped`'s throughput under contention.

The test stays §11's: a value per key is data in stripes; an entity per key
that does I/O is an actor.

## 5. Proposed doc edits (for approval; none applied)

### foundations.md, decision 10

**a. Replace the bullet "Whether a shared handler's state is marked is open." with:**

> - **A shared handler's state isn't marked; what crosses its edge is.**
>   Only the task holding the instance reaches its state, so the state
>   keeps plain counts and changes in place, as a Rust `Mutex<T>` needs
>   only `T: Send`. What's marked is what crosses the instance's edge: an
>   argument the state keeps, and a result that shares the state's
>   structure (which marks that part of the state, so its next change
>   copies once). Measured (experiments/many-cores, K3), marking the state
>   instead was slower everywhere: 8× at one worker, since a marked
>   object is never unique and every change copies it, and 6 to 8× at 8
>   workers and 12 to 15× at 16 under the lock this decision describes,
>   since the copies and atomic counts run while the lock is held.

**b. In "An operation keeps its instance until it returns", replace "so across threads it costs what a plain lock does uncontended, about 5 to 20 ns." with:**

> so across threads it costs what a plain lock does uncontended, 1 to 3
> ns on an M4 when the lock's line is in the core's cache (P1).

**c. After "as Go's mutex does.", insert:**

> A waiter spins for a short budget before its task parks, since waking
> a parked worker costs 4 to 8 µs on macOS against 0.1 to 0.4 µs for a
> spinning handoff (P1). The starvation guard is 1 ms: a waiter passed
> over that long is handed the instance directly. Measured with 64 tasks
> on one instance (P3), barging gave 3.4 to 4× the throughput of
> first-in-first-out handoff for 100 ns operations at 12 to 16 workers
> and never less, the guard fired on under 0.05% of releases, and the
> median wait fell from about 100 µs to 0.3 µs; the p99 wait was 10 to
> 20% worse at 4 to 8 workers.

### foundations.md, decision 18

**d. In "No home core.", replace "Shipping operations to a home core, as Seastar does, costs a hop per call;" with:**

> Shipping operations to a home core, as Seastar does, costs a hop per
> call, measured at 100 to 400 ns with the home core spinning and 4 to
> 8 µs with it parked, against 1 to 3 ns to take the instance (P1);

**e. Replace the partitions bullet with:**

> - **A family is split into partitions**, a fixed number `actors` sets
>   with `parts:`, whose default comes from `max:` and never from the
>   core count: the largest power of two at most `max / 1024`, from 1 to
>   64. Each has its own lock, map, exact LRU and a cap of `max / parts`.
>   So a journal from a run on one thread replays on sixteen. A cap per
>   partition costs under 1% of hits once a partition holds 1,500 or
>   more, and under 0.2% once the keys in use are 1.5 × `max:` (K2); at
>   150 a partition, with the keys in use ≈ `max:`, it cost up to 8.5%.

(The constant 1024 is pending K1 and cache3 at parts 4, 8, 16 and 32; until
then the services stage's `parts: Int = 4` stands.)

**f. In the `striped` bullets, after "It replaces `sync.keyed(n, h)` as 11a built it.", add:**

> - **Stripes are padded to the target's cache line** under every runtime
>   with more than one worker, 128 bytes on Apple's cores. Unpadded,
>   stripes were no faster than one atomic; padded to 64 bytes on an M4,
>   50 to 80% of 128 (S1, S2). Padded, a counter's stripes ran 3 to 7×
>   one atomic at 16 workers with work between adds.

And in the table, `work_stealing` / `striped(by: Key)` cell: "locked
stripes" → "locked stripes, padded".

### foundations.md, Staging item 6

**g. After the phase-one list, add:**

> **Phase one, done** (experiments/many-cores/SYNTHESIS.md): K3 decided
> marking at the edge (decision 10); P1 kept "no home core" and measured
> parked wakeups at 4 to 8 µs, so waiters spin before parking; P3 kept
> fair-not-FIFO with a 1 ms guard; S1 held, with stripes padded to the
> cache line, which answers S2; S3 was measured lightly; K2 held, and sets
> the default for `parts:`. Left for phase two: K1b, a cheaper `at` on a
> hit; `parts:` and `striped`'s n swept; S3 for locked stripes per worker;
> K4. P4 and P5 were dropped with the home core.

**h. In item 8 (11b), replace "with fair handoff, partitions and marking as K3 decided." with:**

> with fair handoff that spins before it parks, partitions sized from
> `max:`, stripes padded to the cache line, and marking at the edge.

## 6. The second tier

| exp | still needed? | what it should answer |
|---|---|---|
| **P2**, contended ops touching 1 to 64 lines | **mostly answered** by K3's state-size grid (the edge/shared ratio grows with what's touched). Keep only if `place:` is reconsidered: at how many lines touched per op does a hop (P1: 100 to 400 ns) beat moving the lines to the caller? | the crossover, if any |
| **P4**, hot key held across a 100 µs fsync | **unnecessary**: placement is settled (no home core), and holding across slow I/O is a serialization cost cache3's `one_hold` already shows | — |
| **P5**, home core on an E core | **unnecessary** with no home core | — |
| **S2**, padding | **done** in S1: 128 bytes on the M4 | — |
| **S3**, merge latency | **partly done**. Remaining: under `work_stealing` `by: Worker`, can an operation with an empty row skip the stripe lock (owner-only, ~0.5 µs merges) instead of locking (0.3 to 3 ms with writers)? And with decision 10's lock, not the spin lock S1 used | whether `by: Worker` gets a lock-free write path |
| **S4**, stripes made on their own worker | **low value** on the M4's unified memory; move to phase two on a multi-socket or chiplet machine if one is used | first-touch effects off Apple silicon |
| **K4**, eviction's `finally` not stalling its partition | **needed**: cache3's actors run `finally` after dropping the partition lock, but never with a slow `finally` | p99 of other keys' `at` in the victim's partition while a 100 µs `finally` runs |
| **K1b** (new) | **needed** | `at` with an atomic pin and a lazy or batched LRU against today's three takes; whether 16 workers then beat one |
| **parts / n sweep** (new) | **needed** before fixing the default | K1 and cache3 at parts 4, 8, 16, 32 and `striped` n 8, 16, 32, 64 at 8 and 16 workers |
| **Spin budget** (new, small) | useful | K3 and P3 with decision 10's lock at spin budgets 0 to 1000, on P cores and with E cores in the mix |

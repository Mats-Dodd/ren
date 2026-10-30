# Runtime-frames experiments X1, X3, X3b and X5: results

X1, X3 and X5 are the first three experiments from
[research/runtime-frames/SYNTHESIS.md](../../research/runtime-frames/SYNTHESIS.md) §7.
X3b follows up X3 under `per_core`, against runtime.md and concurrency.md
("Many cores").

**Machine.** All runs were on the owner's Apple M4 Max: 16 cores (12P + 4E),
macOS 15.1, Apple clang 16.0.0, and tcc 0.9.28rc (mob e23dabe). The machine is
shared with other agents. The 1-minute load average before each round was:

| experiment | load |
|---|---|
| X1 | 1.9 to 3.8 |
| X5 | 3.3 to 5.7 |
| X3 | 5.5 to 8.1 |
| X3b | 7.2 to 20.9 |

Each variant ran interleaved with the others, in 5 to 7 rounds. Figures are
the median over rounds, with [min..max] across rounds after them. Raw lines
and summaries are in `x*/results/`. The commands are in each directory's
README.

## Verdicts

| | predicted | measured | verdict |
|---|---|---|---|
| **X1** register convention | nested round trip from about 31 ns to within 20% of the inlined `pingpong` | 32.5 → **19.2 ns** [19.1..19.6]. That is 1.21× the inlined 15.9 ns. With the bounds check dropped: 18.9 ns (1.19×). With put and get kept out of line: 21.0 ns (1.32×). | **Borderline.** It hits only with release's bounds-check elimination. The nested cost fell 41%. |
| **X3** shared takes as suspending | under 3% throughput and under 10% code growth uncontended. With a 100 µs hold, parking keeps wasted CPU under 10% where spinning burns it, and without a hand-off a waiter starves for ms. | Throughput: **+0.3%** ns a request against `os_unfair_lock`. Code: the path's text grew **3.6×** (424 → 1,524 B), and the model's whole text grew 17.6%. Long hold: wasted CPU **1.7%** parked against **87.5%** spinning. A waiter's p50 is **35 ms** without a hand-off and **6.5 ms** with one. | **Throughput, wasted CPU and starvation: hit. Code size: miss.** Not predicted: with short holds at 8 workers, parking runs at **4.4× below** `os_unfair_lock`. |
| **X3b** a contended shared instance under `per_core` | home-core shipping beats parking by over 2× on C, within 1.5× of `os_unfair_lock`, with near-zero waste, background work flowing under long holds, and the mixed scenario within 10% of the best. Adaptive parking recovers half the gap with under 20% waste. | Shipping: **2.7×** `os_unfair_lock` and **5.9×** parking on C. Background work flows under a 100 µs hold. Mixed: **−6%**, but a shared operation waits **130 µs** (10.5 µs with FAST) against 0.2 µs. P2: **0.7 to 1.5×** parking, with 46 to 75% wasted. `at`: moving the task runs **0.16×** shipping at 1 operation a block, 0.51× at 4 and **1.70×** at 16. | **(H): hit, the C ones exceeded. The home-core cap is real (about 30M ops/s) but wasn't what bound C.** Its costs are latency when lightly contended, and preemption of the home. **(P2): miss.** |
| **X5** static frame-stack sizing | about 4,200 B against about 290 B a parked task | **4,208 B** against **240 B** (malloc accounting), or 4,230 against 252 B (footprint). The chunk boundary goes from 22.3 ns to **4.2 ns** with a spare, against 1.2 ns in the segment. | **Bytes: hit**, and smaller than predicted. **Spare within 1 ns: miss** (+1.4 to +3.1 ns), though the 4× cliff is gone. |

What this means for SYNTHESIS §6:

- **Decision 4 (one register convention):** supported for clang.
  - Under tcc it costs +2% on the nested bench, and +33% on single-frame
    code, where the prototype kept everything in the frame.
  - That is worse than §2a's "about 10%", but still within one convention's
    tolerance.
- **Decision 2 (shared takes suspending):** supported on uncontended cost and
  on long holds, where it is decisively better than a thread lock.
  - Go's 1 ms hand-off is required, not optional.
  - The contended short-hold case is a real cost that SYNTHESIS didn't
    predict. The park path needs work (adaptive spin, workers that spin
    before sleeping), and hot unstriped instances should be steered to
    `striped`.
  - The code-size claim is wrong as stated: a recoloured function costs
    about 220 B more.
- **Decision 5 (static sizing, cap, spare chunk):** supported.
  - Freeing the spare at park is necessary: without it a parked task is
    4,336 B.
  - §5's chunk retirement is incomplete: see X5.

---

## X1: the register convention end to end

`x1/ren_reg.c` is `ren_single.c`'s two ping-pong benches in §5's
convention. The heap, instances and waiter queues are the prototype's,
unchanged. The baseline is the prototype file itself, built unmodified.

The table shows ns a round trip, from two interleaved sessions of 7 rounds
(5 reps a run, n = 2M with clang and 500k with tcc).

| build | `pingpong` (inlined ops) | `pingpong_nested` |
|---|---|---|
| prototype, clang -O2 | 15.9 [15.8..16.7] / 16.1 [15.9..16.6] | **32.5** [32.4..32.8] / 32.3 [32.0..32.7] |
| register, clang -O2 | 16.1 [16.0..16.2] / 16.3 [16.2..29.6] | **19.2** [19.1..19.6] / 19.8 [19.7..19.9] |
| register, no bounds check | 15.9 / 16.2 | **18.9** [18.9..19.0] / 18.7 [18.6..18.8] |
| register, put/get out of line | 15.9 / 16.2 | **21.0** [20.7..21.3] / 21.1 [21.0..21.2] |
| prototype, tcc | 41.4 [41.3..41.6] / 41.5 | 116.8 [116.4..117.8] / 117.0 |
| register, tcc | 55.1 [54.0..56.7] / 55.0 | 119.3 [118.5..122.1] / 120.2 |

- **Correctness.** Every variant returns the same sum (`n(n+1)/2`).
  `--check` passes under clang, tcc and ASan+UBSan, with and without
  inlined ops, at n = 1, 2, 3, 1000 and 100000.
- **What's left of the gap.** The nested bench switches twice a round
  trip, as the inlined one does. Each switch then resumes two frames
  through the trampoline instead of one: an extra indirect call and a cold
  dispatch. That cost is on the resume path, which r2 measured at about 3 ns
  a level, so it isn't fast-path cost. Four fast-path child calls a round
  trip cost the rest, about 0.3 ns each with the check, which matches r2's
  0.4 ns a level.
- **The prediction compared against the prototype's inlined `pingpong`
  measured today** (15.9 ns here, against the Xeon's 16 to 18). With the
  check, 19.2 to 19.8 ns is 21 to 23% over: a narrow miss. Without the
  check, it's 16 to 19%: a hit. Release drops the check when the inline
  segment covers the static bound (§5's table), so the release number is
  the bottom row of the clang group.
- **tcc.** The register convention is no help under tcc. Nested: +2%.
  Single-frame: +33%, because tcc returns the 16-byte `ren_ret` through
  memory and keeps few C locals in registers, so the "locals in C locals"
  rule buys nothing. §2a said tcc conventions are within about 15% of each
  other. Nested agrees; single-frame doesn't.

## X3: colouring shared takes as suspending

`x3/` is a server-shaped C model:

- 8 worker threads, each with a FIFO run queue of 16 connection tasks;
- every request is a put or a get (50/50) on one in-memory hash table,
  behind one exclusive instance, unstriped;
- every 8th `recv` suspends and is answered at once, so a worker
  interleaves its tasks.

One `path.c`, compiled two ways:

- **(a)** a suspending take: a CAS, about 1 µs of spin, then the task
  parks, with an optional Go-style 1 ms hand-off;
- **(b)** a thread lock with plain callers: `os_unfair_lock`, or a TTAS
  spin lock.

**Correctness.** At one worker, all four strategies give the same response
checksum for the same 320,000 requests. ASan+UBSan and TSan builds of both,
contended, with and without a hold, finish every request and leave the lock
clean (`x3/results/check-*.txt`). TSan is clean.

**Colour, by construction.** The model has 14 functions. Two are
suspending in both builds: `serve`, and `recv`, which reaches a world call.
Five change colour: `handle`, `route_put`, `route_get`, `mt_put` and
`mt_get`, which is every function between the request and the take. Seven
stay plain (parse, validate, insert, lookup, hold, encode, respond). Every
function on the path from a request to the take changes colour. Nothing off
the path does.

**Code size** (`size -m`):

| | (a) | (b) | growth |
|---|---|---|---|
| `path.o` `__text` | 1,524 B | 424 B | +1,100 B, 3.6× |
| whole model binary `__text` | 7,504 B | 6,380 B | +17.6% |

- In (b), clang inlines the plain path into `serve`.
- In (a), the resume functions are address-taken, so each stays a function
  of 120 to 330 B with its spill and dispatch paths.
- So "under 10% code growth" is a miss as a statement about the recoloured
  code. For a whole program, the growth is about 220 B for each function
  that changes colour. Whether that's under 10% depends on how much of the
  program sits on paths to a shared take.

**U, uncontended** (1 worker), ns a request:

| park (a) | handoff (a) | unfair (b) | spin (b) |
|---|---|---|---|
| 68.8 [68.7..69.3] | 68.9 [68.8..69.7] | 68.6 [68.3..69.4] | 67.4 [66.8..67.8] |

(a) costs **+0.3%** against `os_unfair_lock` and +2.1% against a bare spin
lock: a hit. The frames and the CAS are lost in about 69 ns of request
work.

**C, contended with short holds** (8 workers, no hold). Not predicted:

| | req/s | wait p50 / p99 / max (µs) | spin % | idle % |
|---|---|---|---|---|
| park (a) | 1.15M [1.11..1.16] | 1.0 / 576 / 2,425 | 20.9 | 28.1 |
| handoff (a) | 1.13M [1.09..1.14] | 1.0 / 548 / 1,644 | 20.4 | 29.1 |
| park, 10 µs spin (a) | 3.03M [2.53..3.12] | 1.9 / 310 / 2,395 | 80.2 | 0 |
| spin (b) | 3.95M [3.94..4.09] | 1.8 / 19 / 236 | 81.1 | 0 |
| unfair (b) | **5.08M** [5.03..5.13] | 0.6 / 40 / 530 | 0 | 0 |

- **Task parking loses 4.4× to `os_unfair_lock`** on an unstriped instance
  with holds of tens of ns.
- With a 1 µs spin, most takes park (parks are about equal to requests).
  A worker whose 16 tasks have all parked goes to sleep on its condition
  variable (28% idle), and every release then pays a cross-thread wake.
- A 10 µs spin recovers most of it (3.0M), but burns 80% of the CPU as
  spinning does.
- `os_unfair_lock`'s kernel-assisted hand-off is the better contended
  short-hold lock in this model.
- I didn't tune further: an idle-worker spin (`IDLE_SPIN_US`) didn't help
  at a 1 µs take spin in a quick probe.

**L, a 100 µs hold folded into `put`** (8 workers, plus one background task
a worker that never touches the table):

| | req/s | wait p50 / p99 / max | wasted CPU % | stalled % | background ops/s |
|---|---|---|---|---|---|
| park (a) | 19,922 | **35.1 / 42.8 / 48.5 ms** (worst round 90.5 ms) | **1.7** | 0.1 | 3.42M |
| handoff (a) | 19,392 | **6.5 / 7.8 / 8.6 ms** | **1.7** | 0.1 | 3.44M |
| spin (b) | 20,081 | 0.4 / 13.8 / 48.0 ms | **87.5** | 0.1 | 155 |
| unfair (b) | 19,682 | 247 ms / **1.6 s** / 1.6 s | 0.7 | **87.0** | 153 |

How to read the columns:

- **Wasted CPU** is CPU% minus timed useful work% (the holds and the
  background work), over all workers' time.
- **Stalled** is the time a worker is off the CPU without being idle by
  choice: here, the thread blocked in the kernel lock.
- **Request throughput** is bound by the lock: about 20k a second, about
  1 / 100 µs at 50% puts, the same under every strategy.

What the long hold shows:

- **Parking keeps the other workers' wasted CPU at 1.7%** (0.3% of it
  spinning), against **87.5%** for a spin lock. That's a hit.
- **The workers stay useful.** With parking, the background tasks run at
  3.4M ops a second, against about 155 under either thread lock. A worker
  blocked or spinning on the table runs none of its other tasks. This is
  the case decision 10's "a thread never blocks while its task is parked"
  exists for.
- **Without a hand-off, a parked waiter starves for tens of milliseconds:**
  p50 35 ms and a max of 48 to 90 ms. That is 5.4× the hand-off's p50. A
  woken waiter mostly loses to a barging taker on the releaser's own
  worker. That's a hit.
- **With the hand-off, the wait is the queue,** not starvation. About 64
  put waiters × 100 µs is about 6.5 ms, and the max is within 30% of the
  p50.
- **`os_unfair_lock` is far worse than r5 measured:** p50 0.25 s and a max
  of 1.6 s here, against r5's 16 to 75 ms, and it stalls 87% of all
  worker time.

## X3b: a contended shared instance under `per_core`

### Verdict

- **For a contended shared instance under `per_core`, Ren should ship each
  operation to the instance's home core (H), not park on a take.**
  - On X3's contended short-hold server, shipping ran **2.7×**
    `os_unfair_lock`'s throughput, with per-round ratios of 2.2 to 3.6 at
    load 10 to 14. At load 8 or below it ran 5.4 to 5.7×.
  - That is **5.9×** plain parking, and 24× at load 8 or below.
  - It needs no take spin and no starvation rule, since the rings are FIFO.
  - Uncontended, it costs nothing measurable.
  - One thing is required with it: **a worker spins about 5 µs before
    sleeping.** Without that spin, shipping is 3 to 5× slower. Workers fall
    asleep, replies must wake them, and the home spends 94% of its time in
    its drain loop, mostly in those wakes.
- **Adaptive parking (P2) doesn't fix parking.**
  - It ran 0.7 to 1.5× plain parking, depending on load.
  - It wasted 46 to 75% of the CPU spinning.
  - It stayed below `os_unfair_lock` in every round.
  - Under `per_core`, parking is only worth keeping where a core can't
    reach the instance's home.
- **For `at` under `per_core`, ship each operation by default. Move the
  task only for long blocks, from about 8 operations up.**
  - With a dedicated home, so the comparison is fair, moving the task ran
    0.16× shipping's throughput at 1 operation a block, 0.51× at 4 and
    **1.70× at 16**.
  - A move costs the home about 0.5 µs a block: two hops, a run-queue turn,
    and the task's frame lines changing cores. A shipped operation costs it
    about 35 to 45 ns.
  - Moving needs a fairness rule at the home. When hopped tasks ran next,
    they starved the home's own tasks for 0.2 to 1.8 s.
  - When the home also serves requests, its own connections win its run
    queue. The other workers' moved requests then ran at 0.16 to 0.86× of
    shipping.
  - The compiler can choose per block: count the block's operations, ship
    up to about 8, and move a block that loops.
- **Where shipping loses:**
  1. **Latency on a lightly contended instance (M).** Throughput matched the
     best lock within 6%. But a shipped operation waits about 130 µs at p50,
     against 0.2 µs under any lock.
     - It waits for the home's next scheduling point, and then for its own
       worker's next scheduling point.
     - Draining the rings at every scheduling point and running resumed
       tasks next (`FAST`) cut that to 10.5 µs at p50, with a p99 of
       309 µs.
     - That is still 50× a lock's latency for an operation nobody contends.
  2. **The home is a single point of preemption.**
     - If the OS deschedules the home thread, every worker that needs the
       instance stalls, not just the holders of one short critical section.
     - On this machine, at load 13 or more, ship at 12 workers fell below
       ship at 8 (9.9M against 13.4M).
     - In M, remote workers sat 16 to 29% idle.
  3. **Long holds starve the home's other work.** With a 100 µs hold, the
     home was 91 to 98% busy running other cores' puts. Its own background
     task got almost nothing. The other seven workers kept theirs flowing.
  4. **One home caps the instance at about 30M short operations a second**,
     about 33 ns each, measured with a dedicated home at 78 to 84% busy.
     Past that, stripe.
- **A hybrid is the obvious next experiment, and it's untested here:**
  - an uncontended operation takes a CAS from any core and runs in place,
    keeping M's 0.2 µs;
  - a contended one ships to the holder or the home, a delegation lock or
    flat combining.
  - That might keep M's latency and C's throughput.
  - If it's adopted, runtime.md's "A shared take" paragraph becomes:
    "under `per_core`, an operation off its home core is a D.Call".

| prediction | measured | verdict |
|---|---|---|
| (H) beats plain parking on C by over 2× | **5.9×** [3.7..11.9] per round (focus session); 24× at load ≤ 8 | **hit** |
| (H) within 1.5× of `os_unfair_lock` on C | **2.7× faster** [2.2..3.6]; 5.4 to 5.7× at load ≤ 8 | **hit, exceeded** |
| (H) near-zero wasted CPU | take spin 0%. Spin before sleeping 4.8 to 8.2%, and it's required: without it, 3 to 5× lower throughput | **hit for take spin.** The idle spin is a cost the design needs |
| (H) capped by the home core | the dedicated home ran 78 to 84% busy at 20 to 25M ops/s, so about 30M ops/s at most. At 8 workers, round-trip latency × calls in flight bound it first (home 45 to 71% busy). Past 8 workers, home preemption did. | **partly**: the cap exists but isn't what bound C |
| (H) 100 µs hold: background work flows like parking | background ops/s 2.14M (2.94M with FAST) against parking's 2.74M and `os_unfair_lock`'s 150. The loss is the home's own task. | **hit** |
| (H) mixed: within 10% of the best | throughput 0.99× parking, 1.00× `os_unfair_lock` per round; median 3.74M against the best 3.99M (−6%) | **hit on throughput.** Shared-op latency: 130 µs against 0.2 µs |
| (P2) recovers ≥ half of the parking → `os_unfair_lock` gap on C, under 20% wasted | 0.87× parking [0.53..2.41] (focus), 0.70× (session 2), 1.51× (session 1, load ≤ 8: 2.15M, 15% of the gap); wasted 46 to 75% | **miss on both** |

### What was built

`x3b/` reuses X3's server model: 8 workers, 16 connection tasks each,
FIFO run queues, every 8th recv suspending, and one unstriped memtable,
50% puts. It adds:

- **(H) `ship` and `shipded`.**
  - The memtable lives on worker 0.
  - Off the home, `mt_put` and `mt_get` push a 32 B D.Call record (op,
    key, value, task) onto that worker's SPSC ring to the home, and the
    task suspends in the register convention.
  - On the home, they're direct calls, with no lock.
  - The home drains up to 16 records a ring between its own task steps,
    runs them, and pushes replies on the reverse rings. It publishes each
    ring's tail once a pass.
  - `shipded` gives the home no connections, so 7 workers serve.
- **Why SPSC rings, one a source, rather than one MPSC queue.**
  - A push is a slot write and a release store, with no read-modify-write.
  - Seven producers never share a tail line, and a shared tail line would
    be the contended word this design exists to remove.
  - The home polls 7 tails, and a tail's line moves only when its source
    pushed. That's Seastar's choice.
  - Each ring holds 64. A full ring fails the push, and the caller waits
    for room. It never filled: at most 16 calls are in flight a source.
- **`move` and `moveded`.**
  - `handle` hops the task to the home for its `at` block of `OPS`
    operations, runs them as direct calls, and hops back.
  - The worker does the hop after `step` returns. The first version pushed
    the task from inside `handle` and hung, because the callers above
    still write their frames on the way out. That is Go's
    gopark-with-unlock problem: a task can be published to another core
    only once it has fully suspended.
- **(P2) `p2`.**
  - X3's take, but it spins while the holder's worker is on the CPU, up to
    4 µs, then parks.
  - The 1 ms hand-off is on.
  - A worker with nothing to run spins 5 µs before sleeping.
  - In this model a holder never waits inside an operation, so "holder
    running" is false only if the holder's worker is asleep. Effectively,
    P2 is a bounded spin plus the idle spin.
  - `probe_p2.sh` swept SPIN_US 1, 2, 4, 8 against IDLE_SPIN_US 0, 5, 20,
    50 on C. Every setting landed between 1.0M and 2.2M at the median, with
    11 to 54% wasted. I kept 4 µs and 5 µs.
- **`FAST=1`.**
  - The rings are drained at every recv, which is a scheduling point.
  - A task resumed by a reply or a hop goes to the front of its run queue,
    as Go's `runnext`.
- **The references,** unchanged from X3: `park`, `handoff`, `unfair`
  (`os_unfair_lock`) and `spin` (TTAS).

Latency is now a whole request's, from `next_request` to `respond`,
sampled into a 1M-entry reservoir a worker. X3 timed only the take's wait.

**Correctness** (`x3b/results/check-*.txt`).

- With `DISJOINT=1`, each connection owns its keys, so the response
  checksum and the final table depend only on contract 1 (one task's calls
  to one key run in order), not on interleaving.
- Every strategy at 8 workers gave the same checksum and table as
  `os_unfair_lock` at 1 worker with the same 128 connections (112 for the
  dedicated homes). That held for plain requests, `at` blocks of 4, and the
  mixed scenario, with and without `FAST`.
- ASan+UBSan and TSan builds of every strategy, contended, with and without
  a hold, with `at` blocks and with `FAST`, finished every request and left
  the lock and every ring clean: 138 runs. Neither sanitizer reported
  anything.

**Sessions.** The machine was busy throughout, at load 7 to 21. Each
session interleaves every variant within a round, and the ratios are taken
within a round, which held steadier than ratios of medians.

| session | file | load | used for |
|---|---|---|---|
| 1 | `raw-20261030-150854` | 7.8 → 17.9 | low-load corroboration (rounds 1 to 3, load ≤ 8.1); its U is void, from before a fix to `handle` |
| 2 | `raw-20261030-152306` | 7.8 → 16.5 | U, L, W, FAST and idle0 variants |
| focus | `focus-20261030-154449` | 9.9 → 13.6 | C, M, A (7 rounds) |
| at | `at-20261030-155106` | 7.2 → 15.2 | ship against move, home serving and dedicated (7 rounds) |

### C: 8 workers × 16 connections, short holds (focus session)

| | req/s | latency p50 / p99 (µs) | wasted % (take spin + idle spin) | idle % | messages / req | wakes / req |
|---|---|---|---|---|---|---|
| park | 2.41M [1.47..3.60] | 0.3 / 539 | 17.1 (17.1 + 0) | 23.3 | 0.27 | 0.044 |
| p2 | 2.08M [1.27..4.05] | 0.3 / 1,012 | 46.4 (43.3 + 3.1) | 24.9 | 0.27 | 0.032 |
| **ship** | **14.8M** [13.2..20.0] | 4.0 / 8.3 | **8.2** (0 + 8.2) | 42.1 | 1.64 | 0.000 |
| ship, FAST | 15.0M [13.3..19.1] | 2.5 / 10.3 | 4.8 | 44.4 | 1.83 | 0.000 |
| shipded | 14.8M [10.1..19.2] | 3.6 / 46.8 | 7.6 | 40.5 | 2.00 | 0.009 |
| spin (b) | 2.96M [2.84..3.83] | 0.5 / 18.6 | 78.0 | 0 | 0 | 0 |
| `os_unfair_lock` (b) | 5.62M [5.40..5.97] | 0.1 / 17.4 | 0 | 0 | 0 | 0 |

At load ≤ 8 (session 1, rounds 1 to 3):

| park | p2 | ship | shipded | ship, no idle spin | move | spin | `os_unfair_lock` |
|---|---|---|---|---|---|---|---|
| 1.42M | 2.15M (75% wasted) | **35.3M** | 23.4M | 6.6M | 7.6M | 4.05M | 6.34M |

How to read C:

- **Why shipping wins.** Every lock-based variant moves the lock's line and
  the table's lines between cores on every operation. Under shipping, the
  table's lines stay on the home. A ring line carries four 32 B records, and
  the home answers them in batches.
- **Messages a request.** Shipping sends 1.64 to 2.0 messages a request: a
  call and a reply for each of the 7/8 of requests that come from off the
  home.
  - Parking sends 0.27 cross-worker requeues a request, plus 0.03 to 0.24
    condition-variable wakes.
  - Neither count includes the lock line's own traffic.
- **What bounds shipping at 8 workers isn't the home.**
  - The home was 38 to 71% busy, and the other workers sat 32 to 45% idle,
    their 16 tasks all waiting on replies.
  - By Little's law, 112 calls in flight at a 3 to 4 µs round trip gives
    the measured rate. More connections a worker would raise it.
- **The idle spin is load-bearing.** Without it (`ship+idle0`), throughput
  is 4.9M (session 2) or 6.6M (session 1).
  - A worker that runs out of work falls asleep, so a reply must wake it.
  - The home's drain loop, where it sends those wakes, then takes 94% of
    its time: 0.04 to 0.065 `pthread_cond_signal`s a request at a few µs
    each.
  - This is X3's cross-thread wake again.
- **The dedicated home saturates.**
  - At load ≤ 8, `shipded` ran 20 to 25M ops/s at 78 to 84% busy, so the
    ceiling is about 30M short operations a second, about 33 ns each
    including the reply.
  - With the home also serving requests, `ship` is higher. Its own requests
    are direct calls, and its batches are larger.
- **The worker sweep** (session 2) is ship 9.2M, 10.6M, 13.4M and 9.9M at
  2, 4, 8 and 12 workers, against `os_unfair_lock`'s 7.4M, 5.9M, 5.2M and
  6.8M.
  - In session 1 ship reached 13.3M, 17.9M, 33.9M and 11.0M.
  - The drop at 12 workers is the home thread losing its core on an
    oversubscribed machine. When the home is off the CPU, everyone who
    needs the instance waits.

### U: one worker (session 2)

ns a request: park 93.8, p2 93.5, ship 87.7, move 81.8, `os_unfair_lock`
87.7, spin 88.9.

- Every spread is wide, from 71 to 400 ns, because of the load. The
  medians are within noise of each other.
- On one worker, shipping is a direct call behind a TLS compare and a ring
  poll over zero sources.
- These are about 15 ns above X3's 69 ns, because X3b timestamps every
  request.
- Session 1 showed (a) 23 ns slower than (b). That was this model's fault:
  `handle` kept its block loop's state in the frame. Moving it to C locals,
  spilled only at a suspension as X1's convention says, removed the gap.

### L: 100 µs hold in put, plus one background task a worker (session 2)

| | req/s | latency p50 / p99 / max | wasted % | stalled % | background ops/s | home busy % |
|---|---|---|---|---|---|---|
| park | 16,399 | 0.1 / 71.7 / 94 ms | 0.3 | 19.1 | 2.74M | |
| handoff | 13,002 | 6.7 / 131 / 227 ms | 0.2 | 21.4 | 2.71M | |
| p2 | 14,841 | 6.9 / 122 / 171 ms | 0.8 | 14.0 | 2.93M | |
| **ship** | 12,816 | 6.1 / 47.7 / 66 ms | **0** | 36.6 | **2.14M** | 91 |
| ship, FAST | 17,858 | 5.7 / 21.5 / 67 ms | 0 | 10.0 | **2.94M** | 98 |
| shipded | 13,692 | 5.5 / 35.7 / 59 ms | 0 | 31.3 | 2.29M | 98 |
| move | 11,431 | 0.1 / 50.8 / 103 ms | 0 | 44.8 | 1.81M | |
| spin (b) | 18,457 | 0.1 / 4.5 / 56 ms | 87.4 | 8.1 | 143 | |
| `os_unfair_lock` (b) | 19,180 | 0.1 / 0.1 / **1.26 s** | 0 | **87.4** | 150 | |

How to read L:

- **Throughput is the hold's**, about 20k a second under every strategy.
  The load spread it from 2.5k to 19.8k across rounds.
- **Shipping keeps the other workers' background work flowing**, as
  parking does. It's at 2.1 to 2.9M ops/s, against 150 under either thread
  lock.
  - What it loses is the home's own background task: the home is 91 to 98%
    busy running other cores' 100 µs puts.
  - Seven workers' worth is 3.0M, which matches.
- **A shipped put's latency is the queue,** as the hand-off's is: about
  6 ms at p50, or 64 puts × 100 µs.
  - The rings are FIFO, so no starvation rule is needed. The max was 66 ms,
    against the hand-off's 227 ms in the same session.
  - The p50 of 0.1 ms under park, move and the locks is a get or a put that
    didn't wait.
  - `stalled` is 8 to 45% for every strategy except `os_unfair_lock`. That
    is the load (16 to 21 at the time): the workers were runnable and off
    the CPU, with spreads from 0 to 71%. Only `os_unfair_lock`'s 87% is
    the lock.

### M: 10% of requests touch the table, the rest do 2 µs of local work (focus session)

| | req/s | per round, against park | shared requests: latency p50 / p99 / max (µs) | idle % | messages / req |
|---|---|---|---|---|---|
| park | 3.79M [2.57..4.28] | 1 | 0.2 / 0.5 / 21,805 | 0 | 0 |
| p2 | 3.89M [3.52..4.28] | 1.01 | 0.2 / 0.6 / 11,970 | 0 | 0 |
| ship | 3.74M [3.15..4.25] | 0.99 [0.79..1.65] | **129.7 / 246** / 25,833 | 8.3 | 0.17 |
| ship, FAST | 3.80M [3.49..4.22] | 0.97 [0.91..1.64] | **10.5 / 309** / 9,969 | 6.7 | 0.18 |
| `os_unfair_lock` (b) | **3.99M** [3.32..4.28] | | 0.2 / 0.9 / 13,560 | 0 | 0 |

How to read M:

- **Throughput: a hit,** within 6% of the best. 90% of the time is local
  work, which every strategy runs the same.
- **The shared operation's latency is the cost.** Without FAST, a call off
  the home waits two turns:
  - one for the home's next pass, which comes between task steps, and a
    step is about 8 requests, or 16 µs;
  - one for a turn on its own worker, behind 15 tasks' steps, since a
    resumed task joins the tail.
  - FAST, which drains at every scheduling point and runs resumed tasks
    next, removes most of that.
- **Remote workers sit 7 to 8% idle,** with all their tasks waiting on
  replies. It's worse when the home thread loses its core: at load 21
  (session 2, one run), remote workers sat 16 to 29% idle with FAST and 29
  to 57% without it, against 0.2 to 1.2% under parking.

### `at` blocks under `per_core`: ship each operation, or move the task (at session)

Requests are `at` blocks of 1, 4 or 16 operations. Ratios are taken within
a round. "Remote" counts only requests that completed on the 7 non-home
workers.

| ops a block | moveded / shipded | move / ship (remote req/s, home serving) | shipded / `os_unfair_lock` | moveded / `os_unfair_lock` |
|---|---|---|---|---|
| 1 | **0.16** [0.10..0.22] | 0.16 [0.10..0.25] | 2.89 | 0.34 |
| 4 | **0.51** [0.48..0.61] | 0.46 [0.08..0.95] | 1.69 | 0.91 |
| 16 | **1.70** [1.10..2.13] | 0.86 [0.36..1.66] | 0.80 | 1.47 |

Absolute medians: `shipded` 15.5M, 6.08M and 1.37M req/s. `moveded` 1.99M,
3.18M and 2.47M. `os_unfair_lock` 5.77M, 3.52M and 1.69M.

- **The crossover is about 8 to 9 operations a block**, by interpolating
  the dedicated ratios.
- That matches the per-op costs at the home:
  - a moved block costs about 0.5 µs of home time: 1 / 2.0M blocks at 1
    operation;
  - a shipped operation costs about 35 to 45 ns: 15.5M ops/s at 71% busy;
    24M at 74% for blocks of 4;
  - 0.5 µs / 45 ns ≈ 11 operations.
- **Moving funnels every moved task through the home's run queue.**
  - A moved block waits 25 to 42 µs at p50 even at 1 operation, because
    112 tasks share one queue.
  - Its workers sleep and wake as all their tasks leave, at 0.6 to 0.8
    wakes a request.
- **With the home also serving, moving is worse.** The home's own 16
  connections take most of its run queue, so remote requests fall to 0.16
  to 0.86× of shipping's.
- **Running hopped tasks next (FAST, session 2) starved the home's own
  tasks:** max latency 0.2 to 1.8 s, and lower throughput.
  - Moving needs a fairness rule at the home, for example a budget of
    hopped tasks a pass.
  - Shipping needs none: a shipped call is a record, not a task, and the
    home answers it between its own tasks.
- **Both beat a thread lock once blocks are long.** At 16 operations,
  moving ran 1.47× `os_unfair_lock`, which takes the lock once an
  operation.

## X5: static frame-stack sizing, and the spare chunk

`x5/frames.c` uses X1's convention. A parked task runs serve → read → recv
(64 B frames: a 32 B header plus 32 B of locals) and parks in recv.
100,000 tasks run in a fresh process per policy, 5 rounds. After
measuring, three rounds of replies are delivered, each task's total is
checked, and every chunk is checked as freed.

**Bytes per parked task** (the spread was under 1 B across rounds):

| policy | malloc zone `size_in_use` | Σ `malloc_size` | `phys_footprint` | `resident_size` |
|---|---|---|---|---|
| today: segment = body frame, 4 KiB chunk | **4,208** | 4,208 | 4,230 | 4,227 |
| static bound (192 B segment, cap 256) | **240** | 240 | 252 | 245 |
| static, spare made before parking, freed at park | 240 | 240 | 253 | 245 |
| static, spare kept at park | 4,336 | 4,336 | 4,369 | 4,360 |

- That is a 17.5× reduction, a hit. The prediction's 290 B assumed the
  prototype's 96 B task header. This one is 48 B: §2b dropped `task` from
  frames, and the size moved to a saved `sp`.
- The last row shows why §2g frees the spare at park. Otherwise one deep
  excursion, made once, keeps a parked task at 4.3 KB.

**The chunk boundary** (X7's prediction), ns a call (n = 5M, 7 reps, 5 rounds):

| | in segment | past it, chunk freed on empty | past it, one spare kept |
|---|---|---|---|
| register convention, clang | 1.16 [1.15..1.17] | 22.3 [21.9..22.7] | **4.22** [4.21..4.22] |
| the same, grow and retire inlined | 1.15 | 20.3 | **2.68** [2.68..2.68] |
| register convention, tcc | 8.43 | 31.9 | 13.8 |
| prototype convention (r2's `fastpath.c`, `ren`) | 5.27 [5.25..5.35] | 23.6 [23.1..26.6] | **6.64** [6.56..6.95] |

- The spare removes the malloc. 0 mallocs a call against 1, and the
  15 to 20 ns cliff is gone.
- "Within 1 ns of in-segment" is a miss:
  - +1.4 ns in the prototype's convention;
  - +3.1 ns in the register convention with out-of-line grow and retire;
  - +1.5 ns with them inlined.
- What remains is two calls and about ten pointer updates a crossing. For
  a loop that crosses the boundary every iteration, inlining the spare-reuse
  path is worth 1.5 ns. Most call sites can't overflow, so it rarely
  matters.

**A gap in SYNTHESIS §5, found while building this.** §5 retires a chunk
only in the trampoline, by the frame's `REN_FIRST_IN_CHUNK` flag. That
covers the resume path. On the fast path, though, a callee in a chunk
returns DONE straight to its caller, and nothing retires the chunk. Also,
`ren_bump` compares against a single `t->limit`, which is wrong once `sp`
moves back to the segment while `t->limit` still names the chunk. The fix
used here:

- `t->limit` is the current region's limit; grow sets it and retire
  restores it;
- a call site that can overflow keeps a `grew` flag (a register), and
  retires the chunk after a DONE;
- the flag is still needed for the resume path.

The cost is one predictable branch after such calls, and none where the
static bound proves no overflow.

## Noise and caveats

- **The load was 2 to 8 throughout.** X1 and X5 are single-threaded, and
  their spreads are within 3%, except one 29.6 ns outlier in one round of
  X1's `reg_clang pingpong`.
- **X3 ran at load 5.5 to 8.1 with 8 worker threads,** so some workers
  shared cores with other agents' work. The ratios are stable across
  rounds, but the contended absolute numbers would move on an idle machine.
- **X3's wait percentiles count only waits that ended before the stop
  flag.** Under `unfair`, few long waits end in the window, so its p99 and
  max (both 1.6 s) are lower bounds.
- **X3's "wasted" for parking (1.7%) includes run-queue and wake overhead,
  not just spinning** (0.3%).
- **X3's model has no network.** `recv` is answered inline, so the 69 ns a
  request is mostly hashing and the table. A real request with syscalls
  would make the uncontended difference smaller still.

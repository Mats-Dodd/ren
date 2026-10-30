# Runtime-frames experiments X1, X3 and X5: results

These are the first three experiments from
[research/runtime-frames/SYNTHESIS.md](../../research/runtime-frames/SYNTHESIS.md) §7.

**Machine.** All runs were on the owner's Apple M4 Max: 16 cores (12P + 4E),
macOS 15.1, Apple clang 16.0.0, and tcc 0.9.28rc (mob e23dabe). The machine is
shared with other agents. The 1-minute load average before each round was:

| experiment | load |
|---|---|
| X1 | 1.9 to 3.8 |
| X5 | 3.3 to 5.7 |
| X3 | 5.5 to 8.1 |

Each variant ran interleaved with the others, in 5 to 7 rounds. Figures are
the median over rounds, with [min..max] across rounds after them. Raw lines
and summaries are in `x*/results/`. The commands are in each directory's
README.

## Verdicts

| | predicted | measured | verdict |
|---|---|---|---|
| **X1** register convention | nested round trip from about 31 ns to within 20% of the inlined `pingpong` | 32.5 → **19.2 ns** [19.1..19.6]. That is 1.21× the inlined 15.9 ns. With the bounds check dropped: 18.9 ns (1.19×). With put and get kept out of line: 21.0 ns (1.32×). | **Borderline.** It hits only with release's bounds-check elimination. The nested cost fell 41%. |
| **X3** shared takes as suspending | under 3% throughput and under 10% code growth uncontended. With a 100 µs hold, parking keeps wasted CPU under 10% where spinning burns it, and without a hand-off a waiter starves for ms. | Throughput: **+0.3%** ns a request against `os_unfair_lock`. Code: the path's text grew **3.6×** (424 → 1,524 B), and the model's whole text grew 17.6%. Long hold: wasted CPU **1.7%** parked against **87.5%** spinning. A waiter's p50 is **35 ms** without a hand-off and **6.5 ms** with one. | **Throughput, wasted CPU and starvation: hit. Code size: miss.** Not predicted: with short holds at 8 workers, parking runs at **4.4× below** `os_unfair_lock`. |
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

# origin-counters: results

Design, schemes and predictions are in [PLAN.md](PLAN.md). The machine is an
Apple M4 Max (12 P + 4 E), macOS, with every thread at
`QOS_CLASS_USER_INTERACTIVE` and no pinning. Other agents were running
throughout: load1 was 7 to 12 during the passes. **Read absolute numbers as
±40% and compare ratios.**

## What was run

| file | what |
|---|---|
| `results/measure-20261029-234628.txt` | the full sweep, one pass: 4 workloads × spin 0/100/1000 × workers 1–16 × 6 schemes, plus the side runs (N = 64, W4 at N = 16) |
| `results/measure-20261029-234915.txt` | key cells rerun 3×: every workload and spin at 8 and 12 workers |
| `results/key-cells.txt` | those cells pooled over all 4 passes: median ratio to `none`, [min–max] |
| `results/fuel-20261029-234828.txt` | fuel accuracy: 3 reps × {4, 16 workers} × W4 (F = 2000) and W5 (F = 80) |
| `results/smoke.txt` | `--check` and TSan for every scheme × workload × {1, 3, 8} workers |
| `results/investigations.txt` | the runs behind the three surprises below |
| `results/v1-unbounded-baseline/` | the first matrix. **Superseded**: its `none` baseline had no intake bound (see surprise 3) |

All 1,512 timing lines say `ok=1`. Every delivery was made, every origin
closed with exactly its tree's deliveries, and no control message arrived
for a closed origin. Under TSan, all sound schemes are clean. `naive`
fails, as designed: on W4 it closed origins while their mail was still
being delivered (`premature=1`, `badcount=2` at 8 workers).

**Thread counts.** Trust the 8- and 12-worker columns. At 16 workers on a
machine with load 7–12, 16 spinning schedulers are oversubscribed. `none`
itself falls from 471 M/s at 12 workers to 198 at 16 (W1, spin 0), and
every scheme's 16-worker cell moves by 2× between passes. The 1-worker
cells carry ±25% because a lone unpinned thread may land on an E core.

## Throughput: ratio to `none` (median over 4 passes [min–max])

These are the 8- and 12-worker cells. `none` is in M deliveries/s.

**Spin 100 ns,** the realistic small op:

| wl | w | none | atomic | vector | credit | credit_soft | home |
|---|---|---|---|---|---|---|---|
| W1 doc→index | 8 | 61 | **0.59** [.44–.67] | 0.84 [.64–.92] | 0.81 [.64–.95] | 0.79 | 0.86 |
| | 12 | 87 | **0.65** [.47–.66] | 0.81 | 0.81 | 0.82 | 0.78 |
| W2 fan-out 16 | 8 | 61 | **0.75** [.67–.84] | 1.02 | 1.03 | 1.00 | 0.94 |
| | 12 | 91 | **0.65** [.63–.73] | 0.82 | 0.87 | 0.81 | 0.86 |
| W3 chain 8 | 8 | 57 | **0.59** [.54–.70] | 0.86 | 1.01 | 1.04 | 0.89 |
| | 12 | 84 | **0.66** [.65–.70] | 0.81 | 0.99 | 0.97 | 0.76 [.72–.79] |
| W4 hot, N = 4 | 8 | 60 | **0.42** [.36–.57] | 0.99 | 1.00 | 1.03 | 0.97 |
| | 12 | 85 | **0.30** [.29–.54] | 0.95 | 0.99 | 0.89 | 0.89 |

**Spin 0,** an empty op, so this shows the accounting's raw cost:

| wl | w | none | atomic | vector | credit | credit_soft | home |
|---|---|---|---|---|---|---|---|
| W1 | 8 | 400 | **0.24** | 0.48 | 0.50 | 0.53 | 0.50 |
| | 12 | 433 | **0.26** | 0.53 | 0.50 | 0.52 | 0.46 |
| W2 | 8 | 483 | **0.36** | 0.64 | 0.66 | 0.64 | 0.61 |
| | 12 | 720 | **0.24** | 0.41 | 0.35 | 0.35 | 0.33 |
| W3 | 8 | 239 | **0.35** | 0.67 | 1.14 | 1.16 | 0.61 |
| | 12 | 304 | 0.36 | 0.48 | 0.67 | 0.60 | **0.22** |
| W4, N = 4 | 8 | 295 | **0.11** | 0.95 | 0.96 | 0.94 | 0.62 |
| | 12 | 321 | **0.09** | 0.90 | 0.84 | 0.72 | **0.23** [.13–.71] |

**Spin 1000 ns.** Every scheme is within 0.94–1.06 of `none` on W1–W3 at
8–12 workers. On W4, `atomic` is 0.88 and 0.85 and the others 0.90–0.98.

How to read the spin-0 table:

- **Even on one core, every scheme pays about 10 ns per delivery** that
  `none` doesn't. That's the per-origin bookkeeping all schemes share: the
  admission slot, initialising the home record, and the close-latency
  timestamps and histograms. On W1 at spin 0, credit is 0.44× `none` at
  **1 worker**. So the floor of about 0.5× there is bookkeeping, not
  cross-core cost. Compare schemes with each other, not with that floor.
- At spin 0, differences under about 20% between the cheap schemes are
  queueing dynamics. Surprise 2 below shows the W3 order flipping with the
  edge's intake threshold.

Control messages per delivery, at 16 workers and spin 100:

| | atomic | vector | credit | home |
|---|---|---|---|---|
| W1 | 0.50 (CLOSE) + 1 RMW | 0.50 | 0.50 | 0.50 |
| W2 | 0.06 + 1 RMW | 0.88 | 0.88 | 0.88 |
| W3 | 0.10 + 1 RMW | 0.84 | **0.10** | **1.58** |
| W4 | 0.00 + 1 RMW | 0.18 | 0.13 | **1.01** |

Batching per pass is why `vector` and `credit` stay cheap on W4: up to 32
deliveries fold into one message per origin. On a chain, credit hands its
whole weight to the one child, so only the final leaf returns anything.

## Close-detection latency (µs, p50 / p99, median of 3 reps)

| | atomic | vector | credit | home |
|---|---|---|---|---|
| W1 spin 0, w = 8 | 3.9 / 12 | 2.3 / 5 | 2.3 / 5 | 2.5 / 5 |
| W1 spin 100, w = 8 | 9.5 / 23 | 8.2 / 18 | 8.3 / 17 | 8.5 / 17 |
| W1 spin 1000, w = 8 | 59 / 117 | 63 / 117 | 61 / 115 | 64 / 117 |
| W2 spin 100, w = 12 | 10.7 / 55 | 11.0 / 41 | 10.2 / 40 | 9.7 / 41 |
| W3 spin 100, w = 12 | 10.7 / 48 | 7.5 / 42 | 7.5 / 36 | 6.3 / 27 |
| W4 spin 0, w = 12 | **26.7 / 149** | 2.8 / 18 | 2.2 / 20 | 3.0 / 22 |
| W4 spin 100, w = 12 | **26.0 / 165** | 13.7 / 60 | 14.7 / 59 | 6.2 / 45 |
| W4 spin 1000, w = 12 | 45 / 405 | 75 / 448 | 77 / 544 | 57 / 672 |

- **Close latency is set by pass length, not by the scheme.** Mail and
  flushes are both published at the end of a pass, so the home learns of a
  close one pass plus one hop after the last delivery. That is about 2–3
  µs at spin 0, about 8 µs at spin 100, and about 60 µs at spin 1000,
  where a pass is up to 64 ops of 1 µs.
- `atomic`'s "instant" detection buys nothing: its CLOSE rides the same
  ring. When the line is contended (W4) it is 2–10× worse, because the
  closer is late reaching the line.
- `home` is best on W4, because the home sees every post and decrement
  itself.

## Admission, N = 64, spin 100 (M/s; ratio to credit)

| | w = 4 | w = 8 | w = 12 |
|---|---|---|---|
| W1: atomic / vector / credit / home | 23.4 / 26.0 / 26.4 / 26.8 | 32.1 / 37.5 / 37.4 / 37.5 (atomic 0.86) | 37.9 / 48.6 / 38.0 / 31.6 |
| W2: atomic / vector / credit / home | 30.1 / 31.8 / 31.9 / 32.0 | 44.0 / 55.9 / 59.6 / 55.6 (atomic 0.74) | 59.5 / 53.1 / 67.4 / 60.0 |
| W4 at N = 16: atomic / vector / credit / home | 27.2 / 31.9 / 32.3 / 30.6 | 34.6 / 60.8 / 62.0 / 59.6 (atomic 0.56) | 45.8 / 63.7 / 89.6 / 80.1 |

These are single-pass numbers.

- At N = 64, admission binds. W1 at 8 workers reaches 37 M/s against 58
  unbounded.
- Lifetime is about 2–8 µs, which is two hops plus a pass, and close
  latency is part of it.
- Because every scheme's close latency is about the same, the ranking is
  the ranking from the unbounded runs. `atomic` loses 14–26% on W1 and W2.
  It loses 44–49% on W4, where its longer close latency holds slots longer.
  The 12-worker column is noisy.

## Fuel accuracy (3 reps; posts made before the scheme noticed, minus F)

| scheme | W4, F = 2000, 4 workers | W4, F = 2000, 16 workers | W5 skew (80 posts), F = 80 |
|---|---|---|---|
| atomic | 0 (measured −4 … +0) | 0 (measured −6 … +24\*) | never panics, in all runs |
| home | 0 (−4 … 0) | 0 (−4 … 0) | never panics |
| vector (soft) | mean 1,190–1,255, max 1,828 | mean 774–1,105, **max 2,515** | never panics |
| credit_soft (soft) | mean 2,198–2,486, **max 3,124** | mean 1,746–1,898, max 3,176 | never panics |
| credit (split) | never exceeds F. Every origin panics at depth 5 after **1,364 posts in every run**; the first panic comes after 24–220 posts | as at 4 workers: 1,364 posts | **panics in every origin after exactly 20 posts** in every run: child 0 gets (80−16)/16 = 4 fuel for its 64-hop chain |

\* Exactness is by construction: `atomic`'s RMW returns the count, so the
(F+1)th post is refused before it is sent, and `home` counts each post
before forwarding it. The measured −6 … +24 compares timestamps taken
after the RMW on different threads. One thread was preempted between its
RMW and reading the clock.

Soft pooled fuel overshoots by **0.5–1.6× F** at F = 2000, and the amount
changes from run to run.

- `vector` learns of posts once per pass per core. A hot origin's tree
  makes thousands of posts across 16 cores within a few passes.
- `credit_soft` learns of a subtree's posts only when its leaves return.
  Debt below 64 rides on in-flight mail.

Both bounds scale with how wide and how fast the tree is, not with F. A
soft fuel can promise "a runaway is caught eventually", not "at most F".

## Predictions

| | prediction | result | held? |
|---|---|---|---|
| P1 | W1, spin 0, 8–16 workers: message schemes 0.5–0.75× `none`; `atomic` no better, at 0.4–0.65×. Spin 1000 within 10% | message schemes 0.46–0.53, `atomic` **0.24–0.26**. About 0.45 of the gap is single-core bookkeeping that every scheme shares (1 worker: 0.44). Spin 1000: 0.94–1.06 | **partly**: the ranking held, and `atomic` is worse than predicted (2 line transfers per origin cost as much as all the rest) |
| P2 | W2, ≥ 8 workers, spin 0: `atomic` ≤ 0.75× credit; vector, credit and home within 15% of each other | `atomic`/credit 0.55 (8), 0.69 (12). The others are within 6% at 8 and within 20% at 12 | **yes** (at 12 workers the three are 20% apart, not 15%) |
| P3 | W3: `home` slowest at spin 0, ≤ 0.8× credit; credit cheapest; `atomic` in between | home/credit 0.54 (8), 0.33 (12); credit cheapest, about 1.0× `none`. `atomic` is 0.35 at 8, *below* home there | **mostly**: `atomic` isn't between them at 8 workers, it's the slowest |
| P4 | W4: `atomic` ≤ 0.5× credit at 8–12 workers, spin 0/100, narrowing at 1000; `home` ≤ 0.6× credit at 16 workers, spin 0; credit within 15% of `none` | `atomic`/credit 0.11, 0.11 (spin 0), 0.42, 0.30 (spin 100), 0.93, 0.90 (spin 1000). home/credit 0.65 (8), 0.27 (12), and the 16-worker cell is unreliable. credit/none 0.96 (8), 0.84 (12) | **yes** |
| P5 | `atomic` lowest close p50 on W1; message schemes within 2×; p99 set by pass length; on W4 `atomic` closes sooner but lives longer | p99 is set by pass length (yes). Message schemes are within 2× of `atomic` (yes). `atomic` is **not** lowest on W1 at spin 0/100 (3.9 vs 2.3 µs). On W4 `atomic`'s close latency is **worse** (27 vs 2–15 µs) | **partly**: the hop dominates, and contention makes `atomic` slower to notice, not faster |
| P6 | N = 64: ranking as P1/P2, with differences ≤ 20% | `atomic` 0.86 (W1), 0.74 (W2), 0.56 (W4 at N = 16); the others within 6% of credit | **mostly**: W2 and W4 exceed 20% for `atomic` |
| P7 | atomic and home exact; vector hundreds to about 2,000 at 16 workers; credit_soft a few thousand; split never exceeds F and panics early, deterministically, on W5 | exact; vector max 2,515; credit_soft max 3,176; split 1,364 and 20 posts in every run | **yes** (vector slightly above the band) |
| P8 | determinism, by reasoning | below | — |

## Surprises, and what caused them

1. **In the first matrix, schemes beat `none` by up to 1.8×.** `none` has
   no admission, and the edge's intake rule only looked at the local run
   queue. A post leaves its core, so the run queue stays short, and every
   core opened its whole quota at once into the rings and spill queues.
   That gave 0.46 ops per pass against credit's 18.5. The fix is one
   intake rule for every scheme: open only while run queue + unread
   inbound + spill < 64. That's Seastar's "work before intake". The old
   matrix is kept in `results/v1-unbounded-baseline/`.
2. **On W3 at spin 0 and 8 workers, credit was 1.14× `none` in 4 of 4
   passes.** Admission isn't the cause: N = 512, 4,096 and 65,536 give the
   same result. The edge's intake threshold is. Built at 16, 64 and 256,
   `none`/credit went 1.15×, 1.0× and 0.83× (`results/investigations.txt`).
   At spin 0, ordering within about 20% is queue depth, not accounting.
3. **The first spin loop was too cheap.** A dependent multiply chain is
   independent from one call to the next, so the out-of-order core
   overlapped consecutive calls: 100 ns of it cost about 60 ns. It was
   replaced with calibrated `isb`, which serializes, before any of the
   recorded runs.

## Determinism (P8), by reasoning

`sim` replays from a tape that decides every scheduling choice, and the
protocol messages of any scheme are just more scheduled events. So under
`sim` **every scheme is deterministic**. The real question is decision
18's claim, "a journal from a run on one thread replays on sixteen". A
journal records each key's delivery order and the choices made at the edge.
It does not record how deliveries on different cores interleaved.

- **Close.** In every sound scheme an origin is logically closed at its last
  delivery, which is a function of the deliveries alone. What depends on
  timing is when the home *learns* it: one pass plus one hop later in every
  scheme, and more under contention for `atomic`. That moves when an
  admission slot frees, and so which waiting edge call gets it. That's the
  same kind of choice as a lock handoff. The journal already has to record
  edge waits, so close doesn't separate the schemes. `settled()` returns
  after the logical close in all of them.
- **Pooled exact fuel (`atomic`, `home`).** Whether an origin exceeds F is
  deterministic, if its tree's total post count is. *Which* post is the
  (F+1)th is fixed by the global order of that origin's posts, and that
  order is set by timing:
  - for `atomic`, by the order the RMWs reach the line;
  - for `home`, by the order routes arrive at the home core.

  A journal recording only per-key order doesn't fix it, so on replay the
  panic can land on a different post, after a different set of side
  effects. It can be made exact:
  - `atomic` can journal the count each RMW returned with each post;
  - `home` can journal the home's arrival order. It's already sequential,
    on one core.

  Replay must then force that order, which ties replay to it.
- **Pooled soft fuel (`vector`, `credit_soft`).** This has the pooled
  problem, plus a notice point that is late by 0.5–1.6× F depending on
  timing. Both the panic's moment and the work done before it differ
  between runs, even with an identical delivery order. **It cannot replay
  exactly** unless the flushes themselves are journalled.
- **Split fuel (`credit`).** An op's fuel is a function of its message's
  causal path: the root's F, minus each ancestor's post count, divided
  among its siblings. Each ancestor's post count depends only on that
  actor's own delivery order, which the journal records. So whether an op
  panics, and which op it is, **replays exactly at any thread count**.
  W5 measured it: 20 posts, then a panic at the same hop, in every one of
  12 runs at 4 and 16 workers. A side effect: with split fuel the
  product of fan-outs along any path is ≤ F < 2^32. That makes weight
  underflow impossible with a 2^63 root, since an op splits its weight
  exactly at its end. Under pooled fuel, underflow is reachable: a 64-level
  binary caterpillar has 2^64 leaves' worth of splitting and only 128
  posts. Then `credit` needs Mattern's exponent representation, or
  borrowing from the home.

## What this implies for open question 8

These are the tradeoffs, stated plainly.

1. **Don't use a shared atomic per origin under `per_core`.** It is the
   most expensive scheme in every multi-core cell below spin 1000.
   - On the common W1 case at spin 100 it costs 0.59–0.65× `none`, against
     0.8–0.86× for the message schemes.
   - On a hot origin it collapses to 0.30–0.42× at spin 100 and about
     0.1× at spin 0.
   - Its close detection isn't faster, because the CLOSE still takes a
     hop.

   This is S1 from many-cores (one atomic against padded stripes) showing
   up again.
2. **Weight-throwing credit (Mattern/Huang), split at the op's end and
   batched per pass, is the cheapest exact close detector.**
   - It is within 0–20% of no accounting at spin 100 in every workload. On
     chains and hot trees it is indistinguishable from `none`.
   - It uses 0.10–0.88 control messages per delivery, sends one message
     for a whole chain, and never touches a shared line.
   - It is sound by conservation.
   - `vector` (X10) costs about the same and is also sound. It needs
     W-sized vectors and multi-part flushes, and has no advantage.
3. **Pooled fuel can be exact and cheap, or replay-exact, but not both
   without journalling a counter's order.**
   - Exact pooled fuel needs one serialization point per origin. Its cost
     is the gap between `atomic` or `home` and credit above.
   - `home` is fine when the root makes the posts (W1, W2: 0.78–0.94×) and
     costs an extra hop per interior post. It reaches 0.76–0.97× at spin
     100 on chains and hot trees, and 0.2–0.6× at spin 0, where the home
     core becomes the bottleneck.
   - Even exact, the panic point is a timing-dependent post unless the
     journal records the order.
   - Soft pooled fuel is cheap but overshoots by about F with a
     timing-dependent amount, so it is neither a stated bound nor
     replay-exact.
4. **The one scheme that keeps replay exact at no measurable cost is
   credit with split fuel**: `credit` here. Its price is a semantic
   change, not a cost.
   - F becomes a per-branch budget. A branch exhausts while siblings hold
     unused budget: W5's 64-hop relay panics at hop 4 under F = 80, which
     is exactly enough pooled.
   - Fan-out divides the budget at each level. A balanced 4-ary tree to
     depth 6 makes 1,364 of its 2,000.
   - TON has these semantics.
   - Split fuel bounds every branch's depth and width, so it still gives
     the N·F memory bound (total posts ≤ F per origin).
   - It also guarantees the weight never underflows.

   If Ren keeps pooled F, the practical form is credit for closing plus
   `home`-style counting. Route a post through the home only when the
   poster isn't the home, and journal the home's count. That makes the
   common edge-op-posts case free and charges interior posts one hop.

The choice for the owner is semantic. Is "F per origin, pooled" worth one
of these?

- An extra hop per interior post, plus a journalled counter order, for
  exact replay.
- An overshoot of about F, with no exact replay.

The alternative is "F per causal branch": TON's model, which is free and
replays exactly.

Caveats:

- This is one machine, under shared load, with one transport design:
  per-pass batching, 32-op passes and spinning cores.
- `work_stealing` wasn't modelled. There, an origin's ops run wherever,
  so credit and `vector` need per-worker state that tasks can migrate
  away from.
- Parking wasn't modelled. A parked core delays its flush until it wakes,
  which matters for close latency (4–8 µs per wake in many-cores P1), and
  more for credit and `vector`, whose returns ride on the next pass.

---

## Part 2: the outbox

The design, the two new schemes and predictions Q1–Q7 are in PLAN.md
§"Part 2". All of part 1's results above stand: `credit`'s code and every
earlier scheme are unchanged.

### First, a correction to the premise

The halving problem isn't in part 1's data. `credit` already releases an
op's posts together and splits weight and fuel *exactly* over their count.
The harness's `children()` gives an op its whole post list at the end, which
is a free outbox. W5's 64-hop branch panicked at hop 4 because the root's 16
posts **split 64 fuel among 16 siblings**, giving 4 each. That is sibling
division, and an exact outbox does the same (Q4 below).

So part 2 measures the outbox against the scheme it actually replaces:

- **`credit_eager`** is weight throwing where an op doesn't know its post
  count: each post takes half of what's left.
- **`credit_outbox`** is the same op shape (posts made *during* the op)
  with the outbox, and should behave like `credit`.
- **`credit`** is the same split with no buffering cost.

### What was run

| file | what |
|---|---|
| `results/fuel-outbox-20261030-000317.txt` | fuel_outbox.sh. 3 reps × {1, 4, 16} workers × {outbox, credit, eager}: relay L = 16/64/79/80/81 at F = 80; double at F = 80/1000; W4 at F = 2000/5459/5460, plus `home` at 2000; W5 at F = 80 |
| `results/measure-20261030-000711.txt` | the sweep, one pass: W1–W4 × spin 100/1000 × workers 1/2/4/8/12 × {none, credit, credit_outbox, credit_eager, home} |
| `results/measure-20261030-000754.txt` | the key cells (8 and 12 workers) rerun 4×. Pooled with the sweep, that's n = 5 per cell |
| `results/pub-outbox-20261030-000859.txt` | pub_outbox.sh: rings published per pass, per op or per post. W1 and W3, spin 100 and 1000, 8 workers, 3 reps |
| `results/outbox-analysis-{sweep,key,pub}.txt` | the output of `outbox_cells.py` |
| `results/smoke-outbox.txt` | the new schemes under `--check` and TSan, W1–W4 × {1, 3, 8} workers. All clean, with no underflow |
| `results/outbox-v1-extra-now/` | **superseded**. The first timed pass, where midpost ops took one extra `mach_absolute_time` (7 ns, measured). That made `credit_outbox` look 3–6% slower at spin 100. It was fixed before the runs above |

All 616 timing lines and 306 fuel lines say `ok=1`.

**Load.** load1 was 3–5 before the runs. The machine is shared with other
agents, and it rose to 6.3–9.2 in the sweep, 6.3–12.1 in the reruns and
about 11 in the pub runs. As in part 1, **read absolute numbers as ±40%,
trust ratios within a pass, and treat single-pass cells as anecdotes**. In
the one-pass sweep a few cells are clearly hit by load: W2 eager 0.45 at
8 workers, W3 outbox 0.40 at 8 workers, W4 credit 0.41 at 12 workers, and
home 0.37–0.49 at W1. Each is ≥ 0.85 in the reruns.

### Fuel (3 reps × 1, 4 and 16 workers: 9 runs per row)

"Same every run" means panics, panic depth (min and max) and posts per
origin were identical in all 9 runs. Every row below is.

| test | `credit_outbox` | `credit` | `credit_eager` (halving) | pooled exact (`home`) |
|---|---|---|---|---|
| relay L = 16, 64, 79, 80, F = 80 | **completes** | completes | panics at hop 6 after 6 posts | — |
| relay L = 81, F = 80 | **panics at depth 80 after exactly 80 posts**, in every origin | same | hop 6, 6 posts | — |
| double, F = 80 | panics at **depth 5 in every branch**: 32 panics and 62 posts per origin | same | panics at depths 3–6, 32 posts | would stop at post 80 |
| double, F = 1000 | depths 8–9, 978 posts | same | depths 5–9, 218 posts | would stop at 1000 |
| W4 hot tree, F = 2000 | depth 5 in every origin, **1,364 posts** | same | depths 2–5, 1,050 posts | **2,000** (exact, but timing decides which post) |
| W4, F = 5459 / 5460 | 4,488 posts and panics / **completes, 5,460 posts** | same | 1,949 / 1,950 | — |
| W5 skew, F = 80 | 20 posts, panic at depth 5 | same | 12 posts, then the **root panics** after 7 sends | never panics |

"Posts before the first panic" (in wall time) still varies between runs
for every scheme, from 20 to 1,364 on W4. It's a timing measure, not a
semantic one: which panic happens first in real time. What replays is the
set of panicking ops and the posts each origin makes.

### Throughput: ratio to `none`, 8 and 12 workers (median of 5 passes [min–max])

**Spin 100 ns**

| wl | w | none M/s | credit | credit_outbox | credit_eager | home | **outbox/credit** | eager/credit |
|---|---|---|---|---|---|---|---|---|
| W1 | 8 | 50 | 0.90 [.80–1.03] | 0.89 [.83–.92] | 0.91 | 0.91 | **1.01** [.86–1.03] | 1.00 |
| | 12 | 68 | 0.82 [.73–.86] | 0.86 [.77–.90] | 0.84 | 0.74 [.37–1.06] | **1.04** [1.02–1.13] | 1.01 |
| W2 | 8 | 56 | 0.93 [.72–.97] | 0.92 [.92–.97] | 0.90 | 0.93 | **1.00** [.99–1.30] | 0.97 |
| | 12 | 73 | 0.84 [.60–.86] | 0.80 [.26–1.08] | 0.81 | 0.84 | **1.08** [.31–1.26] | 0.98 |
| W3 | 8 | 55 | 0.99 [.87–1.00] | 1.03 [.40–1.04] | 0.88 [.79–.90] | 0.84 | **1.04** [.40–1.05] | **0.91** [.86–.91] |
| | 12 | 66 | 0.96 [.57–1.15] | 0.95 [.74–.98] | 0.80 [.69–.85] | 0.77 | **1.02** [.76–1.63] | **0.87** [.70–1.40] |
| W4 N = 4 | 8 | 52 | 0.98 [.94–1.25] | 1.00 [.81–1.23] | 0.97 | 0.92 | **1.01** [.83–1.05] | 0.98 |
| | 12 | 70 | 0.78 [.41–.90] | 0.82 [.63–.91] | 0.84 | 0.74 | **1.01** [.91–2.08] | 1.03 |

**Spin 1000 ns.** Every scheme is 0.91–1.01× `none` at 8 and 12 workers,
except eager W4 at 12 workers (0.81 [.31–.94]), which is one bad pass.
**outbox/credit is 0.97–1.08**, and eager/credit 0.93–1.02.

The sweep at 1–4 workers puts outbox/credit at 0.99–1.04 in every cell, at
both spins (`results/outbox-analysis-sweep.txt`).

### Control messages, close latency and delivery latency (medians, µs)

| cell (w = 8) | ctrl/delivery credit · outbox · eager | close p50 credit · outbox · eager | delivery p50 none · credit · outbox · eager · home |
|---|---|---|---|
| W1 spin 100 | 0.50 · 0.50 · 0.50 | 10.5 · 10.3 · 10.7 | 6.0 · 7.8 · 7.7 · 7.8 · 7.8 |
| W3 spin 100 | **0.10 · 0.10 · 0.79** | 9.7 · 9.3 · 8.7 | 11.0 · 10.3 · 9.8 · 8.5 · 14.7 |
| W4 spin 100 | 0.05 · 0.05 · 0.06 | 32.7 · 30.0 · 32.0 | 363 · 24.0 · 22.7 · 24.0 · 39.3 |
| W1 spin 1000 | 0.50 · 0.50 · 0.50 | 64 · 65 · 64 | 45 · 48 · 48 · 48 · 48 |
| W3 spin 1000 | 0.10 · 0.10 · 0.79 | 71 · 71 · 57 | 80 · 75 · 75 · 56 · 93 |
| W4 spin 1000 | 0.06 · 0.06 · 0.06 | 171 · 165 · 176 | 3072 · 163 · 163 · 160 · 299 |

Delivery latency is measured from the parent op's start to the child op's
start. It is almost all queueing: 7–75 µs, against an op of 0.1–1 µs.
`none`'s large W4 numbers come from having no admission. It runs every
origin at once, so its queues are deep.

**Does the outbox's hold matter?** The pub runs publish each ring
immediately after the op (outbox) or after each send (eager), instead of
at the pass end. Medians of 3 runs, 8 workers:

| | W1 spin 1000: thr / delivery p50 | W3 spin 1000 | W3 spin 100 |
|---|---|---|---|
| credit_outbox, publish per pass | 0.99 / 48 µs | 0.99 / 73 µs | 1.03 / 10.0 µs |
| credit_outbox, publish per op | 0.97 / 44 | 0.98 / 52 | 0.90 / 7.7 |
| credit_eager, publish per pass | 0.98 / 48 | 0.99 / 56 | 0.91 / 8.5 |
| credit_eager, publish per post | 0.98 / 44 | 0.95 / 39 | **0.75** / 6.2 |

### Predictions

| | prediction | result | held? |
|---|---|---|---|
| Q1 | relay: outbox passes L ≤ 80 and panics at depth 80 after 80 posts when L = 81, in every run at 1/4/16 workers. `credit` the same. Eager panics at hop 6 | exactly that, in 9 of 9 runs per L | **yes** |
| Q2 | double, F = 80: outbox depth 5, 32 panics, 62 posts, every run. F = 1000: depth 7–8. Eager deterministic, depths 2–5, 30–45 posts | F = 80 exact. F = 1000: depths **8–9**, 978 posts. Eager: depths 3–6, 32 posts, deterministic | **mostly**: the F = 1000 depth was one level off |
| Q3 | W4, F = 2000: outbox = credit = 1,364 posts at depth 5; `home` 2,000; F = 5460 completes and 5459 panics; eager under 300 posts | all of it, except eager: **1,050** posts. Halving starves the 2nd–4th children, but the first child's path still gets half at every level | **mostly**: eager was far better on a balanced tree than predicted |
| Q4 | W5: the outbox doesn't fix it; 20 posts, like credit | 20 posts, depth 5, every run | **yes** |
| Q5 | outbox within 5% of credit everywhere. Eager ctrl W3 ≈ 0.9 and W4 0.2–0.3; eager 0–10% below credit at spin 100 | outbox/credit medians 0.97–1.08, inside noise (the per-cell ranges are wider than the gap). Eager ctrl W3 0.79–0.82 (yes); W4 **0.06–0.09** (no: per-pass batching folds the extra returns). Eager/credit 0.87–0.91 on W3 and about 1.0 elsewhere | **mostly** |
| Q6 | outbox close p50 within 15% of credit | within 10% in every key cell except W2 spin 1000 w = 8 (147 vs 117 µs, where credit's own p99 outlier pass skews it) | **yes** |
| Q7 | with per-pass publishing, outbox, credit and eager delivery latency within 15%. With publish per op/post, eager lower by about half an op; publishing costs 0–15% at spin 1000 | outbox = credit within 5% everywhere. **Eager is 18–25% lower on W3**, with less throughput. Per-post vs per-op: W1 identical (the 0.5 µs is below the noise); W3 13 µs lower, which is 25× the hold. Publish cost 0–5% at spin 1000, but **10–25% at spin 100** | **partly**: see below |

**Why eager's delivery latency is lower on W3, and why that isn't the
outbox's hold.** Eager returns weight from every op, so W3 carries
0.8 control messages per delivery instead of 0.1. Control messages sit in
the same rings, and the edge counts unread ring entries as backlog ("work
before intake"). So eager opens fewer origins, its queues are shorter, and
both latency and throughput drop: 0.87–0.91× credit at spin 100. That's
part 1's surprise 2 again: at this scale, latency differences are
queue-depth differences. The outbox's own hold is at most one op, 0.1–1
µs. It never shows against 7–75 µs of queueing, and under per-pass
publishing it is exactly zero, because nothing leaves a core before the
pass ends anyway.

### What this implies

1. **The outbox does remove halving, and costs nothing measurable.**
   - Against eager weight throwing it turns a 6-hop limit into an 80-hop
     limit at F = 80, with a relay paying exactly 1 per hop.
   - A doubling cascade dies at depth ⌊log2((F+2)/4)⌋ + 1 (5 at F = 80, 8–9
     at F = 1000), using 78–98% of F.
   - A balanced tree uses all of F: W4 completes at F = 5460, its exact
     post count, and panics at 5459.
   - All of it replays identically at 1, 4 and 16 workers. Throughput,
     close latency and control messages are those of `credit` within
     noise. The buffering is one 64-byte copy per post.
   - Under Seastar-style per-pass publishing the hold costs no latency at
     all, and with immediate publishing it is at most one op.
2. **It also gives panics a clean edge.** A panicking op's outbox is
   dropped, so a panic sends nothing. Eager has already sent its earlier
   posts: on W5 the eager root panics after 7 of its 16 posts are out.
   Part of a fan-out escaping is a semantic wart that the outbox removes.
3. **It does not remove the problem part 1 actually hit.**
   - W5 still panics at hop 4 after 20 posts. Split fuel's real limit is
     **sibling division on unbalanced trees**: a wide parent hands each
     child an equal share, so one deep child starves while 15 shallow ones
     waste theirs.
   - The outbox can't fix that, because the parent doesn't know which
     child will go deep.
   - The fixes are semantic: an explicit share at the post site, unused
     fuel returning to the parent, or pooled fuel with its cost (part 1).
     None is measured here.
4. **What gets worse.**
   - An op's posts can't leave before it ends. That's free for short ops
     under per-pass publishing. For a long op that posts as it goes (a
     streaming reply, a 10 ms scan feeding a pipeline) the first post
     waits for the whole op. Not modelled here.
   - The outbox's memory is bounded by the op's own fuel (k ≤ f), so it
     isn't unbounded.
   - Publishing per post to get latency back costs 10–25% throughput at
     spin 100. That's a transport choice, not an outbox one.

**Caveats.** All of part 1's caveats apply: one machine under shared load
(load1 6–12 in these runs), one transport, spinning cores, no
`work_stealing` and no parking. The fuel and smoke runs used the build
before the 7 ns timestamp fix. That fix changes no accounting.

# origin-counters: what a per-origin refcount and fuel cost under per_core

Informs research/actor-origins/LANDSCAPE.md §9, open question 8: "What does
the refcount cost on `work_stealing` and `per_core`? A shared atomic per
origin, per-core deltas merged at closing (X10's vectors), or credit
splitting? Which keeps `sim` replay exact?" Only `per_core` is modelled here.

The predictions below were written before the timing runs. Two kinds of run
came first, and are disclosed here: the `--check`/TSan smoke runs, and a
debugging run of W4 at 8 workers and spin 100. That run showed `atomic` at
about 0.45× `credit`, and it's why P4's atomic number is as sharp as it is.

## The design under test

- **Origins.** An outside call into a family (one post, or one operation
  through `at`) opens an origin. A family allows at most `inflight: N` open
  origins, and only the edge waits for a slot.
- **Mail inside the family.** A sibling post carries its sender's origin
  and never waits.
- **Closing.** An origin closes when all its descendant mail is delivered.
  That is termination detection.
- **Fuel.** Each origin has fuel F, the total number of descendant posts it
  may make. Exceeding F panics.
- **`settled()`.** A test-only call that waits for the caller's origins to
  close.

The runtime is `per_core`: one scheduler per core, keys have home cores, and
a post is a `D.Call` shipped to the key's core.

## The harness (c/origins.c)

- **Cores.** There are W threads at `QOS_CLASS_USER_INTERACTIVE`, unpinned,
  as in experiments/many-cores and runtime-p2/percore. Each is a spinning
  scheduler with no parking, and every scheme pays the same idle polling.
- **Transport.** It is Seastar-style: a 1024-slot SPSC ring per ordered pair
  of cores, with 64-byte messages. A pass publishes its tail and head stores
  once, at its end, as Seastar's smp queues batch. A post to a key on the
  same core goes on the local run queue. A full ring spills into a
  per-destination FIFO, so a post never waits.
- **A pass.** It runs at most 32 ops from the rings and 32 from the run
  queue. Then the edge opens origins: at most 16, only while the run queue
  holds fewer than 64, and only with a free slot. Then the pass flushes
  batched accounting and publishes its rings.
- **Admission.** The N slots are split over the cores, N/W each. Under
  per_core an origin's home is the core that opened it, and its slot is
  freed when the home learns the origin closed. A global admission
  semaphore would be a second shared counter. It's left out so that each
  scheme's cost is measured on its own.
- **An op.** It spins `--spin` ns of `isb` (about 9 ns each, calibrated).
  `isb` serializes, so the work can't hide in the out-of-order window. The
  first version used a multiply chain, and 100 ns of it cost about 60 ns.
  The op then makes its posts. Posts are buffered to the op's end, as a
  runtime ships an op's outbox, so an op knows its post count n when it
  accounts. Every scheme gets this.
- **Deliveries/s.** It counts every op, root ops included. Wall time runs
  from the start barrier to the last close (the last delivery for `none`).
- **Close latency** runs from the last descendant's completion to the home
  core knowing the origin closed, which frees the slot and returns
  `settled()`. Messages carry the completion timestamp. `mach_absolute_time`
  is global on Apple silicon.
- **Checks.** `--check` and smoke.sh flag three things: a delivery after
  its origin's close, a close with the wrong number of deliveries, and a
  control message for an origin that has closed. They also run under TSan.

### Schemes

| # | `--scheme` | refcount | fuel | per post | per delivery off the home |
|---|---|---|---|---|---|
| 0 | `none` | none, and no admission | none | nothing | nothing |
| 1 | `atomic` | one padded 128 B line per origin. Low 32 bits are the live count, high 32 bits the posts. | pooled, exact | an op does ONE `fetch_add((n<<32)+n-1)` | the RMW on a line that last lived on another core. The core that reaches zero sends CLOSE to the home |
| 2 | `vector` | X10-style. Each core keeps `sent[dest]` and `done` per origin and flushes them to the home at the end of the pass. The home keeps `M[p]` = spawns to p − completions at p, and the origin closes when every entry is 0 | pooled, soft: posts are reported with the flush | a local increment | one FLUSH message per dirty origin per pass |
| 3 | `credit` | Mattern/Huang weight throwing. The root has 2^63. An op splits its weight exactly over its n posts at the op's end, and a leaf returns its weight. Returns are batched per pass | **split down the tree**: an op with fuel f and n posts needs n ≤ f, and its children share f−n | carries 8 bytes of weight | one RET per dirty origin per pass, from leaves only |
| 3s | `credit_soft` | as `credit` | pooled, soft. A message carries the posts made on its path that haven't been reported ("debt"). A leaf reports its debt with its weight, and debt ≥ 64 is reported early | as credit | as credit |
| 4 | `home` | the counter lives on the home core, non-atomic. A post made off the home is **routed through the home**, which counts it, checks fuel and forwards it. A completion off the home is a DEC batched per pass | pooled, exact, at the home | a hop to the home and a hop on, unless the poster is the home | one DEC per dirty origin per pass |
| — | `naive` | home counter, with each core sending its net delta (posts − done) per pass and posts going direct | — | — | **unsound**, see below |

Why `home` routes posts. The obvious version of scheme 4 is "remote cores
batch decrements and increments to the home". It's `naive`, and it's
unsound. Say core q runs an op that posts t1 and t2 to core p, and q's
delta of +1 is still in the q→home ring. p runs t1 and its −1 reaches the
home first, so the home sees 0 and closes. That is a false close, with t2
still queued. The smoke run shows it: on W4, `naive` closes origins while
their mail is still being delivered (`premature`, `badcount` > 0). Batched
decrements are safe only when the home learns every increment before the
child it counts exists. That leaves three options:

1. Route the post through the home (`home`).
2. Make each report carry who it spawned to (`vector`).
3. Conserve a quantity (`credit`).

Dijkstra–Scholten with acks per core pair is a fourth, with the same
message cost as 2 and 3. It isn't built.

Why `vector` is sound with per-pass reports. A report from core q carries
the spawns *and* the completion of each op in that pass, together, and the
done count is in the last message of a multi-part report. So a task's
spawn is reported if and only if its parent's completion is. A false zero
needs an unreported task matched, at its own core, by a reported task
whose parent is unreported. Following those matches gives a cycle in time
order (a child runs after its parent, and reports from one core arrive in
FIFO order), which is impossible. X10's non-resilient finish is the same
protocol, flushed at quiescence instead of per pass.

### Workloads

| wl | shape | ops per origin |
|---|---|---|
| W1 doc→index | the root posts once to a random other core | 2 |
| W2 fan-out | the root posts to 16 keys on cores home+1 … home+16 (mod W) | 17 |
| W3 chain | 8 hops, each to a random core other than the current one | 9 |
| W4 hot origin | fan-out 4 to depth 6, each child on a random core, at **N = 4** (a few huge origins), and N = 16 | 5461 |
| W5 skew (fuel only) | the root posts 16, and child 0 relays a chain of 64 | 81 |

The grid is W1–W3 at N = 4096 and W4 at N = 4, each over spin 0, 100 and
1000 ns and workers 1, 2, 4, 8, 12 and 16. There are also three side runs:

- Admission: W1 and W2 at N = 64, spin 100.
- W4 at N = 16, spin 100.
- Fuel: W4 with F = 2000 against 5460 posts per origin, and W5 with F = 80.

The baseline `none` has no admission at all, because nothing tells it when
an origin closes. On W1–W3 at N = 4096 admission doesn't bind, so the
comparison is fair. On W4 at N = 4 it isn't: `none` runs every origin at
once. Read W4 against the best scheme as well as against `none`.

Noise: the machine is shared. As in many-cores/SYNTHESIS.md, **read absolute
numbers as ±40% and compare ratios within a pass**.

## Predictions

- **P1. W1, the common case.** The message schemes (`vector`, `credit`,
  `home`) add one control message per origin, 0.5 per delivery. `atomic`
  adds two cache-line transfers per origin, home→remote→home, plus a CLOSE
  message.
  - At spin 0, 8–16 workers: the message schemes reach 0.5–0.75× `none`.
    `atomic` is no better than the message schemes, and is 0.4–0.65×.
  - At spin 1000: every scheme is within 10% of `none`.
- **P2. W2, fan-out 16.** Up to 16 cores RMW one line within a few
  microseconds. At ≥ 8 workers and spin 0, `atomic` is ≤ 0.75× `credit`.
  `vector`, `credit` and `home` land within 15% of each other, since all
  send about one control message per remote core per origin.
- **P3. W3, chain.** `home` pays an extra hop for 7 of the 8 posts and is
  the slowest at spin 0, at ≤ 0.8× `credit`. `credit` is the cheapest
  scheme. It sends one RET per origin, from the leaf, and carries the weight
  intact through the chain. `atomic` moves the line on every hop and lands
  between them.
- **P4. W4, hot origin, N = 4.** 16 cores hammer 4 lines.
  - `atomic` collapses to ≤ 0.5× `credit` at 8–16 workers, spin 0 and
    100, and the gap narrows at spin 1000.
  - `home` puts about 5460 routed posts per origin through 4 home cores.
    It is ≤ 0.6× `credit` at 16 workers and spin 0.
  - `credit` is within 15% of `none`. Per-pass batching folds up to 32
    returns into one message.
- **P5. Close latency.**
  - `atomic` has the lowest p50 on W1: the closer sends CLOSE at once.
  - The message schemes' p50 is within 2× of `atomic`'s: one pass plus one
    hop, a few µs at spin 0.
  - Everyone's p99 is set by pass length, up to 32 ops × spin, so it is
    tens of µs at spin 1000.
  - On W4, `atomic`'s close latency is lower than `credit`'s, but its
    lifetime is longer.
- **P6. Admission, N = 64.** Throughput ≈ N × ops per origin ÷ lifetime
  (Little's law), and lifetime includes the close latency. The scheme
  ranking matches P1/P2. Differences in close latency show up as at most
  20% in throughput, because the hop to the leaf dominates the lifetime.
- **P7. Fuel accuracy.**
  - `atomic` and `home` notice the (F+1)th post before it is delivered:
    overshoot 0, by construction.
  - `vector`, flushed per pass, overshoots by up to W × (posts in one pass)
    plus flushes in flight. That is hundreds to about 2000 posts at 16
    workers, and it varies from run to run.
  - `credit_soft` overshoots more, up to a few thousand, because debt below
    64 rides in flight unreported.
  - `credit` (split) never exceeds F. On W4 it panics before F's worth of
    posts. On W5, F = 80 (exactly enough pooled) panics at child 0's chain
    in every run, at every thread count.
- **P8. Determinism.** This one is reasoned, not measured. The verdict and
  argument go in RESULTS.md.
  - Split fuel (`credit`) is a function of each message's causal path only,
    so it replays exactly at any thread count.
  - Pooled exact fuel (`atomic`, `home`) panics at the post that is
    (F+1)th in a global order of that origin's posts. That order is the
    atomic's or the home's arrival order, which depends on timing. It is
    deterministic under `sim` only if `sim` schedules it, and in a journal
    only if the journal records it.
  - Pooled soft fuel is additionally late by a timing-dependent amount.
  - Close is logically "the last delivery" in every sound scheme. Only
    *when* the home learns it is timing-dependent, and that moves
    admission.

## Part 2: the outbox (written before the timed runs)

**The proposal.** An op's posts are buffered and released together when it
ends. Only then is k (the post count) known, so the op's remaining fuel r
splits exactly: charge 1 per post, and divide r − k evenly over the k posts,
remainder to the earliest. Credit for close detection splits the same way.

**A correction to the premise, found while reading the code.** The existing
`credit` already does this. `children()` hands an op all its posts at once
after its spin, which is an outbox that costs nothing, and `credit` splits
weight and fuel exactly over n (`fq = (f − n)/n`, remainder to child 0). W5's
hop-4 panic is not halving. W5's root posts 16 and divides its remaining 64
fuel among 16 siblings, so child 0 gets 4 for a 64-hop chain. That is
sibling splitting, and an exact outbox does the same. A smoke run before
these predictions confirmed it: `credit` passes a relay of L = 80 at F = 80
and panics at L = 81.

So part 2 adds two schemes. Each makes an op's posts **during** the op, so
the op doesn't know k until it ends, as a real op doesn't:

| `--scheme` | posts | weight | fuel |
|---|---|---|---|
| `credit_outbox` | post i is made after (i+1)/(n+1) of the spin, copied into a per-core outbox, and released at the op's end | exact split over k at release | charge 1 per post. The (f+1)th post panics the op, and its outbox is dropped unsent. The children share f − k exactly |
| `credit_eager` | made at the same points, sent at once (no outbox) | each post takes half the remaining weight. The rest returns at the op's end | each post costs 1 and takes half the remainder. Leftover fuel is lost. This is the halving baseline the brief describes |

`credit` stays as it was. It's the outbox's lower bound: the same split
with no buffering and no mid-op posts.

New harness pieces:

- **Workloads.** `--wl 6` is a relay of `--L` hops, each to the next core.
  `--wl 7` is double: every op posts 2 to random cores, capped at depth 60.
- **`dlat`.** A histogram of the parent op's start to the child's delivery,
  for every scheme.
- **`--pub pass|op|post`.** This sets when ring tails are published. The
  default, `pass`, matches every earlier run.

### Predictions

- **Q1. Relay, F = 80.**
  - `credit_outbox` passes L = 16, 64, 79 and 80. At L = 81 every origin
    panics at the op at depth 80, after exactly 80 posts. That holds in
    every run, at 1, 4 and 16 workers. `credit` matches it exactly.
  - `credit_eager` panics at depth 6 after 6 posts, for every L ≥ 7: the
    fuel goes 80 → 39 → 19 → 9 → 4 → 1 → 0. That is deterministic too,
    since halving also depends only on the causal path.
- **Q2. Double.** `credit_outbox` at F = 80 panics at depth 5 in every
  branch. Every depth-5 op panics, which is 32 panics and 62 posts per
  origin, the same in every run. Generally, the panic depth is about
  ⌈log2((F+2)/4)⌉. At F = 1000 it's depth 8, possibly 7–8 in a few
  branches because of remainders. Pooled F = 80 would allow 80 posts.
  `credit_eager` also panics deterministically, at mixed depths (2–5),
  with fewer posts than the outbox (about 30–45 at F = 80).
- **Q3. W4 hot tree, F = 2000.**
  - `credit_outbox` matches `credit`: 1,364 posts and panics at depth 5 in
    every origin. Pooled exact fuel (`home`) stops at exactly 2,000.
  - Because the 4-ary tree is balanced, split fuel loses only rounding.
    F = 5460, the tree's own post count, completes, and F = 5459 panics.
  - `credit_eager` gets far fewer posts, under 300: a fan-out of 4 gives
    the children 1/2, 1/4, 1/8 and 1/16 of the budget.
- **Q4. W5 skew.** The outbox does **not** fix it. `credit_outbox` panics
  after 20 posts, like `credit`.
- **Q5. Throughput** at spin 100 and 1000, against `credit`.
  - `credit_outbox` costs one extra 64 B copy per post plus the split spin
    loop, about 1–3 ns per post. It lands within 5% of `credit` in every
    cell, which can't be told apart from noise.
  - `credit_eager` returns weight from every op, not only leaves, so its
    control messages per delivery rise. On W3 it goes from 0.10 to about
    0.9, and on W4 from 0.13 to about 0.2–0.3. At spin 100 it is 0–10%
    below `credit`, and within noise at spin 1000.
- **Q6. Close latency.** `credit_outbox` matches `credit`, with p50 within
  15%: the same one pass plus one hop.
- **Q7. Delivery latency, `--pub pass`.** `credit`, `credit_outbox` and
  `credit_eager` are within 15% of each other. A post isn't visible to
  another core until the pass ends anyway, so holding it to the op's end
  costs nothing extra. The outbox's hold only shows when rings are
  published sooner.
  - With `--pub post` for eager, against `--pub op` for the outbox, at
    spin 1000, eager's delivery p50 is lower by about half an op
    (~500 ns) on W1 and W3.
  - Throughput falls under per-post publishing, by 0–15% at spin 1000.

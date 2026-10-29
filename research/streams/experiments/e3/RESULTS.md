# E3: push against pull, measured natively

**The question.** The amended streams design pushes a chain whose head
is a `gen fn` call and whose consumer is a `for` or a built-in sink. The
generator's body runs with the one-input stages and the loop body folded
in. Two-input stages (`zip`) and a pipeline passed to a user function
pull instead, through a frame and a `next`. Does "the obvious code is the
fast code" hold for streams? What does pulling cost compared with
pushing, with a hand-written loop, and with Rust and Go?

**The answer.** Mostly yes. Recursion is the exception, and it decides
how decision 10 should go.

1. **Pushed chains cost the same as a hand loop** in every workload:
   1.00× (W1), 0.98× (W2), 0.99× (W3), 1.05× (W4, one side pushed).
2. **Pulling a flat generator is also nearly free**, as long as the
   chain is composed at the call site, as "a pipeline is a block" (B)
   composes it. The frame is a local, `next` is a static specialized
   function, and clang inlines the switch away: 1.00× (W1), 1.04× (W3),
   1.14× (W4, `zip`). Passing the pipeline to a user function costs
   1.02× (W5), because decision 1 specializes that function per block.
3. **Pulling only costs when the `next` isn't inlined.** That's about
   1 ns per call left in place, which is 1.80× on W4's 1.5 ns items and
   1.24× on W1's 22 ns lines with two calls per item.
4. **Recursion is the one large gap.** A tree walk pulled through boxed
   `yield from` child frames, as the draft lowers it, takes **13.5×** a
   hand loop (8.4× if a dropped box is reused). That's O(depth) per item
   plus a malloc per node, and Rust's boxed `dyn` chain pays the same
   (15.9×). Pushed, the walk costs **0.98×**. Pulled with the frames on
   one stack that the consumer owns, it costs **1.46×**.
5. **Fusion through a `gen fn` bought nothing here.** In W3, the user
   stage `dedup_by` is pushed and its mapped source is pulled, which is
   what the design gives, and that already costs 0.99×. Fully fused, it
   costs 1.18×, and the extra comes from loop shape, not the mechanism.
6. **Against the twins:** Ren's model is level with Rust on W2–W4
   (Rust's ratios are 0.87–0.96× on W2, 0.93× on W3 and 0.90× on W4) and
   faster on W1 and W5. Go's `range`-over-func is close to C, except
   on recursion (1.63×). Go's `iter.Pull`, a coroutine switch, costs
   3.9× (W2), 10× (W3), and 25× and 51× on `zip` (W4). Ren's `zip` is
   a state machine that costs 1.14×.

## What this means for the open decisions

- **Decision 10 (where a pushed recursive generator recurses).** The
  amendment's recommendation was "push only non-recursive producers at
  first; a self-recursive `yield from` pulls". Recursion is the case
  where push pays the most. If a recursive generator pulls through boxed
  frames, `for e in walk_dir(root).select(big).take(10)` gets 13× slower
  just by being a generator. That breaks property 8 on the program
  streams.md itself uses as an example. Two changes follow from the
  numbers:
  - **Push recursive producers natively now.** The only observable
    difference is stack depth, and a recursive `fn` that walks the same
    tree already has it (REN_STACK_CHECK). So a pushed `gen fn` behaves
    like the recursive function it reads as, and that difference adds
    no new rule.
  - **When a recursive generator must pull** (zipped, or passed to a
    user function), **lower `yield from` to a frame stack**: one
    growable array of frames, a hidden local of the pipeline, where
    `next` resumes the top frame. That costs 1.46×, O(1) per item, with
    one allocation that grows. Never box child frames: boxing is
    Python's and Rust's O(depth) trap.
- **Decision 8 (push now).** Base push matters, for recursion and for
  robustness (see the caveats on complex generators). The extra 200–400
  lines of "fusion through a `gen fn`" made no measurable difference
  when the inner source is flat, because a composed, inlined pull
  already reduces to the hand loop. That part could stay Later without
  breaking property 8. Ranking by measured value: recursion pushed or
  frame-stacked, then base push, then fusion through a `gen fn`.
- **Elegance check.** With B, the design has one lowering, a chain
  composed where it's written with `next` as a static function, plus one
  optimization, push. The numbers say push is only *needed* where
  recursion would otherwise go through boxes. A lean version of the
  rule: "a chain is a block composed at the call site; a recursive
  `yield from` uses a frame stack when pulled; a `for` over a generator
  is pushed." No case measured here pays a cost the programmer has to
  think about, except a `next` that clang doesn't inline (about 1 ns per
  item).
- **`zip` pulls (two-input stages).** That costs 1.14×, against Go's
  25×. Pushing one side and pulling the other inside the body (push1)
  costs 1.05×, if anyone wants the last 9%.

## Setup

- **Machine:** Apple M4 Max, 16 cores, macOS (Darwin 24.1).
- **Compilers:** Apple clang 16.0.0 at `-O2 -std=gnu11`, as `ren build
  --release` runs it; rustc 1.99.1 at opt-level 3 with one codegen unit
  (std only, no unsafe); go 1.27.3.
- **Runs:** 11 rounds, interleaved, each command once per round in a
  rotated order, under `/usr/bin/time -l`. Each program times only its
  kernel, not data generation.
- **Load (uptime):** `11:53 load averages: 2.79 2.49 2.36` at the start
  and `11:58 load averages: 2.24 2.59 2.46` at the end. Each row has 1–2
  outlier rounds up to about 1.6× its median, the same rounds for
  every command, so they came from the machine. Medians matched the
  smoke runs made before the measurement.
- **Checks:** every variant in a workload, C, Rust and Go alike, prints
  the same `check=`, and measure.py fails on any mismatch. There were
  none. The data are byte-identical across languages: one LCG, and the
  same generators in each language.

### How the C models Ren

Read from `ren build --release --emit-c` on a small program with a block
parameter:

- **A block** is a `static` function specialized per call site. Its
  captures are passed as `restrict` pointers to the caller's locals,
  with an evidence pointer `ev`.
- **Int arithmetic that can overflow** goes through `ren_add`, which
  traps.
- **A recursive function** starts with `REN_STACK_CHECK()`.
- **A Str** is strings.md's 16-byte layout: a root, a 32-bit offset and
  a 32-bit length.
- **Push:** the twin `G_push(args, ev, captures…)` turns each `yield e`
  into a call of the specialized body. The body returns `REN_CONT` or
  `REN_BREAK`, the control-value protocol. `take`'s counter is a hidden
  local of the caller.
- **Pull:** the generator's frame is a struct, a hidden local of the
  caller (B+R). `next` switches on the resume point and returns an
  `Option` by value. The pipeline is a block, `fn() -> Option<T>`,
  composed where the chain is written, with the frames and stage state
  as hidden locals.
- **`-ni` variants** mark one or two of those functions `noinline`, to
  show what a call costs when clang won't inline it.
- **`indirect` (W5)** is Ren's `ren_block {code, env}` called through a
  pointer, as a debug build passes blocks, or a release build past the
  specialization budget. The asm confirms the `blr` stays in place.

## Results

ns/item divides by:

| Workload | Items per program run |
|---|---|
| W1 | 822,724 lines read before `take` stops × 5 reps |
| W2 | 9,092,787 nodes visited before `take` stops × 3 |
| W3 | 16 Mi deltas × 8 |
| W4 | 14,680,064 pairs × 8 |
| W5 | 987,455 lines × 5 |

Minstr is the whole process, including data generation.

### W1: lines of a 100 MB log → map(parse) → select(level == Error) → take(40,000) → count and sum of ids

| Variant | ms | Range | × hand | ns/line |
|---|---|---|---|---|
| C hand | 90.2 | 85.8–147.4 | 1.00 | 21.9 |
| **C push** | 90.6 | 86.6–150.2 | **1.00** | 22.0 |
| C push, body not inlined | 106.0 | 101.4–173.4 | 1.18 | 25.8 |
| **C pull** | 90.5 | 86.0–147.6 | **1.00** | 22.0 |
| C pull, pipeline block not inlined | 91.1 | 87.6–150.9 | 1.01 | 22.2 |
| C pull, block and `lines.next` not inlined | 112.3 | 107.0–180.9 | 1.24 | 27.3 |
| Rust iterator chain | 125.6 | 121.9–209.9 | 1.39 | 30.5 |
| Rust `for` over the chain | 123.6 | 118.9–204.1 | 1.37 | 30.0 |
| Go range, stages in the body | 97.6 | 92.0–159.8 | 1.08 | 23.7 |
| Go range over Map/Filter/Take | 99.8 | 94.1–160.9 | 1.11 | 24.3 |
| Go `iter.Pull` | 118.1 | 110.3–188.7 | 1.31 | 28.7 |

Parsing dominates: memchr plus a byte loop at about 22 ns per line. Push
and pull can't be told apart. Rust loses on `split_terminator('\n')`,
not on the iterator machinery.

### W2: recursive tree walk, 10.2M nodes over 21 levels → select(v % 7 == 0) → take(1.3M) → sum

| Variant | ms | Range | × hand | ns/node |
|---|---|---|---|---|
| C hand, recursive function | 86.9 | 81.3–148.7 | 1.00 | 3.19 |
| C hand, explicit stack | 103.3 | 96.6–162.1 | 1.19 | 3.79 |
| **C push** (recursion on the native stack) | 85.6 | 80.5–146.3 | **0.98** | 3.14 |
| C pull, boxed `yield from` (the draft) | 1174.8 | 1114.5–1910.3 | **13.52** | 43.1 |
| C pull, boxed, dropped box reused | 725.4 | 707.3–1153.5 | 8.35 | 26.6 |
| **C pull, frame stack owned by the consumer** | 127.2 | 119.6–206.2 | **1.46** | 4.66 |
| Rust push (`FnMut -> ControlFlow`) | 75.8 | 72.2–119.2 | 0.87 | 2.78 |
| Rust explicit-stack iterator | 83.8 | 79.2–130.0 | 0.96 | 3.07 |
| Rust boxed `dyn` chain (`once.chain(flat_map(walk))`) | 1380.2 | 1339.0–2173.9 | 15.88 | 50.6 |
| Go range over a recursive `iter.Seq` | 141.3 | 138.3–221.9 | 1.63 | 5.18 |
| Go `iter.Pull` of it | 339.3 | 328.1–540.5 | 3.90 | 12.4 |

The boxed pull passes each item up through every level's `next`, about
20 calls per item, and mallocs and frees a frame per node. Reusing the
box removes the mallocs but not the O(depth) cost. The frame stack
removes both. Rust's tree stores `Vec<Tree>` inline where C and Go use
pointers, which helps its locality a little.

### W3: user stage dedup_by over ticks(ds).map(x / 2) → sum

| Variant | ms | Range | × hand | ns/item |
|---|---|---|---|---|
| C hand | 71.2 | 67.2–118.1 | 1.00 | 0.53 |
| **C design** (`dedup_by` pushed, its source a pulled pipeline) | 70.6 | 67.8–117.5 | **0.99** | 0.53 |
| C full push (fusion through a `gen fn`) | 84.2 | 80.3–138.4 | 1.18 | 0.63 |
| C all pulled (`dedup_by`'s frame over the source's) | 74.3 | 68.7–123.9 | 1.04 | 0.55 |
| C all pulled, `dedup_by.next` not inlined | 82.8 | 79.2–134.1 | 1.16 | 0.62 |
| Rust: `scan` + `map` + a user `DedupBy` struct | 66.0 | 62.1–108.5 | 0.93 | 0.49 |
| Go range over Map + DedupBy | 72.2 | 67.7–117.7 | 1.02 | 0.54 |
| Go `iter.Pull` | 725.9 | 708.8–1123.8 | 10.20 | 5.41 |

The full push's 18% is loop shape: asm/w3.s shows clang didn't peel
`last`'s "have" flag out of the loop, while the hand version did. It
isn't a cost of pushing. A user stage written as a `gen fn` over a block
costs nothing.

### W4: zip(thirds(N), nonneg(bs)).map(a ^ b) → sum

| Variant | ms | Range | × hand | ns/pair |
|---|---|---|---|---|
| C hand, two indices | 175.0 | 163.2–272.4 | 1.00 | 1.49 |
| C push one side, pull the other in the body | 184.5 | 166.0–315.7 | 1.05 | 1.57 |
| **C pull both** (what the design gives) | 199.7 | 190.2–349.4 | **1.14** | 1.70 |
| C pull both, zip block not inlined | 315.2 | 304.5–512.4 | 1.80 | 2.68 |
| Rust `filter.zip(filter).map.sum` | 158.1 | 150.3–254.9 | 0.90 | 1.35 |
| Go range one, `iter.Pull` the other | 4431.6 | 4152.1–6931.1 | 25.3 | 37.7 |
| Go `iter.Pull` both | 8976.9 | 8547.3–14713.9 | 51.3 | 76.4 |

### W5: a pipeline passed to a user function, against the same chain inlined

`total(lines(log).map(parse).select(level == Error))` against `for e in
lines(log).map(parse).select(..)`.

| Variant | ms | Range | × inline | ns/line |
|---|---|---|---|---|
| C inlined `for` (pushed) | 107.1 | 103.5–177.8 | 1.00 | 21.7 |
| **C passed; `total` specialized for the block** (pulled) | 109.6 | 104.2–179.0 | **1.02** | 22.2 |
| C passed, `total` not inlined | 109.2 | 104.7–178.4 | 1.02 | 22.1 |
| C passed as code and frame (debug, over budget) | 109.0 | 103.3–178.5 | 1.02 | 22.1 |
| Rust inline | 148.2 | 141.4–243.2 | 1.38 | 30.0 |
| Rust `total(impl Iterator)` | 147.4 | 141.1–244.2 | 1.38 | 29.9 |
| Rust `total(&mut dyn Iterator)` | 160.4 | 154.0–264.5 | 1.50 | 32.5 |
| Go inline | 114.6 | 112.3–187.0 | 1.07 | 23.2 |
| Go `total(iter.Seq)` | 114.6 | 110.3–182.2 | 1.07 | 23.2 |

At 22 ns per item, even an indirect call per item doesn't show. W4's
`-ni` row is the bound for cheap items: about 1 ns per call that stays
in place.

## Caveats

- **These are C models, not Ren's output.** They're written by hand in
  the shape Ren's backend emits today. Neither push nor pull exists in
  the compiler yet.
- **Reference counting is left out.** No variant touches a Str root's
  count or a Tree's count, on the assumption that borrow inference sees
  the source outlive the loop. Where counting does happen, pull pays
  more: a frame that holds a `Tree` increments it per frame (W2), while
  push borrows. That would widen W2's pull rows, not narrow them.
- **The generators are small.** Each has one or two resume points, no
  `finally`, and few live locals. A big generator, with several
  `yield`s, a `try`/`finally` and a `with`, makes a bigger switch and
  frame that clang may not inline or scalarize. Then pull moves toward
  the `-ni` rows, about 1 ns per call per item, with the frame in
  memory. Push is just code, so it doesn't depend on clang's inliner.
  That's push's real value for flat generators: a guarantee rather
  than a speedup.
- **The overflow checks differ.** C checks every sum (`ren_add`);
  Rust's release build and Go wrap. That matters at most a few percent
  on W3 and W4.
- **Rust and Go fold the reps into one call unless prevented.** A first
  Rust run showed W3 and W4 about 8× faster than C because LLVM
  common-subexpression-eliminated the 8 repeated pure calls into one.
  Rust's inputs now go through `std::hint::black_box`, and C's rep loop
  has a memory barrier. The table numbers are after that fix.
- **Small differences are loop-shape noise.** Differences of ±15–20%
  at under 1 ns/item come from how clang shapes the loop (W3's full
  push, W2's hand-stack), not from push or pull.
- **One machine, under load.** It was a loaded workstation (load ~2.5
  on 16 cores). The medians are stable, and the ranges show the
  disturbed rounds.
- **Go is newer than the brief asked for.** The installed Go is 1.27.3,
  newer than the 1.23 the task names. Its `iter.Pull` is still a
  coroutine switch, and its `range`-over-func rewrite is the 1.23 one.
- **Go has no standard adapters.** Go's Map, Filter, Take and DedupBy
  are hand-written, since the standard library has none for `iter.Seq`.

## Files

| Path (under this folder) | What it is |
|---|---|
| `c/common.h` | the runtime pieces: `ren_add`, the stack check, Str, the LCG, the log generator, `parse` |
| `c/w1.c` | W1 and W5 |
| `c/w2.c`, `c/w3.c`, `c/w4.c` | the other C models, each beginning with the Ren it models |
| `c/count.c` | the item counts |
| `rust/src/main.rs`, `go/main.go` | the twins |
| `build.sh` | builds all of it |
| `measure.py` | `python3 -I measure.py 11 [filter]` |
| `summarize.py` | the tables |
| `results/e3.jsonl` | every run |
| `results/e3.summary.json` | the medians |
| `results/e3.txt` | the raw summary |
| `results/e3.tables.md` | the generated tables |
| `asm/w1.s`, `asm/w3.s` | the asm checked above |

# Native slice: what the benchmarks measure

The native slice ([compiler.md](../../compiler.md#native-slice),
[foundations.md](../../foundations.md#staging), item 2) was built to put
numbers on the memory and dispatch bet before tasks and many cores
build on it. These are those numbers, H1 to H7, with a verdict for
each: **holds**, **fails**, or **inconclusive**, and for each failure
what the generated C or the `--stats` counts say causes it and what
would fix it. The programs are in this folder ([README.md](README.md));
[vision.md](../../vision.md) says what the bars are.

## Small values and packed fields (compiler.md, step 10)

Packed scalar fields (Lean's) and small values as values (Koka's),
against 31fc1ca, the commit before them, in **one** hyperfine
invocation per program (`-N --warmup 3 --runs 10`, release builds at
main.ren's size), with CPU cycles and instructions retired as hyperfine
records them; peak memory is its per-run mean. "no frames" is the new
compiler with stack.ml's pass off (`REN_NO_STACK` when building), which
says what H8's frames still add on top. Load average 2.2 to 6.5 of 16
cores during the run. Every binary prints what the Rust twin prints.

| program | 31fc1ca (s) | now (s) | now, no frames (s) | Rust (s) | now / 31fc1ca, cycles | no frames / now, cycles | instructions 10⁹, 31fc1ca / now | MB, 31fc1ca | now | Rust |
|---|---|---|---|---|---|---|---|---|---|---|
| rbtree | 0.953 ± 0.007 | 0.866 ± 0.006 | 0.863 ± 0.006 | 1.496 ± 0.100 | **0.91×** | 1.00× | 11.69 / 12.74 | 203.2 | **169.6** | 136.2 |
| deriv | 0.719 ± 0.010 | 0.741 ± 0.010 | 0.737 ± 0.013 | 1.867 ± 0.094 | 1.03× | 1.00× | 9.15 / 9.15 | 474.7 | 474.7 | 1023.2 |
| nqueens | 0.737 ± 0.013 | 0.734 ± 0.006 | 0.738 ± 0.013 | 1.066 ± 0.026 | 1.00× | 1.01× | 5.23 / 5.23 | 99.6 | 99.5 | 189.9 |
| cfold | 0.162 ± 0.002 | 0.163 ± 0.002 | 0.163 ± 0.002 | 0.651 ± 0.013 | 1.00× | 1.00× | 1.09 / 1.09 | 130.0 | 130.0 | 377.1 |
| binary-trees | 7.646 ± 0.149 | 7.732 ± 0.191 | 7.760 ± 0.238 | 12.581 ± 0.144 | 1.01× | 1.00× | 105.11 / 105.11 | 202.8 | 202.8 | 137.8 |
| nbody | 4.264 ± 0.299 | 4.057 ± 0.210 | 4.078 ± 0.218 | 1.683 ± 0.002 | 0.96× | 1.01× | 64.73 / 64.73 | 1.4 | 1.4 | 1.5 |
| fannkuch | 2.656 ± 0.017 | 2.651 ± 0.018 | 2.657 ± 0.024 | 2.651 ± 0.006 | 1.00× | 1.00× | 21.22 / 21.22 | 1.5 | 1.5 | 1.6 |
| inout | 2.517 ± 0.014 | 2.509 ± 0.009 | 2.506 ± 0.012 | 1.359 ± 0.001 | 1.00× | 1.00× | 56.09 / 56.09 | 1.5 | 1.5 | 1.6 |
| stack (H8) | 0.986 ± 0.002 | 0.988 ± 0.003 | 0.988 ± 0.003 | 0.907 ± 0.001 | 1.00× | 1.00× | 6.66 / 6.13 | 1.5 | 1.5 | 1.5 |

H8's four kernels alone, 50 million rounds each, both compilers with
and without frames (cycles 10⁹; instructions 10⁹ in brackets):

| kernel | 31fc1ca | 31fc1ca, no frames | now | now, no frames | allocations, 31fc1ca no frames / 31fc1ca / now |
|---|---|---|---|---|---|
| records | 0.566 (1.92) | 1.407 (6.27) | 0.565 (1.92) | 0.565 (1.92) | 50 million / 0, 50 million in a frame / 0 |
| options | 0.561 (1.46) | 0.767 (3.71) | 0.561 (1.02) | 0.562 (1.02) | 33 million / 0, 33 million in a frame / 0 |
| tuples | 0.614 (1.97) | 0.628 (4.32) | 0.614 (1.87) | 0.615 (1.87) | 50 million / 0, 50 million in a frame / 0 |
| blocks | 0.564 (1.97) | 1.409 (6.12) | 0.562 (1.97) | 0.562 (1.97) | 50 million / 0, 50 million in a frame / 0 |

- **Packing: rbtree's peak memory 203.2 MB to 169.6 MB, 1.49× Rust's to
  1.25×,** its node four words, not five, color and value in one (peak
  live bytes 201.6 to 168.0 million); 9% fewer cycles on 9% more
  instructions, the shifts and masks costing less than the memory they
  save. binary-trees can't gain: `Node(left, right)` has no scalar, and
  its 1.47× is the header's 8 bytes on Rust's 16.
- **Small values: every H8 kernel allocates nothing, and nothing is
  left for the frame.** Without frames, a record, an option, a tuple
  and a record given to a block now cost what H8's frames made them
  cost (0.56 to 0.61 billion cycles), with up to 30% fewer instructions
  (options, 1.46 to 1.02 billion: no frame object to build and read);
  31fc1ca without frames took 1.02× to 2.50× as many cycles. The
  kernels are bound by their `%`s, so the instructions saved don't show
  as time.
- **What H8's frames add on top: nothing measurable.** With small
  values, no program here keeps an object in a frame but binary-trees'
  2.8 million roots, which save 0.3% of its instructions and no time
  outside noise. The H7 set doesn't use small values in its hot loops
  (rbtree, deriv, nqueens, cfold and binary-trees build recursive
  types; nbody, fannkuch and inout were already structs or arrays of
  scalars), so it moves only by packing.

## Combined

Five experiments, each built from 920456c, are merged on top of H5's
work (compiler.md, step 8): `map` in place and no stack check where
recursion can't go; nested reuse, reuse into inlined builders and an
inline reset; an 8-byte header and a small-object allocator; objects
kept in the frame (H8); and shared or atomic counting behind build
flags. These are all of them together, against the compiler at
920456c, which is before H5's work too, so a ratio to it counts H5's
gains. The sections after this one are the history: what each
hypothesis measured before.

**How.** Ren 920456c, Ren combined, Rust and Go in **one** hyperfine
invocation per program (`-N --warmup 3 --runs 10`), release builds at
main.ren's size. Peak resident memory is hyperfine's per-run mean. The
machine was shared with other agents' work (the "load" column is the
1-minute load average before and after each program's run, of 16
cores), so 920456c's rbtree, nbody and inout times swung by ±50% to
±70% in a run; ratios to 920456c are therefore of **CPU cycles**,
which hyperfine records per run and load hardly moves. Every binary
prints what the Rust twin prints. The scripts are as build.sh and
measure.sh make them; blocks' chain kernel is new in build.sh.

| program | Ren 920456c (s) | Ren combined (s) | Rust (s) | Go (s) | combined / 920456c, cycles | combined / Rust, time | combined / Rust, cycles | combined / Go, time | Ren MB, 920456c | combined | Rust | Go | memory, combined / Rust | load |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| rbtree | 2.438 ± 1.159 | 0.621 ± 0.003 | 0.856 ± 0.019 | 0.391 ± 0.004 | 0.34× | **0.73×** | 0.72× | 1.59× | 270.7 | 203.1 | 136.2 | 221.3 | **1.49×** | 5.6–7.3 |
| deriv | 1.010 ± 0.017 | 0.477 ± 0.003 | 1.135 ± 0.027 | 1.034 ± 0.026 | 0.46× | **0.42×** | 0.41× | 0.46× | 682.0 | 474.8 | 1023.3 | 1332.7 | 0.46× | 7.3–7.3 |
| nqueens | 0.670 ± 0.012 | 0.476 ± 0.005 | 0.636 ± 0.010 | 0.499 ± 0.015 | 0.71× | **0.75×** | 0.75× | 0.95× | 138.5 | 99.5 | 189.9 | 126.2 | 0.52× | 7.3–6.5 |
| cfold | 0.171 ± 0.004 | 0.102 ± 0.001 | 0.426 ± 0.007 | 0.316 ± 0.008 | 0.59× | **0.24×** | 0.24× | 0.32× | 161.5 | 130.0 | 377.1 | 627.7 | 0.34× | 6.5–6.8 |
| binary-trees | 13.003 ± 0.278 | 4.863 ± 0.086 | 8.393 ± 0.034 | 4.812 ± 0.023 | 0.37× | **0.58×** | 0.58× | 1.01× | 274.8 | 202.8 | 137.8 | 216.9 | **1.47×** | 5.5–5.4 |
| nbody | 24.475 ± 11.621 | 2.603 ± 0.055 | 1.089 ± 0.000 | 1.791 ± 0.030 | 0.15× | **2.39×** | 2.39× | 1.45× | 1.4 | 1.4 | 1.5 | 4.2 | 0.93× | 4.8–5.5 |
| fannkuch | 4.297 ± 0.012 | 1.736 ± 0.004 | 1.733 ± 0.001 | 1.617 ± 0.003 | 0.41× | **1.00×** | 1.00× | 1.07× | 1.5 | 1.5 | 1.6 | 4.3 | 0.93× | 6.7–4.8 |
| inout | 11.658 ± 6.926 | 1.712 ± 0.012 | 0.964 ± 0.002 | 1.635 ± 0.008 | 0.20× | 1.78× | 1.85× | 1.05× | 1.5 | 1.5 | 1.6 | 4.3 | 0.95× | 5.9–6.7 |
| stack (H8) | 2.478 ± 0.032 | 0.648 ± 0.001 | 0.595 ± 0.001 | 0.579 ± 0.000 | 0.27× | 1.09× | 1.09× | 1.12× | 1.6 | 1.5 | 1.6 | 4.2 | 0.93× | 6.8–5.9 |

The first seven are H7's set. Cycles, 10⁹, 920456c / combined / Rust /
Go (Go's include its collector's threads): rbtree 7.17 / 2.46 / 3.40 /
2.01; deriv 3.93 / 1.83 / 4.43 / 11.61; nqueens 2.65 / 1.89 / 2.52 /
2.65; cfold 0.67 / 0.40 / 1.68 / 2.11; binary-trees 52.4 / 19.6 / 33.8 /
45.2; nbody 67.8 / 10.5 / 4.39 / 7.08; fannkuch 16.9 / 6.92 / 6.91 /
6.44; inout 32.2 / 6.56 / 3.55 / 6.28. `--stats`, 920456c to combined:
rbtree allocates 50.4 million objects to 4.2 million (one an insertion,
as Rust), with no dups left; cfold 3.48 to 3.15 million; binary-trees
614 to 611 million, 2.8 million roots kept in a frame; peak live bytes
fall 14% (rbtree) to 29% (cfold) on everything that allocates (the
header).

blocks' kernels, H1 (blocks / loop, both builds in one run, cycles 10⁹):

| kernel | 920456c, time (s) | combined, time (s) | 920456c, cycles | combined, cycles | instructions 10⁹, 920456c | combined | load |
|---|---|---|---|---|---|---|---|
| map | 0.368 ± 0.002 / 0.360 ± 0.027 | 0.339 ± 0.001 / 0.578 ± 0.022 | 1.465 / 1.307 = 1.12× | 1.347 / 1.447 = 0.93× | 5.19 / 4.89 | 3.47 / 4.16 | 5.5–5.6 |
| reduce | 0.087 ± 0.008 / 0.078 ± 0.006 | 0.068 ± 0.006 / 0.049 ± 0.003 | 0.204 / 0.207 = 0.99× | 0.154 / 0.154 = 1.00× | 1.13 / 1.13 | 1.03 / 1.03 | 5.6–5.8 |
| each | 0.056 ± 0.006 / 0.054 ± 0.005 | 0.040 ± 0.003 / 0.040 ± 0.003 | 0.198 / 0.205 = 0.97× | 0.150 / 0.153 = 0.98× | 1.12 / 1.12 | 1.02 / 1.02 | 5.8–6.1 |
| fold | 0.213 ± 0.005 / 0.207 ± 0.009 | 0.215 ± 0.005 / 0.208 ± 0.008 | 0.830 / 0.817 = 1.02× | 0.832 / 0.811 = 1.03× | 3.83 / 3.83 | 3.83 / 3.83 | 6.1–5.9 |
| attempt | 0.095 ± 0.003 / 0.098 ± 0.005 | 0.097 ± 0.005 / 0.093 ± 0.002 | 0.375 / 0.389 = 0.97× | 0.384 / 0.367 = 1.05× | 2.72 / 2.72 | 2.72 / 2.72 | 5.9–5.9 |
| chain | 1.102 ± 0.011 / 0.182 ± 0.001 | 0.094 ± 0.000 / 0.058 ± 0.000 | 4.355 / 0.684 = 6.37× | 0.363 / 0.219 = 1.65× | 14.71 / 6.32 | 2.23 / 1.42 | 5.9–5.9 |

`map` over a unique array (map_unique) goes from 1.410 to 0.219
billion cycles, **6.4× fewer** (0.366 s to 0.057 s), and from 100,003
allocations to 3: map writes in place, and hoist.ml hoists that loop
like any other. The chain, three `map`s a round, is 12× fewer cycles
than at 920456c and **1.65×** the loop fused by hand, which three
passes over the elements instead of one cost; it allocates what the
fused loop does. `map`'s blocks kernel is now *faster* than its loop
twin, which still pushes into `[]` where `map` reserves its length
once; that loop twin takes 11% more cycles than at 920456c on 15% fewer
instructions, which wasn't looked into (H1's placement effect is the
first suspect).

**fannkuch, and the runtime experiment's 13%.** It doesn't persist.
In one run, with fannkuch built five ways: 920456c 16.90 billion
cycles; H5's work alone (301da87) 6.76; combined 6.91; combined with
the allocator off (`REN_CFLAGS=-DREN_SYSTEM_MALLOC`) 6.90; Rust 6.90.
The allocator changes nothing here now: the loop the 13% was in, the
out-of-line `ren_array_set_taking`, is gone (H5). What's left, combined
2.2% more cycles than H5 alone on 3.8% fewer instructions (22.05 to
21.22 billion: the stack checks `flip` no longer makes), is where the
code lands: the program's C is the same but for those checks, and
built with `-falign-functions=64 -mllvm -align-all-nofallthru-blocks=6`
the two take 6.788 and 6.784 billion cycles.

One line each:

- **H1, blocks cost nothing: holds.** Release blocks / loops 0.93× to
  1.05× in cycles, instructions equal but `map`'s, which now does less
  than its loop.
- **H2, a known handler's operation costs a call: holds,** unchanged
  (not run again; nothing here touches it).
- **H3, Perceus counts far less: holds,** and more so: rbtree makes no
  dups at all now, and every program of the Perceus set is faster than
  Rust (0.24× to 0.75×).
- **H4, Perceus allocates less: holds,** with both earlier gaps closed:
  `map` over a unique array allocates 3 objects in all, and rbtree one
  node an insertion, as Rust.
- **H5, array loops at Rust's speed: partly.** fannkuch 1.00× Rust;
  inout 1.85× and nbody 2.39× in cycles, for the index, overflow and
  NaN checks Rust's release build doesn't make (H5 below).
- **H6, debug builds faster than `go build`: fails,** unchanged (not
  run again).
- **H7, within 2× of Rust in time and memory: holds** on six of seven;
  nbody is 2.39×, its NaN checks 31% of its cycles. Memory is within
  1.5× of Rust on all seven, rbtree and binary-trees at 1.49× and
  1.47×, the count in the header the rest of it. Against Go: faster
  on deriv, cfold and nqueens, tied on binary-trees (1.01×), slower on
  rbtree (1.59×), nbody (1.45×) and fannkuch (1.07×).
- **H8, values that never escape live in the frame: holds where it
  applies, which is rarely.** The kernels made of temporaries run at
  Rust's speed (stack: 0.27× of 920456c's cycles, 1.09× Rust); in the
  H7 set it moves nothing but binary-trees' roots, since those programs
  return or store what they build. Second-class blocks matter for
  escape only where an object is handed to a block (stack.md, in the
  experiments).
- **Many cores (cores experiment): the shared bit is cheap and
  necessary, not sufficient.** Counting shared objects atomically only
  costs 1 to 4% of cycles single-threaded, but a shared object that's
  counted scales as Rust's `Arc` does, which collapses to 2 to 12%
  efficiency at 8 threads on data hot in cache; borrowed reads and
  frozen (never counted) state scale. `-DREN_RC_SHARED`,
  `-DREN_RC_ATOMIC` and bench/native/cores build and run on the 8-byte
  header.

**Restricted to stay sound, and left:** a loop hoist.ml indexes that
builds a framed object stays in its function, without `restrict`;
reuse never takes a framed object's memory, nor builds in it; a framed
object must never be marked shared (no code marks anything shared yet;
publishing one would be an escape). The allocator's heap is per thread
only in the experimental counting modes, and a block freed on another
thread joins that thread's lists, since chunks are never given back:
fine for the harness, not the design for tasks (mimalloc's delayed
free is).

## Summary (before the merge)

| | Hypothesis | Number | Verdict |
|---|---|---|---|
| H1 | a block costs nothing once specialized | release blocks / loops 0.99× to 1.03×, map 1.12×; allocations equal in both builds | **holds**: map's gap is where the code lands, not what it does (below) |
| H2 | a call to a known handler costs a function call | 0.45 ns against 0.45 ns, release | **holds** |
| H3 | Perceus counts far less than naive, and that shows in time | 12× to 137× fewer dups and drops; 0.40× to 2.20× Rust, naive 0.94× to 6.31× | **holds** |
| H4 | Perceus allocates less and peaks lower | rbtree 3.6× fewer allocations, map over a unique array 1,000×, fannkuch 10 against 2.3 billion; peak equal on rbtree | **holds**, but `map` doesn't reuse its input |
| H5 | exclusivity and Perceus's uniqueness let array loops run at Rust's speed, with `restrict` on the buffers | `restrict` 1.05× on inout, 1.00× and 1.00× on fannkuch and nbody; after the hoist, fannkuch 0.98× Rust, inout 1.84×, nbody 2.35× (cycles) | **fails** as stated: uniqueness hoisted out of loops is most of it, `restrict` 5% where it applies, and the checks Rust doesn't make keep two of three off Rust's speed |
| H6 | debug builds faster than `go build` | 500k lines: 56.7 s against 12.6 s clean; a leaf edit 56.6 s against 0.64 s | **fails**: 77% of it is clang -O0, and Ren has no build cache yet |
| H7 | within 2× of Rust, in time and peak memory | 5 of 7 within 2× in time (0.40× to 1.57×; fannkuch now 0.93×); rbtree 2.20×, nbody 2.74× (15.5× before H5's work); memory all within 2×, two at 1.99× | **fails** on two programs: nbody on its checked `Float` operations, rbtree on allocation |

## Setup

- **Machine:** Apple M4 Max, 16 cores, 128 GiB, macOS 15.1 (Darwin
  24.1.0). Other work ran on the machine at the same time (a load
  average of 3 to 4 out of 16 cores); every program measured is single
  threaded but Go's collector and `go build`, and the standard
  deviations below say how much that moved.
- **Compilers:** Apple clang 16.0.0 (clang-1600.0.26.6) as `cc`;
  rustc 1.99.1; go 1.27.3; hyperfine 2.0.0. `tcc` isn't on the
  machine's PATH, so the debug builds use clang -O0 (H6 says what that
  means).
- **Ren:** commit 6c0b721 (native step 5) with this step's two fixes
  to the compiler's speed (H6).
- **Flags:** `ren build --debug` is `cc -O0 -g -ffp-contract=off`;
  `ren build --release` is `cc -O2 -ffp-contract=off` on the
  specialized program, `--rc naive` the same with step 2's counting,
  `--no-restrict` the same without `restrict`. Rust is `rustc -C
  opt-level=3 -C codegen-units=1`, Go plain `go build`.
- **How:** `sh build.sh out` builds every configuration;
  `sh measure.sh out results` runs hyperfine (`--warmup 3 --runs 10`,
  binaries run with `-N`, no shell; JSON in `results/<name>.json`),
  `/usr/bin/time -l` once per binary for peak resident memory
  (`memory.tsv`), and each `--stats` build once (`stats.tsv`);
  `python3 -I summarize.py results` prints the tables below. Times are
  hyperfine's mean wall-clock time ± its standard deviation, ratios are
  of means. The naive builds of `nbody` and `inout` aren't timed: they
  copy their arrays at every write (a run of nbody naive takes 181 s,
  inout more than 5 minutes), and no hypothesis needs them.
- **Go** runs as it does by default, its collector on other cores.

## H1: blocks against loops

`blocks`' kernels, each alone (build.sh's kernels/blocks-*), at
100,000 rounds over 1,000 Ints or a tree of as many. Times are the
release build; allocations and block calls are from `--stats`, debug
and release. A block call is a call through a block's code pointer; 2
of them are `print`'s, which goes through `Console`.

| kernel | blocks (s) | loop (s) | blocks / loop | allocations debug, blocks / loop | allocations release, blocks / loop | block calls, debug / release |
|---|---|---|---|---|---|---|
| map | 0.362 ± 0.001 | 0.323 ± 0.001 | 1.12× | 100,003 / 100,003 | 100,003 / 100,003 | 100,000,002 / 2 |
| reduce | 0.049 ± 0.004 | 0.048 ± 0.005 | 1.03× | 3 / 3 | 3 / 3 | 100,000,002 / 2 |
| each | 0.047 ± 0.005 | 0.048 ± 0.005 | 0.99× | 3 / 3 | 3 / 3 | 100,000,002 / 2 |
| fold | 0.201 ± 0.005 | 0.199 ± 0.005 | 1.01× | 1,002 / 1,002 | 1,002 / 1,002 | 100,000,002 / 2 |
| attempt | 0.092 ± 0.003 | 0.091 ± 0.002 | 1.01× | 2 / 2 | 2 / 2 | 200,000,001 / 2 |

**Verdict: holds.** A block allocates nothing in either build, the
debug build calls it through its code pointer and the release build
never does, and four of the five kernels run as fast as their loops.

`map`'s 12% isn't the block. The release C (`--emit-c`) lifts the
block into `map_blocks$1`, which `Array.map$1` calls directly, and
clang inlines both: the inner loop of the two kernels compiles to the
same instructions but one, the lifted function's `REN_STACK_CHECK()`,
three instructions an element (hyperfine counts 5.19 billion
instructions against 4.89). Taking the check out of both leaves them
11% apart (364 ms against 328) with identical loops, and building both with
`-falign-functions=64 -mllvm -align-all-nofallthru-blocks=6` brings
them to 368 ms against 363 ms, 1.3%: the rest was where the loop
landed in memory. **Fix,** for the 1.3%: no stack check in a function
that calls nothing, which can't be where the stack runs out.

## H2: an operation of a known handler

`handlers`' two loops, each alone, 10⁹ calls of `Counter.bump` inside
`with counter() in`, against 10⁹ calls of a plain `bump(total, k)`.
The debug build passes evidence: each call finds the handler in the
evidence chain (`ren_find`) and calls its operation through a code
pointer, its argument in an array. It's measured at -O0, as `ren build
--debug` builds it, and again at -O2 (`REN_CFLAGS=-O2`), to tell the
strategy's cost from -O0's.

| build | `Counter.bump` (ns/call) | plain call (ns/call) | ratio |
|---|---|---|---|
| release | 0.45 | 0.45 | 1.00× |
| debug (-O0) | 13.48 | 9.60 | 1.40× |
| debug strategy at -O2 | 1.24 | 0.45 | 2.75× |

**Verdict: holds.** The release build calls `counter.bump` directly,
its state a cell passed by pointer, and clang inlines it: the loop is
the plain one's, 12.0 billion instructions each. Evidence passing
costs 0.8 ns a call more at -O2, and 4 ns at -O0, where the plain call
is already 9.6 ns.

## H3: counting, Perceus against naive

The Perceus set, release builds. Dups and drops are `--stats`'
counts; reuses are objects built in the memory of one that died.

| program | dups + drops, Perceus | naive | naive / Perceus | reuses | Perceus (s) | naive (s) | Rust (s) | Perceus / Rust | naive / Rust |
|---|---|---|---|---|---|---|---|---|---|
| rbtree | 16,799,871 | 2,301,230,569 | 137.0× | 130,188,893 | 1.704 ± 0.012 | 4.899 ± 0.029 | 0.776 ± 0.015 | 2.20× | 6.31× |
| deriv | 90,532,200 | 1,078,613,510 | 11.9× | 4,455,637 | 0.995 ± 0.011 | 1.231 ± 0.018 | 1.113 ± 0.017 | 0.89× | 1.11× |
| nqueens | 14,098,355 | 1,746,617,151 | 123.9× | 0 | 0.623 ± 0.011 | 1.256 ± 0.012 | 0.604 ± 0.011 | 1.03× | 2.08× |
| cfold | 1,384,498 | 188,244,465 | 136.0× | 10,862,497 | 0.166 ± 0.003 | 0.388 ± 0.010 | 0.412 ± 0.010 | 0.40× | 0.94× |

**Verdict: holds.** Perceus counts 12 to 137 times less, and runs 1.2
to 2.9 times faster than naive counting; three of the four are as fast
as Rust or faster. deriv shares its terms, so most of its counting is
real sharing, and it gains least. rbtree is the one over 2×: H7 says
why.

## H4: allocations and peak memory

`--stats`' allocations and peak live bytes, and peak resident memory
from `/usr/bin/time -l`, release builds. "map over a unique array" is
build.sh's kernels/blocks-map_unique: `ys = ys.map(fn(x) => ...)`
100,000 times over 1,000 Ints, the array held by nothing else.

| program | allocations, Perceus | naive | peak live bytes, Perceus | naive | peak RSS MB, Perceus | naive |
|---|---|---|---|---|---|---|
| rbtree | 50,377,452 | 180,566,345 | 235,200,080 | 235,201,760 | 270.7 | 270.8 |
| map over a unique array | 100,003 | 100,101,003 | 16,488 | 24,136 | 2.4 | 6.0 |
| fannkuch | 10 | 2,282,240,147 | 643 | 536 | 1.5 | 1.9 |
| deriv | 36,632,293 | 41,087,930 | 643,059,191 | 643,076,896 | 682.1 | 682.1 |
| nqueens | 9,349,781 | 9,349,781 | 129,821,976 | 181,838,520 | 138.6 | 268.2 |
| cfold | 3,481,648 | 14,344,145 | 58,720,280 | 109,051,832 | 161.6 | 228.8 |

**Verdict: holds.** Perceus allocates 3.6 times less on rbtree, 1,000
times less on `map`, and fannkuch allocates 10 objects in all, where
the naive build copies an array at every write, 2.3 billion times (63
s, against 4.2). Peak memory is lower or the same: rbtree's peak is
its tree, which both builds hold whole.

Two things it shows that are short of the plan:

- **`map` builds a new array each round** and frees the old one: 1
  allocation and 10 regrowths a round where Lean's `Array.map` writes
  into the array it was given when it's unique
  (lean4/src/Init/Data/Array/Basic.lean:766, `mapMUnsafe`). **Fix:**
  the prelude's `map` reuses a unique input of the same element
  layout, and otherwise reserves its length once.
- **rbtree still allocates 12 nodes an insertion.** Reuse is one level
  deep (compiler.md, step 4): `balance` reuses the node it takes apart
  but not the ones inside it, so the counts and allocations Koka's
  nested drop specialization saves are spent here. And where `ins`
  rebalances, it frees the token of the node it took apart right after
  calling `balance_left` or `balance_right`, which then allocates fresh
  nodes, so that node is never reused there; nested reuse alone
  wouldn't get it back. **Fix:** nested reuse, after Koka's
  ParcReuse.hs, and the token carried into the call that builds,
  which Koka gets by inlining `balance` into `ins`.

## H5: arrays in loops, and `restrict`

The claim: the exclusivity rule (foundations.md, decision 2), that an
`&` parameter's slot aliases nothing the function can see, and
Perceus's uniqueness, a count of 1 checked at run time, together let a
loop over arrays run at Rust's speed, with `restrict` on the arrays'
buffers. The first measurement, kept below as "before", found
`restrict` on the cells did nothing, since every element was reached
through an out-of-line call. So four changes were built (compiler.md,
"Step 7") and measured after each:

| build | what it adds |
|---|---|
| s0 | before: commit 920456c, `restrict` on each `&` parameter's cell |
| s1 | the array's fast paths inline in the C: the index checked, the count checked, the element read or written, a panic or a copy the only calls (lean.h's `lean_array_uset`) |
| s2 | `a[i].f = w` writes the field, in place in a unique array, rather than building the element again and copying it in |
| s3 | a loop that makes no new reference to an array has it made unique once, before the loop, and indexes its buffer inside (hoist.ml); built `--no-restrict` |
| s4 | the same with `restrict` on the buffers: the release build |

The machine was loaded while this ran (a load average of 8 to 13 of 16
cores), and its wall-clock times are slower than the first
measurement's and noisy: inout's s0 took 14.0 s ± 1.6 here and 7.69 s
then. Each program's builds ran back to back in one hyperfine run
(`-N --warmup 3 --runs 10`, measure.sh's), with its Rust twin, so the
ratios compare like with like; and hyperfine's CPU cycles, which
contention moves far less, are given beside the time, with the
instructions retired. Ratios are of means. Every build prints what the
Rust twin prints.

| program | build | time (s) | / Rust | cycles (10⁹) | / Rust | instructions (10⁹) |
|---|---|---|---|---|---|---|
| inout | s0 | 14.041 ± 1.618 | 7.82× | 31.64 ± 0.69 | 8.89× | 288.1 |
| | s1 | 5.443 ± 0.308 | 3.03× | 11.88 ± 0.01 | 3.34× | 106.1 |
| | s2 | 5.460 ± 0.311 | 3.04× | 11.90 ± 0.06 | 3.34× | 106.1 |
| | s3 | 2.464 ± 0.204 | 1.37× | 6.86 ± 0.03 | 1.93× | 60.1 |
| | s4 | 2.685 ± 0.265 | 1.50× | 6.56 ± 0.04 | 1.84× | 56.1 |
| | Rust | 1.795 ± 0.200 | | 3.56 ± 0.03 | | 27.0 |
| fannkuch | s0 | 7.577 ± 0.229 | 2.12× | 16.91 ± 0.04 | 2.44× | 127.9 |
| | s1 | 3.408 ± 0.095 | 0.95× | 7.41 ± 0.03 | 1.07× | 34.8 |
| | s2 | 3.179 ± 0.134 | 0.89× | 7.43 ± 0.06 | 1.07× | 34.8 |
| | s3 | 3.401 ± 0.272 | 0.95× | 6.77 ± 0.02 | 0.98× | 22.1 |
| | s4 | 3.331 ± 0.203 | 0.93× | 6.77 ± 0.02 | 0.98× | 22.1 |
| | Rust | 3.570 ± 0.144 | | 6.92 ± 0.01 | | 13.2 |
| nbody | s0 | 32.005 ± 1.738 | 18.79× | 66.85 ± 0.46 | 15.23× | 406.7 |
| | s1 | 9.604 ± 0.367 | 5.64× | 23.82 ± 0.18 | 5.43× | 114.6 |
| | s2 | 5.331 ± 1.208 | 3.13× | 11.50 ± 0.21 | 2.62× | 93.7 |
| | s3 | 4.747 ± 0.305 | 2.79× | 10.26 ± 0.20 | 2.34× | 64.9 |
| | s4 | 4.666 ± 0.207 | 2.74× | 10.31 ± 0.27 | 2.35× | 64.9 |
| | Rust | 1.703 ± 0.055 | | 4.39 ± 0.00 | | 14.2 |
| rbtree | s0 | 2.731 ± 0.058 | 2.46× | 7.04 ± 0.09 | 2.12× | 39.3 |
| | s4 | 2.458 ± 0.042 | 2.21× | 6.98 ± 0.05 | 2.10× | 39.3 |
| | Rust | 1.112 ± 0.045 | | 3.32 ± 0.13 | | 6.4 |

rbtree, which has no arrays, is the check that nothing else moved: it
retires 39.3 billion instructions in every build, s1 to s3 too.

`restrict`, without it against with it, the number H5 is about:

| program | before: cells, time / cycles | after: buffers, time / cycles |
|---|---|---|
| inout | 1.117 / 1.008 | 0.918 / **1.046** |
| fannkuch | 1.045 / 0.999 | 1.021 / 1.000 |
| nbody | 0.936 / 1.000 | 1.017 / 0.995 |

The times swing ±10% with the load either way; the cycles don't. On
inout, the one program whose loop changes two arrays, `restrict` on the
buffers saves 4.6% of the cycles, 4 billion instructions of 60: in
`a[i] = ...; b[i] = (b[i] + a[i]) % 65536`, `b[i]` is loaded once
rather than again after the store to `a[i]` (the assembly, below).
fannkuch's loops change one array each and nbody's one array, and
there `restrict` has nothing to tell C.

**Verdict: fails as stated.** The parts:

- **Uniqueness hoisted is most of it,** and it's sound by the
  exclusivity rule and Perceus together: after the inline fast paths
  (2.6× on inout, 2.3× on fannkuch, 2.8× on nbody) and the field
  written in place (2.1× more on nbody), the hoist takes 42% off
  inout's cycles, 9% off fannkuch's and 11% off nbody's, and fannkuch
  runs at Rust's speed (0.98×).
- **`restrict` on the buffers is real but small:** 1.05× on the one
  program it applies to, with none of the vectorizing it was meant to
  allow.
- **Two of three aren't at Rust's speed,** for checks Rust's release
  build doesn't make. inout is at 1.84× and nbody at 2.35×.

**Do the loops vectorize? No,** not one, with or without `restrict`
(`-Rpass=loop-vectorize`, and the assembly). inout's inner loop has
five ways out an element besides its end: two index checks (`a`'s is
gone, its bound being the length hoisted) and three overflow checks,
of `*` once and `+` twice. The vectorizer of this clang won't take a
loop with a way out like that. Rust's
`step`, inlined into `main`, knows each slice's length is 1,000, so its
index checks are gone, and its release build doesn't check overflow:
it vectorizes two lanes wide. To tell what the checks cost, the
release C was compiled again with them taken out (an experiment, not a
build Ren makes):

| program | as built | no index checks | no `Int` overflow or `Float` NaN checks | neither | Rust |
|---|---|---|---|---|---|
| inout, cycles (10⁹) | 6.55 | 5.88 | 6.73 | 5.42 | 3.56 |
| nbody, cycles (10⁹) | 10.44 | 10.69 | 7.22 | 7.29 | 4.39 |

nbody's checks of each `Float` operation for a NaN are 31% of its
cycles; its index checks cost nothing measurable. With both kinds out,
inout's loop is legal to vectorize, and clang's cost model declines
(`-Rpass-missed`: "vectorization is not beneficial"; the M4 has no
64-bit vector multiply), where Rust's newer LLVM does it.

How `restrict` was made to count, which the first measurement couldn't
see: clang ignores `restrict` on a pointer declared in a block, and
keeps it on a parameter, also once the function is inlined. So
emit_c.ml writes a hoisted loop as a function of its own, inlined,
whose buffers are `restrict` parameters, and `--no-restrict` leaves
only the keyword out. Even then, `restrict` reaches only the loads and
stores in that function when clang inlines it, not those in a runtime
function it calls and inlines later, so the buffer's accesses are
macros. Built with plain inline functions, the inner loop still loaded
`b[i]` twice; with the macros:

```
ldr  x2, [x10, x9, lsl #3]    ; b[i]
ldr  x8, [x11, x9, lsl #3]    ; c[i]
mul  x3, x2, x8 ...           ; b[i] * c[i], checked
ldr  x8, [x23, x9, lsl #3]    ; a[i]
adds x12, x8, x3 ...          ; checked, then % 65536
str  x3, [x23, x9, lsl #3]    ; a[i] =
adds x8, x2, x3               ; b[i] + a[i], b[i] not loaded again
```

**Fix,** for the rest: the index checks of a loop `for i in lo..hi`
made once, `hi <= len`, before it, so `a[i]` needs none; and the
`Float` NaN checks are the language's (operators.md), so what they cost
is the price of that rule, 31% of nbody, a thing to weigh rather than
to fix in the backend.

### Before


The first measurement: the release build with `restrict` on each `&`
parameter, and with `--no-restrict`.

| program | restrict (s) | --no-restrict (s) | without / with | Rust (s) |
|---|---|---|---|---|
| inout | 7.690 ± 0.010 | 7.690 ± 0.014 | 1.00× | 0.879 ± 0.001 |
| fannkuch | 4.187 ± 0.008 | 4.193 ± 0.015 | 1.00× | 1.677 ± 0.006 |
| nbody | 16.616 ± 0.620 | 16.424 ± 0.018 | 0.99× | 1.069 ± 0.001 |

**Verdict then: fails, a null result.** `restrict` changes nothing, and
the C says why. inout's `step(ren_obj** restrict a, ren_obj**
restrict b, ren_obj* c)` promises the two cells are apart, but the
elements are behind them: each `a[i] = v` is a call to
`ren_array_set_taking(*a, i, v, site)`, out of line, which checks the
index, checks the array is unique, copies it if not, and returns it to
be stored back in `*a`; and each read is `ren_array_get`, which checks
the index. A call clang can't see into may write anything, so no load
moves past it, and nothing vectorizes; `restrict` on the cell says
nothing about the buffers. Sampling the binary (`sample`, macOS) puts
72% of inout's time in `ren_array_set_taking`, 68% of fannkuch's, and
73% of nbody's in `ren_array_set_slots_taking` and the `memmove` it
calls.

**Fix:** the store's fast path inline in the C, as Lean's
`lean_array_uset` is (lean4/src/include/lean/lean.h:1158, a `static
inline` over `lean_ensure_exclusive_array`, :1142); the uniqueness check
hoisted out of a loop that makes no new reference to the array, so the
loop indexes its buffer directly; and `restrict` on those buffer
pointers, which the exclusivity rule makes true just as it does for
the cells. H5 could only be measured again after that, which is what
the part above did.

## H6: source to binary

gen/gen.py's programs, the same shape in both languages ([README.md](README.md)),
built from clean. `ren build --debug` is split into its two halves,
run apart: Ren's front half with lowering, Perceus and C emission
(`ren build --debug --emit-c`), and the C compiler on that C (`cc -O0
-g -ffp-contract=off`, as `ren build --debug` runs it). `go build` is
timed fully clean, an empty `GOCACHE`, which builds the standard library
too, and clean but for the standard library, a cache holding only what
a program importing `fmt` built. The leaf edit changes one number in a
function of the last module, which nothing imports, then builds again
on the cache the build before left. vision.md also asks for an edit
in a widely imported module; that wasn't measured, since every Ren
build is a clean one and would take what the leaf edit does.

| program | ren build --debug (s) | front half + C (s) | cc -O0 (s) | go build, clean (s) | go build, std cached (s) | Ren / Go std cached | Ren, leaf edit (s) | Go, leaf edit (s) | lines/s, Ren / Go clean |
|---|---|---|---|---|---|---|---|---|---|
| 10k (9,987 / 9,949 lines) | 1.105 ± 0.013 | 0.256 ± 0.001 | 0.847 ± 0.008 | 1.408 ± 0.012 | 0.209 ± 0.008 | 5.30× | 1.119 ± 0.008 | 0.124 ± 0.008 | 9,034 / 7,064 |
| 100k (99,115 / 98,580 lines) | 10.888 ± 0.053 | 2.493 ± 0.009 | 8.335 ± 0.056 | 2.210 ± 0.041 | 1.286 ± 0.021 | 8.46× | 10.825 ± 0.045 | 0.217 ± 0.007 | 9,103 / 44,602 |
| 500k (495,251 / 492,703 lines) | 56.706 ± 0.234 | 12.533 ± 0.033 | 43.768 ± 0.302 | 12.577 ± 2.530 | 14.905 ± 0.184 | 3.80× | 56.580 ± 0.118 | 0.636 ± 0.014 | 8,734 / 39,176 |

**Verdict: fails.** Ren beats a fully clean `go build` only at 10k
lines, where Go spends its time building its standard library; from
100k lines on it's 4 to 8 times slower, and after a one-line edit
it's 9 to 90 times slower, since Ren has no build cache yet: every
build, edit or not, is a clean one.

- **clang -O0 is 77% of it** (43.8 s of 56.7 at 500k), on one C file
  of 3.9 million lines. tcc isn't on this machine, so the bar is
  measured against clang -O0, which vision.md already says can't pass
  it: "the debug backend can't be clang." The front half alone runs at
  about 40,000 lines a second (12.5 s at 500k), as fast as all of
  `go build` in wall-clock time.
- **Go uses every core; Ren uses one.** hyperfine's CPU time for `go
  build` at 500k is 112 s against 12.6 s of wall-clock time; Ren's
  front half is 12.5 s of CPU, and clang one process. Ren's front half
  is per module (compiler.md), but the driver links and lowers the
  whole program in one process, into one C file.
- **Two quadratic costs were found and fixed while measuring.**
  to_mem.ml numbered each panic site by counting the list of all the
  sites made so far, and the driver read and split a module's source
  again for every site in it, to write its message. At 500k lines the
  front half took 76.8 s before and 12.3 s after; the C it writes is
  the same byte for byte.

**Fix,** in order of what it saves: tcc, or a backend of Ren's own,
for debug builds; one C file per module, compiled in parallel and
cached by the hash of the module's interface and body, which is also
what makes a leaf edit rebuild one module (stage 13's content-addressed
cache); then the front half in parallel per module.

## Release builds

compiler.md's step 9 fixed the four superlinear costs of the release
build, cut its panic text down to an interned table, and removed
specialization's per-function copy cap (decision 4). Before is 7f8822f
and after is step 9, both run in one session, on gen/gen.py's base
program (no generics) and its stress program (generic code called at
many types, each with a block of its own). "Front" means `ren build
--emit-c` (from source to C, through specialization, Core Lint, Mem,
Perceus and Mem Lint) and is reported with hyperfine's mean and its
CPU cycles; "cc" is clang -O2 on that C, as user CPU time. The sizes
are from `size -m` on the binary. Load averages ran 4 to 7 of 16
cores. 500k lines wasn't measured: base-500k's front half takes about
20 minutes before.

| program | front (s) | front cycles (bn) | cc (s) | `__text` (MB) | `__cstring` (MB) | stripped (MB) |
|---|---|---|---|---|---|---|
| base 10k | 0.568 → 0.378 | 2.13 → 1.37 | 7.6 → 7.7 | 0.758 → 0.759 | 0.650 → 0.015 | 1.52 → 1.06 |
| stress 10k | 3.08 → 1.09 | 10.7 → 3.7 | 12.4 → 14.4 | 1.36 → 0.88 | 1.72 → 0.042 | 3.33 → 1.51 |
| base 100k | 29.7 → 3.83 | 111.6 → 13.2 | 91.9 → 85.9 | — | 6.45 → 0.113 | 14.6 → 10.0 |
| stress 100k | 268.6 ± 39 → 9.62 | 897 → 38.1 | 96.3 → 112.4 | 13.6 → 8.6 | 17.2 → 0.32 | 32.9 → 14.5 |

- **The front half is linear again**: 28× fewer cycles on stress-100k
  and 8.5× fewer on base-100k. What's left at 100k (`REN_PASS_TIMES`)
  is C emission (1.4 s base, 2.7 s stress), Perceus (0.8 / 2.0), then
  folding, Core Lint and specialization (each 0.2 to 0.7).
- **Panic text was most of every binary**, and now isn't. Each site's
  message is a few LEB128 operations over a table of shared text and
  slices of source lines. Stripped binaries are 0.44 to 0.70 times as big.
- **Removing the cap trades C for machine code.** The stress program's
  C is 1.30 times as long (1.69M → 2.20M lines at 100k), and clang
  takes 1.17 times as long on it, but its `__text` is 0.63 times as
  big, since the cap's fallback, which boxed the arguments, was the
  bigger code. clang's peak memory at stress-100k went from 5.50 to 4.91 GB.
- **clang is now 92% to 96% of a release build at 100k** (85.9 s of
  89.7, 112.4 of 122.0). One C file per module, compiled in parallel and
  cached, is what's left (decision 13).

**The benchmarks' run times don't move.** Their Mem is byte for byte
what it was (with `REN_NO_FOLD`; folding folds nothing in them). Every
output matches its Rust twin. In one hyperfine invocation per program,
before against after, wall time differs by −3.6% to +1.0%,
instructions by under 0.01%, and cycles by under 1% (most within
±0.5%):

| program | cycles before (bn) | cycles after (bn) | wall before | wall after |
|---|---|---|---|---|
| rbtree | 2.459 | 2.455 | 645 ms | 635 ms |
| deriv | 1.821 | 1.819 | 477 ms | 475 ms |
| nqueens | 1.874 | 1.888 | 476 ms | 477 ms |
| cfold | 0.401 | 0.402 | 102 ms | 103 ms |
| binary-trees | 20.19 | 19.90 | 5.17 s | 4.99 s |
| nbody | 10.41 | 10.32 | 2.56 s | 2.58 s |
| fannkuch | 6.93 | 6.88 | 1.71 s | 1.71 s |
| inout | 6.57 | 6.57 | 1.63 s | 1.63 s |
| stack | 2.58 | 2.58 | 589 ms | 587 ms |

## H7: against Rust and Go

vision.md's set, the release build against Rust and Go: times from
hyperfine, peak resident memory from `/usr/bin/time -l`. Its real
program, the `just` or a JSON parser, isn't here: `examples/just`
stands for it until it's built natively ([README.md](README.md)).

| program | Ren (s) | Rust (s) | Go (s) | Ren / Rust | Ren / Go | Ren MB | Rust MB | Go MB | memory, Ren / Rust |
|---|---|---|---|---|---|---|---|---|---|
| rbtree | 1.704 ± 0.012 | 0.776 ± 0.015 | 0.381 ± 0.003 | 2.20× | 4.47× | 270.7 | 136.3 | 221.5 | 1.99× |
| deriv | 0.995 ± 0.011 | 1.113 ± 0.017 | 0.797 ± 0.018 | 0.89× | 1.25× | 682.1 | 1023.3 | 1275.3 | 0.67× |
| nqueens | 0.623 ± 0.011 | 0.604 ± 0.011 | 0.486 ± 0.015 | 1.03× | 1.28× | 138.6 | 189.8 | 125.1 | 0.73× |
| cfold | 0.166 ± 0.003 | 0.412 ± 0.010 | 0.310 ± 0.012 | 0.40× | 0.53× | 161.6 | 377.1 | 634.7 | 0.43× |
| binary-trees | 13.049 ± 0.105 | 8.303 ± 0.028 | 4.339 ± 0.023 | 1.57× | 3.01× | 274.8 | 137.9 | 221.0 | 1.99× |
| nbody, before | 16.616 ± 0.620 | 1.069 ± 0.001 | 1.742 ± 0.001 | 15.54× | 9.54× | 1.5 | 1.5 | 4.3 | 0.96× |
| nbody, after H5's work | 4.666 ± 0.207 | 1.703 ± 0.055 | | 2.74× | | | | | |
| fannkuch, before | 4.187 ± 0.008 | 1.677 ± 0.006 | 1.559 ± 0.009 | 2.50× | 2.69× | 1.5 | 1.6 | 4.3 | 0.92× |
| fannkuch, after H5's work | 3.331 ± 0.203 | 3.570 ± 0.144 | | 0.93× | | | | | |

After H5's work (H5 has the table), fannkuch is 0.93× Rust and nbody
2.74×, measured in another session, on a loaded machine; the rows
above say "before" for what this verdict was first written on.

**Verdict: fails,** on three of seven for time before H5's work, two
after; memory is within 2× on
all seven, though rbtree and binary-trees are at its edge. deriv,
nqueens and cfold, three of the Perceus set, are as fast as Rust or
faster; cfold is 2.5 times faster, since reuse rebuilds its tree in
place where the Rust allocates a new `Box` per node. binary-trees,
which only allocates and frees, is 1.57×. Each failure has one cause:

- **nbody, 15.5×: a field written into an array rebuilds the
  element.** `bodies[i].vx -= dx * mj` reads the whole 7-Float struct,
  builds a new one with one field changed, and stores it back through
  `ren_array_set_slots_taking`, out of line, which checks uniqueness and
  `memcpy`s the element, its size read from the array's header: 73%
  of the time, six times per pair of bodies. nbody allocates nothing
  (12 objects in all), so this is all copying and calls. **Fix:** a
  field store into a unique array's element in place, `slots[i * 7 +
  3].f -= ...`, with the stride known in a release build, and H5's
  inline fast path and hoisting. **Done** (H5): 2.74× now, of which
  the checks of each `Float` operation for a NaN are 31% of the
  cycles.
- **fannkuch, 2.50×: every array write is a call** to
  `ren_array_set_taking` (68% of the time), as H5 says. **Fix:** H5's.
  **Done:** 0.93× now.
- **rbtree, 2.20×: allocation.** 12 allocations an insertion, since
  reuse is one level deep and the token isn't carried into `balance`
  (H4), a limit of Perceus here, not of the runtime, and each goes to the system `malloc`:
  sampling puts 58% of the time in `malloc`, `free` and the `memset`
  under them. **Fix:** nested reuse and the token carried into `balance` (H4), and a small-object allocator
  with free lists by size, which kklib gets from mimalloc
  (koka/kklib/include/kklib.h:367).
- **Memory, rbtree and binary-trees at 1.99×: the header.** Every
  object's header is 16 bytes, `rc`, `tag`, `kind`, `boxed_elems`,
  `objs` and `nfields`, so a binary-trees node is 32 bytes where Rust's
  is 16. Lean's is 8 bytes (lean.h:174, `lean_object`), and so is
  Koka's (kklib.h:136, `kk_header_t`), which keeps the fields that hold
  objects first and their count in a byte instead of a bit mask.
  **Fix:** an 8-byte header in that layout.

## What would move each bar

In order of what they'd change: tcc or a direct backend for debug
builds, and modules compiled apart and cached (H6); nested reuse with
the token carried into `balance`, a small-object allocator and an
8-byte header (rbtree and memory); a loop's index checks made once
before it, and what `Float`'s NaN checks cost weighed (nbody and inout,
H5); `map` in place. The inline array store, hoisted uniqueness and
in-place field stores are done (H5).

After the merge ("Combined"), what's left: nbody's and inout's checks,
a loop's index checks made once before it and what `Float`'s NaN checks
cost weighed (H5); a packed scalar area for rbtree's two one-word
scalar fields, toward 1.25× Rust's memory; a stackless free walk for
binary-trees, whose time is half freeing; H6's backend and cache; and
for tasks, frozen handler state and a per-thread heap with delayed
frees.

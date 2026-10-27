# Native slice: what the benchmarks measure

The native slice ([compiler.md](../../compiler.md#native-slice),
[foundations.md](../../foundations.md#staging), item 2) was built to put
numbers on the memory and dispatch bet before tasks and many cores
build on it. These are those numbers, H1 to H7, with a verdict for
each: **holds**, **fails**, or **inconclusive**, and for each failure
what the generated C or the `--stats` counts say causes it and what
would fix it. The programs are in this folder ([README.md](README.md));
[vision.md](../../vision.md) says what the bars are.

## Summary

| | Hypothesis | Number | Verdict |
|---|---|---|---|
| H1 | a block costs nothing once specialized | release blocks / loops 0.99× to 1.03×, map 1.12×; allocations equal in both builds | **holds**: map's gap is where the code lands, not what it does (below) |
| H2 | a call to a known handler costs a function call | 0.45 ns against 0.45 ns, release | **holds** |
| H3 | Perceus counts far less than naive, and that shows in time | 12× to 137× fewer dups and drops; 0.40× to 2.20× Rust, naive 0.94× to 6.31× | **holds** |
| H4 | Perceus allocates less and peaks lower | rbtree 3.6× fewer allocations, map over a unique array 1,000×, fannkuch 10 against 2.3 billion; peak equal on rbtree | **holds**, but `map` doesn't reuse its input |
| H5 | `restrict` on `&` parameters helps | 1.00×, 1.00×, 0.99× | **fails** (a null result): nothing it could help is reached through the pointer it marks |
| H6 | debug builds faster than `go build` | 500k lines: 56.7 s against 12.6 s clean; a leaf edit 56.6 s against 0.64 s | **fails**: 77% of it is clang -O0, and Ren has no build cache yet |
| H7 | within 2× of Rust, in time and peak memory | 4 of 7 within 2× in time (0.40× to 1.57×); rbtree 2.20×, fannkuch 2.50×, nbody 15.5×; memory all within 2×, two at 1.99× | **fails** on three programs, each for one cause in the runtime |

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
  nested drop specialization saves are spent here. **Fix:** nested
  reuse, after Koka's ParcReuse.hs.

## H5: `restrict`

The release build with `restrict` on each `&` parameter, and with
`--no-restrict`.

| program | restrict (s) | --no-restrict (s) | without / with | Rust (s) |
|---|---|---|---|---|
| inout | 7.690 ± 0.010 | 7.690 ± 0.014 | 1.00× | 0.879 ± 0.001 |
| fannkuch | 4.187 ± 0.008 | 4.193 ± 0.015 | 1.00× | 1.677 ± 0.006 |
| nbody | 16.616 ± 0.620 | 16.424 ± 0.018 | 0.99× | 1.069 ± 0.001 |

**Verdict: fails, a null result.** `restrict` changes nothing, and
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
the cells. H5 can only be measured again after that.

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
on the cache the build before left.

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

## H7: against Rust and Go

vision.md's set, the release build against Rust and Go: times from
hyperfine, peak resident memory from `/usr/bin/time -l`.

| program | Ren (s) | Rust (s) | Go (s) | Ren / Rust | Ren / Go | Ren MB | Rust MB | Go MB | memory, Ren / Rust |
|---|---|---|---|---|---|---|---|---|---|
| rbtree | 1.704 ± 0.012 | 0.776 ± 0.015 | 0.381 ± 0.003 | 2.20× | 4.47× | 270.7 | 136.3 | 221.5 | 1.99× |
| deriv | 0.995 ± 0.011 | 1.113 ± 0.017 | 0.797 ± 0.018 | 0.89× | 1.25× | 682.1 | 1023.3 | 1275.3 | 0.67× |
| nqueens | 0.623 ± 0.011 | 0.604 ± 0.011 | 0.486 ± 0.015 | 1.03× | 1.28× | 138.6 | 189.8 | 125.1 | 0.73× |
| cfold | 0.166 ± 0.003 | 0.412 ± 0.010 | 0.310 ± 0.012 | 0.40× | 0.53× | 161.6 | 377.1 | 634.7 | 0.43× |
| binary-trees | 13.049 ± 0.105 | 8.303 ± 0.028 | 4.339 ± 0.023 | 1.57× | 3.01× | 274.8 | 137.9 | 221.0 | 1.99× |
| nbody | 16.616 ± 0.620 | 1.069 ± 0.001 | 1.742 ± 0.001 | 15.54× | 9.54× | 1.5 | 1.5 | 4.3 | 0.96× |
| fannkuch | 4.187 ± 0.008 | 1.677 ± 0.006 | 1.559 ± 0.009 | 2.50× | 2.69× | 1.5 | 1.6 | 4.3 | 0.92× |

**Verdict: fails,** on three of seven for time; memory is within 2× on
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
  inline fast path and hoisting.
- **fannkuch, 2.50×: every array write is a call** to
  `ren_array_set_taking` (68% of the time), as H5 says. **Fix:** H5's.
- **rbtree, 2.20×: allocation.** 12 allocations an insertion, since
  reuse is one level deep (H4), and each goes to the system `malloc`:
  sampling puts 58% of the time in `malloc`, `free` and the `memset`
  under them. **Fix:** nested reuse (H4), and a small-object allocator
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

In order of what they'd change: the inline array store with hoisted
uniqueness and in-place field stores (nbody, fannkuch, and H5's
re-measure); tcc or a direct backend for debug builds, and modules
compiled apart and cached (H6); nested reuse, a small-object allocator
and an 8-byte header (rbtree and memory); `map` in place.

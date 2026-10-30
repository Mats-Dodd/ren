# Native slice: what the benchmarks measure

The native slice ([compiler.md](../../compiler.md#native-slice),
[foundations.md](../../foundations.md#staging), item 2) was built to put
numbers on the memory and dispatch bet before tasks and many cores
build on it. These are those numbers, H1 to H7, with a verdict for
each: **holds**, **fails**, or **inconclusive**, and for each failure
what the generated C or the `--stats` counts say causes it and what
would fix it. The programs are in this folder ([README.md](README.md));
[vision.md](../../vision.md) says what the bars are.

## Bytes stage, part two: the baseline (briefs/stage-bytes-2.md, step 0)

Where Ren's strings stand before part two: representation A, `+` and
`+=` absent (`concat`, which copies both sides), `ren_utf8_valid` a
byte at a time. bench/native/strs ports research/strings/track-b's
workloads to Ren, each with a Rust and a Go twin, over the same inputs:
gen.ren makes, byte for byte, what track-b/c/gen.c writes (the Rust
twin's `dump` writes its files, and `cmp` finds them the same as gen.c's,
built with clang, and as b5.c's texts). Every Ren, Rust and Go run of a
workload printed the same check (measure.py stops if one doesn't), and
main.ren's debug and release builds print what the twins do; tok's 1,030,229 tokens, map's 132,499
keys, group's 1,996 cities and out's 105 MB of JSON and 133 MB of
logfmt are the research's.

**The machine:** an x86_64 cloud container, 4 cores, shared (an Intel
Xeon at 2.10 GHz under KVM, 15 GiB, Linux 6.18.44); **numbers are for
ratios; the owner re-measures on the M4 Max.** `ren build --release`
compiles with `cc`, which is GCC 13.3.0 here (Apple clang on the M4
Max), at -O2; rustc 1.97.0 (`-C opt-level=3 -C codegen-units=1`), go
1.24.7; the compiler at 78b28ec. There are no cycle counters here
(`perf_event_open` of cycles fails; no `perf`), so these are **wall
times**, from just before a process starts to just after it's reaped,
and peak RSS from `wait4`. Each workload runs at R rounds and at 0, a
round is (median at R - median at 0) / R, and the spread is the R-round
runs' least and most; seven runs, every build interleaved and the order
rotated each run; load 1.1 to 2.4. The 0-round runs make the input in
the program (a native build can't read a file yet), up to 1.8 s for
logs, so a round of a short kernel carries that run's noise too.

```sh
sh bench/native/strs/build.sh $out    # every kernel at R and 0, plain and -DREN_RC_SHARED, the twins
# the main session: every row but the 50,000-record ones
SHARED=1 KERNELS=tok,sort,map,group,logs,json_append_5k,json_plus_5k,logfmt_append_5k,logfmt_plus_5k,json_1m,logfmt_1m,utf8_ascii,utf8_cjk,utf8_mixed,slices_logs,slices_logs_r,slices_json,slices_json_r,slices_pages,slices_pages_r,maps \
  python3 -I bench/native/strs/measure.py $out 7 main.jsonl
KERNELS=json_append_50k,json_plus_50k,logfmt_append_50k,logfmt_plus_50k \
  python3 -I bench/native/strs/measure.py $out 3 q50k.jsonl
# the inputs against gen.c's (track-b/gen.sh's data/)
$out/strs-rust dump 1000000 dir && for f in tok.txt keys.txt sort.txt rows.csv logs.txt people.csv; do cmp dir/$f data/$f; done
# the twins against `ren run small.ren`, and main.ren's release build
cd bench/native/strs && ren run small.ren | diff - <(python3 -I agree.py $out/strs-rust 200 10 2)
ren build main.ren --release -o m && ./m | diff - <(python3 -I agree.py $out/strs-go 1000000 5000 1)
```

`kernels` lists each workload's call, its R and its twins' arguments;
`KERNELS=` narrows build.sh and measure.py to some of them.

**The research's workloads** (track-b's B1 and B4), ms a round, the
R-round runs' spread in brackets, peak RSS in MiB:

| workload | R | Ren | Rust, FxHash | Rust, std | Go | Ren / Rust (Fx) | Ren / Rust (std) | RSS, Ren / Rust / Go | the research's A / Rust |
|---|---|---|---|---|---|---|---|---|---|
| tok | 10 | 37.4 (450-502) | 25.3 (253-308) | | 89.8 (951-1328) | 1.48× | | 68.5 / 31.5 / 118 | 1.22× |
| sort | 5 | 737.5 (3891-4428) | 156.9 (901-1031) | | 306.9 (1951-2327) | 4.70× | | 113 / 38.8 / 92.7 | 2.33× |
| map | 5 | 1110 (6137-7552) | 652.4 (3376-3733) | 886.8 (4419-4778) | 514.3 (3467-3980) | 1.70× | 1.25× | 207 / 103 / 412 | 1.08× (Fx), 0.76× (std) |
| group | 5 | 475.9 (3393-3860) | 413.7 (2365-2719) | 461.4 (2498-2768) | 228.6 (2729-3025) | 1.15× | 1.03× | 194 / 112 / 496 | 0.92× (Fx), 0.78× (std) |
| logs | 5 | 341.3 (3288-3631) | 238.6 (1434-1574) | | 624.9 (3977-5147) | 1.43× | | 400 / 198 / 697 | 1.31× |

The Rust keeps `&str`s of the input (the research's fastest Rust,
which needs a lifetime) and sorts with `sort_unstable`; its maps are
std's `HashMap` with FxHash (rustc-hash 1's, written in main.rs) or
std's SipHash, counting with `entry`; Go keeps substrings, `sort.Strings`
and `map[string]int64`. Ren's map counts with a `get` and a `set`, two
probes where Rust's `entry` makes one, since Ren has no entry API, and
keeps each key a 32-byte slice object, as A does; its sort is
`Array.sort`, the runtime's stable merge sort, comparing through the
order's descriptor (ren_rt.c, [ren_array_sort]). The last column
is the research's C model of A against Rust `&str` (B1's session 1) or
Rust's Fx and std (B4) on the M4 Max: Ren today is slower than that
model of itself on every workload, by most on sort.

**Building output** (B3's json and logs), ms a round. `_append`
appends one piece at a time (what `+=` will write); `_plus` adds each
record's pieces in one expression (what `a + b` will). Both are
`concat` today and copy the whole string each time. The Rust appends
with `String::push_str` and `write!`, the Go with a `strings.Builder`
and `strconv.AppendInt`; neither has a quadratic form to run.

| records | Ren json, append | Ren json, plus | Ren logfmt, append | Ren logfmt, plus | Rust json | Rust logfmt | Go json | Go logfmt |
|---|---|---|---|---|---|---|---|---|
| 5,000 | 771.3 (3786-4087 for 5) | 477.7 (2342-2454) | 903.5 (4325-4873) | 913.8 (4358-4787) | 0.90 | 0.55 | 2.35 | 3.12 |
| 50,000 | 304,990 (303,708-305,858 for 1) | 192,705 (190,004-195,135) | 307,890 (307,936-314,728) | 310,803 (305,766-312,307) | 12.5 (38-48 for 1) | 4.8 (39-40) | 38.1 | 54.3 |
| 1,000,000 | | | | | 188.9 (1455-1572 for 5) | 142.2 (1192-1332) | 502.7 | 602.6 |

At 5,000 records Ren takes 860× Rust's time on json and 1,640× on
logfmt; 50,000 records take 395× (json, append), 403× (json, plus),
341× and 340× (logfmt) what 5,000 do: ten times the records, a hundred
times the bytes copied, and four times more again, since the string
outgrows the caches (5,000 records' output is 260 to 470 KB, 50,000's
2.6 to 4.7 MB). Ren at 1M records (105 and 133 MB) would take days and
isn't run; at 50,000 a run takes five minutes, so that row is three
runs, not seven, in a session of its own (the 5,000 and 1M rows are the
main session's seven). The twins' 50,000 rows are a difference of runs
of 30 to 190 ms, so only their order of magnitude means anything.
json's plus form is faster than its append form because a record's
escaped strings are built apart and appended once each, so it copies
the whole output fewer times.

**`Str.from_utf8`** of a 1 MiB text (B5's texts, 4,000 validations a
run), GB/s:

| text | Ren | Rust std | Go | the research, Ren today on the M4 Max |
|---|---|---|---|---|
| ascii | 1.64 | 36.75 | 12.32 | 2.61 |
| cjk | 0.84 | 0.90 | 0.63 | 1.09 |
| mixed (2% non-ASCII) | 1.17 | 1.92 | 1.19 | 1.71 |

Rust's std validator skips ASCII a word at a time, which is its 36 GB/s
here; step 1's target is the research's NEON numbers (73.1, 9.01 and
13.5 on the M4 Max), which this machine can't run (no NEON).

**The slices kernels** (bench/native/slices, "Slices" above), each
alone at 200,000 for 20 rounds and for 0, ms a pass:

| kernel | Ren slices | Ren offsets (`_r`) | slices / `_r` | Rust slices | Rust `_r` | Go slices | Go `_r` | Ren / Rust, slices | Ren / Rust, `_r` |
|---|---|---|---|---|---|---|---|---|---|
| logs | 24.4 (530-617) | 15.5 (372-475) | 1.58× | 11.4 | 17.2 | 15.7 | 15.6 | 2.14× | 0.90× |
| json | 118.6 (1961-2558) | 70.1 (1427-1620) | 1.69× | 62.1 | 32.9 | 252.0 | 149.0 | 1.91× | 2.13× |
| pages | 8.01 (304-389) | 3.90 (209-278) | 2.05× | 2.14 | 1.66 | 23.1 | 4.61 | 3.74× | 2.35× |

Step 4's targets are against these: json and pages within 1.2× of `_r`
and logs within 1.1× (today 1.69×, 2.05× and 1.58×), and every kernel
within 2× of Rust (today logs and pages with slices, and json and pages
with offsets, miss it).

**The `Map` claim** (scope 7): bench/native/maps, 20 rounds and 0, ms a
round; maps' Rust twin as it was (std's SipHash) and again with FxHash
(maps/rust/fx.rs, the same program with the hasher swapped):

| | Ren | Rust, std | Rust, FxHash | Go | Ren / Rust std | Ren / Rust Fx |
|---|---|---|---|---|---|---|
| maps | 64.6 (1212-1479) | 98.0 (1714-2425) | 65.3 (1186-1565) | 148.6 (2569-3581) | 0.66× | **0.99×** |

compiler.md's 0.69× (the M4 Max, against SipHash) holds here as 0.66×,
and against FxHash Ren's map runs at Rust's speed, 0.99×, not faster;
the research put it at 1.02 to 1.05×. On the research's `Map<Str,
Int>` workload (map above) Ren is 1.25× Rust's std and 1.70× its
FxHash, two probes an update and a slice object a key included.

**`-DREN_RC_SHARED`, uncontended** (decision 10's hot-root trap; brief,
"Risks"): every Ren kernel built again with the C compiled
-DREN_RC_SHARED, one thread, the same session, ms a round:

| kernel | plain | -DREN_RC_SHARED | shared / plain | second session, 11 runs: plain, shared, ratio |
|---|---|---|---|---|
| tok | 37.4 | 41.1 | 1.10 | 47.1, 48.9, 1.04 |
| sort | 737.5 | 778.4 | 1.06 | 873.7, 950.5, 1.09 |
| map | 1110 | 1106 | 1.00 | 1280, 1271, 0.99 |
| group | 475.9 | 424.8 | 0.89 | 466.7, 423.6, 0.91 |
| logs | 341.3 | 281.7 | 0.83 | 356.9, 299.9, 0.84 |
| out json, 5,000, append | 771.3 | 784.7 | 1.02 | |
| out json, 5,000, plus | 477.7 | 477.1 | 1.00 | |
| out logfmt, 5,000, append | 903.5 | 895.6 | 0.99 | |
| out logfmt, 5,000, plus | 913.8 | 904.3 | 0.99 | |
| utf8 ascii / cjk / mixed | 0.64 / 1.25 / 0.90 | 0.62 / 1.27 / 0.93 | 0.97 / 1.02 / 1.03 | |
| slices logs | 24.4 | 26.2 | 1.07 | 26.4, 27.4, 1.04 |
| slices logs_r | 15.5 | 17.0 | 1.10 | 16.5, 18.3, 1.11 |
| slices json | 118.6 | 120.2 | 1.01 | 126.3, 126.4, 1.00 |
| slices json_r | 70.1 | 71.7 | 1.02 | 79.3, 76.3, 0.96 |
| slices pages | 8.01 | 8.05 | 1.00 | 8.79, 10.13, 1.15 |
| slices pages_r | 3.90 | 3.80 | 0.97 | 4.38, 4.18, 0.95 |
| maps | 64.6 | 67.4 | 1.04 | 76.0, 82.2, 1.08 |

The second session ran at load 2 to 4.5, so its absolute times are
higher:

```sh
SHARED=1 WHO=ren KERNELS=tok,sort,map,group,logs,slices_logs,slices_logs_r,slices_json,slices_json_r,slices_pages,slices_pages_r,maps \
  python3 -I bench/native/strs/measure.py $out 11 shared.jsonl
```

The shared mode's hot paths are the plain mode's (ren_rt.h, "Counting
has three modes"), and on one thread its counts are positive, so this
is the cost of the relaxed loads and the thread-local heap: up to 10%
(tok, sort, slices logs and logs_r, maps), within noise elsewhere, and
group and logs 9 to 17% faster in both sessions, which nothing here
explains (their rounds are the difference of 3 to 4 s runs whose input
takes 1.4 to 1.9 s to make). The research's C model found no cost it
could measure. The contended case, many tasks counting one root, waits
for 11b.

## The data stage: the milestone (compiler.md, "Data stage", "The layout fixes (step 7)")

The milestone: dispatch's `interp` kernel, research/dispatch.md's
expression tree, written ADT-first (`interp/bench.ren`: `Expr` a sum
type of eight constructors, the binary ones by name, and `eval` a
`match`), against its Rust twin, dispatch's `rust/main.rs` run as `100
interp enum` (`Expr` an enum of `Box`es, `eval` a `match`), and beside
the descriptions: Rust's `interp dyn` and dispatch's Ren `interp`
(build.sh's `dispatch-interp`, `dep Node`). The same work in each: one
tree of depth 17 from seed 1 (about 1,200 nodes), 25,600 evaluations, each
with a fresh four-element environment; every one prints -326745600, as
`ren run main.ren` does (16.5 s), and at the small size 105, which
native.t checks against `ren run small.ren`.

**The machine is the cloud container of "Data stage: layout" below**,
not the M4 Max of the older sections: an Intel Xeon at 2.10 GHz, 4
vCPUs under KVM, 15 GiB, Linux 6.18.44, GCC 13.3 (`cc`, which `ren
build` runs), rustc 1.97.0, go 1.24.7, hyperfine 2.0.0. **These numbers
are for comparison only; the owner re-measures on the M4 Max.** Runs
here drift by 15 to 25% from one to the next (each kernel's σ below),
so the instruction counts, from valgrind's cachegrind, are the steady
measure; times are one hyperfine run of all six (`-N --warmup 5 --runs
100`), release builds, in ms:

| build | mean | median | min | instructions | mean / Rust enum | mean / Rust dyn |
|---|---|---|---|---|---|---|
| Ren, ADT (`interp-perceus`) | 163.5 ± 20.4 | 164.7 | 97.8 | 886.2 M | **1.13×** | 2.90× |
| Rust, `interp enum` | 144.5 ± 12.6 | 144.9 | 99.8 | 870.6 M | 1.00× | 2.56× |
| Rust, `interp dyn` | 56.4 ± 11.9 | 52.4 | 40.4 | 430.2 M | 0.39× | 1.00× |
| Ren, descriptions (`dispatch-interp-perceus`) | 101.9 ± 22.0 | 94.4 | 69.8 | 985.7 M | 0.70× | **1.81×** |
| Ren, ADT at 213b4a9 | 140.0 ± 20.6 | 142.6 | 87.4 | 965.0 M | 0.97× | 2.48× |
| Go, `interp` (an interface) | 87.6 ± 20.5 | 81.2 | 60.8 | | 0.61× | 1.55× |

**The ADT kernel is within 1.13× of its Rust twin** (1.14× by
medians), on 2% more instructions: both are one function whose `match`
is a jump table through the node's tag, and both are bound by that one
indirect jump, which the predictor can't learn across a random tree.
Each description's `eval`, Ren's and Rust's `dyn`, calls its children
through their code pointers from the arm it's in, eight call sites the
predictor tells apart, so both run faster than either `match` on as
many instructions or more: Ren's descriptions 0.62× the ADT's time on
11% more, Rust's `dyn` 0.39× its enum's on half. That's what the
dispatch table above found on the M4 too (Rust's enum 1.52× its `dyn`
there, 2.56× here), so the ADT kernel is 1.6× slower than the
descriptions version on this machine, not faster: `Expr` written as a
sum is the program the docs teach (step 6), and its cost is Rust's for
the same program.

**The one change, a tag read with no scalar test.** A boxed sum all of
whose constructors have fields is never a scalar, so its tag is its
header's: `((int64_t)e->tag)`, not `ren_tag(e)`, which tested the
pointer's low bit first (Mem's `Obj_tag`; compiler.md, step 7's
choices, part 4). `eval` loses a test and a branch a node: 965.0 to
886.2 million instructions (0.92×), 109 to 78 million conditional
branches. Its time, though, moves with code layout more than with its
instructions, both ways: with GCC's default layout it's 1.06 to 1.18×
the time at 213b4a9 in six runs (1.17× in the table's); built from the
same C with `-Wa,-mbranches-within-32B-boundaries` it's 0.78× (145 ms
against 186), and with clang 18 at -O2 0.94× (141 ms against 150, in
two runs), so the default layout's slowdown is where GCC puts the jump
table's targets, not the change. Two programs of the suite read such a
tag, and run faster in two hyperfine runs each (`-N --warmup 3 --runs
20`), the same output:

| program | instructions, 213b4a9 | after | time (ms), 213b4a9 | after | after / before |
|---|---|---|---|---|---|
| deriv | 8,029 M | 7,482 M | 1379 ± 54, 1417 ± 88 | 1264 ± 52, 1279 ± 70 | 0.92×, 0.90× |
| cfold | 789.1 M | 747.1 M | 199 ± 14, 213 ± 16 | 186 ± 17, 193 ± 12 | 0.93×, 0.91× |

No other program or kernel of the suite compiles to different C (each
`main.ren`, bench/data's and bench/10d's programs, both countings,
compared as for the layout fixes); of bench/data, interp, shapes,
variants and variants_reuse do, and of bench/10d, overany and
review_deps, each only in that read.

**What's left in `eval`'s C,** each measured by editing the generated C
by hand and counting instructions (none of these is built):

| removed | instructions | against the built 886.2 M |
|---|---|---|
| `REN_STACK_CHECK()` at each call | 669.4 M | 0.76× |
| the switch's default arm, the `match`'s "no arm matched" panic, as `__builtin_unreachable()` | 824.3 M | 0.93× |
| `env[i]`'s bounds check | 871.5 M | 0.98× |
| `+` and `-` checked, as wrapping | 1,016.0 M | 1.15× (GCC lays the wrapping version out worse) |
| all four | 731.9 M | 0.83× |

The stack check, checked arithmetic and the bounds check are the
language's semantics (decision 15: an overflow, of the stack or of an
`Int`, panics where it happens), so they stay; the stack check costs
most because `__builtin_frame_address(0)` makes GCC keep a frame
pointer, so it's seven instructions a call where the compare alone is
three. The default arm is unreachable, since a value of a sum
has one of its tags and the switch has a case for each, but making it
`__builtin_unreachable()` turns a compiler fault into undefined
behaviour where it's a panic today, for 7% of the instructions and no
time this machine can see; not done. The evidence `eval` is passed and
doesn't use costs nothing (GCC drops it, `ren_bench_eval_1.isra.0`).
Ren allocates each evaluation's environment, 25,600 of the 26,812
allocations (`--stats`), where Rust's is on the stack: one allocation
for about 1,200 nodes evaluated, nothing to see.

**How**, from the repository, `$S` a scratch folder:

    sh bench/native/build.sh $S/bench        # interp-perceus, dispatch-interp-perceus, dispatch-rust, dispatch-go
    sh bench/native/measure.sh $S/bench $S/res machine stats time
    python3 -I bench/native/summarize.py $S/res     # the last table: the milestone's ratios
    # or alone, as above:
    hyperfine -N --warmup 5 --runs 100 -n ren-adt $S/bench/interp-perceus \
      -n rust-enum "$S/bench/dispatch-rust 100 interp enum" \
      -n rust-dyn "$S/bench/dispatch-rust 100 interp dyn" \
      -n ren-descriptions $S/bench/dispatch-interp-perceus \
      -n go "$S/bench/dispatch-go 100 interp"
    valgrind --tool=cachegrind --cache-sim=no --cachegrind-out-file=/dev/null $S/bench/interp-perceus   # "I refs"
    (cd bench/native/interp && ren run small.ren && ren run main.ren)   # 105; -326745600
    # the change against 213b4a9: build each compiler, then each program with each
    # (`ren build main.ren --release`), and time them in one run as above; the
    # layout check builds `ren build main.ren --release --emit-c`'s C with
    # cc -O2 -ffp-contract=off -Wa,-mbranches-within-32B-boundaries ... -lm -lpthread

## Data stage: layout (compiler.md, "Data stage", "The layout fixes (step 7)")

The data stage's three layout faults, each measured before its fix and
after it, on the kernel bench/data has for it and on this folder's
suite. **The machine isn't the M4 Max of the sections below:** a cloud
container, an Intel Xeon at 2.10 GHz, 4 vCPUs under KVM, 15 GiB, Linux
6.18.44, GCC 13.3, rustc 1.97.0, go 1.24.7, hyperfine 2.0.0, load
average under 1. Its numbers are for before and after only; whole runs
drift by up to 15% between hours (the Rust and Go twins, which don't
change, moved 0.83× to 1.17× from one run of the suite to the next).

**Before, at 8c7c65c, all three faults.** Release builds, 100,000 items
each; allocations from `--stats`, peak resident memory from GNU time,
time hyperfine's (`-N --warmup 5 --runs 50`, the kernels in one run),
mostly the process starting:

| kernel | the fault | allocations | peak RSS | time (ms) |
|---|---|---|---|---|
| nested | a small record in a small variant, `Draft(u: Unvalidated)` | 66,671 | 2.1 MB | 2.60 ± 0.36 |
| rows | an array of records holding a `Str`, `Array<Line>` | 100,006 | 5.8 MB | 6.25 ± 1.36 |
| optional | an `Option` of a record holding a `Str`, `Option<Item>` | 101,004 | 2.1 MB | 3.25 ± 0.50 |

nested's last line printed an `Item` when step 0 wrote it, and `show`
boxes a small value's type program-wide (compiler.md, "Small values are
values"), which boxed `Unvalidated` too: 200,005 allocations, whatever
the layout. It prints the total now (compiler.md, step 7's choices).
rows' and optional's last lines `show` a `Line` and an `Option<Item>`
the same way.

**The first fix: a small record or tuple in a small value is flattened
into its slots.** `Item` is a tag and `Unvalidated`'s two slots, and a
`Draft` allocates nothing:

| kernel | allocations, 8c7c65c | after | time (ms), 8c7c65c | after |
|---|---|---|---|---|
| nested | 66,671 | **4** | 2.47 ± 0.53 | 1.71 ± 0.42 |
| nested, 100 times the items | 6,666,671 | **4** | 64.2 ± 8.7 | **17.0 ± 4.5** |
| rows | 100,006 | 100,006 | | |
| optional | 101,004 | 101,004 | | |

Each pair of times is one hyperfine run of both binaries (200 runs for
nested, 20 for the copy with a loop of 10 million, built from nested.ren
by changing its count). Peak memory doesn't move (2.1 MB); rows and
optional wait for the second and third fixes.

**The suite**, every kernel measure.sh times, before and after, in two
runs about two hours apart. Of its 49 programs and kernels, only three
compile to different C, through the fix to reuse's sizes that the
layout tests needed (compiler.md, step 7's choices), not the layout:
deriv reuses 9.7 million objects, not 4.5 million, and allocates 31.4
million, not 36.6 million; rbtree drops a reset in its `Leaf` arm that
never ran; cfold's drops move. In one hyperfine run of before and after
(`-N --warmup 3 --runs 20`): deriv 1.440 ± 0.096 s to 1.381 ± 0.088 s,
rbtree 1.333 ± 0.105 to 1.371 ± 0.142, cfold 0.214 ± 0.017 to 0.212 ±
0.020, so no regression. The rest of the suite is the same C, so its
changes between the two runs, 0.82× to 1.05×, are the machine's, as the
twins' are; peak memory is the same to 0.1 MB for every Ren build.

| program | build | 8c7c65c (s) | after (s) | after / before |
|---|---|---|---|---|
| rbtree | perceus | 1.335 ± 0.150 | 1.250 ± 0.134 | 0.94× |
| deriv | perceus | 1.388 ± 0.102 | 1.364 ± 0.073 | 0.98× |
| nqueens | perceus | 1.072 ± 0.093 | 1.007 ± 0.059 | 0.94× |
| cfold | perceus | 0.213 ± 0.024 | 0.195 ± 0.020 | 0.91× |
| binary-trees | perceus | 13.245 ± 0.546 | 12.283 ± 0.374 | 0.93× |
| nbody | perceus | 3.842 ± 0.238 | 3.700 ± 0.234 | 0.96× |
| fannkuch | perceus | 2.788 ± 0.189 | 2.869 ± 0.137 | 1.03× |
| inout | perceus | 3.022 ± 0.298 | 2.762 ± 0.338 | 0.91× |
| nested | perceus | 1.754 ± 0.237 | 1.543 ± 0.096 | 0.88× |
| dispatch interp | perceus | 0.117 ± 0.031 | 0.110 ± 0.032 | 0.93× |

**The second fix: an array of small values that hold objects keeps them
inline,** counted by the mask of their slots that hold objects, which
the array's header keeps in its `objs` byte, instead of boxing their
type program-wide. Against d86b474, the first fix's commit, in one
hyperfine run of both binaries each (`-N`; 200 runs for rows, 20 for
the copy of it with 100 times the items, built from rows.ren by
changing its count), release:

| kernel | allocations, d86b474 | after | peak RSS, d86b474 | after | time (ms), d86b474 | after |
|---|---|---|---|---|---|---|
| rows | 100,006 | **6** | 6.1 MB | 3.8 MB | 6.41 ± 0.90 | **3.50 ± 1.51** |
| rows, 100 times the items | 10,000,006 | **6** | 402 MB | 162 MB | 445.6 ± 35.9 | **186.7 ± 29.1** |

rows.ren's last line printed `ls[4]`, whose `show` boxes `Line`
whatever the layout (100,006 allocations at d86b474 and after); it
prints the element's fields now, `bb` and `4` (compiler.md, step 7's
choices). What's left is the array and its growth: 17 doublings,
`Line` two words inline, `{ sku, qty }`, the `Str` counted by the mask
`0b01`.

**The suite, second fix.** Of its programs and kernels, only `slices`
compiles to different C, and `nbody` in one argument, the mask 0 of an
array of uncounted structs: slices' `json` and `pages` tokens, an `Int`
and a slice or two slices, are inline in their arrays now. Each against
d86b474 in one hyperfine run (`-N --warmup 2`, 10 runs, 40 for the
pages kernels, whose runs vary most), release, the same output:

| program | allocations, d86b474 | after | peak RSS MB, d86b474 | after | time (s), d86b474 | after | after / before |
|---|---|---|---|---|---|---|---|
| slices (main.ren) | 164,220,000 | 96,149,400 | 381.6 | 305.6 | 6.701 ± 0.200 | 5.881 ± 0.280 | 0.88× |
| slices, `json` kernel | 127,999,826 | 63,999,926 | 245.0 | 193.6 | 3.384 ± 0.133 | 2.644 ± 0.084 | 0.78× |
| slices, `pages` kernel | 12,220,125 | 8,149,425 | 149.5 | 149.5 | 0.371 ± 0.053 | 0.342 ± 0.048 | 0.92× |
| slices, `json_r` | 26 | 26 | 108.7 | 108.7 | 1.900 ± 0.127 | 1.652 ± 0.071 | 0.87× |
| slices, `pages_r` | 8,025 | 8,025 | 149.5 | 149.3 | 0.259 ± 0.045 | 0.248 ± 0.031 | 0.96× |
| nbody | 12 | 12 | 3.5 | 3.5 | 3.869 ± 0.329 | 3.678 ± 0.241 | 0.95× |

The offsets kernels, `json_r` and `pages_r`, and nbody run the same
code as before in their loops (their C differs in functions they don't
call, or in the mask alone), so their ratios are this machine's noise.
A first build pushed a struct's words through an out-of-line call that
copied them with a `memcpy` of the stride the array keeps, and `pages`
ran 7% slower than at d86b474 on 3% fewer instructions (cachegrind):
the push of a struct whose size the compiler knows is inline now
(`ren_array_push_slots_taking_k`), its words stores, and `pages` is
0.92×. The rest of the suite is the same C as at d86b474.

**The third fix: a byte tag, and pointer niches.** A sum with one
constructor that has fields, one an object, and the rest without has no
tag: the object's slot holds `ren_box(UINT32_MAX - t)` for constructor
`t` without fields. Any other sum's tag is the low byte of slot 0, its
constructors' small scalars packed above it. `Option<Item>` is two
words, `{ name, price }`, where it was a tag and two slots. optional.ren's
last line printed `best`, whose `show` boxes `Option<Item>` and so
`Item`, 101,004 allocations at 7c68889 and after; it prints `best`'s
fields now, `tea` and `7` (compiler.md, step 7's choices), and with that
change alone it allocates 4 at 7c68889 too, the option a tag and two
slots: the second word is what this fix saves. Against 7c68889, the
second fix's commit, all in one hyperfine run (`-N --warmup 5 --runs
50`), release, with instructions from valgrind's lackey, which this
machine (no perf) counts steadily where its times drift; the copy with
100 times the items is optional.ren with its count changed, and the
array holds a million options, half `None`, read ten times:

| kernel | allocations, 7c68889 | after | peak RSS, 7c68889 | after | instructions, 7c68889 | after | time (ms), 7c68889 | after |
|---|---|---|---|---|---|---|---|---|
| optional | 4 | 4 | 2.1 MB | 2.1 MB | 4.40 M | 4.30 M | 2.05 ± 0.32 | 2.30 ± 0.71 |
| optional, 100 times the items | 4 | 4 | 2.1 MB | 2.1 MB | 411.2 M | **401.4 M** | 29.2 ± 6.9 | 31.8 ± 8.1 |
| `Array<Option<Item>>`, a million | 4 | 4 | 25.2 MB | **17.6 MB** | 308.9 M | **256.4 M** | 45.7 ± 8.1 | **36.6 ± 5.8** |
| optional as step 0 wrote it, `print(best)` | 101,004 | 101,004 | 2.1 MB | 2.1 MB | 12.53 M | 12.53 M | | |

The first two runs' times are within this machine's noise of each other
(their minimums, 1.56 and 1.45 ms, 19.6 and 19.5 ms, agree), on 2% fewer
instructions: a variable's option is a word less to copy, and the match
compares a pointer where it read a tag. An array of them is a third
smaller, 16.8 MB of elements, not 25.2, and reading it 0.80× as long.

**The suite, third fix.** No program or kernel of the suite compiles to
different C: none keeps a sum that's a small value and has a niche or a
scalar to pack beside its tag (the C of every program and kernel
build.sh builds, both countings, compared as for the second fix). A sum
with nothing packed beside its tag keeps the whole word, read without a
mask, so `stack`'s `Option<Int>` is as it was. Nothing in it to time.

**How.** `$S` is a scratch folder, `ren` the compiler at each commit
copied there before building the next:

    sh bench/native/build.sh $S/bench-before          # REN=$S/before/ren
    REN=$S/before/ren sh bench/native/measure.sh $S/bench-before $S/res-before machine stats time memory
    sh bench/native/build.sh $S/bench-after           # REN=$S/after/ren
    REN=$S/after/ren sh bench/native/measure.sh $S/bench-after $S/res-after machine stats time memory
    python3 -I bench/native/summarize.py $S/res-after
    # the kernels, from bench/data, each binary built both ways
    ren build --release nested.ren -o nested
    ren build --release --stats nested.ren -o nested-stats && ./nested-stats
    /usr/bin/time -v ./nested        # peak RSS
    hyperfine -N --warmup 5 --runs 200 -n before $S/before/nested -n after $S/after/nested
    # the second fix: rows the same way; which programs' C changed, from
    # the C of every program and kernel build.sh builds, both countings,
    # emitted by each compiler (`ren build main.ren --release --emit-c`,
    # the part after `---- the program ----`) and compared; then each
    # program whose C changed timed against d86b474 in one run
    hyperfine -N --warmup 2 --runs 10 -n before $S/before/slices -n after $S/after/slices
    # the third fix: optional the same way, and its two copies, in one run
    sed 's/for k in 0..100000/for k in 0..10000000/' optional.ren > optional_big.ren
    hyperfine -N --warmup 5 --runs 50 -n optional-before $S/before/optional -n optional-after $S/after/optional ...
    valgrind --tool=lackey --basic-counts=yes ./optional     # "guest instrs"

The array of options, `optional_array.ren` above:

    type Item = { name: Str, price: Int }

    fn main() uses Console =
      let names = ["tea", "jam", "cake"]
      var os: Array<Option<Item>> = []
      for k in 0..1000000
        let price = k * 7919 % 1000
        &os.push(if price < 500 then Some(Item { name: names[k % 3], price }) else None)
      var t = 0
      for round in 0..10
        for o in os
          match o
            Some(i) => t += i.price + i.name.len() + round
            None => t += 1
      print(t)

measure.sh's whole run took 67 minutes here. build.sh stopped at the
dispatch kernels at 8c7c65c (step 6 renamed `shapesK` to `codecsK`), and
measure.sh's peak memory needed BSD time's `-l`: both are fixed.

## Dispatch (foundations.md, decision 4; compiler.md, "Dispatch (step 4)")

`dispatch`'s kernels, each alone at main.ren's size (build.sh's
`dispatch-<kernel>`), release, against 678bbf7 in the same run, and
against Rust's `dyn` and enum twins and Go's. Hyperfine, 10 runs, in ms;
cycles from `/usr/bin/time -l`.

| kernel | 678bbf7 | after | Rust dyn | Rust enum | Go | after / Rust dyn | cycles 10⁶, before / after |
|---|---|---|---|---|---|---|---|
| shapes2 | 49.1 ± 0.6 | **30.2 ± 0.5** | 29.5 | 19.3 | 33.4 | 1.02× | 188 / 117 |
| shapes4 | 62.8 ± 0.7 | **38.2 ± 1.0** | 38.4 | 28.2 | 43.5 | 0.99× | 239 / 149 |
| shapes8 | 70.1 ± 0.8 | **46.4 ± 0.3** | 42.4 | 40.7 | 48.7 | 1.09× | 271 / 178 |
| shapes32 | 74.5 ± 1.0 | **50.4 ± 0.3** | 45.0 | 48.6 | 53.0 | 1.12× | 291 / 195 |
| db | 230.9 ± 0.7 | **87.3 ± 4.2** | 84.3 | 57.1 | 125.5 | 1.04× | 906 / 346 |
| router | 81.6 ± 0.8 | **56.6 ± 0.4** | 56.2 | 62.4 | 64.8 | 1.01× | 317 / 221 |
| interp | 127.3 ± 0.6 | **60.2 ± 0.7** | 39.4 | 60.0 | 57.5 | 1.53× | 496 / 237 |

shapes2 and shapes4 copy no loop (the array's element changes each
step) and compare the tag; shapes8, shapes32 and router call through
the tag, the method's address; db's loop is copied for each of its four
handlers; interp's `eval` calls through the tag too, recursion through
`Node`. The other programs
didn't move: handlers, blocks, rbtree, deriv, nbody and stack are within
1% in cycles.

## Bytes stage: the baseline (compiler.md, "Bytes stage")

Where Ren's offset-based byte code spends its cycles against Rust's, on
the slices benchmark's `_r` kernels and on `bytes`, before any of the
bytes stage's fixes (at b171b76's compiler). The owner's M4 Max, macOS
15.1, Apple clang 16.0.0, rustc 1.99.1, Go 1.27.3, nothing else
building. Each `_r` kernel runs 20 times on its input and again 0
times, and a pass is the difference over 20; ten runs, Ren, Rust and Go
interleaved, medians, the spread the 20-round runs' least and most.

```sh
sh bench/native/profile/build.sh $out            # the kernels, bytes, the twins
python3 -I bench/native/profile/measure.py $out 10
python3 -I bench/native/profile/variants.py $out # the C with one cost taken out
python3 -I bench/native/profile/measure.py $out 7 nob,noovf,noarr,none,push,pushnone,O3
cc -O2 -g -ffp-contract=off -w $out/json_r-20.c -o json_r-20 -lm -lpthread
python3 -I bench/native/profile/prof.py ./json_r-20
```

| kernel | Ren Mcyc a pass | Rust | Go | Ren / Rust | M instructions a pass, Ren / Rust / Go |
|---|---|---|---|---|---|
| `logs_r` | 43.9 (856-1096 for 20) | 30.8 (655-747) | 36.0 | 1.43× | 270 / 188 / 170 |
| `json_r` | 160.0 (3141-3716) | 57.2 (1028-1214) | 95.5 | 2.80× | 565 / 226 / 387 |
| `pages_r` | 6.29 (337-374) | 2.70 (110-123) | 4.68 | 2.33× | 30.6 / 15.6 / 21.7 |
| `bytes`, the whole program | 2130 (2125-2131) | 1731 (1726-1733) | 2951 | 1.23× | 2347 / 2260 / 4022 |

With one cost taken out of the emitted C (`variants.py`; seven runs,
Mcyc / M instructions a pass):

| kernel | base | no `Bytes.at` check | no overflow checks | no array checks | none of the three | push inline | push inline, no checks | -O3 |
|---|---|---|---|---|---|---|---|---|
| `logs_r` | 44.0 / 271 | 30.4 / 170 | 41.8 / 196 | 47.8 / 270 | 50.7 / 174 | | | 36.4 / 198 |
| `json_r` | 157.7 / 560 | 145.3 / 497 | 146.0 / 515 | 139.5 / 546 | 131.1 / 462 | 91.0 / 399 | 103.7 / 311 | 132.8 / 492 |
| `pages_r` | 7.16 / 31.6 | 6.41 / 27.6 | 5.72 / 30.0 | 6.53 / 31.3 | 5.43 / 22.9 | 4.49 / 20.3 | 3.68 / 12.2 | 6.59 / 29.6 |

The push columns are from a second session of nine runs, whose base was
json 151.9 and pages 6.33, and Rust's 50.3 and 2.50. Every variant of
`bytes` ran 2127 to 2131 Mcyc. compiler.md's "Bytes stage" says what
the profiles show and which fixes step 1 makes of them.

## Bytes stage, step 1 (compiler.md, "Bytes stage", "Step 1, as built")

The same machine, kernels and method as the baseline above. Each fix
was built on the one before and measured against it in one session, ten
runs interleaved with Rust and Go; the previous build's binaries are
timed as a variant (`<out>/var/<kernel>-<rounds>.<name>`, copied in by
hand). Mcyc a pass, M instructions in brackets; bytes in Mcyc whole:

| build | `logs_r` | `json_r` | `pages_r` | bytes |
|---|---|---|---|---|
| step 0 | 42.2 (271) | 154.8 (572) | 6.77 (32.1) | 2124 (2346) |
| 1, `Bytes.at` inline | 39.4 (254) | 141.0 (563) | 6.44 (30.3) | 2125 (2346) |
| same session: 1 | 40.2 (254) | 136.6 (557) | 6.70 (31.0) | 2128 (2346) |
| 1b, length and data before the loop | **32.6** (191) | 136.5 (534) | 7.05 (30.1) | 2126 (2346) |
| same session: 1b | 33.8 (192) | 136.4 (533) | 7.11 (30.8) | 2129 (2347) |
| 4, push inline | 33.7 (192) | **82.6** (369) | **4.31** (19.3) | 2128 (2346) |
| same session: 4 | 33.3 (191) | 86.4 (369) | 4.30 (18.7) | 2126 (2346) |
| 5, `%` and `/` by a constant | 33.5 (192) | 82.8 (366) | 4.30 (19.0) | 2125 (2346) |
| same session: 5 | 34.8 (192) | 80.3 (366) | 4.34 (19.2) | 2130 (2347) |
| 2 and 3, step and `b.at(i)` proved | 34.9 (191) | 82.9 (353) | 4.39 (19.3) | 2127 (2346) |
| Rust, those sessions | 30.7 to 33.7 | 49.1 to 51.2 | 2.51 to 2.60 | 1726 to 1730 |
| Go | 33.4 to 36.2 | 85.6 to 87.7 | 4.52 to 4.78 | 2942 to 2950 |

All of step 1 against step 0, 21 runs interleaved, load about 4 (the
OS's photo analysis was running), medians and the 20-round runs' spread:

| kernel | step 0 | step 1 | Rust | Go | step 1 / Rust |
|---|---|---|---|---|---|
| `logs_r` | 40.7 (847-1093) | 35.4 (773-894) | 31.3 (655-750) | 35.6 | 1.13× |
| `json_r` | 158.1 (2815-3534) | 93.6 (1514-2409) | 51.8 (985-1202) | 93.9 | 1.81× |
| `pages_r` | 6.93 (339-389) | 4.47 (294-348) | 2.62 (111-125) | 4.72 | 1.71× |
| bytes, whole | 2125 (2123-2127) | 2124 (2123-2126) | 1727 (1726-1730) | 2944 | 1.23× |

```sh
sh bench/native/profile/build.sh $out
# the build before, its Ren binaries copied to $out/var as <k>-<r>.base and bytes.base
python3 -I bench/native/profile/measure.py $out 21 base
```

`json_r` alone, twelve runs of one binary: 1.64 to 2.33 G cycles on 7.5
to 8.0 G instructions, so its spread is the run, not the build. Fix 5's
hand-written multiply (the C's `% INT64_C(1000003)` replaced by `smulh`
by the magic number, a shift, a fix-up and `msub`) ran bytes in 2188
Mcyc against 2125, five runs each.

The other programs, release, step 0's compiler against step 1's, five
runs interleaved, G cycles: binary-trees 19.27 / 19.87 (eleven runs:
19.63 / 19.94, spreads 19.1-20.0 and 19.3-20.3), blocks 4.47 / 4.48,
cfold 0.201 / 0.203, deriv 1.83 / 1.84, dispatch 1.33 / 1.35, fannkuch
6.95 / 6.93, handlers 3.68 / 3.67, inout 5.98 / 5.98, nbody 7.14 / 7.14,
nested 2.90 / 2.88, nqueens 1.88 / 1.90, rbtree 2.24 / 2.26, slices
10.26 / 8.46, stack 2.58 / 2.58, vec 4.40 / 4.39; each printed the same.


## Bytes stage, step 2 (compiler.md, "Bytes stage", "Step 2, as built")

The same machine and method; load 4.3 to 5.6 (the OS's photo analysis
was running). `frames` is the new kernel (bench/native/frames): a
million length-prefixed little-endian records with a `VarUInt` field,
decoded through a cursor, 20 rounds against 0, with Rust and Go twins.
Each build of the cursor, ten or eleven runs interleaved, Mcyc a pass,
M instructions in brackets:

| build | `frames` | Rust | Go | / Rust |
|---|---|---|---|---|
| the cursor's room checked by a method of the cursor | 134.2 (931) | 22.2 | 51.3 | 6.0× |
| the room checked inline in each read | 91.0 (550) | 22.2 | 51.7 | 4.1× |
| the prelude's small functions inlined by C, `print`'s included | 43.9 (320) | 22.3 | 51.1 | 1.97× |
| as committed, `print`'s path left out | **46.1** (320) | 22.3 | 51.4 | **2.06×** |

`print`'s path inlined cost the other kernels, the same C otherwise, 11
runs each: `pages_r` 6.1 against 4.6 Mcyc a pass (19.0 against 18.8 M
instructions), `json_r` 97.1 against 90.6, so it's left out.

As committed, 11 runs interleaved (bytes 5), medians and the 20-round
runs' spread:

| kernel | Ren | Rust | Go | Ren / Rust |
|---|---|---|---|---|
| `logs_r` | 34.5 (768-898) | 33.0 (655-748) | 34.9 (710-789) | 1.04× |
| `json_r` | 87.0 (1620-2158) | 51.6 (983-1242) | 93.1 (1776-2146) | 1.69× |
| `pages_r` | 4.39 (302-340) | 2.56 (111-125) | 4.59 (183-206) | 1.71× |
| `frames` | 46.1 (910-1058) | 22.3 (488-529) | 51.4 (1112-1172) | 2.06× |
| bytes, whole | 2125 (2124-2126) | 1727 (1726-1730) | 2959 (2944-2960) | 1.23× |

```sh
sh bench/native/profile/build.sh $out
python3 -I bench/native/profile/measure.py $out 11
KERNELS=frames python3 -I bench/native/profile/measure.py $out 11   # one kernel
# the A/B of the inlining: build the C with --emit-c, then compile it
# with REN_INLINE defined as `inline` and as `inline __attribute__((always_inline))`
```

The other programs with and without the inlining, release, five runs:
`vec` 4.39 / 4.39 G cycles, `nbody` 7.14 / 7.14.
## Bytes stage, step 3 (compiler.md, "Bytes stage", "Step 3, as built")

The same machine and method; load 4.1 to 4.4 (the OS's photo analysis
was running again, nothing else building). `maps` is the new kernel
(bench/native/maps): 200,000 accounts in a `Map<Int, Account>` and a
`Map<Str, Int>`, each round built, looked up 400,000 times, a third
removed and iterated in insertion order, 20 rounds against 0, with Rust
(std `HashMap` of each key to its place in a `Vec` of entries) and Go
(a `map` the same way) twins. Eleven runs interleaved, Mcyc a round,
the 20-round runs' spread in brackets, then M instructions a round:

| kernel | Ren | Rust | Go | Ren / Rust |
|---|---|---|---|---|
| `maps` | **108.1** (2065-2679) | 157.0 (3036-3325) | 255.4 (5116-5259) | **0.69×** |
| M instructions | 282.2 | 358.7 | 904.0 | |

Whole runs at the full size, three each, wall clock: Ren release 0.48
to 0.55 s, Rust 0.73 to 0.74 s, Go 0.84 to 0.86 s; Ren debug 2.85 to
3.11 s. Ren's spread is wide under the load, but its slowest 20-round
run is under Rust's fastest. Rust's std `HashMap` hashes with SipHash,
where Ren's map hashes an `Int` with one multiply-and-fold and a `Str`
8 bytes at a time; the rest is the same shape, an index of entry
numbers into a dense array of entries.

```sh
sh bench/native/profile/build.sh $out
KERNELS=maps python3 -I bench/native/profile/measure.py $out 11
```
Since the data stage's step 6 (compiler.md, "Data stage", "Descriptions
(step 6)"), Ren's side of the shapesK kernels is codecs, `dep Codec2 =
cost: fn() -> Int` and so on, since a program that owns every shape
writes the ADT; the kernels keep their names here, in measure.sh and in
the twins. Only names changed: the release build's C is the same but
for its handlers' names, the checksums are the same, so these numbers
stand (checked on a Linux cloud container, against ed8f0f8).

## Bytes stage, part two, step 1 (compiler.md, "Bytes stage, part two", "Step 1, as built")

`Str.from_utf8`'s validator, `ren_utf8_check`, on b5.c's texts of 1 MiB,
GB/s. x86_64 cloud container, 4 cores, shared, so this is the scalar
path: eight ASCII bytes at a time, then a range-table decoder. Wall
time, since there's no `perf`. "before" is the byte loop it replaced,
ren_rt.c's `ren_utf8_valid` at 9ec5fb9, copied into the harness. Rust
is std's `str::from_utf8` (`rustc -C opt-level=3`) on the same bytes.
Seven runs interleaved, medians and spread:

| text | before | step 1 | Rust | step 1 / before | step 1 / Rust |
|---|---|---|---|---|---|
| ASCII | 1.01 (0.92-1.04) | 21.4 (13.6-25.3) | 25.7 (20.0-26.8) | 21× | 0.83× |
| CJK | 0.82 (0.75-0.90) | 1.01 (0.92-1.09) | 0.76 (0.60-0.80) | 1.23× | 1.33× |
| mixed | 0.88 (0.66-0.94) | 2.01 (1.81-2.10) | 2.08 (1.70-2.24) | 2.3× | 0.97× |

An earlier session on the same build got ASCII 11.2 (8.5-13.6) against
1.92 (1.53-2.19), CJK 1.03 (1.02-1.08) against 0.83 (0.67-0.91), and
mixed 2.28 (2.10-2.35) against 1.25 (1.22-1.29). The machine's speed
moves by up to 2× between sessions; the ratios within a session hold.

```sh
dune build test/utf8/diff.exe
d=_build/default/test/utf8/diff.exe
for k in ascii cjk mixed; do $d dump $k 1048576 /tmp/$k.txt; done
rustc -C opt-level=3 -o /tmp/u8 test/utf8/from_utf8.rs
for r in 1 2 3 4 5 6 7; do for k in ascii cjk mixed; do $d bench $k 1048576; /tmp/u8 /tmp/$k.txt; done; done
```

**NEON isn't timed here.** The step's targets are the research's NEON
numbers on the M4 Max: 70 GB/s or more on ASCII, about 9 on CJK and
13.5 on mixed (73.1, 9.01, 13.5). The NEON path is checked for
correctness under qemu-aarch64 (test/utf8/neon.sh: 0 disagreements),
which can't time it. On the M4, `diff.exe bench K 1048576` built there
times it against the old loop; bench/native/strs/'s `utf8` kernel times
`Str.from_utf8` from Ren once it's on main.

## Slices (foundations.md, decision 17; compiler.md, step 6)

Slices are built as representation A: a slice is a header like its
owner's, the same type, with a pointer into the root's buffer and the
root counted (Roc's seamless slices). `split_at` lends its halves, so a
quicksort by `split_at` sorts in place. B, a slice inline in its
container, and the uncounted view of a borrowed root are not built
(compiler.md, step 6, "Where it differed from its plan").

**The other programs**, release at main.ren's size, against 695b3a8 in
the same run. Hyperfine, 10 runs, in ms; cycles and instructions the
median of 5 interleaved runs under `/usr/bin/time -l`; load average
about 5.

| program | 695b3a8 | after | cycles 10⁶, before / after | ratio | instructions 10⁶ |
|---|---|---|---|---|---|
| rbtree | 580.4 ± 3.7 | 574.5 ± 4.0 | 2277 / 2254 | 0.990 | 12744 / 12748 |
| deriv | 482.4 ± 4.9 | 476.0 ± 3.4 | 1869 / 1849 | 0.990 | 9164 / 9193 |
| nqueens | 483.2 ± 5.5 | 479.3 ± 6.4 | 1905 / 1881 | 0.988 | 5225 / 5229 |
| cfold | 54.4 ± 0.9 | 54.1 ± 0.6 | 208 / 206 | 0.994 | 843 / 844 |
| binary-trees | 5289.6 ± 150.8 | 5183.3 ± 89.8 | 20789 / 20340 | 0.978 | 102208 / 102798 |
| nbody | 1802.0 ± 3.6 | 1819.0 ± 4.9 | 7089 / 7153 | 1.009 | 26230 / 26429 |
| fannkuch | 1802.6 ± 7.9 | 1769.9 ± 6.2 | 7085 / 6956 | 0.982 | 20774 / 21650 |
| nested | 722.5 ± 6.9 | 726.1 ± 6.9 | 2835 / 2858 | 1.008 | 14082 / 14283 |
| bytes | 541.2 ± 1.2 | 542.1 ± 1.1 | 2129 / 2131 | 1.001 | 2342 / 2346 |
| vec | 1122.7 ± 3.1 | 1118.3 ± 2.4 | 4417 / 4398 | 0.996 | 16115 / 16122 |
| blocks | 1141.5 ± 9.6 | 1137.9 ± 16.9 | 4492 / 4497 | 1.001 | 26413 / 26819 |
| inout | 1481.4 ± 4.9 | 1517.6 ± 5.5 | 5823 / 5967 | 1.025 | 48095 / 48103 |
| handlers | 939.6 ± 7.4 | 939.3 ± 4.8 | 3699 / 3698 | 1.000 | 24027 / 24027 |
| stack | 657.3 ± 2.2 | 657.5 ± 0.9 | 2583 / 2587 | 1.002 | 6125 / 6126 |
| dispatch | 345.8 ± 6.6 | 341.5 ± 6.0 | 1352 / 1335 | 0.988 | 5301 / 5303 |

The first build read `root` in `ren_array_unique` and
`ren_array_writable`, on every push and every write in place: blocks
was 1.038 in cycles, its `map` kernel alone 14% (720 against 820
Mcycles), one more dependent load a push. `cap` now says what kind an
array is, at least 1 for an owner, 0 for a slice and -1 for a lent one,
so both tests read the count and `cap` as before. inout's program C is
the same before and after, and so are its instructions; it calls
`ren_array_own` twice a round of a thousand elements, so its 2.5% is
where the loop landed, not work.

**The parsing kernels** (research/slices.md, section 2): bench.ren's
`logs`, `json` and `pages`, each with slices and with offsets (`_r`), and
Rust's and Go's twins, each alone at 200,000 for 20 rounds (build.sh's
`slices-<kernel>`). Per pass, the input's generation (0 rounds)
subtracted; cycles the median of 10 runs. Rust's slices are `&[u8]`,
Go's `[]byte`; `_r` is offsets in each language.

| kernel | Ren slices | Ren offsets | Rust slices | Rust offsets | Go slices | Go offsets | Ren slices / Rust slices |
|---|---|---|---|---|---|---|---|
| logs, Mcyc a pass | 59.6 | 38.3 | 26.8 | 33.7 | 34.1 | 35.7 | 2.23× |
| json | 224.6 | 210.3 | 105.7 | 72.3 | 496.3 | 104.0 | 2.12× |
| pages | 19.7 | 10.2 | 7.5 | 4.3 | 39.1 | 5.5 | 2.64× |

Measured again on 2026-10-28 (the same binaries, cycles the median of
5, each kernel's 0-round run subtracted), logs and json hold: 2.43×
and 2.20×. pages doesn't: Rust's twins ran 3.2 Mcyc a pass with slices
and 2.4 with offsets, not 7.5 and 4.3, so Ren's slices are **5.6×**
Rust's there (Ren 18.1). Ren's offsets are 2.6× Rust's on pages and
2.8× on json too, so not all of the gap is slices: Ren's byte and
string handling is slower than Rust's before a slice is made.

| kernel | allocations a pass | dups a pass | instructions 10⁶ a pass, slices / offsets |
|---|---|---|---|
| logs | 1.2M (one a field) | 1.2M | 387 / 271 |
| json | 6.4M (token and slice) | 8.8M | 1197 / 575 |
| pages | 611k | 814k | 110 / 31 |

The offsets twins allocate nothing in their loops. These are the
research's A-heap numbers (logs 55.3 Mcyc a pass, json 196, pages
17.8; the same allocations and dups exactly), on a machine about as
loaded; Rust's json ran 1.5× slower than the research's here, so json's
row is the noisiest. What A costs is a header allocated, the root
counted, and the header freed, per slice: in logs 21 Mcyc a pass over
offsets, in pages 9.5.

What B would save, by the research's hand-written B: json 196 to 143
Mcyc a pass, pages 17.8 to 8.5, within 1.2× of offsets; and the
uncounted view of a borrowed root, logs 55.3 to 35.7. Both need a
slice of two or three words held where Ren holds one: in a field, an
array element, a word of a type variable's value. Step 10's small
values are release-only and never any of those, and stack.ml's frames,
where A-frame kept a header, went in decision 14. Until then, offsets
are the fast way to parse, and slices the clear one at about 2×.

**Writing in place through `split_at`.** A quicksort that recurses on
the halves of a `split_at`, which are lent, as bench/10d/slices_lent.ren's
does: 200,000 `Int`s sort in 20 ms, allocating a header for each half and no copy of
an element, peak 2.1 MB, the array's 1.6 MB and its headers.

**Retention.** The research's program, bench.ren's `retain` (build.sh's
`retain_slice` and `retain_copy`), eight 8 MiB inputs keeping a
thousand ten-byte keys each: kept as slices, peak live 134.5 MB, every
input alive to the end; kept as `.copy()`, 75.9 MB, the generator's
own. `copy()` of an owner is the owner, counted. The debug report of a
small slice keeping a large root alive (research/slices.md, section 3)
is not built.

## Frames and late overflow cut (foundations.md, decisions 14 and 15)

stack.ml's frames (H8) and late.ml's late overflow removed, against
3f15998, the commit before, release builds at main.ren's size, one
hyperfine invocation per program (`-N --warmup 2 --runs 10`), cycles
the median of hyperfine's per-run counts. Apple M4 Max, load average
4.5 to 5.4 of 16 cores during the run. Every binary prints what the
other prints.

Each program's C is the same as before but for the panic texts (the
overflow help now writes `n +% 1`) and the runtime: stack.ml promoted
nothing in any of them once small values were built, and late.ml was
off. So any difference is the runtime's.

| program | 3f15998 (s) | now (s) | now / 3f15998, cycles | cycles 10⁹, 3f15998 / now |
|---|---|---|---|---|
| rbtree | 0.576 ± 0.003 | 0.575 ± 0.002 | 1.00× | 2.26 / 2.25 |
| deriv | 0.495 ± 0.010 | 0.489 ± 0.007 | 0.99× | 1.90 / 1.89 |
| nqueens | 0.490 ± 0.006 | 0.488 ± 0.007 | 1.00× | 1.91 / 1.91 |
| cfold | 0.054 ± 0.001 | 0.054 ± 0.001 | 1.00× | 0.21 / 0.21 |
| binary-trees | 5.089 ± 0.091 | 5.199 ± 0.091 | 1.00× | 20.37 / 20.35 |
| nbody | 1.824 ± 0.005 | 1.826 ± 0.004 | 1.00× | 7.09 / 7.10 |
| fannkuch | 1.782 ± 0.008 | 1.792 ± 0.009 | 1.01× | 6.96 / 7.01 |
| inout | 1.509 ± 0.004 | 1.509 ± 0.007 | 1.00× | 5.83 / 5.83 |
| stack (H8) | 0.656 ± 0.002 | 0.657 ± 0.002 | 1.00× | 2.58 / 2.59 |
| blocks | 1.156 ± 0.011 | 1.154 ± 0.008 | 1.00× | 4.54 / 4.55 |
| nested | 0.728 ± 0.010 | 0.723 ± 0.007 | 0.99× | 2.86 / 2.84 |
| vec | 1.120 ± 0.002 | 1.123 ± 0.002 | 1.00× | 4.41 / 4.43 |
| bytes | 0.541 ± 0.002 | 0.540 ± 0.001 | 1.00× | 2.13 / 2.13 |

binary-trees' cycles are a second invocation's: the first's 1.02×
didn't repeat (20.37 against 20.35 billion), its instructions the same
in both (102.17 billion). bench/frames.ren, H8's cases as a program,
runs in 3 ms either way.

- **One runtime change moved a benchmark, not the cut.** Taking
  `ren_late_check()` out of `ren_array_grow`'s out-of-memory path let
  clang inline the whole function into `ren_array_push_taking`, and
  blocks went from 4.54 to 5.63 billion cycles (1.24×) on fewer
  instructions (26.4 to 24.6 billion); sampling put the time in
  `ren_array_push_taking`. Splitting off only the doubling, with the
  length test inline, didn't recover it (1.19× in wall time); keeping
  `ren_array_grow` out of line (`noinline`, as the extra call had kept
  it) did, and that's what's built. Why the inlined push is slower on
  the M4 isn't known.

## Follow-ups (compiler.md, step 14: loops without indices)

Where every program stands after the follow-ups to foundations.md, and
what this one, decision 16's loops, did. 7f8822f is the commit
that amended foundations.md from the native slice's measurements, before
any follow-up (steps 10 to 14) was built; d5a2381 is the commit
before this step; after is this commit's. One hyperfine invocation per
program (`-N --warmup 3 --runs 10`, main.ren's size, release builds),
with CPU cycles and instructions retired as hyperfine records them, and
the Rust (`rustc -C opt-level=3 -C codegen-units=1`) and Go twins in the
same invocation. Load average 2.0 to 5.4 of 16 cores (5.4 only during
binary-trees, whose spread shows it). Every binary prints what the Rust
twin prints, except 7f8822f's vec, which can't build the two kernels
with sized `Int`s and leaves their lines out. bytes and nested are newer
than 7f8822f.

| program | 7f8822f (s) | d5a2381 (s) | after (s) | Rust (s) | Go (s) | after / Rust | after / Go | cycles, after / 7f8822f | cycles, after / d5a2381 |
|---|---|---|---|---|---|---|---|---|---|
| binary-trees | 8.10 ± 1.08 | 7.94 ± 0.88 | 7.65 ± 0.13 | 13.03 | 6.44 | 0.59× | 1.19× | 1.00× | 0.99× |
| blocks | 2.239 | 1.744 | 1.737 | 1.457 | 1.808 | 1.19× | 0.96× | 0.78× | 1.00× |
| bytes | | 0.814 | 0.814 | 0.663 | 1.129 | 1.23× | 0.72× | | 1.00× |
| cfold | 0.165 | 0.087 | 0.088 | 0.695 | 0.477 | 0.13× | 0.18× | 0.52× | 1.01× |
| deriv | 0.750 | 0.749 | 0.762 | 1.881 | 1.328 | 0.41× | 0.57× | 1.02× | 1.01× |
| fannkuch | 2.671 | 2.651 | 2.681 | 2.644 | 2.467 | 1.01× | 1.09× | 1.00× | 1.01× |
| handlers | 1.402 | 1.404 | 1.402 | 1.331 | 1.943 | 1.05× | 0.72× | 1.00× | 1.00× |
| inout | 2.512 | 2.526 | **2.269** | 1.358 | 2.407 | **1.67×** (was 1.86×) | 0.94× | 0.90× | **0.90×** |
| nbody | 4.078 | 2.732 | 2.714 | 1.682 | 2.702 | 1.61× | 1.00× | 0.67× | 0.99× |
| nested | | 1.098 | 1.101 | 2.631 | 2.836 | 0.42× | 0.39× | | 1.00× |
| nqueens | 0.744 | 0.747 | 0.745 | 1.086 | 0.773 | 0.69× | 0.96× | 1.00× | 1.00× |
| rbtree | 0.964 | 0.880 | 0.878 | 1.440 | 0.606 | 0.61× | 1.45× | 0.91× | 1.00× |
| stack | 0.991 | 0.987 | 0.987 | 0.910 | 0.886 | 1.08× | 1.11× | 1.00× | 1.00× |
| vec | 8.104 | 1.705 | 1.694 | 1.377 | 4.242 | 1.23× | 0.40× | 0.21× | 0.99× |

Standard deviations are under 2% except where shown. Every program is
within vision.md's 2× of Rust; inout, at 1.67×, and nbody, at 1.61×,
are the furthest.

**vec's kernels, one at a time** (bench/native/vec, `run(1000,
1_000_000, k)`; `--runs 5`; "old forms" is this commit's compiler on
the kernels written with `for i in 0..xs.len()` and `xs[i]`, as before
this step, which is what d5a2381 built):

| kernel | written | clang, after | 7f8822f | d5a2381 | old forms | after | Rust | after / Rust, cycles |
|---|---|---|---|---|---|---|---|---|
| dot | `for (x, y) in xs.zip(ys)` | vectorized, 2 × 4, in order | 1.870 | 0.747 | 0.750 | 0.750 | 0.747 | 1.00× |
| fsum | `xs.sum()` | vectorized (ren_float_sum, step 13) | 4.820 | 0.109 | 0.109 | 0.109 | 0.108 | 1.01× |
| scale | `for x in &xs` | vectorized, 2 × 4 | 0.414 | 0.105 | 0.104 | 0.104 | 0.106 | 0.99× |
| axpy | `for i, y in &ys`, `xs[i]` | vectorized, 2 × 4, versioned on `xs` | 0.634 | 0.156 | 0.154 | 0.153 | 0.153 | 1.00× |
| churn | `for x in &xs`, `*%` and `+%` | interleaved, not vectorized: "not beneficial" | | 0.171 | 0.171 | 0.171 | 0.176 | 0.97× |
| total | `for x in xs`, `t += x` | not vectorized: the overflow check's exit | 0.402 | 0.402 | 0.402 | 0.401 | 0.091 | **4.45×** |
| blend | `for i, x in &xs`, `ys[i]`, `UInt8` | vectorized, 16 × 4, versioned on `ys` | | 0.032 | **0.021** | **0.022** | 0.022 | **0.99×** (was 1.49×) |

- **What this step bought is the loops over two arrays, and inout.**
  blend, which reads `ys[i]` while it writes `xs`, didn't vectorize at
  d5a2381: `ys[i]` was checked, so the loop had a second way out.
  Versioned (`if n <= length ys`), its fast copy has no check, and clang
  vectorizes it sixteen bytes at a time: 0.66× the cycles, Rust's time.
  inout's `step` reads `b[i]` and `c[i]` in a loop over `a`; versioned,
  those are unchecked, and it's 0.90× the cycles and 14% fewer
  instructions, 1.67× Rust where it was 1.86×.
- **The single-array loops were already Rust's speed at d5a2381.**
  dot, scale and axpy written the old way were 1.00× Rust before this
  step: clang removes a check of `xs[i]` against the length a `for i in
  0..xs.len()` counts to by itself (it sees the bound and the check are
  the same load), and the hoisted loops of step 7 gave it the length
  once. So writing them `for x in &xs` or `zip` changes their code very
  little (2% fewer instructions in axpy): the new forms say what the
  loop does, and are what keeps it cheap where clang's own reasoning
  doesn't reach, as in blend.
- **What still blocks vectorizing, by loop:**
  - *An `Int` overflow check* (total, inout, bytes' loops, fannkuch's
    flips): a checked `+` or `*` is a branch out of the loop, so clang
    won't vectorize it ("could not determine number of loop
    iterations", or no candidate at all). total is 4.45× Rust, whose
    release build wraps. This is now the largest cost left in the
    benchmarks, and step 13's late overflow didn't remove it (RESULTS,
    step 13). The wrapping operators do vectorize, where they're what's
    meant (churn: interleaved; 64-bit multiplies aren't worth vectorizing
    on arm64, for Rust either).
  - *Reading and writing two elements of one array* (nbody's pairs
    loop, `bodies[i]` and `bodies[j]`): "unsafe dependent memory
    operations". Its indices are all proved now (`(i + 1)..n` counts
    from a count in bounds), 9% fewer instructions, but the cycles are
    the same, 1.61× Rust; Rust's is the same scalar loop over a fixed
    array of five.
  - *A loop that isn't counted* (blocks' `attempt`, a `while` on a
    condition; the recursive walks of the tree programs): nothing to
    vectorize, and nothing this step changes.
  - *A floating point sum in order* (dot) vectorizes as an in-order
    reduction, which is no faster than scalar: it's Rust's speed, and
    Rust's is the same. A sum that may be reassociated is `sum()`'s
    fixed tree (decision 15).
- **fannkuch** writes its copy loop `for i, x in perm1` now, which
  vectorizes; it's a small part of the run, so its time is unchanged,
  at Rust's.
- No program got slower: deriv's 1% is its run-to-run spread (0.762 ±
  0.006 against 0.749 ± 0.007, and the same instructions).

## NaN where observed, Float sums, late overflow (compiler.md, step 13)

Decision 15's rules for arithmetic. Before is 1563352, the commit
before this step, whose release build checked every `Float` operation
for a NaN (`ren_fcheck`) and added a `Float` array's `sum` left to
right; after is this commit's, which checks a NaN where it's observed
and sums in eight lanes; "late" is this commit's with REN_LATE set,
which reports an `Int` overflow in a loop late (late.ml). One hyperfine
invocation per program (`-N --warmup 3 --runs 10`, main.ren's size),
with CPU cycles and instructions retired as hyperfine records them,
the Rust twin (`rustc -C opt-level=3 -C codegen-units=1`) in the same
invocation. Load average 3.2 to 4.1 of 16 cores. Every binary prints
what the Rust twin prints.

| program, release | 1563352 (s) | after (s) | late (s) | Rust (s) | after / before, cycles | instructions 10⁹, before / after / late | after / Rust |
|---|---|---|---|---|---|---|---|
| nbody | 3.986 ± 0.053 | **2.727 ± 0.002** | 2.743 ± 0.018 | 1.679 ± 0.001 | **0.68×** | 64.7 / 28.8 / 33.1 | **1.62×** (was 2.37×) |
| inout | 2.533 ± 0.036 | 2.514 ± 0.020 | 2.977 ± 0.043 | 1.356 ± 0.000 | 0.99× | 56.1 / 56.1 / 64.1 | 1.85× |
| `sum` of a million `Float`s, 2,000 times | 9.965 ± 0.001 | **0.286 ± 0.002** | | | **0.029×** | 22.1 / 2.3 | |
| a running `Int` sum of squares, late against not | 1.070 ± 0.037 | 1.072 ± 0.047 | 1.373 ± 0.117 | | 1.0× (late 1.29×) | 20.0 / 20.0 / 24.1 | |

- **nbody is 1.62× Rust,** where it was 2.37×: its arithmetic is C's
  own, with no check after each operation, and a NaN would be checked
  where it's compared or shown, which nbody's loops never do. Less than
  half the instructions. What's left is the loop over pairs, which
  clang doesn't vectorize: it reads and writes `bodies[i]` and
  `bodies[j]` in the same turn ("unsafe dependent memory operations in
  loop"), and every index is checked.
- **A `Float` array's `sum` is 35× faster,** since it was a chain of
  dependent additions each checked for a NaN and is now eight
  accumulators, which clang vectorizes: two `fadd.2d` on 128-bit
  registers for each pair of lanes, four an iteration
  (`-Rpass=loop-vectorize` and the assembly). Its result is the fixed
  tree's, the same in `ren run` and both builds, which differs in the
  last place from adding left to right (999000000.0 against
  999000000.0000001 here).
- **Late overflow makes no loop vectorize, and the loops it changes
  slower,** so it's off. inout's loop still checks every index, so it
  has exits either way (clang: "could not determine number of loop
  iterations" with it, and with it off the loop isn't a candidate at
  all); its `*` and `+` aren't the only way out. And it costs: 18% more
  cycles on inout, 29% on a running sum of squares, which has no other
  check. Each late operation still branches to a call that records its
  site and operands, which the panic needs to be `ren run`'s; that call
  returns, unlike a panic, so clang keeps what a panic would let it drop
  (the check on `i + 1`), and each loop counts its turns to check every
  1,024. Taking the count out gives inout back its time (2.55 s), so
  it's the count and the returning call. A flag alone, `ovf |=
  overflowed`, which clang could vectorize, can't say which operation
  faulted or with what operands, and a running sum's overflow can't be
  checked in lanes at all, since whether a prefix overflowed isn't known
  from the lanes' sums: clang says "value that could not be identified
  as reduction is used outside the loop" even for the flag. So no
  design keeps `ren run`'s message and vectorizes these loops.

## Sized storage (compiler.md, step 12)

`bytes` ([README.md](README.md)): a million bytes as an `Array<UInt8>`
and a million numbers as an `Array<Int32>`, each changed in place a
round at a time with every store checked to fit, and an FNV-1a hash of
the bytes with `*%` into a `UInt32`. Before is `wide.ren`, the same
program written with `Array<Int>`s as it had to be at 82ed3d1, the
commit before sized types, built by that commit's compiler, its `xor`
a bit at a time since `Int` had none; "wide, now" is the same file
built by this commit's, which changes nothing (same cycles and
instructions). One hyperfine invocation per row (`-N --warmup 3 --runs
10`, at main.ren's size), with CPU cycles, instructions retired and
mean peak memory as hyperfine records them; each kernel is `bench.ren`'s
function alone, on the array `run` builds. The Rust and Go twins, which
keep `u8`s and `i32`s and check each store, timed just after, whole
program only. Load average 3.2 to 3.6 of 16 cores. Every binary prints
what the Rust and Go twins print.

| run | 82ed3d1, `Array<Int>` (s) | wide, now (s) | sized (s) | Rust (s) | sized / 82ed3d1, cycles | instructions 10⁹, before / sized | peak MB, before / sized | `--stats` peak live bytes, before / sized |
|---|---|---|---|---|---|---|---|---|
| `bytes`, release | 1.396 ± 0.008 | 1.493 ± 0.017 | **0.560 ± 0.004** | 0.432 ± 0.004 (Go 0.721) | **0.39×** | 15.3 / 2.3 | 17.6 / 6.6 (Rust 6.7, Go 20.6) | 16,777,339 / 5,243,003 |
| smooth (`Array<UInt8>`), release | 0.106 ± 0.000 | 0.106 ± 0.000 | **0.082 ± 0.000** | | **0.77×** | 0.97 / 0.87 | 9.5 / 2.5 | 8,388,683 / 1,048,651 |
| mix (`Array<Int32>`), release | 0.412 ± 0.002 | 0.413 ± 0.001 | **0.357 ± 0.001** | | **0.87×** | 1.47 / 0.98 | 9.5 / 5.5 | 8,388,687 / 4,194,383 |
| fnv (`*%` into a `UInt32`), release | 0.882 ± 0.001 | 0.882 ± 0.002 | **0.107 ± 0.000** | | **0.12×** | 13.0 / 0.57 | 9.5 / 2.5 | 8,388,664 / 1,048,632 |
| `bytes`, debug | (see cycles) | | **6.37 ± 0.17** | | **0.24×** | 302.1 / 88.9 | 17.8 / 6.7 | |
| smooth, debug | 2.49 ± 0.14 | | 2.58 ± 0.13 | | 1.05× | 33.2 / 36.0 | 9.6 / 2.6 | |
| mix, debug | 2.52 ± 0.11 | | 2.63 ± 0.10 | | 1.09× | 34.8 / 37.7 | 9.6 / 5.6 | |
| fnv, debug | 22.2 ± 1.1 | | **1.12 ± 0.02** | | **0.056×** | 233.7 / 15.1 | 9.6 / 2.5 | |

- **Memory is the element's width.** The arrays' peak live bytes,
  which `--stats` counts exactly, are 8× smaller for the bytes and 2×
  for the `Int32`s, and the process's peak resident memory follows:
  the whole program's 17.6 MB is 6.6 MB, the Rust twin's 6.7 MB.
- **Narrow arrays are faster too.** smooth reads and writes a byte per
  element instead of a word: 0.77× the cycles and a tenth fewer
  instructions, with the fit check on each store (`ren_narrow_u8`, a
  compare and a branch never taken). mix is a dependency chain through
  `%`, so the narrower load saves less: 0.87×.
- **The hash is 8× faster** because it's written as it means: `xor` and
  a multiply that wraps at 32 bits are one instruction each, where
  82ed3d1's had to do the `xor` a bit at a time and keep `h` in range
  with `%`. 0.57 billion instructions to 13.0.
- **Against Rust: 1.30× its time**, 1.24× its cycles, where `Array<Int>`
  was 3.2×. The Rust checks each store with `try_from().unwrap()`, as
  Ren does, but keeps `h` a `u32` the whole way; Ren's is read as an
  `Int` and stored back each step, a widen, and a check for the `xor`'s
  store, which C can't drop since it doesn't know `h.xor(b)` fits.
- What it costs: in the debug build, built at -O0, each store into a
  sized element calls the runtime's check, which nothing inlines, so
  smooth and mix take 5% and 9% more cycles there. The debug build's whole-program time at
  82ed3d1 isn't given: under the load of the run its ten samples ranged
  from 0.4 to 2.3 minutes, so only its cycles, 101 billion, are.

## Arrays of arrays and recursion that builds (compiler.md, step 11)

Swap-out (swap.ml, Lean's) and tail recursion modulo cons (trmc.ml,
Koka's), on `nested` ([README.md](README.md)), against 7fdeedb, the
commit before them, and 7f8822f, in **one** hyperfine invocation per
row (`-N --warmup 3 --runs 10`, at main.ren's size), with CPU cycles
and instructions retired as hyperfine records them and its mean peak
memory. Each kernel is `nested`'s function alone (build.sh's
`nested-grid`, `-map`, `-list`). The Rust column is the twin's kernel
alone, timed in its own invocation just after. Load average 2.7 to
3.8 of 16 cores. Every binary prints what the Rust and Go twins print.

| run | 7f8822f (s) | 7fdeedb (s) | now (s) | Rust (s) | now / 7fdeedb, cycles | instructions 10⁹, 7fdeedb / now | MB, 7fdeedb / now | allocations, 7fdeedb / now |
|---|---|---|---|---|---|---|---|---|
| `nested`, release | 13.919 ± 0.139 | 13.908 ± 0.073 | **1.100 ± 0.013** | 2.623 ± 0.025 (Go 2.812) | **0.079×** | 255.5 / 14.1 | 98.4 / 25.6 | 303.0 million / 101.0 million |
| grid, release | 10.392 ± 0.092 | 10.333 ± 0.044 | **0.172 ± 0.016** | 0.098 | **0.016×** | 229.5 / 3.5 | 2.4 / 1.6 | 100,000,103 / 103 |
| map, release | 0.534 ± 0.005 | 0.519 ± 0.003 | **0.089 ± 0.000** | 0.063 | **0.17×** | 4.7 / 1.4 | 1.7 / 1.6 | 1,000,103 / 103 |
| list, release | 3.070 ± 0.019 | 3.042 ± 0.025 | **0.849 ± 0.004** | 2.513 | **0.28×** | 21.1 / 9.1 | 97.4 / 25.5 | 202.0 million / 101.0 million, 101.0 million reused |
| `nested`, debug | 43.218 ± 0.355 | 43.357 ± 0.275 | **16.746 ± 0.054** | | **0.39×** | 572.7 / 189.2 | 243.2 / 26.2 | |
| grid, debug | 30.877 ± 0.627 | 30.806 ± 0.601 | **6.766 ± 0.008** | | **0.22×** | 436.8 / 70.2 | 2.9 / 1.6 | 100,000,103 / 103 |
| map, debug | 3.217 ± 0.009 | 3.329 ± 0.004 | 3.332 ± 0.005 | | 1.00× | 32.5 / 32.5 | 2.9 / 2.4 | 1,010,103 / 1,010,103 |
| list, debug | 9.345 ± 0.018 | 9.345 ± 0.011 | **6.611 ± 0.013** | | **0.71×** | 103.4 / 86.6 | 241.5 / 25.5 | 202.0 million / 101.0 million, 101.0 million reused |

- **grid: every write copied a row, and now none does.** `g[i][j] = v`
  read the row counted again, so its count was 2 when it was written:
  100 million copies of a 100-element row. Now it's moved out of the
  grid and back: 103 allocations in all, 60× fewer cycles, in both
  builds. 1.76× Rust's time: 100 million counts and drops are left,
  the read of `g[i][j]` in the value, which borrows the row for a
  moment but counts it (`array-get` counts what it gives; a borrowed
  read would need Perceus to know the array outlives it).
- **map over an array of arrays reuses every row in the release build,**
  1,000,103 allocations to 103, 6× fewer cycles, 1.41× Rust's (whose
  `into_iter().map().collect()` reuses each Vec too). The debug build's
  `map` is the generic one, which builds a new array (step 7's
  `map_into` is release only), so it's unchanged.
- **list: no stack, and the cells reused.** `build` and `scale` are
  loops: peak memory 97.4 MB to 25.5 MB, the 72 MB a million frames
  took. And building `scale`'s cell before its recursive call puts it
  right after the drop of the cell it takes apart, so reuse.ml builds
  it there: 101 million cells reused, where the call between had kept
  any from being. 3.6× fewer cycles; a third of the Rust's time, whose
  twin mallocs and frees each `Box` (as in binary-trees). At 30 million
  cells, 7fdeedb panics, the stack overflowed at 1 GiB; now it runs in
  722 MB, its cells.
- What it costs: a function this pass takes has its body twice in the
  C, a first turn and the loop; and a parameter it walks without
  consuming becomes a variable the loop owns, counted each turn, where
  borrow inference had borrowed it. `evens` over a shared list counts
  and drops each cell once more (60,000 of each for 60,000 cells), and
  over a million cells 30 times still takes 2.1× less time than
  7fdeedb (230 to 110 ms): the stack it no longer touches costs more. blocks' `fold` kernel allocates its tree's root on
  the heap now, 1,001 to 1,002 in the release build: `build` was a
  function that built its result in its caller's frame (stack.ml),
  which a loop that fills a hole can't be.

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
  run again; see H6's "With tcc" for the later step 15).
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

**With tcc** (compiler.md, step 15): a debug build writes its C in
units with no system headers and compiles them with tcc in parallel.
Measured clean, in one hyperfine run against the commit before
(median wall seconds; 3 runs at 500k, 5 at 100k, 10 at 10k; load 5
to 20; `go build` with the standard library cached):

| program | before | after | go build | after / Go |
|---|---|---|---|---|
| base 10k | 1.148 | 0.481 | 0.225 | 2.14× |
| base 100k | 10.95 | 3.674 | 2.79 ± 0.43 | 1.32× |
| base 500k | 57.07 | 17.96 | 15.21 | 1.18× |

Still fails, but by 1.18× at 500k instead of 3.8×, with a fifth of
Go's CPU (20.4 s against 105.5). The C compiler is 0.22 s of it at
500k; writing the C, tcc's link (1.3 s) and the front half on one core
are the rest. There's no cache yet, so a leaf edit takes what a clean
build does.

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

## Patterns stage: the keyword kernel (compiler.md, "Patterns stage")

bench/native/keywords: identifiers classified against a key set, 65,536
queries a round, 90% keys and 10% near misses (a key with `_` added or
its last byte made `#`), the sets of research/perfect-hash/code/keys:
Ren's 35 keywords (`renkw`), JS's 45 reserved words (`jsreserved`), 9
HTTP methods, 20 header names, 24 JSON field names. gen.py writes the
Ren (an `==` chain per set, and from step 1 a `match` of literal arms),
its Rust twin (a plain `match`, rmatch.rs's shape) and its Go twin (a
`switch`); all three build the same queries from one LCG and print the
same check.

**Machine:** `cloud` (experiments/MACHINE-cloud.md): Intel Xeon @ 2.10
GHz, 4 vCPUs, a KVM guest with shared cores. rustc 1.97 `-C
opt-level=3 -C codegen-units=1`, Go 1.24, Ren release with gcc 13 `-O2`
(cc). The research's numbers are hand-written C on an M4 Max; compare
these with each other and with its ratios, never its nanoseconds.

**Method:** `R=200 sh build.sh <out>` then `R=200 python3 -I measure.py
<out> 11 <out>.jsonl`: each binary at 200 rounds and at 0, the two
forms and the twins interleaved and rotated, 11 runs each; a lookup is
(median at 200 − median at 0) / (200 × 65,536), and the range is the 11
runs' least and most at 200 less the median at 0. A lookup includes the
loop that walks the queries, which is each language's own: Ren's
counts each `Str` it reads.

### The baseline (step 0): Ren's `==` chain

ns per lookup, median (least to most):

| set | keys | Ren chain | Rust `match` | Go `switch` | chain / Rust |
|---|---:|---:|---:|---:|---:|
| renkw | 35 | 57.4 (55.4 to 59.8) | 19.4 (18.0 to 21.5) | 27.6 (26.4 to 30.5) | 3.0 |
| jsreserved | 45 | 66.3 (62.4 to 74.2) | 22.3 (21.4 to 26.3) | 26.7 (25.7 to 28.6) | 3.0 |
| methods | 9 | 25.6 (24.4 to 29.5) | 16.4 (15.4 to 18.0) | 15.8 (15.1 to 19.7) | 1.6 |
| headers | 20 | 25.3 (24.3 to 28.3) | 12.6 (11.8 to 14.2) | 13.6 (13.2 to 14.6) | 2.0 |
| json24 | 24 | 28.5 (27.5 to 30.5) | 11.4 (10.1 to 12.5) | 12.2 (11.7 to 12.9) | 2.5 |

The chain is a function per set, `if s == "fn" then 0 else if ...`,
each `==` a call of `ren_str_eq`. Its emitted C, release, is 317 KB per
set's program (most of it the runtime's and the prelude's; `wc -c` of
`build.sh`'s `<set>-chain.c`).

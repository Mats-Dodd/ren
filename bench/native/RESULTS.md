# Native slice: what the benchmarks measure

The native slice ([compiler.md](../../compiler.md#native-slice),
[foundations.md](../../foundations.md#staging), item 2) was built to put
numbers on the memory and dispatch bet before tasks and many cores
build on it. These are those numbers, H1 to H7, with a verdict for
each: **holds**, **fails**, or **inconclusive**, and for each failure
what the generated C or the `--stats` counts say causes it and what
would fix it. The programs are in this folder ([README.md](README.md));
[vision.md](../../vision.md) says what the bars are.

## Runtime core stage: step 0 baseline

The **current sequential native baseline** was refreshed at
`97a152973e0bee31c8355a37ba19de1dc0c827c5`, after the upstream bytes-runtime
changes in `bb8044e` through `93d3ac4`, and includes the new `streams`
program. Measured 2026-10-30 (America/Los_Angeles; raw timestamps are
UTC), before runtime-core implementation. The original 21-program
native measurements at `12da2291` are retained below as historical;
use the current 22-program table for later runtime-core comparisons.

Machine `310e503d7935`: x86_64 KVM guest, Intel Xeon Platinum 8573C,
5 visible vCPUs with a 4-CPU cgroup quota and 16 GiB memory limit,
Linux 6.18.57. The repository's pinned Nix environment supplies Clang
23.1.3 (`cc`, release `-O2`), OCaml 5.5.2, Dune 3.24.2 and glibc 2.44.
Current raw commands, outputs, load and compiler metadata are in
[97a1529/](runtime-core-baseline/97a1529/); the original records are
preserved unchanged in [12da2291/](runtime-core-baseline/12da2291/).
The current reference executable's SHA-256 starts `627727b1089c`, the
original's `0164a7e99ce2`; both full hashes are in their build metadata.

The compiler and all native programs were rebuilt before the refresh.
Other agents held compiler/check workloads throughout timing and
continued light source/documentation work. One child runs at a time;
each program is warmed once, then the starting program rotates each
round. Spreads are observed least to most, not confidence intervals.
This shared guest is not the owner's M4 Max, and the two native tables
are measurements in separate windows rather than a paired comparison.

Reproduce the current baseline inside `devenv shell --clean` from the
repository root:

```sh
dune build
python3 -I bench/native/runtime-core-baseline.py build /tmp/runtime-core-baseline-97a1529
python3 -I bench/native/runtime-core-baseline.py kernels /tmp/runtime-core-baseline-97a1529 --runs 5
python3 -I bench/native/runtime-core-baseline.py summarize /tmp/runtime-core-baseline-97a1529
```

**Current sequential native programs (97a1529).** All 22
`*/main.ren` programs, release, five runs each. Wall seconds include
process startup. Each program's five outputs agree, and all 21 existing
programs retain their historical checksums. One-minute load during
current timed runs was 0.80–1.08. `keywords/main.ren` runs only one
round, so its roughly 5 ms includes substantial startup noise; the
dedicated keyword measurements below remain the lookup benchmark.

| program | median (s) | least–most (s) |
|---|---:|---:|
| binary-trees | 11.4375 | 11.2720–11.4587 |
| blocks | 1.9947 | 1.9842–2.0424 |
| bytes | 0.6743 | 0.6544–0.6803 |
| cfold | 0.1580 | 0.1467–0.1890 |
| deriv | 1.4320 | 1.2730–1.6081 |
| dispatch | 0.6927 | 0.6684–0.7533 |
| fannkuch | 3.2991 | 3.2270–3.3118 |
| frames | 1.2172 | 1.1930–1.2189 |
| handlers | 1.9505 | 1.9372–2.0029 |
| inout | 3.2261 | 3.0422–3.3745 |
| interp | 0.1325 | 0.1304–0.1413 |
| keywords | 0.0046 | 0.0036–0.0077 |
| maps | 1.3280 | 1.3066–1.5042 |
| nbody | 2.9756 | 2.8795–3.0373 |
| nested | 1.2928 | 1.2884–1.3302 |
| nqueens | 1.0610 | 1.0507–1.1685 |
| rbtree | 1.4210 | 1.3388–1.4759 |
| slices | 3.4862 | 3.4432–3.5809 |
| stack | 0.8332 | 0.8297–0.8550 |
| streams | 2.0567 | 1.9694–2.6664 |
| strs | 5.7291 | 5.5936–5.7664 |
| vec | 2.0194 | 2.0065–2.0741 |

**Historical sequential native programs (12da2291).** The original
five-run, 21-program table follows unchanged; its one-minute load was
1.00–1.10. These values predate the upstream bytes-runtime changes and
are superseded as the sequential baseline by the table above.

| program | median (s) | least–most (s) |
|---|---:|---:|
| binary-trees | 11.3331 | 11.0947–11.4962 |
| blocks | 2.0204 | 1.9917–2.0777 |
| bytes | 0.6729 | 0.6696–0.6933 |
| cfold | 0.1612 | 0.1481–0.2213 |
| deriv | 1.3550 | 1.2924–1.4780 |
| dispatch | 0.7112 | 0.6936–0.7258 |
| fannkuch | 3.3152 | 3.2955–3.5354 |
| frames | 1.0420 | 1.0242–1.3317 |
| handlers | 2.0370 | 1.9664–2.4101 |
| inout | 3.3376 | 3.2098–3.3748 |
| interp | 0.1250 | 0.1184–0.1337 |
| keywords | 0.0052 | 0.0044–0.0073 |
| maps | 1.4105 | 1.3817–1.7952 |
| nbody | 2.9651 | 2.9482–3.0094 |
| nested | 1.3266 | 1.3093–1.3722 |
| nqueens | 1.0858 | 1.0544–1.1941 |
| rbtree | 1.2645 | 1.2281–1.3616 |
| slices | 3.5827 | 3.5551–3.7857 |
| stack | 0.8380 | 0.8206–0.8786 |
| strs | 5.8890 | 5.7445–6.2170 |
| vec | 2.0507 | 2.0346–2.1299 |

**Why the other references are retained.** Interpreter/frontend/std
sources and all measured interpreter fixtures are identical between
`12da2291` and `97a1529` (115 tracked entries; native compiler/runtime
sources excluded). X1/X5 and the prototype source trees are also
unchanged since their adapter was committed in `cb3cb0c`. The matching
source-tree fingerprints and their exact scope are recorded in
[retained-inputs.json](runtime-core-baseline/97a1529/retained-inputs.json).
Their timings below remain the original, explicitly dated same-machine
references; they were not repeated for this native-only refresh.

The retained interpreter and frame measurements can be reproduced with
the same harness modes, five and seven rounds respectively:

```sh
python3 -I bench/native/runtime-core-baseline.py examples /tmp/runtime-core-baseline-97a1529 --runs 5
python3 -I bench/native/runtime-core-baseline.py frames /tmp/runtime-core-baseline-97a1529 --runs 7
```

**Retained interpreter tasks and services (12da2291).** Each command
was `test --sim --seeds 1000`, five runs after one warmup. Times include source loading,
checking and running every selected test under its 1,000 seeds. The
seven landed example suites and the four retained correct milestone
variants all pass. Only the CLI's final elapsed-time suffix is removed
when checking that their reported results agree; raw output keeps it.
One-minute load was 0.95–1.00.

| suite or selected milestone | tests | median (s) | least–most (s) |
|---|---:|---:|---:|
| 11a-cached | 1 | 0.1374 | 0.1306–0.1522 |
| 11a-two-adds | 1 | 0.1191 | 0.1134–0.1298 |
| breaker | 4 | 0.2772 | 0.2722–0.2839 |
| crawler | 3 | 4.8385 | 4.7128–4.9462 |
| docs | 4 | 10.0094 | 9.9425–10.1194 |
| just | 21 | 3.5636 | 3.5259–3.5819 |
| refresh | 4 | 0.3375 | 0.3316–0.3478 |
| server | 4 | 0.8201 | 0.8066–0.8563 |
| services-one-operation | 1 | 1.2107 | 1.1805–1.2204 |
| services-without-chaos | 1 | 1.3430 | 1.3364–1.3606 |
| transfer | 4 | 0.3307 | 0.3160–0.3369 |

**Retained X1, nested round trip (12da2291).** Rebuilt the prototype and register
convention with Clang `-O2` and pinned TinyCC `e23dabed` (`-O2`, which
TinyCC accepts without optimization). Seven rotated rounds; each
process reports the median of five internal repetitions, at 2,000,000
round trips for Clang and 500,000 for TinyCC. Nanoseconds per nested
round trip (two task switches), with the least and most of the seven
reported medians; every repetition's value is in the raw output. X1's
normal checks pass for all six variants, and its register and noinline
ASan+UBSan checks pass. One-minute load was 1.00.

| X1 build | median ns/round trip | least–most |
|---|---:|---:|
| base_clang | 30.39 | 29.62–30.97 |
| reg_clang | 27.79 | 27.21–28.46 |
| reg_noinl_clang | 37.88 | 37.01–38.39 |
| reg_nochk_clang | 30.16 | 29.66–30.58 |
| base_tcc | 103.22 | 100.69–107.77 |
| reg_tcc | 110.02 | 107.21–115.00 |

**Retained X5, parked tasks (12da2291).** Seven rotated rounds, a fresh Clang `-O2`
process per policy, 100,000 parked tasks. The original experiment uses
Mach and Apple's malloc metrics. [x5/linux.py](../../experiments/runtime-frames/x5/linux.py)
generates a Linux copy outside the repository: `CLOCK_MONOTONIC`,
`malloc_usable_size`, glibc `mallinfo2().uordblks` and `/proc/self/statm`
RSS replace those observations. It also frees the original harness's
bookkeeping arrays after all observations and task checks, fixing its
process-exit leak without changing the measured interval or frame
policies. The original `frames.c` is unchanged. All policies pass
ASan+UBSan+LeakSanitizer at 5,000 tasks, and every measured run reports
`check=ok` with task/chunk counts balanced.

Bytes per parked task: usable live blocks sum only each task and its
chunks, heap is the allocator's live-heap delta, RSS is its second
resident observation's delta. Each cell gives the median and observed
range. Linux RSS and heap are different measures from macOS footprint
and malloc-zone bytes; RSS also includes page effects and lazy
bookkeeping pages. One-minute load was 1.00.

| policy | inline segment | requested task block | usable live blocks | heap delta | RSS delta |
|---|---:|---:|---:|---:|---:|
| today | 64 | 112 | 4224.0 (4224.0–4224.0) | 4240.0 (4240.0–4240.0) | 4256.0 (4256.0–4256.0) |
| static | 192 | 240 | 248.0 (248.0–248.0) | 256.0 (256.0–256.0) | 272.0 (272.0–272.0) |
| static_x | 192 | 240 | 248.0 (248.0–248.0) | 256.0 (256.0–256.0) | 272.0 (272.0–272.0) |
| static_xk | 192 | 240 | 4352.0 (4352.0–4352.0) | 4368.0 (4368.0–4368.0) | 4384.0 (4384.0–4384.0) |

The static chain uses a 192-byte inline segment and a 240-byte requested
task block (248 usable bytes here). After a deep inline excursion,
`static_x` frees its spare at park and keeps that same live-block total;
`static_xk` keeps the spare and reaches 4,352 bytes. These are step 4's
reference observations on this machine.

## Bytes stage, part two, step 4 (part 3) (compiler.md, "Bytes stage, part two", "Step 4 (part 3), as built")

The 4 GiB escape, unboxed map entries, and the fixes that took the
escape's tests off the hot paths. x86_64 cloud container, 4 cores,
shared (another agent building and testing beside it, load 2 to 14),
GCC 13.3 -O2. The measure is **callgrind's instructions a round**,
which don't move with load: each kernel built at R rounds and at 0 by
the same main.ren as build.sh's (strs at R = 1, the slices kernels and
maps at 2), (I(R) - I(0)) / R. Before is 78d2a26, the commit part 3 is
on (step 5b; its slices kernels' C is part 2's, 28c0ac8, to the
instruction); part 3 is 783b3a7; fixed is this commit; step 3 is
30f7db7.

```sh
# each compiler, each kernel k: build at R and 0, count
(cd $dir && $ren build main.ren --release -o $out/$k-$R)      # main.ren as build.sh writes it
valgrind --tool=callgrind --callgrind-out-file=/dev/null $out/$k-$R   # and $k-0
# where the instructions went: the C, -g, per source line, R less 0
$ren build main.ren --release --emit-c > p.c
cc -O2 -ffp-contract=off -g p.c -o p -lm -lpthread
valgrind --tool=callgrind --callgrind-out-file=p.cg ./p
callgrind_annotate --auto=yes p.cg
# a bound: the same C with ren_sv_is_escape returning 0
```

| kernel | step 3 | before | part 3 | fixed | part 3 / before | fixed / before | fixed / step 3 |
|---|---|---|---|---|---|---|---|
| tok | 323.2 | 171.5 | 177.0 | 171.9 | 1.032 | 1.002 | 0.53 |
| sort | 4355.8 | 1636.9 | 1630.2 | 1629.1 | 0.996 | 0.995 | 0.37 |
| map | 5167.0 | 4104.6 | 4212.1 | 4074.1 | 1.026 | 0.993 | 0.79 |
| group | 4524.5 | 3910.1 | 3915.4 | 3979.4 | 1.001 | 1.018 | 0.88 |
| logs | 3078.5 | 1888.6 | 1931.3 | 1898.5 | 1.023 | 1.005 | 0.62 |
| json_1m | 2195.2 | 2227.1 | 2170.0 | 2180.4 | 0.974 | 0.979 | 0.99 |
| logfmt_1m | 954.6 | 1145.9 | 1130.9 | 1132.9 | 0.987 | 0.989 | 1.19 |
| slices_logs | 358.6 | 205.8 | 216.8 | 187.7 | 1.053 | 0.912 | 0.52 |
| slices_logs_r | 204.2 | 208.9 | 213.9 | 212.4 | 1.024 | 1.017 | 1.04 |
| slices_json | 736.5 | 313.5 | 332.0 | 325.5 | 1.059 | 1.038 | 0.44 |
| slices_json_r | 285.8 | 329.0 | 341.3 | 337.4 | 1.037 | 1.026 | 1.18 |
| slices_pages | 94.8 | 31.9 | 37.4 | 36.2 | 1.174 | 1.136 | 0.38 |
| slices_pages_r | 23.1 | 24.0 | 25.4 | 25.4 | 1.061 | 1.061 | 1.10 |
| maps | 290.7 | 294.9 | 295.9 | 295.6 | 1.004 | 1.002 | 1.02 |

Fix by fix (compiler.md has what each is), M instructions a round:
slices json 332.0 to 326.6 at (1), the checks against the length field;
slices logs 226.3 to 188.3 at (2), a loop's `len` hoisted (226.3, not
216.8, since (1) had moved its loop's C); tok 176.5 to 171.9 at (3),
`==` by length fields; logs 1935.5 to 1898.5 and slices pages 37.2 to
36.2 at (5), runs of counts merged (with both branches inline instead,
logs went to 2178.5); group 4011.7 to 3972.9 and map 4113.9 to 4073.9
at (6), a set's key read once. Tried and dropped: `at`'s escape read
out of line (pages_r 25.4 to 29.1), or as a `pure` function (more
than inline even with the index's range assumed); a map probe comparing length fields first (group
4024.0 to 4059.2). With every escape test made `false` in the fixed C,
json_r is 317.5 and group 3881.2: what's left on them is the tests.

**Wall time**, before against fixed, 7 runs interleaved and rotated
(`python3 -I bench/native/strs/ab.py <before> <fixed> 7 tok:1 sort:1
map:1 group:1 logs:1 json_1m:1 logfmt_1m:1 slices_logs:2 ...`), ms a
round and the R runs' spread: at these rounds every spread is wider
than the difference, so these say nothing either way, and the
instructions above are the measure.

| kernel | before | fixed | fixed / before |
|---|---|---|---|
| tok | 31.5 (98-150) | 39.4 (100-155) | 1.25 |
| sort | 409.8 (686-797) | 396.8 (691-786) | 0.97 |
| map | 1732.7 (2807-3195) | 1247.4 (2353-2753) | 0.72 |
| group | 353.6 (1185-1394) | 387.4 (1187-1387) | 1.10 |
| logs | 293.4 (1033-1333) | 288.5 (1317-1450) | 0.98 |
| json_1m | 243.3 (1354-1641) | 234.1 (1330-1508) | 0.96 |
| logfmt_1m | 214.6 (1398-1575) | 149.1 (1464-1643) | 0.69 |
| slices_logs | 22.8 (128-170) | 17.1 (128-145) | 0.75 |
| slices_logs_r | 18.4 (122-145) | 15.9 (121-144) | 0.87 |
| slices_json | 83.3 (270-363) | 90.5 (292-362) | 1.09 |
| slices_json_r | 70.5 (254-312) | 75.3 (250-311) | 1.07 |
| slices_pages | 2.8 (160-266) | 3.9 (163-181) | 1.41 |
| slices_pages_r | 6.6 (148-224) | 9.2 (164-233) | 1.39 |
| maps | 102.8 (188-247) | 106.9 (205-325) | 1.04 |

**Peak RSS** (KB, `/usr/bin/time -f %M`, one run each, the binaries
above): step 3 against fixed, tok 70,136 / 37,372, sort 100,084 / 81,656,
map 214,784 / 215,860, group 198,796 / 198,900, logs 409,584 / 276,724,
json_1m 431,480 / 344,048, logfmt_1m 539,512 / 406,644, slices json
189,108 / 106,220, maps 48,076 / 51,776 (+7.7%, entries of two-word
keys), the other slices kernels the same within 0.1%; before part 3
the same as fixed but maps, 48,060.

**The owner's header**: the kernels built with `REN_CFLAGS=-DREN_OWNER_PAD=0`
and `=16` by part 3's tree with an owner 16 bytes larger (`ren_str_size`,
an experiment, not kept), at tok 10, sort 5, map 5, group 5 and maps 20
rounds, 3 runs of each interleaved, twice (part 3's and this one's):

| kernel | RSS, pad 0 | RSS, pad 16 | a 16-byte owner saves | s, pad 0 | s, pad 16 |
|---|---|---|---|---|---|
| map | 215,816-215,828 | 218,692-218,964 | 1.4% | 7.54-9.23 | 7.84-10.75 |
| maps | 51,600-51,772 | 54,720-54,848 | 5.6% | 2.50-3.51 | 3.08-3.80 |
| group | 198,892-198,932 | 198,936-198,964 | 0.0% | 3.21-3.73 | 2.92-3.98 |
| tok, sort | 37,228-37,444; 82,284-82,412 | 37,344-37,348; 82,292-82,404 | 0.0% | | |

## Bytes stage, part two, step 4, part 2 (compiler.md, "Bytes stage, part two", "Step 4 (part 2), as built")

The uncounted view, lent element reads, `lend_parts` again, and runs of
one root dropped at once when an array is freed. x86_64 cloud container,
4 cores, shared (other agents building beside it), GCC 13.3 -O2,
rustc 1.97.0, **wall time** (no cycle counters here; `perf` isn't
installed), and **callgrind's instruction counts**, which don't move
with load. Before is 3b649c6 (part one), built by that commit's `ren`;
after is this commit's. ms a round, (median at R rounds - median at 0)
/ R, interleaved and rotated, the R runs' spread in brackets.

```sh
sh bench/native/strs/build.sh $before   # REN=<3b649c6's ren>
sh bench/native/strs/build.sh $after
python3 -I bench/native/strs/ab.py $before $after 7 tok:10 sort:5 map:5 group:5 logs:5 \
  json_1m:5 json_plus_1m:5 logfmt_1m:5 logfmt_plus_1m:5 slices_logs:20 slices_logs_r:20 \
  slices_json:20 slices_json_r:20 slices_pages:20 slices_pages_r:20 maps:20
# instructions a round: (I at R - I at 0) / R, each binary once
valgrind --tool=callgrind --callgrind-out-file=/dev/null $after/slices_json-20   # and -0
```

The slices parsers at 20 rounds are 5 to 100 ms over 0-round runs of
100 to 190 ms, which this machine's noise swamps (pages_r, the same C,
came out 0.81 and 1.23 of itself), so they were also built at more
rounds, json 60, logs 100, pages 200 and 1,000, by the same main.ren as
build.sh's with the count changed, and timed beside slices' Rust twin at
the same rounds (`slices-rust 200000 <rounds> <parser>`), 11 runs.

| kernel | before | after | after / before | instructions a round, M | after / Rust (Rust) |
|---|---|---|---|---|---|
| tok | 38.63 (446-523) | 36.35 (379-548) | 0.94 | 205.5 / 171.4 (0.83) | |
| sort | 433.71 (2434-2767) | 446.51 (2321-2635) | 1.03 | 1652.9 / 1618.4 (0.98) | |
| map | 1921.2 (9989-12022) | 1793.4 (9880-10914) | 0.93 | 4049.7 / 3968.9 (0.98) | |
| group | 446.40 (2911-3343) | 430.25 (2842-3251) | 0.96 | 4017.4 / 4002.4 (1.00) | |
| logs | 273.38 (2074-2466) | 237.14 (2106-2482) | 0.87 | 1967.0 / 1898.0 (0.96) | |
| out json, 1M, `+=` | 253.61 (2260-2621) | 260.15 (2433-2714) | 1.03 | 2398.0 / 2226.1 (0.93) | |
| out json, 1M, `a + b` | 321.11 (2765-3175) | 305.85 (2695-2876) | 0.95 | 3323.7 / 3061.9 (0.92) | |
| out logfmt, 1M, `+=` | 170.65 (2142-2327) | 182.36 (2128-2375) | 1.07 | 1204.7 / 1161.9 (0.96) | |
| out logfmt, 1M, `a + b` | 193.93 (2161-2380) | 181.14 (1987-2294) | 0.93 | 1188.7 / 1141.9 (0.96) | |
| slices logs, 100 rounds | 19.38 (1850-2343) | 19.12 (1860-2130) | 0.99 | 206.4 / 205.2 (0.99) | 1.41 (13.60) |
| slices logs_r, 100 | 19.82 (1975-2514) | 17.92 (1787-1962) | 0.90 | 227.7 / 218.2 (0.96) | 0.91 (19.74) |
| slices json, 60 | 100.15 (5963-6404) | 91.62 (5426-6114) | 0.91 | 423.1 / 310.9 (0.73) | 1.39 (65.84) |
| slices json_r, 60 | 83.57 (4906-5418) | 82.72 (5011-5550) | 0.99 | 328.8 / 328.7 (1.00) | 2.08 (39.85) |
| slices pages, 1000 | 5.253 (5154-5603) | 4.476 (4217-5032) | 0.85 | 50.8 / 31.2 (0.61) | 1.97 (2.273) |
| slices pages_r, 1000 | 3.669 (3457-4088) | 3.630 (3457-4165) | 0.99 | 23.1 / 23.1 (1.00) | 1.82 (1.992) |
| maps | 146.14 (2612-3124) | 134.80 (2627-4167) | 0.92 | 310.2 / 296.2 (0.96) | |

Against their `_r` forms, after: json 1.11, logs 1.07, pages 1.23.
Other runs of the same binaries: pages 1.19 (9 runs), 1.28 (15) and
1.28 (9, 1000 rounds); logs 1.10 and 1.11 (15 and 9); json 1.11 and
1.12. Pages against Rust: 2.05 and 2.15 in the other runs. Pages' gap to
`_r` is the free walk: the same binary with `ren_release_elems` skipped
(an experiment that leaks the root) runs 0.3 to 0.6 ms a round faster,
about what's left.

**Fix by fix** (`python3 -I abn.py 9 hb,h1,h2,ha,h3 slices_json:60
slices_json_r:60 slices_pages:200 slices_pages_r:200 slices_logs:100
slices_logs_r:100`, a loop like ab.py's over five build directories,
each built by `ren` at that fix; instructions at 2 rounds minus 0):

| | part one | (1) view | (2) lent elements | (3) `lend_parts` | (4) runs | (5) loops |
|---|---|---|---|---|---|---|
| json, ms | 111.06 (6300-7216) | 107.13 (6323-7699) | 104.39 (5709-6778) | 102.89 (5951-7072) | 100.96 (5921-6776) | 98.88 (5792-6777), 11 runs, part one 104.94 |
| json, M instructions | 425.8 | 425.5 | 366.3 | 367.9 | 345.5 | 313.5 |
| json_r, ms | 87.64 | 87.74 | 88.88 | 87.85 | 88.33 | 88.04 |
| pages, ms | 5.877 (1222-1813) | 6.112 (1264-1512) | 5.718 (1125-1485) | 5.094 (1095-1446) | 4.981 (1059-1394) | 4.934 (987-1627), 11 runs, part one 5.947 |
| pages, M instructions | 51.2 | 50.0 | 40.6 | 39.0 | 36.0 | 31.9 |
| pages_r, ms | 3.931 | 3.652 | 3.910 | 3.831 | 3.884 | 4.032 |
| logs, ms | 21.79 (2158-2760) | 20.57 (2049-2324) | 20.14 (2051-2400) | 21.21 (2040-2349) | 20.91 (1966-2316) | |
| logs, M instructions | 196.4 | 205.8 | 205.8 | 205.8 | 205.8 | |

logs' instructions rise at (1) on C that only lost counts: GCC compiles
`logs`' byte loop, unchanged, to more instructions a byte, as it does
`group`'s byte loop after (4) and (5) (same Ren C, 576 million more
instructions on that one loop's line, `callgrind_annotate` of a `-g`
build of the emitted C; the free loop out of line didn't undo it).

**The rest of bench/native, once** (5 runs, `rest.py`, each program's
main.ren): binary-trees 1.04, blocks 0.96, bytes 0.99, cfold 1.01,
deriv 1.02, dispatch 0.90, fannkuch 1.06, frames 0.93, handlers 1.02,
inout 0.99, interp 0.84, nbody 1.05, nested 0.99, nqueens 0.99, rbtree
1.01, stack 1.02, vec 1.04. Their C is the same but for the runtime and
an element read's `dup` moved in dispatch and stack; callgrind gives
fannkuch, vec, blocks, nested and nbody the same instructions within
0.01% (fannkuch 22,505,571,626 and 22,505,571,641): noise and placement.
`-DREN_RC_SHARED` wasn't measured again; this part makes fewer counts.

## Bytes stage, part two, step 4, part 1 (compiler.md, "Bytes stage, part two", "Step 4 (part 1), as built")

Representation B in release builds: a `Str` or `Bytes` is two words, a
root and a range, kept inline in locals, records, arrays and an object's
fields declared one; a slice allocates nothing. The machine is step 3's:
an x86_64 cloud container, 4 cores, shared, GCC 13.3 -O2, clang 18.1.3,
rustc 1.97.0, go 1.24.7, **wall time** (no cycle counters here), numbers
for ratios, which the owner re-measures on the M4 Max. Before is
bb005eb (step 3 and the services stage's step 4), built by that commit's
`ren`; after is this commit's. ms a round, (median at R rounds - median
at 0) / R, 7 runs interleaved and rotated, the R-round runs' spread in
brackets:

```sh
sh bench/native/strs/build.sh $before   # REN=<bb005eb's ren>
sh bench/native/strs/build.sh $after
python3 -I bench/native/strs/ab.py $before $after 7 tok:10 sort:5 map:5 group:5 logs:5 \
  json_1m:5 json_plus_1m:5 logfmt_1m:5 logfmt_plus_1m:5 slices_logs:20 slices_logs_r:20 \
  slices_json:20 slices_json_r:20 slices_pages:20 slices_pages_r:20 maps:20
KERNELS=tok,sort,map,group,logs,json_1m,logfmt_1m,slices_logs,slices_logs_r,slices_json,slices_json_r,slices_pages,slices_pages_r,maps \
  python3 -I bench/native/strs/measure.py $after 7 final.jsonl
SHARED=1 WHO=ren KERNELS=tok,sort,logs,slices_json,slices_pages python3 -I bench/native/strs/measure.py $after 5
```

| kernel | before | after | after / before | Rust (measure.py) | after / Rust |
|---|---|---|---|---|---|
| tok | 57.43 (588-704) | 37.51 (422-535) | **0.65** | 27.56 | 1.51 |
| sort | 1427.7 (7066-8009) | 503.1 (2658-3292) | **0.35** | 211.8 | 2.17 |
| map | 2454.8 (12513-14945) | 2081.0 (10232-12891) | **0.85** | 1082.7 (FxHash), 1488.9 (std) | 1.88 / 1.37 |
| group | 533.4 (2821-4088) | 535.4 (2946-3876) | **1.00** (11 runs: 0.85) | 426.8 (FxHash), 478.1 (std) | 1.06 / 0.95 |
| logs | 423.8 (3208-4024) | 263.2 (2292-2832) | **0.62** | 259.3 | 1.19 |
| out json, 1M, `+=` | 334.9 (2654-3358) | 271.4 (2564-3408) | 0.81 | 214.5 | 1.22 |
| out json, 1M, `a + b` | 378.2 (3091-4149) | 349.5 (2807-3436) | 0.92 | | |
| out logfmt, 1M, `+=` | 209.7 (2611-2997) | 177.1 (2179-2714) | 0.84 | 151.6 | 1.25 |
| out logfmt, 1M, `a + b` | 184.0 (2401-2838) | 177.4 (2176-2588) | 0.96 | | |
| slices logs | 30.49 (681-963) | 19.32 (464-555) | 0.63 | 15.09 | 1.48 |
| slices logs_r | 19.91 (417-570) | 20.54 (466-654) | 1.03 | 22.19 | 0.93 |
| slices json | 153.4 (3103-3319) | 105.1 (2128-2630) | 0.69 | 71.19 | 1.46 |
| slices json_r | 82.39 (1716-1987) | 85.70 (1730-2005) | 1.04 | 43.72 | 1.96 |
| slices pages | 15.48 (359-667) | 6.48 (271-369) | 0.42 | 2.69 | 2.82 |
| slices pages_r | 5.24 (232-294) | 5.47 (228-311) | 1.04 | 2.63 | 1.78 |
| maps | 158.2 (2563-3829) | 172.9 (2920-3902) | 1.09 (11 runs: 1.02) | 152.2 (FxHash) | 1.13 |

The Rust column is measure.py's run, its own medians, with the after
build beside the twins; "after / Rust" divides that run's Ren by its
Rust (tok 41.62, sort 459.7, map 2032.4, group 452.5, logs 308.8, json
1M 261.0, logfmt 1M 189.9, slices logs 22.34 and logs_r 20.66, json
103.96 and json_r 85.82, pages 7.59 and pages_r 4.67, maps 172.5).
The slices kernels against their `_r` forms: logs 0.94 (ab.py) and 1.08
(measure.py), json 1.23 and 1.21, pages 1.18 and 1.63: pages' rounds are
5 to 8 ms over 0-round runs of 170 to 190 ms, so its spread is wide;
fifteen runs (`ab.py ... 15 slices_pages:20 slices_pages_r:20
slices_json:20 slices_json_r:20`, before `lend_parts`) gave pages 7.83
against 4.62 and json 118.65 against 86.39.

**Fix by fix.** (1) B itself, the layout and the runtime's functions
(3 runs, the first build against before): tok 0.69, sort 0.38, map
0.92, group 1.06, logs 0.69, slices logs 0.73, json 0.76, pages 0.38.
(2) A literal's two words counted as the constant they are (rc.ml's
`Static`), and a map's key boxed only when the map keeps it
(`ren_map_set_sv`): slices json 0.87 of (1) (5 runs), group 1.06 to
1.01 of before. (3) `lend_parts` (rc.ml), the count and drop around a
struct made of a field's part only read: against (2), 7 runs, pages
0.71, json 0.91, tok 1.00, logs 0.99, slices logs 1.02. Tried and not
kept: dropping a run of one root's elements at once when an array of
strings is freed cut 19% of slices json's instructions (callgrind) and
nothing of its time (0.99); a struct aliased to its one counted slot
freed a string as an object, since Perceus's parts are by slot.

**The clang fault** (VERIFY.md, problem 1). Built with
`REN_CC=clang`, logs (7 runs, `ab.py`): before 408.4 (2864-3329),
after 298.4 (2038-2478), **0.73**; with an empty `asm` on the index in
`ren_buf_byte` (an experiment, `-DREN_LSR_BARRIER`, not kept) 289.2
against 288.7, 1.00. The scan in `field_end`, inlined into `records`,
steps 11 to 14 induction variables a byte, with spills, in clang's
output before and after (`clang -O2 -S` of the `--emit-c` build.sh
writes beside each binary); every other kernel's inner loops step 4 or
fewer. So it isn't B's, and hoist.ml's length and data read into two
locals before the loop didn't cure it.

**Hot roots, uncounted contention** (`-DREN_RC_SHARED`, 5 runs, plain
against shared): tok 42.2 / 38.7, sort 495.0 / 478.2, logs 291.8 /
285.3, slices json 102.8 / 117.3 (1.14×), pages 10.3 / 8.4. Only json,
which counts its root most, costs more than noise.

**The rest of bench/native, once** (5 runs interleaved, each program's
main.ren, before and after, ms, `python3 -I rest.py`, a loop like
ab.py's over `<name>-before` and `<name>-after`): binary-trees 0.93,
blocks 1.08 (11 runs: 0.92), bytes 1.01, cfold 1.03, deriv 1.00,
dispatch 1.11 (0.98), fannkuch 1.01, frames 0.99, handlers 1.17 (0.95),
inout 0.99, nbody 1.02, nested 1.04, nqueens 1.06 (1.02), rbtree 1.02,
stack 0.98, vec 1.10 (0.99), and interp 1.29 (11 runs: 1.35, 129 against
174 ms). interp's `eval` is the same machine code before and after, at
another address (0x7c20, 0x9810), 878.8M instructions in callgrind in
both: a placement effect, not B, whose program only prints a number.

## Bytes stage, part two, step 3 (compiler.md, "Bytes stage, part two", "Step 3, as built")

Appending in place, on representation A: `+=`, and `a + b` where `a`
dies, write into a unique owner's room, growing it by doubling. The
machine is the baseline's: an x86_64 cloud container, 4 cores, shared,
GCC 13.3 -O2, rustc 1.97.0, go 1.24.7, **wall time** (no cycle counters
here), numbers for ratios, which the owner re-measures on the M4 Max.
The `out` rows' R changed now that they're linear: 100 rounds at 5,000
records, 10 at 50,000, 5 at 1M (the Ren 1M rows are new). Seven runs,
interleaved and rotated, ms a round, the R-round runs' spread in
brackets:

```sh
sh bench/native/strs/build.sh $out
KERNELS=json_append_5k,json_plus_5k,logfmt_append_5k,logfmt_plus_5k,json_append_50k,json_plus_50k,logfmt_append_50k,logfmt_plus_50k,json_1m,json_plus_1m,logfmt_1m,logfmt_plus_1m \
  python3 -I bench/native/strs/measure.py $out 7 out.jsonl
KERNELS=json_held_5k,json_held_50k python3 -I bench/native/strs/measure.py $out 3 held.jsonl
```

| records | Ren json, `+=` | Ren json, `a + b` | Ren logfmt, `+=` | Ren logfmt, `a + b` | Rust json | Rust logfmt | Go json | Go logfmt |
|---|---|---|---|---|---|---|---|---|
| 5,000 | 1.23 (122-173 for 100) | 1.90 (156-232) | 0.62 (62-81) | 0.68 (63-87) | 0.82 (76-112) | 0.44 (44-68) | 2.41 | 2.95 |
| 50,000 | 15.97 (199-266 for 10) | 18.94 (225-343) | 6.26 (140-224) | 6.99 (147-210) | 6.70 (110-136) | 5.72 (84-127) | 24.09 | 28.09 |
| 1,000,000 | 285.4 (2800-3476 for 5) | 421.2 (3265-3824) | 194.4 (2502-3081) | 203.8 (2762-3227) | 201.8 (1588-1959) | 182.6 (1377-1745) | 644.8 | 591.1 |

- **`+=` against Rust's `push_str`, 1M records:** logfmt 1.06×, within
  the 1.1× target; **json 1.41×, which misses it.** The baseline was
  860× and 1,640× at 5,000 records.
- **Linear:** 50,000 records take 13.0× (json, `+=`), 10.0× (json,
  `a + b`), 10.1× and 10.3× (logfmt) what 5,000 do; Rust 8.2× and
  13.0×. The baseline's were 340 to 403×.
- **`a + b` in a loop.** `o = o + a + b` appends in place too, since
  `o` dies at its first `+` (compiler.md, "Appending in place"), so
  `_plus` is linear: 1.48× and 1.05× of `+=` at 1M. What stays
  quadratic is a `+` whose left side something else holds: `json_held`,
  `_plus` with the output before the last record kept, takes 54.1 ms a
  round at 5,000 (272-314 for 5) and 19,559 ms at 50,000 (19,546-19,850
  for 1, three runs, while another build ran), 362×. A debug build of it
  prints, at exit:

```
note: this `+` copied its left side on 199 passes, since something else held it
    ┌─ bench.ren:307:5
307 │     o = o + (if r > 0 then "," else "") + "{\"id\":" + show(x.id) + …
    │     ^^^^^^^^^^…
    help: build the string once: join, or keep it unique
```

  (200 records, `main.ren` calling `bench.run_json_held(200, 1)`, built
  `ren build --debug`; the first pass copies the literal `"["`, which
  isn't counted.)

**Where json's 1.41× goes** (callgrind, json at 50,000 for 10 rounds less
0 rounds, 1,065M instructions): the slices `put_json` takes,
`s[run..i]`, each a 32-byte object under A (`ren_str_slice`,
`ren_chars_check`, `ren_str_part` and their frees, 23%), and
`show(x.id)` and `show(x.score)`, each a new string (`ren_show_int`,
12%), which Rust's `write!` puts in the buffer. Appending is
`ren_str_concat_taking`'s fast path, inlined into the loops, and its
`memcpy` (11%, which other copies share). logfmt
appends whole fields and has no slices, and runs at Rust's speed. Step 4's
representation B makes those slices values; the shows stay. Before
`ren_show_int` wrote its own digits it was `snprintf`, a fifth of
json's instructions, and json ran at 1.85× and logfmt 1.23× (one
session, 5 runs).

**Nothing else slowed.** The other strs kernels and the slices and maps
kernels, built at step 2 (86c1e88) and now, interleaved, 7 runs, ms a
round (bench/native/strs/ab.py, below, runs each build's binaries at R
and 0 in turn):

| kernel | step 2 | step 3 | step 3 / step 2 |
|---|---|---|---|
| tok | 50.1 (534-705) | 50.3 (562-706) | 1.00 |
| sort | 1067 (5339-6107) | 1078 (5231-6802) | 1.01 |
| map | 1574 (7898-9843) | 1460 (7866-10156) | 0.93 |
| group | 531.9 (3857-4573) | 555.7 (3345-4821) | 1.04; 11 runs again, 1.01 |
| logs | 447.1 (3854-4914) | 392.2 (3017-3671) | 0.88 |
| utf8 cjk / mixed, ms for 4,000 | 1.13 / 0.52 | 1.12 / 0.52 | 0.99 / 1.01 |
| slices logs / `_r` | 36.7 / 19.6 | 36.4 / 19.2 | 0.99 / 0.98 |
| slices json / `_r` | 133.9 / 88.5 | 149.2 / 84.0 | 1.11 (11 runs again: 1.00) / 0.95 |
| slices pages / `_r` | 12.9 / 3.42 | 11.1 / 3.34 | 0.85 / 0.98 |
| maps | 88.8 | 88.2 | 0.99 |

utf8 ascii's round is under the noise of its 0-round run here. The
input-making runs (0 rounds) got faster where gen.ren builds strings by
`+` (group's from 1,485 to 1,083 ms), so a kernel's round, a difference,
moves with them; the spreads overlap on every row.

```sh
# $before: build.sh at 86c1e88; $after: build.sh now
python3 -I bench/native/strs/ab.py $before $after 7 tok:10 sort:5 map:5 group:5 logs:5 utf8_ascii:4000 utf8_cjk:4000 utf8_mixed:4000 \
  slices_logs:20 slices_logs_r:20 slices_json:20 slices_json_r:20 slices_pages:20 slices_pages_r:20 maps:20
```

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
            Some(i) => t += i.price + i.name.byte_len() + round
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

### Step 3: the perfect hash

The same kernel, the same machine and method (`R=200 sh build.sh
<out>`; `R=200 python3 -I measure.py <out> 11`), with each set's `match`
of literal arms (`<set>_match`), which a release build looks up through
phash.ml's hash and the two-word compare (x86 has no NEON; ren_rt.h's
"string patterns"), beside its `==` chain, and a seventh set, `one`, of
the single key `v1`, whose `match` stays a chain: a length test and a
compare. ns per lookup, median (least to most):

| set | keys | Ren chain | Ren `match` | Rust `match` | Go `switch` | chain / `match` | Rust / Ren `match` |
|---|---:|---:|---:|---:|---:|---:|---:|
| renkw | 35 | 63.9 (60.9 to 68.8) | 7.3 (6.8 to 8.7) | 19.1 (18.5 to 21.8) | 27.4 (26.1 to 30.4) | 8.8 | 2.6 |
| jsreserved | 45 | 78.8 (76.5 to 82.2) | 8.1 (7.4 to 8.9) | 22.0 (20.4 to 24.4) | 27.4 (26.1 to 29.2) | 9.8 | 2.7 |
| methods | 9 | 26.6 (25.0 to 29.6) | 6.6 (6.3 to 9.2) | 16.6 (15.8 to 18.7) | 16.3 (15.3 to 19.9) | 4.0 | 2.5 |
| headers | 20 | 27.7 (25.9 to 29.9) | 7.3 (6.7 to 8.9) | 13.2 (12.1 to 19.7) | 15.0 (13.3 to 16.8) | 3.8 | 1.8 |
| json24 | 24 | 29.7 (29.1 to 32.8) | 7.8 (7.6 to 11.6) | 10.8 (10.2 to 12.3) | 12.2 (11.8 to 13.3) | 3.8 | 1.4 |
| one | 1 | 7.1 (7.0 to 8.7) | 5.5 (5.0 to 7.0) | 2.2 (2.0 to 3.2) | 3.2 (2.9 to 4.0) | 1.3 | 0.4 |

- **Against Rust's `match`:** Ren's `match` is faster on every set of
  two keys or more, 1.4× (json24) to 2.7× (jsreserved). On `one` it's
  2.5 times slower, as the chain is: what's left there is the loop, not
  the compare (below).
- **Against the chain:** 3.8× to 9.8×, against the research's 5.5× to
  8.3×. Each lookup here includes Ren's walk over the queries, a call
  and the reading of each `Str` from the array, which `one` bounds: its
  `match` is a length test and an inline compare, so about 5 ns of its
  5.5 is that loop, which neither form avoids. Less 5 ns each, the chain
  takes 22 to 74 ns and the `match` 1.6 to 3.1, 9× to 25×. The ratios
  that fall short of the research's, methods, headers and json24, are
  the sets whose chain is shortest, where the shared 5 ns is most of
  the `match`'s time.
- **A one-literal arm:** 5.5 ns against the chain's 7.1, so it costs no
  more than the chain did (`ren_pat_is` inline against a call of
  `ren_str_eq`).
- **Code size:** bench/patterns/lexer.ren, release, 211,937 bytes of C
  with step 2's chain, 220,296 with the hash: 8.4 KB for its lookup,
  the two position tables (512 bytes), the slot, length and value tables
  and the keys, 16 bytes and two words a slot, 64 slots.
- **NEON** wasn't measured: this machine is x86, whose release builds
  take the two-word compare. The NEON form is built for arm64 (clang
  18 `--target=aarch64-linux-gnu`, which picks it: `tbl` instructions in
  the assembly) and run under qemu on test_phash.ml's 44,783 queries,
  each at the end of a page with a guard page after it: it agrees with
  the two-word form on every one (compiler.md, "Step 3, as built").

### Step 4: `keys.index(s)` on a constant

The kernel's third form, `<set>_index`: `let keys = [...]` then `match
keys.index(s)`, `Some(i) => i`, `None => -1`, which a release build
lowers to the same lookup as the `match` (compiler.md, "Step 4, as
built"), its array never made. Same machine and method, a later run of
all three forms and the twins (`R=200 sh build.sh <out>`; `R=200
python3 -I measure.py <out> 11`), ns per lookup, median (least to
most):

| set | Ren chain | Ren `match` | Ren `keys.index` | Rust `match` | Go `switch` |
|---|---:|---:|---:|---:|---:|
| renkw | 66.3 (63.1 to 67.9) | 8.0 (7.1 to 11.1) | 7.5 (7.2 to 10.1) | 20.3 (18.8 to 24.6) | 28.5 (27.2 to 30.8) |
| jsreserved | 80.8 (77.0 to 85.3) | 7.8 (7.5 to 11.2) | 7.9 (7.1 to 9.9) | 22.9 (21.1 to 25.3) | 27.9 (26.2 to 30.0) |
| methods | 26.7 (25.7 to 29.3) | 6.9 (6.1 to 9.3) | 6.9 (6.4 to 8.8) | 17.0 (15.7 to 18.6) | 16.0 (15.5 to 17.3) |
| headers | 27.8 (26.2 to 30.9) | 7.5 (6.8 to 8.5) | 9.1 (7.9 to 10.4) | 12.8 (11.7 to 14.5) | 14.8 (13.8 to 17.0) |
| json24 | 30.9 (28.7 to 31.8) | 8.3 (7.6 to 10.8) | 7.9 (7.3 to 9.4) | 12.7 (10.7 to 14.3) | 12.7 (11.6 to 14.3) |
| one | 7.4 (6.8 to 9.3) | 5.3 (5.0 to 6.8) | 5.6 (5.4 to 7.4) | 2.2 (1.9 to 3.2) | 3.2 (3.0 to 4.1) |

`keys.index` runs at the `match`'s speed, within the spread on every
set but headers, where it's 1.6 ns slower (ranges 7.9 to 10.4 against
6.8 to 8.5): the `Option` it makes and the `match` on it, which the
direct `match` doesn't have. This run repeats step 3's within its
spread.

## Generators stage, step 0: current Ren hand loops (2026-10-30)

These are **current Ren programs**, before `gen fn` and pipeline lowering,
not the C-model predictions in streams.md. `streams/bench.ren` supplies
all five Cost workloads: parsing log lines through map/select/take,
a recursive preorder tree walk through select/take, sparse ticks mapped
to halves and deduplicated, two filtered sources zipped and xor-summed,
and a pull block passed to a user function. Each runs at 1,000,000 items
and 20 passes; its round changes state or the checksum calculation so
identical calls cannot be folded into one call. The fixture is smaller
and simpler than E3's 100 MiB log and variable-branching tree; comparisons
below are for this fixture on this machine, not a remeasurement of E3's
published ratios. Native generator performance remains unmeasured.

The Rust uses iterator adapters, a user Dedup struct, an explicit-stack
walk and a boxed recursive walk. Its default log splitter uses libc
`memchr`, as streams.md's Rust column does, in a small documented unsafe
FFI wrapper; `rust-std` separately uses safe `split_terminator`. Input
UTF-8 validation occurs during setup in both Rust log variants. Ren's
`Bytes.index` also reaches libc `memchr`. The Go push forms range directly
over their adapter chains; W5 passes its chain to `total`. Its pull forms
use `iter.Pull`; `go-pull1` pulls the second zip source while ranging the
first, and `go-pull2` pulls both. These forms keep the Cost columns'
choices visible, including the expensive boxed and coroutine cases.

Machine: Linux x86_64, kernel 6.18.57, Intel Xeon Platinum 8573C under
KVM, five visible CPUs with a four-CPU cgroup quota, 16 GiB memory limit.
Compiler baseline `12da2291bbbeee241bbe17bfb501fcd834f617a0`; Clang 23.1.3
at Ren's release flags (`-O2`), rustc 1.99.0 (`-C opt-level=3
-C codegen-units=1`), Go 1.27.3; OCaml 5.5.2 and Dune 3.24.2 built the
compiler. One thread per kernel; Go's runtime/collector uses its default
configuration. Full tests and other compilations were paused for the
measurement. This is shared virtual hardware, with no hardware-counter
or CPU-affinity claim.

The table contains **11 interleaved rounds**, rotated and reversed.
Each implementation is timed once with one pass and once with 20 in
each round; its per-pass estimate is `(time20 - time1)/19`, with the
median and min/max of those 11 paired estimates shown. Using one pass
keeps input generation observably live in the subtraction control.
This estimates the additional pass's cost while removing most input
construction and destruction. The full 20-pass process median and spread
are also shown; all one-pass samples are preserved in the JSON. Ratios
use paired-estimate medians, relative to the Ren hand loop; a ratio is
suppressed if any paired estimate is nonpositive. Wall time and allocation
or GC variation can affect subtraction, so the spread is part of the
result. No warm-up or outlier sample is removed.

Two preliminary runs were discarded before the final 11-round run: one
exposed an extra generic sink boundary in Go's direct push rows, and the
next exposed setup/GC noise from repeatedly growing an unreserved Go
log buffer (including a negative W5 paired estimate). The final twins
reserve the log fixture's known maximum size, as E3 reserved its known
target size. These are source/method corrections; all samples from the
final run, including remaining noise, are retained.

| Workload | Variant | Full process median ms (min–max) | Paired additional-pass median ms (min–max) | / Ren |
|---|---|---:|---:|---:|
| w1 | ren | 758.47 (739.61–843.91) | 16.970 (15.955–18.399) | 1.00 |
| w1 | rust | 275.56 (265.20–295.07) | 8.595 (8.015–9.899) | 0.51 |
| w1 | go-push | 326.24 (314.68–337.51) | 11.871 (11.467–12.651) | 0.70 |
| w1 | rust-std | 518.62 (499.03–551.28) | 20.912 (19.847–22.963) | 1.23 |
| w1 | go-pull | 466.75 (455.63–482.36) | 18.855 (17.987–19.735) | 1.11 |
| w2 | ren | 142.22 (128.58–175.29) | 5.023 (3.782–5.644) | 1.00 |
| w2 | rust-stack | 218.79 (204.34–245.56) | 6.954 (5.074–8.557) | 1.38 |
| w2 | go-push | 184.26 (178.79–191.07) | 5.750 (5.387–6.155) | 1.14 |
| w2 | rust-boxed | 1556.76 (1507.43–1582.71) | 74.279 (71.192–75.456) | 14.79 |
| w2 | go-pull | 536.97 (524.70–596.63) | 23.211 (22.657–25.959) | 4.62 |
| w3 | ren | 31.90 (28.20–36.08) | 1.104 (0.955–1.353) | 1.00 |
| w3 | rust | 26.98 (24.81–33.26) | 0.946 (0.847–1.332) | 0.86 |
| w3 | go-push | 33.67 (32.06–39.12) | 1.155 (0.979–1.556) | 1.05 |
| w3 | go-pull | 173.95 (169.76–245.65) | 8.227 (7.907–11.839) | 7.45 |
| w4 | ren | 87.49 (84.63–101.18) | 3.973 (3.851–4.745) | 1.00 |
| w4 | rust | 51.85 (49.82–69.87) | 2.239 (2.093–3.035) | 0.56 |
| w4 | go-pull1 | 1817.66 (1790.50–1955.40) | 90.418 (88.907–97.429) | 22.76 |
| w4 | go-pull2 | 3515.95 (3474.89–3611.39) | 175.249 (172.907–180.392) | 44.11 |
| w5 | ren | 1010.69 (988.12–1103.26) | 29.761 (27.743–30.809) | 1.00 |
| w5 | rust | 319.89 (305.69–339.93) | 11.007 (9.836–12.520) | 0.37 |
| w5 | go-push | 390.33 (377.37–402.80) | 14.955 (14.406–15.850) | 0.50 |
| w5 | rust-std | 618.39 (607.96–658.01) | 25.810 (25.374–27.708) | 0.87 |

All final paired estimates were positive. Rust's libc log splitter is
about 2.4 times faster than its standard splitter on these inputs; the
choice materially changes the log rows. The boxed tree walk is 14.79×
the Ren hand loop, and Go's zip coroutine forms are 22.76× and 44.11×.
These are measured implementation costs on this fixture; they do not
establish native generator fusion or frame-copy costs. The wider W2/W3
ranges also mean a future 10% generator claim needs fresh interleaved
hand-loop/generator measurements, rather than comparison to these stored
medians alone.

A separate pure backtracking control copies today's explicit cursor
record, or reconstructs it by replay before four speculative steps at
each position. **Replay here is a model, not an implemented generator
runtime.** The 11-round process measurements (rotated/reversed, every
checksum compared between copy/replay) are:

| Positions | Mode | Process median ms (min–max) |
|---|---|---:|
| 5000 | copy | 1.065 (0.967–1.725) |
| 5000 | replay | 55.921 (54.409–59.617) |
| 10000 | copy | 1.133 (1.040–1.379) |
| 10000 | replay | 224.212 (218.855–232.726) |

Doubling positions increases replay's median by 4.01×, exposing its
quadratic reconstruction work. The copy control is dominated by process
startup; its ~1 ms wall time is an upper bound, not a measurement of the
cost of copying a native generator frame. Copy and replay agree at both
sizes, and the interpreter's 50-position control agrees with native.

The small input (200 items, two passes) agrees in the interpreter,
native debug/release, ASan+UBSan release, tcc debug, and all Rust and Go
variants. The separate fork control agrees in those four native builds
and the interpreter too. Full-size native outputs agree with every timed
twin, for both pass counts, and every sample is checked by the timing
driver. The five 20-pass checksums are:

```text
399494187080160
2654077366861184
9761875200
2349267531239758
494872837717524
```

The standalone release C files, including the runtime, are recorded below.
The program-only count starts at `/* ---- the program ---- */` (including
that marker); it separates generated code from the common runtime prefix.
Both counts are source bytes and newline counts, not object or text size.
These are the 20-pass per-kernel entries preserved by build.py.

| Entry | Standalone C bytes | Lines | Program C bytes | Lines |
|---|---:|---:|---:|---:|
| W1 map/select/take | 285,581 | 7,543 | 26,859 | 508 |
| W2 recursive tree walk | 277,978 | 7,439 | 19,256 | 404 |
| W3 user dedup_by | 273,747 | 7,357 | 15,025 | 322 |
| W4 zip | 277,345 | 7,425 | 18,623 | 390 |
| W5 passed pull block | 288,348 | 7,619 | 29,626 | 584 |
| examples/just | unavailable | — | unavailable | — |

`examples/just` was attempted with `ren build main.ren --release --emit-c`
from its folder. It exits 1 with `the real Fs isn't in the native slice
yet` and `help: run it with ren run main.ren`. No C is emitted; its empty
redirected output is not a C-size baseline. This remains a native-stage
limitation independent of generators.

Reproduce from the repository root, in the toolchain shell:

```sh
dune build bin/main.exe
python3 -I bench/native/streams/verify.py
python3 -I bench/native/streams/build.py /tmp/ren-streams
python3 -I bench/native/streams/measure.py /tmp/ren-streams bench/native/streams/results.json --runs 11
python3 -I bench/native/streams/measure_fork.py /tmp/ren-streams bench/native/streams/fork-results.json 11
wc -lc /tmp/ren-streams/w?.c
(cd examples/just && ../../_build/default/bin/main.exe build main.ren --release --emit-c)
```

This session used `/workspace/.ren-tools/with-toolchain` before each
command to enter the pinned Nix toolchain. `REN` selects another compiler.
The build keeps all generated `.ren` entries and emitted `.c` files
outside the checkout, while [streams/results.json](streams/results.json)
keeps every timing sample, checksum, command, source hash, compiler
version and machine metadata. The independent backtracking samples and
commands are in [streams/fork-results.json](streams/fork-results.json).

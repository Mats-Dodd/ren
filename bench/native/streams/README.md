# Stream hand-loop baseline

Step 0 of briefs/stage-generators.md. `bench.ren` expresses streams.md's
five Cost workloads in today's Ren. `main.ren` runs a million items and
20 passes; `small.ren` runs 200 items and two passes. The five output
lines are map/select/take, recursive walk, dedup_by, zip, and a pull block
passed to a function, in that order.

The log fixture has variable-length ASCII lines, a level, and nine decimal
id digits. Each pass parses every line before selecting errors (1/20);
W1 takes n/25 errors, W5 consumes all. W2 walks a balanced binary tree
preorder, selects values divisible by seven, and takes n/8. W3 scans
sparse 0/1 deltas, halves the running tick, removes adjacent duplicates,
and sums. W4 zips a range excluding multiples of three with an array
excluding negative values, then sums xor. All input generators agree
across languages. Salt varies by pass and affects the checksum, which
prevents repeated kernels being folded into one evaluation.

Rust uses iterator adapters, an explicit frame stack (and optional boxed
recursive iterator), a user Dedup iterator, zip, and a generic total
function. Its default lines iterator uses libc memchr like the Cost table;
that requires a documented unsafe FFI wrapper, an exception to the usual
native benchmarks' safe Rust convention. The `std` variant measures
split_terminator separately. Go uses iter.Seq and range-over-func;
`pull` uses iter.Pull, including one pulled side for zip, and `pull2`
pulls both sides. Go W5 passes iter.Seq to total. These are the Cost
columns' implementations, with a smaller deterministic fixture; absolute
ratios are not expected to reproduce the Apple M4 C-model measurements.

Build and measure from a shell with Ren's toolchain on PATH:

```sh
python3 -I bench/native/streams/build.py /tmp/ren-streams
python3 -I bench/native/streams/measure.py /tmp/ren-streams /tmp/ren-streams/results.json --runs 11
```

REN selects the compiler (default _build/default/bin/main.exe). The build
script preserves each entry, the five release C files, and config.json.
It builds per-kernel binaries for one and 20 passes. Timing follows
bench/native/profile's subtraction method, using one pass rather than
zero so setup's input remains observably used. Additional-pass time is the median of the per-round paired differences
(20-pass time - one-pass time)/19; its min/max and the raw full-process
median and min/max are reported beside it. This removes most setup/drop
cost but remains an estimate. Ratios are suppressed if any paired
difference is nonpositive. Every timed output is checked against Ren. Runs are
rotated and reversed to interleave implementations and baseline/full cases.
The JSON preserves raw samples and commands. Measure with no compiler or
full test suite running. No hardware-counter claim is made.

`fork.ren` adds a separate backtracking control: an explicit pure cursor
record copied at each position, with four speculative steps. Its replay
mode reconstructs that record from the beginning before probing. Both
return the same checksum. This models the O(position) replay-copy trap
called out in the synthesis; it does not measure an implemented generator
runtime, and is kept apart from the five Cost rows. `fork_small.ren`
checks both paths at 50 positions.

Small-size verification (interpreter, debug, release, ASan+UBSan release,
tcc debug, and every twin variant) is reproducible with:

```sh
python3 -I bench/native/streams/verify.py
```

The build also writes separate 5,000- and 10,000-position backtracking
controls. Time them independently with:

```sh
python3 -I bench/native/streams/measure_fork.py /tmp/ren-streams /tmp/ren-streams/fork-results.json 11
```

The copy control's process startup is larger than its kernel, so its wall
time is an upper bound rather than a frame-copy cost. The replay control
makes reconstruction's scaling visible. Measured tables and emitted C
sizes are in [RESULTS.md](../RESULTS.md); raw samples are preserved in
[results.json](results.json) and [fork-results.json](fork-results.json).

# String `match` as a perfect hash: results

Track B. Ren `match` on string literals, compiled the way Lemire's
ConstexprCore/perfect_hash does it, measured on the M4 Max against what
Ren emits today, rustc, gperf and a general hash map.

## Findings

1. **Ren has no string literal patterns today.** `"GET" =>` is a parse
   error ("expected a pattern, found the string"). Code writes an `==`
   chain. `--release --emit-c` turns it into nested `if`s calling
   `ren_str_eq` once per arm: a length test, then `memcmp`
   (code/ren/m2.ren, code/ren/m2.full.c, `ren_m2_code_1`).
2. **The perfect hash with a 16-byte NEON compare is 5 to 9 times faster
   than Ren's chain on random traffic.** On the seven key sets it took
   0.87 to 1.57 ns a lookup. The chain took 5.3 to 13.6 ns. rustc's
   `match` took 3.4 to 13.7 ns. gperf took 6.0 to 11.8 ns. A general hash
   map took 6.7 to 15.4 ns. 20 HTTP headers took 1.29 ns, which matches
   Lemire's ~1.3 ns on the M3 Max.
3. **The win is branch prediction, not instruction count.** The perfect
   hash runs about as many instructions as the chain (24 to 33 against 23
   to 50), but at 6 to 9 instructions a cycle against about 1. Random
   keys make the chain's branches unpredictable. The hash form has no
   data-dependent branch on a hit.
4. **It still wins on skewed traffic.** With 70% GET and 20% POST, the
   chain took 3.5 ns, rustc 1.5 ns, the hash 0.97 ns.
5. **It wins from 2 keys up.** With 1 key, a plain length test and
   compare is best (0.34 ns against 0.41 to 0.51 ns). With 2 keys the
   hash takes 0.87 ns and the chain 1.7 ns.
6. **The page check costs nothing measurable.** Lemire's page-boundary
   check before the 16-byte load adds about 3 instructions and no time.
   On one set (renkw) the check-free form was slower (1.20 against
   1.04 ns); elsewhere they're within the spread. So the runtime doesn't
   need to promise padding to get this speed.
7. **The compare is what matters, not the hash.** The same hash with
   `memcmp` for the compare took 4.9 to 10 ns, barely ahead of the chain.
   A variable-length `memcmp` is a call with its own branches. The
   compare has to be a fixed-width load, mask and compare.
8. **A portable form exists.** Two 8-byte words, masked by length and
   compared as integers, need no intrinsics. It took 1.0 to 2.0 ns,
   within 1.3x of NEON. It needs the same over-read guarantee (or the
   same page check).
9. **The generator always found a hash.** All 11 sets got one with 0, 1 or
   2 byte positions and a table of next_pow2(n) slots. None needed the
   fallback. It runs in a few milliseconds.

## Main table: ns per lookup

Random order, 90% hits, 10% near misses (one byte changed, or a byte
added). Mean of 25 hyperfine runs minus the empty loop, ± combined
standard deviation. "phash" is this work.


| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 10.21 ± 0.13 | 11.30 ± 0.16 | 13.64 ± 0.49 | 9.93 ± 0.02 | 7.20 ± 0.22 | 5.33 ± 0.11 | 8.00 ± 0.30 |
| length switch + memcmp (C) | 10.07 ± 0.12 | 11.34 ± 0.24 | 12.27 ± 0.28 | 9.98 ± 0.09 | 6.97 ± 0.22 | 5.22 ± 0.06 | 7.66 ± 0.28 |
| Rust `match` (rustc) | 8.43 ± 0.34 | 10.69 ± 0.18 | 13.65 ± 0.41 | 6.74 ± 0.30 | 6.91 ± 0.15 | 3.43 ± 0.23 | 7.35 ± 0.32 |
| gperf 3.0.3 | 10.39 ± 0.16 | 11.75 ± 0.17 | 10.12 ± 0.12 | 9.87 ± 0.13 | 6.06 ± 0.15 | 5.37 ± 0.11 | 6.01 ± 0.14 |
| hash map (FNV-1a, open addr.) | 11.42 ± 0.16 | 15.42 ± 0.15 | 13.69 ± 0.24 | 11.22 ± 0.17 | 8.74 ± 0.14 | 6.69 ± 0.14 | 7.30 ± 0.20 |
| phash + memcmp | 8.06 ± 0.13 | 9.96 ± 0.12 | 8.80 ± 0.16 | 8.42 ± 0.05 | 5.44 ± 0.12 | 4.91 ± 0.12 | 5.50 ± 0.14 |
| phash + 2 words (padded) | 1.75 ± 0.02 | 1.62 ± 0.01 | 2.00 ± 0.02 | 1.79 ± 0.03 | 1.03 ± 0.02 | 1.07 ± 0.03 | 1.06 ± 0.02 |
| phash + NEON, page check | 1.55 ± 0.03 | 1.29 ± 0.02 | 1.52 ± 0.01 | 1.57 ± 0.01 | 0.90 ± 0.02 | 1.09 ± 0.01 | 1.04 ± 0.02 |
| phash + NEON, padded | 1.62 ± 0.04 | 1.27 ± 0.02 | 1.54 ± 0.03 | 1.54 ± 0.02 | 0.87 ± 0.02 | 1.08 ± 0.01 | 1.20 ± 0.03 |


Relative to phash + NEON with the page check (ratio of means, ± spread):


| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 6.6x ± 0.2 | 8.8x ± 0.2 | 9.0x ± 0.3 | 6.3x ± 0.0 | 8.0x ± 0.3 | 4.9x ± 0.1 | 7.7x ± 0.3 |
| length switch + memcmp (C) | 6.5x ± 0.2 | 8.8x ± 0.2 | 8.1x ± 0.2 | 6.4x ± 0.1 | 7.8x ± 0.3 | 4.8x ± 0.1 | 7.3x ± 0.3 |
| Rust `match` (rustc) | 5.4x ± 0.2 | 8.3x ± 0.2 | 9.0x ± 0.3 | 4.3x ± 0.2 | 7.7x ± 0.3 | 3.1x ± 0.2 | 7.0x ± 0.3 |
| gperf 3.0.3 | 6.7x ± 0.2 | 9.1x ± 0.2 | 6.6x ± 0.1 | 6.3x ± 0.1 | 6.7x ± 0.2 | 4.9x ± 0.1 | 5.8x ± 0.2 |
| hash map (FNV-1a, open addr.) | 7.4x ± 0.2 | 12.0x ± 0.2 | 9.0x ± 0.2 | 7.2x ± 0.1 | 9.7x ± 0.3 | 6.1x ± 0.1 | 7.0x ± 0.2 |
| phash + memcmp | 5.2x ± 0.1 | 7.7x ± 0.1 | 5.8x ± 0.1 | 5.4x ± 0.1 | 6.1x ± 0.2 | 4.5x ± 0.1 | 5.3x ± 0.2 |
| phash + 2 words (padded) | 1.1x ± 0.0 | 1.3x ± 0.0 | 1.3x ± 0.0 | 1.1x ± 0.0 | 1.1x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 |
| phash + NEON, page check | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 |
| phash + NEON, padded | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.0x ± 0.0 | 1.1x ± 0.0 |


Instructions per lookup (hyperfine's counters, minus the empty loop):


| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 25.3 | 31.4 | 50.2 | 23.4 | 32.0 | 22.8 | 41.3 |
| length switch + memcmp (C) | 26.2 | 34.3 | 44.5 | 26.7 | 34.3 | 23.5 | 41.6 |
| Rust `match` (rustc) | 16.7 | 26.3 | 36.7 | 15.7 | 27.6 | 15.5 | 34.0 |
| gperf 3.0.3 | 53.0 | 54.7 | 54.9 | 53.2 | 55.2 | 53.3 | 55.7 |
| hash map (FNV-1a, open addr.) | 76.8 | 98.0 | 79.1 | 79.7 | 92.3 | 66.9 | 71.9 |
| phash + memcmp | 47.7 | 48.6 | 51.6 | 44.8 | 44.1 | 45.6 | 48.4 |
| phash + 2 words (padded) | 25.4 | 27.2 | 34.8 | 27.2 | 35.5 | 25.3 | 28.2 |
| phash + NEON, page check | 27.4 | 27.2 | 33.0 | 27.2 | 32.7 | 27.3 | 30.2 |
| phash + NEON, padded | 24.4 | 24.3 | 30.1 | 24.3 | 29.9 | 24.4 | 27.3 |


Instructions per cycle:


| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 1.0 | 1.1 | 1.4 | 0.9 | 1.0 | 1.0 | 1.2 |
| length switch + memcmp (C) | 1.0 | 1.2 | 1.4 | 1.0 | 1.1 | 1.0 | 1.3 |
| Rust `match` (rustc) | 0.8 | 0.9 | 1.0 | 0.9 | 1.0 | 1.0 | 1.2 |
| gperf 3.0.3 | 2.0 | 1.8 | 2.1 | 2.1 | 2.2 | 2.3 | 2.2 |
| hash map (FNV-1a, open addr.) | 2.6 | 2.4 | 2.2 | 2.7 | 2.5 | 2.3 | 2.3 |
| phash + memcmp | 2.3 | 1.9 | 2.3 | 2.0 | 1.9 | 2.1 | 2.1 |
| phash + 2 words (padded) | 5.6 | 6.4 | 6.7 | 5.8 | 8.7 | 5.9 | 6.6 |
| phash + NEON, page check | 6.8 | 8.1 | 8.3 | 6.6 | 9.1 | 6.3 | 7.2 |
| phash + NEON, padded | 5.8 | 7.3 | 7.5 | 6.0 | 8.7 | 5.7 | 5.7 |


## Small sets and skewed traffic

`one` = {v1}, `pair` = {keys, health}, `trio` = {GET, PUT, DELETE},
`quad` = {GET, HEAD, POST, PUT}. `methods_skew` is the 9 methods with 70%
GET, 20% POST, 8% the rest, 2% misses.


| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| Ren today (== chain) | 0.34 ± 0.01 | 1.69 ± 0.07 | 2.85 ± 0.17 | 3.05 ± 0.11 | 3.49 ± 0.02 |
| length switch + memcmp (C) | 0.35 ± 0.01 | 1.52 ± 0.07 | 2.59 ± 0.07 | 2.81 ± 0.16 | 3.47 ± 0.02 |
| Rust `match` (rustc) | 0.37 ± 0.01 | 1.65 ± 0.10 | 2.79 ± 0.23 | 2.99 ± 0.23 | 1.49 ± 0.08 |
| gperf 3.0.3 | 0.57 ± 0.01 | 4.79 ± 0.04 | 4.55 ± 0.06 | 5.13 ± 0.05 | 4.47 ± 0.02 |
| hash map (FNV-1a, open addr.) | 3.54 ± 0.05 | 6.35 ± 0.07 | 6.28 ± 0.04 | 5.59 ± 0.09 | 5.44 ± 0.05 |
| phash + memcmp | 0.40 ± 0.01 | 3.96 ± 0.11 | 4.16 ± 0.08 | 4.13 ± 0.09 | 3.99 ± 0.06 |
| phash + 2 words (padded) | 0.40 ± 0.01 | 1.04 ± 0.02 | 1.09 ± 0.03 | 1.03 ± 0.02 | 1.03 ± 0.01 |
| phash + NEON, page check | 0.51 ± 0.01 | 0.87 ± 0.02 | 0.87 ± 0.02 | 0.92 ± 0.02 | 0.97 ± 0.01 |
| phash + NEON, padded | 0.41 ± 0.01 | 0.84 ± 0.01 | 0.85 ± 0.02 | 0.93 ± 0.09 | 0.96 ± 0.02 |


Instructions per lookup:


| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| Ren today (== chain) | 10.5 | 11.5 | 14.5 | 13.6 | 22.7 |
| length switch + memcmp (C) | 8.7 | 11.1 | 14.9 | 13.7 | 22.8 |
| Rust `match` (rustc) | 8.1 | 10.6 | 13.6 | 12.7 | 14.2 |
| gperf 3.0.3 | 14.3 | 51.3 | 52.0 | 56.4 | 56.3 |
| hash map (FNV-1a, open addr.) | 63.2 | 73.6 | 79.1 | 67.9 | 73.3 |
| phash + memcmp | 8.7 | 41.2 | 49.4 | 43.7 | 50.6 |
| phash + 2 words (padded) | 8.7 | 25.0 | 25.1 | 25.3 | 25.7 |
| phash + NEON, page check | 16.3 | 26.9 | 27.0 | 27.2 | 27.7 |
| phash + NEON, padded | 12.5 | 24.0 | 24.1 | 24.3 | 24.7 |


Instructions per cycle:


| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| Ren today (== chain) | 7.6 | 1.6 | 1.2 | 1.0 | 1.6 |
| length switch + memcmp (C) | 6.1 | 1.7 | 1.5 | 1.1 | 1.6 |
| Rust `match` (rustc) | 5.4 | 1.5 | 1.2 | 1.0 | 2.4 |
| gperf 3.0.3 | 6.3 | 2.5 | 2.9 | 2.5 | 3.2 |
| hash map (FNV-1a, open addr.) | 4.4 | 2.8 | 3.2 | 2.8 | 3.4 |
| phash + memcmp | 5.4 | 2.4 | 3.0 | 2.4 | 3.2 |
| phash + 2 words (padded) | 5.4 | 6.0 | 5.9 | 6.2 | 6.3 |
| phash + NEON, page check | 7.9 | 7.8 | 7.9 | 7.5 | 7.1 |
| phash + NEON, padded | 7.7 | 7.2 | 7.3 | 6.7 | 6.4 |


## What the generator chose

| set | keys | lengths | table M | byte positions | nonzero values |
|---|---:|---|---:|---|---:|
| methods | 9 | 3..7 | 16 | [0] | 4 |
| headers | 20 | 3..15 | 32 | [0] | 10 |
| jsreserved | 45 | 2..10 | 64 | [1, 2] | 23 |
| json8 | 8 | 2..10 | 8 | [0] | 3 |
| json24 | 24 | 2..21 | 32 | [0] | 10 |
| schemes | 6 | 2..5 | 8 | [0] | 2 |
| renkw | 35 | 2..7 | 64 | [0, 1] | 25 |
| one, pair, trio, quad | 1-4 | | 2-4 | [] or [0] | 0-2 |

json24 has one key over 16 bytes (`notification_settings`). Its slot
compares with `memcmp`; the others use the 16-byte compare.

Read-only data per `match`: 256 bytes per byte position, plus 16 bytes
of key and 2 bytes of length and value per slot. For the 20 headers
that's about 830 bytes.

## Method

- **Machine:** M4 Max, shared with another experiment. Before each key
  set, the script waited until the 1-minute load was below 4 (polling
  every 30 s). The load is recorded before and after each set below. It
  rose to 4.5 to 5.9 during runs, partly from these runs themselves.
- **Timing:** hyperfine 1.x, `-N`, 3 warmups, 25 runs. Each run does
  500 passes over 65,536 queries (32.8M lookups). The ns figure is (mean
  wall time minus the empty loop's) / 32.8M. Each binary also reports the
  minimum of its 500 passes, which agrees within about 10% (see
  code/out/main_tables.md).
- **Instructions and cycles:** hyperfine's counters, mean of the 25 runs,
  minus the empty loop.
- **Queries:** code/gen.ml writes them with a fixed seed. Each query is
  copied into an arena 8-byte aligned after a 32-byte gap, as a `Str`'s
  bytes sit after its header. Every form is checked against the chain on
  every query before timing.
- **C:** Apple clang 16, `-O2`, as `ren build --release` uses
  (lib/native/cc.ml). All lookups are `static inline`, inlined into the
  loop, as Lemire's are.
- **Rust:** rustc 1.99.1, `-C opt-level=3`, a plain `match s { "GET" =>
  0, ... }` inlined into a generic loop (code/rmatch.rs). Its assembly
  (code/asm/rmatch.s) is a branchy binary search on the length, then
  inline 2- to 8-byte word compares. That is the "length switch".
- **gperf:** Apple's /usr/bin/gperf 3.0.3, `--compare-lengths`, a struct
  with the arm index.
- **Hash map:** open addressing, FNV-1a 64-bit, linear probing, 256
  slots, compare by length and `memcmp`. Roughly what a `Table<Str, Int>`
  would do.
- **Not measured:** x86, and the extra load a real `Str` needs (its
  length and data pointer from the object). That load is the same for
  every form.

Load during each set (1-minute average):

| set | before | after |
|---|---:|---:|
| methods | 3.86 | 3.49 |
| headers | 3.49 | 5.85 |
| jsreserved | 3.80 | 5.20 |
| json8 | 3.98 | 5.72 |
| json24 | 3.95 | 4.75 |
| schemes | 3.55 | 3.67 |
| renkw | 3.67 | 4.49 |
| one | 3.93 | 4.41 |
| pair | 3.91 | 3.53 |
| trio | 3.53 | 4.21 |
| quad | 3.92 | 4.46 |
| methods_skew | 3.73 | 4.63 |

## What Ren emits today

`match` can't take a string literal. The `==` chain, which is what code
writes instead:

```c
static int64_t ren_m2_code_1(const ren_ev* v1_ev, ren_obj* v2_m) {
  bool v4_eq = ren_str_eq(v3_m, ((ren_obj*)&ren_lit_1));   /* "GET" */
  if (v4_eq) { v5_if = 1; } else {
    bool v7_eq = ren_str_eq(v6_m, ((ren_obj*)&ren_lit_0)); /* "POST" */
    ...
```

`ren_str_eq` is `len == len && memcmp(...) == 0`. The runtime is in the
same C file, so clang can inline it. The "Ren today" row is that chain on
`(data, len)`.

The native `match` (lib/native/to_mem.ml, `match_`) switches on a sum's
tag, then tries the arms that can match, in order. A tuple subject isn't
built. There's no decision tree over several columns yet.
Exhaustiveness (lib/sema/exhaust.ml) treats each `Int` literal as a
constructor of an infinite family. `Str` literals would slot in the same
way.

## Over-reading: can Ren guarantee 16 readable bytes?

The 16-byte compare loads 16 bytes from the start of the key, past its
end when it's shorter. That's safe unless the load crosses into an
unmapped page.

**What the runtime does now** (lib/native/runtime/ren_rt.h, ren_rt.c):

- A `Str` is `{header, len, data, root, bytes[]}`. An owner's `data`
  points at its own `bytes`, with `len` bytes then a 0. A slice's `data`
  points into its root's bytes, and `root` counts the owner (decision
  17).
- An owner is allocated with `sizeof(ren_str) + len + 1` bytes, rounded
  up to words. Small objects (up to 64 words) come from free lists or a
  bump in 1 MB chunks from `malloc`. Larger ones come from `malloc`.
- Literals are static structs with `char bytes[len + 1]`.
- So today there are 1 to 8 bytes after an owner's end, not 16. A string
  at the end of a chunk or a `malloc` block can sit right before an
  unmapped page.

**What it would take to promise 16 bytes:** allocate owners with `len +
16` instead of `len + 1`, and emit literals with `bytes[len + 16]`. Then
any slice is safe too: a slice starts at an offset at most the root's
length, so its 16 bytes end at most 16 past the root's end. The cost is
about 8 to 15 bytes per owned string, nothing per slice.

**What would break it:** any `Str` or `Bytes` whose bytes the runtime
didn't allocate, such as a future zero-copy view of an `mmap`ed file or
a buffer from C. Each of those would need its own padding.

**Recommendation: keep Lemire's page check, and promise nothing.** It
costs about 3 instructions and no measurable time here. It keeps working
for bytes from anywhere. The load needs `no_sanitize("address")`, since
Ren's sanitizer builds (build.t) would flag the deliberate over-read.
The portable two-word form would need the same check, written in scalar
code.

## Files

- code/gen.ml: the generator, the algorithm the compiler would run.
  Positions, greedy values, power-of-two table, fallback.
- code/phrt.h: the runtime half. Page-safe load, padded load, the masked
  16-byte compare, the two-word masks.
- code/gen/*.h: the C emitted per set, all forms. code/gen/*.rs: the Rust
  twins. code/gen/*.gperf: gperf input.
- code/bench.c, code/rmatch.rs, code/rmatch_small.rs: the harnesses.
- code/measure.sh, code/measure_small.sh: the runs. code/summarize.py:
  these tables.
- code/out/: hyperfine JSON and text, loads, the full tables.
- code/ren/m2.ren, code/ren/m2.full.c: Ren's emitted chain.

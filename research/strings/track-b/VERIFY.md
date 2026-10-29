# Track B, verified

An independent check of `RESULTS.md`. I reviewed the harness first, then
re-ran the headline rows myself. Nothing in `track-b/` was changed.
Everything I ran is in `track-b/verify/`: copies of the sources, two
added variants, `measure.py` pointed at its own `bin/` and `results/`,
and every run (`results/*.jsonl`, `*.txt`).

**Verdict.** Every headline number reproduces to within 10%, apart from
two small rows covered below. One harness problem changes a conclusion:
the B1 **logs** row was dominated by a clang codegen pathology, and it
hit every layout. With that removed, B beats A on logs by 16% instead
of tying it, and **SSO beats B on logs by 6%**. "Build B" gets
stronger. "SSO doesn't pay" gets weaker: it still loses on tok, sort,
map and group, but it wins on records with many short fields.

## How it was run

- Same machine (M4 Max), Apple clang 16.0.0, rustc release profile
  (`opt-level=3`, `lto`, `codegen-units=1`), Go 1.27.3. Load average
  1.6 to 3.3 at the start of each set, with other agents' sessions idle
  in `ps`. Sets ran one at a time, 09:44 to 09:51.
- 11 runs, interleaved and rotated, through Track B's own `measure.py`
  logic. The medians are of in-process kernel times.
- **The binaries are the sources.** Rebuilding every C variant from
  `c/` gave binaries byte-identical to those in `bin/`. The same holds
  for the Go twins. The Rust twins were rebuilt fresh into
  `verify/rust-target/` from `rust/src`. All checks agreed in every
  run.

## Harness review

**Variant A models ren_rt.h faithfully** (checked against cf7787c):
- `ren_str` is `{ren_obj h; int64 len; const char *data; ren_obj *root;
  char bytes[]}`, a 32-byte header. The harness's `astr` is the same.
- `ren_str_part` matches line for line: a whole-range slice is a dup,
  and any other slice is a 32-byte object counting its root.
- `ren_alloc_str` matches, at `sizeof + len + 1`.
- The allocator matches: 64 words, 1 MiB chunks, free lists. It isn't
  thread-local in the default mode, so a plain static is right.
- `ren_utf8_valid` in `b5.c` is verbatim.

Omitted: `ren_dup`/`ren_drop`'s `ren_is_scalar` test and the `rc < 0`
cold path. That's one predictable branch, and real Ren would pay it in
every layout. The `-at` variants also omit the acquire fence on the
last drop, which only matters on frees. Neither changes a ratio.

**Layouts are sound.**
- B is 16 bytes, 8-aligned. The root's 16-byte header keeps the bytes
  16-aligned, and the count sits on the root.
- SSO's tag is `b[15]`, the top byte of `len` on little-endian. That's
  valid while length < 2^31, which is the 4 GiB escape RESULTS already
  lists as not built.
- SSO's over-read is bounded by the root's `cap` and falls back near
  the end.
- G is canonical, with zero-padded inline values, and its long values
  point to A-style objects, as described.

**Nothing is optimized away.**
- Every kernel prints a `check=`, and the checks agree across layouts
  and twins.
- The validators are `noinline` and their results are summed. The Rust
  twin uses `black_box`.
- I extended B5's agreement test to long inputs, with random mutations
  of 1 MiB texts, and to every truncated or invalid sequence placed
  around 64-byte block boundaries (`verify/c/b5big.c`). The result was
  0 disagreements in 69,000 inputs, 53,000 of them invalid. The NEON
  tables match simdjson's lookup algorithm.

**Twins are idiomatic and built for release.**
- Rust's map uses `get_mut` then `insert`, so it hashes twice only on
  the 132k misses out of 4M, which is negligible.
- Rust's B2 twin validates UTF-8 inside its timed region and C doesn't.
  That's a small handicap for Rust, and it still wins.
- Rust's sort uses `sort_unstable` against the harness's quicksort,
  which RESULTS already flags.
- The Go twins are default builds.

**Problems found**, most important first:

1. **B1 logs: a clang loop-strength-reduction pathology, in every
   layout.** In `w_logs`'s field-splitting loop
   (`while (p[e] != ' ') e++`), clang carries up to 12 redundant
   induction variables per byte. Among them is the packed u32
   `{off,len}` pair, advanced by `1<<32` each byte. That's the inner
   loop at `verify/results/b1_B.s` lines 1895–1990. It is not a
   property of any layout: B's parse costs 2,090M instructions and
   B24's 1,495M. It survives `-O3` and `noinline`. An empty `asm` on
   `e` after each scan (`verify/c/b1iv.c`, applied to every layout
   alike) removes it. The same barrier changes nothing on tok or sort
   (`results/v8.txt`), so it's specific to this loop.
   Logs, median of 11 (`results/v7.txt`):

   | | A | B | B24 | SSO |
   |---|---|---|---|---|
   | as built (RESULTS: 149.9 / 151.9 / 142.8 / 156.4) | 149.2 | 151.1 | 140.7 | 157.0 |
   | **IV barrier (corrected)** | **138.2** | **116.0** | 127.1 | **109.5** |
   | instructions, corrected (M) | 1,224 | 810 | 845 | 900 |

   Corrected, **B is 0.84× A** and B24 is 1.10× B. **SSO is 0.94× B**:
   57% of these fields are 15 bytes or less, and inline fields make the
   drop pass 13.7 ms against B's 23.4 ms.
   - This **invalidates** "logs is the exception: B ties A" and the
     "ambiguous: records with many Str fields are a wash" bullet.
   - It also **reverses the reason** behind "B24's only clean win was a
     codegen artifact". The artifact was in *B's* code (and A's and
     SSO's), not B24's. The conclusion, prefer B over B24, still
     stands.
   - It **narrows** headline 2: SSO's range against B is 0.94–1.10×,
     not 1.03–1.10×.
   - A caveat: Ren's compiler emits its own C, so whether its output
     trips the same LSR heuristic is unknown. The as-built row is what
     you get if it does.

2. **The B3 iolist holds the whole document before writing.** All ~20M
   pieces stay in one growing vector, about 320 MB, and `writev`
   starts at the end. A real iolist output path writes as it goes. I
   added a variant that flushes every 1,024 pieces (`IOL_STREAM`,
   `verify/c/b3.c`):

   | ms | inplace | builder | iolist (as built) | iolist, streaming |
   |---|---|---|---|---|
   | json | 157.5 | 158.8 | 426.7 (2.7×) | **337.9 (2.15×)** |
   | logs | 93.5 | 92.2 | 341.8 (3.7×) | **235.2 (2.5×)** |

   The iolist still loses clearly, but by 2.2–2.5×, not 2.9–3.3×. The
   memory claim ("1.7–2.7× the builder's") holds only for the
   hold-everything version. Streaming, the iolist peaked at 220 MiB on
   json and 389 MiB on logs, *below* inplace and builder, because no
   105 MB output buffer exists.

3. **B3's RSS for realloc-grown buffers is bimodal**, anywhere from 208
   to 366 MiB from run to run for the same binary (`v3.jsonl`). So
   "inplace 321, builder 263 MiB" is noise. My medians were 342 and
   321. Don't read a memory difference between inplace and builder.

4. **SSO's `s_eq_raw` rebuilds an inline value with a variable-length
   memcpy** on every probe that hits an inline key. Comparing in place
   (`-DSSO_EQFIX`) brings SSO's map from 301.3 to 288.3 ms, against B's
   283.3. That's 1.02× B, not 1.04–1.06×. It's a small bias against
   SSO, and it doesn't change the verdict on map.

5. **B2's C keep reads each chunk twice**: `read_file` into a malloc
   buffer, then `s_new` copies it into the owner. Every policy pays
   this alike, so the comparisons within the table hold. But it
   inflates C's absolute times against the twins: Go `strings.Clone`
   ran in 154 ms against C's 199–208 ms. Separately, "store was
   faster" is +4% in milliseconds with overlapping spreads (199 against
   207). It's solid in cycles: 529–533 against 635–637 Mcyc, −17%.

## Re-measured headline rows

Median ms of 11. The RESULTS value is in parentheses. Δ is mine against
RESULTS.

**B1 layouts** (`results/v1.txt`, `v6.txt`)

| | A | B | SSO | SSOmc | G | B24 |
|---|---|---|---|---|---|---|
| tok | 27.08 (26.85) | 20.19 (20.47) | 21.13 (21.27) | 24.86 (24.94) | 24.83 (24.37) | 22.21 (22.51) |
| map | 312.3 (306.8) | 283.3 (282.9) | 301.3 (294.5) | 300.1 (290.2) | 319.6 (325.1) | 291.1 (290.9) |
| sort | 344.3 (342.5) | 262.0 (260.9) | 288.1 (287.8) | 292.2 (290.7) | 290.2 (285.3) | 263.5 (262.5) |
| group | 211.1 (212.8) | 208.6 (208.5) | 217.5 (217.2) | | 220.0 (220.3) | 208.5 (209.2) |
| logs | 151.0 (149.9) | 151.9 (151.9) | 156.5 (156.4) | | 171.7 (170.4) | 141.4 (142.8) |

Ratios: B/A is 0.75 on tok, 0.76 on sort and 0.91 on map (RESULTS:
0.76, 0.76, 0.92). SSO/B is 1.05, 1.06 and 1.10. SSOmc/B on tok is
1.23 (RESULTS: 1.22). Allocation counts weren't re-run. They follow
from the code by construction: one slice object per kept slice in A,
none in B.

**B2 retention** (`results/v2.txt`)

| keep | ms | RSS MiB | Mcyc |
|---|---|---|---|
| A share | 208.5 (206.6) | 522.3 (522.2) | 637 (636) |
| A n16 / n64 | 209.9 / 206.9 | 522.3 / 522.5 | |
| A store | 200.0 (198.5) | **18.5** (18.5) | **533** (528) |
| B share / store | 207.3 / 198.8 (209.5 / 201.0) | 522.0 / 18.4 | 635 / 529 |
| SSO share / store | 205.4 / 202.6 | 522.0 / 18.3 | |
| Rust `String` | 193.4 (192.1) | 10.8 | |
| Go share / clone | 234.3 / 153.6 (235.5 / 154.7) | 663.4 / 38.6 | |
| tok, B share / store | 19.94 / 32.90 (20.65 / 32.97) | 42.5 / 63.8 | |

**B3 output** (`results/v3.txt`): json inplace 157.5 (153.2), builder
158.8 (162.6), iolist 426.7 (441.2). logs inplace 93.5 (95.2), builder
92.2 (94.7), iolist 341.8 (312.4, +9.4%). json at 5k records: concat
522.2 (521.8) against inplace 0.77 (0.76), 678×. Rust `String` json
123.8 (124.2); Go 159.2 (157.4).

**B4 keys** (`results/v4.txt`; `v4-run1.txt` is an earlier run under
load 2.9, with B at 299 ms and spreads twice as wide, so I ran it
again)

| map | ms | Mcyc |
|---|---|---|
| C A-wy | 301.7 (299.9) | 877 |
| **C B-wy** | **279.6** (278.3) | 818 |
| Rust `&str` std / fx / ahash | 397.4 / **273.2** / 283.9 (394.1 / 275.9 / 281.2) | 1104 / 782 / 813 |
| Rust `String` std / fx / ahash | 369.3 / 265.3 / 265.6 (366.3 / 262.4 / 265.0) | 1035 / 754 / 760 |

B is 1.02× Rust `&str`+Fx, 1.05× `String`+Fx, and 0.70–0.76× std.

**B5 validation** (`results/v5.txt`, `rpr.txt`): throughput reproduces
to within 1%. ren is 2.60 / 1.09 / 1.70 GB/s on ascii / cjk / mixed at
1 MiB. NEON is 73.1 / 9.01 / 13.5, and simdutf8 72.6 / 9.00 / 13.4. At
64 B: NEON 18.5 / 8.22 / 5.09 against simdutf8 18.6 / 5.99 / 5.78.

Read-parse-respond, validate / total ms:

| file | ren | neon |
|---|---|---|
| logs.txt | 37.3 / 230.5 (37.3 / 229.8) | 4.27 / 194.8 (2.89 / 189.4) |
| people.csv | 24.0 / 179.9 (24.3 / 182.6) | 1.87 / 158.8 (1.9 / 162.6) |
| cjk-big.txt | 64.2 / 158.0 (64.0 / 157.4) | 8.30 / 105.1 (7.6 / 102.2) |

## Discrepancies over 10%

| row | RESULTS | mine | why / matters? |
|---|---|---|---|
| B1 logs, every layout | B ≈ A; SSO 1.03× B | corrected: B 0.84× A, SSO 0.94× B | Harness problem 1. **Changes conclusions.** |
| B3 iolist / inplace | 2.9–3.3× | 2.7–3.7× as built; 2.15–2.5× streaming | Problem 2. Same verdict, smaller gap. |
| B3 iolist peak memory | 1.7–2.7× builder | below the builder when streaming | Problem 2. |
| B3 builder RSS | 263 MiB | 321 MiB | Noise from bimodal realloc (problem 3). |
| rpr logs.txt, NEON validate | 2.89 ms (1.5%) | 4.27 ms (2.2%) | Wide spread, 2.6–5.6 ms in both sessions. Tiny in absolute terms, same verdict. |

Everything else is within 10%, nearly all within 3%.

## Does each "what this says for Ren" survive?

- **Build B.** Survives and gets **stronger**. With the codegen
  artifact removed, B wins on logs too (0.84× A), so "wins or ties
  everywhere" becomes "wins everywhere but group, where it ties".
- **B over B24.** Survives. Corrected logs: B 116 against B24 127 ms.
  RESULTS' reason was wrong: B's code was the pessimized one, not
  B24's.
- **Don't do SSO or German strings now.** German strings: survives
  (1.05–1.23× B everywhere). SSO: survives, but weaker. It loses 2–10%
  on tok, map, sort and group, and **wins 6% on record-heavy logs**,
  where most fields are short and the drop pass skips their counts.
  "SSO saves counts but not time" is wrong for that shape. Keeping SSO
  open as a later, invisible compiler change under option (c) is the
  right call. The case for it now rests on record-heavy programs, not
  only on threaded counting.
- **"Ambiguous: records with many Str fields are a wash".**
  Overturned: B wins by 16% once the artifact is out. Record size
  still shows in the drop pass (B 23.4 ms against A 14.9).
- **Retention: no free automatic policy; always share plus `copy()`
  plus the debug report; maybe copy on store when the root provably
  dies first.** Survives. Thresholds kept every buffer (522 MiB at n16
  and n64 in all three layouts), store held 18.4 MiB, and store on tok
  cost 1.65×. "Faster" is true in cycles (−17%) and marginal in wall
  time (−4%).
- **Positions favour option (c).** That isn't a measurement and
  survives as an argument. The share/store rows confirm that copy
  policies are real choices the compiler may want to make, and under
  (b) they would change observable offsets.
- **`s += x` in place on a unique owner; no Builder type; `s = s + x`
  must not ship as the way to build output.** Survives exactly
  (inplace ≈ builder within 1–2%; concat 678× at 5k).
- **iolists not the default; `Net.write(parts)` is enough.** Survives,
  with a smaller margin (2.2–2.5× when streaming). Drop the
  memory-penalty argument: a streaming iolist uses *less* peak memory.
- **Keep wyhash with a stored hash; don't hash a prefix; re-measure the
  bytes stage against FxHashMap/aHash.** Survives. B is 1.02–1.05× Rust
  with Fx, and SipHash flattered Ren by 1.32–1.42×. Prefix and
  nohashcmp weren't re-run: a 7.6× effect and a "no change" are
  outside what noise could flip.
- **Ship a SIMD `from_utf8`; validation then costs 1–7%.** Survives.
  The throughput reproduces to within 1%, the NEON validator passed an
  extended agreement test, and the read-parse-respond share is
  1.2–7.9%.

## Files

- `verify/c/`: copies of the harness. Changes against `c/`: `strs.h`
  adds `SSO_EQFIX`; `b3.c` adds `IOL_STREAM`; `b1iv.c` is `b1.c` with
  the IV barriers; `b1ni.c` is `b1.c` with `w_logs` noinline;
  `b5big.c` is the extended validator test.
- `verify/build.sh` builds `verify/bin/` and checks it against
  `bin/`. `verify/measure.py` holds sets `v1`–`v8`, `rpr` and `v5`.
- `verify/results/`: the `*.txt` summaries, the `*.jsonl` runs,
  `b1_B.s` and `b1_B24.s` (the asm behind problem 1), and
  `v4-run1.*` (the noisy first B4 run).

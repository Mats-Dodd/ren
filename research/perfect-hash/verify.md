# Track B verify: string `match` as a perfect hash

An independent re-run of results.md, a fuzz of the generator on
adversarial key sets, a check of the over-read reasoning against Ren's
runtime, and a critique of list-patterns.md against language.md.

Everything is under verify/: bench/ (rebuilt binaries, hyperfine JSON,
loads), fuzz/ (harness, key sets, generated C), compare.py,
compare_full.md (every cell, theirs against mine).

## Verdict

1. **The speed claim holds.** Ratios against phash + NEON reproduce
   within the spread on every set. The perfect hash is 5 to 8 times
   faster than the `==` chain on the seven real sets.
2. **Four of results.md's absolute columns are about 1.5x too slow.**
   methods, headers, jsreserved and json8 ran at a flat 2.6 GHz. Their
   own hyperfine cycle counters show it. Every other set, in both runs,
   ran at about 4.0 GHz. Cycles per lookup agree, so the ratios are fine
   but the ns are not. The 20 headers take **0.90 ns, not 1.29 ns**. So
   "matches Lemire's ~1.3 ns on the M3 Max" is wrong: this machine is
   faster than that.
3. **The hash itself is correct.** I fuzzed 15 adversarial sets and the
   11 original ones, with 1M random and near-miss queries each, at three
   placements in memory. Once the emitter's table widths were fixed,
   there were zero mismatches.
4. **The emitter has five bugs**, all at the edges. Two are wrong
   answers on plausible inputs: more than 127 keys, and keys longer than
   255 bytes. Two involve the empty string. The fifth is that the ASan
   exemption doesn't work as written. None of them affects the measured
   sets.
5. **The over-read reasoning is sound for non-empty strings.** It misses
   the empty string at a page boundary, sanitizers, and memory tagging.

## 1. Numbers: mine against theirs

Same sources and the same build: clang 16 `-O2`, rustc 1.99.1
`-C opt-level=3`, gperf 3.0.3. My regenerated `.h` and `.q` files are
byte-identical to theirs. I used hyperfine `-N`, 3 warmups and 25 runs,
waited before each set until the 1-minute load was under 4, and
subtracted the empty loop. I re-ran headers because a load spike (6.86)
hit its gperf and rust cells.

ns per lookup (mine), ± combined standard deviation:

| form | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ren today (== chain) | 5.94 ± 0.10 | 7.34 ± 0.16 | 8.08 ± 0.36 | 5.79 ± 0.09 | 7.86 ± 0.18 | 6.04 ± 0.10 | 8.50 ± 0.37 |
| Rust `match` | 4.83 ± 0.30 | 7.10 ± 0.14 | 9.01 ± 0.31 | 4.57 ± 0.60 | 7.17 ± 0.16 | 3.51 ± 0.37 | 7.21 ± 0.25 |
| gperf | 6.35 ± 0.20 | 7.55 ± 0.06 | 6.60 ± 0.12 | 6.49 ± 0.08 | 6.20 ± 0.06 | 5.73 ± 0.10 | 6.18 ± 0.12 |
| hash map | 7.00 ± 0.15 | 10.08 ± 0.11 | 9.02 ± 0.18 | 7.39 ± 0.12 | 9.07 ± 0.11 | 7.15 ± 0.12 | 7.67 ± 0.23 |
| phash + memcmp | 4.83 ± 0.13 | 6.38 ± 0.03 | 5.73 ± 0.15 | 5.56 ± 0.07 | 5.87 ± 0.12 | 5.45 ± 0.11 | 5.73 ± 0.11 |
| phash + 2 words | 1.15 ± 0.02 | 1.10 ± 0.01 | 1.35 ± 0.04 | 1.19 ± 0.02 | 1.06 ± 0.03 | 1.10 ± 0.03 | 1.07 ± 0.01 |
| phash + NEON, page check | 1.04 ± 0.04 | 0.90 ± 0.05 | 1.02 ± 0.01 | 1.06 ± 0.02 | 0.95 ± 0.03 | 1.12 ± 0.04 | 1.06 ± 0.01 |
| phash + NEON, padded | 1.07 ± 0.04 | 0.87 ± 0.01 | 1.02 ± 0.02 | 1.03 ± 0.02 | 0.90 ± 0.02 | 1.11 ± 0.03 | 1.21 ± 0.01 |

The chain against phash + NEON (page check), mine against theirs:

| | methods | headers | jsreserved | json8 | json24 | schemes | renkw |
|---|---:|---:|---:|---:|---:|---:|---:|
| mine | 5.7x ± 0.2 | 8.2x ± 0.5 | 7.9x ± 0.4 | 5.5x ± 0.1 | 8.3x ± 0.3 | 5.4x ± 0.2 | 8.0x ± 0.4 |
| theirs | 6.6x | 8.8x | 9.0x | 6.3x | 8.0x | 4.9x | 7.7x |

Small sets and skewed traffic (mine; theirs agree within 5 to 15%):

| form | one | pair | trio | quad | methods_skew |
|---|---:|---:|---:|---:|---:|
| chain | 0.36 ± 0.02 | 1.87 ± 0.18 | 2.98 ± 0.23 | 3.44 ± 0.08 | 3.50 ± 0.02 |
| Rust `match` | 0.38 ± 0.01 | 1.79 ± 0.23 | 2.78 ± 0.07 | 3.48 ± 0.51 | 1.52 ± 0.16 |
| phash + NEON, page check | 0.53 ± 0.01 | 0.86 ± 0.01 | 0.90 ± 0.01 | 0.89 ± 0.01 | 0.98 ± 0.01 |
| phash + NEON, padded | 0.42 ± 0.01 | 0.84 ± 0.01 | 0.90 ± 0.01 | 0.88 ± 0.01 | 0.96 ± 0.01 |

Load (1-minute) before and after each set: methods 3.47/4.01,
headers (re-run) 2.98/3.12, jsreserved 3.60/4.92, json8 3.88/3.73,
json24 3.73/4.23, schemes 3.70/3.56, renkw 3.56/3.23, one 3.23/3.26,
pair 3.26/3.50, trio 3.50/3.63, quad 3.63/3.69, methods_skew 3.69/3.75.

**The clock.** Cycles divided by wall time, from each run's own
counters:

| set | theirs (chain/phash/gperf) | mine |
|---|---|---|
| methods, headers, jsreserved, json8 | 2.60 / 2.60 / 2.60 GHz | 4.0 to 4.45 GHz |
| the other eight sets | 3.95 to 4.47 GHz | 3.8 to 4.05 GHz |

Their first four sets were most likely scheduled on efficiency cores, or
the machine was throttled. For methods, both runs take 4.05 and 4.11
cycles a lookup. The fix is to re-run those four sets, or to report
cycles a lookup next to ns.

**Corrected ranges for results.md's finding 2:** phash + NEON took 0.90
to 1.12 ns. The chain took 5.8 to 8.5 ns, rustc 3.5 to 9.0 ns, gperf 5.7
to 7.6 ns, and the hash map 7.0 to 10.1 ns. Findings 3 to 8 stand as
written:
- skew: 0.98 against 3.50 ns, rustc 1.52 ns.
- one key: the chain wins, 0.36 against 0.53 ns.
- two keys: the hash wins, 0.86 against 1.87 ns.
- the page check is free except at one key.
- renkw's padded form is again slower, 1.21 against 1.06 ns. That
  reproduces, so it's real, probably code layout.

**Method notes (minor, they don't change the verdict):**
- The benchmark arena is zero-filled after each string, and the stored
  keys are zero-padded. So a masking bug would pass the benchmark's own
  check. My fuzz puts random bytes after every string.
- The Rust harness has its own loop with `black_box` but is offset by
  the C empty loop. That biases rustc by a fraction of a ns at most.

## 2. Correctness: the fuzz

The harness is fuzz/fuzz.c, run by fuzz/run_fuzz.sh. The reference is a
linear compare against the key file, which is independent of gen.ml.

Each query is tested three ways:
- **G:** random bytes after the string, random alignment. All six forms.
- **K:** the string starts at 4080 to 4095 mod 4096, inside mapped
  memory, with random bytes after. This drives the shuffle path of the
  page-safe load.
- **P:** the string ends exactly at a `PROT_NONE` page. Unpadded forms
  only.

The queries are every key, then 1M generated ones. About 10% are random
strings over the keys' byte alphabet plus random bytes. The rest
change a key: one byte replaced (any value, including NUL and high
bytes), a bit flipped, a prefix, 1 to 3 bytes appended, a byte inserted
or deleted, or halves of two keys joined.

Key sets (gen.ml was given hex input, so the empty string and any byte
can be a key):

| set | what | plan | result as emitted |
|---|---|---|---|
| prefix | 27 keys sharing `application/vnd.ren.` (20 bytes), plus its prefixes | M=32, [20] | ok |
| past16 | 8 keys equal for 20 bytes, differing at 20..23; 8 at byte 15; 4 at 16; q×17..19 | **fallback** (needs more than 4 positions) | ok |
| past16b | `k`×16 plus suffixes: every key differs only past byte 16 | M=16, [16; 17] | ok |
| empty | `""` among 8 others | M=16, [0] | ok |
| emptylast, emptylast2 | `""` plus keys that differ in their last byte | M=32, [last] | **FAIL: `""` not found** |
| emptyonly | `{""}` | M=2, [] | **FAIL: `""` not found** |
| emptypair | `{"", "z"}` | M=2, [] | ok |
| k200 | 200 random identifiers, 1 to 24 bytes | M=256, [0; last] | **FAIL: arms 128+ wrong** |
| k200prefix | `user.settings.0` .. `.199` | M=512, [last; 14; 15] | **FAIL: arms 128+ wrong** |
| k200short | 200 strings over {a, b}, 1 to 9 bytes | **fallback** | ok |
| utf8 | café/cafe/cafè, 日本/日本語/日本人, emoji, é/è (differ in one continuation byte), ß/ss, NBSP, combining marks, a 30-byte Greek key | M=32, [last; 1; 4] | ok |
| lenonly | lengths alone nearly separate | M=8, [0] | ok |
| long255 | a 255-byte key | M=4, [2] | ok |
| long300 | keys of 300 and 299 bytes | M=4, [44] | **FAIL: never found** |
| the 11 original sets | | as results.md | ok |

After the four emitter fixes below (fuzz/gen_fixed.ml), **every set
passes with zero mismatches**, 1M queries each at all three placements.

### Bugs found

1. **More than 127 keys gives wrong arms.** `_val` is `int8_t`, so arm
   128 comes back as -128. That's a wrong arm, or a miss whenever the
   value is -1. Seen in k200: 154 came back as -102.
   *Fix:* size `_val` by the number of arms.
2. **Keys over 255 bytes are never found.** `_len` is `uint8_t`, so 300
   is stored as 44. Long keys are rare in a `match`, but the failure is
   silent.
   *Fix:* size `_len` by the longest key. The empty-slot sentinel 255
   also collides with a real 255-byte key. It's harmless today only
   because the empty slot's value is -1.
3. **An empty key with a "last byte" position reads `s[-1]`.** gen.ml
   treats `""`'s last byte as "adds 0". The C reads `s[n - 1]` with no
   guard, which is out of bounds when `n = 0`. Whatever byte sits before
   the string then picks the slot. `""` is missed whenever that byte has
   a nonzero table value: 1,760 failed checks in emptylast's 1M-query
   run.
   *Fix:* emit `(n > 0 ? A[s[n-1]] : 0)` when the shortest key is
   empty.
4. **The set `{""}` alone gets a zero-width key table.**
   `w = (0 + 15) / 16 * 16 = 0`, so `ph_eq16` reads 16 bytes past a
   0-byte row, and `""` is missed.
   *Fix:* `w = max 16 ...`.
5. **The ASan exemption doesn't work as written.**
   `no_sanitize("address")` sits on `ph_load_paged`, which is
   `always_inline`. Once inlined, the load is instrumented as part of
   its caller. With `-fsanitize=address`, a 3-byte `malloc` holding
   "GET" gives a heap-buffer-overflow in ph_neon, ph_pad and ph_word, at
   both `-O0` and `-O2`.
   *Fix:* put the attribute on the emitted lookup function (checked:
   clean), or have sanitized builds emit the `memcmp` form.

### A crash outside today's runtime

**An empty string whose pointer is the first byte of an unmapped page
crashes ph_neon with SIGBUS (exit 138).** The page check sees offset 0,
takes the fast path, and loads 16 bytes from the unmapped page. It
happens only if `""` is a key, since otherwise the length range check
rejects `n = 0` first.

It can't happen in Ren today. Every owner has a 0 byte after its `len`
bytes, and a slice's end is inside its root's bytes or on that 0. It can
happen with any future foreign or `mmap`ed bytes.

*Fix:* the compiler knows which slot holds `""`, so that slot returns
on the length test alone, with no load. The page-safe load's
correctness proof needs `n >= 1`.

### Test-tool bugs (not the algorithm)

- `emit_queries` crashes on an empty key: `Bytes.set b (len - 1)`.
- `emit_rs` uses OCaml's `%S`, which writes non-ASCII as `\ddd`. That
  isn't Rust syntax.
- `c_str` doesn't escape a newline or control bytes. A real compiler
  emits its own literals.

### Fallback is real

results.md says no set needed the fallback. Two of mine did:
- past16, because it needs at least 5 byte positions and the budget is
  4.
- k200short, 200 keys over a 2-letter alphabet.

The fallback is correct, but it's the length switch, 6 to 8 times
slower. Keys that differ only past byte 16 are not the problem on their
own: past16b and prefix both hashed. Lemire's generator searches harder
(more positions, larger tables). Before falling back, the compiler could
try a 64-bit mix of the first and last 8 bytes, with no positions to
find. That's worth a look, not a blocker.

## 3. The over-read reasoning

What results.md says about the runtime checks out
(lib/native/runtime/ren_rt.c, `ren_alloc_str`; ren_rt.h, `ren_str`):
- Owners get `sizeof(ren_str) + len + 1`, rounded up to words.
- Small objects bump from 1 MB `malloc` chunks.
- Literals have `bytes[len + 1]`.
- So 1 to 8 bytes are readable past an owner's end, not 16.

The page-safe load is correct for `n >= 1`. `s` is mapped. If
`s & 4095 <= 4080`, all 16 bytes are in the same 4 KB page. Otherwise,
either the string itself crosses the boundary (so the next page is
mapped), or the load is moved back to end at the boundary and shuffled
down. The 4 KB check is conservative on this machine's 16 KB pages and
exact on x86. The K and P placements in the fuzz drive both branches.
The only gap is `n = 0` (above).

I agree with "keep the page check, promise nothing", with three
additions:

1. **The empty string:** see the crash above.
2. **Sanitizers:** the attribute goes on the whole lookup function (bug
   5). Valgrind will flag the read too.
3. **Memory tagging (Arm MTE, Apple's EMTE).** With synchronous tag
   checks, an unaligned 16-byte load that runs into the next allocation's
   16-byte granule faults. The page check doesn't help with that. Two
   forms survive tagging:
   - padding every allocation to a 16-byte multiple past `len`, which
     keeps the over-read inside the string's own granules;
   - two 16-byte loads aligned down, then a shift.

   This isn't needed now. If Ren ever builds for tagged memory, that's
   the point where padding becomes a promise.

A smaller point: the over-read can touch a neighbouring object that
another thread is writing to. Today's heaps are per thread, but values
do cross actors. The bytes are thrown away, so real hardware is fine.
TSan could report it, and in C11 terms it is a data race. Exempt the
lookup in TSan builds too.

## 4. list-patterns.md against language.md

What fits:
- **`..` as "the rest" fits.** language.md uses `{ w, .. }` in
  patterns and `{ ..order, ... }` in values. A `..rest` that binds in a
  pattern is the mirror of a spread that builds in a value.
- **One rest, fixed pieces either side, is the right single rule.**
- **Leaving out `Bytes` matches §12,** "Formats are the patterns".

What to change or add:

1. **Say why there's one rest.** It's what stops `Str` patterns from
   becoming a parser: `..k "=" ..v` can't be written, and that's on
   purpose. That's `split`'s job. Without this stated, the first request
   will be "allow two". It's the same line §12 draws for bytes.
2. **"Flagged" should say "an error".** language.md says Ren has no
   warnings, so an unreachable arm is an error. That also makes the
   lowering sound: all literal arms can be looked up in one hash before
   any prefix arm is tried, because a literal shadowed by an earlier
   prefix arm can't exist. The note should say this, since order
   matters for prefixes and not for literals. The `[..init, last]`
   example would then be a compile error, and it should say so.
3. **Guards are missing from the lowering.** If a guarded arm
   `"GET" if cond =>` fails, it has to fall through to later arms,
   including prefix arms and `_`. "One lookup, then a dense switch"
   needs a fall-through edge for guarded arms. Show one.
4. **OCaml doesn't use decision trees.** OCaml compiles matches to
   backtracking automata (Le Fessant and Maranget 2001, typing/
   matching.ml). Maranget 2008 is the decision-tree paper. Decision
   trees can duplicate code: in the route example, `idx0` and `idx1`
   are recomputed under every length branch. Choose one on purpose. A
   tree with shared join points (a DAG) fits "complexity in the
   compiler, no surprises" best.
5. **State the `Str` length rule and the boundary guarantee.** `p ..x q`
   matches only if `len >= len(p) + len(q)`. The slice cuts always fall
   on character boundaries, because `p` and `q` are valid UTF-8 and
   UTF-8 resynchronizes. So binding `..x` never checks and never panics
   (strings.md, decision 17). It's a nice property, so say it.
6. **Say how prefix and suffix arms compile.** A hash doesn't apply to
   them. With a few arms, a length test plus a fixed compare per arm in
   order is enough. A trie is for later, if ever.
7. **Covering needs prefix, suffix and length.** One arm `p1 .. q1`
   covers another `p2 .. q2` when `p1` is a prefix of `p2`, `q1` is a
   suffix of `q2`, and the second arm's minimum length is at least the
   first's. `"a" ..x "a"` does not cover `"a"`.
8. **Ban `..x` alone and `[..xs]` alone.** Each is a second spelling of
   the binding `x`. language.md's "one spelling" rule argues for an
   error whose help writes `x`.
9. **Update the cited numbers**
   - NEON took 0.9 to 1.1 ns, not 0.9 to 1.6 ns.
   - The chain took 5.8 to 8.5 ns, not 5.3 to 13.6 ns.
   - rustc took 3.5 to 9.0 ns.

   Also change "none of the 11 sets hit [the fallback]" to "it can
   happen; see verify.md".
10. **The thresholds are confirmed.** At 1 literal, length and compare
    wins (0.36 against 0.53 ns). From 2 up, the hash wins (0.86 against
    1.87 ns).

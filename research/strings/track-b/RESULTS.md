# Track B: string representation, measured

These are measurements of how a `Str` could be laid out. A program can't
see the layout, so it's the compiler's choice, and only numbers should
decide it. Five experiments ran on a C model of Ren's runtime, each
with Rust and Go twins. Nothing in the repo was changed.

## Headlines

1. **Representation B (an inline 16-byte value `{root, u32 offset, u32
   length}`) is the best layout overall.** Against today's A:
   tokenizer 0.76×, sort 0.76×, map 0.92×, group-by 0.98×, logs 1.01×.
   B never lost by more than noise, and it allocates nothing per
   slice. A's tokenizer made 1.03M allocations; B made 2.
2. **SSO (up to 15 bytes inside the value) didn't pay on top of B.**
   It cuts the counts by 28–94% but runs at 1.03–1.10× B's time. To get
   that close it needs an over-read trick: without it, the tokenizer
   ran at 1.22× B. **German strings (Umbra-style) are worse still:**
   1.06–1.19× B, and 1.14× A on logs. A counted root can't be found
   from an interior pointer, so every long slice needs an indirection.
3. **Retention: only "copy when stored" bounds memory.** Keeping 10k
   keys (230 KB) from 512 MiB of input held 522 MiB under always-share
   and under every size threshold (copy under 8 to 64 bytes). Copying
   each slice when it's stored held 18.4 MiB and was *faster*: 528
   against 636 Mcyc. But applied blindly to a tokenizer, "copy when
   stored" costs 1.6× and more memory. A threshold only helps when
   every kept slice is under it.
4. **Building output: `s += x` in place when unique matches a
   Builder.** JSON took 153 against 163 ms, logs 95 against 95 ms.
   Today's `s = s + x` copies the whole string every time: 690× slower
   at 5,000 records, and quadratic. An iolist with `writev` was 2.9–3.3×
   *slower* on JSON and log lines (about 16 ns a piece). It only tied
   for HTTP responses, which were syscall-bound.
5. **Keys: Ren's `Map<Str, _>` (wyhash, the hash kept per entry) runs
   at Rust's FxHashMap/aHash speed.** That's 278 ms for B against
   276–281 ms for Rust with borrowed keys. Rust's std (SipHash) took
   366–394 ms. So the bytes stage's comparison against SipHash flattered
   Ren by about 1.4×. Hashing only a prefix is ruinous: 7.6–7.9×
   slower, because URLs and dotted names share their first 8 bytes.
   Comparing a key's prefix first changed nothing, because the stored
   hash already rejects almost every wrong key.
6. **UTF-8 validation: `ren_utf8_valid` today runs at 0.5–2.6 GB/s; a
   NEON validator runs at 8–73 GB/s.** The NEON one is Keiser and
   Lemire's algorithm, which also gave 9.0 GB/s on CJK and emoji, as
   the `simdutf8` crate does. In a read-parse-respond program, today's
   validator takes 16% of the time on ASCII logs and 41% on CJK text.
   The NEON one takes 1.5% and 7.4%.

**What this says for Ren, in one paragraph.** Build representation
B. Don't add SSO or German strings now; revisit SSO only if
multi-threaded counting makes a count on the root expensive (atomic
counts with no contention cost nothing measurable here). Give `s += x`
in-place append on a unique owner. Don't add a Builder type, and don't
make iolists the default. Keep wyhash with the hash stored in each
entry. Ship a SIMD `from_utf8` before claiming "validated at the
boundary" is cheap. On retention, the evidence favours copying on
store into long-lived structures, or an explicit `copy()` plus the
debug report, over any size threshold.

**Positions:** SSO, German strings and every copy policy all lose a
slice's offset into its root. A short slice copied into the value has
no root. That makes them legal only under the owner's option (c),
where positions are relative to the value. Option (b), offsets relative to
the root, would forbid the copy policies and the inline layouts; B2
measures what (b) would cost.

## Setup and limits

- **Machine:** the owner's M4 Max (16 cores, 128 GB), macOS 15.1,
  Apple clang 16.0.0, rustc 1.99.1, Go 1.27.3. Load average was 1.8 to
  3.4 during sessions (other agents were running; photo analysis wasn't
  visible in `ps`).
- **How it was measured:** `measure.py` runs each set's commands 11
  times, interleaved and rotated each round, each under `/usr/bin/time
  -l`, as bench/native/profile/measure.py does. Each program times its
  own kernel, from after its input is loaded until its last value is
  dropped, and prints a `check=`. Every variant and twin of a workload
  agreed on the check in every run. Tables give the **median of 11
  in-process times** with the spread (min–max), plus the
  whole-process instructions and peak RSS (median). Raw runs are in
  `results/*.jsonl`, and the printed summaries are in `results/*.txt`.
- **The harness is a model of Ren's runtime, not Ren** (`c/rt.h`,
  `c/strs.h`, `c/map.h`). The parts copied from ren_rt.h/ren_rt.c at
  cf7787c:
  - the 8-byte header with a non-atomic count, where 0 means "never
    freed";
  - the size-class free lists over 1 MiB bump chunks (64 words or
    less, bigger goes to malloc);
  - `ren_str_part`, the A slice;
  - arrays that double with realloc;
  - `ren_map`: ordered entries `{hash, key, value}`, an int32 index at
    most 2/3 full, linear probing from the hash's top bits, the stored
    hash compared before the key, and wyhash v4 with Ren's mix.

  It has no index or overflow checks, no panics and no Perceus. The
  harness writes the dups and drops Perceus would emit. Transient
  lookups use raw views (`s_eq_raw`), which stands in for decision 17's
  "what doesn't escape costs nothing". So **kept slices are what's
  measured**, and absolute numbers flatter Ren today. Compare variants
  within a table, and treat twins as a reference, not a race.
- **clang -O2**, as `ren build --release`. Rust is `opt-level=3`,
  `codegen-units=1`, `lto`. Go uses its defaults.
- **Not built:** B's escape for strings of 4 GiB or more (a flag and an
  out-of-line offset), and an allocator that pads every buffer, which
  SSO's fast path assumes. The fast path checks that 16 bytes are in
  the root and falls back to a byte copy otherwise.

---

## B1: the layout of a Str value

**The layouts** (`c/strs.h`):

| | value | owner | a slice | equality / order |
|---|---|---|---|---|
| **A** (today) | 8 B pointer | 32 B header + bytes | a 32 B object `{data, root}`, counting its root | length, then memcmp |
| **B** | 16 B `{root, u32 off, u32 len}` | 16 B header `{count, cap}` + bytes | one count on the root, nothing allocated | the same |
| **B24** (Roc's, `str.zig` `RocStr`) | 24 B `{data, len, root}` | as B | as B | the same |
| **SSO** | B, or up to 15 bytes in the value (last byte `0x80\|len`) | as B | ≤ 15 B: copied into the value, no count; else as B | 16-byte compare when either is inline |
| **SSOmc** | SSO, the inline copy done with `memcpy` | | | |
| **G** (German) | 16 B `{u32 len, 4 B prefix, 8 B inline rest or pointer}` | as A | ≤ 12 B inline; else a pointer to an A owner or A slice object | first 8 bytes in one compare; order by prefix first |
| **-at** | the same, with atomic counts (`REN_RC_ATOMIC`'s) | | | |

**The workloads** (`c/b1.c`; inputs from `c/gen.c`, deterministic):

- **tok:** tokenize 6 MB of code-like text, keeping all 1,030,229
  tokens `{kind, text}`. Then count `== "return"` and drop them.
- **map:** `Map<Str, Int>` counts over 4M keys drawn from a pool of
  200k: 60% identifiers, 25% dotted metric names, 15% URLs. 132,499
  distinct, median length 22, 28% are 15 bytes or less. Then 4M
  lookups.
- **sort:** sort 1M mostly distinct keys of the same mix, kept as
  slices.
- **group:** sum by city over 5M CSV rows, 1,996 cities.
- **logs:** parse 1M log lines into records keeping 6 `Str` fields and
  2 `Int`s, then run three queries.

**Session 2** (`b1x`, 11 runs), median ms (min–max) for the whole
kernel, the drops included:

| workload | A | B | B24 | SSO | SSOmc | G | A-at | B-at | SSO-at |
|---|---|---|---|---|---|---|---|---|---|
| tok | 26.85 (26.1–27.5) | **20.47** (20.0–21.3) | 22.51 | 21.27 (20.5–22.3) | 24.94 | 24.37 | 28.47 | 22.11 | 21.67 |
| map | 306.8 (291–376) | **282.9** (272–312) | 290.9 | 294.5 | 290.2 | 325.1 | 301.4 | 276.0 | 295.5 |
| sort | 342.5 (338–351) | **260.9** (260–263) | 262.5 | 287.8 | 290.7 | 285.3 | 343.0 | 262.4 | 287.2 |
| group | 212.8 (209–215) | **208.5** (206–211) | 209.2 | 217.2 | 216.3 | 220.3 | 213.5 | 215.8 | 216.9 |
| logs | 149.9 (138–163) | 151.9 (144–157) | **142.8** | 156.4 | 156.2 | 170.4 | 158.0 | 154.9 | 158.1 |

**Session 1** (`b1`), the same C binaries with the twins. Its "SSO" is
SSOmc, measured before the fast path was added.

| workload | A | B | SSO(mc) | G | Rust `&str` | Rust `String` | Rust `Rc<str>` | Go |
|---|---|---|---|---|---|---|---|---|
| tok | 26.70 | **20.23** | 24.73 | 24.69 | 21.95 | 46.32 | 55.50 | 51.58 |
| map | 297.9 | **276.1** | 288.0 | 319.7 | 393.2 (SipHash) | 367.4 | 373.8 | 398.4 |
| sort | 341.8 | 261.3 | 291.3 | 286.3 | **146.4** | 207.7 | 221.0 | 258.4 |
| group | 211.5 | **207.7** | 216.7 | 219.5 | 269.5 (SipHash) | 267.8 | | 274.5 |
| logs | 144.3 | 148.9 | 154.7 | 169.9 | **109.9** | 303.5 | 341.7 | 305.9 |

Go has no drop phase: its GC runs whenever it likes.

**What the runtime did** (`results/b1-stats.txt`, from the `STATS`
builds):

| workload | A allocations | B allocations / counts on the root | SSO counts | G allocations |
|---|---|---|---|---|
| tok | 1,030,231 | 2 / 1,030,229 | 63,001 (94% inline) | 135,594 (87% inline) |
| map | 132,500 | 1 / 132,499 | 95,470 (28% inline) | 116,112 |
| sort | 1,000,001 | 1 / 1,000,000 | 490,748 (51%) | 610,164 |
| logs | 6,000,002 | 2 / 6,000,000 | 2,577,165 (57%) | 2,799,848 |

**Peak RSS** (MiB): tok A 59.5, B 42.5, B24 52.3, SSO 42.4, G 44.4,
Rust `&str` 36.9, `String` 63.5. sort A 87.2, B 52.2, B24 67.1, G 66.9.
logs A 429, B 343, B24 413, SSO 343, G 370, Rust `&str` 254, `String`
436.

**What the numbers mean.**

- **B against A** is the cost of a slice object. In tok and sort, every
  kept slice in A is a 32-byte allocation that has to be followed to
  read its bytes: −24% time and −29% to −40% memory. In map and group
  few slices are kept (132k and 2k), so most of the time is hashing and
  probing, and B's gain is 2–8%.
- **logs is the exception:** B ties A (151.9 against 149.9, spreads
  overlapping). B's record is 112 bytes against A's 64, so the record
  array is larger to grow and stream, and B's drop pass took 22.6
  against 13.8 ms. B24 parsed fastest (96 ms against B's 118) on 600M
  fewer instructions. That's clang's code for this function, not a
  property of the layout: B24 is within 1–10% of B everywhere else and
  bigger. **Ambiguous:** don't read "B24 beats B" from that one row.
- **SSO saves counts but not time.** Making an inline value means
  copying up to 15 bytes; making a B slice means three stores and an
  increment on a root whose cache line is already hot. The increment
  is cheaper. With a byte-copy `memcpy` (SSOmc) the tokenizer ran at
  1.22× B. With two 8-byte loads and a mask it ran at 1.04×, but that
  over-read needs padded buffers. Every read then branches on "inline?"
  (sort 1.10× B, map 1.04×). SSO's win, 94% fewer counts in tok, only
  matters if counts are expensive. Atomic counts with no contention
  barely moved B (tok 22.1 against 20.5; sort and map within noise).
  The contended case, many threads counting one root, is the hot-root
  trap of decision 10, and wasn't measured here.
- **German strings** pay an indirection on every long string, because
  an interior pointer can't find its counted root. Long slices still
  allocate an A-style object, and the prefix-first compare doesn't
  rescue sort: the keys share prefixes (`http` begins 15% of them, and
  342 four-byte prefixes cover all 132k keys). G was the slowest C
  layout on map, group and logs. Its strengths, a single 8-byte compare
  and a fixed 16-byte column cell, belong to a column store (DuckDB,
  Arrow's StringView) where strings live in arena buffers that aren't
  counted.
- **Twins.** B's tokenizer ran at 0.93× Rust's borrowed `&str`, which
  needs a lifetime, and at 0.44× Rust's `String`. In logs, B was 1.38×
  `&str` and 0.50× `String`. In sort, Rust's `sort_unstable` (ipnsort)
  beat the harness's quicksort 2×; that's the sort algorithm, not the
  layout. Go shares substrings as B does, but it ran 2–2.5× slower than
  B on tok and logs because of GC and allocation.

**What this says for Ren.**

- **Build B (decision 17's representation B).** It wins or ties
  everywhere and allocates nothing per slice. It also keeps slices
  "values of the same type" at 16 bytes, two words, which decision 14's
  small-value rule can carry in registers.
- **Pick B (u32 offset and length) over B24 (Roc's 24 bytes) unless
  the 4 GiB escape costs something** in code that never sees one.
  B24's only clean win was a codegen artifact, and it costs 20–29% more
  memory in tok, sort and logs.
- **Don't do SSO or German strings now.** SSO stays open if threaded
  counting turns out to be expensive. It is a pure compiler change
  later, invisible to programs, *provided positions are value-relative
  (option c)*.
- **Ambiguous:** in records with many `Str` fields (logs), 16-byte
  values against 8-byte pointers is a wash, and the record size shows
  up in the drop pass and in memory streaming. A program with a
  million records of 10 strings each would see the same.

---

## B2: retention

**The workloads:**

- **keep** (`c/b2.c`): reads 64 files of 8 MiB (512 MiB, generated
  in full, not scaled down) one at a time, each whole into one `Str`.
  It keeps the first field of every 268th line in a `Map<Str, Int>`:
  10,039 keys, 230,654 bytes. Key lengths are 8–16 (50%), 17–32 (35%)
  and 33–80 (15%), about 157 kept keys a file.
- **tok:** B1's tokenizer, where every token is kept.

**The policies** (`strs.h`): `share` always shares (today's rule);
`nN` copies any slice shorter than N bytes when it's made; `store`
copies a slice when it's stored in a collection (map insert, array
push); SSO copies under 16 bytes by layout.

**keep**, median of 11:

| policy | A ms | A RSS MiB | B ms | B RSS MiB | SSO ms | SSO RSS MiB |
|---|---|---|---|---|---|---|
| share | 206.6 (201–210) | **522.2** | 209.5 | 522.0 | 207.6 | 522.0 |
| n8 | 210.5 | 522.2 | 207.2 | 522.0 | 207.9 | 522.0 |
| n16 | 208.7 | 522.3 | 208.5 | 522.1 | 208.2 | 522.0 |
| n24 | 206.7 | 522.4 | 208.2 | 522.2 | 207.1 | 522.1 |
| n32 | 207.6 | 522.4 | 209.8 | 522.3 | 208.7 | 522.2 |
| n64 | 206.8 | 522.5 | 208.0 | 522.3 | 208.3 | 522.2 |
| **store** | **198.5** (189–218) | **18.5** | 201.0 | **18.4** | 200.1 | **18.3** |
| Rust `String` (forced by the borrow checker) | 192.1 | 10.8 | | | | |
| Go substrings (share) | 235.5 | 663.4 | Go `strings.Clone` | 154.7 ms, 38.8 MiB | | |

Whole-process cycles: A share 636 Mcyc against store **528 Mcyc**.
With store, a freed 8 MiB buffer is reused by the next read; with
share, every read faults in fresh pages.

**tok**, B layout (A in `results/b2.txt` shows the same pattern):

| policy | total ms | RSS MiB |
|---|---|---|
| share | **20.65** | **42.5** |
| n8 | 29.70 | 55.9 |
| n16 | 31.86 | 61.3 |
| n32 | 32.26 | 63.4 |
| n64 | 31.88 | 63.8 |
| store | 32.97 | 63.8 |
| SSO (share; copies ≤ 15 B into the value, no allocation) | 21.94 | 42.4 |

**What the numbers mean.**

- **A threshold policy didn't bound retention.** A buffer stays alive
  if *any* slice kept from it is at least N bytes. With k kept slices
  in a buffer and p the chance that one is shorter than N, the buffer
  is freed with probability p^k. Here k ≈ 157 and, even at N = 64,
  p ≈ 0.95, so p^k ≈ 0.0002: every buffer stays (522 MiB for 225 KB of
  keys, about 2,300×). Thresholds only help when *all* kept slices are
  short, as with SSO's inline case, which keeps nothing alive.
- **Copy when stored bounds it at 18 MiB, and was faster here,** but on
  the tokenizer it's the wrong default: the copies cost 1.6× the time
  and 1.5× the memory, because there the root stays alive anyway.
- **Twins:** Rust has no choice; the borrow checker makes you copy
  (`to_string()`). Go's substrings retain exactly as Ren's share does
  (663 MiB), which is why Go added `strings.Clone`; its doc comment
  describes this case (`$GOROOT/src/strings/clone.go`).

**What this says for Ren.**

- **There's no free automatic policy.** Size thresholds are useless
  for bounding memory and cost time. "Copy when stored" helps one
  shape (a few keys from a huge stream) and hurts another (a
  tokenizer).
- **The defensible design is decision 17's as written:** always
  share; `copy()` is explicit and free on an owner; the debug report
  names the slices keeping big roots alive. One addition is worth
  considering, because it's where the owner's "complexity in the
  compiler" ethos points: copy on store **only when the compiler can
  see the root dies before the collection does**, as here (the chunk
  is dropped at the end of each loop iteration, while the map lives
  on). That's an escape-and-lifetime fact Perceus's analyses already
  compute. It isn't measured as a compiler feature, only as the
  policy's effect (`store`): 28× less memory and 17% fewer cycles.
- **Positions:** every copy policy, and SSO, move a slice's bytes to a
  new place. Under option (b), offsets relative to the root, the
  `at:` a format error reports would differ between share and copy,
  and between the interpreter and native builds. Under option (c),
  relative to the value, they can't differ. These measurements are
  evidence for (c): it keeps every row of this table legal.

---

## B3: building output

**The variants** (`c/b3.c`, one binary per variant):

- **concat:** `s = s + x`, a new string each time, as `ren_str_concat`
  does today.
- **inplace:** `s += x`, appended in place when `s` is unique and a
  whole owner (Perceus's test), with room doubling.
- **builder:** a separate Builder type, with no count to test.
- **iolist:** the pieces kept as `Str` values (literals, slices of the
  input, numbers inline) and written with `writev`, 1024 at a time.

**The workloads:**

- **json:** 1M people as one JSON array, 105 MB, with string escaping.
- **logs:** 1M records re-emitted as logfmt, 133 MB.
- **http:** 100k responses, each 7 headers and a 512–1535 byte body
  sliced from a page, each written on its own.

Output went to `/dev/null`.

| workload | concat | inplace | builder | iolist | Rust `String` | Rust iovec | Go `strings.Builder` |
|---|---|---|---|---|---|---|---|
| json, 1M | (quadratic) | **153.2** (149–168) | 162.6 (153–170) | 441.2 | 124.2 | | 157.4 |
| logs, 1M | (quadratic) | 95.2 (90–100) | **94.7** (90–103) | 312.4 | 88.3 | | 147.0 |
| http, 100k | 54.7 | 55.0 | **46.7** | 55.4 | 66.1 | 53.2 | 73.4 |
| json, 5k records | **521.8** | 0.76 | 0.83 | 1.90 | | | |
| logs, 5k records | **545.2** | 0.44 | 0.46 | 1.35 | | | |

All in ms. Peak RSS for json: inplace 321, builder 263, iolist 706 MiB.

**What the numbers mean.**

- **In-place append equals a Builder.** The uniqueness test is a load
  and a compare on a line already in cache. The one gap, http (55.0
  against 46.7), is reuse, not the test: the builder kept its buffer
  across responses, while inplace started each response from `""` and
  grew it again.
- **Today's concat is quadratic**: 690× to 1,240× slower at 5k records,
  and 1M records doesn't finish in reasonable time. It ties in http
  only because each response is short.
- **The iolist lost by 2.9–3.3×** on json and logs. Each piece is a
  16-byte value plus an iovec entry, about 16 ns a piece against a
  memcpy of 5–20 bytes, and its peak memory was 1.7–2.7× the
  builder's. It tied
  on http, where the syscalls dominate and the 1 KiB body isn't
  copied. **Limit:** `/dev/null` doesn't copy what it's given, so a
  socket, which does, would charge the builder and the iolist the
  same copy into the kernel. The iolist's one advantage, no user-space
  copy of large pieces, is real but small next to its per-piece cost.

**What this says for Ren.**

- **Make `s += x` append in place when the string is unique and an
  owner with room,** growing by doubling. That's Perceus's reuse,
  applied to `Str` (an owner needs a capacity field, which B's 16-byte
  header has).
- **Today's `s = s + x` should not ship** as the way to build output.
- **No separate Builder type is needed for speed.** One obvious way,
  `s += x`, is enough. A `clear()` that keeps the room would close the
  reuse gap http showed.
- **iolists:** don't make them the default output path. They earn
  their place only for large existing pieces such as file bodies, and
  `Net.write(parts)` taking several values is enough for that.

---

## B4: keys

The B1 map and group workloads, with the hash and the equality
varied:

- **wy:** Ren's own: wyhash, the hash kept in each entry and compared
  before the key.
- **fx:** FxHash's multiply-rotate.
- **prefix:** hash only the length and the first 8 bytes, what a
  prefix-first key would hash.
- **nohashcmp:** don't compare the stored hash; the key's own equality
  goes first, which for G is prefix-first.

Rust twins use std `HashMap` with std (SipHash 1-3), `rustc-hash` 2.1.2
Fx, `ahash` 0.8.12 and `foldhash` 0.2.0. Median ms of 11.

**map** (4M inserts or updates, then 4M lookups):

| | wy | fx | prefix | nohashcmp |
|---|---|---|---|---|
| A | 299.9 | 340.1 | 2376 | 304.1 |
| B | **278.3** (272–286) | 321.1 | 2127 | 275.1 |
| SSO | 290.6 | 336.6 | 2239 | 288.5 |
| G | 316.2 | 345.3 | 2484 | 314.3 |

| Rust | std (SipHash) | Fx | aHash | foldhash |
|---|---|---|---|---|
| `&str` keys | 394.1 | **275.9** | 281.2 | 283.9 |
| `String` keys | 366.3 | **262.4** | 265.0 | 286.6 |

Go `map[string]int64`: 399.6.

**group** (5M updates, 1,996 keys): every C row is 208–235 ms
(B-wy 208.0). Rust is 226–238 with Fx/aHash/fold and 266–271 with std;
Go is 277.9.

**What the numbers mean.**

- **Ren's map matches Rust's fast hashers.** B-wy at 278 ms against
  Fx's 263–276 ms puts Ren's map within 1.06× of the best Rust row.
  Against std's SipHash it's 0.71–0.76×. The bytes stage's Rust twin
  used SipHash, so its "Ren against Rust" for `Map<Str, _>` flattered
  Ren by about 1.4×.
- **Prefix hashing is ruinous on real keys.** The 132,499 distinct
  keys fall into only 61,129 `(length, first 8 bytes)` buckets; the
  largest holds 2,082 keys, all URLs starting `https://`. A
  prefix-only hash collides there, and the map ran 7.6–7.9× slower.
- **Prefix-first equality buys nothing beside a stored hash.** With the
  hash compare removed, G's 8-byte length-and-prefix compare does the
  rejecting, and the times don't move (B 275 against 278, G 314 against
  316). The stored 64-bit hash already rejects almost every wrong key
  before the bytes are touched.
- **My C FxHash was slower than wyhash on these keys** (median 22
  bytes, URLs up to 90): Fx is a serial multiply every 8 bytes, while
  wyhash takes 16 bytes a step. Rust's Fx (rustc-hash 2) uses a
  different string hash, so don't compare "C fx" with "Rust Fx".

**What this says for Ren.**

- **Keep wyhash with the hash stored in each entry.** It's at the
  fast-Rust frontier and is seeded (determinism: the walk's fixed
  `x.hash()` is separate).
- **Don't hash a prefix,** and don't change a key's representation to
  serve equality.
- **Re-measure the bytes stage's `Map` against Rust with
  FxHashMap or aHash**, so "within 2× of Rust" is against Rust as it's
  used for speed.

---

## B5: UTF-8 validation

**The validators** (`c/b5.c`):

- **ren:** `ren_utf8_valid` from ren_rt.c, verbatim.
- **ascii:** the same with a 16-byte ASCII skip, written as a naive
  attempt.
- **neon:** Keiser and Lemire's lookup algorithm ("Validating UTF-8 In
  Less Than One Instruction Per Byte", Software: Practice and
  Experience 2021, as simdjson and simdutf implement it), in NEON,
  64-byte blocks with an all-ASCII skip.

`b5 test` checked that all three agree on 2M random and mutated
inputs: 0 disagreements, 1.42M of them invalid. Rust: `std::str::
from_utf8` and `simdutf8` 0.1.5. Go: `utf8.Valid`.

**Throughput**, GB/s, median of 11 (256 MiB of work each):

| text | piece | ren (today) | ascii | **neon** | Rust std | Rust simdutf8 | Go |
|---|---|---|---|---|---|---|---|
| ascii | 1 MiB | 2.61 | 13.9 | **72.8** | 35.6 | 72.7 | 60.6 |
| latin (1 in 12 accented) | 1 MiB | 0.97 | 0.81 | **8.98** | 1.02 | 8.99 | 0.78 |
| cjk | 1 MiB | 1.09 | 0.85 | **9.02** | 1.05 | 9.02 | 1.17 |
| emoji (half 4-byte) | 1 MiB | 0.50 | 0.45 | **9.03** | 0.52 | 9.03 | 0.45 |
| mixed (2% non-ASCII) | 1 MiB | 1.71 | 2.82 | **13.5** | 3.92 | 13.5 | 3.23 |
| ascii | 64 B | 2.35 | 9.28 | **18.5** | 6.97 | 18.6 | 5.86 |
| cjk | 64 B | 2.24 | 1.81 | **8.24** | 2.00 | 6.00 | 2.19 |
| mixed | 64 B | 1.41 | 1.87 | **5.10** | 2.00 | 5.92 | 1.63 |

**Read, validate, parse, respond** (`b5 rpr`): read a file whole,
validate it as `Str.from_utf8` would, split lines and fields, build a
response line for each, and write. Median ms of 11:

| file | total, no validation | ren: validate / total (share) | neon: validate / total (share) |
|---|---|---|---|
| logs.txt, 94 MB ASCII | 182.4 | 37.3 / 229.8 (**16%**) | 2.9 / 189.4 (**1.5%**) |
| people.csv, 59 MB, 5% of names non-ASCII | 158.1 | 24.3 / 182.6 (**13%**) | 1.9 / 162.6 (**1.2%**) |
| cjk-big.txt, 64 MiB of CJK | 94.8 | 64.0 / 157.4 (**41%**) | 7.6 / 102.2 (**7.4%**) |

**What the numbers mean.**

- **Today's validator is byte-at-a-time, even on ASCII.** At 2.6 GB/s
  on ASCII it's 23–28× slower than NEON and Go, and 41% of a CJK
  program's time.
- **My naive ASCII skip helped ASCII and hurt everything else.** It
  re-tests 16 bytes at every non-ASCII byte. It shows that "add an
  ASCII fast path" isn't the fix; the block algorithm is.
- **The NEON version reaches `simdutf8`'s speed exactly** at 1 MiB. On
  64-byte pieces it's faster on CJK (8.2 against 6.0) and slower on
  mixed text (5.1 against 5.9). The algorithm is under 100 lines here
  and needs no tables beyond three 16-byte lookups.
- **On 64-byte pieces every validator slows down** (the setup and tail
  handling). Validating many small strings costs more per byte than
  validating one buffer, which is an argument for validating at the
  boundary, once, as formats.md says.

**What this says for Ren.**

- **"Checked once, at the boundary" is only cheap with a SIMD
  validator.** Ship Keiser–Lemire in the runtime (NEON, plus SSE4/AVX2
  on x86, or vendor simdutf if a C++ dependency is acceptable). The
  algorithm is exact and table-driven, so the interpreter and native
  builds can't disagree: both answer "valid UTF-8 or not", and the
  error's offset can come from a scalar re-scan of the failing block.
- At 1–7% of a read-parse-respond program, validation stops being a
  reason to want an unchecked `Str` constructor.

---

## Reproducing

From `track-b/`:

```sh
./gen.sh                      # data/: about 1 GB, deterministic (c/gen.c)
./build.sh                    # every C variant into bin/, the Rust and Go twins
./bin/b5 test                 # the validators agree
python3 -I measure.py b1 11   # B1 with the twins      -> results/b1.txt, b1.jsonl
python3 -I measure.py b1x 11  # B1, the C layouts only -> results/b1x.txt
python3 -I measure.py b2 11   # B2
python3 -I measure.py b3 11   # B3
python3 -I measure.py b4 11   # B4
python3 -I measure.py b5 11   # B5 throughput
python3 -I measure.py rpr 11  # B5 read-parse-respond
# the counts: bin/b1s-<A|B|SSO|G> <tok|map|sort|group|logs> data; bin/b2s-<A|B|SSO>-share data
```

`measure.py <set> <runs> <filter>` runs a subset, for example
`measure.py b1x 11 tok/`. Each set's exact command lines are the first
line of its `results/<set>.jsonl`. Sessions, in order and one at a
time: b1 09:20, b1x 09:23, b2 09:26, b3 09:27, b4 09:29, b5 09:33, rpr
09:35, 2026-10-29. Load at start: 1.8, 1.8, 2.4, 2.4, 3.4, 2.0, 3.1.

**Re-measuring the headlines.** For an independent re-run, the rows
that carry the conclusions are:

- `b1x` tok, sort and map, for A, B and SSO;
- `b2` keep, share against store, and tok, B share against store;
- `b3` json and logs, inplace against builder against iolist;
- `b4` map, B-wy against Rust `fx` and `std`;
- `rpr`, all rows.

## Prior art cited

- **Roc's seamless slices and small strings:**
  `/tmp/ren-refs/roc-rust/crates/compiler/builtins/bitcode/src/str.zig`.
  `RocStr` is `{bytes, length, capacity_or_alloc_ptr}`, 24 bytes, with
  the slice bit in the length and the allocation pointer `>> 1` in the
  capacity (lines 20–86). Small strings take up to 23 bytes. B24 here
  is its slice layout without the small-string case.
- **Go:** a substring shares its backing array and the GC retains the
  whole of it. `strings.Clone` was added for exactly B2's case
  (`$GOROOT/src/strings/clone.go`, its doc comment).
- **German strings:** Neumann and Freitag, "Umbra: A Disk-Based System
  with In-Memory Performance", CIDR 2020. They're also used by DuckDB
  (`string_t`), Apache Arrow's `StringView` and Polars' 2024 string
  rewrite. All of them use arena buffers that aren't counted, which is
  why the layout fits them and not a counted root here.
- **Swift's String:** 16 bytes, with up to 15 UTF-8 bytes inline
  (`stdlib/public/core/StringObject.swift` and `SmallString.swift` in
  swiftlang/swift; the local clone doesn't include stdlib, so this is
  cited from upstream).
- **UTF-8 validation:** Keiser and Lemire, SPE 51(5), 2021; simdutf
  (github.com/simdutf/simdutf); the `simdutf8` crate 0.1.5, measured
  here.

## Files

- `c/rt.h`: the runtime model (header, counts, allocator, wyhash, Fx).
- `c/strs.h`: the layouts A, B, B24, SSO and G, and the retention
  policies.
- `c/map.h`: Ren's `Map<Str, Int>`, with B4's knobs.
- `c/b1.c`: B1 and B4. `c/b2.c`: B2. `c/b3.c`: B3. `c/b5.c`: B5.
  `c/gen.c`: the inputs.
- `rust/src/bin/{b1,b2,b3,b5}.rs` and `go/{b1,b2,b3,b5}/main.go`: the
  twins.
- `build.sh`, `gen.sh`, `measure.py`: building and measuring.
- `results/`: every run (`*.jsonl`), the summaries (`*.txt`) and the
  counts (`*-stats.txt`).

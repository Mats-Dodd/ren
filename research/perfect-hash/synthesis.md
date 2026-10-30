# Track B synthesis: string `match` as a perfect hash

This pulls together results.md, verify.md and list-patterns.md in this
folder. No new timings were run for it. Every number below is from
verify.md's re-run, which corrected results.md's clock problem (four
sets ran at 2.6 GHz). Load during that run was 2.98 to 4.92 before each
set, 6.86 once after the first headers run, which was re-run at
2.98/3.12. Times are ns per lookup, M4 Max, hyperfine `-N`, 3 warmups,
25 runs, empty loop subtracted. Ratios are ratios of means, with spread
from the combined standard deviation.

## The short version

- Ren has no string literal patterns today. Code writes an `==` chain,
  which compiles to a length test and `memcmp` per arm.
- A perfect hash with a fixed 16-byte masked compare takes 0.9 to 1.1 ns
  on every real key set. The chain takes 5.8 to 8.5 ns. rustc's `match`
  takes 3.5 to 9.0 ns.
- The win is branch prediction. Both run about 25 to 35 instructions.
  The hash has no data-dependent branch on a hit, so it runs 6 to 9
  instructions a cycle against about 1.
- The compare is the whole trick. The same hash with `memcmp` is barely
  faster than the chain.
- It wins from 2 keys. At 1 key a length test and compare is better.
- The generator is correct. A fuzz found five emitter bugs at the edges
  and one crash on the empty string. All have known fixes.

## What the compiler emits, and when

The literal arms of one column at one node of the match form a set. The
compiler looks the subject up in that set once and gets an arm index or
"none". The arms then `switch` on that index, which C turns into a jump
table. Prefix and suffix arms and guards are handled around that (see
the list-pattern rules).

How the set is looked up:

| set | emit | measured |
|---|---|---|
| 0 literals | nothing | |
| 1 literal | length test, then an inline fixed compare | 0.36 ns; the hash takes 0.53 ns |
| 2 or more, all keys 16 bytes or less | perfect hash, then a 16-byte masked compare behind the page check | 0.86 ns at 2 keys, 0.90 to 1.12 ns up to 45 keys |
| 2 or more, some keys over 16 bytes | the same hash; those slots compare with `memcmp` | json24, one 21-byte key: 0.95 ns |
| no hash found within the budget | length switch, then word compares (what rustc does) | 6 to 8 times slower than the hash |

The hash is Lemire's shape. It reads 0 to 2 byte positions (first,
last, or a fixed index), sums table values with the length, and masks
into a table of next_pow2(n) slots. The generator tries positions
greedily and takes a few ms. It found a hash for all 11 real sets and
for most adversarial ones. Two adversarial sets fell back: keys that
need more than 4 positions, and 200 keys over a 2-letter alphabet.
Before falling back, the compiler should try a 64-bit mix of the first
and last 8 bytes. That needs no positions and is worth one experiment.

No upper key count was found. 200 keys hash correctly once the table
widths are fixed. Read-only data is 256 bytes per byte position plus
about 18 bytes a slot, about 830 bytes for 20 headers. Cold-cache cost
was not measured.

**The compare form depends on the build:**

| build | compare | why |
|---|---|---|
| release, clang, arm64 | NEON 16-byte load, mask, compare | fastest, 0.90 to 1.12 ns |
| debug, tcc | two 8-byte words, masked, compared as integers | tcc has no NEON intrinsics; 1.06 to 1.35 ns, within 1.3x of NEON |
| sanitizer builds | `memcmp` | ASan, TSan and Valgrind would flag the deliberate over-read |
| x86 | SSE2 twin of the NEON form | not measured; measure before claiming |

All forms compute the same answer, so this keeps decision 20's rule 4:
the optimization is invisible, and a debug build means the same.

**The over-read.** The 16-byte load reads past a short key's end.
Keep Lemire's page check and promise no padding. It costs about 3
instructions and no measurable time. It works for bytes from anywhere,
including future `mmap`ed or foreign bytes, which padding would not
cover. If Ren ever targets Arm memory tagging, padding to a 16-byte
granule becomes a promise then, not now.

**What the emitter must get right** (all found by verify.md's fuzz):

1. Size the value table by the arm count. `int8_t` breaks at 128 arms.
2. Size the length table by the longest key. `uint8_t` breaks at 256
   bytes, and the empty-slot sentinel collides with a real 255-byte key.
3. When `""` is a key and a "last byte" position is used, guard it:
   `n > 0 ? A[s[n-1]] : 0`. Today it reads `s[-1]`.
4. Give the key table a width of at least 16. The set `{""}` gets 0.
5. Put `no_sanitize` on the emitted lookup function, not the inlined
   load. Or, simpler, emit `memcmp` in sanitizer builds.
6. The `""` slot answers on the length test alone, with no load. An
   empty string at the first byte of an unmapped page crashes the NEON
   form. It can't happen in today's runtime, but it can with foreign
   bytes.

## Verified speedups

Phash means the NEON form with the page check.

| set | keys | chain (Ren today) | rustc `match` | phash | vs today | vs Rust |
|---|---:|---:|---:|---:|---:|---:|
| methods | 9 | 5.94 | 4.83 | 1.04 | 5.7x ± 0.2 | 4.6x ± 0.3 |
| headers | 20 | 7.34 | 7.10 | 0.90 | 8.2x ± 0.5 | 7.9x ± 0.5 |
| jsreserved | 45 | 8.08 | 9.01 | 1.02 | 7.9x ± 0.4 | 8.8x ± 0.3 |
| json8 | 8 | 5.79 | 4.57 | 1.06 | 5.5x ± 0.1 | 4.3x ± 0.6 |
| json24 | 24 | 7.86 | 7.17 | 0.95 | 8.3x ± 0.3 | 7.5x ± 0.3 |
| schemes | 6 | 6.04 | 3.51 | 1.12 | 5.4x ± 0.2 | 3.1x ± 0.3 |
| renkw | 35 | 8.50 | 7.21 | 1.06 | 8.0x ± 0.4 | 6.8x ± 0.2 |

Small sets and skewed traffic:

| set | chain | rustc | phash | vs today | vs Rust |
|---|---:|---:|---:|---:|---:|
| one key | 0.36 | 0.38 | 0.53 | 0.68x ± 0.04 | 0.72x ± 0.02 |
| two keys | 1.87 | 1.79 | 0.86 | 2.2x ± 0.2 | 2.1x ± 0.3 |
| three | 2.98 | 2.78 | 0.90 | 3.3x ± 0.3 | 3.1x ± 0.1 |
| four | 3.44 | 3.48 | 0.89 | 3.9x ± 0.1 | 3.9x ± 0.6 |
| 9 methods, 70% GET | 3.50 | 1.52 | 0.98 | 3.6x ± 0.0 | 1.6x ± 0.2 |

On skewed traffic rustc's branches predict well, so its lead shrinks to
1.6x. The hash still wins.

What these numbers don't cover:
- The "today" row is the chain Ren emits, run on `(data, len)` in C.
  A real `Str` adds one load for its length and pointer, the same for
  every form.
- Hot loop, warm cache, random queries with 10% near misses.
- arm64 only. x86 is unmeasured.
- Rust with the `phf` crate or a hand-written perfect hash would close
  the gap. The comparison is to Rust's plain `match`, which is what
  serde's derived field dispatch uses.

## Where it applies beyond routing

Routing is the weakest case. A request's routing touches a few segments
once, and `segments()` allocating an array costs more than the match.
The win matters where a string match sits in a hot loop.

| use | key set | measured | how it gets the hash |
|---|---|---|---|
| **Lexers**: keywords after an identifier is scanned | Ren's 35 keywords, JS's 45 reserved words | 1.06 and 1.02 ns against 8.50 and 8.08 (8x) | a plain `match ident` with keyword arms. The biggest real win, and it serves stage 18's self-hosted compiler. |
| **json field names** in shape decoding | 8 and 24 fields | 1.06 and 0.95 ns against 5.79 and 7.86 (5.5x, 8.3x); 4.3x and 7.5x faster than rustc's match, which serde uses | a library can't write a `match` over a type's field names. It needs owner decision 3. |
| **Method parse** | 9 methods | 1.04 ns against 5.94; 0.98 against 3.50 on skewed traffic | a derived `parse` on `Method`, see fieldless sums |
| **Header names** | 20 headers | 0.90 ns against 7.34 (8.2x) | `match` in `http`. Header names are case-insensitive, which was not measured. See owner decision 5. |
| **CLI flags** | 5 to 30 flags | not measured; the sizes match schemes and json8 | `match arg` with `"--" ..name` prefix arms. It runs once at startup, so speed doesn't matter. The pattern syntax is the win. |
| **Fieldless sum parse** | `Role = Admin \| Member`, `Method = Get \| ...` | same as methods | the derived `parse` (a reserved name, decision 20 rule 3) emits a `match` on constructor names, which gets the hash with no extra work |

Where it doesn't apply:
- One literal. Use the plain compare.
- Key sets known only at run time. Use a `Map`.
- Prefix and suffix arms. They're tested in order, each a length test
  and a fixed compare. A trie is for later, if ever.
- `Bytes`. Formats are the patterns (language.md section 12).

## List patterns in five rules

1. **A sequence pattern is fixed pieces in front, at most one `..` in
   the middle, and fixed pieces at the back.** On `Array<T>` a piece is
   an element pattern: `[]`, `["v1", "keys", k]`, `[first, ..rest]`,
   `[..init, last]`. On `Str` a piece is a string literal: `"GET"`,
   `"Bearer " ..token`, `..stem ".json"`, `"<" ..inner ">"`. One rest is
   on purpose: it stops patterns becoming a parser. `..k "=" ..v` can't
   be written; that's `split`'s job. No `Bytes` patterns, no `Char`, no
   case folding, no regex.
2. **`..name` binds the middle as a slice of the same type; `..` alone
   ignores it.** It copies nothing (decision 17). On `Str`,
   `p ..x q` matches only when `len >= len(p) + len(q)`, and since `p`
   and `q` are valid UTF-8 the cuts fall on character boundaries, so
   binding never checks and never panics. `..x` alone or `[..xs]` alone
   is an error whose help writes `x`: one spelling.
3. **String literals are patterns wherever a pattern goes,** inside
   or-patterns and `as` too: `"GET" | "HEAD" =>`, `["v1" | "v2", ..]`.
   Each alternative binds the same names at the same types, as now.
4. **Exhaustiveness: array lengths are constructors, strings are an
   infinite family.** An array column splits lengths the way rustc's
   slice patterns do, so `[]`, `[_]` and `[_, _, ..]` cover every array
   with no `_`. A `Str` literal or prefix never covers `Str`, so a
   string match needs `_` or a binding. An arm an earlier arm covers is
   an error, since Ren has no warnings. One arm covers another when its
   prefix is a prefix of the other's, its suffix a suffix, and its
   minimum length no longer. `"a" ..x "a"` doesn't cover `"a"`.
5. **The first arm that matches wins, and the lowering keeps that
   invisible.** Because a covered literal is an error, all literal arms
   of a column can be looked up in one hash before any prefix arm, with
   the same result. A guarded arm that fails falls through to the next
   arm that can match, prefix arms and `_` included, so a guarded arm
   ahead of a literal it matches is tested first.

## Owner decisions, with recommendations

1. **Ship `Str` prefix and suffix patterns with literals, or literals
   only?** Recommend both. It's the same one rule, and prefixes are the
   common real case (`Bearer `, `--flag=`, `/v1/`).
2. **Keep the page check and promise no padding?** Recommend yes. It's
   free here, and it's safe for bytes the runtime didn't allocate.
   Revisit only for memory tagging.
3. **How does a library like `json` get the hash for field names it
   only knows from a shape?** It can't write a `match` over them, and
   rule 2 of decision 20 says std gets no power a user library lacks.
   Options:
   - (a) The compiler lowers `keys.index(s)` to the perfect hash when
     `keys` is a build-time constant `Array<Str>`: a top-level `let`, or
     a value release specialization folds, such as a shape's field names
     after `keys: camel_case`. Invisible, general, one generator.
   - (b) A std type, say `Keys.of([...])`, whose table is computed by a
     generator written in Ren at build time, plus a 16-byte compare
     primitive. Explicit, but two generators, one in OCaml for `match`
     and one in Ren.
   - (c) Nothing. json uses a `Map` (7 to 9 ns).

   Recommend (a). It's decision 20's rule 4 exactly, and any third
   party's msgpack gets it too. It depends on release builds folding
   `T.shape` and the format's settings to constants, which shapes.md
   promises and stage 12 builds.
4. **One lowering, or a decision tree against a backtracking
   automaton?** Recommend a decision DAG: Maranget's 2008 trees, with
   shared join points so tests aren't duplicated under every length
   branch. OCaml itself uses backtracking automata; trees are easier to
   read in `--emit-c` and keep each segment tested once.
5. **Case-insensitive header names.** Recommend no case-folding pattern
   in the language. `http` lowercases the name first, its own policy
   (decision 20 rule 5); HTTP/2 names arrive lowercase anyway. The cost
   of lowercasing a 16-byte word first was not measured; measure it in
   stage 12.
6. **Keep `[..init, last]` on `Array`?** Recommend yes. It falls out of
   rule 1 and costs nothing extra.

## Staging

The work splits in two: the patterns, which are language, and the hash,
which is an invisible optimization.

1. **Patterns, in "the `just`, natively".** Parse string literal
   patterns and the sequence patterns, type them, extend
   lib/sema/exhaust.ml with length constructors and the `Str` family,
   and make covered arms errors. Run them in the interpreter, and
   natively as today's chain (a length switch is fine). The `just` is
   the first program that needs them: its CLI flags and its lexer's
   keywords. This closes the language gap the owner named.
2. **The lowering, in the same stage.** The decision DAG in the native
   `match` (today's tag switch is its one-column case), gen.ml's
   generator in the compiler with the six fixes above, the NEON, two-word
   and `memcmp` compares in the runtime, and sanitizer builds on `memcmp`.
   Done when the just's lexer and a keyword kernel in bench/native run
   at least as fast as Rust's `match`, measured.
3. **Libraries, in stage 12.** The derived `parse` for fieldless sums
   emits a string `match`. `keys.index(s)` on a build-time constant
   (decision 3) lands with `T.shape`, and `json`'s field dispatch uses
   it. `http` routes with list patterns and parses `Method` and header
   names through the same path. Measure json decoding against serde
   there, end to end, not only the field dispatch.

Not blocking any of this: the 64-bit-mix fallback, x86 numbers, and
cold-cache cost. Each is one experiment, run when it's needed.

## Files

- results.md: the first run, its method and the generator's choices.
- verify.md: the re-run, the fuzz, the over-read check, and the critique
  of list-patterns.md.
- list-patterns.md: the first design note. The five rules above
  supersede its proposal where they differ.
- code/gen.ml and code/phrt.h: the generator and the runtime compare.
  verify/fuzz/gen_fixed.ml has the emitter fixes.

# Strings: synthesis and gavels

Inputs: `prior-art.md`, `track-a/programs.md` (16 paper tasks plus a
bonus), `judge-ergonomics.md`, `judge-ethos.md`, `track-b/RESULTS.md`
and `track-b/VERIFY.md`, all in this folder. Every number below is one
VERIFY re-measured, unless it's marked otherwise.

## 1. Verdict

A `Str` is valid UTF-8 bytes, and **bytes are the only unit it has.**
Positions, ranges, equality, hashing and order are all bytes. Anything
that reads a Unicode table (case, normalization, graphemes) lives in
the `unicode` module, so `Str` itself gives the same answer in every
build and every release. A position counts from the start of the value
you hold. A program that wants a stream or file position says where its
value starts, once, where it makes the cursor. You build a string with
interpolation, `+=` (in place when the string is unique) and `join`.
There's no builder type. Retention stays explicit: `copy()` plus the
debug report.

Underneath, the compiler should build representation B: a 16-byte
value `{root, u32 offset, u32 length}`. It beat today's layout on every
workload that wasn't a tie, and it allocates nothing per slice. Two
smaller changes should come with it: in-place `+=` and a SIMD UTF-8
validator. None of these can be seen by a program, and they stay
invisible only because positions are relative to the value.

## 2. Semantic gavels, A1 to A7

The two judges agree on direction for all seven. Where they split, I
say so and decide.

### A1. Positions: value-relative, with the base given once (option c)

**Recommendation.** A position is a byte offset into the value you
hold. Only the two things that make positions take a base: a cursor
(`b.cursor(from: n)`) and a format view (`T.fmt.view(b, from: n)`).
Library cursors that know their own base carry it as data, as
`Net.frames` and `Fs.line_reader` do. Plain functions take no base:
`Str.from_utf8(b) ! InvalidUtf8(at)` reports `at` within `b`. Add one
rule to formats.md: **`at` is for reports, never for indexing. To
reach bytes, use the cursor.**

```ren
var c = buf.cursor(from: base)   // errors' `at` are now stream offsets
...
Err(e) => fail e                 // no shifting by hand
```

**Evidence.**
- Task 1, framing over a socket: under A1b the offset silently counts
  from whichever root `buf` is today, which might be a leased chunk, a
  joined buffer or an interpreter copy. Under A1c the error passes
  through unchanged and is right.
- compiler.md already records that A1b can't be built: the
  interpreter's `Bytes` keep no root, so "the offset in the root isn't
  known in both builds".
- `ByteCursor.at()` is already value-relative (lib/core/prelude.ml:426),
  so only the docs change.
- Prior art: Lean 4's slice-relative `Pos` with an explicit lift,
  Kaitai's substreams, and nom_locate's carried base
  (prior-art.md §3). Erlang has the root offset and deliberately hides
  it.
- Track B: every copy policy, and any inline layout, moves a slice's
  bytes. Under A1b each one would change an error's `at`. Under A1c
  none of them is observable.
- Both judges pick A1c.

**The trap A1c brings (ergonomics judge).** With `from: 4096`,
`b[e.at..]` reads the wrong bytes. With `from: 0`, which is what every
unit test uses, it's right. So the bug is latent. The defence is
the "`at` is for reports" rule plus a cursor complete enough that
nobody needs to index the original. A value cursor already peeks by
copying (`var next = c`).

**Main alternative: A1a** (value-relative, no base). It's honest, but
every framing loop has to shift each error by hand, and forgetting the
shift is silent. A library `e.shifted(by: base)` shrinks that cost, but
the shift still happens where you catch the error, and it's optional.
A1c moves it to where you construct the cursor, and library cursors do
it for you.

**Where the judges split.**
- *Spelling.* The ethos judge notes that `cursor(from: n = 0)` needs
  labelled call arguments with defaults, and language.md has labels
  only on constructors. **Decide:** settle labelled call arguments
  first. stdlib.md already writes `retry(5, on: Declined)`, so that
  gavel is owed anyway. If strings ship before it, use a second name,
  `b.cursor_from(n)`.
- *`ByteCursor.sub(n)`.* The ergonomics judge wants it, the ethos judge
  cuts it. **Decide: cut it** for now. It's three lines, and it would
  be a second way to make a cursor with a base. Add it if nested-format
  programs keep repeating the pattern.

**Doc text that changes.**
- foundations.md decision 19, "Offsets are free in errors": becomes
  "offsets count from the start of the value given to `view`, or from
  the base it was given".
- formats.md, "Errors carry offsets": the same rewrite. Drop "Erlang
  can't do it", which is wrong on the facts. Add the "`at` is for
  reports" rule.
- compiler.md, "Where it differs from formats.md": no longer a
  difference. It becomes the rule.
- stdlib.md, "Bytes at an offset, and a cursor": add the based cursor.

### A2. `len` and indexing: bytes, with the unit in the name

**Recommendation.**
- `s[a..b]` is a byte range. It panics if it cuts a character (A4).
- `s[i]` is a compile error. Its help names `s.bytes().u8(i)`,
  `s[i..j]` and `s.chars()`.
- **`s.len()` is a compile error too.** Its help names
  `s.byte_len()`, `s.is_empty()`, `s.chars().count()` and
  `unicode.graphemes(s).count()`. `Bytes` and `Array` keep `len`.
- `s.chars()` is a cursor of code points.
- Drop the `for at, x in s.graphemes()` form.

**Evidence.**
- Tasks 3 and 16: byte indexing invites character arithmetic done in
  bytes, which cuts emoji or panics on real data.
- Tasks 4 and 15 show the same trap in `len`. A reader of
  `t.len() > 50` on a user-facing tag can't tell whether 50 bytes was
  meant. If it was characters, a Japanese user gets 16.
- Mojo 1.0 made `len(String)` unavailable because "a single length is
  ambiguous" (`modular/.../string.mojo:835-845`). Roc's `Str.len` now
  returns a tag that points you to `count_utf8_bytes`
  (`roc-zig/src/build/roc/Builtin.roc:2259-2263`). Track A cited an
  older Mojo release that has since been superseded.

**Where the judges split.** The ethos judge would keep `len` as bytes.
Ren has one position unit, `len` is the end of `s[0..len]`, and
operators.md says "no `length` or `size` beside `len`". **Decide:
`byte_len`.**
- The question isn't which unit Ren uses. It's whether a reader of
  `name.len() > 20` can tell the writer's intent. With `byte_len`, the
  unit is on the page.
- It's the same rule as `s[i]`: on `Str`, anything with an ambiguous
  unit is a compile error with help. That makes one rule, not two.
- It isn't a synonym beside `len`, because `Str` has no `len`.

This is the closest call in the set, and it costs a few characters per
call site. If you'd rather keep `len`, it's coherent too. Just don't
keep both.

**For-loop forms.** Both judges cut `for at, x in` over cursors.
README.md:151 and decision 16 make `for i, x` "the index and the
element", so a byte offset there would give the form two meanings. To
get offsets, sum `g.byte_len()` in a `var`.

**Main alternative: A2-named** (Mojo's `s[byte=a..b]`,
`s[grapheme=a..b]`). It's consistent, but it hides O(n) grapheme scans
behind `[]` and adds a subscript form Ren doesn't otherwise have.

**Doc text that changes.** stdlib.md, the text/bytes section: `len`
becomes `byte_len` with the compile-error help. Add a note to
operators.md that `Str` has no `len`, and why.

### A3. Equality: bytes; normalization is explicit, once, at the boundary

**Recommendation.** `==`, `hash` and `<` on `Str` compare bytes, which
operators.md already decided. Normalization is something you call, and
you call it once, in an opaque type's constructor:

```ren
pub type Username = opaque Str
  pub fn parse(s: Str) -> Username ! BadName =
    let id = unicode.nfkc_fold(s)
    if id.byte_len() > 64 then fail BadName   // check after folding
    id
```

Every function that reads a Unicode table moves to `unicode`:
`nfc`, `nfd`, `nfkd`, `nfkc_fold`, `lower`, `upper`, `graphemes` and
the classifiers. Cut `fold`, `nfkc` and `is_nfc`. No task needed them,
and `nfc()` already returns `s` itself when it's in NFC.

**Evidence.**
- Canonical `==` is ruled out, not just worse. `x.hash()` is unseeded
  and journaled (stdlib.md), and normalization is stable only for
  assigned code points (the Unicode stability policy). A stored hash
  would change when the tables are bumped.
- Canonical `==` also breaks decision 17's "a slice is a value": you
  could have `a == b` while `a.byte_len() != b.byte_len()`.
- Task 4: canonical equality doesn't solve usernames anyway, since
  identity needs folding (`ß`, fullwidth). Task 15: normalize once,
  then compare bytes forever.
- Swift, the one language that chose canonical equality, now keeps a
  byte comparison beside it (SE-0464).
- Both judges agree.

**The `unicode`-module rule** (ethos judge). It's what makes the journal
rule exact. Because dispatch is static over a closed world (decision
4), the compiler knows whether a program reaches `unicode` at all. Write
the Unicode version into the journal header only when it does, and
refuse a mismatched replay only then, naming the function reached. Track
A's version, recording it always, would break every `tests/*.journal`
once a year. **Decide: take the rule.** It's crisp, it's checkable, it
removes about a third of the proposed `Str` surface, and stdlib.md
already lists `unicode` as the home of normalization, graphemes and
case.

**Main alternative: A3-canon** (Swift). It costs every non-ASCII
comparison, makes hashes depend on the table version, and still doesn't
fold.

**Doc text that changes.**
- operators.md's `key` example (`Email`, `key = self.lower()`) is the
  trap task 15 names: it normalizes on every hash and `==`, it's
  ASCII-only, and it's the wrong function for identity. Move the
  example to the constructor pattern, and show `key` projecting a
  field instead.
- operators.md's "`Email` is equal by its lowercase" changes to match.
- stdlib.md's `unicode` row stays as it is.

### A4. A slice that cuts a character: panic, plus floor and ceil

**Recommendation.** Decision 17 stays as written: a `Str` slice that
cuts a character panics. Add `s.char_floor(i)` and `s.char_ceil(i)`,
and have the panic's help name whichever one fits the side that cut.
Cut `is_char_boundary`, since `s.char_floor(i) == i` says the same
thing. Grapheme cuts never panic, because a panic mustn't depend on a
table.

```ren
let head = line[0..line.char_floor(1024)]              // first ≤1024 bytes
let tail = m[m.char_ceil(m.byte_len() - 1024)..]       // last ≤1024 bytes
```

**Evidence.** Task 16 (a byte budget): a plain panic fails on real
data, and rounding silently makes `s[a..b].byte_len() != b - a`. Rust
1.91 stabilized `floor_char_boundary` and `ceil_char_boundary`
together, and Mojo 0.26.2 also panics on a cut code point. The
ergonomics judge added `char_ceil`, and the ethos judge cut
`is_char_boundary`. Neither choice contradicts the other.

**Main alternative: A4-round.** It's silent, and it breaks the length
arithmetic.

**Deferred:** a checked `s.get(a..b) -> Option<Str>`, for offsets that
come from input. Add it only together with the same form on `Array`
and `Bytes`. Offsets from input should normally go through a format or
a cursor.

**Doc text.** Decision 17's bullet gains one clause: "`char_floor` and
`char_ceil` give a boundary for a computed limit".

### A5. Building: interpolation, `+=` in place, `join`; holes are `\{x}`

**Recommendation.**
- Interpolation goes through `show`.
- `+` and `+=` work on `Str`, and `+=` appends in place when the string
  is unique.
- `xs.join(sep)` joins an array.
- There's no builder type and no iolist type, and `concat` goes.
- `pad_*` and format specs go to `fmt`.
- **Holes are written `\{x}`.**

**Evidence.**
- B3: in-place `+=` matched a dedicated builder (json 157.5 against
  158.8 ms, logs 93.5 against 92.2). Today's `s = s + x` was 678×
  slower at 5,000 records, and quadratic.
- A builder would be an object with identity in a value language. Go
  needed a runtime `copyCheck` to guard its builder.
- Lean, Roc, Erlang and Swift all append in place when unique
  (prior-art.md, "Building").

**Where the judges split: the hole syntax.** The ethos judge wants
`{x}`, because stdlib.md already writes `"jobs/{job}"`. The ergonomics
judge wants `\{x}`, because `{x}` captures silently: `"\\d{3}"` (a
regex) becomes `\d3`, and a `"{name}"` log template for another system
interpolates Ren's `name` if one is in scope. **Decide: `\{x}`.**
- The failure is silent, and the owner's yardstick puts silent bugs
  above one keystroke.
- `\` is already the escape character, so plain JSON, CSS, regexes and
  other systems' templates paste in unchanged.
- Java's JEP 430 chose `\{` for this reason, and Swift uses `\(x)`.
- The ethos judge's argument ("only hand-built JSON hurts, and the
  design says not to do that") misses the regex and foreign-template
  cases.
- Changing stdlib.md's two examples costs two characters.

**Tagged templates (`sql"..."`).** Both judges say they're stdlib.md's
open question (stage 12), not strings.md's. Agreed: strings.md cites it
and doesn't decide it.

**`join`.** A method on `Array<Str>` needs a prelude form for a method
on one instantiation of a generic type. Take `xs.join(sep)` and put the
cost in the compiler. Fall back to `Str.join(xs, sep)` only if that
form is unwelcome elsewhere.

**Keep** the debug report for "`+=` copied a shared `Str` inside a
loop". It's the one way in-place append can silently become quadratic
again.

**Doc text.**
- stdlib.md's interpolation examples become `"jobs/\{job}"` and
  `sql"... \{plan}"`.
- operators.md: `concat` goes, and interpolation's hole syntax is
  stated.

### A6. The Str/Bytes boundary: strict, with an offset

**Recommendation.**
- `Str.from_utf8(b) -> Str ! InvalidUtf8(at: Int, incomplete: Bool)`,
  where `at` is relative to `b`, and `incomplete` means the input ended
  in the middle of a character.
- A named `Str.from_utf8_lossy(b)` that replaces each maximal invalid
  subpart with U+FFFD. That rule comes from UTF-8's structure, not a
  table, so it stays on `Str`.
- Neither function strips a BOM.
- OS data that may not be UTF-8 is `Bytes`-backed: `Path = opaque
  Bytes`, whose `show` escapes `\` as `\\` so its `\xNN` escapes aren't
  ambiguous.
- `Os.args() ! ArgNotUtf8(index)`, `Os.env(name) !
  EnvNotUtf8(name)`, plus `raw_args` and `raw_env`.
- No `OsStr` and no surrogateescape.

**Evidence.**
- Task 9: read `Bytes` once, then convert. Reading the file twice is a
  race.
- Task 17: names that aren't UTF-8 must round-trip.
- Rust's `Utf8Error` has both `valid_up_to` and `error_len`. Swift's
  validating initializer gives no offset (SE-0405).
- B5 makes "checked once, at the boundary" cheap, but only with a SIMD
  validator.

**Fixes the judges found, both taken.**
- The ethos judge: Track A gave `NotUtf8` two shapes (`index` and
  `name`), which errors.md forbids in one error set. So the tags become
  `ArgNotUtf8` and `EnvNotUtf8`.
- The ergonomics judge: add `incomplete`. A decoder that works chunk by
  chunk must tell "invalid" from "not finished yet".
- Do both now, because `InvalidUtf8` is payload-free today
  (prelude.ml:699). Every std use (`from_utf8`, `Fs.read_str`, the line
  reader, `Path.to_str`) must move to the new shape in one commit,
  and doing it twice would be worse.
- Views report bad UTF-8 in a `Str` field as `Malformed(at, path,
  "not UTF-8")`, so one view has one error set.

**Main alternative: A6-lossy by default.** It loses data silently, and
the loss should be something you choose.

**Doc text.**
- stdlib.md text/bytes gets the new `from_utf8` signature and the
  `Os` tags.
- strings.md states the principle that OS data is `Bytes`-backed, and
  leaves the `Path` API to the `path` module.
- prelude: `Path = opaque Str` becomes `opaque Bytes`. That's a change
  set touching `Path.join`, `Fs` and `cli`, not one line.

### A7. Retention: explicit; the compiler may copy, invisibly, but promises nothing

**Recommendation.** Decision 17 stays as written: slices share their
root, `copy()` is explicit and free on an owner, and debug builds report
roots that small slices keep alive. Where a leased slice is kept past
its turn, follow the streams direction: a compile error with a
`.copy()` fix-it where the keep is visible, and a debug report
otherwise. **Reject A7-store as a promise.** The compiler *may* still
copy a slice when it can prove the root dies before the collection
does, or keep short values inline. Both are representation choices
that A1c keeps invisible. No user may count on either.

**Evidence. Track B changed this question.**
- **Size thresholds don't bound memory.** Keeping 10k keys (230 KB) out
  of 512 MiB held **522 MiB** with plain sharing, and still 522 MiB when
  every slice under 16 or under 64 bytes was copied. One longer kept
  slice per buffer pins it.
- So "inline small strings" (A7-tiny) is **not** a retention policy.
  Prior-art.md's "Ren's defence has to be automatic small-slice copying"
  is refuted for this shape.
- **Copy-on-store bounded it at 18.4 MiB**, and ran 17% fewer cycles
  (529 against 635 Mcyc; wall time −4%, within noise).
- **Blind copy-on-store cost 1.65× on the tokenizer** (32.90 against
  19.94 ms), where the root stays alive anyway.
- So no automatic policy is free. "Copy on store, when the root
  provably dies first" is the only good one, and it's a compiler
  analysis that hasn't been built or measured.

**Where the judges split.** The ergonomics judge takes all three
(manual, tiny and store) and wants store to compact `Map` values too.
The ethos judge rejects store as "a copy found behind your back", with
two rules for one trap and a tuning knob users would come to rely on.
**Decide: the ethos judge, sharpened by B2.**
- The tiny layout doesn't solve retention, so it's only a performance
  choice.
- A store rule scoped to `Map`/`Set` keys leaves arrays and record
  fields pinning, so it isn't predictable.
- The streams amendments' decision 12 recommends the explicit
  version. It's still a recommendation, but strings should match it.

**What a user is told:** "If you keep many slices of a big input in
something long-lived, write `.copy()`. The debug report tells you when."

**Pool starvation** (ergonomics judge). A kept line that pins a
*leased* chunk can stall reads, not just use memory. That belongs to the
streams gavel (runtime-io.md). Strings inherit whatever it decides.

**Doc text.** None changes in decision 17. strings.md states the rule
above, and that the compiler may copy invisibly because of A1c.

### Two smaller gavels the judges surfaced

- **`Char`: (P1) no `Char` type.** A character literal like `'a'` is an
  `Int` literal, its code point, and it's checked where it's stored
  (decision 15). So `b.u8(i) == '"'` and formats.md's `'Q'` tag work
  unchanged. Storing a non-ASCII character literal into a `UInt8` is a
  build error. `s.chars()` yields `Int`, classification is
  `unicode.is_alphabetic(c)`, and `Str + Char` goes (write `s +=
  Str.of_code(c)`).
  - This matches operators.md's "a literal's type is read from its
    spelling". The ergonomics judge's alternative, where a literal
    takes its type from context, contradicts that decided text.
  - The cost: no type tells a code point from an `Int`. A `Char =
    opaque Int` added later would change `chars()`'s element type, so
    choose now.
- **`trim`, `fields` and `lines` mean ASCII whitespace on both `Str`
  and `Bytes`.** Track A gave `Str` Unicode White_Space and `Bytes`
  ASCII, with the same names. That's the HTTP-smuggling trap from task
  12, where the meaning silently switches when code moves between the
  types. Today's `trim` is already ASCII, so nothing breaks. Display
  trimming of NBSP or U+3000 is `unicode`'s job. For the same reason,
  today's `s.lower()` (ASCII) is renamed `s.ascii_lower()`. A silent
  change to Unicode would alter existing callers.

## 3. Representation findings, B1 to B5

Measured on a C model of Ren's runtime (copied from ren_rt at cf7787c),
with Rust and Go twins. Medians of 11 runs. These are the VERIFY
numbers.

### B1. Layout: build representation B

| workload | A (today) | **B** (16 B, `{root, u32 off, u32 len}`) | B24 (Roc, 24 B) | SSO (≤15 B inline) | German |
|---|---|---|---|---|---|
| tok | 27.08 | **20.19** (0.75×) | 22.21 | 21.13 (1.05× B) | 24.83 |
| map | 312.3 | **283.3** (0.91×) | 291.1 | 301.3 (1.06×; 1.02× with a fairer compare) | 319.6 |
| sort | 344.3 | **262.0** (0.76×) | 263.5 | 288.1 (1.10×) | 290.2 |
| group | 211.1 | 208.6 (tie) | 208.5 | 217.5 | 220.0 |
| logs, corrected | 138.2 | **116.0** (0.84×) | 127.1 | **109.5** (0.94× B) | n/a |

- **Layout: B.** It wins everywhere except group, where it ties. It
  allocates nothing per slice; A allocates a 32-byte object for every
  slice it keeps. Prefer it over Roc's 24 bytes, since B24 is never
  faster once the codegen fault is removed.
- **Not now: SSO or German strings.**
  - German strings lose everywhere (1.05–1.23× B). A counted root
    can't be found from an interior pointer, so every long slice needs
    an indirection. They suit column stores with uncounted arenas, not
    counted values.
  - SSO loses 2–10% on tok, map and sort, but **wins 6% on
    record-heavy logs**, where 57% of fields are short and the drop
    pass skips their counts. It stays open as a later change that
    programs can't see, and only because of A1c.
- **Caveat on logs.** The as-built logs row was ruined by a clang
  loop-strength-reduction fault, which hit every layout (as built, B
  151.9 and A 151.0, a tie). Ren emits its own C, so whether Ren's
  output trips the same fault is unknown. If it does, logs is a tie,
  not a 16% win.

### B2. Retention

Numbers are under A7 above. In short:
- Always sharing is right for parsers.
- Thresholds are useless for bounding memory.
- Copy-on-store is right only when the root dies before the collection
  does.
- The compiler should keep explicit `copy()` and the debug report, and
  may later add the proved copy-on-store as an invisible optimization.

### B3. Building output

| ms | `+=` in place | builder | iolist (as built) | iolist, streaming |
|---|---|---|---|---|
| json, 1M | 157.5 | 158.8 | 426.7 | 337.9 (2.15×) |
| logs, 1M | 93.5 | 92.2 | 341.8 | 235.2 (2.5×) |

- `s += x` in place on a unique owner is the strategy. Give B's owner
  header a capacity field and grow it by doubling.
- An iolist loses 2.2–2.5× even when it streams (about 16 ns a piece).
  Keep `Net.write(parts)` taking several values for large existing
  pieces, but don't make it the default output path.
- Ignore memory differences between `+=` and builder: the realloc RSS
  was bimodal noise.

### B4. Keys

| `Map<Str, Int>`, 4M ops | ms |
|---|---|
| Ren model, B, wyhash with the hash kept per entry | 279.6 |
| Rust `&str` keys, FxHash / aHash / std SipHash | 273.2 / 283.9 / 397.4 |
| Rust `String` keys, FxHash / std | 265.3 / 369.3 |

- **Keep wyhash with the stored hash.** It runs at 1.02–1.05× Rust's
  fast hashers.
- The bytes stage compared against std's SipHash, which flattered Ren
  by about 1.3–1.4×.
- Don't hash a prefix, and don't change a key's layout to serve
  equality. Prefix-only hashing ran 7.6× slower, because URLs share
  their first 8 bytes. Prefix-first compare changed nothing beside the
  stored hash. VERIFY didn't re-run these two, and judged both effects
  too large or too null for noise to flip.

### B5. Validation

| | ASCII | CJK | mixed |
|---|---|---|---|
| today's `ren_utf8_valid`, GB/s at 1 MiB | 2.60 | 1.09 | 1.70 |
| NEON Keiser–Lemire | 73.1 | 9.01 | 13.5 |
| Rust `simdutf8` | 72.6 | 9.00 | 13.4 |

Validation's share of a whole read, parse and respond program:

| file | today | NEON |
|---|---|---|
| logs, 94 MB ASCII | 16% | 2.2% |
| CSV, 59 MB | 13% | 1.2% |
| CJK, 64 MiB | 41% | 7.9% |

- Ship a block validator (Keiser–Lemire). It's under 100 lines, with
  three 16-byte lookup tables, and it's exact, so the interpreter and
  native builds can't disagree.
- Find the error offset by re-scanning the failing block one byte at a
  time.
- It agreed with the scalar validator on 2M random inputs, plus 69k
  long and boundary cases.
- With it, there's no speed argument left for an unchecked `Str`
  constructor.

### What the next bytes stage builds first

1. **Representation B, with in-place `+=` in the same step.** B's owner
   header carries the capacity that `+=` needs. Expected effect:
   - tokenizers and sorts that keep slices: about 0.75× time;
   - maps: about 0.9×;
   - record-heavy parsing: 0.84× if Ren's C dodges the clang fault,
     and a tie if not;
   - output built with `+=`: from quadratic to builder speed.

   Also add the debug report for `+=` on a shared string.
2. **The SIMD validator** (NEON now; SSE4 or AVX2 when x86 matters).
   It's independent and small, so it can go first as a warm-up.
   Expected effect: validation falls from 13–41% of a read, parse and
   respond program to 1–8%.
3. **Re-measure compiler.md's `Map` claim** against Rust with FxHash or
   aHash, not SipHash.

### Still unknown

- **Hot roots.** Whether contended atomic counts on one hot root (many
  tasks keeping slices of one buffer) make SSO worth having. That's
  decision 10's hot-root trap, and it wasn't measured.
- **The 4 GiB escape.** What it costs in code that never sees one
  (a flag plus an out-of-line offset). It wasn't built.
- **Ren's own C.** Whether Ren's emitted C hits the clang fault that
  ruined the logs row.
- **Real writes.** Gather writes on a socket, which copies what it's
  given, unlike `/dev/null`. Also the http-response reuse gap (builder
  46.7 against `+=` 55.0 ms, from RESULTS only, never re-measured),
  which would argue for a capacity-keeping `clear()`.
- **Proved copy-on-store.** Whether it's worth building as a compiler
  analysis. Only the policy's effect was measured, not the analysis.
- **Absolute numbers.** The harness writes Perceus's dups and drops by
  hand and has no bounds checks, so absolute numbers flatter Ren.
  Compare within a table.

## 4. The Str API after cuts

| Group | On `Str` | Notes |
|---|---|---|
| Size and position | `s.byte_len()`, `s.is_empty()`, `s[a..b]`, `s.char_floor(i)`, `s.char_ceil(i)`, `s.line_col(at)` | `s.len()` and `s[i]` are compile errors with help. Columns count code points |
| Views | `s.bytes()` (free), `s.chars()` (cursor of `Int` code points) | graphemes are `unicode.graphemes(s)` |
| Search | `index`, `includes`, `starts_with`, `ends_with`, `strip_prefix`, `strip_suffix` | results are found slices, never checked |
| Split and trim | `split`, `split_once`, `lines`, `fields`, `trim` | whitespace means ASCII, as on `Bytes` |
| Transform | `replace`, `ascii_lower`, `ascii_upper` | today's `lower` is renamed |
| Build | `"…\{x}…"`, `a + b`, `s += t`, `xs.join(sep)`, `Str.of_code(c)` | `+=` in place when unique |
| Boundary | `Str.from_utf8(b) ! InvalidUtf8(at, incomplete)`, `Str.from_utf8_lossy(b)`, `s.copy()` | `at` counts from the start of `b` |
| `unicode` module | `nfc`, `nfd`, `nfkd`, `nfkc_fold`, `lower`, `upper`, `graphemes`, `is_alphabetic`, `is_numeric`, `is_whitespace`, `is_mark` | pinned tables; a program that reaches these gets the Unicode version in its journal |
| `Bytes` | the same search, split and trim names, with ASCII meaning; `ascii_lower`; `b.cursor()`, `b.cursor(from: n)` | `ByteCursor` loses nothing and gains no `sub` |
| OS | `Path = opaque Bytes`, `Os.args() ! ArgNotUtf8(index)`, `Os.env(n) ! EnvNotUtf8(name)`, `raw_args`, `raw_env` | |

**Cut:** `len` on `Str`, `concat`, `fold`, `nfkc`, `is_nfc`,
`is_char_boundary`, `trim_start`, `trim_end`, `last_index`, `repeat`,
`pad_start`, `pad_end` (to `fmt`), the `Char` type and its roughly ten
methods, `for at, x in` over cursors, `ByteCursor.sub`, and `json"…"`
and `html"…"` (stdlib.md's tagged-template question). That leaves about
25 names on `Str` and 11 in `unicode`, down from about 45.

**Still open, small:** how a `Bytes` literal is spelled for needles
(`b.index(b"\r\n")`). A `b"…"` prefix fits "a literal's type is read
from its spelling" and the `sql"…"` prefix form. Decide it with the
tagged-template question.

## 5. Outline for strings.md

1. **What it has to do.** Text that's always valid, bytes as the one
   unit, the same answers in every build, and a layout nobody can see.
2. **Str and Bytes.** What each one is, when to use which, and why
   parsers work on `Bytes`.
3. **Positions.** Value-relative byte offsets, a base given once, and
   "`at` is for reports, never an index".
4. **Length and indexing.** `byte_len`, byte ranges, why `len` and
   `s[i]` are compile errors, and the `chars` cursor.
5. **Cutting a character.** The panic, `char_floor` and `char_ceil`,
   and why found slices never check.
6. **Equality, hashing and order.** Bytes, and why they aren't
   canonical.
7. **The `unicode` module.** What reads a table, the pinned version,
   the journal rule, and identity keys made in constructors.
8. **Building strings.** `\{x}` interpolation through `show`, `+=` in
   place, `join`, and the debug report for shared `+=`.
9. **The boundary.** `from_utf8` with `at` and `incomplete`, lossy by
   name, BOM left alone, `Path` and `Os` over `Bytes`.
10. **Character literals.** `'a'` is an `Int`, checked where it's
    stored.
11. **Retention.** Sharing, `copy()`, the debug report, leased slices,
    and what the compiler may do without telling you.
12. **Representation (the compiler's, not the program's).** B, in-place
    append, the SIMD validator, and what stays open (SSO, hot roots, 4
    GiB).
13. **Left out.** Builders, iolists, ropes, canonical equality,
    `OsStr`, format mini-languages and collation.
14. **Evidence.** Links to the prior art, the tasks and the Track B
    tables.

## 6. Open risks, and conflicts with decided text

**Conflicts with decided or written text**, each needing an edit:

| Where | What it says now | Change |
|---|---|---|
| foundations.md decision 19; formats.md "Errors carry offsets" | offsets in the whole buffer, "free", "Erlang can't do it" | value-relative plus a base (A1) |
| compiler.md, "Where it differs from formats.md" | views keep the root-relative promise | the difference becomes the rule |
| operators.md, "no `length` or `size` beside `len`" | `len` everywhere | `Str` has `byte_len` and no `len` (A2). This bends the spirit of the rule. Say why there |
| operators.md, `key` example | `Email` keyed by `self.lower()` | constructor normalization (A3) |
| today's `s.lower()` | ASCII, named `lower` | renamed `ascii_lower`, a breaking rename |
| stdlib.md examples | `"jobs/{job}"`, `sql"... {plan}"` | `\{x}` (A5) |
| prelude, `InvalidUtf8` | no payload | `(at, incomplete)`, every use changed in one commit |
| prelude, `Path` | `opaque Str` | `opaque Bytes`, a change set |
| streams.md (draft) | `chunk.split_lines()` | `lines` |
| compiler.md, Bytes stage | `Map` "0.69× of Rust's cycles" | measured against SipHash. Against FxHash it's about 1.02–1.05×, so re-state it |
| prior-art.md §4 | "the defence has to be automatic small-slice copying" | B2 refutes it for many kept keys. Don't carry it into strings.md |
| language.md | labels on constructors only | `cursor(from:)` needs labelled call arguments, which is a separate gavel |

**Risks.**
- **`byte_len` against `len`** is the decision most likely to be
  argued again. Both forms are coherent, and keeping both isn't.
- **The A1c trap is latent.** Code that indexes with `at` passes every
  test that uses base 0. Nothing in the type system catches it today.
  An `Offset` type that can't index would, but it adds a type. Revisit
  only if the trap shows up in real code.
- **P1 (no `Char`) can't be undone cheaply.** Adding a `Char` later
  changes `chars()`'s element type.
- **SSO might be the right layout after all** for record-heavy
  programs, or under contended counts. Measure again once representation
  B is real and the clang fault is understood.
- **Leased-chunk starvation** is unsolved here. It depends on the
  streams gavel (decision 12) and runtime-io.md.
- **Track A's programs have bugs** worth fixing before strings.md quotes
  them:
  - task 1 silently drops a truncated frame at EOF;
  - task 2 loses a last row with no final newline;
  - task 9 reads the file twice;
  - task 12 has a `try … orelse` that doesn't mean what it looks like.
- **Streams is undecided.** A1's library cursors (`Net.frames`,
  `Fs.line_reader`) and A7's leased-slice rule assume the amended
  direction. They don't depend on its details, but they should be
  gavelled first or together.

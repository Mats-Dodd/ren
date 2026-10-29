# Strings, track A: the ergonomics and correctness judge

I judged `track-a/programs.md` against `prior-art.md`, the Ren docs it
cites, and the primary sources where the two files disagree. For each
question I name a winner on **ergonomics** (it reads well, it's easy to
write, there's one obvious way) and on **correctness** (fewest silent
bugs; traps caught at compile time or by a clear panic). I also list
where Track A's code is wrong or unfair, and where Ren still trails the
best prior art and what would close the gap.

## Verdicts at a glance

| Q | Track A says | Ergonomics winner | Correctness winner | My verdict |
|---|---|---|---|---|
| A1 positions | A1c | A1c | A1c, with one trap Track A missed | **A1c**, and `at` is for reporting, never for indexing (see A1) |
| A2 len/index | A2-views, `len` is bytes | A2-views | A2-views **without a bare `len`** | **A2-views, plus `s.len()` becomes a compile error with help, like `s[i]`**. Track A's reason for keeping `len` is a misread of Mojo |
| A3 equality | bytes + explicit nfc | bytes + nfc | bytes + nfc | **Agree.** Check the length after folding, not before |
| A4 cut char | panic + `char_floor` | panic + floor | panic + floor | **Agree, and add `char_ceil`** (Rust stabilized both together) |
| A5 building | interp + `+=` + join, no builder | same | same, with `\{x}` holes | **Agree, but the hole syntax should be `\{x}`, not `{x}`.** `{x}` turns `"\d{3}"` into `\d3` silently |
| A6 boundary | strict + `at`, lossy by name, `Path` over Bytes | same | same, plus an "incomplete" flag | **Agree, and `InvalidUtf8` should say whether the input ended mid-character** |
| A7 retention | manual + tiny + store | store + tiny | same | **Agree, and compact `Map` values too, not only keys** |

Track A's direction holds on every question. The changes below are
corrections, not reversals, except for A2's `len`, which I'd reverse.

---

## Code in Track A that's wrong or unidiomatic

None of these change a verdict. Several are exactly the silent bugs the
question is about, which makes them worth fixing before the synthesis
quotes the programs.

1. **Task 1, every version: a truncated frame at EOF is silently
   dropped.** When `got.len() == 0`, the loop ends with `c.rest()`
   possibly non-empty. A peer that closes mid-frame looks like a clean
   close. The fix goes after the read:
   ```ren
   let got = try Net.read(conn, 65_536)
   if got.len() == 0 then
     if c.left() > 0 then fail Short(c.at(), 0)   // ended inside a frame
     open = false
   buf = c.rest() + got
   ```
   `Net.frames` should own this case too, and the amendments should say
   so.
2. **Task 2: the last row is lost if the file has no final newline.**
   Rows are pushed only on `'\n'`. An empty last field (`a,b,`) is lost
   too, and `\r\n` leaves `\r` in the last field. The CSV parser needs
   `if row.len() > 0 then &rows.push(row)` after the loop, plus a `\r`
   strip. This is the sort of thing the csv crate gets right and a paper
   version should not pretend to.
3. **Indexed `for` over an array uses `.with_index()`.** Tasks 2 and 7
   write `for n, l in text.lines().with_index()` and `for i, it in
   r.items.with_index()`. README.md:151 makes `for i, x in xs` the form
   for arrays. Write `for n, l in text.lines()`.
4. **Indexed `for` over a cursor isn't Ren.** Task 3 and the API table
   (`for at, x in s.graphemes()`, "`for at, x in` gives byte offsets")
   contradict README.md:151: "a cursor has none: count in a `var`." Keep
   the rule, and write task 3 the Ren way:
   ```ren
   fn short_name(s: Str) -> Str =
     var n = 0
     var at = 0
     for g in s.graphemes()
       if n == 20 then return s[0..at] + "…"
       n += 1
       at += g.len()
     s
   ```
   It's still short, and it's correct because grapheme slices are
   contiguous. Drop "`for at, x in` gives byte offsets" from the API.
   The pipeline form (`take(20).map(len).sum()`) is the nicer one
   anyway.
5. **Task 15: `tags.get(t).unwrap_or(0)`.** Ren writes `tags.get(t)
   orelse 0` (language.md:279, operators.md:514).
6. **Task 12: `try Str.from_utf8(...) orelse fail BadHeader(at)`**
   combines two failure handlers. Under language.md:784-828, `orelse`
   applies to the chain, so the `try` is either redundant or makes
   `orelse` dead. Write `Str.from_utf8(line[0..colon]) orelse fail
   BadHeader(at)`.
7. **Byte search takes a `Char` (`line.index(':')`, `b.u8(i) == '"'`),
   but the API table says `b.index(x: Bytes)`.** Task 9 also invents
   `strip_prefix_bytes`, which the receiver rule says is `strip_prefix`.
   One rule fixes all three, and I'd make it a gavel: **a literal takes
   its type from where it's used**. `"…"` where `Bytes` is expected is a
   `Bytes` literal, and `'a'` where a `UInt8` is expected is that byte
   (an error if the character isn't ASCII). This is Roc's
   `from_quote`/`Str.from_interpolation` and Swift's
   `ExpressibleByStringLiteral`. It also settles Track A's open
   interaction 1 (char literals) and formats.md's `'Q'` tags with no new
   names. `line.index(":")`, `b.strip_prefix("\u{FEFF}")` and `b.u8(i) ==
   '"'` all then read naturally.
8. **Task 9 reads the file twice** (`Fs.read_str`, then `Fs.read` on
   failure). That's a race, and it's double the I/O. Read `Bytes` once
   and call `Str.from_utf8(b)`. It also uses `from_utf8_lossy` on a
   prefix known to be valid, only to dodge a `try`. With the
   literal-typing rule this isn't needed, and `Bytes` could get
   `b.line_col(at)` (lines by `\n`, column in characters of the valid
   prefix). Then the whole error path is one line.
9. **Task 6's debug report numbers disagree:** "1,048 chunks of 64 KB"
   is 67 MB, not 640 MB. Choose one. The report is the user-facing
   artifact, so its arithmetic is what gets quoted.
10. **Task 12, `name.ascii_lower()` after checking `is_tchar`.** Once the
    name is known to be ASCII, Unicode `lower()` gives the same answer,
    so this task doesn't need `Str.ascii_lower` at all (see A2/A3 below).

---

## A1: positions

**Ergonomics: A1c. Correctness: A1c, with a trap to design out.**

Evidence that holds:
- **Task 1 (framing):** under A1c the base is said once, where the
  buffer is made, and errors pass through as `Err(e) => fail e`. A1b
  is wrong for exactly this program. Fact 2 in Track A, that a leased
  chunk is a root, is decisive.
- **Task 14 (nested views):** `view(slice, from: base + s.off)` says the
  base at the one place the program cut a slice.
- **Fact 1:** `ByteCursor.at()` is already value-relative
  (lib/core/prelude.ml:426, "where it is, in the bytes it was made
  from"), while formats.md:349 promises root-relative offsets. So only
  formats.md changes.

**Where Track A is unfair:**
- **To A1a, in tasks 1 and 14.** The "match every variant, three arms per
  nesting point" cost goes away with one library function,
  `FormatError.shifted(by: Int)`, which the stdlib would write once:
  `Err(e) => fail e.shifted(base)`. A1a's real cost is that the shift
  happens **where you catch**, and it's optional, so forgetting it is
  silent. A1c moves the base to **where you construct**, and the
  library cursors (`Net.frames`, `Fs.line_reader`) do it for you.
  That's the honest argument, and A1c still wins it.
- **In tasks 12 and 13 A1c isn't "best", it's a tie.** Task 12's
  `header(line, at)` takes `at` by hand under every option, so A1c only
  helps if the function takes the cursor. In task 13, a file reader's
  offset is **the reader's own data**, its `pread` position, under any
  option. It isn't a position in a value. Under A1a the reader can
  report `InvalidUtf8(at: file offset)` just as well. Both rows should
  read "tie (A1b wrong)".
- **To Swift, in task 14.** Swift's `Substring` indices are relative to
  the **parent value**, which is visible in the type. They don't change
  when storage is copied or reallocated. That's not the A1b
  representation leak. Swift's real A1b-style leak was `encodedOffset`
  (SE-0241), which Track A also cites, and that's the right citation.

**The trap Track A missed.** Under A1c, a position from a cursor made
`from: base` **is not an index into the value you hold**. Take
`b[c.at()..]` or `b.u8(e.at)`: with `from: 0` (every unit test) it's
right. With `from: 4096` (production) it reads the wrong bytes, or
panics only if it falls out of range. It's a latent, silent bug, and
A1a can't have it.

nom_locate shows the way out: `location_offset()` is absolute, and the
data is reached only through `fragment()`, never by indexing the
original with the offset. Lean does the same with slice-relative `Pos`
plus an explicit lift (prior-art.md §1, Lean 4). For Ren:
- State the rule in formats.md: **"`at` is for reports. To reach bytes,
  use the cursor."**
- Make the cursor complete enough that indexing the original is never
  needed: `c.rest()`, `c.bytes(n)`, `c.sub(n)` (Track A's), and a
  `c.peek(n)`.
- Rename nothing. When `from:` is 0 the two meanings coincide, so a
  debug build can't catch the confusion, which is why the cursor API
  has to make it unnecessary.

**Ren against the best prior art:** nom_locate also carries line and
column. Ren shouldn't: serde_json's way (byte offset in the error, line
and column computed when shown, from the value held) is already Track
A's `line_col`. With the rule above, Ren matches Kaitai and Lean and
beats tokio's `self.consumed` by hand.

---

## A2: what `len` and indexing mean

**Ergonomics: A2-views. Correctness: A2-views without a bare `len`.**

Track A's analysis of `s[i]` is right: it's a compile error with help,
and parsers that want bytes go through `s.bytes()` or parse `Bytes`.
But **it keeps `s.len()` as bytes on a factual error**. Task 11 says "Go,
Rust and Mojo 1.0 all made `len` bytes and survived", quoting Mojo
v0.25.1. That was superseded:
- **Mojo 1.0 makes `len(String)` unavailable:** "a single length is
  ambiguous: it could mean the number of UTF-8 bytes, the number of
  Unicode code points, or the number of user-visible characters. Use
  `s.byte_length()`…"
  (`/tmp/ren-refs/modular/Mojo/stdlib/std/collections/string/string.mojo:835-845`;
  deprecated in `docs/site/releases/v1.0.0b1.md:547`).
- **Roc's current `Str.len`** returns a guidance tag pointing at
  `count_utf8_bytes` and `is_empty`
  (`/tmp/ren-refs/roc-zig/src/build/roc/Builtin.roc:2259-2263`).

prior-art.md has this right ("no bare `len` on `Str`"), and Track A
didn't reconcile with it.

**Track A's own programs show the trap.** Task 4 checks `t.len() > 64`
on a username, and task 15 checks `t.len() > 50` on a tag. Is a 50-limit
on a user-facing tag meant in bytes? Then a Japanese user gets 16
characters. In characters? Then the code is wrong. Nobody reading
either line can tell, and that's the A2-bytes trap from task 3 again,
moved from `[]` to `len`.

**The rule:** `s.len()` is a compile error whose help names:
- `s.byte_len()` (O(1)), what a buffer or DB column limit means;
- `s.is_empty()`;
- `s.chars().count()`;
- `s.graphemes().count()`.

It's the same treatment as `s[i]`, for the same reason, so it's one
rule, not two. `Bytes.len()` and `Array.len()` keep `len`, where the unit
isn't ambiguous.

**Where else Track A is unfair:**
- **To A2-bytes in tasks 5 and 11.** Go has `s[i]` as a byte **and** a
  rune view (`for _, r := range s`), so a Go slug keeps "crème". The
  only real difference between A2-bytes and A2-views is whether `s[i]`
  is sugar for `s.bytes().u8(i)`. The A2-bytes slug that "drops
  letters" is a straw man. The fair case against A2-bytes is tasks 3
  and 16, where `s[i]` and `len` invite character arithmetic in bytes.
  That case is enough.
- **To A2-named (Mojo):** Mojo forbids unlabelled `s[a:b]` too
  (`string.mojo:809-830`). Ren keeps `s[a..b]` unlabelled, as bytes.
  That's fine, because a wrong byte range panics loudly on a cut
  character (A4). But that loud panic is the reason it's fine, and it
  should be said.

**Smaller fixes:**
- **`pad_start(width)` "in chars"** pads `e` + U+0301 wrong. Either count
  graphemes, or leave padding to the terminal library with
  `display_width`. I'd leave it out of `Str`.
- **Receiver rule, case.** Track A rejects `fields_ascii` because "the
  type picks", then keeps `Str.ascii_lower` beside `Bytes.ascii_lower`.
  Apply the rule all the way: `Bytes` gets `lower()`/`upper()` with
  ASCII meaning, and `Str` gets Unicode `lower()`/`upper()` and no
  `ascii_*` twins. Task 12 shows the Str twin isn't needed: validate
  the token, then `lower()` is exact, and an implementation's ASCII
  fast path makes it as cheap.

**Ren against the best prior art:**
- **Swift** wins task 3 on brevity: `s.prefix(20)` is graphemes, one
  line. Ren's `s.graphemes().take(20)` is close, and honest about O(n).
  Closing the rest of the gap needs no new concept: a sink that gives
  back the covered prefix, `s.graphemes().take(20).span()`, or simply
  `s.grapheme_prefix(20) -> Str`. I'd add the second only if the paper
  programs keep wanting it.
- **Mojo** ships the UAX #29 conformance tests. Ren should ship them
  too, under the pinned table (prior-art.md §2).

---

## A3: equality and normalization

**Ergonomics and correctness: A3-bytes + explicit normalization, in an
opaque type's constructor.** I agree with Track A.

Task 15's five points against canonical `==` are the strongest part of
the document. Points 1 (equal values with different slices) and 3
(replay under a new Unicode version) are decisive for Ren in particular.

**Corrections:**
- **Task 15 overstates the `key` form's cost.** "allocates per lookup"
  is false under Track A's own API, where `nfc()` returns `s` itself
  when it's already NFC. The cost is an `is_nfc` scan per hash and per
  `==`, which is O(n) but doesn't allocate. The `parse` form still wins:
  it's paid once, and the stored key is the normal form. But say it
  accurately.
- **Task 4 checks the length before folding.** NFKC_Casefold expands
  (`ß` to `ss`, ligatures, and U+FDFA to 18 code points). An `id` that
  passed `t.len() > 64` can exceed a 64-byte column. Check the limit on
  `id`, and in the unit you mean (A2).
- **"`nfkc_fold` is correct for identity" needs PRECIS's other half.**
  RFC 8265's IdentifierClass **disallows** compatibility characters like
  `Ⅸ` rather than mapping them. UAX #31 §5 recommends NFKC_Casefold for
  caseless identifier matching. Both are defensible. Ren's std should
  provide the fold and leave the policy (map or reject) to the
  `Username` type. Track A's "reject unassigned in the parse" is right
  and should stay.

**Ren against the best prior art:** Erlang's `string:equal(A, B, true,
nfc)` does the comparison in one call. Ren's is `a.nfkc_fold() ==
b.nfkc_fold()`, which is fine and explicit. No gap worth closing. The
operators.md `Email` example (`key` = `self.lower()`) should move to
the constructor pattern with `fold()`, since it's the example people
will copy.

---

## A4: slicing that cuts a character

**Ergonomics and correctness: A4-panic + floor.** I agree with Track A.

Task 16 makes the case. The alternatives are rejected for good reasons:
A4-round makes `s[a..b].len() != b - a` silently, and Go yields invalid
UTF-8 silently.

**Add `s.char_ceil(i)`.** Taking the **last** 1024 bytes of a log line
is `m[m.char_ceil(m.byte_len() - 1024)..]`. `char_floor` there would
give 1025+ bytes. Rust stabilized `floor_char_boundary` **and**
`ceil_char_boundary` together in 1.91.0 (the `round_char_boundary`
feature), for this reason. The panic's help should name whichever of
the two fits the side that cut.

prior-art.md also proposes a checked `s.get(a..b) -> Option<Str>`, which
Track A didn't adopt. Offsets that come from **input** (a format that
says "name at 12, length 5") want it. With `is_char_boundary` it's
`if s.is_char_boundary(a) && s.is_char_boundary(b) then ...`, which is
clumsy enough to argue for `get`, if `Array` has the same `get`. One
name across `Array`, `Bytes` and `Str` keeps it "one way".

**Ren against the best prior art:** with `char_ceil`, Ren matches Rust
exactly, and its panic message is better.

---

## A5: building strings

**Ergonomics:** interpolation for text with holes, `+=` (in place when
unique) for loops, `join` for lists, and no builder type. **Correctness:**
the same, with a different hole syntax. I agree with Track A, except on
the syntax.

**The hole syntax is a correctness question, not taste.** Track A
leaves it as a gavel (`{x}` or `${x}`), and lists "every `{` in JSON
needs `\{`" as the only cost. The worse cost is **silent**: with `{x}`,
any brace in literal text that happens to parse as an expression is
interpolated without warning:
- `"\\d{3}"` (a regex) becomes `\d3`;
- `"a{1,2}"` becomes `a(1, 2)` or a compile error;
- a format string for another system (`"{name}"` in a log template)
  interpolates Ren's `name`, if one is in scope.

| Holes | Silent capture? | Escapes needed in plain text | Prior art |
|---|---|---|---|
| `{x}` | **yes**: any `{…}` that parses | every literal `{` | Python f-strings, but only with an `f` prefix |
| `${x}` | rarely: `${` in shell or JS text | `$` before `{` | Roc, JS, Kotlin, Dart |
| `\{x}` | **never**: `\` is already the escape | none new | Java's JEP 430 chose `\{` for exactly this; Swift's `\(x)` |

**Recommendation: `\{x}`.** It adds no new special character to string
literals, so JSON, CSS, regexes and other systems' templates paste
unchanged. It costs one character per hole, and it reads as an escape,
which is what it is. Python's way (`{x}` only in `f"…"`) is the other
safe option, but it's a second kind of literal. Java's withdrawal of
string templates in JDK 23 was about the processor API, not the `\{`
syntax.

**Tagged templates.** The safety comes from **the sink taking a type
that isn't `Str`** (`db.query(q: Sql)`), not from the prefix. With that,
`db.query("… \{id}")` either types the literal as `Sql` (Roc/Swift
expected-type dispatch) or is a type error, and injection can't be
written. Under the literal-typing rule from fix 7, expected-type
dispatch is the same rule again, and needs no `sql"` prefix. That's one
mechanism for `Bytes`, `UInt8`, `Sql` and `Html` literals. I'd fold the
tagged-template question into the literal-typing gavel.

**Other notes:**
- Track A's "debug report for `+=` copying a shared `Str` in a loop" is
  the right guard. Go needed a runtime `copyCheck` for its builder
  (prior-art.md, Go). Perceus makes Ren's guard a report, not a rule.
- `Str + Char` fits operators.md's per-right-type `add` overloads
  (operators.md:60-66). Keep it.
- **Task 7's iolist "trap" ("`parts` must outlive the write")** isn't a
  trap in Ren: `parts` is a value the call holds. Drop it.

**Ren against the best prior art:** Rust's `format_args!` writes to a
sink without allocating. Ren's interpolation always builds a `Str`.
For output paths, Track B's B3 should measure whether lowering
`Net.write(conn, "…\{x}…")` straight to a gather write is worth doing
as a compiler optimization. It's invisible, so it fits the bet.

---

## A6: the `Str`/`Bytes` boundary

**Ergonomics and correctness: A6-strict, with `at`; lossy by name with a
pinned algorithm; `Path` over `Bytes`.** I agree with Track A.

**Add what Rust has and Track A cites but drops:** `Utf8Error::error_len()
== None` means "the input ended mid-character". A decoder working over
chunks (a frame body split across reads, a `Str` cursor over a socket)
has to tell "invalid" from "incomplete", or it rejects valid text that
happens to straddle a read. So the error should be
`InvalidUtf8(at: Int, incomplete: Bool)`, or a second variant,
`Truncated(at)`. Task 13's line reader avoids this by splitting on `\n`
first, but `Net.frames` with a `Str` field doesn't.

**Path `show`:** `\xNN` escapes are ambiguous unless a literal `\` is
escaped too. A file named `r\xE9.txt` (literally) and one named
`r<0xE9>.txt` must show differently. Use Rust's `Path::display` or
Python's `ascii()`: escape `\` as `\\`.

**`Os.args() ! NotUtf8(index)`** fails the whole call when one argument
is bad, even if the program never reads it. That's acceptable only
because `cli` reads `Path` fields from `raw_args`. Say so in the
stdlib, or most programs will reach for `Os.args()` and fail on a
Latin-1 file name.

**Ren against the best prior art:** with `at` and `incomplete`, Ren
equals Rust's `Utf8Error` and beats Swift's validating initializer,
which gives no offset (SE-0405). B5 settles the speed.

---

## A7: retention as programmers feel it

**Ergonomics and correctness: all three (manual + tiny + store).** I
agree with Track A. The user-facing rule is what matters: "think about
`copy()` only when keeping many mid-sized slices in arrays, and the
debug report tells you when".

**Correction: compact `Map` values, not only keys.** `Map<Str, Str>`
built from `key=value` lines keeps every value slice pinned under
Track A's rule. "Keys are free, values pin" is an uneven rule nobody
will remember. Apply the same ratio-and-floor check to any `Str` or
`Bytes` that goes into a `Map` or `Set`, key or value. Go's `unique.Make`
clones the whole value (prior-art.md, Go). `Array.push` stays exempt,
since decision 17's measured win depends on it.

**Pool starvation is a liveness problem, not only memory.** Task 6 and
amendments.md say that a kept line pins a **leased** chunk. A server
that keeps lines in an `Array` doesn't just use more memory: it can
exhaust the lease pool and stall reads. A7-store doesn't touch that
case. Either the streams design lets a lease that's still referenced
when it would go back to the pool be detached (copied out or replaced),
or the debug report has to treat "a leased chunk outlived its turn" as
a warning, not a note. That's for the streams gavel, but strings
inherit it.

**A7-tiny's cliff:** Track A names it (12-byte ids to 36-byte UUIDs),
and A7-store covers the map case. The cliff remains for arrays of
records. The debug report is the answer there, and that's fine.

**Ren against the best prior art:** Erlang copies sub-binaries of 64
bytes or less automatically (`erl_bits.c:2643`), and Ren's
representation B does the same. No mainstream system compacts on
container insert. Polars does it heuristically for columns. Ren would
be ahead of all of them, and it can only do this because positions are
value-relative, which is Track A's best cross-question point.

---

## What the synthesis should carry forward

These are changes to Track A's API table, in order of weight:

1. **`s.len()` becomes a compile error with help** (`byte_len`,
   `is_empty`, `chars().count()`, `graphemes().count()`), matching
   `s[i]`. This is the evidence-backed reversal (Mojo 1.0, Roc), and
   Track A's own tasks 4 and 15 show the bug.
2. **Interpolation holes are `\{x}`.** A literal takes its type from
   context (`Bytes`, `UInt8` for an ASCII char, and `Sql`/`Html` for
   templates). That one rule replaces char-literal special cases,
   `strip_prefix_bytes`, and the tagged-template prefix question.
3. **A1c with the rule "`at` is for reports, never an index"**, a
   cursor complete enough (`rest`, `bytes`, `sub`, `peek`) that no
   program indexes the original with `at`, and `FormatError.shifted(by)`
   for the rare catch-and-rethrow.
4. **Add `char_ceil`**, and consider `get(a..b) -> Option` if `Array`
   has `get`.
5. **`InvalidUtf8(at, incomplete)`**, and `Path` `show` escapes `\`.
6. **`Map`/`Set` compaction covers values as well as keys.** Lease
   starvation goes to the streams gavel.
7. **Drop:** `Str.ascii_lower`/`ascii_upper` (`Bytes.lower` is ASCII by
   receiver), `for at, x in` over cursors, and `pad_start` in chars.
8. **Fix the programs** listed in "Code in Track A that's wrong" before
   quoting them, especially the silent truncation at EOF in task 1,
   which is the very program A1 is decided on.

## Sources checked for this judgement

- Mojo `String.__len__` and `__getitem__` unavailable:
  `/tmp/ren-refs/modular/Mojo/stdlib/std/collections/string/string.mojo:809-845`,
  `/tmp/ren-refs/modular/Mojo/docs/site/releases/v1.0.0b1.md:547`.
- Roc `Str.len` guidance tag:
  `/tmp/ren-refs/roc-zig/src/build/roc/Builtin.roc:2259-2263`,
  `/tmp/ren-refs/roc-rust/crates/compiler/builtins/roc/Str.roc:526-528`.
- Rust `floor_char_boundary` and `ceil_char_boundary`, both stable in
  1.91.0: https://doc.rust-lang.org/std/primitive.str.html#method.ceil_char_boundary
  and https://goodfirstissue.org/rtk-ai/rtk/issues/1402 (the
  `round_char_boundary` gate).
- Ren's for-loop and cursor index rule: README.md:151. Its `orelse`:
  language.md:279, 784-828. Operator overloads by right type:
  operators.md:60-66. `ByteCursor.at`: lib/core/prelude.ml:420-432.
  formats.md's root-relative promise: formats.md:349-351.
- Interpolation isn't implemented in the lexer today
  (lib/syntax/lexer.ml has no string-part token), so the hole syntax is
  still free to choose.
- Java JEP 430 (`\{x}` templates, withdrawn in JDK 23 over the processor
  design): https://openjdk.org/jeps/430
- nom_locate `LocatedSpan::location_offset` / `fragment`:
  https://docs.rs/nom_locate/latest/nom_locate/struct.LocatedSpan.html
- RFC 8265 §3.3 (IdentifierClass disallows compatibility characters);
  UAX #31 §5 (NFKC_Casefold for caseless identifier matching).

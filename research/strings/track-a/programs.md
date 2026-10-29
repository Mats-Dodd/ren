# Strings, track A: paper programs on semantics

Sixteen real tasks, each written in Ren under every candidate for the
questions it touches, beside the strongest prior-art version, with the
traps each one has. A per-question verdict table follows, then the Str
API that falls out of the verdicts.

**Status.** Paper experiments. Nothing here is decided. Every string API
that Ren doesn't have today is marked `// PROPOSAL`, or listed in the
final section. What Ren's `Str` has today (lib/core/intrinsic.ml:243-292,
lib/core/prelude.ml:1260-1290): `len` (bytes), `s[a..b]`, `index`,
`split`, `trim`, `starts_with`, `concat`, `bytes`, `Str.from_utf8 !
InvalidUtf8` (no offset), `copy`, `split_at`, and `lower`, which is
**ASCII only** (lib/eval/builtins.ml:294).

## What the reader needs first

**The candidates,** with short names used throughout:

| Q | Candidates |
|---|---|
| A1 positions | **A1a**: value-relative only. **A1b**: root-relative (formats.md's current promise). **A1c**: value-relative, plus an explicit base where the program says the value starts (`b.cursor(from: n)`, a reader that carries its offset) |
| A2 meaning of `len`/index | **A2-bytes**: Go's way, `s[i]` is a byte. **A2-none**: Swift's way, no integer index, opaque positions. **A2-views**: byte `len` and byte ranges, no `s[i]`, explicit `.chars()` and `.graphemes()` views. **A2-named**: Mojo 1.0's way, `s[byte=a..b]`, `s[grapheme=a..b]` |
| A3 equality | **A3-bytes**: Rust, Go, Python. **A3-canon**: Swift, canonical equivalence. **A3-bytes+nfc**: byte equality plus explicit `.nfc()` / `.nfkc_fold()` |
| A4 cutting a char | **A4-panic**: today's rule. **A4-round**: round to a boundary. **A4-panic+floor**: panic, plus an explicit `s.char_floor(i)` for computed limits |
| A5 building | **A5-plus**: `+` and `+=`, in place when unique. **A5-builder**: a `StrBuilder`. **A5-iolist**: a tree of parts written with `writev`. **A5-interp**: interpolation as the main tool |
| A6 boundary | **A6-strict**: `Bytes→Str` validates and fails with an offset, nothing else. **A6-lossy**: plus a named lossy conversion. **A6-os**: where paths, args and env live |
| A7 retention | **A7-manual**: `copy()` plus a debug report (today). **A7-tiny**: plus the compiler/runtime copies tiny slices (inline small strings, representation B). **A7-store**: plus the runtime compacts a slice when it's stored somewhere long-lived (a `Map`/`Set` key) |

**Two facts the paper runs turned up before any program:**

1. **Layer 3 as built is already A1a, and formats.md promises A1b.**
   `ByteCursor.at()` is "where it is, in the bytes it was made from"
   (lib/core/prelude.ml:426), and bench/bytes/cursor.ren checks that "a
   cursor over a slice counts from the slice's start". formats.md,
   "Errors carry offsets", says `at` "is the offset in the whole buffer,
   the file or the socket's". So the docs and the build already
   disagree. Picking A1c means only formats.md changes.
2. **A1b can't be implemented truthfully for the inputs that matter.**
   A socket's bytes arrive as leased chunks (stdlib.md, runtime-io.md).
   A chunk is a root, so a root-relative offset is an offset into a
   64 KB lease, not into the stream. A frame that spans chunks is
   joined into a new root, and its offsets start again at 0. The
   promise "offset in the socket" is false for the program it was
   written for.

**Syntax conventions.** These follow language.md, stdlib.md,
formats.md and examples/just: `fn f(x: T) -> R ! E uses D =`,
`try`, `attempt`, `fail`, `orelse`, `let ... else`, `&x.push(v)`,
`for x in &c`, and `for at, x in ...` for an index and an element.
Cursors and pipelines follow streams.md as amended
(scratchpad/streams/amendments.md): pipelines are blocks, value cursors
are data, `for x in try &c`. Interpolation is written `"{x}"`, as
stdlib.md's examples already write it (`"jobs/{job}"`). It isn't decided
(stdlib.md, open questions).

---

## 1. A framing loop over a socket

Length-prefixed frames, each a `UInt32 be` length then a body. A frame
may span reads, and a read may hold several frames. A malformed frame
must be reported with its offset **in the connection's stream**, so the
operator can find it in a pcap. Touches **A1** and **A7**.

### A1a: value-relative only

```ren
type Frame = { body: Bytes }

fn frame(inout c: ByteCursor) -> Frame ! FormatError =
  let n = try &c.u32_be()
  if n > 16_777_216 then fail Malformed(c.at() - 4, "", "frame of {n} bytes")
  Frame { body: try &c.bytes(n) }

fn session(conn: Conn) ! NetError | FormatError uses Net =
  var buf = Bytes.empty()        // what's read and not yet framed
  var base = 0                   // stream offset of buf's first byte: by hand
  var open = true
  while open
    var c = buf.cursor()
    var more = true
    while more
      var next = c
      match attempt frame(&next)
        Ok(f) =>
          try handle(f)
          c = next
        Err(Short(_, _)) => more = false
        Err(Malformed(at, p, why)) => fail Malformed(base + at, p, why)   // shift every variant by hand
        Err(UnknownTag(at, t)) => fail UnknownTag(base + at, t)
    base += c.at()
    let got = try Net.read(conn, 65_536)
    if got.len() == 0 then open = false
    buf = c.rest() + got              // PROPOSAL: Bytes `+`, in place when unique
```

### A1b: root-relative

```ren
fn session(conn: Conn) ! NetError | FormatError uses Net =
  var buf = Bytes.empty()
  var open = true
  while open
    var c = buf.cursor()
    ...                               // the same inner loop, errors passed on unchanged
    let got = try Net.read(conn, 65_536)
    if got.len() == 0 then open = false
    buf = c.rest() + got              // a NEW root: every later `at` restarts at 0
```

The error passes through untouched, and it reports the wrong number.
`at` counts from the start of whichever root `buf` is today. That's
the joined buffer after a span, the leased chunk when nothing was
left over, or a copy the interpreter made. It is never the stream
offset, and it differs between `ren run` and a native build wherever
the two make roots differently. The program can't detect any of this.

### A1c: value-relative, with the base said once

```ren
fn session(conn: Conn) ! NetError | FormatError uses Net =
  var buf = Bytes.empty()
  var base = 0
  var open = true
  while open
    var c = buf.cursor(from: base)    // PROPOSAL: positions count from `base`
    var more = true
    while more
      var next = c
      match attempt frame(&next)
        Ok(f) =>
          try handle(f)
          c = next
        Err(Short(_, _)) => more = false
        Err(e) => fail e              // `at` is already the stream offset
    base = c.at()
    let got = try Net.read(conn, 65_536)
    if got.len() == 0 then open = false
    buf = c.rest() + got
```

And what most programs write once `Net.frames` ships (amendments.md,
"Ship `Net.frames(conn, fmt)`"). The library carries the base, so the
user carries nothing:

```ren
format wire for Frame, be =
  len: UInt32
  body: Bytes[len]

fn session(conn: Conn) ! NetError | FormatError uses Net =
  for f in try Net.frames(conn, Frame.wire)    // errors' `at` = stream offset (A1c inside)
    try handle(f.value)
```

### Prior art: Rust, tokio-util `Decoder`

```rust
fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Frame>, E> {
    if src.len() < 4 { return Ok(None) }
    let n = u32::from_be_bytes(src[..4].try_into().unwrap()) as usize;
    if n > MAX { return Err(E::TooBig { at: self.consumed }) }  // offset tracked by hand
    if src.len() < 4 + n { src.reserve(4 + n - src.len()); return Ok(None) }
    src.advance(4); self.consumed += 4 + n as u64;
    Ok(Some(Frame { body: src.split_to(n).freeze() }))
}
```

Erlang's `{packet, 4}` socket option does the framing in the driver, but
its errors carry no offset at all (formats.md, Evidence:
`zip.erl:2011-2027`).

### Traps

| Version | Trap |
|---|---|
| A1a | Shifting the error means matching every variant of `FormatError`. A new variant added later is silently unshifted wherever someone wrote `Err(e) => fail e` "to be safe". |
| A1b | **Silent wrong answer.** The offset counts from whatever the current root is. It changes when the buffer is joined, compacted or copied, and between `ren run` and native builds. It looks right in a test with one read. |
| A1c | `from:` must be passed each time the buffer is rebuilt. Forgetting it gives buffer-relative offsets, which are wrong but honest and consistent everywhere. `Net.frames` removes the chance. |
| Rust | `self.consumed` is by hand, and `reserve` is the user's job. |
| all | `c.rest() + got` copies the unread tail on every read that ends mid-frame. One 1 MB frame in 16 KB reads moves 32 MB. `Short(need)` lets `Net.frames` read `need` into one buffer. That's B-track work, not semantics. |

**A7 here:** `f.body` is a slice of `buf`. A handler that keeps it pins
the whole read buffer, or the leased chunk (amendments.md: "a slice kept
past the body's turn holds its leased chunk"). Under A7-manual the
handler writes `f.body.copy()`. Under A7-store, putting it in a `Map`
compacts it. Under A7-tiny, only a body of 15 bytes or less is free.

**Verdict:** A1c. A1b is wrong for exactly this program. A1a is
correct, but it makes every framing loop re-derive the stream offset
and shift each error variant.

---

## 2. A CSV parser reporting `line:column`

`Bad quote at 3:17`. The file is read whole as `Str`. The parser works
on byte offsets and reports `line:column` for a human. Touches **A1**,
**A2** and **A6**.

### Ren (A2-views, A1c; the parser is the same under A1a)

```ren
type CsvError = ! BadQuote(line: Int, col: Int) | Ragged(line: Int, want: Int, got: Int)

// A row is slices of `text`; a quoted field with "" in it is a new Str.
fn parse(text: Str) -> Array<Array<Str>> ! CsvError =
  let b = text.bytes()                         // free: the same buffer
  var rows: Array<Array<Str>> = []
  var row: Array<Str> = []
  var i = 0
  while i < b.len()
    if b.u8(i) == '"' then                     // PROPOSAL: a char literal as a byte, see "Char"
      let (field, end) = try quoted(text, i)
      &row.push(field)
      i = end
    else
      var j = i
      while j < b.len() && b.u8(j) != ',' && b.u8(j) != '\n'
        j += 1
      &row.push(text[i..j])                    // never cuts: ',' and '\n' are ASCII
      i = j
    if i < b.len() && b.u8(i) == '\n' then
      &rows.push(row)
      row = []
    i += 1
  rows

fn quoted(text: Str, start: Int) -> (Str, Int) ! CsvError =
  match text[start + 1..text.len()].index("\"")
    None =>
      let (line, col) = text.line_col(start)   // PROPOSAL: 1-based line, column in chars
      fail BadQuote(line, col)
    Some(k) => ...
```

`line_col(at)` is a method of the **text that holds `at`**, so the
answer can't depend on a root. Under A1a and A1c, a parser given one
line (`parse_line(l)`) reports the column in that line. The caller adds
the line number it already counts:

```ren
for n, l in text.lines().with_index()          // PROPOSAL: lines(); with_index exists on Array
  match attempt parse_line(l)
    Err(BadField(col)) => fail BadQuote(n + 1, col)
    ...
```

### A1b

Under A1b, a `parse_line(l)` given `text.lines()[k]` would get offsets
in the whole file "for free", which is formats.md's argument. That holds
only while `l` is still a slice of the file's root. The same function
given a line from `Fs.line_reader` (a slice of a 64 KB lease), from a
test literal, or after `l.copy()` gives a different number for the same
text. **The A1b win is real only for the one call shape where the
caller didn't need it.**

### A2-bytes (Go's `s[i]` is a byte)

```ren
if text[i] == '"' then ...        // under A2-bytes, s[i] reads a byte
```

That's shorter than `text.bytes().u8(i)`. The trap is `text[i]` on a
non-ASCII column: you get one byte of `é`, and the parser treats it as a
character. Go programs do exactly this. A2-views keeps byte access one
call away, explicit, and free.

### Column units

| Column counted in | `"naïve,"x` cut at `x` | Trap |
|---|---|---|
| bytes | 9 | Wrong for any editor. |
| chars (code points) | 8 | rustc reports this. Matches editors for most text, and is cheap. |
| graphemes | 8 | The same here. Differs for `é`, emoji and ZWJ sequences, and depends on the Unicode version. |
| UTF-16 units | 8 | LSP's default. Wrong for emoji outside an editor. |

Propose **chars**, deterministic, with a pinned table not needed at all,
since UTF-8 decoding is version-free. A `line_col_graphemes` isn't
worth a second name.

### Prior art: Rust (csv crate)

```rust
let mut rdr = csv::Reader::from_reader(file);
for rec in rdr.records() {
    let rec = rec?;  // csv::Error has .position(): Position { byte, line, record }
}
```

The csv crate's `Position` carries byte, line and record, and the reader
tracks them. Python's `csv` gives only `reader.line_num`.

### Traps

- **A1b:** a different column for the same line, depending on how it was
  obtained. That's silent.
- **A2-bytes:** a non-ASCII byte read as a character.
- **all:** `text[i..j]` can't panic here, because the separators are
  ASCII. That's the decision 17 promise ("found boundaries don't
  check"). A parser that cut at `j - 1` to drop a trailing `\r` would
  be fine too, since `\r` is ASCII.
- **A6:** reading the file needs `Fs.read_str`, which fails today with
  `InvalidUtf8` and **no offset**. It must say `at`, so the parser's
  `line_col` can be reused for "invalid UTF-8 at 12:3" (task 9).

**Verdict:** A1c, or A1a (they're identical here), A2-views, columns in
chars.

---

## 3. Truncating a display name to 20 visible characters

`"Zoë 👩‍👩‍👧 Smith-Jones the Third"` becomes at most 20 user-perceived
characters plus `…`. Touches **A2** and **A4**.

### A2-views (graphemes as a cursor of slices)

```ren
fn short_name(s: Str) -> Str =
  let end = s.graphemes().take(20).map(fn(g) => g.len()).sum()  // PROPOSAL: graphemes()
  if end == s.len() then s else s[0..end] + "…"                 // PROPOSAL: Str `+`
```

This is three proposals and no new concept. `graphemes()` yields
**slices of `s`, in order**, so their byte lengths summed from the
start is a boundary. That works because positions are value-relative.
`take`, `map` and `sum` are the streams vocabulary on a cursor
(streams.md, "One vocabulary, two receivers"). The slice `s[0..end]` is
at a grapheme boundary, which is also a char boundary, so it can't panic.

A form with indices, if the pipeline isn't liked:

```ren
fn short_name(s: Str) -> Str =
  var n = 0
  for at, _ in s.graphemes()            // PROPOSAL: `at` = byte offset of each in `s`
    if n == 20 then return s[0..at] + "…"
    n += 1
  s
```

### A2-bytes

```ren
fn short_name(s: Str) -> Str =
  if s.len() <= 20 then s else s[0..20] + "…"    // panics: 20 is inside 'ë' or the emoji
```

### A2-bytes + A4-round

```ren
  if s.len() <= 20 then s else s[0..20] + "…"    // rounds down: no panic, but 20 BYTES:
                                                 // "Zoë 👩‍👩‍" — a family cut to two women
```

### A2-named (Mojo 1.0)

```ren
  s[grapheme=0..20] + "…"          // O(n) scan hidden behind index syntax; the count check is separate
```

### A2-none (Swift)

```swift
func shortName(_ s: String) -> String {
    s.count <= 20 ? s : String(s.prefix(20)) + "…"   // count and prefix are graphemes
}
```

Swift's is the best prior-art version: one line, correct by default. Its
costs are that `s.count` is O(n) every time it's called, and that the
result depends on the OS's Unicode version (graphemes changed in Unicode
15.1 for Indic conjuncts).

### Traps

| Version | Trap |
|---|---|
| A2-bytes | Panics on the first non-ASCII name: the bug ships, then crashes in production. |
| A2-bytes + A4-round | No crash, but a ZWJ family or a flag is split into a different emoji, and the length is bytes, not characters. **Silent.** |
| A2-views via chars (`s.chars().take(20)`) | Counts code points: `é` written as `e` + U+0301 counts as two, and a flag counts as two. Off by a little, silently. |
| A2-views via graphemes | Correct. The result changes when Ren's pinned Unicode version changes, which is deterministic per release (stdlib.md's determinism test). The cost is O(n), visible as a cursor. |
| A2-named | Correct, but the O(n) is hidden behind `[]`. That's the cost Mojo documents in v1.0.0b1 ("prefer `byte=` when byte offsets are known"). |
| all | "Visible characters" may really mean **terminal columns** (CJK is 2 wide, UAX #11). That's a different function, `display_width`, and belongs in a terminal library, not std `Str`. |

**Verdict:** A2-views with graphemes as a cursor of slices. A4-panic is
never reached, because the boundaries are found ones.

---

## 4. Case-insensitive username comparison

Is `"STRASSE"` the same user as `"straße"`, and `"Ⅸ"` the same as `"ix"`?
For a login, the answer must be stable, and the same in `ren run`, every
native build, and replay. Touches **A3**.

### A3-bytes + today's `lower` (ASCII)

```ren
fn same_user(a: Str, b: Str) -> Bool = a.lower() == b.lower()   // ASCII only today
// "ÉMILE" vs "émile": false. Two accounts for one person.
```

### A3-bytes + Unicode `lower`

```ren
fn same_user(a: Str, b: Str) -> Bool = a.lower() == b.lower()   // PROPOSAL: lower is Unicode
// "STRASSE" vs "straße": "strasse" vs "straße" → false
// "é" vs "é": false (not normalized)
```

### A3-bytes+nfc: an explicit fold for identity

```ren
fn same_user(a: Str, b: Str) -> Bool = a.nfkc_fold() == b.nfkc_fold()   // PROPOSAL
// Unicode's toNFKC_Casefold (UAX #44, DerivedNormalizationProps):
// "STRASSE" ≡ "straße", "é" ≡ "é", "Ⅸ" ≡ "ix", fullwidth "ＡＢＣ" ≡ "abc"
```

And because it's a login, the real program normalizes **once, at the
boundary**, into a type (task 15):

```ren
pub type Username = opaque { shown: Str, id: Str }
  pub fn parse(s: Str) -> Username ! Invalid =
    let t = s.trim()
    if t.len() == 0 || t.len() > 64 then fail Invalid
    Username { shown: t, id: t.nfkc_fold() }     // PROPOSAL
  pub fn key(self) -> Str = self.id              // ==, hash and < go through it (operators.md)
  pub fn show(self) -> Str = self.shown
```

### A3-canon (Swift)

```ren
fn same_user(a: Str, b: Str) -> Bool = a.lower() == b.lower()
// == is canonical equivalence: "é" ≡ "é" holds; "STRASSE" vs "straße" still false;
// "Ⅸ" vs "ix" false (compatibility, not canonical)
```

Canonical equality fixes one of the four cases, and it costs every `==`
in the program.

### Prior art

- **RFC 8265 (PRECIS UsernameCaseMapped):** width-map, then case-map,
  then NFC, then reject disallowed code points. That's the closest
  standard for exactly this task.
- **Swift:** `a.caseInsensitiveCompare(b) == .orderedSame`, which is
  Foundation and locale-sensitive.
- **Go:** `strings.EqualFold(a, b)`, simple case folding only.
  `"straße"` vs `"STRASSE"` is false.
- **Erlang:** `string:equal(A, B, true, nfc)`, case-insensitive with
  normalization, explicit (lib/stdlib/src/string.erl:286-299).
- **Roc:** `Str.caseless_ascii_equals` only. Unicode case lives in a
  package that "can be upgraded independently"
  (crates/compiler/builtins/roc/Str.roc:1360-1423).

### Traps

| Version | Trap |
|---|---|
| ASCII `lower` (today) | **Silent:** two accounts for one person, and operators.md's `Email` example inherits this, since `key` is `self.lower()`. |
| Unicode `lower` | `ß`, unnormalized input, and compatibility forms all slip through. `lower` is for display, not identity. Turkish `İ` lowercases to `i̇` (two code points). |
| `nfkc_fold` | Correct for identity. The result depends on the pinned Unicode version, which only changes when Ren's tables change. A stored `id` from an older version stays valid for every assigned code point (the Unicode normalization stability policy), but not for code points that were unassigned when it was stored. So "reject unassigned" belongs in the parse, as PRECIS does. |
| A3-canon | Fixes only the canonical case, makes every `==` cost a normalization check, and makes `==` on `Str` disagree with `==` on `s.bytes()` (see task 15). |
| all | Confusables (`раypal` with a Cyrillic `а`) are a different problem, UTS #39 skeletons, and belong in a library. |

**Verdict:** A3-bytes+nfc. The fix is a named fold, applied once at the
boundary, through the `key` mechanism Ren already has. Unicode `lower`
and `upper` are still wanted for display, and must be Unicode, not
ASCII.

---

## 5. Slugify a title

`"Crème Brûlée: 10 Ways — Straße Edition!"` becomes
`crème-brûlée-10-ways-straße-edition` (Unicode slug) or
`creme-brulee-10-ways-strasse-edition` (ASCII slug). Touches **A2**,
**A3** and **A5**.

### A2-views + A5-plus (ASCII slug)

```ren
fn slug(title: Str) -> Str =
  var out = ""
  var dash = false
  for c in title.nfkd().fold().chars()           // PROPOSAL: nfkd, fold, chars
    if c.is_ascii_alphanumeric() then            // PROPOSAL: Char methods
      if dash && out.len() > 0 then out += "-"
      out += c                                   // PROPOSAL: Str + Char
      dash = false
    else if not c.is_mark() then dash = true     // drops the accents NFKD split off
  out[0..out.char_floor(80)]                     // PROPOSAL: char_floor; ASCII so exact anyway
```

`fold` (full case folding) turns `ß` into `ss`, NFKD splits `é` into `e`
plus U+0301, and `is_mark` drops the mark. `out += ...` is in place,
because `out` is unique. That's A5-plus's whole promise.

### A2-bytes (bytes only)

```ren
fn slug(title: Str) -> Str =
  var out = ""
  for i in 0..title.len()
    let b = title[i]                             // a byte
    if (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') then out += Str.of_byte(b)
    ...
// "Crème" → "crme". Silent.
```

### A5-builder

```ren
  var sb = StrBuilder.empty()
  ...
  &sb.push(c)
  sb.finish()
```

This adds a type and a `finish` call. It buys nothing over `+=` once
Perceus makes `+=` in place. That's the Roc argument: `Str.concat` and
`Str.reserve` operate in place when unique, and Roc has no builder type
(Str.roc:409, 435, 493).

### Prior art: Python (python-slugify, with unidecode)

```python
slugify("Crème Brûlée: 10 Ways — Straße Edition!")  # 'creme-brulee-10-ways-strasse-edition'
```

That's a library with a transliteration table. In std Python, the idiom
is `unicodedata.normalize("NFKD", s).encode("ascii", "ignore")`, which
drops `ß` entirely (`"strae"`).

### Traps

| Version | Trap |
|---|---|
| A2-bytes | Non-ASCII letters vanish silently. |
| A2-views without `fold` | `ß` turns into `-` (it isn't ASCII and isn't a mark): `stra-e`. |
| A2-views with `lower` instead of `fold` | The same `ß` problem. `fold` is the right tool, and `lower` isn't. Two names that do different things is a cost, and the docs must say when to use which. |
| `out[0..80]` without `char_floor` | Fine for an ASCII slug. A Unicode slug panics there (task 16). |
| all | CJK titles slug to the empty string. Transliteration is a library (std.x), not `Str`. |

**Verdict:** A2-views and A5-plus. The task exposed the need for
`nfkd`, `fold`, `is_mark` and `is_ascii_alphanumeric`.

---

## 6. Keeping 10k keys from a 1 GB log

Read a 1 GB access log, and keep the first 10,000 distinct client ids
(each about 12 bytes) in a `Set<Str>` that lives for the life of the
process. Touches **A7**.

### A7-manual (today)

```ren
fn first_clients(path: Path) -> Set<Str> ! FsError | InvalidUtf8 uses Fs =
  var seen: Set<Str> = Set.empty
  for line in try &Fs.line_reader(path)          // streams: lines are slices of leased chunks
    if seen.len() == 10_000 then break
    let id = line.split(" ")[2]
    if not seen.includes(id) then &seen.add(id.copy())   // forget .copy() and...
  seen
```

Without `.copy()`, each key pins its chunk. 10,000 keys spread over
about 16,000 chunks of 64 KB hold up to **640 MB**, and the leased pool
starves (amendments.md: "a slice kept past the body's turn holds its
leased chunk"). With `Fs.read` (the whole file as one root), they pin
the whole **1 GB**. foundations.md, decision 17 measured the same shape:
80 KB of keys holding 67 MB.

The debug report, as decided, catches it after the fact:

```
note: 10,000 slices of 12 to 16 bytes keep 1,048 chunks of 64 KB alive (640 MB)
  ┌─ clients.ren:6:47
  │
6 │     if not seen.includes(id) then &seen.add(id)
  │                                             ^^ made here
  = help: keep a copy: `id.copy()`
```

### A7-tiny (inline small strings, representation B)

The same program with no `.copy()`. A `Str` of 15 bytes or less is
stored inline in its 16-byte value (German-string or Umbra layout, or
Swift's small strings). Slicing a 12-byte id out of a chunk gives an
inline value with **no root**. That's not a copy the user asked for:
the representation has no pointer to keep. Nothing is pinned.

That covers exactly this task. It doesn't cover 40-byte UUIDs, URLs, or
user agents.

### A7-store (the runtime compacts slices stored long-lived)

The same program with no `.copy()`. `Set.add` and `Map.set` look at a
key that's a slice. If its root is more than, say, 4× its length and
more than a page, they copy it on insert, which is Erlang's
`referenced_byte_size` heuristic made automatic (otp
lib/stdlib/src/binary.erl:637-690, whose docs show exactly this `store`
function written by hand). It's unobservable, because positions are
value-relative (A1a or A1c) and slices have no identity. **Under A1b it
would be observable:** a key's offsets would change on insert. That's
another reason A1b is out.

What A7-store doesn't cover: a slice kept in a record in an `Array`,
for example `&tokens.push(Token { text: line[a..b] })` over a 1 GB file.
The decision 17 numbers (1.09× to 1.17× for kept slices) say that's
often wanted. The debug report stays for it.

### Prior art

- **Erlang:** the same trap, and the fix is `binary:copy/1` by hand,
  guarded by `binary:referenced_byte_size` (cited above). OTP's notes
  record small sub-binaries keeping large ones alive (erts/doc/notes.md,
  cited in formats.md).
- **Java 7u6** removed `substring` sharing altogether, because of this
  trap. Every substring now copies.
- **Go:** `strings.Clone` (Go 1.20) exists for exactly this. The trap is
  silent.
- **Swift:** `Substring` is a different type, and storing it as a
  `String` copies. That makes the trap visible in types, at the cost of
  two types (Swift's Substring docs: "Don't store substrings
  long-term").
- **Roc:** seamless slices, with the same trap and no tool.

### Traps

| Version | Trap |
|---|---|
| A7-manual | You learn about it in a debug report, or in production memory graphs. Every key-keeping loop needs `.copy()`, and the user must know to write it. |
| A7-tiny | Correct for the common short-key case. A key that grows past 15 bytes (from 12-digit to UUID ids) suddenly pins chunks again, as a **performance cliff from a data change**. |
| A7-store | A copy per insert, of the key only, which is cheap. The ratio threshold is a tuning knob (Track B). A key that's a whole small file (ratio ≤ 4) isn't copied, which is correct. |
| Java-style always copy | Loses decision 17's measured win (24M slices, 0.96× of offsets). |

**Verdict:** all three together. Representation B makes tiny slices
free. `Map`/`Set` compaction on insert covers the "keys from a big
input" pattern. `copy()` plus the debug report covers records in arrays.
After that, a user thinks about `copy()` only when keeping many
mid-sized slices in records, which is where decision 17 says offsets
are the fastest tool anyway.

---

## 7. Building a JSON response

`{"user": "...", "items": [...], "total": 12.50}`. Touches **A5**.

### Ren, the obvious way: shapes

```ren
type Item = { sku: Str, qty: Int }
type Resp = { user: Str, items: Array<Item>, total: Decimal }

fn respond(conn: Conn, r: Resp) ! NetError uses Net =
  try Net.write(conn, json.encode(r).bytes())   // encode: Str; .bytes(): free
```

That's one call, and escaping is correct by construction (stdlib.md:
json over `T.shape`). It's the answer for A5 in this task: **the
obvious way to build JSON isn't string building at all.**

### A5-interp by hand

```ren
let body = "\{\"user\": \"{r.user}\", \"total\": {r.total}\}"   // `{` must be escaped
// r.user = "Ann \"the hacker\"" → invalid JSON, or injection
```

### A5-plus by hand (for a format json doesn't cover)

```ren
var s = "["
for i, it in r.items.with_index()
  if i > 0 then s += ","
  s += json.quote(it.sku)                         // PROPOSAL: json.quote escapes one string
s += "]"
```

### A5-iolist

```ren
let parts = ["[", json.quote(a), ",", json.quote(b), "]"]
try Net.write_all(conn, parts)      // PROPOSAL: writev of an Array<Bytes or Str>
```

That's an Erlang iolist as an `Array<Str>`. B3 measures whether the
runtime needs it. Semantically it's just "write these in order", and it
needs no new type.

### Prior art

- **Rust:** `serde_json::to_vec(&r)?`, or `json!({"user": r.user})`, a
  macro that escapes.
- **Go:** `json.NewEncoder(w).Encode(r)`.
- **Elixir:** `Jason.encode_to_iodata!(r)`, which gives an iolist,
  written with `writev`, never flattened.

### Traps

| Version | Trap |
|---|---|
| interpolation | **Injection.** Any user `Str` with `"` or `\` breaks the output. Every `{` in the JSON must be escaped, which is ugly enough that people write it wrong. |
| `+=` | Correct with `json.quote`. Quadratic if `s` isn't unique, for example if it was also pushed into a log array mid-build (each `+=` then copies). A debug report should flag "`+=` copied a shared Str in a loop". |
| iolist | Fast, but `parts` must outlive the write (fine here). |
| shapes | None for this task. |

**Verdict:** shapes for JSON, `+=` for ad-hoc. This task argues for a
**tagged-template rule**: `json"..."`, `sql"..."` and `html"..."` hand
their parts to a library that escapes them (stdlib.md, open question).
That way plain interpolation never meets untrusted text in a structured
format.

---

## 8. A template with interpolation

An email body: greeting, an amount of money, a date, a list of items.
Touches **A5**.

### A5-interp

```ren
fn email(u: User, order: Order) -> Str =
  let lines = order.items.map(fn(i) => "  - {i.name} × {i.qty}").join("\n")   // PROPOSAL: join
  "Hello {u.name},

Your order {order.id} of {order.total.round(2, HalfEven)} ships on {order.ships.date()}.

{lines}
"
```

- `{x}` calls `show` (operators.md: "One `show`, used by `print`,
  interpolation and test output"). A `Str` shows as itself at the top.
- **There's no format mini-language.** Width, precision and padding are
  methods: `{x.round(2, HalfEven)}`, `{n.pad_start(6)}`. That's one way
  to format, not `{x:>6.2}` beside methods.
- Multi-line literals are needed (Roc's `"""` with indentation
  stripped, Str.roc:15-27). That isn't designed yet. **PROPOSAL:**
  `"""` as Roc's.

### A5-plus

```ren
  "Hello " + u.name + ",\n\nYour order " + show(order.id) + " of " + ...
```

That's legal and nobody should write it. It survives as the
loop-building tool (tasks 5 and 7).

### A5-builder

A builder adds nothing that interpolation plus `join` plus `+=` lacks.

### Prior art

- **Python:** f-strings, `f"{x:>6.2f}"`, which has a format
  mini-language, and PEP 750 t-strings (3.14), which give the parts to a
  library. That's the `sql"..."` idea.
- **Swift:** `"\(x)"` with `DefaultStringInterpolation`, extensible per
  type (SE-0228).
- **Roc:** `"${x}"`. Roc moved from `\(x)` to `${x}` so that `{` in
  ordinary text needs no escape (Str.roc:31-50).
- **Mojo 1.0:** `t"..."` t-strings, flattened at build time
  (v0.26.2.md:700-712).

### Traps

| Version | Trap |
|---|---|
| `"{x}"` | JSON, CSS and code templates are full of `{`, and each needs `\{`. `${x}` (Roc, JS, Kotlin) avoids that, at the cost of one character on every hole. **A gavel.** |
| no format language | `"{price}"` on a `Float` prints `12.5`, not `12.50`. That's correct, but surprising. Money should be `Decimal` (stdlib.md), whose `show` keeps its scale. |
| `show` of a `Str` inside a collection | `"{names}"` prints `["Ann", "Bo"]` (quoted inside). Good for debugging, and occasionally surprising in user-facing text. Write `names.join(", ")`. |

**Verdict:** A5-interp as the main tool, for text. `+=` for loops,
`join` for lists, and tagged templates for structured formats.

---

## 9. Reading a file that may not be UTF-8

A config file, usually UTF-8, sometimes Latin-1 from an old editor,
sometimes with a UTF-8 BOM. Touches **A6**, and **A1** for the offset.

### A6-strict

```ren
fn load(p: Path) -> Config ! FsError | InvalidUtf8 | ConfigError uses Fs =
  let text = try Fs.read_str(p)              // fails: InvalidUtf8(at: 1043)   PROPOSAL: `at`
  try Config.parse(text)

// reporting it as a human wants:
match attempt Fs.read_str(p)
  Err(InvalidUtf8(at)) =>
    let b = try Fs.read(p)
    let (line, col) = Str.from_utf8_lossy(b[0..at]).line_col(at)   // the prefix IS valid
    fail BadConfig("{p}:{line}:{col}: not UTF-8")
  ...
```

`b[0..at]` is valid UTF-8 by the definition of `at`, the first byte
that isn't. Its `line_col(at)` is exact.

### A6-lossy

```ren
let text = Str.from_utf8_lossy(try Fs.read(p))   // PROPOSAL: U+FFFD per maximal subpart
```

The replacement must be one pinned algorithm, Unicode's "U+FFFD
substitution of maximal subparts" (Unicode 15, §3.9, and the WHATWG
Encoding standard's), so `ren run` and native builds agree byte for
byte.

### Latin-1 fallback (a library, not `Str`)

```ren
let b = try Fs.read(p)
let text = match attempt Str.from_utf8(b.strip_prefix_bytes(BOM))   // PROPOSAL names
  Ok(s) => s
  Err(_) => latin1.decode(b)                                        // total: every byte maps
```

### Prior art

- **Rust:** `String::from_utf8(v)` gives `Utf8Error::valid_up_to()` and
  `error_len()` (`None` if the input was cut mid-sequence), and
  `String::from_utf8_lossy` gives a `Cow`. This is the best version:
  offset and kind, strict by default, lossy by name.
- **Swift:** `String(validating: bytes, as: UTF8.self)` gives an
  optional, with no offset (SE-0405), and `String(decoding:)` repairs.
- **Python:** `open(p, errors="strict" | "replace" | "surrogateescape")`.
  `surrogateescape` (PEP 383) round-trips invalid bytes through `str`.
  That's a lie in the type.
- **Go:** a `string` can hold anything. `utf8.ValidString` must be
  asked, and `range` silently yields U+FFFD.
- **Roc:** `Str.from_utf8 : List U8 -> Result Str [BadUtf8 { problem,
  index }]` and `from_utf8_lossy` (Str.roc:338-342, 540-550).
- **Lean 4:** `String.fromUTF8?` and a lossy decoder
  (src/Init/Data/String/Lossy.lean).

### Traps

| Version | Trap |
|---|---|
| today's `InvalidUtf8` without an offset | The user can't say where. That's a 1-line fix with real value. |
| A6-lossy as the default anywhere | Silent data loss. A config value with `\xE9` becomes `�`, and is written back that way. It must be a name you choose. |
| Python surrogateescape style | A `Str` that isn't UTF-8 breaks the invariant everything else relies on (task 15's hash, `line_col`, slicing). Rejected. |
| Go style | Every function must re-validate, or not. |
| BOM | `Str.from_utf8` should **not** strip a BOM (it's a valid U+FEFF). `Fs.read_str` could, but then `read_str` and `from_utf8(read)` differ. Keep both literal, and offer `s.strip_prefix("\u{FEFF}")`. |

**Verdict:** A6-strict, with an `at`, plus a named `from_utf8_lossy`
with a pinned algorithm. Latin-1 and other encodings go in a library.

---

## 10. Splitting on whitespace

`"  GET   /index.html\tHTTP/1.1 "` becomes `["GET", "/index.html",
"HTTP/1.1"]`, and a user-typed `"tag one  tag two"` too. Touches
**A2**.

### A2-views

```ren
let words = line.fields()                // PROPOSAL: Unicode White_Space, empty parts dropped
// or, for a protocol, ASCII only:
let parts = line.fields_ascii()          // PROPOSAL? see trap
```

### A2-bytes / today

```ren
let words = line.split(" ").select(fn(w) => w != "")   // tabs and NBSP stay inside words
```

That's examples/just/justfile.ren today, which splits on `" "` and then
again on `"\t"` (lines 31-33).

### Prior art

- **Go:** `strings.Fields(s)`, Unicode space, and
  `bytes.Fields`.
- **Rust:** `s.split_whitespace()` (Unicode) and
  `s.split_ascii_whitespace()`.
- **Python:** `s.split()` with no argument, Unicode.

### Traps

| Version | Trap |
|---|---|
| `split(" ")` | Empty strings for runs of spaces, and tabs and NBSP kept inside words. **Silent.** |
| Unicode `fields` in a protocol parser | HTTP says SP and HTAB only. U+0085 or U+00A0 would split where the spec doesn't. That's a smuggling vector in a security-relevant parser. |
| two names | `fields` and `fields_ascii` both exist in Rust, and people pick wrongly both ways. |

**Verdict:** A2-views. `fields()` uses Unicode White_Space, since text
is the default. Protocol parsers work on `Bytes` (task 12), where
`b.fields()` is ASCII by definition, because bytes have no Unicode. So
the type picks, and there's no `_ascii` twin. That's one name, two
receivers, which is streams.md's "the receiver decides" applied to
`Str`/`Bytes`.

---

## 11. Word count and grapheme count

A text box shows "143 words, 812 characters". Twitter-style limits
count graphemes, or code points. Touches **A2**.

### A2-views

```ren
let words = text.fields().len()                   // whitespace words
let chars = text.graphemes().count()              // PROPOSAL: cursor sink `count()`
let bytes = text.len()                            // what a DB column limit means
```

### A2-bytes

```ren
let chars = text.len()     // bytes: "naïve" is 6
```

### A2-none (Swift), the best prior-art version

```swift
let chars = text.count                                       // graphemes
let words = text.split(whereSeparator: \.isWhitespace).count
```

### A2-named (Mojo)

```mojo
s.count_graphemes(); s.count_codepoints(); s.byte_length()
```

That's three explicit names. Mojo **reversed** its plan to make `len()`
count code points: "length in codepoints is a more specialized notion
of string length that is rarely the correct metric"
(modular Mojo/docs/site/releases/v0.25.1.md:286-300).

### Traps

| Version | Trap |
|---|---|
| A2-bytes as `len` | Fine, if every doc says bytes. Go, Rust and Mojo 1.0 all made `len` bytes and survived. Roc made `Str.len` a stub that returns a `LearnAboutStringsInRoc` tag (Str.roc:526). That's honest, but the user still needs some length. |
| A2-none | `count` is O(n), and spelled like an O(1) property. |
| graphemes count | Depends on the Unicode version (pinned, so deterministic per Ren release), and costs O(n). |
| Python `len` (code points) | 👩‍👩‍👧 is 5. Neither bytes nor what a user sees. |

**Verdict:** A2-views: `len()` is bytes, and graphemes are a cursor you
count. Every count is a different call, and only bytes is O(1).

---

## 12. Parsing an HTTP header

`Content-Type: text/html; charset=utf-8\r\n`. Header names are ASCII
tokens, compared case-insensitively. Values are bytes (RFC 9110 allows
obs-text, 0x80 to 0xFF), and are usually ASCII. Touches **A1**, **A2**,
**A3** and **A6**.

### Ren: parse `Bytes`, turn to `Str` only where it's text

```ren
type Header = { name: Str, value: Bytes }

fn header(line: Bytes, at: Int) -> Header ! HttpError =   // `at`: offset of `line` in the request
  let Some(colon) = line.index(':') else fail BadHeader(at)              // PROPOSAL: Bytes.index(byte)
  let name = try Str.from_utf8(line[0..colon]) orelse fail BadHeader(at)
  if not name.all_bytes(is_tchar) then fail BadHeader(at)                 // ASCII token
  Header { name: name.ascii_lower(), value: line[colon + 1..line.len()].trim() }  // PROPOSAL: Bytes.trim
```

- `name.ascii_lower()` happens **once, at parse**. After that, the
  header map is `Map<Str, Bytes>` with plain byte equality (A3-bytes).
  That's the same shape as `Username` in task 4.
- `trim` on `Bytes` trims ASCII space and tab, per the receiver rule from
  task 10.
- Getting text: `try Str.from_utf8(h.value)`, which fails with
  `InvalidUtf8(at)`, `at` relative to the value. The request parser,
  holding the request's base (A1c), adds it once.

### A1 for the error

| | `BadHeader(at)` means |
|---|---|
| A1a | offset in `line`. The caller must pass where `line` started, which this function's signature already does by hand. |
| A1b | offset in whatever root `line` is part of: the request buffer, or a leased chunk if the headers spanned reads. |
| A1c | `header` is given `line`, and the request cursor that produced it was made `from:` the connection's base, so `c.at()` before reading the line is the stream offset. The `at` parameter is that number. |

### A2 and A3

- **A3-canon** would make `"content-type" == "Content-Type".lower()`
  cost a normalization check per lookup, for pure ASCII. That's pure
  waste.
- **A2-bytes** (`s[i]` a byte) would be harmless here and convenient,
  since everything is ASCII. That's the strongest argument for
  A2-bytes, and it's answered by parsing `Bytes` instead, where `b.u8(i)`
  and `b.index(':')` are byte-native.

### Prior art: Rust `http` crate, the best version

```rust
let name = HeaderName::from_bytes(&line[..colon])?;     // validates the token, lowercases
let value = HeaderValue::from_bytes(trim(&line[colon+1..]))?;
let ct: &str = value.to_str()?;                           // fails on non-visible-ASCII
```

Names are normalized at construction, and values are bytes with a
fallible `to_str`. That's the same design as above. Go's
`textproto.CanonicalMIMEHeaderKey` normalizes to `Content-Type` casing.
Same idea, different canonical form.

### Traps

| Version | Trap |
|---|---|
| parsing headers as `Str` | A Latin-1 value (`filename=r\xE9sum\xE9.pdf`) fails the whole request at `from_utf8`, which a server mustn't do. Parse as `Bytes`. |
| Unicode `lower` on names | Wrong in theory (`K`, U+212A KELVIN SIGN, lowercases to `k`), and a smuggling vector. `ascii_lower` is the right one. |
| `trim` on `Str` used for HTTP | Unicode trim strips U+0085 and U+00A0, which HTTP doesn't. The `Bytes` receiver avoids it. |

**Verdict:** A2-views, A3-bytes, A6-strict, A1c. The task argues that
`Bytes` gets the search vocabulary (`index`, `split`, `trim`,
`starts_with`, `fields`) with ASCII meaning.

---

## 13. A stream of lines from a file

`for line in try &Fs.line_reader(path)` over a large file, with errors
that say `path:line` and the byte offset. It must be consistent with
streams.md as amended, where a library reader is a value cursor that
keeps its offset as data and reads with `pread` ("a file's reader keeps
its offset as data"). Touches **A1**, **A6** and **A7**.

### Ren (A1c: the reader *is* the value that says where it starts)

```ren
fn count_errors(path: Path) -> Int ! FsError | InvalidUtf8 uses Fs =
  var n = 0
  for line in try &Fs.line_reader(path)        // next: -> Option<Str> ! FsError | InvalidUtf8
    if line.starts_with("ERROR") then n += 1
  n
```

Inside the reader (stdlib, sketched):

```ren
pub type LineReader = opaque { path: Path, offset: Int, line: Int, buf: Bytes }
  // the next line, without its "\n" or "\r\n": a slice of the reader's chunk, or a
  // copy if it spans two. Not UTF-8: InvalidUtf8(at), at = the FILE offset.
  pub fn next(inout self) -> Option<Str> ! FsError | InvalidUtf8 uses Fs = ...
  pub fn line_no(self) -> Int = self.line     // PROPOSAL: for "path:line" messages
  pub fn at(self) -> Int = self.offset        // the file offset of the next line
```

The reader splits on `\n` in `Bytes`, then validates each line, so a
chunk boundary inside a character is never seen by the validator.
Lines are validated whole. The error's `at` is `self.offset + k`, which
is A1c: the cursor carries its base as data, exactly as amendments.md
asks resource cursors to do.

### A1a

The reader would report `InvalidUtf8(at)` relative to the line. The
user's loop has no file offset unless it keeps a running sum of
`line.len() + 1`, which is wrong for `\r\n`.

### A1b

The reader would report the offset in the leased chunk. Two adjacent
lines can report the same `at`.

### A7

`line` is a slice of a leased chunk. Keeping it past the loop body pins
the chunk (task 6). Streams' open question is exactly this. With
A7-store, putting a line in a `Map` compacts it. With A7-tiny, short
lines are free. Pushing whole lines into an `Array<Str>` still pins,
and the debug report names it.

### Prior art

- **Rust:** `BufReader::lines()` yields an owned `String` per line. That
  copies every line, and has no line number or offset.
  `read_until(b'\n', &mut buf)` reuses one buffer.
- **Go:** `bufio.Scanner`. `Bytes()` is valid only until the next `Scan`,
  which is a use-after-scan trap; `Text()` copies.
- **Python:** `for line in open(p)` decodes per chunk, and a
  `UnicodeDecodeError` reports a position relative to the chunk, not the
  file. That's A1b's trap in the wild.

### Traps

| Version | Trap |
|---|---|
| A1c reader | None found. The reader owns its offset and line number as data, which streams already require. |
| A1a | Offsets per line only. |
| A1b | Offsets per lease, which look plausible and are wrong. |
| Go `Bytes()` | Aliasing after the next scan. In Ren slices are values, so this trap can't happen. A kept slice pins instead. |

**Verdict:** A1c. It's consistent with streams' "resource state in the
service, ids and offsets in the cursor".

---

## 14. Nested format views reporting an error offset

A database file: 4 KB pages, each a slotted page (formats.md, "Arrays of
records in a page") whose slots point at records. A corrupt record must
be reported as `file offset 0x3A1F2C, page 929, slot 7, Record.name`.
Touches **A1**.

### A1c

```ren
fn check_page(file: Bytes, no: Int) ! FormatError =
  let base = no * 4096
  let page = file[base..base + 4096]
  let dir = try Directory.disk.view(page, from: base)              // PROPOSAL: from:
  for s in dir.slots
    let r = try Record.disk.view(page[s.off..s.off + s.len], from: base + s.off)
    ...
```

A nested format **inside one view** (`slots: Array<Slot.disk>[count]`,
`T.fmt` fields) needs nothing: the view machinery knows each field's
offset in the value it was given, and `path` names it
(`"Directory.slots[7]"`). `from:` is needed only where **the program**
cuts a slice and views it, because only the program knows where that
slice sits.

If the page was read alone (`Fs.read_at(f, base, 4096)`, not a slice of
`file`), the code is the same and so is the answer. That's the point:
the same program reports the same offset however the bytes got there.

### A1a

```ren
  let r = attempt Record.disk.view(page[s.off..s.off + s.len])
  match r
    Err(Malformed(at, p, why)) => fail Malformed(base + s.off + at, p, why)
    Err(Short(at, need)) => fail Short(base + s.off + at, need)
    Err(UnknownTag(at, t)) => fail UnknownTag(base + s.off + at, t)
    Ok(v) => ...
```

That's three arms at every manual nesting point.

### A1b

```ren
  let r = try Record.disk.view(page[s.off..s.off + s.len])  // `at` relative to the root
```

The result is correct **if** `file` was read whole as one root. It's
off by `base` if the page came from a page cache (each page its own
4 KB root). It's off by something else in `ren run` if the interpreter
copies slices. The caller can't tell which happened.

### Prior art

- **Rust nom:** errors carry the remaining input slice, and position is
  recovered by pointer subtraction against the original
  (`nom::Offset::offset`). That's A1b by address arithmetic, which Ren
  can't and won't do.
- **Haskell binary:** `runGetOrFail` returns a `ByteOffset` relative to
  the input given, which is A1a.
- **Kaitai:** `_io.pos` within the current substream, with a manual
  offset for absolute positions, which is A1a or A1c.
- **Lean 4 (2025):** `String.Slice.Pos` is a byte offset **relative to
  the slice** (`Slice.startPos` has `offset := 0`), with a proof it's at
  a char boundary (lean4 src/Init/Data/String/Defs.lean:541-557). A
  modern design chose value-relative positions on purpose.
- **Swift:** `Substring` indices are shared with the base `String`
  (A1b), and `String(sub)` resets them. Using an index from `sub` on
  the copy is a known trap. SE-0241 deprecated `encodedOffset` because
  it silently depended on the storage encoding: "the offset is therefore
  encoding-dependent" (swift-evolution 0241, Motivation). That's A1b's
  leak, found in production.

### Traps

| Version | Trap |
|---|---|
| A1a | Boilerplate per nesting point, and easy to get wrong for one variant. |
| A1b | Correct by coincidence, depending on how the buffer was obtained. Breaks "the interpreter and native builds agree on every observable behaviour". |
| A1c | Forgetting `from:` gives a page-relative offset. It's wrong, but the same everywhere, and the debug message says `at 12 (relative to the view)` so it reads as relative. |

**Verdict:** A1c. `from:` lives on exactly the two things that make
positions: `b.cursor(from:)` and `T.fmt.view(b, from:)`. Errors are
then right without shifting.

---

## 15. `Map<Str, _>` with keys from user input

A tag system: users type tags, and `café` typed on macOS (NFD, from
some input paths) and on Windows (NFC) must be one tag. Touches **A3**:
equality, hash, ordering and sorting.

### A3-bytes (keys as typed)

```ren
var tags: Map<Str, Int> = Map.empty
&tags.set(input, tags.get(input).unwrap_or(0) + 1)
// "café" and "café" are two tags, shown identically. Silent.
```

### A3-bytes+nfc: normalize at the boundary, into a type

```ren
pub type Tag = opaque Str
  pub fn parse(s: Str) -> Tag ! Invalid =
    let t = s.trim().nfc()                        // PROPOSAL: nfc; fast path if already NFC
    if t.len() == 0 || t.len() > 50 then fail Invalid else t

var tags: Map<Tag, Int> = Map.empty
let t = try Tag.parse(input)
&tags.set(t, tags.get(t).unwrap_or(0) + 1)
let sorted = tags.keys().sort()                   // byte order = code point order, of NFC
```

`==`, `hash` and `<` on `Tag` are its representation's, which is
already normalized. Each costs what it costs on `Str`: a `memcmp` and
a wyhash. Normalization is paid once per input.

Alternatively, through `key`, if the original spelling must be kept:

```ren
pub type Tag = opaque Str
  pub fn key(self) -> Str = self.nfc()     // runs on EVERY hash and ==: allocates per lookup
```

That's correct, but each map lookup normalizes. The `parse` form is
right. The `key` form is the trap, and the docs should say so.

### A3-canon (Swift-style `==`)

```ren
var tags: Map<Str, Int> = Map.empty   // == and hash are canonical: one tag, no code
```

It works with no code, and here is what it does to the rest of the
language:

1. **`a == b` but `a.bytes() != b.bytes()`.** `a.len() != b.len()`, and
   `a[0..4] != b[0..4]`. Equal values with different lengths and
   different slices break "a slice is a value like any other". Value
   semantics on `Str` and `Bytes` disagree, and `Str.from_utf8(x) ==
   Str.from_utf8(y)` doesn't imply `x == y`.
2. **Hash must normalize.** Swift's `String` hashing normalizes to NFC
   (the fast path when already NFC). Every `Map<Str, _>` lookup pays a
   normalization check. bench/native/maps measured Ren at 0.69× of
   Rust's cycles with byte hashing (compiler.md, Bytes stage step 3);
   canonical hashing gives part of that back on every non-ASCII key.
3. **Determinism.** `==` itself would depend on the Unicode version.
   Ren pins its tables, so it's deterministic per release, but a journal
   recorded under Ren N could replay differently under Ren N+1 for
   strings with code points that were unassigned in N (normalization is
   stable only for assigned code points). With A3-bytes, only the
   explicit `nfc()` calls move, and they're visible.
4. **Protocols.** HTTP header names, JSON object keys, file names and
   SQL identifiers are byte-compared by their specs. JSON (RFC 8259
   §8.3) compares member names code unit by code unit. Under A3-canon
   every one of those needs a "byte equals" escape, so the protocol
   world writes `a.bytes() == b.bytes()` everywhere.
5. **Sorting.** Swift sorts `String` by NFC code points, so the order
   isn't the order of the stored bytes. A sorted file of keys written
   by Ren, read by `sort(1)`, or merged against bytes from disk
   disagrees.

### Prior art

- **Swift:** canonical `==`, `<`, `hash`, the only mainstream language
  with it. SE-0363 notes it's "fairly novel" and that "the vast
  majority of other languages and engines are not capable of comparing
  with canonical equivalence" (swift-evolution 0363:59-101). SE-0464's
  `UTF8Span` offers **both** byte and canonical comparison by name
  (0464:433-471), which is Swift itself conceding that byte equality is
  needed beside canonical.
- **Erlang:** byte equality, and `string:equal(A, B, IgnoreCase, Norm)`
  explicit.
- **Rust, Go, Python, Java:** byte or code point equality, with
  normalization a library call.

### Traps

| Version | Trap |
|---|---|
| A3-bytes, keys as typed | **Silent duplicate keys.** Rare in practice: most input methods produce NFC, macOS file names were NFD on HFS+, and copy-paste from PDFs produces NFD. |
| A3-bytes+nfc, normalized at parse | You have to know to do it. The cure is the opaque-type pattern, which Ren already uses for `Email`, plus an advice in `ren review` ("a `Map<Str, _>` keyed by user input"). |
| `key` that normalizes | Allocation per lookup. |
| A3-canon | Points 1 to 5 above. Equality stops being structural, which Ren's derived equality (operators.md) is built on. |

**Verdict:** A3-bytes+nfc. `==`, `hash` and `<` on `Str` are bytes,
which is code point order (operators.md already says so). Normalization
is an explicit call, made once, at the boundary, into an opaque type.

---

## 16. Truncating a log line to a byte budget

Each log record's message is capped at 1024 bytes for the wire, so it's
a budget in **bytes**, not characters. Touches **A4**.

### A4-panic

```ren
let msg = if m.len() > 1024 then m[0..1024] else m    // panics if byte 1024 is inside a char
```

### A4-round

```ren
let msg = if m.len() > 1024 then m[0..1024] else m    // silently 1022 bytes: correct here
```

### A4-panic+floor

```ren
let msg = m[0..m.char_floor(1024)]                     // PROPOSAL: largest boundary ≤ 1024
// (char_floor(i) of i ≥ len is len, so no `if` is needed)
```

### Decision 17 check

decision 17 says: "A `Str` slice panics if it cuts a character. The
slices `split`, `index`, `trim` and `lines` make are at boundaries they
found, and don't check." It holds:

- Every slice the library makes (`split`, `trim`, `lines`, `fields`,
  `graphemes`, `chars` with offsets) is at a found boundary. No check
  is needed, so no panic is possible.
- A computed limit (`1024`, `80`) is the only way to reach the panic,
  and `char_floor` is the one explicit way to make a computed limit
  safe. The panic message's help names it:

```
panic: slice 0 to 1024 ends inside a character (bytes 1022..1025 are 'é…')
  ┌─ log.ren:4:13
  = help: to cut at most 1024 bytes, `m[0..m.char_floor(1024)]`
```

- **A4-round** would mean `s[a..b].len()` may not be `b - a`, which is
  a silent change of meaning for every slice. It also hides real bugs,
  where an offset was computed from the wrong string. A2-bytes users in
  Go get this silently: `s[:1024]` produces invalid UTF-8.

### Grapheme cuts

`char_floor` can cut a grapheme (`e` | U+0301, a ZWJ family). That gives
valid UTF-8 and a different visible character. For a log line that's
acceptable. For display, use task 3's graphemes. Panicking on grapheme
cuts was considered and rejected: it would make slicing depend on the
Unicode version and on context, which is O(n) worst case.

### Prior art

- **Rust:** `&s[..1024]` panics ("byte index 1024 is not a char
  boundary"), and `s.floor_char_boundary(1024)` was stabilized in
  1.91.0 (2025). That's exactly A4-panic+floor, reached after years of
  people writing it by hand.
- **Mojo 0.26.2:** "Subscripting into `String` and `StringSlice` will
  now panic if the index falls in the middle of a UTF-8 encoded
  codepoint. Previously they would return invalid UTF-8. This panic is
  unconditional" (v0.26.2.md:680-684). Mojo **moved to** A4-panic.
- **Go:** `s[:1024]` silently yields invalid UTF-8.
- **Swift:** no integer index, so the question doesn't arise. The cost
  is `s.utf8.prefix(1024)`, followed by a repair.

**Verdict:** A4-panic+floor. Decision 17 holds unchanged, and adds one
method.

---

## 17. Paths, arguments and environment (bonus, for A6)

List a directory and print each file name, including names that aren't
UTF-8 (Latin-1 files on an old ext4 volume). Read `HOME` and the
program's arguments.

### A6-os, proposed

```ren
fn list(dir: Path) ! FsError uses Fs, Console =
  for p in try Fs.list(dir)                      // PROPOSAL: Fs.list -> Array<Path>
    Console.write("{p}")                          // show: lossy, escaped: "r\xE9sum\xE9.txt"
    match attempt p.name().to_str()               // PROPOSAL: Path.to_str ! InvalidUtf8
      Ok(s) => index(s)
      Err(_) => skip_with_warning(p)              // the program chooses
```

- **`Path` becomes `opaque Bytes`**, not `opaque Str` as in
  prelude.ml:601 today. Unix names are any bytes except `/` and NUL.
  Windows names are WTF-16, held as WTF-8 (Rust's `OsString`
  representation on Windows; Zig's `std.unicode.wtf8`). Joining,
  comparing and opening never decode. Only showing and `to_str` do.
- `Path.of(s: Str)` stays (from text, always valid). `p.show()` is a
  deterministic lossy form with `\xNN` escapes, so a log is
  unambiguous.
- **Args and env:** `Os.args() -> Array<Str>` and `Os.env(name: Str) ->
  Option<Str>`, with each failing `! NotUtf8(index: Int)` (args) or `!
  NotUtf8(name: Str)` (env) when one isn't UTF-8. Raw forms
  `Os.raw_args() -> Array<Bytes>` and `Os.raw_env(name) ->
  Option<Bytes>` exist for tools that pass paths through. `cli` reads a
  `Path` field from the raw form, so `mytool ./r\xE9sum\xE9.txt` works.

### Prior art

- **Rust:** `OsStr`/`OsString` and `Path`, with `env::args()`
  **panicking** on non-UTF-8 and `env::args_os()` raw. Typed, but it
  adds two types.
- **Python:** PEP 383 surrogateescape makes paths `str` that round-trip.
  That's a lie in the type (task 9).
- **Go:** strings are bytes, so it just works, and nothing is validated
  (also task 9).
- **Zig:** everything is `[]const u8`, with WTF-8 on Windows.

### Traps

| Version | Trap |
|---|---|
| `Path = opaque Str` (today) | A non-UTF-8 name **can't be represented**. `Fs.list` must skip it, fail, or go lossy, and a lossy name can't be opened again. That's a correctness bug for a backup tool. |
| Rust's panic in `args()` | A crash on an unusual file name passed as an argument. Ren fails with a typed error instead. |
| `Path = opaque Bytes` | `"{p}"` is lossy. Must be documented: "show is for people". |

**Verdict:** A6-strict for `Str`. `Path` over `Bytes`. Args and env are
`Str` with a typed failure, plus raw forms. No `OsStr` type: `Bytes` is
already "any bytes".

---

## Per-question table

**Which candidate each task favours, and why.** "—" means the task
doesn't discriminate.

### A1: positions

| Task | A1a value-only | A1b root | A1c value + base | Why |
|---|---|---|---|---|
| 1 framing | works, shifts every error variant by hand | **wrong**: offset in lease or joined buffer | **best** | the stream offset exists only where the program says where the buffer starts |
| 2 CSV line:col | **tie** | right only for one call shape | **tie** | `line_col` is asked of the text holding the offset |
| 9 file not UTF-8 | — | — | — | the offset of `from_utf8` is in the bytes given, either way |
| 12 HTTP header | works, `at` passed by hand | offset in whichever chunk | **best** | the request cursor carries the base |
| 13 lines | per-line only | **wrong**: per lease | **best** | the reader keeps its file offset as data, as streams requires |
| 14 nested views | 3 arms per nesting point | correct only if read as one root | **best** | `from:` at the program's own slice points |
| 6 keys (A7-store) | unobservable | **observable**: compaction moves offsets | unobservable | A1b turns a runtime optimisation into a behaviour |

**Recommendation: A1c.** A1a is what's built today (`ByteCursor.at()`,
bench/bytes/cursor.ren). A1c adds `from:` to `b.cursor` and
`T.fmt.view`, and `ByteCursor.sub(n)` (a cursor over the next `n` bytes
that counts on from this one), so formats nested by hand keep the base
with no arithmetic. formats.md's "Errors carry offsets" changes from "in
the whole buffer, at no cost" to "in the value given, counted from
`from:`". A1b is rejected. It leaks representation (copy, reallocation,
leases, interpreter copies), it's false for sockets, and it would make
A7-store observable.

### A2: what `len` and indexing mean

| Task | A2-bytes (`s[i]` byte) | A2-none (Swift) | A2-views | A2-named (Mojo) | Why |
|---|---|---|---|---|---|
| 2 CSV | convenient, mis-reads non-ASCII | heavy for a byte-level parser | **best**: `text.bytes().u8(i)`, free | `s[byte=i]` fine | parsers want bytes, text wants found boundaries |
| 3 truncate | **panics or cuts emoji** | best one-liner | **best**: graphemes cursor | correct, O(n) hidden in `[]` | grapheme work should look like O(n) work |
| 5 slugify | **drops letters** | fine | **best** | fine | needs chars, `nfkd`, `fold` |
| 10 whitespace | — | — | **best**: `fields()` per receiver | — | the type picks Unicode or ASCII |
| 11 counts | `len` bytes ok | `count` O(n) looks O(1) | **best**: every count a different call | best-equal | Mojo reverted `len` to bytes |
| 12 HTTP | harmless | heavy | **best** (parse `Bytes`) | fine | protocols are bytes |
| 16 byte budget | silently invalid (Go) | needs a repair | **best** with `char_floor` | fine | |

**Recommendation: A2-views.** `s.len()` is bytes, O(1). `s[a..b]` is a
byte range. `s[i]` is a **compile error** whose help lists
`s.bytes().u8(i)`, `s[i..j]`, `s.chars()` and `s.graphemes()`.
`chars()` and `graphemes()` are cursors yielding `Char` and `Str`
slices, with `for at, x in` giving byte offsets. Counting is
`.count()` on the cursor. A2-named was the closest rival. It's
consistent, but it puts O(n) grapheme scanning behind `[]` and adds a
keyword-subscript form Ren doesn't otherwise have.

### A3: equality and normalization

| Task | A3-bytes | A3-canon | A3-bytes+nfc | Why |
|---|---|---|---|---|
| 4 username | wrong silently (`ß`, NFD, fullwidth) | fixes only NFD | **best**: `nfkc_fold` at parse | identity needs folding, which canon doesn't give |
| 12 HTTP | **best** | waste per lookup | = bytes | specs compare bytes |
| 15 tag map | silent duplicates | works with no code; breaks slices, hash cost, sort order, replay | **best**: `Tag.parse` normalizes once | normalize once, compare bytes forever |
| 7 JSON | **best** | wrong for RFC 8259 keys | = bytes | |

**Recommendation: A3-bytes+nfc.** `==`, `hash` and `<` are bytes, which
is code point order. Normalization and folding are explicit:
`nfc()`, `nfd()`, `nfkc()`, `nfkd()`, `fold()` and `nfkc_fold()`, plus
`is_nfc()` as a fast check. They're applied once, into an opaque type.
Prefer the opaque-type constructor over a `key` that normalizes, and
let `ren review` advise on `Map<Str, _>` keyed by user input. Human
sorting (collation, UCA) is a library in std.x, not `<`.

### A4: a slice that cuts a character

| Task | A4-panic | A4-round | A4-panic+floor | Why |
|---|---|---|---|---|
| 3 truncate | never reached (found boundaries) | — | — | |
| 5 slugify | — | — | `char_floor` for the 80 | |
| 16 byte budget | panics on real data | correct but silently changes `b - a` | **best** | an explicit floor for computed limits |

**Recommendation: A4-panic+floor.** Decision 17 holds unchanged, adding
`s.char_floor(i)` and `s.is_char_boundary(i)`, and the panic's help
names `char_floor`. Grapheme cuts never panic.

### A5: building strings

| Task | A5-plus | A5-builder | A5-iolist | A5-interp | Why |
|---|---|---|---|---|---|
| 5 slugify | **best** (`+=` in place) | ceremony | — | — | loops append |
| 7 JSON | fine with `json.quote` | — | runtime concern | **injection** | structured formats go through libraries or tagged templates |
| 8 template | verbose | — | — | **best** | text with holes |
| 1 framing | `buf = rest + got` | — | — | — | quadratic across spans, which `Net.frames` fixes |

**Recommendation:** interpolation for text with holes. `+`/`+=` for
loops (Str + Str, Str + Char), in place when unique. `xs.join(sep)` for
lists. Tagged templates (`json"..."`, `sql"..."`, `html"..."`) for
structured formats, as the library's own escaping. **No builder type.
No iolist type:** writing an `Array<Bytes>` with `writev` is a runtime
choice Track B (B3) measures. `concat` goes, since `+` replaces it
(operators.md: one name each). Two gavels remain: `{x}` or `${x}`, and
a debug report for `+=` on a shared `Str` inside a loop.

### A6: the `Str`/`Bytes` boundary

| Task | A6-strict | A6-lossy | A6-os | Why |
|---|---|---|---|---|
| 9 not UTF-8 | **best**, needs `at` | by name only | — | silent loss must be chosen |
| 12 HTTP | **best**: parse `Bytes`, `from_utf8` at the edge | — | — | |
| 13 lines | per-line validation with file offset | — | — | |
| 17 paths | — | `show` only | **`Path` over `Bytes`**, args and env `Str` with typed failure, plus raw forms | non-UTF-8 names must round-trip |

**Recommendation:** `s.bytes()` is free (a slice of the same buffer).
`Str.from_utf8(b) -> Str ! InvalidUtf8(at: Int)` is value-relative.
`Str.from_utf8_lossy(b)` uses pinned maximal-subpart U+FFFD. `Path =
opaque Bytes`. `Os.args` and `Os.env` are `Str` with typed failures,
plus `raw_args` and `raw_env`. No `OsStr`. No surrogateescape. Other
encodings (Latin-1, UTF-16) go in a library.

### A7: retention as programmers feel it

| Task | A7-manual | A7-tiny | A7-store | Why |
|---|---|---|---|---|
| 6 10k keys | `.copy()` or 640 MB to 1 GB pinned | **free** for keys ≤ 15 bytes | **free** for any key in a `Map`/`Set` | |
| 1 frames | `.copy()` the body | small bodies free | free if stored in a map | |
| 13 lines | pins leases | short lines free | lines in a map free | lines in an array still pin |

**Recommendation: all three.** Representation B (inline small strings)
removes tiny slices' roots. `Map`/`Set` insertion compacts a slice whose
root is much larger (a ratio and a floor, which Track B tunes). `copy()`
plus the debug report covers records in arrays. All of this is
unobservable under A1a or A1c, which is a second reason A1b is out.
**Would a user think about `copy()`?** Only when keeping many mid-sized
slices in records or arrays of a large input, where the debug report
tells them. Never for map keys, and never for small strings.

---

## The `Str` API that falls out

Signatures in Ren's style. ✓ means it exists today, ✎ means it changes,
and ✚ means it's new (a proposal). "Found" means at a boundary the
method found, so it never panics.

### Measuring and positions

| | Signature | Meaning |
|---|---|---|
| ✓ | `s.len() -> Int` | bytes, O(1) |
| ✓ | `s[a..b] -> Str` | byte range, a slice. Panics on a cut char (decision 17) |
| ✚ | `s[i]` | **compile error**, whose help names `s.bytes().u8(i)`, `s[i..j]`, `chars()`, `graphemes()` |
| ✚ | `s.is_char_boundary(i: Int) -> Bool` | |
| ✚ | `s.char_floor(i: Int) -> Int` | the largest boundary ≤ `i`, clamped to `len` |
| ✚ | `s.line_col(at: Int) -> (Int, Int)` | 1-based line, and column in chars, for the offset `at` in `s` |

### Views (cursors; `for at, x in` gives byte offsets in `s`)

| | Signature | Meaning |
|---|---|---|
| ✚ | `s.chars() -> Chars` | a cursor of `Char`, code points. Version-free |
| ✚ | `s.graphemes() -> Graphemes` | a cursor of `Str` slices, UAX #29 extended grapheme clusters, pinned Unicode |
| ✓ | `s.bytes() -> Bytes` | free, the same buffer |
| ✚ | `Chars.count() / Graphemes.count() -> Int` | the streams sink, O(n) |

### Searching and splitting (results are found slices)

| | Signature | Meaning |
|---|---|---|
| ✓ | `s.index(t: Str) -> Option<Int>` | the first byte offset of `t` |
| ✚ | `s.last_index(t: Str) -> Option<Int>` | |
| ✚ | `s.includes(t: Str) -> Bool` | Array's name (operators.md) |
| ✓ | `s.starts_with(t: Str) -> Bool` | |
| ✚ | `s.ends_with(t: Str) -> Bool` | |
| ✚ | `s.strip_prefix(t: Str) -> Option<Str>` / `s.strip_suffix(t)` | for `let Some(rest) = ... else` |
| ✓ | `s.split(sep: Str) -> Array<Str>` | |
| ✚ | `s.split_once(sep: Str) -> Option<(Str, Str)>` | headers, `key=value` |
| ✚ | `s.lines() -> Array<Str>` | without `\n` or `\r\n` |
| ✚ | `s.fields() -> Array<Str>` | split on Unicode White_Space, empty parts dropped |
| ✓✎ | `s.trim() -> Str` | Unicode White_Space (today: spaces, tabs, newlines) |
| ✚ | `s.trim_start() / s.trim_end() -> Str` | |
| ✚ | `s.replace(from: Str, to: Str) -> Str` | all occurrences |

### Case, normalization and classification (pinned Unicode tables)

| | Signature | Meaning |
|---|---|---|
| ✓✎ | `s.lower() / s.upper() -> Str` | **Unicode** default case conversion, locale-free. For display. Today `lower` is ASCII |
| ✚ | `s.ascii_lower() / s.ascii_upper() -> Str` | for protocols and identifiers known to be ASCII |
| ✚ | `s.fold() -> Str` | full case folding (CaseFolding C+F), for caseless matching |
| ✚ | `s.nfc() / s.nfd() / s.nfkc() / s.nfkd() -> Str` | normalization. Returns `s` itself (no copy) when already in that form |
| ✚ | `s.is_nfc() -> Bool` | the quick check |
| ✚ | `s.nfkc_fold() -> Str` | Unicode's toNFKC_Casefold, the identity key for usernames and tags |
| ✚ | `Char`: `c.is_whitespace()`, `is_alphabetic()`, `is_numeric()`, `is_alphanumeric()`, `is_mark()`, `is_ascii()`, `is_ascii_alphanumeric()`, `c.code() -> Int`, `Char.of(code: Int) -> Option<Char>`, `c.len() -> Int` (UTF-8 bytes) | |

### Building

| | Signature | Meaning |
|---|---|---|
| ✚ | `"text {expr} text"` | interpolation through `show`. `{x}` or `${x}` is a gavel |
| ✚ | `a + b`, `s + c` (`Str.add(Str)`, `Str.add(Char)`), and `s += t` | appends in place when `s` is unique (Perceus), amortized O(1) |
| ✎ | `s.concat(t)` | removed, `+` replaces it |
| ✚ | `xs.join(sep: Str) -> Str` on `Array<Str>` | |
| ✚ | `s.repeat(n: Int) -> Str` | |
| ✚ | `s.pad_start(width: Int) / s.pad_end(width: Int) -> Str` | width in chars. Terminal columns belong in a terminal library |
| ✚ | `json"..."`, `sql"..."`, `html"..."` | tagged templates: the parts go to a library that escapes them (stdlib.md, open question) |

### The boundary

| | Signature | Meaning |
|---|---|---|
| ✓ | `s.bytes() -> Bytes` | free |
| ✓✎ | `Str.from_utf8(b: Bytes) -> Str ! InvalidUtf8(at: Int)` | `at` is the first invalid byte, relative to `b` |
| ✚ | `Str.from_utf8_lossy(b: Bytes) -> Str` | U+FFFD per maximal subpart, pinned |
| ✓ | `s.copy() -> Str` | its own buffer, free on an owner |
| ✎ | `Path = opaque Bytes` | `Path.of(s: Str)`, `p.to_str() -> Str ! InvalidUtf8(at: Int)`, lossy `show` with `\xNN` |
| ✚ | `Os.args() -> Array<Str> ! NotUtf8(index: Int)`, `Os.raw_args() -> Array<Bytes>` | |
| ✚ | `Os.env(name: Str) -> Option<Str> ! NotUtf8(name: Str)`, `Os.raw_env(name: Str) -> Option<Bytes>` | |

### `Bytes` gets the search vocabulary, with ASCII meaning

| | Signature | Meaning |
|---|---|---|
| ✚ | `b.index(x: Bytes) -> Option<Int>`, `b.split(sep: Bytes) -> Array<Bytes>`, `b.split_once(sep: Bytes) -> Option<(Bytes, Bytes)>`, `b.starts_with(x: Bytes)`, `b.ends_with(x: Bytes)` | |
| ✚ | `b.trim() -> Bytes`, `b.fields() -> Array<Bytes>`, `b.lines() -> Array<Bytes>` | ASCII whitespace only (SP, HT, CR, LF, FF, VT): the receiver picks |
| ✚ | `b.ascii_lower() -> Bytes` | |

### Positions, layer 3 and formats (A1c)

| | Signature | Meaning |
|---|---|---|
| ✎ | `b.cursor(from: Int = 0) -> ByteCursor` | `c.at()` = `from` + bytes read. Errors' `at` too |
| ✚ | `try &c.sub(n: Int) -> ByteCursor ! FormatError` | a cursor over the next `n` bytes, counting on from `c.at()` |
| ✎ | `T.fmt.view(b: Bytes, from: Int = 0) -> View ! FormatError` | `at` in errors = `from` + the offset in `b` |
| ✚ | `Net.frames(conn, T.fmt)`, `Fs.line_reader(p)` | library cursors that carry their own base as data (streams amendments) |

### Open interactions to settle with the gavels

1. **Char literals.** formats.md uses `'Q'` as a byte tag in `case`
   arms. If `'a'` is a `Char`, then a `case` on a `UInt8` field takes an
   ASCII `Char` literal as its byte, and `b.u8(i) == 'a'` needs the same
   rule. Alternatively, Roc's way, where `'a'` is an `Int` literal (its
   code point) and `Char` has no literal (`Char.of(…)`). Roc's is
   simpler, and loses `c.is_alphabetic()` on literals.
2. **Interpolation's hole syntax**, `{x}` against `${x}`, and whether
   every string literal interpolates (Roc, Swift) or only prefixed ones
   (Python's `f"`).
3. **`lines`, `fields` and `split` return arrays, while `chars` and
   `graphemes` return cursors.** That's consistent with today's `split`.
   If streams' pipelines land, lazy segmenters could follow, as
   `s.cursor_lines()` or by the receiver rule. Not needed now.
4. **The Unicode version** is pinned per Ren release (stdlib.md). A
   journal recorded on release N and replayed on N+1 can differ in
   `graphemes`, `fold`, `nfkc_fold` and `lower` for newly assigned
   code points. The journal header should record the Unicode version,
   as it records shape hashes (formats.md, Layer 1), and replay should
   refuse a mismatch with a clear message.

## Sources

Local clones in /tmp/ren-refs:

- **Roc:**
  `roc-rust/crates/compiler/builtins/roc/Str.roc`. `len` is a stub
  returning `LearnAboutStringsInRoc` (526). Also `from_utf8` with an
  index (540-550), `from_utf8_lossy` (342), the ASCII case functions
  and the Unicode package rationale (1340-1423), interpolation `${}`
  (31-50), and in-place `concat`/`reserve` (409, 435, 493).
- **Swift Evolution:** 0180 (index overhaul, rounding left to later,
  186), 0241 (`encodedOffset` deprecated as encoding-dependent, 10-30),
  0363 (canonical equivalence "fairly novel", 59-101), 0405 (validating
  initializers), 0464 (`UTF8Span`, byte and canonical comparison side by
  side, 433-471).
- **Lean 4:** `src/Init/Data/String/Defs.lean:428-557`, `String.Slice`
  and slice-relative `Slice.Pos`, and `Lossy.lean`.
- **Mojo:** `modular/Mojo/docs/site/releases/`. `v0.25.1.md:278-300`
  (`len` returned to bytes), `v0.26.2.md:680-716` (panic on a cut
  codepoint, `s[byte=a:b]`), `v1.0.0b1.md:555-570` and
  `v1.0.0b2.md:28-40, 538-550` (`[codepoint=]`, `[grapheme=]`, O(n)),
  `v1.0.0.md:630-645, 1128-1137`.
- **Erlang/OTP:** `lib/stdlib/src/binary.erl:637-690`
  (`referenced_byte_size` and the hand-written `store` with `copy`), and
  `lib/stdlib/src/string.erl:243-299` (graphemes as `length`, `equal`
  with case and normalization options).

Web:

- Rust `str::floor_char_boundary`, stable in 1.91.0:
  https://doc.rust-lang.org/std/primitive.str.html#method.floor_char_boundary
- Rust `Utf8Error::valid_up_to`, `error_len`:
  https://doc.rust-lang.org/std/str/struct.Utf8Error.html
- Go `strings.Fields`, `strings.EqualFold`, `strings.Clone`, `bufio.Scanner`:
  https://pkg.go.dev/strings, https://pkg.go.dev/bufio
- RFC 8265, PRECIS usernames: https://www.rfc-editor.org/rfc/rfc8265
- RFC 9110 §5.5 (field values, obs-text) and RFC 8259 §8.3 (JSON string comparison).
- Unicode: UAX #15 (normalization and its stability policy), UAX #29
  (grapheme clusters), UAX #44 (`NFKC_Casefold`), UTS #39
  (confusables), Unicode §3.9 (U+FFFD substitution of maximal subparts).
- Python PEP 383 (surrogateescape), PEP 750 (t-strings).

Ren: foundations.md (the bet, decisions 14, 15, 17, 19), formats.md
("Errors carry offsets", layer 3), stdlib.md (cursors, slices, layer 3,
`x.hash()`), operators.md (equality, `key`, ordering by bytes, slices),
compiler.md "Bytes stage" (the maps kernel at 0.69× of Rust's cycles),
lib/core/prelude.ml:380-560 (`ByteCursor`, value-relative `at`),
bench/bytes/cursor.ren, lib/eval/builtins.ml:294 (ASCII `lower`),
streams.md and scratchpad/streams/amendments.md.

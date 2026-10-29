# Strings, track A: the ethos and coherence judge

I judged track-a/programs.md against Ren's decided documents: foundations.md
(the bet, decisions 11, 14, 15, 16, 17 and 19), operators.md, formats.md,
stdlib.md, errors.md and compiler.md ("Bytes stage"). I also checked it
against the streams draft as amended (scratchpad/streams/amendments.md),
and against prior-art.md where the two disagree. I verified the claims
the programs make about today's code. `ByteCursor.at()` is "where it is, in
the bytes it was made from" (lib/core/prelude.ml:426). `Path = opaque Str`
(prelude.ml:601). `lower` is `Char.lowercase_ascii` (lib/eval/builtins.ml:294).
`trim` is OCaml's `String.trim` (builtins.ml:682). All four claims hold.

The yardstick, in the owner's terms:
- explicit over magic;
- no observable representation;
- the interpreter and native builds agree;
- determinism and replay;
- complexity in the compiler, not the user;
- crisp scope, with one obvious way.

## Verdicts

| Q | Track A's pick | My verdict | Why, in one line |
|---|---|---|---|
| A1 positions | A1c | **A1c, agreed.** Spell the base without adding default arguments to the language | It's the only option the interpreter can implement truthfully. A1b is already broken in the build (compiler.md). |
| A2 `len`/index | A2-views | **A2-views, agreed.** Keep `len` = bytes, against prior-art.md's "no bare `len`". Drop `for at, x in s.graphemes()` | Ren has one position unit, and `len` is the end of the range `s[a..b]` takes. An offset yielded by `for i, x` would clash with decision 16 |
| A3 equality | A3-bytes+nfc | **A3-bytes+nfc, agreed.** Move every table-reading function into the `unicode` module. Cut `fold`, `nfkc`, `is_nfc` | `x.hash()` is unseeded and journaled, so `==` must not depend on table versions. stdlib.md already puts normalization in `unicode` |
| A4 cut char | A4-panic+floor | **A4-panic+floor, agreed.** Cut `is_char_boundary` | Decision 17 is unchanged. One method for computed limits |
| A5 building | interp + `+=` + `join`, no builder, no iolist | **Agreed.** Use `{x}`, not `${x}`. Tagged templates stay where stdlib.md already has them, out of this doc | The one case where `{` hurts is building JSON by hand, which the design says not to do |
| A6 boundary | strict + named lossy + `Path` over `Bytes` | **Agreed, with one bug fixed.** The `NotUtf8` tag has two shapes | errors.md: one error set can't hold two shapes of one tag |
| A7 retention | all three (manual + tiny + store) | **Manual + tiny. Reject A7-store** | It is the "copy found behind your back" the streams amendments reject (decision 12 there). It's a second rule that covers only `Map`/`Set`, and a tuning knob |

The biggest coherence finding cuts across A2, A3 and A6. **`Str`'s
methods should be exactly the ones that don't depend on the Unicode
version.** Everything that reads a Unicode table belongs in the `unicode`
module, which stdlib.md already lists:

> `` | `unicode` (normalization, graphemes, case) | std | determinism: tables pinned to one Unicode version | ``

That gives one crisp, checkable rule. It shrinks the `Str` surface by
about a third. It makes the version dependency visible at the call site.
And because dispatch is static over a closed world (decision 4), the
compiler knows whether a program reaches `unicode` at all. That makes the
journal rule exact (see A3).

---

## A1: positions

**Verdict: A1c.** A position is a byte offset into the value you hold. A
program that wants a stream or file position says where its value starts.

**Ethos.**
- **A1b fails the bet.** It makes the root's identity observable, and
  "the programmer never holds an address, so representation is the
  compiler's choice" forbids that. `copy()`, reallocation on append,
  leased chunks and A7-tiny would all change an error's `at`.
- **A1b also fails interpreter/native agreement, and that's already on
  record.** compiler.md, "Where it differs from formats.md", says:
  > "The interpreter's `Bytes` keep no root (a slice is a copy there), so
  > the offset in the root isn't known in both builds"

  So A1b isn't a design that could be built carefully. The interpreter
  rules it out.
- **A1a is honest.** But it pushes per-variant offset shifting onto every
  nesting point, which is complexity left with the user. A1c puts the
  base in two constructors and nowhere else.

**Coherence.**
- **Formats.** `view` and the layer 3 cursor are the only two things that
  make positions, so they're the only two that take a base. Nested
  formats inside one view need nothing (task 14 has this right).
- **Streams.** The amendments' rule "ids and offsets in the cursor" is A1c
  for resources. `Fs.line_reader` and `Net.frames` keep their base as
  data. A1c and the amendments are the same idea at two scales.
- **Journal.** An error's `at` is a value that can be journaled. Under
  A1c it's the same in `ren run` and native. Under A1b a replayed
  failure could differ.
- **A7-tiny depends on it.** Inline small slices are invisible only if
  positions are value-relative. A1c is what keeps representation B legal.

**Conflict: the proposed spelling adds a language feature.**
`b.cursor(from: Int = 0)` and `T.fmt.view(b, from: Int = 0)` need labelled
arguments with defaults on functions. Ren doesn't have them: language.md
lists labels for constructors only (line 270). Strings shouldn't be the
reason default arguments enter the language. Two options:
- a second name, such as `b.cursor_from(base)` and `T.fmt.view_from(b,
  base)`;
- or settle labelled call arguments separately first. stdlib.md's
  `retry(5, on: Declined)` already assumes them.

I'd take the second name now, and leave the label question to its own
gavel.

**Cut `ByteCursor.sub(n)`.** It's three lines of sugar:
`let at = c.at()`, then `let b = try &c.bytes(n)`, then
`b.cursor_from(at)`. It also adds a second way to make a based cursor.
Bring it back if real nested-format programs repeat that pattern.

**Keep these rules of A1c:**
- Plain functions stay value-relative and take no base:
  `Str.from_utf8 ! InvalidUtf8(at)`, `line_col(at)`.
- Only the two things that make positions take one.
- A library cursor that knows its base adds it once (the line reader,
  `Net.frames`).

**Doc text that must change.**
- foundations.md, decision 19:
  > "**Offsets are free in errors.** A slice is a root and a range, so a
  > malformed field's offset is reported within the whole buffer, the
  > file's or the socket's, at no cost."

  Should become: offsets count from the start of the value given to
  `view`, or from the base it was given.
- formats.md, "Errors carry offsets":
  > "**`at` is the offset in the whole buffer,** the file or the socket's,
  > not just the slice the view was made from, because a slice is a root
  > and a range. That's free, and Erlang can't do it."

  Rewrite it the same way. "Erlang can't do it" is also wrong on the
  facts: Erlang has the offset and deliberately hides it (prior-art.md
  §1, OTP).
- compiler.md, "Where it differs from formats.md":
  > "Layer 2's views, which carry their root, are where the promise is
  > kept."

  This promise goes. The section stops being a difference and becomes
  the rule.
- stdlib.md, "Bytes at an offset, and a cursor": add the based
  constructor next to `b.cursor()`.

---

## A2: what `len` and indexing mean

**Verdict: A2-views.**
- `s.len()` is bytes, O(1).
- `s[a..b]` is a byte range.
- `s[i]` is a compile error, whose help names the alternatives.
- `chars()` and `graphemes()` are explicit cursors.

**Keep `len`, against prior-art.md.** prior-art.md §2 recommends "no bare
`len` on `Str`", citing Mojo and Roc. That evidence doesn't carry over to
Ren:
- Mojo removed `len` because it indexes by three units (`byte=`,
  `codepoint=`, `grapheme=`), so a bare length really is ambiguous there.
- Roc has no integer positions at all.
- Ren has exactly one position unit, bytes, everywhere: slices,
  `char_floor`, cursors, `at` in errors and `line_col(at)`. `len` is the
  end of the range that `s[0..s.len()]` takes. Calling it `byte_len`
  would make it the only collection with a different name for its
  length, against operators.md's "no `length` or `size` beside `len`".
- The trap Mojo and Roc fear is "`len` means characters". The compile
  error on `s[i]`, plus graphemes and chars as separate O(n) cursors,
  answers it.

**Conflict: `for at, x in s.graphemes()` with `at` a byte offset.**
Decision 16 and stdlib.md define `for i, x in &xs` as "the index and the
element", which is an ordinal. A cursor whose `for i, x` yields a byte
offset gives that syntax two meanings. It also runs against A1c in
spirit: a slice doesn't know where it sits in its parent, which is the
whole point of value-relative positions. So the offset has to be computed
or yielded by name. Task 3's first form, summing `g.len()` over the
graphemes taken, already does this with nothing new. Drop the `for at,`
form. If byte offsets per item turn out to be needed, give them a named
cursor (Rust's `char_indices`), not a meaning of `for i, x`.

**Graphemes belong in `unicode`.** Segmentation reads UAX #29 tables, so
it's `unicode.graphemes(s)`. `s.chars()` stays a `Str` method, because
UTF-8 decoding depends on no table.

**Char literals are the one real gavel inside A2.** formats.md already
uses `'Q'` as a byte, and decided text depends on it:

```
  case kind
    'Q' => Query(sql: CStr)
```

operators.md fixes that "a literal's type stays read from its spelling".
That leaves two coherent packages:
- **(P1) No `Char` type.** This is Roc's and Go's way: `'a'` is an `Int`
  literal, its code point.
  - formats.md is unchanged, and `b.u8(i) == 'a'` works.
  - `s.chars()` yields `Int`s, and classification is
    `unicode.is_alphabetic(c)`.
  - Storing a non-ASCII literal into a `UInt8` is a build error. `'é'`
    is 233, which fits a `UInt8` but isn't its UTF-8. That's decision
    15's "a literal is checked where it's stored", sharpened for
    character literals.
  - The cost: no type tells a code point from an `Int`.
- **(P2) A `Char` type,** a Unicode scalar value. That's ML taste, and
  Rust, Swift, Lean and OCaml's `Uchar` all have it. But formats.md's
  `'Q'` then needs a rule that converts an ASCII `Char` to a byte in tag
  arms and comparisons, which is a conversion the reader doesn't see.
  The alternative is a second literal form, Rust's `b'Q'`.

I lean to **P1**. Ren's target programs are parsers, protocols and
storage engines, which compare bytes against ASCII constantly. P1 keeps
formats.md as written, and it removes about ten `Char` methods from the
surface. `Str + Char` then goes. Appending a code point is
`s += Str.of_code(c)`, which is rare once `+=` takes a `Str`. This is
the owner's call. Either package is coherent. Mixing them is not.

---

## A3: equality and normalization

**Verdict: A3-bytes+nfc.** `==`, `hash` and `<` on `Str` are bytes, which
operators.md already decided: "`Str` (by bytes, which is code point
order)". Normalization is an explicit call, made once, at the boundary,
into an opaque type.

**Why A3-canon is ruled out, not just worse.**
- stdlib.md decided `x.hash()` "has **no seed**: the same value on every
  run, in `ren run` and in every native build, so a hash that's printed,
  stored or journaled replays the same."
- compiler.md: "a `Str` or `Bytes` [is hashed] as its bytes and length".
- Canonical equality makes `hash` normalize. Normalization is stable only
  for assigned code points (prior-art.md §2, the Unicode stability
  policy). So a stored or journaled hash would change across a Unicode
  table bump.
- It also breaks decision 17's "a slice is a value like any other":
  `a == b` but `a.len() != b.len()` (task 15, point 1).
- And Swift, the one language that chose it, keeps a byte comparison
  beside it (SE-0464).

**Coherence. The `key` mechanism already exists, but operators.md's
showcase example is the trap task 15 names.** operators.md, `key`:

```ren
pub type Email = opaque Str
  pub fn of(s: Str) -> Email = s
  pub fn key(self) -> Str = self.lower()
```

This normalizes on every hash and every `==`, allocating per map lookup.
`lower` is the wrong function for identity (task 4: `ß`, NFD,
fullwidth). And today it's ASCII-only. The example should normalize once,
in the constructor. The `key` example should then show a key that
*projects*, such as `Username { shown, id }` with `key = self.id`, or
`Instant`'s. That's the pattern the strings design wants people to copy.
stdlib.md's `Email.parse` snippet is already the right shape.

**Move every table-reading function to `unicode`, and cut three.**
- Keep: `unicode.nfc`, `unicode.nfd`, `unicode.nfkd`,
  `unicode.nfkc_fold` (the identity key), `unicode.lower`,
  `unicode.upper` (display).
- Cut `fold`. Task 5 itself flags "two names that do different things"
  (`lower` against `fold`). With `nfkc_fold` for identity and `lower` for
  display, plain `fold` is a third case name with no task that needs it.
  Task 5's slug becomes `t |> unicode.nfkc_fold |> unicode.nfd`, then
  drop the marks.
- Cut `nfkc`. No task uses it alone, since `nfkc_fold` covers identity.
- Cut `is_nfc`. `nfc()` already returns `s` itself when it's in NFC.

The existing `s.lower()` becomes `s.ascii_lower()`. It's ASCII today,
native since Bytes stage step 3, and the right tool for protocols (task
12, the Kelvin sign). Keeping the name `lower` and silently making it
Unicode would change what it means for existing callers, which is worse.

**The journal rule, made exact.** Track A's open interaction 4 proposes
recording the Unicode version in every journal header and refusing replay
on a mismatch. That would break every `tests/*.journal` once a year,
including the ones for programs that never touch Unicode. Under the
`unicode`-module rule, the compiler knows whether a program reaches
`unicode` (decision 4, a closed world). Record the version only then, and
refuse a mismatch only then, naming the function reached. That follows
the precedent of formats.md's journal shape hashes, which refuse only for
the types that changed.

**Doc text that must change.**
- operators.md, `key`: the `Email` example above.
- operators.md, "What the README changes":
  > "`Email` is equal by its lowercase."
- stdlib.md: nothing; the `unicode` row already says it.

---

## A4: a slice that cuts a character

**Verdict: A4-panic+floor.** Decision 17 is unchanged:
> "A `Str` slice panics if it cuts a character. The slices `split`,
> `index`, `trim` and `lines` make are at boundaries they found, and
> don't check"

Add `s.char_floor(i)`, and have the panic's help name it. This matches
the `xs[i]`/`xs.get(i)` split in operators.md: a bad offset is a bug,
and a computed limit asks explicitly. Rust (1.91) and Mojo (0.26.2) both
moved here.

**Cut `is_char_boundary`.** `s.char_floor(i) == i` says the same, and
nothing in the sixteen tasks needs it. That leaves one way.

**Keep "grapheme cuts never panic".** A panic that depended on the
Unicode version would make slicing depend on a table, against the
`unicode`-module rule.

---

## A5: building strings

**Verdict:**
- interpolation through `show` for text with holes;
- `+` and `+=` on `Str`, in place when unique;
- `xs.join(sep)` for lists;
- no builder type and no iolist type;
- `concat` removed.

This fits operators.md: an operator is a method, and "one name each".
It's Perceus's promise (decision 14) made reliable where CPython's
isn't. A builder would be an identity-bearing object in a value language,
the thing Go needed `copyCheck` to guard (prior-art.md).

**`{x}` against `${x}`: take `{x}`.** It's already written in decided
text (stdlib.md's `"jobs/{job}"`, `sql"... {plan}"`). The case where `{`
hurts is a JSON or CSS literal, which task 7 shows is the case the design
steers away from (shapes for JSON, tagged templates for structured
formats). The escaping cost falls only on code that's already doing the
wrong thing.

**Scope: tagged templates aren't this document's.** stdlib.md already
owns the mechanism ("`sql"..."` needs interpolation a library can
intercept ... stage 12") and lists it as an open question. strings.md
should cite that, not re-decide it, or name `json"..."` and `html"..."`.

**Keep out of `Str`:** `pad_start`, `pad_end` and any format
mini-language. Padding "in chars" is wrong for CJK and emoji, the
terminal-columns trap task 3 itself names. stdlib.md has a `fmt`
module, and padding and number formatting belong there.

**Keep the iolist a runtime question.** Task 7's `Net.write_all(conn,
Array<Str>)` is fine as a library call if B3 says `writev` pays. It
needs no type.

**Coherence notes.**
- `Bytes + Bytes` appears in task 1 (`c.rest() + got`). It's quadratic
  across spans, as the streams amendments note ("`buf ++ c` is
  quadratic"), and `Net.frames` is the answer there. Fine as long as
  strings.md doesn't present `+` on `Bytes` as the framing idiom.
- The proposed debug report for "`+=` copied a shared `Str` in a loop"
  fits decision 17's debug-report family. Keep it.

---

## A6: the `Str`/`Bytes` boundary

**Verdict:**
- A6-strict: `Str.from_utf8(b) -> Str ! InvalidUtf8(at: Int)`, with `at`
  relative to `b` (A1c).
- A named `Str.from_utf8_lossy`. Maximal-subpart U+FFFD is defined by
  UTF-8's structure, not a table, so it stays a `Str` method under the
  `unicode` rule.
- `Path` over `Bytes`.
- No `OsStr`, and no surrogateescape.

That holds "`Str` is always valid UTF-8" without exception, which the
`line_col`, slicing and hash rules all lean on.

**A conflict to fix: two shapes of `NotUtf8`.** The proposal has:
- `Os.args() -> Array<Str> ! NotUtf8(index: Int)`
- `Os.env(name: Str) -> Option<Str> ! NotUtf8(name: Str)`

errors.md says: "If one error set would contain two shapes of one tag,
that's an error asking you to rename one." So any function that reads
both args and env fails to compile. That's the exact case stdlib.md's
error-tag convention exists to prevent. Fix it with distinct
domain-named tags, `ArgNotUtf8(index: Int)` and `EnvNotUtf8(name: Str)`,
following stdlib.md's "named for the domain, with a payload". The other
fix is one shape for both, but an index and a name don't fit one shape.

**`InvalidUtf8` gains a payload.** Today it's payload-free
(prelude.ml:699, 1278–1284). Every `std` use must move to
`InvalidUtf8(at: Int)` together, or user code meets two shapes. The
change is one-time. It just has to be in the same commit everywhere:
`from_utf8`, `Fs.read_str`, the line reader, `Path.to_str` and views'
`Str` fields. That last one is formats' `Malformed`, so check that views
report bad UTF-8 as `Malformed(at, path, "not UTF-8")` and not as
`InvalidUtf8`, so one view has one error set.

**`Path = opaque Bytes`** is coherent: equality is by representation
(operators.md's opaque rule) and `show` is its own (operators.md already
says `Path` has one). Two caveats:
- It touches `Path.join(name: Str)`, `Fs` and `cli`, so it's a change
  set, not a line.
- It's partly outside a strings document. I'd decide the principle
  ("OS data that may not be UTF-8 is `Bytes`-backed") in strings.md and
  leave the `Path` API to `path`.

**BOM:** agreed. Neither `from_utf8` nor `read_str` strips it.

---

## A7: retention

**Verdict:**
- **A7-manual** (`copy()` plus the debug report, as decided).
- **A7-tiny** as representation B's job, if B1 measures it.
- **Reject A7-store.**

**A7-tiny is the bet working as intended.** A short slice copied inline
has no root to keep. No program can tell (A1c keeps it that way), and
Erlang (64 bytes) and V8 (13 characters) do it for the same reason.
It's representation, not policy, so "explicit over magic" doesn't apply:
nothing about meaning is hidden. The cliff when a key outgrows the inline
size is a performance property, and it's documented.

**A7-store conflicts with the amended streams direction.** The streams
amendments' decision 12, on a leased slice kept past the body's turn:
> "I recommend **a compile error with a `.copy()` fix-it where the keep
> is visible, plus a debug report otherwise**. The alternative is the
> compiler copying out silently at the keep point, which is a copy found
> behind your back."

A7-store is precisely "the compiler copying out silently at the keep
point", for one kind of keep. It also fails on its own terms:
- **Two rules for one trap.** A key in a `Map` is fixed, but the same
  slice in an `Array`, a record or a `Map` *value* still pins. A user
  can't predict which without knowing the rule's scope. That's the
  opposite of crisp.
- **A tuning knob**, the ratio and floor, on behaviour users would come
  to rely on: memory and leased-pool backpressure. Rely on it, and it's
  a semantic promise with a heuristic inside.
- **It defeats the explicit path.** If the streams compile error lands,
  `seen.add(id)` with `id` a leased slice is an error before A7-store
  could ever run. If A7-store lands instead, the compile error has to be
  suppressed for exactly `Map` and `Set` keys. One of the two has to go.
  The amendments chose explicit, and strings should agree.

So, would a user think about `copy()`? Not for small keys (A7-tiny).
For larger keys of leased input, the compiler says so with a fix-it, and
for owned roots the debug report does. That's the explicit version of
"complexity in the compiler": the compiler finds it, and the user writes
one word.

**Doc text:** none changes. Decision 17's copy bullet and debug report
stand.

---

## Conflicts found, collected

| # | Proposal | Conflicts with | Fix |
|---|---|---|---|
| 1 | `cursor(from: Int = 0)`, `view(b, from: Int = 0)` | language.md: labels exist on constructors only, and there are no defaults | a second name, or a separate gavel on labelled arguments |
| 2 | `for at, g in s.graphemes()`, with `at` a byte offset | decision 16: `for i, x` gives "the index and the element"; also A1c (a slice doesn't know its place) | drop it; sum `len`s, or a named offsets cursor later |
| 3 | `NotUtf8(index)` and `NotUtf8(name)` | errors.md "Tags are structural"; stdlib.md's tag convention | `ArgNotUtf8(index)`, `EnvNotUtf8(name)` |
| 4 | A7-store | streams amendments, decision 12 ("a copy found behind your back") | reject; take the compile error plus the debug report |
| 5 | `Str.trim`/`fields` on Unicode White_Space, and `Bytes.trim`/`fields` on ASCII, "the receiver picks" | streams.md's "the receiver decides" is about **cost** (eager or lazy), never meaning: "the names are shared, and the type says which". Same name, different meaning by type is a silent switch when code moves from `Bytes` to `Str`. That's the HTTP smuggling trap task 12 names, moved to `Str` | make `trim` and `fields` ASCII whitespace on both, so they mean one thing. Unicode-aware word splitting is `unicode.words` (UAX #29) later, if wanted. Today's `trim` is already ASCII |
| 6 | `s.lower()` becomes Unicode | today's `lower` is ASCII, native, and used by operators.md's `Email` | rename to `ascii_lower`; Unicode case is `unicode.lower` |
| 7 | nfc, graphemes and case as `Str` methods | stdlib.md puts them in a `unicode` module, for determinism | `unicode.*`, as above |
| 8 | `s.lines()` | streams.md's generator example writes `chunk.split_lines()` | pick `lines` and fix streams.md |
| 9 | journal records the Unicode version always, and refuses on mismatch | the journal-as-tests workflow (testing.md); formats.md's precedent refuses only for changed types | record and refuse only if the program reaches `unicode` |
| 10 | `Str + Char` | depends on the `Char` gavel (P1/P2) | settle `Char` first |
| 11 | `xs.join(sep)` on `Array<Str>` only | a method on one instantiation of a builtin generic; the prelude's `Array<T> = builtin` has no such form yet | `Str.join(xs, sep)`, or allow it in the prelude. Small, but decide it |

Conflict 5 is the one I'd most want the owner to see. Task 10's
reasoning ("protocol parsers work on `Bytes`") is right, but the remedy
gives one name two meanings. ASCII-only `trim` on `Str` loses nothing
real. NBSP and U+3000 trimming is display-text work, which belongs with
`unicode`.

---

## The `Str` API: what to cut

The rule applied: **a `Str` method is version-free and earns its place in
a task. Anything that reads a Unicode table is `unicode.*`. Formatting is
`fmt`.**

### Keep on `Str` (version-free)

| | Notes |
|---|---|
| `len`, `s[a..b]`, `s[i]` as a compile error with help | A2 |
| `char_floor(i)` | A4 |
| `chars()` | yields `Int` (P1) or `Char` (P2) |
| `bytes()`, `Str.from_utf8 ! InvalidUtf8(at)`, `Str.from_utf8_lossy`, `copy()` | A6 |
| `index`, `includes`, `starts_with`, `ends_with`, `strip_prefix`, `strip_suffix` | search |
| `split`, `split_once`, `lines`, `trim`, `fields` | **ASCII whitespace**, the same on `Bytes` |
| `replace` | |
| `ascii_lower`, `ascii_upper` | protocols |
| `line_col(at)` | columns in code points, version-free |
| `+`, `+=`, interpolation, `join` | A5 |

### Move to `unicode`

`graphemes`, `nfc`, `nfd`, `nfkd`, `nfkc_fold`, `lower`, `upper`, and
classification (`is_alphabetic`, `is_numeric`, `is_whitespace`,
`is_mark`).

### Cut

| Cut | Why |
|---|---|
| `fold` | a third case function; `nfkc_fold` for identity, `lower` for display |
| `nfkc` | no task uses it alone |
| `is_nfc` | `nfc()` returns `s` when it's already NFC |
| `is_char_boundary` | `char_floor(i) == i` |
| `trim_start`, `trim_end` | no task needs them; add when one does |
| `last_index` | no task needs it; add with a task (file extensions are `Path`'s) |
| `repeat` | no task; a two-line loop with `+=` |
| `pad_start`, `pad_end` | wrong unit for display; `fmt`'s job |
| `Chars.count()` / `Graphemes.count()` as named methods | they're the cursor vocabulary streams already gives every cursor; don't list them as `Str` API |
| the `Char` method list (about 10) | goes with P1; under P2, cut to `is_ascii`, `code`, `Char.of`, and put the rest in `unicode` |
| `ByteCursor.sub(n)` | sugar for three lines; a second way to make a based cursor |
| `concat` | already removed by `+` |
| `json"..."`, `html"..."` | not strings.md's; stdlib.md owns tagged templates |

Net effect: about 45 proposed names become about 25 on `Str`, plus about
11 in `unicode`. Every name left on `Str` is O(n) or better, depends on
no table, and gives the same answer in every build and every release.

---

## Questions for the owner

1. **`Char`:** P1 (`'a'` is an `Int`; formats.md is unchanged) or P2 (a
   `Char` type, plus a byte-literal rule). I lean to P1.
2. **The base on positions:** a second name now (`cursor_from`,
   `view_from`), or decide labelled call arguments first.
3. **`trim` and `fields` on `Str`:** ASCII, the same meaning as on
   `Bytes` (my recommendation), or Unicode White_Space (Track A's).
4. **A7-store:** confirm the rejection, in line with the streams
   amendments' decision 12.

Everything else follows from decided text.

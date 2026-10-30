# Strings: text as bytes that are known to be UTF-8

How a Ren program holds, cuts, compares, builds and converts text, and
how that differs from `Bytes`. It settles what [foundations.md
decision 17](foundations.md#17-slices-are-values) and
[operators.md](operators.md#slices) left open about `Str`, and amends
[foundations.md decision 19](foundations.md#19-formats-are-views),
[formats.md](formats.md#errors-carry-offsets),
[operators.md](operators.md) and [stdlib.md](stdlib.md).

**Status.** Decided on 2026-10-29, from a survey of prior art (Rust,
Zig, Go, Swift, Python, Java, Erlang, Roc, Lean, Mojo and others),
seventeen programs written against the candidate designs, two judges
of those programs, and measurements of five layouts and policies on a
C model of Ren's runtime. The documents it amends keep their current
text until they're updated to match. Already built: `Str` is valid
UTF-8, slices share their root and panic if they cut a character,
equality is by bytes, and `trim` and `lower` are ASCII. Items marked
**later** are noted so they aren't lost.

## Contents

- [What it has to do](#what-it-has-to-do)
- [Str and Bytes](#str-and-bytes)
- [Positions](#positions)
- [Length and indexing](#length-and-indexing)
- [Cutting a character](#cutting-a-character)
- [Equality, hashing and order](#equality-hashing-and-order)
- [The `unicode` module](#the-unicode-module)
- [Building strings](#building-strings)
  - [Templates](#templates)
- [Literals](#literals)
- [The boundary](#the-boundary)
- [Characters](#characters)
- [Retention](#retention)
- [The API](#the-api)
- [Representation](#representation)
- [Compiler errors](#compiler-errors)
- [Left out](#left-out)
- [Later](#later)
- [Evidence](#evidence)

## What it has to do

1. **A `Str` is always valid UTF-8.** It's checked once, where bytes
   become text, and never again.
2. **One unit.** Positions, ranges, lengths, equality, hashing and
   order are all in bytes. Anything that counts or compares in another
   unit says so in its name.
3. **The same answer everywhere.** `ren run` and every native build,
   this year's release and next year's, give the same result for every
   operation on `Str`. That's what lets a journal replay.
4. **A layout nobody can see.** The programmer never holds an address
   ([the bet](foundations.md#the-bet)), so how a string is laid out,
   shared or copied is the compiler's choice, and nothing a program can
   observe pins it.
5. **The obvious code is the fast code.** Slicing copies nothing,
   appending in a loop is linear, and checking UTF-8 costs a few percent
   of a program that reads text.

## Str and Bytes

`Bytes` is any bytes. `Str` is bytes known to be UTF-8. They share
everything that doesn't depend on the difference: slicing, search,
split, trim, `copy()`, and the same meaning for each name.

- **A parser works on `Bytes`** when its input is a protocol or a file
  format, and makes a `Str` of a field once it has checked it. A view
  checks a format's `Str` fields when it's made ([formats.md](formats.md)).
- **A program works on `Str`** for text it shows, stores or compares.
- **`s.bytes()` is free.** It's the same buffer, seen as `Bytes`.
  Going the other way, `Str.from_utf8(b)`, checks.

## Positions

**A position is a byte offset into the value you hold.** `s.index(",")`
on a slice counts from the slice's start, not from the buffer it was
cut from. So an offset never depends on how the value was made, whether
it was copied or shared, or which build ran.

A program that wants a position in a whole stream or file says where
its value starts, once, where it makes the thing that reports
positions: a cursor (`b.cursor(from: n)`) or a format view
(`T.fmt.view(b, from: n)`). After that, every error's `at` counts from
`n`:

```ren
var c = buf.cursor(from: base)    // base: where buf starts in the stream
match attempt frame(&c)
  Ok(f) => try handle(f)
  Err(e) => fail e                // e's `at` is already a stream offset
```

- **`from` defaults to 0.** Unit tests never need it.
- **Library cursors that know their base carry it,** as `Net.frames`
  and `Fs.line_reader` do, so their errors give stream and file offsets
  with no code.
- **Plain functions take no base.** `Str.from_utf8(b)` reports `at`
  within `b`.
- **`at` is for reports, never for indexing.** An error's `at` goes in
  a message or a log. To reach bytes, use the cursor. Code that indexes
  the buffer with `at` works while the base is 0, which every test
  uses, and reads the wrong bytes once it isn't.

`from` is a parameter with a default, `from: Int = 0`, so it's given by
name ([language.md](language.md#positional-for-one-field-by-name-for-several)).

**Why not offsets in the root.** formats.md promised that `at` was "the
offset in the whole buffer", the file's or the socket's, because a
slice is a root and a range. That offset counts from whichever buffer
the bytes happen to be in: a leased chunk, a buffer two reads were
joined into, or a copy the interpreter made. It's not the stream
offset, it differs between builds, and every copy or inline layout
the compiler might choose would change it. It can't be built either:
the interpreter's `Bytes` keep no root.

## Length and indexing

```ren
s.byte_len()            // bytes
s[a..b]                 // the bytes from a to b, a Str
s.chars()               // a cursor of characters, each a one-code-point Str
unicode.graphemes(s)    // a cursor of grapheme clusters, each a Str
```

**`Str` has no `len` and no `s[i]`.** Both are compile errors, and the
help names what each might have meant:

```
error: `Str` has no `len`: bytes, or characters?
  --> signup.ren:14:8
   |
14 |   if name.len() > 20 then fail TooLong
   |           ^^^
   = help: bytes: `name.byte_len()`; code points: `name.chars().count()`;
           what a reader sees as characters: `unicode.graphemes(name).count()`
   = help: `name.is_empty()` asks whether it has any
```

A reader of `name.len() > 20` can't tell whether the writer meant 20
bytes or 20 characters, and the two disagree for every user who doesn't
write English. A limit in bytes is a storage or protocol limit, and one
in characters is a display limit; the name puts the unit on the page.
`Bytes` and `Array` keep `len`, where there's only one unit.

This bends operators.md's "one name for each, no `size` beside `len`":
`Str` has `byte_len` *instead of* `len`, not beside it. It's the same
rule as `s[i]`: on `Str`, an operation whose unit is ambiguous doesn't
compile.

- **`s[i]` would be a byte,** which invites character arithmetic done
  in bytes. A byte is `s.bytes().u8(i)`.
- **There's no `for at, x in s.chars()`.** `for i, x` means the index
  and the element (decision 16), and a byte offset there would give it
  two meanings. A loop that needs offsets sums `c.byte_len()` in a
  `var`, or uses a cursor.

## Cutting a character

A `Str` slice that cuts a character panics, as decision 17 says, in
every build at the same point:

```
panic: slice 0 to 1024 ends inside a character
  = help: to cut at most 1024 bytes, end at `line.char_floor(1024)`
```

`s.char_floor(i)` is the last character boundary at or before `i`, and
`s.char_ceil(i)` the first at or after it, which is what a byte budget
needs:

```ren
let head = line[0..line.char_floor(1024)]                 // at most 1024 bytes
let tail = m[m.char_ceil(m.byte_len() - 1024)..]          // at most the last 1024
```

- **No rounding.** A slice that rounds silently breaks
  `s[a..b].byte_len() == b - a`.
- **Found slices never check.** The slices `index`, `split`, `trim` and
  `lines` make are at boundaries they found.
- **Grapheme cuts never panic,** because a panic mustn't depend on a
  Unicode table. Cutting at a grapheme is `unicode`'s.
- **`s.char_floor(i) == i`** asks whether `i` is a boundary, so there's
  no `is_char_boundary`.

## Equality, hashing and order

`==`, `hash` and `<` on `Str` compare bytes, as operators.md decided.
Two strings that look the same but are written with different code
points, `é` as one or as `e` and an accent, aren't equal.

Canonical equality, as Swift has, is ruled out, not just slower:
- **Hashes would change between releases.** `x.hash()` has no seed and
  may be journaled ([stdlib.md](stdlib.md#xhash-and-a-maps-own-hash)),
  and normalization is stable only for code points already assigned.
  A new Unicode version would change a stored hash.
- **A slice would stop being a value.** You could have `a == b` while
  `a.byte_len() != b.byte_len()`.
- **It wouldn't solve identity anyway.** Usernames and emails need
  case folding and compatibility forms (`ß`, fullwidth letters), which
  canonical equality doesn't do.

So a type whose identity needs normalizing normalizes **once, in its
constructor,** and compares bytes from then on:

```ren
pub type Username = opaque Str
  pub fn parse(s: Str) -> Username ! BadName =
    let id = unicode.nfkc_fold(s)
    if id.is_empty() || id.byte_len() > 64 then fail BadName    // check after folding
    id
```

A `key` that normalizes, `fn key(self) -> Str = self.lower()`, is the
trap this avoids: it normalizes on every hash and every `==`, and the
value stored isn't the value compared.

## The `unicode` module

Everything that reads a Unicode table is in `unicode`, and nothing
on `Str` reads one:

| | |
|---|---|
| normalization | `unicode.nfc(s)`, `nfd`, `nfkd`, `nfkc_fold` |
| case | `unicode.lower(s)`, `unicode.upper(s)` |
| segmentation | `unicode.graphemes(s)` |
| classes, of a `Str`'s first code point | `unicode.is_alphabetic(c)`, `is_numeric`, `is_whitespace`, `is_mark` |

- **The tables are pinned** to one Unicode version per Ren release.
- **The journal records a fingerprint of the pinned top-level data a
  program reaches,** from any library: Unicode's tables, the time zone
  database, a user's own tables. They're top-level `let`s, which the
  build already hashes ([shapes.md](shapes.md)), and dispatch is static
  over a closed world (decision 4), so the compiler knows which a
  program can reach. A replay under different data is refused only
  then, naming what was reached. `unicode` gets this as any library
  does, with no rule of its own: a program that never touches it
  replays across every release, and its `tests/*.journal` files never
  go stale.
- **`nfc(s)` returns `s` itself** when it's already in NFC, so it costs
  a scan and no copy.
- **`Str`'s own methods give the same answer in every release,**
  because none of them reads a table. That's why `s.lower()` is renamed
  `s.ascii_lower()`: it's ASCII-only today, and a silent change to
  Unicode would change existing callers.

## Building strings

There are three ways, and no builder type:

```ren
let path = "jobs/\{job}"                  // interpolation, through `show`
var out = "["
for i, r in rows
  if i > 0 then out += ","
  out += r.json()                          // in place when `out` is unique
out += "]"
let csv = cells.join(",")
```

- **Holes are written `\{x}`.** `\` is already the escape character,
  so a regex (`"\\d{3}"`), JSON, CSS, or another system's template
  (`"{name}"`) pastes into a string unchanged and means what it says. A
  plain `{` would capture silently whenever a name in scope matched.
  Java's string templates chose `\{` for the same reason, and Swift
  uses `\(x)`.
- **A hole is any expression,** `"\{u.name}: \{n * 2}"`, and goes
  through its type's `show`. Widths, padding and number formats are
  `fmt`'s, `"\{fmt.pad(n, 6)}"`; there's no format mini-language in
  the string.
- **`s += t` appends in place** when `s` is unique, growing its buffer
  by doubling, so a loop of appends is linear, as fast as a builder.
  `a + b` makes a new string. Debug builds report a `+=` inside a loop
  that copied because its string was shared, the one way appending goes
  quadratic again.
- **`xs.join(sep)`** on an `Array<Str>`.
- **`\{x=}` is `x=\{x}`,** in `"..."` and `t"..."` alike. Only a name
  or a path may come before `=`. Python's `f"{x=}"` is the model.
- **A library that wants the holes,** for SQL, HTML or a log line,
  takes a template, below.

### Templates

A plain string is for text. A template is for a library that needs to
see the holes before they become text: SQL that must not splice values
into the query, HTML that must escape, a log line that wants fields.
Decided on 2026-10-29 from the templates experiment
(research/templates/).

```ren
log.info(t"user \{user} paid \{amount}")
let users = DB.rows<User>(t"select * from \{sql.table(kind)} where id = \{id}")
let row = html.of(t"<td>\{name}</td><td>\{html.raw_trusted(badge)}</td>")
```

Six rules:

1. **`"...\{x}"` is a `Str`.** Each hole goes through `show`, as above.
   The plain case stays the cheapest case.
2. **`t"...\{x}"` is a `Template<H>`, never a `Str`.** It has a static
   half, the site, made while building: the parts, the raw parts, and
   each hole's source text and static type. It has a dynamic half, the
   holes, evaluated eagerly left to right, as the tuple `H`. Nothing
   converts between `Str` and a template implicitly. `t.render()` is
   the only way to a `Str`. A `Str` passed where a template is expected
   is a type error, the mistake JS can't catch when a tag is missing.
3. **A template follows the block rule.** It's passed down as an
   argument, or bound with `let` and passed on. It can't be stored,
   returned, chosen with `if`, or captured by a block that outlives the
   call. To keep one, convert it to the consumer's data: `t.render()`,
   `sql.frag(DB, t)`, `html.of(t)`. A template is two words, the site
   and a pointer to the holes in the caller's frame, so nothing
   allocates, at any number of holes, in either build.
4. **A `let` between a signature and its `=` runs while building, once
   per call site.** This is the signature `let`. It reads only what's
   known while building: a template's site, a type's shape, literals,
   top-level values. A `try` that fails there fails the build, at the
   call. The body reads the result as a constant, a plan rather than a
   pass or fail.

   ```ren
   pub fn rows<T, H>(self: Schema, q: Template<H>) -> Array<T> uses Sql ! DbDown
     let plan = try sql.plan(self, q.site(), T.shape)   // while building, per call site
   =
     Sql.rows(plan.bind(q.holes())) |> try sql.decode_all<T>
   ```

   It's general, not for templates only: `regex.compile`,
   `Duration.parse` and json codecs with a literal argument use it too.
   It's [decision 20](foundations.md#20-what-the-language-owns-and-what-std-owns)
   rule 3's one mechanism for build-time checks. Two limits, each an
   error with help: a signature `let` that depends on a type parameter
   of the caller is refused, because debug builds never specialize
   (decision 13); and forwarding a template through a wrapper to a
   signature `let` is refused, so the wrapper takes the consumer's own
   type (`sql.Query`). It may read only the build's world (`Fs` inside
   the package, `Git`), never a database.
5. **A hole's kind or format is a value:** `\{sql.table(k)}`,
   `\{html.raw_trusted(s)}`, `\{fmt.pad(n, 6)}`. There's no format
   language. The consumer's plan decides what each hole's type means and
   refuses the ones it can't handle.
6. **`\{x=}` is `x=\{x}`,** in templates as in strings.

**The site's identity.** `site.id` is one `Int` per literal, a cache key
inside one process. It never crosses a journaled dependency call,
because a rebuilt binary renumbers sites. Where a dependency needs a
key, a prepared statement or a log message id, the consumer passes
`site.hash`, a hash of the parts.

**Decisions that came with it:**

- **Passed down, not kept.** A keepable template costs one allocation
  and loses its call site, so its check is gone. No program in the
  experiment needed to keep one; each that kept something wanted the
  consumer's data.
- **The signature `let` is the build-time mechanism,** for templates
  and everything else, not a reserved `check` member on the consumer.
  It's explicit in the callee's signature, and its position (before
  `=`) says when it runs, the rule top-level `let` already uses.
- **A lazy log line uses a guard,**
  `if log.on(Debug) then log.debug(t"tree \{dump(tree)}")`. A block may
  not return a template (rule 3), so this revises stage 12's G2. Under
  `log.off()` in a closed world the line compiles out.
- **Log field names come from the hole's source text.** The log plan
  refuses a hole that isn't a name or a path.
- **SQL across a dependency** makes one params array per call, today's
  cost. Templates make SQL safe and checked, not faster.
- **No prefix like `DB"..."`.** A prefix is a second spelling of a
  method call: Java withdrew its template processors (JEP 465) for that
  reason. In SQL it loses the verb and the row type, and in logs it has
  nowhere to put the level.
- **Raw and multi-line templates** are [Literals](#literals)'
  `t"""..."""` and `t#"..."#`, which keep their holes.

**Measured,** on an M4 Max, hand-written C as release should emit it,
against Rust's `write!` (research/templates/verify.md):

- **A log line,** four fields into a reused buffer: 0.39x of Rust's
  time, 15.2 ns, with 0 allocations. Specialized per `H` only, not per
  site, it's 0.51x; debug's unspecialized shape is 0.56x.
- **An HTML row,** five holes, four escaped: 0.63x of Rust's time, 0
  allocations.
- **SQL** is safety, not speed. The cost is the params array, as today.
  What goes away is interpolating into the query text, 82 ns and unsafe.
- **Today's log line** is 3.3x Rust's time, mostly `snprintf` in
  `show_int`. A digit-pair `show_int` alone takes it to 2.0x.

**Prior art:**

- **Python's PEP 750:** a template is its own type, and `Template + str`
  is an error.
- **Java after JEP 465:** the template is the value, and plain methods
  process it.
- **JS tagged templates:** one site per literal, its strings array
  cached.
- **C#'s interpolated string handlers:** a `ref struct`, so zero
  allocation; Ren's lowering measured within noise of it.
- **Rust's `fmt::Arguments`:** can't outlive its statement, the same
  rule as rule 3.
- **C++20's `format_string` and Zig's `std.fmt`:** the check lives in
  the callee and runs at compile time, as a signature `let` does.
- **postgres.js and doobie:** a hole's kind is a value, `sql(ident)`.

## Literals

Decided on 2026-10-29. Before it, a string couldn't span lines and had
four escapes, so an HTTP line ending couldn't be written, and the JSON
and HTML programs of the templates experiment were full of `\"`. The
best prior art (Swift, C# 11) strips indentation at compile time by the
closing delimiter's column, and makes raw strings by choosing a
delimiter rather than banning characters; runtime dedenting (Kotlin's
`trimIndent`, Python's `textwrap.dedent`), a crate (Rust's `indoc!`) and
per-line prefixes (Zig's `\\`) are what those replaced.

Three rules:

1. **`"""` starts a multi-line string, and the closing `"""`'s column
   decides its indentation.**

   ```ren
   let body = """
     {
       "name": "\{name}",
       "tags": ["a", "b"]
     }
     """
   ```

   - The content starts on the line after the opening `"""` and ends
     before the line of the closing `"""`, so it has no trailing
     newline; a blank line before the closing `"""` gives one.
   - Every content line starts with the closing `"""`'s indentation,
     which is removed. A line indented less is an error pointing at it,
     and so is a prefix that mixes tabs and spaces. A blank line may be
     shorter.
   - `\` at the end of a line joins it to the next, for a long line.
   - Escapes and holes work as in `"..."`, and a `"` needs no escape.
   - The layout rule doesn't look inside: the literal is one token.

2. **`#`s around a string make it raw: its escape becomes `\` followed
   by as many `#`s.**

   ```ren
   let re = #"\d{3}-\d{4}"#
   let q = t#"select "name" from t where id = \#{id}"#
   let doc = #"""
     "\n" means newline. Ask \#{who}.
     """#
   ```

   Inside `#"..."#`, `\n` is two characters; `\#n` is a newline and
   `\#{x}` a hole. Content holding `"#` takes more: `##"..."##`. It's
   one rule for every form: `"""`, the prefixes `t` and `b`, and holes,
   as Swift's has been since 2019.

3. **The escapes are `\n`, `\t`, `\r`, `\0`, `\"`, `\\` and
   `\u{...}`** (a code point, 1 to 6 hex digits, not a surrogate) in
   every string, and in character literals with `\'` for `\"`. **`\x41`,
   a byte, is only in `b"..."`:** in a `Str` it could make invalid
   UTF-8, and its error's help writes the `\u{...}`.

**`b"..."` is a `Bytes` literal:** `b"\r\n"`, `b"\x00\x01"`,
`b#"..."#`, `b"""..."""`. Its bytes are the UTF-8 of the text as
written, non-ASCII included (as Zig, unlike Rust), plus each `\x`. It
has **no holes**: `Bytes` has no `show` to put into one, so `\{` there
is an error whose help points to [formats.md](formats.md). It's a
static owner, as a `Str` literal is, so it allocates nothing:
`b.index(b"\r\n")`.

**The prefixes are a closed set, `t` and `b`.** No user prefixes
([Templates](#templates), "No prefix like `DB"..."`"), and no `r`: a
`#` is the raw form.

## The boundary

Bytes become text in one place, and fail with where they went wrong:

```ren
Str.from_utf8(b) -> Str ! InvalidUtf8(at: Int, incomplete: Bool)
Str.from_utf8_lossy(b) -> Str
```

- **`at`** is the offset of the first byte that isn't valid, within `b`.
- **`incomplete`** is true when `b` ends partway through a character,
  so a decoder working chunk by chunk can tell "invalid" from "not
  finished yet".
- **Lossy is by name.** `from_utf8_lossy` replaces each maximal invalid
  subpart with U+FFFD. That rule comes from UTF-8's structure, not a
  table, so it's on `Str`. Losing data is something you choose.
- **A byte order mark is kept.** Neither function strips one.
- **Read once, convert once.** `Fs.read_str(p)` reads `Bytes` and
  converts them; reading a file a second time to recover the bytes is a
  race.
- **A view reports a bad `Str` field** as `Malformed(at, path, "not
  UTF-8")`, so a view has one error set.

**What the operating system gives isn't always UTF-8.** File names,
arguments and environment variables are bytes on Unix, so:

- **`Path` is `opaque Bytes`,** not `opaque Str`. A path that isn't
  UTF-8 round-trips. Its `show` writes invalid bytes as `\xNN` and a
  backslash as `\\`, so the output isn't ambiguous. Its API is the
  `path` module's.
- **`Os.args() ! ArgNotUtf8(index: Int)`** and **`Os.env(name) !
  EnvNotUtf8(name: Str)`**, with `Os.raw_args()` and `Os.raw_env(name)`
  for programs that want the bytes. Each tag has one shape
  ([errors.md](errors.md)).
- **No `OsStr` type,** and no surrogate escapes.

## Characters

There's no `Char` type. "Character" means a byte, a code point or a
grapheme depending on who's asking, and a type named `Char` would pick
one and hide the choice, which is what [Length and
indexing](#length-and-indexing) refuses to do. Instead:

**`s.chars()` yields one-code-point `Str` slices.** They copy nothing,
print as themselves, compare with string literals and append with
`+=`:

```ren
for c in s.chars()
  if c == "é" || unicode.is_alphabetic(c) then out += c
```

`c.code()` gives a one-character string's code point as an `Int`, and
panics on any other string. `Str.of_code(n)` makes one from a code
point, for decoders and escapes.

**`'a'` is an `Int` literal,** whose value is its code point, checked
where it's stored as any literal is (decision 15). It's for working
with bytes and code points as numbers:

```ren
if b.u8(i) == '"' then ...        // an Int against an Int
let tag: UInt8 = 'Q'              // formats.md's tags, unchanged
let e: UInt8 = 'é'                // build error: 'é' is 2 bytes in UTF-8, not one
```

- **A non-ASCII literal can't be stored in a `UInt8`,** though its code
  point may fit: a `UInt8` is a byte, and `'é'` isn't one.
- **Characters are text, and code points are numbers.** A loop over
  `s.chars()` deals in `Str`, which prints as `é`, not `233`. Code that
  does arithmetic on code points, a hand-written decoder or a lexer's
  tables, calls `.code()`, and usually belongs on `Bytes` anyway.
- **The `unicode` classifiers take a `Str`,** `unicode.is_alphabetic(c)`,
  so they work on a character from `chars()` and on a grapheme from
  `unicode.graphemes(s)` alike. One with more than one code point is
  classified by its first.

**Whitespace means ASCII.** `trim`, `fields` and `lines` split on ASCII
whitespace, on `Str` and on `Bytes` alike, so code that moves between
the two types keeps its meaning. A header parser that trimmed Unicode
space as `Str` and ASCII as `Bytes` would disagree with the server
behind it, which is how requests get smuggled. Trimming NBSP or U+3000
for display is `unicode`'s.

## Retention

A slice shares its root and keeps the whole of it alive (decision 17).
That's what makes parsing free, and it's the one trap strings keep:

- **Keeping many small slices of a big input pins the input.** Write
  `.copy()` on what you keep; it's free on a value that already has its
  own buffer.
- **Debug builds report** roots kept alive mostly by small slices, and
  where they were made.
- **A slice of a leased chunk kept past its turn** is an ordinary root
  (decision 17). Under pool pressure the runtime may move a held chunk
  to the heap, which positions relative to the value make invisible.
  Debug builds report it, and the pool's metrics count it.

**What the compiler may do without telling you.** Because positions
are relative to the value, a program can't see whether a string is
shared, copied or stored inline. So the compiler may copy a slice when
it proves the root dies before the collection keeping it, or keep short
strings inline. Neither is a promise, and no program may rely on
either.

**No automatic rule replaces `copy()`.** Measured: keeping 10,000 keys
(230 KB) from 512 MiB of input held 522 MiB with plain sharing, and
still 522 MiB when every slice under 16 or under 64 bytes was copied,
because one longer slice per buffer pins it anyway. Copying everything
that's stored bounded it at 18 MiB but made a tokenizer 1.6× slower,
where the root was alive anyway.

## The API

About 25 names on `Str` and 11 in `unicode`:

| | On `Str` | |
|---|---|---|
| Size and position | `s.byte_len()`, `s.is_empty()`, `s[a..b]`, `s.char_floor(i)`, `s.char_ceil(i)`, `s.line_col(at)` | columns count code points |
| Views | `s.bytes()`, `s.chars()`, `c.code()` | `chars()` yields one-code-point `Str`s |
| Search | `index`, `includes`, `starts_with`, `ends_with`, `strip_prefix`, `strip_suffix` | results are slices or offsets of `s` |
| Split and trim | `split`, `split_once`, `lines`, `fields`, `trim` | ASCII whitespace |
| Transform | `replace`, `ascii_lower`, `ascii_upper` | |
| Build | `"…\{x}…"`, `a + b`, `s += t`, `xs.join(sep)`, `Str.of_code(c)` | |
| Boundary | `Str.from_utf8(b)`, `Str.from_utf8_lossy(b)`, `s.copy()` | |

- **`Bytes`** has the same search, split and trim names with the same
  meaning, `ascii_lower`, `len`, and layer 3's reads, writes and
  cursor ([stdlib.md](stdlib.md#bytes-at-an-offset-and-a-cursor)), plus
  `b.cursor(from: n)`.
- **Gone from what earlier stages had or proposed:** `len` on `Str`,
  `concat`, `fold`, `nfkc`, `is_nfc`, `is_char_boundary`, `trim_start`,
  `trim_end`, `last_index`, `repeat`, `pad_start` and `pad_end` (to
  `fmt`), the `Char` type, `for at, x in`, and
  `ByteCursor.sub`.

## Representation

None of this is visible to a program. It's what the compiler should
build, and why. Measured on a C model of Ren's runtime with Rust and Go
twins, medians of 11 runs, compared within each table.

**A `Str` is 16 bytes: a root, a 32-bit offset and a 32-bit length.**
Today a kept slice is a 32-byte heap object. The inline layout
allocates nothing per slice:

| ms | today | **16 B inline** | 24 B (Roc's) | short strings inline | German strings |
|---|---|---|---|---|---|
| tokenizer | 27.1 | **20.2** | 22.2 | 21.1 | 24.8 |
| map build | 312 | **283** | 291 | 301 | 320 |
| sort | 344 | **262** | 264 | 288 | 290 |
| group by | 211 | 209 | 209 | 218 | 220 |

- **German strings lose** by 5–23%. A counted root can't be found from
  a pointer into its middle, so every long string needs an extra
  indirection. They suit column stores, not counted values.
- **Short strings inline** lose 2–10% here but won 6% on parsing
  records with many short fields. It stays open as a **later** change.
- **The owner's header carries a capacity,** which in-place `+=`
  needs, so the two are built together.

**Appending.** Building 1M JSON records: `+=` in place 158 ms, a
builder 159 ms, an iolist 427 ms. Today's `s = s + x` is quadratic:
about 680× slower at 5,000 records. `Net.write` keeps taking several
values for large existing pieces, but iolists aren't the output path.

**Validation.** Checking UTF-8 is 13–41% of a program that reads text,
parses it and responds. A block validator (Keiser and Lemire's, about
100 lines, three 16-byte tables) runs at 73 GB/s on ASCII against
today's 2.6, the same as Rust's `simdutf8`, and cuts that share to
1–8%. It's exact, so the interpreter and native builds can't disagree;
the error's offset comes from re-scanning the failing block byte by
byte. With it, there's no speed argument left for an unchecked `Str`.

**Keys.** A `Map<Str, Int>` with wyhash and the hash kept per entry
runs at 1.02–1.05× Rust with FxHash or aHash. (compiler.md's "0.69×"
was against Rust's default SipHash.)

**The 4 GiB limit.** A 32-bit offset and length cover 4 GiB. A larger
`Str` or `Bytes` takes an escape, a flag and an offset kept outside;
what that costs code that never meets one isn't measured yet.

## Compiler errors

```
error: `Str` has no `len`: bytes, or characters?
   = help: bytes: `s.byte_len()`; code points: `s.chars().count()`;
           what a reader sees as characters: `unicode.graphemes(s).count()`

error: a `Str` can't be indexed: `s[i]` would be a byte
   = help: a byte: `s.bytes().u8(i)`; a slice: `s[i..j]`; characters: `s.chars()`

error: `s.lower()` is now `s.ascii_lower()`
   = help: for every script's case, `unicode.lower(s)`

error: `'é'` isn't a byte: it's 2 bytes in UTF-8
   = help: compare text as text: `c == "é"`
```

## Left out

- **A builder type.** In-place `+=` is as fast, and a builder is an
  object with identity in a language of values. Go needed a runtime
  check to keep its builder from being copied.
- **Iolists and ropes.** 2.2–2.5× slower to build output, even
  streaming.
- **Canonical equality.** See above.
- **Root-relative offsets.** See [Positions](#positions).
- **Grapheme indexing,** `s[grapheme: 3]`. It hides a scan from the
  start behind `[]`.
- **`OsStr`.** `Path` and `Os` use `Bytes`.
- **Format mini-languages** in strings. `fmt` has functions.
- **Collation and locale.** A sort by a person's language is a
  library's, with its tables, and isn't `<`.
- **UTF-16 and other encodings** inside a program. They're converted at
  the boundary.

## Later

- **`s.get(a..b) -> Option<Str>`,** a checked slice for offsets that
  come from input, added only with the same form on `Array` and `Bytes`.
- **Short strings inline,** measured again once the 16-byte layout is
  real, and under contended counts on a hot root (decision 10).
- **Copying a slice when the compiler proves its root dies first,** an
  analysis that hasn't been built or measured.
- **An `Offset` type that can't index,** only if the `at` trap shows up
  in real code.
- **`clear()` that keeps capacity,** if reusing a response buffer turns
  out to matter.

## Evidence

In research/strings/: the prior-art survey, the seventeen programs (a framing loop, CSV with
`line:column`, truncating names, usernames, slugs, keeping 10k keys,
JSON output, templates, files that aren't UTF-8, whitespace, word and
grapheme counts, HTTP headers, file lines, nested views, user-input
map keys, a byte budget, and paths and arguments), the two judges'
reports, and the measurements with their verification.

- **Positions:** Lean 4's slice-relative positions, Kaitai's
  substreams and nom_locate's carried base. Erlang has the root offset
  and hides it.
- **`len`:** Mojo made `len(String)` unavailable in 2025 because "a
  single length is ambiguous"; Roc's `Str.len` points you to
  `count_utf8_bytes`.
- **Cutting:** Rust 1.91 stabilized `floor_char_boundary` and
  `ceil_char_boundary` together.
- **Equality:** Swift, the one language with canonical equality, added
  a byte comparison beside it (SE-0464).
- **Building:** Lean, Roc, Erlang and Swift all append in place when
  unique. Java's string templates (JEP 430) use `\{`.
- **The boundary:** Rust's `Utf8Error` has `valid_up_to` and
  `error_len`; Python's surrogate escapes and Rust's `OsStr` are the
  two designs not taken.
- **Representation:** Roc's 24-byte strings, Umbra's German strings,
  Keiser and Lemire's validator (simdutf).

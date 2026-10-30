# Formats: how a type looks outside

How a Ren program reads and writes data whose form something outside
it fixes. A format is how a type looks somewhere, and there are two
kinds. A **layout** is bytes: a page on disk, a log record, a network
frame, a file header. A **look** is names, tags and conversions: a json
body, a flag, a route, a version of a message, read by any library
through the type's shape. It closes the open question in
[foundations.md](foundations.md#open-questions), "explicit layout, for
formats on disk and on the wire", and is the third piece of
[language.md](language.md)'s data-oriented side after `Table` and
`Pool`. The short version of layouts is [language.md §12](language.md#12-bytes-types-and-their-formats);
how they run is [foundations.md decision 19](foundations.md#19-formats-are-views).
How a library walks a type through its looks is
[shapes.md, "The walk"](shapes.md#the-walk).

**Status.** Layouts decided on 2026-10-29, from two research passes
into prior art (views over buffers, declared layouts and versioning;
binary parsing ergonomics). Looks decided on 2026-10-29, from the looks
research (research/looks/: Effect v4 studied, flottning's API written
both ways, a review and a check against the compiler), signed off with
the owner's rulings and placed by
[decision 20](foundations.md#20-what-the-language-owns-and-what-std-owns).
Layouts are staged with strings, bytes, slices and sized integers, in
"the `just`, natively" ([foundations.md](foundations.md#staging)); looks
in stage 12 (research/looks/feasibility.md). Items marked **later** are
noted so they aren't lost. Nothing here is implemented.

## Contents

- [What it has to do](#what-it-has-to-do)
- [The problems](#the-problems)
- [Three layers: a default, then sharper tools](#three-layers-a-default-then-sharper-tools)
- [A type, and its formats](#a-type-and-its-formats)
- Looks
  - [Looks of a scalar: `via`](#looks-of-a-scalar-via)
  - [Looks of a record: lines](#looks-of-a-record-lines)
  - [Looks of a sum: tags](#looks-of-a-sum-tags)
  - [Looks of an opaque type: always a function](#looks-of-an-opaque-type-always-a-function)
  - [What a look can expose](#what-a-look-can-expose)
  - [Errors carry paths](#errors-carry-paths)
  - [Versions are looks](#versions-are-looks)
  - [Dependencies as data](#dependencies-as-data)
  - [Looks checked when building](#looks-checked-when-building)
  - [Look errors](#look-errors)
- Layouts
  - [Layouts: a type as bytes](#layouts-a-type-as-bytes)
  - [Placing fields](#placing-fields)
  - [Byte order](#byte-order)
  - [What a field can be](#what-a-field-can-be)
  - [Variable-length and tagged formats](#variable-length-and-tagged-formats)
  - [Reading: `view`](#reading-view)
  - [Writing](#writing)
  - [Errors carry offsets](#errors-carry-offsets)
  - [Versions](#versions)
  - [Arrays of records in a page](#arrays-of-records-in-a-page)
  - [Checked when building](#checked-when-building)
  - [Layer 1: the derived encoding](#layer-1-the-derived-encoding)
  - [Layer 3: raw bytes](#layer-3-raw-bytes)
  - [Where formats stop](#where-formats-stop)
  - [Compiler errors](#compiler-errors)
- [How looks compile](#how-looks-compile)
- [Tools over looks](#tools-over-looks)
- [std's policy for looks](#stds-policy-for-looks)
- [Left out](#left-out)
- [Later](#later)
- [Open](#open)
- [Evidence](#evidence)

## What it has to do

1. **Records keep no layout promise.** foundations.md's rule stands:
   the programmer never holds an address, so representation is the
   compiler's choice. That's what lets it reorder and pack fields,
   unbox values, and store a `Table` as columns. Nothing here may take
   that back.
2. **Zero copies.** A storage engine reads a header out of a page, and
   writes one field of it, without decoding the page. It costs a load,
   as TigerBeetle's structs over buffers do.
3. **The layout is written once, and the compiler checks it.** Sizes,
   gaps, overlaps and byte order are build errors, not conventions.
4. **Malformed input is an error with an offset,** never a wrong
   answer, and checked once, at the boundary.
5. **Formats evolve,** and a format already written to disk can't be
   changed by accident.
6. **An omakase default and sharp tools.** Most programs never think
   about bytes. Those that must get a declared layout, and below that,
   raw bytes. Each layer is complete; you go down one only where the
   one above doesn't fit.
7. **It stops before it's a language.** Kaitai Struct, Spicy and
   Construct each grew expressions, offsets that point elsewhere, and
   backtracking, until each was a language of its own.

## The problems

Grounded in the programs Ren is for ([vision.md](vision.md#what-ren-is-for)):

| Program | The bytes |
|---|---|
| A storage engine | page headers; slotted pages, a table of offsets and variable-length records; log records, length-prefixed and checksummed; SSTable blocks; B-tree nodes in pages; a superblock. Read without copying, one field written in place. |
| A server | protocol framing: Postgres's wire protocol, HTTP/2 frames, DNS. Length prefixes, flags in bits, big-endian. A json API whose names, tags and versions aren't the type's. |
| A command-line tool | file headers: zip, PNG, ELF. Flags and environment variables named for users, not for the code. |
| Interop | a C struct across a foreign call, in `trust` only. |

## Three layers: a default, then sharper tools

| Layer | What you write | For | Promises |
|---|---|---|---|
| **1. Derived** | `bin.encode(order)`, `try json.decode<Order>(text)` | the type's default look, walked by a library: messages between your own processes, caches, an API that follows the type | nothing about layout, and nothing across versions of a type |
| **2. Declared formats** | `format disk for PageHeader = ...`, `format v1 for Order = ...` | layouts for bytes you own or must match; looks for values a library writes another way | a layout: byte order, validation, versions. A look: names, tags, conversions, versions |
| **3. Raw bytes** | `b.u32_le(at)`, bit operations, slices | what layer 2 deliberately doesn't do | what you write |

A layout compiles to layer 3's calls, and `ren explain` shows them, so
it's one mechanism with a declaration over it, not two.

**The two families in prior art,** and why Ren takes one:

- **Cast the bytes to a struct**, so the struct's layout is the format:
  Zig's `extern struct` and `bytesAsValue`, Rust's zerocopy and bytemuck,
  Swift's `RawSpan.load(as:)` (whose proposal says those layouts "are
  not guaranteed to be stable"). That's the C-struct promise Ren
  refuses.
- **Generate accessors at offsets**, so the format is separate from the
  type in memory: OCaml's cstruct, SBE's flyweights, Cap'n Proto,
  FlatBuffers. An accessor inlines to a plain load, so it's as fast.

**Ren takes accessors, never casts.**

## A type, and its formats

**A type says what a thing is. A format says how it looks somewhere.**
A format is declared apart from its type and named through it:
`PageHeader.disk`, `Time.unix`, `Order.v1`. A type can have several.

There are two kinds, written with one declaration:

| Kind | What it has | Who reads it | Example |
|---|---|---|---|
| **Layout** | byte order, widths, offsets | the format itself: `view`, `edit`, `write`, `encode` | `format disk for PageHeader, le, size 32 =` |
| **Look** | names, tags, conversions; no byte order, no widths | any library, through a shape | `format v1 for Order =` |

- **The kind is read off the lines.** A line with a field kind from
  "What a field can be" (`UInt16`, `Bytes[16]`, `CStr`, `le`) makes a
  layout. A line with only names, looks and constants makes a look. A
  format that mixes them is a build error that names one line of each.
- **Looks and layouts are values.** `Time.unix` is a value of type
  `Look`; `PageHeader.disk` is a value of type `Layout`. They can be
  stored in a settings record, put in an array, compared with `==`,
  and passed between functions. A library's settings take
  `Array<Look>`, so passing a layout there is an ordinary type error.
  How a `Look` is represented is the compiler's
  ([How looks compile](#how-looks-compile)); no program sees it, and no
  closure is stored (README, "No stored closures").
- **A look can be declared in any module, for any type it can name.**
  It's an item of the module that declares it, private unless marked
  `pub format`, and it's reached through the type wherever it was
  declared: `Time.unix`. A `pub` look may name only `pub` functions.
  Naming a private look from outside is "`Money.raw` is private to
  `money`". Otherwise a look declared next to a type could hand any
  program a private constructor.
- **Two looks of one name for one type in scope is an error at the
  import,** whose help says to rename one
  ([Look errors](#look-errors)).
- **A format's name shares its type's namespace.** `Time.unix` can't be
  both a look and a method. Same rule as `Users.x` in the README: one
  name, one meaning.
- **There are no standalone formats.** A format with no type would be
  an ad hoc struct or an ad hoc record, a second kind of record.
- **A type with no look still has one: its default.** That's its
  `parse` and `repr` if it has them, else its structure
  ([shapes.md, "The walk"](shapes.md#the-walk)). So most types never
  declare a look. A look is for "this type looks different here".

Effect v4 found the same split by accident: `Schema.toCodecJson` walks
a schema, and its binary codec (`SchemaBinary`) walks the same schema's
encoded side. Ren separates them on purpose: a layout promises bytes,
a look promises names.

**Who owns what.** Every rule here sits under one owner, by decision
20's five rules:

| Owner | What it holds | Where |
|---|---|---|
| **Language** | the `format` declaration: layouts, and a look's names, subsets, constants, `via` conversions, tags as typed distinct constants, `reads` and `writes`; `Look` and `Layout` as values; `T.shape`, the walk and its doors; build-time checks; `D.Call`, `D.Reply`, `D.Error` and errors on a dep's header | from here through [Compiler errors](#compiler-errors); [shapes.md](shapes.md#the-walk) |
| **Compiler** | how a look is represented, perfect hashes for constant matches, specialization. None of it changes meaning | [How looks compile](#how-looks-compile) |
| **Toolchain** | `ren explain`, freezing, generated round-trip tests. They read the language, never a library | [Tools over looks](#tools-over-looks) |
| **std** | json's sums, casing, `null` and numbers; strictness; first error or all; text media's names; http's routes, statuses, headers and bodies; `Secret`; `Unavailable` and `Why`; the envelope and transports | [std's policy for looks](#stds-policy-for-looks) |

The language owns reshaping; libraries own spelling. No language rule
below names a medium. Where an example uses json or http, it's the
library reading a look, and the rule it shows is std's.

## Looks of a scalar: `via`

```ren
format unix for Time = Int via (Time.from_unix, fn(t) => t.unix_seconds())
format cents for Money = Int via (Money.from_cents, fn(m) => m.cents())
format base64 for Bytes = Str via (base64.decode, base64.encode)
```

- **`X via (read, write)`** says "seen as an `X`". `read` is
  `X -> T ! E`. `write` is `T -> X`, or `T -> X ! E` when some values
  have no `X` (a v1 that can't carry v2's `ttl` fails `NotInVersion`).
  Either error reaches the caller as `Invalid(at, why)`, with the
  error's tag as `why`.
- **A look can go one way.** `reads` takes `via (read)` and can't
  encode; `writes` takes `via (write)` and can't decode. Using one in
  the wrong direction is a build error at the use. This is a layout's
  `reads`, plus its mirror. `format text for Bytes = Str via
  (Str.bytes), reads` is a complete look; it needs no write function.
- **`X` is what gets read,** the encoded side, written once. It's
  walked by the same rules as any type, so it can be a record, a sum,
  or a type with its own look. There's no second type parameter, and
  no `Type` and `Encoded` spelled out as Effect has them. A record or
  sum look's encoded side is its lines.
- **Both functions are pure.** A `via` with a `uses` row is a build
  error. A look runs inside decoders, at build time in checks, and in
  generated tests; reaching the world there would be invisible.
- **Looks chain.** If the call also chooses a look for `Int`, the `Int`
  side of `Time.unix` goes through it. A chain that comes back to its
  start is a build error.
- **A look may keep less than its type.** `Time` holds nanoseconds and
  `unix` keeps seconds. Nothing marks it: the generated test checks
  that the wire form is stable, which such a look passes
  ([Tools over looks](#a-round-trip-test-per-look)).

## Looks of a record: lines

A record look uses a layout's line form. Each line says where one name
in the look comes from:

```ren
type Order = {
  id: OrderId,
  customer: CustomerId,
  lines: Array<Line>,
  total: Money,
  placed: Time,
  note: Option<Str>,
  source: Source = Web,
  audit: Audit = Audit.none,
}

format v1 for Order =
  kind = "order"                  // a constant: written, and checked on read
  id                              // the field as itself
  customerId = customer           // renamed
  total: Money.cents              // through a look
  placedAt = placed: Time.unix    // renamed, through a look
  ..                              // the rest as themselves: lines, note, source, audit
```

| Line | Means |
|---|---|
| `id` | the field `id`, by its own name, walked by the call's choices |
| `customerId = customer` | the field `customer`, under the name `customerId` |
| `total: Money.cents` | the field `total`, through the look `Money.cents` |
| `placedAt = placed: Time.unix` | both |
| `kind = "order"` | a constant: written going out; coming in, missing is `Missing`, different is `Invalid` |
| `"@type" = "Order"` | a name that isn't an identifier is a string |
| `..` | every field not named above, as itself |

- **`=` has one meaning: the look's name is on the left.** The token on
  the right says what it is, with no lookup: a lowercase identifier is
  a field of the type; a literal or an uppercase constructor is a
  constant. A lowercase identifier that names no field is a build
  error. There's no `field = value` form in looks; a `reads` layout
  keeps it ([Versions](#versions)).
- **Without `..`, the look lists exactly what it carries.** A field it
  leaves out must have a default or be an `Option`, else it's a build
  error. Coming in, a left-out field gets its default or `None`. Going
  out, it isn't there. A value an old version lacks that has no
  default is a `via` to a wire type.
- **There are no defaults in a look.** Coming in, a field gets the
  default its constructor uses, filled at the door, and nothing else.
- **A `writes` look is a subset.** It can leave out any field, because
  nothing is read back: `format public for User, writes = id, name`
  hides `email` and `password_hash` wherever it's used. Using it to
  read is a build error.
- **A name written in a look is marked exact** in the shape. What a
  library does with that mark (json's casing leaves exact names alone)
  is the library's.
- **Every name is written once.** Two lines giving one name, or a
  rename that lands on a name `..` also produces, is a build error.
- **No flattening, no nesting by path, no computed fields.** A field is
  carried, renamed, looked, or left out; a constant is a literal. A
  look that needs more is a `via` to a record written for the wire.
  That's a layout's rule too: a format is what a spec's tables say.

## Looks of a sum: tags

```ren
type Event =
  | Placed { order: Order, by: UserId }
  | Cancelled { id: OrderId, reason: Str }
  | Refunded { id: OrderId, amount: Money }

format v1 for Event.Placed =
  orderId = order: Order.v1
  ..

format v1 for Event =
  | Placed as "order.placed": Event.Placed.v1
  | Cancelled as "order.cancelled"
      orderId = id                // lines under a case reshape it in place
      reason
  | ..
```

- **`| Case as tag`** gives a case its tag. Without `as`, the tag is
  the case name as written, a `Str`.
- **A case is reshaped in one of two ways.** `: Look` names a look of
  the variant type, `Event.Placed` (language.md §2, "Variant types").
  Lines indented under the case reshape it in place, in a record look's
  line form with all its rules: renames, constants, looks on fields,
  `..`, and listing exactly what it carries without `..`. A case has
  one or the other, or neither, and then carries its fields as
  themselves. Lines suit a one-off; a named look suits a case reshaped
  the same way in several looks.
- **`| ..`** is the rest of the cases, as themselves. Without it, every
  case must be listed: a value of an unlisted case would have nowhere
  to go.
- **A tag is a typed constant.** All tags in one look have one type,
  which the look's tags decide: `"order.placed"` is a `Str`, `404` an
  `Int`, `GET"/v1/keys/\{key}"` an `http.Route`. The language checks
  the type. Which tag types a library reads is that library's check
  ([Looks checked when building](#looks-checked-when-building)).
- **Tags are distinct in a look that reads.** A reader picks a case by
  its tag, so two cases with one tag are a build error. A `writes` look
  may repeat a tag, because nothing reads a case back by it. That's
  the whole rule; a library that wants repeats (http's statuses) uses a
  `writes` look.
- **A tag may have holes that name the case's fields.** In a tag
  written with a value prefix, `\{key}` is the case's field `key`, as a
  bare name in a look always is a field. The language checks each hole
  names a field and gives the library the tag's parts. What the parts
  mean is the library's: http reads them as a route, and a sql or topic
  library could read them its own way.
- **The look says which tag a case has, not where the tag goes.** A tag
  field's name, an adjacent payload, or no tag at all are a library's
  spelling. The shape carries each case's tag and fields; nothing more.

**`as` in three places.** In a pattern, `as` binds a name. In a layout,
`lsn: UInt64 as Lsn` reads the integer through `Lsn`'s constructor. In
a sum look, `| Placed as "order.placed"` gives a case its tag. Each
reads "seen as", and the position says which.

## Looks of an opaque type: always a function

**An opaque type is only ever read through a function.** Its looks are
all `via` looks, inside its module or out:

```ren
pub type Money = opaque Int with numeric
  pub fn parse(s: Str) -> Money ! BadAmount = ...     // "12.50": the default look
  pub fn repr(self) -> Str = ...
  pub fn from_cents(c: Int) -> Money ! BadAmount = ...
  pub fn cents(self) -> Int = self

format cents for Money = Int via (Money.from_cents, fn(m) => m.cents())
```

- **Outside its module,** a look of an opaque type can use only what
  any code there can: its `pub` functions. So a look never exposes more
  than the public API. `..`, field lines and naming a private function
  are build errors: "`Money` is opaque here; read it through a
  function".
- **Inside its module,** a `via` may call private functions, and then
  the look is private too ([above](#a-type-and-its-formats)). So
  `format raw for Money = Int via (Money.unchecked, ...)` exists only
  inside `money`. It still can't be a record look over the
  representation: reading must go through a constructor that keeps the
  type's rules, or input from outside could build a value the module
  never allows.
- **An opaque record looks like a record through a wire type:**

  ```ren
  type OrderWire = { id: OrderId, lines: Array<Line>, total: Money }
  format v1 for Order = OrderWire via (Order.from_wire, fn(o) => o.to_wire())
  ```

  This costs a declaration. It's the same cost a layout's `as` pays for
  `lsn: UInt64 as Lsn`: a conversion that can fail is visible.

## What a look can expose

- **A type without `repr` can be read but not written** by the walk.
  Writing one where no look writes it fails at the door, with the path
  ([shapes.md, "The doors"](shapes.md#the-doors-build-and-view)).
- **A look exposes exactly what the public API exposes, no more.** If a
  `pub` function gives a value out, a look over that function can
  write it. Making that a named look in a settings record is how a
  library makes an exposure visible ([`Secret`](#secret)).

## Errors carry paths

The doors that read through a look fail with one shared set, in the
`shape` module the language provides beside `T.shape`:

```ren
pub type Problem = ! Missing(at: Str, field: Str)
                   | Unknown(at: Str)
                   | Mismatch(at: Str, expected: Str, found: Str)
                   | Invalid(at: Str, why: Str)
                   | NoCase(at: Str, tag: Str)
                   | TooDeep(at: Str, limit: Int)
```

- **`at` uses the look's names,** the ones in the input:
  `"orders[2].customerId"`. That's what the sender can fix.
- **`field` names the type's field,** `"Order.customer"`, for the
  programmer. `show` prints both:
  `orders[2].customerId (Order.customer): missing`.
- **The input isn't kept.** A `Mismatch` says `found: "a string"`, not
  the string, because it may be a secret. There's no switch.
- **The doors can stop at the first problem or collect all.** It's a
  parameter of `build<T>`. Which one a library uses by default is its
  policy.
- **`Unknown` and `TooDeep` are raised by libraries,** which share the
  tags so every library spells them one way. When a library raises
  them is its policy.
- **A library adds its own tags around `Problem`** (a syntax error with
  a byte offset, a limit). Layouts keep `FormatError`, with offsets;
  its `path` uses the same spelling.
- **A named error set has a shape, as the `Err` side of a `Result`.** A
  look may be `for` a named error set (`Keys.Error`, `Problem`).
  Writing one takes the `Err` of a `Result`; reading one yields
  `Err(tag)` inside a `Result`, never a free tag. This keeps
  [errors.md](errors.md#tags-are-structural)'s rule: an error is a
  value only inside a `Result`, and an error set is never a sum type.

## Versions are looks

```ren
format v1 for Order, reads =
  id
  total: Money.cents
  ..

format v2 for Order =
  id
  total                 // through Money's own parse/repr now
  ..
```

- **A version is another look of the same type,** as a layout has
  another format. No second type, no conversion functions.
- **`reads` forbids writing.** Unlike layouts, several looks of one
  type may be writable, so a program can answer each reader in its
  version. Mark `reads` when a version must never be produced again.
- **A field an old look lacks** gets its field default or `None`, the
  same rule as any left-out field. A field with neither is a `via` to a
  wire type.
- **A write a version can't express fails; it's never trimmed.** The
  version's `via` writes `T -> X ! E`, so a v1 with no place for v2's
  `ttl` fails `NotInVersion` rather than dropping it. How a protocol
  reports that is std's ([Remote failure](#remote-failure-unavailable-and-why)).
- **Choosing a version is code you can see:** a value holding the
  version's looks, picked by a `match`.
- **What gets frozen** is in [Tools over looks](#tools-over-looks).

## Dependencies as data

For each dependency `D` the compiler writes three declarations, so a
dependency's operations are data any library can read (decision 20,
rule 3: the program's declarations as data).

```ren
use std.remote.Unavailable

pub dep Keys ! Unavailable =
  get: fn(key: Key) -> Bytes ! NotFound
  put: fn(key: Key, value: Bytes, expect: Option<Version>) -> Version ! Conflict
  list: fn(prefix: Str = "", limit: Int = 100) -> Array<Key>
```

- **`D.Call`** is a sum with one case per operation, its parameters as
  fields, their defaults as field defaults.
- **`D.Reply`** is a sum with one case per operation, holding its
  result; fieldless for `()`.
- **`D.Error`** is a named error set: the union of every operation's
  errors and the header's.
- **They're ordinary data.** They have shapes, default looks, `==`,
  `show` and generators, and looks may be declared for them like any
  sum. [language.md §6](language.md#6-stored-descriptions-an-enum-the-compiler-writes)
  says so: they're data enums the compiler writes, not opaque
  descriptions.
- **`D.Call` exists only if every operation is data:** no block, no
  `&`/`inout` argument, no view, a data result. That's decision 18's
  rule for `post`, stated once. Naming `D.Call` for any other dep is a
  build error naming the operation.
- **Errors on the header.** `pub dep Keys ! Unavailable =` says every
  operation can also fail with `Unavailable`. It's the form
  `Actors<DocId, Doc> ! StoreDown` already has. `ren types Keys` shows
  it on each operation, and a handler for `Keys` must fit it as it fits
  any declared error. The language gives "errors on the header";
  what `Unavailable` is, is std's.
- **A handler `over D` for an all-data `D` may write `call(c: D.Call)`**,
  and `next.call(c)` is `D.call(c)` against the next handler. This sits
  beside `over any`'s `call =>`, which stays as built: it covers every
  dependency, data or not, and it carries the journal
  ([shapes.md](shapes.md#handlers-that-work-for-any-dependency)).

## Looks checked when building

**One mechanism.** Every build-time check runs through top-level `let`
and `assert`, or a signature `let`: a `let` between a function's
signature and its `=`, run while building once per call site
([strings.md, Templates](strings.md#templates)). The language writes no
check for one library. Two groups:

**Checked on the declaration, by the language.** Each is a build error
with a fix-it:

- a format that mixes layout lines and look lines;
- a look named like a method of its type; two looks of one name for
  one type in scope;
- a field left out of a look with no default and not an `Option`
  (except in a `writes` look);
- two lines giving one name; a lowercase right side that names no
  field;
- a `via` whose functions don't have the types `X -> T ! E` and
  `T -> X` (or `T -> X ! E`), or that has a `uses` row;
- a chain of `via` looks that comes back to its start;
- a sum look missing a case, without `| ..`; a case with both lines and
  a `: Look`;
- tags of more than one type in one look; two cases with one tag in a
  look that reads; a hole that names no field;
- a look of an opaque type that isn't a `via`;
- a private look named outside its module; a `pub` look that names a
  private function;
- a `reads` look used to write, a `writes` look used to read;
- naming `D.Call` for a dep with an operation that isn't data.

**Checked where a type meets its looks, once per call site.**
`shape.through<T>(looks)` fails, with a `LookError`, on two looks for
one type in the list, an opaque type the walk can't read, and a type
with no `repr` that the list doesn't write. A library calls it in a
signature `let`, so `json.decode<Order>(text, API)` checks `Order`
against `API` while building, at that call. A library's own checks
(tag types it reads, its casing collisions, its route overlaps) are
code in that library, run the same way.

- **So a settings record must be known while building:** a literal, or
  a top-level value. Settings known only at run time are a build error
  at the call, whose help says to bind them with a top-level `let`.
- **A top-level `let` checks too.** `let KEYS_V1 =
  http.mount<Keys>(...)` fails the build if http's check fails, like
  any top-level failure.

## Look errors

```
error: `customer` is left out of `public`, has no default, and isn't an `Option`
  format public for Order =
    id
    total
  = a look lists what it carries; reading it back must build an `Order`
  help: carry `customer`, add `..`, give it a default in `Order`,
        or mark the look `writes`
```

```
error: `Money` is opaque here; a look of it reads it through a function
  format v1 for Money =
    cents
  help: `format v1 for Money = Int via (Money.from_cents, fn(m) => m.cents())`
```

```
error: `PageHeader.disk` is a `Layout`; this field is an `Array<Look>`
  let J = json.settings(formats: [PageHeader.disk])
  help: a layout is read with `PageHeader.disk.view(bytes)`
```

```
error: `v1` of `Event` has no tag for `Refunded`
  help: add `| Refunded as "..."`, or `| ..` for the rest as themselves
```

```
error: `Time.from_unix` uses `Clock`; a look's functions are pure
```

```
error: `Get`'s tag has a hole `\{id}`, but `Keys.Call.Get` has no field `id`
  | Get as GET"/v1/keys/\{id}"
  help: did you mean `\{key}`?
```

```
error: two looks named `unix` for `Time` are in scope
  use wire
  = `wire` declares `format unix for Time`, and so does `time`
  help: rename one of them, e.g. `format unix_seconds for Time` in `wire`
```

```
error: json checks `Order` against its settings while building, and these are known only at run time
  json.decode<Order>(text, settings_for(cfg))
  help: bind the settings with a top-level `let`: `let API = json.settings(...)`
```

Errors a library raises read the same way, but are written by the
library: `customerId` written twice after json's casing,
`Keys.Error.rest` missing a status ([std's policy](#stds-policy-for-looks)).

## Layouts: a type as bytes

**A layout says how a type looks as bytes:**

```ren
type PageHeader = { lsn: Lsn, count: Int, kind: PageKind }
type PageKind = | Leaf | Branch

format disk for PageHeader, le, size 32 =
  magic: UInt32 = 0x52454E31       // a constant: checked on read, written on write
  checksum: Bytes[16]               // the format's own field, not the type's
  lsn: UInt64 as Lsn                // the type's field, placed
  count: UInt16                     // narrower than the type's Int
  kind: UInt8 { Leaf = 1, Branch = 2 }   // tag numbers live in the format
  _: reserved(1)                    // zero: checked on read, written on write
```

- **A field named like one of the type's is placed.** Everything else,
  constants, checksums, reserved bytes, lengths, counts and tags,
  belongs only to the format. The domain type never mentions bytes.
- **Tag numbers live in the format.** A domain enum has no wire numbers,
  and a second format can number it differently.
- **Several formats of one type** cover versions (`v1`, `v2`), disk and
  wire (`disk`, `wire`), and migrations, as "another format of the same
  type" rather than a second type with conversions between them. A
  format is named through its type: `PageHeader.disk`.
- **The cost is two declarations to keep in step.** Every field placed
  is checked against the type, so a mismatch is a build error, not a
  drift.

Prior art: Ada's record representation clauses sit apart from the type,
and Ada RM 13.6 converts between two representations of one type for
you, which is this idea forty years earlier. serde's `remote` and
`with`, binrw's versioned fields, and Haskell newtypes each with its
own `Binary` instance are the same idea in parts.

A format can be declared inside a function, beside the code that uses
it, as Erlang's matches sit beside theirs.

## Placing fields

- **Fields go in the order written.** That's the one way to place them,
  and it's what makes variable-length fields work.
- **`at N` is a checked note.** Copy a spec's table in, `lsn: UInt64 as
  Lsn at 20`, and the compiler confirms the field starts there.
- **`size N` on the format line means every byte belongs to a field.**
  A gap is an error whose fix-it adds `reserved`, and an overlap is an
  error that names both fields. That's TigerBeetle's `no_padding`
  assert, built in. A format with variable-length fields has no `size`.
- **`_: reserved(n)`** is `n` bytes that must be zero: checked on read,
  written as zero.
- **Alignment is the compiler's.** Loads are unaligned in principle and
  aligned where the compiler can prove it, so alignment never appears
  in a program.

## Byte order

**Every field wider than a byte has a byte order, and it's always
written.** `le` or `be` on the format line, overridable on a field:

```ren
format frame for Frame, be =
  len: UInt24
  kind: UInt8
  stream: UInt32
  trailer: UInt32 le          // one field the other way
```

There's no default and no machine order. Machine order exists only in
`trust`, for C interop.

Why: deku defaults to the machine's order, which is wrong exactly where
you can't test it on x86. Erlang defaults to big-endian, so every
little-endian format repeats `/little` on every field. Kaitai, binrw
and Zig make you say it, and nobody complains.

## What a field can be

A closed set:

| Field | Bytes | In the type |
|---|---|---|
| `UInt8` ... `UInt64`, `Int8` ... `Int64`, `UInt24` and other widths | fixed, with a byte order | a sized or plain integer |
| `F32`, `F64` | fixed, with a byte order | `Float` |
| `VarUInt`, `VarInt` | LEB128, zigzag for signed | an integer |
| `Bytes[n]` | `n` bytes | `Bytes`: a slice, no copy |
| `CStr`, `Str[n]` | zero-terminated, or `n` bytes, UTF-8 | `Str`: a slice, no copy, checked once |
| `Array<F>[n]` | `n` of format `F` | `Array` |
| `T.fmt` | a nested format of another type | that type |
| `UInt8 { A = 1, B = 2 }` | a tag for a fieldless enum | the enum |
| bit fields | inside one integer | integers or `Bool`s |

- **An integer narrower than the type's field** widens on read, which
  always fits, and is checked on write, as storing into a sized integer
  is ([README](README.md)): a value that doesn't fit panics, because
  it's a bug in the data, not in the input.
- **An opaque type is placed with `as`:** `lsn: UInt64 as Lsn`. The
  bytes are the integer; on read, the type's own constructor runs on
  it, so the type's invariants hold, and a value it refuses is
  `Malformed`. The conversion is written because it can fail, and a
  conversion that can fail is visible. The members it uses are the
  ones shapes.md's opaque shapes say a type is built by.
- **Bit fields** are listed from the most significant bit and must add
  up to the integer's width:

  ```ren
  format dos for DosTime, le =
    packed: UInt16 bits
      hour: 5
      min: 6
      sec2: 5
  ```

## Variable-length and tagged formats

The same declaration covers them. A sum type's format has a tag field
and a `case`:

```ren
type PgMessage =
  | Query(sql: Str)
  | Parse { name: Str, sql: Str, oids: Array<Oid> }
  | Terminate
  | Other { kind: UInt8, body: Bytes }

format wire for PgMessage, be =
  kind: UInt8                      // the tag
  len: UInt32                      // counts itself
  case kind
    'Q' => Query(sql: CStr)
    'P' => Parse { name: CStr, sql: CStr, n: UInt16, oids: Array<UInt32 as Oid>[n] }
    'X' => Terminate
    _   => Other { kind, body: Bytes[len - 4] }
```

- **A field that's a tag, a length or a count is never written by
  hand.** Writing `Query("select 1")` fills in `'Q'` and `len`. It's
  binrw's `calc`, made automatic, and it removes Kaitai's worst pain,
  where serializing means setting every length yourself.
- **So sizes must be invertible:** a field, plus, minus or times a
  constant. `Bytes[len - 4]` is fine; `Bytes[len * len]` is an error,
  because writing couldn't work `len` out.
- **A count or length comes before what it sizes.** One that comes
  after is an error with a fix-it that moves it.
- **Unknown tags are a choice you write.** With a `_` arm they become a
  variant of the type (`Other`). Without one, reading fails with
  `UnknownTag`, and the compiler notes that and offers the arm.
- **Exhaustiveness lives on the type,** after the format decoded it. No
  tool studied can make a byte tag exhaustive, since a `UInt8` has 256
  values and a protocol defines a few. `match` on the decoded
  `PgMessage` is Ren's ordinary exhaustive `match`, with its errors
  that print the missing arms.

**No byte patterns in `match`.** Erlang's bit syntax is loved, but the
formats *are* the patterns, and a second pattern language for bytes
would break "one mechanism per question". Erlang's real wins, zero
copies and a cursor reused in place, Ren gets from slices and Perceus,
without Erlang's invisible optimizations (OTP ships a compiler flag
just to report where they silently fail) and without its `badmatch`
that says nothing about where the input went wrong.

## Reading: `view`

```ren
let h = try PageHeader.disk.view(page[0..32])
h.lsn          // a load: can't fail
h.value        // the whole PageHeader, in the compiler's layout
h.rest         // the bytes after the format
```

- **`view` is the one way in.** It checks once: the length, constants,
  tags, reserved bytes, UTF-8 in `Str` fields, and what `as`
  constructors refuse. That's FlatBuffers' verify-once and zerocopy's
  `TryFromBytes`. After it, **reading a field can't fail** and costs a
  load.
- **A view is a value:** a slice and a format, small, kept inline in
  records and arrays, counting its root like any slice (decision 17).
  It can be stored and returned. It keeps its whole buffer alive, as a
  slice does; `copy()` the slice first to keep only the view's bytes.
- **`.value` decodes everything** into the type. There's no separate
  `decode`, which would be a second way.
- **`.rest` is the slice after the format,** so reading a stream is a
  loop on `rest`, and keeps Erlang's brevity:

  ```ren
  fn extras(b: Bytes) -> Array<Extra> ! FormatError =
    var out: Array<Extra> = []
    var rest = b
    while rest.len() > 0
      let e = try Extra.zip.view(rest)
      &out.push(e.value)
      rest = e.rest
    out
  ```

- **Fields that belong only to the format** are read from the view,
  `h.checksum`, and aren't in `.value`.
- **Checksums are ordinary code,** never syntax: `h.checksum ==
  aegis(page[16..])`. They often cover bytes outside the format, as
  TigerBeetle's body checksum does, and check order is the program's
  (TigerBeetle: header checksum, command, size, body checksum).

## Writing

```ren
try PageHeader.disk.edit(&page[0..32]) fn(&h) =>  // checked as `view` checks
  h.lsn = next_lsn                                // one field, in place
try PageHeader.disk.write(&page[0..32], header)   // the whole value
let bytes = PgMessage.wire.encode(msg)            // a new buffer
```

- **One field, in place, in a block.** `edit(&page[a..b]) fn(&h) =>`
  checks the bytes as `view` does and gives the block a view it can
  write, as `split_at` gives a block its ranges (decision 17). The
  `&` lasts the call, so the borrow ends with the block, as every `&`
  does: a writable view is never stored or returned, and no exclusivity
  rule changes. A view kept as a value is for reading only.
- **A read view kept while its page is written copies the page.** The
  view counts the page's buffer, so the buffer is shared, and value
  semantics copies it before the write. That's correct and silent, so
  debug builds report it where it happens, as they report roots kept
  alive by small slices. Let the view go first, or read through
  `edit`.
- **`write(&buf[a..b], v)`** writes every field, with constants, tags,
  lengths, counts and reserved bytes filled in, into a buffer allocated
  earlier, and returns how many bytes it wrote. It fails with
  `TooSmall(need: Int)`.
- **`encode(v)`** allocates a `Bytes` of the right size and writes it.
- **A format-only field that isn't a constant, a tag, a size or
  reserved,** such as a checksum, is written as zero and set through
  the view afterwards, as TigerBeetle computes its checksum last.
- **A view made with `view` is read-only.** Writing through one is an
  error whose help writes the `edit` block.

## Errors carry offsets

Reading fails with one error set:

```ren
pub type FormatError = ! Short(at: Int, need: Int)
                       | Malformed(at: Int, path: Str, why: Str)
                       | UnknownTag(at: Int, tag: Int)
```

- **`at` counts from the start of the bytes given to `view`,** or from
  the base it was given: `T.disk.view(page, from: page_no * 4096)`
  reports offsets in the file. A cursor takes the same base,
  `b.cursor(from: n)`. Counting from the root a slice was cut from
  would depend on which buffer the bytes happen to be in, a leased
  chunk, a joined one or the interpreter's copy, and on every layout
  the compiler chooses ([strings.md](strings.md#positions)).
- **`at` is for reports, never for indexing.** It goes in a message or
  a log. Code that indexes the buffer with it works while the base is
  0, as in every test, and reads the wrong bytes once it isn't. To
  reach bytes, use the view or the cursor.
- **`path`** follows shapes.md's: `"Parse.oids[2]"`.
- **`Short(need)` is what a framing loop needs:** read that much more
  and try again. So no streaming parser is needed:

  ```ren
  try match PgMessage.wire.view(buffered)
    m =>
      handle(m.value)
      buffered = m.rest
    fail Short(_, need) => try conn.read_more(need)
  ```

## Versions

A type has a format per version, and the rules keep old data readable
and new writes lossless:

```ren
format v1 for Superblock, le, size 64, reads =
  ...
  owner = Owner.nobody              // not in v1: what it reads as

format v2 for Superblock, le, size 128 =
  ...
  owner: UInt64 as Owner
```

- **At most one layout of a type is writable.** Older ones are marked
  `reads`. A field of the type that a `reads` format lacks gets `=
  value`, what it reads as. That's SBE's `sinceVersion` turned into
  migration, and it rules out writes that lose data: you can't write a
  `Superblock` through a format that has nowhere to put `owner`.
- **A writable format places every field of its type.** One that
  doesn't is an error whose help places it, or marks the format
  `reads` with a value.
- **Looks differ here.** Several looks of one type may be writable at
  once ([Versions are looks](#versions-are-looks)). What this rule
  guards, a write that loses data, comes there from a `via` that fails
  on write and a fingerprint that covers `via` functions. A look has no
  `field = value` line; in a look, `=` always puts a name on the left.
- **Choosing a version is code you can see:** a `match` on a version
  field, read through a small format of its own or with layer 3.
- **Released formats are frozen.** `formats.lock`, committed beside the
  code like a lockfile, lists each released format and a fingerprint
  of its layout. A format it lists can't change: the build fails, and
  the fix-it adds the next version. `ren formats freeze` adds what's
  new; until then a format is a draft and changes freely. This is
  `buf breaking` for Ren, checked on every build.

How others evolve: Cap'n Proto numbers fields and only appends;
FlatBuffers' tables evolve through vtables while its structs never
can; SBE has `sinceVersion` and a block length old readers skip by;
protobuf keeps tags `reserved`; TigerBeetle reserves zeroed regions,
keeps a version field for breaking changes, and ships several releases
in one binary; FoundationDB refuses a mismatched format version and
branches on the protocol version in its serializer.

## Arrays of records in a page

A slotted page is formats over formats, with layer 3 where the offsets
point:

```ren
type Slot = { off: Int, len: Int }
type Directory = { free_end: Int, slots: Array<Slot> }

format disk for Slot, le, size 4 =
  off: UInt16
  len: UInt16

format disk for Directory, le =
  count: UInt16                     // worked out when writing: slots.len()
  free_end: UInt16
  slots: Array<Slot.disk>[count]

let dir = try Directory.disk.view(page)
for s in dir.slots                  // each a view: s.off is a load
  let r = try Record.disk.view(page[s.off .. s.off + s.len])
  ...
```

`dir.slots` is checked against `count` once, when the view is made.
This isn't a `Table`: a `Table` is the compiler's layout for data in
memory, and a format is a promised layout for bytes.

## Checked when building

- **`PageHeader.disk.size`** and **`PageHeader.disk.offset(lsn)`** are
  shapes ([shapes.md](shapes.md)), so `assert PageHeader.disk.size ==
  32` is checked on every build, as TigerBeetle's comptime asserts are.
  They exist on formats only: a record has no offsets to promise.
- A slice known when building to be shorter than a fixed format is a
  build error; otherwise it's `Short` at run time.
- Gaps, overlaps, missing byte orders, sizes after their use, sizes
  that can't be inverted, bit fields that don't add up, and a changed
  frozen format are all build errors ([Compiler errors](#compiler-errors)).

## Layer 1: the derived encoding

`bin.encode(v)` and `bin.decode<T>(bytes)` are a library over `T.shape`,
written in Ren like `json` ([shapes.md](shapes.md#libraries-that-work-for-any-type)):
compact, specialized in release builds, nothing to declare. It walks
the type through `parse` and `repr`, so opaque types keep their rules,
and it takes no looks: it has no names to rename. `json` and `cli` walk
the same default look, and take looks where a medium wants other names
or tags ([A type, and its formats](#a-type-and-its-formats)).

**It's not for disk.** Its bytes follow the type, so changing the type
changes the encoding, and nothing records what an old version looked
like. That's fine for messages between processes of one build, and for
caches that are thrown away. For anything that outlives the build that
wrote it, write a format. That's a sharp edge, and it's documented
where `bin` is, in its first line, rather than guarded.

**The journal is the exception, and is guarded.** It's derived from
shapes like `bin`, but kept on disk across builds as tests
(`tests/bug.journal`). So its header records a hash of each shape it
encodes, and replaying it against a type that has changed fails before
the first call, naming the type, instead of decoding a value wrong
([testing.md](testing.md)).

## Layer 3: raw bytes

`Bytes` has reads and writes at an offset with the width and byte order
in the name, `b.u32_le(at)`, `b.u64_be(at)`, `&b.set_u16_le(at, x)`, as
Zig's `takeInt` and Go's `binary.LittleEndian` do, and a cursor over a
slice for reading in sequence. With slices, bit operations and
`VarUInt` helpers, that's everything layer 2 compiles to, available
directly.

## Where formats stop

**A format is what a protocol spec's tables say, and nothing more.**
These stay in layer 3, ordinary code with formats for the pieces:

- arbitrary expressions in sizes or conditions;
- references to other offsets: DNS name compression, ELF section
  tables, a zip's central directory found from the end of the file;
- backtracking, and alternatives tried in turn;
- encodings a user defines;
- checksums;
- fields that appear on a condition other than `case`.

## Compiler errors

Each points at the line and has a fix-it:

```
error: `lsn` is a UInt64 with no byte order
  lsn: UInt64 as Lsn at 4
  help: write `UInt64 le`, or `format disk for PageHeader, le`
```

```
error: bytes 30..31 of `disk` belong to no field
  = a format with a `size` accounts for every byte
  help: add `_: reserved(1)` after `kind`
```

```
error: `lsn` covers bytes 20..28 and `count` starts at 26
  help: move `count` to 28
```

```
error: `lsn` is at 8, but the fields before it end at 4
  help: add `_: reserved(4)` to fill the gap, or fix the `at`
```

```
error: `oids` is counted by `n`, which comes after it
  help: move `n` above `oids`
```

```
error: `body: Bytes[len * len]` can't be written back: `len` can't be worked out from the size
  = a size is a field, plus, minus or times a constant
```

```
error: `lsn` is an `Lsn` in `PageHeader`; a format places integers and bytes
  help: place its integer: `lsn: UInt64 as Lsn`
```

```
error: `PageHeader.owner` has no place in `v2`, which can be written
  help: place it, or mark `v2` `reads` with `owner = ...`
```

```
error: `name` is a `Str`, which has no fixed size
  help: `name: CStr`, or `name: Str[n]` with a length field
```

```
error: `kind` has bits 5 + 6 + 4 = 15, but it's a UInt16
```

```
error: `Branch` has no tag number in `disk`
  help: `kind: UInt8 { Leaf = 1, Branch = 2 }`
```

```
error: `v1` is frozen at 32 bytes and is now 36 (`owner` was added)
  = formats.lock lists it: data on disk was written with it
  help: add `format v2 for PageHeader` and mark `v1` `reads`
```

```
error: `h` is a view for reading
  h.lsn = next_lsn
  help: write it in a block: `try PageHeader.disk.edit(&page[0..32]) fn(&h) => h.lsn = next_lsn`
```

```
note: `wire`'s `case` has no `_`, so an unknown tag fails with `UnknownTag`
  help: add `_ => Other { kind, body: Bytes[len - 4] }` to keep them
```

And through shapes.md, `assert PageHeader.disk.size == 32` failing
names the format and its size.

## How looks compile

The compiler's part. None of it changes what a program means; a debug
build means the same, slower.

- **A `Look` is represented as the compiler likes.** In a closed world
  the compiler knows every `format` in the program, so it can number
  them: an enum it writes, one tag per format. A `via` runs inside its
  tag's arm and is never stored. Debug builds `match` on the tag (or
  point at a static record, as `Handler_tag` does); release builds use
  a number. No program sees which.
- **A look declared outside its type's module** is keyed by the type
  and the module that declares it. Members of a type from another
  module don't exist in the compiler today (research/looks/feasibility.md).
- **A `match` over constant tags compiles to a perfect hash.** That
  covers a reader picking a case by its tag and a library matching
  route strings. A reader never tries each case (Effect v4's
  `SchemaAST.ts` union candidates do the same lookup).
- **Specialization over known looks.** Settings are known while
  building, so release builds copy a library's walk per (type, looks)
  into straight-line code. That's two steps: a constant argument in
  specialize.ml's key, then unfolding the library's `match` over a
  constant shape (stage 12's risk 2). See
  [shapes.md, "How the walk compiles"](shapes.md#how-the-walk-compiles).

## Tools over looks

The toolchain reads the language, never a library, so each tool serves
every library alike.

- **`ren explain`** prints, per field, the look's name, the encoded
  type and the walk step that chose it
  ([shapes.md, "Seeing the walk"](shapes.md#seeing-the-walk)).
- **Freezing** fingerprints what a top-level value sends
  ([shapes.md, "Freezing what is sent"](shapes.md#freezing-what-is-sent)).
- **A round-trip test per look,** below.

### A round-trip test per look

`ren test` runs one generated property per look, with no test written:

```
look Order.v1: 1000 values, wire form stable
look Time.unix: 1000 values, wire form stable
```

- **The values come from the type's generator** ([testing.md](testing.md),
  "Every type generates itself"), so only values the module allows.
- **It checks that the wire form is stable:** write a value, read it
  back, write it again, and the second write equals the first,
  `encode(decode(encode(x))) == encode(x)`. It goes through the doors,
  `view<T>` and `build<T>`, not through a library, so it tests the look
  itself: renames, constants, tags and both `via` functions. Libraries
  test their own syntax.
- **It holds for every look,** one that keeps less than its type
  included. `Time.unix` drops sub-seconds and passes: the seconds it
  writes read back as a `Time` that writes the same seconds. A `via`
  whose two functions disagree (`from_unix` reading milliseconds)
  fails, with the shrunk value.
- **Exact equality is your own property.** Where a look must keep
  everything, `decode(encode(x)) == x` is a one-line test you write.
- **A one-way look gets a one-way test.** A `reads` look is fed what
  the type's default look writes, through the look's own encoded shape;
  a `writes` look is checked to never fail on a generated value unless
  its `via` declares an error.
- **A failure prints the value, the look and the field:**
  `Order.v1: placed: 1970-01-01T00:00:01Z wrote 1, read back as
  1970-01-01T00:00:00.001Z, which writes 0; Time.from_unix and
  Time.unix_seconds disagree`.

Effect v4 derives an `Arbitrary` from a schema but leaves the round
trip to you. Here it's free because looks are declared, not built.

## std's policy for looks

Each rule here is one library's default, in its settings or its docs
(decision 20, rule 5). Consistency across std is a written convention.
Where a library needs the compiler's help, it uses a primitive above
that any third-party library could use. Settings records, casing,
strictness and how each library reads a shape are in
[shapes.md, "std's policy for the walk"](shapes.md#stds-policy-for-the-walk).

### json

- **Where the tag goes.** By default an internal tag named `"type"`:
  `{"type": "order.placed", ...}`. `type` is a Ren keyword, so no
  field collides with it. `tag: Adjacent("type", "data")` in json's
  settings puts the payload under `"data"`. There's no untagged form.
  A field named like the tag field is json's build-time error.
- **Where the payload goes:** named fields beside the tag; one record
  payload merged; any other payload under `"value"`; no payload, just
  the tag ([shapes.md, "Sums in json"](shapes.md#sums-in-json)).
- **A fieldless sum is still an object,** `{"type": "Admin"}`. A json
  API that wants `"Admin"` gives the type `parse`/`repr`, or names a
  `Str via` look.
- **Tags must be `Str`.** A look whose tags are another type fails
  json's check.
- **Casing re-cases only names not marked exact.** Two names that meet
  after casing are json's build-time error:

  ```
  error: `customerId` is written twice in what json sends for `Order`
    = `customerId = customer` in `Order.v1`
    = `customer_id`, a field, re-cased by `keys: camel_case` in `API`
    help: rename one of them in the look
  ```

- **Strict by default, first error.** An unknown key is `Unknown(at)`;
  `unknown: Ignore` relaxes a whole call. json stops at the first
  problem.
- **`null` and absent both decode to `None`;** encoding leaves `None`
  out, and `none: Null` writes `null` instead.
- **Numbers are exact number text,** read with a range check, never
  switched by size. std ships a JavaScript-safe look for `Int`, a
  string of digits.
- **`Bytes` is padded base64;** std ships `Bytes.base64url` and
  `Bytes.hex` as looks.
- **A map's keys go through their type's text form,** else json's check
  fails with help to use `Array<(K, V)>`
  ([shapes.md](shapes.md#absence-numbers-and-keys-in-json)).

### Text media: cli, env, query strings, sql text

- **A fieldless sum reads and writes as its case name:** `--role
  admin`, `?mode=merge`, `FLOTT_SYNC=Group`. That's their syntax, not
  a rule of the walk.
- **cli uses the same looks for flag names;** short flags and
  positionals stay in `cli.spec`. One look serves every medium:
  `listen = addr` is `"listen"`, `FLOTT_LISTEN` and `--listen`.
- **config collects all problems,** because it merges sources and a
  user fixes a file once.

### http

A REST look of `D.Call` is the route table: a sum look whose tags are
`http.Route` values. Statuses are a `writes` look of `D.Error` whose
tags are `Int`s. Both are ordinary looks; what their tags mean is
http's.

```ren
pub format rest for Keys.Call =
  | Get as GET"/v1/keys/\{key}"
  | Put as PUT"/v1/keys/\{key}"
  | List as GET"/v1/keys"

pub format rest for Keys.Error, writes =
  | NotFound as 404
  | Conflict as 409
  | Unavailable as 503
```

- **`GET"/v1/keys/\{key}"` is a value prefix:** `GET.template(t)`, an
  `http.Route`. Its holes are the case's fields. http checks the
  template while building, through `http.mount<Keys>(...)` in a
  top-level `let`.
- **A path hole is read through its type's `parse(Str)`.** `Key.parse`
  reads the segment.
- **Fields not in the path** go in the query for `GET` and `DELETE`, and
  in the body otherwise, through the call's json settings. There's no
  per-route override in 1.0.
- **Headers and raw bodies come with the http stage.** flottning wants
  `If-Match` from `expect` and a raw value body on day one. They're
  http's own: its route templates grow a header line and a raw-body
  line whose holes name fields, e.g. `If-Match: \{expect}` and
  `body: \{value}`. The language sees only holes naming fields; http
  says what a header is.
- **A status look may repeat a status.** It's a `writes` look, so the
  language allows it. A dep with a `Busy` error can give it 503 beside
  `Unavailable`, because the body carries the error's own tag and the
  client reads that, not the status.
- **Every error needs a status.** The look lists every case; a new
  error without a status fails the build.

  ```
  error: `Keys.Error.rest` has no status for `Throttled`
    help: add `| Throttled as 429`
  ```

- **Success is 200, and 204 for `()`.** A `writes` look of `Keys.Reply`
  can say otherwise (`| Put as 201`).
- **A reply body drops the case tag,** because the route says which
  case it is.
- **A bad path segment or body is a `Problem`,** not one of `D.Error`'s
  tags. http answers it 400 with the `Problem` in the body.
- **Two routes that can match one request** fail http's build-time
  check. Matching compiles to a perfect hash plus segment checks, by
  the compiler's general rule.
- **Serving several deps on one port** uses mounts: `http.mount<Keys>
  (KEYS_V1)` is a stateless handler of a std dep, so it's a
  description (language.md §6), and a list of mounts is an array of a
  compiler-written enum. No `D.call` is stored as a value.

### `Secret`

`Secret<T>` has `parse` and no `repr`. So:

- **It reads** wherever `T` does: json, env, flags.
- **It doesn't write** by the walk. `json.encode(cfg)` where `cfg`
  holds a `Secret` fails at the door, with the path:

  ```
  error: `Cfg.admin_token` is a `Secret<Str>`, which has no `repr`
    json.encode(cfg)
    = a type without `repr` can be read but not written
    help: leave it out with a `writes` look of `Cfg`, `format public for Cfg, writes = addr, dir`
  ```

- **Writing one goes only through a named look over the public
  `reveal`:** `format plain for Secret<Str> = Str via (Secret.parse,
  fn(s) => s.reveal())`. It sits in a settings record, where grep and
  review find it.
- **The journal's rule is on the type, not the look.** A `Secret` is
  hashed on export whatever look read it.

### Remote failure: `Unavailable` and `Why`

- **std declares the tag once,** in `std.remote`:
  `Unavailable(why: Why)`, with `Why = Refused | Timeout |
  Decode(Problem) | Protocol | Version | Denied | Server`. Structural
  tags need one spelling, and std is where it lives.
- **A dep says it with the header,** `pub dep Keys ! Unavailable =`.
  std's client handler (`http.client<D>`) fails with it, so it can only
  be given for a `D` whose header has it: the ordinary rule that a
  handler fits the dep's errors.
- **A write a version can't express is refused, never trimmed.** std's
  envelope writes through the version's looks, so a v2 caller writing a
  `ttl` to a v1 server fails `NotInVersion`, and the client reports
  `Unavailable(Version)`. That's std's rule for its protocols, not the
  language's.
- **Mapping.** A handler panic on the server is a 500 and
  `Unavailable(Server)` at the client.
- **The envelope and transports** are in
  [shapes.md, "Dependencies over the wire"](shapes.md#dependencies-over-the-wire).

## Left out

- **Casts of bytes to records,** outside `trust`.
- **`offset` and promised sizes on records.** They're a format's.
- **Standalone formats,** with no type.
- **A separate `decode`** beside `view(...).value`.
- **Checksums as syntax.**
- **Byte patterns in `match`,** Erlang-style.
- **A default byte order.**
- **Everything in [Where formats stop](#where-formats-stop).**
- **Attributes on fields.** A look is apart from the type, always.
- **Medium words in a format.** No tag field names, casings, statuses
  or headers in the declaration; libraries read them from tags and
  their own settings.
- **Untagged sums.** Slow, ambiguous, no error path.
- **Flattening, paths and computed fields in looks.** Use a `via` to a
  wire record.
- **Splicing a sum case into its parent.** `flot kv get a` stays, or
  the cli's command type is written flat.
- **Record looks over an opaque type's representation.** Always a `via`.
- **Marking a look that loses information.** The generated test checks
  that every look's wire form is stable, so no look needs to say it.
- **A switch to keep rejected input in errors.**
- **A per-route body or query override in http,** for 1.0.

## Later

- **A shape hash in all of layer 1's bytes,** as the journal has, so
  `bin` bytes from another version of a type fail to decode instead of
  decoding wrong.
- **Formats derived from a C header,** for interop in `trust`.
- **`ren explain` for a layout:** the layer 3 calls it compiles to, and
  its offsets as a table.
- **json's external tag,** `{"Placed": {...}}`, for serde-default APIs.
- **json's tag field per look,** `tags: [(Event.v1, Internal("kind"))]`
  in its settings, since looks are values. Until then an API with one
  type tagged `"kind"` needs a second settings record or a `via`.
- **JSON Schema** as a library over shapes. **OpenAPI ships with the
  http stage:** it's a walk over `shape.through` of `D.Call` and the
  REST looks, so it's small, and Effect v4 serves docs from the same
  value on day one.

## Open

- **Limits read at run time.** A settings record is known while
  building, but a `max_bytes` that comes from config isn't. Where such
  a limit goes, a separate argument or a run-time part of the settings,
  is open.
- **The spelling of http's header and raw-body lines,** for the http
  stage.
- **The envelope's spec:** call id, reply, defect, cancel, a reserved
  `Chunk`, the shape-hash handshake.

## Evidence

Two research passes on 2026-10-29 for layouts, using the clones in
`/tmp/ren-refs` and published sources, and the looks research
(research/looks/: synthesis.md, effect-study.md on Effect v4's
`Schema`, `SchemaAST`, `SchemaBinary` and `RpcSerialization`,
programs.md, judge.md, feasibility.md).

**Views, declared layouts and versions**

- TigerBeetle: `extern struct` with `stdx.no_padding` (`tigerbeetle.zig:29,
  112`; `stdx/stdx.zig:490`); size asserts (`vsr/superblock.zig:101-104,
  151`); reads with `bytesAsValue` (`vsr/grid.zig:1375, 1399`) and
  arrays with `bytesAsSlice` (`lsm/schema.zig:200-252`); check order
  (`grid.zig:1399-1410`); reserved regions asserted zero before the
  checksum (`superblock.zig:399-431`); a version field for breaking
  changes (`:64-65`); several releases in one binary
  (`multiversion.zig`); one region of bytes read through typed views by
  command (`vsr/message_header.zig:78-102, 158, 242`); a build-time
  assert that the machine is little-endian (`config.zig:204`).
- FoundationDB: Redwood refuses a mismatched `formatVersion`
  (`fdbserver/kvstore/VersionedBTree.cpp:2287`); the serializer
  branches on the protocol version (`storageserver.cpp:10465`); page
  structs packed.
- Swift SE-0525, `RawSpan.load(as:)` and `ConvertibleFromBytes`, whose
  layouts "are not guaranteed to be stable"
  (`swift-evolution/proposals/0525-rawspan-safe-loading-api.md:204`).
- OCaml cstruct and ppx_cstruct; SBE flyweights and `sinceVersion`;
  Cap'n Proto ordinals, defaults past an old struct's end, traversal
  limits; FlatBuffers vtables and its verifier; protobuf `reserved` and
  `buf breaking`; Rust zerocopy and bytemuck; Ada RM 13.5 and 13.6,
  representation clauses and change of representation.

**Parsing ergonomics**

- Erlang's bit syntax in OTP: a length-prefixed, tagged list in two
  clauses (`lib/stdlib/src/zip.erl:2006`), a size from an earlier field
  (`:2001`), bit fields by re-matching (`:2534`), writing with the same
  syntax (`:1200`), every field `/little`, the default big-endian
  (`lib/stdlib/src/dets_v9.erl:472`), errors with no offset
  (`zip.erl:2011-2027`); sub-binaries as root and range
  (`erts/emulator/beam/erl_bits.h:60-82`); small sub-binaries keeping
  large ones alive (`erts/doc/notes.md:9096, 2328`).
- Zig's `takeInt(T, endian)` (`lib/std/Io/Reader.zig:1150`).
- deku's attributes and machine-order default:
  https://docs.rs/deku/latest/deku/attributes/index.html. Kaitai's
  serialization: https://doc.kaitai.io/serialization.html. binrw's
  `calc`, `magic` and `count`; Construct's `Switch` and `build`; Spicy's
  network-order default; Wuffs; nom; Haskell's `runGetOrFail` and its
  `ByteOffset` (from the docs, not fetched).

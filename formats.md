# Formats: types as bytes

How a Ren program reads and writes bytes whose layout is fixed by
something outside it: a page on disk, a log record, a network frame, a
file header. It closes the open question in
[foundations.md](foundations.md#open-questions), "explicit layout, for
formats on disk and on the wire", and is the third piece of
[language.md](language.md)'s data-oriented side after `Table` and
`Pool`. The short version is [language.md §12](language.md#12-bytes-types-and-their-formats);
how it runs is [foundations.md decision 19](foundations.md#19-formats-are-views).

**Status.** Decided on 2026-10-29, from two research passes into prior
art (views over buffers, declared layouts and versioning; binary
parsing ergonomics). Staged with strings, bytes, slices and sized
integers, in "the `just`, natively" ([foundations.md](foundations.md#staging)).
Items marked **later** are noted so they aren't lost. Nothing here is
implemented.

## Contents

- [What it has to do](#what-it-has-to-do)
- [The problems](#the-problems)
- [Three layers: a default, then sharper tools](#three-layers-a-default-then-sharper-tools)
- [A type, and its formats](#a-type-and-its-formats)
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
- [Left out](#left-out)
- [Later](#later)
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
| A server | protocol framing: Postgres's wire protocol, HTTP/2 frames, DNS. Length prefixes, flags in bits, big-endian. |
| A command-line tool | file headers: zip, PNG, ELF. |
| Interop | a C struct across a foreign call, in `trust` only. |

## Three layers: a default, then sharper tools

| Layer | What you write | For | Promises |
|---|---|---|---|
| **1. Derived** | `bin.encode(order)`, `try bin.decode(bytes)` | messages between your own processes, caches | nothing about layout, and nothing across versions of a type |
| **2. Declared formats** | `format disk for PageHeader = ...` | disk and wire formats you own or must match | layout, byte order, validation, versions |
| **3. Raw bytes** | `b.u32_le(at)`, bit operations, slices | what layer 2 deliberately doesn't do | what you write |

Layer 2 compiles to layer 3's calls, and `ren explain` shows them, so
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

**A type says what a thing is. A format says how it looks as bytes.**
Every format is *for* a type, and a type can have several:

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
- **There are no standalone formats.** A format with no type would be
  an ad hoc struct, a second kind of record.

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

- **At most one format of a type is writable.** Older ones are marked
  `reads`. A field of the type that a `reads` format lacks gets `=
  value`, what it reads as. That's SBE's `sinceVersion` turned into
  migration, and it rules out writes that lose data: you can't write a
  `Superblock` through a format that has nowhere to put `owner`.
- **A writable format places every field of its type.** One that
  doesn't is an error whose help places it, or marks the format
  `reads` with a value.
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
compact, specialized in release builds, nothing to declare.

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

## Left out

- **Casts of bytes to records,** outside `trust`.
- **`offset` and promised sizes on records.** They're a format's.
- **Standalone formats,** with no type.
- **A separate `decode`** beside `view(...).value`.
- **Checksums as syntax.**
- **Byte patterns in `match`,** Erlang-style.
- **A default byte order.**
- **Everything in [Where formats stop](#where-formats-stop).**

## Later

- **A shape hash in all of layer 1's bytes,** as the journal has, so
  `bin` bytes from another version of a type fail to decode instead of
  decoding wrong.
- **Formats derived from a C header,** for interop in `trust`.
- **`ren explain` for a format:** the layer 3 calls it compiles to, and
  its offsets as a table.

## Evidence

Two research passes on 2026-10-29, using the clones in `/tmp/ren-refs`
and published sources.

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

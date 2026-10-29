# Strings: prior art, read from source

Input for the strings track (A1–A7 gavels, B1–B5 measurements). Every
claim cites a file or a URL. Clones I read are named by the path where
they live. `/tmp/ren-refs` holds roc-zig @7de4d5c (2026-10-26), lean4
@24a851d (2026-10-27), modular @cb987e0 (2026-10-26) and otp @18c22b8
(2026-10-26). `/tmp/ren-refs/swift` is sparse and has no
`stdlib/public/core`, so I made a sparse clone of
`swiftlang/swift` main (2026-10-29) at `scratchpad/strings/refs/swift`,
cited below as `swift:`. Go, V8, serde_json, compact_str and smol_str
files were fetched raw into `scratchpad/strings/refs/`.

Each section ends with **Ren:**, saying what to take and what to avoid.
The constraints don't change: no addresses, representation is the
compiler's choice, Perceus with in-place-when-unique, slices are values
(decision 17), and the interpreter and native builds agree.

---

## 1. Representation

### Roc: seamless slices, 3 words

Source: `roc-zig/src/builtins/str.zig` (lines 38–200, 264–290,
1118–1149) and `list.zig:25`.

- `RocStr = extern struct { bytes: ?[*]u8, capacity_or_alloc_ptr: usize, length: usize }`,
  which is 24 bytes on 64-bit.
- **Small strings:** the bytes are kept inline across all 24 bytes. The
  high bit of the last byte (`small_str_flag = 0b1000_0000`) marks a
  small string, and the low 7 bits hold its length. Up to
  `SMALL_STR_MAX_LENGTH = 23` bytes.
- **Big strings:** `capacity_or_alloc_ptr` holds the capacity shifted
  left by 1. The refcount sits in the word before the data.
- **Seamless slices:** `capacity_or_alloc_ptr` holds the *allocation
  pointer* with its low bit set (`SEAMLESS_SLICE_TAG = 1`). `bytes`
  points at the slice's first byte and is never tagged. The comment
  explains why: "masking it on every read would put tag handling in the
  hottest path. Slice tagging lives in `capacity_or_alloc_ptr` instead,
  which is only inspected by capacity and reference-counting
  operations."
- `getAllocationPtr` picks the owner pointer without a branch, using
  `seamlessSliceMask = 0 -% (cap & 1)`. A slice of a slice reuses the
  root's tagged pointer (`substringUnsafe`, 1138–1146), so slices are
  never nested. This matches decision 17's "a slice of a slice has the
  first one's root".
- **Retention:** `substringUnsafe` on a *big* string always returns a
  seamless slice, however short. A 3-byte token cut from a 1 MB string
  pins the 1 MB. The small-string path is taken only when the source
  is already small. The only remedy is manual:
  `Str.release_excess_capacity` ("will also convert seamless slices to
  regular lists", `src/build/roc/Builtin.roc:2702`).
- Equality has a fast path for the same pointer and length, then
  `memcmp` (`eql`, 330–360).
- For `List` slices whose elements are refcounted, Roc puts the
  original length on the heap so a slice holding the last reference can
  free every element. Brendan Hansknecht explains this on Zulip
  (https://roc-lang.github.io/zulip-export/stream/395097-compiler-development/topic/Size.20on.20heap.html).
  The 2023 announcement only warns of "underlying memory ramifications"
  (https://roc-lang.github.io/zulip-export/stream/316715-contributing/topic/PSA.3A.20Seamless.20Slice.html).

**Ren:**
- **Take** the encoding. Keep the hot byte pointer untagged and put the
  root and the slice flag in the cold word. That is representation A
  done well, and it's what decision 17 already describes.
- **Avoid** "short slice of a big root stays a slice". Under Ren's bet,
  copying a short slice inline is invisible to the program, and Roc
  doesn't do it. That gap is B1's question.

### Swift: `_StringObject` / `_StringGuts`, 16 bytes

Source: `swift:stdlib/public/core/StringObject.swift`,
`SmallString.swift`, `StringBreadcrumbs.swift`, `StringHashable.swift`,
`StringComparison.swift`.

- The value is 2 words: `_countAndFlagsBits: UInt64` and
  `_object: BridgeObject` (StringObject.swift ~93–102).
- **The discriminator is the top nibble of `_object`:**
  - b63 isImmortal: "Should the Swift runtime skip ARC". Literals are
    large immortal strings.
  - b62 isBridged, or for small strings, isASCII.
  - b61 isSmall.
  - b60 isForeign, which means no contiguous UTF-8.
- **Small strings:** 15 UTF-8 bytes on 64-bit (`SmallString.swift:81–93`),
  and 14 on Android arm64 because of memory tagging.
- **The flags word:** b63 ASCII, b62 NFC, b61 natively stored, b60 tail
  allocated, b59 foreign UTF-8, b48–58 reserved, and a 48-bit count
  (StringObject.swift:716–755).
  - The isNFC bit "enables trivial lexicographical comparisons: just
    memcmp". **But every constructor sets it as `isNFC: isASCII`**
    (StringObject.swift:862, 871, 880). So in practice any non-ASCII
    string takes the normalizing slow path for `==`, `<` and hashing.
- **Breadcrumbs:** native storage is UTF-8, so Cocoa's UTF-16 offsets
  need a lazily built side table. It records one `String.Index` every
  64 UTF-16 units (`breadcrumbStride`) and gives amortized O(1)
  UTF-16↔UTF-8 offset mapping (`StringBreadcrumbs.swift`). The 2019 post
  says they're built "only when requested" and skipped for ASCII
  (https://www.swift.org/blog/utf8-string/).
- **Bridging:** an NSString is not copied on import. It becomes
  "foreign/bridged" and is validated lazily on read. That's the reason
  for b60 and b62.

**Ren:**
- **Take** these:
  - the immortal bit for literals, so a literal is never counted;
  - an ASCII flag, which makes code-point and grapheme work trivial;
  - "flags are performance hints, never semantics".
- **Avoid** these:
  - a representation flag (NFC) that's almost always false;
  - lazy foreign storage. Ren has no Cocoa, so every `Str` should be
    contiguous, validated UTF-8.

### Mojo (2025–26): static, inline or refcounted, 3 words

Source: `modular/Mojo/stdlib/std/collections/string/string.mojo:224–297`.

- The fields are `_ptr_or_data`, `_len_or_data` and `_capacity_or_data`.
- `INLINE_CAPACITY = 3*8 - 1 = 23`. The top byte of the capacity word
  holds the flags: `FLAG_IS_INLINE`, `FLAG_IS_REF_COUNTED` and
  `FLAG_HAS_NUL_TERMINATOR`, plus a 5-bit inline length.
- A heap string has an atomic refcount *before* the data
  (`REF_COUNT_SIZE`). Copying a string increments it (604–620).
- Literals use the "static constant representation" with capacity 0.
  The source comment reads: "Always use static constant representation
  initially, defer inlining" (lines 333–371). So a literal isn't inlined
  until it is mutated.
- Equality is length, then the same-pointer check, then `memcmp`
  (1002–1020). `StringSlice.__hash__` hashes the raw bytes
  (`string_span.mojo:357–368`).
- `StringSlice` is a *separate*, origin-tracked borrowed type. That is
  Rust's `&str` model, not Roc's.

**Ren:**
- **Take** the three forms (static, inline, counted) in one 24-byte
  value, and literals that are never counted.
- **Ren differs:** Mojo's slice is a borrowed type with origins. Ren's
  decision 17 rejects that type.

### Lean 4: a counted object, in place when exclusive

Source: `lean4/src/include/lean/lean.h:234–240`,
`src/runtime/object.cpp:2176–2195`, `src/Init/Prelude.lean:3741–3757`
and `src/Init/Data/String/Defs.lean:370–560`.

- `lean_string_object { header; m_size /* bytes incl. NUL */; m_capacity; m_length /* UTF8 length */; m_data[] }`.
  The **code-point count is cached** in the object.
- `lean_string_append` grows in place when `lean_is_exclusive(s1)`, and
  copies otherwise. This is Perceus as Ren uses it.
- Equality is `memcmp` (`lean_string_eq_cold`).
- `String.Pos.Raw` is a **byte** offset: "Indexing a `String` by a
  `String.Pos.Raw` takes constant time, while character positions need
  to be translated".
- The 2025 API adds `String.Pos s`, a byte offset bundled with a proof
  that it falls on a UTF-8 boundary.
- `String.Slice { str, startInclusive, endExclusive }` is a *separate*
  type that holds the whole `String`, so it retains it too.
- **`Slice.Pos` is relative to the slice:**
  - `Slice.startPos.offset = 0`.
  - The validity rule is `(p.offsetBy s.startInclusive.offset).IsValid s.str`
    (Defs.lean:509–512).
  - Converting to a root position is explicit: `Slice.Pos.str`
    (`Basic.lean:888`) and `Slice.Pos.ofSliceFrom` (`Basic.lean:1355`,
    which replaced an older name on 2025-11-20).

**Ren:**
- **Take** byte positions, and slice-relative positions with an explicit
  lift to the parent. That is the owner's option (c), done in a proof
  assistant that has just redesigned this.
- Caching the code-point count is cheap if Ren ever wants an O(1)
  `codepoints().count()`, but it isn't needed.

### Erlang/OTP: heap and refc binaries, sub-binaries, match contexts, iolists

Source: `otp/erts/emulator/beam/erl_bits.h:56–170` and `erl_bits.c:2635–2660`.
OTP 27 rewrote this; the efficiency guide predates the rewrite
(https://www.erlang.org/doc/system/binaryhandling.html).

- **Heap binaries:** `ERL_ONHEAP_BINARY_LIMIT 64`. These live on the
  process heap and are copied on send.
- **Off-heap ("refc") binaries:** reached through a `BinRef`, which
  "should never be exposed to the user". A program sees them only
  through an `ErlSubBits { base_flags, start, end /* in bits */, orig }`.
- **Sub-binaries:** the same struct. A sub-binary never points at
  another sub-binary.
- **The match context** is the same struct with the MUTABLE flag set:
  the compiler advances `start` in place when it can prove the context
  isn't shared. That is a cursor value updated in place when unique,
  which is exactly Ren's `ByteCursor` under Perceus.
- **Small slices are copied automatically.** `erts_build_sub_bitstring`:
  `if (size <= ERL_ONHEAP_BITS_LIMIT) { ... HEAP_BITSTRING(...) }`
  (`erl_bits.c:2643`). A slice of 64 bytes or less is *copied* into a
  heap binary and holds no reference to its parent.
  - The `binary:referenced_byte_size/1` doc shows it:
    `<<B:10/binary, C/binary>> = A` gives B referencing 10 bytes and C
    referencing 1000 (`lib/stdlib/src/binary.erl`, around line 640).
  - Large slices still pin. The manual remedy is `binary:copy/1`, which
    the doc says to apply "only when a real problem has been
    identified". Its example heuristic copies when
    `referenced_byte_size > 2 * byte_size`.
- **Appending:** `<<Bin/binary, X>>` appends in place when there is "a
  single ProcBin and a single reference". Sending, matching or storing
  in ETS "shrinks" the binary, and the next append copies (efficiency
  guide).
- **iolists** are nested lists of binaries and bytes, written with
  `writev`. `erl_iolist.c:37` copies pieces of 512 bytes or less
  (`IOL2V_COPY_THRESHOLD = ERL_ONHEAP_BITS_LIMIT*8` bits) and references
  larger ones.

**Ren:**
- **Take** the automatic small-slice copy. It is invisible, because a
  binary has no identity, and Ren's bet makes it invisible too.
  Representation B (inline slices) is exactly this. Erlang's threshold,
  where a sub-binary header costs about as much as the bytes, is the
  argument for B's threshold.
- **Take** the match context as the model for `ByteCursor` (already
  done), and iolists for B3.
- **Note:** formats.md says root-relative offsets are something "Erlang
  can't do". In fact Erlang has the start offset internally and
  deliberately never exposes it.

### Go: `(ptr, len)`, slicing shares, Clone by hand

- `runtime/string.go:297` is `stringStruct { str unsafe.Pointer; len int }`.
  A string is any bytes, "usually" UTF-8. Slicing shares storage, and
  the GC keeps the whole array alive.
- `strings.Clone` came in Go 1.18 and `bytes.Clone` in 1.20, both
  tracked as #45038 (`api/go1.18.txt`, `api/go1.20.txt`). From
  `refs/go/strings_clone.go`: "can be important when retaining only a
  small substring of a much larger string ... Clone should typically be
  used only rarely, and only when profiling indicates that it is
  needed."
- `unique.Make` came in Go 1.23 (#62483). It **clones every string
  inside the value before interning it** (`clone(value, &m.cloneSeq)`,
  `refs/go/unique_handle.go:50`), so an interned key never pins its
  source.
- `strings.Builder` carries `copyCheck`, "a dynamic check to prevent
  modification after copying a non-zero Builder" (#25907, #47276;
  `refs/go/strings_builder.go:26–32`). It's an identity-bearing builder
  in a value language, and it took runtime guards to keep it safe.

**Ren:**
- **Take** `copy()` and its framing as a fix you apply when the
  debug-build report finds a problem.
- **Take** "interning and long-lived maps copy their keys".
  `Map<Str, _>` could `copy()` a key on insert when its root is much
  larger than the key; that's B4's question.
- **Avoid** a builder object with identity. Ren's `s += x`, in place
  when unique, needs none.

### Rust: `String`/`&str` and the crates

- **std:** `String` is a `Vec<u8>` holding valid UTF-8, 24 bytes, with
  no small-string optimization. `&str` is `(ptr, len)`, borrowed, so
  lifetimes prevent dangling but not retention. Slicing at a
  non-boundary panics ("byte index N is not a char boundary").
  `str::get(range) -> Option` and `is_char_boundary` are the checked
  forms.
- **compact_str** (`refs/rust/compact_str.md`): 24 bytes, inline up to
  **24** bytes. The trick is that the last byte of valid UTF-8 is always
  below 192, so the last byte values 192–215 encode lengths 0–23 and
  any value below 192 means "inline, length 24". Heap capacity is kept
  in 7 bytes. `const_new` takes a `&'static str` with no allocation.
- **smol_str** (`refs/rust/smol_str.md`): 24 bytes, immutable, O(1)
  clone through `Arc<str>`, inline up to 23 bytes. Runs of newlines
  followed by spaces (indentation) stay inline at any length. Its stated
  purpose: "a good enough default storage for tokens".
- **`bytes::Bytes`**: 4 words `(ptr, len, data, vtable)`. `slice()` and
  `split_to()` are O(1) and share a refcount. `from_static` never counts
  (https://docs.rs/bytes/latest/bytes/struct.Bytes.html). Retention is
  the user's problem.

**Ren:**
- **Take** compact_str's trick for B1: Ren's `Str` is always valid
  UTF-8, so inline capacity can be the full value width.
- **Take** smol_str's lesson: immutable, O(1)-clone, inline-small is
  what tokens want, and that's what Ren's slices plus representation B
  give.

### Zig

`std.Io.Reader.takeDelimiterInclusive` returns a slice of the reader's
own buffer that is invalidated by the next `peek`
(`/tmp/ren-refs/zig/lib/std/Io/Reader.zig:772–787`). Strings are
`[]const u8`, with no string type and no validity invariant.

**Ren:** this is the zero-copy line reader, paid for with use-after-peek
bugs. Ren gets the same zero-copy with a slice of a leased chunk
counted by Perceus (stdlib.md "Streams"), and nothing is invalidated.

### Java: 7u6 removed shared substrings, 9 added compact strings

- **CR 6924259 removed `String.offset` and `String.count` in 7u6
  (2012).** After that, `substring`, `subSequence` and `split` copy.
  - Rationale: memory leaks from small substrings, two fields fewer per
    String, and a simpler VM.
  - Cost: O(1) became O(n), and parsers reported regressions of "as
    much as a couple of percent". There was a public objection to
    changing complexity in an update release.
  - Sources: https://mail.openjdk.org/pipermail/core-libs-dev/2012-May/010295.html,
    https://mail.openjdk.org/pipermail/jdk7u-dev/2012-May/003199.html and
    https://mail.openjdk.org/pipermail/core-libs-dev/2012-November/012250.html
- **JEP 254 (Java 9)** made the backing store `byte[]` plus a `coder`
  (Latin-1 or UTF-16). The semantics are still UTF-16 code units, and
  `charAt` is UTF-16 indexed.

**Ren:** Java is the cautionary data point for both sides. Sharing leaked
memory and copying cost the parsers. Ren's answer is to share by default
and copy small slices automatically, in place of Java's copy-always.

### V8: cons, sliced and thin strings

From `refs/v8/string.h` (main) and `refs/v8/strings.md`:

- `SlicedString` is (parent, offset, length).
  `static const uint32_t kMinLength = 13`, and anything shorter is
  copied flat.
- The header comment still lists as a "missing feature": "truncating
  sliced string to enable otherwise unneeded parent to be GC'ed".
- `ConsString` (`kMinLength = 13`) is a lazy rope, flattened on read or
  when it gets too deep.
- `ThinString` forwards to the internalized copy.

**Ren:**
- **Take** the minimum slice length, which is the same idea as Erlang's
  64 bytes.
- **Avoid** ropes. They make the cost of indexing and comparison depend
  on history. Ren's `s += x`, in place when unique, makes concatenation
  cheap without them.

### German strings: Umbra, Arrow StringView, DuckDB, Velox, Polars

- **Umbra (CIDR 2020), as described by CedarDB**
  (https://cedardb.com/blog/german_strings/):
  - 16 bytes: a 32-bit length and a 4-byte prefix.
  - 12 bytes or less: inline. Longer: the prefix plus a 64-bit pointer,
    with **2 bits stolen for a storage class** (persistent, transient or
    temporary).
  - Immutable, so "appending ... is now a relatively expensive
    operation". Strings are capped at 4 GiB.
- **Arrow BinaryView** (https://arrow.apache.org/docs/format/Columnar.html):
  - 16 bytes, either `{len i32, inline[12]}` or
    `{len, prefix[4], buffer_index i32, offset i32}`, "adapted from TU
    Munich's UmbraDB".
  - A long string is **not a pointer**. It is an index into the array's
    own list of data buffers plus an offset.
- **DuckDB `string_t` and Velox `StringView`** use the same 16-byte,
  12-byte-inline layout.
- **Polars** (https://pola.rs/posts/polars-string-type/) moved to it:
  - `filter` and `gather` became O(n) instead of O(n·k).
  - "The biggest downside": after gather or filter, "we might keep
    strings alive that are not used anymore". Polars uses heuristics to
    decide when to compact the buffers.
- **Polar Signals, "Das Problem mit German Strings"** (2025-08-26,
  https://www.polarsignals.com/blog/posts/2025/08/26/das-problem-mit-german-strings):
  - A view costs at least 16 bytes per element. For low-cardinality
    columns (most of theirs are below 0.05% distinct), a 4-byte
    dictionary index cut memory by 75%.
  - Their argument: the encoding "should be Just Another Encoding",
    chosen from the data, not fixed by the system.

**Ren:**
- **For a column (`Table`/`Array<Str>`):** Arrow's form fits Ren well.
  The column owns a list of roots, and each element is
  `{len, prefix, root_idx, off}` or inline. No per-element refcount is
  needed, and compaction is the compiler's (Polars' heuristic).
  Dictionary encoding is another choice open to the compiler.
- **For a lone `Str` value:** with 64-bit pointers, 16 bytes can't hold
  {len, prefix, root pointer, offset}. Something has to give:
  - drop the prefix;
  - use a 32-bit offset with the root pointer, giving up the 4 GiB
    range;
  - or use Roc's 24 bytes.

  B1 should measure 16 bytes `{len32, off32, root ptr}` (inline up to
  12) against 24 bytes (inline up to 23, Roc or compact_str style).
- Both are allowed only because no program can observe the layout.

---

## 2. Semantics

### Indexing and length: the 2026 consensus is to name the unit

| System | Unit of position | `len` | Element |
|---|---|---|---|
| Rust | byte; panics at a non-boundary | bytes | `chars()` iterator |
| Go | byte; `s[i]` is a byte | bytes | `range` decodes runes; invalid → U+FFFD, width 1 |
| Lean 4 | byte (`Pos.Raw`) plus a validity proof (`Pos s`) | `utf8ByteSize`, `length` (code points, cached) | `Char` |
| Swift | opaque `String.Index` (UTF-8 offset plus transcoded and grapheme bits) | `count` = graphemes, O(n) | `Character` (grapheme) |
| Mojo | `s[byte=i]`, `s[codepoint=i]`, `s[grapheme=i]` | **`__len__` is `@unavailable`**: "a single length is ambiguous" (`string.mojo:834–845`) | named |
| Roc | none | **`Str.len` returns `LearnAboutStringsInRoc(Str)`**, a guidance tag (`Builtin.roc:2244–2260`); use `count_utf8_bytes` | none |
| Python 3 | code point; PEP 393 stores 1, 2 or 4 bytes per character to keep O(1) | code points | `str` of length 1 |
| Java | UTF-16 unit | UTF-16 units | `char` |

**Ren:**
- **Take** byte offsets as the only position. Rust, Go, Lean and Mojo's
  `byte=` all agree, and decision 17 already panics at a cut character.
- **Take** the Mojo/Roc move. Two independent languages changed this in
  2025–26, which is strong evidence that an unqualified `s.len()` on
  text is a trap. Have `s.byte_len()` (or `Bytes`-style `len` on
  `s.bytes()`), `s.codepoints()` and `s.graphemes()`, and no bare `len`
  on `Str`.
- Grapheme segmentation comes from pinned tables, as stdlib.md's
  `unicode` row already says. Mojo ships the conformance tests
  (`test/collections/string/test_grapheme_conformance.mojo`), and so
  should Ren.

### Equality and hashing: Swift is the outlier

- **Swift:** `==`, `<` and `hash` use **canonical equivalence**.
  `"e\u{301}" == "é"` is true.
  - Hashing keeps this consistent by feeding the *NFC* code units, with
    a `0xFF` terminator (`StringHashable.swift`).
  - Comparison is `memcmp` only when both strings are NFC, and the NFC
    bit is in practice the ASCII bit (see section 1). Otherwise it
    normalizes incrementally (`StringComparison.swift:100–190`).
  - The rationale is in the Manifesto (`swift:docs/StringManifesto.md:227–284`):
    equality at the UCA's "identical" level reduces to comparing
    normalized forms, so equality and hashing can skip collation.
    Ordering is then a lexicographic comparison of normalized forms and
    isn't locale-aware.
- **Everyone else** uses byte or code-unit equality: Rust, Go, Mojo,
  Lean (`memcmp`), Roc (`eql`), Python, Java, Haskell `text` and
  Erlang. Rust and Swift share the `0xFF` hash terminator.
- **The stability problem:** Unicode guarantees that normalization is
  stable *only for assigned characters*. A string containing
  then-unassigned code points "might not be in normalized form according
  to a future version of Unicode"
  (https://www.unicode.org/policies/stability_policy.html). So
  canonical-equivalence `==` and hashing can change when the tables
  move.

**Ren:**
- **Byte equality and byte hashing are the default.** Ren's `x.hash()`
  is unseeded and journaled, and replay has to reproduce it. Equality
  that depends on table versions would make a stored hash or a
  `Map<Str, _>` iteration outcome version-dependent.
- Normalization is explicit: `s.nfc()` and `s.nfd()`, with
  `a.nfc() == b.nfc()`. A domain type can write a `key` that
  normalizes, as operators.md already allows for "a type whose
  representation isn't unique". This is A3's answer, from evidence:
  Swift's choice costs every non-ASCII comparison, and Ren's
  determinism rules it out.

### Slicing at a non-boundary

| System | What happens |
|---|---|
| Rust | panic; `get` gives `None` |
| Mojo | `s[byte=a:b]` off a code-point boundary aborts (`string.mojo`, the "on codepoint boundaries will abort" doc) |
| Roc | `drop_first_bytes` and `drop_last_bytes` return `Err(BadUtf8)` (`Builtin.roc:2566–2590`) |
| Lean | ruled out by the type (`Pos s` carries the proof) |
| Go | allowed; the result may be invalid UTF-8 |
| Swift | indices are rounded down to a scalar boundary (`_isScalarAligned`) |

**Ren:** keep decision 17: panic, because a bad offset is a bug, as an
out-of-range `xs[i]` is. Splitters skip the check. Roc's `Result` form
is right only for offsets that come from *input*, so a checked form
such as `s.get(a..b) -> Option<Str>` should sit beside the panicking
form, as Rust does.

### Building

- **In place when unique:**
  - Lean `lean_string_append` (`lean_is_exclusive`);
  - Roc concat;
  - Erlang writable binaries ("a single reference");
  - Swift (unique native storage);
  - CPython's `+=` on a refcount-1 string. PEP 8 tells people not to
    rely on that last one ("fragile even in CPython"). The idea is
    right, but CPython can't guarantee it.
- **Builder objects:** Go `strings.Builder` (with `copyCheck`, an
  identity hazard), Java `StringBuilder`, and Rust `String` plus
  `fmt::Write`.
- **Rust `format_args!`:** the template is parsed at compile time into
  an `Arguments` of static pieces and arguments, written to any sink
  without allocating.
- **Gather writes:** Erlang iolists sent with `writev`, and small pieces
  copied (section 1).

**Ren:** Perceus makes `s += x` reliable where CPython's is fragile, so
there's no separate builder type. That's B3's first arm. Output paths
(JSON, HTTP) also want an iolist-like gather; B3 measures it.

### Interpolation designs

- **Swift SE-0228** (`swift-evolution/proposals/0228-...md:160–217`):
  - The compiler lowers `"a\(x)b"` to
    `init(literalCapacity: 2, interpolationCount: 1)`,
    `appendLiteral("a")`, `appendInterpolation(x)` and
    `appendLiteral("b")`.
  - `appendInterpolation` can be overloaded per type, with labels
    (`\(x, format: .hex)`).
  - Any type can be built from a literal (SQL, HTML, attributed text).
- **Roc** (`Builtin.roc:2895–2920`): `Str.from_interpolation(segments)`
  is called **at compile time** with the literal segments and returns
  the function that assembles the string at runtime. `from_quote` does
  the same for literals. The literal's type picks the builder.
- **Python PEP 750 t-strings** (3.14, https://peps.python.org/pep-0750/):
  - `t"..."` is a `Template` holding `strings` (N+1 parts) and
    `interpolations` (value, expression, conversion and format spec).
  - It has **no `__str__`**: "no canonical way to convert a Template to
    a string".
  - The motivation is SQL injection and XSS.
- **JS tagged templates:** `tag(strings, ...values)`. The `strings`
  array is frozen and cached per call site, which lit-html uses.

**Ren:**
- **Keep** today's rule: interpolation goes through `show` (operators.md)
  and builds a `Str`, with the literal sizes as a capacity hint, Swift
  style.
- **Later:** a typed template, where the literal's expected type picks
  the builder, Roc and Swift style, for `Sql` and `Html`. It's
  compile-time dispatch, so it fits decision 4 (static dispatch, closed
  world).
- **Avoid** a "format spec" mini-language inside strings. Swift's
  labelled interpolation arguments are the explicit form.

### The text/bytes boundary

- **The winning split:** `Str` is valid UTF-8 and `Bytes` is any bytes.
  Rust, Swift 5 (validated once at creation), Haskell `text`, Python 3
  and Mojo all do this. Roc returns typed problems from `from_utf8`.
- **Where it breaks is the OS boundary:**
  - **Python:** PEP 383 (3.1) smuggles undecodable bytes into `str` as
    lone surrogates. PEP 540 (3.7) added UTF-8 mode, and PEP 686 makes
    it the default.
  - **Rust:** `OsStr` is bytes on Unix and **WTF-8** on Windows. Since
    1.74 `as_encoded_bytes` exposes it as "a self-synchronizing superset
    of UTF-8".
  - **Zig** also uses WTF-8 for Windows paths.
  - **Go** skips the problem: a string is any bytes, and you get U+FFFD
    when you range over it.

**Ren:**
- **Take** Rust's and Python's lesson: don't let invalid data into
  `Str`. Paths, environment values and arguments are a `Bytes`-backed
  type, `Path`, which already has its own `show`.
- **Take** a lossy `show` and a checked `to_str() -> Result`.
- **Avoid** surrogateescape: it breaks "Str is valid UTF-8".
- **Avoid** a third string type. Ren isn't on Windows yet; if it gets
  there, WTF-8 goes inside `Path`.

---

## 3. Positions and offsets in parsers and errors

| Tool | Positions relative to | How you get the root or stream position |
|---|---|---|
| **Lean `String.Slice.Pos`** | the slice (`startPos.offset = 0`) | explicit `Slice.Pos.str` / `ofSliceFrom` (`Defs.lean:509`, `Basic.lean:888, 1355`) |
| **Kaitai Struct** | the current substream: a sized field "creates a new substream", and "`pos` ... addresses data relative to the start of that substream" | explicit `io: _root._io` (https://doc.kaitai.io/user_guide.html §5) |
| **protobuf `CodedInputStream`** | `pushLimit` is "(current position) + byteLimit"; `getTotalBytesRead` counts from the start or the last `resetSizeCounter()` | the caller resets or adds |
| **winnow `LocatingSlice`** | the input given to `LocatingSlice::new`; `reset_to_start` is "useful for formats that encode a graph with addresses relative to the start of the input" | wrap the right base |
| **nom_locate `LocatedSpan`** | the input at construction (`location_offset` starts at 0) | `new_from_raw_offset(offset, line, ...)` **carries a base as data** |
| **nom `Offset`** | **pointer subtraction** between two slices of the same buffer | (needs addresses) |
| **serde_json** | the input; `position_of_index(i)` computes line and column **lazily, on error**, from the byte index (`refs/rust/serde_json_read.rs:448–457`; the column is in bytes) | n/a |
| Go `json.SyntaxError.Offset`, Rust `Utf8Error::valid_up_to`, Python `UnicodeDecodeError.start` | the value passed in | n/a |
| **Erlang** match context | an internal bit offset into `orig`; **never exposed** | n/a |
| **Swift** `Collection` slices | **the base**: "A collection and its slices share the same indices" (`swift:stdlib/public/core/Collection.swift:223–226`) | built in |

The only systems with root-relative positions are Swift's shared
indices (and Ren's formats.md promise). Swift needs them so that an
index stays valid in the base. It also paid for the related leak:
**SE-0241 deprecated `String.Index.encodedOffset`**, which "assumes
UTF-16" because that "happened to be the only encoding used internally".
It was "frequently misused", and Swift 5's switch to UTF-8 broke the
code that used it
(`swift-evolution/proposals/0241-string-index-explicit-encoding-offset.md`).
The general lesson is that an offset defined by the current
representation gets used, and then the representation can't change.

**Ren:**
- **Option (c) has the most prior art.** Lean's slice-relative `Pos`
  plus explicit lift, Kaitai's substream `pos` plus explicit
  `io: _root._io`, and nom_locate's carried base are the three
  precedents. A cursor's position is relative to the value it holds,
  and a program that wants a stream position says where its value
  starts: `b.cursor(from: 4096)`, or a framing loop that carries a base.
- **Option (b) makes root identity observable.** `copy()`, append-time
  reallocation, and the interpreter's copies would all change an
  error's `at`, so interpreter and native would differ. Only nom does
  (b), and it can because it has addresses. formats.md's "Errors carry
  offsets" bullet needs rewording either way.
- **Take** serde_json's trick: errors carry a byte offset, and line and
  column are computed only when the error is shown, from the value the
  program holds.

---

## 4. Documented regrets and reversals

1. **Java 7u6 (2012):** shared substrings became copies, because of
   leaks. Parsers paid for it, and the change landed in an update
   release (CR 6924259, threads above).
2. **Swift 3 to 4:** `String` had been its own SubSequence, with shared
   storage and 3 words. Swift 4 added a separate `Substring` (SE-0163,
   `0163-string-revision-1.md:44–83`; Manifesto "Substrings",
   `StringManifesto.md:484–600`).
   - The Manifesto lists the three options (same type and shared; same
     type and copied; different type and shared) and picks the third.
   - It names Java 7 as the precedent and admits that "having two
     types" is "likely ... a significantly bigger problem than with
     Array and ArraySlice".
   - **Ren picked the first option, and it is the only option the
     Manifesto doesn't defend against leaks. Ren's defence has to be
     automatic small-slice copying plus the debug-build report.**
3. **Swift 2 to 4:** `String` stopped being a `Collection` (you went
   through `.characters`), then became one again (Manifesto "String
   should be a Collection of Characters Again", line 328).
4. **Swift 5 (2019):** the native encoding moved from UTF-16 to UTF-8,
   with breadcrumbs to keep UTF-16 interop. It had to land before ABI
   stability (https://www.swift.org/blog/utf8-string/). SE-0241 was the
   fallout.
5. **Haskell `text-2.0` (Dec 2021):** UTF-16 to UTF-8. The changelog
   says array functions now work on bytes, not 16-bit words
   (https://hackage.haskell.org/package/text-2.0/changelog,
   https://mail.haskell.org/pipermail/libraries/2021-December/031552.html).
   `Data.Text` slices share storage, so it has `copy` for exactly the
   retention problem (Hackage docs for `Data.Text.copy`).
6. **Python 3:** the `str`/`bytes` split stuck. The OS boundary needed
   PEP 383, then PEP 540 UTF-8 mode, then PEP 686 to make it the
   default. PEP 393 had already changed how `str` is stored, to keep
   O(1) code-point indexing.
7. **Go:** retention was left to users. `strings.Clone` came in 1.18,
   `bytes.Clone` in 1.20, and `unique.Make` (1.23) clones internally,
   so the standard library protects itself.
8. **Roc:** slices became seamless in March 2023, announced with "please
   run under valgrind". Refcounted lists later needed a heap-stored
   length. Today `Str.len` is withdrawn in favour of a guidance tag.
9. **Mojo:** in 2025–26 `len(String)` was made unavailable, and indexing
   takes an explicit unit.
10. **V8:** the sliced-string "truncation" that would let a parent be
    collected is still listed as missing in `string.h` today.
11. **Erlang OTP 27:** the binary implementation was rewritten around
    sub-bitstrings, and small slices are copied into the heap.
12. **German strings:** after adoption, Polars calls the GC of
    unreferenced buffers its "biggest downside", and Polar Signals moved
    most columns back to dictionaries.

---

## 5. What this means for Ren, by gavel

- **Representation (B1):** measure representation A (Roc-style,
  24 bytes, root in the cold word) against B at 16 bytes (inline up to
  12, `{len32, off32, root}`) and B at 24 bytes (inline up to 23 or 24,
  compact_str style).
  - Whichever wins, **short slices stop pinning roots**, as in Erlang
    (64 bytes or less) and V8 (fewer than 13 characters).
  - Columns get Arrow's buffer-index views.
- **Equality and normalization (A3):** bytes. Normalization explicit.
  `key` for types that normalize.
- **Length and indexing:** byte positions; no bare `len` on `Str`;
  named views.
- **Positions:** (c), value-relative. A cursor or loop states its base.
  Errors carry a byte offset, and line and column are derived when the
  error is shown.
- **Building (B3):** `+=` in place when unique, plus a gather writer for
  output. Interpolation stays `show`, and typed templates come later.
- **Boundary:** `Str` is always valid UTF-8; OS data is `Path` or
  `Bytes`; `from_utf8` returns typed errors with offsets (B5 measures a
  SIMD validator).

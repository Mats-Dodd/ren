# Standard Library

**Own the shared types. Fake every dependency. Borrow the computation, own the effects.**

This doc covers what ships with Ren: which modules are in the standard library, which are left to packages, the types every library has to agree on, and the conventions that keep the ecosystem testable. How the runtime talks to the operating system is in [runtime-io.md](runtime-io.md).

> **Status:** design. Nothing here runs yet beyond the prelude types used by the interpreter, `Clock`, `Random` and `Console` with their test implementations (stage 7, [deps.md](deps.md)), the world's thin slice (`Fs`, `Os`, `Proc`, `Net`), and what tasks need: `Async`, `sync` and `sim` (stage 11a), and the services stage's `striped`, `actors`, `Instances`, `Send` and `Async`'s producers (Part 5's "Concurrency and resilience"). Decisions marked *proposed* are recommendations, not settled; see [Open questions](#open-questions).

---

## The short version

```
 std owns the shared types        Time, Request, Sql, Blob: libraries agree on them
 three implementations each       real, in-memory, simulated, plus one conformance suite
 cursors first                    for line in &reader: a value keeps its place, no Reader objects
 borrow the computation           SQLite, aws-lc, rustls, zstd: pure work, effects supplied by Ren
 own the effects                  borrowed code never reaches the world on its own
 stable in std, moving in std.x   HTTP and JSON are stable; cloud APIs and YAML are not
```

---

## Four rules

**1. The standard library owns the shared types.**
Go's `net/http.Handler`, `io.Reader` and `database/sql` are why Go libraries fit together without adapters. Breadth matters less than getting the types everyone passes between libraries right: `Bytes`, `Time`, `Instant`, `Duration`, `Decimal`, `Request`, `Response`, `Sql`, `Blob`, and the log event.

**2. Every dependency has three implementations and one conformance suite.**
A dependency in `std` ships a real implementation, an in-memory one, and a simulated one that fails in every way its contract allows. One test suite runs against all three, and against any vendor's implementation. This is what makes the README's testing and simulation story true for everyone, not only for code in `std`.

**3. Borrow the computation, own the effects.**
Ren borrows mature components where the work is decades of hardening. A borrowed component may compute, but it may not reach the world on its own: its I/O, clock, randomness and allocation are supplied by Ren, so simulation and replay still hold.

**4. Stable things go in `std`. Moving things go in `std.x`.**
`std` comes with a compatibility promise. A domain that changes faster than that promise can absorb (cloud APIs, Kafka clients, YAML edge cases, HTTP/3) goes in `std.x`, a staging area of ordinary packages, or stays out. `golang.org/x` and Effect's `unstable` modules are the models.

---

## Part 1: What goes in

### The tests

A module belongs in `std` if it passes any of these:

| Test | Question | Example |
|---|---|---|
| **Shared type** | Must libraries agree on this type to fit together? | `Time`, `Request`, `Sql` |
| **Determinism** | Must it be controlled for simulation and replay to hold? | `math`, hashing, Unicode tables, DNS, time zones |
| **Trust** | Does it need `trust` or FFI, or is it critical to security? | crypto, TLS, compression |
| **Toolchain** | Does the Ren toolchain itself need it? | TOML, tar, SHA-256, an HTTP client, JSON |
| **Ubiquity** | Does nearly every service need it? | JSON, HTTP, logging, configuration |

It goes to `std.x`, or stays out, if it fails the **stability test**: does the domain change faster than the compatibility promise allows?

The determinism test is the one other languages don't have. A third-party `sin`, hash function, Unicode table or DNS resolver could quietly make a recorded trace replay differently on another machine, so Ren owns them.

### Layers

```
prelude    Int, Str, Bytes, Array, Map, Set, Option, Result, Duration, Time
           (what nearly every module needs)

pure       str, bytes, fmt, sort, math, unicode, decimal, bigint, random, uuid,
           collections, regex, json, schema, base64, hex, url, csv, toml,
           compress, crypto

deps       Fs, Net, Clock, Random, Console, Alloc, Async, Os
           each with real, in-memory and simulated implementations

services   http, tls, x509, dns, sql, sqlite, postgres, config, cli, log, trace,
           metrics, schedule, retry, cache, channel, test, sim

infra      Blob, BlobCas, Kv, Cache, Queue: dependency types only, implemented
           by vendor packages

std.x      websocket, protobuf, grpc, yaml, mysql, redis, jwt, prometheus,
           ren.syntax, ...
```

---

## Part 2: Shared types

### Streams: cursors first

Go's `io.Reader` is a stateful object behind an interface. Ren has neither half of that: there are no traits, and a block can't hold state, since it can't be kept. What Ren has is a value that keeps its position, which value semantics allow, and `for` over it. A **cursor** is any type with a method `next(inout self) -> Option<T>`, and `for x in &c` calls it until it gives `None` (runs since stage 10c):

```ren
var r = Fs.line_reader(path)               // a cursor: it keeps its place in the file
for line in &r
  if line == "---" then break              // `r` stays where it stopped
  try Index.add(parse(line))
for line in &r                             // and this loop goes on from there
  &body.push(line)
```

`for x in c`, without `&`, on a named cursor is an error, since it would step a copy and leave `c` at the start ([streams.md](streams.md#data-cursors-you-keep); today it still steps the copy); a temporary needs no `&`. `xs.zip(ys)` over two arrays is a cursor too, of their pairs, which a `for` compiles to one counted loop. A cursor reads one item at a time, so it can zip two streams or read exactly *n* bytes for a framed protocol, and `break` leaves the loop with the cursor where it stopped. Lines, SQL rows, HTTP bodies and byte chunks all use the same shape:

```ren
var chunks = Net.chunks(conn)              // chunk: Bytes, leased from the runtime's pool
for chunk in &chunks
  try out.write(chunk)
```

When the body's turn ends, the chunk's reference count reaches zero, its buffer goes back to the pool, and the next read is submitted ([runtime-io.md](runtime-io.md#buffers-lent-or-leased)). Backpressure comes for free: nothing is read ahead of a body that hasn't finished.

Since the services stage, a cursor's `next` can use a dependency, as a channel's `items()` does, and a temporary's can fail, `for x in try c`; `Async.map` and `Async.each`, and any parameter `fn() -> Option<T>`, take what `for` takes ([async.md](async.md#the-whole-surface)). `Fs.line_reader` and `Net.chunks`, readers that hold an id and an offset, wait for stage 11c, as `for x in try &r` over a named one that can fail does. [streams.md](streams.md) decides the rest:

- **A chain over a cursor is a lazy pipeline,** `&r.map(f).select(p).take(n)`, a block composed where it's written, so it allocates nothing; on an `Array` the same names run now. The default stages are `map`, `select`, `reject`, `take_while`, `drop_while`, `flat_map`, `with_index`, `scan`, `dedup_by`, `take`, `drop`, `batch(n)`, `batch_while`, `windows(n)`, `zip` and `merge_by`, with the sinks `sum`, `reduce`, `count`, `any`, `all`, `find`, `first`, `min`, `max` and `to_array()`. `skip` is `drop`, and `chunks(n)` is `batch(n)`, keeping "chunk" for bytes.
- **A `gen fn` is the way to write a producer with control flow,** and a user's stage is a `gen fn` that takes a block, joined with `|>`.
- **Each resource has two forms:** a generator you use where you call it, whose `finally` closes it (`Fs.lines(p)`, `Db.query(q)`), and a reader you can keep, which is data (`Fs.line_reader(p)`, `Db.rows(q)`, `Net.frames(conn, fmt)`). A reader holds an id and an offset, and the service holds the resource: a service's open resources are a family keyed by id, its `max:` the cap on open files, and a reader whose resource was evicted or ended fails with a typed `Closed` ([concurrency.md](concurrency.md#streams-calls-that-answer-many-times)).
- **`Async.pull` is gone.** A recursive producer is a `gen fn` with `yield from`, and one that needs a task is `Async.produce` ([async.md](async.md#the-whole-surface)).

### Slices: views without a view type

A parser takes a `Str` or `Bytes` apart without copying it, and without a type that borrows: a slice, `s[a..b]`, is a value of the type it's cut from, which shares that buffer and keeps it alive ([foundations.md](foundations.md#17-slices-are-values), [operators.md](operators.md#slices)). So the library's splitters return slices of what they're given: `s.split(";")` is an array of slices of `s`, and `s.trim()` a slice of it, cut where they found a separator or a space, so neither checks for a character it cut. A record that keeps a slice keeps the whole buffer, so code that keeps a few small slices of a large input calls `copy()` on them, which costs nothing on a value that already has its own buffer:

```ren
let fields = line.trim().split(" ")        // slices of `line`, no copies
&index.push(fields[0].copy())              // a key kept past the file it came from
```

A function that changes parts of an array in place takes them as places, `&xs.split_at(n) fn(&lo, &hi) => ...`, which is how a sort or a parallel loop divides its work.

### From bytes to a string

`Str.from_utf8(b)` is the one way from `Bytes` to a `Str` that checks them, and fails with `InvalidUtf8(at: Int, incomplete: Bool)`: `at` is where the first byte that isn't part of a character is, and `incomplete` says the end cut that character off, so a decoder fed in chunks keeps the last few bytes for the next chunk instead of failing ([strings.md](strings.md)). It accepts exactly what OCaml's `String.is_valid_utf_8` does, in `ren run` and natively, where it's a block validator, 64 bytes at a time, where there's NEON, and a scalar one elsewhere. `Str.from_utf8_lossy(b)` never fails: it writes U+FFFD for each maximal invalid subpart, as Unicode recommends and Rust's `from_utf8_lossy` does.

### Text: sizes, characters and building

A `Str`'s size is `s.byte_len()`, and `s.is_empty()` asks whether it has any; it has no `len` and no `s[i]`, since a reader can't tell bytes from characters, and each is a compile error whose help names the choices ([strings.md](strings.md#length-and-indexing)). `Bytes` keeps `len`. `s.char_floor(i)` and `s.char_ceil(i)` are the character boundaries at or before and at or after `i`, for cutting at most so many bytes, and a slice that cuts a character panics with a help that names `char_floor`. `s.chars()` is a cursor of one-code-point `Str` slices, `c.code()` the code point of one (it panics on any other string), and `Str.of_code(n)` makes one. `'a'` is an `Int` literal, its code point; a non-ASCII one can't be stored in a `UInt8`. `s.ascii_lower()`, on `Str` and `Bytes`, changes `A` to `Z` and nothing else (`lower` was renamed so that a Unicode one, `unicode.lower(s)`, can't be mistaken for it).

Searching, splitting and trimming have the same names on `Str` and `Bytes`, with the same meaning, so code that moves between the two keeps it; whitespace is ASCII on both, `trim`'s (space, `\t`, `\n`, `\r`, form feed: [strings.md](strings.md#characters)). What gives part of the receiver gives a slice of it:

| Name | What it gives |
|---|---|
| `s.index(t)` | `Some` of where `t` first starts, or `None` |
| `s.includes(t)`, `s.starts_with(t)`, `s.ends_with(t)` | whether `t` is in it, at its start, at its end |
| `s.strip_prefix(t)`, `s.strip_suffix(t)` | `Some` of what's after `t` at its start, or before `t` at its end, or `None` |
| `s.split(sep)` | the parts between each `sep`; an empty `sep` panics |
| `s.split_once(sep)` | `Some` of the parts before and after the first `sep`, or `None` |
| `s.lines()` | an array of its lines: the parts between each `\n`, a `\r` just before it dropped, with no empty last line (Rust's `lines`) |
| `s.fields()` | an array of the runs between ASCII whitespace, none empty |
| `s.trim()` | without the ASCII whitespace at its ends |
| `s.replace(from, to)` | each `from`, left to right and not overlapping, made `to`; an empty `from` panics |
| `s.ascii_lower()`, `s.ascii_upper()` | `A` to `Z` made `a` to `z`, or the other way, and nothing else |
| `s.line_col(at)` | on `Str`: the line and column of the offset `at`, `(Int, Int)`, from 1, the column in code points; panics if `at` is past the end or inside a character |

`count()` with no predicate is how many there are, on every receiver: an array, a map, a set, and a cursor, whose items a copy of it gives, so `name.chars().count()` counts code points and a named cursor stays where it was; `count(f)` counts those `f` is true of, on each of them ([operators.md](operators.md#the-collection-methods)). `ren run` and native builds agree on every result and panic here.

`xs.index(x)` is `Some` of the first index where `x` is, or `None`. **When it's hashed:** where `xs` is an array literal of string literals, written there or bound by a `let`, `keys.index(s)` is a string `match` of `s` with an arm for each key, so a release build looks it up through the same perfect hash, about one lookup whatever the number of keys (compiler.md, "Patterns stage"); a debug build runs the method as written, with the same answer. A shape's field names, which a library only knows from `T.shape`, get it once release builds fold them to constants (stage 12).

Strings are built three ways: interpolation, `"jobs/\{job}: \{n * 2}"`, each hole any expression shown through its type's `show`, and `\{x=}` writing `x=` before `x`'s value; `a + b` and `s += t`, on `Str` and `Bytes` (`concat` is gone); and `xs.join(sep)` on an `Array<Str>`. A native build's `s += t` (and `a + b` where `a` isn't used after) appends in place when nothing else holds the string, its buffer doubling when it's full, so a loop of appends is linear; where something else holds it, it copies. A debug build reports, once at a normal exit, on stderr, each `+=` (or `o = o + x`) that copied its string on more than one pass, as a `note:` with the help `build the string once: join, or keep it unique`; `REN_NOTES=0` silences it, and a release build has no report. The capacity and the report are native only: `ren run`'s `+=` copies, and reports nothing, since only meaning has to agree ([compiler.md](compiler.md#bytes-stage-part-two)).

### Bytes at an offset, and a cursor

Below formats ([formats.md](formats.md#layer-3-raw-bytes)), `Bytes` has reads and writes at an offset with the width and byte order in the name, as Go's `binary.LittleEndian` and Zig's `takeInt` do: `b.u8(at)`, `b.i16_be(at)`, `b.u32_le(at)` ... `b.i64_be(at)`, and `&b.set_u32_le(at, x)` and the rest, on a `Bytes` made with `Bytes.zeros(n)` or any other. A read or a write at an offset the program computed panics out of range, as `xs[i]` does: a bad offset is a bug. A write that doesn't fit its width panics as a store into a sized integer does. `u64_le` gives an `Int`, and panics on 2^63 or more; `i64_le` reads the same bits as a signed `Int`, which is how a 64-bit hash or checksum is read. A write copies the bytes first if anything else holds them, a slice's root or a literal included, so `Bytes` stay values. `&b.set_varuint(at, x)` and `&b.set_varint(at, x)` write LEB128 (zigzag for `VarInt`) and return how many bytes they took, which `Bytes.varuint_size(x)` says first.

Reading in sequence is a cursor's, `b.cursor()`, or `b.cursor(from: n)` for bytes that start at `n` in their stream or file, from which every `at` it reports counts ([strings.md](strings.md#positions)), a value: its reads, `try &c.u32_le()`, `try &c.varuint()`, `try &c.bytes(n)`, `try &c.skip(n)`, fail with a `FormatError` when the input runs out, `Short(at, need)`, and leave the cursor where it was, so a framing loop copies the cursor, tries a record, and keeps the copy only if the record was all there:

```ren
var next = c
match attempt record(&next)
  Ok(r) =>
    handle(r)
    c = next
  Err(_) => wait_for_more()
```

A `u64` too large for an `Int`, or a `VarUInt` longer than 10 bytes, is `Malformed`. `c.at()`, `c.left()` and `c.rest()` say where it is and what's after it. `c.at()` and the errors' `at` count from the start of the bytes the cursor was made from, or from a base, `b.cursor(from: n)`, so a cursor over a buffer that starts at byte `n` of a stream reports stream offsets ([strings.md](strings.md#positions)) (compiler.md, "Bytes stage", "Layer 3: the API").

### `x.hash()`, and a map's own hash

Every type with a derived or written `hash` ([operators.md](operators.md#equality-hashing-and-show)) has a method `x.hash()` that gives an `Int`, through the type's `key` if it has one, so two values `==` hash the same. It has **no seed**: the same value on every run, in `ren run` and in every native build, so a hash that's printed, stored or journaled replays the same. A `Map` or `Set` doesn't use it: inside, it hashes its keys with a fast hash mixed with a seed drawn when the process starts (fixed under `ren test` and `ren replay`), so keys chosen by an attacker can't force collisions. A map iterates in insertion order, so the seed changes only its speed, never what a program sees (compiler.md, "Bytes stage", "Step 3, as built").

### `Time` and `Instant`

Go's `time.Time` hides a monotonic reading inside a wall-clock time. The reading is lost when the value is serialized, and subtracting two times can then go silently wrong. Ren uses two types, as Rust does:

```ren
pub dep Clock =
  now:     fn() -> Time             // wall clock: can jump, serializable, for timestamps
  instant: fn() -> Instant          // monotonic: for measuring, never serialized
  sleep:   fn(d: Duration)

let started = Clock.instant()
...
log.info("done", took: Clock.instant() - started)   // Instant - Instant → Duration
let bad = Clock.now() - started                      // error: Time - Instant
```

`sim.clock` controls both, and can make `now` jump (an NTP correction) while `instant` keeps advancing steadily. `Time`, `Instant` and `Duration` are in the prelude (stage 7), with operators since stage 9a: `Duration.ms(100)`, `t + d`, and `t - u` for the `Duration` between two. Formatting, parsing and time zones are in the `time` module, with the time zone database built in and pinned for determinism.

### `Decimal`

The danger with money is `0.1` silently becoming a `Float`. One type per literal, and numbers that never convert, prevent it: `price * 0.1` with a `Decimal` price is an error whose help says `0.1d`. `Decimal` is a language number type beside `Int` and `Float`, and its `d` suffix is the language's ([operators.md](operators.md#deferred)), since a literal's type comes from its spelling, which only the compiler reads. Its operations are below:

```ren
type Decimal                               // the language's, 128 bits
  pub fn add(self, b: Decimal) -> Decimal = ...
  pub fn mul(self, b: Decimal) -> Decimal = ...
  pub fn round(self, places: Int, mode: Rounding) -> Decimal = ...
  pub fn div(self, b: Decimal, scale: Int, mode: Rounding) -> Decimal = ...

let price = 19.99d                         // exact: never passes through a Float
let tax = (price * 0.0825d).round(2, HalfEven)
let third = price.div(3d, scale: 2, mode: HalfEven)
let x = 19.99 + 0.01                       // a Float: the spelling says so
```

- **Representation.** 128-bit fixed precision, about 34 significant digits, like C#'s `decimal`. It's an inline value, so it costs nothing in code without `Alloc`. Arbitrary precision lives in `bigint`.
- **No `/` operator.** Every division states its scale and rounding mode. The signature is the truth, applied to arithmetic.
- **Why the language.** Its literals are, so the type is, as `Int` and `Float` are, though most modules don't handle money. A third party's `BigDecimal` or `Money` has no literals; it's built from `Decimal` or `Int`. It is a shared type: `json` decodes numbers into `Decimal` straight from their source text, never through an `f64`, and Postgres's `numeric` maps to it.
- **`Money`** (an amount with a currency) involves policy choices, such as what adding two currencies means, so it belongs in `std.x`.

### HTTP

```ren
type Request  = { method: Method, path: Str, query: Query, headers: Headers, body: Body }
type Response = { status: Int, headers: Headers, body: Body }
type Body = opaque Conn                    // read with `for chunk in req.body.chunks()`

pub fn serve(port: Int, handle: fn(req: Request) -> Response) ! AddrInUse(port: Int)
    uses Net, Async, Alloc
```

- **Middleware is `with`,** not a function from handler to handler. Go needed `func(http.Handler) http.Handler` because it had nothing like `with`.
- **`handle` is a block,** so the routes' `uses` flow into `serve`'s caller, and the compiler knows everything the whole server touches.
- **`Body` is a handle to the connection,** not a stored block, which no type can hold.

---

## Part 3: Conventions

### Error tags

Tags are structural ([errors.md](errors.md#tags-are-structural)), and one error set can't hold two shapes of one tag. If `std` failed with `NotFound(path: Path)`, every user's own `NotFound` would collide with it:

```ren
fn export(id: UserId) ! _ uses Users, Fs =
  let u = Users.get(id) orelse fail NotFound          // the user's NotFound
  let tpl = try Fs.read(template_for(u))              // if std used NotFound(path: Path)...
  // error: NotFound has two shapes in this function
```

So `std` follows one rule (*proposed*, stage 6):

| Kind | Rule | Examples |
|---|---|---|
| Common words | payload-free, by convention, documented in the prelude | `NotFound`, `Timeout`, `Invalid`, `Conflict`, `Forbidden`, `Cancelled` |
| Errors specific to a `std` domain | named for the domain, with a payload | `NoSuchFile(path: Path)`, `ConnRefused(addr: Addr)`, `TlsHandshake(reason: Str)`, `SqlConstraint(name: Str)` |

Every tag `std` uses then either agrees with user code by design or can't collide with it.

### Three implementations, one conformance suite

| Dependency | Real | In-memory | Simulated |
|---|---|---|---|
| `Fs` | the ring | `mem_fs(files)` | `sim.fs(seed, full_disk: 1%)` |
| `Net` | the ring, with TLS | `mem_net(routes)` | `sim.net(seed, partition_at: 3.s)` |
| `Clock` | the system clock | `Clock.frozen(t)`, `test_clock(t)` | `sim.clock` |
| `Http` (client) | `http.client()` | `mem_http(routes)` | `sim.http(seed, p99: 2.s)` |
| `Sql` | the driver | `sqlite.memory` | `sim.sql(seed, conflict_rate: 5%)` |

Simulated implementations need the simulation scheduler, the runtime `sim` that stage 11a brings, and the full set arrives in stage 17. Until then the rule is two implementations, with fault-injecting fakes (`fail_rate:`) from stage 11a.

Each dependency type also ships a **conformance suite**: one set of tests every implementation must pass, including the in-memory and simulated ones. It's a `pub group` over an implementation, which a vendor package imports and runs against its own ([deps.md](deps.md#groups)):

```ren
import blob.{blob_conforms}

group "s3" = blob_conforms(s3.client(test_bucket))
```

That keeps real implementations and fakes in agreement, so a passing simulation means something about production. `database/sql` never had one, and Go driver quality varies as a result.

---

## Part 4: Infrastructure dependency types

`database/sql` works because SQL is a shared language. Generalized, the pattern is: `std` defines the type, vendors implement it, and everyone gets the fakes. Ren applies it to the infrastructure most services touch. Code built on S3 gets `sim.blob(seed, fail_rate: 5%)` without the S3 package doing anything extra.

Queues, stores and locks have no shared language, and their semantics differ in ways that matter: SQS delivers at least once, Kafka is an ordered log, NATS core delivers at most once. A type that hides those differences lies, and an in-memory fake built on the lie makes tests pass falsely. So each type **states its guarantees**, and its simulated implementation **behaves as badly as those guarantees allow**:

```ren
// At least once, unordered. A message not acked within `visibility` is redelivered.
pub dep Queue =
  send:   fn(msg: Bytes) ! QueueFailed(reason: Str)
  stream: fn(visibility: Duration, body: fn(m: Message))
  ack:    fn(m: Message) ! QueueFailed(reason: Str)
// sim.queue redelivers, reorders and duplicates, because the contract allows it
```

**Optional features are separate capabilities,** so a signature shows what code relies on:

```ren
fn claim(job: JobId) -> Lease ! Taken uses Blob, BlobCas =
  try BlobCas.put_if_absent("jobs/\{job}", owner())
```

Code with `uses Blob` alone runs on any store. Code that needs compare-and-swap says so, and can't be wired to a store without it.

| Type | Guarantees | Implemented by |
|---|---|---|
| `Blob`, `BlobCas` | read-after-write consistency; conditional writes by ETag | S3, GCS, Azure Blob, the filesystem |
| `Kv` | linearizable, compare-and-swap by version, TTL | DynamoDB, etcd, single-node Redis, FoundationDB |
| `Cache` | lossy: may drop entries or return stale ones | Redis, Memcached, Cloudflare KV, an in-process LRU |
| `Queue` | at least once, unordered, visibility timeout | SQS, Pub/Sub, RabbitMQ, NATS JetStream |

Left out on purpose:

- **`Lock`.** A distributed lock without fencing tokens is broken: a paused holder's lease expires, and two writers both believe they hold it. `Kv`'s compare-and-swap handles leader election correctly. If `Lock` ever ships, it returns a fencing token, and `sim` pauses holders past their lease to show why.
- **`Log`** (Kafka, Kinesis: ordered partitions with offsets) is a different model from `Queue`. It goes in `std.x`.

Each type costs an interface, written semantics, in-memory and simulated implementations, and a conformance suite. Four is the limit for 1.0.

---

## Part 5: The inventory

**Core data**

| Module | Verdict | Why |
|---|---|---|
| `str`, `bytes`, `fmt`, `sort`, `math` | std | used everywhere; `math` is Ren's own, for determinism |
| `unicode` (normalization, graphemes, case) | std | determinism: tables pinned to one Unicode version |
| `decimal`, `bigint` | std | money; crypto and parsing |
| `random`, `uuid` (v4, v7) | std | determinism: seeded through `Random` |
| `collections` (`Deque`, `Heap`, `OrderedMap`, `BitSet`) | std | ordered iteration matters for determinism |
| `regex` | std | linear time, RE2-style, so a pattern can't hang a server |

**Encoding**

| Module | Verdict | Why |
|---|---|---|
| `json`, `schema` | std | shared types; used everywhere |
| `base64`, `hex`, `url`, `csv` | std | small and stable |
| `toml` | std | the toolchain reads `ren.toml` |
| `protobuf` | std.x | moves with gRPC |
| `yaml` | std.x | a huge spec with endless edge cases |
| `xml`, `msgpack`, `cbor` | std.x | niche |

**Network**

| Module | Verdict | Why |
|---|---|---|
| `net` (TCP, UDP, Unix sockets) | std | primitives |
| `dns` | std | determinism: simulation controls name resolution, so Ren owns the resolver |
| `tls`, `x509` | std | trust |
| `http` (1.1 and 2, server, client, router, SSE) | std | shared types; HTTP/2 because gRPC and modern clients need it |
| `websocket` | std.x | promote once the API settles |
| HTTP/3, QUIC | std.x | still changing |
| `smtp` | out | Go's `net/smtp` is frozen, which is the lesson |

**Crypto** (all std, by the trust test): SHA-2, SHA-3, BLAKE3, HMAC, HKDF, AES-GCM, ChaCha20-Poly1305, Ed25519, X25519, ECDSA P-256, RSA verification, Argon2id, constant-time comparison, a cryptographically secure random number generator. JWT and JOSE go in `std.x`: the specs are full of footguns.

**Data**

| Module | Verdict | Why |
|---|---|---|
| `sql` (the interface) | std | shared type |
| `sqlite` | std | embedded; the interpreted-Ren milestone needs a database |
| `postgres` | std | the database most services use; the wire protocol is written in Ren |
| MySQL, Redis clients | std.x | useful, not universal |
| Kafka, NATS, cloud SDKs | out | vendor churn; they implement the infrastructure types instead |

**Concurrency and resilience:** `Async` ([async.md](async.md)), `xs.par_map` for pure work, `channel`, `select`, a semaphore, a rate limiter, `schedule`, `retry`, `cache` (LRU and TTL), all std. There's no mutex: handler state replaces it. What's built, in the interpreter:

| Where | What |
|---|---|
| the prelude's `Async` | `scope`, `map` and `each` over any pull argument (a collection, a cursor, `&r`, a block `fn() -> Option<T>`, a channel's `items()`), `produce(cap: 16, f) fn(items) => ...`, whose `f` sends through the `Send<T>` it installs, `Send.send(x)`, `map_pull(src, max: 64, f) fn(results) => ...`, `beside`, `background`, `both`, `race`, `timeout`, `isolate`, `until`, `tick`, `yield`, and `worker()`, the worker a task runs on (0 under `single`, 0 or 1 under `sim`) |
| `release` | a word, not a function: `try release Next.get(id)` in an operation lets go of its instance for that one call ([async.md](async.md#shared-state-is-a-handler)) |
| the prelude's `Proc` | `run(cmd, args, kill: Kill = Tree)`: a cancel kills the program's process group, or with `Child` the program alone; `sim.proc()`'s `SimProc.kills()` says which |
| `sync` | `channel(cap)` for `Chan<T>`, whose ordinary function `items()` is a cursor that receives, `Events.items()` through an alias; `semaphore(n)`, `limit() over any`, `batcher()` |
| the prelude's `striped` | `striped(h, by: Key(n: 16) \| Worker, merge: Sum \| Max \| Min \| Concat \| Custom(m))`: `h`'s instances under fixed keys, a call with a first argument routed by its hash or by `Async.worker()`, one with none run on every stripe and folded by `merge:`, refused at the `with` where a fold is needed and missing |
| the prelude's `actors` | `actors(h, max: 10_000, mailbox: 64, evict: Lru, chaos: false)`, `max:` one cap for the whole family, `mailbox:` each key's bound, for `Actors<K, D>`, `dep Docs = Actors<DocId, Doc> ! StoreDown`: `Docs.at(k) fn() => ...`, `Docs.at_all([a, b]) fn() => ...`, which holds several keys in their order and inside which `at` of a held key doesn't wait (of another, it panics), `Docs.post(k, Doc.Call.Edit { op })`, `evict(k)`, `evict_idle(d)`, `each`, `count()`, `made()`, `evicted()`; `evict: Lru` is sampled LRU, a full family evicting the oldest-used of 5 actors with no pin and no mail that `Random` samples (K1b: within 0.55 points of exact LRU's hit rate); `chaos: true` evicts what `Random` picks at each call |
| the prelude's `Instances` | the runtime's keyed instance family, which `striped` and `actors` are written over and any library can be: `open`, `pin`, `enter`, `visit`, `call`, `post`, `hold`, `make`, `made`, `keys`, `evictable`, `idle`, `evict`, `counts`, `close`, and `at_edge`, a block run at each call into the family, `actors`' chaos; each take writes an instance's use stamp, and a full family gives the library's `victim` its evictable instances as `Stamped<K>`, key and stamp; ambient, so no `uses` names it; with `family_kept`, a block's value and error kept, and `lib_panic`, which any library may call as `actors` and `striped` do |
| each dependency's `D.Call` | its calls as data, `Doc.Call.Edit { op }`, written by the compiler; generic code's `D.Call<R ! E>` is the prelude's `Call<D, R, E>`, with `first_hash`, `sum`, `max`, `min`, `concat` and `fold`, and `operations(h)` the operations as data |

All of it is interpreter-only but `release`, which is a plain call natively; `ren build` refuses the rest as it refuses `Async.scope` (compiler.md, "Services stage").

**Observability:** `trace`, `log`, `metrics`, the flight recorder and the OTLP exporter, all std. Logging is the trace stream, so there's no Go-style split between `log` and `slog`. A Prometheus exporter goes in `std.x`.

**OS and process:** `os` (environment, arguments, signals, exit), `process`, `path`, directory walking and globbing, and minimal terminal support (detecting a TTY, colors), all std. Full terminal UIs are out.

**Testing and tooling:** `test`, `sim`, property tests, snapshots, fuzzing, benchmarks, golden files and `cli` (arguments derived from a type), all std. `ren.syntax`, the compiler as a library like Go's `go/ast`, goes in `std.x` until the compiler is written in Ren.

**Compression and archives:** gzip and deflate (HTTP needs them), zstd (the build cache) and tar are std. Brotli and zip go in `std.x`.

**Out entirely:** GUI, ORMs, web frameworks, HTML templating (`std.x` at most), Markdown, image and audio formats, internationalization, GraphQL, numerical arrays.

### Snippets

Decoding comes from the type, with validation on the type that needs it:

```ren
type Email = opaque Str
  pub fn parse(s: Str) -> Email ! Invalid =
    if s.index("@").is_some() then s else fail Invalid

type Signup = { email: Email, name: Str, plan: Plan = Free }

let s = try json.decode<Signup>(body)      // checks Email, fills in the default plan
```

Data with no type is a `Value`, `json.decode<Value>(body)`, the tree
every medium decodes to; a sub-document kept exactly, to forward or
decode later, is a field typed `json.Raw` ([shapes.md](shapes.md#value-the-dynamic-view)).

Retrying is a call, which says how many times and which errors it retries:

```ren
try retry(5, on: Declined) fn() =>
  try Async.timeout(3.s) fn() => try Billing.charge(card, amount)
```

Configuration comes from a type, and std's `Secret<T>` keeps a field out of logs and traces: it parses as `T` does, has no `repr`, and its `show` redacts, so the derived walk never writes it. It's written to the wire only through a named look over its public `reveal`:

```ren
type Cfg = { port: Int = 8080, db_url: Secret<Str>, region: Str }

let cfg = try config.load<Cfg>()           // reads PORT, DB_URL, REGION
```

Query parameters are bound, never spliced into the string:

```ren
for user in DB.rows<User>(t"select * from users where plan = \{plan}")
  ...
```

`t"..."` is a template, not a string: the library sees the parts and the holes apart, binds each hole as a parameter, and checks the query against the schema while building, through a signature `let`. A `Str` where a template is expected is a type error, so a query can't be built by pasting strings. There's no `sql"..."` prefix; the library is an ordinary method that takes a template ([strings.md](strings.md#templates), decided; built in stage 12).

---

## Part 6: What Ren writes, and what it borrows

Zig replaces a borrowed component when keeping it blocks a goal (cross-compilation, compile speed), not for purity. LLVM stays for optimization because nothing is blocked there. Ren adds a requirement of its own, rule 3: borrowed code computes, and Ren supplies its effects.

| Borrowable: its effects can be supplied | Not borrowable as it is |
|---|---|
| SQLite: its VFS layer and allocator are pluggable, so `sim.fs` can inject torn writes into SQLite itself | most database client libraries, which open their own sockets |
| rustls: sans-IO, with randomness and time injected | OpenSSL with its default I/O |
| zstd: pure computation, with a custom allocator | anything that starts its own threads |
| aws-lc primitives: pure computation | anything that reads the system clock or `/dev/urandom` itself |
| Unicode and time zone data, generated into Ren tables | ICU |

The rule of thumb: ordinary code a good engineer can write and test (parsers, protocols, data structures) is **written in Ren from the start**, because that's where dogfooding is cheap. Ren borrows only where the work is decades of hardening (SQLite, cryptographic primitives) or a moving security target (TLS).

| Component | Interpreter (to stage 12) | Native (stage 13 to 1.0) | Later |
|---|---|---|---|
| json, http, postgres protocol, dns, url, toml, csv, regex, decimal, gzip, collections | Ren | Ren | Ren |
| crypto primitives | OCaml libraries | aws-lc, through FFI | aws-lc: constant-time code needs assembly |
| TLS | ocaml-tls | rustls-ffi on aws-lc | perhaps the protocol state machine in Ren |
| SQLite | OCaml bindings | C through FFI, VFS routed to `Fs` | C, permanently |
| zstd | OCaml bindings | C through FFI | C; perhaps decompression in Ren |
| Unicode and time zone data | generated tables | generated tables | generated tables |

rustls brings a Rust toolchain into the runtime's build. Ren ships it as prebuilt static libraries for each target, so users never need Rust. If that proves painful, aws-lc's own TLS layer is the fallback, at the cost of memory safety.

---

## Roadmap

Stage numbers match the [README roadmap](README.md#roadmap).

| When | What |
|---|---|
| **Stage 5** | the prelude as a module; pure `fmt`, `math`, `sort` with methods |
| **Stage 6** | the error-tag convention; everything that parses or validates |
| **Stage 7** | `Clock` (with `Time`, `Instant` and `Duration`), `Random` and `Console`, each with a real and a test implementation; conformance suites as groups |
| **Stage 8** | `str` and `bytes`; `Fs`, `Os` and `path`, each real and in-memory; `config`, `schedule`, `retry`; the infrastructure types with in-memory implementations |
| **Stage 9** | operators; `Map` and `Set` ([operators.md](operators.md)) |
| **Stage 10** | handlers `over` a dependency, like `transaction() over Sql`; journal fixtures for tests |
| **Stage 11a** | `Net` and `Async` ([async.md](async.md)); `channel`; fault-injecting fakes; buffers leased from a pool for `Net` |
| **Services** | `striped` and `actors` in the prelude over the runtime's `Instances`; `Async.produce`, `Async.map_pull`, `Send<T>`, `Async.worker()`, `Async.beside` and `Async.background`; `Chan<T>`'s `items()`; `Proc.run(kill:)` (done, in the interpreter) |
| **Stage 12** | `Decimal`, a language number type, and its `d` suffix; `Secret<T>`; interpolation libraries can intercept; `json`, `cli`, `config` and SQL rows over shapes ([shapes.md](shapes.md)); cursors over files, sockets and SQL rows; `http` server, client and router; `sqlite`; `cache`; `log`; property and snapshot tests |
| **↑ interpreted Ren** | a JSON API on SQLite, configured from the environment, with retries on an outgoing HTTPS call, whose tests run in under a second on in-memory fakes |
| **Stage 13** | packages and `std.x`; the compatibility promise starts; `tls`, crypto, `dns`, `toml`, tar, zstd, `postgres`, HTTP/2; conformance suites for vendor packages |
| **Stage 15** | non-allocating pure modules (`checksum`, `hash`, parsers), `push_within`, registered buffers |
| **Stage 16** | `Array<T, soa>`, in-place `unique` APIs in `collections` |
| **Stage 17** | `sim.*` for every dependency; the flight recorder and the OTLP exporter |
| **After 1.0** | promotions from `std.x`; perhaps the TLS state machine in Ren |

---

## Open questions

- What does flottning need? Its dependencies decide what 1.0 has to ship.
- Is `Alloc` inferred before stage 15 and enforced from it, or added to signatures all at once in stage 15? Inferring it early keeps `std`'s public signatures stable.
- Is rule 3 a hard rule or a warning? We're leaning hard for `std`, with `trust` and non-simulatable flagging covering user FFI.
- Does `std.x` version separately from `std`, or move with the toolchain?
- When does `websocket` move from `std.x` to `std`?

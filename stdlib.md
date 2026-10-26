# Standard Library

**Own the shared types. Fake every dependency. Borrow the computation, own the effects.**

This doc covers what ships with Ren: which modules are in the standard library, which are left to packages, the types every library has to agree on, and the conventions that keep the ecosystem testable. How the runtime talks to the operating system is in [runtime-io.md](runtime-io.md).

> **Status:** design. Nothing here runs yet beyond the prelude types used by the interpreter, and `Clock`, `Random` and `Console` with their test implementations (stage 7, [deps.md](deps.md)). Decisions marked *proposed* are recommendations, not settled; see [Open questions](#open-questions).

---

## The short version

```
 std owns the shared types        Time, Decimal, Request, Sql, Blob: libraries agree on them
 three implementations each       real, in-memory, simulated, plus one conformance suite
 the producer owns the loop       for line in Fs.lines(path): push streams, no Reader objects
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
prelude    Int, Str, Bytes, Array, List, Map, Set, Option, Result, Duration, Time
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

### Streams: the producer owns the loop

Go's `io.Reader` is a stateful object behind an interface. Ren has neither half of that: there are no traits, and a closure can't hold mutable state, because state lives only in handlers. What Ren does have is the transparent closure parameter, which never allocates and passes its errors and dependencies through to the caller. So the producer owns the loop and calls a body for each item, which is where Go itself moved with range-over-func in 1.23:

```ren
pub fn lines(path: Path, body: fn(line: Str)) ! NoSuchFile(path: Path)
    uses Fs, Alloc

for line in Fs.lines(path)                 // sugar for: Fs.lines(path) fn(line) => ...
  if not line.starts_with("#") then
    try Index.add(parse(line))             // errors and `uses` flow out through the body
```

`for x in f(...)` is sugar for passing the loop body as `f`'s last parameter (*proposed*, stage 12). Lines, SQL rows, HTTP bodies and byte chunks all use the same shape:

```ren
for chunk in Net.chunks(conn)              // chunk: Bytes, leased from the runtime's pool
  try out.write(chunk)
```

When the body returns, the chunk's reference count reaches zero, its buffer goes back to the pool, and the next read is submitted ([runtime-io.md](runtime-io.md#buffers-lent-or-leased)). Backpressure comes for free: the producer can't run ahead of a body that hasn't returned.

Push iteration can't easily zip two streams or read exactly *n* bytes for a framed protocol. Two escape hatches cover that:

- **`Async.pull(seq)`** runs a push sequence on a fiber and hands back a pull iterator, like Go's `iter.Pull`.
- **A buffered reader value** keeps its position in an `inout` value, which value semantics allow: `var r = bufio.reader(conn)`, then `try &r.read_exact(4)`.

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

`sim.clock` controls both, and can make `now` jump (an NTP correction) while `instant` keeps advancing steadily. `Time`, `Instant` and `Duration` are in the prelude (stage 7), with methods, `Duration.ms(100)` and `t.plus(d)`, until operators and literals like `100.ms` arrive (stage 9). Formatting, parsing and time zones are in the `time` module, with the time zone database built in and pinned for determinism.

### `Decimal`

The danger with money is `0.1` silently becoming an `f64`. Putting `Decimal` in the prelude doesn't prevent that. Typing literals by context does (*proposed*, stage 9):

```ren
type Decimal = opaque i128
  from_literal(digits: Str) => ...         // called by the compiler at compile time
  add(a, b) => ...
  mul(a, b) => ...
  pub fn round(self, places: Int, mode: Rounding) -> Decimal = ...
  pub fn div(self, b: Decimal, scale: Int, mode: Rounding) -> Decimal = ...

let price: Decimal = 19.99                 // exact: never passes through f64
let tax = price.mul(0.0825).round(2, HalfEven)
let third = price.div(3, scale: 2, mode: HalfEven)
let x = 19.99 + 0.01                       // nothing in context says Decimal: f64, as before
```

- **Representation.** 128-bit fixed precision, about 34 significant digits, like C#'s `decimal`. It's an inline value, so it costs nothing in code without `Alloc`. Arbitrary precision lives in `bigint`.
- **No `/` operator.** Every division states its scale and rounding mode. The signature is the truth, applied to arithmetic.
- **Why `std`, not the prelude.** Most modules don't handle money, so it fails the prelude's test. It is a shared type: `json` decodes numbers into `Decimal` straight from their source text, never through an `f64`, and Postgres's `numeric` maps to it.
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
- **`handle` is transparent,** so the routes' `uses` flow into `serve`'s caller, and the compiler knows everything the whole server touches.
- **`Body` is a handle to the connection,** not a stored closure, so it needs no `..e` or `..d`.

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

Simulated implementations need the simulation scheduler, so they arrive in stage 17. Until then the rule is two implementations, with fault-injecting fakes (`fail_rate:`) from stage 11.

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
  try BlobCas.put_if_absent("jobs/{job}", owner())
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

**Concurrency and resilience:** `Async` ([async.md](async.md)), `xs.par_map` for pure work, `channel`, `select`, a semaphore, a rate limiter, `schedule`, `retry`, `cache` (LRU and TTL), all std. There's no mutex: handler state replaces it.

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
    if s.contains("@") then s else fail Invalid

type Signup = { email: Email, name: Str, plan: Plan = Free }

let s = try json.decode<Signup>(body)      // checks Email, fills in the default plan
```

Retry policies are values:

```ren
let backoff = schedule.exponential(100.ms).jitter().up_to(5)

with retry(backoff) over Async.timeout(3.s) in
  try Billing.charge(card, amount)
```

Configuration comes from a type, and `secret` keeps a field out of logs and traces:

```ren
type Cfg = { port: Int = 8080, db_url: secret Str, region: Str }

let cfg = try config.load<Cfg>()           // reads PORT, DB_URL, REGION
```

Query parameters are bound, never spliced into the string:

```ren
for row in Sql.query(sql"select * from users where plan = {plan}")
  ...
```

`sql"..."` needs interpolation a library can intercept, like tagged templates in JavaScript. Without it, every SQL library has either an injection risk or an awkward API, so it has to land before the first SQL library does (*proposed*, stage 9).

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
| **Stage 9** | `Map` and `Set`; `from_literal` and `Decimal`; interpolation libraries can intercept |
| **Stage 10** | handlers `over` a dependency, like `transaction() over Sql`; journal fixtures for tests |
| **Stage 11** | `Net` and `Async` ([async.md](async.md)); `channel`; fault-injecting fakes; buffers leased from a pool for `Net` |
| **Stage 12** | `json`, `cli`, `config` and SQL rows over shapes ([shapes.md](shapes.md)); `for x in f(...)`, push streams; `http` server, client and router; `sqlite`; `cache`; `log`; property and snapshot tests |
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
- How does interpolation hand its parts to a library: `sql"..."` resolved through a member of the type, or something else?
- Does `std.x` version separately from `std`, or move with the toolchain?
- When does `websocket` move from `std.x` to `std`?

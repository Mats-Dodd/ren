# Layers

**A few universal primitives in the language; std builds on them, one
layer at a time, with nothing a user lacks.**

This is the map every part of the standard library is placed on: what
the language gives, what each layer of std builds from the one below,
and where a user's own code plugs in. Which features belong to the
language and which to std is [foundations.md](foundations.md#20-what-the-language-owns-and-what-std-owns)
decision 20; what std contains is [stdlib.md](stdlib.md).

> **Status:** decided on 2026-10-30, from the research in
> research/stdlib/ (Go's standard library, Effect v4's, and where Zig,
> Rust, Roc, Eio, Koka, Effekt, Swift, Unison, Python and Gleam draw
> the line). Reshaping today's `Fs`, `Proc` and `Net` to rule 1 lands
> in stage 12.

---

## The short version

```
 the language is a few primitives    data, dependencies, blocks, the tree, build time, trust
 one door to the world               Async.submit(D.Call), inside trust
 operations are the smallest set     everything else is a function over them
 fake the bottom                     three implementations at the world; above it, real code
 the layer never shows at the call   it always shows to a handler over the dependency
 each layer uses only those below    and std asserts it
```

---

## The stack

```
L0  the language     data and shapes · dependencies (dep, handler, with, over, D.Call)
                     · blocks, cursors, generators · the tree (scope, spawn, until, families)
                     · build time (top-level and signature let) · trust: foreign fn, submit
─────────────────── one door to the world: Async.submit(D.Call), in trust
L1  the world        Fs · Net · Clock · Random · Proc · Os · Signal · Console
                     small, shaped like the system calls, each answered by a driver
L2  the kit          writers · byte cursors and framing · buffering · encodings over
                     shapes · Time, Bytes, Str · Async's combinators · sync · actors,
                     striped · resources as families
L3  protocols        http · tls · dns · sql and sqlite · cli · config · log and trace exporters
L4  batteries        an http server with routing and middleware as handlers · test harnesses
```

**L0 is Ren's universal interface.** Zig 0.16 puts the world behind one
`Io` value, a vtable of 51 operations passed like an allocator. Ren gets
the same universality from one mechanism instead of one value: each
world dependency is a sum of calls, `D.Call`, and one door, `submit`,
answers all of them ([runtime.md](runtime.md#drivers-are-ren)). A
signature still names exactly the capabilities it uses, `uses Fs`, never
all of them at once, and a handler can intercept any of them, which a
value passed by hand can't promise.

**The runtime's built-in handlers sit at L0 too:** `Async`, the keyed
instance family, `Mem`, `Alloc` and the journal. With the drivers'
door, they're the only privileged code (decision 20, rule 2).

## Four rules

### 1. A dependency's operations are the smallest set its implementations must provide

Everything else is a function over them, written once inside the `dep`
declaration, as `Fs.read_str` is today:

```ren
pub dep Fs =
  open: fn(p: Path, mode: Mode) -> File ! FsError
  read_at: fn(f: File, at: Int, buf: &Bytes) -> Int ! FsError
  write_at: fn(f: File, at: Int, b: Bytes) -> Int ! FsError
  sync: fn(f: File) ! FsError
  close: fn(f: File)
  stat: fn(p: Path) -> Stat ! FsError
  list: fn(dir: Path) -> Array<Path> ! FsError
  rename: fn(from: Path, to: Path) ! FsError
  remove: fn(p: Path) ! FsError

  pub fn read_all(p: Path) -> Bytes ! FsError uses Fs = ...
  pub fn write_atomic(p: Path, b: Bytes) ! FsError uses Fs = ...   // temp, sync, rename
  pub fn lines(p: Path) -> ... uses Fs = ...
  pub fn walk(dir: Path) -> ... uses Fs = ...
```

- **At L1, the operations are shaped like the system calls,** so a
  driver is small, `sim` models what the system really does (a write
  that's torn, a sync that lies, a crash between the write and the
  rename), and a conformance suite covers the whole contract.
- **Every L1 dependency's operations** are specified in
  [runtime-io.md](runtime-io.md#part-4-the-worlds-interfaces).
- **`Proc`** is `spawn`, `wait` and `kill`, with pipes; today's `run`,
  which collects what the program printed, is a function over them.
  **`Net`** is `listen`, `accept`, `connect`, `recv`, `send` and
  `close`; `Net.connections` and framing are functions and L2.
- **The same rule holds at every layer.** `Sql`'s operations are what a
  driver must answer; query plans, row decoding and transactions are
  functions over them.

### 2. Fake the bottom, and everything above is real

- **Three implementations (real, in-memory, simulated) and one
  conformance suite are owed at L1,** where the drivers are. They ship
  in the dependency's own module from its first release.
- **Everything above runs as ordinary code over L1,** so it's tested and
  simulated by what's below it. sqlite over `sim.fs` gets torn writes
  inside SQLite itself; http over `sim.net` gets real partitions and
  reordering. That's TigerBeetle's and FoundationDB's discipline.
- **A dependency above L1 may ship an in-memory fake, for speed,** and
  owes a conformance suite whenever others implement it (`Sql`'s
  drivers). It doesn't owe a simulated one: simulation comes from below.

### 3. The layer never shows at the call site, and always shows to a handler

- **Operations and functions are called alike,** `Fs.read_all(p)` and
  `Fs.read_at(f, 0, &buf)`, so std reads as one cohesive library.
  The hover and the docs say which is which: "an operation:
  implementations provide it" or "a function over `Fs`".
- **A handler `over Fs` sees only operations.** A recorder, a fault
  injector or `sim` sees the `read_at` calls `read_all` makes, at the
  smallest unit, so wrapping at the bottom catches everything above.
- **No capability is discovered at run time.** A fast path,
  `copy_file_range` or `sendfile`, is an operation, called explicitly
  by the function that wants it, and every handler implements every
  operation of its dependency. So a handler written over a dependency
  can't hide one of its abilities, the problem Go's optional interfaces
  (`http.Flusher`, `io.WriterTo`) had once anything wrapped them.

### 4. Each layer uses only the layers below it, and std asserts it

std states its own structure in Ren, checked on every build:

```ren
assert http.serve.uses <= [Net, Clock, Async]
assert not json.decode.uses.includes(Fs)
```

with a check on imports between std's layers beside it, so an L2 module
that imports an L3 one is a build error, not a review comment.

## Where a user plugs in

At every layer, with the tools std uses:

| Layer | A user writes | With |
|---|---|---|
| L1 | a new primitive: a serial port, a GPU queue, a ring of their own | a `dep` and a driver in `trust` (drivers are open) |
| L2 | a compression writer, a framing cursor, a cache | a handler `over` a writer, a cursor, a family |
| L3 | a protocol: msgpack, a Kafka client, a database's wire format | plain Ren over L1 and L2, simulated for free |
| L4 | a framework | handlers and wirings |

Nothing at L2 and above needs `trust`. The privilege is L0's, closed and
listed, which is why the list stays small.

## The writer

Decided on 2026-10-30. Reading has cursors; writing is a dependency,
the one `produce` already installs:

```ren
pub dep Send<T> =
  send: fn(x: T)
  flush: fn()                    // a no-op unless something buffers
```

- **A sink is a dependency.** `fn render(doc) uses Send<Bytes>` writes;
  its caller says where: `with Fs.writer(f) { render(doc) }`,
  `Net.writer(c)`, `Console.out()`. A generator's `yield` and a writer
  are the same thing. (streams.md's undeclared `Writer` is this.)
- **Wrapping is `over`:** `with gzip() over Fs.writer(f) { ... }`;
  `buffered(64k)` gathers small writes; a hash is a stateful handler
  that passes bytes on and keeps a digest. Go's `io.Writer` composition,
  with nothing new in the language, and by rule 3 a recorder or `sim`
  at the bottom sees every write.
- **Ending is the handler's scope end.** Leaving the `with` flushes,
  closes and runs the handler's `finally` (gzip's trailer), so there's
  no `close()` to forget. `flush` is for protocols that need bytes on
  the wire mid-stream.
- **Short writes are the bottom's business.** `Fs.writer` loops
  `write_at`, `Net.writer` loops `send`, so `send` takes everything.
- **A sink's error is its handler's.** A full disk or a reset socket
  fails the `with`, cancelling the writer like a failing sibling, so
  `send` has no error and `render` never names the medium's.
- **Two sinks at once take a writer as a value,** a handle to an
  installed `Send`; one implicit sink is the common case, and nothing
  names dependencies at the type level.

## Still to decide

- **What a log line or a span needs in its row.** The proposal: events
  go to the runtime's trace stream, beside the journal, so `log.info`
  needs no `uses`, and the only ways out are exporters, handlers
  installed by `main` with their own `uses Net` or `uses Fs`.

## Borrowed from

- **Zig 0.16's `std.Io`:** one interface for every way to block or be
  nondeterministic, its implementations swappable. Ren keeps the
  universality and splits the capability.
- **Go:** small interfaces over shared types (`io.Reader`,
  `http.Handler`), helpers written once over them (`io.ReadAll`), and
  the optional-interface trap to avoid.
- **Effect v4:** one cohesive surface over services, and the lesson
  that conformance suites and fakes belong in the published package.
- **TigerBeetle, FoundationDB:** simulate the bottom, run the real code
  above it.
- **Rust:** what happens when std doesn't own the shared types.

# Runtime I/O

**Hand the kernel the work, not the question.**

This doc covers how Ren code reaches the operating system: the shape of an I/O call, who owns a buffer while the kernel uses it, how cancellation finishes, how calls are batched, and how all of it sits under narrow dependencies like `Fs` and `Net`. What the standard library builds on top is in [stdlib.md](stdlib.md).

> **Status:** design. The interpreter does no I/O through this model yet. `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc` and `Net` are dependencies today (stages 7, 8 and 11a, [deps.md](deps.md)), whose real implementations call OCaml's standard library and `Unix` directly; `Net`'s sockets are non-blocking, and each wait is the scheduler's, on `Unix.select`; `Proc.run` waits for its program as the scheduler's wait too, looking with `waitpid` and `WNOHANG` at a timer, and a cancel kills the program, SIGTERM and then SIGKILL after the cleanup deadline, and waits for it to exit. `Str`, `Bytes` and `Path` exist (stage 8), with `Str.from_utf8` the one fallible way from bytes to a string. Decisions marked *proposed* are recommendations, not settled; see [Open questions](#open-questions).

---

## The short version

```
 completion, not readiness       hand over the operation and the buffer; get told when it's done
 &buf means the kernel's turn    nobody else sees buf until the call returns
 cancelling waits                a cancelled read returns only once the kernel lets go
 one submission, many calls      the scheduler batches every fiber's pending calls
 a call is a value               submission, completion and journal entry have one shape
 narrow capabilities, one ring   Fs, Net, Clock, Random, Console, Os in signatures; one queue underneath
```

---

## Three rules

**1. Completion, not readiness.**
epoll tells a program when a socket is ready, and the program then makes the call. io_uring takes the operation and the buffer, and reports when the operation is done. Ren's I/O is completion-shaped everywhere. A readiness backend (epoll, kqueue) can be wrapped to look like completion easily, while the other direction is hard, so this costs nothing on platforms without a completion API.

**2. A call is a value.**
An io_uring submission is a record of an operation and its arguments, and a completion is its result. A dependency call has the same shape, `D.Call`, the value the compiler writes for each dependency (foundations.md decision 18), and so does an entry in the effect journal. The kernel is the outermost handler, and `sim.fs` and `sim.net` take its place by implementing the same dependencies.

**3. Narrow capabilities, one ring.**
A signature says `uses Fs` or `uses Net`, never a catch-all `Io`. Underneath, every capability goes through one submission queue owned by the runtime. Signatures stay precise, and batching stays global.

---

## Part 1: The model

### Buffers: lent or leased

Every I/O call takes its buffer in one of two ways, and never as "wait until ready, then read":

**Lent.** The caller passes `&buf`, and the kernel has the buffer until the call returns:

```ren
let n = try Fs.read(file, &buf)            // the kernel has exclusive access to buf
```

`&` already means nobody else can observe `buf` during the call, and value semantics mean there's no alias to it anywhere. That's exactly what a completion API needs.

**Leased.** The runtime hands out a buffer from a pool it registered with the kernel ahead of time:

```ren
for chunk in Net.chunks(conn)              // chunk: Bytes from the pool
  handle(chunk)
// last reference dropped → the buffer goes back to the pool
```

Ten thousand idle connections each holding a 64 KB receive buffer waste 640 MB. With io_uring's provided buffers, the kernel takes a buffer from the shared pool only when data actually arrives. Reference counting returns it with no lease protocol to get wrong: when the count reaches zero, the buffer goes back to the ring.

A slice of a chunk kept past the body's turn is an ordinary root (foundations.md, decision 17), so it holds the buffer. Under pool pressure the runtime may move a held chunk to the heap, at a safepoint and only when its root isn't shared; positions count from the value, so no program can tell ([strings.md](strings.md#retention), [streams.md](streams.md#data-cursors-you-keep)). Debug builds report it, and a pool metric counts it.

Registered buffers, pinned once so each call skips setup, fit code without `Alloc`. A hot path that uses only pooled buffers needs neither `Alloc` nor per-call kernel work.

### Cancelling waits for the kernel

Rust's async I/O lends out `&mut buf`, and dropping a future cancels it at once. With a completion API the kernel may still be writing into a buffer that has been freed, which is why tokio-uring needs a different, owned-buffer API.

Ren avoids the problem by rule (*proposed*, stage 11a):

> A call cancelled while the kernel holds its buffer returns only after the kernel confirms it has let go.

```ren
let n = Async.timeout(50.ms) fn() =>
  try Net.recv(conn, &buf)
```

When the timeout fires, the runtime submits a cancel request for the read and waits for its completion before `Async.timeout` returns. `buf` is never touched after the call returns. Ren can keep this rule where Rust can't because cancellation happens only at dependency calls and is allowed to wait, and structured concurrency means no task outlives the block that started it.

Some operations can't be stopped once the kernel has started them; a regular file read may simply finish. The wait is then the remaining time of that operation, which is bounded.

### Batching

Fibers pause at every dependency call. The scheduler collects the calls pending across all fibers and submits them with one system call:

```ren
let srcs = Async.map(paths) fn(p) => try Fs.read_all(p)
// 500 reads → 500 submissions → one io_uring_enter
```

Pure code can't observe the order of dependency calls, so merging them is safe. This is the README's automatic batching, applied to the kernel.

### Linked operations

io_uring can chain operations in the kernel, such as "write, then fsync, and skip the fsync if the write fails". Ren exposes the common chains as single calls (*proposed*):

```ren
try Fs.write_then_sync(file, offset, bytes)
```

`sim.fs` treats the pair as two steps, so it can still crash between them or lie about the sync.

---

## Part 2: Capabilities over one ring

```
 user code sees      Fs    Net    Clock    Random    Console    Os    Alloc    Async
                       \     |      |        |         |       /
 runtime handler        ring: io_uring · epoll · kqueue · IOCP · sim
                        requires Unsafe; one per program, installed by main
```

| Capability | Covers |
|---|---|
| `Fs` | files, directories, metadata, sync |
| `Net` | TCP, UDP and Unix sockets; DNS is a `std` module built on `Net` |
| `Clock` | `now` (wall clock), `instant` (monotonic), `sleep`, timers |
| `Random` | seeds for hashing and the cryptographic random number generator |
| `Console` | writing a line to standard output, which `print` goes through |
| `Os` | environment, arguments, signals, exit |
| `Proc` | running other programs |

There's no single `Io`. Each is an ordinary dependency type, declared with `dep`, so `mem_fs`, `Clock.frozen` and `sim.net` implement them like any user handler would. Finer capabilities (`Fs.read` without `Fs.write`, a directory, an address) can split off later without changing this model.

Why not one capability? io_uring itself shows the cost. It had a run of kernel vulnerabilities, and several large operators (Google among them) turned it off, partly because one interface that can do everything is impossible to audit. A function that says `uses Io` tells a reader almost nothing. `uses Fs` tells them it never opens a socket.

### Journal entries

A journal entry has the shape of a submission and its completion (*proposed*, stage 10):

```
{ task: 17, seq: 412, dep: Fs,  op: read,   args: (file: 7, len: 4096), result: Ok(4096 bytes) }
{ task: 17, seq: 413, dep: Net, op: recv,   args: (conn: 3, len: 65536), result: Cancelled }
{ task: 17, seq: 414, dep: Net, op: cancel, args: (seq: 413),           result: Ok(()) }
```

- **`task` and `seq`** come from structured concurrency, so an entry knows who made the call and in what order.
- **Cancellation is an operation** with its own entry, so replay reproduces exactly when the kernel let go.
- **`result`** is what level 3 of the recorder stores for exact replay. Lower levels keep only the operation and timings.

This is the format question from the README's roadmap. Taking the shape from the kernel interface means simulation, replay and migration all see the same thing the hardware saw.

---

## Part 3: Platforms

| Platform | Backend | Notes |
|---|---|---|
| Linux | io_uring | the reference backend |
| Linux, restricted | epoll, wrapped as completion | container runtimes and hardened hosts often block io_uring, so this is required, not optional |
| macOS, BSD | kqueue, wrapped as completion | system calls go through libSystem on macOS |
| Windows | IOCP | already completion-based |
| Wasm | WASI | later |
| Simulation | `sim.*` | the same dependencies, implemented by the simulator |
| Interpreter | OCaml's Eio | completion-based, with an io_uring backend on Linux and a portable fallback |

### The primitive layer

The standard library is written in Ren on top of a small set of primitives: submit an operation (read, write, open, accept, connect, timer, cancel), wait for completions, get random bytes, plus the basics of `Str` and `Bytes`.

- **Until the runtime core,** the primitives are OCaml, built on Eio, so the interpreter already uses the right model.
- **From the runtime core,** the primitives and the rest of the runtime (fibers, the scheduler, reference counting, the allocator, the journal) are native, in the runtime's implementation language, which is still open, and linked with the compiler's output. The core does no I/O itself: drivers answer its calls ([runtime.md](runtime.md)).

Everything above the primitives carries over unchanged from the interpreter to native code. Only the primitives are rewritten.

### TLS and kTLS

TLS sits above `Net` as a handler. The library under it must be sans-IO, taking bytes in and giving bytes out, with randomness and time supplied by Ren, or a seed would no longer replay the same handshake. That's why `std` borrows rustls ([stdlib.md](stdlib.md#part-6-what-ren-writes-and-what-it-borrows)).

On Linux, once the handshake is done, the session keys can be handed to the kernel (kTLS). The kernel then encrypts and decrypts, and `Net.chunks` keeps its zero-copy path. Under `sim.net`, real TLS runs with a seeded random number generator and the simulated clock, so expired certificates, clock skew and failed handshakes replay exactly.

## Part 4: The world's interfaces

These are L1 of [layers.md](layers.md): the operations every
implementation of a world dependency provides, real, in-memory and
simulated, and every driver answers. Each is shaped like the system
call under it. Everything a program usually calls, `Fs.read_all`,
`Proc.run`, `print`, is a function over them, written once inside the
`dep` (layers.md, rule 1), and called the same way.

> **Status:** decided on 2026-10-30 as the shapes; names, argument
> details and error variants are refined by the runtime core stage,
> which builds the drivers, and recorded in compiler.md. Today's
> operations keep working as functions of the same name and meaning, so
> no call site changes.

### What every world dependency shares

- **Handles are keys in a family.** A `File`, `Conn`, `Listener`, `Child`
  or `Pipe` is data: an id and its incarnation, copied freely. What it
  names lives in the dependency's family ([concurrency.md](concurrency.md),
  "Resources are families"): the open files' cap is `max:`, a handle
  whose resource was closed or evicted fails with `Closed`, and the
  family's end closes what's left, so no program leaks one and there's
  no close rule. `close` is still an operation, to let go early.
- **Buffers are lent or leased** (Part 1): `read_at(f, at, &buf)` lends
  `buf` until the call returns and gives the count; a leased chunk comes
  from the runtime's pool and goes back when its count reaches zero.
- **Counts can be short.** `write_at` and `send` give how much they
  wrote, as the system does; `Fs.write_all` and friends loop. A count of
  0 from a read is the end.
- **Every operation that waits can be cancelled,** and returns only once
  the kernel lets go (Part 1). A cancelled read had no effect. A
  cancelled write may have happened in part: its reply says how much,
  the journal records it, and `sim` explores both.
- **One error set each,** with the system's reasons as variants and
  `Failed(reason: Str)` for the rest, so a caller matches what it can
  handle and passes on the rest.
- **What `sim` models is part of the contract,** and the conformance
  suite checks that every implementation allows it: listed under each.

### `Fs`

```ren
pub dep Fs =
  open: fn(p: Path, mode: Mode) -> File ! FsError        // read, write, create, truncate, exclusive, append
  read_at: fn(f: File, at: Int, buf: &Bytes) -> Int ! FsError
  write_at: fn(f: File, at: Int, b: Bytes) -> Int ! FsError
  sync: fn(f: File, data_only: Bool = false) ! FsError
  set_len: fn(f: File, n: Int) ! FsError
  copy_range: fn(from: File, at: Int, to: File, to_at: Int, n: Int) -> Int ! FsError
  lock: fn(f: File, exclusive: Bool, wait: Bool = true) -> Bool ! FsError
  close: fn(f: File)
  stat: fn(p: Path) -> Stat ! FsError                     // size, kind, modified
  list: fn(dir: Path) -> Array<Entry> ! FsError           // names and kinds
  make_dir: fn(p: Path) ! FsError
  rename: fn(from: Path, to: Path) ! FsError              // replaces `to` atomically
  remove: fn(p: Path) ! FsError
  sync_dir: fn(dir: Path) ! FsError                       // makes a rename or a create durable
```

- **Functions over it:** `read_all` (today's `read`), `read_str`,
  `write_all`, `write` (today's: create or replace), `write_atomic` (a
  temporary file, `sync`, `rename`, `sync_dir`), `exists`, `lines`,
  `line_reader`, `walk`, `copy`.
- **`copy_range` is the fast path,** `copy_file_range` or a clone,
  called explicitly by `copy`; an implementation without one reads and
  writes.
- **`lock` and `sync_dir`** are what a storage engine needs: one writer
  per directory, and a rename that survives a crash.
- **`sim.fs` models:** a write torn at sector size; unsynced writes lost
  at a crash, in any subset and order; a `sync` that lies, when asked
  to; a rename that's atomic, and one lost before its `sync_dir`; a full
  disk; read and write errors on chosen ranges; latency.

### `Net`

```ren
pub dep Net =
  listen: fn(addr: Addr) -> Listener ! NetError
  accept: fn(l: Listener) -> Conn ! NetError
  connect: fn(addr: Addr) -> Conn ! NetError
  recv: fn(c: Conn, buf: &Bytes) -> Int ! NetError        // 0: the peer closed
  recv_chunk: fn(c: Conn) -> Bytes ! NetError             // leased from the pool
  send: fn(c: Conn, b: Bytes) -> Int ! NetError
  shutdown: fn(c: Conn) ! NetError                        // done sending; still receiving
  close: fn(c: Conn)
  close_listener: fn(l: Listener)
  local: fn(l: Listener) -> Addr
  peer: fn(c: Conn) -> Addr
  set_no_delay: fn(c: Conn, on: Bool) ! NetError
  resolve: fn(host: Str) -> Array<Addr> ! NetError        // the system's resolver, for now
```

- **`Addr`** is `Tcp { host, port }` or `Unix(path)`. UDP's `bind`,
  `send_to` and `recv_from` come with `dns`, which needs them, and
  `resolve` then moves to `std.dns` over them, so the resolver is Ren's
  and replays.
- **Functions over it:** `read` and `write` (today's), `write_all`,
  `connections(l)` (the cursor `Async.each` takes), framing and buffered
  reading in L2. `accept_until` goes: `Async.race` of an `accept` with
  `Signal.wait` says the same.
- **`sim.net` models:** latency and bandwidth per link; a partition, one
  way or both; a reset; a half-open connection; a peer that reads
  slowly or never; a refused connect; a full backlog; short sends and
  receives of any length.

### `Clock`

```ren
pub dep Clock =
  now: fn() -> Time                    // the wall clock
  instant: fn() -> Instant             // monotonic
  sleep_until: fn(i: Instant)
```

- **Functions over it:** `sleep(d)`, deadlines, and every timer:
  `Async.timeout` is a `race` against `sleep_until` (runtime.md).
- **`sim.clock` models:** virtual time that moves only when every task
  waits; a wall clock that jumps, forward or back, while `instant` keeps
  going.

### `Random`

```ren
pub dep Random =
  fill: fn(buf: &Bytes)                // the system's secure generator
```

- **Functions over it:** `int(below)` (today's), `float`, `shuffle`,
  `choose`, ids. A handler over `Random` that buffers is L2's, for code
  that draws often.
- **`sim` answers it from the seed,** so a run replays, and property
  tests shrink the choices ([testing.md](testing.md)).

### `Console`

```ren
pub dep Console =
  write_out: fn(b: Bytes)
  write_err: fn(b: Bytes)
  read_in: fn(buf: &Bytes) -> Int      // 0: the end of input
  is_terminal: fn(s: Stream) -> Bool   // In, Out or Err
```

- **Functions over it:** `print` and `Console.write` (a line to
  standard output), `Console.error`, `read_line`, `lines()` over
  standard input. A terminal's raw mode and size come with a `cli`
  that needs them.
- **`sim` and tests** capture output and script input.

### `Os`

```ren
pub dep Os =
  args: fn() -> Array<Str>
  env: fn(name: Str) -> Option<Str>
  cwd: fn() -> Path
  exit: fn(code: Int) -> Never
```

- **`exit` ends the program the way a stop does:** it cancels the whole
  tree, runs every `finally` under the cleanup deadline, and then exits
  with `code`. Go's `os.Exit`, which skips deferred cleanup, is the
  mistake it avoids. A crash is `panic`, not an exit.

### `Proc`

```ren
pub dep Proc =
  spawn: fn(cmd: Str, args: Array<Str>, io: Stdio, env: Env = Inherit,
            dir: Option<Path> = None, kill: Kill = Tree) -> Child ! ProcError
  read: fn(p: Pipe, buf: &Bytes) -> Int ! ProcError       // 0: the end
  write: fn(p: Pipe, b: Bytes) -> Int ! ProcError
  close_pipe: fn(p: Pipe)
  wait: fn(c: Child) -> Exit                              // a code, or the signal that ended it
  kill: fn(c: Child, s: Sig)
```

- **`Stdio`** says, for standard input, output and error each, `Inherit`,
  `Pipe` (the child's handle carries it), `Null` or a `File`.
- **Functions over it:** `run` (today's: inherit, wait, the exit code),
  `output` (capture standard output and error), `pipeline`. A cancelled
  wait kills as `kill` says, SIGTERM then SIGKILL after the cleanup
  deadline, as today.
- **`sim.proc` models:** scripted programs, their output and exit codes,
  slow ones, and ones that ignore SIGTERM.

### `Signal`

```ren
pub dep Signal =
  wait: fn(set: Array<Sig>) -> Sig     // until one of them arrives
```

- **Functions over it:** `Signal.on(term) fn() => ...`, a graceful stop
  as a `race` of the server with `wait([term, interrupt])`.
- **`sim` draws when a signal arrives** from its tape.

### What isn't here

- **The terminal beyond `is_terminal`, file watching, memory maps,
  UDP and `sendfile` from a file to a socket** come when a program needs
  them, each an operation added to its dependency, never a probe.
- **Nothing reaches the world but these.** `dbg` is the one named
  exception: it writes to standard error from anywhere, is compiled out
  of release builds, and `ren test --ci` refuses it (decision 20).

---

## Roadmap

Stage numbers match the [README roadmap](README.md#roadmap).

| When | What |
|---|---|
| **Stage 7** | `Clock`, `Random` and `Console` as dependency types, with real implementations and test ones (done) |
| **Stage 8** | `Fs`, `Os` and `Proc` as dependency types, with real implementations and in-memory ones: `Fs` on `Unix` and `mem_fs`, `Os.args` and `test_os`, `Proc.run` and `test_proc` (done) |
| **Stage 10** | the journal entry format |
| **Stage 11a** | `Net`; fibers and `Async`; cancellation that waits (done in the interpreter: `Async`'s tasks are OCaml effects, and `Net`, `Clock` and `Proc.run` wait on `Unix.select` and timers, not a ring). Still to come from this row: the ring, batched submission, linked operations, and leased buffers returned to the pool when their count reaches zero |
| **Runtime core** | the runtime and primitives, natively, in a language still open: the core of [runtime.md](runtime.md), with io_uring and kqueue drivers |
| **Stage 13** | epoll and IOCP drivers; TLS through rustls; a monotonic `Clock.instant` |
| **Stage 15** | registered buffers for code without `Alloc` |
| **Stage 17** | the ring replaced wholesale by the simulator; replay from journal entries |
| **After 1.0** | kTLS; finer capabilities; WASI |

---

## Open questions

- Which linked operations are worth exposing beyond write-then-sync? Or should the scheduler recognize the pattern itself?
- How is a registered-buffer pool sized and configured: per process, per handler, or per `with`?
- Does `Net` cover DNS resolution directly, or does `dns` stay a `std` module over sockets? Owning the resolver is required for determinism either way.
- How much of `Os` (signals, spawning processes) can be simulated, and what does `sim` do with a spawned process?
- Is Windows a 1.0 platform, or later?

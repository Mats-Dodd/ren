# Runtime I/O

**Hand the kernel the work, not the question.**

This doc covers how Ren code reaches the operating system: the shape of an I/O call, who owns a buffer while the kernel uses it, how cancellation finishes, how calls are batched, and how all of it sits under narrow dependencies like `Fs` and `Net`. What the standard library builds on top is in [stdlib.md](stdlib.md).

> **Status:** design. The interpreter does no I/O through this model yet. Decisions marked *proposed* are recommendations, not settled; see [Open questions](#open-questions).

---

## The short version

```
 completion, not readiness       hand over the operation and the buffer; get told when it's done
 &buf means the kernel's turn    nobody else sees buf until the call returns
 cancelling waits                a cancelled read returns only once the kernel lets go
 one submission, many calls      the scheduler batches every fiber's pending calls
 a call is a value               submission, completion and journal entry have one shape
 narrow capabilities, one ring   Fs, Net, Clock, Random, Os in signatures; one queue underneath
```

---

## Three rules

**1. Completion, not readiness.**
epoll tells a program when a socket is ready, and the program then makes the call. io_uring takes the operation and the buffer, and reports when the operation is done. Ren's I/O is completion-shaped everywhere. A readiness backend (epoll, kqueue) can be wrapped to look like completion easily, while the other direction is hard, so this costs nothing on platforms without a completion API.

**2. A call is a value.**
An io_uring submission is a record of an operation and its arguments, and a completion is its result. A dependency call has the same shape, and so does an entry in the effect journal. The kernel is the outermost handler, and `sim.fs` and `sim.net` take its place by implementing the same dependencies.

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

Ten thousand idle connections each holding a 64 KB receive buffer waste 640 MB. With io_uring's provided buffers, the kernel takes a buffer from the shared pool only when data actually arrives. Reference counting returns it with no lease protocol to get wrong: when the count reaches zero, the buffer goes back to the ring. Before stage 11, leased buffers are copied into ordinary `Bytes`.

Registered buffers, pinned once so each call skips setup, fit code without `Alloc`. A hot path that uses only pooled buffers needs neither `Alloc` nor per-call kernel work.

### Cancelling waits for the kernel

Rust's async I/O lends out `&mut buf`, and dropping a future cancels it at once. With a completion API the kernel may still be writing into a buffer that has been freed, which is why tokio-uring needs a different, owned-buffer API.

Ren avoids the problem by rule (*proposed*, stage 8):

> A call cancelled while the kernel holds its buffer returns only after the kernel confirms it has let go.

```ren
let n = async.timeout(50.ms) fn() =>
  try Net.recv(conn, &buf)
```

When the timeout fires, the runtime submits a cancel request for the read and waits for its completion before `async.timeout` returns. `buf` is never touched after the call returns. Ren can keep this rule where Rust can't because cancellation happens only at dependency calls and is allowed to wait, and structured concurrency means no task outlives the block that started it.

Some operations can't be stopped once the kernel has started them; a regular file read may simply finish. The wait is then the remaining time of that operation, which is bounded.

### Batching

Fibers pause at every dependency call. The scheduler collects the calls pending across all fibers and submits them with one system call:

```ren
let srcs = async.par_map(paths) fn(p) => try Fs.read_all(p)
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
 user code sees      Fs    Net    Clock    Random    Os    Alloc    Async
                       \     |      |        |       /
 runtime handler        ring: io_uring · epoll · kqueue · IOCP · sim
                        requires Unsafe; installed once, before main
```

| Capability | Covers |
|---|---|
| `Fs` | files, directories, metadata, sync |
| `Net` | TCP, UDP and Unix sockets; DNS is a `std` module built on `Net` |
| `Clock` | `now` (wall clock), `instant` (monotonic), `sleep`, timers |
| `Random` | seeds for hashing and the cryptographic random number generator |
| `Os` | environment, arguments, signals, exit, spawning processes |

These replace the README's single `Io`. Each is an ordinary dependency type, so `mem_fs`, `clock.frozen` and `sim.net` implement them like any user handler would. Finer capabilities (`Fs.read` without `Fs.write`, a directory, an address) can split off later without changing this model.

Why not one capability? io_uring itself shows the cost. It had a run of kernel vulnerabilities, and several large operators (Google among them) turned it off, partly because one interface that can do everything is impossible to audit. A function that says `uses Io` tells a reader almost nothing. `uses Fs` tells them it never opens a socket.

### Journal entries

A journal entry has the shape of a submission and its completion (*proposed*, stage 8):

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

- **To stage 9,** the primitives are OCaml, built on Eio, so the interpreter already uses the right model.
- **From stage 10,** the primitives and the rest of the runtime (fibers, the scheduler, reference counting, the allocator, the journal) are C, emitted alongside the compiler's output.

Everything above the primitives carries over unchanged from the interpreter to native code. Only the primitives are rewritten.

### TLS and kTLS

TLS sits above `Net` as a handler. The library under it must be sans-IO, taking bytes in and giving bytes out, with randomness and time supplied by Ren, or a seed would no longer replay the same handshake. That's why `std` borrows rustls ([stdlib.md](stdlib.md#part-6-what-ren-writes-and-what-it-borrows)).

On Linux, once the handshake is done, the session keys can be handed to the kernel (kTLS). The kernel then encrypts and decrypts, and `Net.chunks` keeps its zero-copy path. Under `sim.net`, real TLS runs with a seeded random number generator and the simulated clock, so expired certificates, clock skew and failed handshakes replay exactly.

---

## Roadmap

Stage numbers match the [README roadmap](README.md#roadmap).

| When | What |
|---|---|
| **Stage 7** | `Fs`, `Net`, `Clock`, `Random`, `Os` as dependency types, with real implementations on Eio and in-memory ones |
| **Stage 8** | fibers and `Async` on the ring; batched submission; cancellation that waits; the journal entry format; linked operations |
| **Stage 10** | the runtime and primitives in C: io_uring, epoll, kqueue and IOCP backends; TLS through rustls |
| **Stage 11** | leased buffers returned to the pool when their count reaches zero |
| **Stage 12** | registered buffers for code without `Alloc` |
| **Stage 14** | the ring replaced wholesale by the simulator; replay from journal entries |
| **After 1.0** | kTLS; finer capabilities; WASI |

---

## Open questions

- Which linked operations are worth exposing beyond write-then-sync? Or should the scheduler recognize the pattern itself?
- How is a registered-buffer pool sized and configured: per process, per handler, or per `with`?
- Does `Net` cover DNS resolution directly, or does `dns` stay a `std` module over sockets? Owning the resolver is required for determinism either way.
- How much of `Os` (signals, spawning processes) can be simulated, and what does `sim` do with a spawned process?
- Is Windows a 1.0 platform, or later?

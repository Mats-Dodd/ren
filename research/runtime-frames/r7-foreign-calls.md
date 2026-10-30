# R7: foreign calls

Proposal point 4 adds two declarations inside `trust`. A `foreign fn` is
a plain C call made inline, for instance by a driver. A `blocking
foreign fn` is called from task code and becomes a world call answered
by the driver's thread pool. Neither exists yet. README.md's "FFI and
`trust`" sketches `extern "z" fn crc32(seed: u32, p: Ptr<u8>, n: usize)
-> u32` behind `Unsafe` (README.md:833-842). This file sets that sketch
against nine systems and proposes the smallest sound pair.

It builds on research/runtime/r3-effects-kernel.md (Go's optimistic
handoff, Loom's pinning, Eio's unbounded pool, Zig's signal cancel) and
r2-completion-io.md §8 (pools can't cancel; `F_FULLFSYNC`). Those
findings are cited, not redone. r6-drivers-in-language.md, next to this
file, covers what a driver needs, which overlaps here in §8.

Sources, read at these commits:

- Go `6c49ac3` (2026-10-26), `src/runtime` only
- tokio `6470b5e` (2026-10-29); Zig `738d2be` (2025-11-26)
- Swift `1006dea` (2026-10-26, sparse) and swift-evolution (SE-0495)
- Koka `198fc3b` (2026-10-14); Lean 4 `24a851d` (2026-10-27)
- OxCaml `629921bf` (2026-10-26); Eio `1fa7762` (2026-10-16)
- Inko `45af188` (2026-10-25); Pony `f032e36` (2026-10-25)

Measured here: Apple M4 Max laptop shared with other agents (load
average 3 to 7), clang (Xcode), Go 1.27.3, Swift 6.0.3, tcc 0.9.28rc.
Code is in scratchpad `r7-foreign/`.

## The short version

- **Ren emits C, so a plain foreign call is just a C call.** It costs
  what any non-inlined C call costs, 1.2 ns here, against cgo's 23 to
  25 ns. Struct-by-value and variadic calls come for free from the C
  compiler, with no marshalling and no stack switch. Of the systems
  studied, only Zig and Swift are as direct. Go, OCaml and Inko all pay
  a runtime transition on every call.
- **Every runtime with user-level concurrency marks blocking calls, or
  repairs the damage afterwards.** Go repairs (sysmon retakes the P
  after about 20 µs). Inko and OCaml mark per call (`start_blocking`,
  `caml_enter_blocking_section`). Eio and tokio mark a *closure* sent to
  a pool. Pony does neither, and just shipped a fix for scheduler
  threads parked in a blocking `read`.
- **The prior art's unit of blocking work is a closure, not one call.**
  tokio's `spawn_blocking(f)` and Eio's `run_in_systhread fn` run a
  whole function on the pool. Proposal point 4's per-call `blocking
  foreign fn` is simpler to journal, but it splits errno, thread-locals
  and multi-call sequences across pool threads. Ren needs both forms.
- **A pool hop costs about 5 µs here,** four thousand times a plain call
  (condvar out, kevent or condvar back). So `blocking` must be a
  deliberate choice, never a default.
- **Ren values cross only borrowed.** Koka passes them owned by default,
  so C must drop them. Lean marks borrowed parameters `@&`. Ren gives C
  no reference-count API at all, so every reference-counted argument is
  borrowed for the call and the compiler keeps it alive until the call
  returns, or until the reply for a `blocking` call.
- **Callbacks from C into Ren must be plain**, and from a thread Ren
  didn't make they may only post a completion. Swift refuses an `async`
  C entry point outright. Go needs a spare M for C threads.

---

## 1. Zig: `extern fn` and `callconv(.c)`

- **Direct calls.** An `extern fn` is a C call with Zig's own types. A
  `callconv(.c)` Zig function can be passed to C as a function pointer.
  `Threaded` installs a Zig signal handler this way:
  `fn doNothingSignalHandler(_: posix.SIG) callconv(.c) void {}`
  (`lib/std/Io/Threaded.zig:6255`, installed at `:138-151`).
- **Blocking is not marked.** Under `Io.Threaded` every call already runs
  on a pool thread, so a blocking C call is just a call. Under the
  evented implementations it stalls the fiber's thread, and Zig has
  nothing for it beyond "use `Threaded`" (r3 §4).
- **Cancel by signal.** `Threaded` cancels a thread blocked in a syscall
  with `tgkill(SIGIO)`, so the call returns `EINTR` (r3 §4,
  `Threaded.zig:100-112`). That only works for syscalls that tolerate
  `EINTR`, not for arbitrary C.

## 2. Rust: `extern "C"` and `tokio::task::spawn_blocking`

- **`extern "C"` is a direct call,** as in C.
- **`spawn_blocking(closure)`** moves the closure to the blocking pool:
  - `max_blocking_threads` defaults to **512** (`runtime/builder.rs:324`,
    documented at `:607`);
  - idle threads exit after **10 s** (`KEEP_ALIVE`,
    `runtime/blocking/pool.rs:231`);
  - a thread is spawned only when none is idle and the count is under
    the cap; otherwise the task waits in the queue
    (`pool.rs:462-500`);
  - a temporary OS refusal to spawn is tolerated if any blocking thread
    exists (`pool.rs:485-492`).
- **It can't be cancelled once running.** "tasks spawned using
  `spawn_blocking` cannot be aborted because they are not async ...
  calling `abort` may prevent the task from starting", and shutdown
  waits for them (`task/blocking.rs:108-116`).

## 3. Go: cgo

The flow is spelled out at the top of `runtime/cgocall.go`:

- **A cgo call is a syscall to the scheduler.** `cgocall` calls
  `entersyscall` "so as not to block other goroutines or the garbage
  collector", then `asmcgocall` switches to the g0 stack (OS-allocated,
  "safe to run gcc-compiled code on"). After the call, `exitsyscall`
  "blocks until this m can run Go code without violating the
  $GOMAXPROCS limit" (`cgocall.go:9-27`).
- **The P is handed off lazily.** The worker keeps its P during the
  call. `sysmon` retakes it after at least one tick of about 20 µs and
  hands it to another thread (r3 §3; `proc.go:6693-6788`). There's an
  eager path, `entersyscallblock`, used when "Synchronous pipe I/O may
  need a peer goroutine to make progress" and no other P is idle
  (`cgocall.go:168-174`).
- **Callbacks from C** go through `crosscall2` → `cgocallback` →
  `cgocallbackg`, which calls `exitsyscall` before running Go
  (`cgocall.go:30-84`, `:311-360`). A C thread that Go didn't create
  needs an "extra M" (`proc.go:1955-1956`; `needm`, `:2401`).
  `#cgo nocallback` makes a callback into Go panic:
  "function marked with #cgo nocallback called back into Go"
  (`cgocall.go:354-356`).
- **Pointer rules are checked at run time.** `cgoCheckPointer` rejects a
  Go pointer to memory holding Go pointers and pins the pointer for the
  call (`cgocall.go:541-620`). It's on by default (`debug.cgocheck`).

**Measured here** (`go build && ./cgobench`, 20 M calls, 3 runs):

| Call | ns per call |
|---|---|
| Go to a `//go:noinline` Go function | 1.15 to 1.17 |
| cgo to a static C function | 23.1 to 24.1 |
| cgo with `#cgo noescape` and `nocallback` | 25.5 to 25.8 |

So cgo costs about 20 times a plain call on this machine. `noescape` and
`nocallback` didn't make the call itself any cheaper. Their benefit is
elsewhere: fewer escaping arguments, and no callback setup.

## 4. Swift: C interop and `@_cdecl`

- **Calling C is direct:** imported C functions are called with no
  marshalling (from memory; the sparse clone has no Sema to cite).
- **Exposing Swift to C** uses `@_cdecl("name")`, "Similar to
  `@_silgen_name` but uses the C calling convention ... Type bridging is
  not done" (`docs/ReferenceGuides/UnderscoredAttributes.md:55-62`).
  SE-0495 formalises it as `@c` in Swift 6.3
  (`swift-evolution/proposals/0495-cdecl.md:6`). Signatures may use only
  primitives, pointers, `@convention(c)` function references, SIMD
  types, `@c` enums and imported C types. Swift structs, non-`@c` enums,
  classes and existentials are rejected (`0495-cdecl.md:113-133`).
- **An `async` function can't be a C entry point.** Checked here with
  Swift 6.0.3: `@_cdecl("f_async") public func fAsync() async -> Int32`
  fails with "@_cdecl global function cannot be asynchronous"
  (`swiftc -parse-as-library -typecheck a.swift`; the diagnostic is
  `attr_decl_async`, `include/swift/AST/DiagnosticsSema.def:2542-2543`).
  That's exactly Ren's rule: a suspending function has no frame C could
  hold, so a C callback must be plain.

## 5. Koka and Lean 4: who owns a counted value passed to C

Both use reference counting, as Ren does (decision 14).

- **Koka: owned by default, `^` for borrowed.** An `extern` names a C
  function (`c "kk_os_read_text_file_error"`, `lib/std/os/file.kk:35-38`)
  or inlines C text (`c inline "..."`, `lib/std/core/lazy.kk:21-23`).
  An owned argument must be dropped by the C side:
  `kk_posix_open` takes `kk_string_t path` and ends with
  `kk_string_drop(path,ctx)` (`kklib/src/os.c:44-56`). Borrowed
  parameters are marked `^` (`fip extern string-cmp( ^x : string, ^y :
  string )`, `lib/std/core/string.kk:54`). Every C function also
  receives `kk_context_t* ctx`, the thread's runtime context. Blocking
  isn't marked: `kk_posix_open` calls `open` inline.
- **Lean 4: typed ownership at the C boundary.** `lean.h` has
  `lean_obj_arg` (owned), `b_lean_obj_arg` (borrowed) and
  `u_lean_obj_arg` (unique) (`src/include/lean/lean.h:207-211`). The
  Lean side marks borrowed parameters with `@&`:
  `@[extern "lean_io_prim_handle_read"] opaque read (h : @& Handle)
  (bytes : USize) : IO ByteArray` (`src/Init/System/IO.lean:847`). The
  C side allocates its result with `lean_alloc_sarray` and returns it
  owned (`src/runtime/io.cpp:592-616`). Lean's blocking strategy is a
  dedicated task priority (`Task.Priority.dedicated`, `IO.lean:1553`),
  a thread per task, not a per-call mark.

**For Ren.** Both languages let C create and drop counted values,
because C gets a runtime API (`kk_string_drop`, `lean_alloc_sarray`).
Ren shouldn't offer one in 1.0. Then the rule is one line: **a counted
value is always borrowed by C, never owned, and never kept.** A C
function that produces data writes into a buffer Ren lent it (`inout
Bytes`), the same shape as a world call. The compiler must treat a
foreign argument as borrowed (Perceus may not drop it before the call
returns), which is what Lean's `@&` and Koka's `^` tell their
compilers.

## 6. OCaml 5: blocking sections and `[@@noalloc]`

- **A blocking section releases the domain lock.**
  `caml_enter_blocking_section` first runs pending signal handlers and
  GC interrupts, then calls `caml_release_domain_lock`
  (`runtime/signals.c:198-225`). `caml_leave_blocking_section`
  re-acquires it, and **saves and restores `errno` around that**
  ("Save the value of errno (PR#5982)", `signals.c:227-260`). The C
  stub brackets the blocking call itself. Inside, it may not touch the
  OCaml heap.
- **`[@@noalloc]` externals** skip the runtime transition entirely: the
  C function promises not to allocate, raise or release the lock
  (`stdlib/bool.ml:43-46`, `camlinternalLazy.ml:35`). `[@untagged]` and
  `[@unboxed]` let integers and floats cross without boxing (from
  memory; not checked in this clone).
- **Eio's `run_in_systhread fn`** sends a whole closure to an unbounded
  pool: "This pool creates a new system thread if all threads are busy,
  it does not wait" (`lib_eio/unix/eio_unix.mli:72-78`;
  `thread_pool.ml:123`). Cancellation is checked only before the job
  starts (r3 §1).

## 7. Inko and Pony

- **Inko marks the call, and a monitor thread compensates.**
  `std.io.start_blocking` and `stop_blocking` bracket a C call that
  "might block the current OS thread", and `stop_blocking` returns the
  errno (`std/src/std/io.inko:27-75`). The runtime records a blocking
  epoch per thread, and a monitor running every 100 µs replaces a
  thread blocked longer than that with a backup thread
  (`rt/src/scheduler/process.rs:43-80`, `:325-366`, `:675-705`). The
  goal "isn't to guarantee blocking operations never take more than the
  given interval. Instead, our goal is to ensure blocking operations
  don't block an OS thread indefinitely" (`:69-71`).
- **Pony marks nothing.** FFI calls are direct:
  `use @read[ISize](fd: I32, buffer: Pointer[None], bytes_to_read:
  USize)` (`packages/files/file.pony:4`). The 0.67.0 release fixed a
  hang where "A read on a socket could park a scheduler thread inside
  the read call, waiting for data that might never arrive. The runtime
  then never went idle and the program never exited", caused by a
  blocking-mode fd "opened over the C FFI"
  (`.release-notes/0.67.0.md:193-205`). That's the failure Ren's
  unmarked `foreign fn` would have, found in production.

---

## 8. The minimal sound design for Ren

### 8.1 Two declarations, plus one form for sequences

```ren
// in a trust module
foreign fn crc32(seed: u32, p: Ptr<u8>, n: usize) -> u32                  // plain: inline C call
blocking foreign fn getaddrinfo(node: CStr, ..., out: Ptr<Ptr<AddrInfo>>) -> i32   // a world call from a task
blocking fn read_config(path: Bytes) -> Result<Bytes, Errno> =            // a plain Ren fn run whole on the pool
  ...foreign calls, sharing one thread's errno and thread-locals...
```

- **`foreign fn`** is a C prototype. The emitter writes it as one and
  calls it directly. Measured here: 1.16 ns per non-inlined call
  (clang -O2). Variadic functions and calls without system headers work
  under tcc and clang (`open`, `fcntl` with and without the third
  argument, `__error()`; checked with `tcc -run va.c` in scratchpad
  `r6-drivers/`).
- **`blocking foreign fn`** is a world call when reached from a task.
  The compiler lowers the call site to `Async.submit(Blocking.Call {
  fn_id, args })`. The driver's pool runs the C function, captures
  `errno` on the same thread right after the call, and replies. Its
  caller's specialization now reaches a scheduling point, so it
  suspends: proposal point 1's colour rule handles it with no new
  machinery.
- **`blocking fn`** is the closure form, as tokio's `spawn_blocking` and
  Eio's `run_in_systhread` do. It's a plain Ren function with data
  parameters and a data result and an empty row. Its whole body runs on
  one pool thread and is one world call. It's needed for anything with
  thread-local state across calls: OpenSSL's error queue, `strerror`,
  a SQLite connection bound to a thread, `errno` read after a second
  call. Without it, two `blocking foreign fn` calls in a row may run on
  different pool threads.

### 8.2 Types that cross

| Ren | C | Rule |
|---|---|---|
| `Int`, `u8`..`u64`, `i8`..`i64`, `f32`, `f64`, `Bool` | the matching C scalar | by value |
| `Ptr<T>`, `usize` | `T*`, `size_t` | `trust` only (decision 2's "never handle an address") |
| a C-layout record declared in `trust` | a C struct | by value or by pointer. The C compiler does the ABI, since Ren emits C. |
| `Bytes`, a slice | `(const uint8_t*, size_t)` | **borrowed for the call**; read-only |
| `inout Bytes` (`&buf`) | `(uint8_t*, size_t)` | borrowed and exclusive for the call |
| `Str` to a C string | `const char*` | copied into a NUL-terminated temporary, as Koka's `kk_with_string_as_qutf8_borrow` does (`os.c:50-52`) |
| a plain Ren `fn` marked for C | a C function pointer | §8.4 |
| any other Ren value (a record, an enum, a block) | none | rejected, as SE-0495 rejects Swift structs |

Two points need care:

- **Borrowed means the compiler keeps it alive.** Perceus must not drop
  a foreign argument before the call returns. For a `blocking` call,
  that's until the reply, and the parked frame holds it.
- **Shared, immutable `Bytes` is safe to lend to a pool thread.** C
  reads it, and nobody writes it. C never touches the count, and the
  frame's reference keeps it alive. A shared buffer must never be lent
  as `inout`, and the exclusivity rule already forbids that.

### 8.3 Who owns memory

One rule for both kinds: **a call's arguments belong to whoever answers
it until the reply.** That's runtime.md's rule for world calls, applied
to C:

- for a plain `foreign fn`, the reply is the return;
- for a `blocking` call, the pool thread owns the borrowed buffers until
  the reply, and the task stays parked. Cancelling waits (r2 §1), so the
  buffers can't be freed early.

C must not keep a pointer past the return. Nothing checks it, which is
what `trust` means. A debug build can poison a lent `inout` range after
a `blocking` reply to catch a late write.

### 8.4 Callbacks from C into Ren

Decision 4 already keeps C function pointers as the one indirect call
in `trust`. Three cases:

1. **A callback on the same thread, during a plain `foreign fn`** (a
   `qsort` comparator, a zlib allocator). It runs on the task's native
   stack with C frames below it. **It must be plain:** it can't suspend,
   because there's nowhere to put its frame. Swift enforces the same
   rule (§4). The compiler checks it: a function used as a C function
   pointer must be plain in every specialization.
2. **A callback on a pool thread, during a `blocking` call** (an SQLite
   progress handler). The task is parked, so nothing races its frame.
   But the callback runs on another thread, so it may not reach a
   handler instance. **It must be plain with an empty row.** An empty
   row is already "touches no dependency", so this is the same check
   plus one: no `uses`.
3. **A callback from a thread Ren didn't create** (a C library's own
   I/O thread). There's no Ren thread context, so it can't allocate.
   Go needs a spare M for this (`proc.go:1955-1956`). Decision 11
   already gives the answer: **C callbacks post completions to a
   runtime queue.** Concretely, the callback is C, or a Ren function
   restricted to one call, `ren_reply(core, id, bytes)`,
   whose bytes answer a standing world call (`Lib.Call.Next`).
   The event is then journaled like any reply.

The block form (code plus frame pointer, decision 13) maps onto C's
usual `(fn, void* ctx)` pair. Passing a block's frame to C as `ctx` is
`trust`, and valid only for case 1 or for case 2 while the call is
outstanding.

### 8.5 Journal and replay

- **`blocking foreign fn` and `blocking fn` are world calls,** so their
  arguments and result are journaled, and replay answers them from the
  journal without running C. That holds only if the result is data.
  **A `blocking` call that returns a pointer** (`SSL*`, a `dlopen`
  handle, `malloc`) can't be replayed, because the pointer means
  nothing in the next run. Rule: a `blocking` result is data (scalars,
  `Bytes`, a `Result` of those, and `inout` buffers, whose bytes are
  journaled). A handle-returning call is a driver's job, and the driver
  maps it to a handle id, as it does for fds.
- **A plain `foreign fn` in task code isn't journaled.** SYNTHESIS §2.10
  says to mark the journal header "contains unrecorded foreign effects".
  That's too blunt. Most plain foreign calls are pure: `crc32`, zstd,
  SHA-256, `memcmp`, `libm`. Replay calls them again and gets the same
  answer. So:
  - **plain `foreign fn` is pure by assertion.** The `trust` author
    promises "a function of its arguments and the memory it's lent".
    That's the common case and costs nothing to replay;
  - **a foreign call that reads or changes the world** (`getpid`,
    `clock_gettime`, `write`) belongs in a driver, reached through a
    dependency, or is `blocking`. Then it's journaled.
  - **`ren why --unsafe` lists every `foreign fn`,** and a debug replay
    that diverges after one names it.

### 8.6 errno and thread-locals across a pool hop

- **errno is read on the calling thread, immediately.** The emitted C
  reads errno right after the call and before anything else runs.
  OCaml learned this (`signals.c:230-233`, PR#5982), and Inko returns
  errno from `stop_blocking` (`io.inko:37-75`). A foreign declaration
  says whether its result carries errno (`-> Result<i32, Errno>` on
  `-1`). errno is a macro (`__error()` on Darwin, `__errno_location()`
  on glibc), so std supplies a platform `trust` shim. For a `blocking`
  call, errno is captured on the pool thread and travels in the reply.
- **Thread-locals don't survive the hop.** Two `blocking foreign fn`
  calls may land on different pool threads. That's what `blocking fn`
  is for (§8.1).

### 8.7 Cancelling a blocking call

It can't be cancelled once it's running: tokio says so
(`task/blocking.rs:108-116`), Eio checks only before the job starts,
and Zig's signal trick works only on `EINTR`-safe syscalls (r3 §4).

- **Queued, not started:** retract it in the core and reply `Cancelled`
  (r2 §1, glommio's `Enqueued`).
- **Running:** the task waits, as every cancel does. At the 5 s cleanup
  deadline the call is **abandoned**: the task resumes with
  `Cancelled`, its borrowed buffers must stay alive (so the core moves
  the frame's lent buffers to a leak list until the reply), and the
  late reply is `RELEASE`d and journaled. r2 §8 leans the same way. The
  pool slot stays busy until C returns, and a metric counts abandoned
  calls. A pool full of stuck NFS reads is visible, not silent.

### 8.8 A plain `foreign fn` that blocks

That's Ren's pinning (r3 §5): a stalled worker, and under
`DEFER_TASKRUN` its ring's completions are stranded too (SYNTHESIS §2.9).
Pony's 0.67.0 fix is this exact bug in production (§7).

- **Release:** the host watchdog over `ren_progress` (SYNTHESIS §2.9)
  reports the worker and, if the core records it, the call site of the
  foreign call in progress. Cost: one store before and after each plain
  foreign call reached from a task, about 1 ns.
- **Debug:** time each plain foreign call reached from task code, and
  warn above 1 ms with the call site. Two clock reads (about 20 to 40 ns)
  are too much for release next to a 1 ns call, but fine in a debug
  build.
- **Don't compensate** (no Inko-style backup thread, no Go-style
  handoff). A Ren worker owns a ring and a frame stack, so another
  thread can't take its place. The fix is to mark the call `blocking`.

## 9. The pool hop's cost

Measured here (`clang -O2 pool.c && ./pool`, 200k round trips, 3 runs
each; the pool thread runs a non-inlined `work(x)`):

| Shape | Round trip |
|---|---|
| direct call | 1.16 ns |
| mutex and condvar both ways (both sides sleep) | 5.05 to 5.25 µs |
| condvar to the pool, `EVFILT_USER` kevent back (the driver-loop shape) | 4.91 to 5.11 µs |
| both sides spin on atomics (lower bound, burns two cores) | 148 to 177 ns |

So a `blocking` call costs about 5 µs on macOS when both sides sleep,
which is the normal case. Many filesystem calls (`stat` on a cached
inode, `open` of a cached path) take about 1 to 2 µs inline (from
memory), so the hop costs more than the call. That's an argument for
compio's `Decision` (r2 §6): the driver may run a fast filesystem call
inline through `answer_now` when it knows the call won't block, and
send it to the pool otherwise. It's the driver's choice and invisible
to the program. Linux futex numbers weren't measured.

---

## What this means for Ren

### Proposal point 4, foreign calls

**Confirmed: `foreign fn` as a direct C call.** Ren emits C, so it gets
the C ABI, structs by value and variadics with no marshalling. Measured:
1.16 ns against cgo's 23 to 25 ns. Zig, Swift and Rust do the same.

**Confirmed: `blocking foreign fn` as a world call answered by the
driver's pool.** It folds into point 1's colour rule (the caller
suspends) and into the journal. Inko and OCaml mark per call, tokio and
Eio per closure, and Pony's unmarked FFI produced the hang it just
fixed.

**Missing: the closure form.** The prior art's unit of blocking work is
a function (`spawn_blocking`, `run_in_systhread`), not one C call.
Without it, errno and thread-locals split across pool threads. Fix: add
`blocking fn`, a plain Ren function with an empty row and data in and
out, run whole on one pool thread as one world call.

**Missing: ownership rules.** Fix, in one line each:

- counted values are always borrowed by C, never owned or kept; the
  compiler keeps them alive to the return, or to the reply for
  `blocking` (Lean `@&`, Koka `^`);
- C produces data only into a lent `inout` buffer; there's no C API
  for Ren's heap in 1.0;
- a `blocking` result must be data, or replay can't answer it.

**Missing: callback rules.** Fix: a Ren function used as a C function
pointer must be plain (Swift rejects `async` C entry points; checked
here). On a pool thread it must also have an empty row. From a thread
Ren didn't make, it may only post a completion to a standing world call
(decision 11).

**Wrong: "a plain foreign call in task code is unrecordable."** Most
are pure. Fix: a plain `foreign fn` is pure by `trust` assertion and
replays by calling again. World-touching C goes through a driver or
`blocking`. Drop the blanket journal-header flag; let `ren why
--unsafe` list the foreign functions instead.

**Confirmed, with the deadline: blocking calls can't be cancelled
once running.** Retract while queued; abandon at the 5 s deadline,
keeping the lent buffers alive until the late reply, which is released
and journaled.

### Candidate open decisions

1. **Is a plain `foreign fn` pure by assertion?**
   - Recommendation: **yes.** World access goes through dependencies, so
     "a function of its arguments and lent memory" is the only honest
     meaning of an unjournaled call.
   - Tradeoff: a wrong assertion breaks replay silently. Debug replay
     divergence names the foreign calls on the diverging path, which
     makes it findable but not prevented.
2. **`blocking fn` (closure form) in 1.0, or only `blocking foreign
   fn`?**
   - Recommendation: **both.** flottning needs `F_FULLFSYNC` plus errno,
     and TLS (rustls is Rust, not C, so less pressing) makes the closure
     form the one users reach for.
   - Tradeoff: two forms, and the closure form's body can't be
     inspected by the journal. Only its boundary is.
3. **Headers.** Decision 13 says no system headers in a module's unit
   (they were 6.7 of tcc's 8.1 ms per unit). But `errno`, liburing's
   API and many C libraries are macros or `static inline`.
   - Recommendation: **a `trust` module may declare `foreign include
     "liburing.h"`, compiled as its own translation unit,** so only that
     unit pays for the header. std ships shims for errno and the like.
   - Tradeoff: header-dependent units are less cacheable and slower
     under tcc. Most programs have none.
4. **Should the driver run fast filesystem calls inline?**
   - Recommendation: **yes, as a driver choice through `answer_now`,**
     as compio's `Decision` does. A 5 µs hop for a 1 µs `stat` is waste.
   - Tradeoff: an inline call that turns slow (a cold NFS inode) stalls
     a worker. The watchdog sees it, and the driver can learn per mount.
5. **Pool size and abandoned calls.**
   - Recommendation: **a fixed cap (tokio: 512, `builder.rs:324`) and a
     metric for abandoned calls.** Excess calls queue as world calls.
   - Tradeoff: abandoned calls hold slots forever. If the pool fills with
     them, `blocking` calls stop being answered. Report that as a stall
     with the call sites.

### Experiments worth running

- **E-F1: the pool hop on Linux.** Repeat §9 with a futex pool and an
  eventfd or `IORING_REGISTER_SEND_MSG_RING` (6.13) reply into a
  sleeping io_uring worker. **Predicted:** 3 to 8 µs when both sides
  sleep, 150 to 300 ns when the worker is spinning.
- **E-F2: inline versus pool for `stat` and `open`.** On a warm page
  cache, 10k files. **Predicted:** inline 1 to 3 µs, pool 6 to 10 µs.
  So the driver's inline path wins by 3 to 5 times when the cache is
  warm.
- **E-F3: a stalled worker.** A plain `foreign fn` that sleeps 50 ms in
  task code under `per_core` with `DEFER_TASKRUN`. Measure p99 latency
  of other tasks' I/O on the same worker and on other workers, and
  check the watchdog names the call site. **Predicted:** same-worker
  I/O waits the full 50 ms (stranded completions), other workers are
  unaffected, and the watchdog fires within one interval.
- **E-F4: abandoned blocking calls.** A `blocking` call that hangs
  forever, cancelled. Check that the task resumes at the 5 s deadline
  with `Cancelled`, that the lent buffer stays valid under ASan until
  the thread returns, and that the late reply is released and
  journaled. **Predicted:** passes once the core keeps a leak list for
  abandoned calls' lent buffers. Without it, ASan reports a
  use-after-free.

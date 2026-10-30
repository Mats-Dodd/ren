# R3: stackless or stackful, for Ren's goals

Track R3 of the runtime-frames research. It asks whether proposal point 2
(stackless frames on a per-task LIFO frame stack) is the right choice
against the alternative, a stack per task (Go, Loom, OCaml 5 fibers). It
goes axis by axis: idle memory, switch cost, migration under work
stealing, WASM, debugging, profiling, C interop, code size and compiler
complexity. It builds on research/runtime/r5-hosted-wasm.md (JSPI, stack
switching, Asyncify, Go's wasm port) and research/runtime/SYNTHESIS.md
("Stackless frames (decision 12) are what make hosted runtimes possible",
SYNTHESIS.md:109) and doesn't redo them.

Sources, read at these commits:

- Go `6c49ac3`, `/tmp/ren-refs/go`; `/tmp/ren-refs/go-wasm` is a file
  snapshot (`wasmobj.go`, `wasm_exec.js`), not a git repo
- OpenJDK `6ded68f1`, sparse. I added four HotSpot files to its sparse
  checkout for this track: `src/hotspot/share/runtime/continuationFreezeThaw.cpp`,
  `runtime/continuation.cpp`, `oops/stackChunkOop.hpp`,
  `oops/instanceStackChunkKlass.hpp`
- OxCaml `629921bf`, `/tmp/ren-refs/oxcaml` (its runtime differs from
  upstream OCaml 5 here; see §1.3)
- Swift `1006dea`, tokio `6470b5e`, Eio `1fa7762`
- js-promise-integration `5b247b1`, stack-switching `d9fbe34`
- `/tmp/ren-refs/binaryen-asyncify/Asyncify.cpp` and
  `/tmp/ren-refs/kotlinx-wasm/*.kt` are file snapshots, not git repos

Claims from memory or the web are marked **(web)** or **(memory)**.

**Measured here** means on the Apple M4 Max laptop, shared with other
agents. The 1-minute load average was 4 to 7 during the runs, so the
numbers carry about 10 to 20% noise. Code and commands are in
`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/r3-stack/`.

---

## Summary

- **Stackless is the right call for Ren, and the evidence is stronger
  than "memory".** It wins or ties on every axis except two: debugging
  and profiling don't work out of the box. Both have cheap fixes because
  Ren frames have parent pointers, which Rust futures don't.
- **Switch cost isn't the argument.** A minimal hand-written arm64 stack
  switch costs 18.5 to 32.9 ns a round trip (measured here). The Ren
  prototype's channel round trip, ops included, is 16.2 ns. Stackful
  isn't faster even at its floor.
- **The memory argument holds per task, but for flottning it is
  second-order.** Ren is about 128 to 500 B per idle connection, against
  Go's 4 to 20 KB. But the kernel's per-socket state, about 3 to 4 KB
  (memory), is the floor either way. And lent read buffers (64 KiB each)
  would dwarf both, which is why SYNTHESIS §2.6's leases matter more
  than the choice of frame model.
- **WASM is the decisive axis.** The prototype runs unmodified on plain
  wasm32 at 1.5 to 1.6 times its native time, the usual wasm ratio
  (measured here). A stackful design needs Asyncify, JSPI or stack
  switching. Asyncify costs +55% code size, +15 to 49% on code that
  never suspends, and 31 to 33 ns a switch on top (measured here).
- **Three things the proposal misses:**
  1. A static frame-stack bound per task body. The prototype's 4 KiB
     overflow chunk would make a 600 B idle connection cost 4 KiB.
  2. A resume-site table (state to source line), so backtraces and
     profiles can name the suspension point.
  3. A rule against foreign code keeping an OS lock or thread-affine
     state across a suspension.

---

## 1. Memory per idle task

### 1.1 Go

- **The minimum stack is 2 KiB.** `stackMin = 2048`, and `fixedStack`
  rounds `stackMin + stackSystem` up to a power of two
  (`go/src/runtime/stack.go:78-89`). `stackSystem` is 0 on Linux and
  macOS, and 1 KiB on iOS arm64 (`stack.go:75`).
- **A stack grows by copying.** `copystack` allocates a stack of the new
  size and moves the frames, adjusting pointers into the stack
  (`stack.go:929`, `adjustframe` at `stack.go:701`).
- **It shrinks only in GC,** by half, and only when less than a quarter
  is in use (`shrinkstack`, `stack.go:1286-1330`). So an idle goroutine
  keeps its high-water stack until the next GC sees it at under 25%.
- **New goroutines start at the average scanned stack size**
  (`gcComputeStartingStackSize`, `stack.go:1415-1458`; on by default,
  `runtime1.go:399`). After warm-up, a server's goroutines start at what
  their siblings grew to.
- **The descriptor is 448 B** plus per-arch extended registers
  (`runtime.G{}`, `go/src/runtime/sizeof_test.go:27`).
- **Measured here** (Go 1.27.3, `gonet_bin`, 4,000 connections over
  loopback):
  - an idle raw TCP connection goroutine blocked in
    `bufio.Reader.ReadString`: **4,202 B** of `StackInuse` per connection;
  - an idle `net/http` keep-alive connection: **8,183 B** of stack plus
    **11,417 B** of heap per connection. The heap figure includes the
    4 KiB bufio reader and writer, and the client-side objects in the
    same process, so it is an upper bound.
- **The trivial parked goroutine** measured on the cloud machine was
  2,660 B by allocator and 8,876 B by RSS
  (`experiments/runtime-p2/switch/results/cloud/SUMMARY.md:127-139`).

### 1.2 Java virtual threads (Loom)

- **On yield, frames are copied to a heap `StackChunk`.** "Freeze" copies
  them to a chunk and "thaw" copies them back
  (`openjdk/src/hotspot/share/runtime/continuationFreezeThaw.cpp:93-110`).
  The amortized budget for each is "~100-150ns"
  (`continuationFreezeThaw.cpp:104`).
  - The fast path copies compiled frames verbatim. The slow path
    relativizes interior pointers in interpreted frames
    (`continuationFreezeThaw.cpp:106-109`).
  - Thaw is lazy: a return barrier thaws one more frame when the
    mounted ones return (`continuationFreezeThaw.cpp:101`, `:2256`).
  - The continuation keeps a linked list of chunks (`tail`, `parent()`;
    `jdk/internal/vm/Continuation.java:116, 330`).
- **An idle virtual thread costs roughly its live frames plus the
  `VirtualThread` and `Continuation` objects.** That is "hundreds of
  bytes to a few KB" by the JEP 444 text (web; not measured here,
  because no JDK is installed on this machine).
- **Pinning is now only native frames and critical sections.**
  `Continuation.Pinned` has `NATIVE`, `CRITICAL_SECTION` and `EXCEPTION`,
  and no monitor case (`Continuation.java:58-62`). JEP 491 removed
  `synchronized` pinning. A native frame on the stack still pins
  (`continuationFreezeThaw.cpp:933-945`: "Frame can't be frozen. Most
  likely the call_stub or upcall_stub which indicates there are further
  natives frames up the stack").

### 1.3 OCaml 5 fibers (Eio)

- **In upstream OCaml 5, a fiber's first stack is tiny and grows by
  copying.** It is `Stack_threshold * 2` = 64 words = 512 B
  (`oxcaml/runtime/fiber.c:96`, `caml/config.h:187-188`).
- **OxCaml differs:** with `STACK_GUARD_PAGES` (`caml/config.h:198-201`)
  a fiber gets a thread-sized mmap'd stack with a guard page
  (`fiber.c:185-215`, `startup_aux.c:87-88`). That is 8 MiB of address
  space, of which only touched pages are resident.
- **Measured here** (OCaml 5.4.1 upstream, `fib.ml`): 100k fibers each
  parked on an effect cost **757 B of RSS per fiber** (78.6 MB at
  n = 100k against 2.9 MB at n = 1). Of that, 101 B is on the OCaml heap
  (the continuation and a list cell).

### 1.4 Rust and tokio

- **A future is exactly its state machine.** It has no header. Children
  awaited in sequence overlap in the same bytes, and a child future is
  stored inline in its parent's.
- **Measured here** (`fsize.rs`, rustc -O):

| future | bytes |
|---|---|
| leaf: one await, one u64 | 24 |
| mid: awaits leaf twice | 48 |
| top: awaits mid twice | 64 |
| holds a `[u8; 4096]` across an await | 4,097 |
| the same with no buffer (a lease shape) | 1 |
| boxed recursion (`Box::pin(rec(d-1))`) | 32, plus a heap box per level |

- **A tokio task adds a header** (state, vtable, scheduler links,
  waker). A trivial parked task measured 266.5 B by allocator and 394 B
  by RSS on the cloud machine (`SUMMARY.md:133`).
- **Real connection futures are large.** Hyper's server connection
  future is commonly several KB (memory, unverified). The size of a
  future is a well-known Rust pain point, and the cause is the 4,097-B
  row: buffers held across awaits.

### 1.5 Swift tasks

- **A task is one allocation,** header plus initial context, plus a
  512-B first slab for the task allocator (`initialSlabSize = 512`,
  `swift/stdlib/public/Concurrency/Task.cpp:1700`). Later slabs are
  sized to fit a 1,024-B malloc quantum (`TaskPrivate.h:1077-1083`).
- **An async frame's header is two words:** `Parent` and `ResumeParent`
  (`include/swift/ABI/Task.h:1072-1094`). Ren's frame header is three
  fields in 24 B, padded to 32.
- **Measured here** (Swift 6.0.3, `park.swift`): 100k tasks in a task
  group, each parked in `withCheckedContinuation`, cost **1,483 B of
  footprint per task**. That includes the task-group child record and
  the continuation box.

### 1.6 Ren's prototype

- **A parked task is 128 B:** a 96-B task header and one 32-B frame,
  in one allocation (`experiments/runtime-p2/switch/c/ren_single.c:71-99,
  147-163`; `SUMMARY.md:131`).
- **On wasm32 it is 80 B** (measured here: `bytes_per_task=80.0`).
- **Each extra frame costs 32 B of header plus its live locals.** The
  header is `resume`, `parent`, `state` and `size`, padded to 16
  (`ren_single.c:71-76, 124-135`).

### 1.7 flottning at 100k idle connections

Assume a realistic idle chain of serve → read request → recv, three
frames.

| cost per idle connection | Ren (stackless) | Go | Loom | tokio | Swift | OCaml 5 |
|---|---|---|---|---|---|---|
| task + frames | 96 + 3 × ~64 ≈ **300–500 B** (estimate) | **4.2 KB** raw, **8.2 KB** net/http stack (measured) | ~1 KB+ (web) | 266 B + future, often KBs (memory) | **1.5 KB** trivial (measured) | **0.76 KB** trivial (measured) |
| × 100k | 30–50 MB | 420–820 MB of stack | ~100 MB+ | 30 MB to 300 MB+ | 150 MB+ | 76 MB+ |
| read buffer, lent per connection, 64 KiB | 6.4 GB | same | same | same | same | same |
| read buffer, leased from a ring (R2 §3) | ≤ 512 MiB shared | n/a (Go has no provided buffers) | n/a | | | |
| kernel socket state, idle | ~3–4 KB → 300–400 MB (memory: `tcp_sock` plus file, inode and dentry; skbs only when data is queued) | same | same | same | same | same |
| io_uring multishot recv in flight | a few hundred B (R2 §3, memory) | n/a | n/a | | | |

**What dominates.**

- A lent buffer dominates everything, 6.4 GB. So the lease shape
  (SYNTHESIS §2.6) is the first-order decision.
- With leases, the kernel's ~300 to 400 MB dominates.
- Ren's tasks then add about 10%. Go's stacks add 100 to 200% on top of
  the kernel's floor, and net/http's per-connection bufio buffers add
  more.
- So stackless buys flottning roughly a 2 to 3 times smaller total
  footprint against Go, not 20 times.

**A stackless frame can hold a buffer too.** Rust's 4,097-B row is the
warning: a `var buf = Array(4096)` that is live across a `recv` makes
the frame 4 KB, just as Go's bufio does. Stackless saves only the
*unused* stack. Holding no buffer across an idle wait is a property of
the API (leases), and Ren should make it the default shape for
`Net.chunks`.

**The prototype's overflow chunk is a trap.** `frame_grow` allocates at
least `CHUNK` = 4,096 B (`ren_single.c:101, 113-123`). A task whose
inline segment is 128 B and whose idle chain is 300 B gets a 4 KiB
chunk, so the idle connection costs 4.2 KB, the same as Go.

- **Fix:** in a closed world the compiler knows each task body's
  suspending call graph. For a body with no recursion across a
  suspension, the deepest frame chain is a static sum, and the task's
  inline segment should be exactly that size.
  - This is Swift's `async let` preallocation idea
    (`Task.cpp:1706-1725`), done for the whole chain.
  - Chunks are then only for recursion. Size them geometrically from
    the frame that overflowed, not at a fixed 4 KiB.

---

## 2. Switch cost

| switch | ns | source |
|---|---|---|
| Ren prototype, one-slot channel round trip (two switches, ops included) | **16.2** | measured here, `ren_native --bench pingpong` (clang -O2 of `ren_single.c`) |
| hand-written stackless floor (`raw_c`) | 10.0 | measured here, `build/raw_c --bench pingpong` |
| Ren prototype, nested child frames | 33.0 | measured here, `pingpong_nested` |
| **minimal stackful switch**, arm64 asm, 20 callee-saved registers, `ret` | **32.9** round trip | measured here, `ctxsw.c` |
| the same, returning with `br x30` | 18.5 round trip | measured here, `ctxsw_br.c` |
| Go, GOMAXPROCS=1, channel round trip | 388 (cloud) | `SUMMARY.md:150` |
| tokio round trip | 401 (cloud) | brief |
| Loom freeze + thaw budget | ~200–300 | `continuationFreezeThaw.cpp:104` |

**A raw stack switch is no faster than Ren's whole channel round trip.**

- **The `ret` version pays a return-address misprediction.** Its `ret`
  goes somewhere the return stack predictor didn't push. That is why
  the `br x30` variant, an indirect branch with no return-stack
  involvement, is 1.8 times faster.
- **Stackless resumes in one indirect call to `f->resume`** and returns
  normally, so the return stack stays balanced.
- **Stackful designs pay save and restore of every callee-saved
  register** at every switch. Stackless pays only for the live locals,
  which are already in memory.

**Spawning is where stackful loses badly.**

| spawn cost | ns |
|---|---|
| guard-paged 64 KiB stack: `mmap`, `mprotect`, touch, `munmap` | **2,750–2,770** a task (measured here, `ctxsw_br`) |
| a 2 KiB malloc'd stack: malloc, touch, free | 18.9 (measured here) |
| Ren spawn + park | 23–24 (cloud, `SUMMARY.md:179`) |

- **Go avoids guard pages** by checking the stack bound in every
  function prologue and calling `morestack` (`stack.go:102`,
  `asm_arm64.s:421-429`).
- **That only works if stacks can move,** which needs precise stack maps
  for every frame, and forbids C from holding Go stack pointers (§3).

---

## 3. Migration under work stealing

**Stackful stacks can migrate, but moving or copying them is what hurts.**

- **Go's stacks migrate between Ms freely,** but they move in memory
  when they grow or shrink.
  - Copying needs precise pointer maps. `isShrinkStackSafe` refuses
    during syscalls ("often we don't have precise pointer maps for the
    innermost frames") and at async safe points (`stack.go:1245-1258`).
  - cgo has to switch to the g0 system stack for every C call
    (`go/src/runtime/cgocall.go:15-24`).
  - Go pointers passed to C are checked at runtime (`cgoCheckPointer`,
    `cgocall.go:536-549`).
- **Loom migrates by copying frames out and back in** (§1.2). Any
  native frame pins the carrier, because the VM can't copy a C frame it
  doesn't understand (`continuationFreezeThaw.cpp:933-945`).

**Ren's frames never move.**

- Frames are bump-allocated in the task's inline segment or in chunks.
  A chunk is freed only when it empties (`frame_pop`,
  `ren_single.c:136-145`), and nothing is ever copied.
- So a frame's address is stable for its whole life, and a pointer into
  a frame can be held by anyone, the kernel included, across a
  suspension. This is stronger than "position-independent": nothing has
  to be.

**Is any native-stack state live across a suspension? No, by
construction.**

- A suspending function returns `SUSPEND` up the native stack to
  `step()` (`ren_single.c:185-197`, the `CALL` macro at `:323-330`).
  Plain code is called from a resume function and returns before it
  does.
- So when a task is parked, nothing of it is on any native stack, and
  `work_stealing` can pick it up on any worker.
- This is proposal point 1's "plain code never spans a suspension",
  and it is confirmed by the lowering itself, not by a rule someone
  must remember.

**What still breaks across a move.** These are the same hazards Loom
pins for, except that in Ren they are about state held across a
suspension, not frames:

1. **Thread-locals read across a suspension.**
   - `errno` read right after a `foreign fn` is fine: plain code, the
     same thread.
   - A C library's thread-local context, an OpenGL context, a SQLite
     connection opened in single-thread mode, or macOS main-thread APIs
     must not be used before and after a suspension on different
     workers.
   - `Async.pinned()` (runtime.md:30) is the answer for whole programs.
     For a single handler, a thread-affine resource should be a
     service instance whose operations never suspend, or one homed on a
     worker.
2. **OS locks held across a suspension.** In `trust`, a `foreign fn`
   could take a pthread mutex and return. If the Ren code then
   suspends and resumes on another worker, its unlock is undefined
   behaviour.
   - Ren's own instance locks are runtime-owned, not OS mutexes, so
     they're fine (decision 10).
   - **Missing:** a documented `trust` obligation ("a foreign call
     returns with no OS lock held and no thread-affine state pending").
     Debug builds could check it cheaply by recording the worker id at
     each foreign call with a `requires_same_thread` attribute.
3. **The per-thread heap.** Rule H in compiler.md's runtime model sends
   frees back to the owning heap through a delayed-free list. The
   prototype keeps `t->heap` per task and sets `cur_heap` at each step
   (`ren_single.c:202-205`). So migration is already accounted for.

**`per_core` vs `work_stealing`.** Under `per_core` a task never moves,
so none of the above can bite. Under `work_stealing`, items 1 and 2
are the whole list. Neither depends on the frame model: a stackful
design has the same hazards plus moving stacks.

---

## 4. WASM

R5 covers the landscape: JSPI baseline in browsers and Node 24.22
(r5-hosted-wasm.md:51-90); stack switching at phase 3, behind flags
(r5:92-105); Asyncify (r5:106-117); Go's resume-point tax (r5:118-125).
This section adds source detail and numbers.

### 4.1 Asyncify uses the analysis of proposal point 1

- **The algorithm.** Asyncify's `ModuleAnalyzer` marks imports that
  "can change the state" (`binaryen-asyncify/Asyncify.cpp:600-625`). It
  then propagates that property backwards through the call graph
  (`propagateBack`, `Asyncify.cpp:746-751`), and only functions marked
  that way are instrumented.
- **That is "a function suspends only if it can reach a scheduling
  point",** done on the wasm call graph instead of on Ren's specialized
  one.
- **The difference is indirect calls.** Asyncify must assume any
  `call_indirect` can unwind (`Asyncify.cpp:654-661`: "TODO optimize the
  other case, at least by type") unless the user passes
  `asyncify-ignore-indirect` (`:236-241`) and lists exceptions by hand
  (`:274-323`).
- **Ren's closed world removes that imprecision in release.** In debug
  builds (decision 13), evidence and dictionaries are indirect, so Ren
  is exactly where Asyncify is: a conservative answer by row (see §7).

### 4.2 Measured here: stackless on plain wasm

- **Build.** The prototype `ren_single.c`, unmodified, compiled with
  `zig cc -target wasm32-wasi -O2` (zig 0.17.0) and `wasm-opt -O2`
  (binaryen 123), run in Node 24.22.1 under `node:wasi`. Every
  `--check` passed.

| bench | native (clang -O2) | wasm32 | ratio |
|---|---|---|---|
| pingpong round trip | 16.2 ns | 24.8 ns | 1.53× |
| pingpong_nested | 33.0 | 50.1 | 1.52× |
| park wake, a task | 7.4 | 11.7 | 1.58× |
| bytes per parked task | 128 | 80 | (32-bit pointers) |

That is wasm's usual tax over native, with no switching tax: **no
instrumentation, no JSPI, no stack switching.**

### 4.3 Measured here: Asyncify's tax on the same program

Asyncify run over the same module. Nothing ever unwinds, so this is
the pure tax of having it.

| | size | pingpong | nested | park |
|---|---|---|---|---|
| plain (`wasm-opt -O2`) | 67,598 B | 24.8 | 50.1 | 11.7 |
| `--asyncify` (default: indirect calls may unwind) | 104,910 B (+55%) | 37.0 (+49%) | 57.5 (+15%) | 15.1 (+29%) |
| `--asyncify` with `asyncify-ignore-indirect` | 78,326 B (+16%) | 24.1 | 48.4 | 11.8 |

- **Default mode instruments every resume function,** because `step()`
  calls `f->resume` indirectly.
- **The +55% matches Zakai's "around 50% larger on average"** (web,
  [Zakai 2019](https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html),
  which also reports +22% on fannkuch from just enabling it, and an
  outlier about 5× slowdown on SQLite).

### 4.4 Measured here: stackful coroutines built on Asyncify

`acoro.c` and `acoro2.c` model what a stackful Ren on wasm would do.
Two coroutines ping-pong, and each yields from a recursion of depth D,
so a switch unwinds and rewinds D + 2 frames. Built with
`asyncify-ignore-indirect`, its most favourable mode.

| D | plain recursion, no yield (ns an iteration) | instrumented, no yield | instrumented, yield each iteration |
|---|---|---|---|
| 0 | 2.3 | 5.3 (+130%) | 36.0 |
| 16 | 10.0 | 13.9 (+39%) | 44.2 |
| 64 | 35.8 | 48.1 (+34%) | 81.3 |

- **A switch costs about 31 to 33 ns** over instrumented code, which is
  2.5 to 3 times stackless Ren's whole round trip on wasm (24.8 ns for
  two switches plus channel ops).
- **Every instrumented function also runs 34 to 130% slower** even when
  it never yields.

### 4.5 The other stackful routes

- **Go's wasm port** gives every function resume points and a
  `br_table` entry loop (`go-wasm/wasmobj.go:280-337`, `:397-445`). A
  goroutine switch unwinds the wasm stack by returning 1 through every
  frame (`wasmobj.go`, the `ARETUNWIND` case, about lines 500-560).
  There is no async preemption at all (`go/src/runtime/preempt_wasm.s`).
  It is Asyncify's design done in the linker, and it pays on every
  function in the program.
- **Kotlin/Wasm is the stackless precedent.** Coroutines are compiler
  state machines (memory). The wasm dispatcher only enqueues runnables
  and drains them on `setTimeout` or `nextTick`
  (`kotlinx-wasm/web-JSDispatcher.kt:29-41`,
  `CoroutineContext.kt:5-21`). It uses no JSPI and no instrumentation,
  which is Ren's plan.
- **JSPI** suspends the whole wasm stack between a `promising` export
  and a `Suspending` import
  (`js-promise-integration/proposals/js-promise-integration/Overview.md:5,
  21-23`). It is one stack per export call. A stackful Ren would need
  one JSPI-suspended stack per task, which is one in-flight JS promise
  chain per task. R5's recommendation stands: JSPI only for `blocking`
  foreign calls (r5:579-583).
- **Stack switching** (`cont.new`, `resume`, `suspend`;
  `stack-switching/proposals/stack-switching/Explainer.md:180-240`)
  would make stackful-on-wasm cheap. But it isn't shipped (r5:96-105),
  and its continuations are GC references, which a non-GC wasm module
  can't keep in linear memory without a table.

**Quantified.** On wasm, stackless gives:

- 0% code-size and 0% speed tax on plain code, against Asyncify's +16
  to 55% size and +15 to 130% speed on instrumented code;
- a switch about 3 times cheaper (about 12 ns against 36 to 81 ns);
- independence from any proposal's shipping date.

---

## 5. Debugging and backtraces

### 5.1 How others do it

- **Go: free.** Goroutine stacks are real stacks. `traceback`
  (`go/src/runtime/traceback.go:881`) and `tracebackothers` (`:1391`,
  every goroutine on a crash) walk them. A goroutine dump is a walk of
  each g's stack.
- **Swift: the frame record marks itself as async, and the async chain
  is followed from there.**
  - The runtime exports `swift_async_extendedFramePointerFlags = 0x1000000000000000`
    on 64-bit Apple platforms (`swift/stdlib/public/Concurrency/Task.cpp:73-80`).
    Bit 60 of a saved frame pointer says "the slot below this frame
    record holds an `AsyncContext*`".
  - From that context, an unwinder follows `Parent`
    (`include/swift/ABI/Task.h:1077-1094`) and reports each hop as an
    `asyncResumePoint` frame (`docs/Backtracing.rst:463-471`), encoded
    in the compact backtrace format as the `async` instruction
    (`docs/CompactBacktraceFormat.md:55, 100-112`).
  - LLDB's async unwinder does the same (memory; it's in llvm/lldb, not
    in this clone).
  - Swift splits each async function into one funclet per suspension
    point, so a resume address alone identifies the source location.
- **Rust and tokio: there are no parent pointers, so a dump re-polls.**
  - `Handle::dump` notifies every idle task (`notify_for_tracing`,
    `tokio/src/runtime/task/trace/mod.rs:437-450`) and polls it in a
    tracing mode.
  - Each leaf future (sleep, socket) then captures a native backtrace,
    bounded by the `Root` future's address, and returns `Pending`
    instead of working (`trace/mod.rs:28-38, 160-182, 299-318`). Its
    waker is deferred so the task polls again later.
  - So a task's logical stack is recovered by running it. That is
    expensive and invasive ("can cause a wake-and-capture loop",
    `:181-182`).
  - tokio-console and `async-backtrace` instead add tracing spans or
    instrumentation by hand (memory).

### 5.2 For Ren

**Ren has what Swift built and Rust lacks:** a `parent` pointer in every
frame, and `t->top` updated on every `CALL` (`ren_single.c:326`). So:

- **A task's logical stack is `t->top`, then `->parent`, up to the
  root.** It is a plain pointer walk: no re-poll and no unwinder.
- **At a panic,** the native stack holds the plain callees above the
  innermost resume function. The full backtrace is the native frames
  from the panic down to the first resume function, then the frame
  chain from `t->top`. A panic ends the program with no unwinding, so
  the panic handler prints from where it stands.
- **The missing piece is "which suspension point".** One resume
  function is a `switch` on `state`, so its address names the function
  but not the line.
  - **Fix:** the compiler emits a resume-site table, one entry per
    suspension point: `{resume_fn, state, file, line, fn_name}`. That
    is a few hundred bytes for a big program.
  - For a frame that is running (on the native stack), its line comes
    from DWARF and `#line`. For a parked frame, it comes from
    `(resume, state)`.

**Proposed panic output** (one line per frame, suspending frames
marked):

```
panic: index 3 out of range for an array of length 3
  at parse_header     http.ren:88        (plain)
  at read_request     http.ren:41        (plain)
  at handle           server.ren:30      waiting: Net.recv, state 2
  at serve            server.ren:12      waiting: Async.each, state 1
task 4211: Async.each(Net.connections(l)) item 4211, started at server.ren:12
```

- The last line is the task path, the same key as the journal's task
  column (foundations.md "What it reverses", "A task path column").
- A task dump (a signal, or `ren dump`) prints the same thing for every
  parked task. Walking the scope tree gives the tree, as concurrency.md
  draws it.

**lldb with tcc, measured here.** `dw.c` is a hand-lowered pair of frame
structs, with `#line` directives naming `server.ren`, compiled with
`~/.local/bin/tcc -g`.

- tcc emits `DW_TAG_structure_type` and `DW_TAG_member` for the frame
  structs, with names and types (`dwarfdump --debug-info dw_tcc`).
- lldb stops at `server.ren:13` and `bt` shows Ren lines.
- `frame variable *f` prints the header and locals.
- `p *(serve_frame *)f->f.parent` prints the parent frame.
- `f->f.parent->resume` symbolicates as `serve_resume at server.ren:16`.

So tcc's DWARF is good enough. Two gaps:

1. **The dynamic type of a parent frame is the cast the user must
   write.** `parent` is a `frame *`. The fix is a 50-line lldb Python
   command, `ren bt`. It maps a resume function to its frame type by a
   naming convention (`<fn>_resume` to `<fn>_frame`), walks the chain,
   and prints locals and resume sites. The resume pointer works like a
   vtable.
2. **Anonymous structs print as "(unnamed struct)".** The emitter
   should name frame struct tags (`struct serve_frame`).

---

## 6. Profiling

- **Go: pprof sees whole goroutine stacks,** because `sigprof` walks
  the real stack of the interrupted goroutine (`proc.go:5805`), and the
  goroutine profile walks every g (`mprof.go:1243`).
- **Swift:** Instruments and the backtracer follow the extended frame
  pointer into the async chain (§5.1). That works only with Apple's
  tools, or tools that know the bit-60 convention (memory).
- **Rust:** perf and samply see only the poll stack: the executor, then
  `poll`, then the innermost future's code. Logical parents that are
  parked aren't there, and parents that are running appear as nested
  `poll` frames. tokio-console is not a sampler; it collects tracing
  spans (memory).

**For Ren**, a sample's native stack is: worker loop, `step()`, the
resume functions on the fast path, then plain callees. Everything above
`t->top` that is parked is in the frame chain, not on the native stack.

**A Ren-aware sampler** needs four things:

1. **The current task per worker at a known symbol** (`ren_worker[i].current`).
   The prototype has `current` (`ren_single.c:104, 202`).
2. **Publication order:** write a frame's header before linking it, and
   set `t->top` after the push. Use a compiler signal fence, not a
   hardware fence, since the handler runs on the interrupted thread
   itself.
3. **The stitch rule:** the native frames from the PC down to the
   innermost resume function, then `t->top->parent...`. Frames are
   never freed by another thread while their task runs, so the walk is
   signal-safe.
4. **The resume-site table** from §5.2, to name each parked frame's line.

So the runtime should own an in-process sampler (`ren run --profile`,
SIGPROF or a timer thread), writing pprof or folded stacks, as Go does.

- Out-of-process profilers (perf, samply, Instruments) will see only
  the native part unless Ren adopts Swift's bit-60 convention. That
  helps only on Apple, and is worth considering only once Ren has its
  own backend.
- Frame pointers must stay on: macOS arm64 keeps them, and tcc uses
  them. Release clang builds on Linux need `-fno-omit-frame-pointer`,
  which costs about 1% (memory).

---

## 7. Other costs, both ways

### 7.1 Costs of stackless

- **Locals live across a suspension live in memory.** Inside one resume
  segment, clang keeps them in registers. At each suspension point they
  are stored to the frame. That is a store per live variable, against
  stackful's save of every callee-saved register. It is cheaper unless
  a function has many live locals and suspends in a tight loop.
- **Recursion across a suspension pushes a frame per level.** It's
  cheap: pingpong_nested is 33 ns against 16 ns, and a frame push is a
  bump. Decision 13 already gives it the same depth limit as a
  recursive call.
- **You can't suspend through plain C.** A C library calling back into
  Ren (a SQLite VFS, a parser with callbacks) can only call plain Ren.
  - This is Loom's `NATIVE` pin (§1.2) made static. Loom pins at run
    time and silently loses a carrier. Ren can reject it at compile
    time: a block or function passed to a `foreign fn` must be plain,
    and the error names the dependency that made it suspend.
  - **Missing:** this rule isn't written down with the `foreign fn`
    design (proposal point 4).
- **Code size and compiler complexity.**
  - Each suspending function becomes a frame struct, a resume function
    with a `switch`, and the save and restore code. Plain code is
    untouched.
  - A function that is plain in one specialization and suspending in
    another gets two bodies in release, which is specialization's
    normal cost.
  - **Debug builds can't decide colour per specialization,** because
    they don't specialize (decision 13). They must decide it by the
    inferred `uses` row (decision 12), so more functions are suspending
    in debug than in release.
  - That is safe because cancellation lands only at real scheduling
    points: a frozen `Clock` returns `DONE` at once even when its
    caller has a frame. But frame shapes and backtraces differ between
    the two builds. It should be stated, so nobody expects a debug
    backtrace to match a release one frame for frame.
- **Debug and profiling need tooling** (§5, §6): one table and two
  small tools.

### 7.2 Costs of stackful

- **Overflow detection.** Either a guard page per task (2.75 µs to
  create and free one, measured here, and a VMA each, which Linux caps
  at `vm.max_map_count`, 65,530 by default, memory) or a prologue check
  in every function plus movable stacks (Go).
  - Ren's plain code already does the prologue check on one big worker
    stack ("every function compares its frame with a limit 1 MiB above
    the end, as Go's prologues do", compiler.md:1567-1571). Stackless
    keeps that at one stack per worker, not per task.
- **C calls need a big stack.** Go switches to g0 for each cgo call
  (`cgocall.go:15-24`). With stackless, plain code and C run on the
  worker's own large native stack, so there's no switch.
- **Signals** need an alternate stack per thread either way. Stackful
  adds the risk of a signal arriving on a small task stack. Go reserves
  `stackSystem` for that on some OSes (`stack.go:71-75`).
- **Pointers into stacks.** Moving stacks forbid foreign code from
  keeping them. Ren's frames never move (§3).

---

## 8. Verdict

| axis | stackless (Ren's proposal) | stackful (Go, Loom, OCaml 5 style) | winner |
|---|---|---|---|
| idle memory per task | 128 B trivial; ~300–500 B realistic, *if* the inline segment is sized statically | Go 2.7–8.9 KB trivial, 4.2–8.2 KB real stack; OCaml 0.76 KB; Swift 1.5 KB; Loom ~1 KB+ (web) | stackless, 10–30× per task; ~2–3× in flottning's total, because kernel state is the floor |
| switch | 16.2 ns channel round trip | 18.5–32.9 ns raw register switch alone; Go 388 ns | stackless, or a tie at the floor |
| spawn | 23 ns spawn + park | 2.75 µs with a guard page; Go-style growable needs prologue checks and moving stacks | stackless |
| migration | trivial: nothing on the native stack, frames never move | Go copies and needs stack maps; Loom copies and pins on native frames | stackless |
| WASM | runs unmodified at ~1.5× native; 0% tax | Asyncify +55% size, +15–130% speed, ~32 ns a switch; JSPI one stack per call; stack switching unshipped | **stackless, decisively** |
| debugging | needs a resume-site table and a `ren bt` lldb script; tcc DWARF suffices | free | stackful; stackless is close with ~1 table + 1 script |
| profiling | needs an in-process sampler that stitches the frame chain | free (pprof) | stackful; fixable for Ren's own profiler, not for perf or Instruments |
| C interop | C can't call back into suspending Ren (a compile error); no stack switch per C call | Loom pins at run time; Go switches to g0 per call | stackless: a static rule beats a runtime pin |
| code size | resume functions only for suspending code | none natively; huge on wasm | stackless on wasm, stackful native |
| compiler complexity | the frame lowering, colour analysis, two colourings (debug by row, release by specialization) | a runtime with stack growth and copying (Go) or freeze and thaw (Loom), and none in the compiler | stackful is simpler in the compiler, much harder in the runtime |

---

## What this means for Ren

### Point 1: plain or suspending, per specialization

- **Confirmed: plain code never spans a suspension,** so tasks migrate
  with nothing on the native stack. Evidence: the lowering itself
  (`ren_single.c:185-197, 323-330`).
- **Confirmed: the analysis is Asyncify's** (`Asyncify.cpp:600-661,
  746-751`), and Ren's closed world fixes its one weakness, indirect
  calls.
- **Missing: debug builds.** Debug doesn't specialize, so colour there
  is by `uses` row, and more functions are suspending than in release.
  - **Fix:** say so in decision 12 and 13. Make the semantics
    (cancellation points) identical in both builds by construction: a
    non-suspending handler returns `DONE` at once.
  - Backtraces may differ in which frames are frames.

### Point 2: stackless frames on a LIFO frame stack

- **Confirmed** on every axis but debugging and profiling (§8).
- **Missing: a static frame-stack bound.**
  - **Fix:** the compiler computes each task body's maximum frame chain
    when it has no recursion across a suspension, and allocates the
    task inline at that size.
  - Overflow chunks are only for recursion, sized geometrically from
    the request, not 4 KiB (`ren_single.c:101, 113-123`).
  - Without this, an idle flottning connection costs about 4.2 KB, the
    same as a goroutine.
- **Missing: a resume-site table** `{resume, state, file, line, fn}`,
  emitted by the compiler. It feeds the panic printer, task dumps and
  the sampler.
- **Refine the header.** Swift uses two words (`Task.h:1079-1090`).
  - `size` is known statically per resume function, so it can live in a
    per-function descriptor.
  - Header: `resume` (8) + `parent` (8) + `state` (4) = 20, padded to
    24 with 8-byte alignment, or to 32 with today's 16 (`R16`).
  - Aligning frames to 8 unless a frame needs 16 saves 8 to 16 B a
    frame. That is worth it only after the static bound above; it's a
    small win.
- **Refine: name frame structs** in emitted C (`struct serve_frame`),
  so lldb prints types, not "(unnamed struct)".

### Point 3: drivers are Ren

- **Untouched by this track,** except one consequence: drivers compile
  to plain code, so they run on the worker's native stack with C, and
  pay no switch for foreign calls.

### Point 4: foreign calls in `trust`

- **Missing: a callback rule.** Code handed to C (a callback, a
  function pointer) must be plain. A suspending one is a compile error
  naming the dependency. This is Loom's `NATIVE` pin
  (`Continuation.java:58-62`, `continuationFreezeThaw.cpp:933-945`)
  made static.
- **Missing: a migration obligation in `trust`.** A `foreign fn`
  returns with no OS lock held and no thread-affine state the next
  segment relies on. Thread-affine libraries go behind a homed
  service, or `Async.pinned()`.
  - Optionally, debug builds check a `requires_same_thread` attribute
    by recording the worker id.

### Candidate open decisions

1. **The task inline segment is sized by a static bound,** and chunks
   only serve recursion.
   - *Recommend yes.*
   - Tradeoff: one more whole-program fact in release. Debug has no
     whole program, so it needs a per-module bound or a default inline
     size; recommend 256 B and geometric chunks.
2. **The backtrace format and the resume-site table** as part of the
   ABI between the compiler and the runtime.
   - *Recommend yes.* It's cheap, and it is what makes stackless
     debuggable.
   - Tradeoff: one table per build, and the runtime must read it.
3. **An in-process sampler in the runtime** (`ren run --profile`),
   writing pprof.
   - *Recommend yes, after 11b.*
   - Tradeoff: Ren owns a profiler, and perf or Instruments users see
     native stacks only. Swift's bit-60 convention waits for Ren's own
     backend.
4. **Frame alignment of 8, with 16 only where a frame needs it.**
   - *Recommend deciding it with the C emitter.*
   - Tradeoff: 8 to 16 B a frame against an `alignof` per frame type.

### Experiments worth running

1. **Static bound on the prototype.**
   - Give `ren_single.c` a 3-frame idle chain (serve → read → recv)
     with 32 B of locals each. Measure bytes per parked task with
     today's 128-B inline segment and 4 KiB chunks, against an inline
     segment sized to the chain.
   - *Predict:* about 4,200 B, against about 290 B (96 + 3 × 64, rounded
     to 16).
2. **flottning-shaped idle memory, Ren against Go,** at 100k
   connections on Linux. Report task, kernel (`/proc/net/sockstat`,
   `slabtop`) and buffer memory separately, as E4 in SYNTHESIS asks.
   - *Predict:* Ren under 50 MB of tasks; Go 400 to 800 MB of stacks;
     kernel 300 to 400 MB in both.
   - If the kernel share is under 1.5 KB a socket, the stackless win in
     flottning's total grows to 4 to 6 times.
3. **`ren bt` in lldb** on a tcc build of the prototype: a Python
   script walking `t->top` and the resume-site table.
   - *Predict:* about 50 lines, and it works on tcc's DWARF as `dw.c`
     shows.
4. **A SIGPROF sampler on the prototype** at 1 kHz, stitching the
   native stack and the frame chain.
   - *Predict:* about 1 µs a sample, overhead under 0.2%.
   - Check that it never reads a half-pushed frame, using ASan and a
     stress run with signal fences removed (which should fail).
5. **wasm32 on more benches.** Run `spawn_batch` and `fanout` from
   `ren_single.c` under Node, and in a browser on a Web Worker.
   - *Predict:* the same 1.5 to 1.6× wasm ratio. A gap above 2× would
     point at `call_indirect` cost in that engine, not at the frame
     model.

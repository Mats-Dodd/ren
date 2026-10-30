# R2: stackless frames compiled into C

Track R2 of the runtime-frames research. It asks how a suspending function
should look once it's emitted as C, by tcc for debug and by clang -O2 for
release. Under that are four questions:

- What does the fast path cost when nothing suspends?
- How does a reply resume a frame without growing the C stack?
- What should the emitted resume function look like?
- How is a finished frame marked?

It studies Swift's async lowering, C++20 coroutines, Kotlin, Rust, and a
set of C-emitting or C-hosted systems: Koka, Nim, Lua, Python, Chicken
and protothreads. It also measures the prototype's calling convention
against two alternatives.

Sources, read at these commits unless marked otherwise:

- Swift `1006dea` (2026-10-26), `/tmp/ren-refs/swift`. This is a sparse
  clone. I added `stdlib/public/runtime`, `include/swift/Runtime` and
  `include/swift/ABI` to it with `git sparse-checkout add`.
- swift-evolution `4e7c32c`, `/tmp/ren-refs/swift-evolution`
- tokio `6470b5e` (2026-10-29), `/tmp/ren-refs/tokio`
- Koka `198fc3b`, `/tmp/ren-refs/koka`
- `/tmp/ren-refs/kotlinx-wasm` holds four loose `.kt` files and no
  compiler, so the Kotlin section comes from the web.
- Ren `0be57bb`: `experiments/runtime-p2/switch/c/ren_single.c` (below,
  `ren_single.c`) and foundations.md decisions 12 and 13.

**Web or memory** is marked *(web)* or *(memory)*. Anything not marked
was read in source, or measured here.

**Machine.** Apple M4 Max, 16 cores, shared with other agents. The load
average was 3 to 7 during the runs. Swift 6.0.3, Apple clang 16.0.0,
tcc 0.9.28rc. Every benchmark is in the scratchpad
`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/frames/`.
Each was run three times. The numbers given are a representative run;
the runs were within about 10% of each other.

---

## Summary

- **The prototype's CALL convention is about 4× slower than plain C on
  the fast path at clang -O2.** It costs 3.4 ns a level against plain
  C's 0.8 ns. The cost is memory traffic through the task, not the
  frame bump:
  - the result goes through `t->result`;
  - `t->top` is stored twice a call;
  - `t->sp` is loaded and stored;
  - locals live in the frame.
- **A register convention closes most of the gap.** sp goes in as an
  argument, and `{status, value}` comes back in two registers. Locals
  stay in C locals, spilled only when the function suspends, and frame
  headers are written only on the way out of a suspension. That
  convention costs **0.4 ns a level over plain C** (20.0 against
  14.0 ns at depth 16). That's 3× faster than the prototype, and
  faster than Swift (7 ns a level) or C++ coroutines without HALO
  (about 23 ns a level).
- **The trampoline is the right resume mechanism, and musttail isn't
  needed.**
  - Ren has a direct-return fast path. Swift doesn't: every return is a
    tail call to a continuation.
  - The C stack is provably bounded by the static depth of inline
    completions (measured: constant over 2M resumes).
  - tcc parses `musttail` and silently ignores it (measured: it
    overflows the stack).
- **Re-polling from the root costs O(depth) a wake.** At depth 16 with
  8 suspensions an op, Rust-style re-polling was 2.6× Ren's trampoline
  (275 against 102 to 105 ns).
- **One resume function a suspending function, with a cold dispatch at
  the end, is the right shape for both compilers.**
  - Locals are C locals, reloaded at the dispatch, and the body is
    entered by `goto`.
  - clang still vectorizes an inner loop inside an outer loop that the
    dispatch jumps into (checked with `-Rpass`).
- **"Ends once" needs more than a terminal state.** A finished frame is
  popped and its memory reused by the next call. A late reply must
  therefore never be addressed by a frame pointer. It must go to a
  `(task, call id, generation)`. Swift's `UnsafeContinuation` and C++'s
  resume after `final_suspend` are undefined behaviour for exactly this
  reason.

---

## 1. Swift: coroutine splitting and the task allocator

### How a call is lowered

- **An async function pointer is `{relative fn, context size}`.**
  `AsyncFunctionPointer` holds a 32-bit relative `Function` and a
  `uint32_t ExpectedContextSize`
  (`swift/include/swift/ABI/Executor.h:405-414`). The caller reads the
  size and allocates the callee's context itself:
  `emitAllocAsyncContext` calls `emitTaskAlloc`
  (`swift/lib/IRGen/GenCall.cpp:5444-5449`).
- **A context's header is two words:** `Parent`, and `ResumeParent`, the
  function to call to return (`swift/include/swift/ABI/Task.h:1076-1107`).
  The *caller* writes both into the *callee's* context before the call.
  So the return continuation lives in the child, not the parent: Swift
  is continuation-passing at the ABI.
- **`swifttailcc` plus musttail.** When the target supports the async
  calling convention, IRGen uses `SwiftTail` and `TCK_MustTail`;
  otherwise plain `TCK_Tail` (`swift/lib/IRGen/IRGenModule.cpp:575-582`).
  Where musttail is missing, as on wasm, the function "can return
  control back to the caller", and IRGen emits `ret void` instead of
  `unreachable` (`swift/lib/IRGen/GenCall.cpp:6855-6863`).

**Measured here: the split, in IR.** `swiftc -parse-as-library -emit-ir -O a.swift`
gives `scratchpad/frames/a.ll`. Each `await` of a call splits the
function, whether or not the callee can actually suspend:

- `caller` became a ramp, `$s1a6calleryS2iYaF`, plus two partial
  functions, `...TQ0_` and `...TQ1_`.
- The ramp does four things. It calls
  `swift_task_alloc(ExpectedContextSize)`, stores `Parent`, stores
  `ResumeParent = ...TQ0_`, and musttail-calls the callee.
- `noSuspend` (`x * 3`) still returns by
  `musttail call swifttailcc void %ResumeParent(...)`.
- The continuation `TQ0_` then calls `swift_task_dealloc` on the child's
  context.

So a non-suspending async call costs:

- two out-of-line runtime calls, `swift_task_alloc` and
  `swift_task_dealloc`, each finding the current task through
  `swift_task_getCurrent()`, a thread-local read
  (`swift/stdlib/public/Concurrency/TaskAlloc.cpp:53-63`);
- two indirect tail calls.

There is no "returned DONE inline" path.

- **`swift_task_switch` is the executor hop.** It reads the current
  executor from thread-local tracking info. If no switch is needed, it
  tail-calls the resume function. Otherwise it either assumes the new
  executor on this thread or enqueues the task
  (`swift/stdlib/public/Concurrency/Actor.cpp:2654-2724`).
  `runOnAssumedThread` says why it tail-calls: "We don't want these
  frames to potentially accumulate linearly" (`Actor.cpp:2609-2617`).
- In the Swift 6.0 IR, a nonisolated caller hops back after *every*
  await: `musttail call swift_task_switch(..., i64 0, i64 0)`, to the
  generic executor. That is SE-0338's rule: "on any entry to the
  function, including calls, returns from calls, and resumption from
  suspension, they will switch to a generic, non-actor executor"
  (`swift-evolution/proposals/0338-clarify-execution-non-actor-async.md:33`).
  SE-0461 (Swift 6.2) makes nonisolated async functions run on the
  caller's actor by default (`0461-async-function-isolation.md:1-20`).

### Measured here: Swift's fast path

`sb2.swift`, built with `swiftc -parse-as-library -O`. 20M calls each;
the loop runs in a `nonisolated` async function.

| call | ns a call |
|---|---|
| sync, one level (`@inline(never)`) | 1.16 |
| async, one level, never suspends | 21.1 |
| sync, four levels | 3.5 |
| async, four levels, never suspend | 42.5 |
| `await Task.yield()` round trip | 557 |

- **The outer async call costs about 21 ns.** That's alloc, dealloc, two
  tail calls and one `swift_task_switch` hop that finds no switch
  needed.
- **Each further nested level costs about 7 ns.** Those levels do no hop
  (checked in the IR: `a2`'s continuation goes straight to its parent).
- `@_unsafeInheritExecutor` on the callees changed nothing.

### What Swift teaches Ren

- **A direct-return fast path is worth having.** Swift's 7 ns a level is
  the price of always continuing by tail call and always allocating
  through an out-of-line, thread-local-reading allocator.
- **Frame sizes travel with function pointers.** Swift's
  `{fn, context size}` pair is the answer to "the caller allocates a
  callee frame whose size it can't see". Ren has that problem in debug
  builds across modules, and wherever a frame is reached through a
  dictionary or a block (decision 13). Section 8 and r4 come back to
  this.

---

## 2. C++20 coroutines

- **Ramp, resume, destroy.** clang splits a coroutine into a ramp plus
  `.resume` and `.destroy` clones.
  - Measured here: `clang++ -std=c++20 -O2 -S -emit-llvm co.cpp` gives
    `cpp/co.ll`.
  - The ramp of `c1` allocates the frame with `_Znwm(64)` (operator
    new). It then stores `@_Z2c1y.resume` and `@_Z2c1y.destroy` at
    offsets 0 and 8, and stores the suspend index (`store i2 0`).
  - The frame layout is: resume pointer, destroy pointer, promise,
    copied parameters, spilled locals, and the index.
- **Symmetric transfer (P0913R0)** *(web: Lewis Baker, "C++ Coroutines:
  Understanding Symmetric Transfer", 2020)*.
  - Under the Coroutines TS, `await_suspend` that called `.resume()`
    nested a C frame per resumption. A loop awaiting tasks that
    complete synchronously would "perform unbounded recursion without
    looking like they are doing any recursion" and overflow the stack.
  - The `bool`-returning workaround needed atomics and extra branches.
  - With symmetric transfer, `await_suspend` returns a
    `coroutine_handle`, and the compiler "guarantees that this will
    always be a tail-call, regardless of whether optimisations are
    enabled". Measured here: the `.resume` clones contain
    `musttail call fastcc void %13(...)`.
- **HALO (P0981R0) elides the heap frame when the coroutine's lifetime
  provably nests in the caller.** In practice that means the ramp is
  inlined and the handle doesn't escape.
- **Measured here** (`cpp/co.cpp`: a lazy `task<T>` with symmetric
  transfer; the leaf awaits an awaitable that is always ready):

| variant | depth 1 | depth 4 | allocations an op |
|---|---|---|---|
| coroutines `noinline` (HALO impossible) | 21–24 ns | 96–108 ns | 1 a level |
| coroutines inlinable (HALO fires) | 3.4 ns | 7.2 ns | 0 |

  **HALO fails whenever the coroutine isn't inlined.** That covers
  separate translation units, indirect or virtual calls, recursion and
  `noinline`. Each frame is then an operator-new allocation, about
  23 ns a level here. *(memory)* clang 20 added
  `[[clang::coro_await_elidable]]` to make elision more predictable for
  directly awaited tasks.
- **Lesson for Ren.** Ren needs neither HALO nor symmetric transfer:
  - The frame stack makes allocation a bump, whether or not anything is
    inlined.
  - The direct DONE return keeps inline completion off the resume path.
  - Symmetric transfer solves a problem C++ has because `co_await`
    *always* goes through suspend/resume machinery.

---

## 3. Kotlin: CPS state machines

*(web: KEEP `proposals/coroutines.md`, "Implementation details")*

- **Every suspend function takes a hidden `Continuation` and may return
  the `COROUTINE_SUSPENDED` marker.** Callers check
  `if (result == COROUTINE_SUSPENDED) return` after each call.
- **The state machine is an object with a `label` field.** "An instance
  of the state machine object is created when suspending function is
  invoked." It is "updated and reused" across that invocation's
  suspensions and discarded when the function completes.
  - So **Kotlin allocates on entry, on the heap, even when nothing
    suspends.**
  - The KEEP notes that the compiler *may* later create it only at the
    first suspension point.
  - Functions whose suspending calls are all tail calls get no state
    machine.
- **On resume, Kotlin walks back up by calling `resumeWith` on each
  completion.** That is a nested call a level, the same shape as Ren's
  trampoline minus the loop.
- **No published numbers** for "a suspend fun that doesn't suspend"
  were found. The structure is one JVM allocation and one type check
  per call.
- **Lesson for Ren.** Kotlin's marker return is the same idea as Ren's
  DONE/PENDING, and that part is confirmed prior art. Ren's bump
  allocator removes Kotlin's per-call heap allocation.

---

## 4. Rust: poll from the root

- **A task is one future, polled from the top.** tokio's `Core::poll`
  pins the task's root future and calls `future.poll(&mut cx)`
  (`tokio/tokio/src/runtime/task/core.rs:365-387`). On `Ready`, it drops
  the future (`core.rs:381-383`). The harness wraps this in
  `catch_unwind` (`tokio/tokio/src/runtime/task/harness.rs:523-545`).
- **Every wake re-enters at the root.** Each `async fn` state machine
  matches its state and re-polls the child future it is awaiting, down
  to the leaf that registered the waker. A wake therefore costs
  O(depth) calls even when only the leaf has news.
  - *(web: users.rust-lang.org "Quadratic slowdown with many nested
    futures", 2018)* This was a real quadratic for nested combinator
    enums. `async`/`await` made the per-level cost small, but not zero.
  - *(web: Yoshua Wuyts, "The Waker Allocation Problem")* `join` has
    the same shape across siblings. It needs per-child wakers to avoid
    re-polling every child.
- **No published measurement of deep `.await` chains was found.**
  Section 6 measures an analogue in C.
- **Polling after completion.** *(memory)* rustc's generated `async fn`
  panics with "`async fn` resumed after completion". The `futures`
  crate's `FusedFuture::is_terminated` lets a combinator avoid that.
  tokio sidesteps it by dropping the future on `Ready`.
- **Lesson for Ren.** Ren's parent pointers let a reply start at the
  innermost frame. Its cost is O(1) to resume, plus O(levels that
  actually finish). This is the one structural advantage over Rust that
  the measurements confirm.

---

## 5. C-emitting and C-hosted systems

- **Koka (C backend): yield bubbling, not CPS.**
  - Every call that may yield is followed by `if yielding() then
    yield-extend(next) else next(x)` (`koka/lib/std/core/hnd.kk:288-296`).
    `kk_yielding` is a load of a context field (`kklib/include/kklib.h:472-475`).
  - When yielding, `kk_yield_extend` pushes a heap continuation closure
    onto `ctx->yield.conts`, at most `KK_YIELD_CONT_MAX` (8) before
    composing them (`lib/std/core/inline/hnd.c:324-341`,
    `kklib/include/kklib.h:417`).
  - **So Koka builds the continuation lazily, on the way out of a
    yield.** The fast path is one predictable branch a call. That is the
    "headers written only on the way out" idea measured in section 6.
- **Nim closure iterators** *(memory)*. The `closureiters` pass lowers an
  iterator into one function with a `:state` field. Its body becomes a
  `case` (C `switch`) over states inside a loop, and locals live across
  yields are lifted into the environment object. That is the protothread
  shape with real locals. Nim's async is built on it (asyncmacro), with
  a heap closure a future.
- **Lua coroutines** *(memory, Lua 5.2+ manual §4.7 "Handling Yields in
  C")*.
  - Lua coroutines are stackful over Lua frames, but a C function on the
    stack can't be suspended. Yielding across it fails with "attempt to
    yield across a C-call boundary".
  - The fix is `lua_callk`/`lua_pcallk`/`lua_yieldk`. They take a
    *continuation function* that Lua calls instead of returning into the
    C frame.
  - This is exactly Ren's rule that "a plain C call can't be suspended
    across". Lua made C functions opt in with a hand-written
    continuation. Ren makes the compiler write it, and refuses
    suspension inside `foreign fn`.
- **Python generators** *(memory, PEP 380)*.
  - Frames live on the heap. `yield from` delegates by forwarding each
    `send`/`next` down the chain of `gi_yieldfrom` sub-generators, so a
    resume of a depth-d delegation is O(d) C-level calls.
  - This is the "boxed recursive `yield from`" trap that streams.md:597
    already names.
- **Chicken Scheme, Cheney on the MTA** *(memory, Baker 1995)*.
  - The program is CPS-converted to C functions that never return. The C
    stack is the nursery.
  - When it nears its limit, live data is copied to the heap and a
    `longjmp` resets the stack.
  - It shows a C backend can give unlimited, cheap continuations. It
    does so by making every call a heap-escape candidate and giving up
    C's native return. That is the opposite of Ren's aim that plain code
    stay plain C.
- **Protothreads / Duff's device** *(memory, Dunkels et al. 2006)*.
  - `switch (pt->lc) { case 0: ... case __LINE__: ... }` lets a function
    resume into the middle of loops.
  - Its limits are no locals across a wait and no `switch` in the body,
    because the case labels collide.
  - Ren's emitted shape keeps the trick, jumping into loop bodies, but
    uses `goto` labels instead of case labels, so the body may contain
    `switch`. It also stores live locals in the frame.
- **Lean 4** *(memory)* has no coroutines in its C backend. Its `Task`s
  are threads or thunks.

---

## 6. Measured here: the fast path and the resume path in C

`scratchpad/frames/fastpath.c` is modelled on `ren_single.c`.

**The chain.** A chain of D suspending functions:

- level k calls level k−1 and adds 1;
- the leaf calls a driver `submit()` (noinline), which either answers
  inline or doesn't;
- every chain function is `noinline`, so levels can't merge;
- the task body loops n times calling the chain's top.

**Five variants:**

- **plain**: the same chain as plain C calls.
- **ren**: the prototype's `CALL`.
  - It pushes a full header with `frame_push`.
  - It stores `t->top` before and after the call.
  - Results go through `t->result`; locals live in the frame.
  - `ren_single.c:124-145` and `323-331`.
- **lazy**: as `ren`, but the header (`resume`, `parent`) and `t->top`
  are written only on the SUSPEND path. The fast path just bumps and
  restores `sp`.
- **reg**, the register convention:
  - `rv2 fn(task *t, frame *f, char *sp, uint64_t in)` returns
    `{status, value}` in two registers.
  - Callee frames bump from `sp`.
  - Arguments arrive in registers (`in`), and locals are C locals,
    spilled to the frame only when the function suspends.
  - Headers are lazy, as in `lazy`.
  - On resume, `in` carries the finished child's value.
- **poll**: Rust-style.
  - Each level keeps its child's frame. On a wake, the chain's root is
    polled, and each level re-polls its child.

`_susp` means the driver never answers inline. The leaf suspends, the
chain unwinds to `step()`, and the bench writes the reply and calls
`step()` again. K is the number of suspensions a leaf call makes.

**Commands:** `clang -O2 -o fp_clang fastpath.c`,
`tcc -o fp_tcc fastpath.c`, then `./fp_clang <depth> 10000000 1` and
`./fp_tcc <depth> 5000000 1`.

**clang -O2, K = 1, ns per op** (an op is one call of the chain):

| depth | plain | ren | ren_susp | lazy | lazy_susp | reg | reg_susp | poll_susp |
|---|---|---|---|---|---|---|---|---|
| 1 | 2.31 | 5.34 | 7.63 | 5.16 | 7.58 | **3.02** | 8.04 | 8.38 |
| 4 | 4.88 | 16.52 | 23.78 | 14.03 | 21.90 | **6.33** | 17.68 | 23.51 |
| 16 | 14.04 | 58.79 | 82.52 | 56.82 | 91.74 | **20.01** | 72.54 | 73.08 |

**tcc, K = 1, ns per op:**

| depth | plain | ren | ren_susp | lazy | reg | reg_susp | poll_susp |
|---|---|---|---|---|---|---|---|
| 1 | 4.60 | 15.35 | 21.80 | 14.03 | 12.30 | 31.33 | 22.96 |
| 4 | 11.85 | 50.64 | 81.90 | 49.26 | 41.89 | 94.50 | 82.16 |
| 16 | 19.24 | 210.53 | 294.67 | 206.15 | 230.82 | 384.58 | 431.78 |

**Eight suspensions an op (K = 8), ns per op:**

| build, depth | ren_susp | reg_susp | poll_susp |
|---|---|---|---|
| clang, 4 | 46.7 | 50.0 | 90.8 |
| clang, 16 | 102.5 | 105.0 | **275.5** |
| tcc, 16 | 367.6 | 504.5 | **961.6** |

What the numbers say:

- **The prototype's fast path is 3.4 ns a level at -O2.** That's
  (58.79 − 5.34) / 15. Plain C costs about 0.8 ns a level.
  - The code clang emits for a level is about 20 instructions
    (checked: `clang -O2 -S`, function `_s2`).
  - The cost is serial memory dependencies through the task. `t->sp` is
    stored and reloaded at every level on the way down, and
    `t->result += 1` is a read-modify-write at every level on the way
    up.
- **Lazy headers alone buy only 5 to 15%.** The header stores aren't on
  a dependency chain.
- **The register convention costs 0.4 ns a level over plain at -O2.**
  That's (20.01 − 14.04) / 16. It is 2.9× faster than the prototype at
  depth 16.
  - This is the single most useful finding here. The CALL in
    `ren_single.c` shouldn't be what release emits.
  - Swift pays 7 ns a level, and C++ without HALO about 23.
- **Under tcc, nothing is fast,** and the conventions are within about
  15% of each other.
  - tcc returns the 16-byte struct through memory and keeps few values
    in registers.
  - Debug code runs 3 to 11× slower than plain tcc C on this
    call-dominated microbenchmark. That is within decision 13's
    accepted range for call-heavy code, not for whole programs.
  - **One convention for both builds is fine.** Prefer `reg`: it is
    clang's win, and only about 10% slower than `ren` under tcc.
- **The resume path is cheap.** In `reg`, one suspension and one resume
  at depth 16 add about 52 ns: 16 SUSPEND returns with header writes,
  then 16 trampoline iterations with indirect calls. That's about 3 ns
  a level, paid only when something actually suspends.
- **Re-polling from the root costs about 1.4 ns a level per extra
  wake.** At K = 8 and depth 16 it is 2.6× the trampoline under clang,
  and 1.9 to 2.6× under tcc. Ren's choice is confirmed.
- **The C stack stays bounded (measured).**
  - `submit()` records the lowest and highest addresses of a local
    across all calls in the `_susp` run.
  - With K = 8, the span is 48, 192 and 768 B at depths 1, 4 and 16:
    exactly one 48-B C frame a level.
  - The span is constant over 2M ops. The resumed leaf runs directly
    under `step()`, and the first call runs under the full inline
    chain. Nothing accumulates.

**One more measurement: the chunk boundary.** The prototype frees an
overflow chunk as soon as it empties (`ren_single.c:135-145`).
`THRASH=1 ./fp_clang 1 5000000 1` puts the chain's frame just past the
inline segment. Each call then mallocs and frees a 4-KiB chunk: `ren`
goes from 5.4 to 23.2 ns an op. See r4 for the fix: keep a spare
chunk, as Swift keeps empty slabs.

---

## 7. Keeping the C stack bounded on resume

**The invariant.** At any moment, the C stack holds `step()` plus the
frames called *inline* since the last resume. Every suspension returns
PENDING all the way up to `step()`. Every resume starts a fresh C call
from `step()`.

**The case in the brief is safe.** A reply resumes the innermost frame;
it finishes; the trampoline resumes its parent; the parent calls
another child that completes inline. The C stack is then `step` →
parent → child, and it unwinds back to `step` before the next loop
iteration.

**The C stack's depth is bounded by** (frames resumed: 1) + (the
deepest chain of inline completions). That is the static call depth,
plus recursion when a recursive suspending function completes inline.
The recursion case is the same as plain recursion, which decision 13
already accepts.

**The mechanisms compared:**

| mechanism | per finished frame on resume | needs | used by |
|---|---|---|---|
| trampoline (`step()` loop) | one indirect call + one return | nothing | Ren prototype; Kotlin, in effect |
| musttail continuation | one indirect tail call | `musttail` (clang, gcc 15) | Swift (`IRGenModule.cpp:575-582`) |
| symmetric transfer | one indirect tail call | compiler-guaranteed tail calls | C++20 |

- **tcc has no musttail.** It accepts `__attribute__((musttail))` and
  ignores it. Measured here (`scratchpad/frames/cg.c`): mutual recursion
  100M deep with `musttail` on both returns *segfaults under tcc*, and
  runs under clang -O0.
- **Ren doesn't need musttail.** Swift needs it because a callee
  *returns* by tail-calling the parent's continuation. Ren's callee
  returns DONE to a direct caller on the fast path. Only the resume path
  goes through `step()`, which is already a loop.
- **A child can't tail-call its parent's resume instead.** It would have
  to know whether it was called inline (return to the caller) or
  resumed (continue the parent), and that is a branch either way.
- **Recommendation: the trampoline in both builds. No musttail anywhere.**

**One missing rule.** The fast path grows the native stack for inline
completions, so worker threads need native stacks as large as the main
thread's. macOS gives secondary pthreads 512 KiB by default *(memory)*.
The core must create workers with an explicit stack size (8 MiB), or
deep inline recursion will crash only off the main thread.

---

## 8. What a resume function should look like in C

**One function a suspending function.** Inside it:

- fresh entry runs straight-line code on C locals;
- each suspension point spills the live locals and returns;
- a cold `dispatch:` block at the bottom reloads the live locals and
  `goto`s into the body.

### Why this shape

- **One function, not one per state.**
  - Swift-style splitting needs musttail between the pieces, and tcc
    has none.
  - One function also keeps `#line` stepping sane in lldb (decision 13).
- **C locals, not frame fields, for anything live.**
  - Frame-resident locals across an opaque call, such as `submit(&...)`,
    must be stored and reloaded around every call. That is part of the
    3.4 ns a level above.
  - With C locals whose address is never taken, clang keeps them in
    registers. The frame is touched only on the suspend and resume
    paths.
- **Entry by `goto` into loop bodies is fine for clang.**
  - Measured here (`scratchpad/frames/irr.c`): an outer loop the
    dispatch jumps into. Its hot inner loop has no suspension point, and
    clang -O2 still reports "vectorized loop (vectorization width: 4,
    interleaved count: 4)".
  - Only the loop that contains the suspension point becomes
    irreducible. Such a loop makes a suspending call every iteration,
    so it was never a vectorization candidate.
- **`switch` for the dispatch, not computed goto.**
  - tcc does accept `&&label` (measured: `cg.c`), so either works.
  - A `switch` on a dense 1..n state is a jump table in clang and is
    easier to read in a debugger.
  - Computed goto would save one bounds check on a cold path only.
- **No protothread case labels in the body.** They break a Ren `match`
  lowered to a C `switch` that spans a suspension point.

### The recommended C (identical for tcc and clang)

```c
/* ---- core ABI (the core's header, shared by both builds) ---- */
typedef struct ren_task ren_task;
typedef struct ren_frame ren_frame;
typedef struct { uintptr_t st; uint64_t v; } ren_ret;  /* x0/x1, rax/rdx */
enum { REN_DONE = 0, REN_PENDING = 1 };
typedef ren_ret (*ren_resume)(ren_task *, ren_frame *, char *sp, uint64_t in);

struct ren_frame {           /* 32 B */
  ren_resume resume;         /* written by the caller, on the way out of a suspension */
  ren_frame *parent;         /* ditto */
  uint32_t state;            /* 0 fresh; 1..n suspension points; REN_ENDED */
  uint32_t flags;            /* FIRST_IN_CHUNK, ... */
  char *sp;                  /* this frame's stack top when it suspended */
};
#define REN_ENDED 0xffffffffu

/* Places a callee frame at sp; returns the callee's sp. Past the segment's
   limit, ren_grow (out of line) puts the frame at the start of a chunk and
   sets REN_FIRST_IN_CHUNK. size is a constant, 16-aligned. */
static inline char *ren_bump(ren_task *t, char *sp, uint32_t size, char **frame) {
  if (REN_UNLIKELY(sp + size > t->limit)) return ren_grow(t, size, frame);
  *frame = sp;
  ((ren_frame *)sp)->flags = 0;
  return sp + size;
}
```

A Ren function that reads until EOF and counts bytes. `read` may
suspend (it reaches a world call):

```c
typedef struct { ren_frame h; Reader src; int64_t total; } count_frame;

ren_ret count_resume(ren_task *t, ren_frame *hf, char *sp, uint64_t in) {
  count_frame *f = (count_frame *)hf;
  Reader src; int64_t total; ren_ret r;
  if (REN_UNLIKELY(f->h.state != 0)) goto dispatch;
  src = f->src;                     /* arguments: the caller wrote them */
  total = 0;
  for (;;) {
    { /* let n = try src.read() */
      read_frame *c;
      char *csp = ren_bump(t, sp, sizeof(read_frame), (char **)&c);
      c->h.state = 0; c->src = src;
      r = read_resume(t, &c->h, csp, 0);
      if (REN_UNLIKELY(r.st == REN_PENDING)) {
        c->h.resume = read_resume; c->h.parent = &f->h; c->h.sp = csp;
        f->src = src; f->total = total;         /* spill what's live */
        f->h.state = 1; f->h.sp = sp;
        return r;
      }
    }
  s1:
    if (r.v == 0) break;
    total += (int64_t)r.v;
  }
  f->h.state = REN_ENDED;           /* debug builds only; see section 9 */
  return (ren_ret){REN_DONE, (uint64_t)total};

dispatch:                           /* cold: reload, then enter the body */
  src = f->src; total = f->total;
  switch (f->h.state) {
  case 1: r.v = in; goto s1;
  default: ren_panic_resumed_after_end(hf);   /* never returns */
  }
}
```

The innermost suspender, a bottom handler's world call, records itself
for the core: `f->h.state = k; f->h.sp = sp; t->top = &f->h; return
(ren_ret){REN_PENDING, 0};`. It is the only place that writes `t->top`.

The core's trampoline:

```c
void ren_step(ren_task *t, uint64_t reply) {   /* reply: small payload, or 0 */
  ren_frame *f = t->top;
  uint64_t in = reply;
  for (;;) {
    ren_ret r = f->resume(t, f, f->sp, in);
    if (r.st == REN_PENDING) return;           /* the suspender set t->top */
    ren_frame *p = f->parent;
    if (REN_UNLIKELY(f->flags & REN_FIRST_IN_CHUNK)) ren_chunk_retire(t, f);
    if (!p) { ren_task_finish(t, r.v); return; }
    t->top = f = p;
    in = r.v;
  }
}
```

**Notes on the sketch:**

- **Nothing is written to the task on the fast path, and nothing is
  "popped".** `sp` is a C local, and a callee's frame disappears when
  the caller stops using `csp`. On resume, a frame's stack top is the
  `sp` it saved, not its address plus its size. That matters for r4: a
  frame that has bumped a generator's frame above itself must protect
  that frame from its own callees.
- **Values wider than 8 B,** and error results, go through an
  out-pointer into the caller's frame or a C local. `v` carries a
  scalar or a pointer to it.
- **Cross-module and dictionary calls in debug builds** can't use
  `sizeof(read_frame)`. They read the size from a descriptor next to
  the resume function: `{ren_resume fn; uint32_t frame_size}`, Swift's
  `AsyncFunctionPointer` (`Executor.h:405-414`). A block is then
  `{descriptor*, captured-frame*}`.
- **The prototype's frame header carries a `size`, and the proposal
  adds a `task` field.** The task is always an argument, so it doesn't
  belong in the header. `size` is replaced by `sp`.

### Release-only refinements

These are optional, and none is needed for correctness:

- **Inline known callees.** Decision 12 already allows it. The callee's
  locals join the caller's frame, and its states join the caller's
  switch.
- **Mark the dispatch `__attribute__((cold))`** through a helper, and
  give the `PENDING` branches `__builtin_expect`.
- **Skip the bounds check on bump** when the task's inline segment is
  sized to the static maximum (r4) and the call is non-recursive.

---

## 9. Ends once: terminal states

| system | how a finished frame is marked | what happens if resumed again |
|---|---|---|
| Swift | context freed by its caller's continuation (`swift_task_dealloc` in `TQn_`, measured IR) | no frame left; `CheckedContinuation` traps on double resume, `UnsafeContinuation` is UB *(memory)* |
| C++20 | suspended at `final_suspend`; `handle.done()` true | resuming is UB |
| Kotlin | state-machine object discarded; `SafeContinuation` | "Already resumed" `IllegalStateException` *(memory)* |
| Rust | future dropped on `Ready` (tokio `core.rs:381-383`) | rustc's generator panics "resumed after completion" *(memory)*; `FusedFuture` opts out |

**For Ren, a terminal state in the frame is necessary but not enough.**

- A finished frame is popped, and its bytes are reused by the very next
  call at the same `sp`. A stale resume aimed at the old frame pointer
  would run *someone else's* state machine with a plausible state.
- **The real guard is that nothing outside the task holds a frame
  pointer:**
  - replies address `(task, call id)` with a generation (proposal
    point 2);
  - the core checks the generation against the task's pending call;
  - only then does it call `ren_step(t, reply)`.
- **`REN_ENDED` is a debug assertion only.** Release can make the
  `default:` arm `__builtin_unreachable()`.
- **Swift shows the cost of getting this wrong.** `UnsafeContinuation`
  is a raw context pointer, and double resume is memory corruption.
  Ren should never hand out the equivalent.

---

## What this means for Ren

### Point 1 (plain or suspending per specialization)

- **Confirmed, with a number.** A call into a suspending function that
  doesn't suspend costs 3.0 against 2.3 ns at depth 1, and 20 against
  14 ns at depth 16, against plain C under clang -O2 (`reg`, section 6).
  - That makes the colour split matter less than feared for release.
  - It still matters for debug builds (3 to 11× under tcc) and for code
    size: every suspending function carries a dispatch and spill paths.
  - Computing colours per specialization stays right.
- **Missing: the convention.** The proposal says only "returns DONE or
  PENDING". **Fix:** specify the register convention in section 8:
  - `ren_ret fn(task*, frame*, char *sp, uint64_t in)`;
  - lazy headers;
  - C locals spilled on suspend.

### Point 2 (stackless frames, trampoline)

- **Confirmed: the trampoline, not re-polling from the root.** It is
  2.6× faster at depth 16 with 8 wakes. The C stack is bounded by the
  static depth of inline completions (measured constant over 2M
  resumes).
- **Confirmed: no musttail is needed,** and tcc couldn't provide it.
  Swift needs musttail only because it has no direct-return path.
- **Wrong in detail: the prototype's CALL must not be what release
  emits.**
  - It is 2.9× the cost of the register convention at depth 16.
  - It writes `t->top` and `t->result` on every call.
  - **Fix:** `t->top` is written only by the innermost suspender.
    Headers are written by callers on the PENDING path. Results come
    back in registers.
- **Wrong in detail: the header.**
  - Drop `task`: it's an argument.
  - Replace `size` with a saved `sp`.
  - Add a `flags` bit for "first in an overflow chunk", so the
    trampoline retires chunks without comparing against `t->chunk` on
    every pop.
- **Missing: the debug-build frame size.** Use a `{fn, frame_size}`
  descriptor wherever the callee isn't statically known.
- **Missing: "ends once" needs the generation check in the core, not
  just a terminal state.** Frames are reused at the same address.
- **Missing: worker threads need a full-size native stack (8 MiB).**
  Inline completion uses it.

### Candidate open decisions

1. **One calling convention for both builds** (recommended: `reg`).
   - For: one emitter path; clang's 3× win.
   - Against: tcc is about 10% slower than with the `ren` convention.
   - The alternative, two conventions, doubles the emitter's lowering
     for little gain.
2. **One resume function with a bottom dispatch, or one function a
   state** (recommended: one function).
   - For: tcc has no musttail; debugger stepping; code size.
   - Against: loops containing a suspension point become irreducible.
     Measured harmless for inner hot loops.
3. **Spill to the frame at suspension only, or keep live locals in the
   frame always** (recommended: spill at suspension).
   - For: the measured gap.
   - Against: the emitter must compute liveness at each suspension
     point. It needs that anyway to size the frame.

### Experiments worth running

- **Rewrite `ren_single.c`'s `pingpong_nested` with the `reg`
  convention.**
  - Prediction: the nested round trip drops from about 31 ns (Xeon) to
    within 20% of the inlined `pingpong`. On this M4: from roughly 2×
    `pingpong` to about 1.2×.
- **The same microbenchmark with a 24-byte result returned through an
  out-pointer.**
  - Prediction: +0.3 to 0.5 ns a level under clang. That would still be
    well under the prototype.
- **A tcc-specific check: pass `sp` and return status only, with the
  value through `t`.**
  - Prediction: tcc's `reg` drops to about `ren`'s numbers, and clang
    loses about 1 ns a level. Run it only if debug-build call overhead
    shows up in real programs.
- **An emitted-C smoke test once the compiler emits frames.** Compile a
  generated resume function containing a `match` lowered to `switch`
  across a suspension point, under tcc and clang -O2.
  - Prediction: both compile. clang vectorizes any inner loop without a
    suspension point (`-Rpass=loop-vectorize`).

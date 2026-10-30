# R4: the frame stack allocator

Track R4 of the runtime-frames research. It asks whether a per-task
LIFO bump allocator for frames (proposal point 2) holds up. It studies
Swift's task allocator in source, checks where LIFO breaks in other
languages, and walks Ren's generators, scopes and `with` blocks through
the allocator case by case. It ends with sizing.

Sources, read at these commits unless marked otherwise:

- Swift `1006dea` (2026-10-26), `/tmp/ren-refs/swift`, a sparse clone.
  I added `stdlib/public/runtime`, `include/swift/Runtime` and
  `include/swift/ABI` with `git sparse-checkout add`.
- swift-evolution `4e7c32c`, `/tmp/ren-refs/swift-evolution`.
- Ren `0be57bb`: foundations.md decisions 12 and 13, streams.md,
  `experiments/runtime-p2/switch/c/ren_single.c`.

Web and memory are marked *(web)* and *(memory)*. Measurements were run
on an Apple M4 Max, shared with other agents, at a load average of 3 to
7, with Swift 6.0.3 and Apple clang 16. Code is in
`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/frames/`.

---

## Summary

- **Swift's allocator is the proposal's allocator, and Swift enforces
  LIFO with a fatal error.** A dealloc of anything but the last
  allocation is "freed pointer was not the last allocation". Swift keeps
  emptied slabs instead of freeing them. Ren's prototype frees overflow
  chunks at once, which thrashes at the boundary: measured 5.4 → 23.2 ns
  a call.
- **Swift keeps LIFO through structure, not cleverness.**
  - `async let`'s child task lives in 640 B reserved in the parent's
    frame, and its scope ends after the child is awaited.
  - Task-group and unstructured children get their own malloc'd tasks.
  - Ren's scopes map onto this exactly.
- **Ren's generators are LIFO-safe, for one reason: `yield` appears
  only in the generator's own body** (streams.md:322). At a yield, none
  of the generator's callee frames is live. So any number of pulled
  generators, `zip`ped or not, are fixed slots that are never above the
  stack top across a yield.
- **The exception is a pulled *recursive* `yield from`.** Its
  delegation chain survives yields and grows and shrinks at run time.
  On the task's stack, two such generators zipped interleave and break
  LIFO. **Each one needs its own frame stack,** owned by its hidden
  local. That's how "one frame stack the consumer owns" (decision 12)
  must be read.
- **Debug builds can't make a generator's frame a static hidden local**
  across modules: the size isn't known at the consumer's compile time.
  **Fix:** bump it on the consumer's frame stack at the `let`, sized by
  a `{fn, frame_size}` descriptor (Swift's `AsyncFunctionPointer`), and
  have the consumer save its `sp` past it.
- **Memory per parked task: Swift is about 1.4 KB.** Measured here,
  1,426 B a task at depth 0 and 2,796 B at depth 8; the second number
  is a second slab. The prototype's is 128 B. Swift's first slab is a
  separate malloc of up to 1 KiB on a plain task's first
  `swift_task_alloc`. The 512-B inline first slab exists only for
  `async let` and run-inline tasks.

---

## 1. Swift's task allocator, in source

- **The allocator is `StackAllocator`,** "a bump-pointer allocator that
  obeys a stack discipline"
  (`swift/stdlib/public/runtime/StackAllocator.h:60-90`).
  - Its slabs are linked (`Slab::next`, `:140-152`).
  - Every allocation has a 16-B header: `previous` and `slab`
    (`:243-267`). So deallocation needs no size, and `deallocThrough`
    can walk back.
- **LIFO is enforced.**
  - `dealloc` checks that the pointer is `lastAllocation`. If not, it
    calls `SWIFT_FATAL_ERROR(0, "freed pointer was not the last
    allocation")` (`:401-412`).
  - The one exception is when the slab allocator is disabled, and it
    falls back to `free`.
  - Debug builds also guard each allocation with an end marker and
    poison freed memory (`:124-131, 216-235`).
- **Emptied slabs are kept for reuse.** "In general, slabs which become
  unused are _not_ freed, but reused for subsequent allocations"
  (`:71-74`).
  - On allocation, an existing empty successor slab is reused if it
    fits (`:278-284`).
  - If it doesn't fit, all successors are freed, and one slab of their
    combined capacity is allocated (`:285-291`).
  - All slabs are freed only when the task is destroyed (`:363-370`).
- **Slab size.** `SlabCapacity = 1024 - 8 - slabHeaderSize()`, so a
  slab plus its header fits "a 1024-byte malloc quantum"
  (`swift/stdlib/public/Concurrency/TaskPrivate.h:1077-1089`). An
  allocation bigger than that gets a slab of its own size
  (`StackAllocator.h:299-300`). There is no geometric growth.
- **The allocator lives inside the task.**
  - `PrivateStorage::Allocator` is "2 words + 4 bytes"
    (`TaskPrivate.h:1104-1106`).
  - Every `swift_task_alloc` finds it through `swift_task_getCurrent()`,
    a thread-local read (`swift/stdlib/public/Concurrency/TaskAlloc.cpp:39-63`).
  - It is on by default: `SWIFT_DEBUG_ENABLE_TASK_SLAB_ALLOCATOR`
    defaults to true, and turning it off routes every frame to `malloc`
    for memory tools (`swift/stdlib/public/runtime/EnvironmentVariables.def:173-176`).
- **Where the first slab comes from.**
  - A plain task (`swift_task_create`) is one `swift_slowAlloc` of the
    header plus the initial context. Its allocator starts with no slab,
    so the first frame mallocs one of about 1 KiB
    (`swift/stdlib/public/Concurrency/Task.cpp:1457-1491, 1734-1741, 1878-1886`).
  - `initialSlabSize = 512` (`Task.cpp:1700`) is used only when an
    `async let` or a run-inline task has spare preallocated room
    (`Task.cpp:1702-1736`).
  - So r3's line "a 512-B first slab" is right for `async let` only.
- **`swift_task_dealloc_through`** pops everything down to and including
  a pointer (`StackAllocator.h:414-424`, `TaskAlloc.cpp:69-71`). IRGen
  uses it for yield-once coroutine callee frames
  (`swift/lib/IRGen/GenCall.cpp:5484-5488`). Such a callee frame may
  leave allocations of its own above it, and the caller frees the lot.
  This is the one place Swift admits a frame doesn't free its own
  sub-allocations in order.

### Does a frame ever outlive LIFO order in Swift?

- **`async let`: no, by construction.**
  - IRGen allocas `NumWords_AsyncLet` = 80 words, "640 bytes ought to be
    enough for anyone" (`swift/include/swift/ABI/MetadataValues.h:69`,
    `swift/lib/IRGen/GenConcurrency.cpp:248-251`).
  - In an async function, that alloca lives in the parent's context,
    which is task-allocated.
  - The child *task object* is placed in it, and its leftover room
    becomes the child's first slab (`Task.cpp:1706-1726`).
  - If it doesn't fit, the child is carved from the parent's allocator
    with `_swift_task_alloc_specific(parent, ...)` and flagged
    `DidAllocateFromParentTask`
    (`swift/stdlib/public/Concurrency/AsyncLet.cpp:58-63`).
  - It is freed when the `async let` finishes, after the child has
    completed (`AsyncLet.cpp:316-335`). An `async let`'s scope always
    awaits or cancels-and-awaits the child, so the parent's frames above
    it are gone by then.
  - **This is Ren's "a scope's captured frame is the spawner's"** with
    one more trick: the child task's storage sits *inside* the parent's
    frame stack.
- **Task groups and unstructured tasks** get a heap task each
  (`Task.cpp:1738`). Their frames never touch the parent's allocator.
  SE-0304 says they "are not able to utilize some of the optimization
  techniques wrt. allocation"
  (`swift-evolution/proposals/0304-structured-concurrency.md:451`).
- **Out-of-order frees can't happen in correct Swift.** The compiler
  emits `swift_task_dealloc` in reverse allocation order, and the
  runtime traps otherwise.

### Measured here: memory per parked Swift task

`idle.swift`, built with `swiftc -parse-as-library -O`. It starts 100k
`Task.detached` tasks. Each recurses `depth` async calls and parks in
`withUnsafeContinuation`. Footprint is `TASK_VM_INFO.phys_footprint`.

| chain depth when parked | bytes a task |
|---|---|
| 0 | 1,426 |
| 8 | 2,796 |

- **The 1.4 KB at depth 0** is the heap task, its future fragment, and a
  roughly 1-KiB first slab.
- **Eight more frames add a second 1-KiB slab.**
- r3 measured 1,483 B a task in a task group, which agrees.
- The prototype parks a task in 128 B (`ren_single.c:85-99`;
  SUMMARY.md). The difference is Swift's malloc'd first slab and a task
  header about 3× Ren's.

---

## 2. What breaks LIFO elsewhere

- **C++20.**
  - Each coroutine frame is a separate heap allocation unless HALO
    places it in the caller's frame. Measured in r2: 1 allocation a
    level when not inlined.
  - Nothing is LIFO: a `task` can be moved, stored, or destroyed out of
    order.
  - HALO is legal only when the compiler proves the coroutine's
    lifetime nests in the caller's. That's the LIFO proof done per call
    site.
- **Rust.**
  - A child future is a *field* of its parent's state machine, held
    inline. The task's total size is static, and recursion needs
    `Box::pin`.
  - Futures are values: they can be stored in structs, raced in
    `select!` (the loser is dropped mid-flight), or polled in any order
    by `join`. None of that is LIFO, and none of it needs to be, since
    there is no stack to break.
  - The costs are size bloat and boxing. *(memory)* Large futures are a
    known problem, with clippy's `large_futures` lint and tokio's
    boxing of large spawned futures.
- **Kotlin.** Every state machine is a JVM heap object, so order is
  irrelevant.
- **Go and Loom.** Frames are real stack frames on a growable or
  copyable stack, so the question doesn't arise. The costs are in r3.
- **Swift.** LIFO by construction, as above. The non-LIFO cases, task
  groups and unstructured tasks, are made separate tasks.

**The pattern:** LIFO holds when every frame that must outlive a
suspension is either below the suspended point on one stack, or owned
by a different stack (a task). Ren's design has to put each frame in
one of those two places.

---

## 3. Does LIFO hold with Ren's generators, scopes and `with`?

**The governing facts.**

- **A pulled generator's frame is a hidden local of its consumer**
  (foundations.md decision 12, streams.md rule 2).
- **`yield` appears only in the generator's own body,** never inside a
  `fn` literal (streams.md:322).
- **A generator's step is an ordinary call from whoever steps it.**
  Callee frames that the step pushes sit above the stack top.

**The cases:**

| case | frames live across a yield | LIFO? |
|---|---|---|
| one pulled generator G, stepped by consumer C | only G's own frame, a fixed slot inside C's frame | yes |
| G's step calls `f()`, which suspends on I/O | `f`'s frames above C's top; C is waiting in its step | yes: plain nesting |
| G yields while a callee is live | impossible: `yield` is only in G's body, so callees have returned | n/a |
| zip(A, B): create A, create B; step A, step B, step A... | A's and B's slots in C's frame; nothing above the top between steps | yes, in any order |
| A ends before B | A's `finally` runs as a call on top; A's slot is reclaimed with C's frame | yes |
| scope end with A and B | they close in reverse order, as `with`s do (streams.md:371) | yes |
| non-recursive `yield from child()` | child's frame is a fixed slot inside G's frame | yes |
| **recursive `yield from`, pulled** | the delegation chain G → G1 → … → Gk, of run-time length, live across yields | **no, if it shares the task's stack** |
| two recursive pulled generators zipped | A's chain, then B's chain on top; then A's chain shrinks (A2 ends) below B1 | **breaks** |
| pipeline passed to a block parameter, stepped in a callee F | G's slot is in C's frame (below F); G's callees go above F's frames, popped at the yield | yes |
| `Async.produce`, `Async.merge` | each source gets a producer task with its own frame stack (streams.md:495-506) | yes |
| spawned task in a scope | its own frame stack; it reads the spawner's frame, which outlives it (structured) | yes |
| `with` installing a handler instance whose state lives in a frame | the instance lives in the installing frame; operations run as calls above it; the instance ends with the frame | yes |
| a generator holding a `with` across a yield | the `with`'s state is in G's slot; it ends with G, inside C's scope (streams.md:372-375) | yes |
| a value cursor (data) | not a frame: no dependency in its row, so it never suspends; its state is data | n/a |

**Recursive `yield from` needs its own stack.**

- **The problem.** decision 12 says "a recursive `yield from` that must
  pull runs on one frame stack the consumer owns". Read as "the
  consumer's task stack", zip of two tree walkers breaks.
- **The fix: the hidden local of a pulled recursive generator holds a
  private frame stack:**
  - an inline segment, sized to a few levels, plus chunks;
  - the delegation chain's frames live there;
  - callees of a step that suspend mid-step still bump from the
    *current* `sp`, as in r2's convention, so on the generator's stack;
  - parent links cross from the generator's stack to the consumer's at
    the root.
- **What makes it work.** With r2's convention, no frame depends on a
  task-global `sp`. Each frame saves its own `sp`, and the trampoline
  never "pops" by assigning `t->sp`. Two stacks per task cost nothing
  extra in the trampoline.
- **The prototype's `frame_pop` breaks it.** It sets `t->sp = f`
  (`ren_single.c:135-136`), and for a frame on another stack that
  silently corrupts the task's stack.
- **Depth.** The delegation chain's depth is the recursion depth, so the
  private stack's limit is the recursion limit (decision 13; section 4).

**A related trap: frames that bump something above themselves.**

- A hidden local bumped dynamically at a `let`, as debug builds need
  (below), sits *above* the consumer's frame. The consumer's later
  callees must start above it.
- With a "frame + size = callee sp" rule (the prototype's `size`
  field), a resumed consumer would put its next callee on top of its own
  generator.
- **Fix:** the frame saves its current `sp` at suspension (r2's header
  field `sp`), never derives it from its size. Swift solves the same
  problem with per-allocation headers.

**Debug builds: the size of a hidden local.**

- In release, a generator's frame size is a compile-time constant in
  the whole-program back half, so it is a real field of the consumer's
  frame struct.
- In debug, each module compiles alone (decision 13), and a generic
  generator passes a dictionary. The consumer's C struct can't embed a
  frame of unknown size.
- Two options:
  - **(a) Bump the generator's frame on the frame stack at the `let`,**
    sized by the callee's `{fn, frame_size}` descriptor, and pop it at
    the `let`'s scope end. This is what Swift does for every async call
    (r2 §1).
  - **(b) Export frame structs in module interfaces.** This makes a
    callee's internal change, a new local live across a yield,
    recompile all its consumers. That breaks "each module compiles
    alone and incrementally".
- **Recommend (a) for debug, and the embedded field for release.** Both
  are LIFO: `let` scopes nest, and generators close in reverse order.

---

## 4. Sizing

- **Static maximum depth for the inline segment (release).**
  - Release has the whole program. For each task body it can compute
    the deepest chain of suspending frames: the sum of frame sizes along
    the longest call-graph path through suspending functions.
  - If that path is acyclic, a task allocated with that segment
    *never* overflows. Bump checks can then go too (r2 §8).
  - The prototype does this by hand: "sized by release to the deepest
    frame chain it can see" (`ren_single.c:7-10`).
- **Cap the inline segment.**
  - A deep but rare path, say an error-reporting chain 30 frames deep,
    shouldn't make every parked task carry 2 KB.
  - Recommend `min(static max, 256 B)` inline. A parked task stays
    around 128 to 384 B, against Swift's 1.4 KB.
  - Deeper chains take a chunk.
- **Recursion through a suspending function** makes the path cyclic, so
  the bound is unknown, and chunks are mandatory. That covers recursive
  `yield from` on its private stack, too.
- **Chunks: keep one spare.**
  - The prototype frees an overflow chunk as soon as its first frame
    pops (`ren_single.c:135-145`).
  - Measured here (r2 §6, `THRASH=1 ./fp_clang 1 5000000 1`): a call
    just past the inline segment, made in a loop, costs **23.2 ns
    against 5.4 ns**, because it mallocs and frees 4 KiB every
    iteration.
  - Ren's per-thread free lists would cut that, but not to zero.
  - **Fix: Swift's rule.** Keep the most recent empty chunk on the
    task. Free spares only when a larger chunk is needed
    (`StackAllocator.h:285-291`), when the task ends, or when the task
    parks with a spare. That last one keeps idle tasks small, which
    Swift doesn't bother with.
- **Chunk size.**
  - Swift uses 1 KiB slabs and no geometric growth.
  - Ren's 4 KiB with "bigger if one frame needs it" (`ren_single.c:113-123`)
    is fine.
  - Recommend geometric growth, doubling up to 64 KiB, only for chunks
    of the recursive stacks. Deep recursion otherwise costs a malloc
    every 4 KiB.
- **Depth limits.**
  - Decision 13: "A recursive `yield from` has the depth limit of a
    recursive call, pushed or pulled."
  - The pushed form runs on the native C stack. The pulled form runs on
    a frame stack. Their per-level sizes differ: a C frame vs a Ren
    frame of header plus live locals. The limits can't be equal in
    depth *and* in bytes.
  - **Recommend:** define the limit as one number of *bytes*, the same
    for both stacks: the worker thread's native stack size, 8 MiB (r2
    §7). Overrunning either is the same panic, "stack overflow in
    <fn>".
  - With a common byte limit, the pushed and pulled forms differ in
    depth by at most the ratio of frame sizes. That's a factor of 1 to
    3, not unbounded.
  - Strict equality would need a depth counter in every recursive call,
    pushed or pulled. That costs a load, an add and a compare a level,
    and isn't worth it.
- **The `size` field.** r2 replaces it with a saved `sp`. Nothing in
  the allocator needs a frame's size: the pop is implicit, the callee's
  `sp` is a C local, and a chunk is retired by its first frame's flag.

---

## What this means for Ren

### Point 2 (per-task LIFO frame stack)

- **Confirmed for everything but one case.** Swift ships this allocator,
  traps on non-LIFO frees, and has never needed more than
  `dealloc_through` (StackAllocator.h:401-424). Ren's generator rule
  "`yield` only in the generator's own body" is what makes pulled
  generators LIFO-safe, `zip` included (section 3's table).
- **Wrong as worded: "runs on one frame stack the consumer owns"**
  (decision 12) for a pulled recursive `yield from`. **Fix:** "a pulled
  recursive generator owns its own frame stack, held by its hidden
  local". Otherwise two zipped tree walkers interleave their delegation
  chains on one stack.
- **Wrong in the prototype: `frame_pop` assigns `t->sp = f`.** That
  presumes one stack and frames that own everything above them. **Fix:**
  r2's convention. `sp` is a C local and saved per frame at suspension,
  so several stacks and dynamically bumped hidden locals just work.
- **Missing: chunk hysteresis.** Measured 4.3× slower at the boundary.
  **Fix:** keep one spare chunk a task, as Swift does.
- **Missing: hidden locals in debug builds.** **Fix:** bump them at the
  `let`, sized by a `{fn, frame_size}` descriptor. Release embeds them.
- **Confirmed: memory.** 128 B parked against Swift's measured
  1,426 B. Capping the inline segment at about 256 B keeps Ren below
  400 B even for tasks with deep possible chains.

### Candidate open decisions

1. **Inline-segment cap** (recommend 256 B).
   - Tradeoff: idle memory against a chunk allocation on deep paths. At
     100k idle connections, 256 B extra is 25 MB.
2. **Depth limit in bytes, shared by the native stack and frame stacks**
   (recommend 8 MiB each, one "stack overflow" panic).
   - Tradeoff: the pushed and pulled lowerings differ in maximum depth
     by a small factor, not exactly. The alternative is a depth counter
     on every recursive call.
3. **Release: embedded hidden locals or bumped ones.**
   - Recommend embedding when the size is static. It saves a bump and
     an `sp` save a generator, and makes the consumer's frame size
     exact for the static depth bound.
   - Debug always bumps.

### Experiments worth running

- **Two recursive tree walkers under `zip`, in C,** on one shared frame
  stack and then on per-generator stacks.
  - Prediction: the shared version corrupts, which the guard checks
    catch at the first out-of-order pop. Per-generator stacks pass, at
    under 5% overhead against one walker run twice.
- **Spare-chunk hysteresis in `ren_single.c`.**
  - Prediction: the boundary case drops from 23 ns to within 1 ns of
    the in-segment 5.4 ns.
  - `pingpong_nested`, the `park` bytes a task, and the depth-1000
    `--check` are unchanged.
- **Static depth sizing on a realistic program** (flottning's
  serve → request → recv chain, with handler ops not inlined).
  - Prediction: the maximum is 150 to 300 B. A 256-B cap covers it, so
    a parked connection task stays at about 250 to 400 B.

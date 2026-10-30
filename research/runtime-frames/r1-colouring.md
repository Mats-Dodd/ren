# R1: colouring by inference

Track R1 of the runtime-frames research. It tests proposal point 1:
**plain or suspending, decided per specialization.** Which systems decide
"this function can suspend" by analysis rather than by a keyword, how
they decide it, what it costs on paths that don't suspend, and what broke.
Then it walks every place in Ren where "can suspend" isn't settled after
specialization, and proposes a rule for each.

The short answer: the rule is right for release, and Koka already runs
it (specialize first, then colour). But the proposal mixes two different
things, and the mix matters for `sim` and the journal. **A scheduling
point** is where the runtime may act: switch tasks, deliver a cancel,
count the budget, draw from the tape. **A colour** is a calling
convention: whether a call may return PENDING. The points have to be
defined by meaning and be the same in every build and every runtime.
Colours are only cost, and may over-approximate the points. Once those
are split, debug builds can colour coarsely (by the row) without
changing anything a program, a journal or a seed can see.

Sources, read at these commits unless marked otherwise:

- Zig `cb6f0c2` (2026-10-26), `/tmp/ren-refs/zig-cb` (std only), and
  `738d2be` (`/tmp/ren-refs/zig`), plus the web, marked
- Koka `198fc3b`, `/tmp/ren-refs/koka`
- Effekt `5ce8d12` (2026-10-26), `/tmp/ren-refs/effekt`
- OxCaml `629921bf` (2026-10-26), `/tmp/ren-refs/oxcaml`
- Go `6c49ac3`, `/tmp/ren-refs/go` (runtime only, no `cmd/`)
- Lean 4 `24a851d` (2026-10-27), `/tmp/ren-refs/lean4`
- Roc `7de4d5c` (the Zig rewrite's design.md) and `roc-rust` `d73ea10`
- swift-evolution `4e7c32c`, Hylo `6889158`, Inko `45af188`, ponyc `f032e36`
- Ren at `0be57bb`, plus the switch prototype
  (`experiments/runtime-p2/switch`)

Measured here: Apple M4 Max, shared with other agents, load average 4.7
to 6.1 during the runs. Code is in the scratchpad
(`.../scratchpad/r1-colouring/`).

---

## 1. Zig: inferred colours, removed

### What it was (from memory and the web)

Stage 1 Zig had no `async` function keyword. A function was async if its
body had a `suspend` or called an async function. That was inferred over
the call graph, which is exactly proposal point 1. Its frame was a
first-class type, `@Frame(f)`, sized by `@frameSize`. A caller could
write `async f()` to get a frame and `await` it; a plain call to an async
function from an async function just suspended with it. Three rules
leaked through:

- **Function pointers.** A pointer to an async function needed
  `callconv(.Async)`, and the call needed `@asyncCall` with a frame
  buffer you sized yourself. The inference stops at a pointer.
- **Recursion.** `@Frame(f)` for a recursive `f` has no finite size, so a
  recursive async function had to heap-allocate its own child frames.
- **Separate analysis.** `@frameSize` is only known once the whole call
  graph below is analysed.

### Why it went (web)

- The self-hosted compiler never got it. The 0.11 release shipped without
  async because the work wasn't finished
  (https://ziglang.org/news/0.11.0-postponed-again/).
- An April 2024 langref commit listed the unsolved problems: LLVM's weak
  optimization of coroutines, third-party debugger support, the
  cancellation problem, and **function pointers that stop the stack size
  from being known** (search results summarising commit `c78f996`; I
  couldn't load the commit itself).
- #6025 ("re-introduce async/await") was closed in July 2025: "Zig will
  not have async/await keywords. Stackless coroutines may return to Zig,
  but if they do, it will be in a different form."
  (https://github.com/ziglang/zig/issues/6025). PR #24362 removed
  `async`, `await` and `@frameSize`.
- The replacement proposal, #23446, keeps inference ("A function is async
  if it has any suspension point", a suspension point being
  `@asyncSuspend` or a call to another async function) but needs
  **restricted function pointers**, #23367, so that every indirect call
  has a closed, listed set of callees. #23367 opens: "Indirect calls
  through function pointers are a major blocker for both #1006 and
  #6025" (https://github.com/ziglang/zig/issues/23367). How it handles
  recursion is open in the thread.

**That's Ren's decision 4.** Zig wants the closed world Ren already has.
What killed inferred colours in Zig was the open world of function
pointers, plus frame sizes needing the whole graph, plus debugging.
Ren's closed world removes the first, Ren's per-task bump stack
(decision 12) removes the need for exact frame sizes, and debugging is
still open (§9.3).

### What Zig does now: stackful fibers behind a vtable

- `Io` is a vtable (`lib/std/Io.zig:25-26`). `Evented` is `Uring` on
  Linux, `Kqueue` on the BSDs and `Dispatch` on Apple, and only where
  `fiber.supported`, which is aarch64, riscv64 and x86_64
  (`Io.zig:30-36`, `Io/fiber.zig:1-4`).
- **The fibers are stackful.** `fiber.zig` saves sp, fp and pc and
  swaps them in inline asm (`Io/fiber.zig:7-40`). Each fiber reserves
  `min_stack_size = 60 * 1024 * 1024`, 60 MiB of address space
  (`Io/Uring.zig:256`, the same in `Io/Dispatch.zig:196`).
- **`async` may run inline; `concurrent` must not**
  (`Io.zig:2554-2565, 2600-2606`). `concurrent` can fail with
  `error.ConcurrencyUnavailable`. The doc comment says what `async` is
  for: "allows, for example, stackful single-threaded blocking I/O".
- **The colour moved to a parameter.** Any function that does I/O takes
  `io: Io`. Readers on Hacker News pointed out that this is colouring
  every function that touches I/O, not removing colour (web, via the
  LWN coverage, https://lwn.net/Articles/1046084). Ren's `uses` row is
  the same thing, inferred and checked: the row is Ren's `io`.

---

## 2. Koka: colour by the effect type, after specialization

Koka is the closest prior art to the proposal. It compiles to C,
decides per function whether to transform it, and does so **after**
specialization.

### What decides

- `isMonEffect` (`src/Core/Core.hs:856-863`): an effect row needs the
  monadic transform if **its tail is open** (a row variable), or if any
  label in it has an operation that may resume more than once or not at
  all (`ResumeMany`, a `ctl` operation). A closed row of `fun` and `val`
  operations is not monadic: those are tail-resumptive, so the handler
  runs in place, with no yield.
- `isMonType` (`Core.hs:846-854`) applies that to a function type.
  `Monadic.hs:132` transforms an application only if the callee's type
  is monadic. `isNeverMon` (`Monadic.hs:313-320`) skips an `open` whose
  source row is total.
- **The order:** `specialize` runs at `src/Compile/Optimize.hs:93` and
  `monTransform` at `Optimize.hs:114`. So a higher-order function that
  was specialized for a known, total argument has a closed row and is
  left plain. One that wasn't is transformed.

So Koka colours by **declaration**: whether an operation is `fun` or
`ctl` is written on the effect, not chosen by the handler. Ren has no
such marker. A `Clock` dependency is answered by a world handler that
suspends and by a frozen fake that doesn't, so Ren has to colour by the
handler, which only a specialization knows.

### What it costs on the path that doesn't yield: one branch

The C backend uses yield bubbling. A yielding operation sets
`ctx->yielding` and returns. Each monadic call is followed by a check:

```c
static inline bool kk_yieldingx(const kk_context_t* ctx) {
  return (ctx->yielding != KK_YIELD_NONE); }
#define kk_yielding(ctx)   kk_unlikely(kk_yieldingx(ctx))
```

(`kklib/include/kklib.h:472-475`). In Koka source it's `yield-bind`:
`if yielding() then yield-extend(next) else next(x)`
(`lib/std/core/hnd.kk:280-293`). `yield-extend` is `noinline`
(`hnd.kk:288`), so the continuation closure is built only on the path
that yields. **On the path that doesn't, the cost is one load and one
predicted branch,** and no frame exists.

That's the difference from proposal point 2. Koka allocates the
continuation **lazily**, on the heap, only when something yields. The
proposal allocates the frame **eagerly**, on the task's frame stack, at
every call to a suspending function. Eager keeps frames LIFO and
resumes the innermost frame directly. Lazy keeps the non-yielding path
free but builds a heap closure per frame on every real suspension, and
resumes by calling a composed continuation (`kcompose`,
`lib/std/core/inline/hnd.c:270-306`). For Ren, where most calls to a
world handler do suspend, eager is right. For debug calls through
evidence that usually don't suspend, Koka's "a status, no frame" is the
cheap convention (§9.3 measures it).

### Polymorphic code

Because an open tail counts as monadic, every unspecialized
higher-order function is transformed: `map(xs, ^f : a -> e b) : e
list<b>` (`lib/std/core/list.kk:217`) pays the branch after each call
of `f`, whatever `f` is. Specialization (`Optimize.hs:88-93`) is what
removes it. **This rule would be a disaster for Ren as it stands:**
every Ren function type has an open tail. `ren core --types` gives
`abs : fn(Int) -> Int ! ..e uses ..d` and `gcd : fn(Int, Int) -> Int !
..e uses ..d` (examples/blocks.ren), so Koka's test would colour every
Ren function. Ren's debug rule has to look at whether the tail variable
reaches a call, not at whether it exists (§9.3).

---

## 3. Effekt: everything on its own stack; colour only on externs

Effekt has effect types and capture sets, but its native backend doesn't
use them to make code plain.

- **LLVM:** every non-tail call pushes the free variables and a return
  address onto Effekt's own segmented stack (`PushFrame`,
  `effekt/shared/src/main/scala/effekt/generator/llvm/Transformer.scala:284-303`).
  The stack is bump-allocated with a limit check that grows it by copy
  (`libraries/llvm/rts.ll:292-337`). So every function is "suspending",
  and the price is paid everywhere. It's the eager-frame design of
  proposal point 2, applied without colouring.
- **JS:** whole-program CPS, with a local optimisation that turns a
  continuation used once into direct assignments (`canBeDirect`,
  `generator/js/TransformerCps.scala:562-590`).
- **The only colour is on foreign functions.** An extern whose capture
  set contains the builtin `async` capability gets the stack or
  continuation; any other extern is inlined as a plain call
  (`cps/Transformer.scala:39`, `machine/Transformer.scala:69`,
  `TransformerCps.scala:502-522`). In source it's written `at async`:
  `extern def yield() at async: Unit` (`libraries/common/io.effekt:19`).
  So Effekt marks the *foreign* boundary explicitly and leaves Effekt
  code uncoloured. That's proposal point 4 (`foreign fn` against
  `blocking foreign fn`) exactly.

---

## 4. OxCaml: stackful, but it added a "can yield" axis anyway

OCaml 5 effects run on stackful fibers, so there's no colouring for
speed. OxCaml still found it needed a colour, for soundness:

- **A `yielding` mode** (`jane/doc/extensions/_05-modes/intro.md:253-274`):
  "a future axis that tracks whether a function is permitted to perform
  effects that will be handled in its parent stack". **Global values
  default to `unyielding`, local values to `yielding`.** So a closure
  that can be stored can't yield by default, and one that only travels
  down the stack can. That's Ren's split exactly: a block (decision 1)
  travels down and may suspend; anything stored (a C function pointer,
  a handler description) is code that mustn't.
- **The capability is a parameter.** `Effect.Safe.perform :
  Handler.t @ local -> 'a t -> 'a`, and a `Handler.t @ local` "is proof
  that the current function is running within an effect handler"
  (`stdlib/effect.mli:55-67`). The body passed to `match_with` must be
  `@ unyielding` (`effect.mli:128-138`). That's Zig's `io` again, as a
  mode.
- **Preemption, as an effect.** `Effect.Deep.Preemptible` handlers get
  ticks from the runtime and can perform a `Preemption` effect
  (`effect.mli:177-200`, the `Preemption` constructor at `effect.mli:42-45`).
  Ren refuses preemption (SYNTHESIS §1), and OxCaml shows what it takes:
  signal-safe tick handlers, and TLS split per fiber.
- Every fiber has its own `local_arenas` (`runtime/fiber.c:352`), which
  is why stack-allocated values and yielding have to be tracked
  together.

From memory, not checked here: in OCaml 5 an effect can't be performed
across a C frame; a callback from C runs under a fresh handler, and an
unhandled effect there raises `Effect.Unhandled`. Stackful systems have
Ren's C-boundary rule too.

---

## 5. Go: no colour, paid on every function

- A goroutine starts with `stackMin = 2048` bytes (`runtime/stack.go:78`)
  and grows by copying the whole stack (`copystack`, `stack.go:929`;
  `newstack`, `stack.go:1055`), with every pointer into it adjusted.
- Every function that isn't `nosplit` checks the stack bound in its
  prologue (from memory: the clone has no `cmd/`). That's Go's colour
  tax: a compare and a branch on every call, which Koka pays only after
  monadic calls and Ren would pay only at suspending ones.
- **The benefit is total:** function pointers, interfaces, recursion and
  C-free callbacks all suspend with no rule. The switch prototype
  measured what it costs Go at the other end: 388 ns a round trip
  against Ren's 16 to 18 (PLAN.md, cloud), and 2 KiB or more per task.

---

## 6. Lean 4: no suspension in C at all

Lean doesn't suspend compiled code. It blocks threads and compensates.

- `Task.get` on an unfinished task blocks the OS thread. If the caller is
  a pool worker, the manager first raises `m_max_std_workers` and starts
  another worker, so the pool doesn't starve (`src/runtime/object.cpp:1029-1050`).
  That's Loom's compensation (R3).
- A task with priority above `LEAN_MAX_PRIO` gets a dedicated thread
  (`object.cpp:801-804`).
- **The async library colours by type, by hand.** `BaseAsync α :=
  BaseIO (MaybeTask α)` (`src/Std/Async/Basic.lean:387`), where
  `MaybeTask` is `pure α` or `ofTask (Task α)` (`Basic.lean:321-330`).
  The `pure` case is the proposal's DONE fast path; `ofTask` is
  PENDING, and binding on it allocates a heap task closure
  (`IO.bindTask`, `src/Init/System/IO.lean:357`).

**The lesson:** Lean put the DONE/PENDING split in the type and built
it as a library monad. Everything effectful is in the monad, so Lean
colours by the type, the way Ren's decision 12 colours by the row.

---

## 7. Roc: effectfulness solved after dispatch, but never suspension

Roc's new compiler infers whether a function is effectful (its `!`), and
its design doc spells out the algorithm Ren needs:

- An effectful call is a direct call to an effectful function, a call
  through a function value whose type is effectful, or "a static-dispatch
  call whose selected implementation is checked effectful"
  (`roc/design.md:1168-1172`).
- "It must not be represented by one early boolean that is finalized
  before static dispatch has resolved." Slots watch dispatch sites;
  "strongly connected recursive groups may be condensed, marked
  effectful if any member is effectful, and then propagated to callers"
  (`design.md:1181-1222`).

That's the least fixed point over SCCs that §9.2 proposes. **But in Roc
it never decides a calling convention.** A hosted effect is a plain C
call to `roc_fx_*`, provided by the platform (`roc-rust/crates/compiler/gen_llvm/src/llvm/build.rs:6603-6606`).
If the platform wants concurrency, it runs Roc on its own threads or
coroutines. Roc compiled code never suspends.

---

## 8. Explicit colours: Swift, Kotlin, Rust; and Hylo, Inko, Pony

- **Swift.** `async` is written. A synchronous function converts
  implicitly to the async function type (`swift-evolution/proposals/0296-async-await.md:342`),
  which is the adapter of option (a) below. SE-0296 floated `reasync`
  and doubted it (`0296-async-await.md:611-660`). SE-0533's `@Reasync`
  macro was **rejected**; the Language Steering Group wrote that any
  `reasync` "would need to emit two separate machine-level functions,
  since synchronous and async functions cannot share a calling
  convention" (`0533-reasync-macros.md:738-757, 826-836`). That's the
  answer for `map(xs, f)`: polymorphism over colour costs two copies, or
  one copy in the slow convention.
- **Kotlin** (memory). `suspend` is written. Each suspend function is
  CPS-transformed into a state machine taking a `Continuation`, and
  returns `COROUTINE_SUSPENDED` to bubble, which is Koka's yield bubbling
  with an eager, heap continuation object per call. `inline` higher-order
  functions are how `map` with a suspending lambda works: the lambda is
  inlined into a suspending caller, which is Ren's release
  specialization.
- **Rust** (memory). `async` is written. Futures are sized state
  machines nested by value, and polled from the root on every wake. The
  "keyword generics" effort to be generic over `async` hasn't shipped.
- **Hylo.** Stackful: `spawn_` and `await` over Boost.Context, and
  `future.await()` may come back on another thread
  (`Examples/concurrent_greeting.hylo:10-18`). No colour.
- **Inko.** Stackful processes with 512 KiB stacks and a guard page
  (`rt/src/config.rs:34`, `rt/src/stack.rs:22-66`). No colour.
- **Pony.** No suspension at all: a behaviour runs to completion, and an
  actor handles up to `PONY_SCHED_BATCH` (100) messages per turn
  (`src/libponyrt/actor/actor.h:18`). Waiting is a message.

### What every system's colour broke on

| | decided by | function pointers | recursion | polymorphic code | debug |
|---|---|---|---|---|---|
| Zig stage 1 | inference over calls | `callconv(.Async)` + `@asyncCall` | heap frames by hand | n/a | a stated reason it died |
| Zig #23446 | inference | needs restricted pointers (#23367) | open | n/a | open |
| Koka | effect type, after specialize | via type (open tail is monadic) | via type | open tail is monadic, so every unspecialized HOF | n/a |
| Effekt | nothing: all code on its own stack | free | free | free | n/a |
| Swift, Kotlin, Rust | keyword | in the type | free | two copies, or the slow one | async backtraces needed debugger work (memory) |
| Go, OCaml, Hylo, Inko | nothing: stackful | free | free | free | ordinary stacks |
| Lean, Roc | no suspension in compiled code | n/a | n/a | n/a | n/a |

---

## 9. Ren: where "can suspend" isn't settled after specialization

### 9.0 First, split the two things the proposal mixes

**A scheduling point** is where the runtime may act. Under `sim` it draws
from the tape, so it's recorded in the journal and decides what a seed
means. It's where cancellation lands, where the counted budget counts
(SYNTHESIS §2.8), and what decision 10's `Mem.snapshot` rule is about.
**A colour** is a calling convention: whether a call may return PENDING
and so needs a frame.

The interpreter already defines the points by meaning, and finer than
the row. compiler.md:4505-4507: "A scheduling point is each place a task
can wait, and **each call of an operation of a shared, exclusive
instance** (one a spawned task can reach, whose handler keeps state),
before the call". compiler.md:5345-5350: `Sched.point` runs before
`Sched.holding`, and "Under `single`, `point` does nothing". Sharing is
marked at run time: `s.spawn` "marks shared every instance in its
block's evidence ... for good" (compiler.md:4700-4704).

So the rule Ren needs is:

> **Scheduling points are defined by meaning, the same in every build:**
> a world call, an `Async` wait (`until`, `yield`, `tick`, a scope's end,
> room in a scope or a bounded queue), `release`, and a call of an
> operation of an instance that is shared and exclusive. Sharing is the
> run-time mark, made at `spawn`. **A colour is a static
> over-approximation:** a function is suspending if it can reach a
> point. The runtime acts only at points. Code compiled in the
> suspending convention but standing at no point never sees the
> runtime.

Everything below follows from that.

### 9.1 The proposal's instance rule is wrong as written

Point 1 says "taking a handler whose operations never suspend is a
short lock, never a suspension". That's true for cost, and false for
`sim`:

- Under `sim`, every call of an operation of a shared, exclusive instance
  is a point (compiler.md:4505). Without it, `sim` can't put task B's
  `get` between task A's `put(1)` and `put(2)`, which a multi-core run
  can do. That's the lost update split over two operations that
  testing.md's services row says `sim` finds (testing.md:594), and
  decision 11's "a test on one thread can reach every behaviour".
- Under `per_core` and `work_stealing`, a shared instance can be held
  by a task on another core. Decision 10 says waiters "queue for the
  instance as tasks: a thread never blocks while its task is parked".
  Queueing as a task means suspending.
- Under `lockfree` handlers, "under `sim` every access is a scheduling
  point" (foundations.md:686-692).

**Fix:** a call of an operation of an instance that **may be shared** and
is exclusive is suspending-coloured. "May be shared" is static and
whole-program in release: the instance is installed outside some spawn
whose block's evidence reaches it. Whether it **is** shared is still the
run-time mark, checked at the point, so debug, release and the
interpreter make the same points. Non-exclusive handlers (no `var`, no
opaque `let`), and instances no spawn reaches, stay plain. Under
`single`, the point is a flag test that does nothing (compiler.md:5349),
and the take can't park unless some operation of that instance holds it
across a suspension.

**Don't let the colour depend on the runtime.** Under `single` alone it
could be finer: a take parks only if some operation of the instance can
suspend holding it. But then a `sim` test and a `single` production run
compile different code, so the test doesn't exercise the code that
ships. Colour shared exclusive takes the same under every runtime. The
cost under `single` is a frame on a path that never parks, about 0.35
ns a call at -O2 (§9.3).

### 9.2 Recursion

- **Rule:** colour is the least fixed point over the specialized call
  graph's strongly connected components. A component is suspending if
  any member reaches a point; otherwise all of it is plain. That's
  Roc's algorithm (`roc/design.md:1215-1222`) on specializations, not
  on source functions. It's finite because unbounded polymorphic
  recursion is already an error (decision 4).
- **A function whose suspension depends only on itself** (`f` calls `f`
  and nothing else that suspends) is plain under the least fixed point.
  That's correct: no execution of it reaches a point.
- **Depth differs by colour.** Plain recursion uses the worker thread's
  native stack (host-sized, `ren_thread_init(core, worker, stack)`).
  Suspending recursion pushes frames in 4 KiB chunks (PLAN.md). If debug
  colours a function suspending and release colours it plain, the depth
  at which it overflows differs. Decision 13 already refused that for
  generators: "a recursive `yield from` has the depth limit of a
  recursive call, pushed or pulled". **Rule:** a stack overflow is a
  panic in both conventions, and its depth isn't part of meaning. Or,
  to match decision 13, give the frame stack the same byte limit as the
  native stack. Cheap: the bump allocator already checks a limit.

### 9.3 Debug builds: calls through evidence

Debug never specializes (decision 13). Handlers are evidence (a
function-record pointer), blocks are code and frame pointers, generics
pass dictionaries. A call through evidence can't know whether the
handler at the other end suspends.

**How much is at stake.** Over Ren's example programs and the services
and 10d benches (`ren core --types`, 451 functions, scripts `rows.py`
and `calls.py`, measured here):

- 123 of 451 functions (27%) have a concrete dependency in their
  inferred row; 4 more only take blocks.
- Of about 1,190 static call sites, 290 are operation calls through
  evidence and 94 are calls to functions with a dependency: **about a
  third** would use the suspending convention under option (a). The
  other 489 were calls into the prelude and std (`Array.push`,
  `Str.bytes`), almost all plain.

That's static. Dynamically, hot loops are mostly plain code (decision
10 assumes it), so the dynamic share should be lower. These programs
are effect demos, so they over-represent effectful code.

**The per-call cost** (`conv.c`, 10^8 calls through a function pointer,
measured here):

| convention | tcc | clang -O0 | clang -O2 |
|---|---|---|---|
| plain indirect call | 2.5 ns | 1.9-2.0 | 1.15 |
| status return, result through a pointer, no frame | 4.4 | 3.4-3.5 | 1.15 |
| push a frame, call, check status, pop | 8.6 | 5.8 | 1.5 |

(With `push` as an inline function, tcc doesn't inline it and the last
row is 11.6 ns. The emitter must write frame pushes as expressions, not
calls.)

**The options:**

- **(a) Colour by the row in debug.** One debug rule, all of it local to
  the module:
  - A function is suspending if its inferred row has a concrete
    dependency, or it calls a block or function parameter whose row is
    open. **Not "if its row is open"**: every Ren function type is open
    (`gcd : fn(Int, Int) -> Int ! ..e uses ..d`), so Koka's test would
    colour all of them.
  - Every evidence entry uses the suspending convention. A handler
    whose operation is plain gets an entry that runs it and returns
    DONE: Swift's implicit sync-to-async conversion, as an adapter.
  - **The callee pushes its own frame.** Through evidence the caller
    doesn't know the callee's frame size. The prototype's `CALL` macro,
    which has the caller push a frame of known size
    (`experiments/runtime-p2/switch/c/ren_single.c:321-330`), is the
    release convention. In debug the adapter pushes nothing, so a call
    to a plain handler costs the status row: **+1.9 ns in tcc**. A call
    to a function with a dependency pushes its frame: **+6.1 ns in
    tcc**.
  - A plain caller may call a suspending-convention callee when the
    block it passes has an empty, closed row: `map(xs, fn(x) => x + 1)`
    can't return PENDING, so the caller asserts DONE. That keeps
    decision 10's rule ("no code reached from a call with an empty row
    runs a scheduling point") true by typing, in both builds.
- **(b) Two entry points per function.** That's the Swift LSG's
  `reasync` answer: two machine functions. In debug it doubles the C
  that tcc compiles for about 27% of functions, and it still needs a
  run-time test of the evidence to choose the entry. Decision 13 spends
  everything on debug compile speed. Refuse it.
- **(c) Stackful tasks in debug.** Debug gives each task a real C stack,
  and every function is plain C. Suspension is a stack switch in the
  core. lldb shows ordinary backtraces, which is the thing Zig listed as
  unsolved for stackless frames. A naive aarch64 switch measured here is
  18 ns a round trip (`fiber_br.c`; 33 ns with `ret`, which confuses
  the return predictor). The prototype's stackless round trip is 15.8
  ns, and 31.6 nested, on this machine (`build/ren_c --bench pingpong`
  and `pingpong_nested`, measured here). So speed is a wash. The costs:
  the core holds two kinds of task; debug tasks hold 8 to 64 KiB of
  committed stack where release holds 128 B; hosted debug needs JSPI
  (R5); and overflow depth differs again.

**Recommendation: (a).** It's one rule, it's local, it costs about 2 ns
on a third of debug calls, and debug code is already 1 to 1.8× clang
-O0 (decision 13). Run (c) as an experiment only if state-machine
backtraces turn out to hurt in lldb (see Experiments).

**Does (a) change anything observable?** Not if 9.0 holds:

- **The journal and `sim`.** Points are the same set in both builds:
  world calls, `Async` waits, `release`, and takes of instances whose
  run-time shared mark is set. A plain fake `Clock` (no `var`) is called
  through a suspending-convention adapter in debug and inlined in
  release, and in neither is it a point. The tape draws at the same
  places, so a seed means the same in both, and a debug journal replays
  under `--release`.
- **The budget.** SYNTHESIS §2.8 counts "scheduling points that didn't
  wait", replayed under `single` with no journal entry. That's only
  sound if both builds count the same set. **Fix the wording:** the
  budget counts points (as 9.0 defines them), never suspending-convention
  calls. "Count only outermost dependency calls" (§2.8) is ambiguous:
  in release an inlined plain dependency call isn't a call at all.
  Count points, and yield at the next point where the task holds no
  instance.
- **Cancellation** lands only at points, so the same in both.
- **`Mem.snapshot`'s rule** is about rows, so it's the same in both.
- **What does differ:** overflow depth (9.2) and memory per parked task.
  Neither is meaning.

**So decision 12's sentence needs rewording,** not reversing. "Only a
function whose `uses` reaches a dependency can suspend" is the debug
colour. Release is finer, per specialization. Both are colours. What
"can suspend" means to the program is the point set.

### 9.4 `map(xs, f)`: one copy or two in release?

**Two, and they cost nothing extra.** Decision 1 already specializes a
higher-order function per block literal, and Ren's colour is computed
per specialization, so `map` with a pure block and `map` with a block
that calls `Net` are already different copies. One is plain C, the
other a state machine. That's the Swift LSG's "two machine functions",
paid by specialization Ren does anyway.

Two places that need care:

- **Sharing per layout** (decision 4). A specialization shared across
  types per layout must also be keyed by colour, wherever it takes a
  block or reaches a handler. Identical-function folding does it by
  itself, since the emitted C differs.
- **Release dispatch that doesn't specialize:** the more-than-four
  table call, and a call the size budget boxed. A table's arms share
  one convention. If any arm suspends, the site is suspending and the
  plain arms get debug's adapter. That's debug's problem at small
  scale, and `--explain-dispatch` should say which arms were adapted.

### 9.5 Instances held across a suspension

"Taking an instance that some other task may hold across a suspension"
is a scheduling point. Under 9.1 it's subsumed: may-be-shared and
exclusive is the colour, and the run-time mark is the point. Under
`single`, should a take of an instance whose operations never suspend
holding it be plain? It could be, but 9.1 says don't: then `sim` and
`single` compile different code.

A handler whose operation uses `Async.until` and no world call is
suspending by its row (`until` is `Async`'s, so `Async` is in the row),
in both builds. No special case.

### 9.6 C function pointers, `trust`, foreign callbacks

- **A C function pointer is always plain.** C can't return PENDING.
  This is the one indirect call left (decision 4), and Zig's experience
  says don't try to infer through it.
- **A Ren function passed to C as a callback must have a closed, empty
  row,** checked by type in both builds. Not "plain after
  specialization", which a debug build can't know and which would make
  a program compile in release and fail in debug. That's OxCaml's
  "global is unyielding" default. A callback that needs the world posts
  a completion to a runtime queue, as decision 11 already says.
- **`foreign fn`** is plain, and **`blocking foreign fn`** is a world
  call, so suspending (point 4). That's Effekt's `at async` on externs
  (`io.effekt:19`), with Ren's split.
- **A driver** uses no world dependency, so its code is plain by the
  same rules, in both builds: it calls `foreign fn`s and the core's
  verbs. That confirms point 3's "a driver compiles to plain code
  automatically", as long as `Async.submit` is the core's verb and not a
  dependency the driver's row names.

### 9.7 Separate compilation and the release cache

Release colours are whole-program facts per specialization. A
specialization's colour depends on every callee's, so it belongs in the
cache key of release's back half (decision 13). An edit that makes a
deep helper call `Clock` recolours every caller up the chain and
recompiles them. That's the same cascade inlining already causes, and it
never touches the front half or debug.

---

## What this means for Ren

### Point 1: plain or suspending, per specialization

- **Confirmed for release.** Koka does it in this order: specialize at
  `Optimize.hs:93`, colour at `Optimize.hs:114`. Zig's inferred colours
  died of open-world function pointers (#23367), which Ren's decision 4
  removes. Roc's design doc gives the SCC algorithm
  (`design.md:1181-1222`).
- **Wrong:** "taking a handler whose operations never suspend is a short
  lock, never a suspension". Under `sim` a shared exclusive take is a
  point (compiler.md:4505), and under `per_core` decision 10 queues
  waiters as tasks. **Fix:** a call of an operation of a may-be-shared
  exclusive instance, or of a lockfree handler, is suspending-coloured,
  under every runtime (9.1).
- **Missing: the split between points and colours (9.0).** Without it,
  debug and release, or `sim` and `single`, would draw from the tape at
  different places, and a seed or journal from one wouldn't replay in
  the other. **Fix:** define points by meaning, with sharing as the
  run-time mark, and say a colour may over-approximate them. Add one
  line to decision 12: "the runtime acts only at scheduling points;
  which calls use the suspending convention is the build's".
- **Missing: the debug rule.** Recommend (a): row colours, adapters in
  evidence, callee-allocated frames, and "a tail variable counts only
  if it reaches a call" (9.3).
- **Missing: three small rules.** SCC least fixed point (9.2). A Ren
  callback to C needs a closed, empty row (9.6). Colour is part of the
  specialization and cache key (9.4, 9.7).
- **"A test fake compiles to plain code":** true for a fake with no
  `var`. A fake with state that a spawned task reaches (`sim.clock()`,
  or a counter) is a point under every runtime, so it's suspending. Say
  so, or a reader will expect a stateful fake to be free.
- **"Cancellation lands only at scheduling points":** confirmed, given
  9.0. Plain code is never interrupted.

### Point 2: frames (what this track found)

- **Missing: who pushes the frame.** The prototype has the caller push
  a frame of known size (`ren_single.c:321-330`). Through debug evidence
  the size is unknown, so debug needs the callee to push its own frame.
  **Fix:** callee-pushes in debug, either in release (release inlines
  small child frames anyway).
- **Koka's lazy alternative:** build a continuation only when something
  yields (`hnd.kk:288-293`). Cheaper when calls rarely suspend, but heap
  closures and not LIFO. Ren's world calls usually do suspend, so stay
  eager. Keep "status, no frame" for adapters.
- **Fast-path cost at -O2:** a frame push and status check is +0.35 ns
  over a plain call (1.51 against 1.15, measured here). Release should
  still inline small child frames, as decision 12 says.

### Open decisions to raise

1. **Points by meaning, with sharing marked at run time** (9.0).
   Recommend yes. Tradeoff: a load and a test at each may-be-shared take,
   even in release, to keep debug, release and the interpreter on one
   point set.
2. **Is colour runtime-independent?** Recommend yes: `sim` tests the
   code that ships. Tradeoff: under `single`, shared exclusive takes
   carry frames that never park.
3. **Debug convention: (a), (b) or (c).** Recommend (a). Tradeoff: about
   2 to 6 ns on a third of static debug call sites, and state-machine
   backtraces in lldb. (c) fixes backtraces at the cost of a second kind
   of task in the core.
4. **The budget counts points,** not dependency calls (SYNTHESIS §2.8).
   Recommend rewording §2.8.
5. **Overflow depth:** one byte limit for the native and frame stacks,
   or "overflow depth isn't meaning". Recommend the second, with one
   limit as a cheap later option.

### Experiments worth running

- **E-col-1: point-set equality.** Run the services benches (lost update,
  breaker) under `sim` with seeds 1 to 1000 in the interpreter and as
  debug and release native builds once they can, and diff the journals.
  Predicted: identical when points are 9.0's; different the moment
  release drops the shared-mark test for an inlined plain handler.
- **E-col-2: debug convention cost.** Emit option (a) in the native
  slice for `bench/services/*` and the examples. Predicted: +3 to 8% of
  debug run time, since about a third of static calls change and most
  hot loops are plain. Above 15% would argue for (c).
- **E-col-3: lldb on state machines.** Break inside a world call three
  frames deep in a debug build. If `bt` can't show the logical chain,
  write the frame walk as an lldb Python command over the task's frame
  stack (each header has `parent` and `resume`): about 100 lines. If
  that isn't enough, try (c).
- **E-col-4: release recolour cascade.** Make a leaf helper in base-500k
  call `Clock.now`, and count recompiled specializations. Predicted:
  everything on the call path to `main`, which is the inlining cascade
  in size.

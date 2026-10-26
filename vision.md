# What Ren is meant to beat

Ren should be better than what exists today, and "better" should be
something a benchmark can check. These are the three bars. Every stage of
the [roadmap](README.md#roadmap) should move one of them or make one of
them possible, and a design that would break one needs a very good reason.

| Bar | Compared with | Measured by |
|---|---|---|
| Within 2× of Rust | Rust, release builds | the benchmark set below |
| Debug builds faster than Go | `go build` | lines per second, clean and incremental |
| Replay byte for byte | nothing does this today | every example, in CI |

None of them can be measured yet: Ren runs in an interpreter. They're
written down now so the stages that get there are judged by them.

## Principles

The bars say where Ren is going. These say how it gets there. A new
feature should follow from them. If one needs a principle that isn't
here, that's the signal to slow down.

1. **The compiler knows where the world comes in.** Every effect goes
   through a dependency, at run time and at build time. Tests swap them,
   the journal records them, replay answers them, and asserts check them
   ([deps.md](deps.md), [handlers.md](handlers.md),
   [shapes.md](shapes.md)).
2. **Values never change once they're shared.** Mutable state has one
   owner, or lives in a handler, which one task touches at a time
   ([async.md](async.md)).
3. **There's one way to do each thing.** When two features overlap, one
   goes. `over` replaced `outer` and `forwards`, and the top level replaced
   a `const` keyword.
4. **Nothing is lost silently.** A dropped value is written `let _`.
   Errors are checked. Cancellation can't be swallowed, a timeout never
   reports work that finished as timed out, and a second failure goes to
   the trace.
5. **Everything has a limit.** Tasks, queues, retries, stacks and build
   time are all bounded, and running into a limit is an error that says
   where.
6. **Guarantees never depend on optimizations.** A program means the same
   thing in a debug build and a release build. Optimizations make it
   faster, never more correct.
7. **Each fact is computed once and carried.** Types, requirements,
   shapes and top-level values are worked out once, cached by hash, and
   never derived again.
8. **Every IR has a checker.** Each stage of the compiler can be verified
   on its own ([compiler.md](compiler.md)).
9. **Least surprise.** When in doubt, do what a reader would expect, and
   when that isn't possible, make it an error with a help line rather than
   behaviour to learn.

## Within 2× of Rust

Ren's release builds run within twice the time of idiomatic Rust, on the
same machine, for the same program.

- **The benchmarks:**
  - The Perceus set from Koka's papers: `rbtree`, `deriv`, `nqueens`,
    `cfold`. This is where reuse should win.
  - A few from the Benchmarks Game, chosen because they're hard on
    Ren's model: `binary-trees` (allocation), `nbody` (floats in a
    loop), `fannkuch` (arrays mutated in place).
  - One real program: the `just`, or a JSON parser, written the way
    someone would actually write it in each language.
- **Idiomatic on both sides.** The Rust is what a good Rust programmer
  would write. It doesn't use `unsafe` or hand-tuned SIMD. The Ren is
  what the docs teach. A benchmark that needs Ren-specific tricks to
  pass doesn't count.
- **What it measures:** run time and peak memory. Twice Rust's peak
  memory is the limit too.
- **What gets it there:** the memory stage (specialization, lambda
  sets, borrow inference, Perceus, reuse), through the C backend at
  `-O2`.
- **Where it's at risk:** code that mutates shared arrays. TigerBeetle-
  style code lives there. Reuse helps when a value has one owner. When
  it doesn't, Ren copies. `fannkuch` is in the set to keep that honest.

## Debug builds faster than Go

From a clean cache, `ren build` turns source into a runnable binary
faster than `go build` does for a program of the same size. After a
one-line change, it rebuilds faster too.

- **How it's measured:** lines per second on generated programs of 10k,
  100k and 500k lines with the same shape in both languages. Once
  self-hosted, the Ren compiler itself is measured against a Go program
  of similar size. Each one is timed clean, and again after a one-line
  edit in a leaf module and in a widely imported one.
- **What it costs Ren's design:**
  - **Debug builds don't specialize.** They pass dictionaries and
    evidence, as decided in stage 10.0.
  - **Requirements are inferred per module and carried.** Each fact is
    computed once.
  - **Modules compile separately, and a change that doesn't touch a
    module's interface doesn't rebuild what imports it.**
  - **The debug backend can't be clang.** `clang -O0` alone is slower
    than Go's whole compiler on big programs. Debug builds need a C
    compiler built for speed, like tcc, or later a direct backend of
    Ren's own. This is the bar most likely to change the backend plan.
- **What gets it there:** the module system, the naive C backend with a
  fast C compiler, then separate compilation and caching.

## Replay byte for byte

Any program recorded with `ren run --record` replays with `ren replay`
and produces exactly the same output: the same bytes on stdout and
stderr, the same exit code, and the same sequence of calls to the world.
It never touches the disk, the network or a process.

- **How it's measured:** CI records and replays every example and
  compares them byte for byte. Then it changes one line of each and
  checks that the replay stops at the first call that differs.
- **What it costs Ren's design:**
  - **Every effect goes through a dep.** There's no way to reach the
    world except through `Clock`, `Random`, `Fs`, `Os`, `Proc`,
    `Console` and later `Net`. A primitive that skips them breaks this
    bar.
  - **Pure code is deterministic.** Iteration order is defined (Map and
    Set keep insertion order), hashing isn't randomized per run, and
    floats follow IEEE exactly.
  - **With Async, the scheduler's decisions are recorded too.** A
    concurrent program replays exactly, or it doesn't meet the bar.
  - **The journal's format is versioned by name,** so a journal recorded
    on one build replays on the next.
- **What gets it there:** the handlers and journal stage
  ([handlers.md](handlers.md)), then Async's scheduler recording.

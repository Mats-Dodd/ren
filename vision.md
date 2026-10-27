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

The native slice measured the first two for the first time
([bench/native/RESULTS.md](bench/native/RESULTS.md)), on its sequential
subset:

- **Within 2× of Rust:** not yet. Four of the seven programs are
  (deriv, nqueens and cfold at 0.40× to 1.03×, binary-trees at 1.57×),
  and three aren't: rbtree at 2.20×, fannkuch at 2.50× and nbody at
  15.5×: fannkuch and nbody from one cause in the runtime, an array
  store that's a call and copies a whole element, and rbtree from
  allocating 12 nodes an insertion, since Perceus reuses only one level
  of a node, each through the system `malloc`. Peak memory is within 2× on all seven, two at 1.99×.
- **Debug builds faster than Go:** no. A clean build of 500k lines
  takes 57 s against Go's 13, 77% of it clang -O0, and a one-line edit
  rebuilds everything, since there's no build cache yet.
- **Replay byte for byte:** in the interpreter, where the journal
  runs; a native binary has no journal yet.

They were written down before any of it ran, so the stages that get
there are judged by them.

## Principles

The bars say where Ren is going. The principles say how it gets there, and
they're the [README's](README.md#principles), ranked: one list, so two
can't disagree. A new feature should follow from them. If one needs a
principle that isn't there, that's the signal to slow down.

Two more are about how the compiler is built
([compiler.md](compiler.md)):

1. **Each fact is computed once and carried.** Types, requirements,
   shapes and top-level values are worked out once, cached by hash, and
   never derived again.
2. **Every IR has a checker.** Each stage of the compiler can be verified
   on its own.

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
- **What gets it there:** the memory stage (specialization per
  block and handler, borrow inference, Perceus, reuse), through the C backend at
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

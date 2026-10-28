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

- **Within 2× of Rust:** on all seven, after the experiments and
  follow-ups that came after the first measurement. Five run faster
  than Rust (cfold 0.13×, deriv 0.41×, binary-trees 0.59×, rbtree
  0.61×, nqueens 0.69×), fannkuch ties it (1.01×), and nbody is 1.61×,
  since a NaN is checked where it's observed
  ([foundations.md](foundations.md#15-arithmetic)) instead of after
  every operation, which was 2.37×. Peak memory is within 1.5× on all
  seven. The first measurement had three over 2×, nbody at 15.5×.
- **Debug builds faster than Go:** not yet. A clean build of 500k lines
  takes 18 s with tcc against Go's 15 (it was 57 s with clang -O0),
  and the C compiler is 0.2 s of it; a one-line edit rebuilds
  everything, since there's no build cache yet. What's left is Ren's
  front half and writing its C, which run on one core and already need
  a fifth of Go's CPU, so running them per module in parallel, with a
  build cache and a fast link, is what passes.
- **Replay byte for byte:** in the interpreter, where the journal
  runs; a native binary has no journal yet.

They were written down before any of it ran, so the stages that get
there are judged by them.

## What Ren is for

Ren is a systems language for infrastructure: the programs other
programs run on, on an operating system.

| Kind | For example | What it asks of Ren |
|---|---|---|
| A command-line tool | a task runner, a build or migration tool | starts at once, typed errors, the world as dependencies |
| A server | an HTTP API, a proxy, a queue | tasks on every core, injected dependencies, replay from production |
| A storage engine | a key-value store, an LSM tree or a B-tree | buffers changed in place, formats on disk, reads without locks, simulation |
| Not | kernels, drivers, firmware, code with no OS or no allocator | |

One language for three kinds of program, each harder on it than the
last. They're also the order Ren proves itself in: each is built when
the stages it needs have landed, the way someone would write it, and
judged by the bars above.

1. **A command-line tool.** The everyday language: plain loops and
   mutation, blocks, typed errors, `Console`, `Fs` and `Os` as
   dependencies so tests need no setup, a native binary that starts at
   once. It needs strings and the real `Fs`.
2. **A web server.** Structured concurrency without colored functions,
   dependencies injected without a framework, middleware as handlers,
   the runtime chosen in `main`, and the whole server simulated from a
   journal recorded in production. Effect's model at native speed. It
   needs tasks and many cores (11a, 11b), `Net`, HTTP and JSON.
3. **A storage engine: the flagship.** A small key-value store, an LSM
   tree or a B-tree, tested by deterministic simulation as TigerBeetle
   and FoundationDB are: every disk and clock behind a dependency,
   faults injected by handlers, a crash replayed from its journal. It
   uses every decision at once: buffers changed in place under
   exclusivity, sized integers for formats, slices of pages kept as
   values, snapshots read without a lock, vectorized checksums, hot
   paths that allocate nothing. Of the four designs it needed, views
   into buffers and reads that take no lock are decided; explicit
   layouts for formats on disk and control over allocation are still
   open ([foundations.md](foundations.md#open-questions)).
   If Ren can host a credible one in idiomatic code, the ambition is
   earned.

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
  - **The debug backend isn't clang.** `clang -O0` alone is slower
    than Go's whole compiler on big programs. Debug builds use tcc,
    which compiles Ren's C 12 to 24 times faster
    ([foundations.md](foundations.md#13-two-builds)), and later a
    backend of Ren's own, for a fast link and better debug code.
  - **The front half runs per module, in parallel.** With tcc, it's 80
    to 90% of a debug build, on one core.
- **What gets it there:** the module system, the C backend with tcc,
  then the front half in parallel, separate compilation and caching.
- **The goal past it: release by default.** Debug and release builds
  have one semantics ([foundations.md](foundations.md#15-arithmetic)):
  the same panics at the same points, the same `Float` results. So
  which build runs is only a question of speed, and if release builds
  are fast enough, the edit loop can use them and there's one kind of
  build. Measured, specializing costs 1.1 to 1.2× the debug front half;
  the cost is clang -O2. No fast backend's code comes within 3 times of
  -O2, but -O2 per module in parallel builds 13 to 16 times faster than
  on one file (base-500k in 19.7 s on 16 cores), and with each
  specialization cached by content an edit recompiles one module.

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
    floats follow IEEE exactly, in program order. A `Float` sum is a
    fixed tree of eight lanes, so it vectorizes and gives the same bits
    on every machine: a journal recorded on one replays on another.
  - **With Async, the scheduler's decisions are recorded too.** A
    concurrent program replays exactly, or it doesn't meet the bar.
  - **The journal's format is versioned by name,** so a journal recorded
    on one build replays on the next.
- **What gets it there:** the handlers and journal stage
  ([handlers.md](handlers.md)), then Async's scheduler recording.

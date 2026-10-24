# Ren

**Read like a script. Checked like a proof.**
*App-language ergonomics. Systems-language control.*

Ren is a systems programming language with pure-feeling semantics, compile-time-checked dependencies, and no garbage collector. Function bodies stay short and readable because the signature carries the detail: what a function touches, how it can fail, and what it costs. The compiler checks all of it.

```ren
pub fn upgrade(id: UserId, seats: Int) -> User ! NotFound | PaymentFailed | Conflict
    uses Users, Billing =
  var user = Users.get(id) orelse fail NotFound
  try Billing.charge(user.id, price(seats))
  user.plan = Pro(seats)
  try Users.save(user)
  user
```

You can read that signature without opening the body. `upgrade` returns a `User`, can fail in exactly three ways, and touches exactly two dependencies. It performs no other I/O, hidden allocation, or global state access. Every line that can fail starts with `try`.

Because the compiler knows every boundary a program crosses, Ren can **test, trace, replay, and profile** those boundaries without any instrumentation code. [More on that below.](#test-trace-replay-profile-built-in)

> **Status:** design phase. Nothing runs yet. The examples show how Ren is intended to look. See [Roadmap](#roadmap).

---

## Contents

- [Why Ren](#why-ren)
- [Principles](#principles)
- [A tour](#a-tour)
- [Operators and equality: `ops`](#operators-and-equality-ops)
- [Memory without a GC](#memory-without-a-gc)
- [Concurrency](#concurrency)
- [FFI and `trust`](#ffi-and-trust)
- [Why this is possible: knowledge × control](#why-this-is-possible-knowledge--control)
- [Test, trace, replay, profile: built in](#test-trace-replay-profile-built-in)
- [Errors are part of the design](#errors-are-part-of-the-design)
- [Tooling](#tooling)
- [Trade-offs](#trade-offs)
- [Prior art](#prior-art)
- [Implementation](#implementation)
- [Roadmap](#roadmap)
- [Beyond 1.0](#beyond-10)
- [Open questions](#open-questions)

---

## Why Ren

| You like… | …but you're tired of | Ren keeps | Ren drops |
|---|---|---|---|
| **Rust** | lifetimes, slow compiles | memory safety, no GC, native speed | the borrow checker, trait search |
| **Zig** | convention-only discipline | explicit allocation, minimalism, C interop | unchecked aliasing, manual frees |
| **Go** | `if err != nil`, `ctx` everywhere, OTel overhead | a big stdlib, one way to do things | nil, untyped errors |
| **Effect TS** | a framework on top of a language | typed dependencies, swappable layers | the runtime, the generics gymnastics |
| **OCaml / Elm** | GC pauses, no systems control | ADTs, exhaustive matching, inference | the GC |

The goal is one language for the whole range: everyday backend services at one end, storage engines and databases at the other. The types tell you which end of that range a piece of code is at.

```
 everyday server code                                    a new database
 uses Users, Billing, Net         same language          unique, soa, no Alloc,
 try, with, swap in tests                                arenas, simulation tests
 "reads like a script"                                   "checked like a proof"
```

---

## Principles

These are ranked. When two of them conflict, the one higher on the list wins.

1. **The signature is the truth.** Everything a function touches, returns, or fails with is in its type.
2. **The world is a dependency.** Code reaches outside itself (network, disk, clock, memory) only through dependencies listed in `uses`.
3. **Nothing is found behind your back.** There's no trait search, no overloading, and no implicit conversion. Implementations are installed or attached to a type, never searched for.
4. **Values never change under you.** There is no shared mutable state. You can write `x.field = y`, but nobody else can observe it.
5. **Costs that matter can be pinned.** A function that doesn't list `Alloc` doesn't allocate, and the compiler proves it.
6. **One mechanism, many uses.** Dependency injection, test fakes, allocators, middleware, simulation, and tracing all use the same `uses` / `with` mechanism.
7. **The compiler explains itself.** Every error explains why it happened and suggests a concrete fix.
8. **Enough out of the box.** One formatter, one test runner, one build tool, and a stdlib you can ship with.

A useful filter for any proposed feature: does it make function bodies read more like a script, or signatures more like a proof? If it does neither, cut it.

---

## A tour

Ren has eight concepts. Anything else is a library function.

### 1. Types

```ren
type UserId = opaque u64               // distinct from u64; only this module can make one
type Email  = opaque Str

type Plan =
  | Free
  | Pro(seats: Int)
  | Enterprise(contract: ContractId)

type User = { id: UserId, email: Email, plan: Plan }

fn seat_limit(p: Plan) -> Int =
  match p                              // exhaustive: add a Plan and this stops compiling
    Free          => 1
    Pro(seats)    => seats
    Enterprise(_) => Int.max
```

Ren has no null. Optional values are written `T?`.

### 2. `let` and `var`: value semantics

```ren
var scores = [3.0, 1.0, 2.0]
let before = scores                    // a value, not a reference
scores.push(10.0)                      // copies once: `before` still shares the buffer
assert before == [3.0, 1.0, 2.0]       // nothing changes out from under you

var user = load(id)
user.plan = Pro(seats: 5)              // reads like mutation, means "new value"
```

No two names ever see the same mutable thing, so Ren has no data races and no reference cycles. When a value isn't shared, the compiler updates it in place, so the copies you'd expect from immutable data mostly never happen.

### 3. Functions

```
pub fn name(params) -> Value ! Errors      what goes in, what comes out, how it fails
    uses Dependencies =                    what it touches
```

```ren
fn total(xs: Array<f64>) -> f64                // read-only parameter (default)
fn normalize(inout xs: Array<f64>)             // updates the caller's value
fn blur(unique img: Image) -> Image            // proven unshared, so in-place is guaranteed
```

Lambdas, with trailing-lambda syntax for multi-line bodies:

```ren
let names = users.map(fn(u) => u.name)

let summaries = par_map(users) fn(u) =>
  let feed = try load_feed(u.id)
  summarize(u, feed)
```

Public functions spell out their full contract. Private functions can infer their `uses` and their error set (`! _`). `ren fmt --annotate` writes the inferred clauses into your code.

### 4. Errors

Errors are part of the return type, and failure points are marked where they happen.

```ren
pub fn load(id: UserId) -> User ! NotFound
    uses Users =
  Users.get(id) orelse fail NotFound           // Option → error

pub fn page(id: UserId) -> Html
    uses Users =
  let user = load(id) catch                    // handle errors (exhaustive)
    NotFound => guest()
  render(user)

fn report(id: UserId) -> Report ! _ =
  let user  = try load(id)                     // propagate
  let stats = attempt fetch_stats(id)          // capture as a Result value
  build(user, stats)
```

Bugs aren't errors. Out-of-bounds access, a failed `assert`, or `unwrap` on `None` panics the program.

### 5. `uses`: dependencies are types

A dependency is an ordinary record of functions. Listing it in `uses` makes it available to the function.

```ren
type Users = {
  get:  fn(id: UserId) -> User?,
  save: fn(u: User) ! Conflict,
}

type Clock = { now: fn() -> Time, sleep: fn(d: Duration) }

pub fn touch(id: UserId) ! NotFound | Conflict
    uses Users, Clock =
  var u = Users.get(id) orelse fail NotFound
  u.last_seen = Clock.now()
  try Users.save(u)
```

The built-in dependencies are types too: `Io`, `Net`, `Alloc`, `Async`, and `Unsafe`.

```ren
pub fn checksum(data: Bytes) -> u32 =          // no `uses`: pure, cannot allocate
  var h: u32 = 2166136261
  for b in data
    h = (h ^ b.u32) *% 16777619
  h
```

### 6. `with`: installing implementations

```ren
let frozen = Clock { now: fn() => Time.epoch, sleep: fn(_) => () }

fn main() ! StartupError
    uses Os, Net, Alloc =
  let cfg = try Config.from_env()
  with Sql.pool(cfg.db_url), pg_users, system_clock, Log.json in
    Http.serve(cfg.port, routes)

test "touch updates last_seen" =
  with mem_users([alice]), frozen in
    try touch(alice.id)
    assert Users.get(alice.id).unwrap().last_seen == Time.epoch
```

Production wiring, test fakes, allocators, simulators, and tracers all use the same mechanism. Implementations in a `with` are listed from outermost to innermost, and order matters: in `with retry(3), transaction in`, the retry wraps the transaction.

### 7. `handler`: stateful implementations

Stateless implementations are plain values, as in `frozen` above. An implementation needs a `handler` when it holds state or forwards calls to the next implementation out.

```ren
handler mem_users(init: List<User>) for Users =
  var table = init.index_by(.id)
  get(id) => table.get(id)
  save(u) => table[u.id] = u

handler cached(ttl: Duration) for Users
    uses Clock =
  var cache = {}
  get(id) =>
    match cache.get(id)
      Some(e) if Clock.now() - e.at < ttl => Some(e.user)
      _ =>
        let u = outer.get(id)                   // forward to the next Users out
        if u is Some(user) then cache[id] = { user, at: Clock.now() }
        u
  save(u) =>
    cache.remove(u.id)
    try outer.save(u)
```

Handlers resume at most once, which keeps them as cheap as function calls.

### 8. `&`: this call changes it

```ren
normalize(&scores)                     // visibly updates `scores`

for p in &particles                    // update each element in place
  p.pos += p.vel * dt

let n = try Io.read(fd, &buf)          // the kernel gets exclusive access to buf

swap(&a, &a)                           // error: `a` passed as inout twice
```

A function body uses exactly two markers: `try` means a call can fail, and `&` means a call changes something.

---

## Operators and equality: `ops`

There are no traits or typeclasses. A type carries its own operations, and the compiler looks there and nowhere else.

```ren
type Vec3 = { x: f32, y: f32, z: f32 }
  ops =
    add(a, b)      => { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z }
    mul(a, s: f32) => { x: a.x * s,   y: a.y * s,   z: a.z * s   }
    zero           = { x: 0, y: 0, z: 0 }

type Email = opaque Str
  ops =
    eq(a, b) => a.lower() == b.lower()          // override derived equality
    hash(a)  => a.lower().hash()

type Meters = opaque f64
  ops = numeric                                 // f64 arithmetic, still a distinct type

pub fn sum<T>(xs: Array<T>) -> T where T has add, zero =
  xs.fold(T.zero, fn(acc, x) => acc + x)
```

`==`, `hash`, `compare`, and `show` are derived structurally for every type. You can't add operations to a type you don't own; wrap it in an `opaque` type instead. Because lookup only ever checks the type's own definition, there are no orphan rules, no coherence puzzles, and no slow search.

---

## Memory without a GC

Ren uses compiler-managed reference counting with in-place reuse ([Perceus](https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse/)). There's no garbage collector and no lifetimes. Because no mutable state is shared, the data can't form reference cycles, so reference counting never leaks.

In the safe subset, Ren aims for Rust-level memory safety without lifetimes. Safety comes from reference counting and value semantics at runtime rather than a borrow checker at compile time. Borrow inference, moves on last use, `unique`, and arenas eliminate most of the counting work.

Allocation is a dependency like any other:

```ren
pub fn parse(src: Str) -> Ast ! ParseError
    uses Alloc = ...

fn handle(req: Request) -> Response
    uses Users, Alloc =
  with arena(req.budget) in                     // everything inside freed in O(1)
    respond(try decode(req))                    // only the response escapes (copied out)
```

You choose how much the compiler guarantees:

| You write | You get |
|---|---|
| nothing | reference counting with in-place reuse where possible |
| a `unique` parameter | in-place updates guaranteed; the runtime check is removed |
| no `Alloc` in `uses` | no allocation and no frees, proven; a hidden copy becomes a compile error |

Freeing memory is also the job of `Alloc`, so real-time code without `Alloc` can't stall on a large drop. It has to hand dying values off instead:

```ren
fn audio_cb(inout synth: Synth, inout out: Buf)
    uses Reaper =
  if synth.patch_changed then
    Reaper.send(synth.swap_patch())       // freed later, on a normal thread
  render(&synth, &out)
```

Memory layout is part of the type, not part of the loop:

```ren
type Particle = {
  pos: Vec3,
  vel: Vec3,
  mass: f32,
  cold name: Str,                 // stored out of line, never pulled into hot loops
} where size <= 64                // compile error if it outgrows a cache line

fn step(inout ps: Array<Particle, soa>, dt: f32) =
  for p in &ps
    p.pos += p.vel * dt           // switch soa ↔ aos with one word; the body doesn't change
```

---

## Concurrency

Ren has no `async` or `await` and no colored functions. Concurrency is structured: no task outlives the block that started it, and a failure in one task cancels the others.

```ren
pub fn dashboard(ids: List<UserId>) -> List<Summary> ! Timeout | FeedError
    uses Users, Net, Async, Alloc =
  timeout(2.s) fn() =>
    par_map(ids) fn(id) =>
      summarize(id, try load_feed(id))
```

Shared data is immutable and mutable data has exactly one owner, so data races can't happen. Values with a single owner move between threads for free, and only values that are actually shared pay for atomic reference counts.

---

## FFI and `trust`

```ren
extern "z" fn crc32(seed: u32, p: Ptr<u8>, n: usize) -> u32

pub fn crc(data: Bytes) -> u32 =
  trust crc32(0, data.ptr(), data.len())        // the one audit point: greppable
```

Raw pointers and FFI require `Unsafe`. A `trust` block wraps unsafe code behind a safe signature. `ren why --unsafe` lists every `trust` in your dependency tree.

---

## Why this is possible: knowledge × control

Ren's distinctive features come from two properties that no mainstream language has at the same time:

- **Knowledge.** The language rules give the compiler complete knowledge of every boundary a program crosses. Nothing reaches the outside world except through `uses`, values never change under you, signatures are complete, and structured concurrency records who spawned whom.
- **Control.** Ren owns the whole stack, including the compiler, runtime, codegen, fibers, allocator, and reference-count headers. That's what makes acting on the knowledge nearly free.

```
                     low control                  high control
               ┌──────────────────────────┬──────────────────────────┐
 high          │ Effect TS, Haskell       │                          │
 knowledge     │ knows the effects, but   │   Ren                    │
               │ pays at runtime on a     │                          │
               │ GC / JS runtime          │                          │
               ├──────────────────────────┼──────────────────────────┤
 low           │ Go, Java, Python         │ Rust, Zig, C             │
 knowledge     │ OTel via libraries and   │ full control, but any    │
               │ monkey-patching          │ function can syscall or  │
               │                          │ mutate anything          │
               └──────────────────────────┴──────────────────────────┘
```

That's why principles 1 and 2 rank at the top. A single hole, such as an unchecked FFI call or a global, would quietly make simulation, replay, and tracing untrustworthy.

---

## Test, trace, replay, profile: built in

> **Ren knows every boundary your program crosses, so it can test, trace, replay, and profile them without instrumentation code.**

Every interaction with the outside world is a typed dependency call that the compiler knows about statically. That one fact supplies a single event stream to four tools:

```
                      one event stream, one task tree
 dependency calls  ──▶ [ Users.get | Billing.charge | Net.get | ... ]
                          │           │           │           │
                       observe     simulate     replay     profile
                      (record)    (fake all)   (feed back  (time, allocs,
                                                recorded)   reuse misses)
```

*All planned.*

### Deterministic simulation testing

Run your system under a seeded fake scheduler, clock, network, and disk. Every failure replays exactly.

```ren
test sim "log survives S3 flakiness and crashes" (seed) =
  with sim_scheduler(seed), sim_clock, sim_s3(seed, fail_rate: 5%), sim_crash(seed) in
    let log = DurableLog.open("bucket")
    par_map([writer, reader]) fn(task) => task(log)
    assert DurableLog.recover("bucket").is_prefix_consistent()
```

```
$ ren test --sim --seeds 10000
  ✗ seed 7731: lost acknowledged write after crash at step 412
$ ren test --sim --seed 7731 --trace           # replays exactly, every time
  step 409  writer  S3.put(seg-00041)  → ok
  step 410  writer  ack(offset 40960)
  step 411  sim     S3.put(manifest)   → timeout
  step 412  sim     CRASH
```

The compiler flags any code that can't be simulated, meaning anything with `Unsafe` or FFI in its dependencies, so a passing simulation never gives false confidence.

### Observability without the overhead

OpenTelemetry is expensive because it pays before deciding whether data is needed: it allocates spans, formats strings eagerly, propagates context, and serializes on hot threads. Ren avoids each of those costs:

- **Static metadata, tiny events.** Span names, source locations, and argument types are extracted at compile time (the [NanoLog](https://www.usenix.org/conference/atc18/presentation/yang-stephen) technique). A runtime event is a fixed-size binary record with no strings and no maps.
- **Deferred serialization for free.** Values never change, so an event holds a reference (one RC increment) instead of an eager copy. Formatting happens off the hot path, or never.
- **Context propagation is the task tree.** Structured concurrency already says who spawned whom, so there are no thread-locals and no `ctx`.
- **Zero cost when off.** When no recorder is installed, instrumentation isn't compiled in. When one is installed, the cost is one predictable branch per call site.
- **Flight recorder instead of head sampling.** Everything goes into per-task ring buffers, and Ren decides at the end of the request whether to keep it (on error, or when slow). Tail sampling happens in-process.
- **Traces, metrics, and logs are one stream.** Metrics are derived from events, so there's no separate API.
- **Secrets can't leak.** `type ApiKey = secret Str` is never recorded or printed.

```ren
fn main() ! StartupError
    uses Os, Net, Alloc =
  let cfg = try Config.from_env()
  with Trace.flight_recorder(keep: errors_or_slower_than(500.ms), level: Replayable),
       Trace.otlp(cfg.collector),               // works with existing backends
       pg_users, stripe_billing in
    Http.serve(cfg.port, routes)
```

Business code doesn't change: every dependency call is already a span. Pure work can be marked explicitly:

```ren
let price = span("pricing.compute", seats: seats) fn() =>
  compute_price(plan, seats)
```

### Replay production bugs locally

Recording levels share one schema:

| Level | Records | Use |
|---|---|---|
| 0 | nothing | compiled out |
| 1 | timings and IDs | traces and metrics |
| 2 | + arguments | debugging |
| 3 | + dependency results | exact local replay |

```
$ ren trace pull --request 8812
$ ren replay trace-8812.bin
  ✗ panic: index 17 out of bounds  (pricing.ren:88)
```

### Native profiling

Every wait goes through a dependency, so wall time breaks itself down:

```
$ ren profile --request 8812
  412ms total
  ├─ 301ms  Users.get        (waiting, 3 calls)     users.ren:12
  ├─  62ms  Billing.charge   (waiting)              users.ren:14
  ├─  41ms  CPU: compute_price                      pricing.ren:30
  └─   8ms  CPU: other
```

Ren can also profile things other languages can't see:

```
$ ren profile --reuse            # where in-place updates failed, and why
  pricing.ren:44   map over `rows`   reuse hit 2%   shared with `snapshot` (line 41)
  feed.ren:19      buf.push          COW copy 12×   shared by slice `head` (line 17)
```

Performance tests are deterministic, so they're never flaky:

```ren
test sim "dashboard has no N+1" (seed) =
  with sim_world(seed), Profile.count in
    dashboard(ids_100)
    assert Profile.calls(Users.get) <= 1
    assert Profile.allocs() <= 50
```

Production profiles feed back into release builds (`ren build --release --pgo profile.bin`), so the compiler spends its specialization budget on the code that's actually hot.

### What else falls out

- **Swap anything in tests.** No mocking library, just a different `with`.
- **Dependencies can't phone home.** A dependency that gains `Net` in an update fails your build.
- **Performance contracts survive refactors.** A no-`Alloc` hot path that starts copying is a compile error.
- **Semantic diffs.** `ren diff main..pr-412` shows behavior changes, such as "`checkout` now uses `Net`."
- **Hermetic builds.** Compile-time code has no network, clock, or environment access, so builds are reproducible by construction.

**Costs:** the trace recorder is the one privileged dependency, woven into call sites by the compiler. Flight-recorder buffers keep values alive until a request ends, so they need a byte budget. Generated C keeps frame pointers (about 1–2%) and emits `#line` directives, so tools point at `.ren` source. CPU time inside pure code still needs a sampler.

---

## Errors are part of the design

```
error: `dashboard` doesn't declare `Clock`
   ┌─ src/feed.ren:31:5
31 │     summarize(id, try load_feed(id))
   │                       ^^^^^^^^^^^^^ needs Clock
   │
   = via: dashboard → load_feed → retry → Clock.sleep   (src/feed.ren:22)
   help: add `Clock` to `uses` on `dashboard`
```

```
warning: `buf` is shared by the slice `head`, so `push` copies the buffer
   ┌─ src/frame.ren:14:1
13 │ let head = buf[0..16]
   │            --- slice keeps `buf` shared
14 │ buf.push(0)
   │ ^^^^^^^^ copies
   help: copy the slice instead:  let head = buf[0..16].copy()
```

Every error points to the code that caused it, explains why, and offers a concrete fix. An error message that doesn't do all three counts as a bug.

---

## Tooling

One binary, with one way to do each thing.

```
$ ren new shop && cd shop
$ ren run
$ ren test                        # unit, property, and simulation tests
$ ren fmt                         # one style, no configuration
$ ren why upgrade                 # what does this function touch, and where from?
  upgrade -> User ! NotFound | PaymentFailed | Conflict
    uses Users    ← Users.get, Users.save   (users.ren:12, 16)
    uses Billing  ← Billing.charge          (users.ren:14)
$ ren build --release
  shop  1.9 MB  static
```

Dependencies are vendored source, Go-style, with no package registry by default.

---

## Trade-offs

Ren gives some things up on purpose:

- **No shared mutable references.** Graphs, doubly linked lists, and observers use indices, generational handles, or a handler that owns the state. This is the same style serious Rust code converges on.
- **No multi-shot continuations.** Handlers resume at most once. Generators and async still work. Backtracking search is written explicitly.
- **Reference counting isn't free.** Expect some overhead on pointer-heavy shared data. Arrays of plain values carry one count in total, not one per element. Expect roughly 1–1.5x of Rust on typical code (a target, not a benchmark).
- **Safety is checked at runtime, not proven at compile time.** Ren's safety rules (uniqueness, arena escape, the no-free rule) are new combinations. They need precise specs, sanitizer-checked tests, and fuzzing before anyone can claim they match Rust.
- **No operations on types you don't own.** Wrap them in an `opaque` type.
- **Dependencies are ambient.** Knowing which implementation answers a call depends on tooling: hover and `ren why` are first-class features.
- **It's new.** No ecosystem, no Stack Overflow, and LLMs don't know it yet.

---

## Prior art

Ren is mostly a new combination of existing ideas. It owes a lot to:

- **[Koka](https://koka-lang.github.io/):** row-typed effects, evidence passing, Perceus reference counting, functional-but-in-place
- **[Roc](https://www.roc-lang.org/):** the closest relative. It shares the RC + Perceus core, a fast compiler, and lambda set specialization. Roc keeps apps pure and puts systems work in a separate "platform" host. Ren puts both in one language, with named, typed dependencies instead of a pure/effectful split.
- **[Lean 4](https://lean-lang.org/):** borrow inference, functional-but-in-place arrays
- **[Hylo](https://www.hylo-lang.org/) and Swift:** mutable value semantics, `inout`
- **OxCaml:** uniqueness and locality modes
- **[Lambda set specialization](https://www.cs.princeton.edu/~mpmilano/publication/lss/) (PLDI '23):** closures and dependency records without heap allocation or indirect calls
- **[Zig](https://ziglang.org/):** explicit allocation, comptime, minimalism
- **Go:** stdlib-first, one-binary tooling
- **[Effect](https://effect.website/):** typed dependencies, layers, structured concurrency
- **FoundationDB, TigerBeetle, Antithesis:** deterministic simulation testing
- **NanoLog, `defmt`, `rr`:** static log extraction, record and replay
- **Elm and Gleam:** errors written for humans, small languages that fit in your head

---

## Implementation

- The compiler is written in **OCaml**.
- The backend emits **C**: `tcc` for fast debug builds, `clang -O2` (or `zig cc`) for release builds, and Wasm through the same path.
- Debug builds pass dependencies as dictionaries for fast compiles. Release builds specialize implementations known at compile time using lambda sets, so dependency calls become direct, inlinable calls, within a specialization budget.
- Golden tests cover every example and every error message from day one. All generated C runs under ASan and UBSan, and the interpreter and native backend are differentially tested against each other.

---

## Roadmap

| Stage | Adds | Done when |
|---|---|---|
| 1 | lexer, parser, indentation, functions | `fib(30)` runs |
| 2 | records, sum types, exhaustive `match` | missing-case errors fire |
| 3 | type inference | private functions need no annotations |
| 4 | `var`, `inout`, `&`, value semantics | `normalize(&scores)` works |
| 5 | `!`, `try`, `catch`, `fail`, `orelse` | error paths type-check |
| 6 | `uses`, `with`, dependency types | tests swap implementations |
| 7 | `handler`, `Async`, `par_map`, **the effect journal** | caching handlers wrap real ones; calls are journaled |
| 8 | `ops`, derived equality and hashing | `Map<Email, User>` works |
| **↑** | **interpreted Ren** | **a small web service and its tests run** |
| 9 | C backend | native binaries |
| 10 | reference counting with reuse | `map` reuses memory in place |
| 11 | `Alloc` as a dependency, arenas, no-alloc checking | `checksum` provably never allocates |
| 12 | `unique`, layout (`soa`, `cold`, `where size`) | hot loops run with zero copies |
| 13 | simulation scheduler, flight recorder, replay, profiler | a failing seed replays exactly |
| **↑** | **Ren 1.0** | **flottning, rewritten in Ren, passes 10,000 simulation seeds** |

The **effect journal** in stage 7, the record of every dependency call, is the most important design artifact after the type system. Simulation, replay, migration, and traffic replay all depend on it. If the format is right, those features are extensions. If it's wrong, each one becomes a rewrite.

---

## Beyond 1.0

Once the language and its four built-in tools exist, the same knowledge-plus-control foundation enables a platform. All of this is long-term vision, not current scope.

```
 foundations:  uses/with ─┬─ sim scheduler ─┬─ effect journal ─┬─ flight recorder
                          │                 │                  │
               batching ◀─┘    fleet sim ◀──┤  traffic replay ◀┤
               read caps       model check ◀┘  time travel ◀───┤
               incremental                     migration ◀─────┘
```

### Wave 1

**Whole-fleet simulation.** A service-to-service call is just a dependency, so `with remote(Users, url)` in production becomes `with sim_node("users")` in tests. A whole fleet of Ren services, plus databases and object storage, runs in one deterministic process, with partitions, clock skew, and crashes.

```ren
test sim "checkout survives a partition" (seed) =
  with sim_cluster(seed, nodes: [api, users, billing], partition_at: 3.s) in
    assert eventually(all_orders_consistent)
```

**Exact incremental computation.** Pure functions are deterministic, and every input (files, config) arrives through a dependency, so results can be cached by content and invalidated precisely. `ren test` reruns only the tests whose code, or whose dependencies' code, actually changed. Build systems, data pipelines, and reactive UIs get the same treatment.

### Wave 2

**Model checking real code.** The simulation scheduler controls every interleaving, so for small configurations it can explore all of them instead of random samples. That's TLA+-style exhaustive checking run against your real code, not a separate spec.

```
$ ren test --model-check --nodes 3 --max-steps 40
  ✓ explored 2,184,331 interleavings, no violations
```

**Automatic batching.** Pure code between dependency calls can't observe their ordering, so concurrent lookups merge into a single query. N+1 queries get fixed, not just detected.

```ren
with batched(Users, max: 100) in
  par_map(ids) fn(id) => Users.get(id)      // one query, not 100
```

**Read-only capabilities.** `uses Users.read` versus `uses Users.write`. The compiler then knows which functions are safe to retry, hedge, or cache, with no idempotency annotations.

### Wave 3

**Replay production traffic before you deploy.** Replay recorded traffic against a new build and diff the responses, errors, dependency calls, and allocations. "The tests passed" becomes "these 3 requests behave differently."

```
$ ren replay --traces last-hour/ --against ./new-build --diff
  4,912 requests  ·  3 behavior changes  ·  Users.get calls −38%
```

**Time-travel debugging.** Replay combined with immutable, structurally shared values makes stepping backwards cheap.

### Wave 4

**Hot reload with typed state migration.** State lives in handlers and values are immutable, so a running server can swap code between requests, migrating handler state with a type-checked function. It's Erlang-style hot code swapping, with types.

**Moving a request mid-flight.** Every interaction with the world is journaled, so a task can stop on one machine and resume on another by replaying its journal, without serializing a stack. This enables live migration, draining nodes without dropping work, and moving computation closer to its data.

**Data lineage.** `type Email = pii Str` lets the compiler track which logs, responses, and cache entries derive from personal data, so a deletion request becomes a query instead of an audit.

---

## Open questions

- Should mutating method calls on a `var` (`xs.push(x)`) need `&`?
- Should arena results escape by copy only, or also through borrowed handler parameters?
- How much `comptime` is needed for `Json.decode<T>`-style reflection without macros?
- Should handler ordering be linted, and which orderings are known to be bad?
- What exactly goes in an effect journal entry so it serves simulation, replay, and migration alike?
- Which dependencies are traced per call by default, and which only in aggregate (`Clock`, `Alloc`)?

---

## License

TBD.

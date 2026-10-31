# Where other languages draw the line between language and std

Prior art for [foundations.md decision 20](../../foundations.md#20-what-the-language-owns-and-what-std-owns)
and [stdlib.md](../../stdlib.md). Clones are in `/tmp/ren-refs`; paths
below are relative to each clone. Snapshots: zig 738d2be (Nov 2025, just
before 0.16), roc 7de4d5c, eio 1fa7762, koka 198fc3b, effekt 5ce8d12,
swift 1006dea, lean4 24a851d, unison ccd85c3, oxcaml 629921bf (all Oct
2026 except zig).

The short version:

- Every language surveyed privileges its std somewhere. The ones that
  say they don't (Zig, Roc) hold the line on *powers* and still give std
  special status on *names*: the compiler knows `Str`, `List`, an
  allocator interface, or a set of operator traits by name.
- The two places the line breaks are **the shared types** (who owns
  `Future`, `AsyncRead`, `Request`, the log facade) and **the
  optimizer** (std code the compiler recognizes by name).
- Passing capabilities as values (Zig `Io`, Eio `env`) and
  rows-and-handlers (Ren) have the same power. Values cost plumbing,
  give one coarse grant, and in practice get stored in structs. Rows
  give a fine-grained, checked record for free.
- Every language that splits the scheduler from I/O badly (Rust) got an
  ecosystem split. Every one that puts the scheduler and the driver in
  one object (Zig, Eio) has backends that lag each other.
- Big stds rot at the protocol end (Python's dead batteries, Go's
  `net/smtp`), not at the shared-type end.

---

## 1. Zig

**Where the line sits.** The language is small: types, `comptime`, and
about 120 `@builtin` functions (`@memcpy`, `@atomicRmw`, `@cImport`,
`@typeInfo`, ...). std is ordinary Zig over those builtins. There is no
hidden allocator, no hidden I/O, and since 0.16 no hidden argv or
environment: `main` may take a `std.process.Init` holding `gpa`, an
`arena`, `io`, args and the environment
([0.16 release notes, "Juicy Main"](https://ziglang.org/download/0.16.0/release-notes.html)).

**What's privileged.** Builtins, and a few std types the compiler names
(`std.builtin.Type` for `@typeInfo`, the panic handler, the start
code). The allocator and `Io` interfaces are not privileged: each is a
struct of a pointer and a vtable, `userdata: ?*anyopaque, vtable:
*const VTable` (`lib/std/Io.zig:560-563`). Anyone can write one.

**How effects reach std.** As values passed down. Allocators have been
explicit since around 2018. 0.15 went further: `std.ArrayList` became
the *unmanaged* kind by default, with the allocator passed to each
method instead of stored in the list
([Ziggit](https://ziggit.dev/t/arraylist-and-allocator-updating-code-to-0-15/12167)).
The stated reasons: stored allocators make signatures worse, block
static initialization, and cost memory in nested containers. 0.16 then
did the same for I/O.

**`std.Io`.** In 0.16, "all input and output functionality requires
being passed an `Io` instance". The release notes give the rule:
whatever can block control flow or introduce nondeterminism belongs to
`Io`. So `Io` covers files and directories, sockets, DNS, the clock and
sleeping, `io.random` and `io.randomSecure`, process spawning, mutexes
and condition variables, and concurrency itself. The vtable in the
snapshot has 51 operations (`Io.zig:563-710`): `async`, `concurrent`,
`await`, `cancel`, `select`, group operations, mutex and condition
operations, about 20 `dir*`/`file*` ones, `now`, `sleep`, and 14
`net*` ones.

- **async/await is a library.** The keywords were removed in 0.11 and
  rebuilt as `io.async(f, args)`, which returns a `Future` you
  `await(io)` (`Io.zig:1570`). `async` may run `f` inline, before it
  returns. `io.concurrent` must run it concurrently, and may fail with
  `ConcurrencyUnavailable` (`Io.zig:1590-1609`). This split exists so
  one library runs on a blocking single-threaded `Io` as well as an
  evented one. It also makes a producer that needs a concurrent
  consumer say so in its type.
- **The implementations.** `Io.Threaded` (a thread pool,
  `Io/Threaded.zig`, 6,259 lines) is the only finished one.
  `Io.Evented` (stack switching) is experimental with no networking.
  `Io.Uring` and `Io.Kqueue` are proofs of concept
  (`Io.zig:546-556`). `Io.Dispatch` uses GCD. `Io.failing` supports no
  operation. Each implementation is a scheduler *and* a set of
  syscalls in one object.
- **Cancellation.** A cancel makes the next I/O operation return
  `error.Canceled`. Code propagates it, re-arms it, or masks it.
  `Threaded` interrupts blocking syscalls with a signal.
- **Tests** use `std.testing.io` (`Io/test.zig:19`), "much like
  `std.testing.allocator`". It is a real `Threaded` instance, so tests
  do real I/O. There's no in-memory filesystem or simulated network in
  std.
- **Coloring.** The function's color is a parameter, not a keyword.
  Code that takes `io: Io` runs on every implementation. Code that
  doesn't take one can't do I/O at all. The interface costs one
  indirect call per operation. Zig expects to devirtualize when a
  program has only one implementation
  ([Loris Cro, "Zig's New Async I/O"](https://kristoff.it/blog/zig-new-async-io/)).

**Against Ren's dependencies and drivers.**

| | Zig `Io` | Ren |
|---|---|---|
| What's granted | one value grants everything: files, net, clock, entropy, processes, spawning | one row entry per world dependency: `Fs`, `Net`, `Clock`, `Random`, ... |
| Where it shows | a parameter, written by hand on every function | `uses`, inferred for private functions, written on public ones |
| Can it be stored? | yes, and libraries do keep `io` in structs, as they kept allocators | no: handlers are scoped by `with`, and closures can't be stored |
| Tests | real I/O by default; `Io.failing` | fakes by default; real, in-memory and sim for each dependency |
| Swapping part of it | wrap the whole vtable | `with` one dependency, or `over` one |
| Scheduler and driver | one object | closed set of schedulers; open drivers in `trust` over `Async.submit` (runtime.md, "Drivers are Ren") |
| Cost of a call | indirect call through a vtable | a call, plus an evidence lookup that becomes a fixed index when the row is known (deps.md rule 6) |

**What Zig decided.** A capability is a value: no new type system
feature, no inference, nothing the compiler must understand. They
accept coarse grants (no way to say "this needs the clock but not the
network") and hand plumbing. The same test, "blocks or is
nondeterministic, so it goes through `Io`", is Ren's determinism test
(stdlib.md, Part 1). Zig arrived at Ren's world list from the other
side: entropy, the clock and processes went into `Io` *because*
simulation and portability needed them there.

**What it teaches Ren.**

- The criterion for the world list should be written down: "it blocks,
  or it differs between two runs". Zig used it to close their list.
  Decision 20 only enumerates.
- Zig found that locks and condition variables must go through the
  same interface as I/O, or a lock blocks the event loop. Ren has no
  mutex (handler state replaces it), so this is already covered.
- 51 operations is the real width of a world interface for a systems
  language. Ren's world `D.Call` sums will be about that size.
- Fusing scheduler and driver leaves backends uneven: in 0.16 only
  `Threaded` is complete. Ren's split, few schedulers and many drivers
  over one primitive, avoids that.
- Per-call allocators over stored ones agrees with Ren: `Alloc` is a
  dependency in the row, never a field.

---

## 2. Rust

**Where the line sits.** Three layers. `core` needs nothing: no heap,
no OS. `alloc` adds `Box`, `Vec`, `String`, `Rc` and `Arc`, and needs a
global allocator (`#[global_allocator]`, stable since 1.28). `std`
adds the OS: files, sockets, threads, `env`, `process`, `time`.
`#![no_std]` drops `std` for a crate. std has no HTTP, no async
runtime, no random numbers, no regex, no serialization, no logging.

**What's privileged.**

- **Lang items.** Over 150 `#[lang = "..."]` items connect syntax to
  library code: `Add` for `+`, `Deref` for `*`, `IntoIterator` for
  `for`, `Try` for `?`, `Future` for `.await`, `owned_box` for `Box`,
  `Sized`, `Copy`, `Drop`. The list grows with each new piece of
  syntax.
- **Intrinsics** (`core::intrinsics`), unstable to users.
- **Unstable features.** std is built with nightly features users
  can't turn on in stable Rust: specialization (`min_specialization`),
  `#[rustc_*]` attributes, `allocator_api`. So std's
  `impl<T: Copy> Extend<&T> for Vec<T>` can be faster than a user's
  collection can be.
- **`Box`** can be moved out of with `*b`. No user type can.

**How effects reach std.** Ambiently. `std::fs::read` reaches the
world from anywhere. Capabilities were tried as a crate, `cap-std`
(Bytecode Alliance). It works, and few libraries use it, since the
ambient std is always there.

**The cost of a small std.**

- **The runtime split.** `Future` and `Waker` are in `core`, so the
  language has async. Spawning, timers and `AsyncRead`/`AsyncWrite`
  are not in std. tokio and async-std each defined their own, and a
  library had to pick one or add a feature flag for each. `futures`
  defined a third `AsyncRead`. async-std was discontinued in March 2025
  in favour of smol ([async-std](https://github.com/async-rs/async-std)).
  The split was over shared types and the runtime. It wasn't over
  leaf functionality.
- **Shared types by convention.** The ecosystem rebuilt what std
  didn't own. `log` is a facade that every library writes to and one
  binary implements. The `http` crate (1.0 in Nov 2023) gives hyper,
  reqwest and axum one `Request` and `Response`. Both work because one
  blessed crate exists. Until `http` 1.0, a hyper 0.14 and a hyper 1.0
  `Request` were different types.
- **Leaf crates are fine outside std.** `regex` and `serde` are
  better for being free of std's promise. `rand` is the cautionary
  one. It broke its API at 0.7, 0.8 and 0.9, and documents that
  `StdRng`'s algorithm may change, so a seeded stream isn't
  reproducible across versions. That's the failure Ren's determinism
  test prevents.
- **`no_std` is a crate-level flag,** and it spreads by feature
  flags: `default-features = false, features = ["alloc"]`. Many crates
  never opt in, so embedded and kernel code has a smaller ecosystem.
  The allocator API that would let `Vec<T, A>` take an arena has been
  unstable since 2016 (tracking issue #32838).

**Against Ren.**

- Ren's `Alloc` in the row is `no_std` at the function level, decided
  by inference, not a crate flag. A pure function in any package is
  usable in no-alloc code without its author doing anything. That's
  the right shape. The risk is stdlib.md's last paragraph: "an
  unchecked package writes no `Alloc`, and each of its functions counts
  as allocating to its callers". That's a crate-level `no_std` default
  again. If the inference is sound, run it on every package and let
  `ren.toml` decide only whether `Alloc` must be *written* in public
  signatures.
- "std owns the shared types" (stdlib.md rule 1) is confirmed by
  Rust's history. The types that split Rust's ecosystem were the
  runtime's (`spawn`, `AsyncRead`) and the protocol's (`Request`).
  Ren puts `Async` in the runtime and `Request` in std. Both are right.
- Rust's std having nightly features is a direct rule-2 breach.
  Decision 20 should say that std is compiled with the same language
  users have: no flag, attribute or feature only std may use.

---

## 3. Roc

**Where the line sits.** The standard library is the `Builtin` module
(`src/build/roc/Builtin.roc`, 28,519 lines): `Str`, `List`, `Box`,
`Dict`, `Set`, `Num`, `Iter`, `Stream`, `Hasher`, `Encoding` and
`Crypto` with SHA-256 (`Builtin.roc:2222, 3032, 3204, 3634`). It has no
I/O at all. "The standard library contains only functions and data
structures; an application gets all of its I/O primitives from its
platform" (`docs/langref/platforms.md:45`).

**What's privileged.** `Str`, `List`, `Box` and the SIMD types are
declared `[ProvidedByCompiler]` (`Builtin.roc:2222, 3896, 5595`). The
platform is privileged in a different way: it owns `main`, every I/O
primitive and the allocator. "In C terms, the host provides `malloc`
and `free`" (`platforms.md:90`). A platform's hosted functions are
declared in Roc and listed in its header,
`hosted { "roc_stdout_line": Stdout.line! }`
(`docs/langref/modules.md:581-611`). Foreign calls exist only if the
platform offers them (`platforms.md:63`).

**How effects reach std.** They don't. Effectful functions are marked
by `!` and `=>`, inferred by purity checking, with no effect row. An
application reaches the world through `import pf.Stdout`.

**What the split gives.**

- A platform can refuse a primitive at build time. A browser platform
  has no file I/O. A server has no blocking stdin (`platforms.md:51-55`).
- Security: a platform can prompt before any file operation, and
  there's no escape hatch (`platforms.md:59-63`).
- Allocation tailored to the domain: `nea` allocates a request's memory
  in an arena and frees it all when the response is sent
  (`platforms.md:94`).

**What it costs.** A package that does I/O must name one platform, "the
identical platform version and content hash" (`platforms.md:114`).
There's no shared `Fs` interface across platforms, so an I/O library is
written once for each platform. Tests that need a fake world need a
test platform, or the code must take its effects as function
arguments. The platform docs admit platform scheduling "haven't been
built yet" (`platforms.md:71`).

**Against Ren.** Ren has Roc's benefit without its cost. The world
comes from outside (a driver, installed by `main`), as Roc's does. But
std declares the *interfaces*, `dep Fs` and `dep Net`, so a library
written against `Fs` runs on every driver, and a test swaps one
dependency rather than a platform. Roc's per-request arena is Ren's
`Mem` arenas under an `Alloc` handler. Roc's "a platform without file
I/O" is Ren's build refusing a program whose row has `Fs` under a
driver that answers no `Fs` calls. That check is worth stating in
runtime.md (hosted drivers). Roc also shows that `Crypto` and a
`Stream` type end up in a pure std even in a language that pushes
everything out. A shared stream type is needed even when std does no
I/O.

---

## 4. OCaml Eio (and OxCaml)

**Where the line sits.** The OCaml stdlib is ambient: `open_in`, `Unix`
and `Random` reach the world from anywhere. Eio is a library on top,
using OCaml 5's effect handlers.

**Capabilities as values.** `Eio_main.run` hands `main` an `env`
object: `net`, `domain_mgr`, `process_mgr`, `clock`, `mono_clock`,
`fs`, `cwd`, `secure_random`, `debug` (`lib_eio/unix/eio_unix.mli:105-118`).
"All authority starts at the (privileged) `Eio_main.run` function"
(`README.md:475`). The README tells libraries not to pass `env` around
and to take only what they need, `~clock ~net`, so a reader can see
what a function touches (`README.md:1815-1830`). That's Ren's `uses`
row, written by hand and unchecked. And "since OCaml is not a
capability language, code can ignore Eio and use the non-capability
APIs directly" (`README.md:492`).

**Structured concurrency in a library.** `Switch` and `Fiber` are
plain OCaml over three effects: `Fork` (`lib_eio/core/fiber.ml:1`),
`Suspend` (`core/suspend.ml:2`) and `Get_context` (`core/cancel.ml:32`).
Each backend (`eio_linux` on io_uring, `eio_posix`, `eio_windows`)
handles them, so each backend is a scheduler and a driver in one, as
in Zig. Within a domain, scheduling is deterministic, and "programs
using only the Eio APIs can only behave non-deterministically if given
a capability to do so" (`README.md:1568-1570`). `traceln` is the
stated exception: it writes to stderr without a capability and without
switching fibers (`README.md:1574-1576`).

**How tests swap capabilities.** Pass a different value.
`Eio_mock.Flow.make`, `Eio_mock.Net.make` and `Eio_mock.Backend.run`
build fakes and a test scheduler (`README.md:162-183, 369-401`).

**OxCaml.** Jane Street ships its extensions' library support in tiers:
`otherlibs/stdlib_alpha`, `stdlib_beta`, `stdlib_stable` and
`stdlib_upstream_compatible`. A language feature (unboxed `float_u`,
`iarray`, `or_null`) brings std modules with it, staged with the
feature. Std follows the language's staging, not a separate one.

**Against Ren.** Eio proves the model: one privileged entry point, fakes
by passing other values, deterministic scheduling, structured
concurrency over a handful of effects. Ren takes the same model and
checks it. Two details carry over:

- Eio's `traceln` is Ren's `dbg`: a world effect outside the capability
  discipline, allowed because it never changes scheduling. Decision 20
  should name `dbg` as an exception, as Eio names `traceln`.
- Eio dropped OCaml objects for a value plus an interface lookup "for
  Eio to be widely accepted" (`doc/rationale.md:136`). Ren's evidence
  vector is the compiled form of the same thing.

---

## 5. Koka and Effekt

**Koka.** Effects are in the language. The std is written over them.
Async is a library: `std/async` is built over the effects
`async-await`, `async-cancel` and `async-ioc` (`lib/std/async/internal.kk:27-48`)
and C externs over libuv. But the *world* effects are not handlers.
`net`, `fsys`, `ui` and `blocking` are bare type constants (`:: X`),
and `io` is an alias over them (`lib/std/core.kk:62-81`). Their
operations are `extern` C calls (`lib/std/os/file.kk:35-40`). So the
type system records that a function touches the file system, but no
handler can intercept it. A test can't swap the file system. The
built-ins are the row kinds (`total`, `div`, `ndet`, `alloc<h>`,
`read<h>`, `write<h>`, `core/types.kk:125-150`), `ref`, the primitive
types and the externs.

**Effekt.** Same pattern, with captures instead of rows for the world.
Externs are typed `at io`, `at async` or `at global`
(`libraries/common/io.effekt:11`, `effekt.effekt:41-122`). The direct
functions, `readFile(path): String / Exception[IOError]`
(`io/filesystem.effekt:14`), reach the file system without an effect
in their type. A handleable `Files` interface exists and is opt-in:
`interface Files` and `def filesystem { program: => R / Files }`
(`io/filesystem.effekt:150-161`).

**What it teaches Ren.** Two research languages with full effect
handlers both chose not to make the world handleable by default. The
reasons are cost (a handler call per operation) and convenience
(`println` without ceremony). Ren pays that cost on purpose, and it
buys Ren's whole testing and simulation story. The evidence says Ren's
choice is unusual, not wrong. Ren has to make the call cheap (deps.md
rule 6, a fixed index) and make the default handlers free to install
(`main` installs them). Effekt's opt-in `Files` is what Ren would
become if a "fast path" for the real `Fs` ever skipped the handler. It
must not.

---

## 6. Swift, Lean 4, Unison

**Swift.** The stdlib is Swift over a `Builtin` module that "is only
visible when the compiler is invoked with the `-parse-stdlib` frontend
flag" (`docs/Generics/chapters/types.tex:694`). `Bool` is a struct over
`Builtin.Int1` (`stdlib/public/core/Bool.swift:64-65`). Two further
privileges matter more than `Builtin`:

- **`@_semantics`.** The optimizer recognizes std functions by a
  string tag: `@_semantics("array.get_count")`, `"array.get_capacity"`
  (`stdlib/public/core/Array.swift:328-343`). There are 268 uses in
  `stdlib/public/core`. A user's array type can't get those
  optimizations. It's an optimization that is invisible and still
  only std's.
- **Underscored public API.** `@usableFromInline` and `_`-prefixed
  public names exist so std can inline across its ABI boundary,
  outside the evolution process
  (`docs/StandardLibraryProgrammersManual.md:253-267`).

Concurrency (`Task`, actors, executors) is in the stdlib's
`Concurrency` module with a C++ runtime, so Swift has no runtime split.
Custom executors came later (SE-0392). Foundation was the big library
outside the stdlib. It was rewritten in Swift (`swift-foundation`,
2023 on), split into `FoundationEssentials` and
`FoundationInternationalization`. `swift-collections`, `swift-system`
and `swift-algorithms` are separate packages that work as a staging
area.

**Lean 4.** `Init` is the prelude and core, `Std` ships in the
compiler's repository, and `Batteries` (renamed from `std4` in 2024 to
free the name) and Mathlib are outside it. `IO` is a builtin monad over
`ST IO.RealWorld` (`src/Init/System/IO.lean:39`), ambient. `Std` has
grown `Std.Async`, `Std.Net` and `Std.Http` over libuv (`src/Std/Http`,
`src/Std/Async`, `src/Std/Net`, 59 files; `src/runtime/libuv.cpp`),
which brings a server stack into a std that ships with the compiler.
Whatever the motive, a std tied to the toolchain's release grows toward
what the toolchain's users build.

**Unison.** `IO` is a builtin ability (`parser-typechecker/src/Unison/Builtin.hs:207`)
that user code can't handle. Only the runtime runs it. TLS, sockets,
threads, `MVar` and crypto hashes are builtins
(`Builtin.hs:208-224, 1020`). Other abilities (`Exception`, `Random`,
`Remote`) are handled by code, so tests swap them. The relevant part
is versioning. Definitions are named by the hash of their content.
`base` is a library pinned by hash inside each project (`lib.base`),
so two versions of `base` coexist, and a definition that didn't change
between them is the *same* definition. Moving or renaming never breaks
a caller. There is no "std version".

**What it teaches Ren.**

- Swift's `@_semantics` is the most likely way Ren's rule 2 erodes.
  Rule 4 says an optimization is invisible. It doesn't say an
  optimization may not be keyed to a std declaration's name. Ren's
  current ones are general (a string `match` on any array literal of
  strings, in-place `+=` on any unique string). Keep it so in writing.
- Unison's content identity answers stdlib.md's open question on
  `std.x`. Promotion from `std.x` to `std` must not make a new type.
  Go learned this when `golang.org/x/net/context` moved to `context`:
  the two were distinct types until Go 1.9 added type aliases, largely
  for that move. Ren already keys declarations for incremental builds
  (module-build.md). If promotion re-exports the same declaration
  rather than copying it, `Time` from `std.x/foo` and from `std/foo`
  stay one type.
- Unison and Roc both put TLS or crypto among the builtins. Ren keeps
  them in std over `foreign fn`, which any package can use. That holds
  rule 2, as long as the link check (stdlib.md, Part 6) and `trust` are
  as open to a third party as to std.

---

## 7. Python's dead batteries, Gleam's small std (and Go)

**Python.** Batteries included, for 30 years. PEP 594 (accepted 2022)
removed about twenty modules in 3.12 and 3.13: `asyncore`, `asynchat`,
`smtpd`, `cgi`, `cgitb`, `telnetlib`, `nntplib`, `uu`, `xdrlib`,
`crypt`, `audioop` and others. What died was **protocols and media**:
mail and news servers, old audio formats, CGI. Shared types (`bytes`,
`datetime`, `pathlib`, `io`) did not die. The HTTP client people use,
`requests`, never entered std, and `urllib` stayed as a fallback.
`asyncio` entered std late and fixed `async` to one runtime too late to
prevent `trio`, `curio` and `anyio`.

**Gleam.** The compiler ships no std. `gleam_stdlib` is a hex package
versioned on its own, and the BEAM parts (`gleam_erlang`, `gleam_otp`)
and `gleam_http` (the shared `Request` and `Response` types used by
`mist` and `wisp`) are separate packages. Before 1.0 of the std it
moved modules *out*: `gleam/iterator` was deprecated for the
`gleam_yielder` package ([gleam_stdlib 0.45 docs](https://gleam-stdlib.hexdocs.pm/0.45.0/gleam/iterator.html)),
and regex went to `gleam_regexp`.

**Go,** briefly, since stdlib.md leans on it. `net/http`, `io.Reader`
and `database/sql` are why Go libraries fit together. That's
stdlib.md's rule 1 and it holds. `net/smtp` and `net/rpc` are frozen.
`math/rand/v2` (Go 1.22) was std's first v2 package, needed because
v1's global source and API couldn't change. HTTP/2 lives in
`golang.org/x/net/http2` and is copied into std as `h2_bundle.go`.

**What it teaches Ren.** Std rots at its protocol end. Every module
that names a protocol is a future dead battery, and needs a way out
that doesn't break callers. A small, separately versioned std works
when the core team blesses the shared-type packages (`gleam_http`,
Rust's `http`). Ren's choice, shared types in std and protocols
staged, is the safer one, but its inventory still lists many protocols
as std.

---

## The patterns

**Where good lines sit.**

1. **The language owns syntax's targets.** Every language has a closed
   but growing list of library names its syntax turns into: Rust's
   lang items, Swift's literal protocols, Roc's `ProvidedByCompiler`,
   Ren's reserved names. The list grows with each construct. Ren's
   decision to keep it one closed list (rule 3) is the norm, done
   explicitly.
2. **The runtime belongs to the language, or the ecosystem splits.**
   Rust and Python left the scheduler out and split. Swift, Go and
   Koka put it in and didn't. Zig puts it in std as an interface, and
   it's too early to tell.
3. **The shared types belong to std, or to one blessed package.**
   `http`, `log`, `gleam_http` and `Future` all exist because someone
   had to own them.
4. **Leaf computation belongs outside std,** unless something
   cross-cutting depends on its exact output: determinism (rand),
   security (crypto, regex's linear time), or the toolchain.
5. **Protocols are the part that rots.**

**What ends up privileged anyway.**

- The primitive types and their operations (all).
- The allocator, or how the heap is reached (Rust's
  `#[global_allocator]`, Roc's host `malloc`, Zig's interface, Ren's
  `Alloc`).
- The entry point, which holds every initial capability (Zig's
  `process.Init`, Eio's `Eio_main.run`, Roc's host `main`, Ren's
  `main` installing the runtime).
- A debug print that skips the discipline (Eio's `traceln`, Rust's
  `dbg!` to stderr, Ren's `dbg`).
- The hash seed and other per-process randomness that collections use
  (Rust's `RandomState`, Python's `PYTHONHASHSEED`, Ren's `Map` seed).
- Optimizer knowledge of std's names (Swift `@_semantics`, Rust
  specialization in std). This one is avoidable, and only Zig and Roc
  avoid it.

**How big std should be for a CLI, a server and a storage engine.**
Go's size for the shared types and the world; Rust's size for
everything that names a protocol. Concretely: the world interfaces and
their fakes; bytes, strings, time, decimal, collections; the
determinism-critical algorithms (hashing, random, unicode, math);
`json`, `toml`, `csv`, `url`, `base64`; HTTP/1.1 types, server and
client; TLS and crypto; `log` and `trace`; `cli` and `config`; `test`
and `sim`. A storage engine needs `Fs` with `fsync` semantics, a
simulated `Fs` with torn writes, checksums and compression. It doesn't
need Postgres or HTTP/2.

---

## Pressure-testing decision 20 and stdlib.md

**Rule 1 (no media, no protocols) holds.** Every language surveyed
keeps protocols out of the language. Ren's exceptions, `Bytes`,
`Decimal`'s `d` and `Duration`'s `30.s`, are literals, and the
literal argument is the one Swift and Rust use too.

**Rule 2 (std has no powers a user library lacks) holds on powers and
has four unlisted holes.**

1. **`Map` and `Set`'s seed.** stdlib.md:175: a map "hashes its keys
   with a fast hash mixed with a seed drawn when the process starts
   (fixed under `ren test` and `ren replay`)". That's randomness
   outside `Random`, and a test and replay switch, that no user
   collection can get. A third party's hash trie must either take
   `Random` in its row or be attackable. Either expose the seed as a
   runtime value any library reads ambiently (and list it), or have
   `Map` take it from `Random` like everyone else.
2. **`dbg`.** module-build.md:255: it "works anywhere". It's a world
   effect without `Console`. Fine, Eio does the same, but it belongs in
   the list with its reason (compiled out in release, refused in CI).
3. **Optimizations keyed to std.** Rule 4 makes them invisible. Rule 2
   should also make them general. Swift's 268 `@_semantics` tags show
   where this goes without such a rule.
4. **Features only std may use.** Rust's std is built with nightly
   features. Ren has `trust` and `foreign fn`, open to all. Say so in
   rule 2: std is compiled with exactly the language users get.

`Instances` is "ambient, so no `uses` names it" (stdlib.md:378), and
it's on decision 20's runtime list. That's consistent. But the
boundary audit's point stands: every ambient runtime power should
appear in that one list, with nothing else ambient.

**The world list holds, and needs its criterion.** Zig's list (files,
dirs, net, DNS, clock, entropy, processes) matches Ren's. Zig closed
theirs with a rule: blocks or introduces nondeterminism. Ren's
determinism test is that rule. Write it into decision 20 so the next
candidate (a GPU, a hardware RNG, `Tty`) is placed by the rule, not by
amending the list. Also, stdlib.md's layer table lists deps as `Fs,
Net, Clock, Random, Console, Alloc, Async, Os`. It's missing `Proc`
and `Signal`, which decision 20 has.

**Rule 3 (the compiler's knowledge) holds,** and the list will grow.
Rust's lang items now number over 150 and grew with each construct (`?`, `async`, `for` over `IntoIterator`). Ren's reserved
names already took on the cursor protocol and the stream stage names.
The prelude table in module-build.md, "what constructs turn into", is
the honest form of this. Keep that table as the single list, and
derive rule 3's list from it.

**"Three implementations and one conformance suite" holds for the
world and breaks at scale.** No other language does it. Zig ships only
`Io.failing`, Eio ships mocks, Rust nothing. It's Ren's real
differentiator, and it costs a sim implementation per dependency.
stdlib.md already caps infrastructure types at four. Apply the same
cap to the services layer: `sql`, `http` and `dns` need sims.
`metrics`, `schedule` and `cache` are plain Ren over `Clock` and need
none.

**The inventory is too big for the promise.** stdlib.md, Part 5 puts
these in std: `postgres`, HTTP/2, the OTLP exporter, `metrics`,
`sqlite`, `dns`, `csv`, `cli`, `config`, `retry`, `schedule`, `cache`,
tar, gzip and zstd. By the Python and Go evidence, the protocol ones
(postgres's wire protocol, HTTP/2, OTLP) are the ones that freeze or
die. The "toolchain" test is the weakest of the five. Cargo uses
crates rather than std for TOML and HTTP. It ties std's
promise to the toolchain's needs. A toolchain can depend on `std.x`
packages pinned by the toolchain release.

**Missing.**

- How a type keeps its identity when it moves between `std.x` and
  `std` (Go's `context`, Unison's hashes).
- A statement that driver capability is checked. A program whose row
  has `Fs`, built for a hosted driver with no files, is refused at
  build time (Roc's platform guarantee).
- A rule for `Alloc` in unchecked packages that doesn't recreate
  `no_std` as a package flag.

---

## What Ren should take

1. **The criterion for the world list:** "a world dependency is
   anything that blocks or can differ between two runs" (Zig 0.16,
   Eio's determinism note). foundations.md, decision 20, rule 2,
   before the list.
2. **Name the unlisted privileges:** the `Map`/`Set` seed and `dbg`,
   each with its reason, or make the seed a value any library can
   read. foundations.md, decision 20, rule 2; stdlib.md, "`x.hash()`,
   and a map's own hash".
3. **Two sentences in rule 2:** std is compiled with the language users
   have, no feature only std may enable (Rust's nightly std). No
   optimization is keyed to a std declaration (Swift `@_semantics`).
   foundations.md, decision 20, rules 2 and 4.
4. **Promotion keeps identity:** a module promoted from `std.x`
   re-exports the same declarations, so its types don't change (Go 1.9
   aliases, Unison). stdlib.md, Open questions (std.x versioning);
   module-build.md, wherever declaration identity is defined.
5. **Infer `Alloc` everywhere:** `ren.toml` decides only whether a
   public signature must write it. Then no package counts as allocating
   just because it was unchecked (Rust's `no_std` split). stdlib.md,
   "Settled" paragraph.
6. **Move protocols out:** `postgres`, HTTP/2 and the OTLP exporter to
   `std.x` for 1.0, unless flottning needs them. Drop the toolchain
   test, or let it pull in `std.x` packages instead of std (Python PEP
   594, Go `net/smtp`, Lean's `Std.Http`). stdlib.md, Part 1 "The
   tests" and Part 5.
7. **Size each world `D.Call` against Zig's vtable:** about 51
   operations across dirs, files, net, time, entropy and processes
   (`Io.zig:563-710`). runtime.md, "Drivers are Ren"; runtime-io.md.
8. **Build refuses a row the driver can't answer** (Roc's platforms).
   runtime.md, the hosted driver.
9. **Keep the sim requirement only where a dependency touches the
   world.** Services that are plain Ren over `Clock` get their sim from
   `sim.clock`. stdlib.md, "Three implementations, one conformance
   suite".

## What Ren should not take

1. **Capabilities as values** (Zig `Io`, Eio `env`). Same power as
   rows, but coarse (one `Io` grants all), hand-plumbed, storable in
   structs, and with real I/O as the test default. Ren's rows and
   `with` are better on each count. deps.md, opening, needs no change.
2. **A scheduler fused with its driver** (Zig's `Io` implementations,
   Eio's backends). It's why only `Io.Threaded` is complete. Keep
   runtime.md's split: a closed set of schedulers, open drivers over
   `Async.submit`.
3. **Zig's `async` vs `concurrent` split.** Zig needs it because a
   blocking single-threaded `Io` can't interleave. Every Ren scheduler,
   `single` included, has frames, so concurrency is always available.
   async.md needs nothing.
4. **The world as type labels without handlers** (Koka's `fsys`,
   Effekt's `at io`, Unison's `IO`). It records the effect and loses
   the fakes. deps.md rule 2 stays.
5. **A platform per application** (Roc). It ties every I/O package to
   one platform hash. Ren's std-declared world interfaces avoid it.
   Keep `dep Fs` in std.
6. **A small std that leaves the runtime and shared types to the
   ecosystem** (Rust, Gleam). The splits it caused are exactly in
   those two places. stdlib.md rule 1 stays.
7. **Batteries for protocols** (Python). Ren's `std.x` exists for
   this, so use it more, not less.

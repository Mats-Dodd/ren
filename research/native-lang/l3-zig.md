# L3: Zig as the language of Ren's runtime core and drivers

Track L3 of the native-language question (C, Rust or Zig). It covers Zig as
the language of the scheduler core and drivers, and `zig cc` as a C toolchain
Ren could bundle. All measurements were taken on 2026-10-29 on this machine
(Apple M-series, macOS 15, Darwin 24.1), with Zig 0.17.0 run through
`mise exec zig@0.17.0` (no mise config written), Apple clang 16.0.0 and
tcc 0.9.28rc. The scratch files are in
`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/zig/`.
Anything marked *(unverified)* comes from memory and was not checked.

## 0. The constraint that decides most of this

Emitted C calls about 103 `static inline` functions in `ren_rt.h`
(`grep -c "static inline"`), such as `ren_dup`/`ren_drop` (ren_rt.h:440, 464),
`ren_array_get` (735) and the bounds and overflow checks (1049, 1494). They
are inlined because they are *C source in the same translation unit*:
- In a **debug build**, each unit (`ren_u0.c` and the others) does
  `#define REN_UNIT` / `#include "ren_rt.h"`, and tcc compiles it
  (lib/native/cc.ml:1-9).
- In a **release build**, one C file holds the header, then ren_rt.c, then
  the program (ren_rt.h:23-28), and clang -O2 inlines across all of it.

No language other than C can supply these bodies to tcc. Zig cannot emit a C
header containing function bodies: `-femit-h` silently writes nothing (§3.2).
Zig's C backend (`-ofmt=c`) writes C that tcc rejects (§3.3). So **the hot
inline paths stay C in any plan**. The real question for Zig is only (b): the
scheduler core, the drivers, and the cold half of ren_rt.c.

## 1. Stability: Zig is still pre-1.0 and still breaking things

| Release | Date | What broke (from the release notes) |
|---|---|---|
| 0.15.1 | Aug 2025 *(date unverified)* | "Writergate": every `std.io` reader and writer replaced, called "extremely breaking". The `async`/`await` keywords and `@frameSize` removed. `usingnamespace` removed. `ArrayList` unmanaged by default. `BoundedArray` removed. [notes](https://ziglang.org/download/0.15.1/release-notes.html) |
| 0.16.0 | 2026 | `std.Io` added: anything that may "block control flow" or introduce "nondeterminism" now takes an `Io`, and the fs and process APIs moved onto it. `Io.Threaded` is complete. `Io.Evented` (green threads), `Io.Uring` and `Io.Kqueue` are experimental or proof-of-concept, and `Io.Uring` has no networking. `@cImport` deprecated. [notes](https://ziglang.org/download/0.16.0/release-notes.html) |
| 0.17.0 | ~Oct 2026 ([zeli.app](https://zeli.app/story/49938521)) | `@cImport` **removed**: verified, `error: invalid builtin function: '@cImport'`. translate-c moved to an external package with "an independent release cadence". `@bitCast` semantics changed in a way that "has the potential to break existing code without triggering a compile error". `containsAtLeastScalar` swapped its arguments, so old calls compile and behave wrongly. `std.builtin` became `std.lang`. ZLS doesn't work with 0.17 yet. [notes](https://ziglang.org/download/0.17.0/release-notes.html) |

The 0.17 roadmap to 1.0 still lists "complete and stabilize the language",
"remove the LLD dependency", "move from a library dependency on LLVM to a
process dependency on Clang" and "audit the standard library". No date is
given. The 0.15 notes say: "Zig has known bugs, miscompilations, and
regressions", and a bug policy applies only from 1.0.0.

The best evidence from people living with this:
- **TigerBeetle** pins Zig exactly, with a comptime check, and is still on
  0.16.0 although 0.17.0 has shipped:
  `/tmp/ren-refs/tigerbeetle/build.zig:53-70`
  (`@compileError("unsupported zig version ...")`). It also carries its own
  `stdx` layer, `src/io/linux.zig:12` (`const posix = stdx.posix`), so that
  churn in `std` stops at one boundary.
- **Roc** (the Zig rewrite) declares `minimum_zig_version = "0.17.0"`
  (`/tmp/ren-refs/roc-zig/build.zig.zon:4`) and ships a `src/zig-0.17.nix`.
  It tracks each release.
- Roc's older Rust-era builtins README still says `callconv(.C)`
  (`/tmp/ren-refs/roc-rust/crates/compiler/builtins/bitcode/README.md`).
  Today it is `.c` (translate-c output above uses `callconv(.c)`), which shows
  even the ABI spelling has changed.

For Ren this matters more than it would for an application. Ren is itself a
moving language project with one owner, and a Zig runtime would add a second
moving language, upgraded about every 5-8 months, and an editor (ZLS) that can
lag a release. The async story was removed in 0.15 and is coming back as a
library (`std.Io`) whose evented/io_uring backends are still proofs of
concept. Ren wouldn't use `std.Io` anyway: its runtime is sans-I/O and the
host owns threads. But it shows how much of Zig's I/O surface is still being
redesigned.

## 2. Experiments

### 2.1 `zig cc` as the debug-build compiler (to replace tcc): no

I captured the units of a real debug build (`bench/10d/router.ren`, through a
`REN_CC` wrapper that runs tcc and copies the units) and timed each compiler
on them with hyperfine. Each run changed the content with a nonce, which
defeats zig's cache.

| unit | tcc | clang -O0 (Apple 16) | zig cc -O0 (clang 22.1.8) |
|---|---:|---:|---:|
| empty file (fixed cost) | 3.7 ms | 40.5 ms | **127.4 ms** |
| `ren_u0.c` (403 lines plus the 2085-line header) | 5.4 ms | 75.9 ms | **186.8 ms** (34.5x tcc) |
| `ren_rt.c` (2803 lines) | 10.8 ms | 131.1 ms | **394.1 ms** (36.5x tcc) |

Zig's default `-fsanitize=undefined` at -O0 accounts for little of this: with
`-fno-sanitize=all` the unit takes 176 ms, and adding `-g0` gives 161 ms. Most
of the cost is fixed per process: about 127 ms to start the zig binary and do
its cache bookkeeping, before any compiling. A cache *hit* was still 77-86 ms,
15 times a tcc *miss*. So `zig cc` is **2.5-3x slower than clang -O0 and 35x
slower than tcc** per unit. That undoes decision 13's tcc result
(foundations.md ~721-741). **zig cc cannot replace tcc.**

### 2.2 `zig cc` as the release compiler and cross toolchain: plausible, and the real attraction

Release, `router` as one 5795-line C file, -O2, linked:

| | clang -O2 (Apple 16) | zig cc -O2 |
|---|---:|---:|
| native macOS | 501 ms | 759 ms (1.5x) |

Cross-compiling the same file from this Mac with nothing else installed:

| target | first build (builds libc and caches it) | warm | result |
|---|---:|---:|---|
| x86_64-linux-gnu | 2.22 s | | ELF x86-64, dynamic, glibc |
| aarch64-linux-gnu | 2.28 s | | ELF aarch64, dynamic, glibc |
| x86_64-linux-musl | 11.85 s | 0.76 s | ELF static |
| aarch64-linux-musl | 12.27 s | | ELF static |
| wasm32-wasi | 6.85 s | 0.69 s | wasm module; it ran under node's WASI and printed `error: couldn't start the program's thread`, the `pthread_create` at ren_rt.c:2794 |

This is Zig's real offer to Ren: a single ~60 MB download is a hermetic C
toolchain with libc headers and libcs for every target flottning needs
(Linux gnu and musl, x86_64 and aarch64), plus wasm32-wasi. It works with
Ren's runtime written **in C**. The WASM failure is the existing runtime
creating its own thread. The planned C ABI ("the runtime never creates
threads"; the host calls `ren_run`) removes that, whatever language the core
is in.

I could not run the Linux binaries: the OrbStack docker daemon was down and I
didn't start it.

### 2.3 Zig object linked into C: works with clang and ld64, **not with tcc on macOS**

`ffi/core.zig` is a toy ready-ring with `export fn ren_core_push/pop`. It also
calls `ren_dup`, `ren_array_len` and `ren_drop` through translate-c's
`ren_rt.h`. Results:
- clang + ld64 links it and runs it (prints `100`).
- **tcc refuses it on macOS: `tcc: error: core.o: unrecognized file type`.**
  tcc on Darwin writes *ELF* relocatables (`file units/o_tcc.o`: "ELF 64-bit
  LSB relocatable, ARM aarch64") and links them with its own linker. It cannot
  read Mach-O objects or archives from Zig, clang or rustc.
- It works as a dylib: `zig build-lib -dynamic` → `tcc main.c -lcore` → runs.

So on macOS debug builds, a non-C runtime has to ship as a `.dylib` (or tcc
must learn Mach-O). This applies **equally to Rust**, so it does not decide
between Zig and Rust. It is a cost of leaving C. On Linux, tcc can link ELF
`.a` files from other compilers *(unverified for Zig's TLS and
relocations; I couldn't run Linux here)*.

### 2.4 Cross-language LTO

`zig build-obj -flto` makes LLVM bitcode, and `zig cc -flto` links it with
the C. On the x86_64-linux-musl target, calls from `main` (C) to
`ren_core_*` (Zig) dropped from 7 to 2: `push` inlined, `pop` internalized
(`objdump` on `m_l-flto`). Limits:
- **macOS: `error: LTO requires using LLD`.** Zig's own Mach-O linker can't
  do LTO, so there is no cross-language LTO on the dev platform.
- Bitcode from Apple clang 16 could not be combined with Zig's LLVM 22
  (`ld.lld: ... incompatible`). Cross-language LTO means compiling the
  emitted C with **zig cc** (the same LLVM) too. Rust has the same rule:
  rustc's LLVM must match clang's.

### 2.5 translate-c on `ren_rt.h`

`zig translate-c -lc ren_rt.h` succeeded and wrote 9602 lines.
- It translated all 223 `ren_*` functions, the static inlines among them,
  into Zig `callconv(.c)` functions. For example, `ren_dup` is at
  `rt_translated.zig:2099`, with `__builtin_expect` mapped to `__builtin.expect`.
- What failed is the macro layer: `REN_STACK_CHECK`
  (`__builtin_frame_address`), `REN_SIZED_ARRAY`, the `ren_buf_set_*` and
  `REN_NARROW` statement-expression macros, and `REN_INLINE`. Each became a
  `@compileError` stub that only fails when used.
- Since `@cImport` is gone, the workflow is a build step or a checked-in
  generated `rt.zig`, run with the external translate-c package.

Zig code *can* consume the C object model in place. In ReleaseFast the Zig
object referenced only `_ren_shared_count`, so the inlines inlined.

### 2.6 Headers from Zig, other backends, safety-mode cost

- **`-femit-h` writes nothing** in 0.17 (no file, no error). TigerBeetle
  writes its C header with a hand-written comptime generator,
  `/tmp/ren-refs/tigerbeetle/src/clients/c/tb_client_header.zig` (299 lines,
  a table of type → C name). Ren would do the same, or keep `ren_rt.h`
  hand-written as the source of truth and have Zig match it, with a test.
- **`-ofmt=c`** (Zig's C backend) on a 3-line function gives 73 lines that
  need `zig.h`, and tcc rejects it:
  `zig.h:2034: error: ';' expected (got 'zig_align_unavailable')`.
- **Safety-mode objects**: the same toy is 17 KB in ReleaseFast but 2.4 MB in
  ReleaseSafe and 3.1 MB in Debug. Those modes pull in the panic handler and
  the `std.debug` stack-trace machinery, and with them `_NSGetExecutablePath`,
  `__ulock_wait2`, `__tlv_bootstrap` and more. A runtime that wants
  ReleaseSafe's bounds and overflow checks without that has to override the
  root `panic` *(the mechanism is documented; I did not test the override)*.
- Building the toy for x86_64-linux-gnu, aarch64-linux-gnu and
  x86_64-windows-gnu took 7-9 s each, cold. That is a CI cost, not a user
  one: the runtime would be prebuilt for each target.

## 3. TigerBeetle's io/ as a reference driver design (language-neutral)

`/tmp/ren-refs/tigerbeetle/src/io/`: linux.zig 1896 lines (io_uring),
linux_epoll.zig 1406, darwin.zig 1223 (kqueue), windows.zig 1659 (IOCP),
common.zig 308. The simulator's IO is `src/testing/io.zig` (372 lines) plus
`src/testing/storage.zig` and `packet_simulator.zig`. What carries over to
Ren:
- **Completion-based, intrusive, caller-owned.**
  `Completion = struct { io, result, link, operation, context, callback }`
  (linux.zig:374-385). The caller owns the memory, so the hot path never
  allocates, and `prep` maps each operation to an SQE (386 onward). This is
  the shape of Ren's `ren_call`/`ren_reply`, written as data instead of a
  callback.
- **The backend is picked at compile time, not through a vtable.**
  `pub const IO = switch (builtin.target.os.tag) { .linux => IO_Linux, ... }`
  (src/io.zig:10). The whole replica is generic over its effects:
  `ReplicaType(StateMachine, MessageBus, Storage, AOF)` (src/vsr/replica.zig:144-148),
  which is how the simulator replaces real storage and network with
  deterministic fakes at zero cost. This is the part where comptime does
  real work. Ren's draft does the same with a runtime `ren_host *` table at
  the driver boundary, which is fine since drivers are not on the inline hot
  path.
- **Kernel feature floor checked at init**: it panics without
  `IORING_FEAT_EXT_ARG` (5.11), and logs seccomp/sysctl hints when io_uring is
  disabled (linux.zig:43-66). An epoll fallback is kept for clients
  (`ClientIO`, src/io.zig:20).
- TigerBeetle's own non-trivial blocking file work goes through `std.Io`
  (`io_std: std.Io`, linux.zig:32). So a 0.16 migration reached into the
  driver itself.

None of this design *needs* Zig. Ren's sans-I/O core plus host drivers can
copy it in C, with `#if` or link-time selection instead of `switch` on
`builtin.target`. What Zig adds is enforcement: comptime type parameters for
sim versus real, explicit allocators, `defer`/`errdefer`, and slices with
checked bounds in safe modes.

## 4. What Zig would buy the core and drivers, against C

**For Zig:**
- **Explicit allocators.** Every allocating std API takes an `Allocator`.
  That suits arenas, Mem.snapshot and a deterministic sim allocator, and fits
  the owner's "explicit over magic".
- **comptime generics over sim/real** (TigerBeetle's pattern) rather than
  hand-written C macros or vtables.
- **ReleaseSafe**: bounds, overflow, null and `unreachable` checks in a
  shippable build. C's nearest equivalent is UBSan in trap mode, and ASan
  isn't shippable.
- **`std.os.linux.IoUring`** is a maintained liburing port, so there's no
  liburing dependency. TigerBeetle uses it as `linux.IoUring`
  (linux.zig:5).
- The cross toolchain (§2.2), though Ren gets that from `zig cc` with a C
  runtime too.

**Against Zig:**
1. **Language and std churn before 1.0** (§1), including silent semantic
   breaks in 0.17. Ren would pin like TigerBeetle and pay a migration every
   release, in a second language the owner hasn't learned, on top of OCaml.
2. **Split runtime.** The hot inlines must stay C (§0), so the runtime
   becomes two languages across one ABI, `ren_rt.h` ↔ Zig, with no generated
   header (§2.6). Every shared struct (the object header, `ren_array`,
   `ren_str`, the reply and call records) is declared twice, or translated
   from C with a sync test.
3. **Toolchain friction on the dev platform.** tcc on macOS can't link a Zig
   `.a` (§2.3), so it becomes a dylib in debug. Cross-language LTO doesn't
   work on macOS (§2.4).
4. **Release single-TU inlining is lost** for whatever moves to Zig, unless
   release compiles the emitted C with zig cc and uses LTO, which works only
   on Linux. For the scheduler that is acceptable: its entries
   (`ren_run`/`ren_poll_call`) are called per batch, not per value.
5. **Users will later write drivers in Ren inside `trust`, and Ren compiles to
   C.** The longer-term runtime language is Ren-emitted C. A Zig layer would
   sit between the C the compiler emits and the C Ren itself becomes.
6. **Thin precedent for a runtime under a C-emitting language.** Roc's Zig
   builtins work because Roc feeds them as **LLVM bitcode** into its own LLVM
   module, so they inline
   (`/tmp/ren-refs/roc-rust/crates/compiler/builtins/bitcode/README.md`,
   "compile the result to LLVM bitcode, and import that bitcode into the
   compiler"). Ren's debug path is tcc, which has no bitcode input, so Roc's
   model doesn't carry over.

## 5. Where Zig fits without being the runtime language

- **`zig cc` as Ren's release and cross C toolchain** (optional, for
  flottning's Linux targets and WASM). Ren keeps tcc for debug, and uses
  clang or `zig cc` for release. The cost is 1.5x release compile time against
  Apple clang on macOS (§2.2), so use it for cross builds, not native ones.
  This needs no Zig *code* in Ren and doesn't depend on Zig language stability:
  `zig cc` is clang plus bundled libc. It also gives cross-language LTO later
  if parts of the runtime ever move to a language on the same LLVM.
- **TigerBeetle's io/ and simulator as the design reference** for the drivers
  and the sim/replay driver, written in C.

## Verdict for Ren

**(a) Hot inline paths emitted C calls: C.** Not a close call. They must be C
source that tcc compiles inside each unit and clang -O2 inlines in the release
TU. Zig can't emit a usable header (`-femit-h` is a no-op in 0.17), and its C
backend doesn't compile under tcc. Any non-C language here gives up
decision 13's 12-24x debug speed.

**(b) Scheduler core and drivers: C, not Zig, for now.** The strongest
reasons:
1. **The runtime would be split across two languages and one ABI.** The hot
   half has to be C (§0). A Zig core would declare the shared object layout
   twice, with no header generation, link to tcc on macOS only as a dylib,
   and have no cross-language LTO on macOS (§2.3, §2.4).
2. **Zig is pre-1.0 and still breaking, sometimes silently.** In three
   releases it removed `@cImport`, async and `usingnamespace`, rewrote I/O
   twice, and changed `@bitCast` silently in 0.17. TigerBeetle, the best Zig
   systems shop, pins exact versions and lags a release (§1). Ren is already
   a moving target.
3. **What Zig would give the core can be had in C at a known cost.**
   TigerBeetle's completion-based, sim-swappable driver design is not tied to
   the language (§3). Explicit allocators and sim/real selection are
   conventions plus link-time choice. ReleaseSafe's checks can be partly
   covered by C with UBSan in CI and sanitizers in `bench/build.t`. Ren's own
   `trust` drivers will compile to C anyway.

**Do adopt `zig cc`, as a toolchain, not a language:** it is the cheapest way
to get hermetic cross builds for flottning (linux gnu and musl, x86_64 and
aarch64) and wasm32-wasi from a Mac, all verified building here. Keep tcc for
debug: zig cc is 35x slower per unit (127 ms fixed per process), so it can
never be the debug compiler.

**Biggest risk of this verdict:** C gives no help in exactly where the core
will be hardest: a work-stealing scheduler, io_uring ownership, and
cross-thread refcount marking (negative counts, ren_rt.h:13-20). Bugs there
are memory and data-race bugs. Writing it in C means making TSan/ASan and the
deterministic sim driver part of CI *from the first scheduler commit*, not
later. **Revisit Zig at 1.0**, when a stable language and a Mach-O LTO linker
would remove reasons 1 and 2. If the comparison is C against Rust, Rust is
the only one of the two non-C options that is stable today; see l2-rust.md.

### Sources
- Zig release notes: https://ziglang.org/download/0.15.1/release-notes.html,
  https://ziglang.org/download/0.16.0/release-notes.html,
  https://ziglang.org/download/0.17.0/release-notes.html
- 0.17 release date: https://zeli.app/story/49938521
- Local: `/tmp/ren-refs/tigerbeetle` (0450c32, 2026-10-14),
  `/tmp/ren-refs/roc-zig` (7de4d5c, 2026-10-26), `/tmp/ren-refs/roc-rust`,
  `lib/native/runtime/ren_rt.{h,c}`, `lib/native/cc.ml`, foundations.md
  decision 13.

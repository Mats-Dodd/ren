# L1: what other language implementers wrote their runtime in

Track L1 of the C vs Rust vs Zig question. It surveys languages whose compilers emit code that calls a runtime, and asks three things of each: what the runtime is written in, how compiled code reaches the hot paths (refcounts, allocation, arrays, strings) without a call, and what the authors later regretted or rewrote.

Sources are cited by local clone path (`/tmp/ren-refs/<repo>`, commits as cloned in late October 2026) or URL. Claims from memory are marked **(unverified)**.

## 0. Ren's starting point

- `lib/native/runtime/ren_rt.h` (2085 lines, 103 `static inline` functions) is the hot path: `ren_dup`/`ren_drop` (lines 430, 450), `ren_alloc_ctor` (602), `ren_reuse` (644), and the array get/set/take family (735–872). Emitted C calls these directly. The fast path is written so a later shared (negative) count lands on a cold path (header comment, lines 1–27; `__atomic_*` at 405–481).
- `ren_rt.c` (2801 lines) is the cold path: `ren_free` (357), `ren_drop_shared` (377), array growth, string slicing, maps.
- The runtime ships **as source text inside the compiler**. `lib/native/emit_c.ml:2` embeds ren_rt.h and ren_rt.c as `Runtime_c`, and `lib/native/cc.ml:141` writes `ren_rt.c` out as its own unit. A release build is one translation unit (header + ren_rt.c + program, ren_rt.h:22–26), so clang -O2 sees all runtime code next to the program. A debug build compiles ren_rt.c with tcc as one more unit. So `ren build` needs only a C compiler. Nothing is prebuilt per target.

This last fact decides most of what follows. Any runtime not written in C stops being "source text compiled with the program". It becomes a **prebuilt per-target artifact** (a `.a` or `.bc`) that the compiler must ship and link.

## 1. Survey

### Lean 4: C header for hot paths, C++ for the rest (the closest match to Ren)

- `/tmp/ren-refs/lean4/src/include/lean/lean.h` is 3816 lines of pure C with 599 `static inline` functions, wrapped in `extern "C"` (line 37). The rest of the runtime is C++ (`src/runtime/*.cpp`; the thread pool is `class task_manager`, `src/runtime/object.cpp:762`).
- The fast/cold split is exactly Ren's. `lean_dec_ref` (lean.h:734) is `static inline LEAN_ALWAYS_INLINE`: it decrements when rc > 1 and otherwise calls the exported `lean_dec_ref_cold` (lean.h:731). Allocation works the same way: the inline `lean_alloc_small_object` (522) falls back to `lean_alloc_small_object_core` (515). Ren's header comment already cites lean.h for this design.
- For its LLVM backend, Lean compiles the inline header to bitcode, `lean.h.bc`, and links it into the module (`src/runtime/CMakeLists.txt:134–152`, built from `lean_inlines.c` with `-emit-llvm`). The cold implementation language (C++) never touches the hot path. The ABI between the two is C.
- **Lesson:** the implementation language of the cold runtime is independent of the hot path, provided the hot path is a C header. Lean has used C++ for the cold half for years with no stated regret **(unverified: I found no regret post; absence is weak evidence)**.

### Koka: kklib in C, header-inlined, unity build

- `/tmp/ren-refs/koka/kklib`: about 10.3k lines of C. `include/kklib.h` holds 130 `static inline` functions. `kk_block_drop` (kklib.h:764) is inline, and the shared/sticky/free cases go to `kk_decl_cold kk_block_check_drop` (745).
- `kklib/src/all.c` is a unity build that `#include`s every .c file, with mimalloc's `static.c` included first. This is the same move as Ren's single release unit.
- Koka emits C, which is also Ren's architecture. Its runtime stayed C through the Perceus/FBIP and multi-threaded refcount work.

### Pony: libponyrt in C, merged as bitcode

- `/tmp/ren-refs/ponyc/src/libponyrt`: C, including the work-stealing scheduler (`sched/scheduler.c`) and the ASIO thread (`asio/`).
- `CMakeLists.txt:259–261`: "Build runtime bitcode (libponyrt.bc) by default on clang. ponyc merges this into the program's IR before optimisation, enabling cross-module interprocedural optimisation between Pony code and the runtime." The loader is `codegen_merge_runtime_bitcode`, `src/libponyc/codegen/codegen.c:767`. If no .bc is found it falls back silently (`runtime_bitcode_merged = false`, 797).
- `SYSTEMATIC_TESTING.md`: deterministic, seeded interleaving of scheduler threads (copied from Verona). "Systematic testing does not run the ASIO thread", so I/O is outside the deterministic world. Ren's sans-I/O core with a sim driver is meant to close that gap. That is a design point, not a language one.

### Verona-rt: header-only C++

- `/tmp/ren-refs/verona-rt/src/rt/sched/`: every file is a `.h` (`core.h`, `workstealingqueue.h`, `threadsyncsystematic.h`, ...). The whole runtime is templates included into the program. This is the C++ form of "the runtime is source compiled with the program".
- Systematic testing is built in (`threadsyncsystematic.h`). Pony took it from here.

### OCaml 5 / OxCaml: C plus per-arch assembly

- `/tmp/ren-refs/oxcaml/runtime`: C, with `amd64.S`/`arm64.S` for fiber switches and C-to-OCaml transitions, `domain.c`/`domain_state.tbl` for multicore.
- Hot paths are not inlined from a header. The native backend emits minor-heap allocation and write-barrier fast paths itself and calls `caml_*` C functions for slow paths **(unverified from memory, consistent with `runtime/caml/domain_state.tbl` exposing young_ptr/young_limit to compiled code)**.
- The multicore retrofit (OCaml 5, 2022) kept C. Its cost was years of auditing runtime C for data races, not a language change **(unverified, from memory of the Retrofitting Effect Handlers / Parallelism papers)**.

### Inko: runtime in Rust, hot paths emitted by the compiler

- `/tmp/ren-refs/inko/rt` is a Rust crate built as `crate-type = ["staticlib", "lib"]` named `inko` (`rt/Cargo.toml`), about 6.8k lines. It holds the work-stealing scheduler (`src/scheduler/`), network poller (`src/network_poller/`), and TLS via rustls.
- Compiled code calls only about 13 runtime functions (`compiler/src/llvm/runtime_function.rs:5–19`): process new/yield/send, runtime start/drop, `malloc`, `free`, and error reporters. Refcount increments are **emitted as LLVM IR by the compiler** (`compiler/src/llvm/builder.rs:339` `atomic_add`; used at `passes.rs:1625, 2501`). So Inko's hot path is in neither Rust nor C: it is codegen.
- Context switching is hand assembly embedded through `global_asm!` (`rt/src/macros/mod.rs:26–28`, `rt/src/context/unix/x86_64.rs`). Rust did not remove the need for per-arch assembly.
- Unsafe is everywhere it matters. `rt/src/process.rs` has 22 `unsafe` sites and the scheduler's `process.rs` has 7. These are the memory-layout parts, where the borrow checker cannot help.
- Distribution cost: the compiler links a prebuilt `libinko.a` (`compiler/src/linker.rs:229–232`). Cross-compiling needs `inko runtime add TARGET` to download a runtime per triple (`docs/source/guides/cross-compilation.md:187–220`). Ren avoids this today.
- History: the runtime moved off a custom Immix allocator to the system allocator, and off reductions to compiler-injected preemption points ([Inko runtime docs](https://docs.inko-lang.org/manual/main/design/runtime)). Both are design simplifications made inside Rust, not language regrets.

### Roc: builtins in Zig as bitcode; then the whole compiler moved from Rust to Zig

- Old compiler (`/tmp/ren-refs/roc-rust`, Rust): builtins in Zig, `pub fn ... callconv(.C)`, compiled to LLVM bitcode and embedded in the compiler (`crates/compiler/builtins/bitcode/README.md`: "it's nicer to implement them in a higher-level language like Zig, then compile the result to LLVM bitcode, and import that bitcode into the compiler"). The LLVM backend inlines them. The dev backend calls them as plain functions.
- New compiler (`/tmp/ren-refs/roc-zig`, Zig, requires Zig 0.17.0 per `build.zig.zon:4`). It still embeds builtin bitcode per pointer width (`src/llvm_compile/compile.zig:153, 210`). For the dev backend it uses a static library, `src/builtins/static_lib.zig`, plus `dev_wrappers.zig`, whose header says the wrappers "decompose RocStr/RocList structs into individual fields so all arguments fit in registers and avoid platform-specific struct-passing ABI issues". That is a tax paid for calling a non-inlined, foreign-language runtime from a fast-path backend.
- Stated reasons for the rewrite ([Feldman's gist](https://gist.github.com/rtfeldman/77fb430ee57b42f5f2ca973a3992532f)): "Rust's compile times are slow. Zig's compile times are fast." On memory safety: "For many projects, Rust's memory safety is a big benefit. As we've learned, Roc's compiler is not one of those projects." On allocators: "We tend to pass around allocators for memory management (like Zig does, and Rust does not)." The gist also cites Zig's direct LLVM bitcode generation and static musl linking. The trigger was that the roadmap already required rewriting nearly every part. Coverage: [Rust Weekly](https://weeklyrust.substack.com/p/why-roc-is-moving-away-from-rust), [Zig SHOWTIME](https://buttondown.com/ZigSHOWTIME/archive/38).
- **Lesson for Ren:** Roc's builtins are the analogue of `ren_rt.h`. They stayed out of Rust even while the compiler was Rust, because builtins must be inlinable into generated code, and a C-ABI language that emits bitcode does that cleanly.

### TigerBeetle: Zig for io_uring, static allocation and deterministic simulation

- `/tmp/ren-refs/tigerbeetle/src/io/{linux,darwin,windows,linux_epoll}.zig`: one completion-based IO interface over io_uring, kqueue and IOCP, plus an epoll file. That is the driver set Ren plans. Simulation is a separate IO and time implementation.
- Reasons, from the creator's 2025 post ([TigerBeetle blog](https://tigerbeetle.com/blog/2025-10-25-synadia-and-tigerbeetle-pledge-512k-to-the-zig-software-foundation/), quoted through search results): Rust's default at the time (2020) was to crash on OOM, while TigerBeetle wanted explicit static allocation (NASA Power of Ten). The borrow checker "made less sense for TigerBeetle". The post concedes some bugs "would have been prevented by the borrow checker" but were "caught by our fuzzers and online verification".
- Cost of a pre-1.0 language: TigerBeetle pins Zig 0.16.0 (`zig/download.ps1:4`). The new `std.Io` interface is already threaded through `src/io/linux.zig` (`io_std: std.Io`). Zig 0.15 alone removed `usingnamespace` and async/await, and redid all of std.io ("These changes are extremely breaking", [0.15.1 notes](https://ziglang.org/download/0.15.1/release-notes.html)).

### Bun: Zig, then rewritten in Rust (2026)

- Bun was about 535k lines of Zig. In 2026 it was ported to Rust, mostly by coding agents, in about four months ([InfoQ](https://www.infoq.com/news/2026/09/bun-ai-rewrite-zig-rust-4-months/); primary: [bun.com/blog/bun-in-rust](https://bun.com/blog/bun-in-rust), linked from [Simon Willison](https://simonwillison.net/b/9540)).
- Stated reason: many bugs were "use-after-free, double-free, and 'forgot to free' in an error path", and "Compiler errors are a better feedback loop than a style guide." Sumner called mixing a GC (JSC) with manual memory management something "no language is designed for". The InfoQ figures are second-hand: v1.4.0 fixed 128 long-standing bugs, and memory over 2000 `Bun.build()` calls plateaued at 609 MB instead of climbing past 6.7 GB.
- Counterpoint: Andrew Kelley argued that bugs are removed by engineering effort, and asked "What happened to the test suite being sufficient to catch everything?" (same InfoQ article).
- **Lesson:** the most prominent large Zig runtime moved to Rust, and the reason was lifetime bugs across a sprawling, heap-heavy, error-path-heavy codebase. Ren's planned runtime is small and has an explicit ownership discipline (refcounts, arenas, a sans-I/O core with no callbacks), which is closer to TigerBeetle's shape than Bun's.

### Go: runtime in Go plus assembly

- `/tmp/ren-refs/go/src/runtime/HACKING.md` documents a dialect of Go just for the runtime: `//go:nosplit` (1033 uses across runtime/*.go), `systemstack`, `//go:nowritebarrier`, `//go:linkname`. The runtime was translated from C to Go for Go 1.5 **(unverified date, from memory)**.
- **Lesson for the "drivers in Ren inside `trust`" plan:** writing a runtime in your own language works, but it needs a restricted sub-language with compiler-enforced rules (no stack growth, no write barrier, no preemption). Go's directive list is that sub-language. If Ren goes this way, `trust` will need equivalents.

### Swift: C++ runtime, with executors moving into Swift

- `/tmp/ren-refs/swift/stdlib/public/Concurrency`: the executor core is in C++ (`GlobalExecutor.cpp`, `ExecutorImpl.cpp`), but newer executors are in Swift (`CooperativeExecutor.swift`, 2025 copyright, `@available(StdlibDeploymentTarget 6.3, *)`, with `PlatformExecutorLinux.swift` and others). Swift is moving the scheduler layer from the implementation language into the source language, the same direction as Ren's `trust` drivers.

### BEAM / Gleam, Mojo

- ERTS is C. The JIT (BeamAsm) is C++ on asmjit (`/tmp/ren-refs/otp/erts/emulator/beam/jit/*.cpp`). Gleam targets BEAM/JS and has no native runtime of its own.
- Mojo: runtime and async runtime are closed-source C++ on MLIR **(unverified)**. Not usable evidence.

## 2. How compiled code reaches hot runtime paths: the four patterns

| Pattern | Who | Works with tcc? | Needs matching toolchain? |
|---|---|---|---|
| **C header of `static inline`** + cold runtime in anything with a C ABI | Lean (C++ cold), Koka (C), Ren today | Yes | No |
| **Runtime merged as LLVM bitcode** | Pony (C→.bc), Roc (Zig→.bc), Lean's LLVM backend (`lean.h.bc`) | No | Yes, the LLVM version must match the consumer |
| **Compiler emits the hot path itself** | Inko (atomics in IR), OCaml (alloc fast path) | Yes, if the backend emits it | No |
| **Header-only runtime in the same language** | Verona-rt (C++ templates), Go (same compiler) | n/a | n/a |

The Rust-specific version of pattern 2 is cross-language LTO. It requires `-Clinker-plugin-lto` and lld, and "Best results are achieved by using a `rustc` and LLVM compilers that are based on the exact same version of LLVM", with a compatibility table pairing Rust 1.91–1.94 with clang 21 ([rustc book](https://doc.rust-lang.org/rustc/linker-plugin-lto.html)). For Ren that means release builds tied to a specific clang per rustc release, and nothing for tcc debug builds. Zig's `.bc` route has the same LLVM-version coupling.

**No surveyed implementer puts its refcount/alloc fast path in Rust or Zig behind a function call.** Those that use Rust or Zig either have the compiler emit the hot path (Inko) or ship bitcode to an LLVM backend they control (Roc). Ren has neither: it emits C and uses tcc.

## 3. Regrets and rewrites, summarised

| Project | Move | Stated reason | Applies to Ren? |
|---|---|---|---|
| Roc compiler | Rust → Zig | compile times; allocator-passing style; memory safety "not a big benefit" for a compiler; Zig's LLVM bitcode emission | Weakly. That was the compiler, and Ren's compiler is OCaml. Builtins were Zig all along. |
| Bun | Zig → Rust | UAF, double-free, leaks on error paths across a 500k-line runtime | Partly. This is the risk for a growing C or Zig scheduler and driver layer. |
| TigerBeetle | chose Zig over Rust | static allocation, OOM control, the borrow checker a poor fit for intrusive, pre-allocated structures | Yes for drivers and the journal: same io_uring and DST shape. |
| Go | C → Go | one language, so the GC can see the runtime **(unverified)** | It foreshadows `trust` drivers in Ren. |
| Swift | C++ → partly Swift | executors as library code | Same direction as `trust` drivers. |
| Inko | stayed Rust; dropped Immix and reductions | simplicity | Rust worked for a small scheduler/poller runtime with an emitted hot path. |
| Lean, Koka, Pony, OCaml | stayed C/C++ | (no regrets found) | Precedent for C headers plus a C/C++ cold runtime. |

## 4. What this means for Ren

**Take:**
- Lean/Koka's split: a C header of inline fast paths, with a cold runtime behind a C ABI. Ren already has it, and the C ABI is what frees the choice of language for the cold half.
- Inko's small surface: about 13 functions between compiled code and the scheduler. Ren's draft ABI (`ren_start`, `ren_run`, `ren_poll_call`, `ren_reply`, `ren_poll_deadline`) is the same size, so the scheduler core could be swapped to another language behind it without touching emitted code.
- TigerBeetle's IO shape: completion-based drivers behind one interface, plus a sim implementation. This shape is language-independent.

**Refuse:**
- Moving `ren_rt.h` fast paths out of C. Every pattern that does so needs LLVM bitcode or compiler-emitted IR, and tcc debug builds can use neither. It would also end "the runtime is source text in the compiler" (`emit_c.ml:2`), and Ren would start shipping per-target `.a` files the way Inko does (`inko runtime add`).
- Basing the language decision on Roc's rewrite. Its reasons were about a compiler's build times, and Ren's compiler is OCaml.

**Still to decide (and measure):**
- Whether the **scheduler core and drivers** go in C, Rust or Zig behind the C ABI. The precedent cuts both ways: Inko's Rust scheduler worked, TigerBeetle's Zig io_uring works, and Bun shows a large Zig codebase leaking and use-after-freeing. Suggested experiment: write the same small sans-I/O work-stealing core (deque, injector, timer heap, `ren_run`/`ren_poll_call`) in C and in Rust (`no_std` + `alloc`, `panic=abort`, staticlib), linked into one Ren program. Measure (1) `ren_run` overhead per task, (2) added link time and binary size in debug (tcc) and release, (3) how many `unsafe` blocks the Rust needs, (4) what a sim/replay driver costs in each.
- Distribution. A C runtime ships as source. Rust or Zig means prebuilt `.a` files per target triple (macOS arm64/x86_64, Linux x86_64/aarch64 gnu+musl, wasm32) or bundling rustc/zig with Ren. A Zig compiler bundled as `zig cc` would double as the release C compiler and cross-linker, which is a real point in Zig's favour **(unverified that this suits Ren's needs; worth an experiment)**.
- Stability. Zig is pre-1.0, with breaking std changes each release (0.15 std.io and async removal, 0.16 `std.Io`). TigerBeetle and Roc pin exact versions and absorb that churn. Rust is stable, at the price of LLVM-version coupling, which matters only if LTO is wanted.
- `trust` drivers. Go and Swift show the runtime eventually moving into the source language. Whatever is chosen now is an interim layer under the C ABI. That favours the cheapest, most transparent option for the interim, and an ABI that Ren-in-`trust` can implement later.

## Verdict for Ren

**(a) The hot inline paths that emitted C calls: C. This is not close.** Every surveyed implementer with a fast path reachable from generated code puts it in a C header (Lean, Koka, Ren), in bitcode for an LLVM backend it owns (Pony, Roc), or in compiler-emitted IR (Inko). Ren emits C and debug-builds with tcc, so only the C header works. Keeping C also keeps the one-unit release build that clang -O2 optimises across, and keeps the runtime as source text shipped in the compiler with no per-target artifacts.

**(b) The scheduler core and drivers: C, behind the draft C ABI, for now.** Reasons:
1. Lean, Koka, Pony, OCaml and Verona run schedulers and multicore runtimes in C/C++ with no regrets on record. Inko shows Rust also works, but its context switch is still assembly and its process and scheduler code is full of `unsafe`.
2. Moving to Rust or Zig adds a second toolchain and per-target prebuilt libraries. Ren pays nothing for either today.
3. The ABI is about five functions (Inko's is about 13), so the decision can be reversed. A Rust or Zig core can replace the C one later without touching emitted code, and Ren-in-`trust` is the long-term replacement anyway (the Go and Swift direction).
4. The planned core is small and sans-I/O, without callbacks, which is TigerBeetle's shape rather than Bun's.

**Strongest counter-reason:** Bun's 2026 move from Zig to Rust over use-after-free, double-free and error-path leaks. A work-stealing deque, a journal and io_uring buffer ownership are exactly where C bugs live. The defence is Ren's own: a deterministic sim driver, systematic testing in the Pony/Verona style, and sanitizers. That defence has to be built, not assumed.

**Biggest risk:** the scheduler and driver layer could grow past "small" (IOCP, JSPI, journal, keyed instances, arenas) before `trust` drivers exist, leaving Ren with a Bun-sized C codebase and no borrow checker. Mitigation, to measure: build the work-stealing core in both C and Rust (`no_std`, staticlib) behind the same ABI, compare per-task overhead, binary and link cost, and the `unsafe` count, and decide on that evidence. If Rust's `unsafe` covers most of the core anyway, as in Inko's `process.rs`, its safety gain is small and C stands.

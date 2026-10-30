# Native runtime language: C, Rust or Zig. Synthesis

This synthesis draws on four tracks in this folder:
- `l1-prior-runtimes.md`: what other language implementers wrote their runtimes in.
- `l2-rust.md`: Rust behind a C ABI, with seven experiments.
- `l3-zig.md`: Zig as a language and `zig cc` as a toolchain, with experiments.
- `l4-c.md`: C done properly, plus an audit of what must stay C.

I re-checked the citations that drive the recommendation myself (§5). Claims the tracks took from memory keep their *(unverified)* marks.

## 1. The real decision

"C, Rust or Zig" is really three separate decisions, plus a toolchain question.

| Layer | What it is | Size today | Status |
|---|---|---|---|
| **A. Hot inline header** | `static inline` functions, macros and struct layouts in `ren_rt.h` that emitted C calls directly: refcounts, the allocator fast path, arrays, bytes, checked arithmetic, NaN, evidence lookup, the stack check | ~980 lines must be C text (l4 §1.2); 103 `static inline` functions | **Settled: C.** All four tracks agree. |
| **B. Warm out-of-line runtime** | `ren_free`, maps and hashing, array growth and push, strings, `ren_install` | ~1,300 of the ~2,300 code lines in `ren_rt.c` (l4 §1.3) | **C by default.** clang inlines these today because a release build is one translation unit. Moving them behind an opaque ABI has a cost nobody has measured (l4's experiment E1). |
| **C. Scheduler core and drivers** | the deque, injector, timers, op table, `ren_start/run/poll_call/reply/poll_deadline`, kqueue/io_uring/epoll/replay/sim drivers, the blocking pool, the journal | not written yet; expected to be 2-5k lines (l2 §6, l4 §4.2) | **The only open question.** |
| Toolchain | which C compiler builds release and cross builds | clang today | Separate from the language question. `zig cc` works as a cross toolchain even if the runtime is written in C (l3 §2.2). |

So the decision is about layer C: what language the stage 11b/13 core and drivers are written in, behind a five-function C ABI that keeps the choice reversible (l1 §4, l2 Verdict).

**A constraint none of the tracks put together:**
- On macOS, tcc can link only objects that tcc itself compiled. I re-ran this (§5). tcc writes ELF relocatables, rejects a clang-built Mach-O object with `unrecognized file type`, and `ld` rejects tcc's objects with `unknown file type`.
- l2 and l3 found this as a cost of Rust and Zig, which would need a runtime dylib for macOS debug builds.
- But l4's "C done properly" plan has a scheduler unit "always compiled by clang -O2 and cached" (l4 §2.6 item 1). That unit hits **the same wall**: in a macOS debug build it would also have to ship as a dylib.

So once lock-free code must not be compiled by tcc, C loses its "debug builds need only tcc" advantage too, for the scheduler unit. C keeps it only if one of these holds:
1. tcc compiles the core in debug builds. tcc's atomics, CAS and fences pass a smoke test (l4 §1.4; re-run in §5), but nobody has checked whether tcc compiles a lock-free core correctly.
2. Debug builds always run the `single` or `deterministic` scheduler, and the work-stealing core is only ever compiled by clang for release. This fits the runtime model, where the language owns meaning and the runtime owns timing, ordering and placement. But it means real parallelism is never exercised in a debug build.
3. A dylib, which removes the language difference for this unit.

This narrows the gap between C and the other two for layer C. It does not close it: C still has one source of truth for layouts, needs no second toolchain, and has the path toward drivers written in Ren.

**A second constraint that holds whatever the language** (l4 §1.4; re-run in §5):
- tcc on macOS arm64 segfaults on any `_Thread_local` access.
- `ren_heap` becomes thread-local under `REN_THREAD_LOCAL` (`ren_rt.h:390, 534`).
- So header code must take an explicit per-worker context, never TLS.

## 2. Comparison

| | C | Rust | Zig |
|---|---|---|---|
| **Inlining into emitted C, tcc debug** | Yes. The header is compiled into every unit (`cc.ml:1-9`). | Never. tcc can't inline across languages. Calling Rust from tcc needs a dylib on macOS (l2 E2). | Never. `-femit-h` writes nothing, and the `-ofmt=c` output fails under tcc (`zig.h:2034`) (l3 §2.6). |
| **Inlining, clang -O2 release** | Free. The release build is one translation unit (`ren_rt.h:22-27`), so the warm `ren_rt.c` paths inline too. | Only through cross-language LTO with matching LLVM versions. It failed against Apple clang 16: `Unknown attribute kind (102)` (l2 E4). Otherwise an out-of-line dup/drop costs 1.93 ns against 0.39 ns inlined (l2 E1). | Only through LTO with `zig cc` compiling the emitted C as well. That works on Linux targets and fails on macOS ("LTO requires using LLD") (l3 §2.4). |
| **Concurrency-bug safety** | Nothing at compile time. Use-after-free, double free, out-of-bounds, unsigned wrap and plain-field races are all open (l4 §4.1). | Closes use-after-free, double free, out-of-bounds and plain-field races, but only in safe code. Ren's tasks, frames, refcounts and io_uring buffers are C objects, so the critical hand-offs are `unsafe` (l2 §6). | Bounds checks and trapped arithmetic in ReleaseSafe. Use-after-free, double free and races stay open (l4 §4.1). |
| **Bugs no language checks** | Memory ordering, lost wakeups, and kernel writes into a buffer after cancel are open in all three (l4 §4.1; [withoutboats](https://without.boats/blog/io-uring/)). | Same. | Same. |
| **Testing tools** | ASan and UBSan are already in CI (`bench/build.t`). Also TSan, which can't model fences (l4 §2.3), GenMC or CDSChecker for C11 atomics, libFuzzer over the ABI, and the sim scheduler. | loom and shuttle cover Rust code only. Miri rejects calls through FFI function pointers, and resuming a frame is exactly that (l2 §7). Plus the sanitizers and the sim scheduler. | The C sanitizers through clang, a GPA leak and double-free detector, the sim scheduler, and TigerBeetle-style comptime switching between real and simulated I/O. No loom equivalent. |
| **io_uring and kqueue prior art** | liburing is C (inline ring access, 275 tests). Pony and libuv are C. | tokio-uring, monoio, glommio and compio, all dense with `unsafe` (monoio 577, tokio-uring 90) (l2 §6). | `std.os.linux.IoUring` is a liburing port in std. TigerBeetle has io_uring, kqueue, IOCP and simulator backends (l3 §3). |
| **WASM and JSPI** | clang or wasi-sdk, nothing extra. `zig cc` built wasm32-wasi; the program fails at runtime only because the runtime creates its own thread (`ren_rt.c:2794`), which the new ABI removes (l3 §2.2). | The C ABI on `wasm32-unknown-unknown` was fixed only in Rust 1.89. Threads need nightly `-Zbuild-std` *(unverified)* (l2 §9). | Good wasm32 targets. JSPI is the same in all three languages (l2 §9). |
| **Toolchain and build** | The runtime ships as two OCaml strings (`lib/native/runtime/dune`). A build needs only a C compiler. | Prebuilt runtime libraries per target, as Inko does (`inko runtime add`, cross-compilation.md:187), or cargo inside dune. no_std only linked with a `rust_eh_personality` stub (l2 §2). | Prebuilt libraries per target. `@cImport` was removed in 0.17, so `ren_rt.h` needs an external translate-c step (l3 §2.5). |
| **Stability** | Stable. Ren uses C11 plus the GNU builtins tcc supports. | Stable editions. Release builds that use LTO tie each rustc release to a clang release. | Pre-1.0. 0.15 removed async and rewrote I/O, 0.16 added `std.Io`, and 0.17 removed `@cImport` and changed `@bitCast` in a way that can break code silently. TigerBeetle pins exactly 0.16.0 (`build.zig:53-70`). |
| **Binary size (stripped arm64)** | Pay for what you use. The base is 16.8 KB. | +289 KB with no_std, +1.0 MB with std (l2 E3). | 17 KB in ReleaseFast; 2.4 MB in ReleaseSafe unless the panic handler is overridden (l3 §2.6). |
| **Build time** | `tcc -c ren_rt.c` takes 7-11 ms; clang -O2 takes 0.42 s (l2 E7, l3 §2.1). | Clean builds take ~3 s and incremental ~0.3 s, paid once in CI (l2 E5). | 7-9 s cold per target, in CI. `zig cc` is 35x slower than tcc per unit, so it can't be the debug compiler (l3 §2.1). |
| **Contributor pool** | Very large. Ren's emitted code is already C. | Large. Runtime-level `unsafe` skill is rarer. | Small and pre-1.0 *(judgement, not measured)*. |
| **Fit with drivers written in Ren inside `trust`** | Best. Ren compiles to C, so Ren-written drivers become the same kind of code in the same translation unit (l4 §3 item 5). | Every step stays an FFI boundary, with layouts duplicated (l2 §11). | Same as Rust (l3 §4 item 5). |
| **Layout source of truth** | One: `ren_rt.h`. | Two: `#[repr(C)]` copies made by bindgen, with a sync test (l2 §2). | Two: translate-c output, whose statement-expression macros fail (l3 §2.5). |

Where the tracks disagree or are out of date:
- l4 §3 item 2 and §5 say Zig "can `@cImport` the header". That is wrong for 0.17: l3 verified `@cImport` is removed. A Zig move would go through the external translate-c package, which already fails on `ren_rt.h`'s statement-expression macros.
- l4's plan for a clang-compiled scheduler unit runs into the macOS tcc linking wall (§1 above).

## 3. What only an experiment can settle

These can't be settled by reading:
1. **The safety question.** For the actual Ren slice, which bugs does each language stop at compile time, and which does its tooling catch? How much of a Rust core ends up `unsafe` once tasks are C frames?
2. **The cost of opacity.** Calling an out-of-line hot path costs 5x an inlined one (l2 E1). What that costs a whole program depends on how often the warm `ren_rt.c` paths run (l4's E1).
3. **Linux linking.** Can tcc link Rust and Zig ELF archives on Linux (TLS and GOTPCRELX relocations, COMDAT groups)? Unverified by both l2 and l3. Does tcc's TLS work on Linux? (l4's E2.)
4. **tcc and lock-free code.** Does tcc compile a lock-free core correctly? If it does, C keeps the tcc-only debug build for layer C as well (§1).
5. **Engineering cost.** How many lines and hours does the same slice take in each language, with the same rules?

### Experiment spec: `experiments/native-lang/`

Run this after runtime-p2 finishes, so it doesn't disturb that run's numbers. Fold it into runtime-p3 if that is simpler.

**Fairness rules**
- **One shared C harness**, `harness/`, used unchanged by all three:
  - `slice.h` holds the layouts (`ren_obj` with the signed rc protocol, `ren_array`, the task frame with a resume function pointer, `ren_call` and `ren_reply`).
  - It includes the "emitted-style" C programs (workloads below) and the driver-facing host loop.
  - Rust and Zig get these layouts through bindgen or translate-c from `slice.h`. Hand-mirroring is not allowed. The cost of generating them is itself a metric.
- **One algorithm spec**, `SPEC.md`, written before any code: pseudocode for each part, with every atomic ordering named.
  - The Chase-Lev deque follows Lê et al. 2013 with **signed `int64_t` indices**. Check the orderings against the paper's Fig. 1 first, since l4 §2.1 quotes them from memory.
  - The op table identifies ops by **slot plus generation**, never by pointer (l4 §2.6 item 4).
  - The kernel or driver owns each buffer from submit to completion (l4 §2.6 item 5).
- **No third-party scheduler or deque crates or libraries** in any language. Allowed: libc, rustix or the `libc` crate, Zig's `std.posix` and `std.os`, loom, shuttle and Miri. crossbeam-deque may run only as an outside performance and correctness baseline.
- **Same effort budget**: one agent per language with the same time box. Each records how long its work took and every bug it found itself.
- **Builds measured**:
  - C: clang -O2 for release, with ASan, UBSan and TSan variants. Also a tcc build of the core, to settle question 4.
  - Rust: `--release`, `panic=abort`, in both a no_std+alloc and a std variant, on stable.
  - Zig 0.17.0, pinned: ReleaseFast and ReleaseSafe, the latter with the root panic handler overridden.

**The slice, identical in each language**

1. **Deque.** A Chase-Lev deque with a fixed ring plus growth. Owner push and take; thief steal.
2. **Sans-I/O core** behind exactly:
   ```c
   ren_core *ren_start(int (*main)(void), const ren_host *, void *host, int workers);
   int      ren_run(ren_core *, int worker, int64_t now_ns, uint32_t budget);
   bool     ren_poll_call(ren_core *, int worker, ren_call *out);
   void     ren_reply(ren_core *, const ren_reply *);
   int64_t  ren_poll_deadline(ren_core *, int worker);
   ```
   - It holds per-worker deques, a global injector, a timer heap, a generation-checked op table, and park and unpark through the host.
   - It never creates threads: the harness starts one thread per worker, and each calls `ren_run`.
   - Tasks are **C heap frames from the harness** (frame struct plus resume function pointer), refcounted with the header's `ren_dup` and `ren_drop`. This is the boundary l2 says Rust can't see through, so it must be part of the test.
3. **kqueue driver (macOS).** The host turns `ren_call` into kevent:
   - sleep and timer;
   - read and write on a pipe;
   - accept, read and write on a loopback TCP socket;
   - cancel.
   Completions come back through `ren_reply`.
4. **Replay driver.**
   - Recording mode logs every `(worker, now_ns, budget, ren_call, ren_reply)` exchange, and the schedule, to a file.
   - Replay mode drives the core from that log with no OS calls on one thread. Its output and call sequence must match the recording byte for byte.
   - The same driver, fed random bytes, is the fuzz harness (l4's E4).
5. **One hot path, called from emitted-style C:**
   - `ren_dup` and `ren_drop` on a shared object;
   - `ren_array_push` with an inline fast path and an out-of-line grow.

   Variants:
   - (i) C `static inline` in the header;
   - (ii) C out of line in another unit;
   - (iii) Rust `extern "C"`;
   - (iv) Zig `export`;
   - (v) Rust with cross-language LTO on Linux, with rustc and clang on the same LLVM;
   - (vi) Zig with LTO through `zig cc` on Linux.

   Each variant is compiled under tcc (debug) and clang -O2 (release).

**Workloads** (median of 10 runs with hyperfine, reported with the spread, at 1, 4 and 8 workers):
- W1 spawn: 1M trivial tasks, fan-out and fan-in. Tasks per second.
- W2 switch: two tasks ping-pong through a channel-like await, 10M times. ns per switch.
- W3 world-call round trip: a task awaits a 0-byte pipe read that the other end has written. Latency p50 and p99, with the core and kqueue driver in the same process.
- W4 replay: record W1 and W3, then replay them. Replay throughput, plus a byte-for-byte match.
- W5 hot path: 400M dup/drop pairs and 100M array pushes (with growth). ns per operation for each variant and compiler.

**Planted bugs.** Each language's port gets the same five seeded variants, one at a time. For each tool, record whether it caught the bug, at what stage (compile, test, fuzz, model check, never) and how long it took:

| # | Planted bug | C tools | Rust tools | Zig tools |
|---|---|---|---|---|
| P1 | a `seq_cst` fence in take/steal weakened to `acq_rel` | GenMC, TSan | loom | TSan (`-fsanitize=thread`), sim |
| P2 | an unsigned index, giving the underflow on an empty deque (Wingo 2022) | UBSan with `unsigned-integer-overflow` | debug panic, Miri | ReleaseSafe trap |
| P3 | a stale completion delivered after a slot is reused, with the generation check removed | ASan, fuzzer, sim | compiler or Miri, depending on whether it is `unsafe` | GPA, fuzzer, sim |
| P4 | cancel and completion both free the op record (a double free) | ASan, fuzzer | compiler | GPA |
| P5 | a stealer writes a plain (non-atomic) field of a worker | TSan | compiler (`Send`/`Sync`) | TSan |

**Metrics to collect**

| Metric | How |
|---|---|
| Spawn and switch throughput | W1 and W2 |
| World-call round trip | W3, p50 and p99 |
| Hot-path cost | W5, per variant and compiler |
| Lines of code | `tokei`, broken out by part (deque, core, kqueue, replay) |
| `unsafe` lines (Rust) | lines inside `unsafe` blocks and functions, not just keyword counts |
| Raw-pointer and `@ptrCast` sites (Zig) | count |
| Bugs found | planted bugs P1-P5 per tool (table above), plus bugs each author hit while writing, with the tool that caught them |
| Build time | clean and incremental, for the runtime piece and the full harness link |
| Binary size | stripped, for W1, per variant |
| tcc linking on macOS | static object vs dylib; does the debug binary run? |
| tcc linking on Linux | x86_64 and aarch64 in docker: Rust `.a`, Zig `.a`, tcc TLS (l4's E2) |
| tcc as the compiler of the C core | does W1-W4 pass under tcc? |
| Cross-compiling | to x86_64 and aarch64 Linux musl, and wasm32-wasi (single worker, replay driver, no threads). Does it build, and does it run (docker / wasmtime or node)? |
| Layout sync | lines of generated or mirrored layout per language, and whether a deliberate change to `slice.h` fails the build or fails silently |
| Toolchain added to `ren build` | what a user must have installed |

Also run l4's **E1** alongside this: the release benchmarks as one translation unit vs `ren_rt.c` as a separate -O2 object without LTO. It is the only measurement of layer B's cost.

## 4. Provisional recommendation

**(a) Hot inline paths: C. Final.**
- tcc can't inline anything that isn't C source.
- Rust's cross-language LTO fails against Apple clang.
- Zig can't produce a usable header.

All four tracks agree, and the evidence comes from measurement, not argument.

**(b) Scheduler core and drivers: C, provisionally,** written as l4 §2.6 describes:
- a scheduler unit of its own, with C11 atomics and an explicit order on every operation;
- signed indices;
- op slots checked by generation;
- the kernel owning each buffer until it completes;
- GenMC on the deque;
- ASan, UBSan and TSan in CI;
- a fuzzer over the ABI and the sim scheduler from the first commit.

Also adopt `zig cc` **as a toolchain only**, for cross builds to Linux and wasm (l3 §2.2).

Strongest reasons:
1. One source of truth for layouts, and no second toolchain.
2. Release keeps inlining the warm paths.
3. The bug classes that cost most here (memory ordering, lost wakeups, buffers written after cancel) are unchecked in Rust and Zig too.
4. Ren-written drivers in `trust` will compile to C.

**Biggest risk:** use-after-free and plain-field races in the op table and task lifecycle, which Rust would make compile errors. Pony's C runtime shipped exactly these in its completion-based IOCP driver for years (l4 §4.2).

**What would overturn it**
- **Rust takes layer C** if all of these hold:
  - Rust stops P3, P4 and P5 at compile time while C's tools miss one of them or catch it only by luck in fuzzing.
  - `unsafe` covers under about a third of the Rust core, even with C frames.
  - tcc on Linux links the Rust staticlib, and the macOS debug cost is no worse than for a clang-built C core (both need a dylib unless tcc compiles the C core).
  - The no_std build adds under about 100 KB on stable.
  - W1-W3 are within 10% of C.
- **Zig takes layer C** only after Zig 1.0. Even then it would need to beat C on P2 and P3 without a layout-sync burden. Zig has no borrow checker, so it can't win on P3-P5 without its GPA, and the churn cost in §2 stands.
- **C's case strengthens**, toward a firm decision, if:
  - C's tool stack catches P1-P5 before merge;
  - tcc compiles and passes the C core;
  - E1 shows an opaque runtime costs over 2%.
- **Revisit trigger after 11b** (l4 §5): if ASan, TSan or the simulator keep finding memory-safety bugs in the scheduler unit after the first two months, or one reaches a user, move only that unit. Move it to Rust if Rust won the experiment above; Zig is only an option after its 1.0.

## 5. Citations re-checked for this synthesis

All re-checked on 2026-10-29 on this machine. Scratch files are in `/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/syn/`.

| Claim | Result |
|---|---|
| tcc 0.9.28rc (HEAD@e23dabe, AArch64 Darwin): `_Thread_local` | SIGSEGV, exit 139; clang exits 3. **Confirmed.** |
| tcc links a clang Mach-O object | `tcc: error: f_cl.o: unrecognized file type`. **Confirmed.** |
| `ld` links a tcc object | tcc objects are `ELF 64-bit LSB relocatable`, and `ld: unknown file type`. **Confirmed.** |
| tcc C11 atomics (release store, CAS, `seq_cst` fence) | exit 9, the correct result. **Confirmed.** |
| `ren_rt.h` has 103 `static inline` functions; `ren_dup` and `ren_drop` at :430 and :450; release is one translation unit (:22-27); `REN_THREAD_LOCAL _Thread_local` at :390, used for `ren_heap` at :534 | **Confirmed.** |
| The runtime is embedded as OCaml strings ("a binary needs no installed files") | `lib/native/runtime/dune`. **Confirmed.** |
| The runtime creates its own thread at the end of `ren_rt.c` | `pthread_create` at ~:2794. **Confirmed.** |
| "Rust is within ±10% of C everywhere" | `experiments/many-cores/RESULTS.md` ~:242. **Confirmed.** |
| TigerBeetle pins exactly Zig 0.16.0 with a `@compileError` | `/tmp/ren-refs/tigerbeetle/build.zig:53-70`. **Confirmed.** |
| Roc requires `minimum_zig_version = "0.17.0"` | `/tmp/ren-refs/roc-zig/build.zig.zon`. **Confirmed.** |
| Inko cross-compiling needs `inko runtime add TARGET` | `/tmp/ren-refs/inko/docs/source/guides/cross-compilation.md:187`. **Confirmed.** |
| Inko's `rt/src/process.rs` has 22 `unsafe` | **Confirmed.** |
| `lean_dec_ref` is `static inline` with a cold fallback | `/tmp/ren-refs/lean4/src/include/lean/lean.h:734`. **Confirmed.** |
| l2's measurements (E1 1.93 vs 0.39 ns, E4 LTO failure, E3 sizes) and l3's (`zig cc` 127 ms fixed cost, the `-femit-h` no-op, the macOS LTO error) | Taken from the tracks' own runs; not re-run here. |
| Bun's move from Zig to Rust and its stated reasons | Second-hand through InfoQ (l1). It is the main counter-reason, not a basis for the recommendation. |

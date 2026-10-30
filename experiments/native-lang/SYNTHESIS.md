# native-lang Phase B: synthesis (C vs Rust vs Zig for the runtime core)

**Machine: cloud.** `experiments/MACHINE-cloud.md`: 4 vCPU Xeon under KVM (Firecracker guest), Linux 6.18, io_uring available, including MSG_RING.
- Date: 2026-10-30. Builds and plants ran 13:10-17:05 UTC, measuring 17:06-20:00 UTC, and the independent verification about 20:00-22:00 UTC.
- Toolchains: clang 18.1.3 (plus clang-22/lld-22 for cross-language LTO), gcc 13, tcc 0.9.27+git20200814, rustc 1.97 stable (nightly 1.101 for Miri and TSan only), zig 0.17.0 pinned, liburing 2.5, qemu-aarch64-static 8.2.2, wasmtime 25.

**Sources.** This synthesis draws on:
- `research/native-lang/SYNTHESIS.md` (§3 is the experiment spec, §4 the provisional recommendation);
- `SPEC.md`;
- `results/cloud/MEASURE.md`;
- `results/cloud/bugs-{c,rust,zig}.md`;
- `results/cloud/VERIFY.md`, an independent rebuild and re-run;
- `{c,rust,zig}/NOTES.md` and `results/cloud/*-log.md`.

**How MEASURE and VERIFY are reconciled.**
- VERIFY re-ran every headline cell, 7 reps each, with the languages interleaved. All 36 cells came out within 10% of MEASURE's claim; the largest gap was +8.4%. Where a criterion depends on a speed ratio, both figures are given below, and the verdict holds on either.
- VERIFY **disagrees** in two places, and its version is the one used here:
  1. The Zig P1 catch rate is 17/20, not 7/20.
  2. The reason a `Cell<u64>` P5 compiles in the Rust core is not "because `Core` has `unsafe impl Sync`". It still compiles after that impl is deleted. The real reason is that `Core` crosses threads as a raw pointer through the C ABI, so no `Sync` bound is ever checked.

**The ABI.** All three cores implement the **nine-function ABI** of `research/runtime/SYNTHESIS.md` §3, not the five-function ABI written into native-lang §3. That means:
- no `now_ns` and no `ren_poll_deadline`;
- timers are `Clock.Call.SleepUntil` world calls held by the driver;
- the journal goes through `ren_host.journal`;
- `ren_reply` returns ACCEPTED or RELEASE;
- ids are `slot:32|gen:32`.

Each core ships an epoll driver, an io_uring driver, and a replay/fuzz driver. There is no kqueue driver and no macOS run (see §6, "Not measured").

---

## 1. Metrics table

### 1.1 Speed

The table shows MEASURE's median (10 runs; W2 at 4 and 8 workers 7 runs) / VERIFY's median (7 runs). **Bold** marks the fastest where the ranges separate. 8 workers is oversubscribed on 4 vCPUs.

| metric | C | Rust (std) | Zig (ReleaseFast) | Rust vs C (verified) | Zig vs C (verified) |
|---|---|---|---|---|---|
| W1 spawn, tasks/s, epoll x8 | **139,356 / 143,278** | 126,196 / 131,745 | 123,222 / 122,048 | −9.4% / **−8.0%** | −11.6% / **−14.8%** |
| W1 spawn, tasks/s, uring x8 | **140,016 / 134,304** | 132,438 / 128,871 | 120,364 / 116,916 | −5.4% / **−4.0%** | −14.0% / **−12.9%** |
| W2 switch, ns, epoll x4 | 1,878 / 1,992 | **1,752 / 1,832** | 1,927 / 1,982 | 7% / 8% faster | 2.6% slower / 0.5% faster |
| W2 switch, ns, uring x4 | 2,385 / 2,565 | **1,856 / 1,960** | 2,228 / 2,328 | 22% / 24% faster | 7% / 9% faster |
| W2 switch, ns, epoll x8 | 3,117 / 3,241 | 2,927 / 3,081 | 3,138 / 3,217 | 6% / 5% faster (within noise) | tie |
| W2 switch, ns, uring x8 | 3,362 / 3,578 | **3,003 / 3,254** | 3,435 / 3,604 | 11% / 9% faster | 2% / 1% slower |
| W3 world call p50, ns, epoll x8 | 5,636 / 5,621 | **4,792 / 4,875** | 5,092 / 5,057 | 15% / 13% lower | 10% / 10% lower |
| W3 world call p50, ns, uring x8 | 5,284 / 5,238 | 4,904 / 4,801 | **4,503 / 4,438** | 7% / 8% lower | 15% / 15% lower |
| W3 world call p99, ns, epoll x8 | 38,614 / 39,524 | 38,335 / 38,419 | 37,612 / 39,605 | within noise | within noise |
| W3 world call p99, ns, uring x8 | 39,790 / 40,186 | 40,760 / 39,370 | 39,402 / 38,538 | within noise | within noise |
| 1-worker reference (all NOISY, not headlines): W1 tasks/s, W2 ns, W3 uring p50 ns | ~5.4M; 67-72 (pinned 71.7); 978 | ~5.9-6.4M; ~50; 914 | ~5.8-5.9M; 61; 874 | — | — |

**W4 replay** (1 worker, replay driver, no OS calls). Every configuration was NOISY at 17-50% spread, so the figures below are indicative medians only.

| journal | C | Rust | Zig |
|---|---|---|---|
| W1, 1M tasks, 7,877 entries | 6.5M tasks/s | 8.5M tasks/s | 7.4M tasks/s |
| W3, 2.4M entries, 152 MB | 10.2M entries/s (0.65 GB/s) | 16.9M entries/s (1.07 GB/s) | 17.8M entries/s (1.13 GB/s) |

Byte-match:
- Every core replayed every core's journals: **36/36** output-identical, with every core entry byte-identical.
- The journal files themselves are identical (md5) across all three languages for W1, and between C and Zig for W3. Rust's W3 journals differ only in driver-entry order (REPLY written before DRAINED).
- Also 8/8 between c-tcc and c-release, 32/32 replaying x86-recorded journals on aarch64, and 8/8 replaying x86 journals in C under wasm32-wasi.

**What the speed rows actually measure** (VERIFY, harness issues):
- **W1 at 4 and 8 workers mostly measures the park/eventfd-wake path, not spawn cost.**
  - At 8 workers, 70-80% of CPU time is kernel time, with 0.7-0.9 sleeps per task.
  - Throughput falls from 5.5M/s at 1 worker to 0.14M/s at 8.
  - Running under `strace` alone makes the x4 case 13× faster.
  - The comparison is still like for like, because all three follow the same SPEC wake policy.
- **W3 "x8" runs a single task.** The extra 7 workers sit idle in epoll or io_uring.
- **The 1-worker rows are noisy.** Every 1-worker row, W4 and E1 run under about 1 s, and this VM gives them 15-50% spread. None of them is a headline.

### 1.2 W5 hot path (ns/op) per variant and compiler

The variants are:
- (i) C `static inline`;
- (ii) C out of line;
- (iii) Rust `extern "C"`;
- (iv) Zig `export`;
- (v) Rust plus clang-22 ThinLTO;
- (vi) Zig plus `zig cc -flto`.

Medians come from MEASURE §7, unpinned. Only `dupshared` is clean. The `dup` and `push` cells are NOISY, but their order is consistent.

| variant | dupshared, clang | dupshared, tcc | dup, clang (NOISY) | dup, tcc (NOISY) | push, clang (NOISY) | calls to `ren_hot_*` left in the loop |
|---|---|---|---|---|---|---|
| (i) C inline | 20.93 | 25.42 | **0.63** | 3.20 (pinned, clean: 3.07) | **0.77** | inlined |
| (ii) C out of line | 20.52 / VERIFY 20.78 | 24.28 / VERIFY 25.26 | 1.30 | 3.24 | 1.68 | 5 |
| (iii) Rust extern | 20.17 / VERIFY 20.96 | 20.43 / VERIFY 20.99 | 1.29 | 1.64 | 1.48 | 5 |
| (iv) Zig export | 20.27 / VERIFY 21.12 | 20.34 / VERIFY 21.09 | 1.39 | 1.98 | 1.48 | 6 |
| (v) Rust LTO (clang-22) | 20.53 | not buildable (tcc has no LTO) | 0.91 | — | 0.83 | 4 (`ren_hot_drop` is **not** inlined across the boundary) |
| (vi) Zig LTO (zig cc) | 20.54 | not buildable | 1.16 | — | 1.71 | 0 |

How to read W5 (VERIFY):
- **`dupshared` cannot rank the languages.** All three compile `ren_hot_dup` to the same 8 instructions, with two lock-prefixed RMWs.
- **The "tcc" column is mislabelled for C.** build.sh compiles C's hot path itself with tcc, while Rust's and Zig's hot paths stay LLVM-optimized. C's 24-25 ns is tcc's code generation, not the cost of being called from tcc-built C.

The real signals:
- Inline C costs about 0.6-0.8 ns, against about 1.3-1.7 ns for any out-of-line call, which is roughly 2×.
- Under tcc, an LLVM-compiled Rust or Zig hot path (1.6-2.0 ns) beats tcc-compiled C (3.2 ns).

### 1.3 E1: one translation unit vs a separate -O2 object (C core)

The table shows median [spread]. Pinned results are similar.

| workload | unity | split | read |
|---|---|---|---|
| W1, tasks/s | 4.90M [27%] | 5.32M [26%] | NOISY |
| W2, ns | 70.1 [14%] | 72.4 [16%] | NOISY |
| W3 p50, ns | 1,443 [1.2%] | 1,440 [17%] | no difference |

**No difference is visible at this resolution.** The noise floor here is around 15%, so a 2% effect cannot be seen either way.

Note what E1 actually split: the slice's **scheduler core**, not the warm half of `ren_rt.c` that l4's E1 is about. So layer B's opacity cost is still **unmeasured**.

### 1.4 Code, safety surface, build

| metric | C | Rust | Zig |
|---|---|---|---|
| LOC, deque | 137 | 193 | 96 |
| LOC, core (scheduler, op table, journal, atomics) | 868 | 1,083 | 884 |
| LOC, driver common + recorder | 373 | 376 | 317 |
| LOC, epoll driver | 372 | 335 | 345 |
| LOC, io_uring driver | 334 (liburing) | 460 (raw syscalls, bindgen'd kernel ABI) | 296 (`std.os.linux.IoUring`) |
| LOC, replay + fuzz driver | 281 | 409 | 285 |
| LOC, hot path | 30 | 67 | 67 |
| LOC, layout glue / exports | 9 | 234 | 127 |
| **LOC, shipped total (cloc)** | **2,404** | **3,157** | **2,417** |
| language-only tests | 0 | 472 (Miri op-table tests, loom) | 0 |
| agent wall time to a 72/72 slice | 0.45 h | 0.77 h | 0.73 h |
| unsafe lines / cast sites | n/a (all of it) | **66.8%** of lines inside `unsafe` (2,045/3,061). By file: deque 6.7%, sched 70.1%, epoll 83.3%, uring 82.2%. Written unsafe-fn-first and not minimised | 27 `@ptrCast`, 10 `@alignCast` (each paired with one), 5 `@intFromPtr`, 2 `@ptrFromInt`, 37 `[*c]` in signatures |
| build time, language piece, clean / incremental (median s) | 1.68 / 1.85 (no incremental build: recompiles all 10 files) | 5.23 / 3.36 (first-ever clean build 13.8 s, including the crates.io index and `libc`) | 3.99 / 4.27 (one compilation unit, so incremental ≈ clean) |
| build time, harness link | 2.55 s | 3.23 s | 2.67 s |
| binary size, W1-only, stripped | **72 KB** (tcc-built core: 87 KB) | std 1,099 KB, or 439 KB with gc-sections. no_std 384 KB, or **158 KB with gc-sections** | ReleaseFast **109 KB**. ReleaseSafe 846 KB |
| added over C, W1-only | — | std +1,027 KB (+367 KB with gc). no_std **+311 KB** (+86 KB with gc) | +37 KB (ReleaseFast) |

### 1.5 Portability and toolchain

| metric | C | Rust | Zig |
|---|---|---|---|
| **tcc links the core archive (Linux x86_64)** | yes, trivially (tcc's own objects or clang's ELF) | **no_std: yes, only after adding `libgcc_eh.a`** (`undefined symbol '_Unwind_Resume'`); then 72/72. **std: no**: `tcc: error: Unknown relocation type for got: 19` (R_X86_64_TLSGD; std carries 36 TLSGD and 16 TLSLD relocations) | **yes, as is**: 72/72 |
| tcc TLS on Linux | `__thread` and `_Thread_local` are syntax errors. TLSGD and TPOFF32 relocations are rejected. **GOTTPOFF links, and the program segfaults** (a silent mislink) | same; only std brings TLS | same; the core uses no TLS |
| **tcc compiles the C core** | **yes, x86-64: 72/72** (W1-W4 at 1, 4 and 8 workers, both drivers, plus fuzz), xreplay 8/8 both ways. It goes through slice.h's x86-64 asm atomics shim. `drv_uring.c` stays clang, because liburing.h needs `<stdatomic.h>`. tcc ignores `packed` on `struct epoll_event`, which needed a byte-buffer workaround | n/a | n/a |
| tcc on aarch64 (arm64-tcc built from Ubuntu's source) | cannot compile slice.h: the shim `#error`s outside x86-64 | | |
| tcc links aarch64 archives | **no** for every archive: `Unknown relocation type for got: 299` (R_AARCH64_LDST128_ABS_LO12_NC) | same | same |
| cross to x86_64-linux-musl | builds only with an `epoll_pwait2` syscall shim (zig's musl lacks the declaration) plus liburing rebuilt with `--use-libc`; runs 54/54 | std and no_std link only with `-lunwind` (`_Unwind_Resume`); 54/54 | **builds as is**; 54/54 |
| cross to aarch64-linux-musl | builds with the shim. Under qemu 8.2: 7/29, because qemu-user lacks `epoll_pwait2`. io_uring returns ENOSYS, which is correctly refused | needs `BINDGEN_EXTRA_CLANG_ARGS` (otherwise bindgen reads host glibc headers: `'bits/libc-header-start.h' file not found`) plus `-lunwind`; **29/29 under qemu** (it uses `epoll_wait`) | builds as is. 6/29 under qemu: the same `epoll_pwait2` gap, **plus deque stress 5/5 failing**. A store-buffering litmus test gives 8,815 forbidden outcomes out of 2M with `stlr`/`ldar` under qemu and 0 with `dmb`, so that failure is a qemu artifact. Zig on real aarch64 is **untested** |
| x86 journals replayed on aarch64 | 8/8 | 8/8 (std and no_std) | 8/8 |
| wasm32-wasi | **no as is**: slice.h's LP64 static asserts fail first, in all three. With a probe slice.h (asserts off) plus driver stubs, **C replays the x86 journals 8/8 under wasmtime** | with the probe: 111 rustc errors (the `libc` crate has no epoll on wasi); needs cfg-gating, not attempted | with the probe: `std.os.linux` errors; needs comptime-gating, not attempted |
| **layout sync**: generated or mirrored layout lines | 0 (slice.h is the source) + 9 (layout table) | bindgen: 557 (slice.rs, generated twice), 75 (layout_gen.rs), 436 (kernel io_uring ABI), plus 234 lines of glue | translate-c: 1,378 (slice.zig) + 2, plus root.zig glue |
| layout edits a/b/c (field moves, a size change, op renumbering) | propagated | propagated | propagated |
| **layout edit d** (`ren_io_result.res` int64_t → uint64_t) | **builds silently and passes every test** | **fails the build** (E0308) | **fails the build** (`expected type 'i64', found 'u64'`) |
| toolchain a user must install for `ren build` | a C11 compiler, plus liburing for the uring driver. Cross builds: `zig cc`, liburing per target, and the epoll_pwait2 shim | rustc and cargo 1.97 plus a target per triple; the `libc` crate; the **bindgen CLI plus libclang 18 specifically** (with libclang-22 bindgen silently emits opaque structs, and build.rs asserts against that); kernel uapi headers; libgcc_s or libgcc_eh/libunwind; a target sysroot for bindgen when cross-building; clang-22 + lld-22 for LTO; nightly for TSan. About 2.2 GB | zig 0.17.0 exactly (one 411 MB directory, bundling clang 22, musl, wasi-libc and kernel headers); `-fcompiler-rt` for safe builds. A host C compiler is still needed for emitted C, and `zig cc` can be that compiler |

---

## 2. Planted bugs: bug × language × tool → caught / stage

**Key:**
- **C** = caught at compile time.
- **T** = caught by a test or an assertion oracle.
- **S** = caught by a sanitizer or Miri at run time.
- **F** = caught by a fuzzer.
- **M** = caught by a model checker.
- "—" = missed.
- "hang" = the bug shows up only as a timeout.

VERIFY re-ran P1, P3 and P5 in all three languages, plus every compile-time row (✓v below). It did not re-run P2/P4 at run time (apart from C), Miri, valgrind, libFuzzer or GenMC.

| bug | language | compiler / lints | tests and oracles | ASan (or ASan harness) | UBSan / safe-mode traps | TSan | Miri | loom | valgrind | fuzz (fuzz_run, libFuzzer) | first catch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **P1**: SC fence weakened to acq_rel | C | — (✓v) | **T, intermittent**: `deque_stress stress`, release 23/30 (VERIFY 17/20), debug 20/30, asan 13/30. One run inside the suite caught it in only 1 of 5 profiles. W1 x8: 0/20 | — | — | **— (✓v)**: TSan does not model fences | n/a | n/a | — (helgrind/drd reports look the same as P0) | — (1-worker fuzz cannot reorder) | T (stress oracle). GenMC: could-not-run (its build was denied) |
| | Rust | — (✓v) | **T**: deque_stress x50 fails on run 1 (VERIFY 13/20) | — | — | **— (✓v)** | **S**: weak-memory emulation, `threads` test, double take | **M**: `two_thieves` (✓v) | — | — | T / M (loom) |
| | Zig | — (✓v) | **T**: deque_stress, debug 20/20, release-fast 7/20 (**VERIFY 17/20**), release-safe 7/20 | — | — | **— (✓v)** | n/a | n/a | — | — | T (stress oracle) |
| **P2**: unsigned deque indices | C | **C, incidental**: the `-Werror` build fails at dq.c:47:13 with -Wsign-compare, only because `cap` stayed signed; -Wconversion gives 6 warnings (✓v) | hang (65/72 time out) | hang | **S**: `-fsanitize=integer` reports dq.c:58:32 `0 - 1` (✓v) | hang | n/a | n/a | hang | F as a timeout; fuzz_run under UBSan | C (incidental) / S |
| | Rust | — (one unused-import warning) | hang (release); **debug: overflow panic at deque.rs:109** | hang | debug overflow panic | hang | **S**: overflow panic | M (indirect): branch limit exceeded | — | F as a timeout | debug panic (0.2 s) |
| | Zig | **C**: `dq.zig:66:39 incompatible types 'u64' and 'i64'`, a hard error, but again only because `cap` stayed i64 (✓v). P2u, with everything unsigned, compiles | P2u release-fast: hang | P2u: SEGV only | **P2u: ReleaseSafe/Debug trap `integer overflow`** on the first take (on by default) | — | n/a | n/a | — | P2u: trap | C (spec-exact) / safe-mode trap |
| **P3**: generation check removed | C | — | **T**: `abi_test.c:218` in every profile (✓v) | — (LeakSanitizer only, after the abort) | — | — (✓v) | n/a | n/a | — | **F**: fuzz_run oracle "a stale reply was ACCEPTED" (✓v); libFuzzer 0.5 s | T / F (the oracles) |
| | Rust | — | **T**: abi_test.c:218 (✓v); the Rust op-table test `stale_after_reuse` | — | — | — (✓v) | T (a test assertion, no UB) | n/a | — | **F** (✓v); libFuzzer 0.3 s | T / F |
| | Zig | — | **T**: abi_test.c:218 (✓v) | — | — | — (✓v) | n/a | n/a | — | **F** (✓v); libFuzzer 0.3 s | T / F |
| **P4**: cancel and completion both free the op | C | — (warnings). **`clang --analyze`: core.c:150:16 use-after-free** (✓v; P0 has 5 untriaged reports in the drivers) | **T**: 56/72; release SIGSEGV | **S**: heap-use-after-free at core.c:150 | SEGV handler only | S (incidental UAF) | n/a | n/a | **S**: invalid read and invalid free | **F**: 201 execs | C (analyzer) / T / S |
| | Rust | **—**: it is one `Box::from_raw` inside an existing `unsafe fn`. An owned-`Box` design would get E0382, but this core uses `*mut Op` | **T**: glibc double-free abort, 16/72 | **S**: double free | — | S (UAF) | **S**: UB, freed reference | n/a | — | **F** | T / S |
| | Zig | — | **T**: 56/72; glibc abort in release-fast | S (double free only, via the ASan harness) | **SafeAllocator: "double free"** with an empty stack trace; Debug: a bounds trap on the freed value | **S**: UAF, both lines named | n/a | n/a | — | **F** | T / S |
| **P5**: a stealer writes a plain worker field | C | — | — (the counter is never checked) | — | — | **S: 20/20** at W1 x4 (✓v 10/10 + 5/5), sched.c:165 | n/a | n/a | helgrind/drd: buried in about 50 false positives | — | S (TSan) |
| | Rust | **C only for a bare `u64`**: E0594, a *mutability* error, not Send/Sync (✓v). The `UnsafeCell` form (as planted) compiles inside an existing `unsafe fn` with no new `unsafe` (✓v). **The `Cell<u64>` form compiles in entirely safe code, even after deleting `unsafe impl Sync for Core`** (✓v; this corrects the C table's explanation). The atomic load+store form compiles and is invisible to every tool | — | — | — | **S**: sched.rs:433 (✓v) | **S**: UB data race (the Cell form only with many seeds) | n/a (deque only) | — | — | S (TSan / Miri); C only in the bare spelling |
| | Zig | **— (✓v)**: Zig has no Send/Sync and no atomic types | — | — | — | **S: 20/20** (✓v), core.zig:562/419 | n/a | n/a | — | — | S (TSan) |

What the table says:
- **No language stopped P3, P4 or P5 at compile time in the shape the core actually has.**
  - Rust stops P5 only when it is written as a bare field. That is borrowck (E0594), not the thread-safety check. Nothing stops `Cell` or `UnsafeCell`, because the core crosses threads as `*const Core` through the C ABI.
  - Rust would stop P4 only in an owned-`Box` design, which the C ABI and intrusive lists rule out.
  - The one compile-time catch anywhere besides that is **P2**. C (-Werror) and Zig catch it incidentally, and only while `cap` stays signed. The C analyzer catches P4 as an extra.
- **P3 is caught the same way in every language**: by the shared `abi_test` and the fuzz oracle. No memory tool sees it in any language, because the stale reply lands on the slot's live new occupant.
- **P1 is caught only by the deque_stress oracle in C and Zig**, and intermittently. In Rust, loom and Miri also catch it. That is Rust's one real tooling advantage here, and it applies only to Rust-only test code (Miri cannot run through the C frames). GenMC, the C tool meant for P1, could not be built: the session's permission classifier denied building it.
- **P5 is caught by TSan, 100%, in all three languages.**
- **SPEC §F's expectations that did not hold:**
  - TSan catches P1: no, in all three.
  - ASan catches P3: no, in all three.
  - The fuzzer catches P1 or P5: no, because it is 1-worker.
  - The Rust compiler catches P4 and P5 via Send/Sync: only in spellings the core doesn't use.

---

## 3. Bugs the authors hit while writing

| language | bugs | caught by compiler or linker | caught by tests / oracles | caught by sanitizers / Miri / fuzzer | own review / inspection | open |
|---|---|---|---|---|---|---|
| C (7) | (1) `ren_free` read a task word after dropping it, a UAF; (2) replay reset `core_pos`; (3) fuzz REPLY lost a call; (4) tcc ignores `packed` on `epoll_event`; (5)(6) TSan false reports from fence-based publication and the harness rc read; (7) a static-name clash in unity.c | 7 (clang) | 2 (W4), 4 (smoke/io on tcc) | 3 (**libFuzzer**), 5-6 (TSan, tool interaction) | 1 (**the only core memory-safety bug, caught by review**) | 5 untriaged `clang --analyze` reports in the clean drivers |
| Rust (14) | toolchain and scaffolding: (1) libclang-22 makes bindgen emit opaque structs **silently**; (4) the no_std `rust_eh_personality` link; (5) a nightly TSan ABI mismatch; (6) TSan fence reports; (7)-(11) test code; (12) `ren_stop` journaling every slot; (13) fuzz driver lost a call; (14) wrong link.flags | 2, 3, 5, 8, 11 (rustc); 4, 14 (linker / tcc) | 7 (bounds panic) | 9, 10 (**Miri**, on test code), 13 (**libFuzzer**), 6 (TSan) | 1, 12 (journal compared against C's) | **Found later, in the unplanted core: `t_cancel` x8 hangs 2/200 (epoll) and 3/200 (uring)**, every worker parked with no timer armed: a lost wake on the cancel path. Not diagnosed |
| Zig (11) | (1)-(5) Zig 0.17 churn: shadowing, a removed `**` init, pointless discard, `.Debug`→`.debug`, a layout tuple; (6) a debug pending-mark race; (7) `__zig_probe_stack`; (8) an empty lto-hot archive; (9) **W2 x4 intermittent hang**; (10) epoll ACCEPT parked as EPOLLOUT, so t_tcp hung; (11) `.note.GNU-stack` (the fix broke tcc; the self-hosted Debug backend ignores the asm) | 1-5 (zig), 7, 8, 11 (ld / tcc) | 9, 10 (smoke / io timeouts, diagnosed with gdb) | none: "nothing was caught by Zig's safety checks, the safe allocator or TSan" | 6 | **Bug 9 unexplained**: about 8 of 15 runs hung in one loaded window, then 0 in more than 100 runs (bugs-zig also saw 0 in 20 suites). Zig's author also flagged a **use-after-free window in SPEC §B.5 itself** (`deliver` notifies after the REL store, so a spuriously woken task can finish and be freed first). That window applies to all three cores; no test exercises it |

Two things stand out:
1. In every language, **no core logic bug was caught by the language**. The compiler errors were churn, typos and scaffolding.
2. The two lost-wake style hangs (Rust t_cancel x8, Zig W2 x4) are in protocol code that is line for line the same as C's. Neither has been seen in C, but neither has been ruled out in C either. They are a SPEC/protocol risk, not a language result.

---

## 4. Where the measurements disagree with the research

`research/native-lang/SYNTHESIS.md` and the l2/l3/l4 tracks are cited here as "research". The research was done on macOS arm64 and this run on Linux x86-64, so some differences are expected.

1. **"Rust closes plain-field races in safe code" (§2) does not hold for this design.**
   - The core crosses threads as `*const Core` through the C ABI, so `Sync` is never checked.
   - `Cell<u64>` compiles with zero `unsafe`, even with the hand-written `unsafe impl Sync` deleted (VERIFY).
   - The only P5 the compiler rejects is the bare-field spelling, and that is via E0594, a mutability error.
2. **The research's "Rust compiler" entries for P3, P4 and P5 (§3 table) all missed.**
   - P4 is caught at compile time only in an owned-`Box` design that the C ABI precludes.
   - P3 is a logic bug in every language.
3. **The "TSan" entries for P1 (§3 table, C and Zig) also missed.**
   - TSan missed P1 in all three languages, because it doesn't model fences.
   - Worse, every language had to make push's `bottom` store Release in TSan builds, or TSan reported every stolen frame.
4. **ASan was expected to catch P3. It never did:** the stale reply hits a live op.
5. **Miri is not as blocked as §2 says.** It still can't run through the C frames. But on Rust-only op-table and deque tests it caught **all five** plants: P1 by weak-memory emulation, P2 by panic, P3 by assertion, P4 and P5 as UB. That is the strongest single-tool result in the experiment, and it only reaches code that has a pure-Rust test double.
6. **Cross-language LTO works on Linux** with clang-22 matching rustc's LLVM 22, unlike the Apple clang failure in l2 E4.
   - It is incomplete: `ren_hot_drop` stays a call.
   - Zig LTO through `zig cc` inlines everything (0 calls).
7. **The out-of-line hot-path penalty is about 2× here (1.3 vs 0.63 ns), not 5× (l2 E1: 1.93 vs 0.39 ns).** These cells are NOISY. The direction is the same, and the magnitude is smaller.
8. **Build times differ from the research.**
   - Rust incremental is 3.4 s, not about 0.3 s (l2 E5). Clean is 5.2 s, not about 3 s.
   - Zig cold is 4.0 s, not 7-9 s.
   - tcc compiles the 10-file C core in 0.42 s. That is not comparable with "7-11 ms for `ren_rt.c`".
9. **Sizes.**
   - Rust no_std +311 KB and std +1.03 MB over C match l2 E3 (+289 KB / +1.0 MB). The new finding is that `--gc-sections` brings no_std down to +86 KB.
   - Zig ReleaseFast is 109 KB, against C's 72 KB. Research had "17 KB", but that was the base, not a W1 binary with all drivers.
10. **Layout sync.**
    - §2 counts "one source of truth" as C's advantage, and says Zig's translate-c fails on statement-expression macros.
    - On slice.h, translate-c and bindgen both worked, and both **caught a signedness change (edit d) that C compiled silently and passed**.
    - The single source of truth does not make C safer against layout *type* drift; the generated bindings did better.
11. **Cross builds.**
    - "`zig cc` works as a cross toolchain for the C runtime" holds only with workarounds: an epoll_pwait2 shim, and liburing rebuilt with `--use-libc`.
    - "C on wasm needs nothing extra" fails as is, on slice.h's LP64 static asserts. That is a harness issue that hits all three languages. With them off, only C ran (8/8).
12. **New facts about tcc on Linux** (research §3 question 3 was unverified):
    - tcc links Zig's `.a` as is, and Rust no_std's with `libgcc_eh.a` added.
    - It cannot link Rust std's (TLSGD).
    - tcc TLS is broken on Linux too, including one silent GOTTPOFF mislink.
    - tcc cannot target aarch64 Linux for any of the three (relocation 299).
13. **Speed.**
    - The research's "Rust within ±10% of C everywhere" (many-cores) holds. Here Rust is **faster than C** on W2 (up to 24% on uring x4) and W3 p50 (8-13%).
    - That points to something in the C core's wake/switch path worth profiling. The protocols are meant to be identical. The research had no reason to expect C to lose.

---

## 5. Recommendation

### (a) The inline header (layer A): **C. Final, re-confirmed.**
- Inline C is the only form under 1 ns on `dup` and `push` (0.63 / 0.77 ns). Every out-of-line variant costs about 2× that.
- tcc can't inline anything that isn't C source, and can't do LTO, so (v) and (vi) are unbuildable under tcc.
- Rust's LTO on Linux needs a matching clang-22 and still leaves `ren_hot_drop` as a call.
- Zig LTO inlines, but only if `zig cc` also compiles the emitted C.
- Nothing measured here argues for moving it.

### (b) The warm half of `ren_rt.c` (layer B): **C, in the release translation unit, unchanged. Still unmeasured, not newly supported.**
- E1 found no difference, but its noise floor is about 15%, and it split the slice's scheduler core, not `ren_rt.c`'s maps, strings and array growth.
- So C's strengthening criterion "E1 shows an opaque runtime costs over 2%" is **not met** and **not refuted**.
- Nothing measured gives a reason to make layer B opaque either: there is no safety plant in it, and W5 shows opacity costs about 2× per call on the cheap paths.
- **Action:** re-run E1 on the real `ren_rt.c` on a quiet, pinned, bare-metal machine before stage 11b freezes the split.

### (c) The scheduler core and drivers (layer C): **C, firmed: the provisional recommendation stands and Rust's overturn case fails.**

**Rust takes layer C only if every criterion holds.** Two fail outright, two pass only partially, and one is met.

| criterion (§4) | result | verdict |
|---|---|---|
| Rust stops P3, P4 and P5 at compile time | P3: no. P4: no (raw `*mut Op` in an existing `unsafe fn`). P5: only the bare-`u64` spelling, via E0594. `Cell` compiles in safe code, `UnsafeCell` compiles with no new `unsafe` (VERIFY-confirmed) | **fails** |
| …while C's tools miss one of them, or catch it only by luck in fuzzing | C catches P3 deterministically (abi_test, fuzz oracle), P4 four ways (ASan, valgrind, the analyzer, a release crash) and P5 with TSan 20/20 | **fails**: C's tools catch all three |
| `unsafe` under about a third of the core, even with C frames | 66.8% overall; sched 70%, drivers 80%+. The author says minimisation would lower the count, but "not the amount of code that touches raw pointers" | **fails** (unminimised; even halving it would not reach a third) |
| tcc on Linux links the Rust staticlib (and the macOS debug cost is no worse than C's) | no_std links only after adding `libgcc_eh.a`; **std does not link** (TLSGD). macOS was not measured | **partial** |
| no_std adds under about 100 KB on stable | +86 KB only with `-ffunction-sections -fdata-sections -Wl,--gc-sections`; **+311 KB** without | **partial** (it passes if Ren's link always uses gc-sections) |
| W1-W3 within 10% of C | W1 −8.0% / −4.0% (VERIFY; MEASURE −9.4% / −5.4%); W2 and W3 equal or faster | **met** |

**Zig takes layer C only after 1.0, and only if it beats C on P2 and P3 without a layout-sync burden.**
- It is still 0.17. During this slice it caused five churn compile errors and a backend-dependent `.note.GNU-stack` behaviour.
- **P2:** Zig rejects spec-exact P2 at compile time, but only for the same incidental reason as C's -Werror. Safe-mode traps catch the all-unsigned variant by default, where C needs `-fsanitize=integer`. That is a small edge.
- **P3:** no better than C; the same oracle catches it.
- **Layout sync:** effectively no burden, and it caught edit d.
- **Speed:** W1 x8 is **−14.8% / −12.9%** against C (VERIFY), outside 10%.
- Verdict: **not met; the gate is still 1.0.**

**C's case strengthens if all of the following hold. Two are met and one is unknown.**
- **Tools catch P1-P5 before merge: met for P2-P5, not for P1.**
  - P2 is caught by -Werror (incidental) and UBSan integer.
  - P3 by abi_test and the fuzz oracle.
  - P4 by ASan, the analyzer and the tests.
  - P5 by TSan, 100%.
  - P1 is caught only by the deque_stress oracle, at 43-85% per run depending on the profile (release 23/30, VERIFY 17/20); a single suite run caught it in 1 of 5 profiles. GenMC could not be built. "Before merge" for P1 needs either GenMC or a repeated stress gate. At about 77% per run, 10 runs miss with probability around 4×10⁻⁷, but that is luck by construction.
- **tcc compiles and passes the C core: met on x86-64** (72/72, cross-replay 8/8), through slice.h's asm shim. **Not on aarch64.** The io_uring driver still needs clang.
- **E1 shows an opaque runtime costs over 2%: unknown** (see (b)).

**Why C, criterion by criterion:**
- Rust's distinctive guarantees did not reach the hand-offs that matter. The core is raw pointers across a C ABI, so the compiler caught nothing C's tooling missed.
- The `unsafe` share is twice the threshold.
- Rust costs a second toolchain plus bindgen pinned to libclang 18, and its std archive tcc cannot link.
- Rust's real wins are worth recording as the revisit case:
  - it is faster on W2 and W3;
  - Miri and loom catch P1 in Rust-only tests;
  - aarch64 under qemu was cleanest for Rust, but only because it uses `epoll_wait`.

**What to carry into the C core** (each item answers a measured gap):
1. **P1:** get GenMC building (it needs permission to build external code), or make `deque_stress stress` a repeated gate (10 runs or more) in CI. Neither TSan nor the fuzzer can see P1.
2. **Layout type drift (edit d):** add signedness and type checks to `ren_layout_table` or slice.h, for example a `_Generic` static assert per field. The generated Rust and Zig bindings caught this; C did not.
3. **P2:** keep `-Werror -Wsign-compare` (it caught P2 only through `cap`), and run `-fsanitize=integer` in CI with intended wraps annotated, as the C entry did.
4. **Add `clang --analyze` to CI,** after triaging the 5 existing reports in the clean drivers.
5. **Before stage 11b**, investigate the lost-wake hangs (Rust t_cancel x8, Zig W2 x4) and the §B.5 notify-after-store UAF window, against the C core. They are protocol issues the C core shares.
6. **Profile why C's W2 and W3 are 8-24% slower than Rust's** on the same protocol.
7. **Fix the harness:** slice.h's LP64 asserts block wasm in all three languages, `fuzz_run` exits 0 with no arguments, and `test.sh replay_one` reports the wrong exit code.
8. **Keep `zig cc` as a cross toolchain only.** Add the epoll_pwait2 shim and a liburing built `--use-libc` per target.

**The revisit trigger stays as written in §4.** If ASan, TSan or the simulator keep finding memory-safety bugs in the scheduler unit after two months, move only that unit, and move it to Rust. Before relying on Rust's compile-time guarantees there, it would have to be designed so that `Core` and ops cross threads as Rust types (`&Core` with real `Sync` bounds, owned `Box<Op>`), not as raw pointers. This experiment shows those guarantees are otherwise lost.

---

## 6. Not measured, and caveats

- **macOS:** no kqueue driver, and no tcc-on-macOS link or dylib test. Cloud is Linux only. The macOS half of Rust's tcc criterion is open.
- **Real aarch64 hardware:** not available. Zig's deque on aarch64 is untested (qemu cannot validate it). C's and Zig's epoll drivers are untested on aarch64 (qemu-user 8.2 lacks `epoll_pwait2`).
- **GenMC:** could not run (its build was denied); P1 has no model-check result for C.
- **The VM's noise:** 1-worker runs, W4 and E1 are all NOISY. The headline speed results come only from multi-worker rows, which mostly measure the wake path. VERIFY saw a machine-wide 2.5-8.4% W2 shift that affected all three languages at once.
- **The unsafe count:** Rust's 66.8% is an unminimised first draft.
- **t_timer flakes:** about 0.4% in every core, a test-timing limitation (timers 5 ms apart).
- **Installs:** none for this synthesis. Earlier phases installed things with apt only for the C GenMC attempt (listed in bugs-c.md). The tarballs for liburing 2.5 and tcc came from archive.ubuntu.com, with checksums verified.

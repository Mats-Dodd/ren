# L2: Rust as the language of Ren's runtime core and drivers

Question: should Ren's scheduler core, drivers, blocking pool, journal and
arenas (stage 11b/13) be Rust behind a C ABI, with emitted C calling it,
instead of C?

Method: I read `lib/native/runtime/ren_rt.h`, `ren_rt.c`, `lib/native/cc.ml`
and `lib/native/emit_c.ml`, the prior-art runtimes in `/tmp/ren-refs`
(tokio, tokio-uring, monoio, glommio, inko, roc-rust, loom, shuttle), and
ran seven small experiments with rustc 1.99.1 (LLVM 23.1.1), Apple clang
16.0.0 and tcc 0.9.28rc on macOS arm64. The experiment sources are in the
scratchpad (`.../scratchpad/l2/`). Where a claim comes from memory and I did
not check it, it says **unverified**.

## 1. What today's runtime is, and what that does to the question

- **About half the runtime isn't a library.** `ren_rt.h` has 103
  `static inline` functions (`grep -c "static inline"`): `ren_dup` and
  `ren_drop` (ren_rt.h:430-477), the allocator's fast path
  (`ren_alloc_bytes`, :542), array get/set/push (:705-1052), checked
  arithmetic (:1474-1540), NaN-tagged floats (:1569-1622), map lookups
  (:1890-1897), and the evidence lookups (`ren_find`, :1995). Emitted C calls
  these directly, and they only cost nothing because the C compiler inlines
  them.
- **The runtime ships as source in the compiler.** `lib/native/runtime/dune`
  turns `ren_rt.h` and `ren_rt.c` into OCaml strings (`runtime_c.ml`).
  `emit_c.ml:2030-2032` pastes them into a release build's single C file.
  `emit_c.ml:2221-2222` and `cc.ml:130-160` write them out as units of a
  debug build. So a release build is one translation unit, and clang
  optimizes the runtime and the program together. A Ren binary needs no
  installed files (the dune comment). Every target that has a C compiler
  gets a runtime for free.
- **Ren tasks are heap frames.** Pure code runs on the native stack, and
  only code that can wait gets a frame (research/runtime/r6-scheduling.md:23-26,
  :366). So the scheduler holds pointers to C-allocated, C-refcounted
  frames and resumes them through C function pointers. Every object it
  schedules is foreign to Rust.

So the question is narrower than "C or Rust". Section 3 shows the hot
inline paths can't move to Rust under either build mode. The real question
is (b): a Rust crate behind `ren_start` / `ren_run` / `ren_poll_call` /
`ren_reply` / `ren_poll_deadline`, beside a C header that stays.

## 2. Exporting a C ABI from Rust: the mechanics work

- **`extern "C"` and `#[no_mangle]`** work as documented. Edition 2024,
  which `cargo new` now defaults to, requires `#[unsafe(no_mangle)]`. A
  plain `#[no_mangle]` is a hard error ("unsafe attribute used without
  unsafe"); I hit it in experiment E5. It's trivial, but it shows that every
  export is formally an unsafe act.
- **Panics.** Since Rust 1.81, a panic that escapes an `extern "C"` function
  aborts rather than unwinding into C. `"C-unwind"` is the explicit opt-in
  ([project-ffi-unwind roadmap](https://github.com/rust-lang/project-ffi-unwind/blob/master/planning/roadmap/c-unwind-abi.md),
  [rust#97235](https://github.com/rust-lang/rust/pull/97235); the 1.81 detail
  comes from a [release thread](https://redlib.hackliberty.org/r/rust/comments/1f9qbpv/announcing_rust_1810/llnht3g/?context=3)
  and was not checked against the official notes). With `panic = "abort"`
  in the profile, which I used in all experiments, a runtime panic is an
  abort, which matches Ren's panic. That needs no design work.
- **Header and layouts.** `#[repr(C)]` gives C layout. But the source of
  truth has to be the C header: emitted C includes `ren_rt.h`, and
  `ren_obj`, `ren_ctor`, `ren_array`, `ren_map`, the `rc` sign convention
  (ren_rt.h:404-477) and the frame layout are defined there. So the
  direction is bindgen (C to Rust, needs libclang), not cbindgen (Rust to
  C). cbindgen would only produce the five-function scheduler ABI. Neither
  tool is installed here and I didn't run them. Either way, two definitions
  of `ren_obj` must stay in step, and the refcount protocol (`rc > 0`
  owned, `rc < 0` shared, `rc == 0` immortal) must be duplicated in Rust or
  reached by calling out-of-line C.
- **no_std.** A `#![no_std]` + `alloc` staticlib works, but not cleanly on
  stable. Linking it failed on `_rust_eh_personality` (E3), because the
  prebuilt `liballoc`/`libcore` are built for unwinding. The fixes are a
  stub symbol (I did that) or nightly `-Zbuild-std=core,alloc
  -Zbuild-std-features=panic_immediate_abort` (the flag names are
  **unverified**). Even then, a toy core with a `VecDeque` added 289 KB to
  a stripped binary (`fmt` for panic messages). The std build added
  ~1.0 MB.

| E3: stripped arm64 binary | size |
|---|---|
| C `main` alone | 16.8 KB |
| C + toy Rust core, `no_std` + alloc, panic=abort | 305 KB |
| C + toy Rust core, std, panic=abort | 1,032 KB |
| C + crossbeam-deque + rustix (std) | 1,144 KB |

None of this blocks anything. But Ren's C runtime costs nothing until it is
used, and a Rust core costs 0.3 to 1 MB per binary unless you go to nightly
and hand-build std.

## 3. The hot inline paths: Rust cannot serve them

**E1: dup+drop pair, 400 M iterations, on the same object** (`bench.c`).
Times are ns per pair.

| caller compiled by | inline C (`static inline`) | out-of-line C in another TU | Rust `extern "C"` |
|---|---|---|---|
| clang -O2, Rust staticlib | **0.39** | 1.93 | 1.93 |
| tcc (debug), Rust dylib | 5.53 | 4.80 | 3.46 |

- Under clang, a call that isn't inlined costs 5x the inline path, whether
  the callee is C or Rust. The cost is losing the inlining, not Rust. But
  only C in the header gets inlined.
- **Cross-language LTO fails with the user's toolchain** (E4).
  `-Clinker-plugin-lto` plus Apple clang `-flto` fails to link:
  `'Unknown attribute kind (102) (Producer: 'LLVM23.1.1-rust-1.99.1-stable' Reader: 'LLVM APPLE_1_1600.0.26.6_0')'`.
  The [rustc book](https://doc.rust-lang.org/rustc/linker-plugin-lto.html)
  says "Best results are achieved by using a rustc and LLVM compilers that
  are based on the exact same version of LLVM", and its table pairs Rust
  1.91-1.94 with clang 21. Apple clang trails upstream LLVM by years. So
  release builds would need Ren to pin and ship (or require) a matching
  upstream clang. And every rustc upgrade then forces a clang upgrade.
  Release builds would also change from one C file (whole-program for free)
  to an LTO link, which is slower to build.
- **tcc can never inline across languages.** It doesn't do LTO and it
  barely inlines.

**Verdict for (a):** the inline paths stay C in `ren_rt.h`, and later become
C that Ren itself emits. That holds whatever (b) is written in, and it means
Ren keeps a C runtime of ~2,000 lines regardless.

## 4. Debug builds: tcc on macOS can't link any precompiled object

This was the most surprising result (E2).

- tcc on macOS writes **ELF** relocatable objects (`file bt.o` →
  `ELF 64-bit LSB relocatable, ARM aarch64`). It only produces Mach-O for the
  final executable. It rejects Mach-O objects: `tcc: error: xc.o:
  unrecognized file type`, for a **clang-compiled C object** as well as for
  Rust's `.rcgu.o`. Given a Rust `.a`, it finds no symbols at all.
  `ld64` likewise rejects tcc's objects ("unknown file type").
- What does work is a **dylib**. With
  `-C link-arg=-undefined -C link-arg=dynamic_lookup`, so the dylib's
  `ren_free` resolves against the executable, the Rust cdylib (387 KB) links
  under tcc and runs.
- So a precompiled runtime piece, in any language other than tcc-compiled
  C, makes a macOS debug binary depend on a runtime dylib at a known path
  (rpath). That breaks "a binary needs no installed files" for debug
  builds, and adds a dyld stub to every call. This penalty is not specific
  to Rust: it applies equally to a Zig- or clang-built runtime. Today tcc
  compiles the whole C runtime in **7 ms** (`tcc -c ren_rt.c`; clang -O2
  takes 0.42 s), so there is nothing to save by precompiling it.
- On Linux, tcc writes ELF and can generally link gcc/clang ELF archives,
  but I didn't test Rust's objects (TLS and GOTPCRELX relocations, COMDAT
  groups). **Unverified.** Worth one experiment before anything depends on
  it.

## 5. Distribution and build integration

Prior art: **Inko** has a Rust runtime (`/tmp/ren-refs/inko/rt`: 8,139
lines, 349 `unsafe`, `crate-type = ["staticlib", "lib"]`, rt/Cargo.toml).
It ships `libinko.a` per target. Cross-compiling needs
`inko runtime add TARGET` to download a prebuilt runtime
(inko/docs/source/guides/cross-compilation.md:183-199). That is the shape
Ren would take on:

1. **Ship prebuilt static libs per target.** Today that's
   {mac arm64, mac x86_64, linux x86_64/aarch64 × gnu/musl}, later wasm32,
   built in CI. The `ren` binary embeds them or downloads them. Users need
   no cargo. Debug builds on macOS need the dylib variant (section 4).
2. **Or invoke cargo from dune.** That needs cargo on every Ren
   developer's machine, and it is dune's weak spot: `(rule (action (run
   cargo build ...)))` with deps on the crate's files. It works, but dune
   can't see inside cargo's graph (my experience, **unverified** for
   current dune).

Build times are fine. A toy crate with crossbeam-deque + rustix built from
clean in 3.3 s release and 2.7 s debug, and in 0.27 s after a touch (E5).
Tokio with `rt-multi-thread,net,time` (~104 k lines of source) built from
clean in 2.9 s release (E6). This is a one-time CI cost, not a per-build
cost.

What Ren loses: today the compiler is one OCaml binary with the runtime
inside it, and any C compiler for the target is all a build needs. After
the switch: an OCaml toolchain, a Rust toolchain pinned per release, a CI
matrix of runtime artifacts, and for cross-compiling, `rustup target add`
or a download. For a language whose owner prizes "few decisive rules",
that's a second build system to own.

## 6. How much `unsafe` does a scheduler + io_uring driver need?

Counted with `grep -rho '\bunsafe\b'` in `/tmp/ren-refs`:

| code | lines | `unsafe` |
|---|---|---|
| tokio `runtime/scheduler/multi_thread` | 3,460 | 16 (all in `queue.rs`, the work-stealing queue) |
| tokio `runtime/task` (raw task, vtables, state) | 4,840 | 148 |
| tokio `runtime/io` | 2,107 | 47 |
| tokio `runtime/time` (timer wheel) | 2,326 | 62 |
| tokio `util/linked_list.rs` (intrusive list) | — | 40 |
| crossbeam-deque `deque.rs` | 2,261 | 42 |
| tokio-uring `src` | 8,878 | 90 |
| monoio | 27,513 | 577 |
| glommio | 42,185 | 313 |
| inko `rt` | 8,139 | 349 |

Tokio's `task/raw.rs` opens with `#![expect(unsafe_op_in_unsafe_fn)]` and
the comment "This module is doing the low-level task management that
requires tons of unsafe operations". In io_uring, `SubmissionQueue::push`
is `unsafe` because the kernel holds the buffer until completion
(tokio-uring/src/runtime/driver/mod.rs:133,160; src/io/pool.rs:42).

**Does Rust's safety survive this for Ren?** Less than it does for tokio,
for a reason specific to Ren:

- In tokio the tasks are Rust futures, so the `unsafe` stays inside `task/`
  and the rest of the scheduler deals in safe handles. In Ren the tasks,
  their frames, the buffers handed to io_uring and their refcounts are all
  **C objects managed by inline C in `ren_rt.h`**. Rust sees `*mut RenObj`
  and `unsafe extern "C" fn(*mut RenObj)`.
- The invariant that matters most for io_uring is that a buffer stays alive
  until its completion. In Ren that is a `ren_dup` at submit and a
  `ren_drop` at completion, on C refcounts Rust can't see. The borrow
  checker has nothing to check there.
- What Rust would really check is the internals: the run queues, the timer
  wheel, the journal's buffers, the keyed instance table, the driver's own
  bookkeeping. Those are real wins (bounds, no use-after-free inside the
  core, `Send`/`Sync` discipline on per-worker state). But the dangerous
  seam is the ownership hand-off between scheduler, frames and kernel, and
  it sits exactly at the FFI boundary.
- Ren's design makes the core smaller than tokio's. It's sans-I/O, it never
  creates threads, and drivers sit across `ren_poll_call`/`ren_reply`.
  research/runtime/r1-sans-io.md has the shape. So the amount of code Rust
  protects is maybe 2-5 k lines, of which a large share is still `unsafe`.

## 7. Testing wins: real, but most can't cross the boundary

- **loom.** Exhaustive, bounded-preemption model checking of
  atomics/threads. Tokio has ~100 files with `cfg(loom)` and
  `runtime/tests/loom_multi_thread.rs` etc. It's the strongest argument for
  Rust. But it only sees code that uses loom's types (loom/src/lib.rs:251-270,
  "Any code that does not use loom's replacement types is invisible to
  loom"). It can't model C frames or C refcounts, and SeqCst loads/stores
  are only partly supported (loom/README.md:71-75).
- **shuttle.** Randomized PCT scheduling (shuttle/README.md:8-9, 38-66).
  It has the same restriction to Rust code.
- **Miri.** Tokio runs it in CI on a pinned nightly (tokio
  .github/workflows/ci.yml:20-21, 411). But Miri can't follow the scheduler
  into Ren. It reports "unsupported operation: calling a function pointer
  through the FFI boundary", and "calling Rust functions from C is not
  supported" ([miri native_lib.rs](https://doc.rust-lang.org/nightly/nightly-rustc/src/miri/shims/native_lib.rs.html),
  [miri test](https://rust.googlesource.com/miri/+/HEAD/tests/native-lib/fail/call_function_ptr.trace.stderr)).
  Resuming a frame is exactly that. Miri needs nightly; only stable is
  installed here (`rustup toolchain list`), although `cargo-miri` is
  present.
- **What C has for the same jobs:** TSan, which Ren's experiments already
  use (`experiments/many-cores/k3/verify/k3_hybrid_tsan`); ASan, which
  `ren_rt.h:518-523` already handles; GenMC/CDSChecker for C11 atomics
  (from memory, **unverified** for current versions). And most importantly,
  **Ren's own deterministic/sim scheduler** (stage 11b's `deterministic`
  core), which tests the real core with the real frames. That's the
  language-neutral form of what shuttle gives, and Ren is building it
  anyway.

So loom and Miri are a real edge for the deque and the timer wheel taken
alone. They give nothing for the scheduler/frame/driver integration, which
is where Ren's bugs will be.

## 8. Performance parity: settled by Ren's own experiments

`experiments/many-cores` ran C and Rust twins of the same kernels.
RESULTS.md:242: "Rust is within ±10% of C everywhere". K2: "C = Rust
exactly" (SYNTHESIS.md:28). E1 confirms it: an out-of-line Rust call costs
the same as an out-of-line C call (1.93 ns). Language speed is not a reason
either way. Only inlining is (section 3).

## 9. WASM and JSPI

- JSPI is language-neutral. It wraps wasm imports
  (`WebAssembly.Suspending`) and exports (`WebAssembly.promising`). Rust has
  no advantage there, and research/runtime/r5-hosted-wasm.md covers it.
- Linking C with Rust on wasm32 was broken for years: Rust's `extern "C"`
  on `wasm32-unknown-unknown` didn't follow the standard C ABI until Rust
  1.89 (Aug 2025)
  ([Rust blog, 2025-04-04](https://blog.rust-lang.org/2025/04/04/c-abi-changes-for-wasm32-unknown-unknown/),
  [rust#133951](https://github.com/rust-lang/rust/pull/133951)). It's fixed
  now, but it shows that mixed C+Rust on wasm is the less-trodden path.
- Shared-memory wasm threads for Web Workers: Rust's std for
  `wasm32-unknown-unknown` isn't built with `+atomics`, so it needs nightly
  `-Zbuild-std` (from memory, as wasm-bindgen-rayon documents;
  **unverified**). `wasm32-wasip1-threads` exists as a target. C with
  clang/wasm-ld or Emscripten needs nothing extra.
- tcc can't target wasm, so WASM builds use clang anyway. Ren needs no
  extra toolchain there if the runtime is C.

## 10. Prior art that bears on this

- **Roc**, whose compiler was in Rust (`/tmp/ren-refs/roc-rust`), wrote the
  builtins its generated code calls in **Zig, not Rust**. They were compiled
  to LLVM bitcode or objects per target by `build.rs` and linked or inlined
  into the generated code
  (roc-rust/crates/compiler/builtins/bitcode/README.md; build.rs builds
  `builtins-host.o`, `builtins-windows-x86_64.obj`, `builtins-wasm32.o`).
  Even a Rust-first team didn't use Rust for the layer emitted code calls.
  The new compiler (`/tmp/ren-refs/roc`) is all Zig.
- **Inko** has a Rust runtime, but Inko emits LLVM IR. It can inline its
  own refcount and alloc fast paths in codegen and calls Rust only for the
  slow paths. Ren emits C, so the same split falls between the C header and
  a Rust crate. Inko pays for it with a per-target runtime artifact
  (section 5).
- **Lean 4 and Koka**, both emitting C, keep their runtimes in C/C++
  (`lean.h`, `kklib`), and ren_rt.h already cites both. They are the
  closest relatives of Ren's pipeline.

## 11. The future where Ren writes drivers in `trust`

If user drivers in `trust` Ren compile to C and call the core through the
same C ABI, a Rust core is no obstacle. But the long arc is "part of the
runtime becomes Ren itself". A C core migrates piece by piece into Ren
whose output is C, and the pieces stay in one TU in release builds and
inline into each other. A Rust core would migrate the same way, but at
every step the boundary between Rust and emitted C is an FFI boundary
again, with layouts duplicated across the two.

## 12. Where Rust would really pay off (keep this open)

The ABI is message-shaped (`ren_poll_call` / `ren_reply`). A **host**,
meaning the thing that turns calls into syscalls, can live outside the core
in any language. A flottning-specific io_uring host, or a test harness that
drives the core, could be Rust with loom and shuttle around its own state
without touching emitted C. The C ABI keeps that door open, so choosing C
for the core now doesn't rule out Rust hosts later. The experiments
already use Rust well as a **twin and oracle** (many-cores), which is a
cheap way to cross-check a C deque.

## Experiments run (all in the scratchpad, `l2/`)

- E1: dup/drop inline C vs extern C vs Rust (`bench.c`, `x.c`, `renrt/`).
- E2: tcc linking Rust `.a` (fails), Rust objects (fail), clang objects
  (fail), Rust cdylib (works).
- E3: binary size, std vs no_std (the no_std build needed a stub
  `rust_eh_personality`).
- E4: cross-language LTO, rustc LLVM 23.1.1 vs Apple clang 16 (fails).
- E5: crossbeam-deque + rustix staticlib: build times, size, edition-2024
  `unsafe(no_mangle)`.
- E6: tokio rt-multi-thread clean release build time, 2.9 s.
- E7: `tcc -c ren_rt.c` 7 ms; `clang -O2 -c` 0.42 s.

Experiments worth adding to runtime-p3, if this stays open:
1. tcc on Linux x86_64/aarch64 linking a Rust staticlib (section 4's
   unverified Linux half).
2. A Chase-Lev deque in C run under TSan + the deterministic scheduler, vs
   crossbeam-deque under loom. Seed a known ordering bug and see which
   finds it, and how fast.
3. A 300-line sans-I/O core in both languages behind the draft ABI,
   measuring resume overhead and lines of `unsafe` vs lines of C needing
   review.

## Verdict for Ren

**(a) The hot inline paths emitted C calls: C.** They stay `static inline`
in `ren_rt.h`, and later become C that Ren emits. Rust is ruled out, not
just disfavoured:
- An out-of-line call costs 5x the inlined dup/drop (1.93 vs 0.39 ns, E1).
- tcc can never inline Rust.
- Cross-language LTO fails against the user's Apple clang (LLVM 23 bitcode
  vs an LLVM 16-era reader, E4). Making it work would mean pinning a
  matching upstream clang for every rustc release.

**(b) The scheduler core and drivers: C as well, with Rust kept for
out-of-process hosts and test twins.**

The strongest reasons:
1. **Rust's safety stops at the boundary that matters.** Tasks are C heap
   frames, values carry C refcounts, and io_uring buffers are Ren objects
   kept alive by `ren_dup`/`ren_drop`. The scheduler's critical hand-offs
   are all raw pointers and `unsafe extern "C" fn`s. Miri rejects calls
   through FFI function pointers, and loom can't see C. Prior art shows
   that even with Rust tasks, scheduler/task/timer code is dense with
   `unsafe` (tokio `task/` 148, `time/` 62, monoio 577).
2. **The toolchain cost breaks properties Ren has now.**
   - A binary needs no installed files.
   - A debug build is tcc-only. tcc on macOS can't link any Mach-O object,
     so it would need a dylib.
   - Release is one TU.
   - Cross-compiling needs only a C compiler.
   - The cost of switching: a Rust toolchain per release, a matrix of
     per-target runtime artifacts as in Inko, a 0.3-1 MB binary floor, and
     nightly-only paths for no_std and wasm threads.
3. **Performance is a wash** (±10%, many-cores RESULTS.md:242). The plan to
   grow the runtime into Ren-in-`trust` emitting C favours one language
   end to end.

**The biggest risk** of this verdict is concurrency bugs in a C
work-stealing deque, timer and io_uring lifetime code, without loom's
exhaustive checking. Mitigations:
- Make the deterministic/sim scheduler the main test harness from day one.
- Run TSan and ASan in CI.
- Port a published, proven deque (Chase-Lev with the Lê et al. C11
  orderings) rather than invent one.
- Keep a Rust twin of the deque under loom as an oracle, as many-cores
  already does with twins.

If the risk materializes (repeated ordering bugs the sim doesn't catch),
the C ABI lets a Rust core take over later without touching emitted code.
The opposite risk of choosing Rust now (toolchain lock-in, a debug build
that needs a dylib, duplicated layouts) can't be undone so cheaply.

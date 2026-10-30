# L4: staying in C, done properly

Track L4 of the native-language question (C, Rust or Zig for Ren's native
runtime). This track makes the strongest honest case for C. It also
audits what has to stay C whichever language wins.

Sources: `lib/native/runtime/ren_rt.h` (2085 lines) and `ren_rt.c` (2801
lines), read in full; `lib/native/cc.ml`; `lib/native/runtime/dune`;
`foundations.md` decision 13; the prior-art clones in `/tmp/ren-refs`; and
the web pages cited inline. Anything from memory is marked *(unverified)*.

## TL;DR

- **About 1,000 lines of the runtime must be C text whatever we pick.**
  That is roughly 800 lines of `static inline` functions and macros that
  emitted C calls directly, plus 180 lines of struct layouts the emitted
  code reads field by field. Both tcc (debug) and clang (release) have to
  compile them inside every unit of program code. Rust and Zig can't
  supply them: tcc can't inline across a language boundary, and clang can
  only do it through cross-language LTO with matching LLVM versions.
- **The other 2,300 lines of code in `ren_rt.c` could live behind a C
  ABI.** About 1,300 of them are warm, though. A release build is one
  translation unit (TU), so clang inlines `ren_free`, `ren_map_find`,
  `ren_array_push_taking` and the hash into the program today. An opaque
  runtime would turn each of those into a call. The cost hasn't been
  measured; see experiment E1.
- **The bugs that cost the most in a work-stealing io_uring runtime are
  the same in all three languages.** Those are memory-ordering errors,
  lost wakeups, and buffer lifetimes when an op is cancelled. Rust's type
  system doesn't check atomic orderings. It can't model the kernel
  holding a buffer either, so Rust io_uring crates use APIs where the
  operation owns the buffer. Even the published C11 Chase-Lev deque had
  bugs that only a model checker or real use found.
- **C does leave memory-safety bugs open:** use-after-free, double free,
  out-of-bounds, unsigned wraparound, and data races on plain fields. Pony
  is the closest prior art (a C runtime with an actor scheduler and
  epoll/kqueue/IOCP). Its changelog shows these bugs keep turning up for
  years (§4).
- **A new finding: tcc 0.9.28rc on macOS arm64 crashes on any
  `_Thread_local` or `__thread` access.** I tested this here (§1.4). The
  header's thread modes make `ren_heap` thread-local and use it from
  inline code, so a debug build with threads would crash on macOS. Any
  thread-aware hot path has to take an explicit worker context instead of
  using TLS. That holds whatever language the scheduler is written in.
- **Verdict:** (a) the hot paths stay C, with no real alternative. (b) The
  scheduler core and drivers should also be C, in a TU of their own that
  is always compiled by clang and cached, behind the five-function ABI,
  with the checking stack in §2. The biggest risk is use-after-free and
  data races in the op and task tables, which Rust would rule out at
  compile time. §5 gives a measured trigger for revisiting the choice.

---

## 1. Audit: what in the runtime has to stay C

### 1.1 How the runtime reaches a binary today

- The runtime is **embedded in the compiler as two OCaml strings**
  (`lib/native/runtime/dune`: "so `ren build` writes it into each C file
  and a binary needs no installed files").
- **A release build is one C file:** header, then `ren_rt.c`, then the
  program, compiled by `cc -O2 -ffp-contract=off` (`ren_rt.h:22-27`,
  `cc.ml:166-181`). clang can therefore inline *any* runtime function
  into program code, not just the header's `static inline` ones.
- **A debug build compiles units in parallel with tcc:** `ren_rt.c` as a
  unit of its own, plus the program in units of a few modules
  (`cc.ml:128-163`). Program units include **no system headers**
  (`ren_rt.h:39-90`, the `REN_UNIT` branch), because headers took 6.7 of
  tcc's 8.1 ms per unit (foundations.md decision 13). Every header type
  and inline function is therefore compiled by tcc in every unit.
- The emitter refers to about 144 distinct `ren_*` names
  (`grep -o '"ren_[a-z0-9_]*' lib/native/emit_c.ml | sort -u | wc -l`).

### 1.2 Line counts by class

These were counted by a small brace-matching classifier over each file.
Counts are approximate to within a few lines.

| File | Class | Lines | Must be C text? |
|---|---|---:|---|
| ren_rt.h | `static inline` function bodies (incl. `REN_SIZED_ARRAY`/`REN_NARROW` instantiations) | 716 | **yes**: hot, inlined into emitted C by tcc and clang |
| ren_rt.h | function-like macros (`ren_buf_*`, `REN_STACK_CHECK`, generators) | 83 | **yes**: hoisted-loop access, `restrict` relies on them being macros (`ren_rt.h:1036-1046`) |
| ren_rt.h | types, enums, struct layouts (`ren_obj`, `ren_array`, `ren_str`, `ren_map`, `ren_desc`, `ren_ev`, `ren_handler` ...) | 181 | **yes**: emitted C reads and writes these fields directly. Any other language would have to mirror them |
| ren_rt.h | prototypes of out-of-line functions | 138 | the C ABI surface |
| ren_rt.h | comments / blank / preprocessor / const macros | 959 | — |
| ren_rt.c | out-of-line definitions (public + static) | ~2,190 | **no**: could be any language behind a C ABI |
| ren_rt.c | inline helpers, macros, types | ~150 | follow the code they serve |
| ren_rt.c | comments / blank / preprocessor | ~460 | — |

**Totals: about 980 lines must be C text** (799 of hot code and 181 of
layout). About 2,300 lines of code in `ren_rt.c` could move behind an
ABI.

### 1.3 Function-by-function classification

**Hot, inline, must be header C** (`ren_rt.h`):

| Group | Lines | Functions |
|---|---|---|
| Value representation | 212-245, 334-356 | `ren_f32_bits`, `ren_f32_of_bits`, `ren_sized_word`, `ren_is_scalar`, `ren_box`, `ren_tag`, `ren_niche_tag` |
| Counting (Perceus) | 404-485 | `ren_rc`, `ren_dup`, `ren_drop`, `ren_is_unique`, `ren_mark_shared` (stub). These are the most-called functions in any program. The `REN_RC_SHARED`/`REN_RC_ATOMIC` modes already put C11 `__atomic` builtins here |
| Heap fast path | 528-575 | `ren_words`, `ren_alloc_bytes`, `ren_free_bytes` (free-list pop and push, touching `ren_heap` directly) |
| Objects and reuse | 578-656 | `ren_fields`, `ren_ctor_size`, `ren_ctor_objs`, `ren_set_objs`, `ren_alloc_ctor`, `ren_reset`, `ren_reuse` |
| Arrays | 658-1112 | `ren_array_len/check/unique/writable/own/get/get_s/take`, `ren_sized_load/store`, `ren_array_load/get_w/take_w/set_taking*/init_w`, 8×2 sized accessors, `ren_array_slots*`, `ren_array_push_slots_taking_k` (inlined fast push, measured in compiler.md "Bytes stage"), `ren_slots_dup/drop`, `ren_array_set_field_taking*`, `ren_buf_check`, `ren_dup_elem`, and 14 `ren_buf_*` macros |
| Strings and bytes | 1117-1118, 1182-1199 | `ren_str_len`, `ren_str_data`, `ren_bytes_at`, `ren_buf_byte` |
| Arithmetic | 1238-1261, 1474-1544 | `ren_narrow_*` (7 + f32), `ren_add/sub/mul` with tcc fallbacks for the overflow builtins (`ren_rt.h:1474-1497`), `ren_shl`, `ren_shr` |
| Layer 3 (formats) | 1286-1455 | `ren_bytes_room`, `ren_bswap`, `ren_bytes_load`, `ren_u64_read`, `ren_bytes_fits`, `ren_bytes_writable`, `ren_bytes_store`, `ren_var_bits/len/size`, `ren_bytes_set_var` |
| NaN | 1569-1640 | `ren_nan_tagged`, `ren_fmade`, `ren_f*_d` (6), `ren_nan_check`, `ren_float_sum` |
| Descriptors (generic code) | 1734-1838 | `ren_desc_elem`, `ren_ctor_field`, `ren_desc_counted`, `ren_dup_val`, `ren_drop_val`, `ren_desc_is_float` |
| Maps | 1890-1908 | `ren_map_len`, `ren_map_value` |
| Evidence | 1995-2021, 2068-2075 | `ren_find`, `ren_find_args`, `ren_method_of` (handler lookup on every dependency call in debug builds) |
| Stack check | 326-330 | `REN_STACK_CHECK` (every function prologue) |

**Warm, out of line, but inlined in release because it's one TU**
(`ren_rt.c`, about 1,300 lines). Moving these behind an opaque ABI is
where a non-C runtime would cost the most:

| Section | Lines (approx.) | Why warm |
|---|---|---|
| memory: `ren_alloc_slow`, `ren_alloc_array_c` and friends, `ren_free`, `ren_free_one`, `ren_release`, `ren_todo_push` | 72-366 | every freed object goes through `ren_free` |
| shared counting: `ren_dup_shared`, `ren_drop_shared`, `ren_mark_shared` | 367-466 | the cold side of the counting fast path once tasks share objects |
| reuse: `ren_drop_unkept`, `ren_free_keeping`, `ren_free_token` | 467-493 | Perceus reuse paths |
| arrays: `ren_array_copy`, `ren_array_grow` (deliberately `noinline`, `ren_rt.c:558-564`), `ren_array_push_taking*`, `ren_array_unshare`, struct pushes | 494-691 | every push that isn't the inline fast path |
| strings: `ren_str_of/concat/eq` | 692-712 | string building |
| hashing: `ren_wyhash`, `ren_hash_in` and friends | 2027-2220 | every map operation |
| maps: `ren_map_probe/find/set/put/remove/room/reindex` | 2221-2594 | every map operation |
| evidence: `ren_install`, `ren_given`, `ren_desc_same` | 2685-2736 | every `with` and every generic dependency lookup |

**Cold, out of line, any language would do** (about 1,000 lines). These
are panics and messages (`ren_panic`, `ren_*_panic`, `ren_rt.c:11-71`, NaN
1295-1391). Also `show`, print and the equality/compare/`nan_in` walks
over descriptors (1392-2026). Those are warm only in generic debug code
and for user `==` on compound types. Then slices, splice, split, trim and
UTF-8 checks (713-1276), `ren_div/rem/neg` and float rounding
(1277-1391), the console (2737-2749), and `ren_run` with its 1 GiB thread
(2750-2801).

**The planned scheduler and drivers split the same way.** Their hot,
inline part is small: the budget/yield check at safe points, the shared
counting paths (which are already header C), and a per-worker heap
pointer. Everything else is out of line: `ren_start/run/poll_call/reply/
poll_deadline`, the deque, the timer wheel, the drivers, the blocking pool
and the journal. That part could be any language behind the C ABI. The
question for (b) is whether it *should* be.

### 1.4 What the hot C needs from the threaded runtime: no TLS

The header already plans for threads. `REN_THREAD_LOCAL` makes `ren_heap`
and the free list `_Thread_local` (`ren_rt.h:386-393, 534`; `ren_rt.c:96,
220`), and `ren_alloc_bytes` reads `ren_heap` inline. I tested tcc's
support for this here (tcc 0.9.28rc 2026-10-16, HEAD@e23dabe, AArch64
Darwin, the one `tools/tcc.sh` installs):

```
_Thread_local int tl; int main(void){ tl=3; return tl; }   -> tcc: SIGSEGV (exit 139); clang: exit 3
__thread int tl;      (same)                                -> tcc: SIGSEGV (exit 139)
__atomic_fetch_add / __atomic_load_n                         -> tcc: OK
<stdatomic.h> store/load/CAS seq_cst / atomic_thread_fence   -> tcc: OK
```

So **on macOS, a debug build of a threaded program would crash on its
first allocation** if the heap stays thread-local in inline code. tcc's
TLS on Linux ELF is untested *(unverified)*. The fix fits Ren's taste
anyway. Pass an explicit per-worker context through emitted code: either
as a parameter, or as one global that each worker's stack points at,
read through the stack-limit pattern that `REN_STACK_CHECK` already uses.
`ren_stack_limit` and `ren_here` are process globals today
(`ren_rt.c:7-9`), and they need the same treatment once there are
workers. This constraint sits on the *emitted* C. It holds whichever
language owns the scheduler.

---

## 2. How serious C runtimes stay correct

### 2.1 Chase-Lev in C11: the reference and its bugs

- **The reference:** N. M. Lê, A. Pop, A. Cohen, F. Zappa Nardelli,
  *Correct and efficient work-stealing for weak memory models*, PPoPP
  2013, pp. 69-80, DOI 10.1145/2442516.2442524
  ([portal](https://research.manchester.ac.uk/en/publications/correct-and-efficient-work-stealing-for-weak-memory-models/)).
  It proves an optimised Chase-Lev deque correct on ARM and POWER, and
  gives x86 and portable C11 versions. HotSpot's task queue took its
  fence and load-acquire from this paper
  ([hotspot-dev, 2013](https://mail.openjdk.org/pipermail/hotspot-dev/2013-March/008848.html)).
  The C11 shape, from memory *(unverified; check against the paper's
  Fig. 1 before porting)*:
  - `take`: a relaxed store of `bottom`, then a `seq_cst` fence, then a
    relaxed load of `top`, and a `seq_cst` CAS on `top` for the last
    element.
  - `steal`: an acquire load of `top`, then a `seq_cst` fence, then an
    acquire load of `bottom`, then a consume or acquire load of the
    buffer, then a `seq_cst` CAS on `top`.
  - `push`: a release fence, or release store, of `bottom`.
- **It still had bugs:**
  - Norris and Demsky's CDSChecker paper (OOPSLA 2013, DOI
    10.1145/2509136.2509514) says in its abstract that the tool "found
    errors in a recently published C11 implementation of a work-stealing
    queue" ([bib](https://bibtex.github.io/OOPSLA-2013-NorrisD.html)). An
    LWN commenter identifies that implementation as Lê et al.'s
    ([LWN 827285](https://lwn.net/Articles/827285)). The tie is
    second-hand.
  - Andy Wingo found an **integer underflow** in 2022 while using the
    deque: `take` on an empty, freshly initialised deque decrements a
    `size_t` `bottom`, so the deque appears to hold `(size_t)-1`
    elements
    ([wingolog](https://wingolog.org/archives/2022/10/03/on-correct-and-efficient-work-stealing-for-weak-memory-models)).
  - A Maude-based study reports a put/steal race on an empty deque in the
    published ARM version (search summary of
    [arXiv 1802.04406](https://arxiv.org/pdf/1802.04406); not read in
    full).
- **The lesson for Ren:** don't take a lock-free structure from a paper on
  trust. Use signed `int64_t` indices. Port from a version that has been
  model-checked, and model-check our own port. Note that the underflow is
  a C pitfall (unsigned wraparound) that Zig's safe build modes would trap
  and Rust's debug builds would panic on. The ordering bugs are not
  C-specific.

### 2.2 Model checking lock-free C

- **GenMC** ([github.com/MPI-SWS/genmc](https://github.com/MPI-SWS/genmc);
  [CAV'21 paper](https://plv.mpi-sws.org/genmc/cav21-paper.pdf)) is a
  stateless model checker "for C/C++ and Rust programs". Rust support is
  experimental. It runs on LLVM IR, so it checks the real C source with
  `pthread` harnesses. It explores RC11 and IMM executions, and it was
  built to find bugs in data structures like this deque *(model names
  from memory, unverified)*.
- **CDSChecker/CDSSpec:** C/C++11 atomics, the tool that found the bugs
  above.
- **CBMC** (bounded model checking of C) suits sequential invariants:
  ring-index arithmetic, timer-wheel bucket maths, the journal's framing.
  It isn't the right tool for weak-memory concurrency.
- **herd7 and LKMM** (`tools/memory-model` in the Linux tree; herd7 from
  the diy suite at diy.inria.fr) check *litmus tests*, not whole
  programs *(unverified paths)*. They help when reasoning about a
  specific fence pattern, such as the io_uring SQ tail release and CQ
  head acquire. They don't replace GenMC on the deque.
- **The Rust equivalent is `loom`**, which tokio uses to test its queue
  (`/tmp/ren-refs/tokio/tokio/src/runtime/scheduler/multi_thread/queue.rs:3-4,
  62-68`, which also shrinks the queue under `cfg(loom)`; tests in
  `tokio/src/runtime/tests/loom_*.rs`). Rust's real advantage here is
  that loom sits in the normal `cargo test` flow. GenMC is a separate
  LLVM-version-pinned tool. Either way, someone has to write the
  harnesses.

### 2.3 Sanitizers

- **ASan and UBSan are already in Ren's test suite**
  (`bench/build.t:22`, `bench/build.t:2029`, `bench/strs.t:74-75`,
  `bench/bytes.t:99-100`, which set
  `REN_CFLAGS='-fsanitize=address,undefined'`). The heap switches itself
  to malloc under ASan so use-after-free is still caught
  (`ren_rt.h:513-526`).
- **TSan:**
  - OCaml 5 ships a TSan mode for its C runtime, with code to keep TSan's
    shadow stack balanced across effects and exceptions
    (`/tmp/ren-refs/oxcaml/runtime/tsan.c:1-60`). Its runtime uses C11
    atomics through thin wrappers (`runtime/caml/camlatomic.h:41-79`).
  - Pony builds a `-thread_sanitizer` runtime variant
    (`/tmp/ren-refs/ponyc/CMakeLists.txt:188-208`, also ASan and UBSan).
  - **One limitation matters directly: TSan doesn't model
    `atomic_thread_fence`.** GCC 11+ warns with `-Wtsan`; LLVM added a
    matching warning
    ([llvm PR 166542](https://github.com/llvm/llvm-project/pull/166542);
    [kcsan patch](https://lore.kernel.org/lkml/20211130114433.2580590-13-elver@google.com/)).
    Chase-Lev depends on `seq_cst` fences, so TSan is blind or noisy on
    exactly the deque. That is why GenMC is needed for the deque and TSan
    for everything around it.
- **MSan** (clang, Linux only) adds little once the runtime zeroes or
  writes what it reads. The heap's rule is "every allocation's caller
  writes all of what it reads" (`ren_rt.h:499-500`). It's optional.

### 2.4 Deterministic simulation and fuzzing: the biggest lever, in any language

- **Pony's C runtime has *systematic testing*:** a seeded scheduler that
  serialises threads and replaces the CPU clock with a logical one, so
  scheduler decisions are a deterministic function of the seed
  (`/tmp/ren-refs/ponyc/src/libponyrt/sched/systematic_testing.h`,
  `SYSTEMATIC_TESTING.md`).
- **TigerBeetle (Zig)** gets its confidence from the VOPR simulator and
  TigerStyle rather than from the language. TigerStyle requires an
  average of at least two assertions per function
  (`/tmp/ren-refs/tigerbeetle/docs/TIGER_STYLE.md:112-118`) and no
  allocation after start-up (`:151-152`).
- **Ren's planned ABI already *is* a simulator harness.** `ren_run(core,
  w, now_ns, budget)`, `ren_poll_call`, `ren_reply` and
  `ren_poll_deadline` give the host all of time, I/O and ordering. A
  libFuzzer target can take a byte string as a schedule (which worker
  runs, how long the budget is, which reply comes back, what the clock
  says) and drive many workers on one thread. That covers every logic
  bug in the core except the true-parallelism ones (memory ordering),
  which GenMC and TSan cover. This is a design property, not a language
  property, and it is the main reason C's weaker compile-time checking
  costs less here than in a classic runtime.

### 2.5 How long-lived C projects keep correct

- **SQLite** ([testing](https://www.sqlite.org/testing.html)):
  - about 590 times as much test code as library code;
  - 100% branch coverage and MC/DC, with `testcase()` macros;
  - dbsqlfuzz at about a billion mutations a day, plus OSS-Fuzz;
  - UBSan, `-ftrapv` and Valgrind;
  - injected OOM, I/O errors and crashes at every Nth operation;
  - 6,754 `assert()`s.

  Their stated preconditions for ever moving to Rust include "100% branch
  coverage testing of the compiled binaries" and graceful OOM recovery
  ([whyc](https://www.sqlite.org/whyc.html)). Ren's journal and
  storage-engine work (flottning) should copy the *anomaly testing*:
  fail the Nth `ren_reply` and the Nth allocation. The language choice
  doesn't affect that.
- **liburing** is the reference user-space io_uring library, in C. Its
  ring access is header inlines (156 `IOURINGINLINE` functions in
  `/tmp/ren-refs/liburing/src/include/liburing.h`), with explicit
  `io_uring_smp_store_release` and `io_uring_smp_load_acquire`
  (`src/include/liburing/barrier.h:45-79`). It has 275 test files and a
  `--enable-sanitizer` configure flag (`configure:35,87,654`). It even
  ships a `liburing-ffi` variant, because static inlines don't cross an
  FFI boundary: the same split as Ren's header.
- **OCaml 5** uses C11 atomics in the runtime, a TSan build mode, and a
  property-based linearisability suite. That suite is
  ocaml-multicore/multicoretests (Lin/STM), which found runtime bugs
  *(from memory, unverified)*.

### 2.6 "C done properly" for Ren, concretely

1. **Two layers, two compilers.**
   - The header layer stays as it is: single-threaded fast paths, tcc and
     clang, no TLS, no fences except in the shared counting paths.
   - The **scheduler core and drivers are a third unit, `ren_sched.c`,
     always compiled by clang -O2** with sanitizer variants. It is built
     once per (compiler version, target, flags) and cached. That way tcc
     never compiles lock-free code, and debug builds don't pay to compile
     it.
   - tcc's arm64 atomics passed my smoke test, but they are not a code
     path to bet a deque on.
2. **C11 `<stdatomic.h>` with an explicit order on every operation.**
   No `volatile`, and no default (seq_cst) orders by accident. Wrap the
   operations as OCaml does in `camlatomic.h`. Use signed `int64_t`
   indices and counters everywhere.
3. **Port the deque from a model-checked source, and check it.** Keep one
   GenMC harness per lock-free structure in CI (push/take/steal with 2-3
   threads), run on the real source file.
4. **Identify ops by generation, not by pointer.** Every in-flight
   io_uring/kqueue op's `user_data` is `(slot << 32) | generation` into an
   op table, never a raw pointer. A stale completion then fails a
   generation check instead of becoming a use-after-free. This is Ren's
   own `Table`/`Pool` generational-slot design, and it removes most of the
   class Rust would otherwise catch.
5. **The kernel owns a buffer from submission until its completion.**
   This is the same rule Rust io_uring crates had to adopt (§4).
   Cancellation submits a cancel and waits for both completions before
   the buffer goes back.
6. **Sanitizer matrix in CI:**
   - ASan+UBSan for everything (already there);
   - TSan over the runtime with real threads, with the deque's fences
     annotated or excluded;
   - optionally the clang static analyzer, plus `-Wthread-safety`
     annotations on the blocking pool's mutexes.
7. **A fuzzer over the sans-I/O ABI** (§2.4), plus fault injection (fail
   the Nth reply or allocation) as SQLite does.
8. **TigerStyle assertions in debug builds** (`REN_DEBUG`): two per
   function on average, and paired assertions on the op table and deque
   invariants.
9. **One C dialect: C11 plus the GNU builtins tcc supports.** No C23 in
   the header, since tcc's C23 is partial *(unverified)*. The scheduler
   unit could use C23 features under clang, but there's no need.

---

## 3. The case for one language

1. **A binary needs nothing installed, and `ren build` needs nothing but
   a C compiler.**
   - Today the compiler carries its runtime as two strings
     (`runtime/dune`). The user's `cc` (or tcc) builds it for *their*
     target: macOS arm64 and x86_64, Linux glibc or musl, x86_64 or
     aarch64, and WASM later through clang's wasm32 target or wasi-sdk.
   - With a Rust or Zig runtime, the compiler release would have to ship
     a prebuilt static library per target triple and C library, or else
     require cargo or zig on the user's machine. Roc did exactly that. Its
     builtins are Zig, compiled into LLVM bitcode at compiler build time
     and imported into the LLVM backend
     (`/tmp/ren-refs/roc-rust/crates/compiler/builtins/bitcode/README.md`).
     For its non-LLVM dev backend it also needs a separate
     `builtins-host.o` (`bitcode/build.rs:30-33`).
   - Ren's backend is "C compiled by whatever C compiler", so there is no
     bitcode path through tcc.
2. **Layouts have one source of truth.** `ren_obj`, `ren_array`,
   `ren_str`, `ren_map`, `ren_ev`, `ren_desc` and `ren_handler` are read
   by emitted code, by the header inlines and by the out-of-line runtime.
   In C they are declared once. In Rust they are `#[repr(C)]` copies kept
   in sync by hand or by cbindgen/bindgen. Zig is better here: it can
   `@cImport` `ren_rt.h` directly *(unverified for this header's
   `REN_UNIT` branch)*.
3. **Release inlining across the whole runtime comes free.** One TU means
   clang inlines the warm `ren_rt.c` paths (§1.3), and measured tuning
   already depends on it: `ren_array_grow` was kept `noinline` after
   measurement (`ren_rt.c:558-564`), and `ren_array_push_slots_taking_k`
   was inlined after measurement (`ren_rt.h:956-976`). A Rust or Zig
   runtime gets that only through cross-language LTO, which needs clang
   and rustc to share an LLVM version
   ([rustc linker-plugin-lto](https://doc.rust-lang.org/rustc/linker-plugin-lto.html)).
   Apple's clang doesn't match any rustc's LLVM *(unverified in detail)*,
   and tcc can't take part at all. Pony hit the same problem: it has a
   `--runtimebc` mode that links its C runtime as bitcode, and a history
   of fixing it ("Fix runtime bitcode performance", PR #6133; "Fix
   optimizer attributes lost after runtime linking", PR #6148, in
   `/tmp/ren-refs/ponyc/CHANGELOG.md`).
4. **One debugger, one profiler, one set of sanitizers, one build.** lldb
   already steps through emitted C with `#line` (decision 13). A panic in
   the scheduler unwinds through C frames that the same tools read. The
   owner is new to OCaml. Adding Rust or Zig means a fourth language in
   the repo (OCaml, C, Ren, plus one), with its own build system inside
   dune.
5. **The runtime moves toward Ren anyway.** Drivers are meant to be
   writable in Ren inside `trust`, and Ren compiles to C. A C runtime is
   the same target as the code that later replaces it. Ren-written drivers
   become ordinary emitted C linked against the same header. A Rust or Zig
   core would be an island that Ren code calls into through an FFI the
   runtime itself doesn't use.
6. **The sans-I/O core is small, and the hard parts are algorithms.** The
   core is a few thousand lines of deque, timer wheel, run queues and op
   table. The bugs that dominate (§4) are orderings, wakeups and
   cancellation, which no language checks. What helps is GenMC, the
   simulator, and assertions.

---

## 4. The honest costs: what C leaves open

### 4.1 Bug classes in a work-stealing io_uring runtime

| Class | Where it lives in Ren's plan | C | Rust (safe code) | Zig (safe build modes) | What catches it in C |
|---|---|---|---|---|---|
| Use-after-free of a task or op record (stale completion, task freed while queued or woken) | op table, run queues, wakers | open | closed outside `unsafe` | open (no borrow checking; GPA detects some) | generation-checked `user_data`; ASan; the simulator |
| Double free | task teardown, cancel + completion | open | closed | open | ASan; asserts on slot state |
| Out-of-bounds ring/buffer index | deque buffer, SQ/CQ rings, journal | open | bounds-checked | bounds-checked | UBSan bounds checks; asserts; CBMC on index maths |
| Integer wraparound (Lê et al.'s `size_t` underflow) | deque indices, timers | open | panics in debug only | trapped in safe builds | signed `int64_t`; `-fsanitize=unsigned-integer-overflow` (clang) |
| Data race on a plain field | worker state touched by a stealer | open | closed (`Send`/`Sync`) | open | TSan; ownership rules in comments; `-Wthread-safety` |
| **Wrong memory order** | deque, wakeup flags, SQ tail | open | **open** (atomic orders are unchecked; same C++ model) | **open** | GenMC/CDSChecker; herd7 for fence idioms |
| **Lost wakeup / deadlock / early quiescence** | park/unpark, blocking pool, shutdown | open | **open** | **open** | simulator; TSan (deadlocks); liveness asserts |
| **Kernel writes into a buffer after cancel** | io_uring reads | open | **open in the type system**; crates had to make the op own the buffer | open | the ownership rule (§2.6 item 5); simulator models late completions |
| fd reuse race (close vs in-flight op on a recycled fd) | drivers | open | open | open | fd generations / registered files |
| Uninitialised read | heap free lists | open | closed | open (undefined values) | ASan/MSan; the "caller writes all" rule |
| UB from aliasing casts (`ren_obj*` to `ren_array*`) | everywhere, by design | open | n/a (the layout is unsafe anyway) | n/a | common-initial-member layout; optionally `-fno-strict-aliasing` *(not set today)* |

Three of the classes are **open in all three languages**: memory order,
lost wakeups and cancellation. For the cancellation case, withoutboats'
analysis is the reference: cancelling a future doesn't stop the I/O, "the
kernel will write to or read from that buffer even if you cancel the
future", so "the kernel must own the buffer"
([Notes on io-uring](https://without.boats/blog/io-uring/)). Rust io_uring
runtimes are still full of `unsafe`: about 90 occurrences in tokio-uring's
`src`, about 579 in monoio's, and 53 in tokio's scheduler alone (counted
with `grep -c unsafe` under `/tmp/ren-refs`).

### 4.2 How often these bite, from the evidence

- **Pony's C runtime, 2015-2026**
  (`/tmp/ren-refs/ponyc/CHANGELOG.md`, which mixes compiler, stdlib and
  runtime fixes). Runtime entries include:
  - use-after-free in IOCP (#5046, #5055, #5091) and at Windows socket
    teardown (#5805);
  - use-after-free in actor heap finalisation (#4522) and with fast actor
    reaping (#4616);
  - races in epoll (#4658), kqueue (#2193), ASIO wakeups being lost
    (#2561), and "Race conditions that can lead to a segfault" (#3667);
  - "Race condition in scheduler queues on weakly-ordered architectures";
  - "Strengthen memory ordering on runtime queue pushes" (#5245) and
    "Strengthen the ordering for some atomic operations" (#4083);
  - early quiescence (#4550), shutdown hangs (#5037), and scheduler timing
    bugs (#5535, #5538, #5539).

  Roughly a third of those would have been compile errors in safe Rust:
  the use-after-free bugs and some of the races. The rest are ordering,
  liveness and kernel-lifetime bugs that Rust doesn't check. The
  use-after-free bugs cluster in **completion-based I/O (IOCP)**, which is
  the model io_uring shares. That is a direct warning for Ren's io_uring
  driver.
- **Rust doesn't make the problem go away:** tokio's RUSTSEC-2021-0124 /
  CVE-2021-45710 was a data race in `oneshot` after `close`, inside
  `unsafe`. The advisory notes memory corruption was observed in practice
  ([advisory](https://rustsec.org/advisories/RUSTSEC-2021-0124);
  [1.13.1](https://github.com/tokio-rs/tokio/releases/tag/tokio-1.13.1)).
- **Base rates from industry:** in Android, memory-safety bugs were 76% of
  vulnerabilities in 2019 and 24% in 2024, after new code moved to
  memory-safe languages. Vulnerability density falls with code age, and
  5-year-old code has 3.4-7.4 times lower density than new code
  ([Google, Sept 2024](https://security.googleblog.com/2024/09/eliminating-memory-safety-vulnerabilities-Android.html)).
  For Ren the runtime core is *all new code*, so this is the window where
  C costs the most. It also means the cost falls over time if the core
  stays small and stable.

**What this means for Ren:**

- Expect the first year of a C scheduler and io_uring driver to produce a
  steady trickle of use-after-free bugs and data races. Most of them
  would be surfaced in testing by generation-checked op slots, ASan, TSan
  and the simulator, not by users.
- For a project whose 1.0 target is a storage engine and server
  (flottning), the leftover risk is real. It's concentrated in about
  2-4k lines that the plan already isolates behind five functions.

---

## 5. Experiments this track proposes

These are queued, not run: no benchmarks were run here, to keep
runtime-p2's numbers clean. The only things run were the tcc TLS and
atomics smoke tests, a few milliseconds each.

- **E1: the cost of an opaque runtime.** Build the release benchmark
  suite twice:
  - as one TU (today);
  - with `ren_rt.c` as a separate `-O2` object and no LTO, which stands in
    for a Rust or Zig runtime behind the C ABI.

  Compare cycles per benchmark. If the gap is under about 2%, the
  inlining argument (§3 item 3) drops out of the decision. If the maps,
  strings and free paths lose more, it's a strong argument for C.
- **E2: tcc TLS on Linux x86_64 and aarch64.** This confirms whether
  §1.4 is macOS-only. The no-TLS rule should be adopted either way.
- **E3: Chase-Lev in C11 under GenMC.** Port the deque with signed
  indices, write push/take/steal harnesses for 2-3 threads, and measure
  GenMC's run time and whether it finds a seeded ordering bug (one
  `seq_cst` weakened to `acq_rel`). This prices the "C done properly"
  stack in hours of work.
- **E4: a fuzzer over the sans-I/O ABI.** Build a libFuzzer harness that
  drives `ren_run`, `ren_poll_call` and `ren_reply` from bytes, with ASan.
  Seed it with a stale completion and with a cancel racing a completion,
  and check that the generation-checked op table turns both into an
  assert, not a use-after-free.

**Revisit trigger:** after the 11b native slice, count the
memory-safety bugs (use-after-free, double free, out-of-bounds, plain-field
races) that ASan, TSan and the simulator find in the scheduler and driver
unit. If they keep arriving after the first two months, or one reaches a
user, move *that unit* to Zig. Zig can `@cImport` the header, has trapped
arithmetic and bounds checks, and compiles with clang's toolchain. The
hot header stays C either way.

---

## Verdict for Ren

**(a) The hot inline paths emitted C calls: C, with no real alternative.**
About 800 lines of `static inline` functions and macros, plus 180 lines
of layouts, have to be C text that tcc (debug, per unit, without system
headers) and clang (release, one TU) compile into every unit. This covers
counting, allocation, array and bytes access, checked arithmetic, NaN
handling, evidence lookup and the stack check. Rust can't provide these
without cross-language LTO, which tcc can't take part in. Zig could only
provide them by generating C. Whichever language owns the scheduler, this
layer has two new rules:

- **No TLS:** tcc on macOS arm64 segfaults on `_Thread_local`, as tested
  here. Use an explicit worker context instead.
- **No lock-free code compiled by tcc.**

**(b) The scheduler core and drivers: C as well.** Write them in C11 with
explicit atomic orders, as their own unit always compiled by clang -O2
and cached, behind the five-function sans-I/O ABI, with the §2.6 stack:

- GenMC on every lock-free structure;
- ASan, UBSan and TSan in CI;
- a fuzzer over the ABI, plus the deterministic simulator;
- generation-checked op slots, so `user_data` is never a pointer;
- kernel-owned buffers until their completion;
- TigerStyle assertions.

Strongest reasons:

1. One toolchain, and the zero-install property stays: the runtime ships
   as source strings, and every target's `cc` builds it.
2. Layouts have one source of truth, and release builds keep inlining the
   warm runtime paths.
3. The bug classes that cost the most here (memory order, lost wakeups,
   cancellation and kernel buffer lifetimes) are unchecked in Rust and Zig
   too. Ren's sans-I/O and simulation design attacks them directly.
4. Drivers are meant to become Ren, which compiles to C, so a C core is
   the same target as its successor.

**Biggest risk:** use-after-free and plain-field data races in the op
table, task lifecycle and io_uring completion paths. Rust would make these
compile errors. Pony's C runtime kept shipping exactly these in its
completion-based (IOCP) driver for years. Mitigate with generation-indexed
ops plus ASan, TSan and simulation. Use the §5 revisit trigger to move
only that unit to Zig if the bugs keep coming. The hot header stays C
whatever happens.

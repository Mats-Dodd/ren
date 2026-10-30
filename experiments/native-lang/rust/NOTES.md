# The Rust entry (native-lang slice)

Machine **cloud**. Written 2026-10-30, 13:10 to 13:56 UTC. Spec: `../SPEC.md`.
ABI: `../harness/slice.h`, the nine-function ABI.

## Layout

```
Cargo.toml            workspace: core/ and hot/; panic = "abort" in both profiles
build.sh              <profile> <outdir>  (the contract in ../README.md)
test.sh               the Rust-only checks: cargo test, Miri, loom, fuzz regressions, unsafe count
tools/bindgen_slice.rs  shared by both build.rs: the bindgen CLI on $REN_HARNESS/slice.h,
                      plus REN_LAYOUT_LIST read out of slice.h into the layout table
tools/count_unsafe.py lines inside unsafe blocks and unsafe fn bodies (not keyword counts)
core/src/deque.rs     Chase-Lev, SPEC §A.3, signed i64 indices, growth, retired rings
core/src/sched.rs     the core, SPEC §B: op table, scheduling word, park/wake, journal
core/src/journal.rs   the journal wire, field by field, little-endian
core/src/ffi.rs       the 9 + 7 + 5 C exports, each type-checked against bindgen's declaration
core/src/layout.rs    ren_layout_table (generated from REN_LAYOUT_LIST, values from offset_of!)
core/src/drv/         mod.rs (ren_drv_*, recording), linux.rs (the C.1 loop), epoll.rs,
                      uring.rs (raw syscalls; kernel ABI from bindgen on <linux/io_uring.h>),
                      replay.rs (replay and fuzz)
core/src/rt.rs        no_std only: a GlobalAlloc over malloc, a panic handler that aborts
core/tests/optable.rs pure-Rust conformance tests (no harness C) that also run under Miri
core/tests/loom_deque.rs  loom model of the deque
hot/src/lib.rs        ren_hot_* (no_std staticlib), SPEC §E
fuzz/regress-lost-call.bin  the 5-byte libFuzzer find, kept as a regression input
```

Generated bindings go to `target/<profile>/.../out/` (`slice.rs`, `uring.rs`,
`layout_gen.rs`). None is checked in. Each profile and plant has its own target
dir, `target/<profile>[-Pn]`.

## Profiles

| profile | what | toolchain |
|---|---|---|
| release | std, panic=abort, codegen-units=1 | stable 1.97 |
| release-nostd | `#![no_std]` + alloc over libc malloc, panic=abort | stable 1.97 |
| debug | dev profile: overflow checks, debug assertions, panic=abort | stable 1.97 |
| tsan | `-Zsanitizer=thread -Zbuild-std=core,alloc`, no_std, feature `tsan` | nightly 1.101 (this profile only) |
| release-hot | libren_hot.a only (W5 iii); libren_core.a is empty | stable |
| lto-hot | libren_hot.a with `-Clinker-plugin-lto` (W5 v) | stable |

`link.flags`: std builds `-lgcc_s -lutil -lrt -lpthread -lm -ldl`
(from `--print native-static-libs`); no_std builds `-lrt -lpthread`; hot-only
builds nothing.

Both variants (std and no_std) are the same source. The code uses only `core`,
`alloc` and the `libc` crate. The `std` feature only switches `#![no_std]`, the
allocator and the panic handler.

## Results (all under `flock -s`, functional only, no timing)

`harness/test.sh bin/rust-<p>` with `WORKERS="1 4 8"`, both drivers:

| profile | result |
|---|---|
| release | 72/72 |
| release-nostd | 72/72 |
| debug | 72/72 |
| tsan | 72/72, TSan clean (TMO=200) |
| ASan+UBSan harness over the release core (scratch build) | 72/72 |

- The 72 checks: layout, abi (12/12), deque (empty, lifo, stress 10x200000),
  W1/W2/W3 on epoll and uring at 1/4/8 workers, the I/O tests (t_timer, t_pipe,
  t_tcp, t_cancel, t_block stop, t_block kill) on both drivers at 1/4/8, the W4
  replay suite (w1, w3, t_cancel, t_timer, on both drivers, byte-identical output
  and journal) plus both negative tests, and fuzz_run --random 300.
- **xreplay**: rust-release → c-release and c-release → rust-release, 8/8 each
  way. rust → stub 8/8, and stub → rust (w1, w3 on epoll) 2/2.
- `--no-defer` io_uring: t_timer, t_pipe, t_tcp, t_cancel and w3 at 4 workers pass.
- **Replay at 4 and 8 workers** is refused at the first differing entry with
  "schedule divergence", as SPEC §D.1 says: arrival interleaving is not
  recorded. The one exception is t_timer x4 on epoll, which happened to replay.
  Byte-for-byte replay is promised, and passes, at 1 worker.
- **Layout probe** (`./build.sh layout-probe rust`): edits a, b and c all build
  and pass, so the change propagated through bindgen. This is the intended
  outcome for Rust. A deliberately broken binding fails the build, through
  build.rs's opaque-struct assertion and the `sig_check` fn-pointer
  unification.
- **libFuzzer**: the ASan+UBSan target linked with the Rust release core found
  one bug in my fuzz driver (bug 13 below). After the fix, 300k runs (seed 1)
  and 3M runs (seed 7) are clean.
- **Miri** (nightly, `./test.sh miri`): the deque tests (including a 3-thread
  test) and 6 op-table tests (basic, stale-after-reuse, retract, stop, full,
  and a 2-worker run with replies from a third thread) pass under Stacked
  Borrows, the data-race detector and leak checking. Miri warns about
  integer-to-pointer casts, because tasks travel as u64 in the deque and through
  `core[1]` (uintptr_t), which the C ABI dictates.
- **loom** (`./test.sh loom`): 3 models pass (take vs steal on the last item,
  steal during grow, two thieves). As a sanity check I weakened both SeqCst
  fences to AcqRel in scratch, which is what P1 does: loom failed `two_thieves`.
  The change was reverted at once. Plants are not in the tree.
- **W5**: `./build.sh w5 rust` builds iii-tcc, iii-clang and v-clang22-lto. In
  v-lto, objdump shows no call to ren_hot_* inside the loops. The three calls
  that remain are the final drops outside the timed loops. Not timed.

## unsafe (tools/count_unsafe.py, shipped code, tests excluded)

3031 code lines; **2025 inside unsafe (66.8%)**. 1997 are in unsafe fn bodies,
28 in unsafe blocks outside them, and 31 more are lines of `unsafe impl`
items. This is a first draft written "unsafe fn by default" around the raw
C ABI:
- every `extern "C"` export;
- every driver function that makes syscalls;
- every core function that dereferences frame pointers.

The deque is 7%: one unsafe deref per operation. I did not minimise it.
Narrowing to safe fns with small unsafe blocks would cut the count, but not the
amount of code that touches raw pointers. Record this as the honest draft
number.

## Bugs I hit while writing, and what caught each

| # | bug | caught by |
|---|---|---|
| 1 | bindgen 0.66.1 picks up libclang-22, which was installed for cross-language LTO. It then silently emits every struct declared through `typedef struct X X;` before its body (`ren_task`) as opaque `{ _address: u8 }`. libclang-18 is correct. Fixed by pinning `LIBCLANG_PATH=/usr/lib/llvm-18/lib` and asserting in build.rs that no slice.h struct came back opaque. (A toolchain trap, not my code.) | my inspection of the bindgen output, before writing code; now build.rs fails the build |
| 2 | `Backend::Epoll(ws) \| Backend::Uring(_)` or-pattern binding `ws` on one side only | rustc (E0408) |
| 3 | unused import | rustc warning |
| 4 | no_std staticlib: undefined reference to `rust_eh_personality` (stable's precompiled `alloc` is panic=unwind). Fixed with a never-called `#[no_mangle] rust_eh_personality`, since `#[lang = "eh_personality"]` is nightly-only. | the linker (ld) when linking the harness against release-nostd |
| 5 | `-Zsanitizer=thread` against an uninstrumented core/alloc: "mixing `-Zsanitizer` will cause an ABI mismatch". Fixed with `-Zbuild-std=core,alloc`. | rustc (nightly) |
| 6 | TSan reported every stolen task frame as a race at 4 workers. The deque publishes with `fence(Release)` + a relaxed store of bottom (the paper), and TSan does not model standalone fences. In the tsan profile only, feature `tsan` makes that store Release too; the fence stays. The C entry will meet the same thing. | TSan (W1, epoll and uring, x4 and x8) |
| 7 | optable test: the arrays sized 8, but 40 tasks | Rust bounds check (panic in cargo test) |
| 8 | test: `use ren_core::...` was ambiguous with bindgen's type `ren_core` (crate name = slice.h type name) | rustc (E0659) |
| 9 | test host: the journal callback appended to a `Vec` from two worker threads at once (the callback is any-thread) | Miri data-race detector |
| 10 | test: a raw pointer to the host and state was invalidated by a later `&`-reborrow in the test body | Miri (Stacked Borrows) |
| 11 | loom was a dev-dependency, but under `--cfg loom` the lib itself uses it | rustc (E0433) |
| 12 | `ren_stop` journaled a LATE CANCEL for every one of nw*S slots (SPEC §B.4 taken literally): a 151 KB journal for t_block where C writes 3.7 KB. It now skips FREE slots, as C and the stub do, and the core entries match C's. | comparing my journal with the C entry's (jdump) |
| 13 | fuzz driver: REPLY removed the call from `pending` before reading its last input bytes. Input ending mid-action lost a pulled call, which gave "no termination". | **libFuzzer** (5-byte input `21 03 ed 92 ed`); fuzz_run --random had not hit it |
| 14 | W5: link.flags for the hot-only profiles listed std's `-lgcc_s ...` though ren_hot is no_std | tcc ("library 'gcc_s' not found") |

No bug in the core or the drivers was caught by a test. abi_test (12/12), the
deque suite, the smoke and I/O suites and the replay suite all passed on the
first build that linked. The four found by tooling (9, 10, 13, and the TSan
issue in 6) were in test scaffolding, the fuzz driver and the tool
interaction.

## Places where SPEC needed a decision

- **§B.4 ren_run "debug: assert runs == 0 || drained"**: abi_test `budget` calls
  ren_run twice without polling in between, so this assertion would fail a
  normative test. It is not implemented. The thread-binding assertion is
  (debug builds).
- **§B.4 ren_stop**: skips FREE slots (bug 12 above).
- **§C.1 "records that in the J_DRV entry"**: J_DRV has three u32 fields. An
  io_uring fallback without SINGLE_ISSUER|DEFER_TASKRUN is recorded as
  `kind | REN_DRV_F_URING_NO_DEFER << 16`. Replay reads only `workers`.
- **§C.1 release()**: only ACCEPT (close the fd) and READ (poison the fd) act,
  as written. A released CONNECT's socket is not closed.
- **§D.4**: "a seed that comes from the first input byte" is not in the
  grammar, and w_fuzz.c's op order is fixed, so no byte is consumed for it. A
  cancel reply in RUN pushes its id to done_ids, like REPLY.
- **io_uring CONNECT and TIMEOUT cancels** go through `IORING_OP_ASYNC_CANCEL` by
  user_data. After a kill, every in-flight op gets its own ASYNC_CANCEL, not
  CANCEL_ANY, so that the armed eventfd read survives.
- **Driver J_REPLY order**: PIPE, LISTEN, MONO_NOW and CLOSE are answered inside
  the poll loop, so their J_REPLY lies between J_PULLs. The C entry batches
  and replies after J_DRAINED. Both replay, in either language, because replay
  follows file order.

## Not done (by instruction or out of time)

- No plants (P1-P5): the task says not yet. The plan: P1 is the two
  `fence(SeqCst)` in deque.rs; P2 is the `Idx`/`AIdx` aliases; P3 is the
  generation check in `Core::reply`; P4 is `on_cancel_done`; P5 is
  `stolen_from`.
- No timing runs: the task says not to.
- No ASan profile: the contract has none for Rust. An ASan+UBSan harness over
  the Rust core was run by hand (72/72) and through libFuzzer.
- unsafe was not minimised (see above).

No apt packages were installed for the Rust entry. loom 0.7 and its
dependencies came from crates.io, for tests only.

# Planted bugs P1-P5, C entry, machine "cloud"

Machine: **cloud** (experiments/MACHINE-cloud.md): 4 vCPU Xeon under KVM, Linux 6.18.
Tools: clang 18.1.3, gcc 13.3, valgrind 3.22, libFuzzer (clang 18), TSan, ASan, UBSan.
Runs took place 2026-10-30, 13:59 to 15:59 UTC. Everything ran under `flock -s /tmp/ren-bench/lock`.
No timed benchmarks were run.

Raw logs are in `results/cloud/bugs-c/<P>/`, and every stage is listed with its exit code and seconds in `bugs-c/summary.tsv`. P0 is the clean build, run through every tool as a false-positive baseline.

## How the plants are built

Each plant is a compile-time switch, `PLANT=Pn` → `-DREN_PLANT=n` (SPEC §0.4). With no plant the code is the correct version. After the plants went in, the clean `release` build re-passed 72/72 and `tcc` passed 54/54.

| # | lines changed (`#if REN_PLANT == n`) |
|---|---|
| P1 | `dq.c` `dq_take` and `dq_steal`: `FENCE(SC)` → `FENCE(AR)`. Checked with objdump: the `mfence` in each function is gone in `c-release-P1` (clean: 1 + 1, P1: 0 + 0). |
| P2 | `dq.h`: `typedef int64_t dq_i; typedef a64 adq_i;` → `uint64_t` / `au64`. This covers `top`, `bottom` and every local copy, because they are all `dq_i`. |
| P3 | `core.c` `ren_reply`: the line `if (wgen(wd) != g) ... return REN_RELEASE;` is removed. |
| P4 | `core.c` `deliver`: `if (o->had_cancel) { cancel_done++; free(o); }`. The common path then reads `o->slot` and `o->gen` and calls `free(o)` again. |
| P5 | `core.h`: `stolen_from` becomes a plain `uint64_t`. `sched.c` `steal_any`: `c->W[v].stolen_from += 1`. `ren_run`: a plain read. One extra line was forced by the type change: the `ST(&W->stolen_from, 0, RLX)` initialiser in `ren_start` became a plain `= 0`, which runs before any worker thread exists. |

Some plants failed or hung the normal builds, so the scripts got a few switches:
- `c/build.sh` accepts `REN_C_WERROR=0`, because P2 does not build under the normal `-Werror`.
- `c/bugs.sh` drives the stages.
- `c/bugs-vg.sh` runs valgrind. It runs every command to the end and keeps valgrind's exit 99 apart from the program's own exit code.
- `c/bugs-rate.sh` runs a detector N times and logs how many runs failed.

## Result table

"Tests" means the whole shared suite (`harness/test.sh`: layout, abi, deque, smoke W1-W3, io, W4 replay, fuzz). It ran at 1, 4 and 8 workers on epoll and on io_uring, in the release, debug, asan, ubsan-int and tsan profiles. The time to catch is wall time until the first failing command reports.

| bug | tool | caught | stage | time to catch | evidence |
|---|---|---|---|---|---|
| **P1** | clang/gcc `-Wall -Wextra -Wconversion` | no | never | – | `P1/warn-clang.log`: 0 warnings, the same as P0 |
| P1 | `deque_stress stress 10 200000` (owner + 3 thieves), not TSan | **yes**, intermittent | test | ~0.5 s per run. Runs that failed: release 23/30, debug 20/30, ubsan-int 16/30, asan 13/30 | `P1/rate-deque-*.log`: `duplicated=144138 lost=144138`. P0 failed 0/30 (`P0/rate-deque-release.log`). The single deque-stress run inside the full suite passed in 4 of 5 profiles |
| P1 | W1-W4 suites | no | never | – | 72/72 in release, debug and tsan, 73/73 in asan. W1 x8 with n=1M failed 0/20 runs (`P1/rate-w1x8-release.log`) |
| P1 | TSan | no | never | – | `P1/tests-tsan.log` 72/72; `rate-deque-tsan.log` 0/30 failed; `rate-w1x4-tsan` 0/20 failed. TSan does not model `atomic_thread_fence`, and the TSan build's deque push also uses a REL store for bottom (c/NOTES.md) |
| P1 | ASan / UBSan(int) | no (the fault is not theirs to detect) | test only | – | they fail only through the deque_stress oracle above |
| P1 | valgrind memcheck / helgrind / drd | no | never | – | `P1/valgrind.log`. helgrind and drd give about 50 reports on P0 as well, because they do not understand C11 atomics. The P1 report set looks the same as P0's |
| P1 | fuzz (fuzz_run 20k, libFuzzer 300 s) | no | never | – | The fuzz driver runs 2 workers from one thread, so no store-load reordering is possible (`P1/libfuzzer-asan.log`: clean, 300 s) |
| P1 | GenMC | could-not-run | – | – | See the GenMC section below |
| **P2** | clang `-Wall -Wextra` (the normal `-Werror` build) | **yes** | compile | 0.1 s | `P2/build-release.log`: `dq.c:47:13: error: comparison of integers of different signs: 'dq_i' (aka 'unsigned long') and 'int64_t' [-Werror,-Wsign-compare]`. This fires on `b - t > a->cap - 1` in **push**, because `cap` stayed `int64_t`. It does not fire on the `0 - 1` in take. If `cap` were unsigned too, no warning would fire |
| P2 | clang/gcc `-Wconversion` | yes, incidental | compile | 0.4 s | clang gives 6 warnings (`-Wsign-conversion` on `i & (cap - 1)`, 5 of them), gcc gives 10. All of them come from mixing with signed `cap` |
| P2 | UBSan `-fsanitize=integer` (unsigned-integer-overflow) | **yes** | sanitizer-run | 0.009 s (deque_stress empty) | `P2/direct-deque-empty.log`: `dq.c:58:32: runtime error: unsigned integer overflow: 0 - 1 cannot be represented in type 'uint64_t'`. The whole ubsan-int suite fails 65/72 in 1.6 s |
| P2 | `deque_stress empty` (and the W1-W4 suites), not UBSan | yes, as a **hang** | test | the timeout (5-10 s) | Release, debug, asan and tsan **hang** rather than fail. The first take on an empty deque leaves bottom = 2^64-1, so the next push's `grow` copies about 2^64 slots. 65 of 72 tests time out (`P2/tests-release.log`). The 7 that pass are layout, lifo, stress and the 4 replay-refusal tests. `deque_stress stress` **passes** |
| P2 | ASan / TSan | no (hang only) | test | timeout | `P2/tests-asan.log` and `P2/tests-tsan.log` show no sanitizer report, only timeouts. tsan-w1x4 timed out at 120 s |
| P2 | valgrind memcheck / helgrind / drd | no (hang only) | never | 30 s timeouts | `P2/valgrind.log`: every memcheck command hangs with 0 errors |
| P2 | fuzz (libFuzzer, asan) | yes, as a **timeout** | fuzz | 12 s (unit 1, the empty input; `-timeout=10`) | `P2/libfuzzer-asan.log`: `ERROR: libFuzzer: timeout after 11 seconds`. The first attempt used libFuzzer's default 1200 s unit timeout, never reached `-max_total_time`, and I stopped it by hand at 406 s (`libfuzzer-asan-no-unit-timeout.log`) |
| P2 | fuzz_run under ubsan-int | yes | fuzz / sanitizer-run | 0.0 s | `P2/fuzz-run-ubsan.log` exit 1 (UBSan). Under release, fuzz_run hung until the 600 s timeout |
| **P3** | clang/gcc warnings | no | never | – | 0 warnings |
| P3 | `abi_test stale` | **yes** | test | < 0.1 s | `FAIL tests/abi_test.c:218: reply(c, a, REN_DONE, 0x5A1E5A1E) == REN_RELEASE`, in all 5 profiles |
| P3 | W1-W4 (smoke, io, replay) | no | never | – | Every W1-W4 and io test passes. The only failures are abi_test and fuzz_run (70/72) |
| P3 | fuzz: fuzz_run (oracle) | **yes** | fuzz | 0.0 s (input offset 35 of the first inputs) | `P3/fuzz-run-release.log`: `fuzz oracle: a stale reply was ACCEPTED (id 0000000800000001, ...)` |
| P3 | fuzz: libFuzzer + ASan | **yes** (by the oracle's abort, not an ASan report) | fuzz | 0.5 s, 3,909 execs | `P3/libfuzzer-asan.log`: `deadly signal`, with the oracle line above it. The reproducer is in `build/bugs-c-fuzz/P3/` and `P3/test-sh-libfuzzer-crash-*.bin` |
| P3 | ASan | no | never | – | The stale reply lands on the slot's **live** new occupant, so no freed memory is touched. The only ASan output is a LeakSanitizer report after abi_test aborts mid-test |
| P3 | UBSan / TSan / valgrind | no | never | – | `P3/valgrind.log`: memcheck reports 0 errors; abi_test fails by its own assert |
| **P4** | clang/gcc `-Wall -Wextra -Wconversion` | no | never | – | 0 warnings |
| P4 | clang static analyzer (`clang --analyze`, extra) | **yes** | compile (analysis) | 13 s for all core files | `P4/clang-analyze.log`: `core.c:150:16: warning: Use of memory after it is freed [unix.Malloc]`. Note: **P0 already has 5 analyzer reports** (`P0/clang-analyze.log`: drv_epoll.c:378/392, drv_uring.c:233/348, drv_common.c:317). I did not triage them |
| P4 | tests (abi_test cancel_race / cancel_sent / retract / stop / determinism; t_cancel; t_block stop; W4 record t_cancel; fuzz_run) | **yes** | test | < 0.1 s | 56/72 pass in every profile. Release and debug crash with SIGSEGV (exit 139), because the read of `o->slot` after the free goes wrong before glibc's double-free check is reached (`P4/direct-abi.log`) |
| P4 | ASan | **yes** | sanitizer-run | < 0.1 s | `heap-use-after-free ... in deliver core.c:150:3`, freed at `core.c:146`. ASan reports the UAF that comes before the second `free` |
| P4 | TSan | yes (incidental) | sanitizer-run | < 0.1 s | `P4/tests-tsan.log`: `SUMMARY: ThreadSanitizer: heap-use-after-free core.c:150:3 in deliver` |
| P4 | UBSan | yes (SEGV handler only, no UB check) | sanitizer-run | < 0.1 s | `UndefinedBehaviorSanitizer: SEGV on unknown address` |
| P4 | valgrind memcheck | **yes** | sanitizer-run | 0.6 s | `P4/valgrind.log`: `Invalid read of size 4` plus `Invalid free()` on abi_test, t_cancel x1 / x4 and fuzz_run. W1, W2 and W3 do not cancel, so they are clean |
| P4 | fuzz (libFuzzer + ASan; fuzz_run) | **yes** | fuzz | 0.1 s, 201 execs | `P4/libfuzzer-asan.log`: `heap-use-after-free core.c:150:3 in deliver`. fuzz_run under release exits with SIGSEGV at once |
| **P5** | clang/gcc `-Wall -Wextra -Wconversion` | no | never | – | 0 warnings |
| P5 | TSan, W1 at 4 workers | **yes** | sanitizer-run | 0.3-0.6 s, first run; **20/20** on epoll, **20/20** on uring | `P5/tsan-w1x4.log`: `data race ... Read of size 8 by thread T3: ren_run sched.c:191` / `Previous write ... steal_any sched.c:165`. In the full suite, 25/72 fail (every multi-worker W1/W2/W3/io test). P0 under TSan: 0/10 |
| P5 | tests (W1-W4) without TSan / ASan / UBSan | no | never | – | 72/72 and 73/73. The counter is never checked, so lost increments cannot be seen |
| P5 | valgrind helgrind / drd | yes, but **buried** | sanitizer-run | 1 s | `P5/valgrind-stolen_from.log`: helgrind names sched.c:165/191 in 4+2 of about 50 reports, 3/3 runs; drd 2+1 of about 56. P0 gives about 50 reports too, and none of them is on stolen_from. Seeing it needs a diff against a clean baseline |
| P5 | valgrind memcheck | no | never | – | 0 errors |
| P5 | fuzz | no | never | – | The fuzz driver runs both workers on one thread, so it has no concurrency |
| any | GenMC | could-not-run | – | – | see below |

### Summary per bug

- **P1, missing SC fence.** The only C tool that caught it is the deque_stress oracle. It is intermittent: 43-77% of runs fail outside TSan. A single run in the suite caught it in only 1 of 5 profiles. TSan, valgrind, the fuzzers and every W1-W4 workload miss it. GenMC is the tool meant for this, and it could not be run.
- **P2, unsigned indices.**
  - Compile: the `-Werror` build rejects it, but only because `cap` stayed signed (`-Wsign-compare` in push).
  - Sanitizers: UBSan's unsigned-integer-overflow check names the exact `0 - 1` at once.
  - Everything else: the bug shows up as a **hang**, not a failure. Tests, ASan, TSan, valgrind and fuzzers all see only timeouts.
- **P3, missing generation check.** abi_test stale and both fuzzers' oracles catch it at once. No memory tool sees it, because the stale reply corrupts a *live* op.
- **P4, double free.** Every memory tool catches it: ASan, valgrind and the clang analyzer, plus a crash in release. It appears as a use-after-free on the line after the extra `free`, not as a double free.
- **P5, plain counter.** TSan catches it 100% of the time at W1 x4. helgrind and drd see it inside their false-positive noise. Nothing else catches it.

## P5 in Rust (asked specifically)

Logs, sources and diffs are in `results/cloud/bugs-c/rust-p5/`. The slice variants were built in a scratch copy of `rust/`, which itself was not modified. The checks used rustc 1.97 stable, plus nightly Miri for one check.

| variant | compiles? | what rejects it |
|---|---|---|
| Standalone, `Arc<Vec<Worker{stolen_from: u64}>>`, thief `w[0].stolen_from += 1` | **no** | `E0596: cannot borrow data in an Arc as mutable` (aliasing/borrowck, not Send/Sync) |
| Standalone, `Cell<u64>` in the Arc | **no** | **`E0277: Cell<u64> cannot be shared between threads safely`**, the Sync check |
| Standalone, `static mut [u64; 4]` | no in safe code | `E0133: use of mutable static is unsafe` (editions 2021 and 2024) |
| Standalone, `UnsafeCell<u64>` + `unsafe impl Sync for Worker` + `unsafe { *get() += 1 }` | yes | It needs two `unsafe` tokens. Miri then reports `Data race detected between non-atomic write ... and non-atomic read` (`miri-d.log`) |
| **Slice**, `stolen_from: u64`, `self.worker(v).stolen_from += 1` | **no** | `E0594: cannot assign to data in a & reference`, even though `steal_any` is an `unsafe fn` |
| **Slice**, `stolen_from: Cell<u64>`, `c.set(c.get() + 1)` | **YES: compiles in safe code, with no `unsafe` at the use site** | Nothing rejects it. `Core` already has `unsafe impl Sync for Core {}` (sched.rs:190), written for its owner-only `UnsafeCell` fields. That one manual impl hides `Cell`'s `!Sync` for every field added later |
| **Slice**, `stolen_from: UnsafeCell<u64>`, `*...get() += 1` | yes | It compiles inside the existing `unsafe fn steal_any` with no new `unsafe` block and no warning (edition 2021) |
| Slice, `*(&x as *const u64 as *mut u64) += 1` | no | the deny-by-default lint `invalid_reference_casting` ("assigning to `&T` is undefined behavior"). An `#[allow]` would let it through |

**Answer.** In safe code built from std types, the compiler rejects P5.
- A plain field is stopped by the borrow checker (E0594/E0596).
- `Cell` is stopped by the Sync check (E0277).

In the real slice, once a struct carries a hand-written `unsafe impl Sync`, P5 needs no `unsafe` at all: `Cell<u64>` compiles. So the Send/Sync guarantee is only as good as the audit of the one existing `unsafe impl`. Writing it as `UnsafeCell` costs nothing extra inside an `unsafe fn` under edition 2021. I did not run the Rust TSan or Miri builds of the slice variants here; that is the Rust agent's job.

## GenMC: could-not-run

1. I installed the prerequisites (below) and cloned GenMC at commit 9f6c4c0 (2026-09-24).
2. CMake configured it against LLVM 22.1.8, using `/usr/lib/llvm-22` with g++-14 (`genmc/cmake-configure.log`). GenMC supports LLVM 19-22 and needs C++20 (g++ ≥ 14).
3. The build step (`cmake --build`) was **denied by this session's permission classifier** ("Code from External"), and I did not try to get around that.
4. So GenMC was not built and no GenMC check of P1 (or of the others) was run.

To enable it, a user has to allow building GenMC from source. A client test would then be needed: the SB-shaped take/steal race over `dq.c`, compiled with `genmc --rc11`.

## Things found on the way (for the C agent and the harness)

- **valgrind and io_uring.** Under valgrind 3.22, `harness w1 --driver uring --workers 4` hangs at 0% CPU even on the **clean** build. It sat for more than 9 minutes before I killed it (`P0/vg-memcheck-uring-hang.log`). Valgrind runs here are epoll-only.
- **helgrind and drd** give about 50 reports on the clean core, because they do not model C11 atomics. Neither is usable as a pass/fail gate.
- **clang static analyzer, clean build.** It gives 5 reports on the clean build (4 "use of memory after it is freed" in the epoll and uring drivers, and 1 garbage value at drv_common.c:317). I have not triaged them; they may be false positives on paths the analyzer cannot rule out.
- **The SPEC's P2 exposure.** SPEC names `deque_stress --empty` as the test for P2. With these indices it *hangs* rather than fails, so the test needs a timeout to report it. `deque_stress stress` passes under P2.
- **The SPEC's P3 exposure.** SPEC says "ASan when the stale reply touches a freed frame". In this core it never did: the stale reply's target is the slot's live new occupant.
- **test.sh small bugs.**
  - `replay_one` prints `record (exit 0)` for failed recordings, because `$?` is read after `!`.
  - The libFuzzer suite writes crash files into the current directory: two landed in `experiments/native-lang/`, and I moved them into `bugs-c/P3/` and `bugs-c/P4/`.
  - The libFuzzer runs in test.sh and bugs.sh had no `-timeout`. bugs.sh now passes `-timeout=10`; test.sh is unchanged.

## Process notes

- **apt installs**, all under the shared lock: llvm-18-dev, libclang-18-dev, llvm-18-tools, libclang-rt-18-dev, libedit-dev, libhwloc-dev (with libhwloc15, libhwloc-plugins, libnuma-dev, libltdl-dev, libxnvctrl0), libbsd-dev, libmd-dev, and g++-14 / gcc-14 with their dependencies. cmake, autoconf, automake and libffi-dev were already there. All of these were for GenMC, which in the end was not built.
- **Lock hold times.** The first runs of P1, P3, P4 and P5 each held the shared lock for one plant's whole run, about 4-7 minutes. P2's first run would have held it for more than an hour because of hangs, so I stopped it. `c/bugs.sh` now takes the lock separately for each stage command. The longest single hold after that was a P2 test.sh profile, about 5.7 minutes.
- **Interrupted runs.**
  - P2's first attempts (TMO=60, then TMO=8) were stopped. Their partial log is `P2/tests-release-partial-TMO8.log`.
  - One P2 asan suite finished, but its shell was killed before it recorded the time, so I re-ran it.
  - The P0 valgrind run hung on uring, as described above.

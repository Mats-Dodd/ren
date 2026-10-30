# Planted bugs P1-P5, Zig entry, machine "cloud"

Machine: **cloud** (experiments/MACHINE-cloud.md): 4 vCPU Xeon under KVM, Linux 6.18.
Tools: Zig 0.17.0 (`/usr/local/bin/zig`), clang 18.1.3 for the harness, the libFuzzer target and the extra ASan harness, gdb.
Runs took place 2026-10-30, 16:02 to 17:05 UTC. Every build, test, sanitizer and fuzz command ran under `flock -s /tmp/ren-bench/lock`, taken per stage command. No timed benchmarks were run. Nothing was installed with apt.

Raw logs are in `results/cloud/bugs-zig/<P>/`. Every stage is listed with its exit code and seconds in `bugs-zig/summary.tsv`. The two P1 `rate-tsan-w1x4` rows appear twice because I reran that stage while adding the debug rate. P0 is the clean build, run through every tool as the false-positive baseline. It is clean everywhere:
- tests: 72/72 in release-fast, debug and tsan, and 73/73 in release-safe (that profile's bin also has the hand-linked libFuzzer target);
- deque_stress: 0/20 failures on release-fast, release-safe, debug and tsan;
- TSan W1 x4: 0/20;
- fuzz_run: clean; libFuzzer: 4.6M runs in 120 s, clean;
- the ASan harness: clean.

## How the plants are built

Each plant is a comptime switch, `PLANT=Pn`. zig/build.sh writes it into the generated `opts` module as `plant = n`, because `zig build-lib` has no `-D` (zig/NOTES.md). Each `opts.plant == n` test is comptime-known, so the code that is not selected is never compiled, and with no plant the code is the correct version. The clean `release-fast` build re-passed after the edits, and so did the full P0 run above.

| # | lines changed |
|---|---|
| P1 | `dq.zig` `take`: `st(bottom, b, .seq_cst)` → `.release` and `ld(top, .seq_cst)` → `.acquire`. `steal`: both `.seq_cst` loads → `.acquire`. This weakens the SC substitution of SPEC §A.3 as §F says. Checked with objdump: `ren_dq_take` in `zig-release-fast` has `xchg %rsi,0x80(%rdi)` (the SC store), and in `-P1` it is gone. Neither build has an `mfence` in take or steal. |
| P2 | `dq.zig`: `Idx` (the type of `top`, `bottom` and every local `b`/`t`) becomes `u64`. `Ring.cap` stays `i64`. I split it into a `Cap` type that is `i64` in every build except P2u. |
| P2u | (Zig-only, extra) P2 plus `Cap = u64`, i.e. the paper's `size_t` everywhere. Spec-exact P2 does not compile in Zig (below), so this variant exists to see what the runtime tools do with the bug. Selected with `PLANT=P2u`. |
| P3 | `core.zig` `reply`: the generation test `if (wd>>32 != g) RELEASE` becomes `if (opts.plant != 3 and ...)`, so it is deleted at comptime. The CAS already installs REPLIED on the generation as loaded. |
| P4 | `core.zig` `deliver`: `if (op.had_cancel) { cancel_done += 1; A.destroy(op); }`. The common path then reads `op.slot` and `op.gen` and calls `A.destroy(op)` again. |
| P5 | `core.zig`: `stealAny` does `victim.stolen_from += 1` (plain) instead of `@atomicRmw(.Add, .monotonic)`. `run` does a plain read instead of `@atomicLoad(.monotonic)`. Zig has no atomic types, so the field declaration is unchanged; only the two accesses change. |

Scripts: `zig/bugs.sh <P0|P1..P5|P2u> [build tests direct rate fuzz asan]` runs the stages. `zig/build.sh` accepts the extra `PLANT=P2u`.

Profiles (zig/NOTES.md):
- `release-fast`: c_allocator, no safety.
- `release-safe`: safety checks on, `std.heap.SafeAllocator` (Zig 0.17's GeneralPurposeAllocator/DebugAllocator), root panic handler.
- `debug`: the self-hosted backend, SafeAllocator, extra checks.
- `tsan`: ReleaseSafe with `-fsanitize-thread` and c_allocator, because TSan intercepts malloc. Safety checks stay on.

Extra tools, beyond the four profiles:
- **ASan harness ("asanh").** clang ASan+UBSan harness binaries linked against the *uninstrumented* release-fast Zig core. That core frees through libc, which ASan intercepts, so ASan sees double and invalid frees but not wild reads inside the core.
- **libFuzzer target.** Linked by hand, as the Zig entry did: clang `-fsanitize=fuzzer,address,undefined` harness with the release-safe Zig core. Run for 120 s with `-timeout=10`.

**Tests** means the whole shared suite, `harness/test.sh`: layout, abi, deque, smoke W1-W3, io, W4 replay and fuzz_run. It ran at 1, 4 and 8 workers on epoll and on io_uring, in the 4 profiles, with TMO=30 s (10 s for P2u). The time to catch is wall time until the first failing command reports.

## Result table

| bug | tool | caught | stage | time to catch | evidence |
|---|---|---|---|---|---|
| **P1** | zig compiler (no warnings exist in Zig) | no | never | – | `P1/build-*.log`: all 4 profiles build with no diagnostics |
| P1 | `deque_stress stress 10 200000` (the suite's oracle), not TSan | **yes**, intermittent | test | 0.4-0.8 s per run. Failed: **debug 20/20**, release-fast 7/20, release-safe 7/20, tsan 0/20 | `P1/rate-deque-*.log`: `FAIL tests/deque_stress.c:85: dup == 0 && lost == 0 ... duplicated=99889 lost=99889`. The single deque-stress run in the suite failed in release-fast, release-safe and debug (71/72) and passed in tsan (72/72). P0 failed 0/20 in every profile |
| P1 | Debug / ReleaseSafe safety traps | no | never | – | No panic in any P1 log. Duplicated tasks were not run concurrently long enough to hit the debug "task run twice" check, or they were not tasks at all (the deque test ABI holds u64s) |
| P1 | W1-W4 suites | no | never | – | Every smoke, io and replay test passed in all 4 profiles. W1 x4 took 2.4-2.7 s against 0.3-0.5 s on P0 (`P1/w1x4-*.log`), but its output was correct |
| P1 | TSan | **no** | never | – | `P1/tests-tsan.log` 72/72 with 0 reports. `rate-deque-tsan` failed 0/20 and `rate-tsan-w1x4` 0/20. The accesses are all atomics, so there is no data race to report, and TSan's scheduling hides the store-load reordering |
| P1 | SafeAllocator, ASan harness | no | never | – | the bug is not a memory error |
| P1 | fuzz (fuzz_run 20k/20k/5k; libFuzzer 120 s) | no | never | – | `P1/fuzz-run-*.log` and `P1/libfuzzer-release-safe.log` are clean. The fuzz driver runs both workers on one thread, so no reordering can happen |
| **P2** (spec-exact: top/bottom/b/t `u64`, cap `i64`) | **zig compiler** | **yes** | **compile** | 0.4-1.2 s (the whole build) | `P2/build-debug.log`: `src/dq.zig:66:39: error: incompatible types: 'u64' and 'i64'` on `i & (a.cap - 1)` in `at()`, reached from push, grow, take and steal. All 4 profiles fail. Zig has no implicit signed/unsigned mixing, so this is a hard error, not a warning that a flag could turn off. It fires because `cap` stayed signed, the same as C's `-Wsign-compare`. If `cap` is unsigned too (P2u), it compiles |
| P2u | zig compiler | no | never | – | `P2u/build-*.log`: all 4 build cleanly |
| P2u | **ReleaseSafe / Debug safety trap** (integer overflow) | **yes** | test (the trap fires at runtime) | **0.0 s**, on the first take on an empty deque | `P2u/tests-release-safe.log`: `ren zig panic: integer overflow`. gdb on debug (`P2u/gdb-deque-empty-debug.log`): `#7 dq.Deque(u64).take` ← `ren_dq_take` ← `t_empty` (deque_stress.c:18). This is the `0 - 1` in take. The suite fails 65/72 in 1.7 s (release-safe) and 2.0 s (debug), all on the trap |
| P2u | TSan profile (ReleaseSafe + TSan) | yes, by the **safety trap** only | test | 0.0 s | `P2u/tests-tsan.log` 7/72 pass, `integer overflow` panics. No TSan report |
| P2u | tests in release-fast (no safety) | yes, as a **hang** | test | the timeout (10 s per command; abi_test 60 s, W1 120 s in the direct runs) | `P2u/tests-release-fast.log` 13 passed, 59 failed, all exit 124 (timeout). The suite took 612 s. Passed: layout, deque lifo, **deque stress** (20/20 clean in `rate-deque-*`), t_block kill x6 and the 4 replay-refusal tests. This matches the C entry's P2 (a hang, from the next push's grow copying about 2^64 slots) |
| P2u | ASan harness (release-fast core) | yes, but only as a **SEGV** | sanitizer-run | 0.1 s | `P2u/asanh-abi.log`: `AddressSanitizer: SEGV on unknown address ... core.runTask core.zig:365:41`. With b = 2^64-1, `t <= b` holds, so take hands back a garbage slot as a task. This is not an ASan diagnosis, because the core is not instrumented |
| P2u | fuzz | yes | fuzz | 0.0 s on release-safe/debug fuzz_run (trap); 0.1 s libFuzzer (trap, `deadly signal`); release-fast fuzz_run **hung** until the 300 s timeout | `P2u/fuzz-run-*.log`, `P2u/libfuzzer-release-safe.log` |
| **P3** | zig compiler | no | never | – | clean build |
| P3 | `abi_test stale` | **yes** | test | < 0.1 s | `FAIL tests/abi_test.c:218: reply(c, a, REN_DONE, 0x5A1E5A1E) == REN_RELEASE`, in all 4 profiles and in the ASan harness |
| P3 | W1-W4 (smoke, io, replay) | no | never | – | the suite is 70/72 in every profile. The only failures are abi_test and fuzz_run |
| P3 | fuzz_run (the oracle) | **yes** | fuzz | 0.01-0.02 s (input offset 35) | `P3/fuzz-run-release-fast.log`: `fuzz oracle: a stale reply was ACCEPTED (id 0000000800000001, ren_reply = 0, input offset 35)`, exit 134, in all 3 profiles |
| P3 | libFuzzer (release-safe core) | **yes**, by the oracle | fuzz | 0.3 s, about 3,770 execs | `P3/libfuzzer-release-safe.log`: oracle line, then `ERROR: libFuzzer: deadly signal` |
| P3 | Debug / ReleaseSafe safety, SafeAllocator, TSan, ASan harness | no | never | – | The stale reply lands on the slot's **live** new occupant, so no freed memory, bound or race is involved. The only ASan-harness output is a LeakSanitizer report after abi_test aborts mid-test (`P3/asanh-abi.log`) |
| **P4** | zig compiler | no | never | – | clean build. Zig has no lifetime checking |
| P4 | tests (abi cancel_race/…, t_cancel, t_block stop, W4 record t_cancel, fuzz_run) | **yes** | test | < 0.1 s | 56/72 in every profile (`P4/tests-*.log`), the same count as the C entry |
| P4 | **SafeAllocator double-free detection** (release-safe) | **yes** | test (runtime) | 0.009 s | `P4/abi-release-safe.log`: `ren zig panic: double free of [addr: 56518caecbd0, len: 136 (0x88) align: 8]`. The "alloc / first free / second free" stack traces are **empty** in ReleaseSafe, so the report does not say where. In the libFuzzer run it fired on the first input |
| P4 | **Debug safety trap** (bounds check) | **yes**, before the allocator | test (runtime) | 0.019 s | `P4/abi-debug.log`: `ren zig panic: index out of bounds: index 1431655765, len 4096`. gdb (`P4/gdb-abi-debug.log`): `#8 core.deliver`, after the first free; the index is garbage read from the freed op record. The use after free is caught as a bad index, not as a use after free, and the SafeAllocator never gets to see the second free |
| P4 | release-fast (c_allocator = glibc) | yes, by **glibc** | test | 0.008 s | `P4/abi-release-fast.log`: `free(): double free detected in tcache 2`, exit 134 |
| P4 | TSan | **yes** | sanitizer-run | < 0.1 s | `P4/abi-tsan.log` and `P4/t_cancel-x4-tsan.log`: `WARNING: ThreadSanitizer: heap-use-after-free ... Read of size 4 ... core.deliver core.zig:452:34` / `Previous write ... free ... core.deliver core.zig:450:39`. It names both lines exactly |
| P4 | ASan harness (uninstrumented core) | **yes** (double free only) | sanitizer-run | 0.1 s | `P4/asanh-abi.log`: `AddressSanitizer: attempting double-free ... core.deliver core.zig:455:14`, `freed by ... alloc.zig:29`. It cannot see the read at :452, because the core is not instrumented |
| P4 | fuzz (fuzz_run, libFuzzer) | **yes** | fuzz | 0.0 s fuzz_run (all 3 profiles); 0.1 s libFuzzer (first input) | `P4/libfuzzer-release-safe.log`: SafeAllocator `double free` panic → `deadly signal` |
| P4 | SafeAllocator leak detection | n/a | – | – | P4 does not leak. Note: the slice never calls `safe_state.deinit()`, so leak reporting is not wired at all |
| **P5** | zig compiler | **no** | never | – | `victim.stolen_from += 1` on a field shared across threads compiles with no diagnostic. Zig has no Send/Sync and no atomic types; atomicity is per access (`@atomicRmw`), so the type system cannot tell the plain access apart |
| P5 | Debug / ReleaseSafe safety, SafeAllocator | no | never | – | 72/72 in debug, release-fast and release-safe |
| P5 | tests (W1-W4) without TSan | no | never | – | the counter is never checked, so lost increments cannot be seen |
| P5 | **TSan, W1 at 4 workers** | **yes** | sanitizer-run | 0.4 s, first run; **20/20** (epoll 10/10, uring 10/10) | `P5/w1x4-tsan.log`: `WARNING: ThreadSanitizer: data race ... Read of size 8 ... core.run core.zig:562:45` / `Previous write of size 8 by thread T4: core.stealAny core.zig:419:40`. The full tsan suite fails 22/72 (`P5/tests-tsan.log`). P0 under TSan: 0/20 |
| P5 | fuzz / ASan harness | no | never | – | the fuzz driver has no concurrency, and the race is not a memory error |
| any | GenMC / a model checker | not run | – | – | Zig has no GenMC or loom equivalent (GenMC takes C/C++ LLVM IR from clang only). The C entry could not run GenMC either |

### Summary per bug

- **P1, weakened SC accesses.** Only the deque_stress oracle catches it.
  - Rates: 100% on Debug, 35% on ReleaseFast and ReleaseSafe, 0% under TSan.
  - No Zig safety mechanism, sanitizer, fuzzer or workload test notices it.
  - Same picture as C: TSan misses it there too.
- **P2, unsigned indices.**
  - Spec-exact P2: **the Zig compiler rejects it.** The u64/i64 mix in `i & (cap - 1)` is a hard `incompatible types` error in every profile. C only catches this with `-Werror -Wsign-compare`.
  - P2u (everything unsigned): ReleaseSafe and Debug trap at once on the `0 - 1` in take (`integer overflow`, with gdb pointing at `Deque(u64).take`). This is the equivalent of C's UBSan `-fsanitize=unsigned-integer-overflow`, except Zig has it on by default in safe builds.
  - ReleaseFast hangs like C's release build.
- **P3, missing generation check.** `abi_test stale` and both fuzzers' oracles catch it at once. No Zig safety check, allocator or sanitizer sees it, because the stale reply corrupts a live op. Same as C.
- **P4, double free.** Every runtime configuration catches it within 0.1 s, but each reports it differently:
  - SafeAllocator (ReleaseSafe): `double free`, with empty stack traces.
  - Debug: a bounds trap on a garbage index read from the freed record.
  - glibc (ReleaseFast): `double free detected in tcache 2`.
  - TSan: `heap-use-after-free`, with both lines named.
  - ASan harness: double free only.

  The compiler does not catch it.
- **P5, plain counter.** Only TSan catches it, 20/20 at W1 x4. The Zig compiler accepts it silently, because Zig has no Send/Sync and atomicity is a property of each access, not of the type.

## P5 in Rust (asked specifically)

I did not re-run this; it was already measured on cloud by the C agent and the Rust agent. Sources, diffs and logs are in `results/cloud/bugs-c/rust-p5/` and `results/cloud/bugs-rust/P5-compile/`. rustc 1.97 stable, with nightly Miri for the Miri runs.

- **The compiler rejects P5 in safe code.**
  - A plain `stolen_from: u64` with `self.worker(v).stolen_from += 1` fails with `error[E0594]: cannot assign to data in a & reference` (`bugs-rust/P5-compile/variant-a.log`). That is borrowck rather than Send/Sync.
  - A standalone `Arc<Vec<Worker>>` with `Cell<u64>` fails with `E0277: Cell<u64> cannot be shared between threads safely`, which is the Sync check (`bugs-c.md`, P5 in Rust).
- **What it takes to make it compile.**
  - In the real slice, `Core` already carries a hand-written `unsafe impl Sync for Core {}`. Because of it, `stolen_from: Cell<u64>` with `c.set(c.get() + 1)` **compiles in safe code with no new `unsafe`** (`variant-b.log`: `Finished`).
  - `UnsafeCell<u64>` compiles inside the existing `unsafe fn steal_any` with no new `unsafe` block (`variant-c`/`variant-d`).
  - Miri then reports `Undefined Behavior: Data race detected between (1) non-atomic write ... and (2) non-atomic read` (`variant-b-miri-many-seeds.log`).

  The Rust guarantee therefore depends on auditing the single existing `unsafe impl Sync`.
- **Compared with Zig.** The Zig compiler accepts P5 silently, with no `unsafe` equivalent needed.

## Notes and honesty

- **SafeAllocator in ReleaseSafe.** Its reports have no stack traces ("(empty stack trace)"), so the double free names an address and size but no source line. The location came from TSan, the ASan harness or gdb.
- **Debug P4.** The trap is a bounds check on a value read from freed memory, not an allocator report. Which check fires first depends on the read order after the first free.
- **Coverage gaps.**
  - libFuzzer coverage only measures the instrumented C harness, not the Zig core, which is not built with sanitizer coverage.
  - The ASan harness only checks malloc/free calls at the boundary.
- **The open W2 x4 hang.** Bug 9 in zig-log.md did not reproduce here. There were 20 suite runs that could have shown it (P0, P1, P3, P4 and P5 x 4 profiles), each running W2 at 4 and 8 workers on both drivers, and none hung. The only W2 failures are P5's TSan reports, which exit with 66.
- **Files changed for this task.**
  - `zig/src/dq.zig`: the P1 orderings, the P2 `Idx`, and the new `Cap` type, which is `i64` exactly as before in every non-P2u build.
  - `zig/src/core.zig`: P3, P4 and P5.
  - `zig/build.sh`: the `P2u` plant and the `p2u` option in `opts`.
  - `zig/bugs.sh`: new.

  No harness or design files were changed.
- **Wall time.** About 1.05 h, 16:02 to 17:05 UTC. The P2u release-fast hangs alone took about 20 min.

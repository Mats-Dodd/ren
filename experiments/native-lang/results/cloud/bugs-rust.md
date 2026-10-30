# Planted bugs P1-P5: the Rust entry

Machine: **cloud** (4 vCPU Xeon under KVM, Linux 6.18). Run 2026-10-30 14:23 to 16:17 UTC.
Toolchains: rustc/cargo/clippy 1.97 stable; nightly 1.101 for Miri and for the `tsan` profile only;
loom 0.7.2; clang 18 for ASan, UBSan and libFuzzer. No apt packages were installed.
Every step ran under `flock -s /tmp/ren-bench/lock`, one lock per step. No step was timed under the exclusive lock.

- Driver script: `rust/tools/bugs.sh <P0|P1..P5> [step...]`.
- Logs: `results/cloud/bugs-rust/<Pn>/<step>.log`.
- One row per step: `results/cloud/bugs-rust/summary.tsv`, with columns plant, step, exit code, seconds.
- P0 is the control: the same matrix with no plant.

## How the plants are switched

Each plant is a cargo feature, `plant1` to `plant5`. `PLANT=Pn ./build.sh rust <profile> Pn` passes `--features plantN`, and each tag gets its own target directory. With no feature, the source is the correct version. Each plant changes only the lines SPEC §F names:

| plant | edit (`#[cfg(feature = "plantN")]`) |
|---|---|
| P1 | `deque.rs`: `const BT_FENCE = if plant1 { AcqRel } else { SeqCst }`, used by the one fence in `take` and the one in `steal` |
| P2 | `deque.rs`: `type Idx = u64; type AIdx = AtomicU64;` in place of `i64`/`AtomicI64`. Every `b`, `t`, `top` and `bottom` uses these aliases |
| P3 | `sched.rs` `reply`: the `if (wd >> 32) as u32 != g { RELEASE }` test is cfg'd out |
| P4 | `sched.rs` `on_cancel_done`: adds `drop(Box::from_raw(_op))`. `deliver` then reads `o.slot` and frees `op` again |
| P5 | `sched.rs`: `Worker.stolen_from: UnsafeCell<u64>`. The thief does `*stolen_from.get() += 1` and the owner does a plain read at `ren_run` entry |

## Tools run per plant

| tool | what it is |
|---|---|
| rustc | `build.sh rust` for `release`, `debug`, `release-nostd` and `tsan`; the warnings are counted |
| clippy | `cargo clippy -p ren_core --features plantN -- -W clippy::all`, compared with P0's warnings |
| cargo test | the stable dev profile with overflow checks: deque unit tests plus `tests/optable.rs` |
| W1-W4 tests | `harness/test.sh` on `rust-{release,debug,release-nostd,tsan,asanh}-Pn` with `WORKERS="1 4 8"` and `DRIVERS="epoll uring"`. That is 72 checks: layout, abi_test, deque, W1-W3, the I/O tests, W4 replay and fuzz_run 300. asanh adds a 20k-run libFuzzer check for 73 |
| asanh | the harness C built with clang `-fsanitize=address,undefined` and linked over the Rust **release** core. The Rust code is not instrumented, but ASan intercepts its malloc and free. Rust has no ASan profile in the contract |
| TSan | the `tsan` profile: nightly `-Zsanitizer=thread -Zbuild-std=core,alloc`, no_std. It runs the full suite, then W1 at 4 workers on epoll, then `deque_stress` |
| deque_stress | `stress 10 200000`, 50 times on release and 20 times on debug |
| loom | `tests/loom_deque.rs` (take_vs_steal_last, steal_during_grow, two_thieves) under `--cfg loom --release` |
| Miri | `cargo +nightly miri test -p ren_core`, which covers the deque unit tests and optable. The optable suite includes a 2-worker, 3-thread test |
| fuzz | `fuzz_run --random 3000` on release and on debug, the fuzz regression input, and libFuzzer on asanh, time-boxed to 120 s with `-seed=1` |

Timeouts per harness check: P0 used 60 s, and 200 s for TSan. P1 and P3-P5 used 20 s, and 60 s for TSan. P2 used 20 s on release and 5 s on the other profiles, 10 s for TSan, because every hanging check otherwise costs the full timeout. The P2 release run at 20 s took 1221 s.

## Results

Each cell gives the result, the stage, and the wall time of the step. The time includes the incremental build for cargo-based tools. "caught" means the step failed because of the plant. The first failing check is named.

| tool | P1 fence SC→AR | P2 u64 indices | P3 no gen test | P4 double free | P5 plain stolen_from |
|---|---|---|---|---|---|
| **rustc** (compile) | compiles, 0 warnings: **no** | compiles. The only warning is the unused import `AtomicI64`, a side effect of the alias switch: **no** | compiles, 0 warnings: **no** | compiles, 0 warnings, already inside an `unsafe fn`: **no** | a plain `u64` is **rejected** (E0594). The `UnsafeCell<u64>` form compiles, 0 warnings. See below |
| **clippy** | same 3 warnings as P0: no | +1, the unused import only: no | no | no | no |
| **debug-build panic** (cargo test, debug harness) | no panic; the debug harness fails `deque stress` (dup/lost) | **yes, panic**: "attempt to subtract with overflow" at `deque.rs:109` in `take` on a fresh deque. cargo test 0.2 s; debug suite 7.3 s with 65/72 failing | n/a, no panic. The optable `stale_after_reuse` assertion fails in cargo test (3.6 s) | n/a. cargo test dies with glibc "free(): double free detected in tcache 2", SIGABRT (3.6 s) | no |
| **W1-W4 tests**, release | **yes**: `deque stress` (dup == 0 && lost == 0), 3.2 s. W1-W3 and all I/O tests pass | **yes, as hangs**: abi_test, `deque empty` and everything that takes from a fresh deque spin. 59/72 fail; the first (abi_test) at the 20 s timeout | **yes**: `abi_test stale` (tests/abi_test.c:218) and `fuzz_run random 300` ("a stale reply was not RELEASEd"), 18.6 s. W1-W3 and t_cancel pass | **yes**: abi_test (`cancel_race`), t_cancel and t_block stop at every worker count, W4 t_cancel record, fuzz_run. 16/72 fail, glibc abort, 9.3 s | **no**: 72/72 pass on release, debug, nostd and asanh |
| **ASan+UBSan harness** (asanh) | 73/73 on one suite run; `deque_stress` x20 fails on run 2. Caught by the stress test, not by ASan | hangs (60/73) | abi_test and fuzz fail through the oracle. **No ASan report**: the stale reply writes a live op record | **yes, ASan**: "attempting double-free" in abi_test, harness and libFuzzer, 16.3 s | no |
| **TSan** (nightly) | **no**: 72/72, no report, and tsan-deque passes. TSan does not model fences, and the tsan profile also makes push's bottom store Release | hangs; W1x4 times out (200 s), not a report | abi_test and fuzz fail through the oracle; no TSan report | **yes**: "heap-use-after-free sched.rs:458 in deliver" (16/72) | **yes**: "data race" write/write in `steal_any` sched.rs:433 and read/write at sched.rs:653. W1 x4: 0.5 s. The suite fails at every 4- and 8-worker smoke check (22 checks) |
| **deque_stress x50** (release) / **x20** (debug) | **yes**, run 1 (0.3 s and 0.6 s) | no, 50/50 and 20/20: stress pushes before it takes | no | no | no |
| **loom** (deque) | **yes, model-check**: `two_thieves` "an item was lost or taken twice" `[1, 2, 2]`. 0.07 s of model time, 31.7 s with the build | **yes, model-check (indirect)**: `take_vs_steal_last` "Model exceeded maximum number of branches", because take on a fresh deque livelocks. The loom build is `--release`, so there is no overflow panic | n/a, core logic: passes | n/a: passes | n/a, the deque only: passes |
| **Miri** | **yes**: `deque::tests::threads` "item 24 left: 2 right: 1". This is a double take found by Miri's weak-memory emulation, reported as the test assertion and not as UB. 3.4 s of test time, 9.6 s step | **yes**: the overflow panic in `empty_and_lifo` (debug) | **yes, test assertion**: `stale_after_reuse` fails. No UB reported | **yes, UB**: "reference not dereferenceable: alloc… has been freed" at sched.rs:458 (`o.slot` in `deliver`), test `retract`, 11.0 s | **yes, UB**: "Data race detected between non-atomic write on thread unnamed-7 (sched.rs:433) and non-atomic read on unnamed-8 (sched.rs:653)" in `threads_reply_from_elsewhere`, default seed, 14.9 s. With `-Zmiri-many-seeds=0..16` seed 1 also fails |
| **fuzz** (fuzz_run 3000; libFuzzer 120 s) | **no**: 1-worker fuzz cannot steal; 3000 + 3000 inputs and 120 s of libFuzzer are clean | **yes, hang**: fuzz_run debug panics in 0.1 s. fuzz_run release and libFuzzer hang (outer timeout). With `-timeout=5`, libFuzzer reports "timeout after 5 seconds" on its first input (6.1 s) | **yes**: fuzz_run fails on its first random input, 0.0 s. libFuzzer finds it after about 3,770 execs, 0.3 s ("fuzz oracle failed ... a stale reply was not RELEASEd") | **yes**: fuzz_run aborts on input 1, and the existing regression input aborts too. libFuzzer plus ASan reports a double-free on the first input, 0.1 s | **no**: 1 worker, no steals |

### Summary: earliest catch per plant

| plant | first catch | stage | time |
|---|---|---|---|
| P1 | `deque_stress stress` (release); loom `two_thieves`; Miri | test / model-check | 0.3 s for stress; 0.07 s of loom model time |
| P2 | debug overflow panic in `take` | debug-build panic (test) | 0.2 s (cargo test); release shows only hangs |
| P3 | optable `stale_after_reuse`, `abi_test stale`, fuzz oracle | test / fuzz | 0.0-3.6 s |
| P4 | glibc double-free abort; ASan double-free; Miri UB; TSan UAF | test / sanitizer-run | 0.1-11 s |
| P5 | rustc E0594 rejects the bare field; once in UnsafeCell, TSan and Miri | compile (bare) / sanitizer-run | 0.5 s TSan W1x4; 14.9 s Miri |

No plant was caught by clippy. The Rust type system caught only one plant, and only in its literal spelled-out form: P5 written as a bare `u64` field.

## P5 in Rust: what the compiler rejects and what it takes to compile

The diffs and logs are in `results/cloud/bugs-rust/P5-compile/`. Each variant is a copy of the real crate with only the P5 lines changed, built with `--features plant5`.

| variant | P5 spelled as | rustc 1.97 | needs `unsafe` | caught by |
|---|---|---|---|---|
| a | `stolen_from: u64`, `self.worker(v).stolen_from += 1` | **rejected**: E0594 "cannot assign to data in a `&` reference" | — | compiler |
| shipped plant | `UnsafeCell<u64>`, `*stolen_from.get() += 1` | compiles, 0 warnings | yes, a raw-pointer deref. But it sits inside `unsafe fn steal_any` / `unsafe fn run` (edition 2021, `unsafe_op_in_unsafe_fn` allowed), so **no new `unsafe` token is written** | TSan, Miri |
| b | `Cell<u64>`, `.set(.get() + 1)` | compiles, 0 warnings | **none**: Cell is safe | Miri, only with many seeds: the default seed passes and seed 15 of 0..16 fails |
| c | variant b and also `unsafe impl Sync for Core` deleted | **still compiles**, lib and tests | none | — |
| d | `AtomicU64` written as `store(load() + 1)`, a non-atomic RMW | compiles, entirely safe | none | not a data race: Miri with 16 seeds is clean, and TSan cannot see it by construction (not run). The lost updates are a logic bug that only a counter check would find |

**Why Send/Sync never fires here.** `Core` already carries a hand-written `unsafe impl Sync`, which covers any `!Sync` field added later, `Cell` included. More fundamentally, the core never crosses threads as a Rust type. It crosses as `ren_core *` / `*const Core` through the C ABI (`ren_run(c, w, budget)` on each worker thread), so no `Sync` bound is ever checked. Variant c shows that deleting the impl changes nothing. In this design the Send/Sync check only rejects the literal "plain `u64` behind `&`" spelling (E0594, a mutability error, not a Send/Sync error). One `UnsafeCell`, or a `Cell` with zero `unsafe`, gets P5 through rustc. TSan and Miri then catch the UnsafeCell and Cell forms; the atomic load+store form d is caught by neither.

**P4 in owned Rust** (`results/cloud/bugs-rust/P4-compile/`). If the op record travelled as `Box<Op>` and `on_cancel_done(op: Box<Op>)` freed it, rustc rejects `deliver` with E0382, "use of moved value: `op`". If it travels as `&mut Op`, the plant cannot be written at all: `drop(&mut Op)` frees nothing. The core instead uses `*mut Op` because ops cross threads through the C ABI and intrusive MPSC lists. In that form P4 is one `Box::from_raw` line inside an existing `unsafe fn`, and rustc says nothing.

## Control (P0) and a pre-existing hang in the clean core

P0 is clean on every tool except one intermittent check. `tests-release` failed `t_cancel epoll x8` with a 60 s timeout, and every other P0 suite passed (72/72, or 73/73 on asanh). I reran it on its own: `bin/rust-release/harness t_cancel --workers 8` with a 20 s timeout.

| driver | hangs |
|---|---|
| epoll | 2 / 200 |
| uring | 3 / 200 |

A third hunt hung on run 283. Logs are in `results/cloud/bugs-rust/P0-flake/`.

The gdb backtrace (`P0-flake/t_cancel-hang-gdb.log`) shows all 8 workers parked in `epoll_wait(..., timeout=-1)` in `drv/epoll.rs:336`, so no timer is armed anywhere. The main thread is in `pthread_join`. This looks like a lost wake or lost timer on the cancel path at 8 workers, which is oversubscribed on 4 vCPUs. It happens in the **unplanted** core on both drivers. I did not diagnose or fix it; it was outside this task.

It contradicts the build report's "72/72" and "no test caught a logic bug". The hang is intermittent, roughly 1-2% per run at 8 workers. Plant results that depend on `t_cancel x8` are unaffected: the P4 failures happen at every worker count with an immediate abort, not a timeout.

## Notes and deviations

- **Accidental extra build.** I mistakenly started `bugs.sh P1` a second time; it ran one stray `build-release` and was killed by SIGPIPE. Its row was removed from summary.tsv and the rebuild was identical. One `P1 build-release.log` was overwritten with the same content.
- **Aborted P2 run.** The first P2 `tests-release` at a 60 s timeout was aborted and is kept as `P2/tests-release-TMO60-aborted.log`. The run that counts used a 20 s timeout, then 5 s for the other profiles.
- **SPEC §F expectations that did not hold in Rust:**
  - TSan does not catch P1.
  - ASan does not catch P3, because no freed frame is touched: the stale reply lands on the new occupant's live op.
  - The fuzzer does not catch P1 or P5, because it runs 1 worker.
  - "The Rust compiler" catches P4 only in an owned-`Box` design, not in this raw-pointer core.
  - "The Rust compiler (Send/Sync)" catches P5 only when it is spelled as a bare field, and then through E0594 rather than through Send/Sync.
- **Files changed:**
  - `rust/core/src/deque.rs` and `rust/core/src/sched.rs`: the cfg'd plant lines only.
  - `rust/tools/bugs.sh`: new.
  - Nothing in `harness/` or in any design doc.
- **Built outputs:** `bin/rust-*-Pn/`, `bin/rust-asanh*/`, `build/rust-*-Pn/` and `rust/target/<tag>/`, all git-ignored. The P4 and P5 compile variants were built in the scratchpad.

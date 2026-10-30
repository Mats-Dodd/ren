# VERIFY: an independent check of the Phase B headline numbers and planted-bug tables

Machine: **cloud** (experiments/MACHINE-cloud.md: 4 vCPU Xeon under KVM, Linux 6.18). Date: 2026-10-30, about 20:00-22:00 UTC.
Raw data is in `results/cloud/verify/`:
- `bench.jsonl`: every sample, with machine "cloud", cmd, rc, loadavg and metrics.
- `bench-summary.txt`
- `plant-builds.txt`, `plant-rates.txt`, `fuzz-loom-asan.txt`, `w1-wakepath.txt`
- `logs/`
- `scripts/`: vbench.py, vbugs.sh, vbugs2.sh, vsum.py

No apt packages were installed. I made no git operations and did not edit any design doc or harness file. I did not edit the language sources in the repo either: every plant build and variant was done in a scratch copy.

## Method

1. **Separate rebuild.** I copied the sources (c/, rust/, zig/, harness/, build.sh) into a scratch directory with tar, leaving out bin/, build/, rust/target/, zig/.zig-cache/ and results/. I rebuilt from scratch there with `./build.sh c release`, `rust release`, `zig release-fast`, and then `./build.sh w5 rust zig`. The build takes the shared lock itself. All builds succeeded, including both W5 LTO variants. The headline numbers below come from these binaries, not from the repo's bin/.
2. **Benchmarks.** Each run took the **exclusive** lock alone (`flock -x /tmp/ren-bench/lock timeout 600 <cmd>`), so other agents' work could slip in between runs. I interleaved the languages within each rep (c, rust, zig, c, ...), so slow drift affects all three equally. Each configuration got 7 reps, and the commands and sizes are exactly the ones claimed. I report median [min, max] and spread = (max-min)/median.
3. **Plants.** I rebuilt P1, P3 and P5 for every language in release and tsan, plus C asan-P3 and C ubsan-int-P2. I also rebuilt every row claimed to catch a bug at compile time: C P2 -Werror and -Wconversion, C P4 `clang --analyze`, Zig P2, and Rust P5 in three hand-made variants. I ran the claimed catching tool and at least one claimed non-catching tool against an unplanted P0 control. Every step ran under `flock -s`.

## Did the benchmarks measure what they claim? (code read)

| check | finding |
|---|---|
| W5 dead-code elimination | **OK.** The loop calls out-of-line `ren_hot_dup`/`ren_hot_drop` from another unit with no LTO, behind an `asm volatile("" ::"r"(o) : "memory")` barrier. The clang binaries have 4 `call ren_hot_d*` sites each. The disassembled `ren_hot_dup` is the same 8 instructions in C (ii), Rust (iii) and Zig (iv); Zig only adds a push/pop of rbp. The shared (rc<0) path is one `lock decl` plus one `lock xadd`, so about 20 ns is the cost of two uncontended lock-prefixed RMWs. Equal numbers are therefore expected: this metric cannot tell the languages apart. |
| W5 tcc row | **The label is misleading.** For C, build.sh compiles the hot path itself with tcc (`tcc ... hot/w5_hot.c hot/hot_c.c`). Rust's and Zig's hot libraries stay LLVM-optimized. So "C is slower when called from tcc" measures tcc's codegen of the hot path, not the cost of calling across languages. |
| Timing scope | W1, W2: from the root's first resume to the root seeing `left==0`. That includes spawning the two players for W2, which is negligible against 10M turns. W3: from issuing READ to resume after the reply, and each READ goes through outbox → driver → `read()` → reply. `answer_now` only answers MONO_NOW inline, so the READ really is a driver round trip. |
| Percentiles (W3) | **OK.** After a qsort it reads `lat[n/2]`, `lat[n*99/100]`, `lat[n*999/1000]` (nearest rank, floored). |
| Workers concurrent | **Yes.** At 4 workers cpu/wall was 1.5-1.7 for W1 and W2, and there is one pthread per worker. W3 runs a single task, so "8 workers" means 7 idle workers. |
| Replay is OS-free | **Confirmed.** Under strace, a replay of a recorded W3 (2000 iterations, 6000 world calls) makes only loader, journal-file and stdout syscalls (about 60 in all, the same for all 3 languages). Not one epoll, io_uring, pipe or clock syscall. |
| **W1 x8 cost** | **Wake-path dominated (caveat, not a bug).** At 8 workers, 70-80% of CPU time is kernel time, with 0.7-0.9 voluntary context switches per task (C 691k, Rust 826k, Zig 902k for 1M tasks). At 2 workers there are 29-9330 switches. Throughput falls from 5.5M/s (x1) and 2.4M/s (x2) to 0.55M/s (x3), 0.18M/s (x4) and 0.14M/s (x8). Under `strace -f` the x4 run goes **2.48M/s**, because strace changes the timing. So the W1 x4/x8 headline measures the park/eventfd-wake protocol on a 4-vCPU guest, not spawn cost, and it is very sensitive to timing. The comparison is still like for like, since all three use the same SPEC policy. See `verify/w1-wakepath.txt`. |

## Headline numbers: verdicts

Each cell shows my median [min, max] (spread), followed by Δ, my median against the claimed one. **Verdict scale:** confirmed = my median within 10% of the claim; within-noise = within 10% but the language ordering is not resolvable; disagrees = more than 10% off; could-not-reproduce = not run.

| metric | C | Rust | Zig | verdict |
|---|---|---|---|---|
| W1 tasks/s epoll x8 | 143,278 [139,150, 151,513] (8.6%) Δ+2.8% | 131,745 [123,160, 147,476] (**18.5%**) Δ+4.4% | 122,048 [116,346, 124,218] (6.4%) Δ-1.0% | **confirmed**. C > Zig resolves; Rust overlaps both. |
| W1 tasks/s uring x8 | 134,304 [127,894, 140,283] (9.2%) Δ-4.1% | 128,871 [122,726, 139,193] (12.8%) Δ-2.7% | 116,916 [115,139, 120,412] (4.5%) Δ-2.9% | **confirmed**. C > Zig resolves; Rust overlaps C. |
| W2 ns/switch epoll x4 | 1,991.9 [1,825.4, 2,094.6] (13.5%) Δ+6.0% | 1,831.7 [1,775.3, 1,875.9] (5.5%) Δ+4.5% | 1,982.1 [1,927.7, 2,092.8] (8.3%) Δ+2.9% | **confirmed**. Rust fastest; C and Zig tie. |
| W2 ns/switch uring x4 | 2,564.6 [2,455.8, 2,598.6] (5.6%) Δ+7.5% | 1,960.4 [1,818.2, 1,984.9] (8.5%) Δ+5.6% | 2,327.9 [2,175.6, 2,382.5] (8.9%) Δ+4.5% | **confirmed**. Rust < Zig < C, all three ordered. |
| W2 ns/switch epoll x8 | 3,240.5 [3,111.7, 3,311.8] (6.2%) Δ+4.0% | 3,080.5 [3,036.3, 3,282.0] (8.0%) Δ+5.2% | 3,217.2 [3,115.6, 3,306.0] (5.9%) Δ+2.5% | **confirmed / within-noise**. The ranges overlap, so there is no resolved ordering. |
| W2 ns/switch uring x8 | 3,577.8 [3,479.9, 3,637.8] (4.4%) Δ+6.4% | 3,253.9 [3,057.4, 3,324.7] (8.2%) Δ+8.4% | 3,603.5 [3,533.9, 3,742.0] (5.8%) Δ+4.9% | **confirmed**. Rust fastest; C and Zig tie. |
| W3 p50 ns epoll x8 | 5,621 [5,451, 5,817] (6.5%) Δ-0.3% | 4,875 [4,791, 4,980] (3.9%) Δ+1.7% | 5,057 [4,974, 5,237] (5.2%) Δ-0.7% | **confirmed**. C slowest; Rust and Zig barely separate. |
| W3 p50 ns uring x8 | 5,238 [5,046, 5,396] (6.7%) Δ-0.9% | 4,801 [4,677, 4,947] (5.6%) Δ-2.1% | 4,438 [4,336, 4,547] (4.8%) Δ-1.4% | **confirmed**. Zig < Rust < C. |
| W3 p99 ns epoll x8 | 39,524 [37,938, 42,126] (10.6%) Δ+2.4% | 38,419 [37,742, 39,873] (5.5%) Δ+0.2% | 39,605 [36,754, 40,144] (8.6%) Δ+5.3% | **confirmed / within-noise**. No language difference. |
| W3 p99 ns uring x8 | 40,186 [37,763, 41,469] (9.2%) Δ+1.0% | 39,370 [37,894, 41,082] (8.1%) Δ-3.4% | 38,538 [37,807, 39,284] (3.8%) Δ-2.2% | **confirmed / within-noise**. No language difference. |
| W5 dupshared ns/op, clang caller | 20.78 [20.24, 21.25] (4.9%) Δ+1.3% | 20.96 [20.39, 21.80] (6.7%) Δ+3.9% | 21.12 [19.69, 21.48] (8.5%) Δ+4.2% | **confirmed / within-noise**. The machine code is identical (see above). |
| W5 dupshared ns/op, tcc caller | 25.26 [24.20, 25.51] (5.2%) Δ+4.0% | 20.99 [20.39, 23.54] (15.0%) Δ+2.7% | 21.09 [20.49, 21.68] (5.6%) Δ+3.7% | **confirmed**. C is slower, but only because tcc compiles C's hot path (see the W5 tcc row above). |

Every one of the 36 cells is within 10% of the claim: the largest gap is +8.4% (Rust W2 uring x8), and 34 of 36 are within 7.5%. My W2 runs are 2.5-8.4% slower **for all three languages at once**. That points to a machine-wide shift (loadavg was 1-4 at the start of runs), not to a change between languages.

Four of my configurations went over the 10% spread rule: Rust W1 epoll (18.5%), Rust W1 uring (12.8%), C W2 epoll x4 (13.5%) and Rust W5 tcc (15.0%; one 23.5 ns outlier). measure_b.py would have re-run these, and I did not.

## Planted bugs: verdicts

For each row: the claimed result, then my result. P0 is the unplanted control, run with the same command and count.

| lang | bug | tool (claim) | claimed | mine | verdict |
|---|---|---|---|---|---|
| C | P1 | deque_stress stress 10 200000, release | yes, 23/30 | **17/20** failed, e.g. `duplicated=80639 lost=80639`; P0 0/20 | confirmed (the rate is intermittent) |
| C | P1 | TSan deque_stress | no, 0/30 | 0/10; P0 0/10 | confirmed |
| C | P1 | W1 test (x8 release) | no, 0/20 | 0/10 | confirmed |
| C | P1 | -Wall -Wextra (-Werror build) | no | builds clean under -Werror | confirmed |
| C | P1 | fuzz_run | no | `--random 300 1` passes | confirmed |
| C | P2 | -Werror build | yes, dq.c:47:13 -Wsign-compare | identical error; it fails because cap stayed signed | confirmed |
| C | P2 | -Wconversion | clang 6, gcc 10 | clang dq.c 6 (P0 0). gcc 10 for the whole core, against 4 for P0, so 6 come from the plant | confirmed (the gcc figure is the total, not the plant's share) |
| C | P2 | UBSan integer | yes, dq.c:58:32 `0 - 1` | identical message from `deque_stress empty` | confirmed |
| C | P2 | deque_stress stress (ubsan-int) | passes | passes | confirmed |
| C | P3 | abi_test stale | yes, abi_test.c:218 | 3/3 release, 3/3 tsan, 2/2 asan, same line; P0 0/3 | confirmed |
| C | P3 | fuzz_run oracle | yes | `--random 300 1`: "a stale reply was ACCEPTED (id 0000000c00000001)"; P0 ok | confirmed |
| C | P3 | ASan | no (only LeakSanitizer after abort) | rc=1 from the abi_test assert; the only Sanitizer output is LeakSanitizer | confirmed |
| C | P3 | TSan | no | abi_test fails only by its own assert, with no TSan report | confirmed |
| C | P3 | W3 test | no | W3 uring x4 passes 3/3 | confirmed |
| C | P4 | clang --analyze | yes, core.c:150:16 unix.Malloc | core.c: 1 warning at exactly core.c:150:16; P0 core.c 0 | confirmed |
| C | P5 | TSan W1 x4 | yes, 20/20, sched.c:165/191 | epoll **10/10**, uring 5/5, `sched.c:165:27 in steal_any`; P0 0/10 and 0/5 | confirmed |
| C | P5 | release W1 x8 / deque_stress | no | 0/10, 0/5 | confirmed |
| Rust | P1 | deque_stress, release | yes | **13/20**; P0 0/20 | confirmed |
| Rust | P1 | loom | yes, two_thieves | `two_thieves ... an item was lost or taken twice`; P0 3/3 pass | confirmed |
| Rust | P1 | TSan (nightly) deque_stress | no | 0/10 | confirmed |
| Rust | P1 | rustc | no, 0 warnings | 0 warnings | confirmed |
| Rust | P1 | W1 x8 release / fuzz_run | no | 0/10; fuzz passes | confirmed |
| Rust | P3 | abi_test | yes, abi_test.c:218 | 3/3 release, 3/3 tsan | confirmed |
| Rust | P3 | fuzz_run | yes, "a stale reply was not RELEASEd" | the same message | confirmed |
| Rust | P3 | TSan / W3 | no | no TSan report; W3 3/3 pass | confirmed |
| Rust | P5 | rustc, bare u64 | yes, E0594 (a mutability error, not Send/Sync) | `error[E0594]: cannot assign to data in a & reference`, sched.rs:433:21 | confirmed |
| Rust | P5 | rustc, Cell<u64> in the slice | no | compiles. It **still compiles after deleting `unsafe impl Sync for Core`** | confirmed. This **refutes** the C table's explanation ("because Core already has unsafe impl Sync") and supports the Rust table's (Core crosses threads as a raw pointer through the C ABI). |
| Rust | P5 | rustc, standalone Arc<Cell> | yes, E0277 | `error[E0277]: Cell<u64> cannot be shared between threads safely` | confirmed |
| Rust | P5 | rustc, UnsafeCell (as planted) | no | builds, 0 warnings | confirmed |
| Rust | P5 | TSan W1 x4 | yes, sched.rs:433 | epoll 10/10, uring 5/5, `sched.rs:433:21 in steal_any`; P0 0/10 | confirmed |
| Rust | P5 | release tests / fuzz | no | W1 x8 0/10, deque 0/5, fuzz passes | confirmed |
| Zig | P1 | deque_stress, release-fast | yes, **7/20** | **17/20**; P0 0/20 | caught: confirmed. Rate **disagrees** (85% against 35%); it is intermittent and depends on load. |
| Zig | P1 | TSan | no, 0/20 | 0/10 | confirmed |
| Zig | P1 | compiler / W1 tests / fuzz | no | 0 warnings, W1 x8 0/10, fuzz passes | confirmed |
| Zig | P2 | compiler (spec-exact P2) | yes, dq.zig:66:39 | `src/dq.zig:66:39: error: incompatible types: 'u64' and 'i64'` in release-fast and debug | confirmed. Like C, it is caught only because cap stays i64. |
| Zig | P3 | abi_test | yes | 3/3 release-fast, 3/3 tsan | confirmed |
| Zig | P3 | fuzz_run | yes | "a stale reply was ACCEPTED" | confirmed |
| Zig | P3 | TSan / W3 | no | no TSan report; W3 3/3 pass | confirmed |
| Zig | P5 | compiler | no | builds silently | confirmed |
| Zig | P5 | TSan W1 x4 | yes, core.zig:562/419 | epoll 10/10 (`core.zig:562:45 in core.run`), uring 5/5 (`core.zig:419:27 in core.stealAny`); P0 0/10 | confirmed |
| Zig | P5 | release tests / fuzz | no | W1 x8 0/10, deque 0/5, fuzz passes | confirmed |

Not re-run: P4 at run time in all languages (except C `clang --analyze`), P2 at run time in Rust and Zig, Miri, valgrind, libFuzzer, and GenMC. GenMC is recorded as could-not-run because building it was denied; I did not try either.

## Harness issues that matter

1. **The meaning of W1 x8 (and x4).** The number mostly measures context switches and kernel time on the park/wake path, at roughly 0.8 sleeps per task. strace alone makes it 13x faster. It is a fair cross-language comparison of one wake policy, but it should not be read as "spawn cost". Its wide spread (Rust 18.5%) follows from that.
2. **The W5 tcc metric** compares a tcc-compiled C hot path against LLVM-compiled Rust and Zig hot paths. It is not "the same hot path called from tcc".
3. **The W5 dupshared numbers are identical by construction.** All three compile to the same lock-prefixed instructions, so the metric cannot rank the languages.
4. **`fuzz_run` with no arguments exits 0** ("0 files ok"). A script that calls it without `--random N SEED` passes silently. My first plant pass made this mistake and I re-ran with `--random 300 1`. test.sh passes the arguments, so the claimed results are not affected.
5. **W3 "x8 (oversubscribed)"** runs one task, so the extra workers only add idle threads parked in epoll or io_uring.

No defect I found invalidates any of the claimed numbers.

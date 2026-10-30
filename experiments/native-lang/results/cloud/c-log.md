# C entry: build log, machine cloud

Machine: **cloud** (experiments/MACHINE-cloud.md: 4 vCPU Xeon under KVM,
Linux 6.18). Toolchain: clang 18.1.3 (every profile except tcc), tcc 0.9.27,
liburing 2.5, clang-22 for the `lto-hot` hot library. No timing runs were
done. No bugs are planted yet. Design notes, departures from SPEC, the tcc
findings and the bug list with what caught each are in `c/NOTES.md`.

## Wall time

- `date` at start: Fri Oct 30 13:09:54 UTC 2026
- `date` at end: Fri Oct 30 13:36 UTC 2026 (the last `date` before this file was written read 13:36:13)
- Total: about 0.45 h.

The per-part times below are reconstructed from the order of the work
between those two `date` calls. They are approximate: I only ran `date` at
the start and the end.

| part | approx. |
|---|---|
| reading SPEC, slice.h, harness | 4 min |
| deque (atom.h, dq.c) | 2 min |
| core (core.h, sched.c, core.c, journal.c) | 5 min |
| drivers (drv_common.c, drv_epoll.c, drv_uring.c) | 5 min |
| replay and fuzz (drv_replay.c) | 2 min |
| hot path and layout (hot.c, layout.c) | 1 min |
| build profiles, test runs, fixing bugs 2 to 6, tcc and TSan investigation, notes | 7 min of work, with the suites running in the background |

## Functional results

Each profile ran `harness/test.sh bin/c-<p>` with `WORKERS="1 4 8"`, both
drivers and all default suites. The full lines are in
`results/cloud/c-functional.txt`.

| profile | passed | failed |
|---|---|---|
| release (clang -O2) | 72 | 0 |
| debug (clang -O0, debug checks) | 72 | 0 |
| asan (ASan+UBSan, plus the libFuzzer target) | 73 | 0 |
| ubsan-int (`-fsanitize=undefined,integer`, no recover) | 72 | 0 |
| tsan | 72 | 0 |
| tcc (core by tcc 0.9.27; drv_uring.c by clang) | 72 | 0 |

Each profile's run covered:
- layout_check;
- abi_test, all 12 tests;
- deque_stress empty, lifo and stress (10 rounds of 200000);
- w1, w2 and w3 on epoll and uring at 1, 4 and 8 workers;
- t_timer, t_pipe, t_tcp and t_cancel, plus t_block stop and kill, on both drivers at 1, 4 and 8 workers;
- W4: w1, w3, t_cancel and t_timer recorded at 1 worker and replayed with
  output identical. A replay checks every core entry byte for byte. A
  flipped input byte and a truncated journal were both refused on both
  drivers;
- fuzz_run --random 300.

Further runs:
- **Recordings byte-identical across compilers:** w1 and w3 recorded at 1
  worker by clang-release and by tcc are byte-identical on epoll and on
  uring (`cmp`).
- **xreplay:**
  - c-release to c-tcc, 8 of 8 passed;
  - c-tcc to c-release, 8 of 8 passed;
  - c-release to stub-release, 8 of 8 passed;
  - stub-release to c-debug (w1 and w3), 2 of 2 passed.
- **Replay at 4 and 8 workers:** this always reports a divergence (at entry
  3 to 3587), which is the expected "schedule divergence" of SPEC §D.1. It
  is not a pass.
- **Fuzzing:**
  - libFuzzer: 1,000,000 runs, seed 11, 46 s, clean. Before the fix to bug
    3, a 20,000-run pass found that bug;
  - fuzz_run --random 3000 under tcc: clean;
  - fuzz_run --random 3000 under ubsan-int: clean.
- **E1:** `./build.sh e1 c` builds. w1, w2 and w3 give correct results in
  both unity and split form. That build first failed on static-name clashes
  between drv_epoll.c and drv_uring.c, so their statics now carry `ep_` and
  `ur_` prefixes.

## Harness change (shared by all languages)

ThreadSanitizer does not model `atomic_thread_fence`. So it reports races
on the harness's own rc protocol: the plain read in slice.h `ren_dup` and
`ren_drop`, and Arc's `fence(ACQ)` in rt.c `ren_drop_shared`. It reports
them on every shared dup and drop, whatever the core. The change is
TSan-only, and other builds compile to the same code as before:
- **slice.h:** I added `REN_TSAN_HARNESS` detection and the macro
  `REN_RC_READ(o)`. Under TSan the macro is a relaxed atomic load; otherwise
  it is `o->rc`. `ren_dup` and `ren_drop` now read rc through it.
- **rt.c `ren_drop_shared`:** under `REN_TSAN_HARNESS`, an acquire load of
  rc replaces the acquire fence.

`./build.sh check` still compiles the harness under clang, gcc and tcc.

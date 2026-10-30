# Zig entry: build log, machine cloud

Machine: **cloud** (experiments/MACHINE-cloud.md: 4 vCPU Xeon under KVM,
Linux 6.18). Toolchain: Zig 0.17.0 (`/usr/local/bin/zig`, checked by
zig/build.sh). The harness is built with clang 18. The hand-built libFuzzer
target uses clang 18 `-fsanitize=fuzzer,address,undefined`. I installed
nothing with apt. I ran no timing runs and planted no bugs. Design notes,
departures from SPEC, the Zig 0.17 findings, the pointer-site count and the
bug list with what caught each are in `zig/NOTES.md`.

## Wall time

- `date` at start: Fri Oct 30 13:37:39 UTC 2026
- `date` at end: Fri Oct 30 14:21:14 UTC 2026
- Total: about 0.73 h.

The per-part times are reconstructed from file timestamps and the order of
the work, so they are approximate.

| part | approx. |
|---|---|
| reading SPEC, slice.h, harness, the C entry's journal/replay encoding (for cross-language byte compatibility), probing Zig 0.17 std (IoUring, linux, SafeAllocator, panic) | 6 min |
| deque (dq.zig), alloc.zig, wire.zig | 2 min |
| core (core.zig) | 4 min |
| replay and fuzz (replay.zig) | 2 min |
| drivers (drv.zig, epoll.zig, uring.zig) | 4 min |
| hot path, root exports and layout table, build.sh | 3 min |
| first build (compile errors 1 to 5) and first tests | 2 min |
| W2 ×4 hang investigation with gdb (bug 9, unresolved) | 8 min |
| profiles (release-safe and tsan compiler-rt, lto-hot), xreplay, libFuzzer, the ACCEPT bug (10), GNU-stack (11), suites, notes | 12 min, with suites running in the background |

## Functional results

Each profile ran `harness/test.sh bin/zig-<p>` with `WORKERS="1 4 8"`, both
drivers and all default suites. The full lines are in
`results/cloud/zig-functional.txt`.

| profile | passed | failed |
|---|---|---|
| release-fast | 72 | 0 |
| release-safe (plus a hand-built libFuzzer target, 20000 runs) | 73 | 0 |
| debug (self-hosted backend, debug checks) | 72 | 0 |
| tsan (`-fsanitize-thread`; no fuzz suite; 0 ThreadSanitizer reports) | 71 | 0 |

The 72 checks cover W1, W2 and W3 on epoll and io_uring at 1, 4 and 8
workers, and all the I/O tests (timer, pipe, TCP, cancel, stop, kill) on
both drivers at 1, 4 and 8 workers.

W4 replay (w1, w3, t_cancel, t_timer, recorded on both drivers at 1 worker)
gives byte-identical output, and every core entry matches in
`ren_drv_finish`. The flipped-byte and truncated journals are both refused.

Recordings made at 4 or 8 workers end in a clean "replay diverged at entry
N" report (SPEC §D.1 scope).

**Cross-language replay:**

| direction | result |
|---|---|
| Zig → C | 8/8 |
| C → Zig | 8/8 (one flaky C recording rerun, see below) |
| Zig → Rust | 8/8 |
| Rust → Zig | 8/8 |
| Zig → stub | 8/8 |
| stub → Zig | 2/2 |

- C → Zig: the first run failed only in C's own recording of t_timer on
  epoll ("order or timing wrong", order 2,4,1,3,0). That is a flake in the
  C entry. The rerun passed 8/8.
- stub → Zig: the stub can only record w1 and w3 on epoll; the other 6 are
  the stub failing to record.

io_uring with `--no-defer` passes t_timer, t_tcp, t_cancel and w3 at 4
workers. `./build.sh w5 zig` builds variants iv-tcc, iv-clang and
vi-zigcc-lto.

## Open issue

Bug 9 in zig/NOTES.md is still open. W2 at 4 workers hung in about 8 of 15
runs during one window. The core state in gdb showed a lost notify: both
players PARKED with no flag. It was not reproduced in more than 100 later
runs, including runs under CPU load and with a new double-execution check.
The code is line for line the C entry's protocol.

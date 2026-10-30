# K1b results: which machine

- **Files directly in `results/`** (and `results/aborted/`) are from the owner's
  **macOS** laptop: Apple M4 Max, 12P+4E, measured 2026-10-29 with
  `measure.sh`. They are the macOS reference. Leave them as they are.
- **`results/cloud/`** is the **cloud** machine (see
  `experiments/MACHINE-cloud.md`): 4 vCPU Intel Xeon @ 2.1 GHz, KVM, no SMT,
  Linux 6.18. Measured with `measure-cloud.sh`. Every file there starts with a
  `# machine=cloud` header, and every line ends with `machine=cloud`.

## How the cloud runs differ from macOS

| | macOS (`results/`) | cloud (`results/cloud/`) |
|---|---|---|
| per-worker clock (use stamp, `at` latency) | `mach_absolute_time`, 24 MHz, 41.7 ns tick | `rdtsc`, invariant TSC, about 2.1 GHz (0.476 ns tick), rate calibrated at start against `CLOCK_MONOTONIC_RAW`. A back-to-back `rdtsc` pair reads about 30 ticks (14 ns), so that much is inside every timed `at` |
| latency histogram bucket | 1 tick = 41.7 ns, range 2.7 ms | 16 ticks = 7.6 ns, range about 8 ms |
| `--lock os` | `os_unfair_lock` | `pthread_mutex_t` (glibc default: futex, no spin) |
| `--qos p` | `QOS_CLASS_USER_INTERACTIVE` | ignored (no QoS classes; SCHED_OTHER) |
| `mem` footprint | `phys_footprint` | RSS from `/proc/self/statm` (`footprint_src=rss`) |
| workers | 1, 2, 4, 8, 12, 16 | 1, 2, 3, 4, and 8, 16 oversubscribed (`oversub=1`) |
| extras workers | 1, 8, 16 | 1, 4, 8, 16 (parts sweep: 4, 8, 16) |
| reps | 7 × 200 ms after a 200 ms warm-up | the same, each configuration under `flock -x`; spread > 10% is re-run up to twice, then marked `noisy=1 NOISY` |
| load | `sysctl vm.loadavg` before the run | `/proc/loadavg`, at start and end (`load1_start=`, `load1_end=`) |
| TSan build | clang | gcc 13 (clang 18 here has no TSan runtime) |

The instance stays 128 bytes on x86 too (the line is 64 B, but keeping 128
keeps the layout identical to macOS). `CLOCK_MONOTONIC_COARSE` wasn't used: its
resolution on this kernel is 4 ms.

The Rust threaded harness and simulator (`rust/src/k1b.rs`, `rust/src/sim.rs`)
were rewritten from the C for this port. The originals were in
`rust/src/bin/`, which `experiments/.gitignore`'s `bin/` rule also matched, so
they were never committed. The rewritten simulator gives the same output as the
C on all 32 traces. The C simulator on Linux gives the same output as the macOS
`results/sim-20261029-210431.txt`, all 32 lines identical. So the macOS Rust
rows in `results/` came from code that is no longer in the repository.

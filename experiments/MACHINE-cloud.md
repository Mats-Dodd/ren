# Machine: `cloud` (claude.ai cloud container, 2026-10-30)

Every result file from the cloud runs names this machine as `cloud`.
Results from the owner's laptop stay labelled `macOS` (Apple M4 Max, 12P+4E).

| item | value |
|---|---|
| CPU | Intel Xeon Processor @ 2.10 GHz (family 6 model 207, Emerald Rapids class), KVM guest |
| cores | **4 vCPUs**, 1 socket, 4 cores, **1 thread per core (no SMT visible)**, 1 NUMA node |
| caches | L1d 48 KiB/core, L2 2 MiB/core, L3 260 MiB shared (as reported by the guest); line 64 B |
| memory | 15 GiB, no swap; THP `madvise` |
| kernel | Linux 6.18.44-fc-v185, `PREEMPT_DYNAMIC`, x86_64 |
| cpufreq | not exposed (no governor in guest); `tsc_known_freq`, `constant_tsc` |
| io_uring | **available**: `kernel.io_uring_disabled=0`, no seccomp filter on the process; `io_uring_queue_init` + NOP succeed; probe: `MSG_RING` and `SEND_ZC` supported. liburing 2.5 (Ubuntu `liburing-dev`) |
| perf | `perf_event_paranoid=2`; `perf` not installed |
| libc | glibc 2.39; musl 1.2.4 (`musl-gcc`) |

## Toolchains

| tool | version | how |
|---|---|---|
| clang | Ubuntu clang 18.1.3 | preinstalled; ASan/TSan/UBSan runtimes present |
| gcc | 13.3.0 | preinstalled |
| tcc | 0.9.27 | `apt-get install tcc` |
| rustc / cargo | 1.97.0 stable (2026-07-07) | preinstalled; targets x86_64/aarch64 `-linux-musl`, `wasm32-unknown-unknown` added |
| rustc nightly | 1.101.0-nightly (92b5b8c87 2026-10-29), Miri 0.1.0 | `rustup toolchain install nightly`, for Miri only |
| go | 1.24.7 linux/amd64 | preinstalled |
| zig | **0.14.1, pinned** | official tarball `zig-x86_64-linux-0.14.1.tar.xz` in `/opt/zig`, linked as `/usr/local/bin/zig` |
| node | 22.22.0 (no JSPI: `WebAssembly.Suspending` undefined without flags) | preinstalled |
| python3 | 3.13 | preinstalled |
| valgrind | 3.22.0 | preinstalled |

## Measurement rules on this machine

- Runs are serialised machine-wide with `flock`: benchmarks take
  `flock -x /tmp/ren-bench/lock`, builds and checks take `flock -s` on the
  same file, so nothing compiles while a benchmark runs.
- Load is read from `/proc/loadavg` and recorded at the start and end of
  every configuration.
- At least 7 repetitions per configuration; report median, min and max.
  A configuration whose spread (max − min)/median exceeds 10% is re-run;
  if it still exceeds 10% it is reported as noisy, not used as a headline.
- Only 4 cores: any configuration with more than 4 busy threads is
  oversubscribed by construction. Results above 4 workers say what this
  machine does, not what the runtime does.

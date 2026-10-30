# switch results

- **Files directly in `results/`** (`smoke-*.txt`, `measure-*.txt`) are the
  **macOS** reference runs: the owner's laptop, Apple M4 Max (12P+4E), from
  `measure.sh` / `measure-p2.sh`. They are kept unchanged.
- **`results/cloud/`** holds runs on the **cloud** machine (claude.ai cloud
  container: 4 vCPUs, KVM, Intel Xeon 2.1 GHz, Linux 6.18; see
  `experiments/MACHINE-cloud.md`), from `measure-cloud.sh`. Every file there
  names the machine as `cloud` in its header. `.cmds` lists every command,
  `.err` collects stderr.

Differences to keep in mind when comparing the two:

- Timer: `mach_absolute_time` on macOS, `clock_gettime(CLOCK_MONOTONIC)` on Linux.
- Memory: macOS reports peak `phys_footprint` (`/usr/bin/time -l`, `task_info`);
  the cloud runs report peak RSS (`ru_maxrss` via `build/peakrss`, and
  `/proc/self/statm` in-process). `bytes_per_task` (allocator-level) is the
  same measure on both.
- Repetitions: on macOS a line is one process (median of its in-process reps).
  On cloud a configuration is 7 such processes; it reports the median, min and
  max of their medians, with spread = (max-min)/median, and NOISY above 10%.
- Toolchains: Go 1.24.7 and rustc 1.97 on cloud (go.mod says `go 1.24`);
  macOS used Go 1.27. ASan/UBSan builds use gcc on cloud (clang 18 there has
  no sanitizer runtimes); they are for `--check` only.

Compare ratios within one machine, not absolute numbers across them.

# percore results

- **Files directly in `results/`** (`measure-*.txt`, `.cmds`, `.err`) are the
  **macOS** reference runs: the owner's laptop, Apple M4 Max (12P+4E), from
  `measure.sh` / `measure-p2.sh`. They are kept unchanged.
- **`results/cloud/`** holds runs on the **cloud** machine (claude.ai cloud
  container: 4 vCPUs, KVM, Intel Xeon 2.1 GHz, Linux 6.18; see
  `experiments/MACHINE-cloud.md`), from `measure-cloud.sh`. Every file there
  names the machine as `cloud` in its header and includes the extension
  (work_stealing / per_core / place_at_spawn, even and skewed load).

The two machines differ in core count (16 vs 4), ISA, timer, parking primitive
(ulock vs futex) and pinning (none vs `sched_setaffinity`), so compare ratios
within one machine, not absolute numbers across them. See PLAN.md, "Cloud port".

`results/cloud/SUMMARY.md` summarises the cloud runs: every configuration, the load records, headlines, and comparisons with PLAN.md and macOS.

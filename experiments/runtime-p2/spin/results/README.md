# spin results

- Files directly in `results/` (`full-*.txt`, `tsan.log`) are from the owner's
  laptop: **macOS, Apple M4 Max (12P+4E)**, built with `build.sh` and run with
  `measure.sh` / `measure-p2.sh` (ulock, mach time, QoS user-interactive, no
  pinning, workers 2/8/16). They are the macOS reference; leave them as they are.
- Files in `results/cloud/` are from the **cloud** machine
  (`experiments/MACHINE-cloud.md`: 4 vCPU Xeon KVM guest, Linux 6.18), run with
  `measure-cloud.sh` (futex, `clock_gettime`, workers 2/4 pinned one per CPU,
  8 unpinned and oversubscribed, section 2 at 4 workers). Every file there
  names `machine=cloud` in its header. `results/cloud/tsan.log` is the Linux
  TSan run of `--check` (gcc 13 libtsan).
- Summarise a cloud run with
  `python3 analyze.py results/cloud/full-<stamp>.txt --wait-workers 4`
  (NOISY configs are dropped unless `--keep-noisy`). The per-config
  median/min/max/spread and load are in `results/cloud/summary-<stamp>.txt`.
- `results/cloud/SUMMARY.md`: the cloud measurement write-up (headlines with
  reproduce commands, every configuration's median [min..max] spread and NOISY
  flag, comparison with PLAN.md). Besides the main sweep (`summary/full/raw-20261030-063521`)
  it uses a 2 s-window repeat (`*-20261030-0905-w2000`), an idle-burn run gated on
  CPU metrics (`*-20261030-idleburn`) and the oversubscription control
  `oversub-20261030-063521.txt` from `oversub-cloud.sh` (`--pin auto|off|wrap`).
  Tables: `python3 cloudtable.py results/cloud/summary-<stamp>.txt`.

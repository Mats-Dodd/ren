"""Prints tables from measure.sh's CSV: `python3 -I summarize.py [csv]`.

Throughput is nodes visited per second, all threads together, the
median of the repetitions, with the lowest and highest beside it.
Efficiency is the median throughput at N threads over N times the median
at one thread, of the same build and mode: 100% is linear scaling."""

import csv
import os
import statistics
import sys
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.environ.get("TMPDIR", "/tmp"), "ren-bench-cores.csv")
runs = defaultdict(list)
loads = []
with open(path) as f:
    for r in csv.DictReader(f):
        key = (int(r["depth"]), r["build"], r["mode"], int(r["threads"]))
        runs[key].append(float(r["nodes_per_sec"]))
        loads.append(float(r["load1"]))

print(f"load average over the runs: min {min(loads):.1f}, "
      f"median {statistics.median(loads):.1f}, max {max(loads):.1f}\n")

builds = ["plain", "shared", "atomic", "rust"]
modes = ["a-owned", "a-borrowed", "b", "c", "d", "e"]
threads = sorted({k[3] for k in runs})
for depth in sorted({k[0] for k in runs}):
    print(f"### depth {depth}: {2 ** depth - 1} nodes\n")
    head = "| build | mode | " + " | ".join(f"{t} thr (M nodes/s)" for t in threads)
    head += " | " + " | ".join(f"eff {t}" for t in threads if t > 1) + " |"
    print(head)
    print("|" + "---|" * (2 + len(threads) + len([t for t in threads if t > 1])))
    for b in builds:
        for m in modes:
            if (depth, b, m, 1) not in runs:
                continue
            base = statistics.median(runs[(depth, b, m, 1)])
            cells, effs = [], []
            for t in threads:
                xs = runs.get((depth, b, m, t))
                if not xs:
                    cells.append("")
                    if t > 1:
                        effs.append("")
                    continue
                med = statistics.median(xs)
                cells.append(f"{med / 1e6:.0f} ({min(xs) / 1e6:.0f}-{max(xs) / 1e6:.0f})")
                if t > 1:
                    effs.append(f"{100 * med / (t * base):.0f}%")
            print(f"| {b} | {m} | " + " | ".join(cells) + " | " + " | ".join(effs) + " |")
    print()

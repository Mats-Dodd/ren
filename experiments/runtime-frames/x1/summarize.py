#!/usr/bin/env python3
# Median and spread (min..max) over rounds of each variant's per-run median.
import re, sys, statistics as st
rows = {}
for line in open(sys.argv[1]):
    if not line.startswith("RUN"): continue
    v = re.search(r"variant=(\S+)", line).group(1)
    b = re.search(r"bench=(\S+)", line).group(1)
    ns = float(re.search(r" ns_per_op=([0-9.]+)", line).group(1))
    ok = "check=ok" in line
    rows.setdefault((b, v), []).append((ns, ok))
for (b, v), xs in sorted(rows.items()):
    ns = [x for x, _ in xs]
    print(f"{b:16s} {v:16s} n={len(ns)} median={st.median(ns):7.2f} min={min(ns):7.2f} max={max(ns):7.2f} ok={all(o for _, o in xs)}")

#!/usr/bin/env python3
# Medians and spread (min..max) over rounds.
import re, sys, statistics as st
park, bound, fp = {}, {}, {}
for line in open(sys.argv[1]):
    if not line.startswith("RUN"): continue
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    if "PARK" in line:
        for k in ("zone_B_per_task", "malloc_size_B_per_task", "footprint_B_per_task", "resident_B_per_task"):
            park.setdefault((kv["policy"], k), []).append(float(kv[k]))
        park.setdefault((kv["policy"], "ok"), []).append(kv["check"] == "ok")
    elif "BOUND" in line:
        bound.setdefault((kv["build"], kv["policy"]), []).append((float(kv["ns_per_call"]), kv["check"] == "ok"))
    elif "fastpath" in kv:
        m = re.search(r" ren +([0-9.]+)", line)
        fp.setdefault(kv["fastpath"], []).append((float(m.group(1)), line.rstrip().endswith("ok")))
def s(xs): return f"median={st.median(xs):8.2f} min={min(xs):8.2f} max={max(xs):8.2f}"
print("bytes per parked task, N=100000")
for (p, k), xs in sorted(park.items()):
    if k == "ok": print(f"  {p:10s} ok={all(xs)}"); continue
    print(f"  {p:10s} {k:24s} {s(xs)}")
print("chunk boundary, ns a call (register convention)")
for (b, p), xs in sorted(bound.items()):
    print(f"  {b:18s} {p:6s} {s([x for x, _ in xs])} ok={all(o for _, o in xs)}")
print("chunk boundary, prototype convention (fastpath.c `ren`, depth 1)")
for p, xs in sorted(fp.items()):
    print(f"  {p:6s} {s([x for x, _ in xs])} ok={all(o for _, o in xs)}")

#!/usr/bin/env python3
"""Part 2 (outbox) analysis. Ratios are per pass (same rep, same file), then
median [min-max] over passes. Latencies are medians over passes, in us.
    python3 -I outbox_cells.py sweep results/measure-A.txt          # 1 pass, workers 1-12
    python3 -I outbox_cells.py key results/measure-A.txt results/measure-B.txt
    python3 -I outbox_cells.py pub results/pub-outbox-X.txt"""
import sys, statistics as st
from collections import defaultdict
mode, paths = sys.argv[1], sys.argv[2:]
rows = defaultdict(dict); loads = []
for path in paths:
    for line in open(path):
        t = line.split()
        if len(t) < 2 or t[1] != "OR": continue
        r = dict(x.split("=", 1) for x in t if "=" in x)
        assert r["ok"] == "1", line
        if "load1" in r: loads.append(float(r["load1"]))
        k = (r["scheme"], int(r["wl"]), int(r["spin"]), int(r["workers"]), r.get("pub", "pass"))
        rows[k][path + r["rep"]] = r
if loads: print(f"load1: min {min(loads):.1f} median {st.median(loads):.1f} max {max(loads):.1f}")
def ratio(a, b, f="mdps"):
    A, B = rows.get(a, {}), rows.get(b, {})
    rs = [float(A[p][f]) / float(B[p][f]) for p in A if p in B]
    return (st.median(rs), min(rs), max(rs), len(rs)) if rs else None
def med(k, f, scale=1e-3):
    v = rows.get(k)
    return st.median(float(x[f]) for x in v.values()) * scale if v else float("nan")
def fr(x): return f"{x[0]:.2f}" if x and x[3] == 1 else (f"{x[0]:.2f} [{x[1]:.2f}-{x[2]:.2f}]" if x else "-")
S = ["credit", "credit_outbox", "credit_eager", "home"]
if mode == "sweep":
    WS = [1, 2, 4, 8, 12]
    for sp in (100, 1000):
        print(f"\n== spin {sp}: ratio to none (one pass); none in M/s")
        for wl in (1, 2, 3, 4):
            print(f"W{wl} none   " + " ".join(f"{med(('none',wl,sp,w,'pass'),'mdps',1):7.1f}" for w in WS))
            for s in S:
                print(f"   {s:14}" + " ".join(f"{fr(ratio((s,wl,sp,w,'pass'),('none',wl,sp,w,'pass'))):>7}" for w in WS))
            print(f"   outbox/credit " + " ".join(f"{fr(ratio(('credit_outbox',wl,sp,w,'pass'),('credit',wl,sp,w,'pass'))):>7}" for w in WS))
elif mode == "key":
    for sp in (100, 1000):
        for wl in (1, 2, 3, 4):
            for w in (8, 12):
                k = lambda s: (s, wl, sp, w, "pass")
                print(f"sp={sp:4} W{wl} w={w:2} none={med(k('none'),'mdps',1):6.1f}M/s n={len(rows[k('none')])}  "
                      + "  ".join(f"{s}={fr(ratio(k(s), k('none')))}" for s in S)
                      + f"  outbox/credit={fr(ratio(k('credit_outbox'), k('credit')))} eager/credit={fr(ratio(k('credit_eager'), k('credit')))}")
                print("      close p50/p99 us: " + "  ".join(f"{s}={med(k(s),'close_p50_ns'):.1f}/{med(k(s),'close_p99_ns'):.0f}" for s in S))
                print("      dlat  p50/p99 us: " + "  ".join(f"{s}={med(k(s),'dlat_p50_ns'):.1f}/{med(k(s),'dlat_p99_ns'):.0f}" for s in ["none"] + S))
                print("      ctrl/deliv, ops/pass: " + "  ".join(f"{s}={med(k(s),'ctrl_per_deliv',1):.2f},{med(k(s),'ops_per_pass',1):.1f}" for s in S))
elif mode == "pub":
    for wl in (1, 3):
        for sp in (100, 1000):
            base = ("none", wl, sp, 8, "pass")
            print(f"\n== W{wl} spin {sp} w=8: thr ratio to none/pass; dlat p50/p99 us; close p50 us")
            for s, p in (("none","pass"),("none","post"),("credit","pass"),("credit","op"),("credit_outbox","pass"),("credit_outbox","op"),("credit_eager","pass"),("credit_eager","post")):
                k = (s, wl, sp, 8, p)
                print(f"  {s:14} pub={p:4} thr={fr(ratio(k, base)):>18}  dlat={med(k,'dlat_p50_ns'):6.2f}/{med(k,'dlat_p99_ns'):6.1f}  close={med(k,'close_p50_ns'):5.1f}")

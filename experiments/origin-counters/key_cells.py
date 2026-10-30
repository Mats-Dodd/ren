#!/usr/bin/env python3
"""Key cells (8 and 12 workers) pooled over several measure files: median
ratio to `none` per pass, with [min-max] over passes.
    python3 -I key_cells.py results/measure-A.txt results/measure-B.txt"""
import sys, statistics as st
from collections import defaultdict
rows=defaultdict(dict)
for path in sys.argv[1:]:
    for line in open(path):
        t=line.split()
        if len(t)<2 or t[1]!="OR": continue
        r=dict(x.split("=",1) for x in t if "=" in x)
        if r["workers"] not in ("8","12"): continue
        rows[(r["scheme"],int(r["wl"]),int(r["spin"]),int(r["workers"]))][path+r["rep"]]=r
S=["atomic","vector","credit","credit_soft","home"]
for wl in (1,2,3,4):
  for sp in (0,100,1000):
    for w in (8,12):
      b=rows[("none",wl,sp,w)]
      cells=[]
      for s in S:
        a=rows[(s,wl,sp,w)]
        rs=[float(a[p]["mdps"])/float(b[p]["mdps"]) for p in a if p in b]
        cells.append(f"{s}={st.median(rs):.2f}[{min(rs):.2f}-{max(rs):.2f}]")
      nm=[float(x["mdps"]) for x in b.values()]
      print(f"W{wl} sp={sp:4} w={w:2} none={st.median(nm):5.1f}[{min(nm):.0f}-{max(nm):.0f}] n={len(nm)} "+" ".join(cells))

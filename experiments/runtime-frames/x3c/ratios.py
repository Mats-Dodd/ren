#!/usr/bin/env python3
# Per-round throughput ratios (each round runs every variant back to back, so
# a ratio within a round is steadier than a ratio of medians on a loaded box).
#   ratios.py raw.txt SCEN NUM DEN [NUM DEN ...]
import os, re, sys, statistics as st
FIELD = os.environ.get("FIELD", "req_per_s")  # FIELD=remote_req_per_s for the `at` comparison
rows = {}
for line in open(sys.argv[1]):
    if not line.startswith("RUN"): continue
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    name = kv["strategy"] + ("+" + kv["tuned"] if "tuned" in kv else "")
    rows[(kv["scen"], name, kv["round"])] = float(kv[FIELD])
sc = sys.argv[2]
args = sys.argv[3:]
for num, den in zip(args[::2], args[1::2]):
    rs = sorted({r for (s, n, r) in rows if s == sc and n == num} & {r for (s, n, r) in rows if s == sc and n == den})
    xs = [rows[(sc, num, r)] / rows[(sc, den, r)] for r in rs]
    print(f"{sc} {num}/{den}: median {st.median(xs):.2f} [{min(xs):.2f}..{max(xs):.2f}] per round: {' '.join(f'{x:.2f}' for x in xs)}")

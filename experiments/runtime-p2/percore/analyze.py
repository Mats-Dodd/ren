#!/usr/bin/env python3
"""percore: medians over reps and the PLAN.md predictions.
    python3 -I analyze.py results/measure-<ts>.txt
"""
import sys, statistics as st
from collections import defaultdict

rows = defaultdict(list)
bad = []
for line in open(sys.argv[1]):
    t = line.split()
    if len(t) < 2 or t[1] != "PC":
        continue
    r = dict(x.split("=", 1) for x in t if "=" in x)
    v = r["variant"] + ("_if4" if r.get("inflight", "1") == "4" else "")
    if r.get("ok") != "1":
        bad.append(line.strip()); continue
    rows[(v, r["get_pct"], r["dist"], int(r["workers"]))].append(r)

F = ["mops", "p50_ns", "p99_ns", "cpu_per_wall", "hops_per_req", "lock_parks_per_req", "idle_parks_per_req"]
med = {}
noisy = []
for k, rs in rows.items():
    med[k] = {f: st.median(float(r[f]) for r in rs) for f in F}
    ms = [float(r["mops"]) for r in rs]
    med[k]["min"], med[k]["max"], med[k]["n"] = min(ms), max(ms), len(ms)
    med[k]["load"] = max(float(r.get("load1", 0)) for r in rs)
    if (max(ms) - min(ms)) / med[k]["mops"] > 0.25:
        noisy.append(k)

V = ["ws_one", "ws_worker", "ws_keyed", "ws_sharded", "pc_spin", "pc_park", "pc_spin_if4", "pc_park_if4"]
WS = [1, 2, 4, 8, 12, 16]
def g(v, mix, d, w, f="mops"):
    return med.get((v, mix, d, w), {}).get(f, float("nan"))

print(f"failed-check lines: {len(bad)}")
for b in bad[:20]:
    print("  ", b[:200])
print(f"configs: {len(med)}  reps per config: {sorted(set(m['n'] for m in med.values()))}")
print(f"noisy configs (spread > 25% of median): {len(noisy)}")
for k in sorted(noisy):
    m = med[k]; print(f"  {k} med={m['mops']:.2f} min={m['min']:.2f} max={m['max']:.2f} maxload={m['load']}")

for d in ("uniform", "zipf"):
    for mix in ("95", "50", "5"):
        print(f"\n== Mops/s, dist={d} get%={mix}   (median of reps)")
        print("  variant      " + " ".join(f"{w:>7}" for w in WS))
        for v in V:
            print(f"  {v:12} " + " ".join(f"{g(v,mix,d,w):7.2f}" for w in WS))
        print("  ws_sharded/pc_spin " + " ".join(f"{g('ws_sharded',mix,d,w)/g('pc_spin',mix,d,w):7.2f}" for w in WS))
        print("  p50 ns  ws_sharded " + " ".join(f"{g('ws_sharded',mix,d,w,'p50_ns'):7.0f}" for w in WS))
        print("  p50 ns  pc_spin    " + " ".join(f"{g('pc_spin',mix,d,w,'p50_ns'):7.0f}" for w in WS))
        print("  p50 ns  pc_park    " + " ".join(f"{g('pc_park',mix,d,w,'p50_ns'):7.0f}" for w in WS))
        for v in ("ws_one", "ws_sharded", "pc_spin"):
            print(f"  p99 ns  {v:10} " + " ".join(f"{g(v,mix,d,w,'p99_ns'):7.0f}" for w in WS))
        for v in ("ws_one", "ws_sharded", "pc_spin", "pc_park"):
            print(f"  cpu/wall {v:9} " + " ".join(f"{g(v,mix,d,w,'cpu_per_wall'):7.2f}" for w in WS))

print("\n== P11: uniform/zipf at 16 workers, and (pc_spin/ws_sharded) zipf over uniform")
for mix in ("95", "50", "5"):
    s = " ".join(f"{v}={g(v,mix,'uniform',16)/g(v,mix,'zipf',16):.2f}" for v in ("ws_one", "ws_keyed", "ws_sharded", "pc_spin"))
    ru = g('pc_spin',mix,'uniform',16)/g('ws_sharded',mix,'uniform',16)
    rz = g('pc_spin',mix,'zipf',16)/g('ws_sharded',mix,'zipf',16)
    print(f"  get%={mix}: {s}  pc/ws_sh uniform={ru:.2f} zipf={rz:.2f} ratio={rz/ru:.2f}")

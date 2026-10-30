#!/usr/bin/env python3
"""origin-counters: medians over reps, ratios to `none`, close latency, fuel.
    python3 -I analyze.py results/measure-<ts>.txt [results/fuel-<ts>.txt]
Ratios are computed per rep (same pass) and then the median is taken, since
absolute numbers move +-40% with background load.
"""
import sys, statistics as st
from collections import defaultdict

def parse(path, tag="OR"):
    for line in open(path):
        t = line.split()
        if len(t) < 2 or t[1] != tag:
            continue
        r = dict(x.split("=", 1) for x in t if "=" in x)
        yield r

rows = defaultdict(dict)  # (scheme, wl, spin, N, W) -> {rep: r}
bad = []
for r in parse(sys.argv[1]):
    if r.get("ok") != "1":
        bad.append(r); continue
    k = (r["scheme"], int(r["wl"]), int(r["spin"]), int(r["N"]), int(r["workers"]))
    rows[k][r["rep"]] = r

S = ["none", "atomic", "vector", "credit", "credit_soft", "home"]
WS = [1, 2, 4, 8, 12, 16]
f = lambda r, x: float(r[x])

def med(k, field="mdps"):
    v = rows.get(k)
    return st.median(f(r, field) for r in v.values()) if v else float("nan")

def ratio(k, kb):
    a, b = rows.get(k, {}), rows.get(kb, {})
    rs = [f(a[p], "mdps") / f(b[p], "mdps") for p in a if p in b]
    return (st.median(rs), min(rs), max(rs)) if rs else (float("nan"),) * 3

print(f"failed lines: {len(bad)}")
for b in bad[:10]:
    print("  ", {k: b.get(k) for k in ("scheme", "wl", "spin", "N", "workers", "late", "premature", "bug", "crashed")})
reps = sorted({p for v in rows.values() for p in v})
print(f"configs: {len(rows)}  reps: {reps}")
loads = [float(r.get("load1", 0)) for v in rows.values() for r in v.values()]
if loads:
    print(f"load1 during runs: min {min(loads):.1f} median {st.median(loads):.1f} max {max(loads):.1f}")

def table(wl, N, spin, base="none"):
    print(f"\n== W{wl} N={N} spin={spin}: deliveries/s ratio to `{base}` (median of per-rep ratios); `none` row is M/s")
    print("  scheme       " + " ".join(f"{w:>6}" for w in WS))
    print("  none M/s     " + " ".join(f"{med(('none', wl, spin, N, w)):6.1f}" for w in WS))
    for s in S[1:]:
        print(f"  {s:12} " + " ".join(f"{ratio((s, wl, spin, N, w), (base, wl, spin, N, w))[0]:6.2f}" for w in WS))

for wl, N in ((1, 4096), (2, 4096), (3, 4096), (4, 4)):
    for spin in (0, 100, 1000):
        table(wl, N, spin)
for wl, N in ((4, 4),):
    for spin in (0, 100, 1000):
        print(f"\n== W{wl} N={N} spin={spin}: ratio to `credit`")
        print("  scheme       " + " ".join(f"{w:>6}" for w in WS))
        for s in ("atomic", "vector", "credit_soft", "home", "none"):
            print(f"  {s:12} " + " ".join(f"{ratio((s, wl, spin, N, w), ('credit', wl, spin, N, w))[0]:6.2f}" for w in WS))

print("\n== control messages and atomics per delivery (16 workers, spin 100)")
for wl, N in ((1, 4096), (2, 4096), (3, 4096), (4, 4)):
    print(f"  W{wl}: " + "  ".join(
        f"{s}={med((s, wl, 100, N, 16), 'ctrl_per_deliv'):.2f}/{med((s, wl, 100, N, 16), 'atom_per_deliv'):.2f}"
        for s in S[1:]))

print("\n== close latency, us: p50 / p99 (median over reps)")
for wl, N in ((1, 4096), (2, 4096), (3, 4096), (4, 4)):
    for spin in (0, 100, 1000):
        for w in (4, 8, 12, 16):
            if ("credit", wl, spin, N, w) not in rows:
                continue
            cells = []
            for s in S[1:]:
                k = (s, wl, spin, N, w)
                cells.append(f"{s}={med(k, 'close_p50_ns')/1e3:.1f}/{med(k, 'close_p99_ns')/1e3:.0f}")
            print(f"  W{wl} spin={spin:4} w={w:2}: " + "  ".join(cells))

print("\n== side: admission N=64 (W1, W2) and W4 N=16, spin 100: M/s, ratio to credit, lifetime p50 us")
for wl, N in ((1, 64), (2, 64), (4, 16)):
    print(f"  W{wl} N={N}")
    for s in S:
        print(f"    {s:12} M/s " + " ".join(f"{med((s, wl, 100, N, w)):6.1f}" for w in WS)
              + "  | /credit " + " ".join(f"{ratio((s, wl, 100, N, w), ('credit', wl, 100, N, w))[0]:5.2f}" for w in WS)
              + "  | life_p50 " + " ".join(f"{med((s, wl, 100, N, w), 'life_p50_ns')/1e3:6.0f}" for w in WS))
    # Little's law check: N * ops/origin / life_p50 vs measured
    size = {1: 2, 2: 17, 4: 5461}[wl]
    for s in ("atomic", "credit", "home"):
        pred = " ".join(f"{N * size / (med((s, wl, 100, N, w), 'life_p50_ns') / 1e3):6.1f}" for w in WS)
        print(f"    Little {s:6} N*size/life_p50 M/s {pred}")

print("\n== spread: (max-min)/median of mdps over reps, configs > 25%")
noisy = 0
for k, v in sorted(rows.items()):
    ms = [f(r, "mdps") for r in v.values()]
    if len(ms) > 1 and (max(ms) - min(ms)) / st.median(ms) > 0.25:
        noisy += 1
        if noisy <= 25:
            print(f"  {k} " + " ".join(f"{m:.1f}" for m in ms))
print(f"  noisy configs: {noisy} of {len(rows)}")
print("== spread of ratios to none over reps (max-min), median across configs, by scheme")
for s in S[1:]:
    sp = []
    for k in rows:
        if k[0] != s:
            continue
        kb = ("none",) + k[1:]
        m, lo, hi = ratio(k, kb)
        if m == m and m > 0:
            sp.append((hi - lo) / m)
    if sp:
        print(f"  {s:12} median {st.median(sp)*100:.0f}%  p90 {sorted(sp)[int(0.9*len(sp))]*100:.0f}%")

if len(sys.argv) > 2:
    print("\n== fuel")
    fr = defaultdict(list)
    for r in parse(sys.argv[2]):
        fr[(r["scheme"], r["wl"], r["workers"])].append(r)
    for k in sorted(fr):
        rs = fr[k]
        print(f"  {k[0]:12} W{k[1]} w={k[2]:>2} F={rs[0]['F']}: "
              + " | ".join(f"noticed={r['fuel_noticed']} over min/mean/max={r['over_min']}/{r['over_mean']}/{r['over_max']}"
                           f" panics={r['panic_origins']} pre-panic={r['posts_before_panic_min']}-{r['posts_before_panic_max']}"
                           f" total={r['posts_total_min']}-{r['posts_total_max']} ok={r['ok']}" for r in rs))

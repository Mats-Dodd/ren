#!/usr/bin/env python3
"""K1b: check the PLAN.md predictions against results/*.txt.
    python3 -I analyze.py results/   (uses the newest file of each section)
"""
import glob, os, sys, statistics as st

d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "results")

def newest(sec):
    fs = sorted(glob.glob(os.path.join(d, f"{sec}-*.txt")))
    return fs[-1] if fs else None

def parse(path, tag):
    rows = []
    if not path:
        return rows
    for line in open(path):
        t = line.split()
        if not t or t[0] != tag:
            continue
        rows.append(dict(x.split("=", 1) for x in t[1:] if "=" in x))
    return rows

thr = parse(newest("throughput"), "k1b")
ext = parse(newest("extras"), "k1b")
sim = parse(newest("sim"), "k1b_sim")
mem = parse(newest("mem"), "k1b_mem")
parts_lines = [l.strip() for l in open(newest("parts"))] if newest("parts") else []

def T(rows, **kw):
    out = [r for r in rows if all(r.get(k) == str(v) for k, v in kw.items())]
    return out

def one(rows, **kw):
    r = T(rows, **kw)
    if len(r) != 1:
        return None
    return r[0]

def m(r):
    return float(r["mops_median"]) if r else float("nan")

def spread(r):
    a, lo, hi = float(r["mops_median"]), float(r["mops_min"]), float(r["mops_max"])
    return (hi - lo) / a if a else 0

base = dict(k="5", lock="spin")
print("== correctness")
for name, rows in (("throughput", thr), ("extras", ext)):
    bad = [r for r in rows if r.get("ok") != "1"]
    print(f"{name}: lines={len(rows)} not_ok={len(bad)}")
print("sim lines", len(sim), "not_ok", sum(r.get("ok") != "1" for r in sim))
for l in parts_lines:
    if l.startswith("k1b_parts") or l.startswith("k1b_sim_agree"):
        print(l)
sa = [l for l in open(newest("sim"))] if newest("sim") else []
print([l.strip() for l in sa if l.startswith("k1b_sim_agree")])

print("\n== noisy rows (spread (max-min)/median > 0.25), throughput+extras")
noisy = [r for r in thr + ext if spread(r) > 0.25]
print(f"{len(noisy)} of {len(thr)+len(ext)}")
for r in noisy[:400]:
    print(f"  {r['lang']} {r['variant']} k={r['k']} {r['lock']} {r['dist']} max={r['max']} u={r['universe']} p={r['parts']} w={r['workers']}"
          f" med={r['mops_median']} min={r['mops_min']} max={r['mops_max']} load={r.get('load1')}")

def W(v, dist, mx, u, w, lang="c", rows=thr, **kw):
    b = dict(base, k=("5" if v == "b_sampled" else "0"))
    return one(rows, lang=lang, variant=v, dist=dist, max=mx, universe=u, workers=w, **{**b, **kw})

print("\n== P1: one worker, C, spin, u=0.9: b/a and c/a; ns per at of b")
for mx in ("10000", "50000"):
    for dist in ("zipf99", "zipf70", "uniform", "scan"):
        a, b, c = (W(v, dist, mx, "0.9", "1") for v in ("a_lru", "b_sampled", "c_clock"))
        print(f"  max={mx} {dist:8} a={m(a):7.1f} b={m(b):7.1f} c={m(c):7.1f} Mops  b/a={m(b)/m(a):.2f} c/a={m(c)/m(a):.2f}"
              f"  a_ns={1000/m(a):.1f} b_ns={1000/m(b):.1f}")

print("\n== P2/P3: scaling 16w/1w, and b16/a16 (u=0.9, C and Rust)")
for lang in ("c", "rust"):
    for mx in ("10000", "50000"):
        for dist in ("uniform", "zipf70", "zipf99", "scan"):
            s = {}
            for v in ("a_lru", "b_sampled", "c_clock"):
                s[v] = [m(W(v, dist, mx, "0.9", w, lang)) for w in ("1", "2", "4", "8", "12", "16")]
            print(f"  {lang:4} max={mx} {dist:8} " + " ".join(
                f"{v[0]}:[{' '.join(f'{x:.0f}' for x in s[v])}] x{s[v][-1]/s[v][0]:.2f}" for v in s)
                + f"  b16/a16={s['b_sampled'][-1]/s['a_lru'][-1]:.1f} c16/a16={s['c_clock'][-1]/s['a_lru'][-1]:.1f}")

print("\n== P4: p50/p99 ns at 16 workers, u=0.9, C")
for mx in ("10000", "50000"):
    for dist in ("uniform", "zipf99"):
        out = []
        for v in ("a_lru", "b_sampled", "c_clock"):
            r = W(v, dist, mx, "0.9", "16")
            out.append(f"{v[0]} p50={r['at_p50_ns']} p99={r['at_p99_ns']}")
        print(f"  max={mx} {dist:8} " + "  ".join(out))

print("\n== P5: c/b on hit path (u=0.9, all lang/max/dist/workers)")
rat = []
for r in T(thr, variant="b_sampled", universe="0.9"):
    if r["dist"] == "scan":
        continue
    c = W("c_clock", r["dist"], r["max"], "0.9", r["workers"], r["lang"])
    rat.append((m(c) / m(r), r))
inside = sum(0.9 <= x <= 1.1 for x, _ in rat)
print(f"  (scan excluded: it misses at u=0.9)\n  within 10%: {inside}/{len(rat)}  median c/b={st.median(x for x,_ in rat):.2f} min={min(x for x,_ in rat):.2f} max={max(x for x,_ in rat):.2f}")

print("\n== P6: rust/c on hit path (u=0.9)")
rat = []
for r in T(thr, lang="c", universe="0.9"):
    q = W(r["variant"], r["dist"], r["max"], "0.9", r["workers"], "rust")
    rat.append((m(q) / m(r), r))
inside = sum(0.85 <= x <= 1.15 for x, _ in rat)
print(f"  within 15%: {inside}/{len(rat)}  median={st.median(x for x,_ in rat):.2f} min={min(x for x,_ in rat):.2f} max={max(x for x,_ in rat):.2f}")
for v in ("a_lru", "b_sampled", "c_clock"):
    xs = [x for x, r in rat if r["variant"] == v]
    print(f"   {v}: median={st.median(xs):.2f} min={min(xs):.2f} max={max(xs):.2f} within15={sum(0.85<=x<=1.15 for x in xs)}/{len(xs)}")
worst = sorted(rat, key=lambda t: t[0])[:6]
for x, r in worst:
    print(f"   low {x:.2f} {r['variant']} {r['dist']} max={r['max']} w={r['workers']}")

print("\n== P7: os lock vs spin (extras, u=0.9, max 10000)")
for lang in ("c", "rust"):
    for dist in ("zipf99", "uniform"):
        for v in ("a_lru", "b_sampled", "c_clock"):
            row = []
            for w in ("1", "8", "16"):
                o = one(ext, lang=lang, variant=v, lock="os", dist=dist, max="10000", universe="0.9", workers=w)
                s = W(v, dist, "10000", "0.9", w, lang)
                row.append(f"w{w}: os={m(o):.0f} spin={m(s):.0f} ({m(o)/m(s):.2f})")
            print(f"  {lang:4} {dist:8} {v:9} " + "  ".join(row))

print("\n== P8: parts on hit path (extras, C, max 10000, u=0.9)")
for dist in ("zipf99", "uniform"):
    for v in ("a_lru", "b_sampled"):
        for w in ("8", "16"):
            xs = []
            for p in ("1", "8", "64"):
                r = one(ext, lang="c", variant=v, lock="spin", dist=dist, max="10000", universe="0.9", parts=p, workers=w)
                xs.append(m(r))
            print(f"  {dist:8} {v:9} w={w}: parts1={xs[0]:.0f} parts8={xs[1]:.0f} parts64={xs[2]:.0f}  64/1={xs[2]/xs[0]:.2f}")

print("\n== P9/P10/P11: miss regime u=2 (C)")
for mx in ("10000", "50000"):
    for dist in ("uniform", "scan", "zipf99", "zipf70"):
        s = {}
        for v in ("a_lru", "b_sampled", "c_clock"):
            s[v] = [W(v, dist, mx, "2", w) for w in ("1", "2", "4", "8", "12", "16")]
        line = " ".join(f"{v[0]}:[{' '.join(f'{m(x):.0f}' for x in s[v])}]" for v in s)
        rb = [float(x["retries"]) / max(1.0, float(x["misses"])) for x in s["b_sampled"]]
        rc = [float(x["retries"]) / max(1.0, float(x["misses"])) for x in s["c_clock"]]
        rr = rb + rc
        print(f"  max={mx} {dist:8} {line}  a1/b1={m(s['a_lru'][0])/m(s['b_sampled'][0]):.2f}"
              f" b8/a8={m(s['b_sampled'][3])/m(s['a_lru'][3]):.2f} b16/a16={m(s['b_sampled'][5])/m(s['a_lru'][5]):.2f}"
              f" c16/b16={m(s['c_clock'][5])/m(s['b_sampled'][5]):.2f} retries/miss b=[{' '.join(f'{x:.2f}' for x in rb)}] c=[{' '.join(f'{x:.2f}' for x in rc)}]")
print("  k sweep (extras, b_sampled, u=2, max 10000; k=5 from throughput)")
for dist in ("zipf99", "zipf70", "uniform", "scan"):
    row = []
    for w in ("1", "8", "16"):
        k3 = one(ext, lang="c", variant="b_sampled", k="3", dist=dist, max="10000", universe="2", workers=w)
        k10 = one(ext, lang="c", variant="b_sampled", k="10", dist=dist, max="10000", universe="2", workers=w)
        k5 = W("b_sampled", dist, "10000", "2", w)
        row.append(f"w{w}: k3={m(k3):.0f} k5={m(k5):.0f} k10={m(k10):.0f}")
    print(f"   {dist:8} " + "  ".join(row))

print("\n== P12-P15: simulator hit rates (C), points vs lru")
for r in T(sim, lang="c"):
    lru = float(r["hit_lru"])
    diffs = " ".join(f"{p}={100*(float(r['hit_'+p])-lru):+.2f}" for p in ("plru", "s3", "s5", "s10", "clock"))
    U = float(r["universe"])
    print(f"  {r['dist']:8} max={r['max']:5} U={r['universe']:4} lru={100*lru:6.2f}% {diffs}"
          + (f"  max/U={100/U:.2f}%" if r["dist"] == "uniform" else ""))

print("\n== P17-P19: memory")
for r in mem:
    print("  " + " ".join(f"{k}={r[k]}" for k in r))

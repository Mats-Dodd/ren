#!/usr/bin/env python3
"""Summarise a spin-sweep results file.

    python3 analyze.py results/full-<stamp>.txt [--x 0.05]

X is the CPU allowance: a budget is admissible at a config if its waste
(util - work_util, a fraction of all workers' capacity) is at most X above
budget 0's waste at the same config. Idle-ish loads are gap >= 20 us.
With several reps, each metric is the median over reps.
"""
import statistics
import sys
from collections import defaultdict

BUDGETS = ["0", "100", "500", "1000", "2000", "5000", "10000", "20000", "50000", "inf"]
METRICS = ["hop_p50_ns", "hop_p99_ns", "hop_p999_ns", "reach_p99_ns", "hops_per_s", "cpu_ns_per_hop",
           "util", "work_util", "waste", "spin_hit", "parks_per_hop", "wakes_per_hop"]


def parse(path):
    rows = defaultdict(list)
    fails = 0
    for line in open(path):
        if not line.startswith("SPIN "):
            continue
        if " FAIL" in line:
            fails += 1
            continue
        kv = dict(t.split("=", 1) for t in line.split()[1:] if "=" in t)
        key = (kv["policy"], kv["reply_spin_ns"], kv["idle_spin_ns"], int(float(kv["service_ns"])),
               int(float(kv["gap_ns"])), int(kv["workers"]))
        rows[key].append({m: float(kv[m]) for m in METRICS})
    med = {k: {m: statistics.median(r[m] for r in v) for m in METRICS} for k, v in rows.items()}
    return med, fails


def us(ns):
    return f"{ns / 1000:.1f}"


def main():
    args = sys.argv[1:]
    x = 0.05
    if "--x" in args:
        i = args.index("--x")
        x = float(args[i + 1])
        del args[i:i + 2]
    if not args:
        print(__doc__)
        sys.exit(2)
    d, fails = parse(args[0])
    print(f"configs={len(d)} failed_lines={fails} X={x}")
    services = sorted({k[3] for k in d})
    gaps = sorted({k[4] for k in d})
    workers = sorted({k[5] for k in d})

    def fixed(b, s, g, n, reply=None, idle=None):
        return d.get(("fixed", reply or b, idle or b, s, g, n))

    print("\n## Fixed sweep: hop p99 in us (waste) per budget, and the best admissible budget")
    best = {}
    for s in services:
        for n in workers:
            print(f"\nservice={s}ns workers={n}")
            print("gap_us  " + " ".join(f"{b:>13}" for b in BUDGETS) + "   best(p99 us, waste)")
            for g in gaps:
                base = fixed("0", s, g, n)
                cells, cands = [], []
                for b in BUDGETS:
                    r = fixed(b, s, g, n)
                    if not r:
                        cells.append(f"{'-':>13}")
                        continue
                    cells.append(f"{us(r['hop_p99_ns']):>6}({r['waste']:.2f})")
                    if base is None or r["waste"] <= base["waste"] + x:
                        cands.append((r["hop_p99_ns"], b, r))
                pick = min(cands, key=lambda t: t[0]) if cands else None
                if pick:
                    best[(s, g, n)] = pick
                tail = f"  {pick[1]} ({us(pick[0])}, {pick[2]['waste']:.2f})" if pick else ""
                print(f"{g / 1000:>6g}  " + " ".join(cells) + tail)

    print("\n## Is there one budget? For each budget: configs where it is within 10% of the best admissible p99")
    for b in BUDGETS:
        ok = tot = 0
        idle_ok = idle_tot = 0
        for (s, g, n), (p99, _, _) in best.items():
            r = fixed(b, s, g, n)
            base = fixed("0", s, g, n)
            if not r:
                continue
            good = r["hop_p99_ns"] <= 1.1 * p99 and (base is None or r["waste"] <= base["waste"] + x)
            tot += 1
            ok += good
            if g >= 20000:
                idle_tot += 1
                idle_ok += good
        print(f"budget={b:>6}: {ok}/{tot} all, {idle_ok}/{idle_tot} idle-ish")

    print("\n## Which wait the spin pays on (service=1000ns, workers=8): p99 us (waste)")
    print("gap_us   budget   both          reply-only    idle-only")
    for g in gaps:
        for b in BUDGETS[:-1]:
            both = fixed(b, 1000, g, 8)
            ro = d.get(("fixed", b, "0", 1000, g, 8))
            io = d.get(("fixed", "0", b, 1000, g, 8))
            f = lambda r: f"{us(r['hop_p99_ns']):>6}({r['waste']:.2f})" if r else f"{'-':>12}"
            print(f"{g / 1000:>6g}  {b:>7}  {f(both)}  {f(ro)}  {f(io)}")

    print("\n## Adaptive rules against the best admissible fixed budget")
    pols = sorted({(k[0], k[1]) for k in d if k[0] != "fixed"})
    for p, cap in pols:
        ok = tot = 0
        worst = []
        for (s, g, n), (p99, b, rb) in best.items():
            r = d.get((p, cap, cap, s, g, n))
            base = fixed("0", s, g, n)
            if not r:
                continue
            tot += 1
            good = r["hop_p99_ns"] <= 1.1 * p99 and (base is None or r["waste"] <= base["waste"] + x)
            ok += good
            if not good:
                worst.append(f"s={s} g={g} n={n}: p99 {us(r['hop_p99_ns'])} vs {us(p99)}@{b}, "
                             f"waste {r['waste']:.2f} vs base {base['waste'] if base else float('nan'):.2f}")
        print(f"{p} cap={cap}: {ok}/{tot} within 10% of best p99 and within X")
        for w in worst[:8]:
            print("   miss " + w)


if __name__ == "__main__":
    main()

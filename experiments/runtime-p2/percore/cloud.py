#!/usr/bin/env python3
"""percore cloud helper (used by measure-cloud.sh; run with python3 -I).

  cloud.py stats  FILE CFG TRY GATE   -> one summary line for that try of a config
  cloud.py ws     FILE LOAD           -> work_stealing's median mops in throughput mode
  cloud.py report FILE                -> the extension tables and the checks

Rep lines look like  "cfg=NAME try=T rep=R PC ... key=value ... ok=1".
"""
import sys, statistics as st
from collections import defaultdict

HEAD = ["mops", "p50_ns", "p99_ns", "p999_ns", "light_p50_ns", "light_p99_ns", "light_p999_ns",
        "heavy_p50_ns", "heavy_p99_ns", "heavy_p999_ns", "cpu_per_wall", "work_us_mean", "lag_ms"]


def parse(line):
    r = {}
    for t in line.split():
        if "=" in t:
            k, v = t.split("=", 1)
            r.setdefault(k, v)
    return r


def reps(path, cfg=None, tr=None):
    out = []
    for line in open(path):
        if not line.startswith("cfg="):
            continue
        r = parse(line)
        if " PC " not in line and r.get("crashed") != "1":
            continue
        if cfg is not None and r["cfg"] != cfg:
            continue
        if tr is not None and r["try"] != str(tr):
            continue
        out.append(r)
    return out


def num(r, k):
    try:
        return float(r.get(k, "nan"))
    except ValueError:
        return float("nan")


def spread(xs):
    m = st.median(xs)
    return (max(xs) - min(xs)) / m if m else 0.0


def stats(path, cfg, tr, gate):
    rs = reps(path, cfg, tr)
    ok = all(r.get("ok") == "1" for r in rs) and len(rs) > 0
    if not ok or not rs:
        print(f"n={len(rs)} ok=0 spread=inf")
        return
    g = [num(r, gate) for r in rs]
    parts = [f"n={len(rs)}", "ok=1", f"gate={gate}", f"median={st.median(g):.6g}", f"min={min(g):.6g}",
             f"max={max(g):.6g}", f"spread={spread(g):.4f}"]
    for k in HEAD:
        xs = [num(r, k) for r in rs]
        if any(x != x for x in xs):
            continue
        parts.append(f"med_{k}={st.median(xs):.6g}")
        if k in ("mops", "light_p99_ns", "light_p999_ns", "p99_ns", "p999_ns", "heavy_p99_ns"):
            parts.append(f"spread_{k}={spread(xs):.4f}")
    parts.append(f"sustained_all={int(all(r.get('sustained') == '1' for r in rs))}")
    ks = {r.get("keyset_sum") for r in rs}
    ws = {r.get("work_sum") for r in rs}
    parts.append(f"keyset_sum={'|'.join(sorted(ks))}")
    parts.append(f"work_sum={'|'.join(sorted(ws))}")
    print(" ".join(parts))


def cfgs(path):
    c = {}
    for line in open(path):
        if line.startswith("CFG "):
            r = parse(line)
            c[r["name"]] = r
    return c


def ws_mops(path, load):
    c = cfgs(path).get(f"x_{load}_thr_ws")
    print(c["median"] if c and c.get("ok") == "1" else "0")


def report(path):
    c = cfgs(path)
    print(f"configs: {len(c)}   NOISY: {sum(1 for r in c.values() if r.get('noisy') == '1')}"
          f"   failed (ok=0): {sum(1 for r in c.values() if r.get('ok') != '1')}")
    for n, r in sorted(c.items()):
        if r.get("noisy") == "1" or r.get("ok") != "1":
            print(f"  {n}: ok={r.get('ok')} noisy={r.get('noisy')} spread={r.get('spread')} gate={r.get('gate')}")
    # keyset / work_sum agreement across runtimes at one load
    groups = defaultdict(set)
    wgroups = defaultdict(set)
    for n, r in c.items():
        if n.startswith("x_"):
            load = n.split("_")[1]
            groups[load].add(r.get("keyset_sum"))
            wgroups[load].add(r.get("work_sum"))
    for load in sorted(groups):
        print(f"  ext {load}: keyset_sum values {len(groups[load])} (want 1), work_sum values {len(wgroups[load])} (want 1)")
    RT = ["ws", "pc", "pas_3p1", "pas_2p2", "pas_4p4"]
    def g(n, k):
        r = c.get(n)
        if not r:
            return float("nan")
        v = r.get(k)
        return float(v) if v not in (None, "") else float("nan")
    def us(x):
        return f"{x / 1e3:9.1f}" if x == x else "      nan"
    for load in ("even", "skewed"):
        if not any(n.startswith(f"x_{load}_") for n in c):
            continue
        print(f"\n== extension, {load} load: throughput mode (Mreq/s, median of reps; * = NOISY)")
        for rt in RT:
            n = f"x_{load}_thr_{rt}"
            if n not in c:
                continue
            m = g(n, "median")
            flag = "*" if c.get(n, {}).get("noisy") == "1" else " "
            print(f"  {rt:8} {m:8.3f}{flag}  vs ws {m / g(f'x_{load}_thr_ws', 'median'):5.2f}x  cpu/wall {g(n, 'med_cpu_per_wall'):5.2f}")
        for frac in ("25", "50", "75"):
            if not any(f"x_{load}_lat{frac}_{rt}" in c for rt in RT):
                continue
            print(f"\n== {load} load at {frac}% of ws throughput (latency in us, median of reps; * = NOISY, ! = not sustained)")
            print("  runtime   light_p50 light_p99 light_p999 heavy_p50 heavy_p99  all_p99  all_p999  achieved_Mreq/s")
            for rt in RT:
                n = f"x_{load}_lat{frac}_{rt}"
                if n not in c:
                    continue
                flag = ("*" if c[n].get("noisy") == "1" else " ") + ("!" if c[n].get("sustained_all") != "1" else " ")
                print(f"  {rt:8}{flag}{us(g(n, 'med_light_p50_ns'))}{us(g(n, 'med_light_p99_ns'))} {us(g(n, 'med_light_p999_ns'))}"
                      f"{us(g(n, 'med_heavy_p50_ns'))}{us(g(n, 'med_heavy_p99_ns'))}{us(g(n, 'med_p99_ns'))}{us(g(n, 'med_p999_ns'))}"
                      f"   {g(n, 'med_mops'):.3f}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "stats":
        stats(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "ws":
        ws_mops(sys.argv[2], sys.argv[3])
    elif cmd == "report":
        report(sys.argv[2])
    else:
        sys.exit("usage: cloud.py stats|ws|report ...")

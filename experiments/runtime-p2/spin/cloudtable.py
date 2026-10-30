#!/usr/bin/env python3
"""Markdown table of every CFG line in a measure-cloud summary file or an oversub file.

    python3 cloudtable.py results/cloud/summary-<stamp>.txt

Each cell is median [min..max] spread over the kept try (7 reps); µs unless noted.
"""
import re
import sys

ORDER = ["policy", "budget-ns", "reply-spin-ns", "idle-spin-ns", "service-ns", "gap-ns", "workers", "pin"]


def parse_args(a):
    t = a.split()
    d = {}
    for i in range(0, len(t) - 1, 2):
        d[t[i].lstrip("-")] = t[i + 1]
    return d


def fmt(v, m):
    v = float(v)
    if m.endswith("_ns"):
        return f"{v/1000:.1f}"
    if m == "hops_per_s":
        return f"{v/1000:.0f}k"
    if m == "cpu_ns_per_hop":
        return f"{v/1000:.2f}"
    return f"{v:.2f}"


def cell(kv, m):
    return f"{fmt(kv[m+'_med'], m)} [{fmt(kv[m+'_min'], m)}..{fmt(kv[m+'_max'], m)}] {float(kv[m+'_spread'])*100:.0f}%"


def rows(path):
    out = []
    for line in open(path):
        if not line.startswith("CFG"):
            continue
        args = line.split('args="')[1].rstrip().rstrip('"')
        kv = dict(t.split("=", 1) for t in line.split('args="')[0].split()[1:] if "=" in t)
        kv["status"] = re.search(r"status=(\w+)", line).group(1)
        out.append((parse_args(args), kv))
    return out


def key(r):
    a = r[0]
    def num(x):
        return float("inf") if x == "inf" else float(x)
    pol = {"fixed": 0, "ema": 1, "pred": 2, "go": 3}[a["policy"]]
    sec = 0 if "budget-ns" in a else 1
    b = num(a.get("budget-ns", a.get("reply-spin-ns", "0")))
    i = num(a.get("idle-spin-ns", "0")) if sec else 0
    return (sec, pol, int(a["workers"]), float(a["service-ns"]), float(a["gap-ns"]), b, i, a.get("pin", ""))


def main():
    path = sys.argv[1]
    rs = sorted(rows(path), key=key)
    M = ["hop_p50_ns", "hop_p99_ns", "hop_p999_ns", "cpu_ns_per_hop", "hops_per_s", "waste"]
    pin = any("pin" in a for a, _ in rs)
    hdr = ["policy", "reply/idle spin", "svc µs", "gap µs", "W"] + (["pin"] if pin else []) + \
        ["hop p50 µs", "hop p99 µs", "hop p99.9 µs", "CPU µs/hop", "hops/s", "waste", "load1 start→end", "try", "status"]
    print("| " + " | ".join(hdr) + " |")
    print("|" + "---|" * len(hdr))
    for a, kv in rs:
        if "budget-ns" in a:
            sp = a["budget-ns"]
        else:
            sp = f"{a['reply-spin-ns']}/{a['idle-spin-ns']}"
        if a["policy"] != "fixed":
            sp = "cap " + sp
        c = [a["policy"], sp, f"{float(a['service-ns'])/1000:g}", f"{float(a['gap-ns'])/1000:g}", a["workers"]]
        if pin:
            c.append(a.get("pin", ""))
        c += [cell(kv, m) for m in M]
        c += [f"{kv['load1_start']}→{kv['load1_end']}", kv["try"], "**NOISY**" if kv["status"] == "NOISY" else kv["status"]]
        print("| " + " | ".join(c) + " |")


if __name__ == "__main__":
    main()

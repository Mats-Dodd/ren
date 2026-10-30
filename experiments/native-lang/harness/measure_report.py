#!/usr/bin/env python3
"""measure_report.py: markdown tables from the results/cloud/*.jsonl files that
measure_b.py writes (machine "cloud"). Prints to stdout; MEASURE.md embeds it.

  measure_report.py [section ...]   sections: w1 w2 w3 pinned w4 w5 w5pinned e1 e1pinned build   (default: all)
"""
import json, os, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
R = os.path.join(ROOT, "results", "cloud")
LANGS = [("c-release", "C"), ("rust-release", "Rust (std)"), ("zig-release-fast", "Zig (ReleaseFast)")]


def load(tag):
    p = os.path.join(R, f"{tag}.jsonl")
    if not os.path.exists(p):
        return []
    return [json.loads(l) for l in open(p) if l.strip()]


def fmt(x, nd=0):
    if x is None:
        return "-"
    if nd == 0:
        return f"{x:,.0f}"
    return f"{x:,.{nd}f}"


def cell(o, k, nd=0, scale=1.0):
    s = o["final"]["summary"].get(k)
    if not s:
        return "-"
    flag = " **NOISY**" if (s.get("spread") or 0) > 0.10 else ""
    return (f"{fmt(s['median'] * scale, nd)} [{fmt(s['min'] * scale, nd)}, {fmt(s['max'] * scale, nd)}] "
            f"{(s['spread'] or 0) * 100:.1f}%{flag}")


def la(o):
    f = o["final"]
    return f"{f['loadavg_start'][0]}→{f['loadavg_end'][0]}"


def runs_of(o):
    f = o["final"]
    n = max((v.get("n", 0) for v in f["summary"].values()), default=0)
    return f"{n}×{o['attempts']}" + (f" ({f['failed_runs']} failed)" if f["failed_runs"] else "")


def table_run(wl, keys, nd=0, title=""):
    print(f"\n| lang | driver | workers | " + " | ".join(f"{k} median [min, max] spread" for k in keys)
          + " | runs×attempts | loadavg 1-min start→end |")
    print("|---|---|---|" + "---|" * len(keys) + "---|---|")
    for d in ("epoll", "uring"):
        for w in (1, 4, 8):
            for tag, name in LANGS:
                for o in load(tag):
                    if o.get("workload") == wl and o.get("driver") == d and o.get("workers") == w:
                        wl_ = f"{w}" + (" (oversubscribed)" if w > 4 else "")
                        print(f"| {name} | {d} | {wl_} | " + " | ".join(cell(o, k, nd) for k in keys)
                              + f" | {runs_of(o)} | {la(o)} |")


def generic(tags, keys, nd=0, label="config", namefn=None):
    print(f"\n| {label} | " + " | ".join(f"{k} median [min, max] spread" for k in keys)
          + " | runs×attempts | loadavg 1-min start→end |")
    print("|---|" + "---|" * len(keys) + "---|---|")
    for tag in tags:
        for o in load(tag):
            nm = namefn(tag, o) if namefn else f"{tag} {o['workload']}"
            print(f"| {nm} | " + " | ".join(cell(o, k, nd) for k in keys) + f" | {runs_of(o)} | {la(o)} |")


def main():
    secs = sys.argv[1:] or ["w1", "w2", "w3", "pinned", "w4", "w5", "w5pinned", "e1", "e1pinned", "build"]
    for s in secs:
        print(f"\n<!-- section {s} -->")
        if s == "w1":
            table_run("w1", ["tasks_per_s"])
        elif s == "w2":
            table_run("w2", ["ns_per_switch"], 2)
        elif s == "w3":
            table_run("w3", ["p50_ns", "p99_ns"])
        elif s == "pinned":
            generic([f"{t}-pinned" for t, _ in LANGS] + [f"{t}-w1big" for t, _ in LANGS],
                    ["tasks_per_s", "ns_per_switch", "p50_ns", "p99_ns"], 0,
                    namefn=lambda t, o: f"{dict(LANGS)[t.rsplit('-', 1)[0]]}: {o['workload']}"
                    + ("" if "pinned" in t else " (unpinned)"))
        elif s == "w4":
            generic([f"{t}-w4" for t, _ in LANGS] + [f"{t}-w4pinned" for t, _ in LANGS], ["wall_s"], 4,
                    namefn=lambda t, o: f"{dict(LANGS)[t.rsplit('-', 1)[0]]}: "
                    + (o['workload'] + " " + os.path.basename(o.get('journal', '')) if 'journal' in o else o['workload']))
        elif s == "w5":
            generic(["w5"], ["ns_per_op"], 3, label="variant / mode",
                    namefn=lambda t, o: f"{o['variant']} {o['mode']}")
        elif s == "e1":
            print("\n| workload | form | metric median [min, max] spread | runs×attempts | loadavg |")
            print("|---|---|---|---|---|")
            for o in load("e1-c"):
                k = {"w1": "tasks_per_s", "w2": "ns_per_switch", "w3": "p50_ns"}[o["workload"]]
                print(f"| {o['workload']} ({k}) | {o['e1_form']} | {cell(o, k, 2 if k == 'ns_per_switch' else 0)} "
                      f"| {runs_of(o)} | {la(o)} |")
        elif s == "w5pinned":
            generic(["w5pinned"], ["ns_per_op"], 3, label="variant / mode", namefn=lambda t, o: o["workload"])
        elif s == "e1pinned":
            generic(["e1pinned"], ["tasks_per_s", "ns_per_switch", "p50_ns"], 2, namefn=lambda t, o: o["workload"])
        elif s == "build":
            generic(["buildtime"], ["lang_build_s", "harness_link_s", "proc_wall_s"], 2,
                    namefn=lambda t, o: o["workload"])


if __name__ == "__main__":
    main()

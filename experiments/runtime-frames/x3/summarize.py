#!/usr/bin/env python3
# Medians and spread (min..max) over rounds, per scenario and strategy.
#   wasted% = CPU burned beyond useful work (cpu% - work%), of all workers' time
#             (meaningful in L, where work% is timed: the hold and background work)
#   stalled% = worker time off-CPU while not idle by choice (100 - cpu% - idle%)
import re, sys, statistics as st
rows = {}
for line in open(sys.argv[1]):
    if not line.startswith("RUN"): continue
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    key = (kv["scen"], kv["strategy"] + ("+" + kv["tuned"] if "tuned" in kv else ""))
    rows.setdefault(key, []).append(kv)
def f(xs, fmt="{:.1f}"):
    return f"{fmt.format(st.median(xs))} [{fmt.format(min(xs))}..{fmt.format(max(xs))}]"
for (sc, s), kvs in sorted(rows.items()):
    g = lambda k: [float(kv[k]) for kv in kvs]
    out = [f"{sc} {s:16s} n={len(kvs)} ok={all(kv['check']=='ok' for kv in kvs)}",
           f"req/s={f(g('req_per_s'), '{:.0f}')}", f"ns/req/worker={f(g('ns_per_req_per_worker'))}"]
    if sc != "U":
        cpu, work, idle = g("cpu_pct"), g("work_pct"), g("idle_pct")
        out += [f"wait_us p50={f(g('wait_p50_us'))} p99={f(g('wait_p99_us'))} max={f(g('wait_max_us'))}",
                f"spin%={f(g('spin_pct'))}", f"cpu%={f(cpu)}", f"idle%={f(idle)}"]
        if sc == "L":
            out += [f"work%={f(work)}", f"wasted%={f([c - w for c, w in zip(cpu, work)])}",
                    f"stalled%={f([100 - c - i for c, i in zip(cpu, idle)])}",
                    f"bg_ops/s={f(g('bg_ops_per_s'), '{:.0f}')}", f"handoffs={f(g('handoffs'), '{:.0f}')}"]
    print("  ".join(out))

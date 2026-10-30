#!/usr/bin/env python3
# Medians and spread [min..max] over rounds, per scenario and strategy.
#   lat      a request's latency, next_request to respond (all requests)
#   sh_lat   the same, requests that touched the table only (M)
#   spin%    the take's spin, of all workers' time
#   ispin%   workers spinning on an empty run queue before sleeping
#   wasted%  spin% + ispin%: CPU burned without progress
#   idle%    asleep with nothing to do;  stalled% blocked in a kernel lock
#   x/req    cross-worker messages a request (ring pushes, cross-worker requeues)
#   wake/req cross-thread condition-variable wakes a request
#   remote_req/s  requests completed on workers other than the home (A, W)
#   home%    the home worker's time running shipped operations (H)
import re, sys, statistics as st
rows = {}
for line in open(sys.argv[1]):
    if not line.startswith("RUN"): continue
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    key = (kv["scen"], kv["strategy"] + ("+" + kv["tuned"] if "tuned" in kv else ""))
    rows.setdefault(key, []).append(kv)
def f(xs, fmt="{:.1f}"):
    return f"{fmt.format(st.median(xs))} [{fmt.format(min(xs))}..{fmt.format(max(xs))}]"
order = {s: i for i, s in enumerate("U C L M A1 A4 A16 W2 W4 W12".split())}
for (sc, s), kvs in sorted(rows.items(), key=lambda x: (order.get(x[0][0], 99), x[0][0], x[0][1])):
    g = lambda k: [float(kv[k]) for kv in kvs]
    out = [f"{sc:3s} {s:16s} n={len(kvs)} ok={all(kv['check']=='ok' for kv in kvs)}",
           f"req/s={f(g('req_per_s'), '{:.0f}')}"]
    if sc != "U":
        if "remote_req_per_s" in kvs[0] and sc[0] in "AW":
            out += [f"remote_req/s={f(g('remote_req_per_s'), '{:.0f}')}"]
        out += [f"lat_us p50={f(g('lat_p50_us'))} p99={f(g('lat_p99_us'))} max={f(g('lat_max_us'), '{:.0f}')}"]
        if sc == "M":
            out += [f"sh_req/s={f(g('sh_req_per_s'), '{:.0f}')}",
                    f"sh_lat_us p50={f(g('sh_lat_p50_us'))} p99={f(g('sh_lat_p99_us'))} max={f(g('sh_lat_max_us'), '{:.0f}')}"]
        sp, isp, cpu, idle = g("spin_pct"), g("idle_spin_pct"), g("cpu_pct"), g("idle_pct")
        out += [f"spin%={f(sp)}", f"ispin%={f(isp)}", f"wasted%={f([a + b for a, b in zip(sp, isp)])}",
                f"idle%={f(idle)}", f"stalled%={f([100 - c - i for c, i in zip(cpu, idle)])}",
                f"x/req={f(g('xmsgs_per_req'), '{:.2f}')}", f"wake/req={f(g('xwakes_per_req'), '{:.3f}')}",
                f"home%={f(g('home_busy_pct'))}"]
        if sc == "L":
            out += [f"work%={f(g('work_pct'))}", f"bg_ops/s={f(g('bg_ops_per_s'), '{:.0f}')}",
                    f"handoffs={f(g('handoffs'), '{:.0f}')}"]
        if any(float(kv["ring_full"]) for kv in kvs): out.append(f"ring_full={f(g('ring_full'), '{:.0f}')}")
    else:
        out.append(f"ns/req={f([1e9 / x for x in g('req_per_s')])}")
    print("  ".join(out))

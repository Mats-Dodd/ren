import json, statistics, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1])]
KEY = {"w1": ["tasks_per_s"], "w2": ["ns_per_switch"], "w3": ["p50_ns", "p99_ns"], "w5": ["ns_per_op"]}
g = collections.defaultdict(list); fails = collections.Counter()
for r in rows:
    k = (r["wl"], r["driver"], r["workers"], r["lang"])
    if r["rc"] != 0: fails[k] += 1; continue
    g[k].append(r["m"])
out = {}
for k, ms in sorted(g.items()):
    for key in KEY[k[0]]:
        xs = [m[key] for m in ms if key in m]
        med = statistics.median(xs)
        out[(k, key)] = (med, min(xs), max(xs), (max(xs) - min(xs)) / med, len(xs), fails[k])
        print(f"{k[0]} {k[1]} x{k[2]} {k[3]:5s} {key:12s} med {med:12.2f} [{min(xs):.2f}, {max(xs):.2f}] spread {100*(max(xs)-min(xs))/med:.1f}% n={len(xs)} fail={fails[k]}")

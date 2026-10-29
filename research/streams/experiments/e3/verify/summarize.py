# `python3 -I summarize.py [results/e3.summary.json]`: a markdown table
# per workload, each row's median against its workload's baseline (the
# hand loop; W5's inlined chain), and ns per item where it means one.
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
s = json.load(open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "results/e3.summary.json")))
base = {"w1": "w1/C-hand", "w2": "w2/C-hand", "w3": "w3/C-hand", "w4": "w4/C-hand", "w5": "w5/C-inline"}
items = {"w1": 5 * 822724, "w2": 3 * 9092787, "w3": 8 * (16 << 20), "w4": 8 * 14680064, "w5": 5 * 987455}
print(f"start: {s['uptime_start']}\nend: {s['uptime_end']}\nruns: {s['runs']}\n")
for w in ["w1", "w2", "w3", "w4", "w5"]:
    rows = {k: v for k, v in s["rows"].items() if k.startswith(w + "/")}
    if not rows:
        continue
    b = rows[base[w]]["ms"]
    print(f"### {w}\n\n| variant | ms (median) | range | × {base[w].split('/')[1]} | ns/item | Minstr |\n|---|---|---|---|---|---|")
    for k, v in rows.items():
        print(f"| {k.split('/')[1]} | {v['ms']:.1f} | {v['min']:.1f}–{v['max']:.1f} | {v['ms']/b:.2f} | "
              f"{v['ms']*1e6/items[w]:.2f} | {v['proc_minstr']:.0f} |")
    print()

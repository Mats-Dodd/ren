#!/usr/bin/env python3
"""Independent re-run of the Phase B headline numbers (machine "cloud").
Each single run takes the EXCLUSIVE lock on its own (flock -x), languages are
interleaved per repetition (c, rust, zig, c, rust, zig, ...) so slow drift
hits all three equally. Raw samples appended as JSON lines to OUT."""
import json, re, subprocess, sys, time, os
V = sys.argv[1]; OUT = sys.argv[2]; group = sys.argv[3]; REPS = int(sys.argv[4]) if len(sys.argv) > 4 else 7
TAGS = {"c": "c-release", "rust": "rust-release", "zig": "zig-release-fast"}
W5 = {"c": "ii", "rust": "iii", "zig": "iv"}
SIZES = {"w1": "1000000", "w2": "10000000", "w3": "200000"}
CONFIGS = {
    "w1": [("w1", d, 8) for d in ("epoll", "uring")],
    "w2": [("w2", d, w) for w in (4, 8) for d in ("epoll", "uring")],
    "w3": [("w3", d, 8) for d in ("epoll", "uring")],
    "w5": [("w5", cc, 0) for cc in ("clang", "tcc")],
}
def la():
    return open("/proc/loadavg").read().split()[0]
def run(cmd):
    l0 = la(); t = time.time()
    p = subprocess.run(["flock", "-x", "/tmp/ren-bench/lock", "timeout", "600"] + cmd, capture_output=True, text=True)
    m = {}
    for line in p.stdout.splitlines():
        if line.startswith("metric:"):
            for k, v in re.findall(r"(\w+)=([-\d.]+)", line):
                try: m[k] = float(v)
                except ValueError: pass
    return {"rc": p.returncode, "m": m, "load0": l0, "load1": la(), "t": round(time.time() - t, 3),
            "err": p.stderr[-300:]}
for (wl, d, w) in CONFIGS[group]:
    for rep in range(REPS):
        for lang in ("c", "rust", "zig"):
            if wl == "w5":
                cmd = [f"{V}/bin/w5/w5-{W5[lang]}-{d}", "dupshared", "400000000"]
            else:
                cmd = [f"{V}/bin/{TAGS[lang]}/harness", wl, "--driver", d, "--workers", str(w), "--n", SIZES[wl]]
            r = run(cmd)
            rec = {"machine": "cloud", "wl": wl, "driver": d, "workers": w, "lang": lang, "rep": rep, "cmd": cmd, **r}
            with open(OUT, "a") as f: f.write(json.dumps(rec) + "\n")
            print(wl, d, w, lang, rep, r["rc"], r["m"].get("tasks_per_s") or r["m"].get("ns_per_switch") or r["m"].get("p50_ns") or r["m"].get("ns_per_op"), flush=True)

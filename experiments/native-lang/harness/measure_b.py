#!/usr/bin/env python3
"""measure_b.py: the Measure step of phase B, machine "cloud".

Same rules as measure.py (one configuration at a time, the whole configuration
under the EXCLUSIVE lock, /proc/loadavg at start and end, median/min/max), with
the Measure task's re-run rule: a configuration whose spread (max-min)/median of
ANY headline metric exceeds 10% is re-run up to 2 more times; if the last
attempt is still over 10% it is marked NOISY (never a headline). Every attempt
is kept in the record.

  measure_b.py run <bindir> <tag> [--workloads w1,w2,w3] [--workers 1,4,8] [--drivers epoll,uring] [--runs N]
  measure_b.py w4  <bindir> <tag> <journal> <workload> <n>     (replay throughput; journal recorded beforehand)
  measure_b.py w5  <w5-bindir> <tag>
  measure_b.py e1  <e1-bindir> <tag>
  measure_b.py cmd <tag> <name> [--runs N] [--keys k1,k2] -- <argv...>   (any command; default metric = its wall time, s;
                  --keys: metrics read from its 'metric:' lines)

Appends one JSON object per configuration to results/cloud/<tag>.jsonl."""
import json, os, re, subprocess, sys, time, statistics

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = "/tmp/ren-bench/lock"
RUNS = int(os.environ.get("RUNS", "10"))
MAX_RERUNS = 2
SIZES = {"w1": "1000000", "w2": "10000000", "w3": "200000"}
KEYS = {"w1": ["tasks_per_s"], "w2": ["ns_per_switch"], "w3": ["p50_ns", "p99_ns"]}
EXTRA = {"w1": ["inner_s", "wall_s"], "w2": ["inner_s", "wall_s"], "w3": ["p999_ns", "min_ns", "wall_s"]}


def loadavg():
    with open("/proc/loadavg") as f:
        return f.read().split()[:3]


def metrics(text):
    out = {}
    for line in text.splitlines():
        if line.startswith("metric:"):
            for k, v in re.findall(r"(\w+)=([-\d.]+)", line):
                try:
                    out[k] = float(v)
                except ValueError:
                    pass
    return out


def summarize(samples, keys):
    s = {}
    for k in keys:
        xs = [x[k] for x in samples if k in x]
        if not xs:
            continue
        med = statistics.median(xs)
        s[k] = {"median": med, "min": min(xs), "max": max(xs),
                "spread": (max(xs) - min(xs)) / med if med else None, "n": len(xs)}
    return s


RUNNER = r'''
import subprocess, sys, json, time
cmd = json.loads(sys.argv[1]); runs = int(sys.argv[2]); timed = sys.argv[3] == "1"
out = []
for i in range(runs):
    t0 = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    dt = time.perf_counter() - t0
    out.append([p.returncode, p.stdout[-20000:], p.stderr[-2000:], dt])
print(json.dumps(out))
'''


def one_attempt(cmd, keys, runs, timed):
    la0 = loadavg()
    t0 = time.time()
    p = subprocess.run(["flock", "-x", LOCK, sys.executable, "-I", "-c", RUNNER, json.dumps(cmd), str(runs),
                        "1" if timed else "0"], capture_output=True, text=True)
    la1 = loadavg()
    if p.returncode != 0:
        raise SystemExit(f"measure_b: runner failed: {p.stderr}")
    rr = json.loads(p.stdout)
    bad = [r for r in rr if r[0] != 0]
    samples = []
    for r in rr:
        if r[0] != 0:
            continue
        m = metrics(r[1])
        m["proc_wall_s"] = r[3]
        samples.append(m)
    return {"loadavg_start": la0, "loadavg_end": la1, "elapsed_s": round(time.time() - t0, 3),
            "failed_runs": len(bad), "first_failure": (bad[0][2] if bad else None),
            "first_stdout": rr[0][1][-3000:] if rr else None,
            "summary": summarize(samples, keys), "samples": samples}


def spread_bad(res, keys):
    return any((res["summary"].get(k, {}).get("spread") or 0) > 0.10 for k in keys)


def measure(cmd, keys, extra=(), runs=RUNS):
    attempts = []
    while True:
        res = one_attempt(cmd, list(keys) + list(extra) + ["proc_wall_s"], runs, True)
        attempts.append(res)
        if not spread_bad(res, keys) or len(attempts) > MAX_RERUNS:
            break
    final = attempts[-1]
    return {"attempts": len(attempts), "noisy": spread_bad(final, keys), "final": final,
            "earlier_attempts": [{"loadavg_start": a["loadavg_start"], "loadavg_end": a["loadavg_end"],
                                  "summary": a["summary"]} for a in attempts[:-1]]}


def record(tag, obj):
    os.makedirs(os.path.join(ROOT, "results", "cloud"), exist_ok=True)
    path = os.path.join(ROOT, "results", "cloud", f"{tag}.jsonl")
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")
    return path


def line(tag, label, m, keys):
    f = m["final"]
    parts = []
    for k in keys:
        s = f["summary"].get(k, {})
        parts.append(f"{k} med {s.get('median')} [{s.get('min')}, {s.get('max')}] sp {round((s.get('spread') or 0)*100,1)}%")
    print(f"{tag} {label}: " + "; ".join(parts) + f" failed={f['failed_runs']} attempts={m['attempts']}"
          f"{' NOISY' if m['noisy'] else ''} load {f['loadavg_start'][0]}->{f['loadavg_end'][0]}", flush=True)


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    mode = sys.argv[1]
    args = sys.argv[2:]
    def opt(name, dflt):
        return (args[args.index(name) + 1] if name in args else dflt).split(",")
    runs = int(opt("--runs", str(RUNS))[0])
    if mode == "run":
        bindir, tag = os.path.abspath(args[0]), args[1]
        for d in opt("--drivers", "epoll,uring"):
            for wl in opt("--workloads", "w1,w2,w3"):
                for w in opt("--workers", "1,4,8"):
                    cmd = [os.path.join(bindir, "harness"), wl, "--driver", d, "--workers", w, "--n", SIZES[wl]]
                    m = measure(cmd, KEYS[wl], EXTRA[wl], runs)
                    obj = {"machine": "cloud", "tag": tag, "workload": wl, "driver": d, "workers": int(w),
                           "runs": runs, "oversubscribed": int(w) > 4, "cmd": cmd, **m}
                    record(tag, obj)
                    line(tag, f"{wl} {d} x{w}{' (oversubscribed)' if int(w) > 4 else ''}", m, KEYS[wl])
    elif mode == "w4":
        bindir, tag, journal, wl, n = os.path.abspath(args[0]), args[1], args[2], args[3], args[4]
        cmd = [os.path.join(bindir, "harness"), wl, "--workers", "1", "--n", n, "--replay", journal]
        m = measure(cmd, ["wall_s"], [], runs)
        obj = {"machine": "cloud", "tag": tag, "workload": "w4-replay-" + wl, "journal": journal,
               "journal_bytes": os.path.getsize(journal), "runs": runs, "cmd": cmd, **m}
        record(tag, obj)
        line(tag, f"w4 replay {wl} ({os.path.basename(journal)})", m, ["wall_s"])
    elif mode == "w5":
        bindir, tag = os.path.abspath(args[0]), args[1]
        for exe in sorted(os.listdir(bindir)):
            if not exe.startswith("w5-"):
                continue
            for mm, n in (("dup", "400000000"), ("dupshared", "400000000"), ("push", "100000000")):
                cmd = [os.path.join(bindir, exe), mm, n]
                m = measure(cmd, ["ns_per_op"], [], runs)
                obj = {"machine": "cloud", "tag": tag, "workload": "w5", "variant": exe, "mode": mm,
                       "runs": runs, "cmd": cmd, **m}
                record(tag, obj)
                line(tag, f"{exe} {mm}", m, ["ns_per_op"])
    elif mode == "e1":
        bindir, tag = os.path.abspath(args[0]), args[1]
        for wl in ("w1", "w2", "w3"):
            for form in ("unity", "split"):
                cmd = [os.path.join(bindir, f"{wl}-{form}"), wl, "--workers", "1", "--n", SIZES[wl]]
                m = measure(cmd, KEYS[wl], EXTRA[wl], runs)
                obj = {"machine": "cloud", "tag": tag, "workload": wl, "e1_form": form, "workers": 1,
                       "driver": "epoll", "runs": runs, "cmd": cmd, **m}
                record(tag, obj)
                line(tag, f"E1 {wl} {form}", m, KEYS[wl])
    elif mode == "cmd":
        tag, name = args[0], args[1]
        cmd = args[args.index("--") + 1:]
        keys = opt("--keys", "proc_wall_s") if "--keys" in args[:args.index("--")] else ["proc_wall_s"]
        m = measure(cmd, keys, [], runs)
        obj = {"machine": "cloud", "tag": tag, "workload": name, "runs": runs, "cmd": cmd, **m}
        record(tag, obj)
        line(tag, name, m, keys)
    else:
        print(__doc__); sys.exit(2)


if __name__ == "__main__":
    main()

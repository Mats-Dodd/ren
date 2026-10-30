#!/usr/bin/env python3
"""measure.py: timed runs for the native-lang experiment, machine "cloud".

One configuration at a time under the EXCLUSIVE lock (flock -x
/tmp/ren-bench/lock), following experiments/MACHINE-cloud.md:
- 10 repetitions (at least 7);
- median, min and max;
- /proc/loadavg at the start and end;
- a configuration whose spread (max - min) / median exceeds 10% is re-run
  once, and reported as noisy if it still does.

  measure.py run  <bindir> <tag> [--workloads w1,w2,w3] [--workers 1,4,8] [--drivers epoll,uring]
  measure.py w5   <w5-bindir> <tag>
  measure.py e1   <e1-bindir> <tag>      ({w1,w2,w3}-{unity,split}, 1 worker, epoll)

Results are appended to results/cloud/<tag>.jsonl, one JSON object per
configuration, each naming machine "cloud"."""
import json, os, re, subprocess, sys, time, statistics

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = "/tmp/ren-bench/lock"
RUNS = int(os.environ.get("RUNS", "10"))
SIZES = {"w1": "1000000", "w2": "10000000", "w3": "200000"}
# the headline number per workload, from its "metric:" line
KEYS = {"w1": ["tasks_per_s", "inner_s"], "w2": ["ns_per_switch", "inner_s"],
        "w3": ["p50_ns", "p99_ns", "p999_ns", "wall_s"]}


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


def one_config(cmd, keys):
    """Run [cmd] RUNS times holding the exclusive lock for the whole configuration."""
    script = ("import subprocess,sys,json\n"
              "out=[]\n"
              f"cmd={cmd!r}\n"
              f"for i in range({RUNS}):\n"
              "    p=subprocess.run(cmd,capture_output=True,text=True,timeout=600)\n"
              "    out.append([p.returncode,p.stdout,p.stderr[-2000:]])\n"
              "print(json.dumps(out))\n")
    la0 = loadavg()
    t0 = time.time()
    p = subprocess.run(["flock", "-x", LOCK, sys.executable, "-I", "-c", script],
                       capture_output=True, text=True)
    la1 = loadavg()
    if p.returncode != 0:
        raise SystemExit(f"measure: runner failed: {p.stderr}")
    runs = json.loads(p.stdout)
    bad = [r for r in runs if r[0] != 0]
    samples = [metrics(r[1]) for r in runs if r[0] == 0]
    return {"loadavg_start": la0, "loadavg_end": la1, "elapsed_s": round(time.time() - t0, 3),
            "failed_runs": len(bad), "first_failure": (bad[0][2] if bad else None),
            "summary": summarize(samples, keys), "samples": samples}


def noisy(res, keys):
    return any((res["summary"].get(k, {}).get("spread") or 0) > 0.10 for k in keys[:1])


def record(tag, obj):
    os.makedirs(os.path.join(ROOT, "results", "cloud"), exist_ok=True)
    path = os.path.join(ROOT, "results", "cloud", f"{tag}.jsonl")
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")
    return path


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    mode, bindir, tag = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
    args = sys.argv[4:]
    opt = lambda name, dflt: (args[args.index(name) + 1] if name in args else dflt).split(",")
    if mode == "run":
        for d in opt("--drivers", "epoll,uring"):
            for wl in opt("--workloads", "w1,w2,w3"):
                for w in opt("--workers", "1,4,8"):
                    cmd = [os.path.join(bindir, "harness"), wl, "--driver", d, "--workers", w, "--n", SIZES[wl]]
                    res = one_config(cmd, KEYS[wl])
                    rerun = False
                    if noisy(res, KEYS[wl]):
                        rerun = True
                        res = one_config(cmd, KEYS[wl])
                    obj = {"machine": "cloud", "tag": tag, "workload": wl, "driver": d, "workers": int(w),
                           "runs": RUNS, "rerun": rerun, "noisy": noisy(res, KEYS[wl]),
                           "oversubscribed": int(w) > 4, "cmd": cmd, **res}
                    path = record(tag, obj)
                    k = KEYS[wl][0]
                    s = res["summary"].get(k, {})
                    print(f"{tag} {wl} {d} x{w}: {k} median {s.get('median')} "
                          f"[{s.get('min')}, {s.get('max')}] failed={res['failed_runs']}"
                          f"{' NOISY' if obj['noisy'] else ''} -> {path}", flush=True)
    elif mode == "w5":
        for exe in sorted(os.listdir(bindir)):
            if not exe.startswith("w5-"):
                continue
            for m, n in (("dup", "400000000"), ("dupshared", "400000000"), ("push", "100000000")):
                cmd = [os.path.join(bindir, exe), m, n]
                res = one_config(cmd, ["ns_per_op"])
                obj = {"machine": "cloud", "tag": tag, "workload": "w5", "variant": exe, "mode": m,
                       "runs": RUNS, "noisy": noisy(res, ["ns_per_op"]), "cmd": cmd, **res}
                record(tag, obj)
                s = res["summary"].get("ns_per_op", {})
                print(f"{exe} {m}: ns/op median {s.get('median')} [{s.get('min')}, {s.get('max')}]", flush=True)
    elif mode == "e1":
        for wl in ("w1", "w2", "w3"):
            for form in ("unity", "split"):
                cmd = [os.path.join(bindir, f"{wl}-{form}"), wl, "--workers", "1", "--n", SIZES[wl]]
                res = one_config(cmd, KEYS[wl])
                obj = {"machine": "cloud", "tag": tag, "workload": wl, "e1_form": form, "workers": 1,
                       "driver": "epoll", "runs": RUNS, "noisy": noisy(res, KEYS[wl]), "cmd": cmd, **res}
                record(tag, obj)
                k = KEYS[wl][0]
                s = res["summary"].get(k, {})
                print(f"E1 {wl} {form}: {k} median {s.get('median')} [{s.get('min')}, {s.get('max')}]", flush=True)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()

# `python3 -I measure.py <runs> [filter]`: runs every command <runs> times,
# interleaved (each round runs each command once, in a rotated order),
# each under /usr/bin/time -l, as ../../strings/track-b/measure.py does.
# Keeps every run in results/e3[-filter].jsonl, prints the median and
# range of the program's own *_ns phase, process cycles and instructions,
# and peak RSS, and writes results/e3[-filter].summary.json. A run whose
# `check=` differs from its workload's first is an error.
import json, os, re, statistics, subprocess, sys, time

here = os.path.dirname(os.path.abspath(__file__))
B = os.path.join(here, "bin")


def b(name, *a):
    return [os.path.join(B, name), *a]


CMDS = []
for v in ["hand", "push", "push-ni", "pull", "pull-ni", "pull-ni2"]:
    CMDS.append((f"w1/C-{v}", b("w1", "w1", v)))
CMDS += [("w1/rust-iter", b("e3-rust", "w1", "iter")), ("w1/rust-for", b("e3-rust", "w1", "for")),
         ("w1/rust-libc", b("e3-rust", "w1", "libc")),
         ("w1/go-loop", b("e3-go", "w1", "loop")), ("w1/go-push", b("e3-go", "w1", "push")),
         ("w1/go-pull", b("e3-go", "w1", "pull"))]
for v in ["hand", "hand-stack", "push", "pull-box", "pull-reuse", "pull-stack", "pull-stack2"]:
    CMDS.append((f"w2/C-{v}", b("w2", v)))
CMDS += [("w2/rust-push", b("e3-rust", "w2", "push")), ("w2/rust-stack", b("e3-rust", "w2", "stack")),
         ("w2/rust-boxed", b("e3-rust", "w2", "boxed")),
         ("w2/rust-oc-push", b("e3-rust-oc", "w2", "push")), ("w2/rust-oc-stack", b("e3-rust-oc", "w2", "stack")),
         ("w2/go-push", b("e3-go", "w2", "push")), ("w2/go-pull", b("e3-go", "w2", "pull"))]
for v in ["hand", "design", "full-push", "full-push2", "pull", "pull-ni"]:
    CMDS.append((f"w3/C-{v}", b("w3", v)))
CMDS += [("w3/rust-iter", b("e3-rust", "w3", "x")), ("w3/rust-oc-iter", b("e3-rust-oc", "w3", "x")),
         ("w3/go-push", b("e3-go", "w3", "push")), ("w3/go-pull", b("e3-go", "w3", "pull"))]
for v in ["hand", "push1", "pull", "pull-ni"]:
    CMDS.append((f"w4/C-{v}", b("w4", v)))
CMDS += [("w4/rust-zip", b("e3-rust", "w4", "x")), ("w4/rust-oc-zip", b("e3-rust-oc", "w4", "x")),
         ("w4/go-pull1", b("e3-go", "w4", "pull1")), ("w4/go-pull2", b("e3-go", "w4", "pull2"))]
for v in ["inline", "passed", "passed-ni", "indirect"]:
    CMDS.append((f"w5/C-{v}", b("w1", "w5", v)))
CMDS += [("w5/rust-inline", b("e3-rust", "w5", "inline")), ("w5/rust-generic", b("e3-rust", "w5", "generic")),
         ("w5/rust-dyn", b("e3-rust", "w5", "dyn")), ("w5/rust-libc", b("e3-rust", "w5", "libc")),
         ("w5/go-inline", b("e3-go", "w5", "inline")), ("w5/go-passed", b("e3-go", "w5", "passed"))]


def run(cmd):
    p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"failed: {' '.join(cmd)}\n{p.stdout}\n{p.stderr}")
    out = {}
    for line in p.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    e = p.stderr

    def g(pat):
        m = re.search(r"(\d+)\s+" + pat, e)
        return int(m.group(1)) if m else None

    out["cycles"] = g("cycles elapsed")
    out["instructions"] = g("instructions retired")
    out["rss"] = g("maximum resident set size")
    return out


def main():
    runs = int(sys.argv[1])
    filt = sys.argv[2] if len(sys.argv) > 2 else ""
    cmds = [(k, v) for k, v in CMDS if filt in k]
    os.makedirs(os.path.join(here, "results"), exist_ok=True)
    tag = "e3" + (("-" + filt.replace("/", "_")) if filt else "")
    log = open(os.path.join(here, "results", tag + ".jsonl"), "w")
    load0 = os.getloadavg()
    up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    log.write(json.dumps({"start": time.ctime(), "load": load0, "uptime": up0, "runs": runs,
                          "cmds": {k: v for k, v in cmds}}) + "\n")
    res = {k: [] for k, _ in cmds}
    for i in range(runs):
        order = cmds[i % len(cmds):] + cmds[: i % len(cmds)]
        for k, cmd in order:
            o = run(cmd)
            res[k].append(o)
            log.write(json.dumps({"cmd": k, "run": i, **o}) + "\n")
            log.flush()
    load1 = os.getloadavg()
    up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    log.write(json.dumps({"end": time.ctime(), "load": load1, "uptime": up1}) + "\n")
    bad = 0
    checks = {}
    for k, rs in res.items():
        w = k.split("/")[0]
        for o in rs:
            ch = o.get("check")
            checks.setdefault(w, ch)
            if checks[w] != ch:
                print(f"CHECK MISMATCH {k}: {ch} != {checks[w]}")
                bad += 1
    med = statistics.median
    summary = {"uptime_start": up0, "uptime_end": up1, "runs": runs, "rows": {}}
    print(f"# e3 {filt} runs={runs}\n# start: {up0}\n# end:   {up1}")
    for k, rs in res.items():
        w = k.split("/")[0]
        xs = [int(o[w + "_ns"]) / 1e6 for o in rs]
        ins = med([o["instructions"] for o in rs]) / 1e6
        cyc = med([o["cycles"] for o in rs]) / 1e6
        rss = med([o["rss"] for o in rs]) / 2**20
        summary["rows"][k] = {"ms": med(xs), "min": min(xs), "max": max(xs),
                              "proc_mcyc": cyc, "proc_minstr": ins, "rss_mib": rss,
                              "check": rs[0].get("check")}
        print(f"{k:22s} {med(xs):9.1f} ms ({min(xs):.1f}-{max(xs):.1f}) | proc {cyc:.0f} Mcyc "
              f"{ins:.0f} Minstr rss {rss:.1f} MiB")
    json.dump(summary, open(os.path.join(here, "results", tag + ".summary.json"), "w"), indent=1)
    if bad:
        sys.exit(1)


main()

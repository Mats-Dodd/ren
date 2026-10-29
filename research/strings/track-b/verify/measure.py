# `python3 -I measure.py <set> <runs> [filter]`: runs every command of
# the set <runs> times, interleaved (each round runs each command once,
# in a rotated order), each under /usr/bin/time -l, as bench/native/
# profile/measure.py does. Keeps every run in results/<set>.jsonl and
# prints, per command, the median and spread (min-max) of each `*_ns`
# phase the program reports, of the whole process's cycles and
# instructions, and of its peak RSS. A run whose `check=` differs from
# the first command's of the same workload is an error.
import json, os, re, statistics, subprocess, sys, time

here = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(os.path.dirname(here), "data")
bin_ = os.path.join(here, "bin")
rust = os.path.join(here, "rust-target/release")


def c(name, *a):
    return [os.path.join(bin_, name), *a]


def r(name, *a):
    return [os.path.join(rust, name), *a]


SETS = {}
v1 = []
for w in ["tok", "map", "sort"]:
    for rep in ["A", "B", "SSO", "SSOmc", "G", "B24"]:
        v1.append((f"{w}/C-{rep}", c(f"b1-{rep}", w, D)))
    if w == "map":
        v1.append((f"{w}/C-SSOfix", c("b1-SSOfix", w, D)))
SETS["v1"] = v1
v2 = []
for rep in ["A", "B", "SSO"]:
    for pol in ["share", "n16", "n64", "store"]:
        v2.append((f"keep/C-{rep}-{pol}", c(f"b2-{rep}-{pol}", D)))
v2.append(("keep/rust-own", r("b2", D)))
v2.append(("keep/go-share", c("b2-go", D, "share")))
v2.append(("keep/go-clone", c("b2-go", D, "clone")))
v2.append(("tok/C-B-share", c("b1-B", "tok", D)))
v2.append(("tok/C-B-store", c("b1-B-store", "tok", D)))
v2.append(("tok/C-A-store", c("b1-A-store", "tok", D)))
v2.append(("tok/C-SSO-share", c("b1-SSO", "tok", D)))
SETS["v2"] = v2
v3 = []
for w in ["json", "logs"]:
    for v, name in [(1, "inplace"), (2, "builder"), (3, "iolist")]:
        v3.append((f"{w}/C-{name}", c(f"b3-{v}", w, D, name)))
    v3.append((f"{w}/C-iolist-stream", c("b3-3s", w, D, "iolist")))
    v3.append((f"{w}/rust-string", r("b3", w, D, "string")))
    v3.append((f"{w}/go-builder", c("b3-go", w, D)))
for w in ["json"]:
    for v, name in [(0, "concat"), (1, "inplace")]:
        v3.append((f"{w}5k/C-{name}", c(f"b3-{v}", w, D, name, "5000")))
SETS["v3"] = v3
v4 = []
for rep in ["A", "B"]:
    v4.append((f"map/C-{rep}-wy", c(f"b1-{rep}", "map", D)))
for mode in ["borrow", "own"]:
    for h in ["std", "fx", "ahash"]:
        v4.append((f"map/rust-{mode}-{h}", r("b1", "map", D, mode, h)))
SETS["v4"] = v4
rpr = []
for f in ["logs.txt", "people.csv", "utf8/cjk-big.txt"]:
    for v in ["none", "ren", "neon"]:
        rpr.append((f"rpr-{f.split('/')[-1]}/C-{v}", c("b5", "rpr", os.path.join(D, f), v)))
SETS["rpr"] = rpr
v5 = []
for size in ["64", "1048576"]:
    for k in ["ascii", "cjk", "mixed"]:
        for v in ["ren", "neon"]:
            v5.append((f"{k}-{size}/C-{v}", c("b5", "bench", k, size, v)))
        f = os.path.join(D, "utf8", f"{k}-{size}.txt")
        v5.append((f"{k}-{size}/rust-simdutf8", r("b5", f, size, "simdutf8")))
SETS["v5"] = v5

v6 = []
for w in ["group", "logs"]:
    for rep in ["A", "B", "B24", "SSO", "G"]:
        v6.append((f"{w}/C-{rep}", c(f"b1-{rep}", w, D)))
SETS["v6"] = v6
v7 = []
for rep in ["A", "B", "B24", "SSO"]:
    v7.append((f"logs/C-{rep}", c(f"b1-{rep}", "logs", D)))
    v7.append((f"logs/C-{rep}-ivfix", c(f"b1iv-{rep}", "logs", D)))
SETS["v7"] = v7
v8 = []
for w in ["tok", "sort"]:
    for rep in ["A", "B", "SSO", "G", "B24"]:
        v8.append((f"{w}/C-{rep}", c(f"b1-{rep}", w, D)))
        v8.append((f"{w}/C-{rep}-ivfix", c(f"b1iv-{rep}", w, D)))
SETS["v8"] = v8

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
    out["footprint"] = g("peak memory footprint")
    return out


def main():
    name, runs = sys.argv[1], int(sys.argv[2])
    filt = sys.argv[3] if len(sys.argv) > 3 else ""
    cmds = [(k, v) for k, v in SETS[name] if filt in k]
    os.makedirs(os.path.join(here, "results"), exist_ok=True)
    log = open(os.path.join(here, "results", f"{name}{('-' + filt.replace('/', '_')) if filt else ''}.jsonl"), "w")
    load = os.getloadavg()
    log.write(json.dumps({"start": time.ctime(), "load": load, "runs": runs,
                          "cmds": {k: v for k, v in cmds}}) + "\n")
    res = {k: [] for k, _ in cmds}
    for i in range(runs):
        order = cmds[i % len(cmds):] + cmds[: i % len(cmds)]
        for k, cmd in order:
            o = run(cmd)
            res[k].append(o)
            log.write(json.dumps({"cmd": k, "run": i, **o}) + "\n")
            log.flush()
    log.write(json.dumps({"end": time.ctime(), "load": os.getloadavg()}) + "\n")
    # checks agree within a workload
    checks = {}
    for k, rs in res.items():
        w = k.split("/")[0]
        for o in rs:
            ch = o.get("check") or o.get("ok")
            if ch is None:
                continue
            checks.setdefault(w, ch)
            if checks[w] != ch:
                print(f"CHECK MISMATCH {k}: {ch} != {checks[w]}")
    med = statistics.median
    print(f"# {name} {filt} runs={runs} load start {load[0]:.2f} end {os.getloadavg()[0]:.2f}")
    for k, rs in res.items():
        phases = [p for p in rs[0] if p.endswith("_ns")]
        parts = []
        for p in phases:
            xs = [int(o[p]) / 1e6 for o in rs]
            parts.append(f"{p[:-3]} {med(xs):.2f} ({min(xs):.2f}-{max(xs):.2f}) ms")
        if "gbps" in rs[0]:
            xs = [float(o["gbps"]) for o in rs]
            parts.append(f"GB/s {med(xs):.2f} ({min(xs):.2f}-{max(xs):.2f})")
        ins = med([o["instructions"] for o in rs]) / 1e6
        cyc = med([o["cycles"] for o in rs]) / 1e6
        rss = med([o["rss"] for o in rs]) / 2**20
        parts.append(f"proc {cyc:.0f} Mcyc {ins:.0f} Minstr rss {rss:.1f} MiB")
        print(f"{k:28s} " + " | ".join(parts))


main()

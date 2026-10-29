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
D = os.path.join(here, "data")
bin_ = os.path.join(here, "bin")
rust = os.path.join(here, "rust/target/release")


def c(name, *a):
    return [os.path.join(bin_, name), *a]


def r(name, *a):
    return [os.path.join(rust, name), *a]


SETS = {}

# B1: layouts, five workloads, and the twins
b1 = []
for w in ["tok", "map", "sort", "group", "logs"]:
    for rep in ["A", "B", "SSO", "G"]:
        b1.append((f"{w}/C-{rep}", c(f"b1-{rep}", w, D)))
    b1.append((f"{w}/rust-borrow", r("b1", w, D, "borrow")))
    b1.append((f"{w}/rust-own", r("b1", w, D, "own")))
    if w != "group":
        b1.append((f"{w}/rust-rc", r("b1", w, D, "rc")))
    b1.append((f"{w}/go-share", c("b1-go", w, D, "share")))
SETS["b1"] = b1

# B1, second session: the C layouts only, with Roc's 24-byte B, SSO's
# fast inline path against its byte copy, and atomic counts
b1x = []
for w in ["tok", "map", "sort", "group", "logs"]:
    for rep in ["A", "B", "B24", "SSO", "SSOmc", "G", "A-at", "B-at", "SSO-at"]:
        b1x.append((f"{w}/C-{rep}", c(f"b1-{rep}", w, D)))
SETS["b1x"] = b1x

# B2: retention
b2 = []
for rep in ["A", "B", "SSO"]:
    for pol in ["share", "n8", "n16", "n24", "n32", "n64", "store"]:
        b2.append((f"keep/C-{rep}-{pol}", c(f"b2-{rep}-{pol}", D)))
b2.append(("keep/rust-own", r("b2", D)))
b2.append(("keep/go-share", c("b2-go", D, "share")))
b2.append(("keep/go-clone", c("b2-go", D, "clone")))
for rep in ["A", "B"]:
    b2.append((f"tok/C-{rep}-share", c(f"b1-{rep}", "tok", D)))
    for pol in ["n8", "n16", "n24", "n32", "n64", "store"]:
        b2.append((f"tok/C-{rep}-{pol}", c(f"b1-{rep}-{pol}", "tok", D)))
b2.append(("tok/C-SSO-share", c("b1-SSO", "tok", D)))
b2.append(("tok/rust-borrow", r("b1", "tok", D, "borrow")))
b2.append(("tok/rust-own", r("b1", "tok", D, "own")))
b2.append(("tok/go-share", c("b1-go", "tok", D, "share")))
b2.append(("tok/go-clone", c("b1-go", "tok", D, "clone")))
SETS["b2"] = b2

# B3: building output
b3 = []
for w in ["json", "logs", "http"]:
    for v, name in [(1, "inplace"), (2, "builder"), (3, "iolist")]:
        b3.append((f"{w}/C-{name}", c(f"b3-{v}", w, D, name)))
    if w == "http":
        b3.append((f"{w}/C-concat", c("b3-0", w, D, "concat")))
    b3.append((f"{w}/rust-string", r("b3", w, D, "string")))
    if w == "http":
        b3.append((f"{w}/rust-iovec", r("b3", w, D, "iovec")))
    b3.append((f"{w}/go-builder", c("b3-go", w, D)))
for w in ["json", "logs"]:  # concat is quadratic: 5000 records
    for v, name in [(0, "concat"), (1, "inplace"), (2, "builder"), (3, "iolist")]:
        b3.append((f"{w}5k/C-{name}", c(f"b3-{v}", w, D, name, "5000")))
SETS["b3"] = b3

# B4: keys
b4 = []
for w in ["map", "group"]:
    for rep in ["A", "B", "SSO", "G"]:
        b4.append((f"{w}/C-{rep}-wy", c(f"b1-{rep}", w, D)))
        b4.append((f"{w}/C-{rep}-fx", c(f"b4-{rep}-fx", w, D)))
        b4.append((f"{w}/C-{rep}-prefix", c(f"b4-{rep}-prefix", w, D)))
        b4.append((f"{w}/C-{rep}-nohashcmp", c(f"b4-{rep}-nohashcmp", w, D)))
    for mode in ["borrow", "own"]:
        for h in ["std", "fx", "ahash", "fold"]:
            b4.append((f"{w}/rust-{mode}-{h}", r("b1", w, D, mode, h)))
    b4.append((f"{w}/go-share", c("b1-go", w, D, "share")))
SETS["b4"] = b4

# B5: validation
b5 = []
for size in ["64", "1048576"]:
    for k in ["ascii", "latin", "cjk", "emoji", "mixed"]:
        for v in ["ren", "ascii", "neon"]:
            b5.append((f"{k}-{size}/C-{v}", c("b5", "bench", k, size, v)))
        f = os.path.join(D, "utf8", f"{k}-{size}.txt")
        b5.append((f"{k}-{size}/rust-std", r("b5", f, size, "std")))
        b5.append((f"{k}-{size}/rust-simdutf8", r("b5", f, size, "simdutf8")))
        b5.append((f"{k}-{size}/go", c("b5-go", f, size)))
SETS["b5"] = b5
rpr = []
for f in ["logs.txt", "people.csv", "utf8/cjk-big.txt"]:
    for v in ["none", "ren", "ascii", "neon"]:
        rpr.append((f"rpr-{f.split('/')[-1]}/C-{v}", c("b5", "rpr", os.path.join(D, f), v)))
SETS["rpr"] = rpr


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

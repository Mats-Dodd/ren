# `python3 -I measure.py <out> <runs> [results.jsonl]`: build.sh's
# binaries, Ren, Rust and Go interleaved, each run [runs] times, rotated
# each round. A Linux machine without cycle counters (a cloud container)
# has only time, so this takes wall time, from just before the process
# starts to just after it's reaped, and its peak RSS (wait4). Each Ren
# workload runs at R rounds and at 0 (`kernels` says R), and so does each
# twin; a round is (median at R - median at 0) / R, and the spread the R
# runs' least and most. Every run's output must be the same as the
# others' of its row at its rounds, Ren's, Rust's and Go's: the checks
# agree, or this stops. The slices parsers and `maps` are at 20 rounds
# and 0 as profile/measure.py's; `maps` is also timed against maps' Rust
# twin with FxHash (`rust-fx`), and `map` and `group` against Rust's std
# SipHash (`rust-std`).
#
# $KERNELS, comma-separated, times only those rows (`tok,map`); $SHARED
# set times each Ren binary's -DREN_RC_SHARED build beside it
# (`ren-shared`); $WHO, comma-separated, only those builds (`ren,rust`).
import json, os, statistics, subprocess, sys, time

here = os.path.dirname(os.path.abspath(__file__))
out, runs = sys.argv[1], int(sys.argv[2])
log = open(sys.argv[3], "a") if len(sys.argv) > 3 else None
only = os.environ["KERNELS"].split(",") if os.environ.get("KERNELS") else None
who_only = os.environ["WHO"].split(",") if os.environ.get("WHO") else None
shared = bool(os.environ.get("SHARED"))

# rows: name -> (R, unit bytes or None, {who: (cmd at R, cmd at 0)})
rows = {}
for line in open(os.path.join(here, "kernels")):
    name, call, r, twin, n = line.rstrip("\n").split("|")
    r = int(r)
    cmds = {}
    if call:
        cmds["ren"] = ([f"{out}/{name}-{r}"], [f"{out}/{name}-0"])
        if shared:
            cmds["ren-shared"] = ([f"{out}/{name}-{r}.shared"], [f"{out}/{name}-0.shared"])
    if twin:
        cmds["rust"] = ([f"{out}/strs-rust", twin, n, str(r)], [f"{out}/strs-rust", twin, n, "0"])
        if twin in ("map", "group"):
            cmds["rust-std"] = ([f"{out}/strs-rust", twin + "_std", n, str(r)],
                                [f"{out}/strs-rust", twin + "_std", n, "0"])
        cmds["go"] = ([f"{out}/strs-go", twin, n, str(r)], [f"{out}/strs-go", twin, n, "0"])
    rows[name] = (r, int(n) if name.startswith("utf8") else None, cmds)
for k in ["logs", "logs_r", "json", "json_r", "pages", "pages_r"]:
    cmds = {"ren": ([f"{out}/slices_{k}-20"], [f"{out}/slices_{k}-0"]),
            "rust": ([f"{out}/slices-rust", "200000", "20", k], [f"{out}/slices-rust", "200000", "0", k]),
            "go": ([f"{out}/slices-go", "200000", "20", k], [f"{out}/slices-go", "200000", "0", k])}
    if shared:
        cmds["ren-shared"] = ([f"{out}/slices_{k}-20.shared"], [f"{out}/slices_{k}-0.shared"])
    rows["slices_" + k] = (20, None, cmds)
cmds = {"ren": ([f"{out}/maps-20"], [f"{out}/maps-0"])}
if shared:
    cmds["ren-shared"] = ([f"{out}/maps-20.shared"], [f"{out}/maps-0.shared"])
for who, b in [("rust", "maps-rust"), ("rust-fx", "maps-rust-fx"), ("go", "maps-go")]:
    cmds[who] = ([f"{out}/{b}", "200000", "20"], [f"{out}/{b}", "200000", "0"])
rows["maps"] = (20, None, cmds)

rows = {k: v for k, v in rows.items() if only is None or k in only}
jobs = [(k, who, at, cmd) for k, (r, _, cmds) in rows.items() for who, pair in cmds.items()
        if who_only is None or who.split("-")[0] in who_only or who in who_only
        for at, cmd in zip(("R", "0"), pair)]


def run(cmd):
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    stdout = p.stdout.read()
    _, status, ru = os.wait4(p.pid, 0)
    t = time.perf_counter() - t0
    if status != 0:
        sys.exit(f"{cmd} failed: {status}")
    return t, ru.ru_maxrss, stdout.decode()


times = {j[:3]: [] for j in jobs}
rss = {j[:3]: [] for j in jobs}
seen = {}
print(f"load {os.getloadavg()[0]:.2f}, {len(jobs)} commands, {runs} runs", flush=True)
for i in range(runs):
    order = jobs[i % len(jobs):] + jobs[:i % len(jobs)]
    for k, who, at, cmd in order:
        t, m, output = run(cmd)
        times[(k, who, at)].append(t)
        rss[(k, who, at)].append(m)
        # the checks agree: every build of a row prints the same at R,
        # and the same at 0
        prev = seen.setdefault((k, at), (who, output))
        if prev[1] != output:
            sys.exit(f"{k}: {who} printed {output!r} at {at}, {prev[0]} {prev[1]!r}")
        if log:
            log.write(json.dumps({"kernel": k, "who": who, "at": at, "cmd": cmd, "s": t,
                                  "maxrss_kb": m, "load": os.getloadavg()[0]}) + "\n")
            log.flush()
    print(f"run {i + 1} done, load {os.getloadavg()[0]:.2f}", flush=True)

med = statistics.median
for k, (r, size, cmds) in rows.items():
    for who in cmds:
        if (k, who, "R") not in times:
            continue
        tr, t0 = times[(k, who, "R")], times[(k, who, "0")]
        a_round = (med(tr) - med(t0)) / r
        line = (f"{k:18s} {who:10s} ms a round {a_round * 1e3:9.2f}"
                f"  ({r} rounds {min(tr) * 1e3:.0f}-{max(tr) * 1e3:.0f} ms, 0 rounds {med(t0) * 1e3:.0f})"
                f"  peak RSS {med(rss[(k, who, 'R')]) / 1024:.1f} MiB")
        if size:
            line += f"  GB/s {size / a_round / 1e9:.2f}"
        print(line)

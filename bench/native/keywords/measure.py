# `python3 -I measure.py <out> <runs> [results.jsonl]`: build.sh's
# binaries, Ren's chain and match and the Rust and Go twins, interleaved,
# each run [runs] times, rotated each round. Wall time from just before
# the process starts to just after it's reaped; a lookup is (median at R
# - median at 0) / (R * 65,536), and the spread is the R runs' least and
# most less the median at 0. Every run of a set must print the same
# check, or this stops. $SETS, comma-separated, times only those sets.
import json, os, statistics, subprocess, sys, time

out, runs = sys.argv[1], int(sys.argv[2])
log = open(sys.argv[3], "a") if len(sys.argv) > 3 else None
R = int(os.environ.get("R", "200"))
N = 65536
sets = os.environ.get("SETS", "renkw,jsreserved,methods,headers,json24,one").split(",")


def run(cmd):
    t = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True)
    t = time.perf_counter() - t
    if p.returncode != 0:
        sys.exit(f"{cmd} failed: {p.stderr}")
    return t, p.stdout.strip()


for s in sets:
    cmds = {}
    for form in ["chain", "match"]:
        if os.path.exists(f"{out}/{s}-{form}-{R}"):
            cmds["ren-" + form] = ([f"{out}/{s}-{form}-{R}"], [f"{out}/{s}-{form}-0"])
    cmds["rust"] = ([f"{out}/keywords-rust", s, str(N), str(R)], [f"{out}/keywords-rust", s, str(N), "0"])
    cmds["go"] = ([f"{out}/keywords-go", s, str(N), str(R)], [f"{out}/keywords-go", s, str(N), "0"])
    times = {w: ([], []) for w in cmds}
    checks = {}
    order = list(cmds)
    for i in range(runs):
        for w in order[i % len(order):] + order[: i % len(order)]:
            for j, cmd in enumerate(cmds[w]):
                t, o = run(cmd)
                key = (j, o)
                if checks.setdefault(j, o) != o:
                    sys.exit(f"{s}: {w} printed {o}, not {checks[j]}")
                times[w][j].append(t)
    row = {}
    for w, (at_r, at_0) in times.items():
        base = statistics.median(at_0)
        per = lambda t: (t - base) / (R * N) * 1e9
        row[w] = {"ns": per(statistics.median(at_r)), "lo": per(min(at_r)), "hi": per(max(at_r))}
    print(s + ": " + ", ".join(f"{w} {v['ns']:.2f} ns ({v['lo']:.2f} to {v['hi']:.2f})" for w, v in row.items()))
    if log:
        log.write(json.dumps({"set": s, "R": R, "runs": runs, "rows": row}) + "\n")

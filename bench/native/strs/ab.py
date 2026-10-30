# `python3 -I ab.py <before> <after> <runs> name:R ...`: two build.sh
# outputs (bench/native/RESULTS.md, "Bytes stage, part two, step 3"),
# each Ren kernel of both at R rounds and at 0, interleaved and rotated;
# ms a round, (median at R - median at 0) / R, and the R runs' spread.
import os, statistics, subprocess, sys, time
a, b, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
ks = [x.split(":") for x in sys.argv[4:]]
jobs = [(k, w, at, f"{d}/{k}-{at}") for k, r in ks for w, d in (("before", a), ("after", b)) for at in (r, "0")]
t = {j[:3]: [] for j in jobs}
for i in range(runs):
    for k, w, at, cmd in jobs[i % len(jobs):] + jobs[:i % len(jobs)]:
        t0 = time.perf_counter()
        subprocess.run([cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        t[(k, w, at)].append((time.perf_counter() - t0) * 1000)
for k, r in ks:
    row = []
    for w in ("before", "after"):
        R = t[(k, w, r)]; Z = t[(k, w, "0")]
        row.append((statistics.median(R) - statistics.median(Z)) / int(r))
        row.append(f"{min(R):.0f}-{max(R):.0f}")
    print(k, "medians R/0:", [round(statistics.median(t[(k, w, x)])) for w in ("before", "after") for x in (r, "0")])
    print(f"{k:16} before {row[0]:9.2f} ({row[1]})  after {row[2]:9.2f} ({row[3]})  after/before {row[2]/row[0]:.3f}", flush=True)

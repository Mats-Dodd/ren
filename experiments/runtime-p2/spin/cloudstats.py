#!/usr/bin/env python3
"""Per-configuration statistics for measure-cloud.sh.

    python3 cloudstats.py <reps-file> <try> <last-try 0|1> <reps-wanted> <gate-metrics> <args...>

<reps-file> holds the SPIN lines of one try of one configuration (all its
reps), plus "LOAD start=" / "LOAD end=" lines. Prints one CFG line:

    CFG try= reps= load1_start= load1_end= <m>_med= <m>_min= <m>_max= <m>_spread= ...
        gate_spread= status=ok|RERUN|NOISY|FAIL args="..."

spread = (max - min) / median. The gate is the largest spread over the
gate metrics (comma separated, default hop_p99_ns,cpu_ns_per_hop): above
0.10 the config is re-run (status RERUN) unless this was the last try,
in which case it is kept and marked NOISY.

Exit status: 0 ok, 3 rerun wanted, 4 noisy (kept), 1 failed run(s).
"""
import statistics
import sys

METRICS = ["hops_per_s", "hop_p50_ns", "hop_p99_ns", "hop_p999_ns", "reach_p50_ns", "reach_p99_ns",
           "cpu_ns_per_hop", "util", "waste", "spin_hit", "parks_per_hop"]
LIMIT = 0.10


def main():
    path, tr, last, want, gate = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1", int(sys.argv[4]), sys.argv[5]
    args = " ".join(sys.argv[6:])
    gate = [g for g in gate.split(",") if g]
    rows, fails, load = [], 0, {}
    for line in open(path):
        if line.startswith("LOAD "):
            k, v = line.split()[1].split("=", 1)
            load[k] = v
            continue
        if not line.startswith("SPIN "):
            continue
        if " FAIL" in line or not line.rstrip().endswith(" ok"):
            fails += 1
            continue
        kv = dict(t.split("=", 1) for t in line.split()[1:] if "=" in t)
        rows.append({m: float(kv[m]) for m in METRICS})
    out = [f"CFG try={tr} reps={len(rows)} load1_start={load.get('start', 'nan')} "
           f"load1_end={load.get('end', 'nan')}"]
    spreads = {}
    for m in METRICS:
        v = [r[m] for r in rows]
        if not v:
            continue
        med, lo, hi = statistics.median(v), min(v), max(v)
        sp = (hi - lo) / med if med else (0.0 if hi == lo else float("inf"))
        spreads[m] = sp
        out.append(f"{m}_med={med:.6g} {m}_min={lo:.6g} {m}_max={hi:.6g} {m}_spread={sp:.3f}")
    gs = max((spreads.get(g, float("inf")) for g in gate), default=0.0)
    if fails or len(rows) < want:
        status, rc = "FAIL", 1
    elif gs <= LIMIT:
        status, rc = "ok", 0
    elif not last:
        status, rc = "RERUN", 3
    else:
        status, rc = "NOISY", 4
    out.append(f"gate={','.join(gate)} gate_spread={gs:.3f} fails={fails} status={status} args=\"{args}\"")
    print(" ".join(out))
    sys.exit(rc)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Time the separate explicit-copy versus replay-model backtracking control."""
import json
import hashlib
from pathlib import Path
import statistics
import subprocess
import sys
import time

out, destination = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 11
commands = [(size, mode, [str(out / f"fork-{size}-{mode}")]) for size in (5000, 10000) for mode in ("copy", "replay")]
values = {f"{size}/{mode}": [] for size, mode, _ in commands}
checks = {}
for r in range(runs):
    order = commands[r % len(commands):] + commands[:r % len(commands)]
    if r % 2:
        order = list(reversed(order))
    for size, mode, cmd in order:
        start = time.perf_counter_ns()
        check = subprocess.check_output(cmd, text=True).strip()
        values[f"{size}/{mode}"].append((time.perf_counter_ns() - start) / 1e6)
        expected = checks.setdefault(str(size), check)
        if check != expected:
            raise RuntimeError(f"copy and replay differ at {size}")
destination.parent.mkdir(parents=True, exist_ok=True)
source = Path(__file__).resolve().parent / "fork.ren"
destination.write_text(json.dumps({"sources_sha256": {"fork.ren": hashlib.sha256(source.read_bytes()).hexdigest()}, "runs": runs, "commands": commands, "checks": checks, "milliseconds": values}, indent=2) + "\n")
print("| Positions | Mode | Process median ms (min–max) |")
print("|---|---|---:|")
for size, mode, _ in commands:
    v = values[f"{size}/{mode}"]
    print(f"| {size} | {mode} | {statistics.median(v):.3f} ({min(v):.3f}–{max(v):.3f}) |")

#!/usr/bin/env python3
"""Rotated, interleaved process timings; validates every printed checksum."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics as st
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument("out", type=Path)
p.add_argument("result", type=Path)
p.add_argument("--runs", type=int, default=11)
a = p.parse_args()
out = a.out.resolve()
cfg = json.loads((out / "config.json").read_text())
n, reps = cfg["size"], cfg["rounds"]
commands = []
for w in ("w1", "w2", "w3", "w4", "w5"):
    variants = [("ren", None), ("rust-stack" if w == "w2" else "rust", "libc"), ("go-pull1", "pull") if w == "w4" else ("go-push", "push")]
    if w in ("w1", "w5"):
        variants += [("rust-std", "std")]
    if w == "w2":
        variants += [("rust-boxed", "boxed")]
    if w in ("w1", "w2", "w3"):
        variants += [("go-pull", "pull")]
    if w == "w4":
        variants += [("go-pull2", "pull2")]
    for who, v in variants:
        for rounds in (1, reps):
            cmd = [str(out / f"{w}-{rounds}")] if who == "ren" else [str(out / ("streams-rust" if who.startswith("rust") else "streams-go")), str(n), str(rounds), v, w]
            commands.append((w, who, rounds, cmd))
values = {f"{w}/{who}/{r}": [] for w, who, r, _ in commands}
checks = {}
meta = {"platform": platform.platform(), "machine": platform.machine(), "config": cfg, "runs": a.runs, "commands": commands}
def command_text(cmd):
    return subprocess.check_output(cmd, text=True).strip()

cpu = Path("/proc/cpuinfo").read_text() if Path("/proc/cpuinfo").exists() else ""
meta["cpu"] = next((line.split(":", 1)[1].strip() for line in cpu.splitlines() if line.startswith("model name")), platform.processor())
meta["cpu_quota"] = Path("/sys/fs/cgroup/cpu.max").read_text().strip() if Path("/sys/fs/cgroup/cpu.max").exists() else None
meta["versions"] = {"rustc": command_text(["rustc", "--version"]), "go": command_text(["go", "version"]), "cc": command_text(["cc", "--version"]).splitlines()[0]}
here = Path(__file__).resolve().parent
meta["sources_sha256"] = {str(p.relative_to(here)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (here / "bench.ren", here / "rust/main.rs", here / "go/main.go")}
meta["git_commit"] = command_text(["git", "rev-parse", "HEAD"])
meta["uptime_start"] = command_text(["uptime"])
a.result.parent.mkdir(parents=True, exist_ok=True)
start = time.time()
for run in range(a.runs):
    # Rotate both languages and baseline/full cases each round; reverse every
    # other round to avoid correlating any language with an increasing load.
    order = commands[run % len(commands):] + commands[:run % len(commands)]
    if run % 2:
        order = list(reversed(order))
    for w, who, r, cmd in order:
        t = time.perf_counter_ns()
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        elapsed = (time.perf_counter_ns() - t) / 1e6
        check = result.stdout.strip()
        expected = checks.setdefault(f"{w}/{r}", check)
        if check != expected:
            raise RuntimeError(f"checksum mismatch: {w}/{who}/{r}: {check} != {expected}")
        values[f"{w}/{who}/{r}"].append(elapsed)
    meta["completed_rounds"] = run + 1
    a.result.write_text(json.dumps({"metadata": meta, "checks": checks, "milliseconds": values}, indent=2) + "\n")
    print(f"round {run + 1}/{a.runs} ({time.time() - start:.1f}s)", flush=True)
meta["uptime_end"] = command_text(["uptime"])
a.result.parent.mkdir(parents=True, exist_ok=True)
a.result.write_text(json.dumps({"metadata": meta, "checks": checks, "milliseconds": values}, indent=2) + "\n")
print("| Workload | Variant | Full process median ms (min–max) | Paired additional-pass median ms (min–max) | / Ren |")
print("|---|---|---:|---:|---:|")
for w, who, r, _ in commands:
    if r != reps:
        continue
    full, base = values[f"{w}/{who}/{r}"], values[f"{w}/{who}/1"]
    paired = [(f - b) / (reps - 1) for f, b in zip(full, base)]
    ren = [(f - b) / (reps - 1) for f, b in zip(values[f"{w}/ren/{r}"], values[f"{w}/ren/1"])]
    per = st.median(paired)
    ratio = f"{per / st.median(ren):.2f}" if min(paired) > 0 and min(ren) > 0 else "unstable"
    print(f"| {w} | {who} | {st.median(full):.2f} ({min(full):.2f}–{max(full):.2f}) | {per:.3f} ({min(paired):.3f}–{max(paired):.3f}) | {ratio} |")

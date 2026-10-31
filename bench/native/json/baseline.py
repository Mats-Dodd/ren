#!/usr/bin/env python3
"""Stage 12a baseline: run in the toolchain shell, outside concurrent builds.

Build: baseline.py build /tmp/ren-stage12a
Measure: baseline.py measure /tmp/ren-stage12a --runs 7
All binaries, generated entry points and Cargo output stay outside the checkout.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
NATIVE = HERE.parent
ROOT = NATIVE.parent.parent


def call(cmd, cwd=None):
    result = subprocess.run(list(map(str, cmd)), cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {list(map(str, cmd))}\n{result.stdout}{result.stderr}")
    return result.stdout.strip()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=["build", "measure"])
    p.add_argument("out", type=Path)
    p.add_argument("--results", type=Path, help="measurement output directory (defaults to binary directory)")
    p.add_argument("--ren", type=Path, default=ROOT / "_build/default/bin/main.exe")
    p.add_argument("--runs", type=int, default=7)
    p.add_argument("--warmups", type=int, default=1)
    p.add_argument("--size", type=int, default=10000)
    p.add_argument("--rounds", type=int, default=20)
    p.add_argument("--template-ops", type=int, default=10000000)
    a = p.parse_args()
    if min(a.runs, a.size, a.rounds, a.template_ops) <= 0:
        p.error("counts must be positive")
    if a.warmups < 0:
        p.error("warmups must be nonnegative")
    out, ren = a.out.resolve(), a.ren.resolve()
    out.mkdir(parents=True, exist_ok=True)
    config = out / "config.json"
    if a.mode == "build":
        cfg = {"size": a.size, "rounds": a.rounds, "template_ops": a.template_ops}
        config.write_text(json.dumps(cfg, indent=2) + "\n")
        # Copy sources so the baseline keeps the pre-stage compiler and program.
        import shutil
        baseline = out / "ren-baseline"
        if baseline.exists():
            baseline.unlink()
        shutil.copy2(ren, baseline)
        for rounds in (1, a.rounds):
            for mode in ("roundtrip", "decode", "encode"):
                d = out / "sources" / f"json-{mode}-{rounds}"
                d.mkdir(parents=True, exist_ok=True)
                shutil.copy2(HERE / "bench.ren", d / "bench.ren")
                fn = "run" if mode == "roundtrip" else mode + "_run"
                (d / "main.ren").write_text(f"import bench\nfn main() uses Console = bench.{fn}({a.size}, {rounds})\n")
                call([ren, "build", d / "main.ren", "--release", "-o", out / f"json-{mode}-ren-{rounds}"])
        call(["cargo", "build", "--locked", "--release", "--manifest-path", HERE / "rust/Cargo.toml", "--target-dir", out / "cargo"])
        rust_binary = out / "json-rust"
        if rust_binary.exists():
            rust_binary.unlink()
        shutil.copy2(out / "cargo/release/ren-stage12a-json-baseline", rust_binary)
        call(["go", "build", "-o", out / "json-go", HERE / "go/main.go"])
        template = ROOT / "research/templates/perf"
        call(["cc", "-O2", "-ffp-contract=off", "-I", ROOT / "lib/native/runtime", template / "c/interp.c", "-o", out / "templates-c", "-lm"])
        call(["rustc", "-C", "opt-level=3", "-C", "codegen-units=1", template / "rust/main.rs", "-o", out / "templates-rust"])
        # CHECK hashes every flushed byte. Define signed checksum wrapping in
        # this correctness-only build; performance builds keep verify.md flags.
        call(["cc", "-O2", "-ffp-contract=off", "-fwrapv", "-DCHECK", "-I", ROOT / "lib/native/runtime", template / "c/interp.c", "-o", out / "templates-check", "-lm"])
        checks = {}
        for group, variants in [("log", ["log-today-snp", "log-passed-site", "log-walk"]), ("html", ["html-today", "html-plan"])]:
            for variant in variants:
                value = call([out / "templates-check", variant, 1000])
                if value != checks.setdefault(group, value):
                    raise RuntimeError(f"template bytes differ: {variant}")
        (out / "template-byte-checks.json").write_text(json.dumps(checks, indent=2) + "\n")
        # Existing sequential kernels: same source and full workload as before.
        for source in sorted(NATIVE.glob("*/main.ren")):
            if source.parent.name in ("json", "cores"):
                continue
            print("build", source.parent.name, flush=True)
            call([ren, "build", source, "--release", "-o", out / (source.parent.name + "-ren")])
        print("baseline binaries ready", flush=True)
        return

    results = a.results.resolve() if a.results else out
    results.mkdir(parents=True, exist_ok=True)
    cfg = json.loads(config.read_text())
    n, rounds, ops = cfg["size"], cfg["rounds"], cfg["template_ops"]
    commands = []
    for r in (1, rounds):
        for mode in ("decode", "encode", "roundtrip"):
            commands += [(f"json/{mode}/ren/{r}", [out / f"json-{mode}-ren-{r}"], None, f"json/{mode}/{r}"),
                         (f"json/{mode}/rust/{r}", [out / "json-rust", n, r, mode], None, f"json/{mode}/{r}"),
                         (f"json/{mode}/go/{r}", [out / "json-go", n, r, mode], None, f"json/{mode}/{r}")]
    for group, variants in [("log", ["log-today-snp", "log-passed-site", "log-walk"]),
                            ("html", ["html-today", "html-plan"])]:
        for variant in variants:
            for count in (0, ops):
                commands.append((f"templates/{variant}/{count}", [out / "templates-c", variant, count], None, f"{group}/{count}"))
        for count in (0, ops):
            commands.append((f"templates/{group}-rust/{count}", [out / "templates-rust", group + "-write", count], None, f"{group}/{count}"))
    for name in ("just", "docs", "server"):
        for mode in ("check", "build"):
            cmd = [ren, mode, "main.ren"]
            if mode == "build":
                cmd += ["--release", "-o", out / (name + "-example")]
            commands.append((f"examples/{name}/{mode}", cmd, ROOT / "examples" / name, None))
    for binary in sorted(out.glob("*-ren")):
        commands.append(("sequential/" + binary.name, [binary], None, "sequential/" + binary.name))
    metadata = {
        "time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "node": platform.node(), "platform": platform.platform(), "cpu_count": os.cpu_count(),
        "commit": call(["git", "rev-parse", "HEAD"], ROOT), "config": cfg,
        "runs": a.runs, "warmups": a.warmups,
        "ren_sha256": hashlib.sha256(ren.read_bytes()).hexdigest(),
        "cpu_quota": Path("/sys/fs/cgroup/cpu.max").read_text().strip() if Path("/sys/fs/cgroup/cpu.max").exists() else None,
        "cpu": next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "unknown"),
        "versions": {tool: call([tool, arg]).splitlines()[0] for tool, arg in [("cc", "--version"), ("rustc", "--version"), ("cargo", "--version"), ("go", "version")]},
        "sources_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [HERE / "bench.ren", HERE / "rust/src/main.rs", HERE / "rust/Cargo.toml", HERE / "rust/Cargo.lock", HERE / "go/main.go", ROOT / "research/templates/perf/c/interp.c", ROOT / "research/templates/perf/rust/main.rs"]},
        "commands": [(name, list(map(str, cmd)), str(cwd) if cwd else None) for name, cmd, cwd, _ in commands],
    }
    (results / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    values, checks, failures = {}, {}, {}
    with (results / "samples.jsonl").open("w") as stream:
        for run in range(-a.warmups, a.runs):
            order = commands[run % len(commands):] + commands[:run % len(commands)]
            if run % 2:
                order = list(reversed(order))
            for name, cmd, cwd, checksum_group in order:
                load = os.getloadavg()
                start = time.perf_counter()
                result = subprocess.run(list(map(str, cmd)), cwd=cwd, text=True, capture_output=True)
                elapsed = time.perf_counter() - start
                output = result.stdout.strip()
                if result.returncode:
                    if name.startswith("examples/") and name.endswith("/build"):
                        failures[name] = {"returncode": result.returncode, "diagnostic": result.stderr.strip()}
                    else:
                        raise RuntimeError(f"{name} failed ({result.returncode}): {result.stdout}{result.stderr}")
                if checksum_group:
                    expected = checks.setdefault(checksum_group, output)
                    if output != expected:
                        raise RuntimeError(f"{name} differs: {output!r} != {expected!r}")
                if run >= 0:
                    values.setdefault(name, []).append(elapsed)
                stream.write(json.dumps({"time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "round": run, "name": name, "seconds": elapsed,
                                         "load_before": load, "load_after": os.getloadavg(), "output": output, "stderr": result.stderr, "returncode": result.returncode}) + "\n")
                stream.flush()
                print(f"{run + 1}/{a.runs} {name} {elapsed:.6f}s", flush=True)
    summary = {name: {"median_seconds": statistics.median(v), "min_seconds": min(v), "max_seconds": max(v)} for name, v in values.items()}
    paired = {}
    pairs = []
    if rounds > 1:
        for mode in ("decode", "encode", "roundtrip"):
            for language in ("ren", "rust", "go"):
                prefix = f"json/{mode}/{language}"
                pairs.append((prefix, f"{prefix}/{rounds}", f"{prefix}/1", n * (rounds - 1)))
    for group in ("log-today-snp", "log-passed-site", "log-walk", "html-today", "html-plan", "log-rust", "html-rust"):
        prefix = f"templates/{group}"
        pairs.append((prefix, f"{prefix}/{ops}", f"{prefix}/0", ops))
    for name, full, base, count in pairs:
        deltas = [(f - b) * 1e9 / count for f, b in zip(values[full], values[base])]
        paired[name] = {"median_ns_per_operation": statistics.median(deltas), "min_ns_per_operation": min(deltas), "max_ns_per_operation": max(deltas)}
    (results / "summary.json").write_text(json.dumps({"timings": summary, "paired": paired, "checksums": checks, "unavailable_builds": failures}, indent=2) + "\n")
    for name, row in summary.items():
        if name in failures:
            print(f"| {name} | unavailable | exit {failures[name]['returncode']}; diagnostic in summary.json |")
            continue
        print(f"| {name} | {row['median_seconds']:.6f} | {row['min_seconds']:.6f}–{row['max_seconds']:.6f} |")
    print("Paired per-operation nanoseconds (median, min–max):")
    for name, row in paired.items():
        print(f"| {name} | {row['median_ns_per_operation']:.3f} | {row['min_ns_per_operation']:.3f}–{row['max_ns_per_operation']:.3f} |")


if __name__ == "__main__":
    main()

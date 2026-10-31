#!/usr/bin/env python3
"""Calibrate stage 12a's deterministic step default without changing the compiler.

Run in the Ren toolchain shell, with no other builds or benchmark processes:
  python3 bench/native/shape-steps.py prepare /tmp/ren-shape-steps
  python3 bench/native/shape-steps.py measure /tmp/ren-shape-steps --runs 7
  python3 bench/native/shape-steps.py probes /tmp/ren-shape-steps

The temporary compiler charges one step per evaluated Core expression. A tail
branch charges before handling it; the fallback delegates its charge to eval.
The zero-iteration control removes module loading and command startup. Timings
are evidence for a fixed default, never part of the language's step limit.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
MARKER = "REN_CALIBRATION_STEPS="
PROGRAM = '''fn main() uses Console =
  var total = 0
  var i = 0
  while i < NNN
    total = (total + i) % 65521
    i += 1
  print(total)
'''


def call(cmd, **kwargs):
    return subprocess.run(list(map(str, cmd)), check=True, text=True,
                          capture_output=True, **kwargs)


def prepare(out):
    source = out / "source"
    source.mkdir(parents=True, exist_ok=True)
    paths = call(["git", "ls-files", "lib", "bin", "dune", "dune-project"], cwd=ROOT).stdout.splitlines()
    for name in paths:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    evaluator = source / "lib/eval/eval.ml"
    text = evaluator.read_text()
    head = '''let calibration_steps = ref 0
let calibration_tick () = incr calibration_steps
let () = at_exit (fun () -> Printf.eprintf "REN_CALIBRATION_STEPS=%d\\n%!" !calibration_steps)

'''
    needle = "let rec eval cx env (e : expr) =\n  match e.kind with"
    assert text.count(needle) == 1
    text = text.replace(needle, head + "let rec eval cx env (e : expr) =\n  calibration_tick ();\n  match e.kind with")
    needle = "and tail cx env (e : expr) =\n  match e.kind with"
    replacement = '''and tail cx env (e : expr) =
  (match e.kind with
  | If _ | Let _ | Seq _ | Match _ -> calibration_tick ()
  | Call (_, args, _)
    when List.for_all (function Value _ -> true | Ref _ -> false) args ->
      calibration_tick ()
  | _ -> ());
  match e.kind with'''
    assert text.count(needle) == 1
    text = text.replace(needle, replacement)
    evaluator.write_text(text)
    result = call(["dune", "build", "--root", source, "bin/main.exe"], cwd=source)
    (out / "build.log").write_text(result.stdout + result.stderr)
    meta = {
        "commit": call(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip(),
        "original_eval_sha256": hashlib.sha256((ROOT / "lib/eval/eval.ml").read_bytes()).hexdigest(),
        "instrumented_eval_sha256": hashlib.sha256(evaluator.read_bytes()).hexdigest(),
        "charge": "one per eval dispatch; tail If/Let/Seq/Match and eligible tail Call charge directly; fallback charges in eval",
        "versions": {name: call([name, arg]).stdout.strip() for name, arg in [("ocamlc", "-version"), ("dune", "--version")]},
    }
    (out / "compiler.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(source / "_build/default/bin/main.exe")


def measure(out, runs, iterations):
    compiler = out / "source/_build/default/bin/main.exe"
    assert compiler.is_file(), "run prepare first"
    cases = (0, iterations)
    for n in cases:
        (out / f"loop-{n}.ren").write_text(PROGRAM.replace("NNN", str(n)))
    samples = []
    # Warm both paths before measuring rotated/interleaved pairs.
    for n in cases:
        call([compiler, "run", out / f"loop-{n}.ren"])
    for run in range(runs):
        for n in (cases if run % 2 == 0 else tuple(reversed(cases))):
            cmd = [compiler, "run", out / f"loop-{n}.ren"]
            load = os.getloadavg()
            start = time.perf_counter()
            result = call(cmd)
            elapsed = time.perf_counter() - start
            match = re.search(r"REN_CALIBRATION_STEPS=(\d+)", result.stderr)
            assert match, result.stderr
            samples.append({"run": run, "iterations": n, "seconds": elapsed,
                            "steps": int(match.group(1)), "stdout": result.stdout,
                            "load_before": load, "load_after": os.getloadavg()})
            print(run + 1, n, elapsed, match.group(1), flush=True)
    control = {x["run"]: x for x in samples if x["iterations"] == 0}
    rates = []
    for sample in samples:
        if sample["iterations"]:
            zero = control[sample["run"]]
            assert sample["seconds"] > zero["seconds"]
            rates.append((sample["steps"] - zero["steps"]) / (sample["seconds"] - zero["seconds"]))
    # The count is deterministic even though timings vary.
    for n in cases:
        assert len({x["steps"] for x in samples if x["iterations"] == n}) == 1
    median = statistics.median(rates)
    summary = {
        "host": platform.node(), "platform": platform.platform(), "cpu_count": os.cpu_count(),
        "cpu": next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "unknown"),
        "iterations": iterations, "runs": runs,
        "steps_per_second_median": median, "steps_per_second_min": min(rates), "steps_per_second_max": max(rates),
        "suggested_fixed_default": max(100000, round(median / 100000) * 100000),
        "samples": samples,
    }
    (out / "measurement.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "samples"}, indent=2))


def probes(out):
    compiler = ROOT / "_build/default/bin/main.exe"
    assert compiler.is_file(), "build the unmodified repository compiler first"
    rows = []
    for path in sorted((ROOT / "research/looks/feas").glob("*.ren")):
        argv = [str(compiler), "run", str(path)]
        p = subprocess.run(argv, text=True, capture_output=True)
        row = {"file": str(path.relative_to(ROOT)), "command": argv,
               "status": p.returncode, "stdout": p.stdout, "stderr": p.stderr}
        # The old research probes predate main's exact Console row. Keep their
        # original failures, then isolate that unrelated annotation outside git.
        original = path.read_text()
        corrected = re.sub(r"fn main\(\)\s*=", "fn main() uses Console =", original)
        corrections = []
        if corrected != original:
            corrections.append("declare main's Console row")
        if path.name == "i_named.ren":
            corrected = corrected.replace('Keys.get(key: "a").show()', '(try Keys.get(key: "a")).show()')
            corrections.append("handle Keys.get's declared error with try")
        if path.name == "v1.ren":
            corrected = corrected.replace("key.len()", "key.byte_len()")
            corrections.append("use Str.byte_len instead of obsolete Str.len")
        if corrected != original:
            companion = out / "companions" / path.name
            companion.parent.mkdir(parents=True, exist_ok=True)
            companion.write_text(corrected)
            fixed_argv = [str(compiler), "run", str(companion)]
            fixed = subprocess.run(fixed_argv, text=True, capture_output=True)
            row["companion"] = {"corrections": corrections, "command": fixed_argv,
                                "status": fixed.returncode, "stdout": fixed.stdout,
                                "stderr": fixed.stderr}
        rows.append(row)
        print(path.name, p.returncode, flush=True)
    (out / "probes.json").write_text(json.dumps({
        "commit": call(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip(),
        "compiler_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest(), "probes": rows}, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "measure", "probes"])
    parser.add_argument("out", type=Path)
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--iterations", type=int, default=5000000)
    args = parser.parse_args()
    if args.runs < 3 or args.iterations < 1:
        parser.error("use at least three runs and a positive iteration count")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if args.mode == "prepare":
        prepare(out)
    elif args.mode == "measure":
        measure(out, args.runs, args.iterations)
    else:
        probes(out)


if __name__ == "__main__":
    main()

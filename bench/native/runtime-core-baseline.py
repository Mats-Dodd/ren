#!/usr/bin/env python3
"""Runtime-core step 0: isolated release builds and rotated baseline runs.

Run from any directory. JSONL includes wall time, host load and stdout, with
one process at a time. The build subcommand copies the reference interpreter.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import re
import statistics
import subprocess
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
KERNELS = sorted(p.parent.name for p in HERE.glob("*/main.ren"))
EXAMPLES = {name: (ROOT / "examples" / name, [])
            for name in ["transfer", "refresh", "server", "crawler", "just", "breaker", "docs"]}
EXAMPLES.update({
    "11a-two-adds": (ROOT / "bench/11a/tasks/lost_update", ["--only", "two adds"]),
    "11a-cached": (ROOT / "bench/11a/tasks/lost_update", ["--only", "a save is never undone"]),
    "services-one-operation": (ROOT / "bench/services/lost_update", ["--only", "one operation"]),
    "services-without-chaos": (ROOT / "bench/services/memory", ["--only", "without chaos"]),
})


def run(cmd, cwd=None):
    return subprocess.run(list(map(str, cmd)), cwd=cwd, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def record(stream, kind, name, round_, cmd, cwd=None):
    load_before = os.getloadavg()
    start = time.perf_counter()
    p = run(cmd, cwd)
    item = dict(kind=kind, name=name, round=round_, time_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), command=list(map(str, cmd)),
                cwd=str(cwd or pathlib.Path.cwd()), seconds=time.perf_counter() - start,
                load_before=load_before, load_after=os.getloadavg(),
                returncode=p.returncode, output=p.stdout)
    stream.write(json.dumps(item) + "\n")
    stream.flush()
    print(f"{kind} {name} round={round_} {item['seconds']:.3f}s exit={p.returncode}", flush=True)
    if p.returncode:
        raise RuntimeError(p.stdout)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["build", "kernels", "examples", "frames", "summarize"])
    ap.add_argument("out", type=pathlib.Path)
    ap.add_argument("--ren", type=pathlib.Path, default=ROOT / "_build/default/bin/main.exe")
    ap.add_argument("--runs", type=int, default=5)
    args = ap.parse_args()
    if args.runs < 1:
        ap.error("--runs must be positive")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if args.mode != "summarize":
        metadata = dict(node=platform.node(), platform=platform.platform(),
                        cpu=os.cpu_count(), commit=run(["git", "rev-parse", "HEAD"], ROOT).stdout.strip(),
                        time_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
        for tool in ["clang", "cc", "ocamlc", "dune"]:
            metadata[tool] = run([tool, "--version" if tool != "ocamlc" else "-version"]).stdout.splitlines()[0]
        metadata["tcc"] = run([os.environ.get("REN_TCC", "tcc"), "-v"]).stdout.strip()
        if args.ren.exists():
            metadata["ren_sha256"] = hashlib.sha256(args.ren.read_bytes()).hexdigest()
        (out / (args.mode + "-metadata.json")).write_text(json.dumps(metadata, indent=2) + "\n")
    if args.mode == "frames":
        x1 = ROOT / "experiments/runtime-frames/x1"
        dest = out / "x1"
        dest.mkdir(exist_ok=True)
        variants = [("base_clang", "clang", ROOT / "experiments/runtime-p2/switch/c/ren_single.c", []),
                    ("reg_clang", "clang", x1 / "ren_reg.c", []),
                    ("reg_noinl_clang", "clang", x1 / "ren_reg.c", ["-DOPS_NOINLINE"]),
                    ("reg_nochk_clang", "clang", x1 / "ren_reg.c", ["-DBUMP_NOCHECK"]),
                    ("base_tcc", os.environ.get("REN_TCC", "tcc"), ROOT / "experiments/runtime-p2/switch/c/ren_single.c", []),
                    ("reg_tcc", os.environ.get("REN_TCC", "tcc"), x1 / "ren_reg.c", [])]
        for name, cc, src, flags in variants:
            subprocess.run([cc, "-O2", *flags, str(src), "-o", str(dest / name)], check=True)
        for name, _, _, _ in variants:
            subprocess.run([str(dest / name), "--check"], check=True, stdout=subprocess.DEVNULL)
        for name, flags in [("reg_asan", []), ("reg_noinl_asan", ["-DOPS_NOINLINE"])]:
            subprocess.run(["clang", "-O1", "-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all", *flags, str(x1 / "ren_reg.c"), "-o", str(dest / name)], check=True)
            subprocess.run([str(dest / name), "--check"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["python3", "-I", str(ROOT / "experiments/runtime-frames/x5/linux.py"), str(out / "x5"), "clang"], check=True)
        # The adapter frees the prototype's bookkeeping after observations.
        sanenv = dict(os.environ, ASAN_OPTIONS="detect_leaks=1")
        for policy in ["today", "static", "static_x", "static_xk"]:
            subprocess.run([str(out / "x5/frames-asan"), "park", policy, "5000"], check=True, env=sanenv)
        with (out / "frames.jsonl").open("w") as stream:
            for round_ in range(args.runs):
                rotated = variants[round_ % len(variants):] + variants[:round_ % len(variants)]
                for name, _, _, _ in rotated:
                    n = "500000" if name.endswith("tcc") else "2000000"
                    record(stream, "x1", name, round_ + 1, [dest / name, "--bench", "pingpong_nested", "--n", n, "--reps", "5"])
                policies = ["today", "static", "static_x", "static_xk"]
                policies = policies[round_ % 4:] + policies[:round_ % 4]
                for policy in policies:
                    record(stream, "x5", policy, round_ + 1, [out / "x5/frames", "park", policy, "100000"])
        return
    if args.mode == "build":
        import shutil
        shutil.copy2(args.ren, out / "ren-reference")
        with (out / "build.jsonl").open("w") as stream:
            for name in KERNELS:
                record(stream, "build", name, 0, [out / "ren-reference", "build", "main.ren", "--release", "-o", out / name], HERE / name)
        return
    if args.mode == "summarize":
        for filename in ["kernels.jsonl", "examples.jsonl"]:
            path = out / filename
            if not path.exists():
                continue
            items = [i for line in path.read_text().splitlines() if "name" in (i := json.loads(line))]
            for name in sorted(set(i["name"] for i in items)):
                rows = [i for i in items if i["name"] == name]
                vals = [i["seconds"] for i in rows]
                outputs = [i["output"] for i in rows]
                if rows[0]["kind"] == "examples":
                    # The CLI's final summary includes measured elapsed time.
                    # Compare the test results while retaining that raw text.
                    outputs = [re.sub(r"(?m)^(\d+ passed, each under \d+ seeds) in \d+ms$", r"\1", s) for s in outputs]
                assert len(set(outputs)) == 1, name
                print(f"| {name} | {statistics.median(vals):.4f} | {min(vals):.4f}–{max(vals):.4f} |")
        path = out / "frames.jsonl"
        if path.exists():
            items = [json.loads(line) for line in path.read_text().splitlines()]
            for name in sorted(set(i["name"] for i in items)):
                rows = [i for i in items if i["name"] == name]
                metric = "ns_per_op" if rows[0]["kind"] == "x1" else "usable_B_per_task"
                vals = [float(re.search(r"(?:^| )" + metric + r"=([0-9.]+)", i["output"])[1]) for i in rows]
                print(f"| {name} | {statistics.median(vals):.2f} | {min(vals):.2f}–{max(vals):.2f} |")
        return
    names = KERNELS if args.mode == "kernels" else list(EXAMPLES)
    with (out / (args.mode + ".jsonl")).open("w") as stream:
        stream.write(json.dumps(dict(kind="machine", node=platform.node(), platform=platform.platform(), cpu=os.cpu_count(), commit=run(["git", "rev-parse", "HEAD"], ROOT).stdout.strip())) + "\n")
        stream.flush()
        # Warm once, excluded. Rotate the first workload each round.
        for name in names:
            cmd = [out / name] if args.mode == "kernels" else [out / "ren-reference", "test", "--sim", "--seeds", "1000", *EXAMPLES[name][1]]
            cwd = ROOT if args.mode == "kernels" else EXAMPLES[name][0]
            p = run(cmd, cwd)
            if p.returncode:
                raise RuntimeError(p.stdout)
            print(f"warm {args.mode} {name} done", flush=True)
        for round_ in range(args.runs):
            for name in names[round_ % len(names):] + names[:round_ % len(names)]:
                cmd = [out / name] if args.mode == "kernels" else [out / "ren-reference", "test", "--sim", "--seeds", "1000", *EXAMPLES[name][1]]
                cwd = ROOT if args.mode == "kernels" else EXAMPLES[name][0]
                record(stream, args.mode, name, round_ + 1, cmd, cwd)

if __name__ == "__main__":
    main()

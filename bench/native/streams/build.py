#!/usr/bin/env python3
"""Build independent Cost kernels outside the checkout (run in toolchain shell)."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
p = argparse.ArgumentParser()
p.add_argument("out", type=Path)
p.add_argument("--size", type=int, default=1_000_000)
p.add_argument("--rounds", type=int, default=20)
p.add_argument("--fork-only", action="store_true", help="rebuild only the separate backtracking controls")
a = p.parse_args()
if a.size < 25 or a.rounds < 2:
    p.error("size must be >=25 and rounds >=2")
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
ren = Path(os.environ.get("REN", ROOT / "_build/default/bin/main.exe")).resolve()

def call(args, **kw):
    subprocess.run(list(map(str, args)), check=True, **kw)

if not a.fork_only:
    call(["rustc", "-C", "opt-level=3", "-C", "codegen-units=1", HERE / "rust/main.rs", "-o", out / "streams-rust"])
    call(["go", "build", "-o", out / "streams-go", HERE / "go/main.go"])
# Every entry keeps data construction outside the pass loop. Use 1 pass as
# the subtraction baseline so its input cannot become dead code at -O2.
inputs = {
    "w1": ("let b = bench.log_input(N)", "bench.map_select_take(b, N / 25, r)"),
    "w2": ("let t = bench.tree_input(0, N)", "bench.tree_walk(t, N / 8, r)"),
    "w3": ("let ds = bench.deltas_input(N)", "bench.dedup_by(ds, r)"),
    "w4": ("let xs = bench.zip_input(N)", "bench.zip(xs, N * 21 / 16, r)"),
    "w5": ("let b = bench.log_input(N)", "bench.passed(b, r)"),
}
for w, (setup, expr) in ([] if a.fork_only else inputs.items()):
    for rounds in (1, a.rounds):
        d = out / "sources" / f"{w}-{rounds}"
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy(HERE / "bench.ren", d / "bench.ren")
        text = f"import bench\nfn main() uses Console =\n  {setup}\n  var sum = 0\n  for r in 0..{rounds}\n    sum += {expr}\n  print(sum)\n"
        (d / "main.ren").write_text(text.replace("N", str(a.size)))
        name = f"{w}-{rounds}"
        print(name, flush=True)
        call([ren, "build", "main.ren", "--release", "-o", out / name], cwd=d)
        if rounds == a.rounds:
            with (out / f"{w}.c").open("w") as f:
                call([ren, "build", "main.ren", "--release", "--emit-c"], cwd=d, stdout=f)
if not a.fork_only:
    (out / "config.json").write_text(__import__("json").dumps({"size": a.size, "rounds": a.rounds}, indent=2) + "\n")
# Separate pure backtracking control, not one of the five Cost rows.
for size in (5000, 10000):
    for replay in (False, True):
        name = f"fork-{size}-{'replay' if replay else 'copy'}"
        d = out / "sources" / name
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy(HERE / "fork.ren", d / "fork.ren")
        (d / "main.ren").write_text(f"import fork\nfn main() uses Console = print(fork.backtrack({size}, {str(replay).lower()}))\n")
        call([ren, "build", "main.ren", "--release", "-o", out / name], cwd=d)

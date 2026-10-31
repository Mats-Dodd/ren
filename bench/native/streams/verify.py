#!/usr/bin/env python3
"""Small-size checksum agreement in the interpreter, native builds and twins."""
import os
import sys
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ren = str(Path(os.environ.get("REN", ROOT / "_build/default/bin/main.exe")).resolve())
env = dict(os.environ, REN_NOTES="0", ASAN_OPTIONS="detect_stack_use_after_return=0:detect_leaks=0")

def run(cmd, **kw):
    return subprocess.check_output(list(map(str, cmd)), cwd=HERE, env=env, text=True, **kw)

with tempfile.TemporaryDirectory(prefix="ren-streams-check-") as tmp:
    tmp = Path(tmp)
    for entry in (sys.argv[1:] or ("small.ren", "fork_small.ren")):
        expected = run([ren, "run", entry])
        for mode in ("debug", "release", "sanitize", "tcc"):
            binary = tmp / f"{entry}-{mode}"
            build_env = dict(env)
            flags = ["--debug" if mode in ("debug", "tcc") else "--release"]
            if mode == "tcc":
                build_env.pop("REN_CC", None)
                build_env.pop("REN_CFLAGS", None)
                if not build_env.get("REN_TCC") and not __import__("shutil").which("tcc"):
                    raise RuntimeError("REN_TCC or tcc on PATH required")
            else:
                build_env["REN_CC"] = "cc"
                build_env["REN_CFLAGS"] = "-fsanitize=address,undefined" if mode == "sanitize" else ""
            subprocess.run([ren, "build", entry, *flags, "-o", str(binary)], cwd=HERE, env=build_env, check=True)
            assert run([binary]) == expected, (entry, mode)
            print(f"{entry}: {mode} agrees", flush=True)
        if entry == "small.ren":
            subprocess.run(["rustc", "-C", "opt-level=3", "-C", "codegen-units=1", str(HERE / "rust/main.rs"), "-o", str(tmp / "rust")], check=True)
            subprocess.run(["go", "build", "-o", str(tmp / "go"), str(HERE / "go/main.go")], check=True)
            for lang, variants in (("rust", ("libc", "std", "boxed")), ("go", ("push", "pull", "pull2"))):
                for variant in variants:
                    assert run([tmp / lang, "200", "2", variant]) == expected, (lang, variant)
                    print(f"small.ren: {lang}/{variant} agrees", flush=True)

#!/usr/bin/env python3
"""Planned native sim CLI adapter. Missing capability is a failure/skip, never conformance."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("program", type=Path)
parser.add_argument("seed", type=int)
parser.add_argument("journal", type=Path)
parser.add_argument("mode", choices=["debug", "release", "asan", "ubsan", "tsan", "tcc"])
parser.add_argument("--test", help="original source test entry, future --ren-test host option")
args = parser.parse_args()
ren = json.loads(os.environ.get("REN_CORE_REN", '["ren"]'))
env = os.environ.copy()
if args.mode in ["asan", "ubsan", "tsan"]:
    sanitizer = dict(asan="address", ubsan="undefined", tsan="thread")[args.mode]
    env["REN_CFLAGS"] = env.get("REN_CFLAGS", "") + " -fsanitize=" + sanitizer + " -fno-omit-frame-pointer"
    env["REN_CC"] = env.get("REN_CC", "cc")
elif args.mode == "tcc":
    env["REN_CC"] = env.get("REN_TCC", "tcc")
with tempfile.TemporaryDirectory(prefix="ren-native-sim-") as directory:
    binary = Path(directory) / "program"
    build = ren + ["build", "--scheduler", "sim", "--release" if args.mode == "release" else "--debug",
                   str(args.program.resolve()), "-o", str(binary)]
    if args.test:
        build += ["--test-entry", args.test]
    result = subprocess.run(build, capture_output=True, env=env, check=False)
    if result.returncode:
        unsupported = any(b"has no option " + flag in result.stderr for flag in [b"--scheduler", b"--test-entry"])
        if unsupported:
            print("SKIP c4/c5: native sim/test-entry CLI capability is unavailable", file=sys.stderr)
            raise SystemExit(77)
        sys.stderr.buffer.write(result.stderr)
        raise SystemExit(result.returncode)
    command = [str(binary), "--ren-seed", str(args.seed), "--ren-record", str(args.journal.resolve())]
    if args.test:
        command += ["--ren-test", args.test]
    status = subprocess.run(command, env=env, check=False).returncode
    if not args.journal.is_file():
        print("native program produced no journal; runtime recording capability is unavailable", file=sys.stderr)
        raise SystemExit(77)
    raise SystemExit(status)

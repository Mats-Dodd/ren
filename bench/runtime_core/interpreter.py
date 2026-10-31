#!/usr/bin/env python3
"""Invoke the unchanged-Core reference adapter; no source launcher is used."""
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
adjacent = Path(__file__).resolve().parent / "adapter/interpreter.exe"
default = adjacent if adjacent.is_file() else root / "_build/default/bench/runtime_core/adapter/interpreter.exe"
executable = Path(os.environ.get("REN_CORE_INTERPRETER", str(default)))
if not executable.is_file():
    print("reference adapter not built: dune build bench/runtime_core/adapter/interpreter.exe", file=sys.stderr)
    raise SystemExit(77)
os.execv(str(executable), [str(executable)] + sys.argv[1:])

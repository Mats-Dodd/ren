#!/usr/bin/env python3
"""Syntax-check pending C traces, or link/run them against the real c3 adapter.

--syntax never claims that a core was tested. --run requires production
sources and the future hook adapter; it refuses absent implementation.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PREFIX = "REN_CORE_TEST_"
# Exact expected assertion is required: crashes, timeouts, compiler failures,
# or a different invariant do not demonstrate that a mutant was caught.
MUTANTS = [
    ("deliver-ref-cancel", "DISABLE_DELIVER_REF", "NoUseAfterFree"),
    ("deliver-ref-spurious", "DISABLE_DELIVER_REF", "NoUseAfterFree"),
    ("scope-end-ref", "DISABLE_SCOPE_REF", "NoUseAfterFree"),
    ("instance-handoff-ref", "DISABLE_HANDOFF_REF", "NoUseAfterFree"),
    ("until-signal-ref", "DISABLE_UNTIL_REF", "NoUseAfterFree"),
    ("retract-wake", "DISABLE_RETRACT_WAKE", "NoLostWake"),
    ("retract-other-call-in-flight", "DISABLE_RETRACT_WAKE", "NoLostWake"),
    ("stop-retract-wake", "DISABLE_RETRACT_WAKE", "NoLostWake"),
    ("stop-until-notify-all-live", "DISABLE_STOP_WALK", "NoLostWake"),
    ("stop-running-before-park", "STOP_PARKED_ONLY", "NoLostWake"),
    ("cancel-does-not-free-op", "CANCEL_FREES_OP", "NoDoubleFree"),
    ("reply-generation-cas", "DISABLE_REPLY_GENERATION", "StaleReplyNeverAccepted"),
    ("cancel-generation-cas-finally", "DISABLE_CANCEL_GENERATION", "StaleCancelNeverHits"),
    ("store-before-notify", "NOTIFY_BEFORE_STORE", "NoLostWake"),
    ("park-announcement-recheck", "DISABLE_PARK_RECHECK", "NoLostWake"),
    ("cancelled-task-waits-for-reply", "DISABLE_WAIT_REPLY", "CancelledTaskWaitsForReply"),
    ("take-lock-recheck", "DISABLE_TAKE_RECHECK", "NoLostWaiter"),
]
CASES = [row[0] for row in MUTANTS] + [
    "late-reply-release", "inline-reply", "duplicate-before-delivery",
    "stop-pulled-call", "stop-during-publish", "PING", "PINGY",
    "two-host-replier-threads", "all-nine-host-functions", "kill-driver-lease"]


def execute(argv, **kwargs):
    return subprocess.run(argv, timeout=30, check=False, **kwargs)


def build(cc, output, sources, flag=None, sanitize=None):
    options = ["-std=c11", "-g", "-O1", "-Wall", "-Wextra", "-Werror", "-pthread",
               "-DREN_CORE_TEST_HOOKS=1", "-I" + str(HERE),
               "-I" + str(ROOT / "lib/native/runtime")]
    if flag:
        options += ["-D" + PREFIX + flag + "=1"]
    if sanitize:
        options += ["-fsanitize=" + sanitize, "-fno-omit-frame-pointer"]
    result = execute(cc + options + [str(HERE / "core_protocol.c")] + sources + ["-o", str(output)])
    if result.returncode:
        raise RuntimeError("C core test build failed; this is not a caught mutant")
    actual = execute([str(output), "--compiled-mutant"], capture_output=True, text=True)
    expected = PREFIX + flag if flag else "none"
    if actual.returncode or actual.stdout.strip() != expected:
        raise RuntimeError("core adapter did not report the requested production mutation: " + expected)


def require_pass(binary, case):
    result = execute([str(binary), "--case", case], capture_output=True, text=True)
    if result.returncode or result.stdout != f"PASS {case}\n":
        raise RuntimeError(f"correct core failed {case}: {result.stdout}{result.stderr}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--syntax", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--sources", nargs="+", help="real core + hook adapter + existing runtime C sources")
    parser.add_argument("--sanitizers", action="store_true", help="also run correct core under ASan/UBSan and two host replies under TSan")
    args = parser.parse_args()
    if args.sources is None and os.environ.get("REN_CORE_TEST_SOURCES"):
        args.sources = json.loads(os.environ["REN_CORE_TEST_SOURCES"])
    cc = shlex.split(os.environ.get("REN_CC", "cc"))
    if args.syntax:
        # The Nix compiler wrapper also injects link-only flags into a
        # syntax-only command. Suppress that wrapper diagnostic only.
        version = execute(cc + ["--version"], capture_output=True).stdout.lower()
        wrapper_flags = ["-Wno-unused-command-line-argument"] if b"clang" in version else []
        result = execute(cc + ["-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread"] +
                         wrapper_flags + ["-fsyntax-only", str(HERE / "core_protocol.c")])
        if not result.returncode:
            print("C protocol traces: syntax checked; production core not linked")
        return result.returncode
    if not args.run and not args.case:
        parser.error("choose --syntax, --run or --case")
    adapter = ROOT / "lib/native/runtime/ren_core_test.c"
    if not args.sources and not adapter.is_file():
        print("SKIP c3: production ren_core_test.c hook adapter is not implemented", file=sys.stderr)
        return 77
    if not args.sources:
        parser.error("--sources must name the real core, hook adapter and existing runtime sources")
    sources = [str(Path(path).resolve(strict=True)) for path in args.sources]
    with tempfile.TemporaryDirectory(prefix="ren-core-tests-") as directory:
        binary = Path(directory) / "core-tests"
        build(cc, binary, sources)
        for case in [args.case] if args.case else CASES:
            require_pass(binary, case)
        for case, flag, invariant in MUTANTS:
            if args.case and case != args.case:
                continue
            build(cc, binary, sources, flag=flag)
            result = execute([str(binary), "--case", case], capture_output=True, text=True)
            marker = f"INVARIANT {invariant}: {case} at line "
            if result.returncode != 1 or marker not in result.stderr:
                raise RuntimeError(f"mutant {flag} did not fail its intended invariant {invariant}: "
                                   f"exit {result.returncode}: {result.stdout}{result.stderr}")
        if args.sanitizers:
            for sanitizer in ["address", "undefined", "thread"]:
                build(cc, binary, sources, sanitize=sanitizer)
                for case in (["two-host-replier-threads"] if sanitizer == "thread" else CASES):
                    require_pass(binary, case)
    print("production C core: rule-on, rule-off and requested sanitizer checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)

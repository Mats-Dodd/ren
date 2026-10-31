#!/usr/bin/env python3
"""Compare interpreter and native sim runs without choosing a future CLI.

Each adapter is a JSON argv array with {program}, {seed}, {journal} and
{mode} substitutions. An adapter must select sim, record to {journal}, and
return the program's exit status. Both see the same absolute paths. There
is no shell expansion. Native adapters may build before running, but must
keep build diagnostics off the program's stdout/stderr.
"""

import argparse
import contextlib
from types import SimpleNamespace
from dataclasses import dataclass
import json
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@dataclass
class Run:
    status: int
    stdout: bytes
    stderr: bytes
    journal: bytes


class Mismatch(Exception):
    pass


def difference(label, left, right):
    if left == right:
        return
    offset = next((i for i, pair in enumerate(zip(left, right))
                   if pair[0] != pair[1]), min(len(left), len(right)))
    raise Mismatch(f"{label}: first difference at byte {offset} "
                   f"(interpreter {len(left)} bytes, native {len(right)} bytes); "
                   f"interpreter {left[offset:offset + 32]!r}; "
                   f"native {right[offset:offset + 32]!r}")


def compare(left, right):
    if left.status != right.status:
        raise Mismatch(f"exit status: interpreter {left.status}, native {right.status}")
    difference("stdout", left.stdout, right.stdout)
    difference("stderr (including panic location)", left.stderr, right.stderr)
    difference("journal", left.journal, right.journal)


def run(adapter, program, seed, journal, mode, timeout):
    journal.unlink(missing_ok=True)
    fields = dict(program=str(program), seed=seed, journal=str(journal), mode=mode)
    argv = [arg.format_map(fields) for arg in adapter]
    result = subprocess.run(argv, cwd=program.parent, capture_output=True,
                            timeout=timeout, check=False)
    if not journal.is_file():
        raise Mismatch(f"adapter produced no journal: {argv[0]} (exit {result.returncode})")
    return Run(result.returncode, result.stdout, result.stderr, journal.read_bytes())


def first_view_difference(left, right):
    lines = (left.splitlines(), right.splitlines())
    count = max(len(lines[0]), len(lines[1]))
    for i in range(count):
        a = lines[0][i] if i < len(lines[0]) else b"<end>"
        b = lines[1][i] if i < len(lines[1]) else b"<end>"
        if a != b:
            return f"journal view line {i + 1}: interpreter {a!r}; native {b!r}"
    return "journal views agree; difference is in binary representation"


def journal_context(adapter, reference, native, journal, timeout):
    views = []
    for content in (reference, native):
        journal.write_bytes(content)
        command = [arg.format_map(dict(journal=str(journal))) for arg in adapter]
        result = subprocess.run(command, capture_output=True, timeout=timeout, check=False)
        if result.returncode != 0:
            return f"journal view failed: {result.stderr!r}"
        views.append(result.stdout)
    return first_view_difference(*views)


def argv(value):
    parsed = json.loads(value)
    if not isinstance(parsed, list) or not parsed or not all(isinstance(x, str) for x in parsed):
        raise argparse.ArgumentTypeError("adapter must be a nonempty JSON array of strings")
    return parsed


def conformance(args):
    program = args.program.resolve(strict=True)
    here = Path(__file__).resolve().parent
    interpreter = args.interpreter or [sys.executable, str(here / "interpreter.py"), "{program}", "{seed}", "{journal}"]
    native_adapter = args.native or [sys.executable, str(here / "native.py"), "{program}", "{seed}", "{journal}", "{mode}"]
    if args.test:
        if args.interpreter or args.native:
            raise Mismatch("--test uses the built-in adapters; include test-entry args in custom adapter arrays")
        interpreter += ["--test", args.test]
        native_adapter += ["--test", args.test]
    with tempfile.TemporaryDirectory(prefix="ren-conformance-") as directory:
        journal = Path(directory) / "run.journal"
        for seed in range(args.seed, args.seed + args.seeds):
            reference = native = None
            try:
                reference = run(interpreter, program, seed, journal, args.mode, args.timeout)
                native = run(native_adapter, program, seed, journal, args.mode, args.timeout)
                compare(reference, native)
            except (Mismatch, subprocess.TimeoutExpired) as error:
                print(f"FAIL {program}: seed {seed}, {args.mode}: {error}", file=sys.stderr)
                if args.journal_view and reference and native and reference.journal != native.journal:
                    try:
                        print(journal_context(args.journal_view, reference.journal,
                                              native.journal, journal, args.timeout), file=sys.stderr)
                    except subprocess.TimeoutExpired:
                        print("journal view timed out", file=sys.stderr)
                return 1
    print(f"conformant: {program.name}, {args.seeds} seeds from {args.seed}, {args.mode}")
    return 0


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.reference = Run(0, b"output\n", b"", b"\x00journal\xff")

    def test_identical(self):
        compare(self.reference, self.reference)

    def test_each_observable(self):
        for field, value, label in [("status", 1, "exit status"),
                                    ("stdout", b"wrong", "stdout"),
                                    ("stderr", b"panic at main.ren:3", "stderr"),
                                    ("journal", b"\x00journal\xfe", "byte 8")]:
            with self.subTest(field=field):
                changed = dict(vars(self.reference), **{field: value})
                with self.assertRaisesRegex(Mismatch, label):
                    compare(self.reference, Run(**changed))

    def test_truncated_journal(self):
        with self.assertRaisesRegex(Mismatch, "byte 1"):
            difference("journal", b"ab", b"a")

    def test_adapter_and_missing_journal(self):
        with tempfile.TemporaryDirectory(prefix="ren-harness-") as directory:
            program = Path(directory) / "main.ren"
            program.write_text("fn main() = ()\n")
            journal = Path(directory) / "run.journal"
            adapter = [sys.executable, "-c",
                       "import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b'\\x00\\xff'); print(sys.argv[2])",
                       "{journal}", "{seed}"]
            result = run(adapter, program, 47, journal, "debug", 5)
            self.assertEqual(result, Run(0, b"47\n", b"", b"\x00\xff"))
            with self.assertRaisesRegex(Mismatch, "no journal"):
                run([sys.executable, "-c", "pass"], program, 47, journal, "debug", 5)

    def test_view_names_first_call(self):
        message = first_view_difference(b"header\n1 main Fs.read(a)\n", b"header\n1 main Fs.read(b)\n")
        self.assertIn("line 2", message)
        self.assertIn("1 main Fs.read(a)", message)
        self.assertIn("1 main Fs.read(b)", message)

    def test_seed_loop_invokes_both_adapters(self):
        with tempfile.TemporaryDirectory(prefix="ren-loop-") as directory:
            program = Path(directory) / "main.ren"
            program.write_text("fn main() = ()\n")
            adapter = [sys.executable, "-c",
                       "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2]); print(sys.argv[2])",
                       "{journal}", "{seed}"]
            args = SimpleNamespace(program=program, interpreter=adapter, native=adapter,
                                   test=None, seed=7, seeds=2, mode="debug", timeout=5, journal_view=None)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(conformance(args), 0)
            self.assertIn("2 seeds from 7", output.getvalue())

    def test_timeout(self):
        with tempfile.TemporaryDirectory(prefix="ren-harness-") as directory:
            program = Path(directory) / "main.ren"
            program.touch()
            with self.assertRaises(subprocess.TimeoutExpired):
                run([sys.executable, "-c", "while True: pass"], program, 1,
                    Path(directory) / "run.journal", "debug", 0.05)


def main():
    if sys.argv[1:] == ["--self-test"]:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(HarnessTests)
        output = io.StringIO()
        result = unittest.TextTestRunner(stream=output, verbosity=0).run(suite)
        if result.wasSuccessful():
            print("conformance harness: 7 tests passed")
        else:
            print(output.getvalue(), file=sys.stderr)
        return 0 if result.wasSuccessful() else 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("program", type=Path)
    parser.add_argument("--interpreter", type=argv)
    parser.add_argument("--native", type=argv)
    parser.add_argument("--test", help="exact original source test name")
    parser.add_argument("--journal-view", type=argv, help="optional JSON argv, e.g. ren journal show {journal}; names the first differing call")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--seeds", type=int, default=1000)
    parser.add_argument("--mode", choices=["debug", "release", "asan", "ubsan", "tsan", "tcc"], default="debug")
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    if args.seeds <= 0 or args.timeout <= 0:
        parser.error("--seeds and --timeout must be positive")
    return conformance(args)


if __name__ == "__main__":
    raise SystemExit(main())

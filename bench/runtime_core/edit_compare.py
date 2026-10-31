#!/usr/bin/env python3
"""Compare exact per-declaration C artifacts across independent source edits.

The emitter is pending: ren build --scheduler sim --emit-declarations DIR.
Self-tests use synthetic manifests to validate this comparator only.
"""
import argparse
from dataclasses import dataclass
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
LINK_IDS = {"link:manifest", "link:relocations", "link:source-base-lines", "link:shape-slots"}
KNOWN = {"specializer-discovery-order-copy-name", "specializer-global-size-budget"}
RUNTIME_KINDS = {"frame", "entry", "resume", "resume-sites", "carry", "dispatcher", "abi-adapter"}


class EditFailure(Exception):
    pass


@dataclass(frozen=True)
class Artifact:
    id: str
    declaration: str
    copy_key: str
    kind: str
    content: bytes
    reads: tuple


def load(directory):
    directory = directory.resolve()
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest.get("version") != 1:
        raise EditFailure("unsupported declaration manifest version")
    artifacts = {}
    for row in manifest["artifacts"]:
        name = row["id"]
        if name in artifacts:
            raise EditFailure("duplicate artifact id: " + name)
        if row["kind"] == "link":
            if name not in LINK_IDS:
                raise EditFailure("unrecognized link-only exemption: " + name)
            continue
        path = (directory / row["file"]).resolve()
        if not path.is_relative_to(directory):
            raise EditFailure("artifact outside output directory: " + name)
        reads = tuple(sorted((read["fact"], read["hash"]) for read in row["reads"]))
        if len(dict(reads)) != len(reads):
            raise EditFailure("duplicate read fact: " + name)
        artifacts[name] = Artifact(name, row["declaration"], row["copy_key"],
                                   row["kind"], path.read_bytes(), reads)
    return artifacts


def digest(artifact):
    return hashlib.sha256(artifact.content).hexdigest()


def compare(before, after, policy, waivers=()):
    allowed = set(policy.get("declarations", []))
    allowed_new = set(policy.get("new_declarations", []))
    facts = set(policy.get("facts", []))
    known = []
    for name in sorted(before.keys() | after.keys()):
        old, new = before.get(name), after.get(name)
        if old is None:
            if new.declaration not in allowed_new:
                raise EditFailure("unexpected new artifact: " + name)
            continue
        if new is None:
            if old.declaration not in allowed:
                raise EditFailure("existing artifact disappeared: " + name)
            continue
        if (old.declaration, old.copy_key, old.kind) != (new.declaration, new.copy_key, new.kind):
            raise EditFailure("artifact identity changed: " + name)
        changed_reads = {fact for fact in dict(old.reads).keys() | dict(new.reads).keys()
                         if dict(old.reads).get(fact) != dict(new.reads).get(fact)}
        if changed_reads - facts and old.declaration not in allowed:
            raise EditFailure("unrelated recorded interface fact changed: " + name)
        if old == new:
            continue
        if old.declaration in allowed or changed_reads and changed_reads <= facts:
            continue
        matching = [w for w in waivers if w.get("edit") == policy["name"] and w.get("artifact") == name]
        if matching:
            w = matching[0]
            if (w.get("category") not in KNOWN or old.kind in RUNTIME_KINDS or
                    w.get("before") != digest(old) or w.get("after") != digest(new) or not w.get("reason")):
                raise EditFailure("invalid specializer exception: " + name)
            known.append((name, w["category"]))
            continue
        raise EditFailure("unrelated declaration bytes changed: " + name)
    return known


def emit(ren, program, output, mode):
    if output.exists():
        shutil.rmtree(output)
    command = ren + ["build", "--" + mode, "--scheduler", "sim",
                     "--emit-declarations", str(output), str(program)]
    result = subprocess.run(command, capture_output=True, timeout=120, check=False)
    if result.returncode:
        raise EditFailure("declaration emission failed (pending compiler support is not a pass): " +
                          result.stderr.decode(errors="replace"))
    if not (output / "manifest.json").is_file():
        raise EditFailure("compiler emitted no declaration manifest")
    return load(output)


def mutate(tree, policy):
    for action in policy["actions"]:
        target = tree / action["file"]
        if "write" in action:
            target.write_text(action["write"])
        else:
            text = target.read_text()
            if "prefix" in action:
                text = action["prefix"] + text
            if "replace" in action:
                old, new = action["replace"]
                if text.count(old) != 1:
                    raise EditFailure("edit target must occur once: " + action["file"])
                text = text.replace(old, new)
            target.write_text(text)


def run(args):
    fixture = args.fixture.resolve(strict=True)
    policies = json.loads((fixture / "edits.json").read_text())
    waivers = json.loads(args.known.read_text()) if args.known else []
    with tempfile.TemporaryDirectory(prefix="ren-edit-") as directory:
        tree, output = Path(directory) / "program", Path(directory) / "emitted"
        for mode in ["debug", "release"]:
            if tree.exists():
                shutil.rmtree(tree)
            shutil.copytree(fixture, tree)
            before = emit(args.ren, tree / "main.ren", output, mode)
            for policy in policies:
                shutil.rmtree(tree)
                shutil.copytree(fixture, tree)
                mutate(tree, policy)
                after = emit(args.ren, tree / "main.ren", output, mode)
                for name, category in compare(before, after, policy, waivers):
                    print(f"KNOWN {mode} {policy['name']} {name}: {category}")
                print(f"PASS {mode} {policy['name']}")
    return 0


class ComparatorTests(unittest.TestCase):
    def artifact(self, name="worker/f", content=b"C", reads=(), kind="function"):
        return Artifact(name, name, "Int", kind, content, reads)

    def test_exact_bytes(self):
        a = self.artifact()
        self.assertEqual(compare({a.id: a}, {a.id: a}, {"name": "lines"}), [])
        with self.assertRaisesRegex(EditFailure, "bytes changed"):
            compare({a.id: a}, {a.id: self.artifact(content=b"C ")}, {"name": "lines"})

    def test_recorded_inliner(self):
        a = self.artifact(reads=(("body:helper", "old"),))
        b = self.artifact(content=b"new inline", reads=(("body:helper", "new"),))
        compare({a.id: a}, {b.id: b}, {"name": "body", "facts": ["body:helper"]})

    def test_callee_size_cannot_invalidate_caller(self):
        a = self.artifact(reads=(("frame-size:callee", "16"),))
        b = self.artifact(content=b"sp += 32", reads=(("frame-size:callee", "32"),))
        with self.assertRaisesRegex(EditFailure, "unrelated recorded"):
            compare({a.id: a}, {b.id: b}, {"name": "grow", "declarations": ["callee"]})

    def test_new_copy_does_not_rename_old(self):
        a = self.artifact()
        b = self.artifact(name="worker/new")
        compare({a.id: a}, {a.id: a, b.id: b}, {"name": "add", "new_declarations": [b.id]})
        with self.assertRaisesRegex(EditFailure, "disappeared"):
            compare({a.id: a}, {b.id: b}, {"name": "add", "new_declarations": [b.id]})

    def test_runtime_artifacts_never_waived(self):
        a = self.artifact(kind="frame")
        b = self.artifact(kind="frame", content=b"new frame")
        waiver = dict(edit="e", artifact=a.id, category=next(iter(KNOWN)),
                      before=digest(a), after=digest(b), reason="documented")
        with self.assertRaisesRegex(EditFailure, "invalid specializer"):
            compare({a.id: a}, {b.id: b}, {"name": "e"}, [waiver])

    def test_known_exception_requires_exact_bytes(self):
        a, b = self.artifact(), self.artifact(content=b"existing known naming break")
        waiver = dict(edit="e", artifact=a.id, category="specializer-discovery-order-copy-name",
                      before=digest(a), after=digest(b), reason="pre-existing specializer")
        self.assertEqual(len(compare({a.id: a}, {b.id: b}, {"name": "e"}, [waiver])), 1)
        waiver["after"] = "different"
        with self.assertRaises(EditFailure):
            compare({a.id: a}, {b.id: b}, {"name": "e"}, [waiver])

    def test_manifest_path_and_link_exemption(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            row = dict(id="link:runtime", kind="link")
            (path / "manifest.json").write_text(json.dumps(dict(version=1, artifacts=[row])))
            with self.assertRaisesRegex(EditFailure, "link-only"):
                load(path)
            row.update(id="function", declaration="function", copy_key="", kind="function",
                       file="../outside", reads=[])
            (path / "manifest.json").write_text(json.dumps(dict(version=1, artifacts=[row])))
            with self.assertRaisesRegex(EditFailure, "outside output"):
                load(path)


def main():
    if sys.argv[1:] == ["--self-test"]:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ComparatorTests)
        output = io.StringIO()
        result = unittest.TextTestRunner(stream=output).run(suite)
        if result.wasSuccessful():
            print(f"declaration comparator: {result.testsRun} tests passed; compiler emission pending")
        else:
            print(output.getvalue(), file=sys.stderr)
        return 0 if result.wasSuccessful() else 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--ren", type=json.loads, default=["ren"], help="JSON command argv")
    parser.add_argument("--known", type=Path, help="exact artifact/hash exceptions for the two existing specializer breaks")
    return run(parser.parse_args())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (EditFailure, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)

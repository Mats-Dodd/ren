#!/usr/bin/env python3
"""The grammar against the compiler: every program the compiler parses has
to parse here too, without an error.

The programs are every example under examples/, the data stage's
programs under bench/data/, and every Ren snippet in the compiler's tests
(test/*.ml), the `{|...|}` strings that aren't an expected output. Each
is parsed by the compiler (`ren ast`) and by tree-sitter.

  compiler parses it, tree-sitter doesn't   a bug in the grammar: fails
  tree-sitter parses it, compiler doesn't   expected: the compiler also
                                            checks things a grammar
                                            doesn't, such as a `pub`
                                            import or a misaligned line;
                                            counted, and listed with -v

Run from anywhere, after `dune build` and `npm install`:

  python3 editors/tree-sitter-ren/differential.py [-v]
"""

import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
REN = ROOT / "_build" / "default" / "bin" / "main.exe"
TREE_SITTER = HERE / "node_modules" / ".bin" / "tree-sitter"

# {|...|} and {id|...|id}, OCaml's quoted strings
QUOTED = re.compile(r"\{([a-z_]*)\|(.*?)\|\1\}", re.S)


def snippets():
    """(name, source) for every Ren program the tests and examples hold."""
    # a test of a string that isn't UTF-8 holds bytes that aren't: they're
    # kept as they are, as the compiler reads them
    for f in sorted((ROOT / "examples").rglob("*.ren")):
        yield str(f.relative_to(ROOT)), f.read_text(errors="surrogateescape")
    for f in sorted((ROOT / "bench" / "data").glob("*.ren")):
        yield str(f.relative_to(ROOT)), f.read_text(errors="surrogateescape")
    for f in sorted((ROOT / "test").glob("*.ml")):
        text = f.read_text(errors="surrogateescape")
        for m in QUOTED.finditer(text):
            # an expected output, `[%expect {| ... |}]`
            if "%expect" in text[max(0, m.start() - 20) : m.start()]:
                continue
            line = text.count("\n", 0, m.start()) + 1
            yield f"{f.relative_to(ROOT)}:{line}", m.group(2)


def compiler_parses(path):
    r = subprocess.run([REN, "ast", path], capture_output=True)
    return r.returncode == 0


def tree_sitter_failures(paths):
    """The paths tree-sitter parses with an ERROR or MISSING node."""
    r = subprocess.run(
        [TREE_SITTER, "parse", "-q", *map(str, paths)],
        capture_output=True,
        text=True,
        cwd=HERE,
    )
    failed = set()
    for line in r.stdout.splitlines():
        path = line.split("\t", 1)[0].strip()
        if path:
            failed.add(path)
    return failed


def main():
    verbose = "-v" in sys.argv
    for tool in (REN, TREE_SITTER):
        if not tool.exists():
            sys.exit(f"missing {tool}: run `dune build` and `npm install` first")

    with tempfile.TemporaryDirectory() as tmp:
        files = []
        for i, (name, src) in enumerate(snippets()):
            p = pathlib.Path(tmp) / f"{i}.ren"
            p.write_text(src, errors="surrogateescape")
            files.append((name, p, src))

        accepted = {str(p) for _, p, _ in files if compiler_parses(p)}
        failed = tree_sitter_failures(p for _, p, _ in files)

        bugs = [f for f in files if str(f[1]) in accepted and str(f[1]) in failed]
        lenient = [
            f for f in files if str(f[1]) not in accepted and str(f[1]) not in failed
        ]

        for name, p, src in bugs:
            print(f"FAIL {name}: the compiler parses it, the grammar doesn't")
            tree = subprocess.run(
                [TREE_SITTER, "parse", str(p)], capture_output=True, text=True, cwd=HERE
            ).stdout
            src = src.encode(errors="surrogateescape").decode(errors="replace")
            print("\n".join("    " + l for l in src.strip("\n").splitlines()))
            for l in tree.splitlines():
                if "ERROR" in l or "MISSING" in l:
                    print("  " + l.strip())
            print()
        if verbose:
            for name, _, _ in lenient:
                print(f"lenient {name}")

        print(
            f"{len(files)} programs: {len(accepted)} the compiler parses, "
            f"{len(bugs)} of those the grammar doesn't; "
            f"{len(lenient)} the grammar parses that the compiler rejects"
        )
        sys.exit(1 if bugs else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""count_unsafe.py [FILE|DIR ...]: lines of Rust code inside `unsafe`.

Counts LINES, not keywords: a line counts if it holds code (not blank, not
only a comment) and lies inside the braces of
  - an `unsafe { ... }` block,
  - the body of an `unsafe fn` (any ABI: `unsafe extern "C" fn`), or
  - (reported separately) an `unsafe impl ... { ... }`.
Nested regions count once (the union of lines). The line holding the
opening `unsafe ... {` counts too. Comments and string/char literals are
stripped first, so braces in them do not confuse the matcher.

Default input: ../core/src ../hot/src (the shipped code, not tests).
Output: one row per file, then totals, as a table.
"""
import os
import re
import sys


def strip(src):
    """Blank out comments and literals, keeping newlines (line numbers stay)."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j): depth += 1; j += 2
                elif src.startswith("*/", j): depth -= 1; j += 2
                else: j += 1
            out.append(re.sub(r"[^\n]", " ", src[i:j])); i = j
        elif c == "r" and re.match(r'r#*"', src[i:]) and (i == 0 or not (src[i-1].isalnum() or src[i-1] == "_")):
            m = re.match(r'r(#*)"', src[i:]); close = '"' + m.group(1)
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            out.append(re.sub(r"[^\n]", " ", src[i:j])); i = j
        elif c == '"' or (c in "bc" and i + 1 < n and src[i+1] == '"' and (i == 0 or not (src[i-1].isalnum() or src[i-1] == "_"))):
            j = i + (2 if c != '"' else 1)
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            j += 1
            out.append(re.sub(r"[^\n]", " ", src[i:j])); i = j
        elif c == "'":
            m = re.match(r"'(\\.|\\u\{[0-9a-fA-F]+\}|\\x[0-9a-fA-F]{2}|[^\\'])'", src[i:])
            if m:
                out.append(" " * len(m.group(0))); i += len(m.group(0))
            else:
                out.append(c); i += 1  # a lifetime
        else:
            out.append(c); i += 1
    return "".join(out)


def match_brace(s, open_at):
    depth = 0
    for j in range(open_at, len(s)):
        if s[j] == "{": depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                return j
    return len(s) - 1


def regions(s):
    """(kind, start_offset, end_offset) for every unsafe region."""
    res = []
    for m in re.finditer(r"\bunsafe\b", s):
        k = m.end()
        rest = s[k:]
        r = re.match(r"\s*\{", rest)
        if r:
            ob = k + r.end() - 1
            res.append(("block", m.start(), match_brace(s, ob)))
            continue
        r = re.match(r'\s*(extern\s*(\s*"[^"]*")?\s*)?fn\b', rest)
        r2 = re.match(r"\s*impl\b", rest)
        if r or r2:
            # the body: the first '{' at paren/angle depth 0 after the signature, unless a ';' comes first
            j, par = k, 0
            while j < len(s):
                ch = s[j]
                if ch in "([": par += 1
                elif ch in ")]": par -= 1
                elif ch == ";" and par == 0: j = -1; break
                elif ch == "{" and par == 0: break
                j += 1
            if j > 0:
                res.append(("fn" if r else "impl", m.start(), match_brace(s, j)))
    return res


def count_file(path):
    raw = open(path, encoding="utf-8").read()
    s = strip(raw)
    lines = s.split("\n")
    code = {i for i, l in enumerate(lines) if l.strip()}
    line_of = []
    for i, l in enumerate(lines):
        line_of.extend([i] * (len(l) + 1))
    sets = {"block": set(), "fn": set(), "impl": set()}
    for kind, a, b in regions(s):
        sets[kind] |= set(range(line_of[a], line_of[min(b, len(line_of) - 1)] + 1)) & code
    unsafe_code = sets["block"] | sets["fn"]
    return len(code), len(unsafe_code), len(sets["fn"]), len(sets["block"] - sets["fn"]), len(sets["impl"])


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    roots = argv or [os.path.join(here, "../core/src"), os.path.join(here, "../hot/src")]
    files = []
    for r in roots:
        if os.path.isdir(r):
            for d, _, fs in os.walk(r):
                files += [os.path.join(d, f) for f in fs if f.endswith(".rs")]
        else:
            files.append(r)
    tot = [0] * 5
    print(f"{'file':44} {'code':>6} {'unsafe':>7} {'in fn':>6} {'block':>6} {'impl':>5} {'%':>6}")
    for f in sorted(files):
        c = count_file(f)
        tot = [a + b for a, b in zip(tot, c)]
        rel = os.path.relpath(f, os.path.join(here, ".."))
        print(f"{rel:44} {c[0]:6} {c[1]:7} {c[2]:6} {c[3]:6} {c[4]:5} {100*c[1]/max(c[0],1):5.1f}%")
    print(f"{'TOTAL':44} {tot[0]:6} {tot[1]:7} {tot[2]:6} {tot[3]:6} {tot[4]:5} {100*tot[1]/max(tot[0],1):5.1f}%")
    print("code = non-blank, non-comment lines; unsafe = lines inside unsafe blocks or unsafe fn bodies "
          "(union); 'in fn' = inside unsafe fn bodies; 'block' = in unsafe blocks outside unsafe fns; "
          "impl = lines of unsafe impl items (not in 'unsafe').")


if __name__ == "__main__":
    main(sys.argv[1:])

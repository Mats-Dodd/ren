#!/usr/bin/env python3
"""Strict differential targets for stage 12a; disabled stages are explicit skips."""
import os
import re
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
ENABLED = set(ROOT.joinpath("stages").read_text().splitlines())
REN = shutil.which("ren")


def run(argv, *, cwd, env=None):
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True)
    return result.returncode, result.stdout, result.stderr


def checked(argv, *, cwd, env=None):
    status, out, err = run(argv, cwd=cwd, env=env)
    if status:
        raise AssertionError(f"{argv!r} failed ({status}):\n{out!r}\n{err!r}")
    return out, err


def differential(stage, name, source, expected):
    if stage not in ENABLED:
        print(f"{name}: until {stage}")
        return
    assert REN, "ren is required"
    with tempfile.TemporaryDirectory(prefix="ren-shapes-") as work:
        path = Path(work) / "main.ren"
        path.write_text(source)
        reference = run([REN, "run", str(path)], cwd=work)
        assert reference == (0, expected.encode(), b""), reference
        assert run([REN, "run", "--release", str(path)], cwd=work) == reference
        for mode in ("debug", "debug-naive", "release", "release-naive", "tcc"):
            env = dict(os.environ, REN_NOTES="0")
            env["ASAN_OPTIONS"] = "detect_stack_use_after_return=0:detect_leaks=0"
            env["UBSAN_OPTIONS"] = "halt_on_error=1"
            env["REN_CC"] = (env.get("REN_TCC") or "tcc") if mode == "tcc" else "cc"
            env["REN_CFLAGS"] = "" if mode == "tcc" else "-fsanitize=address,undefined"
            binary = str(Path(work) / "program")
            argv = [REN, "build", "--stats", "--release" if mode.startswith("release") else "--debug"]
            if mode.endswith("naive"):
                argv += ["--rc", "naive"]
            checked(argv + [str(path), "-o", binary], cwd=work, env=env)
            status, out, err = run([binary], cwd=work, env=env)
            stats = [line for line in err.splitlines() if line.startswith(b"ren stats:")]
            assert stats and b"objects live at exit 0" in err, (name, mode, err)
            clean_err = b"".join(line + b"\n" for line in err.splitlines()
                                 if not line.startswith(b"ren stats:"))
            assert (status, out, clean_err) == reference, (name, mode, err)
    print(f"{name}: interpreter, release run, sanitizers and tcc agree")


def freezing(force=False):
    if not force and "s8" not in ENABLED:
        print("freezing: until s8")
        return
    assert REN, "ren is required"
    source = '''import json
type Id = opaque Int
  pub fn read_id(n: Int) -> Id = n
  pub fn write_id(self) -> Int = self
fn unrelated(n: Int) -> Int = n
type Order = { id: Id }
format wire for Id = Int via (Id.read_id, fn(n) => n.write_id())
format v1 for Order =
  id: Id.wire
  ..
let API = json.settings(formats: [Order.v1])
fn main() = try json.decode<Order>("{\\"id\\":1}", API)
'''
    mutations = [
        ("field", "type Order = { id: Id }", "type Order = { id: Id, extra: Int = 0 }"),
        ("via", "fn read_id(n: Int) -> Id = n", "fn read_id(n: Int) -> Id = n + 1"),
        ("look", "v1", "v2"),
    ]
    with tempfile.TemporaryDirectory(prefix="ren-shapes-freeze-") as work:
        path = Path(work) / "main.ren"
        path.write_text(source)
        checked([REN, "formats", "freeze", "API"], cwd=work)
        lock = Path(work) / "formats.lock"
        assert lock.is_file(), "freeze must save formats.lock"
        saved_lock = lock.read_bytes()
        checked([REN, "check", "main.ren"], cwd=work)
        path.write_text(source.replace("fn unrelated(n: Int) -> Int = n",
                                       "fn unrelated(n: Int) -> Int = n + 1"))
        checked([REN, "check", "main.ren"], cwd=work)
        for name, before, after in mutations:
            path.write_text(source.replace(before, after))
            code, out, err = run([REN, "check", "main.ren"], cwd=work)
            diagnostic = out + err
            assert code != 0 and b"API" in diagnostic and b"frozen" in diagnostic, (name, diagnostic)
            assert lock.read_bytes() == saved_lock, "a rejected build must not rewrite the lock"
        path.write_text(source)
        checked([REN, "check", "main.ren"], cwd=work)
    print("freezing: unchanged passes; field, via and look-name changes fail")


def native_invariants():
    if "s2" not in ENABLED:
        print("static C: until s2")
    else:
        with tempfile.TemporaryDirectory(prefix="ren-shapes-static-") as work:
            path = Path(work) / "main.ren"
            path.write_text('''let CRC_TABLE = crc_table()
fn crc_table() -> Array<Int> = [0, 1, 3, 2]
fn main() uses Console = print(CRC_TABLE)
''')
            for mode in ("--debug", "--release"):
                code, _ = checked([REN, "build", mode, "--emit-c", str(path)], cwd=work)
                assert b"static " in code, "computed value must have static storage"
                starts = re.findall(rb"static void ren_program\(void\) \{(.*?)\n\}", code, re.S)
                assert len(starts) == 1, "inspect the emitted C entry when its spelling changes"
                startup = starts[0]
                assert not re.search(rb"\b[A-Za-z_0-9]*crc_table[A-Za-z_0-9]*\s*\(", startup), \
                    "startup must not call the build-time computation"
                assert not re.search(rb"\b[A-Za-z_0-9]*CRC_TABLE[A-Za-z_0-9]*\s*=", startup), \
                    "startup must not initialize the frozen value"
            path.write_text("assert 2 + 2 == 5\nfn main() = ()\n")
            for command in ([REN, "check", str(path)], [REN, "run", str(path)],
                            [REN, "test", str(path)],
                            [REN, "build", "--debug", str(path), "-o", str(Path(work) / "bad")]):
                status, out, err = run(command, cwd=work)
                diagnostic = out + err
                assert status != 0 and b"assert" in diagnostic and b"building" in diagnostic, (command, diagnostic)
        print("static C: no build-time function or startup call")
    if "s3" not in ENABLED:
        print("template allocations: until s3")
    else:
        with tempfile.TemporaryDirectory(prefix="ren-shapes-template-") as work:
            path = Path(work) / "main.ren"
            for count in (0, 1, 4, 17, 64):
                holes = " ".join("\\{i + " + str(j) + "}" for j in range(count))
                path.write_text('fn consume<H>(t: Template<H>, count: Int) -> Int =\n'
                                '  let right_count = t.site().parts.len() == count + 1\n'
                                '  assert right_count\n'
                                '  t.holes().hash()\n'
                                'fn main() =\n'
                                '  var i = 0\n'
                                '  while i < 100\n'
                                '    let a = consume(t"' + holes + '", ' + str(count) + ')\n'
                                '    let b = consume(t"' + holes + '", ' + str(count) + ')\n'
                                '    let same = a == b\n'
                                '    assert same\n'
                                '    i += 1\n')
                for mode in ("--debug", "--release"):
                    binary = str(Path(work) / "program")
                    checked([REN, "build", mode, "--stats", str(path), "-o", binary], cwd=work)
                    _, err = checked([binary], cwd=work)
                    assert b"ren stats: allocations 0," in err, (count, mode, err)
        print("template allocations: zero for 0, 1, 4, 17 and 64 holes")
    if "s7" not in ENABLED:
        print("copy names: until s7")
    else:
        with tempfile.TemporaryDirectory(prefix="ren-shapes-keys-") as work:
            path = Path(work) / "main.ren"
            prefix = 'fn planned(n: Int) -> Int\n  let plan = n * 2\n= plan\n'
            copies = []
            for earlier in (False, True):
                path.write_text(prefix + 'fn main() uses Console =\n'
                                + ('  print(planned(1))\n' if earlier else '')
                                + '  print(planned(2))\n')
                out, _ = checked([REN, "core", "--release", str(path)], cwd=work)
                names = set(re.findall(rb"\(fn (planned\$[^\s()]+)", out))
                assert names, "release must expose keyed copies for signature constants"
                copies.append(names)
            assert copies[0] < copies[1], copies
        print("copy names: adding an earlier site preserves every existing key")


def explain():
    if "s4" not in ENABLED:
        print("walk and explain: until s4")
        return
    source = '''import json
type OrderId = opaque Int
  pub fn parse(n: Int) -> OrderId = n
  pub fn repr(self) -> Int = self
type CustomerId = opaque Int
  pub fn parse(n: Int) -> CustomerId = n
  pub fn repr(self) -> Int = self
type Money = opaque Int
  pub fn parse(s: Str) -> Money = 0
  pub fn repr(self) -> Str = "money"
  pub fn from_cents(n: Int) -> Money = n
  pub fn cents(self) -> Int = self
type Time = opaque Int
  pub fn parse(s: Str) -> Time = 0
  pub fn repr(self) -> Str = "time"
  pub fn from_unix(n: Int) -> Time = n
  pub fn unix_seconds(self) -> Int = self
type Order = { id: OrderId, customer: CustomerId, total: Money, placed: Time }
format cents for Money = Int via (Money.from_cents, fn(m) => m.cents())
format unix for Time = Int via (Time.from_unix, fn(t) => t.unix_seconds())
format v1 for Order =
  kind = "order"
  id
  customerId = customer
  total: Money.cents
  placed
let API = json.settings(formats: [Time.unix, Order.v1])
fn main() = ()
'''
    expected = '''Order                 Order.v1             (2: the caller)
  kind                "order"              constant
  id         -> id    Int                  (3: OrderId.repr)
  customer   -> customerId  Int            (3: CustomerId.repr)
  total      -> total Int                  (1: Money.cents, named in Order.v1)
  placed     -> placed Int                 (2: Time.unix)
'''
    with tempfile.TemporaryDirectory(prefix="ren-shapes-explain-") as work:
        path = Path(work) / "main.ren"
        path.write_text(source)
        out, err = checked([REN, "explain", "API", "for", "Order"], cwd=work)
        assert (out, err) == (expected.encode(), b""), (out, err)
    print("walk and explain: exactly the spec's precedence table")


def unit_runtime_targets():
    # Use the same literal source and fixed output as the interpreter tests.
    # Generated-vector bodies have their own explicit bin targets; this
    # extractor refuses an empty inventory, rather than claiming no work.
    text = ROOT.parents[1].joinpath("test/test_shapes.ml").read_text()
    pattern = re.compile(r'\boutput\s*\{\|(.*?)\|\}\s*("(?:[^"\\]|\\.)*")', re.S)
    cases = list(pattern.finditer(text))
    assert len(cases) == 42, "literal runtime-target inventory changed; review coverage explicitly"
    quoted = r'"(?:[^"\\]|\\.)*"'
    raw = r'\{\|.*?\|\}'
    vector_pattern = re.compile(r'\((' + quoted + r'),\s*(' + quoted + '|' + raw
                                + r'),\s*(' + raw + r')\)', re.S)
    vector_text = text.split("let vectors =", 1)[1].split("\n      in", 1)[0]
    vectors = vector_pattern.findall(vector_text)
    assert len(vectors) == 23, "all scalar/collection golden vector entries must be discovered"
    malformed_text = text.split('let%expect_test "[s5] bin rejects malformed', 1)[1].split('let%expect_test', 1)[0]
    malformed = re.findall(r'\((' + quoted + r'),\s*(' + raw + r')\)', malformed_text, re.S)
    assert len(malformed) == 8, "all malformed binary vectors must be discovered"
    if "s7" not in ENABLED:
        print("unit runtime targets: native until s7")
        return
    for index, case in enumerate(cases):
        expected = json.loads(case.group(2))
        assert expected.endswith("()\n"), "expected output must include Helpers.run's Unit result"
        expected = expected[:-3]
        differential("s7", f"unit_runtime_{index + 1}", case.group(1), expected)
    for index, (type_text, value_text, bytes_text) in enumerate(vectors):
        type_ = json.loads(type_text)
        value = value_text[2:-2] if value_text.startswith("{|") else json.loads(value_text)
        bytes_ = bytes_text[2:-2]
        source = ("import bin\nfn main() uses Console =\n  let v: " + type_ + " = " + value
                  + "\n  print(try bin.encode(v) == " + bytes_ + ")\n  print(try bin.decode<"
                  + type_ + ">(" + bytes_ + ") == v)\n")
        differential("s7", f"bin_vector_{index + 1}", source, "true\ntrue\n")
    for index, (type_text, bytes_text) in enumerate(malformed):
        source = ("import bin\nfn main() uses Console =\n  print(match attempt bin.decode<"
                  + json.loads(type_text) + ">(" + bytes_text[2:-2]
                  + ")\n    Ok(_) => false\n    Err(_) => true)\n")
        differential("s7", f"malformed_bin_{index + 1}", source, "true\n")


if "--freeze-only" in sys.argv:
    freezing(force=True)
    sys.exit(0)

differential("s1", "front_end", '''fn id<T>(x: T) -> T = x
type Cfg = { port: Int = 8080 }
fn main() uses Console =
  let cfg: Cfg = {}
  print(id<Int>(cfg.port))
''', "8080\n")
differential("s2", "static_data", '''let CRC_TABLE = [0, 1, 3, 2]
assert CRC_TABLE.len() == 4
fn main() uses Console = print(CRC_TABLE)
''', "[0, 1, 3, 2]\n")
differential("s3", "template", '''fn consume<H>(t: Template<H>) -> Str = t.render()
fn main() uses Console =
  let x = 7
  print(consume(t"value \\{x=}"))
''', "value x=7\n")
differential("s7", "json", '''import json
type User = { id: Int, name: Str = "anonymous", email: Option<Str> }
fn main() uses Console =
  print(try json.encode(try json.decode<User>("{\\"id\\":7}")))
''', '{"id":7,"name":"anonymous"}\n')
differential("s7", "bin", '''import bin
type Packet = { id: Int, note: Option<Str> }
fn main() uses Console =
  let p: Packet = { id: -1, note: Some("ok") }
  print(try bin.decode<Packet>(try bin.encode(p)) == p)
''', "true\n")
freezing()
native_invariants()
explain()
unit_runtime_targets()

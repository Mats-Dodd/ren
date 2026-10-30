"""Prints the tables in RESULTS.md from what measure.sh wrote:

    python3 -I bench/native/summarize.py RESULTS_FOLDER

Times are hyperfine's mean, in seconds, with its standard deviation;
ratios are of means. Memory is the peak resident set size, in MB.
"""

import json
import os
import sys

res = sys.argv[1]


def timing(name):
    """hyperfine's results in [name].json, by command name."""
    path = os.path.join(res, name + ".json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            results = json.load(f)["results"]
    except ValueError:  # still being written
        return {}
    out = {}
    for r in results:
        if "summary" in r:  # hyperfine 2's schema
            wall = r["summary"]["time_wall_clock"]
            r = {"name": r["name"], "mean": wall["mean"], "stddev": wall["stddev"]}
        out[r.get("name") or r["command"]] = r
    return out


def tsv(name):
    out = {}
    path = os.path.join(res, name)
    if os.path.exists(path):
        for line in open(path):
            if "\t" in line:
                k, v = line.rstrip("\n").split("\t", 1)
                out[k] = v
    return out


stats_lines = tsv("stats.tsv")
memory = tsv("memory.tsv")
lines = tsv("lines.tsv")


def stats(binary):
    """The counts a --stats build printed, by name."""
    line = stats_lines.get(binary, "")
    out = {}
    for part in line.replace("ren stats:", "").split(","):
        words = part.split()
        if words:
            out[" ".join(words[:-1])] = int(words[-1])
    return out


def secs(r):
    return "%.3f ± %.3f" % (r["mean"], r["stddev"]) if r else "–"


def ratio(a, b):
    return "%.2f×" % (a["mean"] / b["mean"]) if a and b else "–"


def mb(binary):
    # /usr/bin/time -l on macOS reports bytes
    v = memory.get(binary)
    return "%.1f" % (int(v) / 1e6) if v else "–"


def mratio(a, b):
    x, y = memory.get(a), memory.get(b)
    return "%.2f×" % (int(x) / int(y)) if x and y else "–"


def count(n):
    return "{:,}".format(n) if n is not None else "–"


def table(head, rows):
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for r in rows:
        print("| " + " | ".join(r) + " |")
    print()


print("### H1: blocks against loops, release\n")
rows = []
for k in ["map", "reduce", "each", "fold", "attempt"]:
    t = timing("h1-" + k)
    b, l = t.get(k + "_blocks-perceus"), t.get(k + "_loop-perceus")
    sb = stats("blocks-%s_blocks-debug-stats" % k)
    sl = stats("blocks-%s_loop-debug-stats" % k)
    rb = stats("blocks-%s_blocks-perceus-stats" % k)
    rl = stats("blocks-%s_loop-perceus-stats" % k)
    rows.append(
        [
            k,
            secs(b),
            secs(l),
            ratio(b, l),
            "%s / %s" % (count(sb.get("allocations")), count(sl.get("allocations"))),
            "%s / %s" % (count(rb.get("allocations")), count(rl.get("allocations"))),
            "%s / %s" % (count(sb.get("block calls")), count(rb.get("block calls"))),
        ]
    )
table(
    [
        "kernel",
        "blocks (s)",
        "loop (s)",
        "blocks / loop",
        "allocations debug, blocks / loop",
        "allocations release, blocks / loop",
        "block calls, debug / release",
    ],
    rows,
)

print("### H2: an operation of a known handler, 10^9 calls\n")
t = timing("h2")
rows = []
for build, label in [
    ("perceus", "release"),
    ("debug", "debug (-O0)"),
    ("debug-O2", "debug strategy at -O2"),
]:
    w, f = t.get("with-" + build), t.get("function-" + build)
    rows.append(
        [
            label,
            "%.2f" % w["mean"] if w else "–",
            "%.2f" % f["mean"] if f else "–",
            ratio(w, f),
        ]
    )
table(["build", "`Counter.bump` (ns/call)", "plain call (ns/call)", "ratio"], rows)

perceus_set = ["rbtree", "deriv", "nqueens", "cfold"]
print("### H3: counting, Perceus against naive\n")
rows = []
for p in perceus_set:
    s, n = stats(p + "-perceus-stats"), stats(p + "-naive-stats")
    sp = s.get("dups", 0) + s.get("drops", 0)
    sn = n.get("dups", 0) + n.get("drops", 0)
    t = timing(p)
    rows.append(
        [
            p,
            count(sp),
            count(sn),
            "%.1f×" % (sn / sp) if sp else "–",
            count(s.get("reuses")),
            secs(t.get("perceus")),
            secs(t.get("naive")),
            secs(t.get("rust")),
            ratio(t.get("perceus"), t.get("rust")),
            ratio(t.get("naive"), t.get("rust")),
        ]
    )
table(
    [
        "program",
        "dups + drops, Perceus",
        "naive",
        "naive / Perceus",
        "reuses",
        "Perceus (s)",
        "naive (s)",
        "Rust (s)",
        "Perceus / Rust",
        "naive / Rust",
    ],
    rows,
)

print("### H4: allocations and peak memory, Perceus against naive\n")
rows = []
for p, name in [
    ("rbtree", "rbtree"),
    ("blocks-map_unique", "map over a unique array"),
    ("fannkuch", "fannkuch"),
    ("deriv", "deriv"),
    ("nqueens", "nqueens"),
    ("cfold", "cfold"),
]:
    s, n = stats(p + "-perceus-stats"), stats(p + "-naive-stats")
    rows.append(
        [
            name,
            count(s.get("allocations")),
            count(n.get("allocations")),
            count(s.get("peak live bytes")),
            count(n.get("peak live bytes")),
            mb(p + "-perceus"),
            mb(p + "-naive"),
        ]
    )
table(
    [
        "program",
        "allocations, Perceus",
        "naive",
        "peak live bytes, Perceus",
        "naive",
        "peak RSS MB, Perceus",
        "naive",
    ],
    rows,
)

print("### H5: restrict\n")
rows = []
for p in ["inout", "fannkuch", "nbody"]:
    t = timing(p)
    rows.append(
        [
            p,
            secs(t.get("perceus")),
            secs(t.get("norestrict")),
            ratio(t.get("norestrict"), t.get("perceus")),
            secs(t.get("rust")),
        ]
    )
table(["program", "restrict (s)", "--no-restrict (s)", "without / with", "Rust (s)"], rows)

print("### H6: source to binary, debug\n")
rows = []
for n in ["10000", "100000", "500000"]:
    r, g = timing("h6-ren-" + n), timing("h6-go-" + n)
    if not r:
        continue
    rl, gl = int(lines.get("ren" + n, 0)), int(lines.get("go" + n, 0))
    tot, clean = r.get("total"), g.get("clean")
    rows.append(
        [
            "%s (%s / %s lines)" % (n, "{:,}".format(rl), "{:,}".format(gl)),
            secs(tot),
            secs(r.get("front")),
            secs(r.get("cc")),
            secs(clean),
            secs(g.get("clean-std-cached")),
            ratio(tot, g.get("clean-std-cached")),
            secs(r.get("leaf-edit")),
            secs(g.get("leaf-edit")),
            "%s / %s"
            % (
                "{:,.0f}".format(rl / tot["mean"]) if tot else "–",
                "{:,.0f}".format(gl / clean["mean"]) if clean else "–",
            ),
        ]
    )
table(
    [
        "program",
        "ren build --debug (s)",
        "front half + C (s)",
        "cc -O0 (s)",
        "go build, clean (s)",
        "go build, std cached (s)",
        "Ren / Go std cached",
        "Ren, leaf edit (s)",
        "Go, leaf edit (s)",
        "lines/s, Ren / Go clean",
    ],
    rows,
)

print("### H7: against Rust and Go\n")
rows = []
for p in perceus_set + ["binary-trees", "nbody", "fannkuch"]:
    t = timing(p)
    ren, rust, go = t.get("perceus"), t.get("rust"), t.get("go")
    rows.append(
        [
            p,
            secs(ren),
            secs(rust),
            secs(go),
            ratio(ren, rust),
            ratio(ren, go),
            mb(p + "-perceus"),
            mb(p + "-rust"),
            mb(p + "-go"),
            mratio(p + "-perceus", p + "-rust"),
        ]
    )
table(
    [
        "program",
        "Ren (s)",
        "Rust (s)",
        "Go (s)",
        "Ren / Rust",
        "Ren / Go",
        "Ren MB",
        "Rust MB",
        "Go MB",
        "memory, Ren / Rust",
    ],
    rows,
)

print("### The data stage's milestone: interp, ADT-first\n")
t = timing("interp")
adt, enum, dyn, desc = (
    t.get("ren-adt"),
    t.get("rust-enum"),
    t.get("rust-dyn"),
    t.get("ren-descriptions"),
)
table(
    [
        "Ren ADT (s)",
        "Rust enum (s)",
        "Rust dyn (s)",
        "Ren descriptions (s)",
        "ADT / Rust enum",
        "ADT / Rust dyn",
        "ADT / descriptions",
        "descriptions / Rust dyn",
    ],
    [
        [
            secs(adt),
            secs(enum),
            secs(dyn),
            secs(desc),
            ratio(adt, enum),
            ratio(adt, dyn),
            ratio(adt, desc),
            ratio(desc, dyn),
        ]
    ],
)

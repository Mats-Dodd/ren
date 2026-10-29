# `python3 -I measure.py <out> <runs> [variants]`: build.sh's binaries,
# Ren, Rust and Go interleaved, each run under /usr/bin/time -l, and the
# medians of their cycles and instructions. For the `_r` kernels, and
# layer 3's `frames`, a pass is (20 rounds - 0 rounds) / 20, and the spread is the 20-round runs'
# least and most. [variants], comma-separated, also times variants.py's
# binaries of the Ren kernels (`nob,noovf,push`), as `<kernel>.<variant>`
# in <out>/var.
import os, re, statistics, subprocess, sys

out, runs = sys.argv[1], int(sys.argv[2])
variants = sys.argv[3].split(",") if len(sys.argv) > 3 else []
# $KERNELS, comma-separated, times only those (`frames,bytes`)
only = os.environ.get("KERNELS", "").split(",") if os.environ.get("KERNELS") else None
kernels = [k for k in ["logs_r", "json_r", "pages_r", "frames"] if only is None or k in only]
cmds = {}
for k in kernels:
    for r in ["20", "0"]:
        if k == "frames":
            if not os.path.exists(f"{out}/frames-{r}"):
                continue
            cmds[(k, "ren", r)] = [f"{out}/frames-{r}"]
            cmds[(k, "rust", r)] = [f"{out}/frames-rust", "1000000", r]
            cmds[(k, "go", r)] = [f"{out}/frames-go", "1000000", r]
            continue
        cmds[(k, "ren", r)] = [f"{out}/{k}-{r}"]
        cmds[(k, "rust", r)] = [f"{out}/slices-rust", "200000", r, k]
        cmds[(k, "go", r)] = [f"{out}/slices-go", "200000", r, k]
        for v in variants:
            path = f"{out}/var/{k}-{r}.{v}"
            if os.path.exists(path):
                cmds[(k, v, r)] = [path]
bytes_bins = {"ren": f"{out}/bytes", "rust": f"{out}/bytes-rust", "go": f"{out}/bytes-go"}
for v in variants:
    bytes_bins[v] = f"{out}/var/bytes.{v}"
for who, path in bytes_bins.items():
    if os.path.exists(path) and (only is None or "bytes" in only):
        cmds[("bytes", who, "all")] = [path]

res = {k: ([], []) for k in cmds}
for _ in range(runs):
    for key, cmd in cmds.items():
        p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, text=True)
        res[key][0].append(int(re.search(r"(\d+)\s+cycles elapsed", p.stderr).group(1)))
        res[key][1].append(int(re.search(r"(\d+)\s+instructions retired", p.stderr).group(1)))

med = statistics.median
for k in kernels:
    for who in ["ren", "rust", "go"] + variants:
        if (k, who, "20") not in res:
            continue
        c20, i20 = res[(k, who, "20")]
        c0, i0 = res[(k, who, "0")]
        print(f"{k:8s} {who:9s} Mcyc a pass {(med(c20) - med(c0)) / 20e6:7.2f}"
              f"  (20 rounds {min(c20) / 1e6:.0f}-{max(c20) / 1e6:.0f})"
              f"  M instructions a pass {(med(i20) - med(i0)) / 20e6:7.1f}")
for who in ["ren", "rust", "go"] + variants:
    if ("bytes", who, "all") in res:
        c, i = res[("bytes", who, "all")]
        print(f"bytes    {who:9s} Mcyc {med(c) / 1e6:8.1f} ({min(c) / 1e6:.0f}-{max(c) / 1e6:.0f})"
              f"  M instructions {med(i) / 1e6:8.1f}")

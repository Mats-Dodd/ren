# `python3 -I prof.py <binary> [args...]`: where a binary's time goes, by
# Instruments' Time Profiler (`xctrace`, macOS, 1 ms samples): the leaf
# frame of each sample, by function, inlined ones included, and by source
# line (atos), for a binary built with -g, as `cc -O2 -g -ffp-contract=off
# <out>/json_r-20.c -o json_r-20 -lm -lpthread` builds one. TOP sets how
# many lines.
import subprocess, sys, os, re, collections, xml.etree.ElementTree as ET, tempfile, shutil
binary = sys.argv[1]; args = sys.argv[2:]
tmp = tempfile.mkdtemp()
trace = os.path.join(tmp, "t.trace")
subprocess.run(["xctrace", "record", "--template", "Time Profiler", "--output", trace, "--launch", "--", binary] + args, capture_output=True, check=True)
xml = subprocess.run(["xctrace", "export", "--input", trace, "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], capture_output=True, text=True, check=True).stdout
root = ET.fromstring(xml)
binaries = {}
for b in root.iter("binary"):
    if "id" in b.attrib: binaries[b.attrib["id"]] = (b.attrib.get("name"), b.attrib.get("load-addr"))
frames = {}
for fr in root.iter("frame"):
    if "id" in fr.attrib:
        b = fr.find("binary"); bn = (None, None)
        if b is not None: bn = binaries[b.attrib.get("id") or b.attrib["ref"]]
        frames[fr.attrib["id"]] = (fr.attrib.get("name"), fr.attrib.get("addr")) + bn
bts = {}
for bt in root.iter("backtrace"):
    if "id" in bt.attrib:
        fr = bt.find("frame")
        if fr is not None: bts[bt.attrib["id"]] = frames[fr.attrib.get("id") or fr.attrib["ref"]]
leaf = collections.Counter(); total = 0
for row in root.iter("row"):
    bt = row.find("backtrace")
    if bt is None: continue
    f = bts.get(bt.attrib.get("id") or bt.attrib["ref"])
    if f is None: continue
    leaf[f] += 1; total += 1
byfn = collections.Counter(); byaddr = collections.Counter()
me = os.path.basename(binary)
for (name, addr, bname, load), n in leaf.items():
    byfn[(name, bname)] += n
    if bname == me: byaddr[(addr, load)] += n
print(f"{total} samples")
for (name, b), n in byfn.most_common(12):
    print(f"  {100*n/total:5.1f}%  {name}  [{b}]")
# by source line
lines = collections.Counter()
items = list(byaddr.items())
if items:
    load = items[0][0][1]
    addrs = [a for (a, _), _ in items]
    out = subprocess.run(["atos", "-o", binary, "-l", load] + addrs, capture_output=True, text=True).stdout.splitlines()
    for ((a, _), n), sym in zip(items, out):
        m = re.search(r"\(([^()]*:\d+)\)\s*$", sym)
        fn = sym.split(" (in")[0]
        lines[(fn, m.group(1) if m else "?")] += n
    print("by line:")
    for (fn, l), n in lines.most_common(int(os.environ.get("TOP", "25"))):
        print(f"  {100*n/total:5.1f}%  {l}  {fn}")
shutil.rmtree(tmp)

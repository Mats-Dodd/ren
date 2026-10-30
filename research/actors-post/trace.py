import sys, json
# Condense a fizz run of post.fizz: one line per step, with the family's state.
prev = None; last_st = None
def show(st):
    mb = " ".join("%s:%s" % (k, ",".join("%s%s#%d" % (m[2], "<T%d" % m[0] if m[0] < 100 else "<D%d" % (m[0]-100), m[1]) for m in v) or "-") for k, v in sorted(st["mbox"].items()))
    lv = ",".join("%s(pin%d)" % (k, a["pins"]) for k, a in sorted(st["live"].items())) or "-"
    fl = []
    if st["lost"]: fl.append("LOST %s" % st["lost"])
    if st["fifo_bad"]: fl.append("FIFO")
    if st["panicked"]: fl.append("PANIC " + st["why"])
    if st.get("dropped_td"): fl.append("DROPPED %s" % st["dropped_td"])
    return "  %-40s live %-16s mbox [%s] %s" % (st["last"], lv, mb, " ".join(fl))
for line in sys.stdin:
    if line.startswith("state: "):
        st = json.loads(line[7:]); last_st = st
        if st["last"] and st["last"] != prev:
            print(show(st))
        prev = st["last"]
    elif line.startswith(("FAILED", "PASSED")) or "DEADLOCK" in line or "Invariant" in line or "Unique states" in line or line.startswith("Nodes"):
        print(line.strip())

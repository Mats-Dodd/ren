import sys, json
# Condense a failing fizz run: config, then one line per executed instruction.
prev = None; cfg = None
for line in sys.stdin:
    if line.startswith("state: "):
        st = json.loads(line[7:])
        if cfg is None and "cfg" in st: cfg = st["cfg"]; print("config [style, body, B.work, task2]:", cfg)
        l = st.get("last", "")
        if l and l != prev:
            fl = [k for k in ("two_writers","stale","self_wait") if st[k]]
            print("  ", l.ljust(28), "pos", st["pos"], "ghost", st["ghost"], "A held by", st["holder"]["A"], "B by", st["holder"]["B"], ("VIOLATION " + ",".join(fl)) if fl else "")
        prev = l
    elif line.startswith("FAILED") or line.startswith("PASSED") or "eadlock" in line:
        print(line.strip())

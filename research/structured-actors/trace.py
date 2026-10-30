import sys, json
# Condense a failing fizz run of actors.fizz: one line per step with the
# live actors (pins), the busy ones, mail per key, and each task's position.
prev = None
def show(st):
    live = []
    for f, ks in st["live"].items():
        for k, pins in sorted(ks.items()):
            b = st["busy"][f][k]
            live.append("%s%s%s%s" % (f, k, "(pin%d)" % pins if pins else "", "*" + b if b else ""))
    mail = []
    for f, ks in st["mbox"].items():
        for k, ms in sorted(ks.items()):
            if ms:
                mail.append("%s%s:%s" % (f, k, ",".join("%s<%s" % (m[2], m[0]) for m in ms)))
    tasks = []
    for t, fr in sorted(st["stacks"].items()):
        if fr:
            tasks.append("%s@%s" % (t, "/".join("%s:%d" % (x[0], x[1]) for x in fr)))
    extra = []
    if st["errs"]: extra.append("errs %s" % st["errs"])
    if st["lost"]: extra.append("LOST %s" % st["lost"])
    if st["fifo_bad"]: extra.append("FIFO")
    ended = [f for f, e in st["ended"].items() if e]
    if ended: extra.append("ended " + ",".join(ended))
    return "  %-34s live [%s] mail [%s] tasks [%s] %s" % (st["last"], " ".join(live), " ".join(mail), " ".join(tasks), " ".join(extra))
for line in sys.stdin:
    if line.startswith("state: "):
        st = json.loads(line[7:])
        s = show(st)
        if st["last"] and s != prev:
            print(s)
        prev = s
    elif line.startswith(("FAILED", "PASSED")) or "DEADLOCK" in line or line.startswith("Invariant") or "Unique states" in line:
        print(line.strip())

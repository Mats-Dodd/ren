import sys, json
# Condense a fizz run of origins.fizz: one line per step, with the family's state.
# A message prints as op<poster#seq, plus @origin under ORIGINS (e.g. nop<D0#1@0).
# "orig" lists open origins as slot:T<owner> rc=<refcount> used=<fuel spent>.
# With split fuel or credit (outbox runs), a message also shows $fuel~weight,
# an origin ret=<weight back home>, "ob" each running op's unsent outbox and
# "ctrl" the weight returns in flight.
prev = None
def who(p):
    return "T%d" % p if p < 100 else "D%d" % (p - 100)
def msg(m):
    s = "%s<%s#%d" % (m[2], who(m[0]), m[1])
    if len(m) > 4 and m[4] != -1:
        s += "@%d" % m[4]
    if len(m) > 6 and (m[6] or m[7]):
        s += "$%d~%d" % (m[6], m[7])
    return s
def show(st):
    mb = " ".join("%s:%s" % (k, ",".join(msg(m) for m in v) or "-") for k, v in sorted(st["mbox"].items()))
    lv = ",".join("%s(pin%d)" % (k, a["pins"]) for k, a in sorted(st["live"].items())) or "-"
    og = ""
    if st.get("orig"):
        og = " orig [" + " ".join("%s:T%d rc=%d used=%d" % (o, r["owner"], r["rc"], r["used"]) + (" ret=%d" % r["ret"] if r.get("ret") else "") for o, r in sorted(st["orig"].items())) + "]"
    obs = [("T%d" % i, ex) for i, ex in enumerate(st.get("texec") or []) if ex] + [("D%s" % k, ex) for k, ex in sorted((st.get("dexec") or {}).items())]
    obs = ["%s:%s" % (w, ",".join("%s>%s" % (p[1], p[0]) for p in ex[7])) for w, ex in obs if len(ex) > 7 and ex[7]]
    if obs:
        og += " ob [" + " ".join(obs) + "]"
    if st.get("ctrl"):
        og += " ctrl %s" % st["ctrl"]
    fl = []
    if st["lost"]: fl.append("LOST %s" % st["lost"])
    if st["fifo_bad"]: fl.append("FIFO")
    if st.get("settled_bad"): fl.append("SETTLED-EARLY")
    if st["panicked"]: fl.append("PANIC " + st["why"])
    if st.get("dropped_td"): fl.append("DROPPED %s" % st["dropped_td"])
    return "  %-40s live %-16s mbox [%s]%s %s" % (st["last"], lv, mb, og, " ".join(fl))
for line in sys.stdin:
    if line.startswith("state: "):
        st = json.loads(line[7:])
        if st["last"] and st["last"] != prev:
            print(show(st))
        prev = st["last"]
    elif line.startswith(("FAILED", "PASSED")) or "DEADLOCK" in line or "Invariant" in line or "Unique states" in line or line.startswith("Nodes"):
        print(line.strip())

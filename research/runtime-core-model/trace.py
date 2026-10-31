import sys, json
# Condense a failing fizz run of core.fizz: one line per step with the actor,
# the step it took (a worker's pc before the step), then each worker, each
# task, the non-free slots and the world.
def wk(w, W):
    s = "W%d:%s" % (w, W["pc"])
    if W["cur"]: s += "(" + W["cur"] + ")"
    if W["parked"]: s += " parked"
    if W["permit"]: s += " permit"
    q = []
    if W["dq"]: q.append("dq=" + ",".join(W["dq"]))
    if W["inbox"]: q.append("inbox=%s" % W["inbox"])
    if W["outbox"]: q.append("outbox=%s" % W["outbox"])
    if W["remote"]: q.append("remote=%s" % W["remote"])
    if W["cq"]: q.append("cq=%s" % [c["id"] for c in W["cq"]])
    return s + (" " + " ".join(q) if q else "")
def tk(t, T):
    if T["sched"] == "-": return ""
    s = "%s:%s@%d.%d" % (t, T["sched"] + ("+n" if T["nf"] else ""), T["pc"], T["sub"])
    if T["freed"]: s += " FREED"
    if T["flag"]: s += " cancelled"
    if T["mask"]: s += " masked"
    if T["pend"] is not None: s += " pend=%d" % T["pend"]
    if T["aw"] is not None: s += " aw=" + T["aw"]
    if T["holds"]: s += " holds"
    return s
def show(st, actor, prev):
    step = actor
    if prev is not None and actor in ("W0", "W1"):
        step += "." + prev["workers"][int(actor[1])]["pc"]
    ws = " | ".join(wk(w, W) for w, W in enumerate(st["workers"]))
    ts = " ".join(x for x in (tk(t, T) for t, T in st["tasks"].items()) if x)
    sl = " ".join("s%d=%s/%d" % (i, s["st"], s["gen"]) for i, s in enumerate(st["slots"]) if s["st"] != "FREE")
    extra = []
    if st["world"]: extra.append("world=%s" % ["%d%s" % (c["id"], "+cancel" if c["creq"] else "") for c in st["world"]])
    if st["inj"]: extra.append("inj=" + ",".join(st["inj"]))
    if st["inst"]["held"] or st["inst"]["q"]: extra.append("I=%s q=%s" % (st["inst"]["held"], st["inst"]["q"]))
    if st["stopping"]: extra.append("stopping")
    if st["viol"]: extra.append("VIOL %s" % st["viol"])
    return "  %-14s %s || %s || %s %s" % (step, ws, ts, sl, " ".join(extra))
actor = ""
prev = None
for line in sys.stdin:
    if line.startswith("state: "):
        st = json.loads(line[7:])
        if actor and actor != "Init":
            print(show(st, actor, prev))
        prev = st
    elif line.startswith(("FAILED", "PASSED")) or "DEADLOCK" in line or "Unique states" in line or line.startswith("Time taken"):
        print(line.strip())
    elif line.strip() and not line.startswith(("--", "Nodes", "Model", "config", "fizz.yaml", "StateSpace", "Writen", "dot ", "open ", "To ", "Skipping")):
        actor = line.strip()

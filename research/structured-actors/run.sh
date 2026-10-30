#!/bin/sh
# Runs every configuration in MODEL.md. Expected result in brackets.
# ./run.sh [design|old|live|mutants] runs one section.
# Defaults (actors.fizz): ORDER Log > Index > Docs (outermost first), 2 keys,
# max: 1, CAP 1, NEST="outer", eager setup, per-key bound, pin rule on.
cd "$(dirname "$0")"
ONLY="$1"
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
run() { echo "=== [$1] $2" | tr '\n' ' '; echo; fizz --preinit-hook "$2" actors.fizz > run.log 2>&1; python3 -I trace.py < run.log | grep -a -E "^(FAILED|PASSED)|DEADLOCK|^Invariant|Unique states" | head -3; case "$1" in PASS*) ;; *) python3 -I trace.py < run.log | grep -a -v -E "^(FAILED|PASSED|Valid|DEADLOCK|Invariant)";; esac; }
live() { sed 's/^liveness: "false"/liveness: strict/' actors.fizz > actors-live.fizz; echo "=== [$1, liveness] $2" | tr '\n' ' '; echo; fizz --preinit-hook "$2" actors-live.fizz > run.log 2>&1; grep -a -E "^(FAILED|PASSED)|DEADLOCK|IsLive|Unique states|rror" run.log | head -4; }

# ---- scenarios -------------------------------------------------------------------
# BASE: two posts whose Docs ops tell Index (I/O before or after), and an `at`
# block whose op `at`s Index, whose op `at`s Log; then a post outward from the block.
BASE='COVER=["end","cap","oppost"]'
# A task pins Docs0 and posts twice to Index0 (CAP 1): it waits on a full Index
# key while it pins. Another task posts to Docs1 and waits for a Docs slot.
PINPOST='COVER=["end","pinpost","slot"]
PROGS=[[["at","Docs",0],["post","Index",0,"nop"],["post","Index",0,"nop"],["end"]],[["post","Docs",1,"nop"]]]'
# Docs ops post to a full Index key while Index ops `at` an outer Log, whose one
# slot an outside task pins.
OPCHAIN='COVER=["end","oppost","slot"]
PROGS=[[["post","Index",0,"log"],["post","Docs",0,"tolog"],["post","Docs",0,"tolog"]],[["at","Log",1],["call","nop"],["end"]]]'
# Every Docs slot pinned (max: 1) while posts to a non-live Docs key wait.
SLOTPIN='COVER=["end","slot"]
PROGS=[[["at","Docs",0],["call","edit"],["call","edit"],["end"]],[["post","Docs",1,"nop"],["post","Docs",1,"tell"]]]'
# Loops: a poster loop and an `at` session loop whose op posts outward, max: 2,
# chaos eviction.
LOOPS='ORDER=["Index","Docs"]
MAX=2
CHAOS=True
SEQMOD=3
COVER=["cap","oppost"]
PROGS=[[["posts","Docs",0,"nop"]],[["at","Docs",1],["calls","tell"],["end"]]]'
# The other install order: Docs outside Index; Index ops post to Docs.
SWAP='ORDER=["Log","Docs","Index"]
COVER=["end","oppost"]
PROGS=[[["post","Docs",0,"nop"],["post","Index",0,"up"],["post","Index",1,"up"]],[["at","Docs",0],["call","nop"],["at","Log",0],["call","nop"],["end"],["end"]]]'
# The compiler refuses a Docs op that names Index when Index is installed inside Docs.
SWAP_ILLEGAL='ORDER=["Log","Docs","Index"]
PROGS=[[["post","Docs",0,"edit"]]]'
# Setup of Index1 and Docs1 may fail: under an outside post, under a post from a
# Docs op, and under an `at`.
FAILKEY='FAIL_KEYS=["Index1","Docs1"]
COVER=["end","fail"]
PROGS=[[["post","Docs",1,"edit"],["post","Docs",0,"tell"]],[["at","Index",1],["call","note"],["end"]]]'

# ---- the old counterexamples, replayed --------------------------------------------
# Load: 3 sessions, more than CAP, each op does I/O and then posts to one Index key.
LOAD='ORDER=["Index","Docs"]
KEYS=3
MAX={"Index":1,"Docs":3}
COVER=["end","oppost"]
PROGS=[[["at","Docs",0],["call","save"],["end"]],[["at","Docs",1],["call","save"],["end"]],[["at","Docs",2],["call","save"],["end"]]]'
# Pin-then-post: posts inside `at`, the target family full and the key's mailbox full.
PINFULL='ORDER=["Index","Docs"]
COVER=["end","pinpost","slot"]
PROGS=[[["post","Index",0,"slow"],["post","Index",0,"nop"]],[["at","Docs",0],["post","Index",1,"nop"],["post","Index",0,"nop"],["end"]]]'
# Chain reaction: an op posting twice into its own family. Refused by the compiler.
CHAIN='PROGS=[[["post","Docs",0,"double"]]]'

# ---- mutants ------------------------------------------------------------------------
# (a) posts into the same family, waiting for room: two actors, each with a full
# mailbox, each running an op that posts to the other.
SAMEWAIT='SAME_FAMILY="wait"
MAX=2
PROGS=[[["post","Docs",0,"poke"],["post","Docs",1,"poke"],["post","Docs",0,"nop"],["post","Docs",1,"nop"]]]'
# (a') ... not waiting: the chain reaction's mail grows past CAP.
SAMENOWAIT='SAME_FAMILY="nowait"
MAX=2
PROGS=[[["post","Docs",0,"double"]]]'
# (b) one bound for the family: a post to an idle key waits behind another key's mail.
FAMBOUND='BOUND="family"
FAMCAP=1
MAX=2
PROGS=[[["post","Docs",0,"nop"]],[["post","Docs",1,"nop"]]]'
# (c) `at` blocks that nest inward (legal only under NEST="notself"): T0 pins
# Index0 and enters Docs; T1 pins Docs1 and enters Index (max: 1 each).
NESTIN='COVER=["end","full"]
PROGS=[[["at","Index",0],["at","Docs",0],["end"],["end"]],[["at","Docs",1],["at","Index",1],["end"],["end"]]]'
# ... the same wait through a mailbox: T0 pins Index0 and posts to a full Docs0,
# whose queued op `at`s Index1.
NESTMAIL='NEST="notself"
COVER=["end","full"]
PROGS=[[["post","Docs",0,"look1"],["post","Docs",0,"look1"],["at","Index",0],["post","Docs",0,"nop"],["end"]]]'
# ... and through taking the actor for one call: T0 pins Index0, enters Docs0 and
# calls it while Docs0's delivery runs look1, which `at`s Index1.
NESTCALL='NEST="notself"
PIN_MAIL=True
PROGS=[[["post","Docs",0,"look1"],["at","Index",0],["at","Docs",0],["call","nop"],["end"],["end"]]]'
# (d) no eager setup: the post queues, and the delivery's setup fails.
LAZY='EAGER=False
CHECK_LIVE=False
FAIL_KEYS=["Docs1"]
PROGS=[[["post","Docs",1,"nop"]]]'
# ... and mail for a key whose actor isn't live while the family is full.
LAZYFULL='EAGER=False
PROGS=[[["post","Docs",1,"nop"],["at","Docs",0],["call","nop"],["end"]]]'

if want design; then
echo "--- the design"
run PASS "$BASE"
run PASS "$PINPOST"
run PASS "$OPCHAIN"
run PASS "$SLOTPIN"
run PASS "$LOOPS"
run PASS "$SWAP"
run "FAIL ProgramsLegal (refused)" "$SWAP_ILLEGAL"
run PASS "$FAILKEY"
fi

if want old; then
echo "--- the old counterexamples"
run PASS "$LOAD"
run PASS "$PINFULL"
run "FAIL ProgramsLegal (refused)" "$CHAIN"
echo "(setup failure under a post: FAILKEY, in the design section)"
fi

if want live; then
echo "--- termination"
live PASS "$PINPOST"
live PASS "$OPCHAIN"
live PASS "$SLOTPIN"
live PASS "$SWAP"
live PASS "$FAILKEY"
live PASS "$LOAD"
fi

if want mutants; then
echo "--- mutants"
run "FAIL DEADLOCK" "$SAMEWAIT"
run "FAIL MailPerKeyWithinCap" "$SAMENOWAIT"
run "FAIL NoHeadOfLineBlocking" "$FAMBOUND"
run "FAIL ProgramsLegal (inward nesting refused under NEST=outer)" "$NESTIN"
run PASS "NEST=\"notself\"
$NESTIN"
run "FAIL DEADLOCK" "NEST=\"notself\"
PIN_RULE=False
$NESTIN"
run "FAIL DEADLOCK" "$NESTMAIL"
run PASS "PIN_MAIL=True
$NESTMAIL"
run "FAIL DEADLOCK" "$NESTCALL"
run "FAIL ProgramsLegal (the fix: NEST=outer)" "$NESTCALL
NEST=\"outer\""
echo "--- (c) under NEST=outer the pin rule is implied: drop it and nothing changes"
run PASS "PIN_RULE=False
$PINPOST"
run PASS "PIN_RULE=False
$OPCHAIN"
run PASS "PIN_RULE=False
$SLOTPIN"
run PASS "PIN_RULE=False
$PINFULL"
run "FAIL NoLostPost" "$LAZY"
run "FAIL MailImpliesLive" "$LAZYFULL"
echo "--- (d) without eager setup the bound becomes keys x CAP, not max: x CAP"
run "FAIL MailWithinMaxTimesCap" "EAGER=False
CHECK_LIVE=False
PROGS=[[[\"post\",\"Docs\",0,\"nop\"],[\"post\",\"Docs\",1,\"nop\"]]]"
echo "--- is delivery-over-max needed? no, not even without eager setup:"
run PASS "CHECK_LIVE=False
$LAZYFULL"
run PASS "EAGER=False
CHECK_LIVE=False
CHECK_MAXCAP=False
PROGS=[[[\"at\",\"Docs\",0],[\"post\",\"Index\",0,\"nop\"],[\"post\",\"Index\",0,\"nop\"],[\"end\"]],[[\"post\",\"Docs\",1,\"nop\"]]]"
run PASS "EAGER=False
CHECK_LIVE=False
CHECK_MAXCAP=False
PROGS=[[[\"at\",\"Docs\",0],[\"call\",\"edit\"],[\"call\",\"edit\"],[\"end\"]],[[\"post\",\"Docs\",1,\"nop\"],[\"post\",\"Docs\",1,\"tell\"]]]"
fi
rm -rf run.log actors-live.fizz actors-live.json actors.json out

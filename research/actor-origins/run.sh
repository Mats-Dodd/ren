#!/bin/sh
# Runs every configuration reported in MODEL.md. Expected result in brackets.
# origins.fizz defaults are decision 18 as first written (no FIX); $FIX gives the
# adopted rules (research/actors-post/), $ORG gives origins.
cd "$(dirname "$0")"
# live: the same, with liveness on (fair runs must end the family and return every settled())
live() { sed 's/^liveness: "false"/liveness: strict/' origins.fizz > origins-live.fizz; echo "=== [$1, liveness] $2" | tr '\n' ' '; echo; fizz --preinit-hook "$2" origins-live.fizz > run.log 2>&1; grep -E "^(FAILED|PASSED)|DEADLOCK|IsLive|Unique states|rror" run.log | head -4; }
run() { echo "=== [$1] $2" | tr '\n' ' '; echo; fizz --preinit-hook "$2" origins.fizz > run.log 2>&1; grep -E "^(FAILED|PASSED)|DEADLOCK|Unique states|rror" run.log | head -3; python3 -I trace.py < run.log | grep -v -E "^(FAILED|PASSED|Nodes|Valid|DEADLOCK)"; }

# Programs (outside tasks), as in actors-post/run.sh
BASE='PROGS=[[["post",0,"ping"],["post",1,"nop"]],[["at",0],["call","notify"],["end"]]]'
FAN3='KEYS=3
MAX=2
MAILBOX=2
CEIL=8
PROGS=[[["post",0,"ping"],["post",1,"fan"]],[["at",2],["call","fan"],["end"]]]'
PINPOST='PROGS=[[["post",1,"nop"]],[["at",0],["post",1,"nop"],["end"]]]'
CHAIN='CEIL=6
PROGS=[[["post",0,"double"]]]'
SESSION='CEIL=6
PROGS=[[["post",1,"nop"]],[["at",0],["calls","notify"],["end"]]]'
PERPETUAL='PROGS=[[["post",0,"loop"]]]'
SELFFULL='PROGS=[[["post",0,"ping"],["post",0,"nop"]]]'
PINGPONG='MAX=2
MAILBOX=2
PROGS=[[["post",0,"ping"],["post",1,"ping"],["post",0,"nop"],["post",1,"nop"]]]'
FAILKEY='SETUP_FAIL_KEYS=[1]
PROGS=[[["post",1,"nop"],["post",0,"nop"]]]'
FAILSIB='SETUP_FAIL_KEYS=[1]
COVER_FAIL=True
PROGS=[[["post",1,"nop"],["post",0,"ping"]],[["at",0],["call","notify"],["end"]]]'
# Step 1: three sessions, each edit saves (I/O) then tells a sibling once
LOAD='KEYS=4
MAX=3
MAILBOX=1
HEADROOM=1
CEIL=99
PROGS=[[["at",0],["call","edit"],["end"]],[["at",1],["call","edit"],["end"]],[["at",2],["call","edit"],["end"]]]'
# A pinning task posts from outside while the family is full and every origin slot is taken
NEST1='COVER_NEST=True
PROGS=[[["post",1,"ping"]],[["at",0],["post",1,"nop"],["end"]]]'
NEST2='KEYS=3
MAX=2
COVER_NEST=True
PROGS=[[["at",0],["call","notify"],["post",2,"ping"],["end"]],[["at",1],["post",2,"nop"],["call","notify"],["end"]]]'
# settled(): waits while its origin's descendants are queued, then returns
SETTLED='COVER_SETTLED=True
PROGS=[[["post",0,"ping"],["settled"]]]'
SETTLED2='COVER_SETTLED=True
INFLIGHT=2
PROGS=[[["post",0,"ping"],["settled"],["post",1,"nop"]],[["at",1],["call","notify"],["settled"],["end"]]]'

# The adopted rules (actors-post's FIX)
FIX='DELIVERY_OVER_MAX=True
AT_METER=True
EAGER=True
COVER_EVICT=False
SIB="panic_over"
HEADROOM=4'
# Origins: kept from FIX are EAGER and DELIVERY_OVER_MAX; INFLIGHT=1, FUEL=2 by default
ORG='ORIGINS=True
EAGER=True
DELIVERY_OVER_MAX=True
COVER_EVICT=False'

echo "--- step 1: legitimate load under the adopted rules"
run FAIL-NoPanic "$LOAD
$FIX
HEADROOM=1"

echo "--- the adopted rules, in this model (same as actors-post)"
run PASS "$BASE
$FIX"
run PASS "$FAN3
$FIX"
run PASS "$BASE
CHAOS=True
$FIX"
run PASS "$PINPOST
$FIX"
run PASS "$SESSION
$FIX"
run PASS "$SELFFULL
$FIX"
run PASS "$PINGPONG
$FIX"
run FAIL-FamilyEnds-exists "$PERPETUAL
$FIX"
run PASS "$FAILKEY
$FIX"
run PASS "$FAILSIB
$FIX"
run FAIL-NoPanic "$CHAIN
$FIX"
run PASS "$NEST1
$FIX
COVER_NEST=False"

echo "--- origins"
run PASS "$LOAD
$ORG
FUEL=1"
run PASS "$LOAD
$ORG
INFLIGHT=3
FUEL=1"
run PASS "$BASE
$ORG"
run PASS "$BASE
$ORG
INFLIGHT=2"
run PASS "$FAN3
$ORG
INFLIGHT=2"
run PASS "$BASE
CHAOS=True
$ORG"
run PASS "$FAN3
CHAOS=True
$ORG"
run PASS "$PINPOST
$ORG"
run PASS "$SESSION
$ORG"
run PASS "$SESSION
$ORG
INFLIGHT=2"
run PASS "$SELFFULL
$ORG"
run PASS "$PINGPONG
$ORG
INFLIGHT=2"
run PASS "$FAILKEY
$ORG"
run PASS "$FAILSIB
$ORG
INFLIGHT=2"
run FAIL-NoPanic-fuel "$CHAIN
$ORG"
run FAIL-NoPanic-fuel "$PERPETUAL
$ORG"
run PASS "$NEST1
$ORG"
run PASS "$NEST2
$ORG"
run PASS "$SETTLED
$ORG"
run PASS "$SETTLED2
$ORG"

echo "--- origins: liveness, terminating programs"
live PASS "$BASE
$ORG"
live PASS "$NEST2
$ORG"
live PASS "$SETTLED2
$ORG"
live PASS "$LOAD
$ORG
FUEL=1"

echo "--- origins: sizing and the alternative"
# fuel is a hop budget too: a legitimate ping -> pong -> nop needs FUEL=2
run FAIL-NoPanic "$PINGPONG
$ORG
INFLIGHT=2
FUEL=1"
# a sibling post that opens a new origin (and so waits at the edge) deadlocks
run FAIL-deadlock "$ORG
SIB_ORIGIN=\"new\"
PROGS=[[[\"post\",0,\"ping\"]]]"
# ---- outbox and split fuel (MODEL.md, "Outbox and split fuel") ----------------
# OUT: the proposal. Origins as above, plus each op's posts leave together when
# it ends, and fuel travels with the mail (split).
OUT="$ORG
OUTBOX=True
FUEL_MODE=\"split\""
CREDIT="$OUT
CLOSE=\"credit\""
# (under the fix an outbox is already empty when an op is cancelled or fails
# after I/O, so the non-empty-outbox coverage can't be reached)
SUSPEND="$OUT
FLUSH=\"suspend\"
COVER_CANCEL=False
COVER_FAILOP=False"
RELAYDET='INFLIGHT=2
MAX=2
FUEL=2
PROGS=[[["post",0,"h3"]],[["at",1],["call","notify"],["post",0,"ping"],["end"]]]
PANIC_AT=[0,2,0,"h1"]'
TREE='KEYS=3
MAX=3
INFLIGHT=2
FUEL=3
PROGS=[[["post",0,"split2"]],[["at",1],["call","notify"],["end"]]]
PANIC_AT=[0,1,2,"h1"]'
CANC='CANCEL=True
COVER_CANCEL=True
MAX=2
FUEL=3
PROGS=[[["at",0],["call","save2"],["end"]],[["post",1,"nop"]]]'
FAILOP='COVER_FAILOP=True
MAX=2
INFLIGHT=2
FUEL=3
PROGS=[[["post",0,"savefail"]],[["at",1],["call","savefail"],["end"]]]'
AWAIT1='MAX=2
PROGS=[[["post",0,"await"]]]'
AWAIT2='MAX=2
PROGS=[[["at",1],["call","await"],["end"]],[["post",0,"nop"]]]'
TWO='MAX=2
PROGS=[[["post",0,"two"],["settled"]]]'

# Every scenario above, under mode $1
suite() {
run PASS "$LOAD
$1
FUEL=1"
run PASS "$LOAD
$1
INFLIGHT=3
FUEL=1"
run PASS "$BASE
$1"
run PASS "$BASE
$1
INFLIGHT=2"
run PASS "$FAN3
$1
INFLIGHT=2
COVER_BOUND=True"
run PASS "$BASE
CHAOS=True
$1"
run PASS "$FAN3
CHAOS=True
$1"
run PASS "$PINPOST
$1"
run PASS "$SESSION
$1"
run PASS "$SESSION
$1
INFLIGHT=2"
run PASS "$SELFFULL
$1"
run PASS "$PINGPONG
$1
INFLIGHT=2"
run PASS "$FAILKEY
$1"
run PASS "$FAILSIB
$1
INFLIGHT=2"
run FAIL-NoPanic-fuel "$CHAIN
$1"
run FAIL-NoPanic-fuel "$PERPETUAL
$1"
run PASS "$NEST1
$1"
run PASS "$NEST2
$1"
run PASS "$SETTLED
$1"
run PASS "$SETTLED2
$1"
run FAIL-NoPanic-fuel "$PINGPONG
$1
INFLIGHT=2
FUEL=1"
# a relay of L in-family hops passes iff L <= F
run PASS "$1
FUEL=3
PROGS=[[[\"post\",0,\"h3\"]]]"
run FAIL-NoPanic-fuel "$1
FUEL=3
PROGS=[[[\"post\",0,\"h4\"]]]"
# determinism: whatever the schedule, the over-long relay (and the tree) panics, and only at one op
run PASS "$RELAYDET
$1"
run PASS "$TREE
$1"
# cancellation and failure mid-op with a non-empty outbox: the posts go, once each
run PASS "$CANC
$1"
run PASS "$FAILOP
$1"
}

echo "--- outbox + split fuel (the proposal), refcount close"
suite "$OUT"
run PASS "$RELAYDET
$OUT
SPLIT_PANIC=\"post\""
echo "--- outbox + split fuel, credit close"
suite "$CREDIT"
echo "--- outbox + split fuel: liveness, terminating programs"
live PASS "$BASE
$OUT"
live PASS "$NEST2
$OUT"
live PASS "$SETTLED2
$OUT"
live PASS "$LOAD
$OUT
FUEL=1"
live PASS "$SETTLED2
$CREDIT"
live PASS "$FAN3
$CREDIT
INFLIGHT=2"

echo "--- determinism under pooled fuel: the tree's panic lands on either branch"
run FAIL-NoPanic "$TREE
$ORG"
echo "--- cancellation and failure mid-op under pooled (eager send), for comparison"
run PASS "$CANC
$ORG
COVER_CANCEL=False"
run PASS "$FAILOP
$ORG
COVER_FAILOP=False"

echo "--- observability: an op that waits on an effect of its own post"
run PASS "$AWAIT1
$ORG"
run PASS "$AWAIT2
$ORG"
run FAIL-deadlock "$AWAIT1
$OUT"
run FAIL-deadlock "$AWAIT2
$OUT"
echo "--- the fix: the outbox also leaves at each suspension (FLUSH=suspend)"
run PASS "$AWAIT1
$SUSPEND"
run PASS "$AWAIT2
$SUSPEND"
run PASS "$AWAIT2
$SUSPEND
CLOSE=\"credit\""
suite "$SUSPEND"
suite "$SUSPEND
CLOSE=\"credit\""
echo "--- the fix's price: an op that posts and then suspends gives fuel away early"
run PASS "$OUT
MAX=2
FUEL=2
PROGS=[[[\"post\",0,\"save2\"]]]"
run FAIL-NoPanic-fuel "$SUSPEND
MAX=2
FUEL=2
PROGS=[[[\"post\",0,\"save2\"]]]"
# and the weight bound W = F no longer suffices
run FAIL-WeightNeverUnderflows "$SUSPEND
CLOSE=\"credit\"
MAX=2
FUEL=1
PROGS=[[[\"post\",0,\"await\"]]]"
run PASS "$SUSPEND
CLOSE=\"credit\"
WEIGHT=2
MAX=2
FUEL=1
PROGS=[[[\"post\",0,\"await\"]]]"

echo "--- mutants: each is caught"
run FAIL-FifoPerPosterActor "$TWO
$OUT
MUTANT=\"order\""
run FAIL-FuelConserved "$BASE
$OUT
MUTANT=\"split\""
run FAIL-CreditConserved "$TWO
$CREDIT
MUTANT=\"credit\""
run FAIL-OriginRefcountExact "$TWO
$CREDIT
MUTANT=\"credit\"
CHECK_CONSERVATION=False"
run FAIL-AllMadePostsDelivered "$CANC
$OUT
MUTANT=\"cancel_drop\""
rm -rf out run.log origins.json origins-live.fizz origins-live.json

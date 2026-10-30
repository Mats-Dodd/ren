#!/bin/sh
# Runs every configuration reported in README.md. Expected result in brackets.
# Defaults (post.fizz) are decision 18 as written: KEYS=2 MAX=1 MAILBOX=1,
# sibling posts never wait, the mailbox is the family's (per key) and survives
# eviction, teardown drains.
cd "$(dirname "$0")"
run() { echo "=== [$1] $2" | tr '\n' ' '; echo; fizz --preinit-hook "$2" post.fizz > run.log 2>&1; grep -E "^(FAILED|PASSED)|DEADLOCK|Unique states" run.log | head -3; python3 -I trace.py < run.log | grep -v -E "^(FAILED|PASSED|Nodes|Valid|DEADLOCK)"; }

# Programs (outside tasks)
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
COVER_EVICT=False
PROGS=[[["post",1,"nop"],["post",0,"nop"]]]'
FAILSIB='SETUP_FAIL_KEYS=[1]
COVER_FAIL=True
PROGS=[[["post",1,"nop"],["post",0,"ping"]],[["at",0],["call","notify"],["end"]]]'
# The proposed rules together
FIX='DELIVERY_OVER_MAX=True
AT_METER=True
EAGER=True
COVER_EVICT=False
SIB="panic_over"
HEADROOM=4'

echo "--- decision 18 as written"
run PASS "$BASE"
run PASS "$FAN3"
run PASS "$BASE
CHAOS=True"
run PASS "$BASE
EVICT_NONEMPTY=False
COVER_EVICT=False"
run PASS "$PINGPONG
COVER_EVICT=False"
run FAIL-deadlock "$PINPOST"
run FAIL-Bounded "$CHAIN"
run FAIL-Bounded "$SESSION"
run FAIL-FamilyEnds-exists "$PERPETUAL
COVER_EVICT=False"
run FAIL-NoLostPost "$FAILKEY
SETUP_POLICY=\"drop\""
run FAIL-NoPanic "$FAILKEY
SETUP_POLICY=\"panic\""
run FAIL-FamilyEnds-exists "$FAILKEY
SETUP_DOWN=True
SETUP_POLICY=\"retry\""
run FAIL-EveryAcceptedPostRan "$BASE
TEARDOWN=\"drop\""

echo "--- the alternatives decision 18 rules out"
run FAIL-NoLostPost "$BASE
CHAOS=True
MBOX_HOME=\"actor\""
run FAIL-deadlock "$PINGPONG
SIB=\"wait\"
COVER_EVICT=False"
run FAIL-deadlock "$SELFFULL
SIB=\"wait\"
COVER_EVICT=False"

echo "--- the proposed rules"
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
run FAIL-FamilyEnds-exists "$PERPETUAL
$FIX"
run PASS "$FAILSIB
$FIX"
run FAIL-NoPanic "$CHAIN
$FIX"
rm -rf out run.log post.json

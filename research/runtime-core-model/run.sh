#!/bin/sh
# Runs every configuration in MODEL.md. Expected result in brackets.
# ./run.sh [design|spec|mutants|live] runs one section.
# Defaults (core.fizz): 2 workers, 2 slots each, replies from the home driver,
# SPEC §B's deliver order (store, free, notify), C's retraction wake, no ref rule.
# Run one section at a time in a checkout (fizz writes core.json and out/ here).
# "design" is the protocol with the recommended rules on (REF=True: whoever
# publishes a wake holds a reference to the task until its notify is done).
cd "$(dirname "$0")"
ONLY="$1"
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
run() { echo "=== [$1] $2" | tr '\n' ' '; echo; fizz --preinit-hook "$2" core.fizz > run.$$.log 2>&1; python3 -I trace.py < run.$$.log | grep -a -E "^(FAILED|PASSED)|DEADLOCK|Unique states" | head -3; case "$1" in PASS*) ;; *) python3 -I trace.py < run.$$.log | grep -a -v -E "^(FAILED|PASSED|Valid|DEADLOCK|Time)" | tail -${TAIL:-14};; esac; }
live() { sed 's/^liveness: "false"/liveness: strict/' core.fizz > core-live.$$.fizz; echo "=== [$1, liveness] $2" | tr '\n' ' '; echo; fizz --preinit-hook "$2" core-live.$$.fizz > run.$$.log 2>&1; grep -a -E "^(FAILED|PASSED)|DEADLOCK|IsLive|Unique states|^Error|panic" run.$$.log | head -4; }

FIX='REF=True'

# ---- scenarios -------------------------------------------------------------------
# A sibling's cancel walk races T1's world call: the walk flags T1, notifies it
# (a spurious resume) and cancels its call by id; the reply (Done or Cancelled)
# races the cancel.
CALL='PROGS={"T1":[["call"]],"T2":[["cancel"]]}
COVER=["cancelsent","reply_after_cancel","spurious_resume","retract","precheck"]'
# T1's call, then a call in a finally (masked), while T2's walk cancels: the
# finally's call reuses T1's slot with the next generation.
FINALLY='PROGS={"T1":[["call"],["finally"],["call"],["endfinally"]],"T2":[["cancel"]]}
COVER=["cancelsent","reply_after_cancel"]'
# Issue a call and cancel it in the same step (t_cancel (b)): retracted at the pull.
RETRACT='PROGS={"T1":[["callcancel"]]}
COVER=["retract","retracted"]'
# The same, with a second task's call in flight.
RETRACT2='PROGS={"T1":[["callcancel"]],"T2":[["call"]]}
COVER=["retracted"]'
# Two calls in a row, and the world sends one late duplicate of a reply:
# after the slot is reused it carries an old generation.
DUPS='PROGS={"T1":[["call"],["call"]]}
DUP=True
COVER=["stale_released","dup_released"]'
# Inline answers (answer_now) mixed with queued ones.
INLINE='PROGS={"T1":[["call"],["call"]]}
ANSWER_NOW=True
COVER=["inline"]'
# Two tasks take the shared instance: CAS, park on contention, handoff on release.
INST='PROGS={"T1":[["take"],["release"]],"T2":[["take"],["release"]]}
SPURIOUS=True
COVER=["inst_park","handoff","spurious"]'
# W2: two tasks ping-pong through a turn word and ren_notify.
PING='PROGS={"T1":[["give","T2"],["await_turn"],["give","T2"]],"T2":[["await_turn"],["give","T1"],["await_turn"]]}'
# ... with a YIELD after each give (W2's ren_tick), through the injector.
PINGY='PROGS={"T1":[["give","T2"],["yield"],["await_turn"],["give","T2"]],"T2":[["await_turn"],["give","T1"],["yield"],["await_turn"]]}'
# ren_stop at any point, around a call.
STOPS='PROGS={"T1":[["call"]]}
STOP=True
STOP_WALK="notify"
COVER=["precheck","cancelsent"]'
# A parked task woken from outside once (another ren_notify), while its call is out.
SPUR='PROGS={"T1":[["call"]]}
SPURIOUS=True
COVER=["spurious","spurious_resume"]'

if want design; then
echo "--- the design: SPEC §B with the ref rule, the retraction wake and (under ren_stop) the stop notify"
run PASS "$FIX
$CALL"
run PASS "$FIX
$FINALLY"
run PASS "$FIX
$RETRACT"
run PASS "$FIX
$RETRACT2"
run PASS "$FIX
$DUPS"
run PASS "$FIX
$INLINE"
run PASS "$FIX
$INST"
run PASS "$FIX
$PING"
run PASS "$FIX
SPURIOUS=True
$PING"
run PASS "$FIX
$PINGY"
run PASS "$FIX
$STOPS"
run PASS "$FIX
STOP=True
STOP_WALK=\"notify\"
$PING"
run PASS "$FIX
$SPUR"
echo "--- replies from any thread (ren_reply on the world's thread, then wake_worker)"
run PASS "$FIX
REPLY=\"any\"
$CALL"
run PASS "$FIX
REPLY=\"any\"
$RETRACT2"
run PASS "$FIX
REPLY=\"any\"
$STOPS"
fi

if want spec; then
echo "--- SPEC §B.5 as written: deliver stores, frees, then notifies a task it holds no reference to"
run "FAIL NoUseAfterFree (deliver)" "$CALL"
run "FAIL NoUseAfterFree (deliver, any spurious wake)" "$SPUR"
echo "--- the same window at the other wake sites"
run "FAIL NoUseAfterFree (scope end: the last child notifies the owner)" "REF=[\"deliver\",\"handoff\",\"give\"]
SPURIOUS=True
PROGS={\"T1\":[[\"call\"]]}"
run "FAIL NoUseAfterFree (instance handoff)" "REF=[\"deliver\",\"scope\",\"give\"]
$INST"
run "FAIL NoUseAfterFree (W2's give, without the references W2 holds)" "REF=[\"deliver\",\"scope\",\"handoff\"]
PEER_REFS=False
$PING"
echo "--- SPEC's ren_stop cancels slots only: a task parked on an until() never sees it"
run "FAIL DEADLOCK" "$FIX
STOP=True
$PING"
echo "--- SPEC's ren_poll_call pseudocode (and the Rust core): a retraction wakes no one"
run "FAIL NoLostWake" "RETRACT_WAKE=False
$FIX
$RETRACT"
run "FAIL NoLostWake" "RETRACT_WAKE=False
$FIX
$RETRACT2"
run "FAIL NoLostWake" "RETRACT_WAKE=False
$FIX
STOP=True
PROGS={\"T1\":[[\"call\"]]}"
fi

if want mutants; then
echo "--- mutants (each on top of the design)"
run "FAIL NoDoubleFree (P4)" "$FIX
P4=True
$CALL"
run "FAIL StaleReplyNeverAccepted (P3)" "$FIX
GEN_CHECK=False
$DUPS"
run "FAIL StaleCancelNeverHits (P3, cancel side)" "$FIX
GEN_CHECK=False
$FINALLY"
run "FAIL NoLostWake (notify before the store)" "$FIX
ORDER=\"notify_first\"
$CALL"
run "FAIL NoLostWake (park without re-check)" "$FIX
PARK_RECHECK=False
REPLY=\"any\"
PROGS={\"T1\":[[\"call\"]],\"T2\":[[\"call\"]]}"
run "FAIL CancelledTaskWaitsForReply (old rule 4)" "$FIX
WAIT_REPLY=False
$CALL"
run "FAIL NoLostWaiter (take parks without re-check)" "$FIX
INST_RECHECK=False
$INST"
run "FAIL DEADLOCK (ren_stop wakes only the tasks parked right now)" "$FIX
STOP=True
STOP_WALK=\"parked\"
$PING"
fi

if want live; then
echo "--- termination: every worker's loop exits"
live PASS "$FIX
$CALL"
live PASS "$FIX
$FINALLY"
live PASS "$FIX
$RETRACT2"
live PASS "$FIX
$INST"
live PASS "$FIX
$PING"
live PASS "$FIX
$STOPS"
live PASS "$FIX
STOP=True
STOP_WALK=\"notify\"
$PING"
live "FAIL" "RETRACT_WAKE=False
$FIX
$RETRACT"
fi
rm -rf run.$$.log core-live.$$.fizz core-live.$$.json core.json out

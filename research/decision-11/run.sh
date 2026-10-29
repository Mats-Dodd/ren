#!/bin/sh
# Runs every configuration reported in ../t2-fizzbee.md. Expected result in brackets.
cd "$(dirname "$0")"
run() { echo "=== [$1] $2" | tr '\n' ' '; echo; fizz --preinit-hook "$2" handler_state.fizz > run.log 2>&1; grep -E "^(FAILED|PASSED)" run.log | head -1; python3 -I trace.py < run.log | tail -n +2; }
run PASS 'RULE="current"'
run PASS 'RULE="narrowed"'
run PASS 'RULE="narrowed"
STEPS=3'
run PASS 'RULE="narrowed"
NESTED_UNTIL=True
T2_KINDS=["pokeA","signalB"]'
run FAIL-NoTwoWriters 'RULE="probe_no_release"'
run FAIL-NoTwoWriters 'RULE="probe_no_until"'
run FAIL-deadlock 'RULE="narrowed"
NESTED_UNTIL=True'
run FAIL-deadlock 'RULE="current"
NESTED_UNTIL=True'
run FAIL-NoReentryWait 'RULE="narrowed"
DECISION10_STATIC=False'
run FAIL-NoReentryWait 'RULE="narrowed"
DECISION10_STATIC=False
B_KINDS=["callC_backA"]'
run FAIL-NoTwoWriters 'RULE="narrowed"
DECISION10_STATIC=False
REENTRANT=True'
run FAIL-NoLostUpdate 'RULE="current"
DECISION10_STATIC=False
REENTRANT=True'
rm -rf out run.log

#!/usr/bin/env bash
# Runtime phase 2: runs the four experiments one at a time, never overlapping.
#   ./run-serial.sh [k1b] [percore] [spin] [switch]   (default: all, in that order)
# Per-run waits are capped at 10 s: our own multi-thread runs raise the
# 1-minute load, so a longer per-run wait mostly waits on ourselves.
# Before each job: poll the 1-minute load every 30 s, up to 15 min, until it is
# at or below 3; then run anyway and say so. Load at start and end of every job
# goes to run-serial.log. Inside each job every configuration also waits
# (up to 60 s) for load <= 3 and records its own load on its line.
# Repetitions: >= 7 everywhere (k1b REPS=7, percore --reps 7, spin --reps 7,
# switch reps 7 / fanout 63; park raised 5 -> 7 in switch/measure-p2.sh).
set -uo pipefail
cd "$(dirname "$0")"
LOG=$PWD/run-serial.log
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >&2; }

gate() {
  local waited=0
  while awk -v l="$(load1)" 'BEGIN{exit !(l>3)}'; do
    if (( waited >= 900 )); then log "gate: load $(load1) still > 3 after 15 min; running anyway"; return; fi
    log "gate: load $(load1) > 3, waiting"
    sleep 30; waited=$((waited + 30))
  done
}

job() { # name cmd...
  local name=$1; shift
  gate
  log "START $name load1=$(load1) cmd: $*"
  "$@"; local rc=$?
  log "END   $name load1=$(load1) rc=$rc"
}

k1b() {
  (cd k1b && ./measure.sh --smoke >/dev/null) || log "k1b smoke FAILED"
  job k1b-det    env REPS=7 LOAD_MAX=3 LOAD_WAIT=10 k1b/measure.sh sim parts mem
  k1b_timed
}
k1b_timed() {
  job k1b-thru   env REPS=7 LOAD_MAX=3 LOAD_WAIT=10 k1b/measure.sh throughput
  job k1b-extras env REPS=7 LOAD_MAX=3 LOAD_WAIT=10 k1b/measure.sh extras
}
percore() {
  (cd percore && ./smoke.sh >/dev/null) || log "percore smoke FAILED"
  job percore env LOAD_WAIT=10 percore/measure-p2.sh --reps 7
}
spin() {
  (cd spin && ./measure.sh --quick >/dev/null) || log "spin quick check FAILED"
  job spin env LOAD_WAIT=10 spin/measure-p2.sh --reps 7
}
switch() {
  switch/measure.sh --check >/dev/null || log "switch check FAILED"
  job switch switch/measure-p2.sh
}

EXPS=("$@"); (( ${#EXPS[@]} )) || EXPS=(k1b percore spin switch)
log "run-serial begin: ${EXPS[*]} load1=$(load1)"
for e in "${EXPS[@]}"; do $e; done
log "run-serial done: ${EXPS[*]}"

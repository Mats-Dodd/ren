#!/usr/bin/env bash
# Independent re-run of each experiment's headline configurations, plus the
# corrected copies (k3/verify/k3_hybrid.c, p3/verify/p3_fixed.c). Serial, one
# job at a time. Before each job it waits (up to 15 min, polling every 30 s)
# for the 1-minute load average to drop to 3 or below, as run-serial.sh does,
# then runs anyway; load at start and end goes into <id>/verify/<job>.log.
# Output goes to <id>/verify/<job>-<ts>.txt; nothing in results/ is touched.
set -u
here=$(cd "$(dirname "$0")" && pwd)
ts=$(date +%Y%m%d-%H%M%S)
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
waitload() {
  for i in $(seq 1 30); do
    awk -v l="$(load1)" 'BEGIN{exit !(l<=3)}' && return 0
    sleep 30
  done
  echo "[$(date +%T)] load still $(load1) after 15 min, running anyway" >&2
}
job() { # id name cmd...
  local id=$1 name=$2; shift 2
  local out="$here/$id/verify/$name-$ts.txt" log="$here/$id/verify/$name-$ts.log"
  waitload
  { echo "start $(date) load: $(sysctl -n vm.loadavg)"; echo "cmd: $*"; } > "$log"
  echo "[$(date +%T)] $id/$name start, load $(load1)" >&2
  local t0=$(date +%s)
  ( cd "$here/$id" && "$@" ) > "$out" 2>> "$log"
  local rc=$?
  echo "end $(date) rc=$rc secs=$(( $(date +%s) - t0 )) load: $(sysctl -n vm.loadavg)" >> "$log"
  echo "[$(date +%T)] $id/$name done rc=$rc" >&2
}

# Second pass: P3 and the K3 hybrid lock at 8 workers, whose first pass ended under heavy load
job p3 headline2 bash -c 'for cfg in "100 8" "100 12" "100 16" "500 12"; do set -- $cfg
  for m in fifo barge; do
    bin/p3c --mode $m --workers $2 --cs-ns $1 --out-ns 1000 --ms 1000 --reps 7
    verify/p3_fixed --mode $m --workers $2 --cs-ns $1 --out-ns 1000 --ms 1000 --reps 7 --runnext-nowake 1
  done; done'
job k3 hybrid2 bash -c 'for v in edge shared; do
  ./verify/k3_hybrid --variant $v --lock unfair --workers 8 --ms 1000 --reps 7
  ./verify/k3_hybrid --variant $v --lock hybrid --spin 64 --workers 8 --ms 1000 --reps 7
  ./verify/k3_hybrid --variant $v --lock hybrid --spin 1000 --workers 8 --ms 1000 --reps 7
done'
echo "[$(date +%T)] all done" >&2

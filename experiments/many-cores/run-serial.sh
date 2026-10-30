#!/usr/bin/env bash
# Runs every phase-one many-cores experiment's full mode, one at a time.
# Before each job it waits (up to 15 min, polling every 60 s) for the 1-minute
# load average to drop to 3 or below, then runs anyway; load before and after
# each job goes into the job's .log next to its raw output in <id>/results/.
set -u
here=$(cd "$(dirname "$0")" && pwd)
ts=$(date +%Y%m%d-%H%M%S)
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
waitload() {
  for i in $(seq 1 15); do
    awk -v l="$(load1)" 'BEGIN{exit !(l<=3)}' && return 0
    echo "[$(date +%T)] load $(load1), waiting" >&2; sleep 60
  done
  echo "[$(date +%T)] load still $(load1) after 15 min, running anyway" >&2
}
job() { # id name cmd...
  local id=$1 name=$2; shift 2
  mkdir -p "$here/$id/results"
  local out="$here/$id/results/$name-$ts.txt" log="$here/$id/results/$name-$ts.log"
  waitload
  { echo "start $(date) load: $(sysctl -n vm.loadavg)"; echo "cmd: $*"; } > "$log"
  echo "[$(date +%T)] $id/$name start, load $(load1)" >&2
  local t0=$(date +%s)
  ( cd "$here/$id" && "$@" ) > "$out" 2>> "$log"
  local rc=$?
  echo "end $(date) rc=$rc secs=$(( $(date +%s) - t0 )) load: $(sysctl -n vm.loadavg)" >> "$log"
  echo "[$(date +%T)] $id/$name done rc=$rc" >&2
}

job k3 full env REPS=7 MS=1000 ./run.sh
job k3 size bash -c 'for sc in 8 32 128; do for ch in 4 16 64; do for v in edge shared; do
  ./bin/k3-c --variant $v --lock unfair --workers 8 --subs-cap $sc --chunks $ch --ms 1000 --reps 7
  ./bin/k3-rust --variant $v --lock mutex --workers 8 --subs-cap $sc --chunks $ch --ms 1000 --reps 7
done; done; done'
job p1 full ./run.sh --reps 11
job p3 full env REPS=7 ./run.sh
job s1 full env REPS=7 ./run.sh
job s1 work100 env REPS=7 READER=0 WORK=100 WORKERS="1 8 16" ./run.sh
job k1k2 full env REPS=7 ./run.sh
job cache3 full env REPS=7 ./run.sh
job cache3 fetch0 env REPS=7 EXTRA="--fetch-us 0" ./run.sh
echo "[$(date +%T)] all done" >&2

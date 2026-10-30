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

# K3: headline (8 workers) and 1 worker, original binaries
job k3 headline bash -c 'for w in 1 8; do for v in edge shared; do
  for l in unfair spin; do ./bin/k3-c --variant $v --lock $l --workers $w --ms 1000 --reps 7; done
  for l in mutex spin; do ./bin/k3-rust --variant $v --lock $l --workers $w --ms 1000 --reps 7; done
done; done'
# K3 corrected: a barging spin-then-park lock (Go-mutex shape), two spin budgets
job k3 hybrid bash -c 'for w in 1 8 16; do for sp in 64 1000; do for v in edge shared; do
  ./verify/k3_hybrid --variant $v --lock hybrid --spin $sp --workers $w --ms 1000 --reps 7
done; done; done'
# K3 state size at 8 workers, including the cells the original harness refused
job k3 size bash -c 'for sc in 8 32 128; do for ch in 4 16 64; do for v in edge shared; do
  ./verify/k3_hybrid --variant $v --lock unfair --workers 8 --subs-cap $sc --chunks $ch --ms 500 --reps 5
  ./verify/k3_hybrid --variant $v --lock hybrid --spin 64 --workers 8 --subs-cap $sc --chunks $ch --ms 500 --reps 5
done; done; done'

# P1: the full run (it is short)
job p1 full ./run.sh --reps 11

# P3: headline cells, original C and Rust, then the copy without the redundant runnext wakep
job p3 headline bash -c 'for cfg in "100 8" "100 12" "100 16" "500 12"; do set -- $cfg
  for m in fifo barge; do
    bin/p3c --mode $m --workers $2 --cs-ns $1 --out-ns 1000 --ms 1000 --reps 7
    bin/p3rust --mode $m --workers $2 --cs-ns $1 --out-ns 1000 --ms 1000 --reps 7
    verify/p3_fixed --mode $m --workers $2 --cs-ns $1 --out-ns 1000 --ms 1000 --reps 7 --runnext-nowake 1
  done; done'

# S1: 16 workers (and 1 for the work=100 baseline), work 0 and 100, then S3 with a reader
job s1 headline bash -c 'for lang in c rust; do
  for wk in 0 100; do for cfg in one_lock:0 one_unfair:0 atomic:0 stripe_lock:0 stripe_lock:128 stripe_owner:128; do
    bin/s1_$lang --variant ${cfg%%:*} --pad ${cfg##*:} --workers 16 --reader 0 --ms 300 --reps 7 --work $wk
  done; done
  for cfg in atomic:0 stripe_owner:128; do bin/s1_$lang --variant ${cfg%%:*} --pad ${cfg##*:} --workers 1 --reader 0 --ms 300 --reps 7 --work 100; done
  for cfg in atomic:0 stripe_lock:128 stripe_owner:128; do
    bin/s1_$lang --variant ${cfg%%:*} --pad ${cfg##*:} --workers 16 --reader 1 --ms 300 --reps 7 --work 0
  done
done'

# K1 at 1, 8, 16 workers; K2 full, compared with the original output
job k1k2 k1 bash -c 'for b in k1_c k1_rust; do ./bin/$b --workers 1,8,16 --parts 1,64 --dist uniform,zipf --lock spin,os --keys 10000 --reps 7 --ms 200 --qos p; done'
job k1k2 k2 bash -c './bin/k2_c --max 1000,10000,100000 --parts 8,64 --factors 1.0,1.1,1.25,1.5,2,4,10 --measure 20 > verify/k2_c.txt
  ./bin/k2_rust --max 1000,10000,100000 --parts 8,64 --factors 1.0,1.1,1.25,1.5,2,4,10 --measure 20 > verify/k2_rust.txt
  diff <(sed "s/lang=[a-z]*//" verify/k2_c.txt) <(sed "s/lang=[a-z]*//" verify/k2_rust.txt) && echo "k2 c=rust: same"
  diff <(sed "s/lang=[a-z]*//" verify/k2_c.txt) <(sed "s/lang=[a-z]*//" bin/k2_full_c.txt) && echo "k2 rerun=original: same"'

# cache3: every variant at 1, 8, 16 workers with the 50 us fetch, then with no fetch
job cache3 headline env REPS=7 WORKERS="1 8 16" ./run.sh
job cache3 fetch0 env REPS=7 WORKERS="1 16" EXTRA="--fetch-us 0" ./run.sh
echo "[$(date +%T)] all done" >&2

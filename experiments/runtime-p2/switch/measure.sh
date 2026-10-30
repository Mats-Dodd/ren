#!/bin/bash
# Runs every configuration ONE AT A TIME. Each run prints one parseable line:
#   SWITCH lang= bench= n= max= reps= ns_per_op= min_ns_per_op= extra_ns=
#          heap_allocs_per_op= sys_allocs_per_op= bytes_per_task= ... check=ok|FAIL
# and this script appends peak_footprint=<bytes> (from /usr/bin/time -l),
# load=<1-min load average before the run>, and for park
# ext_fp_per_task=<(peak footprint at n - peak at n=1) / n>.
# Before each run it waits (up to 5 min, polling every 20 s) for the 1-minute
# load average to fall to 4 or below, then runs anyway.
#   ./measure.sh            full run   -> results/measure-<ts>.txt
#   ./measure.sh --smoke    every config at n/1000 (min 10), 1 rep, no load wait
#   ./measure.sh --check    every binary's --check, the ASan/UBSan builds included
set -u
cd "$(dirname "$0")"
[ -x build/ren_c ] && [ -x build/raw_c ] && [ -x build/switch_go ] && [ -x build/switch_rust ] || ./build.sh >&2
export GOMAXPROCS=1
mode=${1:-full}
if [ "$mode" = "--check" ]; then
  rc=0
  for b in ren_c raw_c ren_c_asan raw_c_asan switch_go switch_rust; do
    ./build/$b --check || { echo "CHECKFAIL $b"; rc=1; }
  done
  [ $rc = 0 ] && echo "ALL CHECKS ok"
  exit $rc
fi
mkdir -p results
ts=$(date +%Y%m%d-%H%M%S)
out=results/measure-$ts.txt
[ "$mode" = "--smoke" ] && out=results/smoke-$ts.txt
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
waitload() {
  [ "$mode" = "--smoke" ] && return 0
  for _ in $(seq 1 15); do
    awk -v l="$(load1)" 'BEGIN{exit !(l<=4)}' && return 0
    echo "[$(date +%T)] load $(load1), waiting" >&2; sleep 20
  done
}
tf=$(mktemp)
timed() { # cmd... ; sets LINE and FP
  LINE=$(/usr/bin/time -l "$@" 2>"$tf") || true
  FP=$(awk '/peak memory footprint/{print $1}' "$tf")
  grep -q FAIL "$tf" && cat "$tf" >&2
}
run() { # bin bench n reps [max]
  local bin=$1 bench=$2 n=$3 reps=$4 max=${5:-64}
  if [ "$mode" = "--smoke" ]; then n=$(( n / 1000 > 10 ? n / 1000 : 10 )); reps=1; fi
  waitload
  local l0; l0=$(load1)
  timed ./build/$bin --bench $bench --n $n --reps $reps --max $max
  local line="$LINE peak_footprint=$FP load=$l0" fp=$FP
  if [ "$bench" = park ]; then
    timed ./build/$bin --bench park --n 1 --reps 1
    line="$line ext_fp_per_task=$(awk -v a="$fp" -v b="$FP" -v n="$n" 'BEGIN{printf "%.1f", (a-b)/n}')"
  fi
  [ -n "$LINE" ] || line="SWITCH bin=$bin bench=$bench n=$n check=FAIL (no output)"
  echo "$line" | tee -a "$out"
}
{ echo "# $(date) $(sysctl -n machdep.cpu.brand_string) mode=$mode"; } >> "$out"

# 1. ping-pong round trips through two one-slot channels
for b in ren_c raw_c switch_go switch_rust; do run $b pingpong 1000000 7; done
run ren_c pingpong_nested 1000000 7
run switch_rust pingpong_local 1000000 7
# 2. spawn + join one at a time; spawn into a limited scope
for b in ren_c raw_c switch_go switch_rust; do run $b spawn_join 1000000 7; done
for m in 64 1000; do
  for b in ren_c raw_c switch_go switch_rust; do run $b spawn_batch 1000000 7 $m; done
done
# 3. 100k parked tasks: bytes a task, wake-all time
for b in ren_c raw_c switch_go switch_rust; do run $b park 100000 5; done
# 4. fan-out of 1,000 tasks x 10 ops on one instance (and with a yield after each op)
for f in fanout fanout_yield; do
  for b in ren_c raw_c switch_go switch_rust; do run $b $f 1000 63; done
done
rm -f "$tf"
echo "wrote $out" >&2

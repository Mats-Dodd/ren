#!/usr/bin/env bash
# percore: the full Linux measurement on the shared cloud machine (machine
# "cloud", experiments/MACHINE-cloud.md). macOS keeps measure.sh / measure-p2.sh.
#
#   ./measure-cloud.sh [all|base|ext]       (default: all)
#
# - Builds from clean (rm bin/ build/ target/) and runs smoke.sh (build,
#   checks, TSan) under the SHARED lock.
# - Every configuration is ONE command `flock -x $LOCK $0 --one ...` that
#   runs REPS (>= 7) repetitions back to back and records the 1-minute load
#   (/proc/loadavg) and hypervisor steal ticks (/proc/stat) at its start and
#   end. Nothing else runs inside the lock; no two benchmarks overlap.
# - Per configuration: median, min, max and spread = (max-min)/median of the
#   gate metric (mops for the original matrix and for the extension's
#   throughput mode; light_p99_ns for the extension's latency mode). If
#   spread > 10% the configuration is re-run, up to 2 more times; if it is
#   still > 10% the try with the smallest spread is kept and marked NOISY
#   (never a headline). Every try's rep lines stay in the file.
# - The pure-work chunk (200 us) is calibrated once under the exclusive lock
#   (3 calibrations, median iteration count) and written into the header;
#   every extension run gets the same --work-iters.
# - Output: results/cloud/measure-<time>.txt (header, rep lines, a CFG line
#   per configuration, the report), .cmds (every command), .err (stderr).
#
# Env: REPS=7 LOCK=/tmp/ren-bench/lock RESDIR=results/cloud
#      base:  VARIANTS MIXES DISTS WORKERS OPS KEYS (as measure.sh; WORKERS="1 2 4 8")
#      ext:   XRT="ws pc pas_3p1 pas_2p2 pas_4p4" XLOADS="even skewed" XFRACS="25 50 75"
#             XOPS_EVEN=250000 XOPS_SKEWED=100000 (per stream, 4 streams)
#      DRY=1  print the commands, run nothing
set -uo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$SELF")"
LOCK=${LOCK:-/tmp/ren-bench/lock}
REPS=${REPS:-7}
MAXTRIES=3
SPREAD_MAX=0.10
load1() { cut -d' ' -f1 /proc/loadavg; }
steal() { awk '/^cpu /{print $9}' /proc/stat; }

# ---- one configuration, run inside flock -x by the main loop ----
if [ "${1:-}" = "--one" ]; then
  shift
  name=$1 try=$2 reps=$3 errf=$4; shift 4
  l0=$(load1); s0=$(steal); t0=$(date +%s.%N)
  for r in $(seq 1 "$reps"); do
    line=$("$@" 2>>"$errf")
    [ -n "$line" ] || line="PC crashed=1 ok=0"
    echo "cfg=$name try=$try rep=$r $line"
  done
  l1=$(load1); s1=$(steal); t1=$(date +%s.%N)
  echo "LOAD cfg=$name try=$try load1_start=$l0 load1_end=$l1 steal_ticks=$((s1 - s0)) secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
  exit 0
fi

mode=${1:-all}
case $mode in all|base|ext|oversub) ;; *) echo "usage: $0 [all|base|ext|oversub]" >&2; exit 2 ;; esac
[ "$REPS" -ge 7 ] || { echo "REPS must be >= 7" >&2; exit 2; }
mkdir -p /tmp/ren-bench && touch "$LOCK"
RESDIR=${RESDIR:-results/cloud}
mkdir -p "$RESDIR"
ts=$(date +%Y%m%d-%H%M%S)
out=$RESDIR/measure-$ts.txt
cmds=$RESDIR/measure-$ts.cmds
case $RESDIR in /*) errf=$RESDIR/measure-$ts.err ;; *) errf=$PWD/$RESDIR/measure-$ts.err ;; esac
: >"$out"; : >"$cmds"; : >"$errf"
DRY=${DRY:-0}

if [ "$DRY" != 1 ]; then
  rm -rf bin build target
  flock -s "$LOCK" ./smoke.sh >"$RESDIR/smoke-$ts.log" 2>&1 || { echo "smoke FAILED, see $RESDIR/smoke-$ts.log" >&2; exit 1; }
fi

{
  echo "# percore measurement, machine: cloud (claude.ai cloud container; see experiments/MACHINE-cloud.md)"
  echo "# NOT macOS: the macOS (Apple M4 Max) reference is the files directly in results/."
  echo "# date: $(date -u '+%F %T UTC')  host kernel: $(uname -r)  cpus: $(nproc)  model: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
  echo "# git: $(git rev-parse --short HEAD 2>/dev/null || echo '?')$(git diff --quiet -- . 2>/dev/null || echo ' (+uncommitted changes in percore/)')"
  echo "# compiler: $(clang --version | head -1); TSan build: gcc $(gcc -dumpfullversion)"
  echo "# mode: $mode  reps per config: $REPS  re-run if spread > $SPREAD_MAX, up to $MAXTRIES tries; NOISY if still above"
  echo "# gate metric: mops (original matrix, extension throughput mode), light_p99_ns (extension latency mode)"
  echo "# every config ran alone under flock -x $LOCK; LOAD lines give /proc/loadavg 1-min load and /proc/stat steal ticks (USER_HZ) at its start and end"
} >>"$out"

run_cfg() { # name gate cmd...
  local name=$1 gate=$2; shift 2
  local best_try="" best_sp="" sline="" try
  echo "$name: $*" >>"$cmds"
  if [ "$DRY" = 1 ]; then echo "flock -x $LOCK $SELF --one $name 1 $REPS ERR $*"; return; fi
  for try in $(seq 1 $MAXTRIES); do
    flock -x "$LOCK" "$SELF" --one "$name" "$try" "$REPS" "$errf" "$@" >>"$out"
    local s; s=$(python3 -I cloud.py stats "$out" "$name" "$try" "$gate")
    local sp; sp=$(echo "$s" | tr ' ' '\n' | sed -n 's/^spread=//p')
    if [ -z "$best_sp" ] || awk -v a="$sp" -v b="$best_sp" 'BEGIN{exit !(a<b)}'; then best_sp=$sp; best_try=$try; sline=$s; fi
    awk -v a="$sp" -v m="$SPREAD_MAX" 'BEGIN{exit !(a<=m)}' && break
  done
  local noisy=0
  awk -v a="$best_sp" -v m="$SPREAD_MAX" 'BEGIN{exit !(a<=m)}' || noisy=1
  local ld; ld=$(grep "^LOAD cfg=$name try=$best_try " "$out" | cut -d' ' -f4-)
  echo "CFG name=$name used_try=$best_try tries=$try noisy=$noisy $sline $ld" | tee -a "$out"
}

# ---- the original matrix (closed loop), 1 2 4 workers + 8 oversubscribed ----
base() {
  local VARIANTS=${VARIANTS:-"ws_one ws_worker ws_keyed ws_sharded pc_spin pc_park pc_spin_if4 pc_park_if4"}
  local MIXES=${MIXES:-"95 50 5"} DISTS=${DISTS:-"uniform zipf"} WORKERS=${WORKERS:-"1 2 4 8"}
  local OPS=${OPS:-200000} KEYS=${KEYS:-1048576}
  local d m w v base extra
  for d in $DISTS; do for m in $MIXES; do for w in $WORKERS; do for v in $VARIANTS; do
    case $v in
      *_if4) base=${v%_if4}; extra="--inflight 4" ;;
      *) base=$v; extra="" ;;
    esac
    # shellcheck disable=SC2086
    run_cfg "b_${v}_g${m}_${d}_w${w}" mops ./bin/percore --variant $base --get-pct $m --dist $d --workers $w \
      --ops $OPS --keys $KEYS --seed 42 $extra
  done; done; done; done
}

# ---- the extension (open loop): work_stealing, per_core, place_at_spawn ----
rt_args() {
  case $1 in
    ws)      echo "--variant work_stealing --workers 4" ;;
    pc)      echo "--variant per_core --workers 4 --inflight 4" ;;
    pas_3p1) echo "--variant place_at_spawn --workers 3 --pool 1 --inflight 4" ;;
    pas_2p2) echo "--variant place_at_spawn --workers 2 --pool 2 --inflight 4" ;;
    pas_4p4) echo "--variant place_at_spawn --workers 4 --pool 4 --inflight 4" ;; # 8 threads on 4 vCPUs: oversubscribed, unpinned
  esac
}
load_args() {
  case $1 in
    even)   echo "--dist uniform --heavy-pct 0 --ops ${XOPS_EVEN:-250000}" ;;
    skewed) echo "--dist zipf --theta 0.99 --heavy-pct 5 --work-iters $WITERS --ops ${XOPS_SKEWED:-100000}" ;;
  esac
}
ext() {
  local XRT=${XRT:-"ws pc pas_3p1 pas_2p2 pas_4p4"} XLOADS=${XLOADS:-"even skewed"} XFRACS=${XFRACS:-"25 50 75"}
  local common="--get-pct 50 --keys 1048576 --conns 4 --shards 4 --seed 42"
  if [ "$DRY" = 1 ]; then WITERS=46000; else
    # Calibrate the 200 us chunk: 3 runs under the exclusive lock, median iteration count.
    flock -x "$LOCK" sh -c "for i in 1 2 3; do ./bin/percore --calibrate --work-us 200 --pin on; done; ./bin/percore --gap-probe" \
      | sed 's/^/# /' >>"$out"
    WITERS=$(grep '^# CAL os=' "$out" | tail -3 | sed 's/.* iters=\([0-9]*\).*/\1/' | sort -n | sed -n 2p)
    echo "# calibration: --work-iters $WITERS (median of the 3 CAL lines above) for every skewed run" >>"$out"
  fi
  local l rt f
  # XTHR=0 skips throughput mode; XWSM_even / XWSM_skewed then give work_stealing's
  # throughput (Mreq/s) from an earlier file, so a re-run offers the same rates.
  # XTAG is appended to the config names (e.g. _long for a run with more ops).
  local tag=${XTAG:-}
  if [ "${XTHR:-1}" = 1 ]; then
  for l in $XLOADS; do for rt in $XRT; do
    # shellcheck disable=SC2046
    run_cfg "x_${l}_thr_${rt}${tag}" mops ./bin/percore $common $(rt_args $rt) $(load_args $l) --rate 0
  done; done
  fi
  for l in $XLOADS; do
    local wsm ov; ov=XWSM_$l; ov=${!ov:-}
    if [ -n "$ov" ]; then wsm=$ov; else
    wsm=$( [ "$DRY" = 1 ] && echo 1.0 || python3 -I cloud.py ws "$out" "$l"); fi
    echo "# $l: work_stealing throughput-mode median ${wsm} Mreq/s; latency runs offer ${XFRACS}% of it" | tee -a "$out"
    for f in $XFRACS; do
      local rate; rate=$(awk -v m="$wsm" -v f="$f" 'BEGIN{printf "%.0f", m*1e6*f/100}')
      [ "$rate" -gt 0 ] || { echo "# $l: no ws throughput, skipping latency at $f%" | tee -a "$out"; continue; }
      for rt in $XRT; do
        # shellcheck disable=SC2046
        run_cfg "x_${l}_lat${f}_${rt}${tag}" light_p99_ns ./bin/percore $common $(rt_args $rt) $(load_args $l) --rate "$rate"
      done
    done
  done
}

# ---- oversubscription check (4 vCPUs): same variants at 3,5,6 workers (pin auto),
# 4 workers unpinned, 8 workers pinned two per CPU. Compare with base's w4 (pinned)
# and w8 (unpinned) to separate "more threads than CPUs" from "pinning".
oversub() {
  local VARIANTS=${OVARIANTS:-"ws_one ws_sharded pc_spin pc_park pc_spin_if4"}
  local OPS=${OPS:-200000} KEYS=${KEYS:-1048576}
  local v base extra w p
  for v in $VARIANTS; do
    case $v in *_if4) base=${v%_if4}; extra="--inflight 4" ;; *) base=$v; extra="" ;; esac
    for wp in 3:auto 4:off 5:auto 6:auto 8:on; do
      w=${wp%:*}; p=${wp#*:}
      # shellcheck disable=SC2086
      run_cfg "o_${v}_g50_uniform_w${w}_pin${p}" mops ./bin/percore --variant $base --get-pct 50 --dist uniform --workers $w \
        --ops $OPS --keys $KEYS --seed 42 --pin $p $extra
    done
  done
}

case $mode in
  all) ext; base ;;
  base) base ;;
  ext) ext ;;
  oversub) oversub ;;
esac
[ "$DRY" = 1 ] && exit 0

{
  echo "# ---- checks"
  echo "# rep lines with ok=0: $(grep '^cfg=' "$out" | grep -c ' ok=0' || true)"
  # Original matrix: same (dist, mix, workers) => same trace => same final key set in every variant.
  grep -E '^cfg=(b|o)_' "$out" | awk '{ for (i=1;i<=NF;i++){ split($i,a,"="); f[a[1]]=a[2] }
       k=f["dist"]" "f["get_pct"]" "f["workers"]
       if (!(k in ks)) ks[k]=f["keyset_sum"]; else if (ks[k]!=f["keyset_sum"]) { print "# keyset differs at " k; n++ } }
     END { print "# base keyset mismatches: " n+0 }'
  echo "# ---- report"
  python3 -I cloud.py report "$out" | sed 's/^/# /'
} | tee -a "$out" >&2
echo "results in $out" >&2

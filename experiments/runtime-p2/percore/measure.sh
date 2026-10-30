#!/bin/sh
# The full measurement. Runs every configuration ONE AT A TIME (no two
# processes overlap), each as its own command, each printing one line:
#   PC lang=c variant= get_pct= dist= ... wall_ms= mops= p50_ns= p99_ns= ... ok=
# Lines go to stdout and to results/measure-<time>.txt; each command is
# echoed to results/measure-<time>.cmds first.
#
#   ./measure.sh [--reps 3]
# Env filters (space-separated lists) narrow the matrix:
#   VARIANTS="ws_one ws_worker ws_keyed ws_sharded pc_spin pc_park pc_spin_if4 pc_park_if4"
#   MIXES="95 50 5"  DISTS="uniform zipf"  WORKERS="1 2 4 8 12 16"
#   OPS=200000 (per worker)  KEYS=1048576
# Afterwards it checks that every variant ended with the same key set at
# each (mix, dist, workers), and that every line says ok=1.
# The machine is shared: run it alone, and read absolute numbers as +-40%
# (phase 1); compare ratios within one pass.
set -eu
cd "$(dirname "$0")"
reps=3
[ "${1:-}" = "--reps" ] && reps=$2
[ -x bin/percore ] || ./build.sh >&2
VARIANTS=${VARIANTS:-"ws_one ws_worker ws_keyed ws_sharded pc_spin pc_park pc_spin_if4 pc_park_if4"}
MIXES=${MIXES:-"95 50 5"}
DISTS=${DISTS:-"uniform zipf"}
WORKERS=${WORKERS:-"1 2 4 8 12 16"}
OPS=${OPS:-200000}
KEYS=${KEYS:-1048576}
mkdir -p results
ts=$(date +%Y%m%d-%H%M%S)
out=results/measure-$ts.txt
cmds=results/measure-$ts.cmds
: >"$out"; : >"$cmds"
for rep in $(seq 1 "$reps"); do
for d in $DISTS; do
for m in $MIXES; do
for w in $WORKERS; do
for v in $VARIANTS; do
  case $v in
    *_if4) base=${v%_if4}; extra="--inflight 4" ;;
    *) base=$v; extra="" ;;
  esac
  cmd="./bin/percore --variant $base --get-pct $m --dist $d --workers $w --ops $OPS --keys $KEYS --seed 42 $extra"
  echo "rep=$rep $cmd" >>"$cmds"
  line=$($cmd 2>>results/measure-$ts.err || true)
  [ -n "$line" ] || line="PC variant=$base get_pct=$m dist=$d workers=$w ok=0 crashed=1"
  echo "rep=$rep $line" | tee -a "$out"
done; done; done; done; done
echo "--- checks" >&2
bad=$(grep -c 'ok=0' "$out" || true)
echo "lines with ok=0: $bad" >&2
# Same (dist, mix, workers) => same trace => same final key set in every variant.
awk '{ for (i=1;i<=NF;i++){ split($i,a,"="); f[a[1]]=a[2] }
       k=f["dist"]" "f["get_pct"]" "f["workers"]
       if (!(k in ks)) ks[k]=f["keyset_sum"]; else if (ks[k]!=f["keyset_sum"]) { print "keyset differs at " k; n++ } }
     END { print "keyset mismatches: " n+0 }' "$out" >&2
echo "results in $out" >&2

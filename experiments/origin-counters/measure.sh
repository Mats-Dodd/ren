#!/bin/sh
# The timing matrix. Runs every configuration ONE AT A TIME, each as its own
# process printing one line:
#   OR scheme= wl= workers= spin= N= ... mdps= close_p50_ns= close_p99_ns= ... ok=
# Lines go to stdout and results/measure-<time>.txt (prefixed rep= and
# suffixed load1=); commands go to results/measure-<time>.cmds.
#
#   ./measure.sh [--reps 2]
# Env filters narrow the matrix:
#   SCHEMES="none atomic vector credit credit_soft home"  WLS="1 2 3 4"
#   SPINS="0 100 1000"  WORKERS="1 2 4 8 12 16"  SIDE=1 (admission N=64, W4 N=16)
# Deliveries per worker: 1.5M at spin 0, 600k at 100, 120k at 1000.
# The machine is shared: read absolute numbers as +-40%; compare ratios.
set -eu
cd "$(dirname "$0")"
reps=2
[ "${1:-}" = "--reps" ] && reps=$2
[ -x bin/origins ] || ./build.sh >&2
SCHEMES=${SCHEMES:-"none atomic vector credit credit_soft home"}
WLS=${WLS:-"1 2 3 4"}
SPINS=${SPINS:-"0 100 1000"}
WORKERS=${WORKERS:-"1 2 4 8 12 16"}
SIDE=${SIDE:-1}
mkdir -p results
ts=$(date +%Y%m%d-%H%M%S)
out=results/measure-$ts.txt
cmds=results/measure-$ts.cmds
: >"$out"; : >"$cmds"
per() { case $1 in 0) echo 1500000;; 100) echo 600000;; *) echo 120000;; esac; }
run() { # rep, args...
  rep=$1; shift
  cmd="./bin/origins $*"
  echo "rep=$rep $cmd" >>"$cmds"
  line=$($cmd 2>>results/measure-$ts.err || true)
  [ -n "$line" ] || line="OR $* ok=0 crashed=1"
  load=$(sysctl -n vm.loadavg | awk '{print $2}')
  echo "rep=$rep $line load1=$load" | tee -a "$out"
}
for rep in $(seq 1 "$reps"); do
  for wl in $WLS; do
    N=4096; [ "$wl" = 4 ] && N=4
    for sp in $SPINS; do
      for w in $WORKERS; do
        for s in $SCHEMES; do
          run "$rep" --scheme "$s" --wl "$wl" --workers "$w" --spin "$sp" --N "$N" --deliveries $((w * $(per "$sp")))
        done
      done
    done
  done
  if [ "$SIDE" = 1 ]; then
    for w in $WORKERS; do
      for s in $SCHEMES; do
        for wl in 1 2; do run "$rep" --scheme "$s" --wl "$wl" --workers "$w" --spin 100 --N 64 --deliveries $((w * 600000)); done
        run "$rep" --scheme "$s" --wl 4 --workers "$w" --spin 100 --N 16 --deliveries $((w * 600000))
      done
    done
  fi
done
echo "--- checks" >&2
echo "lines with ok=0: $(grep -c 'ok=0' "$out" || true)" >&2
echo "results in $out" >&2

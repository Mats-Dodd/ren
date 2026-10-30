#!/usr/bin/env bash
# tests/lostwake.sh: the lost-wake stress test (Phase B open issue: Rust
# t_cancel x8 hung 2-3/200, Zig W2 x4 hung about 8/15 in one loaded window).
# Runs each (workload, driver, workers) cell RUNS times with a timeout and
# counts exits: ok, fail (non-zero), hang (timeout). Runs under the SHARED lock.
#
#   tests/lostwake.sh <bindir> [RUNS]
#   env: WLS="w1 w2 t_cancel w3 t_timer"  DRIVERS="epoll uring"  WORKERS="4 8"
#        JOBS=2 (concurrent runs; >1 loads the 4 vCPUs so wakes race harder)
#        TMO=10 (seconds per run)  OUT=<file> (summary, appended)
set -uo pipefail
if [ -z "${REN_FLOCKED:-}" ]; then
  mkdir -p /tmp/ren-bench; export REN_FLOCKED=1
  exec flock -s /tmp/ren-bench/lock "$0" "$@"
fi
B=$(cd "${1:?usage: lostwake.sh <bindir> [RUNS]}" && pwd)
RUNS=${2:-1000}
WLS=${WLS:-"w1 w2 t_cancel w3 t_timer"}
DRIVERS=${DRIVERS:-"epoll uring"}
WORKERS=${WORKERS:-"4 8"}
JOBS=${JOBS:-2}
TMO=${TMO:-10}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ren-lw.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

args() {
  case $1 in
    w1) echo "--n 20000" ;; w2) echo "--n 20000" ;; w3) echo "--n 2000" ;; *) echo "" ;;
  esac
}
one() {   # wl drv w i -> prints "rc"
  local wl=$1 d=$2 w=$3 i=$4
  timeout -s KILL "$TMO" "$B/harness" "$wl" --driver "$d" --workers "$w" $(args "$wl") --quiet \
    >"$TMP/o.$wl.$d.$w.$i" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then rm -f "$TMP/o.$wl.$d.$w.$i"; fi
  echo "$rc"
}
export -f one args; export B TMO TMP
echo "lostwake: $(basename "$B") runs=$RUNS jobs=$JOBS tmo=${TMO}s loadavg_start=$(cut -d' ' -f1 /proc/loadavg) $(date -u +%FT%TZ)"
total_hang=0; total_fail=0
for wl in $WLS; do for d in $DRIVERS; do for w in $WORKERS; do
  t0=$(date +%s)
  seq 1 "$RUNS" | xargs -P "$JOBS" -I{} bash -c "one $wl $d $w {}" > "$TMP/rcs"
  ok=$(grep -cx 0 "$TMP/rcs"); hang=$(grep -cxE '137|124' "$TMP/rcs"); fail=$((RUNS - ok - hang))
  total_hang=$((total_hang + hang)); total_fail=$((total_fail + fail))
  line="cell $wl $d x$w: ok=$ok fail=$fail hang=$hang of $RUNS ($(( $(date +%s) - t0 ))s)"
  echo "$line"
  if [ $((fail + hang)) -gt 0 ]; then
    f=$(ls "$TMP"/o.$wl.$d.$w.* 2>/dev/null | head -1)
    [ -n "$f" ] && sed 's/^/     | /' "$f" | tail -8
  fi
done; done; done
echo "lostwake total: hang=$total_hang fail=$total_fail loadavg_end=$(cut -d' ' -f1 /proc/loadavg)"
[ $((total_hang + total_fail)) -eq 0 ]

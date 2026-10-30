#!/usr/bin/env bash
# Spin-budget sweep on the cloud machine (Linux, 4 vCPUs; experiments/MACHINE-cloud.md).
#
#   ./measure-cloud.sh [--shard K/N] [--filter REGEX] [--limit N] [--resume STAMP] [--dry-run]
#
# The matrix is commands.sh with WORKERS="2 4 8" and WAIT_WORKERS=4 (810
# configs): 2 and 4 workers are pinned one per CPU, so a caller and its owner
# are always on distinct cores; 8 workers are unpinned and oversubscribed by
# construction (pin=0 on the line): they say what this machine does, not what
# the runtime does.
#
# Rules (shared machine):
#   - every configuration is one `flock -x /tmp/ren-bench/lock` acquisition:
#     the 1-minute load (/proc/loadavg) is read at its start and its end, then
#     REPS (default 7) runs of bin/spin, each a separate process;
#   - per config: median, min, max and spread = (max-min)/median of each
#     metric (cloudstats.py). If the spread of a gate metric (GATE, default
#     hop_p99_ns,cpu_ns_per_hop) is > 10%, the config is re-run, up to 2 more
#     times; if it is still > 10% the last try is kept and marked NOISY
#     (noisy=1 on its SPIN lines; analyze.py drops those unless --keep-noisy);
#   - the build and the --check pre-flight run under `flock -s`; calibration
#     (a timed loop) runs under `flock -x`.
#
# Output, all with a "machine=cloud" header, in results/cloud/:
#   full-<stamp>.txt     SPIN lines of the kept try of every config (rep=, try=,
#                        load1_start=, load1_end=, noisy=), input to analyze.py
#   summary-<stamp>.txt  one CFG line per config: load, med/min/max/spread, status
#   raw-<stamp>.txt      every try, including the ones re-run
# Then:
#   python3 analyze.py results/cloud/full-<stamp>.txt --wait-workers 4
#
# --shard K/N runs configs whose index (0-based, in commands.sh order) is K mod N.
# --resume STAMP appends to existing files of that stamp and skips configs
# already in its summary (a run longer than one sitting can be split).
set -uo pipefail
cd "$(dirname "$0")"
LOCK=/tmp/ren-bench/lock
REPS=${REPS:-7}
TRIES=3 # 1 + up to 2 re-runs
WARM_MS=${WARM_MS:-50}
WINDOW_MS=${WINDOW_MS:-400}
GATE=${GATE:-hop_p99_ns,cpu_ns_per_hop}
export WORKERS=${WORKERS:-2 4 8}
export WAIT_WORKERS=${WAIT_WORKERS:-4}
RESULTS=${RESULTS:-results/cloud} # override only for testing the script itself
load1() { awk '{print $1}' /proc/loadavg; }

# Internal: one configuration, called as `flock -x $LOCK ./measure-cloud.sh --one ...`.
if [ "${1:-}" = "--one" ]; then
  npi=$2 try=$3; shift 3
  echo "LOAD start=$(load1)"
  for r in $(seq 1 "$REPS"); do
    # shellcheck disable=SC2068
    ./bin/spin $@ --ns-per-iter "$npi" --warm-ms "$WARM_MS" --window-ms "$WINDOW_MS" \
      | sed "s/^SPIN /SPIN rep=$r try=$try /" \
      || echo "SPIN rep=$r try=$try FAIL exit args: $*"
  done
  echo "LOAD end=$(load1)"
  exit 0
fi

shard="" filter="" limit=0 resume="" dry=0
while [ $# -gt 0 ]; do
  case $1 in
    --shard) shard=$2; shift 2 ;;
    --filter) filter=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --resume) resume=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "usage: $0 [--shard K/N] [--filter REGEX] [--limit N] [--resume STAMP] [--dry-run]" >&2; exit 2 ;;
  esac
done
[ "$(uname -s)" = Linux ] || { echo "measure-cloud.sh is for the Linux cloud machine; use measure.sh on macOS" >&2; exit 2; }
mkdir -p /tmp/ren-bench "$RESULTS"

cfgs=$(./commands.sh | awk -v sh="$shard" -v re="$filter" '
  BEGIN { if (sh != "") { split(sh, a, "/"); k = a[1]; n = a[2] } }
  { i = NR - 1 }
  sh != "" && i % n != k { next }
  re != "" && $0 !~ re { next }
  { print }')
[ "$limit" -gt 0 ] && cfgs=$(printf '%s\n' "$cfgs" | head -n "$limit")
ncfg=$(printf '%s\n' "$cfgs" | grep -c . || true)
if [ "$dry" = 1 ]; then
  printf '%s\n' "$cfgs" | while read -r a; do echo "flock -x $LOCK ./measure-cloud.sh --one <npi> <try> $a"; done
  echo "# $ncfg configs x $REPS reps (+ re-runs)" >&2
  exit 0
fi

if [ ! -x bin/spin ]; then flock -s "$LOCK" ./build.sh >&2 || exit 1; fi
flock -s "$LOCK" ./bin/spin --check >/dev/null || { echo "spin --check FAILED" >&2; exit 1; }

stamp=${resume:-$(date +%Y%m%d-%H%M%S)}
full=$RESULTS/full-$stamp.txt
summ=$RESULTS/summary-$stamp.txt
raw=$RESULTS/raw-$stamp.txt
if [ -n "$resume" ] && [ -f "$summ" ]; then
  npi=$(sed -n 's/.*ns_per_iter=\([0-9.]*\).*/\1/p' "$summ" | head -1)
else
  npi=$(flock -x "$LOCK" ./bin/spin --calibrate)
  cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)
  hdr="# machine=cloud spin sweep stamp=$stamp ns_per_iter=$npi reps=$REPS tries=$TRIES warm_ms=$WARM_MS window_ms=$WINDOW_MS workers=\"$WORKERS\" wait_workers=$WAIT_WORKERS gate=$GATE limit=0.10 shard=${shard:-all} filter=${filter:-none} cpus=$(nproc) kernel=$(uname -r) cpu=\"$cpu\" (see experiments/MACHINE-cloud.md)"
  for f in "$full" "$summ" "$raw"; do echo "$hdr" > "$f"; done
fi
echo "# machine=cloud: $ncfg configs, results in $summ" >&2

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
n=0
printf '%s\n' "$cfgs" | while read -r args; do
  [ -n "$args" ] || continue
  n=$((n + 1))
  if [ -n "$resume" ] && grep -qF "args=\"$args\"" "$summ"; then continue; fi
  t=1
  while :; do
    # shellcheck disable=SC2086
    flock -x "$LOCK" ./measure-cloud.sh --one "$npi" "$t" $args > "$tmp"
    cat "$tmp" >> "$raw"
    last=0; [ "$t" -ge "$TRIES" ] && last=1
    # shellcheck disable=SC2086
    line=$(python3 cloudstats.py "$tmp" "$t" "$last" "$REPS" "$GATE" $args); rc=$?
    echo "$line" >> "$raw"
    if [ $rc -ne 3 ]; then break; fi
    t=$((t + 1))
  done
  echo "$line" >> "$summ"
  l0=$(sed -n 's/^LOAD start=//p' "$tmp"); l1=$(sed -n 's/^LOAD end=//p' "$tmp")
  noisy=0; [ $rc -eq 4 ] && noisy=1
  grep '^SPIN ' "$tmp" | sed "s/\$/ load1_start=$l0 load1_end=$l1 noisy=$noisy/" >> "$full"
  st=$(printf '%s\n' "$line" | sed -n 's/.* status=\([A-Z a-z]*\) args=.*/\1/p')
  echo "[$n/$ncfg] $st try=$t load=$l0..$l1 $args" >&2
done
nf=$(grep -c ' status=FAIL' "$summ" || true)
nn=$(grep -c ' status=NOISY' "$summ" || true)
nc=$(grep -c '^CFG' "$summ" || true)
echo "# done: $nc configs, $nn NOISY, $nf FAIL (in $summ)" >&2 # not appended: a --resume would repeat it
[ "$nf" -eq 0 ]

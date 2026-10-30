#!/usr/bin/env bash
# c/bugs-rate.sh <P> <N> <name> <bin-profile> <cmd...>: run one detector N times
# against bin/c-<profile>-<P>/ and log how many runs failed (machine "cloud").
# The command is run from that bindir. Runs under flock -s.
set -uo pipefail
if [ -z "${REN_FLOCKED:-}" ]; then
  mkdir -p /tmp/ren-bench; export REN_FLOCKED=1
  exec flock -s /tmp/ren-bench/lock "$0" "$@"
fi
P=$1 N=$2 name=$3 prof=$4; shift 4
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tag=c-$prof; [ "$P" = P0 ] || tag=$tag-$P
B=$ROOT/bin/$tag
L=$ROOT/results/cloud/bugs-c/$P/rate-$name.log
echo "# machine cloud, $(date -u +%FT%TZ), plant $P, $tag: $* x$N" > "$L"
fails=0; first=""; t0=$(date +%s.%N)
for i in $(seq "$N"); do
  if ! (cd "$B" && timeout 120 "$@") > "$L.tmp" 2>&1; then
    fails=$((fails + 1)); [ -n "$first" ] || { first=$i; echo "## first failing run $i" >> "$L"; head -40 "$L.tmp" >> "$L"; }
  fi
done
rm -f "$L.tmp"
t1=$(date +%s.%N)
echo "result: $name $tag failed $fails/$N first_fail_run=${first:-none} total_s=$(echo "$t1 - $t0" | bc)" | tee -a "$L"

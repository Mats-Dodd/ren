#!/bin/sh
# HY's home made sticky: after a failed take (an in-place taker beat the
# home's queue) the home keeps the instance STICKY_US before it may release.
# C and M10, 8 interleaved rounds: H, HY+spin300 with STICKY_US 0, 20, 100.
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-8}
SECS=${SECS:-2}
mkdir -p results
out=results/sticky-$(date +%Y%m%d-%H%M%S).txt
echo "# machine: $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)" > "$out"
run() { sc=$1; tag=$2; shift 2; t=""; [ -n "$tag" ] && t="tuned=$tag "; echo "RUN round=$r scen=$sc $t$(env "$@" | head -1)" >> "$out"; }
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  for sc in C M10; do
    p=100; [ $sc = M10 ] && p=10
    run $sc fast SHARE_PCT=$p FAST=1 build/server_a ship 8 16 0 0 $SECS
    for st in 0 20 100; do
      run $sc spin300-sticky$st SHARE_PCT=$p FAST=1 HOLDSTAT=1 TRY_SPIN_NS=300 STICKY_US=$st build/server_a hy 8 16 0 0 $SECS
    done
    run $sc "" SHARE_PCT=$p build/server_b unfair 8 16 0 0 $SECS
  done
done
echo "$out"

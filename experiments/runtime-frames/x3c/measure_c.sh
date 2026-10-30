#!/bin/sh
# A follow-up on C (8 x 16, short holds): HY's bimodal rounds. 10 interleaved
# rounds of H, HY, HY with LINGER_US=2 (the home keeps the instance 2 us
# after its last record), HY with TRY_SPIN_NS=300, and os_unfair_lock. HY
# runs time their in-place holds (HOLDSTAT=1): a hold over 20 us is a holder
# the OS took off its core.
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-10}
SECS=${SECS:-2}
mkdir -p results
out=results/c-$(date +%Y%m%d-%H%M%S).txt
echo "# machine: $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)" > "$out"
run() { sc=$1; tag=$2; shift 2; t=""; [ -n "$tag" ] && t="tuned=$tag "; echo "RUN round=$r scen=$sc $t$(env "$@" | head -1)" >> "$out"; }
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  run C fast FAST=1 build/server_a ship 8 16 0 0 $SECS
  run C fast FAST=1 HOLDSTAT=1 build/server_a hy 8 16 0 0 $SECS
  run C linger2 FAST=1 HOLDSTAT=1 LINGER_US=2 build/server_a hy 8 16 0 0 $SECS
  run C spin300 FAST=1 HOLDSTAT=1 TRY_SPIN_NS=300 build/server_a hy 8 16 0 0 $SECS
  run C "" build/server_b unfair 8 16 0 0 $SECS
done
echo "$out"

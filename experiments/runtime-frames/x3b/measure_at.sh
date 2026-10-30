#!/bin/sh
# `at` under per_core: ship each operation vs move the task (two hops), for
# blocks of 1, 4 and 16 operations, with the home serving and dedicated.
# With the home serving, its own connections never hop, so compare
# remote_req_per_s (requests completed on the other 7 workers) too.
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-7}
SECS=${SECS:-2}
mkdir -p results
out=results/at-$(date +%Y%m%d-%H%M%S).txt
echo "# machine: $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)" > "$out"
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  for n in 1 4 16; do
    for s in ship move shipded moveded; do echo "RUN round=$r scen=A$n $(OPS=$n build/server_a $s 8 16 0 0 $SECS | head -1)" >> "$out"; done
    echo "RUN round=$r scen=A$n $(OPS=$n build/server_b unfair 8 16 0 0 $SECS | head -1)" >> "$out"
  done
done
echo "$out"

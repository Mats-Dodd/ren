#!/bin/sh
# Interleaved X1 runs: ROUNDS rounds, each running every variant once on both
# benches (each run = 5 reps, its median printed). Appends to results/raw-<stamp>.txt.
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-7}
mkdir -p results
out=results/raw-$(date +%Y%m%d-%H%M%S).txt
{ echo "# machine: $(sysctl -n machdep.cpu.brand_string) $(sysctl -n hw.ncpu) cpus, $(sw_vers -productVersion)"
  echo "# clang: $(clang --version | head -1)"; echo "# tcc: $(tcc -v)"; } > "$out"
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  for b in pingpong pingpong_nested; do
    for v in base_clang reg_clang reg_noinl_clang reg_nochk_clang; do
      echo "RUN round=$r variant=$v $(build/$v --bench $b --n 2000000 --reps 5)" >> "$out"
    done
    for v in base_tcc reg_tcc; do
      echo "RUN round=$r variant=$v $(build/$v --bench $b --n 500000 --reps 5)" >> "$out"
    done
  done
done
echo "$out"

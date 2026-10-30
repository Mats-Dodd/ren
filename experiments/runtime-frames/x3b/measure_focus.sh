#!/bin/sh
# A focused, longer session of the decisive variants (C, M, A4, A16), run
# when the shared machine was quieter. Same format as measure.sh.
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-7}
SECS=${SECS:-2}
mkdir -p results
out=results/focus-$(date +%Y%m%d-%H%M%S).txt
echo "# machine: $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)" > "$out"
run() {
  sc=$1; shift
  tag=""; case "$*" in *FAST=1*) tag="tuned=fast ";; esac
  echo "RUN round=$r scen=$sc $tag$(env "$@" | head -1)" >> "$out"
}
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  for s in park p2 ship shipded; do run C build/server_a $s 8 16 0 0 $SECS; done
  run C FAST=1 build/server_a ship 8 16 0 0 $SECS
  for s in unfair spin; do run C build/server_b $s 8 16 0 0 $SECS; done
  for s in park p2 ship; do run M SHARE_PCT=10 build/server_a $s 8 16 0 0 $SECS; done
  run M SHARE_PCT=10 FAST=1 build/server_a ship 8 16 0 0 $SECS
  run M SHARE_PCT=10 build/server_b unfair 8 16 0 0 $SECS
  for n in 4 16; do
    for s in ship move; do run A$n OPS=$n build/server_a $s 8 16 0 0 $SECS; done
    run A$n OPS=$n build/server_b unfair 8 16 0 0 $SECS
  done
done
echo "$out"

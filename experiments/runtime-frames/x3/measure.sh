#!/bin/sh
# Interleaved X3 runs: ROUNDS rounds of every scenario and strategy, SECS each.
#   U: 1 worker, 16 connections, no hold           (uncontended)
#   C: 8 workers x 16 connections, no hold         (contended, short holds)
#   L: 8 workers x 16 connections, 100 us hold in put, one background task a worker
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-5}
SECS=${SECS:-2}
mkdir -p results
out=results/raw-$(date +%Y%m%d-%H%M%S).txt
{ echo "# machine: $(sysctl -n machdep.cpu.brand_string) $(sysctl -n hw.ncpu) cpus ($(sysctl -n hw.perflevel0.physicalcpu)P+$(sysctl -n hw.perflevel1.physicalcpu)E), macOS $(sw_vers -productVersion)"
  echo "# clang: $(clang --version | head -1)"
  echo "# code size (__text bytes, path objects):"
  size -m build/path_a.o | sed 's/^/#   a: /' | grep -i "__text\|total" || true
  size -m build/path_b.o | sed 's/^/#   b: /' | grep -i "__text\|total" || true
  echo "# binaries: a $(stat -f %z build/server_a) B, b $(stat -f %z build/server_b) B"
} > "$out"
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  for s in park handoff; do echo "RUN round=$r scen=U $(build/server_a $s 1 16 0 0 $SECS)" >> "$out"; done
  for s in unfair spin; do echo "RUN round=$r scen=U $(build/server_b $s 1 16 0 0 $SECS)" >> "$out"; done
  for s in park handoff; do echo "RUN round=$r scen=C $(build/server_a $s 8 16 0 0 $SECS)" >> "$out"; done
  echo "RUN round=$r scen=C tuned=spin10us $(SPIN_US=10 build/server_a park 8 16 0 0 $SECS)" >> "$out"
  for s in unfair spin; do echo "RUN round=$r scen=C $(build/server_b $s 8 16 0 0 $SECS)" >> "$out"; done
  for s in park handoff; do echo "RUN round=$r scen=L $(build/server_a $s 8 16 100 1 $SECS)" >> "$out"; done
  for s in unfair spin; do echo "RUN round=$r scen=L $(build/server_b $s 8 16 100 1 $SECS)" >> "$out"; done
done
echo "$out"

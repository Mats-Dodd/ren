#!/bin/sh
# P2's knobs on C (8 workers x 16 connections, no hold): the take's spin
# budget (SPIN_US) and the worker's spin before sleeping (IDLE_SPIN_US).
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-2}
SECS=${SECS:-2}
mkdir -p results
out=results/probe-p2-$(date +%Y%m%d-%H%M%S).txt
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  for sp in 1 2 4 8; do for id in 0 5 20 50; do
    echo "RUN round=$r scen=C tuned=s${sp}i${id} $(SPIN_US=$sp IDLE_SPIN_US=$id build/server_a p2 8 16 0 0 $SECS)" >> "$out"
  done; done
done
echo "$out"

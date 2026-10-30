#!/bin/sh
# Interleaved X3b runs: ROUNDS rounds of every scenario and strategy, SECS each.
#   U:   1 worker, 16 connections, no hold                (uncontended)
#   C:   8 workers x 16 connections, no hold              (contended, short holds)
#   L:   C with a 100 us hold in put, plus one background task a worker
#   M:   C where 10% of requests touch the table and the rest do 2 us of local work
#   A4, A16: C where a request is an `at` block of 4 or 16 operations
#   W2, W4, W12: C at 2, 4 and 12 workers (where the home saturates)
# FAST=1 variants (ship, shipded, move): the rings are drained at every recv
# (a scheduling point), and a task resumed by a reply or a hop runs next.
# shipded uses the same thread count: worker 0 is the home, 7 others serve.
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-5}
SECS=${SECS:-2}
mkdir -p results
out=results/raw-$(date +%Y%m%d-%H%M%S).txt
{ echo "# machine: $(sysctl -n machdep.cpu.brand_string) $(sysctl -n hw.ncpu) cpus ($(sysctl -n hw.perflevel0.physicalcpu)P+$(sysctl -n hw.perflevel1.physicalcpu)E), macOS $(sw_vers -productVersion)"
  echo "# clang: $(clang --version | head -1)"
} > "$out"
A="park handoff p2 ship shipded move"
B="unfair spin"
F="ship shipded move" # FAST=1: drain rings at every recv; resumed tasks run next
run() { # scen env... -- strategy args
  sc=$1; shift
  tag=""; case "$*" in *IDLE_SPIN_US=0*) tag="tuned=idle0 ";; *FAST=1*) tag="tuned=fast ";; esac
  echo "RUN round=$r scen=$sc $tag$(env "$@")" >> "$out"
}
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  for s in park p2 ship move; do run U build/server_a $s 1 16 0 0 $SECS; done
  for s in $B; do run U build/server_b $s 1 16 0 0 $SECS; done
  for s in $A; do run C build/server_a $s 8 16 0 0 $SECS; done
  run C IDLE_SPIN_US=0 build/server_a ship 8 16 0 0 $SECS
  for s in $F; do run C FAST=1 build/server_a $s 8 16 0 0 $SECS; done
  for s in $B; do run C build/server_b $s 8 16 0 0 $SECS; done
  for s in $A; do run L build/server_a $s 8 16 100 1 $SECS; done
  run L FAST=1 build/server_a ship 8 16 100 1 $SECS
  for s in $B; do run L build/server_b $s 8 16 100 1 $SECS; done
  for s in $A; do run M SHARE_PCT=10 build/server_a $s 8 16 0 0 $SECS; done
  for s in $F; do run M SHARE_PCT=10 FAST=1 build/server_a $s 8 16 0 0 $SECS; done
  for s in $B; do run M SHARE_PCT=10 build/server_b $s 8 16 0 0 $SECS; done
  for n in 4 16; do
    for s in p2 ship shipded move; do run A$n OPS=$n build/server_a $s 8 16 0 0 $SECS; done
    for s in $F; do run A$n OPS=$n FAST=1 build/server_a $s 8 16 0 0 $SECS; done
    run A$n OPS=$n build/server_b unfair 8 16 0 0 $SECS
  done
  for w in 2 4 12; do
    for s in ship shipded; do run W$w build/server_a $s $w 16 0 0 $SECS; done
    run W$w build/server_b unfair $w 16 0 0 $SECS
  done
done
echo "$out"

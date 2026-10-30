#!/bin/sh
# Interleaved X3c runs: ROUNDS rounds of every scenario and variant, SECS each.
#   U:   1 worker, 16 connections, no hold                 (uncontended)
#   C:   8 workers x 16 connections, no hold               (contended, short holds)
#   L:   C with a 100 us hold in put, plus one background task a worker
#   M1, M10, M50: C where 1, 10 or 50% of requests touch the table and the
#        rest do 2 us of local work
# Variants (a): park; ship = H with FAST=1; hy = HY with FAST=1; hy+spin300 =
# HY that retries its CAS for up to 300 ns while an in-place taker holds the
# instance (TRY_SPIN_NS=300) before shipping. (b): unfair (os_unfair_lock).
# Shipping variants spin 5 us before a worker sleeps (the default).
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-7}
SECS=${SECS:-2}
mkdir -p results
out=results/raw-$(date +%Y%m%d-%H%M%S).txt
{ echo "# machine: $(sysctl -n machdep.cpu.brand_string) $(sysctl -n hw.ncpu) cpus ($(sysctl -n hw.perflevel0.physicalcpu)P+$(sysctl -n hw.perflevel1.physicalcpu)E), macOS $(sw_vers -productVersion)"
  echo "# clang: $(clang --version | head -1)"
} > "$out"
run() { # scen tag env... -- cmd
  sc=$1; tag=$2; shift 2
  t=""; [ -n "$tag" ] && t="tuned=$tag "
  echo "RUN round=$r scen=$sc $t$(env "$@" | head -1)" >> "$out"
}
set5() { # scen env... -- workers conns hold bg
  sc=$1; shift
  e=""; while [ "$1" != "--" ]; do e="$e $1"; shift; done; shift
  run $sc ""      $e build/server_a park "$@" $SECS
  run $sc fast    $e FAST=1 build/server_a ship "$@" $SECS
  run $sc fast    $e FAST=1 build/server_a hy "$@" $SECS
  run $sc spin300 $e FAST=1 TRY_SPIN_NS=300 build/server_a hy "$@" $SECS
  run $sc ""      $e build/server_b unfair "$@" $SECS
}
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  run U "" build/server_a park 1 16 0 0 $SECS
  run U fast FAST=1 build/server_a ship 1 16 0 0 $SECS
  run U fast FAST=1 build/server_a hy 1 16 0 0 $SECS
  run U "" build/server_b unfair 1 16 0 0 $SECS
  set5 C OPS=1 -- 8 16 0 0
  set5 L OPS=1 -- 8 16 100 1
  for p in 1 10 50; do set5 M$p SHARE_PCT=$p -- 8 16 0 0; done
done
echo "$out"

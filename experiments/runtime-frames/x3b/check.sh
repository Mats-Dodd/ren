#!/bin/sh
# Correctness. (1) DISJOINT=1: each connection owns its keys, so the response
# checksum and the final table depend only on each connection's own order
# (contract 1), not on interleaving. Every strategy, at 8 workers, must match
# unfair at 1 worker with the same connections (128; 112 for shipded), for
# plain requests, an `at` block of 4, and the mixed scenario.
# (2) ASan+UBSan and TSan builds, contended, with and without a hold, finish
# every request and leave the lock and every ring clean.
set -u
cd "$(dirname "$0")/build"
G='strategy=[a-z0-9]+|chk=[0-9a-f]+|table=[0-9a-f]+|check=[A-Za-z]+'
for cfg in "OPS=1" "OPS=4" "SHARE_PCT=10" "OPS=4 FAST=1" "SHARE_PCT=10 FAST=1"; do
  echo "== $cfg, DISJOINT=1 REQS=3000:"
  printf "ref 1x128 "; env $cfg DISJOINT=1 REQS=3000 ./server_b unfair 1 128 0 0 1 | grep -oE "$G" | tr '\n' ' '; echo
  for s in park handoff p2 ship move; do printf "8x16      "; env $cfg DISJOINT=1 REQS=3000 ./server_a $s 8 16 0 0 1 | grep -oE "$G" | tr '\n' ' '; echo; done
  printf "8x16      "; env $cfg DISJOINT=1 REQS=3000 ./server_b spin 8 16 0 0 1 | grep -oE "$G" | tr '\n' ' '; echo
  printf "ref 1x112 "; env $cfg DISJOINT=1 REQS=3000 ./server_b unfair 1 112 0 0 1 | grep -oE "$G" | tr '\n' ' '; echo
  for s in shipded moveded; do printf "8 (7x16)  "; env $cfg DISJOINT=1 REQS=3000 ./server_a $s 8 16 0 0 1 | grep -oE "$G" | tr "\n" " "; echo; done
done
S='parks=[0-9]+|handoffs=[0-9]+|reqs=[0-9]+|check=[a-zA-Z]+|WARNING: [A-Za-z]+.*|ERROR: .*|SUMMARY: .*'
for b in asan tsan; do
  for s in park handoff p2 ship shipded move moveded; do
    for args in "8 16 0 0" "8 8 20 1"; do
      for cfg in "OPS=1" "OPS=4 SHARE_PCT=50" "OPS=4 SHARE_PCT=50 FAST=1"; do
        printf "%s %s %s %s: " $b $s "$args" "$cfg"
        env $cfg REQS=500 ./server_a_$b $s $args 1 2>&1 | grep -oE "$S" | tr '\n' ' '; echo
      done
    done
  done
  for s in unfair spin; do
    printf "%s %s: " $b $s
    REQS=500 ./server_b_$b $s 8 16 0 0 1 2>&1 | grep -oE "$S" | tr '\n' ' '; echo
  done
done

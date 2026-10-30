#!/bin/sh
# Correctness: (1) at one worker every strategy gives the same response
# checksum for the same requests; (2) ASan+UBSan and TSan builds, contended,
# with and without a hold, finish every request with the lock left clean.
set -u
cd "$(dirname "$0")/build"
echo "same checksum at 1 worker, REQS=20000 x 16 connections:"
for s in park handoff; do REQS=20000 ./server_a $s 1 16 0 0 1 | grep -o "strategy=[a-z]*\|chk=[0-9a-f]*\|check=[a-zA-Z]*" | tr '\n' ' '; echo; done
for s in unfair spin; do REQS=20000 ./server_b $s 1 16 0 0 1 | grep -o "strategy=[a-z]*\|chk=[0-9a-f]*\|check=[a-zA-Z]*" | tr '\n' ' '; echo; done
for b in asan tsan; do
  for s in park handoff; do
    for args in "8 16 0 0" "8 8 20 1"; do
      printf "%s %s %s: " $b $s "$args"
      REQS=500 ./server_a_$b $s $args 1 2>&1 | grep -oE "parks=[0-9]+|handoffs=[0-9]+|reqs=[0-9]+|check=[a-zA-Z]+|WARNING: [A-Za-z]+.*|ERROR: .*" | tr '\n' ' '; echo
    done
  done
  for s in unfair spin; do
    printf "%s %s: " $b $s
    REQS=500 ./server_b_$b $s 8 16 0 0 1 2>&1 | grep -oE "reqs=[0-9]+|check=[a-zA-Z]+|WARNING: [A-Za-z]+.*|ERROR: .*" | tr '\n' ' '; echo
  done
done

#!/bin/sh
# X3c correctness.
# (1) DISJOINT=1: each connection owns its keys, so the response checksum and
#     the final table depend only on each task's own order (contract 1), not
#     on interleaving. Every strategy at 8 workers must match os_unfair_lock
#     at 1 worker with the same 128 connections, for plain requests, `at`
#     blocks of 4, and SHARE_PCT 1, 10 and 50, with and without FAST=1 and
#     POST=1 (a shipped put is posted: the task goes on without waiting).
#     Every run also checks a per-task sequence number at the instance
#     (reorders=0, else check=FAIL).
# (2) HY_BAD=1 drops HY's in-flight rule (a task with a post in flight may
#     still run in place): the sequence check must catch it.
# (3) ASan+UBSan and TSan builds, contended, with and without a hold, with
#     posts, finish every request and leave the lock word and every ring clean.
set -u
cd "$(dirname "$0")/build"
G='strategy=[a-z0-9]+|chk=[0-9a-f]+|table=[0-9a-f]+|check=[A-Za-z]+|reorders=[0-9]+|try_spin_ns=[0-9]+|sticky_us=[0-9]+'
for cfg in "OPS=1" "OPS=4" "SHARE_PCT=1" "SHARE_PCT=10" "SHARE_PCT=50"; do
  echo "== $cfg, DISJOINT=1 REQS=3000:"
  printf "ref 1x128              "; env $cfg DISJOINT=1 REQS=3000 ./server_b unfair 1 128 0 0 1 | grep -oE "$G" | tr '\n' ' '; echo
  for x in "" "FAST=1" "POST=1" "FAST=1 POST=1" "FAST=1 POST=1 TRY_SPIN_NS=300" "FAST=1 POST=1 TRY_SPIN_NS=300 STICKY_US=100"; do
    for s in park ship hy; do
      case "$s:$x" in park:*POST*|park:*TRY*|ship:*TRY*) continue;; esac
      printf "8x16 %-18s" "$x"; env $cfg $x DISJOINT=1 REQS=3000 ./server_a $s 8 16 0 0 1 | grep -oE "$G" | tr '\n' ' '; echo
    done
  done
  printf "8x16 unfair            "; env $cfg DISJOINT=1 REQS=3000 ./server_b unfair 8 16 0 0 1 | grep -oE "$G" | tr '\n' ' '; echo
  printf "8x16 HY_BAD=1 POST=1   "; env $cfg HY_BAD=1 POST=1 FAST=1 DISJOINT=1 REQS=3000 ./server_a hy 8 16 0 0 1 | grep -oE "$G" | tr '\n' ' '; echo "(HY_BAD: FAIL expected wherever a post was in flight at an in-place take)"
done
S='reqs=[0-9]+|check=[a-zA-Z]+|reorders=[0-9]+|WARNING: [A-Za-z]+.*|ERROR: .*|SUMMARY: .*'
for b in asan tsan; do
  for s in ship hy; do
    for args in "8 16 0 0" "8 8 20 1"; do
      for cfg in "OPS=1" "SHARE_PCT=10 FAST=1" "OPS=4 SHARE_PCT=50 FAST=1 POST=1" "SHARE_PCT=50 FAST=1 POST=1 TRY_SPIN_NS=300" "SHARE_PCT=10 FAST=1 POST=1 TRY_SPIN_NS=300 STICKY_US=100 HOLDSTAT=1"; do
        printf "%s %s %s %s: " $b $s "$args" "$cfg"
        env $cfg REQS=500 ./server_a_$b $s $args 1 2>&1 | grep -oE "$S" | tr '\n' ' '; echo
      done
    done
  done
  for s in park; do
    printf "%s %s: " $b $s; REQS=500 ./server_a_$b $s 8 16 0 0 1 2>&1 | grep -oE "$S" | tr '\n' ' '; echo
  done
  printf "%s unfair: " $b; REQS=500 ./server_b_$b unfair 8 16 0 0 1 2>&1 | grep -oE "$S" | tr '\n' ' '; echo
done

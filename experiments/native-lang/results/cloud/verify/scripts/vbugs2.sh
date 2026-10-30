#!/usr/bin/env bash
set -u
V=/tmp/claude-0/-home-user-ren/d65d9998-bee9-5cff-92bb-30baa48ec4a3/scratchpad/v
L=$V/vlogs; cd $V
S() { flock -s /tmp/ren-bench/lock "$@"; }
one() { local label=$1; shift; if S timeout 300 "$@" > $L/tmp2.out 2>&1; then echo "ONE $label rc=0 $(tail -1 $L/tmp2.out | cut -c1-160)"; else echo "ONE $label rc=$? $(grep -m2 -E 'oracle|FAIL|panic|ThreadSan|error|stale' $L/tmp2.out | tr '\n' ' ' | cut -c1-260)"; fi; }
for lang in c rust zig; do rel=release; [ $lang = zig ] && rel=release-fast
  for p in P0 P1 P3 P5; do sfx=""; [ $p = P0 ] || sfx=-$p
    one "$lang $p fuzz_run --random 300 1" bin/$lang-$rel$sfx/fuzz_run --random 300 1
  done
done

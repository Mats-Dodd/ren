#!/usr/bin/env bash
# Independent re-plant verification (machine "cloud"). Every step under flock -s.
set -u
V=/tmp/claude-0/-home-user-ren/d65d9998-bee9-5cff-92bb-30baa48ec4a3/scratchpad/v
L=$V/vlogs; mkdir -p $L
cd $V
S() { flock -s /tmp/ren-bench/lock "$@"; }
rate() {  # label n cmd...: run n times, count failures
  local label=$1 n=$2; shift 2; local f=0 first=""
  for i in $(seq 1 $n); do
    if ! S timeout 120 "$@" > $L/tmp.out 2>&1; then f=$((f+1)); [ -z "$first" ] && first=$(grep -m3 -E "FAIL|ThreadSanitizer|race|stale|duplicated|panic|error" $L/tmp.out | tr '\n' ' ' | cut -c1-300); fi
  done
  echo "RATE $label failed $f/$n first: $first"
}
build() { local lang=$1 prof=$2 plant=${3:-}; local tag=$lang-$prof${plant:+-$plant}
  if REN_FLOCKED= ./build.sh $lang $prof $plant > $L/build-$tag.log 2>&1; then echo "BUILD $tag ok"; else echo "BUILD $tag FAILED rc=$?: $(grep -m2 -E 'error' $L/build-$tag.log | tr '\n' ' ' | cut -c1-300)"; fi; }

step=${1:-all}
if [ $step = all ] || [ $step = build ]; then
  for p in "" P1 P3 P5; do
    build c release $p; build c tsan $p
    build rust release $p; build rust tsan $p
    build zig release-fast $p; build zig tsan $p
  done
  build c asan P3
  build c release P2
  REN_C_WERROR=0 build c ubsan-int P2
  build zig release-fast P2
  build zig debug P2
fi
if [ $step = all ] || [ $step = run ]; then
  for lang in c rust zig; do
    rel=release; [ $lang = zig ] && rel=release-fast
    for p in P0 P1; do
      sfx=""; [ $p = P0 ] || sfx=-$p
      rate "$lang $p deque_stress release" 20 bin/$lang-$rel$sfx/deque_stress stress 10 200000
      rate "$lang $p deque_stress tsan" 10 bin/$lang-tsan$sfx/deque_stress stress 10 200000
      rate "$lang $p w1x8 epoll release" 10 bin/$lang-$rel$sfx/harness w1 --driver epoll --workers 8 --n 200000
    done
    for p in P0 P3; do
      sfx=""; [ $p = P0 ] || sfx=-$p
      rate "$lang $p abi_test release" 3 bin/$lang-$rel$sfx/abi_test
      rate "$lang $p fuzz_run release" 3 bin/$lang-$rel$sfx/fuzz_run
      rate "$lang $p w3x4 uring release" 3 bin/$lang-$rel$sfx/harness w3 --driver uring --workers 4 --n 20000
      rate "$lang $p abi_test tsan" 3 bin/$lang-tsan$sfx/abi_test
    done
    for p in P0 P5; do
      sfx=""; [ $p = P0 ] || sfx=-$p
      rate "$lang $p w1x4 tsan epoll" 10 bin/$lang-tsan$sfx/harness w1 --driver epoll --workers 4 --n 200000
      rate "$lang $p w1x4 tsan uring" 5 bin/$lang-tsan$sfx/harness w1 --driver uring --workers 4 --n 200000
      rate "$lang $p w1x8 release epoll" 10 bin/$lang-$rel$sfx/harness w1 --driver epoll --workers 8 --n 200000
      rate "$lang $p deque_stress release" 5 bin/$lang-$rel$sfx/deque_stress stress 10 200000
    done
  done
  rate "c P3 abi_test asan" 2 bin/c-asan-P3/abi_test
  rate "c P2 deque empty ubsan-int" 1 bin/c-ubsan-int-P2/deque_stress empty
  rate "c P2 deque stress ubsan-int" 1 bin/c-ubsan-int-P2/deque_stress stress 10 200000
fi

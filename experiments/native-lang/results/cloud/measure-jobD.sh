#!/bin/bash
cd /home/user/ren/experiments/native-lang
S=/tmp/claude-0/-home-user-ren/d65d9998-bee9-5cff-92bb-30baa48ec4a3/scratchpad
until grep -q "jobC end" $S/jobC.log; do sleep 10; done
M="python3 -I harness/measure_b.py"
echo "jobD start $(date -u +%FT%TZ)"
for t in c-release rust-release zig-release-fast; do
  $M cmd $t-w4pinned "w4 replay w1 (c-release-epoll-w1.j) pinned" --runs 10 --keys wall_s -- taskset -c 1 bin/$t/harness w1 --workers 1 --n 1000000 --replay build/w4j/c-release-epoll-w1.j
  $M cmd $t-w4pinned "w4 replay w3 (c-release-epoll-w3.j) pinned" --runs 10 --keys wall_s -- taskset -c 1 bin/$t/harness w3 --workers 1 --n 200000 --replay build/w4j/c-release-epoll-w3.j
done
for lp in "c release" "rust release" "rust release-nostd" "zig release-fast"; do set -- $lp
  $M cmd buildtime "$1-$2 clean" --runs 7 --keys lang_build_s,harness_link_s -- $S/bt.sh $1 $2 clean
  $M cmd buildtime "$1-$2 incremental" --runs 7 --keys lang_build_s,harness_link_s -- $S/bt.sh $1 $2 incr
done
echo "jobD end $(date -u +%FT%TZ)"

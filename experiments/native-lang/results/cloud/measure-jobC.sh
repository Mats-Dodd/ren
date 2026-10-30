#!/bin/bash
# 1-worker configurations pinned to one CPU (taskset -c 1): the unpinned 1-worker runs were mostly NOISY
cd /home/user/ren/experiments/native-lang
S=/tmp/claude-0/-home-user-ren/d65d9998-bee9-5cff-92bb-30baa48ec4a3/scratchpad
until grep -q "jobB end" $S/jobB.log; do sleep 10; done
M="python3 -I harness/measure_b.py"
echo "jobC start $(date -u +%FT%TZ)"
for d in epoll uring; do for t in c-release rust-release zig-release-fast; do
  $M cmd $t-pinned "w1 $d x1 pinned" --runs 10 --keys tasks_per_s -- taskset -c 1 bin/$t/harness w1 --driver $d --workers 1 --n 1000000
  $M cmd $t-pinned "w1-n10M $d x1 pinned" --runs 10 --keys tasks_per_s -- taskset -c 1 bin/$t/harness w1 --driver $d --workers 1 --n 10000000
  $M cmd $t-pinned "w2 $d x1 pinned" --runs 10 --keys ns_per_switch -- taskset -c 1 bin/$t/harness w2 --driver $d --workers 1 --n 10000000
  $M cmd $t-pinned "w3 $d x1 pinned" --runs 10 --keys p50_ns,p99_ns -- taskset -c 1 bin/$t/harness w3 --driver $d --workers 1 --n 200000
done; done
echo "jobC end $(date -u +%FT%TZ)"

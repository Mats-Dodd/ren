#!/bin/bash
cd /home/user/ren/experiments/native-lang
S=/tmp/claude-0/-home-user-ren/d65d9998-bee9-5cff-92bb-30baa48ec4a3/scratchpad
until grep -q "jobA end" $S/jobA.log; do sleep 10; done
M="python3 -I harness/measure_b.py"
echo "jobB start $(date -u +%FT%TZ)"
# W4 replay throughput (1 worker, replay driver, no OS calls)
for t in c-release rust-release zig-release-fast; do
  $M w4 bin/$t $t-w4 build/w4j/c-release-epoll-w1.j w1 1000000 --runs 10
  $M w4 bin/$t $t-w4 build/w4j/c-release-epoll-w3.j w3 200000 --runs 10
  $M w4 bin/$t $t-w4 build/w4j/$t-epoll-w3.j w3 200000 --runs 10
done
# W1 at 1 worker, 10x the spec size (the 1M run is ~0.2 s and noisy)
for d in epoll uring; do for t in c-release rust-release zig-release-fast; do
  $M cmd $t-w1big "w1-n10M $d x1" --runs 10 --keys tasks_per_s -- bin/$t/harness w1 --driver $d --workers 1 --n 10000000
done; done
# W5 and E1
$M w5 bin/w5 w5 --runs 10
$M e1 bin/e1-c e1-c --runs 10
# W2 multi-worker (each run 18-32 s: 7 repetitions)
for w in 4 8; do for d in epoll uring; do for t in c-release rust-release zig-release-fast; do
  $M run bin/$t $t --workloads w2 --workers $w --drivers $d --runs 7
done; done; done
echo "jobB end $(date -u +%FT%TZ)"

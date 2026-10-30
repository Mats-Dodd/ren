#!/bin/bash
cd /home/user/ren/experiments/native-lang
M="python3 -I harness/measure_b.py run"
echo "jobA start $(date -u +%FT%TZ)"
for wl in w1 w3; do for w in 1 4 8; do for d in epoll uring; do for t in c-release rust-release zig-release-fast; do
  $M bin/$t $t --workloads $wl --workers $w --drivers $d --runs 10
done; done; done; done
for w in 1; do for d in epoll uring; do for t in c-release rust-release zig-release-fast; do
  $M bin/$t $t --workloads w2 --workers $w --drivers $d --runs 10
done; done; done
for wl in w1 w2 w3; do $M bin/rust-release-nostd rust-release-nostd --workloads $wl --workers 1 --drivers epoll --runs 10; done
echo "jobA end $(date -u +%FT%TZ)"

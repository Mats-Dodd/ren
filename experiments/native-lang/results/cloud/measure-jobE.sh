#!/bin/bash
# W5 and E1 pinned to one CPU (taskset -c 1): the unpinned runs were mostly NOISY
cd /home/user/ren/experiments/native-lang
S=/tmp/claude-0/-home-user-ren/d65d9998-bee9-5cff-92bb-30baa48ec4a3/scratchpad
until grep -q "jobD end" $S/jobD.log; do sleep 10; done
M="python3 -I harness/measure_b.py"
echo "jobE start $(date -u +%FT%TZ)"
for v in i-tcc i-clang ii-tcc ii-clang iii-tcc iii-clang iv-tcc iv-clang v-lto vi-lto; do
  for mn in "dup 400000000" "dupshared 400000000" "push 100000000"; do set -- $mn
    $M cmd w5pinned "w5-$v $1 pinned" --runs 10 --keys ns_per_op -- taskset -c 1 bin/w5/w5-$v $1 $2
  done
done
for wl in "w1 1000000 tasks_per_s" "w2 10000000 ns_per_switch" "w3 200000 p50_ns"; do set -- $wl
  for f in unity split; do
    $M cmd e1pinned "E1 $1 $f pinned" --runs 10 --keys $3 -- taskset -c 1 bin/e1-c/$1-$f $1 --workers 1 --n $2
  done
done
echo "jobE end $(date -u +%FT%TZ)"

#!/bin/bash
cd "$(dirname "$0")"
export SKIPBUILD=1 RESDIR=/home/user/ren/experiments/runtime-p2/switch/results/cloud/verify
r() { echo "== $*" >&2; env "$@" ./measure-cloud.sh; sleep 1; }
r ONLY='^pingpong_switch_go$'
r PIN=3 ONLY='^pingpong_switch_go$'
r ONLY='^pingpong_switch_rust$'
r PIN=3 ONLY='^pingpong_switch_rust$'
r PIN=3 ONLY='^pingpong_local_switch_rust$'
r ONLY='^spawn_join_switch_go$'
r PIN=3 ONLY='^spawn_join_switch_go$'
r ONLY='^spawn_batch_m64_switch_rust$'
r PIN=3 ONLY='^fanout_yield_ren_c$'
r PIN=3 ONLY='^fanout_yield_raw_c$'
r PIN=3 ONLY='^park_raw_c$'
r PIN=3 ONLY='^park_switch_go$'
r ONLY='^park_ren_c$'
r ONLY='^pingpong_ren_c$'
r ONLY='^(spawn_join_ren_c|spawn_batch_m64_ren_c)$'
r ONLY='^pingpong_raw_c$'
echo ALLDONE >&2

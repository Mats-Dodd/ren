#!/bin/bash
# link the shared harness with tcc 0.9.27 against another language's libren_core.a
cd /home/user/ren/experiments/native-lang/harness
ROOT=/home/user/ren/experiments/native-lang
for tag in "$@"; do
  out=$ROOT/build/$tag; bin=$ROOT/bin/tcclink-$tag; mkdir -p $bin
  libs="$out/libren_core.a $(cat $out/link.flags) ${EXTRA:-} -lpthread -lm"
  fl="-g -D_GNU_SOURCE -I."
  echo "== tcc link against $tag ($libs)"
  t0=$(date +%s.%N)
  tcc $fl host_main.c rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c workloads/w3_rtt.c workloads/t_io.c workloads/w_fuzz.c $libs -o $bin/harness 2>&1 | head -20; echo "harness rc=${PIPESTATUS[0]}"
  tcc $fl tests/abi_test.c rt.c $libs -o $bin/abi_test 2>&1 | head -5
  tcc $fl tests/deque_stress.c rt.c $libs -o $bin/deque_stress 2>&1 | head -5
  tcc $fl tests/layout_check.c rt.c $libs -o $bin/layout_check 2>&1 | head -5
  tcc $fl fuzz/fuzz_run.c fuzz/fuzz_common.c rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c workloads/w3_rtt.c workloads/t_io.c workloads/w_fuzz.c $libs -o $bin/fuzz_run 2>&1 | head -5
  tcc $fl tests/jdump.c -o $bin/jdump
  echo "link time $(echo "$(date +%s.%N) - $t0" | bc)"
  ls $bin
done

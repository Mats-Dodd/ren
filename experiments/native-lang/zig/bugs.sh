#!/usr/bin/env bash
# zig/bugs.sh <P0|P1..P5|P2u> [stage ...]: SPEC §F planted-bug runs for the Zig
# entry, machine "cloud". P0 = the clean build (baseline for every tool).
# P2u = the zig-only runnable P2 variant (Ring.cap u64 too; see bugs-zig.md).
# Logs: results/cloud/bugs-zig/<P>/<stage>.log; one line per stage appended to
# results/cloud/bugs-zig/summary.tsv: plant stage exit seconds.
# stages: build tests direct rate fuzz asan (default: all).
# Each stage command runs under flock -s (taken per command, not per run).
set -uo pipefail
mkdir -p /tmp/ren-bench; export REN_FLOCKED=1
P=${1:?plant}; shift
STAGES=("$@"); [ ${#STAGES[@]} -gt 0 ] || STAGES=(build tests direct rate fuzz asan)
ROOT=$(cd "$(dirname "$0")/.." && pwd); Z=$ROOT/zig; H=$ROOT/harness
L=$ROOT/results/cloud/bugs-zig/$P; mkdir -p "$L"
SUM=$ROOT/results/cloud/bugs-zig/summary.tsv
FUZZ_S=${FUZZ_S:-120}
PROFILES=${PROFILES:-"release-fast release-safe debug tsan"}
plant=""; [ "$P" = P0 ] || plant=$P
tag() { echo "zig-$1${plant:+-$plant}"; }
stamp() { date +%s.%N; }
rec() { printf '%s\t%s\t%s\t%.1f\n' "$P" "$1" "$2" "$3" >> "$SUM"; }
timed() {  # name logfile cmd...: run under the shared lock, log, record exit + seconds
  local name=$1 log=$2; shift 2
  local t0; t0=$(stamp)
  { echo "# machine cloud, $(date -u +%FT%TZ), plant $P, stage $name"; echo "# \$ $*"; } > "$log"
  flock -s /tmp/ren-bench/lock "$@" >> "$log" 2>&1; local rc=$?
  local t1; t1=$(stamp)
  echo "# exit $rc after $(echo "$t1 - $t0" | bc) s" >> "$log"
  rec "$name" "$rc" "$(echo "$t1 - $t0" | bc)"
  return $rc
}

st_build() {
  for prof in $PROFILES; do
    timed "build-$prof" "$L/build-$prof.log" "$ROOT/build.sh" zig "$prof" $plant
  done
}

st_tests() {   # the whole shared suite at 1/4/8 workers, both drivers, per profile
  for prof in $PROFILES; do
    local b=$ROOT/bin/$(tag "$prof")
    [ -x "$b/harness" ] || { echo "no $b" > "$L/tests-$prof.log"; rec "tests-$prof" missing 0; continue; }
    timed "tests-$prof" "$L/tests-$prof.log" env WORKERS="1 4 8" DRIVERS="epoll uring" TMO=${TMO:-30} "$H/test.sh" "$b"
  done
}

st_direct() {   # the SPEC §F named exposures, one command each, per profile
  for prof in $PROFILES; do
    local b=$ROOT/bin/$(tag "$prof")
    [ -x "$b/harness" ] || continue
    timed "abi-$prof" "$L/abi-$prof.log" timeout 60 "$b/abi_test"
    timed "deque-empty-$prof" "$L/deque-empty-$prof.log" timeout 20 "$b/deque_stress" empty
    timed "deque-stress-$prof" "$L/deque-stress-$prof.log" timeout 120 "$b/deque_stress" stress 10 200000
    timed "t_cancel-x4-$prof" "$L/t_cancel-x4-$prof.log" timeout 60 "$b/harness" t_cancel --driver epoll --workers 4
    timed "w1x4-$prof" "$L/w1x4-$prof.log" bash -c "for d in epoll uring; do timeout 120 '$b/harness' w1 --driver \$d --workers 4 --n 200000 || exit \$?; done"
  done
}

st_rate() {   # repeated runs of the intermittent detectors (P1 deque oracle, P5 TSan)
  local N=${RATE_N:-20}
  for prof in ${RATE_PROFILES:-release-fast release-safe tsan}; do
    local b=$ROOT/bin/$(tag "$prof")
    [ -x "$b/harness" ] || continue
    timed "rate-deque-$prof" "$L/rate-deque-$prof.log" bash -c "f=0; for i in \$(seq $N); do timeout 120 '$b/deque_stress' stress 10 200000 > /tmp/ren-zig-bugs-$P-\$\$.out 2>&1 || { f=\$((f+1)); tail -3 /tmp/ren-zig-bugs-$P-\$\$.out; }; done; rm -f /tmp/ren-zig-bugs-$P-\$\$.out; echo \"failed \$f/$N\"; [ \$f = 0 ]"
  done
  local t=$ROOT/bin/$(tag tsan)
  [ -x "$t/harness" ] && timed "rate-tsan-w1x4" "$L/rate-tsan-w1x4.log" bash -c "f=0; for i in \$(seq 10); do for d in epoll uring; do timeout 120 '$t/harness' w1 --driver \$d --workers 4 --n 200000 > /tmp/ren-zig-bugs-$P-\$\$.out 2>&1 || { f=\$((f+1)); grep -m3 -A6 'WARNING: ThreadSanitizer' /tmp/ren-zig-bugs-$P-\$\$.out | head -12; }; done; done; rm -f /tmp/ren-zig-bugs-$P-\$\$.out; echo \"failed \$f/20\"; [ \$f = 0 ]"
}

fuzz_bin() {   # the hand-linked libFuzzer target: clang 18 fuzzer+ASan+UBSan harness, Zig release-safe core
  local core=$ROOT/build/$(tag release-safe)/libren_core.a out=$ROOT/bin/$(tag release-safe)/fuzz
  [ -e "$core" ] || return 1
  (cd "$H" && clang -O1 -g -fsanitize=fuzzer,address,undefined -D_GNU_SOURCE -I"$H" fuzz/fuzz_target.c fuzz/fuzz_common.c \
     rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c workloads/w3_rtt.c workloads/t_io.c workloads/w_fuzz.c \
     "$core" -lpthread -lm -o "$out")
}

st_fuzz() {   # through the replay driver's fuzz mode (SPEC §D.4), time-boxed
  local s=$ROOT/bin/$(tag release-safe) r=$ROOT/bin/$(tag release-fast) d=$ROOT/bin/$(tag debug)
  local wd=$ROOT/build/bugs-zig-fuzz/$P; rm -rf "$wd"; mkdir -p "$wd/corpus"
  timed fuzz-run-release-fast "$L/fuzz-run-release-fast.log" timeout 300 "$r/fuzz_run" --random 20000 7
  timed fuzz-run-release-safe "$L/fuzz-run-release-safe.log" timeout 300 "$s/fuzz_run" --random 20000 7
  timed fuzz-run-debug "$L/fuzz-run-debug.log" timeout 300 "$d/fuzz_run" --random 5000 7
  timed fuzz-link "$L/fuzz-link.log" bash -c "$(declare -f fuzz_bin); ROOT='$ROOT' H='$H' P='$P' plant='$plant'; tag() { echo \"zig-\$1\${plant:+-\$plant}\"; }; fuzz_bin"
  if [ -x "$s/fuzz" ]; then
    timed libfuzzer-release-safe "$L/libfuzzer-release-safe.log" bash -c "cd '$wd' && '$s/fuzz' -max_total_time=$FUZZ_S -timeout=10 -seed=1 -max_len=4096 -print_final_stats=1 corpus"
    ls "$wd" >> "$L/libfuzzer-release-safe.log"
  fi
}

st_asan() {   # extra: an ASan+UBSan harness linked against the uninstrumented release-fast Zig core.
  # The core allocates with std.heap.c_allocator there, i.e. libc malloc/free, which ASan intercepts.
  local core=$ROOT/build/$(tag release-fast)/libren_core.a b=$ROOT/bin/$(tag asanh)
  mkdir -p "$b"
  timed asanh-link "$L/asanh-link.log" bash -c "cd '$H' && clang -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -std=gnu11 -D_GNU_SOURCE -I'$H' host_main.c rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c workloads/w3_rtt.c workloads/t_io.c workloads/w_fuzz.c '$core' -lpthread -lm -o '$b/harness' && clang -O1 -g -fsanitize=address,undefined -D_GNU_SOURCE -I'$H' tests/abi_test.c rt.c '$core' -lpthread -lm -o '$b/abi_test' && clang -O1 -g -fsanitize=address,undefined -D_GNU_SOURCE -I'$H' tests/deque_stress.c rt.c '$core' -lpthread -lm -o '$b/deque_stress'"
  timed asanh-abi "$L/asanh-abi.log" timeout 60 "$b/abi_test"
  timed asanh-t_cancel "$L/asanh-t_cancel.log" timeout 60 "$b/harness" t_cancel --driver epoll --workers 4
  timed asanh-w1x4 "$L/asanh-w1x4.log" timeout 120 "$b/harness" w1 --driver epoll --workers 4 --n 200000
}

for s in "${STAGES[@]}"; do "st_$s"; done
echo "done $P: ${STAGES[*]}"

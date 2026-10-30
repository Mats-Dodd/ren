#!/usr/bin/env bash
# c/bugs.sh <P0|P1..P5> [stage ...]: SPEC §F planted-bug runs for the C entry,
# machine "cloud". P0 = the clean build (baseline for every tool).
# Logs: results/cloud/bugs-c/<P>/<stage>.log, one line per stage appended to
# results/cloud/bugs-c/summary.tsv: plant stage exit seconds.
# stages: warn build tests valgrind fuzz (default: all). Each stage command runs under flock -s.
set -uo pipefail
# The shared lock is taken per stage command (timed() below), not for the
# whole run, so other agents' exclusive timed runs can interleave.
mkdir -p /tmp/ren-bench; export REN_FLOCKED=1
P=${1:?plant}; shift
STAGES=("$@"); [ ${#STAGES[@]} -gt 0 ] || STAGES=(warn build tests valgrind fuzz)
ROOT=$(cd "$(dirname "$0")/.." && pwd); C=$ROOT/c; H=$ROOT/harness
L=$ROOT/results/cloud/bugs-c/$P; mkdir -p "$L"
SUM=$ROOT/results/cloud/bugs-c/summary.tsv
FUZZ_S=${FUZZ_S:-300}
plant=""; [ "$P" = P0 ] || plant=$P
tag() { echo "c-$1${plant:+-$plant}"; }
stamp() { date +%s.%N; }
rec() { printf '%s\t%s\t%s\t%.1f\n' "$P" "$1" "$2" "$3" >> "$SUM"; }
timed() {  # name logfile cmd...: run, log, record exit + seconds
  local name=$1 log=$2; shift 2
  local t0; t0=$(stamp)
  { echo "# machine cloud, $(date -u +%FT%TZ), plant $P, stage $name"; echo "# \$ $*"; } > "$log"
  flock -s /tmp/ren-bench/lock "$@" >> "$log" 2>&1; local rc=$?
  local t1; t1=$(stamp)
  echo "# exit $rc after $(echo "$t1 - $t0" | bc) s" >> "$log"
  rec "$name" "$rc" "$(echo "$t1 - $t0" | bc)"
  return $rc
}

st_warn() {   # clang -Wall -Wextra -Wconversion on every core file, no -Werror
  local d=${plant:+-DREN_PLANT=${plant#P}}
  local log=$L/warn-clang.log
  timed warn-clang "$log" bash -c "cd '$C' && for f in dq.c journal.c sched.c core.c layout.c drv_common.c drv_epoll.c drv_replay.c drv_uring.c; do clang -std=c11 -O2 -Wall -Wextra -Wconversion -Wno-unused-parameter $d -D_GNU_SOURCE -I'$H' -I'$C' -fsyntax-only \$f; done"
  grep -c 'warning:' "$log" | sed 's/^/warnings: /' >> "$log"
  local log2=$L/warn-gcc.log
  timed warn-gcc "$log2" bash -c "cd '$C' && for f in dq.c journal.c sched.c core.c layout.c drv_common.c drv_epoll.c drv_replay.c drv_uring.c; do gcc -std=c11 -O2 -Wall -Wextra -Wconversion -Wno-unused-parameter $d -D_GNU_SOURCE -I'$H' -I'$C' -fsyntax-only \$f; done"
  grep -c 'warning:' "$log2" | sed 's/^/warnings: /' >> "$log2"
}

st_build() {
  for prof in release debug asan ubsan-int tsan; do
    if ! timed "build-$prof" "$L/build-$prof.log" "$ROOT/build.sh" c "$prof" $plant; then
      echo "# -Werror build failed; retrying with REN_C_WERROR=0" >> "$L/build-$prof.log"
      timed "build-$prof-nowerror" "$L/build-$prof-nowerror.log" env REN_C_WERROR=0 "$ROOT/build.sh" c "$prof" $plant
    fi
  done
}

st_tests() {  # W1-W4 + abi + deque + io + fuzz suites at 1/4/8 workers, both drivers, per profile
  for prof in ${TEST_PROFILES:-release debug asan ubsan-int tsan}; do
    local b=$ROOT/bin/$(tag "$prof")
    [ -x "$b/harness" ] || { echo "no $b" > "$L/tests-$prof.log"; rec "tests-$prof" missing 0; continue; }
    timed "tests-$prof" "$L/tests-$prof.log" env WORKERS="1 4 8" DRIVERS="epoll uring" TMO=${TMO:-60} "$H/test.sh" "$b"
  done
  # TSan on W1 at 4 workers, the SPEC's named exposure for P5 (and P1), repeated
  local b=$ROOT/bin/$(tag tsan)
  timed "tsan-w1x4" "$L/tsan-w1x4.log" bash -c "for i in 1 2 3 4 5; do for d in epoll uring; do timeout 120 '$b/harness' w1 --driver \$d --workers 4 --n 200000 || exit \$?; done; done"
  timed "tsan-deque" "$L/tsan-deque.log" bash -c "timeout 300 '$b/deque_stress' stress 10 200000"
  # deque_stress on release, many repetitions (P1 on real hardware)
  local r=$ROOT/bin/$(tag release)
  timed "deque-stress-x50" "$L/deque-stress-x50.log" bash -c "for i in \$(seq 50); do timeout 60 '$r/deque_stress' stress 10 200000 || { echo \"iteration \$i failed\"; exit 1; }; done; echo 50 ok"
}

st_valgrind() {   # epoll only: under valgrind 3.22 the uring driver hangs even on the clean build (P0 log)
  local b=$ROOT/bin/$(tag debug)
  local V="timeout 300 valgrind -q --error-exitcode=99"
  timed vg-memcheck "$L/vg-memcheck.log" bash -c "
    set -e
    $V '$b/abi_test'
    $V '$b/deque_stress' empty
    $V '$b/deque_stress' lifo
    $V '$b/deque_stress' stress 4 20000
    $V '$b/harness' w1 --driver epoll --workers 4 --n 20000
    $V '$b/harness' t_cancel --driver epoll --workers 4
    $V '$b/harness' t_cancel --driver epoll --workers 1
    $V '$b/harness' w3 --driver epoll --workers 1 --n 2000
    $V '$b/fuzz_run' --random 100 1"
  timed vg-helgrind "$L/vg-helgrind.log" bash -c "
    $V --tool=helgrind '$b/deque_stress' stress 4 20000; a=\$?
    $V --tool=helgrind '$b/harness' w1 --driver epoll --workers 4 --n 20000; b=\$?
    echo \"deque=\$a w1=\$b\"; [ \$a = 0 ] && [ \$b = 0 ]"
  timed vg-drd "$L/vg-drd.log" bash -c "
    $V --tool=drd '$b/deque_stress' stress 4 20000; a=\$?
    $V --tool=drd '$b/harness' w1 --driver epoll --workers 4 --n 20000; b=\$?
    echo \"deque=\$a w1=\$b\"; [ \$a = 0 ] && [ \$b = 0 ]"
}

st_fuzz() {   # through the replay driver's fuzz mode (SPEC §D.4)
  local a=$ROOT/bin/$(tag asan) u=$ROOT/bin/$(tag ubsan-int) r=$ROOT/bin/$(tag release)
  local wd=$ROOT/build/bugs-c-fuzz/$P; rm -rf "$wd"; mkdir -p "$wd/corpus"
  timed fuzz-run-release "$L/fuzz-run-release.log" timeout 600 "$r/fuzz_run" --random 20000 7
  timed fuzz-run-ubsan "$L/fuzz-run-ubsan.log" timeout 600 "$u/fuzz_run" --random 5000 7
  if [ -x "$a/fuzz" ]; then
    timed libfuzzer-asan "$L/libfuzzer-asan.log" bash -c "cd '$wd' && '$a/fuzz' -max_total_time=$FUZZ_S -timeout=10 -seed=1 -max_len=4096 -print_final_stats=1 corpus"
    ls "$wd" >> "$L/libfuzzer-asan.log"
  fi
}

for s in "${STAGES[@]}"; do "st_$s"; done
echo "done $P: ${STAGES[*]}"

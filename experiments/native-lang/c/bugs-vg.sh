#!/usr/bin/env bash
# c/bugs-vg.sh <P0|P1..P5>: valgrind (memcheck, helgrind, drd) over the debug
# build of one plant, epoll only (under valgrind 3.22 the uring driver hangs
# even on the clean build). Every command runs to the end; a valgrind error
# is exit 99 (--error-exitcode=99), anything else is the program's own exit.
# Log: results/cloud/bugs-c/<P>/valgrind.log (machine "cloud"). Runs under flock -s.
set -uo pipefail
if [ -z "${REN_FLOCKED:-}" ]; then
  mkdir -p /tmp/ren-bench; export REN_FLOCKED=1
  exec flock -s /tmp/ren-bench/lock "$0" "$@"
fi
P=${1:?plant}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tag=c-debug; [ "$P" = P0 ] || tag=$tag-$P
B=$ROOT/bin/$tag
L=$ROOT/results/cloud/bugs-c/$P/valgrind.log
TMO=${TMO:-120}
echo "# machine cloud, $(date -u +%FT%TZ), plant $P, $tag, valgrind $(valgrind --version)" > "$L"
CMDS=(
  "abi_test"
  "deque_stress empty"
  "deque_stress lifo"
  "deque_stress stress 4 20000"
  "harness w1 --driver epoll --workers 4 --n 20000"
  "harness w2 --driver epoll --workers 4 --n 20000"
  "harness w3 --driver epoll --workers 1 --n 2000"
  "harness t_cancel --driver epoll --workers 1"
  "harness t_cancel --driver epoll --workers 4"
  "fuzz_run --random 100 1"
)
for tool in memcheck helgrind drd; do
  [ "$tool" = memcheck ] || CMDS=("deque_stress stress 4 20000" "harness w1 --driver epoll --workers 4 --n 20000")
  for c in "${CMDS[@]}"; do
    t0=$(date +%s.%N)
    timeout "$TMO" valgrind --tool=$tool --error-exitcode=99 $B/$c > "$L.tmp" 2>&1; rc=$?
    t1=$(date +%s.%N)
    nerr=$(grep -oE 'ERROR SUMMARY: [0-9]+ errors' "$L.tmp" | grep -oE '[0-9]+' | head -1)
    kinds=$(grep -oE '==[0-9]+== (Invalid [a-z]+ of size [0-9]+|Invalid free\(\) / delete / delete\[\] / realloc\(\)|Conditional jump[^=]*|Possible data race during [a-z]+|Conflicting [a-z]+ by thread|Use of uninitialised[^=]*)' "$L.tmp" \
            | sed 's/==[0-9]*== //' | sort | uniq -c | tr '\n' ';')
    fns=$(grep -A3 -E 'Possible data race|Conflicting (load|store)' "$L.tmp" | grep -oE '(at|by) 0x[0-9A-F]+: [a-z_]+' | awk '{print $3}' | sort -u | tr '\n' ',')
    printf '%s | %s | exit %s | %.1fs | valgrind_errors %s | %s | race_fns %s\n' "$tool" "$c" "$rc" "$(echo "$t1 - $t0" | bc)" "${nerr:-?}" "$kinds" "$fns" >> "$L"
    if [ "$rc" = 99 ] || [ "$rc" = 124 ] || [ "$rc" -ge 128 ]; then
      echo "---- first 60 lines of valgrind output for: $tool $c" >> "$L"; grep -E '^==' "$L.tmp" | head -60 >> "$L"
    else
      grep -vE '^==' "$L.tmp" | grep -E 'FAIL|fail|oracle|result:' | head -5 | sed 's/^/    program: /' >> "$L"
    fi
  done
done
rm -f "$L.tmp"
echo "done $P" >> "$L"

#!/bin/sh
# P1, the cost of a hop.
#   ./run.sh --quick   smoke run: cross-language check, C under TSan, both
#                      languages at 3 short reps (numbers not meaningful)
#   ./run.sh [--reps N] full run, C then Rust, serially. One line per
#                      configuration on stdout:
#   P1 lang= variant= work_ns= iters= workers=1 reps= median_ns= overhead_ns= p50_ns= p99_ns= qos=
#   median_ns is the median over reps of a batch's mean ns per op;
#   overhead_ns is that minus `call` at the same work; p50/p99 are of
#   individually timed ops (timer granularity 41.67 ns on Apple silicon).
# Run the full mode alone on a quiet machine: other load moves the parked
# rows by microseconds.
set -eu
cd "$(dirname "$0")"
[ -x build/p1_c ] && [ -x build/p1_rust ] || ./build.sh >&2
if [ "${1:-}" = "--quick" ]; then
  c=$(./build/p1_c --check); r=$(./build/p1_rust --check)
  echo "$c"; echo "$r"
  [ "${c#* state=}" = "$(echo "${r#* state=}")" ] || { echo "C and Rust disagree" >&2; exit 1; }
  ./build/p1_c_tsan --check >/dev/null 2>build/tsan.log
  ./build/p1_c_tsan --quick >/dev/null 2>>build/tsan.log
  if grep -q "ThreadSanitizer" build/tsan.log; then echo "TSAN: races, see build/tsan.log" >&2; exit 1; fi
  echo "TSAN ok"
  ./build/p1_c --quick
  ./build/p1_rust --quick
  exit 0
fi
./build/p1_c "$@"
./build/p1_rust "$@"

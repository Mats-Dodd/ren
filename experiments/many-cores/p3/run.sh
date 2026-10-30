#!/bin/sh
# P3: handing off against barging.
#   ./run.sh --quick   correctness smoke: fixed-op runs (counters and state
#                      checked), the starvation guard forced on, a short timed
#                      run, and the C under ThreadSanitizer. Seconds, not timing.
#   ./run.sh           full: one line per configuration, medians over REPS.
#                      impl x mode x workers x cs_ns; ~4 minutes. Run on an idle
#                      machine, serially with other experiments.
# Env overrides for full mode: REPS (5), MS (1000 per rep), WORKERS, CS, OUT.
set -e
cd "$(dirname "$0")"
if [ "$1" = "--quick" ]; then
  ./build.sh --tsan
  fail=0
  for impl in c rust; do
    for mode in fifo barge; do
      for w in 4 12; do
        bin/p3$impl --mode $mode --workers $w --ops 2000 --reps 2 || fail=1
      done
      # guard at 50 us so barge actually takes the handoff path
      bin/p3$impl --mode $mode --workers 8 --ops 300 --guard-us 50 --reps 1 || fail=1
      bin/p3$impl --mode $mode --workers 12 --ms 100 --reps 1 || fail=1
    done
  done
  for mode in fifo barge; do
    bin/p3c_tsan --mode $mode --workers 8 --ops 300 --guard-us 50 --reps 1 || fail=1
    bin/p3c_tsan --mode $mode --workers 4 --ms 100 --reps 1 || fail=1
  done
  [ $fail = 0 ] && echo "# quick: all checks ok" || { echo "# quick: FAILED"; exit 1; }
  exit 0
fi
./build.sh
REPS=${REPS:-5}; MS=${MS:-1000}
WORKERS=${WORKERS:-"4 8 12 16"}; CS=${CS:-"100 500 2000"}; OUT=${OUT:-1000}
for impl in c rust; do
  for cs in $CS; do
    for w in $WORKERS; do
      for mode in fifo barge; do
        bin/p3$impl --mode $mode --workers $w --cs-ns $cs --out-ns $OUT --ms $MS --reps $REPS
      done
    done
  done
done

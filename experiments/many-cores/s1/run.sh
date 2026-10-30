#!/bin/sh
# S1/S2: stripes against atomics.
#   ./run.sh --quick   smoke run: every variant at 1, 4, 16 workers, short, plus the C
#                      under ThreadSanitizer once. Checks only; numbers mean nothing.
#   ./run.sh           full run: one line per configuration (see README "Output").
# Full-run knobs (env): REPS (7), MS (300), WORKERS ("1 2 4 8 12 16"), LANGS ("c rust"),
#   READER ("0 1"), WORK (0). Lines also go to results/s1-<timestamp>.txt.
# Run it alone on the machine: it uses up to 17 threads.
set -eu
cd "$(dirname "$0")"
[ -x bin/s1_c ] && [ -x bin/s1_rust ] && [ -x bin/s1_c_tsan ] || ./build.sh >&2

CONFIGS="one_lock:0 one_unfair:0 atomic:0 stripe_lock:0 stripe_lock:64 stripe_lock:128 stripe_owner:0 stripe_owner:64 stripe_owner:128"
fail=0

out=/dev/null
one() { # bin variant pad workers reader ms reps work
  line=$("$1" --variant "$2" --pad "$3" --workers "$4" --reader "$5" --ms "$6" --reps "$7" --work "$8") || fail=1
  echo "$line"; echo "$line" >> "$out"
}

if [ "${1:-}" = "--quick" ]; then
  for lang in c rust; do
    for cfg in $CONFIGS; do
      v=${cfg%%:*}; p=${cfg##*:}
      for w in 1 4 16; do
        for r in 0 1; do one "bin/s1_$lang" "$v" "$p" "$w" "$r" 20 1 0; done
      done
    done
  done
  echo "--- ThreadSanitizer (C) ---"
  for cfg in $CONFIGS; do
    v=${cfg%%:*}; p=${cfg##*:}
    TSAN_OPTIONS="halt_on_error=1 exitcode=66" one bin/s1_c_tsan "$v" "$p" 4 1 20 1 0
  done
  [ $fail = 0 ] && echo "QUICK OK" || { echo "QUICK FAILED"; exit 1; }
  exit 0
fi

REPS=${REPS:-7}; MS=${MS:-300}; WORKERS=${WORKERS:-"1 2 4 8 12 16"}
LANGS=${LANGS:-"c rust"}; READER=${READER:-"0 1"}; WORK=${WORK:-0}
mkdir -p results
out="results/s1-$(date +%Y%m%d-%H%M%S).txt"
echo "# s1 full run $(date) $(sysctl -n machdep.cpu.brand_string) reps=$REPS ms=$MS" | tee "$out"
  for lang in $LANGS; do
    for r in $READER; do
      for cfg in $CONFIGS; do
        v=${cfg%%:*}; p=${cfg##*:}
        for w in $WORKERS; do one "bin/s1_$lang" "$v" "$p" "$w" "$r" "$MS" "$REPS" "$WORK"; done
      done
    done
  done
echo "# written to $out" >&2
exit $fail

#!/bin/sh
# K3, marking. Prints one line per configuration, key=value, to stdout.
#   ./run.sh --quick   smoke: correctness, digests agree across variants and
#                      languages, the C under ThreadSanitizer; seconds.
#   ./run.sh           full: both variants, C and Rust, 1 2 4 8 12 16 workers,
#                      REPS repetitions of MS milliseconds each (median, min,
#                      max ops/s; median of each rep's sampled p50 and p99).
# Env: REPS (default 7), MS (default 1000), LOCKS_C (default "unfair spin"),
#      LOCKS_RUST (default "mutex spin"), WORKERS (default "1 2 4 8 12 16").
# Run on a quiet machine, one job at a time.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
[ -x "$here/bin/k3-c" ] && [ -x "$here/bin/k3-rust" ] || "$here/build.sh" >&2

if [ "${1:-}" = "--quick" ]; then
  fail=0
  for w in 1 4 8; do
    d=""
    for impl in c rust; do
      for v in edge shared; do
        line=$("$here/bin/k3-$impl" --variant $v --workers $w --ops 20000 --reps 2) || fail=1
        echo "$line"
        dg=$(echo "$line" | sed 's/.*digest=\([0-9a-f]*\).*/\1/')
        if [ -z "$d" ]; then d=$dg; elif [ "$d" != "$dg" ]; then echo "DIGEST MISMATCH workers=$w" >&2; fail=1; fi
      done
    done
    for l in spin; do
      "$here/bin/k3-c" --variant shared --lock $l --workers $w --ops 5000 --reps 1 || fail=1
    done
  done
  echo "# tsan (C, 8 workers, both variants, both locks)" >&2
  for v in edge shared; do
    for l in unfair spin; do
      TSAN_OPTIONS="halt_on_error=1" "$here/bin/k3-c-tsan" --variant $v --lock $l --workers 8 --ops 3000 --reps 1 || fail=1
    done
  done
  [ $fail = 0 ] && echo "# quick: ok" >&2 || { echo "# quick: FAILED" >&2; exit 1; }
  exit 0
fi

REPS=${REPS:-7}; MS=${MS:-1000}
WORKERS=${WORKERS:-"1 2 4 8 12 16"}
for w in $WORKERS; do
  for v in edge shared; do
    for l in ${LOCKS_C:-unfair spin}; do
      "$here/bin/k3-c" --variant $v --lock $l --workers $w --ms $MS --reps $REPS
    done
    for l in ${LOCKS_RUST:-mutex spin}; do
      "$here/bin/k3-rust" --variant $v --lock $l --workers $w --ms $MS --reps $REPS
    done
  done
done

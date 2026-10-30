#!/usr/bin/env bash
# The same cache three ways.
#   ./run.sh --quick   smoke + correctness: every variant, C and Rust, at 1 and 4
#                      workers with few ops; checks ok=1 and that the checksum of
#                      values read agrees across all variants; runs the C under
#                      ThreadSanitizer once. Seconds, not a measurement.
#   ./run.sh           full: one line per (impl, variant, workers), each over
#                      REPS repetitions (default 5), workers 1 2 4 8 12 16.
# Env: REPS, OPS (per worker, default 200000), WORKERS (list), EXTRA (args
# passed to every run, e.g. "--fetch sleep" or "--keys 20000 --cap 10000").
set -uo pipefail
cd "$(dirname "$0")"
./build.sh >/dev/null || { echo "build failed" >&2; exit 1; }

C=bin/cache3_c; R=bin/cache3_rust; T=bin/cache3_c_tsan
EXTRA=${EXTRA:-}
# name : binary : args
CONFIGS=(
  "$C --variant one_hold"
  "$C --variant one"
  "$C --variant striped --stripes 16"
  "$C --variant striped_hold --stripes 16"
  "$C --variant actors --parts 16"
  "$C --variant actors --parts 64"
  "$R --variant one_hold"
  "$R --variant one"
  "$R --variant striped --stripes 16"
  "$R --variant striped_hold --stripes 16"
  "$R --variant actors --parts 16"
  "$R --variant actors --parts 64"
  "$R --variant dashmap"
  "$R --variant moka"
)

if [[ "${1:-}" == "--quick" ]]; then
  fail=0
  for w in 1 4; do
    sums=()
    for cfg in "${CONFIGS[@]}"; do
      line=$($cfg --workers $w --ops 4000 --reps 2 $EXTRA) || fail=1
      echo "$line"
      [[ "$line" == *" ok=1"* ]] || { echo "FAIL: $cfg workers=$w" >&2; fail=1; }
      sums+=("$(sed -n 's/.*checksum=\([0-9a-f]*\).*/\1/p' <<<"$line")")
    done
    n=$(printf '%s\n' "${sums[@]}" | sort -u | wc -l | tr -d ' ')
    if [[ "$n" != 1 ]]; then echo "FAIL: checksums differ at workers=$w: ${sums[*]}" >&2; fail=1
    else echo "# workers=$w: all ${#sums[@]} configs agree, checksum=${sums[0]}"; fi
  done
  echo "# ThreadSanitizer (C, 4 workers, 10 us fetch)"
  for v in one_hold one striped striped_hold actors; do
    out=$(TSAN_OPTIONS="halt_on_error=1" $T --variant $v --workers 4 --ops 4000 --fetch-us 10 2>&1); rc=$?
    if [[ $rc != 0 ]] || grep -q "ThreadSanitizer" <<<"$out"; then echo "$out" >&2; echo "FAIL: tsan $v" >&2; fail=1
    else echo "tsan $v: clean"; fi
  done
  exit $fail
fi

REPS=${REPS:-5}; OPS=${OPS:-200000}; WORKERS=${WORKERS:-"1 2 4 8 12 16"}
for w in $WORKERS; do
  for cfg in "${CONFIGS[@]}"; do
    $cfg --workers $w --ops $OPS --reps $REPS $EXTRA
  done
done

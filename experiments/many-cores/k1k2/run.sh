#!/usr/bin/env bash
# K1 and K2. One machine-readable line per configuration on stdout
# (key=value, space separated); checks and progress on stderr.
#
#   ./run.sh --quick    smoke run: tiny durations, builds with TSan, runs the
#                       TSan K1 once, checks C and Rust K2 agree. Not timing.
#   ./run.sh            full: K1 at 1,2,4,8,12,16 workers x parts 1,8,64 x
#                       uniform,zipf x spin,os locks x C,Rust, REPS reps of
#                       MS ms each (median, min, max Mops/s; p50/p99 of one
#                       at() in ns); then K2 for max 1k,10k,100k.
#   env: REPS (5), MS (200), KEYS (10000), WORKERS, QOS (p|e|none)
set -euo pipefail
cd "$(dirname "$0")"
MODE=full
[[ "${1:-}" == "--quick" ]] && MODE=quick

if [[ $MODE == quick ]]; then
  ./build.sh --tsan
  echo "== K1 quick (C, Rust)" >&2
  ./bin/k1_c    --workers 1,4 --parts 1,8,64 --reps 1 --ms 20
  ./bin/k1_rust --workers 1,4 --parts 1,8,64 --reps 1 --ms 20
  echo "== K1 under ThreadSanitizer (C)" >&2
  TSAN_OPTIONS="halt_on_error=1" ./bin/k1_c_tsan --workers 4 --parts 1,8 --reps 1 --ms 50 --keys 1000 >/dev/null
  echo "tsan: clean" >&2
  echo "== K2 quick (C vs Rust must match)" >&2
  K2ARGS=(--max 1000 --factors 1.0,1.1,2,10 --measure 10)
  ./bin/k2_c    "${K2ARGS[@]}" > bin/k2_quick_c.txt
  ./bin/k2_rust "${K2ARGS[@]}" > bin/k2_quick_rust.txt
  if diff <(sed 's/lang=[a-z]*//' bin/k2_quick_c.txt) <(sed 's/lang=[a-z]*//' bin/k2_quick_rust.txt) >/dev/null; then
    echo "k2: C and Rust agree on $(wc -l < bin/k2_quick_c.txt | tr -d ' ') configurations" >&2
  else
    echo "FAIL: k2 C and Rust disagree" >&2; exit 1
  fi
  cat bin/k2_quick_c.txt
  exit 0
fi

./build.sh
REPS=${REPS:-5}; MS=${MS:-200}; KEYS=${KEYS:-10000}
WORKERS=${WORKERS:-1,2,4,8,12,16}; QOS=${QOS:-p}
for bin in k1_c k1_rust; do
  ./bin/$bin --workers "$WORKERS" --parts 1,8,64 --dist uniform,zipf --lock spin,os \
    --keys "$KEYS" --reps "$REPS" --ms "$MS" --qos "$QOS"
done
./bin/k2_c --max 1000,10000,100000 --parts 8,64 --factors 1.0,1.1,1.25,1.5,2,4,10 --measure 20 > bin/k2_full_c.txt
./bin/k2_rust --max 1000,10000,100000 --parts 8,64 --factors 1.0,1.1,1.25,1.5,2,4,10 --measure 20 > bin/k2_full_rust.txt
if ! diff <(sed 's/lang=[a-z]*//' bin/k2_full_c.txt) <(sed 's/lang=[a-z]*//' bin/k2_full_rust.txt) >/dev/null; then
  echo "FAIL: k2 C and Rust disagree" >&2; exit 1
fi
cat bin/k2_full_c.txt

#!/bin/sh
# Spin-budget sweep for hops to a parked owner.
#   ./measure.sh --quick     smoke: --check (every policy, invariants), the
#                            check under ThreadSanitizer, 3 short configs.
#                            Numbers not meaningful.
#   ./measure.sh [--reps N]  full matrix (commands.sh, 810 configs, about
#                            8 min a rep), ONE CONFIG AT A TIME, each a
#                            separate process. One line per config:
#   SPIN tag=run policy= reply_spin_ns= idle_spin_ns= service_ns= iters=
#        gap_ns= workers= window_ms= hops= hops_per_s= hop_p50_ns=
#        hop_p99_ns= hop_p999_ns= reach_p50_ns= reach_p99_ns=
#        cpu_ns_per_hop= util= work_util= waste= spin_ns_per_hop= spin_hit=
#        parks_per_hop= wakes_per_hop= csw_per_hop= checked_hops= ok|FAIL
# Output goes to results/full-<stamp>.txt (and stdout). Then
#   python3 analyze.py results/full-<stamp>.txt
# Run the full mode alone: other load moves parked wakeups by microseconds.
set -eu
cd "$(dirname "$0")"
[ -x bin/spin ] && [ -x bin/spin_tsan ] || ./build.sh >&2
mkdir -p results
if [ "${1:-}" = "--quick" ]; then
  # results/tsan.log is the macOS reference; other machines write results/cloud/tsan.log.
  tlog=results/tsan.log; [ "$(uname -s)" = Darwin ] && : > "$tlog"
  [ "$(uname -s)" = Darwin ] || { mkdir -p results/cloud; tlog=results/cloud/tsan.log
    echo "# machine=cloud $(date '+%F %T') bin/spin_tsan --check (see experiments/MACHINE-cloud.md)" > "$tlog"; }
  ./bin/spin --check
  ./bin/spin_tsan --check >/dev/null 2>>"$tlog" || { echo "TSAN check failed" >&2; exit 1; }
  if grep -q ThreadSanitizer "$tlog"; then echo "TSAN: races, see $tlog" >&2; exit 1; fi
  echo "TSAN ok"
  npi=$(./bin/spin --calibrate)
  for a in "--budget-ns 0 --gap-ns 20000 --workers 2" "--budget-ns 2000 --gap-ns 0 --workers 8" \
           "--policy pred --budget-ns 5000 --gap-ns 5000 --workers 8"; do
    ./bin/spin $a --service-ns 1000 --warm-ms 5 --window-ms 10 --ns-per-iter "$npi"
  done
  exit 0
fi
reps=1
[ "${1:-}" = "--reps" ] && reps=$2
stamp=$(date +%Y%m%d-%H%M%S)
out=results/full-$stamp.txt
npi=$(./bin/spin --calibrate)
echo "# spin sweep $stamp ns_per_iter=$npi reps=$reps host=$(sysctl -n machdep.cpu.brand_string)" | tee "$out"
fails=0
r=1
while [ "$r" -le "$reps" ]; do
  ./commands.sh | while read -r args; do
    # shellcheck disable=SC2086
    ./bin/spin $args --ns-per-iter "$npi" --warm-ms 50 --window-ms 400 | sed "s/^SPIN /SPIN rep=$r /" | tee -a "$out" \
      || echo "SPIN rep=$r FAIL exit args: $args" | tee -a "$out"
  done
  r=$((r + 1))
done
n=$(grep -c ' FAIL' "$out" || true)
echo "# done: $(grep -c '^SPIN' "$out") lines, $n failed" | tee -a "$out"
[ "$n" -eq 0 ]

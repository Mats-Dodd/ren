#!/usr/bin/env bash
# Oversubscription control on the cloud machine (4 vCPUs): is a collapse above
# 4 workers the design or the machine? Back-to-back hops (gap 0, service 100 ns)
# at workers 2..8 for budgets 0, 5 us and inf, with placement
#   auto  pin worker i to CPU i iff workers <= CPUs (the main sweep's rule)
#   off   never pin (the scheduler places threads)
#   wrap  pin worker i to CPU i mod CPUs (8 workers = 2 per CPU, fixed)
# Each config: one `flock -x` acquisition, load1 at start and end, REPS runs,
# then cloudstats.py (median/min/max/spread; re-run up to 2 more times if the
# hop_p99/cpu spread is > 10%, else NOISY).
#
#   ./oversub-cloud.sh [STAMP]     -> results/cloud/oversub-<stamp>.txt (machine=cloud)
# Env: RESULTS (output dir, default results/cloud), FILTER (ERE on the args line),
#      NPI (ns per iter; default: calibrate under flock -x), REPS (default 7).
set -uo pipefail
cd "$(dirname "$0")"
LOCK=/tmp/ren-bench/lock
export REPS=${REPS:-7}
stamp=${1:-$(date +%Y%m%d-%H%M%S)}
RESULTS=${RESULTS:-results/cloud}
FILTER=${FILTER:-}
out=$RESULTS/oversub-$stamp.txt
mkdir -p "$RESULTS"
[ -x bin/spin ] || flock -s "$LOCK" ./build.sh >&2 || exit 1
npi=${NPI:-$(flock -x "$LOCK" ./bin/spin --calibrate)}
[ -f "$out" ] || echo "# machine=cloud spin oversubscription control stamp=$stamp ns_per_iter=$npi reps=$REPS cpus=$(nproc) kernel=$(uname -r) (see experiments/MACHINE-cloud.md)" > "$out"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
for b in 0 5000 inf; do for n in 2 3 4 5 6 8; do for pin in auto off wrap; do
  # auto == wrap for n <= 4; skip the duplicate
  [ "$pin" = wrap ] && [ "$n" -le "$(nproc)" ] && continue
  args="--policy fixed --budget-ns $b --service-ns 100 --gap-ns 0 --workers $n --pin $pin"
  grep -qF "args=\"$args\"" "$out" && continue
  [ -n "$FILTER" ] && ! printf '%s\n' "$args" | grep -Eq -- "$FILTER" && continue
  t=1
  while :; do
    # shellcheck disable=SC2086
    flock -x "$LOCK" ./measure-cloud.sh --one "$npi" "$t" $args > "$tmp"
    grep '^SPIN ' "$tmp" | sed "s/^/RAW /" >> "$out"
    last=0; [ $t -ge 3 ] && last=1
    # shellcheck disable=SC2086
    line=$(python3 cloudstats.py "$tmp" "$t" "$last" "$REPS" hop_p99_ns,cpu_ns_per_hop $args); rc=$?
    [ $rc -ne 3 ] && break
    t=$((t + 1))
  done
  echo "$line" >> "$out"
  echo "$line" | grep -o 'hops_per_s_med=[^ ]*\|hop_p99_ns_med=[^ ]*\|status=[A-Z a-z]*' | tr '\n' ' ' >&2; echo " $args" >&2
done; done; done

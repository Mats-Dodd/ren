#!/bin/sh
# Fuel accuracy. W4 (5460 posts per origin) at F=2000, N=4, 32 origins, and
# W5 skew (80 posts) at F=80, at 4 and 16 workers, spin 100, 3 reps.
# Posts and notices are timestamped (--fuellog); overshoot = posts made
# before the scheme noticed - F. For split fuel (credit): posts before the
# first panic, and total posts made (truncated tree size).
set -eu
cd "$(dirname "$0")"
[ -x bin/origins ] || ./build.sh >&2
mkdir -p results
out=results/fuel-$(date +%Y%m%d-%H%M%S).txt
: >"$out"
for rep in 1 2 3; do
  for w in 4 16; do
    for s in atomic vector credit credit_soft home; do
      for cfg in "--wl 4 --F 2000 --N 4 --origins 32" "--wl 5 --F 80 --N 64 --origins 2048"; do
        line=$(./bin/origins --scheme $s --workers $w --spin 100 $cfg --fuellog || true)
        echo "rep=$rep $line" | tee -a "$out"
      done
    done
  done
done
echo "results in $out" >&2

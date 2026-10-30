#!/bin/sh
# Part 2 fuel runs (outbox). 3 reps x {1, 4, 16} workers, spin 100, --fuellog:
#   relay (wl 6) L = 16 64 79 80 81 at F = 80;
#   double (wl 7) at F = 80 and 1000;
#   W4 hot tree at F = 2000 (split vs pooled `home`), and at 5459 / 5460;
#   W5 skew at F = 80.
# Split-fuel schemes: credit_outbox, credit (exact split, no mid-op posts),
# credit_eager (halving). Read panics, panic_depth_min/max, posts_total_min/max
# (per origin), posts_before_panic_min/max (posts before the origin's first
# panic in time).
set -eu
cd "$(dirname "$0")"
[ -x bin/origins ] || ./build.sh >&2
mkdir -p results
out=results/fuel-outbox-$(date +%Y%m%d-%H%M%S).txt
: >"$out"
r() { line=$(./bin/origins "$@" --spin 100 --fuellog || true); echo "rep=$rep $line" | tee -a "$out"; }
for rep in 1 2 3; do
  for w in 1 4 16; do
    for s in credit_outbox credit credit_eager; do
      for L in 16 64 79 80 81; do r --scheme $s --wl 6 --L $L --F 80 --workers $w --N 64 --origins 256; done
      for F in 80 1000; do r --scheme $s --wl 7 --F $F --workers $w --N 16 --origins 64; done
      for F in 2000 5459 5460; do r --scheme $s --wl 4 --F $F --workers $w --N 4 --origins 32; done
      r --scheme $s --wl 5 --F 80 --workers $w --N 64 --origins 512
    done
    r --scheme home --wl 4 --F 2000 --workers $w --N 4 --origins 32
  done
done
echo "results in $out" >&2

#!/bin/sh
# Part 2: does the outbox's hold delay delivery? Publish rings per pass (the
# default), per op (outbox / credit release at op end) or per post (eager
# sends go out at once). W1 and W3, spin 100 and 1000, 8 workers, 3 reps.
set -eu
cd "$(dirname "$0")"
[ -x bin/origins ] || ./build.sh >&2
mkdir -p results
out=results/pub-outbox-$(date +%Y%m%d-%H%M%S).txt
: >"$out"
for rep in 1 2 3; do
  for wl in 1 3; do
    for sp in 100 1000; do
      d=$((8 * 600000)); [ $sp = 1000 ] && d=$((8 * 120000))
      for cfg in "none pass" "none post" "credit pass" "credit op" "credit_outbox pass" "credit_outbox op" "credit_eager pass" "credit_eager post"; do
        set -- $cfg
        line=$(./bin/origins --scheme $1 --pub $2 --wl $wl --workers 8 --spin $sp --N 4096 --deliveries $d || true)
        echo "rep=$rep $line load1=$(sysctl -n vm.loadavg | awk '{print $2}')" | tee -a "$out"
      done
    done
  done
done
echo "results in $out" >&2

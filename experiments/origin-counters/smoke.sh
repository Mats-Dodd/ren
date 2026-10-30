#!/bin/sh
# Correctness smoke: every scheme x workload with --check (a delivery after its
# origin closed, a close with the wrong delivery count, a control message for
# a closed origin), then the same under ThreadSanitizer on a small config.
# `naive` is expected to FAIL on wl 3 and 4: that is the point of it.
set -u
tmp=$(mktemp)
cd "$(dirname "$0")"
[ -x bin/origins ] || ./build.sh
for bin in bin/origins bin/origins_tsan; do
  d=400000; [ $bin = bin/origins_tsan ] && d=20000
  for s in none atomic vector credit credit_soft home naive; do
    for wl in 1 2 3 4; do
      N=4096; [ $wl = 4 ] && N=4
      for w in 1 3 8; do
        line=$($bin --scheme $s --wl $wl --workers $w --spin 0 --N $N --deliveries $d --check 2>"$tmp")
        tsan=$(grep -c "WARNING: ThreadSanitizer" "$tmp" || true)
        echo "$bin $s wl=$wl w=$w tsan_warnings=$tsan $(echo "$line" | tr ' ' '\n' | grep -E '^(late|premature|badcount|bug|ok)=' | tr '\n' ' ')"
      done
    done
  done
done
rm -f "$tmp"
# Part 2 (outbox): the new schemes under --check and TSan.
for bin in bin/origins bin/origins_tsan; do
  d=400000; [ $bin = bin/origins_tsan ] && d=20000
  for s in credit_outbox credit_eager; do
    for wl in 1 2 3 4; do
      N=4096; [ $wl = 4 ] && N=4
      for w in 1 3 8; do
        tmp=$(mktemp)
        line=$($bin --scheme $s --wl $wl --workers $w --spin 50 --N $N --deliveries $d --check 2>"$tmp")
        tsan=$(grep -c "WARNING: ThreadSanitizer" "$tmp" || true); rm -f "$tmp"
        echo "$bin $s wl=$wl w=$w tsan_warnings=$tsan $(echo "$line" | tr ' ' '\n' | grep -E '^(late|premature|badcount|bug|underflow|ok)=' | tr '\n' ' ')"
      done
    done
  done
done

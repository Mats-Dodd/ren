#!/bin/sh
# Prints the full measurement matrix, one bin/spin argument list per line,
# in a fixed shuffled order (so slow drift on the shared machine does not
# line up with one budget). measure.sh runs them one at a time.
set -eu
budgets="0 100 500 1000 2000 5000 10000 20000 50000"
services="100 1000 10000"
gaps="0 1000 5000 20000 100000"
# WORKERS / WAIT_WORKERS override the worker counts (measure-cloud.sh uses
# "2 4 8" and 4: the cloud machine has 4 CPUs). Defaults are the macOS matrix.
workers="${WORKERS:-2 8 16}"
ww="${WAIT_WORKERS:-8}"
# macOS awk's srand(seed) is deterministic. Ubuntu's mawk ignores the seed
# (a different order every call), so off macOS the key is a fixed LCG (MINSTD, exact in doubles).
shuffle() {
  if [ "$(uname -s)" = Darwin ]; then
    awk 'BEGIN{srand(20261029)} {print rand() "\t" $0}' | sort -k1,1 | cut -f2-
  else
    awk 'BEGIN{x=20261029} {x=(x*48271)%2147483647; printf "%010d\t%s\n", x, $0}' |
      sort -k1,1 | cut -f2-
  fi
}
{
  # 1. the fixed sweep: one budget for both kinds of wait, plus never-park
  for b in $budgets inf; do for s in $services; do for g in $gaps; do for n in $workers; do
    echo "--policy fixed --budget-ns $b --service-ns $s --gap-ns $g --workers $n"
  done; done; done; done
  # 2. which wait the spin pays on: reply-only and idle-only (1 us, $ww workers)
  for b in $budgets; do for g in $gaps; do
    echo "--policy fixed --reply-spin-ns $b --idle-spin-ns 0 --service-ns 1000 --gap-ns $g --workers $ww"
    echo "--policy fixed --reply-spin-ns 0 --idle-spin-ns $b --service-ns 1000 --gap-ns $g --workers $ww"
  done; done
  # 3. adaptive rules, cap = the budget
  for p in ema pred go; do for c in 5000 20000; do for s in $services; do for g in $gaps; do for n in $workers; do
    echo "--policy $p --budget-ns $c --service-ns $s --gap-ns $g --workers $n"
  done; done; done; done; done
} | shuffle

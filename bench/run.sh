#!/bin/sh
# Time each benchmark: `sh bench/run.sh [path to ren]`, or `dune build
# @bench`. Each line is the program, how long it took, and the last line
# it printed. The VM's own modules are copied from examples/vm next to
# its main, so the benchmark runs the example as it is.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ren=${1:-ren}
case $ren in /*) ;; */*) ren=$(pwd)/$ren ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$here"/*.ren "$work"
mkdir "$work/vm"
cp "$here"/../examples/vm/*.ren "$work/vm"
# the example's own main goes; under dune, the copies are read-only
rm -f "$work/vm/main.ren"
cp "$here"/vm/main.ren "$work/vm/main.ren"
cd "$work"
# seconds since the epoch, to the millisecond, on Linux and macOS alike
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
for b in loop fib deep overflow vm/main; do
  start=$(now)
  out=$("$ren" run "$b.ren" 2>&1 | head -1) || true
  stop=$(now)
  printf '%-9s %7.2fs  %s\n' "$b" "$(python3 -c "print($stop - $start)")" "$out"
done

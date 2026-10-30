#!/bin/sh
# Smoke run, a few ms each: every variant once on a small config, the
# ThreadSanitizer build of every variant (they all use threads), and one
# --fsync run per runtime. Numbers are not meaningful. Exits 1 on any
# failed check or race.
set -eu
cd "$(dirname "$0")"
./build.sh >&2
small="--workers 4 --ops 2000 --keys 4096 --dist zipf --get-pct 50"
fail=0
for v in ws_one ws_worker ws_keyed ws_sharded pc_spin pc_park; do
  ./bin/percore --variant $v $small || fail=1
  ./bin/percore --variant $v $small --inflight 3 >/dev/null || fail=1
done
: >bin/tsan.log
for v in ws_one ws_worker ws_keyed ws_sharded pc_spin pc_park; do
  ./bin/percore_tsan --variant $v $small --inflight 2 >/dev/null 2>>bin/tsan.log || fail=1
done
./bin/percore_tsan --variant pc_spin $small --fsync --group 32 --ops 300 --dir "${TMPDIR:-/tmp}" >/dev/null 2>>bin/tsan.log || fail=1
./bin/percore_tsan --variant ws_one $small --fsync --group 32 --ops 300 --dir "${TMPDIR:-/tmp}" >/dev/null 2>>bin/tsan.log || fail=1
if grep -q ThreadSanitizer bin/tsan.log; then echo "TSAN: races, see bin/tsan.log" >&2; fail=1; else echo "TSAN ok"; fi
exit $fail

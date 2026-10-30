#!/bin/sh
# Smoke run, a few ms each: every variant once on a small config, the
# ThreadSanitizer build of every variant (they all use threads), and one
# --fsync run per runtime. Numbers are not meaningful. Exits 1 on any
# failed check or race. Also the extension runtimes (work_stealing,
# per_core, place_at_spawn) under even and skewed load, throughput mode and
# open-loop. On the shared cloud machine run it under the shared lock:
#   flock -s /tmp/ren-bench/lock ./smoke.sh
set -eu
cd "$(dirname "$0")"
./build.sh >&2
small="--workers 4 --ops 2000 --keys 4096 --dist zipf --get-pct 50"
fail=0
for v in ws_one ws_worker ws_keyed ws_sharded pc_spin pc_park; do
  ./bin/percore --variant $v $small || fail=1
  ./bin/percore --variant $v $small --inflight 3 >/dev/null || fail=1
done
# Extension: small keys, short chunks (--work-iters 2000, a few us) so it's quick.
xs="--ops 3000 --keys 4096 --get-pct 50 --conns 4 --shards 4 --work-iters 2000"
xv() { # label args...
  l=$1; shift
  for load in "--dist uniform" "--dist zipf --heavy-pct 5"; do
    for rate in 0 400000; do
      ./bin/percore $xs $load --rate $rate "$@" >bin/smoke-x.out || fail=1
      echo "$l $load rate=$rate: $(tr ' ' '\n' <bin/smoke-x.out | grep -E '^(mops|light_p99_ns|heavy_p50_ns|work_sum|keyset_sum|sustained|ok)=' | tr '\n' ' ')"
    done
  done
}
xv ws      --variant work_stealing  --workers 4
xv pc      --variant per_core       --workers 4 --inflight 4
xv pas_3p1 --variant place_at_spawn --workers 3 --pool 1 --inflight 4
xv pas_2p2 --variant place_at_spawn --workers 2 --pool 2 --inflight 4
xv pas_4p4 --variant place_at_spawn --workers 4 --pool 4 --inflight 4
: >bin/tsan.log
for v in ws_one ws_worker ws_keyed ws_sharded pc_spin pc_park; do
  ./bin/percore_tsan --variant $v $small --inflight 2 >/dev/null 2>>bin/tsan.log || fail=1
done
./bin/percore_tsan --variant pc_spin $small --fsync --group 32 --ops 300 --dir "${TMPDIR:-/tmp}" >/dev/null 2>>bin/tsan.log || fail=1
./bin/percore_tsan --variant ws_one $small --fsync --group 32 --ops 300 --dir "${TMPDIR:-/tmp}" >/dev/null 2>>bin/tsan.log || fail=1
tx="--ops 800 --keys 4096 --get-pct 50 --conns 4 --shards 4 --work-iters 500 --dist zipf --heavy-pct 10"
for rate in 0 200000; do
  ./bin/percore_tsan --variant work_stealing --workers 4 $tx --rate $rate >/dev/null 2>>bin/tsan.log || fail=1
  ./bin/percore_tsan --variant per_core --workers 4 --inflight 3 $tx --rate $rate >/dev/null 2>>bin/tsan.log || fail=1
  ./bin/percore_tsan --variant place_at_spawn --workers 2 --pool 2 --inflight 3 $tx --rate $rate >/dev/null 2>>bin/tsan.log || fail=1
  ./bin/percore_tsan --variant place_at_spawn --workers 3 --pool 3 --inflight 2 $tx --rate $rate >/dev/null 2>>bin/tsan.log || fail=1
done
if grep -q ThreadSanitizer bin/tsan.log; then echo "TSAN: races, see bin/tsan.log" >&2; fail=1; else echo "TSAN ok"; fi
exit $fail

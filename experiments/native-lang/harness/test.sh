#!/usr/bin/env bash
# harness/test.sh <bindir> [suite ...]: the shared test suites against one
# build (bin/<tag>/ from ../build.sh). Runs under the SHARED lock.
#   suites: layout abi deque smoke io replay fuzz xreplay:<other-bindir>
#   default: layout abi deque smoke io replay fuzz
#   env: DRIVERS="epoll uring"  WORKERS="1 4"  TMO=60 (seconds per command)
#        REPLAY_WL="w1 w3 t_cancel t_timer" (the stub: "w1 w3")
# Prints PASS/FAIL per check and a summary; exit 1 if anything failed.
set -uo pipefail
if [ -z "${REN_FLOCKED:-}" ]; then
  mkdir -p /tmp/ren-bench
  export REN_FLOCKED=1
  exec flock -s /tmp/ren-bench/lock "$0" "$@"
fi
B=$(cd "${1:?usage: test.sh <bindir> [suite ...]}" && pwd); shift
SUITES=("$@"); [ ${#SUITES[@]} -gt 0 ] || SUITES=(layout abi deque smoke io replay fuzz)
DRIVERS=${DRIVERS:-"epoll uring"}
WORKERS=${WORKERS:-"1 4"}
TMO=${TMO:-60}
REPLAY_WL=${REPLAY_WL:-"w1 w3 t_cancel t_timer"}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ren-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; FAILED=()

run() {   # name cmd...
  local name=$1; shift
  if timeout "$TMO" "$@" >"$TMP/out" 2>&1; then
    echo "PASS $name"; pass=$((pass + 1))
  else
    local rc=$?
    echo "FAIL $name (exit $rc)"; sed 's/^/     | /' "$TMP/out" | tail -15
    fail=$((fail + 1)); FAILED+=("$name")
  fi
}
expect_fail() {   # name cmd...: the command must exit non-zero (a negative test)
  local name=$1; shift
  if timeout "$TMO" "$@" >"$TMP/out" 2>&1; then
    echo "FAIL $name (accepted a corrupted journal)"; fail=$((fail + 1)); FAILED+=("$name")
  else
    echo "PASS $name"; pass=$((pass + 1))
  fi
}
results() { grep '^result:' "$1" || true; }

suite_layout() { run "layout_check" "$B/layout_check"; }
suite_abi() { run "abi_test" "$B/abi_test"; }
suite_deque() {
  run "deque empty" "$B/deque_stress" empty
  run "deque lifo" "$B/deque_stress" lifo
  run "deque stress" "$B/deque_stress" stress 10 200000
}
suite_smoke() {
  for d in $DRIVERS; do for w in $WORKERS; do
    run "w1 $d x$w" "$B/harness" w1 --driver "$d" --workers "$w" --n 200000
    run "w2 $d x$w" "$B/harness" w2 --driver "$d" --workers "$w" --n 1000000
    run "w3 $d x$w" "$B/harness" w3 --driver "$d" --workers "$w" --n 20000
  done; done
}
suite_io() {
  for d in $DRIVERS; do for w in $WORKERS; do
    for t in t_timer t_pipe t_tcp t_cancel; do run "$t $d x$w" "$B/harness" "$t" --driver "$d" --workers "$w"; done
    run "t_block stop $d x$w" "$B/harness" t_block --driver "$d" --workers "$w" --stop-ms 50
    ASAN_OPTIONS=detect_leaks=0 run "t_block kill $d x$w" "$B/harness" t_block --driver "$d" --workers "$w" --kill-ms 50
  done; done
}
replay_one() {   # recorder-bindir replayer-bindir driver workload n label
  local rb=$1 pb=$2 d=$3 wl=$4 n=$5 label=$6
  local j="$TMP/$wl-$d.j"
  if ! timeout "$TMO" "$rb/harness" "$wl" --driver "$d" --workers 1 --n "$n" --record "$j" >"$TMP/rec.out" 2>&1; then
    echo "FAIL $label record (exit $?)"; tail -5 "$TMP/rec.out" | sed 's/^/     | /'
    fail=$((fail + 1)); FAILED+=("$label record"); return
  fi
  results "$TMP/rec.out" > "$TMP/rec.res"
  if ! timeout "$TMO" "$pb/harness" "$wl" --workers 1 --n "$n" --replay "$j" >"$TMP/rep.out" 2>&1; then
    echo "FAIL $label replay (exit $?)"; tail -5 "$TMP/rep.out" | sed 's/^/     | /'
    fail=$((fail + 1)); FAILED+=("$label replay"); return
  fi
  results "$TMP/rep.out" > "$TMP/rep.res"
  if cmp -s "$TMP/rec.res" "$TMP/rep.res"; then
    echo "PASS $label ($(stat -c %s "$j") journal bytes, output identical)"; pass=$((pass + 1))
  else
    echo "FAIL $label (output differs)"; diff "$TMP/rec.res" "$TMP/rep.res" | sed 's/^/     | /'
    fail=$((fail + 1)); FAILED+=("$label")
  fi
}
suite_replay() {
  for d in $DRIVERS; do
    for wl in $REPLAY_WL; do
      case $wl in w1) n=50000 ;; w3) n=5000 ;; *) n=0 ;; esac
      replay_one "$B" "$B" "$d" "$wl" "$n" "W4 replay $wl $d"
    done
    # negative tests: a corrupted or truncated journal must be refused
    local j="$TMP/neg-$d.j"
    timeout "$TMO" "$B/harness" w3 --driver "$d" --workers 1 --n 200 --record "$j" >/dev/null 2>&1
    python3 -I - "$j" "$TMP/flip.j" "$TMP/trunc.j" <<'EOF'
import sys, struct
src, flip, trunc = sys.argv[1:4]
b = bytearray(open(src, 'rb').read())
pos, last_in = 0, None
while pos + 24 <= len(b):
    kind, ln = struct.unpack_from('<II', b, pos)
    if kind == 20:  # J_REPLY: u64 id, u32 st, u32 len, body[len], u32 in_len, in...
        blen = struct.unpack_from('<I', b, pos + 24 + 12)[0]
        il = struct.unpack_from('<I', b, pos + 24 + 16 + blen)[0]
        if il > 0: last_in = pos + 24 + 20 + blen
    pos += 24 + ln
c = bytearray(b)
if last_in is not None: c[last_in] ^= 0x55
open(flip, 'wb').write(c)
open(trunc, 'wb').write(b[: len(b) - 200])
EOF
    expect_fail "replay refuses a flipped input byte $d" "$B/harness" w3 --workers 1 --n 200 --replay "$TMP/flip.j"
    expect_fail "replay refuses a truncated journal $d" "$B/harness" w3 --workers 1 --n 200 --replay "$TMP/trunc.j"
  done
}
suite_xreplay() {   # other bindir
  local O; O=$(cd "$1" && pwd)
  for d in $DRIVERS; do
    for wl in $REPLAY_WL; do
      case $wl in w1) n=20000 ;; w3) n=2000 ;; *) n=0 ;; esac
      replay_one "$B" "$O" "$d" "$wl" "$n" "xreplay $wl $d: $(basename "$B") -> $(basename "$O")"
    done
  done
}
suite_fuzz() {
  run "fuzz_run random 300" "$B/fuzz_run" --random 300 1
  if [ -x "$B/fuzz" ]; then run "libFuzzer 20000 runs" "$B/fuzz" -runs=20000 -seed=1 -max_len=4096; fi
}

for s in "${SUITES[@]}"; do
  echo "== $s ($(basename "$B"))"
  case "$s" in
    layout) suite_layout ;; abi) suite_abi ;; deque) suite_deque ;; smoke) suite_smoke ;;
    io) suite_io ;; replay) suite_replay ;; fuzz) suite_fuzz ;;
    xreplay:*) suite_xreplay "${s#xreplay:}" ;;
    *) echo "unknown suite $s"; exit 2 ;;
  esac
done
echo "== summary $(basename "$B"): $pass passed, $fail failed"
for f in "${FAILED[@]}"; do echo "   failed: $f"; done
[ "$fail" -eq 0 ]

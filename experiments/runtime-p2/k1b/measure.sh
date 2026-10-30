#!/usr/bin/env bash
# K1b measurements. Every configuration is its own command, run one at a time;
# each prints one key=value line ending in ok=1 (the binaries exit non-zero
# and print FAIL on stderr if a check fails). See PLAN.md for the matrix.
#
#   ./measure.sh --smoke        build with TSan, run TSan once, a few tiny
#                               configs, C = Rust on the simulator. Not timing.
#   ./measure.sh --list [S..]   print the commands a full run would execute
#   ./measure.sh [S..]          full run of sections S (default: all, in order)
#                               sim parts mem throughput extras
#
# Output: results/<section>-<stamp>.txt (the lines), results/<section>-<stamp>.log
# (each command, the load average before it, failures). Throughput lines get
# load1=<1-minute load average before the run> appended.
# env: REPS (5) MS (200) WARM_MS (200) WORKERS (1,2,4,8,12,16) QOS (p)
#      LOAD_MAX (4): before each throughput run, wait (up to LOAD_WAIT s, 300)
#      while the 1-minute load average is above it.
set -uo pipefail
cd "$(dirname "$0")"

REPS=${REPS:-5}; MS=${MS:-200}; WARM_MS=${WARM_MS:-200}
WORKERS=${WORKERS:-1,2,4,8,12,16}; QOS=${QOS:-p}
LOAD_MAX=${LOAD_MAX:-4}; LOAD_WAIT=${LOAD_WAIT:-300}
STAMP=$(date +%Y%m%d-%H%M%S)
LIST=0
FAILS=0

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_load() {
  local waited=0
  while awk -v l="$(load1)" -v m="$LOAD_MAX" 'BEGIN{exit !(l>m)}' && (( waited < LOAD_WAIT )); do
    sleep 5; waited=$((waited + 5))
  done
}

# run SECTION CMD...: one configuration, one line.
run() {
  local sec=$1; shift
  if (( LIST )); then echo "$*"; return; fi
  local out="results/$sec-$STAMP.txt" log="results/$sec-$STAMP.log" line l
  [[ $sec == throughput || $sec == extras ]] && wait_load
  l=$(load1)
  echo "load1=$l $*" >> "$log"
  if line=$("$@" 2>>"$log"); then
    [[ $sec == throughput || $sec == extras ]] && line="$line load1=$l"
    echo "$line" | tee -a "$out"
  else
    echo "FAIL ($?): $*" | tee -a "$log" >&2
    FAILS=$((FAILS + 1))
  fi
}

DISTS="zipf99 zipf70 uniform scan"
MAXES="10000 50000"
IFS=, read -r -a WS <<< "$WORKERS"

sec_sim() {
  # Hit rates on recorded traces, every policy on the same trace; C and Rust
  # must print the same line (compared below), parts at the derived default.
  for d in $DISTS; do for m in $MAXES; do for u in 1.25 2 4 10; do
    for lang in c rust; do run sim bin/sim_$lang --dist $d --max $m --universe $u; done
  done; done; done
}

sec_parts() {
  # Does the shard count change which key is evicted? Same trace at parts 1,
  # 8, 64: vh_s3/s5/s10/clock must not change; vh_plru (variant a) should.
  for d in $DISTS; do for m in $MAXES; do for p in 1 8 64; do
    run parts bin/sim_c --dist $d --max $m --universe 2 --parts $p
  done; done; done
}

sec_mem() {
  for l in packed line line_header; do for s in 32 256; do
    run mem bin/mem_c --layout $l --n 50000 --state $s
  done; done
}

sec_throughput() {
  # The main matrix: 2 langs x 3 variants x 4 dists x 2 max x 2 universes x workers.
  # universe 0.9 = the hit path (every key fits; misses only for keys first
  # seen after warmup); universe 2 = half the keys can't be resident.
  for u in 0.9 2; do for m in $MAXES; do for d in $DISTS; do
    for v in a_lru b_sampled c_clock; do for lang in c rust; do for w in "${WS[@]}"; do
      run throughput bin/k1b_$lang --variant $v --k 5 --lock spin --dist $d --max $m --universe $u \
        --workers $w --reps "$REPS" --ms "$MS" --warm-ms "$WARM_MS" --qos "$QOS"
    done; done; done
  done; done; done
}

sec_extras() {
  # os_unfair_lock on the hit path; sampled k = 3, 10 on the miss path;
  # partition count on the hit path of a and b.
  for d in zipf99 uniform; do for v in a_lru b_sampled c_clock; do for lang in c rust; do for w in 1 8 16; do
    run extras bin/k1b_$lang --variant $v --lock os --dist $d --max 10000 --universe 0.9 \
      --workers $w --reps "$REPS" --ms "$MS" --warm-ms "$WARM_MS" --qos "$QOS"
  done; done; done; done
  for d in $DISTS; do for k in 3 10; do for w in 1 8 16; do
    run extras bin/k1b_c --variant b_sampled --k $k --lock spin --dist $d --max 10000 --universe 2 \
      --workers $w --reps "$REPS" --ms "$MS" --warm-ms "$WARM_MS" --qos "$QOS"
  done; done; done
  for d in zipf99 uniform; do for v in a_lru b_sampled; do for p in 1 8 64; do for w in 8 16; do
    run extras bin/k1b_c --variant $v --lock spin --dist $d --max 10000 --universe 0.9 --parts $p \
      --workers $w --reps "$REPS" --ms "$MS" --warm-ms "$WARM_MS" --qos "$QOS"
  done; done; done; done
}

# After sim: C and Rust lines must match. After parts: one summary line per
# (dist, max) saying whether each policy's victims changed with parts.
check_sim() {
  local f="results/sim-$STAMP.txt"
  [[ -f $f ]] || return
  if diff <(grep 'lang=c ' "$f" | sed 's/lang=c //') <(grep 'lang=rust ' "$f" | sed 's/lang=rust //') >/dev/null; then
    echo "k1b_sim_agree lines=$(grep -c 'lang=c ' "$f") ok=1" | tee -a "$f"
  else
    echo "k1b_sim_agree ok=0 (C and Rust differ)" | tee -a "$f" >&2; FAILS=$((FAILS + 1))
  fi
}
check_parts() {
  local f="results/parts-$STAMP.txt"
  [[ -f $f ]] || return
  awk '
    { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
      key = v["dist"] " " v["max"]
      split("s3 s5 s10 clock plru lru", ps, " ")
      for (j in ps) { n = "vh_" ps[j]; if (!((key, n) in first)) first[key, n] = v[n]; else if (first[key, n] != v[n]) changed[key, n] = 1 }
      keys[key] = 1 }
    END { for (k in keys) { split(k, km, " ")
      printf "k1b_parts dist=%s max=%s", km[1], km[2]
      bad = 0
      split("s3 s5 s10 clock plru lru", ps, " ")
      for (j = 1; j <= 6; j++) { c = ((k, "vh_" ps[j]) in changed); printf " %s_changes=%d", ps[j], c
        if (c && ps[j] != "plru") bad = 1 }
      printf " ok=%d\n", !bad } }' "$f" | sort | tee -a "$f"
  grep -q 'k1b_parts.*ok=0' "$f" && { echo "FAIL: a sampled or clock victim depended on parts" >&2; FAILS=$((FAILS + 1)); }
}

smoke() {
  ./build.sh --tsan || exit 1
  echo "== TSan (C, every variant, 4 workers, misses on)" >&2
  for v in a_lru b_sampled c_clock; do for p in 1 8; do
    TSAN_OPTIONS="halt_on_error=1" bin/k1b_c_tsan --variant $v --workers 4 --reps 1 --ms 50 --warm-ms 20 \
      --max 1000 --universe 2 --dist scan --parts $p >/dev/null || { echo "FAIL: tsan $v parts=$p" >&2; exit 1; }
  done; done
  echo "tsan: clean" >&2
  echo "== tiny timing configs (not measurements)" >&2
  for lang in c rust; do for v in a_lru b_sampled c_clock; do
    bin/k1b_$lang --variant $v --workers 4 --reps 1 --ms 10 --warm-ms 10 --dist scan --universe 2 || exit 1
    bin/k1b_$lang --variant $v --workers 2 --reps 1 --ms 10 --warm-ms 10 --dist zipf99 --max 50000 || exit 1
  done; done
  echo "== simulator: C = Rust" >&2
  for d in $DISTS; do
    a=$(bin/sim_c --dist $d --max 2000 --universe 2 | sed 's/lang=[a-z]* //')
    b=$(bin/sim_rust --dist $d --max 2000 --universe 2 | sed 's/lang=[a-z]* //')
    [[ "$a" == "$b" ]] || { echo "FAIL: sim C and Rust differ on $d" >&2; exit 1; }
  done
  echo "sim: C and Rust agree" >&2
  bin/mem_c --layout line --state 32 >/dev/null || exit 1
  echo "smoke: ok" >&2
  exit 0
}

[[ "${1:-}" == "--smoke" ]] && smoke
[[ "${1:-}" == "--list" ]] && { LIST=1; shift; }
SECTIONS=("$@")
(( ${#SECTIONS[@]} )) || SECTIONS=(sim parts mem throughput extras)
if (( ! LIST )); then
  ./build.sh || exit 1
  mkdir -p results
  echo "k1b measure $STAMP sections=${SECTIONS[*]} reps=$REPS ms=$MS warm_ms=$WARM_MS qos=$QOS load1=$(load1)" >&2
fi
for s in "${SECTIONS[@]}"; do
  sec_$s
  (( LIST )) && continue
  [[ $s == sim ]] && check_sim
  [[ $s == parts ]] && check_parts
done
(( LIST )) && exit 0
echo "k1b measure done: $FAILS failures" >&2
exit $(( FAILS > 0 ))

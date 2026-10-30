#!/usr/bin/env bash
# K1b on the Linux cloud machine (experiments/MACHINE-cloud.md: "cloud", 4 vCPU
# Xeon, KVM). The macOS script is measure.sh; this one follows the cloud rules:
#
#   - every timed configuration (throughput, extras) is its own command under
#     the EXCLUSIVE lock: flock -x /tmp/ren-bench/lock. Never two at once.
#   - the deterministic, untimed sections (sim, parts, mem) and the build run
#     under the SHARED lock (flock -s), as the machine's rules say for
#     CPU-heavy work that is not a timed benchmark. DET_LOCK=-x makes them
#     exclusive too.
#   - the 1-minute load from /proc/loadavg is read inside the lock at the
#     start and at the end of every configuration and goes on its line
#     (load1_start=, load1_end=).
#   - REPS >= 7 timed reps per configuration (after one untimed warm-up rep);
#     each line has the median, min and max Mops/s, and
#     spread = (max - min) / median. A configuration with spread > 10% is
#     re-run, up to 2 more times; the first attempt at or under 10% is kept.
#     If all three exceed it, the lowest-spread attempt is kept and marked
#     noisy=1 (NOISY: never a headline). Every attempt is in the .log.
#   - workers 1,2,3,4 and oversubscribed 8,16. A line with more workers than
#     the machine's CPUs has oversub=1.
#
#   ./measure-cloud.sh --smoke        build (TSan too) and run measure.sh's smoke
#                                     checks plus an oversubscribed C and Rust
#                                     run, under flock -s. Not timing.
#   ./measure-cloud.sh --list [S..]   print the configurations a run would execute
#   ./measure-cloud.sh [S..]          run sections S (default all, in order):
#                                     sim parts mem throughput extras
#
# Output: results/cloud/<section>-<stamp>.txt (a "# machine=cloud" header, then
# one line per configuration) and results/cloud/<section>-<stamp>.log (each
# attempt's command, load and stderr).
# env: REPS (7, at least 7) MS (200) WARM_MS (200) WORKERS (1,2,3,4,8,16)
#      SPREAD_MAX (0.10) RERUNS (2) LOCK (/tmp/ren-bench/lock) DET_LOCK (-s)
set -uo pipefail
cd "$(dirname "$0")"
SELF=$PWD/$(basename "$0")

LOCK=${LOCK:-/tmp/ren-bench/lock}
load1() { awk '{print $1}' /proc/loadavg; }

# Internal: --one CMD... runs one configuration (the caller holds the lock):
# load before, the command, load after. Prints the command's line with
# load1_start= and load1_end= appended; stderr passes through.
if [[ "${1:-}" == "--one" ]]; then
  shift
  l0=$(load1)
  line=$("$@"); rc=$?
  l1=$(load1)
  [[ $rc == 0 ]] && echo "$line load1_start=$l0 load1_end=$l1"
  exit $rc
fi

REPS=${REPS:-7}; MS=${MS:-200}; WARM_MS=${WARM_MS:-200}
WORKERS=${WORKERS:-1,2,3,4,8,16}
SPREAD_MAX=${SPREAD_MAX:-0.10}; RERUNS=${RERUNS:-2}; DET_LOCK=${DET_LOCK:--s}
(( REPS >= 7 )) || { echo "REPS must be at least 7 on the cloud machine" >&2; exit 2; }
NCPU=$(nproc)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-results/cloud}   # override only to test the script
LIST=0
FAILS=0
mkdir -p /tmp/ren-bench

header() { # section
  echo "# machine=cloud (experiments/MACHINE-cloud.md) section=$1 stamp=$STAMP host_cpus=$NCPU" \
       "kernel=$(uname -r) cpu=\"$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')\"" \
       "reps=$REPS ms=$MS warm_ms=$WARM_MS workers=$WORKERS spread_max=$SPREAD_MAX reruns=$RERUNS" \
       "clock=tsc(rdtsc, calibrated) oslock=pthread_mutex qos=ignored cc=$(clang --version | head -1 | sed 's/ (.*//')" \
       "rustc=\"$(rustc --version)\""
}
ensure() { # section: the .txt gets its header once
  local f="$OUT/$1-$STAMP.txt"
  [[ -f $f ]] || header "$1" > "$f"
}

spread_of() { # a k1b line -> (max - min) / median
  awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
         m = v["mops_median"] + 0; printf "%.4f", (m > 0 ? (v["mops_max"] - v["mops_min"]) / m : 0) }' <<< "$1"
}
workers_of() { sed -n 's/.* --workers \([0-9]*\).*/\1/p' <<< "$*"; }

# det SECTION CMD...: one deterministic configuration, under DET_LOCK.
det() {
  local sec=$1; shift
  if (( LIST )); then echo "flock $DET_LOCK $LOCK $*"; return; fi
  ensure "$sec"
  local out="$OUT/$sec-$STAMP.txt" log="$OUT/$sec-$STAMP.log" line
  echo "cmd: flock $DET_LOCK $LOCK $*" >> "$log"
  if line=$(flock "$DET_LOCK" "$LOCK" "$SELF" --one "$@" 2>>"$log"); then
    echo "$line machine=cloud" | tee -a "$out"
  else
    echo "FAIL: $*" | tee -a "$log" >&2
    FAILS=$((FAILS + 1))
  fi
}

# timed SECTION CMD...: one timed configuration, each attempt under flock -x.
timed() {
  local sec=$1; shift
  if (( LIST )); then echo "flock -x $LOCK $*"; return; fi
  ensure "$sec"
  local out="$OUT/$sec-$STAMP.txt" log="$OUT/$sec-$STAMP.log"
  local w; w=$(workers_of "$*")
  local oversub=$(( w > NCPU ))
  local best="" best_sp="" attempt line sp kept=0
  for (( attempt = 1; attempt <= 1 + RERUNS; attempt++ )); do
    echo "cmd (attempt $attempt): flock -x $LOCK $*" >> "$log"
    if ! line=$(flock -x "$LOCK" "$SELF" --one "$@" 2>>"$log"); then
      echo "FAIL (attempt $attempt): $*" | tee -a "$log" >&2
      FAILS=$((FAILS + 1))
      return
    fi
    sp=$(spread_of "$line")
    echo "  attempt $attempt spread=$sp: $line" >> "$log"
    if [[ -z $best ]] || awk -v a="$sp" -v b="$best_sp" 'BEGIN{exit !(a < b)}'; then best=$line; best_sp=$sp; fi
    if awk -v a="$sp" -v m="$SPREAD_MAX" 'BEGIN{exit !(a <= m)}'; then best=$line; best_sp=$sp; kept=1; break; fi
  done
  local noisy=$(( ! kept ))
  (( attempt > 1 + RERUNS )) && attempt=$((1 + RERUNS))
  local tag=""
  (( noisy )) && tag=" NOISY"
  echo "$best spread=$best_sp attempts=$attempt noisy=$noisy oversub=$oversub machine=cloud$tag" | tee -a "$out"
}

DISTS="zipf99 zipf70 uniform scan"
MAXES="10000 50000"
IFS=, read -r -a WS <<< "$WORKERS"
T="--reps $REPS --ms $MS --warm-ms $WARM_MS --qos p"

sec_sim() {
  # Hit rates on recorded traces, every policy on the same trace; C and Rust
  # must print the same line. Parts at the derived default.
  for d in $DISTS; do for m in $MAXES; do for u in 1.25 2 4 10; do
    for lang in c rust; do det sim bin/sim_$lang --dist $d --max $m --universe $u; done
  done; done; done
}

sec_parts() {
  # Does the shard count change which key is evicted? vh_s3/s5/s10/clock must
  # be equal at parts 1, 8, 64; vh_plru (variant a) should change.
  for d in $DISTS; do for m in $MAXES; do for p in 1 8 64; do
    det parts bin/sim_c --dist $d --max $m --universe 2 --parts $p
  done; done; done
}

sec_mem() {
  for l in packed line line_header; do for s in 32 256; do
    det mem bin/mem_c --layout $l --n 50000 --state $s
  done; done
}

sec_throughput() {
  # 2 langs x 3 variants x 4 dists x 2 max x 2 universes x workers (6 on the cloud).
  for u in 0.9 2; do for m in $MAXES; do for d in $DISTS; do
    for v in a_lru b_sampled c_clock; do for lang in c rust; do for w in "${WS[@]}"; do
      timed throughput bin/k1b_$lang --variant $v --k 5 --lock spin --dist $d --max $m --universe $u \
        --workers $w $T
    done; done; done
  done; done; done
}

sec_extras() {
  # macOS ran these at 1, 8, 16 workers. Here: 1, 4 (the whole box) and the
  # oversubscribed 8, 16; the parts sweep at 4, 8, 16.
  # The OS lock (Linux: pthread_mutex) on the hit path:
  for d in zipf99 uniform; do for v in a_lru b_sampled c_clock; do for lang in c rust; do for w in 1 4 8 16; do
    timed extras bin/k1b_$lang --variant $v --lock os --dist $d --max 10000 --universe 0.9 --workers $w $T
  done; done; done; done
  # Sampled k = 3, 10 on the miss path:
  for d in $DISTS; do for k in 3 10; do for w in 1 4 8 16; do
    timed extras bin/k1b_c --variant b_sampled --k $k --lock spin --dist $d --max 10000 --universe 2 --workers $w $T
  done; done; done
  # Partition count on the hit path of a and b:
  for d in zipf99 uniform; do for v in a_lru b_sampled; do for p in 1 8 64; do for w in 4 8 16; do
    timed extras bin/k1b_c --variant $v --lock spin --dist $d --max 10000 --universe 0.9 --parts $p --workers $w $T
  done; done; done; done
}

sec_headline() {
  # The reduced throughput grid the synthesis rests on, run on an idle
  # machine: C and Rust, all three variants, zipf99 and uniform, max 10000,
  # hits only (universe 0.9) and with real eviction (universe 2), workers
  # 1, 2, 4 and oversubscribed 8. Then sampled k = 3, 10 under eviction.
  # Run with MS=1000 to cut the noise of the 200 ms default.
  for u in 0.9 2; do for d in zipf99 uniform; do
    for v in a_lru b_sampled c_clock; do for lang in c rust; do for w in 1 2 4 8; do
      timed headline bin/k1b_$lang --variant $v --k 5 --lock spin --dist $d --max 10000 --universe $u \
        --workers $w $T
    done; done; done
  done; done
  for d in zipf99 uniform; do for k in 3 10; do for w in 1 4; do
    timed headline bin/k1b_c --variant b_sampled --k $k --lock spin --dist $d --max 10000 --universe 2 --workers $w $T
  done; done; done
}

# After sim: C and Rust lines must match, and the C lines are compared with
# the macOS reference (results/sim-20261029-210431.txt). The simulator is
# deterministic, so they should be identical unless libm's pow() rounds a
# Zipf CDF entry differently; any difference is reported, not hidden.
strip() { sed -e 's/ lang=[a-z]*//' -e 's/ load1_start=.*//' | grep '^k1b_sim '; }
check_sim() {
  local f="$OUT/sim-$STAMP.txt" mac=results/sim-20261029-210431.txt
  [[ -f $f ]] || return
  if diff <(grep 'lang=c ' "$f" | strip) <(grep 'lang=rust ' "$f" | strip) >/dev/null; then
    echo "k1b_sim_agree lines=$(grep -c 'lang=c ' "$f") ok=1 machine=cloud" | tee -a "$f"
  else
    echo "k1b_sim_agree ok=0 (C and Rust differ) machine=cloud" | tee -a "$f" >&2; FAILS=$((FAILS + 1))
  fi
  if [[ -f $mac ]]; then
    local n same
    n=$(grep 'lang=c ' "$f" | strip | wc -l)
    same=$(comm -12 <(grep 'lang=c ' "$f" | strip | sort) <(grep 'lang=c ' "$mac" | strip | sort) | wc -l)
    echo "k1b_sim_vs_macos lines=$n identical=$same machine=cloud" | tee -a "$f"
  fi
}
check_parts() {
  local f="$OUT/parts-$STAMP.txt"
  [[ -f $f ]] || return
  grep '^k1b_sim ' "$f" | awk '
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
      printf " ok=%d machine=cloud\n", !bad } }' | sort | tee -a "$f"
  grep -q 'k1b_parts.*ok=0' "$f" && { echo "FAIL: a sampled or clock victim depended on parts" >&2; FAILS=$((FAILS + 1)); }
}

smoke() {
  flock -s "$LOCK" ./measure.sh --smoke || exit 1
  echo "== oversubscribed (16 workers on $NCPU CPUs), C and Rust, spin and os, misses on" >&2
  for lang in c rust; do for v in a_lru b_sampled c_clock; do for lk in spin os; do
    flock -s "$LOCK" bin/k1b_$lang --variant $v --lock $lk --workers 16 --reps 1 --ms 20 --warm-ms 20 \
      --dist scan --universe 2 >/dev/null || { echo "FAIL: $lang $v $lk at 16 workers" >&2; exit 1; }
  done; done; done
  echo "== TSan, os lock, 8 workers" >&2
  for v in a_lru b_sampled c_clock; do
    TSAN_OPTIONS="halt_on_error=1" flock -s "$LOCK" bin/k1b_c_tsan --variant $v --lock os --workers 8 --reps 1 \
      --ms 50 --warm-ms 20 --max 1000 --universe 2 --dist scan --parts 8 >/dev/null \
      || { echo "FAIL: tsan os $v" >&2; exit 1; }
  done
  echo "measure-cloud smoke: ok" >&2
  exit 0
}

[[ "${1:-}" == "--smoke" ]] && smoke
[[ "${1:-}" == "--list" ]] && { LIST=1; shift; }
SECTIONS=("$@")
(( ${#SECTIONS[@]} )) || SECTIONS=(sim parts mem throughput extras)
if (( ! LIST )); then
  flock -s "$LOCK" ./build.sh || exit 1
  mkdir -p "$OUT"
  echo "k1b measure-cloud $STAMP machine=cloud sections=${SECTIONS[*]} reps=$REPS ms=$MS warm_ms=$WARM_MS workers=$WORKERS load1=$(load1)" >&2
fi
for s in "${SECTIONS[@]}"; do
  sec_$s
  (( LIST )) && continue
  [[ $s == sim ]] && check_sim
  [[ $s == parts ]] && check_parts
done
(( LIST )) && exit 0
echo "k1b measure-cloud done: $FAILS failures (noisy lines: $(cat "$OUT"/*-"$STAMP".txt 2>/dev/null | grep -c 'noisy=1'))" >&2
exit $(( FAILS > 0 ))

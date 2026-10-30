#!/usr/bin/env bash
# switch: the full Linux measurement on the shared cloud machine (machine
# "cloud", experiments/MACHINE-cloud.md). macOS keeps measure.sh / measure-p2.sh.
#
#   ./measure-cloud.sh            build from clean + --check (shared lock), then
#                                 the full run -> results/cloud/measure-<ts>.txt
#   ./measure-cloud.sh --check    build from clean, every binary's --check (ASan/UBSan
#                                 included), all under the shared lock
#   ./measure-cloud.sh --smoke    every config at n/1000 (min 10), 1 process, 1 rep,
#                                 under the shared lock (not timed) -> results/cloud/smoke-<ts>.txt
#
# The configurations are measure-p2.sh's (30 of them, same n, same in-process
# reps: 7, park 7, fanout 63), each run with GOMAXPROCS=1, unpinned, as on macOS.
#
# Repetitions. Each binary already runs R in-process reps and prints their
# median (ns_per_op), min and every rep (reps_ns=). The first in-process rep is
# cold (slab growth, page faults) and is often several times the rest, so the
# spread rule is applied one level up: a configuration is PROCS (>= 7) separate
# processes, each giving its in-process median; the configuration reports the
# median, min and max over those PROCS values and spread = (max-min)/median.
# Every process line (with its reps_ns) stays in the file.
#
# Locking. Every configuration is ONE command `flock -x $LOCK $0 --one ...`
# that runs its PROCS processes back to back (plus, for park, one n=1 process
# for the peak-RSS baseline) and records the 1-minute load from /proc/loadavg
# and hypervisor steal ticks (/proc/stat) at its start and end. Nothing else
# runs inside the lock. If spread > 10% the configuration is re-run (a new lock
# acquisition), up to 2 more times; if it is still > 10% the try with the
# smallest spread is kept and marked NOISY (never a headline).
#
# Memory. Linux has no `/usr/bin/time -l` here; build/peakrss (tools/peakrss.c)
# reports the child's ru_maxrss. So peak_rss is peak RESIDENT SET, not macOS's
# peak phys_footprint, and the in-process footprint_per_task (ren_c, park) is
# an RSS delta from /proc/self/statm. ext_rss_per_task = (median peak RSS at n
# - peak RSS at n=1) / n.
#
# Env: PROCS=7 LOCK=/tmp/ren-bench/lock RESDIR=results/cloud
#      ONLY="<regex on config name>"  run a subset    DRY=1  print the commands
#      PIN=<cpu>  run every timed process under `taskset -c <cpu>` (default: unpinned);
#                 the output file is then measure-pin<cpu>-<ts>.txt
#      NOASLR=1   run every timed process under `setarch -R` (address randomisation off);
#                 the output file is then measure-noaslr-<ts>.txt (with PIN: -pin<cpu>-noaslr-)
set -uo pipefail
cd "$(dirname "$0")"
LOCK=${LOCK:-/tmp/ren-bench/lock}
PROCS=${PROCS:-7}
MAXTRIES=3
SPREAD_MAX=0.10
DRY=${DRY:-0}
ONLY=${ONLY:-.}
PIN=${PIN:-}
NOASLR=${NOASLR:-0}
PINCMD=(); [ -n "$PIN" ] && PINCMD=(taskset -c "$PIN")
[ "$NOASLR" = 1 ] && PINCMD+=(setarch "$(uname -m)" -R)
export GOMAXPROCS=1
load1() { cut -d' ' -f1 /proc/loadavg; }
steal() { awk '/^cpu /{print $9}' /proc/stat; }
fld() { sed -n "s/.* $1=\([^ ]*\).*/\1/p"; } # field from a SWITCH line on stdin

# ---- one configuration, run inside flock -x (or -s for smoke) by the main loop ----
#   --one name try procs errf bin bench n reps max
if [ "${1:-}" = "--one" ]; then
  shift
  name=$1 try=$2 procs=$3 errf=$4 bin=$5 bench=$6 n=$7 reps=$8 max=$9
  l0=$(load1); s0=$(steal); t0=$(date +%s.%N)
  tf=$(mktemp)
  for p in $(seq 1 "$procs"); do
    line=$("${PINCMD[@]}" ./build/peakrss ./build/"$bin" --bench "$bench" --n "$n" --reps "$reps" --max "$max" 2>"$tf")
    cat "$tf" | grep -v '^PEAKRSS' >>"$errf"
    rss=$(fld peak_rss_bytes <"$tf")
    [ -n "$line" ] || line="SWITCH bin=$bin bench=$bench n=$n check=FAIL (no output)"
    echo "cfg=$name try=$try proc=$p $line peak_rss=${rss:-0}"
  done
  if [ "$bench" = park ]; then
    "${PINCMD[@]}" ./build/peakrss ./build/"$bin" --bench park --n 1 --reps 1 >/dev/null 2>"$tf"
    echo "BASE cfg=$name try=$try park_n1_peak_rss=$(fld peak_rss_bytes <"$tf")"
  fi
  rm -f "$tf"
  l1=$(load1); s1=$(steal); t1=$(date +%s.%N)
  echo "LOAD cfg=$name try=$try load1_start=$l0 load1_end=$l1 steal_ticks=$((s1 - s0)) secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
  exit 0
fi

mode=${1:-full}
case $mode in full|--check|--smoke) ;; *) echo "usage: $0 [--check|--smoke]" >&2; exit 2 ;; esac
[ "$PROCS" -ge 7 ] || [ "$mode" != full ] || { echo "PROCS must be >= 7" >&2; exit 2; }
mkdir -p /tmp/ren-bench && touch "$LOCK"

# ---- build from clean and check: CPU-heavy, not timed -> shared lock ----
if [ "$DRY" != 1 ]; then
  flock -s "$LOCK" env CLEAN=1 ./build.sh >&2 || { echo "build FAILED" >&2; exit 1; }
  flock -s "$LOCK" ./measure.sh --check >&2 || { echo "check FAILED" >&2; exit 1; }
fi
[ "$mode" = --check ] && exit 0

RESDIR=${RESDIR:-results/cloud}
mkdir -p "$RESDIR"
ts=$(date +%Y%m%d-%H%M%S)
kind=measure; [ "$mode" = --smoke ] && kind=smoke
[ -n "$PIN" ] && kind=$kind-pin$PIN
[ "$NOASLR" = 1 ] && kind=$kind-noaslr
out=$RESDIR/$kind-$ts.txt cmds=$RESDIR/$kind-$ts.cmds errf=$RESDIR/$kind-$ts.err
[ "$DRY" = 1 ] && out=/dev/stdout cmds=/dev/stdout errf=/dev/null
{
  echo "# switch $kind on machine: cloud (claude.ai cloud container; experiments/MACHINE-cloud.md)"
  echo "# date: $(date -Is)  host: $(uname -srm)"
  echo "# cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //'), $(nproc) vCPUs"
  echo "# toolchains: $(clang --version | head -1); $(go version); $(rustc --version)"
  pinstr=unpinned; [ -n "$PIN" ] && pinstr="pinned to cpu $PIN (taskset -c $PIN)"
  [ "$NOASLR" = 1 ] && pinstr="$pinstr, ASLR off (setarch -R)"
  echo "# GOMAXPROCS=1, $pinstr; PROCS=$PROCS processes a config; in-process reps as measure-p2.sh"
  echo "# memory: peak_rss = child ru_maxrss (not macOS phys_footprint); see the script header"
  echo "# load1 at script start: $(load1)"
} >>"$out"

run_cfg() { # name bin bench n reps [max]
  local name=$1 bin=$2 bench=$3 n=$4 reps=$5 max=${6:-64}
  [[ $name =~ $ONLY ]] || return 0
  local procs=$PROCS lock=-x
  if [ "$mode" = --smoke ]; then n=$(( n / 1000 > 10 ? n / 1000 : 10 )); reps=1; procs=1; lock=-s; fi
  local cmd=(flock "$lock" "$LOCK" "$0" --one "$name" TRY "$procs" "$errf" "$bin" "$bench" "$n" "$reps" "$max")
  if [ "$DRY" = 1 ]; then echo "${cmd[*]/TRY/1}"; return 0; fi
  local try best_try=0 best_sp=999 sline="" bline=""
  for try in $(seq 1 $MAXTRIES); do
    echo "${cmd[*]/TRY/$try}" >>"$cmds"
    "${cmd[@]/TRY/$try}" >>"$out"
    # median / min / max over the processes' ns_per_op (and extra_ns, peak_rss)
    local st
    st=$(grep "^cfg=$name try=$try " "$out" | awk '
      function med(a, n,  i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j+1] = a[j]; a[j+1] = t }
                                     return n % 2 ? a[(n+1)/2] : (a[n/2] + a[n/2+1]) / 2 }
      { for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
        k++; ns[k] = f["ns_per_op"] + 0; ex[k] = f["extra_ns"] + 0; rs[k] = f["peak_rss"] + 0
        if (f["check"] != "ok") bad++
        if (k == 1 || ns[k] < mn) mn = ns[k]; if (k == 1 || ns[k] > mx) mx = ns[k]
        if (k == 1 || ex[k] < emn) emn = ex[k]; if (k == 1 || ex[k] > emx) emx = ex[k]
        bpt = f["bytes_per_task"]; fpt = f["footprint_per_task"]; ha = f["heap_allocs_per_op"]; sa = f["sys_allocs_per_op"] }
      END { if (!k) { print "999 procs=0 check=FAIL"; exit }
            m = med(ns, k); e = med(ex, k); r = med(rs, k); sp = m > 0 ? (mx - mn) / m : 999
            printf "%.4f procs=%d ns_per_op_med=%.2f ns_per_op_min=%.2f ns_per_op_max=%.2f spread=%.3f extra_ns_med=%.2f extra_ns_min=%.2f extra_ns_max=%.2f heap_allocs_per_op=%s sys_allocs_per_op=%s bytes_per_task=%s footprint_per_task=%s peak_rss_med=%.0f check=%s\n",
                   sp, k, m, mn, mx, sp, e, emn, emx, ha, sa, bpt, fpt, r, bad ? "FAIL" : "ok" }')
    local sp=${st%% *}
    if awk -v a="$sp" -v b="$best_sp" 'BEGIN{exit !(a<b)}'; then
      best_sp=$sp best_try=$try sline=${st#* }
    fi
    [ "$mode" = --smoke ] && break
    awk -v a="$sp" -v m="$SPREAD_MAX" 'BEGIN{exit !(a<=m)}' && break
  done
  local noisy=0
  [ "$mode" = --smoke ] || awk -v a="$best_sp" -v m="$SPREAD_MAX" 'BEGIN{exit !(a<=m)}' || noisy=1
  if [ "$bench" = park ]; then
    local b1 rmed
    b1=$(grep "^BASE cfg=$name try=$best_try " "$out" | fld park_n1_peak_rss)
    rmed=$(echo " $sline" | fld peak_rss_med)
    bline="park_n1_peak_rss=$b1 ext_rss_per_task=$(awk -v a="$rmed" -v b="$b1" -v n="$n" 'BEGIN{printf "%.1f", (a-b)/n}')"
  fi
  local ld; ld=$(grep "^LOAD cfg=$name try=$best_try " "$out" | cut -d' ' -f4-)
  echo "CFG name=$name lang=$bin bench=$bench n=$n max=$max reps=$reps used_try=$best_try tries=$try noisy=$noisy $sline $bline $ld" | tee -a "$out" >&2
}

# 1. ping-pong round trips through two one-slot channels
for b in ren_c raw_c switch_go switch_rust; do run_cfg "pingpong_$b" $b pingpong 1000000 7; done
run_cfg pingpong_nested_ren_c ren_c pingpong_nested 1000000 7
run_cfg pingpong_local_switch_rust switch_rust pingpong_local 1000000 7
# 2. spawn + join one at a time; spawn into a limited scope
for b in ren_c raw_c switch_go switch_rust; do run_cfg "spawn_join_$b" $b spawn_join 1000000 7; done
for m in 64 1000; do
  for b in ren_c raw_c switch_go switch_rust; do run_cfg "spawn_batch_m${m}_$b" $b spawn_batch 1000000 7 $m; done
done
# 3. 100k parked tasks: bytes a task, wake-all time (reps 7, as measure-p2.sh)
for b in ren_c raw_c switch_go switch_rust; do run_cfg "park_$b" $b park 100000 7; done
# 4. fan-out of 1,000 tasks x 10 ops on one instance (and with a yield after each op)
for f in fanout fanout_yield; do
  for b in ren_c raw_c switch_go switch_rust; do run_cfg "${f}_$b" $b $f 1000 63; done
done
[ "$DRY" = 1 ] && exit 0

# ---- report: medians against PLAN.md's predictions ----
python3 -I - "$out" "$mode" <<'PY' | sed 's/^/# /' | tee -a "$out" >&2
import sys
cfg = {}
for line in open(sys.argv[1]):
    if line.startswith("CFG "):
        f = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
        cfg[f["name"]] = f
pred = {  # PLAN.md "Predictions" table, ns (bytes for park_bytes)
    ("pingpong", "ren_c"): (12, 25), ("pingpong", "raw_c"): (5, 12), ("pingpong", "switch_go"): (150, 300),
    ("pingpong", "switch_rust"): (150, 300), ("pingpong_local", "switch_rust"): (80, 160),
    ("pingpong_nested", "ren_c"): (25, 45),
    ("spawn_join", "ren_c"): (10, 20), ("spawn_join", "raw_c"): (5, 10), ("spawn_join", "switch_go"): (200, 350),
    ("spawn_join", "switch_rust"): (150, 300),
    ("spawn_batch_m64", "ren_c"): (6, 12), ("spawn_batch_m64", "raw_c"): (4, 8),
    ("spawn_batch_m64", "switch_go"): (250, 400), ("spawn_batch_m64", "switch_rust"): (120, 250),
    ("spawn_batch_m1000", "ren_c"): (8, 20), ("spawn_batch_m1000", "raw_c"): (4, 8),
    ("spawn_batch_m1000", "switch_go"): (300, 600), ("spawn_batch_m1000", "switch_rust"): (150, 300),
    ("park", "ren_c"): (5, 15), ("park", "raw_c"): (2, 5), ("park", "switch_go"): (150, 300), ("park", "switch_rust"): (60, 150),
    ("park_extra", "ren_c"): (15, 30), ("park_extra", "raw_c"): (5, 10), ("park_extra", "switch_go"): (300, 700),
    ("park_extra", "switch_rust"): (150, 350),
    ("park_bytes", "ren_c"): (128, 128), ("park_bytes", "raw_c"): (40, 40), ("park_bytes", "switch_go"): (2500, 3500),
    ("park_bytes", "switch_rust"): (250, 350),
    ("fanout", "ren_c"): (1.5, 3), ("fanout", "raw_c"): (0.5, 1.5), ("fanout", "switch_go"): (15, 35), ("fanout", "switch_rust"): (10, 25),
    ("fanout_yield", "ren_c"): (3, 6), ("fanout_yield", "raw_c"): (1.5, 3), ("fanout_yield", "switch_go"): (25, 50),
    ("fanout_yield", "switch_rust"): (15, 35),
}
if sys.argv[2] == "--smoke":
    pred = {}  # n/1000, one cold rep: not a measurement, so no verdicts
    print("smoke run: n/1000, 1 process, 1 cold rep; NOT a measurement, no comparison with PLAN.md")
def verdict(v, lo, hi):
    return "in range" if lo <= v <= hi else ("BELOW prediction" if v < lo else "ABOVE prediction")
print("---- report (machine: cloud). value = median over processes of each process's in-process median")
print("%-34s %12s %8s %6s  %-14s %s" % ("config", "value", "spread", "noisy", "PLAN predicted", "verdict"))
rows = []
for name, f in cfg.items():
    lang = f["lang"]; b = name[: -len(lang) - 1]
    rows.append((b, lang, "ns", float(f["ns_per_op_med"]), f))
    if f["bench"] == "park":
        rows.append(("park_extra", lang, "ns", float(f["extra_ns_med"]), f))
        rows.append(("park_bytes", lang, "B", float(f["bytes_per_task"]), f))
        rows.append(("park_ext_rss", lang, "B", float(f.get("ext_rss_per_task", "nan")), f))
for b, lang, unit, v, f in rows:
    p = pred.get((b, lang))
    ps = ("%g-%g" % p) if p else ""
    vd = verdict(v, *p) if p else ""
    sp = f["spread"] if unit == "ns" and b != "park_extra" else ""
    print("%-34s %10.2f%-2s %8s %6s  %-14s %s" % (b + " " + lang, v, unit, sp, "NOISY" if f["noisy"] == "1" and unit == "ns" else "", ps, vd))
if sys.argv[2] == "--smoke":
    sys.exit(0)
def g(name, k="ns_per_op_med"):
    f = cfg.get(name); return float(f[k]) if f else float("nan")
r1 = g("pingpong_ren_c") / g("pingpong_raw_c")
r2 = g("park_ren_c") / g("park_raw_c")
print("falsifier: ren_c/raw_c pingpong = %.2fx, park wake = %.2fx (PLAN: design falsified if either > 3x)" % (r1, r2))
pb = cfg.get("park_ren_c", {}).get("bytes_per_task", "nan")
print("falsifier: ren_c parked task = %s B (PLAN: falsified if > 256 B)" % pb)
noisy = [n for n, f in cfg.items() if f["noisy"] == "1"]
bad = [n for n, f in cfg.items() if f.get("check") != "ok"]
print("NOISY configs (not headlines): %s" % (" ".join(noisy) or "none"))
print("check failures: %s" % (" ".join(bad) or "none"))
PY
echo "# load1 at script end: $(load1)" >>"$out"
echo "results in $out" >&2

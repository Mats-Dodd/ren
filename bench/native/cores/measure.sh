#!/bin/sh
# Runs what build.sh built: `sh measure.sh [bin] [csv]`. Every build,
# mode, thread count and tree size, $REPS times (5 if not set), the
# repetitions outermost so a burst of load from elsewhere lands on all
# of one repetition's configurations rather than on one configuration.
# Each line of the CSV is rep, load average, build, then mt's line.
# summarize.py turns it into tables.
set -e
bin=${1:-${TMPDIR:-/tmp}/ren-bench-cores}
csv=${2:-${TMPDIR:-/tmp}/ren-bench-cores.csv}
reps=${REPS:-5}
threads=${THREADS:-1 2 4 8}
echo "rep,load1,build,mode,threads,depth,rounds,secs,nodes_per_sec" >"$csv"
for rep in $(seq 1 "$reps"); do
  # 4: a small value every round takes from the root, so the root's
  # line is all there is; 10: in cache; 20: 48 MB, out of it
  for depth in 4 10 20; do
    # about half a second a run at one thread
    case $depth in 4) rounds=5000000 ;; 10) rounds=100000 ;; 20) rounds=80 ;; esac
    for t in $threads; do
      for b in shared atomic rust plain; do
        for m in a-owned a-borrowed b c d e; do
          case $b in
            rust) [ "$m" = e ] && continue ;;
          esac
          case $b in
            plain) [ "$t" = 1 ] || continue
                   case $m in a-*) ;; *) continue ;; esac ;;
          esac
          load=$(sysctl -n vm.loadavg | awk '{ print $2 }')
          line=$("$bin/mt-$b" "$m" "$t" "$depth" "$rounds")
          echo "$rep,$load,$b,$line" | tee -a "$csv"
        done
      done
    done
  done
done

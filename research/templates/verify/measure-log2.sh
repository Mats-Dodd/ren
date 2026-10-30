#!/bin/sh
# Independent re-run of perf/measure.sh against binaries rebuilt in verify/bin.
V=$(cd "$(dirname "$0")" && pwd); R=$V/results; B=$V/bin
C=$B/interp; T=$B/twin; REN=$V/../perf/today/ren-today
wait_load() {
  i=0
  while :; do
    l=$(sysctl -n vm.loadavg | awk '{print $2}')
    awk -v l=$l 'BEGIN{exit !(l<4)}' && break
    i=$((i+1)); [ $i -ge 40 ] && { echo "$1 load still $l after 20 min" >> $R/load.txt; break; }
    sleep 30
  done
  echo "$1 load-before $(sysctl -n vm.loadavg) waited=${i}x30s" >> $R/load.txt
}
group() {
  name=$1; shift
  wait_load $name
  hyperfine -N --warmup 3 --runs 25 --export-json $R/$name.json "$@" > $R/$name.txt 2>&1
  echo "$name load-after $(sysctl -n vm.loadavg)" >> $R/load.txt
}

group log2 -n log-today "$C log-today" -n log-today-snp "$C log-today-snp" -n log-boxed "$C log-boxed" \
  -n log-passed "$C log-passed" -n log-passed-site "$C log-passed-site" -n log-walk "$C log-walk" -n log-handler "$C log-handler" \
  -n rust-log-write "$T log-write" -n rust-log-format "$T log-format" -n ren-today-binary "$REN"
echo done2 >> $R/load.txt

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
: > $R/load.txt
group base -n c-n0 "$C log-passed 0" -n rust-n0 "$T log-write 0"
group log -n log-today "$C log-today" -n log-today-snp "$C log-today-snp" -n log-boxed "$C log-boxed" \
  -n log-passed "$C log-passed" -n log-passed-site "$C log-passed-site" -n log-walk "$C log-walk" -n log-handler "$C log-handler" \
  -n rust-log-write "$T log-write" -n rust-log-format "$T log-format" -n ren-today-binary "$REN"
group sql -n sql-today "$C sql-today" -n sql-inline "$C sql-inline" -n sql-handler "$C sql-handler" \
  -n sql-boxed "$C sql-boxed" -n sql-plan "$C sql-plan" \
  -n rust-sql-static "$T sql-static" -n rust-sql-reuse "$T sql-reuse" -n rust-sql-build "$T sql-build"
group html -n html-today "$C html-today" -n html-boxed "$C html-boxed" -n html-plan "$C html-plan" \
  -n html-handler "$C html-handler" -n rust-html-write "$T html-write" -n rust-html-format "$T html-format"
group base2 -n c-n0 "$C log-passed 0" -n rust-n0 "$T log-write 0"
echo done >> $R/load.txt

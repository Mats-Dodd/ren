#!/bin/sh
# Times every variant with hyperfine, after waiting for the 1-minute load
# to fall below 4 (the machine is shared). Records the load with each group.
P=$(cd "$(dirname "$0")" && pwd)
R=$P/results; mkdir -p $R
C=$P/c/interp; T=$P/rust/twin; REN=$P/today/ren-today
wait_load() {
  i=0
  while :; do
    l=$(sysctl -n vm.loadavg | awk '{print $2}')
    awk -v l=$l 'BEGIN{exit !(l<4)}' && break
    i=$((i+1)); [ $i -ge 40 ] && { echo "load still $l after 20 min" >&2; break; }
    sleep 30
  done
  echo "$1 load-before $(sysctl -n vm.loadavg)" >> $R/load.txt
}
group() {
  name=$1; shift
  wait_load $name
  hyperfine -N --warmup 3 --runs ${RUNS:-25} --export-json $R/$name.json "$@" > $R/$name.txt 2>&1
  echo "$name load-after $(sysctl -n vm.loadavg)" >> $R/load.txt
}
: > $R/load.txt
group log -n log-today "$C log-today" -n log-today-snp "$C log-today-snp" -n log-boxed "$C log-boxed" \
  -n log-passed "$C log-passed" -n log-walk "$C log-walk" -n log-handler "$C log-handler" \
  -n rust-log-write "$T log-write" -n rust-log-format "$T log-format" -n ren-today-binary "$REN"
group sql -n sql-today "$C sql-today" -n sql-inline "$C sql-inline" -n sql-handler "$C sql-handler" \
  -n sql-boxed "$C sql-boxed" -n sql-plan "$C sql-plan" \
  -n rust-sql-static "$T sql-static" -n rust-sql-reuse "$T sql-reuse" -n rust-sql-build "$T sql-build"
group html -n html-today "$C html-today" -n html-boxed "$C html-boxed" -n html-plan "$C html-plan" \
  -n html-handler "$C html-handler" -n rust-html-write "$T html-write" -n rust-html-format "$T html-format"
group base -n c-n0 "$C log-passed 0" -n rust-n0 "$T log-write 0"
# instructions retired and cycles, one run each, from /usr/bin/time -l
wait_load instr
: > $R/instr.txt
for v in log-today log-today-snp log-boxed log-passed log-walk log-handler sql-today sql-inline sql-handler sql-boxed sql-plan html-today html-boxed html-plan html-handler; do
  for n in 0 10000000; do
    /usr/bin/time -l $C $v $n 2>&1 >/dev/null | awk -v v=c:$v -v n=$n '/instructions retired|cycles elapsed/{print v, n, $2, $1}' >> $R/instr.txt
  done
done
for v in log-write log-format sql-static sql-reuse sql-build html-write html-format; do
  for n in 0 10000000; do
    /usr/bin/time -l $T $v $n 2>&1 >/dev/null | awk -v v=rust:$v -v n=$n '/instructions retired|cycles elapsed/{print v, n, $2, $1}' >> $R/instr.txt
  done
done
echo "instr load-after $(sysctl -n vm.loadavg)" >> $R/load.txt
echo done

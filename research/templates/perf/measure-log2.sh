#!/bin/sh
# The log group again, with interp2 (adds log-passed-site), after the
# first log run saw the load rise to 6.7 during it.
P=$(cd "$(dirname "$0")" && pwd); R=$P/results
C=$P/c/interp2; T=$P/rust/twin; REN=$P/today/ren-today
i=0; while :; do l=$(sysctl -n vm.loadavg | awk '{print $2}'); awk -v l=$l 'BEGIN{exit !(l<4)}' && break; i=$((i+1)); [ $i -ge 40 ] && break; sleep 30; done
echo "log2 load-before $(sysctl -n vm.loadavg)" >> $R/load.txt
hyperfine -N --warmup 3 --runs 25 --export-json $R/log.json \
  -n log-today "$C log-today" -n log-today-snp "$C log-today-snp" -n log-boxed "$C log-boxed" \
  -n log-passed "$C log-passed" -n log-passed-site "$C log-passed-site" -n log-walk "$C log-walk" -n log-handler "$C log-handler" \
  -n rust-log-write "$T log-write" -n rust-log-format "$T log-format" -n ren-today-binary "$REN" > $R/log.txt 2>&1
echo "log2 load-after $(sysctl -n vm.loadavg)" >> $R/load.txt
for n in 0 10000000; do
  /usr/bin/time -l $C log-passed-site $n 2>&1 >/dev/null | awk -v v=c:log-passed-site -v n=$n '/instructions retired|cycles elapsed/{print v, n, $2, $1}' >> $R/instr.txt
done
echo done

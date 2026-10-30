#!/bin/zsh
cd ${0:A:h}
REPS=500
waitload() { for i in {1..40}; do l=$(sysctl -n vm.loadavg | awk '{print $2}'); if (( l < 4.0 )); then echo $l; return 0; fi; sleep 30; done; echo "TIMEOUT $l"; }
for k in one pair trio quad methods_skew; do
  l=$(waitload); echo "$k load_before=$l" >> out/loads.txt
  cmds=()
  for v in null chain lenswitch ph_memcmp ph_neon ph_pad ph_word hmap gperf; do cmds+=("-n" "$v" "bin/$k $v $REPS"); done
  cmds+=("-n" "rust" "bin/rmatch_small $k $REPS")
  hyperfine -N -w 3 -r 25 --export-json out/$k.json "${cmds[@]}" > out/$k.hf.txt 2>&1
  echo "$k load_after=$(sysctl -n vm.loadavg | awk '{print $2}')" >> out/loads.txt
  for v in null chain lenswitch ph_memcmp ph_neon ph_pad ph_word hmap gperf; do
    /usr/bin/time -l bin/$k $v $REPS 2>&1 >/dev/null | egrep "ns/lookup|instructions retired|cycles elapsed" | tr '\n' ' ' | sed "s/^/$k $v /" >> out/internal.txt; echo >> out/internal.txt
  done
  /usr/bin/time -l bin/rmatch_small $k $REPS 2>&1 >/dev/null | egrep "ns/lookup|instructions retired|cycles elapsed" | tr '\n' ' ' | sed "s/^/$k rust /" >> out/internal.txt; echo >> out/internal.txt
done
echo DONE

#!/bin/zsh
# Measurement rule: wait (up to 20 min, polling every 30s) for 1-min load < 4,
# record the load with every timing. hyperfine, 3 warmups, 25 runs.
cd ${0:A:h}
mkdir -p out
REPS=500
waitload() {
  for i in {1..40}; do
    l=$(sysctl -n vm.loadavg | awk '{print $2}')
    if (( l < 4.0 )); then echo $l; return 0; fi
    sleep 30
  done
  echo "TIMEOUT $l"; return 0
}
: > out/loads.txt
for k in methods headers jsreserved json8 json24 schemes renkw; do
  l=$(waitload); echo "$k load_before=$l" >> out/loads.txt
  cmds=()
  for v in null chain lenswitch ph_memcmp ph_neon ph_pad ph_word hmap gperf; do cmds+=("-n" "$v" "bin/$k $v $REPS"); done
  cmds+=("-n" "rust" "bin/rmatch $k $REPS")
  hyperfine -N -w 3 -r 25 --export-json out/$k.json "${cmds[@]}" > out/$k.hf.txt 2>&1
  echo "$k load_after=$(sysctl -n vm.loadavg | awk '{print $2}')" >> out/loads.txt
  # internal min-of-passes ns/lookup and instructions retired, one run each
  for v in null chain lenswitch ph_memcmp ph_neon ph_pad ph_word hmap gperf; do
    /usr/bin/time -l bin/$k $v $REPS 2>&1 >/dev/null | egrep "ns/lookup|instructions retired|cycles elapsed" | tr '\n' ' ' | sed "s/^/$k $v /" >> out/internal.txt; echo >> out/internal.txt
  done
  /usr/bin/time -l bin/rmatch $k $REPS 2>&1 >/dev/null | egrep "ns/lookup|instructions retired|cycles elapsed" | tr '\n' ' ' | sed "s/^/$k rust /" >> out/internal.txt; echo >> out/internal.txt
done
echo DONE

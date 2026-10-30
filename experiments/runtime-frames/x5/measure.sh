#!/bin/sh
# Interleaved X5 runs. Each park run is a fresh process (N=100000).
set -eu
cd "$(dirname "$0")"
ROUNDS=${ROUNDS:-5}
mkdir -p results
out=results/raw-$(date +%Y%m%d-%H%M%S).txt
echo "# machine: $(sysctl -n machdep.cpu.brand_string) $(sysctl -n hw.ncpu) cpus, macOS $(sw_vers -productVersion)" > "$out"
echo "# correctness (ASan+UBSan):" >> "$out"
for p in today static static_x static_xk; do build/frames_asan park $p 5000 | sed 's/^/# asan /' >> "$out"; done
for p in inseg free spare; do build/frames_asan bound $p 20000 | sed 's/^/# asan /' >> "$out"; done
for r in $(seq 1 "$ROUNDS"); do
  echo "# round $r load: $(uptime | sed 's/.*load averages*: //')" >> "$out"
  for p in today static static_x static_xk; do echo "RUN round=$r $(build/frames_clang park $p 100000)" >> "$out"; done
  for p in inseg free spare; do
    echo "RUN round=$r build=clang $(build/frames_clang bound $p 5000000)" >> "$out"
    echo "RUN round=$r build=clang_growinline $(build/frames_gi_clang bound $p 5000000)" >> "$out"
    echo "RUN round=$r build=tcc $(build/frames_tcc bound $p 1000000)" >> "$out"
  done
  # the prototype's convention (r2's fastpath.c): `ren` column, depth 1
  echo "RUN round=$r fastpath=inseg $(build/fp_clang 1 5000000 1 | tail -1)" >> "$out"
  echo "RUN round=$r fastpath=free $(THRASH=1 build/fp_clang 1 5000000 1 2>/dev/null | tail -1)" >> "$out"
  echo "RUN round=$r fastpath=spare $(THRASH=1 SPARE=1 build/fp_clang 1 5000000 1 2>/dev/null | tail -1)" >> "$out"
done
echo "$out"

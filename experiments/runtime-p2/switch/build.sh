#!/bin/sh
# Builds every variant of the single-runtime task-switch experiment.
#   build/ren_c        the Ren single runtime as release would emit it (clang -O2)
#   build/raw_c        hand-written state machines, the floor (clang -O2)
#   build/ren_c_asan   ren_c under AddressSanitizer + UBSan (correctness only)
#   build/raw_c_asan   raw_c under the same
#   build/switch_go    Go twin (run with GOMAXPROCS=1; main also sets it)
#   build/switch_rust  tokio current_thread twin (--release)
#   build/peakrss      Linux only: peak-RSS wrapper standing in for /usr/bin/time -l
# No variant uses threads, so there is no ThreadSanitizer build.
# macOS and Linux (the platform shim is in c/common.h). On the shared cloud
# machine run it under the shared lock: flock -s /tmp/ren-bench/lock ./build.sh
#   CLEAN=1 ./build.sh   removes build/ and rust/target/ first
set -eu
cd "$(dirname "$0")"
CC=${CC:-clang}
if [ "${CLEAN:-0}" = 1 ]; then rm -rf build bin rust/target; fi
mkdir -p build
$CC -O2 -Wall -Wextra -o build/ren_c c/ren_single.c
$CC -O2 -Wall -Wextra -o build/raw_c c/raw.c
SAN="-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer"
san_cc=$CC
# If this clang has no sanitizer runtimes, fall back to gcc's libasan/libubsan.
if ! $CC $SAN -o build/ren_c_asan c/ren_single.c 2>/dev/null; then
  san_cc=gcc
  gcc $SAN -o build/ren_c_asan c/ren_single.c
fi
$san_cc $SAN -o build/raw_c_asan c/raw.c
if [ "$(uname -s)" = Linux ]; then
  $CC -O2 -Wall -Wextra -o build/peakrss tools/peakrss.c
fi
(cd go && go build -trimpath -o ../build/switch_go .)
# Offline first (macOS with a warm registry cache); otherwise fetch via the network/proxy.
(cd rust && { cargo build --release --offline --quiet 2>/dev/null || cargo build --release --quiet; })
cp rust/target/release/switch build/switch_rust
echo "built: $(ls build | tr '\n' ' ')(cc: $($CC --version | head -1); asan: $san_cc; $(go version); $(rustc --version))"

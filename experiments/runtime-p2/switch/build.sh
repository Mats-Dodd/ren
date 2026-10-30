#!/bin/sh
# Builds every variant of the single-runtime task-switch experiment.
#   build/ren_c        the Ren single runtime as release would emit it (clang -O2)
#   build/raw_c        hand-written state machines, the floor (clang -O2)
#   build/ren_c_asan   ren_c under AddressSanitizer + UBSan (correctness only)
#   build/raw_c_asan   raw_c under the same
#   build/switch_go    Go twin (run with GOMAXPROCS=1; main also sets it)
#   build/switch_rust  tokio current_thread twin (--release)
# No variant uses threads, so there is no ThreadSanitizer build.
set -eu
cd "$(dirname "$0")"
mkdir -p build
clang -O2 -Wall -Wextra -o build/ren_c c/ren_single.c
clang -O2 -Wall -Wextra -o build/raw_c c/raw.c
clang -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -o build/ren_c_asan c/ren_single.c
clang -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -o build/raw_c_asan c/raw.c
(cd go && go build -trimpath -o ../build/switch_go .)
(cd rust && cargo build --release --offline --quiet)
cp rust/target/release/switch build/switch_rust
echo "built: $(ls build | tr '\n' ' ')"

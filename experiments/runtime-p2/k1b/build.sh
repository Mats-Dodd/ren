#!/usr/bin/env bash
# Builds K1b into ./bin: C with clang -O2, Rust with cargo --release (no crates).
#   bin/k1b_c bin/k1b_rust   threaded hit path + eviction (variants a, b, c)
#   bin/sim_c bin/sim_rust   single-threaded hit-rate simulator
#   bin/mem_c                memory cost of a cache line per instance
# --tsan also builds bin/k1b_c_tsan (ThreadSanitizer, -O1 -g).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
CC=${CC:-clang}
$CC -O2 -Wall -Wextra -o bin/k1b_c c/k1b.c
$CC -O2 -Wall -Wextra -o bin/sim_c c/sim.c
$CC -O2 -Wall -Wextra -o bin/mem_c c/mem.c
if [[ "${1:-}" == "--tsan" ]]; then
  $CC -O1 -g -fsanitize=thread -o bin/k1b_c_tsan c/k1b.c
fi
(cd rust && cargo build --release --quiet)
cp rust/target/release/k1b bin/k1b_rust
cp rust/target/release/sim bin/sim_rust
echo "built: $(ls bin | grep -v dSYM | tr '\n' ' ')" >&2

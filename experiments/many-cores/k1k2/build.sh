#!/usr/bin/env bash
# Builds K1 and K2 in C (clang -O2) and Rust (release) into ./bin.
# --tsan also builds the C K1 under ThreadSanitizer (bin/k1_c_tsan).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
CC=${CC:-clang}
$CC -O2 -Wall -Wextra -o bin/k1_c c/k1.c
$CC -O2 -Wall -Wextra -o bin/k2_c c/k2.c
if [[ "${1:-}" == "--tsan" ]]; then
  $CC -O1 -g -fsanitize=thread -o bin/k1_c_tsan c/k1.c
fi
(cd rust && cargo build --release --quiet)
cp rust/target/release/k1 bin/k1_rust
cp rust/target/release/k2 bin/k2_rust
echo "built: $(ls bin | tr '\n' ' ')" >&2

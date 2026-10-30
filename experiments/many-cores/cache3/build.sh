#!/usr/bin/env bash
# Builds the C (clang -O2, and a -fsanitize=thread copy) and Rust (release) cache3.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
clang -O2 -Wall -Wextra -o bin/cache3_c c/cache3.c
clang -O1 -g -fsanitize=thread -o bin/cache3_c_tsan c/cache3.c
(cd rust && cargo build --release --quiet)
cp rust/target/release/cache3 bin/cache3_rust
echo "built: bin/cache3_c bin/cache3_c_tsan bin/cache3_rust"

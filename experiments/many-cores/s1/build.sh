#!/bin/sh
# Builds the C (clang -O2), the C under ThreadSanitizer, and the Rust (release).
set -eu
cd "$(dirname "$0")"
mkdir -p bin
clang -O2 -Wall -Wextra -o bin/s1_c c/s1.c
clang -O1 -g -fsanitize=thread -o bin/s1_c_tsan c/s1.c
cargo build --quiet --release --manifest-path rust/Cargo.toml --target-dir build/rust
cp build/rust/release/s1 bin/s1_rust
echo "built: bin/s1_c bin/s1_c_tsan bin/s1_rust"

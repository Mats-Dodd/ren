#!/bin/sh
# Builds P1: C at -O2, C under ThreadSanitizer, Rust in release.
set -eu
cd "$(dirname "$0")"
mkdir -p build
clang -O2 -Wall -Wextra -o build/p1_c c/p1.c
clang -O1 -g -fsanitize=thread -Wall -o build/p1_c_tsan c/p1.c
(cd rust && cargo build --release --quiet)
cp rust/target/release/p1 build/p1_rust
echo "built build/p1_c build/p1_c_tsan build/p1_rust"

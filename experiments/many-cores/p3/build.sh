#!/bin/sh
# Builds the C (clang -O2) and Rust (release) variants of P3 into ./bin.
# --tsan also builds the C under ThreadSanitizer (bin/p3c_tsan).
set -e
cd "$(dirname "$0")"
mkdir -p bin
clang -O2 -Wall -Wextra -o bin/p3c p3.c
if [ "$1" = "--tsan" ]; then
  clang -O1 -g -fsanitize=thread -o bin/p3c_tsan p3.c
fi
(cd rust && cargo build --release --quiet)
cp rust/target/release/p3 bin/p3rust

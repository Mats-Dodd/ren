#!/bin/sh
# Builds every C model into bin/ with clang -O2 (as `ren build --release`
# runs its C compiler), the Rust twins with opt-level 3 and one codegen
# unit, and the Go twins with go build. `sh build.sh`
set -e
cd "$(dirname "$0")"
mkdir -p bin
CC="clang -O2 -std=gnu11 -Wall -Wno-unused-function"
for w in w1 w2 w3 w4; do $CC -o bin/$w c/$w.c; done
(cd rust && cargo build --release --offline -q)
cp rust/target/release/e3 bin/e3-rust
(cd rust && RUSTFLAGS="-C overflow-checks=on" cargo build --release --offline -q --target-dir target-oc)
cp rust/target-oc/release/e3 bin/e3-rust-oc
(cd go && go build -o ../bin/e3-go .)
clang --version | head -1; rustc --version; go version

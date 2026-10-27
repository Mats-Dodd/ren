#!/bin/sh
# Builds the cores experiment (mt.c says what it measures): mt.c in each counting mode,
# and the Rust twin. `sh build.sh [out]`, the folder defaulting to
# ren-bench-cores under $TMPDIR.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-${TMPDIR:-/tmp}/ren-bench-cores}
cc=${REN_CC:-cc}
mkdir -p "$out"
"$cc" -O2 -o "$out/mt-plain" "$here/mt.c" -lpthread
"$cc" -O2 -DREN_RC_SHARED -o "$out/mt-shared" "$here/mt.c" -lpthread
"$cc" -O2 -DREN_RC_ATOMIC -o "$out/mt-atomic" "$here/mt.c" -lpthread
rustc -C opt-level=3 -C codegen-units=1 -o "$out/mt-rust" "$here/rust/main.rs"
echo "built in $out"

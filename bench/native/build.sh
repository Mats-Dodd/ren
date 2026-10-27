#!/bin/sh
# Builds the Rust and Go twin of every benchmark here: `sh build.sh [out]`.
# Each lands in the output folder as <name>-rust and <name>-go, and takes
# its size as its first argument. The folder defaults to ren-bench-native
# under $TMPDIR, outside the repository; REN_BENCH_OUT or the argument
# moves it. Ren's own binaries aren't built here yet: `ren build
# --release main.ren` in a folder builds those native step 2 compiles,
# and step 6 adds them to this script.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-${REN_BENCH_OUT:-${TMPDIR:-/tmp}/ren-bench-native}}
mkdir -p "$out"
out=$(cd "$out" && pwd)
for dir in "$here"/*/; do
  name=$(basename "$dir")
  [ -f "$dir/bench.ren" ] || continue
  echo "== $name"
  rustc -C opt-level=3 -C codegen-units=1 -o "$out/$name-rust" "$dir/rust/main.rs"
  # one file, built outside any module, so no go.mod is needed
  (cd "$dir/go" && go build -o "$out/$name-go" main.go)
done
echo "built in $out"

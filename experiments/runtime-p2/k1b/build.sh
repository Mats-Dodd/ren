#!/usr/bin/env bash
# Builds K1b into ./bin: C with clang -O2, Rust with cargo --release (no crates).
#   bin/k1b_c bin/k1b_rust   threaded hit path + eviction (variants a, b, c)
#   bin/sim_c bin/sim_rust   single-threaded hit-rate simulator
#   bin/mem_c                memory cost of a cache line per instance
# --tsan also builds bin/k1b_c_tsan (ThreadSanitizer, -O1 -g).
# macOS and Linux (c/plat.h, rust/src/plat.rs). On Linux it links -pthread -lm.
# --clean removes bin/ and rust/target/ first.
set -euo pipefail
cd "$(dirname "$0")"
TSAN=0
for a in "$@"; do
  case $a in
    --tsan) TSAN=1 ;;
    --clean) rm -rf bin build target rust/target ;;
    *) echo "unknown arg $a" >&2; exit 2 ;;
  esac
done
mkdir -p bin
CC=${CC:-clang}
LIBS=""
[[ $(uname -s) == Linux ]] && LIBS="-pthread -lm"
$CC -O2 -Wall -Wextra -o bin/k1b_c c/k1b.c $LIBS
$CC -O2 -Wall -Wextra -o bin/sim_c c/sim.c $LIBS
$CC -O2 -Wall -Wextra -o bin/mem_c c/mem.c $LIBS
if (( TSAN )); then
  # The cloud machine's clang 18 has no TSan runtime (libclang_rt.tsan is
  # missing); gcc 13's libtsan is there. Fall back to gcc and say so.
  if ! $CC -O1 -g -fsanitize=thread -o bin/k1b_c_tsan c/k1b.c $LIBS 2>/dev/null; then
    echo "build: $CC has no TSan runtime; building bin/k1b_c_tsan with gcc" >&2
    gcc -O1 -g -fsanitize=thread -o bin/k1b_c_tsan c/k1b.c $LIBS
  fi
fi
(cd rust && cargo build --release --quiet)
cp rust/target/release/k1b bin/k1b_rust
cp rust/target/release/sim bin/sim_rust
echo "built: $(ls bin | grep -v dSYM | tr '\n' ' ')" >&2

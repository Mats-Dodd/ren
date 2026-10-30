#!/bin/sh
# Build K3: the C model (clang -O2), its ThreadSanitizer build, and the Rust one.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/bin"
clang -O2 -Wall -Wextra -o "$here/bin/k3-c" "$here/c/k3.c"
clang -O1 -g -fsanitize=thread -Wall -o "$here/bin/k3-c-tsan" "$here/c/k3.c"
(cd "$here/rust" && cargo build --release --quiet)
cp "$here/rust/target/release/k3" "$here/bin/k3-rust"
echo "built: $here/bin/k3-c $here/bin/k3-c-tsan $here/bin/k3-rust"

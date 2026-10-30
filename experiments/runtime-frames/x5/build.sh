#!/bin/sh
# Builds X5's binaries into build/.
set -eu
cd "$(dirname "$0")"
mkdir -p build
clang -O2 -Wall -Wextra -o build/frames_clang frames.c
clang -O2 -Wall -Wextra -DGROW_INLINE -o build/frames_gi_clang frames.c
tcc -O2 -o build/frames_tcc frames.c
clang -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -o build/frames_asan frames.c
clang -O2 -o build/fp_clang fastpath.c 2>/dev/null
echo built: $(ls build)

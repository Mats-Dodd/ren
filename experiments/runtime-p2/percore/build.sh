#!/bin/sh
# Builds the percore harness: C at -O2, and C under ThreadSanitizer.
# Linux and macOS (the platform shim is in c/percore.c). On the shared cloud
# machine run it under the shared lock: flock -s /tmp/ren-bench/lock ./build.sh
# The cloud machine's clang 18 has no compiler-rt sanitizer runtimes, so the
# TSan build falls back to gcc (libtsan) when clang's TSan cannot link.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
CC=${CC:-clang}
$CC -O2 -Wall -Wextra -pthread -o bin/percore c/percore.c -lm
if $CC -O1 -g -fsanitize=thread -Wall -pthread -o bin/percore_tsan c/percore.c -lm 2>/dev/null; then
  tsan_cc=$CC
else
  tsan_cc=gcc
  gcc -O1 -g -fsanitize=thread -Wall -pthread -o bin/percore_tsan c/percore.c -lm
fi
echo "built bin/percore ($($CC --version | head -1)) bin/percore_tsan ($($tsan_cc --version | head -1))"

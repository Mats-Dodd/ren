#!/bin/sh
# Builds the spin-budget harness: C at -O2, and C under ThreadSanitizer.
# macOS (ulock, mach time) and Linux (futex, clock_gettime, pinning) from one source.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
case "$(uname -s)" in
  Linux) LIBS="-pthread -lm" ;;
  *) LIBS="" ;;
esac
# shellcheck disable=SC2086
clang -O2 -Wall -Wextra -o bin/spin c/spin.c $LIBS
# TSan: clang's runtime if it is installed, else gcc's libtsan (the cloud
# machine has gcc 13's libtsan but no libclang_rt.tsan for clang 18).
TSAN_CC=clang
if [ "$(uname -s)" = Linux ] && [ ! -e "$(clang -print-file-name=libclang_rt.tsan-x86_64.a)" ] &&
   [ ! -e "$(clang -print-resource-dir)/lib/x86_64-unknown-linux-gnu/libclang_rt.tsan.a" ]; then
  TSAN_CC=gcc
fi
# shellcheck disable=SC2086
$TSAN_CC -O1 -g -fsanitize=thread -Wall -o bin/spin_tsan c/spin.c $LIBS
echo "tsan build: $TSAN_CC"
echo "built bin/spin bin/spin_tsan"

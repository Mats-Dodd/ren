#!/bin/sh
# Builds the spin-budget harness: C at -O2, and C under ThreadSanitizer.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
clang -O2 -Wall -Wextra -o bin/spin c/spin.c
clang -O1 -g -fsanitize=thread -Wall -o bin/spin_tsan c/spin.c
echo "built bin/spin bin/spin_tsan"

#!/bin/sh
# Builds the percore harness: C at -O2, and C under ThreadSanitizer.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
clang -O2 -Wall -Wextra -o bin/percore c/percore.c
clang -O1 -g -fsanitize=thread -Wall -o bin/percore_tsan c/percore.c
echo "built bin/percore bin/percore_tsan"

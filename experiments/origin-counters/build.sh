#!/bin/sh
# Builds the origin-counters harness: C at -O2, and C under ThreadSanitizer.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
clang -O2 -Wall -Wextra -o bin/origins c/origins.c
clang -O1 -g -fsanitize=thread -Wall -o bin/origins_tsan c/origins.c
echo "built bin/origins bin/origins_tsan"

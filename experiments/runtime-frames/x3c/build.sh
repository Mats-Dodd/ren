#!/bin/sh
# Builds X3c: (a) server_a (-DSUSP) and (b) server_b, the path objects alone
# for `size`, and ASan+UBSan and TSan builds of both.
set -eu
cd "$(dirname "$0")"
mkdir -p build
W="-O2 -Wall -Wextra"
for v in a b; do
  D=""; [ $v = a ] && D=-DSUSP
  clang $W $D -c -o build/path_$v.o path.c
  clang $W $D -c -o build/rt_$v.o rt.c
  clang -o build/server_$v build/path_$v.o build/rt_$v.o
  clang -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all $D -o build/server_${v}_asan path.c rt.c
  clang -O1 -g -fsanitize=thread $D -o build/server_${v}_tsan path.c rt.c
done
echo built: $(ls build)

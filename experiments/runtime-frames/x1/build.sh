#!/bin/sh
# Builds X1's binaries into build/. clang -O2 and tcc, plus an ASan+UBSan build.
set -eu
cd "$(dirname "$0")"
mkdir -p build
BASE=../../runtime-p2/switch/c/ren_single.c
W="-Wall -Wextra"
clang -O2 $W -o build/base_clang $BASE
clang -O2 $W -o build/reg_clang ren_reg.c
clang -O2 $W -DOPS_NOINLINE -o build/reg_noinl_clang ren_reg.c
clang -O2 $W -DBUMP_NOCHECK -o build/reg_nochk_clang ren_reg.c
tcc -O2 -o build/base_tcc $BASE
tcc -O2 -o build/reg_tcc ren_reg.c
SAN="-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all"
clang $SAN -o build/reg_asan ren_reg.c
clang $SAN -DOPS_NOINLINE -o build/reg_noinl_asan ren_reg.c
clang $SAN -o build/base_asan $BASE
echo built: $(ls build)

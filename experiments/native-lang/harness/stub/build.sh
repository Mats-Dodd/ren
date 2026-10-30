#!/usr/bin/env bash
# harness/stub/build.sh <profile> <outdir>: the STUB's build, written to the
# same contract as c/, rust/ and zig/ build.sh (README.md § Contract).
# NOT ONE OF THE THREE ENTRIES. Profiles: release debug asan tsan tcc
# release-hot lto-hot (the stub's hot library is harness/hot/hot_c.c).
set -euo pipefail
prof=${1:?profile}; out=${2:?outdir}
H=${REN_HARNESS:?REN_HARNESS}
[ -z "${PLANT:-}" ] || { echo "stub: no planted bugs in the stub" >&2; exit 1; }
mkdir -p "$out"
cc=clang
case "$prof" in
  release|release-hot) fl="-O2 -g" ;;
  debug) fl="-O0 -g" ;;
  asan) fl="-O1 -g -fsanitize=address,undefined" ;;
  tsan) fl="-O1 -g -fsanitize=thread" ;;
  tcc) cc=tcc; fl="-g" ;;
  lto-hot) cc=clang-22; fl="-O2 -flto=thin" ;;
  *) echo "stub: unknown profile $prof" >&2; exit 1 ;;
esac
w=""; [ "$cc" = tcc ] || w="-std=gnu11 -Wall -Wextra -Wno-unused-parameter"
$cc $fl $w -D_GNU_SOURCE -I"$H" -c "$H/stub/stub_core.c" -o "$out/stub_core.o"
$cc $fl $w -D_GNU_SOURCE -I"$H" -c "$H/stub/stub_drv.c" -o "$out/stub_drv.o"
$cc $fl $w -D_GNU_SOURCE -I"$H" -c "$H/hot/hot_c.c" -o "$out/hot_c.o"
rm -f "$out/libren_core.a" "$out/libren_hot.a"
ar rcs "$out/libren_core.a" "$out/stub_core.o" "$out/stub_drv.o"
ar rcs "$out/libren_hot.a" "$out/hot_c.o"
: > "$out/link.flags"

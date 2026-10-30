#!/usr/bin/env bash
# c/build.sh <profile> <outdir>: the C entry (README.md § Contract).
# Env: REN_HARNESS (slice.h lives there and only there), PLANT (P1..P5 or empty).
# Profiles: release debug asan ubsan-int tsan tcc release-hot lto-hot.
set -euo pipefail
prof=${1:?profile}; out=${2:?outdir}
H=${REN_HARNESS:?REN_HARNESS}
C=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
plant=""
case "${PLANT:-}" in
  "") ;;
  P[1-5]) plant="-DREN_PLANT=${PLANT#P}" ;;
  *) echo "c/build.sh: bad PLANT '$PLANT'" >&2; exit 1 ;;
esac
CORE=(dq.c journal.c sched.c core.c layout.c drv_common.c drv_epoll.c drv_replay.c)
URING=drv_uring.c
cc=clang; ucc=clang
warn="-std=c11 -Wall -Wextra -Wno-unused-parameter"
[ "${REN_C_WERROR:-1}" = 0 ] || warn="$warn -Werror"   # REN_C_WERROR=0: planted builds that warn
uwarn=$warn
case "$prof" in
  release|release-hot) fl="-O2 -g -DNDEBUG" ;;
  debug) fl="-O0 -g" ;;
  asan) fl="-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined" ;;
  ubsan-int) fl="-O1 -g -fsanitize=undefined,integer -fno-sanitize-recover=all" ;;
  tsan) fl="-O1 -g -fsanitize=thread" ;;
  tcc)
    # tcc 0.9.27 compiles the core (deque, scheduler, op table, epoll, replay,
    # fuzz) through slice.h's asm atomics. liburing.h needs <stdatomic.h>,
    # which tcc lacks, so the io_uring driver alone is compiled by clang.
    cc=tcc; fl="-g"; warn="-Wall"
    ufl="-O2 -g" ;;
  lto-hot) fl="-O2 -g -DNDEBUG" ;;   # core as release; the hot library as ThinLTO bitcode (below)
  *) echo "c/build.sh: unknown profile $prof" >&2; exit 1 ;;
esac
ufl=${ufl:-$fl}
objs=()
for f in "${CORE[@]}"; do
  o="$out/${f%.c}.o"
  $cc $fl $warn $plant -D_GNU_SOURCE -I"$H" -I"$C" -c "$C/$f" -o "$o"
  objs+=("$o")
done
$ucc $ufl $uwarn $plant -D_GNU_SOURCE -I"$H" -I"$C" -c "$C/$URING" -o "$out/drv_uring.o"
objs+=("$out/drv_uring.o")
if [ "$prof" = lto-hot ]; then
  clang-22 -O2 -flto=thin $warn -D_GNU_SOURCE -I"$H" -I"$C" -c "$C/hot.c" -o "$out/hot.o"
else
  $cc $fl $warn -D_GNU_SOURCE -I"$H" -I"$C" -c "$C/hot.c" -o "$out/hot.o"
fi
rm -f "$out/libren_core.a" "$out/libren_hot.a"
ar rcs "$out/libren_core.a" "${objs[@]}"
ar rcs "$out/libren_hot.a" "$out/hot.o"
echo "-luring" > "$out/link.flags"

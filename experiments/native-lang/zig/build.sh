#!/usr/bin/env bash
# zig/build.sh <profile> <outdir>: the Zig entry (README.md § Contract).
# Zig 0.17.0 exactly (/usr/local/bin/zig). Env: REN_HARNESS (slice.h lives
# there and only there), PLANT (P1..P5 or empty).
# Profiles: release-fast release-safe debug tsan release-hot lto-hot.
#
# Generated into <outdir> (never checked in):
#   slice.zig        zig translate-c -lc $REN_HARNESS/slice.h   (@cImport is gone in 0.17)
#   layout_list.zig  REN_LAYOUT_LIST expanded by `zig cc -E` into (type, field) names;
#                    the values are @offsetOf/@sizeOf on slice.zig's types (src/root.zig)
#   opts.zig         build options: plant (PLANT=Pn -> plant = n; the contract's
#                    "-Dplant=N" -- `zig build-lib` has no -D, so it is a module) and tsan
set -euo pipefail
prof=${1:?profile}; out=${2:?outdir}
H=${REN_HARNESS:?REN_HARNESS}
Z=$(cd "$(dirname "$0")" && pwd)
ZIG=${ZIG:-/usr/local/bin/zig}
mkdir -p "$out"
out=$(cd "$out" && pwd)
v=$("$ZIG" version)
[ "$v" = 0.17.0 ] || { echo "zig/build.sh: need zig 0.17.0, have $v" >&2; exit 1; }

plant=0; p2u=false
case "${PLANT:-}" in
  "") ;;
  P[1-5]) plant=${PLANT#P} ;;
  # zig-only P2 variant (results/cloud/bugs-zig.md): Ring.cap is u64 as well, so
  # the spec-exact P2 (which Zig rejects at compile time) can be run
  P2u) plant=2; p2u=true ;;
  *) echo "zig/build.sh: bad PLANT '$PLANT'" >&2; exit 1 ;;
esac

tsan=false; lto=""; mode=ReleaseFast; extra=()
case "$prof" in
  release-fast|release-hot) mode=ReleaseFast ;;
  # safe modes emit stack probes (__zig_probe_stack), which live in compiler-rt:
  # a static library does not bundle it unless asked (-fcompiler-rt)
  release-safe) mode=ReleaseSafe; extra+=(-fcompiler-rt) ;;
  debug) mode=Debug ;;
  tsan) mode=ReleaseSafe; tsan=true; extra+=(-fsanitize-thread -fcompiler-rt) ;;
  lto-hot) mode=ReleaseFast; lto=-flto ;;
  *) echo "zig/build.sh: unknown profile $prof" >&2; exit 1 ;;
esac

# 1. bindings
"$ZIG" translate-c -lc -I"$H" "$H/slice.h" > "$out/slice.zig"

# 2. the layout name list, from the macro itself
cat > "$out/layout_gen.c" <<'EOF'
#include "slice.h"
#define ZX(T, F) .{ #T, #F, sl.T },
#define ZS(T) .{ #T, "", sl.T },
@@BEGIN@@ REN_LAYOUT_LIST(ZX, ZS) @@END@@
EOF
list=$("$ZIG" cc -E -P -I"$H" "$out/layout_gen.c" | tr '\n' ' ' | sed -n 's/.*@@BEGIN@@\(.*\)@@END@@.*/\1/p')
[ -n "$list" ] || { echo "zig/build.sh: REN_LAYOUT_LIST did not expand" >&2; exit 1; }
printf 'const sl = @import("slice");\npub const entries = .{ %s };\n' "$list" > "$out/layout_list.zig"

# 3. options
printf 'pub const plant: u8 = %s;\npub const p2u: bool = %s;\npub const tsan: bool = %s;\n' "$plant" "$p2u" "$tsan" > "$out/opts.zig"

common=(-O "$mode" -fPIC -lc --cache-dir "$Z/.zig-cache" "${extra[@]}")
cd "$Z"
# 4. libren_core.a
# (lto-hot: the contract allows an empty core, but ../build.sh links the harness
#  binaries for every profile, so the core is built as release-fast here too)
{
  "$ZIG" build-lib "${common[@]}" --name ren_core \
    --dep slice --dep opts --dep layout_list -Mroot="$Z/src/root.zig" \
    -Mslice="$out/slice.zig" -Mopts="$out/opts.zig" --dep slice -Mlayout_list="$out/layout_list.zig" \
    -femit-bin="$out/libren_core.a"
}
# 5. libren_hot.a
"$ZIG" build-lib "${common[@]}" $lto --name ren_hot \
  --dep slice --dep opts -Mroot="$Z/src/hot.zig" -Mslice="$out/slice.zig" -Mopts="$out/opts.zig" \
  -femit-bin="$out/libren_hot.a"
# nothing extra: libc and pthread are linked by the harness; the LLVM-built
# objects carry their own .note.GNU-stack (src/root.zig, src/hot.zig). Debug is
# built by Zig 0.17's self-hosted x86-64 backend (the default for Debug), which
# ignores that asm, so the debug profile asks the linker instead (tcc never
# links the debug profile; it does link release-hot, which must stay empty).
if [ "$prof" = debug ]; then echo "-Wl,-z,noexecstack" > "$out/link.flags"; else : > "$out/link.flags"; fi

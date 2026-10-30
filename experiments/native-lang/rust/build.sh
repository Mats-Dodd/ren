#!/usr/bin/env bash
# rust/build.sh <profile> <outdir>: the Rust entry's build (README.md § Contract).
# Env: REN_HARNESS (slice.h is read from there only, by core/build.rs and
# hot/build.rs through the bindgen CLI), PLANT (empty | P1..P5).
# Runs inside the caller's shared lock; takes no lock itself.
#   release        std, panic=abort (stable)
#   release-nostd  no_std + alloc over libc malloc, panic=abort (stable)
#   debug          dev profile: overflow checks + debug assertions, panic=abort
#   tsan           nightly -Zsanitizer=thread (only this profile uses nightly),
#                  no_std build so that every atomic is instrumented
#   release-hot    libren_hot.a only (W5 variant iii); empty libren_core.a
#   lto-hot        libren_hot.a with -Clinker-plugin-lto (W5 variant v)
set -euo pipefail
prof=${1:?profile}; out=${2:?outdir}
: "${REN_HARNESS:?REN_HARNESS must name the harness directory}"
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
feat=()
case "${PLANT:-}" in
  "") ;;
  P[1-5]) feat=(--features "plant${PLANT#P}") ;;
  *) echo "rust/build.sh: bad PLANT '$PLANT'" >&2; exit 1 ;;
esac
tag="$prof${PLANT:+-$PLANT}"
# A separate target dir per profile/plant, so variants never overwrite each other.
export CARGO_TARGET_DIR="$here/target/$tag"
std_libs="-lgcc_s -lutil -lrt -lpthread -lm -ldl"
nostd_libs="-lrt -lpthread"
cargo=(cargo); bstd=()
core=1; hot=1; mode=release; tgt=""; flags=""; libs=$std_libs; core_feat=()
case "$prof" in
  release) ;;
  release-nostd) core_feat=(--no-default-features); libs=$nostd_libs ;;
  debug) mode=debug ;;
  tsan) cargo=(cargo +nightly); tgt=x86_64-unknown-linux-gnu; flags="-Zsanitizer=thread"; bstd=(-Zbuild-std=core,alloc)
        core_feat=(--no-default-features --features tsan); libs=$nostd_libs ;;
  release-hot) core=0; libs="" ;;   # ren_hot is no_std: libc only
  lto-hot) core=0; libs=""; flags="-Clinker-plugin-lto" ;;
  *) echo "rust/build.sh: unknown profile '$prof'" >&2; exit 1 ;;
esac
args=(build --manifest-path "$here/Cargo.toml")
[ "$mode" = release ] && args+=(--release)
[ -n "$tgt" ] && args+=(--target "$tgt" "${bstd[@]}")
dir="$CARGO_TARGET_DIR/${tgt:+$tgt/}$mode"
export RUSTFLAGS="${flags}"
if [ "$core" = 1 ]; then
  "${cargo[@]}" "${args[@]}" -p ren_core "${core_feat[@]}" "${feat[@]}"
  cp "$dir/libren_core.a" "$out/libren_core.a"
else
  rm -f "$out/libren_core.a"; ar rcs "$out/libren_core.a"
fi
if [ "$hot" = 1 ]; then
  "${cargo[@]}" "${args[@]}" -p ren_hot
  cp "$dir/libren_hot.a" "$out/libren_hot.a"
fi
echo "$libs" > "$out/link.flags"

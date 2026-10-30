#!/usr/bin/env bash
# build.sh: build the shared harness against one language's core.
# Machine: cloud (experiments/MACHINE-cloud.md). Every build runs under the
# SHARED lock (flock -s /tmp/ren-bench/lock); timed runs use measure.sh.
#
#   ./build.sh <lang> [profile] [plant]     lang: c | rust | zig | stub
#        -> build/<tag>/ (the language's libraries) and bin/<tag>/:
#           harness abi_test deque_stress layout_check fuzz_run jdump [fuzz]
#        tag = <lang>-<profile>[-<plant>]; plant = P1..P5
#   ./build.sh w5 [lang ...]                W5 hot-path variants -> bin/w5/
#   ./build.sh e1 <c|stub>                  l4's E1: one TU vs separate -O2 core object
#   ./build.sh layout-probe <lang>          SPEC §0.3: deliberate slice.h edits
#   ./build.sh check                        compile the harness alone (clang, gcc, tcc)
#
# A language's build script is <lang>/build.sh <profile> <outdir> (stub:
# harness/stub/build.sh) with env PLANT, REN_HARNESS. It must leave
# <outdir>/libren_core.a, <outdir>/libren_hot.a and <outdir>/link.flags.
set -euo pipefail

if [ -z "${REN_FLOCKED:-}" ]; then
  mkdir -p /tmp/ren-bench
  export REN_FLOCKED=1
  exec flock -s /tmp/ren-bench/lock "$0" "$@"
fi

ROOT=$(cd "$(dirname "$0")" && pwd)
H=${REN_HARNESS:-$ROOT/harness}
export REN_HARNESS=$H
CC=${CC:-clang}
CLANG_LTO=${CLANG_LTO:-clang-22}
LLD_LTO=${LLD_LTO:-lld-22}

die() { echo "build.sh: $*" >&2; exit 1; }

# harness C flags per profile (the core's own flags are the language's business)
hflags() {
  case "$1" in
    debug) echo "-O0 -g" ;;
    asan) echo "-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined" ;;
    ubsan-int) echo "-O1 -g -fsanitize=undefined" ;;
    tsan) echo "-O1 -g -fsanitize=thread" ;;
    *) echo "-O2 -g" ;;
  esac
}
hcc() { case "$1" in tcc) echo tcc ;; *) echo "$CC" ;; esac; }
hwarn() { case "$1" in tcc) echo "" ;; *) echo "-std=gnu11 -Wall -Wextra -Wno-unused-parameter" ;; esac; }

HARNESS_SRC=(host_main.c rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c
             workloads/w3_rtt.c workloads/t_io.c workloads/w_fuzz.c)
WL_SRC=(rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c workloads/w3_rtt.c
        workloads/t_io.c workloads/w_fuzz.c)

lang_script() {
  case "$1" in
    stub) echo "$H/stub/build.sh" ;;
    c | rust | zig) echo "$ROOT/$1/build.sh" ;;
    *) die "unknown language '$1'" ;;
  esac
}

build_lang() {   # lang profile plant
  local lang=$1 prof=$2 plant=${3:-}
  local tag="$lang-$prof${plant:+-$plant}"
  local out="$ROOT/build/$tag" bin="$ROOT/bin/$tag"
  local script; script=$(lang_script "$lang")
  [ -x "$script" ] || die "$script missing or not executable"
  mkdir -p "$out" "$bin"
  echo "== $tag: $script $prof $out"
  local t0=$(date +%s.%N)
  PLANT="$plant" "$script" "$prof" "$out"
  local t1=$(date +%s.%N)
  for f in libren_core.a libren_hot.a link.flags; do [ -e "$out/$f" ] || die "$tag: $script left no $f"; done
  local cc; cc=$(hcc "$prof")
  local fl; fl="$(hflags "$prof") $(hwarn "$prof") -D_GNU_SOURCE -I$H"
  local lf; lf=$(cat "$out/link.flags")
  local libs="$out/libren_core.a $lf -lpthread -lm"
  (cd "$H" && $cc $fl "${HARNESS_SRC[@]}" $libs -o "$bin/harness")
  (cd "$H" && $cc $fl tests/abi_test.c rt.c $libs -o "$bin/abi_test")
  (cd "$H" && $cc $fl tests/deque_stress.c rt.c $libs -o "$bin/deque_stress")
  (cd "$H" && $cc $fl tests/layout_check.c rt.c $libs -o "$bin/layout_check")
  (cd "$H" && $cc $fl fuzz/fuzz_run.c fuzz/fuzz_common.c "${WL_SRC[@]}" $libs -o "$bin/fuzz_run")
  (cd "$H" && $cc $fl tests/jdump.c -o "$bin/jdump")
  if [ "$prof" = asan ] && [ "$cc" = clang ]; then
    (cd "$H" && clang -O1 -g -fsanitize=fuzzer,address,undefined -D_GNU_SOURCE -I$H fuzz/fuzz_target.c \
       fuzz/fuzz_common.c "${WL_SRC[@]}" $libs -o "$bin/fuzz") || echo "note: libFuzzer target did not link (see above)"
  fi
  local t2=$(date +%s.%N)
  printf 'built %s: language %.2fs, harness link %.2fs\n' "$tag" "$(echo "$t1 - $t0" | bc)" "$(echo "$t2 - $t1" | bc)"
  printf '%s lang_build_s=%.3f harness_link_s=%.3f\n' "$tag" "$(echo "$t1 - $t0" | bc)" "$(echo "$t2 - $t1" | bc)" \
    >> "$ROOT/build/build-times.txt"
}

build_w5() {   # langs...
  local langs=("$@"); [ ${#langs[@]} -gt 0 ] || langs=(c)
  local bin="$ROOT/bin/w5" log="$ROOT/build/w5-build.txt"
  mkdir -p "$bin" "$ROOT/build"; : > "$log"
  try() { local name=$1; shift; if (cd "$H" && "$@") >>"$log" 2>&1; then echo "ok   $name" | tee -a "$log"; else echo "FAIL $name: $*" | tee -a "$log"; fi; }
  # (i) static inline in slice.h
  try i-tcc   tcc -DHOT_INLINE -I. hot/w5_hot.c rt.c -o "$bin/w5-i-tcc"
  try i-clang clang -O2 -I. hot/w5_unity.c -o "$bin/w5-i-clang"
  # (ii) C, out of line in another unit
  try ii-tcc   tcc -DVARIANT='"c-extern"' -I. hot/w5_hot.c hot/hot_c.c rt.c -o "$bin/w5-ii-tcc"
  try ii-clang clang -O2 -DVARIANT='"c-extern"' -I. hot/w5_hot.c hot/hot_c.c rt.c -o "$bin/w5-ii-clang"
  for lang in "${langs[@]}"; do
    case "$lang" in
      rust) v=iii; lv=v ;; zig) v=iv; lv=vi ;; *) continue ;;
    esac
    local out="$ROOT/build/$lang-hot"
    if PLANT= "$(lang_script "$lang")" release-hot "$out" >>"$log" 2>&1; then
      try "$v-tcc"   tcc -DVARIANT="\"$lang-extern\"" -I. hot/w5_hot.c rt.c "$out/libren_hot.a" $(cat "$out/link.flags") -lpthread -lm -o "$bin/w5-$v-tcc"
      try "$v-clang" clang -O2 -DVARIANT="\"$lang-extern\"" -I. hot/w5_hot.c rt.c "$out/libren_hot.a" $(cat "$out/link.flags") -lpthread -lm -o "$bin/w5-$v-clang"
    else
      echo "FAIL $v: $lang release-hot build failed (see $log)" | tee -a "$log"
    fi
    local lout="$ROOT/build/$lang-hot-lto"
    if PLANT= "$(lang_script "$lang")" lto-hot "$lout" >>"$log" 2>&1; then
      if [ "$lang" = rust ]; then
        try "$lv-clang22-lto" "$CLANG_LTO" --target=x86_64-unknown-linux-gnu -O2 -flto=thin -fuse-ld="$LLD_LTO" -DVARIANT='"rust-lto"' -I. hot/w5_hot.c rt.c \
          "$lout/libren_hot.a" $(cat "$lout/link.flags") -lpthread -lm -ldl -o "$bin/w5-$lv-lto"
      else
        try "$lv-zigcc-lto" zig cc -O2 -flto -DVARIANT='"zig-lto"' -I. hot/w5_hot.c rt.c "$lout/libren_hot.a" \
          $(cat "$lout/link.flags") -lpthread -lm -o "$bin/w5-$lv-lto"
      fi
    else
      echo "FAIL $lv: $lang lto-hot build failed (see $log)" | tee -a "$log"
    fi
  done
  echo "W5 build log: $log"
}

build_e1() {   # lang (c|stub): the core in the same TU as the workload vs a separate -O2 object, no LTO
  local lang=$1
  local bin="$ROOT/bin/e1-$lang" out="$ROOT/build/e1-$lang"
  mkdir -p "$bin" "$out"
  local core_unity
  case "$lang" in
    stub) core_unity="$H/stub/unity.c" ;;
    c) core_unity="$ROOT/c/unity.c" ;;
    *) die "e1 needs a core written in C (c|stub)" ;;
  esac
  [ -e "$core_unity" ] || die "$core_unity missing"
  local fl="-O2 -g -std=gnu11 -D_GNU_SOURCE -I$H -I$(dirname "$core_unity")"
  "$CC" $fl -c "$core_unity" -o "$out/core.o"
  for w in w1:w1_spawn w2:w2_switch w3:w3_rtt; do
    local name=${w%%:*} file=${w##*:}
    cat > "$out/unity-$name.c" <<EOF
#define WL_ONLY wl_$name
#include "$H/host_main.c"
#include "$H/rt.c"
#include "$H/workloads/wl_common.c"
#include "$H/workloads/$file.c"
#include "$core_unity"
EOF
    "$CC" $fl "$out/unity-$name.c" -lpthread -lm $( [ "$lang" = c ] && cat "$ROOT/build/c-release/link.flags" 2>/dev/null ) -o "$bin/$name-unity"
    "$CC" $fl -DWL_ONLY=wl_$name -c "$H/host_main.c" -o "$out/host_$name.o"
    "$CC" $fl -DWL_ONLY=wl_$name -c "$H/workloads/wl_common.c" -o "$out/wlc_$name.o"
    "$CC" $fl -c "$H/workloads/$file.c" -o "$out/$file.o"
    "$CC" $fl -c "$H/rt.c" -o "$out/rt.o"
    "$CC" "$out/host_$name.o" "$out/wlc_$name.o" "$out/$file.o" "$out/rt.o" "$out/core.o" -lpthread -lm \
      $( [ "$lang" = c ] && cat "$ROOT/build/c-release/link.flags" 2>/dev/null ) -o "$bin/$name-split"
  done
  echo "E1 binaries in $bin: {w1,w2,w3}-{unity,split}"
}

layout_probe() {   # lang
  local lang=$1
  local prof=release; [ "$lang" = zig ] && prof=release-fast   # zig has no "release" profile
  local res="$ROOT/results/cloud/layout-probe-$lang.txt"
  mkdir -p "$ROOT/results/cloud"
  echo "# layout probe, machine cloud, $(date -u +%FT%TZ), language $lang (SPEC §0.3)" > "$res"
  for edit in a b c; do
    local ph="$ROOT/build/probe-$edit/harness"
    rm -rf "$ROOT/build/probe-$edit"; mkdir -p "$ROOT/build/probe-$edit"
    cp -r "$H" "$ph"
    python3 - "$ph/slice.h" "$edit" <<'EOF'
import sys
p, e = sys.argv[1], sys.argv[2]
s = open(p).read()
if e == 'a':   # swap ren_call.task and ren_call.op (same size, offsets move)
    a = '  uint32_t task;      /* the issuing task\'s id */\n'
    b = '  uint32_t op;        /* dependency << 16 | operation (REN_OP_*) */\n'
    assert a + b in s; s = s.replace(a + b, b + a)
elif e == 'b': # a field inserted before ren_io_body.buf (size 32 -> 40; the C assert updated with it)
    a = '  uint64_t len;\n  uint64_t buf;\n  int64_t arg;\n} ren_io_body;'
    assert a in s; s = s.replace(a, '  uint64_t len;\n  uint32_t probe_pad;\n  uint64_t buf;\n  int64_t arg;\n} ren_io_body;')
    s = s.replace('REN_SA(sizeof(ren_io_body) == 32, "ren_io_body");', 'REN_SA(sizeof(ren_io_body) == 40, "ren_io_body");')
elif e == 'c': # renumber an op code
    a = '#define REN_OP_READ        0x00020002u'
    assert a in s; s = s.replace(a, '#define REN_OP_READ        0x00020012u')
open(p, 'w').write(s)
EOF
    local outcome
    if ! REN_HARNESS="$ph" "$0" "$lang" "$prof" >"$ROOT/build/probe-$edit/build.log" 2>&1; then
      outcome="FAILS THE BUILD"
    else
      local b="$ROOT/bin/$lang-$prof"
      if ! "$b/layout_check" >"$ROOT/build/probe-$edit/test.log" 2>&1; then outcome="FAILS A TEST (layout_check)"
      elif ! "$b/abi_test" >>"$ROOT/build/probe-$edit/test.log" 2>&1; then outcome="FAILS A TEST (abi_test)"
      elif ! timeout 60 "$b/harness" w3 --n 2000 >>"$ROOT/build/probe-$edit/test.log" 2>&1; then outcome="FAILS A TEST (w3)"
      else outcome="BUILDS AND PASSES (the change propagated, or went unnoticed: read the logs)"; fi
    fi
    echo "edit $edit: $outcome   (logs: build/probe-$edit/)" | tee -a "$res"
  done
  echo "rebuilding $lang-$prof against the unmodified harness"
  REN_HARNESS="$H" "$0" "$lang" "$prof" >/dev/null
}

check() {
  local out="$ROOT/build/check"; mkdir -p "$out"
  cd "$H"
  for cc in clang gcc tcc; do
    for f in "${HARNESS_SRC[@]}" tests/*.c fuzz/*.c hot/*.c stub/*.c; do
      local w=""; [ "$cc" != tcc ] && w="-std=gnu11 -Wall -Wextra -Wno-unused-parameter -Werror"
      $cc $w -D_GNU_SOURCE -I. -c "$f" -o "$out/x.o" || die "$cc $f"
    done
    echo "ok: harness compiles under $cc"
  done
}

cmd=${1:-}; shift || true
case "$cmd" in
  c | rust | zig | stub)
    prof=${1:-}
    if [ -z "$prof" ]; then case "$cmd" in zig) prof=release-fast ;; *) prof=release ;; esac; fi
    build_lang "$cmd" "$prof" "${2:-}" ;;
  w5) build_w5 "$@" ;;
  e1) build_e1 "${1:-c}" ;;
  layout-probe) layout_probe "${1:?language}" ;;
  check) check ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac

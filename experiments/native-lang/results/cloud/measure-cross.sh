#!/bin/bash
# cross.sh <zig-triple> <rust-triple>: build each core + the harness for a musl target with zig cc
ROOT=/home/user/ren/experiments/native-lang; H=$ROOT/harness; S=/tmp/claude-0/-home-user-ren/d65d9998-bee9-5cff-92bb-30baa48ec4a3/scratchpad
T=$1; RT=$2
LU=$ROOT/build/xlib/liburing-$T/src
HS="host_main.c rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c workloads/w3_rtt.c workloads/t_io.c workloads/w_fuzz.c"
WL="rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c workloads/w3_rtt.c workloads/t_io.c workloads/w_fuzz.c"
link_all() {  # tag libs...
  local tag=$1; shift; local bin=$ROOT/bin/x-$T-$tag; mkdir -p $bin
  local cc="zig cc -target $T -O2 -g -D_GNU_SOURCE -I$H -static"
  (cd $H && $cc $HS "$@" -o $bin/harness 2>&1 | grep -v warning | head -8; echo "  link harness: ${PIPESTATUS[0]}")
  (cd $H && $cc tests/abi_test.c rt.c "$@" -o $bin/abi_test 2>&1 | head -3)
  (cd $H && $cc tests/deque_stress.c rt.c "$@" -o $bin/deque_stress 2>&1 | head -3)
  (cd $H && $cc tests/layout_check.c rt.c "$@" -o $bin/layout_check 2>&1 | head -3)
  (cd $H && $cc fuzz/fuzz_run.c fuzz/fuzz_common.c $WL "$@" -o $bin/fuzz_run 2>&1 | head -3)
  (cd $H && $cc tests/jdump.c -o $bin/jdump 2>&1 | head -3)
  ls $bin | tr '\n' ' '; echo
}
if [ -z "${ONLY:-}" ] || [ "$ONLY" = c ]; then
echo "=== C ($T)"
o=$ROOT/build/x-$T-c; mkdir -p $o
ok=1
for f in dq journal sched core layout drv_common drv_epoll drv_replay drv_uring hot; do
  inc=""; [ $f = drv_epoll ] && [ -n "${SHIM:-}" ] && inc="-include $S/epoll_pwait2_shim.h"
  zig cc -target $T -O2 -g -DNDEBUG -std=c11 -Wall -Wextra -Wno-unused-parameter -D_GNU_SOURCE -I$H -I$ROOT/c -I$LU/include $inc -c $ROOT/c/$f.c -o $o/$f.o 2>&1 | head -5 || ok=0
done
ar rcs $o/libren_core.a $o/dq.o $o/journal.o $o/sched.o $o/core.o $o/layout.o $o/drv_common.o $o/drv_epoll.o $o/drv_replay.o $o/drv_uring.o
link_all c $o/libren_core.a $LU/liburing.a
fi
if [ -z "${ONLY:-}" ] || [ "$ONLY" = rust ]; then
for v in std nostd; do
  echo "=== Rust $v ($RT)"
  o=$ROOT/build/x-$T-rust-$v; mkdir -p $o
  feat=""; [ $v = nostd ] && feat="--no-default-features"
  CARGO_TARGET_DIR=$ROOT/rust/target/x-$RT-$v RUSTFLAGS="" cargo build --release --manifest-path $ROOT/rust/Cargo.toml --target $RT -p ren_core $feat 2>&1 | grep -E "^(error|warning: unused)|Finished|could not" | head -10
  cp $ROOT/rust/target/x-$RT-$v/$RT/release/libren_core.a $o/ 2>/dev/null && link_all rust-$v $o/libren_core.a ${RUST_EXTRA:-}
done
fi
if [ -z "${ONLY:-}" ] || [ "$ONLY" = zig ]; then
echo "=== Zig ($T)"
o=$ROOT/build/x-$T-zig; mkdir -p $o
XT=$T ZIG=$S/zigwrap.sh REN_HARNESS=$H PLANT= $ROOT/zig/build.sh release-fast $o 2>&1 | head -10; echo "  zig build rc=${PIPESTATUS[0]}"
[ -e $o/libren_core.a ] && link_all zig $o/libren_core.a
fi

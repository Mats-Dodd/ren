#!/usr/bin/env bash
# rust/tools/bugs.sh <P0|P1..P5> [step ...]: the planted-bug matrix for the
# Rust entry (SPEC §F), machine "cloud". P0 = no plant (the control).
# Every step runs under its own SHARED lock (flock -s), so timed runs by
# other agents can interleave between steps. Logs go to
# results/cloud/bugs-rust/<plant>/<step>.log; one row per step is appended
# to results/cloud/bugs-rust/summary.tsv: plant step rc seconds.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)        # rust/
NL=$(cd "$here/.." && pwd)                      # experiments/native-lang
H=$NL/harness
export REN_HARNESS=$H
P=${1:?plant}; shift
plant=$P; [ "$P" = P0 ] && plant=""
feat=(); [ -n "$plant" ] && feat=(--features "plant${plant#P}")
sfx=${plant:+-$plant}
L=$NL/results/cloud/bugs-rust/$P
mkdir -p "$L" /tmp/ren-bench
SUM=$NL/results/cloud/bugs-rust/summary.tsv
LOCK=(flock -s /tmp/ren-bench/lock env REN_FLOCKED=1)
TIMEBOX=${TIMEBOX:-120}   # libFuzzer seconds
MIRI_TMO=${MIRI_TMO:-570}

step() {   # name cmd...
  local name=$1; shift
  local t0 t1 rc
  t0=$(date +%s.%N)
  "${LOCK[@]}" "$@" >"$L/$name.log" 2>&1; rc=$?
  t1=$(date +%s.%N)
  local s; s=$(printf '%.1f' "$(echo "$t1 - $t0" | bc)")
  printf '%s\t%s\t%s\t%s\n' "$P" "$name" "$rc" "$s" >>"$SUM"
  printf '%-22s rc=%-3s %6ss  %s\n' "$name" "$rc" "$s" "$(grep -m1 -E 'panicked|ERROR: AddressSanitizer|WARNING: ThreadSanitizer|Undefined Behavior|error(\[|:)|FAIL |summary|test result' "$L/$name.log" | cut -c1-150)"
}

# ---- compile ----
s_build() { for p in release debug release-nostd tsan; do step "build-$p" "$NL/build.sh" rust "$p" $plant; done; }
# ASan+UBSan on the harness C (and libFuzzer), over the Rust release core:
# ASan's malloc/free interposition sees the Rust core's frees (std's System
# allocator and the no_std GlobalAlloc both call libc malloc/free).
s_asanh() { step build-asanh bash -c '
  set -e; B=$0/bin/rust-asanh$1; mkdir -p $B; cd $2
  libs="$0/build/rust-release$1/libren_core.a $(cat $0/build/rust-release$1/link.flags) -lpthread -lm"
  fl="-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -std=gnu11 -D_GNU_SOURCE -I$2"
  WL="rt.c workloads/wl_common.c workloads/w1_spawn.c workloads/w2_switch.c workloads/w3_rtt.c workloads/t_io.c workloads/w_fuzz.c"
  clang $fl host_main.c $WL $libs -o $B/harness
  clang $fl tests/abi_test.c rt.c $libs -o $B/abi_test
  clang $fl tests/deque_stress.c rt.c $libs -o $B/deque_stress
  clang $fl tests/layout_check.c rt.c $libs -o $B/layout_check
  clang $fl fuzz/fuzz_run.c fuzz/fuzz_common.c $WL $libs -o $B/fuzz_run
  clang $fl tests/jdump.c -o $B/jdump
  clang -O1 -g -fsanitize=fuzzer,address,undefined -D_GNU_SOURCE -I$2 fuzz/fuzz_target.c fuzz/fuzz_common.c $WL $libs -o $B/fuzz
  echo built $B' "$NL" "$sfx" "$H"; }
s_clippy() { step clippy env CARGO_TARGET_DIR="$here/target/clippy$sfx" cargo clippy --manifest-path "$here/Cargo.toml" -p ren_core "${feat[@]}" -- -W clippy::all; }

# ---- tests ----
T() { env WORKERS="1 4 8" DRIVERS="epoll uring" TMO="${2:-${TMO_T:-20}}" "$H/test.sh" "$NL/bin/$1"; }
s_tests() {
  local t
  for t in ${TESTS:-release debug nostd asanh tsan}; do
    case $t in
      release) step tests-release bash -c 'T "$@"' T "rust-release$sfx" ;;
      debug) step tests-debug bash -c 'T "$@"' T "rust-debug$sfx" ;;
      nostd) step tests-nostd bash -c 'T "$@"' T "rust-release-nostd$sfx" ;;
      asanh) step tests-asanh bash -c 'T "$@"' T "rust-asanh$sfx" ;;
      tsan) step tests-tsan bash -c 'T "$@"' T "rust-tsan$sfx" "${TMO_TSAN:-60}" ;;
    esac
  done
}
export -f T; export H NL
s_tsan_w1() { step tsan-w1x4 env TSAN_OPTIONS=halt_on_error=0 timeout 200 "$NL/bin/rust-tsan$sfx/harness" w1 --driver epoll --workers 4 --n 200000; }
s_tsan_deque() { step tsan-deque timeout 300 "$NL/bin/rust-tsan$sfx/deque_stress" stress 10 200000; }
s_dq50() { step deque-stress-x50 bash -c 'for i in $(seq 50); do timeout 60 $0/deque_stress stress 10 200000 || { echo "run $i failed"; exit 1; }; done; echo "50/50 ok"' "$NL/bin/rust-release$sfx"; }
s_dq50d() { step deque-stress-debug-x20 bash -c 'for i in $(seq 20); do timeout 60 $0/deque_stress stress 10 200000 || { echo "run $i failed"; exit 1; }; done; echo "20/20 ok"' "$NL/bin/rust-debug$sfx"; }

# ---- Rust-only ----
s_cargo_test() { step cargo-test env CARGO_TARGET_DIR="$here/target/test$sfx" cargo test --manifest-path "$here/Cargo.toml" -p ren_core "${feat[@]}"; }
s_miri() { step miri env CARGO_TARGET_DIR="$here/target/miri$sfx" MIRIFLAGS="-Zmiri-disable-isolation" timeout "$MIRI_TMO" cargo +nightly miri test --manifest-path "$here/Cargo.toml" -p ren_core "${feat[@]}"; }
s_miri_many() { step miri-many-seeds env CARGO_TARGET_DIR="$here/target/miri$sfx" MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-many-seeds=0..16" timeout "$MIRI_TMO" cargo +nightly miri test --manifest-path "$here/Cargo.toml" -p ren_core "${feat[@]}" --lib deque; }
s_loom() { step loom env CARGO_TARGET_DIR="$here/target/loom$sfx" RUSTFLAGS="--cfg loom" timeout 570 cargo test --manifest-path "$here/Cargo.toml" -p ren_core --release --test loom_deque "${feat[@]}"; }

# ---- fuzz ----
s_fuzz() {
  step fuzz-run-release timeout 300 "$NL/bin/rust-release$sfx/fuzz_run" --random 3000 1
  step fuzz-run-debug timeout 300 "$NL/bin/rust-debug$sfx/fuzz_run" --random 3000 1
  step fuzz-regress timeout 60 "$NL/bin/rust-release$sfx/fuzz_run" "$here"/fuzz/*.bin
  step libfuzzer-asanh timeout $((TIMEBOX + 60)) "$NL/bin/rust-asanh$sfx/fuzz" -max_total_time="$TIMEBOX" -seed=1 -max_len=4096 -print_final_stats=1 -artifact_prefix="$L/"
}

steps=("$@"); [ ${#steps[@]} -gt 0 ] || steps=(build asanh clippy cargo_test tests tsan_w1 tsan_deque dq50 dq50d loom miri fuzz)
for s in "${steps[@]}"; do "s_$s"; done

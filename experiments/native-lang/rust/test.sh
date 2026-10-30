#!/usr/bin/env bash
# rust/test.sh: the Rust entry's own checks (the shared suites are
# harness/test.sh bin/rust-<profile>). Runs under the SHARED lock.
#   cargo test     deque unit tests + tests/optable.rs (pure Rust, no harness C)
#   miri           the same under Miri (nightly; Stacked Borrows + data races + leaks)
#   loom           tests/loom_deque.rs (RUSTFLAGS=--cfg loom)
#   fuzz-regress   fuzz/*.bin through bin/rust-release/fuzz_run
#   unsafe         tools/count_unsafe.py (lines inside unsafe blocks / unsafe fns)
set -uo pipefail
if [ -z "${REN_FLOCKED:-}" ]; then
  mkdir -p /tmp/ren-bench
  export REN_FLOCKED=1
  exec flock -s /tmp/ren-bench/lock "$0" "$@"
fi
here=$(cd "$(dirname "$0")" && pwd)
export REN_HARNESS=${REN_HARNESS:-$here/../harness}
steps=("$@"); [ ${#steps[@]} -gt 0 ] || steps=(cargo-test miri loom fuzz-regress unsafe)
fail=0
for s in "${steps[@]}"; do
  echo "== $s"
  case "$s" in
    cargo-test) CARGO_TARGET_DIR=$here/target/test cargo test --manifest-path "$here/Cargo.toml" -p ren_core 2>&1 | grep -E "^test |test result|error" || fail=1 ;;
    miri) CARGO_TARGET_DIR=$here/target/miri cargo +nightly miri test --manifest-path "$here/Cargo.toml" -p ren_core 2>&1 \
            | grep -E "^test |test result|^error|Undefined Behavior|data race" || fail=1 ;;
    loom) CARGO_TARGET_DIR=$here/target/loom RUSTFLAGS="--cfg loom" cargo test --manifest-path "$here/Cargo.toml" \
            -p ren_core --release --test loom_deque 2>&1 | grep -E "^test |test result|error|panicked" || fail=1 ;;
    fuzz-regress) "$here/../bin/rust-release/fuzz_run" "$here"/fuzz/*.bin || fail=1 ;;
    unsafe) python3 -I "$here/tools/count_unsafe.py" ;;
    *) echo "unknown step $s"; exit 2 ;;
  esac
done
[ "$fail" -eq 0 ]

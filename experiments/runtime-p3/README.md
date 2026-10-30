# runtime-p3 (Phase C): INCOMPLETE

Machine: `cloud` (experiments/MACHINE-cloud.md).

Phase C stopped at its first step: the workflow's agents hit the account's
spend limit on 2026-10-30. What is here:

- `core/`: the Phase B C slice (experiments/native-lang/c and harness)
  copied into a self-contained unit, with `include/ren_e1.h` (test hooks
  and stats, not ABI). The E1 additions in research/runtime/SYNTHESIS.md §5
  (drain asserts, double-run digest, forced reply/cancel race replay, two
  cores in one process) are **not** done, and `core/build.sh` is unverified.
- `core/results/cloud/lostwake-phaseB-c-release.txt`: 1,000 runs per cell
  of W1, W2, W3, t_cancel and t_timer at 4 and 8 workers, on epoll and on
  io_uring, against Phase B's C release core. **No hangs in 20,000 runs.**
  3 t_timer failures (all epoll), the same t_timer flakiness Phase B
  measured in every core. So the lost-wake hang Phase B saw in the Rust
  and Zig cores does not reproduce in the C core here.
- No E2-E9 work exists yet. No SYNTHESIS.md.

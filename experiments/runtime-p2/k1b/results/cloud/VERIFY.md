# K1b independent verification: machine=cloud

Machine: **cloud** (experiments/MACHINE-cloud.md): 4 vCPU KVM Intel Xeon @ 2.10 GHz, no SMT, kernel 6.18.44-fc-v185.
Date: 2026-10-30. Checker: an independent verification agent. Claims checked: the cloud run `results/cloud/{sim,parts}-20261030-063029.txt`.
I did not use the other agent's logs, its SUMMARY.md, or its `bin/` binaries.

## Method

- **Rebuilt from source** under `flock -s`, into a separate directory, `k1b/build-verify/bin/` (git-ignored by the `bin/` rule):
  `clang -O2 -Wall -Wextra c/sim.c -lm` -> `sim_c`; `gcc -O2 c/sim.c -lm` -> `sim_c_gcc` (a second compiler, as a cross-check);
  `cargo build --release --target-dir ../build-verify/target` -> `sim_rust`. (The clang `sim_c` is byte-identical to the
  other agent's `bin/sim_c`, which is expected for a deterministic build of the same source.)
- **Did not run `measure-cloud.sh` itself**, because it runs `build.sh` first, and that would overwrite the other agent's `bin/`.
  My runner (`build-verify/bin/verify.sh`) runs exactly the same configurations as `sec_sim` and `sec_parts`, which are
  4 dists x 2 max x U {1.25,2,4,10} x {C,Rust} and 4 dists x 2 max x parts {1,8,64} at U=2.
  It runs **each configuration as its own `flock -x /tmp/ren-bench/lock` acquisition** (the original script uses `-s` for
  these deterministic sections) and reads the 1-minute load from /proc/loadavg at the start and end of each one.
  It does **7 full repetitions** of both sections. Raw lines are in `build-verify/bin/raw/`.
- **Wrote my own checker** (`build-verify/bin/analyze.py`) instead of reusing `check_sim` and `check_parts`. It parses every
  key=value field except lang, load and wall time, and compares the full tuples: C vs Rust, mine vs macOS
  `results/sim-20261029-210431.txt`, and mine vs the other agent's cloud file.
- **Extra check, beyond the claim:** the parts invariance at every universe (1.25, 2, 4, 10) and at parts 1, 2, 8, 32 and 64
  (32 cases, 160 runs), plus the gcc build of the simulator at the default parts.
- Load1 across all of my configurations ran from 0.50 to 1.08.

## Results

These outputs are deterministic, so I report "spread" as the number of distinct outputs per configuration across the 7 reps.
It was **1 for every configuration**: the spread is 0, and no configuration was NOISY.
Wall time is not part of either claim. For the record, one full sim section took a median of 67.9 s (min 66.8, max 77.2) per rep.

| Check | Result (7 reps) |
|---|---|
| C == Rust, all fields, per rep | 32/32 in each of the 7 reps |
| my C vs macOS C (sim-20261029-210431.txt) | 32/32 identical |
| my Rust vs macOS Rust | 32/32 identical |
| my C vs the other agent's cloud C | 32/32 identical |
| gcc-built C vs clang-built C | 32/32 identical |
| parts at U=2, parts 1/8/64: vh_s3/s5/s10/clock (and lru) unchanged, vh_plru changes | 8/8 cases, every rep; vh_plru takes 3 distinct values in every case |
| parts-ext at U 1.25/2/4/10, parts 1/2/8/32/64 | 32/32 cases ok; vh_plru takes 5 distinct values in every case; hits_* of the non-plru policies are also unchanged |
| zipf99 max=10000 U=2 | lru 90.10%, plru +0.00, s3 -0.70, s5 -0.31, s10 -0.09, clock -0.42 (the claim gives exactly these) |

## Verdicts

1. **Parts fingerprint holds on cloud (PLAN 16): confirmed.** 8/8 ok in all 7 reps, and the extension to every universe and
   to parts 2 and 32 also holds (32/32).
2. **Sim hit rates are bit-identical to macOS, and C = Rust: confirmed.** 32/32 for C and 32/32 for Rust, with both clang and gcc.

## Caveats (I tried to refute; none of these overturns a verdict)

- **Wording in claim 2.** It says "hit rate under real eviction". These are hit rates from the single-threaded,
  deterministic **simulator** (`c/sim.c`). It is not the threaded harness (`k1b.c`), which never reports hit rates in this claim.
  The equality with macOS shows that the simulator is portable (same libm pow() results, same integer math). It says nothing about
  whether concurrent eviction in k1b.c gets the same hit rates.
- **The parts invariance holds by construction.** In sim.c, the victim of s*/clock depends only on the slab (stamp[],
  key[], the rng and the hand), and "full" is `nalloc >= max`, which does not depend on the shard. So the check can only fail
  through a shard-table bug, such as a lookup miss or a wrong delete. It is a real consistency test of the table code, but it is
  a weak test of the *policy* claim. It also covers only the simulator, not k1b.c's variant b/c.
- **The default parts does not match PLAN.** PLAN.md (line 144) and measure-cloud.sh ("Parts at the derived default") say
  parts = default_parts(max), which is 8 and 32. But sim.c and sim.rs hard-code `parts = 8`, and every sim line, on both
  macOS and cloud, says `parts=8`, including max=50000. Only the **plru** column at max=50000 is affected (it is simulated
  with 8 partitions, not 32). The other policies don't depend on parts (verified above). Both machines have the same
  discrepancy, so the cloud-vs-macOS identity still holds. The analysis.txt plru column for max=50000 does not test what
  PLAN 15 describes.
- **The parts section uses only U=2.** PLAN 16 says "every workload", and the claim's "8 dist x max cases" covers only U=2.
  My parts-ext run fills the gap (all 4 universes): it holds.
- "vh_plru changes in every case" is true across parts 1/8/64. At parts=1, plru is identical to lru, as expected.

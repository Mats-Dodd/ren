# switch: independent verification on machine: cloud (2026-10-30)

Machine: **cloud** (claude.ai cloud container, `experiments/MACHINE-cloud.md`):
4 vCPUs, KVM, Intel Xeon @ 2.10 GHz, no SMT, Linux 6.18.44. clang 18.1.3,
go 1.24.7, rustc 1.97.0 (tokio from the same Cargo.lock). GOMAXPROCS=1 in every
Go process (all 56 Go process lines print `gomaxprocs=1`).

I did not reuse the first agent's binaries or logs. I copied the sources
(`c/ go/ rust/{Cargo.toml,Cargo.lock,src} tools/ build.sh measure*.sh`) into a
separate tree (`diff -r` showed they matched the working tree). I rebuilt from clean
there with `flock -s /tmp/ren-bench/lock env CLEAN=1 ./build.sh` and ran
`flock -s ... ./measure.sh --check`, which passed (ALL CHECKS ok, ASan/UBSan included).
That tree's copy of `measure-cloud.sh` has one change: `SKIPBUILD=1` skips its
rebuild-from-clean step. Without it, each of the 16 invocations would have
rebuilt cargo and Go. Nothing else in the script changed. The tree was in the
session scratchpad, so it is not in the repo. Its driver is copied to
`verify/run-verify.sh`.

Each claim's command ran as given, with `RESDIR=results/cloud/verify`. Every
configuration ran inside its own `flock -x /tmp/ren-bench/lock`. One
configuration is 7 separate processes. Each process runs the in-process reps
(7, or 63 for fanout) and reports its own median. The configuration reports the
median, min and max of those 7 process medians. If spread was above 10%, it was
retried in a new lock acquisition, up to 3 tries in all. Raw files, with every
process's `reps_ns` and a `LOAD` line (load1 at start/end from
`/proc/loadavg`, steal ticks) for every try, are in `verify/`. No `.err` output.
No check failed.

Load: load1 at configuration start/end was 1.51 .. 6.22 over all tries. Another
agent's percore verification was taking `flock -x` on the same lock *between* my
configurations (seen in `/proc/locks` / `ps`), so it never ran inside one of
them. load1 lags by about a minute, so it reflects that agent's work before my
lock.

## Source review (does each benchmark measure what the claim says?)

What I checked, with no bug found that invalidates a number:

- **Timing**: every binary takes `now()` around the whole workload of one rep:
  CLOCK_MONOTONIC in C, `time.Now` in Go, `Instant` in Rust. Units are ns
  divided by the op count the claim names: round trips for pingpong, spawns
  for spawn_*, woken tasks for park (wake window only), and 10·n ops for
  fanout.
- **Dead code**: the timed work cannot be eliminated. Every result
  (sums, counters, gate counts) is compared against a closed-form value, and a
  mismatch prints `check=FAIL`.
- **Medians**: C `qsort`, Go `sort.Float64s` and Rust `sort_by` compute the
  in-process median correctly. The script's awk computes the cross-process
  median with insertion sort, and computes min/max before sorting. Spread is
  `(max-min)/median` over process medians.
- **Concurrency**: none intended. All four runtimes are single-threaded by
  design: GOMAXPROCS=1, tokio `current_thread` + LocalSet, and the C runtimes
  use no threads.
- **Warm-up**: there is none. The first in-process rep is cold and is included,
  so a median of 7 (or 63) is what keeps it from dominating.

Caveats that change how a number should be read:

1. **fanout_yield per op is not a pure switch.** In both ren_c and raw_c, each
   rep spawns 1000 tasks and then does 10,000 add+yield ops. The 1000 spawns
   are inside the timer, so each "op" carries 0.1 of a spawn. "One add plus one
   yield" understates what is timed. The ren_c/raw_c comparison is still fair,
   because both carry the spawn.
2. **The Rust counting `#[global_allocator]`** does two relaxed atomic RMWs
   (`lock xadd`) on every alloc and dealloc. This affects every tokio
   number that allocates (spawn_join, spawn_batch, park) by a few ns per
   allocation, compared with a stock tokio build.
3. **The retry rule keeps the try with the smallest spread.** This favours
   lucky tries. Claim 8 (park_raw_c) shows the effect: a configuration that was
   NOISY in 11 of the 12 tries we ran between us (their 3 unpinned and 3 pinned,
   my 6 pinned) was reported as a clean headline, because one of their tries passed.
4. Go park "wake" includes `wg.Wait()` and a `sync.Mutex` lock/unlock per task,
   not only the wake. The memory figure from `runtime.MemStats` (2660 B/task)
   is 3.3x smaller than the peak-RSS delta (8876 B/task, reproduced). Neither
   is a headline here.

## Verdicts

Each verdict compares my median with the claimed median ("Δ"). Confirmed means
within 10% and the configuration's NOISY / non-NOISY status reproduced.

| # | claim | claimed | my re-run: median [min..max], spread, tries | Δ | verdict |
|---|---|---|---|---|---|
| 1 | Go pingpong RT, unpinned | 388.05 [378.75..412.40] 8.7% | 379.51 [374.83..410.92] 9.5%, 2 tries | −2.2% | confirmed |
| 1 | Go pingpong RT, pinned cpu3 | 398.52 [378.79..409.63] | 400.15 [378.16..409.90] 7.9%, 3 tries | +0.4% | confirmed |
| 2 | tokio pingpong RT, unpinned | 401.33 [378.32..416.33] 9.5% | 402.11 [387.49..416.20] 7.1%, 1 try | +0.2% | confirmed |
| 2 | tokio pingpong RT, pinned | 385.08 [368.57..405.98] | 384.78 [377.08..410.30] 8.6%, 3 tries | −0.1% | confirmed |
| 3 | tokio pingpong_local RT, pinned | 194.63 [184.85..204.18] 9.9% | 197.27 [194.74..205.33] 5.4%, 2 tries | +1.4% | confirmed |
| 4 | Go spawn+join, unpinned | 485.60 [460.58..497.95] 7.7% | 444.03 [433.80..459.40] 5.8%, 1 try | −8.6% | confirmed (but ranges do not overlap, see below) |
| 4 | Go spawn+join, pinned | 465.96 [456.82..485.26] | 436.36 [417.49..447.74] 6.9%, 1 try | −6.4% | confirmed (ranges do not overlap) |
| 5 | tokio spawn_batch m64 / task, unpinned | 204.49 [200.69..216.00] 7.5% | 207.55 [201.90..222.20] 9.8%, 3 tries | +1.5% | confirmed |
| 6 | ren_c fanout_yield / op, pinned | 5.22 [5.15..5.49] 6.5% | 5.16 [4.88..5.23] 6.8%, 1 try | −1.1% | confirmed (caveat 1) |
| 7 | raw_c fanout_yield / op, pinned | 3.26 [3.24..3.52] 8.6% | 3.24 [3.24..3.31] 2.2%, 3 tries | −0.6% | confirmed (caveat 1) |
| 8 | raw_c park wake / task, pinned | 7.01 [6.73..7.39] 9.4% | **NOISY twice**: 8.54 [7.38..9.09] 20.0% (3 tries) and 8.04 [6.50..8.34] 22.9% (3 tries). Medians of the six tries: 6.76, 8.54, 7.25, 7.39, 8.04, 8.04; spreads 20–36% | +15..22% on the kept try | **disagrees** |
| 9 | Go park wake / task, pinned | 836.74 [809.88..860.73] 6.1% | 810.61 [778.99..821.97] 5.3%, 1 try | −3.1% | confirmed |
| 10 | ren_c parked task size | 128 B alloc, 128.5 B RSS/n | 128.0 B (bytes_per_task), 128.5 B (ext_rss_per_task), 128.7 B in-process RSS delta | 0% | confirmed |
| 11 | (not headline) ren_c pingpong RT | 18.12 28% NOISY / 17.06 52% NOISY | unpinned 16.38 [16.09..18.35] 13.8% NOISY; pinned 16.36 [16.15..17.29] 7.0% (passed on try 3) | −10% / −4% | within-noise |
| 12 | (not headline) ren_c spawn_join; spawn_batch m64 | 13.59 40% / 8.57 17%, both NOISY | spawn_join 15.46 [12.77..18.38] 36% NOISY; spawn_batch m64 8.53 [8.42..9.33] 10.7% NOISY | +14% / −0.5% | within-noise |
| 13 | (not headline) ren_c park wake; spawn+park | 11.12 21% NOISY; spawn+park 23.7 | unpinned 9.94 [9.79..10.49] 7.0% (passed); pinned 9.51 [8.87..9.98] 11.7% NOISY; spawn+park 22.0 | −11% | within-noise |
| 14 | (not headline) raw_c pingpong RT; ren_c/raw_c = 2.32x | 7.81 46% / 7.32 21%, NOISY | unpinned 7.32 [6.71..9.49] 38% NOISY; pinned 7.22 [5.83..7.80] 27% NOISY | −6% / −1% | within-noise; ratio 2.24x unpinned, 2.27x pinned, still under the 3x falsifier |

### Where I disagree, or where something should be flagged

- **Claim 8 (raw_c park wake = 7.01 ns, a "clean" headline): disagrees.** Across
  two invocations, six tries, all under `flock -x`, it never came under 10%
  spread (20.0% to 35.9%). The medians of the individual tries ranged from 6.76
  to 8.54 ns. The first agent's own unpinned run was NOISY as well (7.96, 23%).
  Their pinned value passed only on the third of three tries (caveat 3). The
  honest status is NOISY, so this should not be used as a headline. The
  conclusion "ABOVE PLAN's 2–5 ns" survives: every try I ran is above 5 ns.
- **Claim 4 (Go spawn+join): within 10%, but systematically lower.** My
  medians are 6–9% below theirs, and my max is below their min, both unpinned
  (459.40 < 460.58) and pinned (447.74 < 456.82). The verdict is confirmed under
  the 10% rule, but the claimed number is high relative to this rebuild. I did
  not find a cause. The binaries came from the same source, toolchain and flags.
- **The NOISY classification of ren_c configs is not stable in either
  direction.** pingpong_ren_c pinned and park_ren_c unpinned each passed the
  10% rule once in my runs, where the first agent's were NOISY. park_ren_c
  pinned was NOISY in my run. Keeping all of them out of the headlines remains
  right. Their medians agree with the claimed ones within about 10%, which is
  why those rows are within-noise.
- PLAN comparisons that still hold: Go park (811 ns) and raw_c park (> 5 ns)
  are both ABOVE PLAN. Go/tokio pingpong (~380–400 ns) are above PLAN's
  150–300. tokio pingpong_local (~197 ns) is above PLAN's 80–160. ren_c parked
  task is 128 B, equal to the prediction and under the 256 B falsifier.

## Files

- `verify/measure-*.txt`, `verify/measure-pin3-*.txt`: my raw runs (each
  header says machine: cloud), `.cmds` for every lock acquisition, `.err` (all empty).
- `verify/run-verify.sh`: the driver (the claim commands in order, with
  `SKIPBUILD=1` and `RESDIR` set).

# switch on machine: cloud — summary of the full measurement (2026-10-30)

Machine: **cloud** (claude.ai cloud container, `experiments/MACHINE-cloud.md`):
4 vCPUs, KVM, Intel Xeon @ 2.10 GHz, no SMT, Linux 6.18.44. Toolchains: clang
18.1.3 (ren_c, raw_c at -O2), go 1.24.7, rustc 1.97.0 with tokio 1.53.3; the
ASan/UBSan check builds use gcc 13. All 30 configurations ran with GOMAXPROCS=1.

Files (all in this directory):

| file | what it is |
|---|---|
| `measure-20261030-103435.txt` | **run U**: the full run, unpinned (as on macOS). 30 configs |
| `measure-pin3-20261030-111939.txt` | **run P**: the full run again, every process under `taskset -c 3`. 30 configs |
| `measure-pin0-…105754`, `-pin1-…110020`, `-pin2-…110618` | probes: pingpong ren_c/raw_c and park ren_c pinned to cpu 0, 1, 2 |
| `measure-pin3-20261030-110744.txt` | the same probe on cpu 3, **truncated**: I edited measure-cloud.sh while it ran, so it has pingpong ren_c/raw_c only, no park_ren_c and no report. The two configs it has are complete |
| `measure-noaslr-20261030-111829.txt` | probe: 5 configs unpinned with ASLR off (`setarch -R`) |
| `*.cmds` / `*.err` | every command, in order / stderr (all empty) |

Procedure. Each invocation of measure-cloud.sh first rebuilt from clean (`CLEAN=1
./build.sh`) and ran `measure.sh --check` (ASan/UBSan included: **ALL CHECKS ok**),
both under `flock -s /tmp/ren-bench/lock`. Each configuration then ran inside one
`flock -x /tmp/ren-bench/lock` acquisition: 7 separate processes, each running
the binary's in-process reps (7; fanout 63) and printing its in-process median.
The configuration's median, min and max are taken over those 7 process medians.
Spread = (max-min)/median. Above 10% the configuration was re-run in a new lock
acquisition, up to 2 more times. The try with the smallest spread is kept; if it
is still above 10% the configuration is NOISY. Every try is in the file. No
check failed in any run.

## Load records

Every configuration try has a `LOAD` line in its file with the 1-minute load
(`/proc/loadavg`) at its start and end, `/proc/stat` steal ticks and seconds.

| run | load1 at script start / end | load1 over all config tries (min..max) | max steal ticks in one try |
|---|---|---|---|
| U (unpinned) | 3.06 / 3.75 | 1.07 .. 5.86 | 70 (a 20 s Go config) |
| P (pinned cpu 3) | 1.03 / 1.00 | 1.00 .. 1.02 | 47 (a 20 s Go config) |
| pin0 / pin1 / pin2 probes | 2.04/2.31, 1.89/5.48, 5.08/5.54 | 1.81 .. 6.57 | 6 |
| noaslr probe | 1.00 / 1.07 | 1.00 .. 1.08 | 4 |

The high load1 values in run U and the probes come from another agent's percore
benchmark (8 workers). It took `flock -x` on the same lock between our
configurations (checked with `/proc/locks` and `ps`), so it never ran during one
of ours. load1 is a lagging 1-minute average, so it shows that agent's work
from just before our lock. In run P that agent was idle: load1 was 1.00, which
is our own benchmark process.

## Every configuration

`ns` is ns per op as PLAN.md defines it: per round trip for pingpong, per
spawn+join or task for spawn, wake ns per task for park (`extra_ns` =
spawn+park ns per task), per op for fanout (`extra_ns` = per task). The last
column is the median of every process from every try (7 times tries). It is for
information only; the median column is the reported value.

### Run U — unpinned (`./measure-cloud.sh`)

| config | median [min..max] ns | spread | tries | NOISY | extra_ns med | load1 start/end | pooled median of all procs (n) |
|---|---|---|---|---|---|---|---|
| pingpong_ren_c | 18.12 [13.78..18.92] | 28.4% | 3 (used 3) | NOISY | 0.00 | 3.41/3.41 | 18.06 (21) |
| pingpong_raw_c | 7.81 [7.25..10.84] | 46.0% | 3 (used 2) | NOISY | 7.81 | 3.59/3.62 | 7.79 (21) |
| pingpong_switch_go | 388.05 [378.75..412.40] | 8.7% | 1 (used 1) |  | 388.05 | 3.04/2.46 | 388.05 (7) |
| pingpong_switch_rust | 401.33 [378.32..416.33] | 9.5% | 3 (used 3) |  | 401.33 | 1.69/1.49 | 401.33 (21) |
| pingpong_nested_ren_c | 31.08 [27.67..37.46] | 31.5% | 3 (used 2) | NOISY | 0.00 | 1.45/1.41 | 28.76 (21) |
| pingpong_local_switch_rust | 218.14 [206.12..231.86] | 11.8% | 3 (used 2) | NOISY | 218.14 | 1.32/1.25 | 209.73 (21) |
| spawn_join_ren_c | 13.59 [12.74..18.18] | 40.0% | 3 (used 2) | NOISY | 0.00 | 1.19/1.19 | 13.59 (21) |
| spawn_join_raw_c | 6.68 [6.60..7.33] | 10.9% | 3 (used 3) | NOISY | 6.68 | 1.36/1.36 | 6.77 (21) |
| spawn_join_switch_go | 485.60 [460.58..497.95] | 7.7% | 2 (used 2) |  | 485.60 | 1.19/1.14 | 480.57 (14) |
| spawn_join_switch_rust | 309.06 [285.02..320.57] | 11.5% | 3 (used 3) | NOISY | 309.06 | 1.14/1.11 | 307.19 (21) |
| spawn_batch_m64_ren_c | 8.57 [7.90..9.38] | 17.3% | 3 (used 2) | NOISY | 0.00 | 1.23/1.23 | 9.38 (21) |
| spawn_batch_m64_raw_c | 6.90 [5.74..7.03] | 18.7% | 3 (used 3) | NOISY | 6.90 | 2.13/2.13 | 5.91 (21) |
| spawn_batch_m64_switch_go | 415.23 [410.27..432.45] | 5.3% | 2 (used 2) |  | 415.23 | 1.92/1.66 | 420.58 (14) |
| spawn_batch_m64_switch_rust | 204.49 [200.69..216.00] | 7.5% | 3 (used 3) |  | 204.49 | 4.44/3.91 | 206.25 (21) |
| spawn_batch_m1000_ren_c | 9.88 [9.28..15.17] | 59.6% | 3 (used 1) | NOISY | 0.00 | 4.40/4.40 | 10.83 (21) |
| spawn_batch_m1000_raw_c | 6.15 [5.90..6.86] | 15.6% | 3 (used 3) | NOISY | 6.15 | 5.44/5.44 | 6.11 (21) |
| spawn_batch_m1000_switch_go | 450.37 [421.20..476.10] | 12.2% | 3 (used 3) | NOISY | 450.37 | 2.77/2.27 | 465.13 (21) |
| spawn_batch_m1000_switch_rust | 220.61 [195.34..232.99] | 17.1% | 3 (used 3) | NOISY | 220.61 | 1.71/1.60 | 228.12 (21) |
| park_ren_c | 11.12 [10.36..12.69] | 21.0% | 3 (used 2) | NOISY | 23.70 | 1.55/1.55 | 10.58 (21) |
| park_raw_c | 7.96 [6.63..8.47] | 23.1% | 3 (used 3) | NOISY | 7.23 | 1.51/1.51 | 7.96 (21) |
| park_switch_go | 990.61 [917.31..1063.18] | 14.7% | 3 (used 2) | NOISY | 1830.08 | 1.36/1.26 | 917.33 (21) |
| park_switch_rust | 218.85 [190.50..264.55] | 33.8% | 3 (used 1) | NOISY | 348.90 | 1.38/1.35 | 208.88 (21) |
| fanout_ren_c | 2.44 [2.43..2.78] | 14.3% | 3 (used 1) | NOISY | 24.37 | 1.43/1.43 | 2.44 (21) |
| fanout_raw_c | 0.48 [0.48..0.55] | 14.6% | 3 (used 3) | NOISY | 4.78 | 1.72/1.72 | 0.48 (21) |
| fanout_switch_go | 58.11 [50.38..67.70] | 29.8% | 3 (used 1) | NOISY | 581.15 | 1.83/1.83 | 53.39 (21) |
| fanout_switch_rust | 25.42 [17.56..27.12] | 37.6% | 3 (used 3) | NOISY | 254.24 | 2.08/2.08 | 18.58 (21) |
| fanout_yield_ren_c | 5.75 [5.14..6.99] | 32.2% | 3 (used 2) | NOISY | 57.52 | 5.16/5.16 | 5.30 (21) |
| fanout_yield_raw_c | 3.24 [3.05..3.79] | 22.8% | 3 (used 3) | NOISY | 32.41 | 4.84/4.84 | 3.24 (21) |
| fanout_yield_switch_go | 208.80 [189.40..268.29] | 37.8% | 3 (used 2) | NOISY | 2088.04 | 4.53/4.53 | 208.80 (21) |
| fanout_yield_switch_rust | 103.57 [79.37..115.52] | 34.9% | 3 (used 2) | NOISY | 1035.74 | 3.99/3.99 | 82.61 (21) |

### Run P — pinned to cpu 3 (`PIN=3 ./measure-cloud.sh`)

| config | median [min..max] ns | spread | tries | NOISY | extra_ns med | load1 start/end | pooled median of all procs (n) |
|---|---|---|---|---|---|---|---|
| pingpong_ren_c | 17.06 [16.41..25.27] | 51.9% | 3 (used 3) | NOISY | 0.00 | 1.02/1.02 | 16.61 (21) |
| pingpong_raw_c | 7.32 [7.04..8.55] | 20.6% | 3 (used 1) | NOISY | 7.32 | 1.02/1.02 | 7.38 (21) |
| pingpong_switch_go | 398.52 [378.79..409.63] | 7.7% | 3 (used 3) |  | 398.52 | 1.01/1.01 | 394.48 (21) |
| pingpong_switch_rust | 385.08 [368.57..405.98] | 9.7% | 1 (used 1) |  | 385.08 | 1.01/1.00 | 385.08 (7) |
| pingpong_nested_ren_c | 27.30 [22.66..28.54] | 21.5% | 3 (used 3) | NOISY | 0.00 | 1.00/1.00 | 27.58 (21) |
| pingpong_local_switch_rust | 194.63 [184.85..204.18] | 9.9% | 1 (used 1) |  | 194.63 | 1.00/1.00 | 194.63 (7) |
| spawn_join_ren_c | 12.93 [12.85..17.90] | 39.1% | 3 (used 2) | NOISY | 0.00 | 1.00/1.00 | 13.73 (21) |
| spawn_join_raw_c | 6.66 [5.58..8.96] | 50.8% | 3 (used 2) | NOISY | 6.66 | 1.00/1.00 | 6.74 (21) |
| spawn_join_switch_go | 465.96 [456.82..485.26] | 6.1% | 2 (used 2) |  | 465.96 | 1.00/1.00 | 462.06 (14) |
| spawn_join_switch_rust | 295.89 [288.20..321.11] | 11.1% | 3 (used 1) | NOISY | 295.89 | 1.00/1.00 | 299.97 (21) |
| spawn_batch_m64_ren_c | 8.80 [8.44..9.47] | 11.7% | 3 (used 1) | NOISY | 0.00 | 1.00/1.00 | 9.47 (21) |
| spawn_batch_m64_raw_c | 5.81 [5.58..6.23] | 11.2% | 3 (used 3) | NOISY | 5.81 | 1.00/1.00 | 5.87 (21) |
| spawn_batch_m64_switch_go | 434.97 [427.36..470.36] | 9.9% | 1 (used 1) |  | 434.97 | 1.00/1.00 | 434.97 (7) |
| spawn_batch_m64_switch_rust | 214.02 [197.47..225.52] | 13.1% | 3 (used 2) | NOISY | 214.02 | 1.00/1.00 | 213.19 (21) |
| spawn_batch_m1000_ren_c | 10.09 [8.59..10.28] | 16.7% | 3 (used 3) | NOISY | 0.00 | 1.00/1.00 | 9.74 (21) |
| spawn_batch_m1000_raw_c | 6.01 [5.83..6.53] | 11.6% | 3 (used 3) | NOISY | 6.01 | 1.00/1.00 | 5.96 (21) |
| spawn_batch_m1000_switch_go | 456.38 [429.28..484.46] | 12.1% | 3 (used 2) | NOISY | 456.38 | 1.00/1.00 | 439.72 (21) |
| spawn_batch_m1000_switch_rust | 212.40 [207.23..216.97] | 4.6% | 1 (used 1) |  | 212.40 | 1.00/1.00 | 212.40 (7) |
| park_ren_c | 9.90 [8.80..11.91] | 31.4% | 3 (used 2) | NOISY | 23.00 | 1.00/1.00 | 9.90 (21) |
| park_raw_c | 7.01 [6.73..7.39] | 9.4% | 3 (used 3) |  | 7.11 | 1.00/1.00 | 7.21 (21) |
| park_switch_go | 836.74 [809.88..860.73] | 6.1% | 3 (used 3) |  | 1525.71 | 1.00/1.00 | 836.74 (21) |
| park_switch_rust | 183.35 [162.66..188.43] | 14.1% | 3 (used 2) | NOISY | 303.23 | 1.00/1.00 | 186.75 (21) |
| fanout_ren_c | 2.43 [2.17..2.44] | 11.1% | 3 (used 1) | NOISY | 24.35 | 1.00/1.00 | 2.46 (21) |
| fanout_raw_c | 0.48 [0.48..0.52] | 8.3% | 2 (used 2) |  | 4.77 | 1.00/1.00 | 0.48 (14) |
| fanout_switch_go | 73.82 [52.81..78.21] | 34.4% | 3 (used 3) | NOISY | 738.23 | 1.00/1.00 | 54.37 (21) |
| fanout_switch_rust | 18.59 [17.87..19.37] | 8.1% | 2 (used 2) |  | 185.93 | 1.00/1.00 | 18.30 (14) |
| fanout_yield_ren_c | 5.22 [5.15..5.49] | 6.5% | 1 (used 1) |  | 52.20 | 1.00/1.00 | 5.22 (7) |
| fanout_yield_raw_c | 3.26 [3.24..3.52] | 8.6% | 1 (used 1) |  | 32.63 | 1.00/1.00 | 3.26 (7) |
| fanout_yield_switch_go | 193.86 [163.77..254.62] | 46.9% | 3 (used 3) | NOISY | 1938.60 | 1.00/1.00 | 194.58 (21) |
| fanout_yield_switch_rust | 85.48 [79.54..103.29] | 27.8% | 3 (used 2) | NOISY | 854.84 | 1.00/1.00 | 81.95 (21) |

### Memory (park, n = 100k; the same in both runs)

| lang | bytes_per_task (allocator view) | ext_rss_per_task (peak RSS at n minus at n=1, over n) | PLAN bytes |
|---|---|---|---|
| ren_c | **128.0** | 128.5 | 128 |
| raw_c | 40.0 | 39.3 | 40 |
| Go | 2,660 | 8,876 | 2,500–3,500 |
| tokio | 266.5 | 394 | 250–350 |

bytes_per_task is deterministic: it doesn't vary between processes, so the
spread rule does not apply. ext_rss is peak resident set (`ru_maxrss`), not
macOS's phys_footprint. Go's RSS per parked goroutine is 3.3 times its
`StackInuse+HeapInuse` view.

## Headlines

Only configurations that are **not** NOISY are headlines. Each reproduction
command rebuilds from clean and checks under `flock -s`, then runs that config
(7 processes, up to 3 tries) under `flock -x`. It writes a new
`results/cloud/measure-*.txt` and prints the CFG line.

| claim | value: median [min..max] over 7 processes | spread | reproduce (from `experiments/runtime-p2/switch`) |
|---|---|---|---|
| Go, GOMAXPROCS=1, pingpong round trip (two switches) | **388.05 ns** [378.75..412.40] (U); 398.52 [378.79..409.63] (P) | 8.7% / 7.7% | `ONLY='^pingpong_switch_go$' ./measure-cloud.sh` |
| tokio current_thread, pingpong round trip | **401.33 ns** [378.32..416.33] (U); 385.08 [368.57..405.98] (P) | 9.5% / 9.7% | `ONLY='^pingpong_switch_rust$' ./measure-cloud.sh` |
| tokio current_thread, `!Send` one-slot channel pingpong | **194.63 ns** [184.85..204.18] (P) | 9.9% | `PIN=3 ONLY='^pingpong_local_switch_rust$' ./measure-cloud.sh` |
| Go spawn+join | **485.60 ns** [460.58..497.95] (U); 465.96 [456.82..485.26] (P) | 7.7% / 6.1% | `ONLY='^spawn_join_switch_go$' ./measure-cloud.sh` |
| Go spawn into scope max 64, a task | **415.23 ns** [410.27..432.45] (U); 434.97 [427.36..470.36] (P) | 5.3% / 9.9% | `ONLY='^spawn_batch_m64_switch_go$' ./measure-cloud.sh` |
| tokio spawn into scope max 64, a task | **204.49 ns** [200.69..216.00] (U) | 7.5% | `ONLY='^spawn_batch_m64_switch_rust$' ./measure-cloud.sh` |
| tokio spawn into scope max 1,000, a task | **212.40 ns** [207.23..216.97] (P) | 4.6% | `PIN=3 ONLY='^spawn_batch_m1000_switch_rust$' ./measure-cloud.sh` |
| ren_single, fanout_yield: one add + one `Async.yield()` switch, an op | **5.22 ns** [5.15..5.49] (P) | 6.5% | `PIN=3 ONLY='^fanout_yield_ren_c$' ./measure-cloud.sh` |
| raw C floor, fanout_yield, an op | **3.26 ns** [3.24..3.52] (P) | 8.6% | `PIN=3 ONLY='^fanout_yield_raw_c$' ./measure-cloud.sh` |
| raw C floor, park wake, a task | **7.01 ns** [6.73..7.39] (P); spawn+park 7.11 ns | 9.4% | `PIN=3 ONLY='^park_raw_c$' ./measure-cloud.sh` |
| raw C floor, fanout (no yield), an op | **0.48 ns** [0.48..0.52] (P) | 8.3% | `PIN=3 ONLY='^fanout_raw_c$' ./measure-cloud.sh` |
| Go park wake, a task (100k parked) | **836.74 ns** [809.88..860.73] (P); spawn+park 1,526 ns | 6.1% | `PIN=3 ONLY='^park_switch_go$' ./measure-cloud.sh` |
| tokio fanout, an op | **18.59 ns** [17.87..19.37] (P) | 8.1% | `PIN=3 ONLY='^fanout_switch_rust$' ./measure-cloud.sh` |
| ren_c parked task, bytes (falsifier: > 256 B) | **128 B** (allocator); 128.5 B by RSS | deterministic | `ONLY='^park_ren_c$' ./measure-cloud.sh` (`bytes_per_task`, `ext_rss_per_task` on the CFG line) |

### Required numbers that could NOT be headlines (NOISY in both full runs)

These are what the task asked for. Each was above 10% spread on all 3 tries in
both run U and run P. Per the rules they are **not headlines**. The values are
given so the reader knows where they sit.

| number | U: median [min..max], spread | P: median [min..max], spread | pooled median, U / P (21 processes each) |
|---|---|---|---|
| ren_single task switch: pingpong round trip (2 switches) | 18.12 [13.78..18.92], 28% | 17.06 [16.41..25.27], 52% | 18.06 / 16.61 |
| ren_single pingpong_nested | 31.08 [27.67..37.46], 31% | 27.30 [22.66..28.54], 22% | 28.76 / 27.58 |
| ren_single spawn+join | 13.59 [12.74..18.18], 40% | 12.93 [12.85..17.90], 39% | 13.59 / 13.73 |
| ren_single spawn, max 64, a task | 8.57 [7.90..9.38], 17% | 8.80 [8.44..9.47], 12% | 9.38 / 9.47 |
| ren_single spawn, max 1,000, a task | 9.88 [9.28..15.17], 60% | 10.09 [8.59..10.28], 17% | 10.83 / 9.74 |
| ren_single park wake, a task | 11.12 [10.36..12.69], 21% | 9.90 [8.80..11.91], 31% | 10.58 / 9.90 |
| ren_single spawn+park, a task | 23.70 | 23.00 | |
| raw C floor pingpong round trip | 7.81 [7.25..10.84], 46% | 7.32 [7.04..8.55], 21% | 7.79 / 7.38 |
| raw C floor spawn+join | 6.68 [6.60..7.33], 11% | 6.66 [5.58..8.96], 51% | 6.77 / 6.74 |
| Go fanout_yield, an op | 208.80 [189.40..268.29], 38% | 193.86 [163.77..254.62], 47% | |
| tokio park wake, a task | 218.85 [190.50..264.55], 34% | 183.35 [162.66..188.43], 14% | |

The diagnostic probes gave clean (spread ≤ 10%) results for some of these:
pingpong ren_c **16.32 [16.11..16.64]** (cpu 3, truncated probe, third try);
park ren_c wake **9.78 [9.61..10.07]** (ASLR off) and **9.83 [9.61..10.50]**
(cpu 2); spawn_batch max 1,000 ren_c **9.86 [9.61..10.12]** (ASLR off). They
sit at the pooled medians above. But they are clean tries chosen out of several
noisy ones. I report them as corroboration, not as headlines.

**What the noise is.** Within one process the in-process reps are tight (see
each line's `reps_ns=`). Between processes, most land in a tight cluster and
roughly one in seven is 25–70% slower for its whole life. For example,
pingpong ren_c ranges 14–26 ns per process, and raw_c sits at 7.3 ns with
outliers at 10–13 ns. This happened:
- on all four vCPUs when pinned: pinned medians 16.2–16.7 ns on cpu 0–3, spreads 13–43%;
- with ASLR off (spread 28%);
- in run P, when load1 was 1.00 and steal was negligible.

So it is not oversubscription, not migration between vCPUs, not virtual address
layout and not other agents. It is most likely host-side: physical page or
cache placement, or other tenants on the host. I could not pin it down further
without `perf`, which is not installed. It hits the short C configs hardest:
each of their processes runs for 10–60 ms.

## Oversubscription check (4 cores)

**No configuration here runs more than one runtime worker thread.** ren_c and
raw_c are single-threaded, Go runs at GOMAXPROCS=1 and tokio at current_thread.
Only Go's sysmon and GC helper threads exist besides that. So there is no "N
workers" axis, and no throughput collapse above 4 workers can occur or be
measured in this experiment. That question applies to the multi-worker
experiments (percore), not to switch.

What pinning shows, as the requested pinned comparison (run P vs run U, same
single thread):
- Pinned and unpinned medians agree within ±10% on 20 of 30 configs.
- Of the other 10, pinned is faster on 9, by 11–27%:
  - pingpong_nested ren_c 27.3 vs 31.1;
  - pingpong_local tokio 195 vs 218;
  - spawn_batch m64 raw_c 5.81 vs 6.90;
  - park ren_c 9.9 vs 11.1;
  - park raw_c 7.0 vs 8.0;
  - park Go 837 vs 991;
  - park tokio 183 vs 219;
  - fanout tokio 18.6 vs 25.4;
  - fanout_yield tokio 85 vs 104.
- Pinned is slower on one, fanout Go (73.8 vs 58.1). Both are NOISY; the pooled
  medians are 54.4 vs 53.4, so they are effectively the same.
- Run P was also the quieter run (load1 1.00 throughout), so pinning and the
  quieter host are confounded. The per-vCPU probes ran at higher load
  (load1 1.8–6.6). Their pingpong medians agree with each other within 3%
  across cpu 0–3 (ren_c 16.17–16.67, raw_c 7.30–7.61). Those are 8–11% (ren_c)
  and 3–7% (raw_c) under run U's 18.12 and 7.81.
- Pinning did **not** remove the NOISY flag from the ren_c / raw_c configs: 25
  configs were NOISY unpinned, 18 pinned.

## Against PLAN.md's predictions

PLAN.md's falsifiers: ren_c/raw_c pingpong = **2.32× (U) / 2.33× (P)** and park
wake = **1.40× / 1.41×** (falsified above 3×); ren_c parked task = **128 B**
(falsified above 256 B). **The design is not falsified on this machine.** The
pingpong ratio is computed from NOISY medians; the pooled medians give
18.06/7.79 = 2.32× and 16.61/7.38 = 2.25×, also under 3×.

In range: **every ren_c number**. Pingpong 17–18 (12–25), nested 27–31
(25–45), spawn_join 13–14 (10–20), spawn_batch m64 8.6–8.8 (6–12), m1000
9.9–10.1 (8–20), park wake 9.9–11.1 (5–15), spawn+park 23–24 (15–30), bytes 128
(128), fanout 2.4 (1.5–3), fanout_yield 5.2–5.8 (3–6, near the top). Also in
range: raw_c pingpong, spawn_join and spawn_batch m64; tokio spawn_batch
m64/m1000; Go spawn_batch m1000; tokio spawn_join in run P (296; 309 in U is
ABOVE); tokio spawn+park; park bytes for Go and tokio.

**Disagrees with PLAN (stated plainly):**
- **Go pingpong 388–399 ns, ABOVE 150–300.** tokio pingpong 385–401, ABOVE
  150–300. tokio pingpong_local 195–218, ABOVE 80–160.
- **Go spawn_join 466–486, ABOVE 200–350.** Go spawn_batch m64 415–435, ABOVE
  250–400.
- **Go park wake 837–991 ns, 3–6× ABOVE 150–300.** Go spawn+park 1,526–1,830,
  ABOVE 300–700. tokio park wake 183–219, ABOVE 60–150.
- **Go fanout 54–74 ns an op, ABOVE 15–35.** tokio fanout 18.6 (P) is in range;
  25.4 (U, NOISY) is just ABOVE.
- **Go fanout_yield 194–209 ns, 4–8× ABOVE 25–50.** tokio fanout_yield 85–104,
  ABOVE 15–35.
- **raw_c park wake 7.0–8.0, ABOVE 2–5.** raw_c fanout_yield 3.24–3.26, ABOVE
  1.5–3. raw_c fanout 0.48, BELOW 0.5–1.5.
- PLAN's prose says Ren's switch is "about 10× under Go and tokio". Here
  pingpong is **21–24×** under (17–18 ns against 385–401 ns), and spawn_join is
  about 35×. The ratio is larger than PLAN said, because Go and tokio are slower
  on this machine than predicted while ren_c is not.
- PLAN's "6–12 ns a switch": half a pingpong round trip is 8.5–9 ns, in range.
  But those are NOISY numbers. The clean fanout_yield number, 5.22 ns for an
  add plus a yield, is consistent with it.

## Against the macOS results in `switch/results/`

**There is no macOS full measurement.** `results/` holds only
`smoke-20261029-205953.txt`: n/1000, 1 cold rep, one process. That is not a
measurement, so no cloud number can be said to agree or disagree with a macOS
measurement. For orientation only, the macOS smoke line against cloud:
- **Go and tokio pingpong:** macOS smoke 248 and 232 ns; cloud full run 388–401
  ns, about 1.6× slower on cloud.
- **ren_c pingpong:** macOS smoke 29.9 ns, cold and 1 rep; cloud 17–18. The
  macOS smoke ren_c/raw_c ratio is 3.2×, against 2.3× here.
- **Park bytes:** the same on both: 128 / 40 / about 2.7–2.9 KB / about 265 B.

A real macOS full run (`./measure.sh` on the laptop) is still needed before the
two machines can be compared.

## Script changes made during this step (measure-cloud.sh)

- `PIN=<cpu>`: wraps every timed process in `taskset -c <cpu>`. The file
  becomes `measure-pin<cpu>-<ts>.txt` and the header records the pinning.
- `NOASLR=1`: wraps every timed process in `setarch -R`. The file becomes
  `measure-noaslr-<ts>.txt`.
- The report no longer prints NOISY on the deterministic bytes rows of park.
  Previously the timing flag leaked onto them. Run U's report (written before
  the fix) still shows them flagged.
- Nothing about the measured configurations, n, reps, the spread rule or the
  locking changed. Run U ran the script as the port agent left it.

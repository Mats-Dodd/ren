# Rust entry: effort log (machine: cloud)

Machine **cloud**: `experiments/MACHINE-cloud.md`, 4 vCPU Xeon under KVM,
Linux 6.18.

- Toolchain: rustc/cargo 1.97.0 stable. Nightly 1.101 was used only for the
  tsan profile and for Miri.
- Tools: bindgen CLI 0.66.1, with libclang-18 pinned (see bug 1); libc crate
  0.2.191; loom 0.7 for tests only.
- Started 13:09:58 UTC and finished 13:56 UTC on 2026-10-30, about 0.77 h of
  wall time.
- No timing runs were made, and no plants were added: the task said not to.
- No apt packages were installed.

## Wall time per part

Times come from file mtimes and `date`. They are approximate, because parts
overlap.

| part | wall | code lines (cloc) |
|---|---|---|
| reading SPEC, slice.h, harness, stub; bindgen probe (found bug 1) | 13:10-13:16, ~6 min | — |
| deque (Chase-Lev, §A.3) | ~4 min | 190 (with unit tests) |
| core (sched, journal, ffi, layout, rt) | ~5 min | 1196 |
| drivers (C.1 loop, epoll, io_uring on raw syscalls) | ~5 min | 1171 |
| replay + fuzz | ~2 min, plus a ~3 min fix at 13:42 | 409 |
| hot path (W5) | ~1 min | 67 |
| build scripts (bindgen build.rs, layout-list generator, build.sh) | ~3 min | 141 |
| bring-up: first link, then 54/54 on debug | 13:28-13:29 | — |
| tsan profile (build-std, TSan fence issue) | 13:30-13:35 | — |
| Miri tests, loom models, unsafe counter | 13:36-13:42 | 472 tests + 105 py |
| libFuzzer find and fix, layout probe, W5 build, ren_stop alignment | 13:42-13:52 | — |
| final full runs, notes | 13:52-13:56 | — |

## Functional results

All runs used `flock -s`. W1-W4 were run at 1, 4 and 8 workers.

| build | harness/test.sh (`WORKERS="1 4 8"`, epoll + uring) |
|---|---|
| bin/rust-release | 72 passed, 0 failed |
| bin/rust-release-nostd | 72 passed, 0 failed |
| bin/rust-debug | 72 passed, 0 failed |
| bin/rust-tsan (TMO=200) | 72 passed, 0 failed, no TSan report |
| ASan+UBSan harness over the release core (scratch) | 72 passed, 0 failed |

- **W4 replay** (w1, w3, t_cancel, t_timer, 1 worker, recorded on epoll and on
  io_uring) gives byte-identical result lines, and ren_drv_finish accepts the
  journal. A flipped input byte is refused, and so is a truncated journal.
- **xreplay** passes in every direction tried:
  - rust-release → c-release 8/8, and c-release → rust-release 8/8;
  - rust-debug → rust-release-nostd 8/8;
  - rust-release → stub 8/8, and stub → rust 2/2;
  - rust-release → zig-debug 4/4 (epoll), against the Zig build in progress.
- **Replay at 4 and 8 workers** is refused as "schedule divergence", as SPEC
  §D.1 scopes it.
- **Layout probe**: edits a, b and c all build and pass. The change propagated
  through bindgen (`results/cloud/layout-probe-rust.txt`).
- **Miri**: deque 2/2 and op table 6/6. One op-table test is a 2-worker run on
  two threads, with replies from a third.
- **loom**: 3/3 models. Weakening the take/steal fences to AcqRel, which is P1,
  made `two_thieves` fail. That was a scratch check and was reverted.
- **libFuzzer** (ASan+UBSan, Rust release core): it found bug 13. After the
  fix, 300k runs (seed 1) and 3M runs (seed 7) are clean. The fuzz_run --random
  300 and 2000 runs pass.
- **unsafe** (`rust/tools/count_unsafe.py`): 2025 of 3031 code lines, 66.8%,
  lie inside unsafe blocks or unsafe fn bodies. This is the draft written
  unsafe-fn-first; it was not minimised.

## Self-found bugs and the tool that caught each

| # | bug | caught by |
|---|---|---|
| 1 | bindgen 0.66.1 loads libclang-22 by default (installed for LTO) and silently emits `ren_task` and other typedef-forward-declared structs as opaque `{_address: u8}`. Fix: pin libclang-18; build.rs asserts nothing came back opaque. | inspection of the bindgen output; now build.rs fails the build |
| 2 | or-pattern binding a variable on one side only | rustc E0408 |
| 3 | unused import | rustc warning |
| 4 | no_std staticlib: undefined `rust_eh_personality` | ld, linking the harness |
| 5 | `-Zsanitizer=thread` ABI mismatch with an uninstrumented core | rustc (nightly); fixed with `-Zbuild-std=core,alloc` |
| 6 | false races on stolen frames: TSan ignores `fence(Release)` in push | TSan; the tsan profile also makes the bottom store Release |
| 7 | a test array too small | Rust bounds check (cargo test panic) |
| 8 | the crate name `ren_core` clashed with bindgen's `ren_core` type in a glob import | rustc E0659 |
| 9 | the test host appended to a Vec from two threads | Miri data-race detector |
| 10 | the test reborrowed state the core held raw pointers to | Miri Stacked Borrows |
| 11 | loom declared as a dev-dependency but used by the lib under cfg(loom) | rustc E0433 |
| 12 | ren_stop journaled a CANCEL for every FREE slot (151 KB journal vs C's 3.7 KB) | diffing jdump output against the C entry |
| 13 | the fuzz driver lost a pulled call when input ended mid-REPLY ("no termination") | libFuzzer, 5-byte input |
| 14 | the hot-only link.flags named std's libs | tcc ("library 'gcc_s' not found") |

No core or driver logic bug was found by any test. abi_test (12/12) and every
suite passed on the first build that linked. Full notes, decisions and what is
missing: `rust/NOTES.md`.

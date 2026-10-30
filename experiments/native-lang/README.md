# native-lang: C, Rust or Zig for Ren's scheduler core

This is phase B of the runtime research: the three-language experiment
that `research/native-lang/SYNTHESIS.md` §3 specifies. The ABI is the
**nine-function ABI** of `research/runtime/SYNTHESIS.md` §3. Machine:
**cloud** (`experiments/MACHINE-cloud.md`: 4 vCPU Xeon under KVM, Linux
6.18, io_uring available). Every result file under `results/cloud/`
names machine `cloud`.

```
SPEC.md              the algorithm spec, written before any core code (every atomic ordering named)
harness/slice.h      the one source of truth: layouts, the 9 host functions, the emitted-code ABI,
                     the journal format, the driver-entry ABI, test ABIs, layout list
harness/             shared C: rt.c, host_main.c, workloads/ (W1-W3, the I/O tests, w_fuzz),
                     tests/ (abi_test, deque_stress, layout_check, jdump), fuzz/, hot/ (W5),
                     test.sh (suites), measure.py (timed runs)
harness/stub/        a STUB core + stub drivers: NOT one of the three entries (see below)
c/ rust/ zig/        the three entries (each written by its own agent)
results/cloud/       measurements and logs, machine "cloud"
build.sh             builds the harness against any one language, plus W5, E1 and the layout probe
```

## Using it

```sh
./build.sh stub release                    # bin/stub-release/
./build.sh c release                       # bin/c-release/        (rust: release, zig: release-fast)
./build.sh rust debug P3                   # bin/rust-debug-P3/    (a planted bug, SPEC §F)
harness/test.sh bin/c-asan                 # suites: layout abi deque smoke io replay fuzz
harness/test.sh bin/c-release xreplay:bin/rust-release   # cross-language replay (SPEC §D.3)
./build.sh w5 rust zig                     # bin/w5/: W5 variants i-vi under tcc and clang
./build.sh e1 c                            # bin/e1-c/: l4's E1, one TU vs a separate -O2 core object
./build.sh layout-probe rust               # results/cloud/layout-probe-rust.txt
python3 -I harness/measure.py run bin/c-release c-release      # timed, exclusive lock per configuration
python3 -I harness/measure.py w5 bin/w5 w5
python3 -I harness/measure.py e1 bin/e1-c e1-c
```

`build.sh` and `test.sh` re-run themselves under the **shared** lock
(`flock -s /tmp/ren-bench/lock`). `measure.py` takes the **exclusive**
lock for one configuration at a time (10 runs). It records loadavg at the
start and end, and median, min and max, and re-runs a configuration once
if its spread is over 10%. Workers above 4 are marked `oversubscribed`.

## Contract: what each language directory must provide

Each of `c/`, `rust/` and `zig/` must provide **`<lang>/build.sh <profile> <outdir>`**.

- **Environment:**
  - `REN_HARNESS` is the absolute path of the harness directory. Read
    `slice.h` from `$REN_HARNESS/slice.h` and nowhere else; the layout
    probe points it at an edited copy.
  - `PLANT` is empty or one of `P1` to `P5`.
- **It must leave three files in `<outdir>`:**
  - `libren_core.a`: the core, the drivers, the deque and the layout
    table. These are the symbols below, minus the hot path.
  - `libren_hot.a`: the four `ren_hot_*` symbols.
  - `link.flags`: one line of extra linker arguments, possibly empty
    (for example `-luring` for C, `-ldl` for Rust std).
- **It exits non-zero on failure.** All of its output goes to stdout or
  stderr.
- **No generated file is checked in.** Bindings (bindgen for Rust,
  `zig translate-c -lc $REN_HARNESS/slice.h` for Zig) are generated into
  `<outdir>`, `target/`, `.zig-cache/` or `zig-out/`.

**Profiles** (the names the top build.sh passes):

| lang | profiles |
|---|---|
| c | `release` (clang -O2), `debug`, `asan` (ASan+UBSan), `ubsan-int` (`-fsanitize=integer` on the core, for P2), `tsan`, `tcc` (the core compiled by tcc 0.9.27), `release-hot`, `lto-hot` |
| rust | `release` (std, panic=abort), `release-nostd` (no_std+alloc), `debug` (overflow checks), `tsan`, `release-hot`, `lto-hot` (`-Clinker-plugin-lto` for clang-22 / lld-22) |
| zig | `release-fast`, `release-safe` (panic handler overridden), `debug`, `tsan`, `release-hot`, `lto-hot` (`-flto`, linked with `zig cc -flto`) |

`release-hot` and `lto-hot` need only produce a correct `libren_hot.a`.
`build.sh w5` uses them for variants iii to vi. They also need a
`libren_core.a`, which may be an empty archive.

### Symbols libren_core.a must export (C ABI, names exact, slice.h)

| group | symbols |
|---|---|
| host ABI (9) | `ren_start ren_thread_init ren_run ren_poll_call ren_reply ren_stop ren_kill ren_free ren_progress` |
| emitted-code ABI (7) | `ren_spawn ren_notify ren_world ren_cancel ren_tick ren_cancelled ren_ctx_worker` |
| driver entry (6) | `ren_drv_new ren_drv_host ren_drv_worker ren_drv_finish ren_drv_free ren_drv_last_error` for kinds `REN_DRV_EPOLL`, `REN_DRV_URING`, `REN_DRV_REPLAY`, `REN_DRV_FUZZ`, with recording when `record_fd >= 0` |
| deque test (5) | `ren_dq_new ren_dq_push ren_dq_take ren_dq_steal ren_dq_free` (the same Chase-Lev code the core uses) |
| layout (1) | `ren_layout_table`: every name in `REN_LAYOUT_LIST`, with the value taken from **the language's generated bindings** (`offset_of!` or `size_of`, `@offsetOf` or `@sizeOf`) |

The library must **import** only these symbols from the harness:
- `ren_obj_free`;
- `ren_rc_dup` and `ren_rc_drop` (the core counts task frames with
  these, or an exact reimplementation of SPEC §E's shared branch);
- `ren_task_new` (optional);
- libc, plus liburing for C only.

The library must not define `main`, `ren_obj_free` or any harness symbol.

### Behaviour every core must meet

The tests below are listed by what they check.
- `abi_test`, run single-threaded through the nine functions:
  - basic, stale (P3), cancel_race (P4), cancel_sent, retract,
    answer_now, stop, kill, budget, full, steal and determinism;
  - the exact step counts and journal kinds in it are the spec.
- `deque_stress empty|lifo|stress` (P1, P2).
- `layout_check`.
- `harness w1|w2|w3` at 1 and 4 workers, on both epoll and uring.
- `t_timer t_pipe t_tcp t_cancel`, and `t_block` with `--stop-ms` and
  `--kill-ms` (SPEC §C.2).
- W4: record and then replay `w1 w3 t_cancel t_timer` at 1 worker with
  byte-identical output and journal. A flipped input byte and a
  truncated journal must both be refused.
- `fuzz_run --random`, and the libFuzzer target `fuzz` in the asan
  profile.

`harness/test.sh bin/<tag>` runs all of these.

### Rules (SPEC §0)

- Layouts come from slice.h through bindgen or translate-c. Never hand-mirror.
- No third-party scheduler, deque, runtime or io_uring library.
  - Allowed: libc, the `libc` crate, rustix, bindgen, Zig std
    (`std.os.linux.IoUring`), and liburing in C.
  - loom, shuttle and Miri are allowed for testing.
  - crossbeam-deque may only be an outside baseline.
- Plant each bug exactly where SPEC §F says, and nowhere else.
- Record your time and every bug you hit in `results/cloud/<lang>-log.md`.

## The stub (`harness/stub/`): not an entry

The stub is a deliberately minimal stand-in, so the harness had something
to link against while it was written. It has:
- one worker;
- a plain LIFO stack instead of the Chase-Lev deque, and no park
  handshake;
- a *blocking* stand-in for the epoll driver (synchronous syscalls), so
  it runs W1-W3 but not the I/O tests;
- the replay driver;
- no io_uring, no fuzz driver and no plants.

At 1 worker it follows SPEC §B.4's pick order and §B.7's encoding, so
its journals should match a real core's byte for byte. That makes
`xreplay` against the stub a cheap first conformance check. **Language
entries must not copy stub code.**

What the stub passes on cloud (`harness/test.sh bin/stub-asan`, with
`DRIVERS=epoll WORKERS=1 REPLAY_WL="w1 w3"`):
- layout, abi (steal skipped, since the stub has one worker), deque,
  smoke, and W4 replay of w1 and w3;
- both negative replay tests;
- cross-replay from the ASan build to the tcc build: 14 passed, 0
  failed;
- `abi_test` also fails `stale` against a copy of the stub with P3
  planted, and ASan stops it in `deliver` with P4 planted. These were
  throwaway copies in the scratchpad, not kept.

## Toolchain facts found while building this (cloud, 2026-10-30)

- **tcc 0.9.27** (Ubuntu `0.9.27+git20200814.62c30a4a`) has **no
  `__atomic_*` builtins, no `<stdatomic.h>`, and no `_Thread_local` or
  `__thread`**. Each fails to compile. It does have `_Static_assert` and
  GNU inline asm.
  - So `slice.h` carries an x86-64 inline-asm atomics shim for tcc:
    `lock xadd`, `lock cmpxchg`, `xchg` for seq_cst stores, `mfence`,
    and compiler barriers otherwise.
  - This bears on SYNTHESIS §3 question 4. A C core compiled by tcc
    0.9.27 has to use this shim, or tcc mob. The synthesis' "tcc atomics
    pass" was tcc 0.9.28rc on macOS.
  - Drivers built with tcc must not use TLS.
- **Zig 0.17.0 has no `@fence`** ("invalid builtin function"). SPEC §A.3
  gives the substitution (seq_cst accesses) and the matching P1.
  `zig translate-c -lc harness/slice.h` works. It turns slice.h's
  `_Static_assert`s into comptime checks and translates the static
  inlines.
- **bindgen 0.66.1** takes `slice.h` cleanly. Its layout checks are
  `#[test]` functions, so they run under `cargo test`, not at build time.
- **rustc 1.97.0 uses LLVM 22.1.6.**
  - clang 18 can't do cross-language LTO with it, so **clang-22, lld-22
    and llvm-22 (22.1.8) were installed from apt.llvm.org**
    (`llvm-toolchain-noble-22`).
  - A probe showed that a `-Clinker-plugin-lto` staticlib linked by
    `clang-22 -flto=thin -fuse-ld=lld-22` inlines `ren_hot_dup` into
    the C loop, leaving zero calls.
  - Without `--target=x86_64-unknown-linux-gnu`, lld warns about the
    triple difference (`x86_64-unknown-linux-gnu` vs
    `x86_64-pc-linux-gnu`). build.sh passes the target.
  - tcc 0.9.27 links a Rust no_std staticlib and a Zig `build-lib`
    archive on Linux x86-64, and the probe binaries ran.
  - `zig cc -flto` against a Zig `-flto` lib inlined across languages.
  - These were scratch probes, not the entries' code. Their timings are
    not measurements.
- **zig cc is clang 22.1.8.**
- **The layout probe found a silent failure in the harness's own C.**
  Edit (b) inserts a field before `ren_io_body.buf`. Positional
  initializers such as `ren_io_body b = {7, 8, ptr, 0}` in abi_test then
  put the pointer into the new field and 0 into `buf`. The build passed,
  and the run segfaulted in the stub's `deliver` (a READ of NULL).
  - The harness now uses designated initializers for every slice.h type.
  - SPEC §B.7 now requires field-by-field journal encoding.
  - The C entry is exposed to the same class of failure. That is part of
    what the probe measures for C.
  - `results/cloud/layout-probe-stub.txt` is the stub's run after the
    fix: all three edits build and pass.
- **libclang-rt-18-dev was not installed**, contrary to
  MACHINE-cloud.md's "ASan/TSan/UBSan runtimes present". So clang-18
  `-fsanitize=address` failed to link
  (`cannot find .../libclang_rt.asan_static-x86_64.a`). It was
  installed from the Ubuntu archive (`1:18.1.3-1ubuntu1`).

# zig/: the Zig entry, notes

Machine **cloud** (experiments/MACHINE-cloud.md). Zig **0.17.0** exactly
(`/usr/local/bin/zig`; `build.sh` refuses any other version). Written against
SPEC.md and harness/slice.h, nine-function ABI. **No plants yet**: PLANT is
accepted by build.sh and becomes `opts.plant = N`, but no plant is in the code.
The planted lines are marked `← Pn (not planted)` in the source.

## Files

| file | what |
|---|---|
| `build.sh` | `zig/build.sh <profile> <outdir>`. It generates `slice.zig` (`zig translate-c -lc`), `layout_list.zig` (REN_LAYOUT_LIST expanded by `zig cc -E`) and `opts.zig` into the outdir, then runs `zig build-lib` twice (core, hot) |
| `src/dq.zig` | Chase-Lev, SPEC §A.3 line for line, generic over the item (`Deque(*Task)` in the core, `Deque(u64)` for `ren_dq_*`). Signed `i64` indices, power-of-two rings, growth with old rings retired until free. Fences use §A.3's Zig substitution |
| `src/core.zig` | §B: the nine host functions, the seven emitted-code functions, the op table (slot word `gen:32 \| state:32`, every check one CAS), park/wake, the injector, and the core's journal entries |
| `src/wire.zig` | field-by-field little-endian encoding (`Buf`), FNV-1a, `wireCall` (the CALL/J_PULL payload) |
| `src/alloc.zig` | `c_allocator` (ReleaseFast, TSan) or `std.heap.SafeAllocator` over `c_allocator` (Debug, ReleaseSafe). Every Op and cancel node is its own allocation |
| `src/drv.zig` | `ren_drv_*`, the recorder (spin mutex + buffer), the answer_now and wake callbacks, PIPE/LISTEN, release() fd handling |
| `src/epoll.zig` | epoll driver: an epoll fd + eventfd per worker, a timer heap by (t, id) with lazy deletion, EPOLLONESHOT keyed by fd, `epoll_pwait2` (raw syscall: std has no wrapper) |
| `src/uring.zig` | io_uring driver on `std.os.linux.IoUring`: one ring per worker made R_DISABLED (+SINGLE_ISSUER\|DEFER_TASKRUN) in `ren_drv_new` and enabled (`REGISTER_ENABLE_RINGS`) on the worker thread; TIMEOUT_ABS; ASYNC_CANCEL by user_data and by fd (FD\|ALL); an eventfd READ kept armed |
| `src/replay.zig` | replay driver (§D.1) and fuzz driver (§D.4) |
| `src/root.zig` | the C-ABI exports, the root panic handler, `ren_dq_*`, `ren_layout_table` |
| `src/hot.zig` | `libren_hot.a`: `ren_hot_dup/drop/array_push/array_grow` (§E) |

The fuzz entry is the shared one: `REN_DRV_FUZZ` (random bytes → the replay
driver's host, the §D.4 grammar) is in `src/replay.zig`, and the harness's
`fuzz_run` and `fuzz_target.c` link against it unchanged.

## Profiles

| profile | what |
|---|---|
| `release-fast` | `-O ReleaseFast`, `c_allocator` |
| `release-safe` | `-O ReleaseSafe -fcompiler-rt`, SafeAllocator, root panic handler overridden |
| `debug` | `-O Debug`, SafeAllocator, plus debug checks (below). Zig 0.17 builds Debug with its **self-hosted x86-64 backend** by default, not LLVM (`.comment` names only zig; the object is 12 MB against 1.2 MB, and it builds in 0.8 s against about 4 s). I kept that default. link.flags is `-Wl,-z,noexecstack` for this profile only (see below) |
| `tsan` | `-O ReleaseSafe -fsanitize-thread -fcompiler-rt`, `c_allocator`; `opts.tsan` makes hot.zig's rc read a relaxed atomic |
| `release-hot` | as release-fast (the hot library is what W5 uses) |
| `lto-hot` | the hot library is `zig build-lib -flto` (the archive member is LLVM IR bitcode, checked with `file`); the core is release-fast |

**The root panic handler** (`root.zig`): `pub const panic = std.debug.FullPanic(renPanic)`.
`renPanic` writes the message to stderr and calls libc `abort()`, so every
safety trap ends on the harness's abort path. The old way was a `pub fn panic`
in root, which std.lang calls "Deprecated; make `panic` a namespace instead".

**Debug checks** (Debug and ReleaseSafe, `std.debug.runtime_safety`):
- `ren_run` checks `@frameAddress()` against the stack bound from `ren_thread_init`.
- `ren_world` panics if the task already has a pending call (`task.core[2]`).
- `run_task` panics if the task it picked is not QUEUED (catches double execution).
- There is no "assert runs == 0 || drained" check, as in the C entry: `abi_test budget` breaks it.

## Departures from SPEC (deliberate; all but 4 are the C entry's too)

1. **A retraction wakes the home worker.** `ren_poll_call` retracts a
   CANCEL_UNPULLED op by pushing it to its own inbox, then calls `wake_worker(w)`.
   Without the wake, a driver whose run returned IDLE sleeps forever with the
   retraction sitting in the inbox. It isn't journaled. (C departure 1.)
2. **`ren_stop` skips FREE slots.** Otherwise there would be one LATE CANCEL per
   free slot. (C departure 2, stub.)
3. **DELIVER's inout bytes are clamped to the call's `len`.** (C departure 4.)
4. **Every `fence(SC)` outside the deque is `fenceSC()`**, an inline-asm `mfence`
   (x86-64) or `dmb ish` (aarch64) with a memory clobber. Zig 0.17 has no
   `@fence`. That is the instruction C's `atomic_thread_fence(seq_cst)`
   becomes, but to Zig it is an asm statement, not a C11 fence. The deque uses
   SPEC §A.3's substitution (SC accesses) exactly. hot.zig's `fence(ACQ)` in
   drop_shared is an acquire load of the count (Rust's Arc under TSan does the same).
5. **RELEASE closes the fds the driver made.** That covers ACCEPT, as SPEC says,
   and also CONNECT, LISTEN and both ends of a PIPE. A READ that consumed bytes
   poisons the fd (§2.2). (C departure 5.)
6. **The uring fallback is reported on stderr, not in J_DRV.** J_DRV's payload
   is fixed. (C departure 6.)
7. **`ren_free` drops a pending op's task only if the task word is PARKED.**
   Slots are walked before queues. (C departure 7.)
8. **Fuzz: an action cut short by the end of input is dropped whole.** (C departure 8.)
9. **CLOSE cancels only the closing worker's ops on that fd.** (C departure 9.)
10. **PLANT is `opts.plant`.** `zig build-lib` has no `-D`, so the contract's
    "-Dplant=N" is a generated module (`opts.zig`) holding `plant = N`.

Observation on the spec, not acted on: `deliver` calls `notify(t)` after the
REL store of `aw.state`. A task that was woken spuriously and is running on
another worker can see the state, finish and be freed before that notify
runs. That is a use-after-free window in SPEC §B.5 itself. The harness
workloads never park a task with a pending call that is also notified by a
peer, so no test exercises it. One fix is to dup the task before the store
and drop it after the notify.

## Zig 0.17 findings (API churn hit while writing; each was a compile error)

- `builtin.mode` values are `.debug .safe .fast .small` (they were `.Debug`, `.ReleaseSafe`...).
- `std.builtin` is now `std.lang`. `std.Thread.Mutex` is gone (`std.atomic.Mutex`
  is a tryLock-only spin lock). `GeneralPurposeAllocator`/`DebugAllocator` are
  deprecated for `std.heap.SafeAllocator`.
- `[_:0]u8{0} ** 256` failed to parse: "binary operator '*' has whitespace on
  one side, but not the other". `@splat(0)` works.
- A local `const start` shadowing the file's `pub fn start` is an error, and so is
  `_ = f;` after `f` was used ("pointless discard of capture").
- There's no `@fence` or `@cImport`, and no `epoll_pwait2` wrapper (I used `linux.syscall6`).
- `IoUring.enter` passes no EXT_ARG. That's fine here, since timeouts are in the ring.
- **Safe-mode static libraries need compiler-rt.** ReleaseSafe emits stack
  probes, and the harness link failed with
  `undefined reference to '__zig_probe_stack'` (from `std/Io/Threaded.zig`, which
  the panic machinery pulls in). The fix is `-fcompiler-rt`. Debug linked without it.
- **Zig objects have no `.note.GNU-stack`**, so GNU ld warned "missing
  .note.GNU-stack section implies executable stack". The first fix,
  `-Wl,-z,noexecstack` in link.flags, broke the tcc link of W5 iv
  (`tcc: error: unsupported linker option '-z,noexecstack'`). The fix that works
  is a top-level `comptime { asm(".section .note.GNU-stack,\"\",@progbits\n.previous"); }`
  in root.zig and hot.zig. The LLVM backend honours it. The self-hosted
  backend (Debug) silently ignores it, so the debug profile alone passes
  `-Wl,-z,noexecstack` in link.flags. tcc never links the debug profile.
- Debug's self-hosted backend is also why Debug linked without compiler-rt
  while ReleaseSafe (LLVM) needed `-fcompiler-rt`.
- translate-c keeps REN_* constants as `c_uint` comptime values, and the opaque
  `ren_core`/`ren_ctx`/`ren_drv`/`ren_dq` as `opaque {}`. Every export therefore
  casts the opaque pointer to the Zig struct (counted below).

## Raw-pointer and cast sites (src/, by grep)

| file | @ptrCast | @intFromPtr | @ptrFromInt | @alignCast | `[*c]` in signatures |
|---|---:|---:|---:|---:|---:|
| core.zig | 10 | 2 | 1 | 2 | 10 |
| drv.zig | 6 | 0 | 0 | 2 | 6 |
| epoll.zig | 1 | 3 | 0 | 1 | 0 |
| uring.zig | 2 | 0 | 0 | 1 | 0 |
| replay.zig | 2 | 0 | 0 | 1 | 2 |
| wire.zig | 1 | 0 | 1 | 1 | 0 |
| root.zig | 4 | 0 | 0 | 1 | 15 |
| hot.zig | 1 | 0 | 0 | 1 | 4 |
| dq.zig, alloc.zig | 0 | 0 | 0 | 0 | 0 |
| **total** | **27** | **5** | **2** | **10** | 37 |

So there are 34 cast-builtin sites (`@ptrCast` + `@intFromPtr` + `@ptrFromInt`);
every `@alignCast` is paired with a `@ptrCast`. Each site carries a
`// ptr site:` comment. By kind:
- opaque handle ↔ Zig struct (ren_core, ren_ctx, ren_drv, ren_dq, host pointer): 9;
- `ren_call.body` → `*const ren_io_body`: 4;
- `ren_io_body.buf` (u64) → `[*]u8`: 1 (`wire.bufPtr`, used by everything that touches a buffer);
- reply and journal bytes as `[*]const u8`, and the result as bytes: 7;
- sockaddr_in → sockaddr: 3;
- the injector's link word (`core[1]`, a `uintptr_t` in slice.h) ↔ `*Task`: 2;
- syscall arguments (`epoll_pwait2`): 3;
- the stack bound as an integer: 1;
- realloc's result: 1.

Every `[*c]` → `*T` conversion is a `.?` unwrap, which is null-checked in safe modes.

## Bugs hit while writing (and what caught each)

| # | bug | caught by |
|---|---|---|
| 1 | local `const start` shadowed `pub fn start` (core.zig steal_any) | zig compiler (shadowing error) |
| 2 | `[_:0]u8{0} ** 256` array initializer rejected in 0.17 | zig compiler (parse error) |
| 3 | `_ = f;` on an already-used capture | zig compiler ("pointless discard of capture") |
| 4 | `builtin.mode == .Debug`: the enum is `.debug/.safe` in 0.17 | zig compiler |
| 5 | the layout tuple was generated as (type, field, T) but indexed as (name, T, field) | zig compiler (`no member named 'len'` on a struct type) |
| 6 | `deliver` cleared the debug pending-call mark *after* the REL store of `aw.state`, so a resume on another worker could issue its next call and trip a false "already pending" panic | my own review before the first run |
| 7 | ReleaseSafe/TSan core: `undefined reference to '__zig_probe_stack'` | the harness link (GNU ld); fixed with `-fcompiler-rt` |
| 8 | `lto-hot` with an empty core archive: every harness binary failed to link (`undefined reference to ren_cancelled`, ...) | the harness link (../build.sh links the harness for every profile) |
| 9 | **W2 at 4 workers hung intermittently** (both drivers): every worker parked, deques, injector and inboxes empty, live = 3, and both players PARKED with no NOTIFIED flag while it was player 1's turn. That is a lost notify or a double execution | `test.sh smoke` (timeout 60 s); state read from the hung process with gdb. **Not reproduced since**: it failed in about 8 of 15 runs during one window (13:53-13:58 UTC, when the box was loaded by other agents). After that, 0 failures in more than 100 runs of W2 ×4 and ×8, on debug, release-fast and release-safe, with and without 4 CPU-spinning threads, and with the new run_task double-execution check. The protocol code is line for line the C entry's (which never hung). **Unexplained; recorded as an open bug**. Every hanging run was a Debug build, which uses the self-hosted backend (above), but later Debug builds from the same source didn't hang either |
| 10 | epoll driver: an ACCEPT that got EAGAIN sat in the fd's WRITE/ACCEPT/CONNECT waiter slot, and `arm()` turned that slot into EPOLLOUT. A listening socket never becomes writable, so `t_tcp` hung whenever the connection arrived after the first `accept4` | `test.sh io` (t_tcp epoll ×4 timeout in release-fast; debug had passed by timing); diagnosed with gdb on the live process (the slot table showed an ACCEPT PULLED on worker 2) |
| 11 | no `.note.GNU-stack` in Zig objects; the first fix (`-Wl,-z,noexecstack`) broke tcc; the asm fix then did nothing in Debug (self-hosted backend) | ld warning; then tcc (`./build.sh w5 zig`, variant iv-tcc); then the ld warning again on the debug build (diagnosed with `readelf -S` / `.comment`) |

Nothing was caught by Zig's safety checks (ReleaseSafe/Debug), the safe
allocator or TSan (see results/cloud/zig-log.md for the TSan run). The first
build passed `abi_test` 12/12, `deque_stress` and `layout_check`.

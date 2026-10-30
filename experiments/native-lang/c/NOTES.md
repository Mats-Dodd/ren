# c/: the C entry, notes

Machine **cloud** (experiments/MACHINE-cloud.md). Written against SPEC.md and
harness/slice.h, nine-function ABI. The SPEC §F plants P1-P5 are in the code
behind `#if REN_PLANT == n` (`PLANT=Pn ./build.sh c <profile>`); with no PLANT
the code is the correct version. P2 needs `REN_C_WERROR=0` to build (it trips
-Wsign-compare). P5 also turns the `stolen_from` initialiser in ren_start into a
plain store (forced by the type change). Runs: c/bugs.sh, c/bugs-vg.sh,
c/bugs-rate.sh; results in results/cloud/bugs-c.md.

## Files

| file | what |
|---|---|
| `atom.h` | the atomics: C11 `<stdatomic.h>` on `_Atomic` objects with an explicit `memory_order` on every operation; under tcc the same macros map onto slice.h's x86-64 asm shim |
| `dq.h`, `dq.c` | Chase-Lev deque, SPEC §A.3 line for line; signed `int64_t` indices; growth by doubling with old rings retired until free; also the `ren_dq_*` test ABI |
| `core.h` | private data, SPEC §B.1 |
| `sched.c` | the scheduler unit: `ren_run`'s pick loop, the task word (§B.2), park/wake (§B.6), injector, steal, `ren_spawn`, `ren_notify` |
| `core.c` | the op table and world calls: `ren_start`, `ren_poll_call`, `ren_reply`, `ren_stop`, `ren_kill`, `ren_free`, `ren_world`, `ren_cancel`, deliver; slot word `gen:32 | state:32`, every generation check is one CAS |
| `journal.c` | the core's journal entries, little-endian, field by field |
| `drv_common.c`, `drv.h` | `ren_drv_*`, the recorder (mutex + buffer), the answer_now/wake callbacks, PIPE/LISTEN |
| `drv_epoll.c` | epoll driver: per-worker epoll fd + eventfd, timer heap by (t, id), EPOLLONESHOT readiness |
| `drv_uring.c` | io_uring driver on liburing 2.5: R_DISABLED + SINGLE_ISSUER + DEFER_TASKRUN, enabled on the worker thread; TIMEOUT_ABS for SleepUntil; ASYNC_CANCEL by user_data and by fd |
| `drv_replay.c` | replay driver (§D.1) and fuzz driver (§D.4) |
| `hot.c` | `ren_hot_*` (§E) |
| `layout.c` | `ren_layout_table` |
| `unity.c` | every core file as one TU, for `./build.sh e1 c` |

## Departures from SPEC (each is deliberate)

1. **Retraction wakes the home worker.** `ren_poll_call` retracts a
   CANCEL_UNPULLED op by pushing it to the worker's own inbox. SPEC's
   pseudocode does not wake anyone there. If the worker returned IDLE
   before its driver pulled (the normal order: run, then pull), the driver
   then sleeps forever with a delivery sitting in the inbox (t_cancel (b)).
   The C core calls `wake_worker(w)` after the push: a retraction is a reply
   and §2.7 says every reply leads to a tick. Not journaled, so the journal
   is unchanged.
2. **`ren_stop` skips FREE slots.** SPEC walks every slot and `cancel_slot`
   journals every one, which would write one LATE CANCEL per free slot (4096
   per worker). The stub skips FREE too. A slot that turns ISSUED after the
   read is caught by `ren_world`'s fence + `stopping` check (the Dekker pair).
   Only matters for journals that contain a stop, which W4 does not replay.
3. **No "assert runs == 0 || drained" in debug.** `abi_test budget` calls
   `ren_run` repeatedly with no `ren_poll_call` between, and abi_test is
   normative, so that SPEC debug assertion would fail a passing core. The
   other debug checks are in (thread binding, one pending call per task).
4. **DELIVER's inout bytes are clamped to the call's `len`.** A driver that
   replied `res > len` would otherwise make the core read past the buffer.
5. **RELEASE closes fds the driver created.** SPEC: ACCEPT closes, READ
   poisons, "otherwise nothing". The C drivers also close the fd of a
   released CONNECT/LISTEN and both fds of a released PIPE (they would leak).
6. **The uring fallback is not in J_DRV.** J_DRV's payload is fixed
   (kind, workers, steps); a fallback is reported on stderr instead.
7. **ren_free** drops a pending op's task only if the task word is PARKED: a
   task that was woken spuriously while its call was pending sits in a
   queue too, and the queue walk drops it. Slots are walked before queues
   so no op's task is read after it may have been freed.
8. **Fuzz grammar: an action cut short by the end of input is dropped whole**
   (nothing is removed from `pending` until every byte of the action is read).
9. **CLOSE cancels only the closing worker's ops on that fd.** Ops on the same
   fd held by another worker's epoll/ring are not cancelled (the harness never
   closes an fd that another task still uses).
10. **TSan builds only:** `dq_push` stores `bottom` with REL as well as the
    `fence(REL)` (see TSan below).

## tcc 0.9.27: what happens, and the shim

- `#include <stdatomic.h>`: `error: include file 'stdatomic.h' not found`.
- `_Atomic long x;`: `error: ';' expected (got "long")`.
- `__atomic_store_n` / `__atomic_load_n` / `__sync_fetch_and_add`: **accepted
  as implicit function declarations** (warnings only); the build fails only
  at link: `tcc: error: undefined symbol '__atomic_store_n'`. A library that
  happened to export such a symbol would turn this into a silent non-atomic
  call.
- `_Thread_local int x;`: `error: ';' expected (got "int")`.
- `liburing.h` includes `<stdatomic.h>` (barrier.h:61), so the **io_uring
  driver cannot be built by tcc**. In the `tcc` profile `drv_uring.c` alone is
  compiled by clang -O2; the deque, scheduler, op table, journal, epoll,
  replay and fuzz drivers are compiled by tcc.
- **tcc ignores `__attribute__((packed))` on glibc's `struct epoll_event`**
  (x86-64 `__EPOLL_PACKED`): tcc says sizeof 16 with `data` at offset 8;
  clang and the kernel say 12 and 4. The first tcc epoll build read garbage
  keys and aborted. `drv_epoll.c` passes events through a byte buffer in the
  kernel's layout under tcc.
- **The shim that makes it work** is slice.h's own (`ren_ld64`, `ren_st64`,
  `ren_cas64`, `ren_xchg64`, `ren_xadd64`, `ren_fence`, `ren_st32`), plus a
  CAS-loop `fetch_or` in `atom.h`. tcc does not inline: every atomic is a
  call to an out-of-line copy (objdump of `dq_take`: calls to `ren_ld64`,
  `ren_st64`, `ren_fence`, `ren_cas64`; `ren_fence` contains `mfence`,
  `ren_cas64` contains `lock cmpxchg`). On x86-64 (TSO) plain aligned
  loads/stores with a compiler barrier are acquire/release, so this is
  correct; it would not be on aarch64 (the shim `#error`s there).
- Result: the tcc build passes the whole suite (layout, abi 12/12, deque
  stress, smoke and io at 1/4/8 workers on epoll and uring, W4 replay and
  the negative tests, fuzz_run), and journals replay across clang and tcc
  builds (xreplay).

## TSan

- LLVM's TSan does not model `atomic_thread_fence`. Chase-Lev's push is
  `fence(REL); st(bottom, RLX)` paired with the thief's `ld(bottom, ACQ)`,
  so TSan reported every stolen frame's fields (written by `ren_task_new` /
  the spawner, read by the thief) as a race. In TSan builds only, the store
  of `bottom` is REL too (`REN_C_TSAN`, atom.h / dq.c). This also means TSan
  cannot see P1 (it removes a fence).
- The harness itself produced TSan reports on every shared dup/drop: the
  rc protocol's plain read of a shared count (slice.h `ren_dup`/`ren_drop`)
  and Arc's `fence(ACQ)` before free (rt.c `ren_drop_shared`). **Harness
  change** (TSan builds only, identical code otherwise):
  - slice.h: new `REN_TSAN_HARNESS` detection and `REN_RC_READ(o)`
    (`__atomic_load_n(&o->rc, __ATOMIC_RELAXED)` under TSan, `o->rc`
    otherwise); `ren_dup` and `ren_drop` read rc through it.
  - rt.c `ren_drop_shared`: under `REN_TSAN_HARNESS` an acquire load of rc
    replaces `ren_fence(REN_MO_ACQUIRE)` (what Rust's Arc does under TSan).
  After both, W1/W2/T_TCP at 4 and 8 workers are TSan-clean.

## Bugs hit while writing (and what caught each)

| # | bug | caught by |
|---|---|---|
| 1 | `ren_free` first walked the queues (dropping tasks) and then the slots, reading `op->task`'s word after the drop may have freed the frame | my own review before the first run (no tool) |
| 2 | `drv_replay_run` reset `core_pos` at its start, throwing away the HEADER that `ren_start` had already matched: every replay diverged at entry 1 | `test.sh replay` (W4), all 8 cases |
| 3 | fuzz REPLY removed the call from `pending` before reading its last byte; input ending mid-action left a pulled call that nobody replied, so the end phase never terminated | libFuzzer (asan profile, 20000 runs), input `fa f2 11 f2 f2 f2 ec fa`; diagnosed with a core dump helper (`ren_c_dump`, REN_C_DUMP=1) |
| 4 | under tcc, `struct epoll_event` had the wrong layout (tcc ignores `packed`), so epoll keys were garbage | `test.sh smoke/io` on the tcc build (abort on a huge fd table realloc), confirmed with a sizeof probe |
| 5 | TSan reported frame-field races through the deque (fence-based HB) | TSan (W1 x4) |
| 6 | TSan reported the harness's rc plain read and Arc fence | TSan (W1 x4); harness change above |
| 7 | `unity.c` (E1): drv_epoll.c and drv_uring.c both had statics named `link_op`, `unlink_op`, `release`, `reply`, `submit` | clang ("conflicting types for 'link_op'"), building `./build.sh e1 c`; statics now prefixed `ep_` / `ur_` |

Apart from 7, nothing was caught by the compiler (`-Wall -Wextra -Werror`,
clang 18), and nothing by ASan/UBSan or by `-fsanitize=integer` (the FNV-1a hash and xorshift are
marked `no_sanitize("integer")` up front, since their wrap is intended).

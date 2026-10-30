# native-lang: the slice, specified

This is the one algorithm spec for the three-language experiment in
`research/native-lang/SYNTHESIS.md` §3. It was written before any core
code. The C, Rust and Zig cores implement exactly this, behind exactly
the ABI in `harness/slice.h`, and plant exactly the bugs in §F. Machine:
**cloud** (`experiments/MACHINE-cloud.md`).

Where this spec departs from the two syntheses, it says so and why:
§B.0 has the list. The ABI is the **nine-function** ABI of
`research/runtime/SYNTHESIS.md` §3, which supersedes the five-function ABI
written into native-lang §3. So there is no `now_ns`, no
`ren_poll_deadline` and no timer heap in the core.

Notation. `ld(x, MO)`, `st(x, v, MO)`, `xchg`, `cas(x, expect → desired,
MO_ok, MO_fail)`, `fetch_or`, `xadd` and `fence(MO)` are C11 atomic
operations with the named memory order: RLX, ACQ, REL, AR (acq_rel), SC
(seq_cst). A field written without one of these is a **plain** field,
and the spec names the single thread allowed to touch it. In C these map
to `ren_ld64`, `ren_cas64` and the rest in `slice.h`. In Rust they map to
`core::sync::atomic` through `AtomicI64::from_ptr` and similar, and in
Zig to `@atomicLoad`, `@atomicStore`, `@atomicRmw` and `@cmpxchgStrong`.

---

## §0. Rules every language follows

### 0.1 What each language delivers

These are in `<lang>/`. The exact symbol and file contract is in
`README.md` § Contract.

- A **core library**. It contains the deque (§A), the core (§B), the
  epoll and io_uring drivers (§C), and the replay and fuzz driver (§D).
  It exports:
  - the nine host functions;
  - the seven emitted-code functions (§B.5);
  - `ren_drv_*` (§C, §D);
  - `ren_dq_*`;
  - `ren_layout_table`.
- A **hot library**: `ren_hot_dup`, `ren_hot_drop`, `ren_hot_array_push`
  and `ren_hot_array_grow` (§E).
- No threads are created by the core. Drivers may create none either:
  the slice has no blocking pool.
- No third-party scheduler, deque, runtime or io_uring library. These are
  allowed:
  - libc and liburing (C only);
  - the `libc` crate and `rustix` (Rust);
  - Zig std, including `std.os.linux.IoUring`.

  Rust and Zig may make raw io_uring syscalls. In Rust, the test-only
  dev-dependencies loom and shuttle are allowed, as are Miri and
  crossbeam-deque, which may only be an outside baseline and never be
  linked into the measured library.

### 0.2 Layouts come from slice.h, never by hand

- **Rust** generates its bindings from `harness/slice.h` with bindgen,
  either the crate in `build.rs` or the CLI 0.66.1 called from
  `rust/build.sh`. Generated files go under `target/` or `build/`.
- **Zig** generates them with `zig translate-c -lc harness/slice.h`.
  `@cImport` was removed in 0.17 (l3 §2.5), so this is a build step, and
  its output goes under `.zig-cache/`, `zig-out/` or `build/`.
- Nothing may restate a layout constant that slice.h already defines,
  such as an offset, a size, an op code or a journal kind. Each must come
  from the generated bindings. The journal wire encoding (§B.7) is
  written field by field from those generated types and constants.

### 0.3 The layout check

There are three layers. Each one tells a deliberate change to slice.h
"fails the build" apart from "fails silently".

1. **C** has the `_Static_assert`s at the bottom of slice.h, which fail
   the C build.
2. **Every language** exports `ren_layout_table()`. It holds the offsets
   and sizes of every name in `REN_LAYOUT_LIST`, *as that language's
   bindings see them*: Rust uses `core::mem::offset_of!` and `size_of`
   on the bindgen types, Zig uses `@offsetOf` and `@sizeOf` on the
   translate-c types. `harness/tests/layout_check.c` compares the table
   with C's `offsetof` and `sizeof`. A mismatch fails the test, not the
   build.
3. **`./build.sh layout-probe <lang>`** copies the harness, applies one
   of three deliberate edits to the copy of slice.h, and rebuilds and
   tests the language against it. The three edits are:
   - (a) swap `ren_call.task` and `ren_call.op`;
   - (b) insert a `uint32_t` before `ren_io_body.buf`;
   - (c) renumber `REN_OP_READ`.

   It records for each edit whether it failed the build, failed a test,
   or passed silently. Passing silently is the failure mode the metric
   exists to find.

### 0.4 Build profiles and plants

| lang | profiles (`<lang>/build.sh <profile>`) |
|---|---|
| c | `release` (clang -O2), `debug` (clang -O0 -g), `asan` (ASan+UBSan), `ubsan-int` (UBSan with `-fsanitize=integer`, for P2), `tsan`, `tcc` (core compiled by tcc 0.9.27 using the slice.h asm atomics) |
| rust | `release` (std, `panic=abort`), `release-nostd` (no_std + alloc, `panic=abort`), `debug` (overflow checks on), `tsan` (nightly `-Zsanitizer=thread` is allowed only for this profile; say so in results) |
| zig | `release-fast`, `release-safe` (root panic handler overridden), `debug`, `tsan` (`-fsanitize-thread`) |

A planted bug is selected at build time with `PLANT=P1` through `P5`:
`-DREN_PLANT=1` through `5` in C, `--features plant1` through `plant5`
in Rust, and `-Dplant=1` through `5` in Zig. With no plant, the code is
the correct version. Each plant changes **only** the lines §F names.

### 0.5 Effort accounting

Each language agent records:
- its own wall time per part (deque, core, drivers, replay/fuzz, hot path);
- every bug it hit while writing, with the tool or test that caught it,
  in `results/cloud/<lang>-log.md`.

---

## §A. The Chase-Lev deque

### A.1 Source, and the check against the paper

The deque is Lê, Pop, Cohen and Zappa Nardelli, *Correct and efficient
work-stealing for weak memory models*, PPoPP 2013, DOI
10.1145/2442516.2442524.

**Fig. 1 was fetched and read for this spec.** The copy came from
`https://fzn.fr/readings/ppopp13.pdf`, which is the same text as HAL
hal-00802885. Fig. 1 is the "C11 code of Chase–Lev deque, with low-level
atomics". With the `atomic_`/`memory_order_` prefixes put back, it reads:

```
take:  b = load(bottom, relaxed) - 1;  a = load(array, relaxed);
       store(bottom, b, relaxed);  thread_fence(seq_cst);  t = load(top, relaxed);
       if t <= b: x = load(a->buffer[b % size], relaxed);
                  if t == b: if !CAS_strong(top, t, t+1, seq_cst, relaxed): x = EMPTY
                             store(bottom, b+1, relaxed)
       else: x = EMPTY; store(bottom, b+1, relaxed)
push:  b = load(bottom, relaxed);  t = load(top, ACQUIRE);  a = load(array, relaxed);
       if b - t > size - 1: resize(q); a = load(array, relaxed)
       store(a->buffer[b % size], x, relaxed);  thread_fence(release);  store(bottom, b+1, relaxed)
steal: t = load(top, ACQUIRE);  thread_fence(seq_cst);  b = load(bottom, ACQUIRE);
       x = EMPTY
       if t < b: a = load(array, CONSUME);  x = load(a->buffer[t % size], relaxed);
                 if !CAS_strong(top, t, t+1, seq_cst, relaxed): return ABORT
       return x
```

The paper declares `atomic_size_t top, bottom` and `atomic_int buffer[]`.
So the indices are **unsigned**, which is the root of Wingo's 2022
underflow, and the **elements are atomics** accessed relaxed. Fig. 1 has
no `resize`. §4 of the paper models it as copying the live elements into
a new array, then a barrier, then writing `array`.

**Differences from `research/native-lang/l4-c.md` §2.1**, which quoted
Fig. 1 from memory:

1. *push.* l4 has "a release fence, or release store, of bottom". The
   paper has a `release` fence followed by a *relaxed* store of bottom,
   so l4's "release store" alternative is not the paper's code. l4 also
   leaves out push's **acquire load of `top`**, which the paper has.
2. *steal.* l4 has "a consume or acquire load of the buffer". In the
   paper, the **array pointer** is the consume load and the **element**
   load is relaxed. This matters for growth, since the thief may see the
   old or the new array.
3. *take.* l4 matches: a relaxed store of bottom, a seq_cst fence, a
   relaxed load of top, and a seq_cst CAS for the last element. l4 leaves
   out that the element load and both restores of bottom are relaxed, and
   that each CAS fails with relaxed.
4. l4 is right that the CDSChecker paper (Norris and Demsky, OOPSLA 2013)
   found a bug in this C11 code. **The CDSChecker paper was fetched too**
   (`demsky.eecs.uci.edu/publications/c11modelcheck.pdf`, §8). The bug
   "occurs when both a steal and push operation occur concurrently and
   the push operation resizes the deque. The bug reveals itself as a load
   from a potentially uninitialized memory location", and the authors
   confirmed it. The CDSChecker paper doesn't print the fix.

   This spec closes that window in two ways (A.3):
   - the new ring is fully written before a **release** store of the
     array pointer, which pairs with the thief's acquire load;
   - old rings are **retired, never freed**, until the deque is freed.

   Both are this spec's choices, not the paper's. Model checking them is
   the job of each language's tooling: GenMC or CDSChecker for C, loom
   for Rust.

**Spec choices on top of Fig. 1:**
- Indices `top` and `bottom` are **signed `int64_t`**, and so are all
  their local copies. P2 is what happens without this.
- `consume` is implemented as **acquire**. No compiler implements
  consume, and Rust and Zig don't have it.
- Ring capacities are powers of two, so `i % size` becomes
  `i & (cap - 1)`. That is valid because `i >= 0` wherever it is used.
- Items are pointers: `ren_task *` in the core, and non-zero `uint64_t`
  in the `ren_dq_*` test ABI. Element accesses are relaxed atomics of
  pointer width, as in the paper.

### A.2 Data

```
Ring  { cap: i64 (power of two); slot[cap]: atomic word }
Deque { top: atomic i64;     // stealers CAS it; on its own cache line
        bottom: atomic i64;  // owner writes; on its own cache line
        array: atomic *Ring;
        retired: list of *Ring   // plain, owner only; freed by ren_dq_free / ren_free
      }
```

`top` and `bottom` start at 0. The initial capacity is
`1 << cfg.deque_log2`, or `1 << 8` when that is 0.

### A.3 Operations, with every ordering

```
push(q, x):                                       // owner
  b = ld(q.bottom, RLX)
  t = ld(q.top, ACQ)
  a = ld(q.array, RLX)
  if b - t > a.cap - 1:                           // full
      a = grow(q, a, t, b)
  st(a.slot[b & (a.cap-1)], x, RLX)
  fence(REL)
  st(q.bottom, b + 1, RLX)

grow(q, a, t, b):                                 // owner, from push only
  n = new Ring(cap = 2 * a.cap)
  for i in t .. b-1:  st(n.slot[i & (n.cap-1)], ld(a.slot[i & (a.cap-1)], RLX), RLX)
  q.retired.append(a)                             // never freed while thieves may read it
  st(q.array, n, REL)                             // pairs with steal's ACQ load of array
  return n

take(q):                                          // owner
  b = ld(q.bottom, RLX) - 1                       // signed: -1 on a fresh deque, fine
  a = ld(q.array, RLX)
  st(q.bottom, b, RLX)
  fence(SC)                                       // ← P1 weakens this to AR
  t = ld(q.top, RLX)
  if t <= b:
      x = ld(a.slot[b & (a.cap-1)], RLX)
      if t == b:                                  // last element: race the thieves
          if !cas(q.top, t → t+1, SC, RLX): x = EMPTY
          st(q.bottom, b + 1, RLX)
      return x
  else:
      st(q.bottom, b + 1, RLX)
      return EMPTY

steal(q):                                         // any thread
  t = ld(q.top, ACQ)
  fence(SC)                                       // ← P1 weakens this to AR
  b = ld(q.bottom, ACQ)
  if t < b:
      a = ld(q.array, ACQ)                        // paper: consume
      x = ld(a.slot[t & (a.cap-1)], RLX)
      if !cas(q.top, t → t+1, SC, RLX): return ABORT
      return x
  return EMPTY
```

**Zig substitution (Zig 0.17 has no fence builtin).** `@fence` is
rejected: "invalid builtin function: '@fence'", checked on cloud, and std
emulates fences with an RMW (`std/heap/SafeAllocator.zig:201`). In Zig,
each `fence(SC)` above is replaced by making the two accesses around it
seq_cst:
- take: `st(q.bottom, b, SC)` and then `t = ld(q.top, SC)`;
- steal: `t = ld(q.top, SC)` and then `b = ld(q.bottom, SC)`.

All seq_cst operations sit in one total order, so the outcome that rules
out a double take (both sides read the old value) is still forbidden.
This is the "sequentially consistent version" the paper names in §2.
`fence(REL)` in push becomes `st(q.bottom, b+1, REL)`. Zig's P1 weakens
the four SC accesses to REL stores and ACQ loads. On x86-64 that is the
same code the C and Rust P1 produce, with no `mfence` and no `xchg`.
Rust and C use the fences exactly as written.

**ren_dq_* test ABI.**
- `ren_dq_new(log2)` makes `Deque{top = 0, bottom = 0, array = Ring(1 << log2)}`.
- `ren_dq_push`, `ren_dq_take` and `ren_dq_steal` are the operations
  above. EMPTY is 0 and ABORT is `UINT64_MAX`.
- `ren_dq_free` frees the array and every retired ring.

The core's per-worker deque is the same code with `ren_task *` items.

---

## §B. The sans-I/O core

### B.0 Entities, and departures from the syntheses

- **The ABI is nine functions** with the signatures in `slice.h` §5,
  `research/runtime/SYNTHESIS.md` §3. There are three departures:
  1. `ren_reply`'s argument type is `ren_reply_t`, because C and Zig
     can't have a type and a function both called `ren_reply`.
  2. `main` is `ren_task *(*)(const ren_config *)` rather than
     `int (*)(void)`. A root that can suspend must be a frame, and a
     plain C `main` can't park. The exit status lives in the workload's
     own state (`cfg->user`), so the core holds no globals.
  3. `ren_run`'s "DONE" is spelled `REN_FINISHED`, to keep it apart from
     the reply state `REN_DONE`.
- **`ren_config` gains fields** for §2.8's B and K, the op-slot count,
  the initial deque size and `user`.
- **The emitted-code ABI** (§B.5) is what a resume function calls:
  `ren_spawn`, `ren_notify`, `ren_world`, `ren_cancel`, `ren_tick`,
  `ren_cancelled` and `ren_ctx_worker`. Both syntheses leave it
  implicit. It is part of the slice, because the C frames cross it.
- **Not in the slice:**
  - the LIFO slot;
  - steal-half (a steal takes one item, as in Fig. 1);
  - the cap on how many workers search at once;
  - `Sched.Call.Pick` (deterministic replay is promised at 1 worker
    only, §D.1);
  - leases (`REN_RETURN` is defined but never produced);
  - `pages`.

  Each is small to add later and isn't needed by W1-W5.
- **No timer heap in the core.** A timer is a
  `REN_OP_SLEEP_UNTIL{arg = t}` world call that the driver holds (§C).
- **Tasks are C heap frames from the harness** (`ren_task` in slice.h):
  a 64-byte header, then the emitted code's fields, with
  `resume(self, cx)` returning `REN_T_DONE`, `PARK` or `YIELD`.
  - `ren_task_new` (in harness/rt.c) makes a frame **shared, rc = -1**.
  - The core counts frames only through `ren_rc_dup` and `ren_rc_drop`,
    the header's protocol exported out of line by harness/rt.c, or
    through an exact reimplementation of §E's shared branch.
  - The core owns **one reference per live task**, handed to it by
    `ren_spawn` (or by main's return) and dropped after `REN_T_DONE`.
  - The core uses only `id` and `core[0..3]` of the header:
    - `core[0]` is the task's scheduling word (B.2);
    - `core[1]` is the injector link.

### B.1 Data

```
Core {
  cfg (copied), host (copied), hostp
  nw: i32                         // workers
  W[nw]: Worker                   // each on its own cache line(s)
  slots[nw * S]: Slot             // S = cfg.op_slots (default 4096); worker w owns [w*S, (w+1)*S)
  inj: Injector
  live: atomic i64                // live tasks, root included
  stopping: atomic i32, killed: atomic i32, done: atomic i32
  idle: atomic i32                // parked workers
  B, K: u32                       // budget (default 128), poll interval (default 61)
}
Worker {                          // fields marked (owner) are plain, touched only by worker w's thread
  dq: Deque<ren_task*>
  parked: atomic i32              // 1 = returned IDLE and not yet woken
  steps: atomic u64               // completed steps; st RLX by owner, ld RLX by ren_progress
  stolen_from: atomic u64         // thieves xadd RLX ← P5 makes this plain
  stolen_seen: u64 (owner)        // owner copies ld(stolen_from, RLX) at each ren_run entry
  inbox: atomic *Op               // MPSC stack of replied ops (ren_reply from any thread)
  remote: atomic *CancelNode      // MPSC stack of cancel requests for ops homed here
  cancels: FIFO<*CancelNode> (owner)
  outbox: FIFO<*Op> (owner)       // calls issued here, not yet pulled
  free: stack<u32> (owner)        // free local slot indices; initial pop order 0,1,2,...
  rng: u64 (owner)                // xorshift64, seed 0x9E3779B97F4A7C15 ^ (w+1)
  spawn_seq: u32 (owner)          // last task sequence number issued here
  last_poll: u64 (owner)          // steps value at the last K-poll
  drained: bool (owner, debug)    // ren_poll_call returned false since the last ren_run
  runs: u64 (owner, debug)
  stack_lo, stack_size (owner)    // from ren_thread_init
  cx: ren_ctx { core, worker = w, points: u32, cur: *ren_task }
}
Slot { word: atomic u64 = gen:32 (high) | state:32 (low);  op: *Op (plain; see B.3) }
Op   { next: *Op;  slot: u32;  gen: u32;  home: u16;  had_cancel: bool;
       task: *ren_task;  aw: *ren_await;
       call: ren_call (body → &op.body);  body: ren_io_body;
       reply_state: u32;  reply: ren_io_result }          // heap-allocated per call
CancelNode { next; id: u64 }                             // heap-allocated per cancel sent
Injector { lock: atomic i32 (spinlock); head, tail: *ren_task (plain, under lock); len: atomic i64 }
```

Heap allocation: C uses `malloc`/`free`; Rust uses `alloc`/`Box` (no_std:
`alloc` over a `#[global_allocator]` that calls libc `malloc`); Zig uses
`std.heap.c_allocator` in release, and its safe/general-purpose allocator
in debug and ReleaseSafe. Op records and cancel nodes **must** be
individual heap objects (not a pool or arena), so a double free (P4) is a
real double free each language's tools can see.

**Spinlock** (the injector, the only lock in the core):
```
lock:   while xchg(lock, 1, ACQ) != 0: while ld(lock, RLX) != 0: cpu_relax
unlock: st(lock, 0, REL)
```

**MPSC stacks** (`inbox` and `remote`):
```
push(head, n): loop { h = ld(head, RLX); n.next = h; if cas(head, h → n, REL, RLX): break }
take_all(head): l = xchg(head, NULL, ACQ); return reverse(l)    // FIFO in arrival order
```
`take_all` takes the whole list, so a single pop never happens and there
is no ABA.

### B.2 The task scheduling word (`task.core[0]`)

States: QUEUED = 1, RUNNING = 2, PARKED = 3, DONE = 4. NOTIFIED = 8 is a
flag. Every transition after birth is an RMW, so every notifier's REL
heads a release sequence that the runner's ACQ RMW reads.

```
birth (ren_spawn / ren_start):  st(t.sched, QUEUED, RLX)     // before the publishing push
before resume (worker w):       xchg(t.sched, RUNNING, AR)   // clears NOTIFIED; syncs with every notify before it
notify(cx, t):
  s = fetch_or(t.sched, NOTIFIED, AR)
  if s == PARKED:                   // exactly one notifier sees PARKED without the flag
      xchg(t.sched, QUEUED, AR)
      dq_push(W[cx.worker].dq, t); wake_one(cx.worker)
  // QUEUED, RUNNING, any |NOTIFIED, DONE: the flag is enough
after resume returned r:
  DONE:  xchg(t.sched, DONE, AR); task_done(w, t)
  PARK:  if !cas(t.sched, RUNNING → PARKED, AR, ACQ):     // a notify came while running
             xchg(t.sched, QUEUED, AR); dq_push(W[w].dq, t); wake_one(w)
  YIELD: xchg(t.sched, QUEUED, AR); inj_push(t); wake_one(w)
task_done(w, t):
  ren_rc_drop(&t.obj)               // the core's reference (fin runs inside, at 0)
  if xadd(live, -1, AR) == 1: finish(w)
finish(w):
  journal(END, w, how = 0)
  st(done, 1, REL); wake_all()
```

### B.3 Op identity, the op table and its states

- **Identity.** `id = (uint64)global_slot << 32 | gen`. That is
  slot:32 | gen:32 with the slot in the high half. Every slot's
  generation starts at 1. `next_gen(g) = g + 1`, or 1 if that wraps to 0.
  Generation 0 never names a live call, so id 0 is never valid.
- **Home worker.** `home = global_slot / S`.
- **Slot word.** The word holds `gen` and the state together, so every
  generation check and state change is a single CAS. P3 is exactly that
  check removed.
- **States:** FREE 0, ISSUED 1, PULLED 2, CANCEL_UNPULLED 3,
  CANCEL_PULLED 4, REPLIED 5.

| from | to | who | where |
|---|---|---|---|
| FREE(g) | ISSUED(g) | home, `st REL` after writing `slot.op` | ren_world |
| ISSUED | PULLED | home, `cas AR/ACQ` | ren_poll_call |
| ISSUED | CANCEL_UNPULLED | any, `cas AR/ACQ` | cancel_slot |
| CANCEL_UNPULLED | REPLIED (Cancelled) | home, `cas AR/ACQ` | ren_poll_call (retract) |
| PULLED | CANCEL_PULLED | any, `cas AR/ACQ` | cancel_slot |
| PULLED, CANCEL_PULLED | REPLIED | any, `cas AR/ACQ` | ren_reply |
| REPLIED(g) | FREE(next_gen(g)) | home, `st REL` | deliver |

`slot.op` is written by the home worker before the REL store of ISSUED.
It is read only by a thread whose ACQ load or CAS saw a state of ISSUED
or later with the same generation. That is the same thread that is
about to deliver it, so the write happens-before the read.

**A task has at most one pending world call** (an emitted-code invariant;
debug builds assert it in `ren_world`).

### B.4 The nine functions

```
ren_start(cfg, main, host, hostp):
  validate 1 <= cfg.workers <= 64; copy cfg (defaults for zeros), host, hostp
  allocate Core, W[], slots (word = 1<<32 | FREE), free stacks, deques, injector
  live = 1
  journal(HEADER, worker = -1, step 0, {version 1, workers, B, K, policy, build_id})
  root = main(&core.cfg)            // the frame; one reference, now the core's
  root.id = (0 << 24) | ++W[0].spawn_seq            // = 1
  st(root.sched, QUEUED, RLX); inj_push(root)       // no wake: nobody is parked yet
  return core                       // no global or static mutable state anywhere

ren_thread_init(c, w, stack_lo, stack_size):
  W[w].stack_lo/size = ...; debug: remember the binding; every later ren_run(c, w, ...)
  asserts &local ∈ [stack_lo, stack_lo + stack_size) when stack_lo != NULL.
  (One ren_run per worker at a time; a worker never changes thread.)

ren_run(c, w, steps):
  debug: thread check; assert runs == 0 || drained; drained = false; runs++
  if ld(killed, ACQ): return FINISHED
  if xchg(W[w].parked, 0, AR) == 1: xadd(idle, -1, RLX)
  W[w].stolen_seen = ld(W[w].stolen_from, RLX)     // P5: a plain read of the plain field
  if ld(done, ACQ): return FINISHED
  drain_inbox(w)
  n = 0
  loop:
    if ld(done, ACQ) or ld(killed, ACQ): return FINISHED
    if n == steps: return RUNNING
    t = NULL
    s = W[w].steps (owner's own value)
    if s != 0 and s % K == 0 and W[w].last_poll != s:    // §2.8: the world poll on a count
        W[w].last_poll = s
        drain_inbox(w)
        t = inj_pop()
    if !t: t = dq_take(W[w].dq)
    if !t: t = inj_pop()
    if !t: t = steal_any(w)
    if !t:
        if drain_inbox(w) > 0: continue
        if try_park(w): return ld(done, ACQ) ? FINISHED : IDLE
        continue
    run_task(w, t); n++

run_task(w, t):
  xchg(t.sched, RUNNING, AR)
  cx = &W[w].cx; cx.points = 0; cx.cur = t
  r = t.resume(t, cx)
  st(W[w].steps, W[w].steps + 1, RLX)       // entries written during the resume carry the old value
  handle r as in B.2

drain_inbox(w):   for op in take_all(W[w].inbox): deliver(w, op); return how many

inj_pop():        if ld(inj.len, RLX) == 0: return NULL
                  lock; t = pop head (link = t.core[1]); if t: xadd(inj.len, -1, RLX); unlock; return t
inj_push(t):      lock; append t; xadd(inj.len, 1, RLX); unlock

steal_any(w):
  if nw == 1: return NULL
  start = xorshift64(&W[w].rng) % nw
  for i in 0 .. nw-1:
    v = (start + i) % nw; if v == w: continue
    x = dq_steal(W[v].dq)
    if x is a task: xadd(W[v].stolen_from, 1, RLX)    // ← P5: plain W[v].stolen_from += 1
                    return x
  return NULL                                         // EMPTY and ABORT both move on

ren_poll_call(c, w, out):
  if ld(killed, ACQ): goto none
  if W[w].cancels is empty: W[w].cancels.append_all(take_all(W[w].remote))
  if node = W[w].cancels.pop_front():
      *out = {id = node.id, worker = w, kind = REN_CANCEL, lane 0, task 0, op 0, len 0, body NULL}
      free(node); return true
  while op = W[w].outbox.pop_front():
      g = op.gen
      e = g<<32 | ISSUED
      if cas(slot(op).word, e → g<<32 | PULLED, AR, ACQ): *out = op.call; return true
      // otherwise the state is CANCEL_UNPULLED: retract, with no round trip (glommio's Enqueued)
      cas(slot(op).word, g<<32|CANCEL_UNPULLED → g<<32|REPLIED, AR, ACQ)   // cannot fail: only home moves it from here
      op.had_cancel = true; op.reply_state = REN_CANCELLED; op.reply = {res = -125, 0, 0}
      mpsc_push(W[w].inbox, op)           // delivered at the next drain, in order
none:
  debug: W[w].drained = true
  return false

ren_reply(c, r):                           // any thread
  if ld(killed, ACQ): journal(RELEASE, -1, {r.id, DEAD}); return RELEASE
  gs = r.id >> 32; g = (u32) r.id
  if gs >= nw*S or g == 0: journal(RELEASE, -1, {r.id, STALE}); return RELEASE
  s = &slots[gs]
  loop:
    wd = ld(s.word, ACQ)
    if wd >> 32 != g: journal(RELEASE,-1,{r.id, STALE}); return RELEASE    // ← P3 deletes this line
    st = wd & 0xffffffff
    if st == PULLED or st == CANCEL_PULLED:
        if cas(s.word, wd → (wd & ~0xffffffff) | REPLIED, AR, ACQ): break
        continue
    why = (st == REPLIED) ? DUP : STALE
    journal(RELEASE, -1, {r.id, why}); return RELEASE
  op = s.op
  op.had_cancel = (st == CANCEL_PULLED)
  op.reply_state = r.state; op.reply = first 24 bytes of r.body (zero-filled if r.len < 24)
  mpsc_push(W[op.home].inbox, op)          // REL
  wake_worker(op.home)                     // §2.7: every reply leads to a tick
  return ACCEPTED

ren_stop(c):                               // any thread
  if xchg(stopping, 1, SC) == 1: return
  fence(SC)
  for gs in 0 .. nw*S-1: cancel_slot(gs, ld(slots[gs].word, ACQ) >> 32, worker = -1)
  wake_all()

ren_kill(c):                               // any thread
  if xchg(killed, 1, SC) == 1: return
  journal(END, -1, how = 1); st(done, 1, REL); wake_all()

ren_free(c):        // after every worker's ren_run returned FINISHED and every driver finished
  for each worker: while t = dq_take: ren_rc_drop(t);  while t = inj_pop: ren_rc_drop(t)
  for every slot with state != FREE: op = slot.op; ren_rc_drop(op.task); free(op)
      // after kill only: each parked-on-a-call task has its core reference dropped here.
      // A task parked on ren_notify alone is unreachable from the core and leaks after a
      // kill (documented; the kill test runs with leak detection off).
  free cancel nodes (cancels, remote), deques with their retired rings, slots, W, Core

ren_progress(c, w):  return ld(W[w].steps, RLX)    // any thread, read-only
```

### B.5 The emitted-code ABI

```
ren_spawn(cx, t):
  w = cx.worker
  t.id = (w << 24) | ++W[w].spawn_seq
  st(t.sched, QUEUED, RLX)
  xadd(live, 1, RLX)                       // the spawner is live, so live can't reach 0 meanwhile
  dq_push(W[w].dq, t); wake_one(w)

ren_notify(cx, t):  as B.2

ren_world(cx, self, aw, op, body):
  w = cx.worker
  debug: assert self has no other pending call
  if ld(stopping, ACQ):
      aw.id = 0; aw.op = op; aw.res = {-125,0,0}
      journal(DELIVER, w, {id 0, CANCELLED, res})
      st(aw.state, REN_CANCELLED, REL); return NOW
  if W[w].free is empty: return FULL
  ls = W[w].free.pop(); gs = w*S + ls; g = ld(slots[gs].word, RLX) >> 32
  id = gs << 32 | g
  o = new Op{slot = gs, gen = g, home = w, task = self, aw = aw, body = *body,
             call = {id, worker = w, kind = REN_CALL, lane = 0, task = self.id, op, len = 32, body = &o.body}}
  aw.id = id; aw.op = op; st(aw.state, 0, RLX)
  journal(CALL, w, o.call + body (buf = 0) + out_hash)
  if host.answer_now and host.answer_now(hostp, w, &o.call, &rep):   // inline: same journal path
      journal(DELIVER, w, {id, rep.state, rep.body})
      aw.res = rep.body; st(aw.state, rep.state, REL)
      st(slots[gs].word, next_gen(g) << 32 | FREE, REL); W[w].free.push(ls); free(o)
      return NOW
  slots[gs].op = o
  st(slots[gs].word, g<<32 | ISSUED, REL)
  W[w].outbox.push_back(o)
  fence(SC)                                // Dekker with ren_stop's xchg(stopping, SC) + fence + walk
  if ld(stopping, RLX): cancel_slot(gs, g, w)
  return PENDING

cancel_slot(gs, g, by):                   // shared by ren_cancel and ren_stop
  s = &slots[gs]
  loop:
    wd = ld(s.word, ACQ)
    if wd >> 32 != g: how = LATE; break
    st = wd & 0xffffffff
    if st == ISSUED:
        if cas(s.word, wd → g<<32|CANCEL_UNPULLED, AR, ACQ): how = RETRACT; break
    elif st == PULLED:
        if cas(s.word, wd → g<<32|CANCEL_PULLED, AR, ACQ):
            mpsc_push(W[home(gs)].remote, new CancelNode{id = gs<<32|g}); wake_worker(home(gs))
            how = SENT; break
    else: how = LATE; break
  journal(CANCEL, by, {gs<<32|g, how})     // by = -1 from ren_stop: step 0

ren_cancel(cx, id):  if (id>>32) >= nw*S or (u32)id == 0: journal(CANCEL, cx.worker, {id, LATE}); return
                     cancel_slot(id >> 32, (u32) id, cx.worker)

deliver(w, op):                            // home worker, inside ren_run, from drain_inbox
  aw = op.aw; t = op.task
  journal(DELIVER, w, {op.call.id, op.reply_state, op.reply,
                       inout = (op is READ and state DONE and res > 0) ? buf[0 .. res) : empty})
  aw.res = op.reply; st(aw.state, op.reply_state, REL)
  if op.had_cancel: on_cancel_done(w, op)  // correct: plain W[w] counter only.  ← P4 adds free(op) here
  st(slots[op.slot].word, next_gen(op.gen) << 32 | FREE, REL); W[w].free.push(op.slot - w*S)
  free(op)
  notify(&W[w].cx, t)

ren_tick(cx):       cx.points += 1; return cx.points >= B
ren_cancelled(cx):  return ld(stopping, ACQ) != 0
ren_ctx_worker(cx): return cx.worker
```

The emitted code reads `ld(aw.state, ACQ)` when it resumes. Zero means
the wake was spurious, and it returns PARK again. A task can be resumed
by any `ren_notify` before its reply arrives. Because `aw.state` is a
REL/ACQ pair, `aw.res` is visible even when deliver, on the home worker,
races a resume that runs on another worker.

### B.6 Park and wake (§2.7)

```
try_park(w):
  st(W[w].parked, 1, SC); xadd(idle, 1, SC)
  fence(SC)
  if ld(W[w].inbox, ACQ) != NULL or ld(inj.len, RLX) > 0 or any v: ld(W[v].dq.bottom, ACQ) - ld(W[v].dq.top, ACQ) > 0
     or ld(done, ACQ) or ld(killed, ACQ):
      if xchg(W[w].parked, 0, AR) == 1: xadd(idle, -1, RLX)
      return false                // someone else may already have woken us: harmless (sticky permit)
  return true

wake_worker(v):                    // after making work visible to v (inbox push, remote push)
  fence(SC)
  if ld(W[v].parked, RLX) == 1 and cas(W[v].parked, 1 → 0, AR, RLX):
      xadd(idle, -1, RLX); host.wake(hostp, v)

wake_one(w):                       // after publishing stealable work (dq_push, inj_push)
  fence(SC)
  if ld(idle, RLX) == 0: return
  for i in 1 .. nw: v = (w + i) % nw          // w itself last
     if ld(W[v].parked, RLX) == 1 and cas(W[v].parked, 1 → 0, AR, RLX):
         xadd(idle, -1, RLX); host.wake(hostp, v); return

wake_all():  for v: if cas(W[v].parked, 1 → 0, AR, RLX): xadd(idle, -1, RLX); host.wake(hostp, v)
```

This is a Dekker or store-buffer pattern: SC store, SC fence, then a
load on each side. The publisher's store of the work, then its SC
fence, then its load of `parked` can't both miss and be missed. So
either the parker sees the work, or the publisher sees `parked == 1`.
`host.wake` is called only after a successful 1→0 CAS: only for a
parked worker, and at most once per park. It is a leaf. The driver
makes it sticky with an eventfd, so a wake that lands before the driver
sleeps is not lost.

### B.7 The journal (§2.4), the core's part

`journal(kind, worker, payload)` encodes `ren_jent{kind, len, worker,
_pad = 0, step}` and then the payload, packed little-endian. It calls
`host.journal(hostp, worker, bytes, 24 + len)` only if `host.journal`
is non-NULL. `step` is `ld(W[worker].steps, RLX)` for a worker, and 0
for -1.

Every multi-byte field is written on its own: never `memcpy` a struct,
and never a positional initializer in C. A field inserted into a
slice.h struct must not move the wire. The harness learned this from
its own layout probe (README).

The entries:

- **CALL**: the wire call (28 bytes: id u64, worker u16, kind u16,
  lane u32, task u32, op u32, len u32). Then, for `REN_CALL` only, the
  body as four fields, 32 bytes: fd i64, len u64, buf u64 written as 0,
  and arg i64. Then `out_hash` u64. For WRITE, `out_hash` is the FNV-1a
  64 hash of `buf[0..len)` (offset basis 0xcbf29ce484222325, prime
  0x100000001b3). Otherwise it is 0.
- **DELIVER**: id u64, state u32, len u32 (= 24), the 24-byte result,
  `in_len` u32, then the inout bytes. Inline answers (answer_now) and
  queued replies take this same path, so the journal can't tell them
  apart.
- **CANCEL**: id u64, how u32.
- **RELEASE**: id u64, why u32.
- **END**: how u32.
- **HEADER**: as in slice.h.

The **delivery** is what gets journaled, on the home worker at a counted
step, never the arrival. The cancel race is decided there and recorded
there.

### B.8 Determinism (what replay and cross-language replay rely on)

With `workers = 1`, and with the driver on the same thread (so every
`ren_reply` lands between two `ren_run`s), the whole journal is a
deterministic function of what the driver did. The core entries are
CALL, DELIVER, CANCEL, RELEASE and END. The driver's actions are RUN,
PULL, DRAINED and REPLY, plus answer_now's answers.

The orders B.4 fixes are part of the spec, so all three cores produce
**the same bytes**:
- the free-slot pop order;
- task ids;
- the K-poll rule;
- the order in which work is picked: K-poll, own deque, injector,
  steal;
- delivery order (FIFO of arrival);
- cancel-node order.

`harness/test.sh xreplay` replays a journal recorded by one language
with another language's replay driver.

---

## §C. The Linux drivers (epoll and io_uring)

### C.1 One loop shape (§3 "what it implies"), per worker thread

```
drv_worker(d, c, w):
  setup(w)            // epoll: epoll fd + eventfd (EFD_NONBLOCK) for wake, registered EPOLLIN
                      // uring: ring created with R_DISABLED (+ SINGLE_ISSUER | DEFER_TASKRUN
                      //        unless REN_DRV_F_URING_NO_DEFER), enabled here on its own thread;
                      //        a multishot-free READ on the eventfd kept armed for wakes
  loop:
    r = ren_run(c, w, steps)
    while ren_poll_call(c, w, &call): submit(w, call)      // drain until false: the one signal
    if r == FINISHED and inflight(w) == 0: break
    if r == FINISHED: cancel_all_inflight(w)               // after kill; stop has none left
    wait(w, timeout = (r == RUNNING) ? 0 : until earliest timer, or forever if none)
    for each completion: rr = ren_reply(c, &reply); if rr == RELEASE: release(w, completion)
    for each timer with deadline <= CLOCK_MONOTONIC now: ren_reply({id, DONE, res 0}) (RELEASE → drop it)
  teardown(w)         // only after FINISHED and inflight == 0: close the ring or epoll fd (compio's order)
```

**The buffer rule.** The buffer named by a READ or WRITE belongs to the
driver from `submit` until the driver has called `ren_reply` for the
call's **final** completion. The driver never reads or writes it
afterwards, and the frame never touches it before. A cancelled read
whose CQE has not come back is still in flight. The driver waits for it
before `ren_reply` and before teardown. After `ren_kill` the frames
outlive the driver's drain, because `ren_free` comes after
`ren_drv_finish`. So the kernel never writes into freed memory.

`release(w, completion)` is how the driver acts on `RELEASE`:
- an ACCEPT that succeeded: close the new fd;
- a READ that consumed bytes: mark the fd **poisoned**, so that later
  READs on it complete with `-EIO` (§2.2 torn handle);
- otherwise nothing.

**Ops** (slice.h §4). The body is
`ren_io_body{fd, len, buf, arg}` and the reply is
`ren_io_result{res, a, b}`, with `res` negative errno on failure.

| op | epoll driver | io_uring driver |
|---|---|---|
| SLEEP_UNTIL `arg` = t (ns, CLOCK_MONOTONIC) | driver timer heap (binary heap by (t, id)); the epoll_wait timeout is set from the earliest t | `IORING_OP_TIMEOUT` with `IORING_TIMEOUT_ABS`, CLOCK_MONOTONIC (default), count 0; `-ETIME` → res 0 |
| MONO_NOW | answered by `answer_now`: `clock_gettime(CLOCK_MONOTONIC)` | same (answer_now) |
| PIPE | `pipe2(O_NONBLOCK\|O_CLOEXEC)` synchronously at submit; complete at once | same, synchronously |
| READ / WRITE | try `read`/`write` now; on EAGAIN, `EPOLL_CTL_ADD/MOD` with EPOLLIN/EPOLLOUT \| EPOLLONESHOT, keyed by fd; retry on readiness | `IORING_OP_READ` / `IORING_OP_WRITE`, user_data = id |
| LISTEN | `socket`, `SO_REUSEADDR`, `bind(127.0.0.1:arg)`, `listen(128)`, `getsockname`, synchronously; res = fd, a = port | same, synchronously |
| ACCEPT | `accept4(NONBLOCK\|CLOEXEC)`; on EAGAIN wait for EPOLLIN | `IORING_OP_ACCEPT` (flags NONBLOCK\|CLOEXEC) |
| CONNECT | nonblocking `connect`; on EINPROGRESS wait for EPOLLOUT then `SO_ERROR` | `IORING_OP_CONNECT` (the sockaddr lives in the driver's op record until the CQE) |
| CLOSE | cancel every in-flight op on fd (each gets Cancelled), then `close` | `IORING_OP_ASYNC_CANCEL` with `IORING_ASYNC_CANCEL_FD \| ALL`, then `close` once those CQEs are in (§2.6) |
| REN_CANCEL `id` | if id is waiting on readiness or a timer: drop the wait and reply Cancelled (res -125); if it has completed or is unknown: ignore | `IORING_OP_ASYNC_CANCEL` by user_data = id; the **original** op's CQE is the final reply: `-ECANCELED` → state CANCELLED, any other result → DONE with that result (§2.2: deliver the real result); the cancel's own CQE is ignored |

**One waiter per fd and direction.** In the slice an fd has at most one
pending READ and at most one pending WRITE, ACCEPT or CONNECT at a time.
The harness workloads keep to this, so an epoll driver can register an
fd once and doesn't need waiter lists. A driver may support more.

Each driver keeps the in-flight ops in a table keyed by call id. The
driver's op record holds the `ren_call` (the core's body pointer stays
valid until the final reply, B.3), the readiness state, and for
io_uring the sockaddr and timespec storage.

**Wake.** `host.wake(w)` writes 1 to worker w's eventfd. It is
idempotent and sticky, and may be called from any thread. The driver
drains the eventfd on wakeup. The io_uring driver keeps one READ of the
eventfd armed with a reserved user_data, and re-arms it after each
completion. `MSG_RING` is not used, because wakers can be non-worker
threads (ren_stop, other workers' ren_reply).

**Detect once, fall back whole** (§2.10). `ren_drv_new(URING)`:
- tries `io_uring_setup` with SINGLE_ISSUER|DEFER_TASKRUN|R_DISABLED;
- on EINVAL retries without SINGLE_ISSUER and DEFER_TASKRUN, and records
  that in the J_DRV entry;
- on ENOSYS or EPERM returns NULL, and `ren_drv_last_error` says why.

The harness then reports it. It does **not** silently use epoll.

**Recording.** When `record_fd >= 0`, `ren_drv_host` returns a host
whose `journal` appends to `record_fd` under a mutex: the core's entries
verbatim, plus the driver entries the driver writes itself:
- `J_DRV` once;
- `J_RUN{steps, ret}` after each ren_run;
- `J_PULL{call}` for each true poll;
- `J_DRAINED` for the false poll;
- `J_REPLY{reply, inout bytes, ret}` for each ren_reply, where the inout
  bytes are what the driver wrote into the READ buffer.

Every driver entry's `step` field is `ren_progress(w)` at the time of
writing.

### C.2 What the harness checks (harness/workloads/t_io.c, `test.sh io`)

| test | what it does | pass condition |
|---|---|---|
| T_TIMER | 5 tasks SleepUntil(now + {25, 5, 15, 20, 10} ms) | they finish in deadline order; each finishes at or after its deadline and before it + 200 ms |
| T_PIPE | 256 KiB through a pipe in 4 KiB writes against 1 KiB reads (so it hits EAGAIN) | the checksum matches |
| T_TCP | LISTEN on port 0; ACCEPT, READ 4, WRITE "pong", CLOSE; a client does CONNECT, WRITE "ping", READ 4 | "pong" received; both tasks finish |
| T_CANCEL | (a) READ an empty pipe, a peer sleeps 10 ms then cancels: CANCELLED; (b) issue READ and cancel it in the same step: retracted (journal how 0), CANCELLED; (c) SleepUntil(+10 s) cancelled after 5 ms: CANCELLED in < 1 s | all three |
| T_STOP | tasks blocked on READ and SleepUntil(+10 s); the host calls ren_stop at 50 ms | FINISHED within 1 s; every blocked call is CANCELLED |
| T_KILL | same, with ren_kill | FINISHED, `ren_drv_finish` drains in-flight ops, no ASan error (leaks off) |

---

## §D. Record, replay and fuzz

### D.1 Replay (`REN_DRV_REPLAY`)

The input is a recorded journal. The harness calls `ren_start` with the
same workload and `workers`, then `ren_drv_worker(d, c, -1)` on one
thread, after calling `ren_thread_init` for every worker on that thread.
The replay driver makes no OS calls. It **is** a host whose callbacks
are:
- `wake`: a no-op;
- `answer_now`: answers from the recorded DELIVER for that call id;
- `journal`: compares each entry the replaying core writes with the next
  recorded core entry, byte for byte. Core entries are kinds below 16,
  taken in file order.

```
for each recorded driver entry e (kinds >= 16) in file order:
  J_DRV:     check workers
  J_RUN:     r = ren_run(c, e.worker, e.steps); require r == e.ret
  J_PULL:    require ren_poll_call(c, e.worker, &call) and wire(call) == e.payload; keep call by id
  J_DRAINED: require !ren_poll_call(c, e.worker, &call)
  J_REPLY:   call = kept[e.id] (a reply to an unknown id is replayed as is: it must RELEASE);
             if e.in_len > 0: memcpy(call.body.buf, e.in, e.in_len)      // the driver owns the buffer
             require ren_reply(c, &{e.id, e.state, e.body}) == e.ret
at the end: every recorded core entry was matched, and the replaying core wrote no more
```

The first mismatch makes `ren_drv_finish` return its 1-based entry
index, and `ren_drv_last_error` says which field differed: a call
argument, a delivery point, an early end or a late end (§2.4).

The harness also compares the workload's **output** with the recording's,
byte for byte (`test.sh replay`). W3's latencies are instrumentation, so
they are off in replay and not compared.

**Scope.** Byte-for-byte replay is promised for `workers = 1`. That is
W4's configuration. At more workers a recording is still written, but
arrival interleaving across threads isn't recorded (there is no
`Sched.Call.Pick` in the slice). Replay then reports "schedule
divergence" at the first entry that differs. That is the honest
§2.10 position.

### D.2 Record

Record is `REN_DRV_EPOLL` or `REN_DRV_URING` with `record_fd` set (C.1).

### D.3 Cross-language replay

Because of B.8, a journal recorded by any core must replay under any
other. This is a strong check that the three implement one spec.

### D.4 Fuzz (`REN_DRV_FUZZ`)

This is the replay driver fed random bytes. It is the shared fuzz
harness (l4's E4). The workload is `harness/workloads/w_fuzz.c`:
- 2 workers on one thread;
- 6 tasks, each doing 8 world calls (READ into its frame buffer,
  SLEEP_UNTIL, WRITE), at random from a seed that comes from the first
  input byte;
- every third task cancels a sibling's pending call through a shared
  slot;
- the tasks check every reply they get: the reply id equals their call
  id, the state is DONE or CANCELLED, and the result is never
  `REN_FUZZ_STALE_MAGIC`. They abort otherwise.

The fuzz configuration (`harness/fuzz/fuzz_common.c`) is
`workers = 2`, `op_slots = 8`, `budget_b = 4` and `poll_k = 5`. These
small values force slot reuse, yields and K-polls. The grammar is the
same in every language. `next()` returns the next
input byte, or ends the action loop when the input is used up.

```
pending: list of pulled calls (pull order); done_ids: ring of the last 64 ids replied ACCEPTED
loop while input remains:
  a = next() % 8
  0, 1: RUN     w = next() % nw; steps = 1 + next() % 16; ren_run(c, w, steps);
                then poll w until false, appending REN_CALL calls to pending; a REN_CANCEL for
                an id in pending replies that id {CANCELLED, res -125} at once (oracle: ACCEPTED);
                other cancels are dropped
  2:    REPLY   if pending: k = next() % len; c = remove pending[k];
                state = next() & 1 ? CANCELLED : DONE; res = state == DONE ? next() % (len+1) : -125
                (READ: write res bytes of pattern (id + i) & 0xff into buf first);
                oracle: ren_reply == ACCEPTED; push id to done_ids
  3, 4: STALE   if done_ids: id = done_ids[next() % n]; ren_reply({id, DONE, res = REN_FUZZ_STALE_MAGIC});
                oracle: RELEASE
  5:    BOGUS   id = 8 bytes from next(); if id is not in pending: ren_reply(...); oracle: RELEASE
  6:    STOP    ren_stop(c) (idempotent)
  7:    NOP
end: ren_stop(c); up to 10000 rounds: run every worker (steps 64) with the RUN rule above, then reply
     every pending call CANCELLED; break when every worker returned FINISHED. Not finished → oracle
     failure "no termination" (a lost wakeup or a lost reply).
```

`REN_FUZZ_STALE_MAGIC` is 0x5A1E5A1E. An oracle failure makes
`ren_drv_finish` return a value greater than 0, and the harness aborts,
which is what libFuzzer counts as a crash. The libFuzzer target is
`harness/fuzz/fuzz_target.c`, built with clang
`-fsanitize=fuzzer,address`. `harness/fuzz/fuzz_run.c` is a plain main
that runs a corpus, for builds that can't use libFuzzer: tcc, or Zig's
safe allocator.

---

## §E. The hot path

**The signed rc protocol** (slice.h §2; ren_rt.h:135):
- `rc > 0`: owned by one thread, counted plainly.
- `rc == 0`: immortal.
- `rc < 0`: shared, with `-rc` references.

```
dup(o):  rc = o.rc (plain read: only the owner reads a positive count)
         if rc > 0: o.rc = rc + 1
         elif rc != 0: dup_shared(o)
drop(o): rc = o.rc
         if rc > 1: o.rc = rc - 1
         elif rc == 1: ren_obj_free(o)
         elif rc != 0: drop_shared(o)
dup_shared(o):  xadd32(o.rc, -1, RLX)
drop_shared(o): if xadd32(o.rc, +1, REL) == -1: fence(ACQ); ren_obj_free(o)     // Arc's drop
push(a, v): if a.len == a.cap: grow(a)      // the inline fast path, then the out-of-line grow
            a.data[a.len++] = v
grow(a):    a.cap = a.cap ? 2 * a.cap : 8; a.data = realloc(a.data, a.cap * 8); abort if NULL
```

The plain read of a count that may be negative and shared is the same
read `ren_rt.h` does with `REN_RC_PLAIN_READ`. A shared count only moves
between negative values, so the sign test is stable. The variants
measured by W5:

| # | where dup/drop/push live | debug build (tcc) | release build (clang -O2) |
|---|---|---|---|
| i | `static inline` in slice.h (grow in harness/rt.c, same TU in release) | tcc | clang, one TU |
| ii | harness/hot/hot_c.c, a separate object | tcc | clang, no LTO |
| iii | Rust `extern "C"`, staticlib | tcc links the .a | clang links the .a |
| iv | Zig `export`, static lib | tcc links the .a | clang links the .a |
| v | Rust with cross-language LTO: `-Clinker-plugin-lto` + clang-22 `-flto=thin`, lld-22 | n/a (tcc has no LTO) | clang-22 (LLVM 22.1.8; rustc 1.97 is LLVM 22.1.6) |
| vi | Zig with LTO through `zig cc -flto` compiling the workload too | n/a | zig cc |

Each W5 loop puts `__asm__ volatile("" :: "r"(o) : "memory")` between
the dup and the drop, so the pair can't fold to nothing. The barrier is
the same in every variant.

---

## §F. The planted bugs, exactly

Each plant is one switch (§0.4) and changes only these lines.

| # | where | correct | planted |
|---|---|---|---|
| **P1** | §A.3 `take` and `steal`: the fence between bottom and top | `fence(SC)` in both (Zig: the SC accesses of A.3's substitution) | `fence(AR)` in both (Zig: REL store / ACQ loads). On x86-64 this deletes the `mfence`, so store-load reordering is real on cloud |
| **P2** | §A: the type of `Deque.top`, `Deque.bottom` and every local copy (`b`, `t`) in push, take, steal and grow | `int64_t` / `i64` | `uint64_t` / `u64` (`size_t` as in the paper). `take` on a fresh deque computes `0 - 1` |
| **P3** | §B.4 `ren_reply`: the generation test | `if wd >> 32 != g: RELEASE` | the line deleted: the CAS installs REPLIED on whatever generation the slot holds now (`wd` as loaded), so a stale reply reaches the slot's new occupant |
| **P4** | §B.5 `deliver`: `on_cancel_done` | updates a plain counter | also frees the op record, which the common path then frees again: a double free whenever a cancelled call is delivered |
| **P5** | §B.4 `steal_any`: the thief's count on the victim | `xadd(W[v].stolen_from, 1, RLX)`; the owner reads it with `ld(.., RLX)` at ren_run entry | `stolen_from` is a plain `u64`: thief `W[v].stolen_from += 1`, owner plain read. In Rust this needs `unsafe` or interior mutability, which is the point of the test |

How each one is meant to surface (the table in native-lang §3). The
harness test that exposes it is in brackets.
- **P1**: `deque_stress` (owner push/take plus 3 thieves; every item
  must be taken exactly once; this also runs on real hardware); TSan;
  GenMC (C); loom (Rust).
- **P2**: `deque_stress --empty` (take on a fresh deque must return
  EMPTY); UBSan `-fsanitize=unsigned-integer-overflow`; Rust debug
  overflow panic; Zig ReleaseSafe trap.
- **P3**: `abi_test stale` (a reply to a cancelled-then-reused slot must
  RELEASE); the fuzzer (STALE action); ASan when the stale reply touches
  a freed frame.
- **P4**: `abi_test cancel_race`, `t_io T_CANCEL`, and the fuzzer; ASan,
  the Zig safe allocator, the Rust compiler.
- **P5**: TSan on W1 at 4 workers; the Rust compiler (Send/Sync).

---

## §G. Workloads (harness/workloads)

Every workload is written as Ren's compiler would emit it:
- one frame struct per task, with `pc` as the resume point;
- a `switch (self->pc)` in the resume function;
- every await is "issue, set pc, `return REN_T_PARK`", and resuming
  re-checks.

| W | what | sizes | output compared by replay |
|---|---|---|---|
| W1 spawn | root spawns N children (each holds a dup of the root); each child adds its index to a shared atomic sum and decrements a counter; the last notifies the root | N = 1,000,000 | `sum`, `N` |
| W2 switch | two tasks ping-pong through a shared turn word: write the turn (REL), `ren_notify(other)`, park until it is your turn (ACQ); a stopping task notifies its peer on the way out | 10,000,000 switches | the switch count |
| W3 rtt | PIPE; then per round: WRITE 1 byte, t0, READ 1 byte, t1 (clock_gettime MONOTONIC, off in replay); p50/p99 of t1 - t0 | 200,000 rounds | the checksum of bytes read |
| W4 replay | record W1 and W3 at 1 worker; replay each; compare journal and output | — | byte for byte |
| W5 hot | 400M dup/drop pairs on an owned object (rc > 0) and on a shared one (rc < 0); 100M pushes into arrays of 1,024 grown from 0 | as in §E | — |
| E1 (l4) | W1-W3 release built as one TU (harness + core when the core is C) vs the core as a separate -O2 object without LTO | — | — |

`harness/host_main.c` runs one workload:
`harness <workload> --driver epoll|uring|replay --workers N [--record F] [--replay F] [--steps S]`.
It:
1. starts one pthread per worker, each with an 8 MiB stack whose bounds
   it passes to `ren_thread_init`;
2. runs `ren_drv_worker` on each;
3. joins them;
4. calls `ren_drv_finish` and then `ren_free`;
5. prints one `result:` line (compared by replay) and one `metric:` line
   (timings).

# R2: Completion-based I/O runtimes

Track R2 of the runtime research. It covers how compio, monoio, glommio,
tokio-uring, Seastar, Eio and TigerBeetle drive io_uring and its
fallbacks, and what the kernel itself promises (liburing man pages,
kernel `io_uring/` source, Jens Axboe's wiki). It maps all of that onto
the agreed runtime model: rules 1 (completion-shaped, epoll fallback),
3 (a call's contents belong to the driver until its reply), 4 (a late
reply is released) and 6 (one ring per worker), and onto the draft C ABI.

Sources were read at these revisions: compio master 2026-10-29, monoio
2026-10-15, glommio 2025-04-21, tokio-uring 2025-07-07, Seastar
2026-10-29, liburing 2026-10-27, TigerBeetle 2026-10-14, Linux master
`io_uring/{cancel,msg_ring,kbuf}.c` fetched 2026-10-30. All clones are
in `/tmp/ren-refs/<name>`; the kernel files are in
`/tmp/ren-refs/linux-iouring/`.

## The short version

- **Rule 3 is what every working Rust completion runtime arrived at,
  usually after shipping the bug first.** The operation, with its
  buffer, lives in a heap cell that the driver co-owns until the final
  CQE.
- **Rule 4 is right, but it shouldn't be the normal path.** Ren's own
  docs already say that cancelling waits and never loses a result. Eio
  does exactly that, and it is the better default. Release is for
  replies that have no one waiting for them.
- **Cancellation on io_uring is per ring.** A cancel only finds requests
  in its own ring, and a SINGLE_ISSUER ring rejects submissions from
  any other thread. So the ABI needs a home worker for each call. It is
  the biggest gap in the ABI.
- **Provided buffers change the call's shape.** The reply carries a
  buffer the driver chose. The ABI needs a way to give that lease back,
  from any worker, to the ring that owns it.
- **"Any thread calling `ren_run`" conflicts with SINGLE_ISSUER and
  DEFER_TASKRUN,** which tie a ring to one OS thread.
- **The epoll fallback is required.** Docker 25+ (the default seccomp
  profile), Google production servers, ChromeOS and Android apps all
  block io_uring. TigerBeetle's server still has no fallback and broke
  under Docker 25.

## 1. Who owns the buffer: the Rust drop-while-in-flight problem

A Rust future can be dropped at any `.await`, and drop can't block. If
the future lent `&mut buf` to the kernel, the kernel may write into
freed memory. Every runtime fixed this the same way: the buffer moves
into the operation, and the driver keeps the operation alive until its
CQE arrives, whether or not anyone still wants the result.

- **compio.** An op lives in a reference-counted `ThinCell<RawOp>`
  (`compio-driver/src/key.rs:109-118`), and its pointer is the SQE's
  `user_data`. On push, the driver leaks one reference into the kernel
  and records it in an `in_flight` slot map
  (`sys/driver/iour/mod.rs:345-354`). The completion takes that
  reference back (`poll_entries`, `:278-311`). Dropping the future calls
  `Proactor::cancel` (`compio-runtime/src/future/future.rs:69-76`), which
  only sets a flag and submits `AsyncCancel`. The docs say it plainly:
  "The cancellation is not reliable. The underlying operation may
  continue, but just don't return from poll" (`compio-driver/src/lib.rs:196-215`).
  On shutdown the driver closes the ring fd **before** freeing in-flight
  ops, because closing makes the kernel wait for or cancel them. The
  comment records the heap corruption that happened when it didn't
  (`sys/driver/iour/mod.rs:59-74`, `:512-533`).
- **tokio-uring.** When the op is dropped, its data moves into
  `Lifecycle::Ignored(Box<dyn Any>)` (`src/runtime/driver/op/mod.rs:169`).
  It is freed when the CQE arrives (`:288-297`; `driver/mod.rs:168-201`).
  Dropping an op doesn't submit a cancel at all; cancels are sent only
  when the driver itself is dropped (`driver/mod.rs:377-427`). An
  outstanding accept hangs runtime drop (issue #102). Its "owned buffer"
  API (`BufResult<T, B>`, which hands the buffer back with the result)
  is the user-visible cost of this design.
- **monoio.** The same `Ignored` lifecycle, plus an explicit
  `Canceller`/`CancelHandle` API whose cancelled read still returns its
  buffer (`monoio/src/io/util/cancel.rs:1-80`,
  `io/async_rent_cancelable.rs:10-18`). That makes it "cancel, then wait
  for the reply", the shape Ren wants.
- **glommio.** A source that was queued but never submitted is
  cancelled for free, since the kernel never saw its buffers. One that
  was already dispatched delays freeing until its CQE
  (`glommio/src/sys/source.rs:320-345`).
- **Eio (OCaml, the closest relative).** A cancelled fiber stays
  suspended until the operation's own CQE arrives, so the buffer is
  alive because its owner is still waiting
  (`lib_eio_linux/sched.ml:120-150`, `:243-268`). There's no heap
  hand-off and no `Ignored` state.
- **withoutboats, "Notes on io-uring" (2020)** framed the choice for
  Rust as: the kernel owns the buffer, or drop blocks, or drop leaks
  (https://without.boats/blog/io-uring/; from memory, not re-read).

**For Ren.** Rust needed the heap hand-off because drop can't wait.
Ren's cancellation happens only at dependency calls and is allowed to
wait (async.md, "It waits"; runtime-io.md, "Cancelling waits for the
kernel"), and no task outlives its scope. So Ren can use Eio's model.
The `inout` buffer stays in the waiting task's frame, and "belongs to
the driver until its reply" holds with no reference counts and no
leaking. Rule 3 is right. The prior art says exactly what "its reply"
means:

- **The last CQE, not the first.** A zero-copy send posts a result CQE
  and later a notification CQE. The buffer is the kernel's until the
  notification arrives (`liburing/man/io_uring_prep_send_zc.3`). monoio
  keeps the waker parked in `WaitingMore` until then
  (`monoio/src/driver/uring/lifecycle.rs:105-125`). Multishot operations
  end on the CQE without `IORING_CQE_F_MORE`.
- **A call the driver hasn't taken yet can be retracted.** If the core
  cancels a call that `ren_poll_call` hasn't handed out yet, nothing
  reached the kernel (glommio's `Enqueued` state). The core can drop it
  and reply `Cancelled` itself, with no driver round trip.

## 2. Async cancel semantics, late completions, and what leaks

What the kernel guarantees (`liburing/man/io_uring_prep_cancel.3`,
`io_uring_cancelation.7`):

- A cancel produces **two CQEs**: one for the cancel (0, `-ENOENT` if
  the request already finished, `-EALREADY` if it's too far along) and
  the target's own (`-ECANCELED`, sometimes `-EINTR`, **or a normal
  result**). **Their order isn't guaranteed.** The driver must wait for
  the target's CQE; the cancel's CQE carries nothing Ren needs.
- The kernel side of a cancel runs synchronously. On success the
  target's CQE is posted by the time submission returns. On `-EALREADY`
  "the caller must wait for the canceled request to post its completion
  event".
- **Disk I/O that has reached the device can't be cancelled**
  (`io_uring_cancelation.7`, NOTES). For a regular file read or an
  fsync, a cancel means waiting for it to finish.
- **Closing an fd does not cancel pending io_uring requests on it.**
  Each request holds its own file reference, so a pending recv on a
  closed socket never completes. You have to cancel with
  `IORING_ASYNC_CANCEL_FD | IORING_ASYNC_CANCEL_ALL` first
  (`io_uring_cancelation.7`, "Canceling by file descriptor").
- **A cancel only matches requests in its own ring.**
  `io_cancel_req_match` returns false when `req->ctx != cd->ctx`
  (`linux-iouring/cancel.c:39-44`), and `cd.ctx` is the cancelling
  request's ring (`:237`).
- Alternative: `IORING_OP_LINK_TIMEOUT` lets the kernel cancel one
  linked operation on a deadline.

What leaks when a reply arrives late, by runtime:

| Runtime | Late successful `accept`/`open` | Late provided buffer |
|---|---|---|
| tokio-uring | **fd leaked**: the CQE's `res` is dropped with the `Ignored` box (`op/mod.rs:288-297`) | n/a |
| compio | closed: `set_result` wraps the raw fd in an owned `Socket2` (`sys/op/socket/iour.rs:108-113`). The `OpCode` contract says "The operation stores the result and is responsible to release it if the operation is cancelled" (`sys/driver/iour/op.rs:61-74`) | returned: `set_result` takes it into a `BufferRef` whose drop re-adds it to the ring (`sys/op/managed/iour.rs:60-70`, `:380-400`) |
| monoio | closed: `MaybeFd` closes on drop "when the operation is cancelled, the cancellation failed, the returned result is a fd" (`driver/op.rs:68-137`) | n/a |
| Eio | **not released, delivered**: if `res >= 0` the fiber continues with the result even though it was cancelled, and is cancelled at its next operation (`sched.ml:247-249`) | n/a |

So **rule 4 is the compio and monoio fix, generalized: the driver knows
how to release each reply kind**, and the journal records it. That's
right. Two things need sharpening:

1. **Release vs. "never loses a result".** async.md says "A dependency
   call that finished is never thrown away. A cancel that arrives as a
   read completes lands at the task's next call." That is Eio's rule. It
   matters most for flottning: a WAL `write` or a `send` that completed
   after its cancel **has happened**. Releasing the reply doesn't undo
   the effect; it only loses the knowledge that it happened. The
   writer's offset would then be wrong. So with structured, waiting
   cancellation, a reply normally goes to its task, still waiting.
   Release is only for replies with **no waiter**:
   - the extra CQEs of a cancelled multishot;
   - calls abandoned when the cleanup deadline expires;
   - teardown after a panic or at shutdown;
   - speculative work the driver started itself (prefetch, an armed
     multishot accept).
2. **The decision belongs to the core, the action to the driver.** Only
   the core knows whether a waiter remains. Today `ren_reply` returns
   `void`. It should say "accepted" or "release this". The driver then
   releases (closes the fd, returns the buffer, reaps the process) and
   the core journals `released(call_id)`.

## 3. Provided buffers and memory at many idle connections

Mechanics (`liburing/man/io_uring_provided_buffers.7`,
`io_uring_register_buf_ring.3`, `kernel io_uring/kbuf.c`):

- The application registers a ring of buffers, up to 32768 entries of
  16 bytes each (`struct io_uring_buf { u64 addr; u32 len; u16 bid; u16 resv; }`,
  `liburing/src/include/liburing/io_uring.h:843-848`), per buffer group,
  **per io_uring instance**.
- A recv with `IOSQE_BUFFER_SELECT` names a group, not a buffer. **The
  kernel picks a buffer only when data arrives**, and the CQE carries
  the buffer id in `flags >> 16`. An empty group fails the request with
  `-ENOBUFS`.
- Multishot recv (6.0) plus a buffer ring means one SQE per connection,
  for good. `IOU_PBUF_RING_INC` (6.12) lets one large buffer be consumed
  in pieces.
- Axboe's networking guide says per-connection buffers "don't scale
  very well and lead to excessive memory consumption", and the ring
  form is "vastly more efficient" than the old `PROVIDE_BUFFERS` op
  (https://github.com/axboe/liburing/wiki/io_uring-and-networking-in-2023).

**The memory arithmetic for flottning (100k idle connections).** With a
buffer per request at 64 KiB, there are 6.4 GB pinned for receives that
aren't receiving. With a shared ring per worker, memory is roughly
workers × ring entries × buffer size: 8 × 4096 × 16 KiB = 512 MiB at
most, and only buffers holding unread data are in use. On top of that,
each pending request costs kernel bookkeeping: an `io_kiocb` plus
async-poll state, a few hundred bytes (from memory; E4 measures it). The
kernel's own socket buffers exist either way. E4 should report all three
separately.

**What this means for Ren's call shape.** runtime-io.md already has
"lent" (`&buf`) and "leased" (`Net.chunks`). With a provided buffer,
**the call carries no buffer, and the reply carries a lease the driver
chose**, e.g. `Net.Call.Recv { conn, max }` → `Net.Reply.Chunk(lease)`.
Three consequences:

- **The lease must go back to the ring that owns it.** A buffer ring
  belongs to one io_uring instance. Under `work_stealing`, a chunk
  received on worker A may be dropped on worker B. compio is
  thread-per-core and never faces this. Seastar handles it with
  `foreign_ptr`, which sends the free back to the owning shard (from
  memory). Ren needs a lease-return path that any worker can call and
  that the driver queues to the owning worker. It isn't a world call:
  it has no reply and nothing to replay, so it shouldn't be journaled as
  one.
- **`ENOBUFS` is the driver's backpressure, not a user error.** compio
  surfaces it as `ResourceBusy` (`sys/driver/iour/mod.rs:544-558`). Ren
  should instead re-arm the recv when buffers come back, or fall back to
  `IORING_RECVSEND_POLL_FIRST`. That's async.md rule 4 ("everything has
  a limit") applied in the driver.
- **The fallback gets better, not worse.** compio's poll driver keeps
  the op's buffer through the readiness wait
  (`sys/op/general/poll.rs:87-100`), so an idle connection still holds
  its buffer. An epoll driver answering a lease-shaped recv allocates
  only on `EPOLLIN`, which gives the same memory profile as provided
  buffers. The lease shape is the right one for both drivers.

## 4. One ring per worker, and the flags that bind a ring to a thread

- **One ring per thread is the idiom.** Sharing one "is discouraged"
  (`io_uring_setup_flags.7`, SINGLE_ISSUER), and Axboe's guide says the
  same. compio, monoio, glommio, Seastar and tokio-uring all do it.
  Glommio uses *three* per executor: main, latency (with the eventfd)
  and an IOPOLL ring for NVMe (`glommio/src/sys/uring.rs:1219-1355`).
  Rule 6 is right.
- **`IORING_SETUP_SINGLE_ISSUER` (6.0):** "The submission task is either
  the task that created the ring, or if `IORING_SETUP_R_DISABLED` is
  specified then it is the task that enables the ring... failing
  requests with `-EEXIST`" (`io_uring_setup.2:293-309`).
- **`IORING_SETUP_DEFER_TASKRUN` (6.1)** requires SINGLE_ISSUER, and
  "enforces that the call to io_uring_enter(2) is called from the same
  thread that submitted requests". Completions run only when that thread
  enters with GETEVENTS (`io_uring_setup.2:311-328`). The flags page
  calls it "the default mode for applications setting up a ring".
- **COOP_TASKRUN / TASKRUN_FLAG** are the lighter alternative: no IPI,
  and a flag in the SQ ring tells the application to enter. compio
  exposes all four (`sys/driver/iour/mod.rs:94-115`).

Consequences for the ABI:

1. **"A worker is any thread calling `ren_run`" has to become "a worker
   is driven by one OS thread at a time, the same one for the ring's
   life".** Otherwise a host calling `ren_run(core, 3, ...)` from a
   different pthread gets `-EEXIST` on every submit. There are two
   honest options. (a) The ABI requires a worker id to stay on one
   thread. That's easy for Ren's own `main` and for Workers, which are
   threads anyway. (b) The io_uring driver creates rings with
   `R_DISABLED` and enables each on the first `ren_run` for that worker,
   then asserts the thread never changes. Either way, write it down.
2. **DEFER_TASKRUN makes completion latency equal the budget.** A worker
   running tasks for its whole `budget` doesn't reap its ring
   meanwhile, and no other worker can reap it for it. That's fine, but
   `ren_run`'s budget is now also the I/O latency bound, which E2 and E5
   should state.
3. **Fixed files and buffer groups are per ring.** A registered (direct)
   descriptor exists only in its ring's table
   (`io_uring_registered_files.7`). Under `work_stealing` a migrated
   task's next call is submitted on another worker's ring. So:
   - direct descriptors fit `per_core` and `pinned`, where a connection
     never moves;
   - under `work_stealing` the driver uses plain fds, or routes each
     call to the connection's home ring and pays a cross-worker hop.

   Seastar, glommio and monoio avoid the question by being
   thread-per-core only.
4. **SQPOLL** puts a kernel thread that busy-polls the SQ behind each
   ring, or shared with `ATTACH_WQ`. It saves the submit syscall and
   burns a core. Bursty load pays wake-up latency
   (`io_uring_sqpoll.7`). Seastar's opt-in `asymmetric_io_uring` gives
   SQPOLL dedicated cores (`seastar/src/core/reactor_backend.cc:2133-2160`).
   For Ren it's a driver option, off by default, not a rule. It doesn't
   break "the runtime never creates threads", but it uses a core the
   host has to budget for.
5. **io-wq is the kernel's thread pool.** Buffered writes and fsync
   that can't complete inline are punted to io-wq workers. Their
   unbounded count defaults to `RLIMIT_NPROC`
   (`io_uring_register.2`, `IORING_REGISTER_IOWQ_MAX_WORKERS`, 5.15).
   Rule 2 holds, since Ren creates no threads, but the kernel will, so
   the driver should cap io-wq for flottning's WAL ("everything has a
   limit").

## 5. Waking another worker: MSG_RING vs eventfd

What the runtimes do today:

- **compio:** an eventfd, polled in the ring by a multishot `PollAdd`
  (`sys/driver/iour/notify.rs`, `mod.rs:284-293`, `:463-473`), plus an
  `awake` flag so a waker skips the `write` while the driver is running.
- **monoio:** an eventfd with an atomic `awake` that "Skip[s] wake if
  already awake" (`driver/uring/waker.rs:12-30`).
- **glommio:** an eventfd plus a `should_notify` flag set in
  `prepare_to_sleep`. It writes only if that flag flips
  (`sys/mod.rs:258-350`). Its flag uses `Ordering::Relaxed` on both
  sides (`:309-318`, `:341-349`). The sleep/wake handshake is Dekker's
  pattern, which needs SeqCst or a fence, so this looks like a
  lost-wakeup window. This is my reading of the code, not a confirmed
  bug.

The io_uring-native option:

- **`IORING_OP_MSG_RING` (5.18)** posts a CQE carrying 32 + 64 bits on
  another ring (`io_uring_prep_msg_ring.3`). It needs a source ring.
  With `MSG_RING_FD` (6.0) it can also hand a (direct) fd between rings,
  which is how a `per_core` acceptor would pass a connection to another
  core.
- **`IORING_REGISTER_SEND_MSG_RING` (6.13)** does the same with **no
  source ring** (`io_uring_register.2:983-...`;
  `linux-iouring/msg_ring.c:335-358`). That matters for Ren: blocking
  pool threads and host threads calling `ren_reply` have no ring.
- The target ring receives the message as a CQE through task work
  (`msg_ring.c:83-128`). That is cheap when the target is waiting in
  `io_uring_enter` and deferred when it's busy under DEFER_TASKRUN.

**For Ren.** The `wake(host, worker)` hook is the right cut: the
driver chooses MSG_RING, SEND_MSG_RING, an eventfd or a futex. Two
things to settle:

- **The core calls `wake` only when the target is parked.** All three
  runtimes skip the syscall otherwise, and the parked flag follows the
  SeqCst protocol: a worker sets "sleeping", re-checks its queue, then
  sleeps; a waker pushes, then checks "sleeping". The core owns that
  flag, since it knows when `ren_run` returned `idle`.
- **MSG_RING can carry the reply itself,** not just a wake. A reply for
  a task homed on worker B, arriving on A's ring, could be posted
  straight into B's CQ. E5 should measure that against "push to B's
  queue, then wake".

## 6. Readiness backends emulating completion

**compio's poll driver** (`sys/driver/poll/mod.rs`, `sys/driver/poll/op.rs`)
is the cleanest design to copy:

- **The same op on every backend.** An op implements one trait per
  backend. On the poll backend, `pre_submit` returns a `Decision`:
  - `Completed(n)`: answered inline;
  - `Wait(fd, interest)`;
  - `Blocking`: go to the thread pool;
  - `Aio`: POSIX AIO, on FreeBSD (`poll/op.rs:13-27`, `:45-80`).
- **The syscall is tried first.** Sockets call the syscall
  optimistically and wait only on `EAGAIN`
  (`decide(fd, Readable, || self.call())`, `sys/op/socket/poll.rs:66-80`).
  io_uring's `IORING_RECVSEND_POLL_FIRST` is the opposite hint.
- **Per fd, one FIFO queue per direction.** The fd is registered
  oneshot with the interest of the queue heads and renewed after each
  event (`poll/mod.rs:21-130`, `:409-445`). An op that still gets
  `EAGAIN` goes back to the front of the queue.
- **Cancel is synchronous and always succeeds,** since the kernel holds
  nothing: remove the interest, post a cancelled entry
  (`poll/mod.rs:262-293`).
- **Files go to the blocking pool** (Linux, macOS) or AIO (FreeBSD)
  (`sys/pal/poll/aio.rs:49-96`). Fs metadata ops are all `Blocking`
  (`sys/op/fs/poll.rs`).

monoio's legacy driver does the same with per-op `legacy_call`
(`driver/legacy/`). Seastar's epoll backend is the last entry in its
selector list (`reactor_backend.cc:2650-2665`). TigerBeetle's
`linux_epoll.zig` covers network only: "Disk operations ... are not
implemented; clients never open or write data files" (`src/io/linux_epoll.zig:1-9`).

**For Ren:** compio's `Decision` lines up with the model.

- `Completed` is `answer_now`.
- `Wait` is the readiness emulation.
- `Blocking` is "a blocking call answered by the driver's pool".

The core needs none of it. That is the sans-I/O claim, confirmed in a
shipping runtime.

## 7. Why io_uring is disabled, and detecting it

**Who disables it:**

- **Google.** 60% of kCTF VRP submissions in the year to June 2023
  exploited io_uring. Google disabled it on ChromeOS and on its
  production servers, and Android blocks it for apps with seccomp
  (Google Security Blog, June 2023,
  https://security.googleblog.com/2023/06/learnings-from-kctf-vrps-42-linux.html;
  that page's body didn't render here, so this is per
  https://www.phoronix.com/news/Google-Restricting-IO_uring and
  https://seclists.org/oss-sec/2023/q2/235).
- **Docker 25.0** removed `io_uring_setup/enter/register` from the
  default seccomp profile (https://github.com/moby/moby/pull/46762). The
  user-visible symptom is "operation not permitted"
  (https://github.com/moby/moby/issues/47532).
- **The `kernel.io_uring_disabled` sysctl** (6.6, backported by Ubuntu):
  - 1: creation fails with `EPERM` unless the process is in
    `kernel.io_uring_group` or has CAP_SYS_ADMIN;
  - 2: `io_uring_setup` always fails with `EPERM`;
  - rings that already exist keep working
    (https://patchew.org/linux/x49wmxuub14.fsf@segfault.boston.devel.redhat.com).
- New kernels also let a ring be narrowed with
  `IORING_REGISTER_RESTRICTIONS` or a BPF filter, so a ring can be
  created and still refuse some opcodes (`io_uring_register.2:534-547`).

**How the runtimes detect it:**

- **compio:** creates a 2-entry ring and runs `register_probe`. If that
  fails, or a required opcode is missing, it uses the poll driver and
  logs a warning (`sys/pal/iour/mod.rs:9-24`, `driver_type.rs:13-28`,
  `sys/driver/fusion/mod.rs:24-45`). It also falls back **per op**: an
  unsupported opcode tries `create_entry_fallback`, then the blocking
  pool (`sys/driver/iour/mod.rs:390-426`).
- **monoio:** probes a fixed list of opcodes, and
  `MONOIO_FORCE_LEGACY_DRIVER=1` forces the fallback
  (`utils/uring_detect.rs:15-80`).
- **Seastar:** requires `IORING_FEAT_SUBMIT_STABLE | IORING_FEAT_NODROP`
  plus a list of ops. It also refuses io_uring on old kernels with md
  RAID, or with `RLIMIT_MEMLOCK` under 8 MB (`reactor_backend.cc:1236-1330`).
- **TigerBeetle's server** refuses to start, with a diagnosis: `ENOSYS`
  → "likely cause: the syscall is disabled by seccomp", `EPERM` → "try
  `sysctl -w kernel.io_uring_disabled=0`" (`src/io/linux.zig:46-57`,
  `:1826-1828`).

**For Ren:**

- Pick the driver once in `ren_start` by probing.
- Treat `ENOSYS`, `EPERM` and a missing required opcode or feature the
  same way: fall back to epoll.
- Record the chosen driver and kernel features in the journal header.
- Give an environment override like monoio's.

Set a kernel floor and fall back below it, rather than carry
per-feature paths:

| Feature | Since |
|---|---|
| DEFER_TASKRUN | 6.1 |
| buffer rings | 5.19 |
| multishot recv | 6.0 |
| `IOU_PBUF_RING_INC` | 6.12 |
| SEND_MSG_RING | 6.13 |

A 6.1 floor keeps the io_uring driver to one shape.

## 8. Blocking pools for files, especially on macOS

- **macOS has no usable async file I/O.** compio sends file ops to its
  `AsyncifyPool`: up to 256 threads, which exit after 60 s idle
  (`compio-driver/src/lib.rs:536-548`, `asyncify.rs`).
- **The pool can't cancel anything.** Cancelling a pool op only marks
  it, and the thread runs to completion (`sys/driver/iour/mod.rs:428-442`).
- **TigerBeetle on Darwin** does `pread` inline on the loop thread
  (`src/io/darwin.zig:583-630`). It's a development platform for them.
- **Darwin's `fsync` doesn't flush the disk cache; `F_FULLFSYNC` does**
  (`darwin.zig:1115-1122`). This is a correctness requirement for
  flottning's WAL on macOS: the real `Fs.sync` driver must use it.
- **Go** has no pool. A goroutine blocked in a syscall keeps its thread,
  and `sysmon` hands the P to another thread after at least 20 µs
  (`go/src/runtime/proc.go:6693-6760`).
- **libuv and tokio** use bounded pools (libuv defaults to 4 threads,
  tokio's `spawn_blocking` to 512; from memory).

**For Ren.** "The runtime never creates threads" survives because the
pool belongs to the **driver**: the default host's driver creates it,
and an embedding host may supply its own. Pool size is a limit (async.md
rule 4) and should be explicit, like io-wq's cap. A cancelled pool call
waits for the call to finish, which is "cancelling waits" again. A pool
call that outlives the cleanup deadline is the one case where release
is the normal path.

## 9. Smaller things worth copying

- **Teardown order:** cancel everything (`IORING_ASYNC_CANCEL_ANY | ALL`),
  reap, release, then close the ring. Closing the ring makes the kernel
  give up every buffer (`io_uring_cancelation.7`, "Shutdown cancelation";
  compio's `Drop`). tokio-uring's hang on drop (#102) is what happens
  without it. **The ABI has no teardown call** (`ren_stop`/`ren_free`).
- **Batching:** compio drains completions when the SQ is full and
  retries (`sys/driver/iour/mod.rs:356-388`). Ren's driver loop is:
  1. `ren_run(budget)`;
  2. drain `ren_poll_call` into SQEs;
  3. one `io_uring_enter(submit, wait=1, timeout = ren_poll_deadline)`;
  4. reap CQEs into `ren_reply`.

  That is runtime-io.md's "one submission, many calls" with no extra
  machinery.
- **`IORING_ENTER_NO_IOWAIT` (6.15):** an idle ring shouldn't show up as
  iowait in `top` (compio `sys/driver/iour/mod.rs:42-56`). It's
  cosmetic, but operators notice.
- **Zero-copy send** needs the buffer until a second CQE, and pays off
  only for large payloads, starting around tens of KB per Axboe and
  Begunkov's measurements (from memory). Not a 1.0 need for flottning's
  small responses. Rule 3 already covers it if it comes.

## What Ren should take, refuse, or still decide

1. **Take rule 3 as written, and define "reply" as the final CQE.** For
   multishot that's the CQE without `F_MORE`; for a zero-copy send it's
   the notification. With waiting cancellation, the `inout` buffer stays
   in the waiting task's frame, as in Eio (`sched.ml:243-268`). That
   avoids Rust's heap hand-off (compio `key.rs`, tokio-uring
   `Lifecycle::Ignored`), which exists only because Rust's drop can't
   wait.

2. **Rule 4 is right, but as written it's the wrong default. Fix the
   wording.** async.md promises "never loses a result" and runtime-io.md
   "cancelling waits", and Eio implements both (`sched.ml:247-249`). A
   cancelled call's reply goes to its still-waiting task, and a success
   lands; the task stops at its next call. Releasing is only for replies
   with **no waiter**: multishot leftovers, calls abandoned after the
   cleanup deadline, panic or shutdown teardown, and the driver's own
   speculative work. Otherwise a WAL write that completed after its
   cancel gets "released", and the writer never learns its bytes are on
   disk.

3. **ABI: `ren_reply` should return "accepted" or "release".** The core
   alone knows whether a waiter remains; the driver alone knows how to
   release (close an fd, return a lease, reap a child). This is compio's
   `set_result` contract (`iour/op.rs:61-74`) and monoio's `MaybeFd`,
   split along the sans-I/O cut. The core journals `released(call)`.

4. **Missing from the ABI: a call's home worker.** `ASYNC_CANCEL` matches
   only its own ring (`cancel.c:43`), and SINGLE_ISSUER rejects other
   threads (`io_uring_setup.2:293-309`). So a cancel, and a lease
   return, must be handed to the worker that submitted the call, not the
   one running the cancelling task. `ren_call` needs a stable id and its
   home worker, and `ren_poll_call(worker)` must route cancels there.
   Also: if the core cancels a call no driver has polled yet, retract it
   in the core (glommio's `Enqueued`).

5. **Wrong as written: "a worker is any thread calling `ren_run`".** With
   the io_uring driver, a worker id must be driven by one OS thread for
   the ring's life. The other option is to create rings `R_DISABLED` and
   enable each on its worker's first `ren_run`. State it in the ABI.
   Also state that under DEFER_TASKRUN, `ren_run`'s budget bounds that
   worker's I/O completion latency, since no one else can reap its ring.

6. **Take the leased-reply shape for network receives, and add a
   lease-return path.** `Net.Call.Recv { conn, max }` → a reply carrying
   a driver-chosen buffer. That's provided buffers on io_uring and
   allocate-on-`EPOLLIN` on epoll, with the same memory profile on both.
   The return goes to the owning ring from any worker and isn't a
   journaled world call. `ENOBUFS` is handled inside the driver
   (re-arm, poll-first), never surfaced. E4 should measure kernel
   per-request state and socket buffers separately from Ren's pool.

7. **Rule 6 stands. Fixed files and buffer groups go with it.** Direct
   descriptors and buffer rings are per ring. Use them under `per_core`
   and `pinned`, and default to plain fds under `work_stealing`. Measure
   in E5 before routing calls to a connection's home ring.
   `MSG_RING_FD` is how a `per_core` acceptor hands a connection to
   another core.

8. **Keep `wake(host, worker)` as the only cross-worker hook, and
   specify its protocol.** The core calls it only for a parked worker,
   using a SeqCst sleep/wake handshake (all three Rust runtimes skip the
   syscall when the target is awake; glommio's `Relaxed` flag shows how
   easy it is to get wrong). Drivers implement it with:
   - `MSG_RING` from a thread with a ring;
   - `IORING_REGISTER_SEND_MSG_RING` (6.13) from pool or host threads;
   - an eventfd or a futex otherwise.

   E5 should also try posting the reply itself through MSG_RING.

9. **Detect once, fall back whole, and journal the choice.** Probe in
   `ren_start`: create a small ring and check the required ops and
   features (compio, Seastar). On `ENOSYS`, `EPERM`, or a missing op,
   use epoll and log why (TigerBeetle's messages are the model). Give an
   environment override. Put the driver and kernel features in the
   journal header. Set one kernel floor for the io_uring driver (6.1, for
   DEFER_TASKRUN), not per-feature branches. Don't follow TigerBeetle's
   server in having no fallback: Docker 25, GKE and Google prod all
   block io_uring, and that rules it out for flottning.

10. **Close must cancel.** Closing an fd doesn't cancel io_uring requests
    on it (`io_uring_cancelation.7`). The real driver's `Close` should
    submit `ASYNC_CANCEL_FD | ALL` on the home ring before the close.
    Sim drivers should copy that behaviour, so tests can't pass on
    semantics the real driver lacks.

11. **The blocking pool and io-wq are the driver's, and both are
    limits.** "The runtime never creates threads" holds because the pool
    belongs to the driver, or to the host. Make the pool size and the
    io-wq cap (`IORING_REGISTER_IOWQ_MAX_WORKERS`) explicit
    configuration. On macOS, `Fs.sync` must be `F_FULLFSYNC`
    (TigerBeetle `darwin.zig:1115-1122`), or flottning's WAL isn't
    durable there.

12. **Add teardown to the ABI** (`ren_stop`/`ren_free`). It must cancel
    everything, reap, release and journal before the ring closes.
    Without it, a host can't shut down cleanly (compio's `Drop` order,
    tokio-uring #102).

13. **Refuse for 1.0:**
    - SQPOLL as a default; it's an opt-in driver option at most;
    - zero-copy send; flottning's replies are small;
    - IOPOLL rings, glommio's third ring; they need O_DIRECT and NVMe
      poll queues;
    - link timeouts as the way `Async.timeout` works; timeout is std,
      over the cancel primitive.

    None of these change the core or the ABI. They're driver
    optimizations to add later.

14. **Still to decide:**
    - Does a cancelled *pool* call (or a disk read the kernel can't
      cancel) wait past the 5 s cleanup deadline, or is it abandoned and
      released? I lean toward abandoning and releasing, with a journal
      entry and a metric, since flottning's shutdown shouldn't hang on
      a stuck NFS read.
    - What does `sim` model for a reply racing its cancel? The race
      decides whether the effect happened, so `sim` should choose
      between "Cancelled" and "the result" from the tape, and replay
      reads the journal's answer.

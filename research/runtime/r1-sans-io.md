# R1: Sans-I/O cores, and what they say about Ren's runtime ABI

Track R1 of the runtime research. It studies five libraries that keep their
protocol logic free of I/O, and maps what they learned onto the draft C ABI
(`ren_start`, `ren_run`, `ren_poll_call`, `ren_reply`, `ren_poll_deadline`,
`ren_host`).

Sources, all shallow clones in `/tmp/ren-refs` (commit in brackets):

- **quinn-proto**, QUIC (`quinn` 2697de1)
- **str0m**, WebRTC (`str0m` dc31717)
- **rustls**, TLS (`rustls` 44323f5; this is 0.24-dev, and the 0.23 "unbuffered" API comes from docs.rs)
- **h11** and **h2**, Python HTTP/1.1 and HTTP/2 (`h11` 62c5068, `h2` 8380ac7)
- **s2n-quic**, AWS QUIC (`s2n-quic` a70ae14)

Paths below are relative to `/tmp/ren-refs`.

One difference from Ren runs through the whole report. These libraries are
sans-I/O *protocol* machines: the caller is the event loop, and the core is a
passive object. Ren's core is a sans-I/O *scheduler*: the caller is a driver,
and the core runs user code. The mapping still holds well:

| Ren | Prior-art counterpart |
|---|---|
| `ren_reply` | `handle_event` / `handle_input` / `receive_data` |
| `ren_poll_call` | `poll_transmit` / `poll_output` / `data_to_send` |
| `ren_poll_deadline` | `poll_timeout` |
| `ren_run(now, budget)` | `handle_timeout(now)` plus the driver's bounded drain loop |
| `ren_host.wake` | the Rust `Waker` that the async wrappers store |

---

## 1. How they split the boundary

### quinn-proto: many narrow functions

quinn-proto calls itself "a fully deterministic implementation of QUIC
protocol logic. It contains no networking code and does not get any relevant
timestamps from the operating system" (`quinn/quinn-proto/src/lib.rs:1-5`).
A `Connection` has six entry points, each with one job:

- **Inputs:** `handle_event(ConnectionEvent)` (`connection/mod.rs:1145`) and
  `handle_timeout(now)` (`:1217`).
- **Outputs:** `poll_transmit(now, max_datagrams, &mut buf) -> Option<Transmit>`
  (`:466`), `poll() -> Option<Event>` for the application (`:402`) and
  `poll_endpoint_events()` for the endpoint that owns the connection (`:420`).
- **Deadline:** `poll_timeout(&self) -> Option<Instant>` (`:392`).

Each output's doc comment lists exactly which inputs can change it. For
example, `poll_timeout` may change after "the application performed some I/O,
a call was made to `handle_event`, a call to `poll_transmit` returned `Some`,
a call was made to `handle_timeout`" (`:384-390`). `handle_timeout` says
"spurious extra calls will simply no-op and therefore are safe"
(`:1209-1216`).

The `Endpoint` and its `Connection`s are two machines that exchange
`EndpointEvent` and `ConnectionEvent` values explicitly
(`endpoint.rs:102-142`). That split exists so that connections can be driven
in parallel, with only a small shared part.

### str0m: one input enum and one output enum

str0m has a single input enum, `Input::{Timeout(Instant), Receive(Instant, Receive)}`,
and a single output enum, `Output::{Timeout(Instant), Transmit, Event}`
(`str0m/src/lib.rs:1093-1111`). Its loop contract is written as six steps
(`lib.rs:151-166`):

1. Wait for something to happen.
2. Do one mutation.
3. Call `poll_output`.
4. Handle what it returned.
5. Repeat from step 3 until it returns `Output::Timeout`. "Only then is the engine fully drained."
6. Wait on the deadline it returned.

`Output::Timeout` therefore does two jobs: it is the deadline, and it means
"nothing more right now".

### rustls: from callbacks to caller-owned buffers

rustls moved in three stages, each further from I/O:

- **The classic API** (`read_tls(&mut dyn Read)`, `process_new_packets`,
  `write_tls(&mut dyn Write)`, `wants_read`/`wants_write`) takes I/O trait
  objects. This is from memory and unverified against source.
- **0.23 added an "unbuffered" API.** `process_tls_records` returns a state enum:
  `ReadTraffic`, `EncodeTlsData`, `TransmitTlsData`, `BlockedHandshake`,
  `WriteTraffic`, `PeerClosed`, `Closed` (docs.rs `rustls/0.23.31/rustls/unbuffered/enum.ConnectionState.html`).
  The caller owns both the incoming and the outgoing buffer. Each state
  says exactly what the caller must do next. `TransmitTlsData` data "MUST not
  be sent to the peer more than once", and the caller then calls `done()`.
- **0.24-dev makes the handshake a typestate.** `NeedsInput::process(input, tls)`
  consumes itself and returns the next state (`rustls/src/conn/mod.rs:503-530`).
  After the handshake, `read_tls(input, tls)` returns a `MessageHandler` that
  "must be driven to completion" (`:116-123`, `:353-392`).

### h11 and h2: bytes in, events out, bytes back

- **h11:** `receive_data(bytes)` only buffers (`h11/h11/_connection.py:364-405`).
  `next_event()` returns an event, `NEED_DATA` or `PAUSED` (`:438-500`).
  `send(event)` returns bytes. `send_failed()` tells the machine that the
  bytes it produced never went out (`:577`).
- **h2:** `receive_data(data) -> list[Event]` (`h2/src/h2/connection.py:1501`)
  and `data_to_send(amount)` (`:1398-1419`). h2 has **no notion of time at all**:
  there are no timers, so keepalive and idle timeouts are left to every user.

### s2n-quic: one core under several pluggable I/O providers

The `Endpoint` trait has `receive(rx_queue, clock)`, `transmit(tx_queue, clock)`,
`poll_wakeups(cx, clock)` and `timeout()` (`s2n-quic/quic/s2n-quic-core/src/endpoint/mod.rs:92-137`).
One generic `EventLoop` (`io/event_loop.rs:70-190`) runs it under tokio, a
seeded testing executor, turmoil and XDP (`s2n-quic-platform/src/io/{tokio,testing,turmoil,xdp}.rs`).
This is the same architecture as Ren's "one core under several drivers".

### Why several functions beat one `step`

These libraries split input, output, timeout and events for four reasons:

- **Each output has its own consumer and its own arguments.** `poll_transmit`
  needs `now`, a reusable buffer and a GSO limit. `poll_timeout` is `&self`
  and pure. Application events go somewhere else entirely.
- **Inputs and outputs are counted independently.** One datagram in can mean
  zero or twenty out. A single `step(input) -> outputs` has to allocate a
  list of outputs, or impose a fixed batch.
- **Pull gives backpressure for free.** quinn's driver asks for a transmit
  only when the socket can take one. When `poll_send` returns `Pending`, it
  keeps the transmit for later (`quinn/quinn/src/connection.rs:1224-1256`).
  s2n-quic does the same with its tx queue's `capacity()` (`io/tx.rs:102-109`).
- **A pure deadline query is cheap.** The driver can ask for it without
  mutating anything.

str0m's single output enum fixes the cost of many functions. With quinn the
driver must remember to drain every output queue, in the right order, and
loop: "If a timer expires, there might be more to transmit. When we transmit
something, we might need to reset a timer. Hence, we must loop until neither
happens" (`quinn/src/connection.rs:280-283`). With str0m there is one drain
loop, and it ends at a well-defined point.

**Lesson for Ren.** The draft is already quinn-shaped:

- `ren_reply` is the input.
- `ren_run` is "advance".
- `ren_poll_call` is the output.
- `ren_poll_deadline` is the deadline.

That is right for a scheduler, but it needs str0m's discipline: a written
drain contract, and a single "you're drained" signal.

---

## 2. Who owns buffers across the boundary

There are four patterns, from simplest to fastest.

1. **The core owns its buffers and copies in and out** (h11, h2).
   - It is simple and cannot dangle.
   - It costs a copy each way.
   - Its traps are real. h11's `ReceiveBuffer` exists because naive
     front-deletion made parsing quadratic, which is a denial-of-service risk:
     "reading short segments out of a long buffer MUST be O(bytes read)"
     (`h11/h11/_receivebuffer.py:8-35`).
   - Zero-copy had to be added back later as `send_with_data_passthrough`,
     for sendfile (`_connection.py:544`).
2. **The caller lends a buffer for the duration of one call** (quinn
   `poll_transmit(.., buf: &mut Vec<u8>)`, `connection/mod.rs:466`).
   - The driver reuses one allocation, and the core writes into it.
   - rustls 0.24 goes further on input with `TlsInputBuffer`
     (`rustls/src/conn/receive.rs:1113-1148`):
     - The caller owns the bytes.
     - The core decrypts *in place*, so "the contents of this buffer must not
       be altered except to add new bytes at the end".
     - The core reports consumed bytes back through `discard(n)`.
     - Plaintext comes back as `Payload<'_>`, borrowing the input
       (`conn/mod.rs:409-431`).
   - The 0.23 unbuffered API reports a too-small output buffer as
     `EncodeError::InsufficientSize`; that it carries the required size is
     from memory.
3. **The driver owns slots and lends them to the core** (s2n-quic).
   - On receive, `rx::Queue::for_each` lends `&mut [u8]` for in-place
     decryption (`io/rx.rs:55`).
   - On transmit, the core never gets a buffer of its own: it pushes a
     `Message` whose `write_payload(PayloadBuffer)` writes straight into the
     driver's slot (`io/tx.rs:88-92`, `:135-160`).
   - This is what lets the same core feed an XDP ring or GSO batches without
     a copy.
4. **Ownership moves into the core** (quinn `Endpoint::handle(.., data: BytesMut, ..)`, `endpoint.rs:144-152`).
   - A refcounted buffer is handed over.
   - That lets the core split coalesced packets without copying.

In all four, **every lend is synchronous: it lasts one function call**. None
of these libraries lends memory across asynchronous time, because none of
them does completion I/O. Ren's rule ("a call's contents belong to the driver
until its reply") is the io_uring rule, and the prior art offers no help with
it, except for one thing: **memory that is returned is returned explicitly,
and the core says how much it consumed.** Examples:

- rustls `discard(n)`
- h2 `acknowledge_received_data(size, stream)`, a credit returned only once
  the application has *processed* the data, not when it arrived (`connection.py:1345-1396`)
- the rustls 0.23 `TransmitTlsData::done()`
- h11 `send_failed()`

Ren needs the same kind of explicit hand-back for driver-provided buffers.
See items 6 and 7 at the end.

---

## 3. How a core says "poll me again"

- **Inside the core.** str0m keeps a `Readiness` dirty flag that is armed on
  every mutable access. "The safe default is to re-poll... A forgotten
  narrowing or an over-broad wake costs at most one redundant poll; it can
  never drop output" (`str0m/src/poll.rs:1-25`). In other words, a spurious
  wake is cheap and a lost wake is a bug, so the default leans spurious.
- **At the boundary.** The sans-I/O cores have no wakers at all: whoever
  mutated the core simply polls it. Wakers live in the async wrapper.
  - quinn's `ConnectionDriver` stores one `Waker`, and `wake()` takes and
    fires it (`quinn/src/connection.rs:1415-1419`).
  - When the driver stopped early because of its budget, it re-arms itself
    with `cx.waker().wake_by_ref()` (`:287-295`).
- **Bounded work, with a semantic cost.** quinn produces at most
  `MAX_TRANSMIT_DATAGRAMS = 20` per drive, "so that other tasks (like
  receiving ACKs) can run in between" (`:1523-1527`). There is a TODO: when
  the bound cuts in, quinn never enters `app_limited` and the congestion
  window keeps growing (`:1259-1264`, quinn issue #1126). The budget changed
  protocol behaviour. Ren has the same risk, with `budget` changing schedule
  order.
- **Spin before sleeping.** s2n-quic's `Cooldown` loops a few more times
  after `Pending` before it really parks, which saves wake syscalls under
  load (`s2n-quic-core/src/task/cooldown.rs:11-52`).
- **Event-loop telemetry.** s2n-quic publishes a wakeup event (whether rx,
  tx, timer or application woke it) and a sleep event (the timeout, and how
  long the iteration took) on every iteration (`io/event_loop.rs:112-125`, `:174-186`).
  This is exactly what Ren's journal and `--trace` will want from drivers.

---

## 4. How time is supplied

Every library splits two clocks:

- **Monotonic time is pushed in as an argument.** quinn passes `now` into
  `handle`, `handle_event`, `poll_transmit` and `handle_timeout`. str0m stamps
  every `Input` with an `Instant`: a receive's instant "drives time forward
  when more recent than the last 'now' the instance has seen"
  (`lib.rs:1096-1099`). The cores never read a clock, so a recorded run
  replays exactly.
- **Wall time is pulled through an injected callback.** quinn has
  `TimeSource::now() -> SystemTime`, used for retry-token expiry
  (`quinn-proto/src/config/mod.rs:357-363`, `:669-686`). rustls has
  `TimeProvider::current_time() -> Option<UnixTime>`, used for certificate
  validity: "not required to be monotonic... Return `None` if unable"
  (`rustls/src/time_provider.rs:11-18`).
- **s2n-quic passes a `Clock` capability** instead of a value
  (`time/clock.rs:19-28`), and its loop reads it several times per iteration.

Ren's draft already has both shapes:

- Wall time arrives as a `Clock.now` reply through `answer_now`, which is the
  rustls and quinn `TimeSource` shape.
- Monotonic time arrives as `now_ns` on `ren_run`, which is the quinn and
  str0m shape.

But the model says "time is a reply (core never reads a clock)". `now_ns` is
a second way for time to get in, and it isn't a reply. It is fine *only if it
is journaled* whenever it fires a timer. Otherwise replay depends on when
the driver happened to call `ren_run`. See item 3.

### What goes wrong with time

Every bug in this list is a deadline at or before `now`, which makes the
driver spin.

- str0m's changelog has several:
  - "Fix hot timeout loop with null pacer #863" (`str0m/CHANGELOG.md:184`)
  - "Fix an infinite loop when DTLS timeout handling fails #1017" (`:96`)
  - "Stop SSRC 0 probes from repeatedly scheduling an immediate RTCP feedback timeout #1052" (`:58`)
  - "Provide reason for timeout #520" (`:402`), added so that a spinning loop
    could be diagnosed
- str0m's own test harness forces time forward when a deadline equals
  `last`, "to prevent the test from getting stuck when RTC has no pending
  timeouts" (`tests/common.rs:122-127`, `:345-354`).
- quinn checks the clock itself rather than trusting tokio's `Sleep`,
  because "Sleep::poll respects Tokio's cooperative budget and can return
  Pending for elapsed deadlines" (`quinn/src/connection.rs:1376-1384`).

---

## 5. How they are tested

- **Two machines and a virtual clock.**
  - quinn's `Pair::step` drives the client and the server, then advances
    virtual time to whichever `next_wakeup` (deadline or next inbound packet)
    comes first. `drive_bounded` fails a test that never goes idle
    (`quinn-proto/src/tests/util.rs:86-131`, `:413-460`).
  - str0m's tests put `Netem`, a network emulator that is *itself* sans-I/O
    (`handle_input`/`poll_output`), between two `Rtc`s (`tests/common.rs:297-340`).
    The chaos is a sans-I/O machine too.
- **A seeded executor.** s2n-quic's testing provider runs on `bach` with
  `Scope::new(seed)` for randomness (`s2n-quic-platform/src/io/testing.rs:70-80`).
  It advances time only after a "stalled" macrostep, and panics after 100
  stalls ("the runtime stalled after 100 iterations", `:170-195`). Chaos sits
  at two levels:
  - `havoc` mutates frames from a seeded RNG (`s2n-quic-core/src/havoc.rs`).
  - `packet::interceptor` rewrites received ACKs, addresses and loss
    (`s2n-quic-core/src/packet/interceptor.rs`).

  This matches Ren's two layers: scoped chaos is a handler over a
  dependency, and world chaos is the sim driver.
- **Fuzzing is trivial because the input is bytes plus time.**
  - quinn: `fuzz/fuzz_targets/{streams,packet,params,streamid}.rs`.
  - str0m: twelve targets under `crates/fuzz/fuzz_targets/`.
  - rustls feeds its API from a cursor (`fuzz/fuzzers/server.rs`), with a
    `CryptoProvider` that "provides NO SECURITY and is for fuzzing only" so
    that randomness and crypto are deterministic (`rustls-fuzzing-provider/src/lib.rs:29`).
  - h11: `fuzz/afl-server.py`.

### Determinism leaks anyway

quinn-proto promises full determinism, but:

- BBR seeds its RNG with `Pcg32::from_rng(&mut rand::rng())`
  (`quinn-proto/src/congestion/bbr/mod.rs:101`).
- The endpoint falls back to `SysRng` when no `rng_seed` is configured
  (`endpoint.rs:75-78`).

A library can only *promise* that it never touches ambient randomness. Ren's
compiler can *enforce* it, since `Random` is a dependency. This is a real
advantage, and worth stating in the docs.

---

## 6. What goes wrong in practice (summary)

1. **A deadline at or before `now` makes the driver spin.** This is the most
   common bug class (section 4).
2. **The driver forgets to drain a queue, or drains in the wrong order.**
   quinn needs a fixpoint loop, and str0m collapses everything into one
   drain-until-Timeout loop.
3. **A work budget leaks into semantics.** quinn's `app_limited` TODO.
4. **The core fails while output is still pending.**
   - rustls: when processing fails, "any alert produced by the error will
     have been appended to the `tls` buffer; most likely you will want to
     send that data" (`conn/mod.rs:385-391`). Output must be drained even
     after an error.
   - h11: `send_failed()` exists because the core assumed its bytes left.
5. **Overloaded sentinels.** h11 `receive_data(b"")` means EOF, and has to
   warn about APIs where an empty read is valid (`_connection.py:374-386`).
6. **Leaving time out of the core.** h2 has no timers, so every user
   reinvents keepalive and idle timeouts outside it.
7. **Lock contention around the core.** quinn wraps each `Connection` in a
   mutex that both application tasks and the driver take
   (`quinn/src/connection.rs:268`). Its answer is to split endpoint from
   connection and pass explicit events between them.

---

## What Ren should take, refuse, or still decide

1. **Take: a written drain contract for `ren_run` and `ren_poll_call`**,
   modelled on str0m's six steps and quinn's "may change after" lists.
   - After any `ren_run` that returns, the driver drains `ren_poll_call`
     until it returns false, and only then reads `ren_poll_deadline`.
   - `ren_poll_call` returning false is the single "drained" signal, like
     str0m's `Output::Timeout`.
   - A debug build should assert that the driver drained before it calls
     `ren_run` again.
2. **Take: pull-based output as the backpressure mechanism.**
   `ren_poll_call` is pull, like `poll_transmit` and the s2n-quic tx queue.
   The rule should be stated: a driver whose submission queue is full simply
   stops pulling. The core never needs a "queue full" error.
   Also make "may the driver hold a pulled call and submit it later?"
   explicitly yes. That is quinn's `buffered_transmit`.
3. **Decide (the model is inconsistent here): time enters two ways.** It
   arrives as `ren_run`'s `now_ns` and as `Clock` replies. The prior art says
   time must be an input recorded with the input. Choose one:
   - **(a) Timers are calls.** `sleep_until` is a world call that the driver
     answers. Deadlines ride as a *field* of other calls, as io_uring linked
     timeouts and Go's `SetReadDeadline` do, so a per-request idle timeout is
     not a call plus a cancel per read. `ren_run` loses `now_ns`, and
     `ren_poll_deadline` disappears into the driver: **four functions, and
     "time is a reply" with no exception.** The sim driver advances virtual
     time to its earliest outstanding sleep when the core is idle, exactly as
     quinn's `Pair::step` does.
   - **(b) The quinn shape.** Keep the core's timer heap with
     `now_ns` and `ren_poll_deadline`, but journal each `now_ns` that fires a
     timer, as a reply-like entry.

   **Lean (a).** It is one rule, it matches the model's own sentence, and
   item 4's bug class becomes the driver's to own in one place.
4. **Take, if (b) survives: one rule against spinning, and a reason with
   every deadline.** `ren_poll_deadline` must return either "none" or a
   deadline strictly after the `now_ns` of the last `ren_run`, unless
   `ren_run` returned `running`. Spurious early `ren_run` calls are no-ops,
   as with quinn's `handle_timeout`. Return a reason code with the deadline,
   as str0m's `Reason` (#520) does, so a spinning driver can be diagnosed.
5. **Missing: call identity and cancel in the ABI.** The model says the core
   "sends a cancel to the driver", but no function or call kind carries one,
   and `ren_reply` has no id that the spec defines.
   - Specify that `ren_call` carries a 64-bit id made of a slot and a
     generation. A late reply after a release then can't hit a reused slot:
     the io_uring `user_data` ABA problem.
   - Specify that a cancel is a call of its own kind (`Cancel { id }`)
     pulled through `ren_poll_call`.
   - Specify that the reply to a cancelled call is either its real result
     or `Released`, and that both are journaled.
6. **Missing: handing back driver-owned buffers.** Provided buffers
   (experiment E4) and the `pages` hook mean that some replies carry memory
   the driver owns: the s2n-quic slot pattern. The core needs an explicit
   return, like rustls `discard(n)` or h2 `acknowledge_received_data`.
   - Make it a `Release { buf }` call, batched through `ren_poll_call`.
   - Say whether a released buffer is journaled as an entry or folded into
     its reply.
7. **Decide: what `inout` means for a cancelled call under "release".**
   `runtime-io.md#cancelling-waits-for-the-kernel` says a cancel *waits* for
   the kernel. The new model says a late reply is *released* by the driver.
   - If the task does not wait, the `inout` buffer must have been moved to
     the driver, not borrowed from the task: the tokio-uring owned-buffer
     shape. A `finally` must then not be able to read the argument of a call
     that was cancelled.
   - If the task does wait, the "release" path only applies to calls the
     task has already abandoned.

   Pick one. The sans-I/O libraries never face this, because their lends are
   synchronous.
8. **Take: two clocks, both journaled.** Split `Clock.now` (wall time, may go
   backwards, may fail: rustls returns `Option`) from monotonic time (which
   only `sleep_until` and deadlines use). Wall time is answered inline
   through `answer_now`, as quinn's `TimeSource` and rustls's `TimeProvider`
   are pulled. Both must be journal entries.
9. **Take, and state as rules: `answer_now` and `wake` are leaf callbacks.**
   - `answer_now` runs on the worker inside `ren_run`. It must not call any
     `ren_*` function, and must not block. This is the contract of `TimeSource`.
   - `wake(host, worker)` may be called from any thread, and while the core
     holds internal locks. It must only signal.
   - Make `wake` a *sticky permit* (eventfd counter, futex word,
     park/unpark), so that a wake landing between "`ren_run` returned idle"
     and "the driver sleeps" is not lost. str0m's principle applies: a
     spurious wake costs one poll, and a lost one hangs.
10. **Take, with care: `budget` must not change meaning.** quinn's bound
    leaked into congestion control. Under the deterministic scheduler, where
    `ren_run` returns because of budget must either be journaled as a poll
    boundary or be unable to change the order of task steps. Since decision 11
    already counts polls, record budget exhaustion as one.
11. **Take: the core must report `done` and still be drained.** rustls
    appends alerts on error, and h11 has `send_failed`. After `ren_run`
    returns `done`, or the program panics, the driver must still drain
    pending cancels and releases, and acknowledge them, before it tears down.
    Write that into the contract for `done`.
12. **Take: report errors explicitly, not through sentinels.** EOF, a short
    read and "released" are variants of `D.Reply`, never an empty buffer
    (h11's `b""` trap). The compiler writes `D.Reply`, so this costs nothing.
13. **Take: the sim driver and chaos as sans-I/O machines too.** str0m's
    `Netem` and s2n-quic's `havoc` and interceptors show that the chaos layer
    composes best with the same input/output shape. Ren's sim driver should
    *be* a `ren_host` plus a seeded machine, as s2n-quic's testing provider is
    another provider for the same `EventLoop`. Add s2n-quic's guard: a sim run
    that makes no progress for N macrosteps fails loudly, naming the parked
    tasks.
14. **Take: a per-iteration telemetry event from drivers.** For every wakeup
    record why it happened (reply, deadline, cross-worker wake), and for
    every sleep record the deadline and how long the turn took, as s2n-quic
    does (`event_loop.rs:112-186`). This is cheap and feeds `--trace` and the
    flight recorder.
15. **Refuse: a single `step(input) -> outputs` function.** It forces
    allocating output lists or fixed batches, and it loses pull
    backpressure. The draft's split is right. str0m gets its simplicity from
    the drain contract (item 1), not from having one function.
16. **Refuse: injected clock and RNG callbacks inside the core, beyond
    `answer_now`.** s2n-quic's `Clock` capability is read many times per
    iteration. quinn's BBR shows how an ambient RNG creeps in. Ren's language
    already makes `Random` and `Clock` dependencies, so it should lean on that
    and give the core no other way in.
17. **Still decide: the per-worker split versus the shared core.**
    quinn's endpoint/connection split, with events passed explicitly, is how
    a sans-I/O core scales across threads. Ren has one `ren_core` with
    per-worker calls, and `ren_reply` callable from any thread.
    - Decide whether a reply is routed to the worker that issued the call:
      cheap, no shared queue, and it matches "one ring per worker".
    - The alternative is a shared multi-producer queue. That is the
      contention point quinn avoided.
    - Experiment E5 measures the cost. The ABI should at least let the
      driver say which worker a reply belongs to.

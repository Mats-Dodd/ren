# R5: Hosted runtimes and WASM

Track R5 of the runtime research. The question is whether Ren's draft C
ABI (`ren_start`, `ren_run(budget)`, `wake`, `ren_poll_call`,
`ren_reply`, `ren_poll_deadline`, `answer_now`, `pages`) can be driven
from a host that owns the event loop: JS in a browser, Node or
Cloudflare's workerd, a WASI 0.2/0.3 runtime, or wasmtime. A host that
owns the loop also forbids blocking and may give Ren no threads.

The prior art studied: JSPI, the wasm stack-switching proposal, the
Component Model's async ABI (WASI 0.3), Binaryen's Asyncify, Go's
js/wasm and wasip1 runtime, Kotlin/Wasm's dispatcher, trio's guest mode,
libuv embedding as Electron does it, Web Workers with SharedArrayBuffer,
wasmtime's fuel and epochs, and workerd itself.

Sources are cited by path in `/tmp/ren-refs/...` with line numbers, or
by URL. Claims from memory are marked **(unverified)**. Three JSPI
claims were checked locally by running a small wasm module in Node
24.22.1 (V8 13.6), at
`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/jspi-test.mjs`.

## The short answer

- **Yes, the ABI can be driven from JS cleanly, without JSPI.** This
  follows from decision 12. A Ren task's suspended state lives in heap
  frames, not on the native stack, so `ren_run` can return to JS
  between task steps with nothing on the wasm stack. That is the same
  shape as the Component Model's stackless "callback" export ABI, whose
  return codes EXIT, YIELD and WAIT map one to one onto `done`,
  `running` and `idle` (below). Go took the other path, stackful
  goroutines on wasm, and pays for it in every function (below).
- **Who suspends? The core never needs to, and the driver never does.**
  The core returns, and the driver is plain JS that awaits promises. Ren
  needs JSPI for only two things, both optional:
  1. a `blocking` foreign call compiled into the module, such as a C
     library with a synchronous read callback, which must park a native
     stack;
  2. a "host yield" in the middle of a long step, so a browser main
     thread can render or a Worker can stay inside its CPU slice.
- **What would block a JS host is missing from the ABI rather than wrong
  in it.** Seven gaps:
  1. a defined wire layout for `ren_call` and `ren_reply`;
  2. a lane (origin) on each call, for hosts that tie I/O to an inbound
     request;
  3. a way for inbound events to arrive;
  4. per-thread wasm initialisation (shadow stack and TLS);
  5. a rule that `wake` must not re-enter `ren_run`;
  6. `pages` cannot be undone on wasm;
  7. `budget` has no meaning inside a step.

## What JSPI is, and its state in October 2026

JSPI has two pieces. `new WebAssembly.Suspending(jsFn)` marks an import:
if `jsFn` returns a Promise, the wasm computation suspends.
`WebAssembly.promising(export)` wraps an export so that it returns a
Promise. The computation that suspends is everything between the
innermost `promising` export and the `Suspending` import
(`/tmp/ren-refs/js-promise-integration/proposals/js-promise-integration/Overview.md:19-45`).
The hard restriction is that only wasm frames may sit between the two.
A JS frame in between traps (Overview.md:43-45, 200-207).

Verified locally on Node 24.22.1 with no flags, using a hand-encoded
module (`jspi-test.mjs`):

1. `promising(run)` calling a `Suspending` import works, and while
   `run` is suspended **JS can call another export of the same instance**
   (`set`). The result was 15 = 10 + 5. So `ren_reply` can be called
   while a `ren_run` is parked under JSPI.
2. A JS frame between `promising` and the suspending import throws
   `SuspendError: trying to suspend JS frames`.
3. Calling the export without `promising` throws `SuspendError: trying to
   suspend without WebAssembly.promising`.

Support:

| Engine | Since | Source |
|---|---|---|
| Chrome / Edge | 137 (May 2025) | [web-features](https://web-platform-dx.github.io/web-features-explorer/features/wasm-jspi) |
| Firefox | 153 (July 2026) | same |
| Safari | 27 (Sept 2026) | same |
| Overall | Baseline "newly available" since 2026-09-14 | same |
| Node 24.22 | `'Suspending' in WebAssembly` is `true` with no flag | verified locally. A secondary [blog](https://blog.openreplay.com/jspi-javascript-wasm-bridge/) still says a flag is needed, which is out of date for this Node. |
| workerd | JSPI is gated per context by a V8 callback | `jspiEnabledCallback`, `/tmp/ren-refs/workerd/src/workerd/jsg/setup.h:788`, with a Python JSPI test at `src/workerd/server/tests/python/jspi/`. Python Workers use it ([InfoQ, Sept 2026](https://infoq.com/news/2026/09/cloudflare-python-workers-ga)). Whether plain wasm Workers get it is **unverified**. |

**Lesson for Ren.** JSPI suspends the whole wasm stack up to the
`promising` export, which here would be all of `ren_run`. Every task on
that worker stops until the promise settles. So JSPI is a blocking
call, not a scheduler, which is exactly Ren's model of a `blocking`
foreign call. Use it only there and for host yields. Never make it the
way tasks suspend.

## Stack switching and Asyncify

These are the other ways to get stackful code onto wasm.

- **Stack switching** adds typed continuations: `cont.new`, `resume`,
  `suspend`, `switch`
  (`/tmp/ren-refs/stack-switching/proposals/stack-switching/Explainer.md:492-700`).
  It is in phase 3. V8 runs it only behind `--experimental-wasm-wasmfx`,
  and SpiderMonkey's optimising tier still has stubs
  ([proposal issue #116](https://github.com/webassembly/stack-switching/issues/116),
  [Mozilla bug 2043013](https://bugzilla.mozilla.org/show_bug.cgi?id=2043013)).
  The Component Model already specifies its own threads in terms of it
  (`/tmp/ren-refs/component-model/design/mvp/Concurrency.md:503-506`).
  For 1.0 it is not something Ren can rely on, and Ren doesn't need it.
- **Asyncify** is Binaryen's whole-program rewrite. Every function on a
  path that may pause gets "unwinding" and "rewinding" branches and saves
  its locals
  (`/tmp/ren-refs/binaryen-asyncify/Asyncify.cpp:20-96`). Any indirect
  call is assumed to be able to pause unless the user opts out
  (Asyncify.cpp:206-241). That matters for Ren, because debug builds
  pass evidence and dictionaries through indirect calls. The cost is
  known to be large, around +50% code size, with a slowdown that depends
  on how much code is instrumented
  ([Zakai 2019](https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html),
  **from memory, numbers unverified**). With JSPI now baseline, Asyncify
  is only a fallback for hosts without it.
- **Go js/wasm is the cautionary case.** Go keeps goroutine stacks, so to
  switch goroutines it must unwind the real wasm stack. The linker gives
  every function resume points and a dispatch table
  (`/tmp/ren-refs/go-wasm/wasmobj.go:280-300` and `:500-560`, "unwinding
  WebAssembly stack to switch goroutine"). The runtime has **no async
  preemption on wasm** at all (`/tmp/ren-refs/go/src/runtime/preempt_wasm.s`:
  "No async preemption on wasm"). Ren's stackless frames (decision 12)
  avoid both costs. This is the strongest argument from this track for
  keeping decision 12 as it is.

## Hosts that own the loop: trio, libuv and Electron, Go, Kotlin

These hosts all converged on the same contract: "run until you'd block,
tell me the deadline, I'll call you back".

- **trio guest mode.** The scheduler is a generator, `unrolled_run`. Each
  `send` runs tasks and yields the timeout it wants. The host loop
  supplies I/O events and calls `guest_tick` again
  (`/tmp/ren-refs/trio/src/trio/_core/_run.py:2323-2383`, `:1743-1782`).
  Two lessons apply directly:
  - **Deadlines can shrink while the guest is parked.** trio calls
    `force_guest_tick_asap()` when the earliest deadline changes, or when
    a task is rescheduled from host code (`_run.py:765-782`, `:1818-1822`,
    `:1927-1928`). In Ren, the only thing that changes core state between
    runs is `ren_reply`, so **`ren_reply` must always lead to a tick**,
    through `wake` or by the host's own rule. Ren's pull model
    (`ren_poll_deadline` is re-read after each run) then stays correct.
  - **Coalesce wakes.** trio's `guest_tick_scheduled` flag makes a wake
    idempotent.
- **libuv embedding.** `uv_backend_fd`, `uv_backend_timeout` and
  `uv_run(UV_RUN_NOWAIT)` let a foreign loop poll libuv's fd and run one
  non-blocking pass (`/tmp/ren-refs/libuv/docs/src/loop.rst:154-170`,
  `src/unix/core.c:416-421`). `uv_backend_timeout` returns 0 when
  watchers are pending. That is a "call me again now" result, which
  Ren's `running` status already covers.
  - Electron runs this as two threads in lockstep: an embed thread polls
    the backend fd, then posts `UvRunOnce` to the main loop, which runs
    `UV_RUN_NOWAIT` and posts a semaphore back
    (`/tmp/ren-refs/electron/shell/common/node_bindings.cc:1132-1200`).
  - The semaphore protocol has needed bug fixes for a stale count left by
    racing posts (node_bindings.cc:586-595).
  - **Lesson:** "here is my fd, you poll it" embedding is fragile, and
    Ren's sans-I/O core avoids it entirely. The host *is* the poller, and
    no Ren fd exists to embed.
- **Go's JS host contract.** `run()` returns when all goroutines are idle.
  `beforeIdle` asks JS for a timer with `scheduleTimeoutEvent`, and JS
  calls `resume()` when it fires or when an event arrives
  (`/tmp/ren-refs/go/src/runtime/lock_js.go:209-305`,
  `/tmp/ren-refs/go-wasm/wasm_exec.js:278-296, 548-563`).
  - That is Ren's ABI with the deadline pushed instead of pulled.
  - It carries a permanent workaround for a missed timeout, which
    re-calls `resume()` in a loop (wasm_exec.js:285-291).
  - Pulling the deadline, as Ren's draft does, is simpler.
- **Kotlin/Wasm.** Coroutines are compiled to state machines (stackless,
  like Ren), so the wasm target needs no stack tricks.
  - The dispatcher runs at most `yieldEvery = 16` tasks, then
    reschedules itself as a macrotask
    (`/tmp/ren-refs/kotlinx-wasm/web-JSDispatcher.kt:106-136`). That is
    exactly `ren_run(budget)`.
  - Its wakeup is a `postMessage` to the window in the browser and
    `process.nextTick` in Node, with a promise microtask as the first
    schedule (`/tmp/ren-refs/kotlinx-wasm/JSDispatcher.kt:21-63`). A
    `setTimeout(0)` would be clamped to 4 ms once nested, per the HTML
    spec (**from memory**).

## The Component Model and WASI 0.3

WASI 0.3.0 shipped on 2026-06-11, with 0.3.2 on 2026-10-13
(`/tmp/ren-refs/WASI/docs/Release.md`). Its async story is the Component
Model's native `async` functions, `stream` and `future`
(`/tmp/ren-refs/WASI/docs/ComponentModelFeatures.md`). The p2-style
`wasi:io` pollables are gone from the p3 interfaces: `fs` `sync-data`,
`open-at` and `stat` are `async func`
(`/tmp/ren-refs/WASI/proposals/filesystem/wit/types.wit:369-651`); TCP
`receive` returns `stream<u8>` and `connect` is `async func`
(`/tmp/ren-refs/WASI/proposals/sockets/wit/types.wit:268, 366, 396`);
and the monotonic clock has `wait-until` (`clocks/wit/monotonic-clock.wit:39`).

This is the closest prior art to Ren's ABI anywhere in this survey.

- **Stackless async exports.** The export returns a code: 0 = exited, 1 =
  yield, 2 = wait on a waitable set. The runtime keeps calling a
  `callback` export with the next event until it gets 0
  (`/tmp/ren-refs/component-model/design/mvp/Concurrency.md:1145-1177`).
  That is `ren_run`'s `done` / `running` / `idle`, almost word for word.
- **Completion-based buffers, owned by the host until completion.**
  `stream.read` takes a linear-memory pointer and length. Notification
  means "already copied", and `stream.cancel-read` is how the guest gets
  its buffer back (Concurrency.md:589-625, 675-680). Ren's rule, "a
  call's contents belong to the driver until its reply", is the same
  rule. **The model is right here.**
- **Cancellation has three terminal states:** returned,
  cancelled-before-started, and cancelled-before-returned. Racing returns
  are allowed (Concurrency.md:779-835). Ren's "a late reply is released
  by the driver" is the same idea, but Ren should name these states in
  `ren_reply`.
- **Guest task affinity** (Concurrency.md:1480-1503). When a component's
  async exports are called concurrently, "a runtime should ensure that
  each guest task runs only within the Component Model task that spawned
  it", because hosts attribute imports to the calling task (for logs,
  limits and request ids). `task.return` is only legal from inside that
  task (`canonical-abi/definitions.py:2291-2300`). The suggested
  workaround is that each CM task waits on a `stream<()>` that the guest
  writes to when it has work for that task. **Ren's ABI has no notion of
  which inbound call a piece of work belongs to.** See "Lanes" below.
- **Nondeterminism.** The CM lists its own sources of nondeterminism: the
  order of ready waitables, thread resume order, and backpressure release.
  It says a host can remove all of them with a "deterministic profile"
  (Concurrency.md:837-892). That fits Ren's view that the driver owns
  order and the journal records it.

WASI 0.2 offered `wasi:io/poll.poll(list<pollable>) -> list<u32>`, a
blocking readiness poll that can include a clock pollable (**from
memory**, [wasi-io](https://github.com/WebAssembly/wasi-io)). A Ren
driver on p2 is a readiness driver emulating completions, like the epoll
fallback. Go's wasip1 netpoller does the same over `poll_oneoff`
(`/tmp/ren-refs/go/src/runtime/netpoll_wasip1.go:11-60`). There is
nothing new to learn from p2; target p3.

**One structural difference.** On WASI the driver lives *inside* the
module: it is C calling canonical built-ins, not JS. The draft
`ren_host` is a table of C function pointers, so that works. But
`ren_start` should not assume the host is foreign code.

## Cloudflare Workers (workerd)

From the [limits page](https://developers.cloudflare.com/workers/platform/limits/)
and the [security model](https://developers.cloudflare.com/workers/reference/security-model/):

- **CPU limits.** 10 ms CPU per request on the free plan. On paid plans
  the default is 30 s, raisable to 5 min. Waiting on I/O doesn't count.
- **Memory.** 128 MB per isolate, wasm included. An isolate serves many
  requests.
- **No threads and no shared memory.** "multi-threading and shared memory
  are not permitted in Workers."
- **Frozen time.** `Date.now()` is "locked in place while code is
  executing" and advances only at I/O. workerd states the same in source:
  the event loop's time "will remain constant between ticks"
  (`/tmp/ren-refs/workerd/src/workerd/io/io-context.h:200-212, 1001-1005`).
- **Work outlives the response only through `waitUntil`, for up to 30 s**
  after the response.
- **I/O is bound to the request that created it.** workerd throws "Cannot
  perform I/O on behalf of a different request. I/O objects ... created
  in the context of one request handler cannot be accessed from a
  different request's handler" (`/tmp/ren-refs/workerd/src/workerd/io/io-context.c++:1977-1983`).

What this means for Ren:

- **Time as a reply fits perfectly.** The core never reads a clock. The
  host passes `now_ns` on each `ren_run`, and the frozen clock is simply
  a coarse driver. A deterministic replay inside a Worker is free.
- **`workers` must be 1.** `work_stealing(cores: 1)` is `single`, and
  `per_core` and `Async.worker() > 0` are impossible. `main` must be
  able to ask the host how many workers it may have, instead of
  hard-coding a scheduler.
- **The program is not a server that accepts.** Each request is a JS
  event. Ren's `main` would hold a standing call ("next request") that
  the driver answers with each fetch event. The response goes back as
  another call that the driver resolves into the fetch handler's
  Promise. This is the "inbound events are replies" pattern, and it needs
  no new ABI function. It does need the next point.
- **Lanes.** The driver must start request B's subrequests from code
  running in B's handler, or workerd throws (above) or attributes the
  work to the wrong request. The same applies to the CM's task affinity
  and to per-request CPU accounting. So **each `ren_call` must say which
  inbound event its task tree descends from.** Ren already has the data:
  the task path (`main/serve:4812/handle:0`, decision 11) starts with the
  spawn that took the event. The driver keeps a queue of calls per lane,
  and each fetch handler drains its own lane's queue (sketch below).
  `ren_run` itself is pure computation and can run from any context.
- **Durable Objects are Ren's keyed instances, with Ren's rules.** A DO's
  *input gate* holds back other events while a storage operation is in
  flight. Its *output gate* holds back outgoing messages until writes
  are durable (`/tmp/ren-refs/workerd/src/workerd/io/io-gate.h:6-20`).
  The input gate is decision 10's "an operation keeps its instance until
  it returns". The output gate fixes the exact bug decision 10 cites, "a
  record written during an fsync was published as durable". This is
  independent evidence that Ren's non-interleaving rule is the right
  default for the keyed instance family.

## Web Workers, SharedArrayBuffer and Atomics

- **Cross-origin isolation.** `SharedArrayBuffer`, and so a shared
  `WebAssembly.Memory`, requires COOP and COEP headers. Emscripten
  warns "Pthreads code will not work in deployed environment unless
  these headers are correctly set"
  ([Emscripten pthreads](https://emscripten.org/docs/porting/pthreads.html)).
- **The main thread can't block.** `Atomics.wait` doesn't work on the
  browser's main thread, so Emscripten busy-waits there (same page). Node
  allows it on its main thread (verified locally).
- **`Atomics.waitAsync`** is the non-blocking form: Chrome 87, Safari
  16.4, Firefox 145 (Nov 2025)
  ([web.dev Nov 2025](https://web.dev/blog/web-platform-11-2025)). A
  worker can wait for a wake and still serve its own JS event loop,
  which a JS driver needs because fetch and IndexedDB replies arrive as
  events.
- **Creating workers is asynchronous.** Emscripten pre-creates a pool
  because a Worker can't start inside `pthread_create` without returning
  to the event loop (same page). Ren's rule, "the runtime never creates
  threads; a worker is any thread calling `ren_run`", **is exactly right
  for the web**. The host makes N Web Workers, posts each the same
  `WebAssembly.Module` and the shared `Memory`, and each calls
  `ren_run(core, i, ...)`.
- **The main thread should not be a Ren worker.** At most it is a driver
  for DOM calls, with a small budget.
- **Each wasm thread needs its own shadow stack and TLS block in linear
  memory.** wasm-ld's `__wasm_init_tls`, and Emscripten's thread init,
  do this (**from memory**). The draft ABI has no per-thread entry
  point. See item 4 below.
- **Memory growth and JS views.** Growing non-shared memory **detaches**
  every JS view of it. Shared memory doesn't detach, but old views keep
  their old length. Both verified locally: a non-shared view had length 0
  after `grow`, and a shared view kept 65536 while the buffer became
  131072. Emscripten notes that pthreads with memory growth makes JS
  access to memory slow (same page).
- **Not every web API accepts shared views.** Node accepted
  `crypto.getRandomValues` and `TextDecoder.decode` on shared views
  (verified). Browsers have historically rejected shared views for
  `getRandomValues` (**from memory, unverified**). A browser driver
  should copy through an unshared scratch buffer.

## wasmtime as host

- **Async hosts run wasm on their own fiber.** wasmtime runs guest code
  on its own fiber, so host async functions can suspend the guest with
  no change to the guest (`/tmp/ren-refs/wasmtime-bits/lib.rs`, the
  `wasmtime-fiber` crate). That is host-side stack switching, the native
  equivalent of JSPI.
- **Two ways to interrupt a guest.** Both either trap or yield
  asynchronously (`/tmp/ren-refs/wasmtime-bits/examples-interrupting-wasm.md:1-60`):
  - **Fuel** is deterministic and costs more
    (`config.rs:639`, `store.rs:1040-1058`).
  - **Epochs** are not deterministic and cost about 10% (`config.rs:784`).
- **What this means for Ren.** A host can pause Ren in the middle of a
  step without Ren's cooperation and without changing Ren's meaning. The
  whole instance stops, no task switches, and handler instances stay
  held. So an embedder that needs CPU slicing can have it from outside.
  Ren doesn't need to add preemption.

## Memory: the `pages` hook on wasm

- **Growth happens inside the module.** On wasm, memory grows by the
  `memory.grow` instruction in the module, or by JS calling
  `memory.grow` from outside. Either way growth is monotonic: there is
  no way to give pages back. The memory-control/discard work is not
  shipped (**from memory**).
- **Address space and quotas are small.** wasm32 caps at 4 GiB. A shared
  memory must declare its maximum up front. Workers cap the isolate at
  128 MB.
- **So:**
  - On wasm, `pages(n)` is `memory.grow`. It is compiled in, not a JS
    round trip.
  - The core and its arenas (decision 14's memory model, `Mem`) must
    reuse pages they got and never assume they can return them.
  - A `pages` failure must be a clean out-of-memory, not a trap, because
    128 MB is reachable.
  - The host needs a hook to learn that memory grew, so a JS driver can
    rebuild its views. Simplest: JS re-derives views after every
    `ren_run` that reports growth.
- **The native 1 GiB stack doesn't exist here.** The native slice runs
  `main` "on a thread with a 1 GiB stack" with a frame check 1 MiB from
  the end (`/Users/matthewdodd/Documents/code/ren/compiler.md:1566-1571`).
  On wasm the shadow stack is a fixed region of linear memory (64 KiB
  by default in LLVM and Emscripten, **from memory**), and overflow is
  not caught by the engine; it silently overwrites the heap. Ren's own
  frame-limit check is what saves it, so the limit must come from the
  host per worker, not be a constant.
- **This also contradicts the agreed model.** "The program runs on a
  thread with a 1 GiB stack" means the native build creates a thread,
  which conflicts with "the runtime never creates threads". The stack
  must be the caller's, or one given through the ABI.

## A JS host loop for Ren's ABI

This sketch drives one worker, on the browser main thread, in a Web
Worker, in Node or in workerd. It assumes the additions proposed below:
a fixed call layout, a lane on each call, `ren_thread_init`, a
`REN_GREW` flag on the result of `ren_run`, and released replies.

```js
const RUNNING = 0, IDLE = 1, DONE = 2, REN_GREW = 0x100;

class RenHost {
  constructor(instance, { budget = 64, driver }) {
    this.x = instance.exports;              // ren_* exports + memory
    this.driver = driver;                   // JS: answers calls with promises
    this.scheduled = false;                 // coalesce wakes (trio, Kotlin)
    this.timer = null;
    this.budget = budget;
    this.lanes = new Map();                 // lane id -> queue of calls (workerd/CM affinity)
    const ch = new MessageChannel();        // not setTimeout(0): 4 ms clamp when nested
    ch.port1.onmessage = () => this.tick();
    this.post = () => ch.port2.postMessage(0);
    this.views();
  }
  views() { this.u8 = new Uint8Array(this.x.memory.buffer); this.dv = new DataView(this.x.memory.buffer); }

  // ren_host.wake. MUST only schedule, never re-enter ren_run (it is called
  // from inside ren_run on this thread, or from ren_reply on any thread).
  wake() { if (!this.scheduled) { this.scheduled = true; this.post(); } }

  // ren_host.answer_now: synchronous import, called inside ren_run.
  // Time, randomness, replay. Pure JS, never calls back into wasm.
  answerNow(callPtr, replyPtr) { return this.driver.answerNow(this.dv, callPtr, replyPtr); }

  tick() {
    this.scheduled = false;
    clearTimeout(this.timer);
    const nowNs = BigInt(Math.round(performance.now() * 1e6));  // time is a reply
    const r = this.x.ren_run(this.core, 0, nowNs, this.budget);
    if (r & REN_GREW) this.views();          // memory.grow detached our views
    const call = this.x.ren_call_slot(0);    // per-worker scratch the core owns
    while (this.x.ren_poll_call(this.core, 0, call)) this.dispatch(decodeCall(this.dv, call));
    switch (r & 0xff) {
      case DONE:    return this.driver.finish(this.x.ren_exit_code(this.core));
      case RUNNING: return this.wake();       // budget hit: yield to host, come back
      case IDLE: {
        const dl = this.x.ren_poll_deadline(this.core, 0);  // -1n: none
        if (dl >= 0n) {
          const ms = Number(dl - nowNs) / 1e6;
          this.timer = setTimeout(() => this.tick(), Math.max(0, Math.ceil(ms)));
        }
      }
    }
  }

  dispatch(c) {
    if (c.kind === "cancel") return this.driver.cancel(c.target);   // AbortController.abort()
    // Start the I/O from the code of the lane that owns it (workerd: the
    // fetch handler of that request), or here if the host has no lanes.
    const start = () => this.driver.start(c).then(
      reply => this.reply(c, reply),
      err   => this.reply(c, { error: err }));
    const lane = this.lanes.get(c.lane);
    lane ? lane.push(start) : start();
  }

  reply(c, rep) {
    // The call's buffer (inout `into`) is ours until here: copy bytes in,
    // then hand ownership back. A late reply to a cancelled call is
    // released by the driver and reported as such, so the journal sees it.
    if (rep.bytes) { this.views(); this.u8.set(rep.bytes, c.into); }
    const slot = this.x.ren_reply_slot(0);
    encodeReply(this.dv, slot, c.seq, rep);  // {seq, ok|err|released, len}
    this.x.ren_reply(this.core, slot);       // copies; slot reusable at once
    this.wake();                              // a reply must always lead to a tick (trio)
  }
}

// workerd shape: one isolate-wide core; each fetch is a reply to the standing
// "next request" call, and the handler drains its own lane until Respond.
export default {
  async fetch(request, env, ctx) {
    const lane = host.openLane(request);      // answers Http.Call.Next with lane id
    for await (const start of lane) start();  // I/O begins in this request's context
    return lane.response;                     // resolved by the Respond call
  },
};
```

Notes on the sketch:

- **No JSPI anywhere.** `ren_run` is a plain synchronous export.
  `answer_now` is a plain synchronous import.
- **JSPI could be added later in one place:** export
  `promising(ren_run)` as a second entry, `ren_run_async`. Mark the
  `blocking` foreign-call import, and a compiler-inserted host-yield
  import, as `Suspending`.
  - While suspended, JS may still call `ren_reply`; this was verified
    above.
  - JS must not call `ren_run` for the same worker. That needs a guard.
  - `answer_now` and `wake` must never call into wasm. Otherwise a
    suspension under them would put a JS frame in between, and it traps.
- **Multi-worker on the web.** Each Web Worker runs this loop with
  `worker = i` on a shared memory. `wake(host, i)` from another thread
  becomes `Atomics.store` plus `Atomics.notify` on word `i`. Each worker
  waits with `Atomics.waitAsync`, so its JS loop still delivers its
  driver's replies.

## What Ren should take, refuse, or still decide

1. **Keep decision 12; refuse stackful tasks on any target.**
   Stackless heap frames are why `ren_run` can return to JS between steps
   with an empty wasm stack. That means no JSPI, no Asyncify, and no Go
   resume-point tax in every function (`wasmobj.go:280`, Asyncify.cpp:20-96).
   The Component Model's stackless callback ABI is the same design. Write
   into foundations.md that this is also what makes hosted runtimes
   possible.
2. **Take the Component Model's async export shape as the check on
   `ren_run`.** `done`, `running` and `idle` are EXIT, YIELD and WAIT.
   Make the WASI 0.3 target a driver compiled *into* the module, which
   calls canonical built-ins: `stream.read` with the call's own `into`
   buffer, `subtask.cancel` and `stream.cancel-read` for cancel, and
   `waitable-set.wait` when `idle`. Nothing in the model needs to change
   for this.
3. **Missing: a defined wire layout for `ren_call` and `ren_reply`.** A
   JS driver must decode a call from linear memory: tag, sequence number,
   task, lane, then the `D.Call` fields with pointer and length for
   buffers. The journal is already "the list of calls and replies", so
   **make that one format**: the journal's record, the hosted ABI's
   struct and a dependency-as-protocol's wire are the same bytes.
   decision 20's own `format ... for T` is the tool. Have the compiler
   emit a descriptor, so the JS driver for the closed world list (Fs,
   Net, Clock, Random, Console...) can be generated, not hand-written.
4. **Missing: `ren_thread_init(core, worker, stack_base, stack_size)`,
   or the same through `pages`.** On wasm every thread needs its own
   shadow stack and TLS in linear memory, and the engine doesn't check
   stack overflow. Ren's frame-limit check must take its limit from the
   host. **Wrong in the native slice:** running `main` on a thread the
   runtime makes with a 1 GiB stack (compiler.md:1566-1571) contradicts
   "the runtime never creates threads". The caller's thread, with a
   host-given stack size, must be the rule everywhere.
5. **Missing: lanes.** Give each `ren_call` the lane of the inbound event
   its task tree came from, which decision 11's task path already
   implies. workerd binds I/O to the request that started it
   (io-context.c++:1977-1983). The Component Model asks for "guest task
   affinity" and `task.return` from the owning task (Concurrency.md:1480-1503).
   Per-request CPU and log attribution need it too. The scheduler doesn't
   change; drivers route by lane.
6. **Decide: inbound events are replies to a standing call.** Model a
   fetch event, a CM export call or a Web Worker message as the reply to
   an outstanding `Next` call, and the response as a call. This keeps
   the ABI to its five functions and the journal complete. Fix the
   naming in std (an `Http.Server` dependency). The ABI needs nothing
   more than item 5.
7. **Add a rule: `wake` and `answer_now` must not call back into the
   core, and one `ren_run` per worker at a time.** In JS a re-entrant
   `ren_run` from `wake` would corrupt the scheduler, and under JSPI any
   JS frame that calls into wasm can trap a suspension. `ren_reply` must
   be safe while a `ren_run` is parked, which means a lock-free push and
   no core lock held across a `blocking` call. This was verified possible
   under JSPI above. **`wake` must be idempotent**, and the host must
   coalesce, as trio and Kotlin do.
8. **Add a rule: every `ren_reply` leads to a tick.** Either the core
   calls `wake`, or the host always ticks after a reply. trio needed
   `force_guest_tick_asap` because host-side changes moved its deadline
   (`_run.py:765-782`). With a pulled `ren_poll_deadline`, re-read after
   every run, this is the only rule required.
9. **Wrong as drafted: `pages(n)` has no inverse, and that is correct
   only by accident.** wasm memory never shrinks, shared memory needs a
   declared maximum, and Workers cap the isolate at 128 MB.
   - Say it plainly: `pages` may fail (an out-of-memory panic, not a
     trap) and is never undone.
   - On wasm it compiles to `memory.grow`.
   - Add a "memory grew" bit to `ren_run`'s result, because growth
     detaches JS views (verified).
   - If native wants to give memory back, that is a separate optional
     `unpages` that hosted builds make a no-op.
10. **Decide what `budget` counts.** Decide whether it is task steps or
    poll points, and say that the core can only stop between steps.
    Kotlin uses 16 tasks (`web-JSDispatcher.kt:107`). Within a step Ren
    has no preemption, by design. For hosts that need slicing inside a
    step:
    - wasmtime's epochs or fuel suspend the whole instance from outside,
      at no cost to Ren's meaning;
    - in JS, an optional compiler-inserted host yield at loop back-edges,
      a `Suspending` import under `promising(ren_run)`, does the same.
    Neither switches Ren tasks, so neither is preemption in Ren's sense.
    Ship neither for 1.0. Say that a long step on the browser main
    thread or a 10 ms Worker is the user's problem; their fix is a
    `blocking` call or a separate Web Worker.
11. **Take JSPI for exactly one thing: `blocking` foreign calls on hosted
    targets.** It parks the whole worker, which is the honest cost of a
    blocking call with no thread pool. It is baseline in browsers since
    2026-09-14, and unflagged in Node 24.22. Workers gate it per
    context. Refuse Asyncify as a dependency; at most it is a fallback
    flag.
12. **Missing: `main` needs to learn what the host allows.** On Workers
    `workers` is 1 and nothing may make threads. On the web, N depends
    on `crossOriginIsolated` and on `navigator.hardwareConcurrency`.
    `ren_start(..., workers)` already carries N. Make the scheduler
    `main` installs a request the host may clamp. `work_stealing(cores:
    8)` under a 1-worker host runs as `single`, which the "rules don't
    change with the runtime" guarantee already permits. `per_core`
    should fail at start, not silently degrade.
13. **Take Durable Objects as outside confirmation of decision 10 and the
    keyed family.** The input gate is "an operation keeps its instance
    until it returns". The output gate is "don't publish what isn't
    durable yet" (io-gate.h:6-20). A Ren instance family hosted on DOs
    maps one instance to one object. Still decide whether the family's
    `evict` can be driven by the host, since DOs are evicted at will.
14. **Still decide: the cancel reply's states.** Adopt the Component
    Model's three terminal states for a world call: returned,
    cancelled-before-started, and cancelled-before-returned with resources
    released (Concurrency.md:779-800). This makes "a late reply is
    released and the journal records the release" a value in `ren_reply`,
    not a convention, and a JS driver's `AbortController` maps onto it
    directly.
15. **Confirmed right, keep:**
    - time is a reply, which fits workerd's frozen clock exactly;
    - the runtime never creates threads, which matches Web Worker pools
      and Emscripten's lesson;
    - requests are completion-shaped, with the buffer owned by the driver
      until the reply, which is the Component Model's `stream.read`
      rule;
    - drivers may answer inline, which is how `answer_now` serves the JS
      clock and `crypto` without a round trip;
    - a sans-I/O core with no fd to embed, which avoids the
      libuv/Electron lockstep bugs (`node_bindings.cc:586-595`).

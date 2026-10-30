# The runtime

What a Ren runtime is: the interface between compiled code and the
scheduler, the promises it keeps, and what it's free to choose. One
line says it:

> **The language owns meaning; the runtime owns time, order and place.**

> **Status:** proposed. It builds on [structured-actors.md](structured-actors.md)
> and the prior-art research in [research/runtime/SYNTHESIS.md](research/runtime/SYNTHESIS.md),
> and it frames foundations.md decision 9 and the runtime core stage. Lock
> mechanics, memory and the record layout are
> [compiler.md](compiler.md#the-runtime-model)'s.

## The stack

```
meaning      work is a tree: calls own tasks, families own posted calls.
(language)   Anything that crosses an owner is a D.Call: data, not code.
─────────────── the contract: the orders the language promises
core         time, order and place, over three nouns:
(sans-I/O)   tasks · instances · queues of D.Calls
─────────────── D.Call out, D.Reply in
drivers      the world: Clock, Net, Fs, Proc; real, sim, replay, hosted
─────────────── the host ABI, nine functions
host         threads, rings, event loops, a JS isolate
```

- **One runtime per program,** installed by `main`: `with
  Async.per_core() in serve()`. `Async.pinned()` is the only nesting.
- **The core does no I/O and reads no clock.** Everything it needs from
  the world is a call it hands out and a reply it's given, so the same
  core runs on io_uring, kqueue, a test's tape or a JS event loop.
- **Schedulers are a closed set** for 1.0: `single`, `per_core` (the
  default), `work_stealing` and `sim`. **Drivers are open:** a user
  writes one inside `trust`.

## Three nouns

The core keeps three kinds of thing, and compiled code reaches it only
through their verbs.

| Noun | What it is | Verbs |
|---|---|---|
| **Task** | a node in the work tree, owned by a scope | spawn into a scope (waiting while its `max:` run); wait for a scope's tasks; cancel a subtree; park and wake |
| **Instance** | a handler's state, touched by one operation at a time | take and release for one call; `release` mid-operation for one call; `until(cond)`, checked again at each release |
| **Queue** | a bounded queue of `D.Call`s to an owner, at a place | push, waiting for room; deliver in order, one operation each; drain when the owner ends, or drop when it's cancelled |

- **A family is the three together:** a map from key to an instance and
  its queue, with make, pin, evict and list (decision 18). It's one of
  the runtime's privileged handlers; which to evict and how many to
  keep are a library's.
- **Everything else is std,** written in Ren over these: `both`,
  `race`, `map`, `each`, `timeout`, `beside`, `background`, `produce`,
  `sync`'s channels and semaphores, `actors`, `striped`. `timeout` is a
  `race` against a `Clock` call; `race` is a scope, an instance's state
  and `until`.

## One way to talk: a queue

**The world is the outermost family.** Every wait in a family points
outward ([structured-actors.md](structured-actors.md#no-deadlock-by-one-rule)),
and the world is where every chain of waits ends. So the core has one
way for work to cross an owner: a `D.Call` pushed to a bounded queue.

| What crosses | Into | A reply? |
|---|---|---|
| a world call, `Net.read(conn, buf)` | the driver's queue | yes, `D.Reply` |
| an operation through `at`, on another place | the key's queue at its home | yes |
| a `post` | the key's queue at its home | no |

- **A full ring is a full mailbox.** An io_uring submission queue with
  no room and a key's mailbox at `mailbox:` are the same condition, and
  both wait for room.
- **Time is a world call,** `Clock.Call.SleepUntil(t)`, answered by the
  driver. The core never sees time except as a reply.
- **A call belongs to whoever answers it until its reply,** so `inout`
  buffers move to the driver and back, and a cancel doesn't free them
  early.
- **A cancelled task waits for its reply.** The cancel is a call too;
  the driver answers the original `Done` or `Cancelled`. A reply nobody
  waits for is released, and the journal records it.
- **A driver may answer at once,** inline, and nothing can tell.

## The contract

The language promises these orders, and only these:

1. Calls from one task to one key run in the order they were made.
2. An instance runs one operation at a time.
3. A scope ends after its tasks, and a call that returns is done.
4. `finally`s run in reverse creation order; families end innermost
   first, draining when their body returns.
5. A cancelled task waits for its reply.
6. `until(cond)` resumes only when `cond` holds, and no wakeup is lost.

**Every other order is the runtime's to choose,** and that's exactly
what `sim` explores: which task runs next, which waiter takes a
released instance, which sampled actor is evicted, when a reply lands.
`sim` is the deterministic scheduler plus a sim driver that answers
`Sched.Call.Pick` from a seeded tape. A runtime is correct if it keeps
the list; `sim` covers everything off it.

## What's journaled: time and order, never place

The core writes the journal, through the host's `journal` hook: each
choice it made, each world call and its reply, each post. **Place isn't
journaled, because no program can observe it:** which core ran a task,
where a key lives, whether `at` moved the task or shipped each call.
So a journal recorded on sixteen cores replays on one, by construction.

`Async.worker()` would leak place, so it's std's alone, for
`striped(by: Worker)`, whose merge erases the split (decision 18's
split law).

## Places

A place is where tasks run and keys live: a core under `per_core`, the
thread of an `Async.pinned`, a Web Worker, an isolate. **A place either
shares memory with the others or doesn't**, and that one property is all
the abstraction needs:

- **Shared memory** (threads): a value crosses by reference, marked
  shared; a task may move to a key's home for an `at` block, or send
  each operation there and back. Which is the runtime's, and the
  compiler may choose per block.
- **No shared memory** (Web Workers, isolates): a value crosses as data,
  copied; a frame can't move, so an `at` sends each operation to the
  key's place and back.

Both work because of structured actors: what crosses a place is a
`D.Call`, which is data with no block in it, and a task never outlives
its call, so no frame needs to follow work anywhere.

## The host ABI

The host drives the core through nine functions, sketched in
[SYNTHESIS.md §3](research/runtime/SYNTHESIS.md#3-revised-abi-sketch);
names and signatures are the runtime core stage's:

| Function | Does |
|---|---|
| `ren_start(config, main, host, ctx)` | makes a core; no globals |
| `ren_thread_init(core, worker, stack)` | binds a worker to this OS thread |
| `ren_run(core, worker, steps)` | runs up to `steps`; `RUNNING`, `IDLE` or `DONE` |
| `ren_poll_call(core, worker, out)` | takes the next call for the driver |
| `ren_reply(core, reply)` | gives a reply, from any thread; `ACCEPTED` or `RELEASE` |
| `ren_stop(core)` | cancels everything, and keeps draining until `DONE` |
| `ren_kill(core)` | drops everything with no `finally` (a `sim` crash) |
| `ren_free(core)` | frees it |
| `ren_progress(core, worker)` | a counter for the host's stall watchdog |

- **The runtime never makes a thread.** A worker is a thread the host
  made, bound with `ren_thread_init`, one ring each.
- **Every driver has one loop:** run, take calls into the kernel or the
  JS runtime, sleep until a completion, a timer or a wake, and hand
  back replies.
- **The host's hooks are leaves:** `wake`, `answer_now`, `pages` and
  `journal` never call back into the core.

## What it isn't

- **Not a place for meaning.** Nothing a program can observe depends on
  the runtime: only cost, and which of the free orders a run took.
- **Not BEAM.** No supervisors, no preemption, no mailboxes without a
  bound, no messages inside a family.
- **Not swappable mid-program.** One runtime a program, and `pinned` the
  only nesting.

## Open

- How `at` runs on shared-memory places under `per_core`, moving the
  task or shipping each call: measured in the runtime core stage.
- The core's own record layout, shared with the journal and the hosted
  wire: the runtime core stage.
- A user-written scheduler: later, inside `trust`, against this page.

# Bounding work after it changes hands: a landscape

This is a survey for decision 18 (foundations.md, "### 18. Actors and stripes") and
research/actors-post/. It maps what exists and does not pick a design. The question:
once `Docs.post` hands a call to the family's tree, and messages cause messages, what
bounds the work, where does waiting happen, and how does anyone observe that it has
finished?

**How claims are marked.**
- **[src]**: read in source in /tmp/ren-refs (or a fresh shallow clone), with file:line.
- **[doc]**: read in the system's own documentation or the paper, this session.
- **[mem]**: from memory or secondary sources, not re-checked. Treat the exact numbers as
  unconfirmed.

---

## 0. One-page map

Every system surveyed bounds caused work in one or more of eight ways.

| # | Family | The idea | Where it lives |
|---|---|---|---|
| A | **Per-receiver bounds** | A mailbox has a capacity; at the bound the sender blocks, the message is dropped, or the send fails. | Akka/Pekko bounded mailboxes, Effect Cluster `MailboxFull`, Orleans `MaxEnqueuedRequestsHardLimit`, Ray `max_pending_calls`, Durable Objects "overloaded", Kotlin `actor(capacity)`, Wuyts' bounded channel |
| B | **Scheduler throttling over unbounded mailboxes** | Senders to a congested actor are deprioritised. It is a heuristic, not a bound. | Pony muting / `batch_size`, BEAM sender punishment (removed in OTP 21), Verona backpressure (removed in 2022 for deadlock) |
| C | **Demand / credit per link** | The receiver grants credit and the sender may not exceed it. | Reactive Streams / Akka Streams, Akka reliable delivery, CAF flows, RabbitMQ `credit_flow`, HTTP/2 and QUIC windows, ATM / InfiniBand credits |
| D | **Edge admission, interior never waits** | Waiting and refusal happen only where work enters. Inside, work flows. | FoundationDB Ratekeeper / GRV, DAGOR, Orleans gateway load shedding, Google criticality, TigerBeetle `clients_max` × 1 in flight, Hebert's and Andersen's "flow control at the edge" |
| E | **Per-cause fuel / hop limits** | Each cause carries a budget that everything it causes draws from. | IP TTL, AWS Lambda loop detection (~16), Cloudflare 32 Worker invocations per request, Orleans `MaxForwardCount` and TTL = caller's timeout, gRPC deadlines, Ethereum gas plus the 63/64 rule, TON message value, Wasmtime fuel |
| F | **Causal completion (termination detection)** | Know when everything a cause started is done. | Dijkstra–Scholten, Mattern/Huang credit recovery, weighted reference counting, X10 `finish`, Zone.js / NgZone `isStable`, Effect `TestClock` WakeTracker, Pony quiescence, Ray ownership refcounts |
| G | **Structural acyclicity of waits** | Waits may only go "outward" along a DAG, so no cycle of waits can form. | Seastar `smp_service_group` ("nested calls must form a DAG"), Tagger / virtual channels (monotone tags), Ren's own inner-to-outer rule (decision 10), SDF static schedules |
| H | **Causal resource accounting** | Charge each piece of work to the activity that caused it, then enforce a policy. | Resource containers (OSDI'99), Retro (NSDI'15), Pivot Tracing / baggage, DAGOR priority inheritance |

**Where Ren is today.** Decision 18 plus the fixes in actors-post is **D** with one
global interior cap. Every outside call is metered against `mailbox:`. Sibling posts
never wait, which is family G applied to the one cycle that matters. Past 2× `mailbox`
a sibling post panics, which is a crude, global version of E. Teardown drains, which is
F at family scope with no per-cause view.

**Where the origins hypothesis sits.** It is a composite of four families:

- **D, counted in causes rather than messages.** At most N origins are open, and only
  the edge waits. The closest prior art is TigerBeetle's `clients_max` × one request in
  flight, with message pools sized as the product. Next closest are FoundationDB, which
  admits a transaction at GRV time and never gates its reads afterwards, and DAGOR,
  which admits at the entry and has every downstream call inherit that decision.
- **E, as a total-count budget.** Each origin has fuel F. The closest prior art is
  Ethereum gas: one budget per external transaction, drawn on by every nested call.
  Ren's version differs in two ways. Running out panics instead of reverting. And
  Ren's posts are asynchronous, which is TON's setting, but TON's budget is value that
  is split and forwarded, not a shared pool.
- **F, by refcount.** An origin closes when all its descendant mail is delivered. That
  is Dijkstra–Scholten deficit counting or Mattern's credit recovery, rooted at the
  origin. `settled()` is X10's `finish` over posts, or Effect `TestClock`'s causal
  `pending == 0`.
- **G for families.** Families nest by install order, as Seastar's service groups must
  form a DAG and Tagger's tags only increase.

**What looks new.** No single system found does all four:

1. The admission unit is an open causal tree, not a request or a message.
2. The tree's closing is detected by refcount and exposed as a language operation.
3. A per-tree fuel bound fails like a stack overflow.
4. All of it is tied to structured-concurrency teardown.

Neither the agents' searches nor I found a PL paper on "message fuel" or "causal
budgets" for actors. The parts are each well trodden. The combination, and making it a
language guarantee rather than an operator's knob, appears to be new. That absence is
weak evidence; the searches were not exhaustive.

**The bound the hypothesis buys.** In-family mail ≤ N·F, plus at most one operation's
posts per live actor. The current rule bounds mail at 2·`mailbox` in total, which can't
tell "many small causes" apart from "one exploding cause". The 25k-sessions case is
exactly that confusion.

---

## 1. Actor runtimes: overload and backpressure

### 1.1 Pony: muting, now adaptive batch size [src + doc]

**Mechanism.** Mailboxes are unbounded MPSC queues. Pony doesn't bound them; it
reshapes the schedule.

- **Current source** (/tmp/ren-refs/ponyc, which contains PR #6285, merged
  2026-10-14):
  - Each actor has a `batch_size`, starting at `PONY_SCHED_BATCH_STEP` = 25
    (`actor/actor.h:18-20`, `PONY_SCHED_BATCH` = 100).
  - An actor that uses up its batch is marked OVERLOADED and its batch grows by 25
    (`actor.c:532-545`).
  - A send to a receiver that is overloaded, under pressure or muted
    (`maybe_mark_should_mute`, `actor.c:182-213`) shrinks the *sender's* batch by 25.
  - Once the sender's batch is at or below one step, it is muted
    (`ponyint_sched_mute`, `sched/scheduler.c:1670`): put in a per-scheduler mute map
    keyed by receiver, and not scheduled until the receiver recovers and calls
    `ponyint_sched_start_global_unmute`.
- **Exemptions.** A send to self never mutes, and an overloaded or pressured sender is
  never muted (`actor.c:186-203`). This is Pony's cycle escape: overloaded actors may
  keep sending to each other. It is the same reason Ren's sibling posts never wait.
- **Manual pressure.** `Backpressure.apply/release`
  (`packages/backpressure/backpressure.pony`; `pony_apply_backpressure`,
  `actor.c:1258`) marks an actor UNDER_PRESSURE for external causes such as TCP.
  The docs' own caveat (`backpressure.pony:69-73`): "By intervening, programmers can
  create deadlocks."
- **Causal messaging.** Pony guarantees causal message order between actors (ponylang
  FAQ, [doc]). Muting only delays, so the guarantee survives it.

**What it bounds.** Nothing hard. It slows producers of a hot spot; mailbox length is
not capped. There is no notion of cause.

**Failure under overload.**
- **ponyc#3382** (2019, Wallaroo) [doc]: a sink under pressure needed a timer actor to
  send it `reconnect()`. That send muted the timer, so `release` never ran: a
  deadlock.
- **#2980**: a thundering herd under fan-in.
- The old binary muting collapsed fan-in throughput to about 119 msg/s. #6285 reports
  about 40M msg/s after the change [doc].
- **Muted actors block quiescence.** Program exit requires an empty mute map
  (`scheduler.c:272-274`).

**Implication for Ren.**
- Throttling inside the family by sender identity has a deadlock history even with
  cycle exemptions.
- Pony's exemption rule ("overloaded may send to overloaded") is the scheduling
  analogue of "interior mail never waits".
- Pony never bounded memory. Ren wants a bound.

### 1.2 Erlang/OTP [src + doc]

**Mailboxes are unbounded.** The tools around them:

- **`gen_server:call` is implicit backpressure.** It has a 5 s default timeout
  (`lib/stdlib/src/gen_server.erl:1211`). A call to self exits with `calling_self`
  (`gen.erl:232`). A cycle (A calls B calls A) blocks until the timeout, and with
  `infinity` it never recovers [doc].
- **Sender punishment.**
  - Sending used to cost the sender reductions proportional to the receiver's queue
    length [doc, secondary: about 4 × qlen].
  - It was removed in commit `2e601a2e` (Högberg, 2018-01-08, "the reduction cost of
    sending messages is now constant"), which shipped in **OTP 21** [doc].
  - Current source charges a flat `ERTS_VBUMP_REDS(p, 4)` after a send
    (`erts/emulator/beam/bif.c:2742`) [src].
  - Why it went: it was built for non-SMP machines, "doesn't do much in smp systems",
    and "makes it very hard to get predictable performance" (Larsson, relayed on
    erlang-questions, Jan 2018) [doc].
  - In the same thread Jesper Louis Andersen argued that flow control belongs at the
    edge and that internal flow control risks deadlock [secondary].
- **`max_heap_size`** (OTP 19).
  - Counts heap, stack and on-heap messages, and is checked only at GC.
  - At the limit it kills the process with an untrappable `kill`.
  - `message_queue_data = off_heap` messages escape it [doc + inference].
  - Its error report includes the queue length (`erts/doc/notes.md:6418`) [src].
  - This is a **per-process cap that kills**: the panic pattern, applied per actor.
- **Overload libraries** (all are edge or broker patterns; none touches messages
  between processes):
  - sbroker: a broker matches `ask` with `ask_r`, using CoDel or timeout queues.
  - jobs (Wiger): the caller waits in a named queue with rate, credit and
    concurrency regulators, damped by CPU and memory samplers.
  - safetyvalve (Andersen): a token bucket, and the caller blocks.
  - pobox (Hebert): a buffer process in front of the owner, which pulls; the buffer
    drops when full, and the sender is never slowed.
  - [doc, from READMEs]
- **Hebert's framing** ("Queues Don't Fix Overload", 2014): every overloaded system
  must either block input or drop data. A queue only delays failure and makes it
  worse when it comes [doc].
- **Newer tools.** OTP 27 has a `long_message_queue` system monitor. OTP 28 has
  priority messages (EEP 76; markers visible in `erts/doc/notes.md:1276`) [src].
  The checked-out OTP is 30.0-rc0.

**Implication.**
- BEAM removed its only runtime-level sender throttle.
- The community answer is edge admission (family D) plus `call` in the places where
  you want coupling.
- Ren's "outside calls are metered, sibling posts never wait" is the Erlang folk
  wisdom made a rule.

### 1.3 Akka / Pekko [src + doc]

**Classic bounded mailboxes.**
- `BoundedMailbox` is a `LinkedBlockingQueue`. `enqueue` calls
  `queue.offer(handle, pushTimeOut)` and on failure sends the message to `deadLetters`
  (pekko `actor/.../dispatch/Mailbox.scala:581-593, 729-750`).
- Defaults: capacity 1000, push timeout 10 s. A negative timeout means wait forever,
  which "bears the risk of dead-lock" (`reference.conf:689-694`).
- At runtime it warns that a blocking mailbox with a non-zero push timeout "can lead to
  blocking behavior" (`Mailboxes.scala:249-253`).
- `NonBlockingBoundedMailbox` drops to dead letters.

**Typed.**
- `MailboxSelector.bounded(n)` is `BoundedMailbox(n, Duration.Zero)`, so it never
  blocks and always drops (`Props.scala:224`, `Mailboxes.scala:221-225`).
- The default mailbox is unbounded, and the docs warn about running out of memory
  (`docs/.../typed/mailboxes.md:23-28`).
- The stash is always bounded and throws `StashOverflowException`
  (`StashBufferImpl.scala:70-77`).

**Where backpressure went.**
- **Akka Streams.** Reactive Streams demand. `request(n)` arrives as a `RequestMore`
  message and adds to `downstreamDemand` (`ActorGraphInterpreter.scala:571-594`).
  The input boundary has a fixed buffer, requests `size/2` as it drains, and throws
  "Input buffer overrun" if upstream exceeds demand (`:153-245`).
- **Reliable delivery.** `ProducerController` / `ConsumerController`. The consumer
  grants a `flow-control-window` of 50 and asks for more at half [doc].
- **Work pulling.** Workers ask for work.
- The Streams intro says raw actors "need to take care to not overflow any buffers or
  mailboxes" [doc]. I found no single doc saying "bounded mailboxes are deprecated in
  favour of streams" [unverified].

**Implication.**
- A bounded mailbox with blocking deadlocks in cycles. With drop, it loses messages.
- Akka's mature answer is per-link demand (family C), which needs a protocol per link
  and doesn't fit a request graph that fans out arbitrarily.
- Akka never bounds work by cause.

### 1.4 Orleans [src: /tmp/ren-refs/orleans, shallow clone]

**Turns and reentrancy.**
- By default an activation runs one request to completion, including all its awaits
  (MSR-TR-2014-41 §2.5) [doc].
- **Call-chain reentrancy.**
  - `RequestContext.AllowCallChainReentrancy()` puts a Guid in the request context under
    `"#CCR"` (`Orleans.Core.Abstractions/Runtime/RequestContext.cs:26-58`). It travels
    as ordinary context data on every message (`RequestContextExtensions.cs:48-55`).
  - `ActivationData.MayInvokeRequest` (`ActivationData.cs:1339-1365`) admits a request
    whose reentrancy id matches an active section.
  - This is a **causal id carried on every message** and used for an admission
    decision: the nearest production analogue of an origin tag.
  - The original version was removed and later reintroduced, and Swift cites the
    removal (see §5.1).

**Deadlocks.**
- `DeadlockException` and `PerformDeadlockDetection` are gone. The
  `OnDispatcherDetectedDeadlock` trace (`RuntimeMessagingTrace.cs:18-21`) has no
  callers.
- A deadlocked call chain fails only through `ResponseTimeout`, 30 s
  (`MessagingOptions.cs:21-31`).

**Per-activation limits.**
- `MaxEnqueuedRequestsSoftLimit` / `MaxEnqueuedRequestsHardLimit` default to 0,
  meaning off (`SiloMessagingOptions.cs:67-102`).
- Past the hard limit, `CheckOverloaded` returns `LimitExceededException`
  (`ActivationData.cs:490-520`) and the message is rejected before it is enqueued
  (`:1754-1762`).
- **One-way messages that are rejected are silently dropped.** `RejectMessage` sends a
  rejection only for requests (`MessageCenter.cs:276-286`).

**Load shedding.**
- `LoadSheddingOptions` (off by default, CPU 95 / memory 90) acts **only at the client
  gateway**: `GatewayTooBusy`, "Shedding load" (`GatewayInboundConnection.cs:74-82`).
- Silo-to-silo traffic is never shed. That is pure family D.

**Hop and TTL limits.**
- `MaxForwardCount = 2` (`SiloMessagingOptions.cs:36`) bounds re-routing hops.
- Every message carries `TimeToLive` = the caller's response timeout
  (`InsideRuntimeClient.cs:190-193`), and expired messages are dropped at every hop
  (gateway, silo connection, message center, activation).
- So Orleans already propagates a **per-cause time budget** and drops work that no one
  is waiting for any more.

**Memory.**
- `EnableActivationSheddingOnMemoryPressure` is off by default (80% limit, 75% target)
  and deactivates activations (`GrainCollectionOptions`, `ActivationCollector.cs`).
- There is no hard cap on activation count.

**Implication.**
- Orleans bounds at the gateway and with time-to-live.
- Its one-way messages get no back-pressure and are dropped silently at the hard
  limit, which is exactly what Ren's "post can't fail" forbids.
- The call-chain id shows that carrying a causal id on every message is affordable in
  production. Detecting deadlock from it was abandoned.

### 1.5 Cloudflare Durable Objects [src: workerd + doc]

**Gates** (Varda, "Easy, Fast, Correct — Choose Three", 2021) [doc; `io/io-gate.h:36-266` src]:
- The input gate delivers no events while a storage op is in flight, except storage
  completions.
- The output gate holds outgoing messages until the writes they might depend on are
  confirmed.
- Gates close only around storage, so other requests interleave during
  `fetch`/RPC [doc + inference].

**Overload.**
- The "Durable Object is overloaded" error has four variants: too many requests queued,
  too much data queued, requests queued too long, and too many requests in 10 s.
  Thresholds are not published.
- Errors carry `.overloaded`, and the docs say **don't retry** [doc].
- There is a soft limit of 1,000 rps per object [doc].
- In workerd the error is typed `kj::Exception::Type::OVERLOADED` and becomes a 503
  (`worker-entrypoint.c++:893-903`) [src].

**A global cap that resets everything** [src].
- `ActorCache::evictOrOomIfNeeded` (`io/actor-cache.c++:277-283`): if the storage
  cache overflows, it throws OVERLOADED, "Durable Object's isolate exceeded its memory
  limit due to overflowing the storage cache… **All objects in the isolate were
  reset**."
- One object's write burst takes down its neighbours.
- `evictStale` returns a promise that holds off JS "when the write queue is too deep"
  (`actor-cache.h:252-258`), a local back-pressure.

**Per-cause hop limit** [doc].
- "A single request has a maximum of 32 Worker invocations, and each call to a Service
  binding counts towards this limit." Calls beyond that throw.
- There are also subrequest caps per invocation: 50 free, 10,000 paid.

**Implication.**
- DOs bound per object and refuse at the edge with a typed error.
- Chains are bounded by a per-request invocation budget, which is family E in
  production.
- The isolate-wide reset is a concrete case of **a global cap punishing legitimate
  neighbours**.

### 1.6 Restate virtual objects [src partial + doc]

- **Handlers.** At most one exclusive handler runs per key at a time, "mimicking a
  queue per object key". Shared handlers are read-only and concurrent. One-way
  `send` and delayed send (a durable timer) are available [doc].
- **Queues.** The queue is durable (the log), with no documented bound.
- **Flow control** (1.7 preview, vqueues) limits *concurrency* only, in a 3-level
  hierarchy of scope / L1 / L2 keys (`crates/limiter/src/lib.rs:11-40`) [src].
- **Deadlocks.** The docs warn that request–response calls between exclusive handlers
  deadlock ("A → B and B → A", "A → B → C → A"). There is no detection or timeout;
  you cancel by hand [doc].

**Implication.** Durability turns "unbounded mailbox" into "unbounded log". Restate
pushes cycle safety onto the user and bounds nothing by cause.

### 1.7 Verona / Behaviour-Oriented Concurrency [src + doc]

- **BoC** (Cheeseman et al., OOPSLA 2023). A `when` behaviour acquires a set of cowns
  atomically. If b1 is spawned before b2 (in program order or causally) and they share
  a cown, b1 runs first [mem for exact wording].
- **A CONCUR 2026 axiomatic model** argues the original operational semantics imposed a
  stricter causal order than intended [doc].
- **Backpressure history** [doc via GitHub API]:
  - Theo Butler implemented runtime backpressure "loosely based on Pony's" (PR #183,
    2020). It was later turned into priorities (#310) and a mute message to the mutor
    (#390), and specified in TLA+.
  - **It was removed in PR #548 (2022-03-16)**: "With the move to AcquireAll semantics
    for `when`… we are going to remove the backpressure code as it may introduce
    deadlock."
  - verona-rt today has only test scenarios, `test/func/backpressure/{deadlock,unblock}.h`,
    and no mute logic in `src/` [src].

**Implication.** The second runtime that tried Pony-style interior throttling removed
it for deadlock once behaviours could take several cowns. Ren's `at_all` (an open
question in decision 18) would be the same shape.

### 1.8 CAF [src: /tmp/ren-refs/caf, shallow clone]

- **No mailbox bound.** `mailbox-size` exists only as a metric
  (`libcaf_core/caf/actor_system.cpp:92`).
- **Backpressure is in `caf::flow`.** Defaults: `min_demand` 8, `batch_size` 32,
  `buffer_size` 128 (`defaults.hpp:150-165`). The overflow strategy is `drop_newest`,
  `drop_oldest` or `fail` (`flow/backpressure_overflow_strategy.hpp`).
- **Streams between actors are credit-based.** `stream_demand_msg`
  (`system_messages.hpp:113-175`); the sink computes
  `capacity = max_in_flight − in_flight − buffered` and grants demand in chunks
  (`detail/stream_bridge.cpp:50-72, 175-185`).
- The old `downstream_manager` credit policies survive only as dead config
  [inference].

**Implication.** Same split as Akka: actors stay unbounded, and flow control is a
separate per-link protocol (family C).

### 1.9 Swift actors [src: swift-evolution]

- Actors are reentrant at every `await`, chosen because reentrancy "eliminates a source
  of deadlocks" (SE-0306, `proposals/0306-actors.md:298-300`).
- Non-reentrant actors deadlock, leaving "inactive zombies forever". Per-call timeouts
  were rejected as "prohibitively expensive" and as muddying cancellation
  (`:403-411`).
- **Task-chain reentrancy** (`:751-809`) means reentrant only on behalf of the same
  task or its children, which is an origin-like identity. It was deferred:
  - it "doesn't seem to have been tried at scale", and Orleans' version was removed;
  - "We do not yet know of an efficient implementation technique for this approach
    within the actor runtime".
- There is no mailbox bound. `Task {}` is unstructured and escapes the tree [doc].

**Implication.** The most careful mainstream design review found causal identity
attractive and its implementation cost unknown. That is a direct pitfall for origins
(§7).

### 1.10 Ray: ownership as lineage [src: /tmp/ren-refs/ray, shallow clone]

- **Ownership.** The worker that creates an `ObjectRef` (by submitting the task)
  *owns* it. `ReferenceCounter::Reference` keeps `owner_address_`, `borrowers`,
  nested `stored_in_objects` and `lineage_ref_count` (`core_worker/reference_counter.h:282-473`).
  Owner failure fate-shares the objects it owns (NSDI'21) [doc/mem].
- **Lineage pinning.** A finished task with retries left keeps its spec, and its bytes
  count toward `total_lineage_footprint_bytes_` (`task_manager.cc:1402-1420`).
- **A global cap that degrades rather than panics.**
  - `max_lineage_bytes` is 1 GiB. Past it, **50% of the lineage is evicted** FIFO
    (`ray_config_def.h:218-224`; `reference_counter.cc:828-842`).
  - Objects in scope then become `OBJECT_UNRECONSTRUCTABLE_LINEAGE_EVICTED`
    (`reference_counter.cc:572-585`).
- **Actor backpressure.**
  - `max_pending_calls` per handle defaults to −1, unlimited.
  - At the bound, `.remote()` raises `PendingCallsLimitExceeded` synchronously
    (`actor_task_submitter.cc:921-927`, `_raylet.pyx:4336-4345`).
  - That is an error at the caller, family A.

**Implication.**
- Ray's owner is an origin for *object lifetime*: it tracks descendants by refcount,
  has bounded metadata, and fate-shares with the caller.
- Two differences from Ren's origin:
  - A Ray owner is a live caller. A Ren origin outlives its poster, since `post`
    returns.
  - Ray's lineage cap degrades a guarantee instead of panicking.

### 1.11 Effect v4 Cluster entities [src]

- Each entity has a bounded mailbox, `entityMailboxCapacity` default 4096
  (`cluster/ShardingConfig.ts:200`), counting active requests
  (`internal/entityManager.ts:701-702`).
- A runner-wide `maxResidentEntities` defaults to 10,000 (`ShardingConfig.ts:110-124,
  202`).
- Over either bound:
  - **volatile** messages fail with `MailboxFull`;
  - **persisted** messages stay in storage and are retried when there is room
    (`ClusterError.ts:185-203`, `entityManager.ts:240-247`).

**Implication.** Effect uses durable storage as the overflow buffer and gives volatile
sends an error. Ren's post can't fail and has no storage behind it, so neither escape
is available as-is.

### 1.12 Yoshua Wuyts, "Replacing background tasks with actors" [doc]

- **The proposal.** An "actor" is a struct over a channel receiver, and handlers hold
  the sender. The handler awaits only the enqueue. `main` runs the server and
  `actor.run()` side by side under `try_join`, so the work stays in the task tree.
- **Backpressure.** The channel is `channel::bounded(capacity)`, so the poster waits
  when it is full. That is implied; the post doesn't state it.
- **What it omits.** Nothing on messages causing messages, actors posting to each other,
  or cycles. "Tree-structured concurrency" (2023) has the same pattern with no
  backpressure discussion.

**Implication.** The pattern Ren follows covers exactly the case where the edge
(bounded channel) is the only bound. The hard part, in-family recursion, is outside
its scope.

---

## 2. Causal accounting: charging work to its cause

| System | Carried id | Charged for | Enforced where | Overhead / pitfalls |
|---|---|---|---|---|
| **Resource containers** (Banga, Druschel, Mogul, OSDI'99) [doc] | A container bound to a thread, inherited by the threads it creates and rebindable at any time; can be bound to a socket | CPU and kernel network work, across process and kernel boundaries | Scheduler, using the container hierarchy (a child is limited by its parent) | Needs rebinding discipline for server threads that serve many activities |
| **Retro** (Mace et al., NSDI'15) [doc] | 3-byte workflow ID; AspectJ carries it through threads and queues, RPCs by hand | load and slowdown per workflow per resource (CPU, disk, network, locks, pools) | Token buckets and schedulers at chosen control points, with a central controller | 0.3–2% overhead. **Fan-in:** batched work gets a batch ID, and shares are split back to contributors. **Lesson:** a request must pass control points regularly or it can use unbounded resources between them |
| **X-Trace / Dapper / Pivot Tracing / W3C Baggage** [doc/mem] | Trace and span ids, or tuple baggage | Observability, not admission | n/a | Baggage grows (W3C: at least 64 entries and 8 KB must be propagated). Context leaks across requests. Multi-parent causality is poorly supported |
| **Universal context propagation** (Mace & Fonseca, EuroSys'18) [doc] | Baggage with BRANCH, JOIN, SERIALIZE, DESERIALIZE, TRIM | General | n/a | JOIN must be CRDT-like. **A plain integer counter double-counts or loses branches at a join.** TRIM drops data and leaves a marker |
| **DAGOR** (WeChat, SoCC'18) [doc] | Business priority plus user priority, assigned once at entry and inherited by every downstream call | Admission level | Every server sheds below a level and piggybacks it upstream, so callers reject before sending | Consistent admission solves "subsequent overload" (two calls to a 50%-shedding service succeed only 25% of the time). Session-based priority was gamed |
| **Google SRE** [mem] | Criticality, propagated automatically | Shedding order | Every layer; per-client retry budget of 10%, at most 3 attempts | Retries multiply across layers, so retry only directly above the overloaded layer |
| **gRPC / Finagle deadlines** [doc] | Remaining timeout, propagated to child calls (automatic in Java and Go) | Time | Every hop drops expired work | Finagle `RetryBudget`: 20% plus 10/s |
| **Orleans TTL** [src] | `TimeToLive` = caller's timeout | Time | Every hop drops expired messages | Fire-and-forget has no caller deadline to inherit |

**What this means for origins.**
- Carrying a small causal id on every message is a solved, cheap problem when the id is
  immutable (Retro 3 bytes; Orleans `#CCR`).
- What is *not* cheap is a **mutable, shared per-cause counter**: a refcount or a fuel
  balance. UCP shows integer counters need versioning to survive branch and join. X10
  needed per-place vectors and special-cased patterns (§6).
- Admission by cause at the entry, with interior consistency (DAGOR), is the
  production precedent for "only the edge waits".

---

## 3. Credit and demand flow control

- **Reactive Streams / Akka Streams / CAF flows** (§1.3, §1.8). Demand flows upstream
  per link. Nothing is emitted past the total demand.
- **HTTP/2 (RFC 9113 §5.2) and QUIC (RFC 9000 §4).** Windows exist **per stream and per
  connection**. The stream window stops one stream from starving the others. The
  connection window caps total receiver memory [mem]. This is the closest protocol
  analogue to "fuel per origin plus N origins": a two-level budget, per cause plus an
  aggregate.
- **ATM / InfiniBand credits** (Kung et al., SIGCOMM'94). Credits per virtual circuit,
  per hop. Full speed needs about RTT × rate of buffer per circuit [mem].
- **RabbitMQ `credit_flow`** (Erlang). Default `{200, 50}`. The sender blocks at zero
  credit, and blocking propagates up reader → channel → queue → store [doc]. This
  works because the chain is a **pipeline, not a cycle**.
- **Seastar SMP queues** [src].
  - Cross-core queues are fixed SPSC rings, `queue_length = 128`
    (`include/seastar/core/smp.hh:179-195`); work beyond them waits in a pending list.
  - Remote concurrency is bounded by **`smp_service_group`** semaphores,
    `max_nonlocal_requests` (`smp.hh:73-133`). The doc comment:
    - "Calls in a group should not nest; doing so can result in ABA deadlocks.
      Nested submit_to() calls must form a directed acyclic graph when considering
      their smp_service_groups as nodes… Create a new smp_service_group instead."
    - The default group "does not impose any limits on concurrency… This makes it
      deadlock-safe, but can consume unbounded resources."
  - **This is Ren's family-DAG rule, and the "an open origin must not wait for another
    origin of the same family" rule, stated in production code.**
- **SEDA** (Welsh, SOSP'01). Admission control per stage queue.
  - Welsh's 2010 retrospective [doc]: queues between every stage were the critical
    mistake. Put queues only before slow or blocking stages, and "we never took full
    advantage of" load conditioning.
  - This argues for few queues and edge admission.
- **Lossless datacenter networks** [doc].
  - PFC deadlock needs a cyclic buffer dependency (Hu et al., HotNets'16).
  - On a transient loop of n hops with TTL, deadlock occurs iff the injection rate
    r > nB/TTL. **Hop fuel drains loops below a rate threshold, but not above it.**
  - **Tagger** (CoNEXT'17): rewrite a tag per hop and give tag k its own lossless
    queue. It is deadlock-free if each per-tag subgraph is acyclic and tags never
    decrease. Packets that run out of tags drop to a lossy class.
  - Dally–Seitz virtual channels and Duato's escape channels are the classical forms
    [mem].
  - The analogy is close: families nested in install order are the tags, and fuel
    exhaustion is "demote to lossy". In Ren, "lossy" isn't allowed, so it becomes a
    panic.

---

## 4. Bounded buffers in cyclic message graphs

- **Kahn (1974).** Deterministic with unbounded FIFOs [mem].
- **Parks (Berkeley thesis, 1995).** Start with bounded buffers. On *artificial
  deadlock* (everyone blocked, at least one on a write), grow the smallest full
  buffer. This runs in bounded memory whenever any bounded schedule exists. **Whether
  a KPN is boundedly schedulable is undecidable** (Turing-complete; Buck 1993 for
  BDF) [mem].
- **Geilen & Basten (ESOP 2003).** Parks reacts only to *global* deadlock. A cyclic
  subset stuck while the rest runs is never resolved; the fix is to detect local
  cycles and grow within them [doc for citation, mem for content].
- **SDF** (Lee & Messerschmitt 1987). With fixed token rates, buffer bounds are
  computable at compile time. Cycles need initial tokens [mem].
- **Ren's choices in these terms.**
  - "Sibling posts never wait" plus "deliveries may exceed `max:`" is Parks' grow
    policy, applied eagerly and without detection.
  - The 2× cap is a fixed ceiling on that growth. Since boundedness is undecidable in
    general, any static ceiling either rejects some bounded programs (the 25k case) or
    admits some unbounded ones.
  - Per-origin fuel moves the ceiling from "the whole network" to "one causal tree".
    That is the only granularity at which a programmer can reason about recursion
    depth, as with a stack.
- **Static alternative, already rejected in actors-post.** Reject cycles in the
  operation→posted-operation graph (SDF-like). It also rejects `loop` and relays with
  hop counts.

---

## 5. Structured concurrency meets actors

- **Swift** (§1.9). Structured tasks (SE-0304) and actors are separate worlds. Actors
  own no tasks, and `Task {}` escapes. Task-chain reentrancy is the deferred bridge.
- **Kotlin `actor {}`** [doc].
  - `@ObsoleteCoroutinesApi`, waiting since 2017 on a "complex actors" redesign
    (kotlinx.coroutines#87).
  - The actor is a child of the scope's Job. Capacity defaults to 0 (rendezvous), so
    `send` suspends, which is natural backpressure.
  - Cancelling the parent **drops** unprocessed messages. `close()` drains.
  - Elizarov: waiting on an actor's processing "easily leads to deadlocks".
- **Trio / Smith** [doc + src].
  - Smith's 2016 essay: hidden buffers (asyncio `transport.write`) are a "cardinal
    sin"; respect causality.
  - Trio has no actor construct. Memory channels have explicit capacity and block.
- **Wuyts** (§1.12). Actors as reachable task pools inside the tree.
- **Effect v4 Cluster** (§1.11). An entity's lifetime is a `Scope`, and the residency
  slot is released by the scope finalizer (`entityManager.ts:240-247`).
- **Research 2020–2026** [doc].
  - Gordon, "Actor Capabilities for Message Ordering" (arXiv 2502.07958, 2025):
    static restrictions on which messages a reference may send, and in what order.
  - "Backpressure Flow Control" (NSDI'22): deadlock freedom when the backpressure
    dependency graph is acyclic.
  - **No paper was found that combines nurseries or scopes with actor mailboxes and
    bounds caused work.**

**Implication.**
- Ren's "the family's `with` owns delivery and drains on teardown" is already ahead of
  the field: Kotlin drops on cancel, Swift has no owner.
- The origin is the missing middle layer: a sub-scope inside the family, owned by a
  cause rather than by a task.

---

## 6. Observing completion of fire-and-forget work

**Termination detection** [mem; standard results].
- **Dijkstra–Scholten (IPL 1980).** Each node counts unacknowledged sends (its
  deficit). The first message makes the sender its parent; others are acked at once.
  A node acks its parent when idle and deficit = 0. Cost: one ack per message.
  **A refcounted origin is D–S with the tree collapsed to its root.** Delivery
  decrements a counter at the origin instead of acking a parent.
- **Credit recovery** (Mattern 1989; Huang 1989, weight throwing).
  - The root has credit 1, each message carries half of the sender's, and an idle node
    returns its credit.
  - **No shared counter is ever incremented.** Only returns reach the root, so it has
    no hot spot on fan-out.
  - Underflow is fixed with exponent representation, borrowing, or indirection.
- **Weighted reference counting** (Bevan; Watson & Watson, PARLE'87). The same idea
  applied to references.
- **Four-counter, vector counters, Safra (EWD998).** Wave or token schemes for when
  no per-cause tree exists.

**In languages and runtimes.**
- **X10 `finish`** [doc].
  - Waits for all transitively spawned asyncs at any place.
  - Non-resilient protocol: a home count plus a `live[places]` vector at each place,
    shipped home on join. About one control message per task.
  - Resilient finish costs 2–3 messages per task.
  - The general protocol didn't scale (petascale paper, PPoPP'14). The runtime
    specialises by pattern (local, SPMD, single remote, dense) using analysis and
    pragmas.
  - No bound on open finishes.
  - **The closest language precedent for `settled()`, and for the cost of tracking
    causal completion across cores.**
- **Zone.js / NgZone** [doc].
  - Patches every async API so a zone counts its pending tasks. `isStable` means none
    are outstanding, and `whenStable()` is used in tests.
  - Pitfalls:
    - `setInterval` at bootstrap makes an app **never stable** (NG0506);
    - monkey-patch overhead.
  - Angular went **zoneless by default in v21**, replacing implicit tracking with
    explicit `PendingTasks`.
  - Lesson: implicit causal completion tracking is fragile, and long-lived causes
    poison it.
- **Node AsyncLocalStorage** [doc]. Propagating causal context cost 30–50% under
  promise churn until AsyncContextFrame (Node 24). TC39 AsyncContext is still Stage 2.
- **Effect `TestClock`** [src].
  - `WakeTracker { pending }` (`testing/TestClock.ts:221-445`): every task scheduled
    transitively by a woken fiber increments `pending`, and `adjust` waits for
    `pending == 0` before waking the next sleeper.
  - It warns after `warningDelay` if work never settles.
  - **A causal "settled" in production test tooling**, scoped to one cause, with a
    timeout warning for the never-settles case.
- **Trio `wait_all_tasks_blocked(cushion)`** [src: `trio/_core/_run.py:2250`]. Global,
  not causal: it waits until no task is runnable for `cushion` real seconds.
- **Pony quiescence** [src: `sched/scheduler.c:270-516`]. A global CNF/ACK round when
  every scheduler is blocked and the mute map is empty, which ends the program.
- **Erlang `sys:get_state`** [doc]. A synchronous round trip. It proves FIFO delivery
  of *this sender's* earlier casts and says nothing about what they caused.
- **Akka TestKit `expectNoMessage`** [doc]. Purely time-based.
- **Akka reliable delivery** [doc]. Per-message confirmation. Completion is per
  message, not per cause.

**Implication.**
- `settled()` over refcounted origins has strong precedent in X10 `finish` and Effect's
  WakeTracker.
- The known costs:
  - a shared counter per cause, which X10 had to specialise and credit recovery avoids;
  - never-settling causes (Zone.js);
  - multi-parent work that UCP-style JOIN has to handle.

---

## 7. Specific call-outs

### Prior art for per-origin fuel
- **Ethereum gas** [doc]. One budget per external transaction, spent by every nested
  CALL.
  - EIP-150's 63/64 rule caps what a call can forward, which soft-replaced the 1024
    depth limit (effective depth about 340).
  - Out-of-gas reverts that subcall and spends its gas.
  - It is total-count fuel, the same as F. But it is *synchronous*, and failure is
    transactional, not a panic.
- **TON** [doc]. Asynchronous actor messages. Each hop pays from the value it carries,
  and mode 64 forwards the remaining value. A chain ends when value runs out
  (`cskip_no_gas`).
  - Docs: "multiply totalFwdFee by the number of hops", and there is no rollback.
  - **Fuel is split down the tree, not pooled**, so there is no shared counter, but one
    branch can starve while others hold unused value.
- **AWS Lambda** [doc]. An invocation count per chain in the X-Ray header. At about 16
  it stops, raises `RecursiveInvocationException`, and sends the event to the DLQ.
  - Detection is lost through unsupported services such as DynamoDB streams.
  - **An opt-out (`RecursiveLoop=Allow`) exists for designs that recurse on purpose.**
- **Cloudflare** [doc]. 32 Worker invocations per request, then an exception.
- **IP TTL** [mem]; **Orleans `MaxForwardCount = 2`** [src]; **Orleans / gRPC time
  budgets** [src/doc].
- **Wasmtime fuel** [doc]. Per `Store`, trap on exhaustion. That is per instance, not
  per cause.
- **Not found:** fuel per cause in any actor language or runtime.

### Prior art for refcounted causal completion
- Dijkstra–Scholten, credit recovery, weighted reference counting (§6).
- X10 `finish`, Effect `TestClock` WakeTracker.
- Ray's owner-side refcounts (borrowers, `lineage_ref_count`).
- Zone.js task counts.
- Pony's CNF/ACK (global, not per cause).

### Global caps that failed or punished legitimate load
- **Durable Objects.** Overflowing one isolate's storage cache **resets all objects in
  the isolate** (`actor-cache.c++:279`) [src].
- **Ray lineage.** At 1 GiB it **evicts 50% of all lineage**, making in-scope objects
  unreconstructable regardless of which job caused the growth [src].
- **BEAM sender punishment.** Removed for unpredictable performance on SMP [doc].
- **Pony binary muting.** Collapsed fan-in to about 119 msg/s until #6285 [doc].
- **Verona backpressure.** Removed for deadlock [doc].
- **Lambda loop detection.** A per-cause hop cap, but legitimate recursion tripped it,
  hence the opt-out [doc].
- **Akka's 10 s push timeout default.** Legitimate load sends messages to dead letters
  [src].
- **PFC.** A global lossless guarantee deadlocks on transient loops [doc].
- **Common thread.** A cap at the aggregate level can't tell *who* is responsible, so
  the response is applied to everyone: reset, evict half, slow all senders. The 25k
  case in Ren is the same shape.

### Known pitfalls of causal accounting
1. **Overhead of propagation.**
   - Cheap for an immutable id: Retro reports 0.3–2%, Orleans `#CCR` is ordinary
     context.
   - Expensive when propagation is implicit through every async edge: Node
     AsyncLocalStorage 30–50% before frames; Zone.js was abandoned.
   - Swift deferred task-chain identity for lack of an efficient technique.
2. **Cross-core counters.**
   - A per-origin refcount and a fuel balance are written by every core that runs a
     descendant.
   - X10 used per-place vectors and specialised patterns.
   - Credit recovery and TON avoid the shared counter by *splitting* the budget down
     the tree. The cost is that F becomes per branch rather than per tree (a different
     semantics), and splitting has an underflow edge.
3. **Fan-in / multi-parent causality.**
   - An actor accumulates state from many origins, then one operation posts a flush.
   - Charging the *running* operation's origin is sound for the bound (every post is
     charged to some open origin) but misattributes cause. State-mediated causality
     launders work from one origin into another.
   - Retro needed batch IDs with shares. UCP needed CRDT JOINs.
4. **Long-lived origins.**
   - A session `at` loop, `Docs.each` from `Async.beside`, or a deliberate relay
     (`loop` in actors-post) keeps an origin open indefinitely.
   - That holds an admission slot (N), keeps `settled()` from returning, and burns
     fuel F toward a panic in a legitimate perpetual protocol.
   - Zone.js "never stable" is the precedent; Lambda's opt-out is the patch.
5. **Origin explosion and choosing N and F.**
   - The memory bound is N·F messages. 10k × 1k = 10M, so at least one of the two must
     be small.
   - HTTP/2 and QUIC show that two-level budgets (per stream, per connection) are
     normal. Lambda (16) and Cloudflare (32) chose small fuel. Ethereum prices it.
6. **Nested admission deadlock.**
   - A task holding an open origin that waits at the edge for another origin of the
     same family, while all N slots are held by tasks doing the same, deadlocks.
   - Seastar's "calls in a group should not nest… ABA deadlock" is exactly this.
   - Decision 18's inner-to-outer rule covers slots and mailbox, but would need
     restating for origin slots.
7. **Detection lost at boundaries.**
   - Lambda loses the count through unsupported services. Retro needs manual
     propagation across RPC.
   - In Ren the boundary is anything that isn't a family operation: a channel, a
     `striped` handler, a task started from an actor's state.

---

## 8. Comparison table

| System | Where waiting happens | What's bounded | Granularity | At the bound | Cycles | Deadlock story |
|---|---|---|---|---|---|---|
| **Ren today** (decision 18 + actors-post) | Edge: outside `post` and metered `at` ops | Family mail ≤ `mailbox` from outside; 2×`mailbox` total | Global per family | Edge waits; interior panics | Sibling posts never wait | Inner-to-outer rule; delivery may exceed `max:` |
| **Ren + origins (hypothesis)** | Edge only: opening an origin | Open origins ≤ N; descendants ≤ F each; mail ≤ N·F | Per cause + aggregate | Edge waits; fuel panics with the causal chain | Never wait inside; cross-family by DAG | Origin slots need a nesting rule (Seastar) |
| Pony | Scheduler (muted senders not run) | Nothing hard | Per receiver, heuristic | Sender deprioritised / muted | Overloaded → overloaded exempt | Real deadlocks (#3382); muting blocks quiescence |
| Erlang/OTP | `call` reply; jobs/sbroker queues at caller | `max_heap_size` per process | Per process | Kill | `call` cycles hang to timeout | `calling_self` check; 5 s timeout |
| Akka/Pekko classic | Sender thread (push timeout) | Mailbox capacity | Per actor | Block, then dead letters | Blocking in cycles deadlocks | Docs warn; typed never blocks |
| Akka Streams / reliable delivery / CAF flows | Producer has no demand | Demand / window | Per link | Producer idles | Pipelines; cycles need care | Credit cycles can deadlock |
| Orleans | Caller awaiting response; gateway | Per-activation hard limit (off by default); TTL; forward count 2 | Per activation; per message time | Reject (requests), **silent drop** (one-way), shed at gateway | Call-chain reentrancy | Timeout only (30 s); detection removed |
| Durable Objects | Edge (error to caller) | Queue length / bytes / age per object; 32 invocations per request; isolate memory | Per object; per request; per isolate | `overloaded` error (no retry); exception; **reset all objects** | Interleaving outside storage | Gates only around storage |
| Restate | Per-key durable inbox | Concurrency (preview) | Per key / scope | Queue (unbounded log) | User's problem | Documented deadlocks, manual cancel |
| Verona BoC | Behaviour waits for cowns | None (backpressure removed) | Per cown | — | Atomic multi-cown acquisition | Backpressure removed for deadlock |
| Swift actors | `await` | None | — | — | Reentrancy at every await | No deadlock by construction; interleaving hazards |
| Ray | Caller (`.remote()`) | `max_pending_calls` per handle; lineage 1 GiB | Per handle; global | Error; evict 50% of lineage | — | Owner fate-sharing |
| Effect Cluster | Storage read loop | Mailbox 4096; resident entities 10k | Per entity; per runner | `MailboxFull` (volatile); stay in storage (durable) | — | — |
| Seastar | Semaphore per service group | Nonlocal requests per group | Per group per shard | Wait | **Groups must form a DAG** | Nesting in a group → ABA deadlock |
| FoundationDB | GRV proxy (start of transaction) | Admitted transaction rate, from queue targets (`ServerKnobs.cpp:1083,1109`) | Global, by priority / tag | Delay GRV | Interior never gated | 5 s transaction lifetime (`ServerKnobs.cpp:152`) bounds each origin's life |
| TigerBeetle | Client (one request in flight) | `clients_max`; message pool sized by sum (`message_pool.zig:50-100`) | Per client | Static: can't exceed | — | Pool sized "to ensure… progress, to avoid deadlock" |
| DAGOR | Every hop, consistent by inherited priority | Admission level | Per request priority | Reject (upstream rejects early) | — | — |
| Ethereum | n/a (synchronous) | Gas per transaction; 63/64 forwarding | Per cause | Revert subcall | Gas ends recursion | — |
| TON | n/a | Value carried per message | Per branch (split) | Skip compute, bounce | Value ends chain | No rollback |
| Lambda / Cloudflare / IP | n/a | ~16 / 32 / TTL hops | Per cause (chain) | Stop + DLQ / exception / ICMP drop | Hop count ends loops | Opt-out (Lambda) |
| X10 finish | `finish` end | None | Per finish | — | — | Termination detection cost |
| KPN / Parks | Writer on full buffer | Buffers, grown on artificial deadlock | Per channel | Grow | Grow resolves | Geilen–Basten: local deadlocks missed |
| Tagger / PFC | Switch pause | Buffer per tag | Per hop class | Pause; out of tags → lossy | Monotone tags | Acyclic per-tag graphs |

---

## 9. Open questions for Ren

These are questions, not recommendations.

1. **What is an origin's unit?** Each `post` and each `at` operation, the whole `at`
   block, or the outer task? Per operation keeps origins short-lived and avoids
   Zone.js-style never-settled causes. Per block makes `settled()` mean "everything this
   session caused".
2. **Is fuel F per tree (pooled) or split down the tree?** Pooled (Ethereum) means one
   shared counter per origin written from every core. Split (TON, credit recovery)
   means no hot counter, but a different semantics: one branch can exhaust while the
   tree has budget, and fan-out halves the budget at each level.
3. **Does F count descendants (total work) or depth (hops)?** Depth (TTL, Lambda,
   Cloudflare) bounds chains but not fan-out. Total count bounds both, but also ends
   legitimate long relays. Is a deliberate perpetual protocol (`loop`, a heartbeat
   ring) something Ren must support inside one family, and if so, what restarts its
   origin? An actor-side "this post starts a new origin" would reopen the edge question
   inside the family.
4. **What happens at the fuel bound?** The options are a panic naming the chain (stack
   overflow), failing only the origin (Ethereum-style revert of something with no
   caller), or dropping to a lossy class (Tagger). Each has precedent; only panic
   respects "a post can't fail".
5. **Who pays for state-mediated causality?** When an actor's operation posts because of
   state left by earlier origins, charging the running origin keeps the bound sound but
   makes the panic's "causal chain" misleading. Is attribution only for the bound, or
   also for diagnosis?
6. **How do origin slots nest?** A task with an open origin in family F that makes
   another outside call to F: does it join its existing origin, refuse with `Full`, or
   wait? Seastar says waiting within a group deadlocks. Does the inner-to-outer rule
   extend to origin slots unchanged?
7. **Is the cross-family DAG enough?** Install order gives a DAG of families. Does a
   cross-family post carry its origin, open a new origin in the target family (a
   Tagger-style "tag bump"), or both? Families sharing a cause across a DAG edge could
   double-count or deadlock on N in each.
8. **What does the refcount cost on `work_stealing` and `per_core`?** A shared atomic
   per origin, per-core deltas merged at closing (X10's vectors), or credit splitting?
   Which keeps `sim` replay exact (decision 18's runtime table)?
9. **How do N and F relate to `mailbox:` and `max:`?** Is N·F the new memory knob,
   with `mailbox:` derived from it or retired? Is either sized per partition (`parts:`)?
10. **What does `settled()` promise?** Only that the caller's origins have closed (X10
    `finish`, Effect WakeTracker), or also that their effects are visible? Does it time
    out or warn, as Effect's `warningDelay` does? Is it a test-only tool, given Angular's
    retreat from implicit stability?
11. **How do origins interact with teardown and cancellation?** If the poster's scope
    is cancelled, the origin lives on in the family, as decided. Does cancellation of the
    *family* drop open origins or drain them? actors-post chose drain; the hypothesis
    says teardown waits for open origins. These are the same thing only if every open
    origin has queued mail.
12. **Does an origin's time bound matter?** FoundationDB bounds a transaction's life at
    5 s, and Orleans TTL drops work no one waits for. Ren's origins have no caller
    waiting, so a deadline has no natural source. Is a fuel bound alone enough?
13. **Can model checking still cover it?** The actors-post FizzBee model has 2–3 keys
    and bounds of 1–2. Origins add a per-cause counter and a fuel balance. Can the
    model show "no panic under N·F with legitimate fan-out" and "panic under
    `double`" at those sizes?

---

### Sources consulted

- **Local source (read and grep only).** ponyc, otp (30.0-rc0), seastar, workerd,
  restate, verona-rt, swift-evolution, trio, effect (v4), tigerbeetle, foundationdb.
  Fresh shallow clones: orleans, pekko, caf, ray, all under /tmp/ren-refs.
- **Papers and docs.** Retro NSDI'15; UCP EuroSys'18; DAGOR SoCC'18; HotNets'16
  datacenter deadlocks; Tagger CoNEXT'17; resource containers OSDI'99; Resilient
  Optimistic Termination Detection (ISC'19); EIP-150; TON docs; AWS Lambda recursion
  docs; Cloudflare service-binding and Durable Objects docs; Durable Objects blog
  (2021); Orleans request-scheduling docs and MSR-TR-2014-41; Restate docs; Akka
  mailbox, Streams and reliable-delivery docs; Kotlin `actor` docs and #87; SE-0306;
  ferd.ca (2014, 2016); erlang-questions (2017, 2018); Welsh's SEDA retrospective;
  Angular zoneless and NG0506 docs; Node 24 release notes; Wuyts' 2025 and 2023 posts;
  Smith (2016); ponyc #3382, #2980, #6285; microsoft/verona #183 and #548.
- **From memory, not re-checked:** Dijkstra–Scholten, Mattern/Huang credit recovery,
  weighted reference counting, Parks, Geilen–Basten content, SDF, ATM credits, the
  HTTP/2 and QUIC window details, Dapper / X-Trace / Pivot Tracing details, the
  Google SRE numbers, and Breakwater.

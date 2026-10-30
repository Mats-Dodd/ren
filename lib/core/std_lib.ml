(* The standard library's modules (compiler.md, "Stage 11a", "Two
   standard-library modules"): built into the compiler, as the prelude
   is, each a source in Ren, and found by `import sim` or `import sync`,
   never from a file. Each is checked once, against the whole prelude,
   the intrinsics only the runtime calls among it, since what it is made
   of is the runtime's: `sim.scheduler(seed)` sets the scheduler's
   policy, `sim.clock()` reads its virtual time, and `sync.keyed` is
   built in. Every program has them linked
   in, since `ren test` installs `sim`'s around each test whether the
   program imports it or not (driver.ml).

   Their code is the runtime's in the same way as the prelude's, so it's
   said to be in the prelude's file, [Prelude.file]: a panic in it is
   said at the program's call that reached it, and a native build
   compiles it only if the program reaches it. (Named [Std_lib], since
   [Stdlib] is OCaml's own.) *)

(* The modules' names, which a program's own module can't have. *)
let homes = [ "sim"; "sync" ]

let is_home h = List.mem h homes

(* `sim`: the deterministic runtime, and a clock in its virtual time
   (compiler.md, "Runtimes" and "Virtual time"). *)
let sim =
  {|
// What a test runs in: `ren test` installs `scheduler(seed)` for `Async`
// and `clock()` for `Clock` and `TestClock` around each test, and a
// program can install them itself.

// the runtime of a test: every task on one thread, the next one drawn
// at each scheduling point from a tape of numbers from `seed`, in
// virtual time, which moves only when no task can run, straight to the
// earliest timer. The same seed runs the same way every time
pub fn scheduler(seed: Int) -> Async = sim_runtime(seed)

handler sim_runtime(seed: Int) for Async =
  let was = runtime_sim(seed)
  finally(r) =>
    runtime_leave(was)
    try r
  yield() => async_yield()
  tick() => async_tick()

// a clock in the scheduler's time, virtual under `scheduler`: it reads
// `Time.epoch` when it's installed, sleeping waits until that time has
// moved on, and `TestClock.advance` moves it on at once, waking what it
// passes
pub fn clock() -> (Clock & TestClock uses Async) = sim_clock()

handler sim_clock() for Clock, TestClock uses Async =
  let start = sim_time()
  now() => Time.epoch + Duration.ms(sim_time() - start)
  instant() => Instant.zero + Duration.ms(sim_time() - start)
  sleep(d) => sim_sleep(d.in_ms())
  advance(d) => sim_advance(d.in_ms())

// What a test does with its network: connects to what the program
// listens at, as a client would, and sends the program a signal.
pub dep SimNet =
  // a client's end of a connection to `addr`: it waits while nothing has
  // listened there yet, and is `Refused` once what listened has closed
  connect: fn(addr: Addr) -> Conn ! NetError
  // sends `s` to the program: each `Net.accept_until` waiting for it
  // gives `None`, and so does every later one
  signal: fn(s: Signal)

// a network in memory, for a test: `Net` for the program, `SimNet` for
// the test. Each connection is two ends, each with the bytes sent to it
// that haven't been read yet; a wait is `Async.until`, so it's in the
// scheduler's time, and two tasks' calls take turns
pub fn net() -> (Net & SimNet uses Async) = sim_net()

// one end of a connection: what's been sent to it and not read yet, the
// end it's connected to, and whether it's still open
type NetEnd = { inbox: Array<Int>, peer: Int, open: Bool }

handler sim_net() for Net, SimNet uses Async =
  // what's listening, by its number: its address
  var listening: Map<Int, Addr> = Map.empty
  // each listener's connections not accepted yet, by its number, the
  // first first
  var waiting: Map<Int, Array<Int>> = Map.empty
  // the addresses whose listener has closed
  var gone: Array<Addr> = []
  // each end of a connection, by its number
  var ends: Map<Int, NetEnd> = Map.empty
  // the signals sent so far
  var signals: Array<Int> = []
  // the last number given to a listener or an end
  var numbered = 0
  listen(addr) =>
    if listening.values().includes(addr) then fail InUse(addr)
    numbered += 1
    &listening.set(numbered, addr)
    &waiting.set(numbered, [])
    unsafe_cast(numbered)
  accept(l) =>
    let n: Int = unsafe_cast(l)
    Async.until fn() => not listening.includes(n) || queued(waiting, n) > 0
    if not listening.includes(n) then fail Closed
    let q = waiting.get(n).unwrap_or([])
    &waiting.set(n, q.drop(1))
    unsafe_cast(q[0])
  accept_until(l, stop) =>
    let n: Int = unsafe_cast(l)
    let s: Int = unsafe_cast(stop)
    Async.until fn() =>
      signals.includes(s) || not listening.includes(n) || queued(waiting, n) > 0
    if signals.includes(s) then
      // it stops listening, and the connections it hasn't accepted are
      // closed; those in flight have the cleanup deadline
      match listening.get(n)
        Some(addr) =>
          &gone.push(addr)
          &listening.remove(n)
          for b in waiting.get(n).unwrap_or([])
            &ends.set(b, closed_end(ends, b))
          &waiting.remove(n)
        None => ()
      task_drain()
      None
    else
      if not listening.includes(n) then fail Closed
      let q = waiting.get(n).unwrap_or([])
      &waiting.set(n, q.drop(1))
      Some(unsafe_cast(q[0]))
  read(c, max) =>
    if max < 1 then fail NetFailed("a read takes at least 1 byte, or it couldn't tell that from the end")
    let n: Int = unsafe_cast(c)
    Async.until fn() => readable(ends, n)
    match ends.get(n)
      Some(e) =>
        if not e.open then fail Closed
        let k = if max < e.inbox.len() then max else e.inbox.len()
        &ends.set(n, NetEnd { inbox: e.inbox.drop(k), peer: e.peer, open: true })
        Bytes.of(e.inbox.take(k))
      None => fail Closed
  write(c, b) =>
    let n: Int = unsafe_cast(c)
    match ends.get(n)
      Some(e) =>
        if not e.open then fail Closed
        match ends.get(e.peer)
          Some(p) =>
            if not p.open then fail Closed
            var inbox = p.inbox
            for i in 0..b.len()
              &inbox.push(b.at(i))
            &ends.set(e.peer, NetEnd { inbox: inbox, peer: p.peer, open: true })
          None => fail Closed
      None => fail Closed
  close(c) =>
    let n: Int = unsafe_cast(c)
    &ends.set(n, closed_end(ends, n))
  connect(addr) =>
    Async.until fn() => listening.values().includes(addr) || gone.includes(addr)
    match listening.find(fn((_, a)) => a == addr)
      Some((l, _)) =>
        numbered += 2
        let mine = numbered - 1
        let theirs = numbered
        &ends.set(mine, NetEnd { inbox: [], peer: theirs, open: true })
        &ends.set(theirs, NetEnd { inbox: [], peer: mine, open: true })
        var q = waiting.get(l).unwrap_or([])
        &q.push(theirs)
        &waiting.set(l, q)
        unsafe_cast(mine)
      None => fail Refused(addr)
  signal(s) => &signals.push(unsafe_cast(s))

// how many connections the listener numbered `n` has that it hasn't
// accepted
fn queued(waiting: Map<Int, Array<Int>>, n: Int) -> Int = waiting.get(n).unwrap_or([]).len()

// whether a read of the end numbered `n` can give something now: bytes,
// or the other end closed, or this one, which is `Closed`
fn readable(ends: Map<Int, NetEnd>, n: Int) -> Bool =
  match ends.get(n)
    Some(e) => not e.open || e.inbox.len() > 0 || not open_at(ends, e.peer)
    None => true

// whether the end numbered `n` is open
fn open_at(ends: Map<Int, NetEnd>, n: Int) -> Bool =
  match ends.get(n)
    Some(e) => e.open
    None => false

// the end numbered `n`, closed
fn closed_end(ends: Map<Int, NetEnd>, n: Int) -> NetEnd =
  match ends.get(n)
    Some(e) => NetEnd { inbox: e.inbox, peer: e.peer, open: false }
    None => NetEnd { inbox: [], peer: 0, open: false }

// A program `sim.proc()` runs: the command, what it exits with, and how
// long it takes to.
pub type Run = { command: Command, code: Int, takes: Duration }

// What a test asks of its programs, besides `TestProc.ran()`.
pub dep SimProc =
  // the commands cancelled while they ran, the first first: a real
  // `Proc.run` kills those
  killed: fn() -> Array<Command>
  // how each of those was to be killed, in the same order: its process
  // group, `Tree`, or itself, `Child`
  kills: fn() -> Array<Kill>

// programs that take time, for a test: each `Proc.run` of a command one
// of `runs` names takes its `takes` of the scheduler's time and exits
// with its `code`, and any other exits with 0 at once, as `test_proc`'s
// does. A program's time passes without it keeping the instance, so two
// tasks' programs run at once
pub fn proc(runs: Array<Run>) -> (Proc & TestProc & SimProc uses Async) = sim_proc(runs)

handler sim_proc(runs: Array<Run>) for Proc, TestProc, SimProc uses Async =
  var commands: Array<Command> = []
  var cancelled: Array<Command> = []
  var kinds: Array<Kill> = []
  run(cmd, args, kill) =>
    let c = Command { cmd: cmd, args: args }
    &commands.push(c)
    // what it exits with, and how long it takes to, in milliseconds
    var code = 0
    var takes = 0
    for r in runs
      if r.command == c then
        code = r.code
        takes = r.takes.in_ms()
    // the time it's done at: the instance is released then, which checks
    // the condition below again
    let done = sim_time() + takes
    // what it gives once cancelled is thrown away: the cancel goes on
    finally(out) =>
      match out
        Ok(code) => code
        Err(_) =>
          &cancelled.push(c)
          &kinds.push(kill)
          0
    if takes > 0 then
      sim_alarm(done)
      Async.until fn() => sim_time() >= done
    code
  ran() => commands
  killed() => cancelled
  kills() => kinds
|}

(* `sync`: what tasks share, written once (compiler.md, "The standard
   library (step 8)"): a channel, a semaphore, a limit over any
   dependency, and a batcher, each waiting in `Async.until`, so each
   uses `Async`; and `keyed`, which is built in. *)
let sync =
  {|
// What tasks share. Each handler here waits in `Async.until`, which lets
// go of its instance while it waits, so another task's operation can
// change what it waits for.

// ---- channels ----

// a queue of `T`s from some tasks to others, holding at most its
// capacity: what's sent first is received first
pub dep Chan<T> =
  // puts `x` at the end, waiting while the channel is full. A send on a
  // closed channel panics
  send: fn(x: T)
  // the first thing sent, waiting while there's none and the channel is
  // open: `None` once it's closed and empty
  recv: fn() -> Option<T>
  // says nothing more will be sent: what was sent can still be received
  close: fn()

  // what's received, until the channel is closed and empty: a cursor whose
  // `next` is `recv()`, pulled where it's written, in a `for` or as a pull
  // argument, `Async.each(Events.items())` (streams.md, "Channels")
  pub fn items() -> Items<T> uses Chan<T> = Items {}

// what a channel's `items()` gives: a cursor over the channel it's pulled
// from, which holds nothing of it
pub type Items<T> = opaque {}
  pub fn next(inout self) -> Option<T> uses Chan<T> = Chan.recv()

// a channel holding at most `cap`, 1 or more
pub handler channel<T>(cap: Int) for Chan<T> uses Async =
  var items: Array<T> = []
  var closed = false
  send(x) =>
    if cap < 1 then lib_panic("a channel's capacity is at least 1, so it has room for a send")
    Async.until fn() => closed || items.len() < cap
    if closed then lib_panic("a send on a closed channel")
    &items.push(x)
  recv() =>
    Async.until fn() => closed || items.len() > 0
    if items.len() == 0 then None
    else
      let x = items[0]
      items = items.drop(1)
      Some(x)
  close() => closed = true

// ---- semaphores and limits ----

// permits, each held by one caller at a time: `acquire` and `release`
// are the two halves of holding one, which is how a handler's calls can
// overlap while its operations don't
pub dep Semaphore =
  // takes a permit, waiting while there's none
  acquire: fn()
  // gives back a permit taken: one more than was taken panics
  release: fn()

// `n` permits, 1 or more
pub handler semaphore(n: Int) for Semaphore uses Async =
  var free = n
  acquire() =>
    if n < 1 then lib_panic("a semaphore has at least 1 permit, so it can give one")
    Async.until fn() => free > 0
    free -= 1
  release() =>
    if free >= n then lib_panic("a semaphore's permit given back that wasn't taken")
    free += 1

// over any dependency: each call takes a permit from the `Semaphore`
// installed outside it, is passed on, and gives the permit back however
// it ends, cancelled too. So `with sync.semaphore(16), sync.limit() over
// Web in` makes at most 16 calls of `Web` at once. It keeps no state, so
// its calls overlap; the semaphore's `acquire` is what waits
pub handler limit() over any uses Semaphore =
  call =>
    Semaphore.acquire()
    finally(r) =>
      Semaphore.release()
      try r
    try call.forward()

// ---- batching ----

// what a batcher fetches with: the values of many keys in one call
pub dep Fetch<K, V> =
  // the values of `keys`, each it has
  fetch: fn(keys: Array<K>) -> Map<K, V>

// keys asked for one at a time, by many tasks, and fetched together
pub dep Batcher<K, V> =
  // the value of `k`, once a `flush` has fetched it
  get: fn(k: K) -> V
  // returns once a key has been asked for that no `flush` has fetched
  // yet, so a flusher waits here rather than going round for nothing
  asked: fn()
  // fetches every key asked for since the last flush, in one call
  flush: fn()

// a batcher over the `Fetch` installed outside it. Each value fetched is
// kept, so a key asked for again is answered at once. Its flushes are
// a task's, beside the `with`'s body, which waits for a key to be asked
// for, lets every task that can run ask for theirs, and fetches them:
//
//   with sync.batcher() in
//     Async.beside(fn() => flushing()) fn() => ...
//
//   fn flushing() uses Batcher<K, V>, Async =
//     while true
//       Batcher.asked()
//       Async.tick()
//       Batcher.flush()
pub handler batcher<K has hash, V>() for Batcher<K, V> uses Fetch<K, V>, Async =
  // the keys asked for and not fetched yet, the first first
  var wanted: Array<K> = []
  // the values fetched, and the keys a fetch was asked for and didn't
  // give, by their key
  var got: Map<K, V> = Map.empty
  var missing: Set<K> = Set.empty
  get(k) =>
    if not got.includes(k) && not missing.includes(k) && not wanted.any(fn(w) => w == k) then
      &wanted.push(k)
    Async.until fn() => got.includes(k) || missing.includes(k)
    got.get(k) orelse lib_panic("`Fetch.fetch` didn't give a value for a key it was asked for")
  asked() => Async.until fn() => wanted.len() > 0
  flush() =>
    if wanted.len() > 0 then
      let keys = wanted
      let found = Fetch.fetch(keys)
      for k in keys
        match found.get(k)
          Some(v) => &got.set(k, v)
          None => &missing.add(k)
      wanted = []

// ---- keyed instances ----

// `n` instances of the handler `h` describes, 1 or more, made in order
// when it's installed: each call of an operation goes to one of them by
// its first argument's key, its type's `key` if it has one, so the same
// key always goes to the same instance, and calls on keys in different
// instances overlap; an operation with no parameters goes to each in
// turn, and gives what the last gave. Each instance is one as any other,
// with its own state and its own `finally`, the last made's run first.
// It's built in, since a handler can't keep instances of another
pub fn keyed<T>(n: Int, h: T) -> T = sync_keyed(n, h)
|}

(* Each module's source, by its name; a name of [homes] without one
   isn't written yet. *)
let sources = [ ("sim", sim); ("sync", sync) ]
let source h = List.assoc_opt h sources

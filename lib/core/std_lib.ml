(* The standard library's modules (compiler.md, "Stage 11a", "Two
   standard-library modules"): built into the compiler, as the prelude
   is, each a source in Ren, and found by `import sim`, never from a
   file. Each is checked once, against the whole prelude, the intrinsics
   only the runtime calls among it, since what it is made of is the
   runtime's: `sim.scheduler(seed)` sets the scheduler's policy, and
   `sim.clock()` reads its virtual time. Every program has them linked
   in, since `ren test` installs `sim`'s around each test whether the
   program imports it or not (driver.ml).

   Their code is the runtime's in the same way as the prelude's, so it's
   said to be in the prelude's file, [Prelude.file]: a panic in it is
   said at the program's call that reached it, and a native build
   compiles it only if the program reaches it. (Named [Std_lib], since
   [Stdlib] is OCaml's own.) *)

(* The modules' names, which a program's own module can't have: `sync`
   is reserved for stage 11a's step 8, which writes it. *)
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
|}

(* Each module's source, by its name; a name of [homes] without one
   isn't written yet. *)
let sources = [ ("sim", sim) ]
let source h = List.assoc_opt h sources

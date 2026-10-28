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
|}

(* Each module's source, by its name; a name of [homes] without one
   isn't written yet. *)
let sources = [ ("sim", sim) ]
let source h = List.assoc_opt h sources

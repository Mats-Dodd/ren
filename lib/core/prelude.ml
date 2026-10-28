(* The prelude: what every Ren program can use without declaring it.

   It's a module like any other, whose interface every program is checked
   against (driver.ml). It comes in two halves. [source] is written in Ren
   itself, and checked like any module. Everything else is built into the
   compiler (intrinsic), because it can't be written in Ren yet. Each such
   function is named by an id (intrinsic.ml), and below are its type and
   where it's listed: everything the passes before the interpreter need
   to know about it. What it does when it runs is the interpreter's half,
   eval/builtins.ml. So adding a built-in means adding its id, an entry
   here, and its implementation there, and the compiler points out any
   [match] that's missing it. *)

(* The file its source is said to be in, which no message can show. *)
let file = "<prelude>"

let source =
  {|
pub type Option<T> =
  | Some(value: T)
  | None

  pub fn is_some(self) -> Bool =
    match self
      Some(_) => true
      None => false
  pub fn unwrap_or(self, d: T) -> T =
    match self
      Some(x) => x
      None => d

pub type Result<T, E> =
  | Ok(value: T)
  | Err(error: E)

// ---- collections (operators.md, "The collection methods") ----
//
// `len`, `push` and `sort` are built into the compiler, as `Map`'s and
// `Set`'s finding by hash is; the rest are written here. A method that
// changes nothing gives a new collection. One that takes a function only
// calls it, so whatever it can fail with and uses, the call can too, and
// one that stops early, `find`, `any` and `all`, calls it no more once it
// knows.

pub type Array<T> = builtin
  // the element at `i`, if there is one: `xs[i]` says it's there, and
  // panics if it isn't; `get` asks
  pub fn get(self, i: Int) -> Option<T> =
    if i >= 0 && i < self.len() then Some(self[i]) else None
  pub fn first(self) -> Option<T> = self.get(0)
  pub fn last(self) -> Option<T> = self.get(self.len() - 1)
  // each element through `f`. If nothing else holds this array and a
  // `U` is kept as a `T` is, each element is replaced where it is, and
  // the array is the new one (Lean's `Array.mapMUnsafe`); otherwise the
  // new array is made with room for them all at once
  pub fn map<U>(self, f: fn(T) -> U) -> Array<U> =
    let into: MapInto<U> = map_into(self)
    match into
      InPlace =>
        var out = self
        for i in 0..out.len()
          out[i] = unsafe_cast(try f(out[i]))
        unsafe_cast(out)
      Fresh => try self.map_fresh(f)
  // `map` into a new array, made with room for every element at once
  fn map_fresh<U>(self, f: fn(T) -> U) -> Array<U> =
    var out: Array<U> = array_reserve(self.len())
    for x in self
      &out.push(try f(x))
    out
  // each element through `f`, which gives an array, all of them joined
  pub fn flat_map<U>(self, f: fn(T) -> Array<U>) -> Array<U> =
    var out: Array<U> = []
    for x in self
      for y in try f(x)
        &out.push(y)
    out
  // the elements `f` is true of
  pub fn select(self, f: fn(T) -> Bool) -> Array<T> =
    var out: Array<T> = []
    for x in self
      if try f(x) then &out.push(x)
    out
  // the elements `f` is false of
  pub fn reject(self, f: fn(T) -> Bool) -> Array<T> =
    var out: Array<T> = []
    for x in self
      if not (try f(x)) then &out.push(x)
    out
  // the first element `f` is true of
  pub fn find(self, f: fn(T) -> Bool) -> Option<T> =
    var found = None
    for x in self
      if not found.is_some() then
        if try f(x) then found = Some(x)
    found
  // where `x` first is
  pub fn index(self, x: T) -> Option<Int> =
    var found = None
    var i = 0
    for y in self
      if not found.is_some() && y == x then found = Some(i)
      i += 1
    found
  // whether `f` is true of any element
  pub fn any(self, f: fn(T) -> Bool) -> Bool =
    var yes = false
    for x in self
      if not yes then
        if try f(x) then yes = true
    yes
  // whether `f` is true of every element
  pub fn all(self, f: fn(T) -> Bool) -> Bool =
    var yes = true
    for x in self
      if yes then
        if not (try f(x)) then yes = false
    yes
  // how many elements `f` is true of
  pub fn count(self, f: fn(T) -> Bool) -> Int =
    var n = 0
    for x in self
      if try f(x) then n += 1
    n
  // whether `x` is in it
  pub fn includes(self, x: T) -> Bool =
    var yes = false
    for y in self
      if y == x then yes = true
    yes
  // `f` on each element, in order: a block that changes a `var` outside
  // it, `xs.each(fn(x) => total += x)`
  pub fn each(self, f: fn(T)) =
    for x in self
      try f(x)
  // `f` over each element in turn, from `init`
  pub fn reduce<A>(self, init: A, f: fn(A, T) -> A) -> A =
    var acc = init
    for x in self
      acc = try f(acc, x)
    acc
  // every element added up, from `T.zero`, in order; but `Float`s, in
  // eight lanes added pairwise, the same on every machine, which a
  // vector unit can do (foundations.md, decision 15; `float_sum`)
  pub fn sum(self) -> T =
    if float_lanes(self) then float_sum(self)
    else
      var total = T.zero
      for x in self
        total = total + x
      total
  // the least element, the first of those equal
  pub fn min(self) -> Option<T> =
    var best = None
    for x in self
      match best
        Some(b) => if x < b then best = Some(x)
        None => best = Some(x)
    best
  // the greatest element, the first of those equal
  pub fn max(self) -> Option<T> =
    var best = None
    for x in self
      match best
        Some(b) => if x > b then best = Some(x)
        None => best = Some(x)
    best
  // the element `f` gives the least of, the first of those equal; `f`
  // is called once for each
  pub fn min_by<K>(self, f: fn(T) -> K) -> Option<T> =
    var best = None
    for x in self
      let k = try f(x)
      match best
        Some((b, _)) => if k < b then best = Some((k, x))
        None => best = Some((k, x))
    match best
      Some((_, x)) => Some(x)
      None => None
  // the element `f` gives the greatest of, the first of those equal
  pub fn max_by<K>(self, f: fn(T) -> K) -> Option<T> =
    var best = None
    for x in self
      let k = try f(x)
      match best
        Some((b, _)) => if k > b then best = Some((k, x))
        None => best = Some((k, x))
    match best
      Some((_, x)) => Some(x)
      None => None
  // in the order of what `f` gives each, called once for each; equal ones
  // stay in the order they were
  pub fn sort_by<K>(self, f: fn(T) -> K) -> Array<T> =
    var keyed: Array<(K, Int)> = []
    for (i, x) in self.with_index()
      &keyed.push((try f(x), i))
    var out: Array<T> = []
    for (_, i) in keyed.sort()
      &out.push(self[i])
    out
  // each thing `f` gives, with the elements that gave it, in order
  pub fn group_by<K>(self, f: fn(T) -> K) -> Map<K, Array<T>> =
    var groups: Map<K, Array<T>> = Map.empty
    for x in self
      let k = try f(x)
      var xs = groups.get(k).unwrap_or([])
      &xs.push(x)
      &groups.set(k, xs)
    groups
  // the elements `f` is true of, and the rest
  pub fn partition(self, f: fn(T) -> Bool) -> (Array<T>, Array<T>) =
    var yes: Array<T> = []
    var no: Array<T> = []
    for x in self
      if try f(x) then &yes.push(x) else &no.push(x)
    (yes, no)
  // each element, with how many times it's there
  pub fn tally(self) -> Map<T, Int> =
    var counts: Map<T, Int> = Map.empty
    for x in self
      &counts.set(x, counts.get(x).unwrap_or(0) + 1)
    counts
  // without repeats, the first of each kept
  pub fn uniq(self) -> Array<T> =
    var seen: Set<T> = Set.empty
    var out: Array<T> = []
    for x in self
      if not seen.includes(x) then
        &seen.add(x)
        &out.push(x)
    out
  // each element with the one at its place in `ys`, as long as both have
  // one: a cursor, `for (x, y) in xs.zip(ys)`, which makes no array of
  // the pairs (`Zip`)
  pub fn zip<U>(self, ys: Array<U>) -> Zip<T, U> = Zip { xs: self, ys: ys, at: 0 }
  // each element with where it is, counting from 0
  pub fn with_index(self) -> Array<(Int, T)> =
    var out: Array<(Int, T)> = []
    for i in 0..self.len()
      &out.push((i, self[i]))
    out
  // the first `n` elements, or all of them if there are fewer
  pub fn take(self, n: Int) -> Array<T> =
    assert n >= 0
    var out: Array<T> = []
    for i in 0..(if n < self.len() then n else self.len())
      &out.push(self[i])
    out
  // all but the first `n` elements
  pub fn drop(self, n: Int) -> Array<T> =
    assert n >= 0
    var out: Array<T> = []
    for i in n..self.len()
      &out.push(self[i])
    out
  // last first
  pub fn reverse(self) -> Array<T> =
    var out: Array<T> = []
    for i in 0..self.len()
      &out.push(self[self.len() - 1 - i])
    out

// Keys and their values, found by the key's hash, in the order each key
// was first set. Besides what's built in, `get`, `set`, `remove`,
// `includes(k)`, `keys`, `values` and `len`, it has `Array`'s methods,
// over its `(k, v)` pairs: those that keep some of them give a `Map`.
pub type Map<K, V> = builtin
  pub let empty: Map<K, V> = map_empty()
  // its pairs, in order, as `for` goes over them
  fn pairs(self) -> Array<(K, V)> =
    var out: Array<(K, V)> = []
    for p in self
      &out.push(p)
    out
  pub fn first(self) -> Option<(K, V)> = self.pairs().first()
  pub fn last(self) -> Option<(K, V)> = self.pairs().last()
  pub fn map<U>(self, f: fn((K, V)) -> U) -> Array<U> = try self.pairs().map(f)
  pub fn flat_map<U>(self, f: fn((K, V)) -> Array<U>) -> Array<U> =
    try self.pairs().flat_map(f)
  pub fn select(self, f: fn((K, V)) -> Bool) -> Map<K, V> =
    Map.of(try self.pairs().select(f))
  pub fn reject(self, f: fn((K, V)) -> Bool) -> Map<K, V> =
    Map.of(try self.pairs().reject(f))
  pub fn find(self, f: fn((K, V)) -> Bool) -> Option<(K, V)> =
    try self.pairs().find(f)
  pub fn any(self, f: fn((K, V)) -> Bool) -> Bool = try self.pairs().any(f)
  pub fn all(self, f: fn((K, V)) -> Bool) -> Bool = try self.pairs().all(f)
  pub fn count(self, f: fn((K, V)) -> Bool) -> Int = try self.pairs().count(f)
  pub fn reduce<A>(self, init: A, f: fn(A, (K, V)) -> A) -> A =
    try self.pairs().reduce(init, f)
  pub fn min(self) -> Option<(K, V)> = self.pairs().min()
  pub fn max(self) -> Option<(K, V)> = self.pairs().max()
  pub fn min_by<B>(self, f: fn((K, V)) -> B) -> Option<(K, V)> =
    try self.pairs().min_by(f)
  pub fn max_by<B>(self, f: fn((K, V)) -> B) -> Option<(K, V)> =
    try self.pairs().max_by(f)
  pub fn sort(self) -> Array<(K, V)> = self.pairs().sort()
  pub fn sort_by<B>(self, f: fn((K, V)) -> B) -> Array<(K, V)> =
    try self.pairs().sort_by(f)
  pub fn group_by<B>(self, f: fn((K, V)) -> B) -> Map<B, Array<(K, V)>> =
    try self.pairs().group_by(f)
  pub fn partition(self, f: fn((K, V)) -> Bool) -> (Map<K, V>, Map<K, V>) =
    let (yes, no) = try self.pairs().partition(f)
    (Map.of(yes), Map.of(no))
  pub fn zip<U>(self, ys: Array<U>) -> Zip<(K, V), U> = self.pairs().zip(ys)
  pub fn with_index(self) -> Array<(Int, (K, V))> = self.pairs().with_index()
  pub fn take(self, n: Int) -> Map<K, V> = Map.of(self.pairs().take(n))
  pub fn drop(self, n: Int) -> Map<K, V> = Map.of(self.pairs().drop(n))
  pub fn reverse(self) -> Map<K, V> = Map.of(self.pairs().reverse())

// Two arrays gone over together, a pair of elements at a time, from `at`,
// as long as both have one: what `xs.zip(ys)` gives, a cursor (stdlib.md,
// "Streams: cursors first"). A `for` over `xs.zip(ys)` itself counts
// along both arrays at once, with no `Zip` made and one bounds check for
// the loop, the shorter length (lower.ml, `zip_loop`)
pub type Zip<T, U> = opaque { xs: Array<T>, ys: Array<U>, at: Int }
  pub fn next(inout self) -> Option<(T, U)> =
    let i = self.at
    if i >= 0 && i < self.xs.len() && i < self.ys.len() then
      self.at += 1
      Some((self.xs[i], self.ys[i]))
    else None
  // and a third array's elements: `xs.zip(ys).zip(zs)` gives `(x, y, z)`s
  pub fn zip<V>(self, zs: Array<V>) -> Zip3<T, U, V> =
    Zip3 { xs: self.xs, ys: self.ys, zs: zs, at: self.at }

// Three arrays gone over together, as `Zip` goes over two
pub type Zip3<T, U, V> = opaque { xs: Array<T>, ys: Array<U>, zs: Array<V>, at: Int }
  pub fn next(inout self) -> Option<(T, U, V)> =
    let i = self.at
    if i >= 0 && i < self.xs.len() && i < self.ys.len() && i < self.zs.len() then
      self.at += 1
      Some((self.xs[i], self.ys[i], self.zs[i]))
    else None

// Each value once, found by its hash, in the order each was first added.
// Besides what's built in, `add`, `remove`, `includes` and `len`, it has
// `Array`'s methods: those that keep some of its members give a `Set`.
pub type Set<T> = builtin
  pub let empty: Set<T> = set_empty()
  // its members, in order, as `for` goes over them
  fn members(self) -> Array<T> =
    var out: Array<T> = []
    for x in self
      &out.push(x)
    out
  pub fn first(self) -> Option<T> = self.members().first()
  pub fn last(self) -> Option<T> = self.members().last()
  pub fn map<U>(self, f: fn(T) -> U) -> Array<U> = try self.members().map(f)
  pub fn flat_map<U>(self, f: fn(T) -> Array<U>) -> Array<U> =
    try self.members().flat_map(f)
  pub fn select(self, f: fn(T) -> Bool) -> Set<T> =
    Set.of(try self.members().select(f))
  pub fn reject(self, f: fn(T) -> Bool) -> Set<T> =
    Set.of(try self.members().reject(f))
  pub fn find(self, f: fn(T) -> Bool) -> Option<T> = try self.members().find(f)
  pub fn any(self, f: fn(T) -> Bool) -> Bool = try self.members().any(f)
  pub fn all(self, f: fn(T) -> Bool) -> Bool = try self.members().all(f)
  pub fn count(self, f: fn(T) -> Bool) -> Int = try self.members().count(f)
  pub fn reduce<A>(self, init: A, f: fn(A, T) -> A) -> A =
    try self.members().reduce(init, f)
  pub fn sum(self) -> T = self.members().sum()
  pub fn min(self) -> Option<T> = self.members().min()
  pub fn max(self) -> Option<T> = self.members().max()
  pub fn min_by<B>(self, f: fn(T) -> B) -> Option<T> = try self.members().min_by(f)
  pub fn max_by<B>(self, f: fn(T) -> B) -> Option<T> = try self.members().max_by(f)
  pub fn sort(self) -> Array<T> = self.members().sort()
  pub fn sort_by<B>(self, f: fn(T) -> B) -> Array<T> = try self.members().sort_by(f)
  pub fn group_by<B>(self, f: fn(T) -> B) -> Map<B, Array<T>> =
    try self.members().group_by(f)
  pub fn partition(self, f: fn(T) -> Bool) -> (Set<T>, Set<T>) =
    let (yes, no) = try self.members().partition(f)
    (Set.of(yes), Set.of(no))
  pub fn zip<U>(self, ys: Array<U>) -> Zip<T, U> = self.members().zip(ys)
  pub fn with_index(self) -> Array<(Int, T)> = self.members().with_index()
  pub fn take(self, n: Int) -> Set<T> = Set.of(self.members().take(n))
  pub fn drop(self, n: Int) -> Set<T> = Set.of(self.members().drop(n))
  pub fn reverse(self) -> Set<T> = Set.of(self.members().reverse())

// ---- time ----
//
// Inside the prelude each is a number of milliseconds. A `Duration` is a
// number of its own (operators.md, "Number types"); a `Time` and an
// `Instant` are moments, so two can be told apart, giving a `Duration`,
// and one moved on by a `Duration`, but not added together.

// how long something takes
pub type Duration = opaque Int with numeric
  pub fn ms(n: Int) -> Duration = n
  pub fn seconds(n: Int) -> Duration = n * 1000
  pub fn minutes(n: Int) -> Duration = n * 60000
  // how many milliseconds it is
  pub fn in_ms(self) -> Int = self

// a moment on the calendar: since the epoch, 1970-01-01 00:00 UTC
pub type Time = opaque Int
  pub let epoch: Time = 0
  pub fn add(self, d: Duration) -> Time = self + d.in_ms()
  pub fn sub(self, t: Time) -> Duration = Duration.ms(self - t)
  pub fn sub(self, d: Duration) -> Time = self - d.in_ms()
  // ordered by when it is
  fn key(self) -> Int = self

// a moment for measuring how long something took, on a clock that never
// goes back: an instant means nothing on its own, only next to another
pub type Instant = opaque Int
  pub let zero: Instant = 0
  pub fn add(self, d: Duration) -> Instant = self + d.in_ms()
  pub fn sub(self, i: Instant) -> Duration = Duration.ms(self - i)
  pub fn sub(self, d: Duration) -> Instant = self - d.in_ms()
  // ordered by when it is
  fn key(self) -> Int = self

// ---- paths ----

// where a file is, as the system writes it: names with `/` between them
pub type Path = opaque Str
  pub fn of(s: Str) -> Path = s
  // `name` inside this path, or `name` itself if it starts at the root
  pub fn join(self, name: Str) -> Path =
    if self == "" || name.starts_with("/") then name
    else
      // a path that ends in `/` has an empty last part
      let parts = self.split("/")
      if parts[parts.len() - 1] == "" then self.concat(name)
      else self.concat("/").concat(name)
  pub fn show(self) -> Str = self

// ---- the built-in dependencies (deps.md, "Built in") ----
//
// The runtime installs each one's `real` around `main`, if `main` uses
// it. It's private: nothing else can install the world.

pub dep Clock =
  now: fn() -> Time
  instant: fn() -> Instant
  sleep: fn(d: Duration)

  // a clock stopped at `at`, that never sleeps
  pub fn frozen(at: Time) -> Clock = frozen_clock(at)
  let real: Clock = real_clock()

handler frozen_clock(at: Time) for Clock =
  now() => at
  instant() => Instant.zero
  sleep(_) => ()

handler real_clock() for Clock =
  now() => clock_now()
  instant() => clock_instant()
  sleep(d) => clock_sleep(d)

pub dep Random =
  // a number from 0 up to, but not including, `below`
  int: fn(below: Int) -> Int

  let real: Random = real_random()

handler real_random() for Random =
  int(below) => random_int(below)

pub dep Console =
  write: fn(line: Str)
  // a line apart from what the program writes: how it's going, or what
  // went wrong
  error: fn(line: Str)

  let real: Console = real_console()

handler real_console() for Console =
  write(line) => console_write(line)
  error(line) => console_error(line)

// what any value shows as, on a line of its own
pub fn print<T>(x: T) uses Console = Console.write(show(x))

// a file: where it is, and what's in it
pub type File = { path: Path, data: Bytes }

// every way the real `Fs` can fail: there's nothing at the path, the
// system won't let this program at it, it's a folder, or something else
// went wrong, which the system gives its reason for
pub type FsError =
  ! NoSuchFile(path: Path) | NotAllowed(path: Path) | IsAFolder(path: Path) | FsFailed(path: Path, reason: Str)

// what the system said to a read or a write, which `fs_checked` turns
// into its value or its error
// how `Array.map` makes its array of `T`s (`map_into`)
type MapInto<T> =
  | InPlace
  | Fresh

type FsOutcome<T> =
  | FsDone(value: T)
  | FsMissing
  | FsDenied
  | FsFolder
  | FsOther(reason: Str)

fn fs_checked<T>(o: FsOutcome<T>, p: Path) -> T ! FsError =
  match o
    FsDone(v) => v
    FsMissing => fail NoSuchFile(p)
    FsDenied => fail NotAllowed(p)
    FsFolder => fail IsAFolder(p)
    FsOther(reason) => fail FsFailed(p, reason)

pub dep Fs =
  read: fn(p: Path) -> Bytes ! FsError
  // makes the file, or replaces what's in it
  write: fn(p: Path, b: Bytes) ! FsError
  exists: fn(p: Path) -> Bool

  // what's in a file, as a string
  pub fn read_str(p: Path) -> Str ! FsError | InvalidUtf8 uses Fs =
    let b = try Fs.read(p)
    try Str.from_utf8(b)
  let real: Fs = real_fs()

handler real_fs() for Fs =
  read(p) => try fs_checked(fs_read(p), p)
  write(p, b) => try fs_checked(fs_write(p, b), p)
  exists(p) => fs_exists(p)

pub dep Os =
  // what `ren run file.ren -- args` was given after the `--`
  args: fn() -> Array<Str>

  let real: Os = real_os()

handler real_os() for Os =
  args() => os_args()

// every way the real `Proc` can fail: there's no such program, the
// system wouldn't start it, with its reason, or it was killed before it
// could exit
pub type ProcError = ! NoSuchProgram(name: Str) | CantRun(name: Str, reason: Str) | Killed(name: Str)

// what became of a program, which `proc_checked` turns into its exit code
// or its error
type ProcOutcome =
  | ProcExited(code: Int)
  | ProcMissing
  | ProcNotStarted(reason: Str)
  | ProcKilled

fn proc_checked(o: ProcOutcome, cmd: Str) -> Int ! ProcError =
  match o
    ProcExited(code) => code
    ProcMissing => fail NoSuchProgram(cmd)
    ProcNotStarted(reason) => fail CantRun(cmd, reason)
    ProcKilled => fail Killed(cmd)

pub dep Proc =
  // runs the program `cmd`, found on `PATH` unless it has a `/` in it,
  // with what this program prints to and reads from, and gives back its
  // exit code
  run: fn(cmd: Str, args: Array<Str>) -> Int ! ProcError

  let real: Proc = real_proc()

handler real_proc() for Proc =
  run(cmd, args) => try proc_checked(proc_run(cmd, args), cmd)

// ---- tasks (async.md; foundations.md, decisions 7 and 9) ----
//
// The runtime is a handler of `Async`, installed around `main` as the
// world is. Its operations are `yield` and `tick`; the functions that
// take blocks are its members, written over the scheduler's intrinsics
// (eval/sched.ml; compiler.md, "Stage 11a").

// what `task_isolate` gives: the body's value, or the message of the
// panic that was made a value
type Isolated<T> =
  | Finished(value: T)
  | PanickedWith(msg: Str)

pub dep Async =
  // let every other task that can run, run first
  yield: fn()
  // return once every task that could run when it was called has run
  // until it waits: the batching point
  tick: fn()

  // runs `body` with a scope its tasks are spawned into, and returns
  // once they've all ended; `spawn` waits while `max` of them run
  pub fn scope<T>(max: Int = 64, body: fn(s: Scope) -> T) -> T uses Async =
    try scope_run(max, body)
  // waits until `cond` holds: only in an operation, whose instance it
  // lets go of meanwhile
  pub fn until(cond: fn() -> Bool) uses Async =
    if not cond() then task_until(cond)
  // `body`, or `Timeout` if it's still running after `d`
  pub fn timeout<T>(d: Duration, body: fn() -> T) -> T ! Timeout uses Async =
    match try task_timeout(d, body)
      Some(v) => v
      None => fail Timeout
  // whichever of `a` and `b` finishes first; the other is cancelled.
  // Neither can fail
  pub fn race<T>(a: concurrent fn() -> T, b: concurrent fn() -> T) -> T uses Async =
    task_race(a, b)
  // `body`, or `Panicked` if it panicked
  pub fn isolate<T>(body: fn() -> T) -> T ! Panicked(msg: Str) uses Async =
    match try task_isolate(body)
      Finished(v) => v
      PanickedWith(msg) => fail Panicked(msg)
  // `f` of each element, `max` at once, the results in order
  pub fn map<T, U>(xs: Array<T>, max: Int = 64, f: concurrent fn(x: T) -> U) -> Array<U> uses Async =
    try task_map(xs, max, f)
  // `f` of each element, `max` at once
  pub fn each<T>(xs: Array<T>, max: Int = 64, f: concurrent fn(x: T)) uses Async =
    try task_each(xs, max, f)
  // `a` and `b` at once
  pub fn both<A, B>(a: concurrent fn() -> A, b: concurrent fn() -> B) -> (A, B) uses Async =
    try task_both(a, b)
  // the runtime on one thread, in real time, with real I/O
  pub fn single() -> Async = single_runtime()
  let real: Async = single_runtime()

// One thread, in `single`'s order, in real time (eval/sched.ml): the
// scheduler's policy for its `with`'s body, and the one before once it
// ends. Natively, where nothing else runs, both operations return at
// once. `sim.scheduler(seed)` is the same over `runtime_sim` (std_lib.ml)
handler single_runtime() for Async =
  let was = runtime_single()
  finally(r) =>
    runtime_leave(was)
    try r
  yield() => async_yield()
  tick() => async_tick()

// what `Async.scope` gives its body: it's passed and called, never kept
// (foundations.md, decision 2, rule D)
pub type Scope = builtin
  // starts `body` as a task of this scope, waiting first while `max`
  // of its tasks run
  pub fn spawn(self, body: spawned fn()) uses Async = task_spawn(self, body)
  // the same, giving the task's handle, to join it or cancel it
  pub fn start<T>(self, body: spawned fn() -> T) -> Task<T> uses Async =
    task_start(self, body)
  // `spawn`, after cancelling the task this scope started under `key`,
  // if it's still running, and waiting for it to stop
  pub fn replace<K has hash>(self, key: K, body: spawned fn()) uses Async =
    task_replace(self, key, body)

// a task's handle (rule D, as `Scope`)
pub type Task<T> = builtin
  // waits for the task to end: what it gave, or `None` if it was
  // cancelled first
  pub fn join(self) -> Option<T> uses Async = task_join(self)
  // asks the task to stop, and returns at once: it stops at its next
  // dependency call, or now, if it's waiting
  pub fn cancel(self) uses Async = task_cancel(self)

// ---- trying again (handlers.md, "Functions that run a block") ----

// runs `body`, and again while it fails with one of `on`'s errors, up
// to `n` tries in all: any other error leaves at once, after the last
// try its error leaves, and `body` runs at least once
pub fn retry<T>(n: Int, on: Tags, body: fn() -> T) -> T =
  try match body()
    fail on if n > 1 => try retry(n - 1, on: on, body)
    v => v

// ---- what a test gets (deps.md, "Tests") ----
//
// Each test runs with a fresh instance of each of these handlers, unless
// its `uses` asks for the real dependency instead.

pub dep TestClock =
  // move the test clock on, by `d`
  advance: fn(d: Duration)

// a clock that stands still at `at` until it's moved on: by
// `TestClock.advance`, or by sleeping, which takes no time at all
pub handler test_clock(at: Time) for Clock, TestClock =
  var time = at
  var since = Instant.zero
  now() => time
  instant() => since
  sleep(d) =>
    time = time + d
    since = since + d
  advance(d) =>
    time = time + d
    since = since + d

pub dep TestRandom =
  // the seed the test's numbers come from, which `ren test --seed`
  // sets
  seed: fn() -> Int

// numbers that are the same on every run with the same seed
pub handler test_random(seed: Int) for Random, TestRandom =
  var state = seed
  int(below) =>
    // a spawned task draws from a stream of its own, from the seed and
    // its path, so what it draws doesn't depend on the order tasks ran in
    match task_random(seed, below)
      Some(n) => n
      None =>
        state = seeded_next(state)
        seeded_int(state, below)
  seed() => seed

pub dep TestConsole =
  // every line written to `Console` so far, the first first
  output: fn() -> Array<Str>
  // every line given to `Console.error` so far, the first first
  errors: fn() -> Array<Str>

// a console that keeps what's written to it
pub handler test_console() for Console, TestConsole =
  var lines: Array<Str> = []
  var errors: Array<Str> = []
  write(line) => &lines.push(line)
  error(line) => &errors.push(line)
  output() => lines
  errors() => errors

// files kept in memory, starting with `files`. A test gets an empty one,
// and reads back what it wrote through `Fs` itself.
pub handler mem_fs(files: Array<File>) for Fs =
  var kept: Map<Path, Bytes> = Map.of(files.map(fn(f) => (f.path, f.data)))
  read(p) => kept.get(p) orelse fail NoSuchFile(p)
  write(p, b) => &kept.set(p, b)
  exists(p) => kept.includes(p)

// a system whose program was given `args`
pub handler test_os(args: Array<Str>) for Os =
  args() => args

// a program that was run: its name, and what it was given
pub type Command = { cmd: Str, args: Array<Str> }

// what a test `Proc` says `command` exits with
pub type Exit = { command: Command, code: Int }

pub dep TestProc =
  // every program run so far, the first first
  ran: fn() -> Array<Command>

// programs that don't run, but are kept: each exits with the code its
// `Exit` in `exits` gives, or 0 if none does
pub handler test_proc(exits: Array<Exit>) for Proc, TestProc =
  var commands: Array<Command> = []
  run(cmd, args) =>
    let c = Command { cmd: cmd, args: args }
    &commands.push(c)
    var code = 0
    for e in exits
      if e.command == c then code = e.code
    code
  ran() => commands

// ---- the journal (handlers.md, "The journal") ----
//
// `ren run --record` puts a recorder over each built-in dependency `main`
// uses, and `ren replay` puts `replaying` in place of them all; a test
// installs one with `replay(file)`, and the console keeps its session
// with recorders too. What a journal holds, and how it's written, is the
// runtime's (journal.ml): a Ren program holds one only as its number.

// a journal the runtime has open
type Journal = opaque Int

// The recorder, over any built-in dependency: each operation gives back
// what a line the console kept was given, if it's one of those, or else
// calls the one under it, and writes down what it gave, with the task
// that called it; a call its task waits in is written in two lines. The
// runtime installs it over each one `main` uses.
handler recorder(j: Journal) over any =
  call =>
    let r = journal_kept(j, call.name, call.args) orelse journal_gave(j, call.name, call.args, attempt call.forward())
    try r

// In place of every built-in dependency: each operation gives back what
// the recording says it gave. When the `with` that installed it ends, a
// test's outputs are compared with the recording's.
handler replaying(j: Journal) for Clock, Random, Console, Fs, Os, Proc =
  finally(r) =>
    journal_outputs(j)
    try r
  now() => journal_answer(j, "Clock.now", ())
  instant() => journal_answer(j, "Clock.instant", ())
  sleep(d) => journal_answer(j, "Clock.sleep", d)
  int(below) => journal_answer(j, "Random.int", below)
  Console.write(line) => journal_answer(j, "Console.write", line)
  error(line) => journal_answer(j, "Console.error", line)
  read(p) =>
    let r: Result<Bytes, ! FsError> = journal_answer(j, "Fs.read", p)
    try r
  Fs.write(p, b) =>
    let r: Result<Unit, ! FsError> = journal_answer(j, "Fs.write", (p, b))
    try r
  exists(p) => journal_answer(j, "Fs.exists", p)
  args() => journal_answer(j, "Os.args", ())
  run(cmd, args) =>
    let r: Result<Int, ! ProcError> = journal_answer(j, "Proc.run", (cmd, args))
    try r

// A recorded run, `ren run --record tests/run.journal main.ren`, as each
// built-in dependency it holds calls for, for a test (testing.md, "The
// journal is a test"): what the program reads is answered from it, in
// order for each dependency, and what it writes is compared with it when
// the `with` ends, a difference failing the test with a diff. `file` is
// found from the folder of the file the test is in. Its type lists all
// six; the checker narrows it to those the journal's header names
// (infer_handlers.ml, `replayed`), so the others stay the test's.
pub test fn replay(file: Str) -> Clock & Console & Fs & Os & Proc & Random =
  replaying(journal_load(file))
|}

(* ---- built-in functions ---- *)

(* [Ty.Var n] is the scheme's [n]th type variable and [Some n] in a row its
   [n]th row variable, numbered by first appearance (ty.ml). *)
let scheme_of ?(reqs = []) ty : Ty.scheme =
  Ty.canonical { ty; names = []; reqs; row_reqs = []; modes = []; defaults = [] }

let open_row n : Ty.row = { labels = []; tail = Some n }
let bytes = Ty.Con (Path.prelude "Bytes", [])
let map k v = Ty.Con (Path.prelude "Map", [ k; v ])
let set t = Ty.Con (Path.prelude "Set", [ t ])
let journal = Ty.Con (Path.prelude "Journal", [])

(* Each built-in function's type scheme, by its id. Each parameter's mode
   ([inout] or not) is part of the type. A built-in type's method has its
   receiver, `self`, first, and the type's parameters are its scheme's
   first variables, as in any member's (iface.ml). *)
let scheme (x : Intrinsic.t) =
  let open Ty in
  (* most fail with nothing and use nothing: open rows, which any row
     fits *)
  let fn ?reqs params ret =
    scheme_of ?reqs (Fun (params, ret, open_row 0, open_row 1))
  in
  let inout ty = { mode = Inout; ty } in
  (* `split_at` on [self], giving the block's [r]: what the block fails
     with and uses, the call does *)
  let split_at self r =
    let body = Fun ([ inout self; inout self ], r, open_row 0, open_row 1) in
    scheme_of (Fun ([ inout self; read int; read body ], r, open_row 0, open_row 1))
  in
  (* a key, or a member of a set, is found by its hash, with the `==` it
     agrees with: what `hash` of [Var 0] is *)
  let hashed = [ (0, "hash") ] in
  let k = Var 0 and v = Var 1 in
  match x with
  (* fn<T>(T) -> Str, which the interpreter runs itself, since it shows a
     value through its type (eval.ml) *)
  | Show -> fn [ read (Var 0) ] str
  (* fn() -> Int, the real `Clock.now` and `Clock.instant` *)
  | Clock_now | Clock_instant -> fn [] int
  (* fn(Int) *)
  | Clock_sleep -> fn [ read int ] unit
  (* fn(Int) -> Int *)
  | Random_int -> fn [ read int ] int
  (* fn(Int) -> Int: the state after [state] of the test `Random` *)
  | Seeded_next -> fn [ read int ] int
  (* fn(Int, Int) -> Int: a number from 0 below [below], from that state *)
  | Seeded_int -> fn [ read int; read int ] int
  (* fn(Str) *)
  | Console_write -> fn [ read str ] unit
  (* fn(Str), the real `Console.error`: stderr *)
  | Console_error -> fn [ read str ] unit
  (* fn(Str) -> FsOutcome<Bytes>, the real `Fs.read` *)
  | Fs_read -> fn [ read str ] (Con (Path.prelude "FsOutcome", [ bytes ]))
  (* fn(Str, Bytes) -> FsOutcome<Unit>, the real `Fs.write` *)
  | Fs_write ->
      fn [ read str; read bytes ] (Con (Path.prelude "FsOutcome", [ unit ]))
  (* fn(Str) -> Bool *)
  | Fs_exists -> fn [ read str ] bool
  (* fn() -> Array<Str> *)
  | Os_args -> fn [] (array str)
  (* fn(Str, Array<Str>) -> ProcOutcome, the real `Proc.run` *)
  | Proc_run ->
      fn [ read str; read (array str) ] (Con (Path.prelude "ProcOutcome", []))
  (* The journal's (handlers.md, "The journal"; journal.ml): each is given
     the call it's for, `Fs.read`, its arguments, [A], one value, a
     tuple of several or `()` for none, and what it gives back, [R]: the
     operation's value, or a [Result] of it if it can fail. Each writes
     or reads them through their types, which it's given as descriptors,
     as `show` is. *)
  (* fn<A, R>(j: Journal, call: Str, args: A) -> Option<R>: what a line
     the console kept was given, if this call is one of its, which isn't
     asked again; recording, the call has begun, and is written once its
     task waits in it, or once it's given back *)
  | Journal_kept -> fn [ read journal; read str; read (Var 0) ] (option (Var 1))
  (* fn<A, R>(j: Journal, call: Str, args: A, result: R) -> R: writes the
     call down, with what it gave, and gives that back *)
  | Journal_gave ->
      fn [ read journal; read str; read (Var 0); read (Var 1) ] (Var 1)
  (* fn<A, R>(j: Journal, call: Str, args: A) -> R: what the recording
     says this call gave *)
  | Journal_answer -> fn [ read journal; read str; read (Var 0) ] (Var 1)
  (* fn(j: Journal): in a test, the outputs compared with the
     recording's, once the body of the `with` has run *)
  | Journal_outputs -> fn [ read journal ] unit
  (* fn(file: Str) -> Journal: the journal in [file], read for a test *)
  | Journal_load -> fn [ read str ] journal
  (* fn<T>(self: Array<T>) -> Int *)
  | Array_len -> fn [ read (array (Var 0)) ] int
  (* fn<T>(inout self: Array<T>, x: T) *)
  | Array_push -> fn [ { mode = Inout; ty = array (Var 0) }; read (Var 0) ] unit
  (* fn<T>(self: Array<T>) -> Array<T>, by `T`'s order, equal ones in the
     order they were *)
  | Array_sort ->
      fn ~reqs:[ (0, "ord") ] [ read (array (Var 0)) ] (array (Var 0))
  (* The prelude's own, which `map` is written with (prelude.ml's
     [caller], [Internal]). *)
  (* fn<T>(n: Int) -> Array<T>: an empty array with room for [n] *)
  | Array_reserve -> fn [ read int ] (array (Var 0))
  (* fn<T, U>(xs: Array<T>) -> MapInto<U>: whether `xs.map` can replace
     each element where it is, giving [xs] back as the new array: nothing
     else holds [xs], and a [U] is kept in an array as a [T] is (Lean's
     `Array.mapMUnsafe`, Init/Data/Array/Basic.lean:766) *)
  | Map_into ->
      fn [ read (array (Var 0)) ] (Con (Path.prelude "MapInto", [ Var 1 ]))
  (* fn<A, B>(x: A) -> B: [x], said to be a [B]. Only `map` calls it, on
     an element of an array [map_into] said keeps a [B] as it keeps an
     [A], and on that array: Lean's `unsafeCast` *)
  | Unsafe_cast -> fn [ read (Var 0) ] (Var 1)
  (* fn<T>(xs: Array<T>) -> Bool: whether `T` is `Float`, whose `sum`
     adds in lanes (foundations.md, decision 15) *)
  | Float_lanes -> fn [ read (array (Var 0)) ] bool
  (* fn<T>(xs: Array<T>) -> T: [xs], whose `T` [float_lanes] said is
     `Float`, added up in eight lanes, element i into lane i % 8, each
     from 0.0, and the lanes added pairwise: ((0 + 1) + (2 + 3)) + ((4 +
     5) + (6 + 7)). The same on every machine, and what a vector unit
     does (nan.ml says which NaN it carries) *)
  | Float_sum -> fn [ read (array (Var 0)) ] (Var 0)
  (* A `Map` and a `Set` keep insertion order (operators.md, "`Map` and
     `Set`"), and find a key by its `hash`. *)
  (* fn<K, V>() -> Map<K, V>, which `Map.empty` is *)
  | Map_empty -> fn [] (map k v)
  (* fn<K, V>(pairs: Array<(K, V)>) -> Map<K, V>: a key given twice has
     the last value, in the first one's place *)
  | Map_of -> fn ~reqs:hashed [ read (array (tuple [ k; v ])) ] (map k v)
  (* fn<K, V>(self: Map<K, V>, k: K) -> Option<V> *)
  | Map_get -> fn ~reqs:hashed [ read (map k v); read k ] (option v)
  (* fn<K, V>(inout self: Map<K, V>, k: K, v: V): a key already there
     keeps its place *)
  | Map_set -> fn ~reqs:hashed [ inout (map k v); read k; read v ] unit
  (* fn<K, V>(inout self: Map<K, V>, k: K), which may not be there *)
  | Map_remove -> fn ~reqs:hashed [ inout (map k v); read k ] unit
  (* fn<K, V>(self: Map<K, V>, k: K) -> Bool *)
  | Map_includes -> fn ~reqs:hashed [ read (map k v); read k ] bool
  (* fn<K, V>(self: Map<K, V>) -> Array<K>, and its values, in order *)
  | Map_keys -> fn [ read (map k v) ] (array k)
  | Map_values -> fn [ read (map k v) ] (array v)
  (* fn<K, V>(self: Map<K, V>) -> Int *)
  | Map_len -> fn [ read (map k v) ] int
  (* fn<T>() -> Set<T>, which `Set.empty` is *)
  | Set_empty -> fn [] (set k)
  (* fn<T>(xs: Array<T>) -> Set<T>, each once, in the first one's place *)
  | Set_of -> fn ~reqs:hashed [ read (array k) ] (set k)
  (* fn<T>(inout self: Set<T>, x: T), and taken out, which may not be
     there *)
  | Set_add | Set_remove -> fn ~reqs:hashed [ inout (set k); read k ] unit
  (* fn<T>(self: Set<T>, x: T) -> Bool *)
  | Set_includes -> fn ~reqs:hashed [ read (set k); read k ] bool
  (* fn<T>(self: Set<T>) -> Int *)
  | Set_len -> fn [ read (set k) ] int
  (* A `Str` is UTF-8, always, and `Bytes` are any bytes at all
     (builtins.ml, "strings and bytes"). *)
  (* fn(self: Str) -> Int, in bytes *)
  | Str_len -> fn [ read str ] int
  (* fn(self: Str, s: Str) -> Option<Int>: where [s] first starts *)
  | Str_index ->
      fn [ read str; read str ] (Con (Path.prelude "Option", [ int ]))
  (* fn(self: Str, sep: Str) -> Array<Str>: the parts between each [sep] *)
  | Str_split -> fn [ read str; read str ] (array str)
  (* fn(self: Str) -> Str, without the spaces, tabs and newlines at
     either end *)
  | Str_trim -> fn [ read str ] str
  (* fn(self: Str, prefix: Str) -> Bool *)
  | Str_starts_with -> fn [ read str; read str ] bool
  (* fn(self: Str, s: Str) -> Str: this, then [s] *)
  | Str_concat -> fn [ read str; read str ] str
  (* fn(self: Str) -> Bytes: its UTF-8 *)
  | Str_bytes -> fn [ read str ] bytes
  (* fn(b: Bytes) -> Str ! InvalidUtf8 *)
  | Str_from_utf8 ->
      scheme_of
        (Fun
           ( [ read bytes ],
             str,
             { labels = [ label "InvalidUtf8" ]; tail = None },
             open_row 0 ))
  (* fn(self: Bytes) -> Int *)
  | Bytes_len -> fn [ read bytes ] int
  (* fn(self: Bytes, i: Int) -> Int: byte [i], 0 to 255 *)
  | Bytes_at -> fn [ read bytes; read int ] int
  (* fn(xs: Array<Int>) -> Bytes, each 0 to 255 *)
  | Bytes_of -> fn [ read (array int) ] bytes
  (* fn(self) -> Self: a value equal to [self] that holds its own buffer,
     not a slice of another's (foundations.md, decision 17); [self] itself
     if it already does *)
  | Array_copy -> fn [ read (array (Var 0)) ] (array (Var 0))
  | Str_copy -> fn [ read str ] str
  | Bytes_copy -> fn [ read bytes ] bytes
  (* fn<R>(inout self, n: Int, body: fn(&Self, &Self) -> R) -> R: [body]
     given `self[0..n]` and `self[n..len]`, each a place of its own,
     after which [self] is the first followed by the second, if it
     returns or fails (compiler.md, "Blocks with `inout` parameters, and
     slices"). Whatever [body] fails with and uses, so does the call.
     Lowering writes it out (lower.ml, [split_at]) *)
  | Array_split_at -> split_at (array (Var 0)) (Var 1)
  | Str_split_at -> split_at str (Var 0)
  | Bytes_split_at -> split_at bytes (Var 0)
  (* fn(self: Int, n: Int) -> Int: wrapping arithmetic at 64 bits,
     instead of panicking (operators.md, "`Int` and `Float`") *)
  | Int_wrapping_add | Int_wrapping_sub | Int_wrapping_mul ->
      fn [ read int; read int ] int
  (* fn(self: Int) -> Int *)
  | Int_wrapping_neg -> fn [ read int ] int
  (* fn(self: Int, n: Int) -> Int: the bits of the two's complement of
     each, combined, for hashes and checksums (operators.md, "Sized
     integers") *)
  | Int_xor | Int_bit_and | Int_bit_or -> fn [ read int; read int ] int
  (* fn(self: Int, k: Int) -> Int: shifted left, losing the bits shifted
     out, or right, keeping the sign; `k` outside 0 to 63 panics
     (operators.md, "Bits") *)
  | Int_shl | Int_shr -> fn [ read int; read int ] int
  (* fn(self: Int, b: Int) -> Int: the operators, as methods, `n.add(2)`
     is `n + 2` (operators.md, "Operators are methods"); and `-n` *)
  | Int_add | Int_sub | Int_mul | Int_div | Int_rem ->
      fn [ read int; read int ] int
  | Int_neg -> fn [ read int ] int
  (* the same, for a `Float` *)
  | Float_add | Float_sub | Float_mul | Float_div | Float_rem ->
      fn [ read float; read float ] float
  | Float_neg -> fn [ read float ] float
  (* fn(n: Int) -> Float: numbers never convert by themselves *)
  | Float_of -> fn [ read int ] float
  (* fn(self: Float) -> Int: the nearest, half away from zero; and
     toward zero *)
  | Float_round | Float_truncate -> fn [ read float ] int
  (* fn(self: Float) -> Float *)
  | Float_sqrt -> fn [ read float ] float
  (* fn(self: Str) -> Str, with `A` to `Z` made `a` to `z` *)
  | Str_lower -> fn [ read str ] str
  (* fn<T>(what: Str) -> T: a panic, saying [what] isn't built yet; what
     stage 11a's members of `Async`, `Scope` and `Task` call until the
     step that builds each (compiler.md, "Stage 11a", "The surface") *)
  | Unbuilt -> fn [ read str ] (Var 0)
  (* the scheduler's (sched.ml), what `Async.scope`, `Scope` and `Task`'s
     members are written over (compiler.md, "Stage 11a", "Structured
     tasks"). fn<T>(max: Int, body: fn(Scope) -> T) -> T: [body], with a
     new scope, once its tasks have all ended; what [body] fails with and
     uses, the call does *)
  | Scope_run ->
      let scope = Con (Path.prelude "Scope", []) in
      fn
        [ read int; read (Fun ([ read scope ], Var 0, open_row 0, open_row 1)) ]
        (Var 0)
  (* fn(s: Scope, body: fn()): starts [body] as a task of [s] *)
  | Task_spawn ->
      let scope = Con (Path.prelude "Scope", []) in
      fn [ read scope; read (Fun ([], unit, open_row 2, open_row 3)) ] unit
  (* fn<T>(s: Scope, body: fn() -> T) -> Task<T>: the same, giving its
     handle *)
  | Task_start ->
      let scope = Con (Path.prelude "Scope", []) in
      fn
        [ read scope; read (Fun ([], Var 0, open_row 2, open_row 3)) ]
        (Con (Path.prelude "Task", [ Var 0 ]))
  (* fn<K has hash>(s: Scope, key: K, body: fn()): [body] as a task of
     [s] under [key], once the one under it has been cancelled and has
     ended *)
  | Task_replace ->
      let scope = Con (Path.prelude "Scope", []) in
      fn ~reqs:[ (0, "hash") ]
        [ read scope; read (Var 0); read (Fun ([], unit, open_row 2, open_row 3)) ]
        unit
  (* fn<T>(t: Task<T>) -> Option<T>: what it gave, once it has ended *)
  | Task_join ->
      fn [ read (Con (Path.prelude "Task", [ Var 0 ])) ] (option (Var 0))
  (* fn<T>(t: Task<T>): asks it to stop *)
  | Task_cancel -> fn [ read (Con (Path.prelude "Task", [ Var 0 ])) ] unit
  (* fn(cond: fn() -> Bool): waits until the instance whose operation
     it's in is released with [cond] holding; the caller has checked it
     doesn't hold now (compiler.md, "The rest of `Async`") *)
  | Task_until -> fn [ read (Fun ([], bool, open_row 2, open_row 3)) ] unit
  (* fn<T>(ms: Int, body: fn() -> T) -> Option<T>: [body], under a
     deadline [ms] from now or the one it's under, if that's sooner;
     [None] if the deadline cancelled it. What [body] fails with and
     uses, the call does *)
  | Task_timeout ->
      fn [ read int; read (Fun ([], Var 0, open_row 0, open_row 1)) ] (option (Var 0))
  (* fn<T>(body: fn() -> T) -> Isolated<T>: [body], or the message of a
     panic in it that's made a value *)
  | Task_isolate ->
      fn
        [ read (Fun ([], Var 0, open_row 0, open_row 1)) ]
        (Con (Path.prelude "Isolated", [ Var 0 ]))
  (* fn<T, U>(xs: Array<T>, max: Int, f: fn(T) -> U) -> Array<U>: [f] of
     each element as a task, [max] at once, the results in order; and
     the same, giving nothing. The first failure is the call's *)
  | Task_map ->
      fn
        [ read (array (Var 0)); read int; read (Fun ([ read (Var 0) ], Var 1, open_row 0, open_row 1)) ]
        (array (Var 1))
  | Task_each ->
      fn
        [ read (array (Var 0)); read int; read (Fun ([ read (Var 0) ], unit, open_row 0, open_row 1)) ]
        unit
  (* fn<A, B>(a: fn() -> A, b: fn() -> B) -> (A, B): both as tasks *)
  | Task_both ->
      fn
        [
          read (Fun ([], Var 0, open_row 0, open_row 1));
          read (Fun ([], Var 1, open_row 0, open_row 1));
        ]
        (tuple [ Var 0; Var 1 ])
  (* fn<T>(a: fn() -> T, b: fn() -> T) -> T: both as tasks, the first to
     return the result, the other cancelled; neither can fail *)
  | Task_race ->
      fn
        [
          read (Fun ([], Var 0, open_row 2, open_row 3));
          read (Fun ([], Var 0, open_row 2, open_row 3));
        ]
        (Var 0)
  (* fn(): `single`'s `yield` and `tick` (sched.ml) *)
  | Async_yield | Async_tick -> fn [] unit
  (* The runtime's policy, which its handler sets for its `with`'s body
     (compiler.md, "Runtimes"). fn() -> Int: `single`'s, from now on,
     giving what [runtime_leave] puts back; fn(seed: Int) -> Int: `sim`'s,
     its tape from [seed], in virtual time from 0 *)
  | Runtime_single -> fn [] int
  | Runtime_sim -> fn [ read int ] int
  (* fn(was: Int): the policy before, which [was] says *)
  | Runtime_leave -> fn [ read int ] unit
  (* `sim.clock()`'s (std_lib.ml). fn() -> Int: the scheduler's time, in
     milliseconds, virtual under `sim` *)
  | Sim_time -> fn [] int
  (* fn(ms: Int): waits until the scheduler's time has moved on by
     [ms]; and moves it on by [ms] at once, waking what it passes *)
  | Sim_sleep | Sim_advance -> fn [ read int ] unit
  (* fn(seed: Int, below: Int) -> Option<Int>: in a spawned task, a
     number from 0 below [below] from the task's own stream of the test
     `Random` seeded with [seed]; [None] in a root task, which draws from
     the instance's own (compiler.md, "The tape") *)
  | Task_random -> fn [ read int; read int ] (option int)

(* The operation of a built-in dependency that [x] is how the real one
   does, if it reaches the world: `fs_read` is `Fs.read`'s. Each is called
   only by its dependency's [real] (Core Lint checks it), so every call
   the program makes to the world is a call of an operation, which the
   journal records (handlers.md, "Recording and replaying"). This is the
   one place that says what reaches the world, and it names every
   intrinsic, so a new one has to be put on one side or the other. *)
let reaches (x : Intrinsic.t) =
  match x with
  | Clock_now -> Some ("Clock", "now")
  | Clock_instant -> Some ("Clock", "instant")
  | Clock_sleep -> Some ("Clock", "sleep")
  | Random_int -> Some ("Random", "int")
  | Console_write -> Some ("Console", "write")
  | Console_error -> Some ("Console", "error")
  | Fs_read -> Some ("Fs", "read")
  | Fs_write -> Some ("Fs", "write")
  | Fs_exists -> Some ("Fs", "exists")
  | Os_args -> Some ("Os", "args")
  | Proc_run -> Some ("Proc", "run")
  | Seeded_next | Seeded_int | Journal_kept | Journal_gave | Journal_answer
  | Journal_outputs | Journal_load | Map_empty | Set_empty | Array_sort | Map_of
  | Array_reserve | Map_into | Unsafe_cast | Float_lanes | Float_sum | Unbuilt
  | Scope_run | Task_spawn | Task_start | Task_replace | Task_join | Task_cancel
  | Task_until | Task_timeout | Task_isolate | Task_map | Task_each | Task_both
  | Task_race | Async_yield | Async_tick | Runtime_single | Runtime_sim
  | Runtime_leave | Sim_time | Sim_sleep | Sim_advance | Task_random
  | Map_get | Map_set | Map_remove | Map_includes | Map_keys | Map_values
  | Map_len | Set_of | Set_add | Set_remove | Set_includes | Set_len | Show
  | Array_len | Array_push | Str_len | Str_index | Str_split
  | Str_trim | Str_starts_with | Str_concat | Str_bytes | Str_from_utf8
  | Bytes_len | Bytes_at | Bytes_of | Array_copy | Str_copy | Bytes_copy
  | Array_split_at | Str_split_at | Bytes_split_at | Int_wrapping_add | Int_wrapping_sub | Int_wrapping_mul
  | Int_wrapping_neg | Int_xor | Int_bit_and | Int_bit_or | Int_shl | Int_shr | Int_add | Int_sub | Int_mul | Int_div | Int_rem | Int_neg
  | Float_add | Float_sub | Float_mul | Float_div | Float_rem | Float_neg
  | Float_of | Float_round | Float_truncate | Float_sqrt | Str_lower ->
      None

(* Who can call it. Any program can, unless only the prelude's own
   source can: because it reaches the world, which a program does only
   through a dependency, in the real implementation the runtime installs
   ([World], which [reaches] says); or it's how one of the test
   implementations works ([Test]); or it's the journal's, which the
   runtime puts over the world ([Journal]); or because it's what one of
   the source's values is made with, which a program uses instead:
   `map_empty()` is `Map.empty` ([Value]); or it's how the prelude's own
   `map` works, and unsafe anywhere else ([Internal]). *)
type caller = Any | World | Test | Journal | Value | Internal

let caller (x : Intrinsic.t) =
  match (reaches x, x) with
  | Some _, _ -> World
  | None, (Seeded_next | Seeded_int | Task_random) -> Test
  | ( None,
      ( Journal_kept | Journal_gave | Journal_answer | Journal_outputs
      | Journal_load ) ) ->
      Journal
  | None, (Map_empty | Set_empty) -> Value
  | ( None,
      ( Array_reserve | Map_into | Unsafe_cast | Float_lanes | Float_sum | Unbuilt
      | Scope_run | Task_spawn | Task_start | Task_replace | Task_join
      | Task_cancel | Task_until | Task_timeout | Task_isolate | Task_map
      | Task_each | Task_both | Task_race | Async_yield | Async_tick
      | Runtime_single | Runtime_sim | Runtime_leave | Sim_time | Sim_sleep
      | Sim_advance ) ) ->
      Internal
  | None, _ -> Any

let runtime x = caller x <> Any

(* The built-in functions that aren't a type's members, in the order the
   prelude's interface lists them. *)
let fns : Intrinsic.t list =
  [
    Show;
    Clock_now;
    Clock_instant;
    Clock_sleep;
    Random_int;
    Seeded_next;
    Seeded_int;
    Console_write;
    Console_error;
    Fs_read;
    Fs_write;
    Fs_exists;
    Os_args;
    Proc_run;
    Journal_kept;
    Journal_gave;
    Journal_answer;
    Journal_outputs;
    Journal_load;
    Map_empty;
    Set_empty;
    Array_reserve;
    Map_into;
    Unsafe_cast;
    Float_lanes;
    Float_sum;
    Unbuilt;
    Scope_run;
    Task_spawn;
    Task_start;
    Task_replace;
    Task_join;
    Task_cancel;
    Task_until;
    Task_timeout;
    Task_isolate;
    Task_map;
    Task_each;
    Task_both;
    Task_race;
    Async_yield;
    Async_tick;
    Runtime_single;
    Runtime_sim;
    Runtime_leave;
    Sim_time;
    Sim_sleep;
    Sim_advance;
    Task_random;
  ]

(* ---- built-in types ----

   A built-in type's methods are built in too, and listed with it: each is
   called with a dot, its receiver its first parameter, `self`. *)

type builtin_type = {
  name : string;
  arity : int;  (** type arguments *)
  methods : Intrinsic.t list;
  functions : Intrinsic.t list;  (** its associated functions, without `self` *)
}

let types =
  let t ?(methods = []) ?(functions = []) ?(arity = 0) name =
    { name; arity; methods; functions }
  in
  (* `Array` before `Str`, whose `len` an old-style `len(xs)` means
     less often (resolve.ml) *)
  [
    t "Int"
      ~methods:
        [
          Int_add;
          Int_sub;
          Int_mul;
          Int_div;
          Int_rem;
          Int_neg;
          Int_wrapping_add;
          Int_wrapping_sub;
          Int_wrapping_mul;
          Int_wrapping_neg;
          Int_xor;
          Int_bit_and;
          Int_bit_or;
          Int_shl;
          Int_shr;
        ];
    t "Float"
      ~methods:
        [
          Float_add;
          Float_sub;
          Float_mul;
          Float_div;
          Float_rem;
          Float_neg;
          Float_round;
          Float_truncate;
          Float_sqrt;
        ]
      ~functions:[ Float_of ];
    t "Bool";
    t "Unit";
  ]
  (* the sized storage types (sized.ml): no members, since arithmetic is
     done in what they're read as *)
  @ List.map (fun k -> t (Sized.name k)) Sized.all
  @ [
    t "Array" ~arity:1
      ~methods:[ Array_len; Array_push; Array_sort; Array_copy; Array_split_at ];
    t "Str"
      ~methods:
        [
          Str_len;
          Str_index;
          Str_split;
          Str_trim;
          Str_starts_with;
          Str_concat;
          Str_bytes;
          Str_lower;
          Str_copy;
          Str_split_at;
        ]
      ~functions:[ Str_from_utf8 ];
    t "Bytes"
      ~methods:[ Bytes_len; Bytes_at; Bytes_copy; Bytes_split_at ]
      ~functions:[ Bytes_of ];
    (* a set of error tags, given by name at a call, `on: Flaky | Broken`,
       which the function it's given to matches with `fail on`: never a
       value, since each function that takes one is made for each set it's
       given (compiler.md, "`over any` and `retry`") *)
    t "Tags";
    (* a task's scope, and a task's handle (stage 11a): their members are
       the source's *)
    t "Scope";
    t "Task" ~arity:1;
    t "Map" ~arity:2
      ~methods:
        [
          Map_get;
          Map_set;
          Map_remove;
          Map_includes;
          Map_keys;
          Map_values;
          Map_len;
        ]
      ~functions:[ Map_of ];
    t "Set" ~arity:1
      ~methods:[ Set_add; Set_remove; Set_includes; Set_len ]
      ~functions:[ Set_of ];
  ]
  (* a tuple's type, of each size up to eight, named by its shape, which no
     program can write (Ty.tuple): a program writes two and three, and an
     operation's arguments, `call.args`, are any of them *)
  @ List.init 8 (fun i ->
        t (match Ty.tuple_path (i + 1) with p -> p.name) ~arity:(i + 1))

(* ---- built-in dependencies ----

   The dependencies the runtime installs around `main`, if it uses them:
   each is declared in [source], with its real implementation, `real`
   (deps.md, "`main`"). *)
let world_deps = [ "Clock"; "Random"; "Console"; "Fs"; "Os"; "Proc" ]

(* `Async`, the runtime itself, isn't the world: the journal records
   none of its calls, but the order they made, in its task column, its
   polls and its cancels (journal.ml) *)
let runtime_deps = world_deps @ [ "Async" ]

(* The dependencies a `uses` can name that aren't declared anywhere yet:
   their stages give them operations. *)
let dependencies = [ "Net"; "Alloc"; "Unsafe" ]

(* Every built-in function, by its path. The map is made once, when the
   compiler starts, and never changes. *)
let by_path =
  let all = fns @ List.concat_map (fun t -> t.methods @ t.functions) types in
  List.fold_left
    (fun m x -> Path.Map.add (Intrinsic.path x) x m)
    Path.Map.empty all

let find p = Path.Map.find_opt p by_path

(* The intrinsic half of the prelude's interface, as the prelude's own
   source sees it, with what reaches the world and what its values are
   made with; [public] is what every other module sees, without them. *)
let intrinsics : Iface.t =
  {
    home = Path.prelude_home;
    types =
      List.map
        (fun (t : builtin_type) : Iface.type_decl ->
          {
            path = Path.prelude t.name;
            params = List.init t.arity (fun i -> "T" ^ string_of_int i);
            body = Builtin;
            members =
              Path.Map.of_list
                (List.mapi
                   (fun onum (okind, x) ->
                     ( Intrinsic.path x,
                       {
                         Iface.oname = Intrinsic.member_name x;
                         onum;
                         opub = true;
                         okind;
                         oscheme = scheme x;
                       } ))
                   (List.map (fun x -> (Iface.Method, x)) t.methods
                   @ List.map (fun x -> (Iface.Function, x)) t.functions));
            numeric = None;
            opaque = false;
            loc = None;
          })
        types;
    values =
      List.map
        (fun x ->
          { Iface.vname = Intrinsic.name x; scheme = scheme x; vparams = [] })
        fns;
    tests = [];
  }

let public =
  {
    intrinsics with
    values =
      List.filter
        (fun (v : Iface.value) ->
          match find (Path.prelude v.vname) with
          | Some x -> caller x = Any
          | None -> true)
        intrinsics.values;
  }

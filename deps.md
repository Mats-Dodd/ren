# Dependencies

How Ren code says what it touches, how an implementation is swapped in, and
how tests get fakes without setup. This is stage 7 of the
[roadmap](README.md#roadmap). The short version is in the README's
[`uses`](README.md#5-uses-dependencies-are-types) and
[`with`](README.md#6-with-installing-implementations) sections.

The design borrows from Effect's requirements channel and layers: a
service's interface carries no requirements, the thing that builds it does,
and tests get test services by default. Ren does it in the language
instead of a library, so calls are direct and nothing is looked up by name
while the program runs.

## What dependencies have to do

1. **The signature says what code touches.** `uses` is complete. A private
   function's is inferred.
2. **Nothing reaches the world another way.** There's no global state and
   no ambient I/O. Even `print` goes through a dependency, `Console`.
3. **A missing implementation is a compile error,** naming the dependency
   and the call that needs it. Never a runtime "not installed".
4. **Swapping is one line,** `with frozen in`, and a test needs none: it
   gets test implementations by default.
5. **Interfaces are exact.** An implementation can't fail in ways its
   interface doesn't declare, and what it needs to run is required where
   it's installed, not hidden behind the interface.
6. **A dependency call costs a function call,** plus finding the
   implementation in the evidence vector, which the compiler can make a
   fixed index when it knows the row.

Each rule below follows from these.

## Declaring one

```ren
pub dep Clock =
  now:     fn() -> Time
  instant: fn() -> Instant
  sleep:   fn(d: Duration)

  pub fn frozen(at: Time) -> Clock = frozen_clock(at)

handler frozen_clock(at: Time) for Clock =
  now() => at
  instant() => Instant.zero
  sleep(_) => ()
```

- A `dep` lists its **operations** first, then its members, as a sum type
  lists its variants first.
- `Clock.now()` calls the **installed** implementation. `Clock.frozen(t)` is
  an ordinary member. An operation and a member with the same name is an
  error, so `Clock.x` means exactly one thing.
- An operation can fail: `save: fn(u: User) ! Conflict`. Its errors are part
  of the interface, and a call marks them as usual: `try Users.save(u)`.

## Calling one

Calling an operation adds the dependency to the function's `uses`:

```ren
pub fn credit(inout self, m: Money, what: Movement) ! Frozen(account: AccountId) uses Clock =
  if self.frozen then fail Frozen(self.id)
  self.balance = self.balance + m
  &self.statement.push(Entry { at: Clock.now(), what })
```

A dependency call takes no marker. The capitalised `Clock.` already shows
it, and a call to a function that uses `Clock` indirectly is covered by that
function's signature, as `&` marks only the thing changed. It never takes
`&` either: a handler's state isn't a value the caller holds.

## Generic dependencies

A dependency can take type parameters, as a type does, and a handler
of one takes them too, with what each needs written as a function's
are:

```ren
dep Log<T> =
  add: fn(x: T)
  all: fn() -> Array<T>

handler log<T>() for Log<T> =
  var xs: Array<T> = []
  add(x) => &xs.push(x)
  all() => xs

handler seen<T has eq>() for Seen<T> = ...
```

- **It's found by its full type.** `Log<Int>` and `Log<Str>` are two
  dependencies, which a `with` installs side by side, and a function
  says which it uses: `uses Log<Int>`, or `uses Log<T>` in one generic
  in `T`.
- **A call is written without the type arguments,** `Log.add(x)`: what
  it's given, or what its result is used as, says which instance it
  calls, as a generic function's call says its type arguments. Where
  nothing does, `let n = Log.all().len()` in a function that uses both,
  it's an error that says to write the type.
- **A `with` installs the instance its item's type says.** `let ints:
  Log<Int> = log()`, then `with ints in`. An item at no particular type,
  `with log() in`, is at the type of the body's one use of `Log`.
- **A handler's type parameters are its dependencies'.** Each is a type
  argument of what it's `for` or `over`, since nothing else could say
  what it is where the handler is installed.
- **An alias is a dependency of its own.** `dep Jobs = Chan<Job>`
  declares `Jobs`, with `Chan<Job>`'s operations, called as `Jobs.send(j)`.
  `uses Jobs` doesn't give `Chan<Job>`, so `Jobs` and `Done`, both
  `Chan<Job>`, are two dependencies, installed side by side with `as`:

```ren
with queue() as Jobs, queue() as Done in
  work()
```

  A description written as an alias's, `let q: Jobs = queue()`, is
  installed as it, `with q in`. An alias of a dependency that isn't
  generic, `dep Replica = Db`, is how two of one are installed at once.

A debug build finds a generic dependency's implementation by its type
arguments' descriptors, those a generic function is given; a release
build specializes the function, and the key is a constant again
(compiler.md, "Generic dependencies").

## Implementations

An implementation is a value of the dependency's type, made by a
`handler`. One without state only gives its operations, like
`frozen_clock` above; one with state keeps it in `var`s, and can
implement several dependencies that share it:

```ren
handler counting_rates(rate: Decimal) for Rates, RateCalls =
  var calls = 0
  usd_to(_) =>
    calls += 1
    rate
  count() => calls
```

- **Calling `counting_rates(r)` describes a handler; `with` makes a fresh
  instance.** Two `with`s never share state.
- **What an implementation needs is part of its type,** and is required at
  the `with` that installs it. A `Clock` whose `now` calls `Os` makes
  `with` that clock need `Os`. The code inside sees only `Clock`.
- **Its own dependencies are fixed when it's installed,** to whatever is
  installed further out.
- **An operation may fail with fewer errors than the interface declares,
  never more:**

```
error: this implementation can fail with `Timeout`, and `Rates.usd_to` can't
   ┌─ fx.ren:12:16
   │
12 │   usd_to(c) => try Http.get_rate(c)
   │                ^^^^^^^^^^^^^^^^^^^^ fails with `Timeout`
   │
   = note: `Rates.usd_to` can fail only with `RateUnavailable`
   = help: map it: `match Http.get_rate(c)` with the arm `fail Timeout => fail RateUnavailable`
```

  The help says `try match` instead when the call fails with more than the
  tag it maps, which the `try` passes on.

- **A parameter of a dependency type is transparent.** If it's only
  installed, what it needs flows to the caller. One that's
  stored names its row, `Clock uses ..d`. A block's type never names one:
  a block is only called or passed on, so `fn(Int) uses ..d` is an error,
  "a block's errors and dependencies aren't named", whose help leaves the
  row out.
- `uses` after a dependency's name is what an implementation needs:
  `c: Clock uses Os`. After `->` a `uses` is the function's own, so a
  result writes it in parentheses: `-> (Clock uses Os)`.
- In a type argument, a comma after a `uses` list ends the argument, so
  `Pair<Clock uses Os, Int>` has two; a named row can still follow,
  `Box<Clock uses Os, ..d>`, and several dependencies are written in
  parentheses, `Box<(Clock uses Os, Console)>`.
- **Only a signature names a row.** Every `..d` in one signature is the
  same row, and the body can write it again, in a `let`'s type or a
  lambda's parameter. A function that declares its `uses` declares the
  rows it adds to them too: `fn install(c: Clock uses ..d) uses ..d`. A
  type's declaration can't name one yet, and no type holds a block: a
  record field, a constructor's payload, a type argument or a result
  written `fn(...)` is an error, whose help is to keep data, an enum to
  `match` on, or make the behaviour a dependency.
- **A handler's parameters are data.** A handler's description is a
  value, which can outlive the call that made it, so a parameter whose
  type has a block in it, `handler h(f: fn() -> Int) for N`, is an error,
  "a handler's parameters are data", with the help `pass the data, or
  make the behaviour a dependency`. A dependency's operations keep their
  `fn` types: `get: fn() -> Int` is a signature, not a stored block.
- **A handler can go in front of another implementation,** declared
  `over` it: `handler cached(ttl: Duration) over Prices uses Clock`. Its
  arms reach the one under it with `next.price(item)`, or `next(A).get()`
  when it goes over several that share an operation's name, and the
  operations it leaves out go to that one. A `with` installs it over
  another, `with cached(ttl) over catalogue() in`, or over the one
  installed outside the `with`, `over Prices`. Its type says so, `over
  Prices uses Clock`.
- **A handler can run code when its `with` ends,** in `finally(r) =>
  ...`, a statement among its state that covers what comes after it:
  it's given the result of the body, `Ok(v)` or `Err(_)`, and what it
  gives back, or fails with, is the `with`'s. A handler can have
  several, and an operation's arm can have one, covering the rest of the
  arm (handlers.md, "When a `with` ends").
- **A handler's state can fail,** `let tx = try next.begin()`, and so can
  its `finally`: the `with` that installs it fails with that, as it would
  for a `try`, and the body doesn't run. A public handler says so, `pub
  handler transaction() over Sql ! DbDown`, and so does a written type,
  `s: Sql ! DbDown`; a type without `!` can't fail to start. See
  [handlers.md](handlers.md) and [examples/ledger](examples/ledger).
- **An arm can name its dependency,** `Console.write(line) => ...`, and
  has to when a handler implements two that both have an operation of
  that name: a bare `write(line) =>` there says which to choose.

### Descriptions, the only stored code

A handler's description is the code Ren keeps (foundations.md, decision
3): records, arrays, maps and generic types hold them, and a block never.

```ren
dep Shape =
  area: fn() -> Float

handler circle(r: Float) for Shape =
  area() => 3.0 * r * r

fn total(shapes: Array<Shape>) -> Float =
  var t = 0.0
  for s in shapes
    t = t + s.area()
  t
```

- **A stored description's `uses` is the most it may need.** One whose
  handler needs less fits: `health()`, which needs nothing, goes in a
  `Router<(Api uses Cache, Db)>`, and whoever installs or calls one from
  there provides the whole row the slot says. One that needs more than
  its slot is an error that names what's beyond it, with the slot
  written with that added:

```
error: expected `Api uses Db`, found `Api uses Clock, Db`
   ┌─ main.ren:11:35
11 │   let rs: Array<(Api uses Db)> = [timed()]
   │                                   ^^^^^^^
   = a stored description's `uses` is the most it may need, and this one needs `Clock` too
   help: add it where the type is written: `Array<(Api uses Clock, Db)>`
```

  Only `uses` is a bound: what a description can fail to start with,
  its `!`, is exact.
- **An operation is called on a description as a method,** `s.area()`,
  which means `with s in Shape.area()`, the arguments evaluated first,
  outside: the call needs what `s`'s type says it needs, and fails with
  what `Shape.area` declares. For a stateless handler, with no `var`,
  `finally` or `next`, it makes no instance: it's a call of the arm with
  what the description holds. A handler with state, called as a method,
  starts fresh at each call, its `finally` run when the call ends. One
  whose type can fail to start (`!`), or that goes `over` another, isn't
  called this way: each is an error whose help installs it, `with s in
  Store.get()`. `s.area`, not called, is an error, "an operation is
  called, not read".
- **An inline handler,** `handler fn(req) => respond(req, body)`, is a
  handler for a dependency of one operation, written where a description
  of it is wanted: a `let`'s type, a parameter, a field, an element, a
  result, or a generic slot whose type argument is fixed. Its parameters
  are the operation's, written as a block's are. What it reads from where
  it's written it copies when it's made, so a `var` changed later isn't
  seen, and what it captures is data: a block is an error, and so is
  `next`, since it goes over nothing. What it uses is found where it's
  installed or called, as any handler's: `fn stamper() -> (Stamp uses
  Clock) = handler fn() => Clock.now()` uses nothing itself. One for a
  dependency of several operations, or where which dependency isn't
  known, is an error whose help is to declare a handler, or write the
  type it's kept as.
- **A chain isn't a value.** `cached() over mem()` is written only as a
  `with`'s item; anywhere else it's an error whose help keeps the parts,
  `with cached() over mem() in ...`.

## `with`

```ren
with Clock.frozen(t), counting_rates(Decimal.one) in
  body
```

- **A `with` is a set** ([handlers.md](handlers.md#a-with-is-a-set)).
  Each dependency is installed once: installing one twice, a handler of
  several included, is an error. An item's needs are met by the other
  items first, then by what's installed outside, and the compiler finds
  the order, so the order they're written in never matters; items that
  don't need each other go in the order of their dependencies' names.
  Each item's value is made outside the `with`, in the order written. A
  `with` nested inside another can install a dependency again, and the
  inner one is what its body sees. A line that ends in `,` goes on with
  the list on the next, indented further. That holds for any line outside brackets that
  ends in `,`, so a signature's `uses` list wraps the same way:
  `uses Clock,` then `    Console =` on the next line.
- `with` removes what it installs from the body's `uses`, and adds what its
  items need.
- An item is an implementation, or a chain of them joined by `over`. A
  function that runs a block, like `retry`, isn't one: it's called with
  the block, `try retry(3) fn() => try fetch()`, and written in a `with`
  it's an error whose help writes that call:

```
error: `with` installs only handlers
  ┌─ main.ren:8:10
8 │     with retry(3) in
  │          ^^^^^^^^ takes a block
  = `retry` is a function that runs a block, so it's called with the body as one
  help: call it: `try retry(3) fn() => ...`
```

  The `try` is there only when the function can fail.

## Built in

| Dependency | Operations | Real | Test default | Test controls |
|---|---|---|---|---|
| `Clock` | `now`, `instant`, `sleep` | the system clock | `test_clock(Time.epoch)`: stopped until moved | `TestClock.advance(d)` |
| `Random` | `int(below)` | the OS | seeded from the test's name | `TestRandom.seed()` |
| `Console` | `write(line: Str)`, `error(line: Str)` | stdout, and stderr for `error` | captured | `TestConsole.output() -> Array<Str>`, `TestConsole.errors() -> Array<Str>` |
| `Fs` | `read(p) -> Bytes ! FsError`, `write(p, b) ! FsError`, `exists(p)` | files, through `Unix` | `mem_fs([])`: no files | none: read back through `Fs` |
| `Os` | `args() -> Array<Str>` | what follows `--` in `ren run file.ren -- args` | `test_os([])`: no args | none |
| `Proc` | `run(cmd, args) -> Int ! ProcError` | a process, with this one's stdin, stdout and stderr | `test_proc([])`: runs nothing, exits with 0 | `TestProc.ran() -> Array<Command>` |

- `print(x)` is an ordinary prelude function: `Console.write(show(x))`.
  `show` shows a value through its type, as it's written: a record after
  its type's name, `Entry { at: Time(0), ... }`, and an opaque
  value as its type's name around what it is, `Money(-100)`, or, for an
  opaque record, its fields, `Account(id: AccountId(1), ...)`, unless the
  type has a `show(self) -> Str` method of its own, which is used
  instead: `Path`'s, so `print(p)` prints `src/main.ren`. A string on its
  own is itself. A failed `assert` and an error nothing handles show
  their values the same way.
- `Fs.read_str(p)` is a member of `Fs`, `read` then `Str.from_utf8`.
  `mem_fs(files: Array<File>)` keeps files in memory, each a `File {
  path, data }`, so a test that needs some installs one with `with`.
- `FsError` is `NoSuchFile(path) | NotAllowed(path) | IsAFolder(path) |
  FsFailed(path, reason)`, the last for anything else the system says,
  such as a full disk. The real `Fs` fails with them rather than
  panicking: a file that can't be read is something to handle, not a bug.
  `mem_fs` fails only with `NoSuchFile`, and its `write` never does.
- `Proc.run` gives back the program's exit code. `ProcError` is
  `NoSuchProgram(name) | CantRun(name, reason) | Killed(name)`: it isn't
  there, the system wouldn't start it, or a signal stopped it before it
  exited. What it prints isn't captured.
  `test_proc(exits: Array<Exit>)` keeps each `Command { cmd, args }`, and
  says it exited with the code of its `Exit { command, code }`, or 0.
- `Time`, `Instant` and `Duration` are opaque, with operators
  ([operators.md](operators.md)). A `Duration` is made with `ms`,
  `seconds` or `minutes`, and read back with `in_ms`; it's `with
  numeric`, so two add up, `d * 3` scales one, and they're ordered. A
  `Time` or an `Instant` moves on by one, `t + d`, and two give the
  `Duration` between them, `t - u`; they're ordered by when they are.
- For now the real `instant` reads the same wall clock as `now`, which the
  system can set back (NTP, a manual change). A monotonic source needs a
  primitive OCaml's standard library doesn't have; it comes with the
  runtime's own system calls (stage 13).
- These six are the prelude's, named in every module, and so are their
  types and test implementations: `Time`, `Instant`, `Duration`, `Path`,
  `Bytes`, `File`, `Command`, `Exit`, `TestClock`, `TestProc` and the
  rest. A program's own `type Time`, `type Command` or `dep Clock` is an
  error: it chooses another name.
- `Net` comes with `Async` in stage 11a ([async.md](async.md),
  [runtime-io.md](runtime-io.md)).
  There is no `Io`.

`Str` arrives in this stage at its smallest: literals, `==` and `show`.
Stage 8 adds what `Fs` needs: `Str`'s methods, `Bytes` and `Path`. A
string is UTF-8, its indices are byte offsets, and `Str.from_utf8(b) !
InvalidUtf8` is the one way from bytes to a string.

## `main`

The runtime installs exactly the built-ins `main` lists in its `uses`, as
the outermost implementations. Anything else is an error:

```
error: nothing installs `Users` before `main`
  ┌─ main.ren:1:16
  │
1 │ fn main() uses Users, Console =
  │                ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
  │
  = help: install one inside `main`: `with mem_users([]) in ...`
```

## Tests

```ren
test "a deposit is stamped with the time" =
  var acme = Bank.empty
  let a = &acme.open()
  TestClock.advance(Duration.minutes(5))
  try &acme.deposit(a, Money.dollars(10))
  let s = try acme.statement(a)
  assert s[0].at == Time.epoch + Duration.minutes(5)

test "main prints the balances, and every refusal" =
  try main()
  assert TestConsole.output() == [
    "7000", "5000",
    "Err(Short(AccountId(2), Money(45000)))", "5000", "true",
    ...
  ]
```

- Tests sit next to the code, and `ren run` ignores them. A test sees
  what an importer sees, and its helpers are test items, `test fn` and
  `test handler`, which only tests see
  ([testing.md](testing.md#tests-are-specifications)).
- **Every test gets the test `Clock`, `Random`, `Console`, `Fs`, `Os`
  and `Proc`, and their controls, implicitly.** No `with`, no fixtures. A test without real
  dependencies gives the same result on every run.
- **A test's `uses` asks for the real implementation:**
  `test "the system clock moves" uses Clock =`. Going outside is visible.
- Any other dependency needs a `with`. Forgetting one is the missing
  implementation error, pointing at the test and the call that needs it.
- **`replay(file)`** is every built-in at once, answered from a journal
  `ren run --record` wrote, found from the test's folder: `with
  replay("tests/build.journal") in try main()`. What the program reads
  is answered from it, and what it writes is compared with it
  ([testing.md](testing.md#the-journal-is-a-test)). Only a test can use
  it.
- A test that fails with an error reports it as `main` does. To check that
  something fails, keep it with `attempt` and compare it with the error
  expected, written by its tag: `assert attempt &acme.deposit(a,
  Money.zero) == Err(NotPositive(Money.zero))`.

### Groups

A group is a function over implementations, so one suite can run against
every implementation of a dependency:

```ren
pub group clock_conforms(c: Clock) with c =
  test "instant never goes backwards" =
    let a = Clock.instant()
    assert Clock.instant() >= a

group "frozen" = clock_conforms(Clock.frozen(Time.epoch))
group "test clock" = clock_conforms(test_clock(Time.epoch))
```

The group's `with` applies to each test separately: every test gets a fresh
instance. A `pub group` can be imported, so a library ships the conformance
suite for the dependencies it defines ([stdlib.md](stdlib.md#three-implementations-one-conformance-suite)).

Every `dep` should ship one, and every implementation of it, test or real,
should run it: that's what keeps a fake from drifting away from what it
stands for. `ren test` reports an implementation that runs no group for
its dependency ([testing.md](testing.md#conformance-groups)).

### `assert`

`assert a == b` shows both sides when it fails, with a marker under the
first place they differ. What they share there is left out: each side
shows the way to that place and what it has there, and every other
field, element and payload is `...`, `Account(..., balance:
Money(-100), ...)`. Any other `assert` shows its source. A failed
`assert` is a panic, not an error: it's a bug.

### `ren test`

```
$ ren test bank
bank.ren
  ✓ a deposit is stamped with the time
  ✓ a transfer moves money, and stamps both sides
  ✗ an overdraft is refused, and nothing moves
  ✓ a frozen account takes nothing in
  ✓ an account that doesn't exist is refused
  ✓ only a positive amount moves
  ✓ an account can't send to itself
  ✗ a batch that fails moves nothing

clocks.ren
  frozen
    ✓ now never goes back
    ✓ an instant never goes back
    ✓ sleeping doesn't move it back
  test clock
    ✓ now never goes back
    ✓ an instant never goes back
    ✓ sleeping doesn't move it back

main.ren
  ✗ main prints the balances, and every refusal

──── an overdraft is refused, and nothing moves ── bank.ren:114
    │
114 │   assert acme == before
    │          ^^^^^^^^^^^^^^
    │
    left:  Bank(accounts: Map.of([(AccountId(1), Account(..., balance: Money(-100), ...)), ...]), ...)
    right: Bank(accounts: Map.of([(AccountId(1), Account(..., balance: Money(1000), ...)), ...]), ...)
                                                                             ^ differs here

    seed 3529 · rerun: ren test bank --only "an overdraft" --seed 3529

...

12 passed, 3 failed
```

- One line per test, then each failure: where, the two sides, the seed, the
  rerun command, and what it printed to `Console`. Above, `debit` was
  broken to check only that the balance isn't negative; `examples.t` has
  all of it, with the batch's failure and `main`'s.
- `--only <text>` runs the tests whose name contains it (`--exact`: whose
  name it is, or whose group run it labels). `--seed N` sets
  every test's seed. `--list` lists tests, and flags the ones that use a
  real dependency.
- It exits with status 1 if anything failed.
- `--keep bug.journal` moves a journal `ren run --record` wrote to the
  `tests/` folder next to its program, and adds a test that replays it
  ([testing.md](testing.md#the-journal-is-a-test)).
- Test output shows a value as `show` does, so an opaque type by name
  around its contents, `Money(-100)`.

## How it runs

Every function takes one hidden parameter in Core, its evidence: the
vector of implementations installed where it's called.
Pure functions take it too, so every function takes the same, and
nothing can disagree about what a call passes (the C backend can drop it
from a function it can prove pure). Every call passes the caller's
evidence on. `with` extends it for its body, so the innermost
implementation of a dependency is the one found. A dependency call finds
its implementation in the vector by the dependency's identity, never by
a name at runtime; for now that's a short search, and when the row is
closed the compiler can make it a fixed index (rule 6). Natively, rule 6
is measured ([bench/native/RESULTS.md](bench/native/RESULTS.md), H2):
`ren build --release` calls an operation of a handler it knows is
installed directly, 0.45 ns a call, the same as a plain function; the
debug build searches the evidence and calls through a pointer, 1.24 ns
against 0.45 compiled at -O2. Each call keeps
its shape, dependency, operation and arguments, which is what the
journal records (stage 10b, [handlers.md](handlers.md#the-journal)):
`ren run --record` installs a recorder over each real implementation,
and `ren replay` a replayer in place of them. Every intrinsic that
reaches the world is called only by its dependency's real
implementation, which Core Lint checks, so nothing reaches the world
but through an operation.

A block captures the evidence where it's written, as it captures a
local, so its dependencies are found there (foundations.md, decision 5).
A debug build passes a block as a code pointer and a frame pointer, and
the frame holds that evidence. The callee provides only what the
parameter's type lists: a call of a block passes the caller's evidence,
and the block puts the caller's implementations of those dependencies
on top of what it captured, as Koka's `evv-insert` does. So `fn
twice(f: fn())` gives `f` nothing, and a `with` around a call of a block
reaches it only when the block's type lists what the `with` installs.
A block never outlives the call it's passed to, so what it captured is
still installed whenever it runs. A named function or an operation
passed as a value, `each(xs, show)`, is a block written there, `fn(x)
=> show(x)`. An implementation keeps the evidence where it's installed,
and its operations run with that: what it needs is fixed at install
(rule 5). An associated value is made once, at
startup, with nothing installed, so it can't use a dependency, and it
can't hold a block. The program starts
in `$start`, which installs the real implementation of each built-in
`main` uses and calls `main`. `ren core` prints all of it.

A handler over another is installed inside it, so the evidence where
it's installed holds the one under it: `next.get(id)` is a dependency
call on that evidence, which the handler's operations capture, and so
does a block written in one, so a `with` around the call still reaches
the one under it, and an operation it leaves out is a block that makes
that call. Its `finally`s are one lambda kept in its instance, as its
operations are, and the `with` calls it when its body ends, with the
body's result and a descriptor of its type.

## Deviations

Where the implementation forced a change to what was settled for this
stage, or settled something the plan left open:

- **The exactness help says `match`, not `try match`.** The settled DX
  said `try match Http.get_rate(c)`, but that `try` would cover nothing
  when the call fails only with the tag being mapped, and the compiler
  says so. The help says `try match` only when the call can fail with
  more.
- **A type's declaration can't name a row.** The plan had stored
  implementations name their rows in record fields. A record holds no
  block (foundations.md), and an implementation it holds needs nothing:
  a type takes one that needs more as a type parameter, written
  `Box<Clock uses ..d>` in a signature.
- **In a type argument, a `uses` list ends at a comma,** where elsewhere
  in a type a comma goes on with it to anything that can be a dependency:
  `Pair<Clock uses Os, Int>` would otherwise need `Int` to be one. A
  named row can still follow, since it can't be an argument, and several
  dependencies are written in parentheses, `Box<(Clock uses Os,
  Console)>`, as `ren types` prints them.
- **A block's dependencies are found where it's written** (stage 10c,
  foundations.md decision 5), except those its parameter's type lists,
  which the callee provides:

  ```ren
  fn with_fake_net(body: fn() uses Net) = with fake_net() in try body()
  ```

  `fake_net()` reaches the block's `Net` calls, and its other
  dependencies, a `print`, are its writer's. A type that lists nothing,
  or a parameter whose type isn't written, gives nothing, so `fn
  run_at(f: fn() -> Time) = with at(1) in try f()` doesn't change the
  clock `f` sees: a wrapper can't handle a block's calls by accident,
  and a helper that installs something for its body says so. A block
  passed where its callee gives more than its type lists is an error,
  whose help is to list them where it's written: `let b: fn() uses Net =
  fn() => ...`, or in its parameter's type. Its errors stay its
  function's: a block parameter fails with what its function does, once
  a `try` passes it on.
- **`ren types` prints a block parameter with what its type lists**,
  `body: fn() uses Net`, or nothing, `f: fn() -> T`; its errors are its
  function's, which aren't printed. Before 10c an unwritten one printed
  its function's rows, `g: fn() -> T ! ..e uses ..d`.
- **A parameter whose type is a dependency's, `r: Rates`, installed
  inside a `with`, still passes everything it needs to the caller**,
  even what that `with` installs: its row is its function's. That's more
  than it needs, never less.
- **A function calling itself inside a `with`** uses only what it does
  outside it, but **two functions that call each other**, one inside a
  `with`, still need what that `with` installs: each sees the other's
  `uses` as its own until the pair is checked.
- **A dependency's `self` is transparent, but can be kept.** In `fn
  scaled(self, k: Int) -> N`, `self` needs what the method uses, as `c:
  N` does, and a receiver that needs less will do. Unlike `c: N`, it can
  be returned or captured, since its type can't be written: kept where it
  needs nothing, `-> N`, only a receiver that needs nothing is taken. A
  public method that keeps it says so, `-> (N uses ..d) uses ..d`.
- **A parameter of a dependency's type passed to a function that keeps
  it** where its rows close, `pub fn f(r: Rates) -> Box<Rates> =
  keep(r)`, is an error at the parameter, whose help names its row: no
  syntactic check sees that `keep` keeps it.

- **A handler's state is a cell per `var`, not one cell.** Each
  operation of an instance reads the `var`s it uses from their cells
  when it starts and writes back the ones it changes when it ends, even
  if it fails; only the runtime holds a cell. A `let` in the state is
  a copy the instance keeps, as it keeps its parameters. A block written
  in an arm shares the arm's copy of a `var`, by reference, so what it
  changes is written back when the arm ends.
- **A handler can't use a dependency it implements,** `Rates.usd_to`
  inside a handler for `Rates`, nor through a function it calls that
  uses `Rates`, even though its operations run with what's installed
  outside it: reaching the implementation under it is `next`'s, through
  `over`. It's checked on what the handler needs, so an arm can still
  install another `Rates`, even the same handler, `with
  counting_rates(r) in ...`, around a call that uses one.
- **A `with` fails with what its handlers' state and `finally` fail
  with,** as the `try` of each: the handler's `fails`, part of its type.
  A public handler writes it, `! DbDown`, after what it implements; a
  private one's is inferred. A written implementation type without `!`
  can't fail to start, a parameter's of a dependency's type included,
  where a block parameter `f: fn()` fails with its function's errors.
- **`finally` is generic in the body's value.** It can give it back, pass
  it on or show it, but comparing, ordering or hashing it is an error,
  and it's given its result as `Ok(v)` or `Err(_)`, the error passed on
  with `try r`, since a `fail` pattern never binds a whole error. The
  `with` fails with the body's errors and the handler's own, whatever
  `finally` does with the body's.
- **A handler is `for` all its dependencies or `over` all of them;** one
  over several can't be narrowed by a written type to one of them.
- **A chain installs what its bottom installs,** each link above taking
  the place of what it goes over: `cached(ttl) over counting()`, where
  `counting` is a `Prices & Calls`, installs both.
- **`next` isn't a keyword:** only in a handler declared `over` does
  `next.op(...)` or `next(A).op(...)` reach the one under it. It can only
  be called through, never kept, and nothing in that handler can be named
  `next`.
- **A panic skips `finally`.** A failed start skips one written below
  the line that failed, and, since 10c, runs one written above it,
  given the error, before the `with` fails with it.
- **10c: a `break` can't leave a `with`,** since its handlers'
  `finally`s are given what the body ends in, and a `break` ends in
  nothing. The help ends the body in a `Bool` and breaks after it.
- **A handler of several dependencies has a type that lists them,**
  `Rates & RateCalls`, from the moment it's made, and it never changes.
  The order doesn't matter: `RateCalls & Rates` is the same type. A
  handler of one has its dependency's type.
- **Where a written type asks for one of them, it becomes that one.**
  A parameter, a function's result, a field, or a `let`'s or a list's
  type: `fn run(r: Rates)`, `-> Clock`, `let cs: Array<Users> = [...]`.
  Giving more than is asked is fine, as Effect's layers allow. From
  there on it's a `Rates`, still describing the same handler, but its
  other dependencies can't be reached through it. A written type can
  also ask for several of them, `c: Clock & TestClock`.
- **`with` installs what the value's type says.** `with h in`, with `h`
  a `Rates & RateCalls`, installs both, sharing one state. Inside `fn
  run(r: Rates)`, `with r in` installs only `Rates`, so nothing is
  installed that the code doesn't show.
- **Anywhere else it keeps its full type,** and where that doesn't fit,
  it's an error that says where to write one. That covers a generic,
  `apply(run, counting_rates(1))`, which never narrows through an
  inferred `A`, branches or list items that differ, and a `with` whose
  value's type isn't known yet, `fn f(c) = with c in`.
- **Types flow left to right,** as in Rust and TypeScript: once a
  value's type is known, later code sees it. `ap(counting_rates(1),
  fn(r) => run(r))` checks, since `r` is already a `Rates & RateCalls`
  when it reaches `run`'s written `Rates`. `ap(fn(r) => run(r),
  counting_rates(1))` is an error: `r` is already a `Rates` when the
  handler arrives, and `ap`'s `T` isn't a written type. The help says to
  write one where the handler is made, `let h: Rates = ...`, which works
  in either order.
- **A method called on it is the one of its dependencies that has it,**
  `h.count()`, and it's an error if more than one does, or if the method
  changes its receiver (`inout self`), since that would make `h` just one
  of them. An operation is found the same way, `h.usd_to(1)`, and called
  with `h` installed for the call ([Descriptions, the only stored
  code](#descriptions-the-only-stored-code)).

```
error: the items in this list have different types
  ┌─ test.ren:3:12
  │
3 │   let bs = [pg_users(db), counting_users()]
  │             ^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^ is `Users & UserCalls`
  │             is `Users`
  │
  = help: say what the list holds: `let bs: Array<Users> = ...`
```

```
error: `with` can't tell what `c` installs
  ┌─ app.ren:1:18
  │
1 │ fn run(c) = with c in serve()
  │                  ^ its type isn't written
  │
  = help: write it: `fn run(c: Clock)`
```

- **A handler keeps no block.** Its parameters are data: one whose type
  has a block in it is an error, whose help is `pass the data, or make
  the behaviour a dependency`.
- **A handler's name starts with a lowercase letter,** as a function's
  does, which is now an error for both: a capitalized name is a type's.
- **A handler's parameters are written in parentheses even if it has
  none,** `handler transaction() for Sql =`, as a function's are:
  calling it, `transaction()`, describes it, and `with transaction in`
  is an error whose help says to call it.

- **`test`, `group` and `assert` are keywords,** so nothing else can be
  named one.
- **Tests are checked whenever their module is,** by `ren run` and `ren
  check` too, which don't run them, so a broken test stops `ren run`.
  It's what lets a module import another only to run its `pub group`.
- **A group's parameters are written in parentheses even if it has
  none,** `group smoke() =`, as a handler's are, and its `with` is
  optional.
- **A test in a group's run is named after the run's label,** `frozen /
  instant never goes backwards`: that's the name `--only` looks in and
  its seed comes from, and what a failure is headed with.
- **The test `Clock` moves on when it's slept on,** as `advance` moves
  it, so sleeping in a test takes no time.
- **The test `Random`'s numbers come from its seed alone,** by a linear
  congruential generator, the same on every machine. A test's own seed
  is a hash of its name, from 0 to 9999.
- **A failure's rerun names the shortest start of the test's name, of at
  least two words, that no other test's name has,** or all of it, with
  `--exact` if another test's name has all of it inside, `panics` in
  `it panics`. What the test printed comes after it, under `printed:`.
  A name is shown as it's written: a line break in it is `\n`, so its
  lines stay whole, and its rerun looks for what comes before the break.
- **`REN_NO_TIMINGS`, set, leaves out how long the tests took,** as the
  cram tests do.
- **The test implementations are the prelude's too:** `TestClock`,
  `TestRandom`, `TestConsole`, `test_clock`, `test_random` and
  `test_console` are named in every module, as the six above are, so a
  program can't declare its own with those names, and the dependencies
  in scope an error lists include them.
- **A test's body is `Unit`,** as a statement is: one that ends in a
  value, `compute() == 3` without its `assert`, is an error whose help
  says to `assert` it.
- **`--only` that matches no test exits with status 1,** since a
  mistyped name in a rerun command would otherwise look like a pass.
  `--exact` makes `--only` match a whole name, or a group run's label,
  which is what an editor's run button beside a test uses.
- **A test that asks for the real `Console`** writes to stdout as it
  runs, between the lines `ren test` prints for each test.
- **`ren test` on a folder leaves out a folder in it that holds a program
  of its own,** one with a file that declares `main`, with a note saying
  to test it on its own: its imports are found from its folder, so it
  can't be part of the outer program. `ren test examples` runs only the
  files right in `examples`.
- **A run of a group calls each of its tests with `try`,** so a group's
  test that fails with an error is reported like `main`, as a top-level
  test is.
- **`ren run` shows a failed `assert a == b`'s sides as `ren test`
  does,** through their types, `Money(-100)`.
- **`show` is the one built-in that knows its argument's type.** At
  runtime an opaque value is only what it's represented as, so the
  interpreter works out, at each call of a generic function, what its
  type parameters are, as a compiler that copies a generic function for
  each type would: `print<T>` shows a `Money` as one. Where nothing
  says, `show` falls back on the value's shape, `-100`.
- **A type's own `show` is used wherever its values are shown,** inside
  a record, an error, and the sides of a failed `assert` too, even if it
  hides how two values differ. Inside it, `show(self)` shows only what
  `self` is represented as, so it doesn't call itself: `pub fn show(self)
  -> Str = show(self).concat("c")` shows `2c`. A `show` that fails, uses
  a dependency or takes more than `self` isn't used.
- **An error that ends `main` or a test is shown through its tags'
  types too,** `error: Frozen(AccountId(3))`, so a `Path` in one is
  shown by `Path.show`, `error: NoSuchFile(justfile)`.
- **A failure shows only the first difference.** The way to it is kept,
  and everything else is `...`, even another place the sides differ, so
  that the two lines stay short and the marker finds the one shown. A
  part that can't be looked inside, an opaque value, one its type's own
  `show` shows, two different constructors or an element only one side
  has, is shown whole. Arrays that differ only in length keep the last
  element both have, so the shorter one reads as ending there, `[..., 3]`
  against `[..., 3, 4, ...]`. A value whose parts are all shown the same,
  through a `show` that hides a difference, is shown in full.
- **The settled test of a deposit lacked a `try`:** `acme.statement(a)`
  fails with `NoSuchAccount`, so the test reads it into a `let` with
  `try` first.
- **An error can be written inside `Err(...)`, by its tag,** so a test
  of a refusal compares what it kept, `assert attempt &acme.transfer(t)
  == Err(Short(a, Money.dollars(1)))`, and a failure shows what came
  back. Only a tag goes inside `Err`, so an error is still never a value
  outside a `Result`. Where its `Result` meets what an `attempt` kept or
  a declared `Result`, on either side of `==`, through a `let` or inside
  another value, the tag has to be one of its errors, as in a pattern;
  otherwise it makes a set of its own. A name inside `Err` is always a
  tag, as in a pattern, even where a type in scope has a constructor of
  that name: `Err(Some(1))` holds the error `Some(Int)`.
- **`try` passes on the error of a `Result` written with `Err`,** as it
  does any `Result`'s: `let r = Err(Gone(1))` then `try r` fails with
  `Gone(1)`, and so does `try made()` for a `fn made() = Err(Gone(1))`.
  Refusing that would mean tracking where each set's tags were written,
  through every function. Only `try Err(X)` written directly is an error,
  whose help says `fail X`, the way to fail with an error written in
  place.
- **`attempt` stops at a comparison,** where `try` takes everything to
  its right: `attempt f() == x` is `(attempt f()) == x`, so a test can
  compare what it kept. Arithmetic is still inside it, `attempt a() +
  b()`.
- **A string stays UTF-8.** A literal that isn't is an error, and
  `slice` panics at an offset inside a character, as well as out of
  bounds, so no `Str` can hold bytes `from_utf8` would refuse.
- **`split("")` panics**, since there's nothing to split on.
- **`Path.join` takes a `Str`**, `src.join("main.ren")`, and a name that
  starts at the root, `/etc`, replaces the path, as in most languages.
- **A write into a folder that isn't there fails with `NoSuchFile`,**
  naming the file, as the system does.
- **The real `Fs.exists` is true of a folder,** as the system says,
  though `mem_fs` has only files.
- **The real `Os.args` panics at an argument that isn't UTF-8,** since a
  `Str` can't hold it.
- **`mem_fs` finds a file by its path exactly as it's written,** so
  `a/b` and `a//b` are two files.
- **`Proc` is a dependency of its own,** not part of `Os`, so a test can
  fake the programs it runs and keep the real arguments, or the other way
  round.
- **The real `Proc` looks for a program on `PATH` itself,** so one that
  isn't there fails with `NoSuchProgram`, never exit code 127. On `PATH`
  it skips a file that can't be run, as a shell does. A file that may be
  run but isn't a program is left to the system: Linux refuses it, with
  `CantRun`, and macOS runs it with `sh`.
- **A test `Proc`'s exit codes are a table,** `test_proc([Exit { command,
  code }])`, matched on the whole `Command`, since a program run through
  `sh -c` is told apart by its arguments.
- **The just fails in four more ways than stage 8 set out,** besides
  `UnknownRecipe` and `RecipeFailed`: `BadLine(number)`, a line that's
  neither a recipe nor one of its lines; `Cycle(name)`, a recipe that
  depends on itself; `DuplicateRecipe(name)`, a name given to two
  recipes, as just refuses; and `NoRecipes`, a justfile with none to run
  first.

## Later

- A handler that goes over some dependencies and implements others
  whole.
- `Async` and `Net` (stage 11a, [async.md](async.md)).
- Naming a stack of `with` items as a value, and hiding a dependency from
  the body it's installed around, as Effect's `Layer.provide` does.
- Sharing one instance across a suite, for an expensive real dependency.
- The rest of `Os`, `env` and `exit`, and capturing what a program
  prints.
- The rest of `Str` and `Path`: `Path.parent` and `extension`, listing a
  folder.
- A monotonic `Clock.instant` (stage 13).

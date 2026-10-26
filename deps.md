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

  pub fn frozen(at: Time) -> Clock =
    Clock { now: fn() => at, instant: fn() => Instant.zero, sleep: fn(_) => () }
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
  self.balance = self.balance.plus(m)
  &self.statement.push(Entry { at: Clock.now(), what })
```

A dependency call takes no marker. The capitalised `Clock.` already shows
it, and a call to a function that uses `Clock` indirectly is covered by that
function's signature, as `&` marks only the thing changed. It never takes
`&` either: a handler's state isn't a value the caller holds.

## Implementations

An implementation is a value of the dependency's type, written one of two
ways.

**Stateless:** a record literal, like `Clock.frozen` above.

**Stateful:** a `handler`, which can implement several dependencies that
share one state:

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
   ┌─ fx.ren:12:5
   │
12 │     usd_to: fn(c) => try Http.get_rate(c)
   │                      ^^^^^^^^^^^^^^^^^^^^ fails with `Timeout`
   │
   = note: `Rates.usd_to` can fail only with `RateUnavailable`
   = help: map it: `match Http.get_rate(c)` with the arm `fail Timeout => fail RateUnavailable`
```

  The help says `try match` instead when the call fails with more than the
  tag it maps, which the `try` passes on.

- **A parameter of a dependency type follows the closure rule.** If it's
  only installed, it's transparent, and what it needs flows to the caller.
  One that's stored names its row, `Clock uses ..d`, as a stored closure
  writes `fn() ! ..e uses ..d`.
- `uses` after a dependency's name is what an implementation needs:
  `c: Clock uses Os`. After `->` a `uses` is the function's own, so a
  result writes it in parentheses: `-> (Clock uses Os)`.
- In a type argument, a comma after a `uses` list ends the argument, so
  `Pair<fn() uses Clock, Int>` has two; a named row can still follow,
  `Box<fn() uses Clock, ..d>`, and several dependencies are written in
  parentheses, `Box<(fn() uses Clock, Console)>`.
- **Only a signature names a row.** Every `..d` in one signature is the
  same row, and the body can write it again, in a `let`'s type or a
  lambda's parameter. A function that declares its `uses` or `!` declares
  the rows it adds to them too: `fn press(f: fn() uses ..d) uses ..d`. A
  type's declaration can't name one yet, so a type that keeps a closure
  takes it as a type parameter, `type Button<F> = { on_click: F }`, and a
  signature writes `Button<fn() ! ..e uses ..d>`.
- A handler forwarding to the next implementation out, `outer`, comes
  later (stage 10).

## `with`

```ren
with Clock.frozen(t), counting_rates(Decimal.one) in
  body
```

- Items are installed outermost first. The innermost implementation of a
  dependency wins. A line that ends in `,` goes on with the list on the
  next, indented further. That holds for any line outside brackets that
  ends in `,`, so a signature's `uses` list wraps the same way:
  `uses Clock,` then `    Console =` on the next line.
- `with` removes what it installs from the body's `uses`, and adds what its
  items need.
- An item is an implementation, or a **wrapper**: a function whose last
  parameter is the body. `with retry(3) in body` is `retry(3, fn() => body)`.
  A function of one parameter is a wrapper on its own: `with twice in body`.
- The body of a wrapper is a lambda, so it marks its own calls, and the
  `with` passes on what the wrapper fails with, as `try` would:
  `attempt with retry(3) in try fetch()`. Like any lambda's, it can't
  change a variable from outside it; it gives back a value instead.

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
  its type's name, `Account { id: AccountId(1), ... }`, and an opaque
  value as its type's name around what it is, `Money(-100)`, unless the
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
- `Time`, `Instant` and `Duration` are opaque, with methods only until
  operators arrive (stage 9). A `Duration` is made with `ms`, `seconds`
  or `minutes`, added to with `plus` and `times`, compared with `before`
  and `after`, and read back with `in_ms`.
- For now the real `instant` reads the same wall clock as `now`, which the
  system can set back (NTP, a manual change). A monotonic source needs a
  primitive OCaml's standard library doesn't have; it comes with the
  runtime's own system calls (stage 13).
- These six are the prelude's, named in every module, and so are their
  types and test implementations: `Time`, `Instant`, `Duration`, `Path`,
  `Bytes`, `File`, `Command`, `Exit`, `TestClock`, `TestProc` and the
  rest. A program's own `type Time`, `type Command` or `dep Clock` is an
  error: it chooses another name.
- `Net` comes with `Async` in stage 12 ([runtime-io.md](runtime-io.md)).
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
  assert s[0].at == Time.epoch.plus(Duration.minutes(5))

test "main prints the balances, and every refusal" =
  try main()
  assert TestConsole.output() == [
    "7000", "5000",
    "Err(Short(AccountId(2), Money(45000)))", "5000", "true",
    ...
  ]
```

- Tests sit next to the code, so they can reach private functions. `ren run`
  ignores them.
- **Every test gets the test `Clock`, `Random`, `Console`, `Fs`, `Os`
  and `Proc`, and their controls, implicitly.** No `with`, no fixtures. A test without real
  dependencies gives the same result on every run.
- **A test's `uses` asks for the real implementation:**
  `test "the system clock moves" uses Clock =`. Going outside is visible.
- Any other dependency needs a `with`. Forgetting one is the missing
  implementation error, pointing at the test and the call that needs it.
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
    assert Clock.instant().not_before(a)

group "frozen" = clock_conforms(Clock.frozen(Time.epoch))
group "test clock" = clock_conforms(test_clock(Time.epoch))
```

The group's `with` applies to each test separately: every test gets a fresh
instance. A `pub group` can be imported, so a library ships the conformance
suite for the dependencies it defines ([stdlib.md](stdlib.md#three-implementations-one-conformance-suite)).

### `assert`

`assert a == b` shows both sides when it fails, with a marker under the
first place they differ. What they share there is left out: each side
shows the way to that place and what it has there, and every other
field, element and payload is `...`, `Account { ..., balance:
Money(-100), ... }`. Any other `assert` shows its source. A failed
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
    left:  Bank { accounts: [Account { ..., balance: Money(-100), ... }, ...], ... }
    right: Bank { accounts: [Account { ..., balance: Money(1000), ... }, ...], ... }
                                                           ^ differs here

    seed 3529 · rerun: ren test bank --only "an overdraft" --seed 3529

...

12 passed, 3 failed
```

- One line per test, then each failure: where, the two sides, the seed, the
  rerun command, and what it printed to `Console`. Above, `covers` was
  broken to check only that the balance isn't negative; `examples.t` has
  all of it, with the batch's failure and `main`'s.
- `--only <text>` runs the tests whose name contains it (`--exact`: whose
  name it is, or whose group run it labels). `--seed N` sets
  every test's seed. `--list` lists tests, and flags the ones that use a
  real dependency.
- It exits with status 1 if anything failed.
- Test output shows a value as `show` does, so an opaque type by name
  around its contents, `Money(-100)`.

## How it runs

Every function and lambda takes one hidden parameter in Core, its
evidence: the vector of implementations installed where it's called.
Pure functions take it too, so every function takes the same, and
nothing can disagree about what a call passes (the C backend can drop it
from a function it can prove pure). Every call passes the caller's
evidence on. `with` extends it for its body, so the innermost
implementation of a dependency is the one found. A dependency call finds
its implementation in the vector by the dependency's identity, never by
a name at runtime; for now that's a short search, and when the row is
closed the compiler can make it a fixed index (rule 6). Each call keeps
its shape, dependency, operation and arguments, which is what the effect
journal (stage 10) will record.

A closure gets the evidence of whoever calls it, not of where it was
made, so one that outlives its `with` uses what's installed where it's
called, and a function over closures, `fn twice(f: fn())`, just passes
`f` its own. An implementation keeps the evidence where it's installed,
and its operations run with that: what it needs is fixed at install
(rule 5). An associated value is made once, at startup, with nothing
installed, so it can't use a dependency; a closure stored in one gets its
caller's evidence when it's called, like any other. The program starts
in `$start`, which installs the real implementation of each built-in
`main` uses and calls `main`. `ren core` prints all of it.

## Deviations

Where the implementation forced a change to what was settled for this
stage, or settled something the plan left open:

- **The exactness help says `match`, not `try match`.** The settled DX
  said `try match Http.get_rate(c)`, but that `try` would cover nothing
  when the call fails only with the tag being mapped, and the compiler
  says so. The help says `try match` only when the call can fail with
  more.
- **A type's declaration can't name a row.** The plan had stored
  closures and implementations name their rows in record fields; a
  type takes them as a type parameter instead, `type Button<F> = {
  on_click: F }`, written `Button<fn() uses ..d>` in a signature.
- **In a type argument, a `uses` list ends at a comma,** where elsewhere
  in a type a comma goes on with it to anything that can be a dependency:
  `Pair<fn() uses Clock, Int>` would otherwise need `Int` to be one. A
  named row can still follow, since it can't be an argument, and several
  dependencies are written in parentheses, `Box<(fn() uses Clock,
  Console)>`, as `ren types` prints them.
- **A wrapper's body can't change a variable from outside it.** It's a
  lambda, which captures values, so a change would be lost.
- **The `with` around a wrapper is the wrapper call's `try`.** What the
  wrapper fails with goes on, as for `try`; the body marks its own calls.
- **A parameter whose type is written transparent, `f: fn() -> Int` or
  `r: Rates`, and is called or installed inside a `with`, still passes
  everything it uses to the caller**, even what that `with` installs: its
  row is its function's. That's more than it needs, never less. An
  inferred parameter, `fn run_at(f) = with at(1) in try f()`, gets
  exactly what the `with` doesn't install, and a signature can say so:
  `f: fn() -> Int uses Clock, ..d` with `uses ..d`.
- **A closure called inside two `with`s** gets only what's installed
  outside both, so the same holds for it.
- **A function calling itself inside a `with`** uses only what it does
  outside it, but **two functions that call each other**, one inside a
  `with`, still need what that `with` installs: each sees the other's
  `uses` as its own until the pair is checked.
- **`ren types` prints a transparent parameter without the rows a
  signature names for it**, `body: fn() -> Int ! ..e uses ..d` as `body:
  fn() -> Int`, when they're only its function's own: the two are the
  same type.
- **A dependency's `self` is transparent, but can be kept.** In `fn
  scaled(self, k: Int) -> N`, `self` needs what the method uses, as `c:
  N` does, and a receiver that needs less will do. Unlike `c: N`, it can
  be returned or captured, since its type can't be written: kept where it
  needs nothing, `-> N`, only a receiver that needs nothing is taken. A
  public method that keeps it says so, `-> (N uses ..d) uses ..d`.
- **A transparent parameter passed to a function that keeps it** where
  its rows close, `pub fn f(g: fn() -> Int) -> Box<fn() -> Int> =
  store(g)`, is an error at the parameter, whose help names its rows: no
  syntactic check sees that `store` keeps it.

- **A handler's state is a cell per `var`, not one cell.** Each
  operation of an instance reads the `var`s it uses from their cells
  when it starts and writes back the ones it changes when it ends, even
  if it fails; only the runtime holds a cell. A `let` in the state is
  kept as a lambda keeps a value.
- **A handler can't use a dependency it implements,** `Rates.usd_to`
  inside a handler for `Rates`, nor through a function it calls that
  uses `Rates`, even though its operations run with what's installed
  outside it: reaching the next implementation out is `outer`'s (stage
  10), and the README's section 7 already says it's an error. It's
  checked on what the handler needs, so an arm can still install
  another `Rates`, even the same handler, `with counting_rates(r) in
  ...`, around a call that uses one.
- **A handler's state is made where it's installed, and can't fail:**
  the `with` that installs it isn't a call a `try` could mark.
- **A handler of several dependencies has a type of its own,** named
  after it, `counting_rates`, which can't be written. A handler of one
  has its dependency's type, so `pub fn mem() -> Rates = counting(1)`
  and `fn run(r: Rates) = with r in ...` take either kind of
  implementation. Where a value of one of a handler's several
  dependencies' types is wanted, a parameter, an annotation, a function's
  result or a field, it's taken as a description of an implementation
  of just that one, and installing it makes a fresh instance and installs
  only that: `clock_conforms(test_clock(t))` with `c: Clock`. What's
  wanted can be said before the handler is given or after, in the same
  function: `same(test_clock(t), c)` takes it as a `Clock` as
  `same(c, test_clock(t))` does. A `with` that installs it, or a call of
  a method of one of them, can come before what says which as well as
  after (compiler.md's Deviations has the one exception). Where nothing
  says which, `let h = counting_rates(1)`, it keeps its own type: `with
  h in` installs all of them, sharing one state, and `run(h)` takes it
  as a `Rates`, inside that `with` too. So a value of a dependency's
  type is a record or a handler's description, and `with` tells which as
  it runs. A handler that keeps a closure names its row in its own
  signature, `handler h(f: fn() -> Int uses ..d) for N uses ..d`.
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

- `outer` and forwarding handlers, and the journal (stage 10).
- `Async` and `Net` (stage 12).
- Naming a stack of `with` items as a value, and hiding a dependency from
  the body it's installed around, as Effect's `Layer.provide` does.
- Sharing one instance across a suite, for an expensive real dependency.
- The rest of `Os`, `env` and `exit`, and capturing what a program
  prints.
- The rest of `Str` and `Path`: `Path.parent` and `extension`, listing a
  folder.
- A monotonic `Clock.instant` (stage 13).

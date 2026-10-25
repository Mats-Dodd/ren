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
pub fn credit(inout self, m: Money, what: Movement) uses Clock =
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
- **Only a signature names a row.** Every `..d` in one signature is the
  same row, and the body can write it again, in a `let`'s type or a
  lambda's parameter. A function that declares its `uses` or `!` declares
  the rows it adds to them too: `fn press(f: fn() uses ..d) uses ..d`. A
  type's declaration can't name one yet, so a type that keeps a closure
  takes it as a type parameter, `type Button<F> = { on_click: F }`, and a
  signature writes `Button<fn() ! ..e uses ..d>`.
- A handler forwarding to the next implementation out, `outer`, comes
  later (stage 9).

## `with`

```ren
with Clock.frozen(t), counting_rates(Decimal.one) in
  body
```

- Items are installed outermost first. The innermost implementation of a
  dependency wins.
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
| `Console` | `write(line: Str)` | stdout | captured | `TestConsole.output() -> Array<Str>` |

- `print(x)` is an ordinary prelude function: `Console.write(show(x))`.
- `Time`, `Instant` and `Duration` are opaque, with methods only until
  operators arrive (stage 9).
- For now the real `instant` reads the same wall clock as `now`, which the
  system can set back (NTP, a manual change). A monotonic source needs a
  primitive OCaml's standard library doesn't have; it comes with the
  runtime's own system calls (stage 8, `Os`).
- These six are the prelude's, named in every module, so a program's own
  `type Time` or `dep Clock` is an error: it chooses another name.
- `Fs`, `Net` and `Os` come in stage 8, with strings ([runtime-io.md](runtime-io.md)).
  There is no `Io`.

`Str` arrives in this stage at its smallest: literals, `==` and `show`.
Everything else about strings is stage 8.

## `main`

The runtime installs exactly the built-ins `main` lists in its `uses`, as
the outermost implementations. Anything else is an error:

```
error: nothing installs `Users` before `main`
  ┌─ main.ren:1:16
  │
1 │ fn main() uses Users, Console =
  │                ^^^^^ the runtime installs only `Clock`, `Random` and `Console`
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
  assert acme.statement(a)[0].at == Time.epoch.plus(Duration.minutes(5))

test "main prints the balances" =
  try main()
  assert TestConsole.output() == ["10000", "0", "45000"]
```

- Tests sit next to the code, so they can reach private functions. `ren run`
  ignores them.
- **Every test gets the test `Clock`, `Random` and `Console`, and their
  controls, implicitly.** No `with`, no fixtures. A test without real
  dependencies gives the same result on every run.
- **A test's `uses` asks for the real implementation:**
  `test "the system clock moves" uses Clock =`. Going outside is visible.
- Any other dependency needs a `with`. Forgetting one is the missing
  implementation error, pointing at the test and the call that needs it.
- A test that fails with an error reports it as `main` does. To check that
  something fails, use `attempt`.

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
first place they differ. Any other `assert` shows its source. A failed
`assert` is a panic, not an error: it's a bug.

### `ren test`

```
$ ren test bank/
bank.ren
  ✓ a deposit is stamped with the time
  ✗ an overdraft is refused, and nothing moves

──── an overdraft is refused, and nothing moves ── bank.ren:14
   │
14 │   assert acme == before
   │          ^^^^^^^^^^^^^^
   │
   left:  Bank { accounts: [Account { id: AccountId(1), balance: Money(-100), ... }], next: 3 }
   right: Bank { accounts: [Account { id: AccountId(1), balance: Money(0), ... }], next: 3 }
                                                                  ^ differs here

   seed 2871 · rerun: ren test bank/ --only "an overdraft" --seed 2871

1 passed, 1 failed in 5ms
```

- One line per test, then each failure: where, the two sides, the seed, the
  rerun command, and what it printed to `Console`.
- `--only <text>` runs the tests whose name contains it. `--seed N` sets
  every test's seed. `--list` lists tests, and flags the ones that use a
  real dependency.
- It exits with status 1 if anything failed.
- Test output shows an opaque type by name around its contents,
  `Money(-100)`.

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
journal (stage 9) will record.

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
  9), and the README's section 7 already says it's an error. It's
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
  dependencies' types is wanted as it's made, a parameter, an annotation,
  a function's result or a field, it's taken as a description of an
  implementation of just that one, and installing it makes a fresh
  instance and installs only that: `clock_conforms(test_clock(t))` with
  `c: Clock`. Where nothing says which, `let h = counting_rates(1)`, it
  keeps its own type: `with h in` installs all of them, sharing one
  state, and `run(h)` takes it as a `Rates`, inside that `with` too. So
  a value of a dependency's type is a record or a handler's description,
  and `with` tells which as it runs. A handler that keeps a closure names
  its row in its own signature, `handler h(f: fn() -> Int uses ..d) for N
  uses ..d`.
- **A handler's name starts with a lowercase letter,** as a function's
  does, which is now an error for both: a capitalized name is a type's.
- **A handler's parameters are written in parentheses even if it has
  none,** `handler transaction() for Sql =`, as a function's are:
  calling it, `transaction()`, describes it, and `with transaction in`
  is an error whose help says to call it.

## Later

- `outer` and forwarding handlers, `Async`, the journal (stage 9).
- Naming a stack of `with` items as a value, and hiding a dependency from
  the body it's installed around, as Effect's `Layer.provide` does.
- Sharing one instance across a suite, for an expensive real dependency.
- `Fs`, `Os`, `Path` and full strings (stage 8).

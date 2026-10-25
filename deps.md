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
6. **A dependency call costs a function call.** It compiles to a hidden
   parameter, not a lookup.

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
   = help: map it: `try match Http.get_rate(c)` with the arm `fail Timeout => fail RateUnavailable`
```

- **A parameter of a dependency type follows the closure rule.** If it's
  only installed, it's transparent, and what it needs flows to the caller.
  One that's stored names its row, `Clock uses ..d`, as a stored closure
  writes `fn() ! ..e uses ..d`.
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

Each dependency in a function's `uses` becomes a hidden parameter in Core,
and `with` binds it. Nothing is looked up by name at runtime (rule 6), and
the C backend inherits it as it is. A closure gets its dependencies where
it's called, not where it was made, so one that outlives its `with` never
holds on to the old implementation. Each call keeps its shape, dependency,
operation and arguments, which is what the effect journal (stage 9) will
record.

A function over closures, `fn twice(f: fn())`, doesn't know what `f` uses,
so it couldn't know what to pass it. Instead it has a copy for each set of
dependencies its callers' closures use: `twice(fn() => print(1))` calls
`twice[Console]`, in which `f` takes `Console`. So a closure's hidden
parameters are always exactly what its type names, wherever it's called.
An associated value holding a closure, `let one = fn() => 1`, is made once
at startup, so it gets copies the same way: `T.one()` in a function that
uses Console reads `T.one[Console]`, made right after `T.one`.
The program starts in `$start`, which installs the real implementation of
each built-in `main` uses and calls `main`. `ren core` prints all of it.
(The copies are a choice the implementation made, and the plan didn't
spell out: passing a whole row of evidence as one value would need it
looked up by name inside.) A closure's type is inferred together with
its caller's, so it usually names the caller's whole `uses`, not just what
its body uses: `twice_gen(fn(x) => x + 1)` in a `main` that uses Clock,
Console and Random calls `twice_gen[Clock, Console, Random]`. That runs
the same, but the copies grow with callers' rows rather than with what the
closures use; the rows on stored closures (`uses ..d`) are where to make
them smaller.

## Later

- `outer` and forwarding handlers, `Async`, the journal (stage 9).
- Naming a stack of `with` items as a value, and hiding a dependency from
  the body it's installed around, as Effect's `Layer.provide` does.
- Sharing one instance across a suite, for an expensive real dependency.
- `Fs`, `Os`, `Path` and full strings (stage 8).

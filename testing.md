# Testing

How Ren tests a program: at its boundaries, with tests that are
specifications, data generated from the domain's own types, and a console
for everything that isn't a specification. What runs today, `test`,
`group`, `assert` and `ren test` on test implementations, is in
[deps.md](deps.md#tests). This doc is where that's going.

> **Status:** partly built. Stage 9c runs: tests are specifications, test
> items, `test fn` and `test handler`, and a first `ren console`, with
> types, private items and the choice of world. Stage 10b runs what needs
> the journal: a journal as a test, `replay(file)` and `ren test --keep`,
> and the console's effects shown as they happen, `:reload` and `:spec`.
> Property tests come with the standard library in stage 12. See
> [Roadmap](#roadmap).

## What it has to do

The truth about a program lives at its boundaries: a type's, a module's,
and the program's own, where it meets the world. Ren makes each of them
explicit and narrow ([module-build.md](module-build.md#private-unless-pub)),
and tests them there.

1. **A test is a specification.** It says what an interface does, as a
   client sees it, so changing what's behind the interface never breaks
   it. Refactoring is free, and a red test means behaviour changed.
2. **Exploring isn't testing.** Poking at a private function while writing
   it is real work, but it's done in the [console](#the-console), not left
   behind in the suite, where it would hold the implementation in place.
3. **The fakes are held to the real thing.** A test implementation of a
   dependency runs the same conformance suite as the real one, so a test
   that passes against the fake means something.
4. **Generating data is free, and stays valid.** Any type can be
   generated without writing anything, a value its module wouldn't allow
   is never generated, and a failure shrinks to its smallest case without
   a shrinker.
5. **One mechanism.** Generated data, saved failures, recorded runs,
   fuzzing and, later, simulation schedules are all a sequence of choices
   read through dependencies, so one runner replays all of them.

## Tests are specifications

**A test sees what an importer sees.** Tests live in the module they test,
next to the code, but they're its clients: they see its `pub` items, and
its opaque types are opaque to them.

```ren
pub type Account = opaque { id: AccountId, balance: Money, frozen: Bool, statement: Array<Entry> }
  pub fn open(id: AccountId) -> Account = ...
  pub fn balance(self) -> Money = self.balance
  pub fn freeze(inout self) = self.frozen = true
  pub fn credit(inout self, m: Money, what: Movement) ! Frozen(account: AccountId) uses Clock = ...
  fn stamp(inout self, e: Entry) = ...

test "a frozen account takes nothing in" =
  var a = Account.open(AccountId.of(1))
  &a.freeze()
  assert attempt &a.credit(Money.dollars(5), Deposit) == Err(Frozen(AccountId.of(1)))
```

A test that reaches past the interface is an error, reported at the first
use of each item it reaches:

```
error: `stamp` is private, and a test sees what an importer sees
  ┌─ account.ren:22:5
  │
22 │   &a.stamp(e)
  │      ^^^^^
  │
  = a test is a specification of `account`'s interface
  help: mark it `pub`, or explore it in the console: `ren console account`
```

- **What it costs:** a private helper isn't tested on its own. It's tested
  through what uses it. A helper tricky enough to want its own tests has
  earned its own module, which is one file away.
- **A program's interface is its `pub` items too.** Nothing imports
  `main.ren`, but its tests do, so a script marks what it wants tested
  `pub`. A larger program ends up with a thin `main` and its work in
  modules it imports.
- **Why other languages give in:** Java's `@VisibleForTesting`, Swift's
  `@testable import`, C#'s `InternalsVisibleTo`, Go's `export_test.go` and
  Rust's inline `mod tests` all exist because there tests are the only
  tool for poking at internals. Ren gives exploring its own tool, so tests
  don't need the hole.

### Test items

Tests need helpers: a handler that keeps accounts in memory, a builder for
a sample user. Making them `pub` would fill the interface with
scaffolding, so `test` before an item makes it a test item:

```ren
test handler mem_accounts(init: Array<Account>) for Accounts =
  var table: Map<AccountId, Account> = Map.of(init.map(fn(a) => (a.id(), a)))
  get(id) => table.get(id)
  save(a) => &table.set(a.id(), a)

test fn alice() -> Account = Account.open(AccountId.of(1))
```

- **Only tests see a test item,** in its own module, and in any module
  that imports it if it's `pub test fn` or `pub test handler`: test items
  are private unless `pub`, like everything else. A public one is in an
  interface tier of its own that only tests read, and `ren run` drops it,
  as it drops tests. Code that isn't a test can't call one:

  ```
  error: `alice` is a test item, so only a test can use it
    = a test item isn't part of `bank`'s interface, and `ren run` leaves it out
    help: call it from a test, or remove `test` from its declaration
  ```

- **Only a function or a handler can be a test item.** A test type, or a
  test dependency, would need a view of its own in that tier, so a
  dependency only tests use, like [examples/prices](examples/prices)'
  `Calls`, is an ordinary `pub dep`.
- **A test item sees what an importer sees, too.** Otherwise
  `test fn peek(a) = a.balance` would bring the internals back in through
  a helper.

### Conformance groups

A [group](deps.md#groups) is a function over implementations, so one suite
runs against each of them. That's a specification of an interface, run
against everything that claims to meet it:

```ren
pub group accounts_conform(a: Accounts) with a =
  test "what's saved is what's got" (acc: Account) =
    try Accounts.save(acc)
    assert Accounts.get(acc.id()) == Some(acc)

group "in memory" = accounts_conform(mem_accounts([]))
group "sql" uses Sql = accounts_conform(sql_accounts())
```

- **Every `dep` should ship a `pub group`,** and every implementation of
  it, test or real, should run it. That's how a fake is kept honest: the
  usual weakness of mocks is that they drift from what they stand for,
  and here they fail the same suite the real one passes.
- **`ren test` reports an implementation that runs no group for its
  dependency.** It's a report, not an error: a one-off fake in a single
  test doesn't need a suite.
- **A group with parameters is a property test** (below), so a conformance
  suite can check every implementation against generated data.

## Property tests

**A test with parameters is a property test.** Its parameters are
generated, the test runs for each set, and a failure shrinks to the
smallest one:

```ren
test "a transfer never changes the total" (a: Account, b: Account, m: Money) =
  var bank = Bank.of([a, b])
  let before = bank.total()
  let _ = attempt &bank.transfer(Transfer { from: a.id(), to: b.id(), amount: m })
  assert bank.total() == before
```

```
✗ a transfer never changes the total, failed after 37 cases, shrunk in 112 steps:
    a = Account(id: AccountId(1), balance: Money(0))
    b = Account(id: AccountId(1), balance: Money(0))     ← the same key twice
    m = Money(1)
  saved: replayed first, every run, until it passes
  rerun: ren test bank --only "a transfer" --seed 8812
```

There's no new keyword, no library and no strategy language. Four layers,
each optional.

### 1. Every type generates itself

- **A record or a sum type** is built field by field. Constructors are
  tried in the order they're written, and the ones that don't recur come
  first, so generating always ends.
- **Generation leans toward what breaks code:** `0`, `1`, `-1`, the
  largest and smallest `Int`, `-0.0` and infinity (there's no `NaN` to
  generate), `""`, text with combining characters, an empty array, one
  element, and **two elements with the same key**, since a map is wrong
  exactly where keys collide.
- **Sizes grow over a run,** small first, so the first failure is already
  small.

### 2. An opaque type is built through its constructors

Code outside a module can't build an `Email` from its representation, and
neither can generation. A derived generator for an opaque type calls the
type's `pub` functions that return one, `Email.parse` or `Money.cents`,
with generated arguments, and drops the calls that fail. **A value the
module wouldn't allow is never generated,** which is the deep module's
rule applied to test data.

A random string rarely has an `@`. Two things make this work anyway:

- **The constructor's source is known.** The literals it compares with,
  `"@"` or the ends of `0..120`, become a dictionary for generating its
  arguments. Fuzzers learn these by watching comparisons at run time
  (AFL++'s CmpLog). Ren reads them before the test starts.
- **A refusal is typed.** `parse` failing with `Invalid` is a rejection,
  not a crash, so the search can lean toward arguments that get through,
  and the report says how often they did.

### 3. A type can write its own, as plain Ren

When the derived one isn't good enough, a type writes `arbitrary`, a
reserved member like `key` and `show`:

```ren
pub type Email = opaque Str
  pub fn parse(s: Str) -> Email ! Invalid = ...
  fn arbitrary() -> Email uses Random =
    Random.pick(["ann", "bo", "x.y"]) + "@" + Random.pick(["a.com", "b.org"])
```

- **It's ordinary code that `uses Random`.** No combinators: `if`, `for`,
  `match` and function calls are the language for generating, as for
  everything else.
- **It can be private,** as a `key` can: it still generates `Email`s in
  every module's tests, but nothing else can call it.
- **Other types' generators are in reach:** `User.arbitrary()`,
  `Array<Item>.arbitrary()`, derived or written.
- **Put the simplest choice first.** A failure shrinks toward the first
  option of a `pick`.

### 4. A test can shape its own data

Different tests want different data. A parameter can be given an
expression instead of a type, and a later parameter sees the earlier
ones:

```ren
test "withdrawing within the balance always works"
    (a: Account, m = Money.cents(Random.between(0, a.balance().in_cents()))) =
  var acc = a
  assert attempt &acc.debit(m, Withdrawal) is Ok(_)
```

Two forms, `name: Type` or `name = expression`, and generating one value
from another is only scope. Hypothesis needs `st.data()` for that, and
Hedgehog a `flatMap`. There's no `assume`: build what you want rather than
filtering for it.

### Shrinking replays the choices

Every random choice a generator makes goes through the `Random`
dependency, and the test implementation of `Random` records them. That
sequence of choices **is** the test's input; the values are what the
generators make of it. Shrinking makes the sequence smaller (shorter,
numbers toward 0, picks toward the first option) and runs the same
generators again.

- **Any generator shrinks,** derived or hand-written, with no shrinker to
  write. This is Hypothesis's idea, and in Ren it needs no library:
  `Random` is already a dependency a test controls.
- **A shrunk value is still valid.** It's rebuilt by the same
  constructors, so a shrunk `Email` is an `Email` its module would make.
- **A failure is saved as its sequence** and replayed first on every run
  until it passes. Keep it as a regression test with `ren test --keep`.

### What was tested

Ren knows the domain's sum types and every function's errors, so it can
say what the generated data actually exercised:

```
✓ a transfer never changes the total, 100 cases
    Plan:     Free 41 · Pro 38 · Team 21
    outcome:  ok 12 · Overdrawn 88
    ⚠ 88 of 100 cases ended in `Overdrawn`: generate amounts within the balance
    Email:    built by `arbitrary`
```

- **The outcome line catches the most common silent failure:** a property
  test that spends its cases on the error path.
- **So does a constructor that never came up,** and a constructor that
  refused most of what it was given: "`Email.parse` accepted 2% of its
  inputs. help: write `fn arbitrary`."

### Fuzzing is the same test, for longer

`ren fuzz bank --only "a transfer"` runs the same test with
coverage-guided mutation of its choice sequence, as Go's fuzzing does,
for as long as it's given. There's no second kind of test. What it finds
is saved and shrunk like any other failure.

## The journal is a test

Every effect goes through a dependency, and `ren run --record` writes the
journal of a run ([handlers.md](handlers.md#the-journal)). A journal
becomes a test one way: an ordinary test that installs `replay(file)`.

```ren
test "a recorded run of build replays" =
  with replay("tests/build.journal") in
    try main()
```

- **A replay answers inputs and compares outputs.** A call whose result
  the program uses, `Fs.read` or `Clock.now`, is answered from the
  journal, in order for each dependency; one that isn't the next of its
  dependency's, or that the journal has none left for, fails the test
  there. A call that gives nothing back, `Console.write` or `Fs.write`,
  is compared, and a difference fails the test with a diff of the
  outputs when the `with` ends:

  ```
  ──── a recorded run of build replays ── main.ren:86
     │
  86 │   with replay("tests/build.journal") in
     │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
     │
     the outputs differ from the recording's
     - Console.error("echo base")
     + Console.error("> echo base")
     ...
     help: if the change is what you meant, record the run again, or edit the journal
  ```

  `ren replay`, outside tests, is strict and stops at the first call
  that differs. The journal is found from the folder of the test's
  file. `replay(file)` implements only the built-ins the journal's
  header names, so the others are the test implementations, and a
  `with` can install them too. [examples/just](examples/just) has one,
  `tests/build.journal`.
- **A bug report is a file.** `ren run --record bug.journal` records the
  run that went wrong, and `ren test --keep bug.journal` moves it to
  `tests/` and writes the test for it, to read and edit like any other.
  Fix the bug, and it stays fixed: a test of a journal that ended in an
  error or a panic fails while the program still ends that way, and
  passes once it goes on past where the recording ended, the outputs it
  had made by then the same.

  ```
  $ ren test --keep bug.journal
  moved bug.journal to tests/bug.journal
  added the test "replays bug.journal" to main.ren
  run it with `ren test main.ren --only "replays bug.journal"`: it fails while the program ends as the recording did, and passes once it goes on past there, with the same outputs to there
  ```

## The console

`ren console` is Rails' console with what dependencies make possible. It's
where exploring happens, so tests don't have to:

```
$ ren console bank/account
account> var a = Account.open(AccountId.of(1))
account> a.balance                                     // private: fine here
Money(0) : Money
account> &a.freeze()
account> a
Account(id: AccountId(1), balance: Money(0), frozen: true, statement: []) : Account
account> :t Account.credit
fn(inout Account, Money, Movement) ! Frozen(AccountId) uses Clock
```

- **It opens inside a module.** Its private items, and its opaque types'
  representations, are in reach. That's the difference from a test. Its
  test items are in reach too, and a test that reaches past the
  interface doesn't keep it shut, since this is where that error sends
  you.
- **Every result shows its type,** and `:t` shows an expression's type
  without running it.
- **You choose the world.** It starts on test implementations: the clock
  stopped, the file system in memory, `Random` seeded. Real ones are
  named, `ren console bank --real Clock,Fs`, so the console is safe by
  default and never touches the world by surprise. Rails' console is
  powerful and dangerous for the same reason, the real database. Here
  it's a choice you can see. A real call is made once: what it gave is
  kept, and given back to its line from then on, so a `let t =
  Clock.now()` stays the same time and an earlier line's file isn't
  written again.
- **Every effect is shown as it happens:** a line given to the test
  `Console` as it would be printed, and any other call with what it
  gave, as the journal writes it, an opaque value as what it's
  represented as. A kept line's effects aren't shown again:

  ```
  account> Clock.now()
    Clock.now() → 0
  Time(0) : Time
  ```

- **`:reload` keeps your state.** It reads the module again after an
  edit and runs the session on it, the session's journal giving each
  real call back, to rebuild what you had. Rails' `reload!` loses it. A
  line that doesn't check any more, or makes other calls than it made,
  is dropped, with the lines after it, and said so:

  ```
  counter> :reload
  error: `Counter` has no method named `count`
    ┌─ <console>:2:3
  2 │ c.count()
    │   ^^^^^
    = the session goes on from line 2, which is dropped, and those after it
    help: its methods: `bump`, `total`
  ```

  Line `i` of the session is line `i` of `<console>` in a message.
- **`:spec` turns a session into a test.** It keeps each line a test of
  the module can write, and an `assert` for each result you looked at,
  writes them as a `test` in the module, and shows it to you to edit or
  delete. Whatever the session did through private items is left out:
  if a behaviour can only be reached that way, it isn't part of the
  interface, and `:spec` says so:

  ```
  counter> :spec counting
  added to counter.ren, to edit or delete:

  test "counting" =
    let c = Counter.start().bump()
    assert c.count() == 1
    = left out line 3, `secret()`: `secret` is private, and a test sees what an importer sees
  ```

  An `assert` is written only if it checks, and passes: a value shown
  that a test can't write, an opaque one's representation, is kept as
  `let _ = ` and the line, so what the line does stays in the test. The
  test is run as `ren test` runs it, on its own `Random` seed and the
  test implementations, so an `assert` that held only for the session
  is kept as its line too, and a line that fails or panics in a test is
  left out. A line that uses a variable of one left out is left out for
  that, and so is a `let` at the end. A name the module's tests have
  already is refused, and a session none of whose lines a test can
  keep adds nothing. `:spec` adds to the end of the file as the session
  read it: if it was edited since, it says to `:reload` first.
- **Later, read-only attaching to a running program** through its
  journal: what did this request do?

## The native backend is checked against the interpreter

The interpreter is the reference for what a program does, and every
binary `ren build` makes has to agree with it to the byte: what it
prints to stdout and to stderr, panics included, and how it exits.
[bench/build.t](bench/build.t) builds every program the native slice
compiles ([compiler.md](compiler.md#native-slice)), the benchmarks and
the examples in its subset, as a debug build with `--stats` and under
AddressSanitizer and UndefinedBehaviorSanitizer
(`REN_CFLAGS='-fsanitize=address,undefined'`), runs it and `ren run`,
and compares the two. The statistics say how many objects are still
alive when it ends, which has to be 0: a count that's never dropped is
a leak the sanitizers don't see. A program outside the subset is in it
too, to show the error that says so. It needs a C compiler, `cc` or
`$REN_CC`.

Under it, Mem Lint checks every program `ren build` lowers, and the
expect tests in test/test_native.ml print the Mem IR of a few programs
and the mistakes Lint catches, as Core Lint's tests do for Core.

## Later

- **Generated call sequences.** The compiler knows a module's interface,
  so `ren test` can call it in generated orders and check a property
  after each call, or compare it with a simple model. That's QuickCheck's
  state machine testing, derived from the interface rather than written
  by hand: a deep module, tested at its boundary, automatically.
- **Schedules in the same sequence.** The simulation scheduler's choices
  (the `sim` runtime, stage 11a) join the choice sequence, so a failing interleaving shrinks
  to the shortest schedule that still fails, and generated data and
  generated schedules shrink together.
- **Programs as properties.** Generate a world, files, clock jumps,
  network failures, run `main` under simulation, and check the journal.
- **Swarm testing:** each run leaves out some constructors and some
  operations entirely, which finds bugs that need a rare mix.

## Roadmap

Stage numbers match the [README roadmap](README.md#roadmap).

| Stage | What |
|---|---|
| **9c** | tests see what an importer sees; test items; a type that keeps rules is opaque ([module-build.md](module-build.md#private-unless-pub)); `ren console` with types, private items and the choice of world |
| **10** | the journal: effects shown in the console, `:reload`, `:spec`, journals as tests (done, stage 10b) |
| **native slice** | every binary `ren build` makes compared with `ren run`, under ASan and UBSan, with no object left alive (started, native step 2) |
| **11a** | `ren test --sim --seeds` on the `sim` runtime; journals as tests with a schedule prefix |
| **12** | property tests: derived generation, generation through constructors, `arbitrary`, shaped parameters, shrinking by replay, saved failures, the report, `ren fuzz`; schedules from 11a's `sim` in the choice sequence |
| **Later** | generated call sequences, programs as properties, swarm testing, attaching the console |

## Borrowed from

- **QuickCheck:** properties, and generating from types.
- **Hypothesis:** generating from a recorded choice sequence and shrinking
  that sequence; a database of failures replayed first.
- **Hedgehog and proptest:** shrinking that comes with the generator.
- **Rust's `arbitrary` crate and Go's fuzzing:** structured data from
  bytes, so fuzzing and property tests are one test.
- **AFL++ (CmpLog) and Redqueen:** learning the constants a parser
  compares with.
- **Swarm testing, and Tyche:** varying the mix; showing what was
  generated.
- **FoundationDB, TigerBeetle's VOPR and Antithesis:** deterministic
  simulation, where every failure replays.
- **Go's `package foo_test`:** tests written as clients.
- **Rails' console:** a live, loaded program to poke at.
- **John Ousterhout, *A Philosophy of Software Design*:** deep modules.

## Open questions

- **The cost of specifications for small files.** If writing tests for a
  small file becomes a chore of marking things `pub`, the rule is too
  strict. [examples/just](examples/just) was the one to watch, and in
  stage 9c it cost less than feared: `plan.ren`'s private recursive
  `visit` was already tested through `pub fn order`. The cost was
  elsewhere. Its tests call `main`, which became `pub` with its whole
  contract, nine errors and four dependencies in one signature, and
  `Justfile` keeps rules, so it became opaque, with a `recipes()` that
  reads. A help that writes out the whole `!` clause at once would make
  the first cheaper.
- **How `:spec` picks its asserts,** from the results looked at, without
  writing brittle ones. 10b writes one for every value shown that a test
  can write, which asserts more than a person would.
- **How a saved failure is named and kept** in the repository, so it
  survives renaming the test.

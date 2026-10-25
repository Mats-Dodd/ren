# A bank

Accounts, deposits and transfers, where any step can fail: not enough
money, a frozen account, an account that doesn't exist. A transfer changes
two accounts and must change both or neither. A batch of transfers must
happen whole or not at all. It's the milestone of stage 6: every way the
bank can say no is an error tag, and every call that can fail says so.
And of stage 7: every entry of a statement is stamped by the installed
`Clock`, and the modules carry their tests, which need no setup.

```
ren run bank/main.ren      # what it prints, line by line, is commented in main.ren
ren types bank/main.ren    # every module's interface
ren test bank              # every module's tests
```

| File | What's in it |
|---|---|
| `money.ren` | `Money`, opaque cents, with `Money.dollars(5)`, `a.plus(b)` and `a.covers(b)` |
| `account.ren` | `AccountId`, opaque; `Refusal`, the errors an account fails with; `Movement` and `Entry`, a line of a statement and its time; `Account`, with `credit` and `debit` |
| `bank.ren` | `Bank`: `open`, `deposit`, `transfer`, `batch`, `freeze`, and reading balances; `TransferError`; a test for each way it says no |
| `main.ren` | three customers, and every way a transfer can go; a test of what it prints |
| `clocks.ren` | `clock_conforms`, a group of tests any `Clock` should pass, run against `Clock.frozen` and `test_clock` |

## What to look at

**Signatures are exact.** `debit` fails with `! Refusal`, both of its
tags, but `credit` can't be short, so it writes `! Frozen(account:
AccountId)` alone, and `deposit`, which only credits, can't be short
either. A caller of `deposit` never has to handle `Short`. `Refusal` and
`TransferError` are names for sets of tags, declared with `!`, and
`TransferError` includes `Refusal`. `ren types` shows each function's set
written out.

**Passing an error on is one word.** `transfer` is a list of steps, each
of which can fail: `let i = try self.find(t.from)`, then
`try &draft.accounts[i].debit(...)`. There's no nested `match` and no
glue between `Refusal` and `TransferError`: tags are structural, so a
`Frozen` from `credit` is the same `Frozen` in `transfer`'s set. `find`
is private, so what it fails with is inferred; it turns its `Option`
into an error with `found orelse fail NoSuchAccount(id)`.

**A transaction is a copy.** `transfer` takes money out of one account and
puts it into the other, and the second step can fail after the first went
through. There's nothing to undo: both steps run on `var draft = self`,
and the bank becomes the draft, `self = draft`, only if neither failed.
When a call fails, what it changed stays changed, but here that's only the
draft, which is thrown away. `batch` uses the same three lines for any
number of transfers. In `main.ren`, `acme == before` after a failed batch
holds: nothing moved.

**Three ways to deal with an error.** `main` passes most of them on with
`try`, so `main` itself can fail, and `ren types` shows what with. It
keeps one with `attempt`, a `Result` it prints and gives to
`worth_retrying`. And it handles the frozen transfer with a `match` whose
`fail` arms cover every way `transfer` can fail. Adding a tag to
`TransferError` breaks both the `match` and `worth_retrying` until they
say what to do about it.

**Money isn't a number.** `Money` and `AccountId` are opaque, so outside
their modules `balance + 5` and `deposit(2, ...)` don't compile. Money is
made in a unit you can see, `Money.dollars(100)`, and changes only through
`plus` and `minus`.

**`&` shows what changes.** `&acme.transfer(...)` changes the bank, and
`acme.balance(alice)` doesn't. Inside, `&draft.accounts[i].debit(...)` changes
one account in place, inside one draft, inside one call.

**Statements are stamped with `Clock.now()`.** `credit` and `debit` read
the clock into each `Entry`'s `at`, so their signatures say `uses Clock`,
and so do `deposit`, `transfer` and `batch`, which call them. `main` uses
`Clock` and `Console`, and the runtime installs both. Everything else is
pure, and the compiler worked that out.

**Tests need no setup.** There's no `with` anywhere in the bank. Each
test gets the test `Clock`, stopped at `Time.epoch`, and moves it with
`TestClock.advance`, so "a deposit is stamped with the time" knows the
time exactly. The test of `main` calls it, and checks what it printed
with `TestConsole.output()`. A test for each refusal keeps it with
`attempt`, compares it with the error it expects, written by its tag,
`assert r == Err(Short(a, Money.dollars(1)))`, and checks the bank didn't
move: `assert acme == before`. When that fails, `ren test` shows the way
to the first place the banks differ and what each has there, with what
they share left out and a marker under the difference. Nothing in the
tests reads the real clock, so they print the same on every run.

**One suite for every clock.** `clocks.ren`'s `pub group
clock_conforms(c: Clock) with c` holds what a statement needs from any
clock, that it never goes back, and runs it twice: `group "frozen" =
clock_conforms(Clock.frozen(Time.epoch))` and `group "test clock" =
clock_conforms(test_clock(Time.epoch))`. Each test gets a fresh clock.

**The errors.** `examples.t` breaks the bank in eleven ways:

- adding an `Int` to `Money`
- passing an `Int` as an `AccountId`
- freezing without `&`
- a new way for a transfer to fail, that nobody handles
- a public function taking a private type
- a public function failing with what its signature doesn't say
- freezing without `try`
- a value thrown away
- a `fail` arm on a call that can't fail
- `main` failing: it prints `error: Frozen(AccountId(3))` and exits with status 1
- `credit` dropping `uses Clock`: the error points at `Clock.now()`

and `covers` checking only that the balance isn't negative, which the
compiler can't see: `ren test` catches it, in the overdraft and batch
tests and the test of `main`.

## What writing it ran into

Stage 6 fixed three of the things writing it ran into before:
~~a refusal dropped with `let _ =`~~ (a call that can fail is marked now,
and `try` passes the error on), ~~`Option<Refusal>`, where `None` meant it
worked~~, and ~~a nested `match` for "both accounts found"~~ (two lines
with `try`). What's left, and what stage 6 found:

- **Or-patterns are only for errors.** `fail A | fail B =>` works, but
  `Err(Short(_, _)) | Err(Frozen(_)) =>` doesn't parse, so
  `worth_retrying` has an arm for every tag.
- **No `()` pattern.** The value arm of `match &acme.transfer(...)` is
  `_ =>`, since the value is `()` and `()` can't be written as a pattern.
- **No `panic`.** The arms for errors that can't happen in that `match`
  print `-1`, where they should stop the program.
- **`ren types` writes named sets out.** `transfer` is declared
  `! TransferError`, and its interface lists the five tags instead. That's
  what the set means, but it's longer than what was written.
- **Long signatures.** `deposit` fails with three of `TransferError`'s
  tags, and writes all three. That's the cost of exact signatures.
- **Printing a tag showed an opaque payload.** `print(id)` in a `fail
  Frozen(id)` arm, and `error: Frozen(3)`, showed an `AccountId` as the
  `Int` inside it. Now they show it through its type, `AccountId(3)`.
- **A dropped value's error mentions opacity.** Throwing away a `Money`
  adds "`Money`'s representation is private to `money`", which has
  nothing to do with dropping it.
- **A variable can't share a module's name.** `var bank` clashes with
  `import bank`, which is right. But after reporting the clash, every
  later `bank.open()` is also reported, as a missing function of the
  module: six errors that say nothing new. The compiler should report the
  clash once, and then treat the name as the variable.
- **Strings are minimal.** There are literals, `==` and `show`, but no
  joining or formatting, so `main` prints cents and counts, not a statement.

What stage 7 found, writing the tests:

- **A bank was one long line.** A failed `assert acme == before`
  printed each bank on one line, hundreds of characters wide. Now it
  leaves out what the two share, `Bank { accounts: [Account { ...,
  balance: Money(-100), ... }, ...], ... }`, with the marker under the
  first difference.
- **Printing showed an opaque payload,** `"Err(Short(2, 45000))"`, where
  `ren test` showed `Money(-100)`. Now `print` shows a value through its
  type too, `"Err(Short(AccountId(2), Money(45000)))"`.

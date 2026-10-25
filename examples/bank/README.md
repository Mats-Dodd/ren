# A bank

Accounts, deposits and transfers, where any step can be refused: not
enough money, a frozen account, an account that doesn't exist. A transfer
changes two accounts and must change both or neither. A batch of transfers
must happen whole or not at all.

```
ren run bank/main.ren      # what it prints, line by line, is commented in main.ren
ren types bank/main.ren    # every module's interface
```

| File | What's in it |
|---|---|
| `money.ren` | `Money`, opaque cents, with `Money.dollars(5)`, `a.plus(b)` and `a.covers(b)` |
| `account.ren` | `AccountId`, opaque; `Refusal`, why the bank said no; `Account`, with `credit` and `debit` |
| `bank.ren` | `Bank`: `open`, `deposit`, `transfer`, `batch`, `freeze`, and reading balances |
| `main.ren` | three customers, and every way a transfer can go |

## What to look at

**A transaction is a copy.** `Bank.transfer` takes money out of one
account and puts it into the other, and the second step can be refused
after the first went through. There's nothing to undo, because both steps
ran on `var draft = self`, and the bank becomes the draft, `self = draft`,
only if neither was refused. `batch` uses the same three lines for any
number of transfers. In `main.ren`, `acme == before` after a refused batch
holds: nothing moved.

**Money isn't a number.** `Money` and `AccountId` are opaque, so outside
their modules `balance + 5` and `deposit(2, ...)` don't compile. Money is
made in a unit you can see, `Money.dollars(100)`, and changes only through
`plus` and `minus`.

**Refusals are values, and every function that can refuse says so.**
`deposit`, `transfer`, `batch` and `freeze` return `Option<Refusal>`, and
`ren types` shows it. A new kind of refusal, such as a closed account,
doesn't compile until `Refusal.worth_retrying` handles it.

**`&` shows what changes.** `&acme.transfer(...)` changes the bank, and
`acme.balance(alice)` doesn't. Inside, `&draft.accounts[i].debit(...)` changes
one account in place, inside one draft, inside one call.

**Only `main` uses `Io`.** Everything else is pure, and the compiler
worked that out.

**The errors.** `examples.t` breaks the bank in five ways:

- adding an `Int` to `Money`
- passing an `Int` as an `AccountId`
- freezing without `&`
- a new refusal nobody handles
- a public function taking a private type

## What writing it ran into

- **A refusal can be dropped without a word.** `&acme.deposit(...)` returns
  an `Option<Refusal>`, and as a statement its value is thrown away. That's
  the strongest case so far for stage 6: a function that can fail should
  have to be marked with `try` at the call, so a failure can't be ignored.
- **`Option<Refusal>` is backwards.** `None` means it worked. A `Result`,
  or stage 6's `! Refusal`, would say what it means.
- **Nested `match` for "both found".** `transfer` matches on
  `find(from)`, then inside that on `find(to)`. Stage 6's `try` would make
  that two flat lines.
- **A variable can't share a module's name.** `var bank` clashes with
  `import bank`, which is right. But after reporting the clash, every
  later `bank.open()` is also reported, as a missing function of the
  module: six errors that say nothing new. The compiler should report the
  clash once, and then treat the name as the variable.
- **No `&&` or `||`.** As in the VM: chains of `else if` instead.
- **No strings.** A statement can't be printed as text, so `main` prints
  cents and counts.

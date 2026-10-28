# Ledger

Money moved between two accounts inside a transaction, against a
database kept in memory. A transfer that would leave an account short
fails, and its transaction rolls back what it already did. It was
written for stage 10a to try `over`, `next`, `finally` and a handler
whose state can fail to start, and since stage 10c it shows a block
that changes a variable outside it.

```
ren run ledger/main.ren    # what it prints is commented in main.ren
ren test ledger            # every module's tests
```

| File | What's in it |
|---|---|
| `sql.ren` | `Sql`, a dependency with `get`, `set`, `begin`, `commit` and `rollback`; `Outage`, when the database is down, `AtFirstBegin` only the first time; `mem_sql`, a handler for `Sql` that keeps balances in a `Map`, and those when the last transaction began; `transaction`, a handler over `Sql` |
| `main.ren` | `transfer`, which credits one account and then debits the other inside a transaction; `main`; tests of a commit, a rollback, a failed commit, a transfer retried, and a transaction that can't begin |

## What to look at

**A transaction is a handler over `Sql`.** `transaction() over Sql !
DbDown` begins in its state, `let tx = try next.begin()`, and leaves
`get` and `set` out, so they reach the `Sql` under it. Its `finally` is
given the body's result: on `Ok(v)` it commits and gives back `v`, and
on `Err(_)` it rolls back and fails with the body's error, `try r`.

**Installing it can fail.** `! DbDown` says the handler's state or its
`finally` can fail, so the `with` that installs it can too. A `finally`
covers what comes after the line it's written on, and this one is
written after `let tx`, so when `begin` fails, the body never runs and
`finally` isn't called. One written above it would run then too, given
`begin`'s error (stage 10c).

**`try with sql.transaction() over Sql`** puts the transaction over the
`Sql` installed outside the `with`: `transfer` doesn't say which
database, only that it uses one. Installing it can fail, so the `with`
is marked with `try`, as a call that can fail is; the `try` covers only
the installation, and each call in the body has its own.

**Its errors are the body's and the transaction's.** `transfer` fails
with `Short` from its body and `DbDown` from the `Sql` calls, the start
and the commit, and says so: `! DbDown | Short(name: Str)`.

**A block counts the tries.** The prelude's `retry` runs a block again
while it fails with one of the errors it's given `on:`, and the test of
it passes one that changes `tries`, a `var` outside it:

```ren
var tries = 0
try retry(3, on: DbDown) fn() =>
  tries += 1
  try transfer("ann", "bob", 30)
assert tries == 2
```

A block captures by reference, so `tries` is 2 after the call: the
first transaction couldn't begin, and the second went through.
Exclusivity keeps that sound: nothing else uses `tries` while `retry`
runs the block (foundations.md, decision 2).

## What it ran into

- **`finally` can't compare the body's value.** It's given a result of
  any type, so it can pass it on or show it, never `==` it. A
  transaction never needs to.
- **`retry` used to name the errors it could see.** A block parameter's
  errors pass through it untouched, so to tell `DbDown` apart, the
  ledger's own `retry` wrote out what its block failed with. The
  prelude's `retry(n, on: DbDown)` works for any block: `on:` names what
  it tries again, and every other error leaves at once (handlers.md,
  "Functions that run a block").
- **A helper the tests call is `pub`.** A test sees what an importer
  sees, so `transfer`, `balances` and `start` are part of `main`'s
  interface.

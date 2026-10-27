# Ledger

Money moved between two accounts inside a transaction, against a
database kept in memory. A transfer that would leave an account short
fails, and its transaction rolls back what it already did. It was
written for stage 10a to try `over`, `next`, `finally` and a handler
whose state can fail to start.

```
ren run ledger/main.ren    # what it prints is commented in main.ren
ren test ledger            # every module's tests
```

| File | What's in it |
|---|---|
| `sql.ren` | `Sql`, a dependency with `get`, `set`, `begin`, `commit` and `rollback`; `Outage`, when the database is down; `mem_sql`, a handler for `Sql` that keeps balances in a `Map`, and those when the last transaction began; `transaction`, a handler over `Sql` |
| `main.ren` | `transfer`, which credits one account and then debits the other inside a transaction; `main`; tests of a commit, a rollback, a failed commit and a transaction that can't begin |

## What to look at

**A transaction is a handler over `Sql`.** `transaction() over Sql !
DbDown` begins in its state, `let tx = try next.begin()`, and leaves
`get` and `set` out, so they reach the `Sql` under it. Its `finally` is
given the body's result: on `Ok(v)` it commits and gives back `v`, and
on `Err(_)` it rolls back and fails with the body's error, `try r`.

**Installing it can fail.** `! DbDown` says the handler's state or its
`finally` can fail, so the `with` that installs it can too. When `begin`
fails, the body never runs and `finally` isn't called.

**`with sql.transaction() over Sql`** puts the transaction over the `Sql`
installed outside the `with`: `transfer` doesn't say which database, only
that it uses one.

**Its errors are the body's and the transaction's.** `transfer` fails
with `Short` from its body and `DbDown` from the `Sql` calls, the start
and the commit, and says so: `! DbDown | Short(name: Str)`.

## What it ran into

- **`finally` can't compare the body's value.** It's given a result of
  any type, so it can pass it on or show it, never `==` it. A
  transaction never needs to.
- **A helper the tests call is `pub`.** A test sees what an importer
  sees, so `transfer`, `balances` and `start` are part of `main`'s
  interface.

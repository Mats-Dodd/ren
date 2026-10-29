# 07. Stream database rows inside a transaction

The job: export one customer's orders from a consistent snapshot to a
CSV file, and mark each exported row in the same transaction, so a crash
halfway leaves nothing marked. Then the reusable version a library
wants: "the orders of a customer, read in one transaction", as a stream
other code consumes. The draft forbids `yield` inside a `with`, which is
what that library version would naturally write.

## Ren, per the draft

### A. The consumer owns the transaction (allowed, and good)

```ren
fn export(c: CustomerId, out: Path) ! DbDown | Conflict | FsError | BadRow
    uses Sql, Fs =
  var w = try Fs.create(out)
  finally w.close()
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try &Sql.rows("select * from orders where customer = $1", c)
      let o = try Order.from_row(row)
      try w.write_line(o.csv())
      try Sql.exec("update orders set exported = now() where id = $1", o.id)
```

9 lines. Every `Sql` call in the body, the cursor's `next` included,
reaches the transaction, because the body is lexically inside the `with`.
A failure anywhere rolls back in the handler's `finally`; a cancel too,
shielded.

### B. The library version, as the draft wants it written: refused

```ren
gen fn orders_in_tx(c: CustomerId) -> Order uses Sql ! DbDown | Conflict | BadRow =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try &Sql.rows(q, c)
      yield try Order.from_row(row)
//    ^^^^^ error: `yield` inside a `with`
```

### C. What the library can write instead

**C1. A function that owns the loop and takes a block.** The block's
parameter type lists `uses Sql`, so by decision 5 the callee provides
it: the body's own `Sql` calls go to the transaction. That's explicit,
and better than the other languages below.

```ren
type Flow = | Go | Stop

pub fn each_order(c: CustomerId, body: fn(o: Order) -> Flow uses Sql)
    ! DbDown | Conflict | BadRow uses Sql =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try &Sql.rows(q, c)
      match body(try Order.from_row(row))
        Go => ()
        Stop => break

// caller
try orders.each_order(c) fn(o) =>
  try w.write_line(o.csv())                 // ! FsError flows out through the block
  try Sql.exec("update orders set exported = now() where id = $1", o.id)
  Go
```

No `for`, no `break` in the caller (a block can't `break` the loop it's
passed to), and every body ends in `Go`. The block's errors flow into
`each_order`'s call as the draft says they do, but `each_order`'s
signature then has to be polymorphic in them; the draft and
language.md don't show how a block parameter's error row is written
when it's open (`! E`?).

**C2. `Async.produce`, the transaction on its own task.**

```ren
Async.produce(cap: 64, fn(out) =>
    try with sql.transaction(isolation: RepeatableRead) over Sql in
      for row in try &Sql.rows(q, c) => out.send(try Order.from_row(row))
  ) fn(orders) =>
  for o in try &orders
    try w.write_line(o.csv())
    try Sql.exec(mark, o.id)                // NOT in the transaction: a second connection
```

Compiles, and is wrong for this job: the consumer's `Sql` is the pool,
so the marks commit independently of the read. Worse, with `select ...
for update` in the producer, the consumer's `update` on a second
connection waits for the producer's row lock while the producer waits
on `out.send` with `cap` full: a deadlock through the database that the
runtime can't see. And a task plus a channel for what is
one loop.

**C3. Eager:** read every row inside the transaction into an `Array`,
commit, return the array. Fine for small results, defeats streaming.

### D. What the draft accidentally allows

```ren
let rows = try with sql.transaction() over Sql in Sql.rows(q, c)   // returns the cursor
for row in try &rows                                                 // next runs here
  ...
```

The `with` body's value is a cursor, data (an id on the database's
service, per "Cursors over resources"), so it may leave the `with`.
After the commit its `next` runs with the *consumer's* `Sql`, the pool,
carrying an id the transaction's connection issued. At best a run-time
"no such cursor"; at worst, with a pool that reuses portal names, rows
from someone else's query. Nothing in the draft rejects it.

## Counterparts

**C#, Npgsql, `IAsyncEnumerable`** (yield inside `using` is allowed;
`break` disposes, which rolls back an uncommitted transaction):

```csharp
async IAsyncEnumerable<Order> OrdersInTx(long c,
    [EnumeratorCancellation] CancellationToken ct = default)
{
    await using var conn = await ds.OpenConnectionAsync(ct);
    await using var tx = await conn.BeginTransactionAsync(IsolationLevel.RepeatableRead, ct);
    await using var cmd = new NpgsqlCommand("select * from orders where customer = $1", conn, tx)
        { Parameters = { new() { Value = c } } };
    await using var rd = await cmd.ExecuteReaderAsync(ct);
    while (await rd.ReadAsync(ct)) yield return Order.From(rd);
    await tx.CommitAsync(ct);
}
```

10 lines, reusable, `await foreach` + `break` works. But the consumer
can't write in that transaction: `conn` and `tx` are private to the
iterator, exactly as in Ren's C2, and Npgsql forbids a second command on
a connection with an open reader anyway.

**Kotlin, Spring R2DBC:** `fun ordersInTx(c: Long): Flow<Order> =
client.sql(q).bind(0, c).map(Order::from).all().asFlow().transactional(txOperator)`
(spring-tx's `Flow<T>.transactional(TransactionalOperator)`). One line,
and emission inside the transaction is ordinary. Writes from the
collector join the transaction only because Spring carries it in the
Reactor context, which is the "found behind your back" mechanism Ren
rejects.

**Go 1.23, `iter.Seq2`:**

```go
func OrdersInTx(ctx context.Context, db *sql.DB, c int64) iter.Seq2[Order, error] {
    return func(yield func(Order, error) bool) {
        tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
        if err != nil { yield(Order{}, err); return }
        defer tx.Rollback()
        rows, err := tx.QueryContext(ctx, q, c)
        if err != nil { yield(Order{}, err); return }
        defer rows.Close()
        for rows.Next() {
            o, err := scanOrder(rows)
            if !yield(o, err) { return }       // break: Rollback via defer
        }
        if err := tx.Commit(); err != nil { yield(Order{}, err) }
    }
}
```

14 lines, `for o, err := range OrdersInTx(...)` with `break`. This is the
push model the draft's "pushed when it can be" compiles to. **In Go
this is legal precisely because the loop body runs inside the
producer's call**, so the transaction is open exactly while the body
runs, with no suspended frame to escape.

## Comparison

- **Version A** is the best of all five: 9 lines, the transaction's
  extent is the indentation, and every call inside it is in it. No other
  language makes "the consumer's writes are in the producer's
  transaction" this obvious.
- **The reusable version** is where Ren is worst. C# and Go write it in
  10 to 14 lines with `for`/`break` at the use site. Ren's legal options
  are a block-taking function without `for` sugar (C1), a task (C2,
  wrong semantics here), or eager (C3). The draft's own table says
  `gen fn` replaces "a producer that owns the loop, `Fs.each_line(path)
  fn(line) => ...`, which has no `for` sugar", but for exactly the
  producers that own a resource scope, C1 is still the only way.

## What the draft forbids or leaves unclear

1. **The ban on `yield` inside `with` is broader than its reason.** The
   reason given is PEP 789: a suspended generator leaving a *cancel
   scope* open in its consumer. A handler `with` isn't a cancel scope;
   the real reason it can't sit in a *stored* cursor is the bet: the
   cursor would hold a live handler instance ("the programmer never
   holds an instance"). That reason vanishes if such a generator is
   never stored. And the draft already has the tool: **"a value that
   holds a block is a block."** A generator that yields inside a `with`
   holds an instance; make it a block-kind value. It can be a `for`'s
   source (compiled push, as Go does, which is what "pushed when it can
   be" already does), bound with `let`, passed down; it can't be stored,
   returned or given to a task. Then B compiles, the use site writes
   `for o in try &orders_in_tx(c)` with `break`, and nothing new is
   needed. The cancel-scope wrappers (`Async.timeout`, `scope`, `race`,
   `beside`, `retry`) can stay banned.
2. **What a generator's `finally(r)` (and an enclosing handler's
   `finally`) sees on `break` or drop is unspecified.** A transaction
   commits on `Ok` and rolls back on `Err`. A consumer that `break`s
   after 10 of 1,000 orders: commit or rollback? C# and Go roll back
   (dispose without commit; `defer tx.Rollback()`). Ren should say:
   abandoning a generator unwinds it as a cancel, `Err(Cancelled)`, so a
   transaction rolls back. Today the draft only says *that* `finally`
   runs.
3. **A cursor leaving the `with` that serves its `next` (D)** needs the
   rule decision 7 already has for tasks: "A task can't reach a handler
   installed inside the scope it's spawned into." The cursor equivalent:
   a value whose `next` uses `D` can't be the result of a `with` that
   installs `D`. That needs the cursor's type to carry its `next`'s
   `uses`, which the draft implies ("a cursor's `uses` is its `next`'s")
   but never makes part of the type.
4. **Errors of a block parameter in C1.** `fn(o: Order) -> Flow uses
   Sql` with the block's own `! FsError` flowing out: the draft says
   errors flow into the call as for any block, but a `pub` function must
   write exact signatures, and there's no shown syntax for "whatever the
   block fails with".

## Soundness doubts

- **D is a hole**, not a style problem: an id issued by one handler
  instance used against another.
- **The general form of D is dependency rebinding across `next`.** A
  `gen fn` cursor's `next` resolves its `uses` from whoever calls `next`,
  every time. A generator that called `Fs.open` under `with mem_fs()` in
  one place and is pulled under the real `Fs` in another mixes
  instances. Decision 5 chose "found where written" for blocks to stop
  exactly this; generators are the one suspended code whose dependencies
  are found where they're *resumed*. Kotlin bans the analogous thing at
  run time ("Flow invariant is violated"); the draft cites that as
  "checked statically", but only the task half of it is.

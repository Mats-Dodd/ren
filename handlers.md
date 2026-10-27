# Handlers that wrap, and the journal

How one implementation sits in front of another, what runs when a `with`
ends, and how every call a program makes to the world is recorded,
replayed and traced. It's stage 10 of the [roadmap](README.md#roadmap),
after operators. It builds on [deps.md](deps.md), and changes one of its
rules: a `with` installs a set, and its order never matters.

It's built in two halves:

- **10a, handlers:** `with` as a set, `over` and `next`, `finally`, and
  handler state that can fail to start. It's checking and lowering, with
  no new runtime format.
- **10b, the journal:** recording, replaying, tracing, journals as tests,
  and the console's `:reload` and `:spec` ([testing.md](testing.md#the-console)).
  It needs 10a: recording is a handler `over` each real implementation.

The README's earlier sketch used `outer` and `for Users forwards`. This
design replaces both with one word, `over`, because the wrapping should
be visible in the code, not hidden in where a comma falls.

## What it has to do

1. **What wraps what is written, not implied by order.** Swapping two
   wrappers changes the words, never a comma.
2. **A `with` means the same thing whatever order its items are in.**
3. **Cleanup that can fail is handled where it's written.** No silently
   lost errors (Go's `defer f.Close()`) and no hidden suppression rule
   (Java's suppressed exceptions).
4. **Every call to the world can be recorded and replayed exactly,** and a
   replay that goes differently says where and how.
5. **None of it breaks the no-cycles invariants** ([compiler.md](compiler.md)):
   the wrapped implementation is reached by a call, never held as a value.

## A `with` is a set

```ren
with Clock.frozen(t), mem_users([ann]), mem_rates(1) in
  body
```

- **Each dependency appears at most once in a `with`,** and the order of
  its items never matters.
- **An item's needs are met by the other items in the same `with` first,**
  then by what's installed outside it. The compiler works out the order
  to install them in. Two items that each need the other are an error.
- **A handler of several dependencies counts as each of them.** `with h`
  where `h: Clock & TestClock` installs both, so `with h, test_clock(t)`
  installs `Clock` twice.
- **Installing a dependency twice is an error,** because the second would
  silently hide the first:

```
error: this `with` installs `Users` twice
  ┌─ main.ren:3:8
  │
3 │   with mem_users([ann]), postgres_users(pool) in
  │        ---------------   ^^^^^^^^^^^^^^^^^^^ and again here
  │
  = a `with` installs each dependency once, so its order never matters
  = help: to put one in front of another, use a handler declared `over Users`
```

A `with` nested inside another can still install a dependency the outer
one did. The inner one is in effect inside it, as now. That's shadowing
you can see, one level of indentation in.

## `over`: one implementation in front of another

A handler that sits in front of another implementation of the same
dependency is declared `over` it:

```ren
pub handler cached(ttl: Duration) over Users uses Clock =
  var cache: Map<UserId, (User, Time)> = Map.empty
  get(id) =>
    match cache.get(id)
      Some((u, at)) if Clock.now() - at < ttl => Some(u)
      _ =>
        let found = try next.get(id)
        if found is Some(u) then &cache.set(id, (u, Clock.now()))
        found
  save(u) =>
    try next.save(u)
    &cache.remove(u.id)
```

`over Users` says four things:

- It implements `Users`.
- It must be installed over another `Users`.
- **It may leave operations out.** Those go to the one under it. Here,
  `list` and `delete` do.
- It calls the one under it through **`next`**: `next.get(id)`.

A handler declared `for Users`, not `over`, still implements every
operation, and has no `next`:

```
error: `fake_users` doesn't implement `list` or `delete`
  ┌─ test.ren:3:9
  │
3 │ handler fake_users() for Users =
  │         ^^^^^^^^^^
  │
  = a handler implements every operation, unless it goes `over` another implementation, which then does the rest
  = help: write them, or declare it `over Users` if another `Users` should handle them
```

### `next`

- **`next` is the implementation this one is over,** while an operation
  runs. It's what Express, Koa, Tower and ASP.NET call passing a request
  on, so most people already know it.
- **It can only be called through,** never kept, passed or returned. That
  keeps the third no-cycles invariant: an installed instance is never a
  value.

```
error: `next` can only be called through
  ┌─ users.ren:9:16
  │
9 │     let below = next
  │                 ^^^^
  │
  = `next` is the implementation under this one while an operation runs, and it can't be kept
  = help: call it where it's needed: `next.get(id)`
```

- **A handler `over A & B`** writes `next.get` when only one of the two
  has a `get`, and `next(A).get` when both do. `A & B` is written as a
  handler of several dependencies' type is ([deps.md](deps.md)).
- **Inside an `over Users` handler, `Users.get` is still an error,** with
  help that says `next.get`. Reading it would suggest a call to itself.

### Installing one

```ren
with cached(ttl) over counted() over postgres_users(pool) in
  serve(requests)
```

It reads as it nests: `cached` is over `counted`, which is over
`postgres_users`. A wrapping handler is always installed with `over`:

```
error: `cached` goes over a `Users`, so it's installed with `over`
  ┌─ main.ren:4:8
  │
4 │   with cached(ttl) in
  │        ^^^^^^^^^^^
  │
  = help: say what it goes over: `cached(ttl) over postgres_users(pool)`, or `over Users` for the one installed outside this `with`
```

**`over` and the dependency's name** wraps whatever is installed outside
the `with`, including the world, which a program can't name:

```ren
with slow_clock(2) over Clock in
  run()
```

An `over` chain installs one dependency, so it counts once in its
`with`'s set. A chain is one item, so an item that needs `Users` beside it
in the same `with` gets the top of the chain:

```ren
with Clock.frozen(t), cached(ttl) over mem_users([ann]) in
  // cached's Clock is the frozen one: it's in the same with
```

### Wrappers

A wrapper, a function whose last parameter is the body (`retry(3)`), wraps
the body, so it goes inside everything its `with` installs. Two wrappers
in one `with` say which wraps which with `over`, as handlers do:

```ren
with Clock.frozen(t), retry(3) over timeout(Duration.seconds(5)) in
  try fetch()
```

`retry` is outside `timeout`, so each try gets five seconds. Two wrappers
listed with a comma are an error, whose help writes them with `over`.

## When a `with` ends: `finally`

A handler can run code when the `with` that installed it ends. It's given
the body's result, and returns the `with`'s:

```ren
pub handler transaction() over Sql =
  var tx = try next.begin()
  query(q) => try tx.query(q)
  finally(r) =>
    match r
      Ok(v) =>
        try tx.commit()
        v
      fail e =>
        tx.rollback()
        fail e

fn transfer(t: Transfer) ! DbDown | Short uses Sql =
  with transaction() over Sql in
    try debit(t.from, t.amount)
    try credit(t.to, t.amount)
```

- **`r` is the body's result,** matched with stage 6's `fail` arms. What
  `finally` produces is what the `with` produces.
- **When both the body and the cleanup fail, the handler's author says
  what happens.** Here a failed body rolls back and passes its own error
  on, and a failed commit fails the `with` with the commit's error.
  There's no rule hidden in the language.
- **The `with`'s errors are the body's, plus `finally`'s,** checked like
  any other.
- `finally` runs once, whether the body finished or failed. A panic isn't
  an error, so `finally` doesn't see it: a panic ends the program.

A handler is already what a type that keeps rules has to be
([module-build.md](module-build.md#private-unless-pub)): its state can't
be reached from outside, only through its operations, so the rule needs
nothing more here.

### State that can fail to start

A handler's state can now call a dependency that fails: `var tx = try
next.begin()`. A `with` that installs it fails with those errors too. A
`with` already acts as the `try` of a wrapper it installs ([deps.md,
Deviations](deps.md#deviations)), and this is the same rule: the `with`
passes on what installing its items can fail with.

## The journal

The journal is the record of the calls a program makes to the world: the
real `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, and later `Net`.

### Recording and replaying

```
$ ren run --record run.journal just/main.ren -- build
fmt a.c
cc a.c
recorded 14 calls to run.journal (Fs 1, Os 1, Proc 3, Console 9)

$ ren replay run.journal
fmt a.c
cc a.c
replayed 14 calls: nothing touched the disk, and nothing ran
```

- **Recording is a handler over an implementation,** which calls `next`
  and writes down the call and what it gave back. `ren run --record`
  has the runtime install it outermost, over each real implementation:
  `recorder over Fs`, `over Clock`, and the rest. Only the runtime can
  put it over the world. It works over any implementation, though, so
  the test `Random`'s choices that property tests shrink
  ([testing.md](testing.md#shrinking-replays-the-choices)) and the
  console's session are journals in the same format.
- **A panic is recorded too.** The journal is written as the program
  runs, and a panic is its last entry, so a replay checks that the same
  panic happens at the same call. A bug report is usually a panic, and
  this is what makes it a file you can replay.
- **Recording says what it holds:** `ren run --record` warns that the
  journal has everything the program read, files and arguments included.
  `secret` types will redact what they mark ([Later](#later)), and until
  then the warning is the honest answer.
- **Replaying is a handler for each,** answering every call with what was
  recorded, in order. Pure code is deterministic, so a program given the
  same answers makes the same calls.
- That's enough for exact replay. What happens inside the program, between
  calls to the world, replays by itself. It needs one thing to be true:
  **nothing reaches the world except through a dependency.** Every
  intrinsic the prelude marks as reaching the world is an operation of
  `Clock`, `Random`, `Console`, `Fs`, `Os` or `Proc`, and so is recorded:
  arguments, the environment and the working directory included, and the
  exit code is the journal's last entry.

### A replay that goes differently

```
$ ren replay run.journal
error: the replay went differently at call 3 of 14
   ┌─ just/main.ren:24:16
   │
24 │     let code = try Proc.run("sh", ["-c", line])
   │                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   │
   = the recording has: Console.error("fmt a.c")
   = this program made: Proc.run("sh", ["-c", "fmt a.c"])
   = help: the code changed since this was recorded; record it again
```

A call differs if its dependency, its operation or its arguments differ.
`ren replay` is strict: it stops at the first one, says what the
recording expected, and points at the call that was made instead. That's
what replaying byte for byte means ([vision.md](vision.md)). Temporal's
workflows taught this: a replay that silently goes wrong is worse than one
that stops.

### A journal as a test fixture

```ren
test "the just runs a real justfile" =
  with replay("tests/build.journal") in
    try main()
```

Record a real run once, check the journal in, and the test needs no disk,
no processes and no network again. Ruby's VCR does this for HTTP. In Ren
it works for every dependency, with nothing to set up. `replay(file)` is
an implementation of every built-in dependency the journal holds calls
for, and **it's the one way a journal becomes a test.**

- **In a test, a replay answers inputs and compares outputs.** A call
  whose result the program uses, `Fs.read`, `Clock.now`, `Proc.run`, is
  answered from the journal, in order for each dependency. A call that
  gives back nothing, `Console.print`, `Fs.write`, is compared: the test
  fails if the outputs differ, and shows them as a diff, not as the first
  call that differs. So adding a log line fails with what changed, rather
  than breaking every journal at a call.
- **A bug report becomes a test with one command.** `ren run --record
  bug.journal` records the run that went wrong, and `ren test --keep
  bug.journal` moves it to `tests/` and writes the test above for it, an
  ordinary test to read and edit. Fix the bug, and it stays fixed.

### Tracing

```
$ ren run --trace just/main.ren -- build
main                                   41ms
├─ Fs.read("justfile")                  0.2ms  → 61 bytes
├─ Os.args()                            0.0ms  → ["build"]
├─ Proc.run("sh", ["-c", "fmt a.c"])   18ms   → 0
└─ Proc.run("sh", ["-c", "cc a.c"])    22ms   → 0
```

`--trace` records the same calls at a lower level: what was called, its
arguments and how long it took. `--trace` also shows calls to the
program's own dependencies, nested under the call that made them, since a
trace is for reading, and replay doesn't need them.

| Level | Records | Use |
|---|---|---|
| 0 | nothing | compiled out |
| 1 | what was called, and how long it took | `--trace` without arguments |
| 2 | + arguments | `--trace` |
| 3 | + results | `--record`: exact replay |

### What an entry holds

```
# ren journal 1 · just/main.ren · deps: Fs Os Proc Console
1  Os.args()                         → ["build"]
2  Fs.read("justfile")               → Ok(61 bytes: "build:\n\tfmt a.c\n...")
3  Proc.run("sh", ["-c", "fmt a.c"]) → Ok(0)
4  Console.error("fmt a.c")
```

**A journal is text,** one call a line, because journals are checked in
as tests and read in review: a changed journal shows what changed, and a
bug report can be read before it's run. A compact binary form can come
with the flight recorder, where size matters. The format is to be
revisited once real journals exist. The shape is `runtime-io.md`'s, a
submission and its completion:

- **`task` and `seq`** say who made the call and in what order. There's
  one task until `Async`, but the field is there from the start, so the
  format doesn't change when concurrency arrives.
- **Names, not positions.** A journal starts with a table of the
  dependencies, operations, types and field names it uses, and its
  entries refer to that table. A journal recorded on one build can be
  replayed against another as long as the names still match. That's what
  replaying production traffic against a new build will need.
- **Values are written by the compiler's structural walk,** the same one
  derived `==` and `show` use ([operators.md](operators.md#how-it-runs)).
  It stays internal: the journal's format is the runtime's, not a
  serialization API.
- **Redaction is a value from the start.** `secret Str` doesn't exist yet,
  but when it does, it's recorded as `<redacted>`. The format has room for
  that now, so it never has to change for it.
- **Large values have a limit.** Past a size cap, an entry keeps only a
  value's length, and a replay that needs it says so. A journal has a byte
  budget, set when it's recorded.

## How it runs

- **`next` is a lookup Ren already does.** A handler captures the evidence
  vector from where it's installed. With `over`, the implementation it's
  over is installed just outside it, so `next` is that implementation in
  the captured vector.
- **Leaving operations out** compiles to forwarding them, with no code to
  write. It's a direct call, so it costs what writing it out would.
- **`finally`** lowers to the `Finally` Core already has for `with` ([compiler.md](compiler.md)).
- **The recorder is the one privileged handler,** as the README says: only
  the runtime can install it over the real implementations. A program
  can't name them, so it can't wrap them any other way than `over Clock`.

## What changes in deps.md and the README

- **A `with` is a set.** "Items are installed outermost first; the
  innermost implementation wins" becomes: each dependency once, in any
  order, and wrapping is written with `over`.
- **`outer` and `forwards` go.** `over` and `next` replace them, in the
  README's section 7 too.
- **"A handler's state can't fail"** (a deviation in deps.md) goes. A
  `with` passes on what setting up its handlers fails with.
- **"Reaching the next implementation out is `outer`'s"** in deps.md's
  Deviations becomes `next`'s, through `over`.

## Done when

**10a:**

- The prices example's cache is `cached(ttl) over Prices`, wrapping a real
  `Prices`, and the made-up `Supplier` is gone.
- A `transaction() over Sql` handler commits or rolls back in `finally`,
  tested against an in-memory `Sql`.
- A `with` is a set: installing a dependency twice, a handler of several
  included, is the error above.

**10b:**

- `ren run --record` and `ren replay` reproduce the `just` exactly,
  without touching the disk or running anything. Changing a line of it
  makes the replay stop with the error above.
- A run that panics replays to the same panic at the same call.
- A test of the `just` runs from a checked-in journal, and `ren test
  --keep` turns a recorded journal into such a test.
- Every intrinsic that reaches the world is an operation of a recorded
  dependency.
- `ren run --trace` prints the call tree.
- The console's `:reload` and `:spec` work, on the session's journal.

## Later

- **Recording what the scheduler decides,** with `Async`, so a concurrent
  program replays exactly too.
- **The flight recorder** (stage 17): keeping a journal in a ring buffer,
  and deciding at the end of a request whether to keep it.
- **Replaying production traffic against a new build,** and comparing the
  responses.
- **`secret` types,** recorded as `<redacted>`.
- **`arena`, with `Alloc`** (stage 15): a handler whose `finally` frees
  everything it allocated.

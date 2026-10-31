# Handlers that wrap, and the journal

How one implementation sits in front of another, what runs when a `with`
ends, and how every call a program makes to the world is recorded,
replayed and traced. It's stage 10 of the [roadmap](README.md#roadmap),
after operators. It builds on [deps.md](deps.md), and changes one of its
rules: a `with` installs a set, and its order never matters.

**Status:** built. 10a and 10b run, as
[Where 10a differed](#where-10a-differed) and
[Where 10b differed](#where-10b-differed) say. Stage 10c took wrappers
out of `with` and made `finally` a statement where it's written
([Where 10c differed](#where-10c-differed)).

It's built in two halves:

- **10a, handlers:** `with` as a set, `over` and `next`, `finally`, and
  handler state that can fail to start. It's checking and lowering, with
  no new runtime format.
- **10b, the journal:** recording, replaying, tracing, journals as tests,
  and the console's `:reload` and `:spec` ([testing.md](testing.md#the-console)).
  It needs 10a: recording is a handler `over` each real implementation.

The README's earlier sketch used `outer` and `for Users forwards`. This
design replaced both with one word, `over`, because the wrapping should
be visible in the code, not hidden in where a comma falls.

## What it has to do

1. **What wraps what is written, not implied by order.** Swapping two
   handlers, one `over` the other, changes the words, never a comma.
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

**A generic dependency's instances are each a dependency.**
`Log<Int>` beside `Log<Str>` is two, so a `with` can install both; `Log<Int>`
twice is the error above. `with h as Jobs` installs `h` as an alias of
what it implements (deps.md, "Generic dependencies"). A generic handler
over another goes over one at its own types: `with limit() over queue()`
makes them both `Chan<α>`, and `with limit() over Chan<Int>` goes over the
`Chan<Int>` installed outside.

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
        match found
          Some(u) => &cache.set(id, (u, Clock.now()))
          None => ()
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
  value. A block written in an operation can call it, as the operation
  can: the block finds `next` where it's written, and it can't outlive
  the call it's passed to, so it can't keep it (foundations.md).

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
error: `cached(ttl)` goes over a `Users`, so it's installed with `over`
  ┌─ main.ren:4:8
  │
4 │   with cached(ttl) in
  │        ^^^^^^^^^^^
  │
  = help: say what it goes over: `cached(ttl) over Users` for the one installed outside this `with`, or another implementation of it after `over`
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

### `over any`

A handler `over any` goes over whichever one dependency it's installed
over. Its state comes first, as any handler's, then one arm, `call =>
...`, which runs for every operation of that dependency:

```ren
handler logged() over any uses Console =
  call =>
    Console.write("> \{call.name}\{call.args}")
    let r = attempt call.forward()
    Console.write("< \{r}")
    try r

with logged() over mem_users() in
  print(Users.count())        // > Users.count()  < Ok(1)  1
```

In the arm, `call.forward()` calls the operation under it with the same
arguments, and fails with what the operation declares, so it's written
with `try` or `attempt`; it's called once at most on any path through
the arm. `call.fail(Down)` fails the operation with `Down`, which every
operation of what it's installed over has to declare, checked at the
`with`. `call.name` is `"Users.count"`, as the journal writes it, and
`call.args` the arguments, a tuple shown as a call shows them, `("a",
7)`, `()` for none. The arguments and what `call.forward()` gives are
opaque: they can be shown, compared with `==` and passed to generic
functions, and nothing else, and `call` itself is only used through, as
`next` is.

It's installed with `over`, on an implementation, `with logged() over
mem_users()`, or on the one installed outside, `with logged() over
Users`, and installs that one dependency. It's made where it's installed,
`with logged() over ...`: a function can't return one, since what it is
depends on what it goes over. The compiler makes a copy of the arm for
each operation of each dependency it's installed over (compiler.md,
"`over any` and `retry`"). It can't go over a dependency an operation
of which takes a block, `change: fn(k: Int, f: fn(&Int))`: `call.args`
holds the arguments as a value, and a block is never held in one, so
that's an error at the `with`, whose help says to write a handler `over`
that dependency. One that compares `call.args`, or what
`call.forward()` gives, is checked at the `with` against each
operation's: a result that's a description has no `==`. Comparing them
over a generic dependency isn't built yet.

### Functions that run a block

A `with` installs only handlers. A function that runs a block, like
the prelude's `retry`, is called with it, `try retry(3, on: Flaky) fn()
=> try fetch()`; 10c took these wrappers out of `with`
([foundations.md](foundations.md)). One written in a `with` is an error,
"`with` installs only handlers", whose help writes the call: `call it:
try retry(3, on: Flaky) fn() => ...`, with `try` only when the function
can fail.

`retry(n, on: Tags)` runs the block, and again while it fails with one of
the errors it's given `on:`, `n` tries in all: any other error leaves at
once, and after the last try its error leaves. `on:` is a parameter of
type `Tags`, a set of error tags, written by its name at the call, `on:
DbDown | Timeout`, or a named error set, and each has to be one the block
can fail with. A function of your own can take one too: it's matched,
`fail on => ...`, and passed on, `on: on`.

A handler keeps no block either. Its description is a value, which can
outlive the call that made it, so its parameters are data: `handler
h(f: fn() -> Int) for N` is an error, "a handler's parameters are data",
with the help `pass the data, or make the behaviour a dependency`, and
so is a `var` in its state that holds a block. An inline handler,
`handler fn(req) => respond(req, body)`, copies what it reads from where
it's written, and the same holds of that: a block is an error.

A chain is installed, never kept: `let x = cached() over mem()` is an
error, "a chain of handlers isn't a value", whose help keeps the parts
and writes the chain where it's installed.

### Operations and tasks

An operation keeps its instance until it returns (stage 11a,
[async.md](async.md#shared-state-is-a-handler)): once a spawned task
can reach a handler that keeps a `var`, or a value of an opaque type of
the program's, another task's call of one of its operations waits while
one runs, first come first served, and `Async.until` in an operation
lets go of it while it waits. So a block passed to an operation can't
call back into it, and gets its dependencies only from its parameter's
type:

```
error: a block passed to `Tally.change` can't use `Tally`, which it would wait for while `Tally.change` runs it
  = a block passed to an operation gets its dependencies only from its parameter's type
  help: call it before `Tally.change`, outside the block
```

For another dependency the help is to list it, `f: fn(&Int) uses
Console`, which the handler then has to use itself. A handler with no
such state takes no lock, and neither does one no spawned task can
reach, so a program with no tasks runs as it did.

What an operation's arm changes of its handler's state is kept however
the arm ends, cancelled too: its `finally` can give back what it took,
`&cancelled.push(c)`, and a waiter cancelled in `Async.until` starts its
`finally` from the state as the other operations left it. The standard
library's `sync` is written this way: a channel, a semaphore, `limit()
over any`, whose `finally` gives its permit back, and a batcher, each
over `Async.until` ([async.md](async.md#what-tasks-share-sync)). Many
instances of one handler, each with its own lock, are the prelude's
`striped(h, by: Key(n: 4))`, a call sent to one by its first argument's
key, over the runtime's keyed instance family (language.md §11).

### Called as a method

A description called as a method, `d.op(x)`, is `with d in D.op(x)`,
its arguments evaluated first ([deps.md](deps.md#descriptions-the-only-stored-code)),
and only a stateless handler is called this way, so it's a pure
dispatch. A handler with state would start fresh at each such call, and
its `finally` run when the call ended, as that `with`'s would: a call
that may reach one, a `var` or a `finally` among its state, is an error
whose help writes the `with`, `with c in Counter.bump()`, which keeps
one instance for its body. It's the linked program's check, since which
handlers a description may be is a closed-world fact: `ren run`, `ren
test` and `ren build` make it, and `ren check` of one module doesn't. One
that goes `over` another isn't called this way either, since the call
would install it over whatever is outside: the error's help installs it
over one, `with c over Users in Users.get(...)`.

## When a `with` ends: `finally`

A handler can run code when the `with` that installed it ends. A
`finally` is a statement among its state, and covers what comes after
it: the state below it, and the `with`'s body. It's given the result of
what it covers, and returns the `with`'s:

```ren
pub handler transaction() over Sql ! DbDown =
  let tx = try next.begin()
  finally(r) =>
    match r
      Ok(v) =>
        try next.commit(tx)
        v
      Err(_) =>
        next.rollback(tx)
        try r

fn transfer(t: Transfer) ! DbDown | Short uses Sql =
  try with transaction() over Sql in
    try debit(t.from, t.amount)
    try credit(t.to, t.amount)
```

- **A `with` whose setup or `finally` can fail is written `try with`,**
  as a call that can fail is marked, or `attempt with`, or handled with a
  `match` of the `with` that has `fail` arms. The marker covers only the
  installation: what `begin` and `commit` fail with. Each call in the
  body is a place the code can stop, so it has a marker of its own. A
  `with` that can fail and has no marker is an error, "installing
  `transaction()` can fail, and nothing handles it"; a `try with` whose
  items can't fail is "nothing here can fail".

- **`r` is the body's result,** a `Result` as `attempt` would keep it,
  and `try r` passes the body's error on. What `finally` produces is what
  the `with` produces. It's given a value of any type, so it can give it
  back or show it, never compare it.
- **A cancelled body gives `Err(Cancelled)`** ([async.md](async.md#cancellation)):
  `r`'s type is `Result<T, ! E | Cancelled>`, so a `match r` that names
  each error names `Cancelled` too, or has an `Err(_)`. The `finally`
  runs shielded, its own calls not cancelled until the cleanup deadline,
  5 seconds; then the cancel goes on, `try r` with it, and what the
  `finally` gave is thrown away. `Cancelled` is in no other row, so `try
  r` never adds it to the `with`'s errors.
- **When both the body and the cleanup fail, the handler's author says
  what happens.** Here a failed body rolls back and passes its own error
  on, and a failed commit fails the `with` with the commit's error.
  There's no rule hidden in the language.
- **The `with`'s errors are the body's, plus `finally`'s,** checked like
  any other.
- `finally` runs once, whether the body finished or failed. A panic isn't
  an error, so `finally` doesn't see it: a panic ends the program. Unless
  an `Async.isolate` around the `with` makes it a value
  ([async.md](async.md#a-panic-ends-the-program)): then the `finally` is
  given `Err(Cancelled)`, as a cancelled body's is.
- **Where it's written says what it covers.** This one is after `let tx
  = try next.begin()`, so a failed `begin` never reaches it. One written
  above that line would run then too, given `begin`'s error, and the
  `with` would still fail. A handler can have several, all before its
  first operation, and the last written runs first, given the body's
  result; each one above is given what the one below it returned or
  failed with.
- **An operation's arm can have one too,** covering the rest of the arm,
  and given its result:

  ```ren
  save(u) =>
    let lock = try next.lock(u.id)
    finally(r) =>
      next.unlock(lock)
      try r
    try next.save(u)
  ```

A handler is already what a type that keeps rules has to be
([module-build.md](module-build.md#private-unless-pub)): its state can't
be reached from outside, only through its operations, so the rule needs
nothing more here.

### State that can fail to start

A handler's state can now call a dependency that fails: `let tx = try
next.begin()`. A `with` that installs it fails with those errors too: the `with` passes
on what installing its items can fail with, as `try` would. A `finally`
written above the line that failed runs first, given that error.

## The journal

The journal is the record of the calls a program makes to the world: the
real `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc` and `Net`. A `Net`
call its task waits in, an `accept` or a `read`, is written in two lines,
and the poll that ended the wait between them.

### Recording and replaying

```
$ cd examples/just
$ ren run --record run.journal main.ren -- build
echo base
base
echo building
building
echo built
built
recorded 8 calls to run.journal (Console 3, Fs 1, Os 1, Proc 3)
warning: run.journal holds everything the program read, files and arguments included: read it before you share it

$ rm justfile
$ ren replay run.journal
echo base
echo building
echo built
replayed 8 calls: nothing touched the disk, and nothing ran
```

The just shows each line on stderr before `sh` runs it, and `sh` prints
the line's output. The replay shows the first, which went through
`Console`, and not the second, since nothing runs.

- **Recording is a handler over an implementation,** the prelude's
  `recorder`, a handler `over any` in Ren, which calls `call.forward()`
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
  std's `Secret<T>` will redact what it wraps ([Later](#later)), and
  until then the warning is the honest answer.
- **Replaying is a handler for each,** answering every call with what was
  recorded, in order. Pure code is deterministic, so a program given the
  same answers makes the same calls.
- That's enough for exact replay. What happens inside the program, between
  calls to the world, replays by itself. It needs one thing to be true:
  **nothing reaches the world except through a dependency.** Every
  intrinsic the prelude marks as reaching the world is an operation of
  `Clock`, `Random`, `Console`, `Fs`, `Os` or `Proc`, and so is recorded:
  the program's arguments included, and how the run ended is the
  journal's last entry.

### A replay that goes differently

```
$ ren replay run.journal
echo base
echo building
error: the replay went differently at call 7 of 8
   ┌─ main.ren:27:5
27 │     Console.error(line)
   │     ^^^^^^^^^^^^^^^^^^^
   = the recording has: Console.error("echo built!")
   = this program made: Console.error("echo built")
   help: the code changed since this was recorded; record it again
```

That's the journal's line 7 edited by hand. A replay also stops if the
program ends before the recording does, or goes on past its end, or
ends differently: a panic where the recording exited, say.

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
  ordinary test to read and edit. Fix the bug, and it stays fixed: a
  journal that ended in an error or a panic fails its test while the
  program still ends that way, and passes once the program goes on past
  where it ended, with the outputs it had made by then.

### Tracing

```
$ ren run --trace main.ren -- build
main                                          41ms
├─ Fs.read("justfile")                       0.0ms  → 345 bytes
├─ Os.args()                                 0.0ms  → ["build"]
├─ Console.error("echo base")                0.0ms
├─ Proc.run("sh", ["-c", "echo base"])       7.8ms  → 0
├─ Console.error("echo building")            0.0ms
├─ Proc.run("sh", ["-c", "echo building"])   7.0ms  → 0
├─ Console.error("echo built")               0.0ms
└─ Proc.run("sh", ["-c", "echo built"])      6.7ms  → 0
```

It's printed on stderr once the run ends, and `REN_NO_TIMINGS` leaves
the times out, as it does for `ren test`.

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
# ren journal 3 · main.ren · deps: Console Fs Os Proc
1 main Fs.read("justfile") → Ok("# What `ren run main.ren` runs, ...\n")
2 main Os.args() → ["build"]
3 main Console.error("echo base")
4 main Proc.run("sh", ["-c", "echo base"], Tree) → Ok(0)
...
9 main exit 0
```

From the runtime core on, this text is a view of the binary journal, the
core's order records joined with the recorder's content records
([runtime.md](runtime.md#the-call-record-a-header-the-core-owns-a-body-the-language-owns)),
and the interpreter writes the same files. That's version 3, the services stage's, which is stage 11a's version 2
(compiler.md, "Journal version 2") with the lines of the runtime's
instance families, below: a
number, the task that made the call, `main` or a spawned task's path
(`main/run_all:0`), the call, and what it gave after `→`, left out when
it's `()` or `Ok(())`; the last line is how the run ended, `exit 0`,
`error` and what `main` failed with, written as a value is, or `panic`,
where, and what it said, in quotes. With tasks, three more kinds of
line keep the order the tasks ran in:

```
4 main/main:0 Clock.sleep(30) …
7 poll main/main:1 main/main:0
8 main/main:1 →
11 main/main:2 cancelled
# warning: main/main:3 failed too, with `Broke`, while it was being cancelled
```

A call its task waited in is two lines, its start, ending `…`, and,
after the poll that woke it, a line of its task and `→` with what it
gave; a `poll` names the tasks the scheduler woke when no task could
run, in the order it woke them; a task that saw a cancel is a line;
and a second failure's warning is a comment. `ren replay` follows the
polls and is strict about every entry's task and order, so a concurrent
run replays byte for byte. A test that replays a journal answers each
task's calls from its own entries, compares each task's outputs with its
own, and runs in the recorded order while it can, its schedule prefix,
before the seeded tape takes over. Version 3 adds what the runtime's
keyed instance families do, each on the task that did it
(compiler.md, "Services stage", "Journal version 3"): `main opened docs`,
`main made docs[DocId(1)]#1`, `main/main:0 evicted
docs[DocId(1)]#1` and `posted docs[Key(2)] Ping { left: 2 }` (from the
runtime core on, a post's arguments aren't kept: a replay makes the
post again, so its line keeps its order and call id, and `--trace`
shows the arguments;
[runtime.md](runtime.md#whats-journaled-time-and-order-and-place-only-when-its-read)), an
instance named where its family is installed, by its key and its life,
and the calls a delivered post makes under that name. A version 1 or 2
journal is refused, with how to record it again. The header names the
program from the journal's folder, or absolutely if that's more than
two folders up, and the dependencies `main` uses. What follows is where it's going;
[Where 10b differed](#where-10b-differed) says what isn't there yet.

**A journal is text,** one call a line, because journals are checked in
as tests and read in review: a changed journal shows what changed, and a
bug report can be read before it's run. A compact binary form can come
with the flight recorder, where size matters. The format is to be
revisited once real journals exist. The shape is `runtime-io.md`'s, a
submission and its completion:

- **`task` and `seq`** say who made the call and in what order: the
  task column, and the line's number (version 2, above).
- **Names, not positions.** A journal starts with a table of the
  dependencies, operations, types and field names it uses, and its
  entries refer to that table. A journal recorded on one build can be
  replayed against another as long as the names still match. That's what
  replaying production traffic against a new build will need.
- **Values are written by the compiler's structural walk,** the same one
  derived `==` and `show` use ([operators.md](operators.md#how-it-runs)).
  It stays internal: the journal's format is the runtime's, not a
  serialization API.
- **Redaction is a value from the start.** std's `Secret<T>` doesn't
  exist yet, but when it does, its `show` redacts and it has no `repr`,
  so the walk records it as `<redacted>`. The format has room for
  that now, so it never has to change for it.
- **Large values have a limit.** Past a size cap, an entry keeps only a
  value's length, and a replay that needs it says so. A journal has a byte
  budget, set when it's recorded.

## How it runs

- **`next` is a lookup Ren already does.** A handler captures the evidence
  vector from where it's installed. With `over`, the implementation it's
  over is installed just outside it, so `next` is that implementation in
  the captured vector. A block written in an operation captures that
  vector too, as every block captures the evidence where it's written
  ([deps.md](deps.md#how-it-runs)).
- **Leaving operations out** compiles to forwarding them, with no code to
  write. It's a direct call, so it costs what writing it out would.
- **A handler's `finally`s** are one lambda kept in its instance,
  which runs them last written first. The Core `With` that installed it
  calls it with the body's result, `Ok(v)` or `Err(e)`, and a descriptor
  of the body's type, which the lambda takes first, so `print(v)` works
  for any type ([compiler.md](compiler.md#stage-10a)). When the state
  below one fails to start, the error is handled there, the `finally`'s
  body run on it, and passed on. One in an arm is an `attempt` of the
  rest of the arm, then its body ([compiler.md](compiler.md#stage-10c)).
- **The journal is the runtime's own record,** one of the privileged
  handlers in foundations.md's closed list (decision 20): only the
  runtime can install its recorder over the real implementations. A program
  can't name them, so it can't wrap them any other way than `over Clock`.
  The recorders, `recording_fs(j) over Fs` and one for each built-in, and
  the replayer, `replaying(j)` for all of them, are handlers in the
  prelude, written in Ren. Each operation calls an intrinsic that writes
  the call down, or answers it, through its type; the runtime installs
  them, and journal.ml is the one place that knows the format
  ([compiler.md](compiler.md#stage-10b)). Recording a program's own
  dependencies, tracing and the flight recorder are plain Ren over
  `over any`, with no privilege.
- **A description's tag finds its handler's record** (compiler.md,
  "Descriptions (step 3)"): a native description is an object whose first
  word is the tag, then what the handler captured. A debug build's tag
  points at a static record of the handler's code, its name and its
  size, and a release build's is a number indexing the program's table of
  them. A stateless handler's record has a method for each operation,
  which a method call runs with the caller's evidence and the
  description, making no instance; one with state has none, and a `with`
  of one call, `with d in D.op(x)`, the same site, installs it (a method
  call can't reach one since the data stage's step 6). An inline handler is a handler like any other there. A
  release build reads the record only for a call it can't decide: one
  that one handler reaches is a direct call, two to four a compare of
  the tag, more a table of each operation's methods, and a loop over an
  unchanging description is copied per handler (compiler.md, "Dispatch
  (step 4)", and `ren build --release --explain-dispatch D`).
- **Nothing reaches the world but through an operation:** Core Lint
  checks that each intrinsic that does is called only by its
  dependency's real implementation, `fs_read` by `real_fs`, the prelude
  handler that `Fs.real` describes.

## What changed in deps.md and the README

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

## Where 10a differed

Where building 10a settled something this design left open, or changed
it:

- **`finally`'s arms are `Ok(v)` and `Err(_)`,** and the error goes on
  with `try r`: a `fail` pattern never binds a whole error
  ([errors.md](errors.md)).
- **`finally` is generic in the body's value,** so it can give it back,
  pass it on or show it, but comparing, ordering or hashing it is an
  error. The `with` fails with the body's errors and the handler's own,
  whatever `finally` does with the body's.
- **A public handler that can fail to start says so,** `pub handler
  transaction() over Sql ! DbDown`, as a public function's signature is
  exact; a private one's is inferred.
- **`next` isn't a keyword:** in a handler declared `over`, `next.op(...)`
  and `next(A).op(...)` reach the one under it, and nothing there can be
  named `next`. It can only be called through, never kept.
- **A lambda couldn't call `next`** until stage 10c: passed to the
  implementation under the handler and kept there, it would have reached
  it again, a cycle. A block can't be kept, and it finds `next` where
  it's written, so since 10c step 4 one can:
  `get(k) => [1, 2, 3].map(fn(i) => next.get(k) * i).sum()`.
- **A chain installs what its bottom installs,** with each link above
  taking the place of what it goes over: `cached(ttl) over counting()`,
  where `counting` is a `Prices & Calls`, installs both.
- **An item's value is made outside the `with`,** in the order written,
  before anything is installed.
- **Items that don't need each other are installed in the order of their
  dependencies' names,** so a `with` means the same whatever order its
  items are written in, even when two `finally`s run.
- **A handler is `for` all its dependencies or `over` all of them.**
- **Whether it goes over, and what it can fail to start with, are part of
  an implementation's type:** `over Users uses Clock`, `Sql ! DbDown`. A
  written type without `!` can't fail to start, a parameter's of a
  dependency's type included.
- **`with h() over A & B`** wraps several implementations installed
  outside the `with` at once.
- **A `finally` came last, and a handler had one,** until 10c, which
  made it a statement where it's written.
- **The help for a link over nothing** writes `over Users` rather than
  naming a maker of `Users`, which the compiler can't know is the one
  meant.
- **A panic skips `finally`, and so did a failed start** until 10c:
  now a failed start reaches a `finally` written above where it failed.

## Where 10b differed

- **The runtime installs the recorders and the replayer,** not `$start`
  in Core: `ren run --record` and `ren replay` call `main` with them
  installed, as a test's implementations are.
- **The format is the simplest one:** no `task`, no table of names, no
  size cap and no byte budget. Values are written as Ren writes them,
  through their type, but an opaque value as what it's represented as
  (`Clock.now() → 1793074838446`), a `Path` as its string, and `Bytes` as
  a string with `\xNN` for a byte that isn't UTF-8. `<redacted>` reads,
  and a replay that needs it says it can't give it back.
- **An arm can name its dependency,** `Console.write(line) => ...`, for
  a handler of two dependencies that both have an operation of that
  name. The replayer needed it: `Console` and `Fs` both have `write`.
- **`--trace` is one level,** what the table calls 2 and 3 together:
  arguments and what each call gave, cut to 40 characters, `Bytes` as
  how many, with the time. There's no level 1, and nothing is compiled
  out.
- **`ren replay` prints what went through `Console`,** and not what a
  process the program ran printed, since none runs.
- **`ren test --keep bug.journal`** moves the journal to `tests/` next
  to the program it recorded, rewrites its header's path, and adds
  `test "replays bug.journal"` to the program's file. `main` has to be
  `pub` for that, since a test sees what an importer sees.
- **`replay(file)`** finds the journal from the folder of the test's
  file, and is the prelude's one test item, which only test code can
  use. What it implements is read from the journal's header when the
  test is checked, so the file is named by a string literal; named any
  other way, it implements all six.
- **`ren replay` refuses a journal whose header names other
  dependencies** than the ones `main` uses now.
- **The environment and the working directory aren't recorded,** since
  no operation reads them: `Os` has only `args`. They still shape what
  the real `Proc.run` and `Fs` do (`PATH` finds a program, and a
  relative path is from the working directory), but a replay answers
  those calls from the journal, so it's exact anyway. An operation that
  reads them would be recorded as any other is.
- **A journal has to end with how the run ended.** One without it, cut
  short or stopped, isn't replayed: the replay couldn't say whether
  the run ended as it did.
- **A call past the end of a recording that ended in a panic** panics
  there only if it's where the recording panicked, inside that call.
  Anywhere else the program went on past the recording's end, and the
  replay went differently.

## Where 10c differed

Stage 10c made lambdas blocks (foundations.md), which changed three
things here:

- **Wrappers left `with`.** `with` installs only handlers; a function
  that runs a block is called with it, and a wrapper written in a `with`
  is an error whose help writes the call, `try retry(3, on: Flaky) fn()
  => ...` ([Functions that run a block](#functions-that-run-a-block)).
- **`next` can be called from a block** written in a handler, since a
  block can't be kept (Where 10a differed).
- **`finally` is a statement where it's written,** among the handler's
  state or in an operation's arm, covering what comes after it, and a
  handler can have several. It's never after a handler's first
  operation, and in an arm it's only at the arm's top level, not inside
  an `if` or a `match`. A `break` can't leave a `with`, since a
  `finally` would be given nothing.

## Later

- **Recording what the scheduler decides,** with `Async`, so a concurrent
  program replays exactly too.
- **The flight recorder** (stage 17): keeping a journal in a ring buffer,
  and deciding at the end of a request whether to keep it.
- **Replaying production traffic against a new build,** and comparing the
  responses.
- **std's `Secret<T>`,** recorded as `<redacted>`.
- **`arena`, with `Alloc`** (stage 15): a handler whose `finally` frees
  everything it allocated.

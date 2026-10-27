# Ren

**Read like a script. Checked like a proof.**
*App-language ergonomics. Systems-language control.*

Ren is a systems programming language with pure-feeling semantics, compile-time-checked dependencies, and no garbage collector. Function bodies stay short and readable because the signature carries the detail: what a function touches, how it can fail, and what it costs. The compiler checks all of it.

```ren
pub fn upgrade(id: UserId, seats: Int) -> User ! NotFound | PaymentFailed | Conflict
    uses Users, Billing =
  var user = Users.get(id) orelse fail NotFound
  try Billing.charge(user.id, price(seats))
  user.plan = Pro(seats)
  try Users.save(user)
  user
```

You can read that signature without opening the body. `upgrade` returns a `User`, can fail in exactly three ways, and touches exactly two dependencies. It performs no other I/O, hidden allocation, or global state access. Every line that can fail is marked, with `try` or `fail`.

Because the compiler knows every boundary a program crosses, Ren can **test, trace, replay, and profile** those boundaries without any instrumentation code. [More on that below.](#test-trace-replay-profile-built-in)

> **Status:** early. Stages 1–4, 5a, 5b, 6–9, 10.0, 10a and 10b of the [Roadmap](#roadmap) run in an interpreter: functions, records, sum types, exhaustive `match`, lambdas, type inference with `uses` rows, `var`, `inout`, `&` with value semantics over records and arrays, modules (files as modules, `import`, `pub`, `opaque` types, constructors and fields found through their type, and `uses` on signatures, checked against the body), methods, associated functions and associated values declared under their type, with `&` before a changed receiver: `&xs.push(x)` (see [examples/shop](examples/shop)), and errors: structural tags after `!`, named error sets, `fail`, `try`, `match` with `fail` arms, `try match`, `attempt` and `orelse`, with exact signatures on public functions, and `&&`, `||` and `not`; and dependencies: `dep` declarations, `with` and `handler`s, the built-in `Clock`, `Random` and `Console`, minimal strings, and `test`, `group`, `assert` and `ren test`, with test implementations by default (see [examples/bank](examples/bank)); and the world, thinly: `Str`'s methods, on byte offsets, `Bytes`, `Path`, `Fs`, `Os.args` and `Proc.run`, with `mem_fs`, `test_os` and `test_proc` in tests, and `ren run file.ren -- args` (see [examples/just](examples/just)); and stage 9: operators as methods (`a + b` is `a.add(b)`, chosen by the right side's type), `key`, derived `==`, `hash`, order and `show`, `opaque Int with numeric`, 64-bit `Int`s that panic on overflow, `Float`s with no `NaN`, tuples, ranges in `for`, `Map` and `Set` in insertion order, and `Enumerable`'s methods on `Array`, `Map` and `Set` (see [examples/bank](examples/bank)); and stage 9c: `opaque { ... }` records, a type that keeps rules is opaque, tests that see what an importer sees, `test fn` and `test handler`, and `ren console` on test implementations (see [examples/bank](examples/bank)); and stage 10a: `with` as a set, handlers `over` another implementation that reach it with `next`, `finally`, and handler state that can fail to start (see [examples/prices](examples/prices) and [examples/ledger](examples/ledger)); and stage 10b: the journal, `ren run --record` and `ren replay`, which runs a program again on what it was given without touching the world, `ren run --trace`, a journal as a test with `replay(file)` and `ren test --keep`, and the console's effects shown as they happen, `:reload` and `:spec` (see [examples/just](examples/just)). Most examples in this README show how Ren is intended to look, not what runs today. Editor support: [Zed](editors/zed), on a [tree-sitter grammar](editors/tree-sitter-ren) checked against the compiler's parser.

---

## Contents

- [Why Ren](#why-ren)
- [Principles](#principles)
- [A tour](#a-tour)
- [Methods, operators, and equality](#methods-operators-and-equality)
- [Memory without a GC](#memory-without-a-gc)
- [Allocation model](#allocation-model)
- [Concurrency](#concurrency)
- [FFI and `trust`](#ffi-and-trust)
- [Why this is possible: knowledge × control](#why-this-is-possible-knowledge--control)
- [Test, trace, replay, profile: built in](#test-trace-replay-profile-built-in)
- [Errors are part of the design](#errors-are-part-of-the-design)
- [Tooling](#tooling)
- [Trade-offs](#trade-offs)
- [Prior art](#prior-art)
- [Implementation](#implementation)
- [Roadmap](#roadmap)
- [Beyond 1.0](#beyond-10)
- [Open questions](#open-questions)

---

## Why Ren

| You like… | …but you're tired of | Ren keeps | Ren drops |
|---|---|---|---|
| **Rust** | lifetimes, slow compiles | memory safety, no GC, native speed | the borrow checker, trait search |
| **Zig** | convention-only discipline | explicit allocation, minimalism, C interop | unchecked aliasing, manual frees |
| **Go** | `if err != nil`, `ctx` everywhere, OTel overhead | a big stdlib, one way to do things | nil, untyped errors |
| **Effect TS** | a framework on top of a language | typed dependencies, swappable layers | the runtime, the generics gymnastics |
| **OCaml / Elm** | GC pauses, no systems control | ADTs, exhaustive matching, inference | the GC |

The goal is one language for the whole range: everyday backend services at one end, storage engines and databases at the other. The types tell you which end of that range a piece of code is at.

```
 everyday server code                                    a new database
 uses Users, Billing, Net         same language          unique, soa, no Alloc,
 try, with, swap in tests                                arenas, simulation tests
 "reads like a script"                                   "checked like a proof"
```

---

## Principles

These are ranked. When two of them conflict, the one higher on the list wins.

1. **The signature is the truth.** Everything a function touches, returns, or fails with is in its type.
2. **The world is a dependency.** Code reaches outside itself (network, disk, clock, memory) only through dependencies listed in `uses`, at run time and at build time. Tests swap them, the journal records them, and replay answers them.
3. **Boundaries are narrow, and tested there.** A type that keeps rules is opaque, a module shows only what's `pub`, and a test sees what an importer sees, so a test is a specification and refactoring never breaks one ([testing.md](testing.md)).
4. **Nothing is found behind your back.** There's no trait search, no overloading, and no implicit conversion. Implementations are installed or attached to a type, never searched for.
5. **Values never change under you.** You can write `x.field = y`, but nobody else can observe it. The only state that outlives a call lives inside handlers, which one task touches at a time, and a handler's state can only change between dependency calls.
6. **One way, one mechanism.** When two features overlap, one goes. Dependency injection, test fakes, allocators, middleware, simulation, and tracing all use the same `uses` / `with` mechanism.
7. **Nothing is lost silently.** A dropped value is written `let _`. Errors are checked. Cancellation can't be swallowed, and a second failure goes to the trace.
8. **Everything has a limit.** Tasks, queues, retries, stacks and build time are all bounded, and running into a limit is an error that says where.
9. **Costs that matter can be pinned.** A function that doesn't list `Alloc` doesn't allocate, and the compiler proves it.
10. **Guarantees never depend on optimizations.** A program means the same thing in a debug build and a release build.
11. **Least surprise, and the compiler explains itself.** When in doubt, do what a reader would expect. When that isn't possible, make it an error rather than behaviour to learn, and every error explains why it happened and suggests a concrete fix.
12. **Enough out of the box.** One formatter, one test runner, one console, one build tool, and a stdlib you can ship with.

A useful filter for any proposed feature: does it make function bodies read more like a script, or signatures more like a proof? If it does neither, cut it.

The three bars Ren is measured against (within 2× of Rust, debug builds faster than Go, replay byte for byte) are in [vision.md](vision.md), with two more principles for how the compiler is built.

---

## A tour

Ren has eight concepts. Anything else is a library function.

### 1. Types

```ren
type UserId = opaque u64               // distinct from u64; only this module can make one
type Email  = opaque Str

type Plan =
  | Free
  | Pro(seats: Int)
  | Enterprise(contract: ContractId)

type User = { id: UserId, email: Email, plan: Plan }

fn seat_limit(p: Plan) -> Int =
  match p                              // exhaustive: add a Plan and this stops compiling
    Free          => 1
    Pro(seats)    => seats
    Enterprise(_) => Int.max
```

Ren has no null. Optional values are written `T?`.

### 2. `let` and `var`: value semantics

```ren
var scores = [3.0, 1.0, 2.0]
let before = scores                    // a value, not a reference
&scores.push(10.0)                     // copies once: `before` still shares the buffer
assert before == [3.0, 1.0, 2.0]       // nothing changes out from under you

var user = load(id)
user.plan = Pro(seats: 5)              // reads like mutation, means "new value"
```

No two names ever see the same mutable thing, so Ren has no data races and no reference cycles. When a value isn't shared, the compiler updates it in place, so the copies you'd expect from immutable data mostly never happen.

### 3. Functions

```
pub fn name(params) -> Value ! Errors      what goes in, what comes out, how it fails
    uses Dependencies =                    what it touches
```

```ren
fn total(xs: Array<Float>) -> Float            // read-only parameter (default)
fn normalize(inout xs: Array<Float>)           // updates the caller's value
fn blur(unique img: Image) -> Image            // proven unshared, so in-place is guaranteed
```

Lambdas are **blocks**, with trailing-lambda syntax for multi-line bodies. A block is passed to a call, called, or named with `let` where it's written, `let f = fn(x) => x + 1`. It can't be stored in a record, an array or an enum, returned, or held in a `var`, so it never outlives the call it's passed to:

```ren
let names = users.map(fn(u) => u.name)

let summaries = Async.map(users) fn(u) =>
  let feed = try load_feed(u.id)
  summarize(u, feed)
```

Inside brackets, where line breaks are otherwise ignored, a lambda's body can be a block too: a `=>` that ends its line opens one, indented further than the line around the brackets, and it ends at a line indented less, at a `,` before the next argument, or at the closing bracket:

```ren
let total = items.reduce(0, fn(sum, item) =>
    Clock.sleep(Duration.ms(20))
    sum + (if item == "apple" then 3 else 1)
)
```

Public functions spell out their full contract. Private functions can infer their `uses` and their error set (`! _`). `ren fmt --annotate` writes the inferred clauses into your code.

A parameter written `fn(...)` takes a block, and since a block can only be called or passed on, the parameter is **transparent**: its errors and dependencies flow into the caller automatically, so they're never written:

```ren
pub fn map<T, U>(xs: Array<T>, f: fn(T) -> U) -> Array<U>
pub fn retry<T>(n: Int, body: fn() -> T) -> T
```

`Async.map` and `Async.timeout` take theirs the same way. Calling `Async.map` with a lambda that can fail with `FeedError` and uses `Net` makes that call fail with `FeedError` and use `Net`. It's still transparent even though it runs `f` on other tasks, because no task outlives the call that started it ([async.md](async.md)).

Behaviour that's kept is data, or a dependency. A button that remembers what a click does holds an enum to `match` on where the click is handled, or the code that runs is a `dep`'s implementation, installed with `with`. Writing a function type in a record field, a constructor's payload, a type argument or a return type is an error that says so.

### 4. Errors

Errors are part of the signature, after `!`, and every place that can fail is marked where it happens.

```ren
pub fn load(id: UserId) -> User ! NotFound
    uses Users =
  Users.get(id) orelse fail NotFound           // Option → error

pub fn page(id: UserId) -> Html
    uses Users =
  let user = match load(id)                    // handle every error (exhaustive)
    u => u
    fail NotFound => guest()
  render(user)

fn report(id: UserId) -> Report =              // private: its errors are inferred
  let user  = try load(id)                     // pass it on
  let stats = attempt fetch_stats(id)          // keep the outcome as a Result value
  build(user, stats)

fn profile(id: UserId) -> Profile =
  let user = try match load_full(id)           // handle some, pass the rest on
    u => u
    fail NotFound => guest()
  summarize(user)
```

Handling an error is pattern matching, so it's a `match`: a `fail` pattern matches an error, and any other pattern matches the value. The `match` must handle every error the call can fail with, and `_` never matches one (`fail _` does), so a stray wildcard can't swallow a failure. `try match` handles the errors it lists and passes the rest on, so the line still starts with `try`. `try` covers every call to its right in the same expression, and `attempt` the ones up to a comparison, so `attempt f() == x` compares its `Result`. A call that can fail with no marker is an error, and so is a marker on a call that can't fail.

`attempt` is the one way a call's error becomes a value: it turns the outcome into `Ok(v)` or `Err(tag)`, for an error that has to outlive the line it happened on, such as one checked by a test or decided on later. `try r` fails with it again.

Error tags work like OCaml's polymorphic variants. They're structural and need no declaration: `fail NotFound` and `fail PaymentFailed(reason: "card declined")` just work. Tags aren't values: they appear only after `!`, after `fail`, in `fail` patterns, and inside `Err(...)`, where a name is always a tag, so a test can compare what `attempt` kept, `assert attempt f() == Err(NotFound(id))`. A name for a set of tags is declared with `!`:

```ren
type BillingError = ! PaymentFailed(reason: Str) | CardDeclined

pub fn checkout(cart: Cart) -> Receipt ! BillingError | NotFound
```

A public function lists its errors exactly, so a signature can get long. That's the contract: callers handle what can happen and nothing else.

When a call fails, whatever it changed before failing stays changed. For all-or-nothing, change a copy and keep it only if nothing failed: `var draft = self`, then `self = draft` at the end. A statement whose value isn't `()` is an error, so a result can't be dropped without a word; `let _ = ...` drops it on purpose. The whole design, and why, is in [errors.md](errors.md).

Tags only have to agree where they meet. `Timeout` from `Async.timeout` and `Timeout` from your own code are the same error if they have the same shape. If one error set would contain two shapes of the same tag, such as `Timeout(ms: Int)` and a plain `Timeout`, that's a compile error asking you to rename one. So adding a dependency never breaks code that doesn't touch it.

Bugs aren't errors. Out-of-bounds access, a failed `assert`, or `unwrap` on `None` panics the program.

### 5. `uses`: dependencies are types

A dependency is declared with `dep`: its operations first, then its members, as a sum type lists its variants first. Calling an operation, `Users.get(id)`, calls whatever implementation is installed, and adds `Users` to the function's `uses`.

```ren
pub dep Users =
  get:  fn(id: UserId) -> Option<User>
  save: fn(u: User) ! Conflict

pub fn touch(id: UserId) ! NotFound | Conflict
    uses Users, Clock =
  var u = Users.get(id) orelse fail NotFound
  u.last_seen = Clock.now()
  try Users.save(u)
```

A dependency call takes no marker: the capitalised `Users.` already shows it. Its errors are marked as any call's, `try Users.save(u)`. A private function's `uses` is inferred, and a public one's is checked against its body, with the error pointing at the call that uses what the signature leaves out. `Users.x` means exactly one thing: an operation and a member can't share a name.

The built-in dependencies are `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc` today, then `Net` and `Async` (stage 12), `Alloc` (stage 14) and `Unsafe`. There is no catch-all `Io`. Even `print` goes through one: it's an ordinary prelude function, `Console.write(show(x))`. `Time`, `Instant` and `Duration` come with `Clock`, and `Str` arrives at its smallest: literals, `==` and `show`. Stage 8 gives it methods, and `Bytes` and `Path` with it. Stage 9 renames `s.find(":")` to `s.index(":")`, as `Array.index`: `index` finds where something is, and `find` takes a function.

The runtime installs exactly the built-ins `main` lists in its `uses`, outermost. Any other dependency has to be installed inside `main`, and leaving it out is a compile error, `nothing installs Users before main`, with a help that says how.

```ren
pub fn checksum(data: Bytes) -> u32 =          // no `uses`: pure, cannot allocate
  var h: u32 = 2166136261
  for b in data
    h = (h ^ b.u32).wrapping_mul(16777619)
  h
```

The whole design, and why, is in [deps.md](deps.md).

### 6. `with`: installing implementations

An implementation is a value of the dependency's type, made by a `handler` ([section 7](#7-handler-stateful-implementations)), which gives each of its operations. A dependency can offer one as a member:

```ren
pub dep Clock =
  now:     fn() -> Time
  instant: fn() -> Instant
  sleep:   fn(d: Duration)

  pub fn frozen(at: Time) -> Clock = frozen_clock(at)

handler frozen_clock(at: Time) for Clock =
  now() => at
  instant() => Instant.zero
  sleep(_) => ()
```

`with` installs it around a body:

```ren
fn main() ! StartupError
    uses Os, Net, Alloc =
  let cfg = try Config.from_env()
  with sql.pool(cfg.db_url), pg_users, log.json in
    http.serve(cfg.port, routes)
```

Production wiring, test fakes, allocators, simulators, and tracers all use the same mechanism. A long list of items can break after a comma, the next line indented further. Any line outside brackets that ends in `,` goes on this way, so a signature's `uses Clock,` can wrap too, with the rest of the list indented on the next line. A `with` is a set: each dependency appears in it once, and the order of its items never matters. An item's needs are met by the other items first, then by what's installed outside, and putting one implementation in front of another is written with `over` ([section 7](#7-handler-stateful-implementations)). A `with` nested inside another can install a dependency again, and the inner one wins inside it. `with` removes what it installs from the body's `uses`, and adds what its items need.

`with` installs only implementations. A function that runs a block, like `retry`, is called with it, the block written last:

```ren
pub fn retry<T>(n: Int, body: fn() -> T ! Flaky) -> T ! Flaky   // calls body up to n times

let rate = try retry(3) fn() => try Rates.fetch()
```

Writing one in a `with` is an error whose help writes the call:

```
error: `with` installs only handlers
  ┌─ main.ren:8:10
8 │     with retry(3) in
  │          ^^^^^^^^ takes a block
  = `retry` is a function that runs a block, so it's called with the body as one
  help: call it: `try retry(3) fn() => ...`
```

`retry` calls the block again from the top. It doesn't resume anything. It also repeats any dependency calls the body made before failing, so wrap only work that's safe to repeat.

Dependencies are found when code runs, not when it's written. A function or block whose type says `uses Users` gets whatever `Users` is installed where it's called, and the type checker makes sure one is. A block never outlives the call it's passed to, so it never holds on to an old implementation.

The one exception is an implementation's own dependencies. **What an implementation needs is part of its type**, and is required at the `with` that installs it: a `Clock` whose `now` calls `Os` makes `with` that clock need `Os`, while the code inside sees only `Clock`. Its dependencies are fixed once, when it's installed, to whatever is installed further out. And **interfaces are exact**: an operation's implementation may fail with fewer errors than the interface declares, never more.

#### Tests

```ren
test "a deposit is stamped with the time" =
  var acme = Bank.empty
  let a = &acme.open()
  TestClock.advance(Duration.minutes(5))
  try &acme.deposit(a, Money.dollars(10))
  let s = try acme.statement(a)
  assert s[0].at == Time.epoch + Duration.minutes(5)
```

Tests sit next to the code they test, and `ren run` ignores them. A test sees what an importer sees, the module's `pub` items, so it's a specification of the interface, and its helpers are test items, `test fn` and `test handler`, which only tests see: a test that reaches a private item is a compile error. Exploring a module's insides is what `ren console` is for ([testing.md](testing.md)). Every test gets test implementations of the built-ins without a `with`: a `Clock` stopped at `Time.epoch` until `TestClock.advance` moves it, a `Random` seeded from the test's name, and a `Console` that keeps what it's given, `TestConsole.output()`. So a test that uses no real dependency gives the same result on every run. A test asks for a real one in its `uses`, `test "the system clock moves" uses Clock =`, so going outside is visible. Any other dependency needs a `with`, and forgetting one is a compile error naming the test and the call that needs it.

A group is a function over implementations, so one suite runs against every implementation of a dependency, each test with a fresh one:

```ren
pub group clock_conforms(c: Clock) with c =
  test "now never goes back" =
    let t = Clock.now()
    assert Clock.now() >= t

group "frozen" = clock_conforms(Clock.frozen(Time.epoch))
group "test clock" = clock_conforms(test_clock(Time.epoch))
```

A failed `assert` is a panic: it's a bug, not an error. `assert a == b` shows both sides, with a marker under the first place they differ and what they share left out, `Account(..., balance: Money(-100), ...)`, and an opaque value as its type around its contents, `Money(-100)`, as `print` shows it. To check that something fails, keep it with `attempt` and compare: `assert attempt &acme.deposit(a, Money.zero) == Err(NotPositive(Money.zero))`.

`ren test` runs every module's tests in a folder: one line per test, then each failure with its source, both sides, its seed and the command that reruns it, and what it printed. `--only <text>` runs the tests whose name has it, `--seed N` sets every test's seed, `--list` lists them, saying which use a real dependency, and it exits with status 1 if any failed. [examples/bank](examples/bank) carries a suite like this.

### 7. `handler`: stateful implementations

Every implementation is a `handler`. One without state, like `Clock.frozen`'s above, only gives its operations; one that holds state keeps it in `var`s:

```ren
handler mem_users(init: Array<User>) for Users =
  var table = Map.of(init.map(fn(u) => (u.id, u)))
  get(id) => table.get(id)
  save(u) => &table.set(u.id, u)
```

A handler can implement several dependencies that share one state:

```ren
handler counting_rates(rate: Decimal) for Rates, RateCalls =
  var calls = 0
  usd_to(_) =>
    calls += 1
    rate
  count() => calls
```

Calling `counting_rates(r)` describes a handler, a value of the dependency's type like any implementation, and each `with` creates a fresh instance with its own state: two `with`s never share it. Its type lists what it implements, `Rates & RateCalls`. `with` installs what the type says, so both, sharing the state. Where a written type asks for one of them, `fn run(r: Rates)`, it becomes that one ([deps.md](deps.md)). Handlers resume at most once, which keeps them as cheap as function calls. Inside a handler for `Users`, writing `Users.get` is an error.

A handler can sit in front of another implementation of the same dependency. It's declared `over` it, may leave operations out, which go to the one under it, and calls that one through `next` ([handlers.md](handlers.md)):

```ren
pub handler cached(ttl: Duration) over Users uses Clock =
  var cache: Map<UserId, (User, Time)> = Map.empty
  get(id) =>
    match cache.get(id)
      Some((u, at)) if Clock.now() - at < ttl => Some(u)
      _ =>
        let found = try next.get(id)            // the Users under this one
        if found is Some(u) then &cache.set(id, (u, Clock.now()))
        found
  save(u) =>
    &cache.remove(u.id)
    try next.save(u)

with cached(ttl) over postgres_users(pool) in
  serve(requests)
```

What wraps what is written with `over`, never implied by the order of a `with`. A `cached` installed outside `with Clock.frozen(t) in` keeps using the clock that was installed where it was, even when it's called from inside that block. A handler can only see implementations installed further out, so handlers can't call each other in a loop.

A handler's state is exclusive between dependency calls. Two tasks are never inside the pure part of the same handler at once, so state updates can't corrupt each other. Other calls can interleave only at a dependency call, such as `next.save` or `Clock.now()`, and cancellation happens only there too.

That narrows where a race can happen without hiding it. `cached` above has one: between `cache.remove` and `next.save`, another task's `get` can miss, read the old user, and put it back in the cache. The compiler warns about it, since `cache` is read before a dependency call and written after it ([async.md](async.md#state-that-changed-during-a-call)), and the simulation scheduler switches tasks at exactly these points, so `ren test --sim` finds it too. The fix is to invalidate after `next.save` returns.

A handler can also run code when its `with` ends, in `finally`, which is given the body's result and returns the `with`'s. Its state can fail to start, and the `with` passes that failure on:

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
```

`r` is the body's result, as `attempt` would keep it, and `try r` passes its error on. `! DbDown` says installing it can fail, so the `with` can too ([examples/ledger](examples/ledger)).

When the body is cancelled, `finally` sees `Err(Cancelled)`, and what it returns is discarded ([async.md](async.md#cancellation)).

### 8. `&`: this call changes it

```ren
normalize(&scores)                     // visibly updates `scores`
&scores.push(10.0)                     // a method that changes its receiver

for p in &particles                    // update each element in place
  p.pos += p.vel * dt

let n = try Fs.read(fd, &buf)          // the kernel gets exclusive access to buf

swap(&a, &a)                           // error: `a` passed as inout twice
```

An argument passed with `&` has to be the only way the call can reach that value, so no other argument of the call can use it: `f(&xs, xs)` is an error. If it were allowed, the read would either point into a buffer the call is changing in place, or make that buffer shared and force a hidden copy. For now that also covers reading a part of it, as in `&xs.push(xs[0])`: read it into a `let` first. Once reference counting arrives (stage 11), reading a plain value out of it, such as an `Int` element, will be allowed, because that read copies the value before the call starts. Reading something that is itself counted, like an array element or a `T`, will stay an error.

A function body uses exactly two markers: `try` means a call can fail, and `&` means a call changes something.

---

## Methods, operators, and equality

There are no traits or typeclasses. A type carries its own operations, indented directly under its declaration: methods, associated functions and values, and operators. The compiler looks there and nowhere else.

```ren
pub type Stack<T> = opaque { items: Array<T> }
  pub fn push(inout self, x: T) = &self.items.push(x)
  pub fn peek(self) -> Option<T> =
    let n = self.items.len()
    if n == 0 then None else Some(self.items[n - 1])
  pub fn len(self) -> Int = self.items.len()
  pub fn of(xs: Array<T>) -> Stack<T> = Stack { items: xs }
  pub let empty: Stack<T> = Stack { items: [] }
  fn grow(inout self) = ...                     // private to this module

fn main() uses Console =
  var s = Stack.empty                           // an associated value
  &s.push(1)                                    // Stack.push(&s, 1)
  print(s.peek())                               // Some(1)
  let t = Stack.of([7, 8, 9])                   // an associated function
  print(t.len())                                // 3
```

Each member is written like an ordinary function or `let`, and a `pub` one spells out its signature like any public function. A first parameter named `self` makes it a method, with the type it's declared under as its type, and `x.m(args)` means `Type.m(x, args)`. `m` is found through `x`'s type, the same way a field is. A method that changes its receiver takes `inout self`, and the call marks it: `&s.push(1)`, just as `&xs.push(x)` means `Array.push(&xs, x)`. Leaving out that `&`, or writing it before a method that doesn't change its receiver, is an error. Without `self` it's an associated function, called as `Stack.of(...)`. A `pub let` is an associated value: it's pure, and it's made once when the program starts. A member is private unless it's marked `pub`.

A sum type written over lines lists its variants first, each starting with `|`, and then its members at the same indentation. The first line that doesn't start with `|` ends the variants; a blank line between them is the convention:

```ren
pub type Light =
  | Red
  | Green

  pub fn next(self) -> Light =
    match self
      Red => Green
      Green => Red
```

An `opaque` type gets its whole API this way. Inside its module it's its representation, so its methods can convert in both directions:

```ren
pub type UserId = opaque Int
  pub fn new(n: Int) -> UserId = n
  pub fn raw(self) -> Int = self
```

Operators go in the same place: an operator is a method with a reserved name, so `a + b` is `a.add(b)`, and `-a` is `a.neg()`. The names are `add`, `sub`, `mul`, `div`, `rem` and `neg`, and `zero` and `one` are associated values. There are no new operator symbols, and an operator is found on its left side's type, nowhere else ([operators.md](operators.md)):

```ren
pub type Vec = { x: Float, y: Float }
  pub fn add(self, b: Vec) -> Vec = Vec { x: self.x + b.x, y: self.y + b.y }
  pub fn mul(self, k: Float) -> Vec = Vec { x: self.x * k, y: self.y * k }
  pub let zero: Vec = Vec { x: 0.0, y: 0.0 }
  pub fn length(self) -> Float = (self.x * self.x + self.y * self.y).sqrt()
```

An operator can be written once for each type on its right, the one place a name is defined more than once, and the right side's type chooses which. Inside its module an opaque type is its representation, so `self + d.in_ms()` adds two `Int`s:

```ren
pub type Time = opaque Int
  pub fn add(self, d: Duration) -> Time = self + d.in_ms()
  pub fn sub(self, t: Time) -> Duration = Duration.ms(self - t)
  pub fn sub(self, d: Duration) -> Time = self - d.in_ms()

let deadline = Clock.now() + Duration.seconds(30)   // a Time
let waited = Clock.now() - started                  // a Duration
```

Writing it the other way round, `Duration.seconds(30) + now`, is an error that says `+` is found on its left side's type and suggests swapping them. A reserved member spells out what it takes and gives, can't fail or use a dependency, since `a + b` has no `try` in front, and is public whenever its type is.

`==`, `hash` and `show` are derived for every type, by its structure, except that a type with a function in it has no `==` or `hash`: comparing two functions is a compile error, never a panic. `key` is the one way to change what equal means, and equality, hashing and ordering all go through it, so they can't disagree. `eq`, `hash` and `compare` can't be written:

```ren
pub type Email = opaque Str
  pub fn of(s: Str) -> Email = s
  pub fn key(self) -> Str = self.lower()

assert Email.of("Ann@Example.com") == Email.of("ann@example.com")
```

`<` and the other comparisons need an order, which is derived only where it's obvious: `Int`, `Float`, `Str` (by bytes) and `Bool`, a sum type with no fields, by the order of its variants, a `with numeric` type, and anything with a `key`, by its key. A record, or a sum type with fields, is ordered only through its `key`, so reordering its fields can't change a sort.

An opaque number type gets its arithmetic with `with numeric`:

```ren
pub type Money = opaque Int with numeric
  pub fn dollars(n: Int) -> Money = n * 100

let total = price * 3 + shipping - discount
if total > budget then fail OverBudget(total - budget)
```

It gives `+` and `-` of two, negation, `zero`, comparison, and `*` by a plain `Int` (or `Float`, for `opaque Float with numeric`), and nothing else: `Money * Money` isn't a `Money`, and `/` says how it rounds, so it's written by hand, `pub fn div(self, n: Int) -> Money`, as is `pub fn mul(self, b: Meters) -> Area`. Literals don't convert: it's `Money.dollars(5)` or `Money.zero`, never `5`.

Generic code uses operators on a type parameter, and the compiler works out what it needs. Public signatures spell out everything else, `uses` and `!` included, but not this:

```ren
pub fn sum<T>(xs: Array<T>) -> T =
  var acc = T.zero
  for x in xs
    acc = acc + x
  acc
```

`ren types` shows it as `sum<T has add, zero>`, and `sum([true, false])` is an error where it's called: `` `Bool` has no `+`, which `sum` needs ``. The built-in `[true, false].sum()` gives the same error, and its help says to count them with `count`. In generic code an operator is the one of the same type on both sides.

Numbers follow a few rules, so nothing surprises at runtime. `Int` is 64 bits everywhere and overflow panics in every build, as an out-of-bounds index does; wrapping is a method, `n.wrapping_add(1)`. `/` and `%` round toward zero. `Float` is a 64-bit double, and a literal's type is read from its spelling: `1.5` is a `Float` and `1` an `Int`, always. Numbers never convert by themselves, so `Float.of(n)`, `f.round()` and `f.truncate()` say where they do. There's no `NaN`: `0.0 / 0.0` panics, so `Float` is ordered and hashed. And a condition is a `Bool`, always.

A `Map` and a `Set` find a key by its `hash` and `==`, so a key is any type without a function in it, `Map<Email, User>` included, equal by its `key`. Both keep insertion order: going over one gives what was set first, first, so output never depends on a hash seed, and the seed is the runtime's own. A key that isn't there is ordinary, so `m.get(k)` gives an `Option`, and there's no `m[k]`. There's no literal syntax either: `Map.of([(k, v)])` and `Set.of([x])`, which leaves `{ }` to records.

```ren
var users: Map<Email, User> = Map.empty
&users.set(u.email, u)
let ann = users.get(Email.of("ann@example.com")) orelse fail NoSuchUser
for (email, u) in users
  print(u.name)
```

`(a, b)` and `(a, b, c)` are tuples: two or three values passed together, taken apart only by patterns, `let (k, v) = pair`, `for (i, x) in xs.with_index()`, or a `match`. There's no `.0`: what wants names is a record. A range, `a..b`, is counted by a `for`, from `a` up to, but not including, `b`, and there's one kind: `for i in 0..xs.len()`.

`Array` takes its method names from Ruby's `Enumerable`: `map`, `flat_map`, `select`, `reject`, `find`, `index`, `any`, `all`, `count`, `includes`, `reduce`, `sum`, `min`, `max`, `min_by`, `max_by`, `sort`, `sort_by`, `group_by`, `partition`, `tally`, `uniq`, `zip`, `with_index`, `first`, `last`, `take`, `drop` and `reverse`, and `xs.get(i)` for an index that may not be there. A `Map` has them over its `(k, v)` pairs, and a `Set` over its members, except `index`, `uniq` and `tally`, which mean nothing without repeats or places; a `Map` has no `sum`, and its `includes(k)` and `get(k)` take a key. Those that keep some of a `Map`'s pairs, such as `select`, `take` and `reverse`, give a `Map`, and a `Set` gives a `Set` the same way. A method that changes nothing gives a new collection, `xs.sort()`, and there's one name for each: no `filter` beside `select`, and `xs.filter(...)` is an error whose help says `select`. A function a method takes is only called, so what it fails with and uses, the call does: `try xs.map(load)`.

Only the module that declares a type can write its members. To extend a type you don't own, write a function in your own module or wrap it in an `opaque` type. Because lookup only ever checks the type's own definition, there are no orphan rules, no coherence puzzles, and no slow search.

---

## Memory without a GC

Ren uses compiler-managed reference counting with in-place reuse ([Perceus](https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse/)). There's no garbage collector and no lifetimes. Reference counting never leaks, because safe Ren can't form a cycle:

- Values are immutable once shared, and `a.next = Some(a)` stores a copy of the old `a`, not `a` itself.
- There are no recursive values (no `let rec` on data).
- Local recursive functions are compiled as top-level functions, so a block never captures itself.
- Blocks can't be stored or returned, so no value holds one.
- Blocks never capture handlers, because dependencies are looked up at the call site.

In the safe subset, Ren aims for Rust-level memory safety without lifetimes. Safety comes from reference counting and value semantics at runtime rather than a borrow checker at compile time. Borrow inference, moves on last use, `unique`, and arenas eliminate most of the counting work.

Allocation is a dependency like any other:

```ren
pub fn parse(src: Str) -> Ast ! ParseError
    uses Alloc = ...

fn handle(req: Request) -> Response
    uses Users, Alloc =
  with alloc.arena(req.budget) in               // everything inside freed in O(1)
    respond(try decode(req))                    // only the response escapes (copied out)
```

You choose how much the compiler guarantees:

| You write | You get |
|---|---|
| nothing | reference counting with in-place reuse where possible |
| a `unique` parameter | in-place updates guaranteed; the runtime check is removed |
| no `Alloc` in `uses` | no allocation and no frees, proven; a hidden copy becomes a compile error |

Freeing memory is also the job of `Alloc`, so real-time code without `Alloc` can't stall on a large drop. It has to hand dying values off instead:

```ren
fn audio_cb(inout synth: Synth, inout out: Buf)
    uses Reaper =
  if synth.patch_changed then
    Reaper.send(&synth.swap_patch())      // freed later, on a normal thread
  render(&synth, &out)
```

Memory layout is part of the type, not part of the loop:

```ren
type Particle = {
  pos: Vec3,
  vel: Vec3,
  mass: Float,
  cold name: Str,                 // stored out of line, never pulled into hot loops
} where size <= 64                // compile error if it outgrows a cache line

fn step(inout ps: Array<Particle, soa>, dt: Float) =
  for p in &ps
    p.pos += p.vel * dt           // switch soa ↔ aos with one word; the body doesn't change
```

---

## Allocation model

"No `Alloc`, no allocation" is only useful if you can predict allocation by reading the code. These rules make that possible.

**What lives on the heap.** Scalars, records, tuples, and non-recursive enums are inline values, so `Some(i)`, `Vec3`, and `Pro(seats: 5)` never allocate. Heap values are `Array`, `Str`, `Map` and `Set`, recursive types (boxed only where they recurse), and `cold` fields.

**What counts as allocating.** Creating or growing a heap value, copying a shared value before changing it (copy-on-write), and freeing a value whose count reaches zero.

**How it's checked.** The compiler inserts reference-count operations, copies, and frees, then checks the result. A copy or free inserted into a function without `Alloc` is a compile error that points to the line that caused it. There's no separate proof system: an inserted allocation is a dependency call like any other, checked by the same rules as `uses`.

**Parameters.** Read-only parameters are borrowed and cost no reference counting. For an `inout` parameter, the caller makes the value unshared before the call, so any copy is charged to the caller. A `unique` parameter transfers ownership.

**Blocks.** A block is never heap-allocated. That's a language guarantee, not an optimization that might fail. A block can't be stored or returned, so it lives on the stack of the call it's passed to. (Today's interpreter still copies what a block captures when it's made.)

**Generics.** A requirement on a type parameter, `T has add`, which the compiler infers, works like a transparent parameter. `sum<Int>` doesn't allocate; `sum<BigInt>` uses `Alloc`, because `BigInt.add` does.

**Panics.** A panic in a function without `Alloc` uses a message formatted at compile time and aborts.

**Growth.** `push` needs `Alloc`. Code without `Alloc` works in buffers whose capacity the caller set, using `push_within`.

In practice, code without `Alloc` is linear: every value it owns has to be returned, passed on, or handed to `Reaper`. That's a deliberate tool for hot paths and real-time code, not how most Ren code is written.

### Arenas

Inside `with alloc.arena(budget) in`, `Alloc` is the arena. Handlers installed further out fixed their own `Alloc` when they were installed, so their allocations never land in the arena. A value from an arena can reach longer-lived storage in exactly four places, and the compiler knows all of them:

1. the block's return value
2. a write into handler state
3. the flight recorder
4. `Reaper.send`

At each of these, a value tagged as arena memory is copied out. Nothing else pays for the check. The return value is copied with forwarding pointers, so shared structure stays shared. The arena is about to be freed, so it's safe to overwrite it.

An arena also works as a per-request memory limit: a request that exceeds `req.budget` fails instead of exhausting the server.

---

## Concurrency

Ren has no `async` or `await` and no colored functions. `Async` is a dependency like `Clock`, and concurrency is structured: no task outlives the call that started it, and a failure in one task cancels the others.

```ren
pub fn dashboard(ids: Array<UserId>) -> Array<Summary> ! Timeout | FeedError
    uses Users, Net, Async =
  Async.timeout(2.s) fn() =>
    Async.map(ids) fn(id) =>
      summarize(id, try load_feed(id))
```

Four rules hold everywhere. No task outlives its call. A failure cancels its siblings, and the first one wins. A handler's state is touched by one task at a time between dependency calls. And everything has a limit: `Async.map` runs 64 at once unless told otherwise. Cancellation can't be caught, and work that finished is never reported as timed out. Tests run on virtual time with a seeded scheduler, so `ren test --seeds 1000` tries a thousand interleavings and `--seed` replays one. The design is in [async.md](async.md).

Shared data is immutable, mutable data has exactly one owner, and handler state is exclusive between dependency calls, so data races can't happen. Logic races are still possible, but only at dependency calls, which is where the simulation scheduler looks for them. Values with a single owner move between threads for free, and only values that are actually shared pay for atomic reference counts.

---

## FFI and `trust`

```ren
extern "z" fn crc32(seed: u32, p: Ptr<u8>, n: usize) -> u32

pub fn crc(data: Bytes) -> u32 =
  trust crc32(0, data.ptr(), data.len())        // the one audit point: greppable
```

Raw pointers and FFI require `Unsafe`. A `trust` block wraps unsafe code behind a safe signature. `ren why --unsafe` lists every `trust` in your dependency tree.

---

## Why this is possible: knowledge × control

Ren's distinctive features come from two properties that no mainstream language has at the same time:

- **Knowledge.** The language rules give the compiler complete knowledge of every boundary a program crosses. Nothing reaches the outside world except through `uses`, values never change under you, signatures are complete, and structured concurrency records who spawned whom.
- **Control.** Ren owns the whole stack, including the compiler, runtime, codegen, fibers, allocator, and reference-count headers. That's what makes acting on the knowledge nearly free.

```
                     low control                  high control
               ┌──────────────────────────┬──────────────────────────┐
 high          │ Effect TS, Haskell       │                          │
 knowledge     │ knows the effects, but   │   Ren                    │
               │ pays at runtime on a     │                          │
               │ GC / JS runtime          │                          │
               ├──────────────────────────┼──────────────────────────┤
 low           │ Go, Java, Python         │ Rust, Zig, C             │
 knowledge     │ OTel via libraries and   │ full control, but any    │
               │ monkey-patching          │ function can syscall or  │
               │                          │ mutate anything          │
               └──────────────────────────┴──────────────────────────┘
```

That's why principles 1 and 2 rank at the top. A single hole, such as an unchecked FFI call or a global, would quietly make simulation, replay, and tracing untrustworthy.

---

## Test, trace, replay, profile: built in

> **Ren knows every boundary your program crosses, so it can test, trace, replay, and profile them without instrumentation code.**

Every interaction with the outside world is a typed dependency call that the compiler knows about statically. That one fact supplies a single event stream to four tools:

```
                      one event stream, one task tree
 dependency calls  ──▶ [ Users.get | Billing.charge | Net.get | ... ]
                          │           │           │           │
                       observe     simulate     replay     profile
                      (record)    (fake all)   (feed back  (time, allocs,
                                                recorded)   reuse misses)
```

*All planned.*

### Specifications, and data from your types

A test sees what an importer sees, so it's a specification, and a test with parameters is a property test. Every type generates itself, an opaque one only through its own constructors, so a value its module wouldn't allow never appears. A failure shrinks without a shrinker, because shrinking replays the `Random` dependency's choices with smaller ones:

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
```

Ren knows the sum types and the errors, so the report says what was exercised (`outcome: ok 12 · Overdrawn 88`) and warns when most cases took the error path. Exploring is `ren console`: inside a module, on test implementations unless you name real ones, showing each effect, and `:spec` turns a session into a test. The design is in [testing.md](testing.md).

### Deterministic simulation testing

Run your system under a seeded fake scheduler, clock, network, and disk. Every failure replays exactly.

```ren
type Task = | Writer | Reader

test sim "log survives S3 flakiness and crashes" (seed) =
  with sim.scheduler(seed), sim.clock, sim.s3(seed, fail_rate: 5%), sim.crash(seed) in
    let log = DurableLog.open("bucket")
    Async.map([Writer, Reader]) fn(task) =>
      match task
        Writer => write_some(log)
        Reader => read_some(log)
    assert DurableLog.recover("bucket").is_prefix_consistent()
```

```
$ ren test --sim --seeds 10000
  ✗ seed 7731: lost acknowledged write after crash at step 412
$ ren test --sim --seed 7731 --trace           # replays exactly, every time
  step 409  writer  S3.put(seg-00041)  → ok
  step 410  writer  ack(offset 40960)
  step 411  sim     S3.put(manifest)   → timeout
  step 412  sim     CRASH
```

The compiler flags any code that can't be simulated, meaning anything with `Unsafe` or FFI in its dependencies, so a passing simulation never gives false confidence.

Ren controls the other sources of nondeterminism too:

- **Hashing.** Maps and sets keep insertion order, so iteration replays exactly, and the hash seed is the runtime's own, which nothing can observe.
- **Addresses.** Safe code can't compare, hash, or order values by memory address.
- **Floats.** Arithmetic is strict IEEE. The C backend disables fused multiply-add contraction and fast-math.
- **Math functions.** Ren ships its own `sin`, `exp`, and the rest instead of using the platform's C library, so a trace recorded on x86 replays identically on ARM.
- **Freeing.** When a value is freed, including by `Reaper`, is never observable.

### Observability without the overhead

OpenTelemetry is expensive because it pays before deciding whether data is needed: it allocates spans, formats strings eagerly, propagates context, and serializes on hot threads. Ren avoids each of those costs:

- **Static metadata, tiny events.** Span names, source locations, and argument types are extracted at compile time (the [NanoLog](https://www.usenix.org/conference/atc18/presentation/yang-stephen) technique). A runtime event is a fixed-size binary record with no strings and no maps.
- **Deferred serialization for free.** Values never change, so an event holds a reference instead of an eager copy. Formatting happens off the hot path, or never. The reference doesn't increment the count, which would make the value look shared and turn in-place updates into copies. Instead it sets a *recorded* bit in the same word as the count. The existing "is this unshared?" check already fails when the bit is set, so the fast path costs nothing extra. The slow path serializes the old value just before it's changed in place, takes ownership instead of freeing when the count reaches zero, and serializes any recorded arena values when the arena exits. Values that are already shared get an ordinary increment, since they're never updated in place anyway.
- **Context propagation is the task tree.** Structured concurrency already says who spawned whom, so there are no thread-locals and no `ctx`.
- **Zero cost when off.** When no recorder is installed, instrumentation isn't compiled in. When one is installed, the cost is one predictable branch per call site.
- **Flight recorder instead of head sampling.** Everything goes into per-task ring buffers, and Ren decides at the end of the request whether to keep it (on error, or when slow). Tail sampling happens in-process.
- **Traces, metrics, and logs are one stream.** Metrics are derived from events, so there's no separate API.
- **Secrets can't leak.** `type ApiKey = secret Str` is never recorded or printed.

```ren
fn main() ! StartupError
    uses Os, Net, Alloc =
  let cfg = try Config.from_env()
  with trace.flight_recorder(keep: trace.errors_or_slower_than(500.ms), level: Replayable),
       trace.otlp(cfg.collector),               // works with existing backends
       pg_users, stripe_billing in
    http.serve(cfg.port, routes)
```

Business code doesn't change: every dependency call is already a span. Pure work can be marked explicitly:

```ren
let price = trace.span("pricing.compute", seats: seats) fn() =>
  compute_price(plan, seats)
```

### Replay production bugs locally

Recording levels share one schema:

| Level | Records | Use |
|---|---|---|
| 0 | nothing | compiled out |
| 1 | timings and IDs | traces and metrics |
| 2 | + arguments | debugging |
| 3 | + dependency results | exact local replay |

```
$ ren trace pull --request 8812
$ ren replay trace-8812.bin
  ✗ panic: index 17 out of bounds  (pricing.ren:88)
```

### Native profiling

Every wait goes through a dependency, so wall time breaks itself down:

```
$ ren profile --request 8812
  412ms total
  ├─ 301ms  Users.get        (waiting, 3 calls)     users.ren:12
  ├─  62ms  Billing.charge   (waiting)              users.ren:14
  ├─  41ms  CPU: compute_price                      pricing.ren:30
  └─   8ms  CPU: other
```

Ren can also profile things other languages can't see:

```
$ ren profile --reuse            # where in-place updates failed, and why
  pricing.ren:44   map over `rows`   reuse hit 2%   shared with `snapshot` (line 41)
  feed.ren:19      buf.push          COW copy 12×   shared by `head` (line 17)
```

Performance tests are deterministic, so they're never flaky:

```ren
test sim "dashboard has no N+1" (seed) =
  with sim.world(seed), profile.count in
    dashboard(ids_100)
    assert Profile.calls(Users.get) <= 1
    assert Profile.allocs() <= 50
```

Production profiles feed back into release builds (`ren build --release --pgo profile.bin`), so the compiler spends its specialization budget on the code that's actually hot.

### What else falls out

- **Swap anything in tests.** No mocking library, just a different `with`.
- **Dependencies can't phone home.** A dependency that gains `Net` in an update fails your build.
- **Performance contracts survive refactors.** A no-`Alloc` hot path that starts copying is a compile error.
- **Semantic diffs.** `ren diff main..pr-412` shows behavior changes, such as "`checkout` now uses `Net`."
- **Hermetic builds.** Compile-time code has no network, clock, or environment access, so builds are reproducible by construction.

**Costs:** the trace recorder is the one privileged dependency, woven into call sites by the compiler. Flight-recorder buffers keep values alive until a request ends, so they need a byte budget. Recorded values larger than a size cap keep only their length and hash when they're changed in place, and `inout` buffers are recorded that way by default at level 2. Level 3 has to store what each dependency returned, including every byte `Fs.read` produced. That cost comes with exact replay itself, not with this design. Generated C keeps frame pointers (about 1–2%) and emits `#line` directives, so tools point at `.ren` source. CPU time inside pure code still needs a sampler.

---

## Errors are part of the design

```
error: `dashboard` doesn't declare `Clock`
   ┌─ src/feed.ren:31:5
31 │     summarize(id, try load_feed(id))
   │                       ^^^^^^^^^^^^^ needs Clock
   │
   = via: dashboard → load_feed → retry → Clock.sleep   (src/feed.ren:22)
   help: add `Clock` to `uses` on `dashboard`
```

```
warning: `buf` is shared by `head`, so `push` copies the buffer
   ┌─ src/frame.ren:14:1
13 │ let head = buf
   │            --- `head` keeps `buf` shared
14 │ &buf.push(0)
   │ ^^^^^^^^^^^^ copies
   help: keep only what `head` needs:  let head = buf.take(16)
```

Every error points to the code that caused it, explains why, and offers a concrete fix. An error message that doesn't do all three counts as a bug.

---

## Tooling

One binary, with one way to do each thing.

```
$ ren new shop && cd shop
$ ren run
$ ren test                        # unit, property, and simulation tests
$ ren fmt                         # one style, no configuration
$ ren why upgrade                 # what does this function touch, and where from?
  upgrade -> User ! NotFound | PaymentFailed | Conflict
    uses Users    ← Users.get, Users.save   (users.ren:12, 16)
    uses Billing  ← Billing.charge          (users.ren:14)
$ ren build --release
  shop  1.9 MB  static
```

Dependencies are vendored source, Go-style, with no package registry by default.

---

## Trade-offs

Ren gives some things up on purpose:

- **No shared mutable references.** Graphs, doubly linked lists, and observers use indices, generational handles, or a handler that owns the state. This is the same style serious Rust code converges on.
- **No multi-shot continuations.** Handlers resume at most once. Generators and async still work. Backtracking search is written explicitly.
- **Error tags are structural.** Like OCaml's polymorphic variants, two `Timeout`s with the same shape are the same error, whichever library they come from, and two with different shapes can't share an error set until one is renamed. Use payloads or more specific names to tell them apart.
- **Values from other modules are always qualified.** You write `stripe.charge`, never a bare `charge`. Methods are found through the type (`xs.map(f)`), so everyday code stays short.
- **Allocation-free code is linear.** Without `Alloc`, every owned value must be returned, passed on, or handed to `Reaper`.
- **Reference counting isn't free.** Expect some overhead on pointer-heavy shared data. Arrays of plain values carry one count in total, not one per element. Expect roughly 1–1.5x of Rust on typical code (a target, not a benchmark).
- **Safety is checked at runtime, not proven at compile time.** Ren's safety rules (uniqueness, arena escape, the no-free rule) are new combinations. They need precise specs, sanitizer-checked tests, and fuzzing before anyone can claim they match Rust.
- **No operations on types you don't own.** Write a function in your own module, or wrap the type in an `opaque` type.
- **Dependencies are ambient.** Knowing which implementation answers a call depends on tooling: hover and `ren why` are first-class features.
- **It's new.** No ecosystem, no Stack Overflow, and LLMs don't know it yet.

---

## Prior art

Ren is mostly a new combination of existing ideas. It owes a lot to:

- **[Koka](https://koka-lang.github.io/):** row-typed effects, evidence passing, Perceus reference counting, functional-but-in-place
- **[Roc](https://www.roc-lang.org/):** the closest relative. It shares the RC + Perceus core, a fast compiler, and a split between quick debug builds and release builds that specialize. Roc keeps apps pure and puts systems work in a separate "platform" host. Ren puts both in one language, with named, typed dependencies instead of a pure/effectful split.
- **[Lean 4](https://lean-lang.org/):** borrow inference, functional-but-in-place arrays
- **[Hylo](https://www.hylo-lang.org/) and Swift:** mutable value semantics, `inout`, reentrant actors (the model for handler state)
- **OCaml:** polymorphic variants, the model for Ren's error tags; Rémy-style row unification underneath both errors and `uses`; type-directed lookup of constructors and fields
- **OxCaml:** uniqueness and locality modes
- **[Lambda set specialization](https://www.cs.princeton.edu/~mpmilano/publication/lss/) (PLDI '23):** narrowing a call through a function value to a switch over the few the program can pass there, which release builds do for handlers
- **[Zig](https://ziglang.org/):** explicit allocation, comptime, minimalism
- **Go:** stdlib-first, one-binary tooling, always-qualified imports, `internal/`, one version of each dependency
- **[Effect](https://effect.website/):** typed dependencies, layers, structured concurrency
- **FoundationDB, TigerBeetle, Antithesis:** deterministic simulation testing
- **NanoLog, `defmt`, `rr`:** static log extraction, record and replay
- **Elm and Gleam:** errors written for humans, small languages that fit in your head

---

## Implementation

- The compiler is written in **OCaml**.
- The backend emits **C**: `tcc` for fast debug builds, `clang -O2` (or `zig cc`) for release builds, and Wasm through the same path. A naive C backend comes before the memory stage, so Ren runs natively early and every later stage is measured.
- Every function takes the implementations installed where it's called as one hidden parameter, an evidence vector, which a dependency call searches by the dependency's identity ([deps.md](deps.md#how-it-runs)). Release builds specialize each dependency call for the handler known to be installed there, so it becomes a direct, inlinable call, within a specialization budget, and a block for the call it's passed to.
- What Ren is measured against is in [vision.md](vision.md). How it tests, specifications, test items, conformance groups, property tests and the console, is in [testing.md](testing.md). The stages ahead are designed in [handlers.md](handlers.md) (wrapping and the journal), [async.md](async.md) (concurrency), [shapes.md](shapes.md) (shapes and build time), [stdlib.md](stdlib.md) and [runtime-io.md](runtime-io.md).
- How functions are values, how a call finds its code, and how tasks run on many cores, decided after stage 10b and reversing parts of the documents above, is in [foundations.md](foundations.md).
- How the compiler is laid out, the passes and the languages between them, what each promises and what checks it, and the rules every pass keeps, is in [compiler.md](compiler.md).
- Modules, name lookup, interface summaries, and the content-addressed build are designed in [module-build.md](module-build.md). Every compiler pass is a pure function of one module or call-graph group plus the interfaces of its imports.
- Golden tests cover every example and every error message from day one. All generated C runs under ASan and UBSan, and the interpreter and native backend are differentially tested against each other.

---

## Roadmap

| Stage | Adds | Done when |
|---|---|---|
| 1 | lexer, parser, indentation, functions | `fib(30)` runs |
| 2 | records, sum types, exhaustive `match` | missing-case errors fire |
| 3 | type inference, row unification for errors and `uses` | private functions need no annotations |
| 4 | `var`, `inout`, `&`, value semantics | `normalize(&scores)` works |
| 5a | files as modules, `import`, `pub`, `opaque`, lookup through types, interface summaries, `uses` on signatures | a program of four modules with shared constructor names checks (done) |
| 5b | methods, associated functions and values under their type; `dbg` | `&xs.push(x)` checks (done, except `dbg`) |
| 6 | `!`, `try`, `fail`, `match` on errors, `attempt`, `orelse`; `&&`, `\|\|`, `not` ([errors.md](errors.md)) | the shop, the VM and the bank fail with errors, not values (done) |
| 7 | `dep`, `uses`, `with`, `handler`, `Clock`, `Random` and `Console`; `test`, `group`, `assert`, `ren test` ([deps.md](deps.md)) | the bank's tests run on the test implementations, with no `with` (done) |
| 8 | `Str` and `Bytes`, `Fs`, `Os`, `Proc`, `Path`, each with real and in-memory implementations | a small [just](https://github.com/casey/just) runs, and its tests run on `mem_fs` and a fake `Os` and `Proc` (done, as a slice: `Os` has only `args`, and `Proc.run` doesn't capture output) |
| 9 | operators, derived equality and hashing, arithmetic for opaque number types, `Map` and `Set`, tuples, ranges and the collection methods ([operators.md](operators.md)) | `Map<Email, User>` works (done: 9a, operators, `key`, `with numeric`, `Int` and `Float`; 9b, tuples, ranges, `Map`, `Set` and `Enumerable`'s methods, and the bank keeps its accounts in a `Map`) |
| 9c | boundaries: a type that keeps rules is opaque; a test sees what an importer sees, with test items; `ren console` ([testing.md](testing.md), [module-build.md](module-build.md#private-unless-pub)) | the bank's `Account` and `Bank` are opaque, and its tests are specifications (done) |
| 10.0 | one constraint solver, typed Core, requirements passed as dictionaries, lambda sets in function types (removed in 10c) ([compiler.md](compiler.md)) | every stage-10.0 step passes its check (done) |
| 10a | `with` as a set, `over` and `next`, `finally`, handler state that can fail ([handlers.md](handlers.md)) | the prices cache wraps a real `Prices`, and a transaction commits or rolls back (done) |
| 10b | **the journal**: `ren run --record`, `ren replay`, `--trace`, journals as tests, and the console's `:reload` and `:spec` ([handlers.md](handlers.md#the-journal), [testing.md](testing.md)) | the `just` replays exactly: what it did through `Console`, with no disk read and nothing run (done) |
| 11 | `Async` and `Net`: structured concurrency, cancellation, tasks in handlers, deterministic tests on virtual time ([async.md](async.md)) | a server shuts down gracefully, and `ren test --seeds` finds the `cached` race |
| 12 | the standard library for a web service and the compiler: `http`, `json` and `cli` over shapes, top-level `let` and `assert`; property tests and `ren fuzz` ([stdlib.md](stdlib.md), [shapes.md](shapes.md), [testing.md](testing.md)) | a small web service and its tests, specifications and properties, run interpreted |
| 13 | a naive C backend, emitting Core with reference counting and no optimizations; packages, `ren build` with a content-addressed cache | native binaries, rebuilt incrementally; debug builds measured against Go ([vision.md](vision.md)) |
| 14 | memory: specialization, defunctionalization, borrow inference, reference counting with reuse ([compiler.md](compiler.md)) | `map` reuses memory in place; the benchmarks measured against Rust ([vision.md](vision.md)) |
| **↑** | **native Ren** | **the web service runs natively, within the bars** |
| 15 | `Alloc` as a dependency, arenas, no-alloc checking | `checksum` provably never allocates |
| 16 | `unique`, layout (`soa`, `cold`, `where size`) | hot loops run with zero copies |
| 17 | the full simulation scheduler, flight recorder, profiler | a failing seed replays exactly |
| 18 | the compiler, rewritten in Ren | it compiles itself |
| **↑** | **Ren 1.0** | **flottning, rewritten in Ren, passes 10,000 simulation seeds** |

The **effect journal** in stage 10b, the record of every dependency call, is the most important design artifact after the type system ([handlers.md](handlers.md#the-journal)). Simulation, replay, migration, and traffic replay all depend on it. If the format is right, those features are extensions. If it's wrong, each one becomes a rewrite.

---

## Beyond 1.0

Once the language and its four built-in tools exist, the same knowledge-plus-control foundation enables a platform. All of this is long-term vision, not current scope.

```
 foundations:  uses/with ─┬─ sim scheduler ─┬─ effect journal ─┬─ flight recorder
                          │                 │                  │
               batching ◀─┘    fleet sim ◀──┤  traffic replay ◀┤
               read caps       model check ◀┘  time travel ◀───┤
               incremental                     migration ◀─────┘
```

### Wave 1

**Whole-fleet simulation.** A service-to-service call is just a dependency, so `with remote(Users, url)` in production becomes `with sim.node("users")` in tests. A whole fleet of Ren services, plus databases and object storage, runs in one deterministic process, with partitions, clock skew, and crashes.

```ren
test sim "checkout survives a partition" (seed) =
  with sim.cluster(seed, nodes: [api, users, billing], partition_at: 3.s) in
    assert eventually(all_orders_consistent)
```

**Exact incremental computation.** Pure functions are deterministic, and every input (files, config) arrives through a dependency, so results can be cached by content and invalidated precisely. `ren test` reruns only the tests whose code, or whose dependencies' code, actually changed. Build systems, data pipelines, and reactive UIs get the same treatment.

### Wave 2

**Model checking real code.** The simulation scheduler controls every interleaving, so for small configurations it can explore all of them instead of random samples. That's TLA+-style exhaustive checking run against your real code, not a separate spec.

```
$ ren test --model-check --nodes 3 --max-steps 40
  ✓ explored 2,184,331 interleavings, no violations
```

**Automatic batching.** Pure code between dependency calls can't observe their ordering, so concurrent lookups merge into a single query. N+1 queries get fixed, not just detected.

```ren
with batched(Users, max: 100) in
  Async.map(ids) fn(id) => Users.get(id)      // one query, not 100
```

**Read-only capabilities.** `uses Users.read` versus `uses Users.write`. The compiler then knows which functions are safe to retry, hedge, or cache, with no idempotency annotations.

### Wave 3

**Replay production traffic before you deploy.** Replay recorded traffic against a new build and diff the responses, errors, dependency calls, and allocations. "The tests passed" becomes "these 3 requests behave differently."

```
$ ren replay --traces last-hour/ --against ./new-build --diff
  4,912 requests  ·  3 behavior changes  ·  Users.get calls −38%
```

**Time-travel debugging.** Replay combined with immutable, structurally shared values makes stepping backwards cheap.

### Wave 4

**Hot reload with typed state migration.** State lives in handlers and values are immutable, so a running server can swap code between requests, migrating handler state with a type-checked function. It's Erlang-style hot code swapping, with types.

**Moving a request mid-flight.** Every interaction with the world is journaled, so a task can stop on one machine and resume on another by replaying its journal, without serializing a stack. This enables live migration, draining nodes without dropping work, and moving computation closer to its data.

**Data lineage.** `type Email = pii Str` lets the compiler track which logs, responses, and cache entries derive from personal data, so a deletion request becomes a query instead of an audit.

---

## Open questions

- Which dependencies are traced per call by default, and which only in aggregate (`Clock`, `Alloc`)?
- Does the journal designed in [handlers.md](handlers.md#the-journal) serve simulation and moving a request mid-flight as well as replay?
- How is `call` typed in a handler written for any dependency ([shapes.md](shapes.md#open-questions))?

Answered since: how much `comptime` reflection needs is [shapes.md](shapes.md), and handler ordering is written with `over` ([handlers.md](handlers.md)).

---

## License

TBD.

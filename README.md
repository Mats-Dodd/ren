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

> **Status:** early. Stages 1–4, 5a, 5b, 6, 7 and 8 of the [Roadmap](#roadmap) run in an interpreter: functions, records, sum types, exhaustive `match`, lambdas, type inference with `uses` rows, `var`, `inout`, `&` with value semantics over records and arrays, modules (files as modules, `import`, `pub`, `opaque` types, constructors and fields found through their type, and `uses` on signatures, checked against the body), methods, associated functions and associated values declared under their type, with `&` before a changed receiver: `&xs.push(x)` (see [examples/shop](examples/shop)), and errors: structural tags after `!`, named error sets, `fail`, `try`, `match` with `fail` arms, `try match`, `attempt` and `orelse`, with exact signatures on public functions, and `&&`, `||` and `not`; and dependencies: `dep` declarations, `with`, wrappers and `handler`s, the built-in `Clock`, `Random` and `Console`, minimal strings, and `test`, `group`, `assert` and `ren test`, with test implementations by default (see [examples/bank](examples/bank)); and the world, thinly: `Str`'s methods, on byte offsets, `Bytes`, `Path`, `Fs`, `Os.args` and `Proc.run`, with `mem_fs`, `test_os` and `test_proc` in tests, and `ren run file.ren -- args` (see [examples/just](examples/just)). Most examples in this README show how Ren is intended to look, not what runs today. Editor support: [Zed](editors/zed), on a [tree-sitter grammar](editors/tree-sitter-ren) checked against the compiler's parser.

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
2. **The world is a dependency.** Code reaches outside itself (network, disk, clock, memory) only through dependencies listed in `uses`.
3. **Nothing is found behind your back.** There's no trait search, no overloading, and no implicit conversion. Implementations are installed or attached to a type, never searched for.
4. **Values never change under you.** You can write `x.field = y`, but nobody else can observe it. The only state that outlives a call lives inside handlers, and a handler's state can only change between dependency calls.
5. **Costs that matter can be pinned.** A function that doesn't list `Alloc` doesn't allocate, and the compiler proves it.
6. **One mechanism, many uses.** Dependency injection, test fakes, allocators, middleware, simulation, and tracing all use the same `uses` / `with` mechanism.
7. **The compiler explains itself.** Every error explains why it happened and suggests a concrete fix.
8. **Enough out of the box.** One formatter, one test runner, one build tool, and a stdlib you can ship with.

A useful filter for any proposed feature: does it make function bodies read more like a script, or signatures more like a proof? If it does neither, cut it.

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
fn total(xs: Array<f64>) -> f64                // read-only parameter (default)
fn normalize(inout xs: Array<f64>)             // updates the caller's value
fn blur(unique img: Image) -> Image            // proven unshared, so in-place is guaranteed
```

Lambdas, with trailing-lambda syntax for multi-line bodies:

```ren
let names = users.map(fn(u) => u.name)

let summaries = async.par_map(users) fn(u) =>
  let feed = try load_feed(u.id)
  summarize(u, feed)
```

Inside brackets, where line breaks are otherwise ignored, a lambda's body can be a block too: a `=>` that ends its line opens one, indented further than the line around the brackets, and it ends at a line indented less, at a `,` before the next argument or field, or at the closing bracket:

```ren
let supplier = Supplier { quote: fn(item) =>
    Clock.sleep(Duration.ms(20))
    try prices.get(item)
}
```

Public functions spell out their full contract. Private functions can infer their `uses` and their error set (`! _`). `ren fmt --annotate` writes the inferred clauses into your code.

A function parameter is **transparent** when the function only calls it: it doesn't store it, return it, or hand it to something that outlives the call. A transparent parameter's errors and dependencies flow into the caller automatically, so they're never written:

```ren
pub fn map<T, U>(xs: List<T>, f: fn(T) -> U) -> List<U>
pub fn par_map<T, U>(xs: List<T>, f: fn(T) -> U) -> List<U> uses Async
pub fn timeout<T>(d: Duration, f: fn() -> T) -> T ! Timeout uses Async
```

Calling `par_map` with a lambda that can fail with `FeedError` and uses `Net` makes that call fail with `FeedError` and use `Net`. `par_map` is still transparent even though it runs `f` on other tasks, because structured concurrency guarantees those tasks finish before it returns.

A function that stores a closure names the closure's errors and dependencies with `..e` and `..d`:

```ren
type Button = { label: Str, on_click: fn() ! ..e uses ..d }
```

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

Error tags work like OCaml's polymorphic variants. They're structural and need no declaration: `fail NotFound` and `fail PaymentFailed(reason: "card declined")` just work. Tags aren't values: they appear only after `!`, after `fail`, in `fail` patterns, and inside `Err(...)`, so a test can compare what `attempt` kept, `assert attempt f() == Err(NotFound(id))`. A name for a set of tags is declared with `!`:

```ren
type BillingError = ! PaymentFailed(reason: Str) | CardDeclined

pub fn checkout(cart: Cart) -> Receipt ! BillingError | NotFound
```

A public function lists its errors exactly, so a signature can get long. That's the contract: callers handle what can happen and nothing else.

When a call fails, whatever it changed before failing stays changed. For all-or-nothing, change a copy and keep it only if nothing failed: `var draft = self`, then `self = draft` at the end. A statement whose value isn't `()` is an error, so a result can't be dropped without a word; `let _ = ...` drops it on purpose. The whole design, and why, is in [errors.md](errors.md).

Tags only have to agree where they meet. `Timeout` from `async.timeout` and `Timeout` from your own code are the same error if they have the same shape. If one error set would contain two shapes of the same tag, such as `Timeout(ms: Int)` and a plain `Timeout`, that's a compile error asking you to rename one. So adding a dependency never breaks code that doesn't touch it.

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

The built-in dependencies are `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc` today, then `Net` and `Async` (stage 9), `Alloc` (stage 13) and `Unsafe`. There is no catch-all `Io`. Even `print` goes through one: it's an ordinary prelude function, `Console.write(show(x))`. `Time`, `Instant` and `Duration` come with `Clock`, and `Str` arrives at its smallest: literals, `==` and `show`. Stage 8 gives it methods, and `Bytes` and `Path` with it.

The runtime installs exactly the built-ins `main` lists in its `uses`, outermost. Any other dependency has to be installed inside `main`, and leaving it out is a compile error, `nothing installs Users before main`, with a help that says how.

```ren
pub fn checksum(data: Bytes) -> u32 =          // no `uses`: pure, cannot allocate
  var h: u32 = 2166136261
  for b in data
    h = (h ^ b.u32) *% 16777619
  h
```

The whole design, and why, is in [deps.md](deps.md).

### 6. `with`: installing implementations

An implementation is a value of the dependency's type. A stateless one is a record of its operations, and a dependency can offer one as a member:

```ren
pub dep Clock =
  now:     fn() -> Time
  instant: fn() -> Instant
  sleep:   fn(d: Duration)

  pub fn frozen(at: Time) -> Clock =
    Clock { now: fn() => at, instant: fn() => Instant.zero, sleep: fn(_) => () }
```

`with` installs it around a body:

```ren
fn main() ! StartupError
    uses Os, Net, Alloc =
  let cfg = try Config.from_env()
  with sql.pool(cfg.db_url), pg_users, log.json in
    http.serve(cfg.port, routes)
```

Production wiring, test fakes, allocators, simulators, and tracers all use the same mechanism. A long list of items can break after a comma, the next line indented further. Any line outside brackets that ends in `,` goes on this way, so a signature's `uses Clock,` can wrap too, with the rest of the list indented on the next line. Items are listed from outermost to innermost, and the innermost implementation of a dependency wins. `with` removes what it installs from the body's `uses`, and adds what its items need.

An item is either an **implementation**, or a **wrapper**: an ordinary function whose last parameter is the body.

```
with retry(3) in body    ≡    retry(3, fn() => body)
```

```ren
pub fn retry<T>(n: Int, body: fn() -> T) -> T   // a wrapper: calls body up to n times
```

`retry` calls the body again from the top. It doesn't resume anything. It also repeats any dependency calls the body made before failing, so wrap only work that's safe to repeat.

Dependencies are found when code runs, not when it's written. A function or closure whose type says `uses Users` gets whatever `Users` is installed where it's called, and the type checker makes sure one is. A closure that outlives its `with` is still safe: it never holds on to the old implementation.

The one exception is an implementation's own dependencies. **What an implementation needs is part of its type**, and is required at the `with` that installs it: a `Clock` whose `now` calls `Os` makes `with` that clock need `Os`, while the code inside sees only `Clock`. Its dependencies are fixed once, when it's installed, to whatever is installed further out. And **interfaces are exact**: an operation's implementation may fail with fewer errors than the interface declares, never more.

#### Tests

```ren
test "a deposit is stamped with the time" =
  var acme = Bank.empty
  let a = &acme.open()
  TestClock.advance(Duration.minutes(5))
  try &acme.deposit(a, Money.dollars(10))
  let s = try acme.statement(a)
  assert s[0].at == Time.epoch.plus(Duration.minutes(5))
```

Tests sit next to the code they test, so they can reach private functions, and `ren run` ignores them. Every test gets test implementations of the built-ins without a `with`: a `Clock` stopped at `Time.epoch` until `TestClock.advance` moves it, a `Random` seeded from the test's name, and a `Console` that keeps what it's given, `TestConsole.output()`. So a test that uses no real dependency gives the same result on every run. A test asks for a real one in its `uses`, `test "the system clock moves" uses Clock =`, so going outside is visible. Any other dependency needs a `with`, and forgetting one is a compile error naming the test and the call that needs it.

A group is a function over implementations, so one suite runs against every implementation of a dependency, each test with a fresh one:

```ren
pub group clock_conforms(c: Clock) with c =
  test "now never goes back" =
    let t = Clock.now()
    assert not Clock.now().before(t)

group "frozen" = clock_conforms(Clock.frozen(Time.epoch))
group "test clock" = clock_conforms(test_clock(Time.epoch))
```

A failed `assert` is a panic: it's a bug, not an error. `assert a == b` shows both sides, with a marker under the first place they differ and what they share left out, `Account { ..., balance: Money(-100), ... }`, and an opaque value as its type around its contents, `Money(-100)`, as `print` shows it. To check that something fails, keep it with `attempt`.

`ren test` runs every module's tests in a folder: one line per test, then each failure with its source, both sides, its seed and the command that reruns it, and what it printed. `--only <text>` runs the tests whose name has it, `--seed N` sets every test's seed, `--list` lists them, saying which use a real dependency, and it exits with status 1 if any failed. [examples/bank](examples/bank) carries a suite like this.

### 7. `handler`: stateful implementations

Stateless implementations are plain values, like `Clock.frozen` above. An implementation needs a `handler` when it holds state:

```ren
handler mem_users(init: List<User>) for Users =
  var table = init.index_by(.id)
  get(id) => table.get(id)
  save(u) => table[u.id] = u
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

Calling `counting_rates(r)` describes a handler, a value of the dependency's type like any implementation, and each `with` creates a fresh instance with its own state: two `with`s never share it. Handlers resume at most once, which keeps them as cheap as function calls. Inside a handler for `Users`, writing `Users.get` is an error.

A handler forwarding calls to the next implementation out, through `outer`, comes in stage 9:

```ren
handler cached(ttl: Duration) for Users
    uses Clock =
  var cache = {}
  get(id) =>
    match cache.get(id)
      Some(e) if Clock.now() - e.at < ttl => Some(e.user)
      _ =>
        let u = outer.get(id)                   // forward to the next Users out
        if u is Some(user) then cache[id] = { user, at: Clock.now() }
        u
  save(u) =>
    &cache.remove(u.id)
    try outer.save(u)
```

A `cached` installed outside `with Clock.frozen(t) in` keeps using the clock that was installed where it was, even when it's called from inside that block. A handler can only see implementations installed further out, so handlers can't call each other in a loop.

A handler's state is exclusive between dependency calls. Two tasks are never inside the pure part of the same handler at once, so state updates can't corrupt each other. Other calls can interleave only at a dependency call, such as `outer.save` or `Clock.now()`, and cancellation happens only there too.

That narrows where a race can happen without hiding it. `cached` above has one: between `cache.remove` and `outer.save`, another task's `get` can miss, read the old user, and put it back in the cache. The simulation scheduler switches tasks at exactly these points, so `ren test --sim` finds the race. The fix is to invalidate again after `outer.save` returns.

A handler will also be able to run code when its `with` block ends. `arena` frees everything it allocated, and `transaction` commits or rolls back:

```ren
handler transaction() for Sql =
  var tx = outer.begin()
  query(q) => try tx.query(q)
  finally(result) =>
    if result is Ok(_) then try tx.commit() else tx.rollback()
```

### 8. `&`: this call changes it

```ren
normalize(&scores)                     // visibly updates `scores`
&scores.push(10.0)                     // a method that changes its receiver

for p in &particles                    // update each element in place
  p.pos += p.vel * dt

let n = try Fs.read(fd, &buf)          // the kernel gets exclusive access to buf

swap(&a, &a)                           // error: `a` passed as inout twice
```

An argument passed with `&` has to be the only way the call can reach that value, so no other argument of the call can use it: `f(&xs, xs)` is an error. If it were allowed, the read would either point into a buffer the call is changing in place, or make that buffer shared and force a hidden copy. For now that also covers reading a part of it, as in `&xs.push(xs[0])`: read it into a `let` first. Once reference counting arrives (stage 12), reading a plain value out of it, such as an `Int` element, will be allowed, because that read copies the value before the call starts. Reading something that is itself counted, like an array element or a `T`, will stay an error.

A function body uses exactly two markers: `try` means a call can fail, and `&` means a call changes something.

---

## Methods, operators, and equality

There are no traits or typeclasses. A type carries its own operations, indented directly under its declaration: methods, associated functions and values, and operators. The compiler looks there and nowhere else.

```ren
pub type Stack<T> = { items: Array<T> }
  pub fn push(inout self, x: T) = &self.items.push(x)
  pub fn peek(self) -> Option<T> =
    let n = self.items.len()
    if n == 0 then None else Some(self.items[n - 1])
  pub fn size(self) -> Int = self.items.len()
  pub fn of(xs: Array<T>) -> Stack<T> = Stack { items: xs }
  pub let empty: Stack<T> = Stack { items: [] }
  fn grow(inout self) = ...                     // private to this module

fn main() uses Console =
  var s = Stack.empty                           // an associated value
  &s.push(1)                                    // Stack.push(&s, 1)
  print(s.peek())                               // Some(1)
  let t = Stack.of([7, 8, 9])                   // an associated function
  print(t.size())                               // 3
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

Operators go in the same place, written with `=>`, and are public whenever their type is. They arrive in stage 10:

```ren
type Vec3 = { x: f32, y: f32, z: f32 }
  add(a, b)      => { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z }
  mul(a, s: f32) => { x: a.x * s,   y: a.y * s,   z: a.z * s   }
  zero           => { x: 0, y: 0, z: 0 }
  pub fn length(self) -> f32 = (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()

type Email = opaque Str
  key(a) => a.lower()                           // eq, hash, and compare all use this

pub fn sum<T>(xs: Array<T>) -> T where T has add, zero =
  xs.fold(T.zero, fn(acc, x) => acc + x)
```

`==`, `hash`, `compare`, and `show` are derived structurally for every type, except that types containing functions get no `==` or `hash`. To change what "equal" means, override `key`, so equality, hashing, and ordering always agree. Overriding `eq` alone is an error. Only the module that declares a type can write its members. To extend a type you don't own, write a function in your own module or wrap it in an `opaque` type. Because lookup only ever checks the type's own definition, there are no orphan rules, no coherence puzzles, and no slow search.

An opaque number type, like `type Meters = opaque f64`, will get a shorthand that gives it its arithmetic, planned for stage 10. Its spelling isn't settled: a member line like `derive numeric`, or something on the type line like `opaque f64 with numeric`, which is the current lean. What it gives comes first, though. All of `f64`'s operators would make `Meters * Meters` a `Meters`, which is dimensionally wrong. So it should probably give only `+`, `-`, negation, zero, comparison, and scaling by a plain `f64`, and leave anything else (`Meters * Meters -> Area`) to be written by hand.

---

## Memory without a GC

Ren uses compiler-managed reference counting with in-place reuse ([Perceus](https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse/)). There's no garbage collector and no lifetimes. Reference counting never leaks, because safe Ren can't form a cycle:

- Values are immutable once shared, and `a.next = Some(a)` stores a copy of the old `a`, not `a` itself.
- There are no recursive values (no `let rec` on data).
- Local recursive functions are compiled as top-level functions, so a closure never captures itself.
- Closures never capture handlers, because dependencies are looked up at the call site.

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
  mass: f32,
  cold name: Str,                 // stored out of line, never pulled into hot loops
} where size <= 64                // compile error if it outgrows a cache line

fn step(inout ps: Array<Particle, soa>, dt: f32) =
  for p in &ps
    p.pos += p.vel * dt           // switch soa ↔ aos with one word; the body doesn't change
```

---

## Allocation model

"No `Alloc`, no allocation" is only useful if you can predict allocation by reading the code. These rules make that possible.

**What lives on the heap.** Scalars, records, tuples, and non-recursive enums are inline values, so `Some(i)`, `Vec3`, and `Pro(seats: 5)` never allocate. Heap values are `Array`, `Str`, `Map` and `Set`, recursive types (boxed only where they recurse), closures that are stored, and `cold` fields.

**What counts as allocating.** Creating or growing a heap value, copying a shared value before changing it (copy-on-write), and freeing a value whose count reaches zero.

**How it's checked.** The compiler inserts reference-count operations, copies, and frees, then checks the result. A copy or free inserted into a function without `Alloc` is a compile error that points to the line that caused it. There's no separate proof system: an inserted allocation is a dependency call like any other, checked by the same rules as `uses`.

**Parameters.** Read-only parameters are borrowed and cost no reference counting. For an `inout` parameter, the caller makes the value unshared before the call, so any copy is charged to the caller. A `unique` parameter transfers ownership.

**Closures.** A lambda passed to a transparent parameter is never heap-allocated. That's a language guarantee, not an optimization that might fail. A transparent parameter can't escape, so its closure can live on the stack.

**Generics.** `where T has add` works like a transparent parameter. `sum<Int>` doesn't allocate; `sum<BigInt>` uses `Alloc`, because `BigInt.add` does.

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

Ren has no `async` or `await` and no colored functions. Concurrency is structured: no task outlives the block that started it, and a failure in one task cancels the others.

```ren
pub fn dashboard(ids: List<UserId>) -> List<Summary> ! Timeout | FeedError
    uses Users, Net, Async, Alloc =
  async.timeout(2.s) fn() =>
    async.par_map(ids) fn(id) =>
      summarize(id, try load_feed(id))
```

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

### Deterministic simulation testing

Run your system under a seeded fake scheduler, clock, network, and disk. Every failure replays exactly.

```ren
test sim "log survives S3 flakiness and crashes" (seed) =
  with sim.scheduler(seed), sim.clock, sim.s3(seed, fail_rate: 5%), sim.crash(seed) in
    let log = DurableLog.open("bucket")
    async.par_map([writer, reader]) fn(task) => task(log)
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

- **Hashing.** Hash seeds come from the `Random` dependency, which simulation fixes from the seed. Map iteration order replays exactly.
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
  feed.ren:19      buf.push          COW copy 12×   shared by slice `head` (line 17)
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
warning: `buf` is shared by the slice `head`, so `push` copies the buffer
   ┌─ src/frame.ren:14:1
13 │ let head = buf[0..16]
   │            --- slice keeps `buf` shared
14 │ &buf.push(0)
   │ ^^^^^^^^^^^^ copies
   help: copy the slice instead:  let head = buf[0..16].copy()
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
- **[Roc](https://www.roc-lang.org/):** the closest relative. It shares the RC + Perceus core, a fast compiler, and lambda set specialization. Roc keeps apps pure and puts systems work in a separate "platform" host. Ren puts both in one language, with named, typed dependencies instead of a pure/effectful split.
- **[Lean 4](https://lean-lang.org/):** borrow inference, functional-but-in-place arrays
- **[Hylo](https://www.hylo-lang.org/) and Swift:** mutable value semantics, `inout`, reentrant actors (the model for handler state)
- **OCaml:** polymorphic variants, the model for Ren's error tags; Rémy-style row unification underneath both errors and `uses`; type-directed lookup of constructors and fields
- **OxCaml:** uniqueness and locality modes
- **[Lambda set specialization](https://www.cs.princeton.edu/~mpmilano/publication/lss/) (PLDI '23):** closures and dependency records without heap allocation or indirect calls
- **[Zig](https://ziglang.org/):** explicit allocation, comptime, minimalism
- **Go:** stdlib-first, one-binary tooling, always-qualified imports, `internal/`, one version of each dependency
- **[Effect](https://effect.website/):** typed dependencies, layers, structured concurrency
- **FoundationDB, TigerBeetle, Antithesis:** deterministic simulation testing
- **NanoLog, `defmt`, `rr`:** static log extraction, record and replay
- **Elm and Gleam:** errors written for humans, small languages that fit in your head

---

## Implementation

- The compiler is written in **OCaml**.
- The backend emits **C**: `tcc` for fast debug builds, `clang -O2` (or `zig cc`) for release builds, and Wasm through the same path.
- Every function takes the implementations installed where it's called as one hidden parameter, an evidence vector, which a dependency call searches by the dependency's identity ([deps.md](deps.md#how-it-runs)). Release builds specialize implementations known at compile time using lambda sets, so dependency calls become direct, inlinable calls, within a specialization budget.
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
| 9 | handler `outer`, `Async`, `Net`, `par_map`, **the effect journal** | caching handlers wrap real ones; calls are journaled |
| 10 | operators, derived equality and hashing, arithmetic for opaque number types | `Map<Email, User>` works |
| **↑** | **interpreted Ren** | **a small web service and its tests run** |
| 11 | C backend, packages, `ren build` with a content-addressed cache | native binaries, rebuilt incrementally |
| 12 | reference counting with reuse | `map` reuses memory in place; `&xs.push(xs[0])` is allowed when the element is a plain value |
| 13 | `Alloc` as a dependency, arenas, no-alloc checking | `checksum` provably never allocates |
| 14 | `unique`, layout (`soa`, `cold`, `where size`) | hot loops run with zero copies |
| 15 | simulation scheduler, flight recorder, replay, profiler | a failing seed replays exactly |
| **↑** | **Ren 1.0** | **flottning, rewritten in Ren, passes 10,000 simulation seeds** |

The **effect journal** in stage 9, the record of every dependency call, is the most important design artifact after the type system. Simulation, replay, migration, and traffic replay all depend on it. If the format is right, those features are extensions. If it's wrong, each one becomes a rewrite.

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
  async.par_map(ids) fn(id) => Users.get(id)  // one query, not 100
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

- How much `comptime` is needed for `json.decode<T>`-style reflection without macros?
- Should handler ordering be linted, and which orderings are known to be bad?
- What exactly goes in an effect journal entry so it serves simulation, replay, and migration alike?
- Which dependencies are traced per call by default, and which only in aggregate (`Clock`, `Alloc`)?

---

## License

TBD.

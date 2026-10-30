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

> **Status:** early. Stages 1–4, 5a, 5b, 6–9, 10.0, 10a, 10b, 10c, 10d, 11a and data of the [Roadmap](#roadmap) run in an interpreter: functions, records, sum types, exhaustive `match`, blocks, type inference with `uses` rows, `var`, `inout`, `&` with value semantics over records and arrays, modules (files as modules, `import`, `pub`, `opaque` types, constructors and fields found through their type, and `uses` on signatures, checked against the body), methods, associated functions and associated values declared under their type, with `&` before a changed receiver: `&xs.push(x)` (see [examples/shop](examples/shop)), and errors: structural tags after `!`, named error sets, `fail`, `try`, `match` with `fail` arms, `try match`, `attempt` and `orelse`, with exact signatures on public functions, and `&&`, `||` and `not`; and dependencies: `dep` declarations, `with` and `handler`s, the built-in `Clock`, `Random` and `Console`, minimal strings, and `test`, `group`, `assert` and `ren test`, with test implementations by default (see [examples/bank](examples/bank)); and the world, thinly: `Str`'s methods, on byte offsets, `Bytes`, `Path`, `Fs`, `Os.args` and `Proc.run`, with `mem_fs`, `test_os` and `test_proc` in tests, and `ren run file.ren -- args` (see [examples/just](examples/just)); and stage 9: operators as methods (`a + b` is `a.add(b)`, chosen by the right side's type), `key`, derived `==`, `hash`, order and `show`, `opaque Int with numeric`, 64-bit `Int`s that panic on overflow, `Float`s whose `NaN` panics where it's observed, tuples, ranges in `for`, `Map` and `Set` in insertion order, and `Enumerable`'s methods on `Array`, `Map` and `Set` (see [examples/bank](examples/bank)); and stage 9c: `opaque { ... }` records, a type that keeps rules is opaque, tests that see what an importer sees, `test fn` and `test handler`, and `ren console` on test implementations (see [examples/bank](examples/bank)); and stage 10a: `with` as a set, handlers `over` another implementation that reach it with `next`, `finally`, and handler state that can fail to start (see [examples/prices](examples/prices) and [examples/ledger](examples/ledger)); and stage 10b: the journal, `ren run --record` and `ren replay`, which runs a program again on what it was given without touching the world, `ren run --trace`, a journal as a test with `replay(file)` and `ren test --keep`, and the console's effects shown as they happen, `:reload` and `:spec` (see [examples/just](examples/just)); and stage 10c: blocks, lambdas that are passed down and called but never kept, which capture by reference and find their dependencies where they're written, with exclusivity checked in one pass and rule A; `with` installing only handlers, a function that runs a block called with it; `while` and `break`, cursors and `for` over them; and `finally` where it's written, among a handler's state or in an operation's arm (see [examples/ledger](examples/ledger) and [examples/values.ren](examples/values.ren)); and stage 10d, in the interpreter and natively: generic dependencies, `dep Chan<T>` and aliases installed with `with ... as`, handler descriptions as the only stored code with a stored description's `uses` an upper bound, inline handlers, stateless handlers called as methods and dispatched as decision 4 says (`ren build --release --explain-dispatch D`), `over any` and `retry(n, on: DbDown)`, with the journal's recorder an `over any` handler in Ren, blocks that take `&` parameters, slices `xs[a..b]` of an `Array`, `Str` or `Bytes` and `split_at`, `shl` and `shr`, and hex, binary and underscored literals (see [bench/10d](bench/10d)); and stage 11a: tasks, `Async.scope(max:)` and `spawn`, `until`, `timeout`, `race` and `isolate`, with exclusivity's rules B to D; the runtime as a handler, `single` and `sim`, and `ren test --sim --seeds`, which finds a lost update and replays it by seed; the standard library's `sync`; and `Net`, a thin TCP layer with `sim.net` (see [examples/server](examples/server) and [examples/crawler](examples/crawler)); and the data stage, in the interpreter and natively: record update, `{ ..order, status: Paid }`, record patterns, `{ id, .. }` and `let { id, lines } = order`, variants with several fields by name and one positional, `Rect { w: 2, h: 3 }` and `Some(x)`, or-patterns, `as` and `let ... else`, variant types, `Order.Placed`, errors that teach the model, missing arms printed as code to paste, and `todo`; an operation called on a description only when its handler is stateless; and the layout fixes, a small record flattened into its parent, arrays of small records holding objects kept inline, byte tags and pointer niches (see [examples/bank](examples/bank) and [examples/shop](examples/shop)). The native slice has started: `ren build file.ren` compiles a sequential program through C to a binary that prints what `ren run` prints, panics included: `Int`s, `Float`s, `Bool`s and `Str`s, records, sum types, tuples, arrays, `match`, `var`, `inout`, `while` and `for`, errors with `fail`, `try` and `match`, generic functions through descriptors, derived `show`, `==` and order, blocks that allocate nothing, dependencies, `with`, handlers with state, `over`, `next` and `finally`, and the real `Console`, with Perceus reference counting: parameters only read are borrowed, values dropped as soon as they're dead, a node taken apart reused for the one built from it, and arrays changed in place when they're unique; and `ren build --release`, which specializes the whole program first: a copy of each generic function per type, each block lifted into a function of its own with its captures as parameters, an operation whose handler is known called directly, records and tuples of numbers and `Bool`s kept unboxed, in place in arrays, and `&` parameters `restrict` (see [compiler.md](compiler.md#native-slice)); and the bytes stage's first half, in the interpreter and natively: string and byte code at offsets with the bounds checks the compiler proves taken out, reads and writes at an offset with the width and byte order in the name (`b.u32_le(at)`, `&b.set_u16_be(at, x)`), `Bytes.zeros`, `VarUInt` and `VarInt`, a `ByteCursor` that fails with a `FormatError`, `Str.from_utf8`, `Map` and `Set` in insertion order, and `x.hash()`, unseeded and the same on every run (see [compiler.md](compiler.md#bytes-stage)); the rest of the world says it isn't in it yet. Its benchmarks are measured against Rust and Go in [bench/native/RESULTS.md](bench/native/RESULTS.md): the seven of vision.md run within 2× of Rust, five faster than it; the string and byte kernels `logs_r`, `json_r`, `pages_r` and `bytes` run at 1.04× to 1.71× of Rust, the map kernel at 0.69×, and the layer 3 kernel, `frames`, at 2.06×; and debug builds are still slower than `go build`. Most examples in this README show how Ren is intended to look, not what runs today. Editor support: [Zed](editors/zed), on a [tree-sitter grammar](editors/tree-sitter-ren) checked against the compiler's parser.

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
 uses Users, Billing, Net         same language          sized ints, no Alloc,
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
5. **Values never change under you.** You can write `x.field = y`, but nobody else can observe it. The only state that outlives a call lives inside handlers, which one operation touches at a time, from its start until it returns or waits.
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

Leave out an arm and the error writes it for you, as code to paste under the others, ending in `todo`: an expression of any type that panics where it's reached, so a program with work still to do compiles. Asking a sum for a field one variant has says which, and writes the `match`; asking for one every variant has says to hoist it into a record:

```
error: this `match` doesn't handle every `Plan`
  ┌─ plans.ren:9:3
9 │   match p
  │   ^^^^^
  = missing: Enterprise(_)
  help: add the missing arms, or a `_ =>` arm for the rest:
    Enterprise(_) => todo
```

An arm can match several shapes with `|` between them, each binding the same names, and `as` names the whole of what it matched. A `let` takes apart what might not match when it has an `else`, which has to leave, with `fail`, `break` or `todo`:

```ren
fn upgraded(p: Plan) -> Plan =
  match p
    Pro(n) as old => if n > 5 then Enterprise(big_contract) else old
    Free | Enterprise(_) as other => other    // `as` names what either matched

fn seats(p: Plan) -> Int ! NotPro =
  let Pro(seats) = p else fail NotPro          // no `if let`: this, or a `match`
  seats
```

A variant with one field is positional, `Pro(5)` and `Pro(seats)`; a variant with several is by name, where it's declared, built and matched, `Placed { id, lines, total }` and `Placed { id, .. }`, so adding a field breaks no pattern that doesn't need it, and swapping two fields of one type can't swap the values unseen. Tuples stay positional.

A variant with named fields is a type too, `Order.Placed`, a record of exactly its fields, so a function can accept only one state. Only a pattern's `as` gives one, and it goes anywhere a value does. A constructor always builds the sum, and `Placed { ..p }` makes one the sum again, which costs nothing, since it's the same value. There's no subtyping and no conversion you don't write, and `==`, ordering, `hash` and `show` are the sum's:

```ren
type Order =
  | Draft { lines: Array<Line> }
  | Placed { id: OrderId, lines: Array<Line>, total: Money }
  | Shipped { id: OrderId, tracking: Tracking }

fn ship(p: Order.Placed, t: Tracking) -> Order =   // only a placed order ships
  Shipped { id: p.id, tracking: t }

fn step(o: Order, t: Tracking) -> Order =
  match o
    Placed { .. } as p => ship(p, t)               // `p` is an `Order.Placed`
    _ => o
```

Ren has no null. Optional values are written `T?`.

### 2. `let` and `var`: value semantics

```ren
var scores = [3.0, 1.0, 2.0]
let before = scores                    // a value, not a reference
&scores.push(10.0)                     // copies once: `before` still shares the buffer
assert before == [3.0, 1.0, 2.0]       // nothing changes out from under you

var user = load(id)
user.plan = Pro(5)                     // reads like mutation, means "new value"
```

A record is updated by naming what changes, `..` taking the rest from another, and taken apart by naming its fields, `..` leaving out the rest. When the record updated isn't shared, its update is built over it in place:

```ren
let paid = { ..invoice, paid: true }       // every field of `invoice` but `paid`
let placed = Placed { ..draft, id, total }  // a `Draft`'s lines, with an id and a total
let { id, lines } = invoice                 // a `let` takes apart what always matches

match invoice
  { paid: true, total, .. } => total        // `..`: the fields left out
  { lines, .. } => lines.len()
```

No two names ever see the same mutable thing, a block sharing its frame's variables only during its call, so Ren has no data races and no reference cycles. When a value isn't shared, the compiler updates it in place, so the copies you'd expect from immutable data mostly never happen.

Loops are `for` and `while`, and `break` leaves the innermost one. A `for` goes over an array, a range, a `Map` or a `Set`, or a **cursor**: a value that keeps its place, any type with a method `next(inout self) -> Option<T>`. Since the cursor is a value, `for x in &c` steps `c` itself, so a loop left by `break` leaves it where it stopped, and the next loop goes on from there:

```ren
var i = 0
while i < xs.len()
  if xs[i] < 0 then break
  i += 1

var lines = Lines.of(text)             // a cursor: `next(inout self) -> Option<Str>`
for line in &lines
  if line == "---" then break
  &head.push(line)
for line in &lines                     // goes on after the `---`
  &body.push(line)
```

`for x in c`, without `&`, steps a copy. A `break` can't leave a block for the loop around it, since the block runs during the call it's passed to, nor a `with`, whose handlers are given what its body ends in.

Over an array, `for i, x in xs` gives each element with where it is, and `for i, x in &xs` lets the body change `x`, which goes back at `i`. To go over two arrays together, `xs.zip(ys)` is a cursor of their pairs, as long as the shorter, and `xs.zip(ys).zip(zs)` one of triples. A range's numbers are their own index, and a cursor has none: count in a `var`. None of these can index past an end, so a release build checks each loop's length once, not each element, and the same goes for `xs[i]` in `for i in 0..xs.len()`, and for another array's `ys[i]` once it has checked, before the loop, that `ys` is long enough:

```ren
fn dot(xs: Array<Float>, ys: Array<Float>) -> Float =
  var t = 0.0
  for (x, y) in xs.zip(ys)
    t += x * y
  t

fn axpy(inout ys: Array<Float>, a: Float, xs: Array<Float>) =
  for i, y in &ys
    y += a * xs[i]                     // `xs[i]` panics if `xs` is shorter
```

### 3. Functions

```
pub fn name(params) -> Value ! Errors      what goes in, what comes out, how it fails
    uses Dependencies =                    what it touches
```

```ren
fn total(xs: Array<Float>) -> Float            // read-only parameter (default)
fn normalize(inout xs: Array<Float>)           // updates the caller's value
fn blur(img: Image) -> Image                   // changed in place when the caller's was its last use
```

Lambdas are **blocks**, with trailing-lambda syntax for multi-line bodies. A block is passed to a call, called, or named with `let` where it's written, `let f = fn(x) => x + 1`. It can't be stored in a record, an array or an enum, returned, or held in a `var`, so it never outlives the call it's passed to:

```ren
let names = users.map(fn(u) => u.name)

let summaries = Async.map(users) fn(u) =>
  let feed = try load_feed(u.id)
  summarize(u, feed)
```

A block captures the variables it uses by reference: it reads them when it runs, and can change a `var` outside it. [Exclusivity](#8--this-call-changes-it) keeps that sound:

```ren
var n = 1
let get = fn() => n                    // reads `n` when it runs
n = 2
assert get() == 2

var total = 0
scores.each(fn(x) => total += x)       // changes `total`
```

Inside brackets, where line breaks are otherwise ignored, a lambda's body can be a block too: a `=>` that ends its line opens one, indented further than the line around the brackets, and it ends at a line indented less, at a `,` before the next argument, or at the closing bracket:

```ren
let total = items.reduce(0, fn(sum, item) =>
    Clock.sleep(Duration.ms(20))
    sum + (if item == "apple" then 3 else 1)
)
```

Public functions spell out their full contract. Private functions can infer their `uses` and their error set (`! _`). `ren fmt --annotate` writes the inferred clauses into your code.

A parameter written `fn(...)` takes a block. A block's errors flow out of the call it's passed to, and its dependencies are found where it's written, so they're the writer's: neither is written on the parameter:

```ren
pub fn map<T, U>(xs: Array<T>, f: fn(T) -> U) -> Array<U>
pub fn retry<T>(n: Int, on: Tags, body: fn() -> T) -> T
```

`Async.map` and `Async.timeout` take theirs the same way. Calling `Async.map` with a block that can fail with `FeedError` and uses `Net` makes that call fail with `FeedError`, and the function that wrote the block use `Net`. That holds even though it runs `f` on other tasks, because no task outlives the call that started it ([async.md](async.md)).

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

The built-in dependencies are `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async` today (`Net` is a thin layer over TCP, and a test gets `sim.net()`, in memory), then `Alloc` (stage 15) and `Unsafe`. There is no catch-all `Io`. Even `print` goes through one: it's an ordinary prelude function, `Console.write(show(x))`. `Time`, `Instant` and `Duration` come with `Clock`, and `Str` arrives at its smallest: literals, `==` and `show`. Stage 8 gives it methods, and `Bytes` and `Path` with it. Stage 9 renames `s.find(":")` to `s.index(":")`, as `Array.index`: `index` finds where something is, and `find` takes a function. Stage 10d gives slices, `s[a..b]` on a `Str`, `Bytes` or an `Array`, a value of the same type that shares what it was cut from ([operators.md](operators.md#slices)); `split` and `trim` return slices, and `copy()` gives one a buffer of its own.

The runtime installs exactly the built-ins `main` lists in its `uses`, outermost. Any other dependency has to be installed inside `main`, and leaving it out is a compile error, `nothing installs Users before main`, with a help that says how.

```ren
pub fn checksum(data: Array<UInt8>) -> Int =   // no `uses`: pure, cannot allocate
  var h: UInt32 = 2166136261
  for b in data
    h = h.xor(b) *% 16777619
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

`with` installs only implementations. A function that runs a block, like the prelude's `retry`, is called with it, the block written last:

```ren
pub fn retry<T>(n: Int, on: Tags, body: fn() -> T) -> T   // calls body up to n times while it fails with one of `on`

let rate = try retry(3, on: Flaky) fn() => try Rates.fetch()
```

`on:` names the errors it tries again, and is the one kind of argument written with its parameter's name: a parameter of type `Tags` takes error tags, `on: DbDown | Timeout`, each one the block can fail with. Writing `retry` in a `with` is an error whose help writes the call:

```
error: `with` installs only handlers
  ┌─ main.ren:8:10
8 │     with retry(3, on: Flaky) in
  │          ^^^^^^^^^^^^^^^^^^^ takes a block
  = `retry` is a function that runs a block, so it's called with the body as one
  help: call it: `retry(3, on: Flaky) fn() => ...`
```

`retry` calls the block again from the top. It doesn't resume anything. It also repeats any dependency calls the body made before failing, so wrap only work that's safe to repeat.

A function's dependencies are found when it runs: one whose type says `uses Users` gets whatever `Users` is installed where it's called, and the type checker makes sure one is. A block's are found where it's written, except those its parameter's type lists, which the function that calls it provides:

```ren
fn with_fake_net(body: fn() uses Net) = with fake_net() in try body()
```

So a wrapper can't handle a block's calls by accident, and a helper that installs something for its body says so. A block never outlives the call it's passed to, so what it found where it was written is still installed when it runs.

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

`ren test` runs every module's tests in a folder: one line per test, then each failure with its source, both sides, its seed and the command that reruns it, and what it printed. `--only <text>` runs the tests whose name has it, `--seed N` sets every test's seed, which drives its tasks' order on the `sim` scheduler as well as its `Random`, `--seeds N` runs each under N seeds until one fails, `--list` lists them, saying which use a real dependency, and it exits with status 1 if any failed. [examples/bank](examples/bank) carries a suite like this.

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

Calling `counting_rates(r)` describes a handler, a value of the dependency's type like any implementation, and each `with` creates a fresh instance with its own state: two `with`s never share it. Its type lists what it implements, `Rates & RateCalls`. `with` installs what the type says, so both, sharing the state. Where a written type asks for one of them, `fn run(r: Rates)`, it becomes that one ([deps.md](deps.md)). A description can be kept, in an array or a record, for kinds a library's users add, routes or codecs, and an operation called on it as a method, `r.handle(path)`, is a pure dispatch: only a stateless handler is called that way. Calling `c.usd_to(1)` on a `counting_rates` would start its count again at every call, so it's an error whose help writes the `with` that keeps one instance, `with c in Rates.usd_to(1)`; `ren run`, `ren test` and `ren build` check it on the whole program, `ren check` of one module doesn't. Handlers resume at most once, which keeps them as cheap as function calls. Inside a handler for `Users`, writing `Users.get` is an error.

A handler can sit in front of another implementation of the same dependency. It's declared `over` it, may leave operations out, which go to the one under it, and calls that one through `next` ([handlers.md](handlers.md)):

```ren
pub handler cached(ttl: Duration) over Users uses Clock =
  var cache: Map<UserId, (User, Time)> = Map.empty
  get(id) =>
    match cache.get(id)
      Some((u, at)) if Clock.now() - at < ttl => Some(u)
      _ =>
        let found = try next.get(id)            // the Users under this one
        match found
          Some(u) => &cache.set(id, (u, Clock.now()))
          None => ()
        found
  save(u) =>
    &cache.remove(u.id)
    try next.save(u)

with cached(ttl) over postgres_users(pool) in
  serve(requests)
```

What wraps what is written with `over`, never implied by the order of a `with`. A `cached` installed outside `with Clock.frozen(t) in` keeps using the clock that was installed where it was, even when it's called from inside that block. A handler can only see implementations installed further out, so handlers can't call each other in a loop.

A handler's state is touched by one operation at a time. An operation keeps its instance until it returns, across its own calls to handlers installed outside it, such as `next.save` or `Clock.now()`: another task's call to `cached` waits its turn, and an operation lets go early only while it waits in `Async.until`. So state read before a dependency call is still the state after it, and `cached` above needs no care: between `cache.remove` and `next.save`, no other task's `get` can put the old user back. Cancellation happens only at a dependency call too.

That narrows where a race can happen without hiding it. Races are still possible, but only between operations: a caller that reads with one operation, lets another task run, and writes with a second has lost the other's update, and the fix is one operation that does both. The simulation scheduler switches tasks at exactly those points, so `ren test --sim --seeds` finds such a race and `--seed` replays it ([async.md](async.md#shared-state-is-a-handler)).

A handler can also run code when its `with` ends, in `finally`. It's a statement written among the handler's state, and covers what comes after it: the state below it and the `with`'s body, whose result it's given, returning the `with`'s. Its state can fail to start, and the `with` passes that failure on:

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

`r` is the body's result, as `attempt` would keep it, and `try r` passes its error on. `! DbDown` says installing it can fail, so the `with` can too ([examples/ledger](examples/ledger)). This `finally` is written after `begin`, so a failed `begin` never reaches it; one written above it would be given that error. A handler can have several, the last written run first, and an operation's arm can have one, covering the rest of the arm ([handlers.md](handlers.md#when-a-with-ends-finally)).

When the body is cancelled, `finally` sees `Err(Cancelled)`, and what it returns is discarded ([async.md](async.md#cancellation)).

A handler `over any` is written once for every dependency: one arm, `call => ...`, runs for each operation of whichever it's installed over, and reaches the one under it through `call.forward()`:

```ren
handler logged() over any uses Console =
  call =>
    Console.write("> ".concat(call.name).concat(show(call.args)))
    try call.forward()

with logged() over mem_users() in ...
```

`call.args` and what `call.forward()` gives are opaque, so they can be shown, compared and recorded, and nothing else; `call.fail(Down)` fails the operation with an error every operation of what it's installed over has to declare. The journal's recorder is one ([handlers.md](handlers.md#over-any)).

### 8. `&`: this call changes it

```ren
normalize(&scores)                     // visibly updates `scores`
&scores.push(10.0)                     // a method that changes its receiver

for p in &particles                    // update each element in place
  p.pos += p.vel * dt

let n = try Fs.read(fd, &buf)          // the kernel gets exclusive access to buf

swap(&a, &a)                           // error: `a` is passed with `&` twice
```

While a place is being changed, nothing else may use it: an `&` holds its place for the call, from after the arguments are evaluated, a `for p in &ps` for the loop, and a block passed to a call uses what it captures for that call. So `f(&xs, xs)` and `retain(&xs, fn(x) => x < xs.len())` are errors, while `&xs.push(xs.len())`, and `&xs.push(xs[0])` with an `Int` element, are fine, since a copied value is read before the call starts ([foundations.md](foundations.md#2-one-exclusivity-rule)):

```
error: `xs` is read by this block while the call changes it
  │ retain(&xs, fn(x) => x < xs.len())
  │                          ^^ read here
  │        --- changed for the whole call
  = a block runs during the call it's passed to
  help: read it first: `let len = xs.len()`, and use `len` in the block
```

A range of an array is a place too, and a block can take places of its own, written as a call passes them: `&xs.split_at(n) fn(&lo, &hi) => ...` gives it the two halves, changed in place, and `xs` is `lo` followed by `hi` after it ([operators.md](operators.md#slices)):

```ren
double(&scores[0..10])                 // changes the first ten
&scores.split_at(mid) fn(&lo, &hi) =>  // two halves, each a place of its own
  sort(&lo)
  sort(&hi)
```

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

Numbers follow a few rules, so nothing surprises at runtime. `Int` is 64 bits everywhere and overflow panics in every build, as an out-of-bounds index does; wrapping is `n +% 1`, or `n.wrapping_add(1)`. `/` and `%` round toward zero. `UInt8`, `Int32`, `Float32` and the other sized types are for storage, in fields and arrays: reading one gives an `Int` (or `Float`), storing one checks that it fits, and a wrapping operator's result stored into one wraps at its width. `Float` is a 64-bit double, and a literal's type is read from its spelling: `1.5` is a `Float` and `1` an `Int`, always. Numbers never convert by themselves, so `Float.of(n)`, `f.round()` and `f.truncate()` say where they do. A `NaN` panics where it's observed, compared, shown, rounded, hashed or passed to a dependency, saying where it was made, so `Float` is ordered and hashed; arithmetic carries it unchecked. `xs.sum()` of `Float`s adds in a fixed tree of eight lanes, the same on every machine. And a condition is a `Bool`, always.

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
- A block captures the implementations installed where it's written, but no value holds a block, so no handler's state can reach its own instance through one.

In the safe subset, Ren aims for Rust-level memory safety without lifetimes. Safety comes from reference counting and value semantics at runtime rather than a borrow checker at compile time. Borrow inference, moves on last use, reuse in place, and small values kept as values eliminate most of the counting work.

Allocation is a dependency like any other:

```ren
pub fn parse(src: Str) -> Ast ! ParseError
    uses Alloc = ...

```

You choose how much the compiler guarantees:

| You write | You get |
|---|---|
| nothing | reference counting with in-place reuse where possible |
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

**What lives on the heap.** Scalars, records, tuples, and non-recursive enums are inline values, so `Some(i)`, `Vec3`, and `Pro(5)` never allocate. Heap values are `Array`, `Str`, `Map` and `Set`, recursive types (boxed only where they recurse), and `cold` fields.

**What counts as allocating.** Creating or growing a heap value, copying a shared value before changing it (copy-on-write), and freeing a value whose count reaches zero.

**How it's checked.** The compiler inserts reference-count operations, copies, and frees, then checks the result. A copy or free inserted into a function without `Alloc` is a compile error that points to the line that caused it. There's no separate proof system: an inserted allocation is a dependency call like any other, checked by the same rules as `uses`.

**Parameters.** Read-only parameters are borrowed and cost no reference counting. For an `inout` parameter, the caller makes the value unshared before the call, so any copy is charged to the caller.

**Blocks.** A block is never heap-allocated. That's a language guarantee, not an optimization that might fail. A block can't be stored or returned, so it lives on the stack of the call it's passed to, and shares the frame it was written in.

**Generics.** A requirement on a type parameter, `T has add`, which the compiler infers, is met by the caller, as a block's dependencies are met where it's written. `sum<Int>` doesn't allocate; `sum<BigInt>` uses `Alloc`, because `BigInt.add` does.

**Panics.** A panic in a function without `Alloc` uses a message formatted at compile time and aborts.

**Growth.** `push` needs `Alloc`. Code without `Alloc` works in buffers whose capacity the caller set, using `push_within`.

In practice, code without `Alloc` is linear: every value it owns has to be returned, passed on, or handed to `Reaper`. That's a deliberate tool for hot paths and real-time code, not how most Ren code is written.

### Arenas

`with Mem.arena() in body` allocates the body's objects in chunks that end all at once. It's a tool for sharing, not an allocator: once a task or a shared handler can see it, it's sealed, and every core reads it without counting, as borrowed data. Values leave it only by copy, its result included, and what a handler installed outside it returns is copied in. On one thread it's slower than the heap, since reuse already frees promptly; across eight threads, a server reading its config from one ran at 0.82 to 0.99× of pure borrowing, against 0.02 to 0.08× with the config's strings counted from every core. The rules are in [foundations.md](foundations.md#10-many-cores), decision 10.

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

Four rules hold everywhere. No task outlives its call. A failure cancels its siblings, and the first one wins. A handler's state is touched by one operation at a time, until it returns or waits. And everything has a limit: `Async.map` runs 64 at once unless told otherwise. Cancellation can't be caught, and work that finished is never reported as timed out. Tests run on virtual time with a seeded scheduler, so `ren test --seeds 1000` tries a thousand interleavings and `--seed` replays one. The design is in [async.md](async.md).

Shared data is immutable, mutable data has exactly one owner, and handler state is exclusive for the whole of an operation, so data races can't happen. Logic races are still possible, but only between operations, which is where the simulation scheduler looks for them. A task's result moves to the task that joins it for free, and only values that are actually shared pay for atomic reference counts.

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
- **No stored closures.** A block is only passed down and called, never kept in a record, a collection or handler state, or returned. Code that's kept is an enum with an interpreter, or a handler. In return blocks capture by reference, and never allocate.
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
- The language a program is written in, decided after 11a: data as ADTs, a `dep` as a service you're given, wirings, the pipe, `Array`, `Table` and `Pool`, and when many stateful things are data or actors, is in [language.md](language.md).
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
| 10c | **blocks**: lambdas passed down and called, never kept, capturing by reference, with exclusivity and rule A; dependencies found where a block is written; `with` installs only handlers; `while` and `break`, cursors and `for` over them, `finally` where it's written ([foundations.md](foundations.md), [compiler.md](compiler.md#blocks)) | the ledger's test retries a transaction with a block that counts its tries in a `var` (done) |
| native slice | a naive C backend from Core for the sequential subset, with no optimizations ([vision.md](vision.md), [compiler.md](compiler.md#native-slice)) | vision.md's benchmarks run natively, measured against Rust and Go, before tasks build on the design (done: the benchmarks in Ren, Rust and Go; Mem IR, the C runtime and `ren build`; the debug strategy for blocks, generics, handlers, `show` and `Console`; Perceus: borrow inference, precise dup and drop, reuse, and arrays changed in place; release builds that specialize per type, block and known handler, with unboxed records and `restrict`; and H1 to H7 measured, in [bench/native/RESULTS.md](bench/native/RESULTS.md)) |
| 10d | descriptions: generic dependencies, handler descriptions as the only stored code, a stored description's `uses` as an upper bound, inline handlers, stateless handlers as methods, `over any`, `retry(n, on:)`, blocks that take `inout` parameters, slices, shifts and hex and binary literals ([foundations.md](foundations.md#staging)) | `retry(3, on: DbDown)` works for any block, and the journal's recorder is an `over any` handler in Ren (done, in the interpreter and natively) |
| 11a | tasks and `Net`: exclusivity's rules B to D, `Async.scope(max:)` and `spawn`, `until`, `tick`, `yield`, `timeout`, `race` with branches that can't fail, `isolate`; handler operations that don't interleave; `try with`; the runtime as a handler, `single` and `sim`; journals with task paths; the standard library's `sync`, a channel, a semaphore, `limit() over any`, a batcher and keyed handlers, `sync.keyed(n, h)`; `Net`, a thin TCP layer with `sim.net`; `Proc.run` that waits as a task, and `sim.proc`; and two spec holes closed: `s.spawn` carries `Async` in its row, and no scheduling point in code reached from an empty row ([async.md](async.md), [foundations.md](foundations.md#staging)) | a server shuts down gracefully, and `ren test --sim --seeds` finds a lost update between two operations (a read, then a write) and replays it by seed (done, in the interpreter, and natively for the sequential parts) |
| data | ADTs first ([language.md](language.md)): record update and record patterns, variants with several fields by name, or-patterns, `as`, `let ... else`, variant types (`Order.Placed`), the layout fixes; descriptions only for open sets, and an operation on a stateful one an error ([foundations.md](foundations.md#staging)) | the bank, the shop and the ledger read as language.md's end-to-end program does (done, in the interpreter and natively: record update and patterns, by-name variants, or-patterns, `as`, `let ... else` and variant types; the errors that teach the model, missing arms printed as code, and `todo`; descriptions only for open sets, `Shape` and `Expr` ADTs; the layout fixes, measured; and the ADT-first interpreter kernel at 1.13× Rust's `interp enum`, in [bench/native/RESULTS.md](bench/native/RESULTS.md), "The data stage: the milestone") |
| services | wirings and the pipe, `\|>` with `try` on each step; `Async.beside`, `release` and `Proc.run(kill:)`; `striped` and `actors`, one instance per key, as services ([language.md](language.md#11-many-stateful-things-data-or-actors), [foundations.md](foundations.md#18-actors-and-stripes)) | a document server runs under `sim` with chaos eviction, and a lost update split over two operations of one actor is found by seed |
| the `just`, natively | strings and bytes at Rust's speed, slices inline, `Map`, `Table` and `Pool` ([language.md](language.md#9-collections-array-table-and-pool)), and formats, views over `Bytes` for a type ([formats.md](formats.md)) | the `just` builds natively, its string kernels within 2× of Rust (strings and bytes within 2× of Rust, layer 3 and `Map` and `Set` natively done; left: inline slices, `Table`, `Pool`, formats, and the world natively) |
| 11b | many cores: `work_stealing`, `per_core` and `pinned`; the runtime model ([compiler.md](compiler.md#the-runtime-model)): atomic counts on shared objects, a heap per thread with frees returned to their heap; arenas, `with Mem.arena()`, sealed when shared; `snapshot` reads that take no lock, and `Atomic` fields in lock-free handlers; `striped` and `actors` on many cores, decided by the experiments in [foundations.md](foundations.md#staging) | the server's `sim` tests pass unchanged on every core, and it's measured against Go and Rust |
| 11c | generators, `gen fn` as cursors, and the stream library on them ([stdlib.md](stdlib.md#streams-cursors-first)) | a file is read a line at a time with `for line in &lines` |
| 12 | the standard library for a web service and the compiler: `http`, `json` and `cli` over shapes, top-level `let` and `assert`; property tests and `ren fuzz` ([stdlib.md](stdlib.md), [shapes.md](shapes.md), [testing.md](testing.md)) | a small web service and its tests, specifications and properties, run interpreted |
| 13 | the C backend for the whole language, tasks and handlers included, with reference counting and no optimizations; debug builds with tcc, per partition; the front half per module, in parallel; packages, `ren build` with a content-addressed cache | native binaries, rebuilt incrementally; debug builds measured against Go ([vision.md](vision.md)) |
| 14 | memory: specialization per block and per handler, dispatch over descriptions, borrow inference, reference counting with reuse ([compiler.md](compiler.md)) | `map` reuses memory in place; the benchmarks measured against Rust ([vision.md](vision.md)) (largely done by the native slice and its follow-ups, all seven within 2× of Rust; left: dispatch lowered as foundations.md's decision 4 says, with `--explain-dispatch`, and release with clang -O2 per module in parallel) |
| **↑** | **native Ren** | **the web service runs natively, within the bars** |
| 15 | `Alloc` as a dependency, no-alloc checking (arenas moved to 11b) | `checksum` provably never allocates |
| 16 | layout (`soa`, `cold`, `where size`); `unique` was rejected ([foundations.md](foundations.md#what-it-isnt)) | hot loops run with zero copies |
| 17 | the flight recorder and the profiler | a production failure replays from its flight recording |
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

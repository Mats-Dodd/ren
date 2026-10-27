# Shapes and build time

What a program can know about itself: the shape of a type, the shape of a
dependency, which dependencies a function uses, and the values that can be
computed before it runs. It answers the README's question about
`comptime`, and the question in [stdlib.md](stdlib.md#open-questions) about
how `json.decode<T>` and SQL rows are derived.

Ren knows where the world comes in. This design applies that to build
time:

> **The compiler knows where the world comes in, at build time and at run
> time.** Pure code runs anywhere. The world comes in through deps, visible
> and recorded. Types and deps have shapes you can look at.

Everything below follows from that sentence.

## What it has to do

1. **TigerBeetle's static checks.** Layouts, sizes and limits are checked
   by the build, so a wrong one can't ship.
2. **Libraries like `json` and `cli` are written in Ren,** by anyone, and
   work for any type, without macros or annotations.
3. **A handler can be written once for every dependency.** Tracing,
   limits, retries, mocks and recording each work over anything.
4. **Builds stay fast** ([vision.md](vision.md)), and **reproducible:** the
   same inputs give the same binary.
5. **Build time can't reach the world unseen.** Nothing runs on your
   machine while building that the language doesn't show.

## The top level is build time

```ren
let CRC_TABLE: Array<Int> = crc_table()
let ROUTES: Router = router([get("/users/:id", show_user), post("/users", create_user)])

assert Transfer.size == 128
assert handle_request.uses <= [Sql, Clock, Console]
```

**Everything at the top level of a module is computed while building.**

- **A top-level `let` is a value fixed into the binary.** Any function can
  compute it, as long as it doesn't use a dependency the build doesn't
  have (below).
- **A top-level `assert` fails the build.** It's shown like any other
  error, with the values that made it fail.
- **The top level never runs when the program does.** So Ren has no
  initialization order (C++'s static initialization order fiasco), no
  `init()` (Go), and no code that runs on import (Python). A program starts
  at `main`, with its top level already computed.
- **Inside a function, `let` is a runtime value,** and the optimizer folds
  what it can. Only the top level *guarantees* build time, so a program's
  meaning never depends on the optimizer.
- **There's no keyword.** The position says when it runs.

```
error: this assert failed while building
  ┌─ ledger.ren:4:1
  │
4 │ assert Transfer.size == 128
  │        ^^^^^^^^^^^^^ is 136
  │
  = `Transfer` grew by 8 bytes: `memo: Str` was added at line 12
```

### Limits

- **Top-level values can't depend on each other in a cycle.** The order
  they're computed in is worked out from what they use, as `with` sorts
  its items.
- **Building has a limit, as everything does.** A top-level value that
  runs for longer than the build's budget is an error that says where it
  was, rather than a build that never finishes.
- **A top-level value holds data, never a block** (foundations.md). A
  table of routes holds an enum to `match` on, or handlers' descriptions,
  which are data.

## The build's world

```ren
let SCHEMA: Schema = try sql.parse_schema(try Fs.read("db/schema.sql"))
```

At the top level, the dependencies installed are the build's:

| Dependency | At build time |
|---|---|
| `Fs` | reads, from inside the package |
| `Git` | the checkout being built: commit, tag, dirty or not |
| `Clock`, `Random`, `Net`, `Proc`, `Console` | not installed: a build that used them couldn't be reproduced |

- **Every read is recorded in the build's journal.** The journal is the
  cache key: a rebuild computes a top-level value again only if something
  it read changed. That's Bazel's hermetic builds, with nothing to declare,
  because the compiler already knows the inputs.
- **The same journal gives the same binary.** The replay bar
  ([vision.md](vision.md)) covers builds too.
- **`try` at the top level fails the build** with the error.
- **A package's top level uses the build's world only if it's granted.**
  Until packages exist, only your own package's top level can. Build time
  is where supply-chain attacks happen (`build.rs`, proc macros, `npm`
  install scripts), and in Ren it's visible.

## Shapes

```ren
User.shape        // a record's fields, or a sum's cases: names and types
Users.shape       // a dependency's operations: names, arguments, errors
Transfer.size     // bytes, once the memory stage decides layouts
handle_request.uses   // the dependencies a function uses, as a set
```

A shape is a value, available at run time and at build time.

### Libraries that work for any type

```ren
type User = { id: Int, name: Str, email: Option<Str>, role: Role }
type Role = Admin | Member

let u: User = try json.decode(body)
let out = json.encode(u)
let opts: Options = try cli.parse(Os.args())
```

`json`, `toml`, `cli` and SQL rows are ordinary Ren, written over
`T.shape`:

```ren
pub fn decode<T>(text: Str) -> T ! DecodeError =
  let doc = try parse(text)
  try from_doc(T.shape, doc)
```

- **Inside, a library works with a dynamic view.** The fields of `User`
  have different types, so a loop over them sees each field's value as a
  `Value`, and builds the `User` with a check that can't fail when the
  shape drove it. The dynamic part stays inside a few format libraries,
  written once. Their users see a typed `json.decode`.
- **Errors carry a path:** `DecodeError(at: "users[3].email", expected:
  "Str", found: "a number")`.
- **Debug builds read the shape as they go,** as Go's `encoding/json`
  does. That costs nothing at build time.
- **Release builds unroll it.** The shape is a constant, so specialization
  turns `decode<User>` into straight-line code, as fast as Rust's serde,
  without macros.
- **Renames and defaults are settings on the format,** like
  `json.decode(body, keys: camel_case)`. A wire format that differs more
  than that is a type of its own, converted by hand. There are no per-field
  attributes.
- **An opaque type's shape is opaque outside its module.** Outside, the
  shape of `Money` says only "opaque, built by its `parse`", so no library
  can build one that breaks its rule.
- **A type with a function in it has no shape to decode,** as it has no
  `==` ([operators.md](operators.md)).

The structural walk that derived `==`, `hash` and `show` use is the same
knowledge. The journal is the first format written this way.

### Handlers that work for any dependency

A dependency's shape gives a handler one more clause, `call`:

```ren
pub handler traced<D>() over D uses Clock, Console =
  call(op, args) =>
    let start = Clock.instant()
    let r = attempt next.call(op, args)
    Console.error(op.name + " took " + show(Clock.instant() - start))
    try r
```

- **`call(op, args)` handles every operation the handler doesn't write
  itself.** It's a contextual keyword, like `task` and `finally`.
- **It works in ordinary handlers too.** A handler `over Users` can write
  `get` itself, and send the rest through `call` to log them.
- **Without `call`, an operation an `over` handler doesn't write goes to
  `next` unchanged,** as [handlers.md](handlers.md#over-one-implementation-in-front-of-another)
  says. `call` is that, with a place to step in.
- **`next.call(op, args)` passes it on.** `op` has a name and the
  operation's shape, and `args` is the dynamic view of its arguments.

What it makes into ordinary libraries:

| Handler | What it does |
|---|---|
| `traced<D>()` | times and logs every call |
| `Async.limit(n) over D` | at most n calls at once ([async.md](async.md)), no longer built in |
| `retry<D>(n)` | retries any operation |
| `mock<D>()` | a test implementation of any dependency, recording calls and giving scripted answers |
| `recorder<D>()`, `replayer<D>()` | the journal ([handlers.md](handlers.md#the-journal)), for user dependencies too |
| `rpc.client<D>(addr)` | sends every call to another machine |

`rpc.client` makes a dependency remote without changing the code that uses
it. [runtime-io.md](runtime-io.md#three-rules) says a call is a value, and
`call` makes that true for every dependency.

## Asserting where the world comes in

```ren
assert handle_request.uses <= [Sql, Clock, Console]
assert not ledger.uses.includes(Fs)
```

The compiler knows what every function uses, so architecture rules can be
written in Ren and checked on every build:

```
error: `handle_request` uses `Fs`, which this module says it never does
  ┌─ server.ren:3:1
  │
3 │ assert handle_request.uses <= [Sql, Clock, Console]
  │ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ failed here
  │
  = `handle_request` → `render` → `load_template` → `Fs.read`
  = help: pass the template in, or drop the rule if it no longer holds
```

- "The request path never touches the disk." "The ledger never
  allocates," once `Alloc` exists (stage 15). "This module never uses the
  network."
- The error shows the path the dependency is reached by, the way
  [async.md](async.md#how-it-runs) shows a task's path.
- No other language can check this, because none knows where the world
  comes in.

## How it runs

- **The top level runs in the interpreter,** which the compiler has
  anyway. After self-hosting, it keeps one for this.
- **Each top-level value is cached** by the hash of what it was computed
  from: the code it ran and the journal of what it read. A rebuild that
  changes neither computes nothing.
- **Shapes are computed once per type** and carried, as every fact is
  ([module-build.md](module-build.md)).
- **Debug builds read shapes at run time.** Release builds specialize them
  away.

## What stays out

**Generating code and types.** Zig's `comptime` can return a type, and a
loop over a shape can produce new functions. That's where its costs are:

- build time grows with whatever libraries generate
- errors appear inside generated code
- an editor can't know what exists without running code
- generics are checked only when used

Shapes, generic handlers and inferred requirements cover what it's used
for. If something truly needs it later, it can be added without changing
anything here.

## Borrowed from

- **Zig:** `comptime` evaluation and static asserts. Ren keeps them, but
  in a position (the top level), not a keyword, and without generating
  code.
- **Rust:** serde's speed is the bar for release builds. `build.rs` and
  proc macros show what build time looks like when nothing tracks the
  world.
- **Go:** `encoding/json` reflects at run time, as Ren's debug builds do.
  `init()` is what the top level avoids.
- **Roc:** `Encode` and `Decode` derived for every type, with formats as
  libraries.
- **GHC.Generics, Scala's Mirrors:** typed reflection. Ren contains the
  dynamic part inside libraries rather than in the type system.
- **Java's dynamic proxies:** a handler for any interface. In Ren it's
  static and typed, and costs nothing in release builds.
- **Bazel, Nix:** hermetic, cached builds. Ren gets the inputs from the
  journal instead of declarations.

## What changes elsewhere

- **[operators.md](operators.md#deferred):** "comptime" moves out of
  Deferred and points here.
- **[stdlib.md](stdlib.md#open-questions):** derivation for `json`,
  `config` and SQL rows is answered: shapes.
- **[async.md](async.md):** `Async.limit` becomes a library once shapes of
  dependencies exist.
- **[handlers.md](handlers.md):** the recorder and replayer can be written
  as libraries, and record user dependencies as well as the world's.
- **README:** the question about `comptime` is answered.

## When each part lands

| Part | When |
|---|---|
| Top-level `let` and `assert`, pure | soon, with operators or the standard library |
| `T.shape`; `json`, `cli`, SQL rows | the standard library stage |
| `D.shape` and `call`; generic handlers; `f.uses` | after concurrency, since it rebuilds `Async.limit` and the recorder |
| `Transfer.size` | the memory stage, which decides layouts |
| The build's world, its journal, granting | with packages |

## Open questions

- **How `call` is typed.** Inside `call`, a reply belongs to whichever
  operation was called, and so do its errors. `try r` should pass on that
  operation's errors and no others. The checker needs a type for "the
  reply of `op`" that a handler can pass along but not invent, except
  through a check, as `mock` does.
- **What `Value`, the dynamic view, looks like.** It's the one dynamic
  type in Ren, and it should stay inside libraries. Does it need to be
  public for format authors, or can it be a module they import
  explicitly?
- **Is `f.uses` the inferred set or the declared one?** For a pub
  function they're the same. For a private one, the inferred set is what's
  true.
- **What's the build's time budget,** and can a module raise it?

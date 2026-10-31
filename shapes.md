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

**Status.** The walk, looks as values, the doors and the `call(c:
D.Call)` clause were decided on 2026-10-29 with looks
([formats.md](formats.md#a-type-and-its-formats), research/looks/), and
placed by [decision 20](foundations.md#20-what-the-language-owns-and-what-std-owns).

## Contents

- [What it has to do](#what-it-has-to-do)
- [The top level is build time](#the-top-level-is-build-time)
- [The build's world](#the-builds-world)
- [Shapes](#shapes)
  - [Libraries that work for any type](#libraries-that-work-for-any-type)
  - [The walk](#the-walk)
  - [`T` through looks is a shape](#t-through-looks-is-a-shape)
  - [The doors: `build` and `view`](#the-doors-build-and-view)
  - [Looks as values, checked while building](#looks-as-values-checked-while-building)
  - [Recursion](#recursion)
  - [Handlers that work for any dependency](#handlers-that-work-for-any-dependency)
- [Asserting where the world comes in](#asserting-where-the-world-comes-in)
- [How it runs](#how-it-runs)
- [How the walk compiles](#how-the-walk-compiles)
- [Tools over the walk](#tools-over-the-walk)
- [std's policy for the walk](#stds-policy-for-the-walk)
- [What stays out](#what-stays-out)
- [Borrowed from](#borrowed-from)
- [What changes elsewhere](#what-changes-elsewhere)
- [When each part lands](#when-each-part-lands)
- [Open questions](#open-questions)

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
Transfer.size     // bytes, once the memory stage decides layouts: a fact of this build
PageHeader.disk.size  // a format's size, promised (formats.md)
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
pub fn decode<T>(text: Str) -> T ! Problem =
  let doc = try parse(text)
  try from_doc(T.shape, doc)
```

- **Inside, a library works with a dynamic view.** The fields of `User`
  have different types, so a loop over them sees each field's value as a
  `Value`, and builds the `User` with a check that can't fail when the
  shape drove it. The dynamic part stays inside a few format libraries,
  written once. Their users see a typed `json.decode`.
- **Errors carry a path:** `Mismatch(at: "users[3].email", expected:
  "Str", found: "a number")`, from the `Problem` set every library
  shares ([formats.md](formats.md#errors-carry-paths)).
- **Debug builds read the shape as they go,** as Go's `encoding/json`
  does. That costs nothing at build time.
- **Release builds unroll it.** The shape is a constant, so specialization
  turns `decode<User>` into straight-line code, as fast as Rust's serde,
  without macros.
- **Looks say how a type looks to one library or version:** a field
  renamed for json, a tag spelled as a route, a version of a message
  ([formats.md](formats.md#a-type-and-its-formats)). A look is declared
  apart from the type, and a library's settings name the looks it
  walks through. There are no per-field attributes. A binary layout on
  disk or the wire is a layout, with fields placed one by one.
- **`bin` is the binary one,** `bin.encode(v)` and `bin.decode<T>(b)`:
  compact, nothing to declare, and **not for disk.** Its bytes follow
  the type, so they change when the type does, and nothing records an
  old version. It's for messages between processes of one build and
  for caches thrown away; anything that outlives the build that wrote it
  is a layout ([formats.md](formats.md#layer-1-the-derived-encoding)).
- **A type with a function in it has no shape to decode,** as it has no
  `==` ([operators.md](operators.md)).

The structural walk that derived `==`, `hash` and `show` use is the same
knowledge. The journal is the first format written this way. It's the
one derived format kept on disk across builds, so it records a hash of
each shape it encodes, and replaying it against a type that has
changed fails, naming the type, instead of decoding wrong
([testing.md](testing.md)).

### The walk

**Who owns what,** by decision 20 (the full table is
[formats.md's](formats.md#a-type-and-its-formats)):

| Owner | Here |
|---|---|
| **Language** | the walk and its reserved names; `T.shape` and `shape.through`; the doors `build<T>` and `view<T>`; `Look` values; absence at the door; build-time checks; recursion's `Ref`; a dep's `call(c: D.Call)` clause beside `over any` |
| **Compiler** | specialization per (type, looks); recursive walks as recursive functions ([How the walk compiles](#how-the-walk-compiles)) |
| **Toolchain** | `ren explain` and hover; freezing ([Tools over the walk](#tools-over-the-walk)) |
| **std** | settings records; casing; strictness; json's sums, `null` and numbers; text media; first error or all; depth limits; the wire for deps ([std's policy for the walk](#stds-policy-for-the-walk)) |

Every derived format walks a type. **The walk stops at a type that has
the method of its name:** `show` to print, `key` to compare, `parse` to
come in, `repr` to go out. `parse`'s parameter type is what gets read,
and `repr` returns that same type. These names are reserved, so the
walk behaves the same in every library.

For encodings, it picks **per value, in this order:**

1. **The look a field names:** `total: Money.cents` in the enclosing
   look.
2. **The look the caller names for the type:** `Time.unix` in the looks
   passed to `shape.through<T>(looks)`.
3. **The type's `parse` and `repr`.**
4. **The structure:** a record's fields, a sum's cases, a primitive.

```ren
let API = json.settings(keys: camel_case, formats: [Time.unix, Order.v1])

json.encode(order, API)
// Order:        2, the caller's Order.v1
//   total:      1, Money.cents, named by Order.v1
//   placed:     2, the caller's Time.unix
//   customer:   3, CustomerId.repr
//   lines:      4, an array; each Line by its structure
```

- **One order, everywhere.** Every library and generated test uses it.
  A library never chooses.
- **It's Effect v4's `toCodecJson` order** (explicit encoding on the
  node, then the type's own annotation, then structure), with the
  caller's choice added between 1 and 3. Effect's annotations are Ren's
  `parse`/`repr`, ordinary methods found by one rule.
- **Looks compose without being named.** A field as itself inside a
  look follows the caller's list (step 2); naming a look on it
  (`total: Money.cents`) pins it, which is what lets a version pin one
  field while the rest follows the caller. Freezing the top-level value,
  not the look, makes that safe for wire contracts
  ([Freezing what is sent](#freezing-what-is-sent)).
- **An opaque type outside its module has no structure.** If 1 to 3
  find nothing, `shape.through` fails: "`Money` has no look here: give
  it `parse` and `repr`, or name a look".
- **The encoded side of a `via` is walked again** by the same order, so
  looks chain (`Time.unix` gives an `Int`, and a look for `Int` the
  caller names applies). A cycle is a build error.

### `T` through looks is a shape

A library never sees a look. It sees a shape:

```ren
pub fn decode<T>(text: Str, s: Settings = DEFAULT) -> T ! Error
  let sh = try shape.through<T>(s.formats)     // while building, per call site
=
  let doc = try parse_text(text, s)
  try shape.build<T>(try to_value(sh, doc, s), s.formats)
```

- **`shape.through<T>(looks)` is `T.shape` with the walk applied.**
  Renamed fields carry their new names, constants are nodes, sum cases
  carry their tags, and a `via` or `parse` node shows only its encoded
  side. `looks` is an `Array<Look>`, a plain value.
- **It fails with `LookError`** on two looks for one type, an opaque
  type it can't read, or (for writing) a type with no `repr` that no
  look writes. In a signature `let`, as above, that's a build error at
  the call.
- **The shape gains these** (`shape` module):

  ```ren
  pub type Field = { name: Str, of: Str, exact: Bool, shape: Shape,
                     default: Option<Value>, doc: Str }
  //   name: the name in the look; of: the type's field, for errors;
  //   exact: written in a look, so a library's casing can leave it alone
  pub type Shape = ...
    | Const(value: Value)                         // `kind = "order"`
    | Sum { name: Str, cases: Array<Case>, doc: Str }
    | Text                                        // a leaf read from a string by `parse(Str)`
  pub type Case = { name: Str, tag: Value, holes: Array<Str>,
                    fields: Array<Field>, positional: Bool, doc: Str }
  //   tag: the case's typed constant (its name as a `Str` by default)
  //   holes: the fields the tag names, for a tag with holes
  //   positional: the payload has no field names, `Put(Version)`
  ```

  There's no tag placement in the shape. Where a tag goes is a
  library's spelling. A case reshaped by lines under it has those lines'
  fields, as one reshaped by a named look does.

### The doors: `build` and `view`

- **Conversions run in the doors, never in the library.** `build<T>`
  calls `read` and `parse`; `view<T>` calls `write` and `repr`. The
  compiler writes both for each `T` and look set. So a library is a
  `match` over data, and can't skip a type's rules.
- **Absence is decided at the door.** A field missing from the `Value`
  gets its default, or `None` for an `Option`, else `Missing`. A
  constant that differs is `Invalid`. How a medium says "missing"
  (`null`, an absent key, an empty column) is the library's.
- **`build<T>` stops at the first problem, or collects all,** as its
  caller asks. Each library picks its default.
- **A missing `repr` is found by `view<T>`,** with the path. So
  `json.encode(cfg)` with a `Secret` inside fails, naming
  `Cfg.admin_token`.
- **`Opaque` leaves the shape.** Outside its module, an opaque type
  appears only as the encoded side of its `parse`, so no library can
  see its representation or build one that breaks its rule.

### `Value`, the dynamic view

**`Value` is an ordinary sum type.** What's dynamic about decoding is
the step from data to a `T`, which can fail, and that step is the
doors'. Nothing else is privileged: no `Any`, no downcast, no
reflection.

```ren
pub type Value =
  | Bool(Bool) | Int(Int) | Float(Float) | Text(Str) | Bytes(Bytes)
  | Decimal(Decimal)
  | List(Array<Value>)
  | Map(Array<(Value, Value)>)          // a Map's entries, in order
  | Fields(Array<(Str, Value)>)         // a record, in the shape's order
  | Case(tag: Value, fields: Value)     // a sum's case
  | None                                // an Option present and empty
```

- **Its leaves are Ren's scalars, not a medium's.** There's no `null`:
  absence is decided at the door. `Fields` and `Map` are apart; which a
  json object is depends on the shape the library was given.
- **It's public in std's `shape` module, not the prelude.** `import
  shape` marks a module that works with the dynamic view, which is
  format libraries and tools that walk shapes.
- **Its door is the identity:** `build<Value>(v)` is `v`, so
  `json.decode<Value>(text)` is every medium's untyped decode, and
  `json.encode(v)` writes one back. Each medium documents its mapping
  with no shape: for json, an object is a `Map` with `Text` keys,
  `null` is `None`, and a number is an `Int` when it's whole, else a
  `Decimal`, read from its text.
- **A medium's exact bytes are its `Raw`,** not a dynamic type of its
  own: a field typed `json.Raw` keeps its sub-document unparsed, byte
  for byte, at no cost, to forward or decode later
  (`json.decode<Webhook>(raw)`); a record's bag of fields it doesn't
  model is `extra: Map<Str, json.Raw>`. Go's `json.RawMessage` and
  serde's `RawValue`. So a program never needs a `json.Doc`: `Value` is
  the tree for exploring and converting between media, and `Raw` is the
  medium, exactly.
- **What an untyped decode loses is the medium's own scalars:** a TOML
  datetime is `Text`, and a `Time` only when a shape asks through
  `Time`'s `parse`. A tool that needs the medium exactly takes its
  `Raw` or its library's parser.
- **Release builds make no `Value` tree** ([How the walk
  compiles](#how-the-walk-compiles)); debug builds run it as written.
  The doors are copies keyed by the type's shape hash and the look
  set's ([module-build.md](module-build.md#incremental-by-construction)).

### Looks as values, checked while building

- **`Look` is a value type.** `formats: [Time.unix, Order.v1]` is an
  `Array<Look>`. A library may store it in its settings, pass it
  through its own functions, and compare looks with `==`. Its
  representation is the compiler's.
- **Build-time checks use one mechanism:** top-level `let` and
  `assert`, and a signature `let` that runs once per call site
  ([strings.md, Templates](strings.md#templates)). A library checks a
  type against its settings in a signature `let`, so
  `json.decode<Order>(text, API)` is checked while building, at that
  call. `let CLI = cli.spec<Cmd>(positional: ["key"])` fails the build
  on a misspelled positional the same way: cli's check is ordinary
  code.
- **So settings must be known while building:** a literal, or a
  top-level value. Settings known only at run time are a build error
  at the call, whose help says to bind them with a top-level `let`, or,
  for a limit, to pass it as `limits:`.
- **What shapes the code is known while building; what bounds the work
  is a value.** Settings shape the plan (casing, unknown keys, looks,
  tags), so they're constants. Limits only bound the work (bytes,
  depth, items, a string's bytes), one comparison each at run time, so
  they're values, read from config if a program likes. A library takes
  them as their own argument with safe defaults, `limits:`, never as
  fields of its settings: `json.decode<Order>(text, API, limits:
  cfg.limits)`. Every format shares std's one record, `Limits { bytes:
  16.mib, depth: 64, items: 1_000_000, str_bytes: 1.mib }`; a library
  with other limits (http's header and body sizes) declares its own the
  same way. It's library policy (decision 20, rule 5); the language's
  part is only that a signature `let` reads what's known while
  building, which forces the split.

### Recursion

- **A recursive type's shape refers to itself by name** (`Ref`), and a
  look of it can name itself on a field: `children: Tree.v1`.
- **Encoding always ends:** Ren values are finite and acyclic.
- **Generators stop,** per testing.md: a recursive case is chosen less
  as depth grows.
- **Depth limits are each library's** ([below](#settings-records)).

### Handlers that work for any dependency

A handler `over any` already works for every dependency
([handlers.md](handlers.md#over-any)). Its one arm, `call =>`, runs for
each operation of whatever it's installed over:

```ren
pub handler traced() over any uses Clock, Console =
  call =>
    let start = Clock.instant()
    let r = attempt call.forward()
    Console.error(call.name + " took " + show(Clock.instant() - start))
    try r
```

- **`over any` stays as built.** It covers every dependency, data or
  not, and the journal is one: the prelude's recorder is an `over any`
  handler. `call.args` is opaque, and `call.forward()` is the only way
  on.
- **Beside it, a handler `over D`, for a `D` whose operations are all
  data, may write `call(c: D.Call)`.** `c` is the call as data, the
  sum the compiler writes for `D` ([formats.md, "Dependencies as
  data"](formats.md#dependencies-as-data)), and `next.call(c)` is
  `D.call(c)` against the next handler, giving a `D.Reply`. The
  operation and its arguments are the case and its fields, so a handler
  can `match` on them, log them with `show`, or hand them to any
  library. It's a contextual keyword, like `task` and `finally`.

  ```ren
  handler audited() over Keys uses Console =
    call(c: Keys.Call) =>
      Console.error(show(c))       // Put { key: "a", value: ..., expect: None }
      try next.call(c)
  ```

- **It handles every operation the handler doesn't write itself.** A
  handler `over Keys` can write `get` itself and send the rest through
  `call`. Without `call`, an operation an `over` handler doesn't write
  goes to `next` unchanged, as
  [handlers.md](handlers.md#over-one-implementation-in-front-of-another)
  says.
- **`D.Call`, `D.Reply` and `D.Error` are data with shapes,** so
  `cli.parse<Keys.Call>` is a CLI over the dependency, and a route table
  is a look of `Keys.Call`, with no new rule.
- **Errors on the header** (`pub dep Keys ! Unavailable =`) apply to
  every operation and appear in `D.Error`.

What it makes into ordinary libraries:

| Handler | What it does |
|---|---|
| `traced()` | times and logs every call |
| `Async.limit(n) over D` | at most n calls at once ([async.md](async.md)), no longer built in |
| `retry(n)` | retries any operation |
| `mock<D>()` | a test implementation of any dependency, recording calls and giving scripted answers |
| `recorder()`, `replayer()` | the journal ([handlers.md](handlers.md#the-journal)), for user dependencies too |
| `http.client<D>(addr)` | sends every call of an all-data `D` to another machine, as a `D.Call` |

`http.client` makes a dependency remote without changing the code that
uses it. [runtime-io.md](runtime-io.md#three-rules) says a call is a
value, and `D.Call` makes that true for every dependency whose
operations are data.

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

## How the walk compiles

The compiler's part, invisible: none of it changes what a program means.

- **Specialization per (type, looks).** Settings are known while
  building, so release builds turn `decode<T>` into straight-line code:
  a key switch, the `via` and `parse` calls inline, no `Value` tree. A
  closed world knows every pair. That's two steps. First, specialize.ml
  keys copies on a known constant argument (today it keys on types,
  blocks and evidence only). Second, it unfolds the library's own
  `match` over a constant `Shape` (stage 12's risk 2). If the second
  misses the 12a measurement, the fallback is a visitor the compiler
  writes per (T, looks), with leaf callbacks as blocks.
- **Debug builds read the shape as they go,** matching on each `Look`.
  The same program, slower.
- **The 12a measurement covers looks:** `json.decode<Order>` through
  `Order.v1` must be within 1.5× of a hand-written decoder.
- **Recursive walks** become recursive functions, one per (type,
  looks).
- **This is what Effect v4 added a JIT and an AOT compiler for**
  (`SchemaAOTCompiler`, with a fallback interpreter for
  transformations).

## Tools over the walk

The toolchain reads the language, never a library.

### Seeing the walk

Step 2 and chaining reach places you can't see from the call. So
showing the walk ships with looks, not later:

```
$ ren explain API for Order
Order                 Order.v1             (2: the caller)
  kind                "order"              constant
  id         -> id    Int                  (3: OrderId.repr)
  customer   -> customerId  Int            (3: CustomerId.repr)
  total      -> total Int                  (1: Money.cents, named in Order.v1)
  placed     -> placed Int                 (2: Time.unix)
```

- **It reads the language, not a library.** `ren explain V for T`
  finds the `Look` values in the top-level value `V`, whatever library
  it belongs to, and prints `shape.through<T>` of them: per field, the
  look's name, the encoded type, and the step that chose it. A
  library's spelling (json's casing) isn't shown; the shape is.
- **The editor shows the same** on hover over a top-level value or a
  call.
- **A look in a value that no walk reaches** is a warning from `ren
  review`: it probably means a missing field-named look elsewhere.

### Freezing what is sent

- **The unit frozen is a top-level value.** `ren formats freeze
  KEYS_V1` records, in `formats.lock`, a fingerprint of the value and
  of every `shape.through<T>(looks)` the build evaluates over its
  looks, in a top-level `let` or at a call site's signature `let`. No
  keyword marks it, and the toolchain needs no knowledge of the
  library.
- **Why not freeze looks one by one:** a field as itself in `Order.v1`
  follows the caller's choices, so `Order.v1` alone doesn't fix the
  bytes. The top-level value does, settings and all: it's what a
  protocol version is.
- **The fingerprint covers meaning, not only shape.** It holds the
  encoded shapes, the value itself (it's data, so casing and other
  settings are in it), each look's qualified name, and an IR hash of
  every `via`, `parse` and `repr` function the walk reaches. If
  `Time.from_unix` changes from seconds to milliseconds, the build
  fails like a changed field: "`KEYS_V1` is frozen, and
  `Time.from_unix` changed".
- **The IR hash is new work.** No content hashes exist today. The plan:
  hash Core's printed form (`ren core` already prints it) of each
  function and its callees.
- **A library's own code isn't in the fingerprint.** It covers the
  program's declarations and `via`s, which the toolchain can read
  without knowing a library. A change in how std's json spells what it
  writes is a breaking std release, by std's policy; the lock doesn't
  watch library code, or every std edit would trip every lock.

## std's policy for the walk

Each rule is one library's default (decision 20, rule 5). Consistency
across std is a written convention, below. json's sums, http, `Secret`
and `Unavailable` are in [formats.md, "std's policy for looks"](formats.md#stds-policy-for-looks).

### Settings records

```ren
let API = json.settings(keys: camel_case, formats: [Time.unix, Order.v1])
let LENIENT = json.settings(..API, unknown: Ignore)
let CLI = cli.spec<Cmd>(positional: ["key"], short: [("json", "j")], formats: [Addr.hostport])
```

- **Each std library has one settings record.** Its fields are its
  knobs (casing, unknown keys) and `formats: Array<Look>`. Limits
  aren't settings: they're the `limits:` argument (above).
  This is a convention, not a language rule; a third-party library may
  do otherwise.
- **Settings are data,** known while building. `{ ..API, unknown:
  Ignore }` is record update, in a top-level `let`.
- **`Limits.depth`, 64 by default,** in every format library's
  `limits:`. Past it is `TooDeep(at, limit)`; past the others,
  `TooLarge(at, what, limit)`.

### Names, casing and renames

- **`keys:` re-cases only names not marked exact,** fields as
  themselves and `..`. `customerId = customer` stays `customerId` under
  `keys: snake_case`; that's what writing it meant.
- **Case names are not re-cased.** A tag is the case name as written,
  or the look's `as`.
- **Map keys are data, never re-cased.**
- **Two names that land on one** after casing are the library's
  build-time error, reported where its settings meet the look.
- **Media with one spelling map every name into it.** An env var is
  `PREFIX_` plus the name in upper snake case; a flag is the name in
  kebab case. A look's rename is the input: `listen = addr` gives
  `--listen` and `FLOTT_LISTEN`. json keys and sql columns can hold any
  name, so they use names as they are.

### Strict decoding

- **Strict by default:** an unknown key is `Unknown(at)`; keys match
  case-sensitively; a duplicate key or invalid UTF-8 is a syntax error.
- **`unknown: Ignore`** drops unknown keys, for a whole call. There's no
  per-look switch: a reader that must accept a newer writer either
  ignores for the whole message or reads through the newer version's
  look.
- **Docs follow the decoder.** A JSON Schema or OpenAPI library says
  `additionalProperties: false` unless the settings say `Ignore`. Effect
  v4's JSON Schema says `true` because its decoder ignores by default.
- **cli is always strict.** An unknown flag is a usage error with "did
  you mean".

### First error or all

- **json, msgpack, cli and http stop at the first problem.**
- **config collects all,** because it merges sources and a user fixes a
  file once.
- Each is its library's default, passed to `build<T>`.

### Absence, numbers and keys in json

| On decode | The field is `Option<T>` | The field has a default | Neither |
|---|---|---|---|
| key absent | `None` | the default | `Missing` |
| `null` | `None` | `Mismatch` | `Mismatch` |
| a value | `Some(v)` | `v` | `v` |

- **On encode, `None` is left out,** and a defaulted field is always
  written. `none: Null` writes `null` instead.
- **`Option<Option<T>>` has no json reading.** json's check fails with
  help: it usually means a PATCH's "keep, clear, or set", which is a
  sum, `type Patch<T> = Keep | Clear | Set(T)`.
- **Numbers.** `Int` is exact number text, read with a range check,
  never switched by the value's size. std ships `format str for Int =
  Str via (Int.parse, fn(i) => i.show())` for JavaScript readers. A
  non-finite `Float` panics on encode, naming the path.
- **`Bytes`** is padded base64; std ships `Bytes.base64url` and
  `Bytes.hex` as looks.
- **A map key goes through its type's text form:** `Str`, `Int` as
  decimal text, a fieldless sum as its name, or a type with `parse(s:
  Str)` and `repr` to `Str`. Anything else fails json's check, with help
  to use `Array<(K, V)>`. Keys are never re-cased. The other std
  libraries with keyed maps follow the same rule.

### Sums in json

- **An internal tag named `"type"`:** `{"type": "Placed", ...}`, the
  tag from the shape (the case name as written by default). `type` is
  a keyword, so no field collides. `tag: Adjacent("type", "data")` in
  the settings puts the payload under `"data"`. A field named like the
  tag field fails json's check.
- **Where the payload goes, one rule:**
  - a case with named fields puts them beside the tag:
    `{"type": "Placed", "order": ..., "by": 7}`;
  - a case with one record payload merges that record's fields:
    `Get(Entry)` is `{"type": "Get", "key": ..., "value": ...}`;
  - any other payload goes under `"value"`: `Put(Version)` is
    `{"type": "Put", "value": 1}`;
  - a case with no payload is `{"type": "Delete"}`.
- **A fieldless sum stays an object.** A json API that wants
  `"role": "Admin"` gives `Role` `parse(Str)` and `repr`, or names a
  look `format name for Role = Str via (...)`.
- **json reads `Str` tags.** Any other tag type fails json's check.
- **If the tag isn't first,** the release decoder rescans once; it
  doesn't buffer a tree.

### Text media read names

**cli, env, query strings and sql text read a fieldless sum as its case
name:** `--role admin`, `?mode=merge`, `FLOTT_SYNC=Group`. That's their
syntax. A transport that knows the case drops the tag: http's REST reply
does, because the route says which case it is.

### How each library reads it

All of them call `shape.through<T>(s.formats)` and walk the result.

| Library | Records | Sums | Leaves |
|---|---|---|---|
| **json** | objects, by name | internal or adjacent tag, payload by the rule above | `Int` and `Decimal` as exact number text; `Float` shortest round-trip; `Bytes` as base64; `Text` as a string |
| **msgpack** | maps, by name | as json | native ints, floats and `bin` |
| **cli** | flags, by name in kebab case | subcommands; fieldless sums as choices | read from text: `Text`, `Int`, `Float`, `Bool`, `Str`, `Path` without UTF-8 |
| **config** | sections, keys; env as `PREFIX_A__B` | as json in files, as text in env | as cli in env and flags, as json in files |
| **sql rows** | columns, by name | fieldless sums as text; others its error | column types; anything else through a look to a column type |
| **query, path, headers** | one level of fields | fieldless sums as text | read from text, as cli |
| **bin** | positional | case index | its own; no settings, no looks, but `parse`/`repr` apply |

- **A leaf a text medium can't read** fails that library's check:
  "`Region` can't come from a flag: give it `parse(s: Str)`, or name a
  look `= Str via ...`". The medium reads what `parse` takes.
- **cli's spec keeps what isn't naming:** positionals and short flags,
  by the look's names. Renamed flags are a look of the command type.
- **One look serves every library.** `listen = addr` in a look of
  `Cfg` is `"listen"` in the json file, `FLOTT_LISTEN` in env and
  `--listen` as a flag. A look says names and shapes; a library says
  syntax.

### Dependencies over the wire

These are std's, built on the language's pieces with nothing special:

- **A route table** is a sum look of `D.Call` whose tags are
  `http.Route` values; **statuses** are a `writes` look of `D.Error`
  whose tags are `Int`s and may repeat
  ([formats.md, http](formats.md#http)).
- **Path holes** read through `parse(Str)`; bodies through the call's
  json settings, in the query or the body by method. Headers and raw
  bodies come in the http stage, as http's own template lines.
- **`Unavailable(why: Why)`** is declared once in `std.remote`. `Why`
  is `Refused | Timeout | Decode(Problem) | Protocol | Version | Denied
  | Server`, so a caller can tell a down server from a version clash or
  a bad token (Effect v4's `RpcClientError` reason, but declared). A
  dep puts it on its header; std's client handler fails with it.
- **A reply on the wire is `Result<D.Reply, D.Error>`,** the `Err`
  side a named error set with a shape.
- **The envelope** (call id, reply, defect, cancel, and a reserved
  `Chunk` for streams later) is a small fixed sum in std, framed apart
  from the payload look, as Effect v4's `RpcSerialization` frames its
  envelope and codes only the holes.
- **The version check** is the envelope's. std hashes
  `shape.through<D.Call>` and `shape.through<D.Reply>` for the chosen
  looks (shapes are data, so any library can), sends it once per
  connection (a `ren-shape` header on REST), and a mismatch is
  `Unavailable(Version)`. A write the chosen version can't express
  fails `NotInVersion` in its look and is refused, never trimmed.
- **Transports** are deps; `http.client<D>` and a socket transport
  satisfy one interface.

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
| `D.shape` and `over any`; generic handlers; `f.uses` | after concurrency, since it rebuilds `Async.limit` and the recorder |
| Looks, `shape.through`, the doors, `ren explain`, freezing | stage 12a |
| `D.Call`, `D.Reply`, `D.Error`; `call(c: D.Call)` | stage 12c |
| `Transfer.size` | the memory stage, which decides layouts |
| The build's world, its journal, granting | with packages |

## Open questions

- **How `call` is typed.** Inside `call`, a reply belongs to whichever
  operation was called, and so do its errors. `try r` should pass on that
  operation's errors and no others. The checker needs a type for "the
  reply of `op`" that a handler can pass along but not invent, except
  through a check, as `mock` does.
- **Is `f.uses` the inferred set or the declared one?** For a pub
  function they're the same. For a private one, the inferred set is what's
  true.
- **What's the build's time budget,** and can a module raise it?

# Draft for shapes.md: the walk, looks and settings

Draft, 2026-10-29. Updated with judge.md's fixes, the owner's rulings on
synthesis §4, feasibility.md's corrections, and foundations decision 20
("What the language owns, and what std owns"). Nothing in the repo is
edited. This replaces the bullets in shapes.md's "Libraries that work
for any type" from "Renames and defaults are settings on the format"
through "An opaque type's shape is opaque outside its module", and adds
the sections below after it. It assumes synthesis A1 to A4 (`shape` is
a built-in requirement; `Shape` and `Value` are ADTs behind `view<T>`
and `build<T>`; `parse` in, `repr` out; field defaults). Looks are
defined in [draft-formats.md](draft-formats.md). Effect references are
v4 only.

## Who owns what

| Owner | Here |
|---|---|
| **Language** | the walk and its reserved names; `T.shape` and `shape.through`; the doors `build<T>` and `view<T>`; `Look` values; absence at the door; build-time checks through top-level `let`; recursion's `Ref`; a dep's `call(c: D.Call)` clause beside `over any` |
| **Compiler** | specialization per (type, looks); recursive walks as recursive functions |
| **Toolchain** | `ren explain` and hover; freezing |
| **std policy** | settings records; casing; strictness; json's sums, `null` and numbers; text media; first error or all; depth limits; the wire for deps: `Unavailable`, the envelope, transports |

The language owns reshaping; libraries own spelling.

---

# Part 1. Language

## The walk

Every derived format walks a type. **The walk stops at a type that has
the method of its name:** `show` to print, `key` to compare, `parse` to
come in, `repr` to go out. `parse`'s parameter type is what gets read,
and `repr` returns that same type. These four names are reserved, so
the walk behaves the same in every library.

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
- **It is Effect v4's `toCodecJson` order** (explicit encoding on the
  node, then the type's own annotation, then structure), with the
  caller's choice added between 1 and 3. Effect's annotations are Ren's
  `parse`/`repr`, ordinary methods found by one rule.
- **An opaque type outside its module has no structure.** If 1 to 3
  find nothing, `shape.through` fails: "`Money` has no look here: give
  it `parse` and `repr`, or name a look".
- **A field-named look beats the caller.** That's what lets a version
  pin one field while the rest follows the caller.
- **The encoded side of a `via` is walked again** by the same order, so
  looks chain (`Time.unix` gives an `Int`, and a look for `Int` the
  caller names applies). A cycle is a build error.

## `T` through looks is a shape

A library never sees a look. It sees a shape:

```ren
pub fn decode<T>(text: Str, s: Settings = DEFAULT) -> T ! Error =
  let doc = try parse_text(text, s)
  let sh = try shape.through<T>(s.formats)
  try shape.build<T>(try to_value(sh, doc, s), s.formats)
```

- **`shape.through<T>(looks)` is `T.shape` with the walk applied.**
  Renamed fields carry their new names, constants are nodes, sum cases
  carry their tags, and a `via` or `parse` node shows only its encoded
  side. `looks` is an `Array<Look>`, a plain value.
- **It fails with `LookError`** on two looks for one type, an opaque
  type it can't read, or (for writing) a type with no `repr` that no
  look writes.
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

  There is no tag placement in the shape. Where a tag goes is a
  library's spelling.

## The doors: `build` and `view`

- **Conversions run in the doors, never in the library.** `build<T>`
  calls `read` and `parse`; `view<T>` calls `write` and `repr`. The
  compiler writes both for each `T` and look set. So a library is a
  `match` over data, and can't skip a type's rules.
- **Absence is decided at the door.** A field missing from the `Value`
  gets its default, or `None` for an `Option`, else `Missing`. A
  constant that differs is `Invalid`. How a medium says "missing"
  (`null`, an absent key, an empty column) is the library's, Part 4.
- **`build<T>` stops at the first problem, or collects all,** as its
  caller asks. Each library picks its default (Part 4).
- **A missing `repr` is found by `view<T>`,** with the path. So
  `json.encode(cfg)` with a `Secret` inside fails, naming
  `Cfg.admin_token`.
- **`Opaque` leaves the shape.** Outside its module, an opaque type
  appears only as the encoded side of its `parse`, so no library can
  see its representation.

## Looks as values, checked at the top level

- **`Look` is a value type.** `formats: [Time.unix, Order.v1]` is an
  `Array<Look>`. A library may store it in its settings, pass it
  through its own functions, and compare looks with `==`. Its
  representation is the compiler's (Part 2).
- **Build-time checks use one mechanism: top-level `let` and
  `assert`.** `shape.through<T>(looks)` in a top-level value runs at
  build time, so its `LookError` is a build error. A library's own
  checks run the same way. `let CLI = cli.spec<Cmd>(positional:
  ["key"])` fails the build on a misspelled positional, because it is
  a top-level `let` and cli's check is ordinary code.
- **A library that wants its pair checked at build time** offers a
  value that names the type: `let ORDERS = json.codec<Order>(API)`. A
  direct `json.decode<Order>(text, API)` checks when it runs (boundary
  note 1).

## Recursion

- **A recursive type's shape refers to itself by name** (`Ref`), and a
  look of it can name itself on a field: `children: Tree.v1`.
- **Encoding always ends:** Ren values are finite and acyclic.
- **Generators stop,** per testing.md: a recursive case is chosen less
  as depth grows.

## A dependency's calls

shapes.md's "Handlers that work for any dependency" keeps its `call`
clause as built: `over any`'s `call =>` covers every dependency, data or
not, and carries the journal. Beside it:

- **A handler `over D`, for an all-data `D`, may write
  `call(c: D.Call)`.** `next.call(c)` is `D.call(c)` against the next
  handler. The operation and its arguments are the case and its
  fields, so a handler can `match` on them, log them with `show`, or
  hand them to any library.
- **`D.Call`, `D.Reply` and `D.Error` are data with shapes**
  ([draft-formats, "Dependencies as data"](draft-formats.md#dependencies-as-data)).
  `cli.parse<Keys.Call>` is a CLI over the dependency with no new rule.
- **Errors on the header** (`pub dep Keys ! Unavailable =`) apply to
  every operation and appear in `D.Error`.

---

# Part 2. Compiler (invisible)

- **Specialization per (type, looks).** When the looks are a top-level
  constant, release builds turn `decode<T>` into straight-line code: a
  key switch, the `via` and `parse` calls inline, no `Value` tree. A
  closed world knows every pair. feasibility.md: this is two steps.
  First, specialize.ml keys copies on a known constant argument (M-L;
  today it keys on types, blocks and evidence only). Second, unfold the
  library's own `match` over a constant `Shape` (L; stage 12's risk 2).
  If the second misses the 12a measurement, the fallback is a visitor
  the compiler writes per (T, looks), with leaf callbacks as blocks
  (M).
- **Debug builds read the shape as they go,** matching on each `Look`.
  The same program, slower.
- **The 12a measurement covers looks:** `json.decode<Order>` through
  `Order.v1` must be within 1.5× of a hand-written decoder.
- **Recursive walks** become recursive functions, one per (type,
  looks).
- **This is what Effect v4 added a JIT and an AOT compiler for**
  (`SchemaAOTCompiler`, with a fallback interpreter for
  transformations).

---

# Part 3. Toolchain

## Seeing the walk

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
  library's spelling (json's casing) is not shown; the shape is.
- **The editor shows the same** on hover over a top-level value or a
  call.
- **A look in a value that no walk reaches** is a warning from `ren
  review`: it probably means a missing field-named look elsewhere.

## Freezing what is sent

- **The unit frozen is a top-level value.** `ren formats freeze
  KEYS_V1` records, in `formats.lock`, a fingerprint of the value and
  of every `shape.through<T>(looks)` evaluated while building it at
  build time. No keyword marks it, and the toolchain needs no
  knowledge of the library.
- **Why not freeze looks one by one:** a field as itself in `Order.v1`
  follows the caller's choices, so `Order.v1` alone doesn't fix the
  bytes. The top-level value does, settings and all: it is what a
  protocol version is.
- **The fingerprint covers meaning, not only shape.** It holds the
  encoded shapes, the value itself (it is data, so casing and other
  settings are in it), each look's qualified name, and an IR hash of
  every `via`, `parse` and `repr` function the walk reaches. If
  `Time.from_unix` changes from seconds to milliseconds, the build
  fails like a changed field: "`KEYS_V1` is frozen, and
  `Time.from_unix` changed".
- **The IR hash is new work.** No content hashes exist today (no
  `Digest` in `lib/` or `bin/`). The plan: hash Core's printed form
  (`ren core` already prints it) of each function and its callees.
  S-M.
- **A library's own code isn't in the fingerprint.** If json changes
  how it writes, that is json's versioning (boundary note 3).

---

# Part 4. std policy

Each rule is one library's default (decision 20, rule 5). Consistency
across std is a written convention, below.

## Settings records: the convention

```ren
let API = json.settings(keys: camel_case, formats: [Time.unix, Order.v1])
let LENIENT = json.settings(..API, unknown: Ignore)
let CLI = cli.spec<Cmd>(positional: ["key"], short: [("json", "j")], formats: [Addr.hostport])
```

- **Each std library has one settings record.** Its fields are its
  knobs (casing, unknown keys, limits) and `formats: Array<Look>`.
  This is a convention, not a language rule; a third-party library may
  do otherwise.
- **Settings are data.** `{ ..API, unknown: Ignore }` is record update.
- **Limits** like `max_bytes` can come from config at run time.
- **`max_depth: Int = 64`** in every std library's settings. Past it is
  `TooDeep(at, limit)`.

## Names, casing and renames

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

## Strict decoding

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

## First error or all

- **json, msgpack, cli and http stop at the first problem.**
- **config collects all,** because it merges sources and a user fixes a
  file once.
- Each is its library's default, passed to `build<T>`.

## Absence and `null` in json

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
- **Numbers.** `Int` is exact number text, read with a range check.
  std ships `format str for Int = Str via (Int.parse, fn(i) =>
  i.show())` for JavaScript readers. A non-finite `Float` panics on
  encode, naming the path.
- **`Bytes`** is padded base64; std ships `Bytes.base64url` and
  `Bytes.hex` as looks.

## Sums in json

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

## Text media read names

**cli, env, query strings and sql text read a fieldless sum as its case
name:** `--role admin`, `?mode=merge`, `FLOTT_SYNC=Group`. That is their
syntax. A transport that knows the case drops the tag: http's REST reply
does, because the route says which case it is.

## How each library reads it

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

## Dependencies over the wire

Not designed here. These are std's, built on Part 1 with nothing
special:

- **A route table** is a sum look of `D.Call` whose tags are
  `http.Route` values; **statuses** are a `writes` look of `D.Error`
  whose tags are `Int`s and may repeat
  ([draft-formats, http](draft-formats.md#http)).
- **Path holes** read through `parse(Str)`; bodies through the call's
  json settings. Headers and raw bodies come in the http stage, as
  http's own template lines.
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
- **The connect check** is the envelope's: std hashes
  `shape.through<D.Call>` and `shape.through<D.Reply>` for the chosen
  looks (shapes are data, so any library can), sends it once per
  connection (a `ren-shape` header on REST), and a mismatch is
  `Unavailable(Version)`.
- **Transports** are deps; `http.client<D>` and a socket transport
  satisfy one interface.

---

## The questions, with a recommendation each

**1. Does a look need Effect's `Type` and `Encoded` sides spelled out?**
(Language.) No. The `X` in `X via (...)` is the encoded side, written
once. A record or sum look's encoded side is its lines.
`shape.through` gives a library only the encoded side. If a name is
wanted for tools, `Order.v1.shape` is the encoded shape.

**2. Can looks compose implicitly?** (Language.) Yes. A field as
itself inside a look follows the caller's list (walk step 2). Naming it
(`total: Money.cents`) pins it. Freezing the top-level value (not the
look) makes the implicit case safe for wire contracts.

**3. Defaults on decode.** (Language.) The field's default, the one the
constructor uses, filled at the door. No look-level default at all.

**4. Casing versus explicit renames.** (Language marks names exact;
std re-cases.) A look's names are exact; `keys:` re-cases only the
rest. Env and flags map every name to their one spelling.

**5. `null` versus absent for `Option`.** (json.) Decode accepts both as
`None`. Encode leaves `None` out; `none: Null` writes `null`.

**6. Number precision.** (json.) Exact number text, a range check,
`Int.str` for JavaScript readers. Never switch by value size.

**7. `Bytes` in json.** (json.) Padded base64; `Bytes.base64url` and
`Bytes.hex` as looks.

**8. Maps with non-`Str` keys.** (std convention.) A key goes through
its type's text reading: `Str`, `Int` as decimal text, a fieldless sum
as its name, or a type with `parse(s: Str)` and `repr` to `Str`.
Anything else fails the library's check, with help to use
`Array<(K, V)>`. Keys are never re-cased.

**9. Recursion.** Shapes refer by name and looks may name themselves
(language); depth limits are each library's (std); release builds make
recursive functions (compiler).

**10. A look of `D.Call` and `D.Reply` as REST.** (Language gives the
sum look and tag holes; http gives routes and statuses.) It breaks no
rule: tags are typed constants, holes name fields, no type knows its
status, and every check runs at build time through a top-level `let`.

## Open questions

1. **Inline case looks.** Should a sum look allow reshape lines under a
   case, instead of a named look of each variant type? Fewer names
   against one spelling.
2. **Looks declared outside their type's module.** A look is an item of
   the module that declares it, private unless `pub`, named through the
   type. Two in scope with one name is an error at the import.
   feasibility.md: members of foreign types don't exist today; either
   an orphan rule or formats keyed by (type, module).
3. **Body and query placement in REST looks** is http's rule by method.
   Is a per-route override needed for 1.0?
4. **`lossy`** is one more word. `reads`/`writes` remove most uses of
   it; what is left is looks like `Time.unix` that keep less than the
   type.

Closed since the last draft: fieldless sums in json stay objects (json's
policy); `D.Error` is the compiler-written union; `formats` is an
`Array<Look>` and flows through parameters; writing a `Secret` goes
through a named look over `reveal` (std); first error or all is each
library's (json first, config all); remote failure is errors on the
header, with `Unavailable` from std; splicing a case is dropped.

## Boundary notes

1. **Pair checks need a top-level value.** Decision 20 allows build-time
   checks only through top-level `let` and `assert`, and rule 4 forbids
   specialization from adding errors. So `json.decode<Order>(text, API)`
   called directly checks at run time; the build-time guarantee needs
   `let ORDERS = json.codec<Order>(API)`. The old draft's "a settings
   record is checked against every type it's used with" had the
   compiler doing json's checks, which rule 3 rules out. Either std
   steers users to top-level codecs, or the language gains one general
   way for a generic function to check constant arguments at build
   time.
2. **`Case.holes`** is in the shape for http's route templates. It is
   general (any tag with holes), but http is its only user today.
3. **The fingerprint doesn't cover library code.** It covers the
   program's declarations and `via`s, which is what the toolchain can
   read without knowing a library. A json that changes its spelling
   breaks frozen bytes without the lock noticing. Hashing a library's
   reached code would fix it, at the cost of every std edit tripping
   every lock.
4. **`Problem`'s `Unknown` and `TooDeep`** are raised only by libraries
   but live in the language's set, for one spelling.
5. **`exact` on a field** exists so a library's casing can skip written
   names. It describes the declaration (written or derived), so it is
   language, but casing is its only reader.
6. **The `"type"` default and the `type` keyword:** json's default tag
   field can't collide because the language reserves `type`. A happy
   accident, not a rule.

# Draft for formats.md: a type, and its formats, for every encoding

Draft, 2026-10-29. Updated with judge.md's eight fixes, the owner's
rulings on synthesis §4, feasibility.md's corrections, and foundations
decision 20 ("What the language owns, and what std owns"). Nothing in
the repo is edited. This replaces formats.md's section "A type, and its
formats" and adds the sections after it, up to "Placing fields", which
stays as it is. Layer 2 (bytes) is unchanged; it becomes one of two
kinds of format. Effect references are v4 only (`/tmp/ren-refs/effect`,
see `effect-study.md`).

Other edits this implies, listed at the end: the title and opening
paragraph, the "Three layers" table, "Layer 1", "Left out" and "Later".

## Who owns what

Every rule below sits under one owner, by decision 20's five rules.

| Owner | What it holds here |
|---|---|
| **Language** | the `format` declaration and its vocabulary: names, subsets, constants, `via` conversions, tags as typed distinct constants, `reads`/`writes`/`lossy`; `Look` and `Layout` as values; `T.shape` and the typed doors; reserved names and walk order; build-time checks through top-level `let` and `assert`; `D.Call`, `D.Reply`, `D.Error` and errors on a dep's header |
| **Compiler** | how a look is represented, perfect hashes for constant matches, specialization. None of it changes meaning |
| **Toolchain** | `ren explain`, freezing, generated round-trip tests. They read the language, never a library |
| **std policy** | json's sum encoding and casing, strictness, first error or all, text media's names, http's routes, statuses, headers and bodies, `Secret`, `Unavailable` and `Why`, the envelope, transports |

The language owns reshaping; libraries own spelling. Nothing in Part 1
names a medium. Where an example uses json or http, it is the library
reading a look, and the rule it shows lives in Part 4.

---

# Part 1. Language

## A type, and its formats

**A type says what a thing is. A format says how it looks somewhere.**
A format is declared apart from its type and named through it:
`Time.unix`, `Order.v1`, `PageHeader.disk`. A type can have several.

There are two kinds, written with one declaration:

| Kind | What it has | Who reads it | Example |
|---|---|---|---|
| **Layout** | byte order, widths, offsets | the format itself: `view`, `edit`, `write`, `encode` | `format disk for PageHeader, le, size 32 =` |
| **Look** | names, tags, conversions; no byte order, no widths | any library, through a shape | `format v1 for Order =` |

- **The kind is read off the lines.** A line with a field kind from
  "What a field can be" (`UInt16`, `Bytes[16]`, `CStr`, `le`) makes a
  layout. A line with only names, looks and constants makes a look. A
  format that mixes them is a build error that names one line of each.
- **Looks and layouts are values.** `Time.unix` is a value of type
  `Look`; `PageHeader.disk` is a value of type `Layout`. They can be
  stored in a settings record, put in an array, compared with `==`,
  and passed between functions. A library's settings take
  `Array<Look>`, so passing a layout there is an ordinary type error.
  How a `Look` is represented is the compiler's (Part 2); no program
  sees it, and no closure is stored (README, "No stored closures").
- **A look has visibility, like a function.** It is private to the
  module that declares it unless marked `pub format`. A `pub` look may
  name only `pub` functions. Naming a private look from outside is
  "`Money.raw` is private to `money`". Otherwise a look declared next
  to a type could hand any program a private constructor.
- **A format's name shares its type's namespace.** `Time.unix` can't be
  both a look and a method. Same rule as `Users.x` in the README: one
  name, one meaning.
- **Still no standalone formats.** A look without a type would be an ad
  hoc record, a second kind of record.
- **A type with no look still has one: its default.** That is its
  `parse` and `repr` if it has them, else its structure
  ([shapes.md, "The walk"](draft-shapes.md#the-walk)). So most types
  never declare a look. A look is for "this type looks different
  here".

Effect v4 found the same split by accident: `Schema.toCodecJson` walks
a schema, and its binary codec (`SchemaBinary`) walks the same schema's
encoded side. Ren separates them on purpose: a layout promises bytes,
a look promises names.

## Looks of a scalar: `via`

```ren
format unix for Time = Int via (Time.from_unix, fn(t) => t.unix_seconds())
format cents for Money = Int via (Money.from_cents, fn(m) => m.cents())
format base64 for Bytes = Str via (base64.decode, base64.encode)
```

- **`X via (read, write)`** says "seen as an `X`". `read` is
  `X -> T ! E`. `write` is `T -> X`, or `T -> X ! E` when some values
  have no `X` (a v1 that can't carry v2's `ttl` fails `NotInVersion`).
  Either error reaches the caller as `Invalid(at, why)`, with the
  error's tag as `why`.
- **A look can go one way.** `reads` takes `via (read)` and can't
  encode; `writes` takes `via (write)` and can't decode. Using one in
  the wrong direction is a build error at the use. This is layer 2's
  `reads`, plus its mirror. `format text for Bytes = Str via
  (Str.bytes), reads` is a complete look; it needs no write function
  and no `lossy`.
- **`X` is what gets read.** It is walked by the same rules as any
  type, so it can be a record, a sum, or a type with its own look.
  There is no second type parameter.
- **Both functions are pure.** A `via` with a `uses` row is a build
  error. A look runs inside decoders, at build time in checks, and in
  generated tests; reaching the world there would be invisible.
- **A look that loses information says `lossy`:**
  `format unix for Time = Int via (...), lossy`. `Time` holds
  nanoseconds and `unix` keeps seconds. The word changes what the
  generated test checks (Part 3). It is a promise you can see, never
  inferred.
- **Looks chain.** If the call also chooses a look for `Int`, the `Int`
  side of `Time.unix` goes through it. A chain that comes back to its
  start is a build error.

## Looks of a record: lines

A record look uses layer 2's line form. Each line says where one name
in the look comes from:

```ren
type Order = {
  id: OrderId,
  customer: CustomerId,
  lines: Array<Line>,
  total: Money,
  placed: Time,
  note: Option<Str>,
  source: Source = Web,
  audit: Audit = Audit.none,
}

format v1 for Order =
  kind = "order"                  // a constant: written, and checked on read
  id                              // the field as itself
  customerId = customer           // renamed
  total: Money.cents              // through a look
  placedAt = placed: Time.unix    // renamed, through a look
  ..                              // the rest as themselves: lines, note, source, audit
```

| Line | Means |
|---|---|
| `id` | the field `id`, by its own name, walked by the call's choices |
| `customerId = customer` | the field `customer`, under the name `customerId` |
| `total: Money.cents` | the field `total`, through the look `Money.cents` |
| `placedAt = placed: Time.unix` | both |
| `kind = "order"` | a constant: written going out; coming in, missing is `Missing`, different is `Invalid` |
| `"@type" = "Order"` | a name that isn't an identifier is a string |
| `..` | every field not named above, as itself |

- **`=` has one meaning: the look's name is on the left.** The token on
  the right says what it is, with no lookup: a lowercase identifier is
  a field of the type; a literal or an uppercase constructor is a
  constant. A lowercase identifier that names no field is a build
  error. There is no `field = value` form in looks (layer 2 keeps it
  for layouts).
- **Without `..`, the look lists exactly what it carries.** A field it
  leaves out must have a default or be an `Option`, else it's a build
  error. Coming in, a left-out field gets its default or `None`. Going
  out, it isn't there. A value an old version lacks that has no
  default is a `via` to a wire type.
- **A `writes` look is a subset.** It can leave out any field, because
  nothing is read back: `format public for User, writes = id, name`
  hides `email` and `password_hash` wherever it is used. Using it to
  read is a build error.
- **A name written in a look is marked exact** in the shape. What a
  library does with that mark (json's casing leaves exact names alone)
  is the library's, Part 4.
- **Every name is written once.** Two lines giving one name, or a
  rename that lands on a name `..` also produces, is a build error.
- **No flattening, no nesting by path, no computed fields.** A field is
  carried, renamed, looked, or left out; a constant is a literal. A
  look that needs more is a `via` to a record written for the wire.
  That is layer 2's rule: a format is what a spec's tables say.

## Looks of a sum: tags

```ren
type Event =
  | Placed { order: Order, by: UserId }
  | Cancelled { id: OrderId, reason: Str }
  | Refunded { id: OrderId, amount: Money }

format v1 for Event.Placed =
  orderId = order: Order.v1
  ..

format v1 for Event =
  | Placed as "order.placed": Event.Placed.v1
  | Cancelled as "order.cancelled"
  | ..
```

- **`| Case as tag`** gives a case its tag. Without `as`, the tag is
  the case name as written, a `Str`.
- **`: Look`** reshapes a case's fields by a look of the variant type,
  `Event.Placed` (language.md §2, "Variant types"). A case without one
  carries its fields as themselves.
- **`| ..`** is the rest of the cases, as themselves. Without it, every
  case must be listed: a value of an unlisted case would have nowhere
  to go.
- **A tag is a typed constant.** All tags in one look have one type,
  which the look's tags decide: `"order.placed"` is a `Str`, `404` an
  `Int`, `GET"/v1/keys/\{key}"` an `http.Route`. The language checks
  the type. Which tag types a library reads is that library's check
  (below, "Checked when building").
- **Tags are distinct in a look that reads.** A reader picks a case by
  its tag, so two cases with one tag are a build error. A `writes` look
  may repeat a tag, because nothing reads a case back by it. That is
  the whole rule; a library that wants repeats (http's statuses, Part
  4) uses a `writes` look.
- **A tag may have holes that name the case's fields.** In a tag
  written with a value prefix (F1), `\{key}` is the case's field `key`,
  as a bare name in a look always is a field. The language checks
  each hole names a field and gives the library the tag's parts. What
  the parts mean is the library's.
- **The look says which tag a case has, not where the tag goes.** A tag
  field's name, an adjacent payload, or no tag at all are a library's
  spelling (json's, Part 4). The shape carries each case's tag and
  fields; nothing more.

## Looks of an opaque type: always a function

**An opaque type is only ever read through a function.** Its looks are
all `via` looks, inside its module or out:

```ren
pub type Money = opaque Int with numeric
  pub fn parse(s: Str) -> Money ! BadAmount = ...     // "12.50": the default look
  pub fn repr(self) -> Str = ...
  pub fn from_cents(c: Int) -> Money ! BadAmount = ...
  pub fn cents(self) -> Int = self

format cents for Money = Int via (Money.from_cents, fn(m) => m.cents())
```

- **Outside its module,** a look of an opaque type can use only what
  any code there can: its `pub` functions. So a look never exposes more
  than the public API. `..`, field lines and naming a private function
  are build errors: "`Money` is opaque here; read it through a
  function".
- **Inside its module,** a `via` may call private functions, and then
  the look is private too ([above](#a-type-and-its-formats)). So
  `format raw for Money = Int via (Money.unchecked, ...)` exists only
  inside `money`. It still can't be a record look over the
  representation: reading must go through a constructor that keeps the
  type's rules, or input from outside could build a value the module
  never allows.
- **An opaque record looks like a record through a wire type:**

  ```ren
  type OrderWire = { id: OrderId, lines: Array<Line>, total: Money }
  format v1 for Order = OrderWire via (Order.from_wire, fn(o) => o.to_wire())
  ```

  This costs a declaration. It is the same cost formats.md's `as` pays
  for `lsn: UInt64 as Lsn`: a conversion that can fail is visible.

## What a look can expose

- **A type without `repr` can be read but not written** by the walk.
  Writing one where no look writes it fails at the door, with the path
  ([shapes.md, "The doors"](draft-shapes.md#the-doors-build-and-view)).
- **A look exposes exactly what the public API exposes, no more.** If a
  `pub` function gives a value out, a look over that function can
  write it. Making that a named look in a settings record is how a
  library makes an exposure visible ([Part 4, `Secret`](#secret)).

## Errors carry paths

The doors that read through a look fail with one shared set, in the
`shape` module the language provides beside `T.shape`:

```ren
pub type Problem = ! Missing(at: Str, field: Str)
                   | Unknown(at: Str)
                   | Mismatch(at: Str, expected: Str, found: Str)
                   | Invalid(at: Str, why: Str)
                   | NoCase(at: Str, tag: Str)
                   | TooDeep(at: Str, limit: Int)
```

- **`at` uses the look's names,** the ones in the input:
  `"orders[2].customerId"`. That's what the sender can fix.
- **`field` names the type's field,** `"Order.customer"`, for the
  programmer. `show` prints both:
  `orders[2].customerId (Order.customer): missing`.
- **The input isn't kept.** A `Mismatch` says `found: "a string"`, not
  the string, because it may be a secret. There is no switch.
- **The doors can stop at the first problem or collect all.** It is a
  parameter of `build<T>`. Which one a library uses by default is its
  policy (Part 4).
- **`Unknown` and `TooDeep` are raised by libraries,** which share the
  tags so every library spells them one way. When a library raises
  them is its policy.
- **A library adds its own tags around `Problem`** (a syntax error with
  a byte offset, a limit). Layouts keep `FormatError`, with offsets;
  its `path` uses the same spelling.
- **A named error set has a shape, as the `Err` side of a `Result`.** A
  look may be `for` a named error set (`Keys.Error`, `Problem`).
  Writing one takes the `Err` of a `Result`; reading one yields
  `Err(tag)` inside a `Result`, never a free tag. This keeps errors.md's
  rule: an error is a value only inside a `Result`, and an error set is
  never a sum type.

## Versions are looks

```ren
format v1 for Order, reads =
  id
  total: Money.cents
  ..

format v2 for Order =
  id
  total                 // through Money's own parse/repr now
  ..
```

- **A version is another look of the same type,** as layer 2 has
  another format. No second type, no conversion functions.
- **`reads` forbids writing.** Unlike layouts, several looks of one
  type may be writable, so a program can answer each reader in its
  version. Mark `reads` when a version must never be produced again.
- **A field an old look lacks** gets its field default or `None`, the
  same rule as any left-out field. A field with neither is a `via` to a
  wire type.
- **A look of `D.Call` or `D.Reply` can't be `lossy`.** Its `via`'s
  write side fails instead (`T -> X ! NotInVersion`). So a v2 caller
  writing v1 can't quietly drop a `ttl`.
- **Choosing a version is code you can see:** a value holding the
  version's looks, picked by a `match`.
- **What gets frozen** is in Part 3.

## Dependencies as data

For each dependency `D` the compiler writes three declarations, so a
dependency's operations are data any library can read (decision 20,
rule 3: the program's declarations as data).

```ren
use std.remote.Unavailable

pub dep Keys ! Unavailable =
  get: fn(key: Key) -> Bytes ! NotFound
  put: fn(key: Key, value: Bytes, expect: Option<Version>) -> Version ! Conflict
  list: fn(prefix: Str = "", limit: Int = 100) -> Array<Key>
```

- **`D.Call`** is a sum with one case per operation, its parameters as
  fields, their defaults as field defaults.
- **`D.Reply`** is a sum with one case per operation, holding its
  result; fieldless for `()`.
- **`D.Error`** is a named error set: the union of every operation's
  errors and the header's.
- **They are ordinary data.** They have shapes, default looks, `==`,
  `show` and generators, and looks may be declared for them like any
  sum. language.md §6 says so: they are data, not opaque descriptions.
- **`D.Call` exists only if every operation is data:** no block, no
  `&`/`inout` argument, no view, a data result. That is decision 18's
  rule for `post`, stated once. Naming `D.Call` for any other dep is a
  build error naming the operation.
- **Errors on the header.** `pub dep Keys ! Unavailable =` says every
  operation can also fail with `Unavailable`. It is the form
  `Actors<DocId, Doc> ! StoreDown` already has. `ren types Keys` shows
  it on each operation, and a handler for `Keys` must fit it as it fits
  any declared error. The language gives "errors on the header";
  what `Unavailable` is, is std's (Part 4).
- **A handler `over D` for an all-data `D` may write `call(c: D.Call)`**,
  and `next.call(c)` is `D.call(c)` against the next handler. This sits
  beside `over any`'s `call =>`, which stays as built: it covers every
  dependency, data or not, and it carries the journal.

## Checked when building

**One mechanism.** Every build-time check runs through top-level `let`
and `assert` (shapes.md, "The top level is build time"). The language
writes no check for one library. Two groups:

**Checked on the declaration, by the language.** Each is a build error
with a fix-it:

- a format that mixes layout lines and look lines;
- a look named like a method of its type;
- a field left out of a look with no default and not an `Option`
  (except in a `writes` look);
- two lines giving one name; a lowercase right side that names no
  field;
- a `via` whose functions don't have the types `X -> T ! E` and
  `T -> X` (or `T -> X ! E`), or that has a `uses` row;
- a chain of `via` looks that comes back to its start;
- a sum look missing a case, without `| ..`;
- tags of more than one type in one look; two cases with one tag in a
  look that reads; a hole that names no field;
- a look of an opaque type that isn't a `via`;
- a private look named outside its module; a `pub` look that names a
  private function;
- a `reads` look used to write, a `writes` look used to read;
- a `lossy` look of `D.Call` or `D.Reply`;
- naming `D.Call` for a dep with an operation that isn't data.

**Checked where a type meets its looks, at a top-level `let`.**
`shape.through<T>(looks)` fails, with a `LookError`, on two looks for
one type in the list, an opaque type the walk can't read, and a type
with no `repr` that the list doesn't write. In a top-level `let` that
failure is a build error, like any top-level failure. A library's own
checks (tag types it reads, its casing collisions, its route overlaps)
are code in that library, run the same way:
`let ORDERS = json.codec<Order>(API)` fails the build if json's check
fails. See the boundary notes on calls whose settings are not
top-level.

## Compiler errors

```
error: `customer` is left out of `public`, has no default, and isn't an `Option`
  format public for Order =
    id
    total
  = a look lists what it carries; reading it back must build an `Order`
  help: carry `customer`, add `..`, give it a default in `Order`,
        or mark the look `writes`
```

```
error: `Money` is opaque here; a look of it reads it through a function
  format v1 for Money =
    cents
  help: `format v1 for Money = Int via (Money.from_cents, fn(m) => m.cents())`
```

```
error: `PageHeader.disk` is a `Layout`; this field is an `Array<Look>`
  let J = json.settings(formats: [PageHeader.disk])
  help: a layout is read with `PageHeader.disk.view(bytes)`
```

```
error: `v1` of `Event` has no tag for `Refunded`
  help: add `| Refunded as "..."`, or `| ..` for the rest as themselves
```

```
error: `Time.from_unix` uses `Clock`; a look's functions are pure
```

```
error: `Get`'s tag has a hole `\{id}`, but `Keys.Call.Get` has no field `id`
  | Get as GET"/v1/keys/\{id}"
  help: did you mean `\{key}`?
```

Errors a library raises read the same way, but are written by the
library (Part 4): `customerId` written twice after json's casing,
`Keys.Error.rest` missing a status.

---

# Part 2. Compiler (invisible)

None of this changes what a program means. A debug build means the
same, slower.

- **A `Look` is represented as the compiler likes.** In a closed world
  the compiler knows every `format` in the program, so it can number
  them: an enum it writes, one tag per format. A `via` runs inside its
  tag's arm and is never stored. Debug builds `match` on the tag (or
  point at a static record, as `Handler_tag` does); release builds use
  a number. No program sees which.
- **A `match` over constant tags compiles to a perfect hash.** That
  covers a reader picking a case by its tag and a library matching
  route strings. A reader never tries each case (Effect v4's
  `SchemaAST.ts` union candidates do the same lookup).
- **Specialization over known looks.** When the looks are a top-level
  constant, release builds copy a library's walk per (type, looks) into
  straight-line code. feasibility.md: this is two steps, a constant
  argument in specialize.ml's key (M-L), then unfolding the library's
  `match` over a constant shape (L, stage 12's risk 2). See
  [shapes.md, Part 2](draft-shapes.md#part-2-compiler-invisible).

---

# Part 3. Toolchain

The toolchain reads the language, never a library, so each tool serves
every library alike.

- **`ren explain`** prints, per field, the look's name, the encoded
  type and the walk step that chose it
  ([shapes.md, "Seeing the walk"](draft-shapes.md#seeing-the-walk)).
- **Freezing** fingerprints what a top-level value sends
  ([shapes.md, "Freezing what is sent"](draft-shapes.md#freezing-what-is-sent)).
- **A round-trip test per look,** below.

## A round-trip test per look

`ren test` runs one generated property per look, with no test written:

```
look Order.v1: 1000 values, round trip ok
look Time.unix (lossy): 1000 values, encoded value stable
```

- **The values come from the type's generator** (testing.md "Every type
  generates itself"), so only values the module allows.
- **It round-trips through the doors, not through a library:**
  `build<T>(view<T>(x, [look]), [look]) == x'`. So it tests the look
  itself: renames, constants, tags and both `via` functions. Libraries
  test their own syntax.
- **`x'` is `x` with every left-out field set to what it reads as.**
- **A one-way look gets a one-way test.** A `reads` look is fed what
  the type's default look writes, through the look's own encoded shape;
  a `writes` look is checked to never fail on a generated value unless
  its `via` declares an error.
- **A `lossy` look checks the encoded value instead:** writing, reading
  and writing again gives the same `Value`. `Time.unix` passes; a `via`
  whose two functions disagree (`from_unix` reading milliseconds)
  fails, with the shrunk value.
- **A failure prints the value, the look and the field:**
  `Order.v1: placed: 1970-01-01T00:00:01.5Z came back as ...:01Z;
  Time.unix loses sub-seconds; mark it lossy or fix the via`.

Effect v4 derives an `Arbitrary` from a schema but leaves the round
trip to you. Here it's free because looks are declared, not built.

---

# Part 4. std policy

Each rule here is one library's default, in its settings or its docs
(decision 20, rule 5). Consistency across std is a written convention.
Where a library needs the compiler's help, it uses a Part 1 primitive
any third-party library could use.

## json

- **Where the tag goes.** By default an internal tag named `"type"`:
  `{"type": "order.placed", ...}`. `type` is a Ren keyword, so no
  field collides with it. `tag: Adjacent("type", "data")` in json's
  settings puts the payload under `"data"`. There is no untagged form.
  A field named like the tag field is json's build-time error.
- **Where the payload goes:** named fields beside the tag; one record
  payload merged; any other payload under `"value"`; no payload, just
  the tag. Details in
  [shapes.md, "Sums in json"](draft-shapes.md#sums-in-json).
- **A fieldless sum is still an object,** `{"type": "Admin"}`. A json
  API that wants `"Admin"` gives the type `parse`/`repr`, or names a
  `Str via` look.
- **Tags must be `Str`.** A look whose tags are another type fails
  json's check.
- **Casing re-cases only names not marked exact.** Two names that meet
  after casing are json's build-time error:

  ```
  error: `customerId` is written twice in what json sends for `Order`
    = `customerId = customer` in `Order.v1`
    = `customer_id`, a field, re-cased by `keys: camel_case` in `API`
    help: rename one of them in the look
  ```

- **Strict by default, first error.** An unknown key is `Unknown(at)`;
  `unknown: Ignore` relaxes a whole call. json stops at the first
  problem.

## Text media: cli, env, query strings, sql text

- **A fieldless sum reads and writes as its case name:** `--role
  admin`, `?mode=merge`, `FLOTT_SYNC=Group`. That is their syntax, not
  a rule of the walk.
- **cli uses the same looks for flag names;** short flags and
  positionals stay in `cli.spec`. One look serves every medium:
  `listen = addr` is `"listen"`, `FLOTT_LISTEN` and `--listen`.
- **config collects all problems,** because it merges sources and a
  user fixes a file once.

## http

A REST look of `D.Call` is the route table: a sum look whose tags are
`http.Route` values. Statuses are a `writes` look of `D.Error` whose
tags are `Int`s. Both are ordinary Part 1 looks; what their tags mean
is http's.

```ren
pub format rest for Keys.Call =
  | Get as GET"/v1/keys/\{key}"
  | Put as PUT"/v1/keys/\{key}"
  | List as GET"/v1/keys"

pub format rest for Keys.Error, writes =
  | NotFound as 404
  | Conflict as 409
  | Unavailable as 503
```

- **`GET"/v1/keys/\{key}"` is a value prefix** (synthesis F1):
  `GET.template(t)`, an `http.Route`. Its holes are the case's fields
  (Part 1). http checks the template at build time, through
  `http.mount<Keys>(...)` in a top-level `let`.
- **A path hole is read through its type's `parse(Str)`.** `Key.parse`
  reads the segment.
- **Fields not in the path** go in the query for `GET` and `DELETE`, and
  in the body otherwise, through the call's json settings.
- **Headers and raw bodies (the http stage).** flottning wants
  `If-Match` from `expect` and a raw value body on day one. They are
  http's own: its route templates grow a header line and a raw-body
  line whose holes name fields, e.g. `If-Match: \{expect}` and
  `body: \{value}`. The language sees only holes naming fields; http
  says what a header is. Exact spelling is the http stage's.
- **A status look may repeat a status.** It is a `writes` look, so
  Part 1 allows it. A dep with a `Busy` error can give it 503 beside
  `Unavailable`, because
  the body carries the error's own tag and the client reads that, not
  the status.
- **Every error needs a status.** The look lists every case; a new
  error without a status fails the build (synthesis D3's exhaustive
  edge, declared rather than matched).

  ```
  error: `Keys.Error.rest` has no status for `Throttled`
    help: add `| Throttled as 429`
  ```

- **Success is 200, and 204 for `()`.** A `writes` look of `Keys.Reply`
  can say otherwise (`| Put as 201`).
- **A reply body drops the case tag,** because the route says which
  case it is.
- **A bad path segment or body is a `Problem`,** not one of `D.Error`'s
  tags. http answers it 400 with the `Problem` in the body.
- **Two routes that can match one request** fail http's build-time
  check. Matching compiles to a perfect hash plus segment checks, by
  Part 2's general rule.
- **Serving several deps on one port** uses mounts: `http.mount<Keys>
  (KEYS_V1)` is a stateless handler of a std dep, so it is a
  description (language.md §6), and a list of mounts is an array of a
  compiler-written enum. No `D.call` is stored as a value.

## `Secret`

`Secret<T>` has `parse` and no `repr` (synthesis A3). So:

- **It reads** wherever `T` does: json, env, flags.
- **It doesn't write** by the walk. `json.encode(cfg)` where `cfg`
  holds a `Secret` fails at the door, with the path:

  ```
  error: `Cfg.admin_token` is a `Secret<Str>`, which has no `repr`
    json.encode(cfg)
    = a type without `repr` can be read but not written
    help: leave it out with a `writes` look of `Cfg`, `format public for Cfg, writes = addr, dir`
  ```

- **Writing one goes only through a named look over the public
  `reveal`:** `format plain for Secret<Str> = Str via (Secret.parse,
  fn(s) => s.reveal())`. It sits in a settings record, where grep and
  review find it.
- **The journal's rule is on the type, not the look.** A `Secret` is
  hashed on export (synthesis B1) whatever look read it.

## Remote failure: `Unavailable` and `Why`

- **std declares the tag once,** in `std.remote`:
  `Unavailable(why: Why)`, with `Why = Refused | Timeout |
  Decode(Problem) | Protocol | Version | Denied | Server`. Structural
  tags need one spelling, and std is where it lives.
- **A dep says it with the header,** `pub dep Keys ! Unavailable =`
  (Part 1). std's client handler (`http.client<D>`) fails with it, so
  it can only be given for a `D` whose header has it: the ordinary rule
  that a handler fits the dep's errors.
- **Mapping.** A handler panic on the server is a 500 and
  `Unavailable(Server)` at the client. A v1 write that fails
  `NotInVersion` is `Unavailable(Version)`.
- **The envelope and transports** are in
  [shapes.md, Part 4](draft-shapes.md#dependencies-over-the-wire).

---

## Left out

- **Per-field attributes.** A look is apart from the type, always.
- **Untagged sums.** Slow, ambiguous, no error path.
- **Flattening, paths, computed fields in looks.** Use a `via` to a wire
  record.
- **Splicing a sum case into its parent.** Dropped. `flot kv get a`
  stays, or the cli's command type is written flat.
- **Record looks over an opaque type's representation.** Always a `via`.
- **A switch to keep rejected input in errors.**
- **Medium words in a format.** No tag field names, casings, statuses
  or headers in the declaration; libraries read them from tags and
  their own settings.

## Later

- **An inline look of a case,** lines indented under `| Placed as
  "order.placed"`, instead of naming `Event.Placed.v1`. Saves a
  declaration per case; costs a second spelling.
- **json's external tag,** `{"Placed": {...}}`, for serde-default APIs.
- **Per-route body formats** in http.
- **JSON Schema** as a library over shapes. **OpenAPI ships with the
  http stage:** it is a walk over `shape.through` of `D.Call` and the
  REST looks, so it is small, and Effect v4 serves docs from the same
  value on day one.

## Other edits to formats.md

- **Title and opening:** "Formats: how a type looks outside". The
  opening says a format is how a type looks somewhere, and that there
  are two kinds; the rest of the file through "Layer 3" is the layout
  kind.
- **"Three layers":** layer 1 is "derived: the type's default look,
  walked by a library" (json, cli, `bin`). Layer 2 is "declared:
  layouts for bytes, looks for values". Layer 3 is unchanged.
- **"Layer 1":** `bin` walks the type through `parse`/`repr` (so
  opaque types keep their rules) and takes no looks; it has no names to
  rename.
- **"Left out":** "standalone formats" stays. Add "attributes on
  fields" and "medium words in a format".
- **"Versions":** "at most one format of a type is writable" becomes
  "at most one *layout*". Looks may be writable several at once; the
  rule's purpose (no quiet lossy writes) moves to "no `lossy` look of
  `D.Call` or `D.Reply`" and to the freeze fingerprint covering `via`
  functions.
- **`=` in layouts** keeps layer 2's `field = value` for `reads`
  layouts. Looks don't have it; the doc says so next to the layout
  form, so the two lines aren't confused.
- **`as` has three meanings** (pattern binding, a layout's
  `UInt64 as Lsn`, a sum look's tag). Write them side by side in one
  short paragraph.
- **Sections by owner.** formats.md keeps Part 1 and Part 2; Part 3's
  tests go to testing.md with a link; Part 4 goes to each library's
  docs (json, cli, config, http, `std.remote`), with formats.md linking.

## Elsewhere

- **errors.md:** "A named error set has a shape, as the `Err` side of a
  `Result`; a look may be for it; reading one gives `Err(tag)`, never a
  free tag."
- **errors.md and language.md: handler-wide `fail` arms.** A handler
  may end with `fail` arms that apply to every operation in it:
  `... fail Disk(path) => internal(path)`. Written once, explicit,
  binds no whole error. It is a general handler rule, not a looks rule,
  so it is written there, not in formats.md.
- **language.md §6:** `D.Call`, `D.Reply` and `D.Error` are written by
  the compiler and are data (`==`, `show`, shapes), not opaque
  descriptions. `Look` and `Layout` are value types; their
  representation is the compiler's.
- **language.md, dependencies:** errors on a dep's header,
  `dep D ! E =`, apply to every operation, the same as
  `Actors<K, D> ! E`.
- **foundations decision 10:** remote deps declare `Unavailable` on the
  header, not on every op by hand and not with a keyword.

## Boundary notes

Language rules that today serve mainly one library, or lines decision
20 makes awkward. Each is kept general; listed so the owner can check.

1. **Tag holes (`\{key}` in a tag)** serve only http's routes today.
   Kept general: any prefixed tag value may name fields, and the
   language checks only that they are fields. A sql or topic-template
   library could use it.
2. **"A `writes` look may repeat a tag"** exists because http's status
   look needs repeats. It falls out of `writes` (nothing reads back by
   tag), so it is not an http rule, but http is its only user.
3. **No `lossy` look of `D.Call` or `D.Reply`** guards versioned
   protocols, which are std's. It is stated on declarations-as-data,
   which the language owns, but its reason is one use. Alternative:
   std's envelope refuses lossy looks in its own check.
4. **`Problem` is defined with the doors,** so every library shares its
   tags. `Unknown` and `TooDeep` are only raised by libraries; they sit
   in the language's set so the spelling is one, which is convention
   more than guarantee.
5. **Checks that need a type and its settings together** run only
   where the pair is a top-level value (`json.codec<Order>(API)`).
   `json.decode<Order>(text, API)` called directly checks at first use,
   at run time, unless a release build's specialization finds it, and
   rule 4 says that must not change meaning. Either libraries steer
   users to top-level codecs, or the language gains a general way for
   a generic function to check constant arguments at build time.
6. **`json.settings(tag: ...)` is per call.** An API with one type
   tagged `"kind"` needs a second settings record or a `via`. json
   could key a setting by look (`tags: [(Event.v1, Internal("kind"))]`),
   since looks are values; that needs nothing new from the language.
7. **`type` being a keyword** is why json's default tag field never
   collides. That is a happy accident of the language serving one
   library's default, not a rule; no change needed.

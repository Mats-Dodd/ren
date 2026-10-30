# Judge: looks, against Effect v4 and against Ren's own rules

Written 2026-10-29. I read draft-formats.md, draft-shapes.md,
effect-study.md and programs.md. I checked them against formats.md,
shapes.md, errors.md, language.md (§2, §4, §6, §11), foundations.md
(decisions 4 and 18), README ("no stored closures") and the owner's ten
decisions. Effect means Effect v4 (`/tmp/ren-refs/effect`, 4.0.6) only.
Nothing in the v3 clone was used.

---

## Lens 1: DX against Effect v4

### Verdict

Ren's version is more pleasant for this program. It is shorter (230
lines against 320 for the core), it has fewer ideas, and more mistakes
fail the build. Effect is still better in four places, listed below.
Each one has a single fix.

### Where Ren is ahead

- **One declaration per type.** Effect writes each type as a schema and
  reads the type back with `typeof X.Type`. Ren writes the type, and a
  look only where the wire differs. In v1 of flottning no json look was
  needed at all.
- **The API is the dep.** Effect writes each endpoint, then a handler
  per endpoint, then a client. Ren writes `dep Keys`, a handler, and two
  short looks. The compiler writes `Keys.Call`, `Keys.Reply` and
  `Keys.call`.
- **The CLI comes from the API.** Effect has no bridge from `HttpApi` to
  `cli`; every command repeats its endpoint (E#1). Ren's `Keys.Call.cli`
  is four lines.
- **Statuses live apart from the type.** Effect puts `httpApiStatus` on
  the error class (E#3). Ren's status look is separate and must cover
  every error.
- **Build-time checks Effect lacks:** route holes, overlapping routes,
  an error with no status, a frozen version that changed, exit codes
  checked by `match`.
- **Strict by default.** Effect drops unknown keys, so a typo in
  `"expect"` becomes an unconditional put (E#8).
- **Round-trip tests for free,** one per look. Effect leaves this to
  you.
- **One kind of absence.** Effect has `optionalKey`, `optional`, four
  decoding defaults and an `Option` family. Ren has `Option` and a field
  default.
- **Speed without extra machinery.** Effect added a JIT and an AOT
  compiler. Ren specializes in release builds.

### Where Ren is worse, and one change for each

1. **You can't see which look applies.** In Effect you hover a schema
   and see its `Encoded` type. In Ren a field "as itself" follows the
   call's settings, and a `via`'s encoded side is walked again. So
   `KEYS_V1`'s four looks reach places you can't see from the call
   (R#10). A call that lists `Int.str` for JavaScript also turns
   `Time.unix` into a string, silently.
   **Change:** make `ren explain SETTINGS for T` and an editor hover
   first-class parts of this stage. Each field prints its name on the
   wire, its encoded type, and which of the four walk steps chose it.

2. **Mapping a server error costs a line per arm.** Effect's `internal`
   is one `catchTag` in a pipe. In Ren each handler arm repeats
   `fail Disk(path) => internal(path)` (R#13). programs.md makes it look
   worse than it is: with `try match`, the arm that re-raises
   `Conflict` is not needed (errors.md, "Handling"). But one arm per
   operation is still left.
   **Change:** let a handler end with `fail` arms that apply to every
   operation in it, in `match` syntax:
   `handler kv() for Keys uses Store, Log = ... fail Disk(path) => internal(path)`.
   It is explicit, it is written once, and it binds no whole error.

3. **Transport errors sit in the domain's signature.** Effect adds
   `RpcClientError` only on the client. In Ren the server's handlers
   must produce `Unavailable`, a word that means something only to
   clients (R#3). Auth failures have nowhere to go.
   **Change:** `pub dep Keys, remote =`. The word writes
   `Unavailable(why: std.remote.Why)` into every operation. That keeps
   decision 10 (it is declared, and `ren types` shows it), and std owns
   the tag's one shape. A handler may still fail with it; a handler
   panic becomes a 500 and `Unavailable(Server)` on the client.

4. **No docs and no streams on day one.** Effect serves OpenAPI and
   Scalar from the same value. It also streams SSE and NDJSON, with
   typed errors after the status is sent. In Ren both are "later".
   **Change:** ship an `openapi` library in the http stage. It is a
   walk over `shape.through` (draft-shapes lesson 8), so it is small.
   Reserve a `Chunk` case in the std envelope now, so streaming
   operations can be added later without changing the wire.

Smaller gaps, and things that are equal:

- **`flot kv get`, not `flot get` (R#4).** The fix is a narrow
  `| Kv as ..` line in a sum look. It splices one sum into another. It
  is not general flattening.
- **Splitting a case (R#1)** costs about the same in both. Keep it
  explicit. Don't have `freeze` write source, because decision 10 says
  "no codegen". The generated round-trip test already checks that
  `from_v1` and `to_v1` agree.
- **Auth** is about equal. Effect declares it on middleware; Ren passes
  policy data to `http.mount`. Both need the token by hand on the client.
- **`parse` beats structure in json too (R#9).** `"expect": "3"`
  surprises people, but it follows from decisions 1 and 3. Item 1's
  hover makes it visible, and that is enough.

---

## Lens 2: coherence

### What the drafts add, counted

**Rules: about 44.** By section: format kinds 5, scalar `via` 4,
record lines 5, sum looks 7, opaque 1, `Secret` 1, errors 2, versions 2,
dep looks 4, the walk 2, settings 3, casing 1, strict decoding 1,
absence 1, default sums 1 (plus 1 proposed), library leaves 1,
recursion 1, freezing 1, generated tests 1.

Most of them restate decisions or layer 2. The new ones that carry
weight: the kind is read off the lines; looks chain through `via`; a
written name is exact under casing; `reads` with `field = value` in
looks; tag type decided by the library; query versus body by HTTP
method; success is 200 or 204.

**Reserved words and names.**

| Kind | Names | Count |
|---|---|---|
| words in `format` | `via`, `lossy`, `reads`, `tag`, `content`, `as` (third meaning), `..` (two new meanings) | 7 |
| written per dep | `D.Call`, `D.Reply`, `D.Error`, `D.call` | 4 |
| std types | `Look`, `Layout`, `Problem` (6 tags), `Why` (7 tags), new `Shape` cases `Const`, `Sum`, `Text`, plus `Tag`, `Case` | ~20 names |
| defaults | tag key `"type"`, `max_depth: 64`, header `ren-shape`, status 412 | 4 |
| settings fields | `formats`, `keys`, `unknown`, `none`, `max_depth` | 5 |

Two names are overloaded too much.

- **`as` has three meanings:** binding in a pattern
  (`Placed {..} as p`), going through a constructor in a layout
  (`UInt64 as Lsn`), and a tag in a sum look (`Placed as "x"`). The
  layout meaning is the same idea as `via`. Keep all three for now,
  but write them down side by side.
- **`call` has three:** the `call(op, args)` clause in shapes.md, the
  `D.call` function, and the `D.Call` type. See issue 8.

### Checked against each document

- **formats.md.** Layer 2 holds. Two conflicts: the meaning of `=`
  (issue 4), and "at most one format is writable", which the draft
  narrows to layouts. The narrowing is right, because a server answers
  each client in that client's version. But it needs the protections in
  issue 3, since layer 2's rule existed to stop lossy writes.
- **shapes.md.** "Renames and defaults are settings on the format" is
  replaced, as intended. "Opaque outside its module, built by its
  `parse`" holds. `call(op, args)` overlaps with `D.Call` (issue 8).
- **errors.md.** "A sum type is never an error, and an error is never a
  sum type." Yet the drafts write looks for `Keys.Error` and encode
  `Problem` in bodies (issue 6). Tags are structural, so `Unavailable`
  must have one shape in every dep. The draft spells it bare in one
  place and `Unavailable(why: Why)` in another. `Problem`'s tags
  (`Missing`, `Invalid`, `Unknown`) are generic names. Any library
  whose `Invalid` has another payload clashes with them in a union
  (module-build.md). Rename them `ShapeMissing` and so on, or give
  them distinct payloads on purpose.
- **language.md §6.** A compiler-written enum is "opaque: call it and
  nothing else". `D.Call` must be data: `==`, `show`, decode. So it is
  an ADT the compiler writes, not a description. Say so in §6.
- **README, "No stored closures".** A `Look` value holding
  `via (from, fn(t) => ...)` is a stored closure (issue 1).
- **foundations.md decision 4.** Specializing per (type, settings)
  fits the closed world. That holds only if `formats` is known at build
  time inside the library too (issue 1).
- **Decision 18.** `post` already queues `D`'s operation enum as data,
  with no block kept. `D.Call` has to be that same enum, with the same
  limit (issue 8).
- **Owner's decisions.** 1, 2, 3, 4, 5, 7, 8 and 9 are followed.
  Decision 6 is contradicted by the proposed "fieldless sum is a
  string" (issue 7). Decision 10's sketch `http.expose<Keys>` became
  `http.mount` values in a list. That is fine, if mounts are a
  description (issue 8).

### Implicit things found

- **The kind is read off the lines.** A format whose only lines are
  nested `x: T.fmt` takes its kind from those formats. That is
  inference two levels deep. It is acceptable, but the error for a mix
  must name the nested format.
- **Looks chain through `via`** by the call's settings. It is
  consistent with decision 3, but you can't see it (Lens 1, item 1).
- **http's placement rule.** Fields not in the path go in the query for
  `GET` and `DELETE`, and in the body otherwise. It is a hidden rule
  that shapes every route (R#7). It must appear in `ren explain`.
- **"A shape hash at connect" became a header on each connection plus
  a 412 (R#8).** That is a new rule inside http. Put it in the std
  envelope's spec, not in http alone.
- **`unknown: Ignore` can drop meaning.** A v1 server with `Ignore`
  that gets v2's `ttl` writes a key that never expires. It is opt-in,
  so it is acceptable. Its doc line should say so.

---

## Top 8 issues, each with a fix

**1. A `Look` is a value holding functions, and Ren has no stored
closures.** The draft says "a look is a value of type `Look`", and
`json.decode<T>(text, s)` reads `s.formats` as a parameter. Inside the
library that is a run-time value (shapes.md: only the top level is
build time). So a debug build needs looks as values that carry `via`
functions, which is a stored closure. Release specialization also
depends on a constant flowing through a parameter (open question 5).
**Fix:** a `Look` is an enum the compiler writes, with one tag per
`format` declared in the program (language.md §6, decision 4). A `via`
runs inside that tag's arm and is never stored. `formats` is a list of
tags. Debug builds walk with a `match` on the tag. Release builds
specialize per (type, settings), as the draft says. No new rule, and
open question 5 goes away.

**2. A look can hand out a private constructor (unsound).** "Inside its
module, a `via` may call private functions." Nothing says who may name
that look. So `format raw for Money = Int via (Money.unchecked, ...)`,
declared in `Money`'s module, can be listed by any program in
`json.settings(formats: [Money.raw])`. Hostile input then builds a
`Money` the module never allows. The write side can leak the
representation the same way.
**Fix:** looks have visibility, like functions. A look is private to
its module unless marked `pub`, and a `pub` look may name only `pub`
functions. Naming a private look from outside is "`Money.raw` is
private to `money`".

**3. Versioning can misread or lose data without a word.**
(a) The freeze fingerprint is of `shape.through`, so it covers only the
encoded shape. If `Time.from_unix` changes from seconds to
milliseconds, every hash stays the same and every old timestamp is
read wrong. (b) `format v1 for Keys.Call = CallV1 via (from_v1, to_v1),
lossy` is writable. A v2 client using `KEYS_V1` to talk to a v1 server
sends `put(ttl: Some(10.s))` with the `ttl` dropped, and the call
succeeds. That is the lossy write layer 2's "one writable format" rule
existed to forbid.
**Fix:** (a) The fingerprint covers each look's qualified name and the
names and IR hashes of its `via` functions. Changing a function inside
a frozen look fails the build like a changed field. (b) Let a `via`'s
write side fail (`T -> X ! E`). Forbid `lossy` on looks of `D.Call` and
`D.Reply`. `to_v1` then fails with `NotInVersion` on a `ttl` v1 can't
carry, and the client sees `Unavailable(Version)`.

**4. `=` means three things, and one use is ambiguous.** In looks,
`customerId = customer` renames (the wire name is on the left), and
`kind = "order"` is a constant. The draft also brings in layer 2's
`reads` form, `owner = Owner.nobody`, where the type's field is on the
left. In a `reads` look of a type with a field `status`,
`status = Active` could be a constant written under the key "status",
or the default for the field `status`. The draft's own rule, "the right
is a field or a literal", already rejects `Owner.nobody`.
**Fix:** drop `field = value` from looks. Decision 5 already says a
left-out field needs a default or `Option`; anything more is a `via` to
a wire type. Decide rename versus constant by the token, not by
lookup: a lowercase identifier is a field, and a literal or an
uppercase constructor is a constant. Then each line has one meaning.

**5. Looks are two-way only, so projections and read-only looks don't
fit.** `format public for User = id, name` is the draft's own example
of hiding `email` and `password_hash`. It won't build, because
`password_hash` has no default and must be readable back. `Bytes.text`
is marked `lossy` only to satisfy a write function the CLI never calls
(R#11). Response looks and input looks are both common.
**Fix:** add `writes` beside layer 2's `reads`. A `reads` look has
`via (read)` and can't encode. A `writes` look has `via (write)`, can
leave out any field, and can't decode. Passing one in the wrong
direction is a build error at the call. It costs one word, matches
layer 2, and removes most uses of `lossy`.

**6. Errors become sums on the wire, and errors.md says they never
are.** The drafts write `format rest for Keys.Error`, encode `Problem`
in 400 bodies, and decode error bodies on the client. errors.md:
"tags aren't values ... an error is never a sum type", and errors are
values only inside a `Result`. Structural tags also mean `Unavailable`
must have exactly one shape across every dep in a program. The drafts
use two.
**Fix:** say it in errors.md. A named error set has a shape, as the
`Err` side of a `Result`. A look may be `for` a named error set.
Decoding one yields `Err(tag)` inside a `Result`, never a free tag. A
reply on the wire is `Result<D.Reply, D.Error>`, which errors.md
already allows. std defines `Unavailable(why: Why)` once, and the
`remote` word (Lens 1, item 3) writes it into every operation, so no
dep spells it differently.

**7. The default sum encoding is undefined for half of `D.Reply`.**
Decision 6 says a sum is `{"type": "Placed", ...fields}`. But
`Keys.Reply` has `Put(Version)` (an Int) and `Get(Entry)` (a record
with no field names of its own). An internal tag can't sit beside an
Int. programs.md also has REST reply bodies with no tag, and `--json`
output with the tag, without a rule for either. The proposed "fieldless
sum is a string" contradicts decision 6.
**Fix:** one rule in the walk. A case with named fields puts them
beside the tag. A case with one record payload merges that record's
fields. Any other payload goes under `"value"`:
`{"type": "Put", "value": 1}`. A transport that knows the case from
context drops the tag, and http's REST reply does, as a stated http
rule. Keep decision 6 in json. Text media (cli, query, env, sql) read a
fieldless sum as its case name. That is their syntax, in the library
table, not an exception to the walk.

**8. Two ways to see a dep's calls, and some deps can't be protocols.**
shapes.md already has the `call(op, args)` clause and
`next.call(op, args)`, with `args` as a dynamic view. Decision 10 adds
`D.Call`, `D.Reply` and `D.call(c)`. Those are two mechanisms for one
question, and `call` names three things. Also, an operation that takes
a block, an `&`/`inout` argument, a view, or returns a non-data value
can't be a case of a data enum. That is the same limit decision 18
puts on `post`. Nothing says what `http.expose<D>` does for such a dep.
Finally, `http.mount<Keys>` values in a list hold `D.call` for
different `D`s, which second-class functions don't allow as plain
values.
**Fix:** one mechanism. The `call` clause takes `c: D.Call`, and
`next.call(c)` is `D.call` against the next handler. `D.Call` exists
only if every operation is data, which is decision 18's rule stated
once. Naming `D.Call` (directly, or through `http`, `cli` or `post`)
for any other dep is a build error that names the operation. A mount
is a stateless handler of a std dep, a description (§6). A list of
mounts is then an array of a compiler-written enum, which is what §6
uses routes to motivate. That closes R#6 and keeps decision 10 open for
streams later (Lens 1, item 4).

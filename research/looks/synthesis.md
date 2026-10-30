# Looks: synthesis

Written 2026-10-29. Inputs: `effect-study.md`, `programs.md`,
`draft-formats.md`, `draft-shapes.md` and `judge.md`, all in this
folder. Effect means Effect v4 only (`/tmp/ren-refs/effect`,
`packages/effect` 4.0.6). Nothing in the v3 clone was used. The owner's
ten decisions are fixed. Nothing in the repo is edited.

The judge's eight fixes are now in the two drafts. Where a fix changes
something the owner decided, it is listed under "Decisions for the
owner" instead of being taken silently.

No `feasibility.md` exists for looks. Section 6 is written from the
compiler source (`lib/`) and stage 12's staging.

---

## 1. Verdict

Looks work. On flottning's API, Ren's version is 230 lines against
Effect v4's 320, with fewer ideas and more mistakes caught at build
time (programs.md, Part 3). In v1 no json look was written at all: the
walk, `parse`/`repr` and structure covered every type. Looks appear only
where the wire differs: renames, versions, routes, statuses, CLI names.

Effect stays ahead in four places: you can see the encoded type, error
mapping is one line, transport errors stay out of the domain, and docs
and streams come on day one. Each has one fix, now in the drafts or
below.

---

## 2. The design in 8 rules

### Rule 1. One walk, four steps, and you can see it.

A derived walk stops at a type that has the method of its name: `show`,
`key`, `parse`, `repr`. For encodings it picks, per value: the look a
field names, then the look the call names for the type, then
`parse`/`repr`, then structure. `ren explain SETTINGS for T` and an
editor hover print, per field, its wire name, its encoded type and the
step that chose it.

- **Effect v4:** `Schema.toCodecJson` uses the same order: an explicit
  encoding on the node, then the type's `toCodecJson` annotation, then
  structure, then "Expected JSON value". Ren adds the call's choice as
  step 2. Effect shows the result as `typeof s.Encoded` on hover; Ren
  prints it, because a look is a declaration, not a value with a type.
- **Ren:** decisions 1 and 3. `parse`/`repr` is stage 12's A3.
  `ren explain` is the judge's Lens 1 fix 1; it answers R#9 and R#10.

### Rule 2. A format is a layout or a look, apart from the type.

A format is declared apart from its type and named through it:
`Time.unix`, `Order.v1`, `PageHeader.disk`. Lines with byte order and
widths make a layout. Lines with only names, looks and constants make a
look. Mixing is a build error. `Look` and `Layout` are enums the
compiler writes, one tag per format in the program. A `via` runs inside
its tag's arm and is never stored. A look is private to its module
unless `pub format`, and a `pub` look names only `pub` functions.

- **Effect v4:** the same split exists by accident: `toCodecJson` for
  values, `SchemaBinary` for bytes over the same schema. Effect's
  schemas are values holding functions, which is why it needs a JIT and
  an AOT compiler (`SchemaAOTCompiler`, with an interpreter fallback
  for transformations).
- **Ren:** decision 2. The enum is language.md §6 and foundations.md
  decision 4 (closed world), and it keeps README's "no stored closures"
  (judge fix 1). Visibility closes an unsound hole: a look next to
  `Money` could hand any program `Money.unchecked` (judge fix 2).

### Rule 3. A conversion is two named functions.

`format unix for Time = Int via (Time.from_unix, fn(t) => t.unix())`.
`read` is `X -> T ! E`. `write` is `T -> X`, or `T -> X ! E` when some
values have no `X`. Both are pure. `X` is what gets read, walked by the
same rules, so looks chain. A look can go one way: `reads` takes only
`read` and can't encode; `writes` takes only `write` and can't decode.
A look that keeps less than the type says `lossy`.

- **Effect v4:** `SchemaTransformation.transform` / `transformEffect`
  is a pair of getters, decode and encode, both able to fail, attached
  with `Schema.decodeTo`. Built-ins like `DateTimeUtcFromMillis` are
  named pairs. Ren keeps the pair and drops the object: `X` is Effect's
  `Encoded` side, written once.
- **Ren:** decision 4. `reads` is layer 2's word; `writes` is its
  mirror (judge fix 5). A failing write is judge fix 3b. Purity follows
  from looks running in decoders, build-time checks and generated
  tests.

### Rule 4. A record look is lines, and `=` means one thing.

`id` (as itself), `customerId = customer` (rename), `total: Money.cents`
(through a look), `kind = "order"` (constant, written and checked), `..`
(the rest). The wire name is always left of `=`. The token on the right
decides the meaning: a lowercase identifier is a field; a literal or an
uppercase constructor is a constant. Without `..` a look lists exactly
what it carries, and a left-out field needs a default or `Option`. A
`writes` look may leave out anything. Names written in a look are
exact; `keys: camel_case` re-cases only names from the type.

- **Effect v4:** `Schema.encodeKeys` renames on the encoded side.
  Absence takes `optionalKey`, `optional`, four `withDecodingDefault*`
  variants, a constructor default and an `Option` family, because JS
  has three kinds of "not there".
- **Ren:** decision 5, layer 2's line form. One absence (`Option`) and
  one default (the field's) replace Effect's table. No `field = value`
  line in looks (judge fix 4): it made `status = Active` ambiguous.

### Rule 5. A sum has an internal tag, and one rule for its payload.

With no look: `{"type": "Placed", ...}`, the case name as written. A
case with named fields puts them beside the tag; a case with one record
payload merges its fields; any other payload goes under `"value"`. A
sum look gives tags (`| Placed as "order.placed": Event.Placed.v1`),
passes the rest with `| ..`, and can splice a one-field sum case with
`| Kv as ..`. Tags are distinct unless the library reads a second tag
(http statuses; the body's tag decides). Decoding a tag is one lookup in
a perfect hash. Text media read a fieldless sum as its name; json does
not.

- **Effect v4:** `Schema.TaggedUnion` and `toTaggedUnion("type")` pick
  the tag field and reject duplicates. `SchemaAST.ts` (union
  candidates, ~3571) maps a literal tag to its member in one lookup.
  The default tag is `_tag`, because JS has no sums.
- **Ren:** decision 6. The payload rule is judge fix 7: decision 6 was
  undefined for `Put(Version)` and `Get(Entry)`, half of `D.Reply`. The
  splice closes R#4 (`flot get`, not `flot kv get`).

### Rule 6. A call chooses looks in one settings record.

Each library has one settings record: its knobs plus `formats`, a list
of `Look` tags. Two looks for one type is a build error. A top-level
settings record is checked at build time against every type it is used
with. Decoding is strict: an unknown key is `Unknown(at)`;
`unknown: Ignore` relaxes a whole call. cli uses the same looks for flag
names; short flags and positionals stay in `cli.spec`. One look serves
every medium: `listen = addr` is `"listen"`, `FLOTT_LISTEN` and
`--listen`.

- **Effect v4:** `toCodecJson`, `toCodecStringTree` and `toCodecGoJson`
  are different walks the caller picks; a global change (Go nulls) is a
  different function, not an annotation. `ConfigProvider.constantCase`
  makes casing a source setting. Effect ignores unknown keys by
  default, so a typo in `"expect"` becomes an unconditional put (E#8).
- **Ren:** decisions 7 and 8. Because `formats` is enum data, a library
  can pass settings through its own functions (closes the drafts' open
  question 5).

### Rule 7. A library sees a shape, never a look.

`shape.through<T>(formats)` is `T.shape` with the walk applied: new
names, constant nodes, tag rules, and only the encoded side of a `via`
or `parse`. Conversions run in the typed doors `build<T>` and `view<T>`,
which the compiler writes. So a library is a `match` over data and
can't skip a type's rules. Errors are one std set, `Problem`, with paths
in the look's names and the type's field alongside, and no input kept.
A named error set has a shape as the `Err` side of a `Result`. Release
builds specialize each (type, settings) pair into straight-line code.

- **Effect v4:** `SchemaIssue` is a tree (`MissingKey`, `UnexpectedKey`,
  `InvalidType`, `InvalidValue`, `Pointer` for path steps); input is
  kept only with `reportInput: true`. `toJsonSchemaDocument`,
  `Arbitrary`, `toEquivalence` and `SchemaBinary` are all walks of one
  description. The AOT compiler is what Ren's specialization does
  without a fallback.
- **Ren:** decision 9; stage 12's A1 and A2 (`shape` as a requirement,
  `Shape`/`Value` ADTs, `view`/`build`). Error sets with shapes is
  judge fix 6, which keeps errors.md's "an error is never a sum type".

### Rule 8. Versions are looks; a settings record is what you freeze.

A version is another look of the same type. Several looks may be
writable, so a server answers each client in its version. `ren formats
freeze` records a fingerprint per frozen settings record and type: the
encoded shape, every look's name, and the IR hashes of every `via`
function reached. A look of `D.Call` or `D.Reply` can't be `lossy`; its
write fails with `NotInVersion` instead. `ren test` runs one generated
round-trip property per look, from the type's own generator.

- **Effect v4:** `SchemaBinary`'s `fingerprint: true` puts an 8-byte
  layout hash on every frame, because there is no connect step. Effect
  has no freeze; v1 needs `EntryV1`, `PageV1` and mapping in handlers
  (E#4). `Arbitrary.schema` derives generators but leaves the round
  trip to you.
- **Ren:** decision 10's "versioning by looks plus a shape hash".
  Hashing `via` functions is judge fix 3a: without it, `from_unix`
  moving to milliseconds kept every hash. Banning `lossy` protocol looks
  is fix 3b: it is what layer 2's "one writable format" rule was for.

---

## 3. Doc changes

Both drafts are updated in place with the judge's fixes.

**formats.md** — `draft-formats.md`
(`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/looks/draft-formats.md`).
It replaces "A type, and its formats" and adds sections up to "Placing
fields":

| Section | What changed from the first draft |
|---|---|
| A type, and its formats | `Look`/`Layout` as compiler-written enums (fix 1); `pub format` visibility (fix 2) |
| Looks of a scalar: `via` | write may fail (fix 3b); `reads`/`writes` one-way looks (fix 5) |
| Looks of a record: lines | `=` decided by token, no `field = value` (fix 4); projections are `writes` looks (fix 5) |
| Looks of a sum: tags | statuses may repeat; `\| Case as ..` splice (R#4) |
| Looks of an opaque type | a `via` that calls private functions makes the look private (fix 2) |
| Errors carry paths | error sets have a shape inside `Result` (fix 6) |
| Versions are looks | no `field = value`; no `lossy` protocol looks (fixes 3b, 4) |
| Looks of a dependency | `remote` word; `D.Error`; `Result<D.Reply, D.Error>`; tagless REST replies; decode problems are 400; mounts as descriptions (fixes 6, 8) |
| Checked when building | the new errors from all of the above |
| A round-trip test per look | one-way looks get one-way tests |
| Later | OpenAPI moves into the http stage |
| Other edits / Elsewhere | layer 2's writable rule narrowed to layouts; `as` written side by side; one sentence in errors.md; a note in language.md §6 that `D.Call`/`D.Reply` are data |

**shapes.md** — `draft-shapes.md`
(`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/looks/draft-shapes.md`).
It replaces the bullets from "Renames and defaults are settings on the
format" through "An opaque type's shape is opaque outside its module":

| Section | What changed |
|---|---|
| The walk | new "Seeing the walk": `ren explain` and hover (Lens 1 fix 1) |
| Settings records | `formats` is a list of `Look` tags (fix 1) |
| Sums by default | the payload rule; no fieldless-as-string in json; text media read names (fix 7) |
| How each library reads it | json row follows fix 7 |
| Freezing what is sent | the fingerprint covers looks and `via` IR hashes (fix 3a) |
| Dependencies are protocols | one mechanism, `call(c: D.Call)`; `remote` and `Why`; `Result` on the wire; envelope with a reserved `Chunk` and the version check (fix 8, Lens 1 fixes 3 and 4) |
| Questions | defaults: no look-level default; open questions 2, 3 and 5 closed |

**Also, one line each:** errors.md (error sets have shapes inside
`Result`), language.md §6 (`D.Call`, `D.Reply` are data enums the
compiler writes; `Look` and `Layout` are enums too), shapes.md's
`call(op, args)` clause becomes `call(c: D.Call)`.

---

## 4. Decisions left for the owner

**1. One-way looks, `reads` and `writes`.** A `writes` look may leave
out any field, which relaxes decision 5 in the one direction where its
reason (reading back) doesn't apply.
- **Recommend:** take it. It costs one word, matches layer 2's
  `reads`, and makes response projections (`User.public`) and CLI-only
  looks (`Bytes.text`) honest without `lossy`.
- **Runner-up:** looks stay two-way; a projection is a `via` to a wire
  record.

**2. `remote` in the dep header, instead of `Unavailable` on every op
by hand.** Decision 10 says remote deps declare `Unavailable` on every
op.
- **Recommend:** `pub dep Keys, remote =` writes `Unavailable(why:
  std.remote.Why)` into every operation. It is still declared and shown
  by `ren types`, std owns the one spelling, and the server's handlers
  stop mapping disk failures into a client's word (R#3).
- **Runner-up:** write it by hand on every op, with `Why` from std, and
  a build error if a remote-used dep lacks it.

**3. Looks as a compiler-written `Look` enum.**
- **Recommend:** take it. No stored closures, `formats` is plain data,
  debug builds `match` on the tag, release builds specialize.
- **Runner-up:** looks are not values at all; `formats` must be a
  top-level constant or literal, and libraries can't pass settings on.

**4. The default sum payload rule, and no fieldless-sum-as-string in
json.**
- **Recommend:** named fields beside the tag, one record payload
  merged, anything else under `"value"`. json keeps decision 6's object
  for fieldless sums; text media (cli, env, query, sql) read the name.
- **Runner-up:** also write fieldless sums as strings in json. Shorter
  wire, but an exception to decision 6 that changes when a case gains a
  field.

**5. Status looks may repeat a status.**
- **Recommend:** yes, in http's status look only. The body carries the
  error's tag, so `Busy` and `Unavailable` can both be 503 (R#2).
- **Runner-up:** statuses stay distinct; errors that share a status
  become one error with a reason field.

**6. Splicing a sum case, `| Kv as ..`.**
- **Recommend:** take it, limited to a one-field case whose field is a
  sum. It gives `flot get a` (R#4) without general flattening.
- **Runner-up:** none; live with `flot kv get a`.

**7. Headers and raw bodies in REST looks (R#7).** flottning wants
`If-Match` and raw value bodies on day one.
- **Recommend:** in the http stage, http's route tag grows two line
  forms inside a REST look of a case: a field read from a header, and
  one field as the raw body. Both are http's table, not the walk.
- **Runner-up:** fields go by http's method rule only (query for `GET`
  and `DELETE`, json body otherwise) for 1.0.

**8. Handler-wide `fail` arms (R#13).** Not a looks rule, but it is
where Ren is worst against Effect's `catchTag`.
- **Recommend:** a handler may end with `fail` arms that apply to every
  operation in it: `... fail Disk(path) => internal(path)`. Written
  once, explicit, binds no whole error.
- **Runner-up:** one arm per operation, as now.

**9. Writing a `Secret`.**
- **Recommend:** allow it only through a named look over the public
  `reveal`. It sits in a settings record, where grep and review find it.
- **Runner-up:** no public `reveal`, only a `with_secret(s) fn(x) =>`
  block, so no look can write one.

**10. First error or all errors.**
- **Recommend:** stop at the first, except `config`, which collects all.
- **Runner-up:** an `errors: All` setting in every library, for forms
  and bulk imports.

---

## 5. How it sets up dependency-as-protocol

### Ready

- **`D.Call`, `D.Reply`, `D.Error` are data with shapes.** They are
  ordinary sums and an error set the compiler writes, so they have
  default looks, `show`, `==` and generators. `D.Call` exists only if
  every operation is data, decision 18's rule for `post`.
- **One mechanism.** The `call(c: D.Call)` clause and `next.call(c)` are
  `D.call`; shapes.md's `call(op, args)` is replaced, not kept beside.
- **The route table is a look.** `| Get as GET"/v1/keys/\{key}"` is a
  sum look whose tags are `http.Route` values. Holes are fields, read
  through `parse(Str)`. The build checks holes, overlaps and exhaustive
  statuses.
- **The CLI is a look.** `cli.parse<Keys.Call>` with a cli look and a
  splice needs no new rule.
- **Errors cross the wire as `Result<D.Reply, D.Error>`,** without
  breaking errors.md.
- **Remote failure is declared once.** `remote` and `std.remote.Why`
  (`Refused | Timeout | Decode(Problem) | Protocol | Version | Denied |
  Server`).
- **Versions.** `Keys.v1`/`Keys.v2` as settings records, frozen with a
  fingerprint that covers `via` functions; protocol looks can't be
  lossy; the hash is checked once per connection.
- **Several deps on one port.** `http.mount<D>(settings)` is a
  description of a std dep, so a list of mounts is an array of a
  compiler-written enum.

### Left

- **The envelope's spec:** call id, reply, defect, cancel, a reserved
  `Chunk` for streams, the shape-hash handshake, framing apart from the
  payload look (Effect v4's `RpcMessage` and `RpcSerialization`).
- **Transports as deps:** the interface of a transport dep that
  `http.client<D>` and a socket transport both satisfy.
- **Typed per-op errors from `D.call` (R#5).** `Keys.call` fails with
  all of `D.Error`; a proxy or test wants the op's own set.
- **Splitting a case across versions (R#1).** It stays a wire type and
  two functions. Over a tagged transport `D.Reply` needs the same.
- **Streaming operations,** server-sent and NDJSON, with typed errors
  after the status (Effect v4's `StreamSse`).
- **Auth on the client** (E#7 is the same in Effect), and idempotent
  retry of conditional puts (stage 12's F#16).
- **OpenAPI as a library** in the http stage.

---

## 6. Compiler work and staging

No `feasibility.md` was in this folder, so this comes from the compiler
source and stage 12's staging. None of formats layer 2, `shape`,
`D.Call` or `post` is in the compiler yet.

### Work, by pass

| Pass | Work | Builds on |
|---|---|---|
| syntax (`lib/syntax/parser.ml`) | `[pub] format NAME for T [, words] =` with record lines, sum lines (`\| C as tag: look`, `\| ..`, `\| C as ..`), `X via (...)`. One parser for layouts and looks; the kind is read off the lines. | layer 2 (7b) needs the same parser |
| sema (`lib/sema`) | look names in the type's namespace (clash with methods); line checks (token rule, defaults, `..`, distinct tags); `via` typing and purity; visibility; one-way use at calls; `D.Call`/`D.Reply`/`D.Error` written from a dep's signature, with the data-only check (beside `infer_handlers.ml`); `remote` extending each op's error row | requirements as in `infer_reqs.ml` |
| link (closed world) | the `Look` and `Layout` enums, one tag per format in the program; settings records checked against their types | module-build.md's whole-program link |
| lower / eval | `shape` as a requirement; `shape.through<T>(formats)`; the `view<T>`/`build<T>` doors per (type, look set), extending the one walk in `lib/eval/walk.ml`; debug builds `match` on the `Look` tag | stage 12a (A1, A2, top-level `let`) |
| native (`lib/native/specialize.ml`) | add the settings constant to a copy's key, so each (type, settings) pair gets straight-line code; perfect-hash tables for tags and routes; no `Value` tree | specialize.ml's demand worklist |
| tools | `ren explain` and editor hover; `formats.lock` with the fingerprint (encoded shape, look names, `via` IR hashes, reusing the content hashes specialization caches by); one generated round-trip test per look | 11c generators; `editors/` |

### Staging

1. **12a, looks part 1 (with json, cli, config).** Parser, sema checks,
   the `Look` enum, `shape.through`, the doors, settings records,
   strict decoding, the default sum rule, `Problem`. `ren explain` ships
   here, not later. Done when: P1's types round-trip through json with
   and without `Order.v1`; flottning's config reads `listen` from file,
   env and flags through one look; a misspelled look or a left-out field
   fails the build with the messages in draft-formats.
2. **12a measurement.** Release `json.decode<Order>` through `Order.v1`
   within 1.5× of a hand-written decoder, like the plain one. This is
   stage 12's risk 2 with looks added; if it fails, the visitor fallback
   returns.
3. **12a, looks part 2.** `reads`/`writes`, `lossy`, generated
   round-trip tests, visibility across modules.
4. **12c, the network.** `D.Call`/`D.Reply`/`D.Error`, `remote`, REST
   and status looks, `http.mount`/`http.client`, the envelope,
   `formats.lock` and the connect check, OpenAPI. Done when: programs.md
   §1.8 builds, the v2 change fails against frozen `KEYS_V1` until v1's
   looks exist, and a v1 client's bytes still get v1's answer.
5. **After 12c.** Streams over the envelope, typed per-op `D.call`,
   transports beyond http.

Layer 2 layouts (7b) and looks share the parser and the kind check, so
whichever lands first carries both.

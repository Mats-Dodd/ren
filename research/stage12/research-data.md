# Research: data at the edges (JSON, CLI, config, SQL)

For stage 12. What flottning needs at its three layers:

- **CLI:** subcommands, flags, env fallback, help, completions, JSON output.
- **Server:** JSON request and response bodies, config from env, SQL with bound parameters, rows decoded into records.
- **Storage engine:** SQLite or its own pages, declared binary `format`s (formats.md, not covered here), plus config.

All four domains have the same structure. Text from outside gets parsed into a typed value, and a typed value gets written back out as text. Every ecosystem below has had to answer the same questions: where the per-type description comes from (derive, reflect, hand-written combinators, codegen), where customization lives (per-field attributes or per-format settings), when checking happens (build time or run time), and how holes in a literal reach a library.

Sources are listed with each section. Local clones: `/tmp/ren-refs/effect/packages/effect/src/Schema.ts` (Effect v4 Schema) and `/tmp/ren-refs/swift-evolution/proposals/0228-fix-expressiblebystringinterpolation.md` and `0382-expression-macros.md`. The Go clone in `/tmp/ren-refs/go` is sparse and has no `encoding/json`.

---

## 1. Serialization

### serde (Rust)
**Model.** `#[derive(Serialize, Deserialize)]` proc macros generate visitor code against a fixed data model of 29 types. The two halves are separate: a format (serde_json, bincode, toml) implements `Serializer`/`Deserializer`, and a type implements `Serialize`/`Deserialize`. M formats and N types need M+N implementations, not M×N. For zero-copy, `Deserialize<'de>` lets `&'de str` and `Cow<'de, str>` fields borrow from the input buffer (`#[serde(borrow)]`).
**Went right.** Speed: monomorphized, no intermediate tree, in the same class as hand-written code. The format/type split. One derive serves every format.
**Mistakes.**
- **Attribute sprawl.** There are about 60 attributes (`rename`, `rename_all`, `default`, `skip_serializing_if`, `flatten`, `tag`, `content`, `untagged`, `with`, `bound`, `remote`, ...), and they interact badly. `flatten` and `untagged` buffer the input into an internal `Content` tree, which is slow, loses integer/float distinctions, breaks `deny_unknown_fields` and gives poor errors (serde issues #1183, #1600, #2186).
- **Errors.** `untagged` reports only "data did not match any variant", with no path. Paths need the `serde_path_to_error` crate.
- **Compile time.** Proc macros plus monomorphization are a large share of build time in big Rust services.
- **Decimals.** These needed the `arbitrary_precision` feature, a global hack that changes the number representation for the whole build.
- **Orphan rule.** A type you don't own needs `#[serde(remote = ...)]` shims.

Sources: serde.rs (attributes, data model); github.com/serde-rs/serde issues above; dtolnay's `serde_path_to_error`.

### Go `encoding/json` (v1) and `encoding/json/v2`
**Model.** Run-time reflection over struct fields. Struct tags (`json:"name,omitempty"`) customize it, and the `Marshaler`/`Unmarshaler` methods are the escape hatch.
**Went right.** Nothing to generate, it works on any type, and the package is in std, so every library agrees on it.
**Mistakes (enumerated by the v2 proposal itself):**
- Field matching is case-insensitive.
- Duplicate keys are accepted, last one wins, which is a security issue when two parsers disagree.
- Invalid UTF-8 is silently replaced.
- A nil slice encodes as `null`, but an empty one as `[]`.
- `omitempty` is defined by Go zero-ness, so a `time.Time` struct is never "empty".
- Numbers go to `float64` in `interface{}` unless you call `UseNumber`.
- Method-based customization can't be overridden by the caller.
- It's slow, because reflection runs on every call.
- Tags are stringly typed and checked only by `vet`.

**v2** (`GOEXPERIMENT=jsonv2`, Go 1.25): matching is case-sensitive, duplicates and invalid UTF-8 are rejected, a nil slice encodes as `[]`, and there's `omitzero` (backported to v1 in 1.24). Options are values passed per call (`json.Marshal(v, json.StringifyNumbers(true))`), not global state. Callers can supply marshalers for types they don't own (`WithMarshalers`). The syntax layer is split into its own package, `jsontext` (a streaming tokenizer), from the semantic layer. Unknown members can be kept via an `inline` field or rejected via `RejectUnknownMembers`.

Sources: go.dev/issue/63397 (Joe Tsai, "encoding/json/v2"); go.dev/blog/jsonv2-exp (2025); pkg.go.dev/encoding/json/v2.

### Effect Schema (TypeScript)
**Model.** A schema is a value `Schema<Type, Encoded, R>` describing both directions. `decodeUnknown` checks and transforms outside data into `Type`, and `encode` goes back. Transformations (`transform`, `transformOrFail`) relate an encoded form to a domain form, for example an ISO string to a `Date`, or a string to a branded `Email`. From the same value it derives JSON Schema, `Arbitrary` (property tests), `Pretty` and `Equivalence`. In v4 the API is `decodeUnknownEffect`, `encodeEffect`, `decodeUnknownSync` and so on (`Schema.ts` lines 1527–2080 in the local clone).
**Went right.** One description serves both directions plus test generators. Branded/refined types decode through their check, so "parse, don't validate" happens at the edge. Errors are structured, with paths.
**Mistakes.** TS type-checking cost, and type complexity that shows up in error messages. Bundle size. The schema mirrors the type rather than being derived from it, so in TS you write the schema and infer the type. Requirements (`R`) inside schemas make it harder to reason about what runs when you decode.

Sources: effect.website/docs/schema; local clone.

### Elm decoders, OCaml
**Elm.** Hand-written combinators (`Json.Decode.field "name" string`, `map2`..`map8`, `andThen`). It's total: a decode failure is a `Result`, never a crash. The cost is boilerplate, and the `mapN` arity ceiling pushes people to `elm-json-decode-pipeline`. The Elm community has asked for derivation for years. This shows that explicit hand-written decoders don't scale to hundreds of types.
**OCaml.** `ppx_deriving_yojson` and `ppx_yojson_conv` (Jane Street), and `ppx_sexp_conv`. The derive uses attributes (`[@key]`, `[@default]`), with the same sprawl as serde, only smaller. Ppx ecosystems break across compiler versions (the ppxlib migration churn).

Sources: package.elm-lang.org/packages/elm/json; github.com/ocaml-ppx/ppx_deriving_yojson.

### Zod
**Model.** Schema-first values, `z.infer<typeof S>`, `parse`/`safeParse`. Zod 4 (2025) rewrote it for type-checker and run-time speed.
**Went right.** It's ubiquitous because it's simple. The Standard Schema spec (standardschema.dev) let Zod, Valibot, ArkType and Effect interoperate through one tiny interface. That's the "shared type" lesson from stdlib.md.
**Mistakes.** It's one-directional. Encoding came late (codecs in Zod 4.1). It was slow before v4, and `.transform` breaks round-tripping.

Sources: zod.dev; zod.dev/v4; standardschema.dev.

### Haskell aeson
**Model.** `ToJSON`/`FromJSON` classes, derived via `Generic` or Template Haskell, with an `Options` record for customization (`fieldLabelModifier`, `omitNothingFields`, `sumEncoding = TaggedObject | UntaggedValue | ObjectWithSingleField | TwoElemArray`, `rejectUnknownFields`).
**Went right.** **Customization is one record of settings per derivation, not per-field attributes.** That's the closest prior art to shapes.md's "renames and defaults are settings on the format." `toEncoding` writes straight to a builder instead of going through the `Value` tree, which was a big speed-up and the right default.
**Mistakes.**
- **Hash flooding.** `Object` was a `HashMap Text Value` with a fixed hash salt, so crafted keys DoS'd servers. aeson 2.0 (2021) made it an opaque `KeyMap`. Breaking every library was the price.
- **Big numbers.** `Scientific` let `1e1000000000` decode into `Integer`, which allocates forever. Bounds were added later.
- **Two classes per direction** (`toJSON` and `toEncoding`), which disagreed when users wrote one by hand.

Sources: hackage.haskell.org/package/aeson (changelog 2.0); "Hash flooding aeson" (cs-syd.eu, Tom Sydney Kerckhove, 2021).

### simdjson
**Model.** Two stages. Stage 1 finds every structural character and validates UTF-8 with SIMD, at gigabytes per second. Stage 2 builds a tape. The On-Demand API skips the tape: it's a forward-only cursor that parses only the fields you touch, in the order you touch them.
**Went right.** It showed that UTF-8 validation and structural scanning are nearly free, so strictness costs nothing. On-Demand plus typed access is the fastest way to decode into a known type.
**Mistakes / limits.** On-Demand forbids going backwards (out-of-order field access costs rescans). Its API is easy to misuse, since values are invalidated when the cursor moves on.

Sources: Langdale & Lemire, "Parsing Gigabytes of JSON per Second" (VLDB J. 2019); Keiser & Lemire, "On-Demand JSON" (SPE 2024); simdjson.org.

---

## 2. CLI parsing

### clap (Rust)
**Model.** Either a builder API or `#[derive(Parser)]` on a struct. Field types decide behavior: `bool` is a switch, `Option<T>` is optional, `Vec<T>` repeats, and an enum with `#[derive(Subcommand)]` gives subcommands. Doc comments become help text, `#[arg(short, long, env = "PORT", default_value_t = 8080)]` sets the rest, and `ValueEnum` handles closed choices. `clap_complete` generates shell completions.
**Went right.** "The type is the CLI": sum type means subcommands, and doc comments mean help. Errors are good, with suggestions ("did you mean `--port`?").
**Mistakes.** The v2→v3→v4 churn: `structopt` was merged in, and attributes were renamed twice. Attribute sprawl again. Binary size and compile time are noticeable, which led to `argh` (Fuchsia, deliberately minimal) and `lexopt`. Env fallback only works per field, with no idea of a config file.

Sources: docs.rs/clap (derive tutorial); github.com/google/argh (rationale: code size).

### cobra (Go)
**Model.** A tree of `*cobra.Command` values with `Run` funcs, built on pflag. It has persistent flags inherited by subcommands, generated help, completions and man pages, and integrates with viper.
**Went right.** Subcommand trees, completions, and conventions shared by kubectl, gh and hugo.
**Mistakes.** Commands get registered in `init()`, so global mutable state is assembled by import side effects. Flags are bound to package-level variables. It's stringly typed. Cobra and viper together became the canonical example of Go config spaghetti.

Sources: cobra.dev; github.com/spf13/cobra.

### Python click / typer
**Click.** Decorators stack options onto functions, and commands compose into groups. **Typer.** Type hints on the function's parameters *are* the CLI (`def main(name: str, count: int = 1)`), which makes defaults and types single-sourced.
**Lesson.** Typer, like clap derive, shows that deriving from types wins on ergonomics. Click's composability, where groups are just values, matters for big tools.

Sources: click.palletsprojects.com; typer.tiangolo.com.

### Go `flag`
**Model.** Minimal: `flag.Int("port", 8080, "usage")`. A single dash and a double dash mean the same thing, and parsing stops at the first non-flag.
**Went right.** It's tiny, in std, and good enough for tools.
**Mistakes.** No subcommands (people use `flag.NewFlagSet` per command by hand). Its conventions don't match POSIX/GNU, which is why pflag exists. The parsed values live in global state.

Sources: pkg.go.dev/flag.

---

## 3. Configuration

### Viper (Go)
**Model.** A global singleton key→`interface{}` map, merged from defaults, a config file (JSON/TOML/YAML/HCL/...), env, flags and remote KV, with precedence explicit set > flag > env > file > KV > default. It supports hot reload (`WatchConfig`).
**Mistakes, mostly acknowledged by its maintainers' v2 plans:**
- **Keys are case-insensitive** by force-lowercasing, which breaks map keys and YAML that's case-sensitive.
- **Global state.**
- **Stringly-typed** `GetString("db.url")`, so typos are silent.
- **Env binding needs `AutomaticEnv` plus `SetEnvKeyReplacer` incantations.**
- **Unmarshalling into structs** goes through mapstructure, a second set of tags.
- **Huge dependency tree.**
- **Hot reload races.**

Sources: github.com/spf13/viper (README "Viper v2 feedback" issue #772).

### figment / config-rs (Rust)
**figment.** `Figment::new().merge(Toml::file("App.toml")).merge(Env::prefixed("APP_")).extract::<Config>()`, extracted through serde into a typed struct. **Every value carries metadata on where it came from**, so an error says "`port` from env var `APP_PORT`: expected u16, found `abc`". It's used by Rocket.
**config-rs.** It does the same layering with less provenance.
**Lesson.** Typed extraction plus provenance is what separates good config from Viper.

Sources: docs.rs/figment ("Metadata"); docs.rs/config.

### 12-factor
Config lives in the environment, strictly separated from code. Env vars are flat strings, so nested config needs a naming convention (`DB__URL`). Later critiques: env leaks secrets into child processes and crash dumps, and there's no schema or validation. Hence typed loaders plus secret handling.

Sources: 12factor.net/config.

---

## 4. SQL

### sqlx (Rust)
**Model.** `sqlx::query!("select id, name from users where plan = $1", plan)` is a proc macro that, **at compile time, connects to a live database** (`DATABASE_URL`), prepares the statement, and gets parameter and column types and nullability. `query_as!(User, ...)` maps to a struct. Offline mode (`cargo sqlx prepare`) caches the describe results in `.sqlx/` JSON so CI builds without a database.
**Went right.** You write plain SQL and it's checked, with no DSL. Parameters are always bound.
**Mistakes.**
- **Builds need a live database or a cache file** that can drift from it, so builds aren't hermetic.
- **Nullability inference is imperfect** (`as "name!"` / `as "name?"` overrides).
- **Dynamic queries** (optional filters, `IN` lists) fall outside the macros, so you're back to strings or `QueryBuilder`.
- **Compile time.**

Sources: docs.rs/sqlx (macro docs, "offline mode"); github.com/launchbadge/sqlx FAQ.

### jOOQ (Java)
**Model.** Generates Java classes from the live schema. A type-safe DSL mirrors SQL (`select(USERS.NAME).from(USERS).where(USERS.PLAN.eq(plan))`). Dialects are emulated.
**Went right.** "SQL first, not ORM." Queries compose as values, which handles dynamic queries well.
**Mistakes.** The codegen step adds a build stage, and generated code goes stale. The DSL can't express everything, and every vendor feature needs a DSL addition. Commercial licensing for commercial DBs.

Sources: jooq.org/doc; Lukas Eder's blog.

### Diesel (Rust)
**Model.** `table!` macros (schema.rs, generated from migrations) plus a trait-heavy typed query DSL. Bad SQL doesn't compile.
**Mistakes.** Error messages: pages of trait bounds. Compile times. Async came late (`diesel-async`). The DSL leaks type-level encoding to users. This is the cautionary tale for checking SQL in the type system.

Sources: diesel.rs/guides; diesel issue tracker on error messages.

### Go `database/sql`
**Model.** std defines `DB` (a pool), `Tx`, `Rows` and `Scan(&a, &b)`, and drivers implement `driver.*`. That makes it the shared interface stdlib.md praises.
**Mistakes.**
- **`Scan` into pointers by column position** means a reordered `select` silently misassigns columns of the same type.
- **`sql.NullString`/`NullInt64` wrappers** were needed until generics brought `sql.Null[T]` in 1.22.
- **`Rows.Close` leaks** when people forget it.
- **No named parameters,** and placeholder syntax varies by driver (`?` vs `$1`).
- **Context support came late** (`QueryContext`).

sqlc fills the gap by generating typed Go from `.sql` files plus a schema, checked against the *schema file* rather than a live DB.

Sources: pkg.go.dev/database/sql; go.dev/doc/database; sqlc.dev.

### Ecto (Elixir)
**Model.** Separate pieces: `Schema` (data), `Changeset` (validation and casting at the edge), `Query` (a composable macro DSL) and `Repo` (the thing that talks to the database, passed explicitly, not Active Record). In queries, `^x` marks an interpolated **parameter**, so an unpinned variable is a compile error, never a splice.
**Went right.** Data stays data and the Repo is the effect. That's the closest to Ren's "deps talk to the world" and to DDD. The explicit `^` makes it obvious which values get bound. Changesets are "parse, don't validate" for writes.
**Mistakes.** A second query language to learn. Preloading and association complexity.

Sources: hexdocs.pm/ecto (Ecto.Query, Ecto.Changeset, Ecto.Repo).

### Interpolation that libraries intercept

| Mechanism | What the library receives | When the static part is known | Fate |
|---|---|---|---|
| **JS tagged templates** `` sql`… ${x}` `` | `(strings, ...values)`. `strings` is a frozen array, *identical per call site*, so it works as a cache key | run time, but stable identity per site | Works. postgres.js, slonik, lit-html rely on it. Weakness: any function can be a tag, values are untyped, and a forgotten tag (`sql(` vs `` sql` ``) is a plain string |
| **Scala interpolators** `sql"… $x"` | desugars to `StringContext("…", "…").sql(x)`, an extension method on `StringContext` chosen by name | compile time, if the method is a macro (Quill, doobie's `sql` builds a `Fragment` with params) | Works. Name-resolved, so `sql` must be in scope. Macros enable compile-time checks but are hard to write |
| **Swift** `ExpressibleByStringInterpolation` | the *expected type* drives it: `appendLiteral` and overloaded `appendInterpolation(_:)` per hole type | compile time, by overload resolution | Works and type-safe: a hole of an unsupported type fails to compile. Implicit, since the literal's meaning depends on the context type. SE-0228 |
| **Java JEP 430 → 459, withdrawn** `STR."… \{x}"` | a `StringTemplate` (fragments plus values) passed to a *processor* | run time | Previewed in 21 and 22, **withdrawn from 23** (Goetz, amber-spec-experts, Apr 2024). Reasons: the processor-dot syntax (`STR.`, `RAW.`) was awkward. Processors were a needless abstraction, since an API can just take a `StringTemplate` parameter, the way `PreparedStatement` would overload. And the implicit `STR` import was magic. The redesign direction is a template literal *as a typed value* that libraries accept by overloading, with no processor syntax. No successor has shipped as of this writing. |
| **Python PEP 750 t-strings** `t"… {x}"` (3.14) | a `Template` object: `strings` plus `Interpolation(value, expression, conversion, format_spec)` | run time | Shipped. Deliberately **one prefix**, not arbitrary tags (PEP 501's lineage, and Java's lesson). Libraries take `Template` as a parameter: `sql(t"…")`, `html(t"…")` |

The convergence matters for Ren. Java and Python both ended at the same conclusion: **don't make the prefix a user-extensible hook. Make the literal a typed value with parts and holes, and let ordinary functions accept it.** Swift shows that type-directed holes can be checked statically. JS shows that the static parts' identity is a free cache key (prepared statements).

Sources: openjdk.org/jeps/430, /459; mail.openjdk.org amber-spec-experts "Update on String Templates (JEP 459)" (Brian Goetz, 2024-04-05); peps.python.org/pep-0750; developer.mozilla.org (Template literals, tagged); docs.scala-lang.org/overviews/core/string-interpolation; local `swift-evolution/proposals/0228-*.md`, `0382-expression-macros.md`.

### Swift macros
**Model.** `#stringify(x)` and `@Model` are compiler plugins: separate processes that get a syntax tree and return expanded code, sandboxed. They come with expansion visible in the IDE.
**Lesson.** Even sandboxed, macros cost build time (swift-syntax compile times were a well-known pain until prebuilt swift-syntax) and errors land in expanded code. shapes.md already rejects code generation. Swift is supporting evidence.

### Embedding SQLite
**Model.** A single amalgamation C file. `prepare`/`bind`/`step`/`column`. Pluggable VFS (file I/O, locking, time, randomness) and memory allocator. WAL mode. `STRICT` tables since 3.37 fix type affinity, where a TEXT column would happily store an integer.
**Lessons.** The VFS is how `sim.fs` injects torn writes and how replay stays deterministic: route the VFS's time and randomness through Ren's deps too (`xCurrentTime`, `xRandomness`). Use `STRICT` tables by default so row decoding by shape is sound. `sqlite3_prepare` caching per call site follows from the template-identity lesson. `column_decltype` and `EXPLAIN`-free introspection (`sqlite3_stmt` column count and names) are enough to check rows against a type *at build time against an in-memory DB built from schema.sql*, which is sqlc's approach, hermetic.

Sources: sqlite.org/vfs.html, /strict.html, /amalgamation.html, /c3ref/prepare.html.

---

## 5. Lessons for Ren

**L1. Shapes really are the one mechanism. Keep it that way.** serde, Go, aeson, clap, figment, sqlx's `query_as` and Typer all derive from the type, and the hand-written alternatives (Elm, Zod, Effect) end up wanting derivation. The recurring failure is the *customization channel*: serde's 60 attributes, Go's struct tags, mapstructure tags, clap's `#[arg]`. aeson's single `Options` record and Go v2's per-call option values are the model for shapes.md's "settings on the format." Concretely, each format takes one settings record:

- `json`: `{ keys, sums: Tagged("type") | External | Untagged, unknown: Ignore | Reject, null_is_none }`
- `cli`: `{ env_prefix, case }`
- `config`: sources and precedence
- `sql` rows: `{ columns: snake_case }`

A type that needs more is its own type, converted by hand. Hold that line. It's what keeps the language unified.

**L2. Opaque `parse` is the only validation hook, as Effect's transformations and Ecto changesets show.** `Email`'s `parse` runs during `json.decode`, `cli.parse`, `config.load` and row decoding alike. The same goes for encoding: an opaque type's shape says "encode via its `show`/underlying value." This one rule replaces serde's `with`, Go's `Marshaler`, and Effect's `transform`.

**L3. Strict by default, at zero cost** (simdjson shows UTF-8 and structure checks are nearly free; Go v2 and aeson 2.0 paid to get here late):

- matching is case-sensitive
- duplicate keys and invalid UTF-8 are rejected
- numbers go to `Decimal` from source text (stdlib.md) and never through a float
- depth, size and number-magnitude limits are part of the format's settings
- object keys go into an ordered `Table` or `Array` and are never hashed with a fixed seed

Absent vs `null` is `Option` plus a setting. Errors carry a path (already in shapes.md) *and provenance* (L5).

**L4. `cli` is shape over a sum type.** A record gives flags. A sum gives subcommands, recursively. `Bool` is a switch, `Option` is optional, `Array` repeats, defaults come from field defaults, and closed choices come from enum cases. Help and completions are derived from the same shape. **Gap:** help text needs doc comments, so **`T.shape` should carry each field's and case's doc comment.** That's a small addition to shapes.md, and it serves `cli`, generated OpenAPI/JSON Schema, and `config` errors. No `init()`, no globals (cobra): a CLI is a value parsed in `main`.

**L5. `config.load<T>` is figment, not Viper.**
- **One typed record. Layers are a list of sources** (defaults from the type < file < env < flags), and a flottning binary can use **one type for both its flags and its env** (`cli` and `config` share the field→name mapping).
- **Every value records where it came from,** so errors name the env var or the file:line.
- **Env and file reads go through `Os`/`Fs` deps,** so they're journaled and replay reproduces a config exactly.
- **`secret` fields are redacted** in `show`, logs and journals.
- **No hot reload in std.** It's a long-running service's own job, done over the deps.

**L6. Interpolation that libraries intercept: take Java and Python's conclusion, add Swift's static typing and Ren's build time.** Proposal for stdlib.md's open question:

- **`p"… \{x} …"` is sugar for calling `p` with a `Template`.** `p` is an ordinary function in scope, explicit and found by name like Scala's interpolators. The template's parts are `Array<Str>`, and its holes are values *with their shapes* (the `Value` view, which stays inside the library, per shapes.md). There's no new kind of hook and no implicit conversion. A plain `"…"` is unchanged (holes go through `show`).
- **The literal's constant part is build-time data.** The parts and the hole *types* are known while compiling, so `p` can expose a build-time check (`sql.check(parts, hole_shapes)`), run like a top-level `let`/`assert`, cached, failing the build with the error at the literal. This gives sqlx-style checked SQL **hermetically**: the check reads `let SCHEMA = sql.parse_schema(Fs.read("db/schema.sql"))` (shapes.md's own example) or an in-memory SQLite built from it, never a live database.
- **The result is a value, not a string.** `sql"…"` returns `Sql.Query { text, params }`, so parameters can't be spliced. The per-site identity of the parts is the prepared-statement cache key (JS).
- **Rows decode through `Sql.query<User>(q)`** by column *name* (never position, as Go's `Scan` does), checked at build time against the same schema. A nullable column needs `Option` (sqlx's nullability issue, solved by the schema file plus `STRICT` tables).
- **Dynamic queries compose fragments:** `sql"… where \{filter}"`, where `filter: Sql.Query` is spliced as SQL with its params merged. That's doobie's `Fragment` and jOOQ's composability, without a DSL.

**L7. Speed: debug builds reflect, release builds unroll** (shapes.md). Add simdjson's On-Demand as the release-mode decoder shape: decoding `T` from a `Bytes` cursor (streams.md) visits fields in the order the shape expects, with a fallback rescan, and borrows `Str` slices from the input where strings.md allows it (serde's `'de`). Encoding writes straight to an appendable `Str`/`Bytes` with no intermediate `Value` (aeson's `toEncoding` lesson).

**L8. One std interface, many implementations, conformance tests** (database/sql, Standard Schema). `Sql` is the dep, `sqlite.memory` is the fake, and the drivers pass one `sql_conforms` suite. SQLite's VFS, time and randomness are routed through Ren's deps, so sim and replay cover the storage engine itself.

**What flottning gets from L1–L8:** one type per concept serves its CLI flags, its env config, its JSON API and its rows. One validation hook (opaque `parse`) works for all of them. Its SQL is checked at build time from a schema file. Every input is a journaled dep read.

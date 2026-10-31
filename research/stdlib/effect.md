# Effect v4's standard library as prior art

What Ren's std should learn from Effect's: where Effect puts the line
between its core and its platform packages, how its services and layers
are built, what it installs by default, how much of `Schema` and `Data`
exists only because TypeScript lacks things, and what its maintainers
changed from v3 to v4 and why. Written 2026-10-30 against the clone at
`/tmp/ren-refs/effect`: `effect` 4.0.6 (`packages/effect/package.json:4`),
commit `a461561` of 2026-10-27, an LTS release (`README.md:9`,
`README.md:42-50`). Effect v4 only; v3 appears only where v4's own
migration guide or changelog says what changed.

Paths: `src/X.ts` is `packages/effect/src/X.ts`; `CHANGELOG` is
`packages/effect/CHANGELOG.md`; other paths are from the clone's root.
Ren's side is
[foundations.md decision 20](../../foundations.md#20-what-the-language-owns-and-what-std-owns),
[stdlib.md](../../stdlib.md), [deps.md](../../deps.md),
[language.md §§4-5](../../language.md#4-services-a-dep-is-something-youre-given),
[shapes.md](../../shapes.md) and [formats.md](../../formats.md).

## The lessons, ranked

Ranked by how much each should change Ren's design, most first.

1. **Promotion out of `std.x` shouldn't change an import, and `std.x`
   shouldn't be versioned apart.** stdlib.md's rule 4 names Effect's
   `unstable` modules as the model for `std.x` (stdlib.md:36), and its
   open question leans to versioning each `std.x` package on its own
   (stdlib.md:493). v4 went the other way on both. It removed the
   `effect/unstable/*` paths with no compatibility exports, so stability
   is now a tag on each export, not a place (`CHANGELOG:1266`,
   `MIGRATION.md:40-69`). And every package now shares one version,
   because independent versions made compatibility "difficult to track"
   (`MIGRATION.md:14-20`). ([§1](#1-packaging-and-the-line), [§7](#7-what-the-maintainers-call-mistakes))
2. **Ren hasn't said what row a log line or a span needs.** Effect
   makes `Clock`, `Random`, `Console`, `ConfigProvider`, `Tracer`, the
   loggers and the metric registry defaulted references, which never
   appear in a type (`src/Context.ts:344`). stdlib.md writes
   `log.info(...)` (stdlib.md:189) and the README `trace.span(...)`
   (README.md:974), but no doc says whether they need `uses`. Every
   function that logs depends on the answer. ([§3](#3-cross-cutting-services))
3. **A type's rules are a function no tool can read.** Effect's checks
   carry their meaning as data: `isMinLength(3)` gives the error text,
   the JSON Schema keyword and the generator's bound
   (`src/Schema.ts:8463-8495`). Ren's rules live in `parse`
   (stdlib.md:398-400), so the planned JSON Schema and OpenAPI
   (formats.md:1372-1375) will call an `Email` a string, and a generator
   for it must be written by hand (testing.md:274-281). ([§4](#4-data-and-schema))
4. **Test defaults are a privilege of the built-ins.** In Effect any
   library declares a defaulted service with the same `Context.Reference`
   std uses (`migration/services.md:201-221`). In Ren only the eight
   built-ins get a test implementation implicitly (deps.md:502-504), and
   language.md leaves out "default handlers beyond the built-ins"
   (language.md:826-829). So std's own `Http` and `Sql`, and a vendor's
   `Blob`, can't give tests a default. Decision 20's rule 2 says this
   should be a primitive anyone can use. ([§2](#2-services-and-layers))
5. **Conformance suites are needed, and Effect keeps its own private.**
   One `FileSystem` suite runs against Node and Deno, one `KeyValueStore`
   suite against memory, browser and Deno, and one persistence suite
   against every SQL driver. None is published, and no implementation
   anywhere fails on purpose. Ren's rule 2 is the version that works for
   vendors; Effect shows the suites appear anyway once there are four
   platforms. ([§1](#1-packaging-and-the-line))
6. **The world's surface lacks stdin and a process's output.** Effect's
   `Stdio` gives stdin as a byte stream (`src/Stdio.ts:1-10`), and its
   `ChildProcess` captures and streams output. Ren's `Console` writes
   lines and nothing reads stdin; `Proc.run` returns an exit code and
   "What it prints isn't captured" (deps.md:387-414). flottning's CLI
   will need both. ([§1](#1-packaging-and-the-line))
7. **Docs are checked like code.** Every public export has one doc
   template, a stability tag and a since-version, enforced by a checker,
   and examples run as tests (`.agents/skills/jsdocs/declarations.md:36-111`,
   `.agents/AGENTS.md:23-24`). This is a large part of the DX bar Ren's
   owner names. stdlib.md has no doc convention. ([§6](#6-api-conventions))
8. **Smaller ones.** A naming rule for implementations (Effect's
   `layer`, `layerTest`, `layerConfig`); stateful policies like rate
   limits written over a store dependency; whether `parse` may use a
   dependency; whether secure randomness is `Random`.
   ([§2](#2-services-and-layers), [§4](#4-data-and-schema), [§5](#5-streams-scopes-concurrency-errors))

Most of v3 to v4 is Effect moving toward what Ren already is: one
service mechanism, explicit wiring, no implicit conversions, a flat
error cause, one runtime. Those confirm Ren's design and are listed in
[§7](#7-what-the-maintainers-call-mistakes).

## 1. Packaging and the line

### What's in core

v4 merged `@effect/platform`, `@effect/rpc`, `@effect/cluster`,
`@effect/cli`, `@effect/ai`, `@effect/sql`, `@effect/workflow` and
`@effect/experimental` into `effect` (`CHANGELOG:1162`,
`MIGRATION.md:22-36`). What stays separate is "platform-specific,
provider-specific, or technology-specific": `@effect/platform-*`,
`@effect/sql-*` drivers, `@effect/ai-*` providers, `@effect/atom-*`
bindings, `@effect/opentelemetry`, `@effect/vitest` and tools
(`MIGRATION.md:28-36`, `README.md:56-94`). `effect` has no runtime
dependencies (`CHANGELOG:1165`).

So core holds every abstraction and every protocol written in Effect:
`http`, `http-api`, `rpc`, `sql` (the client interface), `socket`, `net`,
`process`, `persistence`, `cli`, `cluster`, `workflow`, `observability`
(OTLP), `encoding` (Base64, Hex, Toml, Yaml, Xml, Tar, Zip, Ndjson, Sse,
`SchemaBinary`) (`packages/effect/package.json:33-56`,
`packages/effect/src/encoding/`). Even the PostgreSQL client, now written
in Effect with no `pg` dependency, stays in `@effect/sql-pg`
(`CHANGELOG:1198`), because a driver is technology-specific.

Ren's split is close: std owns the interfaces and the protocols, written
in Ren (stdlib.md Part 5, Part 6). The difference is drivers: Ren puts
`postgres` and `sqlite` in std (stdlib.md:363-364), Effect never puts a
driver in core.

### Unstable, and what promotes it

Unstable modules live at the same paths as stable ones. Stability is a
`@stability stable | unstable | experimental` tag on every module and
every directly importable export (`CHANGELOG:890`, `MIGRATION.md:46-51`):
unstable may break in a minor release, experimental in a patch. The
unstable set is large: `ai`, `cli`, `cluster`, `devtools`, `eventlog`,
`http`, `http-api`, `jsonschema`, `observability`, `persistence`,
`process`, `reactivity`, `rpc`, `schema`, `socket`, `sql`, `workflow`,
`workers` (`MIGRATION.md:65-67`). Even `FileSystem` is unstable
(`src/FileSystem.ts:11`). Every module outside `effect` is unstable
(`MIGRATION.md:50-51`).

Two rules are worth copying:

- **"Moving these modules does not stabilize their APIs"**
  (`MIGRATION.md:69`). Location and stability are separate facts, so
  promotion is a tag change and no user edits an import.
- **An API that exposes a third-party dependency is unstable**, because
  that dependency's releases can change it: an accessor to the
  underlying client, options typed as the dependency's, re-exports
  (`MIGRATION.md:53-58`, `.agents/skills/jsdocs/declarations.md:105-111`).
  Ren's rule 3 (borrowed code computes, Ren owns effects) points the same
  way: a std API that shows a borrowed component's types is `std.x`.

What promotes a module isn't written down. The README says feedback
"shapes what we stabilize" (`README.md:40`). There's no stated test.

For Ren: `std.x/websocket` becoming `std/websocket` makes every user
edit an import, which is exactly what Effect removed. And separate
versions is what v3 had and v4 abandoned. A Ren shape that matches v4:
`std.x` ships with the toolchain at its version, under one path per
module that never moves; a module is marked `unstable` in its own
declaration, which `ren doc` shows and the compatibility promise exempts;
promotion removes the mark. stdlib.md's leaning (a release cycle with no
breaking change, plus a conformance suite) is a better promotion test
than anything Effect states, and fits either way.

### Abstract services, implemented per platform

Core declares the services; each platform package implements them.

| Service in core | Node | Bun | Deno | Browser | In core |
|---|---|---|---|---|---|
| `FileSystem` (`src/FileSystem.ts:486`) | yes | yes | yes | | `makeNoop`, `layerNoop` |
| `Path` (`src/Path.ts:270`) | yes | yes | yes | | posix `layer` (`src/Path.ts:926`) |
| `Stdio` (`src/Stdio.ts:111`) | yes | yes | yes | | `layerTest` (`src/Stdio.ts:166`) |
| `Terminal` (`src/Terminal.ts:173`) | yes | yes | yes | | |
| `Crypto` (`src/Crypto.ts:223`) | yes | yes | yes | yes | `TestCrypto` |
| `ChildProcessSpawner` (`src/process/`) | yes | yes | yes | | |
| `HttpClient`, `HttpServer`, `HttpPlatform` | yes | yes | yes | client | `FetchHttpClient`, `HttpApiTest` |
| `Socket`, `SocketServer`, `DatagramSocket`, `Dns`, `AddressResolver` | yes | yes | yes | socket | |
| `KeyValueStore` (`src/persistence/KeyValueStore.ts`) | | | yes | yes | `layerMemory`, `layerFileSystem`, `layerSql` (`:328`, `:366`, `:509`) |
| `Worker`, `WorkerRunner` | yes | yes | | yes | |

(`packages/platform/*/src/`.) A platform bundles the common ones:
`NodeServices` is `ChildProcessSpawner | Crypto | FileSystem | Path |
Stdio | Terminal` (`packages/platform/node/src/NodeServices.ts:34-52`).
The browser package adds services core doesn't know: `Clipboard`,
`Geolocation`, `Permissions`, `IndexedDb`. So Effect's world is open: a
platform package declares a new world service the way any user would.

How this maps to Ren:

- **Effect's services are Ren's world dependencies,** with one
  difference of level. Effect abstracts protocols per platform
  (`NodeHttpServer`, `BunHttpServer`, ...) because each JS runtime has
  its own HTTP stack. Ren abstracts at `Net` and writes HTTP once
  (stdlib.md Part 6). That's Go's choice, and it's why Ren's list can be
  closed and small (decision 20, rule 2).
- **Effect's `Path` is a service,** since path rules differ by platform.
  Ren's `path` is a pure module (stdlib.md:385), which is right for one
  set of targets and worth one sentence if Windows ever matters.
- **Effect splits `Console`, `Stdio` and `Terminal`.** `Console` is
  log-style printing, defaulted (`src/Console.ts:86`). `Stdio` is
  arguments, stdin as a byte stream, stdout and stderr as sinks
  (`src/Stdio.ts:1-10`). `Terminal` is interactive input. Ren has
  `Console` (lines out) and `Os.args()`; nothing reads stdin
  (deps.md:382-414). A CLI that reads a pipe needs it.
- **Effect's `ChildProcess` captures output and builds pipelines**
  (`ai-docs/src/60_child-process/`). Ren's `Proc.run` doesn't capture
  (deps.md:414).

### In-memory and test implementations

Effect ships some, unevenly:

- **In-memory:** `KeyValueStore.layerMemory`
  (`src/persistence/KeyValueStore.ts:328`), `Persistence.layerMemory`
  (`src/persistence/Persistence.ts:1181`), an in-memory `WorkflowEngine`
  (`src/workflow/WorkflowEngine.ts:2-7`), `HttpApiTest` for calling an
  API without a server (`CHANGELOG:1185`).
- **Stubs, not fakes:** `FileSystem.makeNoop` fails every operation with
  `NotFound` unless the test overrides it (`src/FileSystem.ts:654-779`).
  There's no in-memory file system. `Stdio.layerTest` takes a partial
  implementation (`src/Stdio.ts:166`). `Layer.mock` fills any service's
  missing members with "unimplemented" defects (`src/Layer.ts:2290-2354`).
- **Controlled:** `TestClock` (`src/testing/TestClock.ts`), moved by
  hand with `adjust`, with a warning when a test waits on time it never
  advances (`src/testing/TestClock.ts:8`, `:147-181`); `TestConsole`;
  `TestCrypto`, seeded random bytes that delegate digests to a real
  `Crypto` (`src/testing/TestCrypto.ts:1-10`).
- **No simulated implementations.** Nothing fails, reorders or delays
  on purpose.

Conformance suites exist, privately:

- `effect/test/FileSystem.test-utils.ts:19` exports `testLayer`, run by
  `packages/platform/node-shared/test/NodeFileSystem.test.ts:49` and
  `packages/platform/deno/test/DenoFileSystem.test.ts:11`.
- `effect/test/persistence/KeyValueStore.test.ts:7` is run against
  `layerMemory` (`:106`), the browser's localStorage
  (`packages/platform/browser/test/BrowserKeyValueStore.test.ts:11`) and
  Deno's (`packages/platform/deno/test/DenoKeyValueStore.test.ts:10-12`).
- `PersistedCacheTest.suite` runs against pg, mysql2, mssql and
  sqlite-node (`packages/sql/pg/test/Persistence.integration.test.ts:12`).

They're reached through a repo-only alias, `effect-test/*`
(`tsconfig.tests.json:112`), and the package publishes only `src`,
`dist` and docs (`packages/effect/package.json:72-81`). A third-party
driver can't run them.

For Ren: this is evidence for stdlib.md's rule 2 as written. Effect
needed shared suites the moment it had four platforms, wrote them
informally, and kept them where a vendor can't reach. Ren's `pub group`
that a vendor imports (stdlib.md:268-274) is the version that works for
everyone. Effect offers no model for the simulated third implementation;
that part is Ren's own.

## 2. Services and layers

### How a service is declared and provided

v4 has one way: `Context.Service`. It replaced `Context.Tag`,
`Context.GenericTag`, `Effect.Tag` and `Effect.Service`
(`migration/services.md:1-8`, `:223-235`).

```ts
class Database extends Context.Service<Database, {
  query(sql: string): Effect.Effect<Array<unknown>, DatabaseError>
}>()("myapp/db/Database") {
  static readonly layer = Layer.effect(Database, Effect.gen(function*() { ... }))
}
```

(`LLMS.md:133-170`.)

- **A key is a string,** and two services with the same string share a
  slot (`src/Context.ts:173-177`); the guide says to put the package path
  in it (`LLMS.md:141-143`). Ren's compiler knows a dependency by its
  type, so this can't happen.
- **`make` replaces v3's auto-generated `.Default` layer.** v4 stores the
  constructor on the class but builds no layer, and drops the
  `dependencies` option; you write `Layer.effect(this, this.make)` and
  `Layer.provide` its needs yourself (`migration/services.md:142-199`).
  This is Ren's `service` rule that what a service needs is met where
  it's installed (language.md §4, rule 2).
- **Accessors were removed** because a mapped type over the service
  erased generic methods and overloads (`migration/services.md:63-80`).
  Ren calls `Users.name(id)` directly, checked by the language, so it
  never had the problem.
- **`yield*` is preferred over `use`,** because `use` hides the
  dependency at the call site (`migration/services.md:126-140`). Ren's
  calls are always visible: `Clock.` in the call names it (deps.md,
  "Calling one").

A `Layer<ROut, E, RIn>` builds services, may fail, may hold scoped
resources, and composes with `provide`, `provideMerge`, `merge`,
`mergeAll`, `fresh`, `orDie` (`src/Layer.ts:1-12`, `:827-2207`).
`Layer.launch` runs a layer as the program (`src/Layer.ts:2255`).

### Memoization

v3 memoized within one `Effect.provide` call, so nested provides
silently built a layer twice. v4 reuses what an enclosing provide built,
while sibling provides still build their own; `Layer.fresh` and
`provide(..., { local: true })` opt out (`migration/layer-memoization.md:1-113`).
The guide still says to compose first and provide once
(`migration/layer-memoization.md:59-70`).

Ren's wiring is that advice made the only way: one `with` set, flattened,
one instance of each, with an error on a duplicate (language.md §5).
Ren left memoization by identity out on purpose (language.md:826) and
Effect's own history supports that: identity-based sharing needed a fix
in a major release and two escape hatches.

### Keyed families

`LayerMap` builds a service per key on demand and releases it after an
idle time (`src/LayerMap.ts:1-11`), over `RcMap`, which shares a
resource by key, counts its users by scope, and keeps it for an idle
TTL (`src/RcMap.ts:1-15`). A full `RcMap` fails a new key with
`ExceededCapacityError` rather than evicting (`src/RcMap.ts:9-11`).

Ren has this in the language: the runtime's keyed instance family, with
`actors` and `striped` over it (stdlib.md:376-378, decision 20). Ren
evicts (`evict: Lru`); Effect refuses. Both are policies; Ren's
`actors(max:, evict:)` already lets a program choose.

### Is std written with the users' mechanism?

Almost entirely. Clock, Random, Console, the tracer, loggers and config
are `Context.Reference` values (`src/Clock.ts:192`, `src/Random.ts:72`,
`src/Console.ts:86`, `src/Tracer.ts:662`, `src/ConfigProvider.ts:351`),
the same public constructor a user calls (`src/Context.ts:1366`). A user
can define a defaulted service: the guide uses it for configuration and
feature flags (`LLMS.md:172`).

The one exception is a performance knob. `Context.Service` takes
`fiberCached`, marked `@internal` (`src/Context.ts:213-215`, `:226-227`),
which keeps a key out of a context's cache root (`src/Context.ts:808-830`).
Only std uses it: `Tracer` (`src/Tracer.ts:663`), `ParentSpan`
(`src/Tracer.ts:178`), the scheduler references (`src/Scheduler.ts:83`,
`:295`, `:322`), the log level references (`src/internal/references.ts:17-58`).
It's what decision 20's rule 2 forbids: std made fast by a door users
can't open. It's small, and Ren should treat it as a warning: a fast
path std needs becomes a primitive or doesn't exist.

### Defaults, against Ren's

| | Effect | Ren |
|---|---|---|
| Who can declare a default | anyone, `Context.Reference` | only the built-ins (deps.md:502-504) |
| Default in production | yes: Clock, Random, Console, Tracer, loggers, config | no: a missing implementation is a compile error (deps.md rule 3) |
| Default in tests | `TestConsole` and `TestClock`, from `@effect/vitest`'s `it.effect` (`packages/vitest/src/internal/internal.ts:68`, `:490`) | test `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc` |
| Does the type show it | no: `Reference<S> extends Service<never, S>` (`src/Context.ts:344`) | yes: `uses Clock` |

Ren's production rule is stricter and better: an Effect's type can't say
it reads the clock, which is the fact simulation needs. Ren's test rule
is broader for the built-ins (it seeds `Random` from the test's name;
Effect's test environment doesn't touch `Random`). But it's closed:
`Http`, `Sql`, `Blob` and every vendor dependency need a `with` in every
test (deps.md:507-508).

The narrow change that keeps Ren's strictness: a `pub dep` may name a
test implementation, used only under `ren test` where nothing else
installs one. std's `Http` would name `mem_http`, and a vendor's `Blob`
its fake, by the same rule. That's what Ren already does for the
built-ins, made a primitive (rule 2), and it's not Flix's
`@DefaultHandler`, which language.md rejects because it applies in
production too.

### What Effect gets right that Ren might lack

- **`Layer.mock`:** a partial implementation whose missing operations
  fail loudly (`src/Layer.ts:2290-2354`). Ren has it as a library,
  `mock<D>()` over `call(c: D.Call)` (shapes.md:458-465). No gap.
- **Scoped resources in layers:** Ren's handler `finally`. No gap.
- **A naming rule for implementations.** v4 names the main layer
  `layer` and variants `layerTest`, `layerConfig`, `layerMemory`
  (`migration/services.md:196-199`). stdlib.md's examples mix `mem_fs`,
  `test_os`, `test_clock`, `Clock.frozen` and `sim.fs` (stdlib.md:258-264,
  deps.md:384-392). One stated rule, such as `mem_x` for in-memory,
  `sim.x` for simulated and `test_x` only for recording fakes, would let
  a user guess every implementation's name.

## 3. Cross-cutting services

### What's always installed

v3 had a `DefaultServices` bundle. v4 removed it: "Clock, Console,
Random, ConfigProvider, and Tracer are independent defaulted references"
(`migration/v3-to-v4.md:9745-9749`). Beside them, the loggers
(`src/internal/effect.ts:6577-6581`: a default logger and one that writes
log lines into the current span), the metric registry
(`src/Metric.ts:1665`), the scheduler (`src/Scheduler.ts:82`) and the
log and trace levels (`src/References.ts`). The justification is
availability: a reference "is available without explicit provision"
(`src/ConfigProvider.ts:317-320`, `src/References.ts:7-10`).

- **Logging:** `Effect.log` has no requirement
  (`src/Effect.ts:14144`), and log lines join the current span.
- **Tracing:** the default tracer makes in-memory spans and exports
  nothing (`src/Tracer.ts:662-680`); code can check for it and skip work
  only a backend would see. `Effect.fn("name")` wraps a function in a
  span and better stack traces (`src/Effect.ts:14042`), and
  `Effect.fnUntraced` is for "library implementations and hot paths"
  (`LLMS.md:14-16`, `:56-58`).
- **Metrics:** a default registry; OTLP and Prometheus exporters in
  `effect/observability`.
- **Config:** `ConfigProvider` defaults to the environment
  (`src/ConfigProvider.ts:351-354`); `Config` is built on `Schema` in v4
  (`src/Config.ts:11-28`, `Config.schema` at `:854`), with typed
  readers like `Config.Port`, `Config.Duration`, `Config.Redacted`
  (`src/Config.ts:979-1561`).
- **Clock:** v4 "separates wall-clock time from monotonic time"
  (`CHANGELOG:1173`), as Ren's `Time` and `Instant` do (stdlib.md:177-191).

### Against Ren's prelude and observability plan

Ren's prelude holds what the language names; the world's dependencies
are imported (module-build.md:238-253). Effect's defaults are the
opposite choice for the world, and Ren's is better for it: Ren's point
is that the compiler knows where the world comes in.

Observability is where the question is still open. Ren's plan is strong
on cost: every dependency call is already a span, events are fixed-size
records, nothing is compiled in when no recorder is installed, and logs,
traces and metrics are one stream (README.md:949-976, stdlib.md:383).
That's further than Effect, which has to tell library authors to opt out
of tracing by hand. But no doc says what a `log.info` or a
`trace.span` needs in its `uses`. `Log` isn't a world dependency
(decision 20's list), and `Console` is the only prelude dependency that
writes.

There are two answers:

1. **`uses Log`** on every function that logs. Exact, and noisy for a
   concern that crosses every layer; a request path's `service` absorbs
   it, but every helper below it repeats it.
2. **Events go to the trace stream, which the runtime owns, and need no
   row.** The journal is already in decision 20's runtime list. Writing
   an event isn't reaching the world; exporting it is, and the exporter
   is a handler installed at the root with its own `uses Net`
   (README.md:962-968). A log line is then deterministic and replayable,
   and the type still shows every world access. This is Effect's
   defaulted reference with the world access taken out.

The second keeps the ethos and matches Effect's DX. Either way it
belongs in stdlib.md's Observability paragraph, before stage 12's `log`.

## 4. Data and schema

### What `Schema` is in v4

A new implementation (`CHANGELOG:1178-1181`): class-based schemas,
`make` constructors on every schema, effectful decoding with services,
`SchemaRepresentation` for JSON Schema (Draft-04, Draft-07, 2020-12,
OpenAPI 3.0/3.1) import and export and TypeScript codegen, `SchemaBinary`
as cluster's default wire format, and optional JIT and AOT compilers
(`src/schema/SchemaJITCompiler.ts`, `src/schema/SchemaAOTCompiler.ts:1-7`,
both unstable). Its pieces:

- `SchemaAST` (5,356 lines), the schema as data; `SchemaGetter` and
  `SchemaTransformation`, the two sides of a `decodeTo`
  (`src/Schema.ts:5670`); `SchemaIssue` and `SchemaParser`, which
  replaced v3's `ParseResult` (`migration/v3-to-v4.md:363`).
- A codec tracks four types: `Codec<T, E, RD, RE>`, the decoded and
  encoded types and the services each direction needs
  (`src/Schema.ts:1074-1080`).
- Derivations: `toCodecJson`, `toCodecStringTree` (every leaf a string,
  for env, forms and query strings), `toCodecGoJson`, `toEquivalence`,
  `toFormatter`, `toJsonSchemaDocument`, `toRepresentation`, a JSON
  Patch differ, optics (`src/Schema.ts:16725-17161`), and `Arbitrary`,
  now native (`CHANGELOG:1174`).
- `Model.Class` derives `select`, `insert`, `update`, `json`,
  `jsonCreate` and `jsonUpdate` variants from one declaration
  (`src/schema/Model.ts:1-38`).
- RPC serialization is schema-aware (`CHANGELOG:1188`).

### How much is TypeScript's gap

A lot of Effect's data surface exists because the host language lacks
it:

| Effect | What it stands in for | Ren |
|---|---|---|
| `Data.Class`, `TaggedClass`, `TaggedError` (`src/Data.ts:1-10`) | sum types with value equality | ADTs, derived `==` |
| `Equal`, `Hash`, `byReference`; structural by default only from v4 (`migration/equality.md:1-38`) | derived equality and hashing | `==` and `hash` through `key`, never written (decision 20, rule 3) |
| `Brand`, `Newtype`, `Schema.brand`, `Schema.Opaque`: four ways (`src/Brand.ts:1-9`, `src/Newtype.ts:1-12`, `src/Schema.ts:5311`, `:6660`) | nominal and opaque types | `opaque` |
| string service keys (`src/Context.ts:173-177`) | knowing a dependency by its type | the compiler |
| `Schema.Class` with methods | a type's shape as a value | `T.shape` |
| JIT and AOT schema compilers | specialization at build time | release builds unroll the walk (shapes.md:180-183) |
| `Match`, `Option`, `Result` modules, `Effect.gen` | patterns, `try`, direct style | the language |
| 28 decode and encode variants: `Sync`, `Effect`, `Exit`, `Option`, `Promise`, `Result`, each with `Unknown` (`src/Schema.ts:1527-1875`, `src/SchemaParser.ts:270-566`) | one function whose signature says how it fails | `json.decode<T>` |

What isn't a gap but a real library: the walk's order, settings,
casing, strictness, codecs per medium. Ren already took those from
Effect (shapes.md:245-249, research/looks/).

### What Ren's shapes and looks don't cover yet

1. **Checks as data.** Effect's filter is a predicate plus what it
   means to every tool: an expected message, a representation id, a
   JSON Schema fragment, codegen and an arbitrary constraint
   (`src/Schema.ts:8463-8495`). Ren's `Email.parse` is code
   (stdlib.md:398-400). Today nothing in shapes.md lets a JSON Schema,
   OpenAPI or `ren explain` see "at least 3 characters" or "matches
   this pattern", and the derived generator can't hit valid values
   without a written `arbitrary` (testing.md:274-281). A small fix within
   decision 20: a std sum of common checks (length, range, pattern,
   one of) that a type can state as a value and that its `parse` is
   built from, so the door runs them and tools read them. Whether a
   type states it through a reserved name or a look is a question for
   shapes.md's open list.
2. **Decoding that needs a dependency.** `RD` and `RE` make it typed in
   Effect. shapes.md doesn't say whether `parse` may have `uses`. Say
   so either way: "no" keeps the doors pure and pushes lookups after
   decoding, which fits Ren.
3. **JSON Schema in, code out.** Effect imports JSON Schema and
   generates code (`CHANGELOG:1179`), and ships an OpenAPI generator
   (`README.md:93`). Ren plans export only (formats.md:1372-1375);
   import would generate code, which shapes.md keeps out
   (shapes.md:769-781). That's a tool, `ren gen`, not a language
   feature, and can wait.
4. **Two kinds of default.** Effect separates a constructor default from
   a decoding default (`src/Schema.ts:5940`, `:6126`). Ren has one,
   the constructor's, filled at the door (formats.md:274-275). One is
   simpler; Effect's split exists for wire formats that fill a field the
   constructor requires, which Ren's `via` covers.
5. **Model variants.** Ren's looks cover most of `Model.Class`: a
   `writes` look leaves out any field (formats.md:276-279), and left-out
   fields get their default coming in. An insert shape whose `id` the
   database assigns needs a separate type or a `via`. Worth a worked
   example in formats.md when SQL rows land.

## 5. Streams, scopes, concurrency, errors

| Effect | What it is | Ren |
|---|---|---|
| `Stream`, `Channel`, `Sink` (12k, 9k, 2k lines) | pull-based streams, built on `Pull` and `Cause.Done` in v4 (`src/Pull.ts:1-12`) | cursors, `gen fn`, lazy chains (streams.md); the language |
| `Sink` leftovers (`src/Sink.ts:1-11`) | a consumer that reads too much | a cursor stays where it stopped (stdlib.md:87-98) |
| `Scope`, `acquireRelease`, `Effect.scoped` | lifetimes for cleanup | `finally`, `with` |
| `Fiber`, `forkChild`, `forkDetach`, `forkScoped`, `forkIn` (`migration/forking.md`) | spawning | combinators, not spawn (concurrency.md) |
| `FiberSet`, `FiberMap`, `FiberHandle` (`src/FiberMap.ts:1-11`) | background work owned by a scope, by key | `Async.background`, the instance family |
| `Cause` with `Fail`, `Die`, `Interrupt` reasons | every way an effect ended | errors, panics, cancellation (errors.md, async.md) |
| typed recovery: `catch`, `catchTag`, `catchTags`, `catchIf`, `catchFilter`, `catchReason`, ... (`migration/error-handling.md:274-282`) | handling errors | `match`, `attempt`, `try`, `orelse` |
| STM, `Effect.tx`, `Tx*` (`CHANGELOG:1172`) | shared state without locks | handler state |

Std conveniences Ren gets from the language: structured concurrency,
typed errors, the requirements row, cleanup, ends-once, lazy pipelines,
pattern matching, and the cursor protocol.

Library abstractions Ren's std still needs, by Effect's inventory:

- **Already planned:** `schedule`, `retry`, `cache`, `channel`,
  semaphore, time stages (`batch(within:)`, `debounce`, `throttle`,
  streams.md:516-527), framing (`Net.frames`), resource families.
- **Not listed in stdlib.md:** in-process broadcast (`PubSub`), request
  batching and deduplication (`Request`, `RequestResolver`,
  `src/RequestResolver.ts:1-12`, DataLoader's idea), a circuit breaker
  (`src/persistence/CircuitBreaker.ts`). Each is a small library over
  the instance family or a dependency.
- **Rate limits over a store.** v4 removed the in-process rate limiter
  and kept one that takes its state from a store, memory or Redis, so
  the same code limits one process or many
  (`migration/v3-to-v4.md:722`, `src/persistence/RateLimiter.ts:1-12`).
  stdlib.md lists "a rate limiter" with no word on its state. Writing it
  over `Kv` follows Part 4's pattern.

Two error decisions worth noting:

- **v4 flattened `Cause`** from a tree of `Sequential` and `Parallel`
  to a flat list of reasons (`migration/cause.md:1-26`), and made every
  typed recovery skip a cause that holds a defect
  (`migration/error-handling.md:260-298`). In Ren a bug panics and isn't
  an error (errors.md rule 7), so this holds by construction.
- **v4 wraps a domain's failures in one tag with a `reason`:**
  `PlatformError { reason: BadArgument | SystemError }` with normalized
  `NotFound`, `PermissionDenied`, ... (`src/PlatformError.ts:79-90`,
  `:163-165`), `SqlError` reasons such as `UniqueViolation`
  (`CHANGELOG:1200`), and `catchReason` to handle one
  (`migration/error-handling.md:327-336`). It's how TypeScript avoids
  tag collisions. Ren's structural tags with domain names and named
  error sets (stdlib.md:236-254, `FsError` in deps.md) solve the same
  problem without nesting.

Randomness: Effect separates `Random`, a defaulted pseudo-random
generator (`src/Random.ts:1-12`), from `Crypto`, a required platform
service for secure bytes, UUIDs and digests (`src/Crypto.ts:1-11`).
Ren has one `Random`, whose real implementation is the OS
(deps.md:387), and lists a CSPRNG under crypto (stdlib.md:356). One is
fine if the real `Random` is always the OS's secure generator; stdlib.md
should say so, so no one writes a fast insecure one behind the same
name.

## 6. API conventions

### Module per type

One file per type or concept, named for it, imported as a namespace:
`Effect`, `Stream`, `Layer`, `Schema`, `HashMap` (`packages/effect/src/`).
Each has a module doc with `@stability` and `@since`. Area barrels
group them (`effect/http`, `effect/sql`), partly generated
(`.agents/AGENTS.md:44-46`). Ren's modules are files, and its types
carry their methods, so the same layout comes free.

### Names

- **Families by suffix:** `catch`, `catchTag`, `catchCause`,
  `catchDefect`; `decode`, `decodeEffect`, `decodeExit`; `fork*`.
  Renames in v4 shortened the common case (`catchAll` to `catch`,
  `migration/error-handling.md:166-183`) and made names say what
  happens (`fork` to `forkChild`, `forkDaemon` to `forkDetach`,
  `migration/forking.md:665-678`; `Scope.extend` to `Scope.provide`
  because it's providing a service, `migration/scope.md:1-12`).
- **`Unsafe` goes last:** `makeCookieUnsafe`, `serviceNameUnsafe`,
  "renamed to follow the v4 unsafe-suffix convention"
  (`migration/v3-to-v4.md:6221`, `:6619-6623`). Names sort by what they
  do, and the variant reads as a variant.
- **Layers:** `layer`, `layerTest`, `layerConfig` (§2).
- **Options inline,** a named type only when shared
  (`.agents/skills/effect-development/SKILL.md:201-221`).

### `dual` and `pipe`

Nearly every combinator is both data-first and data-last through
`dual`: 156 calls in `src/Stream.ts`, 78 in `src/Array.ts`. It costs
bugs and churn: `TxPriorityQueue.fromIterable(order)(iterable)` passed
its arguments in the wrong order in the data-last form only
(`CHANGELOG:1256`), and a release candidate still added missing
data-last forms (`CHANGELOG:1238`). language.md §8 already rejects
`dual` for a value-first `|>`. Effect's record supports that.

### Generators

`Effect.gen` with `yield*` is how Effect gets direct style; `Effect.fn`
adds a name, a span and stack traces. Ren's calls are direct, so it
needs neither. Ren's `gen fn` is for producers, which Effect does with
`Stream`.

### Documentation and examples

This is where Effect's DX is most deliberate, and copyable:

- **One template per public declaration:** a one-paragraph
  description starting with a present-tense verb, then optional
  `When to use`, `Details`, `Gotchas` in that order, then titled
  examples, then `@see`, `@stability`, `@category`, `@since`
  (`.agents/skills/jsdocs/declarations.md:36-111`,
  `.agents/skills/jsdocs/SKILL.md:23-29`). `When to use` must state a
  positive use case; `Gotchas` only concrete failure modes; `@see` only
  close alternatives or inverses (`declarations.md:129-133`).
- **A fixed vocabulary of categories:** `constructors`, `combinators`,
  `services`, `layers`, `errors`, `error handling`, ...
  (`.agents/skills/jsdocs/categories.md:1-24`), with stated boundaries
  ("services are contracts, tags identify services, and layers provide
  them").
- **Examples are tests.** A fence marked `ts import.meta.vitest` runs
  under `@effect/doctest`, with `// =>` assertions
  (`.agents/AGENTS.md:24`, `.agents/skills/jsdocs/examples.md:1-26`).
  Every example in `src/FileSystem.ts:640-786` is one.
- **Guides are typed programs:** `ai-docs/src/` holds numbered example
  files by topic, and `LLMS.md` is generated from them
  (`.agents/AGENTS.md:51-52`). Each topic answers "how do I" with code
  that compiles.
- **Checked:** `pnpm jsdocs --check` enforces all of it.

For Ren: `ren doc` should read a doc comment in a fixed form, show
`unstable` and `since`, and `ren test` should run doc examples whose
`// =>` lines are asserts. Writing that convention into stdlib.md Part 3
before stage 12 writes `json`, `http` and `log` costs little and is the
largest single piece of the DX bar.

## 7. What the maintainers call mistakes

v3 to v4 is the record. Each change, with the reason the guide gives:

| Changed | Why |
|---|---|
| packages merged into `effect`; one version for all (`MIGRATION.md:14-36`) | independent versions were "difficult to track" |
| `effect/unstable/*` paths removed (`CHANGELOG:1266`) | stability is a tag; moving doesn't stabilize |
| four service constructors became `Context.Service` (`migration/services.md:1-8`) | one mechanism |
| accessors removed (`migration/services.md:74-80`) | they erased generics and overloads |
| `Effect.Service`'s auto `.Default` and `dependencies` removed (`migration/services.md:171-194`) | wiring made explicit with `Layer.provide` |
| `FiberRef` became `Context.Reference` (`migration/fiberref.md:1-6`) | fiber-local state is a service with a default |
| `DefaultServices` bundle removed (`migration/v3-to-v4.md:9745-9749`) | each default is independent |
| `Runtime<R>` removed, `Context<R>` instead (`migration/runtime.md:1-10`) | one thing to run with |
| `Micro` removed (`migration/v3-to-v4.md:717`) | the rewritten runtime is small enough to be the only one |
| `Ref`, `Deferred`, `Fiber`, `Option`, `Either` no longer Effects (`migration/yieldable.md:1-12`, `:572-580`) | `Effect.all` over refs silently read them; conversions must be visible |
| `Either` became `Result` (`migration/v3-to-v4.md:689`) | naming |
| `Secret` became `Redacted<T>` (`migration/v3-to-v4.md:15520-15524`) | one generic wrapper |
| `Cause` flattened (`migration/cause.md:1-26`) | the tree's order wasn't useful |
| defects beat typed errors in every recovery operator (`migration/error-handling.md:260-298`) | v3 was inconsistent across operators |
| error mapping keeps the whole cause (`migration/error-handling.md:313-325`) | v3 mapped the first error and dropped the rest |
| layers shared across nested provides (`migration/layer-memoization.md:1-12`) | v3 built them twice, silently |
| keep-alive built into the core runtime (`migration/fiber-keep-alive.md`) | a waiting program exited without `runMain` |
| `Equal` structural by default, `NaN == NaN` (`migration/equality.md`) | reference equality surprised users |
| fast-check bridge replaced by native `Arbitrary` (`migration/v3-to-v4.md:692`) | a dependency removed |
| in-process `RateLimiter` dropped (`migration/v3-to-v4.md:722`) | the store-backed one replaces it |

The theme is fewer mechanisms, each explicit. Ren's design starts where
v4 ends on almost every row: one dependency mechanism with a type as its
identity, wiring as a set, no implicit conversions, one runtime per
program, panics apart from errors, derived structural equality.

### Bundle size and performance

- **Size:** the fiber runtime was rewritten for memory and speed; a
  minimal program is 7.1 kB minified and gzipped (`MIGRATION.md:71-75`,
  `CHANGELOG:1170`). Much of the changelog is tree-shaking work: tables
  built on first use (`CHANGELOG:1485`), `http-api` evaluating 5 MB of
  embedded assets at import (`CHANGELOG:293`), `Schema` pulled into a
  minimal router bundle as 23% of it (`CHANGELOG:2212`). There's a
  bundle-analysis skill for maintainers (`.agents/skills/bundle-analysis/`).
  Ren avoids the class of problem: the top level is build time and never
  runs at import (shapes.md:60-95).
- **Speed:** Schema needed opt-in JIT and AOT compilers; tracing cost is
  why `fnUntraced` exists; many changelog entries remove closures and
  allocations per step (`CHANGELOG:1260`, `CHANGELOG:1264`). Ren's
  answers are specialization in release builds and "zero cost when
  off" (README.md:956). Keep the second a hard rule, so no std author
  ever chooses between a traced and an untraced version.
- **Type checking:** "much faster type checking for large APIs" is a
  v4 headline for `HttpApi` (`CHANGELOG:1185`), and TypeScript 7 is
  recommended for performance (`README.md:19`). Effect's types do work
  Ren's compiler does directly.

## What Ren should take

- **One path per `std.x` module, forever; stability as a mark on the
  module; one version with the toolchain.** Promotion removes the mark.
  Changes stdlib.md rule 4 and its open question on `std.x` versioning;
  module-build.md "Packages" if `std.x` ships with the toolchain.
- **"An API that exposes a borrowed component's types is unstable."**
  One sentence in stdlib.md Part 6.
- **Decide what a log line and a span use.** Recommend: events go to the
  runtime's trace stream with no row; exporters are handlers at the root
  with their own `uses`. stdlib.md Part 5, Observability; decision 20's
  runtime list names the stream.
- **Checks a tool can read.** A std sum of common checks that a type's
  `parse` is built from and that JSON Schema, OpenAPI, `ren explain` and
  the derived generator read. shapes.md "Open questions", formats.md
  "Later" beside JSON Schema.
- **Test defaults as a primitive.** A `pub dep` may name the
  implementation tests get when nothing installs one; built-ins use the
  same rule. deps.md "Built in" and language.md §5 "Left out".
- **Conformance suites with the first fake.** Each in-memory
  implementation lands with its `pub group`, not at stage 13. stdlib.md
  Roadmap, stage 8.
- **Stdin and process output in the world's surface.** stdin as bytes
  (a cursor), and `Proc` with captured or streamed output. deps.md
  "Built in", decision 20's world list if it needs a new name.
- **A doc convention with doctests:** fixed sections, `since`,
  `unstable`, examples run by `ren test`. stdlib.md Part 3 Conventions;
  testing.md.
- **A naming rule for implementations** (`mem_x`, `sim.x`, `test_x`).
  stdlib.md Part 3, "Three implementations".
- **Rate limiter and circuit breaker over `Kv`.** stdlib.md Part 5,
  Concurrency and resilience.
- **Say whether `parse` may use a dependency,** and that the real
  `Random` is the OS's secure generator. shapes.md "The doors";
  stdlib.md Crypto.

## What Ren should not take

- **Defaults that hide the world from types.** Effect's `Clock`,
  `Random` and config are invisible in `R` (`src/Context.ts:344`).
  Ren's `uses Clock` is the point. deps.md stays as it is.
- **`dual`.** language.md §8 is right; Effect's changelog shows the cost.
- **Return-flavor variants** (`decodeSync`, `decodeExit`, ...). One
  function, whose errors are its signature.
- **Identity-based layer memoization and `provideMerge`.** language.md
  §5 already leaves them out; Effect needed a major release to fix
  sharing and two escape hatches to undo it.
- **Error reasons nested inside a wrapper tag.** Structural tags and
  named error sets already avoid collisions (stdlib.md Part 3).
- **String identities for services, and four ways to make an opaque
  type.** Both stand in for what Ren's compiler knows.
- **Protocols per platform.** Effect writes HTTP per JS runtime because
  it doesn't own I/O; Ren writes it once over `Net`.
- **An open world list.** Effect's platform packages add world services
  freely. Ren's closed list (decision 20, rule 2) is what makes
  simulation and replay complete.
- **A private std fast path** like `fiberCached`. If std needs it, it's
  a primitive.

## Sources

All under `/tmp/ren-refs/effect` (effect 4.0.6, commit `a461561`):
`README.md`, `MIGRATION.md`, `LLMS.md`, `migration/*.md`,
`.agents/AGENTS.md`, `.agents/skills/{jsdocs,effect-development}/`,
`packages/effect/package.json`, `packages/effect/CHANGELOG.md`,
`packages/effect/src/{Context,Layer,LayerMap,RcMap,Clock,Random,Console,Crypto,Stdio,Terminal,Path,FileSystem,PlatformError,Tracer,References,ConfigProvider,Config,Metric,Scheduler,Schema,SchemaParser,Data,Brand,Newtype,Equal,Stream,Pull,Channel,Sink,Scope,FiberMap,FiberSet,RequestResolver,Effect}.ts`,
`packages/effect/src/{testing,persistence,schema,encoding,net,socket,process,workflow}/`,
`packages/effect/src/internal/{effect,references}.ts`,
`packages/effect/test/{FileSystem.test-utils.ts,persistence/}`,
`packages/platform/{node,node-shared,bun,deno,browser}/{src,test}/`,
`packages/sql/pg/test/`, `packages/vitest/src/internal/internal.ts`,
`tsconfig.tests.json`. The v3 tree at `/tmp/ren-refs/effect-v3` was not
used.

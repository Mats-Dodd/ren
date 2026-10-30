# Effect v4 study: schemas, HttpApi, rpc, cli, and what Ren's looks take from them

Source: `/tmp/ren-refs/effect`, `packages/effect` 4.0.6 (commit of Oct 27 2026).
Effect v4 only. Nothing here reads or cites the v3 clone.

Files read: `SCHEMA.md`, `HTTPAPI.md`, `CONFIG.md`, `ARBITRARY.md`;
`src/Schema.ts`, `SchemaTransformation.ts`, `SchemaIssue.ts`,
`SchemaAST.ts` (union candidates), `Arbitrary.ts`;
`src/schema/SchemaAOTCompiler*`; `src/http-api/*` (Endpoint, Client);
`src/rpc/*` (Rpc, RpcGroup, RpcMessage, RpcSerialization, RpcServer,
RpcClient, RpcClientError); `src/encoding/SchemaBinary.ts`;
`src/cli/Flag.ts`, `Command.ts`; tests `test/rpc/RpcServer.test.ts`,
`test/rpc/RpcClient.test.ts`.

Two v4 facts that change the brief's vocabulary:

- v4 has no `Schema.transform` / `transformOrFail`. A transformation is a
  standalone value (`SchemaTransformation.transform`, `transformEffect`)
  attached with `Schema.decodeTo` / `encodeTo`.
- v4 has no `parseJson`, `fromKey` or `propertySignature`. They are
  `Schema.fromJsonString` and `Schema.encodeKeys`. There is no
  `TaggedRequest`; requests are `Rpc.make`. There is no msgpack
  serializer; the binary one is `SchemaBinary`.

---

## 1. Schema

### 1.1 One value, two sides

A schema is a runtime value with two phantom types. `Type` is the value
in your program. `Encoded` is how it looks outside. Decoding goes
Encoded to Type. Encoding goes back.

```ts
const schema = Schema.Struct({
  a: Schema.optionalKey(Schema.FiniteFromString),
  b: Schema.optional(Schema.FiniteFromString)
})
type Encoded = typeof schema.Encoded // { a?: string; b?: string | undefined }
type Type    = typeof schema.Type    // { a?: number; b?: number | undefined }
```

Every AST operation is symmetric. `encode(s) = decode(flip(s))`.
`Schema.flip` swaps the sides. So one interpreter does both directions.

A schema also carries `DecodingServices` and `EncodingServices`: the
services a transformation needs while it runs.

### 1.2 Transformations

A `Transformation<T, E>` is two `Getter`s: `decode: E -> T` and
`encode: T -> E`. Getters are tagged data (`Transform`,
`TransformOptional`, `TransformEffect`, `Passthrough`). They compose.

```ts
const NumberFromString = Schema.String.pipe(
  Schema.decodeTo(Schema.Number, SchemaTransformation.numberFromString))

const URLFromString = Schema.String.pipe(
  Schema.decodeTo(Schema.instanceOf(URL),
    SchemaTransformation.transformEffect({
      decode: (s, o) => Effect.try({ try: () => new URL(s),
        catch: () => new SchemaIssue.InvalidValue({ message: "Invalid URL string" }, s, o) }),
      encode: (url) => Effect.succeed(url.href)
    })))
```

Built-ins: `NumberFromString`, `FiniteFromString`, `DateFromString`,
`DateTimeUtcFromString`, `DateTimeUtcFromMillis`, `durationFromString`,
`optionFromNullOr`, `uint8ArrayFromBase64String`, `snakeToCamel`, and so
on. Each one is a named pair of functions.

`TransformOptional` sees `Option<E>`, so a transformation can see a
missing key and make one up, or drop one on the way out.

### 1.3 Classes, tags, errors

```ts
class Person extends Schema.TaggedClass<Person>()("Person", { name: Schema.String }) {}
class NotFound extends Schema.TaggedError<NotFound>()("NotFound", { path: Schema.String }) {}
program.pipe(Effect.catchTags({ NotFound: (e) => ... }))
```

`Class` gives a constructor that validates, methods, and equality.
`TaggedClass` adds `_tag`. `TaggedError` is a class that is also a
yieldable failure. `Schema.Opaque` makes a nominal type without a
prototype.

### 1.4 Brands and refinements

`Schema.brand("UserId")` is type-only. It adds nothing to the AST. The
docs say so: `SchemaRepresentation` drops it, and you must reapply it
after rebuilding a schema. Runtime checks are separate:
`.check(Schema.makeFilter(p))`, `Schema.isInt()`, `Brand.check`. A filter
can return a string as its message. Filters can report all issues or
abort early.

### 1.5 Optional fields and defaults

TypeScript has two kinds of "not there": key absent, and value
`undefined`. So Effect has `optionalKey` and `optional`, and four
decoding defaults:

| API | encoded side | default given as |
|---|---|---|
| `withDecodingDefaultKey` | key absent | Encoded |
| `withDecodingDefault` | absent or `undefined` | Encoded |
| `withDecodingDefaultTypeKey` | key absent | Type |
| `withDecodingDefaultType` | absent or `undefined` | Type |

Constructor defaults are a fifth thing: `withConstructorDefault(Effect)`,
run on each `make`. `Option` fields need their own family too:
`optionFromOptionalKey`, `optionFromNullOr`, `optionFromNullishOr`...

### 1.6 Renaming

```ts
Schema.Struct({ userId: Schema.FiniteFromString, accountName: Schema.String })
  .pipe(Schema.encodeKeys({ userId: "user_id", accountName: "account_name" }))
```

Only the encoded side changes. Unmapped keys stay. Unknown keys are
**ignored by default**; `onExcessProperty: "error"` makes it strict.

### 1.7 Tagged unions

```ts
Schema.TaggedUnion({ A: { a: Schema.String }, B: { b: Schema.Finite } })

// any union, any tag field:
const tagged = Schema.Union([
  Schema.Struct({ type: Schema.tag("A"), a: Schema.String }),
  Schema.Struct({ type: Schema.tag("B"), b: Schema.Finite })
]).pipe(Schema.toTaggedUnion("type"))
tagged.cases.A; tagged.guards.B; tagged.match({ A: ..., B: ... })
```

The default tag is `_tag` with the class name as written. `toTaggedUnion`
picks another field and rejects duplicate tags. The decoder builds a map
from literal tag value to candidate members (`SchemaAST.ts` ~3571), so a
union with a tag decodes with one lookup, not by trying each member.

### 1.8 Canonical codecs: the walk

This is the part closest to Ren's rule 1 and rule 3.
`Schema.toCodecJson(s)` walks the AST and returns a new schema whose
Encoded side is plain JSON. At each node:

1. An explicit encoding on the node wins (`encodeTo`, `decodeTo`).
2. Else a `toCodecJson` annotation on the type is used (the type's own
   JSON look).
3. Else the structure is walked.
4. A declared type with neither fails ("Expected JSON value").

```ts
const PointSchema = Schema.instanceOf(Point, {
  toCodecJson: () => Schema.link<Point>()(
    Schema.Tuple([Schema.Finite, Schema.Finite]),
    SchemaTransformation.transform({
      decode: (args) => new Point(...args),
      encode: (p) => [p.x, p.y] as const }))
})
```

The same annotation drives `toJsonSchemaDocument`, so the codec and the
JSON Schema never disagree.

There are siblings: `toCodecStringTree` (every leaf a string: used for
path, query and headers), `toCodecIso`, and `toCodecGoJson` (JSON plus
"a null array is `[]`" rules at every level). So one schema has several
derived looks, chosen by the caller. Settings that change the walk
globally (Go nulls) are a different function, not an annotation.

### 1.9 Errors with paths

`SchemaIssue.Issue` is a tagged tree. Leaves: `InvalidType`,
`InvalidValue`, `MissingKey`, `UnexpectedKey`, `Forbidden`, `OneOf`.
Inner nodes: `Filter`, `Encoding`, `Pointer` (adds a path step),
`Composite`, `AnyOf`. Formatters flatten it. The Standard Schema
formatter gives `{ issues: [{ message, path }] }`:

```
{ message: 'Expected a value with a length of at least 1', path: [ 'a' ] }
{ message: 'Missing key', path: [ 'c', 0 ] }
```

Rejected input is **not** kept unless you pass `reportInput: true`,
because it may hold secrets. Messages come from hooks you must supply,
so unused message code is not bundled.

### 1.10 One schema, many derivations

- `Schema.toJsonSchemaDocument(s)`: draft 2020-12. The docs admit it is
  only "preliminary validation"; the decoder is the authority.
- `Arbitrary.schema(s)`: a generator for the Type side, with shrinking.
- `Schema.toEquivalence(s)`, with a `toEquivalence` annotation for
  declared types.
- `Schema.toFormatter(s)` (pretty printing), `toDifferJsonPatch(s)`,
  optics.
- `Schema.toRepresentation(s)`: the schema as data (encoded side by
  default), persistable as JSON, rebuildable with revivers, and
  compilable to TypeScript code.
- `SchemaBinary.toCodec(s)`: a compact binary codec from the encoded
  side (see 3.4).

### 1.11 Speed: an interpreter, then JIT, then AOT

Schemas are interpreted by default. v4 adds a JIT
(`import "effect/schema/SchemaJITCompiler/enable"`) and an AOT compiler
(`SchemaAOTCompiler.compile([{ ast, operations: ["decode"] }])`) that
writes a module of specialized decoders. All three share one `WeakMap`
from AST to decoder. Transformations and middleware fall back to the
interpreter. AOT "removes dynamic source generation, not ... the need for
runtime schema objects". The benchmark table shows schema creation at
60 µs, where Valibot takes 1 µs.

### 1.12 Verdict on Schema

**DX gold**

- One description gives decode, encode, docs, generators, equality,
  diffing and binary. Change it once and all follow.
- The type's own JSON look (`toCodecJson` annotation) plus the walk
  for everything else. An explicit encoding on a field beats the type's
  default.
- Transformations are first-class values that compose and flip.
- Error trees with paths, all errors or first error, input not retained
  by default.
- Tag-field choice per union, and O(1) dispatch on the tag.

**Forced by TypeScript**

- Schemas are values because types vanish at runtime. Every type is
  written twice in effect: once as a schema, once inferred.
- `Encoded`/`Type` phantom pairs and `DecodingServices`/`EncodingServices`.
- `class X extends Schema.Class<X>("X")({...}) {}`: the self-type trick
  and a string identifier for docs.
- `_tag` fields, because JS has no sums.
- `optionalKey` vs `optional`, four decoding defaults, a constructor
  default, and an `Option` family: all because absent, `undefined` and
  `null` are three different things in JS.
- Brands that vanish at runtime.
- Metadata in annotations (`httpApiStatus`, `toCodecJson`,
  `identifier`), because there is no other place to hang it.
- A JIT and an AOT pass to win back speed lost to interpretation.

**What Ren gets for free**

- The type is the schema. `shape` is derived by the compiler like
  `show`, so there is nothing to write twice and nothing to keep in sync.
- Sums are native. The tag is the case name. A sum look renames it.
- One kind of absence: `Option`. A field default is the decoding default
  and the constructor default at once. Decision 5's rule (a left-out
  field needs a default or `Option`) replaces the whole table above.
- `parse`/`repr` are Effect's per-type `toCodecJson` annotation, but they
  are ordinary methods, found by the one walk rule.
- Release builds specialize every walk. That is Effect's AOT compiler,
  with no build plugin, no registry, and no fallback interpreter.
- Nominal types are real types, so a "brand" can't be lost.

---

## 2. HttpApi

### 2.1 Definition

```ts
const Api = HttpApi.make("MyApi").add(
  HttpApiGroup.make("Users").add(
    HttpApiEndpoint.get("getUser", "/user/:id", {
      params: { id: Schema.Int },
      query: { mode: Schema.Literals(["merge", "replace"]) },
      success: User,
      error: [UserNotFound, Unauthorized]
    })))

const UserNotFound = Schema.Struct({ _tag: Schema.tag("UserNotFound"), message: Schema.String })
  .pipe(HttpApiSchema.status(404))
// or, on a class: Schema.TaggedError<U>()("Unauthorized", {}, { httpApiStatus: 401 })
```

An endpoint has `params`, `query`, `headers`, `payload`, `success`,
`error`. Each can be fields or a full schema. `success` and `error` can be
lists. Each item can have its own status and encoding (`asJson`,
`asText`, `asFormUrlEncoded`, `asMultipart`, `asUint8Array`). A schema
that encodes to `Void` means "no content". The default error status is
500.

The endpoint picks the look by position. Path, query and headers go
through `toCodecStringTree`. Payload, success and error go through
`toCodecJson`. So you write `Schema.Int` for a path param and it is read
from a string. "Metadata lives on schemas" is a stated design principle:
the 404 is on the error type, not on the endpoint.

### 2.2 Server

```ts
const UsersLive = HttpApiBuilder.group(Api, "Users", (handlers) =>
  handlers.handleAll({
    getUser: (ctx) => ctx.params.id === 1
      ? Effect.fail(UserNotFound.make({ message: "User not found" }))
      : Effect.succeed({ id: ctx.params.id, name: "..." }),
    deleteUser: (ctx) => ...
  }))

HttpApiBuilder.layer(Api).pipe(Layer.provide(UsersLive), HttpRouter.serve,
  Layer.provide(NodeHttpServer.layer(createServer, { port: 3000 })))
```

The type checker forces one handler per endpoint. `ctx` holds decoded
`params`, `query`, `payload`, `headers`, and the raw request. A failure
whose type matches a declared error is encoded with that error's status.
Routing uses a find-my-way radix tree (`http/FindMyWay`).

### 2.3 Client, derived with full types

```ts
const client = yield* HttpApiClient.make(Api, { baseUrl: "http://localhost:3000" })
const user = yield* client.Users.getUser({ params: { id: 2 } })
```

The error channel is `UserNotFound | Unauthorized | HttpClientError |
SchemaError`. The client builds a map from status code to decoders
(`HttpApiClient.ts` ~978). A response is decoded by its status, then by
content type. An undeclared status is an error. So the server's error
union comes back typed on the client, with no codegen.

### 2.4 OpenAPI, middleware, security, streams

- `HttpApiScalar.layer(Api)` / `HttpApiSwagger.layer(Api)` serve docs at
  `/docs` from the same value. Annotations add titles and descriptions.
- Middleware is a service class with an `error` schema and an optional
  `provides` (for example `CurrentUser`). It is attached to an endpoint,
  a group or the whole API, and implemented as a Layer.
- Security (`bearer`, `basic`, `apiKey`) is declared on a middleware. It
  shows up in OpenAPI and is enforced by the middleware's Layer.
- Streams: `HttpApiSchema.StreamSse({ data, error })`, `StreamNdjson`,
  `StreamUint8Array`. A stream that fails after the status is sent sends
  its `Cause` as a reserved SSE event, and the client fails the stream
  with the same typed error. Streams can't be error responses.

### 2.5 Verdict on HttpApi

**DX gold**

- One value is server, client and docs. Rename an endpoint and both
  sides fail to compile.
- The client's error type is the server's error union. Status codes are
  decoded back to typed errors.
- Natural types in path params (`Schema.Int`), with the string look
  chosen by position.
- Handlers are checked exhaustive.

**Forced by TypeScript**

- The API is a value built with `.add(...)` chains, because there's no
  other way to name types at runtime. Endpoint names are strings
  (`"getUser"`) checked by `const` generics and large mapped types.
- Status on the schema by annotation: there is no separate place for an
  HTTP look of a type.
- Middleware `provides` a context service, so request data flows
  through a typed context bag.

**What Ren gets for free**

- The API *is* the dependency. `D.Call` is the endpoint list, written by
  the compiler. No group, no chain, no string names.
- The route table is a REST look of `D.Call`
  (`| Get as GET "/v1/keys/\{key}"`), apart from the type, as decision 2
  asks. Status codes can live in the same look of `D.Reply` and the error
  set, so nothing is put on the type.
- Path params go through the type's `parse` (decision 1: its parameter
  type is what gets read), so `Key.parse(String)` reads a path segment
  with no special string look.
- Handlers are checked exhaustive because a handler of `D` is already
  checked to cover `D`'s operations.

---

## 3. rpc

### 3.1 Definition and handlers

```ts
const Rpcs = RpcGroup.make(
  Rpc.make("Ping",   { success: Schema.String }),
  Rpc.make("GetUser",{ payload: { id: Schema.Int }, success: User, error: NotFound }),
  Rpc.make("Events", { payload: Schema.Struct({}), success: Schema.Number, stream: true }))

const Handlers = Rpcs.toLayer({
  Ping:    () => Effect.succeed("pong"),
  GetUser: ({ id }) => ...,
  Events:  () => Stream.fromEffectRepeat(...)
})
```

An `Rpc` is a tag plus `payload`, `success`, `error`, `defect`
schemas. `stream: true` wraps success and error in `RpcSchema.Stream`
and sets the call's own error to `Never`. `primaryKey` makes the payload
a class with a key (used for dedup in cluster). Groups `merge`, `omit`,
`prefix`, and take middleware.

### 3.2 Protocols and serialization are layers

```ts
RpcServer.layer(Rpcs).pipe(
  Layer.provide(Handlers),
  Layer.provide(RpcServer.layerProtocolHttp({ path: "/rpc" })),
  Layer.provide(RpcSerialization.layerNdjson))

const client = yield* RpcClient.make(Rpcs)   // needs RpcClient.Protocol
// RpcClient.layerProtocolHttp({ url, batch: { window: "5 millis" } })
yield* client.GetUser({ id: 1 })
```

Protocols: HTTP, WebSocket, socket server, stdio, worker. Serializations:
`json`, `ndjson`, `jsonRpc`, `ndJsonRpc`, and `layerSchemaBinary`. A
serialization is `{ contentType, includesFraming, makeUnsafe(): Parser,
codecFor(schema) }`. The envelope is framed by the parser and never sees
the schema. Only the "holes" (payloads, chunks, exits) go through
`codecFor`, which is `toCodecJson` for the JSON ones. The HTTP client
protocol can batch calls in a time window.

### 3.3 The wire

Client to server (`RpcMessage.ts`):

```
{"_tag":"Request","id":1,"tag":"GetUser","payload":{"id":1},"headers":[],"traceId"?:...}
Ack | Interrupt | Eof | Ping
```

Server to client:

```
{"_tag":"Chunk","requestId":1,"values":[...]}                 // stream items
{"_tag":"Exit","requestId":1,"exit":{"_tag":"Success","value":...}}
{"_tag":"Exit","requestId":1,"exit":{"_tag":"Failure","cause":[
   {"_tag":"Fail","error":...} | {"_tag":"Die","defect":...} | {"_tag":"Interrupt"} ]}}
```

So a request is a tagged sum of operations with arguments as fields,
plus an id. That is Ren's `D.Call`. A reply is an `Exit`: success, typed
failure, defect, or interrupt. Typed errors use the rpc's `error` schema.
Defects use a separate `defect` schema. Streams are `Chunk` messages,
with `Ack` for back pressure, ended by one `Exit`. Interrupts cross the
wire both ways, and a server fiber is finalized when the client goes
away (tested in `RpcServer.test.ts`).

### 3.4 Client errors and versions

Every client method's error channel gets `RpcClientError` added. Its
`reason` is a union: `WorkerErrorReason | SocketErrorReason |
HttpClientError | RpcClientDefect`. The handler's own type does not have
it. The client adds it.

There is no handshake or version check in the JSON serializations.
`SchemaBinary` has two modes. The default writes field ids so peers can
evolve. `fingerprint: true` writes positional layouts and puts an
**8-byte layout hash** on every frame, and rejects a mismatch. Arrays of
structs are written as row runs with shapes declared once and strings
back-referenced.

### 3.5 Verdict on rpc

**DX gold**

- Handlers as one record, checked against the group.
- Transport and serialization are swappable layers. The same group runs
  over HTTP, a socket, a worker or stdio, in tests with `RpcTest`.
- Streams, interrupts and back pressure across the wire with no extra
  API.
- Typed error vs defect vs interrupt, all three carried.
- The envelope is separate from the payload codec.

**Forced by TypeScript**

- Tags as strings, `payload` as fields or schema, `stream: true` as a
  flag that rewrites the success type.
- `RpcClientError` added by the client's type, because there is no way
  to say "this service may be remote" on the service.
- Fingerprint per frame, because there is no connect step where both
  sides agree once.

**What Ren gets for free**

- `D.Call`, `D.Reply` and `D.call(c)` are the RpcGroup, its messages and
  its dispatcher, written by the compiler from `D`'s signature.
- A transport is a dependency (decision 10), so swapping it is a handler,
  not a Layer graph.
- Serialization is a look or a layout chosen in settings, not a service.
- The closed world gives a shape hash at build time, so a connect-time
  check is one comparison.

---

## 4. cli and config

v4's cli is not derived from schemas. You build it from `Flag` and
`Argument` values:

```ts
const deploy = Command.make("deploy", {
  environment: Flag.String("env").pipe(Flag.withDescription("Target environment")),
  server: { host: Flag.String("host").pipe(Flag.withDefault("localhost")),
            port: Flag.Int("port").pipe(Flag.withDefault(3000)) },
  files: Argument.String("files").pipe(Argument.variadic),
  force: Flag.Boolean("force").pipe(Flag.withDefault(false))
}, (config) => ...)
```

Schemas come in at the leaves: `Flag.withSchema(EmailSchema)`,
`Flag.FileSchema("config", ConfigSchema, { format: "json" })`. Nested
records group flags. Subcommands use `Command.withSubcommands`. Flags can
fall back to config or to a prompt. Help and shell completions are
generated. There is no bridge from an `RpcGroup` or `HttpApi` to a CLI.

Config: `Config.schema(Schema.Struct({...}))` reads a struct from a
`ConfigProvider` (env, `.env`, a directory, a plain object), and decodes
strings like `"8080"` to `Int`. `ConfigProvider.constantCase` maps
`databaseHost` to `DATABASE_HOST`. Key casing is a property of the
source, not of the type.

**DX gold:** help and completions for free; a file flag decoded by a
schema; casing as a source setting; fallback chain flag, config, prompt.

**Forced by TypeScript:** each flag is a value with its name as a string.
The record type comes from the builder, not the reverse.

**What Ren gets for free:** `cli.parse<Keys.Call>(Os.args(), cmds)`. The
command sum is `Keys.Call`; its cases are subcommands and its fields are
flags. Renamed flags are a look (decision 8). Short flags and positionals
stay in `cli.spec` settings. A CLI that talks to the server is the same
`Call` sent through `http.client`.

---

## 5. Twelve lessons for Ren's looks and dep-as-protocol

1. **Keep the walk order Effect found.** `toCodecJson` uses: explicit
   encoding on the node, then the type's own annotation, then structure.
   That is Ren's decision 3 with one more level (the call's look). Effect
   fails at a declared type with no JSON look. Ren should fail at build
   time with the same message, naming the type and the path to it.

2. **Pick the look by position, not by annotation.** HttpApi reads path,
   query and headers with the string-tree look and bodies with JSON. In
   Ren, path segments and query values go through `parse(String)`, and
   bodies through the json look. Users write `Key`, never
   `KeyFromString`.

3. **A transformation is a pair of named functions.** Effect needed a
   `Transformation` object with getters. Ren's
   `format unix for Time = Int via (Time.from_unix, t => t.unix())` is the
   same thing in one line. Keep `via` to exactly two functions; let the
   decode side return a `Result` so it can fail with a message, as
   `transformEffect` does.

4. **One absence, one default.** Effect has `optionalKey`, `optional`,
   four decoding defaults, a constructor default and an `Option` family.
   Ren's rule (a field left out of a look needs a default or is `Option`)
   covers all of them. Don't add an "absent vs null" switch to the look.
   If a wire format sends `null` for missing (Go), make it a setting like
   `toCodecGoJson`, not a field mark.

5. **Strict by default is right, and it must cover key sets in docs
   too.** Effect ignores unknown keys by default and its JSON Schema says
   `additionalProperties: true` to match. Ren decodes strictly. Make the
   generated JSON Schema and OpenAPI say `additionalProperties: false`
   unless the settings say `unknown: Ignore`. Docs and decoder come from
   one walk, so they can't drift.

6. **The sum tag is a look decision, and dispatch on it is a table.**
   `toTaggedUnion("type")` picks the field. The decoder maps tag value to
   member in one lookup. Ren's `tag "type"` in a sum look, plus the
   perfect hash already planned for routes, should be used for every sum
   decode, not only routes.

7. **Errors are a tree with paths; input is not kept by default.**
   Copy `MissingKey`, `UnexpectedKey`, `InvalidType`, `InvalidValue`,
   `OneOf`, with a path made of field names and indexes. Paths should use
   the *look's* names (`customerId`), with the type's name alongside for
   the programmer. Don't keep the rejected input unless asked; it may be
   a secret.

8. **One description, many outputs, all from the walk.** JSON Schema,
   OpenAPI, generators (`Arbitrary.schema`), equality, pretty printing
   and binary codecs are all walks in Effect. In Ren they are libraries
   over `T.shape` seen through looks (decision 9). The REST look of
   `D.Call` plus the json looks of its fields is everything OpenAPI
   needs. Ship OpenAPI as a library, not a compiler feature.

9. **`D.Call` with an id is the request; `D.Reply` as an Exit is the
   answer.** Effect's wire is `{Request id tag payload}` and
   `{Exit requestId Success|Failure[Fail|Die|Interrupt]}`, plus `Chunk`,
   `Ack`, `Interrupt`, `Eof`, `Ping`. Ren's envelope should be a small
   fixed sum the std defines once. Keep three outcomes apart: the op's
   declared error, a defect (panic on the far side), and cancellation.
   Frame the envelope separately from the payload look, as
   `RpcSerialization` does, so json, ndjson and a binary layout are only
   different looks for the holes.

10. **`Unavailable` should carry a reason sum.** Effect adds
    `RpcClientError` to every remote call, with a reason union (transport,
    decode, protocol defect). Ren's decision, that remote deps declare
    `Unavailable` on every op, is more explicit and keeps one type for
    local and remote handlers. Borrow the reason: `Unavailable` should
    hold a std sum (`Refused | Timeout | Decode(path) | Protocol |
    Version`) so a caller can tell a down server from a version clash.

11. **Check the shape hash once, at connect.** `SchemaBinary`'s
    fingerprint mode puts an 8-byte hash on every frame because there's
    no handshake. Ren has a closed world, so the hash of
    `D.Call`/`D.Reply` as seen through the chosen look is known at build
    time. Send it once at connect. Map a mismatch to
    `Unavailable(Version)`. Use positional layouts after that. Evolution
    goes through named looks (`Keys.v1`, `Keys.v2`), and the server offers
    each look it was built with.

12. **Statuses, streams and auth live in the transport's look, not on
    types.** Effect puts `status(404)` on the error schema and security on
    middleware. Ren has no attributes on fields and no context bag. So
    the REST look of `Keys.Call` names routes; the REST look of the reply
    and error sets names statuses (`| NotFound as 404`); an op whose
    result is a stream gets chunked frames from the envelope (lesson 9);
    auth is an ordinary function around `http.expose` that passes the
    user as a block parameter. A typed failure after the stream started
    goes as a final envelope frame, as Effect's reserved SSE event does.

Two notes that are not lessons but matter:

- Effect's own numbers show the cost of schemas as values: 60 µs to
  build a schema, and a JIT and an AOT compiler added to win speed back.
  Ren's release specialization is the answer Effect is reaching for. It
  is worth saying so in the docs.
- Effect has no CLI from an API. `cli.parse<Keys.Call>` would be ahead
  of Effect, not behind it.

# Stage 12 candidate design: one small library for a CLI, a server and a storage engine

Draft for the judge, 2026-10-29. Inputs: `research-http.md` (cited as
H-L1..L12), `research-data.md` (D-L1..L8), `grounding.md` (G-§n, G-Qn
for its open questions, G-Cn for its contradictions), and the repo's
decided docs. Each area gives **Recommended** and one or two
**Alternatives**, and says what each choice traces to. Code is in
today's syntax plus the data stage (by-name variants, `let ... else`).

flottning isn't specified anywhere in the repo (G-§0). Section 9 assumes
one binary with three faces: the `flottning` CLI, `flottning serve` (an
HTTP API), and an embedded storage engine. **The first thing this stage
needs from the owner is a paragraph on flottning:** single node or
replicated, what data model, and whether the engine is its own (WAL plus
pages) or SQLite.

---

## 0. The rules

Every area below applies these rules. Nothing else is new.

1. **A type's shape is the only description.** json, cli, config, SQL
   rows, SQL holes and property-test generators all walk `T.shape`. You
   customize with **one settings record per call**, never per-field
   attributes (shapes.md; D-L1, from aeson's `Options` and Go v2's option
   values). A type that needs more is its own edge type, converted by hand.
2. **An opaque type's `parse` is the only validation hook.** Decoding
   from json, flags, env or a row calls it. Encoding writes the
   representation (D-L2; shapes.md "built by its `parse`").
3. **What the type says, the shape carries:** field names and types,
   `Option`, field defaults, and doc comments. Nothing else (§1.4).
4. **Errors become a transport's codes in one exhaustive `match` at the
   edge.** HTTP statuses, exit codes and json error bodies all work this
   way. No error type knows its own status (errors.md, exact `!` sets;
   H-L4).
5. **A function runs code, `over` wraps a dependency, a wiring
   installs.** Request middleware, `cli.run`, `trace.span` and
   `retry` are functions that run a block. Tracing, retries, limits and
   transactions on a dependency are handlers `over` it (handlers.md
   "Functions that run a block"; language.md §5; H-L3).
6. **Everything is bounded by default.** Every limit is a by-name
   parameter with a finite default and a tagged error when it's
   exceeded (built 11a by-name defaults; H-L5 from Roc's resource rule;
   D-L3).
7. **Every input is a dependency read.** Args, env, config files,
   requests and rows all come through `Os`, `Fs`, `Net` or `Sql`, so
   they're journaled, simulated and replayable. Borrowed engines such as
   SQLite get their I/O, clock and randomness from Ren (stdlib rule 3,
   made hard for `std`).
8. **A template literal is a typed value.** `p"... \{x}"` hands its
   parts and holes to `p`. It's never a string first (D-L6, where Java
   JEP 459 and Python PEP 750 converged).
9. **Observability is one event stream through dependencies.** Names
   and metric labels are static, and the cost when it's off is a branch
   or nothing (H-L10; README "one stream").

---

## 1. Shapes: the one mechanism

### 1.1 How a generic function gets `T.shape` (G-Q1)

**Recommended: `shape` joins the closed set of built-in requirements**
(language.md §3: `==`, ordering, `hash`, arithmetic, `zero`/`one`,
`show`). It's inferred, carried in schemes, and passed as a dictionary
in debug builds. Release builds specialize it away, exactly as `show` is
handled. A type with a function in it has no `shape`, as it has no `==`
(shapes.md).

```ren
pub fn decode<T>(text: Str, s: Settings = Settings {}) -> T ! JsonSyntax | JsonMismatch | JsonLimit =
  let doc = try parse(text, s)
  try shape.build<T>(try to_value(T.shape, doc, s))
```

A type that appears only in the result is fixed either by the expected
type, `let u: User = try json.decode(body)`, or by **explicit type
application**, `json.decode<User>(body)`. Both spellings already appear
in the docs. Explicit application is new syntax but small, and every
format call site needs it.

- Traces: language.md §3 (the set is closed, so adding to it is a
  decision, and this is that decision); compiler.md "Requirements"; the
  `shape` dictionary is the same mechanism that already serves `show`.
- Debug builds read the dictionary as they go. Release builds unroll it,
  per shapes.md "How it runs".

**Alternative A: shapes passed as values, `json.decode(User.shape, body)`.**
Nothing new goes into the requirement set. But `Shape` then needs a type
parameter, `Shape<User>`, so that the result is typed, and every caller
writes the type twice. It's explicit, but it's ceremony at every one of
thousands of call sites, and it gives nothing the inferred requirement
doesn't.

**Alternative B: inference only, with no explicit type application.**
Smallest syntax, but `json.decode` used inline as an argument, as in
`f(try json.decode(b))`, works only when `f` isn't generic. That will
fail often enough in handlers that a type annotation on a `let` becomes
the idiom anyway.

### 1.2 `Shape` and `Value`: what they are (shapes.md open; G-Q2, G-Q3)

**Recommended: two ordinary ADTs in `std.shape`, behind two typed doors.**

```ren
// import shape   (explicit: only format libraries import it)
pub type Shape =
  | Prim(kind: Prim)                      // Int, Float, Bool, Str, Bytes, Decimal, Time, Duration, Path
  | List(of: Shape)                       // Array<T>
  | Opt(of: Shape)                        // Option<T>
  | Dict(key: Shape, value: Shape)        // Map<K, V>
  | Record { name: Str, fields: Array<Field>, doc: Str }
  | Sum { name: Str, cases: Array<Case>, doc: Str }
  | Opaque { name: Str, repr: Shape }     // decoded by the type's `parse`, encoded by its representation
  | Ref(name: Str)                        // recursion: a named type already being described
pub type Field = { name: Str, shape: Shape, default: Option<Value>, doc: Str }
pub type Case  = { name: Str, fields: Array<Field>, doc: Str }

pub type Value =
  | VInt(Int) | VFloat(Float) | VBool(Bool) | VStr(Str) | VBytes(Bytes) | VDecimal(Decimal)
  | VNone | VSome(Value) | VList(Array<Value>) | VDict(Array<(Value, Value)>)
  | VRecord(Array<Value>)                 // in the shape's field order
  | VCase(index: Int, fields: Array<Value>)

pub fn view<T>(x: T) -> Value                                  // T: shape
pub fn build<T>(v: Value) -> T ! ShapeMismatch(at: Str, expected: Str) | ParseFailed(at: Str)
```

- **`Shape` and `Value` are data**, so a library writes its walk with a
  `match`. That's language.md §6's own call ("`Shape` and `Expr` become
  ADTs") and ML taste.
- **The only typed doors are `view<T>` and `build<T>`.** `build` checks
  the `Value` against `T.shape` and fails with a path. When a library
  built the `Value` by walking that same shape, the check can't fail.
  That's shapes.md's "a check that can't fail when the shape drove it",
  made concrete. Nothing else turns a `Value` into a typed value, so the
  dynamic part stays inside libraries.
- **`Value` is public but needs `import shape`.** That answers shapes.md's
  question ("public, or a module imported explicitly?") with both: a
  format author can name it, and an application that imports `shape` is
  visibly reaching for reflection.
- **How a shape reaches an opaque type's `parse` (G-Q3):** `build`
  calls it, not the library. `Opaque` carries no code. The compiler,
  which writes `build<T>` for a known `T`, calls `T.parse(repr)` where
  the shape says `Opaque`. In debug builds the dictionary for `T`
  carries a compiler-written entry for it, which is decision 3's one
  kind of stored code and is written by the compiler. A library can't
  build a `Money` that breaks its rule (shapes.md).
- **The canonical constructor (G-C13) is the `pub fn parse` from the
  representation.** An opaque type with none has no decodable shape,
  and the error comes at the call: "`Email` has no `pub fn parse(Str)`;
  decode a `Str` and call your constructor". Property-test generation
  keeps testing.md's rule (any `pub` constructor). The two don't
  conflict: decoding needs one way in, and generating wants every way
  in.
- **Field defaults and doc comments ride in `Field`** (§1.4).

**The cost bet.** Debug builds go text → `Value` → `T`, which is Go's
`encoding/json` with one tree. In release, `T.shape` is a constant, so
`build<User>(to_value(User.shape, doc))` specializes into straight-line
code with no `Value` boxes. That's complexity in the compiler,
shapes.md's promise, and stage 12 must **measure it**: `json.decode<T>`
on a 10-field record in release, against a hand-written cursor decoder,
with a target of 1.5× or less. If specialization can't remove the tree,
§2's release path is the fallback.

**Alternative A: a visitor (serde).** The library implements a reader
with one callback per leaf kind, and the compiler drives it in shape
order, so there's no `Value` tree in either build. It's faster in debug,
but each callback is a block whose type depends on the leaf, which
needs typing Ren doesn't have, and format authors write a protocol
instead of a `match`. It's harder to read and harder to write. Revisit
only if the measurement fails.

**Alternative B: the compiler writes each format.** json, cli and bin
are derived like `show`. That's fastest and has no `Value` at all, but it
breaks shapes.md goal 2, "written in Ren, by anyone", and the compiler
then grows with every format.

### 1.3 The journal and shapes (G-C3)

**Recommended: the journal stays the compiler's internal walk, and
replay matches by names, as handlers.md built it.** shapes.md's "the
journal is the first derived format; replay against a changed type
fails" is narrowed: a replay fails, naming the type, only where a
recorded value no longer fits by name. A removed field, a changed type,
or a missing case all fail. An added `Option` field or an added case
doesn't. That serves replaying production traffic against a new build
(handlers.md), which a hash comparison would forbid.
*Alternative:* store a hash of each shape and refuse any change. It's
simpler, but it blocks the README's "replay prod against the new build".

### 1.4 Per-field metadata, defaults and `secret` (G-Q4..Q6, G-C4)

**Recommended:**

- **Record field defaults are a language feature:** `type Cfg = { port:
  Int = 8080, region: Str }`. A default is a build-time value, computed
  like a top-level `let`. A construction may omit that field, and the
  shape carries the default as a `Value`. Traces: by-name parameters
  with defaults (built 11a). This is the same rule moved from
  parameters to fields, and stdlib.md already writes it.
- **Doc comments are part of the shape** (`Field.doc`, `Case.doc`).
  `cli` uses them for help, `config` for its errors, and OpenAPI or JSON
  Schema could use them later. That's clap's lesson without clap's
  attributes (D-L4).
- **Everything else is a settings record on the call**, checked against
  the shape. When the settings are a top-level `let`, which shapes.md
  says is computed while building, a wrong field name fails the build:

  ```ren
  let CLI = cli.spec<Cmd>(positional: ["path"], short: [("verbose", "v")])   // checked at build time
  ```

- **`Secret<T>` is an opaque prelude type**, not a type former. Its
  `show` is `<redacted>` and the journal records `<redacted>`
  (handlers.md left room for this). It has no encode, since it has no
  `view` for formats, so `json.encode` refuses at the call. It
  decodes like `T`, and `s.reveal()` gives the `T`. `config` reads
  secret fields through `Os.env_secret`, whose result the journal
  redacts at the source, and a replay hands back a placeholder.

**Alternative A: wrapper types for metadata** (`cli.Positional<T>`,
`config.EnvName<T, "X">`). Wrappers are checked by the type system, but
they leak a transport into the domain type, and a type shared by cli and
config then carries both. They're fine for edge-only types. Prefer
settings.
**Alternative B: `secret Str` as a type former** (handlers.md "Later"),
which reads more naturally. It's new syntax for what an opaque type
already does.

### 1.5 `f.uses`, the build budget, and how `call` is typed

- **`f.uses` is the inferred set** (shapes.md leans that way). For a
  `pub` function the inferred and declared sets are equal. For a private
  one the inferred set is what's true, and an architecture `assert` is
  about what's true. *Alternative:* the declared set only, which forces
  rows on private functions, against decision 5's inference.
- **The build budget is counted in interpreter steps, not wall time**
  (10⁹ per top-level value), so a build is reproducible on a slow
  machine (shapes.md: "the same journal gives the same binary"). A
  package raises it in `ren.toml`, not per module, so one place says
  how slow a build may be. *Alternative:* wall time, which is simpler to
  explain but flaky under load (memory: journal.t flakes under load).
- **How `call` is typed: defer it.** The built `over any` (opaque
  `call.args`, `call.forward()`) already covers `traced`, `retry<D>`,
  the recorder and `limit`. Only `mock<D>` and `rpc.client<D>` /
  `http.client<D>` need typed replies, and neither is on flottning's
  critical path (§3.7). **Update shapes.md to the built surface (G-C1)**:
  `call =>`, `call.forward()`, `sync.limit() over any`. On the two
  `retry`s (G-C9): `retry(n, on:) fn() => ...` runs a block, and
  `retry<D>(n) over D` wraps a dependency. Both stay, per rule 5.

---

## 2. json

**Recommended:**

```ren
json.decode<T>(input: Str | Bytes, s: json.Settings = {}) -> T
    ! JsonSyntax(at: Int, expected: Str) | JsonMismatch(at: Str, expected: Str, found: Str) | JsonLimit(what: Str, limit: Int)
json.encode(x: T, s = {}) -> Str
json.write(&out: Str, x: T, s = {})                 // appends in place (strings.md `+=`)
json.items<T>(r) -> gen of T ! ...                  // NDJSON or one top-level array, from a reader (streams.md)
type json.Json = Null | Bool(Bool) | Num(Decimal) | Str(Str) | Arr(Array<Json>) | Obj(Array<(Str, Json)>)
```

- **Settings, one record** (D-L1): `keys: Exact | Snake | Camel`,
  `sums: Tagged(field: "type") | External`, `unknown: Ignore | Reject`,
  `absent: NoneOnly | NoneOrNull`, `max_depth: 64`, `max_bytes:
  8.mb`, `max_number_digits: 100`. **There's no untagged sum
  encoding**, because it's serde's worst attribute: slow, ambiguous,
  and with no error path.
- **Strict at no cost** (D-L3, from simdjson and Go v2): matching is
  case-sensitive, and duplicate keys and invalid UTF-8 are rejected.
  Numbers go from their text to `Int` (range-checked) or `Decimal`, never
  through a float unless the field is `Float`. Objects decode to ordered
  pairs, never a hash with a fixed seed (aeson's hash flooding).
- **Error paths** are `JsonMismatch(at: "users[3].email", ...)`, as
  shapes.md says, and `JsonSyntax.at` is a byte offset into the input,
  per the offset rule in strings.md. The tags are domain-named, per
  stdlib.md's convention (§8.3).
- **Zero copy.** A `Str` field with no escapes in the input is a slice of
  it (decision 17: a slice is a value, one count on its root). An
  escaped string is unescaped into its own buffer. The setting `strings:
  Slice | Copy` defaults to `Slice`. A long-lived cache sets `Copy`,
  and debug builds' report of "roots kept alive by small slices"
  (decision 17) points at the call that should.
- **Encoding writes straight to the output, with no `Value` tree**
  (aeson's `toEncoding` lesson, D-L7). `Option` encodes `None` by
  omitting the field. `Secret` doesn't encode. Map keys must have the
  shape `Str`, an opaque over `Str`, or `Int`.
- **Dynamic JSON** is `json.Json`, an ordinary ADT, which decodes like any
  type. It's the type for "I don't know the schema".
- **Streaming** is `json.items<T>(reader)`, a `gen fn` over streams.md's
  readers. Its errors are at stream offsets, like streams.md program 07.
  It waits on 11c generators, and until then `json.decode` on a whole
  body suffices.
- **Release decoding is shape-directed** (simdjson On-Demand, D-L7). The
  specialized `decode<User>` scans fields in shape order, and rescans
  only when the input's order differs.

**Alternative A: Elm-style combinators as the primary API.** It's
explicit, but D-§1 shows that every ecosystem without derivation ends up
asking for it, and it contradicts shapes.md. It's still possible as
plain Ren over `json.Json`.
**Alternative B: tree first, typed second (`parse` then `from_doc`),
exposed to users.** That's shapes.md's sketch as written. It's simpler to
build, but it makes the slow path the API. Keep it as the debug
implementation behind the same `decode<T>`.

---

## 3. http

### 3.1 The server: a block, not a dependency or a table

**Recommended:**

```ren
pub fn serve(addr: Addr, handle: fn(req: Request) -> Response,
             max_conns: Int = 10_000, header_limit: Int = 16.kb, body_limit: Int = 2.mb,
             read_header_timeout: Duration = 10.s, idle_timeout: Duration = 60.s,
             until: Signal = Signal.term, drain: Duration = 5.s, isolate: Bool = true)
    ! AddrInUse(addr: Addr) uses Net, Async, Log
```

- **`handle` is a block** (stdlib.md, H-L1), so the routes' `uses` flow
  to `serve`'s caller (decision 5). The compiler knows everything the
  whole server touches, which Effect needs `Request.From<"Requires">`
  for.
- **It isn't a dependency.** "Do you hold it, or are you given it?"
  (language.md §1): a server is a function you call from `main`, inside
  a `with`. `with live(cfg) in http.serve(...)` is init, run and
  shutdown, as Roc's `{init!, respond!, shutdown!}` falls out of `with`
  plus `finally` (H-L6).
- **Limits are by-name parameters with finite defaults** (rule 6). Going
  over one is a tag mapped to 413, 431 or 408 inside `serve`.
- **`isolate: true`** runs each request in `Async.isolate`, so a panic
  becomes a 500 for that request and a log event. Tests pass `false` to
  fail fast. This qualifies decision 8 ("a panic ends the program")
  only through the existing `isolate` mechanism.

### 3.2 Routing: a `match` (resolves G-C2)

**Recommended: routing is a `match` on `(req.method, req.segments())`,
with no router in 1.0** (H-L2, wisp):

```ren
fn routes(req: Request) -> Response ! NotFound | Invalid | Conflict | BodyTooLarge(limit: Int) | JsonMismatch(..)
    uses Store =
  match (req.method, req.segments())
    (Get,  ["v1", "keys", k]) => json_ok(try Store.get(try Key.parse(k)))
    (Put,  ["v1", "keys", k]) => put_key(try Key.parse(k), try req.bytes())
    (Post, ["v1", "batch"])   => json_ok(try Store.apply(try json.decode<Batch>(try req.bytes())))
    (_,    ["v1", "keys", _]) => method_not_allowed(allow: [Get, Put])
    _                         => not_found()
```

- **Exhaustiveness and redundancy are checked by the compiler,** which
  is what Go 1.22 and Roc check at startup with a panic.
- **The compiler names each arm** (`GET /v1/keys/{k}`) as static
  metadata for the server span and the metric label. That solves the
  cardinality problem by construction (Go 1.23's `Request.Pattern`).
  It's complexity in the compiler, H-open-5.
- A `match` on string lists compiles to a trie, which is work for the
  compiler, not a DSL.
- **shapes.md's `let ROUTES: Router = router([get("/users/:id",
  show_user)])` is removed:** it stores functions in a top-level value,
  which shapes.md and decision 1 both forbid.

**Alternative A: language.md §6's generic route table,** `serve<R>(routes:
Array<R>, handle: fn(R, Request) -> Response)`. The user owns a `Route`
enum, and patterns are data, `[(Get, "/users/{id}", GetUser)]`. Patterns
then live as data a tool can list (OpenAPI, `ren explain`), but mapping
a pattern to a constructor with arguments needs either functions in the
table or shape-driven construction (`GetUser(id: UserId)` built from the
captured `{id}` through `shape.build`). That's elegant, and it's a good
**12b+ addition on top of the `match`**, not instead of it.
**Alternative B: a table of descriptions,** `Array<(Str, Route)>` with
`dep Route` (foundations decision 3's own example). It's for a library
that takes kinds from others, such as a plugin host, static-file
mounts or an admin console. It's legal today, so std doesn't need to
ship it.

### 3.3 Request and response

```ren
type Request  = { method: Method, target: Target, headers: Headers, body: Body, peer: Addr }
type Target   = { path: Str, query: Array<(Str, Str)> }           // decoded, ordered; segments() splits path
type Method   = Get | Head | Post | Put | Patch | Delete | Options | Other(Str)
type Headers  = opaque Array<(Str, Str)>                          // ordered; case-insensitive get
type Body     = opaque Conn                                       // read once; bounded by body_limit
type Response = { status: Status, headers: Headers, body: Out }
type Out      = Empty | Bytes(Bytes) | Text(Str) | File { path: Path, range: Option<Range> } | Sent
```

- **The response is a value** (H-L1: Dream, wisp, axum, Roc). There's
  no `ResponseWriter`, so Go's "superfluous WriteHeader" and lost
  `Flusher` can't happen.
- **The request body is a cursor over the connection** (stdlib.md). It
  has `req.bytes()`, `req.text()` and `req.chunks()`, each failing with
  `BodyTooLarge(limit)` past `body_limit`.
- **A streaming response is a function that runs a block, and it gives
  back the `Sent` token** (H-open-1):

  ```ren
  (Get, ["v1", "watch"]) => http.stream(req, Ok, sse_headers()) fn(&out) =>
    for ev in try Store.watch()
      try &out.send(sse(ev))
  ```

  `http.stream` writes the head, runs the block, and returns
  `Response { body: Sent }`. `Out.Sent` can't be built any other way,
  because its constructor is private to `http`, so the handler still
  returns exactly one response. Blocks only go down (decision 1). A
  *pure* stream, a value cursor from a pure `gen fn` (decision 12),
  could later be stored in `Out` directly.
- *Alternative:* `Out.Stream` holding a description of a producer
  handler (decision 3). That keeps a value, but every SSE endpoint then
  becomes a handler declaration. It's heavier for the common case.

### 3.4 Middleware

**Recommended (rule 5; H-L3; changes stdlib.md's "Middleware is
`with`"):**

- **Request middleware is a function that runs the rest as a block**:
  `http.cors`, `http.request_id`, `http.head`, `http.compress`,
  `http.security_headers`, plus the user's own `auth.require`.
  **Request-scoped data is a block parameter**, so there's no context
  bag:

  ```ren
  http.serve(cfg.addr) fn(req) =>
    http.request_id(req) fn(req) =>
      auth.require(req, cfg.tokens) fn(req, who) =>      // 401 returns early
        respond(req, who)
  ```

- **World middleware is `over`**, on the dependency: `with traced() over
  Store`, `retry<Http>(3)`, `sync.limit(64) over Sql` and caches. These
  are the built `over any` (handlers.md).

**Alternative: install request-scoped data as a dependency per request**
(`with as_user(who) in respond(req)`, with a `CurrentUser` dep). It's
typed, and it's Effect's "middleware provides a service". But a user
is data you hold, not a service you're given (language.md §1's test),
and it would make each request install a handler.

### 3.5 Errors to statuses

**Recommended: one exhaustive `match` at the edge** (rule 4; H-L4):

```ren
fn respond(req: Request, who: Who) -> Response uses Store, Log =
  match routes(req, who)
    resp                      => resp
    fail NotFound             => status(404)
    fail Invalid | JsonMismatch(..) as e => problem(422, e)    // body: {"error": "...", "at": "..."}
    fail Conflict             => status(409)
    fail StoreFull            => status(507)
```

- A new tag deep in the call graph breaks this `match`'s compilation.
  No surveyed framework does that.
- `http.status_of(tag)` gives the default mapping for the prelude's common
  words (`NotFound`, `Invalid`, `Conflict`, `Forbidden`, `Timeout`), as an
  explicit call in a catch-all arm.
- *Alternative:* a reserved member `status()` on error payloads
  (axum's `IntoResponse`, Effect's `Respondable`). But tags aren't
  values and have no home (errors.md), and the domain would learn about
  transport, which is a DDD smell.

### 3.6 Client

**Recommended: `Http` is a `dep`.** A status is data, and nothing retries
behind your back (H-L9, Roc):

```ren
dep Http = send: fn(req: Request, timeout: Duration = 30.s, max_body: Int = 10.mb) -> Response
    ! Timeout | ConnRefused(addr: Addr) | DnsFailed(host: Str) | BodyTooLarge(limit: Int) | HttpProtocol(at: Int)
let resp = try Http.send(Request.get(url))
let body = try resp.ok()                         // ! HttpStatus(code: Int): the one explicit step
let n = try retry(3, on: Timeout | ConnRefused) fn() => try fetch(url)
```

- The implementations are `http.client(pool: ...)`, where the pool is
  handler state, plus `sim.http(seed, ...)` and a conformance group
  `http.client_conforms` (stdlib rule 2).
- **`mem_http(routes)` as written in stdlib.md can't exist**, because a
  handler's parameters are data and `routes` is a block (handlers.md).
  In-process tests call `routes(req)` directly (§3.8). A client test
  runs `serve` and the client in sibling tasks under `sim.net`.
- It needs `Net.connect` and DNS, owned by Ren for determinism (G-Q24).
  TLS waits for stage 13 (stdlib roadmap). For flottning's 1.0, an
  operator terminates TLS at a proxy, and the CLI talks plain HTTP over
  a Unix socket or localhost.

### 3.7 A typed contract: defer

**Recommended: not in stage 12.** `http.client<D>` and `http.expose<D>`
(H-L8, the most unified idea: a remote service is a dep whose handler
lives elsewhere) need `call` typing (§1.5). flottning's CLI and server
share an `api` module of request and response types, and write a
ten-line client function per endpoint over `Http.send` and `json`.
*Alternative:* settle `call` typing in stage 12 and ship `http.client<D>`.
That's the bigger win if the owner wants it, at the cost of an
unscheduled type-system piece.

### 3.8 Shutdown and testing

- **Shutdown** (H-L6): `until:` flips `/healthz/ready` to unready, then
  stops accepting via the built `accept_until`. Idle keep-alive
  connections are closed, requests in flight get `Connection: close` and
  `drain`, and anything still running is then cancelled. Their
  `finally` runs, and cancelling isn't rolling back. Then `serve`
  returns and the wiring's `finally`s run in reverse order (language.md
  §5): flush the WAL, fsync, close.
- **Testing** happens on three levels, all already possible:
  1. **In process:** `routes(Request.get("/v1/keys/a"))` under
     `mem_store()`.
  2. **Over a simulated socket:** `with sim.net(seed) in` run `serve` and
     the client in one `Async.scope`. It's deterministic and has faults
     once `sim.net` gets partitions and resets (G-Q24). No surveyed
     framework has this, and flottning's 10,000 seeds rest on it.
  3. **Replay:** for stage 12 the journal stays at the `Net` level, which
     is built and exact. *Alternative:* journal at the `Http` level
     (`GET /v1/keys/a → 200`, small and readable), which `ren trace pull
     --request` needs. Add it when the flight recorder lands (README
     stage 17).
- **Scope:** HTTP/1.1 with keep-alive, chunked transfer and SSE. HTTP/2
  and TLS come in stage 13. The *types* and the `serve`/`send`
  signatures are frozen first. The parser is an engine and can change
  (H-L11: Plug outlived cowboy).

---

## 4. cli

**Recommended: the command is an ADT, derived through shapes.**

```ren
/// flottning: a small replicated key-value store
type Cmd =
  /// Run the server
  | Serve(cfg: Cfg)
  /// Read a key
  | Get { key: Key, addr: Addr = Addr.local(7400), json: Bool = false }
  /// Check the data directory's pages and checksums
  | Verify { dir: Path, repair: Bool = false }

let CLI = cli.spec<Cmd>(positional: ["key", "dir"], short: [("json", "j")])

pub fn main() uses Os, Console, Fs, Net, Async, Clock =
  cli.run(CLI) fn(cmd) =>
    match cmd
      Serve(cfg) => try with live(cfg) in serve_api(cfg)
      Get { key, addr, json } => print_value(try client.get(addr, key), json)
      Verify { dir, repair } => try engine.verify(dir, repair)
```

- **The mapping** (D-L4, clap and Typer): a sum gives subcommands, case
  names become kebab-case, and a record payload gives flags. `Bool` is
  a switch, `Option` is optional, `Array` repeats, a payload-free sum is
  a closed choice, an opaque type goes through its `parse`, and a field
  default is the flag's default. A nested sum is a nested subcommand.
  **Help comes from doc comments** (§1.4). **Positionals and short
  flags come from the spec**, a top-level `let`, so a misspelled name
  fails the build.
- **`cli.run` is a function that runs a block** (rule 5). It handles
  `--help` (prints, exits 0), `--version`, and usage errors (prints
  `CliUsage(at, message)` with "did you mean `--json`?", exits 2), then
  runs the block on the command. `cli.parse<T>(spec, args) -> Parsed<T>
  ! CliUsage(..)`, with `Parsed<T> = Run(T) | Help(text: Str)`, is the
  same thing as a value, for tests.
- **Exit codes follow rule 4.** The application maps its own tags to
  codes in one `match` and calls `Os.exit(code)`. Today's default (an
  uncaught failure of `main` prints and exits 1, errors.md) stays, and
  usage is 2.
- **Arguments are bytes underneath.** `cli` reads `Os.raw_args()` and
  decodes `Path` fields without UTF-8 (strings.md: `Path` is `opaque
  Bytes`, `ArgNotUtf8(index)`).
- **Output:** a command's result type is shown for humans (`show` and
  `fmt` alignment, colours when `Console.is_tty()`), and with `--json`
  it goes through `json.encode` of **the same value**. Progress goes to
  stderr only on a TTY. Completions are derived from the same shape,
  and can come in 12b or later.
- **Tests** run `main` with `test_os(["get", "a", "--json"])`, captured
  `Console` and `mem_fs` (built), and compare the output with a golden
  file.

**Alternative A: derive from `main`'s by-name parameters** (Typer):
`fn main(port: Int = 8080, verbose: Bool = false)`. Defaults are already
built for parameters, so it's very natural for single-command tools. It
needs the shape of a function's parameters (`f.shape`, new), and
subcommands become several functions or fall back to an ADT anyway.
It's worth adding later as sugar over the ADT form.
**Alternative B: a combinator or builder API** (Go `flag`, cobra), for
CLIs whose commands are only known at run time. It's explicit but
stringly-typed (cobra's `init()` globals). Ship it only as a
`cli.Args` low-level cursor that the derived parser is written on.

---

## 5. config

**Recommended: layers are a list of sources, and one derivation reads
them** (figment, not Viper; D-L5):

```ren
type Cfg = {
  /// Address the API listens on
  addr: Addr = Addr.any(7400),
  /// Data directory
  dir: Path,
  sync: SyncMode = Group(window: 2.ms),
  admin_token: Secret<Str>,
}

let cfg: Cfg = try config.load([Defaults, File("flottning.json"), Env(prefix: "FLOTT_"), Flags(rest)])
// ! ConfigMissing(field: Str) | ConfigMismatch(field: Str, from: Source, expected: Str, found: Str) | NoSuchFile(..)
```

- **Precedence is the list's order, and a later source wins.** The
  sources are an ADT (`Defaults | File(Path) | Env(prefix) | Flags(args)
  | Value(T)`), which is data, so a program can see its own layering
  (language.md §6, "the standard library's own knobs are ADTs").
- **Provenance:** every value remembers its source, so errors say "`sync`
  from env `FLOTT_SYNC`: expected `Group` or `Every`, found `fsync`".
- **Names come from the shape:** `dir` is `--dir` (the same mapping
  cli uses, so one type serves flags and env) and `FLOTT_DIR`. A nested
  record `db.url` is `FLOTT_DB__URL`.
- **Every read is a dependency read** (rule 7). `Fs.read` and
  `Os.env_secret` are journaled and redacted, so a replay reproduces the
  config exactly.
- **Config is data, passed to wiring parameters** (language.md §5:
  "parameters carry config"): `with live(cfg) in`. It's never a `Config`
  dependency read anywhere.
- **The file format in 12 is json.** The `File` source picks its parser
  by extension, so `toml` is one more case when it lands (the toolchain
  needs it for `ren.toml`, stdlib.md's toolchain test). Adding a minimal
  toml in stage 12 is cheap if the owner wants one.
- There's no hot reload. A service that wants it re-runs `config.load`
  itself.

**Alternative A: env only, 12-factor** (stdlib.md's snippet). It's the
smallest, but it fails flottning's CLI, which wants a file plus flags.
**Alternative B: `Config<T>` as a dependency** that code reads anywhere.
That's convenient, but it's Viper's global with a type: config is held,
not given (language.md §1).

---

## 6. sql

### 6.1 Interpolation that libraries take (stdlib.md and strings.md open question; G-Q11)

**Recommended: `p"... \{x} ..."` calls `p.template(t: Template)`, where
`p` is a module or type in scope.**

```ren
pub type Template = { parts: Array<Str>, holes: Array<Hole>, site: SiteId }
pub type Hole = { value: shape.Value, shape: shape.Shape, source: Str }   // source: the hole's expression text

let q = sql"select id, name from users where plan = \{plan} and created > \{since}"
// is sql.template(Template { parts: ["select ... plan = ", " and created > ", ""], holes: [...], site: ... })
```

- **`template` is a reserved member name**, like `parse`, `key`, `show` and
  `arbitrary` (testing.md), and its owner is found by name, as Scala
  finds its interpolators. It's explicit: `sql` has to be in scope.
- **Holes carry their `Value` and `Shape`** (§1.2), so any type with a
  shape can be bound, and `sql` can refuse a shape it can't bind with
  a tagged error.
- **A build-time check is the library's choice:** if `p` also has `pub fn
  check(parts: Array<Str>, holes: Array<Shape>) ! E`, the compiler runs it
  at build time for each literal (shapes.md: the top level runs in the
  interpreter, and `try` there fails the build). That gives
  sqlx-checked SQL **hermetically**: `sql.check` reads `let SCHEMA =
  try sql.parse_schema(try Fs.read("db/schema.sql"))` from the build's
  world, never a live database (D-L6).
- **`site` is the literal's identity**, so it serves as the cache key for
  prepared statements (JS's lesson).
- **A plain `"..."` is unchanged:** holes go through `show` (strings.md).

**Alternative A: one prefix, as in Python's PEP 750:** `t"..."` makes a
`Template`, and you write `Sql.rows(t"select ...")`. No reserved name,
and there's no build-time hook unless the compiler recognises the call
(which is magic). It's a step more verbose, and it's equally type-safe
because `Sql.rows` takes a `Template`, not a `Str`. **This is the
runner-up**, and it's the right choice if the owner dislikes reserved
members.
**Alternative B: the expected type decides the literal** (Swift's
`ExpressibleByStringInterpolation`). Holes are type-checked statically,
but the same literal means different things in different contexts,
which is implicit and against the owner's yardstick.

### 6.2 The dependency, rows and transactions

```ren
dep Sql =
  exec: fn(q: Query) -> Int ! SqlConstraint(name: Str) | Conflict | DbDown
  rows: fn(q: Query) -> Rows ! DbDown                          // a reader (streams.md), not a block
gen fn sql.query<T>(q: Query) -> T uses Sql ! DbDown | SqlRow(column: Str, expected: Str)   // by column name, through shapes
fn sql.one<T>(q: Query) -> T uses Sql ! NotFound | DbDown | SqlRow(..)
```

- **Rows decode by column *name*, through the shape** (D-L6; Go
  `Scan`'s positional bug). A nullable column needs `Option`. SQLite
  tables are `STRICT` by default, so a shape's checks are sound.
- **Dynamic queries compose fragments:** a hole whose type is `Query`
  is spliced as SQL, with its parameters merged (doobie's `Fragment`).
  There's no query DSL (jOOQ, Diesel and Ecto all have a second
  language to learn).
- **`rows` returns a reader, not a block,** so the recorder (`over any`)
  can wrap `Sql` (G-C8 resolved by streams.md's two forms).
- **Transactions are `with sql.transaction(isolation:) over Sql in`**
  (streams.md program 07, decided). It's a handler `over Sql` whose
  `finally` commits on `Ok` and rolls back on `Err` or `Cancelled`.
- **Migrations:** `let MIGRATIONS = try sql.migrations_from(Fs.list("db/
  migrations"))` at the top level (it's build-time data), and
  `sql.migrate(MIGRATIONS)` at startup.

### 6.3 SQLite

**Recommended: the embedded engine, borrowed as C, with every effect
owned by Ren** (stdlib rule 3, made hard for `std`; D-§4). Its VFS goes
through `Fs`, `xCurrentTime` through `Clock`, and `xRandomness` through
`Random`. So **`sim.fs`'s torn writes reach SQLite** and replay is
exact. In the interpreter it's an OCaml binding with the same VFS. The
implementations are `sqlite.open(path)`, `sqlite.memory()` and
`sim.sql(seed, conflict_rate:)`, plus a conformance group `sql_conforms`.

**Is it in stage 12?** Only if flottning uses SQLite. If flottning's
engine is its own, which "storage engine" suggests, then the 12 slice
should spend that effort on `Fs` handles, `sim.fs` and checksums (§9),
and SQLite moves to 13. *Alternative:* positional-parameter strings
(`Sql.rows("... $1", c)`, streams.md's current spelling) with no
templates. That's the smallest, and it's enough for a server with ten
queries, but it leaves stdlib.md's open question open.

---

## 7. log, trace and metrics

**Recommended: three faces of one event stream, all reached through
dependencies.**

```ren
dep Log = event: fn(e: Event)                    // the compiler builds `Event` from a call site
log.info("compacted", level: n, bytes: b)       // message and field names are static per call site
trace.span("compaction") fn() => compact(n)     // a function that runs a block
metrics.count("requests", route: arm, class: status_class(s))
```

- **The handlers** are `log.text()`, `log.json()`, `log.test()` (which
  captures, for assertions) and `log.off()`. A level filter is handler
  state, so it's not global (H-L10; slog's `Handler` is an interface,
  and in Ren it's a dep).
- **Cheap when off:**
  - Each call site's metadata (message, field names, level, file and
    line) is static data the compiler emits once, as with Rust
    `tracing`'s call sites, NanoLog and TigerBeetle.
  - A disabled level is a compare against handler state, and the field
    expressions aren't evaluated, because the call lowers to `if
    Log.enabled(site) then Log.event(...)`.
  - With `log.off()` installed in a closed world (decision 4), it's
    compiled out.
- **Replayable:** `Log` is an output dependency like `Console`, so the
  journal records it and a replay compares it. `Secret` fields log as
  `<redacted>`.
- **Tracing:** every dependency call is already a span (handlers.md
  `--trace`). `trace.span` adds the user's own, the server adds one per
  request named by its route arm (§3.2), and W3C `traceparent` goes in
  and out. The task tree carries the context, so there's no "current
  span" to get wrong across a suspension.
- **Metrics are derived from events** (`:telemetry`, TigerBeetle).
  **Label values must have a finite shape**: a payload-free sum, `Bool`,
  or a status class. That's checked at compile time through `shape`
  (§1.2), so unbounded cardinality is a type error, not an outage. OTLP
  export is a handler (`trace.otlp(cfg)`) that maps onto OTel's stable
  conventions only at export.

**Alternative A: log as formatted `Console` writes.** It's tiny, but it
can't filter, has no structure, and can't be captured in tests without
parsing.
**Alternative B: `log` as an `over any` recorder only**, with no
explicit events. It's free, but domain events ("compacted level 3")
aren't dependency calls.

---

## 8. Prelude, std and std.x

### 8.1 The rule

- **The prelude holds the shared types and the world:** `Int`, `Float`,
  `Bool`, `Str`, `Bytes`, `Array`, `Map`, `Set`, `Option`, `Result`,
  `Duration`, `Instant`, `Time`, `Decimal`, `Path`, `Secret<T>`; the
  built-in dependencies `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`,
  `Net` and `Async`; `retry`; and the common error words (§8.3). A type
  enters the prelude only if public signatures in several std modules
  name it (stdlib.md's shared-type test).
- **`std` is everything else that passes stdlib.md's tests**, imported by
  name (`import json`), as `sim` and `sync` are today. Until packages
  arrive (stage 13), std modules are Ren source compiled with the
  compiler (`std_lib.ml`'s model).
- **`std.x` is the set of packages that move faster than the
  compatibility promise.**

| Layer | Stage 12 contents |
|---|---|
| prelude | as above, adding `Decimal`, `Time`, `Secret`, `Path` as `opaque Bytes` (needed by 12, decided in 7b) |
| std, 12a | `shape`, `json`, `cli`, `config`, `fmt` (pad/align), `time` (RFC 3339), `uuid` (v7 via `Random` + `Clock`), `checksum` (CRC32C, xxh3), `test` (property tests, `ren fuzz`) |
| std, 12b | `http` (server, client, SSE), `log`, `trace`, `metrics`, `sql` + `sqlite` (if §6.3 says so), `collections.OrderedMap` |
| std, 13 | `tls`, `crypto`, `toml` (unless pulled into 12), `compress`, HTTP/2, `postgres` |
| std.x | `websocket`, `yaml`, `jwt`, `prometheus`, `http.client<D>` until `call` typing |

### 8.2 Rule 3 is hard for `std`

stdlib.md's open question is settled this way: a borrowed component in
`std`, such as SQLite, zstd or rustls, gets all its I/O, time,
randomness and allocation through Ren's dependencies, or it doesn't ship
in `std`. User FFI keeps `trust` and is flagged as not simulatable.

### 8.3 The error-tag convention

stdlib.md's convention has been *proposed* since stage 6, and this
design adopts it. Common words are payload-free (`NotFound`, `Invalid`,
`Conflict`, `Forbidden`, `Timeout`, `Cancelled`). Errors specific to a
domain are named for it and carry a payload (`JsonMismatch(at, ...)`,
`CliUsage(at, ...)`, `ConfigMismatch(field, from, ...)`,
`SqlConstraint(name)`, `BodyTooLarge(limit)`, `NoSuchFile(path)`).
Stage 12 mints more tags than any earlier stage, which is why the
question is due now.

*Alternative:* everything payload-free, with detail kept in logs. It
can't collide, but a path or offset in an error is the most useful
thing a format library can give (shapes.md's `DecodeError(at: ...)`).

---

## 9. flottning's 1.0 needs

Ordered by what blocks the 10,000-seed gate (README) first. The first
column says where each item lands.

| Stage | Need | Layer | From |
|---|---|---|---|
| **12a** | `T.shape`, `Value`, `build`/`view`; top-level `let`/`assert` (pure); field defaults; explicit type application | all | §1 |
| **12a** | `json` decode/encode, errors with paths, slices | server, CLI | §2 |
| **12a** | `cli` from a `Cmd` ADT; `Os.raw_args`, `Os.env`, `Os.exit`, `Console.is_tty`, stdin | CLI | §4 |
| **12a** | `config` (defaults, json file, env, flags), `Secret` | all | §5 |
| **12a** | interpolation and `Template` (`p.template`, optional `check`) | all | §6.1 |
| **12a** | property tests from shapes, saved failures, `ren fuzz` | all | testing.md |
| **12b** | **`Fs` handles**: `open`, `read_at`, `write_at`, `append`, `sync`, `datasync`, `size`, `truncate`, `rename`, `sync_dir`, `list`, `remove`, `mkdir`, `lock` | engine | G-Q21 |
| **12b** | **`sim.fs`**: lost unsynced writes on crash, torn writes, lying fsync, ENOSPC, bit flips; **crash and restart `main` on the same `sim.fs` in one test** | engine | G-Q22; the gate depends on it |
| **12b** | `checksum` CRC32C (WAL) and xxh3 (blocks) | engine | G-C11 |
| **12b** | `collections.OrderedMap` (memtable, range cursors), `BitSet` (bloom) | engine | G-§4 |
| **12b** | HTTP/1.1 server and client, `Net.connect`, owned DNS, `sim.net` faults (partition, delay, reset) | server, CLI | §3 |
| **12b** | `log`, `trace`, `metrics` | all | §7 |
| 7b (already staged) | formats layer 2: `format disk for T`, `view`/`edit`, `formats.lock` | engine | formats.md |
| services | actors and stripes (per-key work, block cache with `evict: Lru`), `Async.background` compaction | engine, server | language.md §11 |
| 11b | `snapshot` for lock-free reads of the version set | engine | decision 10 |
| 13 | TLS (or a proxy for 1.0), HMAC/SHA-256 tokens, zstd blocks | server, engine | stdlib roadmap |
| 15 | `Alloc`, so the hot path is allocation-free | engine | stdlib.md |
| if replicated | a peer protocol as a `format ... for Msg` over `Net.frames`; `http.client<D>` or framed RPC | server | streams.md program "Frames" |

**Suggested cut.** **12a** is "data at the edges": shapes, json, cli,
config, templates and property tests, all pure or `Os`-only. It
runs interpreted, and it delivers README's "done when" for the
non-network half. **12b** is "the world flottning touches": `Fs`
handles and `sim.fs`, HTTP, observability, and SQL only if flottning
uses it. **Of everything here, `sim.fs` with crash and restart matters
most for flottning.** Without it, the storage engine's 10,000 seeds
test nothing, so it should come before HTTP if the two compete.

---

## 10. What changes in the docs if this is taken

- **shapes.md:**
  - `call` uses the built surface.
  - `let ROUTES` is removed.
  - `Shape` and `Value` are ADTs in `std.shape`, `build` and `view` are
    the doors, and doc comments and defaults are in the shape.
  - The journal matches by name.
  - The build budget is counted in steps, and `f.uses` is inferred.
- **language.md §3:** `shape` joins the closed set. §6: routes are a
  `match`, and its `serve<R>` becomes the 12b+ addition.
- **stdlib.md:**
  - "Middleware is `with`" becomes rule 5.
  - The `Request`/`Response` types are the ones in §3.3.
  - `mem_http(routes)` is removed.
  - The interpolation question is answered by §6.1.
  - Rule 3 is hard for `std`.
  - The error-tag convention is adopted.
  - Its stage-12 list is split into 12a and 12b.
- **strings.md:** the `template` member is added under "Building
  strings".
- **handlers.md "Later":** `secret` becomes `Secret<T>`.

## 11. Questions for the owner

1. What is flottning? Is it replicated, and is its storage SQLite or its
   own engine (§0, §6.3, §9)?
2. Is `http.client<D>` in 1.0 (which means typing `call` in stage 12,
   §3.7), or are hand-written clients over shared types enough?
3. For templates, a reserved `template` member with an optional
   build-time `check` (recommended), or Python's single `t"..."` (§6.1)?
4. Should `toml` come into 12 for config files, or is json enough until 13
   (§5)?

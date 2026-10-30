# Research: HTTP servers, clients, routing, middleware, errors, shutdown, testing, observability

For stage 12 (`http`, `json`, `cli` over shapes) and for flottning's server layer. Written 2026-10-29.

**Sources.** Code read locally is cited by path under `/tmp/ren-refs`. That covers Effect v4 (`effect/packages/effect/src/http`, `.../http-api`), Effect v3 (`effect-v3/packages/platform/src`), Roc's `basic-webserver` (`design.md`, `platform/`, `examples/`), TigerBeetle's tracer (`tigerbeetle/src/trace.zig`, `trace/event.zig`, `trace/statsd.zig`) and Zig's new `std.Io` (`zig/lib/std/Io.zig`). The Go clone in `/tmp/ren-refs/go` holds only `src/cmd` and `src/runtime`, not `net/http` or `log/slog`. The Zig clone has no `std/http`, and the OTP clone has only `stdlib`. So Go, axum/tower/hyper/reqwest, Plug/Phoenix/Bandit, cowboy, Encore, Hono, Dream, wisp, Ktor, Zig `std.http`, slog, `tracing` and OpenTelemetry are cited from their public docs and release notes, by version, and marked *(docs)*. Before quoting any of those as fact in a design doc, check the version numbers.

---

## 0. The short version

Across fifteen designs, the same few things went wrong and were patched later:

1. **The handler's dependencies were untyped or global.** Go's `context.WithValue` bag, axum's `Extension<T>` (a missing one was a runtime 500, so 0.6 added typed `State<T>`), Plug's `assigns` map and Ktor's missing DI (a DI plugin only arrived in 3.2). Effect is the exception: its route layers carry their requirements in the type (`Request.From<"Requires", ...>` in `http/HttpRouter.ts`).
2. **Defaults weren't bounded.** Go's `DefaultClient` and server timeouts were zero (`ReadHeaderTimeout` was added in 1.8). Body sizes were unlimited until the user opted in (Go's `MaxBytesReader`; axum added a 2 MB `DefaultBodyLimit` in 0.6). Go servers had no concurrency limit. Roc's design (`basic-webserver/design.md`, "Resource ownership") makes the opposite rule the contract: *every resource-bearing path has an owner, a finite bound, saturation behaviour, a release point.*
3. **Responses were written imperatively, so the type couldn't say when one was finished.** Go's `ResponseWriter` silently ignores a `WriteHeader` that comes after `Write`. Its optional interfaces (`Flusher`, `Hijacker`) are lost when middleware wraps the writer, which Go patched with `ResponseController` in 1.20. Plug raises `AlreadySentError`. The designs people praise return a response **value**: Dream, wisp, Hono, axum `IntoResponse`, Effect and Roc.
4. **Routing was a separate DSL and was patched toward precision.** Go's `ServeMux` gained methods, wildcards, most-specific-wins and conflict panics at registration in 1.22. axum 0.8 changed `/:id` to `/{id}`. Effect v3 shipped two routers (`HttpRouter`, then `HttpLayerRouter`) and v4 merged them. wisp has no router at all: you `case` on `wisp.path_segments(req)`.
5. **Mapping errors to statuses was bolted on.** Go has `http.Error(w, string, code)` and every team writes its own `func(w, r) error` adapter. The patches are a protocol on the error: Plug's `plug_status`, axum's `IntoResponse`, Effect's `Respondable` (`http/HttpServerRespondable.ts`) with schema status annotations, Ktor's `StatusPages` and Encore's `errs.Code`. Each one maps *some* errors. None of them checks the mapping exhaustively.
6. **Graceful shutdown arrived late.** Go got `Server.Shutdown` in 1.8. axum got `with_graceful_shutdown`. It is still often wrong about readiness, about deadlines, and about hijacked or streaming connections.
7. **Observability got expensive because it pays before deciding.** OpenTelemetry allocates spans and attribute maps eagerly, samples at the head, and its semantic conventions churned (`http.method` became `http.request.method`, with an opt-in flag to emit both). The designs that get it right make the call site static: Rust `tracing` caches interest per call site, TigerBeetle uses a compile-time event enum, and Erlang's `:telemetry` is event-first with metrics derived from events.

For Ren, almost all of this is already settled by decisions it has made. Handlers are values, `uses` rows are typed, blocks are second-class, errors are structural tags, `Async.scope(max:)` is bounded, and the journal sees every dependency call. Section 4 says what stage 12 should add, and where stdlib.md's current HTTP sketch needs adjusting. The biggest adjustment: **request middleware is a call that takes a block (wisp's `use`), not `with`.** `over` is for middleware on dependencies.

---

## 1. Servers, routing and middleware

### Go `net/http` *(docs)*

**Model.** `type Handler interface { ServeHTTP(ResponseWriter, *Request) }`. `HandlerFunc` adapts a function to it, and middleware is `func(http.Handler) http.Handler`. `ServeMux` routes requests. The server starts one goroutine per connection, so handlers are plain blocking code and have no function colours.

**What went right.**
- One shared `Handler` type is why Go's web libraries fit together. stdlib.md already makes this point about the shared types everyone passes between libraries.
- Blocking code with no colours, because the runtime does the scheduling.
- `httptest` has two modes. `NewRecorder` calls a handler in-process, and `NewServer` runs it on a real loopback socket. People use both and praise both.
- **ServeMux 1.22** (Feb 2024). Patterns like `"GET /items/{id}"`, `{path...}` for the rest of a path, `{$}` for an exact match, and `r.PathValue("id")`. The most specific pattern wins, and **two patterns that conflict panic at registration**. Behind the change was a design document that defines precedence as a partial order over patterns. Go 1.23 added `Request.Pattern`, so middleware can label metrics by route pattern rather than by raw path, which avoids a cardinality explosion.

**Mistakes and later patches.**
- `ResponseWriter` is an imperative sink. A `WriteHeader` after `Write` is ignored with only a logged "superfluous response.WriteHeader call". Optional capabilities are discovered by type assertion (`http.Flusher`, `http.Hijacker`, the now-deprecated `CloseNotifier`, `Pusher`). Every middleware that wraps the writer hides them, which led to `httpsnoop`, and in 1.20 to `http.ResponseController` and an `Unwrap()` convention.
- Cancellation came late. `CloseNotifier` was replaced by `Request.Context()` in 1.7. `WithContext` copies the request.
- `context.WithValue` is an untyped bag for request-scoped data such as the user and the request id. This is the canonical "deps as ambient globals" smell.
- Handlers return nothing, so an error becomes a string written with `http.Error`. Whole libraries exist only to add `func(w, r) error`.
- The defaults are unbounded. `http.DefaultClient` has no timeout, `Server` has zero Read and Write timeouts (Slowloris), and `ReadHeaderTimeout` came in 1.8. Body limits are opt-in through `MaxBytesReader`, and the number of connections is unbounded too (`netutil.LimitListener` sits in `x/`).
- Graceful shutdown arrived with `Server.Shutdown(ctx)` in 1.8 (2017). It doesn't wait for hijacked connections, which is what `RegisterOnShutdown` is for.
- Go 1.25 later added `CrossOriginProtection`. Security middleware kept migrating into std one item at a time.

### Rust: hyper, tower, axum, reqwest *(docs)*

**Model.** hyper is the HTTP/1 and HTTP/2 engine. tower's `Service<Request>` has `poll_ready` and `call → Future`, and a `Layer` wraps one `Service` in another. axum puts *extractors* on top. A handler is an `async fn` whose arguments implement `FromRequestParts` or `FromRequest` (`Path<T>`, `Query<T>`, `Json<T>`, `State<S>`), and whose return type implements `IntoResponse`.

**What went right.**
- Handlers whose signatures are their contract: `async fn get_user(State(db): State<Db>, Path(id): Path<u64>) -> Result<Json<User>, AppError>`. Decoding comes from the types.
- Errors become responses through `impl IntoResponse for AppError`. That's the axum idiom, and it keeps the mapping in one place.
- tower middleware (timeouts, concurrency limits, load shedding, tracing) is shared between clients and servers, so tonic and axum reuse it.
- In testing, a `Router` is a `Service`, so `router.oneshot(request).await` runs it with no network.

**Mistakes and later patches.**
- `Extension<T>` was runtime-typed: forget the layer and the request fails at runtime. axum 0.6 introduced `State<S>`, which is checked at compile time with `Router::with_state`. That patch moved dependencies into the type, which is where Ren already keeps them.
- Extractor order matters. The body-consuming extractor must come last, and `#[debug_handler]` exists because the trait errors are unreadable.
- tower is hard. Many users never understood the `poll_ready` backpressure semantics, the `Clone + 'static` bounds or `BoxCloneService`. axum added `middleware::from_fn` in 0.6, so middleware could be written as `async fn(req, next: Next) -> Response`, an onion with a block.
- hyper 1.0 (2023) moved the server and client conveniences into `hyper-util` and reworked the body type (`http-body` 1.0 with `Frame`), which broke the whole ecosystem for a year.
- axum 0.8 changed the path syntax from `/:id` to `/{id}`.
- Body limits: axum 0.6 added a default 2 MB `DefaultBodyLimit`, a patch toward bounded defaults.
- Every handler is coloured `async`, and blocking calls inside one stall the executor, so everything needs `spawn_blocking`.

**reqwest (the client).** A pooled `Client` with a builder. Non-2xx responses are **not** errors unless you call `error_for_status()`, which is the same choice Go made. There's no total timeout by default. Retries aren't built in; you reach for `reqwest-middleware` or `reqwest-retry`.

### Elixir: Plug and Phoenix, Bandit; Erlang: cowboy *(docs)*

**Plug model.** A `%Plug.Conn{}` *value* goes through a pipeline. Each plug is `init/1` plus `call(conn, opts) → conn`, and `halt/1` stops the rest. A Phoenix router has `pipeline :api do plug ... end`, `scope "/api"` and `pipe_through`. It's the most ML-like of the mainstream designs: a request is data, transformed by functions.

**What went right.**
- `Plug.Test.conn(:get, "/users/1") |> MyRouter.call([])` tests with no network. It's fast and deterministic.
- Errors to statuses: the `Plug.Exception` protocol, or a `plug_status` field on an exception. A crash becomes a 500 for that request only, because let-it-crash isolates it in its process.
- `:telemetry`. Libraries emit events (`[:phoenix, :endpoint, :stop]` with measurements and metadata), and applications attach handlers to them. `Telemetry.Metrics` **derives metrics from events**, so there's one stream and no separate metrics API. The whole ecosystem adopted it (Ecto, Phoenix, Oban).

**Mistakes.**
- The conn is a god object. `assigns` and `private` are untyped maps, so request-scoped data is ambient. The conn carries both the request and the response under construction, so a "sent" state exists and `AlreadySentError` is possible.
- `halt` doesn't stop the plug you're in. Only later plugs check it.
- Phoenix replaced cowboy with Bandit, written in pure Elixir, as the default server (Phoenix 1.7.11+, 2024). The reason was simpler code and better HTTP/1 performance, which shows that the server engine can be replaced underneath a stable Plug interface. **The shared interface is the asset; the engine isn't.**

**cowboy.** It started a process per connection, and in 2.0 a process per *stream* for HTTP/2. Handlers get `Req` and return `{ok, Req, State}`. cowboy 2.0 broke the API: `Req` became an immutable map, and `reply` returns a new `Req`. Routes are compiled at startup with `cowboy_router:compile`, with constraints on bindings. Ranch handles accepting and draining, and connection limits are explicit options (`max_connections`). The lesson: a request in its own isolated task, routes compiled once, and limits as first-class options.

### Effect Platform, v3 and v4 (read locally)

Files: `effect/packages/effect/src/http/{HttpRouter,HttpMiddleware,HttpServer,HttpServerRespondable,HttpServerError,HttpClient,HttpTraceContext}.ts`, `.../http-api/{HttpApi,HttpApiEndpoint,HttpApiBuilder,HttpApiError,HttpApiMiddleware,HttpApiTest}.ts`, and v3's `effect-v3/packages/platform/src/{HttpRouter,HttpLayerRouter,HttpApi*}.ts`.

**Model.** There are two layers.
1. **`HttpRouter`** (v4). The router is a *service*, and routes are `Layer`s that register themselves with `router.add(method, path, handler)`. A route's requirements and errors surface in its layer's type as `Request.From<"Requires", Exclude<R, Provided>>` and `Request.From<"Error", E>` (`HttpRouter.ts` lines ~55–85). The dependencies of the whole server are therefore known from types. That is the Ren property, reached with heavy type machinery. Global middleware is typed so that it **can't handle errors**: there's a `Types.unhandled` sentinel and the message "You cannot handle any errors".
2. **`HttpApi`**. An *endpoint is a declaration, not a handler* (`HttpApiEndpoint.ts`, header comment). It holds the method, the path and schemas for path, query, headers, payload, success and errors. From one declaration you get the server (`HttpApiBuilder.group(Api, "users", h => h.handle(...))`), a typed client (`HttpApiClient`), OpenAPI (`OpenApi.ts`), Swagger or Scalar, and test helpers (`HttpApiTest.ts`). Error types carry their status: `HttpApiError.NotFound`, `.Conflict` and the rest are `Schema.Error`s with status annotations (`HttpApiError.ts` lines 46–448). `HttpApiBuilder.layer` *rejects two endpoints that share a method and path*.

**What went right.**
- Contract first, so client, server and docs can't drift. Declared errors are part of the endpoint.
- Middleware can **provide** a service. `HttpApiMiddleware` security middleware provides `CurrentUser` to the handlers it guards, which is typed request-scoped data with no bag.
- `Respondable` (`HttpServerRespondable.ts`) is a protocol by which an error value knows its own response. Server errors carry reasons (`RouteNotFound`, `RequestParseError` with `"BodyTooLarge"` mapped to 413, in `HttpServerError.ts` around line 98).
- Tracing is built in: the `tracer` middleware with W3C, B3 and X-B3 propagation (`HttpTraceContext.ts`), plus `SpanNameGenerator` and `TracerDisabledWhen` (`HttpMiddleware.ts` lines 160–300).
- The client has `retryTransient` with a `retryOn: "errors-only" | "response-only" | "errors-and-responses"` option and honours `Retry-After` (`HttpClient.ts` around line 969). `filterStatusOk` is opt-in. There's also a circuit breaker, documented to go after `retryTransient`.
- Testing: `HttpServer.layerTestClient` points a real client at the server under test (`HttpServer.ts` lines 247–280).

**Mistakes and patches.**
- v3 had two routers, the value-based `HttpRouter` and, later, `HttpLayerRouter`. v4 kept the layer one under the old name. The first design made the router a value you combine, and that didn't compose with layers, so the router became a service.
- The type machinery is heavy: `Request.From<...>`, `Exclude<R, Provided>`, the "unhandled" sentinel. The compile errors are notoriously hard. Ren gets the same guarantees from `uses` rows with no machinery.
- Request variants must share one endpoint per method and path, discriminated by a query, a header or the content type (`HttpApiEndpoint.ts` lines 12–28). A patch to keep routing deterministic.
- Everything is under `@stability unstable`. HTTP was rewritten several times in 2024–26.

### Encore (Go and TypeScript) *(docs)*

**Model.** "Infrastructure from code." Endpoints are declared with `//encore:api public method=GET path=/users/:id` in Go, or `api({ expose: true, method, path }, async (p) => ...)` in TypeScript. A static analyser builds a graph of the application, covering services, endpoints, databases and pub/sub, and from it generates clients, an API catalogue, architecture diagrams, and **automatic distributed tracing of every API call and every DB query**, with no instrumentation code. Errors are `errs.Code` values (gRPC-style codes such as `NotFound` and `InvalidArgument`) mapped to statuses. `encore test` provisions test infrastructure, and `et.MockEndpoint` and `et.MockService` came later.

**Right.** The compiler knows every boundary, so tracing, clients and docs are free. This is exactly Ren's README promise. Calls between services are function calls. Errors come from a closed set of codes.

**Wrong.** The magic is parsed comments and code generation, and request and response types are restricted to JSON-serializable named structs. Mocking was added after the fact. People perceive lock-in to the platform. *Ren's version needs no magic: deps are language, not comments.*

### Hono *(docs)*

**Model.** Built on Web-standard `Request` and `Response` (fetch), so it runs on every JS runtime. A handler gets a context `c` and returns `c.json(...)`. Middleware is an onion, `async (c, next) => { ...; await next(); ... }`. `c.req.param('id')` is typed from the path literal's type. RPC mode gives `hc<typeof app>(url)`, a typed client derived from the routes. Validation goes through the `zValidator` middleware. Errors go through `app.onError` and `HTTPException(status)`.

**Right.** Testing is `app.request('/path')`, which calls the app as a function. The client is derived from the server. Middleware is a block with `next`.

**Wrong.** RPC types only work if routes are *chained* (`.get().post()`), and large apps make the TypeScript server crawl, so the docs advise splitting apps. `c.set` and `c.get` variables are typed through generics on the app, which is a typed bag but still a bag.

### OCaml Dream *(docs)*

**Model.** `type handler = request -> response promise` and `type middleware = handler -> handler`. One flat module. `Dream.router [ Dream.get "/" h; Dream.scope "/api" [mw] [ ... ] ]` makes routes a list of values. Request-scoped data uses typed keys: `Dream.new_field` gives a heterogeneous map with typed keys. `Dream.test` runs a handler on a request synchronously.

**Right.** Very few types, and praised for being learnable in an afternoon. Typed per-request fields. Routes are data.

**Wrong.** It's tied to Lwt promises, a colour, and a migration to Eio has been discussed for years. Middleware composes by storing closures (`handler -> handler`), which Ren can't do, since blocks are second-class.

### Zig `std.http` and `std.Io` (Io read locally; http *(docs)*)

**Model.** `std.http.Server` is minimal. It reads requests from a connection you accept yourself, and there's no router. `std.http.Client` exists mainly because **the toolchain needs it** (the package manager fetches packages), which is the same "toolchain" test stdlib.md applies.

**Lessons.** `std.http` was rewritten at almost every release, 0.11 through 0.15. 0.15's Reader/Writer overhaul ("Writergate") broke it again, and 0.16 brings `std.Io`: an *explicit interface parameter*, like `Allocator`, whose implementations (`Threaded`, `IoUring`, `Kqueue` in `zig/lib/std/Io/`) decide whether the code blocks or runs evented. Its vtable (`zig/lib/std/Io.zig` line 563) has `async` and `concurrent`. **Two lessons.** First, settle the I/O model *before* the HTTP library, or HTTP churns every time I/O does. Second, passing Io explicitly is Zig's route to "no colours", the same route Ren takes with deps, but written by hand in every signature where Ren infers it into `uses`.

### Gleam wisp (on mist) *(docs)*

**Model.** A handler is `fn(Request, Context) -> Response`. **There's no router**: you write `case wisp.path_segments(req) { [] -> home(), ["users", id] -> user(req, ctx, id), _ -> wisp.not_found() }`. Middleware is a function that takes a callback, written with Gleam's `use`: `use <- wisp.log_request(req)`, `use req <- wisp.handle_head(req)`, `use <- wisp.require_method(req, Get)`. Dependencies (the DB connection, secrets) go in an explicit `Context` record. Errors are just responses (`wisp.not_found()`, `wisp.bad_request()`). Testing uses `wisp/testing`'s `simulate.request(Get, "/")` and calls the handler directly.

**Right.** It's the closest to Ren's taste. Routing is pattern matching, so it gets exhaustiveness and needs no DSL. Middleware is "a function that runs a block", which needs no stored closures. Dependencies are explicit. It's tiny.

**Wrong.** `use` reads oddly to newcomers. The `Context` record grows into a grab bag. Path parameters are strings to parse by hand. Methods are checked by hand inside each branch. And if you're not careful, a 405 versus 404 distinction is up to you.

### Ktor (Kotlin) *(docs)*

**Model.** Plugins (called "features" before 2.0) are installed into an application pipeline with phases: Setup, Monitoring, Plugins, Call, Fallback. Routing is a DSL of nested lambdas, `routing { get("/users/{id}") { call.respond(...) } }`. The `StatusPages` plugin maps exceptions to responses: `exception<NotFound> { call, _ -> call.respond(HttpStatusCode.NotFound) }`. `testApplication { client.get("/") }` runs on an in-memory engine.

**Right.** The in-memory test engine. `StatusPages` keeps error mapping in one place. Coroutines make structured concurrency natural.

**Wrong.** The pipeline-interceptor API was too hard, so 2.0 added `createApplicationPlugin` with simple `onCall` and `onCallReceive` hooks. There was no DI for years: everyone used Koin, and a DI plugin only arrived in 3.2. Errors are exceptions, so the type doesn't say which statuses a route can produce. Everything is coloured `suspend`.

### Roc `basic-webserver` (read locally: `basic-webserver/design.md`, `examples/*.roc`, `platform/Server.roc`, `platform/Http.roc`)

**Model.** `program = { init!, respond!, shutdown! }`. `init!` runs once, before listening, and returns `{ config, context }`, where the context is immutable. `respond!(request, context) → Try(Outcome, ...)` may run concurrently. `shutdown!(reason, context)` runs once, after draining. The host owns transport, concurrency, pools, static files, access logs, metrics and readiness. The app owns policy.

**What it gets right, and the strongest design document in the set:**
- **Every resource has an owner, a unit, a finite bound, saturation behaviour, a release point and an observable high-water mark.** No implicitly unbounded queues, pools, caches or registries. Metric label sets and prepared-statement caches don't grow with application-controlled strings.
- Startup is atomic: no listener becomes active unless `init!` and the whole server configuration validate. Route conflicts are rejected before listening.
- Shutdown happens in phases: stop accepting, cancel parked work, drain within finite deadlines, call `shutdown!`, release the context. *"If work exceeds a hard drain deadline, process termination is preferable to concurrently destroying resources that the work may still use."*
- Client disconnects aren't rollbacks: "the API must not describe cancellation as undoing completed work."
- The outbound client has finite time and body limits, bounded concurrency per destination, and typed outcomes for DNS, connect, TLS, timeout and limit failures. **Hidden retries are avoided** where they could duplicate effects. Retry policy belongs to the application unless the transport can prove the request wasn't sent.
- Work that must outlive a request is durable state (SQLite plus a supervised worker), never a detached task.
- Testing substitutes the host transport with "a controllable peer", which is authoritative for lifecycle and limits but not for timing. That is a simulated `Net` in all but name.

**Limits.** Every request is synchronous, and fan-out is an explicit bounded batch rather than futures. There's no app-level router: route your own `respond!`. The host and platform split is a second language, which Ren rejects (README, Roc comparison).

---

## 2. Cross-cutting topics compared

### 2.1 Routing

| Design | Routes are | Conflicts | Params typed? | 404 vs 405 |
|---|---|---|---|---|
| Go 1.22 ServeMux | pattern strings in a mux | panic at registration; most specific wins | strings (`PathValue`) | automatic 405 with `Allow` |
| axum | `Router::route(path, get(h).post(h2))` | panic at build | via `Path<T>` extractor | automatic |
| Effect HttpApi | endpoint declarations | rejected at layer build | schema-decoded | automatic |
| Phoenix | macro DSL, compiled to function clauses | compile warnings | strings | manual-ish |
| Dream | list of route values | first match | strings | manual |
| wisp | `case` on path segments | **exhaustiveness and redundancy by the compiler** | strings | manual |
| Roc host | exact or prefix table plus a fallback | rejected before listening | — | per native route |

The trend is toward patterns that are *checked statically for conflicts* and *named for telemetry* (Go 1.23's `Request.Pattern`, Effect's `SpanNameGenerator`).

### 2.2 Middleware: two different things under one name

Every surveyed design merges two kinds of middleware:

- **(A) Request middleware**: CORS, auth, body limits, compression, request ids, method checks, `HEAD` handling. It transforms the request or response, or short-circuits.
- **(B) World middleware**: retries, timeouts, circuit breakers, tracing of outgoing calls, rate limits on a downstream, caching. It wraps calls *to dependencies*.

tower is the one design that treats them as the same abstraction (`Service`) on both the client and server sides, and that generality is exactly what made it hard. Hono, axum's `from_fn` and wisp's `use` show that (A) is easiest as **a function that runs the rest as a block**. (B) is a wrapper around a dependency, which Ren already has as `over` and `over any`.

### 2.3 Errors to statuses

| Design | Mechanism | Checked? |
|---|---|---|
| Go | `http.Error(w, msg, code)` by hand | no |
| axum | `impl IntoResponse for AppError` | the type must implement it; the mapping isn't checked |
| Plug | `Plug.Exception` protocol / `plug_status` | no; unknown means 500 |
| Ktor | `StatusPages` by exception class | no |
| Effect | error schemas annotated with a status; `Respondable` | declared per endpoint; unknown means 500 |
| Encore | `errs.Code` → status | closed code set |
| Hono | `HTTPException(status)`, `onError` | no |
| wisp, Dream | the handler returns the response | trivially, since there are no errors |

**The pattern people like:** domain errors are typed and declared on the endpoint (Effect), and mapped in one place at the edge (axum, `StatusPages`). **The pattern people regret:** a generic catch-all that turns every unexpected error into a 500 with an internal message in the body. That leaks details, or hides bugs behind a 500 nobody looks at.

### 2.4 Graceful shutdown

What a correct shutdown needs, gathered from Go 1.8+, axum `with_graceful_shutdown`, the Roc design, Ktor `gracePeriod` and `timeout`, Ranch, and Kubernetes practice:
1. **Fail readiness first**, then wait for the load balancer to notice (the `preStop` sleep in Kubernetes). People forget this, which drops requests during deploys.
2. Stop accepting, and close idle keep-alive connections (Go does this; many others don't).
3. Drain requests in flight with a **deadline**, then cancel them.
4. Streaming responses (SSE, websockets, hijacked connections) need their own rule. Go doesn't drain hijacked connections, and Roc cancels parked SSE.
5. Run the application's shutdown hooks while the dependencies still exist, then release them.
6. Don't treat cancellation as rollback.

### 2.5 Testing

Two layers, and every praised framework has both:
- **In-process**: call the app as a function. `httptest.NewRecorder`, `Plug.Test`, `app.request`, `oneshot`, `Dream.test`, wisp `simulate`, Ktor `testApplication`, `HttpApiTest`.
- **Over a real socket**: `httptest.NewServer`, Effect `layerTestClient`. This catches the parser, headers, keep-alive and limits.

None of the surveyed designs offers a **simulated network with deterministic time and fault injection**, except Roc's internal "controllable peer" and the outside world of FoundationDB and TigerBeetle (VOPR). None can **replay a production request** from a recording, apart from niche tools (rr, Effect's `TestClock` for time only). This is where Ren is ahead.

### 2.6 Clients

| | Default timeout | non-2xx is an error? | Retries | Body must be closed? |
|---|---|---|---|---|
| Go | **none** | no | no | **yes**, or the connection leaks |
| reqwest | none in total | no (`error_for_status`) | external crate | no (drop) |
| Effect | via schedule | opt-in `filterStatusOk` | `retryTransient`, honours `Retry-After` | scoped |
| Roc | finite, required | — | **none hidden**; the app decides | no |

The lessons: timeouts and body caps must be finite by default. Only retry idempotent requests, or ones the transport proves were never sent. A status is data, and turning it into an error should be one explicit step.

---

## 3. Logging, tracing, metrics

### Go `log/slog` (1.21, 2023) *(docs)*

**Model.** `Logger` sits in front of a `Handler` interface (`Enabled`, `Handle`, `WithAttrs`, `WithGroup`). Attributes are key-value pairs. `LogValuer` resolves a value lazily, which is also how redaction is done. Text and JSON handlers are built in. **Why it exists:** the original `log` package had no structure, the ecosystem split three ways (zap, zerolog, logrus), and libraries couldn't log without choosing one. **A patch on a patch:** the convenient `Info("msg", "k", v, ...)` takes alternating `...any`, which is easy to get wrong (`go vet` gained a check) and allocates. `LogAttrs` is the fast, typed form, so there are two APIs. Context propagation needs the `InfoContext` variants. `WithGroup` makes handlers notoriously hard to write correctly. **Lesson: a logger behind one interface that implementations satisfy is right. That is a dep with handlers, in Ren's terms.**

### Rust `tracing` *(docs)*

**Model.** Spans and events, with fields. Every macro call site has a static `Callsite` holding its `Metadata` (name, target, level, field names, file and line), and **interest is cached per call site**: never, sometimes or always. A disabled call site therefore costs a load and a branch. Subscribers and composable `Layer`s (`tracing-subscriber`) decide what to keep, and `#[instrument]` makes a function a span.

**Mistakes.** `span.enter()` held across an `.await` attaches the wrong span to whatever else runs on that thread. Hence `.instrument(span)`, and a long-standing documentation warning. There's interop with the older `log` crate. `EnvFilter` is slow when span filters are dynamic. 0.2 has been "coming" for years. The OpenTelemetry bridge (`tracing-opentelemetry`) costs noticeably on hot paths.

**Lesson: static call-site metadata is the right foundation. Ren can compute it at compile time instead of at registration.**

### OpenTelemetry: where the cost goes *(docs)*

- **The API and SDK split, with a global provider.** Libraries call the API, and the SDK is installed globally. That's a global dependency, which is exactly what deps replace.
- **Eager allocation.** A span object, an attribute map with string keys, IDs and timestamps are all created even when sampling later drops them. Head sampling decides at the root, *before* anyone knows whether the request erred or was slow. Tail sampling therefore lives in the collector, which has to buffer whole traces in memory.
- **Context propagation** is thread-local, or an explicit `ctx` in Go. Async boundaries lose it unless they're instrumented.
- **Metrics cardinality.** Labelling by raw path or user id explodes series. The fix everywhere is to label by route *pattern* (Go 1.23's `Request.Pattern`).
- **The semantic conventions churned.** The HTTP conventions were stabilised in 2023 with renames (`http.method` became `http.request.method`, `http.status_code` became `http.response.status_code`). An `OTEL_SEMCONV_STABILITY_OPT_IN` variable emits old, new or both, so every exporter carries both.
- **Logs.** OTel chose a *bridge* API for logs, not a new logging API, so it rides on slog and `tracing`. Once again, the existing logging interface is the shared type.

### Erlang/Elixir `:telemetry` *(docs)*

Events are a name, measurements and metadata. Handlers attach at runtime, and metrics are derived from events (`Telemetry.Metrics`). With no handler attached, the cost is an ETS lookup. It's the cleanest "one stream, metrics derived" design in production use, and README's "traces, metrics, and logs are one stream" matches it.

### TigerBeetle trace (read locally: `tigerbeetle/src/trace.zig`, `trace/event.zig`, `trace/statsd.zig`)

Events are a compile-time enum (`event.zig` builds `Operation` and `TreeEnum` from the program's own types with comptime reflection). `trace.start(.{ .compact_mutable = .{ .tree = ... } })` and `stop` pair up, and **the pairing is asserted at runtime** (`trace.zig` lines 1–60: only one of each event may run at once, and `reset` covers cancellation). The output is Chrome or Perfetto JSON. Event names include only a "low-cardinality subset" of the arguments. The same events feed StatsD metrics (`statsd.zig`). This is close to NanoLog, and close to Ren's README plan: static metadata, tiny events, metrics derived. Note the cardinality rule: **put the bounded fields in the event name or key, and keep unbounded ones as payload.**

---

## 4. Lessons for Ren

Each lesson refers to a Ren decision already made. Code is a sketch in today's syntax, not a proposal of record.

### L1. A handler is a function from `Request` to `Response`; `serve` takes it as a block. Keep this.

The praised designs (Dream, wisp, Hono, axum, Roc) return a response **value**. Go's imperative `ResponseWriter` is the most-patched part of Go's net/http. stdlib.md's `serve(port, handle: fn(req: Request) -> Response)` is right, and because `handle` is a block, its `uses` flow to `serve`'s caller, so the whole server's dependencies are known. Effect needs `Request.From<"Requires", Exclude<R, Provided>>` to get that. Ren gets it from decision 5 (blocks find their dependencies where they're written).

There are two consequences to design deliberately:
- **Streaming responses.** A response body that's a stream (SSE, a large file, NDJSON) can't be a stored block. Make the response `Body` a variant: `Bytes(Bytes)`, `File(path, range)` (sent by the runtime, as Roc's "native response plan" does), or `Stream`. The stream is produced by having `serve` call back with a `Send<Bytes>` dep installed, in the same shape as `Async.produce` (async.md). The handler returns `Response.stream(headers)` and the server then runs a second block. An alternative is `serve`'s block returning a description that the server interprets. Settle this before stage 12 freezes `Response`.
- **The request body is a cursor over the connection** (stdlib.md already says `Body = opaque Conn`). Give it a default **byte limit** (axum's 2 MB lesson) and a read deadline. Exceeding the limit is a tagged error, `BodyTooLarge(limit: Int)`, which the server maps to 413.

### L2. Routing is a `match` on method and path segments, with typed segments. Add no router DSL in 1.0.

wisp shows that a `case` on segments needs no router at all. In Ren, the compiler can then check **exhaustiveness and redundancy**, which is what Go 1.22 and Roc check at startup with panics. Sketch:

```ren
fn routes(req: Request) -> Response ! ApiError uses Users, Clock =
  match (req.method, req.segments())
    (Get,  ["users"])          => list_users(req)
    (Get,  ["users", id])      => get_user(try UserId.parse(id))
    (Post, ["users"])          => create_user(try json.decode<NewUser>(req.body))
    (_,    ["users", ..])      => Response.method_not_allowed(allow: [Get, Post])
    _                          => Response.not_found()
```

- **The span and metric name is the arm**, known statically. The compiler can name each arm (`GET /users/{id}`) for the trace recorder at no runtime cost. That solves the cardinality problem (Go's `Request.Pattern`) by construction.
- Matching on string lists can be compiled to a trie. That's work in the compiler, not a DSL.
- **Typed parameters**: use `try UserId.parse(id)` explicitly. Shapes can add `req.path<T>()` later if it's needed.
- A *declarative API* (Effect's `HttpApi`, Encore, Hono RPC), from which clients and OpenAPI are derived, should be **a `dep` with shapes**. See L8. It's not a router.

### L3. Split middleware: request middleware is a call that takes a block; world middleware is `over`.

stdlib.md says "Middleware is `with`". That holds for **(B) world middleware**: `with traced() over any`, `retry<D>(n) over Http`, `Async.limit(n) over Sql`, and caching and circuit breakers as handlers `over` a dependency. These are all `over` (handlers.md, shapes.md "Handlers that work for any dependency").

But **(A) request middleware** (CORS, auth, body limits, request ids, `HEAD`, compression) acts on the *request and response*, not on a dependency's operations. Decision: *`with` installs only handlers; a function that runs a block is called with it.* So request middleware is a function that runs a block, which is wisp's `use` and axum's `from_fn`:

```ren
http.serve(cfg.port) fn(req) =>
  http.cors(req, allow: cfg.origins) fn(req) =>
    auth.require(req) fn(req, user) =>      // a 401 returns early; `user` is a typed block parameter
      routes(req, user)
```

- **Request-scoped data is a block parameter** (`user` above). Not a context bag (Go `WithValue`, Plug `assigns`, axum `Extension`, Hono `c.set`), and not a dependency installed per request. Effect's "middleware provides `CurrentUser`" is the same idea with layers. In Ren it's just a parameter: explicit, typed, ML.
- A middleware that needs to see the response's status for logging or metrics is a call around the block: `let resp = body(req)`, and then it inspects `resp`. No `ResponseWriter` wrapping, so Go's lost-`Flusher` problem can't happen.
- The `std` set: `cors`, `body_limit`, `request_id`, `head`, `compress`, `security_headers`, `recover`. `recover` is `Async.isolate`, turning a panic into a 500 for that request. See L5.
- **Change stdlib.md's bullet** to "Middleware on dependencies is `over`; middleware on requests is a function that runs the rest as a block."

### L4. Errors to statuses: one exhaustive `match` at the edge, with no protocol on error types.

Ren's errors are structural tags, and a public function's error set is exact (errors.md). So the route function's `!` set is known, and the edge can write:

```ren
fn respond(req: Request) -> Response uses Users, Clock =
  match routes(req)
    resp                  => resp
    fail NotFound         => Response.status(404)
    fail Invalid          => Response.status(422)
    fail Conflict         => Response.status(409)
    fail BodyTooLarge(..) => Response.status(413)
```

- The compiler forces every tag to be handled. Adding a new error to a deep function makes the edge fail to compile. That's better than every surveyed design: Effect's per-endpoint declaration is the closest, and unknown errors there still become 500.
- **There's no `Respondable` or `IntoResponse` protocol.** An error doesn't know its own HTTP status, because that couples the domain to transport (a DDD smell). The edge decides.
- `std`'s prelude tags (`NotFound`, `Invalid`, `Conflict`, `Forbidden`, `Timeout`, from stdlib.md Part 3) give a **default mapping function**, `http.status_of(tag)`, which a server can call in its catch-all arm. It's explicit, with no magic.
- Panics: a panic in a request becomes a 500 through `Async.isolate`, per request. Decision: a panic ends the program (async.md). Decide whether `serve` isolates requests by default. Erlang, Plug and Go (which `recover`s in `ServeHTTP`) all do. Recommendation: `serve` isolates and logs, and a test can turn that off to fail fast.

### L5. Bounded by default: limits are named parameters with finite defaults.

Adopt Roc's rule as a `std` convention: **every queue, pool, body, header block, connection count and timeout in `http` has a finite default, a tagged error when it's exceeded, and a high-water mark in the trace.** Concretely: `serve(addr, max_conns: 10_000, header_limit: 16.kb, body_limit: 2.mb, read_header_timeout: 10.s, idle_timeout: 60.s)`. These are by-name parameters with defaults, as foundations already allows. `Async.scope(max:)` is already the backpressure for concurrency. The client gets `timeout: 30.s` and `max_body: 10.mb` by default, and a call made without them is never unbounded.

### L6. Graceful shutdown is the loop's end, plus readiness and a deadline.

async.md's graceful server (`accept_until(listener, Signal.term)`, with the scope waiting for tasks in flight) is the right core, and the simplest of all the designs. Add these to `http.serve`:
1. A `ready` flag, served on `/healthz/ready`, that flips to unready on `SIGTERM`. Then wait `drain_delay` before closing the listener, which is Kubernetes' lesson.
2. Close idle keep-alive connections at once, and let active ones finish their current request, with `Connection: close`.
3. `shutdown_deadline`, after which requests in flight are cancelled. Cancellation reaches their `finally`, and is not a rollback (Roc).
4. Streaming responses get cancelled at the deadline, and their `finally` runs.
5. The application's shutdown work is `finally` in a handler around `serve`. With handler state and `finally` (handlers.md), dependencies are released in reverse order after `serve` returns. There's no `shutdown!` hook to design: **`with ... in http.serve(...)` already is init, run and shutdown.** Roc's `{init!, respond!, shutdown!}` falls out of `with` plus `finally`.

### L7. Testing: three implementations, one handler, and the journal.

- **In-process**: `routes(req)` is a function. Call it with `Request.get("/users/1")` under `mem_users()`. This is the `Plug.Test` and `app.request` experience, for free.
- **Over a socket, simulated**: `with sim.net(seed) in` run `http.serve`, and drive it with `http.client()`. Since the HTTP/1.1 parser is written in Ren (stdlib.md's table: http in Ren), it runs under sim with deterministic time, partitions and slow peers. No other surveyed design has this; Roc's "controllable peer" is the closest. **Flottning's 10,000 seeds need this.**
- **`mem_http(routes)`** as the client's in-memory implementation takes a *block*. A test can therefore point a client at a server's `routes` directly, with no network (Effect's `layerTestClient`, without sockets).
- **Replay.** Journal at the **`Http` level** by default: a request in, a response out, and client calls with their responses. Journal at the `Net` level only when debugging the parser. Entries at the HTTP level are readable (`GET /users/7 → 200`) and small. `ren trace pull --request 8812` plus `ren replay` (README) needs the server to journal each request's *incoming* `Request` as a dependency result. So **accepting a request is a dependency operation** (`Net.accept` and the parse), not something the runtime calls into. Async.md's `accept_until` already makes it so.
- **A conformance group**: `http.client_conforms(c)` checks redirects, timeouts, limits and keep-alive for every implementation (real, `mem_http`, `sim.http`), as stdlib.md requires.

### L8. A typed API contract is a `dep`, served and called over HTTP through shapes. Defer it until after 1.0 unless flottning needs it.

Effect's `HttpApi`, Encore and Hono's RPC all derive the client, server and docs from one declaration. In Ren that declaration already exists, **the `dep`**. The pieces:
- `http.expose<Users>(impl, at: "/users")` serves every operation of a dep: `POST /users/get` with a JSON body, or REST paths annotated per operation.
- `http.client<Users>(base_url)` is an implementation of `Users` that sends each call over HTTP. This is shapes.md's `rpc.client<D>`, with HTTP as the transport.
- The operation's declared `!` tags travel in the response, and the client re-raises them. Error sets survive the network, typed. Encore and Effect only approximate this.
- OpenAPI comes from the shape.

This depends on shapes.md's open question "how `call` is typed". It's the most "unified" idea available: **a remote service is just a dep whose handler lives on another machine**. And it's exactly what flottning's CLI needs to talk to its server. Recommend designing it now, building it in stage 12 only if the `call` typing question is settled, and otherwise doing it right after.

### L9. Clients: status is data, retries are explicit, idempotency is in the type.

```ren
let resp = try Http.send(Request.get(url), timeout: 5.s)  // ! Timeout | ConnRefused(addr:) | TlsHandshake(reason:) | BodyTooLarge(limit:)
let body = try resp.ok()                                   // ! HttpStatus(code: Int)
let rate = try retry(3, on: Timeout | ConnRefused) fn() => try fetch_rate()
```

- Non-2xx isn't a failure of `send` (Go and reqwest got this right). `resp.ok()` is the one explicit step that makes it one.
- **No hidden retries** (Roc). `retry` is a call (handlers.md), and `std` offers `retry_transient`, which retries only idempotent methods and honours `Retry-After` (Effect).
- The body is a cursor that's freed by RC when dropped, so Go's "must close the body" leak can't happen. A dropped value is still written `let _`, per README rule 7.
- The pool is handler state of `http.client(pool: ...)`, so the journal sees each call, not the pool.

### L10. Observability: `log` and `trace` are deps over one event stream; names are static; the span is the route arm.

- Make `log` a **dep with handlers** (`log.json`, `log.text`, `log.test()` to capture, `log.off`), just as slog's `Handler` is an interface. In Ren that's not an interface, it's a dep. Fields are named arguments: `log.info("charged", user: u.id, amount: amt)`. Field names and the message are static, extracted at compile time (NanoLog, TigerBeetle, Rust `tracing` call sites). That avoids slog's two-API split: there's only one form, and it's the fast one.
- **Every dependency call is already a span** (README). HTTP adds the server span per request, named by the route arm (L2), and propagates W3C `traceparent` in and out, which Effect has (`HttpTraceContext.ts`). The task tree carries the context, so there's no thread-local and no `ctx`. Rust's `enter()`-across-`.await` footgun can't happen, because there's no ambient "current span" to get wrong.
- **Metrics are derived from events** (`:telemetry`, TigerBeetle, README). `std` defines the HTTP set: request count and duration by arm and status class, in-flight count, body bytes, and the high-water marks from L5. **Bounded cardinality by construction**: labels come only from static names, enum fields and status classes. An unbounded field is payload, never a label (TigerBeetle's rule).
- OTLP export is a handler (`trace.otlp(cfg)`). Map onto OTel's *stable* HTTP semantic conventions only at export, and never let them leak into the API, because they churned.
- Tail sampling is in-process with the flight recorder (README), which removes OTel's biggest cost.

### L11. Engine and interface are separate; build the interface first and freeze it.

Plug outlived cowboy (Bandit replaced it underneath). Zig's `std.http` churned with every I/O change. hyper 1.0 broke the ecosystem. The shared types (`Request`, `Response`, `Body`, `Headers`, `Method`, the log event) are what must be stable. The HTTP/1.1 parser and the connection loop are an implementation that can change. Stage 12 should freeze the *types* and the `serve` and `send` signatures, and leave HTTP/2 to stage 13 (stdlib.md already does). The runtime's ring (runtime-io.md) must be settled before the server's buffer strategy is.

### L12. What flottning needs from this, by layer

- **Server**: L1–L7 and L10, which are routes, errors at the edge, limits, shutdown, sim and replay.
- **CLI**: the client (L9), and ideally `http.client<D>` (L8), so the CLI calls the server through the same dep its tests fake.
- **Storage engine**: probably no HTTP, but it uses the same `log` and `trace` deps (L10) and the same bounded-resource convention (L5). Its admin and metrics endpoint is a ten-line `match` (L2).

One mechanism per question: **routes are a `match`, request middleware is a block, world middleware is `over`, errors are a `match` at the edge, dependencies are `uses`, a remote service is a dep, observability is the event stream.** Nothing new is needed in the language for 1.0. The work is a `std` that keeps to these rules.

### Open questions this raises for stage 12

1. How does a streaming `Response` body work without stored blocks (L1)? Is it a second block `serve` calls, a `Send<Bytes>` dep, or a description?
2. Does `serve` isolate panics per request by default (L4)? This interacts with "a panic ends the program".
3. Does accepting a request count as a journaled dependency result at the HTTP level (L7)? And what is the journal's level for request bodies at level 2 versus 3?
4. Is `http.client<D>` and `http.expose<D>` in 1.0 (L8)? That depends on how `call` is typed (shapes.md).
5. Should the route `match` have compiler support for naming arms for traces, or should arms be named by a `std` helper (L2)? Prefer the compiler: it's complexity in the compiler, not in user code.

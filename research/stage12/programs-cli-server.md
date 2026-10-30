# Programs, part 1: flottning's CLI, server and client

Written 2026-10-29 against `design.md` (cited §n) in this folder. Each
program is written in Ren under the **recommended** design, then in its
strongest idiomatic twin (Rust: clap + figment + serde, axum + tower +
tracing, reqwest + backon; tests with tower's `oneshot` and turmoil). The
main alternative is shown where it changes the code. Every place the
design felt magic, verbose or needed a special case is marked **[F#n]**
and collected in the last section, with a proposed fix.

Assumed flottning (the design's §0 ask is still open): one binary, a
single-node key-value store with versions and prefix watches, its own
engine (WAL plus pages) behind `dep Store`. The engine's internals are
part 2; here it's an interface.

Syntax is today's plus the data stage (by-name variants, `{ ..x }`,
`let ... else`, or-patterns, `as`), the services stage (`wiring`, `|>`),
unit literals (`2.s`) and 11c readers, as design.md assumes.

---

## 0. Shared: the domain and the API types

```ren
// kv.ren: the domain. Data, and the rules it keeps.

/// A key: 1 to 512 bytes of UTF-8, no control characters
pub type Key = opaque Str
  pub fn parse(s: Str) -> Key ! BadKey(reason: Str) =
    if s.len() == 0 then fail BadKey("empty")
    if s.len() > 512 then fail BadKey("longer than 512 bytes")
    if s.chars().any(fn(c) => c.is_control()) then fail BadKey("control character")
    Key(s)
  pub fn str(self) -> Str = self

pub type Version = opaque Int
  pub fn parse(n: Int) -> Version ! BadVersion = if n < 1 then fail BadVersion else Version(n)

/// When a write may happen
pub type Cond =
  | Always
  | IfVersion(Version)
  | IfAbsent

pub type Entry = { key: Key, value: Bytes, version: Version }

pub type Change =
  | Set { key: Key, version: Version }
  | Removed { key: Key, version: Version }
```

```ren
// store.ren: the engine's interface. part 2 implements it.
pub dep Store =
  get:     fn(k: Key) -> Option<Entry> ! DiskFailed(path: Path)
  put:     fn(k: Key, v: Bytes, c: Cond) -> Version ! Conflict | StoreFull | DiskFailed(path: Path)
  delete:  fn(k: Key, c: Cond) -> Option<Version> ! Conflict | DiskFailed(path: Path)
  scan:    fn(prefix: Str, after: Option<Key>, limit: Int) -> Array<Entry> ! DiskFailed(path: Path)
  watch:   fn(prefix: Str) -> Watch                  // a reader (streams.md rule 6): data, held by the caller
  compact: fn(level: Option<Int>) -> Compacted ! DiskFailed(path: Path) | Busy

pub type Compacted = { tables_in: Int, tables_out: Int, bytes_freed: Int }
```

```ren
// api.ren: the wire types the server and the client share (§3.7: no http.client<D> yet)

/// Body of PUT /v1/keys/{key}
pub type PutBody = {
  /// The value, as UTF-8 text; binary values use value_b64
  value: Option<Str>,
  value_b64: Option<Str>,
  if_version: Option<Int>,
  if_absent: Bool = false,
}

pub type EntryOut = { key: Str, value: Str, version: Int }
pub type PutOut   = { version: Int }
pub type ListOut  = { entries: Array<EntryOut>, next: Option<Str> }

/// The query string of GET /v1/keys
pub type ListQuery = { prefix: Str = "", after: Option<Str>, limit: Int = 100 }

/// Every error body: {"error": "conflict", "at": "if_version", "detail": "..."}
pub type Problem = { error: Str, at: Option<Str>, detail: Option<Str> }

// Edge type to domain: rule 1, "a type that needs more is its own edge type, converted by hand"
pub fn to_write(b: PutBody) -> (Bytes, Cond) ! BadBody(at: Str, reason: Str) =
  let value = match (b.value, b.value_b64)
    (Some(s), None) => s.bytes()
    (None, Some(s)) => base64.decode(s) orelse fail BadBody("value_b64", "not base64")
    _ => fail BadBody("value", "give exactly one of value and value_b64")
  let cond = match (b.if_version, b.if_absent)
    (None, false) => Always
    (Some(n), false) => IfVersion(try match Version.parse(n)
                          v => v
                          fail BadVersion => fail BadBody("if_version", "must be 1 or more"))
    (None, true) => IfAbsent
    (Some(_), true) => fail BadBody("if_absent", "can't be combined with if_version")
  (value, cond)

pub fn entry_out(e: Entry) -> EntryOut =
  EntryOut { key: e.key.str(), value: Str.from_utf8_lossy(e.value), version: e.version.int() }
```

Notes on the shared part:

- `Key.parse` is the one validation hook (rule 2). It's reached from the
  path segment, the CLI positional, json, and property tests alike.
- The tag for a bad key is `BadKey(reason)`, not `Invalid`: the
  convention (§8.3) makes `Invalid` payload-free, and a 422 wants to say
  why. So every validating type mints its own domain tag, and the edge
  `match` lists each one **[F#9]**.
- `PutBody → (Bytes, Cond)` is a hand-written edge conversion. It's
  explicit and short, and it's where the `if_version`/`if_absent`
  exclusion lives. Rust does the same in a `TryFrom`.

---

## 1. The server

### 1.1 Ren, recommended design

```ren
// server.ren
import json
import http.{Request, Response, Status}
import log
import trace

pub type Who = Reader | Writer | Admin

/// Server settings: one record, from defaults, a file, env and flags (§5)
pub type ServerCfg = {
  /// Address the API listens on
  addr: Addr = Addr.any(7400),
  /// Data directory
  dir: Path = Path.of("data"),
  /// How writes reach the disk
  sync: SyncMode = Group(window: 2.ms),
  /// Tokens that may read
  read_tokens: Array<Secret<Str>> = [],
  /// Tokens that may write
  write_tokens: Array<Secret<Str>> = [],
  /// The token for /v1/admin
  admin_token: Secret<Str>,
  /// How long requests in flight get at shutdown
  drain: Duration = 5.s,
  log: Level = Info,
}

// ---- the routes: a match (§3.2) ----

fn routes(req: Request, who: Who) -> Response
    ! BadKey(reason: Str) | BadBody(at: Str, reason: Str) | BadQuery(at: Str, reason: Str)
    | JsonSyntax(at: Int, expected: Str) | JsonMismatch(at: Str, expected: Str, found: Str)
    | JsonLimit(what: Str, limit: Int) | BodyTooLarge(limit: Int)
    | NotFound | Conflict | Forbidden | StoreFull | Busy | DiskFailed(path: Path)
    uses Store, Log, Clock =
  match (req.method, req.segments())
    (Get, ["v1", "keys", k]) =>
      let key = try Key.parse(k)
      let e = try Store.get(key) orelse fail NotFound
      http.json(Ok, entry_out(e))

    (Put, ["v1", "keys", k]) =>
      try who.at_least(Writer)
      let key = try Key.parse(k)
      let (value, cond) = req.bytes()
        |> try json.decode<PutBody>
        |> try to_write
      let v = try Store.put(key, value, cond)
      log.info("put", key: k, version: v.int(), bytes: value.len())
      http.json(Ok, PutOut { version: v.int() })

    (Delete, ["v1", "keys", k]) =>
      try who.at_least(Writer)
      let key = try Key.parse(k)
      let cond = try cond_from_query(req)
      let _ = try Store.delete(key, cond) orelse fail NotFound
      http.empty(NoContent)

    (Get, ["v1", "keys"]) =>
      let q = try http.query<ListQuery>(req)                       // [F#8]
      if q.limit < 1 or q.limit > 1000 then fail BadQuery("limit", "1 to 1000")
      let after = match q.after
        Some(a) => Some(try Key.parse(a))
        None => None
      let es = try Store.scan(q.prefix, after, q.limit + 1)
      let next = if es.len() > q.limit then Some(es[q.limit - 1].key.str()) else None
      http.json(Ok, ListOut { entries: es.take(q.limit).map(entry_out), next })

    (Get, ["v1", "watch"]) =>
      let q = try http.query<WatchQuery>(req)
      watch(req, q.prefix)

    (Post, ["v1", "admin", "compact"]) =>
      try who.at_least(Admin)
      let c = try trace.span("compaction") fn() => try Store.compact(None)
      http.json(Ok, c)

    (_, ["v1", "keys", _]) => http.method_not_allowed([Get, Put, Delete])
    (_, ["v1", "keys"])    => http.method_not_allowed([Get])
    _                      => fail NotFound

type WatchQuery = { prefix: Str = "" }

// ---- the streaming endpoint: server-sent events (§3.3) ----

fn watch(req: Request, prefix: Str) -> Response ! DiskFailed(path: Path) uses Store, Clock =
  http.stream(req, Ok, http.sse_headers()) fn(&out) =>
    var w = Store.watch(prefix)
    loop
      // a heartbeat every 15 s keeps proxies from closing an idle stream;
      // `w.next` is one operation, so it can be raced (streams.md rule 7)  [F#12]
      match attempt Async.timeout(15.s) fn() => try &w.next()
        Ok(Some(ch)) => try &out.send(http.sse_event(name: change_name(ch), data: json.encode(ch)))
        Ok(None) => break
        Err(Timeout) => try &out.send(http.sse_comment("hb"))

fn change_name(c: Change) -> Str =
  match c
    Set { .. } => "set"
    Removed { .. } => "removed"

// ---- errors to statuses: one exhaustive match at the edge (§3.5) ----

fn respond(req: Request, who: Who) -> Response uses Store, Log, Clock =
  match routes(req, who)
    resp => resp
    fail BadKey(reason) => problem(422, "bad_key", None, reason)
    fail BadBody(at, reason) | fail BadQuery(at, reason) => problem(422, "invalid", Some(at), reason)
    fail JsonSyntax(at, expected) => problem(400, "json_syntax", Some("byte {at}"), "expected {expected}")
    fail JsonMismatch(at, expected, found) => problem(422, "invalid", Some(at), "expected {expected}, found {found}")
    fail JsonLimit(what, limit) => problem(413, "too_large", Some(what), "limit {limit}")
    fail BodyTooLarge(limit) => problem(413, "too_large", None, "body over {limit} bytes")
    fail NotFound => problem(404, "not_found", None, "")
    fail Conflict => problem(409, "conflict", None, "")
    fail Forbidden => problem(403, "forbidden", None, "")
    fail StoreFull => problem(507, "store_full", None, "")
    fail Busy => problem(503, "busy", None, "")                      // + Retry-After
    fail DiskFailed(path) =>
      log.error("disk failed", path: path)
      problem(500, "internal", None, "")

fn problem(code: Int, error: Str, at: Option<Str>, detail: Str) -> Response =
  let d = if detail == "" then None else Some(detail)
  http.json(Status.of(code), Problem { error, at, detail: d })

// ---- middleware: functions that run the rest as a block (§3.4) ----

fn authenticate(req: Request, cfg: ServerCfg, rest: fn(req: Request, who: Who) -> Response) -> Response =
  let Some(tok) = req.headers.bearer() else return problem(401, "unauthorized", None, "")
  let who =
    if cfg.admin_token.eq_const(tok) then Admin
    else if cfg.write_tokens.any(fn(t) => t.eq_const(tok)) then Writer
    else if cfg.read_tokens.any(fn(t) => t.eq_const(tok)) then Reader
    else return problem(401, "unauthorized", None, "")
  rest(req, who)

pub fn at_least(self: Who, need: Who) ! Forbidden =     // under `type Who`
  if self.rank() < need.rank() then fail Forbidden

pub fn handle(cfg: ServerCfg, req: Request) -> Response uses Store, Log, Clock =
  http.request_id(req) fn(req) =>
    match (req.method, req.segments())
      (Get, ["healthz", "live"])  => http.empty(Ok)          // outside auth
      (Get, ["healthz", "ready"]) => http.ready(req)          // unready once shutdown starts (§3.8)
      _ => authenticate(req, cfg) fn(req, who) => respond(req, who)

// ---- the composition root ----

pub wiring live(cfg: ServerCfg) provides Store, Log uses Fs, Clock ! DiskFailed(path: Path) | Locked =
  engine.open(cfg.dir, sync: cfg.sync),       // takes the directory's lock; its finally flushes the WAL and fsyncs
  log.json(level: cfg.log)

pub fn serve(cfg: ServerCfg) ! AddrInUse(addr: Addr) | DiskFailed(path: Path) | Locked
    uses Net, Fs, Clock, Async, Os =
  try with live(cfg) in
    log.info("listening", addr: cfg.addr, dir: cfg.dir)
    try http.serve(cfg.addr, until: Signal.term, drain: cfg.drain) fn(req) => handle(cfg, req)
    log.info("drained")
  // here every request has ended, and engine.open's finally has run: WAL flushed, fsynced, lock released
```

What happens at shutdown, in order: SIGTERM flips `/healthz/ready` to
503, `accept_until` stops accepting, idle keep-alive connections close,
requests in flight get `Connection: close` and `cfg.drain`, then the rest
are cancelled. **The SSE streams are requests in flight, so every
graceful shutdown waits the full drain for them and then cuts them off
mid-event [F#12].** Then `serve` returns, `log.info("drained")`, and the
wiring's `finally`s run in reverse: `log.json` flushes, `engine` syncs.

### 1.2 Ren: the server's tests

```ren
// server_test.ren
import sim.{SimNet}

test fn cfg() -> ServerCfg =
  ServerCfg { admin_token: Secret.of("adm"), write_tokens: [Secret.of("w")], read_tokens: [Secret.of("r")] }

test fn get(path: Str, tok: Str) -> Request = Request.get(path).bearer(tok)

// 1. in process: the handler is a function, so call it (§3.8 level 1)
test "a put then a get gives the value back" =
  with mem_store(), log.test() in
    let p = handle(cfg(), Request.put("/v1/keys/a", "{\"value\":\"x\"}").bearer("w"))
    assert p.status == Ok
    let g = handle(cfg(), get("/v1/keys/a", "r"))
    assert try json.decode<EntryOut>(g.body.bytes()) == EntryOut { key: "a", value: "x", version: 1 }

test "a reader can't write" =
  with mem_store(), log.test() in
    let r = handle(cfg(), Request.put("/v1/keys/a", "{\"value\":\"x\"}").bearer("r"))
    assert r.status == Forbidden

test "both if_version and if_absent is a 422 that says where" =
  with mem_store(), log.test() in
    let r = handle(cfg(), Request.put("/v1/keys/a", "{\"value\":\"x\",\"if_version\":2,\"if_absent\":true}").bearer("w"))
    assert r.status == UnprocessableEntity
    assert try json.decode<Problem>(r.body.bytes()).at == Some("if_absent")

// a property test: any key the domain accepts round-trips through the path
test "every key round-trips through PUT and GET" (k: Key, v: Str) =
  with mem_store(), log.test() in
    let path = "/v1/keys/{http.escape_segment(k.str())}"
    let _ = handle(cfg(), Request.put(path, json.encode(PutBody { value: Some(v) })).bearer("w"))
    let e = try json.decode<EntryOut>(handle(cfg(), get(path, "r")).body.bytes())
    assert e.value == v

// 2. over a simulated network, the server and the real client (§3.8 level 2)
test fn here() -> Addr = Addr.local(7400)

test "the client retries through connection resets" =
  // `ren test --seeds 10000` runs this under 10,000 schedules and fault tapes
  with sim.net(reset: 5.percent, delay: 0.ms..20.ms), mem_store(), log.test(), http.client() in
    try Async.scope fn(s) =>
      s.spawn fn() =>
        let _ = attempt http.serve(here(), isolate: false) fn(req) => handle(cfg(), req)
      let c = ClientCfg { addr: here(), token: Some(Secret.of("w")) }
      let v = try client.put(c, try Key.parse("a"), "x".bytes(), IfAbsent)
      assert try client.get(c, try Key.parse("a")) == Some(Entry { key: try Key.parse("a"), value: "x".bytes(), version: v })
      SimNet.signal(Signal.term)

test "a watcher sees every change, in version order" =
  with sim.net(), mem_store(), log.test(), http.client() in
    try Async.scope fn(s) =>
      s.spawn fn() =>
        let _ = attempt http.serve(here(), isolate: false) fn(req) => handle(cfg(), req)
      let seen = s.start fn() => client.watch(rcfg(), "user/", take: 3)
      for i in 1..=3
        let _ = try client.put(wcfg(), try Key.parse("user/{i}"), "{i}".bytes(), Always)
      assert seen.join().map(fn(c) => c.version().int()) == Some([1, 2, 3])
      SimNet.signal(Signal.term)

test "shutdown waits for a slow put, then flushes" =
  with sim.net(), sim.fs(), log.test(), http.client() in
    try Async.scope fn(s) =>
      s.spawn fn() => let _ = attempt serve({ ..cfg(), addr: here() })
      let p = s.start fn() => client.put(wcfg(), try Key.parse("k"), "v".bytes(), Always)
      SimNet.signal(Signal.term)
      assert p.join().is_ok()
    assert log.test.events().last().msg == "drained"

// 3. the conformance group every Store ships (stdlib rule 2) is in part 2
```

Logging and tracing in the tests: `log.test()` captures events, so an
assertion reads `log.test.events()` as values. Each request is a span
named by its route arm, its `Store.*` calls are child spans (handlers.md
`--trace`), and `ren test --trace` shows the tree for a failing seed.

### 1.3 The alternatives where they change the code

**§3.2 Alt A, a route enum** (12b+, on top of the `match`). The pattern
moves into data, and a path parameter is decoded into a typed field by
`shape.build`, so `Key.parse` is written once:

```ren
type Route =
  | GetKey(key: Key)
  | PutKey(key: Key)
  | DeleteKey(key: Key)
  | ListKeys
  | Watch
  | Compact

let ROUTES = http.routes<Route>([
  (Get, "/v1/keys/{key}", "GetKey"), (Put, "/v1/keys/{key}", "PutKey"), (Delete, "/v1/keys/{key}", "DeleteKey"),
  (Get, "/v1/keys", "ListKeys"), (Get, "/v1/watch", "Watch"), (Post, "/v1/admin/compact", "Compact"),
])                                         // checked at build time: every case named once, every {name} a field

fn route(r: Route, req: Request, who: Who) -> Response ! ... uses Store, Log, Clock =
  match r
    GetKey(key) => ...
```

It's tidier at each arm, gives `ren explain` and OpenAPI a list, and
answers [F#1] and [F#7] (the arm *is* a constructor). The cost: a
second place to edit per route, and constructor names as strings inside
the table (checked at build time, but still strings) **[F#13]**.

**§3.4's alternative, the caller as a dependency.** `with as_who(who) in
respond(req)` and `uses Caller` in every route that checks rights. It
removes the `who` parameter from `routes` and adds a handler install per
request. It's not better here: `who` is three values of data.

### 1.4 The Rust twin (axum 0.7, tower-http, tracing, serde)

```rust
// server.rs
#[derive(Clone)]
struct App { store: Arc<dyn Store>, cfg: Arc<ServerCfg> }

#[derive(Deserialize)]
#[serde(try_from = "String")]
struct Key(String);
impl TryFrom<String> for Key { type Error = &'static str; fn try_from(s: String) -> Result<Self, Self::Error> { /* same rules */ } }

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PutBody { value: Option<String>, value_b64: Option<String>, if_version: Option<u64>, #[serde(default)] if_absent: bool }

#[derive(Deserialize)]
struct ListQuery { #[serde(default)] prefix: String, after: Option<Key>, #[serde(default = "d100")] limit: u32 }

#[derive(Clone, Copy, PartialEq, PartialOrd)]
enum Who { Reader, Writer, Admin }

enum ApiError {
    BadKey(String), Invalid { at: String, reason: String }, Json(JsonRejection), Query(QueryRejection),
    Path(PathRejection), NotFound, Conflict, Forbidden, Full, Busy, Disk(PathBuf),
}
impl From<StoreError> for ApiError { fn from(e: StoreError) -> Self { match e { /* ... */ } } }
impl From<JsonRejection> for ApiError { fn from(e: JsonRejection) -> Self { ApiError::Json(e) } }
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (code, error, at, detail) = match self {
            ApiError::BadKey(r) => (StatusCode::UNPROCESSABLE_ENTITY, "bad_key", None, Some(r)),
            ApiError::Json(r) => (r.status(), "json", None, Some(r.body_text())),
            // ... one arm each; adding a StoreError variant breaks only the From impl
            ApiError::Disk(p) => { tracing::error!(path = %p.display(), "disk failed"); (StatusCode::INTERNAL_SERVER_ERROR, "internal", None, None) }
        };
        (code, Json(Problem { error, at, detail })).into_response()
    }
}

async fn get_key(State(app): State<App>, Path(key): Path<Key>) -> Result<Json<EntryOut>, ApiError> {
    let e = app.store.get(&key).await?.ok_or(ApiError::NotFound)?;
    Ok(Json(e.into()))
}

async fn put_key(State(app): State<App>, Extension(who): Extension<Who>, Path(key): Path<Key>,
                 body: Result<Json<PutBody>, JsonRejection>) -> Result<Json<PutOut>, ApiError> {
    if who < Who::Writer { return Err(ApiError::Forbidden) }
    let (value, cond) = to_write(body?.0)?;
    let v = app.store.put(&key, value, cond).await?;
    tracing::info!(key = %key.0, version = v, "put");
    Ok(Json(PutOut { version: v }))
}

async fn watch(State(app): State<App>, Query(q): Query<WatchQuery>)
    -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let s = app.store.watch(&q.prefix).map(|ch| Ok(Event::default().event(ch.name()).json_data(&ch).unwrap()));
    Sse::new(s).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}

async fn auth(State(app): State<App>, mut req: axum::extract::Request, next: Next) -> Result<Response, ApiError> {
    let tok = req.headers().typed_get::<Authorization<Bearer>>().ok_or(ApiError::Unauthorized)?;
    let who = app.cfg.who(tok.token()).ok_or(ApiError::Unauthorized)?;
    req.extensions_mut().insert(who);                     // a typed context bag
    Ok(next.run(req).await)
}

pub fn router(app: App) -> Router {
    let api = Router::new()
        .route("/v1/keys/:key", get(get_key).put(put_key).delete(delete_key))
        .route("/v1/keys", get(list_keys))
        .route("/v1/watch", get(watch))
        .route("/v1/admin/compact", post(compact))
        .layer(middleware::from_fn_with_state(app.clone(), auth));
    Router::new()
        .route("/healthz/live", get(|| async { StatusCode::OK }))
        .route("/healthz/ready", get(ready))
        .merge(api)
        .layer(TraceLayer::new_for_http().make_span_with(|r: &Request<_>| {
            let route = r.extensions().get::<MatchedPath>().map(|p| p.as_str().to_owned());
            tracing::info_span!("http", method = %r.method(), route)
        }))
        .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
        .layer(RequestBodyLimitLayer::new(2 << 20))
        .layer(TimeoutLayer::new(Duration::from_secs(30)))
        .with_state(app)
}

#[tokio::main]
async fn serve(cfg: ServerCfg) -> anyhow::Result<()> {
    tracing_subscriber::fmt().json().with_env_filter(cfg.log.clone()).init();   // a global
    let store = Engine::open(&cfg.dir, cfg.sync).await?;                         // takes the lock
    let listener = TcpListener::bind(cfg.addr).await?;
    let ready = Arc::new(AtomicBool::new(true));
    axum::serve(listener, router(App { store: store.clone(), cfg: Arc::new(cfg) }))
        .with_graceful_shutdown(shutdown(ready.clone()))   // waits forever for SSE unless you add a timeout
        .await?;
    store.close().await?;                                  // flush + fsync; skipped if anything above `?`s
    Ok(())
}

// tests: in process with tower's oneshot; over a simulated network with turmoil
#[tokio::test]
async fn put_then_get() {
    let app = router(test_app());
    let r = app.clone().oneshot(Request::put("/v1/keys/a").header("authorization", "Bearer w")
        .header("content-type", "application/json").body(r#"{"value":"x"}"#.into()).unwrap()).await.unwrap();
    assert_eq!(r.status(), 200);
    /* ... */
}

#[test]
fn client_retries_through_resets() -> turmoil::Result {
    let mut sim = turmoil::Builder::new().fail_rate(0.05).build();   // seeded by RNG option
    sim.host("server", || async { axum::serve(turmoil_listener().await?, router(test_app())).await?; Ok(()) });
    sim.client("cli", async { /* client::put with retries ... */ Ok(()) });
    sim.run()
}
```

### 1.5 Server: the honest comparison

| | Ren (recommended) | Rust (axum) |
|---|---|---|
| Routes | one `match`; exhaustive; 405 arms by hand | a table of method routers; 405 automatic |
| Path params | `try Key.parse(k)` in each arm (4 times) | `Path<Key>` extractor once per handler signature |
| Body | `req.bytes() \|> try json.decode<PutBody> \|> try to_write` | `Json<PutBody>` extractor, then `to_write` |
| Query | `http.query<ListQuery>(req)` (not designed) [F#8] | `Query<ListQuery>` |
| Auth | a function that runs the rest; `who` is a block parameter | `from_fn` layer; `who` in `Extensions`, a typed any-map, read back by type |
| Errors → status | one `match`; a new engine tag breaks the build | `IntoResponse` + `From`; a new variant breaks the `From`, but `?` on anything with a `From` compiles silently |
| SSE | `http.stream` and a heartbeat race by hand | `Sse` + `KeepAlive` built in |
| Shutdown | `until:` + `drain:`; the engine's `finally` runs on every exit | `with_graceful_shutdown`; no drain deadline; `store.close()` skipped on an early `?` |
| Logging | `Log` is a dependency: every `pub fn` on the request path writes `uses Log` | `tracing` global subscriber; nothing in signatures |
| Route label on spans | the compiler names the arm (magic, [F#1]) | `MatchedPath`, read from extensions |
| Tests in process | call `handle(cfg, req)` | `router.oneshot(req)` |
| Tests on a simulated net | `sim.net` + `sim.fs` + scheduler + clock, seeds, and a replayable journal, one runtime | turmoil: net and time only; files and the engine's fsync are real; tokio's scheduler isn't seeded |
| Lines (excluding shared types) | ~150 | ~190 |

**Where Ren is better:** the error edge is exact and the compiler holds
it (no `From` that silently routes a new error to 500); there's no
context bag; cleanup on shutdown is structural (`finally` in the wiring,
which axum programs get wrong routinely); and the tests run the network,
the disk, the clock and the scheduler from one seed, which turmoil only
half does.

**Where Rust is better:** extractors decode path, query and body by type
in the signature, so a handler states its inputs once; 405 and SSE
keep-alive are free; the route table is listable. Ren's `try
Key.parse(k)` per arm is explicit but repetitive, and §3.2 Alt A would
fix it. `uses Log` on every `pub fn` is real noise against Rust's
global `tracing`, though it's what makes logs replayable and testable as
values.

**Rules the server leans on:** 1 (PutBody, ListQuery, Problem through
shapes), 2 (`Key.parse` from path and json), 4 (`respond`), 5
(`request_id`, `authenticate`, `http.stream`, `trace.span` are
functions; `engine.open` and `log.json` are installed), 6 (body and
header limits, `drain`, `max_conns`), 7 (`Net`, `Clock`, `Fs`), 9
(spans per arm and per `Store` call). Plus language.md §5 (wiring), and
§3.1/§3.3/§3.8 of the design.

---

## 2. The client, used by the CLI

### 2.1 Ren, recommended design (§3.6)

```ren
// client.ren
import json
import http.{Request, Response}

pub type ClientCfg = {
  /// Server address
  addr: Addr = Addr.local(7400),
  token: Option<Secret<Str>>,
  /// Per attempt
  timeout: Duration = 2.s,
  /// For the whole call, retries included
  deadline: Duration = 10.s,
  retries: Int = 3,
}

pub type ClientError = ! Timeout | ConnRefused(addr: Addr) | DnsFailed(host: Str)
    | HttpProtocol(at: Int) | BodyTooLarge(limit: Int) | Unavailable
    | Unauthorized | Forbidden | Rejected(error: Str, detail: Option<Str>)
    | JsonSyntax(at: Int, expected: Str) | JsonMismatch(at: Str, expected: Str, found: Str) | JsonLimit(what: Str, limit: Int)

// one round trip, with retry and an overall deadline
fn call(c: ClientCfg, req: Request, idempotent: Bool) -> Response ! ClientError | NotFound | Conflict | StoreFull
    uses Http, Clock, Random =
  let req = match c.token
    Some(t) => req.bearer(t.reveal())
    None => req
  let tries = if idempotent then c.retries + 1 else 1                               // [F#15]
  try Async.timeout(c.deadline) fn() =>
    try retry(tries, on: Timeout | ConnRefused | Unavailable, backoff: Exp(base: 100.ms, max: 2.s)) fn() =>  // [F#15]
      let resp = try Http.send(req, timeout: c.timeout)
      match resp.status.class()
        Success => resp
        _ => fail_with(resp)

// statuses to tags: the client's edge (rule 4, the other way round)
fn fail_with(r: Response) -> Never ! ClientError | NotFound | Conflict | StoreFull =
  let p = attempt json.decode<Problem>(r.body.bytes()) orelse Problem { error: "", at: None, detail: None }
  match r.status.code()
    401 => fail Unauthorized
    403 => fail Forbidden
    404 => fail NotFound
    409 => fail Conflict
    503 => fail Unavailable
    507 => fail StoreFull
    _ => fail Rejected(p.error, p.detail)

pub fn get(c: ClientCfg, k: Key) -> Option<Entry> ! ClientError | Conflict | StoreFull uses Http, Clock, Random =
  match call(c, Request.get(c.url("/v1/keys/{http.escape_segment(k.str())}")), idempotent: true)
    resp => Some(try to_entry(try json.decode<EntryOut>(resp.body.bytes())))
    fail NotFound => None

pub fn put(c: ClientCfg, k: Key, v: Bytes, cond: Cond) -> Version ! ClientError | NotFound | Conflict | StoreFull
    uses Http, Clock, Random =
  let body = PutBody { value_b64: Some(base64.encode(v)), if_version: cond.version(), if_absent: cond == IfAbsent }
  // a conditional put is idempotent enough to retry: a lost reply to a first
  // success makes the retry answer Conflict, which the caller then sees  [F#16]
  let resp = try call(c, Request.put(c.url("/v1/keys/{k.str()}"), json.encode(body)), idempotent: cond != Always)
  Version.parse((try json.decode<PutOut>(resp.body.bytes())).version) orelse fail HttpProtocol(0)

pub fn compact(c: ClientCfg) -> Compacted ! ClientError | NotFound | Conflict | StoreFull uses Http, Clock, Random =
  let resp = try call(c, Request.post(c.url("/v1/admin/compact"), ""), idempotent: true)
  try json.decode<Compacted>(resp.body.bytes())

// a watch: an SSE reader, yielded as changes (11c generators)
pub gen fn watch(c: ClientCfg, prefix: Str) -> Change ! ClientError uses Http, Clock =
  var events = try Http.stream(Request.get(c.url("/v1/watch?prefix={http.escape_query(prefix)}")))
  for ev in try &events.sse()
    if ev.name != "" then yield try json.decode<Change>(ev.data)
```

### 2.2 The alternative: `http.client<D>` (§3.7's alternative)

If `call` typing lands in 12, the API is a dependency and the client is
one line; the server exposes the same dependency:

```ren
pub dep Kv =
  get: fn(k: Key) -> Option<Entry> ! NotFound
  put: fn(k: Key, v: Bytes, c: Cond) -> Version ! Conflict | StoreFull
  compact: fn() -> Compacted ! Busy

// client
with retry<Kv>(3, on: Timeout) over http.client<Kv>(c.addr, token: c.token) in
  let e = try Kv.get(key)

// server
http.serve(cfg.addr) fn(req) => http.expose<Kv>(req)     // routes derived from the dep's shape
```

That deletes `api.ren`, `routes` and `client.ren` for the RPC part, and
the CLI becomes `uses Kv`. It loses the hand-designed REST surface
(paths, statuses, the SSE stream), so for flottning's public API it
would sit beside the `match`, not replace it.

### 2.3 Rust twin (reqwest + backon)

```rust
pub struct Client { http: reqwest::Client, cfg: ClientCfg }

impl Client {
    async fn call(&self, rb: impl Fn() -> RequestBuilder, idempotent: bool) -> Result<Response, ClientError> {
        let attempt = || async {
            let r = rb().bearer_auth_opt(&self.cfg.token).timeout(self.cfg.timeout).send().await
                .map_err(ClientError::from_reqwest)?;
            match r.status() {
                s if s.is_success() => Ok(r),
                StatusCode::SERVICE_UNAVAILABLE => Err(ClientError::Unavailable),
                _ => Err(ClientError::from_problem(r).await),
            }
        };
        let policy = ExponentialBuilder::default().with_max_times(if idempotent { self.cfg.retries } else { 0 })
            .with_jitter();
        tokio::time::timeout(self.cfg.deadline, attempt.retry(policy).when(ClientError::is_transient)).await
            .map_err(|_| ClientError::Timeout)?
    }
    pub async fn get(&self, k: &Key) -> Result<Option<Entry>, ClientError> {
        match self.call(|| self.http.get(self.url(&format!("/v1/keys/{}", k))), true).await {
            Ok(r) => Ok(Some(r.json::<EntryOut>().await?.try_into()?)),
            Err(ClientError::NotFound) => Ok(None),
            Err(e) => Err(e),
        }
    }
    // put, compact, watch (eventsource-stream) ...
}
```

**Comparison.** About the same length. Rust's `when(is_transient)` is a
predicate over any error, including "503 with this body"; Ren's `on:`
is a set of tags, so a status must first become a tag (`Unavailable`),
which is the right discipline but means the client always has its own
`fail_with` edge. Jitter in Rust is `rand::thread_rng`, unseeded; in Ren
it comes from `Random`, so the retry timing is part of the seed and the
journal. The Rust client's test against a server needs turmoil plus a
hand-rolled `connector`; Ren's is the server test above.

**Rules the client leans on:** 4 (statuses to tags in `fail_with`), 5
(`retry` and `Async.timeout` run blocks), 6 (`timeout`, `max_body`,
`deadline` defaults), 7 (`Http` is a dependency, so `sim.net` and the
journal see it).

---

## 3. `flot`, the CLI

### 3.1 Ren, recommended design (§4, §5)

```ren
// main.ren
import cli
import config
import json
import fmt

/// flot: flottning's command line
pub type Flot = {
  /// Config file (default: ./flottning.json if it exists)
  config: Option<Path>,
  /// Print json instead of text
  json: Bool = false,
  /// Log debug events to stderr
  verbose: Bool = false,
  cmd: Cmd,                                     // the one sum field is the subcommand  [F#2]
}

pub type Cmd =
  /// Create a data directory and a config file
  | Init { dir: Path = Path.of("data"), force: Bool = false }
  /// Write a value
  | Put { key: Key, value: Str, if_version: Option<Int>, if_absent: Bool = false, addr: Option<Addr> }
  /// Read a value
  | Get { key: Key, addr: Option<Addr> }
  /// Merge the data directory's tables
  | Compact { online: Bool = false, dir: Option<Path>, addr: Option<Addr> }
  /// Run the server
  | Serve { addr: Option<Addr>, dir: Option<Path>, sync: Option<SyncMode> }      // overrides only  [F#3]

let CLI = cli.spec<Flot>(
  positional: [("Put", "key"), ("Put", "value"), ("Get", "key")],
  short: [("json", "j"), ("verbose", "v")],
)

/// The config file: one record for both faces
pub type FileCfg = { server: ServerCfg, client: ClientCfg = ClientCfg {} }

pub fn main() uses Os, Console, Fs, Net, Async, Clock, Random =
  cli.run(CLI) fn(args) =>                                  // --help, --version, usage errors → exit 2
    Os.exit(report(args, attempt run(args)))                // a whole error can't be bound, so: attempt  [F#10]
```

The flag-to-config layering. The `Serve` case holds only overrides, all
`Option`, and they become the last layer:

```ren
fn load(args: Flot) -> FileCfg ! ConfigMissing(field: Str)
    | ConfigMismatch(field: Str, from: config.Source, expected: Str, found: Str) | NoSuchFile(path: Path)
    uses Fs, Os =
  let file = match args.config
    Some(p) => [config.File(p)]
    None => if Fs.exists(Path.of("flottning.json")) then [config.File(Path.of("flottning.json"))] else []
  let flags = match args.cmd
    Serve { addr, dir, sync } => [config.Value(at: "server", ServeOverrides { addr, dir, sync })]    // None = not given  [F#3]
    Put { addr, .. } | Get { addr, .. } | Compact { addr, .. } => [config.Value(at: "client", ClientOverrides { addr })]
    Init { .. } => []
  try config.load<FileCfg>([config.Defaults] ++ file ++ [config.Env(prefix: "FLOTT_")] ++ flags)
  // env names: FLOTT_SERVER__ADDR, FLOTT_CLIENT__TOKEN  [F#4]

type ServeOverrides  = { addr: Option<Addr>, dir: Option<Path>, sync: Option<SyncMode> }
type ClientOverrides = { addr: Option<Addr> }
```

The commands, one function each, human and json output from the same
value:

```ren
fn run(args: Flot) ! Failure uses Os, Console, Fs, Net, Async, Clock, Random =
  match args.cmd
    Init { dir, force } => try init(args, dir, force)
    Serve { .. } =>
      let cfg = try load(args)
      try server.serve(cfg.server)
    Get { key, .. } =>
      let c = (try load(args)).client
      let e = try with http.client() in client.get(c, key) orelse fail NotFound
      out(args, entry_out(e)) fn(e) => Console.print(Str.from_utf8_lossy(e.value))
    Put { key, value, if_version, if_absent, .. } =>
      let c = (try load(args)).client
      let cond = try to_write(PutBody { value: Some(value), if_version, if_absent }).1
      let v = try with http.client() in client.put(c, key, value.bytes(), cond)
      out(args, PutOut { version: v.int() }) fn(p) => Console.print("{key.str()} = version {p.version}")
    Compact { online: true, .. } =>
      let c = (try load(args)).client
      let r = try with http.client() in client.compact(c)
      out(args, r) fn(r) => print_compacted(r)
    Compact { online: false, dir, .. } =>
      let d = dir orelse (try load(args)).server.dir
      let r = try with engine.open(d, sync: Every) in                      // fails Locked if a server holds it
        try fmt.progress("compacting", when: Console.is_tty()) fn(p) =>    // stderr, only on a TTY
          try Store.compact(None)
      out(args, r) fn(r) => print_compacted(r)

// one value, two renderings: json by shape, text by hand  [F#11]
fn out<T>(args: Flot, x: T, human: fn(x: T)) uses Console =
  if args.json then Console.print(json.encode(x)) else human(x)

fn print_compacted(r: Compacted) uses Console =
  Console.print(fmt.table([
    ["tables in", "{r.tables_in}"], ["tables out", "{r.tables_out}"], ["freed", fmt.bytes(r.bytes_freed)],
  ]))

fn init(args: Flot, dir: Path, force: Bool) ! NoSuchFile(path: Path) | Exists(path: Path) | DiskFailed(path: Path)
    uses Fs, Console, Random =
  let file = args.config orelse Path.of("flottning.json")
  if Fs.exists(file) and not force then fail Exists(file)
  try Fs.mkdir(dir)
  try engine.create(dir)
  let token = Random.token(32)
  // a Secret has no encoding (§1.4), so the file is written from an edge type with plain strings
  try Fs.write(file, json.encode(InitFile { server: { dir: dir.str(), admin_token: token, write_tokens: [token] } }, pretty: true))
  try Fs.chmod(file, 0o600)
  out(args, { file: file.str(), admin_token: token }) fn(_) =>
    Console.print("wrote {file}; admin token {token} (shown once)")

type InitFile = { server: InitServer }
type InitServer = { dir: Str, admin_token: Str, write_tokens: Array<Str> }
```

Errors to exit codes, one `match` (rule 4). `Failure` is the union of
everything `run` can fail with, named once:

```ren
type Failure = ! ClientError | NotFound | Conflict | StoreFull | Locked | Busy | Exists(path: Path)
  | NoSuchFile(path: Path) | DiskFailed(path: Path) | AddrInUse(addr: Addr) | BadBody(at: Str, reason: Str)
  | ConfigMissing(field: Str) | ConfigMismatch(field: Str, from: config.Source, expected: Str, found: Str)

// Ren can't bind a whole error, so reporting is a match over `attempt`'s Result  [F#10]
fn report(args: Flot, r: Result<Unit, Failure>) -> Int uses Console =
  let (code, msg) = match r
    Ok(_) => (0, "")
    Err(NotFound) => (3, "no such key")
    Err(Conflict) => (4, "the version didn't match")
    Err(Unauthorized) | Err(Forbidden) => (77, "not allowed: check client.token")       // EX_NOPERM
    Err(Timeout) | Err(ConnRefused(_)) | Err(Unavailable) | Err(DnsFailed(_)) =>
      (69, "can't reach the server at {cfg_addr(args)}")                               // EX_UNAVAILABLE
    Err(Locked) => (75, "the data directory is in use; is a server running? try --online")
    Err(ConfigMissing(f)) => (78, "config: {f} is required")                           // EX_CONFIG
    Err(ConfigMismatch(f, from, expected, found)) => (78, "config: {f} from {from}: expected {expected}, found {found}")
    Err(BadBody(at, reason)) => (2, "--{at}: {reason}")
    Err(Exists(p)) => (1, "{p} exists; pass --force to overwrite")
    Err(NoSuchFile(p)) => (66, "no such file {p}")
    Err(StoreFull) | Err(DiskFailed(_)) | Err(Busy) | Err(AddrInUse(_)) => (1, show(r))
    Err(Rejected(e, d)) => (1, "server said {e}: {d orelse ""}")
    Err(HttpProtocol(_)) | Err(BodyTooLarge(_)) | Err(JsonSyntax(..)) | Err(JsonMismatch(..)) | Err(JsonLimit(..)) =>
      (70, "the server's reply was malformed: {show(r)}")                              // EX_SOFTWARE
  if args.json then Console.error(json.encode(Problem { error: tag_name(r), at: None, detail: Some(msg) }))
  else Console.error("flot: {msg}")
  code
```

`report`'s `match` lists every tag in `Failure`; adding one to the
engine breaks this build until it has an exit code.

### 3.2 Ren: the CLI's tests

```ren
test "get --json prints the entry as json" =
  with test_os(["get", "a", "--json"], env: [("FLOTT_CLIENT__TOKEN", "r")]), mem_fs([]), sim.net(),
       mem_store_with([("a", "x")]), log.test() in
    try Async.scope fn(s) =>
      s.spawn fn() => let _ = attempt http.serve(Addr.local(7400)) fn(req) => server.handle(test_cfg(), req)
      main()
      SimNet.signal(Signal.term)
  assert TestConsole.out() == "{\"key\":\"a\",\"value\":\"x\",\"version\":1}\n"
  assert TestOs.exit_code() == 0

// the in-process client: a handler may call a function, it just can't hold one
test handler in_process(cfg: ServerCfg) for Http uses Store, Log, Clock =
  send(req, ..) => server.handle(cfg, req)

test "a missing key exits 3, and says so on stderr" =
  with test_os(["get", "nope"]), mem_fs([]), in_process(test_cfg()), mem_store(), log.test() in
    main()
  assert TestConsole.errors() == ["flot: no such key"]
  assert TestOs.exit_code() == 3

test "a flag beats env, which beats the file" =
  with test_os(["serve", "--addr", "127.0.0.1:9000"], env: [("FLOTT_SERVER__ADDR", "127.0.0.1:8000")]),
       mem_fs([("flottning.json", "{\"server\":{\"addr\":\"127.0.0.1:7000\",\"admin_token\":\"t\"}}")]) in
    let args = try cli.parse<Flot>(CLI, TestOs.args()).run()
    assert (try load(args)).server.addr == Addr.of("127.0.0.1", 9000)

test "a misspelled flag suggests the right one and exits 2" =
  with test_os(["get", "a", "--jsno"]), mem_fs([]) in
    main()
  assert TestConsole.errors()[0] == "error: unknown flag --jsno; did you mean --json?"
  assert TestOs.exit_code() == 2

test "help comes from the doc comments" =
  assert cli.parse<Flot>(CLI, ["put", "--help"]) == Ok(Help(golden("help/put.txt")))
```

### 3.3 The alternative where it changes the code

**§4 Alt A, `main`'s by-name parameters** doesn't fit: flot has
subcommands, so it falls back to the ADT. **§5 Alt A, env only**, would
drop `load`'s file and flag layers and fail the "config file plus env
plus flags" requirement. Neither changes the recommendation.

The one real alternative the CLI argues for is **not in the design**:
let a `cli` field be read *through* config (clap's `env =`), so `Serve`
holds a full `ServerCfg` and the layers are given to `cli.run`:

```ren
let CLI = cli.spec<Flot>(..., layers: fn(args) => [Defaults, File(args.config), Env(prefix: "FLOTT_")])
// | Serve(cfg: ServerCfg)    -- cli fills what flags don't from the layers, then checks it's complete
```

It removes `ServeOverrides`, `ClientOverrides` and `load` (~20 lines),
but stores a block in a top-level `let` (forbidden) and couples `cli`
to `config`. Rejected; see [F#3] for the smaller rule that makes the
explicit version shorter.

### 3.4 Rust twin (clap 4 derive + figment + anyhow-free errors)

```rust
#[derive(Parser)]
#[command(name = "flot", version, about = "flot: flottning's command line")]
struct Flot {
    /// Config file (default: ./flottning.json if it exists)
    #[arg(long, global = true, env = "FLOTT_CONFIG")]
    config: Option<PathBuf>,
    /// Print json instead of text
    #[arg(short, long, global = true)]
    json: bool,
    #[arg(short, long, global = true)]
    verbose: bool,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create a data directory and a config file
    Init { #[arg(long, default_value = "data")] dir: PathBuf, #[arg(long)] force: bool },
    /// Write a value
    Put { key: Key, value: String, #[arg(long)] if_version: Option<u64>,
          #[arg(long, conflicts_with = "if_version")] if_absent: bool, #[command(flatten)] client: ClientFlags },
    Get { key: Key, #[command(flatten)] client: ClientFlags },
    Compact { #[arg(long)] online: bool, #[arg(long)] dir: Option<PathBuf>, #[command(flatten)] client: ClientFlags },
    Serve(ServeFlags),
}

#[derive(Args, Serialize)]
struct ServeFlags {
    #[arg(long)] #[serde(skip_serializing_if = "Option::is_none")] addr: Option<SocketAddr>,
    #[arg(long)] #[serde(skip_serializing_if = "Option::is_none")] dir: Option<PathBuf>,
    #[arg(long, value_enum)] #[serde(skip_serializing_if = "Option::is_none")] sync: Option<SyncFlag>,
}

fn load(a: &Flot) -> Result<FileCfg, figment::Error> {
    let mut f = Figment::from(Serialized::defaults(FileCfg::default()));
    if let Some(p) = a.config.as_ref().or(Some(&"flottning.json".into())).filter(|p| p.exists()) {
        f = f.merge(Json::file(p));
    }
    f = f.merge(Env::prefixed("FLOTT_").split("__"));
    if let Cmd::Serve(s) = &a.cmd { f = f.merge(Serialized::default("server", s)); }
    f.extract()
}

#[derive(thiserror::Error, Debug)]
enum Failure { #[error("no such key")] NotFound, #[error(transparent)] Client(#[from] ClientError),
               #[error(transparent)] Config(#[from] figment::Error), #[error("data directory in use")] Locked, /* ... */ }
impl Failure { fn code(&self) -> u8 { match self { Failure::NotFound => 3, /* exhaustive, if written */ _ => 1 } } }

fn main() -> ExitCode {
    let a = Flot::parse();                    // exits 2 on usage errors; --help from doc comments
    let rt = tokio::runtime::Runtime::new().unwrap();
    match rt.block_on(run(&a)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => { if a.json { eprintln!("{}", json!({"error": e.to_string()})) } else { eprintln!("flot: {e}") }
                    ExitCode::from(e.code()) }
    }
}

// tests: assert_cmd + a real temp dir + a real server on a random port, or trycmd golden files
#[test]
fn missing_key_exits_3() {
    let srv = spawn_test_server();            // real sockets, real files
    Command::cargo_bin("flot").unwrap().args(["get", "nope"]).env("FLOTT_CLIENT__ADDR", srv.addr())
        .assert().code(3).stderr("flot: no such key\n");
}
```

### 3.5 CLI: the honest comparison

| | Ren (recommended) | Rust (clap + figment) |
|---|---|---|
| Command type | `Flot` record + `Cmd` sum, doc comments as help | the same, plus `#[arg(...)]` on most fields |
| Positionals, shorts | one `cli.spec` table, checked at build time | per-field attributes |
| Global flags | the record's non-sum fields [F#2] | `global = true` |
| Flags over config | an `Option` overrides record per section, merged by name | a `Serialize` flags struct with `skip_serializing_if` on every field; same duplication, noisier |
| Env | derived names `FLOTT_SERVER__ADDR` | figment `split("__")`, the same names |
| Payload sums from text (`--sync group:2ms`) | needs a text `parse` on a non-opaque type [F#5] | `value_enum` for unit enums; a `FromStr` impl otherwise |
| Output | `out(args, x, human)`: json derived, text by hand | the same, with `serde_json::to_string` |
| Exit codes | one exhaustive `match` on `attempt`'s `Result`, ~20 arms | `thiserror` + a `code()` match that usually ends in `_ => 1` |
| Tests | `test_os`, `mem_fs`, `sim.net`, captured console, in-process `Http` handler: no processes, no ports, deterministic | `assert_cmd` spawns the binary; real ports and temp dirs; `trycmd` for goldens |
| Lines | ~170 | ~150 |

**Where Ren is better:** tests (the CLI, its config file, the network
and the server run in one process from one seed, with no ports or temp
dirs); the exit-code `match` can't silently fall through to 1 for an
error added later; args, env and the file are journaled, so a bug
report's journal replays the exact config.

**Where Rust is better:** clap's `env = "X"` and `global = true` are
local and obvious; Ren needs a record-with-one-sum rule and a separate
overrides type. Rust's `?` with `#[from]` makes `run` shorter, at the
cost of a `_ => 1`. clap and figment are mature: completions, value
hints, `conflicts_with`. Ren's `conflicts_with` is `to_write` by hand,
reused from the server, which is arguably better (one rule, two faces).

**Rules the CLI leans on:** 1 (`Flot`, `Cmd`, `FileCfg` through shapes;
`cli.spec` and `config.load` settings records), 2 (`Key.parse` from a
positional, `Addr.parse` and `Path` from flags), 3 (defaults and doc
comments), 4 (`report`), 5 (`cli.run`, `fmt.progress` run blocks;
`http.client()` and `engine.open` are installed), 6 (client timeouts),
7 (`Os.raw_args`, `Os.env`, `Fs.read` are dependency reads; journaled),
and §1.4 `Secret` (tokens).

---

## 4. Where the design felt magic, verbose, or needed a special case

Ordered by how much each would change the code. Each has a proposed fix
that keeps to the rules.

**[F#1] Magic: "the compiler names each arm" (§3.2).** Which `match`?
`serve` gets a block; `routes` is two calls down, inside `respond` and
`authenticate`. For the arm's name to reach the request span, the
compiler must pick *a* match on `req.segments()` somewhere below `serve`
and thread its arm out. That's action at a distance. **Fix:** an
explicit marker, `match http.route(req)`, where `http.route(req) ->
(Method, Array<Str>)` is an ordinary function the compiler recognises:
the arms of a `match` on it are named, and the name is set on the
request's span when an arm is taken. One marked match per request, an
error for two. Or take §3.2 Alt A, where the arm is a constructor and
the name is data.

**[F#2] Special case: global flags.** §4 maps a sum to subcommands and
a record to flags, but every real CLI has both (`flot --json get a`).
**Fix, one rule:** "a record with exactly one field whose type is a sum
and has no default: its other fields are global flags, accepted before
or after the subcommand; the sum is the subcommand". clap needs
`global = true` and `#[command(subcommand)]` for the same thing.

**[F#3] Verbose: flags over config need a second type.** `Serve(cfg:
ServerCfg)` from §4's example can't work with §5's layering: `cli`
would demand `--admin-token` because the field has no default, though
the file has it. So `Serve` holds `Option` overrides and each section
gets an `XOverrides` type, repeating field names and types. **Fix, two
small rules:** (a) `config.Value(at:, x)` merges any record **by field
name**, and `None` means "not given" (the same matching-by-name as the
journal, §1.3); (b) `cli` accepts `Option<T>` fields as optional flags,
which it already does. That makes the override types legal and one line
each. A type-level `Partial<T>` would delete them but is a type former
Ren doesn't have; don't add it.

**[F#4] Ugly: nested env names `FLOTT_SERVER__ADDR`.** One file with two
sections forces a section prefix on every env var. **Fix:** `File(p,
at: "server")` and `Value(at:)`, so a program can load `ServerCfg`
directly with flat `FLOTT_ADDR`. It's a settings field, not a new
mechanism.

**[F#5] Special case: sums with payloads, `Addr`, and `Duration` from
text.** `--sync group:2ms`, `FLOTT_SYNC=every`, `--addr
127.0.0.1:9000`, `timeout: "2s"` in json. Rule 2 says only an opaque
type's `parse` is a hook; `SyncMode` is a sum and `Addr` a record, so
text sources (flags, env, query, path segments) can't read them.
**Fix, one rule:** "a text source reads a type through its `pub fn
parse(Str)` if it has one, else through its shape". Rule 2 becomes
"`parse` is the only validation hook, and the only text hook". Plus a
decision on the prim encodings in json: `Duration` as `"2ms"`, `Time`
as RFC 3339, `Decimal` as a json number, `Bytes` as base64 (stated once
in `json`'s docs).

**[F#6] Verbose: `try Key.parse(k)` in each arm.** Four arms repeat it,
and Rust's `Path<Key>` says it once. It's explicit and greppable, so it
stays for 12a; §3.2 Alt A removes it in 12b+.

**[F#7] Hand-written 405 arms.** `(_, ["v1", "keys", _]) =>
method_not_allowed([Get, Put, Delete])` repeats the method list, and
forgetting it gives 404 for a wrong method. **Fix:** with [F#1]'s
`http.route`, the compiler knows the arms, so `serve` can answer 405
with `Allow` for a path that matched another method's arm. Or accept it.

**[F#8] Gap: query strings.** The design decodes json bodies and cli
flags by shape but says nothing on `?prefix=a&limit=10`. **Fix:**
`http.query<T>(req)` with exactly `cli`'s flag mapping (field names,
`Bool` as a switch, `Array` repeats, `Option` optional, [F#5]'s
`parse`). Same for `application/x-www-form-urlencoded`. One more
consumer of one walk, not a new rule.

**[F#9] Verbose: the error edge grows with every validating type.** The
convention keeps `Invalid` payload-free, so `BadKey(reason)`,
`BadBody(at, reason)` and `BadQuery(at, reason)` are separate tags,
each a `respond` arm, and the server's `routes` signature lists 15 tags.
It's exact and the compiler holds it, which is the point, but it's the
longest thing in the server. **Fix:** a prelude tag with a payload for
the most common edge case is against the convention; instead name the
set once, `pub type ApiError = ! ...`, in `api.ren`, which errors.md
already allows. Recommend it in the stdlib's style guide.

**[F#10] Inconsistency: §3.5's `fail Invalid | JsonMismatch(..) as e =>
problem(422, e)` and `http.status_of(tag)`.** errors.md: "a `fail`
pattern ... never binds a whole error to a variable", and tags aren't
values. So neither can be written. **Fix:** the edge works on
`attempt`'s `Result`, as `report` does; `http.status_of` takes a
`Result<T, ! NotFound | Invalid | Conflict | Forbidden | Timeout>`
(a declared `Result` may hold more than the call fails with, errors.md),
so it covers only the prelude words and the app's `match` still lists
its own. Also: `Os.exit(report(args, attempt run(args)))` is the CLI
idiom; `cli.run`'s block should allow `-> Int` as the exit code to
avoid `Os.exit` inside a block.

**[F#11] Verbose: human output is by hand.** json is derived; text is a
block per command. `show` prints `Compacted { tables_in: 3, ... }`,
which isn't human output. Fine: Rust is the same. A `fmt.record(x)`
that lays out a record as aligned "doc-comment: value" lines from its
shape would cover most commands; 12b.

**[F#12] Gap: long streams and shutdown, and heartbeats.** An SSE
stream is a request in flight, so every shutdown waits the full
`drain` for it and then cancels it, and clients see a cut, not an end.
**Fix:** `http.stream`'s `out` gets `out.closing()`, a step that
finishes when shutdown starts, raceable with the reader's step
(streams.md rule 7), so the stream writes a final event and returns.
And `http.stream(..., heartbeat: 15.s)` as a by-name parameter does the
heartbeat race inside `http`, which removes the `Async.timeout` loop.

**[F#13] Alt A's table names constructors as strings.** If §3.2 Alt A
is taken, prefer `(Get, "/v1/keys/{key}", GetKey)` with constructors as
values. A constructor with fields is a function, which a top-level value
can't hold; so either a constructor *name* is a new kind of build-time
value, or strings checked at build time. Decide before 12b+.

**[F#14] Noise: `uses Log, Clock` on every `pub fn` on the request
path.** Logs are a dependency, so they're replayable and testable as
values, but a `pub` function writes its `uses` in full, and nearly
every one logs. Accept: it's the price of rule 9, and private functions
infer it. Note it for the services-stage review of "how long are
real signatures".

**[F#15] Gap: `retry` has no backoff, and `on:` can't pick by payload.**
The built `retry(n, on:)` retries at once. **Fix:** a by-name
`backoff: Backoff = Exp(base: 100.ms, max: 2.s, jitter: Full)`, a
policy as data (language.md §6), with jitter from `Random` so seeds
cover it. For statuses, the client's `fail_with` turns 503 into
`Unavailable` first; that's right, not a gap.

**[F#16] Not the design's fault, but surfaced by sim: retrying a
conditional put.** A reset after the server applied `IfAbsent` makes the
retry answer `Conflict`. `sim.net(reset:)` with 10,000 seeds finds it in
the first hundred. Fix in flottning's API: an `Idempotency-Key` header
the engine remembers per key for a minute. That's an argument *for*
the simulation story, which no other stack here makes this cheap.

**What felt right and needs no change:** request middleware as a
function with the request-scoped data as a block parameter (no context
bag); routes as a `match` with exhaustiveness; the error edge as one
`match`; `http.stream` returning a `Sent` token; `with live(cfg) in
http.serve(...)` as init, run and shutdown, with the engine's flush in a
`finally` that runs on every exit; `Secret` refusing to encode, which
forced `init` to name its edge type; and the in-process client, `test
handler in_process(cfg) for Http = send(req, ..) => server.handle(cfg,
req)`, which shows stdlib.md's `mem_http(routes)` was never needed: a
handler can't hold a block, but it can call a function.

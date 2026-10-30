# Programs: flottning's API end to end, in Ren and in Effect v4

Written 2026-10-29. Nothing in the repo is edited. The Ren code uses
[draft-formats.md](draft-formats.md) and [draft-shapes.md](draft-shapes.md)
as written, plus the owner's next step: a dependency is a protocol. The
Effect code is v4 only (`/tmp/ren-refs/effect`, `packages/effect`
4.0.6): `effect/http-api`, `effect/cli`, `Schema`, `Config`.

flottning here is one binary, `flot`: a single-node key-value store with
an HTTP server, a CLI client, and its own engine behind `dep Store`
([stage12/programs-storage.md](../stage12/programs-storage.md)). The
engine is not shown. Simulation is kept to one fault, a host that is
down; the owner designs sim later.

Things the drafts don't fix, assumed here, are marked **[assumed]**.
Every place either version felt awkward is marked **[R#n]** (Ren) or
**[E#n]** (Effect) and collected in part 3.

## Contents

- [Part 1: Ren](#part-1-ren)
  - [1.1 The domain](#11-the-domain)
  - [1.2 The API: two dependencies](#12-the-api-two-dependencies)
  - [1.3 Looks: json, REST, statuses, cli, config](#13-looks-json-rest-statuses-cli-config)
  - [1.4 The server](#14-the-server)
  - [1.5 The client](#15-the-client)
  - [1.6 The CLI](#16-the-cli)
  - [1.7 Tests](#17-tests)
  - [1.8 v1 to v2, served side by side](#18-v1-to-v2-served-side-by-side)
- [Part 2: Effect v4](#part-2-effect-v4)
- [Part 3: Comparison](#part-3-comparison)

---

# Part 1: Ren

Files: `kv.ren` (domain), `api.ren` (deps), `wire.ren` (looks and
settings), `server.ren`, `main.ren`, `*_test.ren`. Sections 1.1 to 1.7
are the first release, v1. Section 1.8 is the change to v2.

## 1.1 The domain

```ren
// kv.ren

/// A key: 1 to 512 bytes of UTF-8, no control characters
pub type Key = opaque Str
  pub fn parse(s: Str) -> Key ! BadKey(reason: Str) =
    if s.len() == 0 then fail BadKey("empty")
    if s.len() > 512 then fail BadKey("longer than 512 bytes")
    if s.chars().any(fn(c) => c.is_control()) then fail BadKey("control character")
    Key(s)
  pub fn repr(self) -> Str = self

/// A key's version: 1 at its first write, one more at each write
pub type Version = opaque Int
  pub fn parse(n: Int) -> Version ! BadVersion =
    if n < 1 then fail BadVersion else Version(n)
  pub fn repr(self) -> Int = self
  pub fn first() -> Version = Version(1)
  pub fn next(self) -> Version = Version(self + 1)

/// When a write may happen
pub type Expect =
  | Any                        // always
  | Absent                     // only if the key has no value
  | At { version: Version }    // only if the key is at this version

  /// "any", "absent" or a version number: how it reads from a flag, a query or json
  pub fn parse(s: Str) -> Expect ! BadExpect =
    match s
      "any" => Any
      "absent" => Absent
      n => At { version: try Version.parse(try Int.parse(n)) } orelse fail BadExpect
  pub fn repr(self) -> Str =
    match self
      Any => "any"
      Absent => "absent"
      At { version } => "{version.repr()}"

pub type Entry = { key: Key, value: Bytes, version: Version }

/// One page of a listing. `next` is where the following page starts.
pub type Page = { entries: Array<Entry>, next: Option<Key> }

pub type Compacted = { tables_in: Int, tables_out: Int, bytes_freed: Int }
```

- `Key` and `Version` are opaque. Every medium reads them through
  `parse`: a path segment, a query value, a flag, a json field, a test
  generator. That is decision 1 doing all of it.
- `Expect` is a sum with a payload, so text media (query, flags) can't
  read it by structure. Giving it `parse(Str)` fixes that. It also means
  json reads `"expect": "3"`, a string, because `parse`/`repr` beats
  structure for every library **[R#9]**.

## 1.2 The API: two dependencies

```ren
// api.ren
import std.remote.{Why}      // Refused | Timeout | Decode(Problem) | Protocol | Version | Server [assumed]

/// The key-value API. It can be remote, so every operation can be Unavailable.
pub dep Keys =
  /// Read a value
  get: fn(key: Key) -> Entry ! NotFound | Unavailable(why: Why)
  /// Write a value, if the key is where you expect
  put: fn(key: Key, value: Bytes, expect: Expect = Any) -> Version
       ! Conflict(current: Option<Version>) | Unavailable(why: Why)
  /// Remove a value, if the key is where you expect
  delete: fn(key: Key, expect: Expect = Any)
       ! NotFound | Conflict(current: Option<Version>) | Unavailable(why: Why)
  /// List keys in order, a page at a time
  list: fn(prefix: Str = "", after: Option<Key>, limit: Int = 100) -> Page
       ! BadLimit | Unavailable(why: Why)

/// Operations for whoever runs the server
pub dep Admin =
  /// Merge the data directory's tables
  compact: fn() -> Compacted ! Busy | Unavailable(why: Why)
```

What the compiler writes from `Keys`, shown for reading. It is in no
file:

```ren
pub type Keys.Call =
  | Get { key: Key }
  | Put { key: Key, value: Bytes, expect: Expect = Any }
  | Delete { key: Key, expect: Expect = Any }
  | List { prefix: Str = "", after: Option<Key>, limit: Int = 100 }

pub type Keys.Reply =
  | Get(Entry)
  | Put(Version)
  | Delete
  | List(Page)

pub type Keys.Error = ! NotFound | Conflict(current: Option<Version>) | BadLimit | Unavailable(why: Why)
                                                                          // [assumed] draft open question 3

pub fn Keys.call(c: Keys.Call) -> Keys.Reply ! Keys.Error uses Keys
```

- The doc comments on operations become help text for the CLI and
  descriptions for any OpenAPI library.
- `Keys.call` fails with the union of every operation's errors. A
  caller that runs a `Get` must still handle `Conflict` **[R#5]**.

## 1.3 Looks: json, REST, statuses, cli, config

```ren
// wire.ren
import http.{GET, PUT, DELETE, POST}

// ---- REST: the route table is a look of Keys.Call ----

format rest for Keys.Call =
  | Get as GET"/v1/keys/\{key}"
  | Put as PUT"/v1/keys/\{key}"            // value and expect go in the json body
  | Delete as DELETE"/v1/keys/\{key}"      // expect goes in the query
  | List as GET"/v1/keys"                  // prefix, after, limit in the query

format rest for Keys.Error =
  | NotFound as 404
  | Conflict as 409
  | BadLimit as 422
  | Unavailable as 503                     // [R#3]

format rest for Admin.Call =
  | Compact as POST"/v1/admin/compact"

format rest for Admin.Error =
  | Busy as 503                            // shares 503 with Unavailable [R#2]
  | Unavailable as 503

// ---- what one release of the API is: a settings record per dep ----

let KEYS_V1 = http.api<Keys>(formats: [Keys.Call.rest, Keys.Error.rest])
let ADMIN   = http.api<Admin>(formats: [Admin.Call.rest, Admin.Error.rest])

// ---- cli: subcommands are a look of Keys.Call ----

format text for Bytes = Str via (fn(s) => s.bytes(), Str.from_utf8_lossy), lossy

format cli for Keys.Call =
  | Get as "get"
  | Put as "put": Keys.Call.Put.cli
  | Delete as "rm"
  | List as "ls"

format cli for Keys.Call.Put =
  key
  value: Bytes.text                         // a flag is text, so the value is too
  expect

// ---- config: one look of ServerCfg serves the file, env and flags ----

format file for ServerCfg =
  listen = addr                             // "listen" in json, FLOTT_LISTEN, --listen
  data = dir
  ..

let CONFIG = config.settings(env_prefix: "FLOTT_", formats: [ServerCfg.file])
```

What the wire looks like under `KEYS_V1`:

```
PUT /v1/keys/user%2F7        {"value": "eA==", "expect": "absent"}
  200                        1
  409                        {"type": "Conflict", "current": 1}
GET /v1/keys?prefix=user/&limit=2
  200                        {"entries": [{"key": "user/1", "value": "eA==", "version": 1}, ...], "next": "user/2"}
DELETE /v1/keys/a?expect=3
  204
GET /v1/keys/%00
  400                        {"type": "Invalid", "at": "key", "why": "BadKey"}     (http's decode rule)
```

- **No json look is written.** `Entry`, `Page`, `Compacted` and the
  bodies go by structure; `Bytes` is base64; `Key`, `Version` and
  `Expect` go through `repr`. A json look is only for "looks different
  here", and in v1 nothing does.
- **`KEYS_V1` is the API.** It names the looks; http finds the route
  look by its tag type (`http.Route`) and the status look by its tag
  type (`Int`) **[assumed]**. It is a top-level `let`, so the build
  checks it: every route hole is a field, no two routes overlap, every
  error has a status.
- **Fields not in the path** go in the query for `GET` and `DELETE`,
  in the body otherwise. That is http's rule, from draft-formats.
- **The value travels as base64 in a json body.** A REST API would
  send raw bytes and put `expect` in `If-Match`. Headers and per-route
  bodies are "later" in the draft **[R#7]**.
- **`Bytes.text` is `lossy`** because writing `Bytes` as a `Str` can
  meet invalid UTF-8, and a `via`'s write can't fail. The cli only reads,
  so the write side exists only to satisfy `via`.
- **`ServerCfg.file`** renames two fields. The rename feeds every
  medium: the json file says `"listen"`, env says `FLOTT_LISTEN`, a
  flag says `--listen`.

## 1.4 The server

```ren
// server.ren
import std.remote.{Why}

pub type ServerCfg = {
  /// Address the API listens on
  addr: Addr = Addr.any(7400),
  /// Data directory
  dir: Path = Path.of("data"),
  /// The token for /v1/admin
  admin_token: Secret<Str>,
  /// How long requests in flight get at shutdown
  drain: Duration = 5.s,
}

/// Keys, served by the engine
handler kv() for Keys uses Store, Log =
  get(key) =>
    match Store.get(key)
      Some(e) => e
      None => fail NotFound
      fail Disk(path) => internal(path)
  put(key, value, expect) =>
    match Store.put(key, value, expect)
      v => v
      fail Conflict(current) => fail Conflict(current)
      fail Disk(path) => internal(path)
  delete(key, expect) =>
    match Store.delete(key, expect)
      Some(_) => ()
      None => fail NotFound
      fail Conflict(current) => fail Conflict(current)
      fail Disk(path) => internal(path)
  list(prefix, after, limit) =>
    if limit < 1 or limit > 1000 then fail BadLimit
    match Store.scan(prefix, after, limit + 1)
      es =>
        let next = if es.len() > limit then Some(es[limit - 1].key) else None
        Page { entries: es.take(limit), next }
      fail Disk(path) => internal(path)

/// A disk failure is the server's problem: log it, tell the caller only "unavailable"
fn internal(path: Path) -> Never ! Unavailable(why: Why) uses Log =
  log.error("disk failed", path: path)
  fail Unavailable(Server)                                    // [R#3]

handler admin() for Admin uses Store, Log =
  compact() =>
    match Store.compact(None)
      c => c
      fail Busy => fail Busy
      fail Disk(path) => internal(path)

pub wiring live(cfg: ServerCfg) provides Keys, Admin, Log uses Fs, Clock ! Disk(path: Path) | Locked =
  engine.open(cfg.dir), log.json(), kv(), admin()

pub fn serve(cfg: ServerCfg) ! AddrInUse(addr: Addr) | Disk(path: Path) | Locked
    uses Net, Fs, Clock, Async, Os =
  try with live(cfg) in
    log.info("listening", addr: cfg.addr, dir: cfg.dir)
    try http.expose(cfg.addr, until: Signal.term, drain: cfg.drain, [
      http.mount<Keys>(KEYS_V1),
      http.mount<Admin>(ADMIN, auth: Bearer([cfg.admin_token])),     // [R#6]
    ])
```

- **There are no routes to write.** `http.mount<Keys>(KEYS_V1)` reads
  the route look, decodes a request into a `Keys.Call`, runs
  `Keys.call(c)` against the installed `kv()`, and encodes the
  `Keys.Reply` or the error through the status look.
- **The handler is checked against `Keys`.** A missing operation, a
  wrong argument, or an error the operation doesn't declare is a build
  error. So `Store`'s `Disk` must be turned into something `Keys`
  declares, in every arm **[R#3]**.
- **`auth: Bearer(...)`** is a policy as data. A bad token is a 401 from
  http, before the call is decoded. It isn't in `Admin.Error`, so the
  client sees it as `Unavailable(Denied)` **[assumed]** **[R#3]**.
- **Two deps on one port** need `http.mount`, a value per dep, and a
  list. The owner's sketch had `http.expose<Keys>(addr, api)` for one
  dep **[R#6]**.
- Shutdown, drain and the engine's flush in `finally` are as in
  stage12/programs-cli-server.md §1.1.

## 1.5 The client

```ren
// in any program that talks to a server
with retry<Keys>(3, on: Unavailable, backoff: Exp(base: 100.ms, max: 2.s))
     over http.client<Keys>(addr, KEYS_V1) in
  let e = try Keys.get(try Key.parse("user/7"))
  let v = try Keys.put(e.key, "y".bytes(), expect: At { version: e.version })
```

- **That's the whole client.** `http.client<Keys>` is a handler for
  `Keys`. Each operation builds a `Keys.Call`, encodes it through the
  route look, sends it, and decodes the reply or the error by status.
  The caller's code is the same as against `kv()` in-process.
- **A transport problem is `Unavailable(why)`:** `Refused`, `Timeout`,
  `Decode(problem)` for a reply that doesn't fit, `Protocol` for a
  status the look doesn't list.
- **Version check [assumed]:** the client sends the shape hash of
  `KEYS_V1` in a header, `ren-shape`, on its first request on each
  connection. A server built with a different `KEYS_V1` answers 412,
  and the client fails `Unavailable(Version)`. REST has no connect, so
  "once at connect" becomes "once per connection" **[R#8]**.
- **`retry<Keys>` retries `put` too.** A lost reply to a conditional put
  that succeeded makes the retry answer `Conflict`. Same issue as
  stage12 [F#16]; not a looks problem.

## 1.6 The CLI

```ren
// main.ren

/// flot: flottning's command line
pub type Flot = {
  /// Server address
  addr: Addr = Addr.local(7400),
  /// Config file
  config: Option<Path>,
  /// Print json instead of text
  json: Bool = false,
  cmd: Cmd,                         // the one sum field is the subcommand (stage12 F#2) [assumed]
}

pub type Cmd =
  /// Run the server
  | Serve
  /// Merge the data directory's tables, through a running server
  | Compact
  /// Read and write keys on a running server
  | Kv { call: Keys.Call }          // `flot kv get a`, not `flot get a` [R#4]

let CLI = cli.spec<Flot>(
  formats: [Keys.Call.cli, Keys.Call.Put.cli, ServerCfg.file],
  positional: [("get", "key"), ("put", "key"), ("put", "value"), ("rm", "key"), ("ls", "prefix")],
  short: [("json", "j")],
)

pub fn main() uses Os, Console, Fs, Net, Async, Clock, Random =
  cli.run(CLI) fn(args) =>                              // --help from doc comments; usage errors exit 2
    Os.exit(report(args, attempt run(args)))

fn run(args: Flot) ! Failure uses Os, Console, Fs, Net, Async, Clock, Random =
  match args.cmd
    Serve => try server.serve(try load(args))
    Compact =>
      let cfg = try load(args)
      let c = try with http.client<Admin>(args.addr, ADMIN, token: Some(cfg.admin_token)) in
        try Admin.compact()
      out(args, c) fn(c) => Console.print("freed {fmt.bytes(c.bytes_freed)}")
    Kv { call } =>
      let r = try with retry<Keys>(3, on: Unavailable) over http.client<Keys>(args.addr, KEYS_V1) in
        try Keys.call(call)                             // one line for every operation
      out(args, r) fn(r) => print_reply(r)

fn load(args: Flot) -> ServerCfg ! ConfigMissing(field: Str) | ConfigMismatch(field: Str, expected: Str, found: Str)
    uses Fs, Os =
  let file = args.config orelse Path.of("flottning.json")
  try config.load<ServerCfg>([config.Defaults, config.File(file, optional: true), config.Env], CONFIG)

fn print_reply(r: Keys.Reply) uses Console =
  match r
    Get(e) => Console.print(Str.from_utf8_lossy(e.value))
    Put(v) => Console.print("version {v.repr()}")
    Delete => ()
    List(p) =>
      for e in p.entries => Console.print("{e.key.repr()}\t{e.version.repr()}")
      if p.next is Some(k) then Console.error("more: flot kv ls --after {k.repr()}")

fn out<T>(args: Flot, x: T, human: fn(x: T)) uses Console =
  if args.json then Console.print(json.encode(x)) else human(x)

type Failure = ! Keys.Error | Busy | Locked | AddrInUse(addr: Addr) | Disk(path: Path)
  | ConfigMissing(field: Str) | ConfigMismatch(field: Str, expected: Str, found: Str)

fn report(args: Flot, r: Result<Unit, Failure>) -> Int uses Console =
  let (code, msg) = match r
    Ok(_) => (0, "")
    Err(NotFound) => (3, "no such key")
    Err(Conflict(current)) => (4, "the key is at {current.map(fn(v) => v.repr()) orelse "nothing"}")
    Err(BadLimit) => (2, "--limit must be 1 to 1000")
    Err(Unavailable(Denied)) => (77, "not allowed: check admin_token")
    Err(Unavailable(Version)) => (69, "the server speaks another version of the API")
    Err(Unavailable(_)) => (69, "can't reach the server at {args.addr}")
    Err(Busy) => (75, "a compaction is already running")
    Err(Locked) => (75, "the data directory is in use")
    Err(ConfigMissing(f)) => (78, "config: {f} is required")
    Err(ConfigMismatch(f, expected, found)) => (78, "config: {f}: expected {expected}, found {found}")
    Err(AddrInUse(a)) | Err(Disk(_)) => (1, show(r))
  if code != 0 then Console.error("flot: {msg}")
  code
```

```
$ flot kv put user/7 hello --expect absent
version 1
$ flot kv put user/7 again --expect absent
flot: the key is at 1                                    (exit 4)
$ flot kv ls --prefix user/ --limit 1
user/7	1
more: flot kv ls --after user/7
$ flot kv get user/7 -j
{"type": "Get", "key": "user/7", "value": "aGVsbG8=", "version": 1}
```

- **The CLI has no code per operation.** The look turns the arguments
  into a `Keys.Call`; `Keys.call` sends it. Adding `Keys.touch` adds
  `flot kv touch` with help, and the build fails until `print_reply`
  and the REST look have a line for it. That's the right three places.
- **`--json` prints the `Keys.Reply`** with its default tag, so a
  script sees `"type": "Get"`. A look of `Keys.Reply` could hide it.
- **Exit codes** are one `match`, as in stage12.

## 1.7 Tests

```ren
// kv_test.ren

test fn key(s: Str) -> Key = Key.parse(s).unwrap()

// 1. the handler is the API: no http at all
test "a conditional put sees the version it expects" =
  with mem_store(), log.test(), kv() in
    let v1 = try Keys.put(key("a"), "x".bytes(), expect: Absent)
    assert attempt Keys.put(key("a"), "y".bytes(), expect: Absent) is Err(Conflict(Some(v1)))
    let v2 = try Keys.put(key("a"), "y".bytes(), expect: At { version: v1 })
    assert v2 == v1.next()

test "paging visits every key once, in order" (keys: Set<Key>, limit: Int in 1..20) =
  with mem_store(), log.test(), kv() in
    for k in keys => let _ = try Keys.put(k, "v".bytes())
    var seen: Array<Key> = []
    var after = None
    loop
      let p = try Keys.list(after: after, limit: limit)
      seen = seen ++ p.entries.map(fn(e) => e.key)
      after = p.next
      if after == None then break
    assert seen == keys.sorted()

// 2. the same calls through the REST look, in process: encode, route, decode, both ways
test "every call survives the REST look" (c: Keys.Call) =
  with mem_store(), log.test() in
    let direct = attempt (with kv() in Keys.call(c))
    let through = attempt (with http.loopback<Keys>(KEYS_V1) over kv() in Keys.call(c))
    assert direct == through

// 3. over a simulated network: one server, one client, one fault
test fn here() -> Addr = Addr.local(7400)

test "a conflict crosses the wire as a typed error" =
  with sim.net(), mem_store(), log.test() in
    try Async.scope fn(s) =>
      s.spawn fn() =>
        let _ = attempt (with kv() in http.expose(here(), [http.mount<Keys>(KEYS_V1)]))
      with http.client<Keys>(here(), KEYS_V1) in
        let v = try Keys.put(key("a"), "x".bytes(), expect: Absent)
        assert attempt Keys.put(key("a"), "y".bytes(), expect: Absent) is Err(Conflict(Some(v)))
      SimNet.signal(Signal.term)

test "with the server down, a call is Unavailable(Refused), not a hang" =
  with sim.net(down: [here()]) in
    with http.client<Keys>(here(), KEYS_V1) in
      assert attempt Keys.get(key("a")) is Err(Unavailable(Refused))

// 4. the cli look: arguments to a call, no server
test "put's arguments become a Keys.Call" =
  assert cli.parse<Flot>(CLI, ["kv", "put", "a", "x", "--expect", "3"])
    == Ok(Flot { cmd: Kv { call: Put { key: key("a"), value: "x".bytes(), expect: At { version: Version.parse(3).unwrap() } } }, .. })
```

Also run with no test written: one round-trip property per look
(draft-formats "A round-trip test per look"): `Keys.Call.rest`,
`Keys.Error.rest`, `Keys.Call.cli`, `Keys.Call.Put.cli`, `ServerCfg.file`,
and `Bytes.text (lossy)`, which checks wire stability instead.

- Test 2 is the one Effect can't write as a property: `Keys.Call` is a
  type with a generator, so every call, with every key the domain
  allows, goes through the route look and back.
- The handler, the loopback and the network client are three handlers
  for one dep. The test code that calls `Keys` doesn't change.

## 1.8 v1 to v2, served side by side

Three changes, each a common one:

1. **Rename a field:** `Entry.version` becomes `Entry.rev`.
2. **Add an optional field:** `Entry.expires: Option<Time>`, and
   `put` takes `ttl: Option<Duration>`.
3. **Split a case:** `put` with `expect` becomes `put` (always writes)
   and `swap` (writes if the key is where you expect).

The v2 source:

```ren
// kv.ren, v2
pub type Entry = { key: Key, value: Bytes, rev: Version, expires: Option<Time> }

// api.ren, v2
pub dep Keys =
  get: fn(key: Key) -> Entry ! NotFound | Unavailable(why: Why)
  /// Write a value, whatever is there
  put: fn(key: Key, value: Bytes, ttl: Option<Duration>) -> Version ! Unavailable(why: Why)
  /// Write a value, if the key is where you expect
  swap: fn(key: Key, value: Bytes, expect: Expect, ttl: Option<Duration>) -> Version
        ! Conflict(current: Option<Version>) | Unavailable(why: Why)
  delete: fn(key: Key, expect: Expect = Any) ! NotFound | Conflict(current: Option<Version>) | Unavailable(why: Why)
  list: fn(prefix: Str = "", after: Option<Key>, limit: Int = 100) -> Page ! BadLimit | Unavailable(why: Why)
```

The handler changes with it (`put` loses its `match` arm for
`Conflict`; `swap` is v1's `put`). That's ordinary code.

Before any wire work, the build already fails:

```
error: `KEYS_V1` is frozen, and what it sends changed
  = Keys.Call: case `Swap` is new
  = Keys.Call.Put: field `expect` is gone; `ttl` is new
  = Entry: field `version` is gone; `rev` and `expires` are new
  formats.lock:12
  help: write looks that keep v1's shape, or `ren formats freeze KEYS_V1` to accept a break
```

`ren formats freeze KEYS_V1` was run when v1 shipped. The fingerprint
is of `shape.through<Keys.Call>` and `Keys.Reply` through `KEYS_V1`
(draft-shapes "Freezing what is sent"). Freezing is a command, not
syntax **[assumed]**.

The v2 wire, and v1 kept as it was:

```ren
// wire.ren, v2

// ---- v2: new paths, and swap gets its own route ----

format v2 for Keys.Call =
  | Get as GET"/v2/keys/\{key}"
  | Put as PUT"/v2/keys/\{key}"
  | Swap as POST"/v2/keys/\{key}/swap"
  | Delete as DELETE"/v2/keys/\{key}"
  | List as GET"/v2/keys"

let KEYS_V2 = http.api<Keys>(formats: [Keys.Call.v2, Keys.Error.rest])

// ---- v1: a rename and a left-out field are looks ----

format v1 for Entry =
  key
  value
  version = rev                 // the old name
                                // no `..`: `expires` is left out, and it's an Option, so that's allowed

// ---- v1: a split case is not a look. It's a wire type and two functions. [R#1] ----

/// What v1 clients send
type CallV1 =
  | Get { key: Key }
  | Put { key: Key, value: Bytes, expect: Expect = Any }
  | Delete { key: Key, expect: Expect = Any }
  | List { prefix: Str = "", after: Option<Key>, limit: Int = 100 }

format v1 for CallV1 =                       // v1's route table, moved here unchanged
  | Get as GET"/v1/keys/\{key}"
  | Put as PUT"/v1/keys/\{key}"
  | Delete as DELETE"/v1/keys/\{key}"
  | List as GET"/v1/keys"

fn from_v1(c: CallV1) -> Keys.Call =
  match c
    Get { key } => Get { key }
    Put { key, value, expect: Any } => Put { key, value, ttl: None }
    Put { key, value, expect } => Swap { key, value, expect, ttl: None }
    Delete { key, expect } => Delete { key, expect }
    List { prefix, after, limit } => List { prefix, after, limit }

fn to_v1(c: Keys.Call) -> CallV1 =
  match c
    Get { key } => Get { key }
    Put { key, value, .. } => Put { key, value, expect: Any }          // ttl is dropped
    Swap { key, value, expect, .. } => Put { key, value, expect }      // ttl is dropped
    Delete { key, expect } => Delete { key, expect }
    List { prefix, after, limit } => List { prefix, after, limit }

format v1 for Keys.Call = CallV1 via (from_v1, to_v1), lossy

let KEYS_V1 = http.api<Keys>(formats: [Keys.Call.v1, CallV1.v1, Entry.v1, Keys.Error.rest])
```

```ren
// server.ren, v2: both versions, one handler
try http.expose(cfg.addr, until: Signal.term, drain: cfg.drain, [
  http.mount<Keys>(KEYS_V1),
  http.mount<Keys>(KEYS_V2),
  http.mount<Admin>(ADMIN, auth: Bearer([cfg.admin_token])),
])
```

```ren
// evolution_test.ren
test "a v1 client's bytes still get v1's answer" =
  with mem_store(), log.test(), http.loopback_raw(KEYS_V1) over kv() in
    let r = try Http.send(Request.put("/v1/keys/a", "{\"value\":\"eA==\",\"expect\":\"absent\"}"))
    assert r.status == Ok and r.body.text() == "1"
    let g = try Http.send(Request.get("/v1/keys/a"))
    assert g.body.text() == "{\"key\":\"a\",\"value\":\"eA==\",\"version\":1}"

test "v1 and v2 see one store" =
  with mem_store(), log.test(), kv() in
    let v = try (with http.loopback<Keys>(KEYS_V1) over kv() in Keys.swap(key("a"), "x".bytes(), Absent, None))
    let e = try (with http.loopback<Keys>(KEYS_V2) over kv() in Keys.get(key("a")))
    assert e.rev == v
```

What each change cost:

| Change | Ren v1 compat | Kind |
|---|---|---|
| Rename `version` to `rev` | one line in `Entry.v1` | look |
| Add `expires` | nothing; leaving it out of `Entry.v1` is allowed because it's an `Option` | look |
| Add `ttl` to `put` | nothing; `to_v1` drops it, so the look is `lossy` | via |
| Split `put` into `put` and `swap` | a copy of v1's call type, two `match`es, a `via` | via, by hand |
| v1's routes | moved from `Keys.Call.rest` to `CallV1.v1` | look |
| Keep v1 frozen | the build refuses the change until the above exists | check |

- **The strict default helps here.** Without `Entry.v1` listing exactly
  three fields, a v1 client that decodes strictly would fail the first
  time a key had `expires` set. Writing the look without `..` is what
  keeps v1 clients working, and the freeze is what makes you write it.
- **Replies need no `via`.** A REST reply body has no tag, and both
  `Put` and `Swap` reply with a `Version`. Over a tagged transport
  (a binary envelope with `Keys.Reply` tags), v1 would also need a
  `Reply` via **[R#1]**.

---

# Part 2: Effect v4

Same program, written as an Effect user would today: `Schema` for the
types, `HttpApi` for the REST surface (server, client and OpenAPI from
one value), `effect/cli` for the CLI, `Config` for config,
`@effect/vitest` for tests. Rpc was the other choice; it gives no
route table or statuses, so HttpApi is the honest twin of a REST look.

## 2.1 The domain

```ts
// domain.ts
import { Effect, Schema, SchemaIssue, SchemaTransformation } from "effect"

export const Key = Schema.String.pipe(
  Schema.check(
    Schema.isMinLength(1),
    Schema.isMaxLength(512),
    Schema.makeFilter((s) => !/\p{Cc}/u.test(s) || "control character")
  ),
  Schema.brand("Key")
)
export type Key = typeof Key.Type

export const Version = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(1)), Schema.brand("Version"))
export type Version = typeof Version.Type

export const Expect = Schema.TaggedUnion({
  Any: {},
  Absent: {},
  At: { version: Version }
})
export type Expect = typeof Expect.Type

/** "any", "absent" or a version number, for query strings and flags */
export const ExpectFromString = Schema.String.pipe(
  Schema.decodeTo(
    Expect,
    SchemaTransformation.transformEffect({
      decode: (s) =>
        s === "any" ? Effect.succeed({ _tag: "Any" as const })
        : s === "absent" ? Effect.succeed({ _tag: "Absent" as const })
        : /^[1-9][0-9]*$/.test(s) ? Effect.succeed({ _tag: "At" as const, version: Version.make(Number(s)) })
        : Effect.fail(new SchemaIssue.InvalidValue({ message: "any, absent or a version number" })),
      encode: (e) => Effect.succeed(e._tag === "At" ? String(e.version) : e._tag.toLowerCase())
    })
  )
)

export class Entry extends Schema.Class<Entry>("Entry")({
  key: Key,
  value: Schema.Uint8Array,                  // base64 in json, by toCodecJson
  version: Version
}) {}

export class Page extends Schema.Class<Page>("Page")({
  entries: Schema.Array(Entry),
  next: Schema.optionalKey(Key)
}) {}

export class Compacted extends Schema.Class<Compacted>("Compacted")({
  tables_in: Schema.Int,
  tables_out: Schema.Int,
  bytes_freed: Schema.Int
}) {}

// errors: each one carries its status [E#3]
export class NotFound extends Schema.TaggedError<NotFound>()("NotFound", {}, { httpApiStatus: 404 }) {}
export class Conflict extends Schema.TaggedError<Conflict>()(
  "Conflict",
  { current: Schema.NullOr(Version) },
  { httpApiStatus: 409 }
) {}
export class BadLimit extends Schema.TaggedError<BadLimit>()("BadLimit", {}, { httpApiStatus: 422 }) {}
export class Busy extends Schema.TaggedError<Busy>()("Busy", {}, { httpApiStatus: 503 }) {}
export class Unavailable extends Schema.TaggedError<Unavailable>()("Unavailable", {}, { httpApiStatus: 503 }) {}
```

## 2.2 The API

```ts
// api.ts
import { Schema } from "effect"
import { HttpApi, HttpApiEndpoint, HttpApiGroup, HttpApiSecurity, HttpApiMiddleware } from "effect/http-api"
import { BadLimit, Busy, Compacted, Conflict, Entry, Expect, ExpectFromString, Key, NotFound, Page, Unavailable, Version } from "./domain.ts"

export class KeysV1 extends HttpApiGroup.make("keys")
  .add(
    HttpApiEndpoint.get("get", "/keys/:key", {
      params: { key: Key },
      success: Entry,
      error: [NotFound, Unavailable]
    }),
    HttpApiEndpoint.put("put", "/keys/:key", {
      params: { key: Key },
      payload: { value: Schema.Uint8Array, expect: Schema.optionalKey(ExpectFromString) },
      success: Version,
      error: [Conflict, Unavailable]
    }),
    HttpApiEndpoint.delete("delete", "/keys/:key", {
      params: { key: Key },
      query: { expect: Schema.optionalKey(ExpectFromString) },
      error: [NotFound, Conflict, Unavailable]
    }),
    HttpApiEndpoint.get("list", "/keys", {
      query: {
        prefix: Schema.optionalKey(Schema.String),
        after: Schema.optionalKey(Key),
        limit: Schema.optionalKey(Schema.Int)            // the default lives in the handler [E#5]
      },
      success: Page,
      error: [BadLimit, Unavailable]
    })
  )
  .prefix("/v1") {}

export class AdminAuth extends HttpApiMiddleware.Service<AdminAuth>()("AdminAuth", {
  security: { bearer: HttpApiSecurity.bearer }
}) {}

export class AdminApi extends HttpApiGroup.make("admin")
  .add(HttpApiEndpoint.post("compact", "/admin/compact", { success: Compacted, error: [Busy, Unavailable] }))
  .middleware(AdminAuth)
  .prefix("/v1") {}

export class FlotApi extends HttpApi.make("flottning").add(KeysV1).add(AdminApi) {}
```

## 2.3 The server

```ts
// server.ts
import { Config, Context, Effect, Layer, Option, Redacted, Schema } from "effect"
import { HttpRouter } from "effect/http"
import { HttpApiBuilder, HttpApiError } from "effect/http-api"
import { NodeHttpServer } from "@effect/platform-node"
import { createServer } from "node:http"
import { AdminAuth, FlotApi } from "./api.ts"
import { BadLimit, Conflict, NotFound, Page, Unavailable, type Expect, type Key } from "./domain.ts"
import { DiskError, Store } from "./store.ts"     // the engine, a Context.Service

/** A disk failure is the server's problem: log it, tell the caller only "unavailable" */
const internal = <A, E, R>(self: Effect.Effect<A, E | DiskError, R>) =>
  self.pipe(
    Effect.catchTag("DiskError", (e) =>
      Effect.logError("disk failed", { path: e.path }).pipe(Effect.andThen(Effect.fail(new Unavailable()))))
  )

const any: Expect = { _tag: "Any" }

export const KeysLive = HttpApiBuilder.group(FlotApi, "keys", (handlers) =>
  Effect.gen(function*() {
    const store = yield* Store
    return handlers
      .handle("get", ({ params }) =>
        store.get(params.key).pipe(
          Effect.flatMap(Option.match({ onNone: () => Effect.fail(new NotFound()), onSome: Effect.succeed })),
          internal
        ))
      .handle("put", ({ params, payload }) =>
        store.put(params.key, payload.value, payload.expect ?? any).pipe(internal))
      .handle("delete", ({ params, query }) =>
        store.delete(params.key, query.expect ?? any).pipe(
          Effect.flatMap(Option.match({ onNone: () => Effect.fail(new NotFound()), onSome: () => Effect.void })),
          internal
        ))
      .handle("list", ({ query }) =>
        Effect.gen(function*() {
          const limit = query.limit ?? 100
          if (limit < 1 || limit > 1000) return yield* new BadLimit()
          const es = yield* store.scan(query.prefix ?? "", query.after, limit + 1)
          return new Page({
            entries: es.slice(0, limit),
            ...(es.length > limit ? { next: es[limit - 1].key } : {})
          })
        }).pipe(internal))
  }))

export const AdminLive = HttpApiBuilder.group(FlotApi, "admin", (handlers) =>
  Effect.gen(function*() {
    const store = yield* Store
    return handlers.handle("compact", () => store.compact().pipe(internal))
  }))

export const AdminAuthLive = Layer.effect(AdminAuth)(
  Effect.gen(function*() {
    const token = yield* Config.redacted("FLOTT_ADMIN_TOKEN")
    return {
      bearer: (effect, { credential }) =>
        Redacted.value(credential) === Redacted.value(token)
          ? effect
          : Effect.fail(new HttpApiError.Unauthorized())
    }
  })
)

export const ServerConfig = Config.schema(
  Schema.Struct({
    listen: Schema.optionalKey(Schema.String),
    data: Schema.optionalKey(Schema.String),
    admin_token: Schema.Redacted(Schema.String),
    drain: Schema.optionalKey(Schema.DurationFromString)
  })
)

export const ServerLive = (cfg: typeof ServerConfig extends Config.Config<infer A> ? A : never) => {
  const [host, port] = (cfg.listen ?? "0.0.0.0:7400").split(":")
  return HttpApiBuilder.layer(FlotApi).pipe(
    Layer.provide([KeysLive, AdminLive, AdminAuthLive]),
    Layer.provide(Store.layer(cfg.data ?? "data")),
    HttpRouter.serve,
    Layer.provide(NodeHttpServer.layer(createServer, { host, port: Number(port) }))
  )
}
```

## 2.4 The client

```ts
// client.ts
import { Effect, Schedule } from "effect"
import { FetchHttpClient, HttpClient } from "effect/http"
import { HttpApiClient } from "effect/http-api"
import { FlotApi } from "./api.ts"

export const makeClient = (baseUrl: string) =>
  HttpApiClient.make(FlotApi, {
    baseUrl,
    transformClient: HttpClient.retryTransient({ schedule: Schedule.exponential("100 millis"), times: 3 })
  })

// use:
// const client = yield* makeClient("http://127.0.0.1:7400")
// const e = yield* client.keys.get({ params: { key } })
// yield* client.keys.put({ params: { key }, payload: { value, expect: { _tag: "At", version: e.version } } })
//   error channel: Conflict | Unavailable | HttpClientError | SchemaError
```

## 2.5 The CLI

```ts
// main.ts
import { Console, Effect, Layer, Option, Redacted, Schema } from "effect"
import { Argument, Command, Flag } from "effect/cli"
import { FetchHttpClient } from "effect/http"
import { NodeRuntime, NodeServices } from "@effect/platform-node"
import { makeClient } from "./client.ts"
import { ExpectFromString, Key } from "./domain.ts"
import { ServerConfig, ServerLive } from "./server.ts"

const flot = Command.make("flot", {
  addr: Flag.String("addr").pipe(Flag.withDefault("127.0.0.1:7400"), Flag.withDescription("Server address")),
  json: Flag.Boolean("json").pipe(Flag.withAlias("j"), Flag.withDefault(false))
})

const show = (json: boolean, value: unknown, human: () => string) =>
  Console.log(json ? JSON.stringify(value) : human())

// one command per endpoint, each restating the endpoint's inputs [E#1]
const get = Command.make("get", { key: Argument.String("key").pipe(Argument.withSchema(Key)) }, ({ key }) =>
  Effect.gen(function*() {
    const { addr, json } = yield* flot
    const client = yield* makeClient(`http://${addr}`)
    const e = yield* client.keys.get({ params: { key } })
    yield* show(json, e, () => new TextDecoder().decode(e.value))
  }))

const put = Command.make("put", {
  key: Argument.String("key").pipe(Argument.withSchema(Key)),
  value: Argument.String("value"),
  expect: Flag.String("expect").pipe(Flag.withSchema(ExpectFromString), Flag.optional)
}, ({ key, value, expect }) =>
  Effect.gen(function*() {
    const { addr, json } = yield* flot
    const client = yield* makeClient(`http://${addr}`)
    const v = yield* client.keys.put({
      params: { key },
      payload: { value: new TextEncoder().encode(value), ...Option.match(expect, { onNone: () => ({}), onSome: (e) => ({ expect: e }) }) }
    })
    yield* show(json, v, () => `version ${v}`)
  }))

const rm = Command.make("rm", {
  key: Argument.String("key").pipe(Argument.withSchema(Key)),
  expect: Flag.String("expect").pipe(Flag.withSchema(ExpectFromString), Flag.optional)
}, ({ key, expect }) =>
  Effect.gen(function*() {
    const { addr } = yield* flot
    const client = yield* makeClient(`http://${addr}`)
    yield* client.keys.delete({ params: { key }, query: Option.match(expect, { onNone: () => ({}), onSome: (e) => ({ expect: e }) }) })
  }))

const ls = Command.make("ls", {
  prefix: Argument.String("prefix").pipe(Argument.withDefault("")),
  after: Flag.String("after").pipe(Flag.withSchema(Key), Flag.optional),
  limit: Flag.Int("limit").pipe(Flag.withDefault(100))
}, ({ prefix, after, limit }) =>
  Effect.gen(function*() {
    const { addr, json } = yield* flot
    const client = yield* makeClient(`http://${addr}`)
    const p = yield* client.keys.list({ query: { prefix, limit, ...Option.match(after, { onNone: () => ({}), onSome: (a) => ({ after: a }) }) } })
    if (json) return yield* Console.log(JSON.stringify(p))
    for (const e of p.entries) yield* Console.log(`${e.key}\t${e.version}`)
    if (p.next !== undefined) yield* Console.error(`more: flot ls --after ${p.next}`)
  }))

const compact = Command.make("compact", {}, () =>
  Effect.gen(function*() {
    const { addr, json } = yield* flot
    const cfg = yield* ServerConfig
    const client = yield* makeClient(`http://${addr}`)       // the bearer token: a header, by hand [E#7]
    const c = yield* client.admin.compact().pipe(/* HttpClient.mapRequest(HttpClientRequest.bearerToken(...)) */)
    yield* show(json, c, () => `freed ${c.bytes_freed} bytes`)
  }))

const serve = Command.make("serve", {}, () =>
  Effect.gen(function*() {
    const cfg = yield* ServerConfig
    return yield* Layer.launch(ServerLive(cfg))
  }))

const app = flot.pipe(Command.withSubcommands([get, put, rm, ls, compact, serve]))

// exit codes: by error tag; the compiler doesn't make this exhaustive [E#6]
const exitCode = (e: unknown): number => {
  switch ((e as { _tag?: string })._tag) {
    case "NotFound": return 3
    case "Conflict": return 4
    case "BadLimit": return 2
    case "Unavailable": case "HttpClientError": return 69
    case "ConfigError": return 78
    default: return 1
  }
}

Command.run(app, { version: "1.0.0" }).pipe(
  Effect.tapError((e) => Console.error(`flot: ${String(e)}`)),
  Effect.catch((e) => Effect.sync(() => { process.exitCode = exitCode(e) })),
  Effect.provide([NodeServices.layer, FetchHttpClient.layer]),
  NodeRuntime.runMain
)
```

## 2.6 Tests

```ts
// kv.test.ts
import { assert, describe, it } from "@effect/vitest"
import { Effect, Exit, Layer } from "effect"
import { HttpApiClient, HttpApiTest } from "effect/http-api"
import { HttpClient, HttpClientError, HttpRouter } from "effect/http"
import { NodeHttpServer } from "@effect/platform-node"
import { HttpApiBuilder } from "effect/http-api"
import { FlotApi } from "./api.ts"
import { Conflict, Key } from "./domain.ts"
import { AdminLive, KeysLive } from "./server.ts"
import { Store } from "./store.ts"

const key = (s: string) => Key.make(s)
const bytes = (s: string) => new TextEncoder().encode(s)
const Handlers = Layer.mergeAll(KeysLive, AdminLive).pipe(Layer.provide(Store.layerMemory))

describe("keys", () => {
  // 1. in memory: the real routing and codecs, no server
  it.effect("a conditional put sees the version it expects", () =>
    Effect.gen(function*() {
      const client = yield* HttpApiTest.groups(FlotApi, ["keys"])
      const v1 = yield* client.keys.put({ params: { key: key("a") }, payload: { value: bytes("x"), expect: { _tag: "Absent" } } })
      const again = yield* Effect.exit(
        client.keys.put({ params: { key: key("a") }, payload: { value: bytes("y"), expect: { _tag: "Absent" } } }))
      assert.deepStrictEqual(again, Exit.fail(new Conflict({ current: v1 })))
    }).pipe(Effect.provide(Handlers)))

  it.effect("paging visits every key once, in order", () =>
    Effect.gen(function*() {
      const client = yield* HttpApiTest.groups(FlotApi, ["keys"])
      const keys = ["a", "b", "c", "d", "e"].map(key)
      for (const k of keys) yield* client.keys.put({ params: { key: k }, payload: { value: bytes("v") } })
      const seen: Array<Key> = []
      let after: Key | undefined
      do {
        const p = yield* client.keys.list({ query: { limit: 2, ...(after ? { after } : {}) } })
        seen.push(...p.entries.map((e) => e.key))
        after = p.next
      } while (after !== undefined)
      assert.deepStrictEqual(seen, keys)
    }).pipe(Effect.provide(Handlers)))

  // 2. a real server on an ephemeral port
  it.effect("a conflict crosses the wire as a typed error", () =>
    Effect.gen(function*() {
      const client = yield* HttpApiClient.make(FlotApi)          // layerTest's HttpClient points at the server
      const v = yield* client.keys.put({ params: { key: key("a") }, payload: { value: bytes("x"), expect: { _tag: "Absent" } } })
      const r = yield* Effect.flip(
        client.keys.put({ params: { key: key("a") }, payload: { value: bytes("y"), expect: { _tag: "Absent" } } }))
      assert.strictEqual(r._tag, "Conflict")
    }).pipe(
      Effect.provide(HttpApiBuilder.layer(FlotApi).pipe(Layer.provide(Handlers), HttpRouter.serve, Layer.provideMerge(NodeHttpServer.layerTest)))
    ))

  // 3. the one fault: the server is down. There is no simulated network, so fake the client.
  it.effect("with the server down, a call fails with a transport error", () =>
    Effect.gen(function*() {
      const refused = HttpClient.make((request) =>
        Effect.fail(new HttpClientError.HttpClientError({
          reason: new HttpClientError.TransportError({ request, description: "ECONNREFUSED" })
        })))
      const client = yield* HttpApiClient.makeWith(FlotApi, { httpClient: refused, baseUrl: "http://127.0.0.1:7400" })
      const r = yield* Effect.flip(client.keys.get({ params: { key: key("a") } }))
      assert.strictEqual(r._tag, "HttpClientError")
    }))
})
```

There is no generated "every call survives the codec" property. You can
write one with `Arbitrary.schema` per endpoint payload, by hand.

## 2.7 v1 to v2, served side by side

```ts
// domain.ts, v2
export class Entry extends Schema.Class<Entry>("Entry")({
  key: Key,
  value: Schema.Uint8Array,
  rev: Version,
  expires: Schema.optionalKey(Schema.DateTimeUtcFromString)
}) {}

/** What v1 clients read: the old name, no expires */
export class EntryV1 extends Schema.Class<EntryV1>("EntryV1")({
  key: Key,
  value: Schema.Uint8Array,
  version: Version
}) {}
export const toV1 = (e: Entry) => new EntryV1({ key: e.key, value: e.value, version: e.rev })

// api.ts, v2: a new group; KeysV1 keeps its schemas but now returns EntryV1
export class KeysV2 extends HttpApiGroup.make("keysV2")
  .add(
    HttpApiEndpoint.get("get", "/keys/:key", { params: { key: Key }, success: Entry, error: [NotFound, Unavailable] }),
    HttpApiEndpoint.put("put", "/keys/:key", {
      params: { key: Key },
      payload: { value: Schema.Uint8Array, ttl: Schema.optionalKey(Schema.DurationFromString) },
      success: Version,
      error: [Unavailable]
    }),
    HttpApiEndpoint.post("swap", "/keys/:key/swap", {
      params: { key: Key },
      payload: { value: Schema.Uint8Array, expect: Expect, ttl: Schema.optionalKey(Schema.DurationFromString) },
      success: Version,
      error: [Conflict, Unavailable]
    }),
    HttpApiEndpoint.delete("delete", "/keys/:key", {
      params: { key: Key }, query: { expect: Schema.optionalKey(ExpectFromString) }, error: [NotFound, Conflict, Unavailable]
    }),
    HttpApiEndpoint.get("list", "/keys", {
      query: { prefix: Schema.optionalKey(Schema.String), after: Schema.optionalKey(Key), limit: Schema.optionalKey(Schema.Int) },
      success: Page,                                       // Page holds v2 Entry
      error: [BadLimit, Unavailable]
    })
  )
  .prefix("/v2") {}

// KeysV1: `get` success becomes EntryV1, `list` success becomes PageV1 (a copy of Page over EntryV1)
export class FlotApi extends HttpApi.make("flottning").add(KeysV1).add(KeysV2).add(AdminApi) {}

// server.ts, v2: two groups of handlers over one store; the split is an `if` in v1's put
export const KeysV1Live = HttpApiBuilder.group(FlotApi, "keys", (handlers) =>
  Effect.gen(function*() {
    const store = yield* Store
    return handlers
      .handle("get", ({ params }) => getEntry(store, params.key).pipe(Effect.map(toV1), internal))
      .handle("put", ({ params, payload }) =>
        (payload.expect === undefined || payload.expect._tag === "Any"
          ? store.put(params.key, payload.value, undefined)
          : store.swap(params.key, payload.value, payload.expect, undefined)
        ).pipe(internal))
      .handle("delete", ({ params, query }) => deleteEntry(store, params.key, query.expect).pipe(internal))
      .handle("list", ({ query }) =>
        listPage(store, query).pipe(Effect.map((p) => new PageV1({ ...p, entries: p.entries.map(toV1) })), internal))
  }))

export const KeysV2Live = HttpApiBuilder.group(FlotApi, "keysV2", (handlers) =>
  Effect.gen(function*() {
    const store = yield* Store
    return handlers
      .handle("get", ({ params }) => getEntry(store, params.key).pipe(internal))
      .handle("put", ({ params, payload }) => store.put(params.key, payload.value, payload.ttl).pipe(internal))
      .handle("swap", ({ params, payload }) => store.swap(params.key, payload.value, payload.expect, payload.ttl).pipe(internal))
      .handle("delete", ({ params, query }) => deleteEntry(store, params.key, query.expect).pipe(internal))
      .handle("list", ({ query }) => listPage(store, query).pipe(internal))
  }))
// getEntry, deleteEntry, listPage: v1's handler bodies, moved out to be shared
```

```ts
// evolution.test.ts
it.effect("a v1 client's bytes still get v1's answer", () =>
  Effect.gen(function*() {
    const http = yield* HttpClient.HttpClient                    // layerTest: points at the test server
    const r = yield* http.execute(
      HttpClientRequest.put("/v1/keys/a").pipe(HttpClientRequest.bodyJsonUnsafe({ value: "eA==", expect: "absent" })))
    assert.strictEqual(yield* r.text, "1")
    const g = yield* http.get("/v1/keys/a")
    assert.strictEqual(yield* g.text, `{"key":"a","value":"eA==","version":1}`)
  }).pipe(Effect.provide(TestServer)))
```

- Nothing stops a v2 change from breaking v1. If someone edits `Page`
  (shared by both groups) the v1 wire changes and only the golden test
  notices. There is no freeze **[E#4]**.
- Unknown keys are ignored by default in Effect, so a v1 client built
  with Effect wouldn't break on `expires` anyway. The cost is the other
  way: typos in requests are silently dropped **[E#8]**.

---

# Part 3: Comparison

## Lines

Counted by a script over this file's code blocks: lines that aren't
blank, comments, or wire samples. "Core" is sections 1.1 to 1.7 and 2.1
to 2.6; "v2" is 1.8 and 2.7.

| | Ren | Effect v4 |
|---|---|---|
| Domain types | 30 | 54 |
| API definition | 11 | 40 |
| Looks and settings | 33 | (inside the API and domain) |
| Server | 50 | 74 |
| Client | 4 | 9 |
| CLI | 62 | 86 |
| Tests | 40 | 57 |
| **Core total** | **230** | **320** |
| v2: types, wire, server | 50 | 62 |
| v2: tests | 11 | 9 |
| **v2 total** | **61** | **71** |

Ren's count leaves out the block the compiler writes (`Keys.Call` and
friends, 12 lines). Effect's v2 count is low: it elides `PageV1` and
the three handler bodies moved out to be shared, about 25 more lines.

The counts are rough. Effect's lines are longer. The gap is mostly the
CLI (Effect restates every endpoint as a command) and the server
(Effect writes a route table and a handler per route; Ren writes only a
handler of the dep).

## Concepts a user must learn

| Ren (20 groups) | Effect v4 (18 groups, about 40 named APIs) |
|---|---|
| opaque types; `parse`/`repr` | `Effect`, `Effect.gen`, `yield*`, `pipe` |
| sums, records, field defaults, `Option` | `Schema` values; `typeof X.Type`; Type vs Encoded |
| `dep`, `handler`, `wiring`, `with`, `over` | `Schema.brand`, `check`, filters |
| `try`, `fail`, `attempt`, `match` on `fail` | `Schema.Class`, `TaggedError`, `TaggedUnion` |
| `D.Call`, `D.Reply`, `D.Error`, `D.call` (written for you) | `optionalKey`, `NullOr`, `Option` |
| `Unavailable(why)` on remote ops | `decodeTo` + `SchemaTransformation` + `SchemaIssue` |
| `format ... for`: lines, `..`, renames | `Context.Service`; `Layer` (provide, merge, launch) |
| sum looks: `as`, tags, `\| ..` | `HttpApi`, `HttpApiGroup`, `HttpApiEndpoint` (params, query, payload, success, error) |
| `via`, `lossy` | `httpApiStatus` annotation |
| route values `GET"..."` with holes | `HttpApiBuilder.group`, `.handle`, `HttpApiBuilder.layer`, `HttpRouter.serve` |
| status looks | `HttpApiMiddleware`, `HttpApiSecurity` |
| settings records: `formats` list | `HttpApiClient.make`, `HttpClient` layer, `retryTransient` |
| `http.api`, `http.mount`, `http.expose`, `http.client`, `http.loopback` | `Command`, `Flag`, `Argument`, `withSchema`, `withSubcommands`, `run` |
| `cli.spec`: positional, short | `Config.schema`, `ConfigProvider` |
| `config.load`, sources | `Redacted` |
| `Secret` | `@effect/vitest` `it.effect`; `HttpApiTest`; `NodeHttpServer.layerTest` |
| `retry<D>` | `Exit`, `Effect.flip`, `Effect.exit` |
| `sim.net` | `Option.match` |
| freeze, `formats.lock` | |
| generated look tests | |

Ren's list is shorter, and most of it is the language. The new
concepts from looks are five: record lines, sum tags, `via`, settings
`formats`, and route and status tags. Effect's list is mostly library
API, and each part (HttpApi, cli, Config) has its own vocabulary for
the same idea, "a type, seen through a codec".

## Where types are written and where they're inferred

| | Ren | Effect v4 |
|---|---|---|
| Domain types | written once, as types | written as schemas; the TS type is inferred from them (`typeof Key.Type`) |
| The API's operations | written once, as `dep` signatures | written as endpoints; no separate interface |
| Call and reply types | written by the compiler (`Keys.Call`, `Keys.Reply`) | inferred: the handler's `ctx` and the client's methods |
| Error union per op | written in the `dep` | written per endpoint (`error: [...]`) |
| Route table | written, as a look | written, in each endpoint |
| Status per error | written, as a look of `Keys.Error` | written, as an annotation on each error class |
| Codec for each body | derived by the walk; looks only where it differs | derived by `toCodecJson`; transformations where it differs |
| Path and query decoding | derived: `parse(Str)` | derived: `toCodecStringTree` |
| Server dispatch | derived: `http.mount<Keys>` runs `Keys.call` | written: one `.handle` per endpoint |
| Client | derived: `http.client<Keys>` is a handler | derived: `HttpApiClient.make` |
| CLI commands | derived from `Keys.Call` through a look | written: one `Command.make` per endpoint |
| CLI output | written: `print_reply` | written: per command |
| v1 compatibility | written: looks, plus a wire type and `via` for the split | written: second group, `EntryV1`, `PageV1`, mapping in handlers |
| Effects / uses rows | written on `pub`, inferred on private | inferred (the `R` parameter) |

## What fails at build time, what at run time

| Mistake | Ren | Effect v4 |
|---|---|---|
| Route hole names no field | build | not checked by the types as far as this study found; a 404 or a decode error at run time |
| Two routes can match one request | build (`check`) | start-up (router throws) or never (first wins) |
| An error has no status | build (status look is exhaustive) | run: it goes out as 500 |
| A handler misses an operation | build | build |
| A handler fails with an undeclared error | build | build (the error channel must fit `error`) |
| A field left out of a look with no default | build | n/a (no projection; a missing field is a type error in the mapper) |
| Two looks for one type in one call | build | n/a |
| Writing a `Secret` | build | run: `Redacted` prints `<redacted>` |
| A new op without a CLI line | build (only `print_reply`) | silent: no command until someone writes one |
| A new error without an exit code | build (`report` is exhaustive) | silent: `default: 1` |
| v2 change breaks v1's wire | build (frozen `KEYS_V1`) | run: a golden test, if written |
| Unknown key in a request | run: 400 (strict) | ignored |
| Bad key, bad expect, bad limit | run: 400/422 with a path | run: 400 with a path |
| Client and server built from different API versions | run, once per connection: `Unavailable(Version)` | run, per call: a decode error, or nothing |
| Server down | run: `Unavailable(Refused)` | run: `HttpClientError` |
| Config missing a field | run: `ConfigMissing` | run: `ConfigError` |

## Every place either felt awkward

### Ren

- **[R#1] A split case is not a look.** Renames and left-out fields
  are one line each. Splitting `put` needs a copy of v1's call type,
  two `match`es, a `via`, and moving v1's route table onto the copy.
  Over a transport that tags replies, `Keys.Reply` would need the same.
  It's honest (a split is a real conversion) but it's the one change
  that costs more than Effect.
- **[R#2] Status looks aren't injective.** draft-formats says two cases
  with one tag are a build error. `Busy` and `Unavailable` are both 503;
  `BadKey` and `BadLimit` both 422 in practice. Status looks need the
  exception the draft already hints at ("a client can tell two errors
  that share a status apart" by the body's tag). Also: a bad path
  segment (`BadKey`) is a decode `Problem`, not in `Keys.Error`, so its
  status is http's rule, not the look's.
- **[R#3] `Unavailable` is the client's word, but it's in the server's
  signature.** The server never means "unavailable"; it means "my disk
  failed". So every handler arm maps `Disk` to `Unavailable(Server)` by
  hand, the status look must give `Unavailable` a status the server
  will rarely send, and auth failures (401) have no home except a
  `Why` case (`Denied`). A dep that is remote has two error sets: the
  domain's, and the transport's. Writing both in one signature mixes
  them.
- **[R#4] The CLI can't splice `Keys.Call` into the top level.**
  `flot kv get a` instead of `flot get a`, because a look can't flatten
  (draft rule) and `Cmd` needs other cases (`serve`, `compact`). Fix
  candidate: a sum look line `| Kv as ..` meaning "this case's one
  field is a sum; its cases are mine". Global flags also lean on
  stage12's unadopted F#2 rule.
- **[R#5] `Keys.call` erases per-op errors.** It fails with
  `Keys.Error`, so code that ran a `Get` still has to handle
  `Conflict`. For the CLI that's fine (one `report`). For a proxy or a
  test that compares calls it's noise. `Keys.Reply` has the same
  problem in reverse: `print_reply` must handle every case though it
  knows which one it asked for.
- **[R#6] Two deps, or two versions, on one port.** The owner's sketch
  is `http.expose<Keys>(addr, api)`. A real server has `Keys` v1,
  `Keys` v2 and `Admin`. This draft invents `http.mount<D>(settings)`
  values in a list. Whether a `Mount` can hold `D.call` (functions are
  second-class) or must be a compiler-written enum of deps is open.
- **[R#7] REST wants headers and raw bodies.** A conditional put is
  `If-Match` in real APIs, and a value is the raw body. The draft puts
  every non-path field in json, so `value` goes as base64 and `expect`
  in the body. Headers and per-route body formats are "later".
- **[R#8] "A shape hash at connect" has no connect over REST.** It
  becomes a header per connection and a 412. That's a new rule
  hiding in http.
- **[R#9] `parse` beats structure everywhere.** `Expect` needed
  `parse(Str)` for flags and the query, so json also says
  `"expect": "3"`. To keep json structural you'd name a look of
  `Expect` that is its structure (`| ..`) in the json settings. Not
  wrong, but surprising.
- **[R#10] The `formats` list for v1 is four looks across four types**
  (`Keys.Call.v1`, `CallV1.v1`, `Entry.v1`, `Keys.Error.rest`), and
  `CallV1.v1` only applies because `Keys.Call.v1`'s `via` reaches it.
  Which look applies where is invisible at the call. `ren explain
  KEYS_V1` (print the walk) would answer it.
- **[R#11] `Bytes.text` must be `lossy`** only because `via` demands a
  write function, though the cli never writes. One-way looks
  (`reads`) still need both functions.
- **[R#12] Freezing has no syntax.** It's `ren formats freeze KEYS_V1`
  and a lockfile. Fine, but it's not visible in the source that
  `KEYS_V1` is a contract.
- **[R#13] Disk errors, per arm.** Each `kv` arm is a 3-4 line `match`
  to re-raise its own errors and map `Disk`. Rust's `?` with `From`, or
  Effect's `catchTag` in a pipe, is one line. Ren can't bind a whole
  error (errors.md), so a helper can't take "any error, except map
  `Disk`".

### Effect v4

- **[E#1] The CLI restates the API.** Each command repeats the
  endpoint's params, payload and query as `Argument` and `Flag` values,
  and then builds the client call by hand, including spreading optional
  keys. There is no bridge from `HttpApi` to `cli`.
- **[E#2] Optional keys and `Option` don't meet.** cli's
  `Flag.optional` gives an `Option`; HttpApi's `optionalKey` wants an
  absent key. Every call site does `Option.match(..., { onNone: () =>
  ({}), onSome: (x) => ({ k: x }) })`.
- **[E#3] Status lives on the error class** (`httpApiStatus: 404`). The
  domain's `NotFound` now knows HTTP. A second transport with other
  codes needs other classes.
- **[E#4] No freeze.** Shared schemas (`Page`) change v1's wire when
  edited for v2. v1 needs copies (`EntryV1`, `PageV1`) and mapping in
  every v1 handler.
- **[E#5] Defaults for query params.** `withDecodingDefaultKey` takes
  the default on the encoded side, which for a query is a string. In
  practice the default goes in the handler (`query.limit ?? 100`), so
  OpenAPI doesn't show it.
- **[E#6] Exit codes by string tag.** The error union from
  `Command.run` is wide (`CliError | Conflict | ... | HttpClientError |
  SchemaError | ConfigError`); the `switch` over `_tag` isn't checked.
- **[E#7] Auth on the client is a header by hand.** The server's
  security middleware is declared; the client needs
  `HttpClient.mapRequest(HttpClientRequest.bearerToken(...))` added
  per client.
- **[E#8] Lenient by default.** Unknown keys are dropped. A client typo
  (`"expct"`) is silently a non-conditional put.
- **[E#9] Disk errors as `catchTag` per handler pipe** (`internal`),
  fine, but forgetting it gives a defect and a 500, not a build error.
- **[E#10] No simulated network.** The "server down" test fakes an
  `HttpClient`. Testing retry under resets needs a real server and
  something like toxiproxy.
- **[E#11] Two names per type.** `Key` the schema and `Key` the type
  (`typeof Key.Type`), brands that `make` must be used to build in
  tests (`Key.make("a")`), `Schema.Class` with a string identifier.

## The 5 worst awkward spots in Ren's version

1. **[R#3] `Unavailable` in the dep's signature mixes the transport's
   errors with the domain's.** Every server arm maps disk failures into
   a word meant for clients, the status look must give it a status,
   and auth has nowhere to go. Candidate fix: a remote dep declares its
   domain errors only, and `http.client<D>` adds `Unavailable(why)` to
   every op, written once in the dep header (`pub dep Keys, remote =`)
   so callers still see it in the signature.
2. **[R#1] Splitting a case can't be a look.** It needs a frozen copy
   of the old `Call` type, two `match`es and a `via`, and the old route
   table moves onto the copy. Probably right to keep it explicit, but
   std could write the copy: `ren formats freeze` could emit
   `Keys.Call.V1` as a type from the lockfile, so only `from_v1` and
   `to_v1` are hand-written.
3. **[R#4] The CLI can't splice a dep's calls into its own
   subcommands.** `flot kv get a`. One look line (`| Kv as ..`) would
   fix it without allowing general flattening.
4. **[R#6] Serving several deps and versions on one port has no
   decided form.** `http.mount<D>` values in a list work on paper, but
   whether a mount can carry `D.call` given second-class functions is
   open, and it's where v1 and v2 meet.
5. **[R#2] Status looks break "tags are distinct", and decode errors
   bypass them.** Two errors on one status is normal HTTP. The draft
   needs to say status tags may repeat (the body tag disambiguates),
   and say what status a bad path segment gets.

Close behind: [R#13] (per-arm error re-raising, from errors.md's "no
whole-error binding") and [R#7] (no headers or raw bodies in REST
looks), which a real flottning API would hit on day one.

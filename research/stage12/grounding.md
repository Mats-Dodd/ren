# Stage 12 grounding: what exists, what's open, what flottning needs

Read on 2026-10-29 against `main` at 0c70dbc (data stage not yet merged;
services stage briefed, not started). Sources: shapes.md, stdlib.md,
formats.md, deps.md, handlers.md, testing.md, runtime-io.md,
module-build.md, language.md §3-§8 and §11, streams.md, strings.md,
errors.md, async.md, foundations.md (Staging, open questions), README
roadmap, vision.md, operators.md "How it runs", compiler.md (11a Net,
std lib), lib/core/prelude.ml, lib/core/std_lib.ml, lib/syntax/{ast,lexer}.ml,
examples/server.

**flottning is never described in the repo.** It appears twice: README's
1.0 gate ("flottning, rewritten in Ren, passes 10,000 simulation seeds")
and stdlib.md's first open question ("What does flottning need?"). Section
4 below assumes the task's framing (CLI + server + storage engine) and
vision.md's three program kinds; the first thing stage 12 needs from the
owner is a one-paragraph spec of flottning (single node or replicated?
what protocol? what data model?).

---

## 1. Inventory: mechanisms stage 12 can build on

Legend: **built** (runs in interpreter, and natively where noted),
**decided** (in a decided doc, not built), **designed** (design doc,
partly *proposed*), **missing** (nobody has designed it).

### Language and compile time

| Mechanism | State | Notes for stage 12 |
|---|---|---|
| Top-level `let` (build-time value) | **designed** (shapes.md), not built | AST items are only `Fn`, `Type`, `Import`, `Testing`. Associated values under a type (`pub let term: Signal = 15`) run today; module-level `let` doesn't. |
| Top-level `assert` (fails the build) | **designed**, not built | `assert` token exists (tests only). |
| Build-time interpreter / build journal / caching | **designed**; "with packages" | Stage 12 slice: pure top-level only. |
| `T.shape` | **designed**, not built | No `shape` anywhere in sema. |
| `D.shape`, `f.uses`, `Transfer.size` | designed; `.size` waits for memory stage | `f.uses` is cheap: rows are already inferred. |
| `over any`, `call.name`, `call.args`, `call.forward()`, `call.fail(e)` | **built** (10d, interp + native) | The built form is NOT shapes.md's `call(op, args)` / `next.call`. `call.args` is opaque: show, `==`, generic pass-through only. Can't wrap ops taking a block. |
| Journal recorder as `over any` handler in Ren | **built** (10d) | Proof that generic handlers suffice for recording. |
| Derived `==`, `hash`, order, `show` (compiler's structural walk) | **built** | operators.md: that walk "stays inside the compiler"; `json` uses `T.shape` instead. |
| Closed set of built-in requirements (`==`, order, `hash`, arith, `zero/one`, `show`) | **built**, passed as dictionaries | `decode<T>` with T only in the return type needs a new member of this set (a shape dictionary). language.md §3 says the set is closed: adding `shape` is a decision. |
| Explicit type application `decode<User>(...)` | not built, not designed | Docs use both `json.decode<Signup>(body)` and `let u: User = try json.decode(body)`. |
| String interpolation `"\{x}"` | **decided** (strings.md), **not built** | Lexer accepts only `\n \t \" \\`. `sql"..."` / tagged templates open. |
| By-name parameters with defaults (`max: Int = 64`) | **built** (11a) | Basis for `json.decode(body, keys: camel_case)`. |
| Record field defaults (`plan: Plan = Free`, `port: Int = 8080`) | used in stdlib.md, **not designed anywhere** | Needed by config/json/cli. |
| `secret` types | Later (handlers.md), used in stdlib.md | Journal format has room for `<redacted>`. |
| Opaque types, `parse` constructors | **built** | Shape of an opaque type is "opaque, built by its parse" (shapes.md). |
| Data stage: record update/patterns, by-name variants, variant types, `let ... else` | briefed, merging | Subcommands, routes, log events are ADTs. |
| Wirings, `|>` with `try` per step | services brief | The composition root for server and CLI. |
| `Decimal`, `d` suffix | designed (stdlib.md), not built | json numbers decode via Decimal per stdlib. |
| Numeric unit literals (`50.ms`, `3.s`) | used in docs, not built | Only `Duration.ms(n)` exists. |

### Encodings and bytes

| Mechanism | State |
|---|---|
| Layer 3: `b.u32_le(at)`, `&b.set_u16_be`, `Bytes.zeros`, varint, `ByteCursor` with `FormatError` (`Short/Malformed/UnknownTag`) | **built** (bytes stage part one, interp + native) |
| Slices of `Str`/`Bytes`/`Array` as values | **built** (heap object each; inline slice is bytes part two) |
| `Str.from_utf8` | **built**; `from_utf8_lossy`, strings.md API: part two |
| Layer 2 declared `format ... for T` with `view`/`edit`/`write`/`encode`, versions, `formats.lock` | **decided** (formats.md, decision 19), not built; staged 7b |
| Layer 1 `bin.encode/decode` over shapes | **decided**, waits on shapes |
| `x.hash()` unseeded; `Map`/`Set` seeded, insertion-ordered | **built** |
| Checksums (CRC32C, AEGIS, xxhash) | **missing** from stdlib inventory; formats.md uses `aegis(...)`; stdlib's `checksum` is stage 15 (no-alloc) |

### World and runtime

| Mechanism | State |
|---|---|
| Built-in deps `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net`, `Async` | **built**, thin |
| `Fs` | only `read(p) -> Bytes`, `write(p, b)`, `exists(p)`, `read_str`. No handles, offsets, append, fsync, rename, list, remove, mkdir, lock. `mem_fs`. No `sim.fs`. |
| `Os` | only `args()`. No env, exit, signals beyond `Signal.term/interrupt`, stdin. |
| `Proc` | `run(cmd, args) -> Int`; no output capture. `sim.proc`. |
| `Net` | `listen/accept/accept_until/read(c,max)/write/close`, TCP only, `Unix.select`. No connect for clients (only `SimNet.connect`), no DNS/TLS/UDP. `sim.net()` in Ren, no faults. Graceful shutdown via `accept_until(l, Signal.term)` + 5 s cleanup deadline **built** (examples/server). |
| `Path` | `opaque Str` today (strings.md decides `opaque Bytes`, 7b) |
| `Async`: scope, spawn, timeout, race, until, isolate, `sim.scheduler(seed)`, virtual `sim.clock()` | **built** |
| `sync`: channel, semaphore, `limit() over any`, batcher, `keyed` | **built** (`keyed` to be replaced by actors) |
| `retry(n, on:)` running a block | **built** |
| Journal v2 (text, task paths, polls), `ren run --record`, `ren replay`, `replay(file)` in tests, `--keep` | **built** |
| `ren test --sim --seeds` | **built** |
| Cursors (`next(inout self)`), `for x in &c` | **built** (10c) |
| Pipelines on cursors, `gen fn`, `Fs.lines`, readers (`Fs.line_reader`, `Net.frames`) | **decided** (streams.md); generators are 11c |
| Completion ring, leased buffers, `write_then_sync`, cancellation-waits | **designed** (runtime-io.md, *proposed*), stage 13+ |
| Errors as structural tags; payload-free common words vs domain-named tags | tags **built**; std's convention still *proposed* (stdlib.md) |
| Property tests, shrinking by replaying `Random`, `arbitrary`, `ren fuzz` | **designed** (testing.md), stage 12 |
| Actors/striped (one instance per key, eviction, chaos) | services stage |
| Arenas, snapshots, `Atomic` | 11b |

---

## 2. Open and *proposed* questions stage 12 must settle

Grouped by what they block. (S) = must settle in stage 12; (L) = can be
deferred with a stated default.

### Shapes and derivation (blocks json, cli, config, bin, property tests)
1. (S) **How a generic function gets `T.shape` when T appears only in the result.** A new built-in requirement (`shape`) in language.md §3's closed set, passed as a dictionary like `show`? Or explicit type application? Both spellings appear in docs.
2. (S) **What `Value`, the dynamic view, is** (shapes.md open). Built `call.args` is opaque (show/`==` only); a decoder must *construct* values. Public type, or an explicitly imported module (`import shape`)? How does it build a record "with a check that can't fail"?
3. (S) **How a shape reaches an opaque type's `parse`.** A shape that carries constructors carries code; blocks can't be stored (foundations decision 1/3). Either shapes hold compiler-written descriptions (decision 3's one stored code), or `decode` dispatches through a compiler-provided requirement.
4. (S) **Where per-field metadata comes from without attributes.** shapes.md bans per-field attributes; but `cli` needs help text, short flags, positional vs flag; `config` needs env names and secrets; `json` needs omit-if-none. Options: doc comments in the shape; settings on the call; wrapper types (`Flag<T>`, `Positional<T>`, `secret T`); "a type of its own, converted by hand".
5. (S) **Record field defaults** (`= 8080`, `= Free`): a language feature, or a format setting?
6. (S) **`secret`**: a type former (`secret Str`), an opaque wrapper in std, or Later? Journal, log and `show` all need the answer.
7. (S) **Is `f.uses` inferred or declared** (shapes.md open); needed if stage 12 ships `assert handle.uses <= [...]`.
8. (S) **Build time budget**, and whether a module raises it (shapes.md open). Needed with top-level `let`.
9. (L) **How `call` is typed** (shapes.md / README open). Built `over any` sidesteps it with opaque args + `forward()`; stage 12 only needs it if `mock<D>()` or `rpc.client<D>` ship.
10. (S) **Release-build specialization of shape walks** vs "debug reads at run time": stage 12 is interpreted, so only the debug path is required, but the API must not preclude unrolling.

### Strings and interpolation
11. (S) **How interpolation hands its parts to a library** (stdlib.md, strings.md): `sql"..."`, `b"..."` literals, and whether `json"..."`/`html"..."` exist. stdlib says it must land before the first SQL library. Interpolation itself isn't built yet.
12. (L) `s.get(a..b) -> Option<Str>` for offsets from input (parsers in http/json).

### Standard library scope and conventions
13. (S) **What flottning needs** (stdlib.md open #1) — this doc's §4.
14. (S) **The error-tag convention** (*proposed* since stage 6): payload-free common words vs domain-named tags. http, json, cli, config all mint tags.
15. (S) **Prelude vs std boundary** (module-build.md open): are `json`, `http`, `cli` imported (`import json`) like `sim`/`sync`, built into the compiler as Ren source (std_lib.ml's model), or files in a std package? Packages are stage 13.
16. (S) **Rule 3 hard or warning** (borrow the computation, own the effects); decides how SQLite/crypto enter the interpreter (OCaml bindings) without escaping sim.
17. (L) `std.x` versioning; when websocket moves.
18. (L) `Alloc` inferred early or added at stage 15: affects std's public signatures being frozen.
19. (S) **Which HTTP**: 1.1 only for stage 12 (stdlib roadmap puts HTTP/2 and TLS at 13)? Router shape (see contradiction C2). Body as a cursor before generators?
20. (S) **Config sources and precedence**: env only (stdlib snippet), or file (toml) + env + flags? toml is listed at stage 13 though the toolchain needs it.

### World / runtime-io
21. (S) **`Fs` with handles and offsets** for a storage engine: positional read/write, append, `sync`/`datasync`, rename, directory sync, list/remove/mkdir, a lock. runtime-io's `Fs.read(file, &buf)` and `write_then_sync(file, offset, bytes)` imply file handles that nobody has specified. Which linked ops (runtime-io open).
22. (S) **`sim.fs`**: torn writes, lying fsync, full disk, crash-and-restart (stdlib: `sim.fs(seed, full_disk: 1%)`). Stage 17 per stdlib for "every dep", but flottning's 10k-seed gate and any storage tests need it far earlier.
23. (S) **`Os` completion**: env (`EnvNotUtf8`), exit codes, stdin, signals beyond term, TTY detection (deps.md Later).
24. (S) **Net client side**: `connect` (only SimNet has it), DNS (runtime-io open: in `Net` or a std module; must be owned for determinism), `sim.net` faults (partitions, delay, reset).
25. (L) Registered buffer pool sizing; Windows as 1.0 platform; how much of `Os`/processes `sim` can simulate.
26. (L) Journal: binary form, large-value cap, byte budget (handlers.md); whether it serves sim and migration (README open).

### Testing
27. (S) **Saved failure naming/storage** (testing.md open) — property tests ship in 12.
28. (S) Whether generated data comes from `T.shape` (same mechanism as json) — testing.md implies yes; confirm one walk.
29. (L) `:spec` assert selection; cost of specs for small files.

### Concurrency (server)
30. (L) A `with`'s own cleanup deadline (fixed 5 s) — a server may need it per listener; `Async.map` default limit.
31. (L) How an arena's data outlives its `with` (foundations open) — server config built once and read forever.

---

## 3. Contradictions between docs (and docs vs code)

**C1. Generic handler surface.** shapes.md: `handler traced<D>() over D`, clause `call(op, args) =>`, `next.call(op, args)`, "`op` has a name and the operation's shape, `args` is the dynamic view". handlers.md (built, 10d): `handler logged() over any`, arm `call =>`, `call.name`, `call.args` (opaque), `call.forward()`, `call.fail(e)`. shapes.md's "What changes elsewhere" and "When each part lands" haven't caught up. Also shapes.md lists `Async.limit(n) over D`; built is `sync.limit() over any uses Semaphore`.

**C2. Routes: three designs.**
- shapes.md: `let ROUTES: Router = router([get("/users/:id", show_user), ...])` at the top level — a table holding functions, while the same doc says "a top-level value holds data, never a block", and foundations says blocks are never stored.
- language.md §6: routes as the user's own enum + a dispatch block, `http.serve(routes, handle)` with `serve<R>(routes: Array<R>, handle: fn(R, Request) -> Response)`; or descriptions where a library takes users' kinds ("routes are like that").
- stdlib.md: `serve(port, handle: fn(req: Request) -> Response)`, middleware is `with`.
Stage 12 must pick one; language.md §6's (data + block, path patterns as data) is the only one consistent with foundations.

**C3. The journal as a derived format.** shapes.md and formats.md: the journal is "the first format written this way", derived from shapes like `bin`, records a hash of each shape, and replay against a changed type fails. handlers.md: the journal is text, has a names table so "a journal recorded on one build can be replayed against another as long as the names still match", values written by the compiler's internal walk, "not a serialization API". One says shape-hash-refuses, the other says names-match-accepts.

**C4. Per-field attributes.** shapes.md: "no per-field attributes on derived formats"; renames/defaults are settings on the format. stdlib.md: `type Cfg = { port: Int = 8080, db_url: secret Str, region: Str }` (field default + `secret` per field) and `type Signup = { ..., plan: Plan = Free }`. Neither field defaults nor `secret` exist in language.md.

**C5. What stage 12 is.** README stage 12: http, json, cli over shapes, top-level let/assert, property tests, `ren fuzz`; done when "a small web service and its tests ... run interpreted". stdlib.md stage 12: also `Decimal` + `d`, interpolation libraries intercept, `config`, SQL rows, cursors over files/sockets/SQL, http *client*, `sqlite`, `cache`, `log`, snapshot tests. stdlib's post-12 milestone ("a JSON API on SQLite ... with retries on an outgoing HTTPS call") needs TLS, which stdlib's own roadmap puts in stage 13.

**C6. stdlib.md's roadmap claims work that isn't done.** Stage 8: "`config`, `schedule`, `retry`; the infrastructure types with in-memory implementations" — none exist (README: stage 8 "done, as a slice"). Stage 11a: "buffers leased from a pool for `Net`" — runtime-io says still to come. Stage 17: stdlib "`sim.*` for every dependency"; README 17 is "the flight recorder and the profiler".

**C7. Net's API.** Built: `Net.read(c, max) -> Bytes`. runtime-io/stdlib/streams: `Net.recv(conn, &buf)` (lent buffer), `Net.chunks(conn)` (leased), `Net.frames(conn, fmt)`; stdlib's `type Body = opaque Conn`, read with `req.body.chunks()`. runtime-io says the interpreter's primitives are on Eio; they're on `Unix.select`.

**C8. Blocks in dependency operations vs replay.** stdlib's `Queue.stream: fn(visibility, body: fn(m: Message))` and `Async`-style ops take a block. handlers.md: `over any` can't go over a dep whose op takes a block — so the journal's recorder (an `over any` handler) can't record those deps, contradicting "everything runs under sim and replay". streams.md's "two forms per resource" (a generator or a reader) is the consistent replacement.

**C9. Two `retry`s.** stdlib.md and built: `retry(5, on: Declined) fn() => ...` runs a block. shapes.md: `retry<D>(n)` as a generic handler over a dep. Pick one or say when each.

**C10. `Path`.** prelude: `opaque Str`; strings.md: `opaque Bytes` (decided, 7b). `Os.args()` built returns `Array<Str>` with no `ArgNotUtf8`. Planned, but stage 12's `cli` must target the strings.md form.

**C11. Checksums.** formats.md's examples use `aegis(...)` as ordinary code; stdlib.md's crypto list has no AEGIS or CRC32C; its `checksum` module is stage 15 and framed as no-alloc only. Storage engines need one in std before 15.

**C12. When generators exist.** stdlib/streams make `Fs.lines`, `Fs.line_reader`, `Net.chunks` wait for 11c; foundations' Staging orders 11c after 11b. Stage 12 per README follows 11c, fine, but streams.md's readers need 11c landed before http bodies and SQL rows can be cursors.

**C13. Shape of an opaque type.** shapes.md: outside its module, "opaque, built by its `parse`" (one constructor). testing.md: a generator calls "the type's `pub` functions that return one", any of them, dropping failures. json needs exactly one canonical decoding constructor; generators want all. Name the rule (a reserved member like `key`/`arbitrary`?).

---

## 4. What flottning needs from std, layer by layer

Assumption: one binary with three faces: `flottning` CLI (admin/client),
`flottning serve` (HTTP API, maybe a peer protocol), and an embedded
storage engine (WAL + memtable + SSTables or B-tree pages). Everything
under `sim` with a journal.

### Storage engine

| Need | From | State |
|---|---|---|
| Page/record layouts, superblock, versions frozen | formats layer 2 (`format disk for T`, `view`, `edit`, `formats.lock`) | decided, 7b |
| WAL: length-prefixed checksummed records, framing loop on `Short(need)` | formats + ByteCursor + checksum | cursor built; checksum missing |
| Checksums: CRC32C (WAL), xxh3/AEGIS-128L (blocks) | `checksum` module, deterministic, no-alloc | missing; slated 15 |
| `Fs` with handles: `open(path, mode) -> File`, `read_at(f, off, &buf)`, `write_at`, `append`, `sync`, `datasync`, `size`, `truncate`, `rename`, `sync_dir`, `remove`, `list`, `mkdir`, `lock` (single writer) | `Fs` dep extended | only whole-file read/write today |
| `write_then_sync` (linked) | runtime-io *proposed* | design |
| `sim.fs`: torn writes, lost unsynced writes on crash, lying fsync, ENOSPC, bit flips, latency; crash-restart in one test | `sim` | missing; the 10k-seed gate depends on it |
| Restart under sim: kill the "process" mid-run, restart `main` on the same `sim.fs` | `sim` + Async | missing |
| Memtable: ordered map (skiplist/B-tree), range scan cursors | `collections.OrderedMap` | missing |
| Merge iterator over N SSTables | cursors over `Array<SstReader>` (streams.md Later: dynamic N-way merge) | workaround documented |
| Bloom filters, `BitSet`, fast unseeded hash | `collections`, `x.hash()` | hash built; rest missing |
| Compaction in the background, bounded | `Async.background` / `Async.beside`, `sync.semaphore` | services stage |
| Lock-free reads of the current version set | `snapshot` (decision 10) | 11b |
| Block cache | `cache` (LRU, size-weighted) or actors with `evict: Lru` | missing / services |
| Compression of blocks | zstd (FFI) or a Ren LZ4 | stage 13 |
| Keys as bytes with ordering | `Bytes` ordering, `b.compare` | check exists |
| Static checks: `assert PageHeader.disk.size == 4096` | top-level `assert` + format shapes | designed |
| No-alloc hot path | `Alloc` | 15 |

### Server

| Need | From | State |
|---|---|---|
| HTTP/1.1 server: keep-alive, chunked bodies, size limits, timeouts per request/header/idle | `http` in Ren over `Net` | missing |
| Router: path patterns, methods, params → user's `Route` enum (language.md §6) | `http` | missing; design conflict C2 |
| JSON request/response over shapes, errors with paths | `json` | missing |
| Middleware as `with`/`over`: request id, logging, auth, rate limit, CORS, compression | handlers, `over any` | mechanism built |
| Auth: API tokens (constant-time compare), HMAC-SHA256 signed tokens, Argon2id passwords, session cookies | `crypto`, `http.cookie` | missing (crypto stage 13 per stdlib) |
| TLS, or "terminate at a proxy" for 1.0's first cut | `tls` (rustls) | stage 13 |
| Graceful shutdown: stop accepting, drain, flush WAL, fsync, exit 143 | `Net.accept_until`, cleanup deadline, `finally` | **built** |
| Backpressure and limits: max connections, max in-flight, per-client rate limit | `Async.scope(max:)`, semaphore, rate limiter, actors per key | partly built |
| Structured logs = trace stream; metrics; health/readiness endpoints | `log`, `trace`, `metrics` | missing |
| Request ids, ids for records | `uuid` v7 via `Random` + `Clock` | missing |
| Time formatting (RFC 3339 in JSON, HTTP dates) | `time` module | missing |
| Peer protocol if replicated: framed binary over TCP, `Net.connect`, `sim.net` partitions/delays | formats + `Net` client + `sim.net` faults | client connect and faults missing |
| Watches/streams to clients (SSE or long-poll) | `http` SSE, actors with subscribers | missing |
| Config at startup from env/file, `secret` fields kept out of logs/journal | `config`, `secret` | missing (C4) |
| Architecture asserts: "the request path never touches `Fs` except via the engine" | `assert f.uses <= [...]` | designed |

### CLI

| Need | From | State |
|---|---|---|
| Argument parsing from a type: subcommands as a sum type, flags as record fields, positionals, `--help` generated, typed errors | `cli` over shapes | missing; metadata question (Q4) |
| Non-UTF-8 args/paths | `Os.args() ! ArgNotUtf8`, `Path = opaque Bytes` | decided, not built |
| Config: file (toml) + env + flags, precedence, defaults | `config`, `toml` | missing; toml is stage 13 per stdlib |
| Output: human (tables, aligned columns, colors when TTY) and `--json` derived from the same type | `fmt` (pad/align), `json`, TTY detection, `Os.is_tty`/`Console` | missing |
| Progress for long ops (import, compaction) on stderr, suppressed when not a TTY | `Console.error`, a tiny progress helper in `fmt`/`term` | missing |
| Exit codes from error tags (`main` failing → code) | `Os.exit`, errors.md `main` | exit missing |
| HTTP client to talk to a running server (status, admin) | `http.client` + `Net.connect` + DNS | missing |
| Reading stdin (import data), files, globbing | `Os.stdin` cursor, `Fs.list`, `path` | missing |
| Signals: Ctrl-C cancels cleanly | `Signal.interrupt` → cancellation | partly built |
| Offline admin commands on the data dir (verify, dump pages, repair) | storage engine + formats `ren explain` | depends on engine |
| Tests: run `main` with `test_os([...])`, captured console, `mem_fs`, golden output | testing | built mechanisms |

### Cross-cutting (all three)
- **One derivation mechanism** (`T.shape`) serving json, cli, config, bin, property-test generators, and (ideally) the journal — five consumers, one walk.
- **Errors**: settle the tag convention so `json.DecodeError(at, expected, found)`, `FormatError`, `FsError`, `NetError`, http status mapping compose in one `!` row.
- **Deterministic everything**: DNS, time zones, hashing, `Random` for uuid, all owned.
- **`sim` coverage**: fs and net faults are what 10k seeds actually test; without `sim.fs`, the storage engine's simulation story is empty.

### Suggested stage-12 cut (for the design workflow to argue with)
Must: top-level `let`/`assert` (pure), `T.shape` + shape requirement, `json`, `cli`, `config` (env + defaults), interpolation, http/1.1 server + router (enum + block) + client over `Net.connect`, `log`, property tests + `ren fuzz`, `Os` env/exit/stdin, `Fs` handles + sync, `sim.fs` basic faults, `checksum` (CRC32C). Defer: TLS, crypto beyond HMAC/SHA-256, sqlite, toml, compression, HTTP/2, `bin`, `mock<D>`.

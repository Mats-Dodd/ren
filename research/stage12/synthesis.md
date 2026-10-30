# Stage 12 synthesis: one small standard library for flottning

Inputs, all in this folder: `grounding.md` (G), `research-http.md` (H-Ln),
`research-data.md` (D-Ln), `design.md` (§n), `programs-cli-server.md`
(P1, F#n), `programs-storage.md` (P2), `judge-ergonomics.md` (JE),
`judge-coherence.md` (JC). Nothing in the repo was edited. Where the
judges agree I state the result. Where they split I say so and make a call.

**Blocking first:** flottning isn't described anywhere in the repo. Every
call below assumes **one node, one binary, its own engine (WAL plus
SSTables), an HTTP API, and a CLI that talks to it**, which is the model
P1 and P2 both wrote. If it's replicated, add a peer protocol
(`format ... for Msg` over `Net.frames`). If it's built on SQLite, `sql`
moves from the last slice to the second.

---

## 1. Verdict

Ren's standard library for flottning is **one walk, one way in and out,
one edge, and the world through dependencies**:

- **One walk.** Every derived format walks the type's shape, an ordinary
  ADT that the compiler derives as it derives `show`. That covers json,
  cli, config, query strings, SQL rows, template holes, generators and
  metric labels.
- **One way in and out.** A type that keeps a rule is read through its
  `parse` and written through its `repr`.
- **One edge.** Each transport (HTTP statuses, exit codes, json error
  bodies) maps errors to its codes in a single exhaustive `match` over
  `attempt`'s `Result`.
- **The world through dependencies.** Every byte that enters comes in
  through `Os`, `Fs`, `Net` or `Sql`, so it is journaled, simulated and
  replayable. Behaviour around a dependency (retry, trace, limit,
  transaction) is a handler `over` it.
- **Behaviour around a request** (auth, CORS, request id, streaming) is
  an ordinary function that runs the rest as a block, with the
  request's data passed as block parameters.

None of this is a new mechanism. It is the closed requirement set grown
by one member (`shape`), by-name defaults moved from parameters to
fields, and the handler and block rules already built in 10c and 10d.
All seven programs were written under these rules without an exception.

Ren's biggest lead is `uses Fs` as the simulation seam. P2's crash test
is about 25 lines and finds an acknowledged-write loss by seed, where
TigerBeetle needs about 1,250. So the stage's order is: data at the
edges first, then the disk under `sim.fs`, then HTTP.

---

## 2. Decisions for the owner

★ marks a close call. "Split" means the judges disagree.

### A. Shapes

**A1. `shape` joins the closed set of built-in requirements, with
explicit type application `json.decode<T>(b)`.**
- **Evidence:** P1 needs `<T>` where nothing else fixes `T`
  (`http.query<ListQuery>`, decoding a piped body). Debug builds pass
  the shape as a dictionary and release builds specialize it away, as
  `show` already works.
- **Alternative:** pass shapes as values, `json.decode(User.shape, b)`,
  which means writing the type twice at every call site.
- **Judges:** both high. Take it.

**A2. `Shape` and `Value` are ADTs in `std.shape`, and the only typed
doors are `view<T>` and `build<T>`.**
- `build` calls an opaque type's `parse` through a compiler-written
  dictionary entry. That is decision 3's one stored code, and it is
  written by the compiler.
- **Change (JC):** shrink `Prim` to `Int`, `Float`, `Bool`, `Str`,
  `Bytes` and `Decimal`. `Duration`, `Time`, `Path` and `Addr` become
  ordinary prelude types read and written through A3. This fixes an
  unsoundness: `Value` has no case for `Duration`, `Time` or `Path`.
- **Alternatives:** a serde-style visitor (needs typing Ren lacks), or
  formats derived by the compiler (breaks "written in Ren by anyone").
- **Judges:** both high.

**A3. ★ `parse` in, `repr` out: one rule replaces three.**
- A type is decoded through `pub fn parse(r: R)` and encoded through
  `pub fn repr(self) -> R`. A text source (flag, env, path segment,
  query, a json string) prefers `parse(Str)` and otherwise falls back
  to the shape.
- `Secret<T>` is then simply a type with `parse` and no `repr`. It
  decodes, and `json.encode` of it fails to type-check because no
  `repr` exists.
- **Evidence:**
  - Design rule 2 as written encodes an opaque type by its private
    representation, which leaks every opaque type's internals (JC A4).
  - F#5 needs `--sync group:2ms`, `FLOTT_ADDR` and `?timeout=2s`.
  - P1's `Key`, `Version` and `Lsn` already hand-write
    `str()`/`int()` accessors.
- **Alternative (JE):** keep rule 2, add "`parse` is also the only text
  hook", and for `Secret` add `Shape.Secret(of)` plus a build-time
  `check` hook on library functions so that `json.encode` can refuse
  it.
- **Judges split.** JE uses a new hook (`check` on any library call)
  to forbid encoding. JC uses a reserved name (`repr`) and needs no
  hook.
- **My call: JC.** One reserved name, symmetric with `parse`, gives
  fewer rules overall, no build-time execution beyond templates, and
  closes the opaque leak. The cost is a new reserved name.

**A4. Record field defaults are a language feature, and doc comments
ride in the shape.** Nothing else is per-field. Positionals, short flags
and renames are one settings record per call, checked at build time
when it's a top-level `let`.
- **Evidence:** every program used defaults, and no program needed an
  attribute. The Rust twins carry `#[serde]` and `#[arg]` on most
  fields.
- **Alternative:** wrapper types (`cli.Positional<T>`), which leak the
  transport into the domain type.
- **Judges:** both high.

**A5. `f.uses` is the inferred set. The build budget is counted in
interpreter steps (10⁹ per top-level value) and raised only in
`ren.toml`. Typing `call` is deferred, and shapes.md moves to the built
`over any` surface.**
- **Evidence:** the built `over any` already covers tracing, retry, the
  recorder and limits. Only `mock<D>` and `http.client<D>` need typed
  replies.
- **Judges:** both high.

**A6. The journal matches recorded values to types by name, not by
shape hash.**
- An added `Option` field or an added case replays. A removed field or
  a changed type fails, naming the type.
- **Evidence:** handlers.md built it this way, and "replay prod against
  the new build" needs it.
- **Alternative:** refuse any change to a shape's hash.
- **Judges:** JE high, JC medium.

### B. Secrets and replay (unsound as designed; fix before 12a freezes)

**B1. Secrets leave the machine only as hashes.**
- A secret read is journaled in clear in the local journal, which is
  treated as a secret-bearing file.
- `ren trace pull` and any other export replace the value with its
  hash.
- Replaying an exported journal re-reads the secret from the replaying
  environment and checks the hash. A mismatch is an explicit replay
  error.
- `Os.env_secret` goes away. `config` reads `Os.env` and builds a
  `Secret` through its `parse`.
- **Evidence (JC B):**
  - Placeholder replay sends P1's token check down a different branch.
  - The same token arrives in clear in each request's `Authorization`
    header, which the `Net`-level journal records.
- **Alternatives:** redact at export only (an exported replay then
  can't authenticate), or hash at recording time (then local replay
  needs the environment too).
- **Judges:** JC is high that the current design is unsound and medium
  on the fix. JE didn't see it. **My call** combines JC's two options.

**B2. ★ Journal at the `Http` level in 12c, not at stage 17.**
- Export can only redact headers it can see, and a `Net`-level record
  is raw bytes.
- **Alternative:** refuse to export `Net`-level journals of a server.
- **My call:** bring it forward. It is also what makes replaying one
  production request small and readable (H-L7).

**B3. Replay reports differences in `Log`; it doesn't fail on them.**
`Console` and other outputs still compare.
- **Evidence:** otherwise a reworded log line breaks prod replay
  against a new build (JC G2).
- **Judges:** high.

### C. json

**C1. Take design §2 as written.**
- One settings record. Strict by default: case-sensitive keys,
  duplicates and invalid UTF-8 rejected.
- No untagged sums.
- Error paths and byte offsets.
- Encoding writes straight to the output, with no tree.
- `json.Json` is the type for dynamic documents.
- `json.items<T>` waits for 11c.
- **Judges:** high.

**C2. `strings: Slice` stays the default.** flottning's
`Store.put` boundary calls `bytes.own()` explicitly, so a stored value
doesn't keep a 2 MB request body alive (JC C).

**C3. Growing a buffer is called `append` everywhere** (`json.append`,
`T.fmt.append`). `write` keeps meaning "into a sized range" (P2 ask 3).
**Judges:** both high.

**C4. std exports named error sets** (`json.Error`, `config.Error`,
`http.ServeError`), and the style guide says to name an application's
set once per edge (F#9).

### D. http

**D1. `serve` takes a block, and the server isn't a dependency.**
- `with live(cfg) in http.serve(...)` gives init, run and shutdown,
  with `finally` running on every exit.
- Limits are by-name parameters with finite defaults.
- `isolate: true` turns a panic into a 500 for that request.
- **Judges:** high.

**D2. ★ Routing: a user `Route` sum, with no compiler-named arms.**
- `serve<R>(addr, route: fn(req) -> R ! NotFound | ..., handle: fn(R, req) -> Response)`.
- The user's `route` is an ordinary `match` on
  `(req.method, req.segments())`. It parses keys once, so F#6 is gone.
- `serve` labels the span and the metrics with `R`'s case name, read
  through its shape. A sum's case name is a finite label, which §7's
  label rule already allows.
- This is language.md §6's `serve<R>` with the table replaced by a
  function.
- **Alternatives:**
  - (JE) for 12a, `match http.route(req)` as a marker the compiler
    recognises, then promote a route table in 12b.
  - The design's "the compiler names each arm".
- **Judges split.** Both reject the design's arm naming as action at a
  distance. JE accepts a recognized function. JC uses the sum.
- **My call: JC.** There's no recognized function, and the route list
  is the sum's cases, ready for `ren explain` and OpenAPI. A 405 stays
  hand-written, which can be revisited later.

**D3. The error edge is a `match` over `attempt`'s `Result`.**
- `fail ... as e` and `http.status_of(tag)` are removed, because
  errors.md forbids binding a whole error.
- `cli.run`'s block may return an `Int` as the exit code.
- **Judges:** both high, and P1 found it (F#10).

**D4. Request middleware is a function that runs the rest of the
request, and request data is a block parameter (no context bag).
Behaviour around a dependency is `over`.** This replaces stdlib.md's
"middleware is `with`". **Judges:** high.

**D5. Streaming.**
- `http.stream(req, status, headers, heartbeat: 15.s) fn(&out)` returns
  a `Sent` token, so a handler still returns exactly one response.
- `out.closing()` is a step that finishes when shutdown starts, and can
  be raced against the producer (F#12).
- **Judges:** high.

**D6. Client.**
- `dep Http`, where a status is data until `resp.ok()`.
- `Response.body` is a reader, the same `Body` the server uses, so one
  `send` covers the client side of a watch (JC D6).
- `retry` gains `backoff: Backoff = Exp(...)` with jitter from `Random`.
- `mem_http(routes)` is removed. A `test handler` that calls the
  server's function replaces it.

**D7. ★ `http.client<D>` and `http.expose<D>` are deferred to std.x.**
- They need `call` typed. P1's hand-written clients are about 10 lines
  per endpoint.
- **Alternative:** type `call` in stage 12 and ship it. That is the
  most unified idea in the research (H-L8): the CLI calls the server as
  a dependency.
- **Judges:** both defer, at medium and high. It stays an owner
  question because it's a taste call about 1.0's headline feature.

**D8. Scope is HTTP/1.1 with keep-alive, chunked transfer and SSE.**
- `Addr` gains `Unix(Path)`, so the CLI can talk to a local server
  without TLS.
- TLS comes in stage 13. For 1.0 the server sits behind a proxy, and
  the docs say plainly that a remote CLI uses plain HTTP until 13.

### E. cli and config

**E1. The command is an ADT.**
- A sum gives subcommands and a record gives flags. Help comes from
  doc comments.
- `cli.spec<T>(...)` is a top-level `let`, checked at build time.
- Usage errors exit 2 with "did you mean".
- **Global flags (F#2):** in a record with exactly one undefaulted sum
  field, the sum is the subcommand and the other fields are global
  flags.
- **Judges:** high.

**E2. Config is an ordered list of sources (`Defaults | File(p, at:) |
Env(prefix) | Flags(args) | Value(at:, x)`), and a later source wins.**
- Every value remembers where it came from, for errors.
- `Value` merges a record by field name, with `None` meaning "not
  given" (F#3).
- `File(p, at: "server")` loads one section with flat env names (F#4).
- Config is data passed to wirings. There is no `Config` dependency.
- **Judges:** JE high on all of it. JC high on the core, medium on the
  merge.

**E3. json only for config files in 12. toml comes in 13, unless the
toolchain needs it sooner for `ren.toml`.** JE is low-confidence either
way.

### F. Templates and sql

**F1. ★ `p"... \{x}"` is `p.template(t: Template)`, where `p` is any
value or module in scope.**
- If `p`'s type also has `check(parts, hole_shapes)`, the compiler runs
  it at build time, like an implicit top-level `assert`.
- `let DB = sql.schema(SCHEMA)` with `DB"select ..."` says which
  database a query is for, and lets `check` see the schema.
- **Evidence:** P2 found that `sql.check` can't reach the
  application's schema without a global.
- **Alternatives:**
  - Python-style `t"..."` with no hook, which is the runner-up if the
    owner wants zero implicit build steps.
  - The expected type decides what the literal means (Swift), which
    is implicit.
- **Judges:** both take the value-prefix form, JE high, JC medium. JC
  flags that `check` is a new kind of reserved member, one that can
  fail.
- **My call:** take it. Name the exception once: "a prefix's `check`
  runs at build time."

**F2. `sql` and SQLite move to the last slice of 12, or to 13 if
flottning's metadata doesn't need SQL.**
- The engine's manifest is its own log.
- When SQLite does ship, its I/O, clock and randomness go through
  Ren's dependencies (rule 3, hard for `std`).
- Pin `journal_mode=DELETE` to avoid simulating `xShmMap`.
- **Judges:** both medium-high.

### G. log, trace and metrics

**G1. Log, trace and metrics are one event stream through `dep Log`.**
- Call-site metadata is static, and spans come from the task tree.
- A metric label must have a finite shape, which is a compile error
  through `shape`.
- **Judges:** high.

**G2. ★ Log arguments are evaluated eagerly.**
- An expensive field is guarded explicitly with
  `if log.on(Debug) then ...`.
- `log.off()` in a closed world compiles the calls out (decision 4).
- **Judges split.** JE kept the `Log.enabled(site)` lowering. JC says
  lazy arguments for one library are a special case.
- **My call: JC.** "Arguments are eager everywhere" is a rule worth
  keeping.

**G3. ★ A named `uses` row, `pub type Req = uses Store, Log, Clock`,
mirroring errors.md's named error sets.**
- **Judges split.** JE (medium) wants it now. JC accepts the noise.
- **My call:** decide it in the services stage, where signatures get
  long, not in 12. It's a language change, and named error sets prove
  it composes.

### H. Storage and sim

**H1. ★ Crash semantics in `sim.fs`: at the crash step, nothing more
runs.**
- The crashed task tree is dropped without running `finally`s, and
  unsynced and torn writes are applied per seed. A restart runs `main`
  again on the same disk.
- A crash isn't a cancel: the process is gone.
- **Alternatives:**
  - (P2) cancel plus a detached disk, under which `finally`s can still
    reach `Net`, `Log` or test state.
  - (JC) cancel with every dependency detached, which is observably
    the same as kill but keeps "cancel always runs `finally`".
- **Judges split three ways.**
- **My call: JE's kill.** It's the simplest to state, it matches
  `kill -9`, it lives entirely in `sim`, and it needs no language
  change.

**H2. Library additions for 12b.**
- `Fs` handles (`open`, `read_at`, `write_at`, `append` including a
  vectored form, `sync`, `datasync`, `truncate`, `rename`, `sync_dir`,
  `list`, `remove`, `lock`), with `Fs.File` as data.
- `crc32c` and `xxh3` now, not at stage 15.
- `OrderedMap` with a nameable `Cursor<K, V>`, and `Heap`.
- `T.fmt.append`, and a view's consumed size.
- **Judges:** both high.

**H3. `FormatError`'s tags pass through engine signatures. No `map_err`
is added.** Both judges agree, at medium.

**H4. Testing docs teach collecting results per task.**
- P2's crash test wrote a captured `var` from concurrent blocks, which
  rules B and C forbid.
- `Async.each` returns per-task values, and the docs show that idiom.

### I. Prelude and std

**I1. Prelude, std and std.x.**
- **Prelude:** shared types plus the world. Add `Decimal`, `Time`,
  `Secret` and `Path` as `opaque Bytes`.
- **std:** everything else, imported by name. It is Ren source compiled
  with the compiler until packages arrive in 13.
- **std.x:** packages that move faster than the compatibility promise.

**I2. Rule 3 is hard for `std`.** A borrowed engine owns none of its
effects, or it doesn't ship in `std`.

**I3. The error-tag convention is adopted.** Common words are
payload-free. Domain tags carry a payload.

---

## 3. Stage 12 in 8 rules

1. **A type's shape is the only description.** It carries names, types,
   `Option`, field defaults and doc comments. Everything else is one
   settings record per call.
   *Traces to:* shapes.md; language.md §3's closed set, grown by
   `shape`; decision 4, since release builds specialize the walk; by-name
   defaults from 11a.
2. **`parse` in, `repr` out.** These are the only hooks for validation
   and for text.
   *Traces to:* opaque types from stage 9c; shapes.md "built by its
   `parse`".
3. **Errors become a transport's codes in one exhaustive `match` over
   `attempt` at the edge.**
   *Traces to:* errors.md's exact sets, and its rule against binding a
   whole error.
4. **A function runs a block, `over` wraps a dependency, a wiring
   installs.**
   *Traces to:* decisions 1 and 3; language.md §1 "held vs given" and
   §5; handlers.md's `over any`.
5. **Every limit has a finite default and a tagged error.**
   *Traces to:* 11a's by-name defaults; decision 7's structured tasks.
6. **Every input is a dependency read, and secrets leave the machine
   only as hashes.** Borrowed engines own nothing.
   *Traces to:* decision 11 (determinism); the 10b journal; stdlib rule
   3.
7. **A prefixed literal is a typed value handed to the prefix.** A
   prefix's `check` runs at build time.
   *Traces to:* top-level `let`/`assert` running in the interpreter
   (shapes.md); strings.md's interpolation.
8. **Observability is one event stream through `Log`.** Labels have
   finite shapes. Replay reports log differences and doesn't fail on
   them.
   *Traces to:* the README's "one stream"; rule 1, for the label check;
   decision 4 for compiling it out.

---

## 4. flottning's 1.0 needs

| Layer | std must ship for 1.0 | Can wait |
|---|---|---|
| **CLI** | `cli` over a `Cmd` ADT, with global flags and help from docs. `config` with sources and provenance. `Os.raw_args`, `env`, `exit`, stdin, `Console.is_tty`. `json` with `--json` output. The `Http` client with `Addr.Unix`. `base64` and `hex`. | `fmt.record` for human output (12c). Completions. toml (13). `http.client<D>` (std.x). Progress bars. |
| **Server** | `http.serve<R>` with limits, route sum, `stream` (SSE, heartbeat, `closing`), shutdown with drain, `isolate`. `json`. `Secret` with a constant-time `eq`. A cryptographic live `Random`. `log`, `trace`, metrics. `Net.connect` and owned DNS. `sim.net` faults (partition, delay, reset). `retry` with backoff. An Http-level journal. | TLS and HTTP/2 (13; a proxy covers 1.0). OTLP export, websocket, jwt (std.x). Query tables, OpenAPI. Idempotency keys are flottning's own code, not std. |
| **Engine** | `Fs` handles plus vectored append. `sim.fs` with crash and restart, torn writes, lying fsync, ENOSPC, bit flips. `crc32c` and `xxh3`. `OrderedMap` with a named cursor. `Heap`. Formats layer 2 (7b) with `append`. Generators (11c) for the merge. `Async.background` for flush and compaction (services). Actors for watch (services). | `snapshot` reads (11b). zstd (13). `Alloc` (15). `sql`/SQLite unless metadata needs it. `BitSet` bloom filters, which are an optimisation. |
| **All** | `shape`, `build`/`view`, field defaults, top-level `let`/`assert`, explicit type arguments, property tests from shapes, `ren fuzz`, `uuid` v7, `time` (RFC 3339). | Typing `call`. A named `uses` row (services review). |

---

## 5. Conflicts with decided docs

| Doc | Conflict | Change |
|---|---|---|
| shapes.md | `call(op, args)`, `next.call`, `Async.limit over D` | Use the built surface: `call =>`, `call.forward()`, `sync.limit() over any` |
| shapes.md | `let ROUTES = router([get(.., show_user)])` stores functions in a top-level value | Remove it. Routes are a `Route` sum plus `serve<R>` (D2) |
| shapes.md, formats.md | The journal records shape hashes and refuses a changed type | Match by name, as built (A6) |
| shapes.md | Opaque types are encoded by their representation | `parse` in, `repr` out (A3) |
| language.md §3 | The requirement set is closed | Add `shape` (A1) |
| language.md §6 | `serve<R>(routes: Array<R>, handle)` takes a table | `serve<R>(route: fn(req) -> R, handle)` (D2) |
| stdlib.md | "Middleware is `with`" | Rule 4 (D4) |
| stdlib.md | `mem_http(routes)` | Remove it. A test handler calls a function |
| stdlib.md | `Cfg { db_url: secret Str }` | `Secret<Str>`, read by `parse`. Field defaults are a language feature (A4) |
| stdlib.md | Stage 12 list (sqlite, cache, client over HTTPS); its post-12 milestone needs TLS | Split into 12a to 12d (§6). The milestone needs plain HTTP until 13 |
| stdlib.md | Roadmap claims `config` and `retry` at stage 8, pooled `Net` buffers at 11a, `checksum` at 15 | Correct the claims. `checksum` moves to 12b |
| stdlib.md | Interpolation is an open question | F1 |
| handlers.md | `secret` is listed under "Later"; a placeholder is used on replay | `Secret<T>` plus B1 |
| handlers.md, README | The `Http`-level journal is at stage 17 | 12c (B2) |
| formats.md | `write` means "into a range", while design `json.write` means "append" | `append` grows a buffer and `write` fills a range (C3). Also say what bytes a `len` field covers, and that `at` is the file offset when the view was made `from:` |
| strings.md | Template literals are missing | `p"..."` is `p.template`, with `check` (F1) |
| errors.md | No conflict | The style guide adds named sets per edge (C4) |
| runtime-io.md, streams.md | `Net.recv`/`chunks`/`frames` against the built `Net.read`; Eio against `Unix.select` | Freeze the `Net` client API in 12c and update the docs to the built primitives |
| foundations.md decision 7 | "Cancel runs `finally`" | Unchanged. A `sim` crash isn't a cancel (H1) |

**shapes.md's open questions, answered:**
- **How `call` is typed:** deferred. The built `over any` covers
  stage 12 (A5).
- **The dynamic `Value`:** an ADT in `std.shape`, behind an explicit
  `import shape`, reached only through `view` and `build` (A2).
- **Inferred or declared `uses`:** inferred (A5).
- **Build time budget:** 10⁹ interpreter steps per top-level value,
  raised in `ren.toml` (A5).

**stdlib.md's open questions, answered:**
- **What flottning needs:** §4 above.
- **How interpolation hands its parts to a library, and `sql"..."`:**
  F1.
- **Is rule 3 hard:** yes for `std` (I2).
- **The error-tag convention:** adopted (I3).
- **The prelude boundary:** I1.
- **Config sources:** E2.

---

## 6. Staging

Each slice runs interpreted first, and the native build follows the
items it depends on. The order is **12a, then 12b, then 12c, then
12d**. 12b comes before 12c because without `sim.fs` the engine's
10,000 seeds test nothing.

**12a: data at the edges.**
- **Scope:**
  - `shape` as a requirement, explicit type arguments, `Shape`/`Value`,
    `build`/`view`.
  - `parse`/`repr`.
  - Field defaults and doc comments in the shape.
  - Top-level `let`/`assert` with the step budget.
  - `json` (decode, encode, append, `Json`).
  - `cli` and `config`.
  - `Os` env, exit and stdin; `Console.is_tty`.
  - `Secret` plus B1's journal rule.
  - Interpolation, `Template`, value prefixes and `check`.
  - Property tests from shapes, saved failures, `ren fuzz`.
  - `base64`, `hex`, `time`, `uuid`.
- **Depends on:**
  - Data (item 5): by-name variants, `let ... else`, `Shape` as an ADT.
  - Bytes part 2 (7a): the `Str`/`Bytes` representation, and
    interpolation's lexer.
  - 7b's `Path` as `opaque Bytes` and `ArgNotUtf8`, interpreter part
    only.
- **Done when:**
  - P1's `flot` CLI with no network runs interpreted, with golden
    tests through `test_os`.
  - P1's API types round-trip through json, and a property test finds
    a planted bug.
  - A misspelled `cli.spec` field fails the build.
  - **Measurement:** release `json.decode<T>` on a 10-field record is
    within 1.5× of a hand-written cursor decoder, or §2's visitor
    fallback is triggered.

**12b: the disk.**
- **Scope:**
  - `Fs` handles plus vectored append.
  - `sim.fs` with H1's crash and restart, torn writes, lying fsync,
    ENOSPC, bit flips.
  - `crc32c` and `xxh3`.
  - `OrderedMap` with `Cursor<K, V>`, and `Heap`.
  - `T.fmt.append`, a view's consumed size, encode-then-edit in one
    call.
- **Depends on:**
  - 7b formats layer 2 (interpreter).
  - 11c generators, for the merge and `Wal.replay`.
  - Services' `Async.background`, for flush (otherwise a flush stalls
    every writer, which is acceptable for correctness tests).
- **Done when:**
  - P2's WAL, flush and merge run, and the crash test over 10,000
    seeds finds the planted apply-after-`release` bug (JE) and passes
    once it's fixed.
  - A replay of a failing seed reproduces it.

**12c: the network.**
- **Scope:**
  - `http.serve<R>`, `stream`, middleware functions, shutdown.
  - The `Http` client with a reader body, `Net.connect`, owned DNS,
    `Addr.Unix`.
  - `sim.net` partitions, delays and resets.
  - `retry` with backoff.
  - `log`, `trace`, metrics.
  - The `Http`-level journal with header redaction.
- **Depends on:**
  - 11a (built).
  - 11c, for bodies as readers.
  - Services: actors, for `Store.watch` and SSE.
  - 12a's json and config.
- **Done when (the README's stage 12 gate):**
  - P1's server, client and CLI run interpreted against the 12b
    engine.
  - Seeds under `sim.net` find F#16, a retried conditional put.
  - Shutdown ends SSE streams cleanly within `drain`.
  - An exported journal holds no secret in clear and replays with the
    secret re-read.

**12d (or 13): SQL.**
- **Scope:** `sql` with value prefixes, rows decoded by name,
  `transaction() over Sql`, migrations, SQLite through a Ren VFS.
- **Depends on:** 12b's `sim.fs`, F1, and the owner's answer on
  flottning's metadata.
- **Done when:** P2's catalog program runs under `sim.fs` and its
  `check` rejects a bad column at build time.

---

## 7. Risks and what to prototype or measure next

1. **flottning is undefined.** Ask the owner for one paragraph before
   12a: one node or replicated, its own engine or SQLite, what data
   model.
2. **Shape specialization has to remove the `Value` tree.** Prototype
   it now: hand-write in C what release *should* emit for
   `decode<User>` and for template holes, and benchmark that against
   the bench/native json kernel. If it can't get within 1.5×, the
   visitor alternative returns. Template holes are boxed `Value`s too
   (JC F2), so include them.
3. **`sim.fs` crash semantics.** Prototype H1 on P2's WAL in the
   interpreter's sim scheduler before freezing 12b. Check that kill
   without `finally` doesn't leave sim's own handler state
   inconsistent across a restart.
4. **`parse`/`repr` (A3).** Write `Duration`, `SyncMode`, `Addr`,
   `Secret` and `Key` through cli, env, query and json as a spike in
   the docs, to confirm that no second hook appears.
5. **Secrets and export (B1).** Confirm the `Http`-level journal can
   find secrets in headers without per-header configuration in every
   app. The default set is `Authorization` and `Cookie`.
6. **Signature length.** Track request-path `uses` rows and error sets
   in P1 at its real size. That data is the input to G3's services
   review.
7. **Slices keeping bodies alive** (C2). Measure decision 17's
   "small slice keeps a root alive" report on the server under load.
8. **SQLite VFS re-entering the scheduler from FFI** (F2). Spike it
   only if 12d is in.
9. **TLS gap.** The 1.0 story is a proxy plus plain HTTP on a Unix
   socket or localhost. Check it with the owner, because a remote CLI
   without TLS may be unacceptable.
10. **Bugs sim should find, as standing regression seeds:**
    - P2's memtable applied after `release`.
    - P1's F#16.
    - P2's illegal concurrent capture, which the compiler should
      reject.

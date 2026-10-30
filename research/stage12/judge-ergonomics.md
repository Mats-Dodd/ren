# Judge: ergonomics

Lens: a working programmer building flottning every day, against Rust
(axum/clap/serde/sqlx), Go (net/http, database/sql, Pebble) and Elixir
(Plug/Phoenix, Logger, runtime config). Inputs: `design.md`,
`programs-cli-server.md` (cited P1, with its [F#n]), `programs-storage.md`
(P2). Confidence: H / M / L.

## Verdict in one paragraph

The design's spine is right and the programs prove it: one shape walk
for json/cli/config/sql/query, one exhaustive `match` at each edge,
functions-that-run-blocks for request middleware and `over` for world
middleware, and `uses Fs` as the whole simulation seam. The daily-use
costs are concentrated in five places, all fixable without new
mechanisms: (1) long error and `uses` lists on the request path, (2)
text decoding of non-opaque types (`--sync group:2ms`, `?limit=10`),
(3) cli global flags and flag-over-config overrides, (4) where a template
`check` finds its schema, (5) SSE/long-stream shutdown. Three things are
unsound as written and must change before 12a is frozen: binding a whole
error at the edge (§3.5), `Secret` having a shape for decode but not
encode (§1.4), and the "compiler names the arm" span label (§3.2).

## Area by area

### 1. Shapes (§1.1 to §1.5)

**Recommend as designed:** `shape` joins the closed requirement set;
explicit type application `json.decode<User>(b)`; `Shape`/`Value` as
ADTs behind `view`/`build`; field defaults as a language feature; doc
comments in the shape; settings records not attributes; budget in steps.
Evidence: P1's `PutBody`, `ListQuery`, `Flot`, `FileCfg`, `TableMeta`
all go through one walk with zero per-field annotations, where the Rust
twins carry `#[serde(default)]`, `#[arg(long, global = true)]`,
`skip_serializing_if` on most fields. That is the single biggest daily
win over Rust. (H)

**Change: rule 2 becomes "`parse` is the only validation hook and the
only text hook" (P1 [F#5]).** A text source (flag, env, path segment,
query, json string for a prim) reads a type through its `pub fn
parse(Str)` if it has one, otherwise through its shape. Without it
`SyncMode`, `Addr` and `Duration` can't come from `--sync`,
`FLOTT_ADDR` or `?timeout=2s`, and every program grows an edge type.
Also fix the prim encodings once in `json`'s docs (`Duration` "2ms",
`Time` RFC 3339, `Bytes` base64, `Decimal` number). Objection: a
non-opaque type with a `parse` now has two decoders (text vs shape).
Answer: it's one per source kind, decided by the source, not the type;
Go's `TextUnmarshaler` and Rust's `FromStr` are the same rule. (H)

**Unsound: `Secret<T>` (§1.4).** It "decodes like `T`" (needs a shape)
but "has no `view`, so `json.encode` refuses at the call". With one
`shape` requirement there is no way to have the first without the
second, and `json.encode` is a library walking a `Shape` at run time in
debug builds, so "refuses at the call" has no mechanism. **Fix with the
mechanism §6.1 already introduces:** add `Shape.Secret(of: Shape)`, and
let a library function carry a build-time `check` over constant shapes
(the same hook as the template `check`). `json.encode`'s check rejects a
shape containing `Secret`; `config`/decode accept it. One hook, two uses,
no second requirement. Objection: generalising `check` beyond templates
widens build-time execution. It's the same interpreter, same budget. (M)

**Journal by names (§1.3):** right; it's what lets "replay prod against
the new build" survive an added `Option` field. (H)

### 2. json (§2)

**Recommend as designed** (strict, paths in errors, zero-copy slices,
encode without a tree, `json.Json` for dynamic, no untagged sums). (H)
**Changes:**
- Export the error set once: `pub type json.Error = ! JsonSyntax(..) |
  JsonMismatch(..) | JsonLimit(..)`. P1's `routes` and `ClientError`
  each spell all three with payloads; that's errors.md's named sets,
  used by std itself. (H)
- **Naming clash (P2 ask 3):** `json.write(&out, x)` appends while
  formats.md's `write` fills a range. Make every "grow a buffer" call
  `append` (`json.append`, `T.fmt.append`), keep `write` for ranges. (H)
- The 1.5x release-decode target is the right gate; publish it as a
  bench before 12b depends on it. (M)

### 3. http (§3)

**Server as a function with a block, routing as a `match`, response as
a value, middleware as functions, errors as one edge `match`:
recommend.** Evidence: P1 server is ~150 lines vs axum ~190; no context
bag; the engine's `finally` runs on every exit where axum's
`store.close()` is skipped by an early `?`; the in-process `test handler
in_process for Http` replaces `mem_http` with no new feature. Against
Elixir: Plug.Router's `get "/v1/keys/:k"` is the same shape as the
`match`, so Elixir programmers will feel at home. (H)

**Unsound: §3.5's `fail Invalid | JsonMismatch(..) as e => problem(422,
e)` and `http.status_of(tag)`.** errors.md (line 213) forbids binding a
whole error. Adopt P1 [F#10]: the edge matches on `attempt`'s `Result`
where it needs the value, and `status_of` takes a `Result` over the
prelude words only. (H)

**Unsound / magic: "the compiler names each arm" (§3.2).** The `match`
that routes is two calls under `serve` (P1 [F#1]); the compiler would
have to guess which. **Recommend for 12a:** route labels are explicit
and static: `http.route(req)` returns `(Method, Array<Str>)` and a
`match` directly on it gets its arms named; two such matches per request
is a build error. That's one recognised function, which is a small
special case, so state it as the rule "a span label is a pattern, and
only a pattern written on `http.route` is one". **12b:** promote §3.2
Alt A (route enum + table decoded by shape) because it also fixes
[F#6] (`try Key.parse(k)` per arm), [F#7] (405s by hand) and [F#8], and
gives OpenAPI a list. Decide [F#13] (constructor names in a table) by
making a payload-free reference to a case, `Route.GetKey`, a build-time
value (a `shape.Case`), not a string. Objection: two routing styles in
one std. Answer: the table is sugar that lowers to the same `match`. (M)

**Gaps to add to §3 (all by-name parameters, no new mechanism):**
- `http.query<T>(req)` and form bodies, with cli's flag mapping (P1
  [F#8]). (H)
- `http.stream(..., heartbeat: 15.s)` and `out.closing()` as a raceable
  step so streams end cleanly on shutdown rather than waiting `drain`
  and being cut (P1 [F#12]). Without it every flottning deploy cuts every
  watcher; axum's `KeepAlive` is free. (H)
- `retry(..., backoff: Backoff = Exp(..., jitter: Full))`, policy as
  data, jitter from `Random` (P1 [F#15]). (H)
- `Idempotency-Key` support belongs to flottning, not std, but the
  sim-found conditional-put bug (P1 [F#16]) is the strongest ergonomic
  argument for the whole design; put it in the stage's demo. (M)

**Client as a `dep Http`, `http.client<D>` deferred: agree** for 12;
P1 shows hand clients are ~10 lines per endpoint, same as reqwest. (M)

### 4. cli (§4)

**Recommend the ADT derivation** (help from doc comments, build-time
checked `cli.spec`, usage exit 2, "did you mean"). P1's flot is ~170
lines vs clap ~150, with no attributes. (H)
**Changes:**
- **Global flags rule (P1 [F#2]):** a record with exactly one sum
  field without a default: the other fields are global flags, the sum
  is the subcommand. Every real CLI needs this on day one. (H)
- **`cli.run`'s block may return `Int` as the exit code** (P1 [F#10]),
  so `Os.exit` isn't called inside a block. (H)
- Positionals keyed by case: `positional: [("Put", "key"), ...]` is
  strings checked at build. Acceptable for 12a; switch to `Cmd.Put.key`
  build-time references once [F#13]'s case references exist. (M)
- `fmt.record(x)` (aligned "doc: value" from the shape) for human output
  (P1 [F#11]) in 12b; most commands then need no `human` block. (M)

### 5. config (§5)

**Recommend** sources as an ordered ADT, provenance in errors, config as
data passed to wirings. Against Elixir's `runtime.exs` and Go's Viper
this is stricter and better. (H)
**Changes:** `config.Value(at:, x)` merges any record by field name with
`None` = not given, which legalises P1's one-line override types (P1
[F#3]); and `File(p, at: "server")` so a program loads one section with
flat env names (P1 [F#4]). Both are settings fields. Reject a `Partial<T>`
type former. (H) Ship a minimal `toml` in 12 only if the toolchain needs
it anyway; json is enough for flottning. (L)

### 6. Templates and sql (§6)

**Recommend `p"..."` calling `p.template`, with optional build-time
`check`.** Holes as shaped values plus `Query` fragments plus rows by
column name gave P2's catalog ~35 lines, level with sqlx and ~20 under
Go. (H)
**Change (P2's ask 2): the prefix may be a top-level value, not only a
module.** `let DB = sql.schema(SCHEMA)` then `DB"select ..."`, calling
`DB.template` and `DB.check`. Otherwise `std`'s `sql.check` can't see
the application's schema without a global. It also says which database
a query is for when there are two. (H)
**On SQLite in 12 (§6.3):** P2 says the engine's manifest should be its
own log and SQLite should hold application metadata. Agree. So SQLite is
not on the 10,000-seed critical path; move `sql`/`sqlite` to the end of
12b or 13 unless the owner's flottning paragraph says otherwise. (M)

### 7. log, trace, metrics (§7)

**Recommend** one event stream through `dep Log`, static call sites,
`Log.enabled(site)` guard, labels with finite shapes. (H)
**Ergonomic cost:** `uses Log, Clock` on every `pub fn` on the request
path (P1 [F#14]), where Rust, Go and Elixir log through a global.
**Recommend a named `uses` row**, `pub type Req = uses Store, Log,
Clock`, mirroring errors.md's named error sets
(`pub type Refusal = ! ...`). Same rule, other row. Objection: it hides
what a function touches. It names it once; the compiler still checks
every row, and `f.uses` asserts still see the expansion. (M)

### 8. Prelude/std split, error convention (§8)

**Recommend** as designed, plus: the stdlib style guide says "name your
error set once per edge" ([F#9]), and std exports its own sets
(`json.Error`, `http.ServeError`, `config.Error`). (H)
**Change:** let `FormatError`'s tags flow through engine signatures
instead of mapping each `view` to `Corrupt` (P2 "map_err"). Ren has no
`map_err`; don't add one. If mapping recurs past flottning, revisit
errors.md, not std. (M)

### 9. Storage engine needs (§9)

**Recommend §9's order: `sim.fs` with crash/restart before HTTP.** P2's
crash test is ~25 lines vs TigerBeetle's ~1,250-line harness, and finds
the group-commit bug by seed. This is the slice where Ren is clearly
ahead of all three comparison languages. (H)
**Change to P2's crash semantics:** P2 proposes "a crash is a cancel
plus a detached disk", so `finally`s run. Prefer **a crash kills the
task tree without running `finally`s, in `sim` only**, like `kill -9`.
Running `finally`s lets code after the crash point touch non-`Fs` deps
(`Log`, `Net`, a counter in another handler) and hides bugs that depend
on cleanup not happening. The sim owns the scheduler, so this is sim
machinery, not a language change. Objection: the language says
cancellation always runs `finally`. Answer: a crash isn't cancellation;
the process is gone. (M)
**Add to 12b's lists** (P2 "What std is missing"): vectored
`Fs.append(f, [a, b])`; `Fs.File` as data (id + incarnation);
nameable cursor types (`OrderedMap.Cursor<K, V>`) so a merge `Source`
sum can hold one; `collections.Heap`; `T.fmt.append(&out, v)`; a view's
consumed size (`v.end`); `encode(v) fn(&h) => ...` as one call so
writing a checksum isn't an `edit` with a `try` that can't fail. (H)

## Problems the programs contain (they argue for sim, not against the design)

- **P2 §4, memtable ordering after `release`.** `write` applies to
  `mem` *after* `try release Wal.sync(lsn)`. Two puts of one key can
  apply out of LSN order, and an older value overwrites a newer one
  unless `apply` compares `Seq`. Worse, a flush triggered by a later
  writer can `truncate_before(lsn)` while an earlier writer, still
  released, hasn't applied its record: that record is dropped from the
  WAL and lands in the new memtable only, so a crash loses an
  acknowledged write. Exactly the class of bug `sim` finds; the stdlib
  docs should show the correct pattern (apply before release, or apply
  keyed by `Seq`, and flush only up to the lowest unapplied LSN).
- **P2 crash test writes a captured `var acked` from `Async.each`'s
  concurrent block.** By foundations.md rule B/C that should be
  rejected; the test needs per-writer results joined after the scope.
  The ergonomics point: the obvious test is illegal, so std's testing
  docs need the idiom (e.g. `Async.each` returning per-task values).

## Added mechanisms where an existing one would do

- `http.status_of(tag)` (doesn't exist and can't): use `attempt` + match.
- Per-arm compiler naming: replace with a pattern on `http.route`, later
  with the route table.
- `Partial<T>`, `Config<T>` dep, wrapper types for cli metadata: all
  correctly rejected; keep them out.
- `json.write` vs formats `write`: one word, two meanings; rename.

## What flottning needs that the design lacks

1. A one-paragraph definition of flottning (still the first blocker).
2. Text-hook rule for non-opaque types (§1 above).
3. Clean shutdown of long streams and heartbeats.
4. Backoff with seeded jitter.
5. Query/form decoding.
6. `sim.fs` crash semantics, vectored append, nameable cursors, `Heap`.
7. A peer/replication story if replicated (only a row in §9 today).
8. TLS: a proxy for 1.0 is acceptable for the server, but the CLI must
   then reach a remote server over plain HTTP; say this explicitly or
   pull client TLS into 12b.

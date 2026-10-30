# Judge: coherence

Lens: few decisive rules that compose, no special cases, deps for the
world (not interfaces), everything under sim and replay, cost. Inputs:
`design.md` (§n), `programs-cli-server.md` (P1, its F#n),
`programs-storage.md` (P2), checked against language.md, errors.md,
shapes.md, README.

**Verdict.** The design is coherent at its core. Shapes are the one
walk; `parse` is the one way in; rule 4 (one `match` at the edge) and
rule 5 (a function runs a block, `over` wraps a dependency) hold up in
all seven programs. No program needed an exception to a rule (P2
scorecard), and the error edge and the sim tests beat every twin. The
problems are in five places. Two are unsound: secrets under replay, and
the §3.5 edge code. Two are special cases a general rule would cover:
`Secret`'s encoding, and the lazy arguments of a log call. One is magic:
the compiler naming route arms. A few flottning needs are missing
(below). Each section gives a recommendation, the evidence, the
strongest objection and a confidence.

---

## A. Shapes (§1)

**A1. `shape` joins the closed requirement set (§1.1). Take it. High.**
`shape` is compiler-derived for every function-free type, exactly as
`show` is. It's not the withdrawn "any method is a requirement" idea
(language.md §3), so the set stays closed and grows by one. Explicit
type application (`json.decode<T>`) is needed: P1 writes
`req.bytes() |> try json.decode<PutBody>` and `http.query<ListQuery>`,
where nothing else fixes `T`.
*Objection:* the set is called closed, and this opens it. The answer is
that it's a compiler-derived member, never user-written, so nothing
changes in kind.

**A2. `Shape`/`Value` as ADTs with `view`/`build` as the only typed
doors (§1.2). Take it, with one change. High on the design, medium on
the change.**
- *Unsound as written:* `Prim` lists `Time`, `Duration`, `Path` and
  `Decimal`, but `Value` has no `VTime`, `VDuration` or `VPath`. So
  `build` can't receive a `Duration`, and F#5 (`timeout: "2s"`,
  `--addr`, `--sync group:2ms`) has nowhere to go.
- **Change: shrink `Prim` to `Int`, `Float`, `Bool`, `Str`, `Bytes`
  and `Decimal`.** `Duration`, `Time`, `Path` and `Addr` become
  ordinary prelude types that are `Opaque` over a prim (or have a text
  form, A4). Their json and text encodings are then not a list of
  per-format decisions (F#5's "decision on the prim encodings"). They
  fall out of the one rule for opaque types. That's fewer kinds, and no
  format special-cases a prelude type.

**A3. Journal matches by name (§1.3). Take it. Medium.** It's what lets
you "replay prod against the new build". *Objection:* with a hash
compare you could say what replay fails on, and with matching by name
you can't. But see G2: if the journal also compares `Log`, a reworded
log line breaks replay, and by-name matching on data won't save it.

**A4. Opaque encoding: replace "encoding writes the representation"
(rule 2) with a symmetric pair. Medium-high. This is the biggest
coherence fix in the shapes area.**
- *Problem 1:* rule 2 encodes an opaque type by its private
  representation, so `json.encode` leaks the internals of every opaque
  type. That breaks `opaque` by the side door.
- *Problem 2:* `Secret<T>` then needs a special case: "decodes like T,
  has no encode".
- *Problem 3:* F#5 needs a text hook for non-opaque types, and proposes
  a second rule about `parse(Str)`.
- **One rule covers all three:** a type is decoded through `pub fn
  parse(r: R)` and encoded through `pub fn repr(self) -> R`. A type
  with only `parse` decodes but doesn't encode. Text sources (flags,
  env, query, path segment) prefer `parse(Str)` and fall back to the
  shape.
  - `Secret` is just a type with `parse` and no `repr`: no special case.
  - `Key`, `Version` and `Lsn` already write a `str()`/`int()` accessor
    in the programs, so this names what they do anyway.
  - `SyncMode` gets `parse(Str)`/`repr` for `group:2ms` without
    becoming opaque.
- *Objection:* it adds a reserved name (`repr`). It replaces two rules
  and a type-specific exception, though, so the count goes down.

**A5. Field defaults as a language feature, and doc comments in the
shape (§1.4). Take both. High.** The by-name-parameter rule moves to
fields, and every program used it.

**A6. Build budget in steps, `f.uses` inferred, `call` typing
deferred (§1.5). Take all three. High.** P2's `assert routes.uses <=
[Store, Log]` works with the inferred set.

---

## B. Secrets and replay: unsound as designed (§1.4, §5, §7)

This is the most important correctness finding.

1. **Placeholder replay diverges.** `Os.env_secret` is journaled
   redacted, and "a replay hands back a placeholder". P1's
   `authenticate` branches on `cfg.admin_token.eq_const(tok)`, so a
   replayed request authenticates differently and replay fails exactly
   where it matters.
2. **Redaction leaks.** The same token arrives in every request's
   `Authorization` header. The design keeps the journal at the `Net`
   level (§3.8), so the secret is journaled in clear anyway.

**Recommend:**
- **Redact at the journal's export (`ren trace pull`), not when it's
  recorded.** A journal is a secret-bearing artifact.
- **Or journal a secret read as its hash.** Replay re-reads the secret
  from the replaying environment and checks the hash; a mismatch is an
  explicit replay error.
- Either way, `Os.env_secret` as a second env API goes away. `config`
  reads `Os.env` and builds a `Secret` through its `parse` (A4).
- Request-header secrets need the `Http`-level journal (§3.8's
  deferred alternative). It should come forward, at least for redacting
  `Authorization`.

Confidence: high that the design as written is unsound; medium on which
fix to take.

---

## C. json (§2)

**Take it. High.** One settings record, strict at no cost, paths in
errors, no untagged sums, encode with no tree.
- **`strings: Slice` as the default** is the right default for a
  request-scoped decode. But flottning stores PUT values in a memtable,
  and a slice would keep a whole 2 MB body alive per small value.
  - The engine's `Store.put` boundary should copy: an explicit
    `bytes.own()` at the domain edge, where the value goes into storage.
  - The default stays.
  - Medium.
- **Naming (P2 ask 3):** take P2's naming. `append(&out, x)` is the
  growing-buffer verb in json and formats alike, and `write` keeps
  meaning "into a sized range". One verb, one meaning.

---

## D. http (§3)

**D1. `serve` takes a block, and the server isn't a dependency (§3.1).
Take it. High.** `with live(cfg) in http.serve(...)` gave P1 init, run
and shutdown, and a `finally` that runs on every exit, which axum gets
wrong.

**D2. Routing is a `match`. Take it, but drop "the compiler names each
arm" (§3.2, F#1). Medium-high.**
- Naming the arms is action at a distance: which `match`, two calls
  below `serve`? F#1's `http.route(req)` marker is still a function the
  compiler recognises, which is magic by another name.
- **The composing answer uses mechanisms the design already has:** the
  user writes `fn route(m, segs) -> Route ! NotFound | BadKey` as an
  ordinary `match`, and `Route` is a sum. `serve` labels the request
  span with the case name of the `Route` value, read through its shape.
  §7 already says a label must have a finite shape, and a sum's case
  name is exactly that.
- That fixes F#1 (no magic), F#6 (`Key.parse` once, in `route`) and
  F#13 (no string table of constructors), with no new mechanism. It
  also gives `ren explain` a list (the sum's cases).
- 405 stays by hand (F#7). Accept it.
- *Objection:* it's two functions instead of one `match`. But
  "domain-first and listable" is DDD taste, and the alternative is
  compiler magic.

**D3. Unsound code in §3.5 (F#10). Fix it. High.**
`fail Invalid | JsonMismatch(..) as e` and `http.status_of(tag)` both
bind a whole error, and errors.md forbids that ("never binds a whole
error to a variable"). The edge is a `match` over `attempt`'s
`Result`, as P1's `report` does. Drop `status_of`, or make it take a
`Result` of only the prelude words. Also take F#10's `cli.run` block
`-> Int` as the exit code.

**D4. Middleware: request middleware is a function and the user is a
block parameter (§3.4). Take it. High.** P1 confirms there's no context
bag. It's the right reading of "held vs given".

**D5. Streaming with a `Sent` token. Take it, plus F#12. High.**
`out.closing()` (a raceable step that finishes when shutdown starts)
and `heartbeat:` as by-name parameters are both rule 6 and rule 5, not
new mechanisms.

**D6. Client (§3.6). Take it, with one fix. Medium.**
- *Gap:* `dep Http` has only `send`, but P1's `watch` calls
  `Http.stream`. Make `send`'s `Response.body` a reader (the same
  `Body` cursor the server uses), so one operation serves both.
- Take F#15's `backoff: Backoff` as data, with jitter from `Random`.
- §3.7 (defer `http.client<D>`): take it. High.

---

## E. cli and config (§4, §5)

**Take the ADT derivation and the source list. High.** Take F#2
(global flags: a record with exactly one undefaulted sum field) and F#4
(`at:`) as written. They're settings and one shape rule, not new
mechanisms.

**F#3 (overrides types).** P1's fix is `Value(at:)` merging by name,
with `None` meaning "not given". It's the same by-name matching as the
journal (A3), so it composes. Take it for 12a. Medium.

There's a cleaner version worth a look: §5 already has a `Flags(args)`
*source*.
- If `cli` can leave a case's flags as raw `cli.Rest` while its help is
  derived from a named record type, the `XOverrides` types disappear.
- That needs a type named in a spec, which Ren doesn't have, so leave
  it for later.

---

## F. sql and templates (§6)

**F1. Templates: take the *value-prefix* form of P2's ask, not a
reserved member found on a module. Medium.**
- *Problem:* `sql.check` can't see the application's `SCHEMA` (P2 §3).
- *Problem:* README says a reserved member "can't fail or use a
  dependency", and `check` fails by design. That's a new kind of
  reserved member.
- **One rule:** `p"..."` is `p.template(Template)`, where `p` is any
  value or module in scope, found the way an operator is found on its
  left side's type.
  - If `p`'s type also has `check`, the literal is checked while
    building, like an implicit top-level `assert`. That's the one
    stated exception, and it's a build-time rule, not a runtime one.
  - `let DB = sql.schema(SCHEMA)` with `DB"select ..."` answers "which
    database" explicitly.
- *Objection:* a check that runs implicitly. The runner-up, `t"..."`
  with no hook, is acceptable if the owner wants zero implicit build
  steps.

**F2. Holes carry `shape.Value` (§6.1). Cost flag.** Every hole is
boxed at run time unless release specialization removes it, as it must
for `json`. Add holes to §1.2's 1.5× measurement.

**F3. SQLite. Agree with P2 ask 6.**
- The engine's manifest should be its own log (P2 program 1's format
  with a `VersionEdit` type). SQLite and `sql` move to stage 13 unless
  the owner says flottning needs SQL for application metadata.
- *Cost risk if kept:*
  - Every SQLite page I/O becomes a journaled `Fs` call, so the
    journal's size is unbounded.
  - WAL mode's `xShmMap` must be simulated too, so pin
    `journal_mode=DELETE` or exclusive locking.
  - A C VFS calling back into Ren's scheduler has to re-enter the
    runtime from FFI.
- Medium-high.

---

## G. log, trace and metrics (§7)

**G1. Log as a dependency, metrics derived from events with
finite-shape labels, spans from the task tree. Take all three. High.**
The label check reusing `shape` is the best composition in the design.

**G2. Unsound for replay:** "`Log` is an output dependency… a replay
compares it." Comparing logs means a reworded log line fails a prod
replay against a new build, which contradicts §1.3's whole purpose.
Journal `Log`, but replay should *report* differences in it, not fail
on them. That's one sentence. High.

**G3. Special case: "the field expressions aren't evaluated" when a
level is off.** That's lazy evaluation for one library's calls. Drop
it. Arguments are eager everywhere, and an expensive field is guarded
explicitly (`if log.on(Debug) then ...`). Keep the static per-site
metadata and the `log.off()` compile-out, which are ordinary
specialization. Medium-high.

**G4. `uses Log` on every `pub fn` (F#14). Accept it.** It's rule 7's
price, and private functions infer it.

---

## H. Storage (P2) and sim

- **Crash semantics: "a cancel plus a disk that detaches" (P2 §4).
  Take it, extended. Medium-high.**
  - As proposed, the `finally`s that run after the crash can still
    reach *other* dependencies: `Net` acks, `Console`, the test's own
    state. A real crash can't.
  - **Fix:** at the crash step, every dependency the crashed block's
    tasks hold detaches, not only `Fs`. Their `finally`s run against
    sinks that drop everything.
  - That keeps cancel and `finally` meaning what they mean, and puts
    the whole fault model in `sim`. No language change.
- **Group commit from decision 10 plus one `release`:** say so in the
  docs. It's the strongest argument for the handler model.
- **P2's std asks: take them all.** Vectored `Fs.append`, nameable
  cursor types (`OrderedMap.Cursor`), `Heap`, a view's consumed size,
  "`at` is the file offset when you viewed with `from:`". Each is
  library surface, not mechanism.
- **Language gaps P2 assumed silently, to decide:**
  - Handler-private helper functions (`fn write` inside `handler
    engine`).
  - Error mapping besides `match`, P2's `map_err corrupt`.
    Recommendation: let `FormatError`'s tags through; don't add
    `map_err`.

---

## I. What flottning needs that the design lacks

1. **Watch / subscriptions.** `Store.watch` returns a reader fed by
   other requests' writes, which is language.md's actors ("a document
   with subscribers"). §9 doesn't map it, and P1's SSE endpoint depends
   on it. Put it on the services-stage row explicitly.
2. **`base64`/`hex` in 12a.** P1 uses `base64` on both the client and
   the server. stdlib.md lists it, but design §8.1 omits it.
3. **Unix-socket listen in `http.serve`.** §3.6 tells the CLI to talk
   over a Unix socket, but `serve` takes an `Addr`. `Addr` needs a
   `Unix(Path)` case.
4. **A CSPRNG live `Random` and `Secret.eq_const`.** P1's `init` mints
   tokens with `Random.token`, so state that the live handler is
   cryptographic.
5. **An idempotency story for retried conditional writes (F#16).** It's
   flottning's API, but sim finds it in the first hundred seeds. Plan
   for it.
6. **Background flush and compaction.** Already staged (services), but
   until then a flush stalls every writer, which affects any 12b
   benchmark.
7. **The owner's paragraph on flottning (§0).** Single node or
   replicated, and its own engine or SQLite. Every recommendation above
   holds under "single node, own engine". Replication adds a peer
   protocol (`format … for Msg` over `Net.frames`) that nothing here
   designs.

## Summary of changes to design.md

| Area | Change | Confidence |
|---|---|---|
| §1.2 | `Prim` shrinks to six; `Duration`/`Time`/`Path`/`Addr` become ordinary types | medium-high |
| rule 2 | becomes `parse` in and `repr` out; text sources prefer `parse(Str)`. Removes the `Secret` special case and F#5's second rule | medium-high |
| §1.4/§5/§7 | secrets: redact at export or journal a hash; no `Os.env_secret` | high (unsound now) |
| §3.2 | no compiler arm naming; a `Route` sum's case name labels spans | medium-high |
| §3.5 | the edge is over `attempt`; no whole-error binding | high |
| §3.6 | `Response.body` is a reader on the client too | medium |
| §6.1 | the prefix is any value in scope; `check` sees the schema through it | medium |
| §6.3 | the manifest is the engine's own log; SQLite moves to 13 by default | medium-high |
| §7 | replay reports `Log` differences and doesn't fail on them; no lazy arguments | high / medium-high |
| §9 | add `base64`, Unix listen, watch → services, a crash that detaches all dependencies | high |

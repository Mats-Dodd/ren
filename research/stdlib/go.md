# Go's standard library as prior art

What Ren's std should learn from Go's: where Go draws the language/std
line, how its shared interfaces made libraries fit, and what it had to
retrofit. Written 2026-10-30 against the Go tree at `/tmp/ren-refs/go`
(commit `6c49ac3`, 2026-10-26, the Go 1.27 development tree). Paths are
under `src/` unless they say otherwise. Ren's side is
[foundations.md decision 20](../../foundations.md#20-what-the-language-owns-and-what-std-owns),
[stdlib.md](../../stdlib.md), [deps.md](../../deps.md) and
[streams.md](../../streams.md).

## The lessons, ranked

Ranked by how much each should change Ren's design, most first.

1. **Ren has a source protocol and no sink protocol.** Most of Go's
   composition happens on the `io.Writer` side: hashes, compressors,
   encoders, TLS and HTTP responses are all Writers that wrap Writers.
   Ren's cursors cover reading. Nothing in stdlib.md or streams.md
   defines what a sink is; `w: Writer` at streams.md:698 is used and
   never declared. ([§1](#1-the-shared-interfaces))
2. **Optional abilities found by type assertion break under wrapping.**
   `http.ResponseWriter`'s `Flusher`/`Hijacker`, `io.Copy`'s
   `WriterTo`/`ReaderFrom`, `fs.FS`'s extension interfaces and
   `database/sql/driver`'s 28 interfaces all hide abilities behind
   assertions, and any middleware hides them again. Go had to add
   `ResponseController` and an `Unwrap()` convention (Go 1.20). Ren's
   "optional features are separate capabilities" (stdlib.md Part 4) is
   the right fix, but deps.md doesn't say what a handler written `over` a
   dependency does with the capabilities beside it. ([§1](#1-the-shared-interfaces), [§2](#2-driver-splits))
3. **Privilege leaks where std lacks a public answer, and the leak
   becomes a promise.** 38 public std packages use `go:linkname`; the tree
   carries 182 "hall of shame" notes for internals third parties pulled
   and that Go may now never change. The Go 1.23 lockdown didn't remove
   them; it froze them. Ren's closed list in decision 20 is the right
   shape. It needs a stated path for "a library needs a runtime hook" so
   the pressure goes into a primitive, not a back door. ([§3](#3-privilege))
4. **Compatibility needs machinery, not only a promise.** Go 1 kept its
   promise by adding GODEBUG (62 settings, keyed to the module's `go`
   line), v2 packages, deprecation comments that `go fix` can inline, and
   v1 rebuilt on v2. Ren's std.x plan (stdlib.md, "Open questions") has a
   promotion lean and no mechanism for changing a std behavior after
   1.0. ([§4](#4-evolution))
5. **Conformance suites in Go exist, ad hoc, and the one that's missing
   hurts most.** `fstest.TestFS`, `iotest.TestReader`, `slogtest`, and
   `nettest.TestConn` (in x/net) are conformance suites; there's none for
   `database/sql/driver`, `RoundTripper` or `Handler`. `testing/synctest`
   (Go 1.25) and `testing/cryptotest` (Go 1.26) are late retrofits of
   what Ren's `sim` and `Random` give by construction. This confirms
   stdlib.md rule 2 and argues for making the suite and the in-memory
   fake ship in the same module as the dependency type. ([§6](#6-shape-and-size-and-testing))
6. **Global registries and global defaults are Go's most repeated
   regret.** `sql.Register`, `image.RegisterFormat`, `crypto.RegisterHash`,
   `DefaultServeMux` (with `net/http/pprof` registering debug endpoints by
   a side-effect import), `DefaultClient` with no timeout, `rand.Seed`.
   Ren's "no global state" and `with` avoid the class. What's left is to
   decide the real implementations' defaults (timeouts, limits).
   ([§2](#2-driver-splits), [§5](#5-mistakes-go-admits))
7. **The good interfaces are one or two methods over a concrete shared
   type std owns.** `Handler` over `*Request`, `Reader` over `[]byte`,
   `slog.Handler` over `Record`. Ren's rule 1 has this. The log event,
   which stdlib.md names as a shared type, isn't specified anywhere yet;
   slog's split is good evidence for its shape. ([§1](#1-the-shared-interfaces))
8. **Most of Go's admitted mistakes are already avoided** by Ren's
   design: `context` (structured cancellation, values as dependencies),
   the monotonic clock (`Instant`), json's loose defaults (shapes.md
   "Strict decoding"), `log` vs `slog` (one trace stream). Two small
   gaps: what `Os.exit` does to a running `finally`, and how a caller adds
   context to an error it passes on. ([§5](#5-mistakes-go-admits))

---

## 1. The shared interfaces

### What each one is

| Interface | Where | Size | Defined over | Verdict |
|---|---|---|---|---|
| `io.Reader`, `io.Writer` | io/io.go:86, :99 | 1 method each | `[]byte` the caller owns | Good. The ecosystem's spine. The read contract is subtle: `n > 0` with an error, `0, nil` meaning nothing (io/io.go:64-83). |
| `io.WriterTo`, `ReaderFrom` | io/io.go:189, :200 | 1 method | another Reader/Writer | Hidden fast paths. `copyBuffer` probes for them (io/io.go:410, :414). Lost under any wrapper. |
| `error` | builtin/builtin.go:317 | 1 method | `string` | Good core; inspection retrofitted (below). |
| `context.Context` | context/context.go:72 | 4 methods | deadline, done channel, error, `any`-keyed values | Grew wrong. Two jobs in one type; viral first parameter; "do not store" is a comment, not a rule (context.go:38). |
| `http.Handler` | net/http/server.go:89 | 1 method | `ResponseWriter`, concrete `*Request` | Good. Every router and middleware library interoperates through it. |
| `http.ResponseWriter` | server.go:97 | 3 methods | headers, bytes, status | Grew wrong through optional interfaces: `Flusher` (:175), `Hijacker` (:187), `CloseNotifier` (:218, deprecated "predates Go's context package"). Fixed by `ResponseController` plus `Unwrap()` (responsecontroller.go:17, :43). |
| `http.RoundTripper` | net/http/client.go:113 | 1 method | `*Request` to `*Response` | Good. Client middleware, test fakes and HTTP/2 and HTTP/3 transports all plug in here (transport.go:377-388). |
| `fs.FS` | io/fs/fs.go:40 | 1 method (`Open`) | a path, a `File` | Good, but read-only. Writes were never added. Seven extension interfaces (`ReadDirFS`, `ReadFileFS`, `StatFS`, `SubFS`, `GlobFS`, `ReadLinkFS`; io/fs/*.go). |
| `slog.Handler` | log/slog/handler.go:33 | 4 methods | concrete `Record`, `Attr`, `Level`, a context | Good. `WithAttrs`/`WithGroup` exist so a handler can format shared attributes once. |
| `iter.Seq` | iter/iter.go:223 | a function type | `yield func(V) bool` | Good for collections; absent from I/O. No public `iter.Seq` in `io`, `bufio`, `os`, `net` or `database/sql` (grep; only `net/http/intrusive_list.go:65`, unexported). It has no error channel. Adoption is regexp, slices, maps, strings, bytes, go/types, reflect. |
| `database/sql/driver` | database/sql/driver/driver.go | 28 interfaces, 6 `Deprecated:` | connections, statements, rows | Grew wrong. Context was added by doubling each interface (`Execer` :186 / `ExecerContext` :200, `Queryer` :213 / `QueryerContext` :227). |
| `hash.Hash` | hash/hash.go:26 | embeds `io.Writer`, plus `Sum`, `Reset`, `Size`, `BlockSize` | bytes in, digest appended | Good because it *is* a Writer: `io.Copy(h, f)` hashes a file. `Cloner` and `XOF` added later (:69, :75). |
| `encoding.TextMarshaler` | encoding/encoding.go:54 | 1 method | `[]byte` | Good. A protocol by convention: json, xml, flag and slog all honor it, found by reflection. `Appender` forms added for allocation (:42, :72). |

### What made the good ones good

- **One method.** `Reader`, `Writer`, `Handler`, `RoundTripper`, `fs.FS`,
  `TextMarshaler`. A user type satisfies them by accident, and a wrapper
  is ten lines.
- **The data is concrete and std's.** `Handler` takes a concrete
  `*Request`; `slog.Handler` takes a concrete `Record`. The interface
  carries behavior; the shared struct carries data. Libraries agree on
  the struct without agreeing on anything else.
- **They live low.** `io`, `hash`, `encoding` and `io/fs` import almost
  nothing, so any package can name them without a dependency cost.
  `fs.FS` was put in `io/fs`, not `os`, so `embed`, `archive/zip` and
  `testing/fstest` could implement it without importing `os`.
- **They're defined over bytes the caller owns.** `Read(p []byte)` lets
  the caller pick the buffer. This is why `bufio`, `gzip` and `tls` stack
  without allocating.

### What made the bad ones bad

- **Optional abilities found at run time.** A type assertion is invisible
  in the signature and lost by any wrapper. Each of `ResponseWriter`,
  `io.Copy`, `fs.FS` and `driver` paid for it. The Go 1.20 fix,
  `Unwrap()` on wrappers, is a convention every middleware author must
  remember.
- **Retrofitting a cross-cutting concern.** `context` was added in Go 1.7
  (from `golang.org/x/net/context`). Every interface that existed before
  needed a second, `...Context` version.
- **One type with two jobs.** `Context` carries cancellation and a bag of
  `any` values. The bag is untyped and invisible in signatures.

### Mapping to Ren

| Go | Ren's nearest | Gap |
|---|---|---|
| `io.Reader` | a cursor, `next(inout self) -> Option<T>` (stdlib.md "Streams: cursors first"), with leased chunks | None for reading. The cursor's contract is simpler than `Read`'s: no `n > 0` with an error. |
| `io.Writer` | **nothing named.** streams.md:698 takes `w: Writer` and calls `w.write_line`; stdlib.md calls `out.write(chunk)` | **The biggest gap.** Ren needs a sink shape so `gzip`, `hash`, `base64`, `tls` and a response body can wrap any sink. Without traits, it's either a reserved method name (as `next` is, decision 20 rule 3) or a `dep`. Decide it. |
| `WriterTo`/`ReaderFrom` | runtime-io.md's leased buffers, kTLS (runtime-io.md:171) | Say how a zero-copy path (`sendfile`, `splice`) is chosen. It should be visible at the call (`Net.send_file(conn, f)`), not probed. |
| `error` | structural tags (errors.md) | Avoided: no sentinel identity, no wrapping needed to match. |
| `context.Context` | the task tree's cancellation (foundations.md decision 7, "Structured tasks"), `Async.timeout`, dependencies for values | Avoided. |
| `http.Handler` | `serve(port, handle: fn(req: Request) -> Response)` (stdlib.md "HTTP"); routes as an ADT and `match` (language.md:864) | Third-party routers interoperate in Go because a handler is a value. In Ren a handler is a block and a route set is an ADT; check that two routing libraries can mount each other's routes. |
| `RoundTripper` | the `Http` client dependency, `mem_http`, `sim.http` (stdlib.md Part 3) | Good. |
| `fs.FS` | `Fs` dependency, `mem_fs` | Go's read-only `fs.FS` is the most-implemented FS type because it's small. runtime-io.md:124 already allows "finer capabilities (`Fs.read` without `Fs.write`)"; make a read-only `FsRead` a 1.0 type so `embed`-like and archive readers can implement it. |
| `slog.Handler` + `Record` | "the log event" (stdlib.md rule 1); log is the trace stream (stdlib.md "Observability") | Specify the event type. slog's evidence: a concrete record, a level check before building it (`Enabled`, handler.go:11), and attributes pre-bound once. |
| `iter.Seq` | cursors and `gen fn` (streams.md) | Ren's cursors can fail (`for x in try c`), so they reach I/O where `iter.Seq` didn't. `iter.Pull` needs runtime coroutines (iter.go:233-237, `linknamestd`); Ren's `gen fn` is the language's, as it should be. |
| `database/sql/driver` | `Sql` dependency (stdlib.md "Data") | See §2. |
| `hash.Hash` | `x.hash()` (stdlib.md) for values; crypto hashes unspecified | A streaming hasher is a sink. Falls out of lesson 1. |
| `TextMarshaler` | the derived walk's reserved `show`/`parse` (decision 20 rule 3), shapes.md | Avoided, and better: the language guarantees every library sees the same names, where Go needs each library to remember to check. |

---

## 2. Driver splits

Go's pattern: std defines the interface and owns the hard shared parts;
others implement the rest.

| Split | What std owns | What the driver owns | How they meet |
|---|---|---|---|
| `database/sql` | the pool, transactions, retries on bad conns, `Scan` conversion | the wire protocol | `sql.Register(name, driver)` in `init` (database/sql/sql.go:54); a global map (:49) |
| `image` | `Decode` by sniffing magic bytes | each format | `image.RegisterFormat` in each format's `init` (image/format.go:37; image/png/reader.go:1053) |
| `crypto` | the `crypto.Hash` enum | each hash | `crypto.RegisterHash` in `init` (crypto/crypto.go:156; crypto/sha512/sha512.go:21); `Hash.New` panics if the package wasn't imported (crypto.go:145) |
| `net/http` client | `Client`: redirects, cookies, timeouts | the transport | a `RoundTripper` value in a struct field. No registry. |

**What worked.**
- `database/sql`'s division of labor. Std owning the pool means every
  driver gets a correct one. This is the part stdlib.md Part 4 copies.
- `RoundTripper`: a value passed in a field, no global. It's how test
  fakes, retry and tracing wrappers, and HTTP/2 and HTTP/3 plug in.

**What didn't.**
- **Registration by side-effect import.** `import _ "image/png"` changes
  what `image.Decode` accepts. Forget it and `crypto.SHA512.New()` panics
  at run time. The same mechanism lets `import _ "net/http/pprof"`
  register debug endpoints on the global mux (net/http/pprof/pprof.go:95-103),
  and `expvar` do the same (expvar/expvar.go:380-384). A program's
  exposed surface depends on its import list.
- **Global registries can't be wrapped.** A tracing vendor wanted to wrap
  every registered SQL driver and had no API, so it linknamed the private
  map. Go now has to keep it: "It is extra wrong that they linkname
  drivers but not driversMu" (database/sql/sql.go:41-49).
- **The interface grew by optional interfaces.** 28 interfaces, 6
  deprecated, because each new feature (context, named parameters,
  session reset, validation) came as a new interface the driver may or
  may not implement, probed at run time (database/sql/ctxutil.go:13, :46).
- **No conformance suite.** Driver quality varies; stdlib.md already
  names this.

**For Ren.** `with` replaces registration: an implementation is a value
installed by the caller, so the import list never changes behavior, and
a tracer is a handler `over Sql`. Two rules to write down:
- A driver interface states its full set of operations at 1.0. Ren's
  cancellation is structural, so the "add `Context` to everything"
  retrofit can't happen; other cross-cutting additions (tracing,
  deadlines) should go through `over` handlers, not new operations.
- When a handler is written `over` one capability (`Blob`), what happens
  to a sibling capability (`BlobCas`) installed with it? The Go evidence
  says a wrapper that silently drops abilities is the common bug. deps.md
  should say whether `over` forwards the siblings, refuses, or requires
  them to be named.

---

## 3. Privilege

### What Go's std can do that users can't

| Power | Scale | Who uses it |
|---|---|---|
| `//go:linkname` into the runtime | 1,395 directives outside `cmd` and `vendor`, 791 of them in `runtime`; 38 public packages use one | `sync`, `sync/atomic`, `time`, `os`, `net`, `reflect`, `iter`, `maps`, `unique`, `weak`, `math/rand`, `crypto/rand`, `testing`, `testing/synctest`, `testing/cryptotest`, `database/sql`, `net/http` and others |
| `//go:linknamestd` | 56 directives | a push that only std may pull; used for coroutines (iter/iter.go:233-237) and synctest bubbles (internal/synctest/synctest.go:25, :35) |
| `internal/` packages | 117 under `src/internal`, 22 more `internal` dirs elsewhere | code sharing that isn't API. Any module can use `internal/` for itself, so this is not a privilege in kind. |
| compiler intrinsics | 180 `add` entries and 87 `alias` entries in cmd/compile/internal/ssagen/intrinsics.go: 47 + 10 for `math/bits`, 41 for `sync/atomic`, 24 for `math` | these are optimizations of std functions that users get by calling them. Invisible, as Ren's rule 4 wants. |
| hooks for the test runner | `os.Exit` panics on exit 0 in tests (os/proc.go:62-77); `internal/testlog` records every `Getenv`, `Stat`, `Open` and `Chdir` so `go test` can cache (internal/testlog/log.go:16-20) | `os`, `testing`, `cmd/go` |
| GODEBUG | 62 settings (internal/godebugs/table.go) | std only |

The privileged code clusters in a few places: the scheduler and its
parking (`sync`, `time`, `net`'s poller), memory (`unique`, `weak`,
`maps`, `arena`), reflection (`reflect`), coroutines (`iter`), and test
control (`synctest`, `cryptotest`, `testlog`). Encoding, HTTP, templates,
crypto algorithms and compression are plain Go. That's close to Ren's
closed list: the world, the scheduler, the instance family, memory, the
journal. Go's extra items (coroutines, reflection, weak and unique) Ren
puts in the language (`gen fn`, shapes) or doesn't have.

### What Go paid where it didn't hold

- **Third parties reached in.** Before Go 1.23, any package could pull a
  private std symbol by name. Widely used packages did: gVisor uses
  `runtime.gopark`/`goready` (runtime/proc.go:446-455); loggers and rate
  limiters pull `time.now` for speed (time/time.go:1309-1318); one logger
  hard-coded an internal epoch offset (time/time.go:1903-1912).
- **The lockdown froze the leaks.** Issue 67401 made the linker check
  linknames by default in Go 1.23 (`-checklinkname`,
  cmd/link/internal/ld/main.go:104; the check at
  cmd/link/internal/loader/loader.go:2530-2615). Every symbol already
  pulled was kept, annotated "Do not remove or change the type
  signature": 182 such notes, in `runtime`, `net/http`, `net`,
  `crypto/tls`, `time`, `reflect`, `database/sql`, `sync` and others. New
  internals "cannot be linknamed, now or ever" (the issue's plan). The
  team's answer to users was to file proposals for the public API they
  were missing.
- **Std needed new private doors for itself.** `testing/cryptotest`
  (Go 1.26) makes crypto randomness deterministic in a test. It has to
  linkname into `crypto/internal/rand` and `testing`
  (testing/cryptotest/rand.go:22-26), is process-global, and refuses
  parallel tests (:35-36). Ren gets the same by `Random` being a
  dependency (runtime-io.md:119).

### Is "no powers a user library lacks" achievable?

Yes, with the exception decision 20 already makes, and Go is evidence
for both halves. The parts of Go's std that people value most (http,
json, crypto algorithms, templates, slog) needed no privilege. Each
privilege that leaked was a missing public primitive: a fast monotonic
clock read, a way to park a goroutine, a hook to wrap registered
drivers. Go learned that a private door that's useful will be used, and
then it's API. Ren's design avoids most of these by construction
(`Clock.instant`, `with`, `over`). The remaining risk is the runtime
list: a library will want something next to `Instances` or the journal.
Decision 20 should say what happens then: it becomes a general primitive
or it isn't done, and there is no unsafe pull.

---

## 4. Evolution

### The machinery

- **The Go 1 promise** (2012): source that compiles keeps compiling. The
  2023 post "Backward Compatibility, Go 1.21, and Go 2" says "There will
  not be a Go 2 that breaks Go 1 programs."
- **GODEBUG** for behavior changes the promise can't absorb. A setting's
  default follows the `go` line in the main module's `go.mod`, so a new
  toolchain keeps old behavior until the module opts in; `//go:debug`
  overrides it. Settings are kept at least two years (four releases).
  The table has 62 entries, 14 of them removed (internal/godebugs/table.go),
  for example `panicnil` (:60), `httpmuxgo121` (:48), `randseednop`
  (:62), `x509sha1` removed in 1.24 (:104). Non-default use is counted in
  `runtime/metrics`, so operators can find what still depends on old
  behavior.
- **v2 packages.** `math/rand/v2` (Go 1.22). The post "Evolving the Go
  Standard Library with math/rand/v2" gives three rules: a separate
  import path so both coexist; a change must be worth the churn; v1
  should become a thin wrapper over v2 where it can. `encoding/json/v2`
  is still behind `GOEXPERIMENT=jsonv2` in this tree
  (encoding/json/v2_decode.go:1); v1 is reimplemented over v2 under the
  experiment (encoding/json/v2_*.go). Go 1.26 shipped without it.
- **Deprecation.** `io/ioutil` was deprecated in 1.16 with each function
  pointing to its replacement; the functions now carry `//go:fix inline`
  (io/ioutil/ioutil.go:7-28) so `go fix` rewrites callers. Nothing is
  removed.
- **`golang.org/x`.** Two roles: a staging area (x/exp) and std's own
  dependencies. Std vendors x/crypto, x/net, x/sys, x/text and x/tools
  (vendor/modules.txt). HTTP/2 came from x/net as a bundled file, and in
  this tree has moved into `net/http/internal/http2` (39 files); HTTP/3
  is being built in `net/http/internal/http3`, unexported.

### Promotions

| Package | From | To std | Notes |
|---|---|---|---|
| `context` | x/net/context | Go 1.7 (2016) | then `http.Request.Context` (1.7) and `sql` `...Context` (1.8) |
| `errors.Is/As/Unwrap` | x/xerrors | Go 1.13 | smaller than xerrors: the frame/stack part was dropped |
| `slices`, `maps` | x/exp | Go 1.21 | after generics; some functions left behind |
| `log/slog` | x/exp/slog | Go 1.21 | experimental code public Aug 2022; discussion (~300 comments) then proposal (800+); context-carrying logger removed as too controversial; accepted Mar 2023 |
| `iter` | none | Go 1.23 | a language change (range over func) with it |
| `uuid` | github.com/google/uuid, de facto | accepted Apr 2026, in this tree (uuid/uuid.go) | proposal 62026, filed 2023; the accepted API is much smaller than google/uuid's |

**The rule that decides promotion** isn't written as a rule. In practice:
the package has been used widely outside std (x/exp or third party); a
proposal passes review; the promoted API is smaller than the staged
one; and the domain has stopped moving. The uuid case shows the bar:
three years for a small, stable, universally used type.

### Compared with Ren's plan

stdlib.md rule 4 and "Open questions" lean: std moves with the
toolchain, std.x packages version on their own, promotion after a
release cycle with no breaking change plus a conformance suite. Go adds:
- **Promote less than was staged.** Every Go promotion cut API. Ren's
  promotion step should list what is dropped.
- **A way to change std behavior after 1.0.** Ren has none yet. Go's
  answer (defaults keyed to the version a package declares, one
  documented table, a counter for non-default use) fits Ren well: the
  version is in `ren.toml`, and a setting is a value the toolchain
  reads, not a library flag.
- **v1 over v2.** When a std module needs a v2, the v1 should be a
  wrapper, so fixes reach both.
- **A fixer.** `//go:fix inline` makes deprecation cheap for users. Ren's
  toolchain reads declarations (decision 20); a deprecation that names
  its replacement can be applied mechanically.

---

## 5. Mistakes Go admits

| Mistake | Evidence | Ren already avoids it? | What's left |
|---|---|---|---|
| `log` vs `slog` | slog added in 1.21 because programs pulled in several logging packages, each needing setup (go.dev/blog/slog). `slog.SetDefault` has to rewire `log`'s output and avoid a deadlock between the two (log/slog/logger.go:62-72). | Yes. Logging is the trace stream; one module (stdlib.md "Observability"). | Specify the event type. |
| `context` retrofitted | `Request.Cancel` (net/http/request.go:323) then `ctx` (:338) and `WithContext` (:373); `DB.Query` beside `QueryContext` (database/sql/sql.go:1742, :1759); `DialContext` deprecating `Dial` (transport.go:141) | Yes. Cancellation is the task tree's; there's no value to thread. | Nothing. |
| Global state | `DefaultClient = &Client{}` with zero `Timeout`, meaning none (client.go:102-106); `DefaultServeMux` (server.go:2795) plus side-effect registration (pprof.go:95); `rand.Seed` now a no-op behind `randseednop` (math/rand/rand.go:393-404); global rand `Read` deprecated (:487) | Yes. deps.md rule 2: "no global state and no ambient I/O". | The real implementations' defaults. `http.client()` should have a finite timeout and `serve` finite header and body limits by default, stated in stdlib.md "HTTP". |
| `os.Exit` and `log.Fatal` | `log.Fatal` calls `os.Exit(1)` (log/log.go:280-285); defers don't run. `os.Exit` needs a test hook (os/proc.go:62-68). | Partly. `Os` covers exit (runtime-io.md:120). | I didn't find what `exit` does to running tasks and `finally` blocks. Say so in deps.md's `Os` row. A safe rule: exit cancels the root scope and unwinds; an immediate exit is a separate, named call. |
| Errors' evolution | `Unwrap`/`Is`/`As` in 1.13 (errors/wrap.go:17, :45, :102), `Join` in 1.20 (errors/join.go:20), `AsType` in 1.26 (wrap.go:167) | Mostly. Tags are structural, so matching needs no wrapping and no identity. | Go's heavy use of `fmt.Errorf("...: %w")` shows people want to add context when passing an error on. errors.md rule 4 says "no wrapping"; it should say where that context goes (the trace, a payload). |
| Monotonic clock | Go 1.9 hid a monotonic reading inside `time.Time` (time/time.go:17-43, the struct at :140-153); it's lost on serialization and stripped by `Round` | Yes. `Time` and `Instant` are two types (stdlib.md "`Time` and `Instant`"). | Nothing. |
| `encoding/json` defaults | v1 replaces invalid UTF-8, allows duplicate names, matches names case-insensitively; v2 rejects all three (encoding/json/v2/doc.go:175-215) | Yes. shapes.md "Strict decoding" (shapes.md:639-642) takes v2's defaults. | Nothing. |
| Optional interfaces | `CloseNotifier` deprecated (server.go:216); `ResponseController` (Go 1.20) | Mostly. Separate capabilities (stdlib.md Part 4). | The `over` rule from §2. |

---

## 6. Shape and size, and testing

### Size

About 200 importable packages; about 957,000 non-test lines of Go
outside `cmd` and `vendor`, runtime included. Some areas, in non-test
lines: `crypto` 98,600; `net` 71,100 (of which `net/http` 43,200,
including internal HTTP/2 and HTTP/3); `go` (the toolchain's parser and
type checker as libraries) 52,500; `encoding` 36,600; `image` 10,800;
`testing` 8,300; `database/sql` 5,600; `text/template` 5,600;
`html/template` 4,900; `log/slog` 3,300; `runtime/pprof` 2,800.

### What's in it that most languages leave out

A production HTTP/1.1 and HTTP/2 server and client, TLS 1.3 with
post-quantum key exchange (`tlsmlkem`, godebugs/table.go:66), X.509, a
FIPS 140-3 crypto module inside std (crypto/internal/fips140), text and
HTML templates with contextual escaping, profiling served over HTTP,
`go/ast`, `go/types`, image codecs, and now `uuid`.

**Why Go thinks it pays.** Go was built for networked servers at Google,
and the std is shaped for them: one HTTP stack and one TLS stack that
every program shares and the Go security team patches. Shared types
come for free when the implementation is shared. The cost shows too:
`net/smtp` frozen, `image` and `text/template` rarely touched, `expvar`
and `net/rpc` left behind. Ren's inventory (stdlib.md Part 5) takes the
server half and leaves the rest, which matches where Go's std has aged
well.

### Testing in std

| Package | What it is | Ren's counterpart |
|---|---|---|
| `testing` | runner, subtests, benchmarks, fuzzing (since 1.18) | `test`, property tests, fuzzing (stdlib.md "Testing and tooling") |
| `testing/fstest` | `MapFS`, an in-memory FS (mapfs.go:33), and `TestFS`, a conformance suite for any `fs.FS` (testfs.go:39) | `mem_fs` and the `Fs` conformance group |
| `testing/iotest` | readers that misbehave on purpose (`OneByteReader`, `HalfReader`, `DataErrReader`, `TimeoutReader`, `ErrReader`; reader.go:17-94) and `TestReader`, a conformance check (:136) | `sim.fs`, `sim.net`: the "fails in every way its contract allows" implementation |
| `testing/slogtest` | conformance suite for any `slog.Handler` (slogtest.go:267, :299) | a conformance group for the log sink |
| `net/http/httptest` | a recorder and a real loopback server | `mem_http`, `sim.http` |
| `x/net/nettest` | `TestConn`, a conformance suite for any `net.Conn` (vendor/golang.org/x/net/nettest/conntest.go:30) | the `Net` conformance group |
| `testing/synctest` | experiment in 1.24, stable in 1.25: goroutines in a bubble get a fake clock that jumps when all are blocked (synctest.go:287, :308) | `sim` and `sim.clock` |
| `testing/cryptotest` | 1.26: deterministic crypto randomness for one non-parallel test (rand.go:45) | `Random` as a dependency |

**How it relates to Ren's rule.** Go arrived at Ren's pattern piece by
piece: an in-memory fake, a misbehaving wrapper, and a conformance suite
for a few interfaces, written years apart and in different places. The
interfaces with suites (`fs.FS`, `slog.Handler`, `net.Conn`) have the most
interchangeable implementations. The one without (`database/sql/driver`)
has the most variance. `synctest` covers only time and goroutine
blocking; disk and network faults are still each library's problem. The
late `cryptotest` shows the cost of randomness not being a dependency
from the start. Ren's rule 2 makes all of this one convention. Go's
lesson is that the convention only holds if the suite and the fake ship
beside the type, in the same module, from the first release.

---

## What Ren should take

- **Define the sink protocol.** One shape for "takes bytes, may fail,
  can be flushed and closed", so `gzip`, hashing, `base64`, `tls`,
  `csv` writing and an HTTP response body wrap any sink. Decide whether
  it's a reserved name beside `next` (foundations.md decision 20 rule 3's
  closed list) or a `dep`. Changes: stdlib.md "Streams: cursors first";
  streams.md "The standard library".
- **Write the `over` rule for sibling capabilities.** A handler `over Blob`
  either forwards `BlobCas` or the `with` is refused; never a silent
  drop. Changes: deps.md (handlers over a dependency); stdlib.md Part 4.
- **Make every fast path visible.** No probing for `WriterTo`-style
  upgrades; a zero-copy send is its own call. Changes: runtime-io.md
  "Buffers lent or leased".
- **Ship the fake and the conformance group in the dependency's own
  module,** from its first release, as `fstest` pairs `MapFS` with
  `TestFS`. Changes: stdlib.md "Three implementations, one conformance
  suite".
- **Add a read-only `FsRead` to 1.0.** Go's most-implemented FS type is the
  small read-only one. Changes: runtime-io.md Part 2; stdlib.md Part 3
  table.
- **Specify the log event as a concrete type,** with a level check
  before it's built and pre-bound attributes. Changes: stdlib.md
  "Observability" and rule 1's list.
- **Give std a behavior-change mechanism before the promise starts:**
  defaults keyed to the version in `ren.toml`, one documented table,
  each setting kept at least two years, use of old behavior counted.
  Changes: stdlib.md rule 4 and "Open questions"; module-build.md.
- **Write the promotion rule with Go's habits:** used outside std first,
  the promoted API smaller than the staged one, a v1 that wraps any v2,
  deprecations that name a mechanical replacement the toolchain can
  apply. Changes: stdlib.md "Open questions".
- **Say what a library does when it needs the runtime.** It becomes a
  general primitive or isn't done; no private pull. Changes:
  foundations.md decision 20 rule 2.
- **State the real implementations' safe defaults:** a finite client
  timeout, finite server header and body limits. Changes: stdlib.md
  "HTTP".
- **Specify `Os.exit`** as cancelling the root scope and unwinding, with
  any immediate exit a separate named call. Changes: deps.md's world
  table; runtime-io.md Part 2.

## What Ren should not take

- **Registration by import.** No `init`, no registry; an implementation
  is installed with `with`. Ren already has this; keep it when `std.x`
  formats and drivers arrive. Changes: none; note it in stdlib.md Part 4.
- **Optional interfaces discovered at run time.** Abilities are
  separate capabilities in the signature. stdlib.md Part 4 has it.
- **A context-like value bag.** Values are dependencies; cancellation is
  the tree's. Keep foundations.md decision 7 and deps.md rule 2 as they
  are.
- **`internal/`-style std-only linkage or a `linknamestd`.** Std uses the
  same module privacy every package has. Changes: none; it follows from
  decision 20 rule 2.
- **Go's breadth in the cold areas.** `image`, `net/smtp`, `net/rpc`,
  `expvar` and text templating aged worst. stdlib.md Part 5 already
  leaves them out.
- **Push iterators as the I/O protocol.** `iter.Seq` never reached I/O
  because it can't fail. Keep cursors that can (streams.md).

## Sources

- Go source at `/tmp/ren-refs/go`, commit `6c49ac3` (2026-10-26).
- [Backward Compatibility, Go 1.21, and Go 2](https://go.dev/blog/compat)
- [Evolving the Go Standard Library with math/rand/v2](https://go.dev/blog/randv2)
- [Structured Logging with slog](https://go.dev/blog/slog)
- [golang/go#67401, restricting linkname](https://github.com/golang/go/issues/67401)
- [golang/go#62026, uuid](https://github.com/golang/go/issues/62026);
  [Accepted proposal: UUID in the Go standard library](https://longform.social/post/did:plc:fgtm2c26vfcj74rfmeggbyqj/3mnl6iasgzl26)
- [Go 1.26 shipped without JSON v2](https://huizhou92.com/go-1-26-shipped-without-json-v2-heres-the-real-reason-why/)
  (third-party; the tree's `goexperiment.jsonv2` build tags confirm it).

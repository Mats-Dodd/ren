# E1: the stress programs on paper, under the amended design

All ten stress programs, rewritten under amendments.md §2 with group A
decided, plus three new ones (11 a lexer, 12 framed binary messages, 13 a
paginated API). Each has the Ren version, the best twin among Kotlin, C#,
Go, Rust and Elixir, an honest comparison, and the rules it leans on. Where
a program names an effectful generator or resumes after a `break`, both
spellings of decision 3 are written side by side.

Anything the docs don't already give is marked `PROPOSAL:`. Open owner
decisions are marked `(open #N)` with the recommendation I assumed.

## The rules, by short name

These are the names the "Leans on" lists use.

| Name | Rule | Where |
|---|---|---|
| **BLK** | A block is passed, `let`-bound or called, never stored or returned. A `let` binds one literal block *or one chain* | foundations 1, decided A1 |
| **PIPE** | A chain over a cursor is a block `fn() -> Option<T>` written where the chain is. Stage state is a hidden local. It can be looped over (no `&`), stepped by hand, passed to a block parameter. It can't be stored, returned or chosen with `if` | decided A1 |
| **HEAD** | `&r.stage(..)` steps the named cursor `r`. `r.stage(..)` on a named cursor is an error. A temporary head needs no `&`. The missing-`&` error is for named places only | amendments §2 |
| **GEN** | Calling a `gen fn` follows its signature. If it's pure and takes only values, the call gives a value cursor (data, storable, `walk.Cursor`). If it uses a dependency or takes a block, the call gives a pipeline whose frame is a hidden local of the caller | decided A2 |
| **DATA** | A position kept past a function is data: a record with `next(inout self)`, holding an id and an offset. The library's readers (`Fs.line_reader`, `Net.chunks`, `Db.rows`, `Net.frames`) are this | amendments §2, "Cursors over resources" |
| **TRY** | `for x in try src` marks that `next` can fail. A failure ends the stream after cleanup. A per-item outcome you recover from is a value: a sum type or an `attempt` `Result` | streams draft, errors.md |
| **FIN** | `finally` runs only at points the syntax fixes: the end of a `for` over a temporary, the end of the statement holding a sink, the end of the scope of the `let` that names the stream, or a cancel. Never at a drop | amendments §2, decision 11 |
| **WHY** | `finally(r)` sees `Err(Cancelled)` when the generator was abandoned (`break`, `take`) | (open #4) |
| **YLD** | `yield` appears only in the generator's own body, never in a `fn` literal or a `finally`. It may sit inside a `with` | amendments §2 |
| **DEP** | Dependencies are found where a block is written, or where a generator's frame is made | foundations 5 |
| **EXCL** | One exclusivity rule; a pipeline's captures are accessed at each step, or for the whole call it's passed to | foundations 2 |
| **PUSH** | A chain whose head is a `gen fn` call and whose consumer is a `for` or a sink is pushed through its one-input stages | (open #8) |
| **ASYNC** | `Async.map` and `Async.each` take any source, bounded by `max:`. Task-backed streams take the consumer-block shape, `Async.produce(..) fn(results) => ..` | async.md, (open #6, #9) |
| **CHAN** | A channel is a `dep`. `Events.items()` is a derived cursor whose `next` is `Events.recv()`. Time operators take that receiver | amendments §2, (open #7) |
| **DOT** | A line that begins with `.`, indented further, continues the line above | amendments §2 |
| **POS** | A position is a byte offset into the value you hold. A base is given once, where the thing that reports positions is made (`cursor(from:)`, `view(from:)`) | strings.md |
| **CHR** | `s.chars()` yields one-code-point `Str` slices. `'a'` is an `Int`. `Str` has no `len` | strings.md |
| **FMT** | A format is checked once by `view`. `Short(at, need)` drives framing. Errors carry `at` | formats.md |
| **KEEP** | A slice of a leased chunk kept past the body's turn needs `.copy()` | strings.md Retention, (open #12) |

## Decision 3, stated once

The question: how is a named effectful generator (a pipeline) spelled
when you step it more than once?

```ren
// (a) let, no &                         // (b) var, with &
let lines = follow(path)                  var lines = follow(path)
for l in try lines                        for l in try &lines
  if l == "---" then break                  if l == "---" then break
for l in try lines                        for l in try &lines
  ...                                       ...
let Some(h) = try lines() else ..         let Some(h) = try &lines.next() else ..
```

Under (a), `lines` is a block, as `let f = fn() => n += 1` is. Its hidden
frame changes and the name never does. Under (b), `lines` reads like the
data reader `var r = Fs.line_reader(p)`, and the price is the first
`var`-bound block.

---

## 01. Tail a log: `select`, `take(100)`, and resuming after `break`

Follow a growing log file, parse each line, keep only errors, stop after
100, and close the file the moment we stop. A variant stops at a marker
and then resumes from the same place.

### Ren

```ren
type Level = | Debug | Info | Warn | Error
type Entry = { at: Time, level: Level, msg: Str }

fn parse(line: Str) -> Entry ! BadLine(text: Str) = ...

// The producer has real control flow: it waits at EOF and carries a partial line.
// It uses Fs and Clock, so a call to it is a pipeline (GEN).
pub gen fn follow(path: Path) -> Str
    uses Fs, Clock ! FsError | InvalidUtf8(at: Int, incomplete: Bool) =
  let f = try Fs.open(path)
  finally f.close()                       // at a point the syntax fixes (FIN)
  var at = try f.size()                   // start at the end, like tail -f
  var carry = Bytes.empty()               // a partial line from the last chunk
  while true
    let chunk = try f.read_at(at, 64 * 1024)
    if chunk.len() == 0 then
      Clock.sleep(Duration.ms(200))
    else
      at += chunk.len()
      var rest = chunk
      while true
        let Some((line, after)) = rest.split_once(b"\n") else break   // b"..": strings.md, Later
        let whole = if carry.is_empty() then line else carry + line
        yield try Str.from_utf8(whole)    // a whole line: no chunk boundary inside it
        carry = Bytes.empty()
        rest = after
      carry += rest                       // PROPOSAL: `+=` on Bytes appends in place, as on Str

// The consumer you'd write first. One statement, so the file closes when it ends.
fn first_errors(path: Path) -> Array<Entry> =
  try follow(path)
    .map(parse)
    .select(fn(e) => e.level == Error)
    .take(100)
    .to_array()
  // Pushed (PUSH): the 100th error leaves `follow`'s loop, its `finally`
  // closes the file, and nothing is allocated except the array.
```

**The variant that resumes, both spellings of decision 3:**

```ren
// (a) let, no &                                  // (b) var, with &
fn sections(path: Path) uses Fs, Clock, Console = fn sections(path: Path) uses Fs, Clock, Console =
  let lines = follow(path)                          var lines = follow(path)
  for line in try lines                             for line in try &lines
    if line == "--- boot ---" then break              if line == "--- boot ---" then break
  for e in try lines                                for e in try &lines
      .map(parse)                                       .map(parse)
      .select(fn(e) => e.level == Error)                .select(fn(e) => e.level == Error)
    Console.print(e.msg)                              Console.print(e.msg)
  // `follow`'s finally runs here, at the end       // the same
  // of `lines`' scope
```

The same program over a data reader (no tailing), for contrast:

```ren
  var r = Fs.line_reader(path)
  for line in try &r
    if line == "--- boot ---" then break
  for e in try &r.map(parse).select(fn(e) => e.level == Error)
    Console.print(e.msg)
```

**Decision 3, which reads clearer:** (b) looks exactly like the data-reader
version, which a reader will like at first glance. (a) is clearer about
what's going on, and that matters in this program because of the
`finally`:

- Under (b), `lines = follow(other)` looks legal. It must either be an
  error (a `var` you can't assign) or close the first file at the
  assignment, which is cleanup at a drop, the thing just removed.
- Under (b), `let copy = lines` looks like the data-reader fix-it "step a
  copy", but a pipeline can't be copied.
- Under (a), the rule a reader needs is one they already have: calling a
  block changes what it captured. `lines.map(parse)` without `&` steps
  `lines` because `lines` *is* the stream, not a place holding it.

**Verdict: (a).** The cost is that the data-reader and generator versions
of `sections` differ by `var`/`&`. That difference is real (one can be
copied and stored, the other can't), so showing it is honest.

### Best twin: Kotlin Flow (Rust `by_ref` for the resume)

```kotlin
fun follow(path: Path): Flow<String> = flow {
    RandomAccessFile(path.toFile(), "r").use { f ->        // closed when the flow is aborted
        var at = f.length()
        val carry = ByteArrayOutputStream()
        val buf = ByteArray(64 * 1024)
        while (true) {
            f.seek(at)
            val n = f.read(buf)
            if (n <= 0) { delay(200); continue }
            at += n
            var start = 0
            for (i in 0 until n) if (buf[i] == '\n'.code.toByte()) {
                carry.write(buf, start, i - start)
                emit(carry.toByteArray().decodeToString(throwOnInvalidSequence = true))
                carry.reset(); start = i + 1
            }
            carry.write(buf, start, n - start)
        }
    }
}.flowOn(Dispatchers.IO)

suspend fun firstErrors(path: Path): List<Entry> =
    follow(path).map(::parse).filter { it.level == Level.Error }.take(100).toList()
```

```rust
// Resuming after a stop: Rust's by_ref.
let mut lines = follow(path)?;
for l in lines.by_ref() { if l? == "--- boot ---" { break } }
for e in lines.map(|l| parse(&l?)).filter(|e| matches!(e, Ok(e) if e.level == Level::Error)) { ... }
```

### Comparison

- **Ren reads better:** the consumer is one statement, and the file
  closes at its end. Kotlin needs `flowOn(Dispatchers.IO)`. Resuming after
  `break` is real in Ren. A cold Kotlin Flow can't do it without
  `produceIn`, a task and a channel. The stop points are the `try`s.
- **Ren reads worse:** `follow` itself is a little longer because a
  `Str` is checked UTF-8, so the line split happens on `Bytes`. That's
  correct, and Kotlin's naive `String(buf, 0, n)` gets it wrong at a chunk
  boundary.
- **What Ren can't do:** keep a *tailing* stream in a record. That's
  program 09's job, as a data position.

**Leans on:** GEN, PIPE, HEAD (a temporary head with no `&`), FIN, PUSH,
TRY, DOT. **Exceptions needed:** none. **PROPOSAL:** `+=` on `Bytes`
(strings.md gives it to `Str`; `Bytes` should match), and `b"\n"` (strings.md
Later).

**Bugs fixed from the original:** `chunk.str()` doesn't exist and would
cut a UTF-8 character at a chunk boundary, so lines are split as bytes
and checked whole. `for line in lines[0 .. n-1]` sliced an array by a
range that dropped nothing. The `&` on `&follow(path)...` (a temporary)
is gone.

---

## 02. A Postgres-style framed protocol

### Ren

```ren
type PgMessage =
  | Query(sql: Str)
  | Parse { name: Str, sql: Str, oids: Array<Oid> }
  | Terminate
  | Other { kind: UInt8, body: Bytes }

format wire for PgMessage, be =
  kind: UInt8
  len: UInt32 = rest + 4          // PROPOSAL: `rest` is the bytes after this field, to the format's end.
  case kind                       //   `view` checks it, `write` fills it, and `Short.need` is the
    'Q' => Query(sql: CStr)       //   whole frame once the 5-byte header is in
    'P' => Parse { name: CStr, sql: CStr, n: UInt16, oids: Array<UInt32 as Oid>[n] }
    'X' => Terminate
    _   => Other { kind, body: Bytes[len - 4] }

fn session(conn: Conn) ! NetError | FormatError | DbDown | StoreDown uses Net, Db, Prepared =
  for msg in try Net.frames(conn, PgMessage.wire)     // a data reader: conn id, one buffer, a base
    match msg
      Query(sql) => try reply(conn, try Db.query(sql))
      Parse { name, sql, oids } =>
        try Prepared.add(name.copy(), sql.copy(), oids)   // kept past the turn: copy (KEEP)
      Terminate => break
      Other { kind, .. } => try reply_error(conn, Unsupported(kind))
```

When the peer closes mid-frame, `Net.frames` fails with `Short(at, need)`,
where `at` is a stream offset (POS). Between frames, it ends with `None`.

**How `Net.frames` is written.** It's ordinary Ren, a data reader, so it's
storable:

```ren
pub type Frames<T> = { conn: Conn, fmt: Format<T>, buf: Bytes, base: Int }
                                          // PROPOSAL: a format is a value, `Format<T>`
pub fn frames<T>(conn: Conn, fmt: Format<T>) -> Frames<T> =
  Frames { conn, fmt, buf: Bytes.empty(), base: 0 }

  pub fn next(inout self) -> Option<T> uses Net ! NetError | FormatError =
    while true
      match self.fmt.view(self.buf, from: self.base)
        m =>
          self.base += self.buf.len() - m.rest.len()
          self.buf = m.rest
          return Some(m.value)
        fail Short(at, need) =>
          let more = try Net.read(self.conn, max: need)   // PROPOSAL: one read of at most `need`
          if more.is_empty() then
            if self.buf.is_empty() then return None       // a clean end, between frames
            fail Short(at, need)                          // closed mid-frame, at a stream offset
          self.buf += more                                // in place once unique (PROPOSAL, as in 01)
```

**Decision 3:** it doesn't arise with `Net.frames`, which is data. It does
for a hand-written framer that uses `Net` (a pipeline), with a startup
message read by hand:

```ren
// (a) let, no &                                 // (b) var, with &
let msgs = messages(conn)                          var msgs = messages(conn)
let Some(Startup(v)) = try msgs()                  let Some(Startup(v)) = try &msgs.next()
  else fail NoStartup                                else fail NoStartup
for msg in try msgs                                for msg in try &msgs
  ...                                                ...
```

**Verdict: (b), narrowly, and only because of `msgs()`.** Stepping a
pipeline by hand as a bare call reads like "make the messages", not "take
the next one". Under (a) with alt-1's cosmetic member, `try msgs.next()`,
the two read the same and (a) keeps its advantages from 01. **I'd adopt
(a) plus `.next()` as the pull type's one member, which means "call".**

### Best twin: Rust, tokio-util `Decoder` and `FramedRead`

```rust
struct PgCodec;
impl Decoder for PgCodec {
    type Item = PgMessage;
    type Error = PgError;
    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<PgMessage>, PgError> {
        if src.len() < 5 { return Ok(None); }
        let len = u32::from_be_bytes(src[1..5].try_into().unwrap()) as usize;
        if src.len() < 1 + len { src.reserve(1 + len - src.len()); return Ok(None); }
        let kind = src[0];
        let body = src.split_to(1 + len).freeze().slice(5..);
        Ok(Some(match kind {
            b'Q' => PgMessage::Query(cstr(&body)?),
            b'P' => parse_parse(&body)?,                 // hand-written
            b'X' => PgMessage::Terminate,
            k    => PgMessage::Other { kind: k, body },
        }))
    }
}

async fn session(sock: TcpStream, db: &Db, prepared: &Prepared) -> Result<(), PgError> {
    let (rd, mut wr) = sock.into_split();
    let mut frames = FramedRead::new(rd, PgCodec);
    while let Some(msg) = frames.next().await {
        match msg? {
            PgMessage::Query(sql) => reply(&mut wr, db.query(&sql).await?).await?,
            PgMessage::Parse { name, sql, oids } => prepared.add(name, sql, oids).await?,
            PgMessage::Terminate => break,
            PgMessage::Other { kind, .. } => reply_error(&mut wr, kind).await?,
        }
    }
    Ok(())   // EOF mid-frame: FramedRead gives "bytes remaining on stream", with no offset
}
```

### Comparison

- **Ren reads better:** the format does the per-kind decoding and the
  length bookkeeping. The session is 8 lines. Errors carry stream offsets
  with no code. `Net.frames` is 15 lines of user-writable Ren, while Rust's
  `FramedRead` is a library type with a trait.
- **Ren reads worse:** `name.copy()` is a thing to remember (KEEP).
  Rust's `Bytes` refcount pins a chunk just the same, but silently.
- **What Ren can't do:** nothing here.

**Leans on:** DATA, TRY, FMT, POS, KEEP, HEAD (a temporary `Net.frames(..)`
with no `&`). **Exceptions needed:** none. **PROPOSAL:** `Format<T>` as a
value. `len: UInt32 = rest + 4`, a length that says it bounds the frame (the
`=` of a constant, with an invertible size, as formats.md already
requires). Without it, a `CStr` body gives `Short(need: 1)` per missing
byte, and a framer re-views the frame once per byte, which is quadratic on
a large `Query`. `Net.read(conn,
max:)`. `Bytes +=`.

**Bugs fixed from the original:** the `buf ++ c` join was quadratic; the
EOF error lost its offset (`Truncated` with no `at`); `&chunks.next()` held
a second reader on the socket; `yield` sat after a `try match` detour.
There's no hand framer now.

---

## 03. A crawler: bounded, ordered, a timeout per page, a policy per page

URLs from a sitemap file. At most 16 at once, 10 s per page. Index the
results in sitemap order as they become ready. A 404 or 410 is skipped. A
5xx, a timeout or a reset is retried 3 times, then skipped. DNS failure
stops the crawl.

### Ren

```ren
type Skip = | NotThere(code: Int) | ServerSaid(code: Int) | TooSlow | Dropped
type Fetched = | Got(page: Page) | Skipped(url: Url, why: Skip)    // an outcome is data, not an error

fn fetch_once(u: Url) -> Page ! Server(code: Int) | Client(code: Int) | Timeout | Reset | DnsDown | BadPage =
  let resp = try Async.timeout(Duration.seconds(10)) fn() => try Http.get(u)
  if resp.status >= 500 then fail Server(resp.status)
  if resp.status >= 400 then fail Client(resp.status)
  try Page.read(resp)

// The policy: one `try match`. What it doesn't name (DnsDown, BadPage) stops the crawl.
fn fetch(u: Url) -> Fetched =
  try match retry(3, on: Server | Timeout | Reset) fn() => try fetch_once(u)
    p => Got(p)
    fail Client(c) => Skipped(u, NotThere(c))
    fail Server(c) => Skipped(u, ServerSaid(c))
    fail Timeout => Skipped(u, TooSlow)
    fail Reset => Skipped(u, Dropped)

gen fn sitemap_urls(p: Path) -> Url uses Fs ! FsError | BadUrl =
  for line in try Fs.line_reader(p)
    if not line.trim().is_empty() then yield try Url.parse(line.trim())

// (a) All at the end, in order.
fn crawl_all(sitemap: Path) -> Array<Fetched> =
  try Async.map(sitemap_urls(sitemap), max: 16) fn(u) => try fetch(u)

// (b) Streaming, in order, as ready: the consumer-block shape (ASYNC).
pub fn crawl(sitemap: Path) ! FsError | BadUrl | DnsDown | BadPage | IndexDown
    uses Fs, Http, Clock, Async, Index, Console =
  try Async.map_pull(sitemap_urls(sitemap), max: 16, fn(u) => try fetch(u)) fn(results) =>
    for r in try results
      match r
        Got(page) => try Index.add(page)
        Skipped(u, why) => Console.print("skipped \{u}: \{why}")
```

- **The source is a pipeline** (it uses `Fs`), passed to a block parameter
  and pulled on the caller's task, which is checked under PIPE: an
  ordinary block parameter can't be handed to a spawn.
- **`map_pull`'s tasks live exactly as long as the consumer block.** A
  `break` or a failure cancels them and waits. The draft's version, whose
  cancel-and-wait landed at a drop, is gone.

### Best twin: Elixir, `Task.async_stream`

```elixir
def crawl(sitemap) do
  sitemap
  |> File.stream!()
  |> Stream.map(&String.trim/1)
  |> Stream.reject(&(&1 == ""))
  |> Stream.map(&URI.new!/1)
  |> Task.async_stream(&fetch/1, max_concurrency: 16, timeout: :infinity, ordered: true)
  |> Enum.each(fn
       {:ok, {:got, page}}         -> Index.add!(page)
       {:ok, {:skipped, u, why}}   -> Logger.warning("skipped #{u}: #{inspect(why)}")
     end)
end

defp fetch(u) do
  case retry(3, fn -> Req.get(u, receive_timeout: 10_000, retry: false) end) do
    {:ok, %{status: s} = r} when s < 400 -> {:got, Page.read!(r)}
    {:ok, %{status: s}} when s < 500     -> {:skipped, u, {:not_there, s}}
    {:ok, %{status: s}}                  -> {:skipped, u, {:server_said, s}}
    {:error, %Req.TransportError{reason: :nxdomain}} = e -> raise "DNS down: #{inspect(e)}"
    {:error, %Req.TransportError{reason: :timeout}}      -> {:skipped, u, :too_slow}
    {:error, _}                                          -> {:skipped, u, :dropped}
  end
end
# retry/2: a 6-line helper that retries on 5xx and transport errors
```

### Comparison

- **Ren reads better:** the policy is checked. `retry(on: Server |
  Timeout | Reset)` is checked against what `fetch_once` can fail with, and
  `fetch`'s error row says exactly what stops the crawl. In Elixir a
  forgotten `:nxdomain` clause is a silent skip. Tasks keep fetching while
  the body indexes, as Elixir's do and as Rust's `buffered` doesn't
  (futurelock).
- **Ren reads worse:** the streaming form is one indent deeper than
  Elixir's pipe (the consumer-block shape), and `Async.map_pull` takes two
  blocks.
- **The same:** about 30 lines each with the policy.
- **What Ren can't do:** a BFS crawl, where results feed the source, isn't
  a stream. It's `Async.scope(max: 16)` with a `Seen` dependency, as in
  async.md, and that's fine.

**Leans on:** PIPE (a pipeline source passed down), GEN, ASYNC, TRY, HEAD,
`retry(on:)`, sum types for outcomes (errors.md, "to say why something
didn't happen as part of a value, use a sum type"). **Exceptions needed:**
none. `max: 16` is written, so (open #6) doesn't bite.

**Bugs fixed from the original:** `Err(e) => Log.warn(.., e)` bound a
whole error to a variable, which errors.md forbids. Outcomes are now a sum
type, so the double-layered `fetch_or_skip` is gone. `Web.get` is
`Http.get` (stdlib.md), and HTTP statuses are values that get classified,
not errors the client invents. Blank sitemap lines are skipped.

---

## 04. Merge two sorted, transformed streams by a key

Rows from a query and events from a log file, both sorted by time, merged
lazily. Stop after 1000. Two sources, one item of lookahead each.

### Ren

```ren
type Event = { at: Time, src: Src, msg: Str }

// A user stage. It takes blocks, so a call gives a pipeline (GEN). Ties go to `a`.
gen fn merge_by<T, K>(a: fn() -> Option<T>, b: fn() -> Option<T>, key: fn(T) -> K) -> T =
  var x = try a()
  var y = try b()
  while true
    match (x, y)
      (None, None) => return
      (Some(p), Some(q)) if key(q) < key(p) =>
        yield q
        y = try b()
      (Some(p), _) =>
        yield p
        x = try a()
      (None, Some(q)) =>
        yield q
        y = try b()

fn timeline(q: Query, path: Path) -> Array<Event> =
  try merge_by(Db.rows(q).map(Event.from_row),
               Fs.line_reader(path).map(parse_event),
               fn(e) => e.at)
    .take(1000)
    .to_array()
```

- **Both sources are temporary heads,** so neither needs `&` (HEAD). Each
  is a chain, so each is a block passed to a block parameter (PIPE).
- **`merge_by` is pulled,** since it's a two-input stage. Each pull is a
  direct call to a specialized block, with no coroutine and no channel.
- **`try a()` on a block parameter** passes on whatever `a` fails with, as
  `retry`'s body does. A `try` on a block whose row turns out empty isn't
  the "covers nothing" error, because the row is a variable where it's
  written.
- **An N-way merge** (a memtable plus N SSTables) takes `Array<SstReader>`,
  data readers, since blocks can't sit in an array (open #14).

### Best twin: Rust, itertools (sync)

```rust
use itertools::Itertools;

fn timeline(db: &mut Db, q: &Query, path: &Path) -> Result<Vec<Event>, Error> {
    let rows = db.rows(q)?.map(|r| Ok(Event::from_row(r?)));
    let logs = BufReader::new(File::open(path)?).lines().map(|l| parse_event(&l?));
    rows.merge_by(logs, |a: &Result<Event, Error>, b| match (a, b) {
            (Ok(a), Ok(b)) => a.at <= b.at,
            (Err(_), _) => true,                 // let an error through first, so `collect` stops
            _ => false,
        })
        .take(1000)
        .collect()
}
```

### Comparison

- **Ren reads better:** errors stay out of the comparator. Rust's `Result`
  items force a 4-arm comparator that has to think about where an error
  sorts. Ren's `try a()` ends the merge with the source's error and runs
  cleanup.
- **Ren reads worse:** Rust gets `merge_by` from a crate. In Ren it's a
  14-line user stage, unless the standard library ships it. **I'd add
  `merge_by` to the default set beside `scan` and `dedup_by`.** It's the
  stage the cursor design exists for, and every user would write the same
  14 lines.
- **What Ren can't do:** store the merged stream. A stored merge is a pure
  `gen fn` over data readers written for its types, `merge_logs(a: SstReader,
  b: SstReader)`, but that's a value cursor only if `SstReader.next` uses no
  dependency, and it does. So it can't be stored at all. That's "what's
  given up" (storing a generator that uses a dependency).

**Leans on:** PIPE, GEN (a block-taking `gen fn` is a stage), HEAD, TRY,
DOT, BLK (blocks passed to a block parameter). **Exceptions needed:**
none. This is the program the draft couldn't write.

**A finding this program surfaced (cleanup of data readers).** `Db.rows(q)`
and `Fs.line_reader(path)` are data readers (DATA). Data has no `finally`.
When `take(1000)` stops early, nothing closes the server-side cursor or
the file until the backstop (the `Db` or `Fs` handler's `with` ends), which
for a server is never. A program that greps 10,000 files with `for l in
try Fs.line_reader(p)` and `break`s leaks a descriptor per file. **Two
fixes, both small:**

1. The library ships both forms, for two questions. The generator form,
   `Fs.lines(p)` and `Db.query(q)`, is a pipeline with a `finally`, for use
   where it's made. The data form, `Fs.line_reader(p)`, is for keeping, and
   closes at EOF or at the backstop.
2. Or: a data reader closes its resource when it returns `None`, and a
   `for` over a *temporary* data reader runs the reader's `close` at the
   loop's end. That's a second cleanup mechanism, so I prefer 1.

With fix 1, the programs here would write `Fs.lines(p)` wherever the
stream isn't kept. I've left `line_reader` in the code to match the draft.

---

## 05. Walk a tree with `yield from`, and stop early

A pure in-memory tree, and a directory tree where each open level holds a
handle, so stopping early must close every level, innermost first. Find
the first 10 files over 1 MB.

### Ren

```ren
type Tree = { node: Node, children: Array<Tree> }

// Pure, values only: a value cursor `walk.Cursor`, storable and copyable (GEN).
gen fn walk(t: Tree) -> Node =
  yield t.node
  for c in t.children
    yield from walk(c)

fn find(t: Tree, name: Str) -> Option<Node> =
  walk(t).find(fn(n) => n.name == name)

type Entry = { path: Path, size: Int, dir: Bool, link: Bool }

// Uses Fs, so a call to it is a pipeline. One `finally` per open level.
gen fn walk_dir(p: Path) -> Entry uses Fs ! FsError =
  let d = try Fs.open_dir(p)
  finally d.close()
  for e in try d.entries()
    yield e
    if e.dir && not e.link then             // don't follow a linked directory: no cycles
      yield from try walk_dir(e.path)       // delegation that can fail is marked (TRY)

fn big_files(root: Path) -> Array<Entry> =
  try walk_dir(root)
    .select(fn(e) => not e.dir && e.size > 1_000_000)
    .take(10)
    .to_array()
  // After the 10th: the levels' `finally`s run innermost first, at the end of this statement.
```

- **`for n in walk(t)` needs no `&`:** it's a temporary (HEAD).
- **A stored mid-walk cursor** is a value. `var w = walk(t)` then `let
  saved = w` is an honest fork, two independent walks, because `walk`
  holds no resource. `walk_dir` can't be stored. Resuming a directory walk
  across requests means keeping the stack as data, `Array<(Path, Int)>`.
- **Cost (open #10).** `walk_dir` recurses through `yield from`, so under
  the recommendation it pulls: one boxed frame per level, and O(depth) per
  item. `walk` consumed by a `for` with no stages pushes, and so do
  non-recursive producers. If #10 pushes recursion on the task's frame
  allocator, `big_files` is O(1) per item too.

### Best twin: Kotlin (`sequence` and `flow`)

```kotlin
fun walk(t: Tree): Sequence<Node> = sequence {
    yield(t.node)
    for (c in t.children) yieldAll(walk(c))
}
fun find(t: Tree, name: String) = walk(t).find { it.name == name }

fun walkDir(p: Path): Flow<Entry> = flow {
    Files.newDirectoryStream(p).use { d ->
        for (e in d) {
            val entry = Entry.of(e)                    // attributes read with NOFOLLOW_LINKS
            emit(entry)
            if (entry.dir && !entry.link) emitAll(walkDir(e))
        }
    }
}.flowOn(Dispatchers.IO)

suspend fun bigFiles(root: Path) =
    walkDir(root).filter { !it.dir && it.size > 1_000_000 }.take(10).toList()
```

### Comparison

- **Ren reads better:** one kind of generator for both trees. Kotlin uses
  `sequence`/`yield`/`yieldAll` for the pure one and
  `flow`/`emit`/`emitAll` plus a dispatcher for the I/O one. The failing
  delegation is marked (`yield from try`). The lengths are the same.
- **Ren reads worse:** nothing in the text. In cost, Kotlin's `emitAll` is
  push, so it's O(1) per item at any depth. Ren's recursive `walk_dir` is
  O(depth) under #10's first step.
- **What Ren can't do:** store a directory walk (see above). Kotlin can't
  either without a channel and a coroutine.

**Leans on:** GEN (the same `gen fn` gives a value or a pipeline depending
on `uses`), HEAD, FIN (innermost-first unwinding), TRY, PUSH, DOT.
**Exceptions needed:** none.

**Bugs fixed from the original:** `&d.entries()` put `&` on a temporary.
Linked directories were followed, so a cycle walked forever. `yield from`
of a failing child was unmarked.

---

## 06. CSV: an error per line as a value, stop on a fatal one, aggregate

A trades file with a header. A line whose numbers don't parse is kept as
a bad line and the run goes on. A line with the wrong number of cells
means the file is misaligned: stop. More than 1,000 bad lines: stop.
Otherwise total the notional per symbol.

### Ren

```ren
type Trade = { sym: Sym, qty: Int, px: Money }
type BadLine = { line: Int, why: Str }
type Row = | Good(trade: Trade) | Bad(line: BadLine)          // a recoverable outcome is data
type Totals = { by_sym: Map<Sym, Money>, rows: Int, bad: Array<BadLine> }

  pub fn absorb(inout self, r: Row) ! TooManyBad =
    match r
      Good(t) =>
        self.rows += 1
        &self.by_sym.set(t.sym, (self.by_sym.get(t.sym) orelse Money.zero) + t.px * t.qty)
      Bad(b) =>
        if self.bad.len() >= 1000 then fail TooManyBad
        &self.bad.push(b)

// The width is fatal, in the signature. A cell that doesn't parse is a value.
fn parse_line(n: Int, line: Str, h: Header) -> Row ! Misaligned(line: Int, cells: Int) =
  let cells = line.split(",")                    // real code: std `csv`, for quoted cells
  if cells.len() != h.width then fail Misaligned(n, cells.len())
  match Trade.from_cells(cells, h)
    t => Good(t)
    fail BadNumber(col, text) => Bad(BadLine { line: n, why: "column \{col}: \{text}" })

pub fn summarize(path: Path) -> Totals
    ! FsError | NoHeader | BadHeader | Misaligned(line: Int, cells: Int) | TooManyBad uses Fs =
  var lines = Fs.line_reader(path)               // data: it keeps its offset
  let Some(head) = try &lines.next() else fail NoHeader
  let h = try Header.parse(head)
  var t = Totals.empty
  for i, l in try &lines                          // goes on after the header
    if not l.is_empty() then try &t.absorb(parse_line(i + 2, l, h))
  t
```

A chain form would need a `reduce` with an `absorb` that returns a new
`Totals`. It's no shorter, and the `for` is what people write first. The
appendix in amendments.md writes the chain. Both are fine.

**Decision 3:** the program uses a data reader, so it doesn't arise. It
does the moment the source becomes a generator, say a gzipped file:

```ren
// (a) let, no &                                     // (b) var, with &
let lines = gz_lines(path)                             var lines = gz_lines(path)
let Some(head) = try lines.next() else fail NoHeader   let Some(head) = try &lines.next() else fail NoHeader
let h = try Header.parse(head)                         let h = try Header.parse(head)
var t = Totals.empty                                   var t = Totals.empty
for i, l in try lines                                  for i, l in try &lines
  ...                                                    ...
```

**Verdict: (b), on refactoring.** Switching the source between
`Fs.line_reader(path)` and `gz_lines(path)` is a one-line change under
(b), and touches three lines under (a), with fix-its. Both read fine, but
here the reader's question is "is this the same stream?", and (b) answers
it with one idiom. (This assumes (a) gets `.next()` as in 02. Without it,
(a) is `try lines()`, which is worse.)

### Best twin: Rust, the `csv` crate

```rust
fn summarize(path: &Path) -> Result<Totals, Fatal> {
    let mut rdr = csv::Reader::from_path(path)?;            // reads the header
    let mut t = Totals::default();
    for (i, rec) in rdr.deserialize::<Trade>().enumerate() {
        let line = i + 2;
        match rec {
            Ok(tr) => t.add(tr),
            Err(e) => match e.kind() {
                csv::ErrorKind::UnequalLengths { .. } => return Err(Fatal::Misaligned(line, e)),
                csv::ErrorKind::Io(_) => return Err(Fatal::Io(e)),
                _ => {
                    if t.bad.len() >= 1000 { return Err(Fatal::TooManyBad) }
                    t.bad.push(BadLine { line, why: e.to_string() });
                }
            },
        }
    }
    Ok(t)
}
```

### Comparison

- **Ren reads better:** the fatal/recoverable split is in `parse_line`'s
  signature, not a `match` on error kinds at the use site, so it's 8 lines
  against 17. `&lines` says the header came out of the same reader the loop
  goes on with. `summarize`'s row lists exactly how the run can stop.
- **Ren reads worse:** Rust's `csv` crate handles quoting and the header
  for you. Ren's `split(",")` is a toy, and the real version calls std
  `csv`.
- **What Ren can't do:** nothing here.

**Leans on:** DATA (`var` and `&` resume after the header), HEAD, TRY,
sum types for outcomes, `orelse` with a default, `let ... else`, `for i,
x` over a cursor (decision 16), DOT. **Exceptions needed:** none.

**Bugs fixed from the original:** `Result<Trade, BadLine>` put a record
inside `Err`, but errors.md allows only tags there, so it's a sum type,
`Row`, now. `match attempt .. Err(e) => e.show()` bound a whole error,
which errors.md forbids. `by_sym.add(sym, v)` replaced the total instead
of adding to it. `{ ..self, bad: self.bad.push(b) }` used an `inout`
method as a function. A blank last line was counted as misaligned. A last
row with no newline is `Fs.line_reader`'s to give, and it does.

---

## 07. Database rows inside a transaction

Export one customer's orders from a snapshot to a file, marking each
exported row in the same transaction. Then the library version: "this
customer's orders, read in one transaction", as a stream other code
consumes, with `break`.

### Ren

**A. The consumer owns the transaction.**

```ren
pub fn export(c: CustomerId, out: Path) ! DbDown | Conflict | FsError | BadRow uses Sql, Fs =
  var w = try Fs.create(out)
  finally w.close()
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try Sql.rows("select * from orders where customer = $1", c)
      let o = try Order.from_row(row)
      try w.write_line(o.csv())
      try Sql.exec("update orders set exported = now() where id = $1", o.id)
```

Every `Sql` call in the body, `next` included, reaches the transaction,
because the body is inside the `with` (DEP). One library requirement this
makes visible: **inside a transaction, `Sql.rows` must read through a
named portal in batches** (Postgres's extended protocol keeps portals open
until the transaction ends), so that `Sql.exec` can run between fetches.
pgx and Npgsql refuse a second command while a reader is open, and the
original program silently assumed otherwise.

**B. The library version. It's now legal (YLD), and `break` rolls back (WHY).**

```ren
pub gen fn orders_in_tx(c: CustomerId) -> Order uses Sql ! DbDown | Conflict | BadRow =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try Sql.rows("select * from orders where customer = $1", c)
      yield try Order.from_row(row)

fn first_big(c: CustomerId, limit: Money) -> Option<Order> =
  try orders_in_tx(c).find(fn(o) => o.total > limit)
  // found early: the transaction's finally sees Err(Cancelled) and rolls back
```

**Preview, then go on in the same snapshot, both spellings of decision 3:**

```ren
// (a) let, no &                                   // (b) var, with &
let orders = orders_in_tx(c)    // BEGIN here      var orders = orders_in_tx(c)
for o in try orders.take(5)                        for o in try &orders.take(5)
  Console.print(o.summary())                         Console.print(o.summary())
if not try Confirm.ask("export the rest?") then    if not try Confirm.ask("export the rest?") then
  return                        // ROLLBACK          return
for o in try orders                                for o in try &orders
  try w.write_line(o.csv())     // COMMIT when       try w.write_line(o.csv())
                                // the generator ends
```

(Holding a transaction open across a human prompt is bad practice. It's
here because it shows a resume with a resource held between the loops.)

**Verdict: (a).** Under (b), `orders = orders_in_tx(c2)` looks legal, and
it would have to roll back the first transaction *at an assignment*. That
is cleanup at a drop, which decision 11 forbids. Under (a), the name can't
be rebound, the transaction's extent is the scope of `orders`, and the
reader has nothing to wonder about.

**D. What the draft let through is now an error.**

```ren
let rows = try with sql.transaction() over Sql in Sql.rows(q, c)
// error: `Sql.Rows` can't leave the `with` that installs `Sql`
```

- **The consumer's writes in B are not in the transaction.** The `Sql`
  in the consumer's body is the consumer's own (DEP), which is correct and
  visible. A consumer whose writes must join the transaction is version A.
  The draft's C1 (a block-taking `each_order` with a `Flow` enum) and C2 (a
  task plus a channel) aren't needed anymore.

### Best twin: C#, Npgsql and `IAsyncEnumerable` (for B)

```csharp
async IAsyncEnumerable<Order> OrdersInTx(long c,
    [EnumeratorCancellation] CancellationToken ct = default)
{
    await using var conn = await ds.OpenConnectionAsync(ct);
    await using var tx = await conn.BeginTransactionAsync(IsolationLevel.RepeatableRead, ct);
    await using var cmd = new NpgsqlCommand("select * from orders where customer = $1", conn, tx)
        { Parameters = { new() { Value = c } } };
    await using var rd = await cmd.ExecuteReaderAsync(ct);
    while (await rd.ReadAsync(ct)) yield return Order.From(rd);
    await tx.CommitAsync(ct);
}

var big = await OrdersInTx(c).FirstOrDefaultAsync(o => o.Total > limit);   // disposes: rollback
```

For A, every one of these languages needs `DECLARE c CURSOR ...; FETCH 500
FROM c` written by hand, since the driver refuses a second command while
a reader is open.

### Comparison

- **Ren reads better:** A is 8 lines, and the transaction's extent is the
  indentation. No other language makes "the consumer's writes are in the
  producer's transaction" this obvious. B is 4 lines against C#'s 10, with
  no cancellation token and no `await using` ladder. The rollback on an
  early stop is the same rule as everywhere else.
- **Ren reads worse:** you have to know that `break` means rollback
  (WHY), as you do in C# and Go.
- **What Ren can't do:** return the transaction's stream from a function
  that isn't a generator, or store it. Neither can C# without keeping the
  connection.

**Leans on:** YLD (`yield` inside `with`), GEN (`uses Sql` makes it a
pipeline, so it can't outlive the scope), FIN, WHY (open #4), DEP, the
with-escape rule (decision 7 given to values). **Exceptions needed:**
none. The with-escape rule is decision 7's task rule, given to values.

**Bugs fixed from the original:** `&Sql.rows(..)` put `&` on a temporary.
Version A assumed a second command could run while rows were being read.

---

## 08. Debounce and batch from a channel, on virtual time, and replayed

Handlers post events into a channel. One consumer batches them, at most
100 per batch or 200 ms after the first, and writes each batch. A search
box's queries are debounced at 300 ms. Both are tested on virtual time,
and a production run is replayed.

### Ren

```ren
dep Events = Chan<Event>
dep Queries = Chan<Str>

fn flusher() ! StoreDown uses Events, Store, Clock, Async =
  for batch in stream.time.batch(Events.items(), max: 100, within: Duration.ms(200))
    try Store.write_many(batch)

fn searcher() ! SearchDown uses Queries, Search, Results, Clock, Async =
  for q in stream.time.debounce(Queries.items(), Duration.ms(300))
    Results.show(try Search.run(q))
```

**Written by hand,** against the channel directly. That's simpler than the
original's generic `Recv<T>` parameter, and correct only because `recv` is
cancel-safe (async.md: a cancelled call never loses a result):

```ren
gen fn batches(max: Int, within: Duration) -> Array<Event> uses Events, Clock, Async =
  while true
    let Some(first) = Events.recv() else return       // closed and empty
    var b = [first]
    let deadline = Clock.now() + within
    while b.len() < max
      match attempt Async.timeout(deadline - Clock.now()) fn() => Events.recv()
        Ok(Some(x)) => &b.push(x)
        Ok(None) => break                              // closed: flush, then end at the next recv
        Err(Timeout) => break
    yield b

gen fn debounced(quiet: Duration) -> Str uses Queries, Clock, Async =
  let Some(first) = Queries.recv() else return
  var pending = first
  while true
    match attempt Async.timeout(quiet) fn() => Queries.recv()
      Ok(Some(q)) => pending = q
      Ok(None) =>
        yield pending
        return
      Err(Timeout) =>
        yield pending
        let Some(q) = Queries.recv() else return
        pending = q
```

`yield` sits outside the `Async.timeout` block (YLD), so the timeout's
scope opens and closes inside one step.

**Tests:**

```ren
test "a burst collapses to its last query" =
  with sync.channel(16) as Queries, recorded_results() in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Queries.send("r")
        Clock.sleep(Duration.ms(100))
        Queries.send("re")
        Clock.sleep(Duration.ms(100))
        Queries.send("ren")
        Clock.sleep(Duration.ms(1000))
        Queries.send("rust")
        Queries.close()
      var seen: Array<(Duration, Str)> = []
      for q in stream.time.debounce(Queries.items(), Duration.ms(300))
        &seen.push((Clock.now() - Time.epoch, q))
      assert seen == [(Duration.ms(500), "ren"), (Duration.ms(1200), "rust")]

test "a batch closes at 100 or at 200 ms" =
  with sync.channel(256) as Events in
    Async.scope fn(s) =>
      s.spawn fn() =>
        for i in 0..250
          Events.send(Event(i))
        Clock.sleep(Duration.ms(50))
        Events.send(Event(250))
        Events.close()
      let sizes = stream.time.batch(Events.items(), max: 100, within: Duration.ms(200))
        .map(fn(b) => b.len())
        .to_array()
      assert sizes == [100, 100, 51]

test "yesterday's incident" =
  with replay("tests/incident-2026-10-28.journal") in
    try flusher()
```

### Best twin: Kotlin, Flow and kotlinx-coroutines-test

```kotlin
fun searcher(queries: ReceiveChannel<String>, search: Search, results: Results) =
    queries.receiveAsFlow().debounce(300.milliseconds).map { search.run(it) }.onEach(results::show)

fun <T> ReceiveChannel<T>.batches(max: Int, within: Duration): Flow<List<T>> = flow {
    while (true) {
        val first = receiveCatching().getOrNull() ?: break
        val b = mutableListOf(first)
        withTimeoutOrNull(within) {
            while (b.size < max) b += receiveCatching().getOrNull() ?: return@withTimeoutOrNull
        }
        emit(b)
    }
}

@Test fun burstCollapses() = runTest {
    val ch = Channel<String>(16)
    launch {
        ch.send("r"); delay(100); ch.send("re"); delay(100); ch.send("ren")
        delay(1000); ch.send("rust"); ch.close()
    }
    val seen = ch.receiveAsFlow().debounce(300).map { currentTime to it }.toList()
    assertEquals(listOf(500L to "ren", 1200L to "rust"), seen)
}
```

### Comparison

- **The same:** the production code is about as long, and the
  hand-written operators are too.
- **Ren reads better:** the tests need no test dispatcher and no
  `currentTime`. `Clock` is a dependency, so the operators run on virtual
  time just by being tested, and `ren test --seeds 1000` explores
  schedules. Replaying a production journal is unique to Ren. Because
  `recv` is cancel-safe, the hand-written `batches` can't drop an item.
  Kotlin's `receiveCatching` inside `withTimeoutOrNull` can, under prompt
  cancellation, unless the channel has `onUndeliveredElement`.
- **Ren reads worse:** `Events.items()` is one more derived name to learn
  (CHAN). Kotlin's `receiveAsFlow()` is the same idea.
- **What Ren can't do:** `debounce` over a *generator* without putting it
  on a channel first (`Async.produce`). Kotlin's `debounce` does that
  internally with a hidden coroutine. Ren makes you write the task, which
  is the price of open #7's recommendation and honest about the cost.

**Leans on:** CHAN, YLD, GEN (`uses Events` makes the hand-written
operators pipelines), HEAD (temporary heads), cancel-safe `recv`,
`attempt` around `Async.timeout`, decision 11 (replay). **Exceptions
needed:** none. This depends on open #7 (a channel receiver).

**Bugs fixed from the original:** `for .. in try &stream.time..(..)` had a
`try` on a channel (a `recv` can't fail) and an `&` on a temporary. `var
seen = []` had no element type. The hand-written operators took a
`Recv<T>` that couldn't say which channel it reads; reading `Events`
directly is simpler and needs no new type.

---

## 09. A stream that has to be stored: keep a position, not a generator

A log service pages clients through "error entries since T". Each
client's position survives between requests. A config flag says whether
the file is read once or followed. A helper is reused, and a reusable lazy
stage takes a key.

### Ren

```ren
// 1. In place.
for e in try Fs.line_reader(path).map(Entry.parse).select(fn(e) => e.level >= min && e.at >= since)
  try Out.send(e)

// 2. A helper. A chain can't be returned, so it's a `gen fn`. It uses Fs: a pipeline.
gen fn errors_since(path: Path, min: Level, since: Time) -> Entry uses Fs ! FsError | Malformed =
  for e in try Fs.line_reader(path).map(Entry.parse)
    if e.level >= min && e.at >= since then yield e

for e in try errors_since(p, Warn, t0).take(10)   // pushed (PUSH): extracting it changed nothing
  Console.print(e.msg)

// 3. Stored per client: the position is data, `Fs.LineReader`, a named type (DATA).
dep Pages =
  page: fn(c: ClientId, n: Int) -> Array<Entry> ! FsError | Malformed

handler paged(path: Path, min: Level, since: Time, follow: Bool) for Pages uses Fs =
  var open: Map<ClientId, Fs.LineReader> = Map.empty()
  page(c, n) =>
    var r = open.get(c) orelse Fs.line_reader(path, follow: follow)   // PROPOSAL: `follow:`
    let out = try &r
      .map(Entry.parse)
      .select(fn(e) => e.level >= min && e.at >= since)
      .take(n)
      .to_array()
    &open.set(c, r)                     // copy out, step, copy back: see open #11
    out
```

- **The config flag is data.** PROPOSAL: `Fs.line_reader(path, follow:
  true)` gives a reader that, at EOF, returns `None` without consuming a
  partial last line, so a later `next` sees it whole. Following a file
  is then "call `page` again later". No second generator is needed, and
  the original's step 4 (`if follow then yield from tail(..) else ..`)
  disappears.
- **Copy out and back in** is there because a `next` is a dependency call,
  and decision 2's handler-state row says it writes all of the handler's
  state, `open` included. Under open #11 (narrowed), `try &open[c].map(..)`
  would be legal. That's not specific to streams. It's the most common
  shape that hits it.

**4. A reusable lazy stage with a key.** `dedup_by` is in the default set
now. A stage the library doesn't have is a `gen fn` that takes a block:

```ren
type Repeated = { entry: Entry, times: Int }

gen fn collapse<K>(src: fn() -> Option<Entry>, key: fn(Entry) -> K) -> Repeated =
  var cur: Option<Repeated> = None
  for e in try src
    match cur
      Some(r) if key(r.entry) == key(e) => cur = Some({ ..r, times: r.times + 1 })
      Some(r) =>
        yield r
        cur = Some(Repeated { entry: e, times: 1 })
      None => cur = Some(Repeated { entry: e, times: 1 })
  match cur
    Some(r) => yield r
    None => ()

for g in try collapse(errors_since(p, Warn, t0), fn(e) => e.code).take(20)
  Console.print("\{g.entry.msg} ×\{g.times}")
```

**A trap this program shows: lookahead across stored pages.** Put
`collapse` into `page` over the stored reader, `collapse(&r.map(..), key).take(n)`,
and each page loses the entry `collapse` pulled to see that a group had
ended. The reader moved past it, but it was never returned. That's
amendments.md's "lookahead loss", and here it's silent data loss across
requests. A stage that looks ahead shouldn't sit between a stored reader
and a `take`. **I'd make that a warning** (`ren review`: "`collapse` looks
ahead; items it pulled past `take(n)` are lost from `r`"), since the
compiler knows which stages look ahead.

**Decision 3**, the helper named and used twice:

```ren
// (a) let, no &                                  // (b) var, with &
let errs = errors_since(p, Warn, t0)                var errs = errors_since(p, Warn, t0)
for e in try errs.take(10)                          for e in try &errs.take(10)
  Console.print(e.msg)                                Console.print(e.msg)
let more = try errs.count()                         let more = try &errs.count()
Console.print("and \{more} more")                   Console.print("and \{more} more")
```

**Verdict: (b), narrowly.** `errs.count()` reads like a question about
`errs`, not something that uses it up. `&errs.count()` shows the
consumption. Under (a), a reader has to know `errs` is a generator to know
the count drains it.

### Best twin: Rust

```rust
fn errors_since(path: &Path, min: Level, since: Time)
    -> io::Result<impl Iterator<Item = Result<Entry, Error>> + Send> {
    let r = BufReader::new(File::open(path)?);
    Ok(r.lines()
        .map(|l| Ok(Entry::parse(&l?)?))
        .filter(move |e| match e { Ok(e) => e.level >= min && e.at >= since, Err(_) => true }))
}

struct Paged {
    path: PathBuf, min: Level, since: Time,
    open: HashMap<ClientId, Box<dyn Iterator<Item = Result<Entry, Error>> + Send>>,
}
impl Paged {
    fn page(&mut self, c: ClientId, n: usize) -> Result<Vec<Entry>, Error> {
        let it = match self.open.entry(c) {
            hash_map::Entry::Occupied(o) => o.into_mut(),
            hash_map::Entry::Vacant(v) => v.insert(Box::new(errors_since(&self.path, self.min, self.since)?)),
        };
        it.by_ref().take(n).collect()
    }
}
// a reusable stage: itertools' `dedup_by_with_count`, or an extension trait
```

### Comparison

- **Ren reads better:** what's stored is plain data with a name,
  `Fs.LineReader`. No `Box<dyn Iterator + Send>`, no `by_ref`, no entry
  API. Following a file falls out of "a position is data". In Rust the
  stored iterator has hit EOF, and a `Lines` iterator that returned `None`
  isn't fused, but resuming it isn't promised either.
- **Ren reads worse:** you can't store the *filtered* stream, only the
  reader, so the stages are written in `page`. Fine here, and worse if
  the pipeline were long, though then it's a function of the reader.
- **What Ren can't do:** store a generator that uses a dependency (the
  price of A2). Every case in this program was covered by a data reader.

**Leans on:** GEN, DATA, HEAD (`&r` head over a local copy), PUSH (the
helper keeps its cost), BLK, decision 2's handler row (open #11).
**Exceptions needed:** none. **PROPOSAL:** `Fs.line_reader(path,
follow:)`.

**Bugs fixed from the original:** the `???` map type is now
`Fs.LineReader`. `cur.take(n)` stepped a copy or not, depending on how the
reader was written; it's `&r` now. The config flag no longer needs two
generator arms.

---

## 10. Streams and actors

**A**: an actor operation consumes a stream, as one operation. **B**:
stream a summary of every live document into a file.

### Ren

```ren
dep Doc =
  edit: fn(op: Op) -> Version ! StoreDown
  edit_all: fn(ops: Array<Op>) -> Version ! StoreDown
  summary: fn() -> Summary
  import: fn(path: Path) -> Version ! StoreDown | FsError | BadOp
dep Docs = Actors<DocId, Doc>

// A2. The operation opens the stream itself: one operation, atomic.
handler doc(id: DocId) for Doc uses Store, Fs =
  var text = try Store.load(id)
  ...
  import(path) =>
    for op in try Fs.line_reader(path).map(Op.parse)
      text = text.apply(op)
    try Store.save(id, text)
    text.version

// A3. The caller streams, one operation per 500 ops. Not atomic, bounded memory.
fn import_chunked(id: DocId, path: Path) ! StoreDown | BadOp | FsError uses Docs, Fs =
  for ops in try Fs.line_reader(path).map(Op.parse).chunks(500)
    try Docs.at(id) fn() => try Doc.edit_all(ops)       // the actor is held for one chunk, not the file

// A4. Fan-in. The mailbox bounds the stream, and a posted block can't fail.
fn route(conn: Conn) ! NetError | BadOp uses Net, Docs, Alerts =
  for (id, op) in try Net.ops(conn)
    Docs.post(id) fn() =>
      match Doc.edit(op)
        _ => ()
        fail StoreDown => Alerts.raise(StoreDown(id))

// B3. Eager, the honest default: each actor is held for one call.
fn nightly(out: Path) ! FsError uses Docs, Fs =
  var all: Array<Summary> = []
  Docs.each(fn() => &all.push(Doc.summary()))
  var w = try Fs.create(out)
  finally w.close()
  for s in all
    try w.write_line(s.csv())

// B2. Streamed through a task (open #9: the producer sends through an installed `Send`).
fn nightly_streamed(out: Path) ! FsError uses Docs, Fs, Async =
  var w = try Fs.create(out)
  finally w.close()
  try Async.produce(cap: 64, fn() => Docs.each(fn() => Send.send(Doc.summary()))) fn(sums) =>
    for s in sums
      try w.write_line(s.csv())
```

**What's refused, with the rule that refuses it:**

```ren
// A1: an operation given a pipeline
  import_from: fn(ops: fn() -> Option<Op>) -> Version
// error: an operation can't take a block or a pipeline (decision 10)
// help: pass a data reader, `ops: Fs.LineReader`, or open the stream in the arm (A2)

// B1: a generator over the family
gen fn summaries() -> Summary uses Docs =
  Docs.each(fn() => yield Doc.summary())
// error: `yield` inside a block (YLD)
```

**An actor that keeps a reader in its state** (open #11):

```ren
handler replica(id: DocId) for Doc uses Fs, Store =
  var log = Fs.line_reader(log_path(id))         // data: kept between operations
  var text = try Store.load(id)
  catch_up() =>
    for op in try &log.map(Op.parse)             // today: error. `next` is a dependency call, which
      text = text.apply(op)                      //   writes all of this handler's state while `&log`
                                                 //   is held for the loop
// today's workaround:  var r = log;  for op in try &r.map(Op.parse) ...;  log = r
```

Under open #11 (narrow the row to `Async.until`, `release` and
block-parameter calls), the first form is legal. Without it, every actor
that keeps a stream writes the copy-out and copy-in dance.

### Best twin: Elixir, GenServer and Registry

```elixir
# A2: the process consumes a stream it opens itself
def handle_call({:import, path}, _from, doc) do
  text = path |> File.stream!() |> Stream.map(&Op.parse!/1) |> Enum.reduce(doc.text, &Text.apply(&2, &1))
  :ok = Store.save(doc.id, text)
  {:reply, text.version, %{doc | text: text}}
end

# A3: one call per 500 ops
path |> File.stream!() |> Stream.map(&Op.parse!/1) |> Stream.chunk_every(500)
|> Enum.each(&GenServer.call(via(id), {:edit_all, &1}))

# A4: fan-in; `cast` has an unbounded mailbox
Enum.each(ops, fn {id, op} -> GenServer.cast(via(id), {:edit, op}) end)

# B: every live doc, as a stream
Registry.select(Docs.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
|> Stream.map(&GenServer.call(&1, :summary))
|> Stream.map(&Summary.csv/1)
|> Stream.into(File.stream!(out))
|> Stream.run()
```

### Comparison

- **The same:** A2, A3 and B are as short as Elixir's, and the costs are
  on the page (one operation holds the actor; `post` bounds the mailbox,
  where Elixir's `cast` doesn't).
- **Ren reads better:** A1's hazard (a stream's block calling back into
  the actor that's running it) is a compile error. Elixir sends a `Stream`
  of closures to the process unchecked. A posted edit that can fail must
  say where its error goes.
- **Ren reads worse:** B1 isn't expressible, and B2 needs a task. Elixir's
  B is one pipe. B3 (eager) is fine at 50k documents, a few MB.
- **What Ren can't do:** stream out of `Docs.each` without a task.

**Leans on:** YLD (B1 is the "`yield` in a block" error), PIPE (A1 is "a
block can't go to an operation", decision 10), DATA (a reader as actor
state), ASYNC (`produce` with `Send`, open #9), decision 2's handler row
(open #11). **Exceptions needed:** none, if #11 is narrowed. Otherwise
actor-held readers need the copy dance, a wart rather than an exception.

**Bugs fixed from the original:** A3 held the actor while reading the file
(`Docs.at` wrapped the whole loop). It's one `at` per chunk now. A4's
posted block could fail; it handles `StoreDown` now. B2's `tx.send` was a
held channel value, which is against the bet.

---

## 11 (new). A lexer over `chars()`, with a user stage

Tokens from a `Str`, each a slice of the source with its byte offset.
A user stage inserts Go-style automatic semicolons. Errors report
`line:col`. A parser wants to backtrack, so the token stream must be
copyable.

### Ren

```ren
type Kind = | Ident | Number | Text | Punct | Space | Comment
type Token = { kind: Kind, text: Str, at: Int }           // `at`: a byte offset into the source (POS)
pub type LexError = ! BadChar(at: Int, ch: Str) | Unterminated(at: Int)

fn is_digit(c: Str) -> Bool =
  let n = c.code()                                        // a one-character Str's code point (CHR)
  n >= '0' && n <= '9'                                    // '0' is an Int
fn is_ident(c: Str) -> Bool = c == "_" || unicode.is_alphabetic(c) || is_digit(c)
fn is_space(c: Str) -> Bool = c == " " || c == "\t" || c == "\n" || c == "\r"   // ASCII, as `trim`

fn peek(cs: Str.Chars) -> Option<Str> =                   // PROPOSAL: the type's name, `Str.Chars`
  var ahead = cs                                          // a copy: lookahead is free
  &ahead.next()

// Steps `cs` past what `keep` accepts, and says how many bytes that was.
fn eat(inout cs: Str.Chars, keep: fn(Str) -> Bool) -> Int =
  var n = 0
  var going = true
  while going
    var ahead = cs
    match &ahead.next()
      Some(c) if keep(c) =>
        n += c.byte_len()
        cs = ahead
      _ => going = false
  n

fn string_rest(inout cs: Str.Chars, start: Int) -> Int ! Unterminated(at: Int) =
  var n = 0
  var escaped = false
  var open = true
  while open
    let Some(c) = &cs.next() else fail Unterminated(start)
    n += c.byte_len()
    if escaped then escaped = false
    else if c == "\\" then escaped = true
    else if c == "\"" then open = false
  n

// Pure, and takes only a value: a call gives a value cursor, `lex.Cursor` (GEN).
pub gen fn lex(src: Str) -> Token ! LexError =
  var cs = src.chars()
  var at = 0
  var more = true
  while more
    match &cs.next()
      None => more = false
      Some(c) =>
        let start = at
        at += c.byte_len()
        let kind =
          if is_space(c) then
            at += eat(&cs, is_space)
            Space
          else if c == "/" && peek(cs) == Some("/") then
            at += eat(&cs, fn(x) => x != "\n")
            Comment
          else if c == "_" || unicode.is_alphabetic(c) then
            at += eat(&cs, is_ident)
            Ident
          else if is_digit(c) then
            at += eat(&cs, is_digit)
            Number
          else if c == "\"" then
            at += try string_rest(&cs, start)
            Text
          else if "+-*/=<>(){}[],.;:".includes(c) then Punct
          else fail BadChar(start, c)
        yield Token { kind, text: src[start..at], at: start }    // found boundaries: never panics

// A user stage. It takes a block, so a call gives a pipeline (GEN).
// Go's rule: a newline after an identifier, a number, a string or a closer ends a statement.
gen fn semis(toks: fn() -> Option<Token>) -> Token =
  var last_ends = false
  for t in try toks
    match t.kind
      Space | Comment =>
        if last_ends && t.text.includes("\n") then
          yield Token { kind: Punct, text: ";", at: t.at }
          last_ends = false
      _ =>
        yield t
        last_ends = t.kind == Ident || t.kind == Number || t.kind == Text
          || t.text == ")" || t.text == "]" || t.text == "}"

// Wrapping by value makes it a value again: pure, takes only a Str.
pub gen fn tokens(src: Str) -> Token ! LexError =
  for t in try semis(lex(src))
    yield t

// The parser backtracks by copying, an honest fork.
fn parse_stmt(src: Str, inout p: tokens.Cursor) -> Stmt ! LexError | Expected(at: Int, what: Str) =
  let saved = p
  match attempt parse_decl(&p)
    Ok(d) => Decl(d)
    Err(_) =>
      p = saved
      Expr(try parse_expr(&p))

fn report(src: Str, at: Int, what: Str) -> Str =
  let (line, col) = src.line_col(at)                      // columns count code points
  "\{line}:\{col}: \{what}"
```

**With one small proposal,** `Str.Chars.at()` (the byte offset of the next
character, the same name and meaning as `ByteCursor.at()` in stdlib.md),
the bookkeeping goes away. `lex` loses its `at` variable and every `at +=`,
and `eat` returns nothing:

```ren
      Some(c) =>
        let start = cs.at() - c.byte_len()
        let kind =
          if is_space(c) then
            eat(&cs, is_space)
            Space
          else ...
        yield Token { kind, text: src[start..cs.at()], at: start }
```

### Best twin: Rust

```rust
#[derive(Clone)]
struct Lexer<'a> { src: &'a str, it: Peekable<CharIndices<'a>> }

impl<'a> Iterator for Lexer<'a> {
    type Item = Result<Token<'a>, LexError>;
    fn next(&mut self) -> Option<Self::Item> {
        let (start, c) = self.it.next()?;
        let kind = if c.is_ascii_whitespace() { self.eat(|c| c.is_ascii_whitespace()); Kind::Space }
            else if c == '/' && matches!(self.it.peek(), Some((_, '/'))) { self.eat(|c| c != '\n'); Kind::Comment }
            else if c == '_' || c.is_alphabetic() { self.eat(|c| c == '_' || c.is_alphanumeric()); Kind::Ident }
            else if c.is_ascii_digit() { self.eat(|c| c.is_ascii_digit()); Kind::Number }
            else if c == '"' { if let Err(e) = self.string_rest(start) { return Some(Err(e)) } Kind::Text }
            else if "+-*/=<>(){}[],.;:".contains(c) { Kind::Punct }
            else { return Some(Err(LexError::BadChar(start, c))) };
        let end = self.it.peek().map_or(self.src.len(), |&(i, _)| i);
        Some(Ok(Token { kind, text: &self.src[start..end], at: start }))
    }
}
impl Lexer<'_> {
    fn eat(&mut self, keep: impl Fn(char) -> bool) { while self.it.next_if(|&(_, c)| keep(c)).is_some() {} }
    fn string_rest(&mut self, start: usize) -> Result<(), LexError> { /* 8 lines, as Ren's */ }
}

fn semis<'a>(toks: impl Iterator<Item = Result<Token<'a>, LexError>>)
    -> impl Iterator<Item = Result<Token<'a>, LexError>> {
    let mut last_ends = false;
    toks.filter_map(move |t| match t {
        Ok(t) if matches!(t.kind, Kind::Space | Kind::Comment) =>
            (std::mem::take(&mut last_ends) && t.text.contains('\n')).then(|| Ok(Token::semi(t.at))),
        Ok(t) => { last_ends = t.ends_stmt(); Some(Ok(t)) }
        Err(e) => Some(Err(e)),
    })
}
```

(`mem::take` clears `last_ends` on a comment without a newline, which is a
bug. A careful Rust author writes the `if` out, which makes it as long as
Ren's.)

### Comparison

- **Ren reads better:** `semis` is a plain loop with `yield`, where Rust
  needs a `filter_map` closure over captured mutable state and a `Result`
  arm for passing errors on. `tokens` turns the pipeline back into a
  storable value by wrapping it in a pure `gen fn`, so backtracking is
  `let saved = p`. Rust gets that from `#[derive(Clone)]` on the lexer, but
  loses it after `semis` (an `impl Iterator` with a closure is `Clone` only
  if you ask for it in the bound). Errors and offsets work with `line_col`
  and need no `Result` items.
- **Ren reads worse:** offsets. Rust's `char_indices` gives them, and
  Ren sums `byte_len()` by hand, about 8 extra lines. `Str.Chars.at()`
  fixes it. User stages can't be dotted: `semis(lex(src))` against
  built-ins' `.take(10)`. Rust's extension traits and Kotlin's extension
  functions let a user stage read like a built-in one.
- **What Ren can't do:** nothing essential.

**Leans on:** CHR (`chars()` yields `Str`, `'0'` is an `Int`, `c.code()`),
POS (`at` is an offset into the source, `line_col` for reports), GEN (a
pure `gen fn` is a value, and a block-taking one is a pipeline), PIPE
(a value cursor passed where a pull block is expected), BLK. **Exceptions
needed:** none. **PROPOSAL:** the name `Str.Chars`; `Str.Chars.at()`.

**Finding: composition through values.** A pipeline wrapped in a pure
`gen fn` that takes only values is storable and copyable again. So
"storable" isn't lost by using a stage. It's recovered by naming the
stream's inputs as data. That falls out of A2 with no extra rule.

---

## 12 (new). Length-prefixed frames, with errors at stream offsets

A replica follows a primary over TCP. Frames are length-prefixed. A
`Batch` frame carries ops in a format. A `Legacy` frame carries rows
hand-encoded as varints, read with a byte cursor. Every error should say
where in the stream it happened. A truncated frame at EOF is an error, and
EOF between frames is a clean end.

### Ren

```ren
type Op = | Put(key: Str, val: Bytes) | Del(key: Str)
type Msg = | Hello(version: Int) | Batch(seq: Int, ops: Array<Op>) | Legacy(body: Bytes) | Bye

format wire for Op, be =
  kind: UInt8
  case kind
    'P' => Put { klen: UInt16, key: Str[klen], vlen: UInt32, val: Bytes[vlen] }
    'D' => Del { klen: UInt16, key: Str[klen] }

format wire for Msg, be =
  len: UInt32 = rest                       // PROPOSAL (as in 02): the length bounds the frame
  kind: UInt8
  case kind
    'H' => Hello(version: UInt16)
    'B' => Batch { seq: UInt64, n: UInt32, ops: Array<Op.wire>[n] }
    'L' => Legacy(body: Bytes[len - 1])
    'Q' => Bye

type Row = { id: Int, name: Str }

// Pure, values only: a value cursor. Its errors count from `from` (POS).
gen fn legacy_rows(body: Bytes, from: Int) -> Row ! FormatError =
  var c = body.cursor(from: from)
  while c.left() > 0
    let id = try &c.varuint()
    let n = try &c.varuint()
    let name = try &c.str(n)              // PROPOSAL: `Malformed(at, .., "not UTF-8")` at a stream offset
    yield Row { id, name: name.copy() }   // kept past the turn: copy (KEEP)

pub fn replicate(conn: Conn)
    ! NetError | FormatError | NoHello | BadVersion(got: Int) | Gap(at: Int, want: Int, got: Int) | StoreDown
    uses Net, Store =
  var frames = Net.frames(conn, Msg.wire)          // data: conn id, one buffer, the stream offset
  let Some(Hello(v)) = try &frames.next() else fail NoHello
  if v != 3 then fail BadVersion(v)
  var want = try Store.last_seq() + 1
  while true
    let start = frames.at()                        // PROPOSAL: the reader's stream offset, as ByteCursor's
    let Some(m) = try &frames.next() else return   // EOF between frames: a clean end
    match m
      Hello(_) => fail Malformed(start, "Msg", "a second Hello")
      Batch(seq, ops) =>
        if seq != want then fail Gap(start, want, seq)
        try Store.apply(ops)
        want += 1
      Legacy(body) =>
        for row in try legacy_rows(body, from: start + 5)     // after `len` and `kind`
          try Store.put_row(row)
      Bye => return

fn session(conn: Conn) uses Net, Store, Console =
  match replicate(conn)
    _ => ()
    fail Short(at, need) => Console.print("primary closed mid-frame at byte \{at}, \{need} short")
    fail Malformed(at, path, why) => Console.print("bad frame at byte \{at}, \{path}: \{why}")
    fail UnknownTag(at, tag) => Console.print("unknown frame kind \{tag} at byte \{at}")
    fail Gap(at, want, got) => Console.print("gap at byte \{at}: wanted \{want}, got \{got}")
    fail NoHello | fail BadVersion(_) => Console.print("not a v3 primary")
    fail _ => Console.print("replication stopped")
```

- **Every offset is a stream offset, and only two lines mention a base:**
  `Net.frames` carries its own, and `legacy_rows` is given `start + 5`
  once. The format's errors (`Malformed` inside an `Op`, `UnknownTag`)
  come out of `Net.frames` already counted from the stream's start.
- **Why a `while` and not `for m in try &frames`:** the `for` holds
  `&frames` for the whole loop (EXCL), so the body can't ask
  `frames.at()`. That's the rule working as intended. A loop that needs
  the position steps by hand, as strings.md says a loop that needs offsets
  "uses a cursor". The alternative is items that carry their offset, which
  strings.md refused for `chars()` (`for at, x`), so the hand loop is
  consistent.
- **The `at` trap stays closed:** `start` goes into errors and messages,
  never into an index.

**Decision 3:** doesn't arise, because `Net.frames` is data. A
hand-written framer that uses `Net` would be spelled as in 02.

### Best twin: Rust, tokio-util `LengthDelimitedCodec` and `binrw`

```rust
async fn replicate(sock: TcpStream, store: &Store) -> Result<(), ReplError> {
    let mut frames = FramedRead::new(sock, LengthDelimitedCodec::builder()
        .length_field_length(4).big_endian().new_codec());
    let mut offset: u64 = 0;                                   // tracked by hand
    let mut next = || async {
        let f = frames.next().await.transpose()?;               // EOF mid-frame: io::Error, no offset
        let start = offset;
        if let Some(f) = &f { offset += 4 + f.len() as u64; }
        Ok::<_, ReplError>(f.map(|f| (start, f)))
    };
    let Some((at, hello)) = next().await? else { return Err(ReplError::NoHello) };
    let Msg::Hello { version: 3 } = decode(&hello, at)? else { return Err(ReplError::NotV3) };
    let mut want = store.last_seq().await? + 1;
    while let Some((start, frame)) = next().await? {
        match decode(&frame, start)? {
            Msg::Batch { seq, ops } => {
                if seq != want { return Err(ReplError::Gap { at: start, want, got: seq }) }
                store.apply(ops).await?; want += 1;
            }
            Msg::Legacy(body) => for row in legacy_rows(&body) {
                store.put_row(row.map_err(|e| e.shifted(start + 5))?).await?;
            },
            Msg::Hello { .. } => return Err(ReplError::Malformed { at: start, why: "second hello".into() }),
            Msg::Bye => return Ok(()),
        }
    }
    Ok(())
}

fn decode(frame: &[u8], start: u64) -> Result<Msg, ReplError> {
    Msg::read(&mut Cursor::new(frame))                          // binrw
        .map_err(|e| ReplError::Malformed { at: start + 4 + e.position(), why: e.to_string() })
}
```

(The `next` closure borrows `frames` and `offset` mutably across awaits,
which the borrow checker refuses. Real code makes it a struct with a
method, about 10 more lines.)

### Comparison

- **Ren reads better:** no offset arithmetic except `start + 5`, which
  the layout makes obvious. A truncated last frame is `Short(at, need)`
  with a stream offset, where Rust's is an `io::Error` saying "bytes
  remaining on stream". The format is checked once and declares the tags.
  The session's `match` lists every way replication stops, checked
  exhaustive.
- **Ren reads worse:** the hand-stepped `while` instead of a `for`, which
  a newcomer won't expect, and `name.copy()`.
- **What Ren can't do:** nothing here.

**Leans on:** DATA (`Net.frames` is a reader), FMT (`view(from:)` inside
`Net.frames`, `Short` driving reads, nested `Op.wire`), POS (`cursor(from:)`,
offsets for reports only), EXCL (why the loop steps by hand), GEN (a pure
`legacy_rows` is a value cursor), KEEP, `let ... else`, TRY. **Exceptions
needed:** none. **PROPOSAL:** `len: UInt32 = rest`; `frames.at()`;
`ByteCursor.str(n)`. Without `c.str(n)`, `Str.from_utf8(try &c.bytes(n))`
reports `InvalidUtf8.at` within the field, since plain functions take no
base (strings.md), so the one error in this program not at a stream offset
would be the UTF-8 one. A cursor read of a `Str` should report like a
view's `Str` field does.

---

## 13 (new). A paginated HTTP API, crawled as a stream

List an organization's repositories through a paged API (100 per page,
`Link: next`), retrying a page 3 times on 5xx, timeouts and resets, with
10 s per attempt. Take the first 250 that aren't archived, fetching no
more pages than needed. Then: an interactive "more?" that resumes, and a
server that keeps each client's position between requests.

### Ren

```ren
type Repo = { name: Str, archived: Bool, stars: Int }
type RepoPage = { items: Array<Repo>, next: Option<Url> }

fn get_page(u: Url) -> RepoPage ! Server(code: Int) | Refused(code: Int) | Timeout | Reset | DnsDown | JsonError =
  let resp = try Async.timeout(Duration.seconds(10)) fn() => try Http.get(u)
  if resp.status >= 500 then fail Server(resp.status)
  if resp.status != 200 then fail Refused(resp.status)
  let body = try resp.body.read_str()               // PROPOSAL: read a whole body as text
  RepoPage { items: try json.decode<Array<Repo>>(body), next: next_link(resp.headers) }

// Uses Http: a call gives a pipeline (GEN).
pub gen fn repos(org: Str) -> Repo
    uses Http, Clock, Async ! Server(code: Int) | Refused(code: Int) | Timeout | Reset | DnsDown | JsonError =
  var at = api("/orgs/\{org}/repos?per_page=100")
  var more = true
  while more
    let page = try retry(3, on: Server | Timeout | Reset) fn() => try get_page(at)
    for r in page.items
      yield r                                        // outside `retry`'s block (YLD)
    match page.next
      Some(u) => at = u
      None => more = false

fn first_active(org: Str) -> Array<Repo> =
  try repos(org)
    .reject(fn(r) => r.archived)
    .take(250)
    .to_array()
  // Pushed (PUSH): page 4 is fetched only if pages 1 to 3 held fewer than 250.
```

**Interactive "more?", both spellings of decision 3:**

```ren
// (a) let, no &                                   // (b) var, with &
let rs = repos(org)                                  var rs = repos(org)
var going = true                                     var going = true
while going                                          while going
  for r in try rs.take(20)                             for r in try &rs.take(20)
    Console.print(r.name)                                Console.print(r.name)
  going = try Keys.ask("more?")                        going = try Keys.ask("more?")
```

**Verdict: (b), clearly.** `rs.take(20)` inside a loop reads, to anyone
from C# (`IEnumerable.Take` re-enumerates) or Kotlin (a cold `Flow`
re-collects), as "the first 20 again". `&rs.take(20)` says "the next 20
from `rs`". The meaning is the same under both. Only (b) shows it.

**Kept between requests: the position is data,** so it's written as a
record, and a generator isn't needed at all:

```ren
pub type RepoCursor = { next: Option<Url>, page: Array<Repo>, i: Int }
  pub fn start(org: Str) -> RepoCursor =
    RepoCursor { next: Some(api("/orgs/\{org}/repos?per_page=100")), page: [], i: 0 }

  pub fn next(inout self) -> Option<Repo>
      uses Http, Clock, Async ! Server(code: Int) | Refused(code: Int) | Timeout | Reset | DnsDown | JsonError =
    while self.i == self.page.len()
      let Some(u) = self.next else return None
      let p = try retry(3, on: Server | Timeout | Reset) fn() => try get_page(u)
      self.page = p.items
      self.i = 0
      self.next = p.next
    self.i += 1
    Some(self.page[self.i - 1])

// Local use reads the same: `for r in try &RepoCursor.start(org)`, or as a temporary.
```

If you know you'll keep it, write the record and use it everywhere. `repos`
is then redundant. That's the price of A2, and it's paid once, in the
library that knows a page token is its position.

### Best twin: C#, `IAsyncEnumerable` with Polly

```csharp
public async IAsyncEnumerable<Repo> Repos(string org,
    [EnumeratorCancellation] CancellationToken ct = default)
{
    var pipeline = new ResiliencePipelineBuilder<HttpResponseMessage>()
        .AddRetry(new RetryStrategyOptions<HttpResponseMessage> {
            MaxRetryAttempts = 3,
            ShouldHandle = new PredicateBuilder<HttpResponseMessage>()
                .Handle<HttpRequestException>()
                .Handle<TimeoutRejectedException>()
                .HandleResult(r => (int)r.StatusCode >= 500) })
        .AddTimeout(TimeSpan.FromSeconds(10))                    // inner: per attempt
        .Build();
    Uri? url = new($"https://api.example.com/orgs/{org}/repos?per_page=100");
    while (url is not null)
    {
        using var resp = await pipeline.ExecuteAsync(async t => await http.GetAsync(url, t), ct);
        resp.EnsureSuccessStatusCode();
        foreach (var r in (await resp.Content.ReadFromJsonAsync<List<Repo>>(ct))!) yield return r;
        url = NextLink(resp.Headers);
    }
}

var first = await Repos("acme").Where(r => !r.Archived).Take(250).ToListAsync(ct);   // System.Linq.Async

await using var e = Repos(org).GetAsyncEnumerator(ct);              // "more?": hold the enumerator
do { for (int i = 0; i < 20 && await e.MoveNextAsync(); i++) Console.WriteLine(e.Current.Name); }
while (AskMore());
```

### Comparison

- **Ren reads better:** the retry policy is checked against what
  `get_page` can fail with. Polly's `ShouldHandle` is a runtime predicate,
  and forgetting `TimeoutRejectedException` is a silent non-retry. No
  cancellation token, no `[EnumeratorCancellation]`, no extra package for
  `Where`/`Take` on async streams. "More?" in Ren is a loop over a name. C#
  drops to `GetAsyncEnumerator` and `MoveNextAsync`.
- **The same:** the generator bodies are equally long.
- **Ren reads worse:** keeping the position between requests means
  writing `RepoCursor` by hand. C# has the same problem (an enumerator
  can't outlive the request either), so it's a wash in practice.
  `retry(n, on:)` can't honour a 429's `Retry-After`. That's a hand-written
  loop in both, and Polly has a hook for it.
- **What Ren can't do:** store the `repos` generator itself (A2).

**Leans on:** GEN, PUSH (laziness across pages: no page is fetched
early), YLD (`yield` outside `retry`'s block), `retry(on:)`, DATA (the
record), HEAD, DOT. **Exceptions needed:** none. **PROPOSAL:**
`resp.body.read_str()`.

---

## Summary

### Reads better, the same, or worse than the best twin

| Program | Best twin | Ren | Why, in one line |
|---|---|---|---|
| 01 tail a log | Kotlin Flow (+ Rust `by_ref`) | **better** | resume after `break` is real; the close point is fixed by syntax |
| 02 Postgres framing | Rust tokio-util | **better** | the format does the decoding, and errors carry stream offsets |
| 03 crawler | Elixir `async_stream` | **same** | the policy is checked, at the cost of one more indent than Elixir's pipe |
| 04 sorted merge | Rust itertools | **same** | errors stay out of the comparator, but `merge_by` is user code unless std ships it |
| 05 tree walk | Kotlin `sequence`/`flow` | **better** | one generator kind, a marked delegation (O(depth) cost under #10) |
| 06 CSV | Rust `csv` | **better** | the fatal/recoverable split is in a signature: 8 lines against 17 |
| 07 rows in a transaction | C# Npgsql | **better** | `yield` in `with`, rollback on `break`, and version A has no equal |
| 08 debounce and batch | Kotlin + coroutines-test | **same** (code), better (tests) | replay and seed exploration are unique |
| 09 stored per client | Rust `Box<dyn Iterator>` | **same** | storing a named reader beats `Box<dyn>`; you can't store the filtered stream |
| 10 actors | Elixir GenServer | **same** | checked where Elixir isn't, and B needs a task |
| 11 lexer | Rust `Peekable<CharIndices>` | **worse** | offsets by hand, and user stages can't be dotted (same with `Chars.at()`) |
| 12 frames and offsets | Rust tokio-util + binrw | **better** | stream offsets with one `+ 5`; a truncated frame is a typed `Short` |
| 13 paginated API | C# + Polly | **better** | the checked retry and "more?" as a loop; storing is a hand record in both |

**Tally: 7 better, 5 the same, 1 worse.** Every program was written
without an exception or special case to the rules in the legend. The new
things it needed are library names and one format feature:

- `Bytes +=`
- `len = rest` in a format
- `Format<T>` as a value
- `Net.read(max:)`
- `frames.at()`, `Str.Chars.at()`, `ByteCursor.str(n)`
- `Fs.line_reader(follow:)`
- `resp.body.read_str()`
- the name `Str.Chars`

### Decision 3, the tally

| Program | Where it arises | Clearer | Why |
|---|---|---|---|
| 01 | `sections`: resume a tailed file | **(a)** | under (b), `lines = follow(q)` would have to close the file at an `=` |
| 02 | a hand framer, startup read by hand | **(b)**, or a tie if (a) gets `.next()` | `try msgs()` reads like "make", not "take the next" |
| 06 | the header, then the rest, from a generator | **(b)** | swapping a data reader for a generator is a one-line change |
| 07 | preview 5, then go on in the same transaction | **(a)** | under (b), reassigning would roll back a transaction at an `=` |
| 09 | the first 10, then count the rest | **(b)** | `&errs.count()` shows that the count uses `errs` up |
| 13 | "more?" in a loop | **(b)** | `rs.take(20)` in a loop reads as "the first 20 again" to C# and Kotlin eyes |
| 03, 04, 05, 08, 10, 11, 12 | doesn't arise (temporaries, data readers, or value cursors) | | |

**(b) 4, (a) 2.** The split is telling:

- **(b) wins at the use site.** It shows *consumption and continuation*
  (`&rs.take(20)`, `&errs.count()`) and keeps one idiom for "a named stream
  I step", data or generator.
- **(a) wins on semantics.** It makes rebinding impossible, and with it
  cleanup at an `=` (closing a file, rolling back a transaction), which is
  the drop-time cleanup that decision 11 and the amendments just removed.

**A third spelling covers both, and I'd put it to the owner:** (c) `let g =
follow(p)` with `&g` at each use (`for l in try &g`, `&g.take(20)`, `try
&g.next()`). `let` makes rebinding impossible, so cleanup stays at scope
end. `&` keeps the one use-site idiom shared with data readers, and shows
consumption. The cost is one sentence in decision 2: "`&` marks a place
being changed, or a named stream being stepped". The draft had `&` on a
`let` and was marked down for breaking that rule. The programs say the
sentence is worth adding. If (c) is too much, (b) reads better in more
programs, provided `var`-bound pipelines can't be assigned. That's a
special case, which is why I'd rank (c) first, (a) with `.next()` second,
and (b) third.

### Findings for the design

1. **Data readers over resources have no prompt close** (04). `Db.rows`
   and `Fs.line_reader` are data, data has no `finally`, and a `break` or
   `take` leaves the cursor or file open until the backstop. Recommend:
   the library ships the generator form for use where it's made
   (`Fs.lines(p)`, a pipeline with a `finally`) and the data form for
   keeping. The judge-ethos table already separates "use here" from "keep".
2. **User stages can't be dotted** (11). `semis(lex(src)).take(10)`
   against `.take(10)`. `lex(src) |> semis` works for one stage. It's the
   one place the uniformity of stages visibly breaks.
3. **Lookahead across a stored reader and a `take` silently drops items**
   (09). The compiler knows which stages look ahead, so `ren review` can
   warn.
4. **A `for` holds its reader, so offsets need a hand loop** (12). It's
   consistent with strings.md's refusal of `for at, x`, and correct, but
   newcomers will hit it. `frames.at()` plus a `while` is the idiom.
5. **Wrapping a pipeline in a pure, value-taking `gen fn` makes it a
   value again** (11). Storability comes back by naming inputs as data,
   with no extra rule. That's the strongest evidence that A2 composes.
6. **`merge_by` belongs in the default set** (04). It's the program the
   cursor design exists for.
7. **Position as data gives you tailing for free** (09, with `follow:`).
   Calling `next` again after `None` reads what was appended.
8. **Bugs the originals had, beyond the task's list:**
   - `Err(record)` and binding a whole error, both forbidden by errors.md
     (03, 06);
   - `Map.add` replacing a running total (06);
   - a quadratic `buf ++ c` (02);
   - an actor held across a file read (10 A3);
   - a second SQL command while a reader was open (07 A);
   - UTF-8 cut at a chunk boundary (01);
   - following linked directories into a cycle (05).

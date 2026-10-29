# 2. A Postgres-style framed protocol over socket chunks

`PgMessage` from formats.md, read with `view`, `.rest` and
`Short(at, need)` from a cursor of leased chunks. A message may span
chunks; a chunk may hold several messages.

## Ren, per the draft

```ren
type PgMessage =
  | Query(sql: Str)
  | Parse { name: Str, sql: Str, oids: Array<Oid> }
  | Terminate
  | Other { kind: UInt8, body: Bytes }

format wire for PgMessage, be =
  kind: UInt8
  len: UInt32
  case kind
    'Q' => Query(sql: CStr)
    'P' => Parse { name: CStr, sql: CStr, n: UInt16, oids: Array<UInt32 as Oid>[n] }
    'X' => Terminate
    _   => Other { kind, body: Bytes[len - 4] }

// The framer: a generator over the connection's chunks.
gen fn messages(conn: Conn) -> PgMessage uses Net ! NetError | FormatError | Truncated =
  var chunks = Net.chunks(conn)              // a cursor holding the connection id
  var buf = Bytes.empty()
  while true
    let got = try match PgMessage.wire.view(buf)
      m =>
        buf = m.rest                         // a slice of the leased chunk (or the joined buffer)
        Some(m.value)                        // `Query(sql)`: `sql` is a slice too
      fail Short(_, _) => None               // `need` is unused: a chunk is whatever arrived
    match got
      Some(msg) => yield msg                 // yield outside the `match` with `fail` arms (allowed?)
      None =>
        match try &chunks.next()
          Some(c) =>
            buf = if buf.len() == 0 then c else buf ++ c   // a copy only when a frame spans chunks
          None =>
            if buf.len() == 0 then return else fail Truncated

// The server loop for one connection.
fn session(conn: Conn) uses Net, Db ! NetError | FormatError | Truncated | DbDown =
  for msg in try &messages(conn)
    match msg
      Query(sql) => try reply(conn, try Db.query(sql))
      Parse { name, sql, oids } => try Prepared.add(name.copy(), sql.copy(), oids)  // kept: copy
      Terminate => break
      Other { kind, .. } => try reply_error(conn, Unsupported(kind))
```

Lines: framer 20, session 7. Without the `got` detour (if `yield`
may sit in a `match` arm whose scrutinee has `fail` arms) the framer is
16.

## Rust: tokio-util `Decoder` + `FramedRead`

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
        let frame = src.split_to(1 + len).freeze();     // zero-copy Bytes
        let body = frame.slice(5..);
        Ok(Some(match kind {
            b'Q' => PgMessage::Query(cstr(&body)?),
            b'P' => parse_parse(&body)?,                // hand-written
            b'X' => PgMessage::Terminate,
            k    => PgMessage::Other { kind: k, body },
        }))
    }
}

async fn session(sock: TcpStream, db: &Db) -> Result<(), PgError> {
    let (rd, mut wr) = sock.into_split();
    let mut frames = FramedRead::new(rd, PgCodec);
    while let Some(msg) = frames.next().await {
        match msg? {
            PgMessage::Query(sql) => reply(&mut wr, db.query(&sql).await?).await?,
            PgMessage::Terminate => break,
            /* ... */
        }
    }
    Ok(())
}
```

## Go: `bufio.Reader` + `io.ReadFull`

```go
func readMessage(r *bufio.Reader) (Msg, error) {
    var hdr [5]byte
    if _, err := io.ReadFull(r, hdr[:]); err != nil { return Msg{}, err }
    n := int(binary.BigEndian.Uint32(hdr[1:])) - 4
    body := make([]byte, n)
    if _, err := io.ReadFull(r, body); err != nil { return Msg{}, err }
    return decode(hdr[0], body)            // hand-written per kind
}
```

## Comparison

| | Ren | Rust (tokio-util) | Go |
|---|---|---|---|
| framer | 20 | 19 + per-kind parsing | 8 + per-kind parsing, copies every body |
| layout declared once, checked | yes (format) | no | no |
| zero-copy within a chunk | yes (slices) | yes (`split_to`) | no |
| copy when a frame spans chunks | `buf ++ c`, whole tail | `BytesMut` grows in place, amortized | n/a |
| partial reads | `Short` + loop | `Ok(None)` + `reserve` | `ReadFull` hides it |

**Better in Ren.** The format does all the per-kind decoding and length
bookkeeping that Rust and Go write by hand; the session loop is the
clearest of the three; one `try` on the `for` covers I/O and framing
errors.

**Worse or unclear.**

1. **Every program writes the accumulate-and-retry loop.** The draft
   rules out "implicit chunking" and has no framing adapter; formats.md
   says "no streaming parser is needed" and shows `conn.read_more(need)`,
   which doesn't exist in the chunks-as-cursor model (you can't ask a
   chunk cursor for `need` bytes). Rust has `Decoder`/`FramedRead`, Go
   `bufio.Reader`/`Scanner`, Elixir `{:packet, 4}`. Ren wants one
   library cursor: `Net.frames(conn, PgMessage.wire)` (or
   `chunks.frames(fmt)`), a `gen fn` generic over a format. Whether a
   format can be a `gen fn`'s argument (is `PgMessage.wire` a value? a
   type-level name?) isn't said anywhere.
2. **`buf ++ c` copies the whole unread tail each time a frame spans
   chunks,** quadratic for one large frame arriving in many small
   chunks (a 1 MB `CopyData` in 16 KB chunks: 64 copies, ~32 MB moved).
   Rust's `BytesMut` reserves and appends. Ren needs either "read until
   `need`" into one buffer (`Short.need` makes that possible:
   allocate `need`, lend it, fill), or an append that reuses a unique
   buffer in place. The obvious code is the slow code here.
3. **Leases are pinned by slices.** `buf = m.rest` and `Query(sql)` are
   slices of the leased chunk, so the chunk goes back to the pool only
   when the next message has been read *and* the consumer has dropped
   every slice. The draft's "leased buffers go back to the pool when the
   body's turn ends" is true only if the body keeps nothing. One
   `Prepared.add(name, sql)` without `.copy()` pins a 64 KB pool buffer
   for the life of the connection; with 10k connections the pool runs
   dry and the *server stalls* rather than allocating. Debug builds
   report "roots kept alive by small slices", but here the cost is
   liveness, not memory. Suggest: a slice of a leased buffer that's kept
   past the turn is copied out (by the compiler at the keep point, or
   the lease degrades into a heap buffer), or a hard debug error.
4. **`Short(at, ...)`: `at` is "the offset in the socket's buffer"**
   (formats.md) only while the message sits in one chunk. After
   `buf ++ c` it's an offset in the joined buffer. Error offsets in a
   stream need a base the framer tracks.
5. **`yield` inside a `match` whose scrutinee has `fail` arms**, and
   inside `try match`: not forbidden by the list in Concurrency, but a
   `try match` is a handler region in effect. Say it's allowed.
6. Writing replies on the same `conn` while `messages(conn)` holds a copy
   of its id is fine by "two names for one connection", but nothing
   stops another task from reading `Net.chunks(conn)` too: two readers
   on one socket each get arbitrary chunks. "Copying the cursor copies
   the id: honest" is honest about aliasing but makes this bug easy.

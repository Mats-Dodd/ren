# Programs, part 2: flottning's storage engine

Four slices of flottning's engine, written in Ren against `design.md`'s
recommended designs, and against formats.md, streams.md and strings.md
as decided. Each sits beside the twin that does the job best today, with
an honest comparison, the rules it leaned on, and what was missing,
magic or verbose.

None of this compiles yet. It assumes what design.md §9 puts in 12b
(`Fs` handles, `sim.fs`, `checksum`, `collections.OrderedMap` and `Heap`)
plus formats (7b) and generators (11c). Where I had to invent an API,
it's marked **assumed**, and the gaps are collected in the last section.

The engine is small on purpose: a write-ahead log, a memtable, SSTables
at level 0 and level 1, a catalog in SQLite, and a `Store` dependency
the HTTP server uses. It's LevelDB's shape, with TigerBeetle's habits
where they help (checksums checked in a fixed order, recovery that
reports offsets, a crash simulator).

## Contents

- [Shared types](#shared-types)
- [1. The write-ahead log](#1-the-write-ahead-log)
- [2. Memtable flush, SSTables and an N-way merge](#2-memtable-flush-sstables-and-an-n-way-merge)
- [3. The catalog in SQLite](#3-the-catalog-in-sqlite)
- [4. The engine as a dependency, and a crash test](#4-the-engine-as-a-dependency-and-a-crash-test)
- [Scorecard](#scorecard)
- [What std is missing](#what-std-is-missing)
- [Where the design felt magic or verbose](#where-the-design-felt-magic-or-verbose)
- [Asks for design.md](#asks-for-designmd)

---

## Shared types

```ren
pub type Lsn = opaque Int
  pub fn parse(n: Int) -> Lsn ! Invalid = if n < 0 then fail Invalid else Lsn(n)
  pub fn next(self) -> Lsn = Lsn(self.0 + 1)
  pub fn int(self) -> Int = self.0

pub type Key = opaque Bytes                       // ordered bytewise (strings.md "Equality, hashing and order")
  pub fn parse(b: Bytes) -> Key ! Invalid =
    if b.is_empty() || b.len() > 1.kb then fail Invalid else Key(b)
  pub fn bytes(self) -> Bytes = self.0

pub type Op =
  | Put { key: Key, value: Bytes }
  | Delete(key: Key)

pub type Record = { lsn: Lsn, op: Op }
```

The domain types never mention bytes. Every byte layout below is a
`format` *for* one of them (formats.md "A type, and its formats").

---

## 1. The write-ahead log

**Job:** records through a format with a checksum; append with fsync,
grouped so concurrent writers share one; recovery that reads until a
torn record and reports its offset.

### Ren

```ren
import checksum

// ---- the bytes ----

format wal for Op, le =
  kind: UInt8
  case kind
    1 => Put { klen: UInt16, vlen: UInt32, key: Bytes[klen] as Key, value: Bytes[vlen] }
    2 => Delete { klen: UInt16, key: Bytes[klen] as Key }

format wal for Record, le =
  lsn: UInt64 as Lsn
  op: Op.wal

/// One frame of the log: a checksum and a length around a record's bytes.
type Frame = { body: Bytes }

format wal for Frame, le =
  crc: UInt32                       // CRC32C of `body`: the format's own field
  len: UInt32                       // filled in when writing
  body: Bytes[len]

assert Frame.wal.offset(body) == 8  // checked on every build

fn frame_of(r: Record) -> Bytes =
  let body = Record.wal.encode(r)
  var out = Frame.wal.encode(Frame { body })          // `crc` written as zero
  try Frame.wal.edit(&out) fn(&h) =>                   // can't fail: we just wrote it
    h.crc = checksum.crc32c(body)
  out

// ---- the service ----

pub dep Wal =
  append: fn(op: Op) -> Lsn ! DiskFull | IoError
  sync: fn(upto: Lsn) ! IoError
  truncate_before: fn(lsn: Lsn) ! IoError             // after a flush made it durable elsewhere

pub type Torn = | ShortTail(at: Int, need: Int) | BadCrc(at: Int) | BadRecord(at: Int, path: Str, why: Str)

pub type Recovered = { records: Array<Record>, end: Int, torn: Option<Torn> }

pub type RecoveryMode = | TolerateTornTail | Strict  // policies are data (language.md §11)

handler file_wal(path: Path, mode: RecoveryMode = TolerateTornTail) for Wal
    uses Fs ! IoError | Corrupt(at: Int) =
  let f = try Fs.open(path, ReadWrite, create: true)      // assumed: Fs handles, 12b
  try Fs.lock(f)                                           // one writer per directory
  let rec = recover(try Fs.read_all(f))
  if rec.torn is Some(t) then
    match (mode, t)
      (Strict, _) => fail Corrupt(torn_at(t))
      (TolerateTornTail, BadCrc(at)) if rec.end < try Fs.size(f) - 4.kb => fail Corrupt(at)   // not a tail
      _ =>
        try Fs.truncate(f, rec.end)                        // cut the torn record off
        try Fs.datasync(f)
  var written = rec.end                                    // bytes in the file
  var next = rec.records.last().map(fn(r) => r.lsn.next()).or(Lsn(0))
  var appended = next                                      // highest lsn written, not yet synced
  var synced = next                                        // highest lsn known durable
  finally(r) =>
    try Fs.datasync(f)
    try r

  append(op) =>
    let lsn = next
    let bytes = frame_of(Record { lsn, op })
    try Fs.write_at(f, written, bytes)                     // into the page cache
    written += bytes.len()
    next = lsn.next()
    appended = lsn
    lsn

  sync(upto) =>
    if upto <= synced then return                          // someone's fsync already covered it
    let target = appended                                  // read before letting go
    try release Fs.datasync(f)                             // appends go on while the disk works
    if target > synced then synced = target                // monotonic: a later sync may have won

  truncate_before(lsn) => ...                              // segment files; left out here

/// Reads frames until the bytes end or one is torn. Pure: unit-testable on any Bytes.
pub fn recover(b: Bytes) -> Recovered =
  var out: Array<Record> = []
  var rest = b
  var pos = 0
  while rest.len() > 0
    match attempt Frame.wal.view(rest, from: pos)
      Ok(fr) =>
        if fr.crc != checksum.crc32c(fr.body) then
          return Recovered { records: out, end: pos, torn: Some(BadCrc(pos)) }
        match attempt Record.wal.view(fr.body, from: pos + 8)
          Ok(r) => &out.push(r.value)
          Err(Malformed(at, path, why)) => return Recovered { records: out, end: pos, torn: Some(BadRecord(at, path, why)) }
          Err(Short(at, _)) | Err(UnknownTag(at, _)) => return Recovered { records: out, end: pos, torn: Some(BadRecord(at, "Record", "short or unknown tag")) }
        pos += rest.len() - fr.rest.len()                 // the bytes this frame took
        rest = fr.rest
      Err(Short(at, need)) => return Recovered { records: out, end: pos, torn: Some(ShortTail(at, need)) }
      Err(e) => return Recovered { records: out, end: pos, torn: Some(BadRecord(e.at, "Frame", "malformed")) }
  Recovered { records: out, end: pos, torn: None }

test "a torn last record is reported at its offset" =
  let a = frame_of(Record { lsn: Lsn(0), op: Delete(key("a")) })
  let b = frame_of(Record { lsn: Lsn(1), op: Put { key: key("b"), value: "xyz".bytes() } })
  let r = recover(a + b[0..b.len() - 2])
  assert r.records.len() == 1
  assert r.end == a.len()
  assert r.torn == Some(ShortTail(a.len() + 8, 2))
```

What a writer does, in the engine (§4):

```ren
let lsn = try Wal.append(op)
try Wal.sync(lsn)                 // returns at once if another writer's fsync covered it
```

### Twin: Go (etcd's `wal` and LevelDB's `log` idioms)

```go
var castagnoli = crc32.MakeTable(crc32.Castagnoli)

func encode(r Record) []byte {
	body := make([]byte, 8+1+2+4+len(r.Key)+len(r.Value))
	binary.LittleEndian.PutUint64(body[0:], r.LSN)
	body[8] = r.Kind
	binary.LittleEndian.PutUint16(body[9:], uint16(len(r.Key)))
	binary.LittleEndian.PutUint32(body[11:], uint32(len(r.Value)))
	copy(body[15:], r.Key)
	copy(body[15+len(r.Key):], r.Value)
	out := make([]byte, 8+len(body))
	binary.LittleEndian.PutUint32(out[0:], crc32.Checksum(body, castagnoli))
	binary.LittleEndian.PutUint32(out[4:], uint32(len(body)))
	copy(out[8:], body)
	return out
}

func Recover(data []byte) (recs []Record, end int, torn error) {
	off := 0
	for off < len(data) {
		if len(data)-off < 8 {
			return recs, off, &ShortTail{At: off}
		}
		sum := binary.LittleEndian.Uint32(data[off:])
		n := int(binary.LittleEndian.Uint32(data[off+4:]))
		if len(data)-off-8 < n {
			return recs, off, &ShortTail{At: off}
		}
		body := data[off+8 : off+8+n]
		if crc32.Checksum(body, castagnoli) != sum {
			return recs, off, &BadCRC{At: off}
		}
		r, err := decode(body) // 20 more lines of bounds checks; miss one and a crafted vlen panics
		if err != nil {
			return recs, off, err
		}
		recs = append(recs, r)
		off += 8 + n
	}
	return recs, off, nil
}

// group commit: a mutex, a cond, and a "syncing" flag (etcd's wal.sync, LevelDB's writer queue)
func (w *WAL) Sync(upto uint64) error {
	w.mu.Lock()
	for w.syncing && w.synced < upto {
		w.cond.Wait()
	}
	if w.synced >= upto {
		w.mu.Unlock()
		return nil
	}
	target := w.appended
	w.syncing = true
	w.mu.Unlock()
	err := w.f.Sync()
	w.mu.Lock()
	w.syncing = false
	if err == nil && target > w.synced {
		w.synced = target
	}
	w.cond.Broadcast()
	w.mu.Unlock()
	return err
}
```

### Comparison

| | Ren | Go |
|---|---|---|
| Lines (codec + recovery + group sync) | ~75 | ~95 (with `decode`) |
| Byte offsets written by hand | 0 | 14 (`body[9:]`, `off+4`, ...) |
| A crafted length that overruns | `Short`/`Malformed` with an offset, from `view` | a panic unless every check is written |
| Delete with a value | can't be encoded: the sum has no field for it | a `Kind` byte and a zero-length value, by convention |
| Group commit | `release` around the fsync, plus a monotonic max | a mutex, a cond, a `syncing` flag, `Broadcast` |
| Torn-tail offset | `end: pos`, the same number `truncate` takes | the same |

**Better:** the codec is declared, not written, and recovery can't read
past a buffer. Group commit is the handler rule doing the work: an
operation holds the instance (foundations.md decision 10), so two
appends can't claim one offset and a record written during an fsync
isn't published as durable, the two bugs research/paper-programs.md found.
The one `release` is where state can change, and `sim` switches tasks
there, so dropping the `if target > synced` guard is a lost update a
seed finds.

**Worse:** writing the checksum takes an `edit` block with a `try` that
can't fail, and two encodes (`Record.wal.encode`, then `Frame.wal.encode`
copies the body). Go writes into one buffer. Ren could too, with
layer 3 (`&out.set_u32_le(0, crc)`), but then the offset `0` is repeated
by hand, which is what the format was for. Computing a frame's consumed
length (`rest.len() - fr.rest.len()`) is clumsy, and the rule that an
error's `at` is "for reports, never for indexing" fights recovery, whose
whole job is to truncate at the offset it reports. Here it's sound only
because the view was made with `from: pos`, so `at` and `pos` agree; I
used `pos` for the truncate and `at` only in reports, as the rule says,
but it took thought.

**Rules leaned on:** formats (`view` checks once; `case` with counts
filled in on write; `as Key` runs the constructor; checksums are ordinary
code; `Short(at, need)`; `from:` base), strings.md positions, decision 10
plus `release`, `finally` on the handler, policies are data
(`RecoveryMode`), bounded by default (`Key.parse` caps at 1 KB).

---

## 2. Memtable flush, SSTables and an N-way merge

**Job:** flush a sorted memtable to an SSTable file of checksummed data
blocks, an index block and a fixed footer; then merge N sorted sources
(the memtable and N tables), newest version of each key winning, which
streams.md lists as a dynamic N-way merge.

### Ren: the file

```ren
pub type Seq = opaque Int   // as Lsn
pub type Val = | Value(v: Bytes) | Tomb
pub type Entry = { key: Key, seq: Seq, val: Val }

format sst for Val, le =
  kind: UInt8
  case kind
    1 => Value { vlen: VarUInt, v: Bytes[vlen] }
    2 => Tomb

format sst for Entry, le =
  klen: VarUInt
  key: Bytes[klen] as Key
  seq: UInt64 as Seq
  val: Val.sst

type BlockTrailer = { count: Int }
format sst for BlockTrailer, le, size 8 =
  count: UInt32
  crc: UInt32                                  // CRC32C of the block's entries

type IndexEntry = { last: Key, offset: Int, len: Int }
format sst for IndexEntry, le =
  klen: VarUInt
  last: Bytes[klen] as Key
  offset: UInt64
  len: UInt32

type Footer = { index_offset: Int, index_len: Int, entries: Int }
format v1 for Footer, le, size 40 =
  index_offset: UInt64
  index_len: UInt32
  entries: UInt64
  index_crc: UInt32
  _: reserved(8)
  magic: UInt64 = 0x5453_5354_544F_4C46     // "FLOTTSST"

assert Footer.v1.size == 40

let BLOCK = 4.kb

/// Writes `mem` to `path` through a temporary name, then renames it:
/// the file is either all there or not there.
pub fn flush(mem: OrderedMap<Key, (Seq, Val)>, path: Path) -> TableMeta ! IoError | DiskFull uses Fs =
  let tmp = path.with_ext("tmp")
  let f = try Fs.open(tmp, Write, create: true, truncate: true)
  finally(r) =>
    Fs.close(f)
    try r
  var block = Bytes.with_capacity(BLOCK + 1.kb)
  var count = 0
  var index: Array<IndexEntry> = []
  var off = 0
  var last: Option<Key> = None

  fn seal(&block, &count, &index, &off, last: Key) ! IoError | DiskFull uses Fs =  // see "verbose" below
    var trailer = BlockTrailer.sst.encode(BlockTrailer { count })
    try BlockTrailer.sst.edit(&trailer) fn(&t) => t.crc = checksum.crc32c(block)
    try Fs.append(f, [block, trailer])                          // assumed: vectored append
    &index.push(IndexEntry { last, offset: off, len: block.len() + 8 })
    off += block.len() + 8
    &block.clear()
    count = 0

  for (key, (seq, val)) in mem                                   // in key order
    Entry.sst.append(&block, Entry { key, seq, val })            // assumed: append to a growing buffer
    count += 1
    last = Some(key)
    if block.len() >= BLOCK then try seal(&block, &count, &index, &off, key)
  if count > 0 then try seal(&block, &count, &index, &off, last.unwrap())

  var ix = Bytes.empty
  for e in index => IndexEntry.sst.append(&ix, e)
  var foot = Footer.v1.encode(Footer { index_offset: off, index_len: ix.len(), entries: mem.len() })
  try Footer.v1.edit(&foot) fn(&h) => h.index_crc = checksum.crc32c(ix)
  try Fs.append(f, [ix, foot])
  try Fs.sync(f)                                    // the file's bytes...
  try Fs.rename(tmp, path)
  try Fs.sync_dir(path.parent())                    // ...and its name (LevelDB, RocksDB, SQLite all do both)
  TableMeta.of(path, mem, off + ix.len() + 40)
```

### Ren: reading, a data cursor

```ren
/// A table's reader: data (an open file's id, the index, one block),
/// so it can sit in an Array (streams.md rule 6).
pub type SstReader = {
  file: Fs.File,                        // id + incarnation: data, not an instance
  index: Array<IndexEntry>,
  block: Bytes,                         // the current block's entries, verified
  rest: Bytes,                          // what's left of it
  next_block: Int,
  base: Int,                            // the block's offset in the file, for reports
}

pub fn open_table(path: Path) -> SstReader ! IoError | Corrupt(at: Int, why: Str) uses Fs =
  let f = try Fs.open(path, Read)
  let size = try Fs.size(f)
  let tail = try Fs.read_at(f, size - 40, 40)
  let foot = try Footer.v1.view(tail, from: size - 40) map_err corrupt   // magic checked here
  let ix = try Fs.read_at(f, foot.index_offset, foot.index_len)
  if checksum.crc32c(ix) != foot.index_crc then fail Corrupt(foot.index_offset, "index checksum")
  var index: Array<IndexEntry> = []
  var rest = ix
  while rest.len() > 0
    let e = try IndexEntry.sst.view(rest) map_err corrupt
    &index.push(e.value)
    rest = e.rest
  SstReader { file: f, index, block: Bytes.empty, rest: Bytes.empty, next_block: 0, base: 0 }

impl SstReader
  pub fn next(inout self) -> Option<Entry> ! IoError | Corrupt(at: Int, why: Str) uses Fs =
    while self.rest.is_empty()
      if self.next_block == self.index.len() then return None
      let b = self.index[self.next_block]
      let bytes = try Fs.read_at(self.file, b.offset, b.len)
      let t = try BlockTrailer.sst.view(bytes[b.len - 8 ..], from: b.offset + b.len - 8) map_err corrupt
      self.block = bytes[0 .. b.len - 8]
      if checksum.crc32c(self.block) != t.crc then fail Corrupt(b.offset, "block checksum")
      self.rest = self.block
      self.base = b.offset
      self.next_block += 1
    let e = try Entry.sst.view(self.rest, from: self.base + self.block.len() - self.rest.len()) map_err corrupt
    self.rest = e.rest
    Some(e.value)                       // key and value are slices of the block: no copy
```

(`map_err corrupt` stands for a one-line `match` turning a `FormatError`
into `Corrupt(at, why)`. Ren has no `map_err` today. See "verbose".)

### Ren: the merge

```ren
/// The sources a merge reads. A closed sum, not an erased `Cursor<T>`:
/// the engine knows every kind it merges.
pub type Source =
  | Mem(OrderedMap.Cursor<Key, (Seq, Val)>)     // assumed: the cursor type has a name
  | Table(SstReader)

impl Source
  pub fn next(inout self) -> Option<Entry> ! IoError | Corrupt(at: Int, why: Str) uses Fs =
    match &self
      Mem(&c) => c.next().map(fn((key, (seq, val))) => Entry { key, seq, val })
      Table(&r) => try r.next()

/// Newest version of each key, in key order. Uses `Fs`, so a call is a
/// block (streams.md rule 2): it's looped over where it's made.
pub gen fn merged(sources: Array<Source>, drop_tombs: Bool = false) -> Entry
    uses Fs ! IoError | Corrupt(at: Int, why: Str) =
  var srcs = sources
  var heap: Heap<(Key, Int, Int)> = Heap.empty     // (key, -seq, source): smallest first
  var heads: Array<Option<Entry>> = []
  for i, _ in srcs
    let h = try &srcs[i].next()
    &heads.push(h)
    if h is Some(e) then &heap.push((e.key, -e.seq.int(), i))
  var last: Option<Key> = None
  while heap.len() > 0
    let (key, _, i) = &heap.pop().unwrap()
    let Some(e) = heads[i] else unreachable
    heads[i] = try &srcs[i].next()
    if heads[i] is Some(n) then &heap.push((n.key, -n.seq.int(), i))
    if Some(key) == last then continue           // an older version: shadowed
    last = Some(key)
    if drop_tombs && e.val == Tomb then continue
    yield e

/// Compaction: N tables into one, at level 1.
fn compact(inputs: Array<TableMeta>, out: Path) -> TableMeta ! IoError | DiskFull | Corrupt(..) uses Fs =
  var srcs: Array<Source> = []
  for t in inputs => &srcs.push(Table(try open_table(t.path)))
  try write_table(out) fn(&w) =>                  // flush's body, taking a stream instead of a map
    for e in try merged(srcs, drop_tombs: true)    // pushed: no state machine
      try &w.add(e)
```

### Twin: Rust (LevelDB's `MergingIterator`, RocksDB's table builder idioms)

```rust
pub struct SstReader { file: File, index: Vec<IndexEntry>, block: Vec<u8>, pos: usize, next_block: usize }

impl Iterator for SstReader {
    type Item = io::Result<Entry>;
    fn next(&mut self) -> Option<Self::Item> {
        while self.pos >= self.block.len() {
            let b = self.index.get(self.next_block)?;
            let mut buf = vec![0; b.len as usize];
            if let Err(e) = self.file.read_exact_at(&mut buf, b.offset) { return Some(Err(e)); }
            let (body, trailer) = buf.split_at(buf.len() - 8);
            let crc = u32::from_le_bytes(trailer[4..8].try_into().unwrap());
            if crc32c::crc32c(body) != crc { return Some(Err(corrupt(b.offset, "block checksum"))); }
            self.block = body.to_vec(); self.pos = 0; self.next_block += 1;
        }
        Some(decode_entry(&self.block, &mut self.pos)) // varint, slice, u64, tag: ~25 lines, each bounds-checked by hand
    }
}

pub fn merged(sources: Vec<Box<dyn Iterator<Item = io::Result<Entry>>>>)
    -> impl Iterator<Item = io::Result<Entry>> {
    let mut srcs = sources;
    let mut heap = BinaryHeap::new();
    let mut heads: Vec<Option<Entry>> = Vec::new();
    // ... the same loop, with Reverse((key.clone(), Reverse(seq), i)) and `?` inside a closure
    std::iter::from_fn(move || { /* 25 lines */ })
}
```

### Comparison

| | Ren | Rust |
|---|---|---|
| Lines (formats + flush + reader + merge) | ~150 | ~210 with the hand codec |
| Footer, trailer, entry layout | declared, sizes asserted at build | `to_le_bytes`/`from_le_bytes` at offsets, a `const FOOTER: usize = 40` |
| Keys in the merge | slices of the block, no copy | `key.clone()` into the heap, or lifetimes that tie the heap to every reader |
| Heterogeneous sources | a closed sum `Source` with a two-arm `next` | `Box<dyn Iterator>`, a vtable per step |
| Errors inside the merge | `uses Fs ! IoError \| Corrupt`, `for e in try merged(..)` | `Item = io::Result<Entry>`, so every consumer unwraps per item |
| Laziness | a `gen fn`, pushed into the compaction loop | `from_fn` closure state machine |

**Better:** the formats remove every offset constant, and keys stay
slices of their blocks (decision 17), which Rust can only do with
lifetimes that tie the heap to the readers, so real Rust engines copy
(LevelDB's `MergingIterator` copies keys into `std::string`s). The
`Source` sum is the ML answer to "erased cursor": two kinds, one `match`,
no vtable, and it's what the owner's taste asks for. streams.md said the
merge would have to be over `Array<SstReader>`; a sum of the two concrete
readers is enough and needs no new feature, *if* the memtable's cursor
type can be named (see gaps).

**Worse:**
- `flush`'s `seal` helper passes five `&` places because Ren has no
  local closures that mutate captures and can be called twice. Rust's
  closure or a `TableBuilder` struct does it with `&mut self`. In Ren
  the right answer is the same as Rust's: a `TableWriter` record with
  `inout self` methods (I used one in `compact` as `w`). That's fine, but
  the first draft was wrong, and the record is ~20 lines.
- Format-only types: `BlockTrailer`, `IndexEntry` and `Footer` exist only
  to have a format (formats.md: "no standalone formats"). Each costs a
  type line that repeats the format's placed fields. For a storage
  engine, about a third of the formats are like this. It's honest (the
  rule keeps one kind of record), and the cost is a line each.
- The heap: `Heap` isn't in std, and a merge needs a heap or a loser
  tree. Ordering by `(Key, Int, Int)` uses the built-in tuple order,
  which is good: no comparator object.

**Rules leaned on:** streams rule 1 (a reader is data and can sit in an
`Array`), rule 2 (`merged` uses `Fs`, so it's a block, looped where it's
made), rule 5 (its frame closes with the loop), rule 6 (`Fs.File` is an
id and an incarnation); formats (fixed `size`, `reads`-ready `v1`,
`magic` constant checked on `view`, `from:`); decision 17 (slices).

---

## 3. The catalog in SQLite

**Job:** the set of live tables (the "manifest"), and the WAL
checkpoint, kept in SQLite. A flush records its table and moves the
checkpoint in one transaction; a compaction swaps inputs for outputs in
one. Rows decode through shapes, holes bind through `sql"..."`.

### Ren

```ren
import sql

pub type TableId = opaque Int        // `pub fn parse(Int)`, as Lsn
pub type TableMeta = {
  id: TableId, level: Int, path: Path,
  min_key: Key, max_key: Key, entries: Int, bytes: Int,
}

let SCHEMA = try sql.parse_schema(try Fs.read_str("db/schema.sql"))   // build time: the build's world
let MIGRATIONS = try sql.migrations_from(try Fs.list("db/migrations"))

// db/schema.sql
//   create table tables (id integer primary key, level integer not null, path blob not null,
//     min_key blob not null, max_key blob not null, entries integer not null, bytes integer not null) strict;
//   create table checkpoint (one integer primary key check (one = 1), lsn integer not null) strict;

pub fn live_tables() -> Array<TableMeta> ! DbDown | SqlRow(..) uses Sql =
  try sql.query<TableMeta>(sql"select * from tables order by level, min_key").to_array()

pub fn checkpoint() -> Lsn ! DbDown | SqlRow(..) | NotFound uses Sql =
  let row: { lsn: Lsn } = try sql.one(sql"select lsn from checkpoint")
  row.lsn

/// A flush: the table is in the catalog and the WAL before `upto` is
/// no longer needed, or neither.
pub fn record_flush(t: TableMeta, upto: Lsn) ! DbDown | SqlConstraint(name: Str) | Conflict uses Sql =
  try with sql.transaction(isolation: Immediate) over Sql in
    try Sql.exec(sql"insert into tables \{sql.values(t)}")      // a Query hole splices (design §6.2)
    try Sql.exec(sql"update checkpoint set lsn = \{upto}")

/// A compaction: inputs out, outputs in, atomically.
pub fn record_compaction(inputs: Array<TableId>, outputs: Array<TableMeta>) ! DbDown | SqlConstraint(..) | Conflict uses Sql =
  try with sql.transaction(isolation: Immediate) over Sql in
    try Sql.exec(sql"delete from tables where id in \{sql.list(inputs)}")
    for t in outputs
      try Sql.exec(sql"insert into tables \{sql.values(t)}")

/// Files on disk that the catalog doesn't name: left by a crash between
/// writing a table and committing it, or between committing a compaction
/// and removing its inputs (RocksDB's "obsolete files").
pub fn sweep(dir: Path) ! DbDown | SqlRow(..) | IoError uses Sql, Fs =
  let live = Set.of(try live_tables().map(fn(t) => t.path))
  for p in try Fs.list(dir)
    if p.ext() == "sst" && not live.has(p) then try Fs.remove(p)
```

`sql.values(t)` and `sql.list(xs)` are ordinary library functions over
shapes that return a `Query` fragment: `(id, level, ...) values (?, ?,
...)` and `(?, ?, ?)`. No new feature: design §6.2 already splices a hole
of type `Query`.

### Twin: Go (`database/sql` + `mattn/go-sqlite3`), and Rust `sqlx`

```go
func RecordFlush(ctx context.Context, db *sql.DB, t TableMeta, upto uint64) (err error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil { return err }
	defer func() {
		if err != nil { tx.Rollback() } else { err = tx.Commit() }
	}()
	if _, err = tx.ExecContext(ctx,
		`insert into tables (id, level, path, min_key, max_key, entries, bytes) values (?, ?, ?, ?, ?, ?, ?)`,
		t.ID, t.Level, t.Path, t.MinKey, t.MaxKey, t.Entries, t.Bytes); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `update checkpoint set lsn = ?`, upto)
	return err
}

func LiveTables(ctx context.Context, db *sql.DB) ([]TableMeta, error) {
	rows, err := db.QueryContext(ctx, `select id, level, path, min_key, max_key, entries, bytes from tables order by level, min_key`)
	if err != nil { return nil, err }
	defer rows.Close()
	var out []TableMeta
	for rows.Next() {
		var t TableMeta
		if err := rows.Scan(&t.ID, &t.Level, &t.Path, &t.MinKey, &t.MaxKey, &t.Entries, &t.Bytes); err != nil { // positional
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
```

Rust's `sqlx::query_as!(TableMeta, "select ...")` checks the SQL at
compile time, against a live database or a cached `.sqlx/` directory.

### Comparison

| | Ren | Go | Rust sqlx |
|---|---|---|---|
| Lines | ~35 | ~55 | ~35 |
| Rows to records | by column name, through the shape; a wrong type is `SqlRow(column, expected)` | positional `Scan`: swap two `int` columns and it's silently wrong | by name, checked at build |
| Insert | `\{sql.values(t)}`: columns from the shape | columns written twice | columns written twice |
| Transaction | `with sql.transaction() over Sql`: `finally` commits on `Ok`, rolls back on `Err` and `Cancelled` | a `defer` with a named `err` result | `tx.commit()` explicitly; drop rolls back |
| Checked SQL | at build, from `db/schema.sql` (hermetic) | no | at build, from a live DB or `.sqlx/` cache |
| Under a crash simulator | yes: SQLite's VFS goes through `Fs`, so `sim.fs` tears its pages | no | no |

**Better:** rows by name and holes as values are the two things Go gets
wrong. The transaction is a handler, so `record_flush` can't forget to
commit or roll back, and a cancel (a server's drain deadline) rolls
back. The decisive one for flottning is the last row: the catalog and
the engine's own files fail together under one `sim.fs`, so a seed can
find the ordering bug every LSM has had at least once (commit the
catalog before the table's file is synced, crash, the catalog names a
table that's half on disk). Nothing in Go or Rust gets you that without
writing a VFS.

**Worse, or unsettled:**
- **How does `sql.check` see `SCHEMA`?** design §6.1 has the compiler
  call `sql.check(parts, holes)` at build time, but the schema is the
  application's top-level `let`, and `std`'s `sql` can't name it. The
  only ways are a global (magic) or a convention (worse). See the ask
  below: let the prefix be a top-level value, `let DB = sql.schema(...)`,
  and write `DB"select ..."`.
- **Two durability domains.** The engine's files are synced by the
  engine and the catalog by SQLite. The order (table fsync, rename,
  dir fsync, *then* the catalog commit, *then* WAL truncation) is the
  program's, and nothing checks it but the crash test in §4. That's
  correct, it's what RocksDB does with its MANIFEST, but it's why a real
  engine usually keeps its manifest as a log of its own. If flottning's
  engine is its own, the catalog is better as a second WAL of `VersionEdit`
  records (program 1's format, a different type), and SQLite is better
  kept for flottning's *application* metadata (users, tokens, buckets).
  design §6.3's question stands; this slice says SQLite is pleasant
  enough that it's not the deciding factor.
- `select *` decoding by name is safe here only because tables are
  `STRICT` and the shape check is by name; a column added later is
  ignored. That's the right default, but it should be stated in sql's
  docs.

**Rules leaned on:** design rule 1 (shape is the only description: rows,
holes, `sql.values`), rule 2 (opaque `parse` runs on `TableId`, `Lsn`,
`Key` from rows), rule 5 (transaction is `over Sql`), rule 7 (SQLite's
I/O is `Fs`), rule 8 (a template is a typed value); handlers.md
`finally` sees `Cancelled`.

---

## 4. The engine as a dependency, and a crash test

**Job:** expose the engine as the `Store` dependency that §3.2 of design
.md routes to; recover on install; then a simulation test that crashes
in the middle of writes, restarts on the same disk, and checks that
every acknowledged write survived.

### Ren: the service

```ren
pub dep Store =
  get: fn(k: Key) -> Option<Bytes> ! IoError | Corrupt(at: Int, why: Str)
  put: fn(k: Key, v: Bytes) -> Lsn ! IoError | DiskFull | Corrupt(..)
  delete: fn(k: Key) -> Lsn ! IoError | DiskFull | Corrupt(..)

handler engine(dir: Path, memtable_max: Int = 64.mb) for Store
    uses Wal, Sql, Fs ! IoError | Corrupt(at: Int, why: Str) | DbDown | SqlRow(..) =
  try sql.migrate(MIGRATIONS)
  try sweep(dir)                                             // orphans from a crash
  var tables = try live_tables()
  var mem: OrderedMap<Key, (Seq, Val)> = OrderedMap.empty
  var mem_bytes = 0
  let from = try checkpoint()
  for r in try Wal.replay(from)                              // assumed: Wal grows a reader of records ≥ lsn
    apply(&mem, &mem_bytes, r)

  get(k) =>
    if mem.get(k) is Some((_, v)) then return v.to_option()
    for t in tables.newest_first().select(fn(t) => t.covers(k))
      if try point_get(t, k) is Some(v) then return v.to_option()   // block index: one block read
    None

  put(k, v) => try write(Put { key: k, value: v })
  delete(k) => try write(Delete(k))

  fn write(op: Op) -> Lsn ! IoError | DiskFull | Corrupt(..) =   // a private helper of the handler (assumed)
    let lsn = try Wal.append(op)
    try release Wal.sync(lsn)                                    // others append while this waits: group commit
    apply(&mem, &mem_bytes, Record { lsn, op })
    if mem_bytes >= memtable_max then
      let meta = try flush(mem, dir / "\{lsn.int()}.sst")       // stalls writers; services stage moves it to the background
      try record_flush(meta, lsn)                                 // only after the file is synced and renamed
      try Wal.truncate_before(lsn)                                // only after the catalog committed
      &tables.push(meta)
      mem = OrderedMap.empty
      mem_bytes = 0
    lsn

pub wiring live(dir: Path) provides Store uses Fs, Clock, Random
    ! IoError | Corrupt(..) | DbDown | SqlRow(..) =
  sqlite.open(dir / "catalog.db"), file_wal(dir / "wal"), engine(dir)
```

The server is design.md §3.2's `routes`, unchanged: it says `uses
Store`, never `Fs`, and an architecture assert keeps it so:

```ren
assert routes.uses <= [Store, Log]          // the request path touches the disk only through the engine
```

### Ren: the crash test

```ren
import sim.{SimFs}

test fn val(i: Int) -> Bytes = "v\{i}".bytes()
test fn k(i: Int) -> Key = Key.parse("k\{i % 64}".bytes()).unwrap()

test "every acknowledged write survives a crash" =
  with sim.fs(torn_writes: true, lose_unsynced: true) in        // seeded from the test's tape
    let dir = Path.of("/data")
    var acked: Map<Key, Bytes> = Map.empty
    // run writers until the disk "loses power" at a step drawn from the tape
    SimFs.crash_at(Random.int(1, 2_000)) fn() =>
      try with live(dir) in
        Async.each(0..8) fn(w) =>                               // 8 writers, interleaved by the seed
          var i = w
          while true
            let lsn = try Store.put(k(i), val(i))
            &acked.set(k(i), val(i))                            // acknowledged: Store.put returned
            i += 8
    // restart: a fresh install on the same disk, unsynced bytes lost, the last sector torn
    try with live(dir) in
      for (key, v) in acked
        assert try Store.get(key) == Some(v)

test "a corrupt block is found, not served" =
  with sim.fs() in
    let dir = Path.of("/data")
    try with live(dir) in
      for i in 0..10_000 => try Store.put(k(i), val(i))
    SimFs.flip_bit(dir / "first.sst", at: 5_000)                // a bit flip at rest
    try with live(dir) in
      assert attempt Store.get(k(0)) is Err(Corrupt(_, "block checksum"))
```

```
$ ren test store --seeds 10000
  ✗ every acknowledged write survives a crash
    seed 7731: k(17) acknowledged with "v4113", read back as None
    rerun: ren test --only "every acknowledged" --seed 7731 --trace
$ ren test --only "every acknowledged" --seed 7731 --trace
  step 1288  w3   Fs.write_at(wal, 98304, 41 bytes)          → ok
  step 1289  w3   Fs.datasync(wal)                           (released)
  step 1290  w5   Fs.write_at(wal, 98345, 41 bytes)          → ok
  step 1291  w3   Fs.datasync(wal)                           → ok   synced := appended (w5's record!)
  step 1292  w5   Wal.sync(lsn 2402)                         → returns: covered
  step 1293  sim  CRASH  (lost: 98345..98386, unsynced)
```

That trace is the bug the `let target = appended` line exists to
prevent: reading `appended` *after* the `release` would mark w5's
record durable when the fsync began before it was written. Without the
line, seed 7731 finds it.

### Twin: Zig (TigerBeetle's VOPR), and what Go and Rust do

TigerBeetle is the only twin with the same capability. The replica is
generic over its storage at compile time, and tests pass a simulated
one:

```zig
pub fn ReplicaType(comptime StateMachine: type, comptime MessageBus: type,
                   comptime Storage: type, comptime AOF: type) type { ... }   // vsr/replica.zig:144

// testing/storage.zig:274 — a crash
pub fn reset(storage: *Storage) void {
    while (storage.writes.pop()) |write| {
        if (storage.prng.chance(storage.options.crash_fault_probability)) {
            const sectors = SectorRange.from_zone(write.zone, write.offset, write.buffer.len);
            storage.fault_sector(write.zone, sectors.random(&storage.prng));
        }
    }
    while (storage.reads.pop()) |_| {}
    storage.next_tick_queue.reset();
}
```

The cluster harness (`testing/cluster.zig`) then restarts the replica on
the same `Storage` and checks invariants. It's ~1,250 lines of simulated
storage plus the harness, written by the database's authors, and every
module that touches the disk takes `comptime Storage: type`.

Go and Rust have no equivalent short of the same work: an `fs`
interface threaded through the engine (Pebble's `vfs.FS` with
`errorfs` and `vfs.NewStrictMem()` for "lose unsynced writes" is the
best of them, and it's real), plus a deterministic scheduler, which
Go doesn't have (goroutines aren't seeded) and Rust gets only from
`madsim`/`turmoil` if every crate cooperates. SQLite inside the same
simulation is out of reach in all three.

### Comparison

| | Ren | Zig (TigerBeetle) | Go (Pebble) |
|---|---|---|---|
| Engine code that knows it's tested | none: `uses Fs` | every disk module: `comptime Storage` | every disk call: `fs vfs.FS` |
| Crash and restart on one disk in one test | `SimFs.crash_at(n) fn() => ...` then a second `with live(dir)` | yes, harness | `StrictMem.ResetToSyncedState()` |
| Interleavings | the seed picks, at every `release` and dependency call | the seed picks (single-threaded by design) | real goroutines, not reproducible |
| SQLite in the same simulation | yes (its VFS is `Fs`) | n/a | no |
| A failure replays | `--seed 7731 --trace` | yes, by seed | no |
| Test lines | ~25 | ~hundreds (harness) | ~60 |

**Better:** this is the slice where Ren is clearly ahead, and it's
because of rule 7 (every input is a dependency read) and decision 10,
not anything stage 12 adds. TigerBeetle got here by designing its whole
codebase around a comptime `Storage`; in Ren the engine says `uses Fs`
and the test installs another `Fs`.

**Unsettled, and the test needs it:** what "crash" means. A cancel runs
`finally`s, and the engine's `finally` would `datasync` the WAL, which
is exactly the clean shutdown a crash isn't. I propose that a crash is
**a cancel plus a disk that detaches**: `SimFs.crash_at(n)` cancels its
block at step `n` (so `finally`s run, under the usual rules, and nothing
new is needed in the language), and from that step the disk ignores
every write and sync from that block's tasks, then drops what wasn't
synced and tears the last sector written, from the tape. That's
TigerBeetle's `reset()` with a page cache in it. It keeps panics,
cancels and `finally` meaning what they mean, and puts the whole fault
model in `sim.fs`.

**Rules leaned on:** language.md §4 and §5 (a `dep`, a `wiring` that
provides only `Store` and hides `Sql` and `Wal`), handler state that can
fail to start (`! Corrupt`), decision 10 and `release`, design rule 7,
testing.md (tests on `sim`, `--seeds`, replay), shapes.md's `f.uses`
assert.

---

## Scorecard

| Program | Ren vs twin | Why |
|---|---|---|
| 1. WAL | better than Go | declared codec, no hand offsets, group commit from decision 10; worse at writing a checksum into an encoded frame |
| 2. Flush + merge | better than Rust on the file, level on the merge | formats and slices beat `to_le_bytes` and key copies; the merge needs `Heap` and a nameable memtable cursor |
| 3. Catalog | better than Go, level with sqlx | rows by name, holes as values, transaction as a handler; how `check` reaches the schema is open |
| 4. Engine + crash | far ahead of Go and Rust, level with TigerBeetle at a fraction of the code | `uses Fs` is the seam; needs `sim.fs` crash semantics defined |

No program needed an exception to a rule. Two needed an API that isn't
specified (Fs handles, `sim.fs` crash), and one needed a language
question answered (how a template's `check` gets the schema).

## What std is missing

In the order flottning would hit them:

1. **`Fs` handles** (design §9, 12b): `open(path, mode, create:,
   truncate:)`, `read_at`, `write_at`, `append`, `size`, `truncate`,
   `sync`, `datasync`, `rename`, `sync_dir`, `list`, `remove`, `lock`.
   Plus **a vectored append**, `Fs.append(f, [a, b])`, or every frame and
   block is copied once to join its header to its body. `Fs.File` should
   be data (an id and an incarnation, streams.md rule 6), so a reader
   that holds one can sit in an `Array`.
2. **`sim.fs` with a defined crash**: `crash_at(step) fn() => ...`,
   `lose_unsynced`, `torn_writes`, `flip_bit(path, at:)`, `full_disk`.
   The proposal above: a crash is a cancel plus a disk that detaches.
3. **`checksum.crc32c` and `xxh3`** before stage 15 (G-C11).
4. **`collections.OrderedMap`** with a range cursor, and **its cursor
   type must be nameable** (`OrderedMap.Cursor<K, V>`), or the merge's
   `Source` sum can't hold it. That's streams.md's open `walk.Cursor`
   naming question, and the engine is the program that needs it.
5. **`collections.Heap`** (a loser tree is a nice-to-have).
6. **A format append to a growing buffer**: `T.fmt.append(&out: Bytes, v)`.
   formats.md has `write(&buf[a..b], v)` into a range sized beforehand and
   `encode(v)` into a new buffer; building a 4 KB block of entries wants
   neither. Note that design §2's `json.write(&out, x)` *appends*, while
   formats.md's `write` fills a range: one name, two meanings. Rename
   one; I'd make both `append` and keep `write` for ranges.
7. **A view's consumed size**, `v.size()` or `v.end`, so recovery doesn't
   compute `rest.len() - v.rest.len()`.
8. **`Wal.replay(from)`**: a reader of records from an lsn, which is
   program 1's `recover` turned into streams.md's second form (a reader
   you keep). It's an engine type, not std, but it's the pattern std's
   docs should show.
9. **Background work** (`Async.background`, services stage) for flush
   and compaction. Inline, a flush stalls every writer for its whole
   duration, because the handler instance is held (decision 10).
10. **`snapshot`** (11b) for reads that don't wait behind a flush.

## Where the design felt magic or verbose

**Verbose:**
- **Writing a checksum into a frame** takes an `edit` block with a `try`
  that can't fail. Suggest: `edit` on bytes that `encode` just returned
  is known valid, so let `T.fmt.encode(v) fn(&h) => h.crc = ...` take a
  block and skip the check. That's not checksum syntax (formats.md left
  that out), just "encode, then edit" as one call.
- **Format-only types** (`Frame`, `BlockTrailer`, `IndexEntry`,
  `Footer`): a type line each that mirrors its format. Acceptable.
- **Turning `FormatError` into the engine's `Corrupt`** takes a `match`
  at each `view` (I wrote `map_err corrupt`). Ren has no error mapping
  besides `match`. Either the engine lets `FormatError`'s tags through
  its rows (they carry `at`, which is all `Corrupt` adds), which is what
  I'd do, or this is a real recurring cost. Worth a look at errors.md.
- **Helpers that mutate several locals** (`seal`) want a record with
  `inout self` methods, as in Rust; local blocks can't be called twice
  while writing captures. Correct, but the first draft hit it.

**Magic, or close to it:**
- **`sql.check` finding the application's schema** (§3): no way without
  a global. Ask: allow the template prefix to be a **top-level value**,
  `let DB = sql.schema(SCHEMA)`, `DB"select ..."` calling
  `DB.template(t)` and `DB.check(...)`. That's explicit, and it also
  answers "which database is this query for" when there are two.
- **`len` in a frame "counting the rest"**: formats.md's `PgMessage`
  says `len: UInt32 // counts itself` and fills it in on write, but
  doesn't say how the compiler knows which bytes a length covers when
  no field is sized by it. I avoided it with `body: Bytes[len]` in a
  `Frame` envelope. formats.md should say: a length is only ever the
  size of a field written after it, and "the rest of the frame" is
  spelled as a field.
- **"`at` is for reports, never for indexing"** is right, but recovery
  is the one program whose report *is* its next action (truncate at the
  torn record). It works because the view was made with `from: pos`. The
  doc could say so: when you made the view with `from:` the file
  offset, the error's `at` is the file offset.

**Not magic, and it should be said so:** group commit falling out of
decision 10 plus one `release`, and transactions rolling back on a
drain-deadline cancel. Both are things engines usually get wrong and
here are the defaults.

## Asks for design.md

1. Put **`sim.fs` crash semantics** in 12b's spec: a crash is a cancel
   plus a detached disk (§4 above).
2. Let a **template prefix be a top-level value** so `check` can see a
   schema (§6.1).
3. Add **`T.fmt.append(&out, v)`**, and make `json.write` and the format
   name agree (§2, formats.md).
4. Name the **cursor types** of std collections (`OrderedMap.Cursor<K,
   V>`) in 12b, since an engine's merge is a sum of them.
5. Add **vectored `Fs.append`** to the `Fs` handle list.
6. On §6.3's question: the engine's own manifest should be its own log;
   SQLite is pleasant enough (and simulatable) to keep for flottning's
   application metadata, but not as the engine's manifest.

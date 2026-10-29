# Alternatives 2: generator cursors — copying, storing, and when cleanup runs

The question: a `gen fn`'s cursor may hold frame state (a leftover chunk, a
framing buffer), resource ids, a `finally` that calls dependencies, or a
`with` it yields inside. What is that cursor allowed to be?

This file works out the draft's position and three alternatives (A, B, C),
each written against the same four programs, and then recommends a fourth
(**R**), which is A with its trigger moved into the signature, plus B's
rules for library cursors over resources.

The four programs:

1. **tail-log:** `follow(path)` tails a file. A `break` stops it, and a
   named cursor resumes after a `break` (programs/01).
2. **pg-framing:** `messages(conn)` frames `PgMessage.wire` over socket
   chunks, with a leftover buffer across `yield` (programs/02).
3. **rows-in-tx:** a reusable "orders of a customer, read in one
   transaction" stream (programs/07).
4. **tree-walk copied mid-walk:** a pure `walk(t)` and a directory
   `walk_dir(p)` that holds one handle per level. Both are copied halfway
   through (programs/05).

Each option answers the same seven questions:

- **Q1** Does a `finally` run twice on copies?
- **Q2** What about a uniqueness check hoisted across a `yield` (`bumped`,
  probe-soundness §4)?
- **Q3** What does `break` do on a named cursor and on a temporary?
- **Q4** What does cancelling a `next` mid-step do?
- **Q5** What happens to a cursor that escapes the `with` that installed its
  dependency?
- **Q6** What is the gen cursor's type called?
- **Q7** What does the interpreter need: one-shot fibers or a state machine?

---

## Draft (streams.md as written)

**Position.** Every gen cursor is a value: it can be copied, stored,
returned, and given to a task. A `finally` runs at the end of a loop, at a
drop, or on cancel, and it may call dependencies. `yield` is banned inside
`with`. A resource's state belongs to its service, and "only ids and
offsets in the cursor".

The four programs are already written to the draft in programs/01, 02, 05
and 07. What breaks:

| Q | Draft's answer | Problem |
|---|---|---|
| Q1 | Copies share nothing, so `let h = g`, both stepped, both dropped, runs `f.close()` twice | **breaks**: a double close, or a read on an fd the OS has reused (01 item 5, 05 item 3) |
| Q2 | "Copies like any value" | **breaks**: `bumped` writes through a pointer hoisted into the copy's buffer |
| Q3 | "Ends a loop by `break`" (line 297) and "`r` stays where it stopped" (line 88) | **contradiction** for a `var`-bound cursor |
| Q4 | Unspecified | |
| Q5 | `let rows = with tx in Sql.rows(q)` compiles, and `next` runs on the pool after commit | **hole** (07 D) |
| Q6 | Unnamed | 09's `Map<ClientId, ???>` can't be written |
| Q7 | Copyable started frames | rules out one-shot fibers, so it needs a Core state machine (1.5–2.5k lines, high risk) |

There's also the cleanup point. A drop-time `finally` that calls `Fs` is a
close when a count reaches zero (decision 11). It lands where Perceus
places it, so the journal moves with the optimizer. It may suspend inside
a function decision 12 gives no frame, and it has no error channel. It
also runs in contexts that can't call dependencies at all: an arena's end
pass, `snapshot` reclaim, and `isolate`'s leak.

And `pg-framing`'s `buf` violates "only ids and offsets in the cursor"
with nothing to stop it: two copies of a framer emit the same leftover
bytes, then read disjoint chunks.

**Verdict: unsound as written.** Every alternative below drops drop-time
effectful `finally`.

---

## Option A: split by what the body does

**Rule.** A generator gets a **scoped, block-kind cursor** if its body does
any of the following:

- (a) has a `finally` that uses a dependency;
- (b) yields inside a `with`;
- (c) keeps resource state in its frame across a `yield`.

A scoped cursor can't be copied, stored, returned, or captured by a spawn,
the same restrictions rule D puts on blocks. Its `finally` runs at points
the syntax fixes:

- the end of a `for` over a temporary;
- the end of the scope of the `var` that binds it;
- a cancel unwind.

In each case it sees `Err(Cancelled)` if the generator didn't finish.
Every other generator is a storable value.

### Programs

```ren
// 1. tail-log: trigger (a), so scoped
gen fn follow(path: Path) -> Str uses Fs, Clock ! FsError =
  let f = try Fs.open(path)
  finally f.close()                   // runs at a syntactic point, never at a drop
  var at = try f.size()
  var partial = ""
  while true
    let chunk = try f.read_at(at, 64 * 1024)
    if chunk.len() == 0 then Clock.sleep(Duration.ms(200))
    else
      at += chunk.len()
      let lines = (partial ++ chunk.str()).split("\n")
      for line in lines[0 .. lines.len() - 1]
        yield line
      partial = lines[lines.len() - 1]

fn sections(path: Path) uses Fs, Clock, Console ! FsError | BadLine =
  var r = follow(path)
  for line in try &r
    if line == "--- boot ---" then break      // r stays suspended
  for e in try &r.map(parse).select(fn(e) => e.level == Error)   // the pipeline holds &r
    Console.print(e.msg)
  // f.close() runs here, at the end of r's scope, with Err(Cancelled)

// 2. pg-framing: trigger (c)? The frame keeps `buf`, a slice of leased chunks
gen fn messages(conn: Conn) -> PgMessage uses Net ! NetError | FormatError | Truncated =
  var chunks = Net.chunks(conn)
  var buf = Bytes.empty()
  ...                                         // as in programs/02
// Is `buf` "resource state"? Only a taint analysis can tell: it was derived
// from a value that a dependency returned. Without (c), this generator is
// storable, and a copy duplicates frames.

// 3. rows-in-tx: trigger (b), so scoped, and now allowed
gen fn orders_in_tx(c: CustomerId) -> Order uses Sql ! DbDown | Conflict | BadRow =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try &Sql.rows(q, c)
      yield try Order.from_row(row)

for o in try &orders_in_tx(c)
  if o.total > limit then break       // the transaction's finally sees Err(Cancelled): rollback
  try w.write_line(o.csv())

// 4. tree-walk
gen fn walk(t: Tree) -> Node =                 // no trigger: storable
  yield t.node
  for c in t.children
    yield from walk(c)

var w = walk(tree)
let _ = w.next(); let _ = w.next()
var w2 = w                                     // a real fork
// walk_dir has `finally d.close()`, trigger (a), so it's scoped:
var d = walk_dir(root)
var d2 = d                                     // error: `walk_dir` closes a handle in its
                                               // `finally`, so its cursor can't be copied
```

### Answers

| Q | A's answer |
|---|---|
| Q1 | Scoped cursors can't be copied. A storable generator's `finally` is pure by construction, so running it twice is harmless. |
| Q2 | Scoped cursors are never copied, so the hoist stays. Storable ones still need a check on resume (below). |
| Q3 | On a temporary, `break` runs `finally`. On a `var`, the cursor stays suspended and `finally` runs at the end of the `var`'s scope. |
| Q4 | The unwind passes through the generator's frame, which is on the stack during `next`. `finally` runs with `Err(Cancelled)`, and later `next`s give `None`. |
| Q5 | A scoped cursor can't be returned, so it can't leave a `with`. A storable one still can, and nothing stops a library cursor (`Sql.rows`). |
| Q6 | Not answered by A. It needs one of the namings below. |
| Q7 | Scoped generators can use fibers. Storable ones still need copyable frames, so a state machine. |

### Assessment

- **Sound** for (a) and (b).
- **(c) can't be decided** in one walk. "Resource state" is a dataflow
  fact: `buf` derived from `c` derived from `Net.chunks`. Without (c),
  `pg-framing`'s copy hazard stays.
- **The kind is found behind your back.** Adding a `finally d.close()` to
  a public generator silently turns its cursor scoped. That breaks a
  caller's `Map<K, WalkDir>` in another module. The kind has to be
  written at the boundary, which means a new marker (`scoped gen fn`), a
  second mechanism next to `uses`.
- **Cost:**
  - typing, plus the kind on type variables, which pipelines need anyway;
  - fibers for scoped generators;
  - a state machine for the rest.

---

## Option B: every generator stays storable; resource state moves into the service

**Rule.** Every gen cursor is a value. A generator's `finally` can't call
dependencies. Resource state goes into the service:

- **Handles.** `Fs.open`, `Fs.open_dir` and `Net` connections register
  with the handler instance. That instance closes what's still open when
  its `with` ends, and there's an explicit `Fs.close(f)`.
- **Framing and line splitting.** These live in the service, keyed by the
  connection id: `Net.frames(conn, PgMessage.wire)`, `Fs.lines(f)`, and
  peek and consume on a connection.
- **Incarnations.** Every id carries its instance's incarnation, as
  decision 18's journal names actors. Using an id with another instance,
  or after its `with` ended, fails with a typed `Closed` or `Stale`.
- **`yield` stays banned inside `with`**, since a stored cursor would hold
  an instance.

### Programs

```ren
// 1. tail-log: the frame is all data, and pread makes a copy an honest fork
gen fn follow(f: Fs.File) -> Str uses Fs, Clock ! FsError | Closed =
  var at = try f.size()
  var partial = ""
  while true
    let chunk = try f.read_at(at, 64 * 1024)
    ...                                       // as before, with no finally
// No finally can close the file, so the caller owns it:
fn sections(path: Path) uses Fs, Clock, Console ! FsError | BadLine | Closed =
  let f = try Fs.open(path)
  finally f.close()                           // the caller's ordinary finally
  var r = follow(f)
  for line in try &r
    if line == "--- boot ---" then break
  for e in try &r.map(parse).select(fn(e) => e.level == Error)
    Console.print(e.msg)

// For a temporary, the "cleanup when the consumer stops" property is lost:
for e in try &follow(try Fs.open(path)).take(100)   // fd leaks until Fs's `with` ends
  ...

// 2. pg-framing: no user framer; the service frames
for msg in try &Net.frames(conn, PgMessage.wire)    // the buffer lives under conn's id
  match msg ...
// A user can still write programs/02's framer with `buf` in the frame.
// B can't forbid it, so a copy still duplicates leftovers. It's documented, not checked.

// 3. rows-in-tx: still impossible as a generator; the library writes C1
pub fn each_order(c: CustomerId, body: fn(o: Order) -> Flow uses Sql)
    ! DbDown | Conflict | BadRow uses Sql =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try &Sql.rows(q, c)
      match body(try Order.from_row(row))
        Go => ()
        Stop => break
// And 07 D: `let rows = with tx in Sql.rows(q)` compiles, then the first next fails with Closed.

// 4. tree-walk: walk forks. walk_dir can't close per level, so it reads each level eagerly
gen fn walk_dir(p: Path) -> Entry uses Fs ! FsError =
  let entries = try Fs.read_dir(p)            // Go's os.ReadDir: no handle across a yield
  for e in entries
    yield e
    if e.dir then yield from walk_dir(e.path)
var d = walk_dir(root); let _ = d.next()
var d2 = d                                     // a fork: two independent walks
```

### Answers

| Q | B's answer |
|---|---|
| Q1 | A `finally` is pure, so running it twice is harmless. The service closes each id once. |
| Q2 | Every cursor can be copied, so the uniqueness of each `&` held across a `yield` is re-checked on resume (one compare per `next`). |
| Q3 | `break` leaves both kinds of cursor suspended. Nothing is cleaned up on `break` beyond the generator's pure `finally`. |
| Q4 | Service operations are already cancel-safe (async.md), so a library cursor stays valid. A gen frame cancelled mid-step is poisoned: `None`. |
| Q5 | Caught at run time by the incarnation (`Closed`/`Stale`). It isn't caught statically. |
| Q6 | It has to name every generator: one nominal type per `gen fn`. |
| Q7 | A state machine for every generator, because every one is copyable. That's 1.5–2.5k lines before 11c ships anything. |

### Assessment

- **Sound for library cursors.** User generators that buffer over a
  socket keep the duplicate-frame hazard, which B documents but can't
  check.
- **It gives up the draft's property 2, "cleanup exactly when the
  consumer stops".** A temporary over an opened file leaks until the
  `with` ends. A long-lived server's `Fs` `with` is the process.
- **`rows-in-tx` stays impossible as a generator.**
- **The service grows.** Each service gets a registry, framing state and
  incarnation checks.
- **Ethos.** It fits "state in the service" well, but it pushes cleanup
  back onto the consumer's `finally`. That's honest, but it's Java's
  `Files.lines`-without-try-with-resources bug, which the draft cites as
  a reason for the design.

---

## Option C: affine generators

**Rule.** A gen cursor is moved, never implicitly copied. `fork()` is
offered only on array and `pread` cursors. A `finally` runs when the
unique owner ends: the end of the `for` over a temporary, the end of a
binding's scope, or a move into a consumer that then ends.

### Programs

```ren
// 1. tail-log
var r = follow(path)
for line in try &r
  if line == "--- boot ---" then break
let errors = r.map(parse)                 // moves r into the pipeline; r is gone
// Stored in a record: type Job = { id: Int, src: Follow }  (Job is now affine too)
fn retire(jobs: Array<Job>, id: Int) -> Array<Job> =
  jobs.reject(fn(j) => j.id == id)        // drops j.src: runs Fs.close inside a pure fn
                                          // error, or close at drop again

// 2. pg-framing: a move-only framer can't be duplicated, so `buf` is safe
var m = messages(conn)
var m2 = m                                 // error: `m` was moved; use `m` or write `fork()`

// 3. rows-in-tx: an affine cursor can still be moved into a record and stored,
// so yielding inside `with` would hold an instance in a stored value. Still banned. C1 again.

// 4. tree-walk
var w = walk(tree); let _ = w.next()
var w2 = w                                 // moves; w is unusable
var w3 = w2.fork()                         // error: fork() is for arrays and pread readers
// The pure walk loses its honest fork, which costs nothing to give.
```

### Answers

| Q | C's answer |
|---|---|
| Q1 | No copies, so a `finally` runs once. But a stored affine cursor dropped in pure code still runs an effectful `finally` at a drop, so the drop rule still needs a fix. |
| Q2 | No copies, so the hoist is fine. |
| Q3 | On a temporary, the `finally` runs at the loop's end. A named cursor stays suspended until its owner ends. |
| Q4 | Same as A. |
| Q5 | A cursor can still be moved out of a `with`, so C needs decision 7's rule or incarnations. |
| Q6 | Nominal per generator. |
| Q7 | One-shot fibers are enough, since nothing is copied. |

### Assessment

- **It contradicts a signed rejection.** foundations.md, "What it isn't":
  "Rejected after research: … linear and unique types".
- **Affinity infects containers.** A record, `Array` or `Map` holding a
  cursor becomes affine. Every generic function then has to be generic
  over copyability, as Swift's `~Copyable` is, which took years to
  retrofit.
- **It doesn't fix drop-time cleanup on its own**, as the `retire` example
  shows.
- **It doesn't make yielding inside `with` possible.**
- **Cost:** high in sema, cheap in the interpreter.
- **Ethos.** A second kind of value semantics is the "clever" Ren
  disowns.

---

## R (recommended): a generator that suspends is a frame; a resource is an id

R takes A's split, but moves the trigger from the body to the
**signature**, onto the line decision 12 already draws: "Only a function
whose `uses` reaches a dependency can suspend." It then adds B's rules for
the library's own cursors over resources.

> **A `gen fn` whose `uses` is empty and whose parameters are values gives
> a value cursor. Any other `gen fn`, one that uses a dependency or takes
> a block or an `&` parameter, gives a frame cursor, which is block-kind.**

That's the bet table's own row: "A suspended frame | its task, in memory
the scope already owns." A frame cursor lives in the scope that created
it, in the task's frame allocator, and dies with that scope. A value
cursor is data, and data flows anywhere.

### What a frame cursor can and can't do

| Can | Can't |
|---|---|
| be bound once with `var` at the call that makes it | be copied (`let h = g`), as a `let` binds one block |
| be a `for`'s source, and resume after a `break` | be stored, returned, or the value of a `with` body |
| be passed down as `&g`, including to `C has next` | be captured by `s.spawn`, or passed to a handler operation |
| be the receiver of a pipeline, zipped, merged | be marked shared or crossed between tasks |

- **Cleanup runs at points the syntax fixes, never at a drop.**
  - When a `for` over a temporary ends, or at the end of the statement that
    consumes it (`.to_array()`).
  - At the end of the scope of the `var` that binds the cursor, in reverse
    order of creation, as nested `with`s end.
  - On a cancel unwind.

  Every one is an unwind: it's shielded, it falls under the cleanup
  deadline, and it runs in the consumer's row. A `finally(r)` sees `Ok`
  if the generator returned, `Err(e)` if it failed, and `Err(Cancelled)`
  if it was abandoned or cancelled. So a transaction rolls back on
  `break`, as C#'s dispose without commit and Go's `defer tx.Rollback()`
  do. The journal position is the same in debug and release, since
  Perceus never decides it.
- **Dependencies are found where the cursor is made** (decision 5,
  applied to frames). The frame keeps the evidence of its creation site,
  and that site outlives it. So `var g = lines(p)` followed by
  `with fake_fs() in for l in &g` still reads the real `Fs`. A frame
  never mixes instances.
- **`yield` inside a `with` is allowed.** The frame holds the instance,
  but it's scoped exactly as the `with` itself is, so the bet's "never
  hold an instance as a value" isn't touched.
- **`yield` is not allowed inside a block** (`fn` literal), and so not
  inside `Async.scope`, `timeout`, `race`, `beside`, `retry`, `isolate`,
  `Docs.at`/`each` or `snapshot.read`, which all take blocks. It's also
  not allowed inside a `finally`. One rule replaces the list
  (probe-soundness §7).
- **What falls out.** A frame gen fn may take blocks and `&` parameters,
  since its cursor is block-kind. That's the draft's own rule, "a value
  that holds a block is a block". So `merge_by(&a, &b, fn(e) => e.at)`
  and a user's `dedup_by` (09 step 6, 04 use 3) become writable. The `&`
  lasts the scope of the cursor's binding. That's one new interval row in
  decision 2's table.

### What a value cursor is

A value cursor is pure: no `uses`, value parameters only. A copy is an
honest fork. Its `finally` can't be observed, so it's allowed and never
matters, and Perceus frees it like any value. The one rule it needs
(probe §4): **each `&` held across a `yield` re-checks uniqueness on
resume**. That's one compare per held `&` per `next`, and the hoist inside
the loop body between yields stays.

### Library cursors over resources (B's half)

`Net.chunks(conn)`, `Sql.rows(q)`, `Fs.line_reader(f)` and
`listener.connections()` are records the service defines: an id and an
offset, with a `next` method that uses the service. They're values, so
09 can store a reader per client. Three of B's rules apply to them:

- **Ids carry their instance's incarnation.** Use on another instance, or
  after the `with` ended, fails with `Closed` (in each `next`'s row).
- **A `with` body's value can't be a cursor type of a dependency that the
  `with` installs.** That's decision 7's rule for tasks, given to values.
  It's checked from the type (`Sql.Rows` belongs to `Sql`), so 07 D is a
  compile error, and the incarnation is the run-time backstop for what
  hides in a generic.
- **Handles register with their handler,** which closes leftovers at its
  `with`'s end. This is the backstop for a stored reader nobody closed. A
  generator's own handles are closed by its `finally` at the points above.

`Net.frames(conn, fmt)` is still worth shipping, but for cost, not
soundness. It reads `Short.need` into one buffer allocated once, so it
avoids the quadratic `buf ++ c` (02 item 2). Under R, a user's framer with
`buf` in its frame is sound, because its cursor can't be copied.

### Programs under R

```ren
// 1. tail-log. follow uses Fs and Clock, so it's a frame.
gen fn follow(path: Path) -> Str uses Fs, Clock ! FsError =
  let f = try Fs.open(path)
  finally f.close()                         // at a syntactic point, once
  var at = try f.size()
  var partial = ""
  while true
    let chunk = try f.read_at(at, 64 * 1024)
    if chunk.len() == 0 then Clock.sleep(Duration.ms(200))
    else
      at += chunk.len()
      let lines = (partial ++ chunk.str()).split("\n")
      for line in lines[0 .. lines.len() - 1]
        yield line
      partial = lines[lines.len() - 1]

fn first_errors(path: Path) -> Array<Entry> uses Fs, Clock ! FsError | BadLine =
  try follow(path).map(parse).select(fn(e) => e.level == Error).take(100).to_array()
  // a temporary: f.close() runs at the end of this statement, after the 100th

fn sections(path: Path) uses Fs, Clock, Console ! FsError | BadLine =
  var r = follow(path)
  for line in try &r
    if line == "--- boot ---" then break    // r stays suspended; nothing closes
  for e in try &r.map(parse).select(fn(e) => e.level == Error)  // the pipeline holds &r
    Console.print(e.msg)
  // r's scope ends: f.close() runs here, with Err(Cancelled), after every print

var r2 = r                                  // error: `follow` uses Fs, so its cursor is a
                                            //   frame and can't be copied
                                            // help: pass it down as `&r`, or store the reader
                                            //   (`Fs.line_reader(f)`), which is data

// Kept per client (09) with the state on the page, as data:
type Tail = { file: Fs.File, at: Int, partial: Str }
  pub fn next(inout self) -> Option<Str> uses Fs, Clock ! FsError | Closed = ...
handler paged(path: Path) for Pages uses Fs, Clock =
  var open: Map<ClientId, Tail> = Map.empty  // a value: a copy forks honestly (pread)
  ...

// 2. pg-framing. messages uses Net, so it's a frame: `buf` can't be duplicated.
gen fn messages(conn: Conn) -> PgMessage uses Net ! NetError | FormatError | Truncated =
  for m in try &Net.frames(conn, PgMessage.wire)   // the library framer; or programs/02's loop
    yield m.value                                  // both are sound under R

fn session(conn: Conn) uses Net, Db ! NetError | FormatError | Truncated | DbDown =
  for msg in try &messages(conn)            // a temporary: pushed, no frame object
    match msg
      Query(sql) => try reply(conn, try Db.query(sql))
      Terminate => break
      ...

// 3. rows-in-tx. Yield inside `with`: a frame, and now legal.
pub gen fn orders_in_tx(c: CustomerId) -> Order uses Sql ! DbDown | Conflict | BadRow =
  try with sql.transaction(isolation: RepeatableRead) over Sql in
    for row in try &Sql.rows(q, c)
      yield try Order.from_row(row)
  // the transaction commits when the loop finishes; break or failure gives Err(..): rollback

// The consumer, with break. Its own Sql calls are its own (decision 5),
// so they're outside the transaction, as in C# and Go:
for o in try &orders_in_tx(c)
  if o.total > limit then break             // rollback, shielded
  try w.write_line(o.csv())
// To write inside the transaction, the consumer owns the `with` (07 version A).

let rows = try with sql.transaction() over Sql in Sql.rows(q, c)
// error: `Sql.Rows` reads through the `Sql` this `with` installs, so it can't leave it
// help: loop inside the `with`, or return what you read

// 4. tree-walk copied mid-walk
gen fn walk(t: Tree) -> Node =              // pure: a value cursor
  yield t.node
  for c in t.children
    yield from walk(c)

var w = walk(tree)
let _ = w.next(); let _ = w.next()
var w2 = w                                  // an honest fork: both continue independently
let ahead = w2.take(5).to_array()           // lookahead without disturbing w

gen fn walk_dir(p: Path) -> Entry uses Fs ! FsError =   // a frame
  let d = try Fs.open_dir(p)
  finally d.close()
  for e in try &d.entries()
    yield e
    if e.dir then yield from try walk_dir(e.path)       // `try` marks the delegated failure

fn big_files(root: Path) -> Array<Entry> uses Fs ! FsError =
  try walk_dir(root).select(fn(e) => not e.dir && e.size > 1_000_000).take(10).to_array()
  // at the statement's end, every open level closes, innermost first

var d = walk_dir(root); let _ = d.next()
var d2 = d                                  // error: a frame can't be copied
                                            // help: collect what you need, or walk a listing
                                            //   (`Fs.tree(root)`), which is data
```

### Answers

| Q | R's answer |
|---|---|
| Q1 | Can't happen. A frame isn't copied, and a value cursor's `finally` has no effects. |
| Q2 | For frames, there's nothing to check: never copied, so the hoist stays. For value cursors, re-check each held `&` on resume, one compare per `next`. |
| Q3 | On a temporary, `break` ends the producer and runs its `finally` as an unwind (`Err(Cancelled)`). On a `var`, `break` leaves it suspended; `finally` runs at the end of the `var`'s scope. The contradiction is gone. |
| Q4 | The cancel unwinds through the generator's frame, which is on the stack during `next`. Its `finally` runs with `Err(Cancelled)`, the cursor is done, and later `next`s give `None`. For deadlines, a service cursor's `next(within:)` is cancel-safe, as every operation is (async.md). |
| Q5 | A frame can't leave its scope. A library cursor can't be a `with` body's value for the dependency it reads (static), and its id's incarnation catches the rest (`Closed`). |
| Q6 | Nominal per gen fn, written with the function's path: `walk.Cursor`, `follow.Cursor`. Only value cursors appear in fields. A frame's type appears only as `&follow.Cursor` or behind `C has next`. A choice between two value generators is an ADT, or a third value generator with `yield from`, kept unboxed when it isn't recursive. |
| Q7 | Frames: one-shot fibers, about 300 lines. They're never copied, and their evidence is fixed at creation, as a block's env is. Value cursors are pure, so a copy can be **replayed**: start a fresh fiber from the arguments and skip `k` items. That's deterministic, since nothing it does is observable, and about 100–150 more lines. So 11c ships without the 1.5–2.5k-line Core state machine. |

What R needs natively:

- **Frames:**
  - pushed when consumed directly (Go's rewrite);
  - otherwise a frame in the task's bump allocator. It's LIFO-safe because
    it can't outlive its scope.
  - `yield from` children of a pulled frame go in the generator's own
    segment.
  - There's no COW, no rebase, and no relative addressing, which removes
    that implementation rule from the draft entirely.
- **Value cursors:** the Mem state machine after Perceus (1.2–2k lines).
  It's simpler than the draft's, because a pure frame never suspends
  inside `next` and has no effectful cleanup.

### Soundness under foundations.md

- **Decision 11** holds: nothing closes at a count. The drop rule is gone.
- **Decision 12** holds: suspension follows `uses`, and only scoped frames
  suspend across `next`.
- **Decision 2:** frames add rule D's restrictions and one interval ("`&`
  given to a frame gen fn: write, the cursor's scope"). Value cursors add
  the resume re-check.
- **Decision 5** extends to frames: dependencies are found where the
  frame is created.
- **Decision 7:** "a task can't reach a handler installed inside its
  scope" gains its value counterpart.
- **Decision 10:** a frame can't be passed to an operation, as a block
  can't, so a frame whose `next` calls back into the actor can't reach
  it.
- **The bet:** "a suspended frame lives in memory the scope already owns"
  is now literally what a suspending generator is.

### Cost

- **Compiler work:**
  - the frame-or-value kind, inferred from the signature;
  - the frame kind on type variables, which pipelines need anyway (probe
    F3 and B3), so it's shared;
  - the syntactic cleanup points;
  - the with-escape check;
  - the resume re-check for value cursors;
  - fibers and replay in the interpreter.

  Net, it's **smaller than the draft's**, which needs the state machine
  and relative addressing for every generator.
- **Runtime:** a frame consumed by a `for` allocates nothing (push), and
  otherwise one bump allocation. A value cursor costs a state machine, and
  one compare per held `&` per `next`.

### How it reads, and the ethos

- **Visible at the boundary.** A generator's kind is in the line every
  public function already writes: `uses Fs` means it suspends, so it's a
  frame. Nothing about the body changes a caller's code.
- **One mechanism per question.** "Can this be kept?" is answered by the
  block rule for both pipelines and suspending generators. "Who cleans up
  a resource?" is answered by `finally` at a syntactic point, with the
  service as backstop. "Can I store a stream over a resource?" is
  answered by: store its state as data, an id and an offset, which is
  "model with data".
- **Nothing behind your back.** No cleanup at an optimizer-chosen drop,
  no dependency rebinding at resume, and no silent frame duplication.
- **The obvious way is the fast way.** `for x in try &gen(...)` is pushed
  and allocates nothing. Writing the framer by hand is now sound, though
  `Net.frames` stays the fast one.

### What it gives up, said plainly

- **A generator that uses a dependency can't be stored, returned or
  handed to a task.** To keep one, you keep its state: a library cursor
  (an id and an offset) or a record with a `next` method. That's real
  friction for 09's "page through a tail per client" (shown above, about
  ten lines). It's also the line the bet already draws for instances.
- **"One kind of stream" bends.** Frame versus value shows up in errors.
  The draft already splits on `uses` for suspension, so it's the same
  split in a second place, not a new one. streams.md's table row should
  say so.
- **A started frame can't be forked.** A directory walk can't be copied
  halfway (Rust's `ReadDir` isn't `Clone` either). A pure walk can.

---

## Summary

| | Draft | A (body triggers) | B (all storable) | C (affine) | **R** |
|---|---|---|---|---|---|
| Sound under foundations.md | no (decisions 11, 12, 2) | yes for (a) and (b); (c) undecidable | for library cursors; user framers still duplicate | not without a drop fix; contradicts the rejection of unique types | **yes** |
| Q1 double `finally` | yes | no | harmless (pure) | no | **no** |
| Q2 hoist | broken | re-check for storable | re-check everywhere | fine | **re-check for value cursors only** |
| Q3 `break` | contradictory | temporary ends; `var` at scope end | nothing closes | temporary ends; owner ends | **temporary ends; `var` at scope end** |
| Q4 cancel mid-step | unspecified | done, `None` | service cursors safe, gen frames poisoned | done | **done, `None`; `next(within:)` on service cursors** |
| Q5 escape `with` | hole | partial | run time | needs a rule | **static, plus incarnation** |
| Q6 type | unnamed | unnamed | per gen fn | per gen fn | **`walk.Cursor`, written only for values** |
| Q7 interpreter | state machine (1.5–2.5k) | both | state machine | fibers | **fibers plus replay (about 450)** |
| `rows-in-tx` as a generator | refused | yes | refused | refused | **yes** |
| Cleanup when the consumer stops | promised, unsound | yes | lost | yes | **yes** |
| Kind visible at the boundary | n/a | needs a marker | n/a | type | **`uses`, already written** |

**Recommend R.** Changes to streams.md:

- **Producers:** a generator is a frame when it uses a dependency or
  takes a block or `&`, and a value otherwise.
- **Cleanup:** only at syntactic points, with the cause given to
  `finally(r)`. Delete the drop bullet and the "`finally` at a drop can
  call dependencies" paragraph.
- **Blocks inside a generator's frame:** drop relative addressing for
  frames. For value cursors, keep it and add the resume re-check.
- **Concurrency:**
  - replace the `yield` list with "not inside a block or `finally`";
  - allow `with`;
  - make dependencies found where a frame is made.
- **Cursors over resources:**
  - incarnations on ids;
  - the with-escape rule;
  - handles registered with their handler;
  - `Net.frames` for cost;
  - fix the RFC 3550 citation (its lesson is that copyable iterators are
    the hazard).
- **Left out:** "affine or unique cursors" stays out. Frames are
  block-kind, not affine.

**Decisions for the owner:**

1. **The trigger.** Should the trigger be `uses` plus block or `&`
   parameters (R), or an explicit `scoped gen fn` marker? R's is already
   written on every public signature. A marker would let a pure generator
   choose to be scoped, which nothing needs yet.
2. **What abandonment looks like.** Is it `Err(Cancelled)` in
   `finally(r)`, or a distinct `Stopped`? `Cancelled` gives rollback for
   free, but stretches "cancellation" to cover a `break`.
3. **Cancel mid-step.** Should a later `next` give `None` (Kotlin's
   choice), or a typed `Ended` in its row (louder, and every row grows)?
4. **Blocks in frame generators.** Should frame gen fns take blocks and
   `&` parameters now (user-written lazy stages, `merge_by`), or later?
   It falls out of the rule, but it widens decision 2's table by one row.
5. **Replay versus a state machine.** Should the interpreter copy value
   cursors by replay in 11c, deferring the Core state machine until a
   measurement asks for it?

# 1. Tail a log: `select`, `take(100)`, cleanup on `break`

Follow a growing log file (`tail -f`), parse each line, keep only errors,
stop after 100 of them, and make sure the file is closed the moment we
stop. A second variant stops on a condition with `break` and then
resumes from where it stopped.

## Ren, per the draft

```ren
type Entry = { at: Time, level: Level, msg: Str }
type Level = | Debug | Info | Warn | Error

fn parse(line: Str) -> Entry ! BadLine = ...

// The producer. Real control flow (wait at EOF, carry a partial line),
// so a `gen fn`, not a pipeline.
gen fn follow(path: Path) -> Str uses Fs, Clock ! FsError =
  let f = try Fs.open(path)
  finally f.close()                          // (1) can `close` fail? who sees it at a drop?
  var at = try f.size()                      // start at the end, like tail -f
  var partial = ""
  while true
    let chunk = try f.read_at(at, 64 * 1024) // pread: the offset is ours, data (§Cursors over resources)
    if chunk.len() == 0 then
      Clock.sleep(Duration.ms(200))          // suspends: `follow`'s `uses` reaches Clock
    else
      at += chunk.len()
      let text = partial ++ chunk.str()      // copies the carry; unavoidable
      let lines = text.split("\n")
      for line in lines[0 .. lines.len() - 1]
        yield line                           // a slice of `text`: no copy
      partial = lines[lines.len() - 1]

// The consumer: the pipeline you'd write first.
fn first_errors(path: Path) -> Array<Entry> uses Fs, Clock ! FsError | BadLine =
  var out: Array<Entry> = []
  for e in try &follow(path).map(parse).select(fn(e) => e.level == Error).take(100)
    &out.push(e)
  out                                        // (2) file closed here? or at the loop's end?

// Same thing, eager-looking consumer form:
fn first_errors2(path: Path) -> Array<Entry> uses Fs, Clock ! FsError | BadLine =
  try follow(path).map(parse).select(fn(e) => e.level == Error).take(100).to_array()

// Variant: stop at a marker, then resume from the same place.
fn sections(path: Path) uses Fs, Clock, Console ! FsError | BadLine =
  var r = follow(path)                       // a gen cursor bound to a var: a value
  for line in try &r
    if line == "--- boot ---" then break     // (3) does `follow`'s `finally` run here?
  let errors = r.map(parse).select(fn(e) => e.level == Error)   // (4) a copy of `r`, or `r`?
  for e in try &errors                       // (5) `&` on a `let`; blocks can't be `var`
    Console.print(e.msg)
```

Lines: producer 19, consumer 5 (or 2 with `to_array`), variant 7.

## Kotlin Flow

```kotlin
fun follow(path: Path): Flow<String> = flow {
    FileChannel.open(path).use { ch ->               // closed when the flow is aborted
        var at = ch.size()
        val partial = StringBuilder()
        val buf = ByteBuffer.allocate(64 * 1024)
        while (true) {
            buf.clear()
            val n = ch.read(buf, at)
            if (n <= 0) { delay(200); continue }
            at += n
            partial.append(String(buf.array(), 0, n))
            var nl = partial.indexOf('\n')
            while (nl >= 0) {
                emit(partial.substring(0, nl))
                partial.delete(0, nl + 1)
                nl = partial.indexOf('\n')
            }
        }
    }
}.flowOn(Dispatchers.IO)

suspend fun firstErrors(path: Path): List<Entry> =
    follow(path).map(::parse).filter { it.level == Level.Error }.take(100).toList()
```

`take(100)` throws `AbortFlowException` into the producer at its
`emit`, so `use` closes the channel then. Resuming after a `break`
isn't possible: a Flow is cold, and collecting it again reopens the
file. You'd hold a `Channel` (`produceIn(scope)`) to resume, which is a
hot stream and a task.

## Rust (sync iterator, the closest in spirit)

```rust
fn follow(path: &Path) -> io::Result<impl Iterator<Item = io::Result<String>>> {
    let mut f = File::open(path)?;
    let mut at = f.metadata()?.len();
    let mut partial = String::new();
    let mut pending: VecDeque<String> = VecDeque::new();
    let mut buf = vec![0u8; 64 * 1024];
    Ok(iter::from_fn(move || loop {
        if let Some(l) = pending.pop_front() { return Some(Ok(l)); }
        match f.read_at(&mut buf, at) {
            Ok(0) => thread::sleep(Duration::from_millis(200)),
            Ok(n) => { at += n as u64;
                       partial.push_str(&String::from_utf8_lossy(&buf[..n]));
                       while let Some(i) = partial.find('\n') {
                           pending.push_back(partial.drain(..=i).collect::<String>().trim_end().into());
                       } }
            Err(e) => return Some(Err(e)),
        }
    }))
}

let errors: Vec<Entry> = follow(path)?
    .map(|l| l.map_err(Error::from).and_then(|l| parse(&l)))
    .filter(|e| !matches!(e, Ok(e) if e.level != Level::Error))
    .take(100)
    .collect::<Result<_, _>>()?;
```

Without generators Rust writes the producer as a hand state machine
(`pending` queue). Errors per item are `Result`s threaded through each
adapter, which is where Ren's `try` on the `for` reads much better.
Resuming after a stop is `by_ref()`: `for l in it.by_ref() { if .. { break } }`
then keep using `it`; explicit and clear.

## Comparison

| | Ren | Kotlin | Rust |
|---|---|---|---|
| producer | 19 | 20 | 18 (hand state machine) |
| consumer | 5 / 2 | 2 | 6 |
| file closed on stop | `finally`, at loop end or drop | `use` + abort exception | `Drop` at end of iterator's scope |
| errors | `try` once on the `for` | exceptions | `Result` per item through every adapter |
| resume after `break` | `var r` + `for .. in &r` | needs a channel and a task | `by_ref()` |

**Better in Ren.** The producer reads like Kotlin's `flow {}` without a
dispatcher, and the consumer is one line with the stop point (`try`) on
the page. Error handling is far cleaner than Rust's per-item `Result`
plumbing. Resuming after `break` is real (Kotlin can't without a hot
channel).

**Worse or unclear in Ren.**

1. **When the file closes is not on the page.** `first_errors`'s loop is
   over a temporary, so the pipeline dies after the loop; the draft says
   `finally` runs "when a loop over it ends" *and* "when the cursor is
   dropped". In `sections`, a `break` out of `for line in try &r` must
   *not* run the `finally` (the cursor section says `r` resumes), so the
   first bullet of Cleanup can only mean "a loop over a temporary".
   And the drop point is Perceus's: README says values are "dropped as
   soon as they're dead", not "at the end of the scope", so if `r` isn't
   used after the loop the file closes *at the break*, and if it is, at
   its last use. Release inlining and borrow inference move that
   point. The draft calls the drop point "the end of a scope you can
   see"; it isn't.
2. **`Fs.close` at a drop is a dependency call nobody wrote at that
   place.** Decision 11 says "Resources are closed in a `finally` or an
   operation, never when a count reaches zero", and this is exactly a
   close when a count reaches zero. It's also journaled, so its position
   in the journal depends on the optimizer. If `close` can fail, there
   is no error channel at a drop.
3. **Does `r.map(parse)` step `r` or a copy of `r`?** Without `&` it's a
   read, so it holds a copy, and `follow`'s cursor is a value: the
   pipeline steps a copy and `r` stays put, the exact footgun the draft
   makes an error for `for x in c`. With a socket cursor the copy shares
   the connection id, so it advances anyway; with a `pread` file reader
   it doesn't. The draft has to say whether a pipeline takes its source
   by `&`, by move, or by copy, and the syntax has to show it
   (`(&r).map(parse)`? a fix-it?).
4. **`for e in try &errors` with `let errors`.** `&` needs a mutable
   place; a pipeline is a block; blocks can't be bound with `var`
   (decision 1). Either pipelines can be `var` (then they're not "blocks"
   in decision 1's sense), or `&` on a `let` pipeline is special-cased,
   or a pipeline can't be resumed after `break` (then why `&`?).
5. **Copying a generator cursor that holds a `finally`.** `var r2 = r`
   then stepping both: value semantics copies the frame on the first
   write, so two frames each own `f` and each run `f.close()`: a double
   close, or a read on a closed file by whichever runs second. The draft
   says "a generator's cursor copies like any value"; with a `finally`
   it can't, unless copies are forbidden (affine, which the draft
   rejects) or the resource lives in `Fs` keyed by an id whose close is
   idempotent and owned by the service, not the frame.
6. `& + try` on every loop: `for e in try &follow(path).map(...)`. On a
   temporary the `&` says nothing (there's no place to leave behind).
   Suggest: `&` required only when the source is a place.

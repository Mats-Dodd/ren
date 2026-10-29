# 4. Merge two sorted streams

Two sources sorted by timestamp: rows from a database query and events
from a log file. Merge them by `at`, lazily, and stop after the first
1000. Needs pulling from two sources with one item of lookahead each.

## Ren, per the draft

```ren
// Generic version: works when T is ordered by `<` (through `key`).
gen fn merge<A, B>(a: A, b: B) -> T =        // A, B `has next` of T; T ordered
  var a = a                                  // a cursor owns its inputs
  var b = b
  var x = try &a.next()                      // (1) `try` here: can a generic `next` fail?
  var y = try &b.next()
  while x != None || y != None
    match (x, y)
      (Some(p), Some(q)) =>
        if p <= q then
          yield p
          x = try &a.next()
        else
          yield q
          y = try &b.next()
      (Some(p), None) =>
        yield p
        x = try &a.next()
      (None, Some(q)) =>
        yield q
        y = try &b.next()
      (None, None) => ()

// Use 1: both sources are already Events, ordered by `at` via `key`.
type Event = { at: Time, src: Src, msg: Str }
  pub fn key(self) -> (Time, Src) = (self.at, self.src)

fn timeline(q: Query, path: Path) -> Array<Event> uses Db, Fs ! DbDown | FsError | BadLine =
  try merge(Db.rows(q), log_events(path)).take(1000).to_array()

// Use 2: the sources need a transform first. This is the program people write:
fn timeline2(q: Query, path: Path) -> Array<Event> uses Db, Fs ! ... =
  let rows = Db.rows(q).map(Event.from_row)
  let logs = Fs.line_reader(path).map(parse_event)
  try merge(rows, logs).take(1000).to_array()
  // error: a `gen fn` can't take a block: `rows` holds one
  //   (and `merge`'s cursor would keep it)

// What it has to become: a gen fn per source, written for its types.
gen fn row_events(q: Query) -> Event uses Db ! DbDown =
  for r in try &Db.rows(q)
    yield Event.from_row(r)

gen fn log_events(path: Path) -> Event uses Fs ! FsError | BadLine =
  for line in try &Fs.line_reader(path)
    yield try parse_event(line)

// Use 3: merge by something other than the type's key (by `msg` length, say):
// impossible lazily. `merge_by(a, b, fn(e) => e.msg.len())` would take a block,
// and a gen fn can't. Options: give the type a different `key` (changes `==`
// and `hash` everywhere), wrap in a newtype with that key, or write a
// `gen fn` with the comparison inlined, one per use.
```

Lines: merge 20 (the 4-way `match` is the bulk), use 1: 1, use 2
needs 6 more lines of `gen fn` wrappers.

## Go 1.23: `iter.Pull`

```go
func Merge[T any](a, b iter.Seq[T], less func(T, T) bool) iter.Seq[T] {
    return func(yield func(T) bool) {
        na, stopA := iter.Pull(a); defer stopA()
        nb, stopB := iter.Pull(b); defer stopB()
        x, okx := na()
        y, oky := nb()
        for okx || oky {
            if okx && (!oky || less(x, y)) {
                if !yield(x) { return }
                x, okx = na()
            } else {
                if !yield(y) { return }
                y, oky = nb()
            }
        }
    }
}
```

14 lines, takes a comparator (a closure), works with any `Seq`
including mapped ones. Cost: `iter.Pull` runs each source on a
coroutine (`runtime.coroswitch` per item, roughly 10x a direct call),
and errors need `iter.Seq2[T, error]` plumbing.

## Rust: itertools

```rust
use itertools::Itertools;
let timeline: Vec<Event> = rows.map(Event::from_row)
    .merge_by(logs.map(parse_event), |a, b| a.at <= b.at)
    .take(1000)
    .collect();
```

One line, closures and adapters compose freely (sync). For async
`Stream`s there's no sorted merge in `futures`; you write it by hand
with two `Peekable`s and `poll_next`, about 30 lines.

## Kotlin Flow

No way to pull from two flows directly; a Flow is push-only. You
`produceIn(scope)` both into channels (two coroutines, two buffers)
and `receiveCatching()` from each:

```kotlin
fun <T> merge(a: Flow<T>, b: Flow<T>, cmp: Comparator<T>): Flow<T> = flow {
    coroutineScope {
        val ca = a.produceIn(this); val cb = b.produceIn(this)
        var x = ca.receiveCatching().getOrNull(); var y = cb.receiveCatching().getOrNull()
        while (x != null || y != null) {
            if (y == null || (x != null && cmp.compare(x, y) <= 0)) { emit(x!!); x = ca.receiveCatching().getOrNull() }
            else { emit(y); y = cb.receiveCatching().getOrNull() }
        }
        ca.cancel(); cb.cancel()
    }
}
```

## Comparison

| | Ren | Go | Rust (sync) | Kotlin |
|---|---|---|---|---|
| lines | 20 | 14 | 1 (library) | 12 |
| comparator / key | the type's `key` only | closure | closure | `Comparator` |
| over transformed sources | **no**: wrap each in a `gen fn` | yes | yes | yes |
| cost per item | direct `next` calls, fused | coroutine switch | inlined | channel hop + 2 tasks |
| cleanup on early stop | both sources' `finally`s at drop | `defer stop()` | `Drop` | `cancel()` |

**Better in Ren.** Pull is native: two cursors, direct calls, no
coroutine (Go) or channel and tasks (Kotlin). Errors from either
source end the merge with one `try` per pull. This is the case the
cursor design exists for, and the cost story is the best of the four.

**Worse or unclear.**

1. **The user can't write an adapter that takes a block, and can't
   write one that takes a pipeline.** `merge` is a `gen fn`, so it
   stores its inputs, so (a) it can't take `rows.map(f)` (a pipeline is
   a block), and (b) it can't take `less`/`by`. Only built-in adapters
   (`map`, `zip`, ...) can hold blocks, because they're "shared
   adapters" the compiler knows. So the vocabulary is closed and
   user-written stream combinators are second-class: `merge_by`,
   `dedup_by`, `scan`, `group_by_key`, `interleave`, any two-input
   adapter. This is "a pull pipeline is a `gen fn` written for its
   element types" from foundations' "What's given up", still given up,
   for every adapter the library doesn't ship. Options: (i) a block
   parameter on a gen fn that's allowed when the gen fn's cursor is
   itself only ever a pipeline (i.e. `gen fn` that *takes* a block
   produces a block-holding cursor, which can't be stored: the same
   rule as pipelines, applied uniformly); (ii) ship `merge_by`,
   `merge` and friends as built-ins. (i) is one mechanism and is
   what makes "a value that holds a block is a block" pay off.
2. **`next` is a requirement with an associated type and rows.**
   `merge<A, B>` needs "`A` has `next` giving `Option<T>`" and the same
   `T` for `B`: that's Rust's `Iterator::Item`, a type function from
   `A` to `T`. No other built-in requirement (`==`, `add`, `zero`,
   `show`) has one. And `next`'s `uses` and `!` rows vary with `A`
   (`Db.rows` uses `Db ! DbDown`; an array cursor uses nothing), so the
   requirement carries row variables, and `try &a.next()` in generic
   code is a `try` that "covers nothing" when `A` can't fail (an error
   today). That's more than "joins the closed set"; spell out the
   requirement's shape (`A has next -> T uses e ! r`) and the rule for
   `try` on a call whose row is a variable.
3. **The draft's own requirement check contradicts compiler.md.**
   compiler.md's `check_blocks` rejects a type variable given a block's
   type, "since `T` could be stored". `index_all(rows: C) where C has next`
   called with a pipeline gives `C` a block-holding type. So either
   every `C has next` parameter is treated as possibly-a-block in the
   callee (can't store, return or capture it, ever, even for a socket
   cursor), or a new kind distinguishes block-holding types. Neither is
   "the checks blocks already have". Same for `merge(a, b)`: whether it
   compiles depends on whether `a` happens to be a pipeline, which a
   debug build (no specialization) must decide from the signature.
4. 20 lines for a sorted merge is fine, but the four-way `match` on
   `(x, y)` is noise Go avoids with `okx`/`oky`; it's not a design
   problem.

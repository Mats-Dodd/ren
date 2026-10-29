# 5. Walk a tree with `yield from`, and stop early

Two trees: an in-memory one (pure), and a directory tree (each level
holds an open directory handle, so stopping early must close every
open handle, innermost first). Find the first 10 files over 1 MB.

## Ren, per the draft

```ren
type Tree = { node: Node, children: Array<Tree> }

gen fn walk(t: Tree) -> Node =
  yield t.node
  for c in t.children
    yield from walk(c)

fn find(t: Tree, name: Str) -> Option<Node> =
  for n in walk(t)                    // a temporary: is `&` needed? (draft: error without it)
    if n.name == name then return Some(n)
  None
// or: walk(t).find(fn(n) => n.name == name)

// The directory tree.
type Entry = { path: Path, size: Int, dir: Bool }

gen fn walk_dir(p: Path) -> Entry uses Fs ! FsError =
  let d = try Fs.open_dir(p)
  finally d.close()                   // one per level that's open
  for e in try &d.entries()
    yield e
    if e.dir then
      yield from walk_dir(e.path)     // (1) its errors: `yield from try walk_dir(..)`?

fn big_files(root: Path) -> Array<Entry> uses Fs ! FsError =
  try walk_dir(root).select(fn(e) => not e.dir && e.size > 1_000_000).take(10).to_array()
  // after the 10th: the open handles close, innermost first, as the frames unwind
```

Lines: `walk` 4, `find` 4 (or 1), `walk_dir` 8, `big_files` 2.

## Kotlin `sequence {}` (sync) / `flow {}`

```kotlin
fun walk(t: Tree): Sequence<Node> = sequence {
    yield(t.node)
    for (c in t.children) yieldAll(walk(c))
}

fun walkDir(p: Path): Flow<Entry> = flow {
    Files.newDirectoryStream(p).use { d ->
        for (e in d) {
            val entry = Entry(e)
            emit(entry)
            if (entry.dir) emitAll(walkDir(e))
        }
    }
}.flowOn(Dispatchers.IO)

val big = walkDir(root).filter { !it.dir && it.size > 1_000_000 }.take(10).toList()
```

Same shape and size as Ren. `yieldAll` on a nested `sequence` is
O(depth) per item; `emitAll` of a nested flow collects in place (push),
so O(1).

## Go 1.23

```go
func (t *Tree) All() iter.Seq[*Node] {
    return func(yield func(*Node) bool) { t.push(yield) }
}
func (t *Tree) push(yield func(*Node) bool) bool {
    if !yield(t.Node) { return false }
    for _, c := range t.Children {
        if !c.push(yield) { return false }
    }
    return true
}
// directory version: os.ReadDir per level + defer f.Close(), same bool threading.
```

Push, O(1) per item, but every recursive helper threads the `bool`
by hand, and forgetting one check panics at run time ("continued
iteration after function for loop body returned false").

## C#

```csharp
static IEnumerable<Node> Walk(Tree t) {
    yield return t.Node;
    foreach (var c in t.Children)
        foreach (var n in Walk(c)) yield return n;     // no `yield from`: O(depth) per item
}
```

## Comparison

| | Ren | Kotlin | Go | C# |
|---|---|---|---|---|
| lines (walk) | 4 | 4 | 9 | 5 |
| per item, consumed by a `for` | push: O(1), nothing allocated | `sequence`: O(depth) | O(1) | O(depth) |
| per item, stored/zipped cursor | O(depth) delegation, a boxed frame per level | | `iter.Pull`: coroutine | O(depth) |
| early stop closes all levels | `finally`s unwind | `use` + abort | `defer` | `Dispose` cascade |

**Better in Ren.** The shortest and clearest: no `bool` threading (Go),
no nested `foreach` (C#), no dispatcher (Kotlin). `yield from` with
push compilation gives Go's cost with Kotlin's syntax. Removing
`Async.pull` for recursion is a real simplification.

**Worse or unclear.**

1. **`yield from` and errors.** The draft puts a `try` on every `for`
   over a cursor that can fail, "the place a stream can stop is on the
   page", but `yield from walk_dir(c)` delegates to a failing cursor
   with no marker. Either `yield from try walk_dir(c)` or say why
   delegation is exempt.
2. **The cost cliff is invisible.** Consumed directly: pushed, O(1),
   nothing allocated. Passed to `.select(...).take(10)`: is a pipeline
   over a `gen fn` a "consumer" that permits push? "Later: fusion
   through a `gen fn` whose consumer is a pipeline" says no, so
   `big_files` compiles `walk_dir` to a state-machine cursor with one
   boxed frame per depth and O(depth) per `next`. The two programs
   above look equally cheap and aren't. Since the pipeline here is a
   built-in adapter chain ending in a `for`/`to_array`, the compiler
   could push through it now (the pipeline's stages are known); worth
   moving out of "Later", or documenting the cliff where `ren explain`
   can show it.
3. **Stopping a pushed recursive generator early** must unwind every
   level's `finally` in order, from the consumer's `break`: that's an
   ordinary unwind in push mode, fine. In cursor mode (stored), the
   open handles are closed when the cursor is dropped, at Perceus's last
   use (see 01, items 1 and 2), and a copy of a mid-walk cursor holds
   copies of every level's frame, each with `d` and a `finally`: a copy
   closes every directory twice.
4. **`for n in walk(t)` without `&`** is an error by the draft's rule
   ("`for x in c` without `&` is an error on a cursor"), but it's a
   temporary, so there's no place to leave anywhere. Requiring `&` on
   a call's result is noise; the rule should be about places.
5. The draft's push rule ("no program can tell") holds for results,
   but a `gen fn` that uses `Clock` and a body that uses `Clock` are
   journaled in the same order in both modes, so fine; worth a line
   that push doesn't reorder dependency calls.

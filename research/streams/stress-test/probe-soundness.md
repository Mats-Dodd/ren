# streams.md: soundness probe against foundations.md

Read-only probe. Programs are on paper; "the rules say" cites foundations.md
(F), language.md (L), streams.md (S), and the 10c checker where it already
implements a rule (`lib/sema/mut.ml`, `lib/sema/excl.ml`,
`lib/sema/infer_msg.ml`).

Severity: **breaks** = unsound or unbuildable as written; **major** = a real
design or ergonomic hole; **minor** = needs a sentence.

## Summary

The core idea, that a pipeline is a second-class value checked like a block,
is right and can be made sound. As written, though, it isn't one rule
extended. It is four new things that the doc treats as "the checks blocks
already have":

1. **A block you can step.** Today a block is stateless and bound only by
   `let` to one literal. A pipeline has state (`take`'s counter, a source
   cursor) and has to be changed in place.
2. **A block in a generic.** Today generics never hold blocks (10c step 3).
   Pipelines get passed to `C has next`.
3. **A block that keeps a reference.** Either it keeps `&r` past its call,
   or it silently copies `r`.
4. **A value whose drop runs effects** (`gen fn` + `finally`).

The first three are fixable with one explicit idea: a **scoped value**
kind, like Swift's `~Escapable`, that the checker tracks through generics.
The fourth is the serious one. A `finally` that calls dependencies when a
Perceus count reaches zero contradicts decision 11. It runs at a point the
compiler chooses, in code whose row doesn't allow it, and once per copy of
a copyable value. Its fix is the same scoped kind: an effectful `finally`
belongs only to a cursor that can't escape.

## 1. A pipeline bound with `let`

```ren
var r = Fs.line_reader(path)
let errors = r.map(parse).select(fn(e) => e.level == Error).take(100)
for e in try &errors
  try alert(e)
  if e.fatal then break
for line in try &r          // where is r?
  ...
```

**As written it fails three rules the compiler already enforces:**

- `let errors = <not a literal fn>` is `let_not_literal`. F1 says "a `let`
  binds one literal block, so the code it runs is known where it's called"
  (`infer_msg.ml:1786-1820`).
- `&errors` on a `let` fails Mut: only a `var`, an `inout` parameter, or a
  `for &` element can be changed (`mut.ml:85`, "declare it with `var`").
- `var errors = ...` fails F1: "blocks can't be bound with `var`".

So the flagship example can't be written. A pipeline has to be steppable,
and every block rule forbids that. **(breaks)**

**Copy or borrow?** `r.map(parse)` has a plain receiver. By L and F2 that
is a read of `r` that hands over a value, so the pipeline holds **a copy of
`r`**. Then:

| `r` is | after `break`, `r` is |
|---|---|
| `xs.cursor()` | at the start: the copy advanced, `r` didn't |
| `Fs.line_reader` (offset as data, `pread`) | at the start: S itself says a copy is "an independent reader" |
| `Net.chunks(conn)` (an id) | past everything the pipeline read, *including lookahead* |

The same program means three things depending on the source's
representation. And S's headline ("a `break` leaves the cursor where it
stopped, the next loop goes on from there", S:82) is false for pipelines
over files and arrays. **(major)**

**If instead the pipeline keeps `&r`,** F2's table has no row for it.
`&p` lasts "the call, from after the arguments are evaluated", and the
pipeline outlives `map`'s call. There are two ways to make it sound:

- **(a) As a held borrow,** a write of `r` for the binding's scope. That is
  sound, since the scope is syntax, but it's a new row, and it makes
  `r` unusable until `errors`'s scope ends. That kills the two-loop idiom.
- **(b) As a capture.** This is what excl.ml already does for a `let`-bound
  block: it "accesses nothing where it's bound, and acts as its captures
  wherever it's called or passed" (`excl.ml:28-30`). The pipeline keeps the
  frame slot of `r`, not a pointer into `r`'s contents, and it can't
  escape the frame. So `r` is written at each use of `errors` and is free
  between uses. That's sound, and it is exactly F1's
  `let f = fn() => n + 1; n += 5; f()` semantics.

**Is "a value that holds a block is a block" enough?** It's enough for
*escape*: rule D keeps the frame alive. It isn't enough to say *what is
accessed when*. (b) is the right reading, but it has to be written down,
and it needs a spelling: `&r.map(parse)`. Without the `&`, `r` changes
during a later `for` over `errors` with no `&r` on the page. That is
"found behind your back". It also contradicts L §8, "no `&` through a
pipe", since `r.map(parse) |> try search.index_all` would carry a hidden
`&r` through `|>`.

**Recommendation.**

- `r.map(f)` consumes a copy, and `&r.map(f)` captures `r` by reference
  with rule (b).
- Pipelines are bound with `var`. Assigning a pipeline `var` after it's
  bound is an error; only stepping it is allowed.
- Add a row to F2: "a pipeline: its stages' captures and its `&` source,
  as a block's, wherever it's stepped or passed."

**Other uses of `r` meanwhile** under (b):

- Between loops: free.
- Inside `for e in &errors`: `r` is held as a write for the loop, so
  `r.next()` in the body is an error. That's sound and desirable.
- `r = Fs.line_reader(other)` between loops: re-targets `errors`. That's
  consistent with blocks, but worth a line.

**Lookahead.** Under (b), `take_while`, `windows`, `chunks` and `zip` read
one item past what they yield. After `for x in &(&r).take_while(p)`, `r`
has lost the first failing item. This is Rust's
`by_ref().take_while` trap. Either document it, or make the lookahead
stages hold the item in the pipeline and not consume it from `r`, which
needs peek on the source. **(minor)**

## 2. Rule A and rule D extended

### 2a. A pipeline through a generic parameter: escape

S:211 has `|> try search.index_all`, whose signature is
`index_all(rows: C) where C has next`. F1 and 10c step 3 say "written
types, generics and handler parameters hold none" (no blocks). Once `C`
may be a pipeline, a generic body can let it escape:

```ren
fn keep<C has next>(c: C) -> C = c                 // returns it
fn later<C has next>(c: C) uses Jobs = Jobs.put(Box { c })   // stores it

let p = keep(xs.cursor().map(fn(x) => x + k))     // p's block points into a dead frame
```

Nothing in `keep`'s signature says `C` might be a block, so the one-walk
check of `keep` accepts it, and the caller's check sees an ordinary call.
**(breaks)**

### 2b. A pipeline through a generic: rule A bypassed

Rule A is enforced *in the callee*, which must see that an argument is a
block. A generic `C` hides that:

```ren
fn drive<C has next>(c: C, k: fn(C)) = k(c)       // c isn't "a block", so rule A is silent
fn bump<C has next>(inout a: Int, c: C) =
  for x in &c
    a += x

var n = 0
drive(xs.cursor().map(fn(x) =>
        n += 1                                     // stage writes n
        x),
      fn(p) => bump(&n, p))                        // &n held for bump; p's stage writes n inside it
```

At the outer call the two blocks are siblings ("blocks passed to the same
call don't conflict"). Inside the lambda, `p` is a parameter of unknown
captures. Inside `bump`, `a` (which is `&n`) and the stage's write of `n`
alias. Natively that breaks the "`&` parameter aliases nothing" fact the
optimizer uses (`restrict`, hoisted checks), and the interpreter's
copy-in/copy-out loses the stage's increments. **(breaks)**

**Fix (2a and 2b):** a scoped kind on type parameters, as Swift had to add
for exactly this reason. Swift's SE-0446 says:

> "in generic contexts, `~Escapable` suppresses the default Escapable
> requirement ... the compiler must conservatively prevent the values from
> escaping"
>
> (`/tmp/ren-refs/swift-evolution/proposals/0446-non-escapable.md:117-131`)

For Ren: a type parameter that may be a pipeline is marked (inferred on
private functions, written on public ones, as rule B's modes are). Its
values follow block rules: no store, no return, no spawn, and rule A
counts them as block parameters. That keeps the check one walk from
signatures. Then also say whether `C has next` alone implies the mark.
I'd say no: `Async.map` and `index_all` opt in.

### 2c. A pipeline whose stage captures a block parameter

```ren
fn scan(f: fn(Str) -> Rec, k: fn(Rec)) uses Fs =
  var r = Fs.line_reader(p)
  for x in try &(&r).map(f)
    k(x)                // f and k alternate, never nest: fine
```

This is fine. Passing the pipeline *to* `k` is impossible anyway, since a
block's parameter type can't hold a block. Once 2a's mark exists, rule A
must treat "a pipeline whose stages capture a block parameter" as "a block
that captures one". That fact is syntactic in the function that builds
the pipeline, so it stays one walk. **OK with the fix.**

### 2d. `zip` of two pipelines over one cursor

```ren
for a, b in &(&r).map(f).zip((&r).map(g))
```

- **Copy semantics:** two independent copies (arrays, files), or two names
  for one socket that steal items from each other alternately.
- **Capture semantics (1b):** both capture `&r` and are arguments to the
  same call, so they're siblings and allowed. `zip` steps `r` twice per
  pair: `a` is item 1, `b` is item 2. That's sound, and surprising.

Suggest: two pipelines capturing one `&` source in one call conflict.
That's an exception to the sibling rule, justified because a pipeline's
captures are *stepped*, not just used. **(minor)**

### 2e. A pipeline over a cursor in handler state

```ren
handler tailer(path: Str) for Tail =
  var r = Fs.line_reader(path)
  poll() =>
    for e in try &(&r).map(parse).select(fn(e) => e.level == Error)
      try Alerts.send(e)
```

F2's last row: "inside a handler arm, any dependency call ... is a write of
all the handler's state, for that call" (`excl.ml:956`, `state_writes`).
The loop holds a write of `r` for the loop, and `Alerts.send` writes all
state, `r` included, so that's an error. So is `r`'s own `next`, which
calls `Fs`. The same is true today of a plain `for x in &r` with a
dependency call in the body. With streams it becomes the normal case:
every resource cursor's `next` is a dependency call, so **no handler or
actor can stream over a cursor it keeps.** That's paper program 10. The
workaround (`var c = r; for ... &c ...; r = c`) is legal, since decision
10 means nobody else runs the instance meanwhile. But it's ceremony the
checker forces for a hazard that exists only at `Async.until` and
`release`.

excl.ml's own comment says the row is "more than tasks need". Suggest
narrowing it to `Async.until`, `release` and block-parameter calls, the
three places the instance can actually be re-entered. **(major)**

## 3. Exclusivity, step by step

```ren
var seen = 0
var limit = 10
for x in &xs.cursor().map(fn(x) =>
    seen += 1                 // stage writes
    x).select(fn(x) => x < limit)
  log(seen)                   // body reads: an instant, between steps
  if x == 3 then limit = 5    // body writes what a stage reads
```

**Within a `for` in the same function this is sound and one walk.** Stage
accesses are instants inside `next`. Every body access ends when the body's
turn ends, which is syntax. They can't overlap, so the stage captures
don't need checking against the body at all. They still count against
anything held *across* the loop: a spawned read of `seen` in an enclosing
scope, or a `for &seen`. That's a check against the loop as a whole, and
also one walk. This holds equally for stage writes and reads.

**It's unsound if "instant" leaks into calls:**

```ren
consume(xs.cursor().select(fn(x) => x < limit), &limit)
fn consume<C has next>(c: C, inout lim: Int) =
  for x in &c
    lim -= 1                  // lim aliases the stage's `limit`
```

For a block, F2 says its captures are held "for the call", which makes this
an error today. If the pipeline's captures count only "at each step", it
passes, and `&lim` aliases a capture, which is the fact F2 promises the
optimizer can't happen.

**Rule to write:** a pipeline passed to a call holds its stages' captures
(and its `&` source) for the call, as a block does. The step-by-step
relaxation applies only to a `for` whose source is the pipeline, in the
function that loops. Concurrency follows from that: `Async.map(p, max:)`
with `p`'s stage writing `n`, while the concurrent block reads `n`, is
already an error under "unless one goes to a concurrent parameter".
That's correct, *provided* `Async.map` steps its cursor on the caller's
task. Say so: the cursor argument of `Async.each`/`Async.map` is ordinary,
stepped serially by the caller. If it were handed to a feeder task, it
would be a pipeline captured by a spawn, which S already forbids.
**(major: it has to be stated, or an implementer applies "instant"
everywhere)**

## 4. A generator's frame is relative, but its uniqueness facts aren't

S:264-272: blocks in a generator's frame address it relatively, so "a
generator's cursor copies like any value." Copies happen only at a
`yield`, since during `next(inout self)` the cursor is held exclusively,
so only state live across a `yield` matters. Relative addressing covers
frame slots. It doesn't cover F2's payoff:

> "when a loop makes no new reference to the array ... the check and any
> copy move to the loop's entry and the loop indexes the buffer directly."

```ren
gen fn bumped(xs: Array<Int>) -> Int =
  var a = xs
  for x in &a          // uniqueness of a's buffer checked once, at entry
    x += 1
    yield x            // the consumer may copy the generator here

var g = bumped([1, 2, 3])
let _ = g.next()
let h = g              // frame copied: a's buffer now has count 2
let _ = g.next()       // resumes the loop, writes a[1] through the hoisted pointer
h.next()               // sees g's write: value semantics broken
```

The `yield` is a point where "a new reference to the array" can be made by
code the loop can't see. **(breaks** the stated implementation rule, cheap
to fix**)**

Two fixes:

- Every `&` held across a `yield` re-checks uniqueness on resume. That's
  one compare per held `&` per `next`.
- Or a `for &` that contains a `yield` doesn't hoist.

The same goes for any `inout` element reference live across a `yield`.

Two more things the generator rules need:

- **A `gen fn` can't take `inout` parameters.** Otherwise its cursor keeps
  a caller's `&`.
- **A handler operation can't be a `gen`.** Otherwise its cursor keeps
  the instance (F3, "no `next` or instance" in data).

Not in S. **(minor)**

Copying a generator that holds a pipeline mid-iteration is otherwise fine.
Its blocks can only capture the generator's own frame, since a `gen fn`
takes no block and its parameters are values.

## 5. `finally` at a drop

S:298-308: a `gen fn`'s `finally` runs "when the cursor is dropped, which
Perceus makes deterministic: at the end of the scope that held the last
reference", and it "can call dependencies". Each of these contradicts a
signed rule.

**5a. Decision 11:** "Resources are closed in a `finally` or an operation,
**never when a count reaches zero**." A drop is a count reaching zero.
**(breaks)**

**5b. Perceus doesn't drop at scope end.** compiler.md, Step 4: a value is
"dropped as soon as it's dead". Borrow inference decides whether a callee
owns, and so drops, a parameter.

```ren
var g = lines(path)
for l in try &g
  if l == "" then break
Console.print("done")      // is Fs.close before or after this line?
```

Under Perceus, `g` dies after the loop, so the `finally` runs before
`print`. Under S's text it runs at scope end, so after. That changes the
journal order. Any change to borrow inference or inlining moves it, so a
journal from a debug build can stop replaying in release. **(breaks)**
(decision 11's determinism)

**5c. Drops happen where no dependency may be called:**

- in generic code with a closed row: `fn first<T>(xs: Array<T>) -> T`
  drops the rest of `xs`. With `T` a `lines` cursor, it runs `Fs.close`
  and *suspends* in a function decision 12 gives no frame;
- at an assignment, `g = lines(other)`: an `=` that calls `Fs` and is a
  `sim` scheduling point;
- in `snapshot`'s QSBR reclaim of an old version, run by the runtime on no
  task;
- in an arena's end pass;
- under `Async.isolate` after a panic, where "values are leaked, not
  dropped", so the file is never closed;
- on whichever task drops the last count of a value marked shared;
- inside a handler operation that overwrites state holding a cursor whose
  `Fs` (or `Db`) was installed *inside* that handler. That's an
  inner-handler call from an operation, which breaks decision 10's
  deadlock argument. Or the `with` has already ended.

**(breaks)**

**5d. Copies.** A `gen fn` cursor is a value ("can be stored, returned,
put in a record and given to a task"). So:

```ren
var g = lines(path)
let _ = try g.next()
let h = g                  // two frames, two pending `finally f.close()`
// both dropped: Fs.close(f) runs twice; or h closes while g still reads
```

That's a double close, or reading a closed (or reused) descriptor. The
only cures inside S's model are affine cursors, which S rejects, or
closing when a count reaches zero, which decision 11 rejects. **(breaks)**

**Cancellation (S:301)** is fine on its own. An unwind already runs
`finally`s shielded under the cleanup deadline (async.md). The trouble is
only the *drop* trigger.

**Recommendation: one rule closes 5a to 5d, and it reuses the scoped kind
from 2a.** A `gen fn` whose `finally` (or anything it covers at a `yield`)
uses a dependency returns a **scoped cursor**, which follows rule D. It
can be bound with `var`, looped, passed down to marked parameters, and
zipped. It can't be stored, returned, copied into a task or marked shared.
Its `finally` runs at a point the syntax fixes: when the `for` that owns
it ends, or at the end of the scope of the `var` that holds it. Both are
unwinds, shielded, in the consumer's row.

A storable `gen fn` (the S:242 use: stored, returned, given to a task) may
have a `finally` only if it uses no dependencies. Its resource cleanup
belongs to the service: `Fs` closes what's still open at its `with`'s end,
and there's an explicit `close`. That is S's own rule (S:323, "a
resource's state belongs to its service") applied to cleanup.

Prior art agrees that drop-time async cleanup can't be had for free:

- Go's `iter.Pull` requires an explicit `stop()` and runs no finalizer
  (pkg.go.dev/iter).
- Rust's async drop is still an open initiative, for exactly the
  "drop in a sync or generic context" reason
  (rust-lang.github.io/async-fundamentals-initiative).
- Python's PEP 525/533 is the failure S cites.

The cost: a `lines` that's stored can't close its own file. I think that's
the right price. It's also the one place the "only one kind of stream"
claim bends: scoped versus storable is visible in errors.

## 6. Can push versus pull be observed?

S:256-262 says "no program can tell". Checked:

| What could tell | Push (body inlined at `yield`) | Pull (state machine) | Same? |
|---|---|---|---|
| journal order of dependency calls | producer's calls, then body's, then producer's | same, via `next` | yes |
| `sim` scheduling points | the dependency calls in that order | same | yes |
| exclusivity | body can't reach producer locals; producer can't capture consumer places (no blocks, value parameters) | same | yes |
| `finally` on `break`/failure/cancel | unwind through producer frame, before the consumer's outer `finally`s | cursor temp dropped at loop exit, same order *if* the temp dies at the loop's end | yes, given 5's rule |
| `finally` of a `var`-bound generator | n/a (pull) | Perceus last use, or scope end? | **depends on 5b** |
| deep `yield from` recursion | nests native frames: a 10⁶-deep tree can overflow | children boxed on the heap, no overflow | **no** |
| a `finally` that sees *why* (`finally(r) =>`) | sees the consumer body's error or cancel | sees a drop | **no, if gen `finally` can take a cause** |

**Fixes:**

- Push only non-recursive producers: a `yield from` of the same function
  goes pull. Or give pushed frames the task's segmented stack.
- Say a generator's `finally` takes no cause.
- With 5's scoped rule, the remaining row is closed.

**(minor)**

Also, `for x in &gen()` and `for row in try &Db.rows(q)` put `&` on a call
result. Mut allows `&` only on places (`mut.ml:1-12`). It needs a rule:
"`&` on a temporary in a `for` source steps it in place". **(minor)**

## 7. `yield` banned inside `with`, scope, timeout, `finally`

**Incomplete, and the wrong shape.** A `yield` inside *any* block can't
work. The block runs inside a callee's frame, which isn't the generator's:

```ren
gen fn g(xs: Array<Int>) -> Int =
  xs.each(fn(x) => yield x)            // not on S's list; can't be compiled
  try retry(3, on: E) fn() => yield 1   // on the list
  Docs.at(k) fn() => yield 2            // not on the list: pins an actor across a yield
  snapshot.read fn(v) => yield v        // not on the list: holds a version across a yield
  Async.isolate fn() => yield 3         // not on the list
```

The rule should be: **`yield` appears only in the `gen fn`'s own body,
not inside any `fn` literal, `with`, or `finally`.** That makes the
scope/beside/timeout/race/retry/isolate/at/read cases fall out, as in
Python and JavaScript, where `yield` in a nested function belongs to that
function.

**Are the two non-block items necessary?**

- **`with`: yes.** Across a `yield` the cursor would hold a handler
  *instance*, which the bet forbids ("the programmer never holds an
  instance"). A copy of the cursor would duplicate it.
- **`finally`: yes.** It runs at an unwind, when no consumer is pulling.

**Also needed:** no `gen` handler arms, and no `inout` parameters on a
`gen fn` (see 4). **(major:** as written the list invites case-by-case
growth, and misses actor pins and snapshot reads, which hold runtime
resources across a `yield`**)**

## 8. Resource cursors holding ids

```ren
var c = Net.chunks(conn)
Async.scope fn(s) =>
  s.spawn fn() =>
    var mine = c                 // rule C: spawned blocks read; a copy to step
    for b in try &mine
      ...
  s.spawn fn() =>
    var mine = c
    for b in try &mine
      ...
```

- **Is it sound? Yes.** Reads are `Net` operations, which serialize. Under
  `sim` the split of chunks between tasks is a tape choice, so it's
  replayable. S calls it "honest", which is fair for raw chunks.
- **It isn't honest once the cursor frames.** Every useful socket cursor
  keeps partial input. formats.md's framing loop keeps `buffered` and
  calls `conn.read_more(need)`. S's own `gen fn lines` keeps the current
  `chunk` and its split position in its frame. Those are resource state
  in the cursor, against S's rule "only ids and offsets in the cursor".
  Two copies (two tasks, or one `let h = g`) both hold the same leftover
  bytes, then read disjoint later chunks from the shared connection. The
  result is duplicated or corrupt frames, not just interleaving.
- **The rule is unenforceable for `gen fn`s.** Any generator over a
  resource that buffers breaks it. **(major)**

Options:

- Framing and line splitting move into the service, with
  `Net.read_frame(conn, fmt)`, `Fs` line offsets and peek/consume on the
  connection, so the cursor really is an id. Or:
- Resource generators are scoped (5's kind), so they can't be copied into
  two tasks or stored.

The second costs least and also fixes cleanup.

**Id provenance** (related). A stored `lines` cursor's `next` runs "with
the consumer's dependencies" (S:345). The file id was minted by the `Fs`
instance where it was opened. The consumer may be under a different `Fs`
(a test's `fake_fs` versus the real one), or after that `with` ended and
its `finally` closed everything. Nothing ties an id to its instance.
Decision 18's journal names actor incarnations for this reason. Resource
ids should carry the instance's incarnation and fail with a typed error,
not reach the wrong handler. **(major)**

**Cleanup ownership.** With copies, "who closes the connection" has no
answer in S. Under 5's recommendation it's the service at `with` end, or
an explicit `Net.close`, and the other copy's next read fails with a
typed `Closed`.

## Smaller points

- **Choosing between pipelines.** In
  `let src = if verbose then (&r).map(f) else (&r).map(g)`, the type can't
  say which block is held (S: "a block is never part of a type"), so
  release can't fuse it into one loop. 10c already has `Let_chosen` for
  blocks ("choose inside one block"). Extend it to pipelines, or say
  release dispatches on a tag there. **(major:** conditional pipelines are
  common, and the doc's "obvious way is the fast way" depends on the
  answer**)**
- **`Async.map_pull` and `Async.produce`.** A cursor whose items come from
  running tasks holds a scope, so by rule D it's scoped. Its "drop" has to
  cancel and wait, which only works at a syntactic point, the same as 5.
  `Async.produce` already does this by taking the body as a block.
  `map_pull`'s returned cursor needs the same shape, or must be scoped.
  **(minor)**
- **F3 descriptions** may hold data, and a storable generator is data. A
  description holding a generator is copied at each `with`, which is 5d's
  double `finally` again. The scoped rule excludes it. **(minor)**

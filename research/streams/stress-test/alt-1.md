# Alternatives 1: what a pipeline is

The question: is a lazy pipeline (`r.map(f).select(p)`, a call of a `gen fn`
that takes a block, a wrapped cursor) **a value of a new block kind** (A,
the draft made sound), or **an ordinary block** `fn() -> Option<T>` that
the compiler composes where the chain is written (B)? A third option (C)
shrinks pipelines to syntax with no values, as the floor to compare
against.

Each option answers the same sub-questions:

1. How a stage holds its source: a copy, an `&r` held as a capture, or a move.
2. Whether `r` has advanced after a `break`.
3. Whether the missing-`&` error applies only to named places.
4. Whether user-written lazy stages keep the fused cost.
5. Whether extracting a pipeline into a helper keeps the fused cost.

Each option is written against the same five programs:

- **P1** the flagship `errors` example (programs/01, the `sections` variant);
- **P2** `merge(rows.map(f), logs.map(g))` (programs/04);
- **P3** a user-written `dedup_by` and `scan` (programs/09, step 6);
- **P4** `index_all` over a pipeline, through `|>` (streams.md:211);
- **P5** a helper extracted, then consumed with `.take(10)` (programs/09, steps 2 and 3).

The soundness counterexamples from probe-soundness.md (`keep`, `drive`,
`consume(..., &limit)`) are run against each option too.

**Recommendation: B.** Its source rule is "`&r.map(f)` captures `r` the
way a block does, a temporary head becomes a hidden local". A `gen fn`
that takes a block is how users write stages, and push lowering runs
through one-input stages. B is the only option where "the checks are
the ones blocks already have" is true rather than aspirational. It
deletes the `next` requirement, the kind mark on type variables, the
new debug layout and the new specialization key. The one thing it gives
up is storable generic adapters over data cursors, such as a
`Peekable<C>` kept in a record. foundations.md already gives that up,
and nothing in the ten paper programs needs it.

---

## The shared base (identical under A, B and C)

None of this depends on the choice, so it's stated once:

- `gen fn` with no block parameters compiles to a data cursor: storable,
  returnable, a frame as a counted object.
- A `for` over a temporary `gen fn` call is pushed (Go's range-over-func
  rewrite).
- Blocks written in a generator's body address its frame relatively.
- Cleanup, `yield` placement, and `Async.produce` are other points'
  business.
- A **cursor** is, structurally, a type with `next(inout self) ->
  Option<T>`, as `for` already treats it (10c, `Infer_expr.cursor`).

---

## Option A: a pipeline is a value of a new block kind (the draft, made sound)

### The rules A needs

The draft's "a value that holds a block is a block" becomes these
rules, each forced by a finding:

| Rule | Forced by |
|---|---|
| A pipeline is bound with `var`, can be stepped, can't be reassigned and can't be chosen between with `if` or `match` | let-pipeline-unbuildable, chosen-pipelines |
| `&r.map(f)` holds `&r` as a capture: accessed wherever the pipeline is stepped or passed; `r.map(f)` on a named cursor place is an error | copy-vs-borrow-source |
| A temporary head (`Db.rows(q).map(f)`) needs no `&` | source-by-ref-or-value |
| `C has next -> T uses u ! e`: a requirement with an associated element type and two associated rows, with fundep-style inference of `T` from `C` | next-requirement-assoc-types, next-row-polymorphism |
| A type parameter that may be a pipeline is marked `block C`, inferred on private functions and written on public ones. Its values can't be stored, returned or spawned, and rule A counts them as block parameters | generic-escape-and-rule-a, block-kind-on-generics |
| A pipeline is either copyable, so both copies step `r`, or not, Swift's `~Copyable` too | new: see P4 |
| Rule D: built-in adapters may return a pipeline, by path, as `Scope` and `Task` are exempt | pipelines-second-class-generics |
| A `gen fn` that takes a block or a `block C` gives a pipeline | no-user-adapters |
| A pipeline passed to a call holds its captures for the call; a `for` over one, at each step | instant-exclusivity-scope |
| Release explodes pipeline arguments into block parameters before specializing (SRoA) | fusion-needs-new-specialization |
| Debug gives a pipeline a stack-aggregate layout and gives `next` a dictionary slot | probe-feasibility "debug pipelines" |

### P1 under A

```ren
var r = Fs.line_reader(path)
for line in try &r
  if line == "--- boot ---" then break
var errors = &r.map(parse).select(fn(e) => e.level == Error).take(100)
for e in try &errors           // steps `errors`; `r` is written at each step
  try alert(e)
  if e.fatal then break
for line in try &r             // goes on after the last line `errors` pulled
  Console.print(line)
errors = other                 // error: a pipeline can't be reassigned
```

### P2 under A

```ren
gen fn merge_by<block A has next -> T, block B has next -> T, K>(
    a: A, b: B, key: fn(T) -> K) -> T =
  var a = a                    // a pipeline moved into the generator's frame
  var b = b
  var x = try &a.next()        // `try` on a requirement whose row is a variable: a new rule
  var y = try &b.next()
  loop
    match (x, y)
      (None, None) => return
      (Some(p), Some(q)) if key(q) < key(p) =>
        yield q
        y = try &b.next()
      (Some(p), _) =>
        yield p
        x = try &a.next()
      (None, Some(q)) =>
        yield q
        y = try &b.next()

fn timeline(q: Query, path: Path) -> Array<Event> uses Db, Fs ! DbDown | FsError | BadLine =
  try merge_by(Db.rows(q).map(Event.from_row),
               Fs.line_reader(path).map(parse_event),
               fn(e) => e.at)
    .take(1000).to_array()
```

The call gives a pipeline, since `merge_by` takes blocks. That's legal
because a `gen fn` that takes a block gives a pipeline.

### P3 under A

```ren
gen fn dedup_by<block C has next -> T, K>(src: C, key: fn(T) -> K) -> T =
  var src = src
  var last: Option<K> = None
  for x in try &src
    let k = key(x)
    if Some(k) != last then
      last = Some(k)
      yield x

gen fn scan<block C has next -> T, S>(src: C, init: S, f: fn(S, T) -> S) -> S =
  var src = src
  var acc = init
  for x in try &src
    acc = f(acc, x)
    yield acc

// use: not a method (§7, no UFCS), so a call or a pipe step
for e in try (&r.map(Entry.parse) |> dedup_by(fn(e) => e.code)).take(10)
  ...
```

A also allows the one thing B can't, a **storable** generic adapter over
data cursors:

```ren
type Peekable<C has next -> T> = { src: C, ahead: Option<T> }   // C unmarked: data only
gen fn interleave<A has next -> T, B has next -> T>(a: A, b: B) -> T = ...  // storable
```

### P4 under A

```ren
pub fn index_all<block C has next -> Row ! e uses u>(rows: C) uses Search, u ! SearchDown | e =
  var rows = rows              // or `inout rows: C`, but `&` can't go through `|>` (§8)
  for row in try &rows
    try Search.put(row)

&r.map(parse).select(valid)
  |> try search.index_all
```

The signature has to say four new things: the kind mark, the
associated element type, the error row and the uses row. It also needs
a decision on copying. `var rows = rows` copies a pipeline that holds
`&r`, so two values step one `r`. Either pipelines are `~Copyable`
(moved, as here), or a copy is allowed and steps the same source. Swift
needed `~Copyable` and `~Escapable` both. A needs both too, which
streams.md doesn't mention.

### P5 under A

```ren
// fn errors_since(...) = Fs.line_reader(path).map(...)   // error: a pipeline can't be returned
gen fn errors_since(path: Path, min: Level, since: Time) -> Entry uses Fs ! FsError | Malformed =
  for e in try Fs.line_reader(path).map(Entry.parse).select(fn(e) => e.level >= min && e.at >= since)
    yield e

for e in try errors_since(p, Warn, t0).take(10)   // pushed through `take`, or pulled (see below)
  try alert(e)
```

### Counterexamples under A

- `keep(xs.cursor().map(f))` is rejected, because `keep<C>` returns a
  `C` that isn't marked `block`, and a public `keep` must write the
  mark.
- `drive(..., fn(p) => bump(&n, p))` is rejected by rule A, once `block
  C` parameters count as blocks.
- `consume(pipeline, &limit)` is rejected by the "held for the call"
  rule.

All three are sound, but **only once the kind exists and reaches every
generic signature.**

### A: verdict

- **Sound?** Yes, with all eleven rules above. Without the kind mark it
  isn't (probe-soundness §2a and §2b), and without the copy decision it's
  unspecified.
- **Compiler cost.** The probe-feasibility rows that exist only because
  of A:
  - the `next` requirement: 600–1,000 lines, high risk;
  - second-class through type variables: 600–1,200, high;
  - debug pipelines and `next` dictionaries: 500–900, medium-high;
  - release SRoA or a new key: 500–900, high;
  - per-step exclusivity: 200–400, medium.

  That's **2,400–4,400 lines, mostly high risk**, plus the copy rule.
  It's the size of another 11a stage on top of the shared base.
- **Runtime.**
  - Release: the same as B once SRoA works, which it has to before
    fusion happens at all. Until then, generic sinks take the debug path.
  - Debug: each stage is a shared adapter calling `next` through a
    dictionary slot. That's several indirect calls per item, plus
    frames for the generic adapters, since their uses row is a
    variable.
- **How it reads.** Chains read the same as in B. Signatures read
  worse: `<block C has next -> Row ! e uses u>` is the heaviest public
  signature in Ren, and every generic sink pays it. `var errors`
  reads as "this changes", which is honest.
- **Fit with the ethos.**
  - It widens §3's closed set with the first requirement that has
    outputs. That's the withdrawn "`T has area`" idea for one name.
  - It adds a kind to type variables, which language.md's "not
    clever" list would reject anywhere else.
  - Adapters on every type with `next` are blanket methods (§7).
  - It gives generic code over stored cursors, which §3 says comes from
    blocks instead.
  - Two mechanisms answer "do this for any stream": a requirement for
    the stdlib's adapters and blocks for everything else.

---

## Option B: a pipeline is a block

### The rules

1. **A chain is a block written where the chain is.** Take
   `src.stage(...).stage(...)`, where `src` is a cursor or a pipeline
   and every stage is in the cursor vocabulary. The compiler composes
   it into one literal block of type `fn() -> Option<T>`, with the same
   errors and uses as the steps it calls. A stage's state, such as
   `take`'s counter, `windows`' buffer, `zip`'s pending item or a
   `gen fn` stage's frame, is a **hidden local** of the frame where the
   chain is written, captured by the block like any other local. After
   that it *is* a block: decision 1, rules A–D, the exclusivity table,
   per-block specialization and debug's code and frame pair apply as
   they are.
2. **The source.**
   - `&r.map(f)`, with `r` a named cursor, captures `r` by reference.
     The written `&` says the pipeline steps `r`.
   - `r.map(f)` on a named cursor is an error, with two fix-its:
     `&r.map(f)` steps `r`; `let c = r` then `&c.map(f)` steps a copy.
   - A temporary head, `Db.rows(q).map(f)` or `follow(path).map(f)`,
     needs no `&`. It becomes a hidden local, since nobody else can see
     it.

   So **the missing-`&` error applies only to named places**. That
   covers both `for x in r` and a chain head. `for row in try
   Db.rows(q)` and language.md §11's `for op in conn.ops()` stay legal.
3. **When the source and captures are accessed.** Every row comes from
   the existing table in foundations.md decision 2 and excl.ml:28-30.
   - The `&r` head of a pipeline is accessed like `for x in &r`: a
     write for any `for` over the pipeline, and for any call it's passed
     to.
   - The stage blocks' other captures are accessed as a `let`-bound
     block's captures are: at each call, which is each step of a `for`,
     and for the whole call it's passed to.
   - Between uses, `r` is free.
   - Two `&r` heads over one place in one call conflict, as `f(&r, &r)`
     does. That's the one new sentence.
4. **Binding.** `let p = <chain>` widens decision 1's "a `let` binds one
   literal block" to "one literal block or one chain". Either way, the
   code it runs is known where it's called. `Let_chosen` applies
   unchanged: `if c then a.map(f) else a.map(g)` is an error whose help
   says to choose inside one block. Blocks can't be bound with `var`,
   and nothing needs to be.
5. **Stepping.**
   - `for x in try p` calls `p` until it gives `None`. It needs no `&`,
     because `p` itself never changes; its hidden locals and `&r` do.
   - Stepping one by hand is a call, `try p()`. A second `for` over `p`
     goes on where the first stopped.
   - `for` takes three sources: a collection, a cursor (`&place` or a
     temporary) and a pull block. A pull-block parameter accepts the
     same three, with the same `&` rule.
6. **The vocabulary.**
   - The stages (`map`, `select`, `take`, `zip`, ...) and the sinks
     (`sum`, `reduce`, `to_array`, ...) are the built-in vocabulary of
     the built-in pull type `fn() -> Option<T>`, as `Array`'s methods
     are `Array`'s.
   - On a cursor type, they're reached structurally, as `for` reaches
     `next`.
   - A cursor type that declares a member with a stage's name is an
     error at its declaration, so `.` never has two meanings.
7. **User stages.** A `gen fn` that takes a block parameter (a pull
   source, a key function) gives a pipeline: a block whose state, the
   generator's frame, is a hidden local of the caller. A `gen fn` that
   takes only data still gives a storable cursor. That's the draft's own
   line ("a pipeline for where it's consumed, a `gen fn` for a stream
   that's stored"), applied to the parameters.
8. **Push through one-input stages.**
   - Take a chain whose head is a `gen fn` call and whose consumer is a
     `for` or a built-in sink. Every stage in between is folded into
     the body pushed into the producer's `yield`s.
   - The check is syntactic: it's one chain on one line of code, with
     no flow analysis.
   - Only a pipeline passed to a user function, or a two-input stage
     (`zip`, `merge_by`), pulls the generator. Pulling is a `switch`
     on its state per item, with no allocation, since the frame is a
     hidden local.
   - Promote this from **later** to the plan. The hover shows "pulled"
     where it happens.

There's **no `next` requirement**. A sink is a function with a block
parameter (language.md §3: "a generic algorithm that needs an operation
takes it as a block"). The element type is the block's result. Errors
and uses flow through the block parameter's tail, as `retry`'s `body`
already does (compiler.md:1585-1589, 3593-3606).

### P1 under B

```ren
var r = Fs.line_reader(path)
for line in try &r
  if line == "--- boot ---" then break
let errors = &r.map(parse).select(fn(e) => e.level == Error).take(100)
for e in try errors            // a call per step; `r` is written for the loop
  try alert(e)
  if e.fatal then break
for line in try &r             // goes on after the last line `errors` pulled
  Console.print(line)
for e in try errors            // goes on too: the counter is a hidden local, at 37 of 100
  ...
```

What the compiler writes for the `let`, in Ren terms. Debug builds run
exactly this, as code and a frame:

```ren
var take$n = 0                 // hidden locals of this frame
let errors = fn() =>
  if take$n == 100 then None else
    loop
      match try &r.next()
        None => break None
        Some(line) =>
          let e = try parse(line)
          if e.level == Error then
            take$n += 1
            break Some(e)
```

The flagship example under the draft breaks three rules: `let` on a
call, `&` on a `let`, and `var` on a block. Here it breaks none.
`errors` is a `let`-bound block literal, it doesn't change, and it
writes `r` and `take$n` as captures. That's `let f = fn() => n += 1`,
which 10c step 5 already does.

**Lookahead.** `take_while`, `windows` and `zip` pull one item they
don't yield. With an `&r` head, that item is gone from `r`. Document it
under `take_while`, as Rust documents `by_ref().take_while`. It's
visible because the `&` is on the page.

### P2 under B

```ren
gen fn merge_by<T, K>(a: fn() -> Option<T>, b: fn() -> Option<T>, key: fn(T) -> K) -> T =
  var x = try a()              // `try` on a block parameter's call, as `retry` does today
  var y = try b()
  loop
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

fn timeline(q: Query, path: Path) -> Array<Event> uses Db, Fs ! DbDown | FsError | BadLine =
  try merge_by(Db.rows(q).map(Event.from_row),
               Fs.line_reader(path).map(parse_event),
               fn(e) => e.at)
    .take(1000).to_array()
```

- Both arguments are chains over temporaries, so each is a block with
  its cursor as a hidden local.
- `merge_by` takes blocks, so its call is a pipeline whose frame is a
  hidden local of `timeline`.
- `.take(1000).to_array()` is a chain over that pipeline.
- Rule A: `merge_by` calls `a`, `b` and `key` one after another and
  passes none of them to another, so it's fine.
- The comparator is a block, so programs/04's "Use 3" (merge by
  something other than the type's key) is one argument.
- Release specializes `merge_by` per block, as it does any
  higher-order function, so `a()` and `b()` inline. The only run-time
  cost left is the `switch` on `merge_by`'s state per item. A
  two-input stage can't avoid it in any design; Rust's `merge_by` has
  it as its `Peekable` state.

### P3 under B

```ren
gen fn dedup_by<T, K>(src: fn() -> Option<T>, key: fn(T) -> K) -> T =
  var last: Option<K> = None
  for x in try src
    let k = key(x)
    if Some(k) != last then
      last = Some(k)
      yield x

gen fn scan<T, S>(src: fn() -> Option<T>, init: S, f: fn(S, T) -> S) -> S =
  var acc = init
  for x in try src
    acc = f(acc, x)
    yield acc

for e in try dedup_by(&r.map(Entry.parse), fn(e) => e.code)   // pushed: one loop
  try out.send(e)

let firsts = (&r.map(Entry.parse) |> dedup_by(fn(e) => e.code)).take(10)
for e in try firsts            // pushed through `take` too
  ...
```

These are the same shape as the stdlib's own stages. A one-input user
stage consumed by a `for` or a built-in sink is pushed. Its `yield`
becomes the body, and release inlines `src`, `key` and the body into
one loop. So **a user stage keeps the fused cost**, as Kotlin's
`flow { collect { emit } }` and Effekt's block-taking stream functions
do (`/tmp/ren-refs/effekt/libraries/common/stream.effekt:30, 82, 117`).
Effekt's streams are second-class blocks too. B is Effekt's design in
pull form, with `fn() -> Option<T>` in place of `() => Unit / emit[A]`.

User stages aren't methods (§7), so they're a call or a `|>` step, and
going on with `.take` after a `|>` needs parentheses (§8, "a chain ends
its expression"). The same holds under A. It's §7's price, not B's.

### P4 under B

```ren
pub fn index_all(rows: fn() -> Option<Row>) uses Search ! SearchDown =
  for row in try rows          // rows' own errors and uses flow through its tail
    try Search.put(row)

&r.map(parse).select(valid)
  |> try search.index_all      // a block goes through the pipe; the `&` is on the head

try search.index_all(Db.rows(q))   // a temporary cursor where a pull is expected: no `&`
try search.index_all(&r)           // a named cursor: `&` says it's stepped
```

- The public signature is an ordinary block parameter. It has no kind
  mark, no associated type and no row syntax, and the existing rule
  covers "C's next's errors".
- `rows` is an ordinary-mode block parameter, so rule B already forbids
  `index_all` from handing it to a task or a concurrent parameter.
  That makes probe-soundness §3's "`Async.map` steps its cursor
  serially on the caller's task" **checked, not just stated**:
  `Async.map(src: fn() -> Option<T>, max: Int, f: concurrent fn(T) ->
  U)` can't pass `src` to `spawn`.
- §8 says "no `&` through a pipe". Here the value through the pipe is a
  block whose head says `&r`. Because the `&` is written on the head,
  the pipe stays a pipe of values. It's still worth one sentence in §8.

### P5 under B

```ren
gen fn errors_since(path: Path, min: Level, since: Time) -> Entry uses Fs ! FsError | Malformed =
  for e in try Fs.line_reader(path).map(Entry.parse).select(fn(e) => e.level >= min && e.at >= since)
    yield e

for e in try errors_since(p, Warn, t0).take(10)       // pushed through `take`: one loop, nothing allocated
  try alert(e)

let first = try errors_since(p, Warn, t0).take(10).to_array()   // a built-in sink: pushed too

try search.index_all(errors_since(p, Warn, t0).take(10))      // passed to a user function: pulled
```

- The helper is a `gen fn`, as in the draft. It's mechanical, and the
  fix-it writes it.
- With rule 8, the two ordinary consumers keep the fused cost.
- Only handing it to a user function pulls it. That's a state machine
  with one `switch` per item, no allocation and no box, since its frame
  is a hidden local. The hover says so.
- That's the cliff the ethos probe found, cut down to "passed to your
  own function". It could be removed only by specializing a pull into a
  push through the callee, which is flow analysis.

### Counterexamples under B

All three are rejected by checks that exist today, with no new rule:

```ren
let p = keep(xs.cursor().map(fn(x) => x + k))
// error (check_blocks): a type variable is never given a block's type, since `T` could be stored

drive(xs.cursor().map(fn(x) => n += 1; x), fn(p) => bump(&n, p))
// error (check_blocks): `drive<C>`'s `C` would be given a block's type. Written without
// generics, `drive(c: fn() -> Option<Int>, k: fn(fn() -> Option<Int>))`, then `k(c)`
// passes a block parameter to a call of a block parameter: rule A, as written today

consume(xs.cursor().select(fn(x) => x < limit), &limit)
// error (decision 2): the block reads `limit` for the call; `&limit` writes it
```

### B: verdict

- **Sound?** Yes, by construction: a pipeline is a block, and every
  block rule is already checked. There are two new sentences, the `&r`
  head row and two heads over one place conflicting. Both are
  restrictions, not relaxations. Hidden locals have no names, so no
  program can touch them except through the block.
- **Compiler cost.** My estimates, from probe-feasibility's figures for
  the pieces B keeps:
  - chain composition into one literal block with hidden locals, in
    sema and lowering: 500–800 lines, medium;
  - the `&` head as a capture, `Let_chosen` for chains, `for` over a
    pull block, a cursor where a pull is expected: 150–300, low;
  - a `gen fn` with block parameters as a pipeline, its frame a hidden
    local (a non-counted frame): 300–600, medium, on top of the gen
    machinery;
  - push through one-input stages: 200–400 over the base push pass.

  That's **1,150–2,100 lines, mostly medium risk**, against A's
  2,400–4,400, mostly high. Release fusion is the existing per-block
  specialization (specialize.ml keys block *parameters*, and every
  pipeline reaches a sink as one). Debug is the existing code and frame
  pair. Decision 13's partitions are handled as for any higher-order
  function.
- **Runtime.**
  - Release: one loop for chains, pushed `gen fn`s and user one-input
    stages. A `switch` per item for two-input stages and pulled
    generators. Nothing is allocated except by a recursive `yield
    from`, which uses the task's frame allocator.
  - Debug: one indirect call per item into the composed block, with the
    stages inline in it. That's cheaper than A's shared adapters with
    dictionary calls.
- **How it reads.**
  - The chain reads exactly as in the draft.
  - `let errors = &r.map(...)` and `for e in try errors` read as "a
    thing that steps `r`".
  - Sinks have the plainest signatures in the language.
  - What's different: hand-stepping is `p()`, not `&p.next()`. A user
    stage is a call or a `|>` step, as under A.
- **Fit with the ethos.**
  - One mechanism per question: "do this for any stream" is a block,
    which is §3's answer. §3's closed set doesn't grow.
  - Nothing behind your back: the `&` is written where `r` is stepped.
    The hidden locals are as visible as `for`'s index, and are what the
    chain says (`take(100)` holds a count).
  - The obvious way is the fast way, for chains, helpers consumed by
    `for`, and user stages.
  - Complexity sits in the compiler (composition, push), not in
    signatures.
  - One exception stays, shared with A: stage names are reached on
    cursor types structurally, as `for` reaches `next`. Rule 6 makes it
    an error to shadow them.

### What B gives up

- **Storable generic adapters over data cursors.** That means a record
  `Peekable<C>` that wraps *any* cursor and is kept, or a stored `merge`
  of two stored generators of unknown type. Under B, a generic adapter
  takes a pull block, so its result is a pipeline, never stored.
  Storing means a `gen fn` written for its types, which is
  foundations.md's "What's given up" as it stands, narrowed to stored
  adapters only.
  - None of the ten paper programs needs it.
  - programs/09 stores a concrete `errors_since`, which works.
  - programs/10 streams inside an actor's arm over a concrete cursor,
    which works.
- **Choosing between two pipelines** with `if` or `match`. That's the
  same under A, by the same rule.
- **`.next()` on a pipeline.** It's `p()`. If the owner wants the
  method spelling, `p.next()` can be the pull type's one member that
  means "call". That's cosmetic.

---

## Option C: pipelines are syntax, never values

A chain may appear only as a `for` source, as the receiver of a
built-in sink, or as the argument of a built-in stage. It can't be
bound with `let`, passed to a user function, or given to a `gen fn`.
This is the "shrink the feature" option from probe-ethos
(block-kind-on-generics).

```ren
// P1: no `let errors`; the loop is written where the chain is
var r = Fs.line_reader(path)
for line in try &r
  if line == "--- boot ---" then break
for e in try &r.map(parse).select(fn(e) => e.level == Error).take(100)
  try alert(e)

// P2: merge must take data cursors, so each transform is its own gen fn (programs/04 as written)
gen fn row_events(q: Query) -> Event uses Db ! DbDown =
  for r in try Db.rows(q)
    yield Event.from_row(r)
// ... log_events likewise; merge<A, B> needs `next` on A and B, so the requirement is back

// P3: impossible lazily: dedup_by can't take a block or a chain
// P4: index_all can't take a chain; write the loop inline, or `.to_array()` first (eager)
// P5: as A and B
```

- **Sound?** Yes, trivially.
- **Cost:** the smallest, about 400–700 lines, but `merge` over cursors
  still needs either `next` as a requirement or a `gen fn` for each pair
  of types.
- **How it reads:** fine for the common loop. It fails the paper
  programs at P2, P3 and P4: user stages, generic sinks and
  `merge_by`.
- **Ethos:** "the obvious way is the fast way" holds only for chains
  that stay in one function.

C is what B collapses to if decision 1's `let` isn't widened to chains.
B costs about twice as much and is strictly more expressive, and its
extra cost is the hidden-local composition that C needs anyway for
`take`'s counter. **C is rejected.**

---

## Side by side

| | A: new block kind | B: a block | C: syntax only |
|---|---|---|---|
| Source | `&r.map(f)` held as a capture | the same | the same, `for` only |
| `r` after `break` | advanced, lookahead lost | the same | the same |
| `&` error | named places only | named places only | named places only |
| Flagship `let errors` | `var errors`, a new binding rule | `let errors`, decision 1 widened to chains | not expressible |
| User lazy stages | `gen fn` over `block C has next`, fused when pushed | `gen fn` over `fn() -> Option<T>`, fused when pushed | none |
| `merge_by(rows.map(f), logs.map(g), key)` | yes | yes | no |
| Generic sink signature | `<block C has next -> Row ! e uses u>(rows: C)` | `(rows: fn() -> Option<Row>)` | none |
| Helper with `.take(10)` in a `for` | fused with push-through | fused with push-through | fused with push-through |
| Storable generic adapter over any cursor | yes | no (written for its types) | no |
| `next` requirement | yes, with outputs and rows | no | needed for `merge` |
| Kind on type variables | yes, inferred and written | no | no |
| Copyability of pipelines | must be decided (`~Copyable`) | not a question: blocks aren't copied | n/a |
| Release fusion | needs SRoA or a new key | existing per-block specialization | existing |
| Debug ABI | new aggregate layout and `next` slots | code and frame, existing | code and frame |
| New compiler, beyond the shared base | 2,400–4,400 lines, high risk | 1,150–2,100 lines, medium | 400–700 lines, low |
| §3 closed set | widened | unchanged | widened, or `merge` lost |

---

## The recommendation, as amendments to streams.md

**Change.** "Pipelines: a value that holds a block is a block" becomes
**"Pipelines are blocks"**:

- A chain over a cursor is a block, `fn() -> Option<T>`, that the
  compiler writes where the chain is. A stage's state is a local of
  that frame, and the block captures it.
- It's bound with `let` (decision 1: one literal block *or one chain*),
  looped over without `&`, called to step it by hand, passed to a block
  parameter, and never stored, returned or chosen between. Rules A–D,
  exclusivity, specialization and debug code and frame apply as they
  are.

**Change.** The source rule:

- `&r.map(f)` steps `r`, which is held as `for x in &r` holds it,
  wherever the pipeline is looped over or passed.
- `r.map(f)` on a named cursor is an error with two fix-its.
- A temporary head needs no `&`.
- After a `break`, `r` has advanced by what the pipeline pulled,
  lookahead included.
- Two `&r` heads over one place in one call conflict.

**Change.** "`for x in c` without `&` is an error on a cursor" applies
only when `c` is a named place.

**Drop.** "`next` joins the built-in requirements". A sink takes `rows:
fn() -> Option<T>`, and its errors and uses flow as a block
parameter's do. The stage and sink vocabulary is built into the pull
type and reached structurally on cursor types, as `for` reaches `next`.
A cursor type can't declare a member with a stage's name.

**Change.** "A `gen fn` can't take a block" becomes: **a `gen fn` that
takes a block gives a pipeline**, its frame a local of the caller. A
`gen fn` that takes only data gives a storable cursor. This is how
users write `dedup_by`, `scan` and `merge_by`, and the compiler error
for a `gen fn` with a block goes away.

**Change.** "Exclusivity, step by step" says nothing new. It's the
existing rule for a `let`-bound block, whose captures are accessed
where it's called, and a `for` calls its source at each step. Passed to
a call, a pipeline holds its captures for the call, as any block does.

**Change.** Move **push through one-input stages** from Later into the
plan. Only a two-input stage, or a pipeline passed to a user function,
pulls a generator, and the hover says where.

**Change.** In "What it changes": rule D and §3 rows are no longer
amended. Add a row for decision 1: "a `let` binds one literal block or
one chain".

**Keep.** "A pipeline that must be stored, returned or given to a task
is a `gen fn`" and "the line is the error that enforces it".

### Decisions for the owner

1. **B over A?** The trade: B gives up storable generic adapters over
   any cursor, such as a `Peekable<C>` kept in a record. A buys them
   with a requirement with outputs, a kind on type variables and a
   copy rule, about 2,400–4,400 lines of high-risk work.
2. **Spelling of the source.** `&r.map(f)`, with a plain `r.map(f)` an
   error, is recommended. The alternative is to infer the `&` with a
   fix-it, which is quieter but means a write of `r` that isn't on the
   page.
3. **A cursor where a pull block is expected.** Accept `&r` and
   temporaries, the same rule as `for` (recommended). The alternative
   is an explicit identity stage, `&r.pull()`, which avoids the
   type-directed acceptance at the cost of a word.
4. **Shadowing stage names.** Make a cursor type declaring `map`,
   `count` or another stage name an error (recommended), or let its own
   member win. Under A too, this has to be decided.
5. **Lookahead loss.** `take_while`, `windows` and `zip` over an `&r`
   head consume an item they don't yield. Document it (recommended), or
   give those stages a peek on the source, which needs more than `next`.
6. **Recursive `yield from` in a `gen fn` that takes a block.** Allow
   it with frames from the task's allocator, or forbid it until a
   program needs it (recommended: forbid at first; no paper program
   needs it).

# Probe: does streams.md fit the ethos?

Read against language.md (the ethos, §1, §3, §7, §8), foundations.md
(the bet; decisions 1, 2, 5, 6, 11, 12, 17; "What's given up"), async.md
(channels) and stdlib.md ("Streams: cursors first"). The draft is
treated as a candidate, not as decided.

## Verdict in one paragraph

The core idea is right and fits Ren well: there's one kind of stream,
the cursor; colors are absent because of `uses`; producers are `gen fn`;
time comes from `Clock`; there's no comprehension syntax, no Emit dep,
and no hot streams or schedulers. Five things break as written, and each
one hits a rule the ethos depends on:

1. cleanup that runs when a cursor is dropped;
2. how a pipeline holds the cursor it reads;
3. what "a value that holds a block is a block" costs the type system;
4. channels used as values;
5. what copying a cursor means.

Four more are real design problems:

- the receiver-decides rule makes the obvious Array chain the slow one;
- `next` as a requirement also brings blanket methods (UFCS for
  cursors), which §7 forbids;
- push and pull have a cost cliff at the first `.select`;
- `Async.map_pull` and the operators in `stream.time` each hide a task
  scope.

## Decision by decision

| Decision | Fit | Severity |
|---|---|---|
| A value that holds a block is a block | Right idea, but it needs a kind on type variables that the draft doesn't admit to | breaks (B3) |
| The receiver decides eager or lazy | Names are shared, but cost, effect order and where `try` goes all depend on an inferred type | major (M1) |
| `next` joins the built-in requirements | A requirement that carries effects and errors, plus blanket methods | major (M2) |
| The compiler picks push or pull | Fits the bet (representation is the compiler's choice), but there's a cost cliff | major (M3) |
| `for x in c` without `&` is an error on cursors only | The reason given is wrong for id-backed cursors, and it collides with `let` pipelines | breaks (B2, B5) |
| Resource state in services, ids in cursors | Fits "never hold an instance", but copying and cleanup don't follow from it | breaks (B1, B5) |
| `gen fn` as the only producer | Fits (no Emit), but "the one way" is overstated | minor (m2) |
| Async.produce vs channels vs gen fn | One mechanism, the cursor, if channels stay deps | breaks (B4) |
| Async.map_pull | Hides a scope, and the step-by-step exclusivity doesn't hold for it | major (M4) |
| stream.time | Taking time from `Clock` fits; the operators that need tasks hide a scope | major (M4) |
| No comprehension syntax | Fits. Keep | none |
| Pipelines with `.` vs `\|>` | Good split, but `.` on every type with `next` is UFCS | major (M2) |

---

## Breaks

### B1. Cleanup when a cursor is dropped contradicts decisions 11 and 12

The draft says (§Cleanup): "A `finally` that runs at a drop can call
dependencies: flush a socket, close a file", and it argues that "the
drop point is the end of a scope you can see".

foundations.md decision 11 says: **"Resources are closed in a `finally`
or an operation, never when a count reaches zero."** A Perceus drop is
a count reaching zero, so the draft does exactly what decision 11 rules
out. The rule exists for determinism and replay: a drop isn't a
journalled poll point.

It gets worse once a cursor is stored, which `gen fn` allows on purpose:

```ren
type Job = { id: Int, src: Lines }        // Lines: a gen fn's cursor, uses Fs

fn retire(jobs: Array<Job>, id: Int) -> Array<Job> =   // pure: no uses
  jobs.reject(fn(j) => j.id == id)        // drops the last ref to j.src -> runs `f.close()`
```

- **Decision 12:** only a function whose `uses` reaches a dependency can
  suspend. `retire` is pure, but the drop runs a `finally` that uses
  `Fs`, so it would have to suspend in a function with no frame for it.
  The only way out is to put the cursor's `uses` into every function
  that might drop one. Then a record that holds a cursor makes every
  function that touches it effectful, and that's an effect found
  behind your back.
- **Which handler?** Under decision 5 the `finally`'s `Fs` would be the
  one in force at the drop site. That could be a test fake or a
  different `with` from the one that opened the file.
- **Errors.** The `finally` can fail, since a close or flush can fail.
  A drop has no `try`, so ethos rule 3 ("say what can go wrong, where
  it can") has nowhere to put the error. Actors already settled this in
  decision 18: "`finally` can't fail".
- **Cancellation.** A drop inside a cancelled task's unwind would need
  its own shielded cleanup deadline, and nothing marks where.

**Suggestion.** Keep the two cases the draft gets right, a `finally` on
loop exit (finishing, `break`, `return`, a failure) and one on
cancellation, because both happen at syntax you can see: the `for`.
Drop the third case and pick one of these:

- **(a) A dropped generator runs only a `finally` that's pure.** A
  `finally` in a `gen fn` that uses a dependency is allowed only when
  the generator's cursor isn't stored or returned, so it's consumed by
  a `for` in the scope that made it. A stored cursor that owns a
  resource has to put the resource in the service (B5): the file is
  closed by its handler's `finally` when the `with` ends, as decision 11
  says.
- **(b) Ownership goes to the service.** `Fs.open` registers the handle
  with the `Fs` handler instance. A generator's `finally` is pure
  bookkeeping, and the handler closes whatever is still open at the end
  of its scope. This is "ids in cursors, state in services" carried
  through to cleanup, so it's the more Ren-shaped choice.

The current text about Swift's worry ("it's explicit where it's
written") answers the question for the producer's author but not for
the reader of the code where the drop happens. "Nothing found behind
your back" is about the reader.

### B2. How does a pipeline hold its source? `let` and `&` contradict decision 1

The flagship example:

```ren
var r = Fs.line_reader(path)
let errors = r.map(parse).select(fn(e) => e.level == Error).take(100)
for e in try &errors
```

- Decision 1 says "Blocks can't be bound with `var`, and a `let` binds
  one literal block." `errors` is a block (by the draft's own rule) that
  is bound with `let` to a *call result*.
- `&errors` is a write access to a `let`. `next(inout self)` needs a
  place it can change, and a pipeline can't be `var`.
- **The draft never says whether `r.map(parse)` copies `r` or borrows
  `&r`.** That question decides the semantics the draft opens with:

  ```ren
  var r = Fs.line_reader(path)
  for x in &r.map(parse)
    if x.done then break
  for line in try &r          // does this go on after the last x, or start over?
  ```

  - If the pipeline holds a copy, a `pread` file reader starts over,
    while a socket cursor, which holds only an id, goes on (see B5).
    The same program means two different things depending on where the
    cursor keeps its state.
  - If it holds `&r`, then a pipeline holds a write access over an
    interval that runs from the `let` to its last use. Rule 2 takes its
    intervals only from syntax (a call, a loop, a scope), and this one
    isn't fixed by any of them.

**Suggestion.** A pipeline borrows its source in place: building it
takes `&r` as a write, which lasts until the end of the scope of the
`let` that binds it (or, for a temporary, until the end of the `for`).
Both of those are fixed by syntax. A `for` over a pipeline needs no
`&`, because nothing can observe a copy of a value that can't escape.
The `&` error then applies only to a *place* whose type is a cursor that
can be stored. That keeps decision 1's `let` rule ("a `let` binds a
block") once it's widened from "a literal" to "a block expression", and
it settles what happens to `r` after a `break`: it stops where it
stopped, which is the property the cursor section sells.

The same issue shows up on temporaries: `for x in &xs.cursor().select(...)`
and `for chunk in try &f.chunks()` put `&` on an rvalue. Requiring `&`
there is noise.

### B3. "A value that holds a block is a block" needs a kind on type variables

The draft says "Its type says it holds a block, so the checks are the
ones blocks already have." They aren't the same checks. Rule D is
checked from signatures because scopes and task handles have *known*
types. Pipelines flow through generics:

```ren
fn first_two<C>(c: C) -> (C, Int) = (c, 2)     // fine for an array cursor
let p = first_two(xs.cursor().map(f))           // now returns a block in a tuple

fn take<C has next>(c: C, n: Int) -> Take<C>   // storable iff C is
```

- `take` takes no block, but `xs.cursor().map(f).take(5)` holds one.
  "A cursor's methods that take a block return a pipeline" isn't the
  real rule: being a block passes through every generic container and
  adapter.
- So every type variable needs a kind that says "may be a block", and
  every generic signature that stores or returns a `T` must say whether
  it accepts a block for `T`. That kind has to be inferred inside a
  module and written at its boundary.
- This is Swift's `~Escapable` (SE-0446), which suppresses a capability
  on generic parameters
  (`/tmp/ren-refs/swift-evolution/proposals/0446-non-escapable.md:117-132`)
  and needed SE-0465 and SE-0516 to get through the standard library
  (`0516-borrowing-sequence.md:68`, `protocol Iterable: ~Copyable,
  ~Escapable`). It's a kind with an order between its two values,
  which the "Not clever" line (no subtyping) should at least have to
  acknowledge.

**Suggestion.** Choose one, and write it into the draft:

- **(a) Own it.** Type variables get one inferred bit, *escapes*, which
  is false by default for parameters and true for anything stored or
  returned. Instantiating a variable whose bit is true with a block type
  is the existing "can't be stored" error, reported at the call. The
  check is still one walk, but the bit has to be carried in schemes like
  requirements, and the draft should say that plainly.
- **(b) Shrink it.** Pipelines are not first-class types. A pipeline
  can only appear as a chain written in a `for`'s source, in a
  consumer's receiver (`.sum()`), or as the argument to a parameter
  whose type is marked as a pipeline. It can't be bound to a generic
  `T`. That's much less power (no `first_two`, no `let` pipelines passed
  through generic helpers), but it's checked from syntax, as rule D is
  today.

(b) matches "one walk from syntax" best. (a) is what the draft's
examples already assume.

### B4. Channels are dependencies, not values

foundations.md decision 6 and async.md define a channel as `dep Chan<T>`,
installed with `with channel(cap) as Jobs`, and called as `Jobs.recv()`.
The bet: "The programmer never holds an instance." The draft treats a
channel as a value in two places:

```ren
for m in &inbox                                   // inbox is a handler instance held as a value
Async.produce(cap: 16, fn(out) => crawl(root, out))  // out: a sender, held and passed
```

As written, both contradict "held instances" in "What's given up".

**Suggestion.** Keep channels as deps, and make the cursor the thing
that's held. That's the draft's own rule, "ids in cursors, state in
services", where the id is the dependency's name:

```ren
for m in Jobs.messages()                 // stdlib gen fn: loop { match Jobs.recv() ... }

Async.produce(cap: 16, fn() uses Send<Page> => crawl(root)) fn(pages) =>
  for p in try pages
    try index(p)
// crawl(root) uses Send<Page>: Send.put(page)
```

The producer's block gets `Send<Page>` from `Async.produce` under
decision 5 ("except those listed in its parameter's type, which the
callee provides"). This is better than `out` in a second way: `crawl`
says in its `uses` that it emits pages, which is the Emit dependency the
draft rejected, now in the one place where it isn't a second way to
write a producer.

### B5. Copying a cursor means three different things

The draft keeps copies as values (no affine types), and states:

- a socket cursor's copy is an alias, because both copies hold one
  connection id;
- a `pread` file reader's copy is independent;
- "a generator's cursor copies like any value".

Now consider a `gen fn` over a socket, which is the common case
(`lines(conn)`, framed protocols):

```ren
gen fn frames(c: Conn) -> Frame uses Net ! NetError =
  var buf = Bytes.empty()
  finally Net.shutdown(c)
  for chunk in try Net.chunks(c)      // id-backed
    &buf.append(chunk)
    ...yield...

var a = frames(conn)
let first = try a.next()
var b = a                 // copies the frame: buf duplicated, socket shared
try a.next(); try b.next()   // each consumes bytes the other's buf never sees
```

- **The copy only partly aliases.** The local buffer forks, but the
  socket is shared, so both copies decode garbage. This is worse than
  either pure answer.
- **The `finally` is duplicated.** Perceus copies the frame on the
  first `next` through a shared reference, because `inout` on a counted
  value triggers copy-on-write. That leaves two frames, each with a
  pending `finally`, so `Net.shutdown(c)` runs twice.
- **The argument for the `&` error goes backwards.** The draft says
  `for x in c` "stepped a copy and left `c` at the start, which is …
  wrong for a socket". For an id-backed cursor, stepping a copy
  *consumes the socket*. So the hazard is real, but it's the opposite of
  the one described. RFC 3550 is about `Range`, a pure value, so it
  supports the error only for value-backed cursors.

**Suggestion.** "Nothing found behind your back" needs one meaning for
copying a cursor. Two options, in the shape Ren likes:

- **(a) A cursor that can be stored is a value, and only values.** A
  `gen fn` frame that holds a resource id or a pending `finally` that
  uses a dependency is a different kind of cursor: it can be moved
  (stored, returned, given to a task) but not copied. The compiler
  checks this with the same bit as B3. That's affine typing for one
  kind of value, which foundations rejected in general; say so if
  chosen.
- **(b) The state of every resource lives in the service, buffers
  included.** `Net.chunks(c)` and `frames(c)` are written so that all
  state that changes, buf included, lives under the connection id in
  `Net`, as a framed reader the runtime keeps. Then a copy is an honest
  alias everywhere, a cursor over a resource holds only ids and its
  `finally` is pure (B1, option b), and the `&` error's reason becomes
  "a copy of an id-backed cursor shares its position; write `&` to say
  you're stepping it". That requires a buffered, framed read operation
  in the standard library (formats.md's framing belongs there anyway),
  and it's the rule the draft already states for anyone writing a
  cursor over a resource. The draft just doesn't follow it for `gen fn`.

(b) is more consistent with the bet ("never hold an instance").

---

## Major

### M1. The receiver decides: the obvious Array chain is the slow one, and the type that decides is inferred

```ren
let t1 = orders.select(fn(o) => o.paid).map(Order.total).sum()          // 2 arrays allocated
let t2 = orders.cursor().select(fn(o) => o.paid).map(Order.total).sum() // 0
```

Ethos rule 4 says the obvious way is the fast way. With collections as
the common receiver, the first form, which everyone writes first, is
the slow one, and the draft's own point 8 ("the pipeline you'd write
first is the one that allocates nothing") fails on arrays.

The same text also means different things depending on a type that is
**inferred inside a module**:

- **Effect order.** On an array, every `map` runs before the first
  `select`. On a cursor they interleave. If the blocks use a dependency
  (`urls.map(fetch)`), the journal differs.
- **`try` placement.** Eager `try xs.map(parse)` marks the failure at
  the call. Lazy `r.map(parse)` has no `try` there; it shows up at the
  `for`. When a source is refactored from `Array<Str>` to
  `Fs.line_reader`, nothing errors, `try`s move, and effects reorder.
  Elixir avoids this by making the module (`Enum` or `Stream`) visible at
  the call, and that's the part of Elixir's design that matters here.

**Suggestion.** Keep the shared names, and make eager chains on
collections *fuse when it can't be observed*: when every block in the
chain uses no dependency and writes no captured place (the compiler has
both facts from rows and from exclusivity), `xs.select(p).map(f).sum()`
compiles to one loop. Eager semantics with lazy cost is "representation
is the compiler's choice", the bet itself. Then `.cursor()` is needed
only for laziness that *is* observable (effects, infinite sources,
`take` before something expensive). Add a hover or `ren review` note
when a chain mixes effects and laziness.

### M2. `next` as a requirement brings two things the draft doesn't name

1. **It's the first requirement any user type meets by declaring a
   method with that name.** `==`, ordering, `hash`, `show` and the
   arithmetic are compiler-known operations. `next` is the
   "`T has area`" idea that language.md §3 *withdrew*, used for one
   name. It's also the first requirement that **carries effects and
   errors**: `take<C has next>` has to inherit `next`'s `uses` and `!`
   row. That means requirements get variables for the effect row and the
   error row, and debug dictionaries hold functions that can suspend.
   That's a real extension to R4, not just one more name.
2. **Blanket methods.** `r.map(parse)`, where `r: Lines` is a user type
   with a `next`, calls a method that `Lines` doesn't declare. §7 says
   "No UFCS. `.` reaches only the type's own members" and "no adding
   methods to someone else's type". Under the draft, about 25 standard
   library methods appear on every type with a `next`. And if the user's
   type declares its own `count` or `take`, which one wins?

**Suggestion.** Make the cursor a **built-in type constructor** and
not a requirement. It fits the closed world (decision 4):

- `Cursor<T> uses E ! X` is what `gen fn`, `xs.cursor()`, `Jobs.messages()`
  and the standard library's resource readers return. The adapters are
  methods of that built-in type, so §7 holds, and `.` still means "this
  type's own vocabulary".
- A user type with its own `next` keeps working with `for`, structurally,
  as it does today, and becomes a `Cursor` through a one-line `gen fn`
  or `c.cursor()` when it wants the adapters.
- The compiler already knows every kind of `Cursor` (it wrote them), so
  specializing is the same as for `gen fn` frames. §3's closed set
  doesn't grow at all.

If the draft keeps `next` as a requirement, it should at least say both
consequences outright: requirements that are polymorphic in effects, and
methods on every cursor that break the no-UFCS rule.

### M3. Push or pull: invisible, which fits the bet, but there's a cost cliff

Choosing push or pull without showing it fits "representation is the
compiler's choice". It's semantically clean, because `finally` runs at
the same point either way for a cursor that's a temporary in a `for`.
The cost isn't clean:

```ren
for n in walk(t)               // pushed: no frames, no allocation
  if n.big then visit(n)

for n in walk(t).select(fn(n) => n.big)   // pulled: a state machine, one boxed child per level
  visit(n)
```

The second is the "obvious" pipeline form, and it's the slow one.
"Fusion through a `gen fn`" is listed under **later**, but it decides
whether rule 4 holds, so it belongs now. It's also simple: every
one-input stage (`map`, `select`, `reject`, `take`, `take_while`,
`skip*`, `with_index`, `flat_map`, `chunks`) can be pushed by inlining
the stage into the body at the `yield`. Only `zip`, and a pipeline bound
by `let` that is stepped by hand, need pull. **Suggestion:** pushing
goes through one-input stages from the start, and `ren profile` or hover
says "pulled: zip" where pull was forced.

### M4. `Async.map_pull` and the task-based `stream.time` operators hide a scope

`Async.map_pull(src, max: 16) fn(x) => ...` "gives a cursor of results".
The tasks it runs need a scope, and the draft says that scope is
*somewhere*: inside the cursor, which by rule D makes the cursor a
block. So:

- It can't be stored or returned (fine), but **where are the tasks
  cancelled and waited for?** At the cursor's drop. That's B1 again,
  with cancellation and joining instead of a close.
- **Step-by-step exclusivity doesn't hold.** Its block runs
  concurrently with the consumer's body, so the "an instant" argument
  (`next` alternates with the body on one task) fails. The block is a
  concurrent parameter (rule B) whose read lasts as long as the
  *consumer's loop*. Nothing in the syntax delimits that.
- `debounce`, `throttle`, `batch(within:)`, `sample` and `merge` all
  wait on "the next item **or** a timer". In a pull model, cancelling a
  source's `next` partway kills a generator. So each of these has to
  pull ahead on a task, which is `Async.produce` underneath, and each
  hides a scope in the same way.

**Suggestion.** Every operator that needs tasks takes the shape
`Async.produce` already has: a body block that gives the consumer
something to bracket.

```ren
Async.map_pull(urls.cursor(), max: 16, fn(u) => fetch(u)) fn(pages) =>
  for p in try pages
    ...

stream.time.debounce(events, Duration.ms(200)) fn(settled) =>
  for e in settled ...
```

The scope's start and end are then on the page, rule C's "frame that
calls `Async.scope`" is the operator's call, and exclusivity is the
ordinary concurrent-parameter rule over that call. Only pure,
single-task stages stay as `.` methods. That also answers "how many
ways": **every concurrent stream is a `produce` shape**, so there's one
spelling for "this stream has tasks behind it".

---

## Minor

### m1. Four questions: streams add a row, and the draft should say so

Streams mostly reuse existing rows. Adapters are "do this for any type?
→ a generic function and a block", and `Async.each` and `Async.map` are
"work alongside other work?". But a sequence that arrives over time
isn't any row in §1's full map, and the cursor is a new kind of thing
by the held-or-given test: it's held (data), while a pipeline is
neither held nor given, it's *passed down*, as blocks are. Suggested
row for the full map in §1:

| Question | Mechanism |
|---|---|
| Items that arrive over time? | a cursor (`for x in c`), written with `gen fn`; transformed with `.` where it's consumed |

It belongs in the bottom half: eager or lazy, and push or pull, are
questions of cost, and changing them shouldn't change what the program
means (M1's suggestion makes that true).

### m2. "`gen fn` is the one way to write a producer" is overstated

Hand-written types with `next` remain, and the draft relies on them for
resource cursors (the socket's connection-id cursor, the `pread`
reader). Then there's `xs.cursor()`, `Async.produce`, and the channel's
cursor. That's fine: there's one *mechanism* (the cursor), with `gen fn`
as its control-flow sugar. Say that instead. Under M2's suggestion it
becomes exactly true: a user type with a `next` works with `for`, and
`gen fn` is how you get a `Cursor`.

### m3. Async.produce vs channels vs gen fn: the answer is fine, once B4 is fixed

- `gen fn`: a producer on the consumer's task.
- `Async.produce`: a producer that needs tasks; it's sugar for a scope,
  a channel and a cursor over it, with cancellation at the body's end.
- A channel: a queue that a program writes on purpose, which is a
  service.

Those are three answers to three questions, not three ways to answer
one. Keep all three, with the spelling from B4.

### m4. `Async.map`'s limit: one call, two defaults

foundations.md decision 7 says the default is 64 "as `Async.map`'s is".
The draft makes `max:` required on a cursor. Either the default holds
for both (a cursor is pulled only when a slot frees, so 64 is just as
safe), or it's required for both. Having the receiver decide the
defaults too is another case of M1.

### m5. Errors from lazy stages show up at the `for`, not where they happen

`r.map(parse)` with a `parse` that can fail has no `try` at `map`. The
`try` is at `for x in try &errors`. §8 wants a `try` on the step that
can fail. That's defensible, because the stream stops where it's
pulled, but the draft should say it on purpose and teach it in the
error: "`next` can fail with `ParseError` (from the `map` on line 12)".

### m6. "No other language can test `debounce` without virtual time" is too strong

RxJava's `TestScheduler`, kotlinx-coroutines-test's `runTest` (with
virtual time built in), and Effect's `TestClock` all do it with a library
for virtual time. What Ren has that they don't is that it's *the same
`Clock`* in production and in tests, and the journal replays it. Claim
that.

---

## Keep as written

- **No comprehension syntax.** A `for` with a `yield` in a `gen fn` is
  the comprehension, and a second spelling would break "one mechanism
  per question".
- **`.` for stages, `|>` for workflow steps that take a pipeline.** It's
  the right division, once M2 makes `.` honest.
- **No Emit dependency.** But see B4: a `Send<T>` dependency inside
  `Async.produce` is the one place emit-style belongs.
- **Resource state in services and ids in cursors.** It's the right
  principle, and the strongest fit with the bet in the draft. B1 and B5
  only ask that it be followed through to cleanup and to `gen fn`
  frames.
- **The `yield` ban inside `scope`, `timeout`, `with` and `finally`.**
  PEP 789 caught at compile time, with no new concept added.
- **Time from `Clock`, and the left-out list** (hot flows, schedulers,
  error operators).
- **Step-by-step exclusivity for single-task stages.** It's correct as
  long as it's restricted to stages that run on the consumer's task
  (see M4), and it should go into decision 2's table as a new row: "a
  block held by a pipeline: each captured place, as the block uses it,
  for each `next`".

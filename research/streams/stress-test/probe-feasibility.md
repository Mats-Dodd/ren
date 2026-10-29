# Probe: can streams.md be built?

Read against the compiler as it stands (lib/sema, lib/lower, lib/eval,
lib/native) and against foundations.md decisions 1, 2, 11, 12, 13, 14.
Read only; nothing was run.

## Short answer

Most of it can be built, and the hard parts are in different places
from where the draft puts them. The draft treats three things as
one-liners that are each a real piece of work, and one is unsound as
written:

1. **`finally` at drop can't be built, and it contradicts decision 11.**
   It's unsound for copies as well (see F1).
2. **"A value that holds a block is a block" isn't "the checks blocks
   already have".** Adapters *return* pipelines, and generic code
   (`index_all<C has next>`) has to take one as a type variable. Today's
   checker forbids both (F3). Allowing them is Swift's `~Escapable` plus
   lifetime dependence (SE-0446).
3. **`next` as a requirement needs an associated element type and
   associated error and `uses` rows.** No requirement has outputs today,
   and debug native dictionaries aren't method tables (F4).
4. **Copyable generator cursors rule out the cheap interpreter**
   (one-shot OCaml continuations), so gen fn needs a state-machine
   transform (F5).

Both breaks have a fix that sits well with Ren. Cleanup goes to
the service and to the loop over a temporary, as decision 11 already
says. A **pipeline is a block, `fn() -> Option<T>`**, built by the
compiler where the chain is written. That reuses rules A–D,
exclusivity, per-block specialization and debug code+frame unchanged,
and needs no `next` requirement at all.

## How each piece compiles

### gen fn in the interpreter

The interpreter is a tree walker; tasks are OCaml 5 fibers (sched.ml
`Suspend`, `Effect.Deep.match_with` at :546). The obvious build is a
fiber per generator, with `yield` performing a `Gen_yield` effect and
the cursor holding the continuation. That's about 250–400 lines, and
`Net` inside `next` works, since the deep handler forwards `Suspend` to
the task's handler. But:

- **OCaml continuations are one-shot.** `let c2 = c1; next(&c1);
  next(&c2)` must give both the same item (the draft: "a generator's
  cursor copies like any value"). A fiber can't be cloned (no
  `clone_continuation` in OCaml 5). The cells of `env` are `t ref` too,
  so a copy would share locals.
- **There are no drops.** Values are OCaml-GC'd, so "finally runs when
  the cursor is dropped" has no event to hang on.
- **Evidence:** a fiber captures the `ev` of its first `next`. The draft
  says `next` runs "with the consumer's dependencies", so `ev` has to be
  a cell refreshed at each resume. That's fine, since `yield` can't be
  inside `with`.

So either gen cursors are **not** copyable after they've started (an
affine-ish rule the draft rejects), or gen fn is a **state machine**:
a record of live locals, a state tag, and `next` as a `match`. A state
machine on Core gives value semantics for free, and both backends could
share it. But Core is a structured expression tree (`While`, `Match`,
`Finally`, `Handle`, no goto). Resuming into the middle of nested loops
means flattening to a CFG first. That's Regenerator- or C#-iterator-sized:
**1,500–2,500 lines, high risk**, plus Core Lint support.

### gen fn natively

There are no native tasks yet (compiler.md, 11a "Native": `Async.scope`
is refused by `ren build`), and stage 13 builds the frame allocator. A
gen fn whose `next` uses `Fs` or `Net`, the interesting case, is
therefore blocked natively on stage 13. A pure gen fn (`walk`) isn't.

The approach that reuses the most is a state machine at Mem level,
after Perceus:

- Lower `yield` in to_mem as a *fallible call*: `Call_fails` of a
  "suspend" whose error means "abandoned". rc.ml then already places
  the drops of every live owned variable on the abandon path. A Mem
  `Catch` around it gives `finally` for free.
- A late pass spills the variables that are live across a yield into a
  frame object: a counted object with a descriptor and a mask, so
  Perceus' copy-on-write on `next(&c)` gives value semantics, as
  arrays' do. emit_c writes the resume dispatch as `switch (st) {
  case k: goto resume_k; }`. C allows a goto into a loop, and Mem's
  structure is otherwise untouched.
- The frame's drop routine is the abandon path for the frame's current
  state.

Estimate: **1,200–2,000 lines (to_mem, rc.ml awareness, the spill pass,
emit_c, the runtime), high risk.** Mem Lint needs a rule for frame
objects.

### `yield from` and boxing

A gen frame is a heap object anyway: most frames exceed decision 14's
small-value size. So "boxed like a recursive enum's field" costs
nothing extra. Recursion between gen fns is an SCC over the frames'
field types. **Low risk, about 100 lines.** The cost to note is that in
pull mode every `walk(c)` allocates a frame. Each item then passes up
through `depth` boxed cursors, so a pulled tree walk is
O(n·depth), the cost Python's `yield from` has. Push mode avoids it.

### "Pushed when it can be"

This is a Core→Core pass, before specialization, so `ren run --release`
exercises it. A gen fn `G` gets a twin, `G_push(args, body)`. Each
`yield e` becomes a call of `body`, and `yield from H(a)` becomes
`H_push(a, body)`. Passing a block parameter on is legal (rule A
forbids passing it only to a call *of* a block parameter), and
specialize.ml keys a passed-on block once. Go does the same rewrite
(`cmd/compile/internal/rangefunc/rewrite.go`).

What it has to handle:

- **`break` and `return` out of the body.** Core Lint forbids a `Break`
  leaving a block (10c), so the body returns a control value: continue,
  break, or return `v`. The producer checks it after each `yield` and
  unwinds through its `Finally`s. Errors already propagate by return
  code natively and as `Failed` in the interpreter.
- **It can't push when the consumer's body contains `yield`**, a gen fn
  looping over another gen fn. The yield would sit inside a block
  (see F9). Those fall back to pull, so gen-over-gen, the
  `valid_records` shape in the draft's own fix-it, always allocates a
  frame.
- **Borrow inference.** On the surface the loop body may change the
  variable the producer's argument came from: the cursor owns a copy.
  In the push form the producer is a call still running while the body
  runs. If borrow.ml decides the producer only *borrows* that
  parameter, the body's in-place write sees a count of one and mutates
  or frees the buffer under the producer. The push twin's parameters
  must be owned, or borrow inference has to run on the pull form's
  facts.
- **Recursion moves to the native stack.** A deep tree walks without
  heap frames, but deep enough input overflows the stack, where pull
  mode wouldn't. That's observable.

Estimate: **400–700 lines, medium risk.**

### Pipelines in debug builds ("shared adapters")

Debug values of a type variable are one word (`ren_val`). "Every Ren
value but a block is a word" (Step 3), and Mem Lint forbids a block in
an object. A pipeline is a source plus a block (two words) plus state,
so it can't be a word. It has to be a stack aggregate, passed to
generic code by pointer, under a new non-counted layout. And a shared
`map` adapter calls its source's `next` through a dictionary, but **a
debug dictionary is the type's descriptor, not a method table** (Step
3: "a type with members of its own is the case that would need more").
`next` is always a user member. That's new machinery: a descriptor
slot holding the `next` function, with the error ABI and evidence
parameter, and suspendable in general, because the adapter's `uses` is
row-polymorphic. **500–900 lines, medium-high risk.**

### Release fusion

specialize.ml keys a copy on "for each **block parameter**, the block
passed" (header, :17–24). A block *inside a value*, like a pipeline's
field, has no key, so `index_all` given `r.map(parse).select(valid)`
would get the debug strategy. Something has to be built for it:

- a new key component, the tree of blocks inside each pipeline
  argument; or
- scalar replacement of pipelines before specialization, exploding each
  pipeline argument into its data fields plus one block parameter per
  stage. Pipelines can't be stored, so the shape is known at every
  call. After that, today's per-block keys and lifting do the rest.

Either way it's a local flow analysis. compiler.md takes pride in
needing none ("Neither needs lambda sets or any flow analysis").
**500–900 lines, high risk.**

Inlining each `next` into one loop is then up to clang. inline.ml only
inlines for reuse. That works while a release build is **one C file**
(cc.ml:4). Once decision 13 splits release into per-module partitions,
the stages' copies must be emitted into the consumer's partition, or
fusion silently goes away.

### Relative frame addressing for blocks in a generator's frame

The draft is right that this is an implementation rule. The cost is in
debug: a debug block's environment is "an array of the addresses of
the locals it captures, on the stack" (Step 3). In a gen frame,
captured locals are frame fields, and the frame can be COW-copied while
suspended. Either generate a per-state rebase, adding (new base − old
base) to the live env arrays after a copy, or re-make the block values
at each resume point; they're literals, so the compiler can. The same
applies to a pipeline that holds `&r` (F7). In release, specialization
passes captures as arguments, so after SRoA nothing absolute is stored.
**200–400 lines, medium.** It isn't Rust's `Pin` problem, because Ren
controls every copy.

### `next` joins the built-in requirements

Requirements are `(type variable id, name)` pairs whose types mention
only the type itself (infer_reqs.ml: `add: fn(self, T) -> T`, `zero:
T`). `next` gives `Option<Elem(C)>`, fails with `Errs(C)` and uses
`Uses(C)`: an **associated type and two associated rows**. Inside
`take<C has next>`, `c.next()` needs a result type, and a public
signature must state its rows ("a `!` on every public signature"),
with no syntax to write "C's next's errors". It's buildable the way
Haskell does multi-parameter classes with fundeps: the requirement
carries fresh `T`, `E`, `U`, quantified in the scheme and unified with
the concrete `next` at instantiation, and its rows flow implicitly, as
a block parameter's do. **600–1,000 lines in sema plus core.ml's
`dict`, high risk.** The 10c restriction ("a cursor's `next` can't fail
or use anything", Infer_expr.cursor checks `row_names errs = [] &&
row_names uses = []`; Lower.cursor_loop passes `Ty.closed`) also has to
be lifted, and `for x in try &c` parsed: **150–300 lines, low.**

## Sizes

| Piece | Lines of OCaml | Risk | Reuses |
|---|---|---|---|
| Syntax: `gen fn`, `yield`, `yield from`, `for x in try &c` | 300–500 | low | parser, resolve's `loop_at` |
| Cursor `next` that fails and uses deps | 150–300 | low | Infer_expr.cursor, Lower.cursor_loop |
| gen fn typing, cursor type naming, where `yield` can go | 400–700 | medium | no_kept_blocks, check_blocks |
| `next` requirement with associated element and rows | 600–1,000 | high | infer_reqs, core.ml `dict` |
| Second-class pipelines through type variables, adapters that return them | 600–1,200 | high | is_handle (rule D) is the only precedent |
| Exclusivity per step, a pipeline's hold on its source | 200–400 | medium | excl.ml |
| Interpreter gen fn: fibers / Core state machine | 250–400 / 1,500–2,500 | low / high | sched.ml effects |
| Push lowering | 400–700 | medium | per-block specialization |
| Async.each and map over cursors, produce, map_pull | 300–500 | medium | sched.ml's task map |
| Native gen frames (after Perceus) | 1,200–2,000 | high | rc.ml's error paths, COW |
| Debug pipelines and `next` dictionaries | 500–900 | medium-high | descriptors |
| Relative addressing / rebase | 200–400 | medium | — |
| Release fusion (SRoA or key) | 500–900 | high | specialize.ml lifting |
| `finally` at drop | not buildable as written | — | — |

That's about 6,000–10,000 lines, the size of 11a. With "a pipeline is
a block" (F3), the two high-risk type-system rows shrink to about 300
lines, the `next` requirement row goes away, and debug pipelines need
no new layout.

## Findings

**F1 (breaks): `finally` at drop.**
- foundations.md decision 11 says: "Resources are closed in a `finally`
  or an operation, **never when a count reaches zero**."
- The interpreter has no drops at all; it runs on OCaml's GC.
- Natively, `ren_drop` is C. It has no evidence, no error channel and
  can't suspend, and a cursor dropped inside a dropped record or array
  is freed by that recursive C walk.
- When the drop runs code depends on run-time counts. So the function
  where the last reference dies, and so whose `uses` gains `Fs` and
  whose errors gain `FsError`, isn't known statically. That's behind
  your back, and it breaks "say what can go wrong".
- **Copies run cleanup twice.** `let c2 = c1; next(&c1)` makes Perceus
  copy the frame. Both copies hold the fd id, and both run `finally
  f.close()`: a double close, which can close an fd the OS has reused.
- Debug and release can place drops differently (borrow inference,
  reuse), so a journal from release wouldn't replay in debug.

Fix: `finally` runs when the body finishes or fails; when a `for` over
a temporary generator ends, by `break`, `return` or a failure; and on
cancellation unwind. An abandoned cursor's resources go back when the
service's own `with` ends. That's the draft's own rule: "a resource's
state belongs to its service".

**F2 (breaks, a contradiction): `break`.** Cleanup says `finally` runs
"when a loop over it ends, by ... `break`". The cursor section says
`break` leaves `&r` where it stopped, and the next loop goes on. Both
can't hold for a gen cursor bound to a `var`. Fix: the producer ends
only for a temporary subject. That's also exactly where push applies.

**F3 (breaks as written): pipelines.**
- `r.map(f)` *returns* a pipeline, and rule D lets no function return a
  block. Only the built-ins `Scope` and `Task` are exempt, by path
  (infer_top.ml `is_handle`).
- `index_all<C has next>(rows: C)` instantiates `C` with a
  block-holding type, which check_blocks forbids: "A type variable
  never stands for a block either: `T` could be stored" (infer_top.ml
  :1603).
- Allowing it needs an inferred "may be second-class" attribute on each
  type variable, conditional on its arguments, as in `Take<C>`. Public
  signatures would have to state it, as rule B does for concurrent
  parameters.
- This is Swift's SE-0446 `~Escapable`, with conditional
  `Escapable where T: Escapable` and lifetime dependence for returns
  (`/tmp/ren-refs/swift-evolution/proposals/0446-non-escapable.md`
  :198–252).
- Also, users can't write their own lazy stage over a pipeline. A gen
  fn can't take one (it holds a block) and a function can't return
  one.

Fix: a pipeline *is* a block, `fn() -> Option<T> ! E uses U`. The
compiler builds it where the chain is written, with stage state (the
`take` counter) as hidden locals of that frame, captured by reference.
Sinks take a block parameter. Rules A–D, exclusivity, per-block
specialization and debug code+frame are unchanged; the element type is
the block's result; rows flow as they already do; there's no `next`
requirement and §3 isn't widened. That's language.md §3's own answer:
"a generic algorithm that needs an operation takes it as a block".

**F4 (major): the `next` requirement.**
- It needs an associated type and two associated rows, which none of
  today's requirements has.
- Public signatures need syntax for "C's next's errors".
- Debug native dictionaries are descriptors, not method tables.
- It's also the "`T has area`" idea language.md §3 withdrew, for one
  name.

F3's fix removes it.

**F5 (major): copying a gen cursor.** Value semantics for a suspended
generator rule out the fiber interpreter (one-shot continuations,
shared `t ref` cells). Options: a Core state machine (the large row in
the table); or make stepping one of two copies of a started generator
an error, which reads as affine. Decide which before 11c.

**F6 (major): a gen cursor's type isn't named.**
- A record field must write it (the fix-it stores `valid_records` in
  `self.pending`).
- Is it nominal per gen fn (static dispatch, but no array of different
  producers, so `merge` over N sources needs a sum)?
- Or one built-in `Gen<T>` (stored code plus data, so a description
  under decision 3, with tag dispatch per decision 4)?
- Its `uses` and errors have to be in the type, like a description's
  `uses` as an upper bound (10d).

**F7 (major): does a pipeline hold its source by value or by
reference?**
- By value, `let errors = r.map(parse)...` steps a copy and leaves `r`
  at the start. That's the RFC 3550 surprise the draft condemns.
- By reference, a pipeline is a value holding `&r`. Exclusivity needs a
  row for it ("each step, an instant", like a let-bound block's
  captures), and relative addressing covers it too.
- `&` on a temporary (`&f.chunks()`, `&Db.rows(q)`,
  `&left.map(...).zip(...)`) isn't a place, and mut.ml `writable`
  rejects it today.
- The rule "`for x in c` is an error on a cursor" also breaks today's
  `for (x, y) in xs.zip(ys)` (prelude.ml :233, stdlib.md).

Make the error apply only when the subject is a place.

**F8 (major): push has hidden conditions.** No push when the consumer's
body yields (gen over gen); the push twin's parameters must be owned,
or borrow inference unsoundly lends a buffer the body mutates;
`break` and `return` need a control-value protocol; recursion moves to
the native stack. "No program can tell" holds only if all four are
handled, and except for stack depth.

**F9 (major, but simplifying): where `yield` can go.** It must be
lexically in the gen body, not inside **any** block. Otherwise a
`yield` inside a block passed to an arbitrary function makes that
callee suspend mid-call: a stackful generator whose frames can't be
copied. The draft's list (`Async.scope`, `beside`, `timeout`, `race`,
`retry`, `with`, `finally`) is a subset of "any block or `with`". Say
the general rule; the error stays specific.

**F10 (major): release fusion isn't free from today's specializer.**
It keys block *parameters*, not blocks inside values (F3's fix avoids
this). Fusion relies on clang seeing all copies in one file, which
decision 13's partitions end unless copies go to the consumer's
partition.

**F11 (minor): native gen fn that uses dependencies waits for stage
13.** That's the most useful case: `lines`, `Db.rows`, `Net.chunks`.
The interpreter can have it at 11c; natively only pure generators can
come first.

**F12 (minor): allocation.** Pull-mode gen cursors allocate one frame
each, and `yield from` one per level, with O(depth) per item. "The
pipeline you'd write first allocates nothing" holds for pipelines and
pushed loops, not for stored or returned generators. Say so.

**F13 (minor): where `Async.map` and `Async.each` pull.** They must
pull from the source on the calling task. A pipeline's blocks capture
by reference, and pulling from worker tasks would run them
concurrently, against rule B.

**F14 (minor): `yield` as a keyword.** The lexer must still accept
`Async.yield()` after a dot.

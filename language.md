# Language: data, services and cost

The design record for how Ren separates modelling data from injecting
services, how it marries domain-driven design with data-oriented
design, and where actors fit between them. It was settled in one design
session on 2026-10-28, from a review of the language as it stood after
stage 11a step 9, three rounds of research into prior art, and probes
against the compiler. It was reconciled the same day with the actor
design from 11a's follow-ups (§11).

**Status.** Decided. This record is the language a program is written
in; [foundations.md](foundations.md) is how it runs: blocks, dispatch,
tasks, memory and cores, with actors and stripes as its decision 18.
Where the two meet, this record says what a program writes and
foundations.md what it means and costs. Staging for both is in
[foundations.md](foundations.md#staging). Items marked **later** are
noted so they aren't lost. Nothing here is implemented unless it says
"today".

## Contents

- [Why: Ren felt object-oriented](#why-ren-felt-object-oriented)
- [The ethos](#the-ethos)
- [1. Four questions, one mechanism each](#1-four-questions-one-mechanism-each)
- [2. Data: ADTs first](#2-data-adts-first)
- [3. Generic code: no user-defined interfaces](#3-generic-code-no-user-defined-interfaces)
- [4. Services: a dep is something you're given](#4-services-a-dep-is-something-youre-given)
- [5. Wirings: the composition root, named](#5-wirings-the-composition-root-named)
- [6. Stored descriptions: an enum the compiler writes](#6-stored-descriptions-an-enum-the-compiler-writes)
- [7. Methods are vocabulary, workflows are functions](#7-methods-are-vocabulary-workflows-are-functions)
- [8. The pipe, and `try` on each step](#8-the-pipe-and-try-on-each-step)
- [9. Collections: `Array`, `Table` and `Pool`](#9-collections-array-table-and-pool)
- [10. Advice that isn't an error](#10-advice-that-isnt-an-error)
- [11. Many stateful things: data or actors](#11-many-stateful-things-data-or-actors)
- [12. Bytes: types and their formats](#12-bytes-types-and-their-formats)
- [Domain-driven design in Ren](#domain-driven-design-in-ren)
- [A program, end to end](#a-program-end-to-end)
- [What changes from today](#what-changes-from-today)
- [Where it could go wrong](#where-it-could-go-wrong)
- [Open and later](#open-and-later)
- [Evidence](#evidence)

## Why: Ren felt object-oriented

Most of what looks object-oriented in Ren is only syntax, and is fine:

- **`x.m(args)` is `Type.m(x, args)`,** resolved through the type like a
  field. No dispatch, no hidden state; `inout self` is an `inout`
  parameter, marked `&` at the call. It's namespacing.
- **Operators are methods with reserved names,** found on the left
  side's type.
- **`Console.error`, `Clock.now()`** read like static classes but are
  dynamically scoped effect operations.
- **Cursors** with `next(inout self)` look like iterators but are values:
  copying one copies its position.

What was really object-oriented was handlers. Feature for feature:

| Object-oriented | Ren today |
|---|---|
| Interface | `dep Shape = area: fn() -> Float` |
| Class | `handler circle(r) for Shape` |
| Constructor and its arguments | a description, `circle(1.0)` |
| Private mutable fields | `var` in a handler |
| Methods | operations |
| Implementing several interfaces | `handler boxed(n) for Size, Label` |
| `super`, a subclass, a decorator | `over` and `next` |
| A dynamic proxy | `over any` |
| A destructor, `using` | `finally` |
| A synchronized object, an actor | an instance's exclusion (foundations.md §10) |
| Virtual dispatch | `s.area()` on a description |
| A vtable | a stateless handler's record of methods |

foundations.md decision 3 called this "Ren's answer to `dyn Trait`", with
the textbook example, and bench/10d/dispatch.ren held the Gang of Four's
Interpreter pattern, an expression tree as classes:

```ren
dep Expr = eval: fn() -> Int
handler num(n: Int) for Expr = eval() => n
handler add(a: Expr, b: Expr) for Expr = eval() => a.eval() + b.eval()
```

What handlers kept that objects don't is the good part, and stays: an
instance can't be stored or aliased, only its description; it lives for
its `with`; dispatch is to a closed set the compiler lists. They're
objects without shared mutable aliasing, closer to Erlang processes than
to Java. §11 makes that the model: a handler with state is an actor, a
service that takes one call at a time, and the program never holds one.

**The root cause was one mechanism doing two jobs.** Ren has no traits,
so `dep` was the only way to abstract over values. It served both
effects (`Fs`, `Sql`, `Clock`) and polymorphism over data (`Shape`),
and the two pull opposite ways:

| | A service | A data interface |
|---|---|---|
| Who picks the implementation | whoever's outside, at `with` | the value itself |
| Lifetime | a scope, with state and `finally` | the value's |
| What you want | `over`, `next`, test fakes, the journal | `==`, `show`, `match`, static calls, inlining |
| Dispatch | dynamic scope | static, or by value |

Data that went through the effect machinery paid for it, each of these
checked against the compiler:

- **No way out.** Generic code can't call a user's method on a type
  parameter: `x.area()` with `x: T` is "`.area` needs a record, but this
  is a `T`". So "anything with an `area`" had to be a dep.
- **Opaque values.** `sq(2) == sq(2)` is "`Shape` has no `==`": a
  description can't be compared, shown, hashed, matched or stored as a
  key. You can only call it. The OO side of the expression problem, by
  default rather than by choice.
- **Effect semantics on pure code.** `s.area()` means `with s in
  Shape.area()`; descriptions carry `uses` rows; an arm's calls count as
  writes of all the handler's state.
- **A trap.** A stateful handler called as a method starts fresh at each
  call, so this printed `1`, `1`, where every reader expects `2`:

  ```ren
  handler counter() for Shape =
    var n = 0
    area() =>
      n += 1
      n

  let c: Shape = counter()
  print(c.area())   // 1
  print(c.area())   // 1
  ```

- **Compiler work spent undoing it.** Decision 4's devirtualization (tags,
  inline compares, loops cloned per handler) is good engineering, but
  much of it recovers what an enum or a specialized generic has from the
  start.
- **A muddied pitch.** When `Shape`, `Expr`, `Size` and `Label` are
  deps, "dependency" stops meaning anything in particular.

10d was already collecting exceptions for "stateless handlers called as
methods": stateful ones start fresh, ones `over` another can't be
called, ones that can fail to start can't, inline handlers only for one
operation, a stored description's `uses` an upper bound. This record
gives each job its own mechanism instead.

## The ethos

Ren is **an ML language for domain modelling and data-oriented
infrastructure, with effects as explicit dependency injection.**

1. **Model with data.** What a thing *is* is an ADT. Rules are data.
   Behaviour is functions.
2. **Ask for services by name.** What code *needs* is in its `uses`, and
   only the composition root decides who provides it.
3. **Say what can go wrong, where it can.** A `try` on each step that can
   fail, a `!` on every public signature.
4. **The obvious way is the fast way.** ADTs inline, generics
   specialized, blocks inlined, services called directly. Writing it
   cleanly never costs a pointer chase.

Under all four: **one mechanism per question, and nothing found behind
your back.** Inferred inside a module, written at its boundary.

It joins three lineages that rarely meet: ML and Wlaschin-style
domain-driven design for meaning, Effect-TS for structure, and
data-oriented design for cost. They fit because they reject the same
thing: behaviour bundled with state behind a pointer. Mike Acton's
advice and Wlaschin's look alike.

### Domain modelling and mechanical sympathy are one language

The tension is real: modelling wants names, states and rules; data-oriented
design wants contiguous arrays, no indirection, hot fields apart from
cold. Ren spans both, and foundations.md already has the bridge:

> **The programmer never holds an address, so representation is the
> compiler's choice.**

Which gives three altitudes:

1. **Model meaning; the compiler chooses layout.** ADTs, records,
   generics. Small values inline, arrays unboxed, unique values changed
   in place. Most code lives here, and it's fast.
2. **When cost matters, state the cost, not the address.** `Table`
   instead of `Array`, `Pool` and `Id<T>` instead of pointers, sized
   integers, arenas, slices, `&`. Each is still a value, so
   data-oriented code is as matchable, comparable and testable as domain
   code.
3. **Never handle an address,** outside `trust`.

The tension doesn't vanish. It narrows to two places: what the compiler
picks silently versus what the programmer asks for (answered in §9), and
formats on disk, where layout *is* meaning (answered in §12: the layout
belongs to a format, not to the type).

### What Ren is not

- **Not object-oriented.** No interfaces over data, no classes as
  handlers, no Strategy pattern, no "`dyn Trait`".
- **Not a typeclass language.** The built-in requirements stay closed.
- **Not a query language or a dataframe.** `Table` is `Array` plus a
  view of its columns.
- **Not an ECS.** A population of mixed kinds is swept with `match`.
- **Not clever.** No flow typing, subtyping, lenses, placeholders or
  automatic layout guesses.

## 1. Four questions, one mechanism each

Every time a programmer reaches for polymorphism, they're asking one of
four questions:

| The question | Ren's answer | What it costs at run time |
|---|---|---|
| **What is this thing?** It comes in known forms. | an **ADT** (records and sum types) and `match` | an inline tag, no indirection |
| **Do this with any type, given how.** | a **generic function** and a **block**, or the built-in `==`, `<`, `+`, `show` | specialized per type |
| **Who do I talk to?** | a **`dep`**, installed with `with` or a wiring | a direct call, once specialized |
| **A collection others add kinds to** | a stored **description** | a tag dispatch over a closed set |

Two tests decide the column:

- **Do you hold it, or are you given it?** Held is data: you have many,
  you pass them, store them, match them. Given is a service: provided by
  the root, one per scope, asked for by name.
- **Do you own every kind?** Then write the ADT. If others add kinds,
  let the compiler write it (§6).

The full map, including the questions about cost (§9):

| Question | Mechanism |
|---|---|
| What is this thing? | an ADT; one state of it is a variant type, `Order.Placed` |
| What does it know about itself? | its methods: vocabulary and invariants |
| What happens to it? | free functions, composed with `\|>` |
| What can go wrong? | `!` rows, a `try` on each step |
| Do this for any type? | a generic function and a block |
| Who do I talk to? | a `dep` in `uses` |
| Who provides it? | the composition root: `with` and wirings |
| Others add kinds? | a stored description |
| How do many sit in memory? | `Array` (rows) or `Table` (columns) |
| Do they keep identity through churn? | `Pool` around either |
| Many entities, each with its own I/O and exclusion? | `actors`, addressed by key, a service (§11) |
| One hot service on many cores? | `striped`, map-reduce over stripes (§11) |
| Work alongside other work? | `Async.scope`, `Async.beside` |
| Where can state change under me? | only at `release` |
| How does it look as bytes? | a format for its type (§12) |

The top half says what a program means, the bottom half what it costs
and how it scales, and changing the bottom never changes the top.

## 2. Data: ADTs first

Domain models are ADTs: records (products), sum types, and opaque types
that keep rules. Enums are one case of that. **Domain rules are data,**
so they can be compared, shown, hashed, matched, decoded from config,
stored and replayed:

```ren
pub type Discount =
  | NoDiscount
  | Flat(off: Money)
  | OverAmount { min: Money, off: Money }
```

The Strategy pattern written as handlers can do none of that.

### What Ren has today

Tested against the compiler on 2026-10-30, after the data stage and the
services stage's pipe, wirings, background work, `release`, services,
pull arguments, channels and producers, the keyed instance family,
`D.Call`, `striped` and `actors` with `post`:

| Feature | Today |
|---|---|
| Constructor arguments | a variant with several fields is declared, built and matched by name, `Rect { w: Int, h: Int }`, `Rect { w: 2, h: 3 }`, `Rect { w, .. }`; one with one field by position, `Flat(5)`, or by name if it's declared in braces, `Draft { lines: Array<Line> }`; the other spelling is an error whose help writes this one. Error tags stay positional, `fail Short(a, by)` |
| Punning in record literals | `P { x, y }` works |
| Record update | `{ ..p, x: 5 }` and `Q { ..p, x: 5 }`, in the interpreter and natively, a unique `p` updated in place |
| Record patterns, `let { id } = u` | `{ id, .. }` and `User { id, .. }` in a `match`, a `let`, a `for` and a block's parameter |
| Labels in a pattern | by name, `Rect { h: hh, .. }`, `..` for the rest |
| Nested patterns and guards | work: `Some(Active(Pro(n))) if n > 3 =>` |
| Or-patterns | anywhere a pattern goes, nested, `Some(Pro(_) \| Team(_))`, each alternative binding the same names at the same types, and one that matches nothing new an error |
| `as` | `Pro(n) as old`, binding the whole of what's matched, looser than `\|` |
| String and list patterns | none: code writes an `==` chain; decided in [List patterns and string patterns](#list-patterns-and-string-patterns) |
| `if let` | an error whose help writes the `match` or the `let ... else` |
| `let Some(n) = o else ...` | works, its `else` leaving with `fail`, `break` or `todo`; a `let`, a `for` and a block's parameter take apart anything that always matches, `let Meters(n) = m` too; `o orelse 0` works |
| Methods on a sum type | work |
| A field of a sum, `s.id` | one every variant has: "every variant of `Shape` has `id`, but a sum type has no fields", whose help says to hoist it into a record, `type Shape = { id: Int, kind: ShapeKind }`, or write a method; one only some variants have: "`Shape` is a sum type; only `Rect` has `w`", whose help writes the `match` that takes it out |
| Narrowing in an arm | a variant with named fields is a type, `Order.Placed`, which a pattern's `as` binds, `Placed { .. } as p`; a record of its fields, read, matched and updated, that goes anywhere a value does, `Placed { ..p }` the sum again; `==`, order, `hash` and `show` the sum's |
| Exhaustiveness | very good: lists the missing patterns, says guarded arms don't count, flags unreachable arms, and the help prints the missing arms as code to paste, `Some(Closed) => todo`, at the arms' column; the editor's code action is later |
| `todo` | a keyword, an expression of any type that panics where it's reached, "reached a `todo`", in `ren run` and natively; it leaves a `let ... else` |
| One constructor name in two types | resolved by the expected type, else "write `A.Open`" |
| A stateful handler called as a method | an error, "`c` may be a description of `counter`, which keeps state, so it isn't called as a method", whose help writes the `with`, checked on the linked program by `ren run`, `ren test` and `ren build` (not `ren check` of one module); a stateless one is called as a method |
| Records | nominal: same-shaped records don't mix |
| The pipe | `x \|> f(a)` is `f(x, a)`, checked as that call, in the interpreter and natively; a step is a function by name, `f`, `module.f` or `Type.f`, and each step that can fail carries its own `try`, which `\|>` stops; `orelse` may follow a chain; a line starting with `\|>`, or with `.` and a name, indented further, continues the one above; the errors of §8, each with its help (examples/checkout, language.md's end-to-end program) |
| Wirings | `wiring live(url: Str) provides Users uses Console ! DbDown = pg_db(url), console_audit(), db_users()`, flattened where a `with` lists it into one set, so an item beside it shares what it installs, in the interpreter and natively; `provides` is all the body may call, `uses` and `!` are inferred for a private wiring and written for a `pub` one, another module lists a `pub` one as `app.live`; wirings nest, a test splits one, a parameter can be a description; every error of §5 with its help, and `ren explain-wiring live main.ren` (examples/checkout, examples/ledger, examples/server) |
| Background work | `Async.beside(task) fn() => body` and `Async.background fn(bg) => body`, `bg.spawn fn() => ...`: the body ends, then its background tasks are cancelled and waited for, then the `with` around it runs its `finally`; a background task may fail, and the first failure cancels the body and is its error. A task that can reach a handler installed inside the scope it's spawned into is a compile error whose help opens the scope inside the `with`, and a panic at the spawn where a helper is handed the scope. In the interpreter; `ren build` refuses them as it refuses `Async.scope` (examples/refresh) |
| `release` | `try release Next.get(id)` in a handler's arm lets go of the instance for that one call and takes it back after, queueing like any caller; the arm's state is written back before and read again after, and `sim` switches tasks there, so a value read before it and written after loses an update under some seed (examples/breaker). A plain dependency call holds none of the handler's state, so an arm loops over a reader in its state while it calls another service; one marked `release`, `Async.until` and a block parameter's call do. With no other task, and natively, it's a plain call. A parked task's deadlock panic names the instances it holds, `holding \`A\` (a.go)`, and `sim` gives a released instance to whichever waiter or arrival its tape runs first |
| Defaults | a literal, or a variant written bare, `kill: Kill = Tree`, with no fields or a default for its one field, `by: By = Key` meaning `Key(n: 16)` when `Key(n: Int = 16)`; a dependency's operation may have them, `Proc.run(cmd, args, kill: Kill = Tree)`. A variant's field with a default is left out, `Key`, or given by name, `Key(n: 64)`; one in braces has none yet |
| Pull arguments | `Async.map` and `Async.each` take what `for` takes: a collection by a snapshot, a temporary cursor as itself, a named one as `&r`, which they change in its place, a block `fn() -> Option<T>`, and a channel's `items()`; they pull it on the caller's task only when a slot frees, `max:` 64 by default, and `map` keeps order. Any function's parameter `fn() -> Option<T>` takes them too, and `for x in try f` loops over such a block, as `for x in try c` over a cursor whose `next` can fail (examples/server) |
| Channels | `dep Events = Chan<Event>`, installed `with sync.channel(16) as Events`; `Events.items()` is `sync`'s ordinary function of `Chan<T>`, a cursor whose `next` is `Events.recv()`, pulled where it's written, in a `for` or as a pull argument, so two channels of one element type don't mix |
| Producers | `Async.produce(cap: 16, fn() => crawl(root)) fn(items) => ...`: the producer runs on a task beside the body and sends with `Send.send(x)`, through the `Send<T>` the call installs, at most `cap` ahead; `items` gives what it sent, in order, then `None`, or fails with what it failed with (`for p in try items`); when the body ends, by finishing, `break` or a failure, the producer is cancelled and waited for. `Async.map_pull(src, max:, f) fn(results) => ...`, `map`'s results as a stream. In the interpreter; `ren build` refuses both as it refuses `Async.scope` (examples/crawler) |
| `Proc.run(kill:)` | `Tree`, the default, starts the program in a process group of its own and a cancel kills the group, so `sh -c "sleep 5; true"` leaves no `sleep`; `Child` kills the program alone, as before, and keeps it in this program's group, where it can read the terminal; `sim.proc()`'s `SimProc.kills()` says which each cancelled run had |
| Services | `service Kv(c: Cfg) uses Http = pub fn get(k: Key) -> Str ! KvError = ...`, a `dep` and its handler written once: its operations are its `pub fn`s, its members share its parameters and its `uses` and call each other directly, and it's installed as a handler is, `with Kv(cfg)`, in a `with` or a wiring, `kv.Kv(cfg)` from another module, and replaced by any handler of `Kv`; in the interpreter and natively. A member's own `uses`, a service used as a value and `Kv(...)` outside a `with` are errors with help. It keeps state as a handler does, `var n: Int = 0` first, set up when it's installed and failing with its `! E`, which its functions read and write as they call each other. A signature's `uses` is a bound (bench/services/service) |
| A call as a value, `D.Call` | the compiler writes `Doc.Call` for each dependency whose operations are all data, a case per operation, `Doc.Call.Edit { op }`, built, matched, compared and shown as any sum; its cases are named only after `Doc.Call`; `Docs.Call` of one that takes a block is an error naming the operation. A call's type carries which operations it may be a call of, so generic code's `D.Call<R ! E>`, `post`'s `D.Call<()>`, takes only calls whose operation gives R and fails with at most E: "`post` takes a call that gives `()` and can't fail, and `line` gives a `Str`". Not yet: `Doc.Call<R ! E>` written of a dependency's own calls, which is refused |
| A `call` clause | a handler writes `call(c) => ...` beside its operations, run for each it doesn't write, `c` that call, a `match` on it giving each case its operation's result type; a merge writes `call(c, a, b) => ...`, folding two results; a handler `for D`, `handler striped<D>(h: D) for D`, writes only that clause, made for the dependency it's given |
| The keyed instance family | the runtime's, in the interpreter: `Instances.open(fn(k) => h, parts, cap, mailbox)` and `Instances.call(fam, k, c)`, `make`, `keys`, `evictable`, `evict`, `counts`, `close`, `pin` for a block and `visit`, and `post`, a call queued for a key and delivered in order, one operation each, by a task of the family's, which only the prelude's `Instances` reaches; every call from outside waits while the mailbox is full, a sibling's never, and panics past twice it; the family's end delivers what's queued first; `ren test` reports each family's high-water mark; `Async.worker()` is 0 under `single` and one of two virtual workers under `sim`, from the tape. Refused by `ren build` |
| Stripes | `with striped(counter(), by: Key(n: 4), merge: Sum)` keeps 4 instances of `counter()` in the family: a call with a first argument goes to one by its hash, one with none runs on each in stripe order, folded by `Sum`, `Max`, `Min`, `Concat` or `Custom(m)`, `m`'s `call(c, a, b)` clause; `by: Worker` goes to the caller's worker's; a missing or unfitting `merge:` is a panic at the `with`; plain Ren in the prelude; `sync.keyed` is gone. Refused by `ren build` |
| Actors | `dep Docs = Actors<DocId, Doc> ! StoreDown`, `with actors(doc, max: 50_000) as Docs`, `try Docs.at(id) fn() => Doc.edit(op)`: one actor per key, made on demand, setup's errors `at`'s, past `max:` the least recently released evicted, its `finally` on the caller's task; `evict(k)`, `evict_idle(d)`, `each`, `count()`, `made()`, `evicted()`; `chaos: true` evicts what `Random` picks; `at` inside `at` of one family, an actor's `at` on its own family and a `finally` that can fail are refused, and `Full` is where waiting could close a cycle; `try Docs.post(k, Doc.Call.Edit { op })`, Erlang's cast, its arguments evaluated at the post, making the actor, so setup's errors are its only ones; an actor names its own family in `uses` to post to its siblings; the journal's `opened`, `made`, `evicted` and `posted` lines, version 3, replayed; a family behind a wiring is provided by its alias, `actors(doc) as Docs`. Interpreter only (examples/docs, §11's document server over `sim.net()`, under a thousand seeds with chaos) |
| Layout, natively | a small record or tuple inside a small value is flattened into its parent's slots; an array of small records that hold objects keeps them inline, counted by the mask of the slots that hold them; a sum's tag is a byte, and a sum with one constructor that has fields, the rest without, has no tag, a pointer niche: `Option<Item>` is two words, not three. `show`, `==` and `hash` of a small value still box its type program-wide (bench/native/RESULTS.md, "Data stage: layout") |

The core is right. What's missing is convenience, and two layout rules
that make the ADT path slower than it should be.

### Record update: `{ ..order, status: Paid }`

```ren
let paid = { ..order, status: Paid }
let placed = Placed { ..draft, id, total }
```

- `..` means "the rest" in both directions: `{ w, .. }` in a pattern
  ignores the rest, `{ ..order, ... }` in a value takes the rest from
  `order`.
- **Not F#'s `{ order with status: Paid }`:** `with` already means
  installing handlers. Elm's `{ order | status: Paid }` was the runner-up.
- Through Perceus reuse, a unique `order` is updated in place, so the
  obvious syntax is the fast one.
- Errors: an unknown field, "`Order` has no field `stauts`", with "did
  you mean `status`?".

### Taking records apart

- `let { id, lines } = order`: irrefutable, so it fits the existing rule
  that `let` takes apart only what always matches.
- Record patterns in `match`: `{ id, .. } =>`.

### Positional for one field, by name for several

**A variant with one field is positional; a variant with several is by
name, in constructors and patterns alike.** Tuples stay positional,
since being ordered is their point.

```ren
Some(x)                       // one field: positional
Percent(10)
Rect { w: 2, h: 3 }           // several: by name
match s
  Rect { w, h } => w * h
  Rect { w, .. } => w         // `..` absorbs the rest
  Rect { w: width, .. } => width
```

Why: domain models evolve. Positional patterns tie every `match` in the
program to a variant's field count and order:

- **Add a field** and every positional pattern fails to compile, even
  where the new field doesn't matter.
- **Reorder two fields of one type** and every positional pattern and
  constructor still compiles, **with the values silently swapped**. A
  refactor becomes a bug no checker can see.

By name is immune to both. Making it the only spelling for several
fields means each variant has exactly one spelling, so this adds no
second way to do anything. It breaks code that exists today, such as the
bank's `Sent(t.amount, t.to)`; that's what the design phase is for.

Error for a missing field: "this pattern doesn't name `h`; add `h`, or
`..` for the rest".

**Calls have one by-name form: a parameter with a default.** It's
given by name or left out, and the others are positional, so each
call has one spelling. A default is a literal or a variant with no
fields (`kill: Kill = Tree`, `evict: Evict = Lru`): `Async.map(xs, max: 8)`, `b.cursor(from: base)`
(compiler.md, "Parameters with defaults"). `retry(5, on: Declined)`'s
`on:` is the one parameter of `Tags`, written the same way.

### Or-patterns and `as`

```ren
match plan
  Pro(_) | Team(_) => paid(plan)
  Free => ...

match order
  Placed { .. } as p => ship(p)
```

- Or-patterns over constructors, nested. The parser already has `POr`
  for `fail` patterns. Error: "`n` is bound in `A(n)` but not in `B`".
- `as` binds the whole of what a pattern matched, OCaml's word, read left
  to right.

### `let ... else`

```ren
let Pro(seats) = plan else fail NotPro
```

- It generalizes `orelse` to patterns. The `else` must leave: `fail`,
  `return`, `break`, a panic. Error: "the `else` of a `let ... else` has
  to leave".
- **No `if let`.** A two-arm `match` is barely longer, and `if let` would
  be a second way.

### List patterns and string patterns

```ren
match (t.method, t.segments())
  (Get, ["v1", "keys", k]) => get(k)
  (Put, ["v1", "keys", k]) => put(k, t.body)
  (Get, ["v1", "stats", ..]) => stats()
  _ => not_found()

match arg
  "-h" | "--help" => Help
  "--out=" ..path => Out(path)
  "--" ..flag => Unknown(flag)
  _ => File(arg)

match header
  "Bearer " ..token => check(token)
  _ => fail NoToken
```

Five rules:

1. **A sequence pattern is fixed pieces in front, at most one `..` in
   the middle, and fixed pieces at the back.** On `Array<T>` a piece is
   an element pattern: `[]`, `["v1", "keys", k]`, `[first, ..rest]`,
   `[..init, last]`. On `Str` a piece is a string literal: `"GET"`,
   `"Bearer " ..token`, `..stem ".json"`, `"<" ..inner ">"`. One rest
   keeps patterns from becoming a parser: `..k "=" ..v` can't be
   written; that's `split`'s job. No `Bytes` patterns, no case folding,
   no regex.
2. **`..name` binds the middle as a slice of the same type, and `..`
   alone ignores it.** It copies nothing (decision 17). On `Str` the
   pieces are valid UTF-8, so the cuts fall on character boundaries and
   binding never checks or panics. `..x` or `[..xs]` alone is an error
   whose help writes `x`.
3. **String literals are patterns wherever a pattern goes,** inside
   or-patterns and `as` too: `"GET" | "HEAD" =>`, `["v1" | "v2", ..]`.
   Each alternative binds the same names at the same types.
4. **Exhaustiveness: array lengths are constructors, and strings are an
   infinite family.** `[]`, `[_]` and `[_, _, ..]` cover every array
   with no `_`, as rustc's slice patterns do. A `Str` literal or prefix
   never covers `Str`, so a string match needs `_` or a binding.
5. **The first arm that matches wins, and an arm an earlier arm covers
   is an error.** One arm covers another when its prefix is a prefix of
   the other's, its suffix a suffix, and its minimum length no longer.
   A guarded arm that fails falls through to the next arm that can
   match.

**A string match compiles to a perfect hash.** The literal arms of a
column become one lookup and a jump, an invisible optimization
([decision 20](foundations.md#20-what-the-language-owns-and-what-std-owns)
rule 4): about 1 ns from 2 to 45 keys, against 5.8–8.5 ns for today's
`==` chain and 3.5–9 ns for Rust's `match` (research/perfect-hash/).
Rule 5 is what allows it: no literal can be covered, so all of a
column's literals are looked up at once before any prefix arm, with the
same result. A library gets the same hash for field names it only knows
from a shape: `keys.index(s)` on a build-time constant `Array<Str>`
lowers to it. `http` lowercases header names itself; the language has
no case-folding pattern.

### Variant types: narrowing you can see

Wlaschin's state machines are functions that accept only one state. Ren
gets them without wrapper records and without subtyping:

```ren
pub type Order =
  | Draft { lines: Array<Line> }
  | Placed { id: OrderId, lines: Array<Line>, total: Money }
  | Shipped { id: OrderId, tracking: Tracking }

fn ship(p: Order.Placed, t: Tracking) -> Order.Shipped = ...

match order
  Placed { .. } as p => ...ship(p, t)...
  _ => ...
```

The rules:

- **A variant with named fields is a record type,** `Order.Placed`,
  holding exactly its fields.
- **A pattern with `as` binds it,** and the value goes anywhere: returned,
  stored, passed on. OCaml's inline records can't escape their arm,
  because of OCaml's layout; Ren's representation is the compiler's
  choice, so they can.
- **Back to the sum is explicit:** `Placed { ..p }`, the same spread as
  record update. If `p` is unique, Perceus reuses it, so it's free.
- **Constructors always build the sum.** `Placed { id, lines, total }` is
  an `Order`; the variant type appears only where a pattern binds it.
- **No subtyping and no implicit conversion.** Scala 3 and Rust's
  stalled RFC 2593 make `Order.Placed` a subtype of `Order`, which drags
  subtyping into Hindley–Milner and adds an implicit conversion; README
  principle 4 rules out both.

The costs: every variant with fields has a type name that shows up in
signatures and errors, `Placed { ..p }` is a little ceremony each time,
and errors gain one more "`Order` or `Order.Placed`?".

**No flow-sensitive narrowing.** TypeScript and Kotlin change a
variable's type after a check, `if s is Rect then s.w`, with no marker.
Kotlin's version breaks on `var` and properties, because the value can
change between check and use, and Ren has `var` and `inout` everywhere.
Narrowing in Ren is binding a pattern to a name: a marker you can see.

**Derived operations are borrowed.** A variant type has no
`==`, `hash`, ordering or `show` of its own; it uses the sum's. `p == q`
means `Placed { ..p } == Placed { ..q }`, compared without wrapping. So
if `Order`'s `key` is its id, two `Placed` values with one id are equal
as `Order.Placed` too. Deriving them structurally would let the two
disagree, and operators.md's rule is that `key` is the only way to
change what equal means.

**Methods on one variant** (later): `pub fn total(self: Placed) -> Money`
under `Order`, so `p.total()` works only on a placed order. A state's own
vocabulary would live with the state; transitions like `ship` stay free
functions. Added if real code asks for it.

### Errors that teach the model

- **A field asked of a sum:** "`Shape` is a sum type; only `Rect` has
  `w`", with the `match` to write.
- **A field every variant has:** the help says to hoist it into a record,
  `type Shape = { id: Int, kind: ShapeKind }`, or write a method. Hoisting
  is the cleaner model and the data-oriented layout.
- **A `match` that misses cases:** today's error, plus the missing arms
  printed as code to paste (`Some(Closed) => todo`), offered as an editor
  code action.

### Layout fixes

These are invisible to programs, and they matter most: today the
ADT-first path is penalised exactly where Wlaschin's patterns live. Found
by reading `lib/native/to_mem.ml` (around 395 to 420, and 517), not yet
benchmarked:

- **A small record inside a small variant is boxed.** `Draft(o:
  Unvalidated)` boxes because a field whose type is itself a struct makes
  the outer type boxed. Fix: flatten a nested small struct into its
  parent's slots, counting the budget in total words.
- **An array of small records holding an object boxes the type
  everywhere.** An `Array<T>` whose small `T` holds a `Str` raises
  `Demote`, and `T` is boxed program-wide. Fix: arrays hold counted
  structs inline, scanned by the mask the type already has.
- **The tag is a whole word.** Fix: a byte, and pointer niches, so a
  variant with one object and the rest empty needs no tag (Roc's
  `NullableUnwrapped`, Swift's spare bits).

Each follows "representation is the compiler's choice" exactly.

### Left out

- Flow-sensitive narrowing (above).
- Implicit `s.id` across variants: it hides the model. Hoist the field.
- Structural variants for domain data (Roc's tags, OCaml's polymorphic
  variants, Flix's restrictable variants). They stay for error tags,
  where composing across libraries is the point. For data they give long
  type errors and let a typo make a new tag.
- Automatic struct-of-arrays (§9).
- Labelled construction in any order: a third spelling.

## 3. Generic code: no user-defined interfaces

- **No traits, typeclasses or user-defined requirements, now or later.**
- **A generic algorithm that needs an operation takes it as a block:**

  ```ren
  fn total<T>(xs: Array<T>, area: fn(T) -> Float) -> Float =
    xs.map(area).sum()

  total(squares, Square.area)
  ```

  Blocks are passed down and never kept, and release builds lift and
  specialize each one, so this costs nothing and hides nothing. It's
  ML's answer.
- **The built-in requirements stay a closed set:** `==`, ordering and
  `hash` through `key`; `add`, `sub`, `mul`, `div`, `rem`, `neg`; `zero`
  and `one`; `show`. Inferred, carried in schemes, passed as dictionaries
  in debug builds and specialized away in release (compiler.md,
  "Requirements").

An earlier idea in the session, letting any method be an inferred
requirement (`T has area`), was **withdrawn**: blocks already do the job,
explicitly, and it would be type-level cleverness for its own sake.

## 4. Services: a dep is something you're given

**A `dep` is a service: something you're given, not something you
hold.** It's provided by the composition root, one per scope, and code
asks for it by name in `uses`. It isn't only the world: a repository, a
policy applied at run time, feature flags, an id generator and an
in-memory store are all services, injected even when none of them touch
the network.

A family of actors is a service too: `uses Docs`, installed by the
root, and addressed by key (§11).

The "Ren knows every boundary" pitch survives: the compiler still knows
which services eventually reach the world, because world access happens
only in the built-ins' real implementations (Core Lint checks it).

### What Ren already does, against Effect

Tested on 2026-10-28:

| Effect-TS | Ren today |
|---|---|
| `Context.Tag` and the service's interface | `dep Users = name: fn(id: Int) -> Str` |
| `Layer<Users, E, Db \| Audit>` | `handler db_users() for Users uses Db, Audit` |
| The R channel | a function's `uses` |
| A consumer requires the service, not the layer's needs | `fn greet(id) uses Users` never mentions `Db` or `Audit` |
| A layer states its direct needs | inferred for a private handler; a `pub` handler lists its direct needs, and the error names any missing |
| `Effect.provide(program, MainLive)` | `with mem_db(), console_audit(), db_users() in main()` |
| Unsatisfied requirements are a type error | "nothing installs `Db` before `main`", pointing at the item that needs it |
| A layer is memoized within a provide | one instance per `with`, shared by every item that needs it |
| `Layer.scoped` | `finally` |
| A layer that fails to build | a handler whose state can fail to start (`!`) |
| `Context.Service` whose shape comes from `make` | a `service`, below (decided after this table was tested) |

Ren is ahead in two places: **a `with` is a set the compiler orders**, so
there are no `provide`-versus-`provideMerge` ordering puzzles; and calls
are direct, `Users.name(id)`, with no `yield* Users` first.

### A service: a dep and its implementation, written once

Decided on 2026-10-29. What Effect had and Ren lacked was the other
half of `Context.Service`: its interface is taken from its `make`, so a
service with one real implementation is one declaration. Without that,
closing over requirements meant writing a `dep` and a handler, which was
enough ceremony that request-path code skipped it, and every `pub fn`
on the path repeated its requirements, its config and its errors:

```ren
pub fn get(c: ClientCfg, k: Key) -> Option<Entry> ! ClientError | Conflict | StoreFull uses Http, Clock, Random = ...
pub fn put(c: ClientCfg, k: Key, v: Bytes, cond: Cond) -> Version ! ClientError | NotFound | Conflict | StoreFull
    uses Http, Clock, Random = ...
```

A service writes them once:

```ren
pub type KvError = ! ClientError | NotFound | Conflict | StoreFull

pub service Kv(c: ClientCfg) uses Http, Clock, Random =
  pub fn get(k: Key) -> Option<Entry> ! ClientError | Conflict | StoreFull =
    match call(Request.get(url("/v1/keys/{k}")), idempotent: true)
      resp => Some(try to_entry(try json.decode<EntryOut>(resp.body.bytes())))
      fail NotFound => None
  pub fn put(k: Key, v: Bytes, cond: Cond) -> Version ! KvError = ...
  fn call(req: Request, idempotent: Bool) -> Response ! KvError = ...   // reads c.token, c.retries

fn sync_all(keys: Array<Key>) uses Kv = ...try Kv.get(k)...           // all a caller sees
fn main() uses Net, Console, Clock, Random = with http.live(), Kv(cfg.client) in run()
test handler fake_kv() for Kv = get(_) => None, put(..) => Version.of(1)
```

The rules:

1. **`service S(params) uses R ! E = members` declares the dependency
   `S` and its one implementation.** Its operations are its `pub fn`s,
   whose signatures are written in full: they're the interface. The
   compiler lowers it to exactly a `dep` and a handler, so nothing is
   new underneath.
2. **Members share the service's `uses` and parameters.** A member
   doesn't write `uses`, and can't add one: what it needs goes on the
   service, required where the service is installed (deps.md's rule
   that what an implementation needs is required at its `with`).
   Members call each other directly.
3. **Callers see only `S`.** Its requirements and parameters never
   reach a caller's signature.
4. **It's installed like a handler,** `with Kv(cfg.client)`, in a
   `with` or a wiring, one instance per scope. A `with` item is never a
   value, so `Kv(...)` there can't be read as a constructor. `! E` is
   what it fails to start with, and it may keep state in `var`s.
5. **It's still a dependency,** so any `handler ... for S` replaces it,
   in a test or anywhere else.

**When to write which.** A service is a dependency whose interface
comes from its one implementation: an API client, the request path,
an application's use cases. A dependency with a real choice of
implementations stays a `dep` with handlers: `Orders` in
examples/checkout, `Fs`, `Sql`, `Clock`. A port a domain declares and
infrastructure implements is a `dep` too, so the domain never imports
its adapter.

**Two rules written down with it:**

- **A function's `uses` is the most it may use; its errors are exact.**
  Listing an error a function never raises forces an arm that can't
  run at every call site, so errors are exact (errors.md). Listing a
  dependency a function never uses costs one item at the composition
  root, met once, and tests get test implementations by default. So
  the bound that a stored description's `uses` already was holds for
  every signature, and one name can cover a path whose functions use
  different parts of it.
- **A private function doesn't write `uses`.** It's inferred; writing
  it is clutter that hides the few signatures that must say it. `ren
  fmt` removes it.

This replaces the named `uses` row stage 12 proposed (G3, `pub type Req
= uses Store, Log, Clock`): a request path that needs `Store`, `Log` and
`Clock` becomes `pub service Api(cfg) uses Store, Log, Clock` with one
`pub fn handle(req)`, and callers write `uses Api`. One mechanism, not
two.

## 5. Wirings: the composition root, named

What was missing is a name for a set of handlers. Today it's repeating
the `with` list, or a function that runs a block, which is tied to one
result type, needs `try body()`, and writes out the block's `uses`:

```ren
fn live(body: fn() -> Str uses Users) -> Str uses Console =
  with mem_db(), console_audit(), db_users() in try body()
```

A wiring adds exactly three things to the `with` set: **a name, a limit
on what the body sees, and parameters.**

```ren
pub wiring live(url: Str) provides Users uses Console ! DbDown =
  pg_db(url), console_audit(), db_users()

pub fn main() uses Console, Os =
  try with live(Os.args()[0]), metrics() in serve()
```

### The rules

- **A wiring is flattened where it's used.** Listing `live` in a `with`
  is the same as listing its items there: one set, one instance of each,
  the order found by the compiler. So `metrics()` can share `live`'s
  `Db`. There's still one way to build a graph, the `with` set.
- **`provides` is always written.** It's the wiring's interface. It
  limits only what the body may call; the items inside still meet each
  other. `serve` calling `Db.get` is an error.
- **`uses` and `!` are what it needs from outside,** inferred for a
  private wiring and written for a `pub` one, direct needs only, as for
  handlers. A wiring fails to start with the union of its items' `!`,
  and is installed with `try with`.
- **A wiring is not a value.** It's declared at the top level, code by
  name, like a chain `a over b`, which a wiring can also name as one of
  its items.
- **Its body is items only.** Code that runs around a block stays a
  function, as `retry` does. A wiring installs; a function runs.
- **The one function that installs is addressing.** `Docs.at(id) fn()
  => body` installs one actor for its block (§11), because its key is
  known only at run time, so no wiring could name it. It's the
  runtime's keyed instance family that installs, and any library over
  it addresses the same way. Addressing installs, wiring composes.
- **Wirings combine.** `with live, metrics in ...`, and a wiring can list
  another among its items.
- **Parameters** carry config, and can be descriptions, functor-style:
  `wiring app(db: Db) provides Users = db, ...`.
- **Plain `with` keeps exposing everything it installs.** Hiding is the
  wiring's job; making `with` hide would change every existing `with`.
- **Teardown** runs `finally` in reverse install order, ties broken by
  dependency name as today, so it's always the same order.
- **The keyword is `wiring`.** `layer` suggests Effect's values with
  memoization by identity, and `over`'s stacking; `root` is wrong for
  something that composes and is used in tests.

### Tests: split the wiring, don't patch it

Dagger's advice after years of experience, and Effect's `layerNoDeps`
pattern:

```ren
wiring core provides Users = console_audit(), db_users()   // needs Db, inferred
pub wiring live(url: Str) provides Users = core, pg_db(url)

test "a lookup is audited" =
  with core, mem_db([]) in ...
```

- **No `with live but mem_db() in ...`.** It's a second way to say
  "these items", and it couples tests to a wiring's insides, which is
  what Dagger warns against: "adding new dependencies will break tests".
  Revisit only if real programs show deep overrides an author couldn't
  foresee.
- Parameters are for substitutions the author planned; splitting is for
  those they didn't.
- Built-ins already get test implementations in tests, so `with
  live(url) in try main()` in a test captures `Console` with no override.

### Two instances of one service

- **Aliases and `as`**, as today: `dep Replica = Db`. Every system
  studied needs a new type or a qualifier here, and Ren's is the
  lightest.
- **Not in v1:** two copies of a whole sub-graph, two `Users` stacks each
  with its own `Db` (Guice's "robot legs"). Nest a `with`, or alias the
  second stack's dependencies. A sealed wiring whose insides stay private
  could come later.

### Errors

Each names where, and has a fix-it:

- **A missing need:** "nothing installs `Db`, which `db_users()` in
  `live` needs", pointing at the `with` and at live's line. Help: "add an
  item that installs `Db` beside `live`: `with live, mem_db() in`", or,
  for a `pub` wiring, "add it to `uses`".
- **A hidden service used:** "`live` installs `Db` but doesn't provide
  it". Help: "add `Db` to `live`'s `provides`", or "install your own
  inside: `with mem_db() in`".
- **A duplicate through flattening:** "this `with` installs `Db` twice:
  `mem_db()` here, and `pg_db(url)` in `live` (live.ren:2)". Help: use a
  smaller wiring that leaves `Db` out, if one exists, or remove one.
- **A cycle:** named as a loop, `a → b → a`, drawn as ZIO draws it.
- **`provides` names what nothing installs:** "`live` provides `Clock`,
  which nothing in it installs".
- **An item nothing uses is an error,** not a warning: Ren has no
  warnings. "`audit()` in `live` provides `Audit`, which nothing needs".
- **A wiring used as a value:** "a wiring isn't a value", help: "install
  it: `with live in ...`".
- **`ren explain-wiring live`** prints the order chosen and what each item
  meets, like ZIO's `Debug.tree`.

### Left out

Memoization by identity, a `provideMerge` twin, `but` and `replace`,
default handlers beyond the built-ins (Flix's `@DefaultHandler` is
found behind your back), automatic search for implementations
(Dagger and Hilt), and sealed wirings for now.

### Where it could become magic

- **Flattening** means a `pub` wiring's internal `Db` can collide with a
  user's. That's the price of sharing, and the duplicate error must name
  the wiring, or it feels like action at a distance.
- **A wiring versus a function taking a block:** the line has to stay
  sharp. A wiring installs; a function runs code.

## 6. Stored descriptions: an enum the compiler writes

**In a closed world, a description is an enum the compiler assembles.**
Each `handler ... for D` in the program is a variant, and each operation
call is a `match` the compiler writes. That's how decision 4 lowers it:
a tag, then a compare or a table. It's defunctionalization, not objects.

So the difference between an ADT and a description is **who writes the
enum**:

| | You write it (an ADT) | The compiler writes it (a description) |
|---|---|---|
| Variants | in one place | spread out, "one declaration anywhere" |
| Behaviour | in a `match` you wrote | each variant carries its own arm |
| As data | `==`, `show`, store, decode | opaque: call it and nothing else |
| Adding a kind | edit the enum and the `match` | add a handler, touch nothing |

**The rule: if you own every kind, write the ADT. If others add kinds,
let the compiler write it.**

There is always another way. A framework can be generic over the user's
enum and take the dispatch as a block, the Elm architecture's `Msg` and
`update`:

```ren
type Route =
  | Health
  | GetUser(id: UserId)
  | Static(files.Dir)          // a library's kind, wrapped

fn handle(r: Route, req: Request) -> Response uses Db =
  match r
    Health => ok("up")
    GetUser(id) => users.show(id)
    Static(d) => files.serve(d, req)

http.serve(routes, handle)     // serve<R>(routes: Array<R>, handle: fn(R, Request) -> Response)
```

Descriptions earn their place where "touch nothing" matters: a library
taking kinds its users define, where a wrapper enum and dispatcher per
user would be busywork. Middleware, codecs, plugins and routes are like
that, and they're usually effectful, so descriptions keep their `uses`
rows. Domain modelling almost never is: the domain is yours, and you want
the list in one place.

Decisions:

- **foundations.md decision 3 is reframed.** No more "Ren's answer to
  `dyn Trait`". Its example becomes routes, not shapes.
- **Calling an operation on a description works only for a stateless
  handler.** On a stateful one it's an error whose help writes the
  `with`. That removes the `counter()` trap, and method syntax on a
  description always means a pure dispatch.
- **`Shape` and `Expr` become ADTs** wherever docs and benchmarks use
  them to model data. Benchmarks that measure description dispatch keep
  a dep, over something a library would really store.
- **Descriptions stay in v1 in full.** Narrowing them to one-operation
  inline handlers was considered and not taken: the fourth question is
  worth answering, and nothing else answers it.
- **A policy is data, and a description only where others add kinds.**
  The standard library's own knobs are ADTs (`evict: Lru`, `by: Worker`,
  `merge: Sum`). A description appears only where a program supplies
  the kind: a `striped` merge the built-in folds don't cover is a
  stateless handler over the dependency, folding in a `call(c: D.Call)`
  clause (§11).
- **`D.Call`, `D.Reply` and `D.Error` are data enums the compiler
  writes.** For a dependency whose operations are all data, the
  compiler writes a sum with a case per operation, a sum of replies,
  and a named error set ([formats.md](formats.md#dependencies-as-data)).
  They're the exception to the table above: the compiler writes them,
  but they're data, with `==`, `show`, shapes and looks, not opaque
  descriptions.
- **Looks are values too.** `Time.unix` is a `Look`, which a library's
  settings hold in an array and compare with `==`. The compiler
  represents looks as an enum it writes, one tag per format, and that
  enum is invisible: no program sees it.

## 7. Methods are vocabulary, workflows are functions

- `x.m(a)` is `Type.m(x, a)`: namespacing.
- **Convention: a type's methods are its own vocabulary and its
  invariants. Workflows are free functions in modules.** `order.total()`
  is what an `Order` knows about itself; `checkout.place(order)` is
  something that happens to it.
- **No UFCS.** `.` reaches only the type's own members, so it tells the
  reader something: the operator says where code lives. `.` is the
  type's vocabulary, `|>` is a step from elsewhere.
- Methods only in the type's own declaration, as today: no adding
  methods to someone else's type, no orphans.

The convention can't be enforced by a checker. Docs, examples and the
standard library have to model it relentlessly, or types grow forty
methods.

## 8. The pipe, and `try` on each step

```ren
order
  |> try validate
  |> price(Discounts.for_customer(c))
  |> try checkout.place
```

### The rules

- **`x |> f(a)` is `f(x, a)`, and `x |> f` is `f(x)`,** checked exactly
  as that call. The value goes **first**, matching `self`-first methods;
  its type is known before the arguments are checked, and nothing relies
  on currying. "A workflow takes its subject first" is a stated rule for
  the standard library and style, which avoids Effect's `dual` (every
  API both data-first and data-last).
- **A target is decided by the parser alone, never by types:** a function
  name, `module.f`, `Type.f`, a function parameter, a `let`-bound block,
  or a call to one of those. Gleam falls back on types (`b(a, 1, 2)` or
  `b(1, 2)(a)`); Ren doesn't guess.
- **Values only.** No `&` and no `inout` through a pipe. Changing in
  place stays a statement, `&xs.push(x)`, where exclusivity can see it.
- **No blocks as steps,** and no placeholder (`_`) or `then`. A subject
  that belongs in another position gets a `let`, or a named block, `let
  step = fn(o) => ...` then `|> step`. A placeholder would be a second
  syntax for partial application. R's pipe had to wrap lambda targets in
  parentheses, or the body swallowed the rest of the chain.
- **`|>` into a method of the piped value's own type is an error** whose
  help writes `.m()`. One way to call a method, and `|>` keeps meaning "a
  step from elsewhere". The friction: calling `.len()` mid-chain needs a
  `let` or parentheses. Kept strict; revisit if real code hits it often.
- **Each link is one term, so there's no precedence table.** `total + fee
  |> round` is an error asking for parentheses. That removes F#'s and
  OCaml's trap, where `|>` shares precedence with `=`, so `a = b |> f` is
  `(a = b) |> f`.
- **`orelse` may follow a chain,** applying to its result. Anything else
  after a chain needs parentheses: a chain ends its expression.

### `try` on each step

- **Every link, the head included, is `[try | attempt] term`.**
- **`|>` ends the reach of `try` and of `attempt`.** Today `try` covers
  every call to its right in the expression, as in Swift (errors.md), and
  `attempt` runs up to a comparison. In a chain, each covers only its own
  step.
- **A step that can fail without its own `try` is an error,** with a
  fix-it that adds it, even inside `attempt (...)` or `match (...)`.
  Those still receive the error the step's `try` passes on, as they do
  today.
- **A `try` on a step that can't fail is an error,** as it is today
  ("nothing here can fail").
- **This is a deliberate exception to Swift's rule.** Swift forbids `try`
  to the right of an operator ("'try' cannot appear to the right of a
  non-assignment operator"). Ren allows it after `|>`, and documents it.

Why a prefix `try` on each step, rather than one `try` for the chain or a
postfix `?`:

- The steps that can fail **are** the domain workflow: "validate can
  reject, place can fail, price can't". You want that on the page.
- It's the only `try` spelling Ren has, so there's one way to mark a
  call. The markers line up in a column after `|>`.
- No doubt about what it binds. On Roc's `a |> foo(b)?` meaning `(a |>
  foo(b))?`, its author said "It still looks surprising to me".
- TC39's pipeline proposal hit the same problem with `await`: both its
  designs needed a marker on each step.

### Grammar and layout

```
pipe  := link ("|>" link)* ["orelse" expr]      between orelse and or
link  := ["try" | "attempt"] term
term  := a unary or postfix expression, no binary operators
```

- `|>` is a new two-character token, lexed before `|`. It doesn't clash
  with sum-type lines, error sets or `fail A | fail B`, which look for
  `|` alone (lexer.ml:421, 444; parser.ml:580 to 706).
- `try`'s parser takes a whole expression today (parser.ml:1225), so it
  must stop at `|>`; so must `attempt`.
- **A line starting with `|>`, indented further than its block,
  continues the line above.** It joins `continues()` (lexer.ml:220)
  beside `uses`, `!` and a trailing `,`. Without this, a vertical chain
  doesn't parse. **A line starting with `.`, indented further, continues
  the line above the same way,** so a chain of stages over a cursor can
  put one stage on a line ([streams.md](streams.md#pipelines-and-the-pipe)).
- **Formatting is all or nothing.** If a chain doesn't fit on one line,
  or has more than two steps, the head goes on its own line and each `|>
  [try] step` on its own line, one indent in.

### Errors

```
error: `validate` can fail, and nothing handles it
  |> validate
     ^^^^^^^^ it can fail with `Bad`
  = in a chain each step that can fail carries its own `try`
  help: write `|> try validate`, or handle it with `match`
```

```
error: nothing here can fail
  |> try price
     ^^^
  = `try` marks the calls that can fail, so a reader can see where the code can stop
  help: remove the `try`
```

```
error: `try` stops at `|>`
  try order |> validate |> checkout.place
  ^^^
  = it covers only `order`, which can't fail; each step is marked on its own
  help: `order |> try validate |> try checkout.place`
```

```
error: `len` is `Array`'s own method, so it's called with `.`
  |> Array.len
     ^^^^^^^^^
  help: write `(...).len()`, or end the chain with a `let`
```

```
error: `|>` puts `rules` first, but `pricing.apply` takes an `Order` there
  rules |> pricing.apply(order)
  - `rules` is a `Rules`, which `pricing.apply` takes second
  = `|>` always passes its value as the first argument
  help: call it directly: `pricing.apply(order, rules)`
```

The "takes second" line appears only when another parameter's type
matches the subject.

```
error: `|>` passes a value, so nothing in a chain can change it
  &cart |> add(item)
  ^
  help: call it with `&` directly: `add(&cart, item)`
```

The same for `|> &f`.

```
error: a step is a function by name, not a block
  |> fn(o) => pricing.apply(o, rules)
  help: name it first, `let apply_rules = fn(o) => ...`, then `|> apply_rules`
```

```
error: `|>` takes one value on its left
  total + fee |> round
  ^^^^^^^^^^^
  help: put it in parentheses: `(total + fee) |> round`
```

```
error: a chain ends its expression
  order |> price == expected
                 ^^
  help: put the chain in parentheses, or name it with `let`
```

## 9. Collections: `Array`, `Table` and `Pool`

### What a `Table` is for

vision.md says Ren is for command-line tools, servers and storage
engines, and for compiling itself. Those are full of one shape:

| Program | The collection | What the hot loop touches |
|---|---|---|
| A compiler (self-hosted Ren) | tokens, syntax nodes | the tag and an offset; Zig's and Roc's compilers keep these as columns |
| A storage engine | B-tree keys, memtable entries, page descriptors | keys for a binary search; `dirty` and `lsn` when flushing |
| A server | connections, sessions, rate-limit buckets, timers | `last_seen` when sweeping for timeouts |
| A build tool | the file index | `mtime` and `hash` |
| A simulation, TigerBeetle-style | nodes, messages in flight | a delivery time and a destination |

**A population: many values of one type, owned in one place, swept by
hot loops that read a few fields each.** That's the problem `Table`
solves. Not querying, relating or analysing data.

### Marrying domain-driven and data-oriented design

**Domain-driven design decides what a thing is and which rules it keeps.
Data-oriented design decides how many of them sit in memory and how
loops sweep them.** Ren keeps them at different altitudes: types carry
meaning, collections carry layout, and changing the collection never
changes what a value means.

Elsewhere that separation is impossible, which is why the schools fight:

- In C++, going data-oriented takes classes apart into parallel arrays.
  `Body` and its invariants dissolve into `xs[]`, `vs[]` and `masses[]`,
  and every rule is now a convention.
- In an ECS, an entity is dismembered into components by design; no
  domain object is left.
- Encapsulation blocks struct-of-arrays: a getter hides which fields are
  touched, so a compiler can't split them.

Ren gets out through properties it already has:

1. **No addresses,** so `Table<Body>` can mean exactly what `Array<Body>`
   means. Zig's `MultiArrayList` needs a different API (`items(.field)`,
   no pointer to an element) because Zig hands out addresses.
2. **Whole-program specialization,** so when a loop calls an opaque
   type's method, `&b.integrate(dt)`, a release build sees through the
   inlined method to the fields it touches and reads only those columns.
   Encapsulation and struct-of-arrays stop being enemies.
3. **Visibility follows the type.** Raw columns of an opaque type are
   reachable only inside its module, so column sweeps live with the
   type's vocabulary, and everyone else goes through its methods.

**Layout is infrastructure, so it lives behind the service.** In DDD,
collections of aggregates live in repositories, and persistence is
infrastructure; layout is too, so it goes in the same place:

```ren
pub dep Sessions =
  touch: fn(id: SessionId, now: Time) -> ()
  expire: fn(now: Time) -> Array<SessionId>

handler mem_sessions(ttl: Duration) for Sessions =
  var all: Table<Session> = Table.empty      // the layout choice lives here
  expire(now) =>
    // reads one column, `last_seen`
    all.select(fn(s) => now - s.last_seen > ttl).map(fn(s) => s.id)
  ...
```

The domain sees `Sessions.expire(now)`. Whether the implementation holds
an `Array`, a `Table` or a `Map` is invisible to it, so the composition
root is also where performance decisions are swapped: a test uses the
simple implementation, production the tuned one.

**References are ids.** Vernon's rule, reference other aggregates by
identity, and data-oriented design's rule, indices instead of pointers,
are the same rule. Ren has it in `Id<T>`.

### Two names, one question

| Layout | Good at | Bad at |
|---|---|---|
| **Rows**, `Array<T>` | whole elements, random access, `push`, `sort` | sweeps over a few fields, vectorizing |
| **Columns**, `Table<T>` | sweeps over a few fields, vectorizing, mixed field sizes | whole elements, random access, `sort` |

**Do my hot loops use whole elements or a few fields?** `Array` for the
first, `Table` for the second. Two names, not a layout parameter:
`Table<T, rows>` would be `Array<T>`, a second spelling.

**Blocks of columns (AoSoA) are left out.** They help vectorized code
over wide records, but break `columns` returning one contiguous slice,
and Ren's target programs are mostly scans and searches. Added only if a
benchmark needs it, perhaps as `Table.blocked(16)`.

**Struct-of-arrays is never automatic.** Every language studied (Zig,
Odin, Jai) makes it opt-in: a wrong guess makes code slower with no
visible cause, which breaks "nothing found behind your back". The choice
is stated once, on the collection.

### What a `Table` means

- **Exactly `Array`'s meaning.** Switching between them changes cost,
  never behaviour, so it's safe to try either way and measure.
- **A loop reads only the columns it touches.**

  ```ren
  var bodies: Table<Body> = Table.empty     // was Array<Body>; one word changed

  for b in &bodies                          // written per element
    b.pos = b.pos + b.vel * dt              // touches the pos and vel columns only
  ```

  You write per-element code and get columnar access. In a debug build,
  elements are gathered and scattered whole: slower, the same meaning.
  `Table`'s gains need release specialization, and that's documented, so
  nobody benchmarks a debug build.
- **Records are flattened all the way down:** `pos.x` and `pos.y` are
  their own columns.
- **A sum type gets one tag column plus one payload column,** Zig's
  layout, with each payload, nested records included, stored as a row.
  A sweep that counts kinds reads only tags. A column per variant and
  field wastes space when variants differ; a sub-table per variant (ECS
  archetypes) changes iteration order, which changes meaning.
- **Built in,** in the prelude like `Array`: the loop rule needs the
  compiler.

### The columns view

`bodies.columns` is a view whose fields are `Body`'s fields, each a
column:

```ren
let total_mass = bodies.columns.mass.sum()

for i in 0..bodies.len()
  bodies.columns.pos[i] += bodies.columns.vel[i] * dt
```

- **No new syntax.** It's field access. The alternatives: a special
  argument, `bodies.column(mass)`, where `mass` means "a field of `T`" in
  one position only; or fields as values, `bodies.column(Body.mass)`,
  which adds lenses.
- **Flattening reads naturally:** `bodies.columns.pos.x` is the path
  you'd write on one `Body`.
- **Visibility is unchanged:** on an opaque type it works only in its
  module.
- **A column is a slice** (foundations.md decision 17), so `for m in
  &bodies.columns.mass` writes through it.
- **Exclusivity already allows it:** different fields of a place don't
  overlap (decision 2), so reading `vel` while writing `pos` needs no
  new rule.
- **A `Table` of a sum type has no `columns` view in v1**, since the tag
  isn't a field. It's swept by element, which reads only the tag column
  when an arm uses no fields. A tag view is later.

### Guardrails: not relational, not a dataframe

The danger comes one method at a time: `join`, then `where`, then
indexes, then a query planner.

1. **`Table`'s API is `Array`'s API plus `columns`.** A method you'd want
   only on `Table` is either an `Array` method or doesn't belong. `Table`
   changes cost, never vocabulary.
2. **Columns are a type's fields, known when compiling.** No columns
   named by strings, none added at run time, no untyped data. If it isn't
   a Ren type, it isn't a `Table`.
3. **Relationships aren't the collection's job.** Lookup by key is a
   `Map`, a reference is an `Id<T>`, and there are no joins and no
   indexes. Bringing related things together is a loop you write, in the
   module that owns them.

`Array` already has Ruby's `Enumerable` (`select`, `group_by`, `tally`),
and `Table` inherits it. That's ordinary collection vocabulary, not a
query language, but `group_by` and `tally` are the edge of what a
collection should do.

### `Pool`: identity through churn

Identity in Ren is always data, an id, never an address. The question is
what happens to an id when what it named leaves the population, and it
depends on the lifecycle:

| Lifecycle | Examples | What identity needs |
|---|---|---|
| Only appended to | tokens, syntax nodes, ledger accounts, log entries | nothing: an id is an index |
| Built, then dropped whole | per request, per compiler pass, an arena | nothing: an id is an index |
| Churns | sessions, connections, timers, cache entries, messages | removal, reused slots, and stale ids |

The first two need no machinery: `Id<T>` is a typed index into an `Array`
or a `Table`. Churn is the hard case: session 7 expires, its slot is
reused, and an old id now silently names someone else.

| Design | A stale id | Sweeps | Lookup |
|---|---|---|---|
| Free list, id = index | **names the wrong thing, silently** | skip holes | direct |
| **Generational ids** (Rust's slotmap, Bevy) | detected | skip holes, via one liveness column | direct, plus a compare |
| Sparse set (EnTT) | detected | packed | one more indirection |

Decisions:

- **`Pool<T>` is plain Ren in std,** over a `Table` of `{ gen, value }`
  slots. Three questions, kept apart: what a thing is (its type), how
  many sit in memory (`Array` or `Table`), whether they keep identity
  through churn (`Pool`). A user's pool over a collection of their own
  is written the same way; the compiler knows nothing of `Pool`.
- **Generational ids.** The `Table` flattens the slot, so the generation
  is one more column, and checking it reads only that column. A sparse
  set can come later behind the same API if dense sweeps under heavy
  churn need it.
- **Generations never wrap: a slot is retired** when its generation would
  overflow. Cheap, and it removes the silent case entirely.
- **`pool.get(id)` returns `Option<T>`,** since a stale id is expected (the
  session expired), as with `xs.get(i)`. **`pool[id]` panics** on a stale
  id, since there it's a bug, as with an index out of bounds.
- **Iteration is in slot order:** deterministic, not insertion order.
  Documented, because `Map` promises insertion order.
- **In the prelude,** beside `Table`: it's how infrastructure holds
  entities.

### `ren profile` suggests, with numbers

"This loop touches 2 of 9 fields of an `Array<Body>`; a `Table` would
read 4.5× less memory." The language points to the right thing with
measurements, not rules.

### Strains, accepted

- **A population of mixed kinds.** Data-oriented design says group by
  kind to avoid mispredicted branches; domain-driven design says one sum
  type. A sweep that `match`es per element branches. Out of scope: it's
  the road to an ECS.
- **Debug builds** are slower with `Table` than with `Array`, never
  faster.
- **Hot and cold fields** need no separate design: columns *are* the
  split.

The approach to every strain: design so the right thing is easy and the
default.

## 10. Advice that isn't an error

### The "this is data" hint

A stateless, pure dep can be legitimate: a `Discounts` service injected
at the root uses nothing and is fine. What makes it a smell is the test
from §1: **holding many, not being given one.** The hint fires only when
all of these hold:

- every handler for the dep is stateless (no `var`, `finally`, `next` or
  `over`), uses nothing, and can't fail to start;
- every handler is in the dep's own module, so you own every kind;
- and the program **holds** its descriptions, in an array, a field or a
  map, not only installs them with `with`.

```
hint: `Shape` is data
   ┌─ shapes.ren:1:5
 1 │ dep Shape =
   │     ^^^^^
 9 │ let shapes: Array<Shape> = [circle(1.0), square(2.0)]
   │             ------------ holds many of them
   = every handler for `Shape` is stateless, uses nothing, and is declared here
   = an ADT can be matched, compared, shown and stored; a description can only be called
   help: as an ADT:
           type Shape =
             | Circle(r: Float)
             | Square(s: Float)
             pub fn area(self) -> Float =
               match self
                 Circle(r) => 3.14 * r * r
                 Square(s) => s * s
```

The handlers' parameters become the variants and their arms the `match`.
It's mechanical, since a description already is an enum the compiler
writes; this shows you that enum.

### Where advice lives: `ren review` and the editor

Ren has no warnings, and this record keeps it that way (an unused
wiring item is an error). The hint can't be an error, since the code is
legal. So advice gets its own home:

- **`ren review`** prints design advice, separate from `ren build`. CI
  can run it if a team wants advice enforced.
- **The editor shows what `ren review` would say,** as information hints
  with code actions, such as the fix-it that writes the ADT.

The compiler's output stays things you must fix, and advice has one
home. Future advice goes there too, such as "this loop wants a `Table`",
if that isn't `ren profile`'s job. The cost is one more concept, accepted.

The alternatives were the editor only, which CI can't see, and
`ren review` only, which you'd have to remember to run.

## 11. Many stateful things: data or actors

A server holds many stateful things: sessions, documents, rate-limit
buckets, cache entries. Ren has two answers, and the ethos allows two
only if one test picks between them.

**The test: is it a population you sweep, or entities that do I/O?**

| | Data in one service | Actors |
|---|---|---|
| The shape | a population swept and related by hot loops | independent entities, each with its own I/O and its own order of operations |
| Examples | expiring idle sessions, summing balances, a file index, timers | a document with subscribers, a per-user cache that fetches on a miss, a rate limit per user |
| How it's held | `Table`, `Array` or `Pool` behind a `dep` (§9) | `actors`, one instance per key, made on demand |
| One slow operation | stalls the service | stalls one key |
| Across many | one loop | `Docs.each`, one call per actor |

A ledger, where every transfer touches two accounts, is data:
cross-key invariants want one owner. A collaborative editor, where each
document saves and broadcasts on its own, is actors. When both fit,
data is the simpler answer.

### Actors are a service

```ren
dep Doc =
  edit: fn(op: Op) -> Version ! StoreDown
  join: fn(c: ConnId)
  leave: fn(c: ConnId)

handler doc(id: DocId) for Doc uses Store, Conns =
  var text = try Store.load(id)              // runs when `at` makes the actor
  var subs: Array<ConnId> = []
  edit(op) =>
    text = text.apply(op)
    try Store.save(id, text)                 // write-through: the store holds what's durable
    for c in subs => Conns.send(c, op)       // every subscriber sees one order
    text.version
  join(c) => &subs.push(c)
  leave(c) => &subs.remove(c)

dep Docs = Actors<DocId, Doc> ! StoreDown

pub wiring live(url: Str) provides Docs uses Net ! StoreDown =
  pg_store(url), conns(), actors(doc, max: 50_000) as Docs

fn session(conn: Conn) ! StoreDown | Closed uses Docs =
  let id = try handshake(conn)
  try Docs.at(id) fn() =>
    Doc.join(conn.id)
    finally(_) => Doc.leave(conn.id)
    for op in conn.ops() => try Doc.edit(op)
```

- **`actors` is plain Ren in std,** over the runtime's keyed instance
  family, which keeps the live instances, pins them, evicts them and
  queues their calls (foundations.md decision 18). Its policies, the
  bound, the mailbox and eviction, are std's.
- **A family is a dependency, `Actors<K, D> ! E`,** with `E` the errors
  of making an actor, which `try Docs.at(id)` can fail with. It's named in `uses`,
  installed by the root, and swapped in tests by installing a family of
  a fake handler, `actors(fake_doc, max: 8) as Docs`. Code that works on
  one actor is written `uses Doc` and runs inside `at`, so it's tested
  with a plain `with fake_doc(d1)`.
- **The key is the address.** `Docs.at(k) fn() => body` installs k's
  actor as `Doc` for its block, making it if it isn't live. There's no
  handle to keep, because `Docs` is a dependency. A key can be stored
  anywhere, and a stored key can't dangle: `at` makes the actor again.
- **`actors(doc, max:)` names the handler,** `max:` defaulting to std's
  10_000, whose one
  parameter is the key. What else it needs comes from the `with` set, as
  for any item.
- **An actor can't `at` its own family,** only `post` to it (below).
  Anything else would be a cycle in one `with` set, which is already an
  error, and it's what keeps waits from closing a cycle.
- **Each operation takes the actor for one call**, as every handler's
  operation does (foundations.md decision 10), and the `at` block keeps
  it from being evicted. So a read and a write in two operations race,
  as in every actor system: a read-modify-write is one operation.
- **`post` is Erlang's cast.** `try Docs.post(k, Doc.Call.Edit { op })` puts one
  operation, with its arguments evaluated now, in k's mailbox and
  returns: a message, which is data, a `Doc.Call`, the call value the
  compiler writes for every dependency. `post` takes a call whose
  result is `()` with no errors, an ordinary type rule; the post itself makes the actor, as
  `at` does, so it fails only with setup's errors. An actor posts to its
  siblings by naming its family in `uses`. Every call from outside, a
  post or an `at`, waits while the family's mail is over its `mailbox:`
  bound; a sibling's post never waits, and past twice the bound it
  panics, as runaway recursion does.

The rest, setup, eviction, periodic work, deadlock and what `sim` does,
is in [foundations.md decision 18](foundations.md#18-actors-and-stripes).

### Stripes: one service on many cores

`striped` keeps a fixed number of instances of one handler and
map-reduces over them, plain Ren in std over the same family. Callers
can't tell: code that `uses Hits` doesn't know whether one instance
serves it or sixteen.

```ren
dep Hits =
  hit: fn(path: Path) -> ()
  total: fn() -> Int

with striped(counter(), by: Worker, merge: Sum) in serve()
```

- **Routing is an ADT, `by: Key(n: 16) | Worker`.** Under `Key(n)`, the
  default, an operation whose first parameter has a `key` goes to one
  of n stripes by it. Under `Worker`, which has no count, it goes to
  the stripe of the worker it's running on, from `Async.worker()`.
- **An operation with no key runs on every stripe.** One that returns
  `()` broadcasts; one that returns a value is folded with `merge:`, in
  stripe order.

### Policies are data

Every knob on `actors` and `striped` is an ADT from the standard
library, as §2 says a rule should be:

```ren
actors(doc, max: 50_000, evict: Lru)              // or Lfu
actors(doc, chaos: true)                           // a test's: evicts what Random picks
striped(sessions(ttl), merge: Concat)              // Sum, Max, Min, Concat
striped(books(), by: Key(n: 64), merge: Custom(book_merge()))  // the rare kind the menu lacks
```

`Custom` holds a description, a stateless handler over `Books` whose
`call(c: Books.Call)` clause folds two stripes' results for the call
`c`. There's no derived `Merge` dependency: the call value is the one
every handler over any dependency already gets. That's §6's rule: a
description where the program adds the kind.

### The marriage: a partitioned table

Data-oriented design inside each stripe, actor scaling across them:

```ren
handler mem_sessions(ttl: Duration) for Sessions =
  var all: Table<Session> = Table.empty
  touch(id, now) => ...
  expire(now) =>                              // sweeps one column, `last_seen`
    all.select(fn(s) => now - s.last_seen > ttl).map(fn(s) => s.id)

with striped(mem_sessions(ttl), merge: Concat) in serve()
```

Each stripe sweeps its own columns, `touch(id, ...)` goes to one
stripe by the id's key, and `expire` runs on all sixteen and
concatenates. The domain still sees `Sessions.expire(now)`.

## 12. Bytes: types and their formats

Ren has no structs with a layout promise. A record is a struct in every
sense that affects how code is written, nominal, named fields, a value,
stored inline when small, but it promises nothing about field order,
padding or size. That's what lets the compiler reorder and pack fields,
unbox values and store a `Table` as columns, and everything in §9
depends on it. Where layout *is* the meaning, a page on disk or a frame
on the wire, Ren uses **formats**. The full design is
[formats.md](formats.md); how it runs is
[foundations.md decision 19](foundations.md#19-formats-are-views).

**A type says what a thing is. A format says how it looks as bytes.**

```ren
type PageHeader = { lsn: Lsn, count: Int, kind: PageKind }

format disk for PageHeader, le, size 32 =
  magic: UInt32 = 0x52454E31       // a constant: checked on read, written on write
  checksum: Bytes[16]               // the format's own field
  lsn: UInt64 as Lsn                // the type's field, placed; `Lsn`'s constructor runs
  count: UInt16
  kind: UInt8 { Leaf = 1, Branch = 2 }
  _: reserved(1)

let h = try PageHeader.disk.view(page[0..32])   // checked once
h.lsn                                            // a load, can't fail
try PageHeader.disk.edit(&page[0..32]) fn(&h) =>
  h.lsn = next_lsn                               // one field, in place
```

The decisions:

- **Every format is for a type, and a type can have several.**
  Versions, disk and wire, and migrations are other formats of the same
  type. Fields named like the type's are placed; constants, checksums,
  reserved bytes, lengths, counts and tags belong only to the format,
  so the domain type never mentions bytes. There are no standalone
  formats.
- **Accessors, never casts.** A view is a slice and a format; reading a
  field is a load. No record is ever laid over bytes.
- **Fields go in order; `at` is a checked note; `size` means every byte
  belongs to a field.**
- **Byte order is always written,** per format, overridable per field.
  There's no default; machine order is `trust`.
- **A closed set of field kinds,** variable-length and tagged ones
  included: `Bytes[n]`, `Array<F>[n]`, `CStr`, `VarUInt`, bit fields, a
  `case` on a tag. Tags, lengths and counts are filled in when writing.
  An opaque type is placed with `as`, so its invariants are checked.
- **`view` is the one way in.** It checks once; after that, reading
  can't fail. `.value` decodes into the type, `.rest` is what follows.
  Writing one field is a block, `edit(&page[..]) fn(&h) => h.lsn = x`,
  so the borrow ends with it; `write` and `encode` take the whole value.
- **Errors carry offsets** in the whole buffer: `Short(at, need)`,
  `Malformed(at, path, why)`, `UnknownTag(at, tag)`.
- **One writable layout per type; older ones `reads`, with values for
  what they lack. Released formats are frozen** by fingerprints in
  `formats.lock`.
- **No byte patterns in `match`.** Formats are the patterns, and
  exhaustiveness lives on the decoded type.
- **A format is what a protocol spec's tables say, and nothing more.**
  Offsets that point elsewhere, backtracking and checksums are ordinary
  code.

Three layers, an omakase default and then sharper tools:

| Layer | For | Promises |
|---|---|---|
| **1.** `bin.encode(v)`, derived from the type's shape | messages between your own processes, caches | nothing about layout or across versions: **not for disk**, and documented so |
| **2.** formats | disk and wire formats | layout, byte order, validation, versions |
| **3.** `b.u32_le(at)`, bit operations, slices | what formats deliberately don't do | what you write |

Layer 2 compiles to layer 3's calls. Each layer is complete, and you go
down one only where the one above doesn't fit.

## Domain-driven design in Ren

Wlaschin's *Domain Modeling Made Functional* is domain-driven design done
the ML way, and Ren's features line up with it:

| Domain-driven design | Ren |
|---|---|
| Value object | an opaque type with checked constructors; `with numeric` |
| Entity identity | `key`, its id |
| States and workflow | sum types and variant types, so illegal states can't be written |
| Aggregate | a module with an opaque type whose methods keep its invariants, all or nothing with `var draft = self` |
| Reference to another aggregate | `Id<T>`, never a pointer |
| Domain error | structural tags in a `!` row |
| Policy or strategy | an ADT, not a handler |
| Repository, gateway, clock | a `dep` |
| An aggregate that lives in memory, one per id | an actor, addressed by its id (§11) |
| Anti-corruption layer | a handler `over` another |
| Domain service, workflow | a free function with `uses`, composed with `\|>` |
| Composition root | `main`'s `with`, and wirings |
| A collection of aggregates, in memory | `Array`, `Table` or `Pool`, chosen behind the repository |

**Inject a policy, or pass it?** Pass it if the caller knows it; inject
it if only the root does. A `dep Discounts` whose handler returns a
`Discount` (data) is fine: the service is given, the policy is held.

## A program, end to end

How Ren is intended to look under this record. `|>`, `wiring`, by-name
variants and `{ .. }` are new.

```ren
// order.ren: the domain. Data, and the rules it keeps.
pub type Line = { sku: Sku, qty: Int, price: Money }

pub type Discount =                       // a policy is data
  | NoDiscount
  | Flat(off: Money)
  | OverAmount { min: Money, off: Money }

  pub fn apply(self, m: Money) -> Money =
    match self
      NoDiscount => m
      Flat(off) => m - off
      OverAmount { min, off } => if m < min then m else m - off

pub type Order = opaque { id: OrderId, lines: Array<Line>, total: Money }
  pub fn total(self) -> Money = self.total     // vocabulary: what an Order knows
```

```ren
// checkout.ren: the services it needs, and the workflow
pub dep Orders =
  save: fn(o: Order) -> OrderId ! DbDown
pub dep Discounts =
  for_customer: fn(c: CustomerId) -> Discount

pub fn checkout(c: CustomerId, cart: Cart) -> Receipt ! Empty | DbDown
    uses Orders, Discounts =
  cart
    |> try validate                          // can reject
    |> price(Discounts.for_customer(c))      // can't fail
    |> try place                             // can fail: DbDown
```

```ren
// main.ren: the composition root, the one place that knows who provides what
pub wiring live(url: Str) provides Orders, Discounts uses Net ! DbDown =
  pg.pool(url), sql_orders(), discounts_from_db()

pub fn main() uses Console, Net, Os =
  try with live(Os.args()[0]) in http.serve(routes)
```

```ren
// a test: services built from data, nothing mocked by hand
handler fixed(d: Discount) for Discounts =
  for_customer(_) => d

test "a flat discount comes off the total" =
  with mem_orders(), fixed(Flat(Money.dollars(5))) in
    let r = try checkout(ann, cart_of_20)
    assert r.total == Money.dollars(15)
```

What reading it tells you:

- `.` and `|>` say where code lives: `order.total()` is the type's own;
  `|> try place` is a step from elsewhere.
- The `try`s are the workflow's failure points, on the page.
- `uses Orders, Discounts` is the workflow's whole list of needs. It
  doesn't know the real `Orders` needs Postgres.
- The domain is data and functions. Services appear only where a
  workflow asks for them.
- A policy is a value: matched in the domain, stored, decoded from
  config, handed to a test handler.

## What changes from today

| Before | After |
|---|---|
| Handlers as "Ren's answer to `dyn Trait`" | descriptions as an enum the compiler writes, for open sets |
| `dep` meant the world | `dep` means a service you're given |
| Data interfaces as deps and handlers | ADTs, and blocks for generic algorithms |
| A stateful handler callable as a method, starting fresh each call | an error whose help writes the `with` |
| Wrapper records per state, boxed | variant types, laid out flat |
| Positional patterns that can silently swap fields | by name for several fields |
| No record update, record patterns, or-patterns, `as` or let-else | all five |
| Wiring by repeating `with` lists, or a function taking a block | named wirings that hide what they don't provide |
| No pipe | `\|>`, a `try` on each step |
| Data-oriented work by hand | `Table`, `Pool`, `ren profile` suggestions |
| `Shape` and `Expr` as deps in docs and benchmarks | ADTs |
| `sync.keyed(n, h)`, stripes held across their calls | `striped`, a map-reduce, and `actors`, one per key, both services |
| Explicit layout, open: a type that opts out of the compiler's layout | formats: views over `Bytes` for a type, several per type |

**Docs.** foundations.md decision 3 reframed, and new decisions for ADTs,
services and wirings, the pipe and the collections. The README gains the
ethos, the four-question table, methods versus workflows, the pipe, and a
domain-driven example. The README leads with "Ren knows every boundary
your program crosses"; that stays true and valuable for testing, replay
and tracing, but it's now a consequence of the design, not its identity.
Whether the README leads with domain modelling that's fast by default
instead is decided when it's written.

**Compiler.** Record update and patterns, or-patterns, `as`, `let ...
else`, by-name variants, variant types, the layout fixes, wirings, `|>`
with its `try` rule and errors, the stateless-only rule for operation
calls, `Table`, `Pool`, the hint, formats.

## Where it could go wrong

Accepted, and watched, because each could quietly undo the ethos:

1. **The methods convention is only a convention.** Nothing stops a
   forty-method `Order`. No lint can judge "vocabulary".
2. **ADT-first only works if ADTs are excellent.** If matching is
   verbose or errors are vague, people reach for handlers again. The
   most important work in this record.
3. **Wirings add a concept.** They earn it only by replacing something:
   the function-that-takes-a-block pattern should become unnecessary,
   and the docs should say so.
4. **Services that are really data.** The line between injecting a policy
   and passing it needs one example in the docs showing each.
5. **`Table` pays only in release builds.**
6. **Data or actors.** Two answers to "many stateful things" hold only
   while §11's test stays sharp. The docs need one program that's
   clearly each, and the ledger, which looks like actors and is data.

They're risks of execution, not of design. Docs, examples and the
standard library must model the ethos consistently, or people fall back
on habits from the languages they came from.

## Open and later

**Later**

- Methods on one variant, `pub fn total(self: Placed)`.
- A tag view of a sum-type `Table`.
- A sparse-set `Pool` behind the same API.
- AoSoA, as `Table.blocked(n)`, if a benchmark needs it.
- Sealed wirings, for two copies of a sub-graph.
- Overrides deeper than splitting a wiring, if real programs need them.
- Calling a type's own method mid-chain, if strictness bites.

**Not decided**

- How the README leads.

Staging is in [foundations.md](foundations.md#staging): this record's
data work (§2, §3, §6) comes first, then wirings, the pipe and §11.

## Evidence

From three research passes on 2026-10-28, using the clones in
`/tmp/ren-refs` and published sources, and probes against the compiler.

**ADTs and layout**

- Swift's extra inhabitants and spare bits:
  `/tmp/ren-refs/swift/docs/ABI/TypeLayout.rst:174-240`.
- Roc's `NullableUnwrapped`, `NonNullableUnwrapped`, `NullableWrapped`:
  `/tmp/ren-refs/roc-rust/crates/glue/platform/Shape.roc:59-112`.
- Koka's value types only when declared, with a warning above 4 words:
  `/tmp/ren-refs/koka/src/Kind/Repr.hs:60-100`.
- Zig's `MultiArrayList`, one tag column and one payload column for a
  tagged union; used by the Roc Zig rewrite:
  `/tmp/ren-refs/roc-zig/src/collections/safe_list.zig:399`.
- Odin's `#soa`, opt-in on the array type. In every system studied,
  struct-of-arrays is requested, never automatic.
- Scala 3 widens a case to its enum unless the expected type is the case:
  https://docs.scala-lang.org/scala3/reference/enums/adts.html. Rust's
  enum variant types, RFC 2593, stalled.
- Flix's restrictable variants:
  `/tmp/ren-refs/flix/examples/unsorted/restrictable-variants/colors.flix`.
- Rust's let-else, RFC 3137. Wlaschin, *Domain Modeling Made
  Functional*, chapter 7.

**Wirings**

- Effect's layer composition, `provide` versus `provideMerge`:
  `effect/ai-docs/src/01_effect/03_services/20_layer-composition.ts`;
  test layers: `09_testing/20_layer-tests.ts`; `Layer.mock`:
  `packages/effect/src/Layer.ts:2354`; memoization by identity and its
  changes across versions: `effect/migration/layer-memoization.md`;
  `Effect.Service`'s `dependencies`, removed in v4:
  `effect-v3/packages/effect/src/Effect.ts:13729`, `migration/services.md`.
- Effect's unsatisfied requirements as "not assignable to type 'never'",
  and complaints about provide chains at the entry point:
  https://www.answeroverflow.com/m/1329830947746611241,
  https://www.answeroverflow.com/m/1182381634557841470,
  https://www.answeroverflow.com/m/1264141317831790643.
- ZIO 2's `ZLayer.make`, its messages for missing, ambiguous, circular
  and unused layers, and `ZLayer.Debug.tree`:
  https://zio.dev/reference/di/automatic-layer-construction/.
- Dagger's testing guide, "adding new dependencies will break tests", and
  a separate test component over overriding modules:
  https://dagger.dev/dev-guide/testing.
- Google Wire, one provider per type, cleanup order, archived on
  2025-08-25: https://github.com/google/wire/blob/main/docs/guide.md,
  https://github.com/google/wire/blob/main/docs/faq.md.
- MirageOS's `functoria`: a composition root grew its own construct over
  OCaml functors.
- Flix's handler-per-function packaging and `@DefaultHandler`:
  `/tmp/ren-refs/flix/main/src/library/Logger.flix:83, 106`.

**The pipe and `try`**

- Swift's "'try' cannot appear to the right of a non-assignment
  operator", and its warning when nothing in a `try` throws:
  `/tmp/ren-refs/swift/include/swift/AST/DiagnosticsSema.def:5183, 6122`.
- TC39's pipeline proposal, F#-style versus Hack-style and the `await`
  problem: https://github.com/tc39/proposal-pipeline-operator.
- Roc: the parser decides targets, `/tmp/ren-refs/roc/design.md:6724-6743`;
  0 uses of `|>` against 116 of `?` in `basic-webserver/platform/*.roc`;
  the thread on whether `|>` is still needed:
  https://roc-lang.github.io/zulip-export/stream/304641-ideas/topic/Do.20we.20still.20need.20.60.7C.3E.60.3F.html.
- Gleam's pipelines: https://tour.gleam.run/functions/pipelines/.
- Elixir's `then/2`: https://hexdocs.pm/elixir/Kernel.html#then/2.
- Data-first versus data-last:
  https://www.javierchavarri.com/data-first-and-data-last-a-comparison/.
- Effect's `dual` and `pipe`:
  `/tmp/ren-refs/effect/packages/effect/src/Function.ts:105, 590`.
- R's native pipe and lambda targets:
  https://stat.ethz.ch/pipermail/r-devel/2021-January/080396.html.

**Probes against Ren**, 2026-10-28, in the session's scratchpad: methods
on a type parameter, descriptions and `==`, a stateful handler called as
a method, a consumer's `uses` with layered handlers, a missing provider,
a `pub` handler without `uses`, the ADT feature table in §2, and `|>` and
`try` parsing.

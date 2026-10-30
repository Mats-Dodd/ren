# The compiler

How the compiler is laid out: the passes a program goes through, the
languages in between, what each one promises and what checks it, and the
rules every pass keeps. It's written for whoever changes the compiler,
and for whoever wants to know why a guarantee in the README holds. The
module rules it builds on are in [module-build.md](module-build.md), and
how dependencies run in [deps.md](deps.md#how-it-runs).

Stage 10.0 lays these foundations before the language moves on to
operators. It isn't a language stage, and what a program can write
hardly changes: `==` on functions becomes a compile error (R4), a few
programs the old inference got wrong are accepted or rejected as they
should be (R3), and recursion more than 100,000 calls deep that aren't
tail calls panics (R0). It's here because what comes after operators,
reference counting with reuse and specialization, needs facts the
compiler doesn't carry yet, and is much harder to retrofit than to plan
for.

## What it has to do

1. **Guarantees never depend on an optimisation.** "No `Alloc`, no
   allocation", `unique` and transparency rest on checked rules.
   Specialization and opportunistic reuse only make code faster. A
   dynamic uniqueness check can't justify "no `Alloc`" unless the shared
   path is ruled out.
2. **Each fact is computed once, by one pass, and carried in the IR.**
   Types, effects and requirements now; ownership, lifetimes, reuse and provenance later. Nothing downstream works one out
   again, and nothing guesses it back from a name.
3. **Every IR has a checker,** as Core Lint is for Core. A pass that
   breaks an IR's promise is caught where it did it, not where the
   interpreter computes something wrong.
4. **The five resource metrics are distinct:** how many allocations, how
   many reference-count operations, the most memory held at once, the
   deepest the stack goes, and how much work freeing does. Fewer count
   operations can hold more memory, and reuse delays freeing, so one
   number never stands for another.

## The pipeline

```
 per module, incremental
   parse ─▶ resolve ─▶ infer ─▶ excl ─▶ typed Core
                        │        │
                        │        └ exclusivity, one walk per function:
                        │          nothing is used while it's changed
                        └ one solver: types, ! rows, uses rows,
                          requirements

 whole program, later
   specialize ─▶ Mem IR ─▶ borrow inference
     ─▶ Perceus: dup/drop, reset/reuse ─▶ resource checks
     ─▶ instrumented interpreter, then C
```

Each module is checked on its own, against its imports' interfaces
(module-build.md). The front half, to typed Core, is per module and will
be cached per call-graph group. The back half needs the whole program:
specialization has to see every call of a generic function, and borrow
inference every body a value goes through.

| IR | Made by | Holds | Checked by | Today |
|---|---|---|---|---|
| tokens | lexer.ml | the source, with indentation as tokens | the parser | yes |
| AST, parsed | parser.ml | the program as written | nothing yet: the tree-sitter grammar's differential test only checks that both parsers accept the same programs, not that they read them alike | yes |
| AST, resolved | resolve.ml | every name found through scope, by its binder's id or its path | inference, which only reads it | yes |
| inferred | infer.ml | each function's scheme and each node's type and lookup | the driver: a public function's inferred scheme is the one its interface states | yes |
| Core | lower.ml | the program with one way to change something, every node typed, evidence explicit; type arguments from R2, requirement dictionaries from R4 | Core Lint, which the tests run on every program | yes |
| specialized Core | the specializer | Core with type arguments and requirements chosen, and each block and known handler specialized where it's used | Core Lint | since native step 5, in a release build: specialize.ml, from the linked program, checked by Core Lint and run by `ren run --release`, `ren core --release` prints it |
| Mem IR | memory lowering | A-normal form, layouts, a block as a code and a frame pointer | its own lint | the sequential subset ([Native slice](#native-slice)): to_mem.ml, checked by mem_lint.ml on every build; generic code through descriptors, blocks, evidence and handlers since native step 3 |
| Mem IR, counted | borrow inference, Perceus | borrows, dup and drop, reuse tokens | its own lint; the resource checks | since native step 4: borrow.ml, rc.ml and reuse.ml, each function's counting checked path by path by Mem Lint; the naive counting to_mem.ml places, a dup at every use and a drop at every scope's end, is `ren build --rc naive` |
| C | the C backend | the counted Mem IR, emitted | the C compiler, ASan and UBSan | the first-order subset: emit_c.ml and the runtime, `ren build`, tested under ASan and UBSan against `ren run` |

## The facts

Each fact has one pass that computes it, and one place it's carried.
That's what stage 10.0 builds to. Where today's compiler falls short of
it, each fact says so, and which step fixes it.

- **Types.** Inference, by Hindley–Milner with levels (types.ml,
  unify.ml). Carried by every Core node and binder, in canonical form
  (ty.ml), and each use of a generic function carries the type
  arguments it picks. Where the running program needs a type, to show
  a value, it's given a descriptor of it (Specialization, below), so the
  interpreter never works one out.
- **Effects.** What a function can fail with, its `!` row, and what it
  uses, its `uses` row. Inference, carried in function types, in the
  same solver as types: what can be decided only once a group of
  functions is checked is a constraint that solver decides (The
  constraint solver, below).
- **Requirements.** From R4. What a generic function needs of a type
  parameter: `eq` for `==`, `ord` for `<`, `add`, `sub`, `mul`, `div`,
  `rem` and `neg` for the operators, and `zero` and `one` for `T.zero`
  and `T.one` (stage 9a), and `hash` for a `Map`'s keys and a `Set`'s
  members (9b), whose dictionary carries the `==` it agrees with, so a
  table is given both as one. Inference, in the same solver; never
  written, on a public function either (operators.md, "Generic code").
  Carried in the scheme, the interface, and as hidden dictionary
  parameters in Core. Inferred since R4, and carried in schemes and
  interfaces (infer_reqs.ml): `==` on a type with a function in it is a
  compile error. Each use of a function records what it needs
  (`Infer.node`), and lowering passes a dictionary for each, so `==` in
  a generic function compares through the one its caller gave it. A
  built-in function's scheme lists what it needs too, and since 9b each
  use of one is passed a dictionary for each, as a function's is:
  `Map.get` is given its keys' `hash`, and `Array.sort` its elements'
  order.
- **Exclusivity.** While a place is being changed, nothing else uses
  it (foundations.md, decision 2). Since 10c step 5, excl.ml checks it
  after inference, since it needs types (a copied value is read in an
  instant, a counted one for the call it's passed to), one walk per
  function: how long an access lasts, an instant, a call or a loop,
  comes from the syntax, a block passed to a call uses what it captures
  for the call, and a call needs only whether each block parameter is
  ordinary, the one mode so far. There's no dataflow, no lifetimes and
  nothing whole-program. Rule A, that a block parameter, or a block
  capturing one, isn't passed to a call of a block parameter, is
  checked there too. It's a check, not a fact carried on: what it gives
  the optimizer is that an `&` parameter aliases nothing else the callee
  can see, not another parameter, a block's capture or handler state,
  so copy-in, copy-out and passing by reference mean the same. That's
  about the slot: the buffer in it can still be shared, `let a = xs;
  f(&xs, a)`, so changing it in place keeps Perceus's uniqueness check.
- **Ownership.** Since native step 4, by its own passes over Mem IR,
  each computing one fact (Native slice, "Step 4"). Borrow inference
  (borrow.ml), over the whole program's calls, decides whether each
  parameter is borrowed or owned, carried in `Mem.fn.modes`: a known
  callee's body says whether it consumes a value. Perceus (rc.ml)
  places each `Dup` and `Drop` from that, and reuse (reuse.ml) a reuse
  token, a variable of layout `Token` an `Alloc` builds in. Mem Lint
  checks the counting they place on every path of every function.
- **Lifetimes, reuse credits, provenance.** Later, each by its own pass
  over Mem IR, after specialization.

## What each IR promises

As with the facts, this is what stage 10.0 builds to, and where today
falls short it says so.

- **The resolved AST** names every local by its binder's id, and every
  top-level entity by its path (path.ml): a module and a name in it.
  Nothing after resolve looks a name up in a scope. A type's member is
  its type's path and which member it is, its name and an overload
  index, so no pass builds a member's name from strings or splits one.
- **Inference's result** gives every expression and pattern a type and,
  where something was found through a type, what (infer.mli). It decides
  every question once: which constructor, which method, whether a call
  can fail, which handler a `with` installs, the
  order a `with` installs its items in, and the type of the body a
  handler's `finally` is given, which `match`es handle errors and which arms are `fail` arms, whether
  a `try` unwraps a `Result`. Lower and exhaust read those decisions
  from it and never make them again.
- **Core** has one way to change something, an assignment to a local,
  and one way each to fail, to handle an error, to install an
  implementation and to call a dependency (core.ml); a `next` call is a
  dependency call on its handler's evidence, which a block captures
  where it's written, as it captures any evidence, and an implementation's type says
  whether it goes over another and what it can fail to start with. Every node has its
  type, and every function its evidence. Core Lint checks each of those
  against the others, from scratch. Every use of a polymorphic function
  has its type arguments too, and Lint checks the type it's used at is
  its scheme's with them put in. `ren core --types` prints them. A
  generic function takes a descriptor of each of its type variables, as
  a hidden parameter, and Lint checks each descriptor a use passes
  describes its type argument. It takes a dictionary for each of its
  requirements too, and Lint checks each use passes one for each, for
  the type argument it's on, as each `==` has one for what it compares,
  built only from the function's own dictionaries, and derived only for
  a type that has what it's derived for. Since 9a the same holds of each
  `<` on what isn't a number (`Compare`), each operator on a type
  variable's values (`Op`) and each `T.zero` (`Value_of`); the
  language's own operator (`Binop`) is only on an `Int`, a `Float` or a
  `with numeric` type, `*` of which takes what it's represented as; and
  each type a module says has a `key`, or an operator or associated
  value for a requirement (`Core.program`'s `keys` and `ops`), has that
  member, of the type the interpreter calls it at. Since 9b an
  intrinsic's use passes a dictionary for each of its scheme's
  requirements, checked as a function's are; a tuple, and a tuple
  pattern, is checked part by part; and a `Map`'s `Entries` and a
  `Set`'s `Members`, the arrays a `for` goes over, are of the table's
  own type's parts. Since 9c, a
  function that isn't test code uses no test function, which is what
  lets `ren run` leave test code out. Since 10b, an intrinsic that reaches the
  world is used only by the real implementation of the dependency it's
  an operation of, and `journal_load` only by test code (`world`), so
  every call a program makes to the world is an operation's, which a
  journal records. Since 10c, a record of a dependency's operations is
  only ever a handler's `Instance`'s, never a value of the program, and
  blocks are second-class: a value of a function type is only a call's
  callee, a call's argument or a `let`'s value, but for an instance's
  operations, and no type argument has a function type in it. Infer
  checks the same of the source first (`check_blocks`, and resolve.ml's
  `no_kept_blocks` for written types). Since the data stage a record
  pattern (`PRecord`) has a pattern for each of its type's fields, in
  declaration order; an or-pattern's alternatives bind the same
  variables at the same types, and `PAs` binds the whole of what its
  pattern matched; and a variant type (`Ty.Variant`, `Order.Placed`) is
  its sum's value: a field read and an update at one are at its
  constructor's fields, `Of_variant` takes one back to its sum without
  changing it, and an `as` binds one only on a pattern of its own
  constructor. Core Lint checks each. `Core.program`'s `method_calls`
  lists each operation called on a description as a method, which
  stateless.ml checks on the linked program (Data stage, step 6).
- **Mem IR**, later, makes every allocation, copy, count operation and
  free an explicit instruction, so the resource checks read them off
  rather than guess them.

## No cycles

Perceus frees a value when its count reaches zero, which is
garbage-free only if no value can reach itself. Ren rules that out, and
each pass keeps it so:

1. **A value never changes in place once it's shared.** `a.next =
   Some(a)` stores a copy of the old `a`, not `a`.
2. **A block captures the evidence where it's written, and can't
   outlive its call.** Since 10c step 4 it gets its dependencies where
   it's written (deps.md, "How it runs"), and its callee gives it only
   what its type lists. Since step 3 a block is second-class: it's
   passed down and called, never stored or returned, so the evidence it
   holds, and through it a handler, is never kept past the call that
   installed it. A handler's operations and `finally`, and a block in
   them, can call through `next`. Core Lint checks that a block captures
   the evidence where it's written, and is given only what its type
   lists.
3. **An installed handler instance is never a value.** A `with` installs
   it, and no expression yields it; its own dependencies are captured
   from further out. So a handler's `var`s can't reach their own
   instance. Core Lint checks this: an `Instance` appears only at the end
   of a `Handler`'s body, after the `let`s that make its state. Since
   10a, the implementation a handler goes over is reached by a dependency
   call on the evidence its handler was installed with, `next.get(id)`,
   never held as a value, and its `finally`s are one lambda in the
   instance, which keeps cells as the operations do, not the instance.

And one rule for the stages after this: **a handler's state can never
hold a suspended continuation.** A fiber belongs to the scope of
structured concurrency that the runtime owns, not to a handler.

## Specialization

A generic function is compiled once, and given what it needs where it's
called:

- **Debug builds** pass requirement dictionaries, as they pass evidence,
  as hidden parameters. `same<T has eq>` takes `T`'s `eq`, and a call of
  `same` at `Int` passes `Int`'s. One copy of each function, quick to
  build.
- **Release builds** specialize the whole program: each generic function
  for each type and requirement it's used at, each block for the call
  it's passed to, and each
  dependency call for the handler known to be installed there. Results
  are cached by content, so a rebuild specializes only what changed.
  Specialization has no cap on the copies of one function, but a size
  budget for the whole program: past it, a call falls back to what a
  debug build does, and the build says so (Native slice, "Step 9").

Since native step 5, `ren build --release` does this (Native slice,
"Step 5"): specialize.ml, from `$start`, over the linked program's Core,
into Core that Core Lint checks and the interpreter runs, as `ren run
--release` and `ren core --release` do. It isn't cached yet: it runs on
the whole program each build, from the linked modules' Core, not the
implementation tier.

Both mean the same: specialization only makes code faster (rule 1). To
specialize a function of another module, a release build needs its body,
which the module's interface doesn't have: so its summary has a second
tier, the implementation tier (impl.ml; module-build.md, "Interface
summaries"), with the typed Core of each public function that's generic
or higher-order. Nothing reads it yet. The interpreter runs the debug
strategy. Evidence is passed this way (deps.md,
"How it runs"), and so are dictionaries, since R4, where `eq` is the
first requirement.

A dictionary is built where it's passed, from the use's type arguments
(core.ml, `dict`): for one of the caller's own type variables, it's the
dictionary the caller was itself given for it; for any other type, it's
derived from the type's structure, given the caller's dictionaries for
its type variables in it. So `both<U has eq>` passes `same` its own `U`
dictionary, and for `Box<U>` one derived from `Box`'s declaration and
that. Each `==` compares through the dictionary of what it compares, the
same way, so one in `same` uses the one `same` was given, and so does
each `<` on what isn't a number, each operator on a type variable's
values and each `T.zero`. The interpreter makes a derived dictionary a
function of its own, from the type it's derived for, which it knows from
the dictionary's descriptor: `==`, `hash` and ordering are each a fold
over one walk of the type's structure (walk.ml), through its `key` if it
has one, which `show` walks too; an operator or an associated value is
`Int`'s or `Float`'s own, or the type's member that gives it, which
lowering lists once (`Core.program`'s `ops`), or for a `with numeric`
type what it's represented as has. It never meets a function, since
inference makes sure there's none in what's compared, with one exception
(Deviations).

So are types, where the running program needs one. Showing a value
depends on its type, `Account { id: 1 }` rather than `{ id: 1 }`, and
what `T` stands for in `print<T>` only its caller knows. So a generic
function takes a hidden parameter for each of its type variables,
holding a descriptor of the type it stands for (core.ml, `desc`), and
each use of it passes descriptors that lowering built from the use's
type arguments: a type without the caller's type variables is a
constant, and one of them is what the caller was itself given. A type
that shows its values through a `show` method of its own is found once,
by lowering, which lists it with its method in its module's Core. The
interpreter evaluates descriptors as it evaluates evidence, and never
matches or substitutes a type. A release build specializes them away
like dictionaries.

## Blocks

A lambda is a block (foundations.md, decision 1): it's passed down and
called, never kept. Since 10c each part of that is decided once, by one
pass, and checked again on Core:

- **Where a block can be** is checked twice in the front half, both per
  module. Resolve rejects a function type written where a value is kept,
  a record field, a constructor's payload, a type argument or a result
  (`no_kept_blocks`), before inference. After inference, one walk per
  function over its nodes (Infer_top, `check_blocks`) checks that each
  value of a function type is a call's callee, a call's argument, or
  the value of a `let` of one literal `fn`; that no type variable is
  given a block's type, since `T` could be stored; and that a handler's
  parameters are data.
- **What a block captures** it shares by reference: a `var` it uses is
  its frame's cell, and it reads it when it runs. It captures the
  evidence where it's written too, and its callee gives it only what
  its parameter's type lists (deps.md, "How it runs").
- **Exclusivity** is one pass after inference, per function, one walk
  (excl.ml; The facts, above). It and rule A are checks, not facts: they
  give the optimizer that an `&` parameter aliases nothing the callee
  can see.
- **Core Lint** checks each again from scratch: a value of a function
  type is only a callee, an argument or a `let`'s value, but an
  instance's operations; no type argument has a function type in it; a
  block's `captures` lists every local its body uses, the evidence where
  it's written among them; it's given only what its type lists; and a
  `Break` never leaves it.

What the optimizer and a native backend get from it, with no flow
analysis: every block at a call site is a literal or a parameter of the
function it's in, so a release build specializes the callee per block,
and a debug build passes a code pointer and a frame pointer. Each block
has a stable name (`Lambda`'s `name`), which a specialized copy is keyed
by, and its captured evidence is explicit, `outer` and `given`, so a
dependency call in it is resolved as in the function it's written in.

## The constraint solver

Inference checks the functions of a module a group at a time, where a
group is functions that call each other, callees' groups first
(infer_top.ml). Each body of a group sees the others only as their
declarations describe them, so no body learns anything from another,
and checking them in another order would find the same. What can be
decided only once every body is checked is a **constraint**
(infer_env.ml, `constr`), and once the group is done the solver
(solve.ml) decides them all.

A handler of several dependencies isn't one. It has a type that lists
them, `A & B`, fixed where it's made (deps.md, "Implementations").
Checking an expression against a type narrows it to some of them only
where that type is written, an annotation or a declaration, not a
variable inference made (infer_expr.ml, `check ~written`, `narrow`).
An `if`, `match` or block checked against a written type narrows each
branch, under a `let` or passed to a written parameter alike. A
`with` installs what the value's type says. Both take the value's type
as inference knows it there: types flow left to right, as in Rust and
TypeScript. `ap(counting_rates(1), fn(r) => run(r))` checks, since the
generic's `T`, and so `r`, is already a `RateCalls & Rates` when `r`
reaches `run`'s written `Rates`; `ap(fn(r) => run(r),
counting_rates(1))` doesn't, since `r` is a `Rates` by then and `T`
isn't written. A `with` of a value whose type is still a variable there
can't tell what it installs. Whether a type is written is decided by the
type itself, not what inference has linked it to (infer_written.ml,
`is_written`): a generic's `T` is a variable however it's solved, and a
function's scheme keeps an inferred parameter a variable, linked to what
was found (types.ml, `copy_param`), so it isn't taken for a written one
however the function is reached. One of the module's own functions is
looked up by its declaration instead (infer_written.ml,
`written_params`), as its scheme
alone doesn't say (test_deps.ml, "types flow left to right").

The constraints:

- **A use of another function of the group** has the type that
  function's own body gave it, with the type parameters and rows its
  declaration names, `fn first<T>` or `! ..e`, made fresh for each use,
  since it says it works for any of them.
- **A value a statement throws away** is `Unit` (errors.md, "Nothing is
  dropped"). One whose type is still unknown becomes `Unit`, and a later
  mismatch at a call of its function points back at it.
- **A `with` that installs** gives its body no more than what it
  installs and what's installed outside it: what the body uses, but what
  it installs, is added to what the `with` uses.
- **What an implementation needs is needed where it's used:** each place
  gets a copy of its row, which gains the labels it learns later.
- **A function that names its own errors' row,** `! ..e`, fails with it.
- **A tag written as a value,** `Err(Right)`, is in its error set, if
  the set is one of its own: `if c then Err(Left(1)) else Err(Right)`
  holds both, and once every set has its tags, no more, as a kept set.
- **One row of errors is included in another:** a call's errors in what
  marks it, a `Result`'s in the `try` that fails with it again. The row
  included from stays as it is, so a callee never fails with what its
  caller does. The labels it has when it's met are added then, and those
  it learns later, from a function of its group, by the solver.
- **A kept set holds no more than it's given:** what an `attempt` keeps,
  or a `match` with `fail` arms handles, is closed once every set has its
  tags, unless it's what a function it was passed fails with.
- **A tag matched in a set still open is one of its tags,** with as many
  payloads, and so is a tag written as a value that didn't go in a set of
  its own.
- **The rules of markers** (errors.md, "Marking"): a call no marker
  covers can't fail, and every marker covers something that can.
- **An implementation's operation fails with no more than its
  dependency declares** (deps.md, "Implementations").
- **A row a named row is added to ends in it,** `..d`, once it has every
  other label, since that stops it getting more; and so do a function's
  own rows, in the rows it names.
- **A function does what it declares** (infer_declared.ml): it uses and
  fails with what its signature says, a public one's parameters of a
  dependency's type keep their rows open, and a handler needs no more than it
  declares, and never itself, but for what it goes over, which only a
  `next` call reaches; what its state and `finally` fail with is all it
  fails to start with, closed once its group is done.
- **What `==` and `!=` compare has `eq`** (infer_reqs.ml): the type of
  their sides, once it's known. A type variable that has to have it
  passes that on to the function it's in, which then needs it of its
  type parameter, `same<T has eq>`; a type with a function in it is an
  error where it's compared. The same constraint, `Compared`, with the
  requirement it's for, says what `<` compares has `ord`, that a type
  variable an operator is used on has that operator, `add` for `+`, and
  that one `T.zero` is reached through has `zero` (stage 9a).
- **A use of a function that needs something of its type parameters**
  needs it of what it puts in their place: an error at the argument it's
  in, if that can't have it, or passed on again, if it's a type variable
  too. A function of the group needs what its body is found to, which
  can grow as the others' uses of each other are decided, so these are
  decided in rounds until one finds nothing new.

So a group is checked in two steps (infer_top.ml, `check_group`): every
body, then the solver. Nothing runs between them, and after the solver
only generalizing touches the group's types.

Each constraint carries where it comes from and what a message about it
needs, and the solver decides them like this:

- **Kind by kind.** The constraints of one kind are all decided before the
  next kind starts, because the later one reads what the earlier decides
  (solve.ml, `solve`): the uses of the group's functions first, since a
  call of one learns only then what it returns, then the handlers taken
  as one dependency, which tells a `with` of one which it installs, then
  the values thrown away, then what each `with` installs and what each
  place an implementation is used needs, then a function's own error
  row, each set's own tags, the inclusions, and the kept sets closed and
  the tags matched in them checked. The checks that only report, like a
  marker's rules or what an operation fails with, read the result after
  all of them, and so do the requirements, which need every type the
  group will have; a row ends in a named row after that, and what each
  function declares is checked last.
- **To a fixpoint.** A use or a value thrown away is decided once. An
  inclusion, or a copy of what an implementation needs, is a worklist
  item: whenever the row it adds from gains a label, it's woken and adds
  that too, in the next round through those woken, in the order they were
  met. Rows only ever gain labels, and each has finitely many to gain, so
  this ends. A `with` that installs is decided once, innermost
  first, after the copies are brought up to date, since what its body
  uses includes them.
- **Reporting every failure, and changing nothing by one.** Each
  unification is tried first on copies of its types (unify.ml,
  `atomically`), and done for real only if that worked. So one that fails
  partway, a variable bound and the next label refused, doesn't leave
  half its changes for the next constraint to trip over. Its message is
  worded from the copies, as far as they got.

The answer doesn't depend on the order the constraints were met, which
is the order their bodies were checked in. Unification finds the most
general solution whatever order it's given the equalities in. An
inclusion only adds labels, so each row ends up with the union of what's
included in it, whatever order they're added in, and a requirement only
adds to what a variable needs, so each needs what any use or `==` says
it does. A check that reads a
result is decided after whatever decides it, so it never sees half of it.
And a constraint that fails changes nothing, so it can't change what
another sees. What order does decide is only which of two constraints
that can't both hold is blamed: the one met second, so a mistake is
reported where the code reads it, after what it contradicts.

One thing the solver can't do is put the groups in order. Which method
a dot call like `s.len()` calls is found only by checking the call,
through `s`'s type, but the groups are found from the call graph before
anything is checked. So the graph starts with the dot calls resolve.ml
can tell, and a dot call that turns out to call a method of the module
not checked yet stops checking (infer_env.ml's `Unchecked`), adds the
call to the graph, and checks the module again from the start
(infer_top.ml, `program`). That stays, because the method's type comes
from checking its body, which has to happen in a group before the
caller's, or in the same one if the method calls it back: which groups
there are is what was wrong, and only the call graph can say that. A
constraint can wait for a type the group will find, but not for a
function whose group hasn't been checked, or put that function in the
caller's group once the caller is checked. Each time adds an edge the
graph didn't have, so it ends, and a method whose signature is written
out in full never needs it, since its type is known before it's
checked, unless it's generic: what it needs of its type parameters
isn't written, so a generic method is known only once its body is
checked, like any other function.

## Stage 10.0

Five steps, R0 to R4, done in order on one branch, in small commits
that each keep every test green. Each step is reviewed on its own before
the next starts:

- **R0, foundations and safety nets.** This document; CI on Linux and
  macOS; benchmarks, and the interpreter's tail calls made a loop, so a
  long loop written as recursion isn't quadratic, and deep recursion
  reaching its panic promptly: a program more than 100,000 calls deep
  that aren't tail calls now panics (eval.ml's `max_depth`), where before
  it ran until OCaml's own, much deeper, stack ran out; test helpers
  that fail when an expected error doesn't come; the roadmap renumbered.
- **R1, restructure with no change in behaviour.** The prelude's
  runtime half moves to eval/, so resolve, lower and lint no longer link
  against it, and intrinsics are found by an id. A type's member is
  `{owner; name; overload}`, and schemes, nodes and interface members are
  kept in maps keyed by it. infer_expr.ml is split by concern, what
  inference decides is recorded for lower to read, inference's message
  wording moves into infer_msg.ml, and the cheap quadratic spots are
  fixed. Every existing output stays byte for byte the same.
- **R2, typed Core.** Every Core node and binder carries its type, and a
  call of a polymorphic function its type arguments, so the interpreter
  no longer works types out at runtime. A scheme gains a slot for
  requirements.
- **R3, one constraint solver.** The deferred queues inference keeps
  become one representation of constraints, solved by one worklist per
  call-graph group, reporting every failure, in an order that doesn't
  change the answer. It fixes four bugs of inference: a generic
  function's written signature not instantiated at a use in its own
  group, a handler coercion that depends on argument order, a private
  function rejected because two rows share a tail, and an error set of
  tags written in `Err` left open after its group.
- **R4, requirements and lambda sets** (lambda sets removed in 10c,
  [foundations.md](foundations.md)). `==` and `!=` require `eq`,
  derived structurally and absent from a type with an implementation in
  it; a block is never compared, and never a type argument. A
  generic function's requirements are inferred and kept in its scheme and
  its module's interface, and passed as dictionaries. A module's
  implementation tier keeps the bodies of its public generic and
  higher-order functions, for specialization. Every function type gets
  its lambda set, inferred by unification, carried in Core and checked by
  Core Lint, and invisible everywhere else.

## Deviations

Where the work forced a change to the plan above:

- **R1, splitting the prelude.** The intrinsics' ids and names are a
  module of their own, `core/intrinsic.ml`, rather than part of
  `prelude.ml`, which keeps each one's type. The AST names an intrinsic
  by its id too, and `prelude.ml` depends on the AST (through `Ty` and
  `Iface`), so the ids can't live there without a cycle. And the
  compiler is still one dune library, so "resolve, lower and lint no
  longer link against runtime code" means none of them refers to it:
  `Value`, `Unix` and `builtins.ml` appear only in `eval/` and the
  driver. Separate libraries would make the linker enforce that, which
  can wait until it's worth the build files.
- **R1, a member's identity.** A member isn't a record of its own,
  `{owner; name; overload}`, but a path with a member part
  (`Path.member`): its type's home and name, and its own name and
  overload index. Everything that names a function, a call in the AST or
  Core, a scheme, a call-graph edge, already holds a path, so a member
  fits in each without a second kind of name beside it. Interface members
  are a map by that path, and each also keeps its place in source order
  (`Iface.op.onum`), since messages and the tests that print an
  interface list them in that order.
- **R1, splitting `infer_expr.ml`.** It's split into seven modules, not
  the four of the plan's findings: besides rows and effects
  (`infer_rows.ml`), handlers and `with` (`infer_handlers.ml`), lookups
  through a type (`infer_lookup.ml`) and the core (`infer_expr.ml`), the
  shared types are `infer_env.ml`, reporting and explaining a mismatch
  `infer_report.ml`, and written types `infer_written.ml`, since each is
  used by several of the others. The names keep the `infer_` prefix,
  because every module of the library shares one namespace. Handlers
  check their parts with the core, which calls them, so the core passes
  its functions to them in a record (`Infer_handlers.core`) rather than
  through a recursive module or a mutable forward reference.
- **R1, moving messages to `infer_msg.ml`.** Inference still decides
  which explanation fits a mismatch, by looking inside the two types
  (`Infer_report.unifies`), and passes what it found as data,
  `Infer_msg.behind`; the wording of every message, its notes and its
  help is `infer_msg.ml`'s. A mismatch is worded from the two types as
  they're printed, since that's what its message shows.
  Each message reads exactly as before, oddities included: the doubled
  backticks of B4, which R3 fixes, and "`` `an index` works on `Int`s ``",
  which a step that may change messages can reword.
- **R1, recording what inference decides.** The decisions lower.ml made
  again are kept as more kinds of `Infer.found`, which now says what
  inference decided at a node, not only what a lookup through a type
  found: a `match` that handles errors (`Handles`), a `fail` arm's
  pattern (`Fail_arm`), a `try` that unwraps a `Result` (`Unwraps`) and
  a tag inside `Err(...)` (`Error_tag`). The last two weren't named in
  the plan, but lower.ml worked them out again from the types inference
  left, and so did exhaust.ml for the first two and the last, so it reads
  them too. The interpreter still works types out at runtime; R2 is the
  step that stops it.
- **R2, type arguments.** They're on each use of a top-level function,
  a member, an associated value or an intrinsic (Core's `Global`,
  `Global_value` and `Intrinsic`), not on a call, since a function can
  be used without being called, `let f = id`. A row variable of the
  callee's scheme gets an argument too, a row, so they're `Ty.args`, a
  list of types and a list of rows, rather than one list of types. A
  function of the group being checked isn't generic yet where it's used,
  so its arguments are found once the group is: what each of its
  variables stands for in the type it was used at (`Types.matching`).
  `ren core` prints as before, and `ren core --types` prints them.
- **R2, types at runtime.** The plan says only that the interpreter stops
  working types out. It's given them instead, as debug builds will be
  given dictionaries: a descriptor of the type each type variable stands
  for, a hidden parameter of every generic function, one for each of its
  type variables whether it shows a value of that type or not, which is
  simpler and costs little (Specialization). Neither `ren core` nor `ren
  core --types` prints them, since the type arguments say what they are,
  and Lint checks the two agree. A hidden type parameter's id is
  negative, so no local's number changed. A type variable inference left
  undecided, like the type of what `Ok` holds in `Err(Gone(1))`, is
  described as itself, and a value of it is shown by its shape, as
  before. One thing shows differently: a generic associated value is
  made once, with nothing known of its type variables, and a function
  stored in it, `pub let shower: fn(T) -> Str = show`, is given that, so
  it shows `{ id: 1 }` where it showed `Acc { id: 1 }`. The interpreter
  used to give `show` the type at each call, but a lambda in the same
  place, `fn(x) => show(x)`, already showed `{ id: 1 }`; now both do
  (test_eval.ml).
- **R3, where the solver's work lives.** Deciding a constraint that
  checks what a function declares, its uses, errors and named rows, and
  a handler's needs, is in infer_declared.ml, beside solve.ml rather than
  in it, since the messages it gives need much of what infer_top.ml had
  for them. Why a function still gets a dependency from
  outside, which a message about a call of it explains with, was a list
  in the environment; it's what the solver returns for each group, which
  infer_top.ml keeps for the next ones and for `main` and tests.
- **R3, a handler taken as one dependency, since removed.** R3 decided
  what a handler of several dependencies was taken as from its later
  uses, which took a map of the variables a handler was given to
  (`Unify.watch`), settling them early wherever something looked inside
  (`settle`), and `with`s that waited to know what they installed. A
  handler of several now has a type that lists them, `RateCalls &
  Rates`, and is narrowed only where a written type asks for some of
  them (see "The constraint solver"), so all of that is gone. A value
  already made isn't narrowed later: `let o = Some(counting_rates(1))`
  then `let p: Option<Rates> = o` is an error, and the programs B3 had
  accepted that way are rejected by design, each with a help that says
  which type to write (test_deps.ml, "whether it checks doesn't depend
  on which comes first", "an `if` whose branches are a handler of
  several and one of them", and the tests under "A handler of several
  dependencies has a type that lists them").
- **R3, rows that hold a label twice (B4).** A call joins what its callee
  uses to what its caller does by unifying the two rows, which works as
  long as they don't already end in the same variable. In `fn twice(k) =
  { let a = run(k); a + k() }`, where `run` installs `Rates` around its
  call of `k`, they do: `k` uses `Rates` and whatever `run` uses, and
  `twice`, after the first call, only the latter, in the same variable.
  Unified, the two would have to be equal, and Rémy's rule refuses that,
  so a function that's fine was rejected. Now a call whose row ends in
  the caller's adds the labels the caller lacks to that variable
  (infer_rows.ml, `join_uses`), which is all that has to hold: the caller
  uses everything its calls do. The callee's row then holds those labels
  twice, once as its own and once from the variable. A row can hold a
  label twice, as Koka's can, but where Koka keeps both, for a set of
  dependencies or errors two of one label mean what one does: listing a
  row's labels lists each once (types.ml, `row_parts`), unifying matches
  every copy of a label at once (unify.ml, `strip`), and canonical form
  had always kept one. So `twice` is inferred as `fn twice(k: fn() -> Int
  uses Rates, ..d) -> Int uses Rates, ..d`, which is right: its own call
  of `k` needs a `Rates` from its caller. (Since 10c step 4 a block's
  dependencies come from where it's written, so neither `run` nor `twice`
  gives `k` a `Rates` and the case no longer arises there; test_deps.ml's
  "a block called inside a `with` and outside it (B4)" now checks that.
  `join_uses` keeps the rule for rows that still end in one variable.)
  The plan suggested Koka's rows;
  only the doubling was needed, not keeping the copies apart. The message
  for a call that uses what what it's in can't, and for a `with`'s body
  that does, named each dependency by its full path in doubled backticks,
  and told the reader to leave a type out that wasn't written: both now
  name it as the module does, and say to add it to the type the function
  is used as, which is what closed its row, or to install it.
- **R3, a set of tags written in `Err` (B5).** Such a set is closed with
  the kept sets, once the group's sets have their tags, so a function
  that makes one, `fn mk2(c: Bool) = if c then Err(Left(1)) else
  Err(Right)`, is generalized with exactly those tags, as `ren types`
  printed it already. So a `match` with an arm for each needs no
  `Err(_)`, and a later group can't add a tag to it: `if c then mk2(c)
  else Err(Third)` is an error now, as a tag written where a kept set is
  met is, and so is `mk2(true) == attempt g()` when `g` fails with
  something else. That comparison's message is the plain mismatch of two
  types, which says nothing about why they differ, so a mismatch between
  two `Result`s, one of which holds a tag the other's closed set can't,
  now says so in a note (`Infer_msg.Holds_beyond`).

  Once its group is done, such a set is a type, the one `ren types`
  prints, and a kept set that meets it in a later group takes its tags
  by unification, as it takes a declared `Result`'s (test_errors.ml,
  "attempt keeps the outcome, and try fails with it again", passes
  `attempt busy()` where `NotFound(Int) | Busy` is wanted, which
  errors.md allows: a declared `Result` says what it can hold). So the
  two have to be told apart, which needs where the tags came from. The
  report suggested marking a row as written in schemes and interfaces;
  marking the tags is simpler, and enough. A label carries where it was
  written inside `Err`, if the solver put it in a set of its own
  (`Types.label`'s `written`, set in `value_tag`). Instantiating a
  scheme copies labels, so the mark goes wherever the set does, through
  a function that passes the `Result` on or a generic one; and a label
  added by inclusion, what a call or a `fail` brings in, is unmarked
  (`Types.unwritten`), as a declared `Result`'s are. Two labels unified
  are one tag, so they share one mark, joined as a variable is linked
  (`Types.join_marks`): the tag is written only if every label it's
  been unified with was. So whether a kept set may hold it doesn't
  depend on the order the `Result`s meet in, or which one the kept set
  happens to hold: one that's equal both to a written set and to a
  declared `Result`, directly or through other `Result`s, takes the
  tag, as it would with the `Err`s written in place. Once the group's
  inclusions are done, a kept set with a tag that's still marked and
  that none of the inclusions into it brought in has taken it from a
  written set, and that's an error (`solve.ml`, `written_kept`): `fn
  kept(c) = if c then mk2(c) else attempt g()`, where `g` fails only
  with `Left(Int)`, is rejected, as the same tags written in the same
  group, `if c then (if c then Err(Left(1)) else Err(Right)) else
  attempt g()`, already were. It's an error rather than a set that
  doesn't gain the tag, which can't be: both branches are one type. The
  message points at the `attempt` and where `Right` is written, and
  suggests declaring the type of the function that makes it, which
  makes it a declared `Result`. Only the sets an `attempt` keeps are
  checked: what a `match` with `fail` arms handles, or passes on, is
  only ever what code inside it fails with, never a `Result`'s type, so
  it can't meet a written set. Only that check reads the
  mark: canonical form drops it, so Core, Core Lint and `ren types` are
  as they were. Interfaces don't need it: a public function writes its
  type in full, so a set of tags written in `Err` never leaves its
  module, and a `Result` from another module is always a declared one.
  So to meet a kept set from another module, such a set goes through
  that module's generic functions, which instantiation follows
  (test_errors.ml, "a kept set doesn't take tags written in another
  module"). A `fail` now adds its tag by inclusion, as a call does,
  only so the check knows what it brings in. So `h(if c then mk2(c)
  else attempt g())`, for an `h` that takes a `Result<Int, ! Left(Int) |
  Right>`, is accepted, and so is giving `h` that `if` through a `let`,
  before or after the kept set meets `mk2`'s (test_errors.ml, "a kept
  set equal to a declared Result too takes its tags").
- **R4, where a requirement is kept.** Inference's schemes are types
  with generic variables (types.ml), not `Ty.scheme`s, so what a
  variable needs is kept by the variable's id, in the state every part
  of inference shares (`Types.needs`), as a type parameter's name is: a
  generic variable's are its scheme's requirements, which canonical form
  puts in `Ty.scheme.reqs`, and an interface's scheme read back gives its
  variables theirs. A type parameter, while its function is checked,
  keeps what its body is found to need, which its generic variable takes
  when the function is generalized.
- **R4, which types have `eq`.** operators.md says a type with a function
  in it has none. An implementation of a dependency, and a handler of
  several, are their operations, which are functions, so they have none
  either, and neither does a type with one in it: comparing two `Clock`s
  is an error, not a comparison of what's inside. An opaque type has it
  if what it's represented as does, in another module too: its
  interface hides the representation, but says whether it has `eq`
  (`Iface.Hidden`'s `eq`), which inference worked out in its own module.
  The plan doesn't decide one thing: a type's type arguments all have to
  have it, even one the type doesn't hold a value of, `Tag<fn()>` for a
  `type Tag<T> = opaque Int`, which is what "a type with a function in
  it" reads as.
- **R4, requirements on rows.** The plan puts requirements on type
  parameters only. But a function's errors are a row, and a function
  that compares what something it's given fails with, `fn cmp(g) =
  (attempt g()) == (attempt g())`, compares tags its row's tail stands
  for, which only a use decides: `cmp(bad)`, where `bad` fails with
  `Bad(fn() -> Int)`, would compare two functions. So a row variable
  can need `eq` as a type variable can, of every tag it stands for: the
  scheme keeps it (`Ty.scheme`'s `row_reqs`), an interface too, a use
  checks it of what it puts in the row's place, as of a type argument
  (infer_reqs.ml, `pass`), and `ren types` prints it after the type
  parameters, `cmp<T has eq, ..e has eq>`. It's a check only: nothing is
  passed for it at runtime, since an error carries the descriptors of
  its payload's types (`Core.Tag`), built where it's made, so a tag a
  set's tail brought in is compared, hashed and shown through its
  payload's types, keys included, and can't meet a function once every
  use is checked. An earlier fix took such a tag to have `eq`, which
  let `cmp(bad)` panic; stage 9a's first cut compared one by its shape,
  which ignored a `key` in its payload.
- **R4, dictionaries beside descriptors.** The plan leaves open whether a
  requirement's dictionary is a hidden parameter of its own or carried
  in the type's descriptor, which a generic function already takes for
  each type variable. It's a parameter of its own (core.ml, `dict`), one
  for each requirement, after the descriptors: a function with none
  takes none, Lint can check each use passes exactly what the callee's
  scheme says it needs, and a release build specializes the two apart,
  since showing a value needs its type but comparing two needs only `eq`.
  An associated value is made once, when the program starts, and given
  neither, as before: one that compares values of its `T`, `pub let eqf:
  fn(T, T) -> Bool = fn(a, b) => a == b`, compares them by their shape,
  and so does `main`, a test, or a type's own `show` method for a type
  variable nothing decided. Inference already checked that whatever it's
  used at has `eq`, so that never meets a function either.
- **R4, what a use needs.** Lowering knows a function of another module
  only by its path, so inference records at each use the requirements of
  the scheme it used, by type variable (`Infer.node`'s `needs`), beside
  its type arguments, rather than lowering looking the scheme up again.
- **R4, a derived dictionary at runtime.** The interpreter has no code
  generated for a type's `eq`, so a derived dictionary compares two
  values by walking the type's declaration, as it shows one by it
  (shown.ml), and goes through the function's dictionaries where the
  type has its type variables. That's what a backend would generate,
  interpreted.
- **R4, no comparison panics.** An earlier fix let two comparisons
  through to the interpreter, which panicked when the derived dictionary
  met a function: a value of another module's opaque type represented
  with a function in it, and a tag holding one that an error row's tail
  brought in. Both are refused before the program runs now (above), so
  the interpreter's `==` treats meeting a function as a compiler bug,
  and a dictionary no longer takes the comparison's location, which was
  there only for the panic.
- **R4, printing dictionaries.** `ren core` prints as before. `ren core
  --types` prints what a function needs after its type, `(needs (eq
  T))`, the dictionaries a use passes after its type arguments, `(inst
  same Int (eq Int))`, and the one each `==` compares with, `(== (eq Int)
  a b)`, so the two typed snapshots that have an `==` changed
  (test_lower.ml, test_infer.ml).
- **R4, interfaces.** The interface is still made from declarations, but
  what a public function or member needs of its type parameters isn't
  declared, so it's given what inference found, by path, as it's made
  (`Iface.of_module`'s `needs`). The driver's check that a public
  function's inferred scheme is the one its interface states then
  compares whole schemes, requirements too, and says what each needs if
  they differ. A module that imports it checks a call's requirements
  against the interface, as it does its own functions' (test_infer.ml,
  "another module's function needs what it needs"), and a body edit
  changes the interface only when it changes them (test_modules.ml,
  "editing a body changes the interface only by what it needs"). An
  opaque type in the interface hides what it's represented as, but says
  whether it has `eq`, which inference works out from the representation
  (`Iface.of_module`'s `has_eq`), so another module can't compare two
  values of one represented with a function in it (test_eval.ml, "==
  can't panic").
- **R4, a generic method used before it's checked.** A method whose
  signature is written out in full had its declared type before its body
  was checked, so a dot call of it needn't come after it. A generic one
  no longer does: what it needs of its type parameters is known only
  from its body, so a dot call of it that resolve.ml couldn't tell is
  found by checking, as for any other method (`Unchecked`), and checked
  after it (test_infer.ml, "a generic method called before it's
  checked").
- **R4, printing requirements.** `ren types` prints each type parameter
  with what it needs, `<T has eq, U>`, named as it was before, so one
  without a written name is `T`, `U`, ... in the order it appears. A
  member of a type doesn't list its type's parameters, but one that
  needs something of one lists that one, `fn has<T has eq>(self, x: T)`,
  since nothing else would say it.
- **R4, where a call that can't have a requirement is reported.** At the
  first argument the type parameter is in, as operators.md's example
  points at `inc`, the receiver first for a method; at the function's
  name if it's in no argument, or the function is used as a value, `let
  s = same`.
- **R4, the implementation tier.** It's a type of its own (impl.ml),
  beside `Iface.t` rather than in it, since it holds Core, which the
  interface, a part of every pass from resolve on, can't depend on.
  It's made from the module's Core and its interface, once it's lowered,
  which the driver does once for each module, when it's first needed.
  It holds each public function's, and each public type's member
  function's, typed Core if it has a type variable, which every member of
  a generic type has, or a parameter or result with a function type in
  it; row variables don't count, since every function has them. A
  handler, whose result is an implementation of functions, isn't counted
  as higher-order: specializing for a known handler is decided where
  it's installed, which is later work. Its Core has no source locations,
  so it changes only when one of those bodies does (test_modules.ml,
  "what the implementation tier records"). It isn't yet all a specializer will need. It holds only
  public bodies, so a private generic helper a public one calls isn't
  in it; and it tells a higher-order function only by the function
  types its signature writes, so one that takes a record with a function
  field, or an implementation of a dependency, isn't either. Both wait
  for the stage that reads it, which knows what it has to copy.
## Stage 9a deviations

Where building operators, `key` and `with numeric` (operators.md, 9a)
differed from its plan:

- **Where `with numeric` is kept.** The plan puts it in `Iface.Hidden`,
  beside `eq`. It's a field of every type declaration instead,
  `Iface.type_decl.numeric`, what the type is represented as, so the
  module's own inference, Lint and `ren types` read it the same way as
  another module's do. `Hidden` keeps only `eq`; a type's order is
  derived from its key, `numeric` or, in its own module, its
  representation, where it's asked for.
- **An opaque type in its own module.** An operator on one is found as
  in any other module first: the one it writes that takes the right
  side's type, or what `with numeric` gives, so in `Money`'s own module
  `price * 3` is a `Money`. Where none of them takes the right side, it's
  its representation's, as everything else about the type is there:
  `price + 1` is an `Int`. Inside the type's own members it's always its
  representation's, since that's what they're written in terms of:
  `self - t` in `Time.sub(self, t: Time)` subtracts two `Int`s rather
  than calling itself. Comparisons aren't revealed: `<` on one is
  through its order, which in its own module is its representation's,
  unless it has a key.
- **A `NaN` is checked where it's observed** (decision 15; nan.ml), in
  the interpreter as in both native builds: arithmetic carries it
  (arith.ml), and comparing it (`ordered`, and the walk's
  `same_leaf`, raising `Nan.Seen`, which the caller turns into its own
  panic; a value with one in it, even where the comparison ends before
  reaching it, walk.ml's `equal` and `compare`), `show`, `round` and `truncate`, hashing, and a dependency's
  operation given one (Core's `Nan_check`, which lowering puts on each
  argument whose type could hold a `Float`) panic. The operation that
  made it tags it with where it is, in bits 29 to 50 of the payload,
  which a `Float32` keeps, so the panic says where it was made.
- **A key that leads back to its own type** (its type has the type in
  it, or a type whose key does) is an error (Infer_reqs.key_loops),
  which operators.md doesn't name: comparing two would compare two of
  the same type again, and never end. Such a key is otherwise treated
  as absent, so inference, Core Lint and the walk never go round.
- **A generic function called with a type that lacks several of its
  requirements** is reported once, for the first, as operators.md's
  `sum([true, false])` is. Another module's function's note says what it
  uses but not where, since an interface doesn't carry its body's
  locations.
- **An operator written for several types on its right can't be named
  as `V.add`**, as a value or a call, since nothing there says which;
  `a + b` and `a.add(b)` choose by the right side.
- **`Int` and `Float` have no `add` method** was so until 9c, which
  made each operator a method of theirs too, an intrinsic, so `n.add(2)`
  works. Its arithmetic is the operator's (arith.ml, shared by both), so
  it panics where `n + 2` does, but without the help to wrap, which the
  operator's panic gives.
- **The overflow panic's help**, `n.wrapping_add(1)`, is given only when
  the left side is written as an `Int`: a `T` or a `with numeric` type
  has no `wrapping_add` to suggest. For `n += 1` it's `n = n.wrapping_add(1)`,
  since the call alone changes nothing.
- **A derived dictionary at runtime** is made from the type the
  dictionary's descriptor describes, in the running program, not from
  the dictionaries it was derived from: the walk needs the whole type
  anyway, to call a generic type's `key` or operator with what its
  parameters stand for. `Derived`'s `from` is still there, for Core Lint
  to check it's built only from the function's own.
- **What a reserved member may be is checked twice.** Resolve checks
  what's written: an operator, `key` or `show` is a method with its
  types written, no `inout`, no `!` and no `uses`, `zero` and `one` are
  values with their type written, and `eq`, `hash` and `compare` can't
  be written; once names are resolved, that `show` makes a `Str` and
  `zero` and `one` are of their own type. Inference then checks its scheme fails with nothing and
  uses nothing, since a private member's body can add to an unwritten
  row.
- **An associated value can still compare its `T`s.** The plan makes any
  requirement on an associated value an error, since it's made once and
  given no dictionaries. Values of a type variable nothing decided are
  compared by their shape, as before 9a, so `eq` and `hash` are allowed,
  and only the others, which have no shape to go by, are errors.
- **A comparison of two opaque types** no longer says either one's
  representation is private: neither is the other's representation, so
  `t -= Time.epoch` says only that it makes a `Duration`, not a `Time`.
- **The smallest `Int` is a literal**, `-9223372036854775808`, though
  2^63 alone doesn't fit: the lexer reads it as `Int64.min_int`, and the
  parser lets it through only right after a `-`, as the whole literal,
  not a `Neg` of it, which would overflow.
- **A `Float` is shown without an exponent**, `100000000000000000000.0`,
  not `1e+20`: a literal has none, so what's shown reads back as Ren.
- **Tuples were 9b.** The spec's `Name` key, `(Str, Str)`, and ordering
  tuples element by element waited for them, and work now.

## Stage 9b

Tuples, ranges, `Map` and `Set`, and the collection methods
(operators.md, 9b). Each fact is where it was, and gains a case:

- **Tuples** are a built-in type of each size, `(,)` and `(,,)`
  (`Ty.tuple`), which no program can name, so a tuple's type is a
  `Con` like any other's, and inference, the requirements, Core Lint
  and the walk each have one case for it: its parts, in order. It's
  ordered when its parts are, lexicographically, and hashed and compared
  part by part. A `let`, a `for` or a lambda's parameter takes one apart
  with a pattern that always matches (the parser checks: names, `_` and
  tuples of them), and lowering makes it a `match` of one arm, so
  exhaust and Lint check it as any other. A `var` can't take one apart.
- **A range** is a `for`'s, not a value: `For`'s `over` is `Each` or
  `Range`, and lowering makes a range a counting `while`, its end
  evaluated once. That keeps one way to count, and no second collection
  type: `(0..n).map(f)` would do what `for` and `with_index` already do.
  Slices, `xs[a..b]`, are deferred, and can reuse the syntax.
- **`Map` and `Set`** are built-in types whose values are a table
  (value.ml, `VTable`; table.ml): entries in the order each key was
  first set, and each entry's number by its key's hash. Each operation
  is an intrinsic whose scheme needs `hash` of the key, and is given its
  dictionary, the hash with the `==` it agrees with (Requirements,
  above). A key set again keeps its place and its first spelling, as
  `uniq` keeps the first of equal ones: setting `Email.of("ANN@x")`
  after `Email.of("ann@x")` changes only the value. Every hash is mixed
  with a seed chosen when the interpreter starts (walk.ml, `mix`), so
  which keys share a bucket changes from run to run, and nothing can
  observe it: iteration is in insertion order, and `==` and
  `hash` of two tables ignore it, so two maps with the same pairs set in
  another order are equal. A `for` over one goes over an array of its
  entries, `(k, v)`, or members, made by `Core.Entries` and
  `Core.Members`; inference decides which from the iterable's type,
  which is carried at its node, so lowering reads it and decides
  nothing.
- **The collection methods** are Ren, in the prelude's source, under
  `pub type Array<T> = builtin`, `Map<K, V>` and `Set<T>`: a declaration
  that adds members to a built-in type, which only the prelude can
  parse (`Parser.parse_program ~prelude`). Resolve accepts it only for a
  built-in type of the same arity, and its own members' names, as the
  rest of the module sees them, are the intrinsics' then the written
  ones (`Iface.join`), so `xs.len()` is still `Intrinsic Array_len`,
  and `xs.map(f)` is a call of `Array.map`, a function of the prelude
  like any other. What each needs of its type parameters is inferred,
  as for any generic function: `sum` needs `add` and `zero`. Written
  in Ren, each builds its result by `&out.push(x)`, which is why `push`
  is cheap (below). What's an intrinsic is what Ren can't say yet:
  `len`, `push`, `sort` (a merge sort given the `ord` dictionary) and
  the hash table.
- **`push` doesn't copy.** An array (value.ml, `vec`) is the first
  `len` items of a store other arrays may share, and an item below an
  array's `len` is never changed. Pushing onto an array that ends where
  its store's used items do writes into the store's spare room and
  gives a longer array of the same store; pushing onto any other copies
  it, with room to spare. So a loop of pushes is linear, where a copy
  each time made `map` over 40,000 elements take seconds, and the
  arrays that share a store still see only their own items: value
  semantics hold without knowing who else holds an array.

Where it differed from its plan:

- **Tuple parameters in a lambda only.** `fn((k, v)) => ...`, which
  operators.md lists as optional, came as a follow-up: the parser makes
  the tuple a parameter with a name no program can write, `$n`, and a
  `let (k, v) = $n` at the start of the body, so it's checked and
  lowered as that `let` is, a `match` of one arm. A named function's
  parameter is still a name, which its signature shows, so `fn f((a,
  b): (A, B))` is an error whose help takes it apart in the body.
- **A written `Map<K, V>` doesn't check `K` has `hash`.** Requirements
  are checked where a value is used, so `Map<Sub, Int>`, with a
  function in `Sub`, is an error at its first `set` or `of`, with help
  to give `Sub` a key, not where it's written. Checking written types
  would need requirements on type arguments, which nothing else has.
- **A `for` over `&m`, a `Map` or a `Set`, is an error,** with help to
  go over a copy and `set` what changes: a key changed in place would
  be in the wrong bucket. A `for` that changes each element of an array
  names it, and can't take it apart; inference says so, not the parser,
  so that `for (k, v) in &m` gets the map's message rather than one
  whose help leads to it.
- **`Map` and `Set` have most of `Array`'s methods, not all.** Neither
  has `index`, `uniq` or `tally`, and a `Map` has no `sum`. The methods
  that keep some of a table's entries give a table of the same kind;
  the rest an array or a value. `Map.first()` and the rest are written
  over its pairs, by a private `pairs()`, an array of them.
- **Each method that stops early is a loop that stops calling.**
  There was no `break` until 10c, so `find`, `any` and `all` go over
  every element but call the function no more once they know. They can
  `break` now, and haven't been rewritten.
- **`take` and `drop` of a negative count panic**, through an `assert`
  in the prelude. A failed `assert` in the prelude is a panic, said to
  be at the program's call that reached it, as any panic in the prelude
  is, and showing the condition, which the prelude's source can't, with
  the function it's in and what each variable in it is: "`take` needs
  `n >= 0`, but `n` is -1".
- **A failed `assert` on two maps** leaves out the entries they share,
  their keys paired by `==`, as the maps find them, so two keys equal by
  their type's `key` are one, and keeps a key whole beside its
  differing value: `Map.of([(AccountId(1), Account(..., balance:
  Money(-100), ...)), ...])` (an opaque record in parentheses since
  9c).
- **Help for names Ren doesn't use** (operators.md, "There's one name
  for each") is a table in infer_msg.ml, `other_names`, consulted only
  when the receiver's type lacks the name but has Ren's:
  `xs.filter(f)` says `select`, `s.find(":")` says `index`.

## Stage 9c

Boundaries (module-build.md, "Private unless `pub`"; testing.md, "Tests
are specifications"): opaque records, a type that keeps rules is opaque,
tests that see what an importer sees, test items, and `ren console`.
Each fact is computed once and carried:

- **`opaque { ... }`** is a type body of its own in the AST
  (`Opaque_fields`), and in the interface's `type_decl` it's a `Record`
  with `opaque = true`, a flag every opaque type has. So in its own
  module it's a record: literals, fields, updates, lowering, exhaust and
  Lint work on it unchanged, and there's no representation to reveal, so
  nothing joins `reps`. `Iface.of_module` makes any opaque type
  `Opaque (Hidden { eq })`, as it made `opaque Int`. A field and a
  method can share a name on one, `balance` and `balance()`, if the
  field isn't a function (Resolve); in its own module `a.balance` is the
  field (Infer_lookup, `own_field`). Shown, it's in parentheses,
  `Account(id: AccountId(1), ...)`, as no other module can write one;
  `Walk.view`'s `Record` says whether it's opaque, and a failed `assert`
  looks inside it as it does a record.
- **A type that keeps rules is opaque** is checked once every group is
  generalized (infer_top.ml, `check_keeps_rules`), since a private
  member's errors aren't written: a `pub` record or sum type can have no
  member, public or private, that takes `inout self`, or that returns
  the type, or a value with one in it, with an error row that has a
  label (a block parameter's error tail alone isn't one), or, with no
  `self`, returns `Option` or `Result` of one: a refusal written as a
  value. A method returning `Option<Day>` is a question about a value,
  not a way to make one, so it's allowed. It's reported once per type, at the
  first such member, with the type written opaque as the help, its
  fields' types printed through its parameters' names.
- **Test code is one flag,** `fn_def.test`, in the AST and in Core: set
  by the parser for `test fn` and `test handler`, and by Test_items on
  every function it makes of a test, a group or a run. Resolve reads it
  for what test code can see, Infer for which view a group is checked
  in, Iface for which tier a public one goes in, and `Driver.link` to
  leave it out of `ren run`, which it can because Core Lint checks that
  nothing else uses it (`test_code`).
- **Test items are in their own interface tier,** `Iface.t.tests`: a
  `pub test fn`, a `pub test handler`, and a `pub group`'s tests, which
  were in `values` before. Only test code finds a name there (Resolve,
  `qualified`); anything else gets "`m.alice` is a test item, so only a
  test can use it".
- **The client view.** Resolve knows the module's own private items,
  `own_private`, and reports test code naming one, a function, a type,
  a named error set, a dependency or a member written after its type: "`stamp` is private,
  and a test sees what an importer sees", at its first use only (it's
  taken out of `own_private` then), since the fix, marking it `pub` or
  exploring it in the console, is the same at every one. What's found through a type,
  a field, a method, a representation, is Infer's: a group of test code
  (a group is all test code or none, since only test code calls it) is
  checked with the module's own types swapped for what an importer sees
  of them (`client_view`, made once: an opaque one hidden, a private one
  empty and not visible), no representation revealed, and `env.client`
  set, which `Infer_env.own` reads wherever a check used to ask whether
  a type is the module's own. They're put back after the group, by
  `Fun.protect`, since the constraint solver runs inside it. The
  messages say "a test sees what an importer sees" when the opaque type
  is the module's own (`Infer_env.tested`), and a test item's say the
  same, since it's test code too. Since 10b a representation test code
  reaches for, whether by a field, as what it's represented as, or by
  an order an importer can't see, is reported at its first use per type
  only, and so is a private method it calls, per method
  (`report_test_once`, `test_reported`), as a private item is; and a call whose callee is
  unknown, or an error already reported, marks the `try`s around it as
  failing (`unknown_call`), so they don't also say nothing in them can
  fail. While the view is swapped in,
  `env.hidden` holds the private types as the module declares them, so
  a bare constructor of one is reported as private, not as missing.
- **The console** (driver.ml, `console`; console.ml) is the simplest
  sound design: each line re-checks the program with the session added
  to the module as a private function, `$console`, of no parameters,
  whose body is every line kept then the new one, each earlier
  expression kept as `let _ =`; and re-runs it from its first line, as a
  test is run (`Eval.run_installed`), on the test implementations but
  those `--real` names, `Random` from seed 0. A real one would make the
  run differ each time, and do its effects again, so the session keeps
  a journal: what each built-in gave, which a run again gives the kept
  lines back without asking the world. Since 10b that's the journal
  (journal.ml, `Session`), through a recorder over each built-in (Stage
  10b, below), which also shows each call as it's made; 9c's own, in
  builtins.ml, is gone. Infer checks the
  session as it checks a test (`check_console`): a dependency nothing
  installs is reported "in the console", unless the line is `:t`,
  which doesn't run. The session is test code (`fn_def.test`), so it
  can use test items, and the program is checked with test code seeing
  every module whole (`sees_all`, Resolve and Infer): the console is
  where a test told it reaches past the interface is sent, so that error
  can't keep it shut. Each line is lexed on its own, its nodes numbered
  on from the line before (`Parser.parse_session_line`); since 10b, line
  `i` of the session is line `i` of `<console>`, and a message shows the
  session's lines (9c made each line 1). A `:t` line's tokens are moved
  past the `:t`. A line that doesn't check,
  fails or panics isn't kept, and neither is what its run was given.

Where it differed from its plan:

- **No `test type`, `test dep` or `test let`.** Each would need a view
  of its own in the test tier. So a dependency only tests use, prices'
  `Calls`, is an ordinary `pub dep`.
- **Test items are `Fn`s with the flag,** not a `testing` case of their
  own: every pass already handles a function.
- **Rule 2 is reported once per type,** not once per member: the fix is
  the same for all of them.
- **The console's costs.** Every line re-checks and re-runs the whole
  session, so a long one gets slower line by line. The journal is
  stage 10's replay in miniature, for the built-ins only, and matched by
  position: the kept lines are deterministic given what they're given,
  so they make the same calls in the same order. A line that fails
  after a real effect isn't kept, but its effect happened. Input is one
  line at a time, so no multi-line `match`. `:t a.credit`, a method not
  called, is an error: write `:t Account.credit`.
- **`n.add(2)` on `Int` and `Float`** is intrinsics only (arith.ml, the
  arithmetic `+` and the method share): a call that overflows panics
  without the `wrapping_add` help an operator's panic has, since that
  help is built from the operator's source. A `with numeric` type has
  its operators with no methods behind them, so outside its module
  `m.add(n)` is an error whose help writes the operator,
  `m + n` (Infer_msg, `numeric_method`); in it, the representation's
  method is found.
- **A private type named in a `pub group`'s parameters** is reported
  twice: once as a public group taking a private type, and once as test
  code naming a private item.

## Stage 10a

Handlers (handlers.md): a `with` is a set, `over` and `next`, `finally`,
and handler state that can fail to start. Each fact is computed once and
carried:

- **An implementation's type** is one constructor, `TImpl` in inference
  (types.ml) and `Impl` in canonical types (ty.ml): the dependencies it
  implements, sorted, whether it goes `over` them, what it needs and what
  it can fail to start with, `fails`. Unification compares `over` and
  unifies both rows, each use gets a copy of `fails` as of `needs`, and
  `ren types` prints it as it's written, `over Sql ! DbDown uses Os`.
- **A `with`'s items** are a list in the AST, each a chain of links, top
  first, and what the bottom goes over when it's the one outside,
  `over Prices`. Inference classifies each link once, in the `with`'s
  own context, as an implementation (`Installs` or `Installs_handler`
  at the link's node), checks the chain and
  the set, and records the order to install the items in at the `with`,
  `Install_order`: an item whose needs another installs goes inside it,
  and otherwise the order of their dependencies' names. Lowering makes
  each implementation's value outside, in the order written, then nests
  a Core `With` or `With_handler` for each in that order, each chain's
  bottom outermost. Until 10c a link could be a wrapper too, a function
  given the body as a block; 10c took them out (foundations.md), and a
  wrapper in a `with` is an error whose help writes the call,
  `try retry(3) fn() => ...`.
- **`next`** is resolved to `Next_op (dep, op)` only in a handler
  declared `over` (Resolve, `next_op`), typed as the operation is, and
  lowered to a `Dep_call` marked `next`, on the `Handler`'s own evidence,
  what's installed where it is, so the one under it, even inside a `with`
  in an operation. The handler's state, operations and `finally`, and
  any block written in them, can call it: since 10c step 4 a block
  captures the evidence where it's written, and since step 3 it can't be
  kept, so passing one to the implementation under the handler makes no
  cycle ("No cycles"). Lint checks a `next` call is given its
  handler's evidence, in scope, and that the handler needs the
  dependency. A handler over `D` needs `D`, joined to its needs only
  after its state, arms and `finally` are checked, so a call that names
  `D.op` brings `D` itself and is reported (with help naming `next.op`,
  or `next(D).op` when another dependency it goes over has an `op`),
  while a call that only got it from sharing the handler's row isn't. What an over
  handler leaves out, inference records at the handler,
  `Handler_facts.forwards`, each with the type of a lambda of its own,
  and lowering makes it a lambda that makes that call. Lint checks every
  instance's record has each operation, as any record literal.
- **A handler's `fails`** is the row its state and `finally` are checked
  with, written after `!` on a public one and closed, inferred on a
  private one and closed once its group is done (`check_needs`). A
  `with` passes it on with its keyword as the `try` (`absorb`), and
  `Core.can_fail` says a `With` whose implementation's type has `fails`
  can fail.
- **`finally`** is checked with the body's type and errors as skolems of
  their own, `r: Result<T, ! ..e>` returning `T`; what it fails with, but
  `..e`, is the handler's `fails`. Once the function is generalized they
  become variables numbered after its own, and the handler records which
  is the body's type, `Handler_facts.body_ty`. A requirement found of it,
  `==` on the body's value, is an error. Lowering makes it a lambda in
  the `Instance`, `{ impls; finally }`, that takes a descriptor of that
  type first, and each Core `With` and `With_handler` carries a
  descriptor of its body's type, `desc`, which it passes when its body
  ends, with `Ok(v)` or `Err(e)`. Lint checks the `With`'s `desc`
  describes its body's type, and the `finally` is a lambda of that
  descriptor and a `Result` of the next type variable, returning it.
  Since 10c a handler can have several, which lowering makes that one
  lambda (Stage 10c).

Where it differed from its plan:

- **`finally` isn't lifted** to a generic top-level function: it's a
  lambda in the instance, as the arms are, which keeps the cells as they
  do. Its one type variable is the function's next, which only its
  descriptor parameter describes (Lint's `body_ty`), so `print(v)` works
  in it without a lifted function's descriptor.
- **A written implementation type without `!` can't fail to start,** a
  parameter's of a dependency's type included, where the plan had one
  fail with its function's errors.
- **The help for a link over nothing** writes `over D` rather than naming
  a maker of `D`.
- **`ren core` doesn't print a `With`'s `desc`.**

## Stage 10b

The journal (handlers.md, "The journal"; testing.md, "The journal is a
test" and "The console"): recording a run, replaying it, a journal as a
test, tracing, and the console's effects, `:reload` and `:spec`. Each
fact is computed once and carried:

- **What reaches the world** is said once, in prelude.ml: `reaches`
  names every intrinsic, and gives the operation of each that reaches
  the world, `fs_read` is `Fs.read`'s; an intrinsic's `caller`, `World`,
  `Test`, `Journal` or anyone, is `World` exactly when `reaches` gives
  one.
  Core Lint's `world` checks each is used only in that dependency's
  `real`, and `journal_load` only in test code ("What each IR
  promises"). So everything a program does to the world is a call of an
  operation of `Clock`, `Random`, `Console`, `Fs`, `Os` or `Proc`, which
  is what a journal records.
- **The recorder and the replayer are handlers in the prelude,**
  written in Ren: `recording_clock(j) over Clock`, and one for each
  built-in, and `replaying(j) for` all six, whose `finally` compares a
  test's outputs. They call five intrinsics, `journal_kept`,
  `journal_gave`, `journal_answer`, `journal_outputs` and
  `journal_load`, each given its values' descriptors, as `show` is, so
  the interpreter writes and reads a value through its type
  (`Walk.view`, as `show` and `==` do). A Ren program holds a journal
  only as its number, `Journal`, an opaque `Int`.
- **journal.ml is the one module that knows the format:** writing a
  value, reading one back told its type, an entry's line, the header,
  and what each mode does with a call: recording it (`Record`),
  answering it strictly (`Strict`, `ren replay`), answering a test's
  inputs per dependency and keeping its outputs (`Test`), or keeping a
  console session's (`Session`). A call that goes differently raises
  `Journal.Differs`, without where; the interpreter makes it
  `Eval.Went_differently` at the call (`call_at`), moved from the
  prelude to the program's call, as a panic is. A call past the end of
  a recording that ended in a panic raises `Journal.Recorded_panic`,
  and the interpreter, which knows where the call was made, makes it
  the panic if that's where the recording panicked, and otherwise a
  replay that went differently, or, in a test of a recording that ended
  in an error or a panic, `Journal.Went_past`, which passes the test.
  Whether a call is an input or an output is decided once per
  operation, by its declared type, when the program is loaded
  (`Eval.load`, `outputs`), and looked up (`gives_nothing`) when a
  test's journal is sorted, when a call is answered, and when a
  recorded call's `→ gave` is left out (`Journal.write_gave ~output`).
  Where a panic was is written and compared by `Journal.place`, so the
  format lives in journal.ml only.
- **`ren run --record` and `ren replay`** start the program without
  `$start`: the runtime installs what `main` uses itself (`Eval.run`,
  `start`), a recorder over each real implementation, or the
  replayer's implementation of each, as it installs a test's, and calls
  `main`. What `main` uses is derived once (`Lower.main_uses`, which
  `$start` installs too); the driver writes it as the journal's header,
  or checks a replayed journal's header is it, and `Eval.run` installs
  what the header says. The last entry is how the run ended, an error
  as the journal writes a value (`Eval.Uncaught`'s `written`), a
  panic's place from the program's folder; a replay compares its end
  with the recording's (`Journal.finish_replay`).
- **`--trace`** wraps each operation call the interpreter makes
  (`Dep_call`, but a `next` in the prelude's recorders) in `traced`,
  which adds it to a tree (trace.ml) under the call running.
- **`replay(file)`** is a public test item of the prelude, the only one:
  the prelude's test items are in scope bare for test code, and only
  for it (Resolve, `own_tests`). The prelude is checked seeing itself
  whole (`sees_all`), since `replay`, test code, calls the private
  `replaying`. A test is run with the folder of its file
  (`Eval.run_test ~dir`), which the journal's name is found from.
  `replaying` implements all six built-ins, and inference narrows a
  `replay("...")` link of a `with` to those its journal's header names,
  read when it's checked (`Infer_handlers.replayed`), as a handler is
  narrowed where a written type asks for some of what it implements;
  lowering wraps it in `Narrowed`.
- **The console** is a journal session, with a recorder over each
  built-in (`Eval.run_installed ~journal`): a kept line's calls are
  checked against what it made, and a real one's answer given back; a
  new line's are shown as they're made. `:reload` reads the module again
  and runs the session on it; a line that doesn't check, or makes other
  calls, is dropped with those after it (`Journal.drop_from`). `:spec`
  (`Driver.console_spec`) checks the session as a test of the module,
  line by line, with test code seeing what an importer sees, and keeps
  each line that checks, an expression whose value was shown as an
  `assert` of it if that checks, or else as `let _ = ` and the line.
  Then it runs the test as `ren test` does (`Eval.run_test`, `Random`
  seeded by the test's name, `Test_items.seed_of`), and where it ends,
  an `assert` is kept as its line and another line is left out, until
  it passes: what `:spec` writes passes, not only checks. A call shows
  in the console as the journal writes it (`Journal.entry_text`).
- **An arm can name its dependency,** `Console.write(line) => ...`
  (`arm_op = Item`), for a handler of two dependencies that have an
  operation of one name, as `replaying` is.

Where it differed from its plan:

- **The runtime installs the recorders and the replayer, not Core.**
  The plan had `Lower.start` make `$record` and `$replay`, Core
  installing the prelude's handlers as `$start` installs the real ones.
  Instantiating their row and lambda-set arguments in Core was more
  than it was worth, so `Eval.run` installs them, as it installs a
  test's; the handlers themselves are checked and linted with the
  prelude.
- **The journal's format is the first one handlers.md sketches,
  simplified:** one call a line, `seq Dep.op(args) → gave`, no `task`
  and no table of names, and no size cap; an opaque value is written as
  what it's represented as, a `Path` as its string, `Bytes` as a string
  with `\xNN` for a byte that isn't UTF-8. A header's dependencies are
  sorted, as `main`'s `uses` is.
- **Qualified arms** are new syntax (parser, the tree-sitter grammar and
  Zed's queries), which `replaying` needed: `Console` and `Fs` both
  have `write`.
- **`--trace` is one level:** arguments and what each call gave, cut to
  40 characters, `Bytes` as how many, and how long it took unless
  `REN_NO_TIMINGS` is set. There's no level 1 without arguments.
- **A replay prints what the program printed through `Console`,** but
  not what a process it ran printed, since nothing runs.
- **`ren test --keep`** moves the journal into `tests/` next to the
  program and appends the test to the program's file; `main` has to be
  `pub`, since a test sees what an importer sees.

Leftovers from the 9c and 10a reviews, done here: a representation
reported at its first use per type, and the `try` cascade (Stage 9c,
above); `5 + price` and `price < 5` on an opaque number help with its
constructors, from any expression of its representation; a handler's
parameter that goes over nothing says to write `over D` in its type;
`h() over A` where `h` goes over `A & B` says to name both; and `outer`,
or `next`, in a record implementation says a handler over it is how
(record implementations removed in 10c).

## Stage 10c

Blocks (foundations.md, decisions 1, 2, 5 and 7; Blocks, above). Six
steps, each green on its own: the specification first, as
test_blocks.ml's catalogue with each test's target; then deletions,
lambda sets out of the type checker, wrappers out of `with` and record
implementations out, each with a fix-it; blocks second-class; lexical
lookup; capture by reference with one exclusivity pass; and the
additions below. Each fact is computed once and carried:

- **Where a block can be, what it captures, and exclusivity** are in
  Blocks, above. A block's name is its one stable fact Core keeps from
  what lambda sets were, `Lambda`'s `name`.
- **`while` and `break`** are Core's `While` and `Break`. Resolve
  decides where a `break` is allowed, once, from where it's written:
  inside a loop, and not across a block or a `with` (`loop_at`); Lint
  checks a `Break` is inside a `While` of its own function, block or
  handler. A `for`'s element written back through `&` is written back
  when a `break` leaves the loop, by the `Finally` that already did it
  when the body failed, which lowering adds when the body can `break`
  too (Lower, `breaks`).
- **A cursor** is a type with a method `next(inout self) -> Option<T>`
  that can't fail and uses nothing. Inference decides once that a
  `for` goes over one, recording the method (`Method_of`) and its type
  arguments at the loop's subject, and lowering makes the loop a `While`
  over a `match` of `next(&c)`, `None` breaking. A `for x in c` steps a
  copy; `for x in &c` steps `c` itself, so a loop left by `break` leaves
  it where it stopped, and the next loop goes on from there.
- **`finally` is a statement where it's written,** and covers what
  comes after it: several among a handler's state, before its arms, or
  among the top-level statements of an arm. The parser reads it as a
  statement, `Ast.Finally` of a lambda; resolve allows it only in those
  two places. One among a handler's state is checked as 10a's was,
  every one of a handler sharing the body's type and errors as skolems
  (`Handler_facts.body_ty` is unchanged); one in an arm is checked as an
  `attempt` of the rest of the arm, so `r: Result<T, ! E>` where `T` is
  the arm's value. Lowering composes a handler's into the one lambda
  10a's `Instance` holds, the last written run first, each earlier one
  given what the one after it returned or failed with; and when the
  state after one can fail to start, it handles that error with the
  `finally`'s body given `Err(e)` before failing with it, Koka's
  `finally` around `initially` (/tmp/ren-refs/koka/lib/std/core/
  hnd.kk:485-494). One in an arm is lowered as `let r = attempt
  (rest) in` its body. Core is unchanged for it.

Where it differed from its plan:

- **A `break` can't leave a `with`.** A handler's `finally` is given
  the body's result, and a `break` gives none, so it's an error whose
  help ends the body in a `Bool` and breaks after the `with`; a `break`
  inside a block can't leave the loop around the block either.
- **A cursor's `next` can't fail or use anything,** so a `for` over one
  needs no `try`; a cursor that reads a file waits for generators
  (11c). Changing the element a cursor loop gave is an error: there's
  nothing to write it back to.
- **A `finally` in an arm is only at its top level,** not inside an
  `if` or `match` of it, and one in a handler is never after its first
  arm: the parser says to move it above. A block that ends in a
  `finally` is an error, since nothing comes after it.
- **The failed-start path copies a `finally`'s body** into the
  `Handle` of the state it covers, so the body is lowered twice, its
  binders' ids repeated in two subtrees Lint sees apart. It's skipped
  when nothing after the `finally` can fail to start. The error it's
  given there is typed as the body's error skolem, which Core doesn't
  check.
- **Blocks still can't take `inout` parameters,** and `retry(n, on:)`,
  inline handlers and generic dependencies wait for 10d. Rules B to D
  wait for 11a, which makes concurrent and spawned parameters.

## Native slice

A C backend for the sequential subset, and vision.md's benchmarks
measured on it against Rust and Go, before tasks build on the design
(foundations.md, Staging, item 2). Six steps: the benchmarks
themselves (bench/native); Mem IR, the C runtime and a naive backend
for the first-order subset, with `ren build`; the debug strategy for
the rest of the subset, blocks, generics, handlers, errors, `show` and
`Console`; Perceus over Mem IR; release builds that specialize; and the
measurements. Then those that act on what they measured: arrays in
loops, the experiments merged, the release build's costs, small values
and packed fields, arrays of arrays and recursion that builds, sized
storage, floats checked where they're observed, loops without indices,
and debug builds with tcc. Each step extends this section, and says
what it changed of the ones before.

### Step 2: Mem IR, the runtime, and `ren build`

`ren build file.ren [-o out] [--debug | --release] [--emit-c]
[--stats]` links the program as `ren run` does (`Driver.linked`), lowers
what `$start` reaches to Mem IR (to_mem.ml), checks it with Mem Lint
(mem_lint.ml), writes it as one C file with the runtime in it
(emit_c.ml), and runs `$REN_CC`, or `cc`, in a temporary folder, with
`$REN_CFLAGS` added. Debug is `-O0 -g`, release `-O2`, the same code
until step 5; both pass `-ffp-contract=off`, so a `Float` is never
computed with a fused multiply and add the interpreter doesn't do. The
binary prints what `main` gives as `ren run` does.

**Mem IR** (mem.ml) is A-normal form: every operand is a variable or a
constant, and each value has a layout, fixed where it's made:

| Layout | What it is | In C |
|---|---|---|
| `Int`, `Float`, `Bool`, `Unit` | scalars | `int64_t`, `double`, `bool`, `uint8_t` |
| `Enum` | a sum type none of whose constructors has fields: its tag | `uint32_t` |
| `Boxed` | a counted object: a record, a tuple, a constructor with fields, an error, an array or a `Str`; a constructor without fields of a sum that has some is a small tagged scalar in the pointer, never counted, Lean's `lean_box` | `ren_obj*` |
| `Cell` | the address of a C local: an `inout` parameter | a pointer |

Allocation, `Dup`, `Drop` and `Free` are instructions. Control is `If`,
`Switch` on a tag, `Loop` and `Break`, `Joins` and `Jump` (Lean IR's
join points), and `Catch` and `Raise`. Mem Lint checks that every
variable is defined before its use, in a scope around it as C's blocks
scope it, and once; that every operand has the layout its operation
needs; that only counted values are counted; that a call passes what
its callee takes and a function that can fail is only called with a
status; that a `Break`, `Jump` or `Raise` is inside what it goes to; and
that an object's counted fields come first. The tests run it on every
program they lower (test_native.ml), and `ren build` on every program
it compiles.

**Calling conventions.** A function whose type can fail with a tag
returns its error, or `NULL`, and writes its value through a last
pointer parameter, `ren_out`; `Fail` raises, a failing call checks its
status, `Handle` is a `Catch`, and `Finally` a `Catch` whose handler
runs the `after` and raises again, the `after` also run on the normal
path and before a `break` that leaves it. An `inout` argument is the
address of the caller's local. `match` switches on the subject's tag
when it's of a sum type: each case tries, in order, only the arms that
can match its constructor, and each arm's body is a join point after
the tests, its pattern's variables declared before them. A subject
written as a tuple, `match (a, b)`, isn't allocated: each arm's parts
are matched against the parts. `while` is a C loop, and `break` a jump
to its end. `Set_index` and `Array.push` copy the array: the naive
semantics, which step 4's reuse makes in place.

**Counting is naive,** H3's baseline: every use of a counted variable
is a `Dup` into a fresh temporary that whatever uses it takes, a value
only read, a `match`'s subject or a record a field is read from, is
dropped once it's read, and every variable that owns one is dropped
when its scope ends. A `Break` or a `Raise` drops what each scope it
leaves holds: to_mem.ml keeps, per scope, the counted values held
there. Step 4 keeps this as `--rc naive`.

**The runtime** is lib/native/runtime, `ren_rt.h` and `ren_rt.c`,
which a dune rule embeds as an OCaml string module (`Runtime_c`), so
the binary needs no installed files. An object's header is its count
and enough to free it without its type: its kind, its tag, and how many
of its fields are counted. `ren_dup` and `ren_drop` are lean.h's
`lean_inc_ref` and `lean_dec_ref` (lean.h:727-785) without the
thread-shared paths, and `ren_is_unique` is `lean_is_exclusive` and
kklib's `kk_block_is_unique` (kklib.h:306): counts are plain, since a
program has one thread. A count of 0 is an object that's never freed,
as Lean's, which is what a string literal is: made once in the C file.
Freeing goes through a list rather than recursing, as
`lean_dec_ref_cold` does (runtime/object.cpp:311-331), so dropping
`nqueens`'s long lists won't overflow the stack. Arrays keep their
length, capacity and whether their elements are counted. `Int`
arithmetic is checked with `__builtin_*_overflow`, and panics, a NaN
where it's observed (step 13), `round` and `truncate`, say exactly what
lib/eval/arith.ml and builtins.ml say.
`-DREN_STATS` counts allocations, frees, dups, drops, reuses, the most
bytes live at once, and the objects still live, printed to stderr when
the binary exits.

**A panic prints what `ren run` prints.** Each place that can panic is
a site, whose message the driver renders as `ren run` would, with a hole
where the message goes (`Driver.site_text`), the overflow help included;
the binary prints the parts around the message it makes. The program
runs on a thread with a 1 GiB stack, which the system maps as it's
used, and every function compares its frame with a limit 1 MiB above
the end, as Go's prologues do, so recursion with no end is the
interpreter's stack-overflow panic, at `main`.

**The subset** is first-order and sequential: `Int`, `Float`, `Bool`,
`Unit` and `Str`; records, sum types, tuples and arrays; `match` with
guards, `if`, `var`, `inout` and `&`, `while`, `for`
over ranges and arrays, and `break`; errors, with `fail`, `try`,
`match` with `fail` arms and `attempt`; `assert`; `show` of a scalar or
a `Str`, `Str`'s `concat` and `len`, `Array`'s `len` and `push`, and
`Float`'s conversions; and `print` and `Console.write` to the real
`Console`, which is the only implementation installed. `$start`'s
install of `Console.real` is the only `with` it compiles, and a call of
the prelude's `print` at a scalar or a `Str` is its `show` written to
the console, since `print` itself is generic. Anything else, a generic
function, a block, a handler, another dependency, `==` on a type that
isn't a scalar or a `Str`, a `Map` or a `Set`, is an error at the code
that needs it: `<what> isn't in the native slice yet`, with help to run
it with `ren run`. bench/build.t builds every program in the subset,
`fib`, `deep`, `loop` and `overflow`, `binary-trees`, `cfold`, `deriv`,
`fannkuch` and `nbody`, and the examples `fib` and `blocks`, under ASan
and UBSan, and checks each against `ren run`.

Where it differed from its plan:

- **A function returns a status only if it can fail with a tag,** not
  whenever `Core.fails` says so of its type. Every function whose
  errors are inferred has a row with a tail, `! ..e`, which `Core.fails`
  counts as failing, but without a block parameter that tail can't
  bring a tag in, so `fib` returns its `Int` (`To_mem.fn_fails`). Step 3
  makes a function with a block parameter whose tail it shares fail.
- **The interpreter's limit of 100,000 calls isn't the binary's.** The
  binary overflows only when its 1 GiB stack does, so a program between
  the two runs natively and panics in `ren run`; `cfold` at its full
  size needs it. Tail calls aren't made into loops yet.
- **Values a panic or an uncaught error leaves are leaked,** as
  foundations.md's decision 8 says, so `--stats` counts them as live.
- **`assert a == b` isn't in the subset,** since its message shows both
  sides through their types: step 3, with `show`.

What later steps need to know:

- Each function's convention is `Mem.fn.fails`, computed once by
  `To_mem.fn_fails`; a call looks it up by the callee, never from the
  type at the call.
- Generic code, blocks and handlers are rejected in `To_mem` at the
  `Global` with descriptors or dictionaries, the `Lambda`, and the
  `With`; step 3 replaces those cases, and evidence, which Mem drops
  today, becomes a parameter.
- `Runtime` calls borrow every argument, and a `Field` or a `Load` is
  borrowed; everything else gives an owned value. Step 4 replaces the
  `Dup`s and `Drop`s to_mem.ml places, and can keep their positions as
  `--rc naive`.
- `Free` and `ren_is_unique` exist for step 4 and nothing emits or
  calls them yet; the stats count `reuses` as 0 until reuse exists.

### Step 3: the debug strategy for blocks, generics and handlers

The rest of the sequential subset compiles, with no specialization:
generic functions, blocks, dependencies, `with` and handlers, `finally`,
`show`, `==` and order on any type, and the real `Console`
(foundations.md, decisions 1, 4 and 13). Every `bench/native` program
and every example that is a single file builds with `ren build
--debug`. This is the strategy debug builds keep: release builds
specialize from step 5, and get the same answers.

**Layouts it adds:**

| Layout | What it is | In C |
|---|---|---|
| `Word n` | a value of the type variable `n`: one word, counted through `n`'s descriptor | `ren_val` |
| `Desc` | a type's descriptor, counted: a static one has a count of 0 | `ren_obj*` |
| `Ev` | evidence: the dependencies installed where the code runs | `const ren_ev*` |
| `Block` | a block: its code and its environment | `ren_block`, two words |
| `Ptr` | a raw pointer: a block's environment or arguments, a handler's code | `void*` |

**A value of a type variable is one word** (`ren_val`): an `Int`, a
`Bool`, a `Unit` or a tag as itself, a `Float` as its bits, an object
as its pointer. Koka boxes what isn't a word where a value meets a
type variable (Backend/C/Box.hs, `boxExpr`); every Ren value but a
block is a word, and a block is never a type's argument, so nothing is
boxed: `To_word` and `Of_word` only change the C type. Fields stay in
the order they're declared, whatever their layouts, so generic code
finds a field where any other does, and the header's count of counted
fields is now a mask, a bit for each field holding an object (so 32
fields at most; Mem Lint checks it). Whoever makes the object knows
which, from the descriptors.

**Descriptors.** A type's descriptor says what its values are: a
scalar, a `Str`, an array or a tuple of descriptors, a type the program
declares with its arguments, or a type's errors. A function with type
parameters takes one descriptor per parameter before its other
arguments, and a dictionary, the requirement `T: Show` or `T: Eq`, is
the descriptor of `T` too: what it requires is decided where it's
used, and the derived walks need nothing else. Descriptors of closed
types are static C data, with each declaration's constructors and
their fields' types as templates over its parameters (`ren_decl`), and
those built from a generic function's own descriptors at run time are
counted objects (`ren_desc_new`). `ren_dup_val` and `ren_drop_val` count
a word through its descriptor. The derived `show`, `==` and order walk
a value with its descriptor (ren_rt.c, `ren_show_any`,
`ren_equal_any`, `ren_compare_any`), each one shown.ml's, eval's
equality's and eval's order's, case for case: the bench tests compare
them byte for byte. The arithmetic of an `opaque ... with numeric` type
reached generically goes through `ren_op_any`.

**Blocks.** Each block, a lambda written in a function, is lifted to a
static C function, and every block has the same signature: its
environment, its caller's evidence, its arguments as an array of words,
and where its value goes; it returns its error, or `NULL`. Its
environment is an array of the addresses of the locals it captures,
on the stack of the function it's written in: capture is by reference
(10c), so a captured variable is the writer's local and the block
writes through its address. A block is the pair, passed by value, and
calling it is an indirect call: nothing is allocated, and Mem Lint
checks that no block, and no cell, is ever stored in an object, which
is what keeps their environments from outliving the stack frame. A
parameter whose type lists dependencies, `fn() uses Log`, gets them
from its callee: the call installs the callee's evidence for those on
top of the block's own (`ren_given`, decision 5). `REN_STATS` counts
block calls, and bench/build.t checks H1 in the debug build: each
kernel of native/blocks written with a block allocates exactly what
its twin written as a loop does.

**Evidence and handlers.** Every function, block and handler takes the
evidence it runs under, a chain of nodes on the stack, each a
dependency's number, the implementation installed there and the next
node, after Koka's evidence vectors (std/core/hnd.kk, `Ev`). A
`Dep_call` finds the innermost implementation of its dependency
(`ren_find`) and calls the operation's block. An implementation is an
array of blocks, one per operation, whose environments hold the
evidence the handler was installed with, so `next`, and the handler's
own calls of what it's `over`, find the implementation under it. A
handler's description is a counted object, its code and what it
captured; its code takes the evidence to install on, the body as a
block, the descriptor of what the body gives and which dependencies to
install. It makes the handler's state as its own C locals, makes its
instance on its stack, installs it, calls the body, and runs its
`finally` with the outcome, `Ok` or `Err`, as `ren run` does. A `with`
lifts its body as a block that captures by reference, so it's an
ordinary call of the description's code; a narrowed description, `let
only: Log = both(5)`, passes only the dependencies it lists. `$start`'s
installs are ordinary `with`s, and an associated value such as
`Console.real` is made once before `$start` and dropped at the end.
The real `Console`'s `write` and `error` are runtime functions; any
other implementation the world provides, the real `Clock`, `Random`,
`Fs`, `Os` or `Proc`, is an error at the `with` that installs it:
``the real `Clock` isn't in the native slice yet``.

**Errors** are as in step 2, an error's tag carrying its payload as
fields; an uncaught one is printed through its own descriptors
(`ren_uncaught`), so its payload shows as `ren run` shows it.

Of step 2 it changed: the header's mask, above, for its count of
counted fields first; `print`, now the prelude's generic function
called with a descriptor, for its special case at a scalar or a `Str`;
and every function's evidence parameter, which step 2 dropped. Step 2's
list of what's in the subset is this step's, less what's below.

What's still outside, each an error at the code that needs it: a `Map`
or a `Set`, so no derived `hash`; a type with a `show`, a `key` or an
operator of its own where a descriptor walks it; `assert a == b`; an
`inout` parameter of a type variable's type, or a block's; a block
passed to a block; an associated value of a generic type; and an
instance outside a handler. bench/build.t builds every
`bench/native/*/small.ren`, `bench`'s programs, the single-file
examples and examples/shop and examples/two under ASan and UBSan, each
the same as `ren run` with no object alive at the end.

Where it differed from its plan:

- **A dictionary is its type's descriptor,** not a table of functions:
  the derived walks are all a dictionary needs to say, and a type with
  members of its own is the case that would need more (above).
- **Nothing is boxed,** since every value a type variable can stand for
  is a word. Koka's boxing returns if a value bigger than a word ever
  becomes a type's argument.
- **A raise the types say can't happen panics.** A failing call inside
  a function that can't fail, a block whose row's tail is closed there,
  has nowhere to send an error; its `on_error` panics, `an error where
  the types say there's none`, rather than being made impossible.
- **The opaque type's representation is looked through** wherever a
  constructor or `match` needs its declaration, which step 2 did only
  for layouts.

What later steps need to know:

- Each lifted block and handler is an ordinary `Mem.fn`, with
  `[Ptr; Ev; Ptr]` (or a handler's) parameters; Perceus (step 4)
  treats them like any function. Arguments in a block's array are
  owned by the block, and its result is written owned.
- Descriptors and evidence are ordinary parameters: step 5's
  specialization removes them by making a copy per type and per
  installed handler, and the debug build keeps this path.
- `block calls` in the stats counts every indirect call, a
  dependency's operation included, so a program that prints once
  counts two: `$start`'s body and `Console.write`.

### Step 4: Perceus

The counting is placed precisely now, in both builds: a value is
counted again only where it's used again, and dropped as soon as it's
dead; a parameter only read is borrowed, and counted nowhere; and what
dies where one as big is built is reused. Three passes over the Mem IR
to_mem.ml makes, each computing one fact, then Mem Lint:

- **rc.ml, `Rc.prepare`,** puts the naive IR in a shape Perceus can see
  through: every count erased, `Array_set` and `Array_push` made the
  ones that take the array (`Array_set_taking`, `Array_push_taking`),
  and each `match` arm only one test reaches moved to that test, so
  the subject dies where the arm's pattern takes it apart; a pattern's
  variable, set once there, is a `Let` of its field, and the loads
  to_mem.ml made only to drop what a cell held are gone.
- **borrow.ml** decides each parameter's mode, `Mem.fn.modes`, after
  Lean's InferBorrow.lean: every counted parameter of a function only
  the program's own calls reach starts borrowed (`mkInitParamMap`,
  :86), and one the body returns, raises, stores, gives to an owned
  parameter or changes is owned, as is one a field or a view of it is
  given away through; until nothing changes (`infer`, :263). `^name` in
  the printed IR is a borrowed parameter. A function a block, a
  handler or an associated value is made of keeps to_mem.ml's modes,
  since its callers don't know which function they call: a block's
  arguments are owned, and a handler's description and its body's
  descriptor borrowed.
- **rc.ml, `Rc.program`,** places the counting, one function at a time,
  after Koka's Parc.hs and Lean's ExplicitRC.lean. What's counted is a
  group, a variable and those that are only it under another name. A
  group is owned, borrowed, a part (a field of another, borrowed from
  it while that one's alive: Lean's derived borrows), or a view (what a
  mutable variable, a local whose address is taken, or a cell holds
  now, borrowed while that doesn't change; one live where it changes
  is a snapshot, which owns a reference). A use that takes a reference
  takes the group's where the group dies, and counts it again where it
  doesn't (`addIncBefore`); a group that dies at a use that only reads
  it is dropped right after (`addDecIfNeeded`); each branch first drops
  what's dead in it (`addPrologForAlt`, Koka's `parcBranches`, :239);
  and when a group dies, its parts still used are counted first, so
  they own theirs from then on. A drop whose object's fields are still
  used is specialized (Koka's `specializeDrop`, :356): if it's unique
  it's freed (`Free`) without counting the fields, and if not they're
  counted and it's dropped. A use of a cell's array that's filled
  again right after, with nothing between that reads it or calls
  anything, takes it from the cell without counting it, so `p[i] = v`
  through an `&` parameter changes the array in place.
- **reuse.ml** reuses an object that dies where a constructor of as
  many fields is built after it, on the path that goes on (Koka's
  ParcReuse.hs, `ruBranch` :305; Lean's ResetReuse.lean): the
  specialized drop becomes a `Reset` if it's unique, whose memory is a
  token the `Alloc` takes, `alloc ... (at tok =1 =4)` in the printed IR,
  with the slots that hold what they held not written again (Lean's
  ExpandResetReuse.lean). If it isn't unique the token is null and the
  `Alloc` allocates. A token no build takes is freed (`Free_token`)
  where its path ends, or before a loop. A record's update is a
  constructor built where the record dies, and reuses it the same way.

Arrays change in place when they're unique: `Array_set_taking` and
`Array_push_taking` take the array, and copy it only if it's shared
(lean.h, `lean_ensure_exclusive_array`), so `&xs[i] = v` and
`&out.push(x)` on an array nothing else holds allocate nothing. A push
that outgrows its buffer reallocates it, which the stats count as a
`grow`, not an allocation. The runtime's `ren_is_unique`,
`ren_free_keeping`, `ren_reset`, `ren_reuse` and `ren_free_token` are
what `Free`, `Reset` and `Alloc ... at` emit.

**Mem Lint checks the counting,** path by path, in both builds:
every reference a function holds is given away or dropped exactly
once on every path, a borrowed parameter is never dropped, nothing is
read after its last reference is dropped, a part kept by a `Free` or
a `Reset` is a field of what's freed, a cell lent to the function holds
one reference when it ends, and every reuse token is used or freed. It
tracks bundles of references, one per value under all its names; a
cell's value is one reference fewer at any call, since what's called
may change it. Where paths meet, the variables that share a value on
one path are taken together, and hold as many on each.

`ren build --rc naive` keeps step 2's counting, H3's baseline, and
`--emit-mem` prints the counted Mem IR. bench/build.t builds every
program in both, the same as `ren run` under the sanitizers with no
object alive at the end, and checks that rbtree counts fewer times
with Perceus than naive, that fannkuch allocates as many objects for 7
as for 6, and that `map` over an array of 2000 allocates as many as
over 1000. test/test_native.ml shows rbtree's `lookup` borrowing the
tree, its `balance_right` building in the node it took apart, the
prelude's `map` pushing in place, fannkuch's `flip` swapping in place,
and what Lint's check of the counting catches.

Where it differed from its plan:

- **Placement is one backward pass over groups,** not Koka's forward
  pass: liveness is the same analysis, and the groups, parts and views
  are what make the debug build's IR, full of `Let`s that rename,
  precise.
- **Only one level of reuse.** A node taken apart inside one that's
  reused has its fields counted again rather than being reused too,
  as Koka's nested drop specialization would; rbtree's `balance`
  reuses the outer node.
- **A function a block or a handler is made of isn't inferred,** above.

What later steps need to know:

- Modes are `Mem.fn.modes`, decided once by borrow.ml; to_mem.ml makes
  every function's `Owned`, and the naive build keeps them. A call's
  arguments follow its callee's modes, a `Runtime` borrows but what
  `Mem.takes` says, and an `Alloc`'s descriptors are borrowed.
- A `Field` carries its object's size, which reuse needs; `Alloc`'s
  `at` names the token and the slots not written again.
- A copy per type that step 5 makes is an ordinary `Mem.fn`, which
  these passes count as they count any other; the take of a cell's
  array relies on the same `&` rule, that it aliases nothing the callee
  can see, that `restrict` will.

### Step 5: release builds that specialize

`ren build --release` specializes the whole program before memory
lowering, then lays copied records out unboxed and marks `&` parameters
`restrict`. The debug build is unchanged. Everything that follows,
Perceus included, runs on the specialized program as it ran on the
debug one.

**specialize.ml** runs after `Driver.linked`, on the program's Core,
from `$start`. It's a worklist driven by demand, after Roc's
monomorphization: each call of a function reached asks for a copy of
it, keyed by three things the call knows.

- **Its types:** the type arguments, and what each of its rows of
  errors stands for, so a copy has no type variables, its descriptors
  are known and its dictionaries derived from known types. A row of
  what a function uses stays a variable, since it changes nothing a copy
  does. `$start`'s own type variables, ones inference left undecided,
  are `()`.
- **Its blocks:** each block parameter's literal is lifted out to a
  function of its own, `main$1#2`, whose captures are its first
  parameters (Effekt's static-argument transformation): a capture the
  block changes is `inout`, the rest are values. The copy calls it
  directly. A block parameter passed on keeps its key, so a recursive
  function is copied once. A block isn't lifted if the call's other
  arguments as written, a block not lifted or one passed with `&`, may
  use a variable it captures: it's given its captures when the call is
  made, and would miss what the other changes during it.
- **Its evidence's shape:** which dependencies it uses have a handler
  known to be installed, by a `with` around the call whose handler is a
  literal. A known handler's operations are lifted, `counter.next`, its
  state their first parameters, as cells, and a dependency call of one
  becomes a direct call. The handler's state is bound before the
  `with`, which stays, with the handler as a literal, so the
  interpreter still installs it; memory lowering installs nothing for
  it.

A copy is named `f$1`, in its original's module, and records where it
came from (`Core.fn_def.origin`) and which handlers it knows
(`known`). A copy only ever replaces a call to the same code (rule 1),
and the budget is 64 copies of one function (step 9 replaced it with a
size budget for the whole program): past it a call gets the function
as written, the debug strategy, unless a handler it uses is
known, which only a copy can call directly. A handler known inside
another handler's operations isn't specialized, and the call goes
through evidence. `ren build --release --stats` prints what it made:
copies, blocks lifted, handlers known and calls past the budget.

**Core Lint checks it** like any Core, and checks the specializer's own
claims too (`Core_lint.specialized`): a cell parameter only in a
function the specializer made, a direct call of an operation only where
its handler is known at the call's evidence, a callee's known handlers
a subset of its caller's there, no dependency call on a known
dependency but `next`, and a known dependency's `with` installing a
handler literal. test/helpers.ml runs every program of the test suite
both ways, and says so if `ren run --release` prints anything different
from `ren run`.

**Copied records are structs.** Whether a type is copied, read in an
instant rather than counted, is one predicate, copied.ml's
`Copied.is`, which excl.ml and memory lowering both use. In a release
build a copied record or tuple whose fields are all `Int`, `Float`,
`Bool`, `()` or a sum with no payloads is a Mem layout of its own,
`Struct n`: a C struct, passed and returned by value, and stored inline
in an array, whose header's stride says how many slots each element
takes. `Make_struct` builds one and `Struct_get` reads a field. A type
whose value would have to be a word, a generic function's parameter
not specialized, a field of an object or a descriptor's, is boxed
instead: memory lowering raises `Demote` for it and starts again with
that type boxed, so a type is one layout in the whole program. Mem Lint
checks that a struct is never a word, but an array's element. nbody's
bodies are structs, and a step allocates nothing: 12 allocations in all
at the small size, where the debug build makes 65,020.

**`restrict`.** Each `inout` parameter of a function is listed in
`Mem.fn.inout`, and the release build declares it `T *restrict`, which
the exclusivity rule makes true: an `&` parameter aliases nothing the
callee can see. `--no-restrict` leaves it out.

bench/build.t builds every benchmark and example `--release` under
ASan and UBSan, the same as `ren run` and `ren run --release`, with no
object alive at the end. It shows H1's `map`, `reduce`, `each`, fold and
retry wrapper making no indirect call and building no block, each
allocating as many objects as its twin written as a loop; H2's
`Counter.bump` a direct call; the `restrict` prototypes; and the
structs. test/test_specialize.ml shows the Core it makes and what Core
Lint catches.

Where it differed from its plan:

- **Only scalars make a struct.** A copied record with a string or an
  array in it stays boxed, since its fields would need counting.
- **A known handler's `with` stays in Core,** with its handler literal,
  so the interpreter runs specialized Core unchanged; memory lowering
  skips the install.
- **`restrict` is on `inout` parameters only,** not on a known
  handler's state, which is passed as a pointer too.
- **No cache.** Specialization runs on the whole linked program each
  release build.

What step 6 needs to know:

- `ren build --release` is `-O2` on specialized, unboxed, `restrict`
  C; `--no-restrict` and `--rc naive` isolate what each part gives;
  `--stats` prints the specializer's counts at build time and the
  runtime's at exit.
- `ren run --release` and `ren core --release` run and print the
  specialized Core, to tell a specializer bug from a backend one.

### Step 6: the measurements

bench/native/build.sh builds every benchmark `--debug`, `--release
--rc naive` and `--release`, each with and without `--stats`, H5's
three `--no-restrict` too, each kernel of `blocks` and `handlers` as a
program of its own, and the Rust and Go twins. measure.sh times them
with hyperfine, takes peak memory with `/usr/bin/time -l` and the
`--stats` counts, and times `ren build --debug` against `go build` on
gen.py's programs; summarize.py prints the tables in
[bench/native/RESULTS.md](bench/native/RESULTS.md), which holds H1 to
H7 with a verdict for each, and for each failure its cause in the
generated C and its fix.

What the slice showed: blocks and known handlers cost what a loop and a
direct call do once specialized (H1, H2); Perceus counts 12 to 137
times less than naive counting and allocates less (H3, H4); four of
vision.md's seven programs run within 2× of Rust, and rbtree, fannkuch
and nbody don't (H7), for causes in the runtime and in Perceus, not
in the design: an array store is an out-of-line call that checks
uniqueness each time and, for an array of structs, copies the whole
element; rbtree allocates 12 nodes an insertion, since reuse is one
level deep and a token isn't passed into a call that builds; and every
object comes from the system `malloc` with a 16-byte header. `restrict`
changes nothing yet (H5), since those calls hide the buffers it would
be about. Debug builds are slower than `go build` (H6): 77% of the time
is clang -O0, and there's no build cache.

Measuring found two quadratic costs in `ren build`, fixed here:
to_mem.ml numbered each panic site by the length of the list of sites
(`new_site`, now a counter), and `Driver.native` read a module's source
again for each site in it; together they took a 500k-line program's
front half from 76.8 s to 12.3 s, with the same C.

Where the slice as a whole differed from its plan (foundations.md,
Staging, item 2):

- **It isn't naive.** The plan was a naive backend with no
  optimizations; measuring H1 to H5 needed Perceus, reuse,
  specialization, unboxed records and `restrict`, so steps 4 and 5
  built them, and `--rc naive` keeps the baseline.
- **No tcc.** The debug build runs `cc`, clang -O0 here; `REN_CC`
  picks another, but nothing was measured with tcc. (Step 15 builds
  debug builds with tcc.)
- **One process, one C file, no cache.** The driver links the whole
  program and writes one C file, so a one-line edit rebuilds it all.

What later stages need to know:

- The array store's fast path inline, uniqueness hoisted out of loops,
  in-place field stores into an array of structs, and `restrict` on
  buffers are what RESULTS.md says would move nbody, fannkuch and H5;
  nested reuse, a small-object allocator and an 8-byte header move
  rbtree and memory. Each should be measured again with measure.sh.
- Stage 13's backend decides H6: a fast C compiler or a direct
  backend, and a C file per module cached by hash.

### Step 7: arrays in loops

What RESULTS.md said would move nbody, fannkuch and H5, built in four
parts and measured after each (RESULTS.md, H5):

1. **The array's fast paths inline.** `ren_array_get`,
   `ren_array_set_taking` and their twins for arrays of structs are
   `static inline` in ren_rt.h: the index checked with one unsigned
   compare, the array made unique by `ren_array_own` (its count 1, else
   `ren_array_unshare`, out of line), and the element read or written,
   lean.h's `lean_array_uset`. emit_c.ml calls the `_s` ones for
   elements that are never counted and the `_k` ones with a struct's
   stride, which it knows.
2. **A field of an array's struct written in place.** `a[i].f = w`,
   which Core writes `a = set a i (update (get a i) f w)`, lowers to
   `Array_set_field` when `a` and `i` are locals and `w` calls and
   changes nothing (to_mem.ml): an `Array_check` where `get` checked,
   so an index out of bounds panics where it did, then one word of the
   element written. Perceus makes it `Array_set_field_taking`, which
   writes it in place in a unique array, rather than building the
   element again and copying it in.
3. **Uniqueness hoisted out of a loop** (hoist.ml, release builds,
   after Perceus). A loop that uses an array only through views of its
   slot, given straight to an index, a length or a write stored back,
   has it made unique once before it (`Array_own`), its length and
   buffer read then (`Array_len`, `Array_data`), and its elements read
   and written through them inside (`Buf_get`, `Buf_set`,
   `Buf_set_field`, each checking the index against the length). The
   slot is an `inout` parameter's cell, which the exclusivity rule says
   nothing else the function can see reaches, used only by `Load` and
   `Store` and as a call's argument outside the loop; or a local, whose
   address, if it's taken, isn't used in the loop and the loop calls
   nothing. Perceus's count is the number of slots that hold the object
   (a view isn't counted only while nothing changes its slot), so after
   `Array_own` this slot is the only one, and the loop makes no other.
   The length can't change: nothing pushes, and every write stores the
   same object back. hoist.ml says why at more length.
4. **`restrict` on the buffers.** Each array a hoisted loop changes is
   unique, so its buffer is no other array's and no other object; one
   it only reads is never one it changes. emit_c.ml writes a hoisted
   loop as a function of its own, `static inline` and
   `always_inline`, whose parameters are the variables it uses from
   around it, a buffer as a `ren_val* restrict`, a variable it changes
   by its address, and calls it in the loop's place; `--no-restrict`
   leaves the keyword out and changes nothing else, so the two builds
   differ by `restrict` alone. hoist.ml moves a loop only if control
   leaves it by its end or its own `break`, and it puts nothing on the
   stack.

bench/build.t shows the hoisted loops of a program and their
`restrict` parameters, a shared array copied once before the loop that
changes it while the other holder keeps its elements, a loop not
hoisted since it passes `&p` to a call, and an index out of bounds in a
hoisted loop panicking as `ren run` does.

Where it differed from its plan:

- **`restrict` on a local does nothing.** The clang measured ignores
  `restrict` on a pointer declared in a block and keeps it on a
  parameter, also once the function is inlined, as scopes on the loads
  and stores in it; hence the loop as a function of its own. And only
  on the loads and stores in the function when it's inlined: a runtime
  function called from it, not yet inlined itself, gets none, so the
  buffer accesses are macros (ren_rt.h).
- **Division and `sqrt` stay as they were.** They looked like calls in
  inout's and nbody's loops, but the runtime is in the same C file and
  clang inlines them already: made inline by hand, the loops ran the
  same instructions, so that change was taken out again.
- **The length is read before the array is made unique,** from the
  array as it was, which a copy keeps, so clang can see that a loop's
  bound read from the same array is its length and drop that check.

What later stages need to know:

- RESULTS.md's H5 has the numbers and the verdict. What stops these
  loops vectorizing now isn't aliasing: each checked `+` and `*` and
  each index check is a way out of the loop, which the vectorizer of
  the clang measured won't take. Rust's release build doesn't check
  overflow, and its inout loop has no index checks once it's inlined.

### Step 8: the experiments merged

Five experiments on the native backend, each built apart from step 6
and merged after step 7; RESULTS.md's "Combined" section measures them
together. A release build's passes are now: specialize; memory
lowering; Perceus (`Rc.prepare`, borrow.ml, `Rc.program`), then
reuse.ml; **inline.ml**, and Perceus and the rest again on what it
inlined; hoist.ml; Mem Lint. (stack.ml ran between Perceus and reuse
until it was cut: "What was cut", in the runtime model.)

- **Reuse goes deeper** (rc.ml, reuse.ml). A dying object's fields
  whose own fields the program reads are kept by its free and dropped
  with their own specialized drops inside its unique branch, nested
  (Koka's `specializeDrop`, recursing); each object such a tree frees
  is reset to a token of its own if a constructor as big is built
  after it. Of the builds before the path branches, the one with the
  most fields already in place takes the token (Koka's
  ParcReuseSpec.hs, Lean's `isSelfSset`), and only the changed fields
  are written. A token's path may cross a failing call: the call's
  error block frees it first. `ren_reset` is inline, and does nothing
  when it keeps every field that holds an object.
- **inline.ml** inlines a call, one level, only where a reuse token was
  freed unused right after it and the callee builds a constructor of
  that size: simple callees (no loops, catches, blocks, handlers,
  cells or recursion) of Koka's cost of 20 at most. rbtree's
  `balance_left` and `balance_right` go into `ins`, so the node `ins`
  took apart is the node `balance` builds.
- **stack.ml** (H8), since cut (foundations.md, decision 14), kept in
  the frame an object that never outlived the call that built it, and
  gave a function whose result was such an object a second version,
  `f_frame`, that built it in memory its caller gave.
- **`map` in place.** The prelude's `Array.map` writes into its input
  when that's unique and the element layouts match (`map_into`,
  `unsafe_cast`, Lean's `mapMUnsafe`), which hoist.ml then hoists like
  any store loop; otherwise it reserves the length once
  (`array_reserve`).
- **No stack check where recursion can't go** (emit_c.ml,
  `unchecked`): a function that calls, directly, only functions that
  don't check either, through no block or handler, in a chain of at
  most 8.
- **The header is 8 bytes** (ren_rt.h): a 32-bit count, a 16-bit tag
  whose top three values are an array's, a string's and a
  descriptor's, a field count and a byte that masks which of the first
  eight fields hold objects. More than eight fields keep a 64-bit mask
  in a word after them, so 64 fields at most. An array's stride is in
  its body, and the byte says which words of an element hold objects:
  1 for counted words, a struct's mask for structs that hold them
  (the data stage's step 7). A
  negative count is the shared mark: by default it aborts, and under
  `-DREN_RC_SHARED` it's Lean's atomic count (`-DREN_RC_ATOMIC`
  counts everything atomically). bench/native/cores measures those
  modes on several threads.
- **A small-object allocator** (ren_rt.h): free lists by size in
  words up to 64, refilled from 1 MiB chunks, sized frees, nothing
  zeroed; bigger objects and arrays' elements use malloc. It's thread
  local in the threaded counting modes, and `-DREN_SYSTEM_MALLOC`,
  which every AddressSanitizer build sets, sends everything to malloc.

bench/frames.ren (under the sanitizers in build.t) has H8's cases,
which stay as programs after stack.ml's cut: a record of more than
eight fields, one that dies where one as big is built after it, and one
built in a hoisted loop; bench/tokens.ren a token crossing a failing call. Core
Lint checks a specialized module with every module's interface in
scope, since a copy can be at a type its module never imports.

### Step 9: the release build's costs

The release-build experiment found that specialization grows code
linearly, a constant 1.25 times the debug build's C, and shrinks
machine code, but that the release build's front half had four costs
that grew with the square of the program, and that 60% of every
binary was the text of its panics (foundations.md, decision 4 and
Staging, item 2). This step fixes those and takes the cap off
specialization. RESULTS.md, "Release builds", has the numbers.

**The four quadratic costs.**

- **Core Lint after specializing** linted each module seeing every
  module's interface and function, and made those tables again for each
  one: O(modules × functions), 96% of a 500,000-line program's front
  half. `Core_lint.programs` makes what every module shares once, the
  interfaces, each module's dependencies, the program's functions, its
  test functions; each module's own imports, types and functions go on
  top with `Hashtbl.add`, which hides what's there, and come off after
  with `Hashtbl.remove`, which shows it again. Each module sees what it
  saw before, in the order it saw it (core_lint.ml, `lint_module`, says
  why), at the cost of what it adds. Debug builds' lint, under the
  tests, shares the same way.
- **Restarting memory lowering for each type kept boxed.** A copied
  record whose value must be a word is kept boxed, and lowering starts
  again (step 5); one restart a type was 826 restarts at 100,000 lines.
  Now a function that finds one is left unfinished and the rest are
  still compiled, so one pass finds them all, and the program is
  compiled again once. Boxing one type changes no other's layout, since
  a struct's fields are scalars, so a type found in a pass is one the
  program keeps boxed whatever order they're found in; what's compiled
  after the first is thrown away, so a function another left in a
  strange state can only end the pass early.
- **Naming a copy** tried `f$1`, `f$2`, ... until one was free, n tries
  for the nth copy. The search for a name now starts where the last
  ended: a name that's taken stays taken, so the names are the same.
- **The worklist and the table of copies.** Appending to a list for
  each copy is now a `Queue`, first in first out as before; and the
  table, whose `Hashtbl.hash` looked at only the first ten words of a
  key, which its function's path mostly used, so every copy of a
  function was in one bucket, hashes deeper (`Hashtbl.hash_param 256
  1024`).

None of them changes what's made: on every program the old cap didn't
reach, every benchmark and gen.py's programs among them, the Mem is
byte for byte what it was. `REN_PASS_TIMES` (env) prints each pass's
wall time.

**A panic's message in pieces.** The text a panic prints was kept
whole for each site, the line of source and the help, as `ren run`
renders it. diag.ml now renders a diagnostic as pieces (`Diag.piece`):
text, a text many diagnostics share (a file's name, a line of it),
spaces, a run of `^`, a number, a slice of a shared text, and the hole
the message goes in; `Diag.render` is those pieces made text, so there's
one renderer. A site is its pieces as bytes (ren_rt.h, `ren_site`),
each text once in the C, in `ren_text_table`, and the help's operands
are slices of the line they're on; sites whose bytes are the same are
one. `ren_panic` prints the pieces. A panic is a few bytes and the
lines it's on are shared, so `__cstring` goes from 6.5 MB to 0.11 MB at
100,000 lines (base), and debug binaries shrink the same. bench/build.t
compares what each kind of site prints with `ren run`, debug and
release, under the sanitizers.

**Specialization without the cap** (foundations.md, decision 4).

- **No copies-per-function cap.** It was reached at about ten modules
  of ordinary code, its fallback code was bigger than what it saved,
  and its fallback made types boxed program-wide, which made the
  restarts above.
- **A size budget for the whole program.** The copies made may add up
  to 8 times the program's own Core, in expression nodes, and at least
  a million (`Specialize.budget_factor`, `budget_floor`; `REN_SPEC_BUDGET`
  sets it). Past it, a call that would need a new copy, and knows no
  handler, gets the function as written, its arguments boxed: a
  dispatch the program didn't ask for, so `ren build` prints a note
  saying how many calls and where the first ten are, always, not only
  with `--stats`. Measured, specialization grows a program by a
  constant 1.25, so only generic code that makes generic code at new
  types without bound reaches it.
- **Folding** (fold.ml), in release builds, after memory lowering and
  before Perceus: functions whose Mem is the same but for their names,
  the numbers of structs laid out alike, and the sites of panics that
  say the same, are one function, rounds of it until a round folds
  nothing, since a caller folds once its callees have. Struct numbers
  are canonical there, the first struct whose fields are laid out
  alike, so every module's `Tag { code: Int, label: Int }` is one C
  struct. `REN_NO_FOLD` (env) turns it off.
- **Per layout, not per type.** A generic function whose body only
  moves its values is one function for each layout, since its copies
  at two types laid out alike have the same Mem, and fold. One that
  uses `==`, `show`, hashing or anything else that depends on its type
  names its type's descriptor, so its copies differ, and stay one per
  type. bench/build.t shows both.

Where it differed from its plan:

- **Per layout is found after lowering, not keyed before it.** The
  specializer still makes a copy for each type, which Core Lint checks
  at its types, and folding finds the copies that came out the same.
  Keying a copy by its types' layouts in the specializer would make
  Core copies Core Lint can't type, a copy at one type called with
  another's values; that would need Core to say "any type laid out
  so", which it can't. So it saves the binary's size and clang's time,
  not the front half's.
- **The budget's fallback still makes a type boxed program-wide** where
  a struct's value must be a word: generic code given an
  `Array<Tag>` reads its elements as words, which no boxing at the call
  can change without copying the array. It's what the call as written
  needs, and it happens only past the budget.
- **Folding folds nothing in the generated programs.** Every call there
  passes a block literal of its own, and a block is keyed by its
  literal, so no two copies are the same (Rust's closures are each a
  type too). It folds generic code without blocks: containers, `pick`,
  `swap`.

What later steps need to know:

- clang -O2 on one C file is now most of a release build: 92% to 96%
  of it at 100,000 lines (bench/native/RESULTS.md, "Release builds"). A C file per module or partition, compiled in
  parallel and cached, is what's left (decision 13).
- Without the cap, the stress program's C is 1.30 times what it was
  with it, and clang's time grows with it, while its machine code is
  0.63 times what it was, since the cap's fallback was the bigger code.

### Step 10: small values, and packed fields

Decision 14's layouts for what isn't an array: an object's small
scalars share a word, and a small value is no object at all
(foundations.md, decision 14, and Staging, item 2).

**Packed scalar fields** (to_mem.ml, [pack]), in both builds. An
object of a type with no parameters keeps its `Bool`s, `()`s and sums
without fields, a byte each (two or four for an enum of more than 256
or 65,536 constructors), packed into words after its other fields,
the widest first, each in the first word with room: Lean's scalar
fields after the objects (lean.h:592-612, `lean_ctor_get_uint8` and
`ctor_set_uint*`). Only where that saves a word, so a lone `Bool`
keeps its own. rbtree's `Node { color, left, key, value, right }` is four
words, not five, its color and value in one. A type with parameters
keeps a word a field in the order they're declared, since generic code
finds a field where any other does. Mem says it in two operations,
`Pack`, the small scalars into the word an `Alloc` is given, and
`Unpack`, a scalar out of the word a `Field` reads, so every pass that
counts or reuses an object's words sees words, as before; reuse writes
a packed word again where any scalar in it changed. Each declaration
tells the walks where its fields are (ren_rt.h, `ren_ctor_info`'s
`at`, and `ren_ctor_field`), so `show`, `==` and order find a packed
field as Mem does. Mem Lint checks that a packed word holds small
scalars that don't overlap, and that what comes out of one is one.
bench/packed.ren, under the sanitizers in build.t, has a red-black
tree's nodes packed and reused, a record of nine `Bool`s and two enums
in two packed words, changed a field at a time, and each walked by
`show` and `==`.

Measuring it found a leak from step 8: a function's version that
builds its result in its caller's frame (stack.ml) built it in a reuse
token's memory when reuse had given its `Alloc` one, which the caller
then never freed. The frame's version gives the token back and builds
in the frame (emit_c.ml).


**Small values are values** (to_mem.ml, [small]), in release builds.
Step 5's structs held only scalars; now a record or a tuple of at most
four fields, or a sum that isn't recursive with a tag and at most three
slots, is a `Struct` too when each field is a scalar or an object, and
a copied record of scalars still is however many fields it has. A sum
keeps its tag in slot 0 and its constructors' fields in the slots
after, shared between constructors where their layouts are the same,
as Koka's value types share their scan fields (Kind/Repr.hs:150-170);
a slot a constructor has no field in holds a scalar. A sum of two
constructors, one without fields and one with an object, is that
object or a value no object or constructor is, `Scalar_ctor (-1)`
(`ren_box(UINT32_MAX)`), Koka's `DataAsMaybe` (Core/Core.hs:533):
`Option<Str>` is one word. (Since the data stage's step 7, any sum with
one constructor that has fields, one an object, and the rest without
has no tag, its object's slot holding a niche for each of the others,
and any other sum's tag is a byte, its small scalars packed beside it:
"Data stage", "The layout fixes (step 7)".) A type is recursive if its declaration
reaches itself through its fields' types, whatever their arguments,
and is never a small value, as in Koka (Kind/Repr.hs:66); so `List`
stays boxed, and `Option<List>` is a pointer that may be none.

A struct that holds an object is `Struct (n, true)`, counted: `Dup` and
`Drop` of it count each object in it, and `Free` of it drops the slots
it doesn't keep, with no question of uniqueness, since a struct is
always its own (Koka's `genDupDropValue`, Backend/C/FromCore.hs:1048).
Perceus counts it as it does an object: `Make_struct` takes its slots,
as `Alloc` takes its fields; `Struct_get` is a part, borrowed while the
struct lives; and where a struct dies with parts still used, it's
freed keeping them, so `let (s, k) = pick(xs, i)` counts nothing. Mem
Lint checks it the same way, path by path, and that a struct is
counted if and only if a slot holds an object. Reuse never resets a
struct.

A struct is never a field of another, nor a word, nor what a
descriptor describes, nor, if counted, an array's element, whose
elements the runtime counts as words or not at all: a type whose value
would be one is boxed, as before ([Demote]). (Since the data stage's
step 7, a small record or tuple in a small value is flattened into its
slots instead, and an array holds a counted struct inline, counted by
the mask of its slots that hold objects: "Data stage", "The layout
fixes (step 7)".) Boxing one
can make a type that held it a struct, which a later pass of compiling
may box in turn; each boxes types none before did, so it ends. So `==`
and `show` of a small value box its type, and so does an option of an
option, whose inner one is a field. Debug builds don't make small
values: the types stay boxed there, as they were.

bench/values.ren, under the sanitizers in build.t in both builds and
both countings, has an `Option` of a string, a `Result`, a sum of
shared slots built in a loop, a record and a tuple of strings taken
apart, changed a field at a time, through `inout` and by a block that
captures one, an associated value, and each kind boxed; values_panic
panics with them alive. Associated values that are structs drop their
objects at exit, as boxed ones do.

Measured (bench/native/RESULTS.md, "Small values and packed fields"):
rbtree's peak memory 203.2 MB to 169.6 MB, 1.25× Rust's, on 9% fewer
cycles; H8's four kernels allocate nothing without stack.ml's frames,
at the cycles the frames gave them, so the frames add nothing
measurable on top; the rest of the H7 set is unchanged.

### Step 11: arrays of arrays changed in place, and recursion that builds

Two ways a program changes or builds a structure that Perceus alone
left copying or deep in the stack.

**Swap-out** (swap.ml), in Perceus builds. `grid[i][j] = x` reads the
row, counted again, and writes it back changed: the row's count is 2
when it's changed, so `Array_set_taking` copies it, every time. Lean
moves the element out of a unique array instead, leaving a placeholder,
so it's still counted 1 when it's changed (`Array.modify`'s `swapAt`,
and `mapMUnsafe`'s `uset i default`, Init/Data/Array/Basic.lean:774).
Here the pass makes such an `Array_get` an `Array_take` (ren_rt.h,
`ren_array_take`): if the array's count is 1, the element is moved out,
its count unchanged, and a scalar left where it was, which a drop
ignores; if not, it's counted again, as before. It's made only where
the same array is written back at the same index, by an
`Array_set_taking` later in the same block, and nothing between can see
the array: no statement between mentions anything that may be it (its
variables, its slot, a cell of it, a view of a field it's in, a cast of
it), but to name it again; nothing between leaves the block, but a
call's error path that only drops it and returns the error; and a call
comes between only if no variable that may be it has its address
taken, since only through a cell or a reference of its own, which
counts it, could the callee reach it. Then the take moves the element
out exactly when the write changes the array in place: both test the
same count. Tokens, a value's identity that a `Set`, or a call, store or
nested block where its address is taken, renews, say the array and the
index written are the ones read. hoist.ml makes a take in a loop it
hoists a `Buf_take`. Mem Lint checks each take again, after hoisting,
and fails the build if one isn't paired so (`Swap.unpaired`).

Core says `grid[i][j] = v` as `grid = set grid i (set (get grid i) j v)`,
which reads the row before `v`, and `v` often reads the grid
(`grid[i][j] += 1`): the grid is used between the read and the write.
So to_mem.ml lowers a write into an element of an element (or a field
of one, `xs[i].f = w`) whose value only computes (`calm`: locals,
fields, elements, operators) as: the reads' index checks, where Core
reads; the value, into a local; each element on the way read once, into
a local; and the writes back. The value can't call or change anything,
so it gives what it gave, and every panic comes where it did, in the
same order. A `map` over an array of arrays needs nothing new: its
release loop, `out[i] = f(out[i])`, is the pairing.

**Tail recursion modulo cons** (trmc.ml), in Perceus builds. A
function whose recursive call's result is put in a constructor and
returned, `Cons { head: i, tail: build(i + 1, n) }`, runs as a loop instead, which
builds each constructor first, with a scalar in the slot the call's
result goes in, and fills that slot, the hole, on the next turn: Koka's
(Leijen and Lorenzen, POPL'22; Core/CTail.hs, `ctailExpr` :264,
`ctailTryArg` :364, `ctailFoundArg` :436). Koka's context is a value a
program can hold; here only the loop holds it, as in Koka's linear case
(`kk_cctx_apply_linear`, lib/std/core/inline/types-cctx.h:66). Mem has
two new operations for it, `Hole`, a slot's address, and `Fill`, which
takes a value and writes it there. The first turn is a copy of the
body, with names of its own, which makes the first constructor the
root; each later turn fills the hole the turn before left, and a
`Return v` on it fills the last hole with `v` and returns the root. So
the root is held, counted 1, from the first turn on, on every path, and
Perceus and Mem Lint count it as any other variable, with no flag that
says which turn it is. A call whose result is returned as it is
becomes a turn too, once there's a hole (`filter`'s skipped element).
It's sound because the constructors are built before the call's work
instead of after it, which nothing can see: their other fields were
computed before the call, an `Alloc` can't fail, and only the root
reaches them, so the hole is written where no one else looks. A
failure returns the error as the innermost call's would have been
passed on, with the chain built so far dropped by Perceus; so a call
that can fail is taken only if all it does with an error is return it.
A function whose values are words, with an `inout` or cell parameter,
or a call in a loop or a catch, isn't taken; nor is any call but the
last in a constructor: `Node(build(l), k, build(r))` loops down its
right side and recurses down its left. The pass runs after
`Rc.prepare`, before borrow inference, so the loop's variables are
counted, and reused, as anything else is: building the constructor
before the call puts it right after the drop of the cell `scale` takes
apart, and reuse.ml builds it there, which it couldn't with the call
between.

Perceus placed a `Return` in a loop as if the loop's next turn read
what it returns: nothing is alive after a statement that leaves the
function, wherever it is (rc.ml, `place_block`).

bench/swap.ren, swap_panic.ren and swap_order.ren, and trmc.ren and
trmc_panic.ren, run under the sanitizers in build.t, in both builds and
both countings, and print what `ren run` does: rows shared and
unique, `+=`, three deep, through `inout`, a record's field, `map` over
arrays of arrays and of strings, a `map` whose block fails part way, a
generic loop; lists built long, mapped unique and shared, filtered and
appended, a tree, a builder that fails part way, and a panic with the
chain half built. bench/native/nested measures them against Rust and
Go.

Measured (bench/native/RESULTS.md, "Arrays of arrays and recursion
that builds"): `nested`'s release build 13.9 s to 1.10 s, 0.42× the
Rust's time; its grid of writes by index 100 million allocations to
103 and 60× fewer cycles in both builds; `map` over it 1,000,103
allocations to 103 in the release build (the debug build's generic
`map` copies, as before); a list built and scaled by recursion 3.6×
fewer cycles, its peak memory 97.4 MB to 25.5 MB, every cell of
`scale` reused, and a list of 30 million, which overflowed the 1 GiB
stack, built. What it costs: a function taken has its body twice in
the C, and a parameter it walks without consuming is owned by the
loop, counted each turn, where it had been borrowed.

### Step 12: sized storage, and the wrapping operators

`Int8`, `Int16`, `Int32`, `UInt8`, `UInt16`, `UInt32`, `UInt64` and
`Float32` (foundations.md, decision 15; operators.md, "Sized
integers"), through the whole pipeline. sized.ml says what each is: its
name, its range, how a value is made to fit, and what a panic says.

**Types.** A sized type is a type of places, never of computation, and
inference keeps it so with two coercions, recorded on the expression's
node (`Infer.node.coerce`) and nowhere else. `infer` reads: a value
whose type is sized is given its wide type, `Int` or `Float`, where
it's used (`read_wide`). `check` stores: an expression checked against
an expected sized type is inferred, read wide, and stored (`stored`),
which is checked, or wrapped if it's a wrapping operator's result (a
`+%`, `-%` or `*%` at its top, or an `Int.wrapping_*` call), or both
for one sized type stored into another. A literal that doesn't fit is
an error where it's written, and so is a wrapping result stored into a
`UInt64`, whose values stop at `Int`'s largest. A type variable only
becomes sized where a type is written, `Array<UInt8>`, so a generic
function's `T` can be one and its body never computes in it: a `+` on a
`T` needs `add`, which no sized type has. An `inout` place has to be
the parameter's type exactly (`check ~exact:true`), since what's
changed there is kept at its width. Lowering makes each coercion a
Core prim, `Widen`, `Narrow` or `Wrap`, which Core Lint types; compound
assignment, `x +%= v`, reads `x` wide and stores the result back. The
interpreter does what sized.ml says (eval.ml, `stored`).

**Native.** Mem has a layout, `Sized k`, a C type of its width
(`uint8_t`, and `int64_t` for a `UInt64`), and three runtime calls:
`Widen`, `Narrow k`, which panics with the interpreter's message
(ren_rt.h, `ren_narrow_*`), and `Wrap_to k`, a conversion to its
unsigned type and back. A `Float32` is checked against 2^128 - 2^103,
halfway from its largest to the next power of two, before converting,
since converting a `double` outside `float`'s range is undefined in C.

- **An array of a sized type keeps its elements at their width,** as
  Lean's scalar arrays do (`lean_sarray_object`, lean.h:226-232), for
  every sized type: the array's header says which (`nfields`, unused by
  arrays, holds a `REN_ELEM_*` kind), so copying, growing, freeing and
  the walks (`show`, `==`, ordering) size it. Code that knows the
  element type reads and writes it directly (`ren_array_get_u8`,
  `ren_buf_get_n(uint8_t, ...)` in a loop hoist.ml takes). A generic
  function's `T`'s array, a `Word`'s, may be sized: its descriptor says
  (`REN_D_SIZED`), an array it makes takes its kind from there
  (`ren_alloc_array_d`), and it reads and writes through the `_w`
  functions, which ask the array. A sized value as a word is the number
  it holds, so generic code sees an `Int` or a `Float`.
- **An object packs its sized fields,** as it packs `Bool`s (step 10):
  8, 16 or 32 bits each, the widest first, sign-extended or read as a
  `Float32`'s bits when unpacked, and decoded for the walks by
  `ren_ctor_field` through the field's descriptor. A `UInt64` takes a
  word. A release build's small value (step 10) packs the same way: a
  record with no type parameters whose fields are all scalars, its
  `Bool`s and enums too, has its small scalars' words in its struct
  (`packed_struct`), so an `Array<Pixel>` of four `UInt8`s is a word an
  element. Writing one such field of an element in place (step 8's
  `Array_set_field`) builds the element again instead.
- `map`'s in-place path (step 7) is taken from a sized type only to the
  same one, so an `Array<UInt8>` mapped to `Int`s gets a new array.

**Soundness.** Every value stored into a sized place went through
`Narrow` or `Wrap_to` (or is a literal checked at compile time, or a
value read from a place of the same type), so a place never holds what
its type can't: every `Sized k` atom fits `k`. Mem Lint checks it: a
`Narrow` needs a site, a `Wrap_to` none and only into a type
`Sized.wraps`, a `Widen` only of a `Sized`, a packed field's bits are
its width. Hence a narrow C store (`(uint8_t)v.i` in `ren_sized_store`)
never loses anything, and a widen gives back exactly the number stored.
Wrapping at a width is sound to do after `Int`'s 64-bit wrap because
2^w divides 2^64, so the low w bits of the 64-bit result are those of
the exact one. bench/sized.ren and sized_panic.ren run under the
sanitizers in build.t, in both builds and both countings, and print
what `ren run` does; test_sized.ml checks the errors, the panics and
the Mem IR.

Measured (bench/native/RESULTS.md, "Sized storage"): `bytes`, a
million `UInt8`s and a million `Int32`s changed in place and an
FNV-1a hash, against the same program with `Array<Int>`s at 82ed3d1:
release 1.40 s to 0.56 s, 1.30× the Rust's time where it was 3.2×;
peak memory 17.6 MB to 6.6 MB (the Rust's 6.7 MB), the arrays' live
bytes exactly 8× and 2× smaller; the hash 8× faster, its `xor` and
32-bit multiply an instruction each. What it costs: the debug build's
stores call the check, 5% and 9% more cycles on the two in-place
kernels.

Left for later: shifts, and computing in narrow lanes where values are
proven to fit (decision 15's last sentence).

### Step 13: NaN where it's observed, `Float` sums, late overflow

Decision 15's three rules for arithmetic, in the interpreter and both
native builds alike.

**NaN.** nan.ml says it once: what an operation given a NaN gives (its
first operand that's one, chosen here and not by the machine, which may
swap a `+`'s), how a NaN is tagged with where it was made, and what
each panic says. The runtime does the same in C (ren_rt.h, "NaN").

- **Arithmetic carries it, unchecked.** A release build's `Float`
  arithmetic is C's own, `a + b`, so nbody's loops are plain floating
  point; a debug build's, `ren_fadd_d(a, b, tag)`, tags a NaN it makes
  with a number for where it is (emit_c.ml, `tag`), which the panic
  turns back into "made at x.ren:3:9" (`ren_nan_where_table`). A
  release build makes no tags, so its message stops before " made".
- **It's checked where it's observed:** before a `Float` comparison and
  `==` (Mem's `Nan_check`), in the walks of `==`, order and `show`
  (`ren_walk_float`, given what's walking and its site; a `==` or an
  order that ends early, `Some(nan) == None`, looks through both values
  after, the left's first, as walk.ml does), in `show` of a
  `Float` and in `round` and `truncate`, and on each argument of a
  dependency's operation whose type could hold one (Core's `Nan_check`
  prim, put there by lowering, `nan_checked`; a value of a generic
  type is walked by its descriptor, `ren_nan_in`). Hashing is the
  interpreter's, since the native slice has no `Map` or `Set`. A
  `match` needs nothing: there are no `Float` patterns.
- **A panic in the prelude is at the program's call that reached it,**
  as `ren run` says (eval.ml, `call_at`): such a site is a `Caller`
  site, which is the runtime's `ren_here`, set before each call of the
  prelude from the program's code (Mem's `Here_set`) and put back by
  prelude code after a block it called returns. Before, a prelude
  function compiled once was given the first call that reached it as
  its sites' place, so `print` of a NaN, which panics inside `print`,
  said the first `print`'s line wherever it was.

**`Float` sums.** `Array.sum` asks an internal intrinsic,
`float_lanes`, whether its `T` is `Float` (known in a release build,
which then lowers only the arm it takes; a descriptor's in a debug
build), and if it is, `float_sum` adds in the fixed tree: element i
into lane i mod 8, each lane from 0.0, then ((0 + 1) + (2 + 3)) + ((4 +
5) + (6 + 7)). arith.ml's `float_sum` and ren_rt.h's `ren_float_sum`
are the same tree. A release build's has no tag to keep, so it's eight
accumulators, which clang vectorizes (two `fadd.2d` pairs an iteration
on arm64); a debug build's adds with `ren_fadd_d`. build.t's
float_sum.ren sums a generator's arrays of every length to 100 and two
long ones, of numbers of every size and a few infinities, through
`sum` and through a generic function's, and every build prints what
`ren run` prints.

**Late overflow** (late.ml) was built, linted and tested, behind
REN_LATE, and cut (foundations.md, decision 15): in a loop with an
`Int` `+`, `-` or `*`, each kept its first fault and gave the wrapped
result, and a check reported it before every call and way out of the
loop, every 1,024 turns, and before any other panic. Measured, it made
no loop vectorize and the loops it changed slower: inout 18% more
cycles, a running sum of squares 29% more. Clang won't vectorize a loop
with a branch to a call that records the fault, an overflow flag alone
can't say which operation it was or with what operands, and a running
sum's overflow can't be checked in lanes at all. late.ml, its Mem
forms (`Late`, `Late_check`, `Late_tick`) and the runtime's
`ren_late` are gone; its programs stay in build.t, overflowing where
they happen in every build.

**Soundness.** A NaN is never observed unchecked: every observation
point the interpreter checks has its check in Mem (Mem Lint requires a
site on each), and the C arithmetic in between can't observe anything.
Tags only add payload bits a NaN already has room for; a value that
isn't a NaN is never changed. `Float` sums are one tree in all three,
so their bits agree.

Measured (bench/native/RESULTS.md, "NaN where observed, Float sums"):
nbody release 3.99 s to 2.73 s, 31.6% fewer cycles and 55% fewer
instructions, 1.62× the Rust's time where it was 2.37×; inout
unchanged; a million-`Float` `sum` 35× faster.

### Step 14: loops without indices

Decision 16: the loops that don't index don't check bounds, and a
release build checks each loop's length once.

**The forms.** `for i, x in xs` and `for i, x in &xs` give the index
beside the element (parser.ml, `parse_for`; the AST's `For` has an
`index` pattern, a name or `_`). The index is an `Int`, bound before
the element, and can't be assigned (mut.ml, "the loop's index"). A
range's numbers are their own index and a cursor has none, so `for i,
x in 0..n` is a parse error and `for i, x in c` of a cursor a type
error, each with a help saying what to write. `Array.zip` gives a
cursor now, the prelude's opaque `Zip<T, U>`, whose `zip(zs)` gives a
`Zip3`; `Map` and `Set`'s `zip` give one too. A `for` over
`xs.zip(ys)` or `xs.zip(ys).zip(zs)` makes no cursor (lower.ml,
`zip_loop`): it holds each array, counts to the least length, and binds
a pattern of names to the elements directly. The tree-sitter grammar
has the index, with a corpus test and a highlight test.

**What's proved** (bounds.ml). Core's `Get_index` and `Set_index`
carry a `bounds`, `Checked` or `In_bounds` (printed `get` and `get-in`).
Lowering makes each `Checked`; `Bounds.mark` runs on every function
lowering makes and marks `In_bounds` the indices it proves: a count let
to 0 or more, stepped only by `i = i + 1` as the last thing a pass of
`while i < n` does, where `n` is let to an array's length or the least
of several and never assigned, and the arrays keep their lengths over
the loop (no assignment but `a = set a j v`, no `&a`, nothing changed
in a block or handler). Copies `let j = i` and `i - k` of a count let
to at least `k` are proved too. Over the loops lowering writes, that's
every index of `for x in xs`, `for i, x in &xs` and `zip`, and `xs[i]`
in `for i in 0..xs.len()` or a range over another such count (nbody's
`(i + 1)..n`). The proof is of Core's shapes, not of what lowering
meant, so a hand-written `while` gets it as well.

**Another array, by versioning.** `ys[i]` in a loop over `xs` isn't
proved by `xs`'s length. An innermost loop that indexes, at its count,
an array it doesn't change and its bound doesn't cover becomes `if n <=
length ys then (the loop, binders renamed) else (the loop)`: the first
copy has `ys`'s indices proved by the test, the second checks them and
panics where it always did. It's LLVM's LoopVersioning, and the
range-check elimination of HotSpot and LLVM's IRCE (Würthinger et al.,
"Array bounds check elimination in the context of deoptimization",
2009), done on Core where the arrays are values and can't change under
the loop.

**Native.** An `In_bounds` index has no site (to_mem.ml), emit_c passes
`REN_IN_BOUNDS`, and `ren_array_check` and `ren_buf_check` (ren_rt.h)
are nothing for it, so clang sees no exit from the loop but its
condition. Mem Lint still requires a site of every other check.

**Soundness.** `Bounds.verify` runs in Core Lint after lowering and
again after specializing, walking the same facts, and rejects an
`In_bounds` they don't prove ("an index marked in bounds that its loop
doesn't keep so"), so a later pass that moved one out of its loop is
caught; test_loops.ml forges one and checks Lint rejects it. The
interpreter checks every `In_bounds` index anyway and treats one out
of bounds as a compiler bug (eval.ml, `proved`), and every test that
runs a program runs both. The facts are sound because an array changes
only by assignment to its local or `&` to a call (decision 2), both of
which the walk sees and forgets at; a block's changes happen where it's
called, so a local a block changes is never trusted; `i + 1` can't
overflow below a length. build.t's loops.ren, loops_panic.ren and
loops_short.ren check, in every build, the forms' results, a panic
from an index into an array a block changes in the loop, which stays
checked, and one from an array shorter than the one counted, in the
versioned loop's checked copy, each where `ren run` panics.

Measured (bench/native/RESULTS.md, "Follow-ups"): blend, which writes
one `UInt8` array while reading another at the same index, vectorizes
sixteen lanes now, 0.66× the cycles, Rust's time; inout's `b[i]` and
`c[i]`, versioned, 0.90× the cycles, 1.67× Rust where it was 1.86×.
The loops over one array were already Rust's speed, since clang drops
a check against the length the loop counts to; the new forms keep that
without depending on it. Every other program is unchanged. What still
stops a loop vectorizing is an `Int` overflow check, a branch out of
it: a running `Int` sum is 4.45× Rust.

### Step 15: debug builds with tcc

Decision 13: a debug build compiles its C with tcc, in units of
moderate size, in parallel, with no system header in the program's
units and `#line`s, so a debugger steps through Ren
(research/backend.md has the measurements behind it).

**What `ren build` runs** (cc.ml). A debug build's compiler is `$REN_CC`
if it's set (bench/build.t's sanitizer builds set it to `cc`), or tcc,
found as `$REN_TCC` or on PATH, or else `cc` at `-O0`, with a one-line
note that says tools/tcc.sh installs tcc. tcc is LGPL-2.1, a separate
program Ren runs, never linked in. tools/tcc.sh fetches tinycc's mob
branch at the commit research/backend.md measured (e23dabed, which
builds on arm64 macOS as is), builds it, installs it under
`~/.local/share/ren/tcc` and links `~/.local/bin/tcc` to it. Each unit
is compiled to an object by its own process, `$REN_JOBS` at once (one
a core if unset), then linked: by tcc's own linker, since tcc writes
ELF objects even on macOS, which ld64 can't read; a binary clang links
from objects has its debug information left in them, so for clang the
build runs dsymutil, as clang does when it compiles and links at once.
tcc's flags are `-g -w` (it warns of functions that might not return,
which Ren's never do, and never fuses a multiply and add); clang's are
the old `-O0 -g -ffp-contract=off`. A release build is as it was: one
C file, `$REN_CC` or `cc` at `-O2`. `--emit-c` prints one file, as
before, without the `#line`s.

**The units** (emit_c.ml, `units`). ren_rt.h; ren_rt.c, a unit of its
own, which includes the system headers; ren_main.c, the program's data
(its string literals, the texts its sites print, its descriptors and
declarations, its associated values) and `ren_program` and `main`;
ren_uN.c, its functions, a file's together, cut when a unit passes
`max(64 KB, total / (4 · jobs))` bytes of them; and ren_sN.c, its
sites, cut the same way. The sites were most of the data: a 500k-line
program's are 91 of the 92 MB its data unit was, which took tcc 3.4 s
alone, the whole compile, before they had units of their own (0.2 s
after). Functions and data the units share are no longer `static`, and
each unit declares only the names it uses of the others, found by
scanning its text for the `ren_` names the program defines: a
function's prototype, `extern` for the rest. A literal is a struct of
its own size, so it's declared by an incomplete struct of its tag,
which C11 6.2.7 makes the same type as the complete one.

**No system headers.** A unit of the program's code defines `REN_UNIT`
before ren_rt.h, which then includes no system header (they were 6.7
of tcc's 8.1 ms a module's unit took) and declares what it and the
program's code use instead: the fixed-width integer types, from the
compiler's `__INT64_TYPE__`, `__SIZE_TYPE__` and `__UINTPTR_TYPE__`,
their limits, `bool`, `NULL`, `INFINITY`, `isnan` as `x != x` (nothing
is built with `-ffast-math`), and `memcpy`, `malloc`, `realloc`,
`free`, `fabs`, `sqrt` and `fmod`. The two prototypes that take a
`FILE *` aren't declared there; `main` prints what the program gave
through `ren_print_result`, which ren_rt.c defines.

**The overflow builtins.** tcc has no `__builtin_{add,sub,mul}_overflow`,
so ren_rt.h's `ren_*_overflow` are them, or, under `__TINYC__`, tests
in portable C: a sum or a difference overflowed by the operands' and
result's signs (Hacker's Delight, 2-13), a product if dividing it by
`b` doesn't give `a` back, but for `b` of 0 or -1. A check without the
division, a test for operands of 32 bits and four 32-bit products
(Hacker's Delight, 8-2), was measured under tcc on the M4: no faster
on small operands and 1.9 times slower on large ones, since the
division costs nothing next to tcc's code around it. All three were
checked against clang's builtins on 60 million pairs, edge values and
random ones, the same in every result and flag, and clean under UBSan.

**`#line`.** to_mem.ml records the source line each variable a function
defines was made at (Mem's `fn.lines`), while it compiles an expression
of the function's own file; emit_c gives a statement its variable's
line, or its site's, or the line before it. Each function starts with
`#line n "file.ren"`, the absolute path, at the line its name is on.
After `#line n`, C counts on from `n` one a line, so the C of one Ren
line is written as one line of C, and a line whose Ren line isn't the
next gets its own `#line n`. Code without Ren source, the prelude's,
goes first in its unit, before any `#line`, so a debugger shows its C.
Checked with lldb on tcc's binaries and on clang's: `b bench.ren:25`
resolves to `ren_bench_append_safe` at bench.ren:25, `bt` gives each
frame's Ren file and line, `frame variable` its variables (C's names,
`v2_queen`), and `next` steps from line 25 to 26 and round the loop
TRMC made of the recursion.

**Soundness.** The units are the one file's C, split: each function and
datum is defined once, with the type it had, and declared elsewhere
with that type; nothing a unit can't see is assumed. The one `static`
the units each have a copy of is `ren_in_bounds_site`, whose address
says an index was proved in bounds (step 14). A unit compares only
against its own copy; a site passed to ren_rt.c's out-of-line
functions is compared with that unit's copy and doesn't match, so the
index is checked there, and passes: a proof can be lost across units,
never forged, since no site the program computes is any copy's
address. bench/build.t's sanitizer runs now build these units, under
ASan and UBSan, with clang; its last part builds every program again
with tcc, Perceus and naive, 134 builds, and each prints and exits as
`ren run` does, with the same objects alive at the end as clang's
build has.

**Measured.** gen.py's base programs, built clean, three runs at 500k,
five at 100k and ten at 10k, all in one hyperfine run against the
commit before this step, on the M4 (16 cores) shared with a workflow
(load 5 to 20); `go build` with only the standard library cached.
Median wall time in seconds; CPU is user and system time, the
children's included. The front half is `ren build --emit-c`, which
writes one file.

| program | before: front + clang -O0, one file | after: front + tcc, units | after, without tcc: clang -O0, units | front half, before / after | go build | after / Go | CPU s, after / before / Go |
|---|---|---|---|---|---|---|---|
| base 10k | 1.148 | **0.481** | 0.976 | 0.313 / 0.319 | 0.225 | 2.14× | 1.7 / 1.2 / 1.6 |
| base 100k | 10.95 | **3.674** | 5.526 | 2.941 / 3.019 | 2.79 ± 0.43 | 1.32× | 5.7 / 11.0 / 20.0 |
| base 500k | 57.07 | **17.96** | 26.89 | 14.79 / 15.08 | 15.21 | 1.18× | 20.4 / 57.2 / 105.5 |

- **Debug builds are 2.4 to 3.2 times faster,** and the C compiler is
  no longer most of one. At 500k (`REN_PASS_TIMES`): writing the units
  takes 6.6 s, against 5.3 s for the one file before, of which about
  3.7 s is the sites' texts and pieces and the data, there either way,
  0.6 s the `#line`s and the lines found for them, and 0.7 s cutting
  the units and finding what each declares; tcc compiles the 116
  units in 0.22 s; and its linker takes 1.3 s, now the largest part
  after writing C. The front half before C, on one core, is about
  9.4 s of it.
- **Without tcc, units still help:** clang -O0 on 16 cores is 2.1 times
  faster than on one file at 500k, for twice the CPU.
- **H6 still fails, by 1.18 to 2.14 times,** while Ren uses a fifth of
  Go's CPU at 500k. What's left is research/backend.md's list: the
  front half per module in parallel, units cached by content, and a
  link faster than tcc's.
- hyperfine's `cpu_cycles` counts only the process it starts, not its
  children, so it isn't a measure of these builds, which are mostly
  child processes; CPU time is.

What later steps need to know:

- **No cache yet.** Decision 13 caches units by content; every build
  writes and compiles all of them, including ren_rt.c, which is the
  same each time.
- **Writing C is the slowest part of the backend now.** The sites'
  pieces and texts (about 3.7 s at 500k) and the scan for each unit's names
  could be done per module, in parallel, when the front half is.
- **Release builds are one file still,** at clang -O2. research/backend.md
  measured -O2 on 32 partitions at 13 to 16 times faster; it's left for
  when release builds are cached (decision 13), since a partition
  loses clang's inlining across it.
- **cfold still overflows the stack** at its benchmark size in a debug
  build, under tcc as under clang -O0 (research/backend.md, 2): their
  frames are bigger than -O2's.

## Stage 10d

Descriptions (foundations.md, decisions 3 to 7, 13, 15 and 17, and
Staging, item 3), built in the interpreter and natively: `ren run`,
`ren run --release`, and `ren build` debug (tcc or clang) and release
agree on every program's output, and on whether and where it panics.
Seven steps, each green on its own, as 10c's were:

0. **This specification,** and its tests (The tests, below).
1. **Shifts and literals.**
2. **Generic dependencies.**
3. **Descriptions as the only stored code:** a stored description's
   `uses` as an upper bound, inline handlers, handlers called as
   methods.
4. **Dispatch lowered as decision 4 says,** and `--explain-dispatch`.
5. **`over any` and `retry(n, on: Tags)`,** the journal's recorder an
   `over any` handler in Ren. The README's milestone for 10d is this
   step's: `retry(3, on: DbDown)` works for any block, and the recorder
   is Ren.
6. **Blocks with `inout` parameters, and slices.**

Each step takes its feature through the whole pipeline: lexer and
parser, Resolve, inference, Core and Core Lint, the interpreter, Mem IR
and Mem Lint, the C it emits in both builds, the tree-sitter grammar
and its corpus, the Zed queries, the error messages with their help,
and the documents that describe it (operators.md, deps.md, handlers.md,
stdlib.md, the README). What follows settles what each step builds; a
step that finds something here unsound or unworkable says so instead of
building something else.

### The tests

**test/test_descriptions.ml is the specification,** as test_blocks.ml
was 10c's. Each test is tagged `[sN accept]` or `[sN reject]` by the
step that lands it. One still to land runs through `until "sN"`
(test/helpers.ml), which holds its target: `~want`, everything a
program that runs prints, or `~says`, the lines an error or a panic has
to hold, its headline and its help, since where the carets go is the
step's to settle (`~checks:true` adds that the program checks, for a
`types` test, whose lines an error today could echo as source). Its
`[%expect]` holds today's output after `(until sN)`. When the program
prints its target, the test fails, saying the step has landed: **the
step turns it on** by writing it plainly, `run src` in place of `until
"sN" ... (fun () -> run src)`, and promoting, so its `[%expect]` is the
target, the whole message for a `says`. A step leaves no `until` of its
own number behind, and doesn't promote one that's still `until` over a
changed output without reading the change.

**bench/10d/ holds a program or two for each step,** each with a
`.expected` of what `ren run` prints, then `exit N`, then the first line
it writes to stderr, a panic's headline. bench/build.t's last section
runs each through `spec`, which prints `as specified` or `not yet`. The
step that lands one changes its line to `as specified`, and adds it to
the loops above that check native builds against `ren run`: `same`
(debug, Perceus and naive, under the sanitizers), `release`, and
`tcc_same`. Step 4 replaces the `--explain-dispatch` line's output,
today the CLI refusing the flag, with the listing.

| step | expect tests | bench/10d |
|---|---|---|
| 1 | literals; `shl` and `shr`; sized stores; a CRC-32C; panics and errors | bits, bits_panic |
| 2 | two instances; a `with`'s type from its body; aliases with `as`; signatures; requirements; six errors | generic |
| 3 | methods; inline handlers; the router; maps and records; nine errors | shapes, router |
| 4 | (dispatch changes no output) | dispatch, and `--explain-dispatch` |
| 5 | a logger; fault injection; `retry`; `Tags`; ten errors | overany |
| 6 | `inout` blocks; slices; `&` on ranges; `split_at`; `Str` and `Bytes`; panics and errors | slices, slices_panic |

**Existing tests that change,** each by the step named, because what
they pin is what 10d changes:

- step 2: test_deps.ml's "a dependency can't take type parameters"
  (an `ast` test; `dep Box<T>` parses), and its "a handler can't take
  type parameters" (the error becomes test_descriptions.ml's).
- step 3: test_deps.ml's "an operation isn't read from an
  implementation" (`c.now()` is a call; `c.now`, unapplied, stays an
  error, "an operation is called, not read"), "an operation read from a
  value holding a handler of several" (it runs), and the three that
  show the `Needs_more` note, "what an implementation needs is part of
  its type", "an implementation that needs more, inside another type"
  and the one near "`self` is kept where it can't need anything"
  (their note and help become the new ones; they're still errors).
- step 5: every local function named `retry`, which the prelude's now
  takes (test_blocks.ml's two, test_deps.ml's two, with their
  messages); examples/ledger, whose `retry` becomes the prelude's,
  `try retry(3, on: DbDown) fn() => ...`, with its README; the help of
  "`with` installs only handlers", whose `try retry(3) fn() => ...`
  becomes `try retry(3, on: ...) fn() => ...` when the function is the
  prelude's. Every journal test passes unchanged.
- step 6: test_mut.ml's two "blocks can't take inout parameters"
  tests; test_infer.ml's `fn(inout Int)` (written `fn(&Int)`, and its
  messages); test_collections.ml's range help; examples/just and
  test_eval.ml's `.slice(a, b)` (written `[a..b]`); and every printed
  function type with an `inout` parameter, which prints `&T`
  (examples/console.t, testing.md).

**research/paper-programs.md's friction that 10d answers** is in the
tests, named by its label: F2 (a description that needs less where one
that needs more is expected: the router), M3 (blocks with `inout`
parameters, an operation lending one its value), M4 (shifts and hex
literals: the CRC), M6 (slices, and `copy()`), and the routes of
server/api.ren called as methods. What 10d doesn't answer, and where it
goes: F1 and F3 (11a, decided), F4 (an open question), F5 (`try with`,
11a), M1 (`keyed(n, h) over any` needs the key of an operation's first
parameter, which `over any` doesn't expose: 11a's standard library),
M2 (handler-private functions), M5 (type aliases, `type Routes =
Router<...>`), M7 and the papercuts.

### Shifts and literals (step 1)

**Literals.** A number may be written in hex, `0x82F6_3B78`, or binary,
`0b1010`, besides decimal, with underscores anywhere after its first
digit, as decimal allows today (`1_000_000`, `1__0`, `1_`). The prefix
is `0x` or `0b`, in lower case; the digits are `0`-`9` and `a`-`f` or
`A`-`F`, or `0` and `1`. It's an `Int`, never a `Float`: there are no
hex floats. **It's a number, not a pattern of bits,** so it has to fit
an `Int` as a decimal one does: `0xFFFF_FFFF_FFFF_FFFF` is too big, and
`-0x8000_0000_0000_0000` is the smallest `Int`, as `-9223372036854775808`
is. Stored into a sized type it's checked as any literal is (sized.ml).
The lexer reads it into `Token.Int` with its value, so nothing after
lexing knows its base; the formatter, when there is one, keeps the
spelling from the source.

**Shifts** are two methods of `Int`, intrinsics `Int_shl` and `Int_shr`:

- `x.shl(k)` is the low 64 bits of `x` times 2^k, read as an `Int`: the
  bits shifted out are lost, so it never overflows. Stored into a sized
  integer, it wraps at that width instead, by the rule `*%` follows
  (operators.md, "The wrapping operators"): `shl` at the top of what's
  stored is one of the wrapping operations sized.ml lists. So `w =
  w.shl(1)` with `w: UInt32` keeps 32 bits, and stored into a `UInt64`
  it's an error, as a wrapping operator's result is.
- `x.shr(k)` is `x` divided by 2^k, rounded down: arithmetic, so a
  negative number keeps its sign, `(-8).shr(1)` is `-4`. It can't
  overflow, and isn't a wrapping operation: storing it is checked as any
  store. "Logical on unsigned types" needs nothing more: a value read
  from a `UInt8` to `UInt64` is never negative (operators.md, "Sized
  integers"), and on a number that isn't negative the two shifts agree.
- `k` outside 0 to 63 panics, `` `shl` by 64: a shift is by 0 to 63 ``,
  in every build at the call. A literal `k` outside that range is an
  error where it's written.
- Natively, `shl` is a shift of the `uint64_t`, cast back; `shr` is
  C's `>>` of the `int64_t`, which C leaves to the implementation for a
  negative number (C11 6.5.7p5) and clang, GCC and tcc define as
  arithmetic: ren_rt.h asserts it of whichever compiler builds it
  (`_Static_assert(((int64_t)-1 >> 1) == -1, ...)`), so a compiler that
  didn't would refuse the program rather than shift wrongly. (As built:
  the portable `x < 0 ? ~(~x >> k) : x >> k` this specified, clang 16
  compiles to five instructions, not one `asr`.) The range check is one
  unsigned compare, `(uint64_t)k > 63`, gone when `k` is a constant;
  both are `static inline` in ren_rt.h, `ren_shl` and `ren_shr`, given
  the call's site, which Mem has as `Shift` of the intrinsic.

Errors:

```
error: `shl` by 64 always panics
  help: a shift is by 0 to 63; to make 0, write `0`

error: a `shl`'s result can't be stored in a `UInt64`
  = `shl` wraps at `Int`'s 64 bits, and half of what it makes is negative
  = a `UInt64` holds what an `Int` can that isn't negative
  help: keep a 64-bit hash or checksum in an `Int`

error: a hex number needs a digit after `0x`
  help: write its digits, `0xFF`

error: `2` isn't a binary digit
  help: a binary number is written with `0` and `1`, `0b1010`

error: a hex number starts with `0x`, in lower case
  help: write `0xFF`

error: this number is too big to fit in an `Int`
  help: the largest `Int` is `0x7FFF_FFFF_FFFF_FFFF`; for all 64 bits set, write `-1`
```

The last is today's headline, with a help for a hex or binary literal.
The step also rewrites a CRC or hash in bench or the examples that
divides for a shift (bench/10d/bits.ren is one, written new), and
operators.md loses "not built yet".

As built, beside the above: a digit or letter run on into a hex number
is `` `g` isn't a hex digit ``, as binary's is; `0B` is binary's
lower-case error; `0b` and `0x` with no digit, or `0x_1`, need a digit.
A literal `shr` by 64 or more helps with `` `shr(63)` makes 0, or -1
if it's negative ``, and a negative literal amount with `to shift the
other way, use `shr`` (or `shl`). 2^63 written in hex, `0x8000_0000_0000_0000`,
is let through the lexer as decimal's is, for the parser to allow only
after a `-`; anywhere else its error has decimal's help, "the smallest
`Int` is `-9223372036854775808`", since the parser doesn't know the
base. The rewrite is bench/native/bytes: its generator took its high 32
bits as `s / 4294967296`, which rounds toward zero, and now takes
`s.shr(32)`, with its constants in hex (the Rust and Go twins `>>`, and
wide.ren, which has to build with 82ed3d1's compiler, rounds down by
hand, so all four print the same new checksums). Measured, release, the
same: 474.8 ms ± 1.9 before, 474.3 ± 1.3 after, 2.124 and 2.126
billion cycles.

### Generic dependencies (step 2)

**Declaring one.** `dep Chan<T> =` takes type parameters as a type
does; its operations and members can use them. A handler takes type
parameters too, with requirements as a function's do, `handler
seen<T has eq>() for Seen<T>`, and each one has to be a type argument
of a dependency it's `for` or `over`: a description's type is the
dependency's, so a parameter it doesn't name couldn't be known where
the description is used. A member of a generic dependency is called
with its type arguments inferred, `Chan.make()`, as a generic function's
are.

**An alias is a dependency of its own.** `dep Jobs = Chan<Job>` declares
`Jobs`, with `Chan<Job>`'s operations, and nothing else: no type
parameters (an alias names one instance) and no body. It's found by its
own name, so `Jobs` and `Done`, both `Chan<Job>`, are two dependencies
that a `with` installs side by side, and `uses Jobs` doesn't give
`Chan<Job>`. An alias of a dependency that isn't generic is allowed,
`dep Replica = Db`, for the same reason: two of one installed at once.
This is the reading of decision 6 that gives `as` its use, which
research/paper-programs.md's `with snapshot(r.index) as Snap` needs,
since `snapshot(r.index)` already fixes its type: an alias is how two
instances of one type are told apart.

**Found by its full type.** A dependency's identity, wherever a row
holds one, is its path and its type arguments: `Chan<Int>` and
`Chan<Str>` are two labels of a row, and two uses of `Chan<Int>` are
one. An alias's identity is its path. So:

- `uses Chan<Job>` and `uses Jobs` are written as any `uses` is.
- An operation is called through the dependency's name without its
  arguments, `Chan.send(x)`; inference gives the call a fresh instance
  `Chan<α>` and fixes `α` from the call, as a generic function's call
  fixes its type arguments. An alias's operations are called by the
  alias, `Jobs.send(j)`.
- When a function is generalized, an instance whose arguments are still
  open is fixed by the function's declared `uses` if exactly one
  instance of that dependency is there; if several are, it's an error
  that names them; if the function has no declared `uses`, an open
  argument that nothing the function is given fixes is an error too. A
  function's type parameter that only its `uses` names is the same
  error: nothing a caller passes could fix it.
- **A `with`'s item** has the type of a description of `Chan<α>`. If the
  item fixes `α` (`let l: Log<Int> = log()`, `with l`), that's what it
  installs. If not, `α` is unified with the body's one use of `Chan`;
  two uses at different types are an error that says to write the type.
  `with h as A` installs `h` as `A`, an alias of an instance of what `h`
  implements, or that instance written out, `as Chan<Int>`; anything
  else is an error. `as` follows the whole item, so `with h over Jobs
  as Jobs` hasn't a use, and a chain `with a over b as Jobs` installs
  the chain as `Jobs`.
- A `with` is a set of labels, so installing `Chan<Int>` twice in one
  is the existing error, and `Chan<Int>` beside `Chan<Str>` isn't.
- A description's written type can be an alias, `let q: Jobs =
  queue()`, which `with q` installs as `Jobs`.

**How it runs.** Evidence is found by a dependency's identity (deps.md,
"How it runs"), and that now includes type arguments. Where they're
known when compiling, the key is a constant. In a function generic in
`T` that uses `Log<T>`, a debug build and the interpreter build the key
from the descriptor of `T` the function was given (core.ml, `desc`), so
the search compares a path and descriptors; a release build specializes
the function, and the key is a constant again. Core's dependency
references carry their type arguments, and Core Lint checks that every
evidence lookup's label is an instance its function's row holds, and
that a `With` installs the label its item's type says. Module
interfaces keep a dependency's type parameters and an alias's target,
and `ren types` prints them:

```
pub dep Chan<T>
  send: fn(T)
pub dep Jobs = Chan<Job>
pub handler queue<T>() for Chan<T>
```

Errors:

```
error: `send_one` doesn't declare `Chan<Job>`
  help: `Jobs` is a dependency of its own, with `Chan<Job>`'s operations: call `Jobs.send`, or add `uses Chan<Job>`

error: which `Log` `Log.all()` calls isn't known: `Log<Int>` or `Log<Str>`
  help: say what its result is: `let xs: Array<Int> = Log.all()`

error: nothing `peek` is given fixes `T`
  help: make `T` a parameter's or the result's type, or name the dependency at one type: `uses Log<Int>`

error: which `Log` `log()` installs isn't known: the body uses `Log<Int>` and `Log<Str>`
  help: say which, with a written type: `let l: Log<Int> = log()`, then `with l in`

error: `T` isn't a type parameter of `N`
  help: a handler's type parameters are its dependencies': remove `<T>`

error: an alias can't take type parameters
  help: use `Chan<T>` itself where it's generic, or fix the alias's types: `dep Ints = Chan<Int>`

error: `queue()` can't be installed as `Users`
  help: `queue()` implements `Chan<T>`: install it as `Chan<...>` or as an alias of it
```

The step writes an example, a generic dependency installed at two
types (a cache or a pool), beside bench/10d/generic.ren.

It's bench/10d/cache.ren, a `Cache<K, V>` installed as `Cache<Int, Str>`
and `Cache<Str, Int>` at once and as an alias, and bench/10d/aliases.ren
has the rest: an alias of a dependency that isn't generic, a written
alias type, a member, and a generic chain. bench/build.t runs all three
native builds against `ren run`.

Where it differed from its plan:

- **A key carries what it's installed from.** Core's `With` keeps the
  dependency the handler implements beside the one it's installed as,
  and the runtime's key (ren_rt.h, `ren_key`) both numbers, so `with
  queue() as Jobs` installs `queue()`'s `Chan` implementation as `Jobs`.
  A description of one dependency has one implementation, installed
  whatever it was made for, so a `Chan<Job>`'s written as a `Jobs`'s
  needs nothing at run time.
- **An evidence node keeps its type arguments' descriptors,** compared
  structurally (`ren_desc_same`), a pointer first; a dependency that
  isn't generic is found as before. A release build knows a handler
  only when its dependency isn't generic and it's installed as itself;
  a generic one's calls go through evidence, by constant keys.
- **A generic handler's description keeps its type variables'
  descriptors** after what it captures, which its code and the blocks it
  lifts read.
- **A description of an alias unifies with one of what it names,** both
  ways, so `Jobs` and `Done` descriptions are one type.
- **`as` follows one implementation.** A chain installed as an alias,
  `with a over b as Jobs`, is an error that says so: `next` in a generic
  handler finds what's under it by the handler's own dependency, which an
  alias would hide. It's left for when `next` is keyed as its `with`
  installed it.
- **A call at an open instance waits** (Infer_env, `Instance`) until the
  function's other constraints are solved, then is fixed by its declared
  `uses`, by the one instance of that name its row has, or by what it's
  given, else reported.

### Descriptions (step 3)

A handler's description is already a value (deps.md,
"Implementations"): `circle(1.0)` is a `Shape`, and arrays, maps,
records and generic types hold them today. Step 3 makes them the stored
code decision 3 says, in four parts. A description's `show` stays
`<handler>`, and it has no `==` or `hash`, as now: it holds code.

**A stored description's `uses` is an upper bound.** A description
whose handler needs `R` fits wherever its dependency's type is written
with a `uses` that lists at least `R`: `health()`, which needs nothing,
goes in `Router<(Api uses Cache, Db)>`. Inference gets this from
unification alone: the type a description is made with has an open
row, `Api uses R, ..ρ`, at a handler's call and at an inline handler,
so it unifies with any written row that holds `R`, under any type
constructor, and with none that lacks part of it. That's sound because
a description's type says what it may need at most: needing less is
always safe, and every place that installs or calls one provides the
whole row its type says (the slot's, not the handler's). Release
dispatch still knows each handler's exact row, since it knows the
handler. `!`, what a description can fail to start with, stays exact:
decision 3 makes only `uses` a bound. The message for one that needs
more than its slot names what's beyond it, and its help writes the slot
with that added; today's said the opposite of what was happening, and
its help wrote the found type, `(Api)`:

```
error: expected `Api uses Db`, found `Api uses Clock, Db`
  = a stored description's `uses` is the most it may need, and this one needs `Clock` too
  help: add it where the type is written: `Array<(Api uses Clock, Db)>`
```

**Inline handlers.** `handler fn(p, ...) => body` is an expression: a
handler for a dependency with one operation, whose parameters are the
operation's, written as a block's are, with a body that's one line or an
indented block. Which dependency is known only from where it's written:
the type of a `let`, a parameter, a field, an element, a result, an
`if`'s or `match`'s other branches, or a generic slot whose type
argument is fixed. Its parameters take the operation's types, its
result is checked against the operation's, and it fails with at most
the operation's declared errors, as any handler. **What it uses is its
handler's, found where it's installed or called** (rule 5), not where
it's written, so `fn stamper() -> (Stamp uses Clock) = handler fn() =>
Clock.now()` uses nothing, and the description it makes needs `Clock`.
**What it captures is copied,** when the description is made: each local
of the scope it's written in that its body reads, at its value then.
A block sees a `var` change later; an inline handler doesn't. Its
captures are data, as a handler's parameters are: a block, `next`, a
`call` or an instance is an error. It has no state, `finally` or
`next`, so a capture can't be assigned. Lowering lifts it to a handler
declared at the top of its module, named for where it's written
(`main$handler1`), whose parameters are its captures, and the
expression becomes the call that makes its description, so every pass
after lowering, and native code, sees an ordinary handler.

**Handlers called as methods.** `d.op(args)`, where `d` is a
description of `D` (or of several, `A & B`, the operation found as an
arm finds it), is a call of `D.op` with `d` installed for the call: it
means `with d in D.op(args)`, the arguments evaluated first, outside.
So the call needs what `d`'s type says it needs, and fails with what
`D.op` declares. A description whose type can fail to start (`!`) or
goes `over` another isn't called this way: each is an error saying to
install it. For a stateless handler, with no `var`, no `finally` and no
`next` (decision 3), the call makes no instance: it's a direct call of
the arm with the description's data, which is what makes it Ren's `dyn
Trait`, and every build lowers it so. **A handler with state, called as
a method, starts fresh at each call,** its `finally` run when the call
ends, since that's what `with d in` means. Decision 3 names only
stateless handlers; a description's type doesn't say whether its
handler keeps state, so the type can't refuse the others, and this is
their meaning rather than a check that can't be made where the
description is used. (Since the data stage's step 6 that call is
refused, on the linked program: "Data stage", "Descriptions (step 6)".)
A dependency's members and operations never share
a name, so `d.x` is one or the other; an operation read without being
called, `d.op`, stays an error.

**A chain isn't a value.** `a over b` written anywhere but a `with`'s
item is an error; its help says to keep the parts and write the chain
where it's installed.

**How it runs.** The interpreter already has descriptions as values; a
method call installs and calls. A debug build makes a description a tag
and up to three words of what it holds, anything larger, or recursive,
boxed, the tag a pointer to a static record of the handler's functions
and its layout, so a module compiles alone; a method call loads the
arm from it. A release build numbers the tags. Step 3's native dispatch
may be a switch on the tag at every site; step 4 lowers it as decision
4 says. A description held in an array, a map or a record needs a
descriptor today's native lowering lacks (`ren build` on an array of
descriptions stops with "a descriptor of what has none"); step 3 adds
it, a description's descriptor walking what its handler holds.

Errors, besides the upper bound's:

```
error: an inline handler implements a dependency of one operation, and `Users` has 2
  help: declare a handler with an arm for each: `handler name() for Users`

error: which dependency this inline handler implements isn't known here
  help: write the type it's kept as: `let h: D = handler fn(...) => ...`

error: an inline handler's captures are data, and `f` is a block
  help: pass the data it needs, or make the behaviour a dependency

error: an inline handler doesn't go over another, so it has no `next`
  help: declare a handler `over Get` to call the one under it

error: a chain of handlers isn't a value
  help: keep the parts, and write the chain where it's installed: `with cached() over mem() in ...`

error: `s` can fail to start, so it isn't called as a method
  help: install it: `with s in Store.get()`

error: `c` goes over another `Users`, so it isn't called as a method
  help: install it over one: `with c over Users in Users.get(...)`
```

bench/10d/router.ren is research/paper-programs.md's router, and the
tests hold it across three modules, where today's error shows.

bench/10d/methods.ren has what shapes.ren and router.ren leave out: an
inline handler in a generic function and one in a record, a capture
copied before the `var` it read changes, and a handler with state
called as a method. bench/build.t runs all three native builds against
`ren run`.

Where it differed from its plan:

- **The bound is a fresh row at each use, closed where it's kept.** A
  handler's call, and a call of a function that gives a description,
  gives one whose `uses` is open (`Infer_expr.made`), so it unifies with
  any written row that holds it. A row nothing else names is closed
  when its group is done (`Types.close_free_needs`), and a function's
  result row that appears nowhere else in its type is closed when it's
  generalized (`Types.close_result_needs`), so `fn fixed(n: Int) -> N`
  prints as written and each call opens it again. Core Lint checks a
  call's result against its callee's, the description it gets needing
  at most what the callee's says.
- **An inline handler is lowered where it's written,** a Core `Handler`
  with no state and one arm, capturing what it reads as a block does,
  rather than lifted to a `main$handler1`: every pass after lowering
  already sees a `Handler` node as a handler, and natively it's one
  with its own record and tag. Lifting it, with the hidden type and
  dictionary parameters of the function it's in, is left to step 4,
  whose listing names it.
- **A description is always boxed,** its tag first, then what its
  handler captured and its type variables' descriptors: no three words
  inline yet, which is step 4's layout. Its descriptor is `D_handler`
  (`REN_D_HANDLER`), an object nothing shows but as `<handler>`,
  compares or looks into for a NaN.
- **A method call looks the arm up in the record, in both builds.** A
  debug build's tag points at the handler's record (ren_rt.h,
  `ren_handler`), a release build's indexes the program's table of them,
  and a stateless handler's record has a method for each operation, a
  block's code given the description first (`To_mem.method_code`). A
  method call takes the method if its record has one and installs the
  handler for the call if not (`To_mem.method_call`): stateless means no
  `var`, no state at all, no `finally`, no `next`, and not generic,
  since a generic one's code needs its descriptors installed. A `with`
  written as `with d in D.op(x)`, its arguments locals, is the same
  call, and runs the same way. Measured against the commit before, in
  release builds of 20 million calls through an array of three
  handlers' descriptions: 96.3 ms and 375M cycles before, 61.0 ms and
  237M after, all stateless; with one of the three keeping state, 29.5
  ms to 20.5 ms (5 million calls); with all three keeping state, which
  is installed as before, 31.1 ms to 32.5 ms, 119M cycles to 124M, the
  record's indirection and the test for a method.

### Dispatch (step 4)

Release builds lower every dispatch over descriptions as decision 4
says, and `ren build --release --explain-dispatch D file.ren` lists
each site. A **site** is a method call on a description, an operation
call inside a `with` that installs one whose handler isn't known, or
an arm's call through a description it holds. How many handlers reach
it is the number of handlers `for` or `over` its dependency in the
whole program (an analysis that narrows them is optional and release
only), and decides the lowering:

- **One:** a direct call, which clang may inline, and the description
  has no tag.
- **Two to four:** the arms inline, as compare-and-branch on the tag,
  not a jump table.
- **More than four:** a call through a static table of the set's arms,
  indexed by the tag. For a dependency with one operation, the tag is
  the arm's code pointer, and the call goes through it.
- **Recursion through its own dependency** (an arm of `D` calling a
  description of `D`, as an expression tree's `eval` does) calls
  through the table, never one switch function holding every arm.
- **Cloned per handler:** a `with`'s body, or a loop whose description
  doesn't change in it, when four or fewer handlers reach it and the
  copy fits a budget; never across a suspension (none exists before
  11a). The budget is foundations.md's open question: the step picks
  one, a number of Mem IR nodes per copy, and states it.
- **Layout:** release sizes a description to its dependency's largest
  handler, up to eight words, before boxing anything; debug keeps a tag
  and three words.

The listing, one block per dependency named:

```
$ ren build --release --explain-dispatch Shape dispatch.ren
Shape: 6 handlers (sq_shape dispatch.ren:41, rect :43, tri :45, ring :47, frame :49, main$handler1 :65), 1 operation (area)
  description: tag = code pointer (one operation), 3 words inline; nothing boxed
  dispatch.ren:75  main(): s.area()  6 handlers reach → table call  [more than 4]
```

Each line is a site, how many handlers reach it, the lowering, and why;
a clone says what it copied and its size. Nothing is left out. The step
ports research/dispatch.md's kernels into bench/native with their Rust
(`dyn` and enum) and Go twins, and measures against them, cycles and
time, against the commit before it.

bench/10d/dispatch.ren and dispatch_mix.ren hold a site of each
lowering, and dispatch_panic.ren a panic inside a copied loop;
bench/build.t runs all three native builds of each against `ren run`
and holds the listing of every dependency in them.

How it's built (lib/native/dispatch.ml, clone.ml):

- **Each method call is a site** (`Mem.Method_of`, with its dependency,
  operation and a number into the program's `dsites`), and an install
  through a description's record is one too (`Call_handler`'s `hsite`).
  Which handlers reach it is every handler implementing its dependency
  (`handler.hdeps`, from the handler's type), so the analysis is the
  closed set, nothing narrower; specialize.ml already makes a call on a
  handler known where it's written direct, before any of this.
- **The lowering is chosen in emit_c.ml from the set,** release only:
  one stateless handler, a direct call `f(NULL, ev, args, out)`; two to
  four, a chain of `tag == k ? f_k(...) : ...`, the last unconditional;
  more, `ren_mtab_<dep>_<op>[tag](...)`, a static table of each
  handler's method, or, for a dependency of one operation whose handlers
  are all stateless and implement only it, `((ren_code)tag)(...)`, the
  tag being the method's address (`with` finds its record back by
  `ren_handler_by_code`). A site in an arm of its own dependency calls
  through the table, as the specification says. A handler with state has
  no method; a site it reaches tests for one first (`Has_code`, a
  compare, or `tab[tag] != NULL`) and installs if not, as step 3 did.
  `Dispatch.prune` folds that test where the set decides it, so a call
  no stateful handler reaches has no install path left to count.
- **Loops are copied per handler** (clone.ml) before Perceus, when two to
  four handlers reach the loop's sites on one description no statement
  of the function changes: `if (tag == k1) { copy, known k1 } else if
  ... else { copy, known the last }`. Each copy's sites are marked
  `known`, so each is one direct call clang inlines. Mem Lint checks that
  every `known` site is under a `Tag_is` test of its description, that
  says it's that handler or none of the others, and that the description
  never changes. The budget is 200 Mem statements a copy (`clone_budget`):
  every loop bench/10d and bench/native has fits under 40, and 200 keeps
  a function at most four times a loop of a fair size; a loop over it is
  listed as not copied.
- **A method borrows its description and its arguments** (`Arg_borrowed`,
  and `Call_block.borrowed`): the caller keeps them alive across the call,
  as Rust's `&self` does, so a call in a loop does no dup and no drop of
  the description. A method that keeps one, in a field or a result, dups
  it there (rc.ml, `borrowed_def`).

Measured same-run against 678bbf7, release, on an M-series Mac, hyperfine
10 runs each (ms) and `/usr/bin/time -l`'s cycles, beside the Rust (`dyn`
and enum) and Go twins (bench/native/dispatch, measure.sh's `time`):

| kernel | before | after | Rust dyn | Rust enum | Go | cycles 10⁶, before / after |
|---|---|---|---|---|---|---|
| shapes2 | 49.1 | **30.2** | 29.5 | 19.3 | 33.4 | 188 / 117 |
| shapes4 | 62.8 | **38.2** | 38.4 | 28.2 | 43.5 | 239 / 149 |
| shapes8 | 70.1 | **46.4** | 42.4 | 40.7 | 48.7 | 271 / 178 |
| shapes32 | 74.5 | **50.4** | 45.0 | 48.6 | 53.0 | 291 / 195 |
| db | 230.9 | **87.3** | 84.3 | 57.1 | 125.5 | 906 / 346 |
| router | 81.6 | **56.6** | 56.2 | 62.4 | 64.8 | 317 / 221 |
| interp | 127.3 | **60.2** | 39.4 | 60.0 | 57.5 | 496 / 237 |

Every kernel is 1.3 to 2.6 times faster, within 1.12× of Rust's `dyn`
but interp (1.53×), and ahead of Go in all but interp (1.05×). What's left is counting:
`for x in xs` dups and drops each element it reads (an element read of a
borrowed array not counted is later work), and the checked arithmetic
Rust's release build doesn't do. Rust's enum wins the small sets, where
it inlines the match into the loop and Ren still has a description
boxed. The other benchmarks are unchanged (handlers, blocks, rbtree,
deriv, nbody, stack: within 1%).

Where it differed from its plan:

- **No layout change: a description is still boxed,** a tag and then
  what its handler holds, in both builds. The listing says how many words
  its largest handler holds, which is what the layout would size it to.
  Inline descriptions need every place that holds one (records, arrays,
  closures, the descriptor walk) to know their size, and they wait for a
  step that changes value layout.
- **A one-handler description keeps its tag word,** never read in
  release, for the same reason.
- **A `with`'s body isn't copied per handler,** only loops are; a site
  in a `with` installs through the record, and the listing says so.
- **fnp, the tag as code pointer, is used only over four handlers,**
  where the call would go through a table, and only when every handler
  of the dependency is stateless and implements only it, so the tag is
  free to be its one method's address.
- **Methods borrow their arguments,** a calling convention this step
  chose: db with the description's dup and drop taken out of its C by
  hand had gone from 733M cycles to 336M, which is what decided it.
- **The listing differs from the example above** in its description line
  (`tag = the handler's number ...; boxed, the tag then N words at most`)
  and in naming each copied loop with its size.

### `over any` and `retry` (step 5)

**`over any`.** `handler name(params) over any uses ... =` goes over any
one dependency: its state, as any handler's, then one arm, `call =>
body`, which runs for every operation of what it's installed over,
whatever its name binds. In the arm:

- `call.forward()` calls the operation under this one with the same
  arguments. Its value is the operation's result, and it fails with the
  operation's declared errors, so it's written with `try` or `attempt`.
  It's called **once at most** on any path through the arm: not in a
  loop, not in a block, and in each branch at most once.
- `call.fail(t)` fails the operation with the tag `t`, as `fail t`
  does, without `try`. Every operation of what the handler is installed
  over has to declare `t`, with its shape: that's checked at each `with`
  that installs it, since only there is the dependency known.
- `call.name` is the operation's dependency and name as the journal
  writes them, `"Users.get"`, a `Str`.
- `call.args` is the arguments; what `call.forward()` gives is the
  result. **Both are opaque:** inside the arm their types are type
  parameters of the arm, one per operation, so they can be shown, compared
  with `==`, and passed to generic functions, the journal's intrinsics
  among them, and nothing else; no pattern takes them apart. This is
  foundations' `call.result`: the value `call.forward()` gives, or
  `attempt call.forward()`'s `Result` of it. `show(call.args)` writes
  the arguments as a call does, in parentheses, `("b", 3)`, `()` for
  none, so `call.name + show(call.args)` is the journal's call.
- `call` is only used through, as `next` is: it can't be kept, passed
  or returned. `next` isn't there: `call.forward()` is.
- The arm's value is the operation's result, and it fails with at most
  the operation's errors. The handler's own `uses` are its own, met
  where it's installed.

It's installed with `over`, as any handler that goes over another is,
`with logged() over mem_users()` or `over Users`; without one it's
today's error. It installs the one dependency it's over, and counts
once in its `with`'s set.

**What the compiler derives per dependency.** Inference checks the arm
once, for an operation in general: the result and arguments as skolems,
the errors as a closed row it can't name. Each `with` that installs it
over `D` checks `call.fail`'s tags against each of `D`'s operations.
Everything that depends on the operation is derived from its signature:
its name, the descriptors of its arguments' tuple and its result (for
`show`, `==` and the journal), and its declared errors. The interpreter
gives the arm a call value holding those and a closure that forwards.
A debug build compiles the arm once, given a call record: the name,
the descriptors, a pointer to the arguments, and the forward function
with its environment. A release build specializes the arm per
dependency and operation it's installed over, so `call.args` is the
arguments, `call.forward()` a direct call, and it's static dispatch
like any other handler.

**The recorder is Ren.** prelude.ml's six `recording_*` handlers become
one, `handler recorder(j: Journal) over any`, which the runtime installs
over each built-in dependency `main` uses, as it installs those now;
journals stay byte for byte as they are, and every journal test passes
unchanged. The journal writes an operation that can't fail as its value
and one that can as its `Ok` or `Err`, as now: what decides it is the
operation's declared errors, which the derived encoding has.
`replaying` stays a handler `for` the six, since it answers in place of
them rather than going over them. If the recorder can't be finished
soundly, the step says exactly what's missing.

**Tags, and `retry`.** A parameter of type `Tags`, a prelude type, takes
a set of error tags. At a call it's written with its name, `on: DbDown |
Timeout`: tag names, without payloads (`on: Short` for `Short(name:
Str)`), or the name of an error set, `on: TransferError`. It's the only
parameter passed by name. Inside the function it isn't a value: it's
matched, `fail on => ...`, an arm that takes an error whose tag is in
it, binding nothing, with a guard if wanted; and passed on, `on: on`. A
`match` with such an arm handles nothing it can name, so it's a `try
match`. **At each call, every tag it's given has to be one the call can
fail with,** after inference: the block's errors, for `retry`, whose
errors are its block's. One the call can't fail with, or one a row only
a type variable holds, is an error. The interpreter gives it as a list
of tag names; a debug build as a static array of them; a release build
specializes the function per set. The prelude's `retry`:

```ren
// runs `body`, and again while it fails with one of `on`'s errors, up
// to `n` tries in all: any other error leaves at once, after the last
// try its error leaves, and `body` runs at least once
pub fn retry<T>(n: Int, on: Tags, body: fn() -> T) -> T =
  try match body()
    fail on if n > 1 => try retry(n - 1, on: on, body)
    v => v
```

Errors:

```
error: `retry` takes `on:`, the errors it tries again
  help: name them: `retry(3, on: Broken | Flaky)`

error: `retry` is given `on: Timeout`, and the block can't fail with `Timeout`
  help: name what it can fail with: `Broken`, `Flaky`

error: `on`, the errors `retry` tries again, is written with its name
  help: write `on: Flaky`

error: `n` isn't passed by name
  help: a name goes only before a parameter of `Tags`: write `3`

error: `down_every(2)` can fail with `Down`, which `Users.get` and `Users.count` don't declare
  help: install it over a dependency whose every operation can fail with `Down`, or write a handler `over Users`

error: `call.forward()` runs the operation under this one, so it's called once at most
  help: keep what it gave: `let r = attempt call.forward()`, and `try r` where it's needed

error: `call` can only be used through
  help: use `call.forward()`, `call.fail(e)`, `call.name` or `call.args` where they're needed

error: `call.args` can only be shown, compared and recorded
  help: write a handler `over` the dependency to read its arguments

error: `quiet()` goes over another implementation, so it's installed with `over`
  help: say what it goes over: `quiet() over Users` for the one installed outside this `with`, or another implementation after `over`
```

The first lists what the block can fail with, sorted. Fault injection
that targets some operations, or `keyed(n, h) over any` (11a), which
needs an operation's first parameter's key, are handlers `over D` until
something exposes more than this.

Where it differed from its plan:

- **Every build specializes, the interpreter's too.** Lowering makes a
  handler `over any` a function per dependency it's installed over,
  `logged$Users`, with the arm copied per operation, `call.args` the
  arguments' tuple and `call.forward()` a call through `next`'s
  evidence; and a function with parameters of `Tags` a function per set
  of tags it's given, `retry$DbDown`, whose `fail on` arm tests the
  error's tag against them (Core's `Tag_in`). Neither is lowered as
  written. Each use asks for what it needs, and the driver makes it in
  the module that declares the function, once, and what that asks for in
  turn (lower.ml, `request`; driver.ml, `link`); the recorder's six are
  always made. So there's no call record, no list of tag names at
  runtime, and no debug build that compiles the arm once: the
  interpreter and both native builds run the same Core. A debug build's
  code grows with the dependencies each `over any` handler goes over,
  which the plan's call record would have saved.
- **`call.args` of one argument is a tuple of one,** `(_)`, so it shows
  as a call does, `(5)`; the journal writes it as it did, without the
  parentheses, and writes what an operation that can't fail gave as its
  value, though the recorder keeps it as `attempt` does, an `Ok`.
- **An operation that takes a block can't be gone over by `any`.**
  `call.args` would hold the block in a tuple, which Core Lint refuses
  and native code has no descriptor for, so the `with` that installs a
  handler `over any` over such a dependency is an error, found in the
  stage-10d review (infer_handlers.ml, `any_links`); a handler `over D`
  is written instead.
- **`==` on `call.args` or on what `call.forward()` gives is checked
  where it's installed,** against each operation's arguments and result,
  since lowering derives it from them: one that gives a description,
  which has no `==`, is an error at the `with`. Over a generic
  dependency it's an error too, not built yet: the function made for
  `Box` would need `==` of its `T`, which nothing passes it. Only a
  handler of the module doing the installing is checked so; an imported
  one that compares isn't, and still stops lowering (review, open).
- **`Tags` is only the type of a named function's parameter,** not a
  handler's, and `fail on` is an arm's whole pattern, never beside
  another in `|`.
- **A named row is passed on as a parameter's is** where errors are
  added up (solve.ml, `include_`), so `attempt call.forward()` keeps
  the operation's errors; before, only a parameter's row was.
- **The native slice took two of `Time`'s limits off,** to run
  10d/overany.ren natively: a `key` that's the value itself orders as
  the representation does, and an operator of a type's own only stops a
  dictionary for that operator, not a descriptor; and a release build
  shows an opaque type laid out as its representation with its name,
  `Time(0)`, as the debug build always did.

### Blocks with `inout` parameters, and slices (step 6)

**Blocks with `inout` parameters.** A block's parameter that it changes
is written `&x`, `fn(&lo, &hi) => ...`, and a function type writes one
`&T`, `fn(&Array<T>, &Array<T>) -> R`: the form a call writes. That
replaces `fn(inout T)` in a function type, which is an error with a
fix-it, and so is `fn(inout x) =>`; a named function's parameters keep
`inout x: T`. Printed types change to match. A block's parameter modes
have to be its expected type's, as they do now; it's called as any
function with `inout` parameters is, `f(&a, &b)`, and a `let` of one is
called the same. Exclusivity doesn't change: a block's parameters are
variables, places of their own, so a block changes them freely, and
what it captures is checked as every block's captures are. Natively a
block's `inout` parameter is passed as a function's is.

**Slices.** `e[a..b]`, where `e` is an `Array<T>`, a `Str` or `Bytes`,
is the elements, or bytes, from `a` up to, but not including, `b`, of
the same type: a range is now written after a `for`'s `in` and inside
an index, and nowhere else. It panics, at the same point in every build:

- `slice 2 to 5 is out of bounds for an array of length 3` (`for a
  string of length`, `for bytes of length`), when `a < 0` or `b` is past
  the end;
- `slice 3 to 1 ends before it starts`;
- for a `Str`, `slice 0 to 2 starts inside a character` or `ends inside
  a character`, today's `Str.slice` messages. `Bytes` never checks.

`Str.slice(a, b)` goes, an error whose help writes `s[a..b]`. `split`
and `trim` return slices of what they're given, at boundaries they
found, so they don't check. `xs.copy()`, on each of the three, is a
value equal to `xs` that holds its own buffer, and costs nothing on one
that already does. A slice is a value like any other: it's compared,
shown, stored and returned as its type is, and nothing can tell a slice
from a copy, but its cost.

**`&` on a range.** `f(&xs[a..b])` passes the range as an `inout`
argument: a write of `xs` for the call, as `&xs[i]` is. What the callee
leaves in its parameter replaces the range, so a callee that pushes
lengthens `xs` there: `grow(&zs[0..2])` with `zs = [1, 4, 6, 4, 5]`
makes `[1, 4, 0, 6, 4, 5]`. `for x in &xs[a..b]` changes that range in
place. Two ranges of one array in one call overlap as two indices do,
so `f(&xs[0..2], &xs[2..4])` is today's error, with a help that splits
it. Assigning to a range, `xs[a..b] = ys`, is an error, "a range of an
array is changed through `&`", whose help is a call or a loop.

**`split_at`.** `&xs.split_at(n) fn(&lo, &hi) => ...`, on `Array`,
`Bytes` and `Str`, gives a block the two halves, `xs[0..n]` and
`xs[n..len]`, each a place of its own, and its result is the block's.
When the block returns, or fails, `xs` is `lo` followed by `hi`, so a
half that grew moves what follows. `n` outside 0 to the length panics,
`` `split_at` 5 is out of bounds for an array of length 3 ``; on a
`Str`, an `n` inside a character panics as a slice does. The block
can't touch `xs`: the call writes it, and a block passed to the same
call reading it is today's error. Its signature, on `Array<T>`:

```ren
pub fn split_at<R>(inout self, n: Int, body: fn(&Array<T>, &Array<T>) -> R) -> R
```

**What a slice is** (decision 17). A seamless slice, Roc's: a root, the
counted owner of the buffer, and a range. An owner is a slice of all of
its root. A slice of a slice has the first one's root. Writing to a
slice, or to an owner that isn't unique, copies the range first; so
`ren_array_own`'s test becomes "unique and an owner". Whether it's two
words (a root, a 32-bit offset and length, with a fallback past 4 GiB)
or three is the step's choice, by measurement, and it says which and
why. Counting:

- **A slice of a parameter the function borrows, that doesn't leave the
  call, doesn't count its root:** it's a part of its root, as a field
  read is, counted only if the root is consumed while it lives. That's
  sound because the borrowed parameter outlives the call and the slice
  dies in it; Mem Lint learns the state, and checks it (The runtime
  model, below, gains the rule).
- **Any other slice counts its root once,** and is a small value
  (decision 14), kept inline in records and arrays.
- **`split_at` changes the halves in place:** it makes `xs` unique and
  an owner once, lends the halves as slices flagged lent, which are
  written in place since nothing else can reach `xs` for the call, and
  on return splices back only a half that's no longer the same lent
  slice. A lent slice is the one slice written in place.
- The interpreter copies (`String.sub`, `Array.sub`): value semantics
  make the two indistinguishable, so its output is the specification.

The step ports research/slices.md's benchmarks (logs, json, pages) with
their Rust twins into bench/native and measures them, retention
included; a debug report of roots kept alive by small slices is
optional. stdlib.md and the README say `split` and `trim` return
slices.

Errors:

```
error: a block's parameter that it changes is written `&n`
  help: write `fn(&n) => ...`

error: `xs` is passed with `&` twice in this call
  = an argument passed with `&` has to be the only way the call can reach that value
  = `xs[0..2]` and `xs[2..4]` may overlap
  help: to change two parts of one array, split it: `&xs.split_at(2) fn(&lo, &hi) => ...`

error: `Str` has no method named `slice`
  help: slice it: `s[0..2]`

error: a range, `a..b`, is written only after a `for`'s `in`, or in an index: it isn't a value
  help: a range is for counting, `for i in 0..n`, and for slicing, `xs[a..b]`
```

Where it differed from its plan:

- **A slice is an object, not a small value.** The runtime's `ren_array`
  and `ren_str` (which `Bytes` is too) gained a `data` pointer and a
  `root`: an owner's `root` is NULL and its `data` its own buffer or
  bytes; a slice is a header of its own whose `data` points into its
  root's, counting the root (ren_rt.h; research/slices.md's
  representation A, Roc's seamless slices at list.zig:574-591 with a
  pointer where Roc steals a bit). Every reader already went through
  `data`, so none changed but a string's, one load more. The plan's
  two- or three-word value kept inline isn't built: `Str` and `Array`
  are one word everywhere, in fields, array elements, a type variable's
  words and descriptors, and decision 14's small values are, as built
  in step 10, release-only and never a field, a counted element or a
  word. Making them three words is a representation change across the
  backend, not this step's; RESULTS.md, "Slices", prices what it would
  save. For the same reason a slice of a borrowed parameter still counts
  its root: without a frame for the header (stack.ml went in decision
  14), not counting it would leave a header that outlives the call
  holding a root nothing counts.
- **Writes check `ren_array_writable`,** unique and an owner or a lent
  slice, and growth `ren_array_unique`, unique and an owner, since a
  lent half's next elements are its neighbour's. `ren_array_take` asks
  the first, as the write it pairs with does. Both read only `cap`: an
  owner's is at least 1, a slice's 0 and a lent slice's -1, since
  reading `root` on every push made blocks' `map` 14% slower in
  cycles.
- **`split_at` lends through a vacant place.** Core reads the place,
  writes `Vacant` there (a scalar natively, the value itself in the
  interpreter: nothing reads it, since the call writes the place), and
  cuts the halves: `ren_array_before` lends its half, `cap` -1, if what
  it's cut from is writable, and `ren_array_after` its own if the first
  was. A slice of a lent slice ends its lending, and so does the join;
  so a lent slice is the only way to its range, and is written in place
  when its count is 1. The join gives back the root itself when the
  halves are still next to each other in it, cover it and are all that
  hold it, a lent slice of the two when they're next to each other in a
  part of it (a split inside a split), and otherwise a new owner: a half
  that's been replaced copies both, not only itself. A quicksort by
  `split_at` over 200,000 `Int`s allocates headers only, its peak the
  array's 1.6 MB.
- **`&xs[a..b]` copies.** The callee gets a slice, which its first write
  copies, and the range is spliced back into a new owner: O(n) of `xs`,
  where `split_at` is O(1).
- **A block's `inout` argument is its cell's address in the block's
  argument words,** which the code reads as the cell it is (to_mem.ml,
  `lambda`); a block given to a block is passed the same way, by its
  address, since a block outlives no call it's given to, which took the
  native slice's old "a block passed to a block" limit off (10d/slices.ren's
  handler arm takes one). A block's `inout` parameter of a type
  variable's type isn't native yet, as a function's isn't.
- **`split` and `trim` return slices natively** (`ren_str_split`,
  `ren_str_trim`), and `Bytes` is native: its layout is a string's, its
  descriptor `REN_D_BYTES`, `==` compares bytes, and `show` writes each
  in hex as the interpreter does.
- **No debug report of roots kept by small slices** (the plan's
  optional part). RESULTS.md measures retention instead.

### Where 10d may differ from foundations.md

Choices this specification made where the record is silent, each to
revisit if a step finds it wrong:

- **An alias is nominal** (decision 6): `dep Jobs = Chan<Job>` is a
  dependency of its own, so two instances of one type can be installed
  at once, which is what `as` is for.
- **A handler with state can be called as a method** (decision 3 names
  stateless ones), starting fresh each call, since a description's type
  doesn't say whether its handler keeps state.
- **`call.result` is the value `call.forward()` gives** (decision 7),
  and `call.name` is added, the operation's name, which the recorder
  needs and which says nothing about arguments or results.
- **`call.fail(t)` is checked per installation** against every
  operation of the dependency, since the arm is checked once for all
  of them.
- **`on:` is a parameter of a new prelude type, `Tags`,** passed by
  name, matched with `fail on`: the one named argument in the language,
  and the one way to write `retry` in Ren.
- **`retry`'s `n` below 1 tries once.**
- **`!` stays exact** where `uses` becomes an upper bound.
- **A function type's `inout` parameter is written `&T`,** replacing
  `inout T` there, as the brief's `fn(&Array<T>, &Array<T>) -> R` says.

## Stage 11a

Tasks (foundations.md, decisions 2 to 11, and Staging, item 4): rules B
to D; structured tasks with `Async.scope(max:)`, `spawn` and its
handle; `until`, `tick`, `yield`, `timeout`, `race`, `isolate`, `map`,
`each` and `both`; handler operations that don't interleave; `try
with`; the runtime as a handler, `Async.single()` and
`sim.scheduler(seed)`; the tape, poll points, task paths and journal
version 2; the standard library's channel, semaphore, `Batcher`,
`keyed` and `limit`; and `Net`, a thin TCP layer, with `sim.net`.
Tasks run in the interpreter, `ren run` and `ren test`, on OCaml 5's
effects; the sequential parts build natively too, and agree with `ren
run`. Ten steps, each green on its own, as 10c's and 10d's were:

0. **This specification,** and its tests (The tests, below), with
   async.md rewritten to match foundations.md and the README's stale
   race passage fixed.
1. **Rules B to D, `try with`, and the two holes in the spec,** with
   what the checker needs of the surface: `Async`'s declarations,
   parameters with defaults, a block given without parentheses, and
   `concurrent` and `spawned` parameters.
2. **`Async.scope(max:)`, `spawn` and its handle, `s.replace(key)`,**
   cancellation at dependency calls, the cleanup deadline, siblings
   cancelled by a failure, and task paths in errors and panics.
3. **The rest of `Async`:** `until`, `tick`, `yield`, `timeout`, `race`,
   `isolate`, `map`, `each` and `both`.
4. **Operations that don't interleave.**
5. **`single` and `sim` as handlers,** virtual time, `ren test --seeds`
   and `--seed`.
6. **Journal version 2.**
7. **`Net` and `sim.net`,** and the server that shuts down gracefully.
8. **The standard library,** then the five programs, the milestone, and
   the `just` running recipes at once.
9. **A review** of the whole stage: soundness, the spec, the docs and
   tooling.

Each step takes its feature through the whole pipeline: lexer and
parser, Resolve, inference, Core and Core Lint, the interpreter, Mem IR
and the C it emits where the feature is sequential, the tree-sitter
grammar and its corpus, the Zed queries, the error messages with their
help, and the documents that describe it (async.md, handlers.md,
deps.md, testing.md, runtime-io.md, the README). What follows settles
what each step builds; a step that finds something here unsound or
unworkable says so instead of building something else, and records
what it chose in "Where 11a may differ from foundations.md", below.

### The tests

**test/test_tasks.ml is the specification,** as test_descriptions.ml
was 10d's, with the same `until "sN"` (test/helpers.ml): a test still to
land holds its target, `~want` for a program that runs or `~says` for
the lines an error or a panic must hold, and its `[%expect]` holds
today's output after `(until sN)`. When the program prints its target
the test fails, saying the step has landed, and **the step turns it
on**: written plainly, `run src` or `check_error src`, its `[%expect]`
the target, the whole message for a `says`. Each error message below is
one such refusal test, a headline and its help, but two: the native
build's is bench/build.t's, and a version 1 journal's is
bench/tasks.t's. A step leaves no
`until` of its own number behind.

Programs that run under `ren run` are written against `single`'s
order (Scheduling, below), which is fixed, so their output is too.
Programs that run as tests (`test`, in helpers.ml) are written so that
what they assert holds under every schedule, since `ren test` runs
them under `sim` with a seed.

**bench/11a/tasks/ holds the five programs of async.md, the `just`'s
concurrent part, and the milestone,** one folder each, each a program
with its tests and an `expected` file of what `ren test` prints there
(with `REN_NO_TIMINGS=1`) and how it exits. bench/tasks.t runs `ren
test` in each through `spec`, which prints `as specified` or `not yet`
(as bench/build.t's does for bench/10d). **The step that lands one
moves its folder to examples/** (`git mv bench/11a/tasks/server
examples/server`), where THE CHECKS run `ren test` in every folder from
then on, changes its line in tasks.t to the new path and `as
specified`, and adds it to tasks.t's loop that runs `ren test --seeds
1000` there. They wait outside examples/ because THE CHECKS run `ren
test` in every folder under it, and `ren test` in a folder reads the
folders under it too, so a program that doesn't parse yet would fail
them; `lost_update` and `journal` stay in bench/11a/tasks, since their
tests are meant to fail.

| folder | what | lands in |
|---|---|---|
| `server` | the server that shuts down gracefully, with `sim.net` | 7; landed |
| `crawler` | the crawler, its `Seen` set and `limit` over its `Web` | 8; landed |
| `just` | `run_all`, independent recipes at once, a failure killing the rest | 8; folded into examples/just |
| `transfer` | a transfer under a timeout, commit in `finally` | 5 (needs virtual time: see "Step 3, as built"); landed |
| `refresh` | prices refreshed by a task beside the `with` | 8; landed in 5, since it needed only virtual time |
| `lost_update` | the milestone: a lost update between two operations, found by `--seeds` and replayed by `--seed`; and the README's `cached`, which can't race any more | 8; holds since 5 |
| `journal` | a version 1 journal, recorded before 11a, which `ren replay` refuses with a help | 6; landed |

`lost_update`'s first test fails on purpose under some seeds, so it has
no `expected`: bench/tasks.t's `milestone` runs `ren test --sim --seeds 200`
there, which has to fail it and print a seed; runs `--seed` with that
seed, which has to fail it again with the same `left:` and `right:`;
and runs `fixed.ren`'s test, the same account with one operation,
`add`, and `cached.ren`'s, the README's `cached`, under `--seeds 1000`,
which have to pass. It prints `the milestone holds` once all of that
is so.

**bench/11a/ holds the sequential programs** that build natively, each
with a `.expected` as bench/10d's (what `ren run` prints, `exit N`, the
first line of stderr), and bench/build.t's last section runs them
through `spec`. The step that lands one says `as specified` and adds it
to `same`, `release` and `tcc_same`:

| program | what | lands in |
|---|---|---|
| `trywith` | `try with`, a transaction's setup and commit failing; it runs already, since `try` already takes a `with`, so step 1 refuses a plain one and adds it to the native loops | 1 |
| `alone` | `Async.until` that holds, `yield` and `tick`, with no other task | 3 |
| `alone_panic` | `Async.until` that doesn't hold, with no other task: the deadlock panic | 3 |
| `limit` | `sync.semaphore` and `sync.limit()` over a dependency, with one task; and `limit_panic`, the standard library's panic | 8 |
| `spawns` | a program that spawns: `ren run` runs it in `single`'s order; `ren build` refuses it (its own line in build.t) | 2 |

**Existing tests that change,** each by the step named:

- step 1: test_deps.ml's and test_infer.ml's lists of "the
  dependencies in scope", which gain nothing but lose `Async` from the
  undeclared ones (it's declared now); examples/ledger's `with
  sql.transaction() over Sql in`, which becomes `try with`, with its
  README and handlers.md's example; any test whose `with` can fail,
  which gains `try`.
- step 2: every `finally` whose `match r` names each error, which gains
  a `Cancelled` arm or a `_` (its `r` can be `Err(Cancelled)` now).
- step 5: deps.md's table of test defaults (the test `Clock` is
  `sim.clock()`); testing.md's `--seed`.
- step 6: examples/just/tests/build.journal, re-recorded as version 2;
  every journal test's expected journal text (test_journal.ml,
  examples/journal.t, examples/just.t), which gains the task column.
- step 7: test_blocks.ml's four `dep Net`s, which become `dep Web` (a
  program can't declare the prelude's `Net`), and test_deps.ml's
  "nothing can implement `Net` yet" errors, whose help changes.

### The surface

Everything 11a adds a program can name, as the prelude declares it.
Step 1 declares it all, so the checker can check programs that use it
(rules B to D are about these parameters); each intrinsic not built yet
panics, `` `Async.scope` isn't built yet: stage 11a, step 2 ``, which
its step removes. The functions are members of `Async`, written in the
prelude in Ren over intrinsics, as `Fs.read_str` is over `Fs.read`:

```ren
pub dep Async =
  // let every other task that can run, run first
  yield: fn()
  // return once every task that could run when it was called has run
  // until it waits: the batching point
  tick: fn()

  // runs `body` with a scope its tasks are spawned into, and returns
  // once they've all ended; `spawn` waits while `max` of them run
  pub fn scope<T>(max: Int = 64, body: fn(s: Scope) -> T) -> T uses Async
  // waits until `cond` holds: only in an operation, whose instance it
  // lets go of meanwhile
  pub fn until(cond: fn() -> Bool) uses Async
  // `body`, or `Timeout` if it's still running after `d`
  pub fn timeout<T>(d: Duration, body: fn() -> T) -> T ! Timeout uses Async
  // whichever of `a` and `b` finishes first; the other is cancelled
  pub fn race<T>(a: concurrent fn() -> T, b: concurrent fn() -> T) -> T uses Async
  // `body`, or `Panicked` if it panicked
  pub fn isolate<T>(body: fn() -> T) -> T ! Panicked(msg: Str) uses Async
  // `f` of each element, `max` at once, the results in order
  pub fn map<T, U>(xs: Array<T>, max: Int = 64, f: concurrent fn(x: T) -> U) -> Array<U> uses Async
  // `f` of each element, `max` at once
  pub fn each<T>(xs: Array<T>, max: Int = 64, f: concurrent fn(x: T)) uses Async
  // `a` and `b` at once
  pub fn both<A, B>(a: concurrent fn() -> A, b: concurrent fn() -> B) -> (A, B) uses Async
  // the runtime on one thread, in real time, with real I/O
  pub fn single() -> Async = single_runtime()

// what `Async.scope` gives its body (rule D: it's passed and called,
// never kept)
pub type Scope = builtin
  // starts `body` as a task of this scope, waiting first while `max`
  // of its tasks run
  fn spawn(self, body: spawned fn()) uses Async
  // the same, giving the task's handle, to join it or cancel it
  fn start<T>(self, body: spawned fn() -> T) -> Task<T> uses Async
  // `spawn`, after cancelling the task this scope started under `key`,
  // if it's still running, and waiting for it to stop
  fn replace<K has hash>(self, key: K, body: spawned fn()) uses Async

// a task's handle (rule D, as `Scope`)
pub type Task<T> = builtin
  // waits for the task to end: what it gave, or `None` if it was
  // cancelled first
  fn join(self) -> Option<T> uses Async
  // asks the task to stop, and returns at once: it stops at its next
  // dependency call, or now, if it's waiting
  fn cancel(self) uses Async
```

The blocks' errors and dependencies are transparent, as `retry`'s are:
`scope`, `timeout`, `isolate`, `map`, `each` and `both` fail with what
their blocks fail with, after cancelling the rest, and use what they
use. Two are closed: a spawned block can't fail, and `race`'s branches
can't; `until`'s condition can't fail and uses nothing (The checker,
below). `Timeout` and `Panicked(msg: Str)` are tags like any other;
`Cancelled` is the one a program can't fail with ("Cancellation",
below).

**Parameters with defaults** (step 1). A function's parameter may end
in `= literal`, an `Int`, `Float`, `Bool` or `Str` literal, or a
negative number: `max: Int = 64`. Those with defaults come after those
without but before a trailing block parameter, and **a parameter with
a default is given by name or left out**, so a call reads the same
either way: `Async.map(xs) fn(x) => ...`, `Async.map(xs, max: 8) fn(x)
=> ...`. Positional arguments fill the parameters without defaults, in order,
and a trailing block the last. A call fills each one left out with its
literal, in Lower;
Core and the interpreter never see a default. A function used as a
value, `let f = g`, has every parameter in its type, so a call through
it gives them all. `on:` stays the one parameter of `Tags`. The
interface keeps each default, so another module's call can leave it
out. Errors:

```
error: `max` has a default, so it's given by name
  help: write `max: 8`

error: a parameter's default is a literal: a number, a `Bool` or a string
  help: give it where it's called instead

error: a parameter with a default comes after those without
  help: move `max` after `xs`

error: `scope` has no parameter named `limit`
  help: its parameters given by name: `max`
```

**A block without parentheses** (step 1). A call whose arguments are
one block may leave out its parentheses, `Async.scope fn(s) => ...` and
`s.spawn fn() => handle(conn)`, as foundations.md writes them: in the
grammar, `postfix := postfix lambda`, where the `fn` is on the same line
as what it follows. Today that's "expected the end of the line, found
`fn`", so nothing that parsed changes.

**`concurrent` and `spawned`** (step 1) mark a block parameter's mode,
written before its `fn`: `f: concurrent fn(T) -> U` may run on several
tasks at once, and `body: spawned fn() -> T` runs as a task until its
scope ends. They're contextual: a word there and nowhere else, so
neither is reserved. A mode is part of the parameter, `Ty.param`'s new
`block : Ty.block_mode` (`Ordinary | Concurrent | Spawned`), kept in
schemes and interfaces and printed by `ren types`; it's written only on
a parameter of a named function, an operation or a method, whose type
is a function's, and anywhere else it's an error: "`concurrent` marks
a block parameter of a function" with "help: remove it". Unification
ignores modes; Excl reads them.

**`Net`** (step 7), in the prelude:

```ren
pub type Addr = { host: Str, port: Int }
// a socket listening, and a connection, as the runtime numbers them
pub type Listener = opaque Int
pub type Conn = opaque Int
// a signal the program is sent
pub type Signal = opaque Int
  pub let term: Signal = 15
  pub let interrupt: Signal = 2
pub type NetError = ! Refused(addr: Addr) | InUse(addr: Addr) | Closed | NetFailed(reason: Str)

pub dep Net =
  listen: fn(addr: Addr) -> Listener ! NetError
  accept: fn(l: Listener) -> Conn ! NetError
  // a connection, or `None` once `stop` has been sent to this program
  accept_until: fn(l: Listener, stop: Signal) -> Option<Conn> ! NetError
  // up to `max` bytes, as soon as there are some; none once the other
  // side has closed
  read: fn(c: Conn, max: Int) -> Bytes ! NetError
  write: fn(c: Conn, b: Bytes) ! NetError
  close: fn(c: Conn)
```

No HTTP, DNS or TLS, and no network that fails: the rest of the
simulator comes later. `Signal.term` is SIGTERM's number.

**Two standard-library modules,** built into the compiler as the
prelude is (lib/core/stdlib.ml, each a `source` in Ren), are found by
`import sim` and `import sync`, never from a file: a program's own
module named `sim` or `sync` is an error, "`sim` is the standard
library's", as its own `dep Clock` is. They can call the prelude's
runtime intrinsics, which other modules can't (Prelude's `caller`).

- **`sim`** (steps 5 and 7): `sim.scheduler(seed: Int) -> Async`, the
  deterministic runtime; `sim.clock() -> Clock & TestClock`, in the
  scheduler's virtual time; `sim.net() -> Net & SimNet`, in memory,
  whose `dep SimNet` has `connect: fn(addr: Addr) -> Conn ! NetError`,
  a client's end, which waits while nothing has listened on `addr` yet
  and is `Refused` once its listener has closed, and
  `signal: fn(s: Signal)`, sent to the program; and `sim.proc(runs:
  Array<Run>) -> Proc & TestProc & SimProc`, programs that take time,
  with `type Run = { command: Command, code: Int, takes: Duration }`
  (a command `runs` doesn't name exits with 0 at once, as `test_proc`'s
  does) and `dep SimProc = killed: fn() -> Array<Command>`, the
  commands cancelled while they ran.
- **`sync`** (step 8), in Ren, each over `Async.until`:
  - `dep Chan<T>` with `send: fn(x: T)`, which waits while it's full,
    `recv: fn() -> Option<T>`, which waits while it's empty and open,
    `None` once it's closed and empty, and `close: fn()`; `handler
    channel<T>(cap: Int) for Chan<T>`;
  - `dep Semaphore` with `acquire: fn()` and `release: fn()`; `handler
    semaphore(n: Int) for Semaphore`;
  - `limit()`, `over any` and `uses Semaphore`: each call takes a
    permit, is forwarded, and gives it back, in a `finally`, so `with
    sync.semaphore(16), sync.limit() over Web in` makes at most 16
    calls to `Web` at once ("Where 11a may differ", below, says why
    it's two items);
  - `dep Batcher<K, V>` with `get: fn(k: K) -> V`, `asked: fn()` (step
    8 added it: "Step 8, as built") and `flush: fn()`;
    `handler batcher<K has hash, V>() for Batcher<K, V> uses Fetch<K,
    V>`, over `dep Fetch<K, V> = fetch: fn(keys: Array<K>) -> Map<K,
    V>`: `get` adds its key and waits until a `flush` has fetched it,
    and a task spawned beside the `with` waits in `Batcher.asked()`,
    then calls `Batcher.flush()` after an `Async.tick()`;
  - `keyed<T>(n: Int, h: T) -> T`, `n` instances of the handler `h`
    describes, each operation sent to one by its first argument's key
    (its `key` member, or the value itself), one with no parameters to
    every instance in turn (built in, below).

### The checker (step 1)

**Rule B: a block parameter's mode is part of its type.** Excl (excl.ml)
already knows, at each call, which arguments are blocks; it now reads
each parameter's mode from the callee's scheme (Ordinary unless
written). Passing a block parameter `f` of the function being checked:

- to a `concurrent` parameter needs `f` to be `concurrent`, and to a
  `spawned` one needs it to be `spawned`: a spawned block runs until
  its scope ends and a concurrent one only during the call, so neither
  stands for the other;
- to an ordinary parameter needs nothing: an ordinary parameter only
  calls it, during the call.

A `pub` function's modes are as written. A private function's are
inferred by Excl, once per module before it checks bodies: each
private function's block parameter takes the strongest mode of the
parameters it's passed to, `Spawned` over `Concurrent` over
`Ordinary`, to a fixpoint over the module's private functions (modes
only go up, and there are three, so it ends). `ren types` prints the
inferred ones. Errors:

```
error: `f` runs on several tasks at once in `Async.map`, but `fan_out` doesn't say it can
  = a block that runs on several tasks at once can only read what it captures
  help: mark the parameter: `f: concurrent fn(Int) -> Int`

error: `body` is spawned as a task here, but `start` doesn't say it can be
  = a spawned block runs until its scope ends, and can only read what it captures
  help: mark the parameter: `body: spawned fn()`

error: `f` is concurrent, so it can't be spawned
  help: mark the parameter `spawned` instead
```

**Accesses** (foundations.md, decision 2's table), in Excl:

- a block passed to a `concurrent` parameter reads each place it
  captures, for the call; a write in it is an error;
- a block passed to a `spawned` parameter reads each place it captures
  by reference (rule C) **until the `Async.scope` call that made the
  scope ends**: a later write in the scope's body, after the spawn, is
  decision 2's error; places it captures by copy aren't accessed after
  the spawn at all;
- blocks passed to one call don't conflict with each other, unless one
  goes to a concurrent or spawned parameter: then each is checked
  against the others' accesses as if they were separate calls;
- `Async.until`'s condition reads what it captures but conflicts with
  nothing in its own arm: it's evaluated only while the instance is
  free (Scheduling), which is what the arm's write of the whole state
  for the `until` call would otherwise forbid.

```
error: `n` can't change while a spawned task reads it
   │ s.spawn fn() => log(n)
   │                     - read until `Async.scope` ends
   │ n += 1
   │ ^^^^^^
   help: copy it for the task, `let m = n`, or change it after the scope

error: `total` can't change in a block that runs on several tasks at once
  help: give back what each one makes, and add them up after: `Async.map(xs) fn(x) => ...`, then `.sum()`

error: a spawned task can't change `seen`, which it only reads
  help: change it through a handler's operation, or give it back: `t.join()` has what the task returned
```

**Rule C: a spawned block captures by reference only the variables of
the frame that calls `Async.scope`.** That frame is the function, or
block, whose code has the `Async.scope` call whose scope is spawned
into, found syntactically: the spawn is `s.spawn` where `s` is the
scope block's parameter, and the variables bound outside that scope's
block, in its caller, are the frame's. Everything else the spawned
block captures is copied when it's spawned: variables bound inside the
scope's block (a loop's variable, a `let` in the body), and, when `s`
is a parameter of a helper (`fn start(s: Scope, ...)`), all of the
helper's locals and parameters. Lower makes the copies (step 2): a
spawn's block becomes `let c' = c in` the spawn, for each copied
capture `c`, and the block captures `c'`. Excl treats a copy as a read
of `c` at the spawn, an instant. A `spawned` block parameter passed on
to `s.spawn` is captured as it is.

**Rule D: a scope and a task's handle are blocks too.** `Scope` and
`Task<T>` are second-class, as blocks are since 10c step 3, and
Infer's same check after inference refuses them where a block is
refused: in a record, a tuple, an array or any type argument
(`Option<Task<Int>>`), a handler's parameter or state, a `var`, a
function's or a block's result, a dependency operation's parameter.
They may be a function's parameter, captured by a block, and the value
of a `let` given a call (`let t = s.start ...`). `s.spawn` gives `()`,
so a server's `s.spawn fn() => handle(conn)` is a statement with no
handle to drop; `s.start` gives one, for a task to join or cancel. Core Lint checks the same: no `Scope` or
`Task` in a constructor, a record, a tuple, an array, a function's
result or a handler's state.

```
error: a task's handle can't be returned: it's only good inside its scope
  help: return what the task makes: `t.join()`

error: a record can't hold a scope
  = a scope lives only as long as its `Async.scope` call
  help: pass it to the functions that spawn into it

error: `Task<Int>` can't be a type argument: a task's handle is only good inside its scope
  help: keep what the tasks make instead: `Async.map` gives every result, in order
```

**A spawned task can't fail.** `spawn`'s block parameter has a closed,
empty error row, and Infer_msg words the mismatch (async.md's group
error, renamed):

```
error: a spawned task can't fail, or one task's failure would stop all the others
  ┌─ server.ren:7:15
  │
7 │       s.spawn fn() => try handle(conn)
  │                       ^^^^^^^^^^^^^^^^ can fail with BadRequest | DbDown
  │
  = help: handle them in the task: `match attempt handle(conn)`
```

`race`'s branches likewise:

```
error: a branch of `race` can't fail, or a failure could leave the race waiting on the other
  help: make the failure a value inside it: `attempt fetch(a)`; to try again until one succeeds, use `retry`
```

**`try with`.** A `with` whose items' setup or `finally` can fail is
marked as a call that can fail is (errors.md, "Marking"): `try with`,
`attempt with` or `with` as a `match`'s subject with `fail` arms.
Infer makes each `with` whose installation can fail an `ecall` of its
own, its errors those of its items' setup and those their `finally`s
add beyond the body's (a `finally` is checked with the body's errors as
a skolem, so `try r` adds none of its own), and the
marker in front of it covers only that: **calls in the body still need
their own markers**, since a reader looks for `try` at each place the
code can stop, and the body's calls are such places. The body's errors
pass out of the `with` as before. The parser needs nothing (`try` and
`attempt` already take a `with`); the tree-sitter grammar's `try`
already does too, and the corpus gains a case. Lower and Core are
unchanged, and so is the native build: `try with` only says what was
already so. Errors, the headline as an unmarked call's:

```
error: installing `transaction()` can fail, and nothing handles it
  ┌─ main.ren:9:3
9 │   with sql.transaction() over Sql in
  │   ^^^^ it can fail with `DbDown`
  help: write `try with`, or handle its errors with `match`

error: nothing here can fail
  = `try` marks the calls that can fail, so a reader can see where the code can stop
  help: installing these can't fail: remove the `try`
```

**The two holes.**

- **`s.spawn` carries `Async` in its caller's row:** its scheme says
  `uses Async` (it waits while the scope is full), as every method of
  `Scope` and `Task` does, so a helper that spawns lists `Async`, and a
  private one has it inferred. Nothing else is needed; the message is
  the ordinary one for a `uses` a signature leaves out, with a note,
  "`s.spawn` waits while its scope is full, so it uses `Async`".
- **No code reached from a call with an empty row runs a scheduling
  point.** A task can switch (Scheduling, below) only at a call of an
  `Async` operation or member, which needs `Async` in the row; in the
  operation of an instance that a spawned task can reach, which is
  installed outside the call, so its dependency is in the row; or in
  the world's waits, `Clock.sleep`, `Net`'s and `Proc.run`, reached
  only through the world's dependencies, which only the runtime
  installs. The handlers that wait and that a program can install,
  `sim.clock()`, `sim.net()`, `sim.proc` and `sync`'s, use `Async` in their
  type, so installing one needs it. What's left is a runtime installed
  inside such a call, which is a closed world: it's a panic if any
  other task is running then ("Runtimes", below). Core Lint checks the
  static half: each intrinsic that can wait (Intrinsic's new `waits`)
  is called only by the prelude's or the standard library's handlers
  and members whose rows have `Async`.

**No handler task.** A `task =>` among a handler's arms is a parse
error with a help, async.md's tasks in handlers being gone:

```
error: a handler has no task of its own
  help: spawn one beside the `with`, into an `Async.scope` outside it, that calls one of the handler's operations
```

### Runtimes (steps 2 and 5)

**One scheduler a run.** The interpreter runs `main`, and each test,
as the root task of a scheduler (lib/eval/sched.ml), whatever the
program uses: a program with no tasks is a scheduler with one, and
nothing it does changes. The root task's path is `main`, or `test` for
a test. A runtime is the scheduler's policy: `single` or `sim`. Its
handler is a real one for `Async`, in Ren:

```ren
handler single_runtime() for Async =
  let rt = runtime_single()       // `sim.scheduler(seed)`'s is `runtime_sim(seed)`
  finally(r) =>
    runtime_leave(rt)
    try r
  yield() => runtime_yield()
  tick() => runtime_tick()
```

`runtime_single` sets the policy for the `with`'s body and
`runtime_leave` puts back the one before; a scope's functions,
`spawn` and the rest are intrinsics that ask the scheduler, which has
the policy. **A runtime installed while any task but the one installing
it is running is a panic,** so policies never mix:

```
panic: `Async.single()` is installed while other tasks run
  = a runtime runs every task of its `with`, so it's installed where no other task runs yet
  help: install it once, around `main`'s body: `ren run` installs `Async.single()` itself, and `ren test` a `sim.scheduler`
```

**What the runtime installs.** `Async` and `Net` join the runtime's
dependencies (Prelude's `runtime_deps`), each installed around `main`
if it uses it, as `Clock` is: `ren run` installs `Async.single()` and
the real `Net`; `ren test` installs `sim.scheduler(seed)`, `sim.clock()`
for `Clock` and `TestClock` (in place of `test_clock(Time.epoch)`,
which a test can still install by hand, a clock that never waits) and
`sim.net()` for `Net` and `SimNet`; a test whose `uses` names `Async`
gets `single`, as one that names `Clock` gets the real clock. Natively,
`Async`'s real implementation has `yield` and `tick` return at once,
and is all a native program has (Native, below).

### Scheduling

A task is a fiber: an OCaml 5 effect continuation, run by the
scheduler's loop, which an intrinsic that waits suspends with an effect
(`Effect.Deep`; each task's `depth`, for `max_depth`, is its own). The
scheduler keeps, per task, its path, its scope, whether it's been
asked to stop, how deep in `finally`s it is (shielded), its deadline
stack and its result. **A task runs until it waits,** at one of:
`join`, `spawn` on a full scope, the end of a scope's body while its
tasks run, `until`, `tick`, `yield`, a sleep, I/O, a `map`, `each`,
`both` or `race` waiting for its tasks, and an operation's instance
held by another task (step 4). There's no preemption.

Step 2 builds the scheduler with `single`'s order and real timers,
which `ren run` uses; step 5 makes `single` and `sim` the handlers
below, and adds `sim`'s choices and virtual time.

**`single`'s order,** which `ren run`'s output follows exactly:

- one run queue, first in first out; a task that's woken, or spawned,
  goes on its end, in the order that happens;
- `s.spawn` starts its task at the queue's end and goes on, unless the
  scope already has `max` tasks running: then it waits until one ends,
  and is woken to spawn it;
- `Async.yield()` goes to the queue's end; `Async.tick()` waits until
  each task that was in the queue when it was called has run until it
  waited, or ended;
- `Async.scope` runs its body in the calling task; once the body has
  returned, the task waits until every task of the scope has ended,
  then returns the body's value;
- `map` and `each` start a task for each of the first `max` elements,
  in order, and one more each time one ends; `both` and `race` start
  their two; the caller waits until they've all ended;
- when no task can run, the scheduler waits for the earliest timer or
  I/O (`Unix.select`), and wakes the tasks whose waits completed in the
  order of their deadlines, then of their file descriptors; if nothing
  is pending and tasks are waiting, it's a deadlock, a panic:

```
panic: every task is waiting, and nothing can wake one
  = main/serve:0 waits in `Async.until` at server.ren:14:5
  = main waits for its scope's tasks at server.ren:9:3
```

**`sim`'s choices.** The same, but at each scheduling point the next
task is drawn from the tape among the tasks that can run, the current
one included. A scheduling point is each place a task can wait, and
**each call of an operation of a shared, exclusive instance** (one a
spawned task can reach, whose handler keeps state: step 4), before the
call, since that's where the order of two tasks can be seen. Wakes are ordered by virtual deadline, then by
the tape. Time is virtual: it moves only when no task can run, straight
to the earliest timer.

**The tape** is a stream of numbers from the seed (splitmix64), typed:
the scheduler's choices draw from one stream, and `Random` from
another, split per task (step 5): the root task's `Random` is today's
chain from the seed, so tests that use it don't change, and a spawned
task's starts from the seed mixed with its path's hash, so what a task
draws doesn't depend on the order tasks ran in. A test's seed is its
own, from its name, as today; `--seed S` gives every test `S`; `--seeds
N` runs each test under its own seed and the next `N - 1`, stopping at
the first that fails, whose report says `seed S · rerun: ren test ...
--seed S`, and a run that passes says `10 passed, each under 1000
seeds`. `--sim` is accepted and changes nothing, since `ren test` runs
on `sim` anyway (the README's milestone writes it).

**Virtual time** (step 5). `sim.clock()`'s `now` is `Time.epoch` plus the
virtual time elapsed since its `with`, `instant` likewise from
`Instant.zero`, `sleep(d)` waits until virtual time has moved on by `d`,
and `TestClock.advance(d)` moves virtual time on by `d` at once, waking
whatever it passes. With one task, that's what `test_clock` did, so
every test today passes unchanged; a test that sleeps an hour finishes
in milliseconds. The real `Clock.sleep` under `sim` waits in virtual
time too; its `now` stays the system's, since a test that asks for the
real clock asked for the world.

### Structured tasks (step 2)

- **`Async.scope(max: n)`** runs its body with a `Scope`; `n` below 1
  is a panic, "`Async.scope`'s `max` is 0, so it couldn't start a task"
  with "help: `max:` is at least 1"; `map`'s and `each`'s too.
- **`s.spawn`** marks the instances its block can reach as shared
  (step 4) and starts the task; **`s.start`** does the same and gives
  its handle. A task's path is
  its parent's, `/`, a label and an ordinal: the label is the name of
  the function the spawn is written in (`serve`; a handler's arm is
  `handler.op`; a test is `test`), and the ordinal counts the tasks its
  parent has started with that label, from 0: `main/serve:7` is the
  eighth task `main` started from a spawn in `serve`. `map`, `each`,
  `both` and `race` label theirs the same way, by the function they're
  called in. So a path depends on the program's functions, not its
  lines, and a journal survives edits (foundations.md, decision 11).
- **A task spawned beside a `with` is its background task.** A block
  spawned into a scope that began before a `with` whose instance the
  block's evidence holds (one installed after the scope began, in the
  spawner's task) is registered with that `With`: when the `With`'s
  body ends, its registered tasks still running are cancelled and
  waited for, and only then does its `finally` run (foundations.md,
  decision 7: "the scope cancels it when the body ends"). So a task can
  never call an instance whose `with` has ended. The interpreter keeps
  a counter of `With`s per task, which a scope records when it begins
  and each instance records when it's made, so "installed after the
  scope began" is one compare. A task spawned with no such `with`
  between, as a server's connections are, is waited for by its scope.
- **`t.join()`** waits for the task to end and gives `Some` of what it
  returned, or `None` if it was cancelled before it returned. **`t.cancel()`**
  asks it to stop and returns at once. A task cancelled before it first
  runs never runs.
- **`s.replace(key) fn() => ...`** cancels the task the scope started
  under a key equal to `key`, if it's still running, waits for it to
  end, then spawns the new one under `key`. Keys of different types
  are never equal.

**Cancellation,** as async.md has it, in the interpreter:

- **It happens at dependency calls.** A task asked to stop raises
  `Sched.Cancelled`, an OCaml exception, at its next dependency call,
  before the call, and at once if it's waiting: the wait ends. A call
  that completed is never thrown away: a cancel that arrives while one
  runs lands at the next.
- **It goes down.** Cancelling a task cancels the tasks of every scope
  whose body it's running, and theirs, and the task waits for them as
  its scopes do.
- **It can't be swallowed.** Core's `Handle` doesn't catch it, so
  `try`, `attempt` and `orelse` can't see it. Only a `finally` sees it,
  as `Err(Cancelled)`: a handler's `finally(r)` and an arm's are typed
  with `r: Result<T, ! E | Cancelled>`, where `E` is the errors of what
  they cover. `Cancelled` is in no other row: `try r` and `fail
  Cancelled` in a `finally` go on cancelling, so its own errors never
  have it, and `fail Cancelled` anywhere else is an error, "`Cancelled`
  isn't an error a program can fail with" with "help: a cancelled task
  stops by itself; to stop early, return". What a `finally` returns when
  cancellation was the cause is thrown away.
- **An arm's `finally`** is lowered to a new Core node, `Covered {
  body; result; after }`: `body`, then `after` with `result` bound to
  `Ok` of its value, `Err` of its error, or `Err(Cancelled)`, shielded;
  if the body was cancelled, the cancellation goes on once `after` has
  run, and otherwise `after`'s value is the node's. Core Lint checks
  `result`'s type is `Result` of the body's type and its errors with
  `Cancelled`. A handler's `finally` is run by `With` the same way.
- **It never stops cleanup.** While a task is in a `finally` (a
  `Covered`'s `after`, a handler's `finally`, a Core `Finally`'s
  `after`) it's shielded: its dependency calls and waits don't see the
  cancel. **The cleanup deadline is 5 seconds** from when the cancel
  was seen, real under `single` and virtual under `sim`; once it has
  passed, the shield is gone, and the cleanup's own calls and waits are
  cancelled too.
- **A failure cancels the tasks beside it, and the first one wins.** In
  `map`, `each`, `both` and a scope's body, the first error is the
  result; the rest are cancelled and waited for, and an error another
  task fails with while being cancelled is written to stderr, never
  dropped and never joined to the error type: "warning: main/crawl:3
  failed too, with `Down`, while it was being cancelled". `ren run
  --record` writes it to the journal as a comment.
- **Errors and panics show the task path.** A panic in a task other
  than the root gains a note, `= in the task main/serve:3`; an error
  `main` fails with that came from a task gains `= from the task
  main/crawl:2`. `--trace` nests each task's calls under the task that
  started it, by path.

### The rest of `Async` (step 3)

- **`Async.until(cond)`** is written in a handler's arm, inside its
  operation (lexically, blocks included), and nowhere else; its
  condition uses no dependency and can't fail:

  ```
  error: `Async.until` waits for a handler's state to change, so it's only written in one of its operations
    help: move the wait into an operation of the handler whose state it reads

  error: `Async.until`'s condition can't use `Clock`
    = it's checked again each time the handler is released, so it can only read the handler's state
    help: read it in the operation, before the wait
  ```

  If the condition holds it returns at once. Otherwise the task lets
  go of the operation's instance and waits; each time the instance is
  released, the waiters' conditions are checked in the order they
  began waiting, and the first that holds gets the instance back and
  is woken, before any caller queued for it (step 4). A panic in a
  condition is its waiter's. With no other task to change the state,
  it's the deadlock panic.
- **`Async.tick()`** and **`Async.yield()`** as in Scheduling.
- **`Async.timeout(d) fn() => ...`** runs its body in the same task,
  under a deadline: the sooner of `now + d` and the deadline it's
  already under, so **deadlines carry down**, and the waits of every
  call made under it (`Net`'s among them) end at it. When the deadline
  passes the body is cancelled, from the timeout down, tasks of scopes
  inside it included, and once the cancellation has reached the
  timeout it fails with `Timeout`. **It never reports `Timeout` for
  work that finished:** if the body ends without the cancellation
  having been seen, because it had returned or failed, or what was left
  was shielded, its result is the timeout's, late. So a commit in a
  `finally` that overruns gives the transfer, not `Timeout`.
- **`Async.race(a, b)`** runs both as tasks; the first to return is the
  result, the other is cancelled, and race returns once it has ended.
- **`Async.isolate fn() => ...`** runs its body in the same task; a
  panic in it ends the program anyway if the task is then in the middle
  of an operation of an instance installed outside the isolate, and
  otherwise the `finally`s of the handlers installed inside it run,
  given `Err(Cancelled)`, the tasks of scopes inside it are cancelled
  and waited for, and it fails with `Panicked(msg)`, `msg` the panic's
  message. Its block can't change a variable from outside it, and
  can't be a block parameter (so no caller's variable can be one it
  changes):

  ```
  error: an isolated block can't change `n`, which is outside it
    = nothing it changed is seen after a panic, so it changes only what it returns, and what it changes through operations
    help: give it back as the block's result: `let n = try Async.isolate fn() => ...`

  error: `Async.isolate` takes a block written here, not `f`
    help: write the block: `Async.isolate fn() => f()`
  ```

- **`map`, `each` and `both`** as in Scheduling and Cancellation; `map`
  gives its results in the elements' order, whatever order they ended
  in. `each`'s block gives `()`:

  ```
  error: `Async.each`'s block gives an `Int`, which `each` would throw away
    help: use `Async.map` to keep the results, or end the block with `()`
  ```

- **No `par_map`:** `xs.par_map(f)` is the ordinary missing method's
  error, with a help: "`Async.map(xs) fn(x) => ...` runs on every core
  when its block uses no dependencies".

### Operations that don't interleave (step 4)

- **An operation keeps its instance until it returns,** across its own
  calls to handlers installed outside it, and lets go early only while
  it waits in `Async.until`. A call of an operation of an instance
  another task holds waits, queued first in first out; when it's
  released, a waiter whose condition holds comes first, then the
  queue's first caller. Lower records on each `Instance` whether it
  needs this, `exclusive`: its handler has a `var`, or a `let` or a
  parameter of an opaque type (a resource the runtime keeps, a
  `Journal`). The interpreter keeps, per instance, its holder, its
  queue and its waiters.
- **The exclusion is skipped for instances no spawned task can
  reach.** `s.spawn` (and `map`, `each`, `both`, `race`) marks shared
  every instance in its block's evidence, which is every instance
  installed outside the spawn, for good. An instance that isn't shared,
  or isn't `exclusive`, is called as today, with no queue and no
  scheduling point. So a program with no tasks runs as it did.
- **No deadlock.** A task takes instances inner to outer, since an
  operation only calls what's installed outside it, given two rules:
  handlers in one `with` can't use each other in a cycle (already an
  error), and **a block passed to an operation gets dependencies only
  from its parameter's type**, so it can't call back into the instance
  that's running it:

  ```
  error: a block passed to `Tally.change` can't use `Tally`, which it would wait for while `Tally.change` runs it
    = a block passed to an operation gets its dependencies only from its parameter's type
    help: call it before `Tally.change`, outside the block
  ```

  For a dependency other than the operation's own, the help says to
  list it in the parameter's type, `f: fn(&Int) uses Clock`, or to call
  it outside the block.

  The second rule is Infer's: a block argument of a `Dep_call` whose
  uses, beyond its parameter type's, aren't empty is refused, at the
  first call in it that uses one.
- `finally`s run when nothing else can reach the instance (a scope
  inside the `with` has ended), so they take no lock.

### Journal version 2 (step 6)

```
# ren journal 2 · main.ren · deps: Console Os Proc
1 main Os.args() → ["all"]
2 main/run_all:0 Console.error("echo base")
3 main/run_all:1 Console.error("echo lint")
4 main/run_all:0 Proc.run("sh", ["-c", "echo base"]) …
5 main/run_all:1 Proc.run("sh", ["-c", "echo lint"]) …
6 poll main/run_all:1 main/run_all:0
7 main/run_all:1 → Ok(0)
8 main/run_all:0 → Ok(0)
9 main exit 0
```

- **Each entry names its task.** A call that waits is written in two
  lines, its start, ending `…`, and, after the poll that completed it,
  what it gave: a line of only a task and `→`, then the value. A call that doesn't wait is one line,
  as in version 1.
- **`poll`** lines are the scheduler's polls that woke tasks, under
  `single`: the tasks whose waits completed, in the order they were
  woken. That and the program's code fix everything else `single`
  does, so a replay that follows them runs the same order. A
  cancellation a task saw is a line too, `12 main/serve:3 cancelled`,
  and the second failures above are `#` comments.
- **Answers are keyed by task:** a replay answers each task's calls
  from that task's entries, in order, so a test's replay doesn't
  depend on the order its tasks happen to run in.
- **A journal as a test has a schedule prefix:** under `sim`, while the
  journal's next entry's task can run, the scheduler runs it; once it
  can't, or the journal has none left, the seeded tape takes over.
  `ren replay` is strict, as before: it follows the polls, and stops at
  the first call, task or order that differs. `ren replay` of the
  concurrent `just`'s journal prints what the run printed, byte for
  byte.
- **Version 1 is refused,** in `ren replay` and `replay(file)`:

  ```
  error: `tests/build.journal` is a version 1 journal, which this `ren` doesn't read
    = version 2 names the task that made each call
    help: record it again: `ren run --record tests/build.journal main.ren`
  ```

  examples/just/tests/build.journal is re-recorded.

### `Net` (step 7)

- **The real `Net`** is non-blocking sockets through `Unix`, each wait
  a scheduler wait on its descriptor (`select`). `listen` binds and
  listens (backlog 128) and fails with `InUse` if the address is taken;
  `accept` waits for a connection; `read` waits until bytes or the end
  are there; `write` waits until all its bytes are written; `close`
  closes. Once `accept_until` has given `None`, its listener is closed,
  and a connection to its address is `Refused`. `accept_until(l, stop)`
  waits for a connection or for `stop`:
  the runtime catches SIGTERM; one that comes while nothing waits on
  `Signal.term` is kept for the next `accept_until`, or, if the program
  has none, cancels `main`, so plain shutdown needs no code.
- **After `accept_until` returns `None`,** the task that called it is
  under the cleanup deadline: its scope's tasks, the in-flight
  connections, have 5 seconds to finish, then they're cancelled, and
  their `finally`s run (shielded, under the cleanup deadline of their
  own). A second SIGTERM ends the program at once. A `main` that was
  cancelled by a signal exits with 143 (128 + 15), after its
  `finally`s.
- **`sim.net()`** is Ren, in the `sim` module: a handler for `Net` and
  `SimNet` keeping listeners and connections in maps, each connection
  two byte buffers, whose waits are `Async.until` in its operations;
  `SimNet.signal(Signal.term)` makes waiting `accept_until`s return
  `None` (and starts the cleanup deadline as above).
- **Journal entries:** `Net`'s calls are world calls, recorded and
  replayed, each wait a two-line entry.

### The standard library (step 8)

`sync` as in The surface, in Ren. `keyed` can't be: a handler can't
keep `n` instances of another in its state, so it's built in, the one
part that isn't, and checked so that its argument is a description: a
`With` of a `keyed(n, h)` description makes `n` instances of `h`, in
order, and an operation's call on it picks one by the hash of its first
argument's key (shown.ml's walk, through the argument's type), or, with
no parameters, runs on each in turn, giving the last's result. Each
instance is an instance as any other, with its own exclusion, so the
operations on two keys in different instances overlap.

```
error: `keyed` takes a handler's description, and `16` is an `Int`
  help: describe the handler whose instances it keeps: `keyed(16, accounts())`
```

Then the five programs and the milestone (The tests), and the `just`
runs a level's recipes at once (`Async.each(level, max: 8)`), killing
the rest when one fails: the real `Proc.run` waits for its process as a
scheduler wait (`SIGCHLD` and `waitpid` with `WNOHANG` at each poll),
and cancelling it kills the process (SIGTERM, then SIGKILL after the
cleanup deadline) and waits for it to exit.

### Native

What's sequential builds natively, in debug and release, and agrees
with `ren run` (bench/11a in bench/build.t):

- `try with` (step 1): nothing new past the checker.
- `Async`'s real implementation, `yield` and `tick` returning at once,
  and `Async.until` with no other task (step 3): its condition is
  evaluated, and if it's false the program panics with the deadlock
  panic's headline, as `ren run` does with one task.
- `sync`'s `semaphore` and `limit` (step 8), which need no task.
- Anything that starts a task is refused by `ren build`, at the first
  call to Async's `scope`, `map`, `each`, `both`, `race`, `timeout` or
  `isolate` that to_mem meets:

  ```
  error: `Async.scope` runs tasks, and tasks aren't native yet
    help: run it with `ren run`, which runs tasks
  ```

### Where 11a may differ from foundations.md

Choices this specification made where the record is silent, each to
revisit if a step finds it wrong:

- **`Async`'s functions are members of the dependency, its operations
  only `yield` and `tick`.** Decision 9 makes the runtime a handler;
  the functions that take blocks and are generic can't be operations,
  which take neither, so they're members in Ren over intrinsics, and
  the scheduler they ask is the one whose policy the installed runtime
  set. A runtime installed while other tasks run is a panic, so
  policies never mix.
- **A parameter with a default** is new to the language, for `max:`
  (decision 7 says the default is 64); a default is a literal, given by
  name.
- **`concurrent` and `spawned`** are the written modes of rule B, which
  names no syntax.
- **The background task of decision 7** is cancelled by the `with` it
  was spawned beside, when that `with`'s body ends; a scope's own body
  ending cancels nothing, since a server's scope waits for its
  connections.
- **`s.spawn` gives `()`, and `s.start` the handle.** A dropped value is
  an error in Ren (`let _ = ...` says so), and a `let` can't end a
  block, so a spawn that gave its handle couldn't be a match arm's
  statement, as a server's is; most spawns want no handle.
- **`join` gives an `Option`**, `None` for a task cancelled first; a
  task cancelled before it runs never runs.
- **`s.replace` waits for the task it cancels** before starting the new
  one, so a key never has two.
- **A task's path's label is the function its spawn is in,** and its
  ordinal counts what its parent started from there (decision 11's
  "label of its spawn site").
- **Seeds:** one seed a test drives its whole tape; `--seeds N` is the
  test's own seed and the next `N - 1`; `--sim` changes nothing.
- **`sim` and `sync` are modules,** found by `import`, the first of the
  standard library's: `sim.scheduler(seed)` and `sim.net` are written
  as foundations.md and the brief write them, and their names stay out
  of every module's scope.
- **The test `Clock` is `sim.clock()`,** virtual time; `test_clock(at)`
  stays, a clock that never waits.
- **`limit` is two items, `with sync.semaphore(16), sync.limit() over
  Web`.** Decision 10 has an operation keep its instance across its own
  calls, `call.forward()` included, so a `limit(n)` that kept its count
  in its own state would let one call through at a time. Decision 10's
  remedy is to split the operation in two, and that's what this is: the
  semaphore's `acquire` waits in `Async.until`, and `limit()` has no
  state, so it takes no lock. Two `limit`s in one `with` share one
  semaphore.
- **`keyed(n, h)` is built in,** since nothing in Ren can keep `n`
  instances; its spelling is the brief's.
- **Signals:** SIGTERM goes to a waiting `accept_until`, or cancels
  `main`; after `accept_until` says `None`, the cleanup deadline bounds
  what's in flight; a cancelled `main` exits with 143.
- **Natively, `Async.until` that doesn't hold** is the deadlock panic,
  as one task under `ren run` is.
- **The prelude's opaque types don't make a handler exclusive** (step
  4): a recorder's `Journal` is the runtime's, and a recorder that locked
  would make the calls it records wait for each other.
- **A call back into the instance its own task holds** is a panic (step
  4), for what reaches one past Infer's rule, through a block parameter.
- **The standard library is lib/core/std_lib.ml** (step 5), since a
  module named `Stdlib` would hide OCaml's own; its modules are linked
  into every program, since `ren test` installs `sim`'s whether the
  program imports it or not.
- **`sim.clock()` is `Clock & TestClock uses Async`** (step 5): it waits,
  so its type says what installing it needs, as "The two holes" asks.
- **`sim`'s virtual time starts at 0** (step 5), so a seed runs the same
  whenever it's run; and **a scheduling point isn't a wait** for `tick`,
  so `tick` under `sim` means what it does under `single`.
- **A call that waits ends its first line with `…`** (step 6), and the
  end of a run is a line of `main`'s, `9 main exit 0`. A call that gives
  nothing and one whose task waited in it would otherwise both be
  `task Dep.op(args)`.
- **A test's root task is `main` to its journal** (step 6): `test/...`
  paths are written `main/...`, so a test that calls `main()` names its
  tasks as the recorded run did.
- **A signal that comes stays come** (step 7): once SIGTERM has come for
  an `accept_until`, every one waiting for it, and every later one, gives
  `None`; one that comes before any `accept_until` has waited for it, in
  a program that has none yet, cancels `main`. `sim.net()`'s `signal` is
  only ever for `accept_until`: it never cancels `main`.
- **`sim.net()` is `Net & SimNet uses Async`** (step 7), as `sim.clock()`
  is: it waits in `Async.until`. `SimNet` is `sim`'s, so a test that
  connects writes `import sim.{SimNet}`; `ren test` installs `sim.net()`
  around every test, with `SimNet`, unless the test `uses Net`.
- **A replay sees a cancel that time made only where its journal says**
  (step 6), at the task's first point after its entry before; time moves
  on to when that cancel was due, so a timeout reaching it is `Timeout`.
- **`Batcher` has a third operation, `asked`** (step 8), which waits
  until a key has been asked for that no flush has fetched. A flusher
  that only ticked and flushed would never wait while nothing is asked,
  so under `sim`, whose time moves only when no task can run, it would
  keep time from ever moving; and `flush` can't wait for a key and then
  tick, since it would tick holding the instance the `get`s need.
- **The standard library's handlers panic where they can't go on**
  (step 8): a send on a closed channel, a channel of capacity 0 or a
  semaphore of 0 permits asked for one, a permit given back that wasn't
  taken, a key `Fetch.fetch` didn't give, `keyed` of fewer than 1. Each
  is said at the program's call, natively too (`lib_panic`).
- **`keyed`'s key goes to an instance by a hash with no seed** (step 8),
  `Walk.fixed_hash`, the same in every run, since which instance has a
  key can be seen (an operation with no parameters gives the last
  instance's result). `keyed` isn't native: to_mem refuses it as any
  intrinsic it doesn't know, which the brief allows ("if cheap").
- **A scope that has ended starts nothing** (step 9): a task of an outer
  scope can capture an inner scope it was spawned in the body of, and
  call `i.spawn` after `i` has ended; that's a panic, "a task is started
  in a scope that has ended", since the new task would outlive its scope
  and the frame it reads. A static rule would have to know which of two
  scopes a helper is given is inner, so it's the run time's.
- **A dependency call in an arm is still a change of all its handler's
  state** (step 9), as decision 2's table says, though an operation keeps
  its instance across its own calls: at one, `Async.until`, other tasks
  do run the handler, and natively it's what keeps a borrow of the state
  from changing under it there. Its note says so now.
- **Cancelling the real `Proc.run` kills its program, not what it
  started** (step 8): `sh -c "sleep 5; true"` leaves its `sleep`
  running, since OCaml's `Unix` can't put a child in a process group of
  its own; a recipe that `exec`s its program is killed whole.

### Step 1, as built

What step 1 settled where the text above is silent, or differs from it:

- **Modes and defaults are in the scheme, not in `Ty.param`.**
  `Ty.scheme` gains `modes`, the block parameters that aren't ordinary,
  by their place among the parameters (`self` counted), and `defaults`,
  each parameter with one, by place, name and literal. Both are a named
  function's signature, never a type's: `fn(Int) -> Int` has no mode, so
  types still compare with `=` (interfaces, release's specialization) and
  Lower and Core never see either. The interface keeps the scheme, so
  another module's Excl reads the modes and its calls leave defaults
  out; `ren types` prints both, `f: concurrent fn(Int) -> Int`, `max: Int
  = 64`.
- **A mode is written only on a named function's parameter whose type
  is written `fn(...)`.** A lambda's or a handler's is an error, "`spawned`
  marks a block parameter of a function"; an operation's block parameter
  has none either, since an operation's parameters are a function type's,
  which carries no mode: an operation can't pass its block on to
  `Async.map` (revisit if a program needs it).
- **`Spawned` stands for `Concurrent`.** Both only read what they capture,
  and a spawned block runs longer, so a `spawned` parameter may be passed
  on to a `concurrent` one; only `concurrent` to `spawned` is refused,
  "`body` is concurrent, so it can't be spawned". That's the order the
  private inference takes, so an inferred mode never refuses a use. A
  lambda's block parameter passed to either is refused: it has no mode to
  write.
- **A block given to a `concurrent` or `spawned` parameter** reads what it
  captures, and each block parameter it calls is passed on at that mode.
  A spawned block's reads of the variables bound outside the
  `Async.scope` body it's spawned into last until that call ends: into
  the scope it's given, as receiver or argument, if Excl is walking its
  body, or, given to a helper's `spawned` parameter with no such scope,
  into every scope around (conservative). `Async.until`'s condition adds
  no access in its arm.
- **Defaults** are checked against their parameter's type where they're
  written. At a call, Infer puts the arguments in their parameters' order
  (`Infer.Args` at the call's node), each default left out a literal at a
  node of its own, `Infer_env.default_node` (negative, so no parsed node
  has it); Lower and Excl read that order. A default is given only to a
  function called by its path, a member or a method; a lambda's is an
  error.
- **Rule D:** Resolve refuses a written `Scope` or `Task<T>` in a record,
  a payload, a type argument, a result, an operation's parameter or a
  handler's; Infer's walk the rest (an array, a tuple, a `var`, a
  handler's state, a type argument a use picks, a result); Core Lint no
  handle inside another type or as a type argument, and no function but
  the prelude's giving one. The prelude's own members are exempt.
- **What can't fail:** a `spawned` parameter's block, whatever it writes,
  and `Async.race`'s branches (`Iface.closed_blocks`, by path) have closed,
  empty error rows; the mismatch is worded by `Infer_expr.cant_fail_why`.
- **`try with`:** the installation's `ecall`s are covered by the markers
  around the `with`, and its body is inferred with none, so its calls
  have their own. `attempt with h() in X` keeps only what installing `h`
  fails with; what `X` fails with is kept by `with h() in attempt X`
  (test_deps.ml's one such test is written so now).
- **The surface's intrinsics** are one, `Unbuilt`, `fn<T>(Str) -> T`,
  which panics with its message; `Intrinsic.waits` says it can wait, and
  Core Lint checks only the prelude's functions whose rows have `Async`
  call one. The steps that build each member replace its `unbuilt` with
  their own intrinsics (each `waits`).
- **`Async` is installed around `main` and a test** (it's a runtime
  dependency and one of `Test_items.defaults`): its `real`, and a test's,
  are `single_runtime()`, whose `yield` and `tick` return at once. With
  one task that's what both do; step 5 makes the test's `sim.scheduler`.
  So every message that lists the built-ins names `Async` too. It isn't
  the world (`Prelude.world_deps`, the other six): the journal records
  none of its calls and a journal's header doesn't name it; `ren run
  --record`, `ren replay` and the console install the real one beside
  the recorders. Natively, its `real` is built, as `Console`'s is, so a
  native `yield` and `tick` return at once.
- **No handler task** is Resolve's, where `task =>` was the arm of an
  `over any` handler; it's reported only in a handler that isn't one.
- Test fixes: test_tasks.ml's `twice` and `fan_out` lacked the `try`
  that a call of a block parameter that can fail needs.

### Step 2, as built

What step 2 settled where the text above is silent, or differs from it:

- **The scheduler is lib/eval/sched.ml.** `main`, and each test, is the
  root task of a scheduler of its own (`Eval.rooted`); a task is an
  `Effect.Deep` fiber, which a wait suspends with the effect `Suspend`.
  It has `single`'s order (Scheduling, above) and real time: the real
  `Clock.sleep` is a timer the loop sleeps for (`Unix.sleepf`) when no
  task can run; `test_clock`'s never waits. Step 5 makes the order a
  policy and adds `sim`'s.
- **The intrinsics** are `scope_run`, `task_spawn`, `task_start`,
  `task_replace`, `task_join` and `task_cancel` (prelude.ml), each
  `Intrinsic.waits`; `task_cancel` returns at once, but asks the
  scheduler, as the rest do. eval.ml runs them (`tasks`), since they
  call blocks and wait.
- **Rule C's copies are the interpreter's, not Lower's.** A spawn copies
  its block (`Eval.copied`): each variable it captured gets a cell of its
  own, and so does each variable of each block it holds. That's sound
  because a spawned block only reads what it captures (Excl), and what
  it reads of the frame that called `Async.scope` can't change until the
  scope ends, so a copy reads what the variable would have; one bound
  inside the scope, a loop's, is read as it was at the spawn, which is
  rule C. A handler's state is a cell held as a value (`VCell`), so a
  task still shares it. Natively nothing spawns, so Lower needn't.
- **Cancellation** is the OCaml exception `Sched.Cancelled`. A
  `Dep_call` checks for it after its arguments and before the call; a
  wait (join, room in a scope, a scope's end, a sleep) ends with it. Core's
  `Handle` catches only `Failed`, so nothing in Ren can keep it. A
  `Finally`'s `after`, an arm's `finally` (`Covered`) and a handler's
  `finally` run `Sched.shielded`; `fail` of the tag `Cancelled`, which
  only a `finally` can write, and so `try r` of a cancelled body's `r`,
  raises it again. Infer gives a `finally`'s `r` the row `Cancelled |
  e`, `try r` passes on the row without it (`Types.without_cancelled`),
  and `fail Cancelled` outside a `finally` is the error above, with a
  note: "a task is cancelled from outside it, and only a `finally` sees
  it: it isn't an error, so `attempt` can't keep it".
- **The cleanup deadline** is 5 s after the cancel (`Sched.cancel` sets
  it), real time until step 5. A shielded wait of a task that's been
  asked to stop has a timer at the deadline, which cancels it then; a
  dependency call past it is cancelled at once.
- **A scope's end:** a body that fails cancels the scope's tasks, waits
  for them (a wait that a cancel doesn't end) and fails with its error;
  one that returns waits for them, and if the task is cancelled
  meanwhile, or in the body, it cancels them, waits, and goes on being
  cancelled. Cancelling a task so reaches every scope it's in the body
  of, and their tasks, down.
- **A task beside a `with`:** each task keeps the `with`s whose bodies
  it's running (`Sched.frame`), numbered by its count of `with`s, which a
  scope records when it begins. A spawn finds the innermost one begun
  after the scope (any of them, if the spawner isn't the scope's own
  task, since it started after the scope did) that installed an instance
  the block's evidence holds, and registers the task with it; the
  `with`'s body ending cancels and waits for those still running, before
  its `finally`.
- **Paths.** The label is the code a spawn is written in (`ctx.site`):
  a function's name (through a release build's copies, `Core.origin`),
  the function a block was lifted from, `handler.op` for a handler's
  arm, and a block written in an arm runs as that arm; a test's code is
  `test`. The prelude's code keeps its caller's label.
- **Panics** carry notes and a help of their own (`Eval.Panic`). One in
  a task that isn't a root gains `= in the task main/main:0` first, and
  ends the run at once, the other tasks with it (a panic isn't an
  outcome, so no `finally` runs). The deadlock panic is raised in the
  root, where it waits, with a note per task alive, earliest started
  first, saying what it waits for and at which call of the program
  (`ctx.call`, the program's call the prelude's code running was
  reached from): `= main/main:0 waits for room in its scope at
  server.ren:4:7`.
- **What isn't reachable yet:** an error a task fails with, and so `=
  from the task` and the "failed too" warning, need `map`, `each` or
  `both` (step 3): a spawned task can't fail, and a scope's body is its
  caller's task.
- **`main` ending cancelled**, which only a `finally` that writes `fail
  Cancelled` with nothing asking can do until signals (step 7), is "error:
  `main` was cancelled"; a test, "the test was cancelled".
- **`--trace`** puts each task's calls under a line of its own, its
  path, under the line of the task that started it.
- **`s.replace`'s keys** are equal when their types are and their
  `hash`'s `==` says so.
- **Natively,** `Covered` is the `Let` it is when nothing is cancelled;
  to_mem refuses the first call of `Async`'s `scope`, `map`, `each`,
  `both`, `race`, `timeout` or `isolate` (or a release build's copy of
  one) with the error above; bench/11a/spawns is as specified.
- **A release build's handler** (specialize.ml) now has its needs in
  scope while its arms are rewritten, so a block lifted from an arm may
  use what the handler `uses`, as it may in debug.
- Test fixes: none of the step 0 tests needed one.

### Step 3, as built

What step 3 settled where the text above is silent, or differs from it:

- **The members are Ren over intrinsics** (prelude.ml): `task_until`,
  `task_timeout` (giving `None` for `Timeout`), `task_isolate` (giving the
  prelude's private `Isolated<T>`, `Finished(v)` or `PanickedWith(msg)`),
  `task_map`, `task_each`, `task_both`, `task_race`, and `async_yield` and
  `async_tick`, which `single_runtime`'s arms call. Each is
  `Intrinsic.waits`; Core Lint lets the prelude's handlers of `Async`, the
  runtime, call one too, since their arms run only where `Async` is in the
  row. `Unbuilt` stays for the later steps' members.
- **An instance has a number** (`Value.installed.inst`, from
  `Value.instance`, increasing; a handler of several dependencies installs
  one number for all). A `Dep_call` runs its operation inside
  `Sched.holding`: the task is in the operation, by number and arm label,
  until it returns, fails or is cancelled, and then the instance is
  *released* (`Sched.released`). Step 4 builds its queue on this.
- **`Async.until`** waits on the instance whose operation it's written in:
  the innermost the task is in with the arm's label (`Sched.op_instance`).
  Each release of that instance checks its waiters in the order they began
  waiting and wakes the first whose condition holds; the condition runs
  as its waiter's (`Sched.as_task`), so a panic in it is raised where the
  waiter waits, with its task. Until step 4 nothing keeps another task
  from changing the state between that wake and the waiter running, so a
  woken waiter checks again, and waits again if it doesn't hold.
- **`Async.until` lets go of the arm's copy of the state.** An arm keeps
  its handler's `var`s in locals for the arm, read from their cells when
  it starts and written back when it ends (lower.ml, `with_cells`). So
  Lower (`until_released`) writes each back before a call of `until` in
  an arm and reads each again after, and makes the condition read the
  cells: other operations see what the arm changed before it waited, and
  the arm goes on from what they changed. That needs the condition to be
  a block written in the call, so a block bound elsewhere is an error,
  new: "`Async.until` takes a block written here, not `ready`", with help
  "write the block: `Async.until fn() => ready()`". `until`'s condition
  can't fail: `Iface.closed_blocks` closes it, as `race`'s branches.
- **Where `until` may be written** is Excl's (`in_op`: an arm and the
  blocks in it, not a `finally`); what the condition uses, the first
  dependency call in it (`first_dep`).
- **`yield` and `tick`** go to the end of the queue. In `single`'s one
  queue, first in first out, that's what `tick` asks too: everything in the
  queue when it was called runs until it waits first. Under `sim` (step 5)
  they differ, and `Sched.tick` is where.
- **`Async.timeout`** pushes a deadline on the task (`Sched.deadline`): its
  `due`, the sooner of now plus `d` and the deadline above it, and how deep
  in `finally`s the task was then. A task sees a cancel at its next
  dependency call or wait once a deadline is due (`Sched.cancel_due`),
  unless it has entered a `finally` since the timeout began: that shields
  it until the cleanup deadline after `due`. So a `finally` around a
  timeout doesn't shield its body, and a timeout written in a `finally`
  bounds what it covers. A wait sets a timer at the soonest of these, so
  a sleep under a timeout ends at its deadline. When `Cancelled` reaches
  the timeout and only its deadline caused it, it's `Timeout`; a cancel
  of the task itself goes on; a body that returned or failed gives what it
  did, however late.
- **`Async.isolate`** keeps, per task, the isolates it's in, each with the
  number of the last instance made before it and how many operations the
  task was in. A panic leaving an operation notes the instance; it's
  isolated (`Sched.isolatable`) when no instance it left, or that the task
  is still in since the isolate began, was installed before the isolate.
  The `with`s, scopes, `map`s and `race`s it unwinds through ask the same,
  and when it's so, a `with`'s `finally` is given `Err(Cancelled)` and a
  scope's tasks are cancelled and waited for, as for a cancel; otherwise
  nothing runs, as for any panic. Only `Eval.Panic` is made a value: an
  `assert` that fails in a test, a stack overflow and a replay that went
  differently aren't. Only a handler's `finally` runs on an isolated
  panic, as foundations.md says, not a function's `finally` or an arm's.
  New errors: "an isolated block can't call `f`, a block it was given"
  (it could change its caller's variables, as the rule against changing
  what's outside is there to stop). Limits: a panic in a task spawned
  inside the isolate still ends the program (a task's panic isn't
  carried to the isolate yet); low, since it's the conservative side.
- **`map`, `each`, `both` and `race`** run their blocks as tasks of a
  scope of their own (eval.ml, `all_of` and `race`), labelled by the code
  they're called from, `map` and `each` starting one more each time one
  ends, with the `max` panic as `Async.scope`'s. The first failure is the
  call's: the rest are cancelled and waited for; one that fails after,
  while being cancelled, is the warning on stderr ("warning:
  main/main:1 failed too, with `Bad`, while it was being cancelled").
  `ren run --record`'s journal comment for it is step 6's.
- **`= from the task`:** an error that came out of such a task is noted
  with the task's path (`Sched.came_from`, kept by the error value's
  identity, the deepest task first); `main` failing with it says
  `= from the task main/main:1` under the error (`Eval.Uncaught`'s
  `from`). A test's failure doesn't say it yet.
- **Release builds** (specialize.ml) know no handler that uses `Async`, and
  none at all in a program that calls `Async.isolate`: a known handler's
  operation is a direct call, with no `Dep_call` to hold or release its
  instance, which `until` and `isolate` need. Natively nothing runs tasks,
  so this costs a native build nothing it has; `isolate` isn't native at
  all. A direct call of a known operation still checks for a cancel, as a
  `Dep_call` does (this was missing in step 2).
- **Natively,** `yield` and `tick` are `()` and `task_until`, reached only
  when the condition doesn't hold, is the deadlock panic at the program's
  call of `Async.until`, whose site carries the note `ren run` prints
  (`Mem.site`'s new `notes`), so bench/11a/alone and alone_panic print the
  same natively, debug, release and tcc, and are in those loops.
- **`transfer` waits for step 5.** Its tests run under `test_clock`, whose
  `sleep` doesn't wait, so no deadline passes during its queries; with
  `sim.clock()`'s virtual time (step 5) they do. Step 5 lands it.
- Test fixes: none.

### Step 4, as built

What step 4 settled where the text above is silent, or differs from it:

- **`exclusive` is Core's.** `Instance` has a field `exclusive`, which
  Lower sets (`opaque_state`): the handler's state has a `var`, or what
  its operations use from outside them, a `let` of its state or one of
  its handler's parameters, has a value of an opaque type the module sees
  (`Infer.t`'s new `opaque`, its own and its imports'). A `let` no
  operation uses keeps nothing an operation could lose, so it doesn't
  count. **The prelude's opaque types don't count,** which departs from
  the text above ("a `Journal`"): the journal a recorder keeps is the
  runtime's, whose intrinsics never wait with it half written, and a
  recorder that took a lock would make the calls it records wait for each
  other, which journal version 2's two-line waits (step 6) rule out. An
  inline handler is exclusive by the same test on what it captures. The
  interpreter carries it on `Value.installed` (`excl`).
- **Shared:** a spawn, `start`, `replace`, and `map`, `each`, `both` and
  `race` share every instance their block can reach (`Eval.share_reach`):
  its evidence, that of each block it holds, and what each of those runs
  with (`outer`), transitively. `Sched.share` gives each exclusive one a
  lock (`Sched.locks`, by number), for good; one that a task is in the
  operations of when it's shared, which it reached before, is that task's
  already. An instance with no lock is called as before: no queue, no
  bookkeeping.
- **The lock** (`Sched.holding`) is its holder, how many of its
  operations the holder is in, and the callers waiting, first in first
  out. A call while another task holds it waits (cancellably: a cancelled
  caller never gets in). When the holder leaves its last operation the
  instance is released, and handed on at once (`released`): first to the
  first `Async.until` waiter whose condition holds, back in as many
  operations as it was, then to the first caller still waiting. Handing it
  on when it's woken, rather than when it runs, is what keeps a task woken
  later from cutting in.
- **`Async.until` lets go of a locked instance** while it waits, which
  is a release: the other waiters are checked and a caller may get in. A
  waiter that's cancelled, or whose condition panics, is still in the
  operation, so it has the instance back before its arm's `finally` runs,
  waiting (not cancellably) for its turn if another task has it. With the
  lock the woken waiter's condition still holds when it runs, so
  `Task_until`'s loop that checks again is only a guard.
- **A panic that leaves an operation** leaves its lock taken for good:
  what it was changing may be half changed. Only an `Async.isolate`
  around its `with` can go on, whose tasks are all cancelled, and a caller
  queued for it is one of those.
- **A call back into the instance its own task holds** can never go on,
  so it's a panic, "`Tally.get` calls back into the instance its own task
  is in, so it would wait for itself", with the no-deadlock rule as its
  help. Infer's rule catches the blocks written at an operation's call;
  this is what reaches one through a block parameter (`fn bump(f:
  fn(&Int)) uses Tally = Tally.change(f)`), which Infer can't see. With
  no tasks, the instance isn't locked and such a call runs as it did.
- **The no-deadlock rule (Infer).** While `applied` checks an operation's
  arguments (`Dep_op`, or a description's method, `Calls_op`) it marks
  their nodes (`Infer_expr.op_args`); a lambda or a named function checked
  at one defers a `Later` check: what its calls brought in themselves
  (each call's `own`), less what its parameter's type lists, is empty, or
  it's reported at the first call that brings one in. Its own row can't
  say, since a block's row is joined to the one where it's written. The
  dependency's own is "can't use `Tally`, which it would wait for while
  `Tally.change` runs it"; another's is "can't use `Console`, which its
  parameter's type doesn't list", whose help writes the parameter's type
  with it listed, `fn(&Int) uses Console`, not the parameter's name,
  which an operation's type doesn't keep (`Iface.Dep` fields). Limits: a
  block bound by a `let`, or a block parameter, passed to an operation
  isn't checked (the panic above covers its call back into the same
  instance); and a call of a function of the same recursive group, whose
  row is still being learned when the call is met, may be missed. Low:
  either is caught at run time, as that panic or the deadlock panic.
- **Release builds** (specialize.ml) know no handler in a program that
  starts tasks (calls `Async.scope`, `map`, `each`, `both` or `race`), as
  for `isolate`. A known handler's operations are direct calls with no
  `Dep_call`, which the lock is taken at; they can't wait (a known handler
  needs nothing, so it calls nothing and can't use `Async.until`), so they
  couldn't interleave anyway, but step 5's `sim` makes each call of a
  locked instance a scheduling point, and a release build must make the
  same ones. Natively nothing starts tasks, so this costs nothing.
- **For step 5:** `Sched.locked inst` says whether an instance is shared
  and exclusive, which is where `sim` makes a call a scheduling point,
  before `Sched.holding` takes the lock.
- Test fixes: test_tasks.ml's s4 accept test gained the `Clock` its
  `main` needs; test_blocks.ml's "a block in a handler's arm calls its
  own parameter" passes an operation a block that prints, which the
  no-deadlock rule refuses now, so its parameter's type lists `Console`
  (and the handler uses it); test_deps.ml's and test_lower.ml's hand-made
  `Instance`s say `exclusive = false`.

### Step 5, as built

What step 5 settled where the text above is silent, or differs from it:

- **The policy is the scheduler's** (sched.ml, `policy`): `Single`, or
  `Sim` with its tape and its virtual clock. `Sched.run` starts every
  run under `Single`; a runtime's handler sets one for its `with`'s body
  with `runtime_single()` or `runtime_sim(seed)` (`Sched.install`), which
  gives a number `runtime_leave` is given in its `finally` to put back
  the one before (`Sched.leave`). Installing one while any task but the
  installer is alive is the panic above, said at the `with`
  (`Eval.installing` moves a panic in the prelude's code that makes an
  instance there). The real `Async`, `single_runtime()`, is that handler
  over `runtime_single`; natively `runtime_single` is `0` and
  `runtime_leave` nothing, since a native program is always on `single`.
- **`sim`'s time starts at 0,** whatever the time was, so a seed's run is
  the same whenever it's run: a deadline compared with time that started
  at the system's would make ties between timers depend on the clock.
  The task installing it is the only one alive, so `Sched.rebase` moves
  the few times it keeps (its cancel's, its cleanup deadline, its
  timeouts' deadlines, and any timer) by the jump, both ways. Every
  deadline, timer and cancel reads `Sched.now`, so the cleanup deadline
  and `Async.timeout` are virtual under `sim` without more.
- **`sim`'s choices:** `Sched.take` draws the next entry of the queue by
  the tape, splitmix64 from the seed, uniformly among all that can run;
  with one, it draws nothing. A call of an operation of an instance that
  `Sched.locked` says is shared and exclusive is a scheduling point
  first, `Sched.point` (eval.ml's `Dep_call`, before `Sched.holding`):
  the task goes back on the queue and the tape picks. Under `single`,
  `point` does nothing, so `ren run`'s order is unchanged. Time moves
  only when the queue is empty, straight to the earliest timer.
- **`Async.tick` under `sim`** waits until each task that was on the queue
  when it was called has run until it waited, or ended (`Sched.waited`,
  from the fiber's handler when it suspends, and from `ended`). A
  scheduling point isn't a wait: a task at one has only let the tape
  choose, and under `single` there's none (a task's `pointed`). Under
  `single`, `tick` stays the queue's end, as step 3 built it.
- **The standard library is lib/core/std_lib.ml,** not stdlib.ml, which
  would hide OCaml's own `Stdlib` in every module of the library. `sim`
  is its one module so far; `sync` is a reserved name without a source
  until step 8, so `import sync` is still "there's no module `sync`",
  and a program's own sync.ren is "`sync` is the standard library's".
  The driver checks each module once (`Driver.std_modules`, lazily, as
  the prelude), against the whole prelude, the runtime's intrinsics among
  it, and **links it into every program, after the prelude:** `ren test`
  installs `sim`'s handlers around each test whether the program imports
  `sim` or not, and a native build compiles only what `$start` reaches.
  An importer sees it through its interface, as any module; `ren core`
  and test_*'s `core_files` leave it out, as they leave out the prelude.
  Its source is said to be in the prelude's file, `Prelude.file`: it's the
  runtime's code, so a panic in it is said at the program's call, and the
  checks that look for the prelude's code by its file (where a wait is,
  a `Dep_call`'s site) treat it alike. Core Lint lets it call the
  intrinsics that wait where `Async` is in the row, as the prelude may,
  and lets a handler whose needs have `Async`, `sim.clock()`, call one.
  An import of `sim` where the program has a sim.ren, or a sim.ren among
  `ren test`'s roots, is "`sim` is the standard library's", with a note
  and a help to rename the file.
- **`sim`'s source:** `scheduler(seed: Int) -> Async`, over the private
  `sim_runtime(seed)`, `single_runtime` with `runtime_sim`; and `clock()
  -> (Clock & TestClock uses Async)`, over `sim_clock()`, which keeps
  nothing but the time it was installed at, `let start = sim_time()`, so
  it has no `var` and takes no lock: two tasks' sleeps never wait for
  each other's (step 4's note). `now` is `Time.epoch` and `instant`
  `Instant.zero` plus the time since; `sleep(d)` is `sim_sleep`, the
  scheduler's sleep (the real `Clock.sleep`'s), and `advance(d)` is
  `sim_advance`, which moves the scheduler's time on, `sim`'s clock or,
  under `single`, a skew on the system's, and fires the timers it
  passes. A negative or zero `d` does nothing. The new intrinsics
  (`runtime_single`, `runtime_sim`, `runtime_leave`, `sim_time`,
  `sim_sleep`, `sim_advance`) are the runtime's (`Prelude.caller`
  `Internal`), and only `sim_sleep` waits. Natively, a call of the `sim`
  ones is "`sim` isn't in the native slice yet", with its help.
- **What a test is run on** (eval.ml, `run_installed`): its instances are
  made in its root task, since making the runtime's sets the policy;
  `sim.scheduler(seed)` first, the test's seed, then `sim.clock()` over
  it, then the rest as before. A test whose `uses` names `Async` gets
  `Async.single()`, as one naming `Clock` gets the real clock. `ren run
  --record` and `ren replay` make what they install in the root task too.
- **`Random` per task:** `test_random`'s `int` asks `task_random(seed,
  below)` first, which in a task that isn't a root gives the next number
  of the task's own stream for that instance (`task.randoms`, by the
  instance's number), from `hash(seed, path)`, by the same generator; a
  root gets `None` and draws from the instance's state as before, so no
  test that ran before changes. A spawned task's draws so don't depend on
  the order tasks ran in, which test_tasks.ml checks under two
  schedules.
- **`ren test --seeds N`** (test_runner.ml) runs each test under its seed,
  its own or `--seed`'s, and the next `N - 1`, stopping at the first that
  fails, whose failure says its seed; a run with no failure says
  `N passed, each under M seeds`. `--sim` is accepted and does nothing.
- **Landed:** `transfer` and `refresh`, now examples/transfer and
  examples/refresh (`refresh` was step 8's, but needed only virtual
  time), each `as specified` in bench/tasks.t and passing `--seeds 1000`
  in its new loop; and bench/tasks.t's `milestone` holds: `lost_update`'s
  first test fails under `--sim --seeds 200`, `--seed` replays it with
  the same sides, and `fixed.ren` and `cached.ren` pass under a thousand
  seeds. It stays in bench/11a/tasks, since its test fails on purpose.
- Test fixes: test_tasks.ml's cleanup-deadline test took 5 real seconds;
  it now runs under `with sim.scheduler(1)` and `sim.clock()`, and checks
  the deadline exactly, 5005 ms of virtual time.

### Step 6, as built

What step 6 settled where "Journal version 2" above is silent, or
differs from it:

- **The format** (journal.ml). Every line after the header is numbered,
  and every one but a poll starts with its task's path: `n path
  Dep.op(args) → gave` for a call that didn't wait; `n path Dep.op(args)
  …` and later `n path → gave` (or `n path →`, for `()`) for one its task
  waited in; `n poll p q`; `n path cancelled`; and the end, `n main exit
  0`, `n main error E` or `n main panic at "msg"`. A `#` line is a
  comment: a second failure's warning is one. `ren run`'s "recorded N
  calls" counts calls, a call that waits once, at its first line, so a
  cancelled sleep is counted. Reading checks that a task's call that waits
  ends before its next call, and that a `→` line ends one. A message
  shows a call with its task, but `main`'s without, so a journal of a
  program with no tasks says what it said before 11a.
- **Recording** (eval.ml's `journal`, journal.ml's `kept`, `gave` and
  `watcher`): `journal_kept` notes, per task, the call that has begun;
  the scheduler (sched.ml, its `journal` hooks, set by `Sched.watch`)
  says when a task waits, which writes that call's first line, ending `…`;
  `journal_gave` then writes its `→` line, or the call in one line. The
  scheduler says which tasks each `fire_due` woke, the poll line; and
  each task that sees a cancel (`Sched.seen`, at a dependency call's
  check, a wait's, and a resume by `Interrupt`), the `cancelled` line.
  `Eval.failed_too` gives its warning to `Sched.note`, the comment.
  Under `single` with real time, timers are the only polls until step
  7's I/O; `Proc.run` still blocks the thread (step 8), so it's one line.
- **Replaying, following the recording.** A replayed journal keeps its
  entries, which it has come to (`consumed`) and the first it hasn't
  (`cursor`). While it `follows`, which `ren replay` always does and a
  test does until it can't, the scheduler runs in `single`'s order
  whatever the policy (no tape, no scheduling point, `tick` as
  `single`'s), no timer fires on its own, and when no task can run the
  recording's next poll ends the waits it names, in its order: a task
  waiting in a replayed call that waits (`awaiting`), or one whose next
  entry is `cancelled`, woken by `Interrupt`. A cancel the task asked for
  (asked, not shielded) is seen as it would be; one time makes, a
  timeout's or the cleanup deadline's, only where the next entry says the
  task saw one, and the scheduler's time moves on to when it was due
  (`Sched.jump`), so `Async.timeout` makes it `Timeout` as the recording
  did. A replayed call whose recording waits waits too, for its poll, and
  then its `→` line is the entry the replay comes to.
- **`ren replay` is strict:** each call, its `→` line, each poll and
  each cancel has to be the next entry, its task's, or the replay went
  differently: "the replay went differently at call N of M", with what the
  recording has and what the program made or has. One found where no
  call is made, at a poll, is said at the journal's line (Eval.run).
  When no task can run and the next entry isn't a poll, the recording
  ended there too, so it's the deadlock panic, or the mismatch at the end.
- **A journal as a test** (`Test`): each task's inputs are answered from
  its own calls to that dependency, in order, and each task's outputs are
  compared with its own; the diff shows them task by task, the
  recording's tasks in the order they first made one. While each call
  the test makes is the journal's next entry, the test follows it, its
  schedule prefix; the first call that isn't, a poll that names a task
  not waiting for it, a cancel the journal doesn't have, or the journal's
  last entry reached, ends the prefix for good (`unfollow`): the tasks
  waiting for a poll are woken, and `sim`'s tape and virtual time take
  over. test_journal.ml checks both: a counter two tasks bump passes
  under 300 seeds while the prefix holds, and a journal whose order
  `single` never runs ends the prefix at once, so seeds differ.
- **Version 1** is `Journal.Version_1`, raised by the header: `ren
  replay` and `ren test --keep` say it as specified, with the program
  found from the journal's folder (`ren run --record tests/build.journal
  main.ren`), and a test's `replay(file)` as an error at the journal's
  first line. bench/11a/tasks/journal is as specified.
  examples/just/tests/build.journal is re-recorded, and every journal in
  the tests is version 2.
- **Byte for byte:** examples/journal.t records a level of recipes run at
  once by `Async.each`, each sleeping first, and diffs `ren run`'s
  output with `ren replay`'s: they differ only in the last line, which
  says recorded or replayed; the same with a failing recipe, whose
  siblings' cancels are lines. The `just` itself runs recipes at once in
  step 8, on this.
- **Limits:** a cancel that time made is seen, replaying, at the task's
  first point that can see one after its previous entry; a recording that
  saw it at a later one, past a dependency call of the program's own
  that wasn't recorded, replays differently, and strict replay says so.
  A recording made while time-based decisions depended on how late the
  recording saw them (a timeout whose cleanup deadline had passed too)
  can replay as the earlier. Low; recording the time on poll and cancel
  lines would close both.

### Step 7, as built

What step 7 settled where "`Net`" above is silent, or differs from it:

- **The prelude** declares `Addr`, `Listener`, `Conn`, `Signal` (`term`
  15, `interrupt` 2), `NetError` and `dep Net` as The surface has them,
  with `real_net()` over six intrinsics of the world (`net_listen`,
  `net_accept`, `net_accept_until`, `net_read`, `net_write`,
  `net_close`), each giving the private `NetOutcome<T>` that
  `net_checked` makes a value or a `NetError`, as `Fs`'s are. `Net` is one
  of `Prelude.world_deps` now, so `$start` installs it, a journal records
  it, `replaying` answers it, `replay(file)`'s type lists it, and the
  lists of built-ins in messages name it; `Prelude.dependencies` keeps
  only `Alloc` and `Unsafe`.
- **The real `Net`** is lib/eval/net.ml: non-blocking sockets, numbered
  by the runtime from 1, never twice, so a closed one's calls are
  `Closed`. A host is written as numbers (no DNS: `NetFailed`, saying
  so); `listen` sets `SO_REUSEADDR`, so a server can start again at once,
  and an address something listens at is still `InUse`; SIGPIPE is
  ignored, so a write to a closed connection is `Closed`. Each wait is
  `Sched.wait_io`, on its descriptor. `read`'s `max` below 1 is
  `NetFailed`, in both `Net`s, since no bytes read as the other side
  having closed.
- **The scheduler's poll** (sched.ml, `poll`): when no task can run and
  a timer, a descriptor or a signal is pending, it waits in `Unix.select`
  for the first of them (under `sim`, not at all if a timer's pending:
  time moves to it), and wakes, in one poll line, the tasks whose timers
  are due, by deadline, then those whose descriptors are ready, by
  descriptor, then those a signal is for. `Unix.select` limits a program
  to about a thousand descriptors; low, for 11a.
- **Signals.** `ren run` (and `--record`) catch SIGTERM
  (`Sched.catch_signals`), and an `accept_until` catches the signal it
  waits for, SIGTERM or SIGINT; another number is never caught, so it
  never comes. OCaml's handler only notes it and writes a byte to a pipe
  `poll` waits on too; a second of the same ends the process at once,
  with 128 and its number. A signal is seen at a poll, never while a
  task runs, so a journal's poll says when: a program that never waits
  sees it only at its next wait, or is ended by a second. A signal that
  nothing has waited for in an `accept_until` cancels the root; a run
  whose root ends cancelled so raises `Sched.Signalled`, which `ren run`
  exits with silently, 143, after the `finally`s ran, and a journal ends
  `n main exit 143` (`Journal.Stopped`). Replaying, a cancel of the root
  the journal has and nothing explains is the signal's (`signal_replayed`).
- **The cleanup deadline after `None`** is `task_drain()`, an intrinsic
  `real_net`, `replaying` and `sim.net()` call when `accept_until` gives
  `None`: each scope whose body the task is running (`task.scopes`, kept
  by `Async.scope`, `map`, `each`, `both` and `race`) gets the deadline,
  now plus 5 s, and so does each of its tasks, and each spawned into it
  later (`task.drained`). It's a cancel each sees at its deadline, as a
  timeout's is (`cancel_due`), so a replay sees it where the journal says;
  one in a `finally` then has its own cleanup deadline after it, as for
  any cancel (test_tasks.ml, "a `finally` running at the cleanup deadline
  has one of its own": cut at 11 s, for a signal at 1 s).
- **`sim.net()`** is std_lib.ml's `sim_net()`, in Ren: maps of listeners,
  connections waiting to be accepted, and ends (each its bytes not read,
  its peer, whether it's open), the signals sent, and the addresses whose
  listener has closed. `connect` waits until something listens at the
  address or its listener has closed (`Refused`); `accept_until`, once its
  signal has been sent, closes its listener, closes the connections it
  hasn't accepted, and starts the deadline. Its numbers are `Int`s it
  casts to `Listener` and `Conn` (`unsafe_cast`, sound since each is an
  opaque `Int`, and the interpreter's value of one is its `Int`).
- **Tests by default** get `sim.net()` for `Net` and `sim.SimNet`
  (`Test_items.defaults`' controls are paths now, for `SimNet`).
- **Native:** the real `Net` is "isn't in the native slice yet", as any
  intrinsic to_mem doesn't know.
- **Landed:** `server` is examples/server, `as specified` in bench/tasks.t
  and under `--seeds 1000`. Test fixes in it: `Err(e) =>
  Console.error(... show(e))` showed an error, which isn't a value
  (`Err(_)` now); its test helpers are `test fn`, since a test sees only
  what's public; and the last test's `try Async.scope` covered nothing.
  examples/net.t runs a server on the real `Net` with a Python client:
  SIGTERM while a request is in flight, which still gets its answer, then
  `Refused`; a sleeping program cancelled by SIGTERM, exiting 143 after its
  `finally`; and a server's run recorded and replayed.
- Test changes the spec listed: test_blocks.ml's `dep Net`s are `dep Web`;
  test_deps.ml's two "nothing can implement `Net` yet" tests name `Alloc`,
  which keeps those paths tested; test_tasks.ml's `type Conn` is `Session`
  (the prelude has a `Conn`).

### Step 8, as built

What step 8 settled where "The standard library (step 8)" above is
silent, or differs from it:

- **`sync`** is std_lib.ml's second module, in Ren: `channel(cap)`,
  `semaphore(n)`, `limit() over any`, `batcher()` and `keyed(n, h)`, as
  The surface has them, each handler `uses Async` and waits in
  `Async.until`. `Batcher` has `asked` too ("Where 11a may differ"); a
  batcher keeps what it fetched, so a key asked for again is answered at
  once, and a key the fetch didn't give is a panic in each task that
  asked for it. `limit()`'s arm takes a permit, then covers the rest of
  the arm with a `finally` that gives it back, so a call that fails, or
  is cancelled, gives it back too. A state passed to a dependency call
  while borrowed is still refused, as before 11a ("`wanted` is read
  across a dependency call"), so `flush` passes a copy; that error's
  note, "other tasks can run this handler at a dependency call", is stale
  since step 4, which step 9 should reword.
- **The standard library's panic** is the intrinsic `lib_panic(msg)`, the
  one that was `unbuilt`, which nothing called after step 3: a panic
  with its message, never a wait. Natively it's a panic with the message
  written in the call, at the site `ren_here` holds; a dependency call
  from the program's code now sets that site (to_mem.ml, `set_here_dep`),
  so a panic in a standard-library handler is said at the program's call,
  as `ren run` says it (bench/11a/limit_panic).
- **`keyed`** is `pub fn keyed<T>(n: Int, h: T) -> T = sync_keyed(n, h)`:
  Infer refuses a call whose `h` isn't a description, with the specified
  error, and makes the call of no type, so its `with` says nothing more
  (infer_expr.ml, `keyed_described`). The interpreter's value is
  `VKeyed (n, h)`; a `With` or `With_handler` of one makes `n` instances
  of `h`, in order, and installs one implementation, `VKeys`, each
  instance's implementation with its own number and exclusivity, so each
  has its own lock, and sharing one shares them all (`share_reach`). A
  `Dep_call` on one picks an instance by `Walk.fixed_hash` of its first
  argument, through its type, so its type's `key`; an operation with no
  parameters runs on each in turn and gives the last's result. Their
  `finally`s run the last made's first (`endings`), each given what the
  one after it gave. `n` below 1 is a panic.
- **`sim.proc(runs)`** is std_lib.ml's `sim_proc` in `sim`, with `Run`
  and `SimProc` as The surface has them. Its `run` has state, so it's
  exclusive once a task can reach it, and its program's time has to pass
  without it keeping the instance: it waits in `Async.until fn() =>
  sim_time() >= done`, which lets go of it, after `sim_alarm(done)`, a new
  intrinsic that releases the instance at that time (`Sched.alarm`), so
  the condition is checked then. The arm's `finally` notes a cancelled
  run in `killed`.
- **The real `Proc.run` waits as a task** (sched.ml, `wait_pid`): the
  program is started as before, and a timer looks at whether it has
  exited, `waitpid` with `WNOHANG`, a millisecond after, then at twice
  the gap, up to 20 ms, so the journal's poll line is the look that saw
  it. A cancel sends SIGTERM, then SIGKILL if it's still running at the
  cleanup deadline, and the task waits for it to exit, a wait no journal
  writes, since a replay runs no program and its cancelled call ends at
  the recording's `cancelled` line. Under `sim` those looks don't wait
  for the system's time; a test runs programs on `sim.proc()`.
- **Two bugs that lost a handler's state, fixed** (lower.ml): an arm's
  copies of its state were written back to their cells only if the arm
  ended or failed, not if it was cancelled, so what its `finally`
  changed was lost; they're written back in a `Finally` now whenever the
  arm can stop (`Core.can_stop`). And an arm that waits in `Async.until`
  read its copies again only if the wait ended, so a waiter cancelled
  there wrote back what it had before it waited, over other operations'
  changes; it reads them again however the wait ends (`until_released`).
  Both have tests in test_tasks.ml's s8 section.
- **The `just`** is examples/just, with bench/11a/tasks/just's tests
  folded in: `plan.levels` puts each recipe in the level after the last
  its dependencies are in, and `run_all` runs each level with
  `Async.each(max: 8)`. Its tests that said the order of a level's
  recipes now say what holds under every schedule: the level before
  first, the level after last, the level's own in either order. The
  justfile's `test` sleeps half a second first, so examples/just.t's
  output is in one order; and `ci`, `broken` beside `slow`, shows a
  failure killing the recipe beside it. tests/build.journal is recorded
  again. just.t records and replays a run of recipes at once, and one
  where one is killed, byte for byte but for the last line. examples/
  journal.t's recipes sleep a tenth of a second apart, since `Proc.run`
  now waits, and so takes time the order could depend on.
- **A test bug that made THE CHECKS flaky, fixed:** examples/just.t's
  `cp -r just t2` copied dune's sandbox's links, so `ren test --keep`
  appended its test to `_build`'s own copy of main.ren, and the next run
  saw "two tests named `replays bug.journal`" until `rm -rf _build`. It's
  `cp -rL` now.
- **Landed:** `crawler` is examples/crawler; `just` is folded into
  examples/just, with an `expected`; both are `as specified` in
  bench/tasks.t and pass under `--seeds 1000`. bench/11a/limit is as
  specified, and with limit_panic in the `same`, `release` and
  `tcc_same` loops. No `until` is left in test_tasks.ml.

### Step 9, as built

The review, with the brief's three lenses. What it found and fixed, each
with a test in test_tasks.ml's s9 section:

- **A task started in a scope that had ended** (unsound, structured
  tasks). `Async.scope fn(o) => Async.scope fn(i) => o.spawn fn() =>
  ...i.spawn ...`: the outer scope's task captured `i`, and once `i` had
  ended its spawn still started a task, which outlived `i`, and `o` too
  ("outer done" came before it). A scope now has `ended` (sched.ml,
  `closed` sets it), and a spawn into one is the panic of "Where 11a may
  differ". A spawn into a scope whose body has ended but whose tasks
  haven't is still taken, and waited for.
- **Two tasks replacing one key at once** (unsound, `s.replace`): both
  found the old task, both waited for it, and both started theirs, so the
  key had two. `Sched.spawn` now takes the key with its `equal`, and after
  each wait, for room or for the task it cancels, asks again; there's no
  wait between finding the key free and the room there and starting the
  task. The keys of tasks that have ended are dropped, so a server that
  replaces forever doesn't keep them all.
- **A task spawned beside a `with` by a task inside its body** (unsound,
  decision 7's background task): `with h() in Async.scope fn(i) =>
  i.spawn fn() => o.spawn fn() => D.op()` started a task in `o` that
  wasn't `h`'s background task, since `beside` looked only at the frames
  of the task spawning, `i`'s, which isn't in the `with`'s body; so it
  called `D.op()` after `h`'s `finally`. A task now keeps its `context`,
  the `with`s its spawn was in (its spawner's frames, then its spawner's
  context), and `beside` looks through the spawning task's frames and its
  context. Scopes and `with`s are numbered in one order across tasks
  (`Sched.begun`), so "began after the scope" means the same for any
  task's `with`, and a frame is `over` once its body is, so a context
  never names one that has ended.
- **A block bound by `let` and passed to an operation** (the no-deadlock
  rule, decision 10): Infer checked only blocks written at the call, so
  `let g = fn() => Y.poke()` passed to `X.run` while a task in `Y.poke`
  waited for `X` was the deadlock panic at run time. A `let` of a lambda
  now keeps its body's calls (`ctx.let_blocks`, from `lambda_calls`), and
  an operation's argument that's such a local is checked as one written
  there is (`op_block`). A block parameter passed on to an operation is
  still not checked statically. The run time catches it: the deadlock
  panic came only once every task waited, which a server's accept loop
  never does, so a cycle of two tasks hung silently; now a call that
  would queue for an instance follows the tasks each waits for
  (`task.queued`, `Sched.holding`'s `chain`), and if they come back to
  it, it's a panic at once that lists the cycle.
- **The stale note on a state read across a dependency call:** the error
  stays, as decision 2's table has it, and its note says why now
  (`Excl.dep_call_note`).

What it checked and found sound, by program (scratch programs, not
kept, beyond the tests above): a cancel that `attempt`, `retry(on:
Cancelled)` or `call.fail(Cancelled)` would catch (each refused, or not
seen); a handler's `finally` that fails with another error on a cancel
(the task still stops); a holder cancelled while others queue, and a
timeout on a queued caller (it never gets in; the state its arm changed
is kept); `race` and `timeout` at equal times and at 0 or less, and
nested; a `finally` that runs `Async.map` and a timeout past the
cleanup deadline (cut at the deadline); an isolated panic with a task
beside a `with` inside it; rule D through generics, `Option`, tuples,
blocks returned and `var`s; rule C through a block bound by `let`, a
helper's locals, nested scopes and loops; rule B through lambdas that
call the parameter; and a seed's run, `Random` per task included, the
same each time (`--seed`).

The spec: the README's milestone holds (bench/tasks.t's `milestone`; by
hand, `ren test --sim --seeds 200 main.ren` in bench/11a/tasks/lost_update
fails with a seed, `--seed` with it fails the same way, and fixed.ren and
cached.ren pass under `--seeds 1000`), and so does async.md's "Done when"
as amended: the five programs are in examples/ and pass under `--seeds
1000` (bench/tasks.t), an hour of virtual time takes milliseconds, the
`just` runs a level's recipes at once, kills the rest on a failure, and
replays byte for byte but its last line (examples/just.t), each error is
a refusal test, and a failure in a task says its path. The docs: async.md
says what this step fixed; the README's 11a row says done; runtime-io.md's
11a row says what was built of it.

### Step 2, as built

**The lexer** (lexer.ml, `lex_string`) finds a hole's end before it lexes
it: from `\{` to its matching `}` on the string's line, counting braces
and skipping the strings in it (with their own holes) and character
literals. The string's text before the first hole is a `STR_HEAD`, the
hole's code is then lexed as any code is, inside a bracket so it has no
layout, and the text after it is a `STR_MID` or `STR_TAIL`; a string
with no hole is a `STR` as before. Nothing about the lexer's
`continues()` or the line continuation changed. A character literal is
an `INT` of its code point, with `\n`, `\t`, `\\` and `\'`; since nothing
after the lexer can tell `'é'` from `233`, the lexer keeps where each
literal is and how it's written in `Ast.char_literals` (forgetting a
file's when it reads the file again), which the checker's `stored`
reads to refuse a non-ASCII one in a `UInt8`, and `Ast.source` reads to
show it as written.

**The AST** has `Interp of piece list`, each a `Lit` of text or a `Hole`
of an expression. Resolve, inference (each hole inferred, the result a
`Str`), Mut, Exhaust, the block and escape walks of infer_top.ml (a hole
is `show`'s argument, so a block there is `show(x)`'s error) and Excl
(one constructor added to the list it walks the children of) see it.
**Lower** makes it `show` of each hole, a `Str` hole as it is, joined by
`Str.add` left to right; an empty text piece is dropped. Native builds
and the interpreter need nothing of their own for it.

**The names.** `Str_len`, `Str_concat` and `Str_lower` became
`Str_byte_len`, `Str_add` (the method `+` finds) and `Str_ascii_lower`;
`Bytes_add`, `Bytes_ascii_lower`, `Str_char_floor`, `Str_char_ceil`,
`Str_code`, `Str_of_code` and `Array_join` are new intrinsics. Natively
`+` is `ren_str_concat`, a copy, as `concat` was (step 3 makes it in
place), and the new ones are ren_rt.c's `ren_char_bound`, `ren_str_code`,
`ren_str_of_code` and `ren_strs_join`. `is_empty` and `chars` are the
prelude's, written in Ren under `pub type Str = builtin`: `chars()` is a
`Chars { s, pos }`, whose `next` gives `s[pos..s.char_ceil(pos + 1)]`, a
slice that never cuts. `Bytes.cursor(from: Int = 0)` keeps `base`, and
`at()`, `Short`'s and `Malformed`'s `at` add it. `len` and `lower` on a
`Str`, `a.concat(b)` and `Str.concat(a, b)` (in Resolve) and `s[i]` are
errors worded as strings.md and the section above word them; a help of
several lines is split by Diag, its continuation under its text and a
`help: ` line a help of its own. `Bytes.add` being built in, lower.ml's
`ops` skips a built-in member, which isn't a function of the program's.

**Panics with a help the running program writes.** A cut character's
help has numbers only the panic knows and the receiver's name only the
source knows. Builtins raise `Panic_help` with `\002` for the receiver;
eval.ml gives the panic the receiver's location (`Panic`'s new `recv`,
the operand's or the call's first argument's), and the driver puts in
its text. Natively the site's help is `"\001"` and its `recv` the
operand's location; the driver makes that line a `Diag.Help_hole` with
the receiver's text, which emit_c.ml writes as piece 7, and
`ren_panic_help` prints it, the `\002`s replaced, only if the runtime
gave a help (an out-of-bounds slice at the same site has none). So
`ren run` and every build print the same bytes, which strs.t compares.

**Moved,** with the compiler's errors as the list (every bench program,
every example and test built, `ren core` over every file): `.concat(x)`
became ` + x` by a script that keeps precedence (a call on the result
gets parentheses), `.lower()` `.ascii_lower()`, and each `len` the
checker refused on a `Str` `byte_len` at the position it named. That's
53 programs under bench/ (native/maps, nbody and stack among the
kernels), examples/just's justfile.ren, the programs in journal.t,
just.t and net.t, and editors/'s highlight test; in test/, only
the lines with a renamed name (and the printed Core, `Str.add`, and
members lists, which the renames force); README, deps.md, handlers.md,
stdlib.md (a paragraph, "Text: sizes, characters and building") and one
line here. invalid_utf8.ren and test_strs.ml's s1 are back to step 2's
names. test_operators.ml's `"a" + "b"` and `sum` of `Str`s now say what
they say with `+` defined.

**Tree-sitter** has `interpolation`, with `interpolation_start` and
`interpolation_end` nodes (named, so the brackets' `}` isn't captured
twice) and an optional `=`, inside `string`, and `character` wherever a
number literal is, in code, patterns and defaults; corpus strings.txt;
Zed's highlights mark a hole `@embedded` and its braces
`@punctuation.special`, and a character literal `@string.special`, with
assertions in markers.ren.

**The tests.** s2 is on, every test written plainly, and no `until
"s2"` is left. test_strs_names.ml holds the choices above. strs.t's
step 2 programs, append, append_count, append_report, slices_kept and
slices_count among them, are as specified and the same natively in
every build (Perceus and naive debug and release under the sanitizers,
tcc, `ren run --release`), with no object alive at the end but in the
panics, which leave their program's as `ren run` does.

### Progress log

| step | commit | done | left |
|---|---|---|---|
| 0 | b3ba3c7 | this section; async.md rewritten to foundations.md and the brief; the README's race passage; test/test_tasks.ml, every test behind `until "sN"`; bench/11a/tasks/ (the five programs, the `just`'s part, the milestone, a version 1 journal) and bench/tasks.t, all `not yet`; bench/11a's sequential programs and their section of bench/build.t (`trywith` already as specified) | steps 1 to 9; nothing of the language or runtime is built yet |
| 1 | f887b16 | parameters with defaults, a block without parentheses, `concurrent` and `spawned` (lexer to tree-sitter and Zed); `Async`, `Scope` and `Task` declared in the prelude, each member panicking until its step; rules B to D (Excl, Resolve, Infer, Core Lint); spawned blocks and `race`'s branches can't fail; `try with`; `s.spawn` uses `Async`, with its note; `Intrinsic.waits`; the `task =>` error; test_tasks.ml's s1 tests on; examples/ledger, handlers.md and errors.md say `try with`; bench/11a/trywith in the native loops | steps 2 to 9 |
| 2 | 30b520b | the scheduler (lib/eval/sched.ml), `main` and each test its root task, in `single`'s order with real timers; `Async.scope(max:)`, `spawn`, `start`, `replace`, `join` and `cancel`; rule C's copies at the spawn; cancellation at dependency calls and waits, seen only by `finally`s as `Err(Cancelled)`, shielded until the 5 s cleanup deadline, `fail Cancelled` refused outside a `finally`; Core's `Covered` for an arm's `finally`; a scope's failure or cancel cancelling its tasks; tasks beside a `with` cancelled when its body ends; task paths in panics, the deadlock panic's notes and `--trace`; `ren build` refusing tasks; test_tasks.ml's s2 tests on, and more; bench/11a/spawns as specified | steps 3 to 9 |
| 3 | 7766c4a | `until`, `tick`, `yield`, `timeout`, `race`, `isolate`, `map`, `each` and `both` in the interpreter; instances numbered and released at each operation's end; `until` letting go of the arm's copy of the state (Lower); the checks on where `until` is written, its condition and `isolate`'s block; `each`'s block giving a value; `par_map`'s help; `= from the task` and the "failed too" warning; release builds knowing no handler that uses `Async`; natively `yield`, `tick` and the deadlock of `until`; test_tasks.ml's s3 tests on, and more; bench/11a/alone and alone_panic as specified and in the native loops | `transfer` (step 5, virtual time); steps 4 to 9 |
| 4 | 1d05a68 | operations that don't interleave: Core's `Instance` says whether its handler is `exclusive` (a `var`, or a resource of an opaque type of the program's); spawns, `map`, `each`, `both` and `race` share what their block can reach; a shared, exclusive instance's callers queue, first in first out, a waiter whose condition holds first; `Async.until` lets go of it and has it back, before its `finally` too; a call back into the instance a task holds is a panic; Infer's no-deadlock rule for a block passed to an operation; release builds know no handler in a program that starts tasks; test_tasks.ml's s4 tests on, and more | `transfer` (step 5); steps 5 to 9 |
| 5 | 1e6bbf0 | the runtime as a handler: the scheduler's policy, `single` or `sim`, set by `Async.single()` and `sim.scheduler(seed)` for their `with`'s body, a panic if other tasks run; `sim`'s seeded tape (splitmix64) at every wait and at each call of a shared, exclusive instance, its virtual time from 0, and `tick` under it; the standard library (lib/core/std_lib.ml) and its `sim` module, `scheduler` and `clock()`, linked into every program, `import sim`, and a program's own `sim` refused; a test on `sim.scheduler(seed)` and `sim.clock()`; `Random` per task; `ren test --seeds N` and `--sim`; `transfer` and `refresh` landed in examples/, and the milestone holds; test_tasks.ml's s5 tests on, and more | steps 6 to 9 |
| 6 | ed2c9a8 | journal version 2: a task column, a call that waits in two lines, poll lines, cancel lines, second failures as comments (journal.ml, the scheduler's `journal` hooks); `ren replay` following the polls, strict about each entry's task and order, byte for byte for a concurrent run (examples/journal.t); a journal as a test keyed by task, with a schedule prefix, then the tape; version 1 refused with a help; examples/just/tests/build.journal re-recorded; bench/11a/tasks/journal as specified | steps 7 to 9 |
| 7 | f5900d4 | `Net` in the prelude, its real implementation (lib/eval/net.ml) on non-blocking sockets and `Unix.select` in the scheduler's poll; SIGTERM caught by `ren run`, for `accept_until` or cancelling `main` (exit 143), a second ending it at once; the cleanup deadline after `accept_until` gives `None`; `sim.net()` and `sim.SimNet` in Ren, a test's default `Net`; `Net` recorded and replayed, a journal ending `exit 143`; examples/server landed, examples/net.t on the real `Net`; test_tasks.ml's s7 tests | steps 8 and 9 |
| 8 | 0959e30 | `sync` in Ren: `channel`, `semaphore`, `limit() over any`, `batcher` (with `asked`); `keyed(n, h)` built in, each instance its own lock, a key's instance by a hash with no seed; `lib_panic`, natively too, said at the program's call; `sim.proc()` and `SimProc`, its programs' time passing without the instance (`sim_alarm`); the real `Proc.run` waiting as a task, a cancel killing its program; an arm's state kept when it's cancelled, and read again after `Async.until` however it ends; examples/crawler landed, the `just` folded into examples/just, recorded and replayed at once; bench/11a/limit and limit_panic native; test_tasks.ml's s8 tests on, and more; no `until` left | step 9 |
| 9 | a895e59 | the review: a spawn into a scope that has ended is a panic; `s.replace` by two tasks at once leaves one task under the key; a task spawned beside a `with` by a task inside its body is its background task (`context`); a block bound by `let` and passed to an operation is checked by the no-deadlock rule; the across-a-dependency-call note reworded; README, async.md and runtime-io.md brought up to date; test_tasks.ml's s9 tests | nothing of 11a's plan; the low items in "Step 9, as built" and the steps' "as built" sections |

Notes for whoever goes on from 11a: what's left is low, and listed in
the steps' "as built" sections and step 9's. The ones most worth doing:
a block parameter passed on to an operation isn't checked by the
no-deadlock rule; a panic in a task spawned inside `Async.isolate` ends
the program; `Unix.select` limits a program to about 1024 descriptors;
`keyed` isn't native.

Notes for step 9 on: what to review first, besides the brief's three
lenses. The stale note "other tasks can run this handler at a dependency
call" (excl.ml, `across`) is still said for a state borrowed across a
dependency call: whether that error is still needed, now that only a
block parameter can reach the instance again, is a soundness question
for the native build, not just wording. `keyed` isn't native. A
cancelled `Proc.run` kills only its own process. The real `Proc.run`'s
looks spin under `sim`. The kill wait isn't journaled, so a replay's
cancelled task goes on at once where the recording's waited: if another
task ran meanwhile and the cancelled one makes calls in its `finally`,
the replay could go differently (it says so, strictly). `Chan.close()`
with no argument can't tell its `T` unless a call beside it does
(inference's, not `sync`'s): test_tasks.ml uses an alias, `dep Nums =
Chan<Int>`.

Notes for step 8 on: the real `Proc.run`'s wait for its process can be a
`Sched.wait_io` on a pipe a `SIGCHLD` handler writes to, as signals are
(`Sched.catch`), or a timer polling `waitpid` with `WNOHANG`; either way
`poll` reports the wake, which is the journal's poll line. `sync`'s
handlers wait in `Async.until`, as `sim.net()`'s do, and use `Async` in
their type. The crawler's `limit` is its own; `server` and `sim.net()`
need nothing more.

Notes for step 7 on: a journal's polls are `Sched.fire_due`'s wakes,
given to the journal's `polled`; I/O that `Unix.select` completes has to
be told to it the same way, its tasks in the order they're woken, and a
replay's poll then ends each such wait: a replayed `Net` call that waits
is an `awaiting` one, as `Clock.sleep` is. A signal that cancels `main`
is a cancel the task didn't ask for, so a replay sees it only where the
journal's `cancelled` line is, which the recording writes as it is. A
read's bytes are a `Bytes` value, written as a string.

Notes for step 6 on: a test's runtime is `sim.scheduler(seed)`, whose
policy is `Sched.policy` (`Sim`'s tape and clock), and its choices are
`Sched.take`'s; a journal's schedule prefix goes there, choosing the
journal's next entry's task while it can run, then the tape. The poll
lines are `single`'s timers firing (`Sched.fire_due`, from the loop when
the queue is empty). The standard library is lib/core/std_lib.ml: `sync`
(step 8) is a source to add to its `sources`, and its handlers that wait
use `Async`, as `sim_clock` does, so Core Lint lets them. A runtime is
installed in a test's root task (eval.ml, `run_installed`), so whatever
the replay installs for a test goes in `install` there.

Notes for step 5 on: each call of an operation of an instance that
`Sched.locked` says is shared and exclusive is a scheduling point under
`sim`, before `Sched.holding` takes its lock (eval.ml's `Dep_call`). A
test handler with a `var` that waits in an operation, as `sim.clock()`'s
`sleep` will, holds its instance while it waits once a task can reach it,
so every task's sleep would wait for the one before: `sim.clock()` has to
keep its time where no lock is taken (no `var`, or the scheduler's own
state), or wait in `Async.until`. `test_clock`'s `sleep` doesn't wait, so
it's unaffected.

Notes for step 4 on: an operation's call is already bracketed,
`Sched.holding inst label`, and its end is `Sched.released inst`, which
wakes `until`'s waiters; the queue for an instance in use goes there,
the woken waiter first, before the callers queued (Scheduling). Once it
does, `Task_until`'s loop that checks again after a wake (eval.ml) is
only a guard. A release build's known handlers skip `Dep_call`, so
specialize.ml's `eligible` already leaves out any handler that uses
`Async`. A handler it still knows, one with no `Async`, can be reached
by a spawned task and is called directly there, with no `Dep_call`, so
step 4's queue has to cover those calls too, or `eligible` has to leave
out every handler a spawned task can reach. `transfer` lands with step
5's virtual time.

Notes for step 3 on: `Async.until`, `tick` and `yield` are still
`unbuilt` (or return at once, in `single_runtime`); each wait is a
`Sched.wait` given what it waits for and the program's call it's at
(`Eval.at_call`). An error a task fails with first reaches anyone in
step 3 (`map`, `each`, `both`): the `= from the task` note and the
"failed too" warning are to build there. The cleanup-deadline test
takes 5 real seconds until step 5's virtual time.

Notes for step 2 on: test_tasks.ml's "[s4 accept] an operation keeps
its instance across its own calls" is missing `Clock` in its `main`'s
`uses` (it's refused today for that, not for anything step 4 builds):
step 4 fixes the test. Running `dune build` while THE CHECKS' script
runs aborts silently ("Another Dune instance"), so wait for it.

Notes for whoever resumes: a stale `_build` (from a cram run killed
part way) once made examples/just.t fail with "two tests named `replays
bug.journal`"; `rm -rf _build` cleared it. THE CHECKS' script runs `ren
test` in every folder under examples/, and `ren test` reads the folders
under one too, which is why stage 11a's programs wait in bench/11a/tasks.

## Bytes stage

The first half of "the `just`, natively" (foundations.md, Staging, item
7): string and byte code at Rust's speed in release builds, layer 3 of
formats.md (reads and writes at an offset, a cursor, `VarUInt`), and
`Map` and `Set` natively, all in the interpreter and natively, debug
and release, agreeing. Inline slices and the uncounted view (decision
17's representation B), formats (layer 2), `Table`, `Pool`, `bin`, the
world natively and native tasks are later stages; slices stay
representation A. Five steps, each green on its own:

0. **This specification,** the baseline profile, and the tests.
1. **String and byte speed,** fix by fix, each measured before and
   after in release builds.
2. **Layer 3,** with a kernel in bench/native that decodes a stream of
   length-prefixed little-endian records with a `VarUInt` field, and
   its Rust and Go twins.
3. **`Map` and `Set` natively,** `x.hash()` with them, and a kernel that
   builds, looks up, removes from and iterates a map of records keyed by
   `Int` and by `Str`, with Rust and Go twins.
4. **A review:** soundness, the spec, the docs and tooling.

**Done when** `logs_r`, `json_r`, `pages_r` and bench/native/bytes each
run within 2× of their Rust twins' time in release builds; layer 3
works in both builds and its kernel is measured against Rust and Go;
and `Map` and `Set` build natively, agreeing with the interpreter, with
their kernel measured.

This stage runs beside the data stage, which owns the parser, the type
checker beyond registering built-ins, pattern matching, and record and
variant layout in to_mem.ml. So this stage adds built-ins and runtime,
never syntax; its tests are in files of their own; and its Ren uses no
variant with several fields.

### The tests

**bench/bytes.t** runs the programs in bench/bytes/, each with a
`.expected` as bench/10d's are (what `ren run` prints, `exit N`, the
first line of stderr): `spec` says whether `ren run` is as specified,
and `native` builds each one debug (Perceus and naive) and release
under AddressSanitizer and UBSan, and debug with tcc, and checks each
prints, writes to stderr and exits as `ren run` does, with no object
alive at the end, and that `ren run --release` agrees too. A program
that doesn't build natively yet prints `not native yet` and `ren
build`'s first line. The step that lands a program changes its lines
there; none moves.

| program | what | lands in |
|---|---|---|
| `reads` | every read at an offset, each width and order, signed and not, at the first and last offset it can read; a slice's offsets its own | 2 |
| `reads_panic`, `reads_negative`, `reads_far` | a read past the end, at a negative offset, and at one so large that adding the width overflows: each panics with the same message | 2 |
| `u64_panic` | `u64_le` of 2^64 - 1 panics; `i64_le` of it is -1 | 2 |
| `writes` | every write, read back; a copy, a slice and a literal's bytes unchanged by a write | 2 |
| `writes_panic`, `writes_range` | a value that doesn't fit, and a write past the end | 2 |
| `varint`, `varint_panic` | `VarUInt` and `VarInt` written and read back at the edges; too long, too large and cut short; a negative `VarUInt` written | 2 |
| `cursor` | a framing loop, `Short` leaving the cursor where it was, `Malformed` for a `u64` too large, `skip`, `bytes`, `rest`, a cursor over a slice | 2 |
| `writes_loop`, `writes_alias` | added in step 2: writes in a loop that reads the bytes too, in place once they're unique; and a write never seen through a `Str`'s bytes, a copy kept before it, or a literal | 2 |
| `map`, `set`, `map_key` | insertion order, a key set again keeping its place, removed and set again going last, 10,000 keys grown and removed, a map changed while a loop goes over it, keys of every kind, a `key`, the collection methods | run now; native in 3 |
| `hash`, `hash_values` | `x.hash()` agreeing with `==`; its values, the same on two runs and natively | 3 |

**test/test_bytes.ml** holds what a program's output can't say: whole
panic messages with their help, the error for a write without `&`, the
cursor's error set, and `x.hash()` through `key`, each `until "b2"` or
`until "b3"` (test/helpers.ml), as test_tasks.ml's are. A step leaves
no `until` of its own number behind.

The kernels of steps 2 and 3 are added by those steps, with their twins
and RESULTS.md's numbers.

### The baseline: where the cycles go

Measured on the owner's M4 Max (macOS 15.1, Apple clang 16.0.0, rustc
1.99.1, Go 1.27.3), with nothing else building; a browser was running. The
`_r` kernels are build.sh's (bench.ren with a `main` running one of
them 20 times on its input), each built `--release`, and again with 0
rounds, whose cycles are subtracted, so a pass is (20 rounds - 0
rounds) / 20; the twins run `slices-rust 200000 20 logs_r` and the
same with 0. bytes is bench/native/bytes/main.ren whole, and its twins.
Ten runs each, Ren, Rust and Go interleaved, under `/usr/bin/time -l`;
medians, and the spread of the 20-round runs.

| kernel | Ren Mcyc a pass | Rust | Go | Ren / Rust | Ren M instructions a pass | Rust | Go |
|---|---|---|---|---|---|---|---|
| `logs_r` | 43.9 (20 rounds: 856-1096 Mcyc) | 30.8 (655-747) | 36.0 | **1.43×** | 270 | 188 | 170 |
| `json_r` | 160.0 (3141-3716) | 57.2 (1028-1214) | 95.5 | **2.80×** | 565 | 226 | 387 |
| `pages_r` | 6.29 (337-374) | 2.70 (110-123) | 4.68 | **2.33×** | 30.6 | 15.6 | 21.7 |
| bytes, whole | 2130 (2125-2131) | 1731 (1726-1733) | 2951 | **1.23×** | 2347 | 2260 | 4022 |

In instructions a byte of input: logs 28.5 against Rust's 19.8, json
47.7 against 19.0. bytes runs 821 ms against Rust's 671.

**How it was found.** Two ways, which agree. Instruments' Time Profiler
(`xctrace`, 1 ms samples) on each binary rebuilt from its emitted C with
`-g`, by the leaf function, inlined ones included; and variants of the
emitted C, each with one cost taken out, measured as above (seven
runs; not sound programs, only measurements): `nob`, `Bytes.at`
without its check; `noovf`, `+`, `-` and `*` without theirs; `noarr`,
arrays' index checks gone; `none`, all three; `push`, an array of
records' push inline, its stride a constant (below); and `-O3` for
-O2. bench/native/profile/ holds the scripts, and RESULTS.md's "Bytes
stage: the baseline" the commands that reproduce every number here.

| kernel | base | `nob` | `noovf` | `noarr` | `none` | `push` | `push` + `none` | `-O3` |
|---|---|---|---|---|---|---|---|---|
| `logs_r`, Mcyc / M instructions a pass | 44.0 / 271 | **30.4** / 170 | 41.8 / 196 | 47.8 / 270 | 50.7 / 174 | | | 36.4 / 198 |
| `json_r` | 157.7 / 560 | 145.3 / 497 | 146.0 / 515 | 139.5 / 546 | 131.1 / 462 | **91.0** / 399 | 103.7 / 311 | 132.8 / 492 |
| `pages_r` | 7.16 / 31.6 | 6.41 / 27.6 | 5.72 / 30.0 | 6.53 / 31.3 | 5.43 / 22.9 | 4.49 / 20.3 | **3.68** / 12.2 | 6.59 / 29.6 |

(`push` was measured in a second session of nine runs, where the base
was json 151.9 and pages 6.33, and Rust's twins 50.3 and 2.50.) `none`
running slower than `nob` on logs is where clang placed the loop, not
work: it runs 4 fewer instructions a byte.

**`logs_r`: the check in `Bytes.at`, and the loads around it.** Its
profile, input generation included: `ren_bytes_at` 25.5% of samples,
`ren_str_len` 19.8%, the loops' own code 26.5%, `ren_add` 13.1%.
`ren_bytes_at` is a runtime function, not `static inline`, so though
clang inlines it into the loop, its panic path, a 128-byte buffer and
an `snprintf`, comes along, and with it the loop reloads the bytes'
`len` and `data` from the object on every byte, since the panic's call
might change them as far as clang knows. Rust's loop keeps the pointer
and length in registers, and LLVM removes the check of `b[j]` for `j in
0..n` outright. Without the check (`nob`), logs runs at Rust's time,
30.4 Mcyc against 30.8, in 170 M instructions against 188: the rest is
the same scan.

**`json_r`: pushing a token.** `_platform_memmove` 30.7% and its stub
3.8%, `ren_array_push_slots_taking` 7.3%, `ren_array_grow` 4.4%,
`ren_rc` 5.1%: 51% of the samples are `&out.push(TokR { ... })`.
Each push is a call to the runtime, which tests uniqueness, calls
`ren_array_grow` (`noinline`, to test capacity) every time, and copies
the record's three words with `memcpy` of `k * sizeof(ren_val)` bytes,
where `k` is the stride read from the array, so the copy is a library
call per token. Rust's push is inline: a capacity compare and a 12-byte
store. The rest: `walk_r` 10.6%, `ren_bytes_at` 9.5%, `ren_add` 7.2%,
the tokenizer 6.0%, `equal` 3.2% (byte by byte, each read checked,
where Rust's slice `==` is a length compare and one load-and-compare).
With the push inline and its stride a constant (`push`), json runs in
91.0 Mcyc, 1.81× Rust's; with the checks gone too, 311 M instructions
against Rust's 225. Rust's token is also half the size, 12 bytes (a
`u8` and two `u32`s) against Ren's three `Int`s, 24: the twins differ
there, which is the kernel's to say, not the compiler's.

**`pages_r`: the same two.** At 400 rounds, so that the kernel
outweighs its input: memmove and its stub 29%, `ren_bytes_at` 18.1%,
`ren_add` 16.2%, the push 10.7%, `ren_array_grow` 7.7%. `push` and the
checks gone reach 3.68 Mcyc, 1.47× Rust's.

**bytes: a remainder that divides.** Ren's loops take mix 65%, fnv 19%
and smooth 14% of the samples; Rust's 64%, 23% and 11%. fnv is the same
code. mix's inner loop, `xs[i] = (xs[i] * 3 + xs[i - 1]) % 1_000_003`,
is 9 instructions in Ren and 10 in Rust, and both keep `xs[i - 1]` in a
register, but Ren's computes the remainder with `sdiv`: clang's constant
hoisting gave 1,000,003 a register, as 1,000,000 (which `ints` uses)
plus 3, so the division by a constant wasn't turned into a multiply, as
Rust's is (`smulh`, a shift and an `msub`). That `sdiv` is on the loop's
dependency chain. None of the variants moves bytes: its checks are
proved already (step 12) or off the chain.

**Overflow checks on counts.** `ren_add` is 7 to 16% of each `_r`
kernel, and most of those adds are a loop's count stepping, `i + 1`,
which bounds.ml already proves can't overflow (the count is below a
bound that is an `Int`), and which still goes through `ren_add` in the
C.

### Step 1's fixes

Each lands alone, measured before and after in release builds, and
each that removes a check says why it's sound here; Mem Lint, Core Lint
and the sanitizers keep running over all of it.

1. **`Bytes.at` inline,** as `ren_array_check` is: `static inline` in
   ren_rt.h, one unsigned compare under `__builtin_expect`, and the
   message built in a cold, `noinline` function, so the loop holds no
   panic's call and keeps `len` and `data` in registers. The same
   check, so nothing to prove.
2. **A step that can't overflow is a plain add.** Where bounds.ml marks
   a count in bounds, `i < n` holds before its step, and `n` is an
   `Int`, so `i + 1 <= n <= 2^63 - 1`. The step is emitted wrapping (it
   can't wrap), and Core Lint's [verify] checks the mark as it checks
   the index's.
3. **`b.at(i)` in bounds,** as `xs[i]` is: bounds.ml's bound learns
   `b.len()` of a `Bytes` (or `Str`'s `bytes()`), and an index that is
   the count, or a copy of it, becomes [In_bounds]. A `Bytes` changes
   only through an assignment or a `&` (layer 3's writes, from step 2),
   which the walk forgets its facts at, as it does an array's. A count
   bounded by a dominating test the loop doesn't change, `while j < n &&
   b.at(j) ...` with `n = b.len()`, is the same proof with the test as
   the loop's condition.
4. **An array of records' push inline,** its stride a constant the C
   emitter knows: a uniqueness and capacity test inline, the record's
   words stored directly, and only a full or shared array's case out of
   line (growing, or copying). The cases are the runtime's own, in the
   same order.
5. **A remainder or quotient by a constant** emitted as C's `%` or `/`
   on the constant itself, with no check: a nonzero constant other
   than -1 can't fault, so `ren_rem`'s tests are dead, and the constant
   reaches clang's division lowering before constant hoisting can hide
   it. If clang still hoists it, the fix is a barrier on the operand,
   measured either way.
6. **Comparing a range of bytes with bytes** (`equal` in the kernels,
   and `==` on two `Bytes` or `Str`s): already `memcmp` where `==` is a
   runtime call; for a loop written by hand nothing changes. If a kernel
   is still past 2× for it, that is recorded, not special-cased.

What may not reach 2× without an out-of-scope change: json's tokens
are 24 bytes against Rust's 12, and an array's growth copies 24 bytes a
token where Rust's copies 12. Sized fields in an array of records
(`kind: UInt8, start: Int32, stop: Int32`) would close it, if the
kernel were written so; step 1 measures the kernel as it is, and says.

### Step 1, as built

Each fix measured alone, before and after in one interleaved session
(ten runs; RESULTS.md, "Bytes stage, step 1", has every number and the
commands), Mcyc a pass:

| fix | `logs_r` | `json_r` | `pages_r` | bytes |
|---|---|---|---|---|
| 1, `Bytes.at` inline | 42.2 → 39.4 | 154.8 → 141.0 | 6.77 → 6.44 | 2124 → 2125 |
| 1b, a `Bytes`' length and data read before the loop | 40.2 → **32.6** | 136.6 → 136.5 | 6.70 → 7.05 | 2128 → 2126 |
| 4, push inline | 33.8 → 33.7 | 136.4 → **82.6** | 7.11 → **4.31** | 2129 → 2128 |
| 5, `%` and `/` by a constant | 33.3 → 33.5 | 86.4 → 82.8 | 4.30 → 4.30 | 2126 → 2125 |
| 2 and 3, the step and `b.at(i)` proved | 34.8 → 34.9 | 80.3 → 82.9 (366 → 353 M instructions) | 4.34 → 4.39 | 2130 → 2127 |

**All of step 1, against the baseline,** 21 runs interleaved, the
owner's M4 Max with the OS's photo analysis running (load about 4):

| kernel | baseline | step 1 | Rust | Go | step 1 / Rust |
|---|---|---|---|---|---|
| `logs_r` | 40.7 | **35.4** (20 rounds 773-894) | 31.3 (655-750) | 35.6 | **1.13×** |
| `json_r` | 158.1 | **93.6** (1514-2409) | 51.8 (985-1202) | 93.9 | **1.81×** |
| `pages_r` | 6.93 | **4.47** (294-348) | 2.62 (111-125) | 4.72 | **1.71×** |
| bytes, Mcyc whole | 2125 | **2124** (2123-2126) | 1727 (1726-1730) | 2944 | **1.23×** |

In quieter sessions earlier the same build ran `logs_r` at 1.03× to
1.04×, `json_r` 1.62× to 1.69× and `pages_r` 1.71× to 1.75×. `json_r`'s
spread is its own: twelve runs of one binary alone vary from 1.64 to
2.33 G cycles on the same instruction count, which is the kernel's
memory (its token array grows by `realloc` to 24 MB), not its code. Every
kernel is within 2× of Rust's time. The other programs of bench/native,
release, against step 0's compiler (five runs): all within 1.5% but
binary-trees, 3% slower (19.6 against 19.9 G cycles in eleven runs,
spreads overlapping), whose C differs only in two `for` steps outside
its hot path; and slices, the whole benchmark, 17% faster.

**What each fix is, and why it's sound:**

1. **`Bytes.at` inline,** as specified: `ren_bytes_at` in ren_rt.h,
   one unsigned compare, its message made in `ren_bytes_index_panic`,
   `cold` and `noinline`. The same check.
1b. **A `Bytes`' length and data read before a loop** (hoist.ml,
   "the bytes a loop reads"; Mem's `Str_data` and `Bytes_get`,
   ren_rt.h's `ren_buf_byte`). Fix 1 alone took logs only from 42 to 39:
   the loop still read the length and the data from the object before
   every byte, not because of the panic's call but because of the
   others in the loop (`equal`, `line_r`'s stores into `st`), which C
   must assume may change the object. Release builds now read both once
   before each loop that reads a byte of a `Bytes`, and the loop checks
   against that length. Sound because a string's header is written only
   when it's made, and the variable read through is a parameter or a
   `let` that nothing in the function `set`s, used in the loop, so the
   one object it holds is alive across the loop; a copy made inside, `let
   y = x`, is followed to it. Not specified in the spec's list; added
   because fix 1 didn't do what the list said it would.
2. **The step,** Core's new `Step` (bounds.ml, "steps that can't
   overflow"): `i = i + 1` as the last thing a pass of a loop does whose
   condition tests `i < e` (alone, or a side of an `&&`), with nothing
   else in the pass or the condition changing `i`, and no block that can:
   `i + 1 <= e <= 2^63 - 1`. Wider than the spec's "a count bounds.ml
   marks in bounds": no array or lower bound is needed. Emitted as C's
   signed `+`, so UBSan checks it in sanitized builds, and Mem's
   `Count_step`. Core Lint's `Bounds.verify` checks each, and the
   interpreter treats one that would overflow as a compiler bug.
3. **`b.at(i)` in bounds,** Core's new `Byte_at In_bounds`, made by
   bounds.ml of a call of `Bytes.at` it proves, as `xs[i]`: a bound
   learns `b.len()`, and the walk learns from a test that held, an `if`'s
   or a loop's condition, `j < n` of a bound or `j < a.len()`, where `j`
   is 0 or more, that `j` is in bounds of those till `j` or they change
   (the walk now forgets a fact about an index where it's assigned or
   passed with `&`). "0 or more" is new too: an `Int` local let-bound to,
   and only ever assigned, literals of 0 or more, lengths, such locals,
   and sums of them, found as a greatest fixpoint ([nonneg]); that's
   json's tokenizer's `i` and `j`, which step by 1, 4, 5 and to each
   other. A checked sum that overflowed would panic, so a sum is never
   negative. The cycles barely moved: after 1b the checks are a compare
   on registers, off the loops' chains.
4. **Push inline,** `ren_array_push_slots_taking_k` in ren_rt.h, its
   stride the struct's words: unique, an owner and with room, the words
   are stored and the length counted; otherwise the out-of-line push,
   which tests the same cases in the same order.
5. **`%` and `/` by a constant** other than 0 and -1 are C's own. As the
   spec feared, clang 16 still hoists 1,000,003 as 1,000,000 plus 3 and
   divides with `sdiv`: bytes didn't move. A barrier can't help, since
   hiding the constant is what clang does already; the multiply by the
   magic number written by hand into the C (`smulh`, a shift, a fix-up,
   `msub`) ran slower, 2188 Mcyc against 2125, so it isn't emitted. The
   remainder stays where bytes' last 23% is; Rust's newer LLVM doesn't
   hoist a divisor.
6. Nothing: `equal` is a loop written by hand, and no kernel is past 2×
   for it.

**A bug in bounds.ml found and fixed:** a count passed with `&`, `bump(&i)`,
wasn't counted as an assignment, so `xs[i]` after it was marked in
bounds; the interpreter called it a compiler bug and a native build read
past the array. A pass with `&` now counts as an assignment that isn't
a step, everywhere a fact is decided (bench/bytes/proofs_ref.ren). And a
versioned loop's copy is now walked before its binders are renamed, so
what bounds.ml knows of them holds in the copy.

**What's left above Rust's time,** none of it past 2×: json's tokens
are three `Int`s, 24 bytes, against Rust's 12, so its array copies and
stores twice the bytes (sized fields would close it, an `Array` of
records with `UInt8` and `Int32` fields, if the kernel were written so);
pages' records are four `Int`s, 32 bytes, against Rust's two `u32`s
and two `u16`s, 12, and its `u16` reads are two checked `at`s each, which layer 3's `u16_le`
(step 2) makes one load; bytes' remainder, above.

### Layer 3: the API

Settled here, in formats.md's style: the width and the byte order in the
name, `le` or `be` always written. Decided with the owner: a read at an
offset the program computed panics past the end, with the offset and the
length, as `xs[i]` does, since a bad offset is a bug; a read through a
cursor fails with `Short(at, need)`, since running out of input is an
error the program handles; `u64_le` and `u64_be` return an `Int` and
panic on 2^63 or more (through a cursor, `Malformed`), and `i64_le` and
`i64_be` read the same bits as a signed `Int`, which is how a 64-bit
hash or checksum is read (decision 15: a 64-bit hash stays an `Int`); a
value that doesn't fit a write panics, as storing into a sized integer
does.

**Reads at an offset,** methods of `Bytes`, each `fn(self, at: Int) ->
Int`:

| | unsigned | signed |
|---|---|---|
| 1 byte | `u8(at)` | `i8(at)` |
| 2 | `u16_le(at)`, `u16_be(at)` | `i16_le`, `i16_be` |
| 4 | `u32_le`, `u32_be` | `i32_le`, `i32_be` |
| 8 | `u64_le`, `u64_be`, panicking at 2^63 or more | `i64_le`, `i64_be` |

- Out of range, `at < 0` or `at + width > len` (computed so that it
  can't overflow: `at > len - width`), a read panics: `index 8 is out
  of bounds for bytes of length 8` for a byte, as `b.at(8)` says, and
  `4 bytes at 5 are out of bounds for bytes of length 8` for a wider
  one.
- `u64_le` past `Int`: `` `u64_le` at 0 read 18446744073709551615,
  which is more than an `Int` holds``, with the help ``read its bits as
  an `Int` with `i64_le` ``.
- Natively, a read is an unaligned load (`memcpy` of the width, which
  clang makes one `ldr`) and, for `be`, a byte swap
  (`__builtin_bswap32`): Rust's `from_le_bytes`, Go's
  `binary.LittleEndian`. Its check is `Bytes.at`'s, so step 1's
  proofs remove it where they can.

**Writes at an offset,** each `fn(inout self, at: Int, x: Int)`: `&b.set_u8(at, x)`, `set_i8`,
`set_u16_le`, `set_u16_be`, `set_i16_le`, `set_i16_be`, `set_u32_le`
... `set_i64_be`. Out of range panics as a read does; a value that
doesn't fit panics with the sized types' message, `65536 doesn't fit in
a `UInt16`, which holds 0 to 65535` (`set_u64_*` takes any `Int` from
0, `set_i64_*` any). A write changes the `Bytes` in its variable:

- **`Bytes` become writable.** Until now nothing wrote a string's bytes
  once made (ren_rt.h, `ren_str`). A write is a write of a value, as
  `xs[i] = v` is: in place if the `Bytes` is unique and an owner (count
  1, `root` NULL, as `ren_array_writable` asks), and otherwise into a
  copy of its bytes first: a shared one, a slice (whose range is
  copied, so its root is never written), and a literal's (a static,
  count 0, never unique). So `let copy = b` then `&b.set_u8(0, 1)`
  leaves `copy` as it was, and `"abc".bytes()` stays `abc`. `Str` gets
  no writes. Rule U of the runtime model covers it; Mem Lint checks the
  write consumes its bundle as it does an array's write in place.
- **`Bytes.zeros(n)`,** `n` zero bytes, to write into; `n < 0` panics
  as an array's `reserve` does.

**`VarUInt` and `VarInt`:** LEB128, 7 bits a byte, least first, the top
bit set on all but the last; `VarInt` zigzag-encodes first (`(x shl 1)
xor (x shr 63)`), so every `Int` fits.

- `&b.set_varuint(at, x) -> Int` and `&b.set_varint(at, x) -> Int`
  write the shortest form and return how many bytes they wrote; a
  negative `VarUInt` panics, `-5 doesn't fit in a `VarUInt`, which
  holds 0 to 9223372036854775807`, and so does one with no room, as
  any write does.
- `Bytes.varuint_size(x)` and `Bytes.varint_size(x)`, from 1 to 9 and
  1 to 10, to size a buffer first.
- Reading one is only through a cursor, since how long it is depends on
  the bytes: a `VarUInt` of more than 10 bytes is `Malformed` (``a
  `VarUInt` is at most 10 bytes``), one of 2^63 or more too (``a
  `VarUInt` of 2^63 or more is more than an `Int` holds``), and a
  `VarInt` whose tenth byte is more than 1 (``a `VarInt` of more than
  64 bits is more than an `Int` holds``). A longer form than needed
  (`81 00` for 1) is read, as Go's `binary.Uvarint` and protobuf's
  readers read it.

**The cursor,** `ByteCursor`, an opaque prelude type written in Ren,
`{ b: Bytes, at: Int }`, made by `b.cursor()`. It's a value (decision
17: a cursor that borrows its input needs no lifetime), so copying one
and reading the copy is how a program tries a record and keeps the
cursor where it was if the record isn't all there yet. Every read is
`inout self` and fails with formats.md's `FormatError`, which the
prelude declares as formats.md does:

```ren
pub type FormatError = ! Short(at: Int, need: Int)
                       | Malformed(at: Int, path: Str, why: Str)
                       | UnknownTag(at: Int, tag: Int)
```

- `try &c.u8()`, `i8`, `u16_le` ... `i64_be`, as the reads at an
  offset, each at the cursor and moving it past what it read;
  `try &c.varuint()`, `try &c.varint()`; `try &c.bytes(n) -> Bytes`, a
  slice of the next `n`; `try &c.skip(n)`.
- `c.at()`, where it is; `c.left()`, how many bytes are after it;
  `c.rest()`, those bytes, a slice.
- **A read that fails leaves the cursor where it was.** `Short(at,
  need)`: `at` where the read began, `need` how many more bytes it
  needs, the width less what's left (1 for a `VarUInt` cut short). That
  is what a framing loop reads more by. `Malformed(at, "", why)`, with
  an empty path, since layer 3 has no fields; layer 2 fills it.
  `UnknownTag` is layer 2's.
- `n < 0` given to `bytes` or `skip` is a bug, and panics.
- Its reads check the room left and then read at an offset, so the
  offset read's own check is one step 1's proofs remove, or one compare
  more.

**Where it differs from formats.md, and why.**

- **`at` is the offset in the bytes the cursor was made from,** not in
  the whole buffer a slice was cut from, which formats.md's errors
  promise. The interpreter's `Bytes` keep no root (a slice is a copy
  there), so the offset in the root isn't known in both builds; a
  program that wants it makes the cursor on the whole buffer and
  `skip`s. Layer 2's views, which carry their root, are where the
  promise is kept. strings.md has since made this the rule for views
  too: offsets count from the value, or from a base given with
  `from:`.
- **Floats (`f32_le` ... `f64_be`), odd widths (`u24_le`) and bit
  fields are left to layer 2,** which needs them and decides how a
  read NaN is carried; layer 3 composes them from the integer reads
  meanwhile.
- **A range as a place, `&b[a..b].set_u32_le(...)`,** isn't promised
  here: writes are on a `Bytes` variable. Whether `&` on a range of
  `Bytes` works is decision 17's, as it is for arrays.

### Step 2, as built

Layer 3 runs in the interpreter and natively, debug and release, as the
API above says, and bench/bytes.t's eleven programs are as specified in
every build, with no object alive at the end.

**What's built in, and what's Ren.** The reads and writes at an offset,
`Bytes.zeros` and the `VarUInt` and `VarInt` writes and sizes are
intrinsics (intrinsic.ml's `Bytes_read`, `Bytes_write`, `Bytes_zeros`,
`Bytes_set_var` and `Bytes_var_size`, each read or write named by its
`access`: the width, signed or not, `le` or `be`), since their panics
carry numbers a panic in the prelude's Ren can't make natively
(`lib_panic` takes only a message written there). The cursor,
`FormatError` and `b.cursor()` are the prelude's Ren (`ByteCursor`, with
`pub type Bytes = builtin` for its one method), so the interpreter and
native builds run the same code. The interpreter's are builtins.ml's
"layer 3"; natively each read is Mem's `Bytes_load`, ren_rt.h's
`ren_bytes_load`, given the width, sign and order as constants that
clang folds: a bounds check, a `memcpy` of the width and, for `be`,
`__builtin_bswap` (a loop of shifts under tcc). A `u64` read is an
`i64`'s, then `U64_read`, a check of its own whose site has the help,
so a `u64` read out of range doesn't say to read it with `i64_le`.

**Writes** go through the variable's cell, as `push` does: Mem's
`Bytes_store` and `Bytes_set_var`, which rc.ml makes `_taking` as it
makes a push's, writing in place when the bytes are unique and an owner
(count 1, `root` NULL) and otherwise into a copy first, which goes back
in the cell (`ren_bytes_writable`). A literal's count is 0, so it's never
written. Mem Lint checks the cell changes as a push's does
(`Mem.changes_cell`). The checks run in the interpreter's order: the
value fits, then the offset, then the copy.

**Choices the spec left open.**

- `Bytes.zeros(n)` with `n < 0` panics ``` `Bytes.zeros(-1)`: a length
  is 0 or more ```.
- A `VarUInt` or `VarInt` write with no room panics as a write of its
  size does: `2 bytes at 9 are out of bounds for bytes of length 10`
  for `300`.
- `varuint_size` of a negative number panics as `set_varuint` does.
- A `VarUInt`'s tenth byte with its top bit set is ``at most 10 bytes``
  before it's ``2^63 or more``; reading stops there, so an eleventh
  byte is never read.
- A cursor's `bytes(n)` and `skip(n)` of `n < 0` panic ``a cursor's
  `skip` of a negative count``, the prelude's message, since a panic in
  its Ren takes only one written there.
- **Each of a cursor's reads says it fails with all of `FormatError`,**
  as the spec says, though a read can only be `Short` or `Malformed`:
  so `fn record(inout c: ByteCursor) -> Record ! FormatError` checks,
  and a framing loop reads the same at layers 2 and 3. The checker wants
  a signature's errors exact, so the prelude's `short(at, need)` fails
  through a `Result<Unit, ! FormatError>`, which brings the whole set.
- `ByteCursor`'s field is `pos`, not `at`, so it doesn't share a name
  with its method `at()`; it's opaque, so no program sees it.

**`Str.from_utf8` natively.** bytes.t's `writes` and `cursor` call it,
so it's built: Mem's `Utf8_valid`, ren_rt.c's `ren_utf8_valid`, which
rejects what OCaml's `String.is_valid_utf_8` does (an overlong form, a
surrogate, past U+10FFFF), and then the bytes are the `Str`, or the call
fails with `InvalidUtf8`.

**A soundness bug, found and fixed.** Step 1's hoist.ml read a `Bytes`'
length and data before a loop when nothing `Set` the variable. A write
through `&` doesn't `Set` it, it takes its address, and when the bytes
are shared the write puts a copy in the variable: a loop that read
`b.at(i)` and wrote `&b.set_u8(i, ...)` read the old bytes after the
write (bench/bytes/writes_loop.ren: 0 in release builds, 36 in `ren
run`). A variable whose address is taken (Mem's `Addr`) now counts as
set there. bench/bytes/writes_alias.ren writes bytes a `Str`, a
borrowed parameter, a field and an array's element hold, through a
function's `inout` too, in every build.

**A test corrected.** step 0's `cursor.ren` matched `Err(e) =>
print(e)`, which the checker refuses (an error is a value only inside
its `Result`); it prints the `Result` instead, `Err(Short(15, 2))`.

**The kernel, `frames`** (bench/native/frames): a million
length-prefixed little-endian records, each a `u32` length, a `u8`
kind, a `VarUInt` id of 1 to 6 bytes, an `i64` time, an `i32` value and
a name of 0 to 12 bytes, 27.5 MB, written with writes at an offset and
decoded through a cursor 20 times; the twins hold a `&[u8]` with a
cursor of their own over `from_le_bytes`, and a `[]byte` with
`encoding/binary`. Measured as the `_r` kernels are (profile/build.sh and
measure.py), Mcyc a pass:

| build | Ren | M instructions | Rust | Go | Ren / Rust |
|---|---|---|---|---|---|
| the cursor as first written, its room checked by a method of the cursor | 134.2 | 931 | 22.2 | 51.3 | 6.0× |
| the room checked on the cursor's numbers, inline in each read | 91.0 | 550 | 22.2 | 51.7 | 4.1× |
| and the prelude's small functions inlined by C (below) | **43.9** | 320 | 22.3 | 51.1 | **1.97×** |
| as committed, `print`'s path left out of that (below), 11 runs | **46.1** | 320 | 22.3 | 51.4 | **2.06×** |

The last row's run, the same binaries, Mcyc a pass: logs_r 34.5 (Rust
33.0, Go 34.9), json_r 87.0 (51.6, 93.1), pages_r 4.39 (2.56, 4.59).
frames is 2.06× Rust, a hair past the 2× the other kernels keep, and
1.12× faster than Go; RESULTS.md has the commands.

Where the cycles went: a read of the cursor was a call of a function
that returns a status, its value through a pointer, which clang left
out of line, since it's called from many places; inlined, it's its two
checks, the room left and the offset's own, the checked add of the
cursor's position, and the cursor's record made again with its count's
test (setting a field of an `inout` record builds the record anew,
to_mem.ml's, which is the data stage's). **The prelude's small functions
are inlined** in release builds (emit_c.ml, `small_prelude`): one of
the prelude's, with no loop, not recursive, of at most 40 statements,
making no block or handler, calling none, and not writing to the
console, is `static REN_INLINE` (ren_rt.h: `inline
__attribute__((always_inline))`), as Rust's std marks its own
`#[inline]`. Only C is told, so nothing a program computes changes.
`print`'s path is left out because inlining it was measured to hurt:
with it, pages_r ran 6.1 Mcyc a pass against 4.6 and json_r 97.1
against 90.6 (the same C otherwise, 11 runs each), `print` grown into
the function that runs the kernel and clang then declining to inline
the kernel into it. Without it, the other kernels' C changes only in
`Console.real`'s two one-line constructors, run once, and `vec`'s
`Array.sum`, which ran 4.39 against 4.39 G cycles (five runs each);
`nbody` 7.14 against 7.14.

What's left against Rust: its reads check the room once, and its
position's add isn't checked (release Rust doesn't check overflow);
Ren's read checks the room and then the offset, and its add is checked,
and setting the cursor's position builds its record again. Those are
what would take the last 3% to 2×: one room check a read, proved to
cover the offset's, and a field set in place on an `inout` record (the
data stage's).

### `Map` and `Set` natively

**Meaning:** the interpreter's (table.ml), which operators.md states:
iteration in insertion order; setting a key that's there keeps its
place and its first key (the first of keys equal by their `key`) and
changes its value; removing one and setting it again puts it last;
`==` is the same entries in any order, and a map's hash is its entries'
hashes added, so the same in any order; the collection methods are the
prelude's, written in Ren over the pairs, which build natively once the
built-ins do. A map is a value: a loop over it goes over the map as it
was when the loop began, whatever the body sets or removes, since the
loop holds the map and a change then copies it, as the interpreter's
tables are never changed in place.

**Representation,** Python's dict and Rust's indexmap: one object, its
header, then:

- `len`, the live entries; `used`, the entries' slots used, removed
  ones included; `cap`, the entries' room; `shift`, log2 of the index's
  size; `removed`, how many entries are gone.
- `entries`, a dense array of `{ hash: UInt64, key, value }` in
  insertion order, each `key` and `value` stored as an array of records
  stores its fields (release builds: unboxed by the key's and value's
  layouts, as an `Array` of a record is; debug builds: a word each,
  counted through descriptors). A `Set`'s entries have no value.
- `index`, a table of 2^shift slots of `int32_t`, each an entry's
  number, -1 empty and -2 a removed entry's tombstone, probed linearly
  from the hash's top bits. It's never more than 2/3 full, counting
  tombstones. Its slots are 4 bytes until a map passes 2^31 entries,
  where they become 8 (not built until something needs it; it panics
  there instead, with the reason).
- **Finding** a key: hash it, probe, and at each live slot compare the
  stored 64-bit hash first and call `==` only on a match.
- **Setting** a key that's there writes its value in place; a new one
  appends an entry and fills a slot. **Removing** one marks its entry
  gone (its hash slot set to a value no live hash has, 0, live hashes
  being forced to 1 or more) and its slot a tombstone, and drops its key
  and value. When `used` reaches `cap`, the entries are compacted if a
  third or more are gone, keeping their order, and the index rebuilt;
  otherwise both double. Iteration walks `entries` in order, skipping
  the gone.
- **Uniqueness,** rule U: a change in place needs a count of 1, and a
  shared map is copied first (entries with each object counted again,
  and the index), as an array is. Perceus, reuse and Mem Lint treat a
  map as an object with fields they don't walk, as an array's elements;
  `--stats` counts its buffers as an array's.

**Hashing,** decided with the owner:

- **A map's hash is seeded.** `Map` and `Set` hash with a fast 64-bit
  hash of the rapidhash class (wyhash's 128-bit multiply-and-fold, on
  8 bytes at a time) mixed with a seed the runtime draws from the OS
  (`getentropy`) when it starts, as Go's maps do, so keys chosen by an
  attacker can't be made to collide. Nothing a program sees depends on
  it: iteration is in insertion order. Under `sim` and replay the
  interpreter's seed is fixed (from the run's seed), so a test's timing
  reproduces too; native builds have no `sim` yet.
- **What's hashed** is what `==` compares: through a type's `key` if it
  has one; an `Int` as its 64 bits; a `Float` as its bits, `-0.0` as
  `0.0`, a NaN panicking where it's hashed (decision 15); a `Str` or
  `Bytes` as its bytes and length; records, tuples and variants by
  their fields in order with the constructor's index, each part's hash
  mixed in; an `Array` its elements and length; a `Map` or `Set` its
  entries' hashes added. Release builds hash `Int`, `Str` and `Bytes`
  keys inline and the rest through the descriptor walk `==` already
  uses (`ren_equal_any`), a `ren_hash_any` beside it; debug builds walk
  descriptors for all of them.
- **`x.hash()`,** the derived hash a program can call, on any type
  with `hash`, returns an `Int`, and has **no seed**: the same value on
  every run and in every build, so what's printed or journaled stays
  reproducible. It is walk.ml's `hash` with the seed 0 (its
  `fixed_hash`), FNV-1a's step over the same walk, specified by that
  code; the native build computes the same bits (bench/bytes.t checks
  `hash_values` against `ren run`). The map's internal hash differs
  from it, which no program can observe. Step 3 adds the method to
  every type the checker gives `hash` (a built-in method, as `show`
  is a function), and an error with a help for a type without one.

### Step 3, as built

`Map`, `Set` and `x.hash()` run natively, debug and release, as the
section above says, and bench/bytes.t's `map`, `set`, `map_key`, `hash`
and `hash_values`, and step 3's own `map_edges` and `take_panic`, are
the same as `ren run` in every build, with no object alive at the end;
build.t has NaN keys, `x.hash()` of a NaN and `sort`'s NaN.

**The runtime** (ren_rt.c, "maps and sets") is the representation
above: `ren_map`, its header, `len`, `used`, `cap`, `shift` and `width`
(3 words an entry, 2 for a set), the dense `entries` of `{hash, key,
value}` and the `int32_t` index, probed linearly from the hash's top
bits, -1 empty and -2 a removed entry's, at most 2/3 full counting
those; when `used` reaches `cap` the entries are compacted if a third
are gone, and otherwise doubled. A hash kept is never 0, so a gone
entry is one whose hash is 0. Finding a key compares the stored hash
first. A change in place needs a count of 1 (`ren_map_writable`); a
shared map is copied first. Perceus, Mem Lint and `--stats` see a map
as an object (`REN_TAG_MAP`) whose entries they don't walk; the
descriptors are `REN_D_MAP` and `REN_D_SET`, so `==` (the same entries
in any order), ordering, `show` (`Map.of([...])`), the NaN walk and
hashing (entries' hashes added) go through maps as through anything
else. Mem's operations are `Map_new`, `Map_len`, `Map_find` (an entry's
number, or -1), `Map_value`, `Map_set`, `Set_add`, `Map_remove` (each
with its `_taking` form, which rc.ml's `erase` gives Perceus, through
the variable's cell as `push`'s), `Map_of`, `Set_of`, `Map_entries`,
`Map_keys`, `Map_values` and `Hash_fixed`. `m.get(k)` is a find, then
`Some` of the value made as Core's constructor is, or `None`; a `for`
over a map is over `Map_entries`, an array of its pairs as they were
when the loop began, so the body's changes copy the map, as the
interpreter's do.

**Hashing.** A map's hash is a wyhash-class 64-bit hash (`ren_mum`, a
128-bit multiply and fold, with a fallback for tcc, which has no
`__int128`) over 8 bytes at a time, mixed with `ren_map_seed`, which
`ren_run` reads from /dev/urandom when the program starts (an address
if it can't). `Int` and `Str` keys are hashed inline in
`ren_key_hash`; anything else walks its descriptor as `==` does
(`ren_hash_in`), through a `key`, `-0.0` as `0.0`, a NaN panicking with
"`hash` of a NaN" where it's hashed. `x.hash()` is `Hash_fixed`,
`ren_hash_fixed`: walk.ml's FNV-1a walk with no seed, the same bits,
which hash_values.expected pins. The interpreter's seed is fixed, for
the whole process, under `ren test` and `ren replay` (walk.ml,
`fix_seed`), and drawn from its random state otherwise.

**`x.hash()` in the checker** is a built-in method of every type that
has `hash` and no field or method of that name (infer_expr.ml,
`derived_hash`): the prelude's `hash_of`, `Intrinsic.Hash`, registered
where it's called, as `show` is a function of the prelude's.

**`key` natively.** A type with a `key` of its own that isn't the
value itself was refused natively. Now a type with no parameters whose
`key` can't fail has it called from the runtime's walks: its
declaration (`ren_decl`) holds `key`, a wrapper emit_c.ml makes
(`key_wrapper`) that takes the value as a word and gives the key as one,
and `keyd`, the key's descriptor, so `==`, ordering and hashing go
through it, natively as in walk.ml. Such a type, and its key's type,
are kept boxed if they'd be structs, since the walk passes words. A
generic type with a `key` is still refused.

**Built because the programs needed them,** which the spec hadn't
listed: the collection methods are the prelude's Ren, and they call
`Array.take`, `drop` and `sort`, and `map_key`'s key calls `Str.lower`.
So a failed `assert` of the prelude's is native, saying what eval.ml's
`unmet` says (`` `take` needs `n >= 0`, but `n` is -3 ``) at the
program's call, through Mem's `Panic_str`; `Array.sort` is native,
`ren_array_sort`, a stable merge sort through the elements' descriptor,
which panics on a NaN as `ren run` does ("`sort` compared a NaN"); and
`Str.lower` is `ren_str_lower`.

**Where it differs from the spec above.**

- Keys and values are words in both builds, counted through their
  descriptors, not unboxed by their layouts in release builds: a
  record or tuple type that would be a struct is kept boxed when it's a
  map's key or value (to_mem.ml's `word_only`, as a type variable's
  values are). A `for` over pairs of two scalars, `(Int, Int)`, still
  gets them as two words an element (`Map_entries true`), a struct each.
  The kernel below didn't need more; a map of small structs would.
- `Int`, `Str` and `Bytes` keys aren't hashed in the program's own
  code: release and debug builds both call the runtime, which takes
  `Int` and `Str` keys inline without the walk, and everything else
  through the walk.
- The seed comes from /dev/urandom, not `getentropy`, which the
  runtime's units (no system headers) can't declare portably; and the
  interpreter's fixed seed under `ren test` and `ren replay` is one
  constant, not the run's seed.
- Past 2^31 - 1 entries a map exits with an error saying it isn't built
  yet, rather than a panic at the program's site.

**The kernel,** bench/native/maps: 200,000 accounts, a record with a
`Str` name, kept in a `Map<Int, Account>` keyed by a scattered id (some
the same) and a `Map<Str, Int>` keyed by name, each round built, 400,000
lookups, a third removed, both iterated in order into a checksum; the
Rust twin keeps std's `HashMap` (SipHash) of each key to its entry's
place in a `Vec`, in insertion order, with holes compacted as Ren's
are (indexmap's shape, no crate), names `Rc<str>`; the Go a `map` the
same way. All three print the same checksum. RESULTS.md, "Bytes stage,
step 3", has the numbers: a round, release, Ren **108** Mcyc, Rust 157,
Go 255 (0.69× Rust); the debug build takes 2.9 s to Go's 0.85.
That's against SipHash. Against Rust with FxHash or aHash, the strings
measurements put the same map at 1.02–1.05×: the same speed, not
faster ([strings.md](strings.md#representation)). Measured again in part two
("Bytes stage, part two", "The baseline"), on an x86_64 cloud
container: 0.66× of this twin, and **0.99×** of the same twin with
FxHash (bench/native/maps/rust/fx.rs).

### Step 4, the review

Adversarial programs found three holes in bounds.ml's proofs, each
reached by `xs[j]` and by `b.at(j)`: the count's is older than this
stage (step 14's), the other two came with step 1's tests. Each read past its
buffer in every native build and stopped the interpreter with an
internal compiler error ("a byte proved in bounds is out of them"):

- **A block that changes the index.** A test `j < n` taught that `j`
  was in bounds, and a call to `fn() => j = j + 100` mid-branch moved
  `j` where no assignment the walk sees did. `learn_test` now learns
  nothing of a `j` a block assigns or passes with `&` ([unsteady]), as
  `learn` and the `Le` case already refused an array a block changes.
- **A block that steps the count.** `counter` took `j` as the loop's
  count when every assignment to it was `j = j + 1`, one of them in a
  block called mid-pass, so `j` reached `n` before the pass's last step.
  `counter` now refuses an [unsteady] count, as `steppable` (fix 2's
  proof) already did.
- **The second side of an `&&`.** `j < b.len() && shrink(&b)` learned
  from the first side and kept it through the second, which shrinks
  `b`. `learn_test` now forgets what the second side changes before it
  learns from it: `learn_test fi (forget (learn_test fi env c1)
  (changed c2)) c2`.

The proofs above are as stated with those conditions: an index learned
from a test, or a count, is never a local a block changes, and what a
test's first side teaches holds in its second only for what the second
doesn't change. bench/bytes/proofs_block, proofs_block_array,
proofs_block_step, proofs_block_step_array, proofs_shrink,
proofs_shrink_array and proofs_bump pin each, bytes and arrays, and
panic as `ren run` does in every build, under the sanitizers and tcc
(bench/bytes.t). The release C of every bench/native kernel, bench/*.ren
and every example is the same, byte for byte, before and after the fix,
so no measurement moved.

The docs: README's status and roadmap row now say what this stage
built; stdlib.md says what `x.hash()` gives and that a map's own hash
is a different, seeded one. formats.md's layer 3 names didn't change;
nothing parses differently, so the grammar is untouched.

What the review leaves, by severity:

- **Medium: frames is 2.06× Rust,** not under 2× (Step 2, as built):
  the cursor's room check and its copy-on-fail shape, without inline
  slices, cost the last 3%.
- **Low: a map's keys and values are words in release builds,** a
  struct boxed, and a generic type's `key` isn't native (Step 3, as
  built): refused with an error, never wrong.
- **Low: bytes' remainder stays `sdiv`** under clang 16 (Step 1).
- **Low, not this stage's: journal.t's timing tests flake under load,**
  at the baseline too.

### Where this stage may differ from foundations.md

- The cursor's `at`, and the formats deferred, above.
- Step 3 keeps a map's keys and values as words in release builds
  too, a struct's type boxed, makes `key` native only for a type with
  no parameters, and built `assert` in the prelude, `Array.sort` and
  `Str.lower` natively, which the spec hadn't listed (Step 3, as built).
- Step 2 made `Str.from_utf8` native (layer 3 needed it, the spec
  hadn't said), fixed hoist.ml's soundness bug with `&` (Step 2, as
  built), and inlines the prelude's small functions in C, which the
  spec's list didn't have; frames lands at 2.06× Rust, not under 2×.
- Step 1 added fix 1b, hoisting a `Bytes`' length and data out of a
  loop, which the spec's list didn't have; widened fix 2 to any loop
  whose condition tests `i < e`; and left fix 5's remainder as `sdiv`,
  measured (Step 1, as built).

### Progress log

| step | commit | what's done | what's left |
|---|---|---|---|
| 0 | "Bytes stage, step 0" | this section; the baseline (RESULTS.md, bench/native/profile/); bench/bytes/ and bench/bytes.t, test/test_bytes.ml, each marked for its step | steps 1 to 4 |
| 1 | "Bytes stage, step 1" | `Bytes.at` inline; a `Bytes`' length and data read before a loop (hoist.ml); Core's `Step` and `Byte_at` (bounds.ml), verified by Core Lint; push of a struct inline; `%` and `/` by a constant; bounds.ml's `&` bug; bench/bytes/proofs*, test_bytes.ml's b1; every kernel within 2× (logs 1.13×, json 1.81×, pages 1.71×, bytes 1.23×) | steps 2 to 4; bytes' `sdiv` (clang 16) |
| 2 | "Bytes stage, step 2" | layer 3: reads and writes at an offset, `Bytes.zeros`, `VarUInt`/`VarInt`, `ByteCursor` and `FormatError` in the prelude, in the interpreter and natively; `Str.from_utf8` native; hoist.ml's `&` bug; the prelude's small functions inlined in C; bench/native/frames with Rust and Go twins (Ren 46.1, Rust 22.3, Go 51.4 Mcyc a pass, 2.06×); test_bytes.ml's b2 on | frames' last 3% to 2×; steps 3 and 4; journal tests flake under load (not this step's) |
| 3 | "Bytes stage, step 3" | `Map` and `Set` natively, debug and release (ren_rt.c's `ren_map`, indexmap's shape), seeded with a wyhash-class hash; `x.hash()` in the checker, the interpreter and natively, unseeded; `key` natively for a type with no parameters; the prelude's `assert`, `Array.sort` and `Str.lower` natively; bench/native/maps with Rust and Go twins (Ren 108, Rust 157, Go 255 Mcyc a round, 0.69×); test_bytes.ml's b3 on | step 4; keys and values unboxed by layout in release builds; a generic type's `key` natively; journal.t's `recipes` timing fails under load, at the baseline too (not this step's) |
| 3, review fix | "Bytes stage, step 3: refuse a type with its own show and key natively" | a type with a `show` and a `key` of its own is refused natively again, as before step 3 (to_mem.ml keeps `key` in `key_fns` apart from `own_members`, so the `show` isn't lost); bench/bytes/show_key.ren | as step 3 |
| 4 | "Bytes stage, step 4: the review" | bounds.ml's three holes (an index or count a block changes, the second side of an `&&`), bench/bytes/proofs_block*, proofs_shrink*, proofs_bump; README's status and roadmap row; stdlib.md's `x.hash()` (Step 4, the review) | frames' last 3% to 2×; the low items in Step 4 |
## Data stage

ADTs made excellent, so that modelling with data is the obvious way and
the fast way (foundations.md, Staging, item 5; language.md §1, §2, §3
and §6). Record update, `{ ..order, status: Paid }`; record patterns and
`let { id, lines } = order`; variants with several fields by name, one
field positional; or-patterns, `as` and `let ... else`; variant types,
`Order.Placed`; the errors that teach the model, with missing arms
printed as code; an operation called on a description only when its
handler is stateless, and `Shape` and `Expr` as ADTs; and the layout
fixes of decision 14, measured. Everything here is sequential, so every
feature runs in the interpreter, `ren run` and `ren test`, and natively,
debug and release, and the two agree. Nine steps, each green on its own,
as 10d's and 11a's were:

0. **This specification,** its tests (The tests, below), and the
   inventory of what by-name variants break.
1. **Record update, record patterns and `let { .. } =`.**
2. **By-name variants,** and every program and doc moved to them in the
   same step, so main never has two styles for long.
3. **Or-patterns, `as` and `let ... else`.**
4. **Variant types.**
5. **The errors that teach the model,** and `todo`.
6. **Descriptions:** the stateless-only rule, and `Shape` and `Expr` as
   ADTs in docs, examples and benchmarks.
7. **The layout fixes,** each measured before and after, then the
   milestone: the ADT-first interpreter kernel against Rust.
8. **A review** of the whole stage: soundness, the spec, the docs and
   tooling.

Each step takes its feature through the whole pipeline: lexer and
parser, Resolve, inference and Exhaust, Core and Core Lint, the
interpreter, Mem IR and Mem Lint, the C it emits in both builds, the
tree-sitter grammar and its corpus (with differential.py agreeing with
the compiler's parser), the Zed queries, the error messages with their
help, and the documents that describe it (language.md's "What Ren has
today" table, operators.md, errors.md, the README). What follows settles
what each step builds; a step that finds something here unsound or
unworkable says so instead of building something else, and records what
it chose in "Where the data stage may differ from language.md", below.

### The tests

**test/test_data.ml is the specification,** as test_tasks.ml was 11a's,
with the same `until "sN"` (test/helpers.ml): a test still to land holds
its target, `~want` for a program that runs or `~says` for the lines an
error or a panic must hold, its headline and its help, and its
`[%expect]` holds today's output after `(until sN)`. When the program
prints its target the test fails, saying the step has landed, and **the
step turns it on**: written plainly, `run src` or `check_error src`, its
`[%expect]` the target, the whole message for a `says`. Each error below
is one such refusal test. A step leaves no `until` of its own number
behind. A test whose program works already, and which a step must not
break, is written plainly now: error tags staying positional (s2),
or-patterns of `fail` (s3), a stateless handler called as a method and a
stateful one installed beside it (s6).

**bench/data/ holds a program or two for each step that has native
relevance,** each with a `.expected` as bench/10d's and bench/11a's
(what `ren run` prints, `exit N`, the first line of stderr), and
bench/build.t's last section runs them through `spec`. The step that
lands one says `as specified` there and adds it to the loops that check
native builds against `ren run`: `same` (debug, Perceus and naive, under
the sanitizers), `release`, and `tcc_same`. Step 7's three kernels ran
from the start, so they said `as specified` already; step 7 added them
to the loops once it had measured them.

| step | expect tests (test/test_data.ml) | bench/data |
|---|---|---|
| 1 | update from a record and a named one; the base, then the fields in order; an update in a loop; an update's type; across record types; record patterns with literals, named, renamed, nested; `let { .. } =`; in a `for` and a block's parameter; fourteen refusals | update |
| 2 | built and matched by name; `..`, renames, nesting; one field positional, unlabelled too; one named field in braces; another module's; tags stay positional; fifteen refusals, the missing arm by name among them | byname |
| 3 | or-patterns, nested; `as`; `let ... else` with `fail`, `break`, a block and an `if`; a `let` of a one-variant type; `fail` or-patterns; the end-to-end program; nine refusals | orpat |
| 4 | `as` binds the variant type; fields, patterns, update and `var` on one; back to the sum; returned, stored, passed; `==`, order, `hash` and `show` borrowed; a generic sum's; an or-pattern's `as` is the sum; seven refusals | variants |
| 5 | a field of a sum, of several variants, of every variant; missing arms to paste, by name, and errors (six refusals); `todo` panics, and leaves a `let ... else` | todo_panic |
| 6 | three refusals of a stateful description called as a method; a stateless one still called; a stateful one installed beside | shapes (the ADT) |
| 7 | none | nested, rows, optional (one per fault), interp (the milestone); the last lines of nested, rows and optional print fields, not the value, whose `show` boxed its type (step 7's choices) |

The end-to-end program is test_data.ml's "[s3 accept] a program, end to
end": language.md's "A program, end to end" without `|>` and wirings, in
one module, run by `ren test`: domain types with by-name variants
(`OverAmount { min, off }`, `Open { customer, lines }`), a policy ADT
with `apply`, an opaque `Order`, the dependencies `Orders` and
`Discounts`, a checkout workflow with a `try` on each step that can
fail, `let Open { lines, .. } = cart else fail Empty`, record patterns
in a `for`, and test handlers made of data, `fixed(d: Discount)`. It
needs steps 1 to 3.

**Existing tests that change,** each by the step named:

- step 1: none; record patterns and `..` only parse where nothing did.
- step 2: every site in the inventory (below), with each output that
  shows a by-name variant, which `show` now writes in braces,
  `Rect { w: 2, h: 3 }`; Exhaust's missing patterns of one, written
  `Rect { .. }` (test_exhaust.ml, test_errors.ml, examples/examples.t
  where they name a by-name variant); test_infer.ml's labelled-argument
  errors (`Pt(x: 1, 2)`, "mixing is an error", which becomes the
  by-name error) and `Pro(seat: 5)` (a label on one field, now its own
  error); test_resolve.ml's `P(x, x)`, which becomes `P { a: x, b: x }`
  and keeps its "bound twice" error.
- step 3: test_resolve.ml's two or-pattern messages, "this alternative
  doesn't bind `id`, which the first one does" and "`n` is bound by this
  alternative, but not by the first one", which become "`id` is bound in
  `...` but not in `...`"; infer_msg.ml's `alternative` ("`x` is an `Int`
  here, but a `Str` in the first alternative") for `fail` or-patterns,
  which becomes the new one; test_collections.ml's three "takes apart
  only a tuple, of names and `_`" errors, whose `let` one becomes
  "`Some(x)` might not match, so this `let` needs an `else`" and whose
  lambda one keeps its help with the new wording (Patterns, below).
- step 5: every "missing:" error's help (test_exhaust.ml, test_errors.ml,
  test_modules.ml, test_tasks.ml, examples/examples.t), which gains the
  arms to paste; and `todo` is a keyword, which no program uses as a
  name today.
- step 6: bench/10d/dispatch_mix.ren, whose `o_seen` (a `var`) is called
  as a method, and whose `t_count` is: their loops install them with
  `with` instead, and its `--explain-dispatch` listing in build.t is
  redone; bench/10d/methods.ren's handler with state called as a method,
  the same; test_descriptions.ml's tests of a handler with state called
  as a method, which become refusals with the new error.

### The inventory

Every site by-name variants break, counted by a throwaway script (not in
the repo) over every Ren source: examples/, bench/ (bench/native's
programs and bench/build.t's heredocs), the strings of test/*.ml (an
`[%expect]`'s counted apart, as "printed"), lib/core/prelude.ml and
std_lib.ml, the tree-sitter corpus, and every ```` ```ren ```` or
unlabelled block of every `.md`. A *declaration* is a variant with two
or more fields written in parens; a *use* is a construction or a pattern
of one, positional or labelled; a *label* is a one-field variant built
with its label, `Pro(seats: 5)`, which step 2 also refuses. Error tags,
after `fail` or `!`, aren't counted: they stay positional. The variants
with several fields today are `A`, `Add`, `B`, `Box`, `C1`, `C2`,
`Cons`, `Enterprise`, `Line`, `More`, `Mul`, `N`, `Named`, `Nd`, `Node`,
`P`, `Pow`, `Pt`, `R`, `Received`, `Rect` and `Sent`, in tests and
benchmarks; the prelude and the standard library have none.

| where | declarations | uses | labels | sites |
|---|---|---|---|---|
| bench/ (packed, review_lists, review_values, sized, trmc, trmc_panic, values) | 19 | 81 | 0 | 100 |
| bench/native (binary-trees, blocks, cfold, deriv, nested, nqueens, rbtree) | 10 | 93 | 0 | 103 |
| bench/build.t (its heredocs) | 2 | 10 | 0 | 12 |
| bench/10d, bench/11a | 0 | 0 | 0 | 0 |
| examples/ (infer.ren, plans.ren) | 0 | 0 | 3 | 3 |
| examples/bank (`Sent`, `Received`) | 2 | 5 | 0 | 7 |
| examples/shop (`Pro(seats: 3)`) | 0 | 0 | 3 | 3 |
| examples/vm (`Cons`) | 1 | 3 | 0 | 4 |
| examples/ the rest | 0 | 0 | 0 | 0 |
| test/test_native.ml | 4 | 34 | 0 | 38 |
| test/test_eval.ml | 2 | 7 | 3 | 12 |
| test/test_blocks.ml | 2 | 8 | 0 | 10 |
| test/test_infer.ml | 2 | 2 (+1 printed) | 1 (+1 printed) | 7 |
| test/test_deps.ml | 1 | 3 (+6 printed) | 0 | 10 |
| test/test_resolve.ml | 1 | 2 (+1 printed) | 0 | 4 |
| test/test_modules.ml | 0 | 0 | 2 (+1 printed) | 3 |
| test/test_ops.ml | 1 | 0 | 0 | 1 |
| test/test_syntax.ml | 0 | 0 | 1 | 1 |
| test/ the rest | 0 | 0 | 0 | 0 |
| lib/core/prelude.ml, std_lib.ml | 0 | 0 | 0 | 0 |
| editors/tree-sitter-ren/test/corpus (types.txt, expressions.txt) | 1 | 0 | 1 | 2 |
| README.md (`Pro(seats: 5)`) | 0 | 0 | 1 | 1 |
| errors.md (the bank's `Sent(t.amount, t.to)`) | 0 | 2 | 0 | 2 |
| formats.md, language.md, every other doc | 0 | 0 | 0 | 0 |
| **total** | **48** | **258** | **18** | **324** |

Besides these: bench/native/dispatch/gen.py writes Rust's `Add(a, b)`,
not Ren's, and no generator writes a Ren variant of several fields;
bench/build.t has nine lines of output that show one (`Cons(...)`,
`Node(...)`), which `show` changes; and formats.md's one "label",
`'Q' => Query(sql: CStr)`, is a format's `case`, which is out of this
stage. language.md is already in the new forms; its "What Ren has today"
table names the old ones on purpose. `Shape` and `Expr` modelled as
dependencies, step 6's, are in deps.md (one), test_descriptions.ml (one,
`Shape`), bench/10d/shapes.ren, dispatch.ren (`Shape`, `Expr`) and
dispatch_mix.ren (`Area`, `Size`, `Label`), and bench/native/dispatch
(`Shape2` to `Shape32`, and `Node`, the GoF Interpreter).

### The grammar

The forms this stage adds, in parser.ml's notation (its header comment
gains them):

```
ctor      := UIDENT                                  (no fields)
           |  UIDENT "(" [IDENT ":"] type ")"         (one field, positional;
                                                       a label documents it)
           |  UIDENT "{" field, ... "}"              (by name: one field or more)
type      := tyname ["." UIDENT] ["<" type, ... ">"]  (`Order.Placed`, a
                                                       variant type; the
                                                       arguments are its sum's,
                                                       `Tree.Node<Int>`)
primary   := ...
           |  "{" ".." expr {"," finit} "}"            (an update: the base's
                                                       type; the expected one
                                                       only when the base's
                                                       isn't known yet)
           |  tyname "{" [".." expr ","] finit, ... "}"
                                                     (a record, or a by-name
                                                       constructor: Resolve
                                                       decides)
           |  ctor_ref "{" [".." expr ","] finit, ... "}"
                                                     (`Order.Placed { ... }`:
                                                       always a constructor)
           |  "todo"                                 (any type; panics)
finit     := IDENT [":" expr]                        (punned without `:`)
stmt      := ...
           |  "let" pattern "=" expr "else" body      (refutable; the value is
                                                       one line, and `else` on
                                                       it)
           |  "let" pattern "=" body                 (a pattern that always
                                                       matches)
pattern   := alt ["as" IDENT]                         (`as` binds looser than `|`)
alt       := single {"|" single}
single    := "_" | IDENT | INT | "-" INT | "true" | "false"
           |  ctor_ref ["(" pattern, ... ")"]
           |  tyname "{" fpats "}"                   (a record, or a by-name
                                                       constructor: Resolve
                                                       decides)
           |  ctor_ref "{" fpats "}"                 (`Order.Placed { .. }`)
           |  "{" fpats "}"                          (a record, of the type
                                                       matched)
           |  "(" pattern ")"                        (grouping)
           |  "(" pattern "," pattern ["," pattern] ")"
fpats     := fpat {"," fpat} ["," ".."] | ".."
fpat      := IDENT [":" pattern]                     (punned without `:`: binds
                                                       the field's name)
arm       := (pattern | fails) ["if" expr] "=>" body (unchanged: `fails` are
                                                       `fail` patterns joined by
                                                       `|`, never with `as`)
lparam    := ... | ("(" | "{" | UIDENT) pattern [":" type]
                                                     (taken apart: one that
                                                       always matches)
for       := "for" [IDENT ","] pattern "in" ...      (the same)
```

**`..` and punning.** In a value, `..base` comes first and once, then
the fields, each `f: v` or `f` alone for `f: f`, each at most once:
`{ ..order, status: Paid }`, `Placed { ..draft, id, total }`, and `{
..o }` alone, a copy. `base` is any expression, `{ ..orders[i], paid:
true }`. In a pattern, the fields come first, each `f: p` or `f` alone,
which binds `f`, and `..` last and alone, "the rest", which binds
nothing. The lexer's `DOTDOT` is the token in both, as in `0..n` and
`..e`. So `..` means "the rest" in both directions (language.md §2), and
which one is the context's: a pattern's `..` is followed by `}`, a
value's by an expression.

**`as` has no ambiguity.** `as` is already a keyword (`AS`), in two
places: after a `with` item, `with queue() as Jobs`, where it follows an
expression and names a dependency; and after an import's path, `import
billing/stripe as pay`, at the top of a file. A pattern's `as` follows a
pattern and is followed by a lowercase name, and patterns appear only
after `match`'s indent (an arm, before `=>`), after `let` (before `=`),
after `for` (before `in`), in a block's parameter list, and inside
other patterns. No expression context and no pattern context overlap: a
`with` item is never a pattern and a pattern never contains an
expression (a guard, after `if`, is outside it). A format's `as`
(language.md §12, `lsn: UInt64 as Lsn`) is inside a format's body,
another item's grammar altogether, and comes in a later stage; it
follows a field kind, never a pattern. In the tree-sitter grammar the
three are three rules, `as_pattern`, the `with` item's `alias`, and the
import's, each in its own context.

**`Name { ... }` is a record or a constructor, by what's in scope.** The
parser reads `Name { ... }`, in a value or a pattern, as it reads a
record literal today (ast.ml's `Record (Some t, ...)`, and the new
patterns and updates likewise), and Resolve decides, by a new
`braces_name` beside `declared_type` (resolve.ml): **if `Name` is a type
in scope, it's that record; otherwise it's the by-name constructor
`Name`,** found by inference through the type, as a bare constructor is
today. A type in scope with a by-name constructor of the same name in a
sum the module can name bare is **refused**, never picked: "`Placed` is
a record type here, and a constructor of `Order` too", whose help says
to write `Order.Placed { ... }` for the constructor or `{ ... }` with the
type left out for the record (found through the expected type or the
fields, as today). An update's, `Placed { ..base }`, says `{ ..base }`
with the type left out is the base's own type, since that's an update's
target when it's left out (step 8). Resolve knows both from the declarations it already
reads: its own module's `types` and the interfaces of its imports.
`Type.Name { ... }` and `m.Type.Name { ... }` are always constructors;
`m.Name { ... }` always a record.

**`let ... else`.** The value is parsed by `parse_expr`, so an `if` in it
takes its own `else` first: `let Some(m) = if c then a else b else fail
E` is unambiguous. The `else` is on the `let`'s line, and its body is a
line or an indented block, as `if`'s `else` is. `let x = e else ...`
with a plain name is the same form, and refused because the pattern
always matches (Errors, below). **No `if let`:** `if let` is a parse
error with a help.

**Variant types in a type.** `Order.Placed` is the parser's `tyname`
then `.` and an uppercase name; `stripe.Order.Placed` with a module
first. Ast's `ty` gains `TyVariant of 't * ident * 't ty list`, the
sum, the variant's name and the sum's type arguments, written after the
variant: `Tree.Node<Int>`, since a constructor has its sum's parameters
and is written `Tree.Node { ... }` in a value. `Tree<Int>.Node` isn't
Ren.

### The AST

ast.ml gains, each a constructor the compiler then points at every
`match` that needs it:

- expressions: `Update of { target : 't target option; base : expr;
  fields : (ident * expr) list }`, `{ ..base, ... }` and `Name { ..base,
  ... }`, where `'t target = Into_type of 't | Into_ctor of 't
  ctor_ref`; `Con_named of 't ctor_ref * (ident * expr) list`, a
  by-name constructor, fields in the order written; `Todo`.
- patterns: `PRecord of 't option * ('b, 't) fields`, `PCon_named of 't
  ctor_ref * ('b, 't) fields`, where `fields = { fpats : (ident *
  pattern) list; rest : bool }` (a punned field is a `PVar` of its
  name), and `PAs of ('b, 't) pattern * 'b`. `POr` takes any patterns,
  not only `fail` ones.
- statements: `Let_tuple` becomes `Let_pattern of { pat; value; else_ :
  expr option }`.
- types: `TyVariant`, above. Declarations: `ctor` gains `ctor_named :
  bool`, true for braces.

The parser makes `Record (Some t, ...)`, `PRecord (Some t, ...)` and
`Update { target = Some (Into_type t); ... }` of a bare `Name { ... }`,
and Resolve turns each into `Con_named`, `PCon_named` or `Into_ctor`
when `Name` isn't a type (`braces_name`). `Iface.ctor` gains `cnamed :
bool`, from `ctor_named`, which every later pass reads.

### Record update (step 1)

`{ ..base, f: v, ... }` takes every field of the target the fields don't
give from `base`. **The target** is the type named, `Order { ..o, ... }`,
or else the base's type, which inference has to know at that point (as
a field read does: `infer_field`'s rule); `{ ..o }` with `o`'s type
unknown is the existing "which type is this" error of a record literal
whose type can't be found (`no_record_fits`), since nothing else could
say. **The rules**, checked in `Infer_expr.infer_update`, a new function
beside `infer_record`:

- `base` is a record (`Record` or a visible `opaque { ... }`), or from
  step 4 a variant type. Anything else is an error; a sum is step 4's
  error, which teaches the match.
- Each field given is the target's, at its type, once.
- Each field of the target not given is the base's, of the same type
  (the target's type's, with its arguments: a generic record's update
  can change a type argument only by giving every field of that type).
- **Strict: nothing is dropped behind your back.** Every field of the
  base is the target's: `Placed { ..s }` where `s` has a `carrier`
  `Placed` lacks is an error, whose help says to name the fields to
  keep. This only matters when target and base differ, across two
  record types or two variants.
- An opaque record updated outside its module is the error reading its
  field is, "`Order`'s representation is private to `order`".
- Evaluation: `base` first, once, then the fields in the order written,
  as a record literal's are (Core's `Record` is "in the order written").

**Lowering** (lower.ml, a new `update`) binds the base to a local, then
each given field's value to a local in order, and builds the target:
`Let (b, base, Let (v1, e1, ... Record (p, fs)))` where `fs` are the
target's fields in declaration order, each the given local or `Field
(b, p, f)`. A constructor target builds `Con (p, c, fs)` the same way.
No new Core node: reuse (reuse.ml) already pairs a dead object with the
allocation of one of its size where it dies, so a unique base is built
over in place. Step 1 checks that bench/data/update.ren's loop of 1000
updates allocates once (`ren build --release --stats`: one allocation
for the record, not 1000), and adds the pairing to reuse.ml if it
doesn't.

### Record patterns (step 1)

`{ f: p, g, .. }` matches a record of the type matched, `User { id, .. }`
one of the type named, field by field; `..` says the rest is left out.
Nested patterns go anywhere a field's pattern does, `Seg { from: Pt {
y: 0, .. }, .. }`. Inference (`bind_pattern`) finds the record type from
the type matched, or, if that isn't known yet, through the fields named,
the one visible record type with at least those fields (`through_type`
with a `fits` of "has every field named", which is "exactly these" when
there's no `..`). Exhaust treats a record as a constructor with one
form, as it treats a tuple ([Tuple n] today): `head` gains the record's
path and field names, and its fields are its declared ones, a field the
pattern leaves out an [Any]. **A pattern in a `match` arm, or a `let
... else`, names every field or ends in `..`;** a pattern in a binding
position, `let`, `for` or a block's parameter, may leave fields out
(Where the data stage may differ). Core gets `PRecord of Path.t *
pattern list`, every field in declaration order, a `PWild` where the
pattern left one out; Core Lint checks it's the type's record, its
fields' patterns at their types. The interpreter matches a `VRecord`'s
fields by name; natively it's each field's read, as `PCon`'s fields are
without the tag test.

**`let { id, lines } = order`** is a `Let_pattern` with no `else`, which
lowers as `Let_tuple` does now (`take_apart`): a one-arm `Match`. Its
pattern has to always match, which Exhaust checks with the types known
(Patterns that always match, below). A record pattern is allowed in a
`for`, `for { qty, price, .. } in lines`, and as a block's parameter,
`fn({ qty, .. }) => qty`, as a tuple pattern is, with the same rule.

### By-name variants (step 2)

**A variant's declaration decides its spelling, once.** `Free` has no
fields. `Flat(off: Money)` or `Flat(Money)` has one, positional; its
label, if written, documents it (errors and help name it, and step 5's
field errors find it), and isn't written where it's built or matched.
`OverAmount { min: Money, off: Money }` is by name, required for two
fields or more and allowed for one, `Draft { lines: Array<Line> }`. The
parser (`parse_ctor_decl`) reads both, and refuses parens with several
fields.

**By-name construction is a record literal.** `Rect { w: 2, h: 3 }`
takes its fields in any order, each once, punned or not, exactly as a
record literal does today, with its errors ("this `Rect` is missing
`h`", "`Shape.Rect` has no field named `z`", "there are two fields named
`w`"). It's checked in a new `Infer_expr.infer_con_named`, which finds
the constructor as `infer_con` does (`find_ctor`, by the expected type,
or the one visible type that has it, or `Shape.Rect`), then checks the
fields as `infer_record` does, against the constructor's. It lowers to
Core's `Con`, the fields in declaration order after binding each value
in the order written (as an update's). Positional and labelled
construction of a by-name variant, `Rect(2, 3)` and `Rect(w: 2, h: 3)`,
are errors whose fix-it writes the by-name form, the arguments given
their fields' names in order (`Infer_lookup.ctor_shape`, which today
checks labels). A labelled one-field construction, `Flat(off: m)`, is an
error whose fix-it is `Flat(m)`; one in braces, `Circle { r: 2 }`, too.
Labelled construction in any order in parens isn't added: it would be a
third spelling (language.md §2, "Left out").

**By-name patterns.** `Rect { w, h }`, `Rect { w, .. }`, `Rect { w:
width, .. }`, `Rect { w: 0, .. }`: as a record pattern, the constructor
found as a `PCon`'s is (`bind_pattern`), its fields named. It lowers to
Core's `PCon` with every field, a `PWild` for one left out; so Exhaust,
Core Lint, the interpreter and native code see what they see today.
Exhaust's `head` gains the field names of a by-name constructor, and
`show_space` writes it in braces, its [Any] fields left out and `..`
after the rest: `Rect { .. }`, `Rect { w: Some(_), .. }`. A positional
pattern of a by-name variant, `Rect(w, h)`, is an error whose fix-it
writes it by name: a subpattern that's a name equal to its field's is
punned, `_` is left out with `..` at the end, and any other is `f: p`.
`..` in parens, `Some(..)`, is a parse error.

**Error tags stay positional.** A tag's payload, `! Short(account:
AccountId, by: Money)`, `fail Short(a, b)` and `fail Short(_, by) =>`,
isn't a variant: tags are structural and compose across libraries
(errors.md), and formats.md (signed off) writes `fail Short(_, need)`.
Labelled `fail Short(account: a, by: b)` keeps working, as today.
Tuples stay positional.

**`show` writes a by-name variant as it's built,** `Rect { w: 2, h: 3 }`,
its fields in declaration order, in the interpreter (shown.ml's `Ctor`
case, given the field names) and natively (ren_rt.h's `ren_ctor_info`,
whose `fields`, today "a record's field names; NULL for a sum", holds a
by-name constructor's names too, and the walk writes braces where it's
non-NULL). `assert`'s diff (shown.ml's `Ctor` case of the diff) writes
it the same way, `Rect { w: 2, ... }`.

**The migration** is step 2's: every site of the inventory, the outputs
that show a by-name variant, the tree-sitter corpus, and each doc's
code, in the same commit as the language change, so main never has two
styles. A throwaway script in the scratchpad may do the mechanical part;
it isn't shipped. Each `Sent(t.amount, t.to)` becomes `Sent { amount:
t.amount, to: t.to }`, and each declaration `Sent(amount: Money, to:
AccountId)` becomes `Sent { amount: Money, to: AccountId }`. A
benchmark's Rust and Go twins don't change; its checksum doesn't.
bench/native/bytes/wide.ren, which has to build with 82ed3d1's compiler,
has no variant of several fields and stays as it is.

### Or-patterns, `as` and `let ... else` (step 3)

**Or-patterns** go anywhere a pattern does, nested, `Some(Pro(_) |
Team(_))`. Every alternative binds the same names (Resolve, `pattern`'s
`POr` case, for every or-pattern, its two messages replaced by one:
"`n` is bound in `A(n)` but not in `B`", the alternatives written as
`show_pattern` writes them), at the same types (Infer, `bind_pattern`'s
new `POr` case, as `bind_fail`'s: "`n` is an `Int` in `A(n)`, but a
`Str` in `B(n)`", which replaces `Infer_msg.alternative` for `fail`
or-patterns too). A `fail` pattern and a value pattern don't combine,
as today. Core's `POr` already exists and binds the same `var`s. Exhaust
gives `space` an `Or of space list`, and `specialize` and `default`
expand one in the first column into a row per alternative (Maranget
2007, or-patterns); each alternative is checked useful against the arms
above and the alternatives before it, so one that matches nothing new
is "this alternative never matches". Natively, to_mem lowers a `POr`
nested in a constructor by trying each alternative in turn on the same
scrutinee, with the bound variables assigned in each (as `fail`
or-patterns are matched today).

**`as`.** `p as x` matches what `p` does and binds `x` to the whole of
it. It binds looser than `|`: `A | B as x` names the whole; `(A as x) |
B` needs the parentheses, and then fails the same-names rule. `x`'s type
is what's matched, except that a by-name constructor's pattern, `Placed
{ .. } as p`, binds its variant type, `Order.Placed` (step 4; until
then, the sum). Core gets `PAs of pattern * var`; Core Lint checks the
`var`'s type is the pattern's, or its variant type (Variant types,
below). The interpreter binds the scrutinee itself; natively the
variable is the scrutinee's value, dup'd as a `PVar`'s is, so `as` never
copies. A `fail` pattern with `as` is refused with today's "a `fail`
pattern can't bind the whole error to a name" and its help (the parser,
`parse_arm_pattern`).

**`let PATTERN = e else LEAVE`.** The pattern may be refutable; when it
doesn't match, `LEAVE` runs, and it has to leave: **`fail Tag(...)`,
`break`, or `todo`** (step 5), or a block whose last line leaves, or an
`if` with an `else` whose branches both leave, or a `match` whose every
arm leaves (Resolve, a new `leaves : Parsed.expr -> bool` on the
syntax, so it's checked before types). Ren has no `return`, and no
expression a program writes panics with any type but `todo`: `assert
false` is a `Unit`, and `lib_panic`, a library's since the services
stage's step 9, isn't a way to leave. A `break` there leaves the innermost loop, as Resolve already
checks a `break` is in one. The pattern's names are bound after the
`let`, for the rest of the block, as a `let`'s are. It lowers to a
`Match` of two arms, the pattern then the rest of the block, and `_`
then `LEAVE`. Exhaust checks the pattern alone: one that always matches
can't have an `else` ("the `else` never runs"), and one that might not
needs one.

**Patterns that always match.** A `let` without `else`, a `for`'s
pattern and a block's parameter take apart only what always matches: a
name, `_`, a tuple, a record, a constructor of a sum with one, `as` of
one, and these nested. Today the parser decides it (`binding_pattern`,
`irrefutable`), which it can't for a record or a one-variant sum, so
Exhaust decides it from step 3, with the types known: the pattern is
exhaustive for its type alone. The parser's `might_not_match` goes, its
two messages Exhaust's (Errors, below). Until step 3 the parser lets a
record pattern through `binding_pattern` (step 1 needs it), and
Exhaust checks those.

### Variant types (step 4)

**A variant with named fields is a record type, `Order.Placed`,** of
exactly its fields, and nothing else has a variant type: a positional
variant, `Flat(off: Money)`, has one field, which its pattern takes out.

- **In Types and Ty,** a new type form: types.ml's `TVariant of Path.t *
  string * ty list` and ty.ml's `Variant of Path.t * string * ty list`,
  the sum's path, the constructor's name and the sum's type arguments.
  It unifies only with itself, the same sum and constructor and
  arguments that unify (unify.ml): never with its sum, with no
  subtyping and no conversion. Ty prints it `Order.Placed`, the sum's
  name as `Resolve.type_name` writes it, then the constructor, then its
  arguments, `Tree.Node<Int>`; every pass that walks a `ty` (subst,
  generalize, canonical, apply, the printers, Infer_written, the
  interfaces) treats it as `Con` of the sum would be, keeping its
  constructor.
- **Written** `Order.Placed` (Infer_written, from `TyVariant`), checked
  there: the sum is a sum type, the constructor is its, and is by name.
- **Bound only by `as`** on a by-name constructor's pattern: `Placed {
  .. } as p`. An or-pattern of several constructors binds the sum, as it
  binds what's matched. A pattern matched against a value of a variant
  type is a record pattern of its fields, or its own constructor's
  pattern, which always matches.
- **A record type for everything a record is:** field reads, `p.id`
  (`field_access`, from the constructor's fields, recorded as a new
  `Field_of_variant (sum, ctor)` in inference's `found`); record
  patterns; update, `{ ..p, total: x }`, an `Order.Placed`; `var p` and
  `p.total = x`, an update of the variable.
- **Back to the sum is explicit:** `Placed { ..p }`, the update with the
  constructor as its target, an `Order`. **Constructors always build the
  sum:** `Placed { id, lines, total }` is an `Order`, everywhere,
  whatever's expected, so `fn f() -> Order.Placed = Placed { ... }` is a
  type error whose help says where a variant type comes from.
- **No methods of its own** (methods on one variant are later):
  `p.total()` where `total` is `Order`'s is an error whose help writes
  `Placed { ..p }.total()`; no implicit conversion.
- **`==`, `hash`, order and `show` are the sum's, borrowed.** Infer_reqs
  answers a requirement of `TVariant (s, _, args)` as of `TCon (s,
  args)`, through the sum's `key` if it has one; so two `Order.Placed`
  with one id are equal if `Order`'s `key` is its id. `show` prints the
  sum's value, `Placed { id: 1, ... }`.

**In Core, a value of a variant type is its sum's value,** the same tag
and fields, so variant types cost nothing, unique or not:

- `PAs (q, v)` with `v.ty = Variant (s, c, args)` where `q` is `PCon (s,
  c, _)` at `Con (s, args)`: `as` binds the scrutinee itself.
- `Con (s, c, fs)` may have type `Variant (s, c, args)`: what `{ ..p,
  total: x }` builds.
- `PCon (s, c, ps)` may match a `Variant (s, c, args)`, its own
  constructor only, which always matches; natively the tag isn't
  tested.
- `Field (r, s, f)` and `Update (r, f, v)` take an `r` of type `Variant
  (s, c, args)`, the field `c`'s, at its type: a field read at a known
  constructor.
- A new kind, `Of_variant of expr`, the conversion back: its operand a
  `Variant (s, c, args)`, its type `Con (s, args)`. It's the identity in
  the interpreter, and natively the same Mem variable, no code: what
  `Placed { ..p }` with nothing else given lowers to.
- `describe` (core.ml) keeps a `Variant`'s constructor, `Known
  (Variant ...)`, or `Applied_variant (s, c, ds)` for one of a generic
  sum's with the function's type variables in it, since a dependency's
  key at `Order.Placed` isn't one at `Order` (step 8); a walk shows,
  compares and hashes it as the sum (walk.ml, shown.ml, `Ty.as_sum`),
  and a `Derived` dictionary of a `Variant` is its sum's.

**Core Lint** checks: a `Variant (s, c, args)` names a sum `s` with a
by-name constructor `c` and as many arguments as `s` has parameters;
`PAs`'s variable has the pattern's type or, for a by-name `PCon`, its
variant type; a `Con` or `PCon` at a `Variant` is of that constructor;
`Field` and `Update` of a `Variant` name a field of its constructor;
`Of_variant` goes from a `Variant` to its own sum; and `same` never
equates a `Variant` with a `Con`.

**Natively** a `Variant` has its sum's layout (to_mem.ml's `layout`
and `plain_layout` map it to `Con (s, args)`'s), and a field of one is
read from the constructor's slot or field, with packing (`record_fields`
and `record_shape` gain the constructor's fields and places, from the
sum's shape for that tag: an object's `ren_ctor_info.at`, or a struct's
slots from `small`). A variant type's descriptor is its sum's,
`REN_D_NAMED` of the sum's declaration, but for its `var`, its
constructor's tag plus one (mem.ml's `D_variant` and `Of_variant`),
which only `ren_desc_same` reads, so an evidence's key tells
`Order.Placed` from `Order` and every walk is the sum's. The specializer
keys copies of generic code by the variant type, as its descriptors do
(step 8; keying by the sum would make the key inside the copy the
sum's).

### The errors that teach the model, and `todo` (step 5)

**A field asked of a sum** (`field_access`, where it says "`.w` needs a
record" today): if some of its variants have the field (a by-name one,
or a positional one whose label is it), "`Shape` is a sum type; only
`Rect` has `w`" (or "only `Rect`, `Frame` and `Ring` have `id`"), and the
help writes the `match` to paste, the receiver as written, the
variants that have it in one arm with `|`, and `_ => todo`; the help
is "take it from `Ring` with a `match`:" for one variant and "take it
from them with a `match`:" for several:

```
error: `Shape` is a sum type; only `Ring` has `r`
  ┌─ test.ren:7:27
7 │ fn f(s: Shape) -> Int = s.r
  │                           ^
  help: take it from `Ring` with a `match`:
      match s
        Ring { r, .. } => r
        _ => todo
```

If every variant has it, at one type, the help says to hoist it:
"every variant of `Shape` has `id`, but a sum type has no fields", help
"hoist it into a record, `type Shape = { id: Int, kind: ShapeKind }`, or
write a method that matches each variant" (the sum's name and `Kind`,
the field's type). A sum none of whose variants has it keeps today's
error.

**A `match` that misses cases** (Exhaust, `check_match`): today's error,
its help ending in `:`, then the arms to paste, each `PATTERN => todo`,
indented as the arms are: up to three, the missing patterns
`show_space` writes, and a `_ => todo` after them if a fourth may be
missing. Today's help "add an arm for `X`, or a `_ =>` arm for the
rest" becomes "add the missing arms, or a `_ =>` arm for the rest:";
the `fail` one, "add the missing arms, or a `fail _ =>` arm for the
rest, or pass them on with `try match`:", its arms `fail Late(_) =>
todo`; the others keep their text, with `:` and the arm. The editor code
action that pastes them is later.

**Code in a help.** Diag.t gains `code : string list`, lines printed
after the help, each indented four spaces under `help:`'s text and
padded as the other lines are (diag.ml's `pieces_indexed`), so a
message's lines stay aligned; `Diag.make` and `Diag.error` take
`?code`. Each line is one `~says` line for a test, which only asks that
the line be in the message.

**`todo`** is a keyword (token.ml's `TODO`, the lexer, the parser's
`primary`, tree-sitter's keywords and Zed's highlights), an expression
of any type (a fresh type variable, as `fail`'s is), which panics where
it's reached: "panic: reached a `todo`", at the `todo`. It lowers to
the intrinsic `Lib_panic` given that message, of the expected type,
which every build already has (natively too: 11a's `lib_panic`, said at
the program's call). It's the only panicking expression of any type a
program writes, so it's what "a panic" in `let ... else` is. No program
uses `todo` as a name today.

### Descriptions (step 6)

**Calling an operation on a description works only for a stateless
handler** (foundations.md, decision 3). A handler is **stateful** if its
state has a `var` or a `finally`; decision 3's other two, state that can
fail to start and `next`, are already refused at the call by their
types (`method_fails`, `method_over`, infer_expr.ml's `desc_method`).
This is decision 3's list, not to_mem's: the native build calls a
handler's arm directly only if it has no state words at all, no
`finally`, no `next` and isn't generic (`To_mem.method_code`, and
dispatch.ml's `stateless`, the code generator's word for it), and
installs it for the call otherwise, which, with no `var` and no
`finally`, means the same.

**The check is the linked program's,** since which handlers a
description may be is a closed-world fact: a library calls `r.handle(req)`
on routes its users declare (decision 4). A new pass, lib/lower/
stateless.ml (`Stateless.check : Core.program list -> unit`), runs in
`Driver.linked`, after the modules are linked and before anything runs
or builds, so `ren run`, `ren test` and `ren build` refuse the program
(`ren check`, of one module, can't see it). It reads:

- each method call on a description, which Lower records in
  `Core.program`'s new `method_calls` (the dependency, the operation,
  the receiver as written and the call's location, from Infer's
  `Calls_op`, which gains the receiver's text);
- each handler of each dependency, a function whose body is a `Handler`,
  stateful if its body makes a cell (`Prim (New_cell, _)`) or its
  `Instance` has a `finally`;
- which handlers' descriptions are kept: every use of a handler's
  function but as the callee of a `With`'s or `With_handler`'s item,
  directly or `Narrowed`. A description `with` installs where it's made
  never reaches a method call.

A method call on a description of `D` is refused if any kept handler of
`D` is stateful: "`c` may be a description of `counter`, which keeps
state, so it isn't called as a method" ("which has a `finally`" for a
`finally`), with the note "a call as a method makes a fresh instance,
so its state would start again at each call", and the help, "install
it: `with c in Area.area()`". This removes language.md's `counter()`
trap, and method syntax on a description always means a pure dispatch.

**`Shape` and `Expr` become ADTs** wherever docs, examples and
benchmarks use them to model data: deps.md's "Descriptions, the only
stored code" example becomes a library's routes, with a sentence
pointing to the ADT for shapes; bench/data/shapes.ren is
bench/10d/shapes.ren's `Shape` as an ADT; and bench/data/interp.ren
(step 7) is the `Expr` one. **Benchmarks that measure description
dispatch keep a dependency, over something a library would really
store:** bench/10d/shapes.ren's and bench/native/dispatch's `Shape`s
become codecs (`dep Codec2 = cost: fn() -> Int`, and so on, in
bench/native/dispatch/gen.py and its output, their arithmetic and
checksums unchanged; the Rust and Go twins keep their names, which
nothing compares), bench/10d/dispatch.ren's `Shape` and `Expr` become
`Codec` and `Pipe` (a stage that holds the stages it feeds, recursing
through its own dependency as `Expr` did), with build.t's
`--explain-dispatch` listing renamed to match, and dispatch_mix's
`Area`, `Size` and `Label` become `Codec`, `Width` and `Name`.
bench/native/dispatch's `Node` stays: it's the `dyn` side of the
milestone's comparison, research/dispatch.md's Interpreter pattern as
descriptions, which step 7 measures against the ADT. test_descriptions.ml's
`Shape` becomes a `Codec` too, each arm's arithmetic kept so its
numbers stay, and its comment loses "Ren's answer to `dyn Trait`"
(decision 3 is reframed).

### The layout fixes (step 7)

language.md found three faults by reading to_mem.ml; step 7 fixes each,
release builds only (debug builds keep every type boxed, as now), and
measures each before and after, on bench/native's programs and on the
kernel bench/data has for it, with `ren build --release --stats` (its
allocations) and bench/native/measure.sh (time and cycles). Today, on
this machine (a cloud container; the owner re-measures headline numbers
on the M4 Max), the kernels allocate: nested 200,005, rows 100,006,
optional 101,004, for 100,000 items each (as specified; each fix's
**Built** has what it allocated before and after, measured with a last
line that no longer `show`s the value: nested 66,671 before).

1. **A small record inside a small variant is boxed** (to_mem.ml,
   `small`, around 395 to 420). A constructor's fields must each be a
   scalar or `Boxed` (`simple`); a field whose layout is a `Struct`
   isn't, so the type with it isn't small, and the field's type is
   demoted to boxed by `slot` ("A struct is never a field of another",
   Step 10). `Draft(u: Unvalidated)` allocates twice. **The fix:** a
   field that's a `Struct` of `Product` kind (a small record or tuple)
   is flattened into its parent's slots: `simple` splices its `sfields`,
   `small`'s slot map gives each field a list of slots (one, or the
   nested struct's, in order) instead of one, and the budget is counted
   in total words after flattening: a sum's tag and three slots, a
   product's four. A nested `Tagged` or `Nullable` struct isn't
   flattened: it stays demoted. A flattened field read is a
   `Make_struct` of its slots, or, when only one of its fields is read,
   `x.u.qty`, one `Struct_get` of the parent's slot; building one copies
   the nested struct's slots in. Mem Lint's rules don't change: no slot
   is a struct. nested.ren should allocate a constant number, not one
   per item. **Built** (step 7, part 1; its choices are below): nested.ren
   allocates 4, where it allocated 66,671, one `Unvalidated` for each
   `Draft`, once its last line no longer `show`s an `Item`, which boxed
   it (step 7's choices).
2. **An array of small records holding an object boxes the type
   everywhere** (`plain_layout`'s `Array` case, line 517). An array's
   elements are counted as words or not at all, so `Array<T>` with `T`
   a counted struct raises `Demote`, and `T` is boxed program-wide.
   **The fix:** an array holds counted structs inline, `stride` words an
   element as an array of uncounted structs already does, and the
   array's header's `objs` byte, today 1 if its elements are counted,
   holds the element's mask, bit `i` set if slot `i` is an object (at
   most four slots, so it fits); `ren_alloc_array_n` and
   `ren_array_reserve` take it, and freeing, `ren_array_unshare`'s copy,
   `push`, `set` and the walks (`show`, `==`, hash, through a type's
   descriptor in generic code) dup and drop each element's masked
   words. A read is a `Make_struct` of the element's slots, borrowed
   while the array lives, as `Struct_get` is; a write drops the old
   slots. Mem Lint counts an element as its slots. rows.ren should
   allocate only its array's growth. **Built** (step 7, part 2; its
   choices are below): rows.ren allocates 6, where it allocated 100,006,
   one `Line` for each element, once its last lines print an element's
   fields, not the element, whose `show` boxed it; a read counts the
   element again, as an array of objects' does, rather than borrowing
   it.
3. **The tag is a whole word.** `Tagged`'s slot 0 is an `Int`. **The
   fix**, in two parts. (a) **A byte tag:** the tag in slot 0's low
   byte, and each constructor's small scalars (`Bool`, `()`, an enum, a
   sized type of 32 bits or less) packed into the rest of slot 0, as
   `pack` places them in an object (`Bits` places), so `| A(Bool) |
   B(Int)` is two words, not three. A boxed constructor's tag is
   already its header's. (b) **Pointer niches:** `Nullable (0, 1)`,
   today two constructors, one without fields and one of one object,
   becomes `Niche of { obj_ctor : int; slot : int }` (built as `Niche {
   obj_ctor; slot; ctors }`, below): any sum with one
   constructor that has fields, at least one an object after
   flattening, and any number without, has no tag; its object slot
   holds the object for `obj_ctor`, and for the `i`-th constructor
   without fields a scalar no object is, `Scalar_ctor (-1 - i)`
   (`ren_box(UINT32_MAX - i)`), its other slots 0 (Roc's
   `NullableUnwrapped`, Swift's spare bits). `Option<Item>` with `Item
   = { name: Str, price: Int }` is two words and no tag; optional.ren
   should allocate a constant number. **Built** (step 7, part 3; its
   choices are below): `Option<Item>` is two words, `{ name, price }`,
   where it was a tag and two slots; optional.ren allocates 4, where it
   allocated 101,004, once its last line prints `best`'s fields, not
   `best`, whose `show` boxed it (with that change alone it allocates 4
   at 7c68889 too, a word more for each option). The niche's scalar is
   by the constructor's tag, `ren_box(UINT32_MAX - t)`, not by its
   number among those without fields; a tag is the whole word where no
   constructor packs a scalar beside it.

Each follows "the programmer never holds an address, so representation
is the compiler's choice" (foundations.md, "The bet"): no program can
tell. Variant types and `Placed { ..p }` cost nothing extra when the
value is unique: `Of_variant` is no code, and an update over a dead
base reuses it (step 1).

**The milestone.** bench/data/interp.ren is research/dispatch.md's
`interp` kernel written ADT-first, `Expr` a sum type of eight variants
(the binary ones by name) and `eval` a `match`, printing what
bench/native/dispatch's Rust twin's `interp enum` does at its small size
(105, for 3 evaluations of the depth-17 tree from seed 1). Step 7 adds
bench/native/interp/ (`bench.ren`, the kernel; `main.ren`, 100 rounds,
25,600 evaluations; `small.ren`, 1), measured against
bench/native/dispatch/rust run as `100 interp enum` and against the
descriptions, `interp dyn` and bench/native/dispatch's Ren `interp`,
and records the numbers in bench/native/RESULTS.md, a section "The data
stage", with the commands that reproduce them and the machine they came
from. That's foundations.md's "Done when" with the bank, the shop and
the ledger reading as language.md's end-to-end program (step 2's
migration, step 3's `let ... else` where it fits; at 94d4cf7 they used
none of the new forms but by-name variants, and step 8 made them read
so: Step 8, as built). **Built** (step 7,
part 4; its choices are below): on the cloud container, release, one
hyperfine run, the ADT kernel takes 163.5 ms to Rust's `interp enum`'s
144.5, **1.13×**, on 886 million instructions to Rust's 871; Rust's
`interp dyn` 56.4 ms and Ren's descriptions 101.9 ms (1.81× `dyn`), both
faster than either `match`, whose one jump table through the tag is
what the time goes on. The section is RESULTS.md's "The data stage: the
milestone". One overhead was removed: a boxed sum all of whose
constructors have fields reads its tag from the header with no test for
a scalar (`Obj_tag`), 0.92× `eval`'s instructions and deriv's and
cfold's time 0.90× to 0.93×.

### What each step changes

- **Step 1:** parser.ml (`parse_primary`'s `{` and `Name {` with `..`,
  `parse_field_init`, `parse_pattern`'s braces, `binding_pattern` and
  `irrefutable` letting record patterns through, `parse_stmt`'s `let {`
  and `for {`, `parse_lambda_param`'s), ast.ml (`Update`, `PRecord`,
  `fields`), resolve.ml (`pattern` and `binding` for `PRecord`,
  `braces_name` for records), infer_expr.ml (`infer_update`,
  `bind_pattern`'s `PRecord`), infer_msg.ml (the errors, and
  `no_such_field`'s help "did you mean `paid`?" through `nearest` where
  one is near, else today's list), exhaust.ml (records as one
  constructor), lower.ml (`update`, `pattern`'s `PRecord`), core.ml(i)
  (`PRecord`), core_lint.ml, eval.ml (matching a `VRecord`), to_mem.ml
  (a `PRecord`'s fields), excl.ml and mut.ml where they walk patterns
  and expressions; tree-sitter's `record_expression` (a `spread` field),
  `record_pattern`, the corpus and Zed's highlights.
- **Step 2:** parser.ml (`parse_ctor_decl`, `parse_ctors`, braces after
  a constructor in values and patterns), ast.ml (`Con_named`,
  `PCon_named`, `ctor_named`), iface.ml(i) (`cnamed`), resolve.ml
  (`braces_name`'s constructor side, the ambiguity error),
  infer_lookup.ml (`ctor_shape`), infer_expr.ml (`infer_con_named`,
  `bind_pattern`'s `PCon_named`), exhaust.ml (`head`'s names,
  `show_space`), lower.ml, shown.ml and walk.ml (braces), to_mem.ml and
  emit_c.ml (`ren_ctor_info.fields` for a by-name constructor),
  ren_rt.c's show; the migration (the inventory); tree-sitter's
  `constructor_declaration` with braces, `constructor_expression` and
  `constructor_pattern` with fields, the corpus; language.md's "What Ren
  has today" table's constructor rows.
- **Step 3:** parser.ml (`parse_pattern`'s `|`, `as` and grouping, the
  `let ... else` statement, the `if let` error, `as` after `fail`
  patterns refused), ast.ml (`PAs`, `POr` for all, `Let_pattern`),
  resolve.ml (same names, `leaves`), infer_expr.ml (`bind_pattern`'s
  `POr` and `PAs`), exhaust.ml (`Or`, alternatives' usefulness, `let`
  patterns), lower.ml (`let ... else`, `PAs`), core.ml(i) (`PAs`),
  core_lint.ml, eval.ml, to_mem.ml (nested `POr`, `PAs`); tree-sitter's
  `or_pattern` for any patterns, `as_pattern`, `let_else`, the corpus,
  Zed's highlights; the bank, the shop and the ledger gain `let ...
  else` where it fits.
- **Step 4:** parser.ml (`parse_ty`'s `TyVariant`), ast.ml, resolve.ml
  (the sum of a `TyVariant`), types.ml and unify.ml (`TVariant`), ty.ml(i)
  (`Variant`, printing), infer_written.ml (written variant types, their
  errors), infer_expr.ml and infer_lookup.ml (`as`, field reads, update,
  the method refusal), infer_reqs.ml (borrowed requirements),
  infer_msg.ml (the mismatch helps), lower.ml (`Of_variant`, `PAs` at a
  variant type), core.ml(i) (`Of_variant`, `describe`), core_lint.ml,
  eval.ml, specialize.ml, to_mem.ml (layout, fields at a known
  constructor); tree-sitter's `variant_type`; operators.md ("Derived
  operations are borrowed").
- **Step 5:** infer_lookup.ml (`field_access`'s sum cases), infer_msg.ml
  (the three field errors), exhaust.ml (the arms to paste), diag.ml(i)
  (`code`), token.ml, lexer.ml and parser.ml (`todo`), ast.ml (`Todo`),
  infer_expr.ml, lower.ml (`Lib_panic`); tree-sitter's `todo` and Zed's
  keyword highlight; errors.md's `match` section shows the pasted arms.
- **Step 6:** lib/lower/stateless.ml (new) and its call in driver.ml,
  core.ml(i) (`method_calls`), lower.ml (recording them), infer_env.ml
  (`Calls_op`'s receiver); the benchmarks, deps.md and
  test_descriptions.ml as above.
- **Step 7:** to_mem.ml (`small`, `slot`, `plain_layout`, `pack`,
  `Nullable` to `Niche`), mem.ml(i) (`struct_kind`, an array's element
  mask), mem_lint.ml, emit_c.ml, ren_rt.h and ren_rt.c (arrays of
  counted structs, the niche scalars), bench/native/interp/,
  bench/native/RESULTS.md; build.t's loops gain bench/data's kernels.
  Part 1, as built: to_mem.ml (`place`'s `Flat`, `small`, `small_of`,
  `struct_shape`, `packs`, `within`, `flat_var`, `flat_slots`, the
  `Field`, `Update` and `Tuple` cases, `small_ctor`, `packed_words`,
  `match_`'s `flats` and `pending`); reuse.ml (`learn`) and rc.ml
  (`dtree`, `stale`), for three counting faults the tests found;
  bench/data's layout, layout_walks, layout_panic and reuse_arms;
  bench/native's build.sh and measure.sh. Part 2, as built: to_mem.ml
  (`plain_layout`'s `Array` case and `element`, which no longer demote),
  emit_c.ml (`struct_mask`, and an array of counted structs' reads,
  writes, field writes, allocation and reserve, in place and in hoisted
  loops), ren_rt.h and ren_rt.c (`objs` the element's mask; the counted
  structs' inline reads and writes, `ren_slots_dup` and
  `ren_slots_drop`; `REN_ELEM_OBJS`, which freeing, copying, the shared
  mark and a splice's copy count by; the copies' sets and pushes),
  mem_lint.ml (an array of counted structs of at most eight slots; a
  field written is its struct's slot, at its layout), hoist.ml (a field
  write's struct agrees with a read's), mem.ml(i)'s `Struct`; bench/data's
  rows_objs and rows_panic, and rows' last line. Part 3, as built:
  to_mem.ml (`small`'s sum case, `Niche` and the byte tag's `Bits (0,
  ...)` places; `small_ctor`, which packs a tag's slot 0 and writes a
  niche), mem.ml(i) (`Tagged of int`, the tag's bits, and `Niche`, for
  `Nullable`; `Scalar_ctor` below 0 a niche), emit_c.ml (`Tag_of` of
  each, a niche's scalar), ren_rt.h (`ren_niche_tag`), mem_lint.ml (a
  sum's struct and its niches; the join, where a constant stands for a
  reference); test_native.ml (the join's two cases); bench/data's
  niche, niche_walks, niche_panic, niche_reuse and niche_join, and
  optional's last line. Part 4, the milestone: bench/native/interp
  (bench.ren, main.ren, small.ren), in build.sh (no twins of its own),
  measure.sh (`interp`, and its `--stats`), summarize.py (the
  milestone's ratios), native.t and build.t; mem.ml(i)'s `Obj_tag`,
  to_mem.ml's `tag_of`, emit_c.ml, mem_lint.ml, and the passes that map
  a Mem rhs (rc, fold, inline, clone, trmc); bench/data's interp in
  build.t's loops.
- **Step 8:** the review, its three lenses (the brief's), and what it
  finds; language.md's "What Ren has today" table brought up to date.

### Errors

Each is a refusal test in test_data.ml, with the pass that says it.

Step 1:

```
error: `..o` comes first, before the fields                          (parser)
  help: move it to the front: `{ ..o, ... }`

error: a record takes the rest from one value                        (parser)
  help: keep one `..`, and write the other's fields

error: `..` in a value takes the rest from another, so it needs one  (parser)
  help: write the value after it, `{ ..o, paid: true }`, or leave it out

error: `..` comes last in a pattern                                  (parser)
  help: move it to the end: `{ id, .. }`

error: a pattern's `..` stands for the fields it leaves out, so it takes no name   (parser)
  help: bind the whole with `as`: `{ id, .. } as rest`

error: `Order` has no field named `piad`                             (Infer)
  help: did you mean `paid`?

error: `..n` takes the rest from a record, but `n` is an `Int`       (Infer)
  help: write every field, without `..`

error: `Shipped` needs `carrier`, which `..p` doesn't have           (Infer)
  help: give it: `carrier: ...`

error: `..s` would drop `carrier`: `Placed` has no field `carrier`   (Infer)
  help: name the fields to keep instead of `..s`

error: `..a`'s `total` is a `Str`, but `B`'s `total` is an `Int`     (Infer)
  help: give it: `total: ...`

error: this pattern doesn't name `lines`; add `lines`, or `..` for the rest   (Infer)
  help: write `{ id, total, paid, .. }` to leave the rest out

error: there are two fields named `id`                               (Infer, today's)
  help: remove one of them

error: a record pattern matches a record, but this is an `Int`       (Infer)
  help: take it apart as what it is, or bind it to a name

error: `Order`'s representation is private to `order`                (Infer, today's)
  help: use a function from `order` to make or read one
```

Step 2:

```
error: a variant with several fields names them, in braces           (parser)
  help: write `Rect { w: Int, h: Int }`
  help (unnamed): give each field a name, in braces: `Rect { a: Int, b: Int }`

error: `Rect` has named fields, so it's built with them              (Infer, ctor_shape)
  help: write `Rect { w: 2, h: 3 }`

error: `Rect` has named fields, so it's matched by them              (Infer)
  help: write `Rect { w, h: tall }`

error: `Circle` has one field, so it's built by position             (Infer)
  help: write `Circle(2)`
  (and "so it's matched by position", help `Circle(r)`, for `Circle { r }`)

error: this pattern doesn't name `h`; add `h`, or `..` for the rest  (Infer)
  help: write `Rect { w, .. }` to leave the rest out

error: this `Rect` is missing `h`                                    (Infer, today's)
  help: give it a value too, like `h: ...`

error: `..` stands for the fields a pattern in braces leaves out     (parser)
  help: write `_` for each field it leaves out

error: `Placed` is a record type here, and a constructor of `Order` too   (Resolve)
  help: write `Order.Placed { ... }` for the constructor, or `{ ... }` with the type left out for the record
  (an update's: write `Order.Placed { ..base }` for the constructor, or `{ ..base }` with the type left out for the base's own type)

error: `Shape` is a sum type, so a record pattern doesn't match it   (Infer)
  help: name the variant: `Rect { w, .. }`

error: this `match` doesn't handle every `Shape`                     (Exhaust, today's)
  = missing: Rect { .. }
```

Step 3:

```
error: `n` is bound in `Pro(n)` but not in `Free`                    (Resolve)
  help: bind the same names in every alternative

error: `n` is an `Int` in `A(n)`, but a `Str` in `B(n)`              (Infer)
  help: bind it to one type in every alternative

error: this alternative never matches                                (Exhaust)
  help: the alternatives before it, or the arms above, already match all of it

error: the `else` of a `let ... else` has to leave                   (Resolve)
  help: end it with `fail`, `break` or `todo`

error: this pattern always matches, so the `else` never runs         (Exhaust)
  help: remove the `else`

error: `Some(n)` might not match, so this `let` needs an `else`      (Exhaust)
  help: add one that leaves, `let Some(n) = o else fail ...`, or use a `match`

error: a `for` takes apart only what always matches, but `Some(n)` might not   (Exhaust)
  help: take it apart with a `match`, which says what happens when it doesn't match
  (and "a block's parameter takes apart ...", the same)

error: Ren has no `if let`                                           (parser)
  help: write a `match`, or `let Some(n) = o else ...`

error: a `fail` pattern can't bind the whole error to a name         (parser, today's)
  help: match each tag, like `fail NotFound`, or keep the whole outcome as a value with `attempt`, and match `Err(e)`
```

Step 4:

```
error: expected `Order.Placed`, found `Order`                        (Infer)
  = a constructor always builds the sum; a variant type is bound by a pattern's `as`
  help: `Order.Placed` is one variant of `Order`: match it and bind that with `as`, `Placed { .. } as p`

error: expected `Order`, found `Order.Placed`                        (Infer)
  help: make it the sum: `Placed { ..p }`

error: `Discount.Flat` isn't a type: only a variant with named fields has one   (Infer_written)
  help: take its field out where it's matched, `Flat(off) => ...`

error: `Order` has no variant `Placd`                                (Infer_written)
  help: did you mean `Placed`?   (else: its variants with named fields: `Draft`, `Placed`, `Shipped`)

error: `User` isn't a sum type, so it has no variants                (Infer_written)
  help: a variant type is one of a sum's, like `Order.Placed`

error: `..o` takes the rest from a record, but `o` is an `Order`, a sum type   (Infer)
  help: match it, and take the rest from the variant: `Placed { .. } as p => Placed { ..p, ... }`

error: `Order.Placed` has no methods of its own                      (Infer)
  help: call it on the sum: `Placed { ..p }.total()`
```

The first's note is said only where what was found is a constructor's
sum; any `Order` where `Order.Placed` is wanted gets the help.

Step 5's are above (The errors that teach the model), and the panic:

```
error: panic: reached a `todo`
```

Step 6:

```
error: `c` may be a description of `counter`, which keeps state, so it isn't called as a method   (Stateless, at link)
  = a call as a method makes a fresh instance, so its state would start again at each call
  help: install it: `with c in Area.area()`
```

### Where the data stage may differ from language.md

Choices this specification made where language.md, foundations.md or
the orchestrator's notes are silent or don't fit the code, each to
revisit if a step finds it wrong:

- **A binding pattern may leave fields out without `..`.** language.md
  writes `let { id, lines } = order` (an order with more fields) and
  foundations.md `let { id } = u`, but also the error "this pattern
  doesn't name `h`; add `h`, or `..` for the rest". Both hold: a brace
  pattern in a `match` arm or a `let ... else`, which tests, names every
  field or ends in `..`; one in a `let`, a `for` or a block's parameter,
  which only takes apart, may leave fields out.
- **An update is strict:** every field of its base is its target's, so
  nothing is dropped unseen; to drop one, name the fields to keep. It
  matters only when target and base differ.
- **`Name { ... }` with `Name` both a record type and a by-name
  constructor in scope is refused,** not resolved by the expected type
  as two constructors of one name are: the help gives a spelling for
  each.
- **The leaves of `let ... else` are `fail`, `break` and `todo`,** and
  blocks, `if`s and `match`es that end in them. Ren has no `return`, and
  until `todo` no expression a program writes panics with any type
  (`lib_panic` is the standard library's).
- **`todo` is a keyword,** an expression of any type that panics,
  "reached a `todo`": language.md prints missing arms as `Some(Closed)
  => todo`, so pasting them has to compile.
- **A `let ... else` whose pattern always matches is an error,** not a
  warning: its `else` can never run.
- **A variant type's arguments follow the variant:** `Tree.Node<Int>`,
  as the constructor is written `Tree.Node { ... }` with its sum's
  parameters.
- **A variant type has no methods,** not even the sum's: calling one
  would be an implicit conversion. Methods on one variant are later.
- **A variant's one field may be written by name, in braces,** `Draft {
  lines: Array<Line> }`, as language.md does; then it's built and
  matched in braces, its declaration deciding, and it has a variant
  type. In parens, a label on one field only documents it.
- **A labelled one-field construction is an error,** `Flat(off: m)`,
  with the fix-it `Flat(m)`: one spelling per variant.
- **The stateless-only rule is checked on the linked program,** since a
  description's type doesn't say whether its handler keeps state, and
  **step 6 refined it** from per dependency to per call: a description
  installed where it's made, `counter().area()`, or held by a local
  never assigned or passed with `&` and only ever installed (`let c =
  counter()`, then `c.area()` or `with c in ...`), reaches only those
  `with`s, so a method call on it is refused only if that handler keeps
  state; any other method call, on a description stored, passed,
  returned or captured, may be any *kept* handler's, and is refused if
  one of its dependency's kept handlers keeps state, as the
  specification said for every call. So a stateful handler that's never
  kept, installed by `with` or bound and only installed, leaves the
  calls on its dependency's stored descriptions alone. It's sound
  because every description is made by calling a handler's function, or
  by an inline handler, which has no state, and one not kept reaches
  only the `with`s the walk saw it reach (stateless.ml). `ren check` of
  one module doesn't see it; `ren run`, `ren test` and `ren build` do.
- **Stateful means a `var` or a `finally`,** decision 3's list less the
  two its types already refuse; a `let` among a handler's state is
  stateless, though native code installs it for a call, which means the
  same.
- **Or-patterns' messages replace today's for `fail` or-patterns too,**
  so there's one wording.
- **Only a small record or tuple is flattened into its parent** (step
  7); a nested small sum stays boxed, since flattening a tag into a tag
  is more than language.md's fault asks for.
- **A recursive `match` isn't yet the fast way** (open, medium; step 7,
  part 4). language.md's ethos says the obvious way is the fast way, and
  §1 that an ADT costs "an inline tag, no indirection". The milestone's
  ADT kernel is 1.13× Rust's `interp enum`, but 1.60× Ren's own
  descriptions version of the same kernel (RESULTS.md, "The data stage:
  the milestone"): a `match` is one jump table for every node, which the
  predictor can't learn across a random tree, where each description's
  `eval` calls its children from the arm it's in, eight sites it tells
  apart. Rust's enum is 2.56× its `dyn` here, the same shape. The ADT
  kernel is the program the docs teach and costs what Rust's does; per-arm
  dispatch (threaded code) is a code-generation question past this stage.
  This is a gap against language.md, not a choice.
- **`Obj_tag` stays on its instructions, not on the milestone's time**
  (step 7, part 4). It takes `eval` from 965 to 886 million
  instructions, but with GCC's default code layout the kernel's time
  went from 140.0 to 163.5 ms in the table's run (1.06× to 1.18× in
  six), from where GCC places the jump table's targets: the same C with
  branches aligned is 0.78×, and with clang 0.94×. deriv and cfold,
  whose C differs only in that read, take 0.90× to 0.93× the time. So
  the milestone's 1.13× is with it; at 213b4a9 that one run had the
  kernel at 0.97× Rust's.
- **`show`, `==` and `hash` still box a small value's type
  program-wide** (unfinished, medium; step 7, part 2, "The walks still
  box"): the walks are given a word, so one `print` of a value anywhere
  in a program boxes its type everywhere, undoing the layout fixes for
  that type. language.md's fixes hold for a type no walk sees, and the
  kernels measure theirs with last lines that print fields, not the
  value. Walks that read a struct by its address change the
  descriptors, the walks' signatures, generic code that takes a word,
  and the debug build: later.
- **Error tags stay positional,** `! Short(account: AccountId, by:
  Money)`, `fail Short(a, b)`, `fail Short(_, by) =>`. language.md's
  "several fields by name" is about variants of data; tags are
  structural, and formats.md (signed off) writes `fail Short(_, need)`.
  So a tag with two payloads of one type keeps the reordering hazard
  language.md names for variants.
- **An unknown field's error says "`Order` has no field named
  `stauts`"**, the compiler's one wording for an unknown field (record
  literals and reads said it before this stage), where language.md
  writes "has no field `stauts`"; the "did you mean `status`?" is as
  written.
- **`ren check` doesn't report a stateful description called as a
  method** (known, low). It's checked on the linked program (above), so
  `ren check`, which the Zed task and an editor run on one file, never
  shows it; `ren run`, `ren test` and `ren build` do. A check of what
  one module makes and calls itself could run in `ren check` later.

### Step 8, as built

Step 8 reviews the stage with three lenses, soundness, the spec, and the
docs and tooling, as three reviews over 94d4cf7. 3545731 is the spec's
and the docs': the examples and the documents. The soundness review's
compiler fixes are the commit after it (below, "The soundness review's
fixes").

**The examples read as language.md's end-to-end program does.** None
of the bank, the shop and the ledger used `{ ..x }`, a record pattern
or `let ... else` at 94d4cf7, so "Done when" didn't hold yet. Now:

- **The bank.** `Bank.transfer` takes its `Transfer` apart, `let {
  from, to, amount } = t`, and writes each movement punned, `Sent {
  amount, to }` and `Received { amount, from }`, the accounts it changes
  `out` and `into`. `Movement.change` is a `match` with an or-pattern,
  `Deposited(m) | Received { amount: m, .. } => m` and `Sent { amount, ..
  } => -amount`, and account.ren's new test, "a statement adds up to the
  balance", takes each entry apart in a block's parameter,
  `a.statement().map(fn({ what, .. }) => what.change()).sum() ==
  a.balance()`. Its README says so, notes that `todo` isn't the panic
  the `-1` arms want, and that the bank doesn't build natively (`Clock`
  and `Map`).
- **The shop.** An invoice's `Status` gains `Paid { amount: Int,
  charge: stripe.ChargeId }`. `invoice.pay` gives back the invoice paid,
  `! Declined(amount: Int) | NothingDue`: `let Due(amount) = i.status
  else fail NothingDue`, then `{ ..i, status: Paid { amount, charge: try
  stripe.charge(amount) } }`. `checkout` takes the charge out with a
  record pattern, `{ status: Paid { charge, .. }, .. } =>
  stripe.receipt(charge)`, its `_ => 0` arm for an invoice that isn't
  paid, which `pay` never gives but the type allows. cart.ren gains
  language.md's policy ADT, `Discount` with `Flat(off: Int)` and
  `OverAmount { min: Int, off: Int }` and `apply`, and `Cart.total_after`;
  `main` prints a paid invoice and a discounted total. The shop has
  tests now, of `pay` and of the discount, so THE CHECKS run them. It
  builds natively, and its debug and release builds print what `ren
  run` does (it's in build.t's `same` loop under the sanitizers).
- **The ledger.** `mem_sql`'s `get` is `rows.get(name) orelse 0`. Its
  data is names and balances in a `Map`, and its subject is handlers,
  `over`, `next` and `finally`, so there's no sum or record to take
  apart: a `Transfer` record for `transfer(from, to, amount)` would add
  a constructor at each call and say nothing the three parameters
  don't, and `transaction`'s `finally` can't be a `let Ok(v) = r else
  ...`, since its `else` ends in `try r`, which isn't one of the leaves.
- examples.t's outputs promoted, each diff read: the shop's new lines
  and interface, `Movement.change` in the bank's interface, the bank's
  line numbers, its tests' count, and the two edits that add `TooLarge`
  to `transfer`, rewritten for its new lines.

**The docs review's findings,** fixed: Zed's grammar `rev`, 2f322dd
(10d's grammar) to 94d4cf7, which has every node the queries name;
README's status (11a and the data stage), its roadmap row (done, with
the milestone), `if found is Some(u)`, which isn't Ren, as a `match` in
README and handlers.md, §2's update block, which treated a sum as a
record, the tour's rule for by name and positional; language.md's "What
Ren has today", each row today's behaviour only, a layout row, the
date; this section's grammar (`lparam` and `for` take any pattern),
step 7's spec text (the counts before, `Niche`'s record), the tests'
tense and step 7's row, the Core paragraph of "What each IR promises",
step 10's rbtree `Node { ... }`; parser.ml's header (a variant type);
deps.md's error example, now its own `Route`'s; the bank README's
`todo`; editors/zed/README.md's note on what the colours can't tell;
differential.py reads bench/data/*.ren too, and agrees on all of them.
Left for the owner, as the review says: language.md's design sections
that the stage made stale (the layout fixes "not yet benchmarked", the
`dep Expr` one-liner and `-> ()`, which don't parse), and
foundations.md's Staging item 5 and decision 14's "a pointer that may
be null", now a niche.

**The spec review's unrecorded items** are in "Where the data stage
may differ from language.md", above: the ADT kernel against the
descriptions, `Obj_tag`'s time, the walks' boxing, error tags, the
"named" wording, and `ren check`'s blind spot.

**The soundness review's fixes.** It found no wrong answer, memory
error or leak, and no program accepted that must be refused; it found
seven programs the compiler stopped on, or refused, wrongly. Each is
fixed at its cause, with test_data.ml's s8 tests and, where it's
native, bench/data's review_keys, review_state, review_state_panic and
review_todo_panic in build.t's four loops (`same`, `release`,
`tcc_same`, `release_naive`):

1. **A variant type in a dependency's type** (high). Two causes. Core
   Lint's `instance_of` and `equal` had no case for two `Variant`s, so
   an operation whose signature has one, `reprice: fn(p: Order.Placed)
   -> Int`, called on a description (which a release build makes a
   `Dep_call`), was "used at a type which isn't its type"; they compare
   two variant types now as two `Con`s, and of one constructor. And
   `describe` made a variant type its sum's descriptor, so a
   dependency's key at `Order.Placed` was the one at `Order`: Core Lint
   refused `with` of a `Store<Order.Placed>` in release, and worse, the
   interpreter found the wrong handler, `Draft` from a `Store<Order>`
   installed inside one at `Order.Placed`, then read a field `Draft`
   hasn't (a crash, not a wrong answer, but unsound). A descriptor keeps
   the variant now: `Known (Variant ...)`, or a new `Applied_variant (s,
   c, ds)` for one with the function's type variables in it, built at
   run time natively (`New_desc (Of_variant ...)`); the interpreter's
   `type_of`, Core Lint's `described`, the specializer's closing and
   `key_label`, and to_mem.ml's `static_desc` and `desc` keep it, and
   natively it's `REN_D_NAMED` of the sum's declaration with its
   constructor's tag plus one in `var`, which only `ren_desc_same`, the
   evidence's lookup, reads. Sound: every walk (walk.ml, shown.ml,
   journal.ml, ren_rt.c) treats it as the sum, which a value of it is;
   only the identity of a dependency changes, and two instances of a
   dependency are told apart by their full type everywhere else
   ("Found by its full type"); and to_mem.ml's `dict` refuses a
   variant type's dictionary for an operator of its sum's own, as it
   does the sum's, rather than letting the walk stand for it. Behind it,
   two more: Core Lint compared
   two rows of what a function uses by their order, which Infer sorts by
   its types' text and `Ty.apply` by Ty's (`Store<Tree.Node<T>>` and
   `Store<Tree<T>>` come out in either order), so it compares them as
   sets (`same_row`); and a generic handler with a parameter,
   `giving<T>(v: T)`, failed every debug Perceus build in Mem Lint
   ("`$ty0` is used where it isn't defined", at 4eb8fe2 too): its code
   read the captures from its description before the descriptors that
   count them, so it reads the descriptors first.
2. **`let ... else` in a handler's state** (high). Infer_handlers
   checked the state's statements with `core.stmt`, which binds the
   pattern and leaves the `else` to `Infer_expr.block`, so the `else`
   had no type and lowering stopped. The state checks the `else`
   against what the state ends in, the instance, a variable unified
   with the handler's type once its node has it (`cx.later`). Behind it:
   any pattern in a handler's state but a name, `let (a, b) = p` too,
   lowers to a `Match` around the rest of the state, which Core Lint
   refused ("a handler's body that doesn't end in an instance") and
   native code gave the instance's type, though a handler's code gives
   the `with` body's word. Core Lint's `handler_end` follows a `Match`
   whose arm ends in the instance (`Core.ends_in_instance`), the other
   arm, which leaves, checked for no instance; to_mem.ml's
   `result_layout` gives a `match` or a `Handle` that ends in the
   instance the word's layout, and an arm that leaves, its result never
   set, a dummy of it. The other statement lists, a block's (functions,
   lambdas, `finally`s, tests' bodies) are `Infer_expr.block`'s, and a
   test handler's state is a handler's: `ren check` and lowering agree
   on each (the s8 tests).
3. **`todo` called, `todo(1)`** (high). `todo` is any type, so a call of
   it type-checks, and `ren run` evaluates the callee first, and panics.
   Lowering made it `Lib_panic` at a function type, which Core Lint
   refuses (a type variable never stands for a block) and native
   lowering couldn't place. A call whose callee is `todo` lowers to the
   panic at the call's type, at the `todo`, its arguments never
   evaluated, as `ren run` did; everywhere else a `todo` where a block
   goes is already refused (it isn't written right there). Accepted,
   rather than refused, since it's what `todo` means anywhere else: it
   panics where it's reached.
4. **An or-pattern inside another's alternative** (medium). Exhaust's
   `alternatives` checked an inner alternative against the whole
   pattern with only its own or-pattern swapped, so the enclosing
   or-pattern's later alternatives counted as before it, and a useful
   alternative was "never matches". `ors` gives each or-pattern the
   or-patterns it's inside, each at the alternative it's in, and
   `simplify`'s `swap` takes several: an inner alternative is checked
   with each enclosing or-pattern at the alternative it's in, against
   the arms above, each enclosing one's alternatives before that one,
   and its own before it. `Some(A(n)) | Some(B(n) | A(n))` still says
   the inner `A(n)` never matches.
5. **The stateless help for a generic dependency** (low). It wrote `with
   c in Chan<Int>.send(1)`, which doesn't parse: an operation is called
   through its dependency's name alone, its type arguments found from
   the call. The help writes `with c in Chan.send(1)`; where the
   arguments don't fix the type arguments, `c.recv()`, it writes the
   type where the value goes, `let recv: Option<Int> = with c in
   Chan.recv()`, since nothing else would (a `with` doesn't fix what its
   body uses). Each pastes and checks (s8). The `with` is still a fresh
   instance at each call, which is what the refusal's note says.
6. **The record-or-constructor help on an update** (low). The spec says
   an update's target, left out, is the base's type, the expected one
   only when the base's isn't known yet ("Record update (step 1)" and
   step 1's choices), so `let r: Rect = { ..q }` with `q: Shape.Rect` is
   a `Shape.Rect`, refused as the mismatch it is. The rule stands; the
   help on an update, `Rect { ..r, w: 1 }`, says so now: "write
   `Shape.Rect { ..base }` for the constructor, or `{ ..base }` with the
   type left out for the base's own type", and the grammar's comment
   says "the base's type; the expected one only when the base's isn't
   known yet".
7. **A handler given a small record** (high in release, at 4eb8fe2
   too). A release build stored the struct in the description's object,
   whose fields are words (Mem Lint: "Struct0 stored in an object"); a
   tuple and an option of an object are the same. What a handler
   captures is a word: a struct's type is kept boxed instead
   (`word_only`, the `Demote` a field of an object already takes), so
   those types are boxed program-wide in such a program, which is sound
   and costs only that program.

All the review's reproducers, and its batch scripts (le/, m1, m2), run
again through its harness in every build: each prints what `ren run`
does, and every OK is still OK.

**Left, with severity:**

- **Medium:** a function whose declared `uses` names a dependency at a
  type built from its type parameter, `fn f<T>() -> T uses
  Store<Option<T>>` or `Store<Tree.Node<T>>`, is refused at its callers
  ("nothing installs `Store<Option<T>>` before `main`", the `T` not
  instantiated): the scheme's `uses` label isn't instantiated with the
  call's type arguments. Before the data stage too, not of variant
  types; `uses Store<T>` works.
- **Low:** a `with` doesn't fix an open type argument of what its body
  uses from what it installs, so `with c in Chan.recv()` needs the type
  written; the spec says so ("Found by its full type"), and the help
  writes it.
- **Low:** while a record type and a by-name constructor share a bare
  name, an update into the record from a variant type of the sum, `Rect
  { ..q }` with `q: Shape.Rect`, can't be written: `Rect` is refused,
  and `{ ..q }` is the base's type. Rename one, or write the record's
  fields.

### Progress log

| step | commit | done | left |
|---|---|---|---|
| 0 | f313084 | this section: the grammar, the AST, each step's rules, passes and files, every error with its help, the layout faults and their fixes, the choices where the design is silent; the inventory of by-name sites (324, counted by a scratchpad script); test/test_data.ml, every test of a feature behind `until "sN"`, the guards written plainly; bench/data/ (update, byname, orpat, variants, todo_panic, shapes, and step 7's nested, rows, optional and interp) and its section of bench/build.t, step 7's three kernels already as specified | steps 1 to 8; nothing of the language is built yet |
| 1 | cff7c15 | record update, `{ ..o, f: v }` and `T { ..o, f: v }`, and record patterns, `{ f: p, g, .. }` and `T { .. }`, in a `match`, a `let`, a `for` and a block's parameter, through the parser, Resolve, Infer (`infer_update`, `record_pattern`), Exhaust (a record is one constructor), Core (`PRecord`) and Core Lint, the interpreter, and Mem IR in both builds; the fourteen refusals; tree-sitter's `record_expression` with a `spread`, `record_pattern`, `field_pattern` and `rest_pattern`, its corpus (records.txt) and Zed's highlights; test_data.ml's s1 tests on, and bench/data/update in build.t's `same`, `release` and `tcc_same`, with its reuse shown (`--stats`: the loop of 1000 updates allocates nothing, each a reuse); the README and language.md's "What Ren has today". Choices: below the table | steps 2 to 8 |
| 2 | e180921 | the language change, by-name variants, through the whole pipeline: the parser (`parse_ctor_decl`'s braces and one positional field, labelled or not; `Shape.Rect { ... }` and `Shape.Rect { .. }`; `..` refused in parentheses), Resolve (`braces_name`, the record-or-constructor refusal; a by-name constructor refused where a binding pattern must always match), Infer (`infer_con_named`, `con_pattern`, `ctor_shape` down to arity, the by-name and by-position refusals with their fix-its, an update into a by-name constructor), Exhaust (`Rect { .. }`), lowering (to `Con` and `PCon`, so Core, Core Lint, the interpreter and Mem IR are unchanged), `show` in the interpreter, its `assert` diff, the journal, and natively (`ren_ctor_info.fields`); tree-sitter's `variant`, `constructor_expression` and `constructor_pattern` with fields, the corpus (variants.txt, and types.txt's declaration moved), Zed's highlights; test_data.ml's s2 tests on, bench/data/byname in `same`, `release` and `tcc_same` (and `shapes` and `interp` now as specified) ; and the migration, every site of the inventory moved to the new forms, 318 of its 324: bench/ 100 (packed, review_lists, review_values, sized, trmc, trmc_panic, values), bench/native 103 (binary-trees, blocks, cfold, deriv, nested, nqueens, rbtree; their Rust and Go twins and checksums unchanged), bench/build.t's heredocs 12, examples/ 17 (bank 7, `Sent { amount: t.amount, to: t.to }`; shop 3, vm 4, infer.ren and plans.ren 3), test/ 81 (test_native 38, test_eval 12, test_blocks 10, test_deps 10 with 6 printed, test_resolve 4 with 1 printed, test_infer 3, test_modules 2, test_ops 1, test_syntax 1), the corpus 2 (types.txt, expressions.txt), the docs 3 (README.md's `Pro(5)`, errors.md's `Sent` and `Received`) and their prose (README.md, bench/native/README.md, the Native slice's trmc paragraph); the outputs promoted, each diff only `show`'s braces, the step's error texts and the bank's line numbers. Left as they are, 6: formats.md's `Query(sql: CStr)`, a format's `case`; test_infer.ml's `Pro(seat: 5)` and `Pt(x: 1, 2)` and their printed copies, now tests of the errors that replace theirs; test_modules.ml's printed `Full(row: Row)`, a declaration of one field. Choices: below the table | steps 3 to 8 |
| 3 | b885fcd | or-patterns anywhere a pattern goes, nested, `as`, and `let PATTERN = e else LEAVE`, through the whole pipeline: the parser (`parse_pattern`'s alternatives, `as` and grouping; `let` and `for` taking any pattern and a block's parameter one that starts with `(`, `{` or a capital; the `let ... else` statement; `if let` refused with its help; `as` after `fail` patterns refused), Resolve (one message for a name only some alternatives bind, `fail` ones too; `leaves`; the `else` resolved before the pattern binds), Infer (`bind_pattern`'s `POr`, through `alternatives`, which `bind_fail` shares, with the new message; `PAs`; the `else` checked against the rest of the block's type), Exhaust (`Or` spaces, each alternative checked useful, the patterns of a `let`, a `for` and a block's parameter checked to always match, and a `let ... else`'s to not), lowering (`let ... else` a `Match` of two arms, `PAs`), Core's `PAs` and Core Lint, the interpreter, and Mem IR in both builds (`PAs` the subject itself; an or-pattern that binds names gives each alternative its own variables and its own join, which Perceus needs, and a pattern's variable found by id); tree-sitter's `or_pattern` for any patterns, `as_pattern`, `parenthesized_pattern`, `let_else`, patterns in a `let`, a `for` and a block's parameter, the corpus (patterns.txt) and the highlight markers, Zed's highlights; test_data.ml's s3 tests on, the end-to-end program among them; bench/data/orpat as specified and in `same`, `release` and `tcc_same`, with bench/data/orpat_strs beside it (or-patterns binding counted values); the bank's `worth_retrying` in two arms with or-patterns; README's tour, language.md's "What Ren has today". The parser's `binding_pattern`, `irrefutable` and `might_not_match` are gone, and so is Resolve's refusal of a by-name constructor in a binding position: Exhaust decides. Choices: below the table | steps 4 to 8 |
| 4 | e77a8bb | variant types, `Order.Placed`, through the whole pipeline: the parser (`parse_ty`'s `TyVariant`, `Tree.Node<Int>`, and `Tree<Int>.Node` refused with its help), Resolve (the sum's name, and the three refusals: not a sum, no such variant with "did you mean", a variant not by name; and a variant type of a private sum in a public signature), Types and Ty (`TVariant` and `Variant`, unifying only with themselves, printed `Order.Placed`, every walk of a type), Infer (`as` on a by-name constructor's pattern binds its variant type; field reads, record patterns, `{ ..p, total: x }` an `Order.Placed`, `var p` and `p.total = x`; `Placed { ..p }` the sum; a pattern of a variant type's own constructor that always matches, and of another one refused; the two mismatch helps and the constructor's note; `..` from a sum, and the method refusal), Infer_reqs (`==`, `hash` and order borrowed, through the sum's `key`), Exhaust (a variant type's one constructor), the interfaces (a variant type in a `pub` signature, written `order.Order.Placed` by an importer), Core (`Of_variant`, `Con`, `PCon`, `Field` and `Update` at a `Variant`, `PAs` binding one; `describe` the sum's) and Core Lint, the interpreter (a variant type's value is its sum's; its walks, `show`, `==`, `hash`, `key` and the journal, the sum's), and Mem IR in both builds (the sum's layout, struct and descriptor; a field read at its constructor's slot; no tag test; `Of_variant` no code; an update of a small one keeps its tag); release specialization; tree-sitter's `variant_type`, its corpus (types.txt) and highlight markers, Zed's highlights; test_data.ml's s4 tests on, and four more (another module's signature, round trips and a variant type's own patterns, another variant's pattern refused, the arguments' place); bench/data/variants as specified and in `same`, `release` and `tcc_same`, with variants_small (variant types of sums kept as structs), variants_escape (stored, passed through generic functions, round-tripped) and variants_reuse beside it, whose loop of 1000 updates and conversions allocates nothing (`--stats`, both builds: 4 allocations, 1000 reuses); README's tour, language.md's "What Ren has today", operators.md's "Equality, hashing and `show`". Choices: below the table | steps 5 to 8 |
| 5 | ed8f0f8 | the errors that teach the model, and `todo`, through the whole pipeline: `todo` a keyword (token.ml, the lexer, the parser's `primary`, Ast's `Todo`), Resolve (one of `let ... else`'s leaves), Infer (a fresh type variable), lowering (the intrinsic `Lib_panic`, "reached a `todo`", at the `todo`, so Core, Core Lint and the interpreter see a call they already know), and Mem IR in both builds (a `Lib_panic` in the program's code is said where it's written, not at the function's site, so native and `ren run` print the same); `$start` calls a `main` that never gives a value, `fn main<T>() -> T`, at `Unit`, which natively was Mem Lint's "`$start` isn't what the program says it is"; Diag's `code` and `code_at`, lines a help writes; `field_access`'s sum case (Infer_msg.field_of_sum): "`Shape` is a sum type; only `Ring` has `r`" with the `match` to paste, its variants in one arm with `\|` when the field has one type, an arm each otherwise; "every variant of `Shape` has `id`, but a sum type has no fields" with the hoisting help, or, at different types, the `match`; Exhaust's arms to paste, up to three and an arm for the rest, values' `_` or errors' `fail _`, by name where a variant is, after their sum where a record type shadows a bare constructor (Infer_msg.braced_ctor), at the column of the match's arms; tree-sitter's `todo`, the corpus (statements.txt) and the highlight markers, Zed's keyword highlight; test_data.ml's s5 tests on, and thirteen more: a positional variant's label, a field at different types, no variant, a generic sum's hoist, more missing than shown, nested, the shadowed constructor, values and errors, `Err`'s tags, a `todo` body and `main`, `todo` not a name, the arms of nine programs pasted back in after their last arm, and the `match` of three field errors pasted in for the read, each of which then checks; every "missing:" error's help in test_exhaust, test_errors, test_modules, test_tasks, test_collections and examples.t promoted, each new line pasteable; bench/data/todo_panic as specified and in `same`, `release` and `tcc_same`, and `fn main() = todo` in build.t; errors.md's `match` section and the README's tour show the printed arms; language.md's "What Ren has today". Choices: below the table | steps 6 to 8 |
| 6 | 8c7c65c | descriptions: an operation called on a description only when its handler is stateless, through the pipeline: Infer's `Calls_op` gains the receiver as written and the call a `with` would make, its arguments as written; Lower records each method call (Core.program's `method_calls`, by its `With`'s location, from `Lower.program` and `Lower.made`); a new link-time pass, lib/lower/stateless.ml (`Stateless.check`), run by `Driver.link` after the modules are linked, so `ren run`, `ren test` and `ren build` refuse (not `ren check`): a handler is stateful if its body makes a cell (a `var`) or its instance has a `finally`; a method call on a description made where it's installed, or held by a local never changed and only installed, may be only that handler's; any other may be any kept handler's (refined from the specification's per-dependency rule: "Where the data stage may differ"); the error, "`c` may be a description of `counter`, which keeps state, so it isn't called as a method" ("which has a `finally`"), at the operation's name, with its note and the help that writes the `with`; the interpreter and native builds unchanged, each program that still compiles running the same; test_data.ml's s6 tests on (the refusals through `run_error`; the last accept's program had a dropped `Area.area()`, now `let _ =`), and seven more: a stateful handler bound and only installed beside stored stateless calls, one called where it's made, a local that's assigned, one passed, returned, stored and wrapped, a handler of another module kept there, and `ren check` not seeing it; test_descriptions.ml's stateful method call a refusal, its `with` half its own accept test, its `Shape` a `Codec` (numbers kept); test_deps.ml's handler of several called as a method through `id(...)`, now a stateless `fixed_rates`, with the `counting_rates` one a refusal; bench/10d/methods.ren, review_deps.ren and dispatch_mix.ren's calls that may reach a handler with state written as `with`s, their outputs and every site's lowering unchanged; the renames: bench/10d/shapes.ren's `Shape` a `Codec`, dispatch.ren's `Shape` and `Expr` `Codec` and `Pipe`, dispatch_mix's `Area`, `Size` and `Label` `Codec`, `Width` and `Name`, build.t's `--explain-dispatch` listings redone, bench/native/dispatch's `ShapeK` `CodecK` (gen.py and bench.ren; the twins byte for byte as they were, checksums the same, the release C the same but for handlers' names, so RESULTS.md's numbers stand, as it now says); bench/data/shapes in `same`, `release` and `tcc_same`; deps.md's example a library's routes, with the rule, its error and that `ren check` doesn't report it; handlers.md's "Called as a method"; README's handlers section; bench/native/README.md; language.md's "What Ren has today". Choices: below the table | steps 7 and 8 |
| 7 (part 1) | d86b474 | the before measurements of all three faults, the kernels and bench/native's suite at 8c7c65c (bench/native/RESULTS.md, "Data stage: layout", with the commands and the machine), and the first fix: a small record or tuple in a small value flattened into its slots, the budget counted in slots (to_mem.ml: `small`'s places and `Flat`, `small_of`, `struct_shape`, `flat_var`, `flat_slots`, `within`, a pattern's `flats` and `pending`), so nested.ren allocates 4, not 66,671, and a copy with 100 times its items runs in 17 ms, not 64; three faults of boxed values' counting the tests found, fixed (reuse.ml's sizes known by path, a heap overflow; rc.ml's slot nested once, and a changing variable's views); bench/data's layout, layout_walks, layout_panic and reuse_arms, and the three kernels, in build.t's loops and a release naive one; build.sh's dispatch kernels, which step 6's rename broke, and measure.sh's peak memory on Linux | the second fix (an array of counted structs inline) and the third (byte tags and niches), each measured; rows.ren's and optional.ren's last lines `show` the value, which boxes its type and hides the fix (step 7's choices); the milestone kernel against Rust; `if c then None else p` in debug builds (step 7's choices) |
| 7 (part 2) | 7c68889 | the second fix: an array of small values that hold objects keeps them inline, counted by the mask of their slots that hold objects, which the array's header keeps in its `objs` byte (1 for counted words, as before), instead of boxing their type program-wide: to_mem.ml's `plain_layout` and `element` no longer demote; ren_rt.h's and ren_rt.c's arrays count by the mask (`REN_ELEM_OBJS` for freeing, copying, the shared mark, splices and joins; `ren_slots_dup` and `ren_slots_drop`; inline reads, writes, field writes and pushes of counted structs, and their hoisted loops' buffer macros); emit_c.ml's `struct_mask` and each operation's C; Mem Lint (arrays of counted structs of at most eight slots, a field written at its slot's layout) and hoist.ml (a field write's struct agrees with a read's); and a fault the suite found: a walk reads an array's elements as words, so a small type that's an array's element anywhere in a walked value is boxed (`no_struct_elements`, for each closed type's descriptor and each built at run time past the specialization budget), which `show` of a record holding an array of uncounted structs crashed on at d86b474 too (build.t's walked_arrays). rows.ren allocates 6, not 100,006, in 3.5 ms, not 6.4 (a copy with 100 times the items 187 ms, not 446, 162 MB, not 402); of the suite only slices' C changes in substance, 96 million allocations, not 164 million, 0.88× the time, its `json` kernel 0.78× (RESULTS.md, "Data stage: layout"); rows.ren's last line prints the element's fields; bench/data's rows_objs and rows_panic in build.t's loops and the release naive one, layout_walks' arrays in a walked record, test_native's Mem Lint tests of arrays of counted structs. Choices: below the table | the third fix (byte tags and niches), measured; optional.ren's last line `show`s the value, which boxes its type and hides the fix; the milestone kernel against Rust; borrowed reads of an array's struct, and swap-out of one's objects (step 7's choices, part 2); `if c then None else p` in debug builds (part 1's choices) |
| 7 (part 3) | 213b4a9 | the third fix: a sum with one constructor that has fields, one of them an object after flattening, and any number without has no tag, `Niche { obj_ctor; slot; ctors }` for `Nullable`, its first object's slot holding `ren_box(UINT32_MAX - t)` for each constructor `t` without fields, read by `ren_niche_tag` or one compare; any other sum's tag is a byte (16 or 32 bits past 256 or 65,536 constructors), `Tagged bits`, each constructor's small scalars (`Bool`, `()`, enums, sized types under 64 bits) packed above it in slot 0, the widest first, and the whole word as before where none is (to_mem.ml's `small` and `small_ctor`, mem.ml(i), emit_c.ml's `Tag_of`, ren_rt.h, Mem Lint's sum structs and niches); and the debug builds' Mem Lint fault from step 3, `if c then None else p`: Mem was right, a boxed constructor without fields is a scalar that holds no reference, and Lint's join counted the parameter dropped on the constant's path against the one moved on the other; a path where some of a class hold constants may now hold fewer references than the paths where none do, at most one fewer for each constant (test_native's two cases, bench/data/niche_join). `Option<Item>` is two words, not three: optional.ren allocates 4, not 101,004, once its last line prints `best`'s fields (4 at 7c68889 too with that line; 2% fewer instructions, the copy with 100 times the items 411 to 401 million, and an array of a million options 25.2 MB to 17.6 MB, 309 to 256 million instructions, 0.80× the time); no program or kernel of the suite compiles to different C (RESULTS.md, "Data stage: layout"); variant types of a niche'd sum cost nothing (niche_reuse: nothing allocated in release, each update a reuse in debug); bench/data's niche, niche_walks, niche_panic, niche_reuse and niche_join in build.t's loops and the release naive one. Choices: below the table | the milestone kernel against Rust; a niche'd or tagged struct as a field of another is still boxed, not flattened (an option of an option, an option in a record); borrowed reads of an array's struct, and swap-out of one's objects (part 2's choices) |
| 7 (part 4) | 94d4cf7 | the milestone: bench/native/interp, dispatch's `interp` written ADT-first (`Expr` a sum of eight constructors, `eval` a `match`), at dispatch's sizes (25,600 evaluations; 3, which prints 105), printing what dispatch's Rust twin's `interp enum` and `dyn` print (-326745600) and `ren run` does; in build.sh (which builds no twins for it), measure.sh's `time` (the ADT kernel, Rust enum and `dyn`, dispatch's descriptions, one hyperfine run) and `stats`, summarize.py's milestone table, native.t, bench/dune and build.t's loops; bench/data/interp in build.t's four loops and the release naive one. Measured on the cloud container (RESULTS.md, "The data stage: the milestone"): the ADT kernel 1.13× Rust's enum, 2.90× its `dyn`, 1.60× Ren's descriptions, which are 1.81× `dyn`; both `match`es bound by their jump table. One overhead removed: `Obj_tag`, the tag of a boxed sum all of whose constructors have fields read from its header with no scalar test (mem.ml(i), to_mem.ml's `tag_of` at a `match`'s switch and a nested pattern's test; emit_c.ml; Mem Lint, a `Boxed` operand), `eval` 965 to 886 million instructions, its time moving with GCC's layout either way (1.06× to 1.18× by default, 0.78× with branches aligned, clang 0.94×); deriv 0.90× to 0.92× and cfold 0.91× to 0.93× the time, 7% and 5% fewer instructions, the only programs of the suite whose C changes. Choices: below the table | the overheads left in `eval` (step 7's choices, part 4): the stack check, checked `+` and `-` and `env[i]`'s bounds check, the language's; the switch's unreachable default, not made undefined; a niche'd or tagged struct as a field of another still boxed; borrowed reads of an array's struct, and swap-out of one's objects (part 2's choices) |
| 8 (examples and docs) | 3545731 (examples and docs) | the review's spec and docs lenses (Step 8, as built): the bank's `transfer` with `let { from, to, amount } = t` and punned `Sent { amount, to }`, `Movement.change` with an or-pattern, a test taking entries apart in a block's parameter; the shop's `Paid { amount, charge }`, `pay` with `let Due(amount) = i.status else fail NothingDue` and `{ ..i, status: Paid { ... } }`, `checkout` by a record pattern, the `Discount` policy ADT in cart.ren, the shop's first tests, its native builds checked against `ren run`; the ledger's `get` with `orelse`; examples.t promoted; the docs review's findings (Zed's grammar `rev`, README's status, roadmap, `if found is`, §2 and the tour's rule, handlers.md, language.md's "What Ren has today", this section's grammar, tests and step 7 text, the Core paragraph, rbtree's `Node`, parser.ml's header, deps.md's example, the bank and Zed READMEs, differential.py over bench/data); the spec review's unrecorded items in "Where the data stage may differ" | the soundness review's compiler fixes; the owner's items (language.md's stale design text, foundations.md's Staging item 5 and decision 14); the open items above: a recursive `match` against descriptions, the walks' boxing, `ren check`'s blind spot |
| 8 (compiler fixes) | this commit | the soundness review's seven findings, fixed at their causes (Step 8, as built, "The soundness review's fixes"): a variant type in a dependency's type (Core Lint's `instance_of` and `equal` at two `Variant`s; descriptors that keep the variant, `Known (Variant ...)` and Core's `Applied_variant`, natively `D_variant` and `Of_variant`, `REN_D_NAMED` with the constructor's tag in `var`, so a dependency's key at `Order.Placed` isn't `Order`'s, which the interpreter got wrong; Core Lint's rows compared as sets; a generic handler's descriptors read before its captures, a debug Perceus Mem Lint failure from before the stage); `let ... else` in a handler's state (its `else` checked against the instance's type; a state's `Match` ending in the instance through Core Lint's `handler_end` and to_mem.ml's `result_layout`); `todo(x)` the panic at the call's type; Exhaust's alternatives inside another or-pattern's checked in the alternative they're in; the stateless help's `with c in Chan.send(1)`, and the type written where the arguments don't fix it; an update's record-or-constructor help, and the grammar's comment, the base's type; a handler given a small record, tuple or option boxed in a release build's description (`word_only`, from before the stage); test_data.ml's s8 tests, fourteen; bench/data's review_keys, review_state, review_state_panic and review_todo_panic in build.t's `same`, `release`, `tcc_same` and `release_naive` loops; the review's reproducers and batch scripts run again, each the same as `ren run` | a generic function whose `uses` names a dependency at a type built from its type parameter, refused at its callers (medium, from before the stage); a `with` doesn't fix its body's open type arguments (low, as specified); an update from a variant type into a record type its constructor's name shadows can't be written (low); the owner's items and the open items above |

Step 1's choices, where the sections above are silent:

- `Let_tuple` keeps its name until step 3 makes it `Let_pattern`, and
  `target` has only `Into_type` until step 2 adds `Into_ctor`.
- An update's base whose type isn't known yet is taken to be the
  target's when it's named, `Order { ..o }`, or the expected type's
  when that's a record; only with neither is it `no_record_fits`.
- A record pattern in a binding position is checked to always match by
  the parser, as a tuple's is (`binding_pattern`, recursing into its
  fields), not by Exhaust: in step 1 a braced name is always a record
  type, so the parser can tell, and its message is today's until step 3
  rewords it.
- Lowering is given the types its module can see, its imports'
  included (`Lower.program ~types`), for a record's declared fields;
  Core's `PRecord` has a pattern per field in declaration order, and the
  interpreter finds the fields' names through its types.
- "Did you mean" measures a swap of two neighbours as one edit (the
  optimal string alignment distance), so `piad` is near `paid`.
- A missing record, in Exhaust's "missing:", is written without its
  type's name, `{ paid: false, .. }`.
- An update that leaves several fields of the target ungiven reports one
  error for each; so does one that would drop several.
- An update of a unique record is built over it in place, but each field
  it keeps that's counted is still dup'd where it's read and dropped
  with the old record's cell (bench/data/update's 1000 dups and drops of
  `lines`): reuse.ml doesn't yet move a reused object's kept fields
  across. Step 7 may.

Step 2's choices, where the sections above are silent:

- A positional field with no name written, `Static(Int)`, has the name
  `""` in the AST and in `Iface.ctor`; messages that list a
  constructor's fields say "write it with one value" for it.
- The parser reports a declaration with several fields in parentheses
  and goes on, reading it as the declaration its help writes (an
  unnamed field named by the first free letter), so one run reports
  every such declaration in a file; the driver still stops after
  parsing. A variant in braces with no fields, `Rect { }`, is refused:
  "a variant in braces names its fields, but this has none", help
  "write `Rect` alone".
- A constructor with no fields written in braces, `Dot { }` or `Dot {
  .. }`, is refused like a one-field one: "`Dot` has no fields, so it's
  written alone", help "write `Dot`".
- `braces_name`: a bare `Name { ... }` where `Name` is a sum type in
  scope, and also a by-name constructor (`type Point = | Point { x: Int,
  y: Int }`), is the constructor: a sum has no record to build, so
  there's nothing to refuse. A name that's neither a type nor a by-name
  constructor bare in scope is a constructor, found through a type by
  inference, so `Nope { x: 1 }` says "there's no constructor named
  `Nope`" (it was "there's no type named `Nope`"). The ambiguity error
  points at the name, not the whole value.
- A bare `Rect { .. }` in a `let`, a `for` or a block's parameter is
  read as a record pattern by the parser, which can't tell; Resolve,
  finding it's a constructor, refuses it with the parser's message ("a
  `let` takes apart only a tuple or a record ... but `Rect { w, h }`
  might not") until step 3 moves that check to Exhaust.
- Every by-name and by-position refusal points at the whole
  constructor or pattern, and its help is `write `...`` holding exactly
  the text that replaces what's underlined (`Rect(2, 3)` becomes `Rect {
  w: 2, h: 3 }`), so a script can apply it; an argument
  `Ast.source` can't print (a block, an `if`, a lambda, a `match`) is
  `...` there. With the wrong number of arguments the help still names
  each field, `...` for one not given. A by-name pattern written by
  position still binds its names at their fields' types when the count
  is right, and a labelled one-field construction is still checked, so
  each gives one error, not a cascade.
- `ctor_shape` checks only the count: labels in parentheses are never
  right now, so "label every field of `Pt`, or none of them" and
  "expected the label `seats` here" are gone, replaced by the by-name
  error (several fields) or the by-position one (one field).
- A by-name construction whose fields are written in declaration order
  lowers straight to `Con`, its values evaluated in that order; in any
  other order each value is bound first, in the order written, as an
  update's are. So a program moved to by-name lowers to the Core it
  lowered to before.
- An update into a by-name constructor, `Placed { ..r, id }`, is built
  in step 2 for a base that's a record (step 4 adds a variant type's):
  the base's type has to be known where it's written, since the
  constructor's sum isn't a record to take it from, or it's
  `no_record_fits`.
- Exhaust writes a by-name constructor from its declaration
  (`show_space` looks it up) rather than from field names in `head`;
  one whose every field matters is written without `..`, `Rect { w: 0,
  h: 0 }`.
- A record pattern matched against a sum names the first by-name
  variant that has every field it names, `name the variant: `Rect { w,
  .. }``; with none, "match its variants instead".
- The journal (journal.ml) writes and reads a by-name variant in braces,
  as `show` does.
- Tree-sitter: a bare `Rect { ... }` stays a `record_expression` or
  `record_pattern`, as the compiler's parser reads it; `Shape.Rect {
  ... }` is a `constructor_expression` or `constructor_pattern` with the
  fields inline. A `variant` takes one field in parentheses, `off:
  Money` or a type, or a `record_type`, so the grammar no longer parses
  several fields in parentheses (types.txt's one such declaration is
  moved in this step, as the grammar's check needs it).
- bench/data's `shapes` and `interp` need only by-name variants, so
  they're as specified now; build.t says so, and steps 6 and 7 still
  add them to the loops.
- The migration chose punning where a pattern's names could become its
  fields' without a clash (`Node { left, key, value, right }` in
  rbtree's `ins`), and kept short names where the code reads as a
  formula (deriv's `Add { l: f, r: g }`) or a test's printed IR names
  them (test_native.ml); a construction too long for a line is written
  a field to a line, with a trailing comma, as a record literal is.
- bench/review_values.ren declares records `A` and `B` and constructors
  `A` and `B` of `Mix`, which by name would be the record-or-constructor
  refusal: the constructors are written `Mix.A { ... }` and the records
  `{ ... }` with the type left out, so the names it checks stay the
  same.
- Tests that pinned an error by-name variants remove keep what they
  tested: test_infer.ml's `Pt(x: 1, 2)`, "label every field of `Pt`, or
  none of them", is now the by-name refusal of the same program with
  `Pt` declared by name; its `Pro(seat: 5)`, "expected the label
  `seats`", is now the by-position refusal; test_resolve.ml's `P(x, x)`
  is `P { a: x, b: x }` and keeps "two pattern variables named `x`".

Step 3's choices, where the sections above are silent:

- `todo` is step 5's, as the step split says; the `else`'s help already
  names it ("end it with `fail`, `break` or `todo`"), the spec's text, so
  until step 5 a `let ... else` leaves with `fail` or `break`, or a block,
  an `if` or a `match` that ends in them. The refusal points at the line
  the `else` ends in.
- One pattern in parentheses is itself, `(A as x) | B`; a tuple needs a
  comma. `as` takes a lowercase name, and anything else after it is "`as`
  names the whole of what's matched, but ... isn't a name".
- The parser reads a pattern after `let` unless a lowercase name comes
  next (that's `let x = e`), after `for` unless a name and `,` or `in`
  do, and as a block's parameter that starts with `(`, `{` or a capital,
  `fn(Meters(n)) => n`. `let x = e else ...` and `let _ = e else ...` are
  the pattern form, a name or `_`, which Exhaust refuses ("the `else`
  never runs").
- A pattern that might not match, in a `let`, a `for` or a block's
  parameter, is pointed at whole, not at its part that might not match:
  test_collections.ml's `let (a, Some(b)) = ...` is now "`(a, Some(b))`
  might not match, so this `let` needs an `else`". A block's parameter is
  told apart by the name the parser gives it, `$` and its node, which no
  program writes.
- A name only some alternatives bind is reported each way round: "`x` is
  bound in `B(x)` but not in `A`", at the name, when a later alternative
  binds one the first doesn't, and "`x` is bound in `A(x)` but not in
  `B`", at the alternative, when it doesn't bind one the first does. A
  nested or-pattern is compared with its own first alternative.
- Each alternative is checked as the whole arm with its or-pattern
  swapped for it, against the arms above, guarded ones left out, and the
  arm with the or-pattern swapped for the alternatives before it; `fail`
  alternatives are each a row, as before. "this alternative never
  matches" is reported, not raised, so one arm can have several, and only
  when the arm itself can match ("this arm can never match" otherwise).
- A `let ... else`'s pattern is a test, as an arm's is: in braces, it
  names every field or ends in `..`. Its `else` is checked against the
  type of the rest of the block, which, since it leaves, is what the two
  arms of the `match` it lowers to share. It sees none of the pattern's
  names, which are bound after it.
- `as` binding an error, `Err(Short(_) as e)`, is refused as `Err(e)` is
  (Exhaust's `no_bound_errors`).
- `if let`'s help writes the pattern, and the value if it's a name, `...`
  if not.
- The first alternative that matches is the one, natively as in the
  interpreter: a later column that doesn't match, or a guard that's
  false, goes on to the next arm, not the next alternative. An
  or-pattern that binds names gives each alternative variables of its
  own and lowers the rest of the arm once for each, with a join each, so
  that each variable is set once on its path and Perceus makes it a
  `let` (rc.ml's `set_once`): set in two places, Perceus took one for a
  `var` and dropped it where it wasn't defined, which Mem Lint caught.
  The arm's body is lowered once for each alternative that binds, the
  price of keeping Perceus as it is.
- A pattern's variable is found by its id natively (to_mem.ml's
  `slot`), not by its record: lowering makes one for each alternative
  that binds it. Before, a `fail` or-pattern that bound a name was an
  internal error natively (`Not_found`); no test had built one.
- Tree-sitter: `or_pattern` is binary and nests to the left, `A | B | C`
  as `(A | B) | C`; `fail` alternatives keep the name `or_pattern`
  through an alias, at an arm's top only. In the grammar a block's
  parameter with `|` or `as` is in parentheses, `fn((A(n) as x)) => ...`,
  since `_` lexes as `wildcard` wherever a pattern may start, and `fn(_)`
  has to stay a parameter; for the same reason `let _ = e` is a
  `let_statement` whose name is a `wildcard`.
- `let ... else` didn't fit the bank, the shop or the ledger as they
  are: each refutable take-apart there is an `Option` with a default or a
  failure, which `orelse` says in one line (`self.accounts.get(id) orelse
  fail NoSuchAccount(id)`), or a `match` whose other arm gives a value.
  The bank's `worth_retrying` uses or-patterns, two arms where it had six.
- Found, not fixed (it isn't this step's, and Mem Lint stops it): a
  sum with a variant of no fields and one with an object, `type Plan = |
  Free | Pro(Int)`, returned as `if c then Free else p` fails Mem Lint
  natively, "`$if` holds 0 and 1 references on different paths", at
  e180921 too; the `Free` is a word that holds nothing. Step 7's layout
  work (`Nullable`, niches) is where it belongs.

Step 4's choices, where the sections above are silent:

- **A written variant type is checked by Resolve,** not Infer_written:
  that `Order` is a sum, `Placed` its constructor, and by name, with the
  spec's three errors, and the sum's number of type arguments. Resolve
  already reads every sum in scope, its own module's and its imports'
  interfaces, and a type declaration's field, `type Box = { p:
  Order.Placed }`, goes to its interface (Iface.of_written) without
  passing through Infer_written; Resolve's errors stop the module before
  inference, so every later pass sees only variant types that exist. A
  variant type of a private sum in a public signature is the private
  type error any type is.
- `Tree<Int>.Node` is a parse error, "a variant type's arguments are its
  sum's, written after the variant", help "write `Tree.Node<Int>`". The
  positional refusal's help names its field, `Flat(off) => ...`, `x` for
  a field with no name, and a variant with no fields, `Free => ...`; "has
  no variant" lists the variants with named fields when nothing is near,
  or says the sum has none.
- **No `Field_of_variant`:** a field read of a variant type records
  `Field_of` the sum, and Lower makes the `Field (r, s, f)` the Core
  section gives, which Core Lint, the interpreter and to_mem tell apart
  by `r`'s type.
- `as` binds a variant type only of a pattern that's a by-name
  constructor's, `Placed { .. } as p` or `(Placed { .. }) as p`; of
  another `as`, `(Placed { .. } as q) as p`, or of an or-pattern, it binds
  what's matched.
- A pattern matched against a value of a variant type: its own
  constructor's always matches, its fields at the variant type's
  arguments (Exhaust's [Of_variant], one constructor); a record pattern
  is its fields', and may leave fields out in a binding position, as a
  record's may, and lowers to its constructor's `PCon`, so Core has no
  `PRecord` at a `Variant`; another constructor's is refused, "an
  `Order.Placed` is never a `Shipped`, so this pattern never matches",
  help "a value of a variant type is always that variant: match it as
  `Placed { .. }`, or match the sum it came from".
- An update with no target whose base is a variant type is that variant
  type, a `Con` of its constructor at the `Variant`; `Placed { ..p }` of
  a `p` of its own variant type, with nothing given, is `Of_variant`;
  with fields given, `Placed { ..p, total }`, it's a `Con` at the sum,
  which reuse builds over a dead `p`. `..` from a sum names the target's
  variant in its help, or the first by-name one with the fields given.
- The note "a constructor always builds the sum" is added to a mismatch
  where a constructor, a by-name construction or an update into a
  constructor is found and its sum's variant type expected; the help is
  any mismatch's of the sum where its variant type is wanted, at the top
  or inside the same type, `Array<Order>` and `Array<Order.Placed>`. The
  help the other way writes the value checked, `Placed { ..p }`, in
  parentheses if it has a space (`check`), and `p` where no value is at
  hand.
- The method refusal fires where the sum has a method of the name and
  the variant no field of it; otherwise it's the field error, "`Order.Placed`
  has no field named `x`".
- **Natively, a variant type is erased to its sum** wherever a layout or
  a descriptor is asked for (`Ty.erase_variants`): one layout, one
  struct and one descriptor for both, so a value moves between them with
  no code. A field read and an update find the constructor's places
  through `record_fields` and `record_shape`, which `ctor_shape` answers
  for a `Variant`; an update of a small value of a variant type, a
  struct, is made as its constructor's is, its tag and the slots it has
  no field in made again (`small_ctor`, which `Con` shares); a `match`
  on a value of a variant type has no switch on its tag, and its
  `PCon` no test.
- Release specialization keys copies by the types as they are, so a
  generic function used at `Order.Placed` and at `Order` is two copies of
  one code: keying them by the sum would give a copy's Core the sum's
  type where its caller passes the variant's, which Core Lint refuses.
- Core Lint takes a descriptor to describe a type up to its variant
  types, which are described as their sums (`describe`).
- A variant type's value is its sum's in the interpreter too: `show`,
  `==`, `hash`, order, a `key` and the journal look through `Ty.as_sum`,
  so `Order`'s `key` and `show` are a placed order's. Natively, a sum
  with a `key` is refused as before, and so its variant types are.
- test_data.ml's "an or-pattern of several variants binds the sum" had
  a typo: its program defined `same`, which `ren types` prints and its
  target didn't. It now writes `if s == o then 1 else 0`, which checks
  only if `s` is the `Order` `o` is; the target is unchanged.
- The bank, the shop and the ledger don't use variant types: none has a
  function that takes one state of a sum it gets from a `match`. Their
  by-name sums (the bank's `Movement`) are built by their callers, and a
  constructor builds the sum, so `debit(..., what: Movement.Sent)` would
  make each caller match the `Sent` it just built.
- Tree-sitter: `variant_type`, the sum's `type_name`, then `.` and the
  variant, then the arguments; Zed highlights the variant as a type. A
  bare `Placed { ..p }` stays a `record_expression`, as step 2 chose.

Step 5's choices, where the sections above are silent:

- **The arms to paste start at the column of the `match`'s arms,** not
  four spaces in from `help:` as other code a help writes does (Diag's
  `code_at`): a whole line copied from the terminal, or several, pastes
  in place under the last arm. The field error's `match`, which replaces
  an expression, is four spaces in, its arms two more.
- An arm for the rest follows the three shown only when a fourth is
  missing: `_ => todo` for the values, `fail _ => todo` for the errors,
  or both when both are left. A missing `Err(_)` of a settled set is
  each of its tags, as the "missing:" note already wrote it, so there may
  be more than three of them before the rest arm is needed.
- A by-name constructor in code a help writes is bare, `Rect { .. }`,
  unless a bare `Rect { ... }` would read as a type in scope that isn't
  a sum with it (Resolve's `braces_name`); then it's after its sum as the
  module writes it, `Shape.Rect { .. }` or `billing.Shape.Rect { .. }`.
  The "missing:" note writes it the same way. A positional constructor
  is always bare: a pattern finds it through the type matched. A type
  parameter named like a constructor isn't looked at (no program does
  that). A sum the module can't name at all, from a module it doesn't
  import, can't be written qualified; its patterns are bare, which works
  unless it's shadowed too.
- The field error binds the field to its own name in the pattern, `Ring
  { r, .. } => r`, and leaves `..` out when it's the variant's only field;
  a positional variant whose label is the field is `Pin(r)`. When the
  variants have it at different types, each gets its own arm, since an
  or-pattern binds one type; when every variant has it at different
  types, the headline is the hoisting one but the help is the `match`
  ("take it from each with a `match`:", no `_` arm), since no one record
  field could hold it. The hoisting help writes the sum's declared name
  and its parameters, `type Tree<T> = { id: Int, kind: TreeKind<T> }`. A
  receiver `Ast.source` can't print is `...` in the `match`. At different
  types the arms it writes are valid Ren, but no one result type holds
  them: that's the choice the error leaves to the program, so test_data's
  paste check leaves that case out.
- `todo` fails with nothing and uses nothing: a stub whose signature
  says it fails, `fn h() -> Int ! Bad = todo`, is refused as any
  function that can't fail with what it lists; `fail Bad` is the stub
  there. A function whose whole body is `todo` and whose result isn't
  written is generic in it, `fn later<T>() -> T`, as one that only
  `fail`s is. `todo` as a name, `let todo = 1`, is the parser's "expected
  a name, found `todo`", as for any keyword.
- When both values and errors are missing, the help is chosen by the
  first one, as before, and the arms are all of them, `false => todo`
  then `fail Late(_) => todo`.
- `todo` lowers to the `Lib_panic` call itself, at its type, the
  intrinsic's two rows closed. Natively that intrinsic in the program's
  code (`todo`'s, and since the services stage's step 9 a library's
  `lib_panic`) is said
  at the call, where before it was said at the function's site; in the
  prelude and the standard library it's still said at the program's
  call that reached it.

Step 6's choices, where the sections above are silent:

- **The rule is per call, not per dependency** (the specification's
  version, refined; "Where the data stage may differ"). The
  specification's rule refuses `xs[0].area()` on an array of `square`s
  because a `counter` is installed by `let c = counter()` then `with c
  in` elsewhere, or called once as `counter().area()`; the walk follows
  a description from where it's made through `let`s, which costs one
  pass over Core, so it refuses only where the call may reach the
  stateful one. A finer analysis, through arrays, records, calls and
  results (a flow analysis of the closed world), would refuse less
  still; it wasn't needed by any program here, and the dispatch
  analysis is no narrower than the dependency (10d's "Dispatch (step
  4)"), so there was nothing to share.
- **What's followed:** a `With`'s or `With_handler`'s item that's a
  call of a handler's function (possibly `Narrowed`), and a `Let` of
  one, or of a copy of such a local, whose variable no `Assign` and no
  `&` argument anywhere in the function names, and every use of which,
  inside blocks too, is a `With`'s item or another such `let`. Anything
  else keeps the handler, the function itself used without a call
  included.
- **One wording for both:** "`c` may be a description of `counter`" even
  when it can only be that one, as the specification's tests have it.
  The handler is named as its module would write it, `counter`, or
  `shapes.counter` from another module; when several kept handlers of
  the dependency keep state, the first in the program's order (the
  prelude, the standard library, then the modules as linked) is named.
- **A `finally`'s note** is "a call as a method makes a fresh instance,
  so its `finally` would run at the end of each call"; a handler with
  both a `var` and a `finally` is said to keep state.
- **The error points at the operation's name,** `c.area()`'s `area`, as
  the other two method refusals do (`method_fails`, `method_over`).
  Each call is refused once, and every refused call is reported.
- **The help's `with` writes the arguments as written,** `with t in
  Tally.add(x + i)`, where each can be shown, and `(...)` otherwise, so
  it pastes. Its arguments are then evaluated inside the `with`, where
  the method call evaluated them before installing; for a stateless
  argument that's the same, and the help is a suggestion to read.
- **Method calls are found by their `With`'s location,** which no
  written `with` shares, rather than a new field on Core's `With`, so
  every pass that matches a `With` is unchanged; Lower records them
  with each module (`method_calls`), and with each function made for a
  request, which the driver adds to its module's.
- **The pass runs in `Driver.link`,** so `ren types` with Core Lint on
  (the tests') sees it too; `ren check` and `ren types` from the
  command line, which don't link, don't.
- **dispatch_mix keeps every site's lowering:** its calls that may reach
  `o_seen` or `t_count` are `with o in Op.run(acc)`, its argument a
  local, which a native build lowers as the method call it was (10d's
  "Dispatch (step 4)"); `total`'s `t.add(x + i)` became `let y = x + i`
  then `with t in Tally.add(y)` for that reason, and its listing still
  copies the loop for each handler, 35 statements a copy.
- **test_deps.ml's "an operation read from a value holding a handler of
  several"** kept what it tests, the lookup through `id(...)`, with a
  stateless handler of the same two dependencies; the stateful one's
  call is a refusal beside it, its help showing the dependency the
  operation was found in.
- **bench/native/dispatch's kernels keep their names,** `shapesK`, in
  the twins, measure.sh and RESULTS.md; only Ren's code says codecs
  (`codecsK`, `CodecK`, `cK_i`, `cost`).

Step 7's choices, part 1 (the measurements before, and the first fix),
where the sections above are silent:

- **Measured before at 8c7c65c, on a cloud container** (an Intel Xeon
  at 2.10 GHz, 4 vCPUs under KVM, 15 GiB, Linux 6.18, GCC 13.3; the
  owner re-measures headline numbers on the M4 Max), and after on the
  same machine: the three kernels, release, their allocations from
  `--stats` and their time from hyperfine, and bench/native's whole
  suite as measure.sh runs it. bench/native/RESULTS.md, "Data stage:
  layout", has the numbers and the commands. Timings there vary by
  about 10% run to run.
- **A kernel prints what it computes, not a value whose `show` would
  measure something else.** A walk (`show`, `==`, hashing) is given a
  word, so a small value's type is boxed program-wide wherever one is
  walked (step 10, "Small values are values"). nested.ren's last line,
  `print(priced(Draft(...)))`, boxed `Item`, and so `Unvalidated`, a
  field of an object: 200,005 allocations whatever the layout. It now
  prints the total, `10`, through a `match`. Before this step, that
  kernel allocated 66,671, one `Unvalidated` for each `Draft`, `Item` a
  struct of a tag and a pointer; now it allocates 4. rows.ren's
  `print(ls[4])` and optional.ren's `print(best)` box `Line`, and
  `Option<Item>` and with it `Item`, the same way: the second and third
  fixes should change those lines likewise, or teach the walks a struct
  (its slots described, the struct given by its address), which would
  let any small value be printed without boxing its type, more than the
  fixes ask.
- **The places** (to_mem.ml, `small`): `small` gives each field of each
  constructor a place, `Slot`, `Bits`, or the new `Flat ks`, a small
  record or tuple whose slots, in order, are the outer value's slots
  `ks`. A product's are consecutive; a sum's are each placed as a field
  of that layout is, in the first slot of it after the tag that the
  constructor hasn't used, so constructors share them as before. The
  budget is counted after flattening: four slots, a sum's tag one of
  them. `ctor_shape`, `record_shape` and `tuple_shape` take a small
  value's places from `small` (`small_of`, `struct_shape`); an object's
  never has a `Flat` one.
- **Reading one** (`flat_var`): each of its slots read (`Struct_get`),
  counted again, and made a struct (`Make_struct`), which the reader
  owns. `x.u.qty`, at any depth, is one read of the outer value's slot,
  the inner one never made (the `Field` case's `locate`; `within` maps
  a place in the inner value to one in the outer).
- **Building one** (`small_ctor`, `packed_words`, which a record's, a
  tuple's and an update's build go through): the inner struct split
  into its slots (`flat_slots`: each read and counted again, then the
  inner one dropped), which Perceus makes a free that keeps them, so
  nothing is counted. An update keeps a flattened field it doesn't
  change by reading it (`flat_var`).
- **Matching one:** a pattern on a flattened field doesn't make it to
  test it. It's a subject of its own, a variable that's never set,
  whose fields are read from the outer value's slots (`match_`'s
  `flats`); a name bound to it, `Draft(u)`, is made where the arm has
  matched (`pending`, made in `matched`, and not counted again there),
  so a path that doesn't match has made nothing it must drop.
- **Not flattened:** a nested `Tagged` or `Nullable` value, as
  specified; it's demoted as before. A record whose one slot is an
  object, in a sum whose other constructors have no fields, `| Named(n:
  Name) | Anon`, is `Tagged`, a tag and the slot, not `Nullable`: the
  niche fix generalizes that.
- **Mem Lint's rules don't change:** no slot is a struct, and a
  flattened read or build is `Struct_get`s, counting and a
  `Make_struct`, which it already checks.
- **Walked, a flattened type is boxed** as any small type is
  (layout_walks.ren). Hashing isn't tested natively: `Map` isn't native
  yet (`Map.empty`, an associated value of a generic type, is refused).
- **Three faults in boxed values' counting, which the tests found,
  fixed**, since each failed a build or the sanitizers at 8c7c65c
  (bench/data/reuse_arms.ren has each):
  - **reuse.ml paired a reset with a build by the object's size**, from
    any read of its fields anywhere in the function, the last one
    winning. A `match` whose arms read constructors of different sizes
    gave its subject one size in every arm, so an arm that builds a
    constructor of another arm's size from a unique subject wrote past
    the object: `Draft(l) => Priced { l, total }`, a heap overflow
    under AddressSanitizer, debug and release. Now a size is known
    where a read of the object's fields, or its build, comes before on
    the same path (`learn`): that read ran, so the object is that
    constructor there. A `Set` of a variable forgets what was known of
    the object it held (`forget`), after it and, conservatively, in any
    block of a statement that sets it, a loop's included, which runs
    again after the `Set`. Of the suite, only deriv's, rbtree's and cfold's
    C changed: deriv reuses 9.7 million objects, not 4.5 million, since
    right sizes pair arms the wrong ones kept apart, and allocates 31.4
    million, not 36.6; rbtree lost a reset in `Leaf`'s arm, a scalar
    that's never unique, so it never ran; cfold's drops moved.
  - **rc.ml's specialized drop nested every dead read of a field whose
    shape it knew**, guarded against a live read of the same slot but
    not against another dead one: `r.q.p.x + r.q.p.y + r.q.z` freed `r`
    keeping slot 0 three times (Mem Lint, "slot 0 kept twice"). A slot
    is nested once now.
  - **rc.ml's specialized drop of a `var` kept parts read through its
    views,** which may be of a value it held before a `Set`: `m = {
    ..m, q: { ..m.q, ... } }`, then `m` dying, freed the new `m`
    keeping the old one's `q` (Mem Lint, "is kept, but isn't a field").
    A dying variable that changes isn't specialized through its views
    (`stale`); its views' own drops still are, so an update in a loop
    reuses as before. No count in build.t moved.
- **Found, not fixed:** the step-3 agent's `type Plan = | Free |
  Pro(...)` returned as `if c then Free else p` fails Mem Lint, "`$if`
  holds 0 and 1 references on different paths", in debug builds only,
  and so does `fn pick(c: Bool, p: Option<Str>) -> Option<Str> = if c
  then None else p`: a boxed variable set to a constructor without
  fields on one path and to a parameter on the other. Release builds
  keep both as structs and pass. It's in the boxed path's counting or
  Mem Lint's join, not in the layout code, and the niche fix won't
  reach it, since debug builds keep every type boxed. Fixed in part 3,
  in Mem Lint's join (part 3's choices).
- **bench/native/build.sh** called dispatch's kernels by step 6's old
  names, `shapes2(...)`, so it stopped there: it calls `codecsK` under
  the kernels' names now. **measure.sh's `memory` part** used BSD
  time's `-l`; on Linux it uses GNU time's `-v`, still in bytes.

Step 7's choices, part 2 (the second fix: an array of counted structs
inline), where the sections above are silent:

- **The header's `objs` byte is the element's mask.** It has room: a
  struct that holds an object is a small value's, at most four slots
  (`small`'s budget), and the byte has eight bits. For an array of
  words it's 1 or 0 as before, which is the mask of a one-word element,
  so one rule counts every array: freeing it, copying it, the shared
  mark's walk and a splice's or a join's copy go through
  `REN_ELEM_OBJS` (ren_rt.c), each element's word if the stride is 1,
  else each slot the mask has; a slice's header copies its root's byte.
  An array of uncounted structs, a copied record of many scalars,
  keeps 0. Mem Lint refuses an array of a counted struct of more than
  eight slots, which nothing makes.
- **A read counts the element again**, the slots its mask has, as
  reading an array of objects counts the object again, rather than
  borrowing it while the array lives as the plan said: `Array_get`,
  `Buf_get` and the rest then have one rule for every layout in
  Perceus, borrow.ml and Mem Lint (the result is owned), and a struct
  read whole that dies is freed keeping its parts, as any counted
  struct is. A borrowed read would save a dup and a drop for each of an
  element's objects a loop reads; that's left for later, with the
  measurements to say whether it matters.
- **The C** (emit_c.ml, ren_rt.h): the compiler knows the mask, so each
  inline function takes it as a constant and its loop over the mask
  unrolls: a read, `ren_array_slots_dup_k`; a write in place,
  `ren_array_set_slots_taking_ko`, which drops the old element's
  objects; a field write in place, `ren_array_set_field_taking_o` for a
  field that holds an object, which drops the old one; and their
  buffers' in a hoisted loop, `ren_buf_slots_dup`, `ren_buf_set_slots_o`
  and `ren_buf_set_field_o`. What's out of line, the copying set, push
  and field write and a push that grows, counts by the array's own
  byte. A push of a struct whose size the compiler knows is inline
  where the array is unique and has room
  (`ren_array_push_slots_taking_k`), its words stores: the out-of-line
  push copied them with a `memcpy` of the array's stride, which made
  slices' `pages` kernel 7% slower than at d86b474 on fewer
  instructions. An array of uncounted structs compiles as before but
  for that push and the mask, 0, given to `ren_alloc_array_n` and
  `ren_array_reserve`.
- **Swap-out stays for objects and words** (swap.ml): a struct element
  changed and written back is read, counted again, and written, the old
  one's objects dropped, which copies no array; `xs[i].f = w` writes
  only the field, as before, and a row of an array of arrays, an
  object, is still moved out (`grid[i][j].sku = "h"`). Taking an
  element's objects out would save the count of the ones changed.
- **hoist.ml** agrees an array's element layout across a loop by the
  struct's number where one side is a field write, which says which
  struct but not whether it's counted. **Mem Lint** checks that a field
  written in an array's struct is that slot, at its layout, which says
  whether the old one is dropped.
- **The walks still box.** `show`, `==` and hashing are given a word, so
  a small value's type is still boxed wherever one is walked (step 10's
  rule), an array of them included (`print(ls)` boxes `Line`, which then
  goes in the array as a pointer, as before). Teaching the walks to read
  a struct by its address isn't contained: the descriptors, the walks'
  signatures, generic code that takes a word and the debug build would
  each change. So rows.ren's last line prints an element's fields,
  `bb` and `4`, not the element (rows.expected says so), as nested.ren's
  did in part 1.
- **A walk reads an array's elements as words, so a small type that's
  an array's element anywhere in a walked value is boxed**
  (`no_struct_elements`, to_mem.ml), with objects or without. Its
  arguments' structs were boxed already (`no_struct_in`), and a field's,
  which is a word of an object (`slot`), but not an array's element
  named in a field's type: `show` of a record holding an `Array<P>`,
  `P = { x: Int, y: Int }`, read each `P`'s first slot as a pointer and
  crashed, natively in release builds, at d86b474 too; with counted
  structs inline it was bench/data/update.ren's and variants_escape's
  `show`s, which the suite found. So when the descriptor of a closed type
  is made, every type a value of it can hold is looked through, its
  fields' types with its arguments, and an array's element that's a
  struct is boxed; and when one is built at run time, in a generic
  function past the specialization budget, so is each array its
  declaration names of a type it knows (build.t's walked_arrays, which
  crashed at d86b474 too). A type that nests itself in its own arguments,
  `Nest<T> = | N(Nest<Array<T>>) | E`, holds types without end, so the
  look stops at types more than 24 deep: an array of structs deeper than
  that in such a type, walked, would be read wrong, which no program
  here has (known, low).
- **Not native, so not here:** `sort` (`Array.sort` isn't in the native
  slice, so neither is `sort_by`), and `pop`, which the prelude doesn't
  have; rows_objs shrinks an array by slicing it.
- **Measured against d86b474** (RESULTS.md, "Data stage: layout"):
  rows.ren allocates 6, not 100,006, in 3.5 ms, not 6.4, and a copy
  with 100 times its items runs in 187 ms, not 446, at 162 MB, not 402.
  Of bench/native's programs and kernels, whose C was compared before
  and after, only slices (its tokens, an `Int` and a slice or two
  slices, in the `json` and `pages` kernels' arrays) and, in the mask
  alone, nbody compile to different C: slices allocates 96 million
  objects, not 164 million, and runs 0.88× as long, its `json` kernel
  0.78×.
- **The naive release build of rows.ren under the sanitizers** (build.t's
  `release_naive`) copies the array at each push, as the naive counting
  does, and takes 120 s where it took 94 at d86b474 (this machine,
  with a test run beside it): a memcpy of two words and the mask's
  `ren_dup`s an element, where each element was one pointer whose
  object was counted. A test's time only; the debug naive build, as
  before, 141 s against 156.

Step 7's choices, part 3 (the third fix: a byte tag and pointer niches,
and Mem Lint's join), where the sections above are silent:

- **Which sums have a niche** (to_mem.ml, `small`): exactly one
  constructor with fields, and one of its slots, after flattening, an
  object; any number without, none included, so `| Wrap { s: Str, n:
  Int, ok: Bool }` has no tag either, its `Tag_of` a constant. Its
  slots are that constructor's, placed as a product's, at most four,
  the product's budget; a sum that was boxed for a tag and four slots
  may now be a small value. The niche slot is its first object. A sum
  of one constructor of scalars only keeps its tag: there's no object to
  hold a niche in, and the spec asks for none.
- **A niche is by the constructor's tag**, `Scalar_ctor (-1 - t)`,
  `ren_box(UINT32_MAX - t)`, not by its number among those without
  fields, as the spec wrote it: either is a scalar no object is, and by
  tag the C reads a tag back with one subtraction. With one constructor
  without fields, `Tag_of` is one compare, as `Nullable`'s was; with
  more, `ren_niche_tag` (ren_rt.h) takes the slot, the constructor with
  fields, and the highest niche'd tag, and a scalar in that range is a
  constructor without fields. **What else can be in the slot:** an
  object, or a boxed sum's constructor without fields, `ren_box(k)` for
  its small tag `k`, which is below the range unless a sum has billions
  of constructors: `Option<Shown>` with `Shown` boxed keeps `Some(Plain)`
  as `ren_box(0)` and `None` as `ren_box(UINT32_MAX - 1)`
  (niche_walks). A niche'd value is never flattened into another, as the
  spec has it, so no niche is ever in a slot that has one of its own; an
  option of an option boxes the inner one, whose `None` is `ren_box(1)`.
- **Counting a niche:** it's a scalar in an object slot, which
  `ren_dup`, `ren_drop`, the release walk, the shared mark and the
  array copies skip, as they skip `Scalar_ctor 0` in a slot a
  constructor doesn't use; an array of niche'd values counts their slots
  by its mask as any counted struct's. The walks (`show`, `==`, hash)
  and descriptors never see one: a walked small value's type is boxed
  (step 10's rule), and a boxed sum is unchanged. Mem Lint checks that a
  niche is only in a `Niche` struct's object slot and is one of its
  constructors without fields, that the slot is an object's, and that a
  tag is 8, 16, 32 or 64 bits.
- **The byte tag** is the low 8 bits of slot 0 for up to 256
  constructors, 16 for up to 65,536, else 32 (as `small_bits` sizes an
  enum), `Tagged bits`. Each constructor's small scalars, those `pack`
  packs in an object (`Bool`, `()`, an enum, a sized type under 64 bits,
  `Float32` included), go above it, the widest first, while there's
  room; the rest take slots as before. Constructors pack independently,
  since only one is alive. A type with parameters packs too: a struct
  is one instantiation's, and generic code never sees one. Built by a
  `Pack` of the tag, an `Enum_tag`, and the fields (`small_ctor`); read
  by `Unpack` of slot 0, as a packed record's field is. **A sum with
  nothing packed beside its tag keeps the whole word**, `Tagged 64`,
  read without a mask, so its C is as before: a first build masked every
  tag, and `stack`'s `Option<Int>` match compiled to different C for an
  `and` it didn't need.
- **Not flattened, still:** a niche'd or tagged struct as a field of
  another small value, as the spec has it: the field's type is boxed
  (an option of an option, an option in a record, `Option<Plan.Pro>`,
  whose field is a `Plan`'s). Flattening a niche'd field into a parent
  that has one would need the niches not to collide; not done.
- **Mem Lint's join, `if c then None else p`** (part 1's "found, not
  fixed", from step 3). The Mem was right. A boxed constructor without
  fields is a scalar, `ren_box(t)`, which holds no reference and which
  dropping does nothing to, so Perceus drops `p` on the constant's path
  and moves it on the other, and the naive counting keeps it on both
  and drops it after; release builds keep both as structs, which Lint
  counts as owned, and pass. Lint's join puts `p` and `$if` in one class,
  since they share a bundle on the parameter's path, and counted 0
  references on the constant's path (`p`, dropped) against 1 on the
  other. It already let a path where the class holds only constants
  hold none; now a path where some of the class hold constants may hold
  fewer references than the paths where none does, at most one fewer
  for each constant, which stands for the reference its variable holds
  elsewhere, and the paths where none does agree with each other. The
  class is then given the most any path holds, so a later drop through
  it is the parameter's on one path and the constant's, which does
  nothing, on the other. A constant path that holds more than the
  others, or two fewer for one constant, is still refused
  (test_native.ml). Like the join's classes before it, this doesn't say
  which of the class holds what: a constant path that kept `p` and so
  leaked it held as many as the other and passed before as now.
- **Measured against 7c68889** (RESULTS.md, "Data stage: layout"):
  optional allocates 4, as it did at 7c68889 once its last line no
  longer `show`s the option, on 2% fewer instructions, its time within
  this machine's noise; an array of a million options is a third
  smaller and read in 0.80× the time. No program or kernel of the
  suite compiles to different C, so none is timed.
- **Variant types and `Placed { ..p }` cost nothing extra when the
  value is unique,** with these layouts too: a variant type's value is
  its sum's, so `as` binds the subject's struct and `Pro { ..q }` is no
  code; in release builds niche_reuse's loop of 1000 round trips
  allocates nothing and its C is struct copies; in debug builds, `Plan`
  boxed, each update is a reuse (build.t).

Step 7's choices, part 4 (the milestone's measurement), where the
sections above are silent:

- **The kernel** is bench/data/interp.ren's, the same `Expr` and
  `eval`, with dispatch's `run`: `rounds * (n / 256)` evaluations, `n`
  65,536 at full size and 1,000 at small, so `main.ren` (100 rounds)
  does 25,600 and `small.ren` 3, the work dispatch's `interp(25_600)` kernel and
  the Rust twin's `100 interp enum` do. It has no twins of its own:
  dispatch's are its, so build.sh skips a folder with no `rust/`, and
  measure.sh runs dispatch's binaries with the kernel's name.
- **The tag of a boxed sum none of whose constructors is without
  fields is its header's** (`Obj_tag`, `((int64_t)x->tag)`), where
  `ren_tag` tested for a scalar first: a constructor without fields is
  the only scalar a boxed sum's value is (`Scalar_ctor`, from a `Con`
  with no arguments), so a sum with none is always an object. to_mem.ml's
  `tag_of` chooses it from the sum's declared constructors (`ctors`,
  through an opaque type's representation), for a `match`'s switch and a
  nested pattern's test, and only for a variable: a constant of such a
  type, `dummy`'s `Scalar_ctor 0`, is only in code that never runs. An
  error's tag (`fail on`'s `Tag_in`, a `PTag` pattern) keeps `Tag_of`:
  an error set's tags may have no payload. Mem Lint checks the operand
  is `Boxed`. Debug builds read it the same way, so the tests check it
  under the sanitizers. Its time on the milestone kernel moves with how
  GCC lays out the jump table's targets more than with the 8% fewer
  instructions (RESULTS.md); deriv and cfold, which compile to different
  C only in this read, take 0.90× to 0.93× the time, so it stays.
- **Not removed, and why** (each measured by editing the generated C,
  RESULTS.md): the stack check at each call (0.76× the instructions
  without it), checked `+` and `-`, and `env[i]`'s bounds check (0.98×)
  are decision 15's semantics, a panic where an overflow happens. The
  switch's default arm, the "no arm of this `match` matched" panic, is
  unreachable, since a sum's value has one of its tags and the switch
  has a case for each, and `__builtin_unreachable()` there is 0.93× the
  instructions; it turns a compiler fault into undefined behaviour where
  it's a panic now, and it measured no faster here (slower, in one
  run, as layout moves it), so it's listed, not done. The environment allocated at each evaluation, which Rust
  keeps on the stack, is one allocation for about 1,200 nodes.
- **Why the descriptions beat the `match`,** in Ren and in Rust: a
  description's `eval` calls each child through its code pointer from
  the arm it's in, so the indirect calls are at eight sites the
  predictor tells apart, where a `match` is one jump table for every
  node. The ADT kernel is the program the docs teach (step 6), and it
  costs what Rust's does for the same program; turning a recursive
  `match` into per-arm dispatch (threaded code) is a code-generation
  question past this stage.

## Bytes stage, part two

The second half of foundations.md's Staging item 7a, "Strings and bytes
at Rust's speed": what strings.md's "Representation" and
research/strings/synthesis.md section 3 say to build next. A `Str` or
`Bytes` held as a 16-byte value in release builds (decision 17's
representation B) instead of a heap object, with the uncounted view of
a borrowed parameter's slice; appending in place; a block UTF-8
validator; and the parts of strings.md's API that are code, in the
interpreter and natively, agreeing. `Path` as `opaque Bytes` and `Os`'s
`ArgNotUtf8` are item 7b's; the `unicode` module, short strings inline,
a capacity-keeping `clear()`, proved copy-on-store, the retention
report, `b"…"` literals and x86 SIMD are later. The brief is
briefs/stage-bytes-2.md. Seven steps, each green on its own:

0. **This specification,** the baseline, and the tests.
1. **The boundary:** the validator, `InvalidUtf8(at, incomplete)`,
   `from_utf8_lossy`.
2. **The API:** scope 5 of the brief, interpolation and `'a'` among it.
3. **Appending in place,** on representation A, with the debug report.
4. **Representation B,** release builds, fix by fix, measured.
5. **The rest of the API:** strings.md's table and `count()`.
6. **A review:** soundness, the spec, the docs and tooling.

**Done when** (Staging item 7a's): the slices kernels' json and pages
run within 1.2× of their `_r` forms and logs within 1.1×, each within
2× of Rust; tok and sort at 0.80× or less of step 3's time, map 0.95×,
group no slower; `out`'s `+=` within 1.1× of Rust's `push_str`;
`Str.from_utf8` at 70 GB/s or more on ASCII; and strings.md's API in
both builds, agreeing. Each step's own "Done when" is below.

This stage runs beside the services stage, which owns the parser's and
checker's new forms for wirings and `|>`, the lexer's line
continuation, the scheduler and std_lib's `sync`, `sim`, `striped` and
`actors`. This one owns strings' runtime and native layout, the
validator, `VStr` and `VBytes`'s operations, and the lexer's string and
character literals; in the shared files (parser.ml, lower.ml,
prelude.ml, builtins.ml, infer_expr.ml) it adds cases and entries and
moves nothing.

**Measured here.** Numbers in this stage come from an x86_64 cloud
container (4 cores, shared), for before-and-after comparisons and
ratios against twins built and run beside them; the owner re-measures
the headline numbers on the M4 Max. There's no NEON here: the validator's
NEON path is compiled with aarch64-linux-gnu-gcc and checked under
qemu-aarch64, which can't time it, so step 1's GB/s targets are the
owner's to confirm on the M4 Max.

### The tests

**bench/strs.t** runs the programs in bench/strs/ as bench/bytes.t runs
bytes/: each `.expected` holds what `ren run` prints, `exit N`, and the
first line of stderr; `spec` says whether `ren run` is as specified, and
`native` builds each debug (Perceus and naive) and release under
AddressSanitizer and UBSan, and debug with tcc, and checks each prints,
writes to stderr and exits as `ren run` does with no object alive at
the end, and that `ren run --release` agrees. A program that doesn't
build natively yet prints `not native yet` and `ren build`'s first
line. Below them, `objects` counts what a build allocates (`--stats`),
and the last block runs the `+=` report. The harness sets
`REN_NOTES=0`, but for the report's own block. **bench/strs_big.t**
runs escape.ren, which needs about 8 GiB, only with `REN_BIG_TESTS=1`
(bench/dune's `enabled_if`): `ren run`, a debug build and a release
one, without the sanitizers, to keep to the memory it needs.
This container has 15 GB, so the step that lands it runs it here.

| program | what | lands in |
|---|---|---|
| `invalid_utf8` | every class of invalid sequence (overlong in 2, 3 and 4 bytes, surrogates, above U+10FFFF, stray continuations, lead bytes F5–FF, C0 and C1, truncated) at every offset 0 to 79, after ASCII and after characters of every width, followed by nothing, 3 bytes or 67: `at`, `incomplete` only when the end cuts a character, lossy's one U+FFFD per maximal subpart (OCaml's decoder's count); the edges of each width valid | 1 |
| `api` | `byte_len`, `is_empty`, `ascii_lower` on both types, `char_floor` and `char_ceil` at every offset of characters of 1 to 4 bytes, `chars` and `code` over them, `of_code` at the edges of each width, `'a'` literals and a `UInt8` of one, `+`, `join`, `cursor(from: 100)` | 2 |
| `api_cut_panic`, `api_cut_start_panic`, `api_code_panic`, `api_code_empty_panic`, `api_of_code_panic`, `api_floor_panic` | each panic, its first line (test_strs.ml has its help) | 2 |
| `interp` | holes of every kind (scalars, records, sums, arrays, tuples, options, maps, calls, an `if`), a string with holes in a hole, braces in a hole, `\"` in a hole's string, `\\{` and plain braces as text | 2 |
| `append` | `+=` in a loop; on a shared string; on slices, of a shared and of an unshared root, and of a slice; on a literal; on itself and on a slice of itself; `a + b`; through `inout`; 10,000 appends and 1 MB; `Bytes` the same | 2 (meaning), 3 (in place) |
| `append_count` | 20,000 appends to a `Str` and to `Bytes`, which `objects` counts | 2; 3 counts |
| `append_report` | a loop's `+=` on a string an array also holds, which the report names; one that copies only a literal, which it doesn't | 2; 3 reports |
| `slices_kept` | slices kept in a small record, an array, a map's keys and values, a set, a generic record, a type variable's value, a wide record (an object), a block's capture, `Bytes`, and returned from a function lent the string; the root dropped before they're read | 2; 4 under B |
| `slices_count` | 10,000 slices kept in an array of small records, which `objects` counts | 2; 4 counts |
| `rest` | step 5's names on `Str` and on `Bytes`, `line_col`, `count()` on every receiver | 5 |
| `escape` (strs_big.t) | `Bytes` of 2^32 + 1 bytes, slices on both sides of the 32-bit edge, read, compared, hashed and appended to | 4 |

**test/test_strs.ml** holds what a program's output can't say, each
behind `until "s1"`, `"s2"` or `"s5"` (test/helpers.ml), as
test_bytes.ml's did: every compile error with its help, every panic
with its help line, `InvalidUtf8`'s payload in a handler, lossy's
output, a hole through a type's own `show` and `+=` through `inout`.
`Bytes` keeping `len` is written plainly, a guard. Steps 3 and 4 change
nothing the interpreter shows, and no expect test builds natively, so
their tests (`objects` and the report) are bench/strs.t's. A step
leaves no `until` of its own number behind.

The kernels (bench/native/strs/, `out`, `utf8`, the slices kernels and
the `Map` claim's twins) are the baseline's and step 4's, in
bench/native/RESULTS.md.

### Representation B in Mem IR

**A `Str` or `Bytes` is a small struct of two slots in a release build:**
slot 0 the root, an object (`Boxed`), counted; slot 1 the range, a
scalar (`Int`), `off | len << 32`. It's `Struct (k, true)` whose
`sfields` are `[Boxed; Int]` and whose `skind` is `Product`, registered
by its type as any small value is (to_mem.ml's `struct_id`, so
`struct_ty` gives back `Str` or `Bytes`), so the data stage's code sees
an ordinary small record: flattening puts its two slots into a small
parent (a `{ name: Str, price: Int }` is three slots, a `(Str, Str)`
four), an array of it or of a struct holding it is inline with the
root's bit in the element's mask (stride 2, mask `0b01`, for an
`Array<Str>`), Perceus dups and drops slot 0, and Mem Lint checks it as
it checks any counted struct. A niche (the data stage's third fix) uses
the root's slot, which never holds a scalar, so `Option<Str>` is two
slots and no tag. In the C it's a two-slot `ren_struct_N`, laid out
as ren_rt.h's `ren_sv`, `{ ren_obj *root; uint64_t range; }`, which the
runtime's string functions take. The budget counts a string as its two
slots: a record of two strings and an `Int` is five, an object.

**Debug builds keep representation A throughout,** as the data stage
keeps every type boxed there: a string is a pointer to a `ren_str`, an
owner or a 32-byte slice object. A is also B's box and the 4 GiB escape,
so the one runtime serves both builds.

**Where a release build boxes.** Never by demoting the type: `Str` and
`Bytes` are never in to_mem.ml's `boxed`, since that would undo B
everywhere. Where the data stage would demote a struct's type because a
value of it must be one word, a string value is boxed there, and
unboxed where it comes back:

- **A type variable's value** (`Word`): `To_word` of a B value is its box,
  `Of_word` into B unboxes. That's generic code a release build keeps
  generic (past the specialization budget, or a descriptor's template),
  and an object's field whose declared type is a type variable,
  `Pair<T>`'s `left`, whatever `T` is.
- **Generic code reading or writing an array, map or set of `T` at
  `Str`** boxes what it reads and unboxes what it writes, by the
  container's own layout (an array's stride and mask, a map's entry
  widths), as `ren_array_get_w` already reads a sized element for a
  word.

Everywhere else a release build keeps the two words, and there's no box:

- **An object's field whose declared type is `Str` or `Bytes`** (a record
  too wide to be small, a boxed sum's constructor, an error's payload)
  takes two consecutive words, the root's bit in the object's mask. Its
  declaration's places (Mem's `dplaces`, ren_rt.h's `ren_ctor_info`)
  say so, so `show`, `==`, hashing and ordering find it, as they find a
  packed field. The field's type is known in generic code too, so a
  generic type's layout doesn't change with its arguments.
- **A handler's captures,** in its description's words: two words, as a
  field.
- **A block's arguments and result:** two entries of its arguments
  array, and two words where its result is written.
- **A block's environment** holds a captured local's address (a cell),
  which is a struct's address as well as a word's: no change.
- **A `Map` or `Set` entry** holds a key or value of `Str` or `Bytes`
  unboxed, the map's header saying each side's width and mask (part one
  kept every key a word).
- **The runtime's walks** (`show`, `==`, ordering, hashing,
  `ren_array_sort`, the NaN walk, a `key`'s wrapper) take a value by the
  address of its words and its descriptor, and a release build's
  `D_str` and `D_bytes` are two words. `as_word` of a B value passes its
  address; nothing is boxed for a walk.

**A box, and unboxing it.** Boxing a B value `{ root, off, len }` gives
the root itself when the value covers all of it (`off == 0` and `len`
the owner's `len`, a literal included) or is the escape; otherwise a new
32-byte slice object `{ len, data = root's bytes + off, root }`, which
takes the value's count on the root. Unboxing an A object `o`: an owner
gives `{ o, 0, o.len }`; a slice gives `{ o.root, o.data - o.root's
bytes, o.len }`, counting the root and dropping `o` (moving the root out
and freeing `o` when it's unique); either gives the escape `{ o,
UINT32_MAX }` when the offset or length doesn't fit. Both take what
they're given, so Mem Lint's rule for `To_word` and `Of_word` (the
result is the operand's bundle) holds; Lint allows a struct there only
for `Str`'s and `Bytes`'.

### The owner's header

**Kept at 32 bytes, today's `ren_str`, with the capacity where an owner's
`root` is:**

```c
typedef struct {
  ren_obj h;          /* nfields bit 0, REN_STR_SLICE: an A slice */
  int64_t len;        /* an owner's: the bytes used */
  const char *data;   /* an owner's: its own [bytes] */
  union { int64_t cap; ren_obj *root; }; /* an owner's room; a slice's root */
  char bytes[];       /* an owner's */
} ren_str;
```

An owner is told from a slice by bit 0 of `nfields`, which strings
don't use (`REN_STR_SLICE`); every test of `root != NULL` in ren_rt.c
moves to it. Static literals keep emit_c.ml's layout, their `bytes` at
offset 32 and `cap` their length, the bit clear and the count 0. An
owner's bytes are no longer followed by a 0; nothing may read past
`len` (step 3 finds and moves anything that does).

Why 32 and not the research's 16 (`{ count, cap }` and the bytes):
an owner is then its own A box, so boxing a whole string, the common
case at a word boundary (a generic value, a debug build), allocates
nothing; debug builds' A and release builds' B share one owner, one set
of string functions and the statics as they're emitted; and the
escape's root is an ordinary A object. It costs 16 bytes an owner,
which shows where a program keeps many small owners, a map of copied
keys. **Step 4 measures map's peak memory and time with this header and
with a 16-byte owner built as an experiment** (it needn't be kept), and
records both in RESULTS.md; if the 16-byte one saves 5% or more of
either, the review reopens this choice.

**Data from a root.** A B value's bytes are at `(char *)root + 32 +
off`, `offsetof(ren_str, bytes)`, with no load, for heap owners and
statics alike. The escape is the one exception: its bytes are its A
object's `data`. An empty value's root is a static (the literal `""`),
never NULL, so a dup or a drop never tests for one, and a niche's
scalars stay free.

### The 4 GiB escape

A value whose offset is 2^32 or more, or whose length is 2^32 - 1 or
more, is the escape: its root is an A object (an owner, or a slice
object that counts the owner) holding the real `data` and `len`, and its
range's length field is `UINT32_MAX` (`range >> 32 == UINT32_MAX`, its
offset 0). `ren_sv_len` and `ren_sv_data` test that once: the length
field if it isn't `UINT32_MAX`, else the object's. A slice of a large
owner whose offset and length fit is an ordinary B value, so only a
value that starts past the first 4 GiB of its buffer, or is 4 GiB
long, pays. Loops read a value's
length and data once before they start (part one's fix 1b, hoist.ml), so
the test is once a loop, not once a byte; step 4 measures what it costs
code that never meets one (2% or less on each kernel, or say why). An
escape is written or appended to in place as A is, when its object is
a unique owner, and copied otherwise.

### Uniqueness under B (rule U)

A write or an append in place needs the root's count to be 1
(`ren_is_unique`) and the root to be an owner (the escape's object
follows A's rule, below).
**A release build writes and appends in place through a slice of a
unique root,** whatever its range. It's sound because a root whose count
is 1 is seen by one value: every other value of it, counted, counts it,
and a part of it (the uncounted view, below) is counted before what
it's a part of is consumed (rule B), and a write or an append consumes
it. So the bytes outside the value's range are no one's. An append in
place first sets the owner's `len` to `off + len` (the bytes after the
range are dropped) and writes after it; one that must grow copies only
the value's range into the new owner, which drops the bytes before it
too. A debug build keeps today's rule for A: in place only on a unique
owner, a slice's range copied into an owner of its own first.

`Bytes`' writes at an offset (`ren_bytes_writable`) follow the same
rule.

### The uncounted view

**A slice of a borrowed parameter's string is a part of it,** as a field
read is (decision 17, "what doesn't escape costs nothing"): its root
slot is the parameter's root, not counted, and borrow.ml marks it a
part of the parameter, so Perceus and Mem Lint follow it as a
`Struct_get` of the parameter. It's counted, one `Dup` of its root, where
Perceus would count a part: when it's stored (in a record, an array, a
map, a set, a handler's description), returned, passed to a callee that takes it, or when what it's part of is
consumed. A block's capture is its local's address, so a slice a block
reads stays uncounted. Release builds only: in A every slice is an
object that counts its root.

### Appending in place

**`s += t` is `s = s + t`,** and `+` on `Str` and `Bytes` is
`ren_str_concat`, which copies both into a new owner. Where the left
side dies at the `+` (a `+=` always; `a + b` with `a` dead after),
rc.ml gives `ren_str_concat_taking`, as it gives `push` its `_taking`
form: if the root is unique and an owner it appends in place when it has
room, and otherwise grows it to at least twice its capacity (realloc,
in place when the allocator can) and appends; if not, it copies into a
new owner with that same doubled room, so a loop that copies a literal
on its first pass appends in place from then on. Plain `a + b` copies
into an owner of exactly its size. When `t` shares `s`'s root (`s +=
s`, `s += s[1..3]`, or `t` a borrowed view of it), `_taking` reads
`t`'s offset in the root before it grows and its bytes from the grown
owner after. The same for `Bytes`. A capacity of 32 bytes at the least.
The interpreter's `+=` stays quadratic: it's the dev loop, and meaning is
what has to agree.

**The report.** A debug binary counts, for each `+=` and `+` site, how
many times its left side was copied because its owner wasn't unique (a
literal, a value something else holds, or a left side still used after),
and when `main` returns (not on a panic) prints one note on stderr for
each site that copied on more than one pass, in the order of the
program's sites:

```
note: this `+=` copied its string on 100 passes, since something else held it
  ┌─ append_report.ren:13:5
13 │     out += "x"
   │     ^^^^^^^^^^
  help: build the string once: join, or keep it unique
```

(`+`'s says "this `+` copied its left side".) It's a report, not a
warning, rendered from the site's pieces as a panic is. `REN_NOTES=0`
silences it; the harnesses that compare a native build's stderr with
`ren run`'s (bench/build.t, bytes.t, strs.t, and any other the step
finds) set it from step 3, but for the report's own test. The
retention report, when it's built, uses the same channel. Release
builds and `ren run` report nothing; stdlib.md says so, and that the
capacity is native only.

### The validator

**Keiser and Lemire's block validator** ("Validating UTF-8 in less than
one instruction per byte", 2021; research/strings/track-b/c/b5.c): three
16-byte tables looked up by the previous byte's high and low nibbles and
the current byte's high nibble (`vqtbl1q_u8`), `vextq_u8` for the
previous bytes, the 3- and 4-byte continuation check, and an all-ASCII
fast path, 64 bytes a block, its error vector tested once a block so
the failing block is known. It replaces `ren_utf8_valid`'s byte loop
with `int64_t ren_utf8_check(const char *p, int64_t n, bool
*incomplete)`, -1 or `at`. Built where `__ARM_NEON` is defined and
`__TINYC__` isn't; elsewhere (tcc, x86_64, this container) a scalar path:
eight bytes at a time while they're ASCII, then the byte decoder.

**Exact.** It accepts what OCaml's `String.is_valid_utf_8` accepts and
nothing else: no overlong forms, no surrogates, nothing above U+10FFFF,
no bytes C0, C1 or F5 to FF. So `ren run` and native builds can't
disagree.

**On failure,** the scalar decoder rescans from the character boundary at
or before the failing block's start: from it, back over at most 3
continuation bytes (`10xxxxxx`), since the blocks before it were valid
and an error found in block k can begin up to 3 bytes into block k - 1.
It gives `at`, the first byte that isn't part of a valid character, and
`incomplete`, true when the bytes from `at` to the end are a proper
prefix of a valid encoding (the end cut a character); `C3` at the end
is incomplete, `E0 80` and `F5` at the end aren't. The interpreter
computes both with OCaml's decoder (`String.get_utf_8_uchar`).
`from_utf8_lossy` writes U+FFFD for each maximal invalid subpart, the
decoder's invalid decodes (Unicode's and WHATWG's rule), and keeps a
byte order mark.

**The differential test** (step 1): test/utf8/, an OCaml generator of
VERIFY.md's inputs (2M random ones, as b5.c's agreement test makes
them, and the boundary cases of verify/c/b5big.c) with OCaml's verdict,
`at` and `incomplete` for each, and a C program that checks the block
validator and the scalar one against them; dune builds and runs both in
`dune test`, and the NEON path under qemu-aarch64 in an alias of its
own, where qemu is installed (here; the M4 runs it natively).

### The API

In the interpreter and natively, every program, test and doc moved in
the step that changes a name, with the compiler's errors as the list:

- **Step 1:** `InvalidUtf8(at: Int, incomplete: Bool)` in the prelude,
  builtins.ml and intrinsic.ml, and every use at once (`Fs.read_str`,
  examples/just, test_deps, test_eval, test_journal, deps.md, and what
  the checker finds); `Str.from_utf8_lossy(b) -> Str`.
- **Step 2:** `s.ascii_lower()` and `Bytes.ascii_lower()`; `byte_len()`
  and `is_empty()` on `Str`, `Bytes` keeping `len`; `+` and `+=` on
  `Str` and `Bytes`, which `concat`'s removal needs; `xs.join(sep)` on
  `Array<Str>`; `s.char_floor(i)` and `s.char_ceil(i)`, intrinsics;
  `s.chars()`, a value cursor in the prelude (streams.md, "Data: cursors
  you keep") yielding one-code-point slices; `c.code()` and
  `Str.of_code(n)`, intrinsics; `b.cursor(from: Int = 0)`, a default
  given by name (Stage 11a, "Parameters with defaults"), its `at()` and
  every `at` it reports counting from `from`. **Character literals**,
  `'a'`, an `Int` literal of its code point, with the escapes `\n`, `\t`,
  `\\` and `\'`, checked where stored as any literal is (decision 15),
  a non-ASCII one refused in a `UInt8`. **Interpolation,** `"…\{e}…"`:
  the lexer reads a hole's expression to its matching `}`, counting
  braces and skipping nested strings, on one line; the AST's string is a
  list of literal pieces and holes; Lower makes it `show` of each hole
  joined by `+` left to right, so the first piece copies and the rest
  append in place. `\\{` is a backslash and a brace. Tree-sitter's
  grammar has interpolation and character literals as nodes, not a
  regex, with its corpus, and Zed's highlights mark a hole's `\{` and
  `}` and a character literal.
- **Step 5:** `includes`, `ends_with`, `strip_prefix` and `strip_suffix`
  (an `Option` of the rest), `split_once` (an `Option` of the two
  sides), `lines` (an `Array`, split at `\n`, a `\r` before it dropped,
  no last empty line, Rust's `lines`), `fields` (an `Array` of the runs
  between ASCII whitespace), `replace` (every match, left to right, not
  overlapping), `ascii_upper`, on `Str` and `Bytes` alike; `s.line_col(at)`,
  1-based, columns in code points; `count()` with no predicate on arrays,
  maps, sets and cursors (operators.md). Mostly prelude Ren over
  `index` and slices. ASCII whitespace is `trim`'s: space, `\t`, `\n`,
  `\r` and form feed. Every name goes in stdlib.md's table.

### Errors and panics

Each is a test in test_strs.ml; strings.md words the first four
exactly. A help names the receiver as written (`name`, `line`, or `s`
where it isn't a name), and a panic's numbers are the values it met.

Step 2, at compile time:

```
error: `Str` has no `len`: bytes, or characters?                        (Infer)
  help: bytes: `name.byte_len()`; code points: `name.chars().count()`;
        what a reader sees as characters: `unicode.graphemes(name).count()`
  help: `name.is_empty()` asks whether it has any

error: a `Str` can't be indexed: `s[i]` would be a byte                  (Infer)
  help: a byte: `s.bytes().u8(i)`; a slice: `s[i..j]`; characters: `s.chars()`

error: `s.lower()` is now `s.ascii_lower()`                              (Infer)
  help: for every script's case, `unicode.lower(s)`

error: `'é'` isn't a byte: it's 2 bytes in UTF-8                         (Infer)
  help: compare text as text: `c == "é"`

error: `concat` is gone: strings are joined with `+`                     (Infer)
  help: `a + b`; in a loop, `out += s`; many at once, `xs.join(sep)`

error: `'ab'` holds 2 code points; a character literal holds one         (lexer)
  help: text is written in double quotes: `"ab"`

error: an empty character literal                                        (lexer)
  help: a character literal holds one code point, `'a'`

error: an empty hole: `\{}` holds an expression                          (lexer)
  help: a brace is written `{`, and a backslash and a brace `\\{`

error: this hole has no `}`                                              (lexer)
```

`concat`'s error is for `a.concat(b)` and `Str.concat(a, b)` alike, and
today's "`Str` has no `+`" error goes. A hole whose type has no `show`
(a block) gets `show(x)`'s error at the hole.

Step 2, panics, in every build at the same point:

```
error: panic: slice 0 to 1024 ends inside a character
  help: to cut at most 1024 bytes, end at `line.char_floor(1024)`

error: panic: slice 2 to 6 starts inside a character
  help: to start where a character does, use `line.char_floor(2)` or `line.char_ceil(2)`

error: panic: `code()` takes one code point, and this string has 2
  help: for each code point: `for c in w.chars()`, and `c.code()`

error: panic: `code()` takes one code point, and this string is empty

error: panic: `Str.of_code(55296)` isn't a Unicode scalar value
  help: a scalar value is 0 to 0x10FFFF, but not 0xD800 to 0xDFFF, the surrogates

error: panic: `char_floor` 4 is out of bounds for a string of length 3
```

"at most N bytes" is the slice's length, `j - i`, and the floor is at
`j`. `split_at` inside a character panics as its first half's slice
does, with the same help. `char_ceil`'s bounds panic is `char_floor`'s
with its name.

Step 5, panics:

```
error: panic: `line_col` 30 is out of bounds for a string of length 23

error: panic: `line_col` 8 is inside a character
  help: the character it's in starts at `text.char_floor(8)`

error: panic: `replace` needs a string to replace that isn't empty
```

No panic is added for the escape: a slice past 4 GiB is the escape, and
`ren run`'s strings have no limit but memory.

### Steps

0. **This section, the baseline and the tests.** The baseline, on the
   owner's M4 Max as part one measured it: the research's workloads in
   Ren in bench/native/strs/ (tok, sort, map, group, logs from
   track-b/c/b1.c and gen.c, the same inputs), `out` (b3's 1M JSON
   records and 1M log lines by `+=` and by `a + b`, at 5,000 and 50,000
   to show the quadratic), `utf8` (1 MiB ASCII, CJK and mixed, GB/s),
   each with Rust and Go twins; the slices kernels against their `_r`
   forms; and the `Map` claim (maps' Rust twin with FxHash, and the
   research's `Map<Str, Int>`). **Done when** this section, the tests
   above (each marked for its step), and the baseline in RESULTS.md
   are on main.
1. **The boundary.** **Done when** `utf8` runs at 70 GB/s or more on
   ASCII, about 9 on CJK and 13.5 on mixed on the M4 Max (the research's
   NEON numbers, 73.1, 9.01 and 13.5), the differential test finds no
   disagreement on either path, and `invalid_utf8` and s1 are on.
2. **The API.** **Done when** test_strs.ml's s2 is on, strs.t's step 2
   programs are as specified and the same natively, and every
   example's tests pass.
3. **Appending in place,** on A. **Done when** `out`'s `+=` runs within
   1.1× of Rust's `push_str` (the research: 157.5 ms in place against a
   builder's 158.8 on JSON, 93.5 against 92.2 on logs), 50,000 records
   take about 10× what 5,000 do, `a + b` in a loop stays quadratic and
   is reported in a debug build, `objects` says fewer than 200 for
   append_count in both builds, and the report's block prints the note.
4. **Representation B,** release builds, with the uncounted view, the
   escape and unboxed map entries, fix by fix, each measured before and
   after. Expect to touch to_mem.ml, emit_c.ml, rc.ml, borrow.ml,
   hoist.ml, Mem Lint, the runtime's string functions (each takes a
   value, or a root and a range) and the map runtime. Check each
   kernel's release assembly for the clang loop-strength-reduction
   fault (VERIFY.md, problem 1): emit the range unpacked into two locals
   before a loop, and an empty `asm` on the index only if that fails,
   measured, with a comment saying why. Build the kernels once with
   `-DREN_RC_SHARED` and record the uncontended cost. **Done when**,
   against step 3's numbers: tok and sort at 0.80× or less (the
   research: 0.75× and 0.76×), map 0.95× or less (0.91×), group no
   slower, logs 0.90× or less (0.84×) or a tie explained by the clang
   fault; the slices kernels' json and pages within 1.2× of their `_r`
   forms and logs within 1.1×; every slices and `_r` kernel within 2× of
   Rust; the escape 2% or less on each; nothing else in bench/native
   slower by more than noise; `objects` says fewer than 200 for
   slices_count in release; and strs_big.t is as specified. A target
   that can't be met is said, with numbers.
5. **The rest of the API.** **Done when** s5 is on, `rest` is as
   specified and the same natively, `count()` and `count(f)` work on
   arrays, maps, sets and cursors, and every new name is in stdlib.md's
   table.
6. **The review,** the brief's three lenses: soundness (an append or
   write through a slice of a shared root, a slice of a slice, a
   borrowed string's slice stored, returned or captured, the escape at
   its edges, the rescan at block edges, Mem Lint and the sanitizers
   over all of it), the spec against strings.md and decision 17, and the
   docs and tooling (README's status and roadmap row, stdlib.md,
   strings.md's "Already built" line, the grammar). **Done when** what
   blocks is fixed and the rest is listed with its severity.

### The baseline

Measured on an x86_64 cloud container (4 cores, shared), at 78b28ec,
release builds by GCC 13.3 -O2 (`cc` here), rustc 1.97.0 and Go 1.24.7:
numbers for ratios, which the owner re-measures on the M4 Max. Wall
time, since the container has no cycle counters: 7 runs interleaved,
medians, ms a round, each workload run at R rounds and at 0, a round
(median at R - median at 0) / R. bench/native/RESULTS.md, "Bytes stage,
part two: the baseline", has the spreads and the commands
(bench/native/strs/build.sh and measure.py). The workloads,
bench/native/strs, are research/strings/track-b's over gen.c's inputs,
byte for byte; every Ren, Rust and Go run prints the same check.

| kernel | Ren | Rust | Go | Ren / Rust |
|---|---|---|---|---|
| tok | 37.4 | 25.3 | 89.8 | 1.48× |
| sort | 737.5 | 156.9 | 306.9 | 4.70× |
| map (Rust FxHash / std) | 1110 | 652.4 / 886.8 | 514.3 | 1.70× / 1.25× |
| group (FxHash / std) | 475.9 | 413.7 / 461.4 | 228.6 | 1.15× / 1.03× |
| logs | 341.3 | 238.6 | 624.9 | 1.43× |
| out json, 5,000, piece by piece / a record at a time | 771.3 / 477.7 | 0.90 | 2.35 | about 860× |
| out json, 50,000 (3 runs) | 304,990 / 192,705 | 12.5 | 38.1 | |
| out logfmt, 5,000 | 903.5 / 913.8 | 0.55 | 3.12 | about 1,640× |
| out logfmt, 50,000 (3 runs) | 307,890 / 310,803 | 4.8 | 54.3 | |
| out json / logfmt, 1M | not run (quadratic) | 188.9 / 142.2 | 502.7 / 602.6 | |
| utf8 ASCII / CJK / mixed, GB/s | 1.64 / 0.84 / 1.17 | 36.75 / 0.90 / 1.92 | 12.32 / 0.63 / 1.19 | |
| slices logs, slices / `_r` | 24.4 / 15.5 (1.58×) | 11.4 / 17.2 | 15.7 / 15.6 | 2.14× / 0.90× |
| slices json | 118.6 / 70.1 (1.69×) | 62.1 / 32.9 | 252.0 / 149.0 | 1.91× / 2.13× |
| slices pages | 8.01 / 3.90 (2.05×) | 2.14 / 1.66 | 23.1 / 4.61 | 3.74× / 2.35× |
| maps (Rust std / FxHash) | 64.6 | 98.0 / 65.3 | 148.6 | 0.66× / 0.99× |

Ren is slower than the research's C model of A on every workload: tok
1.48× Rust (the model's 1.22×), sort 4.70× (2.33×), logs 1.43× (1.31×).
Appending is quadratic: 50,000 records take 340 to 403 times what 5,000
do. Ren's map counts with `get` and `set`, two probes an update, as it
has no entry API; Rust sorts with `sort_unstable`. The 50,000-record
`out` rows are 3 runs, since one Ren run takes about 5 minutes.
`ren run main.ren` can't finish: the interpreter's `set_u8` copies the
buffer, so making a 100 MB input is quadratic there.

**Hot roots, uncounted contention.** Built with `-DREN_RC_SHARED`,
every count atomic: up to 10% slower on tok, sort, slices' logs and
`logs_r` and maps, within noise elsewhere; group and logs ran 9 to 17%
faster in two sessions, unexplained (their rounds are differences of 3
to 4 s runs whose input takes up to 1.9 s to make). The contended case
is 11b's.

**The `Map` claim, restated.** The bytes stage's step 3 "0.69×" was
against Rust's default SipHash. Here bench/native/maps runs at 0.66× of
that twin and **0.99× of the same twin with FxHash**
(bench/native/maps/rust/fx.rs): Ren's `Map` matches Rust written for
speed, it doesn't beat it. On the research's `Map<Str, Int>` workload
(map, above) Ren is 1.25× Rust's std and 1.70× FxHash, with keys
boxed; step 4 unboxes them.

### Where this stage may differ

Choices where strings.md, decision 17 and the brief are silent:

- `+` and `+=` on `Str` and `Bytes` land in step 2, since `concat`'s
  removal needs them; in place is step 3's.
- An object's field of declared type `Str` or `Bytes` takes two words in
  release builds, and a block's arguments, results and a handler's
  captures do too; only a type variable's value, and generic code over
  a container of one, is boxed. The walks take a value by address.
- A release build appends and writes in place through a slice of a
  unique root (above); a debug build, on A, only through an owner.
  Growing a slice copies only its range.
- Copies made by `+=` and `_taking` get doubled room; plain `a + b` an
  owner of its exact size. An owner's bytes have no 0 after them.
- The report counts `+` sites too, and a copy of a literal or of a left
  side still used after, and prints when `main` returns.
- The wording of the errors and panics strings.md doesn't word:
  `concat`'s, a character literal's, a hole's, a slice that starts
  inside a character, `code()`, `of_code`, the bounds of `char_floor`,
  `char_ceil` and `line_col`, and `replace`'s.
- `incomplete` is "the bytes from `at` to the end are a proper prefix of
  a valid character"; a character literal's escapes are `\n`, `\t`, `\\`
  and `\'` (there's no `\r` in either kind of literal).
- `strip_prefix`, `strip_suffix` and `split_once` give an `Option`;
  `lines` and `fields` an `Array`, with Rust's `lines` and
  `split_ascii_whitespace`'s meaning, whitespace `trim`'s set.
- A value is the escape when its offset is 2^32 or more or its length
  2^32 - 1 or more; an escape changes in place by A's rule.
- The escape's test is in strs_big.t, run only with `REN_BIG_TESTS=1`;
  steps 3 and 4's tests are bench/strs.t's, since no expect test builds
  natively.
- Step 1's tests are written with today's names (`concat`, `show`,
  `len`), not step 2's, so they run at step 1. The differential test's C
  program makes the inputs and OCaml checks them, and its 1 MiB texts are
  20 prefixes a kind in `dune test`, 3,000 by hand.
- `Str.from_utf8_lossy` of valid bytes is those bytes, counted again,
  not a copy.
- Step 2: a character literal that isn't closed, or holds an escape it
  doesn't have, is an error of the lexer's ("this character literal isn't
  closed", "`\r` isn't an escape" with its escapes as the help).
  `\{e=}` with anything but a name or a path before the `=` is "only a
  name or a path can come before `=` in a hole", help "write the text
  before it yourself"; an `=` that ends `==`, `!=`, `<=` or `>=` isn't
  one. The text written is the path as written, trimmed, then `=`.
- Step 2: a help that names the receiver names it as the source writes
  it when that's a name or a path (`line`, `self.name`), else `s`, in
  `ren run` and natively alike; for a `split_at` it's the place split.
- Step 2: `'é'` is refused only in a `UInt8`; in an `Int8` or a wider
  sized type it's checked as any number is.
- Step 2: `+` with one of the module's own opaque types on its right,
  `"<" + self` in a member of an `opaque Str`, takes what it's
  represented as, as an argument does, so the many `show`s written with
  `concat` move to `+` unchanged.
- Step 2: an interpolated string whose hole is a `Str` uses it as it is,
  without `show` (the same value), and a string of one hole is that value.
- Step 3: a copy made by `_taking` gets room for twice the left side's
  length, not twice its owner's room: a loop that copies a shared string
  on every pass would otherwise double the room it asks for each time
  (2^100 bytes after 100 passes of append_report.ren's first loop).
  Growing a unique owner in place doubles its room.
- Step 3: the report's sites are a `+=` and a `+` whose result is put
  back in the variable its leftmost left side is, `o = o + a + b`'s
  `o + a`, and it counts a copy only when the left side was held by
  something else (a count above 1), not a literal's or a slice's copy.
  Counting every `+` site, and literals, reported `print("a" + show(i))`
  in a loop, and any loop that starts each string from `""` (json_plus's
  `tags`, `json_quoted`'s `o`), none of which is quadratic. So
  append_report.ren's first loop reports 99 copies, its first pass's
  being of the literal.
- Step 3: a `+` whose left side doesn't die there is the `+` that
  borrows both (rc.ml turns `Str_concat_taking` back into `Str_concat`
  where its left side isn't moved), copying into an owner of the exact
  size, and isn't counted by the report. A parameter given to a `+`'s
  left side is owned (borrow.ml), as one given to `push` is.
- Step 3: `show` of an `Int`, natively (`ren_show_int`), writes its digits itself, not with
  `snprintf`, which took a fifth of json's time once appending was in
  place.
- Step 4: a tuple's part and an error's payload hold a `Str`'s box,
  not its two words: a tuple's parts' types are its arguments, as a type
  variable's are, and an error's walk finds its payload by its count of
  words. A block's arguments and value, a handler's arms' arguments and
  value, what a handler captures and a `with`'s value hold the box too,
  where the spec gave two words: they're words throughout the runtime's
  blocks and descriptions, and a box costs only where a slice crosses one.
- Step 4: a walk that only reads a `Str` is given its two words as an A
  slice made on the stack for the call (count 0), not "by the address of
  its words": the walks are A's, unchanged, and see a box or a view
  where they meet a string, and two words where an array or a field
  holds them. A map's key is boxed only if the map keeps it.
- Step 4: a value past 4 GiB panics where it's made, until the escape.
- Step 4 (part 2): the uncounted view is a slice of any `Str` or `Bytes`
  a function holds in a variable that never changes, not only a borrowed
  parameter's: a local's, a field's or an element's is a part of what
  holds it as a borrowed parameter's is. A slice a block captures is
  counted once, where it's put in the captured local, which is a slot
  that owns a reference, not uncounted as "The uncounted view" says.
- Step 4 (part 2): element reads are lent too, in both builds, an
  array's element a part of the array as a field read is of its object
  (the data stage's "a borrowed read", left for later there), where the
  array's variable never changes and nothing in the function takes the
  array; an array that's written keeps its reads counted, for swap.ml.
- Step 4 (part 2): freeing an array drops a run of elements that hold
  one object at once (`ren_release_n`), a release build's slices of one
  input most often.

### Step 1, as built

**The validator** is ren_rt.c's "UTF-8" section. `ren_utf8_check(p, n,
&incomplete)` gives -1 or `at`. Where `__ARM_NEON` is defined and
`__TINYC__` isn't, it's b5.c's block validator: its three tables, 64
bytes a block, an all-ASCII block skipped. Two changes make the failing
block known without slowing the ASCII path. A block returns its own
error vector, tested once (`vmaxvq_u8`), and the loop stops at the first
block that has one. The "left open" vector is a mask (`vcgtq_u8` of the
last 16 bytes against `maxv`), ORed into the ASCII test, so an ASCII
block after a block that left a character open costs nothing extra.
On failure the scalar decoder rescans from `ren_u8_back(p, i)`. That's
the first byte that isn't a continuation among the 3 before the failing
block's start `i`, else `i`. It's sound because every byte before `i`
was checked with no error, so the one thing left over is a character
that starts in those 3 bytes and that `i` cuts. A run of 3
continuations before `i` ends a whole 4-byte character. The rescan runs
to the first error, which is in that block or the 3 bytes before it.
The end is handled as b5.c handles it: a zero-padded last block, or the
last full block's open mask.

Elsewhere (tcc, x86_64, this container) `ren_utf8_check` is
`ren_utf8_check_scalar`, the scalar path, which is also the rescan. A
run of ASCII is skipped eight bytes at a time (`memcpy` into a
`uint64_t`, tested against `0x80…80`). A character with 3 bytes after
it is decoded by the range table with no test of the end. Anything else
goes to `ren_utf8_char`, which gives a character's length or minus its
maximal invalid subpart's. The first version tested eight bytes before
every character and ran CJK at 0.53 GB/s against the old loop's 0.88.
Trying the eight-byte skip only after an ASCII byte fixed it.
`incomplete` is `ren_utf8_cut`: the subpart at `at` runs to the end and
starts with a lead byte C2 to F4.

In Mem, `Utf8_valid` became `Utf8_error` (`[Boxed] -> Int`, -1 or `at`),
`Utf8_incomplete` (`[Boxed; Int] -> Bool`, only on the failing branch)
and `Utf8_lossy`. `Str.from_utf8` builds its error the way a Core `Tag`
is built: `at`, `incomplete`, then their types' descriptors, in a
shape of the tag's id. Debug, release, sanitizer and tcc builds all run
the same functions.

**`InvalidUtf8(at: Int, incomplete: Bool)`** is the scheme's label
`{ name = "InvalidUtf8"; payload = [int; bool] }`. The interpreter
(builtins.ml) runs `String.is_valid_utf_8`, then on failure walks
`String.get_utf_8_uchar` to the first invalid decode. Its `at` is
there, and `incomplete` is that decode reaching the end from a lead
byte C2 to F4. Moved in the same commit: prelude's `Fs.read_str`,
examples/just (main.ren and README), test_deps, test_eval and
test_journal (the signatures, the `fail InvalidUtf8(_, _)` arm and the
printed payloads, only those lines), bench/bytes/writes_alias.expected's
`Err(InvalidUtf8(0, false))`, test_strs.ml's member lists (now ending
`from_utf8_lossy`), deps.md and stdlib.md (a paragraph, "From bytes to
a string"). The checker's errors were the list. A signature shows the
tag as `InvalidUtf8(Int, Bool)`, since a label's payload has no names.

**`Str.from_utf8_lossy(b)`**: the interpreter decodes with
`String.get_utf_8_uchar` and writes `Uchar.rep` for each invalid decode.
`ren_utf8_lossy` counts the length first, then writes the copy. Both
return the bytes themselves when they're valid, which keeps a BOM.

**The differential test**, test/utf8/, differs from the spec in one
way: the C program makes the inputs and OCaml checks them, the other
way round from the spec. That way one generator, b5.c's own, serves
both, and so does qemu. diff.c is linked with ren_rt.c itself. It runs
b5.c's test (2,000,000 texts of 1 to 200 bytes, of five kinds, with up
to two bytes changed) and b5big.c's sweep (an ASCII run of 0 to 299
bytes, every prefix of six sequences, then 0 to 63 bytes of ASCII),
both after ASCII and after 3-byte characters. It also runs b5big.c's
1 MiB texts, 20 prefixes a kind (b5big.c ran 3,000), for 2,108,100
inputs, 1,513,311 of them invalid. For each it compares
`ren_utf8_check` and `ren_utf8_check_scalar` with a reference written
there. The reference decodes a code point in full and checks its
range, and `incomplete` comes from a table of every proper prefix of
every scalar value's encoding. Then it writes each input with the
runtime's `at`, `incomplete` and lossy length to check.exe. check.exe
holds them against `String.is_valid_utf_8` and the interpreter's own
built-ins, called as test_eval calls them. neon.sh builds the same with
`aarch64-linux-gnu-gcc -O2 -static` and runs it under `qemu-aarch64`,
or prints `neon: skipped, no <tool>`. Both run in `dune test`, about 6 s
natively and 25 s under qemu, in parallel. Results: 0 disagreements on
either path, against the reference and against OCaml. With b5big.c's
full count (`diff.exe check 3000`, 2,123,000 inputs, 1,521,375 invalid)
there are also 0 disagreements, natively (30 s) and under qemu
(`qemu-aarch64 diff_neon.exe check 3000`, 112 s). Planting one bug (C0
taken as a 2-byte lead) gave 18,244 disagreements on both paths.

**The tests.** bench/strs/invalid_utf8.ren and test_strs.ml's three s1
tests used step 2's interpolation, `+=`, `is_empty`, `byte_len` and
`Str.of_code`. They're rewritten with today's names (`concat`, `show`,
`len`, `== ""`, a literal U+FFFD), with the same outputs, so they run
at step 1. Step 2 moves them with the rest. invalid_utf8.ren is as
specified, and the same natively in every build, with no object alive
at the end. s1 is on, and no `until "s1"` is left.

**Measured** (x86_64 cloud container, 4 cores, shared; the scalar path;
wall time, since there's no `perf` here). `diff.exe bench K 1048576` is
b5.c's bench: one 1 MiB text validated until 256 MiB are, by
`ren_utf8_check` and by the old byte loop copied in as `before`. The
Rust twin, test/utf8/from_utf8.rs, is std's `str::from_utf8` on the same
text (`diff.exe dump`).
Seven runs interleaved, medians and spread, GB/s:

| text | before | step 1 (scalar) | Rust | step 1 / before |
|---|---|---|---|---|
| ASCII | 1.01 (0.92-1.04) | 21.4 (13.6-25.3) | 25.7 (20.0-26.8) | 21× |
| CJK | 0.82 (0.75-0.90) | 1.01 (0.92-1.09) | 0.76 (0.60-0.80) | 1.23× |
| mixed | 0.88 (0.66-0.94) | 2.01 (1.81-2.10) | 2.08 (1.70-2.24) | 2.3× |

An earlier session on the same build, without the twin, got ASCII 11.2
(8.5-13.6) against 1.92, CJK 1.03 against 0.83, and mixed 2.28 against
1.25. Between sessions the machine's speed swings by 2×; within one
session the ratios hold. **The step's targets** (70 GB/s ASCII, about 9
CJK and 13.5 mixed) are the NEON path's on the M4 Max, and can't be
timed here: qemu only checks correctness. They're the owner's to
confirm with `diff.exe bench` built natively there (bench/native/
RESULTS.md, "Bytes stage, part two, step 1").

### Step 3, as built

**The owner's header** is as specified: `ren_str` stays 32 bytes, its
fourth word a union, an owner's `cap` (room for bytes, at least `len`)
or a slice's `root`, and bit 0 of `h.nfields`, `REN_STR_SLICE`, set on
a slice. Every test of `root != NULL` in ren_rt.c and ren_rt.h moved to
`ren_str_is_slice`: freeing (an owner's memory is `32 + cap`), the
shared-mark walk, `ren_str_part` (a slice of a slice has the first's
root), `ren_str_join`, `ren_str_copied` and `ren_bytes_writable`. An
owner's room is rounded up to the word its memory ends in, which the
allocator gives anyway, and its bytes have no 0 after them: the two
writes past `len`, in `ascii_lower` and `from_utf8_lossy`, are gone.
emit_c.ml's literals keep their layout, their fourth word `cap`, their
length, and their count 0. Map keys, hashing, `==` and the walks read
`data` and `len` only and didn't change.

**`ren_str_concat_taking(a, b, site)`** takes `a`. Its fast path is
inline in ren_rt.h: a unique owner with the room gets `b`'s bytes after
its own. `ren_str_concat_slow` grows a unique owner that hasn't the room
to twice its room or more (32 bytes at least): `realloc` when its
memory is malloc's, and when it's a small object from a free list a new
object and a copy, since realloc can't take free-list memory; either is
a `grows` in the statistics, not an allocation. `b` may be `a` itself,
or a part of its bytes nothing counted: where it starts is read before
growing and its bytes taken from the grown owner. Anything else (a
count above 1, a literal, an A slice) is copied, its range then `b`,
into an owner with room for twice that range, and `a` dropped. Plain
`ren_str_concat` copies into an owner of the exact size, as before.
`Bytes`' `+` is the same function.

**rc.ml.** `prepare` makes every `Str_concat` the `_taking` one, as it
makes `push`'s (mem.ml's `takes`: argument 0). While placing the counts,
a `_taking` `+` whose left side isn't moved there (it's used after, a
borrowed parameter's, or `b` is the same group) goes back to plain
`Str_concat`, so nothing counts the left side again only for the
runtime to find it shared; a literal's stays `_taking`, so `var out =
"["` copies once with room. `+=` on an `inout` parameter is a cell's
view, which `find_takes` sees taken straight from its slot, so
put_json's `o += …` appends in place. A parameter used as a `+`'s left
side is owned (borrow.ml sees the `_taking` form), as `push`'s array is.
hoist.ml's reason for reading a string's data and length once a loop
now says why an append can't move them: the variable alive across the
loop holds a reference, so the `+` copies. Mem Lint checks
`Str_concat_taking` as any taking call.

**The report.** to_mem.ml gives a `+` a site of kind `Appends` when
it's the leftmost `+` of an assignment's value and its left side is the
variable assigned, `o = o + a + b`'s `o + a`; a `+=` is that same shape
in Core, and is told from `o = o + x` by its `+` having the
assignment's place (lower.ml's `assign`). The prelude's have none.
A debug build defines a `ren_append` for each such site (its site, its
count, its number), in a unit of its own when it's in units, and passes
its address; a release build passes NULL. A copy of what something else
holds (a count above 1) is counted, and the site put on a list the first
time. `ren_run`, once `main` has returned, prints a note for each site
with more than one copy, by site number, unless `REN_NOTES` is `0`;
the note is a diagnostic's pieces with `note:` for `error:` (driver.ml),
printed by `ren_site_print`, which a panic now prints through too. A
panic, which exits, prints none. bench/build.t and bench/bytes.t set
`REN_NOTES=0` beside strs.t; no OCaml test runs a native binary.

**The tests.** append_count is fewer than 200 objects in debug and
release, append_report's block prints the note (99 copies: the first
pass copies the literal, which isn't counted), and every strs.t program
is the same natively in every build with no object alive. build.t's
fannkuch (10 objects to 8) and nbody (5,017 to 5,013 debug, 12 to 8
release) count fewer, from `+` chains in the prelude's `show`s.

**Measured** (x86_64 cloud container, 4 cores, shared, wall time;
bench/native/RESULTS.md, "Bytes stage, part two, step 3", has the
spreads and the commands). At 1M records `+=` takes 285.4 ms a round on
json against Rust `push_str`'s 201.8 (1.41×) and 194.4 on logfmt
against 182.6 (1.06×). 50,000 records take 13.0× and 10.1× what 5,000
do (the baseline's 340 to 403×). `o = o + a + b` appends in place as
`+=` does, since `o` dies at its `+` (this section's own rule), so
`_plus` is linear too (421.2 and 203.8 ms at 1M); a `+` whose left
side something else holds stays quadratic: `json_held`, `_plus` keeping
the output before each record, takes 54.1 ms at 5,000 and 19,559 at
50,000 (362×), and a debug build reports it. The other strs kernels and
the slices and maps kernels are within noise of step 2's.

**What misses.** json's `+=` is 1.41× Rust, not 1.1×. It isn't the
appending: callgrind puts 23% of a round in the 32-byte slice objects
`put_json` makes for `s[run..i]` under A, and 12% in `show(x.id)` and
`show(x.score)` making strings that Rust's `write!` writes into the
buffer. logfmt, which appends whole fields, is at 1.06×. Step 4's B
makes the slices values; `show` into a buffer isn't in this stage. `ren_show_int`
wrote its digits with `snprintf` before this step, a fifth of json's
instructions; it writes them itself now (json was 1.85×, logfmt 1.23×).

### Step 4 (part 1), as built: representation B

The first part of step 4 is B's layout itself in release builds; the
uncounted view, the 4 GiB escape and unboxed map entries are later
parts', which this one leaves room for (below, "For the next part").
Debug builds keep A throughout, so nothing here changes them.

**The layout.** to_mem.ml's `layout` gives `Str` and `Bytes`, in a
release build, one struct, `Struct (n, true)` with `sfields = [Boxed;
Int]` and `skind = Product` (`sv_strukt`), registered under `Str`, so a
`Str`'s bytes are `Bytes` with no conversion and `Str.from_utf8` gives
its argument back. The program says which struct it is (Mem's `sv`),
emit_c.ml writes it as `typedef ren_sv ren_struct_n`, and fold.ml never
merges another struct of the same slots into it, nor it into another,
since its C type is the runtime's. Everything the data stage built for a
small record holds: a `Tok { kind: Int, text: Str }` is three slots,
flattened; an `Array<Str>` is two words an element, mask `0b01`; an
`Option<Str>` is two slots, its niche in the root's; Perceus dups and
drops slot 0 and Mem Lint checks it as any counted struct. A literal is
`Make_struct [Lit n; Int (len << 32)]`, which rc.ml and Mem Lint take
for a constant (`Static`): no count, no drop, as `Lit` itself.

**An object's field** (`field_slot`) takes the two words, its place
`Flat [k; k + 1]`, when its *declared* type is `Str` or `Bytes` (no type
variable in it), so a generic type's layout doesn't change with its
arguments; one declared a type variable's, and a tuple's part and an
error's payload (whose types are their arguments, or are walked through
descriptors kept after them), hold the box. `shape` and `pack` give the
places; reads, updates, patterns and building go through the data
stage's `Flat` code, which needed only the object's word count passed to
`flat_var`. The walks find a field by its constructor's `at` table,
which now says 128 bits for a two-word field (`ren_ctor_field`).
logs' `Rec`, six strings and two `Int`s, is one 14-word object, where it
was an object and six slice objects.

**Where it's boxed,** by runtime calls, never by `To_word` and
`Of_word`, which Perceus takes for the same reference: `Str_box`
(`ren_sv_box`: the root itself, counted again, if the value is all of
it, else a new 32-byte A slice) and `Str_unbox` (`ren_sv_unbox`), each
borrowing and counting again, the original dropped after
(`box_taken`, `unboxed`). They're at: a value given or returned as a
word (`convert`, `take_word`, `from_word`), a block's arguments, its
value and its parameters (`call_block`, `lambda`), a handler's arms'
parameters and values, what a handler captures (`captured`), a `with`'s
value, a field declared a type variable's or a tuple's part or an
error's payload (`packed_words` boxes, `Field`, patterns' `boxes`
unbox), a map's value (`kept_word`), and the C of a type's own `key`
(`key_wrapper`). A walk that only reads (`show`, `==`, ordering, `x.hash()`,
a map's `get`, `remove`'s key, the NaN walk) is given the two words, as
an A slice made on the stack for the call (`REN_SV_VIEW`, count 0, so
counting it does nothing), and a map's key is boxed only if the map
keeps it (`ren_map_set_sv`); Mem Lint allows two words there and
nowhere else that takes a word (mem_lint.ml, `views`).

**The runtime** (ren_rt.h, "representation B"). Its strings' functions
take two words (`ren_sv`) where they're hot: length, data (the root's
address plus 32 plus the offset, no load), `==`, a slice (inline, its
checks then arithmetic and one count), `split_at`'s halves and their
join, `+` and `+=` (`ren_sv_concat_taking`, in place when the root's
count is 1, after setting the root's `len` to the range's end, as
"Uniqueness under B" says; growing realloc's an owner the value starts,
and copies only the range of one it doesn't), `copy()`, `split`,
`trim`, `join`, `b.at(i)`, layer 3's reads and writes (in place through
a slice of a unique root) and `show` of a scalar. The rest (`lower`,
`code`, `char_floor`, `from_utf8`'s test, lossy, `Bytes.of`, a splice,
the console) is today's A functions given a view and, for a string
back, `ren_sv_take`. `ren_desc_sv` says a descriptor is a string's,
under `REN_SV`, which a release build defines: an array made from one
(`ren_alloc_array_d`, `Map.keys`, `sort`) is two words an element, and
the `_w` functions generic code calls box and unbox an element. The
walks read a two-word element or field as a view (`ren_array_peek`,
`ren_ctor_field`); `ren_array_sort` sorts two-word strings by their
bytes directly, with no walk, unless the type has its own `key`. A
value past 4 GiB panics where it's made (`ren_sv_too_big`), where the
escape will go.

**hoist.ml** reads a string's length and data before a loop for two
words as for an object; they're the range and the root, which nothing
changes while the value is held. **rc.ml** gains `lend_parts`, after
Perceus: a struct made of a field's part, only read, then dropped,
`Dup p; let k = Make_struct [p; range]; reads; Drop k` with nothing in
between that drops, frees, calls, branches or gives `k` away, loses the
count and the drop, which are a pair that does nothing, since what `p`
is a part of holds it throughout (rule B); `k` is then a part of the
same object, which Mem Lint checks as one (a struct whose one counted
slot is a part with no count). It's lent only if `p` is a field read
that one `Dup` counts and nothing keeps, so Lint sees it with a count of
0, and so can tell. A release build's `r.key.at(1)` no longer counts
the input's root twice.

**The tests.** strs.t's `objects` of slices_count.ren is fewer than 200
in a release build now (10,000 slices kept in an array of small
records, which a debug build keeps as objects), as step 0 marked for
step 4; every strs.t, bytes.t and build.t program is the same in every
build under the sanitizers with no object alive at the end, and
slices_kept.ren keeps its slices in each place B lays out, its root
dropped first. Changed only where B's layout shows: test_native.ml's
printed Mem of release builds, bytes.t's count of what a release
build's panic leaves alive (2 to 1), and build.t's C variable numbers.

**Measured** (x86_64 cloud container, 4 cores, shared, GCC 13.3 -O2,
wall time, ms a round, 7 runs interleaved; before is bb005eb, step 3's
code; bench/native/RESULTS.md, "Bytes stage, part two, step 4, part 1",
has the spreads, the twins and the commands). Fix by fix: (1) B itself,
the layout and the runtime's two-word functions: tok 0.69 of before,
sort 0.38, map 0.92, group 1.06, logs 0.69, slices json 0.76 (3 runs);
(2) literals uncounted and a map's key boxed only when kept: slices
json 0.87 of (1), group back to 1.01 of before; (3) `lend_parts`:
slices pages 0.71 of (2), json 0.91, the rest unchanged. All three
against before:

| kernel | before | after | after / before | after / Rust |
|---|---|---|---|---|
| tok | 57.4 | 37.5 | 0.65 | 1.51 |
| sort | 1427.7 | 503.1 | 0.35 | 2.17 |
| map | 2454.8 | 2081.0 | 0.85 | 1.88 (std's: 1.37) |
| group | 533.4 | 535.4 | 1.00 (11 runs: 0.85) | 1.06 (std's: 0.95) |
| logs | 423.8 | 263.2 | 0.62 | 1.19 |
| out json `+=`, 1M | 334.9 | 271.4 | 0.81 | 1.22 |
| slices logs / `_r` | 30.5 / 19.9 | 19.3 / 20.5 | 0.63 / 1.03 | 1.48 / 0.93 |
| slices json / `_r` | 153.4 / 82.4 | 105.1 / 85.7 | 0.69 / 1.04 | 1.46 / 1.96 |
| slices pages / `_r` | 15.5 / 5.2 | 6.5 / 5.5 | 0.42 / 1.04 | 2.82 / 1.78 |

"after / Rust" is measure.py's run of the after build beside the twins.
The rest of bench/native is within noise of before, but interp, 1.35
over 11 runs, whose `eval` is the same machine code at another address
(878.8M instructions in callgrind either way): a placement effect.
`-DREN_RC_SHARED` costs json 1.14×, which counts its root most, and
nothing measurable elsewhere.

The clang fault (VERIFY.md, problem 1): clang 18 -O2 keeps 11 to 14
induction variables in logs' `field_end` scan inlined into `records`,
with spills, before B and after, so it isn't B's: hoist.ml already
reads the range unpacked into two locals before the loop. Built with
clang, logs is 0.73 of before (298.4 against 408.4); an empty `asm` on
the index in `ren_buf_byte` gave 1.00 of that (289.2 against 288.7), so
there's no barrier.

**Against the step's targets** (the whole of step 4's; later parts add
to these): tok 0.65 and sort 0.35 (0.80 or less), map 0.85 (0.95 or
less), group 1.00 (no slower) and logs 0.62 (0.90 or less) hold. The
slices kernels against their `_r` forms: logs 0.94 holds (1.1); json
1.23 and pages 1.18 in this run (1.21 and 1.63 in measure.py's) miss
1.2, by what's left of counting the input's root: each token or record
pushed counts it, each element read counts it again and drops it (the
data stage's choice for an array of counted structs, which a read
borrowed while the array is held would remove), and freeing the array
drops it once an element, a chain of increments and decrements of one
word that offsets don't have. Every slices and `_r` kernel is within 2×
of Rust but pages, 2.82×, for the same reason. The uncounted view
doesn't touch these (each slice is stored); borrowed element reads
would. The escape's cost is the later part's to measure.

**For the next part.** Boxing is `box_taken`, `unboxed`, `kept_word`,
`captured` and `ren_map_set_sv` in to_mem.ml and the runtime; a map's
entries are still words, a string's box, so unboxed entries replace
`kept_word` and `ren_map_set_sv` and teach `REN_MAP_EACH`'s readers
two words. The runtime's functions take `ren_sv` by value, or an A view
(`REN_SV_VIEW`), and give `ren_sv`; `ren_sv_make` is where the escape
goes, and `ren_sv_len`, `ren_sv_data` and `ren_sv_view` are the three
reads that test it. The uncounted view is a slice whose root isn't
counted: `ren_sv_slice` dups the root, which a part wouldn't. Traps
found: Perceus takes `To_word` and `Of_word` for the same reference, so
a box made there would be counted wrong (hence runtime calls); a
struct aliased to its one counted slot confuses a struct's slot `k`
with its root object's field `k`, which freed a string as an object
(tried and dropped); fold.ml merged structs by their slots alone, which
would have made a user's `{ Boxed, Int }` record the runtime's `ren_sv`;
GCC warns of the in-place append's `memcpy` where it's inlined on a
literal's root, which the count test never lets run (silenced in
ren_rt.h); and a release build's `--rc naive` is quadratic on
bench/data/rows.ren before and after (25 s against 33 s here), which
nothing tests.

### Step 4 (part 2), as built: the uncounted view

Part one left slices' json and pages short of their `_r` forms by what
counting the input's root costs (above). This part removes the counting
of reads that keep nothing: a slice of a string a function holds, the
uncounted view, and an element read of an array it holds and doesn't
change, each made a part of what it's read from, as a field read is.
Both are rc.ml's (`lent_reads`), decided after borrow inference, and Mem
Lint checks each as a part. Release builds have both; a debug build has
the element reads, since its slices are A objects.

**The uncounted view.** A slice, `s[i..j]`, of a release build's `Str`
or `Bytes` whose variable never changes is `Str_view` (mem.ml), the
runtime's `ren_sv_view_slice`: the same checks as `ren_sv_slice`, and
no count. Perceus makes its variable a part of the sliced value's group
(`Part (g, -1)`, at no slot, so no specialized drop keeps it), and so
counts it again exactly where it would count a field it read: where it's
stored (in a record, an array, a map, a set, a handler's description),
returned, given to a callee that owns its parameter, captured (a local a
block captures is a slot, which owns a reference), or where what it's a
part of dies before it. What's sliced needn't be a borrowed parameter:
any string held by a variable that never changes is held for as long as
its parts are, or its parts are counted first, so the view is the same
for a local, a field read and an element read.

Why it's sound, in the spec's terms. Rule B (Perceus's parts): a part
is borrowed from its parent while the parent is held, and counted again
before the parent is consumed or dropped (rc.ml's `promote`); a view's
root slot is its parent's root slot, so while the parent is held the
root is alive, and once the view is counted it holds the root itself.
Nothing changes a value's root or the bytes in its range while the value
is held: the value is immutable, and every write or append in place
takes the value it writes (`takes`: `Str_concat_taking`'s left side;
layer 3's writes through a cell, `changes_cell`, whose old value a view
of the cell's value keeps by a snapshot), and taking it counts its live
parts first. Rule U: a root whose count is 1 is seen by one value; a view
doesn't count it, but it's counted before the value it's a part of is
taken, so a write in place through a root of count 1 never runs while
an uncounted view of it is live. An append to the view itself takes the
view only where it owns a reference (its parent dead, so it was counted
when the parent died); anywhere else rc.ml makes it the `+` that copies,
as it does for any left side still held.

**Lent element reads.** `xs[i]` of an array whose elements are objects
or counted structs (a release build's `Str`, two words, or a record of
them) is `Array_peek`, and `Buf_peek` once hoist.ml has the loop index
the buffer: the element's words, no count, a part of the array's group.
That's the data stage's code, not strings': it holds for any small
struct that holds an object, and for an array of objects, in both
builds. It's lent only where the element can't change or go while the
part is held: the element's variable never changes; the array's
variable never changes and isn't a view of one that does, nor a part of
such a view (a field of a `var`'s record), so it's held by the function
or its caller as one value; and nothing in the function takes the array
or moves an element out of it (`Array_take`). The last is what makes it
sound beside swap.ml, which moves an element out uncounted where it's
written back: an array that's written is taken by its write, so its
reads stay counted. With those, the argument for a field holds of an
element: the array holds the element while the array is held, and the
array is held across the part's uses, or the part is counted before
it's dropped (`promote`'s count again, never a specialized drop's kept
slot).

**`lend_parts`, again.** Part one's pass removed the count and drop
around a struct made of a field's part, only read. Two cases it missed:
an outer pair whose interval held an inner pair (`r.key.at(r.key.len()
- 1)`), now lent on a second pass, and a call between that takes
nothing counted (`parse_int(v.text)`), now quiet when the part is read
from what only the function's own variables that never change hold
(`settled`: a parameter, a value it made, or a part of one, never what
a cell holds), since a callee can reach what the function holds only
through a cell or what it's given.

**Freeing an array of slices** (ren_rt.c, `ren_release_elems`). With
the reads lent, what's left of counting the input's root in json and
pages is one count where each token or record is pushed, and one drop
of it where the array is freed. The free drops a run of elements that
hold one object at once (`ren_release_n`: one subtraction while the
count stays above what's dropped, else one `ren_release` each, as
before), and its loop is written out for elements of one object and of
two, where the loop over the mask cost pages 34 instructions a record.
Shared and atomic counting (`REN_RC_SHARED`, `REN_RC_ATOMIC`) drop one
at a time, as before. It's out of line: inlined, it changed how GCC
compiled unrelated loops of the program in the same file.

**Mem Lint.** A view or a lent element is a part of what it's read from
with no reference of its own (`lent_part`), as a field read is; a
`Buf_peek`'s array is the one its buffer's `Array_data` read. An element
moved out (`Array_take`, `Buf_take`) or written in place (`Buf_set`,
`Buf_set_field`) makes every part of that array with no reference of
its own dead (`unlend`), so a lent element read after its array changes
is an error, which rc.ml's conditions never make.

**The tests.** bench/strs_lent.t's strs/lent.ren: views only read,
returned, stored, given to a callee that keeps them, captured, and of a
string that dies before the view is read; element reads only read,
kept, outliving their array, nested (an array of arrays), and an array
changed while an element read from it is held, and swapped out; records
of `Bytes` slices read. The same in every build under the sanitizers
with no object alive at the end, and as `ren run` prints. test_native's
printed Mem of a release build's element read changes (`array-peek`, a
`dup` of the slot kept where the `free` kept it).

**Measured** (x86_64 cloud container, 4 cores, shared, GCC 13.3 -O2,
wall time, ms a round, interleaved; before is 3b649c6, part one;
bench/native/RESULTS.md, "Bytes stage, part two, step 4, part 2", has
the spreads, the twins and the commands; callgrind's instructions a
round beside the times, since this machine's wall times move 5 to 10%
between runs). Fix by fix, the slices parsers at 60 (json), 200 (pages)
and 100 (logs) rounds, 9 runs, and instructions at 2 rounds:

| | part one | (1) the view | (2) lent elements | (3) `lend_parts` | (4) runs dropped | (5) loops written out |
|---|---|---|---|---|---|---|
| json, ms | 111.1 | 107.1 | 104.4 | 102.9 | 101.0 | 98.9 (11 runs; part one 104.9) |
| json, M instructions | 425.8 | 425.5 | 366.3 | 367.9 | 345.5 | 313.5 |
| pages, ms | 5.88 | 6.11 | 5.72 | 5.09 | 4.98 | 4.93 (11 runs; part one 5.95) |
| pages, M instructions | 51.2 | 50.0 | 40.6 | 39.0 | 36.0 | 31.9 |
| logs, ms | 21.8 | 20.6 | 20.1 | 21.2 | 20.9 | |

logs' instructions go from 196.4 to 205.8 million at (1) and stay
there, on C with only fewer counts in it: GCC compiles `logs`' byte loop
to more instructions a byte (its bounds test twice as often), as it does
`group`'s, in both cases moved by code elsewhere in the file. The
`_r` forms are the same C throughout.

All five against part one (7 runs at part one's rounds; the slices
parsers again at many rounds, 11 runs, beside their Rust twins):

| kernel | part one | after | after / part one | M instructions a round | after / Rust |
|---|---|---|---|---|---|
| tok | 38.63 | 36.35 | 0.94 | 205.5 / 171.4, 0.83 | |
| sort | 433.7 | 446.5 | 1.03 | 1652.9 / 1618.4, 0.98 | |
| map | 1921.2 | 1793.4 | 0.93 | 4049.7 / 3968.9, 0.98 | |
| group | 446.4 | 430.3 | 0.96 | 4017.4 / 4002.4, 1.00 | |
| logs | 273.4 | 237.1 | 0.87 | 1967.0 / 1898.0, 0.96 | |
| out json `+=`, 1M | 253.6 | 260.2 | 1.03 | 2398.0 / 2226.1, 0.93 | |
| out logfmt `+=`, 1M | 170.7 | 182.4 | 1.07 | 1204.7 / 1161.9, 0.96 | |
| slices logs | 19.38 | 19.12 | 0.99 | 206.4 / 205.2, 0.99 | 1.41 |
| slices logs_r | 19.82 | 17.92 | 0.90 | 227.7 / 218.2, 0.96 | 0.91 |
| slices json | 100.15 | 91.62 | 0.91 | 423.1 / 310.9, 0.73 | 1.39 |
| slices json_r | 83.57 | 82.72 | 0.99 | 328.8 / 328.7, 1.00 | 2.08 |
| slices pages | 5.25 | 4.48 | 0.85 | 50.8 / 31.2, 0.61 | 1.97 |
| slices pages_r | 3.67 | 3.63 | 0.99 | 23.1 / 23.1, 1.00 | 1.82 |
| maps | 146.1 | 134.8 | 0.92 | 310.2 / 296.2, 0.96 | |

**Against the targets.** Slices json at 1.11 of its `_r` form (1.2)
and logs at 1.07 (1.1) hold, logs at 1.07 to 1.11 over three runs of 9
to 15. Pages misses: 1.23 of `_r` here, 1.19 to 1.28 over four runs
(part one: 1.43 to 1.51 at these rounds), and 1.97 to 2.15 of Rust
(2.0). What's left is the free walk (below, "For the next part"), and
`json_r` at 1.99 to 2.08 of Rust is the offsets form's own, the same C
as part one's (1.96 there), with no strings counted. Part one's targets
(tok 0.65, sort 0.35, map 0.85, group 1.00, logs 0.62 of step 3) still
hold: no kernel has more instructions than at part one, and none is
slower beyond this machine's noise. The rest of bench/native compiles
to the same C but for ren_rt.c, and runs within noise of part one
(0.85 to 1.06, 5 runs; fannkuch's, vec's, blocks', nested's and nbody's
instructions are the same within 0.01%).

**For the next part** (the 4 GiB escape and unboxed map entries).
`ren_sv_view_slice` can't allocate: a view holds no reference, so
nothing would drop an object it made. Where the escape lands, a view
whose result is the escape (a slice past 4 GiB of its buffer, or 4 GiB
long) needs an A slice object, which must be counted: either
`ren_sv_view_slice` makes the escape's result from the parent's own A
object where it can (the whole of it), or rc.ml stops lending slices of
values that may be the escape, which it can't know statically, so the
first is the way; Mem Lint's rule (a view is a part, with no reference)
doesn't change. A map's `get` and its entries' readers (`REN_MAP_EACH`)
give owned values; lending them as `Array_peek` does, a part of the map
where nothing takes the map, is the same rule, with the same exclusion
for a map that's written. What's left of pages' gap is the free walk:
freeing an array of slices reads every element to drop its root (6.4 MB
in pages, 0.3 to 0.6 ms of its 1.1 ms over `_r`, measured by skipping
it); an array header that knew every element holds one root could drop
it once, but every element write would have to keep that true.

### Step 5, as built

**What's built in, and what's Ren.** New intrinsics, each a member:
`Str.ends_with`, `ascii_upper` and `line_col`, and on `Bytes` `index`,
`starts_with`, `ends_with`, `split`, `trim` and `ascii_upper`. Each
`Bytes` one is its `Str` twin in both builds: builtins.ml runs the same
OCaml on a `VBytes`, and to_mem.ml calls the same runtime function,
since the two types are laid out alike. The rest is the prelude's Ren,
on both types: `includes` over `index`; `strip_prefix` and
`strip_suffix` over `starts_with` and `ends_with` and a slice;
`split_once` over `index` and two slices; `lines` over `split` of `\n`,
dropping a byte 13 at the end of every part but the last, and the last
part if it's empty; `fields` a loop over the bytes keeping the runs
between `ascii_space`'s five bytes, a slice each; `replace` a check for
the empty string, then `split(from).join(to)` on `Str`, and on `Bytes`
(which has no `join`) the parts appended with `+=`. Every slice these
make is at an ASCII byte or at the ends of a match of valid UTF-8, so a
`Str`'s never cuts a character, and its check never panics. `Str.index`
and `starts_with` were interpreter-only until now; they're native here,
as the rest needs them.

**Natively,** four runtime functions of A strings, each only reading
what it's given, so a release build passes its two words as an A view
on the stack (`REN_SV_VIEW`, the `str_args` list of emit_c.ml), and none
touches B's code: `ren_str_find` (`memchr` for the first byte, then
`memcmp`; -1 if it isn't there), `ren_str_has` (a prefix or a suffix),
`ren_str_upper` (a new owner, as `ren_str_lower`), and `ren_line_col`.
Mem has them as `Str_find`, `Str_has`, `Str_upper` and `Line_col`. An
`index`'s `Option` is made as `Map.get`'s value is: the offset in a
variable, `Some` of it or `None` built through Core's constructor in two
arms. `line_col` is two calls, the line and then the column, at one site
that names the receiver for the help, the first checking `at`; the
tuple is built through Core's, as `Some` is. Each panics with the
interpreter's message and help (builtins.ml, `line_col`).

**`count()`.** On an `Array`, a `Map` or a `Set`, Infer takes
`xs.count()` with no argument as `xs.len()` (infer_expr.ml, a case
before `method_call`): a method can't have two arities, and the prelude's
`count(f)` keeps its signature. On a cursor, a type with a `next` and
no `count` of its own, `c.count()` and `c.count(f)` are the built-ins
`pulled_count(items)` and `pulled_count_by(items, f)`
(`Intrinsic.Pulled_count`), which no program names, as `x.hash()` is
`hash_of(x)`: `items` is a pull parameter, `fn() -> Option<T>`, and the
receiver is given to it as `for` would take it (`pull_arg ~known`, the
receiver's type inferred already), so a named cursor's copy is counted
and the cursor stays where it was, and `f`'s errors and uses are the
call's, as any block argument's are. Lowering pulls the receiver
(`plain_call`) and writes the call out as a loop
(lower.ml, `pulled_count`): the pull block called until `None`, `f`
held and called on each item, so neither build has an intrinsic to run.
A type with a `count` of its own keeps it.

**Choices where the spec is silent.** `split_once("")` is
`Some(("", s))` and `includes("")` true, as `index("")` is `Some(0)`
(Rust's). `lines` drops a `\r` only before a `\n`, so a last line's own
`\r` stays (Rust's since 1.77). `Bytes.replace` of no bytes panics with
"`replace` needs bytes to replace that aren't empty". `ren run`'s
`Bytes.replace` appends with `+=`, so it's quadratic in the number of
matches there, as the interpreter's `+=` is (the brief's "Decided").

**Tests.** rest.ren as specified and the same in every build; strs.t
adds rest_count.ren (a prelude cursor and a program's, a named one left
where it was, `zip`'s, a map's and a set's with and without `f`, a
predicate that fails, one that changes a `var`) and five panics:
`line_col` past the end and inside a character, `replace` of the empty
string on `Str` and `Bytes`, and `Bytes.split` of no bytes. test_strs.ml's
s5 is on, no `until "s5"` left. rest.ren and its `.expected` agreed with
the spec as written, and are unchanged.

### Progress log

| step | commit | what's done | what's left |
|---|---|---|---|
| 1 | "Bytes stage, part two, step 1: the boundary" | the NEON block validator and its scalar path, the rescan; `InvalidUtf8(at, incomplete)` in every use; `from_utf8_lossy`; test/utf8/'s differential test, natively and under qemu-aarch64, 0 disagreements; invalid_utf8 and s1 on; scalar path 21×, 1.23× and 2.3× the old loop on ASCII, CJK and mixed (x86_64) | the NEON GB/s targets, the owner's to time on the M4 Max |
| 2 | "Bytes stage, part two, step 2: the API" | `'a'`, interpolation with `\{x=}`, `ascii_lower`, `byte_len`, `is_empty`, the `len`/`s[i]`/`lower`/`concat` errors, `+` and `+=` (copying), `char_floor`/`char_ceil` and the cut panic's help natively, `chars`, `code`, `of_code`, `join`, `cursor(from:)`; tree-sitter and Zed; every program moved; s2 on | in-place `+=` (step 3); excl.ml got one constructor in its list of nodes to walk, the only touch of the services stage's files beyond the shared ones |
| 3 | "Bytes stage, part two, step 3: appending in place" | the owner's `cap` and `REN_STR_SLICE`; `ren_str_concat_taking` (in place, doubling, copying with room) where the left side dies, `Bytes` too; the debug report with `REN_NOTES`; append_count and the report's block on; `+=` 1.06× Rust on logfmt, linear on both | json's `+=` at 1.41× of Rust, not 1.1×: A's slice objects and `show`'s strings, not the appending (step 4 makes the slices values) |
| 4, part 1 | "Bytes stage, part two, step 4 (part 1): representation B" | `Str` and `Bytes` two words in release builds (`ren_sv`), inline in locals, small records, arrays and declared fields; boxed (A) at words, blocks, handlers, tuples' and errors' fields and map values; walks given a stack view; `ren_map_set_sv`; literals uncounted; `lend_parts`; tok 0.65, sort 0.35, map 0.85, group 1.00, logs 0.62 of step 3; slices_count's objects on | the uncounted view, the 4 GiB escape (a value past it panics), unboxed map entries, the 16-byte owner experiment; slices json and pages at 1.2× and 1.2 to 1.6× of `_r` and pages 2.8× of Rust, from counting the root on each element read and free |
| 4, part 2 | "Bytes stage, part two, step 4 (part 2): the uncounted view" | the uncounted view (`Str_view`, `ren_sv_view_slice`), a slice a part of what it's of; lent element reads (`Array_peek`, `Buf_peek`) of arrays nothing takes, in both builds; `lend_parts` to a fixpoint and through calls that take nothing counted; Mem Lint's lent parts and `unlend`; a run of one root dropped at once when an array is freed; strs_lent.t; slices json 1.11 and logs 1.07 of their `_r` forms, json 0.73 and pages 0.61 of part one's instructions | pages at 1.23 of `_r` and 1.97 to 2.15 of Rust, from the free walk; json_r at 2.0 to 2.1 of Rust, its own; the 4 GiB escape (a view of one), unboxed map entries, the 16-byte owner experiment |
| 5 | "Bytes stage, part two, step 5: the rest of the API" | `includes`, `ends_with`, `strip_prefix`, `strip_suffix`, `split_once`, `lines`, `fields`, `replace`, `ascii_upper`, `line_col` with its panics, on `Str` and `Bytes` alike (`Bytes` given `index`, `starts_with`, `split` and `trim`), in the interpreter and natively, `Str.index` and `starts_with` native too; `count()` on arrays, maps and sets, and `count()` and `count(f)` on every cursor, pulled; rest.ren, rest_count.ren and five panics the same in every build; s5 on; stdlib.md's table | `ren run`'s `Bytes.replace` quadratic in its matches, as its `+=` is |

## Services stage

Services and concurrency (foundations.md, Staging, item 6; decisions 2,
7, 10, 11, 18 and 20; language.md §4, §5, §8 and §11; streams.md,
"Concurrency and time"): a composition root named as a wiring,
workflows as pipes with a `try` on each step that can fail, background
work that can't outlive its handler, `release` on one call, pull
arguments, channels as dependencies and `Async.produce`; then the
runtime's keyed instance family, a call as a typed value, `D.Call`, and
the two standard-library services written in plain Ren over them that
keep many stateful things, `striped`, which replaces `sync.keyed`, and
`actors`, with `post`. Interpreter first, as tasks are: what's
sequential (wirings, the pipe, `release` with no other task) builds
natively and agrees with `ren run`; what starts tasks or keeps
instances is refused by `ren build`, as 11a refuses `Async.scope` and
`keyed`. Ten steps, each green on its own, as 11a's and the data
stage's were (briefs/stage-services.md):

0. **This specification,** its tests (The tests, below), and the
   inventory of what the stage changes; re-specified after decision 20
   (the progress log).
1. **The pipe,** `x |> f(a)`, through the whole pipeline, natively too,
   with `|>` and `.` continuing a line in the lexer and tree-sitter's
   scanner; the README's and language.md's end-to-end shapes as
   examples that run.
2. **Wirings,** through the whole pipeline, natively too, every error of
   language.md §5 and `ren explain-wiring`; the examples that repeat a
   `with` list moved to wirings.
3. **Background work:** decision 7's compile error for a task that can
   reach a handler installed inside its scope, the run time's check where
   a helper hides which scope is inner, `Async.beside` and
   `Async.background`; 11a's cancel-beside-the-`with` rule removed.
4. **`release`, deadlocks and `Proc.run(kill:)`:** `release` on one
   call; decision 2's handler-state row narrowed in excl.ml; `sim`
   naming the instances a parked task holds; `sim`'s fair choice among
   an instance's waiters and arrivals; `kill: Tree | Child`, and a
   default that's a variant written bare, with no fields or with
   defaults for all of them.
5. **Pull arguments, channels and producers:** `Async.each` and
   `Async.map` over what `for` takes, `Chan<T>`'s `items()`, an
   ordinary function in `sync`, `Async.produce` with `Send<T>`, and
   `Async.map_pull`.
6. **The family, `D.Call` and `striped`:** the keyed instance family in
   lib/eval/family.ml, reached through the prelude's `Instances`, whose
   intrinsics Core Lint checks; `D.Call` for every dependency and the
   `call(c: D.Call)` clause; `Async.worker()`; then `striped`, plain
   Ren over the family, with `by: Key(n: 16) | Worker` and `merge:`;
   `sync.keyed` removed.
7. **`actors`,** plain Ren over the family, then **`post`**, which takes
   a `D.Call`, `Docs.post(k, Doc.Call.Edit { op })`; `chaos: true`;
   journal version 3, a family's names by the one rule.
8. **The milestone:** examples/docs, language.md §11's document server
   behind a wiring, its lost update found by seeds and its in-memory
   variant found under `actors(doc, chaos: true)`.
9. **A review** of the whole stage: soundness, the spec, the docs and
   tooling.

Each step takes its feature through the whole pipeline: lexer and
parser, Resolve, inference, Core and Core Lint, the interpreter, Mem IR
and the C it emits where the feature is sequential, the tree-sitter
grammar and its corpus (with differential.py agreeing with the
compiler's parser), the Zed queries, the error messages with their
help, and the documents that describe it (language.md's "What Ren has
today" table, async.md, stdlib.md, testing.md, handlers.md, deps.md,
the README). What follows settles what each step builds; a step that
finds something here unsound or unworkable says so instead of building
something else, and records what it chose in "Where this stage may
differ", below. The design itself is signed off (foundations.md,
language.md, streams.md, async.md): what's decided there is cited here,
not argued again.

### The decisions, and where each is settled

The brief's "What's decided" and "Decided after the draft", each cited
where it's built; none is argued again here.

| decision | settled in |
|---|---|
| What's decided 1, wirings (language.md §5) | The grammar; Wirings (step 2); Errors |
| What's decided 2, the pipe (language.md §8), every link `[try \| attempt] term`, `\|>` ending `try`'s and `attempt`'s reach, the `\|>` and `.` continuation lines | The grammar; The pipe (step 1); Errors |
| What's decided 3, 11a's follow-ups: decision 7's compile error and `beside`/`background`; `release` and `sim` switching at it; decision 10's deadlock rules; `Proc.run(kill:)` | Background work (step 3); `release`, deadlocks and `Proc.run(kill:)` (step 4) |
| What's decided 4, from streams.md: pull arguments, channels as dependencies with `items()` an ordinary function of `Chan<T>` in `sync`, nothing derived; `Async.produce` | Pull arguments, channels and producers (step 5) |
| What's decided 5, the keyed instance family, a runtime primitive: make, pin, evict, list the live keys, a queue of `D.Call`s per key; decision 18's soundness rules its own; journal names by one rule; its own module beside sched.ml; reached through a prelude dependency, `Instances`, whose intrinsics Core Lint checks | The keyed instance family (step 6); Journal version 3 (step 7) |
| What's decided 6, `D.Call`: one case per operation, typed by its result and errors; the `call(c: D.Call)` clause; built only as far as `post`, the queue, the journal and `striped`'s merge need (formats.md, "Dependencies as data", the whole design) | `D.Call` (step 6) |
| What's decided 7, `striped`, plain Ren over the family: `by: Key(n: 16) \| Worker`, `Async.worker()`, keyless broadcast, `merge:` with `Custom(m)` a stateless handler whose `call` clause folds, no `Merge<D>`; a missing `merge:` a panic at the `with`, no Infer rule; `sync.keyed` goes | Stripes (step 6); Errors |
| What's decided 8, `actors`, plain Ren over the family, the user's API as language.md writes it; `post` spelled `Docs.post(k, Doc.Call.Edit { op })`, decided 2026-10-29 with no trailing-call rule; `chaos: true` evicting what `Random` picks | Actors (step 7); `D.Call` (step 6) |
| What's decided 9, interpreter first: the family, `striped` and `actors` refused natively | Native |
| What's decided 10, decision 2's row narrowed, built in excl.ml with `release` | `release`, deadlocks and `Proc.run(kill:)` (step 4) |
| What's decided 11, defaults: a literal, a variant with no fields, or a variant whose fields all have defaults, written bare (`by: By = Key` is `Key(n: 16)`) | The grammar; "Where this stage may differ" (lands in step 4) |
| 2026-10-29: decision 20 moved `actors` and `striped` to std over a runtime primitive; What's decided 5 to 8 rewritten; superseded entries give way | this section, re-specified (the progress log's second step 0 line); superseded rows struck below |
| 2026-10-29: `service`, a dependency and its one implementation written once (language.md §4), step 2b; a signature's `uses` a bound; private functions don't write `uses` | Step 2b: service |
| Sequencing: after the data stage | the data stage is merged (83924d5) before step 0 |
| By-name arguments: defaults only, a variant allowed as one; std's defaults `max:` 10_000, `mailbox:` 10_000, `cap:` 16, `Key`'s `n` 16; no default `merge:` | The grammar; Stripes; Actors; Pull arguments (`cap`) |
| `striped(h, by: Key(n: 16) \| Worker, merge:)`, one function (~~`striped(h, n: Int = 16, by: Key)`~~, superseded) | Stripes (step 6) |
| Stale reads after `release`: found by `sim`'s seeds, no warning | `release` (step 4), and its test "a stale read across `release` is found by a seed" |
| `Docs.at`'s errors declared on the family, `Actors<K, D> ! E`; `Full` only where waiting could close a cycle | Actors (step 7), "The family's type"; The keyed instance family, "No deadlock" |
| `post` is Erlang's cast, as What's decided 8 says; 2026-10-29: spelled `Docs.post(k, Doc.Call.Edit { op })`, `Docs.post(k).edit(op)` not built | Actors (step 7), "`post`"; `D.Call` (step 6) |
| `Async.produce`'s `items` a block parameter, looped with `for p in try items`; `Async.map_pull` in `produce`'s shape | Pull arguments, channels and producers (step 5) |
| Pull arguments now: collections, temporary cursors, `&r`, a hand-written block, a channel's `items()` | Pull arguments, channels and producers (step 5) |
| A trailing block in a pipe only in the last link | The grammar ("A step"); Errors |
| The journal: the family adds made, evicted and posted lines, `docs[DocId(7)]#3` by the one rule for every runtime instance family; version 3; recorded journals recorded again | Journal version 3 (step 7) |
| `sim` chooses fairly among an instance's waiters and arrivals, from the tape, in step 4 | `release`, deadlocks and `Proc.run(kill:)` (step 4), "`sim`'s fair choice" |
| Partitions now, `parts: Int = 4` under every runtime, recorded in the journal | The keyed instance family (step 6); Actors (step 7); Journal version 3's header |
| `Lfu` later | Actors (step 7): `Evict = \| Lru` |
| Native: wirings, the pipe and `release` with no other task build; `beside`, `background`, `produce`, the family, `striped` and `actors` refused as `keyed` is | Native |
| Decision 7's run-time half: a panic at the spawn | Background work (step 3) |
| `Async.background`'s tasks may fail, the first failure cancelling the body | Background work (step 3) |
| The milestone: a line protocol over `sim.net`, an `Op` that appends, `--seeds 1000` with `actors(doc, chaos: true)` | The tests (bench/services/docs, bench/tasks.t); "Where this stage may differ" |
| `sim` has two virtual workers for `by: Worker` | The keyed instance family, "`Async.worker()`"; Stripes (step 6) |
| `Custom(m)`, m a stateless handler over `D` whose `call(c: D.Call)` clause folds (~~a handler of a derived `Merge<D>`~~, superseded) | Stripes (step 6), "`Custom(m)`" |

### The tests

**test/test_services.ml is the specification,** as test_tasks.ml was
11a's and test_data.ml the data stage's, with the same `until "sN"`
(test/helpers.ml): a test still to land holds its target, `~want` for a
program that runs or `~says` for the lines an error or a panic must
hold, its headline and its help, and its `[%expect]` holds today's
output after `(until sN)`. When the program prints its target the test
fails, saying the step has landed, and **the step turns it on**:
written plainly, `run src`, `test src` or `check_error src`, its
`[%expect]` the target, the whole message for a `says`. Each error
below is one such refusal test, but three, which are crams: the native
build's refusal (bench/build.t), `ren explain-wiring`'s listing
(bench/build.t) and a version 2 journal's (bench/tasks.t, once step 7
records journals as version 3). A step leaves no `until` of its own
number behind. A test whose program works already, and which a step
mustn't break, is written plainly now: a scope opened inside the `with`
waits for its tasks (s3), and a task taking an instance it already
holds panics rather than hangs (s4: 11a's step 4 built that half of
decision 10).

Programs run with `run` are `ren run`'s, on `single`'s fixed order, or
on a `sim.scheduler(seed)` they install; programs run with `test` are
`ren test`'s, on `sim`, under `~seeds`, and assert only what holds under
every schedule, or, for a test that's meant to fail under some seed (a
lost update, the split law, a fair choice), say `✗` in their `says`. A
program `test` runs has its items made `pub` by `pub_all` (a test sees
what an importer sees, testing.md).

| step | expect tests (test/test_services.ml) | bench/services |
|---|---|---|
| 1 | to each kind of target; a vertical chain with a `try` on each step; `try` and `attempt` on the head stopping at `\|>`; `orelse` after a chain; a `.` line continuing; a statement after a chain not swallowed; a trailing block in the last step; the end-to-end program's checkout; fourteen refusals (§8's nine, a step's missing `try` inside `attempt (...)`, the "takes second" line or not, `&` on a step, a trailing block on a step that isn't the last, a field of a value as a step) | `pipe` |
| 2 | flattened where used; an item beside a wiring meets its `Db`; wirings combine and nest, and a test splits one; a description as a parameter; `try with` of a wiring that fails to start; teardown in reverse install order; a plain `with` still exposes everything; a private wiring's `uses` inferred, a `pub` one's written (`types`); a `pub` wiring from another module; twelve refusals (§5's seven, its cycle both through wirings and among the items one flattens, a `pub` wiring's undeclared need, no `provides`, a body that isn't items, `provides` naming what a nested wiring hides) | `wiring`, and `wiring.explain` |
| 3 | the compile error, and the run time's panic at the spawn through a helper; `Async.beside` cancelling its task before the `finally`; a pool's order (work drains, the background stops, `finally`); a background failure cancelling the body and being its error; `Async.background`, and its first failure; a scope inside the `with`, plainly | `refused` (with step 6) |
| 4 | `release` with no other task; letting callers in; the arm's copies written back and read again; `try release`; a stale read found by seeds, and the fix holding; two refusals (outside an operation, not a dependency's operation); a loop over a reader in the state while calling another service, accepted; state borrowed across `release`, refused; re-taking an instance, plainly; `until`'s deadlock naming what each parked task holds; the fair choice, found by seeds; a variant default with no fields, one whose fields all have defaults, and one written with arguments refused; `Proc.run(kill:)` under `sim.proc()` | `release` |
| 5 | `Async.map` over a temporary cursor, in order; `Async.each` over `&r`, which goes on after; over a hand-written block; `&r` while the block touches `r`, refused; pulled only when a slot frees; `Events.items()` in a `for` and as a pull argument, and refused elsewhere; `Async.produce`; a `break` cancelling the producer; `cap` and a slow consumer under seeds; a producer's failure ending the stream; `Async.map_pull` | none |
| 6 | `by: Key(n: 4)` with `merge: Sum`; `by: Worker` under seeds; the split law failing under some seed; a keyless `()` broadcast; `Concat` and `Custom(m)`, m's `call` clause folding; three refusals (`by: Worker` with a count, an ADT's error; `Custom` of a handler with state, the data stage's method rule; not a description) and two panics at the `with` (no `merge:`, `Sum` of what isn't a number); `sync.keyed` gone | `refused` (with step 3) |
| 7 | `at` on demand; setup's errors and the retry; LRU eviction past `max:`, the `finally` on the caller's task, the counts; an evicted actor made again from the store; a pinned actor not evicted, the maker waiting; `evict`, `evict_idle` and `each`; teardown in reverse creation order; two operations racing and one not; `actors(doc, chaos: true)` finding text kept only in memory; the journal's lives, recorded and replayed; `Full`; five refusals (`at` in `at`, an actor `at`-ing its family, a handler of more than its key, setup failing outside the family's `!`, a `finally` that can fail), each the family's or an ordinary type rule; `post`: arguments evaluated when posted, order under seeds, setup's errors, teardown draining, posting to its own family, two type errors on `post`'s `D.Call<()>` (a value, an error), a call value built, kept and posted, siblings never waiting past `mailbox:`, a chain reaction panicking past twice it, research/actors-post/'s first two counterexamples | none |
| 8 | the document server's actors under `actors(doc, chaos: true)`, in miniature | `docs`, `lost_update`, `memory` (bench/tasks.t) |

**bench/services/ holds the programs** with native relevance, each with
a `.expected` as bench/data's (what `ren run` prints, `exit N`, the
first line of stderr), and bench/build.t's last section runs them
through `spec`: `pipe` (step 1), `wiring` (step 2), `release` (step 4)
and `refused`, which `ren run` runs once steps 3 and 6 land and whose
`ren build` must say `refused.native`'s line. `wiring.explain` is `ren
explain-wiring live wiring.ren`'s output (step 2). The step that lands
one says `as specified` there and adds it to the `same`, `release` and
`tcc_same` loops.

**bench/services/docs, lost_update and memory are the milestone**
(step 8), run by bench/tasks.t: `docs` is the document server, whose
`expected` is what `ren test` prints there; its tests install
`actors(doc, ..., chaos: true)`, so chaos is in the program, not a flag
(there's no `ren test --chaos`). Its `services_milestone` holds once
`ren test --seeds 1000` passes in docs, `ren test --sim --seeds 200`
fails lost_update's "two sessions' edits both land" with a seed that
`--seed` fails again with the same `left:` and `right:`, fixed.ren's one
operation passes a thousand seeds, and memory's text kept only in memory
passes a thousand seeds in its calm test ("without chaos, every edit is
still there") and fails its chaos test ("under chaos, every edit is
still there") by a seed that `--seed` fails again. Step 8 moves `docs`
to examples/docs (`git mv`), where THE CHECKS run its tests, as 11a's
programs moved; `lost_update` and `memory` stay, since their tests are
meant to fail.

**Existing tests that change,** each by the step named:

- step 1: none; `|>` and a line starting with `.` parse only where
  nothing did. `try`'s reach is unchanged for every expression with no
  `|>` in it.
- step 2: none of the compiler's tests; ledger's and server's tests are
  split the way §5's "Tests" says (The inventory).
- step 3: test_tasks.ml's five tests of 11a's rule (s2 "a task beside a
  `with` is cancelled when its body ends"; the two s8 batcher tests,
  whose flusher is spawned beside `with sync.batcher()`; s9 "a task
  spawned beside a `with` by a task inside its body" and "a task's task
  spawned outside a `with`"), each rewritten with `Async.beside` or
  `Async.background`, or turned into the compile error where that's
  what it shows; s1's "a handler has no task of its own", whose help
  names `Async.beside`; examples/refresh's three tests, unchanged in
  what they assert.
- step 4: every journal text with a `Proc.run` line, which gains the
  `kill` argument, `Proc.run("sh", ["-c", "echo base"], Tree)`
  (examples/journal.t, examples/just.t, examples/console.t,
  test_journal.ml); test_deps.ml's handlers for `Proc`, whose `run` arm
  takes `kill`; deadlock panics in test_tasks.ml, which gain the
  instances each task holds where it holds one.
- step 5: none; an `Array` is a pull argument by snapshot, as `for`
  takes it, so every `Async.map` and `Async.each` reads the same.
- step 6: test_tasks.ml's five `keyed` tests (s8), moved to
  test_services.ml as `striped` tests, `keyed(4, h)` becoming
  `striped(h, by: Key(n: 4))` and its `merge:` where a keyless operation
  gives a value (11a's "gives what the last gave" isn't a fold the menu
  has: those tests read each stripe's value with a keyed operation
  instead, or `Custom` of a handler that keeps the right one).
- step 7: examples/just/tests/build.journal, recorded again as version
  3; bench/11a/tasks/journal/v1.expected, whose help names version 3
  (a version 1 journal is still refused, as is a version 2); every
  journal's header in a test, which gains `parts:` once a family is
  installed (none today).

### The inventory

Every site the stage changes, counted by grep over every Ren source and
document (examples/, bench/, the strings of test/*.ml, lib/core's
prelude.ml and std_lib.ml, the tree-sitter corpus, and the `.md` files
outside briefs/ and research/), and the compiler's own code.

**`sync.keyed`**, which `striped` replaces (step 6):

| where | sites |
|---|---|
| test/test_tasks.ml: five s8 tests, `keyed` by key, refused of an `Int`, two keys overlapping, `finally`s last made first, fewer than 1 panicking | 7 calls |
| lib/core/std_lib.ml: `pub fn keyed`, its section and the header's mention | 3 |
| lib/core/prelude.ml: `Sync_keyed`'s type (`intrinsic_type`), and the three lists that name it (`runtime_only`, `waits`'s exclusions, the table of all) | 4 |
| lib/core/intrinsic.ml: `Sync_keyed` and its name | 2 |
| lib/eval/builtins.ml: `Sync_keyed`'s evaluation, the panic for fewer than 1 | 1 |
| lib/eval/value.ml: `VKeyed`, `VKeys`, and their `show` | 4 |
| lib/eval/eval.ml: `Dep_call` on `VKeys`, `With` and `With_handler` of a `VKeyed`, `share_reach`, `endings`' comment | 5 |
| lib/eval/walk.ml: `VKeyed` and `VKeys` in two walks (`fixed_hash` stays, for `striped`'s key) | 2 |
| lib/sema/infer_expr.ml: `keyed_described`, and its call | 2 |
| lib/sema/infer_msg.ml: `keyed_not_described` | 1 |
| docs: async.md (the `sync` table's row and the sentence before it), deps.md:440, handlers.md:295, README.md's 11a roadmap row | 5 |
| examples/, bench/, the corpus | 0 |
| **total** | **36** |

foundations.md and language.md name `keyed` only as what `striped`
replaces; they're design and stay. compiler.md's 11a sections are its
history and stay. What replaces the 36 is smaller in the checker and
larger in the runtime (decision 20): `VKeyed`'s instances move to
lib/eval/family.ml, reached through `Instances`; `keyed_described` and
`keyed_not_described` go with nothing in their place, since `striped`'s
checks are ordinary type rules or its own panics at the `with`. No
site names `Merge<D>`, `ren test --chaos` or `sim.scheduler`'s
`evict:`, which the first draft of this section specified and decision
20 removed: nothing to undo outside this section and its tests.

**The rule 11a built for background work** (step 3): a task spawned
into a scope that began before a `with` whose instance it can reach is
that `with`'s background task, cancelled when the body ends.

| where | sites |
|---|---|
| examples/refresh/main.ren: `shop`'s refresher, spawned into the scope outside `try with refreshing()`, and the comment that says the `with` cancels it (its three tests assert what stays so) | 1 |
| async.md: "Background work is a task beside the `with`" (the metrics flusher), the batcher's flusher in "What tasks share", the refresh program's prose, the Effect table's `Layer.scoped` row, the summary line | 5 |
| test/test_tasks.ml: s2 "a task beside a `with` is cancelled when its body ends"; s8's batcher tests (2); s9's two `context` tests; s1's "a handler has no task" help | 6 |
| lib/core/std_lib.ml: the batcher's comment ("a task's, spawned beside the `with`") | 1 |
| lib/eval/sched.ml: `frame.bg`, `task.context`, `beside`, `enter_with`'s frame, `leave_with`'s cancelling, and `spawn`'s registration (`beside sc evidence`) | 6 |
| lib/eval/eval.ml: `endings`' `Sched.enter_with` and three `Sched.leave_with`s | 4 |
| **total** | **23** |

A task spawned into a scope opened inside the `with`, as every server's
connections are, isn't touched: the rule only ever applied to a scope
that began before the `with`.

**`Async.map` and `Async.each` taking only an `Array`** (step 5):

| where | sites |
|---|---|
| lib/core/prelude.ml: `map` and `each`'s parameters `xs: Array<T>`, and `task_map`'s and `task_each`'s types | 4 |
| lib/eval/builtins.ml and eval.ml: `Task_map` and `Task_each`, which index an array | 2 |
| lib/sema/infer_expr.ml: `each`'s block giving a value (unchanged), the pull parameter's check (new) | 1 |
| async.md's "Later" line on streams; stdlib.md's `Async` table | 2 |
| callers: test_tasks.ml (29 lines), examples/crawler (1), examples/just (1), README (6), async.md (13), errors.md, runtime-io.md, language.md, foundations.md, streams.md | 0 to change: an `Array` is a pull argument by snapshot |

**`Proc.run`,** which gains `kill: Kill = Tree` (step 4):

| where | sites |
|---|---|
| lib/core/prelude.ml: the operation; `real_proc`'s, `test_proc`'s and the replayer's `run` arms | 4 |
| lib/core/std_lib.ml: `sim_proc`'s `run` arm, `SimProc` (gains `kills`) | 2 |
| lib/core/intrinsic.ml, builtins.ml, eval.ml, sched.ml (`proc_run`, `wait_pid`'s kill) | 5 |
| callers: examples/just/main.ren (1), test_deps.ml (10), test_journal.ml (1), test_tasks.ml (1) | 13, unchanged: `kill` has a default |
| journals: examples/just/tests/build.journal (3 lines), and the journal texts in examples/journal.t (6), examples/just.t (6), examples/console.t (3) | 18 lines, each gaining `, Tree` |
| docs: README (4), async.md (2), deps.md (3), handlers.md (6), runtime-io.md (3), examples/just/README.md (1) | 19 |

**Examples that repeat a `with` list or wrap one in a function that
takes a block** (step 2). The brief names bank, shop, ledger and server;
counted:

| example | `with`s | repeated lists | a function taking a block | what step 2 does |
|---|---|---|---|---|
| bank | 0 (its `with` is a group's, `clock_conforms(c) with c`) | 0 | 0 | nothing to move; noted in its README |
| shop | 0 | 0 | 0 | nothing to move |
| ledger | 6 | 5 × `sql.mem_sql(start(), _)` | 0 | `wiring mem(fail: FailAt) provides Sql = sql.mem_sql(start(), fail)`, its tests installing `mem(Never)` |
| server | 5 | 4 × `sim.net()` in tests | 0 | `wiring live(addr: Addr) provides ...` for `main`, tests on a split wiring |
| prices, crawler, transfer, refresh, just | 4, 4, 5, 5, 10 | none of more than one item | 0 | none required |

Docs with the function-that-takes-a-block pattern: deps.md:685 and
README.md:412's `with_fake_net(body: fn() uses Net)`, which step 2
rewrites as a wiring; language.md §5's `live(body: ...)` and
foundations.md's decision 5 show it on purpose and stay.

**Names the stage makes words:** `wiring`, `provides` and `release` are
contextual, as `concurrent` and `spawned` are (The grammar), since
`release` is an operation's name today (`sync.Semaphore.release`,
test_tasks.ml's `Sem.release`, bench/11a/limit_panic.ren) and nothing
may break. `|>` is a new token; no program writes `|` then `>` today
(grep over every Ren source: 0).

### The grammar

The forms this stage adds, in parser.ml's notation (its header comment
gains them):

```
item     := ... | ["pub"] wiring
wiring   := "wiring" IDENT ["(" param, ... ")"] "provides" tyname {"," tyname}
            [uses] [errors] "=" witem {"," witem}
                                               (`wiring` and `provides`
                                                are words only here; the
                                                items may go on lines
                                                after a `,`, as a `with`'s)
expr     := pipe ["orelse" expr]
pipe     := link {"|>" link}                  (one link is just `or`)
link     := ["try" | "attempt"] or            (the head: `or`, which is
                                                one term or refused below)
          | ["try" | "attempt"] step          (after `|>`)
step     := target ["(" arg, ... ")"] [lambda]
                                              (a trailing lambda only in
                                                the chain's last step)
target   := IDENT | IDENT "." IDENT | tyname "." IDENT
                                              (a function, `module.f`,
                                                `Type.f`, a parameter or a
                                                `let`-bound block: Resolve
                                                decides which)
unary    := ... | ["try" | "attempt"] "release" postfix
                                              (`release` a word only before
                                                a name on its line)
param    := ... ["=" (literal | ctor_ref)]    (a default: a literal, or a
                                                variant written bare)
field    := IDENT ":" type ["=" literal]      (a variant's field may have a
                                                default, as a parameter
                                                does: `Key(n: Int = 16)`)
dep      := ["pub"] "dep" tyname ["<" tparam, ... ">"] [errors] "=" ...
                                              (a dependency may carry an
                                                error row, `Actors<K, D> ! E`)
dep_alias := ["pub"] "dep" tyname "=" dep_ref [errors]
                                              (`dep Docs = Actors<DocId,
                                                Doc> ! StoreDown`)
type     := ... | tyname "." "Call" ["<" type [errors] ">"]
                                              (`Doc.Call<()>`, `D.Call<R ! E>`:
                                                What's decided 6; a case is
                                                built as `Type.Case { .. }`
                                                is, the path one part
                                                longer: `Doc.Call.Edit
                                                { op }`, new in step 6)
arm      := ... | "call" "(" param {"," param} ")" "=>" body
                                              (the `call(c: D.Call)` clause)
```

**`|>`** is the token `PIPEGT`, lexed before `|` (lexer.ml's
`lex_token`, beside `||`), as language.md §8 says; nothing that looks
for `|` alone (sum types' lines, error sets, `fail A | fail B`, or-
patterns) sees it.

**Where the chain sits.** `pipe` is between `orelse` and `or`
(language.md §8, "Grammar and layout"): `parse_orelse` calls a new
`parse_pipe`, which calls `parse_or` for the head and, while the next
token is `PIPEGT`, parses a step. So `a orelse b |> f` is `a orelse (b
|> f)`, and a chain followed by `orelse` is `(chain) orelse ...`. The
head is one term: if what `parse_or` gave is a `Binop` (anything but a
unary or postfix expression, `try`, `attempt` or a parenthesized one),
it's "`|>` takes one value on its left". After the last step, a binary
operator or a comparison is "a chain ends its expression"; `orelse`,
`)`, `]`, `,`, `then`, `else`, `in`, `=>` and the end of the line are
what may follow. `&` before the head (`Ref`) is "`|>` passes a value".

**A step** is parsed by its own function, `parse_step`, not as a
postfix expression, since what it may be is narrower: an optional
`try` or `attempt`, then an `IDENT`, `IDENT . IDENT` or `UIDENT .
IDENT`, then optional arguments in parentheses (`parse_call_arg`, so
by-name arguments work: `|> Async.map(max: 8) fn(x) => ...`), then an
optional trailing `fn` block. `&` there is "`|>` passes a value"; `fn`
there is "a step is a function by name, not a block"; anything else (a
literal, `(`, `[`, a constructor) is the same error, whose help names
the block as a `let`. A trailing block on a step followed by `|>` is
"only the chain's last step can take a block" (decided after the
draft).

**`try` and `attempt` stop at `|>`.** `parse_unary`'s `TRY` parses
`parse_expr` today, the whole expression to its right (parser.ml,
"`try` covers every call to its right"), and `ATTEMPT` `parse_add`. The
parser gains a mutable field, `p.chain_stops : bool`, set while a
`try`'s or an `attempt`'s operand is parsed and saved and put back
around it; while it's set, `parse_pipe` returns its head without
looking for `PIPEGT`. Every place that starts a fresh expression inside
brackets or a body sets it back to `false` for what it parses: a
parenthesized expression, an array literal, a call's and an index's
arguments, a record's fields, a lambda's body, `if`'s branches, a
`match`'s arms and a `with`'s body. So `try order |> validate` is `(try
order) |> validate`, `try f(a |> g)` is `try f((a |> g))`, and `try a()
+ b()` with no `|>` is what it was. `attempt`'s operand, `parse_add`,
already stops before `|>`, which isn't an additive operator; the field
makes it explicit. `assert` still takes the whole expression, chains
included.

**Continuation lines** (lexer.ml's `continues ()`): an indented line
that starts with `|>`, or with `.` followed by a letter or `_` (not `..`
and not a digit), continues the line above, as one starting with `uses`
or `!` does, and gets no layout token. "Indented" is as for `uses`: its
column is past the innermost block's indent (`!i - !bol > current
()`). A line at the block's indent, or one starting with anything else,
is a statement as before; a line starting with `.` today is always a
parse error ("expected an expression"), so nothing that parsed changes.
In brackets nothing changes either, since `continues` is only asked
inside a block. tree-sitter's external scanner (editors/tree-sitter-
ren/src/scanner.c) does the same where it decides a newline is a
`_newline` or nothing.

**`wiring`** is an item: `parse_item` sees `IDENT "wiring"` followed by
an `IDENT` (a lowercase name) and calls `parse_wiring`. `provides` is a
word after the parameters (or the name, when there are none, `wiring
core provides ...`); a missing one is "a wiring says what it provides".
`uses` and `!` are `parse_uses` and `parse_errors`, as a function's,
and may start a line, indented, as a function's do. After `=` come
`with` items, each `parse_with_item` (so chains, `over` and `as` work
as in a `with`), separated by `,`, which may end a line. Anything that
isn't a list of items, a block whose first line is a statement, is "a
wiring's body lists what it installs". `pub wiring`'s `pub` is
`parse_item`'s, as for the other items.

**`release`** is a word in `parse_unary` when `IDENT "release"` is
followed, on the same line, by an `IDENT` (`Next`, `next`): `release
Next.get(id)`, and `try release ...` through `TRY`'s operand. Followed
by `(`, `:`, `=` or anything else, `release` is the name it is today: a
call, an arm `release() =>`, an operation `release: fn()`. Its operand
is `parse_postfix`, one call.

**A default that's a variant written bare** (What's decided 11): a
variant with no fields, or one whose fields all have defaults.
`parse_param`'s `pdefault` accepts a `ctor_ref`, `Tree` or `Kill.Tree`,
not followed by `(` or `{`; one followed by them is "a parameter's
default is a literal, or a variant written bare". Ast's `pdefault`
becomes `(default * Loc.t * int) option` with `default = Lit of literal
| Ctor of 't ctor_ref`; Resolve resolves the constructor as it does in
an expression; Iface's `defaults` keep it as the constructor's path;
Infer checks it against the parameter's type as an argument would be (a
constructor of that sum, every field of which has a default); Lower
fills a call's missing argument with the constructor applied to its
fields' defaults, as it fills a literal. **A variant's field may have a
default** (`parse_variant`'s fields go through the parameter's default
rule, literals only), so `pub type By = | Key(n: Int = 16) | Worker`
declares `Key`, and `Key` written bare, as a default or as any value,
is `Key(n: 16)` (a constructor is called as a function is, and a field
with a default is given by name or left out, language.md §2's one
by-name form); `Key(n: 64)` gives it; `Worker(n: 4)` stays today's "`Worker`
has 0 fields but was given 1", which is how `by: Worker` with a count
can't be written. An operation's parameter may have a default too,
written in its dependency's declaration (`run: fn(cmd: Str, args:
Array<Str>, kill: Kill = Tree) -> Int ! ProcError`,
`parse_fn_ty_param`), since `Proc.run` is an operation: a `Dep_call`
fills it as a function call does (`Infer_env.defaults_of`, keyed by the
operation's path), and an arm takes the parameter as any other. Step 4
builds all three, as the first step whose surface needs them ("Where
this stage may differ"); step 6's `By` is the first field default std
declares.

### The AST

ast.ml gains, each a constructor the compiler then points at every
`match` that needs it:

- expressions: `Pipe of { subject : expr; step : expr; args : expr
  list; mark : mark option; block : expr option }`, one link, the
  subject the chain before it (so a chain of three is two nested
  `Pipe`s), `step` the target as written (a `Var`, or a `Field` of a
  module or a type), `mark` the step's own `Try` or `Attempt` (`mark =
  Mark_try of Loc.t | Mark_attempt of Loc.t`) and `block` its trailing
  lambda; `Release of expr`, the call it covers.
- items: `Wiring of wiring_def`, with `wiring_def = { wpub : bool;
  wname : ident; wparams : param list; provides : 't dep_ref list;
  wuses : 't uses option; werrors : 't errors option; witems : with_item
  list; wloc : Loc.t }`.
- `with_item` gains `from : 't wired option`, `None` as parsed, and
  Resolve's record of the wiring an item was flattened from ("Wirings
  (step 2)", below).
- parameters: `pdefault`'s `Ctor`, above; a variant's fields gain the
  same `pdefault`.
- dependencies: `Dep_alias of 't dep_ref * 't errors option`, and a
  `dep`'s header its own `errors option` (step 7); a type `Call_ty of
  't dep_ref * ty option * 't errors option`, `D.Call<R ! E>` (step 6);
  a handler's arm `Call_arm of param list * expr`, the `call(c:
  D.Call)` clause (step 6), beside `over any`'s `call =>`, which stays.

**As built,** three of these differ, each recorded in its step's
"Chosen" list below: a link is `Pipe { subject; step }`, `step` the call
with a `Piped` first argument (step 1); an item's `from` is the list of
wirings it came through (step 2); and a concrete `Doc.Call` takes no type
arguments, generic code's `D.Call<R ! E>` being the prelude's `Call<D,
R, E>` (steps 6a and 7b).

The tree-sitter grammar gains `pipe_expression` (with `pipe_step`
children, each with an optional `try`/`attempt` field), `release_
expression`, and `wiring_definition` with `provides`, `uses`, `errors`
and `with_item` children; Zed's highlights give `|>` the operator
colour and `wiring`, `provides` and `release` the keyword colour where
the grammar has them.

### The pipe (step 1)

**`x |> f(a)` is `f(x, a)`, checked as that call** (language.md §8,
"The rules"). Resolve resolves `step` as the callee of a call, so a
function, `module.f`, `Type.f` (an associated function or a method), a
function parameter or a `let`-bound block; anything else, a field of a
value, `rules.apply` with `rules` a local, is "a step is a function by
name, and `rules.apply` is a field of `rules`" (Resolve: the parser
can't tell `m.f` from `o.f`). Infer infers `subject` first, with its
own markers, then checks the call `step(subject, args..., block)`
through `infer_call`'s path for a call (so defaults, by-name arguments
and the trailing block are as a call's), with three differences:

- **The step's `mark` covers only the step's call,** not the subject's:
  the subject was inferred already, so its calls carry their own
  markers, and the call's `ecall` gets the step's marker alone. A step
  that can fail without one is "`validate` can fail, and nothing handles
  it" with the note "in a chain each step that can fail carries its own
  `try`" and the help "write `|> try validate`, or handle it with
  `match`", even inside `attempt (...)` or `match (...)`, which still
  receive what a step's `try` passes on (§8, "`try` on each step"). A
  `try` on a step that can't fail is today's "nothing here can fail".
- **A `Try` or `Attempt` that is a chain's subject and covers nothing
  that can fail** is "`try` stops at `|>`", with the note "it covers
  only `order`, which can't fail; each step is marked on its own" and a
  help that writes the chain with a `try` on each step that can fail
  (Infer knows which by then). The check runs where a marker's coverage
  is checked (`Marker`, solve.ml), which knows the marker is a pipe's
  head by a flag the `Pipe` sets on its subject's node.
- **The subject's type against the first parameter.** A mismatch at the
  first argument is "`|>` puts `rules` first, but `apply` takes an
  `Order` there", with "`rules` is a `Rules`, which `apply` takes
  second" when another parameter's type unifies with the subject's (a
  trial unification, `Unify.atomically`), the note "`|>` always passes
  its value as the first argument", and the help "call it directly:
  `apply(order, rules)`" (or `twice(...)` when no other parameter
  matches). **A step that's a method of the subject's own type**, `Type.f`
  where `Type` is the subject's type and `f` has `self`, is "`len` is
  `Array`'s own method, so it's called with `.`" with "help: write
  `(...).len()`, or end the chain with a `let`".

Lower makes `let s = subject in step(s, args)`, so Core, the
interpreter and native code see a call; Core Lint has nothing new. A
chain builds natively with nothing more, which bench/services/pipe and
build.t check.

### Wirings (step 2)

A wiring adds three things to a `with` set: a name, a limit on what the
body sees, and parameters (language.md §5, "The rules"). The decisions
(What's decided 1): `[pub] wiring name(params) provides Ds [uses Ds] [!
Es] = items`; flattened where it's used into one `with` set;
`provides` always written, limiting only what the body calls; `uses`
and `!` inferred for a private wiring and written for a `pub` one,
direct needs only; not a value; items only; wirings combine and nest;
parameters carry config and descriptions; plain `with` still exposes
everything; teardown in reverse install order; every error of §5 with
its fix-it, and `ren explain-wiring`. Left out: `but`, overrides,
sealed wirings, two copies of a sub-graph.

**Flattened in Resolve, into calls of functions it makes.** An item of
a wiring is an expression that makes an implementation, in the
wiring's scope (its parameters, its module's names). Another module
can use a `pub` wiring, but can't see the private names in its items,
so a use site can't be given the items' text. Resolve gives each link
of each item a function of its own instead, `live$1(url: Str) =
pg_db(url)`, `live$2() = console_audit()`, ... (paths `Path.member live
"$1"`, as a member's), taking the wiring's parameters and returning the
link's implementation, as `fn at(minutes: Int) -> Clock =
Clock.frozen(...)` does today (test_deps.ml); `pub` when the wiring is,
with its type inferred (a function's result may be an implementation,
whose needs are its named row, `-> (Db uses ..d)`). A link that's
exactly one of the wiring's parameters, `db` in `wiring app(db: Db)
provides Users = db, ...`, gets no function: the use site passes the
argument straight through, since a dependency-typed parameter used as a
value isn't transparent ("`c` is used as a value here", test_deps.ml).

**The wiring's shape** is what a use site needs, kept in Resolve's
module table and, for a `pub` one, in its interface (`Iface.t` gains
`wirings : wiring list`): its path, its parameters' names and types,
its `provides`, and its items flattened, each with its links' function
paths (or the parameter it passes on), its `under`, its `alias` and its
origin, the chain of wirings it came through with each one's
`provides` and where it's declared. A wiring that lists another
flattens that one's items into its own, recursively, with the outer's
parameters passed to the inner's functions as its call gives them; a
wiring that lists itself, through any number of others, is "`a` lists
itself: a → b → a" (Resolve, a depth-first walk over the wirings'
items, as `no_set_cycles` walks error sets).

**A use.** A `with` item whose top link is a wiring's name, `live`, or
a call of one, `live(url)` (Resolve decides by what the name is,
`Hashtbl.find_opt env.wirings`), becomes, in Resolve's output:

- its arguments bound by `let`s around the `with`, in order, once, so
  `live(Os.args()[0])` reads the arguments once however many items use
  them (decided here: §5 doesn't say, and an item's arguments are
  evaluated before any is installed today, so this keeps the order);
- one item for each of the wiring's flattened items, in its order, each
  link a call of its function with the bound arguments, each with
  `from = Some { wiring; origin; provides }`.

So Infer's `with_` (infer_handlers.ml) sees one flat set and does what
it does today: classifies each link, refuses a dependency installed
twice, finds the install order (`install_order`), and nests each item
around the ones after it. Only the items' `from` is new, and these use
it:

- **`provides`, enforced at the body.** An item whose `from` chain has
  a wiring whose `provides` lacks a dependency the item installs hides
  that dependency from the body. `install` passes it, `~hidden:(Some
  wiring)`, into the `Install` constraint it defers (`Install` gains
  `whidden`), and solve.ml's `install` reports, when the body's row has
  the hidden label, "`live` installs `Db` but doesn't provide it" at the
  body's first call that uses it (the body's `calls`, as the missing
  need's error finds its call), with "help: add `Db` to `live`'s
  `provides`, or install your own inside: `with mem_db() in`". The
  items still meet each other, and an item beside the wiring in the
  same `with` meets what it hides, since that's installation, not the
  body. A dependency that's installed hidden is never also the outer
  one for the body: the body can't reach it at all, so a nested `with`
  installs its own.
- **The errors name the wiring.** "this `with` installs `Db` twice:
  `mem_db()` here, and `pg_db(url)` in `live` (main.ren:2)" (Infer_msg's
  `installed_twice` gains the origin); "nothing installs `Db`, which
  `db_users()` in `live` needs", pointing at the `with` and at the
  wiring's line, with "help: add an item that installs `Db` beside
  `live`: `with live, mem_db() in`"; "`ping()` and `pong()` in `both`
  each need what the other installs" with the loop drawn as a note,
  "`ping()` → `pong()` → `ping()`" (`needs_each_other`, as ZIO draws
  it).

**The wiring's own check.** Infer checks each wiring as it checks a
function, through a function Resolve makes for it, `live$wiring(url:
Str) = try with <its items> in ()`, never called and dropped by Lower:
the `with`'s needs from outside are the wiring's `uses`, and what
installing it can fail with its `!`, by the machinery a function's row
and errors already have. For a private wiring they're inferred and
kept as its scheme; for a `pub` one they're written and checked with
`Declared`, so a need it doesn't write is "`live` needs `Db`, which it
doesn't declare" with "help: add it to `uses`: `uses Db`". The `with`
is marked as the wiring's (`Install_order` at its node, and a flag on
`with_`), which adds three checks there:

- **`provides` names what nothing installs:** "`live` provides `Clock`,
  which nothing in it installs";
- **an item nothing uses:** an item none of whose installs is provided
  or needed by another item of the wiring is "`audit()` in `live`
  provides `Audit`, which nothing needs" (Ren has no warnings);
- **`provides` naming what a nested wiring hides** is that wiring's
  hidden-service error, "`core` installs `Audit` but doesn't provide it".

A wiring's scheme is `ren types`' line, `wiring live(url: Str) provides
Users uses Console ! DbDown`. **A wiring used as a value**, its name
anywhere but a `with`'s item (or another wiring's), is Resolve's "a
wiring isn't a value" with "help: install it: `with live in ...`".
Teardown needs nothing: the set's install order is the order of its
`finally`s reversed, as today.

**`ren explain-wiring live [file]`** (bin/main.ml, Driver's new
`explain_wiring`) checks the program and prints, for the wiring's own
`with`, the install order and what each item meets: each item on a
line, numbered in install order, what it installs, and what it needs,
each met by an item's number or "from outside"; the wiring it came
through, if it's a nested one's; then the wiring's `uses` and its
teardown order. bench/services/wiring.explain is its output for
bench/services/wiring.ren.

Natively a wiring is nothing new: its link functions are functions
that return descriptions, which 10d's dispatch already compiles, and
the `with` is a `with`. bench/services/wiring checks it.

### Step 2b: service

Decided after the draft (2026-10-29; language.md §4, "A service: a dep
and its implementation, written once"): a dependency whose interface
comes from its one implementation is declared with it. It lands as step
2b, right after wirings and, in the order the steps were built, beside
step 3 (built in parallel, from 84ac5d3; neither depends on the other),
through the whole pipeline, natively too.

```ren
pub service Kv(c: ClientCfg) uses Http, Clock, Random =
  pub fn get(k: Key) -> Option<Entry> ! ClientError | Conflict | StoreFull = ...
  pub fn put(k: Key, v: Bytes, cond: Cond) -> Version ! KvError = ...
  fn call(req: Request, idempotent: Bool) -> Response ! KvError = ...   // reads c.token
```

**The grammar** (parser.ml's notation):

```
item     := ... | ["pub"] service
service  := "service" UIDENT "(" param, ... ")" [uses] [errors] "="
            INDENT member { NEWLINE member } DEDENT
                                              (`service` is a word only
                                                at an item's start, before a
                                                capitalized name; `uses` and
                                                `!` in either order, as a
                                                wiring's)
member   := ["pub"] fn_def                    (its operations are its
                                                `pub fn`s)
primary  := ... | IDENT "." UIDENT "(" ...    (`kv.Kv(cfg)`, another
                                                module's service installed:
                                                a call of `kv.Kv`, which
                                                was a parse error)
```

The parameters are written even when there are none, `service
Counter() =`, as a handler's are, and it's installed with them,
`Counter()`. Its state, `let`, `var` and `finally` lines, comes first,
as a handler's does ("Step 2b (state)", below). The AST gains `Service
of service_def` (`spub`, `sname`, `sparams`, `suses`, `serrors`,
`sstate`, `members`, `sloc`), as parsed only, as a `Wiring` is.

**It lowers to exactly a `dep` and a handler** (rule 1), in Resolve,
first thing, where it's written in the module (`service_items`), so
nothing after Resolve knows services exist:

```ren
pub dep Kv =
  get: fn(Key) -> Option<Entry> ! ClientError | Conflict | StoreFull
  put: fn(Key, Bytes, Cond) -> Version ! KvError
pub handler Kv(c: ClientCfg) for Kv uses Http, Clock, Random =
  get(k) => try Kv$get(c, k)
  put(k, v, cond) => try Kv$put(c, k, v, cond)
fn Kv$get(c: ClientCfg, k: Key) -> ... uses Http, Clock, Random = ...
fn Kv$put(c: ClientCfg, ...) -> ... uses Http, Clock, Random = ...
fn Kv$call(c: ClientCfg, req: Request, idempotent: Bool) -> ... uses Http, Clock, Random = ...
```

- **The operations are the `pub fn`s** (rule 1), each a field of the
  `dep` with its signature as written: `->` left out is `()` and `!`
  left out is none, as a public function's, since they're the
  interface. An operation's parameters have types; it takes no type
  parameters and no `inout`, as a dependency's operation doesn't.
- **The handler is named as the service is,** `Kv`, which no
  function can otherwise be (a function's name is lowercase), so a
  `with` installs it by calling it, and another module finds it among a
  `pub` service's values. Its `uses` is the service's (written for a
  `pub` one, inferred for a private one, as a handler's), its `!` the
  service's, its arms each a call of the member, `try` in front where
  the operation can fail.
- **Each member is a function,** named `Kv$get`: a name no one can
  write, which `--release` doesn't make either (it names an arm it
  lifts `handler.op`, which `Kv.get` would have met), shown as `Kv.get`
  in a message (`Ast.fn_name`) and left out of `ren types`, as a
  wiring's link functions are. It's private, taking the
  service's parameters first, then its own (rule 2). Its `uses` is the
  service's: written, a bound it keeps to (below), or none for a `pub`
  service that writes none; inferred for a private service. A member
  that writes its own `uses` is refused, with the help that moves it to
  the service's.
- **Members call each other directly** (rule 2): inside a member, a
  call of another member's name that no local hides, `call(req, true)`,
  is Resolve's call of `Kv$call(c, req, true)`, the shared parameters'
  binders passed first, so a local of the same name as a parameter
  can't take their place. Members call each other in any order, and
  recursively, as functions do. A member used as a value, not called,
  is refused, since it would need its shared arguments: "`get` is a
  function of `Kv`, so it's called, not passed". A member in a chain,
  `s |> pad(n)`, is `Kv$pad(fill, s, n)`: the step's `Piped` follows the
  shared arguments, which infer_expr.ml's `infer_pipe` and `piped_why`
  allow for. `Kv.get(k)` written inside a member would reach the `Kv`
  installed where the call runs, not this one, and is refused.
- **Callers see only `Kv`** (rule 3): the dependency, its operations,
  `uses Kv`; never the parameters or the `uses`.

**Installed like a handler** (rule 4). A `with`'s link and a wiring's
link are where `Kv(cfg)`, which the parser reads as a constructor, and
`kv.Kv(cfg)` are installs: Resolve marks where each is written
(`installed`, `env.installs`), and makes it there a call of the handler
(`service_named` finds it: the module's own service, unless a
constructor of its own sums has that name, or a type imported by name
whose module has a public value of that name). Anywhere else a service's
name is refused (below). So a wiring item, `wiring live(c) provides Kv
= Kv(c), mem_store()`, needs nothing new: its link function's body is
the handler's call. `ren explain-wiring` shows it as written.

**Replaced by any handler** (rule 5): it's a `dep`, so `test handler
fake_kv() for Kv` installs in its place, in a test or anywhere.

**A signature's `uses` is a bound** (decided with it): listing a
dependency the body doesn't use is accepted, as it was; errors stay
exact. A member's `uses`, the service's, is checked as one: what a
member uses past it is reported at the member, at the call that brings
it in, "`Kv.get` uses `Console`, which `Kv` doesn't declare", and not
again at the handler, whose arms only call members
(infer_declared.ml's `check_needs` skips a service's handler).
**Private functions don't write `uses`:** the examples step 2 touched
(checkout, server) lose theirs; ledger had none on a private function.

**Natively** a service is a handler and functions, which 10d already
compiles; bench/services/service builds one installed by a wiring and
replaced by a handler, in build.t's `same`, `release` and `tcc_same`
loops.

**Its errors** (Resolve's, but the parser's first), each with help:

```
error: `get` shares `Kv`'s `uses`, so it doesn't write its own
  = what its functions need is required where `Kv` is installed, so it's written once, on `Kv`
  help: move it to the service's: `service Kv(...) uses Clock, Console`

error: a service isn't a value
  help: install it, `with Kv(...) in ...`, and call its operations: `Kv.op(...)`

error: `Kv(...)` installs a service, so it's written in a `with` or a wiring
  = a `with` item is never a value, so `Kv(...)` there can't be read as a constructor
  help: install it where it's used: `with Kv(...) in ...`

error: a function of `Kv` calls another directly
  = `Kv.get` calls the `Kv` installed where the call is, which isn't this one
  help: call it directly: `get(...)`

error: `get` is a function of `Kv`, so it's called, not passed
  help: call it in a block: `fn(...) => get(...)`

error: `Kv.get` uses `Console`, which `Kv` doesn't declare            (Infer)
  = a service's functions share its `uses`, which is what a `with` that installs `Kv` needs
  help: add `Console` to `Kv`'s `uses`

error: `get` is an operation of `Kv`, so its parameters have types
  help: write its type: `k: T`

error: `Kv` has no operations: a service's operations are its `pub fn`s
  help: mark the functions its callers call `pub fn`

error: a service's state comes first, before its functions          (parser)
  help: move it above the service's first function

error: `n` is `Counter`'s state, so its type is written
  = each of `Counter`'s functions is given its state, as a parameter, and a parameter's type is written
  help: write it: `var n: T = ...`

error: `start` is a function of `Kv`, which its state can't call
  = `Kv`'s functions are given its state, which is still being set up here
  help: set it up here, or with a function outside the service

error: `Kv`'s state is given to its functions by name, so it isn't taken apart
  help: name it, and take it apart where it's used
```

The tests are test/test_service.ml's (`[s2b accept]`, `[s2b reject]`),
a file of their own since step 3 changes test_services.ml beside this
step; tree-sitter's `service_definition` and the `kv.Kv(...)`
constructor, the corpus (service.txt), the highlights and Zed's
outline.

### Step 2b (state)

language.md §4's rule 4: "`! E` is what it fails to start with, and it
may keep state in `var`s." Built after step 4, as a follow-up to 2b.

```ren
service Counter(c: Cfg) uses Console ! Refused =
  var n: Int = c.start
  let label: Str = try open(c.start)
  finally(r) =>
    print("closing " + label)
    try r
  pub fn add(k: Int) -> Int = bump(k)
  fn bump(k: Int) -> Int =
    n += 1
    if k > 1 then bump(k - 1) else n
```

is

```ren
handler Counter(c: Cfg) for Counter uses Console ! Refused =
  var n: Int = c.start
  let label: Str = try open(c.start)
  finally(r) => ...
  add(k) => Counter$add(c, &n, label, k)
fn Counter$add(c: Cfg, inout n: Int, label: Str, k: Int) -> Int = bump(k)    // Counter$bump(c, &n, label, k)
fn Counter$bump(c: Cfg, inout n: Int, label: Str, k: Int) -> Int = ...
```

- **The state lives in the handler,** as written: its `let`s, `var`s
  and `finally`s are the handler's state, in order, set up by each
  `with` that installs it, failing with its `! E`, its `finally`s
  covering what follows them and the `with`'s body, as a handler's do
  (handlers.md). So installing it with `try with`, and a test handler
  in its place, are as before.
- **Each member is given the state,** after the service's parameters:
  a `var` as an `inout` parameter, a `let` by value, each under its own
  name, so a member reads and writes `n` as it's written. An arm passes
  its instance's `&n`; a member calling another passes its own `&n`
  on (Resolve's call, as for the parameters, `passes` saying which go by
  `&`). Members still call each other directly, in any order and
  recursively, being functions.
- **Sound under decision 10 and excl.ml's rules, with nothing new:** an
  operation keeps its instance until its arm returns, and a member
  called from it is a direct call inside that arm, never an operation,
  so it never takes the instance again. What it's given is the arm's
  own state, passed `inout` as any `&` argument is, so exclusivity
  checks it as it checks any call: two `var`s are two places, and a
  block in a member that calls another member captures the parameter as
  any block does (rule A). Nothing outlives the arm: a `var`'s changes
  are written back when the call returns, before the arm does.
- **Its type is written, or a literal's** (`0`, `"x"`, `true`, `1.5`):
  a member's parameter needs a known type, since a private function's
  untyped parameter is generalized and a method on it, `log.push(x)`,
  can't be found. `var log: Array<Str> = []` writes it. A state taken
  apart by a pattern is refused: it's given by name.
- **The state can't call a member,** since every member is given the
  state being set up. `finally` can't either, for the same reason where
  it stands; a member a `finally` needs is written in its body or
  outside the service.

Its errors are above. The tests are test_service.ml's (`[s2b accept] a
service keeps state in `var`s...`, setup failing under `try with`, a
test handler in its place, a block calling a member, and the three
refusals); natively bench/services/service, whose `Kv` keeps a count
and a list and reports them in its `finally`. tree-sitter's
`service_definition` takes `state` and `finally` lines (service.txt).

### Background work (step 3)

Decision 7: "A task can't reach a handler installed inside the scope
it's spawned into. It's a compile error, since the task could outlive
the handler; its help says to open the scope inside the `with`... where
a scope passed to a helper hides which is inner, the check is the run
time's"; "Background work is a scope of its own: `Async.beside(task)
fn() => body` ... `Async.background fn(bg) => body`"; "A background
task's failure cancels the body and is its error". This replaces 11a's
rule ("Structured tasks (step 2)", "A task spawned beside a `with` is
its background task"), which step 3 removes from sched.ml and eval.ml
(The inventory).

**The compile error** is Excl's, which already knows rule C's frames:
for `s.spawn`, `s.start` and `s.replace` where `s` is the parameter of
an `Async.scope` block in the same function (the case rule C finds
syntactically), the `with`s between that block and the spawn are known;
if the spawned block's evidence, the dependencies it uses (Infer's
`calls` for the block, recorded at the spawn's node), names one any of
those `with`s installs, it's "this task can reach `Ticks`, installed
inside the scope it's spawned into" with the label on the `with` and
"help: open the scope inside the `with`: `with ticks() in Async.scope
fn(s) => ...`, or run it beside the body with `Async.beside`".

**The run time's check** is the spawn's: `Sched.spawn` is given the
block's evidence (it is today, for `beside`); if any instance in it was
installed after the scope began (11a's one compare: `With`s are
numbered in one order across tasks, `Sched.begun`) and its `with`'s
body is still running in the spawning task, the spawn panics with the
same headline as the compile error, "panic: this task can reach
`Ticks`, installed inside the scope it's spawned into", and "help: open
the scope inside the `with`" (decided after the draft: a panic at the
spawn). What was `beside`'s registration becomes this check; `frame.bg`
and `leave_with`'s cancelling go (the tasks' `context` stays: "Chosen in
step 3").

**`Async.beside` and `Async.background`** are members of `Async` in the
prelude, over intrinsics, as `scope` is:

```ren
// runs `task` beside `body`: when `body` ends, by returning, failing or
// being cancelled, `task` is cancelled and waited for; a failure of
// `task` cancels `body` and is the result
pub fn beside<T>(task: concurrent fn(), body: fn() -> T) -> T uses Async =
  try task_beside(task, body)

// the same for tasks spawned with `bg.spawn` as `body` goes
pub fn background<T>(body: fn(bg: Scope) -> T) -> T uses Async =
  try task_background(body)
```

Both run `body` in the calling task. `task_beside` starts `task` as a
task of a scope of its own, runs `body`, then cancels the scope's tasks
and waits for them (`Sched.cancel_all`, then `wait_empty`), then gives
`body`'s result; if a background task fails first, the body is
cancelled from the beside down (as `Async.timeout` cancels its body),
and once that's reached the beside, it fails with the background
task's error (the first one's, as a scope's first failure wins).
`background`'s `bg` is a `Scope` whose spawned blocks may fail
(`task_background` gives `body` a scope whose `spawn` takes a block
with an open error row, which Infer types by the member's signature:
`Background` is a builtin type beside `Scope` whose `spawn` is `fn
spawn(self, body: spawned fn())` with the block's errors passed out of
`background`), and the rest is `beside`'s. So in `with pool() in
Async.beside(health) fn() => Async.scope ...`, the scope's work drains
when the body's scope ends, then the health task is cancelled and
waited for, then the `with`'s `finally` runs: decision 7's pool order,
test_services.ml's "a pool's order". `beside`'s `task` is `concurrent`
(it runs while the caller's body runs, so rule B's read-only captures
apply, as `race`'s do); it may fail, unlike a spawned block (decided
after the draft: background tasks may fail).

Neither is native: `ren build` refuses them as it refuses `Async.scope`
(to_mem.ml's `tasks_not_native`, which gains `beside` and
`background`).

**As built (step 3).** `background`'s `bg` is a `Background<! E>`, a
builtin type whose argument is the error set its spawned blocks may fail
with, not a `Scope`; a task's `context` stays, since the run time's check
needs it; a task outside a `with` that reaches nothing it installs
outlives it. "Chosen in step 3", below.

### `release`, deadlocks and `Proc.run(kill:)` (step 4)

Decision 10: "`release` lets go for one call. `try release
next.get(id)`: the instance is let go of while that call runs, and
taken back after it, queueing like any caller ... `sim` switches tasks
at every `release`"; "`sim` names the instances a parked task holds ...
a task taking an instance it already holds panics rather than hangs";
"The queue is fair, not first in first out ... `sim` chooses among the
waiters and the arrivals from its tape". Decision 2's table's last row
is narrowed to "Inside a handler arm, `Async.until`, a `release` call,
or a block-parameter call: write of all the handler's state, that call"
(What's decided 10).

**`release`** is written in a handler's arm (lexically, blocks
included, as `Async.until` is: Excl's `in_op`) and nowhere else, "`release`
lets go of a handler's instance, so it's only written in one of its
operations" with "help: call it without `release`"; its operand is a
call of an operation of a dependency installed outside the handler (a
`Dep_call` after Lower; Infer's `Calls_op` before), anything else
"`release` lets go of the instance for one call of another dependency's
operation, and `twice(1)` isn't one" with "help: write it on the
operation's call: `release Next.get(id)`". Infer types `Release e` as
`e`, its errors and uses `e`'s; a marker on it covers `e`'s call (`try
release ...`).

Lower lowers it as `until_released` lowers `Async.until` (lower.ml):
the arm's copies of its state written back to their cells (`Set_cell`
of each of `cx.cells`), then the intrinsic `arm_release()`, then the
call inside a Core `Finally` whose `after` is `arm_retake()`, so the
instance is taken back however the call ends, then each copy read
again (`Get_cell`). In the interpreter `arm_release` is `Sched.released`
of the instance the task's innermost operation holds
(`Sched.op_instance`), after setting the lock's holder to none and
remembering its depth, as `Sched.until` does; under `sim` it's a
scheduling point; `arm_retake` is `Sched.holding`'s queueing, back to
the depth it had. With no other task, and natively, both do nothing,
and the writes and reads give back what they wrote: a plain call
(decided after the draft; bench/services/release).

**As built (step 4).** `release` covers `next.op(...)` as well as
`D.op(...)`; it's a scheduling point only where the instance is shared
with a spawned task, as an operation's call is, so `arm_release` and
`arm_retake` aren't among `Intrinsic.waits` and a function that writes
`release` needn't use `Async`; a task keeps what it has let go of,
`task.let_go`, which the panics' "holding" leaves out; and `sim`'s fair
choice applies only while it isn't following a recording. "Chosen in
step 4", below.

**Decision 2's row, narrowed** (excl.ml). Today a `Dep_call` in an arm
is a change of all the handler's state for the call (Excl's `Dep_call`
access kind, and `across`'s error, "`r` is changed across a dependency
call", with `dep_call_note`). After step 4 only three calls are: a
`Release`, `Async.until` and a call of a block parameter (`Block_call`,
unchanged). A plain dependency call holds none of the state, sound by
decision 10 (an operation calls only handlers installed outside it, so
nothing it calls can come back into the instance running it, and
research/decision-11/'s model found no two writers, no lost update and
no stale read). So an actor's loop `for x in &r => Sink.put(x)` over a
reader kept in its state is accepted, and the same with `release
Sink.put(x)` is "`r` is changed across a call that lets go of the
handler" (the error's wording for `release`; `dep_call_note` becomes
"at `release` and `Async.until` other tasks run the handler"). The
native build's borrow of state across a plain dependency call is then
sound for the same reason: no other code can reach the instance during
it, and Mem Lint's checks stay as they are.

**Deadlocks.** A task taking an instance it already holds already
panics (11a's step 4, `Sched.holding`'s `reentered`, test_services.ml
keeps it plainly). The deadlock panic, and the cycle panic of 11a's
step 9, gain, for each parked task, the instances it holds:
`task.holding`'s labels, "= main/main:0 waits in `Async.until` at
test.ren:11:13, holding `A` (a.go)". So decision 10's "other waits"
deadlock, an operation of `A` calling `B`, which waits in `until` for a
task that must go through `A`, says where it is.

**`sim`'s fair choice** (decided after the draft: it lands here). Today
a released instance goes to the first waiter whose condition holds,
else the first queued caller (`Sched.released`, first in first out).
Under `sim` it goes to none: the waiters whose conditions hold and the
queued callers are all woken, and so is nothing else; each competes
with the tasks that can run, and the first of them the tape picks to
run that calls the instance takes it (an arrival, a task that wasn't
queued, can win: `Sched.holding` gives an unheld instance to whoever
asks). The others queue again in the order they're woken. That's
decision 10's "chooses among the waiters and the arrivals from its
tape". Under `single` nothing changes, so `ren run`'s output doesn't.
No waiter is passed over without bound: under `sim` by the tape's
uniformity, and `single` stays first in first out.

**`Proc.run(cmd, args, kill: Kill = Tree)`** (What's decided 3): the
prelude gains `pub type Kill = | Tree | Child` and the operation's
parameter with its default. The real `Proc.run`'s child is made by a
small C stub, not `Unix.create_process`, which can't set a process
group: `fork`, then in the child `setpgid(0, 0)` and `execvp`, with no
OCaml code between them (a C function in lib/eval's stubs, `ren_spawn_
group`); a cancel with `Tree` sends SIGTERM to the group (`kill(-pid,
...)`), then SIGKILL after the cleanup deadline, and `Child` keeps 11a's
behaviour, the process alone. `sim.proc()`'s `SimProc` gains `kills:
fn() -> Array<Kill>`, the kill of each cancelled run, in `killed()`'s
order. examples/just.t's `sh -c "sleep 5; true"` cancelled leaves no
`sleep`.

### Pull arguments, channels and producers (step 5)

streams.md's "Concurrency and time" and rule 3: "`Async.each` and
`Async.map` take any pull argument ... pull the next item only when a
slot frees, and are bounded by `max:`, 64 by default"; "A pull
parameter takes what `for` takes, written the same way". Decided after
the draft: pull arguments now are collections (by snapshot), temporary
data cursors, `&r`, a hand-written `fn() -> Option<T>` block, and a
channel's `items()`.

**A pull parameter** is a new parameter mode, written `xs: pull T` (a
word there, as `concurrent` is; `Ty.param`'s `block` gains `Pull`),
meaning "takes what `for x in ...` takes, its items `T`". The prelude's
`map` and `each` become `pub fn map<T, U>(xs: pull T, max: Int = 64, f:
concurrent fn(x: T) -> U) -> Array<U> uses Async` and the same for
`each`. Infer checks a pull argument as it checks a `for`'s subject
(infer_expr.ml's `for` path): an `Array<T>`, `Map` or `Set` (by
snapshot), a value with `next(inout self) -> Option<T>` (a temporary
cursor, as itself), `&r` of a named cursor, or a block `fn() ->
Option<T>`, its items `T`. Excl records `&r` as decision 2's new row,
"a write, held for the call", so the block touching `r` is "`r` is
changed for the whole call". Lower turns each into a step block, `fn()
-> Option<T>` (an index over the snapshot; `r.next()` on the place for
`&r`; the block itself), which `task_map` and `task_each` call on the
caller's task only when a slot frees, so memory is bounded by `max`;
`map` keeps its results in order, a finished one behind a slow head
keeping its slot (streams.md). A pull argument's errors (a block that
can fail, `for p in try items`) pass out of the call as its block's do.

**Channels as dependencies.** `sync.Chan<T>` stays a dependency; a
program names one, `dep Events = Chan<Event>`, and installs it, `with
sync.channel(16) as Events`. **`Events.items()` is an ordinary function
of `Chan<T>` in `sync`,** as `Fs.read_str` is a function of `Fs`
(What's decided 4: nothing is derived for it). `Chan<T>` gains, in
std_lib.ml's source:

```ren
pub dep Chan<T> =
  ...
  // the items received, until the channel is closed and empty: a cursor
  // whose `next` is `recv()`, pulled where it's written
  pub fn items() -> Items<T> uses Chan<T> = Items {}

// what `items()` gives: a cursor over the channel it's pulled from
pub type Items<T> = {}
  pub fn next(inout self) -> Option<T> uses Chan<T> = Chan.recv()
```

Called through an alias, `Events.items()`, a member function's `uses
Chan<T>` is the alias it's called through, as every dependency's member
function's is (`Fs.read_str`'s `uses Fs`), so the cursor's `next`, which
runs where it's pulled (a `for`, or a pull argument, both on the
caller's task and inside its `uses`), receives from `Events`, and two
channels of one element type don't mix where each is named (streams.md).
A temporary cursor is a pull argument as itself (above), so `Async.each(
Events.items())` needs nothing more. What step 5 checks: that a member
function of a generic dependency called through an alias resolves its
`uses` to the alias, which `Fs` (not generic, never aliased) never
tested; if it doesn't, `items()` is written `Events.items()` only where
the alias's type names it, and the step says so ("Where this stage may
differ").

**`Async.produce`** (decided after the draft: its `items` is a block
parameter, `fn() -> Option<T>`, looped with `for p in try items`):

```ren
pub dep Send<T> =
  send: fn(x: T)

// runs `f` on a task in the consumer's scope, sending through `Send<T>`,
// at most `cap` items ahead; `body` pulls them. When `body` ends, by
// finishing, `break` or a failure, the producer is cancelled and waited
// for; a failure in the producer ends the stream with it
pub fn produce<T, R>(cap: Int = 16, f: concurrent fn() uses Send<T>,
    body: fn(items: fn() -> Option<T>) -> R) -> R uses Async
```

`Send<T>` is a prelude dependency `produce` installs for `f` (decision
5: dependencies are found where a block is written; `f`'s parameter
type says `uses Send<T>`, so the call provides it and `f` may use more,
transparently). The interpreter's `task_produce` makes a buffer of
`cap` items (a prelude-private handler `buffer<T>(cap)` for `Send<T>`,
whose `send` waits in `Async.until` while it's full), starts `f` as a
task of a scope of its own with it installed, and runs `body` with the
pull block `fn() => buffer's take()`, which waits while it's empty and
the producer runs, gives `None` once the producer has returned and it's
empty, and, once the producer has failed and it's empty, fails with the
producer's error (so `items` can fail with `f`'s errors, which is why
it's looped with `try`). When `body` ends the producer's scope is
cancelled and waited for, as `beside`'s is. A producer blocked at `cap`
makes progress as the consumer takes (each take releases the buffer's
instance, waking `send`'s `until`). **`Async.map_pull(src, max: Int =
64, f) fn(results) => body`** has `produce`'s shape: `src` a pull
argument, `f` concurrent, `results` the pull block of `f`'s results in
`src`'s order, the tasks living exactly as long as `body`.

None of it is native: to_mem refuses `produce` and `map_pull` with
`tasks_not_native`, and `each` and `map` as today.

**As built (step 5).** A pull parameter is a block parameter `fn() ->
Option<T>`, not a mode of its own; `for` loops over such a block; a
cursor's `next` may use a dependency and fail; `Events.items()` runs
with `Events`'s implementation as `Chan<T>`'s; a stream given to a block
parameter fails with its function's errors; and the buffer is the
scheduler's. Each is in "Where this stage may differ", below, with why.

### The keyed instance family (step 6)

What's decided 5; foundations.md decision 18, "The keyed instance
family: a runtime primitive", and decision 20's closed list, which names
it among the runtime's privileged handlers. A program never holds an
instance (the bet), so a library that keeps many can't keep them
itself: the runtime keeps them for it, as it keeps tasks. The family
does five things and owns decision 18's soundness rules; it decides
nothing a library decides (which instance to evict, when, how many to
keep, how to route), so `actors` and `striped` are two libraries over
it and a third is written the same way (step 7's test, a family of a
fixed key set).

**Ren reaches it through `Instances`,** a runtime dependency in the
prelude, as it reaches `Fs` (handlers.md, "How it runs"): its real
implementation, `real_instances()`, is the only caller of the
`family_*` intrinsics, and Core Lint checks that as it checks
`fs_read`'s (prelude.ml gains a list beside `reaches`, `runtime_of`,
mapping each `family_*` intrinsic to `("Instances", op)`, which Core
Lint's "only the dependency's `real` calls it" covers; `reaches` stays
the world's, since the journal doesn't record these as calls: it has
its own lines for them, Journal version 3). The runtime installs
`real_instances()` around `main` and each test, as the journal's
handlers are, and **a `uses` never names it**: it's ambient, like the
journal, so keeping instances adds nothing to a library's callers'
`uses` (what a library needs besides, as `actors`' `Random`, is named as
any need is). Only privileged code is ambient
(decision 20's closed list); a test can't swap it, as it can't swap the
journal.

```ren
// the runtime's keyed instance family (foundations.md, decision 18):
// instances of one handler, by key, made, pinned, evicted and queued for
// by the runtime, under its rules. Which to evict, when, how many to keep
// and how to route are the library's that opens one
pub dep Instances =
  // a family of `h`'s instances, one per key, in `parts` partitions of at
  // most `cap` live instances each. Calls from outside it wait while its
  // queued calls are over `mailbox`; a sibling's post past twice it panics
  open: fn<K has hash, D ! E>(h: fn(k: K) -> D ! E, parts: Int, cap: Int, mailbox: Int) -> Family<K, D ! E>
  // runs `body` with k's instance installed as `D`, pinned: made first if
  // it isn't live (its setup's errors are `E`), after evicting the key
  // `victim` picks from k's partition's evictable keys, least recently
  // released first, when the partition is full; waiting while `victim`
  // gives `None`, unless waiting could close a cycle (No deadlock, below)
  pin: fn<K, D ! E, T>(f: Family<K, D ! E>, k: K, victim: fn(lru: Array<K>) -> Option<K>, body: fn() -> T uses D) -> T ! E
  // puts `c` in k's queue and returns, making k's instance as `pin` does
  // but never waiting for a slot; a delivery runs it, as one operation,
  // on a task of the family's
  post: fn<K, D ! E>(f: Family<K, D ! E>, k: K, c: D.Call<()>, victim: fn(lru: Array<K>) -> Option<K>) ! E
  // runs `body` with k's instance pinned if it's live, without making it
  // or counting as use; `false` if it isn't live
  visit: fn<K, D ! E>(f: Family<K, D ! E>, k: K, body: fn() uses D) -> Bool
  // evicts k's instance now, running its `finally` on this task, if it's
  // live and evictable; whether it did
  evict: fn<K, D ! E>(f: Family<K, D ! E>, k: K) -> Bool
  // the live keys, in creation order
  keys: fn<K, D ! E>(f: Family<K, D ! E>) -> Array<K>
  // the evictable keys, least recently released first, across
  // partitions; with `idle`, only those released at least that long
  // ago, by the scheduler's clock (virtual under `sim`)
  evictable: fn<K, D ! E>(f: Family<K, D ! E>, idle: Duration = Duration.zero) -> Array<K>
  // live, made, evicted, and the most calls queued at once
  counts: fn<K, D ! E>(f: Family<K, D ! E>) -> Counts
  // the family's end: delivers what's queued (deliveries may post more),
  // then runs the live instances' `finally`s, the last made's first
  close: fn<K, D ! E>(f: Family<K, D ! E>)

pub type Counts = { live: Int, made: Int, evicted: Int, high_water: Int }

// a family `Instances.open` made: data, naming it, kept in the state of
// the handler that opened it, never an instance
pub type Family<K, D ! E> = builtin
```

- **`Family<K, D ! E>` is a handle, not an instance:** a number naming
  a family in the runtime, so keeping it in a handler's state keeps no
  instance (the bet holds). A library opens one in its setup and closes
  it in its `finally`; a call on a closed family panics, "this family
  ended with the `with` that opened it", which is how a handle that
  escaped (returned from an operation) is caught: sound, since nothing
  is reached through it once the runtime has dropped the family.
- **`h` is the family's maker,** a block that makes the instance for a
  key (the handler's name as a function: `doc` is `fn(id: DocId) -> Doc
  ! E`, its errors its setup's). The runtime keeps it for the family's
  life, with the evidence captured at `open`, which is inside the `with`
  that installs the opening handler, so the instances' needs are met by
  that `with` set. Infer treats a parameter passed straight on to a
  maker as a maker too (`actors`' `h`), and checks, where a handler's
  name is given to one, three things any library over the family gets:
  its `finally` can't fail ("`doc` is kept by a family, so its
  `finally` can't fail"); it may name, in its `uses`, the dependency the
  family's opener is installed as, which the `with` set's cycle rule
  allows for exactly this need (a post holds nothing); and its arms
  don't pin that family (below).
- **The soundness rules are the primitive's** (decision 18, "The
  soundness rules are the primitive's"; research/actors-post/): a post
  makes its instance; queued calls count as waiting, so an instance with
  mail is never evicted and a delivery never runs setup; a post's making
  may go past `cap` when nothing is evictable, rather than wait; every
  call from outside the family is metered at its edge, `pin` and `post`
  waiting while the family's mail is over `mailbox`, and a sibling's
  post (from an instance's operation, or a delivery, of the same family)
  never waits; past twice `mailbox` a sibling's post panics, with the
  high-water mark; teardown drains, then runs the `finally`s in reverse
  creation order; partitions each with their own map and cap.
- **No deadlock** (decision 18, decision 10's inner-to-outer rule):
  checks on `pin`, as decision 7's are on `Async`'s spawn. Statically,
  Infer marks each operation whose arm reaches `Instances.pin` (in its
  body or through what it calls, Iface's `pins` per operation, as
  `calls` is kept), and refuses such an operation called inside a block
  pinned by the same family ("`Docs.at` inside a block of `Docs.at`
  could wait for a slot its own block holds") or in an arm of a handler
  that family's maker makes ("`doc` is kept by `Docs`'s family, so it
  can't call `Docs.at`, which pins one of its siblings"); at run time,
  `pin` panics with the same headline where a helper hid it (a task
  that already pins one of the family's instances, or is one of its
  deliveries), and a task that pins an instance of family A and would
  wait for a slot of a family not installed outside A fails with `Full`
  instead. `Full` is in no signature: Infer adds it to the errors of a
  pinning operation's call only where that call is lexically inside
  another family's pinned block, where the checker sees the cycle
  (decided after the draft), and marks the call so; the family fails
  such a call with `Full`, and where an unmarked call (a helper's) would
  wait so, it panics, "a task pinning `Outers` would wait for a slot of
  `Inners`, installed inside it": sound, since no error reaches a caller
  that didn't declare it, and the panic is where the deadlock would be.
- **The LRU is the family's:** an order of release it exposes, not a
  policy. Which instance became evictable last is something only the
  runtime sees (a delivery's operation ending, an `at` block's pin
  released by another task), so Ren over it can't keep the order cheaply,
  and the brief's risk allows it: `pin`'s and `post`'s `victim` block and
  `evictable()` give it, least recently released first, and the library
  picks (`actors`' `Lru` takes the first; `chaos` what `Random` picks;
  `evict_idle(d)` those `evictable(idle: d)` gives).
  Nothing in the family knows `Lru`, `max:` or chaos.
- **`Async.worker() -> Int`** is a new scheduler operation any library
  can call, the worker the calling task runs on: `0` under `single`;
  under `sim`, `0` or `1`, two virtual workers, each task's drawn from
  the tape when it's spawned (decided after the draft), so routing by
  worker is from the tape. It's `Async`'s (the scheduler's), not the
  family's.

**The family in the interpreter: lib/eval/family.ml,** a module of its
own beside sched.ml (the brief's risk: "a second scheduler inside the
first"), using sched.ml's waits, scheduling points, tape and journal
hooks and nothing else of it:

```ocaml
type family = {
  name : string;                (* `docs`: the one rule's name, below *)
  mailbox : int;                (* the edge's bound *)
  parts : part array;           (* a key's by Walk.fixed_hash mod parts *)
  make : Value.t -> Value.t;    (* the maker: runs `h(k)` and its setup *)
  mutable order : int;          (* creation counter, for teardown and `keys` *)
  mutable mail : int;           (* calls queued, across the family *)
  mutable high : int;           (* the most at once *)
  mutable made : int; mutable evicted : int;
  incarnations : (Value.t, int) Hashtbl.t;   (* by key, the last life's
                                                number, kept across
                                                eviction *)
  queues : (Value.t, Value.t Queue.t) Hashtbl.t;  (* `D.Call`s by key,
                                                     not by instance *)
  mutable closed : bool;
}
and part = {
  live : (Value.t, inst) Hashtbl.t;   (* its own map *)
  lru : inst Dll.t;                   (* its evictable instances, least
                                         recently released first *)
  cap : int;
}
and inst = {
  key : Value.t; life : int; born : int;  (* `docs[DocId(7)]#3`, and its
                                             place in creation order *)
  installed : Value.installed;      (* its instance: number, lock, finally *)
  mutable pins : int;               (* pinned blocks and visits holding it *)
  mutable waiters : int;            (* tasks waiting for it: setup, a slot *)
  mutable released_at : float;      (* for `evictable`'s times *)
  mutable state : Making of setup | Live | Evicting;
}
```

An instance is **evictable** when it's `Live` with no pins, no waiters,
no operation running (its lock has no holder) and nothing queued for
its key; the LRU holds exactly the evictable ones, an instance going to
its back when it becomes evictable. **Making one in a full partition**
asks `victim` with the partition's LRU's keys and evicts the one it
names, whose `finally` runs on the making task, shielded under the
cleanup deadline as 11a's `finally`s are (a cancelled caller still pays
the eviction it began); a `victim` that names a key not in the list
panics ("`victim` picked a key that isn't evictable"). When it gives
`None`, the maker waits (a scheduler wait on the partition, woken when
one becomes evictable), or, for a post's making, goes past the cap.
**Setup** runs on the first caller's task, state `Making`; others asking
for the key wait for it and share its error; a setup that's cancelled
leaves the key unmade and wakes its waiters, the first of whom tries
again. **A delivery task per key with mail** (research/actors-post/'s
model), spawned into a scope the family owns, which `close` waits for:
it pins the key, calls each queued `D.Call` on it as one operation (the
interpreter's `Dep_call` of the call's operation and arguments, what
`D.call(c)` does, below), and ends when the queue is empty.

**Journal names, by one rule** (What's decided 5; decision 11, as task
paths are named): a family is named where it's installed, by the
dependency its opening handler is installed as, snake_cased (`with
actors(doc) as Docs` names it `docs`; `with striped(counter())`, for
`Hits`, names it `hits`), and a second family one handler opens is
`docs.2`; an instance is the family's name, its key written as a value
is, and its incarnation, which counts a key's lives from 1:
`docs[DocId(7)]#3`. No library names anything: the runtime knows the
`With` frame `open` ran in. A delivery task is named by its instance.

**Partitions** decide which instance is evicted, so their count is
fixed by the library, `parts`, never by the runtime or the cores: a
journal from one thread replays on many (decision 18). The journal's
header records each family's `parts`.

None of it is native: to_mem refuses the `family_*` intrinsics, said at
the program's call that reached them (as a std panic is), "`striped`
uses the keyed instance family, which isn't native yet".

**As built (steps 6a, 7a and 7b).** The listing above is the design; the
prelude's `Instances` differs in its signatures, each recorded in its
step's "Chosen" list below. It's a dependency with members and no
operations, since an operation can't be generic yet: `open(make: spawned
fn(k: K) -> D, parts, cap, mailbox) -> Family<K, D>`, what making an
instance fails with carried by a description, `Family<K, (D ! ..e)>`,
not a third parameter; `pin`, with `enter`, `made` and `visit` beside it
for a library's operations, whose types can't name setup's errors;
`post(f, k, c, victim) -> Pinned<D>`; `call(f, k, c)` and `make` for
`striped`; `evictable(f)` and `idle(f, d)` in place of
`evictable(f, idle:)`; and `counts` an `InstanceCounts`.
`Async.worker()` draws a task's worker the first time it asks, not at
its spawn. A family's partition count is its journal's `opened` line,
not the header's `parts:`.

### `D.Call` (step 6)

What's decided 6; decision 18, "A call is a typed value"; decision 7's
`over any`; formats.md, "Dependencies as data" (signed off after the
brief, 7830e5d), whose `D.Call` this is, the part of it this stage
needs. **For each dependency `D` the compiler writes `D.Call`,** one
case per operation, its parameters as fields and their defaults as
field defaults, as it writes a description's enum (language.md §6),
but data: `Doc.Call` for `dep Doc = edit: fn(op: Op) -> Version !
StoreDown; join: fn(c: ConnId)` is

```ren
type Doc.Call<R ! E> =        // written by the compiler, not by a program
  | Edit { op: Op }           // a Doc.Call<Version ! StoreDown>
  | Join { c: ConnId }        // a Doc.Call<()>
```

- **Each case is the operation's name in upper camel case** (`edit` is
  `Edit`, `evict_idle` `EvictIdle`), its fields named as the
  operation's parameters, so a call is built and matched as any sum
  with named fields is, `Doc.Call.Edit { op }` and `Edit { op } =>`.
- **`D.Call` exists only if every operation of `D` is data** (formats.md:
  no block, no `&` or `inout` argument, no view, a data result);
  naming it for any other dependency is a build error naming the
  operation, "`Doc.Call` needs every operation of `Doc` to be data, and
  `each` takes a block". So a dependency with a block parameter can't
  be posted to at all, the first half of decision 18's rule for `post`.
- **Its type carries the operation's result and errors:** a variant's
  value is a `D.Call<R ! E>` with R and E that operation's, fixed by the
  constructor as a GADT's are, and `D.Call<()>` is a call that gives
  `()` and can't fail. A `match` on a `D.Call<R ! E>` refines R and E in
  each arm to that operation's (a constructor fixes them, with no
  existential, so refinement is substitution); that's the one place the
  checker refines, and only `D.Call`'s variants do it. Written without
  arguments, `D.Call` in a clause's parameter is `D.Call<R ! E>` for the
  clause's own R and E.
- **Its arguments are values the derived walk covers** (`show`, `==`,
  `repr`, `parse`), so the family's queue copies them and the journal
  writes them as any value: `show(c)` is `Edit { op: Append("a") }`.
- **Members the compiler writes,** the least `post`, the queue, the
  journal and `striped` need (the rest of a dependency's operations as
  data is 12c): `D.call(c)` calls the operation `c` names, with its
  arguments, on the `D` in scope, giving R and failing with E (so
  `try D.call(c)`); `c.first_hash() -> Option<Int>`, the first
  argument's key's `Walk.fixed_hash` (its type's `key`, or the value,
  as 11a's `keyed` hashed), `None` for an operation with no parameters;
  `c.add(a, b)`, `c.max(a, b)`, `c.min(a, b)` and `c.concat(a, b)`,
  each on two results of `c`'s operation, its result type's `add`
  (operators.md), order, or `Array`'s `concat`, panicking for a result
  type that has none (what `striped`'s install check rules out); and
  `D.Call.operations`, a constant `Array<Operation>`, one per operation
  (a small stand-in for the shapes of formats.md's design, stage 12):
  `pub type Operation = { name: Str, params: Int, gives: Str, adds:
  Bool, orders: Bool, concats: Bool }`, `gives` the result type as an
  error writes it (`"Int"`, `"()"`). These are the program's
  declarations as data, which decision 20 rule 3 gives the language.
- **The `call(c: D.Call) => ...` clause.** A handler may write it beside
  its operations, or instead of them: it runs for each operation it
  doesn't write an arm for, `c` that call, its value the operation's
  result and its errors at most the operation's. In a handler `over D`,
  `next.call(c)` is `D.call(c)` against the next handler (formats.md).
  `over any`'s `call =>` arm stays as built (its `call.forward()`,
  `call.name`, `call.args`). formats.md's `D.Reply` and `D.Error`, the
  sums of results and errors, are later (12c): here a call's result is
  its type's `R`, so `D.call(c)` gives `R`, not a `D.Reply`.
  A merge handler (Stripes) writes it with the two results after the
  call, `call(c: D.Call, a, b) => ...`, a and b typed R: that form is
  what a description's `call` clause called as a method takes,
  `m.call(c, a, b)`.
- **No trailing call** (decided 2026-10-29): `post` is spelled
  `Docs.post(k, Doc.Call.Edit { op })`, the call value written out, and
  `Docs.post(k).edit(op)` isn't built, since calls as data are designed
  with dependencies as protocols. The arguments are evaluated where the
  call value is built, before `post` runs, as any argument is, so a
  `var` changed after doesn't change the message.
- **`post`'s parameter is `c: D.Call<()>`,** so posting an operation that
  gives a value, or can fail, is an ordinary type error on that
  argument, with a help for a `D.Call<()>` parameter: "`post` takes a
  call that gives `()` and can't fail, and `text` gives a `Str`" (and
  "... and `edit` can fail with `StoreDown`"), "help: use the value, or
  handle the error, inside the operation, or make the call directly
  where its result is wanted". It's no rule written for `actors`: any
  function with a `D.Call<()>` parameter says the same.

**As built (steps 6a and 7b).** A concrete `Doc.Call` takes no type
arguments: the checker gives it a row of the cases it may be a call of,
and generic code's `D.Call<R ! E>`, the prelude's `Call<D, R, E>`,
unifies with it by closing that row to the cases whose operations give R
and fail with at most E, not by a GADT's refinement; `Doc.Call<R ! E>`
written of a dependency's own calls is refused. A `match` on a `call`
clause's call refines its result in each arm. The fold members are
`sum`, `max`, `min`, `concat` and `fold(m, a, b)`, and the operations as
data are the prelude's `operations(h)`, not `D.Call.operations`.

### Stripes (step 6)

What's decided 7; decision 18, "`striped`: map-reduce over fixed
stripes"; language.md §11, "Stripes" and "Policies are data". **Plain
Ren in std over the family,** in the prelude, since language.md writes
it bare; it calls nothing a user library couldn't: `Instances`,
`Async.worker()` and `D.Call`'s members.

```ren
// how `striped` routes an operation whose first parameter has a key
pub type By =
  | Key(n: Int = 16)        // to one of n stripes, by the key
  | Worker                  // to the stripe of the caller's worker

// how a keyless operation that gives a value folds its stripes'
// results, left to right in stripe order
pub type Fold<D> =
  | Unmerged                // none given: refused at install where it's needed
  | Sum | Max | Min | Concat
  | Custom(m: D)            // a stateless handler whose `call` clause folds

// the instances of `h`, kept by the runtime's family under fixed keys,
// the stripes' numbers. Callers can't tell: code that uses `D` doesn't
// know whether one instance serves it or sixteen
pub handler striped<D>(h: D, by: By = Key, merge: Fold<D> = Unmerged) for D uses Async =
  // under `Worker`, no stripe until a worker calls
  let n = match by
    Key(n) => n
    Worker => 0               // made on each worker's first call
  if by != Worker && n < 1 then lib_panic("`striped` keeps at least 1 stripe, not ".concat(show(n)))
  if merge == Unmerged then
    for op in D.Call.operations
      if op.params == 0 && op.gives != "()" then
        lib_panic("`".concat(op.name).concat("` runs on every stripe and gives an `").concat(op.gives).concat("`, so `striped` needs `merge:`"))
  ...                       // `Sum` of what doesn't add, and the rest, the same way
  // a stripe a key: under `Key(n)` the n made now, in order; under
  // `Worker` each worker's on its first call, fewer than 1024 of them
  let fam = Instances.open(fn(i: Int) => h, parts: 1, cap: if n > 0 then n else 1024, mailbox: 1)
  for i in 0..n => try Instances.pin(fam, i, fn(_) => None, fn() => ())
  finally(_) => Instances.close(fam)
  call(c) =>
    match c.first_hash()
      Some(x) =>
        let i = match by
          Key(n) => x % n
          Worker => Async.worker()
        try release Instances.pin(fam, i, fn(_) => None, fn() => try D.call(c))
      None =>
        // under `Worker`, the caller's stripe at least
        if by == Worker then try release Instances.pin(fam, Async.worker(), fn(_) => None, fn() => ())
        // every stripe in order, each pinned on its own: not a snapshot
        var got = None
        for i in Instances.keys(fam)
          let v = try release Instances.pin(fam, i, fn(_) => None, fn() => try D.call(c))
          got = match got
            None => Some(v)
            Some(a) => Some(combine(merge, c, a, v))
        got orelse lib_panic("`striped` has no stripe")
```

(The listing gives the shape; step 6 writes the whole. `combine` is a
function: `Sum` is `c.add(a, v)`, `Max` `c.max`, `Min` `c.min`, `Concat`
`c.concat`, `Custom(m)` `m.call(c, a, v)`; a `()` result combines to
`()` whatever the merge, so a broadcast needs none. Every `release` is
in the arm, on a call of `Instances`, as step 4's rule asks.)

- **Routing is an ADT,** so a count with `Worker` can't be written:
  `by: Worker(n: 4)` is today's "`Worker` has 0 fields but was given 1",
  an ordinary error, and there's no rule for it.
- **`Key(n)`, the default,** is the variant default with a defaulted
  field (What's decided 11): `by: By = Key` is `Key(n: 16)`. An
  operation whose first parameter has a key goes to stripe
  `first_hash mod n`.
- **`Worker`** sends a call to the caller's worker's stripe, made on that
  worker's first call: under `single` one stripe (decision 18's table:
  "one stripe: the merge is the identity"), under `sim` two, routing
  from the tape (`Async.worker()`), so a program whose result depends on
  routing beyond what the merge erases fails under some seed: the split
  law's test.
- **A keyless operation runs on every stripe,** in stripe order, each a
  pin of its own, so the fold is not a snapshot; one that gives `()`
  broadcasts, one that gives a value is folded with `merge:`.
- **The missing `merge:` is a panic at the `with`** (What's decided 7;
  decision 20, rule 3: a check `striped` makes on its arguments, which
  stage 12's build-time mechanism will make at build time): `striped`'s
  setup reads `D.Call.operations` and panics naming the operation. So
  does a fold that doesn't fit an operation's result, "`merge: Sum` adds
  what `all` gives, and an `Array<Str>` isn't a number". No Infer rule is
  written for either, and `keyed_described` goes with nothing in its
  place: `striped(16)` is the ordinary error of a dependency parameter
  given a value that isn't a description, "`striped` takes a handler's
  description, and `16` is an `Int`".
- **`Custom(m)`** holds a description of a stateless handler over `D`
  whose `call(c: D.Call, a, b)` clause folds two stripes' results for
  `c`; `striped` calls it as a method, `m.call(c, a, b)`, so a handler
  with state is the data stage's rule for a description called as a
  method, "`m` may be a description of `adding`, which keeps state, so
  it isn't called as a method": nothing written for `striped`.
- **A stripe takes the `release`d call** (step 4's `release`): `striped`
  is itself a handler with an instance, so its `call` arm lets go of it
  for the pin, else every caller would queue on `striped`'s instance and
  stripes would serialize. Sound by decision 10: the arm's only state is
  `let`s, which `release` writes back and reads again unchanged.
- **The journal** names a stripe by the one rule, `hits[3]#1`.

**As built (step 6b).** `striped` writes no `release`: its instance keeps
no `var`, so it isn't exclusive and its callers never queue on it. A key
goes to stripe `((h % n) + n) % n`, a first argument of any type being a
key; the folds are `c.sum`, `c.max`, `c.min`, `c.concat` and `c.fold(m,
a, b)`; its checks at the `with` read `operations(h)`; and `sync.keyed`
is "`sync` has no public `keyed`". "Chosen in step 6b", below.

`sync.keyed`, `Sync_keyed`, `VKeyed`, `VKeys` and their sites go (The
inventory), and `sync` has no `keyed`: "`sync` has no `keyed`" is the
ordinary missing member's.

### Actors (step 7)

What's decided 8; decision 18, "`actors`: one instance per key, made on
demand"; language.md §11, "Actors are a service"; decided after the
draft: `Docs.at`'s errors declared on the family, `Actors<K, D> ! E`,
`Full` where the checker sees a cycle; `post` is Erlang's cast;
partitions now; `Lfu` later; the journal's version 3. **Plain Ren in std
over the family,** in the prelude beside `striped`; the user's API is
language.md's, unchanged.

**The family's type.** `Actors<K, D> ! E` is an ordinary generic
dependency with an error row, declared in the prelude; a dependency
alias may carry one too, `dep Docs = Actors<DocId, Doc> ! StoreDown`
(the grammar's `dep_alias`), its `E` the errors of making an actor,
which `at` and `post` fail with.

```ren
// a family of actors of `D`, one per key `K`, made on demand: `E` is what
// making one can fail with
pub dep Actors<K has hash, D> ! E =
  // installs k's actor as `D` for `body`, pinned, making it if it isn't live
  at: fn<T>(k: K, body: fn() -> T uses D) -> T ! E
  // puts one call of `D` in k's mailbox and returns: Erlang's cast,
  // `Docs.post(k, Doc.Call.Edit { op })`
  post: fn(k: K, c: D.Call<()>) ! E
  evict: fn(k: K)
  evict_idle: fn(d: Duration)
  // each live actor, in creation order, pinned in turn; makes none, and
  // isn't use
  each: fn(body: fn() uses D)
  count: fn() -> Int
  made: fn() -> Int
  evicted: fn() -> Int
  high_water: fn() -> Int

pub type Evict = | Lru        // `Lfu` later

// actors of `h`, a handler whose one parameter is the key: at most `max`
// live, the least recently released evicted past it; calls from outside
// wait while `mailbox` posts are queued. `chaos: true`, a test's, evicts
// at each call the evictable actors `Random` picks
pub handler actors<K has hash, D ! E>(h: fn(k: K) -> D ! E, max: Int = 10_000, mailbox: Int = 10_000, evict: Evict = Lru, chaos: Bool = false, parts: Int = 4) for Actors<K, D> ! E uses Random =
  let fam = Instances.open(h, parts: parts, cap: max(1, max / parts), mailbox: mailbox)
  finally(_) => Instances.close(fam)
  at(k, body) =>
    if chaos then shake(fam)
    try release Instances.pin(fam, k, oldest, body)
  post(k, c) =>
    if chaos then shake(fam)
    try release Instances.post(fam, k, c, oldest)
  evict(k) => let _ = Instances.evict(fam, k)
  evict_idle(d) => for k in Instances.evictable(fam, idle: d) => let _ = Instances.evict(fam, k)
  each(body) => for k in Instances.keys(fam) => let _ = release Instances.visit(fam, k, body)
  count() => Instances.counts(fam).live
  ...
```

- **`h`** is the handler's name, `actors(doc)`: Infer checks it as any
  argument, `fn(k: K) -> D ! E`, so a handler of more than its key is
  "expected `fn(DocId) -> Doc`, found `fn(DocId, Int) -> Doc`", and
  setup that fails outside the family's `E` is the ordinary "this
  function can fail with `StoreDown`, and the type wanted here fails
  only with ..." with the alias's `E` (both at `actors(doc)`'s argument;
  the words that named actors go). Its other dependencies come from the
  `with` set, the maker's evidence; the family's own (`uses Docs`, to
  post to siblings) is the cycle rule's exception the maker has (The
  keyed instance family).
- **`at` and `post` take the actor through the family,** each arm
  `release`-ing `actors`' own instance for the pin or the post (step
  4), so `actors`' instance isn't held for a block: other callers'
  `at`s run while one block does. Each operation inside the block takes
  the actor for one call, as every handler's does.
- **Eviction under `max:`,** `cap: max / parts` per partition (at least
  1), its victim `oldest`, `fn(lru) => lru.first()`: `Lru` is std's
  policy over the family's order of release. The victim's `finally`
  runs on the caller's task (the family's rule).
- **`chaos: true`** (What's decided 8): `shake(fam)`, at each call into
  the family (`at`, `post`, `evict`, `each`), evicts each evictable
  actor for which `Random.int(2) == 0`, in `evictable()`'s order. Under
  `ren test` and `sim`, `Random` draws from the tape, so a seed that
  evicts a document between two sessions replays by `--seed`. The
  scheduler and `ren test` know nothing of it: there's no `ren test
  --chaos` and no `evict:` on `sim.scheduler`.
- **`actors` uses `Random`,** for `chaos:`, so an item `actors(...)`
  needs it from its `with` set, as any item does, and a `pub` wiring or
  a function with a written `uses` that installs one names it ("Where
  this stage may differ"). `striped` uses `Async`, for
  `Async.worker()`, the same way.
- **`finally` can't fail,** the maker's rule ("`doc` is kept by a
  family, so its `finally` can't fail").
- **No deadlock:** `Docs.at` in `Docs.at`, an actor's `at` on its own
  family, and `Full` are the family's checks on `pin` (The keyed
  instance family), each saying the dependency and operation the program
  wrote.
- **`post`** (What's decided 8, research/actors-post/'s fixed rules):
  `Docs.post(k, Doc.Call.Edit { op })`, whose `Doc.Call<()>` parameter
  makes "posting an operation that gives a value, or can fail" an
  ordinary type error, and `Doc.Call` itself a dependency whose
  operations are all data. A post makes its actor, so its only errors
  are setup's, `try Docs.post(k, Doc.Call.Edit { op })`; the queue,
  the order of one task's posts, delivery as one operation each on the
  family's tasks, the edge's meter, a sibling's post never waiting, the
  chain reaction's panic, and teardown draining are the family's rules,
  so `actors` writes none of them.

The panic's words name the alias the family is installed as, by the
one rule: "`Peers` has 5 posts queued, past twice its `mailbox:` of 2",
the high-water mark on the line after.

**As built (steps 7a and 7b).** `at`, `each` and `post` are members of
`Actors`, generic functions over its operations `enter`, `visit` and
`send`, since an operation can't be generic and its block can't fail;
`Actors<K, D>` takes two type arguments, an alias's `! E` being `D`'s,
`Actors<DocId, (Doc ! StoreDown)>`; `actors`' maker is `h: spawned fn(k:
K) -> D`; and a family has `max(1, min(parts, max / 64))` partitions.
"Chosen in step 7a" and "Chosen in step 7b", below.

### Journal version 3 (step 7)

Decided after the draft: the family adds made, evicted and posted
lines, and an operation names `docs[DocId(7)]#3` by the one rule for
every runtime instance family (The keyed instance family, "Journal
names"); that's version 3, and recorded journals are recorded again.

```
# ren journal 3 · main.ren · deps: Console Net · parts: docs 4
1 main/session:0 made docs[DocId(7)]#1
2 main/session:0 Net.write(...)
3 main/session:1 posted docs[DocId(7)] Edit { op: Append("a") }
4 docs[DocId(7)]#1 Store.save(...)
5 main/session:2 evicted docs[DocId(7)]#1
6 main/session:3 made docs[DocId(7)]#2
```

- **`made`** and **`evicted`** lines name the task that made or evicted
  the instance (the maker pays) and the instance by the one rule.
- **`posted`** lines are a post as data: the family and key (no
  incarnation: the queue is the key's) and the `D.Call`, written as a
  value is.
- **A delivery's task is named by its instance,** `docs[DocId(7)]#1`, so
  the world calls a delivered post makes are written under that name.
- **Stripes** are instances too: `made hits[0]#1` at the `with`.
- The header gains `parts:`, each family's name and partition count, a
  replay refusing a program whose counts differ.
- A replay checks each `made`, `evicted` and `posted` line where it
  comes, strictly, as it checks a call, so a replay that evicts
  differently stops there and says so; as a test's schedule prefix, the
  replay follows the recorded order while it can, as version 2's does.
  `chaos:`'s draws are `Random`'s, so a replay gives them back as it
  gives back any `Random.int`.
- **Version 2 is refused** as version 1 is, "`tests/build.journal` is a
  version 2 journal, which this `ren` doesn't read" with "version 3
  names the runtime's instance families and their posts" and the same
  help, record it again (journal.ml's `version_1_said` becomes
  `old_version_said`). examples/just/tests/build.journal is recorded
  again.

**As built (step 7a).** A family's partitions are an `opened` line, `main
opened docs parts 1`, since a family opens after the header is written,
and the header has no `parts:`; teardown writes no `evicted` lines; a
test that replays a journal passes over the family's lines; and the
recorded journals had no family, so only their headers' version changed.

### Native

What's sequential builds natively and agrees with `ren run` (decided
after the draft): the pipe (step 1, a `let` and a call), wirings (step
2, functions that return descriptions, and a `with`), and `release`
with no other task (step 4, a plain call: `arm_release` and
`arm_retake` compile to nothing). `beside`, `background`, `produce`,
`map_pull`, the family, and so `striped` and `actors`, are
interpreter-only, refused by `ren build` at the first call to_mem
meets, `tasks_not_native`'s message for the first four and, for the
family's intrinsics, said at the program's call that reached them,
"`striped` uses the keyed instance family, which isn't native yet" (or
`actors`, or whatever library the program called), each with "help:
run it with `ren run`".

### Errors

Each is a refusal test in test_services.ml (but the three crams of The
tests), with the pass that says it.

The pipe (step 1):

```
error: `validate` can fail, and nothing handles it                   (Infer)
  = in a chain each step that can fail carries its own `try`
  help: write `|> try validate`, or handle it with `match`

error: nothing here can fail                                         (Infer, today's)
  = `try` marks the calls that can fail, so a reader can see where the code can stop
  help: remove the `try`

error: `try` stops at `|>`                                           (Infer)
  = it covers only `order`, which can't fail; each step is marked on its own
  help: `order |> try validate |> try place`

error: `len` is `Array`'s own method, so it's called with `.`        (Infer)
  help: write `(...).len()`, or end the chain with a `let`

error: `|>` puts `rules` first, but `apply` takes an `Order` there   (Infer)
  - `rules` is a `Rules`, which `apply` takes second
  = `|>` always passes its value as the first argument
  help: call it directly: `apply(order, rules)`

error: `|>` passes a value, so nothing in a chain can change it      (parser)
  help: call it with `&` directly: `add(&cart, item)`

error: a step is a function by name, not a block                     (parser)
  help: name it first, `let apply_rules = fn(o) => ...`, then `|> apply_rules`

error: `|>` takes one value on its left                              (parser)
  help: put it in parentheses: `(total + fee) |> round`

error: a chain ends its expression                                   (parser)
  help: put the chain in parentheses, or name it with `let`

error: only the chain's last step can take a block                   (parser)
  help: name the block first, `let f = fn(x) => ...`, and pass it in the parentheses

error: a step is a function by name, and `rules.apply` is a field of `rules`   (Resolve)
  help: name it first: `let apply = rules.apply`, then `|> apply`
```

Wirings (step 2):

```
error: nothing installs `Db`, which `db_users()` in `live` needs     (Infer)
  help: add an item that installs `Db` beside `live`: `with live, mem_db() in`

error: `live` needs `Db`, which it doesn't declare                   (Infer)
  help: add it to `uses`: `uses Db`

error: `live` installs `Db` but doesn't provide it                   (Infer, the solver)
  help: add `Db` to `live`'s `provides`, or install your own inside: `with mem_db() in`

error: this `with` installs `Db` twice: `mem_db()` here, and `pg_db(url)` in `live` (main.ren:2)   (Infer)
  help: use a smaller wiring that leaves `Db` out, or remove one

error: `a` lists itself: a → b → a                                   (Resolve)
  help: a wiring can list another, but not one that lists it

error: `ping()` and `pong()` in `both` each need what the other installs   (Infer, today's with the wiring)
  = `ping()` → `pong()` → `ping()`
  help: install one of them in a `with` around this one

error: `live` provides `Clock`, which nothing in it installs         (Infer)
  help: remove it from `provides`, or add an item that installs it

error: `console_audit()` in `live` provides `Audit`, which nothing needs   (Infer)
  help: remove it, or add `Audit` to `live`'s `provides`

error: a wiring isn't a value                                        (Resolve)
  help: install it: `with live in ...`

error: a wiring says what it provides                                (parser)
  help: write `provides` and the dependencies the body may call

error: a wiring's body lists what it installs                        (parser)
  help: code that runs around a block stays a function: `fn live(body: fn() -> T) -> T`
```

Background work (step 3):

```
error: this task can reach `Ticks`, installed inside the scope it's spawned into   (Excl)
  help: open the scope inside the `with`: `with ticks() in Async.scope fn(s) => ...`, or run it beside the body with `Async.beside`

panic: this task can reach `Ticks`, installed inside the scope it's spawned into   (the interpreter, at the spawn)
  help: open the scope inside the `with`
```

`release`, deadlocks and defaults (step 4):

```
error: `release` lets go of a handler's instance, so it's only written in one of its operations   (Excl)
  help: call it without `release`

error: `release` lets go of the instance for one call of another dependency's operation, and `twice(1)` isn't one   (Infer)
  help: write it on the operation's call: `release Next.get(id)`

error: `r` is changed across a call that lets go of the handler       (Excl)
  = at `release` and `Async.until` other tasks run the handler

panic: every task is waiting, and nothing can wake one               (the interpreter, today's, with what each holds)
  = main/main:0 waits in `Async.until` at test.ren:11:13, holding `A` (a.go)

error: a parameter's default is a literal, or a variant written bare   (parser, today's widened)
  help: give it where it's called instead
```

Pull arguments, channels and producers (step 5):

```
error: `r` is read by this block while the call changes it            (Excl, the `&r` row: a `&` argument's)
  help: read it first: `let at = r.at`, and use `at` in the block

error: `Events.items()` is pulled where it's written: in a `for`, or as a pull argument   (Infer)
  help: loop over it: `for e in Events.items()`
```

Stripes (step 6), none of them a rule written for `striped`:

```
panic: `total` runs on every stripe and gives an `Int`, so `striped` needs `merge:`   (striped's setup, at the `with`)

panic: `merge: Sum` adds what `all` gives, and an `Array<Str>` isn't a number   (striped's setup, at the `with`)

panic: `striped` keeps at least 1 stripe, not 0                      (striped's setup)

error: `Worker` has 0 fields but was given 1                         (Infer, today's)
  help: write `Worker` with no parentheses

error: `m` may be a description of `adding`, which keeps state, so it isn't called as a method   (the data stage's rule)

error: `striped` takes a handler's description, and `16` is an `Int` (Infer: a dependency parameter given a value)

error: `striped` uses the keyed instance family, which isn't native yet   (to_mem)
  help: run it with `ren run`
```

The family and `D.Call` (steps 6 and 7), each the family's or an
ordinary type rule, saying the dependency and operation the program
wrote:

```
error: `Docs.at` inside a block of `Docs.at` could wait for a slot its own block holds   (Infer, a check on `Instances.pin`)
  help: finish with the first, then call the second; or post to it, which holds nothing

error: `doc` is kept by `Docs`'s family, so it can't call `Docs.at`, which pins one of its siblings   (Infer, a check on `Instances.pin`)
  help: post to it instead, which holds nothing

error: `doc` is kept by a family, so its `finally` can't fail        (Infer, the maker's rule)
  help: save in its operations, write-through, or flush before the family ends

error: expected `fn(DocId) -> Doc`, found `fn(DocId, Int) -> Doc`    (Infer, today's)

error: expected `fn(DocId) -> Doc`, found `fn(DocId) -> Doc ! StoreDown`   (Infer, today's)
  = this function can fail with `StoreDown`, and the type wanted here fails only with ...

error: `post` takes a call that gives `()` and can't fail, and `text` gives a `Str`   (Infer, a `D.Call<()>` parameter)
  help: use the value, or handle the error, inside the operation, or make the call directly where its result is wanted

error: `post` takes a call that gives `()` and can't fail, and `edit` can fail with `StoreDown`   (Infer, the same)
  help: use the value, or handle the error, inside the operation, or make the call directly where its result is wanted

error: what a call of `Log` gives and fails with isn't written: `Log.Call` is a call of any of its operations, and `D.Call<R ! E>` is generic code's   (Resolve, step 7b)
  help: build the call where it's posted, and take what it's built from instead

error: `Doc.Call` needs every operation of `Doc` to be data, and `each` takes a block   (Infer, formats.md's)

panic: `Peers` has 5 posts queued, past twice its `mailbox:` of 2    (the family)
  = the high-water mark: 5
  = an instance that posts twice around a cycle grows its family's mail without end

panic: this family ended with the `with` that opened it              (the family)

panic: a task pinning `Outers` would wait for a slot of `Inners`, installed inside it   (the family, a helper's `at`)

error: `tests/build.journal` is a version 2 journal, which this `ren` doesn't read   (`ren replay`)
  = version 3 names the runtime's instance families and their posts
  help: record it again: `ren run --record tests/build.journal main.ren`
```

### What each step changes

- **Step 1:** token.ml (`PIPEGT`), lexer.ml (`lex_token`'s `|>`,
  `continues ()`'s `|>` and `.`), parser.ml (`parse_pipe`,
  `parse_step`, `chain_stops`, the errors), ast.ml (`Pipe`), resolve.ml
  (a step's target, the field error), infer_expr.ml (`infer_pipe`, the
  first argument's message), infer_msg.ml, solve.ml (`try` stops at
  `|>`), lower.ml (a `let` and a call), excl.ml and mut.ml where they
  walk expressions; tree-sitter's grammar.js and scanner.c, the corpus,
  differential.py's cases, Zed's highlights; examples of language.md's
  end-to-end shapes; language.md's "What Ren has today" row, operators.md.
- **Step 2:** parser.ml (`parse_wiring`), ast.ml (`Wiring`,
  `with_item.from`), resolve.ml (the link functions, the flattening, the
  cycle, the value error), iface.ml(i) (`wirings`), infer_handlers.ml
  (`with_`'s origin, the wiring's checks, `install ~hidden`),
  infer_env.ml and solve.ml (`Install.whidden`), infer_top.ml (a
  wiring's scheme), infer_msg.ml, driver.ml and bin/main.ml (`ren
  explain-wiring`, `ren types`' line); tree-sitter, corpus, Zed;
  examples/ledger and examples/server, deps.md's and the README's
  `with_fake_net`.
- **Step 2b:** parser.ml (`parse_service`, `kv.Kv(...)`), ast.ml
  (`Service`), resolve.ml (`service_items`, `installed`,
  `service_named`, a member's calls, the errors), infer_declared.ml and
  infer_msg.ml (a member's `uses`, the handler not reported twice),
  infer_expr.ml (a chain's `Piped` after a member's shared arguments);
  tree-sitter, corpus, Zed; bench/services/service; examples/checkout
  and examples/server without a private function's `uses`; language.md's
  table, the README, deps.md.
- **Step 3:** prelude.ml (`beside`, `background`, `Background`),
  intrinsic.ml, builtins.ml and sched.ml (`task_beside`,
  `task_background`; `beside`, `frame.bg`, `context` and `leave_with`'s
  cancelling removed; the spawn's check), eval.ml (`endings`), excl.ml
  (the compile error), to_mem.ml (refused); examples/refresh, async.md.
- **Step 4:** lexer.ml/parser.ml (`release`; a constructor default; a
  variant's field defaults; an operation's parameter's default), ast.ml (`Release`, `pdefault`),
  resolve.ml, iface.ml (defaults), infer_expr.ml, infer_top.ml
  (`defaults_of` for operations), lower.ml (`release`'s write-back and
  read-again, as `until_released`), intrinsic.ml (`Arm_release`,
  `Arm_retake`), sched.ml (`released` without handing off under `sim`,
  the deadlock panic's holdings), excl.ml (the row narrowed), to_mem.ml
  (both intrinsics to nothing), prelude.ml (`Kill`, `Proc.run`'s
  `kill`, its handlers), std_lib.ml (`sim_proc`, `SimProc.kills`), a C
  stub for the process group, sched.ml's `wait_pid` killing the group;
  a circuit breaker example; the journals that write `Proc.run`.
- **Step 5:** ast.ml/ty.ml (`Pull`), parser.ml (`pull`), infer_expr.ml
  (pull arguments as `for`'s subject; `D.items()`), excl.ml (`&r`'s
  row), lower.ml (the step blocks, `items()`'s block), prelude.ml
  (`map`, `each`, `produce`, `map_pull`, `Send`, `buffer`),
  intrinsic.ml, builtins.ml and sched.ml (`task_produce`,
  `task_map_pull`, `task_map` and `task_each` pulling), to_mem.ml
  (refused); async.md's "Later" line, stdlib.md, the crawler if it
  reads better.
- **Step 6:** lib/eval/family.ml (new: the family, its partitions,
  LRU, queues, deliveries, names), intrinsic.ml, builtins.ml and
  prelude.ml (`Instances`, `real_instances`, `Family`, `Counts`, the
  `family_*` intrinsics and `runtime_of`, Core Lint's check of them),
  eval.ml (`With` of the opener's frame, the family's name;
  `D.call`), sched.ml (`Async.worker()`, `sim`'s two workers drawn at
  spawn; the family's hooks: waits on a partition, the delivery scope);
  parser.ml (the path `D.Call.Case` where `Type.Case` is taken, today
  "expected `,` or `)`, found `{`"), ast.ml, resolve.ml and infer
  (`D.Call<R ! E>`, its cases, members and the all-data rule, refinement in a `match` on one, the `call(c:
  D.Call)` clause and a description's `call` called as a method, the
  maker parameter and its three checks, `pins` per operation and the
  two no-deadlock errors, a dependency parameter `D`); prelude.ml's
  `striped`, `By`, `Fold` in Ren; to_mem.ml (the family refused);
  `keyed` removed everywhere (The inventory); test_tasks.ml's `keyed`
  tests moved.
- **Step 7:** parser.ml and ast.ml (a `dep`'s and an alias's error
  row), Infer (an error row as a dependency's parameter, `fn<T>` in an
  operation), prelude.ml's `Actors`, `Evict` and
  `actors` in Ren; journal.ml (version 3, the family's lines, the
  header's `parts:`), driver.ml (`ren replay`'s version message);
  examples/just's journal recorded again.
- **Step 8:** bench/services/docs moved to examples/docs; bench/tasks.t's
  milestone; THE CHECKS' examples list gains docs.

### Where this stage may differ from foundations.md and language.md

Choices this specification made where the record is silent, or doesn't
fit the code, each to revisit if a step finds it wrong:

- **A wiring is flattened into calls of functions Resolve makes, one per
  link,** since another module's use of a `pub` wiring can't see the
  private names in its items' text. A link that's one of the wiring's
  parameters is passed straight through, as a dependency-typed
  parameter can't be returned as a value.
- **A wiring's arguments are evaluated once, before any item,** bound
  by `let`s around the `with`.
- **A dependency a wiring hides can't be reached by the body at all,**
  not even an outer one of the same name: the body gets a fresh one by
  a nested `with`, which is the help §5 gives.
- **A wiring's `provides` may name what a nested wiring provides, not
  what it hides.**
- **A wiring a test splits is `pub`.** language.md §5's test splits a
  private `core`, but a test sees what an importer sees (testing.md),
  so in a test the split wiring is `pub`, its `uses` written.
- **Two parser errors language.md §8 doesn't list:** a trailing block on
  a step that isn't the last ("decided after the draft" allows one only
  in the last link), and a field of a value as a step (Resolve's, since
  the parser can't tell `o.f` from `m.f`).
- **`try`'s and `attempt`'s stop at `|>` is a parser flag** reset in
  every bracket and body, so `try f(a |> g)` keeps `try` covering the
  whole call.
- **The variant default, a variant's field defaults and an operation's
  parameter's default land in step 4,** not step 0 (What's decided 11
  says step 0): step 0 builds no language, and step 4's
  `Proc.run(kill:)` is the first surface that needs them. An operation
  may have a default because `Proc.run` is one. A field's default is a
  literal only, as a parameter's literal default is.
- **A cancelled `Tree` run is killed by a C stub** that forks, calls
  `setpgid` and `execvp`s, OCaml's `Unix` having no process groups.
- **`SimProc` keeps `killed()` and adds `kills()`,** rather than
  changing `killed()`'s type, which 11a's tests read.
- **`sim`'s fair choice wakes every eligible waiter and queued caller
  and lets the tape pick who runs first;** `single` stays first in
  first out, so `ren run`'s output doesn't change.
- **`release` is a word only before a name on its line,** so the
  operation `Semaphore.release()` and arms named `release` stay.
- *Superseded by step 5's choice, a block parameter `fn() -> Option<T>`:*
  **A pull parameter is a mode, `xs: pull T`,** checked as a `for`'s
  subject; Lower makes every pull argument a step block, so the
  interpreter's `task_map` and `task_each` take one kind of source.
- **`Events.items()` gives a cursor type, `sync.Items<T>`,** whose
  `next` is `Chan.recv()`, reading the alias it was called through;
  step 5 checks that a generic dependency's member function called
  through an alias resolves its `uses` to that alias.
- **`Async.produce`'s producer is `concurrent`,** and its failure reaches
  the body through `items`, after what it sent before failing.
- **`Async.background`'s scope is a `Background`,** a `Scope` whose
  blocks may fail, since a `Scope`'s spawned blocks can't.
- **`Instances`, the family's dependency, is ambient:** the runtime
  installs it around `main` and each test, as the journal's handlers,
  and no `uses` names it, so a library over it adds nothing to its
  callers' signatures. Only privileged code (decision 20's closed list)
  may be ambient.
- **The LRU lives in the family,** as the order of release it exposes
  (`victim`'s list, `evictable()`), since only the runtime sees when an
  instance becomes evictable; the policy that reads it (`Lru`, chaos,
  `evict_idle`) is the library's. `evictable(idle: d)` gives the time
  half, so `actors` needs no `Clock`.
- **A family is a `Family<K, D ! E>` handle kept in its opener's state,**
  (as built `Family<K, (D ! ..e)>`, step 7a)
  a number, not an instance; a call after `close` panics.
- **The family's maker parameter carries three checks** any library
  over it gets (a `finally` that can't fail, the cycle rule's exception
  for posting to siblings, no pinning its own family): the family's
  rules, stated once on `Instances.open`'s `h`.
- **`D.Call`'s variants are its operations' names in upper camel case,**
  and a `match` on one refines its result and error types (a
  constructor fixes them); nothing else in Ren refines.
- **A merge's clause takes the two results after the call,** `call(c:
  D.Call, a, b) => ...`, called by `striped` as a method,
  `m.call(c, a, b)`: the design says the clause folds two results for
  `c` and is silent on how it gets them.
- *Superseded by step 6a's choice, `sum`, `max`, `min`, `concat` and
  `fold`, and `operations(h)`:* **The built-in folds are `D.Call`
  members,** `c.add`, `c.max`, `c.min`
  and `c.concat`, and the install check reads `D.Call.operations`,
  since `striped`'s clause can't name a call's result type: the
  declarations as data, decision 20 rule 3.
- **`merge:`'s default is `Unmerged`,** since a parameter given by name
  has a default (§2) and decision 18 gives no default fold; `striped`'s
  setup refuses it, at the `with`, where a keyless operation gives a
  value. It's a value of std's `Fold`, not a rule in the checker.
- *Superseded for `striped` by step 6b's choice, which writes none:*
  **`striped` and `actors` `release` their own instance** in each arm
  that pins or posts, else every caller would queue on the library's
  one instance; `release` (step 4) is what any library over the family
  writes.
- **`actors` uses `Random` and `striped` uses `Async`,** so a `pub`
  wiring or a function with a written `uses` that installs one names it:
  language.md §11's `live ... uses Net` is `uses Net, Random` as built.
  The alternative, the family drawing chaos's randomness itself, would
  put chaos in the runtime, which What's decided 8 rules out.
- **`post`'s type errors say `post`, not "a post",** and their help is
  general (handle it inside the operation, or call it directly), since
  they're the ordinary rule for any `D.Call<()>` parameter; decision 18's
  "use `at`" is the docs'.
- **`striped`, `actors`, `Actors`, `By`, `Fold` and `Evict` are in the
  prelude,** plain Ren, since language.md writes them bare; `sync` keeps
  its channel, semaphore, `limit` and batcher.
- **`striped(by: Worker)` makes a stripe per worker on its first call,**
  two under `sim`, one under `single`.
- **A family's name in the journal is the dependency its opener is
  installed as, snake_cased** (`Docs` is `docs`, `docs.2` for a second
  family of one opener); the incarnation counts a key's lives from 1.
- **`Docs.each`'s block takes no parameters** (decision 18's `Docs.each(fn()
  => try Doc.flush())`), and the family exposes `count`, `made`,
  `evicted` and `high_water`.
- **A delivery task per key with mail,** named by the actor in the
  journal, research/actors-post/'s model.
- **`Full` is added statically only where the `at` is lexically inside
  another family's `at`;** a helper's `at` gets the run time's rule.
- **A design note for the owner: language.md §11's `expire(now)`.**
  §11 says a keyless operation runs on every stripe, and its `expire(now)`
  sweep is meant to; but `striped` routes by "an operation whose first
  parameter has a `key`", and every value has its derived `key`, so as
  built `expire(now)` goes to one stripe by `now` (step 6b's choice) and
  `hit(...) -> ()` isn't parsed. test_calls.ml's run of §11's lines
  writes `expire()` and `hit(path: Path)`, and says so in its name. A
  per-operation way to say "keyless" (or keying only on a declared key
  type) is the design's to decide.
- **The milestone's stand-ins** (the brief's risk; decided after the
  draft): language.md's `conn.ops()` is a framed reader and
  `text.apply(op)` an editing model, which the formats and strings
  stages own, so examples/docs has the smallest that keep what the
  milestone tests. **A line protocol:** a session's first line names its
  document, each line after it is an edit, `+text`, and `bye` ends it,
  answered `done N` with the document's version; `read_line` keeps what
  it read past a line in the session's buffer, so lines may come in any
  number of `Net.read`s, and the test clients write each line on its
  own, so sessions' edits interleave. **An `Op` that appends a line,**
  `Append(line)`, so the text is its edits in order, which is what the
  tests compare: a subscriber's edits against the store's lines, and
  every two subscribers' against each other. Subscribers are seen
  through a test `Conns`, `seen_conns()`; the real one writes each
  line to its connection.

Chosen in step 1, as built:

- **A link is `Pipe { subject; step }`, `step` the call itself,** `f(_,
  a)`, with a `Piped` for its first argument, inside the step's own `Try`
  or `Attempt`, rather than The AST's `{ subject; step; args; mark;
  block }`: Resolve, Infer and Lower then see a call, checked by the
  call's own path (defaults, by-name arguments, a trailing block, an
  operation's block), and nothing that walks calls needed a case. Infer
  records the subject's type at the `Piped`'s node; Lower makes `let s =
  subject in f(s, a)`, the `Piped` the `s`.
- **A link's marker covers only its link, but a step's `try` still
  passes on to the markers around the chain,** as a `try` inside an
  `attempt` does: `attempt (x |> try f |> g)` keeps `f`'s errors, and
  `attempt (x |> f)` with an unmarked `f` that can fail is refused, and
  so is that `attempt`, which then covers nothing (§8, "`try` on each
  step").
- **An unmarked step's error is the one §8 gives;** its function, if it
  says it fails with the step's errors, also hears it says what nothing in
  it can, as for any unmarked call: the fix, `|> try f`, clears both.
- **A trailing block on the step's line whose body is a chain** took the
  rest of the chain in, as R's pipe did a lambda's: it's "only the chain's
  last step can take a block". A block on lines of its own may hold a
  chain.
- **A step whose first parameter is `inout`** is "`|>` passes a value",
  as `&` is, with the help that calls it directly.
- **The subject swapped with another argument** is §8's message, and the
  argument that then doesn't fit its parameter is reported too, as any
  argument is.
- **A line starting with `.` that ends a chain** (`x |> f` then `.g()`)
  is "a chain ends its expression", as an operator after one is: calling
  a method mid-chain is later (the brief's "Deliberately out").
- **tree-sitter's operands:** an operator's operands, and `try`'s,
  `attempt`'s, `-`'s, `not`'s and `&`'s, are an `_operand`, an
  expression that's neither a chain nor an `orelse`, so `|>` stops `try`
  by the grammar's structure, not a precedence (which can't order `try`
  below `orelse` and above `|>`, with `|>` above `orelse`); `try`'s own
  `orelse` keeps a chain on its right, as the compiler's does. It still
  accepts a head the compiler refuses, `a + b |> f`, as `(a + b) |> f`.
- **No formatter exists yet,** so §8's all-or-nothing formatting has
  nothing to change in this step.
- **Step 0's programs that weren't Ren** were mended to say what they
  meant, their targets unchanged: a block parameter called without `try`
  (`n |> try f`, `try xs.map(f)`), functions declared `! Bad` that
  couldn't fail (`if n < 0 then fail Bad else n`), a statement that threw
  an `Int` away (`let _ = try Orders.save(p)`), and bench/services/pipe's
  `attempt [7]`, which covers nothing (`attempt validate([7])`).

Chosen in step 2, as built:

- **An item's `from` is the list of wirings it came through,** `via
  list`, innermost first, [] for an item a `with` writes, rather than a
  `wired option`; how each link is written, `pg_db(url)`, is recovered
  from the function it was made into (`Resolve.written`, its resolved
  body printed, a nested wiring's link followed to the inner one's), and
  shown wherever inference shows the call, so every message about a
  `with` writes a wiring's items as the wiring does. An interface's
  wiring carries those texts (`Iface.wiring.wwritten`), filled in by the
  driver, as a public group's tests are.
- **A link's function takes only the wiring's parameters it reads,**
  `Iface.Made (f, used)`: a parameter of a dependency's type given to a
  function that doesn't install it would be used as a value. An
  argument that's a local already isn't bound again, since reading a
  local twice is reading it once; the wiring's own function passes its
  parameters on so.
- **The wiring's own function is `live$wiring(url: Str) = try with
  live(url) in ()`,** flattened by the same path as any `with` that
  lists it, its `try` Test_items' `passed_on`, so it needn't cover
  anything. Lower doesn't drop it: nothing calls it, and an uncalled
  function costs nothing.
- **What a `with` flattens is numbered below the lowest node of its
  function** (`Resolve.lowest_node`), since the functions a wiring is
  made into number theirs below zero too.
- **`provides` is enforced at the body's calls that bring the hidden
  dependency in themselves** (`call.own`), not by the body's row: this
  checker relates a `with`'s rows by unification, so the body's row
  holds what the items need as well. A call of a function of the same
  recursive group, whose row isn't known when the call is met, is
  checked once the group's bodies are (step 9, "Step 9, soundness").
- **A problem among the items of one wiring is reported once,** at its
  own `with`, not again where it's listed: a dependency installed twice,
  two items that need each other.
- **A missing need through a wiring** gets §5's message where a runner
  installs the world, `main` and a test; inside a function whose `uses`
  is written it's today's "doesn't declare".
- **New errors §5 doesn't list:** a wiring listed with `over` or `as`
  ("a wiring is installed as its items"), an argument by name ("given in
  order"), the wrong number of arguments, a parameter with a default, a
  wiring and a function of one name, two wirings of one name.
- **`ren types` shows a wiring as its own function's signature,**
  `wiring live(url: Str) provides Users uses Console`, its link
  functions not at all; `ren explain-wiring` says "needs nothing" of an
  item that needs nothing, joins what's met and what's from outside with
  `;`, and adds "fails to start with ..." when the wiring can.
- **language.md's end-to-end `main` is `pub fn main() ! DbDown uses
  Console, Net, Os`** in examples/checkout: a public function writes its
  errors, and `try with live(...)` fails with `DbDown`. Its body, for
  `http.serve(routes)`, is `serve()`, three checkouts printed; `pg.pool`
  is examples/checkout/pg.ren's stand-in, a pool that refuses a URL that
  isn't `pg://` and keeps its tables in memory, needing `Net` as a real
  one would. It uses the real `Net`, which isn't native, so
  examples/checkout left bench/build.t's native loops; bench/services'
  `pipe` and `wiring` build its chain and its wiring natively.
- **examples/server's wiring is its tests',** `pub wiring simulated
  provides Net, SimNet uses Async = sim.net()`: `main` installs nothing
  but built-ins, so the inventory's `live(addr)` would have nothing to
  list. examples/ledger's is `ledger(down: Outage)` (the inventory's
  `mem(fail: FailAt)`: the type is `Outage`).
- **Step 0's programs that weren't Ren, mended:** the `types` test's
  `core` declares `uses Db` but listed `console_audit()`, which needs
  `Console`, so it lists a quiet audit; the cross-module test's `app.ren`
  is `pub_all`, since `main` calls `app.Users`. Their targets are
  unchanged.
- **README's and deps.md's `with_fake_net(body: fn() uses Net)`** show
  where a block's dependencies are found, so they stay, with a note that
  a helper that only installs is better a wiring.

Chosen in step 2b, as built (they sat among the specification's choices
above until step 9):

- **A service's state is its handler's, given to each member as
  parameters** (step 2b (state)): a `var` `inout`, a `let` by value,
  each written with its type or a literal, the state first, as a
  handler's; the state can't call a member. One record of the state
  passed `inout` was the other way, but a record type needs its fields'
  types written all the same, and every member would read `st.n`
  instead of `n`.
- **A service is installed with its parentheses,** `Kv()` when it takes
  nothing, as a handler is; `Kv` alone where a `with` lists it is the
  same call.
- **A member used as a value is refused,** rather than made a closure
  over the shared arguments: §4 says members call each other, and a
  block that calls one says the same.

Chosen in step 3, as built:

- **A task's `context` stays,** though "Background work" says it goes:
  the run time's check needs it, since a task spawned into a scope
  inside the `with` that spawns into one outside it spawns from inside
  the `with` too, and without its spawner's frames that task could
  outlive the handler. `frame.bg` and `leave_with`'s cancelling went;
  `leave_with` only marks the frame over (`Sched.inner`).
- **What a task can reach is counted the same way at compile time and at
  the spawn, and generously:** the dependencies its block calls an
  operation of, those of each function it calls by its *scheme* (not by
  the nodes' types, whose `uses` rows are joined to the rows around
  them, so every call there would look like it reaches everything), a
  `let`-bound block's, a block parameter's given ones (a block passed in
  was written outside, so it reaches nothing installed here but those);
  at the spawn, the closure's Core body and every closure it captured
  (eval.ml, `reaching`; excl.ml, `reach`). A dependency a `with` inside
  the block installs counts too. **`Async` is always reached:** every
  task is run by the runtime installed around it, so a task can't be
  spawned out of a `sim.scheduler`'s `with` (which `Sched.leave`
  relies on, as it relied on 11a's rule).
- **A task outside a `with` that reaches nothing it installs is
  allowed,** and outlives it, the scope waiting for it (test_tasks.ml's
  s9 "outlives it"): 11a cancelled every task spawned outside a `with`
  from its body.
- **The compile error's help writes the `with` as the program does,** its
  items, an alias as `as Names`, a wiring by its name, and the scope's
  opener with its parameter's name, `Async.scope fn(o) =>`; it labels
  the outermost `with` inside the scope that installs what's reached.
  `Async.background`'s body counts as a scope for it.
- **`Background<E>` is a builtin type whose argument is an error set,**
  as `Result`'s second is (infer_top.ml, infer_written.ml), and
  `bg.spawn` is an intrinsic member whose block's errors are that set:
  so `Async.background<T>(body: fn(bg: Background<! ..e>) -> T) -> T !
  ..e` passes them out with no `try` on `bg.spawn`, and its scheme marks
  the block `spawned` for Excl.
- **A background failure cuts the body through a deadline,** pushed when
  the body starts and moved to now by the first failure, so the body
  sees a cancel where a timeout's would (`Sched.background`, `fail`,
  `cut_off`); an infinite deadline sets no timer. The body's own error
  wins over a background task's; a background failure while the body
  returned, or while its tasks were being cancelled, is the call's
  error; any after the first is said on stderr, as a scope's second
  failure is. A background task that hasn't started when the body ends
  never runs, as a cancelled task never does.
- **bench/build.t refuses `beside` and `background` natively** in a cram
  of their own, since `refused` reaches stripes first and waits for step 6.
- **Step 0's programs that weren't Ren, mended:** the pool test's
  `finally(_) => print(...)` gave `()` for the body's value; it's
  `finally(r) => print(...); try r`. Its target is unchanged.
- **test_tasks.ml's 11a tests moved:** s2's ticker is beside its body
  with `Async.background`; the batcher's flusher is `Async.beside`; s9's
  two spawns outside a `with` are the compile error where it's lexical,
  and through helpers the panic at the spawn, by a task's task too; a
  task outside a `with` that reaches nothing in it outliving it is new;
  s1's help names `Async.beside`. stdlib.md and testing.md name no
  background work, so they're unchanged.

Chosen in step 4, as built:

- **`release` covers a call of `D.op(...)` or `next.op(...)`,** an
  operation of a dependency installed outside the handler: `next`'s is
  one. Infer's check is on the resolved callee (`Dep_op`, `Next_op`).
- **Its scheduling point is the operation call's:** under `sim` the
  task switches at `release` only when the instance is locked, shared
  with a spawned task, as a call of one is a point only then; an
  instance no other task can reach has nothing to switch to. So
  `arm_release` and `arm_retake` aren't `Intrinsic.waits`, and a
  function that writes `release` needn't use `Async`: like an
  operation's own queueing, it waits only where a spawned task, which
  needs `Async` somewhere above, can reach the instance.
- **A task keeps the instances it has let go of, `task.let_go`,** for
  `Async.until`'s wait as for `release`'s call: the deadlock panic and
  the cycle panic name what each task holds, which is what it's in and
  hasn't let go of, `holding \`A\` (a.go)`, and `share` doesn't make
  such a task the holder of a lock made meanwhile. Taking one back is
  one function, `Sched.take_back`, for both, uncancellable, as 11a's
  waiter getting its instance back was.
- **`sim`'s fair choice applies only while it isn't following a
  recording,** which runs in `single`'s order, first in first out, so a
  journal replays as it ran.
- **An operation passed as a block, `xs.each(Sink.put)`, holds
  nothing:** it's a plain dependency call where it's called, which the
  narrowed row no longer counts.
- **`kill: Child`** parses as `retry`'s `on: Declined` does, a set of
  tags; given to a parameter that isn't of `Tags`, it's the constructor
  it names (Infer's `with_defaults`).
- **A field's default is only a one-field variant's,** in parentheses,
  `Key(n: Int = 16)`, since a variant with several is by name and
  `parse_field_decl` is a record's too; one in braces is still "expected
  `,` or `}`". Its type is checked where the variant is left without it,
  at a node of its own (`default_node` of the constructor, 0), which
  Lower lowers.
- **A variant written bare as a default takes its sum from the
  parameter's written type** (`Resolve.default_of`), so another module's
  call finds it; one written after another type, `kill: Kill =
  Mode.Tree`, is Resolve's error.
- **An operation's defaults are collected while its type is parsed**
  (`parse_fn_ty_param ~collect`), into `Ast.field.op_defaults`, then
  `Iface.field.fdefaults`, by the operation's path in `defaults_of`; a
  default on a function type's parameter anywhere else is a parse
  error. `Ast.field` and `Iface.field` gain the field's default too.
- **The C stub `execv`s the program `find_program` found,** not
  `execvp`, which would search `PATH` again; an `execv` that fails says
  why through a pipe closed on `exec`, raised as `Unix.create_process`
  would raise it; the child clears the signal mask it inherited, and the
  parent calls `setpgid` too, so a kill right after the start reaches
  the group. A `Tree` program isn't in the terminal's foreground group,
  so one that reads the terminal stops (SIGTTIN): `kill: Child` is for
  an interactive program.
- **examples/just's `slow` recipe is `sleep 5.0; true`,** not `sleep 5;
  true`, so just.t's check that no `sleep` is left, `ps`, can't count a
  `sleep 5` something else on the machine runs.
- **examples/just/tests/build.journal isn't recorded again:** its three
  `Proc.run` lines gain `, Tree`; the justfile it read stays the one it
  read then.
- **Decision 2's row 31 tests** (test_blocks.ml, test_deps.ml) mark
  their call `release`, so they still show the error, which a plain
  call no longer is; step 0's s4 programs that weren't Ren were mended,
  their targets unchanged (`Clock` in `main`'s `uses`, a spawned block
  giving `()`, `fn main` where the refusal is Excl's).
- **The circuit breaker is examples/breaker,** in bench/tasks.t and THE
  CHECKS; bench/services/breaker_held is it without `release`, whose
  "a slow answer doesn't hold up a fast one" a seed fails.
Chosen in step 5, as built (step 4's list held them until step 9):

- **A pull parameter is a block parameter `fn() -> Option<T>`,** not a
  new mode `pull T` (step 5 as specified): streams.md's rule 3 says a
  pull parameter "takes what `for` takes", a block as itself, and its
  `dedup_by(src: fn() -> Option<T>, ...)` is a block parameter that's
  given `&r` and a cursor. So any parameter of that type, a user's as
  `Async.map`'s, takes a collection by snapshot, a temporary cursor, a
  named one as `&r`, or a block (Infer_expr's `pull_param`, `pulls`,
  `pull_arg`); Lower makes the block that pulls it (`pull_block`), and
  no parser, Ty or tree-sitter change was needed. What's passed is
  recorded at a node of its own, `Infer.pulled_node`, since the
  argument's node has what was found of it already.
- **`for x in f` and `for x in try f` over a block `fn() -> Option<T>`**
  call it each time round (Infer_expr's `block_subject`, Lower's
  `block_loop`), as `produce`'s body loops over `items`.
- **A cursor's `next` may use a dependency and fail** (Infer_expr's
  `cursor`): what it uses the loop or the pull uses, and what it fails
  with a `for x in try c` passes on, or the call it's pulled by. `for x
  in try &r` over a named cursor that can fail still isn't parsed as one
  (Excl and Mut see `&r` under the `try` as no loop's): stage 11c's
  readers bring it.
- **A stream given to a block parameter fails with what its function
  does** (`Iface.streams_given`, `Infer_written.streams_given`):
  `body: fn(items: fn() -> Option<T>) -> R`'s `items`, written without
  `!`, has the function's own errors row, as a transparent parameter
  does, so `produce`'s producer's failure reaches the body where it
  pulls, `for p in try items`. Any other function type nested in a
  parameter's still fails with nothing. A call of such a block whose
  errors are its lambda's own is checked last among the unmarked calls
  (solve.ml), so a producer that can't fail gives an `items` that
  can't, and `for x in items` needs no `try`; step 0's s5 tests wrote
  `try items` over producers that can't fail, and `Async.produce(...)`
  unmarked over one that can, which Ren refuses ("nothing here can
  fail", and the call's own `try`), so they were mended.
- **A parameter with a default comes before the blocks given last,** not
  only before one (resolve.ml): `produce(cap: Int = 16, f, body)` and
  `map_pull(src, max: Int = 64, f, body)` are written as the brief
  decided, and their calls' positional arguments still read in order.
- **`Events.items()`, a member function of `Chan<T>` called through an
  alias, runs with the alias's implementation installed as the
  dependency it names** (Resolve's `through`, Infer's `through_alias`,
  Lower's `rebound`): around the call alone, and around each `next` of
  the cursor it makes, a stateless handler whose operations call
  `Events`'s, so nothing else there sees it. Infer counts what it uses
  of `Chan<Int>` as `Events`. Since only a `for` or a pull argument
  where the call is written can do that for `next`, such a cursor is
  pulled where it's written, "`Events.items()` is pulled where it's
  written". `Chan.items()` through the dependency's own name is an
  ordinary cursor, kept like any.
- **`Async.produce`'s buffer and `map_pull`'s results are the
  scheduler's** (sched.ml's `stream` and `mapped`, behind the prelude's
  private `Outbox<T>` and `Inbox<T, E>`, whose `E` is what taking can
  fail with, as `Background<E>`'s is), and `Send<T>` is the prelude's
  `sends(out)` handler over `outbox_send`. A producer's failure isn't
  its background's, which would cancel the body: it ends the stream.
  `map_pull` starts its tasks as there's room, pulling `src` on the
  body's task, a finished result keeping its slot until it's taken.
- **`&r` given to a pull parameter is refused, where the block touches
  `r`, by the error any `&` argument a block reads gets** ("`r` is read
  by this block while the call changes it", its label "changed for the
  whole call"), not a headline of its own: decision 2's row is a `&`
  argument's, held for the call. `&` on a collection given to one is
  "doesn't change this argument", as on any parameter that reads.
- **`Async.map` gives `()` for a task a cleanup deadline cut off,** as it
  did before step 5 (examples/server's cut-off connection).
- **`Send` is in every program's scope,** as the prelude's dependencies
  are, so the list of dependencies in scope that an unknown one's error
  gives has it (four tests' expectations gained it).
- **examples/server pulls its connections with `Async.each` over a
  cursor it declares, `Connections`,** whose `next` is `accept_until`,
  since a cursor's `next` may now use `Net` and fail; streams.md's
  `Net.connections(listener)` replaces it with stage 11c. examples/crawler
  sends its pages through `Async.produce`, as async.md now shows both.

Chosen in step 6a, as built:

- **`Instances` is a dependency with members and no operations,** each
  member a function over one of the family's intrinsics, which only that
  member calls (Core Lint's `world`, by `Prelude.runtime_of`), as
  `Async.scope` reaches the scheduler: a dependency's operations can't be
  generic yet (step 7 brings `fn<T>` in an operation), and one whose
  members reach the runtime needs nothing installed, so no `uses` names
  it and no test can swap it (a handler `for Instances` is refused: it
  has no operations). Only the prelude's source may declare a
  dependency with no operations (the parser), and the list of
  dependencies an unknown one's error gives leaves it out. Built: `open(make,
  parts, cap, mailbox)`, `call(f, k, c)`, `make(f, k)`, `keys`,
  `evictable`, `evict`, `counts` (an `InstanceCounts`: a program's own
  `Counts` is common) and `close`. Not yet, step 7's: `pin` for a block,
  whose `uses D` needs a dependency named by a type variable; `post`, the
  queues, their delivery tasks and the edge's meter; a library's
  `victim` (a full partition waits for room); `visit`; and setup's
  errors as the family's, `! E`: an instance that fails to start panics,
  "an instance of `Hits` failed to start, with `DbDown`".
- **A family's instances are shared from the start** (`Sched.share`), as
  every task that reaches the family reaches them, so an exclusive one's
  operations don't interleave; an operation runs as `Dep_call`'s does
  (eval.ml's `dep_op`, factored out of it), the deadlock panic naming the
  instance by the one rule, `hits[0]#1` (`Family.name_of`). The family is
  named by the dependency the `with` making its opener installs,
  snake_cased (`Family.installing`). The journal's lines for families
  are step 7's, with version 3.
- **`D.Call` takes no type arguments in concrete code:** `Doc.Call` is an
  ordinary sum the compiler writes beside the dependency (Resolve's
  `call_types`), for every module but the prelude, whose operations are
  all data as far as the parser can see (no block, no `&` argument; a
  description or a handle among the arguments isn't caught), a field
  written without a name `_1`. Generic code's `D.Call<R ! E>` is the
  prelude's `Call<D, R, E>`, and the function made of it for a dependency
  has that one's `Doc.Call` in its place (`Ty.known`). So `post`'s
  `D.Call<()>`, a concrete call whose result is in its type, is step 7's,
  which gives the sum its two type arguments, fixed by each case; until
  then nothing unifies a concrete `Doc.Call` with `Call<D, R, E>`, so
  generic code never gets a call whose result it doesn't know.
- **A `D.Call`'s cases are never bare:** a case is named after
  `Doc.Call`, or found where a `Doc.Call` is expected, as a pattern's
  is; so a program's own `Edit` isn't made ambiguous by its
  dependency's.
- **A `call` clause is checked once, its call's result a skolem, `R`,**
  as an arm `over any` is, and copied by Lower for each operation it
  runs for (`clause_ops`). In an arm of a `match` on the clause's call,
  `R` is that case's operation's result (`Types.refined`, which `repr`
  reads while the arm is checked: a link is never shortened to the
  refined type, so nothing outside the arm learns it), and each copy
  drops the arms of other cases, which can't be taken there. Only a
  `match` whose result is wanted, the clause's, refines.
- **A merge's clause, `call(c, a, b)`,** is copied for every operation,
  as the fold `fold op` in its instance's record, which Core Lint checks
  beside the operations; its operations that it doesn't write panic,
  "`longest` folds two results of a call with its `call` clause, so it
  isn't installed to run `Seen.see`". `c.fold(m, a, b)` makes `m`'s
  instance for the fold and calls it. Whether `m` keeps state is checked
  as the fold runs, a panic in the data stage's words, not by
  Stateless: Stateless can't tell `Custom(m)`'s description from
  `striped(h)`'s, both kept descriptions of `D`, and would refuse every
  `striped` over a handler with state.
- **`Call`'s fold members are `sum`, `max`, `min` and `concat`,** not
  `add`, which is `+`'s method and takes one argument; the operations as
  data are the prelude's `operations(h)`, `Operation`'s `gives` writing
  `()` for `()`, since generic code can't name `D.Call`'s members.
- **A handler `for D`,** `D` its type parameter, implements whatever
  dependency a call of it gives it a description of: its type lists the
  dependency `for` of `D` (`Ty.param_path`), which a call makes the one
  dependency of `D` it's given, needing what both need
  (Infer_expr.given_for, recording which variable is `D` for Lower,
  `For_param`); Lower makes `striped$main.Hits` as it makes an `over any`
  handler's function, `D` replaced by an implementation of `Hits` whose
  needs and setup errors are rows of the function's. It writes one arm,
  its `call` clause. A handler's parameters may now have defaults, as a
  function's may.
- **`Async.worker()` draws a task's worker from the tape the first time
  it asks,** not when it's spawned, so a program that never asks draws
  what it drew before and its seeds find what they found.
- **The family is refused natively at the program's call of the
  library that reaches it,** "`striped` uses the keyed instance family,
  which isn't native yet" (to_mem's `reaches_family`).

Chosen in step 6b, as built:

- **`striped` writes no `release`:** its instance keeps no `var` and no
  resource of the program's (its `Family` is the prelude's handle, its
  `h` and `merge` descriptions and data), so it isn't exclusive and its
  callers never queue on it; `release` is for an operation of a
  dependency, and `Instances.call` is a member of one.
- **`by: Worker` makes no stripe until a worker calls,** and a call with
  no key makes the caller's first, so it runs on one at least; under
  `single` that's one stripe, under `sim` two, and the merge erases
  which (or doesn't: the split law's test fails under seed 5671).
- **A key goes to stripe `((h % n) + n) % n`** of its first argument's
  hash `h` (`Call.first_hash`, Walk.fixed_hash, as `keyed` hashed), any
  first argument, whatever its type: the spec's "has a `key`" is read as
  "has a first parameter".
- **`Custom(m)` with state is refused where a fold first runs,** a panic
  in the data stage's words, "`m` may be a description of `adding`,
  which keeps state, so it isn't called as a method", said at the
  program's call that needed the fold, not at the `with` (step 6a's
  reason: Stateless can't tell `m` from `h`).
- **`By` and `Fold`'s cases are found only where one is expected,** as
  `D.Call`'s are (Infer_top's `visible`), so a program's own `Key`, `Max`
  or `Min` constructor, examples have them, isn't made ambiguous by
  them; `striped` writes `By.Worker` where nothing is expected.
- **`striped`'s checks at the `with`** read `operations(h)`: fewer than 1
  stripe under `Key(n)`, a keyless operation that gives a value with
  `Unmerged`, and a fold that doesn't fit what one gives, `Sum` of what
  isn't an `Int` or a `Float`, `Max` or `Min` of what isn't one or a
  `Str`, `Concat` of what isn't an `Array` or a `Str`.
- **A first argument is a key, whatever its type** (this section's
  `first_hash`, "None for an operation with no parameters"), as 11a's
  `keyed` routed; so language.md §11's `expire(now)`, which the prose
  says runs on all sixteen, would go to one stripe by `now`: a keyless
  sweep is written without one (test_calls.ml writes `expire()`). The
  brief's "has a `key`", a type's `key` member, would make `hit(path:
  Path)` keyless, which §11's `Worker` example needs keyed.
- **`sync.keyed` is the ordinary missing member's error,** "`sync` has no
  public `keyed`", not "has no `keyed`": a module's members can't be told
  from its private ones.
- **`hit: fn(path: Path) -> ()`** isn't parsed: a type isn't written
  `()`; test_calls.ml's run of §11's `striped` lines writes `hit: fn(path:
  Path)`.

Chosen in step 7a, as built:

- **`at` and `each` are members of `Actors`, not operations.** An
  operation can't be generic, `at: fn<T>`, and its block can't fail, so
  `try Doc.edit(op)` inside `Docs.at`'s block, language.md's session,
  couldn't be written; a member is a generic function whose block is
  transparent, failing with what `at` does. A member is called through
  the alias as `Events.items()` is (step 5), and runs an operation of
  the family's library, `Actors.enter(k, body)` and `Actors.visit`, whose
  block gives nothing and can't fail: `at` carries its block's value
  and error out of it with `family_kept`, an intrinsic (an `attempt` of
  its transparent block, which it then passes on with `try`, which a
  public function may not write itself), which any library may call
  since step 9. `actors` implements the operations: `enter`, `visit`, `keys`,
  `evict`, `evict_idle`, `count`, `made`, `evicted`, `high_water`. So a
  family of a fake handler is still `actors(fake_doc) as Docs`; a
  handler of `Actors` written by hand implements those nine.
- **`E` is `D`'s: `Actors<K, D>` takes two type arguments,** and the
  alias's `! E` is what making the last one fails with: `dep Docs =
  Actors<DocId, Doc> ! StoreDown` is `Actors<DocId, (Doc ! StoreDown)>`,
  a description of `Doc` that fails to start so (the parser). Generic
  code names a description's setup errors by `(D ! ..e)`, `D` a type
  parameter (Resolve; Unify's rule: it unifies with a description of
  one dependency, `D` being that one and `..e` what it fails with), so
  `Instances.pin(f: Family<K, (D ! ..e)>, ...) -> T ! ..e`. An alias's
  description argument needs what the `with` that installs it has
  (Unify.aliased gives it a fresh needs row each time), and through the
  alias a member sees its errors open, so `at` fails with the block's
  errors besides: sound since a description's errors are only ever what
  something fails with. A setup that fails with more than the alias says
  is "`doc`'s setup can fail with `StoreDown`, which `Docs` doesn't
  declare", at the `with`, not the spec's function-type message.
- **`uses D`, `D` a type parameter,** is the label of `Ty.param_path` with
  `D` its payload, which is the dependency `D` is a description of once
  that's known (Types.repr_row, Ty.known_label), and `(D ! ..e)`'s is
  `D`'s. Evidence finds a dependency's type argument that's a
  description by the dependencies it's of (Ty.key_ty: Core.describe,
  Core Lint, the specializer and eval.ml's `key_of`).
- **A handler's maker:** a handler's parameter may be a block only if
  it's `spawned`, `actors(h: spawned fn(k: K) -> D)`, and every call
  gives it a function's or a handler's name, which captures nothing
  (Infer_top.check_blocks; "a handler keeps the block it's given here,
  so it's given a function's name"). A handler given a maker needs what
  the descriptions it makes need (Infer_expr.kept_needs), since the
  family makes them with the evidence where it's installed: `actors`
  writes its maker as `fn(k: K) => h(k)` in its setup, so it captures
  that evidence.
- **`actors` uses `Random`, not `Async`:** the family's members wait as
  an operation of the handler that opened the family does, whose
  instance is installed outside each call that reaches them, so they
  name no `Async` and aren't among Intrinsic.waits (decided after the
  draft: the family is ambient). A family handle returned from an
  operation and pinned in a function with an empty row would be a wait
  no row shows: the known hole, as 11a's block parameter passed on to an
  operation is. `striped` still uses `Async`, for `Async.worker()`.
- **Partitions:** `parts: Int = 4`, but as many as keep 64 actors each,
  at least 1: `max(1, min(parts, max / 64))`, each with `max / n`, so a
  small family is one partition with an exact LRU (the tests' `max: 2`
  evicts the least recently released). Recorded in the journal.
- **The no-deadlock checks** (Infer_expr.pinning): a call pins for a
  block if it's a dependency's member whose block is given a dependency
  a type variable names (`Actors.at`, `each`), or an operation whose arm,
  in the module, calls `Instances.pin`, `visit`, `enter` or one of
  those (Infer_top.pinning_ops, found before the bodies are checked).
  Inside a block one pins, a pin of the same family (by the dependency
  it's called through) is refused; of another, its errors gain `Full`
  where they can (a member's; an operation's closed errors can't, and
  it panics instead) and Lower tells the family around the call
  (`family_full`). At run time `pin` panics for a task already pinning
  one of the family's, and where waiting for room in a family installed
  inside one the task pins (opened after it) isn't marked, "a task
  pinning `Outers` would wait for a slot of `Inners`, installed inside
  it". An actor whose arms pin its own family is refused at the `with`
  that keeps it; naming its own family in `uses` is still the `with`
  set's error until step 7b allows it for `post`.
- **`finally` can't fail** is a check where a handler of the module is
  given to a maker: a `try` in its `finally` of anything but the body's
  result it's given, or a `fail` (Infer_top.failing_finally). One of
  another module's that fails panics where the family runs it.
- **A cancelled setup:** its waiters try again; a setup that fails
  fails each waiter with its error; the next `at` makes it again.
- **Journal version 3:** a family's lines are `main opened docs parts
  1`, `main made docs[DocId(1)]#1` and `main/main:0 evicted
  docs[DocId(1)]#1`, each by the task that did it: `parts` is an `opened`
  line, since a family opens after the header is written. A replay
  checks each where it comes; a test that replays a journal passes over
  them. Teardown writes no `evicted` lines. Version 1 and 2 journals are
  refused with "record it again" (Journal.Old_version).
- **Recorded journals:** examples/just/tests/build.journal and the crams'
  journals have no family, so recording them again changes only the
  header's version, which was changed by hand; bench/11a's v1.expected
  says version 3.
- **A bug fixed:** Resolve's calls through an alias were keyed by node
  alone, which is numbered within a function, so a call in another
  function with the same node ran through the alias (`sim.scheduler(1)`
  in `main`, after `Docs.at` in `go`): now by node and place.
- **Families are named by what's installed:** eval.ml's `With` now
  calls `Family.installing`, which step 6a wrote but nothing called, so
  `striped`'s families were all `family`.
- **Test programs mended:** step 0's s7 programs that weren't Ren were
  mended, their targets unchanged: a handler's `finally` gives back the
  body's result (`finally(r) => ...; try r`), a block doesn't end in a
  `let`, `import` goes first, `Instances.open`'s arguments are
  positional, the third library's `at` gives an `Int` so its block needs
  only `Count`, no `release` on a member, `Full`'s test nests its two
  `with`s so `Outers` is outside `Inners`, and the `at`-making test
  prints the `with`'s body before the family's end.

Chosen in step 7b, as built:

- **A call's type carries which operations it may be a call of,** not R
  and E as type arguments: the checker gives a concrete `Doc.Call` a row
  of its cases after the dependency's own type arguments
  (Types.calls), as OCaml types a polymorphic variant. A case built is
  its own name and possibly more, open; `Doc.Call` written, or read from
  an interface, is every case, closed; and generic code's `Call<D, R, !
  E>`, once [D] is a description of `Doc`, unifies with a `Doc.Call`
  closing its row to the cases whose operations give R and fail with at
  most E (Unify's `known_call`). So a value built as `Put` is a
  `Doc.Call<()>` where one is wanted, `if b then Put {..} else Line {..}`
  is a call of either and isn't, and two calls of different cases still
  compare with `==` (test_calls.ml's), which a GADT's R would refuse. A
  call given to `post` is, from then on, one of the cases `post` takes,
  as unifying rows makes it (a type variable's row could otherwise gain
  a case after the post was checked), so it isn't compared with a call
  of another case after. The
  row is erased where the checker hands a type on (`canon_ty`), so
  lowering, Core Lint and the interpreter see `Doc.Call` as declared,
  and `Call<D, R, E>` with [D] known is `Doc.Call` there as before
  (Ty.known). An operation's parameter of generic code's `Call<D, R, !
  E>`, `Actors.send`'s, is read without that erasure where a call
  through an alias is checked (`Iface.dep_fields ~calls:false`), else an
  alias's operation would take any call.
- **`Doc.Call<R ! E>` isn't written of a dependency's own calls:** it's
  refused, "what a call of `Log` gives and fails with isn't written",
  with help to build the call where it's posted. A function's interface,
  which other modules see it through, keeps only `Doc.Call` (the row is
  the checker's), so a parameter written `Log.Call<Unit>` would let an
  importer pass any call to a body checked as taking only some. Generic
  code writes `D.Call<R>` and `D.Call<R, ! E>` (Resolve passes them on
  as `Call<D, R, ! E>`), and a function whose parameter's type isn't
  written, `fn g(c) uses Logs = Logs.post(k, c)`, is checked at its
  callers in its module; a `pub` one writes its types, so it's `Log.Call`
  and can't post what it's given.
- **The refusal is a type rule on any parameter of `D.Call<R ! E>`:**
  where an argument may be a call of an operation that gives something
  else or can fail with more, "`post` takes a call that gives `()` and
  can't fail, and `line` gives a `Str`" (or "`edit` can fail with
  `StoreDown`"), naming the function as it's called (Infer_expr's
  `call_arg`): `Counts.send` in a third library says it the same way.
- **`post` is a member of `Actors`,** over the operation `send(k, c) ->
  Pinned<D>`, as `at` is over `enter`: what it fails with is setup's,
  the alias's `E`, which an operation's type can't name (step 7a);
  `Instances.post(f, k, c, victim) ->
  Pinned<D>` keeps what making the instance failed with, for `made`.
  The member's parameter is `Call<(D ! ..e), Unit, !>`, the description
  its `uses` names, so it unifies with `send`'s.
- **A task's posts and its calls of one actor come in the order it made
  them** (Family.ordered): an operation called from outside the family,
  through `at`, waits first until what its task posted to that key has
  been delivered, as an Erlang process's cast and call to another go
  through its one mailbox. The spec says a task's posts run in order and
  is silent on a post and a later `at`; without this, `post` then `at`
  on one task would read the actor before its mail, which every s7
  test's target assumes it doesn't. It can wait for nothing a slot
  holds (deliveries never wait for one) and for no lock its own task
  holds but through a delivered operation calling back into something
  the poster is in, which `sim` reports as every task waiting.
- **The edge** (Family.edge, `metered`): a call from outside waits while
  the family's mail is at `mailbox:` (full), so it adds at most one
  call; an operation called through `at` is metered in eval.ml's
  `dep_op` before it takes its instance, by the instance's number
  (Family.owners). A sibling is a task that's one of the family's
  deliveries or is in an operation of one of its instances; its posts
  never wait, and one that makes the mail more than twice `mailbox:`
  panics, "`Peers` has 5 posts queued, past twice its `mailbox:` of 2",
  with "the high-water mark: 5" and the cycle's note, said where it
  posted, in its delivery's task.
- **A delivery task per key with mail,** in a scope of the family's own
  (Sched.owned, never a task's body's), named by its instance by the one
  rule, `peers[Key(2)]#1`, in the `with`s the opener was in; it takes
  each call off the queue as it starts it (mail counts what's queued,
  not what's running), pins the instance for that one operation, and
  ends when the queue is empty. A post's making goes past the cap only
  when nothing is evictable or the library's `victim` gives none
  (`pin ~over`).
- **Siblings name their family:** an item's needs that come only from
  the makers it's given (Infer_expr.kept_needs records them by the call,
  and by the function it's in, for a wiring's link) aren't its own where
  it's installed as one of them, `actors(peer) as Peers` for a `peer`
  that uses `Peers`, and the family adds the opener's own install to its
  maker's evidence once the `with` has made it (Family.installed_as),
  which `open` captured before it existed.
- **The high-water mark is reported by `ren test`,** under each test that
  posted, the most over its seeds: "`Docs`'s high-water mark: 4 posts
  queued at once"; a program reads it with `high_water()`. There's no
  native family, so no debug build reports one.
- **Journal:** `posted` lines, on the posting task, to a key, not a life:
  `posted peers[Key(2)] Ping { left: 2 }`; a delivery's lines are under
  its instance's name, which the journal reads as a task's path, a key
  in brackets that may hold a space in a string (Journal.task_word). A
  key and a call are written as the journal writes a value, so a
  string key is quoted, `logs["a b"]#1`: 7a showed it as `show` does.
- **Test programs mended,** their targets unchanged: the teardown
  test's `finally` gives back the body's result; the two refusals of a
  post call it from a function, not a `main` that uses what nothing
  installs; and the order test's actors write through to a `Kept`
  handler, since its `max: 1` evicts key 1's actor once its mail is
  delivered (the second task's `at` needs the slot), which loses what
  it kept in memory, as it should; it runs under 1000 seeds.
- **Found, not fixed (step 8's first; fixed there):** a wiring item `actors(peer) as
  Peers` is refused, "`live` provides `Peers`, which nothing in it
  installs" and "`actors(peer)` in `live` provides `Actors`, which
  nothing needs": a wiring's checks don't see an item's `as` alias of a
  generic dependency. It's so on main before this step (7a's), and
  examples/docs puts its actors behind a wiring, as s8's test does.
  Where it's fixed, a sibling's need through a wiring's link is already
  met (`kept_in`).

Chosen in step 8, as built:

- **A wiring provides an item by its alias** (step 7b's finding, fixed):
  `actors(doc) as Docs` installs the dependency `Actors`, which lowering's
  `With` needs, but a wiring's `provides`, its "nothing in it installs"
  and "which nothing needs" checks, and its body's hidden dependencies
  name it by its alias, `Docs`, the name the program gives it
  (infer_handlers.ml's `provided_as`). An alias written as the
  dependency itself, `as Chan<Int>`, names `Chan`, as before.
- **examples/docs's wirings split the way §5's "Tests" says:**
  `documents(max, chaos)` is the family, `actors(doc, max: max, chaos:
  chaos) as Docs`, over a `Store` and a `Conns` from outside; `live(dir)`
  is the server's, a store of files, `fs_store(dir)`, the network's
  `net_conns()` and `documents(50_000, false)`, `uses Net, Fs, Random`
  (language.md's `live(url)` is a `pg_store`, which Ren doesn't have;
  `Random` is `actors`', "Where this stage may differ"). The tests list
  `documents(2, true)` beside `sim.net()`, `mem_store()` and
  `seen_conns()`.
- **A session's edits run in its one `Docs.at` block,** and it leaves
  however they end: language.md's `finally(_) => Doc.leave(conn.id)`
  inside a block isn't Ren as built, so the block keeps the edits'
  outcome with `attempt`, leaves, then passes it on with `try`.
- **The variants are the whole server** with the one change each, so
  each fails for the reason the milestone names and no other:
  services/memory's `doc` doesn't save (and has a `text()` the tests
  read through `Docs.at`), its calm test `documents(4, false)`;
  services/lost_update's `Doc` has `text()` and `set(text, line)`, and a
  session's `append` reads with one and writes with the other;
  fixed.ren is examples/docs' server with lost_update's test. Every
  variant's family has `chaos: true` but the calm test's, so fixed.ren's
  thousand seeds hold under chaos too. They stay in bench/services,
  since their tests are meant to fail.
- **What the seeds found** (recorded for the stage's report): the lost
  update fails at `ren test --sim --seeds 200`'s first seed, 4702 (its
  test's own), `left: 3`, `right: 4`, and `--seed 4702` fails the same;
  of the seeds 1 to 100 run one by one, 63 lose an edit. The in-memory
  document fails under chaos at its first seed, 9904, `left: ""`, which
  `--seed 9904` repeats; 93 of the seeds 1 to 100 lose it. examples/docs'
  `ren test --seeds 1000` takes about 10 s of wall clock here (9.7 s;
  each of its four tests under a thousand seeds).
- **No test of examples/docs posts,** so `ren test` prints no
  high-water mark there: language.md's server calls its actors through
  `at` alone.

Step 9, docs and tooling (the review's third lens):

- **The documents say what's built.** async.md: its status, its surface
  (`release`, `Async.worker()`, `striped`, `actors`), rule 3 and "What
  changed" with `release`, a paragraph on `release` under "Shared state
  is a handler", the deadlock panic's holdings, `Async.until`'s waiter
  chosen by `single` in order or by `sim` fairly, `actors` beside
  `striped`, `Proc.run`'s process group, `sim`'s fair choice and two
  workers, chaos and high-water marks, journal names, examples/breaker
  and examples/docs, and actors' open items under "Later" (its
  background section and its "Later" line on streams were right after
  steps 3 and 5). stdlib.md: its status, a table of what's built
  (`Async`'s producers and `worker`, `release`, `Proc.run(kill:)`,
  `sync`'s `items()`, `striped`, `actors`, `Instances`, `D.Call`) and a
  roadmap row. testing.md: its status, `sim`'s fair choice, `release` as
  a scheduling point, two virtual workers, chaos through `actors(doc,
  chaos: true)`, high-water marks, journal version 3, a roadmap row.
  handlers.md's journal section said version 2 under a version 3
  header: now version 3, its `Proc.run` line with `Tree`, the family's
  lines, versions 1 and 2 refused. errors.md: "Errors that come from
  elsewhere" (`try release`, a background failure, a producer's through
  `items`, setup's through `Actors<K, D> ! E`, `post`'s, `Full`, a
  `finally` that can't fail). The README: the status's stage list,
  `release`, `Proc.run(kill:)`, actors, `post` and the milestone; the
  roadmap's services row done; rule 3 with `release`. language.md's
  table: the patterns stage's row (it said "none"), `Instances`' and
  `actors`' members, `try Doc.edit(op)` inside `at`. operators.md was
  right.
- **This section:** an "As built" note at the end of each part whose
  specification the build departed from (The AST, background work,
  `release`, the family, `D.Call`, stripes, actors, journal version 3),
  each pointing at its step's "Chosen" list; the superseded choices of
  "Where this stage may differ" marked; step 5's choices under a heading
  of their own (they sat under step 4's), and step 2b's moved there from
  the specification's list; the design note on §11's `expire(now)`; the
  progress log's step 8 hash, the macOS fix's row, and the blank line
  that split the table removed. test_calls.ml's run of §11's `striped`
  lines is named for what it changes, not "as written".
- **Examples' READMEs:** examples/breaker and examples/docs have one,
  as the others do; examples/checkout's was right.
- **Tooling:** differential.py read only bench/services' top level, so
  the milestone's variants (`lost_update`, `memory`, `breaker_held`)
  weren't compared; it reads every folder now (1999 programs, 0 the
  compiler parses that the grammar doesn't). The corpus gains
  `Background<! ..e>`, `beside`, `background` and `produce` with `for p
  in try items` (tasks.txt), and generic code's `Call<(D ! ..e), Unit,
  !>`, `D.Call<Int, ! Bad>`, `uses D` and `Docs.post(...)` (calls.txt);
  every other form had a case (pipe.txt: `|>` and `.` continuation
  lines; wiring.txt; service.txt, state included; release.txt, variant,
  field and operation defaults; calls.txt, `Doc.Call.Case { .. }` and
  the clauses; actors.txt, the alias's `! E` and a maker). The
  highlight test asserts `release`. Zed's `extension.toml` named a
  commit from before the pipe, so Zed built a grammar without any of
  this stage's forms: it names 4b150c4 now; its README's outline line
  names services and wirings.
- **Left:** foundations.md decision 18's `try Docs.at(id) fn() =>
  Doc.edit(op)` (low: Ren only where `edit` can't fail; with §11's
  `edit ... ! StoreDown` the block writes `try Doc.edit(op)`, as
  examples/docs does), not edited, foundations.md being design.

### Step 9, soundness

The review's soundness lens (the brief's step 9): adversarial programs
for each area, each run through `ren run`, `ren run --release`, `ren
test --seeds`, and `ren build` where it's sequential, with Core Lint on.
What they found, by area; each fix has its regression in
test/test_services_review.ml (`[s9 ...]`) unless it says otherwise.

**Found and fixed:**

- **`with live, live` crashed the compiler** (high: an internal error
  in Lower, "a `with` inference didn't say the order of"). Two listings
  of one wiring were taken for one wiring's items, whose problems are
  reported at its own `with` and so nowhere. Infer_handlers' `one_wiring`
  now also asks that the two items come from one listing (their `iloc`,
  which is the listing's): it's "installs `Db` twice", as `wiring two =
  live, live` already was.
- **`provides` through a call of the same recursive group** (medium,
  step 2's known gap): `fn f() = with live in g()`, `g` in `f`'s group
  using the `Db` that `live` hides, ran with the hidden `Db`. A body's
  call of a function of the group being checked is kept
  (`env.hidden_calls`), and once every body of the group is checked,
  Infer_top's `check_hidden_calls` finds what each function of the
  group brings in, its calls' own labels and those of the group's
  functions it calls, to a fixed point, and reports the first such call
  whose callee brings the hidden label in, with the message a direct
  call gets. It counts calls inside a `with` that installs the label
  too, so it's at most what the function does: sound, and a program
  whose group function doesn't use what's hidden is still accepted (a
  test of each).
- **Two lives of one key at once** (high): `at` or `post` on a key
  whose instance's `finally` was running (being evicted on another
  task) made the key's next life beside it, so a setup that loads what
  that `finally` writes read it stale, and decision 18's one instance
  per key didn't hold. family.ml's `pin` now waits for that `finally`
  to end (`dying`, the instance's `waiting`, woken by `evict_now`), and
  a `finally` that asks for its own key, posting to itself, panics,
  since it would wait for itself. The dead branch `Some { state =
  Evicting }` in `pin`, which would have spun, is now a bug report.
- **A family's handle could leave its handler** (medium): an operation
  `handle: fn() -> Family<K, D>` gave it out, and a function with no
  `uses` could then `Instances.evict` through it, running an instance's
  `finally` (a print) where no effect was declared, or call it after
  the family ended (a panic). Resolve's `no_kept_blocks` now refuses a
  `Family<...>` written in a dependency's operation, a dependency's type
  argument (`dep X = Chan<Family<...>>`, or one in a `uses`) and a
  handler's parameter, "a family's handle is good only in the state of
  the handler that opened it". Inside the handler it's data as before:
  its state, its helpers' parameters, `let`s.
- **std had powers a user library lacked** (medium, decision 20 rule 2;
  the spec review's finding): `Actors.at` carried its block's value and
  error out with `family_kept` and `striped` refused with `lib_panic`,
  both `Internal`. Both are `Any` now (prelude.ml's `caller`), so a
  library calls them as the prelude does; step 7's third library in
  test_services.ml is back to its first intent, a generic `Shards<D>`
  whose `at` gives what its block gives, a `Str`, and fails with what it
  fails with, through `family_kept`, `Instances.enter` and
  `Instances.made`. Ren still has no `panic` of its own: `lib_panic` is
  a library's way to refuse what it can't go on from.
- **Chaos ran only at the library's own operations** (medium; the spec
  review's): `actors(chaos: true)` shook at `enter`, `visit`, `keys`,
  `evict`, `evict_idle` and `send`, not at an operation called through
  `at`'s block, which decision 18 counts as a call into the family. A
  new `Instances.at_edge(f, each)` (`family_edge`) keeps a block the
  family runs at each call from outside into one of its instances, at
  the edge's meter (`Family.metered`), before the call takes the
  instance; `actors` gives it its `shake` when `chaos` is on. Policy
  stays the library's: the family runs a block, and knows nothing of
  chaos. examples/docs' thousand seeds still pass, in 10.2 s (was 9.7
  s); bench/services/memory still fails under chaos at seed 9904, `left:
  ""`, 93 of the seeds 1 to 100; lost_update at 4702.
- **A wiring's errors named its function** (low; the spec review's): "`fn
  live$wiring` says it can fail with ..." is "`wiring live` says ..."
  (Infer_msg's `fn_named`).
- **A program of actors was refused natively at the real `Random`**
  (low; the spec review's), since `$start` installs the world before the
  program's call of `actors` is compiled: to_mem.ml's
  `first_family_call` says the program's first call of a library that
  reaches the family first.

**Probed and sound** (no change): a wiring diamond and a wiring listed
beside its own item (installed twice, said); a cycle across two
wirings and through three (said); an alias through two and three
nested wirings, and one hidden by the outer (said); an item a wiring
provides using what it hides (allowed: items meet each other); a
service's member calling its own operation, returning a block over its
state, or spawning tasks that write it (each refused); `try` inside a
bracket around a chain, `try` then `orelse`, `..r` and `|>` and `.`
lines inside brackets, a `|>` line at the statement's own indent
(parsed as written; natively the same); a helper handed the inner scope
or the background, a task in a scope handing `bg` on, `beside`'s task
spawning into an outer scope (refused statically, or a panic at the
spawn); a background task spawning more, and a scope inside one (stop
with the body); `release` in `until`'s condition (refused), `total +=
release Next.get(id)` (reads again after), nested `release`, `release`
on a task spawned inside an arm (holds nothing, lets go of nothing);
`produce` with a producer failing while the body sleeps, a `break` at
`cap`, a body failing while the producer is blocked, a body that never
pulls, two senders, and `produce` inside a producer (300 seeds each);
`Concat` over stripes hit in either order (stripe order, not arrival);
eviction during setup (the evicting caller waits); a full family
reached from an actor (`at` in `at` of one family, a panic); teardown
draining a chain of posts that evicts as it goes, under chaos (300
seeds).

**Left, by severity:**

- **Low:** a world call inside an operation called through `at` is
  journaled under the calling task's path; only a delivery's are named
  `docs[DocId(7)]#3` (the spec review's). Naming them by the instance
  would change how replay matches a call to its task, and every
  recorded journal: later, with the journal's next version.
- **Low:** `with a, b` where `a`'s item and `b`'s need each other says
  "`ping()` and `pong()` in `a`", though `pong()` is `b`'s.
- **Low:** the help of "`outer` installs `Docs` but doesn't provide it"
  writes `with actors(doc) in`, without the item's `as Docs`.
- **Low:** the help of the inner-scope error inside `Async.beside`'s
  task suggests `Async.beside` again.
- **Low:** natively, a third library over the family is refused at "a
  value of type `Pinned<...>`", not by the family's message, since its
  own code calls `Instances`' members.
- **Low:** a `finally` that posts to its own key panics rather than
  queueing for the key's next life; decision 18 doesn't say which.

### Step 10: structured actors

concurrency.md (the owner's afed5a1) rewrites what steps 7a and 7b
built: there's no mail inside a family, a post waits for room in its
key's mailbox and only there, an `at` block holds its family, and a
`with` drains when its body returns and cancels when it's cancelled
(rules 2 to 4; research/structured-actors/MODEL.md checks them, and
AUDIT.md lists what they touch). This section's earlier records are as
they were built; where they say the edge's meter, a sibling's post, the
panic past twice `mailbox:`, the high-water mark, `Full` or a post's
making past `max:`, this step took them out. Step 10 is two halves:
10a, the owner's items 1 to 4, rules 2 to 4 (below); 10b, items 5 to 8.

**As built in 10a:**

- **No mail inside a family.** family.ml's sibling path (`sibling`,
  `edge`, the family's `mail` count and its `edge` waiters), the panic
  past twice `mailbox:` (`Overflow`), the high-water mark (`high`,
  `highs`, `Actors.high_water()`, `InstanceCounts.high_water`, and `ren
  test`'s line under each test) are gone, and so is the opener's own
  install in its maker's evidence (`installed_as`, the runner's
  `sibling`) and Infer's exception for it (`kept_own`, `kept_in`): an
  actor that names its own family in `uses` needs what nothing outside
  its `with` installs, which is the `with` set's ordinary error,
  "nothing installs `Docs` before `main`", with "installing this needs
  `Docs`" at the item (Infer's install order counts what an item
  installs as met, so it's this error, not "need each other"). So is
  `kept_pins_own`, "`doc` is kept by `Docs`'s family, so it can't call
  `Docs.at`", which that error covers.
- **A post waits for room in its key's mailbox, and only there**
  (`Family.post`): it makes its actor first, as `at` does, waiting for a
  slot when the family is full and nothing's evictable (no more `pin
  ~over`: delivery past `max:` is gone, since a key with mail always has
  a live actor), then, holding it, waits while the key's mailbox holds
  `mailbox` calls, woken as its delivery takes one off, or as the
  delivery ends (a waiter then looks again, and starts another).
  `mailbox:` is per key, `actors`' default 64; `Instances.open`'s
  `mailbox` means the same. An operation called through `at` isn't
  metered any more: `Family.metered` is `Family.entering`, which keeps a
  task's posts before its own later calls of the actor (7b's
  `ordered`) and the library's `at_edge`, `actors`' chaos, both skipped
  for the family's own deliveries.
- **A posted operation can't fail** is 7b's type rule on `post`'s
  parameter, unchanged; its help now names both ways out where it's a
  family's post, "handle it inside the operation, or call it with
  `Docs.at`" (or "use its value inside the operation, ..."), through
  the alias it's called by (Infer_expr's `post_at`). A third library's
  `send` keeps the general help. The post makes its actor, so setup's
  errors are the post's, as in 7b.
- **Rule 3, statically** (Infer_expr's `pinning`, Infer_top's
  `pinning_ops`): a call that pins for a block (`Docs.at`, `each`, an
  operation whose arm pins, `Counts.at`) or posts (`Docs.post`, an
  operation whose arm posts, `Counts.send`), inside a block one pins,
  is refused when its family is the block's or installed inside it, as
  far as the `with`s in sight tell (`env.in_sight`, what the `with`s
  around the code in its own function install, innermost first, pushed
  by Infer_handlers' `install` in install order): of two installed in
  the function, the nearer is inside; one installed in it is inside one
  its callers installed; of two its callers installed nothing's known,
  which the run time checks. `at` in `at` of one family keeps its
  message (help: "finish with the first, then call the second"); the
  rest is "`Inners.at` inside a block of `Outers.at` reaches `Inners`,
  installed inside `Outers`", or "`Docs.post` inside a block of
  `Docs.at` reaches the family its block holds", with the note "a block
  of `Outers.at` holds `Outers` until it ends: inside it, only families
  installed outside `Outers` can be reached, so every wait points
  outward". Handler arms get no new check: an actor's `uses` resolve
  outside its family.
- **Rule 3 at run time** (`Family.held`), where a helper hid it: the
  machinery of 7a's `at` in `at`, the families a task pins for a block
  and their open order (`num`), now checked at every pin for a block
  and every post, whether or not it would wait, a panic said at the
  program's call: "`Docs` is posted to inside a block that pins one of
  its instances, ...", "a block that pins one of `Outers`'s instances
  posts to `Inners`, installed inside it, ...". It replaces the pin
  rule: `Full`, its marking (`Infer.Full_marked`, Lower's
  `family_full` around a marked call, the `Family_full` intrinsic,
  `Family.marked`) and "a task pinning `Outers` would wait for a slot
  of `Inners`" are gone.
- **Drain and cancel** (`Family.close`): a `with` whose body returns
  drains as before, then runs the `finally`s, given `Ok(())`. The drain
  isn't shielded by the `finally` it runs in: it sees a cancel as the
  `with`'s body did (`Sched.shielded_at` the depth in `finally`s the
  family was opened at, `shield`), so a `with` inside `Async.timeout`
  is a drain with a limit. A cancelled `with`, or a drain cancelled
  meanwhile, drops every key's queued mail, cancels the delivery tasks
  (their operations stop at their next dependency call) and waits for
  them, runs the `finally`s with `Err(Cancelled)` (the runner's
  `finish ~cancelled`, which takes their `try r` going on cancelled as
  their end), and then goes on cancelled. A striped family's `with`
  ends the same way: its stripes' `finally`s see `Err(Cancelled)` when
  it's cancelled, as any handler's do.

**Chosen in step 10a** (where concurrency.md is silent):

- **Rule 3's run-time check covers pins for a block and posts, not a
  call of one operation** (`Instances.call`, `make`, `striped`'s): the
  owner's list says `at` and `post`, and a stripe never waits for a
  slot (all are made at the `with`). A block of `Docs.at` that calls an
  operation of a plain handler, or a stripe, installed inside `Docs`,
  whose arm `at`s `Docs` on another task, can still wait in a cycle (a
  slot one way, the instance's lock the other); `sim` reports it as
  every task waiting, as 11a's deadlocks are. The design's "a plain
  handler is a family with one instance" would refuse it; that's a
  wider rule than this step's, left for the owner.
- **The `finally` that asks for its own key** (step 9's panic) is kept
  as a backstop no program reaches: an instance's `finally` can reach
  only families installed outside its own.
- **`Instances.at_edge` keeps its name**, the block run at each call
  into an instance through a block, `actors`' chaos; "edge" no longer
  names a meter.
- **"The cycle in one `with` set"** for an actor naming its own family
  is the existing "nothing installs `Docs` before `main`", as it was
  before 7b allowed it, not a new message.
- **Tests that changed with the design:** the high-water test is gone
  (the design, not a weaker test); s7's sibling posts are refusals (an
  actor naming its own family, the chain reaction, a post from inside
  `at` to its own family) or rewritten across two families (posts past
  `mailbox:` beside an outside poster, the session that posts outward,
  the replay with posts); `Full`'s test is rule 3's refusal; step 9's
  "a key whose `finally` is running" now shows the post evicting 2 to
  make 1 again, since a post's making waits for room; step 9's
  `finally` posting to its own key is the `with` set's error. New, in
  test/test_structured_actors.ml (`[s10 ...]`): a slow key holds up
  only its own posters, a post's making waits for a slot, rule 3
  statically and through a helper (by `at` and by `post`, to the family
  and to one installed inside it), a cancelled `with` dropping queued
  mail, a drain under `Async.timeout`, and a drain that ends with `Ok`.
- **Measured:** examples/docs' thousand seeds take 9.8 s (10.2 s at
  step 9); bench/services/lost_update's seed is still 4702, memory's
  9904.

### Progress log

| step | commit | done | left |
|---|---|---|---|
| 0 | 7a624b2 | this section: each step's grammar, AST, passes, files, errors, the family's representation, journal version 3, the native line, the choices where the design is silent; the inventory (`keyed` 36 sites, the background rule 23, `Async.map`'s `Array` 9, `Proc.run` 48 with journals and docs, the examples to move to wirings, counted); test/test_services.ml, every test of a feature behind `until "sN"`, a refusal test for each error, the two that hold already written plainly; bench/services' programs (`pipe`, `wiring` and its `explain`, `release`, `refused` and its native line) in bench/build.t, and the milestone (`docs`, `lost_update`, `memory`) in bench/tasks.t, all `not yet` | steps 1 to 9 |
| 1 | 5f9409d | the pipe through the whole pipeline: `PIPEGT`, `\|>` and `.` continuing a line (lexer.ml's `continues ()`, tree-sitter's scanner), `parse_pipe` and `parse_step` with `try` stopping at `\|>` (`parse_expr ~chain:false`), `Pipe`/`Piped` (ast.ml), Resolve's field-of-a-value error, `infer_pipe` (each link's own markers, a step's `try` passing on to the chain's, the first argument's message, a method of the subject's own type, `try` stopping at `\|>` in the solver), Lower's `let`, every §8 error and the two of "Where this stage may differ" as refusal tests (test_services.ml's s1, all on); natively, bench/services/pipe in the `same`, `release` and `tcc_same` loops; tree-sitter's `pipe_expression`, `pipe_step` and `step_path`, the corpus (pipe.txt), the highlights, differential.py over bench/services too; examples/checkout, language.md's end-to-end program but its wiring, with tests, natively in build.t; operators.md, errors.md, language.md's table, the README | steps 2 to 9; examples/checkout's `with` becomes `live`'s wiring in step 2 |
| 0 (decision 20) | 0ce9d61 | re-specified after decision 20 (0bc2d5b, f02e66a): the decisions table renumbered to the brief's eleven; the keyed instance family, a runtime primitive in lib/eval/family.ml reached through the prelude's ambient `Instances` (its intrinsics Core Lint checks), its soundness and no-deadlock rules, the LRU as its order of release, names by one rule; `D.Call<R ! E>` with its clause and members, formats.md's all-data rule, `post` spelled `Docs.post(k, Doc.Call.Edit { op })` (383f921: no trailing call); `striped` and `actors` as plain Ren over them, `by: Key(n: 16) \| Worker`, `Fold`, a missing `merge:` a panic at the `with`, `chaos: true` with `Random`; `Async.worker()`; field defaults; `items()` an ordinary `sync` function; Errors, the step files and "Where this stage may differ" (`Merge<D>`, `ren test --chaos` and the Infer rules for `striped` and `actors` gone); s4's variant-default tests, s6, s7 and s8 rewritten to the new API, still behind `until`; bench/services/refused, docs and memory and bench/tasks.t's milestone without `--chaos` | steps 1 to 9; the choices above flagged for steps 6 and 7 (the merge clause's two results, `D.Call`'s fold members, `actors` using `Random`) |
| 2 | 7b18441 | wirings through the whole pipeline: `wiring` and `provides` as words (`parse_wiring`), `Wiring` and `with_item.from` (ast.ml); Resolve's shapes (`wiring_fns`: a function per link, `live$1`, one per wiring for its own `with`, the cycle), the flattening where a `with` lists one (`wiring_ref`, `use_wiring`), "a wiring isn't a value"; `Iface.wiring`, a `pub` one's link functions in the interface (driver.ml); inference's `with_` naming wirings in its errors, `provides` enforced at the body, the wiring's own checks (`wiring_checks`), a `pub` wiring's `uses` and `!` declared; every §5 error and the step's own as refusal tests (test_services.ml's s2, all on); `ren types`' line, `ren explain-wiring`; natively, bench/services/wiring in the `same`, `release` and `tcc_same` loops, `wiring.explain`; tree-sitter's `wiring_definition`, the corpus (wiring.txt), highlights, Zed's outline; examples/checkout's `live` as language.md writes it, examples/ledger's `ledger(down)`, examples/server's `simulated`; language.md's table, the README, deps.md | steps 3 to 9; the review's adversarial wirings (step 9), `provides` through a call of the same recursive group |
| 3 | d5f31e2 | background work: decision 7's compile error in excl.ml (`inner_spawn`, `reach`, the `with`s and scopes walked), the run time's check at the spawn (`Sched.inner`, eval.ml's `reaching`, a panic), `Async.beside` and `Async.background` with `Background<! E>` and `bg.spawn` (prelude.ml, intrinsic.ml; sched.ml's `background`, `fail`, `stop_background`, `cut_off`; eval.ml's `Task_beside`, `Task_background`, `Background_spawn`), refused natively (to_mem.ml, bench/build.t); 11a's rule removed (`frame.bg`, `leave_with`'s cancelling); test_services.ml's s3 all on; test_tasks.ml's tests of the old rule moved; examples/refresh and async.md's flusher, batcher and refresher on `Async.beside`; async.md's background section, its surface and its Effect row; language.md's table, the README | steps 4 to 9; the review's adversarial background programs (step 9) |
| 4 | bb005eb | `release` through the whole pipeline: the word in `parse_unary`, `Release` (ast.ml), Infer's check and Excl's (outside an operation), Lower's write-back, `arm_release`, the call in a `Finally` with `arm_retake` and the reads again (`Lower.released`), `Sched.let_go`, `retake`, `take_back`, natively nothing (bench/services/release in the loops); decision 2's row narrowed in excl.ml (`Lets_go`: `release` and `Async.until`, and block parameters' calls); the deadlock and cycle panics naming what each task holds (`waits_of`); `sim`'s fair choice in `released`; defaults that are variants written bare, a one-field variant's field default, an operation's parameters' defaults; `Kill`, `Proc.run(kill:)`, lib/eval/ren_spawn.c, the group killed, `SimProc.kills()`; examples/breaker and bench/services/breaker_held (bench/tasks.t); the journals' `Proc.run` lines; tree-sitter's `release_expression`, defaults, corpus (release.txt), highlights; test_services.ml's s4 all on; language.md's table, deps.md, testing.md | steps 5 to 9; the review's `release` programs (state read across it, `release` inside `until`'s condition) |
| 2b | 827ff7e | `service`, a dependency and its one implementation written once (language.md §4), through the whole pipeline: `parse_service` (`service` a word before a capitalized name) and `kv.Kv(...)` in the parser, `Service` (ast.ml); Resolve's `service_items`, exactly a `dep`, a handler named as the service is and a private function per member, `Kv.get`, taking the service's parameters first, its `uses` the service's; a member's calls of another, the shared parameters passed on, recursion and chains included (infer_expr.ml's `Piped` after them); `installed`, `service_named` and the three errors of the brief with help, and a member passed as a value, a member's `Kv.get(...)`, an operation's untyped parameter, no `pub fn`, state among members; a member's need past the service's `uses` reported once, at the member (infer_declared.ml, infer_msg.ml's `service_undeclared`); test/test_service.ml's s2b (a test installs a service and replaces it with a test handler; a service in a wiring; another module's; the `uses` bound pinned); natively, bench/services/service in the `same`, `release` and `tcc_same` loops; tree-sitter's `service_definition` and the module's constructor, the corpus (service.txt), the highlights and Zed's outline; examples/checkout and examples/server without a private function's `uses` (no example moved to `service`: checkout's `Orders` and `Discounts` are ports, the ledger's `Sql` keeps state and has `transaction()` over it, the server's `Line` keeps a `finally`); language.md's table, the README, deps.md. Built in parallel with step 3, from 84ac5d3 | a service's state (`var`s among the members: "Where this stage may differ"); steps 3 to 9 |
| 2b (state) | 81a56a1 | a service's state (language.md §4, rule 4): `let`, `var` and `finally` lines first (`parse_service`, `sstate`), the handler's state as written, failing with the service's `! E`; each member given the state after the parameters, a `var` `inout` and a `let` by value (`service_items`, `passes`), an arm passing `&n`, a member passing its own on; the state's type written or a literal's; a state that calls a member, a state taken apart and a state after a function refused with help; test_service.ml's state tests (a `var` counter and a list changed by members calling each other recursively, setup failing under `try with`, a test handler in its place, a block calling a member); natively bench/services/service's `Kv` with state and a `finally`; tree-sitter's `state` and `finally` in a service (service.txt); language.md's table, deps.md | steps 5 to 9 |
| 5 | 1f11d2c | pull arguments: a parameter `fn() -> Option<T>` takes what `for` takes (Infer_expr's `pull_param`, `pulls`, `pull_arg`; Lower's `pull_block`, at `Infer.pulled_node`), `Async.map` and `Async.each` over one, pulled on the caller's task only when a slot frees (eval.ml's `all_of` asks for each call as there's room, `Sched.room`), `&r` a write held for the call (excl.ml, as any `&`); `for x in [try] f` over a block (`block_subject`, `block_loop`); a cursor's `next` that uses a dependency or fails (`cursor`, `next_call` at `Infer.next_node`); `Chan<T>`'s `items()` and `Items<T>` in std_lib.ml's `sync`, a member function through an alias resolved (Resolve's `alias_of`, `through`) and run with the alias's implementation (Infer's `through_alias`, Lower's `rebound`), "is pulled where it's written"; `Send<T>`, `Async.produce` and `Async.map_pull` in the prelude over `task_produce`, `task_map_pull`, `outbox_send` and `inbox_take` (sched.ml's streams, eval.ml), a stream given to a block failing with its function's errors (`streams_given`), unmarked calls of those last (solve.ml), defaults before the blocks given last; refused natively (to_mem.ml, bench/build.t); test_services.ml's s5 all on, with a test of each under `--seeds 1000`; examples/crawler on `Async.produce`, examples/server on `Async.each` over its connections; async.md (surface, table, server, crawler, "Later"), stdlib.md, language.md's table, the README | steps 6 to 9; the review's `produce` programs (a producer failing while the body is blocked, a body that breaks at `cap`); `for x in try &r` over a named cursor that can fail |
| 6a | 261287d | the runtime half: lib/eval/family.ml, the keyed instance family (partitions, pins, the order of release, lives, names by the one rule, eviction with its `finally` on the evicting task, teardown in reverse creation order), reached through the prelude's `Instances` (`open`, `call`, `make`, `keys`, `evictable`, `evict`, `counts`, `close`) over `family_*` intrinsics that Core Lint lets only its members call (`Prelude.runtime_of`); `D.Call` for every dependency whose operations are all data (Resolve's `call_types`, `Doc.Call.Edit { op }` three-part paths in the parser and tree-sitter, `X.Call` as a type, "`Docs.Call` needs every operation of `Docs` to be data"); the `call(c)` clause and a merge's `call(c, a, b)`, checked once with a refined skolem result (`Types.refined`, Infer_handlers.call_clause) and copied per operation (Lower's `clause_ops`); handlers `for D`, made per dependency (`For_param`, Lower's `for_call`); generic code's `Call<D, R, E>` and its members `first_hash`, `sum`, `max`, `min`, `concat`, `fold`, and `operations(h)`; handler parameters with defaults; `Async.worker()` (sched.ml); the family refused natively (to_mem.ml); test/test_calls.ml; language.md's table | step 6b: `striped` in Ren, `sync.keyed` removed; step 7: `pin`, `post`, queues, the meter, setup's errors, `victim`, journal version 3, `D.Call<R ! E>` |
| 6b | 04d0347 | `striped` in the prelude, plain Ren over the family's `Instances`, `Async.worker()` and `Call`'s members: `By` (`Key(n: Int = 16)`, `Worker`), `Fold<D>` (`Unmerged`, `Sum`, `Max`, `Min`, `Concat`, `Custom(m)`), its checks at the `with` reading `operations(h)`, a keyless call on every stripe folded left to right; `sync.keyed` removed with `Sync_keyed`, `VKeyed`, `VKeys` and their sites, its tests moved to test_services.ml as `striped`'s; test_services.ml's s6 all on, the split law failing under seed 5671; language.md §11's `striped` lines run (test_calls.ml); bench/services/refused as specified, natively refused; async.md, deps.md, handlers.md, language.md's table, the README | step 7: `actors`, `pin`, `post`, journal version 3; the review's stripes program (a merge whose result depends on stripe order) |
| 7a | 07434ed | `actors` in the prelude, plain Ren over the family: `Actors<K, D>` with `at` and `each` as members over the operations `enter`, `visit`, `keys`, `evict`, `evict_idle`, `count`, `made`, `evicted`, `high_water`; `actors(h: spawned fn(k: K) -> D, max, mailbox, evict: Lru, chaos, parts)`; the alias's `! E`; the family's `pin` for a block with a library's `victim`, `visit`, `enter`/`made`, `idle`, setup's errors as the family's, waiters sharing them, a cancelled setup retried; the no-deadlock rules static and at run time, `Full`; `finally` can't fail; partitions; chaos; journal version 3 (`opened`, `made`, `evicted`), replayed; test_services.ml's s7 tests but `post`'s on, test/test_actors.ml; tree-sitter's alias errors (corpus actors.txt); language.md's table | step 7b: `post`, the per-key queues and their delivery tasks, the edge's meter and high-water mark, a sibling's post and an actor naming its own family, teardown draining, research/actors-post/'s counterexamples; s7's `post` tests |
| 7b | e8c9e02 | `post`: `Actors.post(k, c)` over the operation `send` and `Instances.post` (`family_post`), its parameter generic code's `Call<D, (), !>`; a concrete call's type carrying which operations it may be a call of (Types.calls; Unify's `known_call`; `D.Call<R ! E>` written in generic code; refused of a dependency's own), the refusal "`post` takes a call that gives `()` and can't fail, and ..." for any such parameter; the family's per-key queues, delivery tasks in a scope of its own named by their instance, a post making its actor past the cap when none is evictable, mail keeping an instance from eviction, the edge's meter for posts and for operations through `at`, a task's posts before its own later calls of the actor, a sibling's post never waiting and panicking past twice `mailbox:` with the high-water mark, the family's end draining before the `finally`s; an actor naming its own family in `uses` (Infer's `kept_own`, the opener's install in its maker's evidence); journal `posted` lines, keys written as journal values, delivery tasks' names read back; `ren test`'s high-water mark; test_services.ml's s7 `post` tests on, with the high-water mark, a replay of a run with posts, and a third library that posts; language.md's table | step 8; a wiring that lists `actors(...) as Docs` (7a's, below) |
| 4 (macOS) | 9eb2e07 | `Proc.run`'s C stub builds on macOS: lib/eval/ren_spawn.c's close-on-exec pipe made with `pipe` and `fcntl` where there's no `pipe2` (Linux keeps `pipe2`) | none |
| 8 | 4b150c4 | the milestone: a wiring provides an item by its alias, `actors(doc) as Docs` (infer_handlers.ml's `provided_as`, 7b's finding), with tests; examples/docs (moved from bench/services/docs), language.md §11's document server behind wirings, `documents(max, chaos)` and `live(dir)`, over a line protocol and an `Op` that appends, a store of files and one in memory, sessions over `sim.net()` that interleave, tests that every subscriber sees one order, that the store holds the final text, that a session off the protocol fails alone, and that the documents outlive the server; its tests under `documents(2, true)`, chaos, pass `ren test --seeds 1000` (about 10 s); bench/services/memory and lost_update (and fixed.ren) as the whole server with one change each; bench/tasks.t's `services_milestone` holds; test_services.ml's s8 on, with two wiring tests; step 3's and 7b's "Chosen" lists moved here from Stage 11a's section, where they'd landed; language.md's table | step 9, the review |
| 9 (docs and tooling) | e9a5b44 | the docs and tooling lens ("Step 9, docs and tooling", above): async.md, stdlib.md, testing.md, handlers.md's journal, errors.md, the README, language.md's table; this section's "As built" notes, superseded choices marked, step 5's and 2b's "Chosen" lists, the `expire(now)` note, the progress log; examples/breaker's and examples/docs' READMEs; differential.py over bench/services' folders, corpus cases for background work, producers and generic calls, `release`'s highlight, Zed's `rev`; test_calls.ml's §11 test named for what it changes | foundations.md's `Doc.edit` in `at` (low, design) |
| 9 (soundness) | 6df76e0 | the soundness lens: adversarial programs for wirings, services, the pipe, background work, `release`, `produce`, stripes and actors ("Step 9, soundness"); fixed: `with live, live`'s internal error, `provides` through a call of the same recursive group, two lives of one key while a `finally` runs, a family's handle leaving its handler, `family_kept` and `lib_panic` open to any library (the third library's `at` generic again), chaos at operations through `at` (`Instances.at_edge`), a wiring's errors naming its function, actors refused natively at `actors`; test/test_services_review.ml | the low items in "Step 9, soundness"; the spec and docs lenses |
| 10a | 35b978d | structured actors, rules 2 to 4 ("Step 10: structured actors"): no mail inside a family (the sibling path, the edge's meter, the panic past twice `mailbox:`, the high-water mark and its `ren test` line, `Full` and the pin rule, delivery past `max:` gone; an actor naming its own family is the `with` set's error); `mailbox:` per key, default 64, every post waiting for room in its key's mailbox and only there; the post's refusal naming `Docs.at`; rule 3 on `at` blocks, by Infer where the `with`s are in sight and by the family at run time; a cancelled `with` cancelling what runs, dropping queued mail and giving the `finally`s `Err(Cancelled)`, and a drain that isn't shielded; test_services.ml's s7 sibling tests refusals or across two families, the high-water test gone; test/test_structured_actors.ml; testing.md, stdlib.md | step 10b: the owner's items 5 to 8, and AUDIT.md's rows left for it; the low item in "Chosen in step 10a" (a plain handler or stripe installed inside a family, reached from its `at` block) |

## Patterns stage

List patterns and string patterns, and a string `match` lowered to a
perfect hash: language.md, "List patterns and string patterns", its
five rules; research/perfect-hash/synthesis.md, "Staging", items 1 and
2; foundations.md, Staging, item 7b, part one (briefs/stage-patterns.md).
Six steps, each green on its own:

0. **This specification,** the keyword baseline and the tests.
1. **The front end and the interpreter:** string literal patterns and
   sequence patterns parsed, resolved, typed and checked (exhaust.ml),
   run by `ren run`; the grammar and Zed.
2. **Natively, as chains:** the decision DAG, each literal a length
   test and `memcmp`, prefix and suffix tests, `..name` a slice.
3. **The perfect hash:** lib/native/phash.ml, the compares and the
   page check in ren_rt.h, the fuzz.
4. **`keys.index(s)` on a constant, and using it:** examples/just.
5. **A review.**

The interpreter matches directly, with no hash: it's the meaning
(decision 20, rule 4). Every build agrees with it on which arm runs,
what each name binds, every error and panic, and `keys.index`'s
result; bench/patterns.t checks that in every build.

### Decided

Recorded from the brief; not reopened here.

- **Prefix and suffix patterns ship with literals** (synthesis, owner
  decision 1).
- **The page check, never padding** (decision 2).
- **`keys.index(s)` on a build-time constant lowers to the hash**
  (decision 3, option a), here only for an array literal of string
  literals, in release builds (see `keys.index(s)`, below, on why not a
  top-level `let`).
- **A decision DAG with join points,** not a backtracking automaton
  (decision 4).
- **No case folding in the language** (decision 5).
- **`[..init, last]` stays** (decision 6).
- **One rest per pattern,** no `Bytes` patterns, no regex.
- **A covered arm is an error;** Ren has no warnings.

### The tests

test/test_patterns.ml is the specification in the interpreter, with
`until "p1"` ... `until "p4"` as test_data.ml's `until "sN"`
(helpers.ml): a test still to land holds its target, `~want` for a
program that runs or `~says` for an error's headline and help, and its
`[%expect]` holds today's output after `(until pN)`. The step that lands
it writes it plainly. bench/patterns.t runs bench/patterns/'s programs:
each through `ren run` against its `.expected` ("as specified" or "not
yet"), and, once step 2 lands them, natively: debug with Perceus's and
the naive counting, release, each under AddressSanitizer and UBSan,
tcc, and `ren run --release`, all printing what `ren run` prints with
no object alive at the end. Step 3 adds the fuzz (test/test_phash.ml)
and step 4 `keys.index`.

What they cover: every form on `Array` and `Str`; nested in tuples,
records, constructors, or-patterns and `as`; slices bound and used
after the subject is gone; `..` beside multi-byte characters; each
error below; exhaustiveness and covered arms, accepted and refused;
guards falling through past literals to prefix arms and `_`; `""` as a
key and as a subject; keys of 1, 16, 17 and 255 bytes; 128 and 200 arms;
and the research's adversarial sets, which the generator can't hash.

### The grammar

```
pattern   ::= ... | STRING | str_seq | "[" [ elems ] "]"
str_seq   ::= piece* rest piece*          (at least one piece)
            | piece piece+                (adjacent literals: one literal)
piece     ::= STRING                      (no holes)
rest      ::= ".." [ IDENT ]
elems     ::= elem ("," elem)* [","]
elem      ::= pattern | rest              (one rest at most)
```

- **A `Str` sequence has no brackets:** `"Bearer " ..token`, `..stem
  ".json"`, `"<" ..inner ">"`, `"--" ..`. Its pieces are string
  literals, juxtaposed; two literals side by side are one, `"a" "b"` is
  `"ab"`. The parser reads one when a pattern starts with a string or
  `..` and a string or `..` follows.
- **An `Array` sequence is in brackets:** `[]`, `[p, q]`, `[first,
  ..rest]`, `[..init, last]`, `[a, .., z]`. An element can be any
  pattern, a `Str` sequence too: `["v" ..ver, ..]`. `"a" ..x` inside
  brackets with no comma is one element.
- `..` inside a record pattern's braces keeps its meaning, the fields
  left out; inside a constructor's parentheses it stays an error.
- A string with holes, `"a\{x}"`, isn't a pattern.

### The AST

ast.ml's `pattern_kind` gains two constructors:

- `PStr of string`, a string literal, `"GET"`;
- `PSeq of ('b, 't) seq`, where `seq = { front : pattern list; middle :
  'b rest option; back : pattern list; bracketed : bool }` and `'b rest
  = { rname : 'b option; rloc : Loc.t }`: the pieces before the rest,
  the rest (`..name` binds, `..` ignores, none is a fixed length) and
  the pieces after. `bracketed` says which: an `Array` sequence, or a
  `Str` one, whose pieces are each a `PStr` and which always has a rest
  (a `Str` sequence without one is a literal, merged by the parser into
  a `PStr`).

Core's `pattern_kind` gains three, which Lower makes of those:

- `PStr of string`;
- `PStr_rest of { prefix : string; rest : var option; suffix : string }`:
  the literal pieces before and after concatenated;
- `PArray of { front : pattern list; rest : rest; back : pattern list }`,
  `rest = No_rest | Rest of var option`.

`..name` binds the middle through the slice operation that exists
today: in the interpreter `Builtins.slice_value v k (len - m)`; natively
the `Slice` runtime call of `x[k..len - m]`, so it costs what a slice
costs and gets bytes part two's representation with it. On `Str` the
cuts are at the ends of valid UTF-8 pieces matched in place, so they
fall on character boundaries and binding never checks or panics; the
native build binds through the unchecked cut (`Slice` with the check
proved, as `split_once`'s halves are), the interpreter through the
same function, which finds the boundary at once.

### Typing

- `PStr` is a `Str`. A `Str` sequence is a `Str`, and its rest is a
  `Str`.
- An `Array` sequence of element type `T` is `Array<T>`, each element
  pattern a `T`, its rest an `Array<T>`.
- **A `Bytes` subject with a string pattern** is an error (below), not
  a mismatch: no `Bytes` patterns (rule 1).
- An or-pattern's alternatives bind the same names at the same types,
  today's rule, now reached by `..name` too.

### Coverage

exhaust.ml's spaces gain two shapes, and its constructors one owner.

**Arrays: lengths are constructors** (rustc's slice-pattern
splitting). At a column whose patterns are array sequences, let `L` be
the larger of the longest fixed length plus one and the largest `P +
S`, where `P` and `S` are the most pieces any pattern with a rest has
in front and at the back. The column's constructors are `[n]` for each
`n < L`, with `n` fields, and `[L..]`, with `P + S` fields: the first
`P` elements and the last `S`, which don't overlap since a value of it
has at least `L >= P + S`. A pattern of fixed length `n` is `[n]`; one
with a rest, `f` in front and `b` at the back, is the or-pattern of
`[n]` for each `f + b <= n < L`, its middle elements wild, and of
`[L..]`, its `f` front pieces then `P - f` wilds, `S - b` wilds then its
`b` back pieces. Those constructors are complete, so `[]`, `[_]` and
`[_, _, ..]` cover every array (`L = 2`, `[0]`, `[1]`, `[2..]`), and a
missing one prints as `[_, _]` or `[_, _, ..]`. `L` is computed at each
column from its rows and the vector being tested, and the expansion is
done there, so the rest of Maranget's algorithm is unchanged.

**Strings: an infinite family.** A `Str` pattern is a constructor of a
type with too many values to list, as an `Int` is, so the family is
never complete: a string `match` needs `_` or a binding, and the
missing arm prints as `_`. A literal `w` is the string pattern `(w, w,
exact)`; a sequence is `(prefix, suffix, at least |prefix| + |suffix|)`.

**One string pattern covers another** (rule 5) when its prefix is a
prefix of the other's, its suffix a suffix of the other's, and its
minimum length no longer; a literal covers only itself. So `"a" ..`
covers `"ab"` and `"ab" ..`, `"a" ..x "a"` doesn't cover `"a"` (minimum
2 against 1), and `.. "s"` covers `"is"`. Specializing a string column
by a pattern keeps the rows whose pattern covers it, and the wild ones;
the rest drop out. An arm with nothing useful left is "this arm can
never match", today's error, so a covered arm is an error. This is
pairwise on purpose: a union of string patterns never covers a pattern
none of them covers alone, which is true of literals and of prefixes
over an infinite alphabet, and what rule 5 says.

**Why looking up every literal of a column first is first match.** At
a node of the DAG with a string column, the lowering hashes the subject
into the set of the column's literals before testing any prefix arm.
Say the subject is `w`, a literal of arm `j`. Every arm `i` before `j`
that can match `w` is still tested before `j`: the branch for `w` holds,
in order, exactly the arms whose column pattern matches `w`, which the
compiler decides at build time by checking each prefix and suffix
pattern against `w`. So the hash never skips an arm, guarded or not; it
only removes tests whose answer is known. If `w` is no literal, the
literal arms can't match and the default branch holds the others, in
order. Rule 5 is what makes this the fast case: an unguarded arm before
`j` that matches `w` would cover `j` (a literal's only string is `w`), so
in a program that compiles every arm before `j` in `w`'s branch is
guarded, and almost always there are none.

### The DAG

Native `match` (to_mem.ml's `match_`) is a decision DAG over the
subject's columns: one, or a tuple's parts written in the `match`.

- **Tag switch:** the tag of a sum, today's.
- **Hash lookup:** a string column with two literals or more: the
  subject looked up in their set once, then a switch on the literal's
  number, a jump table.
- **Prefix test, suffix test:** a length test and a fixed compare each.
- **Length test:** an array's length against its pattern's pieces,
  `==` without a rest, `>=` with one.
- **Element and field tests:** today's, an element read from an array
  at its index from the front or the back.
- **Guard:** an arm's `if`, falling through on false to the rest of
  that branch's arms.
- **Join point:** each arm's body is a join, `Joins`, emitted once
  however many branches reach it.

A switch's branch keeps the arms that can match it, in order, decided
at build time, and knows what the switch decided, so that test is
never emitted again in it; below the switch a branch tests its arms'
patterns in order, each a chain of the tests above. `--emit-c` shows
each lookup as a call of its `ren_ph<N>`, whose comment numbers its
keys, and the `switch` on the number it gives, a `case` for each.

**What isn't built** (Progress log, step 2): the switch is on one
subject, a sum's tag or a string's literals, not on a tuple's columns
one after another, and an array's length is tested per arm, not
switched on; so this is Maranget's tree at its first column, with the
rest of each branch a chain, not the whole tree. Every arm's body is
shared, but a test below the switch is emitted once in each branch that
needs it.

### The generator

lib/native/phash.ml is research/perfect-hash/verify/fuzz/gen_fixed.ml
ported, with the six emitter fixes:

1. the value table is sized by the arm count (`int8_t`, `int16_t`,
   `int32_t`);
2. the length table by the longest key (`uint8_t` up to 254, else
   `uint16_t`, else `uint32_t`), its empty-slot sentinel one more than
   any length;
3. a "last byte" position with `""` a key is guarded, `n > 0 ? A[s[n -
   1]] : 0`;
4. the key table is at least 16 bytes wide, `{""}` too;
5. sanitizer builds compare with `memcmp`, so no `no_sanitize` is
   needed;
6. the `""` slot answers on the length test alone, with no load.

**The budget:** up to 4 byte positions (the best single one; `{0,
last}`; pairs and triples of the best 12; then greedily), table sizes
from `next_pow2(n)` doubling to `min(512, 8 * next_pow2(n))`, values
below `max(32, M)`. That bounds the work at about `positions × tables ×
values × n` steps, milliseconds for 200 keys, and needs no clock. With
no hash within it, the generator tries **the 64-bit mix**: the first 8
bytes and the last 8 (zero-padded) xored with the length, multiplied by
each of 16 fixed odd constants, the top bits a slot in a table of
`next_pow2(n)` doubled up to `8 * next_pow2(n)`. With none of those, the
lookup is a **length switch** and, within a length, compares one key
after another (`memcmp`), rustc's shape.

**Its output** is static const C data beside the lookup function: the
position tables `uint8_t A<i>[256]`, `len[M]`, `val[M]`, the keys as
`uint8_t key[M][W]` aligned to 16, and the two-word form's `w0[M]` and
`w1[M]`. Each table is named by the lookup's number in the program.

**Determinism.** The generator reads only the keys, in arm order: no
hash table's iteration order reaches its output (gen_fixed.ml's
symbol order breaks ties by position and byte) and nothing reads the
time, so the same keys always give byte-identical tables and builds
are reproducible. test_phash.ml checks that two runs agree.

**The compare per build,** each giving the same answer:

| build | compare |
|---|---|
| release, clang, arm64 | NEON: the 16 bytes behind the page check, masked by `vqtbl1q`, compared with `vceqq` |
| debug (tcc), and any other target | two 8-byte words behind the page check, masked, compared as integers |
| sanitizers (`__SANITIZE_ADDRESS__`, `REN_PH_MEMCMP`) | `memcmp` |

Keys over 16 bytes compare their slot with `memcmp` in every build.
**The page check** (decision 2): a 16-byte load at `s` is made only
when it stays in `s`'s 4 KiB page; otherwise the 16 bytes ending at the
page's end are loaded and shifted down (NEON), or the key's `n` bytes
are copied into a zeroed buffer (the two-word form). No padding is
promised. `""` never loads.

### `keys.index(s)`

`keys.index(s)` (prelude's `Array.index`) where `keys` is an array
literal of string literals, written as the receiver or bound by a `let`
in scope that nothing reassigns (a `let` can't be), in a release build,
lowers to the same lookup: `Some(i)` of the first `i` with `keys[i] ==
s`, else `None`. A key that's repeated keeps its first index. Debug
builds call the method as written, with the same result. A shape's
field names wait for `T.shape` (stage 12).

**Not a top-level `let`:** the brief names "a top-level `let` bound to
an array literal of string literals" as the case that exists now, but
Ren has no top-level `let` yet; it lands in stage 12 with build-time
evaluation (README's roadmap, row 12; shapes.md). Building it here
would be stage 12's work, so this stage takes the build-time constants
that exist: a literal, directly or through a local `let`. The top-level
`let` reaches the same lowering once it exists, since Lower sees through
it to the literal.

### Errors

Each is a refusal test in test_patterns.ml.

```
error: `..rest` alone is the whole value                            (parser)
  help: bind it with a name: `rest`

error: `[..xs]` alone is the whole array                            (parser)
  help: bind it with a name: `xs`

error: `..` alone matches anything                                  (parser)
  help: write `_`

error: a pattern has one `..` at most                               (parser)
  help: to cut at a separator, use `split` or `split_once` on the value

error: the pieces of a string pattern are string literals           (parser)
  help: bind the middle with `..name`, and test the rest in the arm

error: a string pattern can't have holes                            (parser)
  help: match the fixed text, and bind the rest with `..name`

error: a string pattern matches a `Str`, but this is `Bytes`        (Infer)
  help: read it with a format, or match `Str.from_utf8(b)` first

error: a list pattern matches an `Array`, but this is `Int`         (Infer)
  help: take it apart as what it is, or bind it to a name

error: `x` is bound in `"a" ..x` but not in `"b"`                   (Infer, today's)
error: this `match` doesn't handle every `Str`                       (Exhaust, today's)
  help: add a `_ =>` arm to cover the remaining values:
error: this `match` doesn't handle every `Array`                (Exhaust, today's)
  help: add the missing arms, or a `_ =>` arm for the rest:   [_, _, ..] => todo
error: this arm can never match                                      (Exhaust, today's)
  help: the arms above already match everything this one does
```

### Step 2, as built: natively, as chains

to_mem.ml's `match_` tests each arm's pattern in order, as it did,
with three new tests:

- **A literal,** `"GET"`: `Str_is`, a runtime call that compares the
  length, then the bytes (ren_rt.h, `ren_pat_is`).
- **A prefix or suffix,** `"Bearer " ..token`: `Str_affix`, the length
  at least the two pieces', then each piece where it goes
  (`ren_pat_affix`). A named rest is then a slice, `Slice (Of_bytes,
  Range)` from the prefix's end to the suffix's start: cut as `Bytes`
  are, without the character check, since the cuts are where valid
  UTF-8 pieces end (rule 2). Its bounds are in range by the length
  test.
- **A list,** `[a, ..rest, z]`: `Array_len` against the pieces' count,
  `==` without a rest and `>=` with one, then each element a piece tests
  read with `Array_get` at its index from the front, or from the back at
  `len - b + k`, unchecked, since the length test holds; and a named rest
  a `Slice (Of_array_elems, Range)`.

**What's read is owned.** `Array_get` counts the element again, and a
slice is a new header, so each is owned by the matcher, not borrowed as
a field is. `temps` holds those of the path being tested: each is
dropped where its pattern's tests end, which is where the paths that
don't match fall through, and on the way to an arm, after the names
bound to it are counted (`matched`'s `go`). A name bound to one is set
to it, then counted where the arm matches, as a field's name is; the
drop on the way leaves the name the one reference the arm owns. A
guard that fails drops the names, falls through, and the temps are
dropped there. Mem Lint checks it on every path, and so do both
countings and the sanitizers (bench/patterns.t).

**The literal is in the call.** `Str_is` and `Str_affix` carry their
literals, which emit_c.ml writes as C string literals; nothing is
allocated for them.

### Step 3, as built: the perfect hash

- **lib/native/phash.ml** is gen_fixed.ml's generator, with the six
  fixes (the spec's list) and the two fallbacks. `Phash.plan` gives a
  `Hash` (positions, tables, slots), a `Mix` (a constant and slots) or
  `Lengths`; `Phash.c` writes its lookup's C; `Phash.lookup` answers as
  the C does, for the fuzz.
- **Mem's `Str_lookup of string list`** gives the number of the key a
  `Str` is, or -1. emit_c.ml numbers each distinct key list as it meets
  it, `ren_ph<N>`, and writes each lookup's C before the functions; in a
  debug build's units each lookup is a static definition that a unit
  using it includes, as it declares what else it uses.
- **The switch** (to_mem.ml's `dispatch`): a `match` of one `Str`
  subject with two literals or more looks the subject up once, then
  `switch`es on the number. The branch of the literal `w` holds, in
  order, the arms whose pattern can match `w`, decided at build time
  (`can_be`), and knows the subject is `w` (`keyed`), so its literal and
  prefix tests aren't made, only a rest's slice is cut. The default
  branch holds the arms that can match a string none of the literals
  is. One literal stays a chain: a length test and a compare (the
  research's 0.36 ns against the hash's 0.53).
- **The compare** is in ren_rt.h's "string patterns", per build, as the
  spec says: `memcmp` under the sanitizers (`__SANITIZE_ADDRESS__`, or
  clang's `__has_feature`) or with `-DREN_PH_MEMCMP`, and on a big-endian
  target; NEON on arm64 with clang; two masked words otherwise, tcc's
  debug builds and x86 release among them. The two over-reading forms
  load 16 bytes only where they stay in the string's page.
- **The fuzz,** test/test_phash.ml: the research's adversarial sets and
  120 random ones (2 to 200 keys, 0 to 40 bytes, over 2 letters to any
  byte), each looked up with every key, four near misses of each and 200
  random strings: in OCaml through `Phash.lookup`, and in C through the
  lookups phash.ml writes, compiled four ways (two words with cc and
  with tcc, `memcmp` with `-DREN_PH_MEMCMP` and under AddressSanitizer),
  each query copied to the end of an `mmap`ed page whose next page no
  one may read, and `""` at the start of that page. No disagreement;
  129 sets hash, 2 take the mix, 1 the length switch. Two runs give the
  same C.
- **`--emit-c`** shows each lookup's keys, numbered, in a comment over
  its function, the numbers the `switch` has a `case` for.
- **NEON, not measured, but run:** on x86 the release build takes the
  two-word compare. test_phash.ml's harness, built with clang 18
  `--target=aarch64-linux-gnu` (which picks NEON: `tbl` in its
  assembly) and run under qemu-aarch64 on the same 44,783 queries, each
  against its guard page, answers as the two-word form does on every
  one. That needs a cross toolchain dune doesn't have, so it was run by
  hand (`apt install gcc-aarch64-linux-gnu qemu-user-static`).
- **The numbers** are bench/native/RESULTS.md's "Step 3: the perfect
  hash".

### Step 4, as built: `keys.index(s)`, and using it

- **The lowering** is in to_mem.ml's `call`, in a release build: a call
  of the prelude's `Array.index`, or of a copy of it (`is_array_index`
  follows a copy's `origin`), whose receiver is an array literal of
  string literals, written there or a local a `let` bound to one
  (`literal_keys`), and whose argument is a `Str`, is lowered as
  `index_match`: the Core `match` of the argument with an arm for each
  key, the first time it's written, giving `Some` of that index, and
  `_ => None`. That's a string `match`, so with two keys or more it's
  the lookup and switch of step 3, and a key list a `match` has too
  shares its tables. A `let` of such a literal whose every use is a
  hashed `index` (`only_indexed`) isn't made at all, so the lookup
  allocates nothing.
- **Debug builds** call the method as written. `ren run --release` runs
  the specialized Core, which still calls it: the rewrite is the native
  lowering's, so the interpreter is the meaning it's checked against
  (bench/patterns.t's index.ren, every build, and the keyword kernel's
  `run_index`, whose sums are the chain's).
- **Not a top-level `let`,** which Ren doesn't have yet (`keys.index(s)`,
  above).
- **examples/just:** `main` finds the recipe to run with a `match` on
  the args and the recipes, `([named, ..], _)`, `([], [first, ..])`,
  `([], [])`, where it tested `args.len()` and indexed; `Justfile.parse`
  classifies a line with a `match` on the trimmed line and the line,
  `("", _) | ("#" .., _)` for blank and comment lines, `(_, " " .. |
  "\t" ..)` for an indented one, where it chained `starts_with`. Its 21
  tests pass unchanged, and bench/tasks.t's runs of it print what they
  did. The just isn't native (it starts tasks), so its code size is the
  lexer kernel's (step 3).
- **stdlib.md** says when `index` is hashed.
- **The numbers:** the keyword kernel's `<set>_index` form, a `let` of
  the keys then `keys.index(s)`, runs at the `match`'s speed, 5.6 to 9.1
  ns against 5.3 to 8.3 (RESULTS.md, "Step 4").

### Step 5, the review

**Soundness.**

- **The over-read and the page check.** test_phash.ml puts every query
  at the end of an `mmap`ed page whose next page no one may read, and
  `""` at the start of that page, and runs 44,783 of them through four
  builds: two words with cc and with tcc, `memcmp` asked for and under
  AddressSanitizer. No disagreement and no fault. NEON, built for arm64
  and run under qemu on the same queries, agrees with them all. A lookup
  answers `""` on its length, so the empty string at a page's first byte
  never loads. Sanitizer builds compare with `memcmp`, so nothing they
  check over-reads.
- **The empty string,** as a key and as a subject: sizes.ren's `edges`
  and `only_empty`, strs.ren, guards.ren, the fuzz's `empty`,
  `emptyonly` and `emptypair` sets and the random ones, which draw
  empty keys. A length switch's case 0 compares no bytes.
- **Slices bound from a subject that dies:** strs.ren keeps the tokens
  of strings made and dropped in the call; a slice counts its root, and
  Mem Lint, both countings and AddressSanitizer agree.
- **Guards:** guards.ren takes every guard false and true across
  literals and prefixes; nested.ren hashes `match`es inside guards' calls
  and inside an arm. `keyed`, a branch's knowledge of its literal, is
  each `match_`'s own, so an inner `match` can't see or change an outer
  one's.
- **The generator at its size edges:** 128 and 200 arms (a value table
  of `int16_t`), keys of 1, 16, 17, 254, 255 and 300 bytes (a length
  table of `uint16_t`, `memcmp` past 16), `{""}`, and sets that need the
  mix and the length switch, in the interpreter, natively and in the
  fuzz.
- **`keys.index` on keys a block takes** (index_blocks.ren): a release
  build lifts the block with the keys a parameter, which the elision of
  a `let` sees as a use that isn't a hashed `index`, so the array is
  made, and the block's `index` calls the method. Every build agrees.
- **Mem Lint and the sanitizers** check every bench/patterns program in
  every build (bench/patterns.t).

**The spec.** Each of language.md's five rules holds, tested both ways
in test_patterns.ml, and the synthesis's emitter fixes are each in
phash.ml, each exercised by the fuzz. The "Done when"s:

- **p1:** every form runs in `ren run`, every error fires with its help.
- **p2:** every native build agrees with `ren run` on every program,
  which arm a guard falls through to included.
- **p3:** the fuzz finds no disagreement. On the brief's five sets the
  `match` is faster than Rust's (1.4× to 2.7×). Against the chain it's
  3.8× to 9.8×, beside the research's 5.5× to 8.3×: renkw and jsreserved
  beat it; methods, headers and json24 fall short, by the about 5 ns
  of Ren's loop over the queries that both forms pay (the `one` set
  bounds it), which is most of a hashed lookup's time here and none of
  the research's C. A one-literal arm, 5.5 ns, costs less than the
  chain's 7.1.
- **p4:** `keys.index` on a literal is the lookup in a release build, at
  the `match`'s speed; the just's tests pass unchanged. The just isn't
  native (it starts tasks), so "both builds" is `ren test` and the
  journal tests bench/tasks.t and examples/just.t run, which pass.

**Docs and tooling:** the README's status and roadmap row, this
section, stdlib.md's `index`, the grammar, its corpus and highlights,
and differential.py over bench/patterns. language.md's "What Ren has
today" still says "none" for string and list patterns: this stage may
not edit language.md, so the owner's to change.

**What's left, by severity:**

- **Medium, speed only:** the DAG is Maranget's at its first column (The
  DAG, "What isn't built"): no length switch for arrays, and a string
  column of a tuple's, `match (method, path)`, is a chain, not a lookup.
  Every answer is right; a tuple's string column is slower than it
  could be.
- **Low:** NEON isn't measured, only built and run under qemu; the
  owner's arm64 machine measures it.
- **Low:** the length switch, the generator's last fallback, compares
  each key with `memcmp`, not word compares as the brief says; it's
  taken by 1 set in 132 of the fuzz's, none of the real ones.
- **Cosmetic:** `--emit-c` numbers a lookup's keys in a comment over it,
  but the `switch`'s cases aren't commented with their literals: Mem's
  `Switch` has no place for a comment.
- **Not this stage's:** test_deps.ml's "a read-only `Fs` can't write"
  test fails in this container, which runs as root, at the stage's
  first commit too; examples/net.t, whose journal records whether a
  socket's read was ready, failed once under load and passed on reruns.

### Where this stage may differ

Choices the documents don't make, made here:

- **Adjacent literals are one,** `"a" "b"` is `"ab"`: the grammar of
  rule 1 juxtaposes pieces, and nothing gives two literals side by side
  another meaning.
- **Covering is pairwise** (Coverage): a union never covers.
- **A `Str` sequence always has a rest;** without one it's a literal.
- **`keys.index(s)` hashes a literal or a local `let` of one,** not a
  top-level `let`, which doesn't exist yet (`keys.index(s)`, above).
- **The DAG switches on its first column only** (The DAG, "What isn't
  built").
- **The length switch compares with `memcmp`,** not words.
- **A seventh key set, `one`,** in the keyword kernel, to measure a
  one-literal arm against the chain.

### Progress log

| step | commit | done | left |
|---|---|---|---|
| 0 | 230aa07 | this section: the AST and Core forms, coverage (lengths as constructors, the `Str` family, the pairwise covered-arm rule and why hashing literals first keeps first match), the DAG's nodes, the generator's budget, output and determinism, the compare per build, every error; the keyword baseline (bench/native/keywords, its Rust and Go twins, RESULTS.md "Patterns stage"); test/test_patterns.ml, every test behind `until "p1"`; bench/patterns.t over bench/patterns/ (gen.py's key sets computed in Python), `index.ren` already as specified in `ren run`, every other program `not yet` | steps 1 to 5; `keys.index` takes a literal, not a top-level `let`, which doesn't exist yet |
| 1 | 933b988 | the front end and the interpreter: `PStr` and `PSeq` (ast.ml), parsed by `parse_str_pattern` and `parse_list_pattern` with `parse_rest`, adjacent literals joined, `let [a, ..] = xs else ...`; Resolve binds a rest's name in place; inference types a list pattern as `Array<T>` and a string one as `Str`, a `Bytes` subject its own error (`str_pattern`); exhaust.ml's `Seq` and `Str` spaces, `lengths` splitting a column's lengths, `covers` and `specialize_str`, the missing arm `[_, _, ..]`; Core's `PStr`, `PStr_rest` and `PArray` (`map_seq`, `seq_pieces`, `seq_rest` for the passes that walk patterns), Core Lint's checks of them; eval.ml's matcher, a rest bound through `Builtins.slice_value`; every p1 test on; tree-sitter's `string_pattern`, `list_pattern` and `sequence_rest`, the corpus, a highlight, differential.py over bench/patterns; bench/patterns.t's programs as specified in `ren run`. Natively a string or list pattern is refused (`unsupported`) until step 2 | steps 2 to 5; language.md's table still says "none" for string and list patterns, and this stage may not edit it |
| 2 | 81579bf | natively, as chains: to_mem.ml's `match_` tests `PStr` with `Str_is`, `PStr_rest` with `Str_affix` and a rest's slice cut unchecked (`Slice (Of_bytes, Range)`), `PArray` with a length test, its elements read by `Array_get` and its rest a slice, all owned and dropped through `temps`; Mem's `Str_is` and `Str_affix`, Mem Lint's signatures, ren_rt.h's "string patterns" section (`ren_pat_is`, `ren_pat_affix`, no `memcmp` of no bytes); bench/patterns.t's programs native in every build, and the keyword kernel's `match` forms (bench/native/keywords). The first run of the checks found `memcmp` undeclared in a debug build's units, which include no system header: the section declares it under `REN_UNIT`. examples/net.t, whose journal records whether a socket's read was ready, failed once under load and passed on 4 reruns | steps 3 to 5; of the DAG, a length switch and a switch on a tuple's columns after the first (The DAG, "What isn't built") |
| 3 | 3f5b8fe | the perfect hash: lib/native/phash.ml (gen_fixed.ml's generator with the six fixes, the 64-bit mix, the length switch, the C of a lookup); Mem's `Str_lookup`; emit_c.ml's lookups, numbered by their keys and written before the functions, and a static copy in each debug unit that uses one; to_mem.ml's switch on a string subject's literals, each branch knowing its literal (`keyed`, `can_be`); ren_rt.h's compares per build and the page check; test/test_phash.ml, the fuzz in OCaml and in C four ways, no disagreement, and the same tables twice; the keyword kernel's `one` set; RESULTS.md's numbers: the `match` 1.4× to 2.7× faster than Rust's on every set of two keys or more, 3.8× to 9.8× the chain (9× to 25× less the loop), a one-literal arm 5.5 ns against the chain's 7.1 | steps 4 and 5; NEON measured on arm64; a hashed column of a tuple's |
| 4 | f3682f8 | `keys.index(s)`: to_mem.ml's `call` lowers it, in a release build, on an array literal of string literals or a `let` of one, as `index_match`, the string `match` step 3 hashes, and a `let` only hashed `index`es read isn't made (`only_indexed`); examples/just's recipe choice and line classification as `match`es on lists and strings, its tests unchanged; stdlib.md's `index`; the keyword kernel's `index` form, at the `match`'s speed (RESULTS.md) | step 5 |
| 5 | 3da6198 | the review (above): bench/patterns' nested.ren and index_blocks.ren, every build; the README's status and roadmap row; "Where this stage may differ" completed | the DAG's further columns and a length switch; NEON measured; language.md's table |

## The runtime model

Every object the runtime makes is in one of four states, which its
count says, and every value the compiler emits is a reference to one,
counted or borrowed. Every pass that changes how a value is
represented, where it lives, or when it's freed keeps the rules below,
and Mem Lint checks them. It's the design for tasks on many cores
(foundations.md, decision 10, and Staging, item 5), checked against
every memory mechanism decided so far for the pairs nobody had checked
(research/runtime-model.md). The native slice builds local, immortal
(statics) and the shared mark, behind `-DREN_RC_SHARED`; the rest
arrives with 11b.

**States.** The count is the 32-bit field of the 8-byte header,
Lean's encoding plus one band for arenas:

| count | state | unique | freed by |
|---|---|---|---|
| 1 and up | local: one thread writes it, exact | at 1 | the last drop, to the heap its chunk names |
| -1 to -2^30 | shared: atomic, one way | never | the last drop, on any thread, to its owner's heap |
| 0 | immortal: statics, sealed arena objects, counts that overflowed | never | never, or its arena's end |
| below -2^30 | arena: counted by the one task that can see it while its chunk is open | at one, if open | the last drop, or its arena's end |

The inline paths are today's: they test for a positive count and exit
inline on 0, so statics and sealed arena data cost two compares and no
call. The rest goes to a cold path, which tells shared from arena by
the band, and an arena's object from an overflowed count by its
address, since arena chunks come from one reserved range. A count that
overflows its band sticks, so overflow costs the fast path nothing. A
sealed object's count becomes 0 on its first cold count, so it costs
what a static does from then on. A chunk of small objects is aligned
and names its owner heap; an arena's chunk also names its arena and
whether it's sealed.

**What the compiler keeps out of the header.** Borrowed references (a
borrowed parameter, a part, which a slice is of its root, a task's
borrow of what its block captures, a read block's borrow), reuse
tokens, holes that tail recursion modulo cons fills, slots swap-out
took, buffers a hoisted loop indexes, and small values, which are no
object. Each lives in one function or one interval of it, and Perceus
and Mem Lint follow it path by path.

**Rules.** Seven, which replace the arena research's eight, the frame
rules, adoption, and the freeze rules:

- **U, uniqueness.** `ren_is_unique` decides every change in place:
  reuse, `Array_own`, swap-out's take, `map_into`, a fill's chain. It's
  true only for a local count of 1, or an arena count of one in an open
  chunk. An array's elements change in place only if it's
  also an owner or a lent slice (`ren_array_writable`), and it grows in
  place only if it's an owner (`ren_array_unique`): a slice shares its
  root's buffer, and a lent one is a `split_at`'s half, the one way to
  its range (Stage 10d, "Blocks with `inout` parameters, and slices").
- **B, borrows.** A reference that isn't counted has a counted holder
  upstream that outlives it and doesn't change it meanwhile; a part is
  counted before what it's part of is consumed. Perceus gives this in a
  thread, and exclusivity and the scope frame's liveness across tasks.
- **H, heap of origin.** Freed memory goes back to the heap its chunk
  names; across threads, through the owner's delayed-free list, as
  mimalloc's `mi_free` does. Arena chunks go back only to their arena,
  at its end.
- **M, marking.** Before an object is reachable from another thread by
  anything but a borrow or a join, it's marked shared: what a spawned
  block keeps of its captures, what's stored in a handler instance tasks
  share, a published version, a value sent on a channel. An arena is
  sealed instead, and its first seal marks its captures.
- **X, crossing.** Values cross a region's edge by copy: out of an arena
  (its result, and what an outer operation keeps of its arguments), into
  one (an operation's result), and out of a read block, up to a budget,
  past which it's counted as shared. One traversal does it, forwarding
  in place where the source dies right after, and through a side table
  where others still read it. Only arenas and read blocks copy; scopes
  and `with` bodies don't.
- **D, deferral.** A free that waits for a grace period finishes before
  the region that owns its memory ends: a snapshot instance frees what
  it retired when it ends.
- **J, joins.** A task's result transfers at its join, with release and
  acquire. Nothing else moves between tasks without M or X.

**One current heap a task.** Each task holds a pointer to the heap it
allocates on, swapped at every task switch and at an arena's boundary:
two stores. Per-thread heaps, arenas, a task's own part of an arena,
re-handling and reclamation are all that one pointer, and every free
goes to the heap its chunk names, not the current one.

**Arenas re-handle what their body uses.** An arena's `with` installs a
stateless handler for each dependency in its body's row that was
installed outside it. Each operation switches the task's current heap
to the one the outer handler was installed with, copies out the
arguments that handler keeps, calls it, switches back, and copies the
result in. A block passed to such an operation is wrapped the other way.
It holds no state, so it takes no lock and makes no journal entry. In
release builds it's a known handler and inlines; in debug builds it's
one more evidence node. Measured with hand-written C, copy-in costs 113
to 152 cycles an operation that returns objects, about 7% of a
4,000-cycle request, and the heap switch as a pointer is two stores.

**Under `single()` and `sim`** there are no marks, seals, deferred frees
or locks, and the shared paths aren't compiled. What's left is local,
immortal and arena-open, and the compiler's states.

**What Mem Lint checks,** beyond what it checks today:

- every operation that writes in place consumes a bundle Lint knows
  holds one reference;
- a part, a slice included, is never read after its parent is consumed
  unless it was counted first;
- each marking point is preceded by `Mark_shared`, or is a join's
  result;
- in an arena's body, every operation of an outer handler goes through
  the re-handler, the leave copies out every object slot of its result,
  and no token, view or part crosses the `with`;
- a value leaving a read block is copied out, or counted only as
  shared;
- the fields an object may have, 64, is one constant shared by to_mem,
  Mem Lint and the runtime (today Lint says 32).

A debug runtime asserts H on every free, and at an arena's end that no
heap object points into its chunks.

**What was cut.**

- **Frames (stack.ml, H8).** After small values (step 10), keeping an
  object in its function's frame added nothing measurable: 1.00× the
  cycles on every benchmark and on H8's kernels, and 0.3% of
  binary-trees' instructions. Frames were also the one memory state Mem
  Lint didn't check, which is how a leak shipped (a frame version
  building its result in a reuse token's memory). stack.ml, the
  `_frame` versions, `Mem.fn`'s `stack` and `slot`, and the runtime's
  `ren_stack_ctor` and `ren_stack_drop` are gone: every benchmark's C
  is the same without them but for the panic texts, and runs in the
  same cycles (RESULTS.md, "Frames and late overflow cut"). The analysis
  stays in git, in case records of more than four fields, built and
  lent, show up in a measured program.
- **Handler operations compiled to atomics.** Uncontended, an atomic
  gains nothing over the instance's lock on an M4 (2.7 against 2.4 ns),
  and contended, the standard library's striped counter beats it (34
  against 13 million operations a second at 8 threads), with no compiler
  rule.
- **Adoption,** which held an outer operation's result until its arena
  ended: copy-in replaces it, which removes a state and bounds memory
  (1.7 MB against 150 MB after a million requests in one arena).
- **Sealed and static as two states:** both are immortal.

**How big it is.** About 2,050 lines of C for the memory model: today's
1,100, the arena 440, the shared paths 120, reclamation 250 and delayed
frees 150, the unbuilt parts estimated. That's about Koka's runtime
plus Lean's regions, made safe: Lean's compacted regions are `unsafe`,
and an arena's seal and rules replace that. Its count states are Lean's
three plus one.

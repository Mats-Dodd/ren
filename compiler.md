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
  `no_kept_blocks` for written types).
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
  its body, and the byte says whether its elements are counted. A
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
keeps its own. rbtree's `Node(color, left, key, value, right)` is four
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
`Option<Str>` is one word. A type is recursive if its declaration
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
would be one is boxed, as before ([Demote]). Boxing one can make a type
that held it a struct, which a later pass of compiling may box in
turn; each boxes types none before did, so it ends. So `==` and `show`
of a small value box its type, and so does an option of an option,
whose inner one is a field. Debug builds don't make small values: the
types stay boxed there, as they were.

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
description is used. A dependency's members and operations never share
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
  none, so `call.name.concat(show(call.args))` is the journal's call.
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
the sanitizers), `release`, and `tcc_same`. Step 7's three kernels run
today, so they say `as specified` already; step 7 adds them to the
loops once it has measured them.

| step | expect tests (test/test_data.ml) | bench/data |
|---|---|---|
| 1 | update from a record and a named one; the base, then the fields in order; an update in a loop; an update's type; across record types; record patterns with literals, named, renamed, nested; `let { .. } =`; in a `for` and a block's parameter; fourteen refusals | update |
| 2 | built and matched by name; `..`, renames, nesting; one field positional, unlabelled too; one named field in braces; another module's; tags stay positional; fifteen refusals, the missing arm by name among them | byname |
| 3 | or-patterns, nested; `as`; `let ... else` with `fail`, `break`, a block and an `if`; a `let` of a one-variant type; `fail` or-patterns; the end-to-end program; nine refusals | orpat |
| 4 | `as` binds the variant type; fields, patterns, update and `var` on one; back to the sum; returned, stored, passed; `==`, order, `hash` and `show` borrowed; a generic sum's; an or-pattern's `as` is the sum; seven refusals | variants |
| 5 | a field of a sum, of several variants, of every variant; missing arms to paste, by name, and errors (six refusals); `todo` panics, and leaves a `let ... else` | todo_panic |
| 6 | three refusals of a stateful description called as a method; a stateless one still called; a stateful one installed beside | shapes (the ADT) |
| 7 | (no output changes) | nested, rows, optional (one per fault), interp (the milestone) |

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
                                                       type, or the expected)
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
lparam    := ... | "{" fpats "}" [":" type]
for       := "for" [IDENT ","] (IDENT | tuple_pat | "{" fpats "}") "in" ...
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
fields, as today). Resolve knows both from the declarations it already
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
false` is a `Unit`, and the standard library's `lib_panic` isn't the
program's. A `break` there leaves the innermost loop, as Resolve already
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
- `describe` (core.ml) gives a `Variant` its sum's descriptor, so a
  generic function shows, compares and hashes it as the sum (walk.ml,
  shown.ml), and a `Derived` dictionary of a `Variant` is its sum's.

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
slots from `small`). The specializer may key copies of generic code by
the sum rather than the variant type, since their code is the same.

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
optional 101,004, for 100,000 items each.

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
   per item.
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
   allocate only its array's growth.
3. **The tag is a whole word.** `Tagged`'s slot 0 is an `Int`. **The
   fix**, in two parts. (a) **A byte tag:** the tag in slot 0's low
   byte, and each constructor's small scalars (`Bool`, `()`, an enum, a
   sized type of 32 bits or less) packed into the rest of slot 0, as
   `pack` places them in an object (`Bits` places), so `| A(Bool) |
   B(Int)` is two words, not three. A boxed constructor's tag is
   already its header's. (b) **Pointer niches:** `Nullable (0, 1)`,
   today two constructors, one without fields and one of one object,
   becomes `Niche of { obj_ctor : int; slot : int }`: any sum with one
   constructor that has fields, at least one an object after
   flattening, and any number without, has no tag; its object slot
   holds the object for `obj_ctor`, and for the `i`-th constructor
   without fields a scalar no object is, `Scalar_ctor (-1 - i)`
   (`ren_box(UINT32_MAX - i)`), its other slots 0 (Roc's
   `NullableUnwrapped`, Swift's spare bits). `Option<Item>` with `Item
   = { name: Str, price: Int }` is two words and no tag; optional.ren
   should allocate a constant number.

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
migration, step 3's `let ... else` where it fits).

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
- **The stateless-only rule is checked on the linked program,** per
  dependency, against every handler whose description is kept, since a
  description's type doesn't say whether its handler keeps state: a
  dependency that has one stateful handler kept as a value refuses
  every method call on its descriptions. `ren check` of one module
  doesn't see it; `ren run`, `ren test` and `ren build` do.
- **Stateful means a `var` or a `finally`,** decision 3's list less the
  two its types already refuse; a `let` among a handler's state is
  stateless, though native code installs it for a call, which means the
  same.
- **Or-patterns' messages replace today's for `fail` or-patterns too,**
  so there's one wording.
- **Only a small record or tuple is flattened into its parent** (step
  7); a nested small sum stays boxed, since flattening a tag into a tag
  is more than language.md's fault asks for.

### Progress log

| step | commit | done | left |
|---|---|---|---|
| 0 | f313084 | this section: the grammar, the AST, each step's rules, passes and files, every error with its help, the layout faults and their fixes, the choices where the design is silent; the inventory of by-name sites (324, counted by a scratchpad script); test/test_data.ml, every test of a feature behind `until "sN"`, the guards written plainly; bench/data/ (update, byname, orpat, variants, todo_panic, shapes, and step 7's nested, rows, optional and interp) and its section of bench/build.t, step 7's three kernels already as specified | steps 1 to 8; nothing of the language is built yet |
| 1 | cff7c15 | record update, `{ ..o, f: v }` and `T { ..o, f: v }`, and record patterns, `{ f: p, g, .. }` and `T { .. }`, in a `match`, a `let`, a `for` and a block's parameter, through the parser, Resolve, Infer (`infer_update`, `record_pattern`), Exhaust (a record is one constructor), Core (`PRecord`) and Core Lint, the interpreter, and Mem IR in both builds; the fourteen refusals; tree-sitter's `record_expression` with a `spread`, `record_pattern`, `field_pattern` and `rest_pattern`, its corpus (records.txt) and Zed's highlights; test_data.ml's s1 tests on, and bench/data/update in build.t's `same`, `release` and `tcc_same`, with its reuse shown (`--stats`: the loop of 1000 updates allocates nothing, each a reuse); the README and language.md's "What Ren has today". Choices: below the table | steps 2 to 8 |
| 2 | e180921 | the language change, by-name variants, through the whole pipeline: the parser (`parse_ctor_decl`'s braces and one positional field, labelled or not; `Shape.Rect { ... }` and `Shape.Rect { .. }`; `..` refused in parentheses), Resolve (`braces_name`, the record-or-constructor refusal; a by-name constructor refused where a binding pattern must always match), Infer (`infer_con_named`, `con_pattern`, `ctor_shape` down to arity, the by-name and by-position refusals with their fix-its, an update into a by-name constructor), Exhaust (`Rect { .. }`), lowering (to `Con` and `PCon`, so Core, Core Lint, the interpreter and Mem IR are unchanged), `show` in the interpreter, its `assert` diff, the journal, and natively (`ren_ctor_info.fields`); tree-sitter's `variant`, `constructor_expression` and `constructor_pattern` with fields, the corpus (variants.txt, and types.txt's declaration moved), Zed's highlights; test_data.ml's s2 tests on, bench/data/byname in `same`, `release` and `tcc_same` (and `shapes` and `interp` now as specified) ; and the migration, every site of the inventory moved to the new forms, 318 of its 324: bench/ 100 (packed, review_lists, review_values, sized, trmc, trmc_panic, values), bench/native 103 (binary-trees, blocks, cfold, deriv, nested, nqueens, rbtree; their Rust and Go twins and checksums unchanged), bench/build.t's heredocs 12, examples/ 17 (bank 7, `Sent { amount: t.amount, to: t.to }`; shop 3, vm 4, infer.ren and plans.ren 3), test/ 81 (test_native 38, test_eval 12, test_blocks 10, test_deps 10 with 6 printed, test_resolve 4 with 1 printed, test_infer 3, test_modules 2, test_ops 1, test_syntax 1), the corpus 2 (types.txt, expressions.txt), the docs 3 (README.md's `Pro(5)`, errors.md's `Sent` and `Received`) and their prose (README.md, bench/native/README.md, the Native slice's trmc paragraph); the outputs promoted, each diff only `show`'s braces, the step's error texts and the bank's line numbers. Left as they are, 6: formats.md's `Query(sql: CStr)`, a format's `case`; test_infer.ml's `Pro(seat: 5)` and `Pt(x: 1, 2)` and their printed copies, now tests of the errors that replace theirs; test_modules.ml's printed `Full(row: Row)`, a declaration of one field. Choices: below the table | steps 3 to 8 |
| 3 | b885fcd | or-patterns anywhere a pattern goes, nested, `as`, and `let PATTERN = e else LEAVE`, through the whole pipeline: the parser (`parse_pattern`'s alternatives, `as` and grouping; `let` and `for` taking any pattern and a block's parameter one that starts with `(`, `{` or a capital; the `let ... else` statement; `if let` refused with its help; `as` after `fail` patterns refused), Resolve (one message for a name only some alternatives bind, `fail` ones too; `leaves`; the `else` resolved before the pattern binds), Infer (`bind_pattern`'s `POr`, through `alternatives`, which `bind_fail` shares, with the new message; `PAs`; the `else` checked against the rest of the block's type), Exhaust (`Or` spaces, each alternative checked useful, the patterns of a `let`, a `for` and a block's parameter checked to always match, and a `let ... else`'s to not), lowering (`let ... else` a `Match` of two arms, `PAs`), Core's `PAs` and Core Lint, the interpreter, and Mem IR in both builds (`PAs` the subject itself; an or-pattern that binds names gives each alternative its own variables and its own join, which Perceus needs, and a pattern's variable found by id); tree-sitter's `or_pattern` for any patterns, `as_pattern`, `parenthesized_pattern`, `let_else`, patterns in a `let`, a `for` and a block's parameter, the corpus (patterns.txt) and the highlight markers, Zed's highlights; test_data.ml's s3 tests on, the end-to-end program among them; bench/data/orpat as specified and in `same`, `release` and `tcc_same`, with bench/data/orpat_strs beside it (or-patterns binding counted values); the bank's `worth_retrying` in two arms with or-patterns; README's tour, language.md's "What Ren has today". The parser's `binding_pattern`, `irrefutable` and `might_not_match` are gone, and so is Resolve's refusal of a by-name constructor in a binding position: Exhaust decides. Choices: below the table | steps 4 to 8 |
| 4 | this commit | variant types, `Order.Placed`, through the whole pipeline: the parser (`parse_ty`'s `TyVariant`, `Tree.Node<Int>`, and `Tree<Int>.Node` refused with its help), Resolve (the sum's name, and the three refusals: not a sum, no such variant with "did you mean", a variant not by name; and a variant type of a private sum in a public signature), Types and Ty (`TVariant` and `Variant`, unifying only with themselves, printed `Order.Placed`, every walk of a type), Infer (`as` on a by-name constructor's pattern binds its variant type; field reads, record patterns, `{ ..p, total: x }` an `Order.Placed`, `var p` and `p.total = x`; `Placed { ..p }` the sum; a pattern of a variant type's own constructor that always matches, and of another one refused; the two mismatch helps and the constructor's note; `..` from a sum, and the method refusal), Infer_reqs (`==`, `hash` and order borrowed, through the sum's `key`), Exhaust (a variant type's one constructor), the interfaces (a variant type in a `pub` signature, written `order.Order.Placed` by an importer), Core (`Of_variant`, `Con`, `PCon`, `Field` and `Update` at a `Variant`, `PAs` binding one; `describe` the sum's) and Core Lint, the interpreter (a variant type's value is its sum's; its walks, `show`, `==`, `hash`, `key` and the journal, the sum's), and Mem IR in both builds (the sum's layout, struct and descriptor; a field read at its constructor's slot; no tag test; `Of_variant` no code; an update of a small one keeps its tag); release specialization; tree-sitter's `variant_type`, its corpus (types.txt) and highlight markers, Zed's highlights; test_data.ml's s4 tests on, and four more (another module's signature, round trips and a variant type's own patterns, another variant's pattern refused, the arguments' place); bench/data/variants as specified and in `same`, `release` and `tcc_same`, with variants_small (variant types of sums kept as structs), variants_escape (stored, passed through generic functions, round-tripped) and variants_reuse beside it, whose loop of 1000 updates and conversions allocates nothing (`--stats`, both builds: 4 allocations, 1000 reuses); README's tour, language.md's "What Ren has today", operators.md's "Equality, hashing and `show`". Choices: below the table | steps 5 to 8 |

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

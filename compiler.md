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
returned, `Cons(i, build(i + 1, n))`, runs as a loop instead, which
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
  chunk.
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

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
   Types, effects, requirements and lambda sets now; ownership,
   lifetimes, reuse and provenance later. Nothing downstream works one out
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
   parse ─▶ resolve ─▶ infer ─▶ typed Core
                        │
                        └ one solver: types, ! rows, uses rows,
                          requirements, lambda sets

 whole program, later
   specialize ─▶ defunctionalize ─▶ Mem IR ─▶ borrow inference
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
| Core | lower.ml | the program with one way to change something, every node typed, evidence explicit; type arguments from R2, requirement dictionaries and lambda sets from R4 | Core Lint, which the tests run on every program | yes |
| specialized Core | the specializer | Core with type arguments, requirements and lambda sets chosen | Core Lint | the memory stage |
| Mem IR | memory lowering | A-normal form, layouts, closures as tagged unions | its own lint | the memory stage |
| Mem IR, counted | borrow inference, Perceus | borrows, dup and drop, reuse tokens | its own lint; the resource checks | the memory stage |
| C | the C backend | the counted Mem IR, emitted | the C compiler, ASan and UBSan | after the memory stage |

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
  parameter, such as `eq` for `==`. Inference, in the same solver; never
  written, on a public function either (operators.md, "Generic code").
  Carried in the scheme, the interface, and as hidden dictionary
  parameters in Core. Inferred since R4, and carried in schemes and
  interfaces (infer_reqs.ml): `==` on a type with a function in it is a
  compile error. Each use of a function records what it needs
  (`Infer.node`), and lowering passes a dictionary for each, so `==` in
  a generic function compares through the one its caller gave it.
- **Lambda sets.** From R4. Which lambdas and functions a value of a
  function type can be. Inference, by unification, as a hidden third
  row of a function type beside `!` and `uses` (Lambda sets, below).
  Carried in canonical types (ty.ml, `Ty.lams`), so in every Core node's
  type and each use's type arguments, and each Core lambda carries its
  identity; Core Lint checks them. They're invisible: no message and
  nothing `ren types` prints shows one, only `ren core --lambdas`, a
  debugging aid. Nothing reads them until specialization.
- **Ownership, lifetimes, reuse credits, provenance.** Later, each by
  its own pass over Mem IR, after specialization: a known callee's body
  says whether it borrows, consumes or keeps a value, which is what
  makes reuse possible.

Effects say what may happen, lambda sets what code may run. They're kept
apart, because a pass that needs one never needs the other, and
specialization reads lambda sets without touching effects.

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
  can fail, whether a `with` installs a handler or wraps its body,
  which `match`es handle errors and which arms are `fail` arms, whether
  a `try` unwraps a `Result`. Lower and exhaust read those decisions
  from it and never make them again.
- **Core** has one way to change something, an assignment to a local,
  and one way each to fail, to handle an error, to install an
  implementation and to call a dependency (core.ml). Every node has its
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
  a type that has what it's derived for. Every function type has a
  lambda set in canonical form, and Lint checks that a lambda's type's
  set has the lambda's identity, and a function's, member's or
  intrinsic's used as a value its own; that a use's set is its scheme's
  with the use's lambda-set arguments put in; that an `if`'s or a
  `match`'s set has whatever each branch's has; and that each identity a
  callee's set has names a function or lambda of the module, or one it
  uses, that takes as many arguments as the call passes.
- **Mem IR**, later, makes every allocation, copy, count operation and
  free an explicit instruction, so the resource checks read them off
  rather than guess them.

## No cycles

Perceus frees a value when its count reaches zero, which is
garbage-free only if no value can reach itself. Ren rules that out, and
each pass keeps it so:

1. **A value never changes in place once it's shared.** `a.next =
   Some(a)` stores a copy of the old `a`, not `a`.
2. **A closure doesn't capture the evidence.** It gets its dependencies
   where it's called (deps.md, "How it runs"), so it never holds the
   handler that's installed where it was made.
3. **An installed handler instance is never a value.** A `with` installs
   it, and no expression yields it; its own dependencies are captured
   from further out. So a handler's `var`s can't reach their own
   instance. Core Lint checks this: an `Instance` appears only at the end
   of a `Handler`'s body, after the `let`s that make its state.

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
  for each type, requirement and lambda set it's used at, and each
  dependency call for the handler known to be installed there. Results
  are cached by content, so a rebuild specializes only what changed.
  Specialization has a budget, and past it the code falls back to what a
  debug build does.

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
same way, so one in `same` uses the one `same` was given. The
interpreter makes a derived dictionary a function of its own, which
compares two values as the type's declaration says: never a function,
since inference makes sure there's none in what's compared, with one
exception (Deviations).

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

## The constraint solver

Inference checks the functions of a module a group at a time, where a
group is functions that call each other, callees' groups first
(infer_top.ml). Each body of a group sees the others only as their
declarations describe them, so no body learns anything from another,
and checking them in another order would find the same. What can be
decided only once every body is checked is a **constraint**
(infer_env.ml, `constr`), and once the group is done the solver
(solve.ml) decides them all.

The constraints:

- **A use of another function of the group** has the type that
  function's own body gave it, with the type parameters and rows its
  declaration names, `fn first<T>` or `! ..e`, made fresh for each use,
  since it says it works for any of them.
- **A handler of several dependencies given where what's wanted isn't
  known yet** is taken as one of them, if that's what's wanted once it's
  known, or else as the handler itself (deps.md, "Implementations"), so
  `same(counting_rates(2), Rates { ... })` and the same with its
  arguments the other way round both take it as a `Rates`. Inference
  doesn't always wait: something that has to look into the type before
  the group is done, a `with`, a field, a method, a call, or a mismatch
  that shows it, makes it the handler's own type first, as the solver
  would if nothing else said (infer_coerce.ml). Meanwhile the variable
  it was given to can only become the handler's type or one of its
  dependencies': anything else said of it is a mismatch where it's said
  (unify.ml, `watch`), so the handler, met first, isn't blamed for it.
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
  fails with what its signature says, a public one's transparent
  parameters keep their rows open, and a handler needs no more than it
  declares, and never itself.
- **What `==` and `!=` compare has `eq`** (infer_reqs.ml): the type of
  their sides, once it's known. A type variable that has to have it
  passes that on to the function it's in, which then needs it of its
  type parameter, `same<T has eq>`; a type with a function in it is an
  error where it's compared.
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
it does. Lambda sets need no constraint: they're unified where they
meet, as the rest of a type is, and two unified each get what the other
lists, whatever order they meet in (Lambda sets, below). A check that reads a
result is decided after whatever decides it, so it never sees half of it.
And a constraint that fails changes nothing, so it can't change what
another sees. What order does decide is only which of two constraints
that can't both hold is blamed: the one met second, so a mistake is
reported where the code reads it, after what it contradicts.

One thing the solver can't do is put the groups in order. Which method
a dot call like `s.size()` calls is found only by checking the call,
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

## Lambda sets

A function type has a third row beside `!` and `uses`, its **lambda
set**: the identities of the lambdas and functions a value of the type
can be, and a variable for the rest. Specialization will read it to turn
a call of a function value into a call of one of a few known functions,
and defunctionalization to make a closure a tagged union with an apply
switch. Until then nothing reads them, but they're inferred and checked
now, since retrofitting them is what Roc found hard.

- **Identities.** A top-level function, a member, an intrinsic or a
  dependency's operation is its path, written in full (`Ty.global_id`):
  `shop/cart.total`, `Array.push`, `Clock.now`. A lambda is its
  top-level function's path and its place in it, counting from 1 in the
  order inference meets them, outer before inner (`Ty.lambda_id`):
  `main.main#2`. So an edit in one function never renumbers another's
  lambdas; adding a lambda renumbers those after it in its own function.
  The body a `with` passes to a wrapper, a handler's operation and an
  implementation's are lambdas like any other. An operation used as a
  value, `let f = Clock.now`, is a lambda lowering makes, which takes the
  operation's identity.
- **Inference.** Each lambda's type gets a set of its own identity and a
  fresh variable, and each use of a function, member, intrinsic or
  operation a set with its identity added to what its scheme says
  (infer_lookup.ml, `named`). Then sets meet only by unification, as the
  rest of the type does: the two branches of an `if`, an argument and its
  parameter, a variable and its value. Unifying two gives each what the
  other lists, and a fresh variable then ends both (unify.ml,
  `unify_lams`). A set is always open, so this never fails, and it only
  adds, so the result doesn't depend on the order sets meet in. A set
  that lists an identity twice means what listing it once does, as a row
  of dependencies does, which is what lets a big set be linked to whole
  rather than copied.
- **Generalizing.** A set's variable is generalized and instantiated as
  a row variable is, numbered apart from type and row variables. So a
  generic `fn map(xs, f)` has a variable for `f`'s set, and each call
  puts what it passes there, at that call only. A function's own set,
  the outermost of its type, is left alone in its group: a use of it,
  even in its own body, gets a set of its own (`own_set`), so its scheme
  says nothing of what its uses are given, and each use adds its
  identity to a fresh one.

**In schemes and interfaces.** A module's own schemes keep the sets
inference found: `fn even(n, k)`, in a group with an `odd` that passes
`even` a lambda, has `k: fn(Int) -> Bool [main.odd#1 | ..l0]`, and a
call of `even` from the module adds its own lambda to that. An interface
doesn't: each function type in it has a set of its own, which says
nothing of what flows there (`Ty.forget_lams`), as a written
declaration would. Sets are inferred from bodies, so an interface that
kept them would change with every body edit that changes which lambda
reaches which function, and early cutoff would be lost; they'd also say
which private lambdas a public function passes around, which a
dependent has no use for while checking. So a dependent sees another
module's function as its signature has it, its sets each a variable of
its own: what `pick(c, f, g)` returns is a set unrelated to what it's
given. That's sound, since a set is always open, just imprecise across
modules, which is lambda set specialization's known limit with separate
compilation; release builds specialize the whole program, from the
implementation tier, which keeps the typed Core with the sets in it.
The driver's check that a public function's inferred scheme is the one
its interface states compares them without sets, and Core Lint checks
a use of another module's function against its interface's scheme,
not that module's own.

**Cost.** A set is a row of identities, so unifying a small one with a
big one walks the big one. The usual sets are small. One that gathers
thousands, an array literal of thousands of lambdas, is linked to whole
rather than copied, and converted to canonical form once for all the
nodes that share it (types.ml, `canon_lams`): 4,000 lambdas in one array
check in about 0.3s (test_infer.ml).

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
- **R4, requirements and lambda sets.** `==` and `!=` require `eq`,
  derived structurally and absent from a type with a function in it. A
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
  they're printed, since that's what its message shows, and one help that
  needs more, the type to write for a public function whose body makes a
  handler of several dependencies, is worked out from the type found
  (`Infer_report.why.help_of`) rather than by rewriting the printed text.
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
  a handler's needs, is in infer_declared.ml, and taking a handler of
  several dependencies as one of them in infer_coerce.ml, beside solve.ml
  rather than in it, since the messages they give need much of what
  infer_top.ml had for them. Why a function still gets a dependency from
  outside, which a message about a call of it explains with, was a list
  in the environment; it's what the solver returns for each group, which
  infer_top.ml keeps for the next ones and for `main` and tests.
- **R3, a handler taken as one dependency.** The plan has it decided once
  both sides are known. A `with` of a handler given to a type not known
  yet waits for that too: it's a constraint of its own, which installs
  the one dependency the handler is taken as, or all of them, once that's
  decided (infer_coerce.ml, `installs`). A field or a method looked up in
  it is taken as the one of the handler's dependencies that has it, if
  just one does, since the handler's own type has neither. Anything else
  that looks into it, a call or a mismatch that shows it, makes it the
  handler's own type then, as the solver would if nothing said otherwise
  (`settle`). Each of those is an error whatever it's taken as, so it
  changes at most what the message says. The one place order still
  decides is a method that two of the handler's dependencies both have:
  looked up before anything says which is wanted, it's the handler's own
  type, which has no methods. What's wanted can be said before the
  handler is given or after, which fixes B3, and so
  `let o = Some(counting_rates(1))` followed by `let p: Option<Rates> =
  o` is accepted now too: one error a test showed is gone (test_deps.ml,
  "a handler of several where something else is wanted"). An `if` whose
  `then` branch is a handler of several waits for its `else`, as an
  element of an array waits for the others, so `if c then
  counting_rates(1) else Rates { ... }` is a `Rates`, as it is with the
  branches the other way round, as deps.md says it should be; it was
  rejected, and a test pinned that ("where nothing says which, a handler
  of several is its own", which no longer holds it). A branch that
  can't be what the other is is blamed if it's the second, as before R3,
  and the note says what the handler implements, whichever branch it's
  in. A variable a handler was given to, passed as an argument
  where one of the handler's dependencies is wanted, is taken as that
  one at that argument only, needing what the handler needs, which is
  copied where it's passed as for a handler whose type is known
  (`taken_as`): joined to what the callee uses, it would have been what a
  `with` of it around the call uses, and the dependency the `with`
  installs would have been needed outside it. The variable itself is left
  to the solver, so another use of the same value can take it as another
  of the dependencies, `run(h) + run2(h)`, or install them all, `with h
  in`. Whether the argument is taken as that one, is it already, or
  can't be, since something else said it's another, is a coercion of its
  own, decided after the variable's. A first fix made the variable that
  one dependency everywhere, which rejected programs that compiled before
  R3 (test_deps.ml, "a value holding a handler of several, taken as each
  of them").
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
  of `k` needs a `Rates` from its caller. The plan suggested Koka's rows;
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
  is an error, not a comparison of what's inside. Three things are taken
  to have `eq` that the plan doesn't decide. An opaque type of another
  module, whose interface hides what it's represented as, since saying
  it had none would make `UserId == UserId` an error in every module but
  its own; one represented as a function still panics when compared,
  until an interface says what its types have. A tag of an
  error set the set's tail may still bring in, what a function it was
  passed fails with, since a requirement on a row would be a kind of
  its own, and no tag holds a function in any program so far. And a
  type's type arguments all have to have it, even one the type doesn't
  hold a value of, `Tag<fn()>` for a `type Tag<T> = opaque Int`, which is
  what "a type with a function in it" reads as.
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
- **R4, the one comparison that can still panic.** An opaque type of
  another module is taken to have `eq` (above), so a value of one
  represented as a function, or holding one, can still be compared, and
  the dictionary derived for it meets the function. The interpreter
  panics there, saying why, which is the one way left for `==` to reach
  a function (eval.ml, `opaque_function`); every other comparison of a
  function, a handler or an implementation is refused before the program
  runs. It goes once an interface says which of its opaque types have
  `eq`.
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
  "editing a body changes the interface only by what it needs").
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
  "what the implementation tier records"), or, since the lambda sets in
  it, which specialization will read, come from the module's other
  bodies too, when an edit elsewhere in the module changes which lambdas
  reach one.
- **R4, lambda sets unify, and don't include.** The plan has sets unify
  and include as rows do. They only unify: everywhere a function value
  flows, inference unifies its type with the type of where it goes, as it
  always has, so the two sets are one, and an inclusion would never have
  anything to add. It's the imprecision lambda set specialization accepts
  (Roc's sets are unified too): `if c then f else g` makes `f`'s and
  `g`'s sets the same, so each lists the other. A set is always open,
  which is what makes unifying two never fail, so it can't add an error;
  a closed set would say no other function can reach a type, which
  specialization can work out from the whole program, and nothing needs
  it before then.
- **R4, a function's own set.** A use of a function of the group being
  checked is joined with the function's own type once the group is done
  (The constraint solver). Joined whole, every use's identity, and what
  the use is then given, would be in the function's own set, the
  outermost of its scheme, and so in every later use's. So a use gets a
  set of its own in place of the function's (Infer_lookup.own_set,
  solve.ml's `join`), and the function's own set is a variable nothing in
  its group touches, which generalizes.
- **R4, the identities.** The plan leaves them to the implementation: a
  path for what has one (`Ty.global_id`), and a lambda's function's path
  and its place in it (`Ty.lambda_id`), which inference records at the
  lambda's node (`Infer.found`'s `Lambda_id`) and Core carries on the
  `Lambda`, so lowering never works it out again. The lambda lowering
  makes for an operation used as a value takes the operation's path, as
  inference gave its type.
- **R4, what an implementation carries.** An implementation's type is
  its dependency's, `Clock uses Os`, which has no lambda sets: the
  lambdas of a record implementation and a handler's operations have
  their sets, with their identities, but a call of an operation
  (`Dep_call`) doesn't know which implementation it reaches. Which one is
  installed is what specializing for known handlers works out, where it's
  installed, a later stage's work.
- **R4, lambda sets in canonical form.** `Ty.Fun` has a fifth part,
  `Ty.lams`: the identities, sorted, and a lambda-set variable numbered
  apart from type and row variables, so no row variable's number moved
  and no printed type or row argument changed; type arguments have a
  list for them (`Ty.args.lams`). Its variable is an `option` only for a
  type written in a declaration, a field's or an operation's, before
  `Ty.canonical` numbers it: a set of its own (`Ty.any_lams`), which Core
  Lint takes as any set, since a declaration says nothing of what flows
  to it.
- **R4, what Core Lint checks of them.** "A call's callee's set is
  consistent" is read as: every identity in the callee's set names a
  function, member, intrinsic, operation or lambda of the module, or one
  it uses, that takes as many arguments as the call passes, since those
  are what specialization will call there. "Sets of joined branches
  include both" is checked as each branch's sets being within the
  `if`'s or `match`'s, with its own message, before the types are
  compared whole, which compares sets too.
- **R4, printing lambda sets.** `ren core --lambdas` prints Core typed,
  as `--types` does, with every function type's set after its effects,
  `fn(Int) -> Int [main.inc, main.main#1 | ..l0]`, each use's lambda-set
  arguments after its row arguments, each lambda's identity and type,
  and the type of a local, an `if`, a `match`, a `let` or a call whose
  type is a function's. It's a debugging aid, so its format can change;
  the tests use it (test_lower.ml). Nothing else prints a set: `ren
  types`, messages and `ren core --types` are as they were.
- **R4, a big lambda set.** Unifying two sets as rows are unified copies
  what each lacks into the other, so an array of n lambdas, each unified
  with the set of all the elements so far, took time quadratic in n in
  copies, and converting each node's set again cubic: 2,000 lambdas took
  over 30s to check and run. A set of more than 32 identities is linked
  to whole instead of copied, which a set listing an identity twice
  allows, and a node's set that is linked to one already converted reuses
  it (types.ml, `canon_lams`). The cost: a type argument for a set's
  variable can then list some of the scheme's own identities too, which
  changes nothing it means, the set being their union.

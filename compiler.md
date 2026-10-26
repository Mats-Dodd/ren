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
| Core | lower.ml | the program with one way to change something, every node typed, evidence explicit; type arguments from R2, requirement dictionaries from R4 | Core Lint, which the tests run on every program | yes |
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
  parameters in Core. Today there are none: `==` takes two values of any
  one type, and panics at runtime on functions.
- **Lambda sets.** From R4. Which lambdas and functions a value of a
  function type can be. Inference, in the same solver, as a hidden third
  row of a function type beside `!` and `uses`. Carried in Core's types,
  and checked by Core Lint; nothing reads them until specialization.
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
  describes its type argument.
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

Both mean the same: specialization only makes code faster (rule 1). The
interpreter runs the debug strategy. Evidence is passed this way today
(deps.md, "How it runs"); dictionaries come with requirements, in R4,
where `eq` is the first.

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
  would if nothing else said (infer_coerce.ml).
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
  all of them; a row ends in a named row after that, and what each
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
included in it, whatever order they're added in. A check that reads a
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
checked.

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
  its module's interface, and passed as dictionaries. Every function type
  gets its lambda set.

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
  of several is its own"). A `then` branch that can't be what the `else`
  is is now blamed itself, "this `then` branch is ...", since the fix
  goes there. A variable a handler was given to, passed as an argument
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
  now says so in a note (`Infer_msg.Holds_beyond`). Once its group is
  done, such a set is a type like any other, the one `ren types` prints:
  what an `attempt` keeps can meet it and take its tags, as it can a
  declared `Result` that holds more (test_errors.ml, "attempt keeps the
  outcome, and try fails with it again", passes `attempt busy()` where
  `NotFound(Int) | Busy` is wanted). Only a tag written in the group
  where it meets a kept set is checked against it. Telling a set made of
  written tags from a declared one in a later group, or another module,
  would need where its tags came from kept in schemes and interfaces.

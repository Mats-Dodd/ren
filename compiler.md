# The compiler

How the compiler is laid out: the passes a program goes through, the
languages in between, what each one promises and what checks it, and the
rules every pass keeps. It's written for whoever changes the compiler,
and for whoever wants to know why a guarantee in the README holds. The
module rules it builds on are in [module-build.md](module-build.md), and
how dependencies run in [deps.md](deps.md#how-it-runs).

Stage 10.0 lays these foundations before the language moves on to
operators. It isn't a language stage: nothing a program can write
changes, except that `==` on functions becomes a compile error. It's
here because what comes after operators, reference counting with reuse
and specialization, needs facts the compiler doesn't carry yet, and is
much harder to retrofit than to plan for.

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
| AST, parsed | parser.ml | the program as written | the tree-sitter grammar's differential test | yes |
| AST, resolved | resolve.ml | every name found through scope, by its binder's id or its path | inference, which only reads it | yes |
| inferred | infer.ml | each function's scheme and each node's type and lookup | the driver: a public function's inferred scheme is the one its interface states | yes |
| Core | lower.ml | the program with one way to change something, every node typed, evidence explicit; type arguments and requirement dictionaries from stage 10.0 | Core Lint, which the tests run on every program | yes |
| specialized Core | the specializer | Core with type arguments, requirements and lambda sets chosen | Core Lint | the memory stage |
| Mem IR | memory lowering | A-normal form, layouts, closures as tagged unions | its own lint | the memory stage |
| Mem IR, counted | borrow inference, Perceus | borrows, dup and drop, reuse tokens | its own lint; the resource checks | the memory stage |
| C | the C backend | the counted Mem IR, emitted | the C compiler, ASan and UBSan | after the memory stage |

## The facts

Each fact has one pass that computes it, and one place it's carried.

- **Types.** Inference, by Hindley–Milner with levels (types.ml,
  unify.ml). Carried by every Core node and binder, in canonical form
  (ty.ml).
- **Effects.** What a function can fail with, its `!` row, and what it
  uses, its `uses` row. Inference, in the same solver as types. Carried
  in function types.
- **Requirements.** What a generic function needs of a type parameter,
  such as `eq` for `==`. Inference, in the same solver; never written,
  on a public function either (operators.md, "Generic code"). Carried in
  the scheme, the interface, and as hidden dictionary parameters in
  Core.
- **Lambda sets.** Which lambdas and functions a value of a function
  type can be. Inference, in the same solver, as a hidden third row of a
  function type beside `!` and `uses`. Carried in Core's types, and
  checked by Core Lint; nothing reads them until specialization.
- **Ownership, lifetimes, reuse credits, provenance.** Later, each by
  its own pass over Mem IR, after specialization: a known callee's body
  says whether it borrows, consumes or keeps a value, which is what
  makes reuse possible.

Effects say what may happen, lambda sets what code may run. They're kept
apart, because a pass that needs one never needs the other, and
specialization reads lambda sets without touching effects.

## What each IR promises

- **The resolved AST** names every local by its binder's id, and every
  top-level entity by its path (path.ml): a module and a name in it. A
  type's member is its type's path and its name. Nothing after resolve
  looks a name up in a scope.
- **Inference's result** gives every expression and pattern a type and,
  where something was found through a type, what (infer.mli). It decides
  every question once: which constructor, which method, whether a call
  can fail, whether a `with` installs a handler or wraps its body. Lower
  reads those decisions; it never makes them again.
- **Core** has one way to change something, an assignment to a local,
  and one way each to fail, to handle an error, to install an
  implementation and to call a dependency (core.ml). Every node has its
  type, every call of a polymorphic function its type arguments, every
  function its evidence. Core Lint checks each of those against the
  others, from scratch.
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

## Stage 10.0

Five steps, R0 to R4, done in order on one branch, in small commits
that each keep every test green. Each step is reviewed on its own before
the next starts:

- **R0, foundations and safety nets.** This document; CI on Linux and
  macOS; benchmarks, and the interpreter's tail calls made a loop, so a
  long loop written as recursion isn't quadratic, and deep recursion
  reaching its panic promptly; test helpers that fail when an expected
  error doesn't come; the roadmap renumbered.
- **R1, restructure with no change in behaviour.** The prelude's
  runtime half moves to eval/, so resolve, lower and lint no longer link
  against it, and intrinsics are found by an id. A type's member is
  `{owner; name; overload}`, and schemes, nodes and interface members are
  kept in maps keyed by it. infer_expr.ml is split by concern, and what
  inference decides is recorded for lower to read. Every existing output
  stays byte for byte the same.
- **R2, typed Core.** Every Core node and binder carries its type, and a
  call of a polymorphic function its type arguments, so the interpreter
  no longer works types out at runtime. A scheme gains a slot for
  requirements.
- **R3, one constraint solver.** The deferred queues inference keeps
  become one representation of constraints, solved by one worklist per
  call-graph group, reporting every failure, in an order that doesn't
  change the answer. It fixes the bugs the order caused.
- **R4, requirements and lambda sets.** `==` and `!=` require `eq`,
  derived structurally and absent from a type with a function in it. A
  generic function's requirements are inferred and kept in its scheme and
  its module's interface, and passed as dictionaries. Every function type
  gets its lambda set.

## Deviations

Where the work forced a change to the plan above:

- None yet.

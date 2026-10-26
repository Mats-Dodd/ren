# Stage 10.0: the report

What stage 10.0 did, step by step, and where it stopped. The brief is
[STAGE-10-0-PLAN.md](STAGE-10-0-PLAN.md), and the design it built is in
[compiler.md](compiler.md), whose Deviations section has every place the
work left the plan, with its reasons.

**The stage stopped after R3.** R0, R1 and R2 are done, each passed by an
independent review. R3's work is all in, but its last review still found
one blocking issue after the two fix rounds the plan allows, so, as the
plan says, R4 wasn't started. The branch is green: `dune build` and
`dune runtest` pass at every commit, run as a user that isn't root (see
"For whoever runs the tests", below).

| Step | Commits | Review |
|---|---|---|
| R0, foundations and safety nets | `849e97f`..`dbf55cd` (19) | passed after two fix rounds |
| R1, restructure with no change in behaviour | `86ccbb1`..`9637c56` (34) | passed first time |
| R2, typed Core | `0e1d896`..`6e8ca0b` (16) | passed first time |
| R3, one constraint solver | `d811c1a`..`3f381d1` (31) | **one blocking issue left** after two fix rounds |
| R4, requirements and lambda sets | none | not started |

`STAGE-10-0-PLAN.md` is kept, since the stage isn't finished: it's what
the next session starts from, with this report beside it.

## R0: Foundations and safety nets

**Commits.** From the session before this one: `849e97f`, `bef1802`,
`42e1496`, `97d8710`, `e8ce6c9`, `86cb38f`. This session: `85a2b10`,
`9e6c255`, `b3fdf02`, `a656dfc`, `73fb8f9`, `8d360b7`; then the review's
fixes, `f72b6d3`, `8b5e946`, `e7c0cd6`, `bf419cc`, `c49d3ff`, `21096ce`;
and `dbf55cd`.

**What was done.**

- `README.md`'s roadmap is in the new order: operators 9, `outer` and the
  journal 10, the memory stage 11, `Async`, `Net` and `par_map` 12, then
  the milestone, then the C backend 13, `Alloc` 14, `unique` and layout
  15, simulation 16. Reference counting with reuse is part of the memory
  stage now, not a row of its own. Every stage number in the repository
  matches it, in the documents, the examples, the grammar's comments and
  the compiler's messages.
- `compiler.md` is written and linked from `README.md`: the pipeline, the
  principles, what each IR promises and what checks it, the no-cycles
  invariants and the continuation rule, the specialization decision, and
  R0 to R4. It says which of its promises are still to come.
- `module-build.md` says honestly what early cutoff still guarantees: a
  body edit changes the interface only when it changes what a public
  generic function needs of a type parameter, and dependents wait for a
  module's bodies, not just its declarations.
- CI on Linux and macOS; benchmarks in `bench/`; tail calls are a loop;
  call depth is limited; test helpers fail when an expected error doesn't
  come; `--help` and `--version`; the Zed extension's `rev` and
  `.gitattributes`.
- Core Lint checks the third no-cycles invariant: an `Instance` is only
  ever the end of a `Handler`'s body.
- Core snapshots in the tests number binders by first appearance, so a
  snapshot changes only when the Core does.

**Deviations.** None from the plan.

**Test outputs that changed.**

- `73fb8f9`: every Core snapshot in `test_lower.ml`, `test_deps.ml` and
  `test_ops.ml`, by the renumbering only, and the line breaks that follow
  from it. The review checked this mechanically: with ids and whitespace
  normalised the files are identical, and the old-to-new mapping of ids is
  one-to-one in every function.
- The stage numbers in two messages: operators "arrive in stage 9", and
  `outer` "comes with `outer` (stage 10)".

**Behaviour that changed.** A program that recurses more than 100,000
calls deep, not in tail position, now panics ("the stack overflowed")
where it used to run to the end in about a second; OCaml's own stack goes
much deeper than the limit. The plan allows it, and `compiler.md` says
so. `bf419cc` fixed a crash it caused: reaching the limit while `ren test`
made an associated value raised an OCaml exception, not a panic.

**Issues still open.** Minor only:

- `ren core`'s cram outputs still print raw binder ids; only the expect
  tests renumber them.
- The renumbering in `test/helpers.ml` would also renumber a module path
  segment that starts with a digit, `geo/2d`; no test has one.
- `e8ce6c9`'s subject starts with "WIP:", which history can't lose.
- `ren test --list` with no tests exits 1, which nothing documents.

## R1: Restructure, with no change in behaviour

**Commits.** `86ccbb1`..`9637c56`, 34 commits.

**What was done.** Every existing expect block and cram output is byte
for byte the same, and nothing was promoted.

- **The prelude is split.** `lib/core/intrinsic.ml` names each built-in by
  a variant, and `lib/core/prelude.ml` keeps the Ren source and each
  built-in's scheme, by that id. What the built-ins do when they run is in
  `lib/eval/builtins.ml`, an exhaustive match on the id. The AST, Core and
  values carry the id, not a string. Resolve, lower and Core Lint don't
  refer to `Value`, `Unix`, `Builtins` or `Eval`, even indirectly.
- **Members have a structured identity.** A path has a `member` part,
  `{ mname; overload }`, with `overload` always 0. Nothing builds a member's
  name from strings or splits one, and `Ast.short_name` is gone. Schemes,
  nodes, call-graph edges and interface members are kept in `Path.Map`s.
- **`infer_expr.ml` is split** into `infer_env` (shared types),
  `infer_report`, `infer_written`, `infer_lookup`, `infer_rows`,
  `infer_handlers` and the core, each with an `.mli` but `infer_env`.
- **Messages are worded in `infer_msg.ml`.** Inference passes it what it
  found. The help for a missing `->` is worked out from the type, not by
  rewriting its printed text.
- **Lower and exhaust read what inference decided**: which `match`es
  handle errors, which arms are `fail` arms, which `try`s unwrap a
  `Result`, which names in `Err` are tags. They no longer call inference's
  own functions.
- **The quadratic spots are fixed**: the driver's reachable interfaces,
  free and assigned locals, line splitting per span, and four more found
  on the way (`Diag.reported`, Core Lint's `value_order`, `load_all`).

**Deviations**, all in `compiler.md`:

- The intrinsic ids live in their own module, since the prelude depends on
  the AST, which now names an intrinsic by its id.
- The compiler is still one dune library, so "resolve, lower and lint
  don't link against runtime code" holds because none of them refers to
  it, not because the linker enforces it.
- A member is a path with a member part, rather than a record of its own,
  since every function identity was already a path.
- `infer_expr.ml` became seven modules, not four, with `infer_` names,
  since every module of the library shares one namespace.
- `Infer.found` now means what inference decided at a node, not only what
  a lookup found.

**Test outputs that changed.** None.

**Issues still open.** Minor only:

- `Builtins.args`, what `ren run` was given after `--`, is still a global
  `ref`, as `Prelude.args` was.
- A few messages still join a type's printed name and a member's with
  `.`, and pass words like "field" or "operation" as strings. That's
  printing, not identity.
- Dependency labels in rows are still `home.Name` strings: they're types,
  not members.

## R2: Typed Core

**Commits.** `0e1d896`..`6e8ca0b`, 16 commits.

**What was done.**

- `Ty.scheme` has a requirements slot, `reqs : (int * string) list`,
  canonical like `names`, and always empty.
- `instantiate` returns its substitution, in the order of the scheme's
  variables.
- `ty.mli`, `iface.mli` and `core.mli`.
- Every use of a polymorphic function, member, associated value or
  intrinsic carries its type arguments in Core, and Core Lint checks from
  scratch that the use's type is the callee's scheme at those arguments.
  Lint also checks a pattern's type isn't an error.
- `ren core --types` prints each function's type and each use's type
  arguments; `ren core` prints as before.
- The interpreter no longer works out types: `bind`, `resolve` and
  `ctx.tys` are deleted. A generic function takes a hidden descriptor
  parameter for each of its type variables, as the debug strategy passes
  evidence, and each use passes descriptors that lowering builds from its
  type arguments. Which types show themselves through their own `show`
  is decided by lowering, not by searching a type's members at runtime.
  Core Lint checks the descriptors against the type arguments. The
  benchmarks got faster.

**Deviations**, all in `compiler.md`:

- Type arguments sit on the use (`Global`, `Global_value`, `Intrinsic`),
  not on `Call`, since a function can be used without being called, and
  row variables get arguments too.
- Every generic function gets a descriptor for every type variable, not
  only those it shows.
- Descriptors aren't printed, even by `--types`, whose type arguments say
  the same; hidden type parameters have negative ids, so no local's number
  moved.

**Test outputs that changed.** None existing. New tests only.

**Behaviour that changed.** One, which no test covered before and a new
test pins: a generic associated value that stores `show`, `pub let
shower: fn(T) -> Str = show`, now shows a record by its shape, `{ id: 1
}`, where it used to show `Acc { id: 1 }`.

**Issues still open.** Minor only:

- The interpreter still turns a descriptor into a `Ty.ty` where a value is
  shown, and shown.ml substitutes a type's parameters into its fields.
  Neither matches a callee's scheme, so the done-when holds, but it's
  still type-building at runtime.
- `$start` calls `main` with a row argument that `$start`'s own scheme
  doesn't have, which `ren core --types` shows as `{..r}`.
- Core Lint's checks of `shows` fail with `failwith`, so their messages
  lack the usual "in `f`, at file:line"; and Lint checks that each listed
  type does show itself, not that every type that does is listed.
- A dependency operation's call carries no type arguments: Lint still
  checks it is some instance of the declared type.

## R3: One constraint solver

**Commits.** `d811c1a`..`3f381d1`, 31 commits: the solver in
`d811c1a`..`2968732`, the bugs in `b718670` (B1), `4275156` (B3),
`3ecabd4` (B4) and `0fd217b` (B5), and the two fix rounds,
`9efe477`..`3f381d1`.

**What was done.**

- **One constraint type**, `Infer_env.constr`, replaces the env's 14
  deferred queues. Inference adds a constraint where it meets one, and
  `solve.ml` (with `infer_declared.ml` and `infer_coerce.ml`) decides a
  group's constraints once its bodies are checked. `compiler.md`'s section
  on the solver says what constraints exist, how they're decided, and why
  the answer doesn't depend on the order they were met.
- **A failure changes nothing.** `Unify.atomically` tries a unification on
  copies first; the real one runs only if the copy succeeded. That covers
  `with` installs, joins and added errors, which used to fail partway.
- **Nothing is swallowed.** The failures the findings named are reported.
- **`infer_top`'s `check` went from about 590 lines to 65.** The
  `Unchecked` re-check of a module stays, justified in `compiler.md`: a
  dot call's callee is found only by checking it.
- **B1 fixed**: a written signature is instantiated at each use, so a
  generic function can be used at another type in its own group, `..e`
  rows included, and its type arguments are recorded.
- **B3 fixed** for arguments, arrays and `if`: a handler of several
  dependencies is taken as the one wanted, whichever comes first.
- **B4 fixed**: a call whose row ends in its caller's is accepted, and
  both its messages are right, with no doubled backticks and no advice to
  leave out a type that is already left out.
- **B5 fixed**: a set of tags written in `Err` is closed once its group is
  done, so `mk2` is what `ren types` prints, the comparison that can never
  be true doesn't compile, and a `match` with exactly the printed arms
  needs no `Err(_)`.

**Deviations**, all in `compiler.md`:

- The solver goes kind by kind, in an order fixed in `solve.ml`, and only
  inclusions and copies use a worklist. It's a phased solver more than a
  pure worklist one.
- A handler's coercion can't always wait for both sides: a `with`, a
  field, a method or a mismatch has to look into the type. One case still
  depends on order: a method two of a handler's dependencies both have,
  looked up before anything says which is wanted.
- B4 doubles a label as Koka's rows do, without keeping the copies apart:
  for a set of dependencies or errors, two copies mean one.
- B5 closes a written set when its group is done, after which it is a
  type like any other, so a kept set in a later group can still take its
  tags (see below).

**Test outputs that changed.**

- `test_deps.ml`, "where nothing says which, a handler of several is its
  own": the error for `pick` is gone. B3: deps.md says it is accepted.
- `test_deps.ml`, "a handler of several where something else is wanted":
  the `let p: Option<Rates> = o` case and its error are gone, moved to a
  positive test, since B3 accepts it; the error after it is on line 16, not
  18.
- `test_errors.ml`, "a tag of two shapes, learned once the group is done",
  a test R3 added: its note says "from the `fail` on line 1", not "from
  the signature", since the function declares no errors.

**Behaviour that changed**, besides the bugs:

- B5's closing is broader than the bug's example: `fn mk() = Err(A)` used
  where a `Result<Int, ! A | B>` is wanted is now rejected.
- Some mismatches blame another place: `same(counting_rates(2), 3)` blames
  the handler, and an `if` whose `then` is a handler of several blames the
  `then` branch.

**Issues still open.**

- **Blocking: a handler of several, once inside a value or a type
  variable, is fixed to the first dependency an argument asks for.**
  `Infer_coerce.taken_as` unifies the variable a handler of several was
  given to with the one dependency an argument wants, so the variable is
  that dependency everywhere, not only at that argument. Programs that
  compiled at `6e8ca0b` are rejected now, with poor messages ("expected
  `RateCalls`, found `Rates`", "nothing installs `RateCalls` before
  `main`"). Each of these ran before and is rejected now:
  - `let o = Some(counting_rates(2))`, then in `match o`, `Some(h) =>
    print(run(h) + run2(h))`
  - `let h = id(counting_rates(2))`, then `run(h)` and `with h in
    RateCalls.count()`
  - the same through an array, `[counting_rates(2), counting_rates(3)]`,
    and through an `if` of two handlers
  - `ap(counting_rates(3), fn(r) => run(r) + (with r in
    RateCalls.count()))`

  The reviewer's suggested fix: coerce the argument where it's passed, and
  leave the variable open for the solver, as is done when the handler's
  type is already known. Each repro above should become a test.
- **B5, the half that needs a decision.** A set kept by `attempt` can
  still take the tags of a written set from an earlier group: `fn kept(c)
  = if c then mk2(c) else attempt g()` gives `! Left(Int) | Right`, though
  errors.md says a kept set doesn't gain tags across groups. Rejecting it
  means keeping where tags came from in schemes and interfaces, while
  still letting a declared `Result`'s extra tags in, which the existing
  `worth_retrying` test needs. That's the owner's call.
- The worklist is quadratic: each decision rescans every waiting item.
  12,000 `try f(i)` calls in one group take 8.7s to check, against 0.3s
  before R3. Watching row tails by variable would fix it.
- `solve.ml`'s tag patterns unify payloads with `unify_at`, not
  atomically: a payload mismatch is reported, but can leave earlier
  payloads unified.
- The test "where nothing says which, a handler of several is its own"
  still holds `pick`, which is accepted now, so its name no longer says
  what it pins.
- A mismatch between two different handlers of several suggests writing a
  `counting_rates { ... }`, a type that can't be written. It predates R3.

## R4: Requirements and lambda sets

Not started.

## Notes for the next stage

- **Finish R3 first.** Fix the blocking issue above, with its repros as
  tests, get an independent review, then do R4 as the plan describes. The
  B5 question needs the owner.
- **R4 has its pieces in place.** Schemes have the `reqs` slot, uses carry
  type arguments, and generic functions already take hidden descriptor
  parameters, which dictionaries can follow: an `eq` dictionary is a
  descriptor that also says how to compare. Requirements are strings
  today, `"eq"`; a variant is a one-line change if R4 wants one.
- **The interface check in the driver** compares a public function's
  inferred scheme with its interface's. Once requirements are inferred,
  that check has to compare them too, and `module-build.md` already says
  what early cutoff guarantees.
- **The memory stage** will want the solver's order-independence to be
  real for lambda sets, which unify and include as rows do. The kind-by-kind
  order in `solve.ml` is the place to look first.

## For whoever runs the tests

As root, one test in `test/test_deps.ml` fails ("not allowed", near line
1104): root can write a file it may only read, so it prints "it wrote a
file it may only read" instead. Run the tests as another user, or restore
that line after a `dune promote`. In the cloud session this report came
from, `ren-test` did the first. The installed `ocamlformat` (0.29) also
formats differently from the owner's, so `dune fmt` over the whole tree
reformats files nobody touched: format only the files you change.

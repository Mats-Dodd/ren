# Stage 10.0: the report

What stage 10.0 did, step by step, and where it stopped. The brief is
[STAGE-10-0-PLAN.md](STAGE-10-0-PLAN.md), and the design it built is in
[compiler.md](compiler.md), whose Deviations section has every place the
work left the plan, with its reasons.

**The stage stopped after R3.** R0, R1 and R2 are done, each passed by an
independent review. R3's work is all in, but its last review still found
one blocking issue after the two fix rounds the plan allows, so, as the
plan says, R4 wasn't started. The owner then asked for that issue to be
fixed and the stage to go on: it's fixed now (`ad47c20`..`4d968ac`, see
R3), with three of R3's minor issues. R3's review of that found two more
blocking issues, a slowdown `4d968ac` brought back and messages that
blamed a handler falsely; they're fixed too (`435e869`..`11cbbe0`). Its
next review found that `435e869` made checking quadratic in the number
of handlers of several given before what's wanted was known; that's
fixed too (`11ae913`), and R3 waits for its review again. The branch is green: `dune build` and
`dune runtest` pass at every commit, run as a user that isn't root (see
"For whoever runs the tests", below).

| Step | Commits | Review |
|---|---|---|
| R0, foundations and safety nets | `849e97f`..`dbf55cd` (19) | passed after two fix rounds |
| R1, restructure with no change in behaviour | `86ccbb1`..`9637c56` (34) | passed first time |
| R2, typed Core | `0e1d896`..`6e8ca0b` (16) | passed first time |
| R3, one constraint solver | `d811c1a`..`3f381d1` (31), then `ad47c20`..`4d968ac` (5), then `435e869`..`11cbbe0` (3), then `11ae913`..`18a55bb` (2) | one blocking issue left after two fix rounds, **fixed since**; its reviews found three more, fixed; to be reviewed again |
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
`9efe477`..`3f381d1`. Then, after the stop, the blocking issue and three
minor ones, `ad47c20`..`4d968ac`, 5 commits; the two blocking issues
its next review found, `435e869`..`11cbbe0`, 3 commits; and the one the
review after that found, with a test for one of its minor issues,
`11ae913`..`18a55bb`, 2 commits; and B5's other half, once the owner
decided it should be fixed, `4037992`.

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
- **B5 fixed**, both halves: a set of tags written in `Err` is closed once
  its group is done, so `mk2` is what `ren types` prints, the comparison
  that can never be true doesn't compile, and a `match` with exactly the
  printed arms needs no `Err(_)`. And since `4037992` what an `attempt`
  keeps can't take such a set's tags in a later group either, or through
  a generic function of another module: the tags carry where they were
  written.

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
- B5 closes a written set when its group is done, and marks its tags,
  not its row as the report suggested, as written in `Err`, so a kept set
  in a later group that takes one none of its calls fail with is an
  error. Interfaces carry no mark: a public function declares its type,
  so such a set never leaves its module.

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
- After the stop (`ad47c20`): `test_deps.ml`, "a handler of several passed
  on inside its own `with`", a test the second fix round added: `k` is
  `fn k() -> Int`, not `fn k() -> Int uses RateCalls`, as it was at
  `6e8ca0b`. Nothing says what `o` holds is one dependency, so `with r`
  installs both, as deps.md says; the comment says so now.
- `0ce6468`: "where nothing says which, a handler of several is its own"
  no longer holds `pick`, which B3 accepts, and the "an `if` takes a
  handler of several as one in either branch" test covers; its two errors
  are three lines higher.
- `435e869`: "an `if` takes a handler of several as one in either
  branch": for `if true then counting_rates(3) else Clock.frozen(...)`
  the `else` branch is blamed, as at `6e8ca0b`, since it's met second,
  and keeps the note on what the handler implements, with help that says
  to change the `counting_rates(...)`. The error for the branches the
  other way round is unchanged.

**Behaviour that changed**, besides the bugs:

- B5's closing is broader than the bug's example: `fn mk() = Err(A)` used
  where a `Result<Int, ! A | B>` is wanted is now rejected.
- `4037992`: `fn kept(c) = if c then mk2(c) else attempt g()`, where `g`
  fails only with `Left(Int)`, is an error, "this `attempt` can't keep
  `Right`", with a label at the `Err(Right)` in `mk2`. So is the same
  through a function that passes `mk2`'s `Result` on, or a generic one,
  here or in another module. A declared `Result`'s extra tags are still
  taken, as `worth_retrying` needs. No existing output changed; a
  `fail` now adds its tag by inclusion, as a call does, which changes no
  message.
- Until `435e869`, a mismatch with a handler of several given where
  what's wanted wasn't known blamed the handler, met first, with a message
  about the other side that wasn't true (see below). Now it blames what's
  met second again, as at `6e8ca0b`: `same(counting_rates(2), 3)` blames
  the `3`.

**Issues still open.**

- **Fixed since the stop (`ad47c20`, `4d968ac`), was blocking: a handler
  of several, once inside a value or a type variable, was fixed to the
  first dependency an argument asked for.** `Infer_coerce.taken_as`
  unified the variable a handler of several was given to with the one
  dependency an argument wanted, so the variable was that dependency
  everywhere, and programs that compiled at `6e8ca0b` were rejected. Now,
  as the reviewer suggested, the argument is a coercion of its own and
  the variable is left to the solver: once the variable is decided, after
  it, the argument is taken as that one if the value is the handler, is
  it already if something said so, or is an error whose note says what
  took it as the other dependency, whichever was said first. Each repro
  runs as it did at `6e8ca0b`, with the same output, and is a test
  (test_deps.ml, "a value holding a handler of several, taken as each of
  them"; the error, both ways round, in "..., taken as one elsewhere"):
  - `let o = Some(counting_rates(2))`, then in `match o`, `Some(h) =>
    print(run(h) + run2(h))`
  - `let h = id(counting_rates(2))`, then `run(h)` and `with h in
    RateCalls.count()`
  - the same through an array, `[counting_rates(2), counting_rates(3)]`,
    and through an `if` of two handlers
  - `ap(counting_rates(3), fn(r) => run(r) + (with r in
    RateCalls.count()))`
- **Fixed since (`4037992`), was the half of B5 that needed a decision.**
  A set kept by `attempt` could still take the tags of a written set from
  an earlier group: `fn kept(c) = if c then mk2(c) else attempt g()` gave
  `! Left(Int) | Right`, though errors.md says a kept set doesn't gain
  tags no call fails with. The owner decided it should be fixed, and it's
  an error now, as the same `Err`s written in place were already. A tag
  the solver puts in a set of its own carries where it was written
  (`Types.label`'s `written`); instantiation keeps it, inclusion drops
  it, unification joins two labels' marks, so a tag is marked only if
  every label it's been unified with was, and a kept set holding such a
  tag that none of the
  inclusions into it brought in is reported (`solve.ml`,
  `written_kept`). A declared `Result`'s tags aren't marked, so
  `worth_retrying(attempt busy())` is still accepted. Interfaces needn't
  carry the mark, since a public function declares its type; such a set
  reaches another module's code only through its generic functions,
  which instantiation follows. compiler.md's B5 entry says how, and
  errors.md says the rule; tests: test_errors.ml, "a kept set doesn't
  take tags written in an earlier group", "... in another module", and
  "a kept set takes a declared Result's tags". A kept set equal both to
  a written set and to a declared `Result` takes the tags, whichever it
  meets first: R3's fourth review found that at first it depended on
  that order, since unification kept one side's labels, and the marks
  are joined now (test: "a kept set equal to a declared Result too takes
  its tags").
- Fixed since the stop (`73a710d`): the worklist was quadratic, and so
  was finding where a set's errors came from at every call, though only
  a message about a tag of two shapes needs it. 12,000 `try f(i)` calls
  in one group took 8.4s to check, against 0.4s at `6e8ca0b`; `73a710d`
  made it 0.4s again, but `4d968ac` brought the slowdown back, which the
  report said nothing of, and `51c9950` fixed it again (below).
  The worklist looks for what's woken once a round, not after every
  item, rather than watching row tails by variable: it's simpler, and the
  rounds go through what's awake in the order it was met, as before. A
  constraint woken by one met before it in the same round is done in the
  next round, which only changes the order things are decided in, never
  what they come to.
- Fixed since the stop (`1387d4c`): `solve.ml`'s tag patterns unify their
  payloads all at once on copies first, so a mismatch changes nothing;
  each payload that doesn't fit is still reported. No test could see the
  difference: a mismatch stops the program before anything reads the
  payloads again.
- Fixed since the stop (`0ce6468`): "where nothing says which, a handler
  of several is its own" no longer holds `pick`.
- **Fixed since R3's review after the stop (`51c9950`), was blocking:
  `4d968ac` made every argument look through the group's constraints.**
  `taken_as` looked for a handler given to the argument's type for
  nearly every argument, which goes through the group's constraints, so
  a group of calls checked in time quadratic in them: 24,000 `try f(i)`
  lines took 18s, against 0.6s at `6e8ca0b`. Now only an argument whose
  type is a variable a handler was given to, or another dependency than
  the one wanted, looks, and a variable a handler was given to is known
  at once (`Unify.watch`, below). The 24,000 lines take 0.7s, and 12,000
  `a + f2(i)` 0.3s, as at `6e8ca0b`. test_infer.ml, "a group of many calls
  checks in time linear in them", checks 36,000 calls in under 10s of
  processor time; they take about 1s now, and 45s at `4d968ac`.
- **Fixed since R3's review after the stop (`435e869`), was blocking: a
  later mismatch blamed a handler of several with a false message.** A
  handler given where what's wanted wasn't known yet waits for the
  solver, so when `b + 1` or `let n: Int = h` decided the variable first,
  the handler's coercion was what failed: "this element is a
  `counting_rates`, but the others are an `Int`" for an array of one, and
  the number of errors depended on the order of the statements. It dated
  from the first fix round. Now the variable a handler is given to is
  watched (`Unify.watch`): it can become only the handler or one of its
  dependencies, and anything else is a mismatch where it's said, which is
  then reported as at `6e8ca0b`. Every repro gives `6e8ca0b`'s output and
  is a test (test_deps.ml, "a handler of several, then said to be
  something else").
- Fixed since R3's review after the stop (`11cbbe0`): each `with` the
  solver installed picked the copies out of all the group's constraints
  again and recounted its shared rows, so 12,000 `with`s took 34s,
  against 6.2s at `6e8ca0b`. Now 4.3s. Deciding the copies before each
  `with` still goes through all of them, so it's still quadratic, as it
  was at `6e8ca0b`; deciding only the copies a `with` can wake would fix
  it.
- **Fixed since R3's third review after the stop (`11ae913`), was
  blocking: `Unify.watch` made checking quadratic in the handlers of
  several a group gives before what's wanted is known.** Each
  unification tried first copied the table of watched variables, and
  each use of such a variable as an argument looked for its handler
  among all the group's constraints. 8,000 `print(run(id(
  counting_rates(2))))` lines took 53s, against 0.5s at `6e8ca0b`;
  8,000 `Some(counting_rates(i))` and then 8,000 `try f(i)` 27s. The
  earlier timing test had no handler in it, so couldn't see it, and the
  report said the slowdown was fixed. Now the watched variables are an
  immutable `Map`, which a tried unification shares instead of copying,
  and each remembers the first handler given to it, so finding that
  handler, or settling the variable as it, costs the same however many
  there are. Only a value taken as two dependencies, which is an error,
  still looks through the constraints, once for that error. Each repro
  checks in about half a second, with the same output, and test_deps.ml,
  "many handlers of several given early check in time", checks three of
  them in under 10s of processor time each (23 to 27s before).
- **The rules for a held handler of several are uneven** (R3's third
  review, minor). A method only one of its dependencies has fixes the
  value to that one everywhere (`Infer_coerce.settle_for_member`, as
  deps.md says), while an argument takes it as one only there: with a
  method `twice` on `Rates`, `let h = id(counting_rates(3))`, then
  `h.twice()` and `run2(h)` is rejected, and `h.twice()` then `with h in
  RateCalls.count()` says nothing installs `RateCalls`; `let h =
  counting_rates(3); h.twice()` is rejected, but through `id(...)` it's
  accepted. Nothing that compiled at `6e8ca0b` is broken. `h.usd_to(1)`
  on such a value says `usd_to` is an operation of `Rates` (pinned by a
  test since `18a55bb`), which also fixes `h` to `Rates`, so a `run2(h)`
  elsewhere gets a second error that follows from the first. Making a
  member lookup take the value as one dependency only there would even
  them out.
- A mismatch between two different handlers of several suggests writing a
  `counting_rates { ... }`, a type that can't be written. It predates R3.

## R4: Requirements and lambda sets

Not started.

## Notes for the next stage

- **Finish R3 first.** The blocking issues above are fixed, with their
  repros as tests; get R3 an independent review, then do R4 as the plan
  describes. B5 is fully fixed (`4037992`).
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

# Stage 10.0: the plan, for whoever runs it

This file is the complete brief for stage 10.0 of Ren: what to build, the
decisions already made, the review findings it acts on, how to run it,
and where the work stands. A fresh session should be able to do the whole
stage from this file and the repository alone. Delete it in the stage's
last commit, once `STAGE-10-0-REPORT.md` replaces it.

## How to run it

- **Work on the `stage-10-0` branch** and push it regularly (`git push
  origin stage-10-0`). Never push to `main`: the owner merges the branch.
- **Do the steps R0 to R4 in order,** each fully before the next.
- **Review each step independently.** When a step is done, spawn a fresh
  reviewer that hasn't seen your reasoning, if you can spawn subagents.
  Give it the step's text below and the commit range. It runs the tests,
  checks the step's done-when criteria by reproducing them, and probes
  with small programs. If you can't spawn subagents, review it yourself
  as a separate pass, reading the diff from scratch.
  - Blocking means a real defect, a regression, an unmet criterion, or a
    broken principle. Style nits are minor.
  - Fix every blocking issue, with a test for each, then review again.
    Allow at most two fix rounds per step.
  - If a step still has blocking issues after two fix rounds, **stop**.
    Don't start the next step. Push, and write the report.
- **Write `STAGE-10-0-REPORT.md` at the end, or when you stop.** For each
  step, give:
  - its commits
  - what was done
  - deviations from the plan
  - test outputs that changed, and why
  - issues still open
  - notes for the next stage
- **The owner develops on macOS,** and CI runs on Linux and macOS. Avoid
  tests whose expected output depends on the platform. For example, how
  exec of a file that isn't a program behaves differs between Linux and
  macOS.

## Where it stands

R0, R1 and R2 are done. R3's work is in, but its last review left one
blocking issue after two fix rounds, so the run stopped there, as "How to
run it" says, and R4 wasn't started. `STAGE-10-0-REPORT.md` says what
each step did, its commits, what changed, and what's still open.

R3's blocking issue has since been fixed (`ad47c20`..`4d968ac`; the
report's R3 section says how), with three of its minor issues, and so
have the two blocking issues R3's next review found (`435e869`..`11cbbe0`).

**Next:** have R3 reviewed again, settle B5's open question with the
owner, then do R4. Delete this file once the stage is done.

## Context

Stages 1 to 8 are done:

- functions, records, sum types and exhaustive `match`
- HM inference, with row types for errors (`!`) and dependencies (`uses`)
- value semantics, with `var`, `inout` and `&`
- modules and methods
- errors (`errors.md`)
- dependencies, `with`, handlers and tests (`deps.md`; read its
  Deviations section)
- a thin slice of strings, `Fs`, `Os` and `Proc` (stage 8)

The next language stage is operators (`operators.md`; read it). Before it,
stage 10.0 lays the compiler's foundations. They're for operators, and
also for what follows: Perceus reference counting, reuse and
functional-but-in-place, borrow inference, and lambda set specialization
with defunctionalization. First read:

- `README.md`: its status, the memory and allocation sections, and the
  roadmap
- `module-build.md`
- `operators.md`
- `deps.md`
- `errors.md`

### The owner's prior-art research

His notes file isn't in the repository. These are the key points:

- **Values and storage are different.** A functional update promises that
  old observable values don't change, not that it uses fresh storage.
  Owned isn't unique: ownership lets you transfer or release a reference,
  and uniqueness lets you change the allocation.
- **Perceus (Koka)** inserts precise reference counting into a functional
  core with explicit control flow, so `dup` and `drop` are explicit
  internal operations. Then come:
  - drop specialization
  - RC cancellation
  - constructor reuse: a unique cell's shell is kept for the next
    constructor of a compatible layout, and a shared cell gives a null
    token
  - reuse specialization

  Uniqueness is per allocation: a unique root can have shared children.
  Freedom from garbage holds for a cycle-free core.
- **Lean** infers borrows before inserting reference counts, then does
  reset and reuse and coalesces count operations. Arrays it holds
  exclusively are updated in place.
- **Morphic (2026)** infers borrows with lifetimes fully automatically. On
  its benchmarks that gave 75–100% fewer increments and a 1.48× speedup.
  No lifetimes written by the user doesn't mean no lifetime analysis.
- **Fewer count operations can hold more memory,** and reuse delays
  freeing. Keep five metrics distinct:
  - how many allocations
  - how many count operations
  - the most memory held at once
  - the deepest the stack goes
  - how much work freeing does
- **FBIP and FIP (functional but in place).** Zippers reuse tree nodes as
  context frames. FIP's credits are concrete reusable cells, not byte
  budgets.
- **Lambda set specialization** (PLDI 2023, used by Roc and Morphic):
  - It tracks which lambdas can reach each function type, through the
    polymorphic type system. Specializing higher-order code then becomes
    monomorphization.
  - Closures are defunctionalized into tagged unions with an apply
    switch. Captured values stay runtime data.
  - Its limits: recursive closure environments, dispatch that remains,
    code size, and separate compilation.
  - Roc found it hard to retrofit lambda sets and typeclass
    specialization.
- **Specialization and ownership reinforce each other.** A known callee's
  body shows whether it borrows, consumes or keeps its argument, and that
  allows more reuse.
- **What this means for Ren:**
  - Ordinary code infers ownership and reuses memory when it can.
  - Strict hot paths need contracts that are checked, never ones that
    depend on an optimisation. A dynamic uniqueness check can't justify
    "no `Alloc`" unless the shared path is ruled out.
  - Allocation effects are checked after memory lowering.
  - Known handler implementations are a chance to specialize, with a
    budget and a defined fallback.
  - Keep the internal facts distinct:
    - effects: what may happen
    - lambda sets: what code may run
    - ownership, lifetimes and reuse credits
    - provenance: which allocator owns the storage

### The target pipeline (10.0 builds its front half)

```
per module, incremental
  parse -> resolve -> infer (ONE solver: types, ! rows, uses rows, requirements, lambda sets)
        -> typed Core (every node typed; type arguments, requirement dictionaries and evidence explicit)
whole program, later stages
  -> specialize (types, requirements, lambda sets, known handlers) -> defunctionalize
  -> Mem IR (every value named, explicit layouts)
  -> borrow inference -> Perceus dup/drop, reset/reuse -> resource checks (Alloc, unique)
  -> instrumented interpreter, then C
```

### Decisions settled with the owner

- **Lambda sets go in the type system now,** as a hidden third part of
  function types beside `!` and `uses`, inferred by the same solver.
  Code generation doesn't use them until the specialization stage, but
  Core Lint checks them.
- **Debug builds pass requirement dictionaries and evidence as hidden
  parameters.** Release builds will specialize the whole program, with a
  content-addressed cache, a budget and a fallback. Both mean the same
  thing.
- **Requirements on type parameters are inferred everywhere, and never
  written,** public functions included. So a module's interface now
  comes partly from inference.
  - `module-build.md` says the interface comes from declarations alone
    and that early cutoff is guaranteed. Amend that honestly: a body edit
    changes the interface only when it changes what a public function
    needs of a type parameter.
- **The order of the stages:**
  1. operators (stage 9)
  2. `outer` and the effect journal (10)
  3. a new memory stage: specialization, defunctionalization, Mem IR,
     borrow inference, Perceus and reuse, run by a new instrumented
     interpreter (11)
  4. `Async`, `Net` and `par_map`, built on that interpreter, from a
     design document written first
  5. the milestone: a small web service and its tests run
  6. the C backend, which becomes "emit the Mem IR"
  7. the existing later stages, renumbered

### Principles (write them into `compiler.md`, and follow them)

1. **Guarantees never depend on an optimisation.** No-`Alloc`, `unique`
   and transparency rest on checked rules. Specialization and
   opportunistic reuse only make code faster.
2. **Each fact is computed once, by one pass, and carried explicitly in
   the IR:** types, effects, requirements and lambda sets now; later
   ownership, lifetimes, reuse and provenance. Nothing downstream
   reconstructs one.
3. **Every IR has a checker,** as Core Lint is for Core.
4. **The five resource metrics are distinct.**

### No cycles (write it into `compiler.md`)

Perceus's freedom from garbage depends on three invariants:

1. **Values are never changed in place once shared.** `a.next = Some(a)`
   stores a copy.
2. **Closures don't capture the evidence vector.** They get their
   dependencies where they're called.
3. **An installed handler instance is never a value.** `with` installs
   it, no expression gives it back, and its own dependencies are captured
   from further out.

So a handler's `var`s can't reach their own instance. Core Lint should
check the third.

For later stages: a handler's state can never hold a suspended
continuation. Fibers belong to the scope of structured concurrency, which
the runtime owns.

## Review findings this acts on

Check the line numbers, which may have drifted.

### Architecture

- **Core carries no types.** So eval re-substitutes the callee's type at
  every `Call` (`eval.ml` ~319), and rebuilds type environments (`bind`,
  ~490). That's only so `show`, `assert` and `own_show` (which finds a
  method named `"show"` at runtime, ~506) know the types.
- **`equal` (~53) is structural,** ignores `key`, and panics on functions.
- **`Ty.scheme` is just `{ty; names}`** (`ty.ml` ~55), and `instantiate`
  (`types.ml` ~238) doesn't return its substitution.
- **Members are dotted-string paths,** split up again (`resolve.ml` ~127,
  `Ast.short_name`).
  - Schemes and nodes are association lists (`infer.mli` ~48/53,
    `driver.ml` ~96/106, `lower.ml` ~931).
  - `Iface` members are a flat `op` list (`iface.ml` ~71).
  - So two methods with one name can't be represented.
- **Core has `Prim (Binop of Ast.binop)`** (`core.ml` ~47), which eval
  handles for `Int` only.
- **`prelude.ml` is in `core/`, but `builtin_fn` carries an `eval`
  closure and `Unix`** (`prelude.mli` 9–16). So resolve, lower and lint
  depend on runtime code. Intrinsics are looked up by string, one at a
  time (`core.ml` ~79, `prelude.ml` ~806).
- **`Diag` has no severity.** An unused import is fatal, and it's
  reported before exhaustiveness is checked (`driver.ml` 65–67).
- **Lower calls `Infer_expr.handles` and `is_fail`** (`lower.ml`
  ~281/373/556), deciding again what inference already decided.
- **No `.mli`** for `infer_expr`, `infer_top`, `types`, `ty`, `iface`,
  `core` or `ast`.
- **Quadratic spots:** `driver.ml`'s `reachable` (`acc @ [i]`),
  `lower.ml`'s free variables (`List.mem`), and `Diag.line_text` per
  span.
- **Evidence is a runtime list,** searched by path (`eval.ml` ~244).

### Sema

- **`unify.ml` and the level-based HM are sound and clean.**
- **`env` (`infer_expr.ml` ~54–133) holds 14 mutable queues of deferred
  work:** joins, drops, forced, unmarked, all_markers, kept, includes,
  tag_patterns, rows_due, impl_ops, installs, copies, handler_needs and
  withheld.
  - Each has its own settle pass in `infer_top.ml`, in an order fixed by
    hand (~2167–2185).
  - Errors and `uses` are inclusion constraints, solved by fixpoints that
    copy labels (`settle_inclusions` ~625, `settle_copies` ~1161).
  - Some unification failures are swallowed (~997, ~1138).
  - A unification that fails partway isn't rolled back (`settle_installs`
    ~1201).
- **`infer_top`'s `check` is about 590 lines** (~1847–2440), with help
  text built by substituting into strings (~2027–2085).
- **The handler `as_one`/`taken_as` coercion** (`infer_expr` ~1489–1511)
  depends on order.
- **`unifies` (~408–630) is mostly diagnosis,** and about 167 `sprintf`s
  live outside `infer_msg`.
- **The `Unchecked` exception re-checks the whole module** (`infer_top`
  ~2440).
- **A suggested split of `infer_expr`:** `row_effects.ml`, `handlers.ml`,
  `lookup_through_type.ml`, and the core of inference.

### Bugs

**B1: A generic function with a written signature can't be used at
another type by a function in its recursive group.**

- Cause: lookup returns the declared type with its skolems still rigid
  (`infer_expr`, `Global p when List.mem p env.spelled`).
- Repro: `fn first<T>(xs: Array<T>, n: Int) -> T = ... xs[g(n)]` with
  `fn g(n) = first([1,2,3],0) * 0` gives "expected `T`, found `Int`". The
  same happens with a named error row, `..e`.
- Fix: instantiate the written signature at each use.

**B2: `==` type-checks on functions, and panics at runtime.** `synth`'s
`Eq | Neq` case puts no constraint on the operand type. R4 fixes it, with
the `eq` requirement.

**B3: The handler coercion depends on argument order.**

- With `fn same(a, b) = if true then a else b`,
  `same(Rates{...}, counting_rates(2))` is accepted.
- `same(counting_rates(2), Rates{...})` is rejected.

**B4: A legitimate private function is rejected.**

- Repro: `fn twice(k) = { let a = run(k); a + k() }`, where `run` installs
  `Rates`.
- Cause: the rows of `k` and `twice` share a tail, so Rémy's side
  condition fails. Rows that allow a label twice, as Koka's do, accept
  it.
- Its message (`join_uses` ~1212):
  - prints doubled backticks around a raw path
  - says "leave the type out and let it be inferred", though it is
    already inferred
- `settle_installs` has the same doubled-backtick bug: it passes names
  that are already quoted to `and_list`.
- Neither message is tested.

**B5: An error set made only by tags written inside `Err` stays open
after its group.**

- Cause: `value_tags` adds tags to an open row and never closes it.
- Repro: `fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)` is
  generalised with an open row, though `ren types` prints it closed.
- Effects:
  - A set kept by `attempt` gains tags across groups, which `errors.md`
    says can't happen.
  - `mk2(true) == attempt g()` compiles, though it can never be true.
  - A `match mk2(true)` with exactly the printed arms still asks for
    `Err(_)`.
- Fix: close such a set once its group is settled, as kept sets are.

### Tests and tooling

- `differential.py` compares only whether both parsers accept a program,
  not what they read.
- Every grammar change needs a Zed `rev` bump, and commits a regenerated
  `parser.c`.
- Integer arithmetic silently wraps at 63 bits. Overflow panics are stage
  9 proper, and `42e1496` pins today's behaviour with a test.
- About 500 rendered errors live in expect blocks, so a promote can
  silently accept a lost negative test. The `bef1802` helpers address
  that; use them.
- Core snapshots print binder ids (`p/1`, `ev/4`) that change whenever
  numbering does.
- `test_deps.ml` is 5,700 lines.
- `has_main` catches every exception.
- The README advertises `ren fmt`, which doesn't exist.

## The steps

### R0: Foundations and safety nets

Most of this is done (see "Where it stands"). In full:

- **Write `compiler.md`** in the repo root, in the voice and structure of
  `deps.md` and `operators.md`. Link it from `README.md`. It covers:
  - the pipeline above, with which IRs exist today and which come later
  - the principles
  - what each IR guarantees, and which checker checks it
  - the no-cycles invariants and the continuation rule
  - the specialization decision: debug dictionaries and evidence, and
    release specialization with a cache, a budget and a fallback
  - the 10.0 plan, R1 to R4
- **Amend `module-build.md` for inferred requirements.** Say honestly what
  early cutoff still guarantees.
- **Update `README.md`'s roadmap to the order above.**
  - Renumber stages consistently in `README.md`, `deps.md`,
    `operators.md`, `runtime-io.md` and `stdlib.md`, and in any stage
    numbers the compiler prints in messages or comments, as commit
    `9965ef7` did.
  - Add rows for "`outer` and the journal", the memory stage and the
    `Async` stage.
- **CI:** `.github/workflows/ci.yml`, a macOS and Linux matrix:
  - `setup-ocaml` and the opam dependencies
  - `dune build` and `dune runtest`
  - the grammar's checks: node and `tree-sitter-cli`, mirroring
    `editors/tree-sitter-ren`'s Makefile
- **Benchmarks** in `bench/`, the quadratic interpreter fixed, and deep
  recursion reaching its panic promptly. Done.
- **Test helpers** that fail loudly if no error is produced. Done.
  Normalise binder ids in printed Core in tests, if it's cheap.
- **The Zed URL and `.gitattributes`.** Done.
- **The CLI.** Done.

### R1: Restructure, with no change in behaviour

**Done when** every existing expect block and cram output is
byte-identical: no promote of changed output at all.

- **Split the prelude.**
  - Static intrinsics, named by a variant or id and holding types only,
    stay in `core/`.
  - Runtime implementations move to `eval/` (e.g. `eval/builtins.ml`).
  - Resolve, lower and lint no longer link against runtime code.
  - Intrinsics are looked up by id, not by a linear search of strings.
- **Give members a structured identity:** a member is `{owner; name;
  overload}`. The overload index is for the later per-right-hand-type
  operators, and is always 0 for now. Keep schemes, nodes and interface
  members in `Map`s keyed by it, not in association lists or dotted
  strings.
- **Split `infer_expr.ml` by concern:** rows and effects, handlers,
  lookup through types, and the core of `check`/`synth`.
- **Move message wording out of inference into `infer_msg`.** Inference
  passes structured data.
- **Stop lower deciding again what inference decided.** Remove
  `lower.ml`'s calls to `Infer_expr.handles` and `is_fail`, by recording
  those decisions in the inference result.
- **Fix the cheap quadratic spots** named above.

### R2: Typed Core

**Done when:**

- Core Lint checks every node's type.
- Eval no longer substitutes or rebuilds types at runtime. The
  `bind`/`resolve` machinery is deleted.
- `show`, `assert` output and `own_show` behave as before.
- All existing outputs are unchanged. Core printing may gain type
  annotations only behind a flag or in a separate printer, so existing
  `ren core` snapshots don't change, unless a change is deliberate and
  explained.

**The work:**

- Every Core node and binder carries its `Ty`.
- Calls of polymorphic functions carry explicit type arguments.
- `Ty.scheme` gains a requirements slot, empty for now.
- `instantiate` returns its substitution.
- Add `.mli` files for `Ty`, `Iface` and `Core`.

### R3: One constraint solver

Replace the 14 deferred queues with one constraint representation and a
worklist solver, run once per call-graph group. It:

- covers type equality, `!` and `uses` rows (inclusion constraints),
  handler coercions, and the other deferred checks
- reports every failure, swallowing none
- doesn't depend on order

Fix B1, B3, B4 (including its message) and B5, each with a regression
test.

Existing outputs may change only where a bug is fixed, or an error message
is genuinely improved. List every changed output and why.

### R4: Requirements and lambda sets

**Lambda sets.** Every function type gets a hidden lambda-set component,
inferred by the solver.

- Each lambda, and each top-level function used as a value, has an
  identity.
- Sets unify and include as rows do, and generalise like rows.
- They're carried in typed Core and checked by Core Lint.
- They're invisible in `ren types` and in messages by default. An
  internal debug printer may show them.
- Nothing consumes them yet.

**Requirements, proven with `eq` only:**

- `==` and `!=` create an `eq` requirement on the operand type.
- `eq` is derived structurally, and a type containing a function has no
  `eq`.
- A generic function's `eq` requirement on a type parameter is inferred,
  for public functions too, and stored in the scheme and the module's
  interface.
- A call site checks that the instantiated type has `eq`. The message
  reads like "`fn(Int) -> Int` has no `==`, which `same` needs", with a
  note that a type with a function in it has no `==` or `hash`. This
  fixes B2.
- Requirements compile to hidden dictionary parameters in Core, as the
  debug strategy says. Eval uses them, not a runtime structural walk that
  panics.
- `ren types` shows requirements as `operators.md` describes:
  `same<T has eq>`.

**Interfaces:**

- Requirements in interfaces come from inference.
- The implementation tier records the bodies of public generic and
  higher-order functions, stored for specialization later.
- Adjust `module-build.md` if R0's wording needs it.

## Rules

- **Commits:**
  - Commit to the `stage-10-0` branch only, in small commits, and push
    it.
  - Keep `dune build` and `dune runtest` green at every commit, and `make
    check` in `editors/tree-sitter-ren` green at every commit that
    touches syntax.
  - Run `dune fmt` only on the files you touch, and revert reformatting
    of files you didn't.
  - For large refactors, prefer several mechanical commits to one huge
    one.
- **Commit messages** follow the repo's style: an imperative subject and a
  short explanatory body, ending with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- **Code reads like the surrounding code:** the same comment density and
  voice, and the same naming. The owner is new to OCaml, so a new idiom
  gets a one-line explanation. Every error explains why, and suggests a
  fix.
- **Determinism:** nothing output-facing depends on `Hashtbl` order, and
  there's no global mutable state.
- **Don't build beyond the step.** If the plan is wrong somewhere, make the
  smallest sensible deviation, record it in `compiler.md` (or in
  `deps.md`'s Deviations, as fits), and report it.

# Brief: stage 12a, the shape machinery

You're building what every stage 12 library stands on: the top level as
build time (top-level `let` and `assert`), the signature `let`,
templates, `T.shape` and `D.shape`, looks, `shape.through`, the doors
`build` and `view`, `Value`, `ren explain` and freezing, and std's
`json`, `cli` and `bin` written over them. The design is
[shapes.md](../shapes.md) and [formats.md](../formats.md)'s looks, with
[strings.md](../strings.md)'s templates and
[module-build.md](../module-build.md)'s prelude. It's part a of
foundations.md Staging item 10 (stage 12). Part b is http, sql, sqlite,
log, config, `Decimal`, `Secret`, property tests and fuzzing, all built
on this.

Ren is a systems language whose compiler is written in OCaml. Work on
`main`. This brief is self-contained: it names everything you need in
the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**The design is decided.** This stage builds it; it doesn't reopen it.
Where the docs are silent, make a choice, record it in compiler.md, and
list it in your final report.

**The interpreter is the reference.** Build time runs in the
interpreter in every build. Everything sequential also builds natively,
and every native build agrees with `ren run`.

## The line between 12a and 12b

12a is the language and the compiler's part, plus enough std to prove
it: a program can decode and encode its own types as json, read its
arguments with `cli`, and send values between its own processes with
`bin`. Anything that names a medium beyond those three, or reaches a
database or the network, is 12b's.

## Read first

- **shapes.md**, all of it. It's the spec. Note "When each part lands":
  12a's row, plus `T.shape`, `json` and `cli` from the standard library
  row. The `D.Call` row is built already (below).
- **formats.md**: "A type, and its formats", every "Looks of ..."
  section, "What a look can expose", "Errors carry paths", "Versions are
  looks", "Looks checked when building", "Look errors", "Layer 1: the
  derived encoding", "How looks compile", "Tools over looks", "std's
  policy for looks" (json and text media), "Left out".
- **strings.md**, "Templates" (the six rules, the site, `site.id` and
  `site.hash`) and "Literals" (`t"""..."""` and `t#"..."#`).
- **module-build.md**, "A small, fixed prelude" and "Incremental by
  construction": the seven rules and the edit test.
- **stdlib.md**: "Four rules", Part 6 (rule 3, hard, checked at link),
  "Snippets" (json, `Value`, `json.Raw`), the roadmap's stage 12 row,
  and "Open questions" (what's settled about `Alloc`).
- **foundations.md**: decisions 4 (a closed world), 13 (two builds;
  debug never specializes), 14, and 20 (the five rules; the toolchain
  reads the language, never a library).
- **compiler.md**: "Specialization" (the two known breaks of the
  incremental rules; don't add a third), "Native slice", "Data stage"
  (record update and patterns, which field defaults meet), "Patterns
  stage" (the perfect hash that a release decoder's key switch uses),
  "Services stage", "`D.Call` (step 6)", and "Runtime core stage",
  "Binary journal" (the derived `bin` bytes and canonical shape bytes).
- **research/looks/feasibility.md**: what the compiler has and lacks,
  piece by piece, with sizes and the files each touches. Rerun its
  probes in feas/ first: some have changed since. Also synthesis.md and
  effect-study.md there.
- **research/templates/**: synthesis.md and verify.md, the lowering and
  the numbers the template kernels were measured at.
- **bench/native/README.md** for how to measure.

## Scope

**In:**

1. **The front end's prerequisites** (feasibility.md's pieces 1, 3 and
   7): explicit type arguments at a call, `f<T>(x)`, `json.decode<T>`,
   `shape.through<T>`, in the parser, Infer and the grammar; default
   values on record fields, `source: Source = Web`, used by
   constructors, record literals and the doors; `parse` and `repr` as
   reserved members, pure, `parse`'s parameter type being what `repr`
   returns.
2. **The top level is build time** (shapes.md): top-level `let` and
   `assert`, run in the interpreter while building, in an order worked
   out from what each uses, a cycle an error; `try` at the top level
   failing the build with the error; the step limit, per value, an error
   naming the value, its steps and the limit; a value holds data, never
   a block. Natively, each value is data in the binary and nothing runs
   at startup. **`f.uses`,** the inferred set, so `assert
   handle_request.uses <= [Sql, Clock, Console]` fails with the path the
   dependency is reached by.
3. **The signature `let` and templates** (strings.md): a `let` between
   a signature and its `=`, run while building once per call site,
   reading only what's known then; its two refusals with help.
   `t"..."` in every literal form as `Template<H>`, its site and holes,
   the block rule, `render`, `site.id` and `site.hash`.
4. **Shapes and looks:** `T.shape` and `D.shape`; the `shape` module
   with `Shape`, `Field`, `Case`, `Ref`, `Value`, `Problem`,
   `LookError` and `Limits`; `format NAME for T = ...` looks (scalar
   `via`, record lines, sum tags with holes, opaque types, `reads` and
   `writes`), every declaration check of formats.md with its help;
   `Look` as a value; `shape.through<T>(looks)` in the walk's order;
   the doors `build<T>` and `view<T>`, absence at the door, first
   problem or all; `ren explain V for T`.
5. **std's `json`, `cli` and `bin`,** written in Ren over
   `shape.through` and the doors, in std's policy (shapes.md, "std's
   policy for the walk"; formats.md, "json" and "Text media"):
   `json.settings`, `decode<T>`, `encode`, `decode<Value>`, `json.Raw`,
   `Limits` as `limits:`; `cli.spec<T>`, `cli.parse<T>`, subcommands
   from sums, choices from fieldless sums, did-you-mean, help from
   docs, `cli.parse<Keys.Call>`; `bin.encode` and `bin.decode<T>`, no
   looks, the runtime core's derived bytes.
6. **The prelude** (module-build.md): it holds what the language names.
   `Clock`, `Random`, `Net`, `Fs`, `Os` and `Proc` are imported,
   `Time` and `Instant` with `Clock` from `std/clock`, `Duration`
   stays; `actors`, `striped` and `Instances` are imported from
   `std/actors`, and `retry` from `std/retry`; `Send<T>` stays, as
   part of `Async`'s surface; each missing import an error whose help
   writes it.
7. **Natively:** shapes, the doors, json, cli and bin in every build;
   in release, copies keyed on a known constant argument, the
   library's `match` over a constant `Shape` unfolded (or the visitor
   fallback), and the 1.5× measurement.
8. **Freezing:** `ren formats freeze V`, formats.lock, the fingerprint
   of shapes.md's "Freezing what is sent", the IR hash.

**Out (don't start them):**

- **12b:** http, sql, sqlite, log, config, msgpack, toml; `Decimal` and
  its literal; `Secret`; property tests, `arbitrary`, the generated
  round-trip test per look, `ren fuzz`.
- **The build's world:** `Fs` and `Git` at the top level, the build's
  journal, caching top-level values, granting. They land with packages
  (shapes.md, "When each part lands"). 12a's top level is pure.
- **`ren.toml`.** It comes with packages; until then the step limit is
  its default.
- **`Alloc`,** inferred or written. Left to 12b (Decided).
- **`D.Reply`, `D.Error`,** the `remote` header word, route and status
  looks, the wire envelope, `http.client<D>`.
- **Layouts:** `format disk for PageHeader, le, ...`, views, `.size` and
  `.offset` (Staging 7b, part two). 12a's `format` parser reads the
  kind off the lines and refuses a layout line, saying it isn't built
  yet.
- **`T.size`** (the memory stage), hover (there's no language server),
  `ren review`'s warning for a look no walk reaches (Ren has no
  warnings yet).
- **`D.Call`, `call(c: D.Call)` and `operations(h)`.** The services
  stage built them. Use them; don't rebuild them.
- Rule 3's link check: it guards `foreign fn`, which isn't 12a's.
- Fixing specialize.ml's two known breaks. Don't add a third.

## Working beside the other stages

The **generators stage** (briefs/stage-generators.md, part one) and the
**runtime core stage** (briefs/stage-runtime-core.md, part one) are on
`main` now, and their part twos may follow.

- **Yours:** the front end's top-level and signature `let` machinery,
  explicit type arguments, field defaults, `parse` and `repr`, the
  `format` item and looks, the `t` prefix in the lexer, `Template`,
  shapes and the `shape` module, the doors, `f.uses`, `ren explain`,
  `ren formats freeze`, the prelude's contents (what's visible without
  an import, and where `import std/...` finds the rest), std's `json`,
  `cli`, `bin` and `shape` modules in lib/core/std_lib.ml, the constant
  argument key in specialize.ml, tests and kernels you add.
- **Theirs, don't touch:**
  - the runtime core: lib/native/runtime/, the call record and
    `ren_carry`, the binary journal's format, lib/eval/journal.ml,
    sched.ml and family.ml, the lowering of tasks and coloured
    functions, `trust` and `foreign`, the drivers and the world's
    handlers, and **the derived `bin` bytes and canonical shape bytes**
    in compiler.md's "Binary journal", with the one helper that owns
    them;
  - generators: the streams module, `gen fn`, `yield`, chains, the
    default stages in the prelude, the interpreter's generator frames,
    `Async.merge` and `Async.expand`, `Fs.line_reader` and `Fs.lines`.
- **`bin` is the journal's encoding, not a second one.** The runtime
  core's part one derives a `bin` encoding from each type's structure
  for journal content until looks exist. std's `bin` must give the same
  bytes for every type: one encoding, specified once in their table,
  written twice (their carry code, your Ren). Share golden vectors with
  them, and use their shape-hash helper for the doors' keys; don't
  write another. If their table and the walk disagree, record it and
  stop for the owner (Risks).
- **The prelude change touches their declarations.** The world's
  handlers become `trust` handlers in their step 1, and generators adds
  `Fs.line_reader`. So the prelude step changes what's visible, not
  where things are declared: a declaration keeps its place and its
  path in prelude.ml, and `import std/clock` finds it there. Moving the
  text into std modules waits until both stages have landed.
- **Shared files** (ast.ml, parser.ml, lower.ml, to_mem.ml, emit_c.ml,
  prelude.ml, std_lib.ml, builtins.ml, walk.ml, specialize.ml,
  infer_*.ml, eval.ml): add your cases; don't move, rename or
  restructure code there. If you need a change that would, stop and say
  so in the progress log.
- **New tests go in new files.** Don't rewrite existing tests. The
  prelude step may add an import to a test's program, and nothing else
  (step 6).
- **Rebase before every push.** If a conflict touches their work, keep
  theirs and redo yours on top. If a check goes red because of their
  commits, record it in the progress log and don't fix their work.

## Steps

Do them in order. After each step THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, baseline, tests first.** Add a "Stage 12a" section to
   compiler.md. In it, settle:
   - **The grammar and the AST:** top-level `let` and `assert`; the
     signature `let`; explicit type arguments, and how `f<T>(x)` is
     told from `a < b > c`; field defaults; the `format` item, its
     record and sum lines, `via`, `reads` and `writes`, as contextual
     words so no program's names break; `t` before every literal form.
     The tree-sitter and Zed changes for each.
   - **Build time:** how the driver finds the top-level values and
     orders them; the step counter in eval.ml and the default limit,
     calibrated to about a second of interpreted work on this machine
     and written as a number of steps; how a computed value reaches
     Core (a constant node, or constructor expressions); how it's laid
     out natively as static data, uncounted as a literal is, and what
     a `Map` or `Set` in one does, since a map's hash seed is drawn when
     the process starts; which of `ren check`, `ren run`, `ren test`
     and `ren build` run top-level values (all of them: an `assert` is a
     check).
   - **The signature `let`:** what it may read; how a call site's
     result reaches the body (debug: a hidden argument pointing at the
     site's static data, one copy of the callee; release: a copy keyed
     on it); each refusal with its help; its own step limit per site.
   - **Templates:** `Template<H>`, the site's fields (parts, raw parts,
     each hole's source text and static type, `id`, `hash`), how the
     block rule keeps one from being stored or returned, `render`, and
     the two-word lowering natively.
   - **The `shape` module:** every type in full (`Shape` with `Ref`,
     `Const`, `Sum`, `Text` and the rest; `Field`, `Case`, `Value`,
     `Problem`, `LookError`, `Limits`); where `Field.doc` and
     `Case.doc` come from (the `//` lines above the field or case, which
     cli's help prints); `T.shape` and `D.shape` (a
     dependency's operations: each one's name, parameters as fields,
     result and errors), and how a debug build reads either from the
     descriptors it already passes; what `f.uses` is as a value, `<=`
     and `includes` on it, and how an `assert` over it prints the path.
   - **Looks:** a `Look`'s representation, by its qualified path, never
     a number the whole program assigns; each declaration check with
     its error and help, worded from formats.md's "Look errors";
     `shape.through`'s algorithm, step by step in the walk's order; the
     doors as a Lower request per (type, look set), keyed by the type's
     shape hash and the look set's.
   - **json, cli and bin:** each one's API, in Ren signatures, and
     each policy rule of shapes.md and formats.md it keeps; `bin`'s
     bytes by reference to the runtime core's table, with the golden
     vectors.
   - **The prelude:** a table of every name the prelude has today and
     where it goes: stays, `std/clock`, `std/random`, `std/net`,
     `std/fs`, `std/os`, `std/proc`, or stays for now (Decided), and
     each type and test handler that moves with its dependency.
   - **Release:** the constant argument in specialize.ml's key, the
     copy named by its key (not by `fresh_path`'s order), the
     unfolding of a `match` over a constant `Shape`, and the visitor
     fallback as shapes.md describes it.
   - **Freezing:** formats.lock's form, what the fingerprint holds, the
     IR hash over Core's printed form, the error when it changes.
   - **Every compile error** this stage adds, with its help.

   **Baseline:** bench/native/json, `Order` (formats.md's, with
   `OrderId`, `CustomerId`, `Money`, `Time`, a sum and an `Option`)
   decoded and encoded by a decoder written by hand in Ren today (a
   tokenizer, and a string `match` on keys), with a Rust twin on
   serde_json and a Go twin on encoding/json; the template kernels of
   research/templates/verify.md (a log line, an HTML row) rebuilt here;
   `ren check` and `ren build` times for examples/just, examples/docs
   and examples/server, so build time's cost shows; bench/native's
   sequential kernels (none may regress past noise).

   **Tests,** marked skipped or expected to fail until their step:
   test/test_shapes.ml with `until "s1"` ... `until "s8"`, and
   bench/shapes.t (the interpreter, native debug, release under the
   sanitizers, tcc, `ren run --release`). At least:
   - shapes.md's top-level examples: `CRC_TABLE`, a router of data, the
     failing `assert` with its values, a cycle, a value past the limit,
     a top-level `try` that fails, a value that uses `Clock` or `Fs`,
     a value that holds a block;
   - `assert f.uses <= [...]` passing and failing with the path, for a
     private function whose declared `uses` is wider than what it uses;
   - each of strings.md's six template rules, both ways: a `Str` where
     a template is expected, a template returned, stored or captured,
     a signature `let` that depends on the caller's type parameter, a
     template forwarded through a wrapper, a hole `\{x=}`, and
     `t"""..."""` and `t#"..."#` keeping their holes;
   - every look error in formats.md, with its help, and every
     declaration check in "Looks checked when building";
   - the walk's order: shapes.md's `json.encode(order, API)` example,
     each field chosen by the step it names, and `ren explain API for
     Order` printing what shapes.md prints;
   - looks chaining, a chain that comes back to its start, an opaque
     type with no look, `Money` read through `parse`, a `writes` look
     used to read, a `reads` one used to write;
   - absence at the door: shapes.md's json table, a constant that
     differs, a field default filled, `Option<Option<T>>` refused, a
     missing `repr` found by `view` with its path;
   - `Problem` paths in the look's names with the type's field beside,
     the first problem and all problems, `TooDeep` at `Limits.depth`;
   - `json.decode<Value>` and `encode` of one back, a `json.Raw` field
     kept byte for byte, `extra: Map<Str, json.Raw>`;
   - json's sums by each payload rule, `tag: Adjacent`, a field named
     like the tag, casing with an exact name left alone, two names that
     meet after casing, strict and `unknown: Ignore`;
   - `cli.parse` of flags, positionals, short flags, a subcommand, a
     choice, a leaf through `parse(Str)`, an unknown flag with did-you-
     mean, a misspelled positional failing the build, and
     `cli.parse<Keys.Call>` over a dependency;
   - `bin` against the golden vectors, and `bin.decode<T>(bin.encode(v))
     == v` over every type in the vectors;
   - a recursive type's shape through `Ref`, decoded and encoded;
   - each prelude name used without its import, with the help;
   - freezing: a frozen value that still matches, a field added, a
     `via` function changed, a look's own name changed.

1. **The front end's prerequisites.** Scope 1, in the interpreter and
   natively, with the grammar and Zed.
   **Done when** s1 is on, every existing test and example passes
   unchanged, and `f<T>(x)`, field defaults, `parse` and `repr` run the
   same in every native build.

2. **The top level is build time.** Scope 2: the order, cycles, the
   step limit, `try`, the refusals, `f.uses`; natively, static data.
   **Done when** s2 is on; shapes.md's examples and errors read as
   shapes.md shows them; the step limit's error names the same steps on
   every run; and a native binary with a top-level `CRC_TABLE` runs no
   code for it at startup (the emitted C shows static data).

3. **The signature `let` and templates.** Scope 3, both builds.
   **Done when** s3 is on; the refusals read as strings.md's rules say;
   a template allocates nothing natively at any number of holes, by
   the allocation counter; and the log-line and HTML kernels are within
   noise of the step 0 rebuild of verify.md's hand-written C, or the
   gap is explained with numbers.

4. **Shapes, looks and the doors.** Scope 4, in the interpreter.
   **Done when** s4 is on; every look error and declaration check has
   its test and help; `ren explain API for Order` prints shapes.md's
   table; and `build<Value>(v)` is `v`.

5. **json, cli and bin.** Scope 5, in the interpreter.
   **Done when** s5 is on; a program decodes and encodes its types as
   json, reads its arguments with `cli`, and round-trips through `bin`;
   `bin`'s bytes equal the golden vectors, and the runtime core's
   journal encoder's bytes over the same values if it has landed.

6. **The prelude.** Scope 6. Every test, example and std module that
   names a world dependency, `Time`, `Instant`, `actors`, `striped`,
   `Instances` or `retry` gets its import. A
   program gains import lines and nothing else; an expected output may
   change only where an added line moved a line number, and a script
   checks every changed expectation differs in line numbers alone.
   **Done when** s6 is on, the prelude holds the table's names, and
   every check passes with no other edit to a test.

7. **Natively, and the measurement.** Scope 7: shapes, the doors, json,
   cli and bin in debug and release; the constant argument key; the
   unfolding. Mem Lint and the sanitizers over all of it.
   **Done when** s7 is on; `ren run` and every native build agree on
   every s-test, byte for byte on what json and bin write and on every
   `Problem`; `json.decode<Order>` through `Order.v1`, natively in
   release, is within 1.5× of the hand-written decoder's time, with
   serde's and Go's beside it; if the unfolding misses, the visitor
   fallback is built and measured, and both numbers are reported; and
   a copy's name depends only on its key: adding a call site earlier
   in the program renames no other copy.

8. **Freezing.** Scope 8.
   **Done when** s8 is on: a frozen value fails the build when a field,
   a look or a `via` function it reaches changes, with formats.md's
   message, and passes when nothing it reaches did.

9. **Review your own work** with three lenses:
   - **Soundness:** the doors keep every type's rules (an opaque type
     built only through `parse`), absence at the door, the block rule
     for templates, static data and its counts, Mem Lint and the
     sanitizers.
   - **The line:** does the language name a medium anywhere? Does std
     use a power a user library lacks? Does any emitted name or id
     depend on the whole program? Does debug ever specialize?
   - **Docs and tooling:** README's status and roadmap row,
     compiler.md, the status lines of shapes.md, formats.md, strings.md
     and stdlib.md, the grammar.
   Fix what blocks; list the rest with its severity.

## The interpreter and native

Build time is the interpreter's in every build, so top-level values,
signature `let`s and build errors are the same everywhere by
construction. What must agree, and bench/shapes.t checks in every
build: every output and its order; every byte json and bin write; every
`Problem`, its tag, `at` and `field`, and whether it was the first;
every panic and where; `render`'s text; `site.hash`. What needn't:
`site.id` (an address, fixed at link), timings, and code size.

## Risks

- **Unfolding the library's walk** is stage 12's risk 2, and the 1.5×
  gate rests on it. Nothing in lib/native partially evaluates recursive
  code over constant data. Build the constant key first, measure the
  decoder with it alone, then unfold; if it misses, the visitor is the
  decided fallback, not a reason to stop.
- **The first problem must be the same** in debug's walk and release's
  straight-line code: which of a missing field and an unknown key is
  found first, and where. The differential tests are the guard.
- **`bin` and the journal's bytes.** Their table encodes an opaque type
  through its `repr`; the walk uses `repr` on any type that has one,
  and `repr` is new in this stage. A type that gains a `repr` must
  encode the same way in both. If their table can't follow the walk,
  record it and stop for the owner.
- **The prelude step touches nearly every test.** Script it, keep it
  to imports, and land it in one commit after a rebase, at a quiet
  point for the other stages.
- **Build time costs every build.** The interpreter runs every
  top-level value and every signature `let` on each build until there's
  a cache. Report `ren check` and `ren build` times against the
  baseline.
- **A signature `let` refuses a caller's type parameter.** A user's
  generic wrapper around `json.decode<T>` is refused in both builds.
  That's decided (decision 13); make its help say what to write instead.
- **Field defaults meet the data stage's record update and patterns.**
  Test a default with `{ ..r }` and with a record pattern's `..`.
- **`f<T>(x)` against comparisons.** The parser reads `<` after a name
  as a comparison today. Test chained comparisons and generic calls
  side by side.

## THE CHECKS

All must pass before any commit:

- `dune build`
- `dune test --force`, with `REN_TCC` set (tools/tcc.sh), or bench/*.t
  are skipped
- `make -C editors/tree-sitter-ren check`
- `_build/default/bin/main.exe test` inside each of examples/bank,
  examples/prices, examples/just, examples/ledger, examples/crawler,
  examples/refresh, examples/server, examples/transfer, examples/docs,
  examples/breaker and examples/checkout
- once the runtime core stage has made it a gate, the edit test, with
  a json fixture of this stage's added

Setup, portability and flakes are as the bytes stage's brief says
(briefs/stage-bytes.md, "THE CHECKS"): journal.t's timing tests flake
under load; rerun and report, never loosen. **Never weaken or delete a
test to get green.**

**Measuring.** Name the machine and its load. Interleave, report
medians and spread, and put every number in bench/native/RESULTS.md
with the commands that reproduce it. Compare to your own baseline and
to the experiments' ratios, not their nanoseconds.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results
  untrustworthy. Note others in your final report.
- **Do NOT edit foundations.md, language.md, shapes.md, formats.md,
  strings.md, module-build.md or stdlib.md,** beyond the status lines
  in step 9. If they're wrong or underspecified, make a choice, record
  it in compiler.md's section, and list it in your final report.
- **Committing:** on main, explicit `git add` paths, never `git add
  -A`; never the root `dune` file's local changes, prior-art.md, or
  anything under .claude/; every message ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push after
  each green step.
- **Keep a progress log** at the end of compiler.md's section.

## Decided

Record these in the spec; don't reopen them.

- **The top level is build time,** with no keyword; inside a function,
  `let` is a runtime value. The top level never runs when the program
  does.
- **12a's top level is pure.** A top-level value that uses any
  dependency, `Fs` and `Git` included, is a build error whose help says
  the build's world comes with packages.
- **The step limit is per value and per signature `let` site,** counted
  in evaluation steps, never time. Its default is fixed until
  `ren.toml` exists.
- **The signature `let` is the one build-time mechanism.** It refuses a
  caller's type parameter and a forwarded template.
- **A template is passed down, never kept;** `site.id` is the site's
  address, fixed at link; a dependency is given `site.hash`.
- **The walk's order:** the field's look, the caller's look for the
  type, the type's `parse` and `repr`, the structure. The reserved
  names are `show`, `key`, `parse`, `repr`.
- **Conversions run in the doors, never in a library;** absence is
  decided at the door.
- **`Value` is an ordinary sum type** in std's `shape` module, not the
  prelude; its door is the identity; a medium's exact bytes are its
  `Raw`.
- **`Value` gains its `Decimal` case with `Decimal`, in 12b.** Until
  then a json number that isn't whole fails `json.decode<Value>` with
  `Invalid`, saying so, and its test as specified waits for 12b. A
  typed `Float` field reads it.
- **`Problem`, `LookError` and `Limits` are in the `shape` module.**
- **A `Look` is named by its qualified path,** never a program-wide
  number; a debug build points at a static record, a release build
  folds it away.
- **`bin` takes no looks,** isn't for disk, and gives the runtime core's
  derived bytes.
- **The world's dependencies are imported, `import std/clock`;** `Time`
  and `Instant` go with `Clock`, `Duration` stays. `import sim` and
  `import sync` keep working as they are, since tests use them.
- **What the prelude has today that its table doesn't name** is sorted
  by the same rule (decided): `actors`, `striped` and `Instances` go to
  `std/actors`, `retry` to `std/retry`, and `Send<T>` stays with
  `Async`. Anything else the spec's table finds that the language
  doesn't name goes to a std module too; list each in the spec.
- **`Alloc` is left to 12b.** Inferring it changes every row the
  checker prints. Rule 2 reads the row without `Alloc` (decided,
  streams.md), so an allocating generator stays data when it comes.
- **`bin` uses `repr` on any type that has one,** as the walk does
  (decided). The runtime core's table says opaque types, which is the
  same until this stage adds `repr`; this stage's `bin` is the one
  encoder, and the journal's bytes follow it.
- **Release specializes per (type, looks),** a copy keyed on a known
  constant argument and named by its key; debug never specializes.
- **The toolchain reads the language, never a library:** `ren explain`
  and freezing work from shapes and declarations.
- **Freezing is 12a's,** by shapes.md's table.
- **The 1.5× bar is against a decoder written by hand in Ren;** serde's
  and Go's numbers go beside it. The Rust twin uses serde_json, an
  exception to the twins' std-only convention, documented in
  bench/native/README.md as streams' FFI wrapper is.

## Final report

End with: per step, what was built, the commits, and the choices you
made where the spec was silent; whether each "Done when" holds, with
the numbers before and after, the twins' numbers, and the commands;
whether the unfolding or the fallback carries the 1.5×; build time
before and after; what's unfinished or unsound, with its severity; and
which checks couldn't run.

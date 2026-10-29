# Brief: the data stage

You're building the data stage of Ren: ADTs made excellent, so that
modelling with data is the obvious way and the fast way. Ren is a
systems language whose compiler is written in OCaml. Work on `main`.
This brief is self-contained: it names everything you need in the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

## Read first

- **language.md** is the signed-off design for this stage: "Why: Ren
  felt object-oriented", "The ethos", §1, §2 (all of it: this is most
  of the stage), §3, §6, and "A program, end to end". Build these as
  written. If something is unsound or can't be built, stop and say so
  instead of inventing a different design.
- **foundations.md**: Staging item 5 is this stage's scope and its
  "Done when". Decision 3 (descriptions, as an enum the compiler
  writes; operations callable only on stateless ones), decision 14
  (small values as values, the layout this stage fixes), and "The bet"
  (the programmer never holds an address, so representation is the
  compiler's choice: the layout fixes follow from it).
- **compiler.md**: the 10c, 10d and 11a sections show how a stage is
  specified and then built. Follow that shape. Its "Native slice"
  sections describe the layout code you'll change
  (`lib/native/to_mem.ml`, around lines 395 to 420 and 517, is where
  language.md found the three layout faults).
- **README.md**, the "data" row of the roadmap; **operators.md** for
  `key` and derived `==`, `hash`, order and `show`; **errors.md** for
  `fail` patterns, which already have or-patterns (`POr` in the
  parser).
- foundations.md and language.md cite research files that aren't in
  the repo. You don't need them: the decisions record what they found.

## Scope

**In:**

1. Record update, `{ ..order, status: Paid }` and `Placed { ..draft,
   id, total }`; `..` means "the rest" in values and in patterns.
2. Record patterns, `{ id, .. }` in `match`, and `let { id, lines } =
   order` (irrefutable only, as `let` already requires).
3. **Variants with several fields are by name, in declarations,
   constructors and patterns; a variant with one field is
   positional.** `Rect { w: 2, h: 3 }`, `Rect { w, .. } =>`, `Some(x)`,
   `Percent(10)`. Tuples stay positional. Positional construction or
   matching of a several-field variant becomes an error with a fix-it
   that writes the by-name form. Labelled construction in any order is
   **not** added (a third spelling).
4. Or-patterns over constructors, nested, with "`n` is bound in `A(n)`
   but not in `B`"; `as`, binding the whole of what a pattern matched;
   `let PATTERN = e else LEAVE`, where the `else` must leave (`fail`,
   `return`, `break`, a panic). **No `if let`.**
5. **Variant types:** a variant with named fields is a record type,
   `Order.Placed`, bound only by `as` in a pattern, usable anywhere
   (returned, stored, passed); back to the sum with `Placed { ..p }`;
   constructors always build the sum; no subtyping, no implicit
   conversion, no flow-sensitive narrowing; `==`, `hash`, order and
   `show` are the sum's, borrowed (language.md §2, "Derived operations
   are borrowed").
6. **Errors that teach the model** (language.md §2): a field asked of a
   sum names the variant that has it and writes the `match`; a field
   every variant has gets the "hoist it into a record" help; a `match`
   that misses cases prints the missing arms as code to paste
   (`Some(Closed) => todo`). The editor code action for that is later;
   printing it is in.
7. **Descriptions** (language.md §6, foundations decision 3): calling
   an operation on a description of a **stateful** handler is an error
   whose help writes the `with`. `Shape` and `Expr` become ADTs wherever
   docs, examples and benchmarks use them to model data. Benchmarks
   that measure description dispatch keep a dependency, over something
   a library would really store (routes, codecs).
8. **The layout fixes, natively, measured** (language.md §2, "Layout
   fixes"): a small record inside a small variant is flattened into its
   parent's slots, the budget counted in total words; an array of small
   records that hold an object keeps them inline, scanned by the mask
   the type already has, instead of boxing the type program-wide; tags
   are a byte, with pointer niches so a variant with one object and the
   rest empty needs no tag. Variant types and `Placed { ..p }` cost
   nothing extra when the value is unique (Perceus reuse).
9. **Every existing program moves to the new forms:** examples/, test/,
   bench/, Ren code in the standard library, the tree-sitter corpus,
   and the code in every doc (README, language.md's own examples are
   already in the new forms). The bank's `Sent(t.amount, t.to)` is the
   kind of site that changes. A throwaway migration script is fine if
   it helps; don't ship it.

**Out (later stages, don't start them):** wirings, the pipe `|>`,
`Table`, `Pool`, formats, `ren review` and its hint, methods on one
variant, the 11a follow-ups, `striped` and `actors`.

## Interpreter and native

Everything here is sequential, so every feature works in the
interpreter (`ren run`, `ren test`) **and** in native builds, debug and
release, and the two agree. Add cases to bench/build.t for each feature.

## Steps

Do them in order. After each step, THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, tests first.** Add a "Data stage" section to compiler.md
   that settles every detail the later steps need: the grammar for each
   form, how `..` and punning combine, how pattern `as` sits beside
   `with h as Dep` and format `as` (language.md §12) without ambiguity,
   how a variant type is represented in types and Core, which errors
   fire where. Make an inventory of every site that breaks under
   by-name variants (count them per directory). Then write the test
   programs, marked skipped or expected to fail until the step that
   builds them, as 10c and 10d did: one per feature, one-line refusal
   tests for every new error, and a program in the shape of
   language.md's "A program, end to end" minus `|>` and wirings.
1. **Record update, record patterns and `let { .. } =`.**
2. **By-name variants,** and the migration of every program and doc
   (scope item 9) in this step, so main never has two styles for long.
3. **Or-patterns, `as` and `let ... else`.**
4. **Variant types.**
5. **The teaching errors.**
6. **Descriptions:** the stateless-only rule, and `Shape` and `Expr` as
   ADTs in docs, examples and benchmarks.
7. **The layout fixes,** each measured before and after on the native
   benchmarks and on small kernels you add that hit each fault (a small
   record in a variant; an array of records holding a `Str`; an
   `Option` of an object). Then the milestone's measurement: an
   ADT-first rewrite of bench/10d's interpreter kernel (`Expr` as a sum
   type and a `match`), against its Rust twin. Record the numbers in
   bench/native/RESULTS.md with the commands that reproduce them.
8. **Review your own work** with three lenses:
   - **Soundness:** adversarial programs for patterns (or-patterns that
     bind differently, `as` inside or-patterns, `let ... else` that
     doesn't leave, variant types escaping and round-tripping, record
     update on opaque types from outside their module) and for layout
     (Mem Lint and the sanitizers over every new layout, interpreter
     against native on each).
   - **The spec:** does it match language.md and foundations.md, and
     does the "Done when" hold?
   - **Docs and tooling:** README, language.md's "What Ren has today"
     table (it says what's built: update it), compiler.md, the grammar
     and corpus, Zed queries.
   Fix what blocks; list the rest with its severity.

**Done when** the bank, the shop and the ledger read as language.md's
end-to-end program does (by-name variants, record update, patterns,
`let ... else` where it fits), and the ADT-first interpreter kernel is
measured against Rust.

## Language changes go through the whole pipeline

Every language change goes through:
- the lexer and parser;
- types and Core;
- the interpreter;
- native, debug and release;
- the tree-sitter grammar and its corpus (`editors/tree-sitter-ren`),
  with `differential.py` agreeing with the compiler's parser;
- Zed queries (`editors/zed`);
- error messages with help lines;
- the docs that describe it.

Grammar and editor support is first-class: don't hack it in.

## THE CHECKS

All must pass before any commit:

- `dune build`
- `dune test --force` (includes bench/build.t's sanitizer and tcc
  builds)
- `make -C editors/tree-sitter-ren check`
- `_build/default/bin/main.exe test` inside each of examples/bank,
  examples/prices, examples/just, examples/ledger, examples/crawler,
  examples/refresh, examples/server and examples/transfer, and in each
  new example

**Setup:**
- OCaml 5.x with opam: `opam install dune ppx_deriving ppx_expect`.
- clang, with AddressSanitizer and UBSan.
- node and npm, for tree-sitter.
- python3.
- tcc: `tools/tcc.sh`.

The repo was developed on macOS; 11a ran in this environment, and its
portability fixes are in. If a check fails at the start before you
change anything, fix it when it's a portability bug in the repo (and
say so). Otherwise record exactly which checks you couldn't run.
**Never weaken or delete a test to get green.** Tests that check
real-time ordering are known to be sensitive to a loaded machine; if
one flakes, rerun it, and report it rather than loosening it.

Benchmark numbers from this machine are for before-and-after
comparisons only. The owner re-measures headline numbers on their own
hardware, so say which machine yours came from.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results untrustworthy.
  Note others in your final report.
- **Do NOT edit foundations.md or language.md's design sections.** If
  they're wrong or underspecified, make a choice, record it in
  compiler.md's data section, and list it in your final report. The one
  exception is language.md's "What Ren has today" table, which records
  what's built.
- **Committing:**
  - Commit on main with explicit `git add` paths, never `git add -A`.
  - Never commit the root `dune` file's local changes, prior-art.md, or
    anything under .claude/.
  - End every commit message with
    `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Push to main after each green step. If you can't push to main, push
    a branch named `stage-data` and say so.
- **Keep a progress log** at the end of compiler.md's data section
  (step, commit, what's done, what's left), so a resumed session can
  pick up where it stopped.

## Final report

End with:
- **Per step:** what was built, the commits, and the choices you made
  where the spec was silent.
- **Whether "Done when" holds,** with the commands that show it, and
  the layout numbers before and after.
- **What's unfinished or unsound,** with its severity.
- **Which checks couldn't run** in this environment.

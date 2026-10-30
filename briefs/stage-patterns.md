# Brief: the patterns stage (7b, part one)

You're building list patterns and string patterns, and a string `match`
lowered to a perfect hash: [language.md](../language.md), "List
patterns and string patterns", and research/perfect-hash/synthesis.md,
its "Staging" items 1 and 2. It's part one of foundations.md Staging
item 7b. Part two (formats views, `Table`, `Pool`, and `Fs`, `Os`,
`Proc` and `Console` natively) gets its own brief once the bytes
stage, part two, is on `main`, because it's built on that stage's
string layout.
Ren is a systems language whose compiler is written in OCaml. Work on
`main`. This brief is self-contained: it names everything you need in
the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**This stage can start now.** Two other sessions are on `main` at the
same time; see "Working beside the other stages".

## Read first

- **language.md**, "List patterns and string patterns", all of it: the
  five rules and the paragraph on the perfect hash. "Or-patterns and
  `as`", just above it, for how alternatives bind names.
- **research/perfect-hash/synthesis.md**, all of it. It's the spec
  for the lowering: when each form is emitted, the compare per build,
  the page check, the six emitter fixes, and the verified numbers.
  **verify.md** for how the numbers were measured and what the fuzz
  found. **list-patterns.md** is the first design note; the five rules
  supersede it where they differ.
- **research/perfect-hash/code/gen.ml** (the generator) and
  **verify/fuzz/gen_fixed.ml** (the same with the six fixes), and
  **code/phrt.h** and **verify/phrt.h** (the NEON, two-word and
  `memcmp` compares, and the page check). They're the reference
  implementation of what you build. **code/rmatch.rs** and
  **rmatch_small.rs** are the Rust twins; **code/keys/** are the key
  sets.
- **foundations.md**: decision 17 (slices are values; "what doesn't
  escape costs nothing"), decision 20 rule 4 (optimizations are
  invisible: debug and release mean the same), decision 13 (debug
  builds don't specialize), and Staging item 7b.
- **strings.md**, "Positions" and "Cutting a character", since `..x`
  on a `Str` is a slice whose cuts are on character boundaries by
  construction.
- **compiler.md**: how `match` is lowered today, in the interpreter
  (lib/eval/eval.ml) and natively (lib/lower/lower.ml to Core's
  `Match`, then lib/native/to_mem.ml and emit_c.ml); "Native slice"
  step 6 (slices); the data stage's section (or-patterns, `as`, record
  patterns, and what exhaust.ml does with them).
- **lib/syntax/ast.ml**, the `pattern` type (`PWild` ... `PFail_in`);
  **lib/sema/exhaust.ml**, the exhaustiveness and coverage check.
- **bench/native/README.md** for how to measure.

## Scope

**In:**

1. **String literal patterns** wherever a pattern goes: alone, inside
   or-patterns, `as`, tuples, records, constructor arguments and array
   elements (rule 3).
2. **Sequence patterns** (rule 1), one rest at most:
   - on `Array<T>`: `[]`, `[p, q]`, `[first, ..rest]`, `[..init,
     last]`, `[a, .., z]`, with element patterns of any kind;
   - on `Str`: literal pieces around at most one rest, `"Bearer "
     ..token`, `..stem ".json"`, `"<" ..inner ">"`, `"--" ..`.
   `..name` binds the middle as a slice of the same type, through the
   slice operation that exists today (rule 2), so it costs what a slice
   costs and gets bytes part two's representation when that lands.
   `..` alone ignores it.
3. **The checks**, each an error with help, worded in the compiler.md
   section you write:
   - `..x` alone, or `[..xs]` alone (help: write `x`);
   - two rests in one pattern (help: `split`, `split_once`);
   - a `Bytes` subject with a string pattern (help: formats, or
     `Str.from_utf8` first);
   - alternatives that bind different names or types (today's rule,
     extended);
   - **exhaustiveness** (rule 4): array lengths are constructors, so
     `[]`, `[_]` and `[_, _, ..]` cover every array; a `Str` literal
     or prefix never covers `Str`, so a string `match` needs `_` or a
     binding; the missing arms printed as code, as today;
   - **a covered arm is an error** (rule 5): one arm covers another
     when its prefix is a prefix of the other's, its suffix a suffix,
     and its minimum length no longer. `"a" ..x "a"` doesn't cover
     `"a"`. A guarded arm covers nothing.
4. **The interpreter** runs all of it.
5. **Natively, a decision DAG**: Maranget's 2008 decision trees with
   shared join points, so a test isn't duplicated under every length
   branch (synthesis, owner decision 4). Today's tag switch is its
   one-column case. Rule 5's first-match semantics, with guards that
   fail falling through to the next arm that can match.
6. **The perfect hash** for the literal arms of one column at one node
   (synthesis, "What the compiler emits, and when"):
   - 0 literals: nothing; 1 literal: a length test and an inline
     compare;
   - 2 or more: the generator's hash, then the compare; keys over 16
     bytes compare their slot with `memcmp`;
   - no hash within the budget: try the 64-bit mix of the first and
     last 8 bytes, then fall back to a length switch and word compares;
   - the compare per build: NEON in release on arm64 with clang; two
     masked 8-byte words in debug (tcc) and on other targets; `memcmp`
     in sanitizer builds. All give the same answer;
   - the page check, never padding (owner decision 2).
   Prefix and suffix arms stay tests in order around the lookup: a
   length test and a fixed compare each.
7. **`keys.index(s)` on a build-time constant `Array<Str>`** lowers to
   the same hash (owner decision 3, option a), **for the case that
   exists now**: a top-level `let` bound to an array literal of string
   literals, in release builds. Debug builds run the method as written,
   with the same result. The case of a shape's field names comes with
   `T.shape` in stage 12; don't build it.
8. **Using it**: examples/just's argument handling and line parsing
   rewritten with patterns where they read better, a keyword-lexer
   kernel, and the grammar.

**Out (don't start them):**

- **Templates, `t"..."` and the signature `let`.** Stage 12, with
  top-level `let`'s build-time evaluation (strings.md, "Templates";
  research/templates/synthesis.md, "The work it implies").
- **The derived `parse` for fieldless sums, `keys.index` over a
  shape's field names, and `http`'s routing.** Stage 12.
- **7b part two:** formats views over `Bytes`, `Table`, `Pool`, the
  world natively, `Path` as `opaque Bytes`, `Os`'s `ArgNotUtf8`.
- `Bytes` patterns, case folding, regex, a trie for prefix arms, raw
  and multi-line literals and `b"..."` (decided together, later), the
  x86 SSE2 compare (unmeasured: x86 gets the two-word form).

## Working beside the other stages

The **services stage** (briefs/stage-services.md) and the **bytes
stage, part two** (briefs/stage-bytes-2.md) run on `main` at the same
time.

- **Yours:** lib/sema/exhaust.ml; the decision DAG wherever native
  `match` is lowered; a new generator module in lib/native (say
  `phash.ml`); the compare functions and page check, as a new section
  at the end of ren_rt.h; string and sequence patterns in the
  interpreter's matcher; tests and kernels you add.
- **Theirs, don't touch:**
  - services: wirings and `|>` in the parser and checker, the lexer's
    `continues()`, lib/eval/sched.ml, `With` and `Dep_call` in eval.ml,
    std_lib.ml's `sync`, `sim`, `striped` and `actors`, and excl.ml;
  - bytes part two: ren_rt.c and ren_rt.h's string and byte code, `Str`
    and `Bytes` layout in to_mem.ml, emit_c.ml and Mem Lint, the
    interpreter's `VStr` and `VBytes` operations, the lexer's string
    literals (`\{` holes) and character literals.
  Read a `Str`'s data and length only through the accessors that exist
  (`ren_str_*`), never its fields, so their change of layout doesn't
  break you.
- **Shared files** (ast.ml, parser.ml, lower.ml, to_mem.ml, emit_c.ml,
  prelude.ml, builtins.ml, infer_expr.ml, eval.ml): add your cases and
  constructors; don't move, rename or restructure code there. If you
  need a change that would, stop and say so in the progress log.
- **New tests go in new files.** Don't rewrite existing tests.
- **Rebase before every push.** If a conflict touches their work, keep
  theirs and redo yours on top. If a check goes red because of their
  commits, not yours, record it in the progress log and don't fix
  their work.

## Steps

Do them in order. After each step THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, baseline, tests first.** Add a "Patterns stage" section to
   compiler.md. In it, settle:
   - **The AST:** a string literal pattern and a sequence pattern
     (front pieces, an optional rest that binds or ignores, back
     pieces), on `Array` and `Str` alike, and how they reach Core.
   - **Coverage** for sequences and strings as exhaust.ml will compute
     it: length constructors for arrays (rustc's slice-pattern
     splitting), the `Str` family, and the covered-arm relation of rule
     5 with its proof sketch that looking up every literal of a column
     first gives the same answer as first match.
   - **The DAG:** its node kinds (tag switch, length switch, hash
     lookup, prefix test, suffix test, guard), join points, and how
     `--emit-c` shows it readably.
   - **The generator's budget** (positions tried, time), its output as
     static const C data, and its determinism: the same keys always
     give the same tables, so builds are reproducible.
   - **Every compile error** this stage adds, with its help.

   **Baseline:** bench/native/keywords: a kernel that classifies
   identifiers against Ren's 35 keywords and JS's 45 reserved words,
   plus the methods (9), headers (20) and json24 (24) sets, from
   research/perfect-hash/code/keys, with 10% near misses as the
   research's queries had. Written in Ren today as an `==` chain, with
   a Rust twin using `match` (rmatch.rs's shape) and a Go twin using
   `switch`. Measured as bench/native measures, interleaved, medians
   and spread.

   **Tests,** marked skipped or expected to fail until their step:
   test/test_patterns.ml with `until "p1"` ... `until "p4"`, and
   bench/patterns.t (spec, native debug, release under the sanitizers,
   tcc, `ren run --release`). At least: every pattern form on `Array`
   and `Str`; nested inside tuples, records, constructors, or-patterns
   and `as`; binding slices and using them after the subject is gone;
   `..` cuts on multi-byte characters; each new error; exhaustiveness
   and covered arms, both ways (accepted and refused); guards falling
   through past literals to prefix arms and `_`; the empty string as a
   key and as a subject; keys of 1, 16, 17 and 255 bytes; 128 and 200
   arms; a set the generator can't hash (the research's adversarial
   sets).

1. **The front end and the interpreter.** Scope 1 to 4: the lexer and
   parser, the checker, exhaust.ml, the interpreter's matcher, and
   tree-sitter's grammar and corpus and Zed's highlights (patterns are
   first-class there, not a regex).
   **Done when** p1 is on: every form runs in `ren run`, and every
   error fires with its help.

2. **Natively, as chains.** Scope 5: the decision DAG in the native
   lowering, with string literals compared by a length test and
   `memcmp`, prefix and suffix tests, and `..name` bound through
   today's slice operation. Mem Lint and the sanitizers over every
   binding.
   **Done when** p2 is on, and `ren run` and every native build agree
   on every test, including which arm a guard falls through to.

3. **The perfect hash.** Scope 6: gen_fixed.ml's generator ported into
   lib/native with its six fixes, the 64-bit-mix fallback, the three
   compares and the page check in ren_rt.h, and sanitizer builds on
   `memcmp`. Port the research's fuzz into a differential test dune
   runs: random key sets and queries, every form against the chain.
   **Done when** p3 is on; the fuzz finds no disagreement; the keyword
   kernel runs at least as fast as Rust's `match` on every set, with
   the research's ratios to the chain (5.5× to 8.3×) as the target and
   any shortfall explained with numbers; and a 1-literal arm costs no
   more than the chain did.

4. **`keys.index(s)`, and using it.** Scope 7 and 8: the lowering for
   a top-level constant, examples/just rewritten where patterns read
   better (its tests must pass unchanged), and stdlib.md's entry for
   `index` saying when it's hashed.
   **Done when** p4 is on, the just's tests pass in both builds, and
   `keys.index` on a constant runs at the hash's speed in release.

5. **Review your own work** with three lenses:
   - **Soundness:** the over-read and the page check, the empty string,
     slices bound from a subject that dies, guards, the generator's
     tables at their size edges, Mem Lint and the sanitizers over all
     of it.
   - **The spec:** does it match language.md's five rules and the
     synthesis, and does each "Done when" hold?
   - **Docs and tooling:** README's status and roadmap row, compiler.md,
     stdlib.md, the grammar.
   Fix what blocks; list the rest with its severity.

## The interpreter and native

The interpreter matches patterns directly, with no hash: it's the
meaning, and the hash is invisible (decision 20, rule 4). What must
agree, and bench/patterns.t checks in every build: which arm runs,
what each name binds, every error and panic, and the result of
`keys.index`. Debug builds hash too (the two-word compare), so a
debug build exercises the same tables release does.

## Risks

- **Coverage is subtle.** A wrong covered-arm rule either refuses good
  programs or lets the hash reorder arms. Test it both ways, and test
  that hashing every literal of a column first never changes which arm
  runs.
- **The over-read.** The 16-byte load reads past a short key. The page
  check makes it safe for any bytes, including a slice at the end of a
  page; test a key at the last bytes of an `mmap`ed page with a guard
  page after it.
- **Code size.** A decision DAG can grow; join points are the answer.
  Report the size of the emitted C for the keyword kernel and the just
  before and after.
- **Build reproducibility.** The generator must not depend on hash
  table iteration order or time.
- **The machine.** The NEON compare needs arm64. If you're measuring
  on x86, release uses the two-word form there; build the NEON form
  for arm64 and check it compiles and agrees under the fuzz, if you
  can run it, and say what you couldn't measure.

## THE CHECKS

All must pass before any commit:

- `dune build`
- `dune test --force`, with `REN_TCC` set (tools/tcc.sh), or bench/*.t
  are skipped
- `make -C editors/tree-sitter-ren check`
- `_build/default/bin/main.exe test` inside each of examples/bank,
  examples/prices, examples/just, examples/ledger, examples/crawler,
  examples/refresh, examples/server and examples/transfer

Setup, portability and flakes are as the bytes stage's brief says
(briefs/stage-bytes.md, "THE CHECKS"): journal.t's timing tests flake
under load; rerun and report, never loosen. **Never weaken or delete a
test to get green.**

**Measuring.** Name the machine. Ren and its twins interleaved,
medians and spread, every number in bench/native/RESULTS.md with the
commands that reproduce it. The research's numbers are hand-written C
on an M4 Max: compare your results to your own baseline and to the
research's ratios, not its nanoseconds.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results
  untrustworthy. Note others in your final report.
- **Do NOT edit foundations.md, language.md or strings.md.** If they're
  wrong or underspecified, make a choice, record it in compiler.md's
  section, and list it in your final report.
- **Committing:** on main, explicit `git add` paths, never `git add
  -A`; never the root `dune` file's local changes, prior-art.md, or
  anything under .claude/; every message ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push after
  each green step.
- **Keep a progress log** at the end of compiler.md's section.

## Decided

Record these in the spec; don't reopen them.

- **Prefix and suffix patterns ship with literals** (owner decision 1).
- **The page check, never padding** (decision 2).
- **`keys.index(s)` on a build-time constant lowers to the hash**
  (decision 3, option a); here only for a top-level literal array.
- **A decision DAG with join points,** not a backtracking automaton
  (decision 4).
- **No case folding in the language;** `http` lowercases first
  (decision 5).
- **`[..init, last]` stays** (decision 6).
- **One rest per pattern,** no `Bytes` patterns, no regex.
- **A covered arm is an error;** Ren has no warnings.

## Final report

End with: per step, what was built, the commits, and the choices you
made where the spec was silent; whether each "Done when" holds, with
the numbers before and after, the twins' numbers, and the commands;
code size before and after; what's unfinished or unsound, with its
severity; and which checks couldn't run.

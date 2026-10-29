# Brief: the bytes stage, part two

You're building what [strings.md](../strings.md) "Representation" and
research/strings/synthesis.md section 3 say to build next: a `Str` and
`Bytes` held as a 16-byte value instead of a heap object, appending in
place, a block UTF-8 validator, and the parts of strings.md's API that
are code. It's part two of foundations.md Staging item 7a, "Strings
and bytes at Rust's speed", whose "Done when" is this stage's.
Ren is a systems language whose compiler is written in OCaml. Work on
`main`. This brief is self-contained: it names everything you need in
the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**This stage starts after the data stage is on `main`.** The data
stage's step 7 (branch `claude/gallant-wright-1m4mba`, 10 commits past
`main` when this was written) flattens small records into their parent
and keeps arrays of small values that hold objects inline, counted by a
mask in the array's header. Representation B is a small value that
holds an object, so it's built on exactly that code. If the data stage
isn't merged when you start, stop and say so.

## Read first

- **strings.md**, all of it, and **research/strings/synthesis.md**
  section 3 ("Representation findings") and section 6 ("Open risks").
  **research/strings/track-b/RESULTS.md** and **VERIFY.md** for how
  each number was measured, and the clang fault (VERIFY.md, problem 1).
  The C model in research/strings/track-b/c/ (`strs.h` has every layout,
  `b5.c` the NEON validator) is the reference implementation of what
  you build. The Rust twins' sources weren't committed
  (track-b/rust/src is empty): write your own.
- **foundations.md**: decision 17 (slices are values; "what doesn't
  escape costs nothing"; the hot-root trap), 14 (small values, the
  header and allocator), and Staging item 3's gaps and item 7a.
- **compiler.md**: "Bytes stage", all of it: what part one built, its
  checks, its kernels, how it measured, and its progress log; "Native
  slice", step 6 (slices, representation A) and step 10 (small
  values); the data stage's section ("The layout fixes (step 7)"); and
  "The runtime model" (rules U and B). "Parameters with defaults"
  (Stage 11a, step 1) for `cursor(from: Int = 0)`.
- **bench/native/RESULTS.md**, "Slices" (the slices kernels, and what
  the research's hand-written B saved on them) and the three "Bytes
  stage" sections. bench/native/README.md for how to measure.
- **streams.md**, "Data: cursors you keep", since `s.chars()` is a
  value cursor and follows its rules.
- **lib/native/runtime/ren_rt.h**, `ren_str` and the slice functions
  (`ren_str_part`, "slices"); **lib/eval/value.ml**, `VStr` and
  `VBytes`, which are OCaml strings: the interpreter has no root, and a
  slice there is a copy.

## Scope

**In:**

1. **Representation B, release builds.** A `Str` or `Bytes` value is
   16 bytes, `{ root, u32 offset, u32 len }`, kept inline in locals,
   parameters, results, record fields and array elements, as the data
   stage keeps a small struct: one object slot (the root, counted) and
   one scalar slot (offset and length packed). Making a slice
   allocates nothing and counts the root once. A slice of a borrowed
   parameter's string doesn't count it at all: it's a part of the
   borrowed root, as a field read is (decision 17, "what doesn't escape
   costs nothing"; foundations item 3's "uncounted view"). Where a
   value must be a word (a type variable's value, generic code through
   descriptors, a block's environment if it's words), it's boxed, and
   **its box is today's representation A**: the owner itself when the
   value covers all of it, otherwise a 32-byte slice object. Debug
   builds keep A throughout, as the data stage keeps every type boxed
   in debug builds. A `Map` or `Set` whose key or value is `Str` or
   `Bytes` keeps it unboxed in its entries in release builds (part one
   kept every key a word; strings are the case that pays).
2. **The 4 GiB escape.** An offset or length that doesn't fit 32 bits
   is the boxed form: the value's root is an A object, its length field
   `UINT32_MAX`, and reading the length or data checks that one value
   first. Loops read both once before they start (part one's fix 1b),
   so the check is per loop, not per byte. Measure what it costs code
   that never meets one.
3. **Appending in place.** `s += t` (and `a + b` when `a` is dead and
   unique) writes into `s`'s owner when the owner is unique and has
   room, and otherwise grows it by doubling (in place when unique,
   copying when shared). The owner's header carries a capacity. Same
   for `Bytes`. **Debug builds report a `+=` in a loop that copied
   because its string was shared**, the one way appending goes
   quadratic again (strings.md, "Building strings").
4. **The validator.** Keiser and Lemire's block validator, NEON, in the
   runtime, replacing `ren_utf8_valid`'s byte loop. Exact: it accepts
   exactly what OCaml's `String.is_valid_utf_8` accepts, so `ren run`
   and native builds can't disagree. On failure, the error's offset
   comes from rescanning the failing block one byte at a time. A scalar
   path for tcc and for targets without NEON.
5. **strings.md's API, the parts that are code,** in the interpreter
   and natively, with every program, test and doc moved in the step
   that changes a name:
   - `InvalidUtf8(at: Int, incomplete: Bool)`, across every `std` use
     in one step; `Str.from_utf8_lossy`.
   - `s.lower()` becomes `s.ascii_lower()` (and `Bytes.ascii_lower`),
     the old name a compile error with help.
   - `Str` gets `byte_len()` and `is_empty()`; `s.len()` and `s[i]`
     become compile errors with strings.md's help. `Str.concat` goes
     (an error pointing to `+` and `join`). `Bytes` keeps `len`.
   - `s.char_floor(i)`, `s.char_ceil(i)`, and the cut-a-character panic
     with strings.md's help line.
   - `s.chars()`, a value cursor yielding one-code-point `Str` slices;
     `c.code()`, panicking on any string that isn't one code point;
     `Str.of_code(n)`.
   - `'a'` as an `Int` literal, its code point; a non-ASCII one stored
     in a `UInt8` a build error with strings.md's help.
   - Interpolation, `"…\{x}…"`, any expression in the hole, through
     its type's `show`. `\{` is an error today, so nothing breaks.
   - `xs.join(sep)` on an `Array<Str>`.
   - `b.cursor(from: Int = 0)`: a parameter with a default, given by
     name, which is already built. Every `at` the cursor reports counts
     from `from`.
6. **The rest of strings.md's API table,** in the interpreter and
   natively: `includes`, `ends_with`, `strip_prefix`, `strip_suffix`,
   `split_once`, `lines`, `fields` (ASCII whitespace, on `Str` and
   `Bytes` alike), `replace`, `ascii_upper`, `s.line_col(at)` (columns
   in code points), and `count()` with no predicate on every receiver
   (operators.md). Mostly prelude Ren over `index` and slices.
7. **The `Map` claim, measured again,** against Rust with FxHash (and
   std's `HashMap` beside it), and compiler.md's "0.69×" restated.

**Out (don't start them):**

- **`Path` as `opaque Bytes`, and `Os.args() ! ArgNotUtf8` with
  `raw_args` and `raw_env`.** They're the world's API, not strings',
  none of it is native yet, and the stage that builds `Fs`, `Os` and
  `Proc` natively (Staging item 7b) writes their signatures
  once. Doing it here means a breaking change to every `Fs` error
  payload with nothing native to show for it.
- The `unicode` module; short strings inline (SSO) and German strings;
  a capacity-keeping `clear()`; proved copy-on-store; the retention
  report (a root kept alive by small slices); `b"…"` literals; x86 SIMD;
  formats (layer 2), `Table`, `Pool`, the world natively, native tasks.

## Steps

Do them in order. After each step THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, baseline, tests first.** Add a "Bytes stage, part two"
   section to compiler.md. In it, settle:
   - **B's layout in Mem IR:** `Str` and `Bytes` as a release layout of
     two slots, the root an object and the range a scalar
     (`off | len << 32`), so the data stage's flattening, array masks,
     Perceus and Mem Lint see an ordinary small struct. Say where the
     boxing happens and how a box is unboxed.
   - **The owner's header.** `ren_obj`'s 8 bytes are full (`rc`, `tag`,
     `nfields`, `objs`), and A's box needs `len` and `data`. The
     expected shape keeps today's 32-byte `ren_str` and puts the
     capacity where an owner's `root` is (NULL today), an owner told
     from an A slice by a bit of the `nfields` byte, which strings
     don't use; the research's owner header was 16 bytes. Decide, and
     measure the map kernel's memory either way if you pick 32.
   - **Data from a root:** a B value's bytes are at the root's address
     plus a constant plus the offset, with no load, for owners and
     statics alike; the escape is the one exception.
   - **Uniqueness under B** (rule U): a write or append in place needs
     the root's count to be 1; a slice of a unique root may be written
     in place, since nothing else sees the root. Say whether that's
     taken, and why it's sound.
   - **The debug report's channel:** `note:` on stderr (see "Decided").
   - **Every compile error and panic** this stage adds, with its help,
     as strings.md words them.

   **Baseline,** on the owner's M4 Max, as part one measured (profile/
   build.sh and measure.py, interleaved, medians and spread): the
   research's workloads ported to Ren in bench/native/strs/ (tok, sort,
   map, group and logs, from track-b/c/b1.c and gen.c, the same inputs),
   `out` (track-b's b3: 1M JSON records and 1M log lines built by `+=`,
   and the same by `a + b`, at 5,000 and 50,000 to show the quadratic),
   `utf8` (`Str.from_utf8` of 1 MiB ASCII, CJK and mixed, GB/s), each
   with Rust and Go twins; and the slices kernels (`logs`, `json`,
   `pages`, with slices, against their `_r` forms). Rust twins are
   single `main.rs` files as bench/native's are: FxHash written inline
   (it's 15 lines), `String::push_str` for appending, std's
   `from_utf8`. **The `Map` claim** (scope 7): bench/native/maps' Rust
   twin again with FxHash, and the research's `Map<Str, Int>` workload,
   numbers into compiler.md's step 3 text.

   **Tests,** marked skipped or expected to fail until their step:
   bench/strs.t, as bench/bytes.t is (spec, native debug Perceus and
   naive, release under the sanitizers, tcc, `ren run --release`), and
   test/test_strs.ml with `until "s1"` ... `until "s5"`. At least:
   `invalid_utf8` (every class of invalid sequence at every offset
   mod 16 and 64, truncated at the end for `incomplete`, `at` checked,
   lossy's U+FFFD per maximal subpart), `api` (each new name, the
   panics, `chars` over 1- to 4-byte characters, `'é'`), `interp`
   (holes of every kind, nested strings and braces, `\\{` escaped),
   `append` (`+=` in a loop, in place; on a shared string; on a slice;
   on a literal; through `inout`; `Bytes` too), `slices_kept` (slices
   kept in records, arrays, map keys and values, a type variable's
   value, a block's capture, and returned, then the root dropped, no
   object alive at the end), `escape` (a 4 GiB + 1 `Bytes`, sliced past
   the 32-bit edge, read and appended; skipped where memory won't
   allow, and said so).

1. **The boundary.** The NEON validator in ren_rt.c, with its scalar
   path; `InvalidUtf8(at, incomplete)` in the prelude, builtins.ml,
   intrinsic.ml and every use in one commit (prelude's `Fs.read_str`,
   examples/just, test_deps, test_eval, test_journal, deps.md, and
   whatever the checker finds); `from_utf8_lossy`. The interpreter
   computes `at` and `incomplete` with OCaml's decoder, and native
   builds with the rescan, which starts at the character boundary at or
   before the failing block (an error found in block k can begin up to
   3 bytes into block k - 1). Add a differential test that runs the
   research's agreement test (VERIFY.md: 2M random inputs and the
   boundary cases, verify/c/b5big.c) against the scalar validator and
   OCaml's, as a C program dune builds and runs.
   **Done when** `utf8` runs at 70 GB/s or more on ASCII, about 9 on
   CJK and 13.5 on mixed (the research's NEON numbers: 73.1, 9.01,
   13.5), and the differential test finds no disagreement.

2. **The API.** Scope 5, but `InvalidUtf8`, through the whole pipeline:
   the lexer (`'a'`, `\{`), the parser and AST (an interpolated string
   is a list of literal pieces and expressions, lowered to `show` and
   concatenation), the checker's errors with help, the interpreter,
   natively, tree-sitter's grammar and corpus and Zed's highlights
   (interpolation and character literals are first-class there, not a
   regex), and every doc and example the renames touch. Move programs
   with the compiler's errors as the list, not a grep. `chars()` is a
   prelude cursor written in Ren; `char_floor`, `char_ceil`, `code` and
   `of_code` are intrinsics. strings.md's `len` help names
   `name.chars().count()`, which step 5's `count()` makes compile.
   **Done when** test_strs.ml's s2 is on and every example's tests
   pass.

3. **Appending in place,** on A, before B: the capacity in the owner's
   header, `ren_str_concat` given a `_taking` form that rc.ml uses where
   the left side dies (as `push`'s), doubling, `Bytes` too. The debug
   report as step 0 specifies, firing for a site that copied a shared
   string on more than one pass, so `var out = "["` copying the literal
   once never reports.
   **Done when** `out`'s `+=` runs within 1.1× of its Rust twin's
   `push_str` (the research: in place 157.5 ms against a builder's
   158.8 on JSON, 93.5 against 92.2 on logs), 50,000 records take about
   10× what 5,000 do, and `a + b` in a loop stays quadratic and is
   reported in a debug build.

4. **Representation B,** release builds, with the uncounted view, the
   escape and unboxed map entries, fix by fix, each measured before and
   after as part one's step 1 was. Expect to touch to_mem.ml (the
   layout), emit_c.ml, rc.ml and borrow.ml (a slice of a borrowed
   string is a part), hoist.ml (a loop reads data and length from the
   value, not the object), Mem Lint, the runtime's string functions
   (each takes a value, or a root and a range), and the map runtime.
   **Done when**, against step 3's numbers: tok and sort at 0.80× or
   less (the research: 0.75× and 0.76×), map 0.95× or less (0.91×),
   group no slower, logs 0.90× or less (0.84×) or a tie explained by the
   clang fault; the slices kernels' json and pages within 1.2× of their
   `_r` forms and logs within 1.1× (what the research's hand-written B
   and uncounted view gave: json 196 → 143 Mcyc, pages 17.8 → 8.5, logs
   55.3 → 35.7); every slices and `_r` kernel within 2× of Rust; the
   escape costing 2% or less on each; and nothing else in bench/native
   slower by more than noise. If a target can't be met, say which and
   why, with numbers.

5. **The rest of the API,** scope 6, with tests in test_strs.ml's s5
   and every new name in stdlib.md's table.
   **Done when** s5 is on, `count()` and `count(f)` work on arrays,
   maps, sets and cursors, and `ren run` and native builds agree on
   each name's results and panics.

6. **Review your own work** with three lenses:
   - **Soundness:** uniqueness under B (an append or write through a
     slice of a shared root, a slice of a slice, a borrowed string's
     slice stored, returned or captured, which must count it), the
     escape at its edges, the validator's rescan at block edges, Mem
     Lint and the sanitizers over all of it.
   - **The spec:** does it match strings.md and decision 17, and does
     each "Done when" hold?
   - **Docs and tooling:** README's status and roadmap row, compiler.md,
     stdlib.md, strings.md's "Already built" line (that line only: say
     what's built), the grammar.
   Fix what blocks; list the rest with its severity.

## The interpreter and native

`ren run` keeps `VStr` and `VBytes` as OCaml strings, a slice a copy.
That's fine, because strings.md makes positions relative to the value:
nothing a program sees depends on sharing. What must keep agreeing,
and bench/strs.t checks in every build: offsets and `at`s, every panic
and its message (cutting a character, `code` on a longer string, a
slice past the end, past 4 GiB), `InvalidUtf8`'s payload, lossy's
output, `chars` and `code` on every width of character, and `x.hash()`
of a string. The debug report and capacity are native only; say so in
stdlib.md. The interpreter's `+=` stays quadratic: it's the dev loop,
and meaning is what must agree.

## Risks

- **The clang loop-strength-reduction fault.** In the research's logs
  loop clang kept up to 12 induction variables a byte, one of them the
  packed `{off, len}` advanced by `1 << 32`, and B's 16% win became a
  tie in every layout. Ren emits its own C, so check the release
  assembly of each kernel's scanning loop for it. The research's fix
  was an empty `asm` on the index; prefer emitting the range unpacked
  into two locals before a loop (part one's fix 1b already reads data
  and length before it), and use a barrier only if that fails,
  measured, with a comment saying why.
- **Hot roots.** B makes every kept slice a count on its root. On many
  cores (11b) a root shared by many tasks is decision 10's hot-root
  trap, with atomic counts on one line. It can't be measured until
  11b. Here: build the kernels once with `-DREN_RC_SHARED` and record
  the uncontended cost (the research found none measurable), and leave
  the contended case to 11b's phase two, with SSO as the answer if it
  bites.
- **The interpreter's representation.** Any place native code might
  reveal a root (an offset in the root, a write through one slice seen
  through another) is a disagreement with `ren run`. The tests above
  are how you'd find one.
- **Generic code and descriptors.** Every runtime walk (`==`, ordering,
  hashing, `show`, `ren_array_sort`, the NaN walk, map entries) learns
  B in release, or sees the box. A walk that misreads a 2-slot element
  is a memory error, so run every map, sort and `show` test under the
  sanitizers in release.
- **The data stage's code is new.** B is its largest client. If its
  masks or flattening are wrong for an object slot beside a packed
  scalar, fix the bug where it is and say so.
- **Retention gets easier to hit.** Free slices make it easy to keep a
  big root alive. The report for it is out of scope; note any kernel
  whose peak memory grows.

## THE CHECKS

All must pass before any commit:

- `dune build`
- `dune test --force`, with `REN_TCC` set (tools/tcc.sh), or bench/*.t
  are skipped. bench/build.t, bench/bytes.t and the new bench/strs.t
  run the sanitizer and tcc builds.
- `make -C editors/tree-sitter-ren check`
- `_build/default/bin/main.exe test` inside each of examples/bank,
  examples/prices, examples/just, examples/ledger, examples/crawler,
  examples/refresh, examples/server and examples/transfer, and in each
  new example

Setup, portability and flakes are as part one's brief says
(briefs/stage-bytes.md, "THE CHECKS"): journal.t's timing tests flake
under load; rerun and report, never loosen. **Never weaken or delete a
test to get green.**

**Measuring.** As part one: numbers on the owner's M4 Max with nothing
else building, Ren and its twins interleaved, medians and spread, every
number in bench/native/RESULTS.md with the commands that reproduce it,
and the machine it came from. The research's numbers are a C model
with no checks and hand-written counts, so compare your results to
your own baseline, and to the research's ratios, not its milliseconds.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results untrustworthy.
  Note others in your final report.
- **Do NOT edit foundations.md, language.md, streams.md or strings.md**
  (but the one line above). If they're wrong or underspecified, make a
  choice, record it in compiler.md's section, and list it in your final
  report.
- **Committing:** on main, explicit `git add` paths, never `git add
  -A`; never the root `dune` file's local changes, prior-art.md, or
  anything under .claude/; every message ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push after
  each green step.
- **Keep a progress log** at the end of compiler.md's section.

## Decided

Record these in the spec; don't reopen them.

- **Start after the data stage is merged to `main`.**
- **The `+=` report:** debug binaries print it once per site at a
  normal exit, on stderr as `note:` with the site and a help (`build the
  string once: join, or keep it unique`); the harnesses set
  `REN_NOTES=0` except in the test of the report. The retention report,
  when it's built, uses the same channel. It's a report, not a warning.
- **The interpreter's `+=` stays quadratic.**
- **B in release builds only.** Debug builds keep A, which is also B's
  box and the 4 GiB escape.
- **`Path` and `Os` are out,** for Staging item 7b.
- **The rest of strings.md's API table is in,** as step 5.

## Final report

End with: per step, what was built, the commits, and the choices you
made where the spec was silent; whether each "Done when" holds, with
the numbers before and after, the twins' numbers, and the commands; the
`Map` claim restated; what's unfinished or unsound, with its severity;
and which checks couldn't run.

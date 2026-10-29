# Brief: the bytes stage, part one

You're building the first half of "the `just`, natively" (foundations.md
Staging item 7): string and byte code at Rust's speed in native builds,
`Bytes` reads and writes at an offset (layer 3 of formats.md), and
`Map` and `Set` natively. Ren is a systems language whose compiler is
written in OCaml. Work on `main`. This brief is self-contained: it
names everything you need in the repo.

The owner is new to OCaml. Write code that reads like the code around
it: its comment density, naming and idiom.

**Another session is building the data stage on `main` at the same
time** (briefs/stage-data.md). It changes the parser, the type checker,
pattern matching, native record and variant layout in
`lib/native/to_mem.ml`, and it rewrites every variant with several
fields in every program and doc to a by-name form. Read "Working beside
the data stage" below before you start.

## Read first

- **foundations.md**: Staging item 7, and item 3's gaps (which say
  Ren's string and byte code is 2.6 to 2.8× Rust's time even with
  offsets); decisions 14 (small values, the runtime's header and
  allocator), 15 (sized integers, wrapping operators, shifts), 16
  (loops that don't check bounds) and 17 (slices).
- **formats.md**, "Layer 3: raw bytes", and "Three layers". Layer 3 is
  what this stage builds. Formats themselves (layer 2) are **not** in
  this stage: they need inline slices, which wait for the data stage.
- **bench/native/RESULTS.md**, "Slices": the `logs`, `json` and `pages`
  kernels with slices and with offsets (`_r`), their Rust and Go twins,
  and the corrected ratios. bench/native/README.md for how to measure.
- **compiler.md**: the "Native slice" sections (Mem IR, the runtime,
  `ren build`, release specialization) and step 6, slices. The 10d and
  11a sections show how a stage is specified and then built.
- **operators.md** for `Map`, `Set`, `key`, derived `hash` and
  insertion order; **README.md**'s roadmap row "the `just`, natively".
- foundations.md cites research files that aren't in the repo. You
  don't need them.

## Scope

**In:**

1. **String and byte speed.** Find where Ren's offset-based string and
   byte code spends its cycles against Rust's on the `_r` kernels
   (bounds checks per byte, calls that don't inline, UTF-8 checks
   repeated, counts touched, checked arithmetic on indices, the shape
   of the emitted C), and fix it in the native lowering and the
   runtime. Every fix is sound: a bounds check removed is one the
   compiler proves, never one assumed.
2. **Layer 3 of formats** (formats.md): reads and writes at an offset
   with the width and byte order in the name, `b.u8(at)`,
   `b.u16_le(at)` ... `b.u64_be(at)`, signed forms, `&b.set_u32_le(at,
   x)` and the rest; a cursor over a slice for reading in sequence;
   `VarUInt` and `VarInt` (LEB128, zigzag) helpers. Decided with the owner:
   - **A read at an offset the program computed,** `b.u32_le(at)`,
     **panics** when it's out of range, with the offset and the length,
     as `xs[i]` does: a bad offset is a bug.
   - **A read through the cursor,** `try &c.u32_le()`, **fails with
     `Short(at, need)`**, formats.md's error, `at` the offset in the
     whole buffer: running out of input is an error the program
     handles, and a framing loop reads the same at layers 2 and 3.
   - **`u64_le` and `u64_be` return an `Int`, and panic** (through the
     cursor: fail with `Malformed`) on a value of 2⁶³ or more. `i64_le`
     and `i64_be` read the same bits as a signed `Int`, so a 64-bit
     hash or checksum is read with them (decision 15: a 64-bit hash
     stays an `Int`).
   - A value that doesn't fit a write panics, as storing into a sized
     integer does.

   In the interpreter and natively. Settle the exact names and the
   cursor's API in the spec (step 0); keep them in the style formats.md
   shows.
3. **`Map` and `Set` natively,** with the interpreter's meaning:
   insertion order, `key`, derived `hash` and `==` natively, and the
   `Enumerable` methods on them. A dense array of entries plus an index
   table, as Python's dict and Rust's indexmap keep insertion order, is
   the expected shape; decide it in the spec. **Hashing, decided with
   the owner:** `Map` and `Set` hash with a fast hash (wyhash or
   rapidhash class) mixed with a random seed per process, as Go's maps
   do, so keys chosen by an attacker can't force collisions. Iteration
   is in insertion order, so the seed changes only speed, never what a
   program sees. Under `sim` and replay the seed is fixed. The `hash` a
   program can call, derived `x.hash()`, is unseeded and the same on
   every run, so what's printed or journaled stays reproducible; the
   map's internal hash differs from it, which no program can observe.

**Out (don't start them):** inline slices and the uncounted view
(foundations decision 17's representation B; slices stay
representation A), formats (layer 2), `Table` and `Pool`, `bin`, the
world natively (`Fs`, `Os`, `Proc`), native tasks, and anything in the
data stage's scope.

## Working beside the data stage

- **Don't touch** pattern matching, record and variant layout in
  `to_mem.ml`, or the parser and type checker beyond registering new
  built-ins.
- **New tests go in new files.** Don't rewrite existing tests.
- **New Ren code uses no variant with several fields,** in declarations,
  constructors or patterns, since its syntax changes partway through
  the data stage. Records, one-field variants, tuples and fieldless
  variants are fine.
- **Rebase before every push.** If a conflict touches the data stage's
  work, keep theirs and redo yours on top. If a check goes red because
  of their commits, not yours, record it and don't fix their work.

## Steps

Do them in order. After each step, THE CHECKS must pass; then commit
and push. If a step can't be finished soundly, leave main green, commit
what's finished, and write down exactly what's missing.

0. **Spec, baseline, tests first.** Add a "Bytes stage" section to
   compiler.md. Profile the `_r` kernels and bench/native/bytes against
   their Rust twins, and write down, per kernel, where the cycles go and
   what Rust's code does that Ren's doesn't, with instruction counts.
   Settle the layer 3 API and the native `Map` and `Set` representation.
   Then write the test programs, marked skipped or expected to fail
   until the step that builds them: layer 3 reads, writes, the cursor
   and the panics, in both builds; `Map` and `Set` programs that compare
   `ren run` with `ren build`, insertion order and removal included.
1. **String and byte speed,** fix by fix, each measured before and
   after, release builds.
2. **Layer 3,** in the interpreter and natively, with a new kernel in
   bench/native: decoding a stream of length-prefixed little-endian
   records with a `VarUInt` field, written with the layer 3 API, with
   Rust and Go twins.
3. **`Map` and `Set` natively,** derived `hash` included, with a kernel
   in bench/native that builds, looks up, removes from and iterates a
   map of records keyed by `Int` and by `Str`, with Rust (std `HashMap`
   plus insertion order, or `indexmap` if the twins already use crates)
   and Go twins.
4. **Review your own work** with three lenses:
   - **Soundness:** every removed check has a proof in the spec;
     adversarial programs for offsets at the edges, negative and
     overflowing offsets, a cursor past the end, maps that grow and
     shrink while iterated (whatever the interpreter says that does,
     native does too); Mem Lint and the sanitizers over all of it.
   - **The spec:** does it match foundations.md and formats.md's layer
     3, and does "Done when" hold?
   - **Docs and tooling:** README's status and roadmap, compiler.md,
     formats.md's layer 3 section if a name changed (that section only),
     stdlib.md, the grammar if anything parses differently (it
     shouldn't).
   Fix what blocks; list the rest with its severity.

**Done when** the `logs_r`, `json_r` and `pages_r` kernels and
bench/native/bytes each run within 2× of their Rust twins' time in
release builds; layer 3 works in both builds and its kernel is
measured against Rust and Go; and `Map` and `Set` build natively,
agreeing with the interpreter, with their kernel measured. If a kernel
can't reach 2× without inline slices or another out-of-scope change,
say exactly which and why, with numbers.

## Interpreter and native

Everything here is sequential, so every feature works in the
interpreter and in native builds, debug and release, and the two agree.
Add cases to bench/build.t for each feature.

## Language changes go through the whole pipeline

This stage adds built-ins, not syntax. Each still goes through types,
the interpreter, native debug and release, error messages with help
lines, and the docs that describe it. If anything needs syntax, stop
and say so: it belongs to another stage.

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
- python3; Rust (stable) and Go, for the twins; hyperfine if you can
  install it.
- tcc: `tools/tcc.sh`.

The repo was developed on macOS; 11a ran in this environment, and its
portability fixes are in. If a check fails at the start before you
change anything, fix it when it's a portability bug in the repo (and
say so). Otherwise record exactly which checks you couldn't run.
**Never weaken or delete a test to get green.** Tests that check
real-time ordering are known to be sensitive to a loaded machine; if
one flakes, rerun it, and report it rather than loosening it.

**Measuring.** Numbers from this machine are for before-and-after
comparisons and ratios against twins built and run on the same machine
in the same session. The owner re-measures headline numbers on their
own hardware, so say which machine yours came from, and record every
number in bench/native/RESULTS.md with the commands that reproduce it.
On a cloud machine, interleave runs and report medians and spread,
since its cores are shared. On the owner's Mac, numbers can be
headline ones: run measurements with nothing else building, interleave
Ren and its twins, and report medians and spread.

## Rules

- **Be sound.** Mem Lint and Core Lint keep checking. Every shortcut
  says why it's sound.
- **Fix only bugs that block your step** or make results untrustworthy.
  Note others in your final report.
- **Do NOT edit foundations.md or language.md.** If they're wrong or
  underspecified, make a choice, record it in compiler.md's bytes
  section, and list it in your final report.
- **Committing:**
  - Commit on main with explicit `git add` paths, never `git add -A`.
  - Never commit the root `dune` file's local changes, prior-art.md, or
    anything under .claude/.
  - End every commit message with
    `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Push to main after each green step. If you can't push to main, push
    a branch named `stage-bytes` and say so.
- **Keep a progress log** at the end of compiler.md's bytes section
  (step, commit, what's done, what's left), so a resumed session can
  pick up where it stopped.

## Final report

End with:
- **Per step:** what was built, the commits, and the choices you made
  where the spec was silent.
- **Whether "Done when" holds,** kernel by kernel, with the numbers
  before and after, the twins' numbers, and the commands that show
  them.
- **What's unfinished or unsound,** with its severity.
- **Which checks couldn't run** in this environment.

# Templates: synthesis

Track A, the synthesis. Inputs: research.md, designs.md, programs.md,
perf.md and verify.md in this folder, plus strings.md and foundations.md
(decisions 1, 4, 13, 14 and 20). Nothing in the repo was edited. I ran no
timings; every number below is from verify.md's re-run, which was taken
under the load rule.

What the owner asked for: checks at build time, templates as plain values
passed explicitly (like Python and JS arguments), C#'s speed, and nothing
hidden.

## The recommendation

**Candidate C: a template is passed down like a block, with no prefix,
checked by a signature `let`.** Six rules:

1. **`"...\{x}"` is a `Str`.** Each hole goes through `show`. Nothing
   changes from strings.md.
   - Prior art: Kotlin and Python f-strings. The plain case stays the
     cheapest case.

2. **`t"...\{x}"` is a `Template<H>`, never a `Str`.** It has a static
   half, the site, made while building: the parts, the raw parts, each
   hole's source text and static type, and the literal length. It has a
   dynamic half, the holes, evaluated eagerly left to right, as the
   tuple `H`. Nothing converts a `Str` to a template or back implicitly.
   `t.render()` is the one way to a `Str`.
   - Prior art: Python's PEP 750 (a template is its own type; `Template +
     str` is an error), Java after JEP 465 was withdrawn (the template
     is the star; methods do the processing), JS (one site per literal).
   - Ren: decision 20 rule 1. `Template` names no medium. Rule 2: any
     library takes a template, so a third party's template consumer is as
     checked and as fast as std's.
   - A `Str` passed where a template is expected is a type error. That's
     the mistake JS can't catch (a missing tag silently makes a string).

3. **A template follows the block rule.** It can be passed as an
   argument, bound with `let` and passed on. It can't be stored,
   returned, chosen with `if`, or captured by a block that outlives the
   call (`s.spawn`). To keep one, convert it to the consumer's data:
   `t.render()`, `sql.frag(DB, t)`, `html.of(t)`.
   - Prior art: C#'s handler is a `ref struct`; Rust's `fmt::Arguments`
     can't outlive its statement. Every zero-allocation design in the
     survey has this rule.
   - Ren: decision 1, applied to one more thing. A template is two
     words, the site and a pointer to holes in the caller's frame.
     Nothing allocates, at any number of holes, in either build.

4. **A `let` between a signature and its `=` runs while building, once
   per call site.** It reads only what's known while building: a
   template's site, a type's shape, literals, top-level values. A `try`
   that fails there fails the build at the call. The body reads the
   result as a constant: a plan, not just a pass or fail.
   - Prior art: C++20's `format_string` (the check lives in the callee's
     parameter type, run at compile time), Zig's `std.fmt` (library code
     at comptime), HEEx and HypertextLiteral (the literal is parsed once,
     statically, into chunks and contexts).
   - Ren: shapes.md ("the position says when it runs") and decision 20
     rule 3 (build-time checks through one general mechanism, never one
     written for a library). This extends top-level `let` by one
     position. It isn't for templates only: `regex.compile` and
     `Duration.parse` with a literal argument use it too.
   - Two limits, both errors with help. A signature `let` that depends
     on a type parameter of the caller is refused, because debug builds
     never specialize (decision 13). Forwarding a template through a
     wrapper to a signature `let` is refused; the wrapper takes the
     consumer's own type (`sql.Query`).
   - It may read only the build's world (`Fs` inside the package,
     `Git`). Never a database: sqlx's live database at build time is the
     part its users hate most.

5. **A hole's kind or format is a value:** `\{sql.table(kind)}`,
   `\{html.raw_trusted(s)}`, `\{fmt.pad(n, 6)}`. There's no format
   language.
   - Prior art: postgres.js (`sql(ident)` inside a hole), doobie's
     typed fragments. Python's `{x:i}` and Swift's labels exist to fill
     the gap that a missing value-level wrapper leaves.
   - Ren: strings.md's "no mini-language". A consumer's plan decides
     what each hole's shape means and refuses the ones it can't handle.

6. **`\{x=}` is `x=\{x}`,** in `"..."` and `t"..."` alike. Only a name
   or a path may come before `=`.
   - Prior art: Python's `f"{x=}"`.

Rules 1, 2, 5 and 6 are a literal. Rule 3 is decision 1 reused. Rule 4
is the only new mechanism.

**The site's identity.** `site.id` is one `Int` per literal, a cache key
inside one process (JS's per-site strings array, lit-html's cache). It
never crosses a journaled dependency call, because a rebuilt binary
renumbers sites. Where a dep needs a key (prepared statements, log
message ids), the consumer passes `site.hash`, a hash of the parts.
designs.md and programs.md broke their own rule here; this fixes it.

## Why not the others

- **A (a template you can keep):** one allocation for most real
  templates, a retention trap like slices', and a kept template has lost
  its call site, so its check is gone. No program in programs.md needed
  to keep a template. Each one that kept something wanted the
  consumer's data instead.
- **B (`DB"..."` prefix):** Goetz's argument for withdrawing Java's
  processors: a prefix is a second spelling of a method call. In SQL it
  loses the verb and the row type. In logs and i18n there's nowhere to
  put the level or the language. In HTML and JSON it needs a made-up
  value to hang on. Its one gain is tree-sitter injection by prefix
  name, which a language server gets from the signature `let`.

## Measured performance

Apple M4 Max, clang -O2 -ffp-contract=off, rustc -C opt-level=3. hyperfine
-N, 3 warmups, 25 runs, 10M ops a run. The ratio is against the Rust
`write!` twin's median; the bracket is the fastest and slowest run over
that median. All C variants are hand-written as release should emit
them, against Ren's real runtime. Every log and HTML variant writes the
same bytes (byte hash). perf.md's first run reproduced: instructions
match to the unit and cycles within 3% (log, SQL) and 11% (HTML).

Load (1-minute) before each group: log 3.23, SQL 3.98, HTML 3.89. The
other experiment pushed load up during some runs. Cycle counts stayed
within 3% across runs, so the slowdowns were clock speed, not work.

**Log line, 4 fields (two `Str`, two `Int`), into a reused buffer**

| variant | ns/op | ratio [min-max] | cycles | allocs |
|---|---|---|---|---|
| today, as Ren emits it | 128.7 | 3.29 [3.19-3.50] | 509 | 10 |
| today, with a digit-pair `show_int` | 78.0 | 1.99 [1.96-2.05] | 311 | 10 |
| A: boxed holes | 17.0 | 0.43 [0.42-0.44] | 66 | 1 |
| C: specialized per `H` only | 19.8 | 0.51 [0.50-0.52] | 79 | 0 |
| **C: specialized per site** | **15.2** | **0.39 [0.38-0.39]** | **60** | **0** |
| C: not specialized (debug's shape) | 21.7 | 0.56 [0.55-0.59] | 87 | 0 |
| C#-handler style | 15.7 | 0.40 [0.39-0.41] | 62 | 0 |
| Rust `write!` | 39.1 | 1.00 [0.98-1.01] | 156 | 0 |

**HTML row, 5 holes, 4 escaped**

| variant | ns/op | ratio [min-max] | cycles | allocs |
|---|---|---|---|---|
| today: escape to a new `Str`, concat | 189.8 | 1.88 [1.85-1.97] | 756 | 15 |
| A: boxed + plan | 74.0 | 0.73 [0.71-0.78] | 294 | 1 |
| **C + plan** | **63.5** | **0.63 [0.62-0.65]** | **256** | **0** |
| C#-handler style | 61.1 | 0.61 [0.59-0.63] | 246 | 0 |
| Rust `write!` + `Escape` | 100.8 | 1.00 [0.98-1.05] | 401 | 0 |

**SQL to (text, params)**

| variant | ns/op | ratio [min-max] to Rust reused `Vec` | cycles | allocs |
|---|---|---|---|---|
| today: constant text, params `Array` | 17.8 | 8.69 [8.46-10.14] | 71 | 1 object |
| today, interpolated into the text (unsafe) | 82.4 | 40.3 [39.7-41.5] | 329 | 10 |
| C + plan, params array reused | 1.3 | 0.64 [0.62-0.75] | 5 | 0 |
| Rust, static text + reused `Vec` | 2.0 | 1.00 [0.97-1.12] | 8 | 0 |

What the numbers say:

1. **C's lowering is C#'s.** Within noise on log and HTML. There's
   nothing more to take from C#.
2. **C beats Rust's `write!`:** 2.6x on the log line, 1.6x on HTML.
   `fmt::Arguments` makes a vtable call per piece and doesn't fold
   literals.
3. **Per-site specialization is worth more than the box.** Per `H` only
   costs 79 cycles against 60. The box costs A 6 cycles on the log line
   and 38 on HTML. Release should specialize a consumer per site; the
   per-`H` version is a good fallback when the code-size budget runs out
   (30% slower).
4. **SQL: templates buy safety, not speed, as designed.** The 1.3 ns
   reuses a params array across calls. The design makes one array per
   call to cross the `Sql` dependency, which is today's 17.8 ns. The win
   over today is that interpolating into the text, 82 ns and unsafe, has
   no reason to exist.
5. **Today's slowness is mostly not templates.** `snprintf` in
   `show_int` is about 200 of the log line's 509 cycles. A digit-pair
   `show` alone takes it from 128.7 to 78.0 ns.

What the numbers assume:
- The output buffer is cleared and reused. Ren has no `clear()` that
  keeps capacity yet (strings.md, Later).
- Every hole is a variable. A hole that calls a function, or a user type
  with a written `show`, allocates its result until `show` writes into a
  buffer.
- Release folds `pieces()` over `Value` into straight code. The
  prototype hand-wrote the folded result. That's stage 12's existing bet
  for json (risk 2), not a new one.

## Decisions for the owner

1. **Can a template be kept?**
   - Recommend **C, passed down.** Zero allocation as a rule, and every
     check sees a literal.
   - Runner-up: A, a keepable value. It's closer to "plain values like
     Python", and costs one allocation per template (6 cycles on a log
     line, 38 on an HTML row) and the check on any kept template.
   - This is a direct trade against "plain values". C's templates are
     values the way blocks are: passed explicitly, never kept.

2. **Is the signature `let` the check mechanism?**
   - Recommend **yes, as a general rule,** and amend decision 20 rule 3
     to "top-level `let` and `assert`, and a signature `let`".
   - Runner-up: stage 12's F1, a reserved `check` member on the
     consumer's type. It runs just as invisibly to the caller, and it
     needs a reserved name.
   - Be clear on what it is. It's as implicit to the caller as a
     dictionary is. It's explicit in the callee's signature. Its phase
     comes from its position (before `=`), which is the rule top-level
     `let` already uses. The error "a signature `let` read a runtime
     value" must be very good.

3. **The lazy log line (G2).** The owner accepted "eager arguments, plus
   a block when the message is expensive". Under C,
   `log.debug fn() => t"..."` is a block returning a template, which
   rule 3 forbids.
   - Recommend **the guard:**
     `if log.on(Debug) then log.debug(t"tree \{dump(tree)}")`. No new
     rule, and under `log.off()` in a closed world the line compiles out.
     This revises G2.
   - Runner-up: one exception, "a block may end in a template, which the
     call it was passed to consumes". Release inlines it; debug boxes
     the holes.

4. **Where do log field names come from?**
   - Recommend **the hole's source text,** as Python's `expression`,
     with the consumer's plan refusing a hole that isn't a name or a
     path.
   - Runner-up: only `\{x=}` holes become fields. More explicit, and it
     stops renaming a local from silently renaming a field. It costs
     `=` on nearly every log hole.

5. **SQL across the dependency.**
   - Recommend **one params array per call,** today's cost. Templates
     make SQL safe and checked; that's the goal.
   - Runner-up: let a dep operation take a borrowed tuple, which the
     journal serializes when recording. That gets the 1.3 ns, but
     changes the dep boundary for one library. Revisit with the driver's
     wire encoding, which every variant pays anyway.

6. **Raw and multi-line literals.** The JSON and HTML programs are full
   of `\"`.
   - Recommend deciding `t"..."`, `b"..."` and a raw form
     (`"""..."""`) together, as strings.md's Later already ties
     `b"..."` to this question.
   - Runner-up: ship `t"..."` alone and take raw literals later.

## The work it implies

| Work | Where it lands |
|---|---|
| `\{x}` in `"..."`: lexer, parser, holes through `show`. Today the compiler says "`\{` isn't an escape" | the `just` natively (strings), now |
| A digit-pair `show_int` | now; worth it without templates (128.7 to 78.0 ns) |
| `Str.clear()` keeping capacity, `reserve` | the `just` natively, with strings |
| `show` writing into a buffer, so a user type's hole doesn't allocate | the `just` natively; helps plain `"..."` as much |
| `t"..."`, `Template<H>` and `Site` in the prelude, `\{x=}` | stage 12, with top-level `let` |
| The block rule extended to templates, including no capture by a block that outlives the call | stage 12; reuses 10c's checker |
| Signature `let`: per-call-site evaluation in the build interpreter, cached by the journal; refusals for type parameters and forwarding; carets at a byte of the literal (the reporter maps plan offsets to source bytes) | stage 12, beside top-level `let` (shapes.md) |
| `site.hash` for anything crossing a dep | stage 12; a note in handlers.md's journal section |
| Release specializes a consumer per site ("a template literal specializes like a block literal"), counted against decision 4's budget, falling back to per `H` | stage 14; written into decision 4 now |
| Folding `pieces()` over `Value` for a known `H` | stage 12's risk 2; same harness as json's shape specialization |
| std consumers: `sql.plan`, `html.plan`, `log`, `proc.run`, `json.of`, `i18n` | stage 12, `sql` and `log` first (flottning needs both) |

Docs to change when this is accepted: strings.md (`\{x=}`, `t"..."`, the
Later list), foundations.md (decision 1 names templates, decision 4 names
per-site specialization, decision 20 rule 3 names the signature `let`),
shapes.md (the second build-time position) and stdlib.md (the
tagged-template question closed).

# Templates: verification and a skeptic's review

Track A verify. I re-ran perf/ from source, checked the C prototype
against designs.md, and read designs.md and programs.md against
strings.md, errors.md, shapes.md and foundations.md (decisions 1, 4, 13
and 14). Nothing in the repo was edited. My files are in
`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/interp-exp/verify/`.

## Contents

- [Verdict](#verdict)
- [The numbers, re-run](#the-numbers-re-run)
- [Does the prototype do what designs.md says?](#does-the-prototype-do-what-designsmd-says)
- [Critique](#critique)
- [Top five problems](#top-five-problems)

---

## Verdict

- **The numbers reproduce.** Cycles agree with perf.md within 3% on log
  and SQL, and within 11% on HTML, where mine are lower. Every ratio's
  direction holds.
- **The output checks hold.** All log and HTML variants hash the same
  bytes. SQL and the Rust twins agree on their (coarser) checksum.
  Allocation counts match allocs.json exactly.
- **The SQL headline doesn't follow from the design as written.** The
  1.2 ns, 0-allocation `sql-plan` reuses a params array the consumer
  keeps across calls. designs.md's own `rows` sketch makes a fresh array
  per call to cross the `Sql` dependency. That is `sql-today`'s shape:
  about 18 ns and 71 cycles. So for SQL, templates buy safety, not speed.
- **The log and HTML results are sound, with two assumptions.** The
  output buffer is cleared and reused, which Ren can't do yet (strings.md
  lists `clear()` under Later). And the best numbers need per-site
  specialization, which Ren's specializer doesn't do (it specializes on
  types and blocks, not on constant values).
- **The design has one real soundness gap:** a signature `let` that reads
  `T.shape` or a hole's type can't run at a call inside generic code in
  a debug build, because debug builds never specialize.

---

## The numbers, re-run

I rebuilt `c/interp.c` and `rust/main.rs` into `verify/bin/` with the
same flags (clang 16, `-O2 -ffp-contract=off`; rustc 1.99.1,
`-C opt-level=3 -C codegen-units=1`). I used perf's `today/ren-today`,
which Ren built. hyperfine 2.0.0, `-N`, 3 warmups, 25 runs, 10M ops a
run. Per op = (run − the same binary at n = 0) / 10M. The bracket is the
variant's fastest and slowest run over the reference's median.

**Load.** Each group waited until the 1-minute load was below 4.

| group | load before (1, 5, 15 min) | load after | waited |
|---|---|---|---|
| base | 3.85 4.57 5.78 | 3.85 4.57 5.78 | 0 |
| log (first, discarded) | 3.85 4.57 5.78 | 8.81 7.45 6.79 | 0 |
| sql | 3.98 5.82 6.22 | 4.92 5.79 6.18 | 2.5 min |
| html | 3.89 4.96 5.71 | 3.59 4.37 5.32 | 4.5 min |
| base2 | 3.59 4.37 5.32 | 3.59 4.37 5.32 | 0 |
| log (re-run, in the table) | 3.23 4.25 5.26 | 2.98 3.91 4.97 | 0 |

The load hit 11 during the first log run. Its wall times were up to
1.6× high and its spread wide (Rust `write!` 0.87 to 1.41), but its
cycles were within 3% of the re-run. So I discarded its times and kept
the re-run.

### Log line, 4 fields

| variant | ns/op | ratio [min-max] | cycles/op | instr/op | perf.md cycles |
|---|---|---|---|---|---|
| today, as emitted (snprintf) | 128.7 | 3.29 [3.19-3.50] | 509 | 2962 | 505 |
| today, fast `show_int` | 78.0 | 1.99 [1.96-2.05] | 311 | 1726 | 313 |
| today, real Ren binary | 119.9 | 3.06 [2.98-3.13] | 483 | 2843 | 487 |
| A: boxed | 17.0 | 0.43 [0.42-0.44] | 66 | 434 | 66 |
| C: per H only | 19.8 | 0.51 [0.50-0.52] | 79 | 454 | 79 |
| **C: per site** | **15.2** | **0.39 [0.38-0.39]** | **60** | **296** | 60 |
| C: walk (unspecialized) | 21.7 | 0.56 [0.55-0.59] | 87 | 545 | 87 |
| C#-handler style | 15.7 | 0.40 [0.39-0.41] | 62 | 329 | 62 |
| Rust `write!` | 39.1 | 1.00 [0.98-1.01] | 156 | 941 | 155 |
| Rust `format!` + push | 59.9 | 1.53 [1.51-1.58] | 239 | 1481 | 239 |

### SQL to (text, params)

| variant | ns/op | ratio [min-max] | cycles/op | instr/op | perf.md cycles |
|---|---|---|---|---|---|
| today: constant text, params `Array` | 17.8 | 8.69 [8.46-10.14] | 71 | 539 | 72 |
| today's interpolation (unsafe) | 82.4 | 40.3 [39.7-41.5] | 329 | 1814 | 333 |
| handler, text per call | 13.1 | 6.40 [6.32-6.48] | 52 | 185 | 52 |
| A: boxed + plan | 5.1 | 2.47 [2.36-2.49] | 20 | 149 | 20 |
| **C + plan, reused params** | **1.3** | **0.64 [0.62-0.75]** | **5** | **46** | 5 |
| Rust sqlx-style | 1.3 | 0.62 [0.62-0.67] | 5 | 36 | 6 |
| Rust reused `Vec` | 2.0 | 1.00 [0.97-1.12] | 8 | 59 | 8 |
| Rust text per call | 37.0 | 18.1 [17.8-18.3] | 149 | 1122 | 149 |

### HTML, 5 holes, 4 escaped

| variant | ns/op | ratio [min-max] | cycles/op | instr/op | perf.md cycles |
|---|---|---|---|---|---|
| today: escape to new Str, concat | 189.8 | 1.88 [1.85-1.97] | 756 | 3453 | 799 |
| A: boxed + plan | 74.0 | 0.73 [0.71-0.78] | 294 | 1402 | 333 |
| **C + plan** | **63.5** | **0.63 [0.62-0.65]** | **256** | **1238** | 286 |
| C#-handler style | 61.1 | 0.61 [0.59-0.63] | 246 | 1238 | 289 |
| Rust `write!` + `Escape` | 100.8 | 1.00 [0.98-1.05] | 401 | 2064 | 404 |
| Rust `format!` + push | 141.4 | 1.40 [1.37-1.43] | 563 | 3229 | 573 |

Instructions match perf.md to the unit everywhere, so it's the same
code. HTML's cycles came out 5 to 12% lower for the C variants and the
same for Rust; I can't explain that, and it doesn't change any
conclusion. The C plan and the handler are within noise of each other
in both runs.

**Allocations** (`-DREN_STATS` build and the counting Rust allocator,
10,000 ops): log today 10/op, A 1, every C and handler variant 0; SQL
today 1 object, inline 10, A 1, C 0; HTML today 15, A 1, C 0; Rust as
allocs.json says. The output buffer grew once per run in every variant.

---

## Does the prototype do what designs.md says?

**What checks out.**
- Today's log line is what Ren emits. I counted the calls in
  `today/today.c`'s `ren_main_line_1`: 8 `ren_str_concat`, 2
  `ren_show_int`. `log_line_today` copies that.
- C's template is `{site *, holes *}` with the holes as a struct in the
  caller's frame, as designs.md describes. No `ren_dup` on the holes,
  which is right for borrowed arguments under Perceus.
- The per-H variant does load parts from the site at run time; the
  per-site variant folds them. That isolates the specialization effect
  cleanly.
- Every log and HTML variant writes the same bytes as today's real
  `ren_str_concat` path (full FNV hash under `-DCHECK`).

**What doesn't match, or is weaker than it looks.**

1. **SQL's reused params array isn't in the design.** `sql_plan_c`
   writes into `param ps[8]`, owned by the benchmark loop and reused.
   designs.md's `rows` body says `let params = plan.bind(q) // one array
   per call, crosses the dep`, and Open question 6 says the same. A Ren
   function has no hidden state to keep a buffer in, so reuse would need
   an explicit `inout` argument or the handler's state. As designed,
   SQL costs what `sql-today` costs (constant text plus one params
   `Array`), 71 cycles, not 5. Templates remove the injection risk and
   the hand-numbered `$n`; they don't make the query cheaper.
2. **The HTML benchmark's template would fail its own check.**
   programs.md says an `href` hole takes `url.Url` only. The benchmark
   puts an `Int` in `href="/u/\{id}"`. Harmless for timing, but the
   plan's rule is stricter than the program the numbers come from, and
   the rule probably needs a "hole after a literal path prefix" case.
3. **HTML's C variant ignores the site** (it passes `NULL`, the chunks
   are globals). So it is the per-site case only. There's no per-H HTML
   number; on the log line that difference was 19 cycles of 79.
4. **The buffer is cleared and reused.** The loop sets `out.len = 0`
   every 4 KiB. Ren has no `clear()` that keeps capacity (strings.md,
   Later). Appending through `inout out: Str` also needs a uniqueness
   test per append, which the prototype leaves out. Both are small, but
   the "0 allocations" for log and HTML depends on the first being added.
5. **Holes are pre-existing values.** Every hole is a variable. A hole
   that is a call (`\{url.job(j.id)}`, a user type's `show`) allocates
   its result. designs.md says so; perf.md's "zero allocation, any
   size" reads stronger than it is.
6. **The SQL checksum is coarse.** It sums text length, the last byte
   and the params. Since every C variant uses the same constant text,
   that's fine here, but it isn't the byte hash the log and HTML get.
7. **Minor:** the Ren binary's n = 0 baseline is Rust's (about 1 ms of
   1.2 s). It doesn't move anything.

---

## Critique

### Where it's implicit

- **The signature `let` is invisible at the call.** `DB.rows<Job>(t"...")`
  runs `sql.plan` while building, may read files through `DB`, and
  passes a hidden constant into the body. designs.md rejected F1's
  reserved `check` member because it "runs implicitly". The signature
  `let` is just as implicit to the caller; it only moves the code to a
  place the callee's author sees. It's defensible (dictionaries are
  hidden arguments too), but it should be argued as that, not as "more
  explicit".
- **Phase is decided by which side of `=` a `let` is on.** shapes.md
  says "the position says when it runs", and that position is the top
  level, which is far from runtime code. Here a build-time `let` and a
  runtime `let` sit two lines apart and differ only in whether they come
  before the `=`. One misplaced line changes when code runs. If this
  rule is kept, it needs a visual marker or the error "a signature
  `let` read a runtime value" must be very good.
- **Hole names become data.** Log fields and i18n keys come from the
  hole's source text. Renaming a local (`count` to `n`) changes a log
  field's name and breaks every catalog. The i18n check catches the
  catalogs; nothing catches a dashboard keyed on the old log field.
  `\{n=}` is fine; deriving field names silently from every hole is the
  implicit part. Consider requiring `\{n=}` or a name for a field.
- **`at` is a field-name convention.** "If the error has an `at`, the
  caret goes at that byte of the literal." errors.md tags are
  structural, so the build reporter would match any payload named `at`.
  And it's an offset into which text? `sql.plan` parses `parts` (escapes
  processed, holes as `?`), not `source`. The reporter needs a mapping
  from plan offsets to source bytes that no one owns yet.
- **The log line's hidden buffer.** programs.md has `log.info` encode
  into "the task's log buffer". That's ambient state, not visible in any
  signature. It should be the `Log` handler's state, reached through the
  dep, and said so.

### Where a build-time check is unsound or impossible

- **Generic code, in debug builds.** A signature `let` reads `T.shape`
  and the holes' types. Inside `fn find<K>(k: K) = DB.rows<Job>(t"...
  \{k}")`, `K` is known only per instantiation. Decision 13: debug
  builds never specialize and each module compiles alone; shapes.md:
  debug reads shapes at run time. So the check can't run at that call in
  debug. The choices are (a) refuse a signature `let` that depends on a
  type parameter of the caller, (b) run it per instantiation in a
  whole-program pass, which decision 13 forbids for the front half and
  which brings back shapes.md's "generics are checked only when used",
  or (c) run it at run time in debug, which makes the check differ
  between builds. designs.md doesn't mention this. I'd take (a): a hole
  of a type-parameter type is refused by a checked consumer, with help
  to take a concrete type or a `sql.Frag`.
- **HTML contexts after a raw hole.** `html.plan` finds each hole's
  context from the literal around it. A preceding `html.Html` hole can
  change the context (an unclosed `<script`, an open attribute). That's
  safe only if every `Html` is balanced. `html.of` can check that;
  `html.raw_trusted` can't. Go's `html/template` has the same hole. The
  rule should be stated: `raw_trusted` must be balanced, checked at run
  time when it's made.
- **SQL fragments** are checked against every table's columns and spliced
  unchecked. programs.md says so. That's honest, but it means `search`,
  the most common dynamic query, gets a run-time `SqlError` for a typo
  in a fragment column that exists in some other table.
- **Forwarding** is an error. Any repository function that takes a
  query (`fn one<T>(q: Template<H>)`) breaks. That's most real code
  around a database. The escape (`sql.Query`) works, but it means the
  check moves to wherever the `Query` is built, and every wrapper needs
  one.

### Where it needs a feature Ren lacks

| Needed | Status |
|---|---|
| Signature `let`: per-call-site build-time evaluation | new; designs.md's rule 4 |
| Specializing a consumer on a constant site or plan, not a type | new. Decision 4 specializes per type, per layout and per block literal. Per-site needs "a template literal specializes like a block literal", which should be written down |
| Release folding `gen fn pieces()` over `Value` into straight code | stage 12's unproven bet (synthesis risk 2). The prototype hand-writes the folded result |
| `clear()` keeping capacity, `reserve` | strings.md "Later"; designs.md uses `out.reserve` |
| `show` into a buffer | designs.md open question 5. Without it every user-type hole allocates |
| Raw / multi-line literals | open question 4; JSON and HTML programs need it |
| `out: &Str` parameter syntax | Ren writes `inout out: Str`; `&` is at the call |

So "rule 4 is the only one that isn't already in Ren" undercounts. The
semantics need one new rule; the speed needs value specialization, a
fold the compiler can't do yet, and two `Str` operations.

### How it composes

- **strings.md.** Rule 1 leaves `"..."` alone, good. strings.md's
  `"\{fmt.pad(n, 6)}"` and designs.md's `fmt.Padded<T>` agree. The
  `\{x=}` sugar applies to `"..."` too, which changes strings.md; fine,
  but say so there. strings.md defers tagged templates to stdlib.md and
  `b"..."` to the same decision; `t"..."` should be decided with `b"..."`
  and raw literals at once, as designs.md suggests.
- **errors.md.** `try` in a signature `let` doesn't add to the
  function's `!` set; it fails the build at the caller. That matches
  `try` at the top level (shapes.md), so it composes, but the callee's
  error type (`BadSql`) now reaches the caller's build output from a
  file the caller never wrote. The error's "note: checked by `sql.plan`"
  line handles that well. `Sql.rows_unchecked` by name is the right
  escape.
- **Decision 1 (blocks).** C's rule copies the block rule cleanly:
  pass, `let`, no `if`, no store, no return. Two gaps. A block passed to
  `s.spawn` outlives its call; can a template be captured by such a
  block? It must not, or its holes' frame can die first. And the lazy
  log form `log.debug fn() => t"..."` is refused, which contradicts the
  G2 answer the owner was just offered ("eager arguments plus a block
  when the message is expensive"). Under C, G2 becomes the `if log.on`
  guard, or the block exception. That needs to go back to the owner.
- **Decision 4 (closed world, code size).** Per-site specialization is
  a copy of the consumer per literal, like per-block copies, which
  "don't fold, and only the budget bounds them". A service with 2,000
  log lines gets 2,000 copies of `log.write`'s body, each small (the
  handler style is about 300 instructions per call here). It should be
  counted against the budget, and the budget's fallback should be the
  per-H version (79 cycles), not a boxed call. That's a good fallback:
  only 30% slower.
- **Journaling.** designs.md says `site.id` is stable only within a
  build and must never be journaled. programs.md's `rows` puts
  `site: q.site().id` into the `Query` given to `Sql.rows`, and `log`
  gives `site_id` to `Log.event`. Both are journaled dependency calls.
  Replay against a rebuilt binary would see different ids. Either key on
  a content hash of the site, or keep the id out of dep arguments.
- **The owner's ask.** "Plain values passed explicitly, like Python and
  JS args." C's templates are not plain values; they're block-like.
  designs.md says so, and the programs show nothing needed to keep one.
  But it's a direct trade against what the owner asked for, and the
  owner should make it, with the numbers: A costs one allocation (6
  cycles on the log line, 38 on HTML) and loses the check on any kept
  template.

---

## Top five problems

1. **The SQL win isn't in the design.** 1.2 ns comes from a params
   array reused across calls. The design makes one per call to cross
   `Sql`, which is today's 18 ns. Templates make SQL safe, not faster,
   unless the dep boundary can take a borrowed tuple.
2. **Signature `let`s can't run in generic code in debug.** A hole or
   row of a caller's type parameter has no shape while building, and
   debug never specializes. Refuse it, or the check differs by build.
3. **The speed needs features Ren doesn't have.** Per-site value
   specialization, folding `pieces()` over `Value`, `clear()` and
   `reserve` on `Str`, and `show` into a buffer. "Rule 4 is the only new
   one" is true of meaning, not of the numbers.
4. **The signature `let` is as implicit as F1's `check`,** and its
   phase hangs on which side of `=` it sits. Hole names silently become
   log fields and i18n keys. Each needs a marker or an explicit name.
5. **C breaks two things the owner was promised.** Templates aren't
   plain values, and the G2 lazy block `log.debug fn() => t"..."` is
   refused. `site.id` also leaks into journaled dep calls, against
   designs.md's own rule.

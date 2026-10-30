# Templates: what the lowering costs

Track A perf prototype for designs.md's recommendation (candidate C: a
template is passed down like a block, checked by a signature `let`). The
question: does C's lowering reach C#'s "no allocation, holes straight into
the buffer", and how far is it from today and from Rust?

Nothing in the repo was edited. Everything is in
`/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/interp-exp/perf/`.

## Contents

- [Results](#results)
- [Conclusions](#conclusions)
- [What was built](#what-was-built)
- [How it was measured](#how-it-was-measured)
- [Caveats](#caveats)

---

## Results

Apple M4 Max, clang -O2 -ffp-contract=off (Ren's release flags), rustc
-C opt-level=3 -C codegen-units=1. 10M operations per run. hyperfine -N,
3 warmups, 25 runs. Per op = (run − the same binary at n=0) / 10M.
Ratio is against the Rust `write!` twin's median; the bracket is the
variant's fastest and slowest run over that median. Allocations come from
`--stats` builds (Ren's counter) and a counting global allocator (Rust).
Instructions and cycles are hyperfine's per-run counters, medians.

### Log line, 4 fields, appended to a reused buffer

`"level=\{level} path=\{path} status=\{status} ms=\{ms}\n"`, two `Str`
and two `Int` holes, about 45 bytes out.

| variant | ns/op | ratio to Rust `write!` | allocs/op | instr/op | cycles/op |
|---|---|---|---|---|---|
| today, as emitted (`show` = snprintf) | 125.0 | 3.25 [3.16-3.37] | 10 | 2962 | 505 |
| today, real Ren binary (builds the Str only) | 120.7 | 3.14 [3.07-3.22] | 10 | 2843 | 487 |
| today, with a fast `show_int` | 75.9 | 1.97 [1.95-2.05] | 10 | 1726 | 313 |
| A: boxed holes (site constant-folded by clang) | 16.7 | 0.43 [0.42-0.45] | 1 | 434 | 66 |
| C: passed down, specialized per H only | 19.8 | 0.51 [0.51-0.53] | 0 | 454 | 79 |
| **C: passed down, specialized per site** | **15.1** | **0.39 [0.39-0.40]** | **0** | **296** | **60** |
| C: not specialized (walks site, switch per hole) | 21.6 | 0.56 [0.55-0.58] | 0 | 545 | 87 |
| C#-handler style (AppendLiteral/AppendFormatted) | 15.4 | 0.40 [0.39-0.41] | 0 | 329 | 62 |
| Rust `write!` into a reused String | 38.5 | 1.00 [0.98-1.02] | 0 | 941 | 155 |
| Rust `format!` then `push_str` | 59.4 | 1.54 [1.51-1.58] | 1 | 1481 | 239 |

### SQL, rendered to (text with `$n`, params)

`t"select id, name, state from jobs where owner = \{owner} and state = \{state} and created_at > \{since} order by id limit \{n}"`,
three `Int` holes and one `Str`.

| variant | ns/op | ratio to Rust (reused Vec) | allocs/op | instr/op | cycles/op |
|---|---|---|---|---|---|
| today: constant text, params an `Array<P>` as Ren emits it | 18.0 | 8.96 [8.60-11.01] | 1 object (2 mallocs) | 539 | 72 |
| today's interpolation into the text (unsafe; cost only) | 82.8 | 41.3 [40.1-42.7] | 10 | 1814 | 333 |
| handler style, text built per call, params reused | 12.8 | 6.39 [6.27-6.49] | 0 | 185 | 52 |
| A: boxed holes + build-time plan | 5.0 | 2.48 [2.36-2.53] | 1 | 149 | 20 |
| **C + signature `let`: text is the plan's constant** | **1.2** | **0.62 [0.61-0.67]** | **0** | **46** | **5** |
| Rust, sqlx-style: `&'static str` + `vec![...]` | 1.5 | 0.74 [0.74-0.76] | 1 (LLVM removed it) | 36 | 6 |
| Rust, static text + reused `Vec<Param>` | 2.0 | 1.00 [0.98-1.07] | 0 | 59 | 8 |
| Rust, text built per call with `write!("${}")` | 36.9 | 18.4 [18.1-18.5] | 0 | 1122 | 149 |

### HTML, 5 holes, 4 escaped

`t"<li class=\"\{cls}\"><a href=\"/u/\{id}\">\{name}</a><span title=\"\{title}\">\{bio}</span></li>\n"`.
A quarter of the names and half the titles and bios need escaping.

| variant | ns/op | ratio to Rust `write!` | allocs/op | instr/op | cycles/op |
|---|---|---|---|---|---|
| today: `html.escape` → new Str per hole, then concat | 198.6 | 1.98 [1.94-2.05] | 15 | 3453 | 799 |
| A: boxed holes + plan | 82.3 | 0.82 [0.81-0.86] | 1 | 1403 | 333 |
| **C + plan: chunks constant, escape into `out`** | **70.6** | **0.70 [0.69-0.72]** | **0** | **1238** | **286** |
| C#-handler style | 71.4 | 0.71 [0.70-0.74] | 0 | 1237 | 289 |
| Rust `write!` with an `Escape` Display wrapper | 100.2 | 1.00 [0.98-1.01] | 0 | 2064 | 404 |
| Rust `format!` then `push_str` | 142.0 | 1.42 [1.39-1.44] | 2 | 3229 | 573 |

Every variant of a workload writes the same bytes. A `-DCHECK` build
hashes every byte written, and the log and HTML variants all match
today's output, which uses Ren's real `ren_str_concat`. The SQL variants
and the Rust twins print the same checksum.

---

## Conclusions

1. **C's lowering is C#'s.** Specialized per site, C and the C# handler
   compile to the same code: 60 against 62 cycles per log line, 286
   against 289 per HTML row. No allocation in either. There's nothing
   more to take from C#.

2. **C beats Rust's `write!` by 2.5× on the log and 1.4× on HTML.**
   `fmt::Arguments` goes through a vtable call per piece and doesn't fold
   literals. A per-site template stores each literal as immediates.

3. **Per-site specialization matters more than the box.** Specialized
   per H only, C takes 79 cycles, because each literal is a load from
   the site and a `memcpy` call. Per site, it takes 60. The candidate A
   box costs about 6 cycles (66 against 60) on Ren's bump allocator.
   Clang specialized A's consumer per site by itself, because it had one
   caller, so that's the fair comparison. So release should specialize
   or inline consumers per site, not just per `H`. Decision 4's
   code-size budget should count that.

4. **The signature `let` is the big SQL win.** With the plan made while
   building, rendering a query is four stores, 1.2 ns, faster than
   sqlx-style Rust. Building the text per call, the C# handler's shape,
   costs 10× more (12.8 ns). Python-style templates rebuild it every
   time too. The template part of a query becomes free, and the driver's
   wire encoding is what's left.

5. **Unspecialized walking is fine for debug.** It's 87 cycles, against
   60, with no allocation. The plan only needs the hole kinds as data.

6. **Today is 3× (HTML) to 8× (log) slower than C, and much of that
   isn't templates.**
   The log line does 10 allocations (8 concats, 2 `show`s). About 190 of
   its 505 cycles are `ren_show_int`'s `snprintf`. A digit-pair `show`
   (Rust's itoa) alone takes today from 125 to 76 ns. That's worth doing
   regardless of templates. Open question 5 ("`show` into a buffer")
   fixes the other half for plain `"..."` too.

7. **For SQL today, the cost is the params `Array`.** It's an `Array`
   object plus a separate `malloc` for its data: 18 ns, about 540
   instructions. A template removes it because the holes are a tuple in
   the frame.

For the design, these support C's rule as written (zero allocation by
rule), plus one addition: **release specializes a template consumer per
site, not only per `H`.** The plan from the signature `let` already
makes the site a constant. Specialization lets the C compiler fold it.

---

## What was built

- `c/interp.c`: one C file holding all Ren variants. It includes Ren's
  real runtime (`lib/native/runtime/ren_rt.h` and `ren_rt.c`) as
  `ren build` does, and uses its literal layout, `ren_str_concat`,
  `ren_show_int`, `ren_alloc_ctor`, `ren_alloc_array_n` and
  `ren_dup`/`ren_drop`. It runs under `ren_run`.
  - **today:** `\{` isn't in the compiler yet (`error: \{ isn't an
    escape`), and `Str` has no `+`. So `today/main.ren` writes the line
    as strings.md defines it, `show` and `concat`. Its
    `--release --emit-c` (`today/today.c`, function `ren_main_line_1`)
    is a chain of 8 `ren_str_concat`s and 2 `ren_show_int`s, and
    `log_line_today` copies it call for call. `ren-today-binary` is that
    Ren program built for real. SQL's `today` copies what Ren emits for
    `[PInt(owner), PStr(state), ...]` (`sqltoday/p.c`): stride 3,
    `ren_alloc_array_n(4, 3, 4)`.
  - **A:** the holes go in a counted constructor, then the consumer
    reads it.
  - **C:** a template is `{const site *, const void *holes}`. The holes
    are a struct in the caller's frame. The consumer is generic in `H`,
    written out as release would specialize it. `log-passed` gets the
    site as a run-time pointer (specialized per H). `log-passed-site`
    gets it as a constant (per site). `log-walk` loops over the site and
    switches on each hole's kind.
  - **handler:** C#'s lowering, `h_new(out, literal_len, n)` then one
    `h_lit`/`h_str`/`h_int` call per part, all into the consumer's
    buffer.
  - The output buffer is `{data, len, cap}`, reused and cleared every
    4 KiB. That's what `&Str` with a capacity (strings.md) would be. It
    grows once per run.
  - Ints use a digit-pair table in every variant except `today-snp`.
    HTML escaping is one byte loop that copies runs, the same in C and
    Rust.
- `rust/main.rs`: the twins. Std only, one thread. `--cfg count` builds
  the counting allocator.
- `measure.sh`, `measure-log2.sh`, `summarize.py`, `allocs.json`, and
  `results/` (hyperfine JSON and text, `load.txt`).

---

## How it was measured

- Each group waited until the 1-minute load was below 4, polling every
  30 s for up to 20 minutes. Loads recorded (1, 5 and 15 minute):

  | group | load before | load after |
  |---|---|---|
  | log (first run, superseded) | 3.89 6.34 6.70 | 6.69 6.27 6.58 |
  | sql | 4.27 5.62 6.43 (20-minute wait ran out) | 4.75 5.61 6.39 |
  | html | 3.57 5.01 6.08 | 6.58 5.54 6.07 |
  | base (n=0) | 3.85 6.14 6.85 | 3.85 6.14 6.85 |
  | log (second run, in the table) | 3.76 5.75 6.65 | 4.83 5.37 6.36 |

- The other experiment's load rose during runs. In the first log run, wall
  times came out 1.3 to 1.6× higher for some variants, but the **cycle
  counts matched the second run to within 3% for every variant**. For
  example, today took 320 against 314 cycles, and the boxed variant 67
  against 67. So the slowdown was clock speed, not work. Cycles and
  instructions are the numbers to trust here, and the ratios hold either
  way.

---

## Caveats

- **`rust-sql-static` didn't allocate.** LLVM removed the `vec!`
  allocation and free. The counting allocator stops that, so it reports
  1 allocation per op. The timed binary has none.
- **The C designs are hand-written,** as release should emit them. They
  assume the specializer unrolls `pieces()` by `H` (designs.md) and that
  the site is a constant. The `walk` variant is what happens if neither
  is done.
- **SQL stops at (text, params).** A real driver then encodes params
  into the Bind message, and every variant pays that equally.
- **Today's HTML assumes `html.escape` makes one Str per hole,** which is
  generous to today.
- **The C#-handler style is C-coded** with the same buffer. It shows the
  lowering's shape, not .NET's runtime. C#'s default handler, which
  ends in a `string`, would add the final allocation.

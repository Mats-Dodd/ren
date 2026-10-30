# Interpolation and templates: prior art for Ren

Track A, research only. I took no timings, so the load rule didn't
apply. The perf numbers below are the sources' own.

What the owner asked for:
- compile-time checks
- templates as plain values passed explicitly (Python t-strings, JS tags)
- C#'s performance (no allocation, holes appended directly, holes skippable)
- nothing target-typed or otherwise hidden

Ren today (strings.md): holes are `\{x}`, a hole goes through `show`,
there's no format mini-language, and interception is stage 12's question.
Stage 12 synthesis F1 proposed `p"... \{x}"` = `p.template(t)`, plus a
build-time `check` on `p`'s type.

Each section answers five questions. What does the library receive?
When are holes evaluated? What gets allocated? How does checking work?
What do users love and hate?

---

## 1. Python 3.14 t-strings (PEP 750)

**Form.** `t"select * from u where id = {uid}"` is a `Template`, not a `str`.
There's one prefix, `t`, and no user prefixes. The consumer is an
ordinary function: `cur.execute(t"...")`, `html(t"...")`.

**What the library receives.** A `Template` holds:
- `strings`, a tuple of N+1 static parts, with empty strings kept, so
  the parts and holes always alternate.
- `interpolations`, N `Interpolation` objects, each with:
  - `value`, the evaluated hole
  - `expression`, the hole's source text (`"uid"`)
  - `conversion`, which is `r`, `s`, `a` or None
  - `format_spec`, a string the consumer interprets as it likes
- `values`, plus an `__iter__` that yields parts and holes in order.

Consumers usually `match` on the items.

**Evaluation.** Eager, left to right, like f-strings. An early draft
made every hole a lambda. It was rejected because most uses want
eagerness and because laziness hurts static analysis. If you want
laziness, you write the lambda yourself.

**Allocation.** A `Template` object, one object per hole, and the tuples.
Nothing is specialised.

**Composition.**
- `Template + Template` is allowed.
- `Template + str` is an error, because the `str` could mean static
  text or a value. You have to say which, with `Template(s)` or
  `Template(Interpolation(...))`.
- A template inside a hole stays a template, so it nests.

**Checking.** None in the language. Type checkers see `Template`, and
nothing checks the content. Caching is left to the consumer, who can
key on `strings`. There's no per-call-site identity.

**Libraries.**
- psycopg 3.3 (Dec 2025) accepts `cur.execute(t"... {id}")`. A value
  hole becomes a bound parameter.
- The format spec carries SQL-specific intent: `{name:i}` is an
  identifier and `{frag:q}` is a pre-built SQL fragment.
- tdom and others do HTML.
- `Template.join` was requested after release and is missing.

**Love:**
- It's just a value passed to a function.
- `expression` gives structured logging for free.
- Mixing in a `str` is safe by default.

**Hate:**
- `format_spec` is an untyped stringly channel, so every library
  invents its own letters.
- Nothing is checked statically.
- There's per-call allocation.

## 2. JavaScript tagged templates (ES2015)

**Form.** ``tag`a${x}b${y}c` `` calls `tag(strings, x, y)`. The tag is
any expression.

**What the library receives.**
- `strings` is a frozen array of the cooked parts.
- `strings.raw` holds the same parts with escapes left alone. That's
  what `String.raw` uses.
- The hole values come as separate arguments.
- There's no expression text and no format spec.

**Identity per call site.** Since ES2019 the spec keys the strings
array on the source location: the realm's [[TemplateMap]] is keyed by
the parse node. So the same call site gets the *same* array object on
every evaluation, and two identical literals at different sites get
different arrays. That's the hook every serious library relies on:
- lit-html keeps a `WeakMap<TemplateStringsArray, Template>`. It parses
  the HTML and builds the `<template>` element once per site, and each
  render after that only patches the holes.
- postgres.js makes a query object per call. The query is lazy (a
  thenable) and runs on `await`. Static queries become prepared
  statements automatically.
- In postgres.js, a nested `` sql`...` `` is a fragment, and
  `sql(obj, 'a', 'b')`, `sql(array)` and `sql('ident')` are typed
  helpers you put *inside* holes. The "kind" of a hole (identifier,
  values list, fragment) is said with a plain value, not a format
  string. `sql.unsafe` is the named escape hatch.

**Evaluation.** Holes are eager, evaluated before the tag is called.
The tag can return anything, including a lazy object.

**Allocation.** The strings array is allocated once per site. The
hole arguments are allocated per call.

**Checking.** None in the language. Tooling such as lit-analyzer and
the SQL plugins for editors parse the strings statically, which is
possible only because they're literal.

**Love:**
- Ergonomics.
- Caching per call site.
- The tag is an ordinary function.

**Hate:**
- No types on holes.
- ``foo`...` `` and `foo(`...`)` look alike but mean very different
  things.
- A missing tag silently makes a string.

## 3. C# 10 interpolated string handlers

**Form.** `$"..."` stays a string literal. If the *target parameter*
has a type marked `[InterpolatedStringHandler]`, the compiler lowers
the literal into calls on that type:

```
var h = new H(literalLength: 9, formattedCount: 2, <forwarded args>, out bool ok);
if (ok && h.AppendLiteral("id=") && h.AppendFormatted(id) && ...) { }
M(ref h);
```

**What the library receives.** A sequence of calls; it never sees a
template object.
- **The constructor** gets the total literal length and the hole count,
  computed at compile time, so it can size its buffer. Through
  `[InterpolatedStringHandlerArgument("x")]` it also gets sibling
  arguments: the logger, the condition, the destination span, the
  `StringBuilder`.
- **`out bool shouldAppend`.** If it's false, *no hole is evaluated*.
  `Debug.Assert(cond, $"...{Expensive()}")` builds nothing when `cond`
  holds. `span.TryWrite` stops when the literal text alone won't fit.
- **`AppendFormatted<T>(T value, int alignment, string? format)`** is
  generic, so value types aren't boxed and the JIT specialises per `T`.
  Overloads for `string` and `ReadOnlySpan<char>` give fast paths.
- **Bool-returning appends** short-circuit the rest.
- `,align` and `:format` are parsed by the compiler and passed as an
  int and a string.

**Evaluation.** Eager and in order, but conditional on `shouldAppend`
and on the earlier appends succeeding.

**Allocation.** The handler is a `ref struct` on the stack.
`DefaultInterpolatedStringHandler` rents from `ArrayPool` or uses a
caller `stackalloc` span.

**Perf** (Toub, .NET 6 blog, BenchmarkDotNet, own machine):

| case | old | new |
|---|---|---|
| FormatVersion | 111.7 ns, 192 B | 66.8 ns, 40 B (0.60x) |
| with stackalloc buffer | 109.9 ns | 48.6 ns (0.44x) |
| invariant culture | 124.9 ns, 224 B | 48.2 ns, 40 B (0.39x) |

The remaining 40 B is the result string itself.

**Checking.** Overload resolution only: each hole must match some
`AppendFormatted` overload. Nothing checks the literal's content.
ASP.NET's `ILogger` doesn't use handlers. It uses message templates
(`"{User}"`) plus a source generator. Analyzer CA2254 warns when you
pass an interpolated string, because that throws away the structure.

**Love:**
- Speed and zero allocation.
- Skipping holes.
- Caller code doesn't change.

**Hate:**
- It's *target-typed*. The same `$"..."` means a string, or a
  stack-buffer write, or a skippable log line, depending on overload
  resolution you can't see at the call site.
- Adding an overload silently changes semantics and evaluation order.
- This is exactly the magic the owner rejects. Take the lowering, not
  the trigger.

## 4. Swift: ExpressibleByStringInterpolation and os.Logger

**Form.** A string literal becomes whatever type the context expects,
if that type conforms. The compiler calls `init(stringInterpolation:)`
after a series of `appendLiteral(_:)` and `appendInterpolation(...)`
calls. Holes can take **labelled extra arguments**, because
`appendInterpolation` is an ordinary overloaded method:

```swift
logger.info("user \(id, privacy: .public) took \(t, format: .fixed(precision: 3))")
```

**What the library receives.** Append calls, as in C#, but with typed,
labelled options per hole instead of a format string.

**os.Logger:**
- `OSLogMessage` must be a literal, and its `privacy`, `format` and
  `align` must be compile-time constants. The compiler's OSLog
  optimisation pass folds the format string and argument metadata into
  constant data.
- Hole values are captured as `@autoclosure`s and evaluated only if
  the level is enabled. So holes are lazy, invisibly.
- Privacy: `.private` is the default for dynamic strings, and
  `.private(mask: .hash)` logs a hash instead.

**Allocation.** os_log writes a compact binary record. The string is
formatted later, by the log reader.

**Love:**
- Typed per-hole options instead of a mini-language.
- Privacy that's redacted by default.
- Speed.

**Hate:**
- Target typing: the same literal is a `String`, a `LocalizedStringKey`
  or an `OSLogMessage`.
- os_log holes don't run if logging is off, so side effects vanish
  silently.
- Literal-only restrictions surprise people ("cannot pass a String
  variable to Logger").
- Overloaded interpolations slow the type checker.

## 5. Scala: StringContext interpolators, doobie, quill

**Form.** `id"a${x}b"` desugars to `StringContext("a", "b").id(x)`. Any
extension method on `StringContext` is an interpolator: `s`, `f`, `raw`
and user-defined ones.

**What the library receives.** The parts (and raw parts) plus the
arguments. If the interpolator is a macro, it also gets their trees and
static types.

**Evaluation.** Eager, as ordinary method arguments.

**Checking:**
- `f"..."` is a compiler macro that checks the format specifiers
  against the argument types.
- doobie's `sql"... $x"` builds a `Fragment`. Each hole needs a `Put[T]`
  instance, found at compile time, so a hole of unsupported type
  doesn't compile. The SQL itself is checked *at test time*:
  `query.check` asks a live database, inside a test suite, whether the
  columns and types match.
- quill quotes a Scala DSL and macro-expands it to SQL at compile time.
  It can optionally probe a database during compilation.

**Love:**
- Typeclass-checked holes (doobie).
- Compile-time SQL (quill).
- The interpolator is just a method.

**Hate:**
- Implicit resolution.
- Macro fragility across Scala 2 and 3.
- quill's compile times and confusing errors.
- doobie's checks need a database.

## 6. Rust: format_args!, format!, sqlx

**Form.** `format!("{} {x:>6}", a)` is a macro, not interpolation. Since
1.58, `{x}` captures a variable in scope inline (identifiers only, not
expressions).

**What gets built.** `format_args!` is a compiler builtin that parses
the literal at compile time and produces `fmt::Arguments<'a>`:
- the static `&[&str]` pieces
- `&[Argument]`, each a reference to the value plus a formatter
  function pointer
- the specs

That's **zero allocation**: everything borrows stack values.
`Arguments` can't outlive the statement, because of temporary
lifetimes. `format!` allocates the final `String`. `write!` and
`println!` don't.

**Checking.** At compile time:
- the argument count
- named and positional matching
- the trait bound per spec (`{}` needs `Display`, `{:?}` needs `Debug`)
- an error for unused arguments

**Evaluation.** Eager.

**sqlx `query!("select .. where id = $1", id)`:**
- At compile time the macro connects to `DATABASE_URL`, PREPAREs the
  SQL, learns the parameter and column types, and type-checks the Rust
  arguments and the anonymous result record.
- Offline builds use a `.sqlx/` cache written by `cargo sqlx prepare`.
- Placeholders are positional, not holes.

**Love:**
- Errors at compile time.
- No allocation.
- sqlx's typed rows.

**Hate:**
- `fmt` uses dynamic dispatch and pulls in a lot of code (embedded
  projects use `ufmt`).
- You can't keep `Arguments` around.
- Captures are identifiers only.
- sqlx needs a database or a checked-in cache to build, which makes
  CI and editors slow or broken.

## 7. Zig: comptime format strings

**Form.** `writer.print("{d} items for {s}\n", .{ n, name })`. There's no
interpolation syntax. The format is a `comptime []const u8` and the
arguments are an anonymous tuple.

**How it works.** `std.fmt` parses the format with ordinary Zig code at
comptime (`inline for` over the tuple fields). A count mismatch, a bad
specifier or an unused argument is a `@compileError` raised by
*library code*, not by the compiler.

**Allocation.** None. It writes straight into the writer.

**Evaluation.** Eager.

**Love.** No compiler magic: checking is a library function run at
compile time. There's no runtime parsing, and the code is specialised
per call.

**Hate:**
- Code size, because every distinct format instantiates code.
- Positional arguments far from their placeholders.
- Cryptic comptime error traces.

**Also C++20 `std::format`** (not on the list, but the closest
precedent). The parameter type `std::format_string<Args...>` has a
`consteval` constructor that parses the literal against the argument
types. So the check lives in the *callee's parameter type*, runs at
compile time, and the call site is an ordinary call.

## 8. Java: JEP 430, 459 and 465 (withdrawn)

**Form** (previews in JDK 21 and 22). `STR."Hello \{name}"`. Here `STR`
is a `StringTemplate.Processor<R, E>`, auto-imported. Also `FMT` and
`RAW`. The processor sees a `StringTemplate` (`fragments()`,
`values()`). Performance came from linkage through `invokedynamic`,
specialised per site. Ren's `\{` comes from here.

**Withdrawn.** JEP 465 (the third preview, to finalise) was withdrawn in
April 2024, and JDK 23 shipped no templates. Goetz on amber-spec-experts,
8 March 2024:
- "Java already has a well established means of abstracting behavior:
  methods." A processor is a new syntax for a method call.
- "Template capture and processing are complected." They should be
  separate, composable features.
- Designers were left "not knowing whether to write a processor or an
  ordinary API".
- The design had been bent by early perf experiments that needed the
  processor known *at capture time*. Goetz now believed other
  techniques could meet the perf goals without that.
- New direction:
  - A template literal is just the literal form of `StringTemplate`,
    unrelated to `String`.
  - Libraries add ordinary overloads: `println(StringTemplate)`,
    `String.format(StringTemplate)`, a JDBC `prepare(StringTemplate)`.
  - "Interpolation remains explicit," but a library may choose it for
    you where that's safe.
- Guy Steele summarised the expert group: making templates "the star
  of the show" is the winning direction, and "no one seems too busted
  up at the loss of processors."

As far as I can find, no replacement JEP has shipped by late 2026.

**Love.** Typed fragments and values, and `\{` syntax that's safe to
paste into.

**Hate:**
- `STR.` boilerplate on every string.
- Processors as a second kind of abstraction.
- Checked-exception generics on the processor.

## 9. Elixir: sigils and HEEx

**Form.** `~H"""<div class={@c}>...</div>"""` is a sigil. `~X` calls the
`sigil_X` *macro* at compile time with the literal (and modifiers).

**HEEx:**
- At compile time it parses the HTML, rejects mismatched or unclosed
  tags and malformed attributes, and warns when a component is called
  without a required declared `attr` or slot, with an unknown
  attribute, or with a literal outside the declared `:values`.
- It compiles to a `%Rendered{static: [...], dynamic: fn}`. The static
  parts are sent to the browser once, and change tracking re-sends only
  the dynamic parts whose assigns changed.
- Holes are escaped by type through the `Phoenix.HTML.Safe` protocol.

**Evaluation.** Holes are inside a function and evaluated on render,
with change tracking.

**Love.** Real HTML validation, component attribute checks, and wire
efficiency.

**Hate.** It's all macro, so errors and the compile model are opaque.
`~H` works only where `assigns` is in scope, which is a hidden variable.

## 10. Kotlin

**Form.** `"$x ${expr}"` lowers to `StringBuilder` or, on JVM 9+, to
`invokedynamic makeConcatWithConstants`. There's no hook and no tag.
Kotlin 2.1/2.2 added multi-dollar raw strings (`$$"""..."""`) so that
`$` can be literal.

**Libraries.** They use DSLs instead: Exposed for SQL, kotlinx.html.
Proposals for templates in the style of JS or Scala have stalled.

**Lesson.** Without a hook, people build injection-safe APIs as DSLs.
That works, but every SQL library ends up a new language.

## 11. Julia

**Form.** `"$x"` lowers to `string(...)`. Non-standard string literals
`foo"..."` call the *macro* `@foo_str` at parse time with the **raw**
literal; there's no interpolation unless the macro does its own.

**Libraries.**
- `r"..."` compiles regexes at parse time.
- `Printf.@sprintf` parses formats at macro time.
- HypertextLiteral.jl's `@htl` parses the HTML at expansion time and
  emits code that escapes each hole *according to its HTML context*:
  text, attribute value or attribute name.

**Love.** Context-aware escaping decided statically.

**Hate.**
- A prefix is a macro, so it's opaque.
- `$` inside the literal is the macro's business, so behaviour varies
  per library.

---

## Table

| | Library receives | Holes evaluated | Allocation | Checking | Hole kind/options | Identity per call site |
|---|---|---|---|---|---|---|
| Python t"" | `Template` (parts, Interpolations with value, expr text, conv, spec) | eager | objects per call | none | `:spec` string | no (key on `strings`) |
| JS tag`` | frozen strings + raw, values as args | eager | values per call | none (tooling) | wrapper values (`sql(x)`) | **yes, spec-guaranteed** |
| C# handler | ctor(lens, count, siblings, out ok) + Append calls | eager, **skippable** | **none** (stack/pool) | overload resolution | `,align:fmt` | n/a (lowered) |
| Swift / os_log | append calls with labelled args | eager, but **lazy** in os_log (autoclosure) | none (os_log) | constants required | **typed labels** | n/a |
| Scala | parts + args (+ trees if macro) | eager | per call | macros, typeclasses; doobie at test | wrapper types | no |
| Rust fmt | `Arguments` (pieces, &value + fn ptr) | eager | **none** | builtin: arity + traits | `{:>6}` spec | static pieces |
| sqlx | macro sees SQL + arg exprs | eager | per call | **live DB at build** | positional | n/a |
| Zig | comptime str + tuple | eager | none | **library code at comptime** | spec | specialised |
| C++20 format | `format_string<Args...>` | eager | none | **consteval ctor of param type** | spec | specialised |
| Java (withdrawn) | `StringTemplate` | eager | per call | none | none | indy per site |
| Elixir HEEx | macro sees literal | render time | statics once | **HTML + attrs at compile** | protocol | statics shared |
| Kotlin | nothing (concat) | eager | builder | n/a | n/a | n/a |
| Julia str macro | raw literal at parse | macro decides | macro decides | macro | context-aware | n/a |

## Lessons for Ren

1. **A template is a value of its own type, never a `Str`.**
   - Python and post-withdrawal Java both landed here.
   - Ren could write it as `t"...\{x}"` and pass it to an ordinary
     function: `db.query(t"select .. \{id}")`.
   - No target typing (the C# and Swift trap), and no implicit
     `Template` + `Str` (the Python rule).
2. **Goetz's argument also cuts against F1's `DB"..."` prefix.**
   - A prefix is a second spelling of a method call, and it
     "complects" capture with processing.
   - `DB.query(t"...")` costs six characters and adds no rule.
   - Keep the prefix only if the experiment shows the check can't hang
     anywhere else.
3. **Put the compile-time check in the callee's parameter, as C++20
   does.**
   - In C++20, the parameter type's constructor runs at compile time.
     In Zig, library code runs at comptime and calls `@compileError`.
   - Ren already runs code at build time.
   - Ren could let a parameter declare a build-time check over the
     template's *static* half: the parts plus the hole types. The
     check is visible in the signature, not hidden on a prefix.
4. **Split each template into a static half and a dynamic half.**
   - The static half holds the parts, raw parts, hole source text and
     hole types. It's a per-site constant with a stable identity, as in
     JS.
   - The dynamic half is a tuple of hole values.
   - The identity is the cache key for prepared statements (postgres.js)
     and parsed HTML (lit), at zero cost.
5. **Make the hole tuple typed and the consumer specialised.**
   - This gets C#'s and Rust's zero allocation without the handler
     protocol.
   - `Template<(Int, Str)>` lives on the stack, and a generic consumer
     is monomorphised per site.
   - The loop over holes unrolls, like Zig's `inline for`, so each
     hole is appended directly with no boxing.
6. **A consumer can also name the interface its holes must have**
   (`Template<ToSql>`), as doobie's `Put` and psycopg's adapters do.
   - Each hole is checked at the call site, and the loop stays uniform.
   - That's one ML-style constraint, with no overload resolution.
7. **Give hole kinds as plain values, not a spec string.**
   - Write `\{sql.ident(t)}`, `\{html.raw(s)}`, `\{secret(x)}`, as
     postgres.js does.
   - Python's `:i`/`:q` and Swift's labels both exist to fill the gap
     a missing value-level wrapper leaves.
   - This keeps strings.md's "no mini-language".
8. **Keep holes eager.**
   - Python rejected implicit laziness, and os_log's silent skipping is
     a known footgun.
   - For C#'s skipping, use Ren's block:
     `log.debug fn() => t"tree \{dump(t)}"`. It's visible and
     allocation-free.
   - A `should_append`-style early stop can be a plain `Bool` the
     consumer checks itself, with no lowering trick.
9. **Plain `"..."` stays `Str` through `show`.**
   - It's the default case and the cheapest (Kotlin's
     `makeConcatWithConstants`).
   - The compiler knows the literal length and hole count, as C# does,
     so it can size the buffer once.
10. **Keep the hole's source text in the static half.**
    - That makes `\{x=}` and structured logging free (Python's
      `expression`).
    - Keep raw parts too, as JS does, for regex and path consumers.
11. **Checks that need the outside world are opt-in and explicit.**
    - sqlx's live database at build time is the most-hated part of
      sqlx.
    - doobie's test-time `check` is the gentler model.
    - For Ren: check what's in the source tree (a schema value),
      never a network.
12. **Templates nest, and a template-valued hole stays structured.**
    - postgres.js fragments, lit's child templates and Python
      `Template` holes all work this way.
    - Add `Template.join` from day one; psycopg users asked for it
      within weeks.

## Sources

- PEP 750: https://peps.python.org/pep-0750/
- psycopg t-strings: https://www.psycopg.org/psycopg3/docs/basic/tstrings.html
- psycopg 3.3 release: https://www.psycopg.org/articles/2025/12/01/psycopg-33-released
- Template.join request: https://discuss.python.org/t/pep-750-please-add-template-join/90202
- C# handlers (Toub): https://devblogs.microsoft.com/dotnet/string-interpolation-in-c-10-and-net-6/
- postgres.js: https://github.com/porsager/postgres
- Goetz, 8 March 2024: https://mail.openjdk.org/pipermail/amber-spec-experts/2024-March/004010.html
- Bierman, withdrawal: https://mail.openjdk.org/pipermail/amber-spec-experts/2024-April/004106.html
- JEP 465: https://openjdk.org/jeps/465
- HEEx / Phoenix.Component: https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html
- From memory, not re-fetched this session:
  - the ES2019 template-site spec change and lit-html's
    `templateCache` (WeakMap keyed on strings)
  - os.Logger's autoclosures
  - Rust `fmt::Arguments` and 1.58 inline captures
  - sqlx offline mode
  - Zig `std.fmt`
  - C++20 `basic_format_string`
  - Scala `StringContext`, doobie `check`, quill
  - Kotlin multi-dollar strings
  - Julia `@foo_str`, HypertextLiteral.jl

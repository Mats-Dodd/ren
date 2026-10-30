# Templates in Ren: three candidate shapes

Track A, design. Inputs: research.md (this folder), strings.md,
language.md (blocks, by-name defaults, no user interfaces), shapes.md
(the top level is build time), foundations.md decisions 1, 4, 13 and 14,
and stage 12's F1 and §6.1. Nothing in the repo was edited. No timings
were taken, so the load rule didn't come up. What to measure is at the
end.

What the owner asked for:
- checks at build time
- a template is a plain value, passed explicitly, like a Python or JS
  argument
- C#'s speed: no allocation, holes appended straight into the output
- explicit: nothing decided by the expected type, nothing found behind
  your back

## Contents

- [What every candidate shares](#what-every-candidate-shares)
- [The check: a `let` in the signature](#the-check-a-let-in-the-signature)
- [Candidate A: a template is a value you can keep](#candidate-a-a-template-is-a-value-you-can-keep)
- [Candidate B: the prefix `DB"..."` as sugar](#candidate-b-the-prefix-db-as-sugar)
- [Candidate C: a template is passed down, like a block](#candidate-c-a-template-is-passed-down-like-a-block)
- [How a consumer reads a template without allocating](#how-a-consumer-reads-a-template-without-allocating)
- [Laziness](#laziness)
- [Call-site identity](#call-site-identity)
- [Format specs and `\{x=}`](#format-specs-and-x)
- [Errors](#errors)
- [Comparison](#comparison)
- [Recommendation and rules](#recommendation-and-rules)
- [Open questions](#open-questions)
- [What to measure](#what-to-measure)

---

## What every candidate shares

**Plain strings don't change.** `"jobs/\{job}"` is a `Str`. Each hole
goes through `show`. That's strings.md, untouched.

**`t"..."` makes a template, never a `Str`.** One prefix, `t`, fixed in
the language, as in Python. There are no user prefixes in A and C.

A template has two halves:

```ren
// prelude
pub type Template<H>              // made only by a t"..." literal
  pub fn site(self) -> Site       // the static half: one constant per literal
  pub fn holes(self) -> H         // the dynamic half: a tuple of the hole values
  gen fn pieces(self) -> Piece    // parts and holes in order (needs `import shape`)
  pub fn render(self) -> Str      // what "..." would have made: holes through `show`

pub type Site = {
  id: Int,                        // one per literal in the program
  parts: Array<Str>,              // n + 1 parts, escapes processed, empty parts kept
  raw: Array<Str>,                // the same parts, escapes left as written
  holes: Array<HoleInfo>,         // n entries
  literal_len: Int,               // the parts' total byte_len
  source: Str,                    // the literal as written, between the quotes
}
pub type HoleInfo = { expr: Str, shape: Shape, at: Int }   // source text, static type, offset in `source`
pub type Piece = Lit(Str) | Hole { i: Int, v: Value }      // Value and Shape are std.shape's
```

- **Holes keep their static types.** `t"id = \{id} and org = \{org}"`
  with `id: UserId` and `org: OrgId` has type
  `Template<(UserId, OrgId)>`. A consumer is generic in `H`, so release
  specializes it per hole tuple (decision 14). The hole types are also in
  `site.holes[i].shape`, as data, for checks.
- **Holes are evaluated eagerly, left to right,** before the call, like
  any argument.
- **The site is built while building.** It's a constant in the binary,
  like a top-level `let`. Making a template at run time costs only its
  holes.
- **No implicit conversion either way.** A `Str` where a `Template` is
  expected is a type error, so a string built at run time can't reach
  `sql` by accident. `t.render()` is the one explicit way to a `Str`.
  `Template + Str` doesn't exist (Python's rule).
- **Hole kinds are values, not a format language:** `\{sql.ident(t)}`,
  `\{html.raw(h)}`, `\{fmt.pad(n, 6)}`. A consumer decides what each
  hole's type means, and its build-time check refuses a type it can't
  handle.
- **Templates nest.** A hole may hold another template, or a value a
  consumer made from one (`sql.Frag`, `html.Html`).
- **No new requirements.** Ren has no user interfaces (language.md §3).
  A consumer handles holes through `shape`, the same walk `json` uses,
  and an opaque type through its `repr` (stage 12, A3). So "can `sql`
  bind this type?" is answered by its shape, checked at build time,
  not by a `ToSql` trait.

The candidates differ on two things only: **can a template be kept**,
and **is there a prefix**. The check is the same for all three.

---

## The check: a `let` in the signature

The owner wants checks at build time, explicitly. Stage 12's F1 hung the
check on a reserved `check` member of the prefix's type, which runs
implicitly. Research found the better place: **the callee's own
signature**, which is what C++20 does with `format_string<Args...>`'s
`consteval` constructor, and what Zig does with library code at
`comptime`.

Ren already has the rule that the position says when code runs: the top
level runs while building. This extends it by one position:

```ren
pub fn rows<T, H>(self: Schema, q: Template<H>) -> Array<T> uses Sql ! DbDown
  let plan = try sql.plan(self, q.site(), T.shape)   // runs while building, once per call site
=
  Sql.rows(plan.bind(q.holes())) |> try sql.decode_all<T>
```

**A `let` between a signature and its `=` is computed while building,
once for each call site.** It's a top-level `let` that belongs to one
call.

- **Its inputs must be known while building:** a template's `site()`,
  a type's `shape`, literals, top-level values, and parameters whose
  argument at that call is one of those. `self` here is a top-level
  `let DB = try sql.parse_schema(...)`. An argument that isn't known
  while building is an error at the call, naming the parameter.
- **A `try` that fails, fails the build,** at the call. If the error
  has an `at`, the caret goes at that byte of the literal (strings.md's
  "`at` is for reports").
- **The body reads it as a constant.** Debug builds pass it as a hidden
  pointer to static data, as they pass a dictionary. Release builds see
  the constant.
- **It runs in the interpreter, cached by the build's journal,** like
  every top-level value (shapes.md). It holds data, never a block.
- **It may only read the build's world** (shapes.md's table: `Fs` inside
  the package, `Git`). Never a database. sqlx's live database is the
  thing its users hate most.

Why a value and not just a pass/fail check: the plan is what makes the
consumer fast. `sql.plan` turns the literal into SQL text with `?`
placeholders and a bind order. `html.plan` splits the literal into
static chunks and an escape context for each hole, as Julia's
HypertextLiteral and Elixir's HEEx do. `proc.plan` splits the argv. At
run time nothing parses the literal again. That's the C# handler's
compile-time literal length, taken to its end.

**Forwarding.** A function that takes a template and passes it on to a
function with a signature `let` would need the `let` to run at *its*
callers. In this first version that's an error, with help: take the
consumer's own type instead (`q: sql.Query`), or write the call where the
literal is. If wrappers turn out to be common, the rule extends as Zig's
`comptime` parameters do: a parameter a signature `let` reads can be
passed on only to a parameter another signature `let` reads, and the
whole chain runs at the outermost call. I'd wait for a program that
needs it.

**Editors.** A signature `let` names its function (`sql.plan`,
`html.plan`), so the language server knows each literal's language and
can colour it, and tree-sitter can inject SQL into `t"..."` passed to a
function the server marks. That's weaker than a prefix for tree-sitter
alone (see B).

---

## Candidate A: a template is a value you can keep

Python's PEP 750, and where Java's designers went after withdrawing
JEP 465. A `Template<H>` is an ordinary value: you can store it, return
it, put it in an array, and choose one with `if` when both have the same
`H`.

```ren
fn by_owner(o: OwnerId) -> Template<(OwnerId,)> = t"owner = \{o}"
let qs = [t"a \{x}", t"b \{y}"]                // Array<Template<(Int,)>>
DB.rows<Job>(t"select * from jobs where \{by_owner(o)}")
```

**Representation.** A pointer to the site, then the tuple `H`. Under
decision 14 that's a small value while it fits in a tag and three
words: the site plus two words of holes. One `Str` hole (16 bytes) or
two `Int` holes fit. Anything bigger is boxed, which is one
allocation. Most log lines and HTML fragments are bigger.

So A allocates exactly when a tuple of its holes plus a word would. That
rule is honest and easy to state, but it isn't C#'s promise. The
optimizer could keep a template that's passed straight to a call
unboxed, but foundations.md dropped frame allocation as an optimization
because small values covered it, and "obvious code is fast" shouldn't
rest on an analysis.

**What A gains.**
- `log.debug fn() => t"tree \{dump(tree)}"` works: a block can return a
  template.
- Helpers can return fragments without converting them.
- It's the most "plain value" of the three.

**What A costs.**
- An allocation on most real templates.
- A template kept for long keeps its holes alive, a retention trap like
  slices' (strings.md).
- Forwarding: a stored template has lost its call site's signature
  `let`, so it can't reach a checked consumer anyway. In practice
  helpers still have to convert to `sql.Frag`, which is C's rule
  arrived at the long way.

---

## Candidate B: the prefix `DB"..."` as sugar

Stage 12's F1: `p"... \{x}"` means `p.template(t"... \{x}")`, where `p`
is any value or module in scope. Here it's pure sugar over A or C. The
check is `template`'s own signature `let`, so F1's reserved `check`
member isn't needed.

```ren
// in sql
pub fn template<H>(self: Schema, q: Template<H>) -> Query
  let plan = try sql.plan_untyped(self, q.site())     // no row type to check against
=
  plan.bind(q.holes())

let DB = try sql.parse_schema(try Fs.read("db/schema.sql"))
Sql.rows(DB"select id, name from users where id = \{id}")
```

**What B gains.**
- Short.
- Tree-sitter can inject a language by prefix name, as editors do for
  JS's `` sql`...` `` and `` html`...` ``.

**What B costs.**
- A reserved member name (`template`) and a lookup rule.
- The prefix can't name a verb, so it must return a value (`Query`),
  and the verbs (`rows`, `one`, `exec`) take that value. The value
  is made per call: params copied into an array, which is an
  allocation C doesn't need.
- The row type `T` has no place to go in `DB"..."`, so `sql.plan`
  can't check columns against the result type at the literal.
  `Sql.rows<User>(DB"...")` would need a second check.
- Goetz's argument for withdrawing Java's processors applies directly:
  a prefix is a second spelling of a method call. `DB.rows(t"...")`
  is seven characters longer and adds no rule.
- `DB"..."` and `DB("...")` look alike and mean different things,
  the JS complaint.

B is worth it only if the editor point decides it. A language server
gets the same information from the signature `let`.

---

## Candidate C: a template is passed down, like a block

**A template follows the block rule** (foundations.md decision 1). It
can be passed as an argument, bound with `let`, and passed on. It can't
be stored in a record or collection, returned, or chosen with `if`. To
keep one, convert it to data: `t.render()`, `sql.frag(t)`,
`html.of(t)`.

That's the rule every zero-allocation design in the survey has:
- C#'s handler is a `ref struct`, so it can't reach the heap.
- Rust's `fmt::Arguments` can't outlive its statement.
- Python's `Template` can be kept, and it allocates per call.

**Representation.** Like a block, a template is two words: the site
pointer and a pointer to the holes. The holes are temporaries in the
caller's frame, evaluated before the call, in the frame a block's
environment would use. Nothing is allocated, at any number of holes,
in debug or release. Debug builds also pass `H`'s dictionary, as they
do for any generic. Release specializes the consumer per `H`, and per
site when the consumer inlines, the way a block is lifted and
specialized today.

**What C gains.**
- C#'s zero allocation, as a rule rather than an optimization, and
  with no new memory rule: it's the block rule, applied to one more
  thing.
- No retention trap: a template can't outlive the frame holding its
  holes.
- The signature `let` always has a literal behind it, because a
  template can't come out of a data structure. Forwarding is the only
  case left, and it's the same case as A's.
- Keeping is explicit and goes to the consumer's own data, the ML
  answer. A `sql.Frag` is SQL; a `Template` is just text with holes.

**What C costs.**
- It isn't quite "a value like Python's". It's a value you pass down,
  the way a block is a function you pass down.
- Choosing between fragments needs conversion first:
  `let w = if admin then sql.frag(t"true") else sql.frag(t"owner = \{me}")`.
  In A the same `if` fails anyway when the branches' `H` differ, which
  it usually does, so this costs less than it looks.
- `log.debug fn() => t"..."` is a block returning a template, which the
  block rule forbids. See [Laziness](#laziness).

---

## How a consumer reads a template without allocating

The C# lowering, in Ren terms. C#'s compiler turns `$"..."` into a
handler constructed with the literal length and hole count, then
`AppendLiteral` and `AppendFormatted<T>` calls, then the call. Ren
doesn't lower into calls on the consumer. The consumer is an ordinary
function that walks the template:

```ren
pub fn write<H>(out: &Str, t: Template<H>) =
  out.reserve(t.site().literal_len)
  for p in t.pieces()
    match p
      Lit(s) => out += s
      Hole { v, .. } => out += shape.show(v)
```

| C# handler | Ren |
|---|---|
| constructor gets `literalLength`, `formattedCount` | `site.literal_len`, `site.holes.len()`: constants |
| `AppendLiteral(s)` | the `Lit(s)` arm |
| `AppendFormatted<T>(T v)`, generic, no boxing | the `Hole` arm: release specializes `write` per `H` and unrolls `pieces()` by `H`'s arity, so each hole's `match` on `Value` folds to one arm for its type |
| `ref struct` on the stack | C: the block rule. A: a small value, or one box |
| `[InterpolatedStringHandlerArgument]` siblings | ordinary parameters: `out`, `self`, a level |
| `out bool shouldAppend` | an ordinary `if` in the consumer, but the holes are already evaluated (eager) |
| `,align:format` | a value in the hole: `fmt.pad(n, 6)` |

- **Release:** `pieces()` over a known `H` is a fixed sequence of
  2n + 1 steps. The specializer unrolls it, as it unrolls
  `json.encode<User>` over `User.shape`. `shape.view(v)` of a known type
  never builds a `Value`. That's the same bet stage 12 is already making
  for json (synthesis risk 2), not a second one.
- **Debug:** `pieces()` builds a `Value` per hole by reading `H`'s
  dictionary, as Go's `encoding/json` reflects. That allocates for
  compound holes, which debug builds may.
- **A consumer with a plan** doesn't walk `pieces()` at all. It walks its
  plan, which says, for instance, "chunk 0, hole 1 escaped as an
  attribute, chunk 1". It reads holes with `t.hole(i)` (a `Value`) or
  binds the whole tuple `t.holes()` through a shape-driven encoder.
- **`show` of a user type returns a `Str`,** so a hole of a type with
  a written `show` allocates that string. Built-in and derived `show`
  can write straight into the buffer. A `show` that writes into a buffer
  is a later change, and it helps plain `"..."` as much as templates.

---

## Laziness

**Holes are never lazy.** Python rejected lazy holes, and os_log's
silent skipping is the known trap. An argument is eager everywhere in
Ren, and a hole is an argument.

What C#'s `shouldAppend` gives, Ren gives explicitly:

- **The guard:** `if log.on(Debug) then log.debug(t"tree \{dump(tree)}")`.
  Plain code, in every candidate, with no second name. With `log.off()`
  installed in a closed world, the whole line compiles out.
- **The block:** `log.debug fn() => t"tree \{dump(tree)}"`. This works in
  A. In C it's a block returning a template, which the block rule
  forbids. It could be allowed with one exception: "a block may end in a
  template, which the call it was passed to consumes before the block's
  frame goes." Release inlines the block, so nothing moves; debug boxes
  the holes, which debug already does for generic small values. I'd
  start with the guard, and add the exception only if the guard feels
  heavy in real code.
- **A block returning a `Str`** works everywhere today:
  `log.debug_text fn() => "tree \{dump(tree)}"`. It's a second name,
  and it loses structure. Not recommended.

---

## Call-site identity

**`site.id` is one `Int` per literal in the program,** as JS's spec makes
the strings array one object per site. It's stable within a build, not
across builds, so it's a cache key, never something to store or journal.

- **Prepared statements:** a connection keeps `Map<Int, Stmt>` keyed by
  `site.id`. A query with spliced fragments keys on the plan's final
  text instead.
- **Parsed templates:** with a signature `let`, the parse happens at
  build time, so a cache per site isn't needed for HTML at all. The
  plan is the cache, and it's in the binary.
- **Logs:** the site is the call site's static metadata: message parts,
  field names, file and line, emitted once. That's what stage 12's G1
  wanted from a special compiler-built `Event`. Templates give it with
  no special case.

---

## Format specs and `\{x=}`

**No format language.** A hole's options are a value made by an
ordinary function: `\{fmt.pad(n, 6)}`, `\{fmt.fixed(t, 3)}`,
`\{fmt.hex(b)}`. `fmt.pad` returns a small value, `fmt.Padded<T>`,
whose `show` writes the padding, so it allocates nothing in `"..."` or
in a template. A consumer that can't use it, such as `sql`, refuses its
shape at build time.

**`\{x=}` is sugar for `x=\{x}`,** in `"..."` and in `t"..."` alike, as
Python's `f"{x=}"` is. The lexer writes `x=` into the part before the
hole. The hole's `expr` is `x` either way.

- In a log line, `t"\{n=}"` and `t"\{n}"` give the same field, `n`.
  The `=` only changes the text.
- `\{fmt.pad(n, 6)=}` reads `fmt.pad(n, 6)=` and isn't useful. I'd
  allow only a name or a path before `=`.

---

## Errors

```
error: `rows` reads `q` while building, but this template isn't a literal
  --> jobs.ren:31:20
   |
31 |   DB.rows<Job>(q)
   |                ^ a parameter of `find`
   = help: write the t"..." here, or take `sql.Query` and build it with `DB.query(t"...")`

error: this query failed its check while building
  --> jobs.ren:12:39
   |
12 |   DB.rows<Job>(t"select * from \{table} where id = \{id}")
   |                                ^^^^^^^^ a `Str` where a table name goes
   = help: a table name must be `sql.Table`, chosen from an enum: `\{sql.table(kind)}`
   = note: checked by `sql.plan`, from `rows`'s signature (sql/query.ren:40)

error: a template can't be stored
  --> page.ren:8:14
   |
 8 |   let items = xs.map(fn(x) => t"<li>\{x}</li>")
   |                               ^^^^^^^^^^^^^^^^ returned from a block
   = help: make each one `html.of(t"<li>\{x}</li>")`, or write them in a loop with `html.write(&out, ...)`

error: expected `Template<H>`, found `Str`
  --> run.ren:5:13
   |
 5 |   DB.exec("delete from jobs where id = \{id}")
   |           ^ a string, with its holes already shown
   = help: write `t"..."` to pass the holes to `exec`
```

The last one matters most. It's the mistake JS can't catch (a missing
tag silently makes a string). Ren refuses it at the type level.

---

## Comparison

| | A: keepable value | B: prefix | C: passed down |
|---|---|---|---|
| Allocation | none up to two words of holes, else one box | as A or C, plus the consumer value the prefix returns | **none, any size, both builds** |
| New rules | `t"..."`, signature `let` | those of A or C, plus a reserved `template` and prefix lookup | `t"..."`, signature `let`, and the block rule extended to templates |
| Can be kept | yes | the returned value can | no: convert with `render`, `sql.frag`, `html.of` |
| Check sees a literal | only if it came straight from one | yes | **always**, except forwarding |
| Verb at the call | yes: `DB.rows<User>(t"...")` | no: `Sql.rows<User>(DB"...")` | yes |
| Laziness | block returning a template | as A or C | the guard, or one block exception |
| Editor injection | by language server | **by prefix, in tree-sitter** | by language server |
| Retention trap | yes, holes kept alive | as A or C | no |
| Precedent | Python, post-withdrawal Java | JS, Scala, F1 | C# `ref struct`, Rust `Arguments` |

---

## Recommendation and rules

**C, without a prefix, with the signature `let` as the check.** The
rules, in full:

1. **`"...\{x}"` is a `Str`,** holes through `show`. Unchanged.
2. **`t"...\{x}"` is a `Template<H>`:** a site built while building,
   plus the holes, evaluated eagerly left to right, as the tuple `H`.
   It's never a `Str`, and nothing converts between them implicitly.
3. **A template is passed down like a block.** It can be an argument,
   bound with `let`, and passed on, but it can't be stored, returned or
   chosen with `if`. To keep one, convert it to data.
4. **A `let` between a signature and its `=` runs while building, once
   per call site.** It reads only what's known while building. A `try`
   that fails there fails the build at the call. The body reads it as a
   constant.
5. **A hole's kind or format is a value** (`sql.ident`, `html.raw`,
   `fmt.pad`). There's no spec language.
6. **`\{x=}` is `x=\{x}`.**

Rule 4 is the only one that isn't already in Ren. Everything else is a
new literal plus the block rule.

---

## Open questions

1. **The block exception for lazy logs** (see Laziness). Start without.
2. **Forwarding a template through a wrapper** to a signature `let`.
   Error first; Zig-style propagation if programs need it.
3. **Is a signature `let` also useful without templates?** Probably:
   `regex.compile(pattern)` with a literal pattern would compile while
   building, and `Duration.parse("2s")` could check. That's a reason to
   take rule 4 as general, and a reason to be careful: it's
   per-call-site evaluation, which is the start of `comptime`
   parameters. shapes.md keeps code generation out, and this rule stays
   on that side: a signature `let` makes data, never code or types.
4. **A raw or multi-line literal** (`t"""..."""`). The JSON and HTML
   programs show escaped quotes everywhere. strings.md has `b"..."`
   later; raw literals should be decided with it, for `"..."` and
   `t"..."` together.
5. **`show` into a buffer,** so a user type's hole doesn't allocate.
6. **Where hole values cross a dependency.** `Sql.rows` and `Log.event`
   are journaled, so their arguments are data. `sql` builds a parameter
   array there, one allocation, small next to the query. `log` should
   encode the holes into the task's log buffer, NanoLog-style (static
   site plus binary arguments), so a log line allocates nothing.

## What to measure

Nothing here is measured. Before freezing:

1. **The lowering.** Hand-write in C what release should emit for
   `html.write(&out, t"<li class=\"\{c}\">\{name}</li>")` and for a
   4-field log line, under C's representation (site plus frame
   pointer) and A's (a boxed tuple). Compare with Rust `write!`, and with
   a hand-written appender. That's the same harness as stage 12's risk 2
   (shape specialization), so run them together, with hyperfine, under
   the load rule.
2. **The build cost of signature `let`s.** Count literals in P1 and P2,
   and time `sql.plan` and `html.plan` in the interpreter per literal.
   The 10⁹-step budget is per top-level value; a plan should be about
   10⁴ steps.
3. **Code size** from specializing consumers per `H` and per site, against
   decision 4's budget.

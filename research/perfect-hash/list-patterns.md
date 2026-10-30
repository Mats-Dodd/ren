# List patterns and string patterns: a design note

Track B of the routing experiment. The owner has decided to add list
patterns. This note proposes the syntax, how exhaustiveness treats them,
and how a route `match` compiles. The measurements behind the choices
are in `results.md` in this folder.

## What exists today

- Patterns are `_`, a name, `Int` and `Bool` literals, constructors
  (positional or by name), tuples, records, `fail`, or-patterns and `as`
  (lib/syntax/ast.ml, `pattern`).
- **There is no string literal pattern.** `match m` with an arm
  `"GET" =>` is a parse error: "expected a pattern, found the string
  `"GET"`". Code writes an `if m == "GET" ... else if` chain instead.
  The native build emits a chain of `ren_str_eq` calls, one per arm, each
  a length test then a `memcmp` (code/ren/m2.ren, `--emit-c`).
- Exhaustiveness is Maranget's usefulness (lib/sema/exhaust.ml). An `Int`
  literal is a constructor of a type with infinitely many constructors.
- The native `match` switches on a sum's tag, then tries the arms that
  can match that constructor, in order. A subject written as a tuple,
  `match (a, b)`, is never built (lib/native/to_mem.ml, `match_`). There
  is no decision tree over more than one column yet.

## The proposal in one rule

**A sequence pattern is fixed pieces at the front, at most one `..` in
the middle, and fixed pieces at the back.** For an `Array<T>` a piece is
an element pattern. For a `Str` a piece is a string literal. `..name`
binds the middle as a slice, which is a value of the same type
(foundations.md, decision 17). `..` alone ignores it.

```ren
match segs                        // Array<Str>
  [] => root()
  ["v1", "keys", k] => get(k)     // a Str literal is an element pattern
  ["static", ..path] => files(path)   // path: Array<Str>, a slice of segs
  [first, ..rest] => other(first, rest)

match xs                          // Array<Int>
  [x] => x
  [x, y, ..] => x + y
  [..init, last] => last          // never reached here, and flagged
  [] => 0

match header                      // Str
  "Bearer " ..token => bearer(token)   // token: Str, a slice of header
  ..name ".json" => json(name)
  "*" => any()
  _ => reject()
```

What goes with it:

- **String literal patterns,** `"GET" =>`, wherever a pattern goes, and
  inside or-patterns, `"GET" | "HEAD" =>`. This closes the gap above.
- **`..` already means "the rest"** in `{ w, .. }` and `{ ..order }`
  (language.md, "Record update"). A list pattern uses it the same way,
  so no new symbol. `..rest` reads as "the rest, named `rest`".
- **Or-patterns and `as` compose as they do now.** `["v1" | "v2", ..]`,
  `[_, ..] as all`. Each alternative binds the same names at the same
  types, the data stage's rule. `..rest` inside an or-pattern binds a
  slice in each alternative, at the same type.
- **Only `Array<T>` and `Str`.** No list patterns on `Bytes`:
  language.md says "No byte patterns in `match`. Formats are the
  patterns." A `Str` prefix is text, not a wire layout, so it doesn't
  cross that line. A `Bytes` value is decoded with a format, then matched.
- **A `Str` piece is a literal, not a sub-pattern.** There's no `Char`
  (strings.md, "Characters"), so there's nothing to match one character
  against. `"Bearer " ..token` covers prefixes, `..stem ".json"` suffixes,
  `"<" ..inner ">"` both.
- **Binding `..rest` costs what a slice costs.** It copies nothing. If it
  doesn't escape it costs nothing; if it's kept, one count on the root
  (decision 17).

### Open for the owner

1. **Ship the `Str` prefix/suffix form now, or only literals?** Literals
   are the gap. Prefix is the common real case (`Bearer `, `/v1/`,
   `--flag=`). It's the same one rule, so it adds no new concept. I'd ship
   both.
2. **`[..init, last]` on `Array`.** It falls out of the rule and costs
   nothing extra to compile. Keep it.

### Prior art

| Language | Array/slice patterns | String prefix | Binding the rest |
|---|---|---|---|
| Rust | `[a, b, rest @ ..]`, `[.., last]` | no | `rest @ ..`, a sub-slice |
| Swift | none | no | — |
| Elixir | lists `[h \| t]` | `"Bearer " <> token` | the tail |
| Haskell | lists `x:xs` | `"Bearer " ++ t` needs view patterns | the tail |
| C# 11 | `[a, .. var rest]`, `[.., last]` | no | `.. var rest` |
| Python 3.10 | `[a, *rest]` | no | `*rest`, a copy |
| Ren (this) | `[a, ..rest]`, `[..init, last]` | `"Bearer " ..token` | `..rest`, a slice |

Rust and C# land on the same shape: one rest, fixed pieces either side.
Ren's `..rest` is Rust's `rest @ ..` without the `@`, since `..` already
means "the rest" here.

## Exhaustiveness

The checker keeps Maranget's algorithm and adds one constructor family,
the one rustc uses for slice patterns
(rustc_pattern_analysis, `Slice`/`SliceKind`).

- `[p1, ..., pn]` with no `..` is the constructor **length n** with n
  fields.
- `[p1, ..., pk, .., q1, ..., qm]` matches **every length at least k+m**.
- To check a column, the lengths are split. Let L be the largest of (the
  longest fixed pattern + 1) and (the largest k+m). Lengths 0 to L-1 are
  each their own constructor. "L or more" is one more constructor, whose
  fields are the first k and last m, with the middle ignored. A pattern
  with a rest is specialized to each length it covers, with `_` filling
  the middle.
- The type has a constructor for every length, so a match that has
  `[]`, `[_]` and `[_, _, ..]` is exhaustive with no `_` arm.
- Missing arms print as code, as now: `[_, _, ..] => todo`,
  `["v1", _] => todo`.
- **`Str` literals are like `Int` literals:** infinitely many
  constructors, so a `match` on a `Str` needs a `_` or a binding. A `Str`
  prefix pattern counts like a literal for exhaustiveness: it never covers
  the type. A literal arm after a prefix arm that covers it,
  `"Bearer " ..t` then `"Bearer x"`, is flagged unreachable. That check
  is a prefix test between literals, which the checker does at compile
  time.
- Unreachable arms are flagged as now. `[..init, last]` after `[x]`,
  `[x, y, ..]` and `[]` is unreachable, since every length is taken.

## How a route `match` compiles

```ren
match (req.method, req.path.segments())
  (Get, ["v1", "keys"]) => list()
  (Get, ["v1", "keys", k]) => get(k)
  (Put, ["v1", "keys", k]) => put(k, req.body)
  (Delete, ["v1", "keys", k]) => delete(k)
  (Get, ["v1", "keys", k, "versions"]) => versions(k)
  (Get, ["v1", "health"]) => ok("up")
  (_, ["v1", ..]) => not_found()
  _ => bad_request()
```

The tuple isn't built (to_mem.ml already doesn't). The arms become a
matrix with columns `method`, `len(segs)`, `segs[0]`, `segs[1]`, and so
on. The compiler turns the matrix into a **decision tree**, Maranget's
"Compiling pattern matching to good decision trees" (2008), the way OCaml
does. The column order heuristic is "needed by the most rows first,
cheapest first". So the tree is:

```
switch len(segs)                               one compare
  2: idx0 = (segs[0] == "v1")                   one literal: length + compare
     idx1 = phash({"keys", "health"}, segs[1]) 2 literals: perfect hash
     switch (idx1, method)
       (keys, Get) => list
       (health, Get) => ok
       _ => not_found
  3: idx0, idx1 as above
     switch method: Get => get, Put => put, Delete => delete, _ => not_found
  4: idx0, idx1, idx3 = phash({"versions"}, segs[3]) ...
  _: if len >= 1 && segs[0] == "v1" then not_found else bad_request
```

The work is shared across arms:

- **Each segment is looked at once per path through the tree.** The
  chain of `if`s today compares `segs[0]` against "v1" once per arm,
  seven times for a request that falls through. The tree compares it
  once.
- **A literal column becomes an index, then a dense `switch`.** The
  literals in a column at one node form a set. The compiler looks the
  segment up in that set once and gets a small integer, or "none". The
  arms switch on that integer, which C compiles to a jump table.
- **The lookup form depends on the set's size**, from the measurements
  in results.md:
  - 1 literal: a length test and an inline compare (0.34 ns). The hash
    adds nothing there.
  - 2 or more: the perfect hash with a 16-byte compare. It already wins at
    2 keys (0.87 ns against 1.5 to 1.7 ns for the chain, the length
    switch and rustc). On the seven real key sets it took 0.9 to 1.6 ns,
    against 5.3 to 13.6 ns for the chain Ren emits today and 3.4 to
    13.7 ns for rustc's `match`.
  - Keys longer than 16 bytes keep the hash and compare with `memcmp`.
  - If no hash is found within the budget (none of the 11 sets hit this),
    it falls back to the length switch.
- **The method column is a sum's tag**, one byte, so it's tested where
  it splits the most rows. Here that's after the segments.
- **`..rest` and `k` bind slices.** `k` is `segs[2]`, an element. A
  `..path` would be `segs[i..len-j]`, which costs nothing unless kept.

**`segments()` itself allocates an array of slices.** The match can't
avoid that, since it is matching an array. Two ways to make it cheap
later, neither needed for the design: a small array that doesn't escape
goes on the stack, or the compiler fuses `segments()` with the match and
cuts the path as the tree asks for each segment. Measure first.

## What the compiler adds, in order

1. Parse `"..."` as a pattern, `[...]` with `..` and `..name`, and
   `"lit" ..name` / `..name "lit"` on `Str`.
2. Type rules: `[...]` against `Array<T>`, elements against `T`, `..name`
   bound at `Array<T>`; `Str` pieces against `Str`, `..name` at `Str`.
3. Exhaustiveness: the length constructors above, and `Str` literals as
   an infinite family.
4. Lowering: a decision tree for the matrix. Today's tag switch is the
   one-column case of it.
5. Emit C: a literal set of 2 or more becomes the perfect-hash table
   from `gen.ml` (code/gen.ml), its tables in read-only data.
6. Runtime: the 16-byte masked compare (code/phrt.h). Either keep
   Lemire's page check, which costs nothing measurable here, or pad every
   string allocation so 16 bytes past any string's start are readable.
   See results.md, "Over-reading".

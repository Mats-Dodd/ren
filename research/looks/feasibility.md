# Looks: compiler feasibility

Written 2026-10-29 against `main` at 78b28ec (data stage merged). Read
only; probes are in `feas/` beside this file, run with
`_build/default/bin/main.exe run`. Sizes: **S** about a day, **M** a
few days to a week, **L** more, or with a design risk in it.

## What the probes found (today's compiler)

| Probe | Result |
|---|---|
| `format unix for Time = Int via (...)` (`b_format.ren`) | parse error: only `fn type dep handler test group` at the top |
| top-level `let LIMIT = 3 + 4` (`c_let.ren`) | parse error, same place |
| `P.shape` (`d_shape.ren`) | "`P` has no member named `shape`" |
| `dep Keys = list: fn(prefix: Str = "", ...)` (`a_default.ren`) | parse error at `=`: function types take no defaults |
| `Keys.get(key: "a")` (`i_named.ren`) | "`key` isn't passed by name"; the error prints `NotFound(Str)`: payload names are gone |
| `type R = { a: Int = 3, ... }` (`h_fielddef.ren`) | parse error: no field defaults (synthesis A4) |
| `size_of<Int>([1])` (`k_tyapp.ren`) | "comparisons can't be chained": **no explicit type arguments at a call** |
| `dep Chan<T>` (`e_generic.ren`), an op taking a block (`f_blockop.ren`) | both accepted |
| `type Cfg ... pub let default: Cfg = ...` (`g_assoc.ren`) | works; lowered as a zero-argument function, run at every use |

Cross-cutting prerequisites the drafts assume but don't list:

- **Explicit type arguments in expressions** (`json.decode<T>`,
  `shape.through<T>`, `cli.parse<Keys.Call>`, `http.mount<Keys>`).
  Parser (`<` after an identifier is a comparison today), Infer, and
  the grammar. **M.** Every shapes library needs it, not only looks.
- **A dependency as a type argument** (`http.client<D>`). Today only
  `over any` is generic over a dependency. **M**, Infer; it also needs
  a way to say "D is a dependency" on a type parameter (`tneeds`
  exists in `Ast.fn_def` and is the natural home).
- **Names in function types.** `Parser.parse_fn_ty_param`
  (parser.ml:530) reads `key:` and throws it away; `Ty.param` is
  `{mode; ty}`; `Iface.Dep of field list` keeps each op as a `Ty.Fun`.
  So a dep's operations have no parameter names, no defaults, and
  their errors' payloads no names (`Iface.error = Tag of string *
  Ty.ty list`, `Ty.label` likewise). `D.Call` cases need field names
  (the route hole `\{key}` is "the case's field `key`"), and `D.Error`
  on the wire needs payload names.

---

## 1. The compiler-written enums, and `D.Call` / `D.Reply` / `D.call`

### Where language.md §6's description enum is built today

- **Interpreter:** a description is `VHandler` (lib/eval/value.ml:73);
  no enum, the closure is the tag.
- **Native debug:** a description's first word is `Handler_tag n`,
  a pointer to the handler's static record
  (lib/native/mem.ml:139, emit_c.ml:155-176): a vtable.
- **Native release:** the closed set is `Dispatch.reach`, the handlers
  per dependency (lib/native/dispatch.ml); `Handler_tag` is a number,
  and dispatch.ml picks Direct / Arms / Table / Code. clone.ml copies
  loops per tag. **This is the enum §6 means: it exists only in
  lib/native, made from Mem's `handlers` list.** Nothing in sema or
  lower writes an enum type.

### Where decision 18's mailbox enum would be

Nowhere yet: `post`, mailboxes and `actors` are the services stage's
(brief steps 0 and 8; std_lib.ml's `actors`, sched.ml, the journal).
Their brief asks step 0 to settle "how `Actors<K, D>` and `Merge<D>`
are declared or derived" and the mailbox representation in the
scheduler. The likely interpreter form is an op index plus an argument
tuple, which `over any` already derives (below).

### The nearest thing that exists: `over any`

compiler.md "`over any` and `retry` (step 5)" shipped a per-dependency,
per-operation derivation: the op's name, descriptors of its argument
tuple and result, its declared errors (Infer: infer_handlers.ml,
infer_env.ml:217-227; Lower: the `Any_for (handler, dep)` request,
lower.ml:64-90 and 1022-1320, made once per pair in the declaring
module by driver.ml:227). `call.args` is deliberately opaque and
`call.forward()` is the only way on. The prelude's `recorder` (the
journal) is an `over any` handler.

**Conflict with the drafts:** draft-shapes says shapes.md's
`call(op, args)` "becomes `call(c: D.Call)`". The compiler never had
`call(op, args)`; it has `over any`'s `call =>`, which works for *every*
dependency, data or not, and carries the journal. `D.Call` exists only
for all-data deps, so it can't replace `over any`. Recommend: keep
`over any` as is; add `call(c: D.Call)` as a clause of a handler `over
D` for a concrete all-data `D`, and let `next.call(c)` be `D.call`.
Changing `over any` itself touches the journal, which services owns.

### What generating `D.Call`, `D.Reply`, `D.Error`, `D.call` needs

| Piece | Where | Size |
|---|---|---|
| Keep op parameter names, defaults and error payload names: a dep op becomes a signature record in `Iface.Dep` (name, params with names/modes/defaults, result, errors with payload names), not a bare `Ty.Fun` | ast.ml `TyFn`/`Dep`, parser.ml:530, resolve.ml:3230-3300, iface.ml(i), infer_declared.ml:176, infer_expr.ml:1804 (`op_of_value`) | **M** |
| By-name arguments and defaults on op calls, `Keys.list(limit: 10)` (named functions have `scheme.defaults`; ops don't) | infer_expr.ml, lower.ml (fills defaults) | **S** once the above lands |
| The data-only check: no block (`TyFn` param), no `&`, no `Impl`, no view, a data result; a build error naming the op wherever `D.Call` is named (directly, via `post`, `cli`, `http`) | a new function beside infer_handlers.ml; `post`'s rule (decision 18) is the same check, so it should be one function | **S** |
| Write the three types: `D.Call` a sum (case per op, by-name fields = params, defaults = field defaults), `D.Reply` a sum (case per op, one positional field of the result; fieldless for `()`), `D.Error` a named error set (union of op rows) | Resolve, as synthesized `type_def`s in the dep's namespace, so Infer, Lower, eval, `==`/`show`/`hash` (walk.ml) and native layouts treat them as ordinary sums with zero new code downstream | **M**: needs `Keys.Call` to resolve (today `X.Y` with both upper is a variant type, `Order.Placed`, ast.ml TyVariant), and `Keys.Call.Get` a three-part constructor reference (parse_ctor_ref handles two) |
| `D.call(c: D.Call) -> D.Reply ! D.Error uses D`: `match c` with one arm per op, each a `Dep_call` wrapped in its `Reply` case | a Lower request `Call_for D`, beside `Any_for` (made once per dep in the declaring module); or synthesized source in Resolve. Either produces plain `Match` + `Dep_call` Core, so **no change to eval's `Dep_call`** (services' file) | **S** |
| Generic deps, `dep Chan<T>` | `Chan.Call<T>`, `Chan.Reply<T>`: the synthesized types take the dep's parameters. An alias `dep Jobs = Chan<Job>`: Resolve maps `Jobs.Call` to `Chan.Call<Job>` (there are no type aliases, only `Dep_alias`; resolve.ml:3266 and infer_top.ml:662 already chase it) | **S** |
| Ops with by-name defaults | become field defaults of the `Call` case, so they need synthesis A4 (record/constructor field defaults: parser, Infer, Lower); until then a `Call` case is built with every field | A4 is **M**, owned by 12a |
| Ops taking blocks | can't cross a wire and can't be posted: the dep gets no `D.Call`, and naming it is the data-only error. `over any` still covers it | **S** (the check) |
| Errors as tags in Reply | the wire carries `Result<D.Reply, D.Error>`; `Result<T, ! ...>` with an error-set argument exists (ast.ml `TyErrors`). `D.Error`'s shape needs payload names (first row) and draft-formats' "error sets have a shape inside `Result`", which is shape work (§3) | **S** on top of the rows above |
| `remote` header word | §4 | **S** |

**Blockers:** the names-in-op-signatures change (first row); A4 for
defaults; explicit type arguments for `cli.parse<Keys.Call>` and
`http.client<D>`.

**Native:** `D.Call`/`D.Reply` are ordinary sums, so to_mem lays them
out like any; release `D.call` after a known handler inlines to a
direct call through specialize.ml's evidence key. Nothing new in
lib/native.

---

## 2. `format` declarations: parsed or checked today?

**Not at all.** No token, no AST node, no tree-sitter rule.
formats.md layer 2 (layouts) is deferred to foundations staging 7b; the
bytes stage did layer 3 only (`b.u32_le(at)`, cursors), and bytes part
two's brief lists layer 2 as out of scope (stage-bytes-2.md:136).
compiler.md:6278 notes "layer 2 fills" error paths later.

What looks add, by pass:

| Pass | Work | Size | Conflicts |
|---|---|---|---|
| **Lexer** | Nothing for looks part 1: `as`, `for`, `..`, `\|`, `=` exist; `format`, `via`, `reads`, `writes`, `lossy`, `remote`, `tag`, `content` should be **contextual** words, like `call`, `task`, `finally`, so no program's identifiers break. Route tags `GET"/v1/keys/\{key}"` need F1 value-prefix strings and `\{` holes | 0 / S | **bytes-2 owns string literals and `\{` holes.** Route looks wait for them |
| **Parser** | New top-level items `[pub] format NAME for T[, words] =` and `let`. One parser for layouts and looks; the kind read off the lines (layout line forms are formats.md's, needed by 7b anyway). Record lines (`f`, `w = f`, `f: Look`, `w = "lit"`/`w = Ctor`, `..`), sum lines (`\| C as tag[: Look]`, `\| ..`, `\| C as ..`), `X via (r, w)`. The token rule for `=` (lowercase ident = field; literal or uppercase = constant) is purely syntactic. Plus explicit type arguments (above) | **M** | parser.ml is a shared file: add cases at the top-level dispatch, don't restructure. Services adds `wiring` and `\|>` there too; rebase often |
| **AST** | `Format` item: name, target type (incl. a variant type, `Event.Placed`, and a dep's `Keys.Call`), header words, kind, lines | S | |
| **Resolver** | Formats join the target type's member namespace (clash with methods and ops: the check at resolve.ml:3300-3345 already does op-vs-member); right-hand names resolve to the type's fields/cases; `Look` names (`Order.v1`, `Event.Placed.v1`) as member paths; visibility (`pub format`, a `pub` look naming only `pub` functions); a look of an opaque type must be a `via`. **Open:** a look for another module's type (`format unix for Time` where `Time` is std): the draft doesn't say; members of foreign types don't exist today, so either forbid it (orphan rule) or key formats by (type, module) in `Iface` | **M** | resolve.ml isn't on either stage's list; fine |
| **Checker** | `via` typing (`X -> T ! E`, `T -> X [! E]`), purity (no `uses`, as resolve's `reserved` already checks for `key`/`show`), chain cycles, left-out fields (needs A4), duplicate wire names, sum completeness, distinct tags, `reads`/`writes` direction at use, two looks for one type in a settings list, layout-vs-look kind as a type error. Most are on declarations and don't need inference; `via` typing and the settings checks do (Infer, as constant expressions) | **M** | infer_expr.ml is shared: add cases only |
| **`Look`/`Layout` enums** | Not a source-level sum. A `Look` value is a format's path: `VLook path` in eval, a pointer to a static format record in a native debug build (as `Handler_tag` is), a number in release (closed world, as dispatch.ml numbers handlers). Its type is a prelude `Look`; `Layout` the same | **S-M** | to_mem.ml/emit_c.ml are bytes-2's where Str/Bytes are laid out; a new atom kind is a different region, but it's their file: add, don't move |
| **tree-sitter** (editors/tree-sitter-ren) | `format_definition` with record and sum line rules, `via`, header words; top-level `let`; type arguments in expressions; `remote` in `dependency_definition`; corpus files (`test/corpus/formats.txt`), highlight assertions, and `make check`'s differential.py against the compiler's parser; Zed's highlight queries | **M** | services also edits grammar.js (wirings, `\|>`): new rules in new places, rebase before push |

---

## 3. `T.shape`, top-level `let`, and specializing the walk

### `T.shape` today

**Doesn't exist** (probe `d_shape.ren`). What it would be built from
does exist:

- Core's `desc` (core.ml:57-80) is a runtime type descriptor every
  generic function already receives; eval's `walk.ml` reads
  `Iface.type_decl` through it (fields, constructors, `cnamed`, opaque
  reps) for `==`, `hash`, order and `show`.
- Native: `ren_decl` / `ren_ctor_info` (ren_rt.h:1690-1730) carry type
  names, constructor names, field names and field descriptors; a native
  build can read a `Shape` from these.

So debug-build `T.shape` is a builtin that turns a descriptor into the
std `Shape` ADT value (eval: in builtins.ml; native: a runtime function
over `ren_decl`). **M**, plus the `Shape`/`Value` ADTs in std (S) and
`shape` as a requirement (infer_reqs.ml, beside `eq`/`hash`: **M**).
The doors `view<T>`/`build<T>` per (type, look set) fit Lower's
existing request mechanism (`Any_for`, `Tags_for` at lower.ml:64-90):
add `Doors_for (T, looks)`, made once per pair. **M**.

Missing for shapes in general: the native slice refuses a type with its
own `show` (ren_rt.h:1796, to_mem.ml:36); the walk stopping at `repr`
natively needs the same lifted.

### Do top-level `let`s run at build time?

**No.** shapes.md's "the top level is build time" isn't implemented:
top-level `let` doesn't parse (`c_let.ren`). The only module-level
values are associated values (`pub let default: Cfg = ...` in a type),
lowered as zero-argument functions and **run at every use**
(`g_assoc.ren`, `ren core`).

Two steps:

1. **Top-level `let`, pure, as a zero-argument function** like an
   associated value: parser, Resolve (a module-level value namespace),
   Infer (no `uses`, no block in the value), cycles. Meaning is right
   (pure and deterministic); only cost differs. **S-M.** Enough for
   settings records in debug builds.
2. **Build-time evaluation proper:** run each top-level value in the
   interpreter at build, with a step budget; put the result into Core
   as a constant (Core has no "value literal" node: a new `Const` of
   an eval value, or rebuild it as constructor expressions); native
   emits it as static data (to_mem/emit_c). Top-level `assert`. **L.**
   The build's world, journal and caching (shapes.md) are later still.

### Can the walk through looks be a build-time constant that release builds specialize (decision 4)?

**Partly, and the hard part isn't the constant.**

- `shape.through<T>(formats)` where `formats` is a literal or a
  top-level `let` *at the call* is easy to fold: a Lower request per
  (T, look list) gives a constant `Shape`, and the doors are straight
  line because the compiler writes them. **M.**
- But the call in the drafts is inside the library: `json.decode<T>(text,
  s)` reads `s.formats` from a parameter. specialize.ml keys copies on
  **types, blocks and evidence** only (specialize.ml:9-33), never on a
  value. Needed: a new key component, "this argument is a known
  top-level constant", with field projection folded in the copy.
  **M-L**; the copy count is bounded by (type, settings) pairs, as the
  drafts say.
- "Straight-line code: a key switch, `via` inline, no `Value` tree"
  further needs the **library's own `match` over a constant `Shape` to
  unfold**: partial evaluation of recursive library code over constant
  data, keyed per shape node (memoized on `Ref` for recursive types).
  Nothing in lib/native does this (inline.ml inlines calls; fold.ml
  merges identical functions). **L, and the real risk** behind the 12a
  measurement (`json.decode<Order>` within 1.5× of hand-written). If it
  fails, the fallback the synthesis names (a visitor the compiler
  writes per (T, looks), with the library supplying leaf callbacks as
  blocks, which specialize.ml *does* specialize) is **M** and fits today's
  keys.
- **Freeze fingerprints:** the synthesis says they reuse "the content
  hashes specialization caches by". **There are none** (no `Digest`
  anywhere in lib/ or bin/). An IR hash is new: hash Core's printed
  form (`ren core` already prints it) of each `via` function and its
  callees. **S-M.**

---

## 4. The `remote` build error and the reserved-name walk

### "A remote dep needs `Unavailable` on every op"

- **With `remote` in the header (synthesis's recommendation):** parse
  one word after the dep name (parser.ml's dep item); in Resolve, where
  a `Dep` body is converted (resolve.ml:3265), append
  `Unavailable(why: std.remote.Why)` to each op's error set. `Why` is a
  new std module (`remote`), not one of services' std_lib entries.
  `ren types Keys` shows it for free. **S.** Needs payload names kept
  (§1) for `why:`.
- **Runner-up (by hand, plus a build error):** the error lives where a
  dep is *used* remotely: a requirement on a dep-typed type parameter
  (`fn client<D>` with `tneeds` "remote"), checked in infer_reqs.ml at
  each use, walking each op's row for the tag with `std.remote.Why`'s
  payload. **M**, and it needs deps as type arguments (prerequisite).
  The header word is cheaper and has no such prerequisite.

### The reserved-name walk (`show`, `key`, `parse`, `repr`)

- **Signatures** of reserved members are checked in resolve.ml's
  `reserved` (resolve.ml:3040-3150: arity, `self`, purity, written in
  full, `pub` on a `pub` type) and `reserved_types` (3155-3190: `show`
  makes a `Str`). Add `parse` (an associated function, `fn parse(x: X)
  -> T ! E`, pure) and `repr` (`fn repr(self) -> X`, pure), and the
  check that `parse`'s parameter type is `repr`'s result. **S.**
- **Where the walk stops at them:** `key` in walk.ml (`keyed`, :164)
  and infer_reqs.ml:285; `show` in shown.ml and lower.ml:2849; natively,
  `key` through `ren_decl.key` and emit_c's key wrapper, `show` refused.
  `parse`/`repr` stop the shape walk, so they live in the doors
  (`Doors_for`, §3) and in `shape.through`'s builder, not in walk.ml.
  **S** given the doors.
- Look names clashing with methods: the member-namespace check beside
  resolve.ml:3300-3345. **S.**

---

## Summary: pieces, sizes, stages

Services and bytes part two are running; anything touching their files
waits for them or adds cases only.

| # | Piece | Size | Blockers / depends on | Conflicts | Stage |
|---|---|---|---|---|---|
| 1 | Explicit type arguments at calls (`f<T>(...)`), parser + Infer + grammar | M | none | parser.ml, infer_expr.ml shared (add cases) | **12a, first** (every shapes library needs it) |
| 2 | Top-level pure `let` as zero-arg functions | S-M | none | parser.ml shared | **12a** |
| 3 | Field defaults (A4) | M | none | parser.ml, lower.ml shared | **12a** |
| 4 | `T.shape`, `Shape`/`Value` ADTs, `shape` requirement | M | 1 | builtins.ml shared | **12a** |
| 5 | `format` parser (looks and layouts, one parser), AST, Resolve, checks | M + M | 2, 3; layer 2 layouts (7b) share it | parser.ml shared | **12a part 1** |
| 6 | `Look` as a value (eval path, native pointer/number), `shape.through`, doors as a Lower request | M | 4, 5 | to_mem/emit_c are bytes-2's files: add only, after bytes-2 merges for the native part | **12a part 1** (eval); native after bytes-2 |
| 7 | `parse`/`repr` reserved members | S | none | none | **12a** (could go now) |
| 8 | `ren explain`, hover | S-M | 6 | none | **12a part 1** |
| 9 | Release: specialize on a known constant argument | M-L | 2 | none (specialize.ml is no one's) | **12a measurement** |
| 10 | Release: unfold a library `match` over a constant `Shape` (or the visitor fallback, M) | L | 9 | none | **12a measurement**; decide by the 1.5× number |
| 11 | Build-time evaluation of top-level values, static data | L | 2 | to_mem/emit_c (bytes-2) | **after 12a**; not needed for looks to work |
| 12 | `reads`/`writes`/`lossy`, generated round-trip tests | M | 6, 11c generators | none | **12a part 2** |
| 13 | Dep op signatures keep names, defaults, error payload names; by-name op calls | M + S | 3 for defaults | infer_expr.ml shared; **services' `post` and `Merge<D>` derive from the same op list** | **before or at 12c**; best right after services merges |
| 14 | `D.Call`/`D.Reply`/`D.Error` written by Resolve; `D.call` as a Lower request; data-only check; generic deps by substitution | M + S | 13; three-part names (`Keys.Call.Get`) | **services' mailbox** is decision 18's enum: let services keep an internal (op index, args) mailbox, and unify with `D.Call` after; don't touch `over any`/journal (services) | **12c, part 1** |
| 15 | `call(c: D.Call)` clause for handlers `over D`; `over any` kept | M | 14 | infer_handlers.ml, lower.ml; journal untouched | **12c** |
| 16 | `remote` header word + `std.remote.Why` | S | 13 | none | **12c** |
| 17 | Route and status looks, http `check` at build time | L | 11, F1 prefix strings, `\{` holes | **bytes-2 owns the lexer's string literals** | **12c, after bytes-2** |
| 18 | Freeze: IR hash (new), `formats.lock`, connect check | S-M + M | 6, 14 | none | **12c** |
| 19 | tree-sitter + Zed for all of the above | M | lands with each piece | grammar.js also edited by services | with each piece |

### Corrections to the synthesis's §6

- `call(op, args)` was never built; `over any`'s `call =>` was, and it
  carries the journal. Keep it; add `call(c: D.Call)` beside it.
- No content hashes exist to reuse for the freeze fingerprint.
- Missing from its table: explicit type arguments at calls, names and
  defaults in dep op signatures, error payload names, deps as type
  arguments (runner-up `remote` only), and three-part names
  (`Keys.Call.Get`, `Event.Placed.v1`).
- "Release builds specialize each (type, settings) pair into
  straight-line code" is two steps, not one: a constant-argument key
  in specialize.ml (M-L), then unfolding the library's walk (L). The
  second is stage 12's risk 2.

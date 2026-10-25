# Modules & Builds

**Every name has one home. Every build is a lookup.**

This doc covers how Ren code is organized into files and packages, how names are found, and how `ren build` turns all of it into binaries. The two halves depend on each other. The module rules are what make the build fast and trustworthy, and the build is the reason the module rules look the way they do.

> **Status:** partly built. Files as modules, `import`, `pub`, `opaque` types, lookup through types (constructors, fields and methods), interfaces made from declarations, `uses` on signatures, and methods, associated functions and associated values declared under their type run today, in stages 5a and 5b; [examples/shop](examples/shop) uses them all. Structural error tags, named error sets imported like types, and the "two shapes" error run too, in stage 6; [examples/bank](examples/bank) uses them. Dependencies declared with `dep`, imported like types, and `pub group`s imported to run their tests run too, in stage 7. Operators, packages and the build are still planned; see [Roadmap](#roadmap).

---

## The short version

```
 a file is a module            shop/billing/stripe.ren  →  `shop/billing/stripe`
 imports are explicit          import shop/billing/stripe      → stripe.charge(...)
 values are always qualified   you can always see where a call comes from
 the type is the other home    Red, user.plan, a + b, &xs.push(x): found through a type
 no wildcards, no cycles       nothing found behind your back
 private unless `pub`          internal/ for package-private
 builds are pure functions     same inputs, same outputs, cached forever
```

---

## Three rules

Everything else in this doc follows from three rules.

**1. What crosses a boundary is written down. What stays inside is inferred.**
This is the first principle, *the signature is the truth*, applied to modules. Anything `pub` states its whole contract in its declaration: parameter and result types, errors, `uses`, and which function parameters are transparent. Private code can leave all of that out. The one exception is what a generic function needs of a type parameter, such as `==`: it's inferred from the body, on a `pub` function too ([operators.md](operators.md#generic-code)), and kept in the module's interface. Inference never crosses a module boundary, so a module can be checked knowing only its imports' interfaces.

**2. Every name has one home, found in one of two ways: through scope or through a type.**
Modules, values, and types are found through scope, by importing them. Constructors, fields, operators, methods, and dependency operations are found through a type, by looking in that type's own declaration. Nothing is found any other way: no search, no wildcards, no implicit imports beyond the prelude. Error tags are the one deliberate exception: they're structural and have no home.

**3. Identity is a path. A cache key is a content hash.**
Every top-level entity is named by where it lives: `shop/billing/stripe.charge`. Every cached result is keyed by the hash of what it was computed from. Modules exist for readers, and the cache doesn't care how big they are.

---

## Part 1: Modules and names

### A file is a module

There are no `mod` declarations and no module blocks. Where a file lives is the only thing that names it.

```
shop/                       ← a package (it has ren.toml)
  ren.toml
  main.ren                  ← shop/main
  billing/
    stripe.ren              ← shop/billing/stripe
    invoice.ren             ← shop/billing/invoice
  internal/
    retry.ren               ← only importable from inside shop
  deps/
    json/                   ← a vendored dependency
```

A directory is only a folder. It isn't a module, and it isn't a privacy boundary, except for `internal/`.

### No import cycles

```
error: import cycle: billing/stripe → billing/invoice → billing/stripe
   ┌─ src/billing/invoice.ren:1:1
 1 │ import shop/billing/stripe
   │ ^^^^^^^^^^^^^^^^^^^^^^^^^^
   help: move what both modules need into a third module that both can import
```

Banning cycles gives the compiler a dependency order. That order is what lets it check modules in parallel and skip the ones that haven't changed. The price is that types that refer to each other have to live in the same file.

### Found through scope: imports

```ren
import shop/billing/stripe              // stripe.charge(...)
import json/decode as jd                // jd.parse(...)
import shop/plan.{Plan, User}           // types, unqualified

pub fn checkout(u: User) -> Receipt ! PaymentFailed
    uses stripe.Client =
  try stripe.charge(u.id, price(u.plan))
```

- **Values from another module are always qualified.** You'll read `stripe.charge`, never a bare `charge` that could have come from anywhere. Inside its own module, a value is written bare.
- **Types can be imported by name**, because `fn f(u: shop_plan.User)` would make every signature unreadable. Only types can be imported by name.
- **There are no wildcard imports.** `import x.{*}` doesn't exist.
- **Unused imports are an error**, with a fix that deletes them.
- **A local can't shadow an import.** Then `stripe.charge` is always the module and `user.charge` is always a field, decided by scope alone.
- **The keyword is `import`, not `use`,** so it can never be confused with `uses`. One is about modules, the other is about capabilities.

### Found through a type

Constructors, record fields, operators, methods, and dependency operations all live on a type. You don't import them: once the type is known, its own declaration is the only place to look.

```ren
type Light = Red | Yellow | Green
type Suit  = Red | Black

fn next(l: Light) -> Light =
  match l
    Red    => Green           // the subject is a Light, and so is the result
    Yellow => Red
    Green  => Yellow

fn main() = print(Red)        // nothing says which `Red`
```

```
error: `Red` could be `Light.Red` or `Suit.Red`
  ┌─ test.ren:9:19
9 │ fn main() = print(Red)
  │                   ^^^
  help: write `Light.Red`, naming the type you mean
```

Every lookup through a type follows the same three steps:

1. **If the expected type is already known at that point**, look there. Known means: an annotation, the declared parameter type of the function being called, the subject of a `match`, the declared result type, or an earlier argument or operand. The checker reads left to right and never waits for something it learns later.
2. **Otherwise, if exactly one visible type has that name**, use it. A type is visible if it's declared in this module, imported by name, or in the prelude.
3. **Otherwise, it's an error** that suggests a qualification or an annotation.

```ren
let names = users.map(fn(u) => u.name)    // `users` is checked first, so `u` is a User

fn label(u) = u.name                      // fine if only one visible record has `name`;
                                          // otherwise: "annotate `u`"
```

The result never depends on the order the checker happens to discover things in, so it's deterministic and predictable. When the type is known, step 1 goes through the type's declaration, not through scope. `Free` therefore works wherever a `billing.Plan` is expected, even if `Plan` was never imported. The full form `billing.Plan.Free` also works.

Two libraries can both define `Error`, and the prelude doesn't reserve `Some` and `None` everywhere.

### Methods and operators live on the type

A type's members, indented directly under its declaration, are everything attached to it: operators, associated values, and methods. Only the module that declares the type can write them, so every lookup goes to exactly one place and orphan instances can't exist.

```ren
pub type Stack<T> = { items: Array<T> }
  pub fn push(inout self, x: T) = &self.items.push(x)
  pub fn peek(self) -> Option<T> =
    let n = self.items.len()
    if n == 0 then None else Some(self.items[n - 1])
  pub fn of(xs: Array<T>) -> Stack<T> = Stack { items: xs }
  pub let empty: Stack<T> = Stack { items: [] }
```

A method is an ordinary function whose first parameter is `self`, which has the type it's declared under, and `x.m(args)` is shorthand for `Type.m(x, args)`. `m` is found through `x`'s type, with the same three steps as a field. Without `self` it's an associated function (`Stack.of(xs)`), and a `pub let` is an associated value, pure and made once when the program starts (`Stack.empty`).

```ren
var s = Stack.empty               // an associated value
&s.push(1)                        // Stack.push(&s, 1): `&` because push changes `s`
let top = s.peek()                // Stack.peek(s)
let t = Stack.of([7, 8, 9])       // an associated function
```

**`&` marks a changed receiver, just as it marks a changed argument.** `&s.push(1)` puts the `&` in front of the receiver, and leaving it out is an error. So a function body still uses exactly two markers: `try` for a call that can fail, `&` for a call that changes something. A `&` in front of a place (`f(&xs.items)`) passes that place `inout`. A `&` in front of a method call (`&xs.items.push(1)`) marks the receiver. A call's result is never a place, so the two can't be confused.

You can't add methods to a type you don't own. Write a function in your own module (`mylib.chunks(xs)`), or wrap the type in an `opaque` type and give that type its own methods.

Operators (written `add(a, b) => ...`, arriving in stage 9) are public whenever their type is. Methods, associated functions and associated values are private unless they're marked `pub`, like everything else, and the `pub` ones are listed under their type in the module's interface.

### Dependencies are types

`import shop/db.{Users}` followed by `uses Users` gives you `Users.get(id)`. `Users` is found through scope, and `get` through the `dep` declaration, which lists its operations and then its members, so `Users.get` and `Users.none()` are found the same way a type's members are. An operation and a member can't share a name, so `Users.x` means one thing. A handler is imported like a function, and a `pub group` like one too, to run its tests: `group "s3" = blob_conforms(s3.client(bucket))`.

### Error tags have no home

Error tags are structural, like OCaml's polymorphic variants. You don't declare or import them; you just `fail NotFound`. Two libraries can use the same tag name with different payloads:

```ren
// http                                       // mutex
fn fetch(u: Url) -> Bytes ! Timeout(ms: Int)  fn lock() -> Lock ! Timeout
```

That only matters if one error set would contain both shapes:

```
error: `Timeout` has two shapes here
   = from `http.fetch`:  Timeout(ms: Int)
   = from `mutex.lock`:  Timeout
   help: rename one where it comes in: `try match mutex.lock()` with the arm `fail Timeout => fail LockTimeout`
```

Tags with the same name and the same shape are the same error, wherever they come from. Adding a dependency can never break code that doesn't touch it.

### Private unless `pub`

```ren
pub type User = { id: UserId, plan: Plan }       // type and fields exported
pub type UserId = opaque u64                     // name exported, representation hidden
pub fn load(id: UserId) -> User ! NotFound ...   // exported
fn helper() = ...                                // this module only
```

There are two levels and no third keyword. For "shared inside my package but not with my users," put the module under `internal/`, the way Go does. Only the module that declares an `opaque` type can see its representation.

Tests are written in the module they test (`test "..." =`), can see its private items, and never appear in its interface.

### Naming is enforced

`UpperCamel` is for types, constructors, and error tags, and `snake_case` is for everything else. That's how the parser tells `Plan.Free` (through a type) from `billing.free` (through scope) without looking anything up.

### A small, fixed prelude

The prelude is an ordinary module that every module imports implicitly.

| Kind | Always available |
|---|---|
| Types | `Int` `Bool` `Str` `Unit` `Option` `Result` `List` `Array` `Map` `Set` |
| Constructors | `Some` `None` `Ok` `Err` |
| Dependencies | `Clock` `Random` `Console` `Net` `Alloc` `Async` `Unsafe` |
| Functions | `print` `dbg` `assert` |

Everything else in the standard library is imported like any other module: `import std/async` gives you `async.par_map`.

**`print` uses `Console`.** It's an ordinary function, `Console.write(show(x))`, so calling it from code that doesn't declare `Console` is an error. Otherwise any pure function could quietly reach the outside world, and simulation and replay would stop being trustworthy.

For debugging there's **`dbg(x)`**, which works anywhere. It prints the value with its source location, is compiled out of release builds, and is rejected by `ren test --ci`, so it can't get committed.

### Interface summaries

For every module, the compiler generates a summary that dependents read instead of its source. You never write one by hand. The summary has two tiers:

| Tier | Contains | Read by |
|---|---|---|
| **Interface** | `pub` types (with their representation, unless `opaque`), `pub` signatures, error sets, `uses`, transparency, the signatures of `pub` types' members, and what each `pub` generic function needs of its type parameters (inferred) | type checking of dependents |
| **Implementation** | `opaque` representations, layouts and sizes, the bodies of `pub` generic and inlinable functions, inferred borrow modes, whether the module contains `trust` | code generation of dependents |

**The interface is computed from declarations, and from one inferred fact.** Rule 1 makes most of that possible. Transparency would otherwise need a body, so `pub` signatures state it: a function parameter without `..e` or `..d` is transparent, and the body is checked against that. Requirements are the exception: what a `pub` generic function needs of a type parameter, `same<T has eq>`, is never written, so it comes from inferring the body ([operators.md](operators.md#generic-code) says why). The interface tier contains no source locations, so adding a blank line at the top of a file doesn't change it.

This gives you:

- **Editing a function body changes its module's interface only when it changes what a `pub` function needs of a type parameter:** using `==` on a `T` that didn't need it, or no longer using it. Anything else a body does, its types, errors, `uses` and transparency, is fixed by the signature, so dependents aren't re-checked for it. Early cutoff still holds for every such edit, and the interface is compared after checking, so an edit that leaves requirements as they were stops there too. It's guaranteed for edits that don't touch requirements, not for all of them.
- **Changing an `opaque` representation** reruns code generation for dependents, but never their type checking.
- **Dependents wait for a module's bodies to be checked,** not just its declarations, since a `pub` function's requirements come from its body. Modules still check in parallel wherever the import graph allows. It's the one place the design gives up build speed for writing less.

### Packages

```toml
# ren.toml
name = "shop"

[deps]
json   = { path = "deps/json" }
stripe = { path = "deps/stripe", allow = ["Net", "Alloc"] }
```

- **Dependencies are vendored source.** There's no registry and no lockfile, because a dependency is identified by the hash of its contents.
- **A build has one version of each package.** Two dependencies that vendor different versions of `json` are an error that names both versions, the way Go does it. So a type's identity stays `json/decode.Value`, and you never see "expected `Value`, found `Value`."
- **`allow` lists the capabilities a dependency may use.** It's checked against the dependency's interface: the `uses` of its `pub` functions, plus `Unsafe` if its implementation tier says it contains `trust`. If an update makes `json` reach for `Net`, your build fails and tells you exactly where:

```
error: dependency `json` uses a capability it isn't allowed
   = json 2.4.0: `decode.parse` now uses `Net`
     via: parse → fetch_schema → Net.get   (deps/json/schema.ren:41)
   help: pin the previous version, or add "Net" to `allow` for json
```

The `via` chain isn't stored in any summary. It's worked out from the dependency's source only when this error is reported.

---

## Part 2: Builds

> Inspired by jade's [*The postmodern build system*](https://jade.fyi/blog/the-postmodern-build-system/).

### The problem

Build systems can't trust compilers. Compilers keep their own private incremental state, so build tools can only cache whole compiler runs. Your unit of reuse ends up being a whole crate or a whole derivation. As jade puts it: *"our problem build systems become the compilers."*

### Ren's answer

Ren owns its compiler, so every step of compilation can be **a pure function of content-hashed inputs.** Caching happens inside the compiler, below the level of a module.

```
 file bytes ─parse─▶ AST ─┬─ declarations + imported interfaces ─▶ interface ─▶ dependents
                          │                              unchanged? dependents stop here
                          │
                          └─ bodies, one call-graph group at a time ─▶ typed Core
                                                                          │
                                       codegen ─▶ C ─zig cc─▶ .o ─link─▶ binary
```

The one arrow the picture leaves out runs from bodies to the interface: a `pub` generic function's requirements join it once its group is checked. Within a module, private functions are inferred one group of mutually recursive functions at a time, so the group is the unit of checking. The same early cutoff applies inside a module: if a group's inferred types don't change, the groups that call it aren't re-checked.

| | Conventional | Ren |
|---|---|---|
| The compiler | an opaque, stateful process | pure functions over hashes |
| What's cached | whole compiler runs | interfaces, call-graph groups, and functions |
| Hermetic because | an OS sandbox | the type system (no `Net`, `Clock`, `Env`) |
| Incremental means | diffing against the last build | looking up content |
| A long-running daemon | a trade-off with trust | just a cache |

**Trustworthy incremental builds come from purity and content addressing, not from rebuilding from scratch.**

### What you get

**Nothing to clean, nothing stale.** Results live in a content-addressed store keyed only by input hashes. There are no timestamps and no "last build." Every branch, worktree, CI run, and teammate shares the same results, and a fresh checkout is always correct.

**Early cutoff.** If you change a function's body, the module's interface changes only if what a `pub` generic function needs of its type parameters changes, so otherwise nothing that imports it gets re-checked.

**A cache you don't have to trust.**
```
$ ren build --verify 5%
  rebuilt 41 of 812 cached results: all identical
```
`--verify` re-runs a random sample of cached steps and compares the results. A mismatch means the compiler has a determinism bug, and Ren reports it as one. Run it at 1% in CI and the cache keeps checking itself.

**Build scripts that can't misbehave.**
```ren
// build.ren
pub fn build() -> Artifacts
    uses Build =
  let schema = Build.read("api/schema.json")          // tracked input
  let api = codegen_api(json.parse(schema))            // pure Ren, cached per function
  let proto = Build.exec("protoc",
      inputs: Build.glob("proto/*.proto"),
      outputs: ["gen/"])                               // external tool, sandboxed
  Build.binary("shop", main: "main.ren", extra: [api, proto])
```
A build script only `uses Build`. It has no network, clock, or environment access, and the compiler enforces that, so builds are reproducible by construction. A script can read a file and decide what to build next, and every read is tracked. External tools like `protoc` run in a sandbox and are cached by their declared inputs.

**Tests that only rerun when they need to.**
```
$ ren test
  ✓ 412 tests   (398 cached, 14 run)              0.31s
```
A simulation test is a pure function of the code plus a seed, so its result can be cached. Tests that use real `Net` or `Fs` can't be cached, and you can see that from their `uses`.

**Watch mode and the LSP for free.** They hold the same cache in memory. A persistent process is as trustworthy as a clean build, so you don't have to choose between a fast daemon and correct results.

**Shared and remote, later.** The store holds pure results over blobs, so CI can fill a shared cache that developers read from, and steps can run on other machines (via the Bazel Remote Build Execution protocol). Remote results get verified like local ones.

### The fine print

- **The compiler must be deterministic, forever.** No output may depend on hash-table iteration order, scheduling, timestamps, paths, or the order modules were checked in. The compiler has no global counters, and types leave the checker in a canonical form, with variables numbered by first appearance and row labels sorted.
- **Cache keys must be complete:** compiler version, target, flags, and the pinned `zig cc` hash. A missing input is a correctness bug.
- **Release builds are coarser.** Cross-module specialization and profile-guided optimization need whole-program information, so release links are less incremental than debug builds. They're still correct, just slower to rebuild.

---

## In the compiler

The three rules decide how the compiler is laid out:

- **Resolve** finds everything that's found through scope: locals, import aliases, qualified values, and type names. It also decides what each `.` means. **Infer** finds everything that's found through a type, using the three steps above, with one mechanism for constructors, fields, record literals, operators, and methods. No name is resolved in both.
- **Infer is bidirectional.** It checks an expression against an expected type whenever one is known, and it never defers a question until later. Exhaustiveness checking runs after Infer, because a constructor's type is only known once Infer has found it.
- **Every pass is a function of explicit inputs:** one module or one call-graph group, plus the interfaces of its imports. The driver runs passes in dependency order. The content-addressed store sits in front of those same functions, without rewriting them.
- **Identities are paths, and local IDs are numbered per function,** so editing one function never renumbers another.
- **The prelude is the first ordinary module.** Built-in types and functions are declared in it, with their implementations supplied by the compiler.

---

## How it all fits

```
 file = module ─────────────────▶ one rule for where code lives; modules sized for readers
 two homes: scope or type ──────▶ every lookup goes to one place; Resolve and Infer split cleanly
 declarations are the contract ─▶ interfaces from headers, plus inferred requirements; early cutoff unless those change
 no import cycles ──────────────▶ a build graph, checked in parallel
 pure compiler passes ──────────▶ a cache you can trust; the daemon is just a cache
 uses Build (no Net/Clock/Env) ──▶ hermetic build scripts, enforced by types
 deterministic simulation tests ─▶ cached test results
```

This is the idea behind simulation and replay at runtime, applied to the compiler and the build. Purity plus content addressing means you compute something once and trust it everywhere.

---

## Roadmap

Stage numbers match the [README roadmap](README.md#roadmap).

| When | What |
|---|---|
| **Today** (stages 5a, 5b, 6, 7) | Files as modules, `import`, `pub`, `opaque`, lookup through types (constructors shared between types, fields, methods), interface summaries in memory, the prelude as a module, `uses` on signatures, methods, associated functions and associated values under their type, structural error tags with payloads, named error sets in interfaces, the "two shapes" error, dependency types imported like other types, and public groups imported to run their tests. Every compiler pass is a pure function of its inputs |
| **Stage 5b, left over** | `dbg` |
| **Stage 13** | Packages (`ren.toml`, vendoring, `allow`, `internal/`), and `ren build` with a local content-addressed cache and `--verify` |
| **Stage 16** | Cached simulation-test results |
| **After 1.0** | `build.ren`, sandboxed tools, remote cache and execution |

---

## Open questions

- Should modules be able to re-export imported types (`pub import`)? We're leaning no until a real need shows up.
- How do vendored dependencies get updated? Probably `ren deps update json --from <git url>`.
- Where does the boundary between the prelude and `std` sit? `Map` and `Set` are in the prelude, but `async.par_map` isn't. The test should be what nearly every module needs.

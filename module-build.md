# Modules & Builds

**Every name has one home. Every build is a lookup.**

This doc covers how Ren code is organized into files and packages, how names are found, and how `ren build` turns all of it into binaries. The two halves depend on each other. The module rules are what make the build fast and trustworthy, and the build is the reason the module rules look the way they do.

> **Status:** design. Constructor sharing (`Light.Red` vs `Suit.Red`) works today. Everything else is planned; see [Roadmap](#roadmap).

---

## The short version

```
 a file is a module            shop/billing/stripe.ren  →  `shop/billing/stripe`
 imports are explicit          import shop/billing/stripe      → stripe.charge(...)
 values are always qualified   you can always see where a call comes from
 no wildcards, no cycles       nothing found behind your back
 private unless `pub`          internal/ for package-private
 constructors belong to types  Red when it's obvious, Light.Red when it isn't
 builds are pure functions     same inputs, same outputs, cached forever
```

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

### Imports say exactly where things come from

```ren
import shop/billing/stripe              // stripe.charge(...)
import json/decode as jd                // jd.parse(...)
import shop/plan.{Plan, User}           // types, unqualified

pub fn checkout(u: User) -> Receipt ! PaymentFailed
    uses stripe.Client =
  try stripe.charge(u.id, price(u.plan))
```

- **Values are always qualified.** You'll read `stripe.charge`, never a bare `charge` that could have come from anywhere.
- **Types can be unqualified**, because `fn f(u: shop_plan.User)` would make every signature unreadable.
- **There are no wildcard imports.** `import x.{*}` doesn't exist.
- **Unused imports are an error**, with a fix that deletes them.
- **The keyword is `import`, not `use`,** so it can never be confused with `uses`. One is about modules, the other is about capabilities.

### No import cycles

```
error: import cycle: billing/stripe → billing/invoice → billing/stripe
   ┌─ src/billing/invoice.ren:1:1
 1 │ import shop/billing/stripe
   │ ^^^^^^^^^^^^^^^^^^^^^^^^^^
   help: move what both modules need into a third module that both can import
```

Banning cycles is what gives the compiler a dependency order. That order is what lets it check modules in parallel and skip the ones that haven't changed.

### Private unless `pub`

```ren
pub type User = { id: UserId, plan: Plan }       // type and fields exported
pub type UserId = opaque u64                     // name exported, representation hidden
pub fn load(id: UserId) -> User ! NotFound ...   // exported
fn helper() = ...                                // this module only
```

There are two levels and no third keyword. For "shared inside my package but not with my users," put the module under `internal/`, the way Go does.

### Constructors belong to their type

Two types can use the same constructor name:

```ren
type Light = Red | Yellow | Green
type Suit  = Red | Black
```

You write the bare name when it's obvious and the qualified name when it isn't:

```ren
fn next(l: Light) -> Light =
  match l
    Red    => Green           // obviously a Light: the other arms say so
    Yellow => Light.Red       // an expression with no context: qualify it
    Green  => Yellow
```

When it's ambiguous, Ren asks you rather than guessing:

```
error: `Red` could be `Light.Red` or `Suit.Red`
  ┌─ test.ren:4:19
4 │ fn main() = print(Red)
  │                   ^^^
  help: write `Light.Red`, naming the type you mean
```

The rule has three steps:
1. Use the expected type if one is known (match arms, annotations, parameters).
2. Otherwise, if only one visible type has that constructor, use it.
3. Otherwise, it's an error with a suggested fix.

Two libraries can both define `Error`, and the prelude doesn't reserve `Some` and `None` everywhere.

### Error tags only have to agree where they meet

Error tags are structural, like OCaml's polymorphic variants. You don't declare them; you just `fail NotFound`. Two libraries can use the same tag name with different payloads:

```ren
// http                                       // mutex
fn fetch(u: Url) -> Bytes ! Timeout(ms: Int)  fn lock() -> Lock ! Timeout
```

That only becomes a problem if one function's errors would contain both shapes:

```
error: `Timeout` has two shapes here
   = from `http.fetch`:  Timeout(ms: Int)
   = from `mutex.lock`:  Timeout
   help: handle one and rename it:  try mutex.lock() catch Timeout => fail LockTimeout
```

Adding a dependency can never break code that doesn't touch it.

### Everything else follows the same pattern

- **Dependency types are ordinary types.** `import shop/db.{Users}` followed by `uses Users` gives you `Users.get(id)`.
- **`ops` live next to their type,** in the same module. Operator lookup goes to exactly one place, and orphan instances can't exist.
- **Naming is enforced:** `UpperCamel` for types and constructors, `snake_case` for everything else. That's also how the parser tells `Plan.Free` (a constructor) from `user.plan` (a field) without looking anything up.

### A small, fixed prelude

| Kind | Always available |
|---|---|
| Types | `Int` `Bool` `Str` `Unit` `Option` `Result` `List` `Array` `Map` `Set` |
| Constructors | `Some` `None` `Ok` `Err` |
| Dependencies | `Io` `Net` `Alloc` `Async` `Unsafe` `Clock` `Random` |
| Functions | `print` `dbg` `assert` |

**`print` uses `Io`.** It's an ordinary function, so calling it from code that doesn't declare `Io` is an error. Otherwise any pure function could quietly reach the outside world, and simulation and replay would stop being trustworthy.

For debugging there's **`dbg(x)`**, which works anywhere. It prints the value with its source location, is compiled out of release builds, and is rejected by `ren test --ci`, so it can't get committed.

### Packages

```toml
# ren.toml
name = "shop"

[deps]
json   = { path = "deps/json" }
stripe = { path = "deps/stripe", allow = ["Net", "Alloc"] }
```

- **Dependencies are vendored source.** There's no registry and no lockfile, because a dependency is identified by the hash of its contents.
- **`allow` lists the capabilities a dependency may use.** If an update makes `json` reach for `Net`, your build fails and tells you exactly where:

```
error: dependency `json` uses a capability it isn't allowed
   = json 2.4.0: `decode.parse` now uses `Net`
     via: parse → fetch_schema → Net.get   (deps/json/schema.ren:41)
   help: pin the previous version, or add "Net" to `allow` for json
```

### Interface summaries

For every module, the compiler generates a summary of its public interface: types, signatures, error sets, `uses`, and `ops`. Modules that import it read only that summary, never its source.

You never write a summary by hand, so there's no second file to keep in sync the way OCaml's `.mli` files require. Inference never crosses a module boundary, which is why private helpers can skip annotations while public functions spell out their contract.

---

## Part 2: Builds

> Inspired by jade's [*The postmodern build system*](https://jade.fyi/blog/the-postmodern-build-system/).

### The problem

Build systems can't trust compilers. Compilers keep their own private incremental state, so build tools can only cache whole compiler runs. Your unit of reuse ends up being a whole crate or a whole derivation. As jade puts it: *"our problem build systems become the compilers."*

### Ren's answer

Ren owns its compiler, so every step of compilation can be **a pure function of content-hashed inputs.** Caching happens inside the compiler, at the level of modules and functions.

```
 file bytes ──parse──▶ AST ──check(import summaries)──▶ typed module + summary
                                                               │
                                     summary unchanged? stop here
                                                               ▼
                                      codegen ──▶ C ──zig cc──▶ .o ──link──▶ binary
```

| | Conventional | Ren |
|---|---|---|
| The compiler | an opaque, stateful process | pure functions over hashes |
| What's cached | whole compiler runs | modules and functions |
| Hermetic because | an OS sandbox | the type system (no `Net`, `Clock`, `Env`) |
| Incremental means | diffing against the last build | looking up content |
| A long-running daemon | a trade-off with trust | just a cache |

**Trustworthy incremental builds come from purity and content addressing, not from rebuilding from scratch.**

### What you get

**Nothing to clean, nothing stale.** Results live in a content-addressed store keyed only by input hashes. There are no timestamps and no "last build." Every branch, worktree, CI run, and teammate shares the same results, and a fresh checkout is always correct.

**Early cutoff.** If you change a function's body without changing its signature, the module's summary stays the same, so nothing that imports it gets rechecked.

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
  let api = codegen_api(Json.parse(schema))            // pure Ren, cached per function
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
A simulation test is a pure function of the code plus a seed, so its result can be cached. Tests that use real `Net` or `Io` can't be cached, and you can see that from their `uses`.

**Watch mode and the LSP for free.** They hold the same cache in memory. A persistent process is as trustworthy as a clean build, so you don't have to choose between a fast daemon and correct results.

**Shared and remote, later.** The store holds pure results over blobs, so CI can fill a shared cache that developers read from, and steps can run on other machines (via the Bazel Remote Build Execution protocol). Remote results get verified like local ones.

### The fine print

- **The compiler must be deterministic, forever.** No output may depend on hash-table iteration order, scheduling, timestamps, or paths.
- **Cache keys must be complete:** compiler version, target, flags, and the pinned `zig cc` hash. A missing input is a correctness bug.
- **Release builds are coarser.** Cross-module specialization and profile-guided optimization need whole-program information, so release links are less incremental than debug builds. They're still correct, just slower to rebuild.

---

## How it all fits

```
 file = module ─────────────────▶ the unit of caching
 no import cycles ──────────────▶ a build graph, checked in parallel
 generated summaries ───────────▶ early cutoff
 pure compiler passes ──────────▶ a cache you can trust; the daemon is just a cache
 uses Build (no Net/Clock/Env) ──▶ hermetic build scripts, enforced by types
 deterministic simulation tests ─▶ cached test results
```

This is the idea behind simulation and replay at runtime, applied to the compiler and the build. Purity plus content addressing means you compute something once and trust it everywhere.

---

## Roadmap

| When | What |
|---|---|
| **Today** | Constructors shared between types, with `Type.Ctor` qualification. Rule: every compiler pass is a pure function of its inputs |
| **Stage 3** | Modules, imports, visibility, interface summaries, constructor resolution by expected type |
| **Stage 5** | Structural error tags |
| **Stage 6** | `print` uses `Io`, `dbg` |
| **Stage 9** | `ren build` with a local content-addressed cache and `--verify` |
| **Stage 13** | Cached simulation-test results |
| **After 1.0** | `build.ren`, sandboxed tools, remote cache and execution |

---

## Open questions

- Should modules be able to re-export imported types (`pub import`)? We're leaning no until a real need shows up.
- How do vendored dependencies get updated? Probably `ren deps update json --from <git url>`.
- Should `billing.Plan.Free` work without importing `Plan`? It's probably needed, but it's three segments long.

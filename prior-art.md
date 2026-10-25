# Prior art: ownership, reuse, and specialization

Research notes for Ren, 2026-10-25.

This report examines Perceus reference counting, opportunistic mutation, constructor reuse, functional but in-place programming, lambda set specialization, and their implications for Ren. It draws on the Koka, Lean, Roc, and Morphic implementations and the papers linked below.

The central finding is that functional value semantics, inferred ownership, storage reuse, and specialization of higher-order functions reinforce each other. Allocation freedom, low reference-count overhead, bounded stack use, and bounded retained memory are nevertheless separate properties. Each needs its own argument.

Examples marked `text` are explanatory pseudocode, not proposed or implemented Ren syntax. Ren's README describes both implemented interpreter behavior and future language guarantees; the recommendations here do not establish that those guarantees are implemented.

## 1. Values and storage are different things

Consider a functional update:

```text
updated = set(tree, key, value)
```

The semantic promise is that independently observable old values remain unchanged. It does not require fresh storage for every operation.

```text
updated = set(tree, key, value)
return updated
```

If this consumes the final usable reference to `tree`, its storage may be reusable. In contrast:

```text
updated = set(tree, key, value)
return (tree, updated)
```

The old value remains observable. The implementation must preserve it, typically by copying changed portions and sharing unchanged portions.

This distinction supports Ren's value semantics for `var` and `inout`: mutation syntax need not expose mutable aliases. Its efficient implementation still depends on precise rules for ownership, borrowing, and uniqueness.

Two questions must remain distinct:

1. Does this function own a reference?
2. Does this allocation have other owners?

**Owned does not mean unique.** Ownership permits transferring or releasing a reference. Uniqueness permits stronger operations on the allocation itself, subject to any outstanding borrow restrictions.

## 2. Perceus: make ownership accounting explicit

Perceus inserts precise reference-count operations into a functional core with explicit control flow. Its formal foundation is a linear resource calculus, although ordinary source programs need not use linear syntax. References move between expressions; duplication and disposal become explicit internal operations. The garbage-free theorem applies to the relevant cycle-free core model, not arbitrary mutable cycles or allocator caches. [Perceus paper][perceus]

Compare these programs:

```text
a = makeList()
b = transform(a)
return b
```

```text
a = makeList()
b = transform(a)
return (a, b)
```

A conceptual ownership lowering is:

```text
// Final use: transfer the existing ownership.
b = transform(move a)

// Continued use: give the callee another ownership reference.
b = transform(dup(a))
return (move a, move b)
```

`dup` acquires a reference; it does not immediately copy the object graph. Avoiding unnecessary duplication matters twice: it saves RC traffic and preserves opportunities to discover uniqueness inside the callee.

Retaining a reference until lexical scope exit can obscure those opportunities. Last-use reasoning lets the compiler transfer or release it sooner.

### From a functional constructor to a reused cell

Take a list of machine integers and a borrowed, nonallocating callback:

```text
map(xs, f):
  match xs:
    Nil         -> Nil
    Cons(x, xx) -> Cons(f(x), map(xx, f))
```

One explanatory lowering is:

```text
map(xs, borrow f):
  match xs:
    Nil -> Nil
    Cons(x, tail):
      if unique(xs):
        token = detachShellAndMoveFields(xs)
        // Transfer the fields; retain the empty outer cell.
      else:
        dup(tail)
        drop(xs)
        token = None
        // Other owners still need the original node.

      y  = f(x)
      ys = map(tail, f)
      return Cons@token(y, ys)
```

`Cons@token` initializes compatible retained storage when available and allocates otherwise. This pseudocode abstracts compiler bookkeeping; `detachShellAndMoveFields` is not a runtime API.

Several optimizations cooperate:

| Stage | Purpose |
|---|---|
| Precise RC insertion | Establish required ownership transfers, duplications, and drops |
| Drop specialization | Expose disposal operations using known constructor layouts |
| RC cancellation | Transfer fields instead of incrementing and immediately decrementing them |
| Constructor reuse | Keep a dead outer allocation for a subsequent constructor |
| Reuse specialization | Avoid stores to fields that already contain the desired values |

Current Koka separates precise RC, constructor reuse, and selective reuse in its C backend. Its general runtime reuse operation releases children and retains the shell on the unique path; specialized generated code can eliminate redundant child operations. Shared storage produces a null reuse token. Koka encodes local uniqueness as RC zero, rather than the conceptual count of one. [Koka pipeline][koka-pipeline], [runtime reuse][koka-reuse]

### Uniqueness is local to an allocation

```text
root ──> Node(left, right)
                    ↑
anotherOwner ────────┘
```

The root may be unique while its right subtree is shared. Reusing the root does not authorize mutating all descendants. Each relevant allocation needs its own safety argument.

This supports efficient persistent trees: reuse unique nodes, copy shared nodes along an updated path, and share unchanged branches. It also explains why source variable counts are not a sufficient model of RC: inferred borrows can provide access without creating another owner.

## 3. Borrowing and lifetimes can remain internal

An inspecting function often needs access without ownership:

```text
n  = length(xs)      // borrow; caller keeps xs alive
ys = transform(xs)   // transfer ownership at last use
return (n, ys)
```

Borrowing can avoid creating an owner that would immediately be released. Lean performs borrow inference before explicit RC insertion, then expands reset/reuse and coalesces RC operations. [Lean pass pipeline][lean-passes]

Morphic's 2026 paper, *Fully-Automatic Type Inference for Borrows with Lifetimes*, directly addresses the desire to avoid lifetime annotations. It infers borrows and lifetimes in a pure functional language, introducing RC operations when needed. The evaluation reports 75–100% fewer increments on benchmarks having baseline increments and a 1.48× geometric-mean speedup overall. These are measured results for that benchmark suite, not universal guarantees. [Authors' description][borrows]

Morphic's implementation has explicit mode, obligation, and RC annotation stages, followed by an internal borrow type check. Its RC insertion distinguishes ownership moves from duplication using inferred lifetime information. [Morphic memory pipeline][morphic-backend]

For Ren, the useful distinction is:

> No user-written lifetime parameters does not imply no compiler lifetime analysis.

Functional semantics make inference substantially more tractable. The same result does not automatically cover unrestricted mutable references, raw pointers, escaping arena objects, or foreign code.

### Fewer reference-count operations can retain more memory

Consider converting a list into a tree. An owned traversal can release list nodes progressively. A borrowed traversal may keep the complete list alive while allocating the tree.

Reuse has a related cost: retaining a dead shell for future reconstruction delays reclamation. Drop-guided reuse bounds the extra retained storage by a constant times evaluation-context depth, rather than an unconditional constant. Recursive depth still matters, even if a backend later eliminates physical stack frames. The frame-limited reuse paper also explains why borrowing need not preserve garbage freedom. [Frame-limited reuse, §4][frame-reuse]

Ren should distinguish at least:

- allocation count;
- RC operation count;
- peak retained memory;
- maximum call-stack depth;
- work performed by a drop, including recursive destruction.

An optimization improving one metric does not prove the others improve.

## 4. Functional but in-place and fully in-place

List reversal demonstrates conservation of storage:

```text
reverse(xs, acc):
  match xs:
    Nil         -> acc
    Cons(x, xx) -> reverse(xx, Cons(x, acc))
```

Each step consumes a node and produces a compatible node. With suitable unique input, this can become a loop that rewires links.

A stronger example uses a zipper:

```text
Tree = Empty | Node(left, value, right)

Context =
  Done
  | CameFromLeft(parent, value, right)
  | CameFromRight(left, value, parent)

descendLeft(Node(left, value, right), context):
  return (left, CameFromLeft(context, value, right))
```

The consumed tree node and the new context frame each have three fields. With compatible layouts, the old node can become the frame. On the way back up, the frame becomes a tree node again:

```text
tree node → traversal context → rebuilt tree node
```

The FIP work formalizes credits for concrete reusable cells of particular sizes. Its restrictions establish no allocation/deallocation and constant stack use under the relevant uniqueness assumptions. FBIP is less restrictive: it permits unbounded stack use and deallocation. Constant allocation credits extend the model to operations such as insertion. [FIP paper][fip]

These credits represent actual reusable cells, not fungible byte budgets. Two small cells cannot automatically become one larger cell.

### The continuation is data that can occupy existing storage

During a recursive tree traversal, unfinished work has to live somewhere:

```text
After the left subtree finishes:
  process the right subtree
  rebuild the parent
```

That work can be represented by a machine stack frame, a closure, or a tagged context constructor. Defunctionalizing the continuation makes its fields explicit. When its representation fits consumed input storage, a zipper can avoid both fresh continuation allocation and growing call-stack usage.

This requires an appropriate transformation and representation; merely rewriting recursion into continuation-passing style does not establish allocation freedom.

The practical design pattern is to ask both:

1. What information must survive this step?
2. Which consumed allocation can carry that information?

## 5. Lambda set specialization

The Princeton link is *Better Defunctionalization through Lambda Set Specialization* (PLDI 2023). LSS tracks possible lambda identities through a polymorphic type system, allowing specialization of higher-order code to be treated as monomorphization. [Authors' description][lss]

A conventional closure is approximately a code pointer plus an environment. Consider:

```text
makeOperation(flag, amount):
  if flag:
    return x => x + amount
  else:
    return x => x * amount
```

There are arbitrarily many possible captured amounts, but only two pieces of lambda code. A defunctionalized representation is:

```text
Operation = Add(amount) | Multiply(amount)

apply(operation, x):
  match operation:
    Add(amount)      -> x + amount
    Multiply(amount) -> x * amount
```

A higher-order helper can specialize for these representations:

```text
twice(f, x) = f(f(x))

twiceAdd(amount, x) = (x + amount) + amount
twiceMultiply(factor, x) = (x * factor) * factor
```

Captured values remain runtime data. Known lambda identity does not imply compile-time-known captures. Multiple possible lambdas can retain tag dispatch; a singleton representation can simplify further.

Morphic caches specialized instances parameterized by function representations. Its lowering builds variants for possible function cases and dispatch functions with calls to known lambda bodies. This directly supports the worked example above. [Specialization implementation][morphic-specialize], [closure lowering][morphic-lower]

### Limits

- Recursive closure environments can require indirection.
- Multiple lambda cases can require runtime branches.
- Specialization increases code size and compilation work.
- Erased interfaces, separate compilation, and dynamic linking need explicit treatment.
- Removing indirect calls does not itself prove fusion, no allocation, or no RC.

Roc's implementers describe related challenges involving recursive lambda sets, closure layouts, and typeclass specialization. Their WITS presentation is useful implementation context, rather than a statement that every compiler revision has identical behavior. [Roc WITS presentation][roc-lss]

## 6. Why specialization and ownership reinforce each other

Compare an opaque callback with a known specialized body:

```text
result = unknownCallback(state)
result = updateCounter(state)
```

The latter can expose whether the callback borrows, consumes, duplicates, or retains its argument. That creates opportunities for the following chain:

```text
known lambda
  → specialized body
  → more precise ownership analysis
  → fewer unnecessary owners
  → more mutation and reuse opportunities
```

This is a design synthesis, not a guarantee that every compiler realizes every step.

Morphic explicitly combines lambda specialization, mutation optimization, and borrow-based RC. Its published sieve example demonstrates the intended result: iterator composition and logically immutable array updates compiling to a loop with in-place updates. [Morphic project][morphic]

FIP and LSS also share a deeper connection: both make control flow inspectable by turning functions or continuations into ordinary data. FIP can then exploit the representation to reuse storage.

## 7. Shared design patterns

| Pattern | What it exposes |
|---|---|
| Consume a value and return its successor | Ownership transfer that may support mutation |
| Inspect first, consume at last use | Borrowing without unnecessary additional owners |
| Match and reconstruct | Constructor reuse opportunities |
| Preserve unchanged fields and subtrees | Fewer stores, less RC, structural sharing |
| Carry evolving state through a fold | A sequence of successor states |
| Represent continuations as tagged data | Explicit control flow and layouts |
| Specialize higher-order helpers | Known callback code and capture representations |
| Infer rich internal types | Precision without equivalent source annotation burden |
| Check resource contracts | Guarantees stronger than opportunistic optimization |

For example:

```text
finalState = fold(events, initialState, applyEvent)
```

may repeatedly update unique state storage. In contrast:

```text
history = scan(events, initialState, applyEvent)
```

retains intermediate values. Preserving history makes copying or persistent sharing semantically necessary.

The implementations share an architectural pattern: introduce explicit resource operations in the compiler IR and optimize them with language-specific knowledge. They do not simply rely on a general backend to rediscover all ownership semantics.

They are not identical implementations of Perceus:

| System | Particularly useful prior art for Ren |
|---|---|
| Koka | Precise RC, constructor reuse, effects, FBIP/FIP checking |
| Lean | Reset/reuse, borrow inference, RC coalescing, exclusive array updates |
| Roc | Ownership analysis, unique collection operations, host allocator boundary, lambda-set implementation experience |
| Morphic | LSS combined with mutation optimization and inferred borrows/lifetimes |

## 8. Implications for Ren's current design

These are recommendations and open proof obligations, not established results about Ren's implementation. See the existing [memory and allocation design](README.md#allocation-model) and [dependency design](deps.md).

### Ordinary inference and strict contracts serve different users

For ordinary functional code, infer ownership and borrow lifetimes, reuse unique objects, and allocate when sharing prevents reuse.

For strict hot paths, establish stronger preconditions. A dynamic uniqueness check offers:

```text
unique → reuse
shared → allocate
```

It cannot justify an unconditional absence of `Alloc` unless the shared case is ruled out or handled without allocation.

Ren already distinguishes borrowed parameters, `inout`, and `unique`. Charging the caller for making an `inout` argument unshared makes the callee's contract easier to reason about. That boundary needs a precise definition for nested fields, shared descendants, slices, and capacity growth.

### Define allocation effects after memory lowering

Ren's stated plan to insert RC, copies, and frees before checking their dependencies fits this research well. Resource checks must account for boxing, closure environments, exceptional exits, destructors, and fallback paths, not just explicit source constructors.

The README deliberately charges freeing to `Alloc`. Preserve that documented meaning: a Ren function without `Alloc` promises more than merely making no fresh allocation. Internally, still distinguish allocation, deallocation, RC traffic, and stack use for diagnostics and analysis.

A compiler should explain why a contract fails, such as an inserted copy caused by retained sharing, rather than only reporting that optimization failed.

### Arena escape copying is a lifetime policy

Effects answer which allocator an operation may use. They do not establish how long its results remain valid.

Ren chooses to copy arena-backed values out at identified escape boundaries. That is a concrete alternative to exposing region lifetimes, but it creates obligations:

- The escape boundary list must remain complete as language features grow.
- Promotion must preserve sharing where promised.
- The destination allocator and the cost/failure of promotion must be specified.
- Borrowed accesses must end before reset or destructive forwarding.
- Nested regions, handler state, tracing, task completion, and deferred reclamation must compose with the policy.

These are validation questions for Ren's chosen design, not a recommendation to replace it with Rust-style annotations.

RC alone cannot make resetting an arena safe while live pointers into it remain. Reuse also retains the original allocation's provenance: installing a different allocator handler does not relocate existing objects.

### Higher-order dependency calls are a specialization opportunity

Known handler implementations can expose direct calls and more precise ownership behavior. Ren's specialization budget is therefore important: predictable code size and a defined fallback are part of the language implementation, not incidental tuning.

Transparent, nonescaping callbacks offer an independent route to stack-resident environments. LSS can further improve dispatch and representation. These are complementary arguments; neither establishes every resource property of the other.

One-shot continuations fit ownership transfer naturally. Fibers, queues, escaping callbacks, and retained or replayable continuations introduce storage and sharing that must be accounted for explicitly. Structured concurrency bounds task lifetimes but does not by itself eliminate task or continuation allocation.

### Keep the internal facts distinct

```text
Effects:       what operations may happen?
Lambda sets:   what code may run?
Ownership:     who preserves or releases a value?
Lifetimes:     how long is borrowed access valid?
Reuse credits: what existing storage is available?
Provenance:    which allocator or region owns the storage?
```

Most of these facts can remain inferred and internal. Expose the ones users need to state and diagnose meaningful resource guarantees.

## 9. Research scope and source snapshots

The research combined paper reading and source inspection. It was not a comparative performance benchmark or a full build/test of all four compilers. A small Koka runtime probe separately exercised unique reuse and shared fallback under address/undefined-behavior sanitizers; it does not validate a complete compiler pipeline or establish performance results.

The Perceus, frame-limited reuse, and FIP PDFs were available for inspection. The LSS publisher PDF could not be retrieved; that discussion uses the authors' description and Morphic's specialization/lowering source. The 2026 borrowing paper's reported results are taken from the authors' abstract, supplemented by source inspection, rather than an independent reproduction.

| Repository | Inspected commit |
|---|---|
| [Koka](https://github.com/koka-lang/koka) | `198fc3bbd158246e7604210ee6692ee72c2d9c50` |
| [Lean](https://github.com/leanprover/lean4) | `9f0f86c7f799b1f7d892886b4bb70661975ca492` |
| [Roc](https://github.com/roc-lang/roc) | `26436de4894be07d5440ea1c69903fd76362e375` |
| [Morphic](https://github.com/morphic-lang/morphic) | `ffe4a080efefe76316a7dd87e55d7550b48cf0d7` |

Useful reading order: Perceus for ownership accounting; frame-limited reuse for space tradeoffs; FIP for resource contracts and zippers; LSS for higher-order representation; automatic borrowing for reducing annotation and RC overhead.

[perceus]: https://www.microsoft.com/en-us/research/wp-content/uploads/2020/11/perceus-tr-v4.pdf
[frame-reuse]: https://www.microsoft.com/en-us/research/wp-content/uploads/2023/07/flreuse.pdf
[fip]: https://webspace.science.uu.nl/~swier004/publications/2023-icfp.pdf
[lss]: https://www.cs.princeton.edu/~mpmilano/publication/lss/
[borrows]: https://www.cs.princeton.edu/~mpmilano/publication/fully-automatic-type-inference/
[koka-pipeline]: https://github.com/koka-lang/koka/blob/198fc3bbd158246e7604210ee6692ee72c2d9c50/src/Backend/C/FromCore.hs#L90
[koka-reuse]: https://github.com/koka-lang/koka/blob/198fc3bbd158246e7604210ee6692ee72c2d9c50/kklib/src/refcount.c#L217
[lean-passes]: https://github.com/leanprover/lean4/blob/9f0f86c7f799b1f7d892886b4bb70661975ca492/src/Lean/Compiler/LCNF/Passes.lean#L143
[morphic]: https://morphic-lang.org/
[morphic-specialize]: https://github.com/morphic-lang/morphic/blob/ffe4a080efefe76316a7dd87e55d7550b48cf0d7/crates/morphic_frontend/src/closure_specialize.rs
[morphic-lower]: https://github.com/morphic-lang/morphic/blob/ffe4a080efefe76316a7dd87e55d7550b48cf0d7/crates/morphic_frontend/src/lower_closures.rs#L291
[morphic-backend]: https://github.com/morphic-lang/morphic/blob/ffe4a080efefe76316a7dd87e55d7550b48cf0d7/crates/morphic_backend/src/lib.rs
[roc-lss]: https://popl24.sigplan.org/details/wits-2024-papers/3/Type-directed-defunctionalization-in-the-presence-of-typeclasses-and-monomorphization

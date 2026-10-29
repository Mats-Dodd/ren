# E2: prototype of "a pipeline is a block" and "a gen fn call follows its signature"

Worktree: `/Users/matthewdodd/Documents/code/ren/.claude/worktrees/wf_350e7dc3-1f2-2`, not committed.
Diff: `streams-exp/e2/prototype.diff`. Programs: `streams-exp/e2/s1/` (step 1), `streams-exp/e2/s2/` (step 2), `streams-exp/e2/hand/` (desugared by hand, before any compiler change). Every output is in `streams-exp/e2/results.txt`.

## Verdict

- **Step 1 holds.** A chain written as the literal block the compiler would write is checked by today's checker with no changes. All three soundness counterexamples are rejected by checks that exist today, and so are "chosen with `if`", "stored in a record" and "returned". Two other cases behave the same way: a concurrent block that steps a pipeline is rejected, and stepping the source between a pipeline's steps is allowed.
- **Step 2 holds in the interpreter.** One-shot fibers (OCaml 5 `Effect.Deep`) run effectful and block-taking generators. A replay cursor with a one-entry cache runs pure ones, and a copy is an honest fork. The runtime part is **118 lines in eval.ml**. With intrinsics and the prelude it's about 190.
- **"About 450 lines" is right for the runtime and wrong for the whole feature.** The spike is 875 lines and still has shortcuts (below). An honest estimate for the full feature in the interpreter path is **about 1,300–1,900 lines**. That's well under a state machine plus everything around it, but it isn't 450.
- **Four places where it doesn't simply fall out:** stage names collide with user methods, a cursor where a block is expected needs a rule, "pure" has to come from the inferred row and not the block's type, and two `&r` heads in one call are legal today.

## How it was built

The spike rewrites the parsed tree (new `lib/syntax/streams.ml`) into ordinary Ren. Resolve, inference, exclusivity, lowering and Core Lint then run unchanged on exactly the code the compiler would write. That's the right test of "falls out of existing rules", but the recognition is done by spelling, not by type (see the shortcuts).

- `&r.map(f).select(p).take(n)` becomes `fn() => try PULL`. `take`'s counter becomes a hidden `var $taken` declared just before the statement, and literal stage blocks are inlined (`{ let x = item; body }`).
- `for x in CHAIN` is fused into a `while` over PULL, with no block at all. Because of that, `ren build` compiled and ran `s1/ok2.ren` natively with no backend work.
- `for x in p`, where `p` is a let-bound pipeline or a parameter written `fn() -> ..`, becomes a `while` over `p()`.
- `gen fn g(..) -> T` becomes `fn g(.., $w: GenYield<T>)`. `yield e` becomes `$gen_yield(e, $w)`, and `yield from g(..)` becomes `g(.., $w)`, a direct call on the same fiber.
- A pure gen fn's call becomes `$gen_cursor(fn($w) => g(args, $w))`, of type `Gen<T>`, a cursor with a built-in `next`.
- Any other gen fn's call becomes a hidden `var $frame = $gen_frame()` plus the block `fn() => $gen_resume(&$frame, fn($w) => try g(args, $w))`.
- After a `for` over a temporary pipeline, `$gen_close(&$frame)` discontinues the fiber with `Cancelled`, so the generator's `finally` sees `Err(Cancelled)`.

## Step 1: what fired (quoted)

| Case | Program | Existing check, its message |
|---|---|---|
| keep through a generic | `keep(ns.cursor().map(fn(x) => x + k))` | "a generic `T` can't be a block" |
| keep in a record | `Box { v: &r.take(2) }` | "a block can't be stored in a record" |
| return | `fn make(ns: Nums) = ns.cursor().take(2)` | "a block can't be returned" (also with `-> fn() -> Option<Int>` written) |
| drive (no generics) | `drive(c: fn() -> .., k: fn(fn() -> ..) -> Int) = try k(c)` | rule A: "`c`, a block parameter, can't be passed to `k`" |
| drive (generic) | `drive<C>(c: C, k: fn(C) -> Int)` | "a generic `C` can't be a block" |
| consume | `consume(xs.cursor().select(fn(x) => x < limit), &limit)` | "`limit` is read by this block while the call changes it … changed for the whole call" |
| chosen | `let p = if short then &r.take(1) else &r.take(2)` | `Let_chosen`: "`let` binds one block written right there", with help "choose inside one block" |
| concurrent | `Async.each([1, 2], fn(x) => print(p()))` | "`r` can't change in a block that runs on several tasks at once" |
| effectful gen fn's call | `fn later() = ticks(3)`, `Box { v: ticks(3) }` | "a block can't be returned", "a block can't be stored in a record" |

**What had to be new for step 1:** only the rewrite itself, plus 3 lines in `infer_expr.ml` so that a compiler-written `try` may cover nothing. Today a `try` over nothing is an error, and the compiler can't know where it's needed without types.

## Step 2: what works

- `s2/g1.ren`, pure `walk(t)`:
  - a recursive in-order walk using `yield from`;
  - `var d = c` forks (c: 0, 1; d: 2, 3; c: 2 again);
  - a `Gen<Int>` stored in a record field;
  - a chain over it: `walk(t).map(..).select(..).to_array()`.
- `s2/g2.ren`, the user stage `dedup_by<T, K>(src: fn() -> Option<T>, key: fn(T) -> K)`: looped over, chained after (`.select(..).take(2).to_array()`), and let-bound.
- `s2/g3.ren`, an effectful, failing generator (`! Bad uses Console`):
  - it runs lazily, interleaved with the consumer;
  - `for x in try ..` works;
  - a user `pairs` stage runs over a mapped generator;
  - `break` after 2 items stops production;
  - `Err(Bad(7))` passes through `select` and `for` into `attempt`.
- `s2/g4.ren`, `finally` in a gen fn: "finally: returned" when it ends normally, and "finally: stopped" (`Err(Cancelled)`) on `break`.
- `s2/g5.ren`, `yield` inside `with transaction()`: the full loop prints `commit`, and `break` prints `rollback`. This is the amendments' `orders_in_tx` case.

## What doesn't hold, or needed something new

1. **Stage names collide with user methods.** One existing test, test_ops "`b` is passed with `&` …" with `&b.take(Bag{..})`, now gets stage errors instead of its exclusivity error. Requiring the stage's arity fixed a second test, `&c.take()`. This is the amendments' "stage names are reserved" rule, made concrete. A type-directed version would only treat `take` as a stage on a type with `next`, but a cursor type with its own `take` would still need the rule.
2. **A value cursor where a block is expected is a type error.** `evens(upto(10))` gives "expected `fn() -> Option<Int>`, found `Gen<Int>`". `upto(10).map(fn(x) => x)` works around it. A real implementation needs a coercion, which alt-1 already listed ("a cursor where a pull is expected"). It's a new rule, not something that falls out.
3. **Purity can't be read from the block's type.** `sneaky` (`s2/r2.ren`) declares no `uses` but calls `print`. The spike made it a value cursor, and it ran. The `$gen_cursor` parameter's empty row didn't catch it, because of decision 5: a block finds its dependencies where it's written, so they aren't in its type. Choosing a value cursor or a pipeline has to look at the gen fn's own inferred `uses` and errors, and include it in the signature. That's cheap, but it's a type-directed rule. Without it, a stored value cursor could replay outside its `with`.
4. **Two `&r` heads in one call are legal today.** `both(&r.take(2), &r.take(2))` compiles and gives 5. That's sound (single task, each access at an instant) but surprising. Decision 2 says blocks passed to the same call don't conflict, so the amendments' "two heads conflict" sentence is genuinely new.
5. **Messages name hidden locals:** "`$taken28` can't change …", "`$frame45` …". These need a rewording pass ("the pipeline's state").
6. **Not built:**
   - closing a *named* pipeline at the end of its scope (only a `for` over a temporary closes);
   - closing on failure or cancel of the consumer;
   - re-checking uniqueness of a held `&` on resume;
   - `index` in `for i, x in pipeline`;
   - the native backend for gen fns ("`$gen_cursor` isn't in the native slice yet").
7. **A bug that was already there, found on the way:** `for x in job.rest` over a cursor held in a record field crashes lowering ("a field inference didn't find") on the base commit too (`s2/g1c.ren`).

## Tests

`dune build` is clean.

`dune test` has three diffs:
- test_ops: the stage-name collision (item 1).
- `examples/journal.t` and `test/test_journal.ml`: timing flakes under load (poll grouping of 5 ms against 40 ms, and 100 ms against 200 ms sleeps). Running `recipes.ren` twice per build reproduced the same flip on the unmodified base (`base 1: poll main/main:1 main/main:2`). These match the known "journal.t flakes under load" note.

No other test changed.

## Lines (`git diff --stat`, plus the new file)

| File | Added |
|---|---|
| lib/syntax/streams.ml (new: chain rewrite, for-over-pull, gen calls, close) | 616 (≈550 without comments) |
| lib/eval/eval.ml (fibers, frame, replay cursor, close) | 118 |
| lib/syntax/parser.ml (`gen fn`, `yield`, `yield from`, hook) | 65 |
| lib/core/prelude.ml (3 builtin types, 6 schemes) | 50 |
| lib/core/intrinsic.ml / .mli | 20 |
| lib/eval/builtins.ml | 4 |
| lib/sema/resolve.ml (`finally` in a gen fn) | 4 |
| lib/sema/infer_expr.ml (quiet `try`) | 3 |
| **Total** | **≈875** |

## Honest estimate of the full cost

The runtime (fibers, frames, replay, close) is about **200–300 lines** with scope and cancel closes. That part matches the 450 figure.

The spike's rewrite stands in for type-directed work that would replace it. Lines per piece:

| Piece | Lines |
|---|---|
| Chain recognition and composition in infer and lower, with hidden locals and real try placement | 500–800 |
| `for` over a block, sinks, `Let_chosen` for chains | 100–200 |
| `gen fn` / `yield` in parser, resolve, infer, with the value-or-pipeline choice from the inferred row | 200–300 |
| The four new rules above, plus messages | 150–250 |
| Tests | not counted |

That's **about 1,300–1,900 lines for the interpreter path**, consistent with alt-1's 1,150–2,100. Fusion in the native backend came free here, because the `for`-over-chain rewrite is plain loops. Native gen fns are separate work.

The core claim survives: nothing about exclusivity, escape or specialization needed a new mechanism. The extra lines are recognition, coercion, purity from the inferred row, and naming.

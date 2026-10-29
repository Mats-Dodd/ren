# E3 verification

**Verdict.** The models are fair, and every directional finding holds. The
headline that recursion through boxed `yield from` costs about 13× holds,
and the push numbers hold. Three numbers move:

1. **The frame-stack pull of W2 is 1.0–1.08×, not 1.46×.** The original
   model sends every child's entry through an extra switch round. The
   lowering a compiler would naturally emit runs the child's first
   `yield` at the `yield from` itself. That lowering is the new
   `pull-stack2`.
2. **Pulling both sides of `zip` (W4) costs 1.25×, not 1.14×.** Two
   separate runs confirmed it.
3. **"Faster than Rust on W1 and W5" isn't a streams result.** It comes
   from memchr. Rust's `split_terminator` uses core's portable memchr,
   while C calls libc's. Give Rust the same libc memchr and it runs at
   0.97× (W1) and 1.01× (W5).

The originals are untouched. Everything for this check is in `e3/verify/`.

## (a) Are the C models faithful?

- **Same work, same check.** In every workload, every variant does the
  same work and prints the same `check=`, in C, Rust and Go. measure.py
  found no mismatch in any of the three runs.
- **The hand, push and pull variants are fair to each other.** Each uses
  `ren_add` throughout and has the same data layout.
- **Push isn't flattered.** It is literally the generator body with the
  yield calling the body block, and the control-value protocol is kept.
  The stack check stays in the recursive twins.
- **Pull isn't a strawman.** The frame is a hidden local, `next` is a
  switch, and the pipeline is a block composed at the call site, as
  B+R lowers it.
- **The boxed `yield from` model is faithful to the draft.** streams.md
  says "the child cursor is kept as data, boxed like a recursive enum's
  field", and amendments.md says "box only recursive `yield from`". It
  uses the system malloc. A pooled allocator would land between
  `pull-reuse` (8.1×) and `pull-box`, so the O(depth) cost dominates
  either way.
- **One model is pessimistic: W2's `pull-stack`.** After a `yield from`
  pushes a child's frame, the model `continue`s back to the top of the
  loop and only yields `t.val` on the next resume. `pull-stack2` runs
  that first `yield` immediately instead. It uses the same frames, the
  same order and the same work, and it measures 1.08× under heavy load,
  with process cycles equal to the hand loop (839 against 845 Mcyc).
- **The W3 claim that fusion is a loop-shape artefact is confirmed.**
  `full-push2` is the same fusion, with `dedup_by`'s locals as plain
  locals instead of captured pointers, and it measures 1.02×. In
  `verify/asm/w3.s`, `full-push` keeps the `have` check (`cbz w11`) in
  the loop, and `full-push2` peels it out, as the hand loop does.
- **W5 is fine.** At about 23 ns per line, an indirect call per item
  doesn't show, so `passed`, `passed-ni` and `indirect` are all 1.02×.

## (b) Are the Rust and Go twins idiomatic and optimized?

- **Builds.** Rust is built with `--release`, opt-level 3 and one
  codegen unit, and its inputs go through `black_box`. Go uses a default
  `go build`, which optimizes. Neither is a debug build.
- **Idioms.** Both are idiomatic: Rust's iterator adapters, a user
  `Iterator` struct, explicit-stack and boxed walks, and push over
  `ControlFlow`; Go's `range`-over-func and `iter.Pull`.
- **One unfairness, on W1 and W5: memchr.** It's in Rust's string
  splitting, not its iterators (see the next point).
- **Overflow checks.** C checks every sum and Rust wraps. Turning Rust's
  checks on (`-C overflow-checks=on`) changed nothing: W3 0.96→0.99×,
  W4 0.95→0.94×, W2 push 0.86→0.90×.

## (c, d) Re-measured

Medians of 11 interleaved rounds. The ratio is against C hand; for W5
it's against C inline.

- **Main run:** load 3.92 at the start and 4.92 at the end. Absolute
  times are about 5–8% above the original's, so compare ratios.
- **W2 rerun** (with `pull-stack2`): load 5.6 to 7.5. Ratios only.
- **W4 C rerun:** load 7.5.

| Claim (original) | Verified | Holds? |
|---|---|---|
| W1 push 1.00, pull 1.00 | 1.00, 1.01 | yes |
| W1 pull with two calls not inlined, 1.24 | 1.22 | yes |
| W1 Rust 1.39 "loses on split_terminator" | 1.39; with libc memchr **0.97** | yes, and the cause is memchr |
| W2 push 0.98 | 1.00 | yes |
| W2 pull, boxed (the draft), 13.5 | 13.4 (13.0 in the rerun) | yes |
| W2 pull, box reused, 8.35 | 8.1 | yes |
| W2 pull, frame stack, 1.46 | 1.47 as modelled; **1.08 with the child's entry threaded** (`pull-stack2`) | **no, it's pessimistic** |
| W2 Rust boxed 15.9, Rust stack 0.96 | 15.4, 0.94 | yes |
| W2 Go push 1.63, Go `iter.Pull` 3.9 | 1.58, 3.85 | yes |
| W3 design 0.99, all pulled 1.04 | 1.01, 1.06 | yes |
| W3 full push 1.18 is "loop shape" | 1.22; the same fusion with plain locals **1.02** | yes, confirmed |
| W3 Go `iter.Pull` 10× | 9.9× | yes |
| W4 pull both 1.14 | **1.25** (1.25 again in the rerun) | **no, about 10% worse** |
| W4 push one side 1.05 | 1.09 (1.12 in the rerun) | roughly |
| W4 pull, zip block not inlined, 1.80 | 1.86 | yes |
| W4 Go 25× and 51× | 25.7×, 53× | yes |
| W5 passed, specialized or indirect, 1.02 | 1.02 for all three | yes |
| W5 Rust 1.38–1.50 | 1.38–1.51; with libc memchr **1.01** | the cause is memchr, not streams |

## What changes for the decisions

- **Decision 10.** E3's recommendation stands and gets stronger: push
  recursive producers natively, and when one must pull, lower
  `yield from` to a frame stack the consumer owns, never to boxes.
  Done properly, that stack costs about the same as the hand loop
  (1.0–1.08×), not 1.46×. So pulled recursion costs the programmer
  nothing they have to think about either. One condition: the lowering
  must run the child's entry inline at the `yield from`.
- **Decision 8.** Unchanged. Fusion through a `gen fn` buys nothing
  measurable here, and its one apparent cost was confirmed as a
  loop-shape artefact. Base push is still the guarantee that doesn't
  depend on clang inlining `next`.
- **`zip`.** Pulling two sides costs about 25% over a hand loop on items
  of about 1.5 ns, still far below Go's 25–53×. If anyone wants
  pushing one side as an optimization, it's worth about 13–15%.
- **Rust comparison.** Ren's model is level with Rust everywhere,
  within ±10%. It is not ahead on W1 or W5: that apparent lead was
  libc memchr against core's.

## Files (under `e3/verify/`)

| Path | What's in it |
|---|---|
| `c/w2.c` | adds `pull-stack2` |
| `c/w3.c` | adds `full-push2` |
| `c/w1.c`, `c/w4.c`, `c/common.h` | unchanged copies |
| `rust/src/main.rs` | adds `LibcLines`, `w1 libc` and `w5 libc` |
| `build.sh` | also builds `bin/e3-rust-oc`, Rust with overflow checks on |
| `measure.py` | adds the new rows |
| `results/e3.{txt,jsonl,summary.json,tables.md}` | the main run, all rows |
| `results/e3-w2*` | the W2 rerun, including `pull-stack2` |
| `results/e3-w4*` | the W4 C rerun |
| `asm/w3.s`, `asm/w2.s` | the asm checked above |

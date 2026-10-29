`ren build` compiles each program the native slice's subset
covers (compiler.md, "Native slice") to a debug binary, with its
statistics and under AddressSanitizer and UndefinedBehaviorSanitizer,
and each prints exactly what `ren run` prints, to stdout and to stderr,
and exits as it does. Each is built twice: with its counting placed
by Perceus, the default, and with the naive counting, `--rc naive`,
and the two print the same. The statistics say no object is still
alive when either ends. Mem Lint checks every program `ren build`
compiles, and its counting, path by path.

The sanitizers are clang's, so these builds compile with cc, not tcc,
which a debug build uses when it's found ("Debug builds with tcc",
below, compares those).

On Linux, AddressSanitizer moves frames to a stack of its own to catch
a use after return, which runs out before `overflow` reaches the
overflow panic, and checks for leaks, which a panic leaves alive on
purpose (the statistics count them); on macOS it does neither, and here
neither is asked for.

  $ export REN_CC=cc
  $ export REN_CFLAGS='-fsanitize=address,undefined'
  $ export ASAN_OPTIONS=detect_stack_use_after_return=0:detect_leaks=0
  $ same() {
  >   for rc in perceus naive; do
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    ren build --debug --stats --rc $rc "$f" -o ./native.bin &&
  >    { ./native.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    grep -v -e '^ren stats: ' -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >      -e '^False positive error reports may follow' \
  >      -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >      native.err > native.err2;
  >    if cmp -s native.out interp.out && cmp -s native.err2 interp.err &&
  >       cmp -s native.code interp.code
  >    then echo "$1, $rc: the same, $(cat native.code), $(grep -o 'objects live at exit [0-9]*' native.err)"
  >    else echo "$1, $rc: different"; diff native.out interp.out; diff native.err2 interp.err
  >    fi)
  >   done
  > }

The benchmarks of `bench`. `overflow` reaches the stack-overflow panic,
after which AddressSanitizer warns that it can't clean up a stack that
deep, which is left out. `values_panic` panics where objects are alive,
which a panic leaves as they are, and so do `swap_panic`, after a row
was moved out of its grid, `swap_order`, and `trmc_panic`, with the
cells a loop built where a recursion would have built none yet.
`sized_panic` panics storing a number too big for a `UInt8`, and
`loops_panic` indexing an array a block shrank, which bounds.ml leaves
checked, and `loops_short` in the checked one of a loop bounds.ml made
twice. `review_shrink` panics indexing an array a call
shrank under its loop's count, which bounds.ml leaves checked.

  $ for f in fib deep loop overflow frames tokens packed values values_panic swap swap_panic swap_order trmc trmc_panic sized sized_panic loops loops_panic loops_short review_arrays review_values review_lists review_shrink 10d/bits 10d/bits_panic 10d/generic 10d/cache 10d/aliases 10d/shapes 10d/router 10d/methods 10d/dispatch 10d/dispatch_mix 10d/dispatch_panic 10d/overany 10d/slices 10d/slices_panic 10d/slices_lent 10d/review_slices 10d/review_deps 11a/trywith 11a/alone 11a/alone_panic 11a/limit 11a/limit_panic data/update data/byname data/orpat data/orpat_strs data/variants data/variants_small data/variants_escape data/variants_reuse data/todo_panic data/shapes data/nested data/rows data/optional data/layout data/layout_walks data/layout_panic data/reuse_arms data/rows_objs data/rows_panic data/niche data/niche_walks data/niche_panic data/niche_reuse data/niche_join data/interp data/review_keys data/review_state data/review_state_panic data/review_todo_panic; do same $f.ren; done
  fib.ren, perceus: the same, exit 0, objects live at exit 0
  fib.ren, naive: the same, exit 0, objects live at exit 0
  deep.ren, perceus: the same, exit 0, objects live at exit 0
  deep.ren, naive: the same, exit 0, objects live at exit 0
  loop.ren, perceus: the same, exit 0, objects live at exit 0
  loop.ren, naive: the same, exit 0, objects live at exit 0
  overflow.ren, perceus: the same, exit 1, objects live at exit 0
  overflow.ren, naive: the same, exit 1, objects live at exit 0
  frames.ren, perceus: the same, exit 0, objects live at exit 0
  frames.ren, naive: the same, exit 0, objects live at exit 0
  tokens.ren, perceus: the same, exit 0, objects live at exit 0
  tokens.ren, naive: the same, exit 0, objects live at exit 0
  packed.ren, perceus: the same, exit 0, objects live at exit 0
  packed.ren, naive: the same, exit 0, objects live at exit 0
  values.ren, perceus: the same, exit 0, objects live at exit 0
  values.ren, naive: the same, exit 0, objects live at exit 0
  values_panic.ren, perceus: the same, exit 1, objects live at exit 4
  values_panic.ren, naive: the same, exit 1, objects live at exit 4
  swap.ren, perceus: the same, exit 0, objects live at exit 0
  swap.ren, naive: the same, exit 0, objects live at exit 0
  swap_panic.ren, perceus: the same, exit 1, objects live at exit 4
  swap_panic.ren, naive: the same, exit 1, objects live at exit 4
  swap_order.ren, perceus: the same, exit 1, objects live at exit 4
  swap_order.ren, naive: the same, exit 1, objects live at exit 4
  trmc.ren, perceus: the same, exit 0, objects live at exit 0
  trmc.ren, naive: the same, exit 0, objects live at exit 0
  trmc_panic.ren, perceus: the same, exit 1, objects live at exit 11
  trmc_panic.ren, naive: the same, exit 1, objects live at exit 1
  sized.ren, perceus: the same, exit 0, objects live at exit 0
  sized.ren, naive: the same, exit 0, objects live at exit 0
  sized_panic.ren, perceus: the same, exit 1, objects live at exit 2
  sized_panic.ren, naive: the same, exit 1, objects live at exit 2
  loops.ren, perceus: the same, exit 0, objects live at exit 0
  loops.ren, naive: the same, exit 0, objects live at exit 0
  loops_panic.ren, perceus: the same, exit 1, objects live at exit 3
  loops_panic.ren, naive: the same, exit 1, objects live at exit 4
  loops_short.ren, perceus: the same, exit 1, objects live at exit 6
  loops_short.ren, naive: the same, exit 1, objects live at exit 6
  review_arrays.ren, perceus: the same, exit 0, objects live at exit 0
  review_arrays.ren, naive: the same, exit 0, objects live at exit 0
  review_values.ren, perceus: the same, exit 0, objects live at exit 0
  review_values.ren, naive: the same, exit 0, objects live at exit 0
  review_lists.ren, perceus: the same, exit 0, objects live at exit 0
  review_lists.ren, naive: the same, exit 0, objects live at exit 0
  review_shrink.ren, perceus: the same, exit 1, objects live at exit 2
  review_shrink.ren, naive: the same, exit 1, objects live at exit 3
  10d/bits.ren, perceus: the same, exit 0, objects live at exit 0
  10d/bits.ren, naive: the same, exit 0, objects live at exit 0
  10d/bits_panic.ren, perceus: the same, exit 1, objects live at exit 1
  10d/bits_panic.ren, naive: the same, exit 1, objects live at exit 1
  10d/generic.ren, perceus: the same, exit 0, objects live at exit 0
  10d/generic.ren, naive: the same, exit 0, objects live at exit 0
  10d/cache.ren, perceus: the same, exit 0, objects live at exit 0
  10d/cache.ren, naive: the same, exit 0, objects live at exit 0
  10d/aliases.ren, perceus: the same, exit 0, objects live at exit 0
  10d/aliases.ren, naive: the same, exit 0, objects live at exit 0
  10d/shapes.ren, perceus: the same, exit 0, objects live at exit 0
  10d/shapes.ren, naive: the same, exit 0, objects live at exit 0
  10d/router.ren, perceus: the same, exit 0, objects live at exit 0
  10d/router.ren, naive: the same, exit 0, objects live at exit 0
  10d/methods.ren, perceus: the same, exit 0, objects live at exit 0
  10d/methods.ren, naive: the same, exit 0, objects live at exit 0
  10d/dispatch.ren, perceus: the same, exit 0, objects live at exit 0
  10d/dispatch.ren, naive: the same, exit 0, objects live at exit 0
  10d/dispatch_mix.ren, perceus: the same, exit 0, objects live at exit 0
  10d/dispatch_mix.ren, naive: the same, exit 0, objects live at exit 0
  10d/dispatch_panic.ren, perceus: the same, exit 1, objects live at exit 2
  10d/dispatch_panic.ren, naive: the same, exit 1, objects live at exit 2
  10d/overany.ren, perceus: the same, exit 0, objects live at exit 0
  10d/overany.ren, naive: the same, exit 0, objects live at exit 0
  10d/slices.ren, perceus: the same, exit 0, objects live at exit 0
  10d/slices.ren, naive: the same, exit 0, objects live at exit 0
  10d/slices_panic.ren, perceus: the same, exit 1, objects live at exit 1
  10d/slices_panic.ren, naive: the same, exit 1, objects live at exit 1
  10d/slices_lent.ren, perceus: the same, exit 0, objects live at exit 0
  10d/slices_lent.ren, naive: the same, exit 0, objects live at exit 0
  10d/review_slices.ren, perceus: the same, exit 0, objects live at exit 0
  10d/review_slices.ren, naive: the same, exit 0, objects live at exit 0
  10d/review_deps.ren, perceus: the same, exit 0, objects live at exit 0
  10d/review_deps.ren, naive: the same, exit 0, objects live at exit 0
  11a/trywith.ren, perceus: the same, exit 0, objects live at exit 0
  11a/trywith.ren, naive: the same, exit 0, objects live at exit 0
  11a/alone.ren, perceus: the same, exit 0, objects live at exit 0
  11a/alone.ren, naive: the same, exit 0, objects live at exit 0
  11a/alone_panic.ren, perceus: the same, exit 1, objects live at exit 3
  11a/alone_panic.ren, naive: the same, exit 1, objects live at exit 3
  11a/limit.ren, perceus: the same, exit 0, objects live at exit 0
  11a/limit.ren, naive: the same, exit 0, objects live at exit 0
  11a/limit_panic.ren, perceus: the same, exit 1, objects live at exit 5
  11a/limit_panic.ren, naive: the same, exit 1, objects live at exit 5
  data/update.ren, perceus: the same, exit 0, objects live at exit 0
  data/update.ren, naive: the same, exit 0, objects live at exit 0
  data/byname.ren, perceus: the same, exit 0, objects live at exit 0
  data/byname.ren, naive: the same, exit 0, objects live at exit 0
  data/orpat.ren, perceus: the same, exit 0, objects live at exit 0
  data/orpat.ren, naive: the same, exit 0, objects live at exit 0
  data/orpat_strs.ren, perceus: the same, exit 0, objects live at exit 0
  data/orpat_strs.ren, naive: the same, exit 0, objects live at exit 0
  data/variants.ren, perceus: the same, exit 0, objects live at exit 0
  data/variants.ren, naive: the same, exit 0, objects live at exit 0
  data/variants_small.ren, perceus: the same, exit 0, objects live at exit 0
  data/variants_small.ren, naive: the same, exit 0, objects live at exit 0
  data/variants_escape.ren, perceus: the same, exit 0, objects live at exit 0
  data/variants_escape.ren, naive: the same, exit 0, objects live at exit 0
  data/variants_reuse.ren, perceus: the same, exit 0, objects live at exit 0
  data/variants_reuse.ren, naive: the same, exit 0, objects live at exit 0
  data/todo_panic.ren, perceus: the same, exit 1, objects live at exit 1
  data/todo_panic.ren, naive: the same, exit 1, objects live at exit 1
  data/shapes.ren, perceus: the same, exit 0, objects live at exit 0
  data/shapes.ren, naive: the same, exit 0, objects live at exit 0
  data/nested.ren, perceus: the same, exit 0, objects live at exit 0
  data/nested.ren, naive: the same, exit 0, objects live at exit 0
  data/rows.ren, perceus: the same, exit 0, objects live at exit 0
  data/rows.ren, naive: the same, exit 0, objects live at exit 0
  data/optional.ren, perceus: the same, exit 0, objects live at exit 0
  data/optional.ren, naive: the same, exit 0, objects live at exit 0
  data/layout.ren, perceus: the same, exit 0, objects live at exit 0
  data/layout.ren, naive: the same, exit 0, objects live at exit 0
  data/layout_walks.ren, perceus: the same, exit 0, objects live at exit 0
  data/layout_walks.ren, naive: the same, exit 0, objects live at exit 0
  data/layout_panic.ren, perceus: the same, exit 1, objects live at exit 5
  data/layout_panic.ren, naive: the same, exit 1, objects live at exit 8
  data/reuse_arms.ren, perceus: the same, exit 0, objects live at exit 0
  data/reuse_arms.ren, naive: the same, exit 0, objects live at exit 0
  data/rows_objs.ren, perceus: the same, exit 0, objects live at exit 0
  data/rows_objs.ren, naive: the same, exit 0, objects live at exit 0
  data/rows_panic.ren, perceus: the same, exit 1, objects live at exit 45
  data/rows_panic.ren, naive: the same, exit 1, objects live at exit 45
  data/niche.ren, perceus: the same, exit 0, objects live at exit 0
  data/niche.ren, naive: the same, exit 0, objects live at exit 0
  data/niche_walks.ren, perceus: the same, exit 0, objects live at exit 0
  data/niche_walks.ren, naive: the same, exit 0, objects live at exit 0
  data/niche_panic.ren, perceus: the same, exit 1, objects live at exit 12
  data/niche_panic.ren, naive: the same, exit 1, objects live at exit 14
  data/niche_reuse.ren, perceus: the same, exit 0, objects live at exit 0
  data/niche_reuse.ren, naive: the same, exit 0, objects live at exit 0
  data/niche_join.ren, perceus: the same, exit 0, objects live at exit 0
  data/niche_join.ren, naive: the same, exit 0, objects live at exit 0
  data/interp.ren, perceus: the same, exit 0, objects live at exit 0
  data/interp.ren, naive: the same, exit 0, objects live at exit 0
  data/review_keys.ren, perceus: the same, exit 0, objects live at exit 0
  data/review_keys.ren, naive: the same, exit 0, objects live at exit 0
  data/review_state.ren, perceus: the same, exit 0, objects live at exit 0
  data/review_state.ren, naive: the same, exit 0, objects live at exit 0
  data/review_state_panic.ren, perceus: the same, exit 1, objects live at exit 2
  data/review_state_panic.ren, naive: the same, exit 1, objects live at exit 2
  data/review_todo_panic.ren, perceus: the same, exit 1, objects live at exit 1
  data/review_todo_panic.ren, naive: the same, exit 1, objects live at exit 1

Every native benchmark, at its small size:

  $ for f in native/*/small.ren; do same $f; done
  native/binary-trees/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/binary-trees/small.ren, naive: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, naive: the same, exit 0, objects live at exit 0
  native/bytes/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/bytes/small.ren, naive: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, naive: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, naive: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, naive: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, naive: the same, exit 0, objects live at exit 0
  native/inout/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/inout/small.ren, naive: the same, exit 0, objects live at exit 0
  native/interp/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/interp/small.ren, naive: the same, exit 0, objects live at exit 0
  native/nbody/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/nbody/small.ren, naive: the same, exit 0, objects live at exit 0
  native/nested/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/nested/small.ren, naive: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, naive: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, naive: the same, exit 0, objects live at exit 0
  native/slices/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/slices/small.ren, naive: the same, exit 0, objects live at exit 0
  native/stack/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/stack/small.ren, naive: the same, exit 0, objects live at exit 0
  native/vec/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/vec/small.ren, naive: the same, exit 0, objects live at exit 0

And the examples in the subset, the single files and two of the
folders:

  $ for f in ../examples/*.ren ../examples/shop/main.ren ../examples/two/main.ren; do same $f; done
  ../examples/blocks.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/blocks.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/fib.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/fib.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/infer.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/infer.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/plans.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/plans.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/values.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/values.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/shop/main.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/shop/main.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/two/main.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/two/main.ren, naive: the same, exit 0, objects live at exit 0

H1, in the debug build: a block costs a call, never an allocation. Its
environment is on its writer's stack, so each kernel of
native/blocks/bench.ren written with a block allocates exactly as many
objects as its twin written as a loop; `block calls` counts the calls.

  $ cd native/blocks
  $ for k in map reduce each; do for v in blocks loop; do
  >   printf 'import bench\n\nfn main() uses Console =\n  var xs: Array<Int> = []\n  for i in 0..1000\n    &xs.push(i * 7 %% 1000)\n  print(bench.%s_%s(xs, 10))\n' $k $v > ${k}_$v.ren
  > done; done
  $ for v in blocks loop; do
  >   printf 'import bench\n\nfn main() uses Console = print(bench.fold_%s(bench.build(0, 1000), 10))\n' $v > fold_$v.ren
  >   printf 'import bench\n\nfn main() uses Console = print(bench.attempt_%s(10))\n' $v > attempt_$v.ren
  > done
  $ allocations() {
  >   ren build --debug --stats "$1.ren" -o ./h1.bin && ./h1.bin 2>&1 > /dev/null |
  >     grep -o 'allocations [0-9]*'
  > }
  $ for k in map reduce each fold attempt; do
  >   b=$(allocations ${k}_blocks); l=$(allocations ${k}_loop)
  >   if [ "$b" = "$l" ]; then echo "$k: $b, both"; else echo "$k: $b with blocks, $l with loops"; fi
  > done
  map: allocations 13, both
  reduce: allocations 3, both
  each: allocations 3, both
  fold: allocations 1002, both
  attempt: allocations 2, both
  $ cd ../..

H3, what Perceus saves over the naive counting, in the debug build.
Counting what it must: rbtree's counts again and drops strictly
fewer times than the naive build's.

  $ counts() {
  >   ren build --debug --stats --rc $2 "$1" -o ./h3.bin && ./h3.bin 2>&1 > /dev/null |
  >     sed -n 's/.*dups \([0-9]*\), drops \([0-9]*\).*/\1 \2/p' | { read d r; echo $((d + r)); }
  > }
  $ cd native/rbtree
  $ p=$(counts small.ren perceus); n=$(counts small.ren naive)
  $ if [ "$p" -lt "$n" ]; then echo "rbtree: fewer with Perceus"; else echo "rbtree: $p with Perceus, $n naive"; fi
  rbtree: fewer with Perceus
  $ cd ../..

Changing what's unique in place: fannkuch allocates its arrays once,
and nothing for each permutation, so it allocates as many objects for
7 as for 6; the naive build copies an array at each change. And
`map` over an array it builds fills it in place, so building one of
2000 elements allocates as many objects as one of 1000.

  $ allocations() {
  >   ren build --debug --stats --rc $2 "$1" -o ./h3.bin && ./h3.bin 2>&1 > /dev/null |
  >     grep -o 'allocations [0-9]*'
  > }
  $ cd native/fannkuch
  $ for n in 6 7; do printf 'import bench\n\nfn main() uses Console = bench.run(%d)\n' $n > run_$n.ren; done
  $ for rc in perceus naive; do
  >   a=$(allocations run_6.ren $rc); b=$(allocations run_7.ren $rc)
  >   if [ "$a" = "$b" ]; then echo "fannkuch, $rc: $a, both"; else echo "fannkuch, $rc: more for 7"; fi
  > done
  fannkuch, perceus: allocations 10, both
  fannkuch, naive: more for 7
  $ cd ../blocks
  $ for n in 1000 2000; do
  >   printf 'import bench\n\nfn main() uses Console =\n  var xs: Array<Int> = []\n  for i in 0..%d\n    &xs.push(i)\n  print(bench.map_blocks(xs, 10))\n' $n > map_$n.ren
  > done
  $ for rc in perceus naive; do
  >   a=$(allocations map_1000.ren $rc); b=$(allocations map_2000.ren $rc)
  >   if [ "$a" = "$b" ]; then echo "map, $rc: $a, both"; else echo "map, $rc: more for 2000"; fi
  > done
  map, perceus: allocations 13, both
  map, naive: more for 2000
  $ cd ../..

The release build (native step 5) compiles the program specialized
(specialize.ml): a copy of each function for the types, blocks and
known handlers each call gives it, which Core Lint checks and `ren run
--release` runs. Each program built `--release`, under the sanitizers,
prints what `ren run` prints, and ends with no object alive; so does
`ren run --release`.

  $ release() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    ren build --release --stats "$f" -o ./release.bin 2> release.made &&
  >    { ./release.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    { ren run --release "$f" > spec.out 2> spec.err; echo "exit $?" > spec.code; } &&
  >    grep -v -e '^ren stats: ' -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >      -e '^False positive error reports may follow' \
  >      -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >      native.err > native.err2;
  >    if cmp -s native.out interp.out && cmp -s native.err2 interp.err &&
  >       cmp -s native.code interp.code && cmp -s spec.out interp.out &&
  >       cmp -s spec.err interp.err && cmp -s spec.code interp.code
  >    then echo "$1, release: the same, $(cat native.code), $(grep -o 'objects live at exit [0-9]*' native.err)"
  >    else echo "$1, release: different"; diff native.out interp.out; diff native.err2 interp.err; diff spec.out interp.out
  >    fi)
  > }
  $ for f in fib deep loop overflow frames tokens packed values values_panic swap swap_panic swap_order trmc trmc_panic sized sized_panic loops loops_panic loops_short review_arrays review_values review_lists review_shrink 10d/bits 10d/bits_panic 10d/generic 10d/cache 10d/aliases 10d/shapes 10d/router 10d/methods 10d/dispatch 10d/dispatch_mix 10d/dispatch_panic 10d/overany 10d/slices 10d/slices_panic 10d/slices_lent 10d/review_slices 10d/review_deps 11a/trywith 11a/alone 11a/alone_panic 11a/limit 11a/limit_panic data/update data/byname data/orpat data/orpat_strs data/variants data/variants_small data/variants_escape data/variants_reuse data/todo_panic data/shapes data/nested data/rows data/optional data/layout data/layout_walks data/layout_panic data/reuse_arms data/rows_objs data/rows_panic data/niche data/niche_walks data/niche_panic data/niche_reuse data/niche_join data/interp data/review_keys data/review_state data/review_state_panic data/review_todo_panic; do release $f.ren; done
  fib.ren, release: the same, exit 0, objects live at exit 0
  deep.ren, release: the same, exit 0, objects live at exit 0
  loop.ren, release: the same, exit 0, objects live at exit 0
  overflow.ren, release: the same, exit 1, objects live at exit 0
  frames.ren, release: the same, exit 0, objects live at exit 0
  tokens.ren, release: the same, exit 0, objects live at exit 0
  packed.ren, release: the same, exit 0, objects live at exit 0
  values.ren, release: the same, exit 0, objects live at exit 0
  values_panic.ren, release: the same, exit 1, objects live at exit 3
  swap.ren, release: the same, exit 0, objects live at exit 0
  swap_panic.ren, release: the same, exit 1, objects live at exit 4
  swap_order.ren, release: the same, exit 1, objects live at exit 4
  trmc.ren, release: the same, exit 0, objects live at exit 0
  trmc_panic.ren, release: the same, exit 1, objects live at exit 11
  sized.ren, release: the same, exit 0, objects live at exit 0
  sized_panic.ren, release: the same, exit 1, objects live at exit 2
  loops.ren, release: the same, exit 0, objects live at exit 0
  loops_panic.ren, release: the same, exit 1, objects live at exit 3
  loops_short.ren, release: the same, exit 1, objects live at exit 6
  review_arrays.ren, release: the same, exit 0, objects live at exit 0
  review_values.ren, release: the same, exit 0, objects live at exit 0
  review_lists.ren, release: the same, exit 0, objects live at exit 0
  review_shrink.ren, release: the same, exit 1, objects live at exit 2
  10d/bits.ren, release: the same, exit 0, objects live at exit 0
  10d/bits_panic.ren, release: the same, exit 1, objects live at exit 1
  10d/generic.ren, release: the same, exit 0, objects live at exit 0
  10d/cache.ren, release: the same, exit 0, objects live at exit 0
  10d/aliases.ren, release: the same, exit 0, objects live at exit 0
  10d/shapes.ren, release: the same, exit 0, objects live at exit 0
  10d/router.ren, release: the same, exit 0, objects live at exit 0
  10d/methods.ren, release: the same, exit 0, objects live at exit 0
  10d/dispatch.ren, release: the same, exit 0, objects live at exit 0
  10d/dispatch_mix.ren, release: the same, exit 0, objects live at exit 0
  10d/dispatch_panic.ren, release: the same, exit 1, objects live at exit 2
  10d/overany.ren, release: the same, exit 0, objects live at exit 0
  10d/slices.ren, release: the same, exit 0, objects live at exit 0
  10d/slices_panic.ren, release: the same, exit 1, objects live at exit 1
  10d/slices_lent.ren, release: the same, exit 0, objects live at exit 0
  10d/review_slices.ren, release: the same, exit 0, objects live at exit 0
  10d/review_deps.ren, release: the same, exit 0, objects live at exit 0
  11a/trywith.ren, release: the same, exit 0, objects live at exit 0
  11a/alone.ren, release: the same, exit 0, objects live at exit 0
  11a/alone_panic.ren, release: the same, exit 1, objects live at exit 3
  11a/limit.ren, release: the same, exit 0, objects live at exit 0
  11a/limit_panic.ren, release: the same, exit 1, objects live at exit 5
  data/update.ren, release: the same, exit 0, objects live at exit 0
  data/byname.ren, release: the same, exit 0, objects live at exit 0
  data/orpat.ren, release: the same, exit 0, objects live at exit 0
  data/orpat_strs.ren, release: the same, exit 0, objects live at exit 0
  data/variants.ren, release: the same, exit 0, objects live at exit 0
  data/variants_small.ren, release: the same, exit 0, objects live at exit 0
  data/variants_escape.ren, release: the same, exit 0, objects live at exit 0
  data/variants_reuse.ren, release: the same, exit 0, objects live at exit 0
  data/todo_panic.ren, release: the same, exit 1, objects live at exit 1
  data/shapes.ren, release: the same, exit 0, objects live at exit 0
  data/nested.ren, release: the same, exit 0, objects live at exit 0
  data/rows.ren, release: the same, exit 0, objects live at exit 0
  data/optional.ren, release: the same, exit 0, objects live at exit 0
  data/layout.ren, release: the same, exit 0, objects live at exit 0
  data/layout_walks.ren, release: the same, exit 0, objects live at exit 0
  data/layout_panic.ren, release: the same, exit 1, objects live at exit 3
  data/reuse_arms.ren, release: the same, exit 0, objects live at exit 0
  data/rows_objs.ren, release: the same, exit 0, objects live at exit 0
  data/rows_panic.ren, release: the same, exit 1, objects live at exit 26
  data/niche.ren, release: the same, exit 0, objects live at exit 0
  data/niche_walks.ren, release: the same, exit 0, objects live at exit 0
  data/niche_panic.ren, release: the same, exit 1, objects live at exit 5
  data/niche_reuse.ren, release: the same, exit 0, objects live at exit 0
  data/niche_join.ren, release: the same, exit 0, objects live at exit 0
  data/interp.ren, release: the same, exit 0, objects live at exit 0
  data/review_keys.ren, release: the same, exit 0, objects live at exit 0
  data/review_state.ren, release: the same, exit 0, objects live at exit 0
  data/review_state_panic.ren, release: the same, exit 1, objects live at exit 2
  data/review_todo_panic.ren, release: the same, exit 1, objects live at exit 1
  $ for f in native/*/small.ren; do release $f; done
  native/binary-trees/small.ren, release: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, release: the same, exit 0, objects live at exit 0
  native/bytes/small.ren, release: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, release: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, release: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, release: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, release: the same, exit 0, objects live at exit 0
  native/inout/small.ren, release: the same, exit 0, objects live at exit 0
  native/interp/small.ren, release: the same, exit 0, objects live at exit 0
  native/nbody/small.ren, release: the same, exit 0, objects live at exit 0
  native/nested/small.ren, release: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, release: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, release: the same, exit 0, objects live at exit 0
  native/slices/small.ren, release: the same, exit 0, objects live at exit 0
  native/stack/small.ren, release: the same, exit 0, objects live at exit 0
  native/vec/small.ren, release: the same, exit 0, objects live at exit 0
  $ for f in ../examples/*.ren ../examples/shop/main.ren ../examples/two/main.ren; do release $f; done
  ../examples/blocks.ren, release: the same, exit 0, objects live at exit 0
  ../examples/fib.ren, release: the same, exit 0, objects live at exit 0
  ../examples/infer.ren, release: the same, exit 0, objects live at exit 0
  ../examples/plans.ren, release: the same, exit 0, objects live at exit 0
  ../examples/values.ren, release: the same, exit 0, objects live at exit 0
  ../examples/shop/main.ren, release: the same, exit 0, objects live at exit 0
  ../examples/two/main.ren, release: the same, exit 0, objects live at exit 0

What it made, with `--stats`: blocks's five kernels each lift their
block, and handlers's `Counter` is known where it's installed.

  $ for d in blocks handlers; do (cd native/$d && sed 's/^ren specialized: //' release.made); done
  21 copies, 5 blocks lifted, 0 handlers known, 0 calls past the size budget
  6 copies, 0 blocks lifted, 1 handlers known, 0 calls past the size budget

H1, in the release build: the kernels written with a block make no
indirect call and build no block. The only functions that do are the
real `Console`'s, which isn't known, and `$start`'s, which installs it.

  $ cd native/blocks
  $ ren build --release --emit-c small.ren > release.c
  $ awk '/^static .*\) \{$/ { f = $0; sub(/\(.*/, "", f); sub(/.* /, "", f) }
  >      /\.code\(|\(\(ren_block\)\{/ { print f }' release.c | sort -u
  ren_bench_line_1
  ren_real_console_handler
  ren_small__start

And each kernel written with a block allocates exactly as many objects
as its twin written as a loop, as in the debug build:

  $ allocations() {
  >   ren build --release --stats "$1.ren" -o ./h1.bin 2> /dev/null && ./h1.bin 2>&1 > /dev/null |
  >     grep -o 'allocations [0-9]*'
  > }
  $ for k in map reduce each fold attempt; do
  >   b=$(allocations ${k}_blocks); l=$(allocations ${k}_loop)
  >   if [ "$b" = "$l" ]; then echo "$k: $b, both"; else echo "$k: $b with blocks, $l with loops"; fi
  > done
  map: allocations 13, both
  reduce: allocations 3, both
  each: allocations 3, both
  fold: allocations 1002, both
  attempt: allocations 2, both

Each `inout` parameter is a `restrict` pointer in the release build,
which `--no-restrict` leaves out:

  $ grep '^static.*restrict.*;$' release.c
  static int64_t ren_bench_attempt_n_1(const ren_ev* v1_ev, int64_t v2_n, int64_t* restrict v3_calls, int64_t v4_i);
  static int64_t ren_bench_attempt_blocks_1_1(const ren_ev* v1_ev, int64_t* restrict v2_calls, int64_t v3_i);
  static ren_unit ren_Array_each_1(const ren_ev* v1_ev, ren_obj* v2_self, int64_t* restrict v3_total, int64_t v4_k);
  static ren_unit ren_bench_each_blocks_1_1(const ren_ev* v1_ev, int64_t* restrict v2_total, int64_t v3_k, int64_t v4_x);
  $ ren build --release --no-restrict --emit-c small.ren | grep -c ' restrict v'
  0
  [1]
  $ cd ../..

H2: `Counter.bump`, called where its handler is known, is a direct call
of the operation, lifted, given the handler's state, a pointer into the
frame of the `with` that installed it. The two indirect calls left are
the real `Console`'s `write` and the body `$start` installs it for:

  $ cd native/handlers
  $ ren build --release --emit-c small.ren > release.c
  $ grep -n 'counter_bump(' release.c | sed 's/^[0-9]*://'
  static int64_t ren_bench_counter_bump(const ren_ev* v1_ev, int64_t* v2_total, int64_t v3_k);
      int64_t v15_result = ren_bench_counter_bump(v1_ev, v3_total, v14_arith);
  static int64_t ren_bench_counter_bump(const ren_ev* v1_ev, int64_t* v2_total, int64_t v3_k) {
  $ grep -c 'REN_STAT(block_calls)' release.c
  2
  $ cd ../..

A copied record or tuple of scalars (copied.ml) is a C struct in the
release build: passed by value, and kept in an array's elements. One
whose value would have to be a word, or a field of an object, stays
boxed: here `P` in the second program, which a handler's operation
not known takes and a block not lifted is given.

  $ cat > structs.ren <<'EOF'
  > type P = { x: Int, y: Int }
  > type V = { a: Float, b: Float, on: Bool }
  > type Q = { p: P, n: Int }
  > 
  > fn add(p: P, q: P) -> P = P { x: p.x + q.x, y: p.y + q.y }
  > fn swap(t: (Int, Int)) -> (Int, Int) =
  >   let (a, b) = t
  >   (b, a)
  > fn bump(inout p: P) =
  >   p.x += 1
  > fn each(xs: Array<P>, f: fn(P)) =
  >   for x in xs
  >     try f(x)
  > 
  > dep Acc =
  >   put: fn(p: P)
  >   total: fn() -> P
  > 
  > handler summing() for Acc =
  >   var t = P { x: 0, y: 0 }
  >   put(p) => t = add(t, p)
  >   total() => t
  > 
  > fn sum_two() -> Int uses Acc =
  >   Acc.put(P { x: 1, y: 2 })
  >   Acc.put(P { x: 3, y: 4 })
  >   Acc.total().y
  > 
  > fn main() uses Console =
  >   var ps: Array<P> = []
  >   for i in 0..5
  >     &ps.push(P { x: i, y: i * 2 })
  >   ps[2].y = 100
  >   var s = P { x: 0, y: 0 }
  >   for p in ps
  >     s = add(s, p)
  >   print(s.x)
  >   print(s.y)
  >   bump(&s)
  >   print(s.x)
  >   let (a, b) = swap((1, 2))
  >   print(a * 10 + b)
  >   var n = 0
  >   each(ps, fn(p) => n += p.y)
  >   print(n)
  >   let v = V { a: 1.5, b: 2.5, on: true }
  >   var w = v
  >   w.a = 3.0
  >   print(w.a + w.b)
  >   if w.on then print("on") else print("off")
  >   print(with summing() in sum_two())
  >   match (s.x, s.y)
  >     (11, _) => print("eleven")
  >     _ => print("other")
  >   var qs = ps
  >   qs[0].x = 42
  >   print(ps[0].x + qs[0].x)
  >   let r = [P { x: 5, y: 6 }, P { x: 7, y: 8 }]
  >   print(r[1].y)
  >   var big: Array<P> = []
  >   for i in 0..100
  >     &big.push(P { x: i, y: 0 })
  >   var k = 0
  >   for i in 0..100
  >     big[i].y = big[i].x * 2
  >     k += big[i].y
  >   print(k)
  >   let arr = [(1, 2), (3, 4)]
  >   var tot = 0
  >   for t in arr
  >     let (x, y) = t
  >     tot += x * y
  >   print(tot)
  >   print(ps.len())
  > EOF
  $ cat > boxed.ren <<'EOF'
  > type P = { x: Int, y: Int }
  > 
  > dep Log =
  >   put: fn(p: P) -> P
  > 
  > handler twice() for Log =
  >   put(p) => P { x: p.x * 2, y: p.y * 2 }
  > 
  > fn go(n: Int) -> Int uses Log =
  >   var s = 0
  >   for i in 0..n
  >     s += Log.put(P { x: i, y: 1 }).x
  >   s
  > 
  > fn pick(c: Bool) -> P = if c then P { x: 1, y: 2 } else P { x: 3, y: 4 }
  > 
  > fn main() uses Console =
  >   let h = twice()
  >   print(with h in go(4))
  >   let f = fn(p: P) => p.x + p.y
  >   print(f(pick(true)) + f(pick(false)))
  >   var g = P { x: 0, y: 0 }
  >   let ts = [(1, 2.5), (2, 3.5)]
  >   var sum = 0.0
  >   for t in ts
  >     let (i, x) = t
  >     sum += x * Float.of(i)
  >   print(sum)
  > EOF
  $ for f in structs boxed; do release $f.ren; ren build --release --emit-c $f.ren | grep 'typedef struct { ren_val'; done
  structs.ren, release: the same, exit 0, objects live at exit 0
  typedef struct { ren_val s[2]; } ren_struct_0;
  typedef struct { ren_val s[3]; } ren_struct_1;
  boxed.ren, release: the same, exit 0, objects live at exit 0
  typedef struct { ren_val s[2]; } ren_struct_0;

nbody's bodies are structs in the array, so a step allocates nothing.
The debug build's are objects: a change of one's field moves it out of
the array (swap.ml) and builds the new one in its memory, where that's
unique, so it allocates a body only where it isn't:

  $ cd native/nbody
  $ for mode in debug release; do
  >   ren build --$mode --stats small.ren -o ./nbody.bin 2> /dev/null && ./nbody.bin 2>&1 > /dev/null |
  >     grep -o 'allocations [0-9]*' | sed "s/^/$mode: /"
  > done
  debug: allocations 5017
  release: allocations 12
  $ cd ../..

A loop that changes an array it holds, and makes no other reference to
it, has the array made unique once, before it, and indexes its
elements directly inside (hoist.ml); a field of a struct in an array is
written in place. The loop is a function of its own, inlined, whose
buffers are `restrict` parameters. `kept` shares `a` when `scale` runs,
so `scale` copies it, once, and `kept` doesn't change; `main`'s own
loop passes `&p` to a call, so it isn't hoisted. An index out of bounds
in a hoisted loop panics as it would anywhere:

  $ cat > hoist.ren <<'EOF'
  > type B = { x: Float, v: Float }
  > 
  > fn scale(inout a: Array<Int>, k: Int) =
  >   for i in 0..a.len()
  >     a[i] = a[i] * k
  > 
  > fn mix(inout a: Array<Int>, inout b: Array<Int>, c: Array<Int>) =
  >   for i in 0..a.len()
  >     a[i] = a[i] + b[i] * c[i]
  >     b[i] = b[i] + a[i]
  > 
  > fn nudge(inout bs: Array<B>) =
  >   for i in 0..bs.len()
  >     bs[i].x += bs[i].v
  > 
  > fn shout(inout ss: Array<Str>) =
  >   for i in 0..ss.len()
  >     ss[i] = ss[i].concat("!")
  > 
  > fn poke(inout a: Array<Int>, i: Int) =
  >   a[i] = a[i] * 2
  > 
  > fn main() uses Console =
  >   var a = [1, 2, 3]
  >   let kept = a
  >   scale(&a, 10)
  >   print(kept[0] + kept[2])
  >   print(a[0] + a[2])
  >   var b = [4, 5, 6]
  >   mix(&a, &b, kept)
  >   print(a[1] + b[1])
  >   var bs = [B { x: 1.0, v: 0.5 }, B { x: 2.0, v: 0.25 }]
  >   let before = bs
  >   nudge(&bs)
  >   print(before[0].x + bs[0].x)
  >   var ss = ["a", "b"]
  >   let old = ss
  >   shout(&ss)
  >   Console.write(old[0].concat(ss[0]).concat(ss[1]))
  >   var p = [1, 2, 3]
  >   for i in 0..p.len()
  >     p[i] = p[i] + 1
  >     poke(&p, i)
  >   print(p[0] + p[1] + p[2])
  > EOF
  $ cat > bounds.ren <<'EOF'
  > fn fill(inout a: Array<Int>, n: Int) =
  >   for i in 0..n
  >     a[i] = i
  > 
  > fn main() uses Console =
  >   var a = [0, 0]
  >   fill(&a, 3)
  >   print(a[0])
  > EOF
  $ release hoist.ren && cat native.out
  hoist.ren, release: the same, exit 0, objects live at exit 0
  4
  40
  65
  2.5
  aa!b!
  18
  $ release bounds.ren && cat native.err | grep -v '^ren stats'
  bounds.ren, release: the same, exit 1, objects live at exit 2
  error: panic: index 2 is out of bounds for an array of length 2
    ┌─ bounds.ren:3:5
  3 │     a[i] = i
    │     ^^^^
  $ ren build --release --emit-c hoist.ren | grep '^static inline.*_loop_'
  static inline __attribute__((always_inline)) void ren_hoist_shout_1_loop_1(int64_t* v3_i, int64_t v6_stop, int64_t v27_len, ren_val* restrict v30_buf) {
  static inline __attribute__((always_inline)) void ren_hoist_nudge_1_loop_1(int64_t* v3_i, int64_t v6_stop, int64_t v32_len, ren_val* restrict v35_buf) {
  static inline __attribute__((always_inline)) void ren_hoist_mix_1_loop_1(int64_t* v5_i, int64_t v8_stop, int64_t v116_len, ren_val* restrict v119_buf, int64_t v121_len, ren_val* restrict v124_buf, int64_t v126_len, ren_val* restrict v128_buf) {
  static inline __attribute__((always_inline)) void ren_hoist_mix_1_loop_2(int64_t* v5_i, int64_t v8_stop, int64_t v102_len, ren_val* restrict v105_buf, int64_t v107_len, ren_val* restrict v110_buf, int64_t v112_len, ren_val* restrict v114_buf) {
  static inline __attribute__((always_inline)) void ren_hoist_scale_1_loop_1(int64_t v3_k, int64_t* v4_i, int64_t v7_stop, int64_t v29_len, ren_val* restrict v32_buf) {
  $ ren build --release --no-restrict --emit-c hoist.ren | grep -c ' restrict v'
  0
  [1]

What the native slice doesn't have says so, at the code that needs it,
like the real `Clock`:

  $ cat > clock.ren <<'EOF'
  > fn main() uses Clock, Console =
  >   let t = Clock.now()
  >   print(t)
  > EOF
  $ ren build clock.ren
  error: the real `Clock` isn't in the native slice yet
    ┌─ clock.ren:1:4
  1 │ fn main() uses Clock, Console =
    │    ^^^^ `ren build` can't compile this yet
    help: run it with `ren run clock.ren`
  [1]

A `var` walked down a list or a tree, by a `match` of it that assigns
it a field its pattern took out, or a constant: the field the variable
holds next is the one reference the old value gave up, counted once,
and a constant where the loop goes round holds none.

  $ cat > walks.ren <<'EOF'
  > type List = Nil | Cons { h: Int, t: List }
  > type T = Leaf | Node { l: T, r: T }
  > 
  > fn count(xs: List) -> Int =
  >   var n = 0
  >   var cur = xs
  >   while true
  >     match cur
  >       Nil => break
  >       Cons { t, .. } =>
  >         n += 1
  >         cur = t
  >   n
  > 
  > fn count_go(xs: List) -> Int =
  >   var n = 0
  >   var cur = xs
  >   var go = true
  >   while go
  >     match cur
  >       Nil => go = false
  >       Cons { t, .. } =>
  >         n += 1
  >         cur = t
  >   n
  > 
  > fn first(xs: List) -> Int =
  >   var n = 0
  >   var cur = xs
  >   while true
  >     match cur
  >       Nil => break
  >       Cons { h, .. } =>
  >         n = h
  >         cur = Nil
  >   n
  > 
  > fn last(xs: List) -> Int =
  >   var cur = xs
  >   var out = 0
  >   for i in 0..100
  >     match cur
  >       Nil => out = out + 0
  >       Cons { h, t } =>
  >         out = h
  >         cur = t
  >   out
  > 
  > fn main() uses Console =
  >   let xs = Cons { h: 1, t: Cons { h: 2, t: Cons { h: 3, t: Nil } } }
  >   print(count(xs) + count_go(xs) * 10 + first(xs) * 100 + last(xs) * 1000)
  >   var t = Node { l: Node { l: Leaf, r: Leaf }, r: Leaf }
  >   var n = 0
  >   var go = true
  >   while go
  >     match t
  >       Leaf => go = false
  >       Node { l, .. } =>
  >         n += 1
  >         t = l
  >   print(n)
  > EOF
  $ same walks.ren; release walks.ren
  walks.ren, perceus: the same, exit 0, objects live at exit 0
  walks.ren, naive: the same, exit 0, objects live at exit 0
  walks.ren, release: the same, exit 0, objects live at exit 0

A call given a block the release build lifts, and one it doesn't, a
`let` of a block, that uses the same variable: the lifted one would be
given that variable when the call is made, and miss what the other
changes during it, so neither is lifted.

  $ cat > siblings.ren <<'EOF'
  > fn both(f: fn(), g: fn() -> Int) -> Int =
  >   try f()
  >   let a = try g()
  >   try f()
  >   a
  > 
  > fn main() uses Console =
  >   var n = 10
  >   let get = fn() => n
  >   print(both(fn() => n -= 1, get))
  >   let dec = fn() => n -= 1
  >   print(both(dec, fn() => n))
  >   print(n)
  > EOF
  $ release siblings.ren; ren run siblings.ren
  siblings.ren, release: the same, exit 0, objects live at exit 0
  9
  7
  6

A panic's message is kept in pieces (ren_rt.h, `ren_site`): each text
once, a file's name and each line of it, which every panic there
shares, and the numbers, spaces and marks between them. Each binary
prints what `ren run` prints for a panic: one in a prelude function,
whose file the binary doesn't show; one with the wrapping method's help
on operands in parentheses, and on `+=` at a line past 99, where the
gutter is wider; a division by zero; an index out of bounds; and an
`assert`, whose message is known whole. A panic leaks what's still
held (foundations.md, decision 8), which the counts at exit show.

  $ cat > p_sum.ren <<'EOF'
  > fn main() uses Console =
  >   let xs = [9223372036854775807, 1]
  >   print(xs.sum())
  > EOF
  $ cat > p_paren.ren <<'EOF'
  > fn main() uses Console =
  >   let a = 4611686018427387904
  >   let b = 1
  >   print((a + b) * 2)
  > EOF
  $ { for i in $(seq 1 100); do echo "// line $i"; done; cat <<'EOF'
  > fn main() uses Console =
  >   var n = 9223372036854775800
  >   for i in 0..10
  >     n += i
  >   print(n)
  > EOF
  > } > p_far.ren
  $ cat > p_div.ren <<'EOF'
  > fn main() uses Console =
  >   let z = [0].len() - 1
  >   print(10 / z)
  > EOF
  $ cat > p_index.ren <<'EOF'
  > fn main() uses Console =
  >   let a = [1, 2, 3]
  >   print(a[1] + a[5])
  > EOF
  $ cat > p_assert.ren <<'EOF'
  > fn main() uses Console =
  >   let a = 3
  >   assert(a > 4)
  >   print(a)
  > EOF
  $ for f in p_sum p_paren p_far p_div p_index p_assert; do same $f.ren; release $f.ren; done
  p_sum.ren, perceus: the same, exit 1, objects live at exit 2
  p_sum.ren, naive: the same, exit 1, objects live at exit 2
  p_sum.ren, release: the same, exit 1, objects live at exit 2
  p_paren.ren, perceus: the same, exit 1, objects live at exit 1
  p_paren.ren, naive: the same, exit 1, objects live at exit 1
  p_paren.ren, release: the same, exit 1, objects live at exit 1
  p_far.ren, perceus: the same, exit 1, objects live at exit 1
  p_far.ren, naive: the same, exit 1, objects live at exit 1
  p_far.ren, release: the same, exit 1, objects live at exit 1
  p_div.ren, perceus: the same, exit 1, objects live at exit 1
  p_div.ren, naive: the same, exit 1, objects live at exit 1
  p_div.ren, release: the same, exit 1, objects live at exit 1
  p_index.ren, perceus: the same, exit 1, objects live at exit 2
  p_index.ren, naive: the same, exit 1, objects live at exit 2
  p_index.ren, release: the same, exit 1, objects live at exit 2
  p_assert.ren, perceus: the same, exit 1, objects live at exit 1
  p_assert.ren, naive: the same, exit 1, objects live at exit 1
  p_assert.ren, release: the same, exit 1, objects live at exit 1
  $ ren run p_far.ren
  error: panic: `+` overflowed: 9223372036854775806 + 4
      ┌─ p_far.ren:104:5
  104 │     n += i
      │     ^^^^^^
      help: if wrapping is what you mean, write `n +%= i`
  [1]

The texts are each once in the C, and a site is a few bytes of pieces:
`p_paren`'s line is one text, its operands slices of it.

  $ ren build --release --emit-c p_paren.ren | grep -c '"  print((a + b) \* 2)"'
  1

Functions whose Mem is the same are one (fold.ml): `pick` and `keep`,
which only move their values, at two record types laid out alike, two
`Int`s, a struct each, are one function each; `show_it`, which shows
its value, so depends on its type, is still two.

  $ cat > fold.ren <<'EOF'
  > type A = { x: Int, y: Int }
  > type B = { p: Int, q: Int }
  > type C = { c: Int }
  > type D = { d: Int }
  > 
  > fn pick<T>(c: Bool, a: T, b: T) -> T = if c then a else b
  > 
  > fn keep<T>(xs: Array<T>, x: T) -> Array<T> =
  >   var ys = xs
  >   &ys.push(x)
  >   ys
  > 
  > fn show_it<T>(x: T) -> Str = show(x)
  > 
  > fn main() uses Console =
  >   let a = pick(true, A { x: 1, y: 2 }, A { x: 3, y: 4 })
  >   let b = pick(false, B { p: 1, q: 2 }, B { p: 3, q: 4 })
  >   let xs = keep([a], a)
  >   let ys = keep([b], b)
  >   print(a.x + b.q + xs.len() + ys.len())
  >   print(show_it(C { c: 5 }))
  >   print(show_it(D { d: 6 }))
  > EOF
  $ ren run fold.ren
  9
  C { c: 5 }
  D { d: 6 }
  $ release fold.ren; ren build --release --emit-mem fold.ren | grep -o -e '^(fn ren_fold_pick.*' -e '^(fn ren_fold_keep.*' -e '^(fn ren_fold_show_it' | sed 's/_[0-9] (/ (/' | sort | uniq -c | sed 's/^ *//'
  fold.ren, release: the same, exit 0, objects live at exit 0
  1 (fn ren_fold_keep (ev/1:Ev xs/2:Boxed x/3:Struct0) -> Boxed
  1 (fn ren_fold_pick (ev/1:Ev c/2:Bool a/3:Struct0 b/4:Struct0) -> Struct0
  2 (fn ren_fold_show_it

Specialization has no cap on the copies of one function, but a size
budget for the whole program (specialize.ml), which `REN_SPEC_BUDGET`
sets: past it, a call that needs a new copy gets the function as
written, its arguments boxed, and the build says so. The program still
prints what `ren run` prints.

  $ cat > budget.ren <<'EOF'
  > fn apply(x: Int, f: fn(Int) -> Int) -> Int = try f(x)
  > fn main() uses Console =
  >   print(apply(1, fn(n) => n + 1))
  >   print(apply(2, fn(n) => n * 2))
  > EOF
  $ REN_SPEC_BUDGET=25 release budget.ren; cat release.made
  budget.ren, release: the same, exit 0, objects live at exit 0
  ren specialized: 3 copies, 1 blocks lifted, 0 handlers known, 1 calls past the size budget
  note: specialization reached its size budget, so 1 call is compiled as written, its arguments boxed:
    budget.ren:3:9: a call of `budget.apply`

A generic function called with a type built of its own parameter,
`c0((x, x))`, is given a descriptor built at run time (to_mem.ml,
`desc`, Mem's `New_desc`), of the descriptors of the type's arguments,
which Mem Lint checks as such: in a debug build, and in a release build
past the budget, where the call isn't specialized.

  $ cat > derived.ren <<'EOF'
  > fn c0<T>(x: T) -> Str = show([x])
  > fn c1<T>(x: T) -> Str = c0(([x], Some(x), (x, 1)))
  > fn main() uses Console =
  >   print(c1(1))
  >   print(c1(true))
  >   print(c1("s"))
  > EOF
  $ same derived.ren; REN_SPEC_BUDGET=1 release derived.ren
  derived.ren, perceus: the same, exit 0, objects live at exit 0
  derived.ren, naive: the same, exit 0, objects live at exit 0
  derived.ren, release: the same, exit 0, objects live at exit 0
  $ ren run derived.ren
  [([1], Some(1), (1, 1))]
  [([true], Some(true), (true, 1))]
  [(["s"], Some("s"), ("s", 1))]

A walk reads an array's elements as words, so a small type that's an
array's element in a walked value is boxed, though an array keeps
small values inline (compiler.md, "Data stage", step 7's choices, part
2): here `Pt` and `Tag` are walked only as elements of a generic
record's arrays, whose descriptor is built at run time past the budget,
and are kept inline in the arrays `main` changes.

  $ cat > walked_arrays.ren <<'EOF'
  > type Pt = { x: Int, y: Int }
  > type Tag = { name: Str, n: Int }
  > type Wrap<T> = { v: T, pts: Array<Pt>, tags: Array<Tag> }
  > fn c0<T>(x: T) -> Str = show(Wrap { v: x, pts: [Pt { x: 1, y: 2 }], tags: [Tag { name: "t", n: 3 }] })
  > fn main() uses Console =
  >   print(c0(1))
  >   print(c0("s"))
  >   var ps = [Pt { x: 5, y: 6 }]
  >   &ps.push(Pt { x: 7, y: 8 })
  >   var ts = [Tag { name: "a", n: 1 }]
  >   &ts.push(Tag { name: "b", n: 2 })
  >   print(ps[1].y + ts[1].n)
  > EOF
  $ same walked_arrays.ren; release walked_arrays.ren; REN_SPEC_BUDGET=1 release walked_arrays.ren
  walked_arrays.ren, perceus: the same, exit 0, objects live at exit 0
  walked_arrays.ren, naive: the same, exit 0, objects live at exit 0
  walked_arrays.ren, release: the same, exit 0, objects live at exit 0
  walked_arrays.ren, release: the same, exit 0, objects live at exit 0

A NaN (foundations.md, decision 15; nan.ml) is carried by arithmetic
and stores, and panics where it's observed: a comparison, `==`, `show`,
`round`, a dependency's operation given one (an order through `sort`,
and hashing, are test_nan.ml's, which the native slice doesn't have). Each
build panics where `ren run` does, with its message; a debug build says
where the NaN was made too, and a release build, which tags no NaN,
says the rest. A panic in the prelude, `show` inside `print` here, is
at the program's call that reached it (ren_rt.h, `ren_here`), whichever
of the calls of `print` that is.

  $ unset REN_SPEC_BUDGET
  $ nan_release() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    ren build --release "$f" -o ./release.bin 2> release.made &&
  >    { ./release.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    sed -e 's/ made at [^ ]*$//' -e 's/ made in the prelude$//' interp.err > interp.err2 &&
  >    grep -v -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >      -e '^False positive error reports may follow' \
  >      -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >      native.err > native.err2;
  >    if cmp -s native.out interp.out && cmp -s native.err2 interp.err2 &&
  >       cmp -s native.code interp.code
  >    then echo "$1, release: the same, $(cat native.code)"
  >    else echo "$1, release: different"; diff native.out interp.out; diff native.err2 interp.err2
  >    fi)
  > }
  $ cat > nan_cmp.ren <<'EOF'
  > fn main() uses Console =
  >   let z = 0.0
  >   let a = z / z
  >   let b = a * 2.0 + 1.0
  >   var fs: Array<Float32> = [0.5, 1.0]
  >   fs[1] = b
  >   print(fs.len())
  >   print(fs[1] < 1.0)
  > EOF
  $ cat > nan_show.ren <<'EOF'
  > fn main() uses Console =
  >   print(1.5)
  >   let xs = [1.0, (0.0 - 1.0).sqrt()]
  >   print(xs.len())
  >   print(xs)
  >   print(2.5)
  > EOF
  $ cat > nan_eq.ren <<'EOF'
  > type P = { x: Float, y: Float }
  > fn main() uses Console =
  >   let z = 0.0
  >   print(P { x: 1.0, y: 2.0 } == P { x: 1.0, y: 2.0 })
  >   print(P { x: 1.0, y: z / z } == P { x: 1.0, y: 2.0 })
  > EOF
  $ cat > nan_round.ren <<'EOF'
  > fn main() uses Console =
  >   let z = 0.0
  >   print((z / z + 1.0).round())
  > EOF
  $ cat > nan_sum.ren <<'EOF'
  > fn main() uses Console =
  >   let z = 0.0
  >   print([1.0, 2.0, 3.0].sum())
  >   let xs = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 1.0 / z, -1.0 / z]
  >   print(xs.sum() > 0.0)
  > EOF
  $ cat > nan_dep.ren <<'EOF'
  > dep Sink =
  >   put: fn(x: Float)
  > 
  > handler ignoring() for Sink =
  >   put(_) => ()
  > 
  > fn main() uses Console =
  >   let z = 0.0
  >   with ignoring() in Sink.put(1.0)
  >   print("once")
  >   with ignoring() in Sink.put(z / z)
  >   print("not reached")
  > EOF
  $ for f in nan_cmp nan_show nan_eq nan_round nan_sum nan_dep; do same $f.ren; nan_release $f.ren; done
  nan_cmp.ren, perceus: the same, exit 1, objects live at exit 1
  nan_cmp.ren, naive: the same, exit 1, objects live at exit 2
  nan_cmp.ren, release: the same, exit 1
  nan_show.ren, perceus: the same, exit 1, objects live at exit 2
  nan_show.ren, naive: the same, exit 1, objects live at exit 2
  nan_show.ren, release: the same, exit 1
  nan_eq.ren, perceus: the same, exit 1, objects live at exit 3
  nan_eq.ren, naive: the same, exit 1, objects live at exit 3
  nan_eq.ren, release: the same, exit 1
  nan_round.ren, perceus: the same, exit 1, objects live at exit 1
  nan_round.ren, naive: the same, exit 1, objects live at exit 1
  nan_round.ren, release: the same, exit 1
  nan_sum.ren, perceus: the same, exit 1, objects live at exit 1
  nan_sum.ren, naive: the same, exit 1, objects live at exit 2
  nan_sum.ren, release: the same, exit 1
  nan_dep.ren, perceus: the same, exit 1, objects live at exit 2
  nan_dep.ren, naive: the same, exit 1, objects live at exit 2
  nan_dep.ren, release: the same, exit 1
  $ ren run nan_show.ren; ren run nan_dep.ren
  1.5
  2
  error: panic: `show` of a NaN made at nan_show.ren:3:18
    ┌─ nan_show.ren:5:3
  5 │   print(xs)
    │   ^^^^^^^^^
  once
  error: panic: `Sink.put` was given a NaN made at nan_dep.ren:11:31
     ┌─ nan_dep.ren:11:31
  11 │   with ignoring() in Sink.put(z / z)
     │                               ^^^^^
  [1]

Comparing a value with a NaN in it panics whether or not the walk
meets the NaN (operators.md, "`Int` and `Float`"): a comparison that
ends early, unequal or ordered, looks through both values, the left's
first (walk.ml, `equal`; ren_rt.c, `ren_equal_any`). So `Some(nan) ==
None`, a constructor against another, arrays of different lengths, a
tuple ordered by its first part, and the same through a generic
function, each panic, in `ren run` and every build alike; and with a
NaN in each, the left's is the one said.

  $ cat > nan_ctor.ren <<'EOF'
  > fn main() uses Console =
  >   let z = 0.0
  >   let a: Option<Float> = Some(1.0)
  >   print(a == None)
  >   let b: Option<Float> = Some(z / z)
  >   print(None != b)
  > EOF
  $ cat > nan_shape.ren <<'EOF'
  > type Shape =
  >   | Dot
  >   | Circle(r: Float)
  > fn same<T>(a: T, b: T) -> Bool = a == b
  > fn main() uses Console =
  >   let z = 0.0
  >   print(same(Circle(1.0), Dot))
  >   print([1.0] == [1.0, 2.0])
  >   print(same(Dot, Circle(z / z)))
  > EOF
  $ cat > nan_len.ren <<'EOF'
  > fn main() uses Console =
  >   let z = 0.0
  >   print([1.0, z / z] == [1.0])
  > EOF
  $ cat > nan_order.ren <<'EOF'
  > fn main() uses Console =
  >   let z = 0.0
  >   print((1, 2.0) < (2, 0.0))
  >   print((1, z / z) < (2, 0.0))
  > EOF
  $ cat > nan_left.ren <<'EOF'
  > fn main() uses Console =
  >   let z = 0.0
  >   let x = -1.0
  >   let b = (2, Some(z / z))
  >   let a = (1, Some(x.sqrt()))
  >   print(a == b)
  > EOF
  $ for f in nan_ctor nan_shape nan_len nan_order nan_left; do same $f.ren; nan_release $f.ren; done
  nan_ctor.ren, perceus: the same, exit 1, objects live at exit 2
  nan_ctor.ren, naive: the same, exit 1, objects live at exit 3
  nan_ctor.ren, release: the same, exit 1
  nan_shape.ren, perceus: the same, exit 1, objects live at exit 2
  nan_shape.ren, naive: the same, exit 1, objects live at exit 2
  nan_shape.ren, release: the same, exit 1
  nan_len.ren, perceus: the same, exit 1, objects live at exit 3
  nan_len.ren, naive: the same, exit 1, objects live at exit 3
  nan_len.ren, release: the same, exit 1
  nan_order.ren, perceus: the same, exit 1, objects live at exit 3
  nan_order.ren, naive: the same, exit 1, objects live at exit 3
  nan_order.ren, release: the same, exit 1
  nan_left.ren, perceus: the same, exit 1, objects live at exit 5
  nan_left.ren, naive: the same, exit 1, objects live at exit 5
  nan_left.ren, release: the same, exit 1
  $ ren run nan_ctor.ren; ren run nan_order.ren; ren run nan_left.ren
  false
  error: panic: `!=` compared a NaN made at nan_ctor.ren:5:31
    ┌─ nan_ctor.ren:6:9
  6 │   print(None != b)
    │         ^^^^^^^^^
  true
  error: panic: `<` compared a NaN made at nan_order.ren:4:13
    ┌─ nan_order.ren:4:9
  4 │   print((1, z / z) < (2, 0.0))
    │         ^^^^^^^^^^^^^^^^^^^^^
  error: panic: `==` compared a NaN made at nan_left.ren:5:20
    ┌─ nan_left.ren:6:9
  6 │   print(a == b)
    │         ^^^^^^
  [1]

An `Int` `+`, `-` or `*` that overflows in a loop panics where it
happens, in every build, as `ren run` does (foundations.md, decision 15;
reporting it late, when the loop ends, was built and dropped). So each
of these prints what `ren run` prints: an overflow whose wrapped number
would index out of bounds, print, run a loop on, or keep a loop going;
two overflows, the first reported; a `break` after one; one in a loop an
array is hoisted out of; and one in a function a loop calls.

  $ cat > late_sum.ren <<'EOF'
  > fn main() uses Console =
  >   var total = 0
  >   var i = 0
  >   while i < 100
  >     total = total + 9223372036854775000 * i
  >     i = i + 1
  >   print(total)
  > EOF
  $ cat > late_index.ren <<'EOF'
  > fn main() uses Console =
  >   let xs = [10, 20, 30]
  >   var k = 4611686018427387904
  >   var i = 0
  >   while i < 10
  >     k = k + k
  >     print(xs[k])
  >     i = i + 1
  > EOF
  $ cat > late_print.ren <<'EOF'
  > fn main() uses Console =
  >   var k = 9223372036854775800
  >   var j = 0
  >   while j < 50
  >     k = k + 1
  >     print(k)
  >     j = j + 1
  > EOF
  $ cat > late_spin.ren <<'EOF'
  > fn main() uses Console =
  >   var n = 1
  >   var steps = 0
  >   while n != 0
  >     n = n * 3
  >     steps = steps + 1
  >   print(steps)
  > EOF
  $ cat > late_inner.ren <<'EOF'
  > fn main() uses Console =
  >   var n = 9223372036854775807
  >   var outer = 0
  >   while outer < 3
  >     var inner = 0
  >     while inner < n
  >       inner = inner + 4611686018427387904
  >     n = n + 1
  >     outer = outer + 1
  >   print(n)
  > EOF
  $ cat > late_two.ren <<'EOF'
  > fn main() uses Console =
  >   var a = 9223372036854775807
  >   var b = -9223372036854775807
  >   var i = 0
  >   while i < 3
  >     b = b - 5
  >     a = a + 1
  >     i = i + 1
  >   print(a)
  > EOF
  $ cat > late_break.ren <<'EOF'
  > fn find(xs: Array<Int>) -> Int =
  >   var acc = 1
  >   for x in xs
  >     acc = acc * x
  >     if acc < 0 then break
  >   acc
  > 
  > fn main() uses Console =
  >   print(find([2, 3]))
  >   print(find([1000000000, 1000000000, 1000000000, 5]))
  > EOF
  $ cat > late_hoisted.ren <<'EOF'
  > fn main() uses Console =
  >   var xs = [5, 6, 7, 8]
  >   var i = 0
  >   while i < 4
  >     xs[i] = xs[i] * 3074457345618258603
  >     i = i + 1
  >   print(xs[0])
  > EOF
  $ cat > late_call.ren <<'EOF'
  > fn grow(n: Int) -> Int = n * 2
  > 
  > fn main() uses Console =
  >   var k = 1
  >   var j = 0
  >   while j < 70
  >     k = grow(k) + 1
  >     j = j + 1
  >   print(k)
  > EOF
  $ for f in late_sum late_index late_print late_spin late_inner late_two late_break late_hoisted late_call; do same $f.ren; release $f.ren; done
  late_sum.ren, perceus: the same, exit 1, objects live at exit 1
  late_sum.ren, naive: the same, exit 1, objects live at exit 1
  late_sum.ren, release: the same, exit 1, objects live at exit 1
  late_index.ren, perceus: the same, exit 1, objects live at exit 2
  late_index.ren, naive: the same, exit 1, objects live at exit 2
  late_index.ren, release: the same, exit 1, objects live at exit 2
  late_print.ren, perceus: the same, exit 1, objects live at exit 1
  late_print.ren, naive: the same, exit 1, objects live at exit 1
  late_print.ren, release: the same, exit 1, objects live at exit 1
  late_spin.ren, perceus: the same, exit 1, objects live at exit 1
  late_spin.ren, naive: the same, exit 1, objects live at exit 1
  late_spin.ren, release: the same, exit 1, objects live at exit 1
  late_inner.ren, perceus: the same, exit 1, objects live at exit 1
  late_inner.ren, naive: the same, exit 1, objects live at exit 1
  late_inner.ren, release: the same, exit 1, objects live at exit 1
  late_two.ren, perceus: the same, exit 1, objects live at exit 1
  late_two.ren, naive: the same, exit 1, objects live at exit 1
  late_two.ren, release: the same, exit 1, objects live at exit 1
  late_break.ren, perceus: the same, exit 1, objects live at exit 2
  late_break.ren, naive: the same, exit 1, objects live at exit 2
  late_break.ren, release: the same, exit 1, objects live at exit 2
  late_hoisted.ren, perceus: the same, exit 1, objects live at exit 2
  late_hoisted.ren, naive: the same, exit 1, objects live at exit 2
  late_hoisted.ren, release: the same, exit 1, objects live at exit 2
  late_call.ren, perceus: the same, exit 1, objects live at exit 1
  late_call.ren, naive: the same, exit 1, objects live at exit 1
  late_call.ren, release: the same, exit 1, objects live at exit 1
  $ ren run late_index.ren; ren run late_two.ren
  error: panic: `+` overflowed: 4611686018427387904 + 4611686018427387904
    ┌─ late_index.ren:6:9
  6 │     k = k + k
    │         ^^^^^
    help: if wrapping is what you mean, write `k +% k`
  error: panic: `-` overflowed: -9223372036854775807 - 5
    ┌─ late_two.ren:6:9
  6 │     b = b - 5
    │         ^^^^^
    help: if wrapping is what you mean, write `b -% 5`
  [1]

`sum` of `Float`s adds in eight lanes, each from 0.0, element i into
lane i mod 8, then the lanes pairwise (prelude.ml, `sum`), in `ren run`
and both builds, which a release build's C compiler can vectorize.
float_sum.ren sums the arrays a generator makes, of every length to
100 and two long ones, through `sum` and through a generic function's,
and each build prints what `ren run` prints.

  $ cat > float_sum.ren <<'EOF'
  > // `sum` of `Float`s, on arrays a generator makes: every length to 100,
  > // and two long ones, of numbers of every size, a few infinite. Each
  > // sum is the same in `ren run` and both builds (prelude.ml, `sum`).
  > fn next(s: Int) -> Int =
  >   s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407)
  > 
  > fn float_of(s: Int) -> Float =
  >   let m = Float.of((s / 1024) % 2000001) / 997.0
  >   let e = ((s / 7) % 6 + 6) % 6
  >   if e == 0 then m * 0.00000001
  >   else if e == 1 then m
  >   else if e == 2 then m * 100000000.0
  >   else if e == 3 then m * 10000000000000000.0
  >   else if e == 4 then m * 0.001
  >   else if s % 4099 == 17 then 1.0 / 0.0
  >   else m * 1000.0
  > 
  > fn total<T>(xs: Array<T>) -> T = xs.sum()
  > 
  > fn main() uses Console =
  >   var s = 42
  >   var n = 0
  >   var lens: Array<Int> = []
  >   while n <= 100
  >     &lens.push(n)
  >     n += 1
  >   &lens.push(10000)
  >   &lens.push(100003)
  >   for len in lens
  >     var xs: Array<Float> = []
  >     var i = 0
  >     while i < len
  >       s = next(s)
  >       &xs.push(float_of(s))
  >       i += 1
  >     print(xs.sum())
  >     print(total(xs))
  > EOF
  $ same float_sum.ren; release float_sum.ren
  float_sum.ren, perceus: the same, exit 0, objects live at exit 0
  float_sum.ren, naive: the same, exit 0, objects live at exit 0
  float_sum.ren, release: the same, exit 0, objects live at exit 0
  $ ren run float_sum.ren | head -12
  0.0
  0.0
  -11153229689067203000.0
  -11153229689067203000.0
  0.000024576970912738214
  0.000024576970912738214
  -15057011033100292000.0
  -15057011033100292000.0
  4204222668004012000.0
  4204222668004012000.0
  49998555369.54821
  49998555369.54821

Debug builds with tcc (foundations.md, decision 13). A debug build
writes its C in units, a few modules' functions each, with no system
header and `#line`s that say which line of Ren each line of C is, and
compiles them in parallel with tcc when it's on PATH or in $REN_TCC
(tools/tcc.sh installs it), linking with tcc's linker. tcc has no
sanitizers. Every program above, built that way, Perceus and naive,
prints exactly what `ren run` prints and exits as it does, with the
same objects alive at the end as clang's build above.

  $ unset REN_CC REN_CFLAGS
  $ command -v tcc > /dev/null || [ -n "$REN_TCC" ] || echo "no tcc: tools/tcc.sh installs it"
  $ REN_PASS_TIMES=1 ren build fib.ren -o ./fib.bin 2>&1 | grep -o 'C compile (.* units, .*tcc)' | sed 's/([0-9]* units, .*tcc)/(units, tcc)/'
  C compile (units, tcc)
  $ tcc_same() {
  >   for rc in perceus naive; do
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    rm -f tcc.bin native.out native.err native.code &&
  >    ren build --stats --rc $rc "$f" -o ./tcc.bin &&
  >    { ./tcc.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    grep -v -e '^ren stats: ' native.err > native.err2;
  >    if cmp -s native.out interp.out && cmp -s native.err2 interp.err &&
  >       cmp -s native.code interp.code
  >    then echo "$1, $rc, tcc: the same, $(cat native.code), $(grep -o 'objects live at exit [0-9]*' native.err)"
  >    else echo "$1, $rc, tcc: different"; diff native.out interp.out; diff native.err2 interp.err
  >    fi)
  >   done
  > }
  $ for f in fib deep loop overflow frames tokens packed values values_panic swap swap_panic swap_order trmc trmc_panic sized sized_panic loops loops_panic loops_short review_arrays review_values review_lists review_shrink walks p_sum p_paren p_far p_div p_index p_assert derived nan_cmp nan_show nan_eq nan_round nan_sum nan_dep nan_ctor nan_shape nan_len nan_order nan_left late_sum late_index late_print late_spin late_inner late_two late_break late_hoisted late_call float_sum 10d/bits 10d/bits_panic 10d/generic 10d/cache 10d/aliases 10d/shapes 10d/router 10d/methods 10d/dispatch 10d/dispatch_mix 10d/dispatch_panic 10d/overany 10d/slices 10d/slices_panic 10d/slices_lent 10d/review_slices 10d/review_deps 11a/trywith 11a/alone 11a/alone_panic 11a/limit 11a/limit_panic data/update data/byname data/orpat data/orpat_strs data/variants data/variants_small data/variants_escape data/variants_reuse data/todo_panic data/shapes data/nested data/rows data/optional data/layout data/layout_walks data/layout_panic data/reuse_arms data/rows_objs data/rows_panic data/niche data/niche_walks data/niche_panic data/niche_reuse data/niche_join data/interp data/review_keys data/review_state data/review_state_panic data/review_todo_panic; do tcc_same $f.ren; done
  fib.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  fib.ren, naive, tcc: the same, exit 0, objects live at exit 0
  deep.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  deep.ren, naive, tcc: the same, exit 0, objects live at exit 0
  loop.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  loop.ren, naive, tcc: the same, exit 0, objects live at exit 0
  overflow.ren, perceus, tcc: the same, exit 1, objects live at exit 0
  overflow.ren, naive, tcc: the same, exit 1, objects live at exit 0
  frames.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  frames.ren, naive, tcc: the same, exit 0, objects live at exit 0
  tokens.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  tokens.ren, naive, tcc: the same, exit 0, objects live at exit 0
  packed.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  packed.ren, naive, tcc: the same, exit 0, objects live at exit 0
  values.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  values.ren, naive, tcc: the same, exit 0, objects live at exit 0
  values_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 4
  values_panic.ren, naive, tcc: the same, exit 1, objects live at exit 4
  swap.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  swap.ren, naive, tcc: the same, exit 0, objects live at exit 0
  swap_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 4
  swap_panic.ren, naive, tcc: the same, exit 1, objects live at exit 4
  swap_order.ren, perceus, tcc: the same, exit 1, objects live at exit 4
  swap_order.ren, naive, tcc: the same, exit 1, objects live at exit 4
  trmc.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  trmc.ren, naive, tcc: the same, exit 0, objects live at exit 0
  trmc_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 11
  trmc_panic.ren, naive, tcc: the same, exit 1, objects live at exit 1
  sized.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  sized.ren, naive, tcc: the same, exit 0, objects live at exit 0
  sized_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  sized_panic.ren, naive, tcc: the same, exit 1, objects live at exit 2
  loops.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  loops.ren, naive, tcc: the same, exit 0, objects live at exit 0
  loops_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 3
  loops_panic.ren, naive, tcc: the same, exit 1, objects live at exit 4
  loops_short.ren, perceus, tcc: the same, exit 1, objects live at exit 6
  loops_short.ren, naive, tcc: the same, exit 1, objects live at exit 6
  review_arrays.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  review_arrays.ren, naive, tcc: the same, exit 0, objects live at exit 0
  review_values.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  review_values.ren, naive, tcc: the same, exit 0, objects live at exit 0
  review_lists.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  review_lists.ren, naive, tcc: the same, exit 0, objects live at exit 0
  review_shrink.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  review_shrink.ren, naive, tcc: the same, exit 1, objects live at exit 3
  walks.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  walks.ren, naive, tcc: the same, exit 0, objects live at exit 0
  p_sum.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  p_sum.ren, naive, tcc: the same, exit 1, objects live at exit 2
  p_paren.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  p_paren.ren, naive, tcc: the same, exit 1, objects live at exit 1
  p_far.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  p_far.ren, naive, tcc: the same, exit 1, objects live at exit 1
  p_div.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  p_div.ren, naive, tcc: the same, exit 1, objects live at exit 1
  p_index.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  p_index.ren, naive, tcc: the same, exit 1, objects live at exit 2
  p_assert.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  p_assert.ren, naive, tcc: the same, exit 1, objects live at exit 1
  derived.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  derived.ren, naive, tcc: the same, exit 0, objects live at exit 0
  nan_cmp.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  nan_cmp.ren, naive, tcc: the same, exit 1, objects live at exit 2
  nan_show.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  nan_show.ren, naive, tcc: the same, exit 1, objects live at exit 2
  nan_eq.ren, perceus, tcc: the same, exit 1, objects live at exit 3
  nan_eq.ren, naive, tcc: the same, exit 1, objects live at exit 3
  nan_round.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  nan_round.ren, naive, tcc: the same, exit 1, objects live at exit 1
  nan_sum.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  nan_sum.ren, naive, tcc: the same, exit 1, objects live at exit 2
  nan_dep.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  nan_dep.ren, naive, tcc: the same, exit 1, objects live at exit 2
  nan_ctor.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  nan_ctor.ren, naive, tcc: the same, exit 1, objects live at exit 3
  nan_shape.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  nan_shape.ren, naive, tcc: the same, exit 1, objects live at exit 2
  nan_len.ren, perceus, tcc: the same, exit 1, objects live at exit 3
  nan_len.ren, naive, tcc: the same, exit 1, objects live at exit 3
  nan_order.ren, perceus, tcc: the same, exit 1, objects live at exit 3
  nan_order.ren, naive, tcc: the same, exit 1, objects live at exit 3
  nan_left.ren, perceus, tcc: the same, exit 1, objects live at exit 5
  nan_left.ren, naive, tcc: the same, exit 1, objects live at exit 5
  late_sum.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  late_sum.ren, naive, tcc: the same, exit 1, objects live at exit 1
  late_index.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  late_index.ren, naive, tcc: the same, exit 1, objects live at exit 2
  late_print.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  late_print.ren, naive, tcc: the same, exit 1, objects live at exit 1
  late_spin.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  late_spin.ren, naive, tcc: the same, exit 1, objects live at exit 1
  late_inner.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  late_inner.ren, naive, tcc: the same, exit 1, objects live at exit 1
  late_two.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  late_two.ren, naive, tcc: the same, exit 1, objects live at exit 1
  late_break.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  late_break.ren, naive, tcc: the same, exit 1, objects live at exit 2
  late_hoisted.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  late_hoisted.ren, naive, tcc: the same, exit 1, objects live at exit 2
  late_call.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  late_call.ren, naive, tcc: the same, exit 1, objects live at exit 1
  float_sum.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  float_sum.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/bits.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/bits.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/bits_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  10d/bits_panic.ren, naive, tcc: the same, exit 1, objects live at exit 1
  10d/generic.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/generic.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/cache.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/cache.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/aliases.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/aliases.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/shapes.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/shapes.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/router.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/router.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/methods.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/methods.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/dispatch.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/dispatch.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/dispatch_mix.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/dispatch_mix.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/dispatch_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  10d/dispatch_panic.ren, naive, tcc: the same, exit 1, objects live at exit 2
  10d/overany.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/overany.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/slices.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/slices.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/slices_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  10d/slices_panic.ren, naive, tcc: the same, exit 1, objects live at exit 1
  10d/slices_lent.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/slices_lent.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/review_slices.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/review_slices.ren, naive, tcc: the same, exit 0, objects live at exit 0
  10d/review_deps.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  10d/review_deps.ren, naive, tcc: the same, exit 0, objects live at exit 0
  11a/trywith.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  11a/trywith.ren, naive, tcc: the same, exit 0, objects live at exit 0
  11a/alone.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  11a/alone.ren, naive, tcc: the same, exit 0, objects live at exit 0
  11a/alone_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 3
  11a/alone_panic.ren, naive, tcc: the same, exit 1, objects live at exit 3
  11a/limit.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  11a/limit.ren, naive, tcc: the same, exit 0, objects live at exit 0
  11a/limit_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 5
  11a/limit_panic.ren, naive, tcc: the same, exit 1, objects live at exit 5
  data/update.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/update.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/byname.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/byname.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/orpat.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/orpat.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/orpat_strs.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/orpat_strs.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/variants.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/variants.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/variants_small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/variants_small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/variants_escape.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/variants_escape.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/variants_reuse.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/variants_reuse.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/todo_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  data/todo_panic.ren, naive, tcc: the same, exit 1, objects live at exit 1
  data/shapes.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/shapes.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/nested.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/nested.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/rows.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/rows.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/optional.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/optional.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/layout.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/layout.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/layout_walks.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/layout_walks.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/layout_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 5
  data/layout_panic.ren, naive, tcc: the same, exit 1, objects live at exit 8
  data/reuse_arms.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/reuse_arms.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/rows_objs.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/rows_objs.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/rows_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 45
  data/rows_panic.ren, naive, tcc: the same, exit 1, objects live at exit 45
  data/niche.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/niche.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/niche_walks.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/niche_walks.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/niche_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 12
  data/niche_panic.ren, naive, tcc: the same, exit 1, objects live at exit 14
  data/niche_reuse.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/niche_reuse.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/niche_join.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/niche_join.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/interp.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/interp.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/review_keys.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/review_keys.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/review_state.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  data/review_state.ren, naive, tcc: the same, exit 0, objects live at exit 0
  data/review_state_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 2
  data/review_state_panic.ren, naive, tcc: the same, exit 1, objects live at exit 2
  data/review_todo_panic.ren, perceus, tcc: the same, exit 1, objects live at exit 1
  data/review_todo_panic.ren, naive, tcc: the same, exit 1, objects live at exit 1
  $ for f in native/*/small.ren ../examples/*.ren ../examples/shop/main.ren ../examples/two/main.ren; do tcc_same $f; done
  native/binary-trees/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/binary-trees/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/bytes/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/bytes/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/inout/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/inout/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/interp/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/interp/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/nbody/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/nbody/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/nested/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/nested/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/slices/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/slices/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/stack/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/stack/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  native/vec/small.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  native/vec/small.ren, naive, tcc: the same, exit 0, objects live at exit 0
  ../examples/blocks.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  ../examples/blocks.ren, naive, tcc: the same, exit 0, objects live at exit 0
  ../examples/fib.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  ../examples/fib.ren, naive, tcc: the same, exit 0, objects live at exit 0
  ../examples/infer.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  ../examples/infer.ren, naive, tcc: the same, exit 0, objects live at exit 0
  ../examples/plans.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  ../examples/plans.ren, naive, tcc: the same, exit 0, objects live at exit 0
  ../examples/values.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  ../examples/values.ren, naive, tcc: the same, exit 0, objects live at exit 0
  ../examples/shop/main.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  ../examples/shop/main.ren, naive, tcc: the same, exit 0, objects live at exit 0
  ../examples/two/main.ren, perceus, tcc: the same, exit 0, objects live at exit 0
  ../examples/two/main.ren, naive, tcc: the same, exit 0, objects live at exit 0

Stage 10d's programs (compiler.md, "Stage 10d"), in 10d/, one or two
for each step that builds what they use: each `.expected` holds what
`ren run` prints, then how it exits, then the first line it writes to
stderr, if any. Until its step lands a program isn't as specified; the
step that lands it changes its line here to say so, and adds it to the
loops above, `same`, `release` and `tcc_same`, which check its native
builds against `ren run` under the sanitizers.

  $ spec() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    { ren run "$f" > spec.out 2> spec.err; echo "exit $?" >> spec.out; } &&
  >    head -n 1 spec.err >> spec.out &&
  >    if cmp -s spec.out "${f%.ren}.expected"
  >    then echo "$1: as specified"
  >    else echo "$1: not yet"
  >    fi)
  > }
  $ for f in bits bits_panic generic shapes router dispatch overany slices slices_panic; do spec 10d/$f.ren; done
  10d/bits.ren: as specified
  10d/bits_panic.ren: as specified
  10d/generic.ren: as specified
  10d/shapes.ren: as specified
  10d/router.ren: as specified
  10d/dispatch.ren: as specified
  10d/overany.ren: as specified
  10d/slices.ren: as specified
  10d/slices_panic.ren: as specified

Step 4's listing of how each dispatch site is lowered, for each
dependency of 10d/dispatch.ren (compiler.md, "Stage 10d", "Dispatch"):
`Seed` a direct call; `Step` the loop in `run` copied per handler;
`Codec` a call through the tag, which is the arm's code; `Pipe`, which
recurses, a call through the table in its arms, and `main`'s call
compare-and-branch.

  $ for d in Seed Step Codec Pipe; do (cd 10d && ren build --release --explain-dispatch $d dispatch.ren -o ./dispatch.bin 2>&1); done
  Seed: 1 handler (lcg dispatch.ren:15), 1 operation (next)
    description: one handler, so no site reads its tag; boxed, the tag then 0 words at most
    dispatch.ren:57  codecs(): s.next(x)  1 handler reaches → direct call  [one handler]
  Step: 3 handlers (inc dispatch.ren:21, dbl :24, sq :27), 1 operation (apply)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 1 word at most
    dispatch.ren:34  run(): s.apply(x)  3 handlers reach → loop copied per handler (inc, dbl, sq; 20 statements a copy), a direct call in each  [the description doesn't change in the loop]
  Codec: 6 handlers (rle dispatch.ren:41, lz :43, huff :45, delta :47, zstd :49, codecs$handler1 :66), 1 operation (cost)
    description: tag = code pointer (one operation); boxed, the tag then 3 words at most
    dispatch.ren:98  main(): c.cost()  6 handlers reach → table call (tag = code pointer)  [more than 4]
  Pipe: 4 handlers (source dispatch.ren:74, merge :76, scale :78, invert :80), 1 operation (pull)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 2 words at most
    dispatch.ren:77  merge(): a.pull()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:77  merge(): b.pull()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:79  scale(): a.pull()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:79  scale(): b.pull()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:81  invert(): a.pull()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:100  main(): pipeline(12, 5).pull()  4 handlers reach → arms inline, compare-and-branch  [4 handlers, at most 4]

And 10d/dispatch_mix.ren's: a set with a handler with state in it,
which the table has no method for and a `with` of one call installs
(since the data stage's step 6 such a set's calls aren't written as
methods, but `with o in Op.run(x)` is the same site); a loop copied
inside another, and one whose copy for a handler with state installs
it; a dependency whose tags are code, installed by a `with`; and a
handler of two dependencies. The listing is a release build's, and
names a dependency the program has.

  $ for d in Op Tally Codec Width Name; do (cd 10d && ren build --release --explain-dispatch $d dispatch_mix.ren -o ./dispatch.bin 2>&1); done
  Op: 6 handlers (o_add dispatch_mix.ren:17, o_sub :19, o_mul :21, o_neg :23, o_id :25, o_seen :28), 1 operation (run)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 1 word at most
    dispatch_mix.ren:89  main(): with o in Op.run(acc)  6 handlers reach → table call  [more than 4]
    dispatch_mix.ren:94  main(): with o in Op.run(i)  6 handlers reach → table call  [more than 4]
    dispatch_mix.ren:118  main(): with p.right in Op.run(10)  6 handlers reach → table call  [more than 4]
    dispatch_mix.ren:119  main(): with p.left in Op.run(r)  6 handlers reach → table call  [more than 4]
  Tally: 3 handlers (t_twice dispatch_mix.ren:37, t_plus :39, t_count :41), 1 operation (add)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 1 word at most
    dispatch_mix.ren:80  total(): with t in Tally.add(y)  3 handlers reach → loop copied per handler (t_twice, t_plus, t_count; 35 statements a copy), a direct call in each  [the description doesn't change in the loop]
    dispatch_mix.ren:102  main(): with t in Tally.add(i)  3 handlers reach → loop copied per handler (t_twice, t_plus, t_count; 34 statements a copy), a direct call in each  [the description doesn't change in the loop]
  Codec: 5 handlers (c_rle dispatch_mix.ren:51, c_lz :53, c_huff :55, c_raw :57, c_none :59), 1 operation (cost)
    description: tag = code pointer (one operation); boxed, the tag then 2 words at most
    dispatch_mix.ren:83  both(): with c in Codec.cost() + Codec.cost()  5 handlers reach → installed through its handler's record  [a `with`'s body isn't copied per handler yet]
    dispatch_mix.ren:110  main(): c.cost()  5 handlers reach → table call (tag = code pointer)  [more than 4]
  Width: 2 handlers (boxed dispatch_mix.ren:68, small :71), 1 operation (width)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 1 word at most
    dispatch_mix.ren:113  main(): b.width()  2 handlers reach → arms inline, compare-and-branch  [2 handlers, at most 4]
    dispatch_mix.ren:116  main(): w.width()  2 handlers reach → arms inline, compare-and-branch  [2 handlers, at most 4]
  Name: 1 handler (boxed dispatch_mix.ren:68), 1 operation (name)
    description: one handler, so no site reads its tag; boxed, the tag then 1 word at most
    dispatch_mix.ren:114  main(): b.name()  1 handler reaches → direct call  [one handler]
  $ (cd 10d && ren build --explain-dispatch Op dispatch_mix.ren -o ./dispatch.bin)
  error: `--explain-dispatch` lists a release build's dispatch
    help: add `--release`
  [2]
  $ (cd 10d && ren build --release --explain-dispatch Nope dispatch_mix.ren -o ./dispatch.bin)
  Nope: no dependency of this name is dispatched over in the release build

Stage 11a's sequential programs (compiler.md, "Stage 11a", "The
tests"), in 11a/, checked as 10d's are: each `.expected` holds what
`ren run` prints, then how it exits, then the first line it writes to
stderr. The step that lands one changes its line here to say so, and
adds it to the loops above that check its native builds against `ren
run`. `trywith` landed in step 1, which refuses a plain `with` that can
fail; its native builds are in those loops. `spawns` landed in step 2,
which runs tasks in `ren run`; it has no native build to check, since
tasks aren't native yet. `limit` landed in step 8, with the standard
library's `sync`: a semaphore and a limit over a dependency need no task,
so they build natively, and `limit_panic` is the standard library's
panic, said at the program's call as `ren run` says it.

  $ for f in trywith alone alone_panic limit limit_panic spawns; do spec 11a/$f.ren; done
  11a/trywith.ren: as specified
  11a/alone.ren: as specified
  11a/alone_panic.ren: as specified
  11a/limit.ren: as specified
  11a/limit_panic.ren: as specified
  11a/spawns.ren: as specified

A program that spawns runs in `ren run`, and `ren build` refuses it
with an error that says tasks aren't native yet, and a help (step 2),
in debug and release alike:

  $ (cd 11a && ren build spawns.ren -o ./spawns.bin 2>&1)
  error: `Async.scope` runs tasks, and tasks aren't native yet
    ┌─ spawns.ren:7:3
  7 │   Async.scope fn(s) =>
    │   ^^^^^^^^^^^^^^^^^^^^
    help: run it with `ren run`, which runs tasks
  [1]
  $ (cd 11a && ren build --release spawns.ren -o ./spawns.bin 2>&1 | head -n 1)
  error: `Async.scope` runs tasks, and tasks aren't native yet

The data stage's programs (compiler.md, "Data stage", "The tests"), in
data/, checked as 10d's and 11a's are: each `.expected` holds what `ren
run` prints, then how it exits, then the first line it writes to
stderr. The step that lands one changes its line here to say so, and
adds it to the loops above that check its native builds against `ren
run`. `nested`, `rows` and `optional` are step 7's kernels, one for each
layout fault: they ran before it, so they're as specified already, and
step 7 measures them before and after its fixes and added them to the
loops, with its own programs (below).
`interp`, the milestone's kernel, and `shapes`, step 6's ADT, needed
only step 2's by-name variants to run, so they're as specified since
step 2; step 6 added `shapes` to the loops, and step 7 measures
`interp` against Rust and adds it.

  $ for f in update byname orpat variants todo_panic shapes nested rows optional interp; do spec data/$f.ren; done
  data/update.ren: as specified
  data/byname.ren: as specified
  data/orpat.ren: as specified
  data/variants.ren: as specified
  data/todo_panic.ren: as specified
  data/shapes.ren: as specified
  data/nested.ren: as specified
  data/rows.ren: as specified
  data/optional.ren: as specified
  data/interp.ren: as specified

An update of a unique record is built over it in place (compiler.md,
"Data stage", "Record update"): the loop at the end of `update` updates
one 1000 times, and Perceus reuse pairs each update with the record it
replaces, so the loop allocates nothing; what's allocated is the rest
of the program's, and each update is a reuse.

  $ (cd data && ren build --release --stats update.ren -o ./update.bin 2>/dev/null && ./update.bin 2>&1 >/dev/null | grep -o 'allocations [0-9]*\|reuses [0-9]*')
  allocations 16
  reuses 1002

A variant type costs nothing when its value is unique (compiler.md,
"Data stage", "Variant types"): its value is its sum's, so `as` binds
the subject itself and `Placed { ..p }` is no code, and an update of
one, `{ ..p, total }`, is built over it in place. The loop of
`variants_reuse` does both 1000 times and allocates nothing: what's
allocated is the rest of the program's, the same in both builds, and
each update is a reuse.

  $ (cd data && for m in debug release; do ren build --$m --stats variants_reuse.ren -o ./reuse.bin 2>/dev/null && ./reuse.bin 2>&1 >/dev/null | grep -o 'allocations [0-9]*\|reuses [0-9]*'; done)
  allocations 4
  reuses 1000
  allocations 4
  reuses 1000

So does one of a sum with a pointer niche (compiler.md, "The layout
fixes (step 7)"): in the debug build `niche_reuse`'s `Plan` is boxed,
and each update is a reuse; in the release build it's two words, no tag,
and the loop allocates nothing and reuses nothing.

  $ (cd data && for m in debug release; do ren build --$m --stats niche_reuse.ren -o ./reuse.bin 2>/dev/null && ./reuse.bin 2>&1 >/dev/null | grep -o 'allocations [0-9]*\|reuses [0-9]*'; done)
  allocations 4
  reuses 1000
  allocations 3
  reuses 0

A `main` that's only a `todo` is generic in what it would give, `fn
main<T>() -> T`, so `$start` calls it at `Unit` (compiler.md, "Data
stage", step 5's choices): it panics at the `todo`, natively as in `ren
run`.

  $ printf 'fn main() = todo\n' > data/todo_main.ren
  $ same data/todo_main.ren; release data/todo_main.ren
  data/todo_main.ren, perceus: the same, exit 1, objects live at exit 0
  data/todo_main.ren, naive: the same, exit 1, objects live at exit 0
  data/todo_main.ren, release: the same, exit 1, objects live at exit 0

The layout fixes (compiler.md, "Data stage", "The layout fixes (step
7)"). A small record or tuple inside a small value is flattened into
its slots: `nested`'s `Draft(u: Unvalidated)` allocates nothing, so the
kernel allocates what the rest of the program does, not one object for
each `Draft`. An array of small records that hold an object keeps them
inline, counted by the mask of their slots that hold objects: `rows`'
100,000 `Line`s allocate nothing, and what's allocated is the array, its
growth, and the rest of the program's. A sum with one constructor that
has fields, one an object, and the rest without has no tag, its object's
slot telling them apart: `optional`'s `Option<Item>` is two words, and
allocates nothing (nor did it once its last line printed fields, not
the option, whose `show` boxed it: it was a tag and two slots).

  $ (cd data && for f in nested rows optional; do ren build --release --stats $f.ren -o ./kernel.bin 2>/dev/null && ./kernel.bin 2>&1 >/dev/null | grep -o 'allocations [0-9]*'; done)
  allocations 4
  allocations 6
  allocations 4

`layout` builds, matches, reads, updates and keeps such values: three
deep, generic, holding a `Str`, one object alone, through `inout`, a
block and arrays; `layout_walks` shows and compares them, which boxes
the types walked; `layout_panic` panics with them alive; and
`reuse_arms` has the three faults of boxed values' counting the others
found: a `match` whose arms are constructors of different sizes, each
building one of the other's size, a field read three times through a
chain, and a `var` updated through its views. `rows_objs` keeps arrays
of records that hold `Str`s, arrays, and a flattened record of a `Str`,
and of a sum of one, and arrays of arrays of them, inline: grown,
shared and changed whole, a field at a time and through `inout`,
sliced, split, mapped and looped over every way; `rows_panic` panics
part way through a loop that changes one in place. `niche` keeps sums
with pointer niches and byte tags, the third fix's: options of a `Str`,
an array and a record in arrays, sums of several constructors without
fields and one with an object, first, last or alone, `Bool`s and sized
ints packed beside a tag, and variant types of niche'd sums, built,
matched with or-patterns and `as`, updated, and through `inout` and a
block; `niche_walks` shows and compares them, which boxes them, keeps
them in records and other sums, which boxes them too, and has an option
of an option, whose inner `None` isn't the outer one's niche, and an
option of a boxed sum, whose `Some(Plain)` is a scalar too;
`niche_panic` panics with them alive; `niche_reuse` round-trips a
niche'd sum's variant type (below); and `niche_join` returns a
constructor without fields on one path and a parameter on another,
which Mem Lint refused in debug builds, where each is boxed, until step
7 taught its join that a constant stands for the reference the other
path holds. Each is in the loops above; here, the release build with the
naive counting too, under the sanitizers.

  $ release_naive() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    REN_CC=cc REN_CFLAGS='-fsanitize=address,undefined' ren build --release --rc naive --stats "$f" -o ./naive.bin 2> naive.made &&
  >    { ./naive.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    grep -v -e '^ren stats: ' -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >      -e '^False positive error reports may follow' \
  >      -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >      native.err > native.err2;
  >    if cmp -s native.out interp.out && cmp -s native.err2 interp.err &&
  >       cmp -s native.code interp.code
  >    then echo "$1, release, naive: the same, $(cat native.code), $(grep -o 'objects live at exit [0-9]*' native.err)"
  >    else echo "$1, release, naive: different"; diff native.out interp.out; diff native.err2 interp.err
  >    fi)
  > }
  $ for f in nested rows optional layout layout_walks layout_panic reuse_arms rows_objs rows_panic niche niche_walks niche_panic niche_reuse niche_join interp review_keys review_state review_state_panic review_todo_panic; do release_naive data/$f.ren; done
  data/nested.ren, release, naive: the same, exit 0, objects live at exit 0
  data/rows.ren, release, naive: the same, exit 0, objects live at exit 0
  data/optional.ren, release, naive: the same, exit 0, objects live at exit 0
  data/layout.ren, release, naive: the same, exit 0, objects live at exit 0
  data/layout_walks.ren, release, naive: the same, exit 0, objects live at exit 0
  data/layout_panic.ren, release, naive: the same, exit 1, objects live at exit 4
  data/reuse_arms.ren, release, naive: the same, exit 0, objects live at exit 0
  data/rows_objs.ren, release, naive: the same, exit 0, objects live at exit 0
  data/rows_panic.ren, release, naive: the same, exit 1, objects live at exit 26
  data/niche.ren, release, naive: the same, exit 0, objects live at exit 0
  data/niche_walks.ren, release, naive: the same, exit 0, objects live at exit 0
  data/niche_panic.ren, release, naive: the same, exit 1, objects live at exit 6
  data/niche_reuse.ren, release, naive: the same, exit 0, objects live at exit 0
  data/niche_join.ren, release, naive: the same, exit 0, objects live at exit 0
  data/interp.ren, release, naive: the same, exit 0, objects live at exit 0
  data/review_keys.ren, release, naive: the same, exit 0, objects live at exit 0
  data/review_state.ren, release, naive: the same, exit 0, objects live at exit 0
  data/review_state_panic.ren, release, naive: the same, exit 1, objects live at exit 2
  data/review_todo_panic.ren, release, naive: the same, exit 1, objects live at exit 1

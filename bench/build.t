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

  $ for f in fib deep loop overflow frames tokens packed values values_panic swap swap_panic swap_order trmc trmc_panic sized sized_panic loops loops_panic loops_short review_arrays review_values review_lists review_shrink 10d/bits 10d/bits_panic 10d/generic 10d/cache 10d/aliases 10d/shapes 10d/router 10d/methods 10d/dispatch 10d/dispatch_mix 10d/dispatch_panic 10d/overany 10d/slices 10d/slices_panic 10d/slices_lent 10d/review_slices 10d/review_deps; do same $f.ren; done
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
  $ for f in fib deep loop overflow frames tokens packed values values_panic swap swap_panic swap_order trmc trmc_panic sized sized_panic loops loops_panic loops_short review_arrays review_values review_lists review_shrink 10d/bits 10d/bits_panic 10d/generic 10d/cache 10d/aliases 10d/shapes 10d/router 10d/methods 10d/dispatch 10d/dispatch_mix 10d/dispatch_panic 10d/overany 10d/slices 10d/slices_panic 10d/slices_lent 10d/review_slices 10d/review_deps; do release $f.ren; done
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
  $ for f in native/*/small.ren; do release $f; done
  native/binary-trees/small.ren, release: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, release: the same, exit 0, objects live at exit 0
  native/bytes/small.ren, release: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, release: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, release: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, release: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, release: the same, exit 0, objects live at exit 0
  native/inout/small.ren, release: the same, exit 0, objects live at exit 0
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
  > type List = Nil | Cons(h: Int, t: List)
  > type T = Leaf | Node(l: T, r: T)
  > 
  > fn count(xs: List) -> Int =
  >   var n = 0
  >   var cur = xs
  >   while true
  >     match cur
  >       Nil => break
  >       Cons(_, t) =>
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
  >       Cons(_, t) =>
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
  >       Cons(h, _) =>
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
  >       Cons(h, t) =>
  >         out = h
  >         cur = t
  >   out
  > 
  > fn main() uses Console =
  >   let xs = Cons(1, Cons(2, Cons(3, Nil)))
  >   print(count(xs) + count_go(xs) * 10 + first(xs) * 100 + last(xs) * 1000)
  >   var t = Node(Node(Leaf, Leaf), Leaf)
  >   var n = 0
  >   var go = true
  >   while go
  >     match t
  >       Leaf => go = false
  >       Node(l, _) =>
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
  $ for f in fib deep loop overflow frames tokens packed values values_panic swap swap_panic swap_order trmc trmc_panic sized sized_panic loops loops_panic loops_short review_arrays review_values review_lists review_shrink walks p_sum p_paren p_far p_div p_index p_assert derived nan_cmp nan_show nan_eq nan_round nan_sum nan_dep nan_ctor nan_shape nan_len nan_order nan_left late_sum late_index late_print late_spin late_inner late_two late_break late_hoisted late_call float_sum 10d/bits 10d/bits_panic 10d/generic 10d/cache 10d/aliases 10d/shapes 10d/router 10d/methods 10d/dispatch 10d/dispatch_mix 10d/dispatch_panic 10d/overany 10d/slices 10d/slices_panic 10d/slices_lent 10d/review_slices 10d/review_deps; do tcc_same $f.ren; done
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
`Shape` a call through the tag, which is the arm's code; `Expr`, which
recurses, a call through the table in its arms, and `main`'s call
compare-and-branch.

  $ for d in Seed Step Shape Expr; do (cd 10d && ren build --release --explain-dispatch $d dispatch.ren -o ./dispatch.bin 2>&1); done
  Seed: 1 handler (lcg dispatch.ren:13), 1 operation (next)
    description: one handler, so no site reads its tag; boxed, the tag then 0 words at most
    dispatch.ren:54  shapes(): s.next(x)  1 handler reaches → direct call  [one handler]
  Step: 3 handlers (inc dispatch.ren:19, dbl :22, sq :25), 1 operation (apply)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 1 word at most
    dispatch.ren:32  run(): s.apply(x)  3 handlers reach → loop copied per handler (inc, dbl, sq; 20 statements a copy), a direct call in each  [the description doesn't change in the loop]
  Shape: 6 handlers (sq_shape dispatch.ren:38, rect :40, tri :42, ring :44, frame :46, shapes$handler1 :63), 1 operation (area)
    description: tag = code pointer (one operation); boxed, the tag then 3 words at most
    dispatch.ren:94  main(): s.area()  6 handlers reach → table call (tag = code pointer)  [more than 4]
  Expr: 4 handlers (num dispatch.ren:70, add :72, mul :74, neg :76), 1 operation (eval)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 2 words at most
    dispatch.ren:73  add(): a.eval()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:73  add(): b.eval()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:75  mul(): a.eval()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:75  mul(): b.eval()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:77  neg(): a.eval()  4 handlers reach → table call  [recursion through its own dependency]
    dispatch.ren:96  main(): tree(12, 5).eval()  4 handlers reach → arms inline, compare-and-branch  [4 handlers, at most 4]

And 10d/dispatch_mix.ren's: a set with a handler with state in it,
which the table has no method for and a call installs; a loop copied
inside another, and one whose copy for a handler with state installs
it; a dependency whose tags are code, installed by a `with`; and a
handler of two dependencies. The listing is a release build's, and
names a dependency the program has.

  $ for d in Op Tally Area Size Label; do (cd 10d && ren build --release --explain-dispatch $d dispatch_mix.ren -o ./dispatch.bin 2>&1); done
  Op: 6 handlers (o_add dispatch_mix.ren:14, o_sub :16, o_mul :18, o_neg :20, o_id :22, o_seen :25), 1 operation (run)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 1 word at most
    dispatch_mix.ren:84  main(): o.run(acc)  6 handlers reach → table call  [more than 4]
    dispatch_mix.ren:89  main(): o.run(i)  6 handlers reach → table call  [more than 4]
    dispatch_mix.ren:113  main(): p.left.run(p.right.run(10))  6 handlers reach → table call  [more than 4]
    dispatch_mix.ren:113  main(): p.right.run(10)  6 handlers reach → table call  [more than 4]
  Tally: 3 handlers (t_twice dispatch_mix.ren:34, t_plus :36, t_count :38), 1 operation (add)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 1 word at most
    dispatch_mix.ren:75  total(): t.add(x + i)  3 handlers reach → loop copied per handler (t_twice, t_plus, t_count; 35 statements a copy), a direct call in each  [the description doesn't change in the loop]
    dispatch_mix.ren:97  main(): t.add(i)  3 handlers reach → loop copied per handler (t_twice, t_plus, t_count; 34 statements a copy), a direct call in each  [the description doesn't change in the loop]
  Area: 5 handlers (a_sq dispatch_mix.ren:47, a_rect :49, a_tri :51, a_line :53, a_zero :55), 1 operation (area)
    description: tag = code pointer (one operation); boxed, the tag then 2 words at most
    dispatch_mix.ren:78  both(): with a in Area.area() + Area.area()  5 handlers reach → installed through its handler's record  [a `with`'s body isn't copied per handler yet]
    dispatch_mix.ren:105  main(): a.area()  5 handlers reach → table call (tag = code pointer)  [more than 4]
  Size: 2 handlers (boxed dispatch_mix.ren:64, small :67), 1 operation (size)
    description: tag = the handler's number, which indexes each operation's table; boxed, the tag then 1 word at most
    dispatch_mix.ren:108  main(): b.size()  2 handlers reach → arms inline, compare-and-branch  [2 handlers, at most 4]
    dispatch_mix.ren:111  main(): s.size()  2 handlers reach → arms inline, compare-and-branch  [2 handlers, at most 4]
  Label: 1 handler (boxed dispatch_mix.ren:64), 1 operation (label)
    description: one handler, so no site reads its tag; boxed, the tag then 1 word at most
    dispatch_mix.ren:109  main(): b.label()  1 handler reaches → direct call  [one handler]
  $ (cd 10d && ren build --explain-dispatch Op dispatch_mix.ren -o ./dispatch.bin)
  error: `--explain-dispatch` lists a release build's dispatch
    help: add `--release`
  [2]
  $ (cd 10d && ren build --release --explain-dispatch Nope dispatch_mix.ren -o ./dispatch.bin)
  Nope: no dependency of this name is dispatched over in the release build

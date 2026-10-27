`ren build` compiles each program the native slice's subset
covers (compiler.md, "Native slice") to a debug binary, with its
statistics and under AddressSanitizer and UndefinedBehaviorSanitizer,
and each prints exactly what `ren run` prints, to stdout and to stderr,
and exits as it does. Each is built twice: with its counting placed
by Perceus, the default, and with the naive counting, `--rc naive`,
and the two print the same. The statistics say no object is still
alive when either ends. Mem Lint checks every program `ren build`
compiles, and its counting, path by path.

  $ export REN_CFLAGS='-fsanitize=address,undefined'
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
deep, which is left out.

  $ for f in fib deep loop overflow; do same $f.ren; done
  fib.ren, perceus: the same, exit 0, objects live at exit 0
  fib.ren, naive: the same, exit 0, objects live at exit 0
  deep.ren, perceus: the same, exit 0, objects live at exit 0
  deep.ren, naive: the same, exit 0, objects live at exit 0
  loop.ren, perceus: the same, exit 0, objects live at exit 0
  loop.ren, naive: the same, exit 0, objects live at exit 0
  overflow.ren, perceus: the same, exit 1, objects live at exit 0
  overflow.ren, naive: the same, exit 1, objects live at exit 0

Every native benchmark, at its small size:

  $ for f in native/*/small.ren; do same $f; done
  native/binary-trees/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/binary-trees/small.ren, naive: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, naive: the same, exit 0, objects live at exit 0
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
  native/nqueens/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, naive: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, naive: the same, exit 0, objects live at exit 0

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

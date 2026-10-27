`ren build` compiles each program the native slice's first-order subset
covers (compiler.md, "Native slice") to a debug binary, with its
statistics and under AddressSanitizer and UndefinedBehaviorSanitizer,
and each prints exactly what `ren run` prints, to stdout and to stderr,
and exits as it does. The statistics say no object is still alive when
it ends. Mem Lint checks every program `ren build` compiles.

  $ export REN_CFLAGS='-fsanitize=address,undefined'
  $ same() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    ren build --debug --stats "$f" -o ./native.bin &&
  >    { ./native.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    grep -v -e '^ren stats: ' -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >      -e '^False positive error reports may follow' \
  >      -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >      native.err > native.err2;
  >    if cmp -s native.out interp.out && cmp -s native.err2 interp.err &&
  >       cmp -s native.code interp.code
  >    then echo "$1: the same, $(cat native.code), $(grep -o 'objects live at exit [0-9]*' native.err)"
  >    else echo "$1: different"; diff native.out interp.out; diff native.err2 interp.err
  >    fi)
  > }

The benchmarks of `bench`. `overflow` reaches the stack-overflow panic,
after which AddressSanitizer warns that it can't clean up a stack that
deep, which is left out.

  $ for f in fib deep loop overflow; do same $f.ren; done
  fib.ren: the same, exit 0, objects live at exit 0
  deep.ren: the same, exit 0, objects live at exit 0
  loop.ren: the same, exit 0, objects live at exit 0
  overflow.ren: the same, exit 1, objects live at exit 0

The native benchmarks that need nothing from native step 3, at their
small size:

  $ for d in binary-trees cfold deriv fannkuch nbody; do same native/$d/small.ren; done
  native/binary-trees/small.ren: the same, exit 0, objects live at exit 0
  native/cfold/small.ren: the same, exit 0, objects live at exit 0
  native/deriv/small.ren: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren: the same, exit 0, objects live at exit 0
  native/nbody/small.ren: the same, exit 0, objects live at exit 0

And the examples in the subset:

  $ for f in blocks fib; do same ../examples/$f.ren; done
  ../examples/blocks.ren: the same, exit 0, objects live at exit 0
  ../examples/fib.ren: the same, exit 0, objects live at exit 0

The rest need native step 3: generic functions, blocks, handlers. Each
says so, at the code that needs it:

  $ cd native/nqueens && ren build small.ren
  error: a call of the generic function `length` isn't in the native slice yet
     ┌─ bench.ren:38:41
  38 │ pub fn run(n: Int) uses Console = print(length(find_solutions(n, n), 0))
     │                                         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `ren build` can't compile this yet
     help: run it with `ren run small.ren`
  [1]

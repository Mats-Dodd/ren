The 4 GiB escape at the edges of the fast paths (compiler.md, "Bytes
stage, part two", "Step 4 (part 3), as built"): strs/escape_edges.ren
takes `[0..0]` of an escape, reads and writes one past its length field
with `at` and layer 3, compares one by `==` with values whose length
fields are its real length and 0, and loops over one whose length is
read once before the loop. As strs_big.t, it needs about 4 GiB natively
and up to 12 GB in `ren run`, so it runs only with REN_BIG_TESTS=1
(bench/dune), on a machine with 13 GB free: `ren run`, then debug
builds with Perceus's counting and the naive one, a release build, and a
release build under AddressSanitizer and UBSan.

  $ export REN_NOTES=0
  $ export ASAN_OPTIONS=detect_stack_use_after_return=0:detect_leaks=0
  $ big() {
  >   (cd strs && f=$1.ren &&
  >    { ren run "$f" > spec.out 2> spec.err; echo "exit $?" >> spec.out; } &&
  >    head -n 1 spec.err >> spec.out &&
  >    if cmp -s spec.out $1.expected; then echo "$f: as specified"; else echo "$f: not yet"; fi
  >    rm -f spec.out spec.err
  >    for b in perceus naive release sanitizers; do
  >      case $b in
  >        perceus | naive) REN_CC=cc ren build --debug --stats --rc $b "$f" -o ./big.bin ;;
  >        release) REN_CC=cc ren build --release --stats "$f" -o ./big.bin ;;
  >        sanitizers) REN_CC=cc REN_CFLAGS='-fsanitize=address,undefined' ren build --release --stats "$f" -o ./big.bin ;;
  >      esac > build.err 2>&1 || { echo "$f, $b: not native yet: $(head -n 1 build.err)"; continue; }
  >      { ./big.bin > big.out 2> big.err; echo "exit $?" >> big.out; } &&
  >      grep -v -e '^ren stats: ' -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >        -e '^False positive error reports may follow' \
  >        -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >        big.err | head -n 1 >> big.out
  >      if cmp -s big.out $1.expected
  >      then echo "$f, $b: as specified, $(grep -o 'objects live at exit [0-9]*' big.err)"
  >      else echo "$f, $b: different"; diff big.out $1.expected
  >      fi
  >    done
  >    rm -f big.bin big.out big.err build.err)
  > }
  $ big escape_edges
  escape_edges.ren: as specified
  escape_edges.ren, perceus: as specified, objects live at exit 0
  escape_edges.ren, naive: as specified, objects live at exit 0
  escape_edges.ren, release: as specified, objects live at exit 0
  escape_edges.ren, sanitizers: as specified, objects live at exit 0

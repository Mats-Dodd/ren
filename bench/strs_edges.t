Step 4's escape, its cost (compiler.md, "Bytes stage, part two", "Step 4
(part 3), as built"): a release build's slices and views check against
the length field alone and send `[0..0]` to the cold path with the
escape, `==` tests for the escape only where the length fields differ
or are 0, a loop reads a string's length once before it, and layer 3's
checks read nothing but the length field until they fail. strs/edges.ren
is those paths on values that aren't the escape, and
strs/edges_view_panic.ren a view's panic on the cold path; the escape's
own are strs_big_edges.t's. As strs.t checks its programs: what `ren
run` prints is as specified, and every native build prints the same
under the sanitizers, with no object alive at the end.

  $ export REN_NOTES=0
  $ spec() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    { ren run "$f" > spec.out 2> spec.err; echo "exit $?" >> spec.out; } &&
  >    head -n 1 spec.err >> spec.out &&
  >    if cmp -s spec.out "${f%.ren}.expected"
  >    then echo "$1: as specified"
  >    else echo "$1: not yet"
  >    fi
  >    rm -f spec.out spec.err)
  > }

  $ for f in edges edges_view_panic; do spec strs/$f.ren; done
  strs/edges.ren: as specified
  strs/edges_view_panic.ren: as specified

  $ export ASAN_OPTIONS=detect_stack_use_after_return=0:detect_leaks=0
  $ native() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    if ! REN_CC=cc ren build --debug "$f" -o ./native.bin > build.err 2>&1
  >    then echo "$1: not native yet: $(head -n 1 build.err)"
  >    else
  >      for b in perceus naive release tcc; do
  >        case $b in
  >          perceus | naive) REN_CC=cc REN_CFLAGS='-fsanitize=address,undefined' ren build --debug --stats --rc $b "$f" -o ./native.bin ;;
  >          release) REN_CC=cc REN_CFLAGS='-fsanitize=address,undefined' ren build --release --stats "$f" -o ./native.bin ;;
  >          tcc) ren build --stats "$f" -o ./native.bin ;;
  >        esac &&
  >        { ./native.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >        grep -v -e '^ren stats: ' -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >          -e '^False positive error reports may follow' \
  >          -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >          native.err > native.err2;
  >        if cmp -s native.out interp.out && cmp -s native.err2 interp.err &&
  >           cmp -s native.code interp.code
  >        then echo "$1, $b: the same, $(cat native.code), $(grep -o 'objects live at exit [0-9]*' native.err)"
  >        else echo "$1, $b: different"; diff native.out interp.out; diff native.err2 interp.err
  >        fi
  >      done
  >      { ren run --release "$f" > spec.out 2> spec.err; echo "exit $?" > spec.code; } &&
  >      if cmp -s spec.out interp.out && cmp -s spec.err interp.err && cmp -s spec.code interp.code
  >      then echo "$1, ren run --release: the same"
  >      else echo "$1, ren run --release: different"
  >      fi
  >    fi
  >    rm -f interp.out interp.err interp.code native.bin native.out native.err native.err2 native.code build.err spec.out spec.err spec.code)
  > }
  $ native strs/edges.ren
  strs/edges.ren, perceus: the same, exit 0, objects live at exit 0
  strs/edges.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 10 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/edges.ren, release: the same, exit 0, objects live at exit 0
  strs/edges.ren, tcc: the same, exit 0, objects live at exit 0
  strs/edges.ren, ren run --release: the same
  $ native strs/edges_view_panic.ren
  strs/edges_view_panic.ren, perceus: the same, exit 1, objects live at exit 2
  strs/edges_view_panic.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 3 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/edges_view_panic.ren, release: the same, exit 1, objects live at exit 2
  strs/edges_view_panic.ren, tcc: the same, exit 1, objects live at exit 2
  strs/edges_view_panic.ren, ren run --release: the same

Step 4's third part (compiler.md, "Bytes stage, part two", "Step 4
(part 3), as built"): maps and sets whose keys or values are `Str` or
`Bytes`, which a release build's entries keep as two words, unboxed,
read by generic code too, and a map's value lent where the map doesn't
change (strs/maps.ren); and maps and generic code of an `opaque Str`
with its own `key`, whose descriptor must say it's counted
(strs/opaque_key.ren, strs/opaque_key_generic.ren, from the soundness
review). As strs.t checks its programs: what `ren run`
prints is as specified, and every native build prints the same under the
sanitizers, with no object alive at the end.

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

  $ for f in maps opaque_key opaque_key_generic; do spec strs/$f.ren; done
  strs/maps.ren: as specified
  strs/opaque_key.ren: as specified
  strs/opaque_key_generic.ren: as specified

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
  $ native strs/maps.ren
  strs/maps.ren, perceus: the same, exit 0, objects live at exit 0
  strs/maps.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 17 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/maps.ren, release: the same, exit 0, objects live at exit 0
  strs/maps.ren, tcc: the same, exit 0, objects live at exit 0
  strs/maps.ren, ren run --release: the same
  $ native strs/opaque_key.ren
  strs/opaque_key.ren, perceus: the same, exit 0, objects live at exit 0
  strs/opaque_key.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 4 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/opaque_key.ren, release: the same, exit 0, objects live at exit 0
  strs/opaque_key.ren, tcc: the same, exit 0, objects live at exit 0
  strs/opaque_key.ren, ren run --release: the same
  $ native strs/opaque_key_generic.ren
  strs/opaque_key_generic.ren, perceus: the same, exit 0, objects live at exit 0
  strs/opaque_key_generic.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 7 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/opaque_key_generic.ren, release: the same, exit 0, objects live at exit 0
  strs/opaque_key_generic.ren, tcc: the same, exit 0, objects live at exit 0
  strs/opaque_key_generic.ren, ren run --release: the same

Generic code kept generic (no specializing, REN_SPEC_BUDGET=0), in a
release build under the sanitizers, counts a `Name` through its
descriptor:

  $ (cd strs && for f in opaque_key opaque_key_generic; do
  >   REN_SPEC_BUDGET=0 REN_CC=cc REN_CFLAGS='-fsanitize=address,undefined' ren build --release --stats $f.ren -o ./native.bin > build.err 2>&1 &&
  >   { ./native.bin > native.out 2> native.err; echo "exit $?" >> native.out; } &&
  >   if cmp -s native.out $f.expected
  >   then echo "$f.ren, release, budget 0: as specified, $(grep -o 'objects live at exit [0-9]*' native.err)"
  >   else echo "$f.ren, release, budget 0: different"; diff native.out $f.expected
  >   fi
  > done; rm -f native.bin native.out native.err build.err)
  opaque_key.ren, release, budget 0: as specified, objects live at exit 0
  opaque_key_generic.ren, release, budget 0: as specified, objects live at exit 0

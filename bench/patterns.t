The patterns stage's programs (compiler.md, "Patterns stage", "The
tests"), in patterns/: string literal patterns and sequence patterns on
`Str` and `Array`, guards falling through, key sets at the generator's
edges and the research's adversarial ones (gen.py writes sizes.ren and
hard.ren, and computes their `.expected` in Python), a keyword lexer's
kernel, and `keys.index` on a constant. Each `.expected` holds what
`ren run` prints, then how it exits, then the first line it writes to
stderr, if any. Until its step lands a program isn't as specified; the
step that lands it changes its line here to say so.

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

Step 1, in `ren run`; `keys.index` already ran there:

  $ for f in strs guards arrays sizes hard lexer index; do spec patterns/$f.ren; done
  patterns/strs.ren: as specified
  patterns/guards.ren: as specified
  patterns/arrays.ren: as specified
  patterns/sizes.ren: as specified
  patterns/hard.ren: as specified
  patterns/lexer.ren: as specified
  patterns/index.ren: as specified

Each program built natively prints what `ren run` prints, to stdout and
stderr, and exits as it does: debug, with Perceus's counting and the
naive one, and release, under AddressSanitizer and UBSan, with no
object alive at the end; release run by `ren run --release` too; and a
debug build compiled by tcc. A program the native build can't compile
yet says so, with the first line of what `ren build` said (step 2).

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
  >          release) REN_CC=cc REN_CFLAGS='-fsanitize=address,undefined' ren build --release --stats "$f" -o ./native.bin 2> /dev/null ;;
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
  $ for f in strs guards arrays sizes hard lexer index; do native patterns/$f.ren; done
  patterns/strs.ren, perceus: the same, exit 0, objects live at exit 0
  patterns/strs.ren, naive: the same, exit 0, objects live at exit 0
  patterns/strs.ren, release: the same, exit 0, objects live at exit 0
  patterns/strs.ren, tcc: the same, exit 0, objects live at exit 0
  patterns/strs.ren, ren run --release: the same
  patterns/guards.ren, perceus: the same, exit 0, objects live at exit 0
  patterns/guards.ren, naive: the same, exit 0, objects live at exit 0
  patterns/guards.ren, release: the same, exit 0, objects live at exit 0
  patterns/guards.ren, tcc: the same, exit 0, objects live at exit 0
  patterns/guards.ren, ren run --release: the same
  patterns/arrays.ren, perceus: the same, exit 0, objects live at exit 0
  patterns/arrays.ren, naive: the same, exit 0, objects live at exit 0
  patterns/arrays.ren, release: the same, exit 0, objects live at exit 0
  patterns/arrays.ren, tcc: the same, exit 0, objects live at exit 0
  patterns/arrays.ren, ren run --release: the same
  patterns/sizes.ren, perceus: the same, exit 0, objects live at exit 0
  patterns/sizes.ren, naive: the same, exit 0, objects live at exit 0
  patterns/sizes.ren, release: the same, exit 0, objects live at exit 0
  patterns/sizes.ren, tcc: the same, exit 0, objects live at exit 0
  patterns/sizes.ren, ren run --release: the same
  patterns/hard.ren, perceus: the same, exit 0, objects live at exit 0
  patterns/hard.ren, naive: the same, exit 0, objects live at exit 0
  patterns/hard.ren, release: the same, exit 0, objects live at exit 0
  patterns/hard.ren, tcc: the same, exit 0, objects live at exit 0
  patterns/hard.ren, ren run --release: the same
  patterns/lexer.ren, perceus: the same, exit 0, objects live at exit 0
  patterns/lexer.ren, naive: the same, exit 0, objects live at exit 0
  patterns/lexer.ren, release: the same, exit 0, objects live at exit 0
  patterns/lexer.ren, tcc: the same, exit 0, objects live at exit 0
  patterns/lexer.ren, ren run --release: the same
  patterns/index.ren, perceus: the same, exit 0, objects live at exit 0
  patterns/index.ren, naive: the same, exit 0, objects live at exit 0
  patterns/index.ren, release: the same, exit 0, objects live at exit 0
  patterns/index.ren, tcc: the same, exit 0, objects live at exit 0
  patterns/index.ren, ren run --release: the same

The keyword kernel of bench/native/keywords at a small size, whose
`check` classifies every query by the chain and by the `match`, which
must agree:

  $ native native/keywords/small.ren
  native/keywords/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/keywords/small.ren, naive: the same, exit 0, objects live at exit 0
  native/keywords/small.ren, release: the same, exit 0, objects live at exit 0
  native/keywords/small.ren, tcc: the same, exit 0, objects live at exit 0
  native/keywords/small.ren, ren run --release: the same

Step 3: a string `match` with two literals or more is looked up through
a perfect hash, in a debug build (the two-word compare) and a release
one; a set the generator can't hash falls back to the 64-bit mix or a
length switch. Each lookup is a function `ren_ph<N>` in the C:

  $ hashed() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    for b in debug release; do
  >      if ren build --$b --emit-c "$f" > out.c 2> /dev/null && grep -q 'ren_ph[0-9]* *(' out.c
  >      then echo "$1, $b: hashed, $(grep -c '^static .*ren_ph[0-9]*(' out.c) lookups"
  >      else echo "$1, $b: not hashed yet"
  >      fi
  >    done; rm -f out.c)
  > }
  $ for f in strs guards lexer sizes hard; do hashed patterns/$f.ren; done
  patterns/strs.ren, debug: not hashed yet
  patterns/strs.ren, release: not hashed yet
  patterns/guards.ren, debug: not hashed yet
  patterns/guards.ren, release: not hashed yet
  patterns/lexer.ren, debug: not hashed yet
  patterns/lexer.ren, release: not hashed yet
  patterns/sizes.ren, debug: not hashed yet
  patterns/sizes.ren, release: not hashed yet
  patterns/hard.ren, debug: not hashed yet
  patterns/hard.ren, release: not hashed yet

Step 4: `keys.index(s)` on an array literal of string literals is the
same lookup in a release build; a debug build calls the method:

  $ hashed patterns/index.ren
  patterns/index.ren, debug: not hashed yet
  patterns/index.ren, release: not hashed yet

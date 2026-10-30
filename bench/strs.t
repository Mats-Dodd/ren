The bytes stage's part two (compiler.md, "Bytes stage, part two", "The
tests"), in strs/: the boundary (`InvalidUtf8(at, incomplete)`, lossy),
strings.md's API, interpolation, appending in place, and slices kept
past their root, which representation B keeps as values. Each
`.expected` holds what `ren run` prints, then how it exits, then the
first line it writes to stderr, if any. Until its step lands a program
isn't as specified; the step that lands it changes its line here to say
so. strs/escape.ren, the 4 GiB escape, needs 8 GiB, and is in
strs_big.t.

Debug builds report a `+=` that copied a shared string, at exit, on
stderr, which `ren run` doesn't, so the comparisons below ask them not
to; the report's own test, at the end, doesn't.

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

Step 1, the boundary:

  $ spec strs/invalid_utf8.ren
  strs/invalid_utf8.ren: as specified

Step 2, the API; and appending, slices kept and their counts, which
need step 2's `+=` and interpolation, and whose meaning steps 3 and 4
don't change:

  $ for f in api api_cut_panic api_cut_start_panic api_code_panic api_code_empty_panic api_of_code_panic api_floor_panic interp; do spec strs/$f.ren; done
  strs/api.ren: not yet
  strs/api_cut_panic.ren: not yet
  strs/api_cut_start_panic.ren: not yet
  strs/api_code_panic.ren: not yet
  strs/api_code_empty_panic.ren: not yet
  strs/api_of_code_panic.ren: not yet
  strs/api_floor_panic.ren: not yet
  strs/interp.ren: not yet
  $ for f in append append_count append_report slices_kept slices_count; do spec strs/$f.ren; done
  strs/append.ren: not yet
  strs/append_count.ren: not yet
  strs/append_report.ren: not yet
  strs/slices_kept.ren: not yet
  strs/slices_count.ren: not yet

Step 5, the rest of the API:

  $ spec strs/rest.ren
  strs/rest.ren: not yet

Each program built natively prints what `ren run` prints, to stdout and
stderr, and exits as it does: debug, with Perceus's counting and the
naive one, and release, under AddressSanitizer and UBSan, with no
object alive at the end; release run by `ren run --release` too; and a
debug build compiled by tcc, as bench/build.t checks its programs. A
program the native build can't compile yet says so, with the first
line of what `ren build` said.

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
  $ native strs/invalid_utf8.ren
  strs/invalid_utf8.ren, perceus: the same, exit 0, objects live at exit 0
  strs/invalid_utf8.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 13 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/invalid_utf8.ren, release: the same, exit 0, objects live at exit 0
  strs/invalid_utf8.ren, tcc: the same, exit 0, objects live at exit 0
  strs/invalid_utf8.ren, ren run --release: the same
  $ for f in api api_cut_panic api_cut_start_panic api_code_panic api_code_empty_panic api_of_code_panic api_floor_panic interp; do native strs/$f.ren; done
  strs/api.ren: not native yet: error: unexpected character `'`
  strs/api_cut_panic.ren: not native yet: error: `Str` has no method named `char_floor`
  strs/api_cut_start_panic.ren: not native yet: error: `Str` has no method named `char_ceil`
  strs/api_code_panic.ren: not native yet: error: `Str` has no method named `code`
  strs/api_code_empty_panic.ren: not native yet: error: `Str` has no method named `code`
  strs/api_of_code_panic.ren: not native yet: error: `Str` has no member named `of_code`
  strs/api_floor_panic.ren: not native yet: error: `Str` has no method named `char_floor`
  strs/interp.ren: not native yet: error: `\{` isn't an escape
  $ for f in append append_count append_report slices_kept slices_count; do native strs/$f.ren; done
  strs/append.ren: not native yet: error: `Str` has no `+`
  strs/append_count.ren: not native yet: error: `Str` has no `+`
  strs/append_report.ren: not native yet: error: `Str` has no `+`
  strs/slices_kept.ren: not native yet: error: `\{` isn't an escape
  strs/slices_count.ren: not native yet: error: unexpected character `'`
  $ native strs/rest.ren
  strs/rest.ren: not native yet: error: `\{` isn't an escape

What a build allocates (`--stats`), which `ren run` can't show. Step 3:
20,000 appends to a string nothing else holds, and to `Bytes`, grow
their buffers in place, a few dozen objects in every build, not one an
append. Step 4: 10,000 slices kept in an array allocate nothing in a
release build, which keeps each as a value; a debug build keeps each an
object (representation A).

  $ objects() {
  >   (cd strs && if ! REN_CC=cc ren build "$@" -o ./count.bin > build.err 2>&1
  >    then echo "not native yet: $(head -n 1 build.err)"
  >    else n=$(./count.bin 2>&1 >/dev/null | sed -n 's/^ren stats: allocations \([0-9]*\),.*/\1/p')
  >      if [ "$n" -lt 200 ]; then echo "fewer than 200 objects"; else echo "200 objects or more"; fi
  >    fi; rm -f count.bin build.err)
  > }
  $ objects --debug --stats append_count.ren
  not native yet: error: `Str` has no `+`
  $ objects --release --stats append_count.ren
  not native yet: error: `Str` has no `+`
  $ objects --release --stats slices_count.ren
  not native yet: error: unexpected character `'`
  $ objects --debug --stats slices_count.ren
  not native yet: error: unexpected character `'`

The report (step 3): a debug build of append_report.ren says, once, at
a normal exit, that its first loop's `+=` copied a string something
else held on each pass, and nothing of its second, which copied only a
literal on its first. `REN_NOTES=0` silences it, and a release build
has no report.

  $ (cd strs && for b in debug release; do
  >    if ! REN_CC=cc ren build --$b append_report.ren -o ./report.bin > build.err 2>&1
  >    then echo "$b: not native yet: $(head -n 1 build.err)"
  >    else echo "$b:"; env -u REN_NOTES ./report.bin; echo "exit $?"; echo "$b, REN_NOTES=0:"; ./report.bin > /dev/null
  >    fi
  >  done; rm -f report.bin build.err)
  debug: not native yet: error: `Str` has no `+`
  release: not native yet: error: `Str` has no `+`

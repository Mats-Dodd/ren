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
  strs/api.ren: as specified
  strs/api_cut_panic.ren: as specified
  strs/api_cut_start_panic.ren: as specified
  strs/api_code_panic.ren: as specified
  strs/api_code_empty_panic.ren: as specified
  strs/api_of_code_panic.ren: as specified
  strs/api_floor_panic.ren: as specified
  strs/interp.ren: as specified
  $ for f in append append_count append_report slices_kept slices_count; do spec strs/$f.ren; done
  strs/append.ren: as specified
  strs/append_count.ren: as specified
  strs/append_report.ren: as specified
  strs/slices_kept.ren: as specified
  strs/slices_count.ren: as specified

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
  ren specialized: 14 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/invalid_utf8.ren, release: the same, exit 0, objects live at exit 0
  strs/invalid_utf8.ren, tcc: the same, exit 0, objects live at exit 0
  strs/invalid_utf8.ren, ren run --release: the same
  $ for f in api api_cut_panic api_cut_start_panic api_code_panic api_code_empty_panic api_of_code_panic api_floor_panic interp; do native strs/$f.ren; done
  strs/api.ren, perceus: the same, exit 0, objects live at exit 0
  strs/api.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 19 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/api.ren, release: the same, exit 0, objects live at exit 0
  strs/api.ren, tcc: the same, exit 0, objects live at exit 0
  strs/api.ren, ren run --release: the same
  strs/api_cut_panic.ren, perceus: the same, exit 1, objects live at exit 1
  strs/api_cut_panic.ren, naive: the same, exit 1, objects live at exit 1
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/api_cut_panic.ren, release: the same, exit 1, objects live at exit 1
  strs/api_cut_panic.ren, tcc: the same, exit 1, objects live at exit 1
  strs/api_cut_panic.ren, ren run --release: the same
  strs/api_cut_start_panic.ren, perceus: the same, exit 1, objects live at exit 1
  strs/api_cut_start_panic.ren, naive: the same, exit 1, objects live at exit 1
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/api_cut_start_panic.ren, release: the same, exit 1, objects live at exit 1
  strs/api_cut_start_panic.ren, tcc: the same, exit 1, objects live at exit 1
  strs/api_cut_start_panic.ren, ren run --release: the same
  strs/api_code_panic.ren, perceus: the same, exit 1, objects live at exit 1
  strs/api_code_panic.ren, naive: the same, exit 1, objects live at exit 1
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/api_code_panic.ren, release: the same, exit 1, objects live at exit 1
  strs/api_code_panic.ren, tcc: the same, exit 1, objects live at exit 1
  strs/api_code_panic.ren, ren run --release: the same
  strs/api_code_empty_panic.ren, perceus: the same, exit 1, objects live at exit 1
  strs/api_code_empty_panic.ren, naive: the same, exit 1, objects live at exit 1
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/api_code_empty_panic.ren, release: the same, exit 1, objects live at exit 1
  strs/api_code_empty_panic.ren, tcc: the same, exit 1, objects live at exit 1
  strs/api_code_empty_panic.ren, ren run --release: the same
  strs/api_of_code_panic.ren, perceus: the same, exit 1, objects live at exit 1
  strs/api_of_code_panic.ren, naive: the same, exit 1, objects live at exit 1
  ren specialized: 3 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/api_of_code_panic.ren, release: the same, exit 1, objects live at exit 1
  strs/api_of_code_panic.ren, tcc: the same, exit 1, objects live at exit 1
  strs/api_of_code_panic.ren, ren run --release: the same
  strs/api_floor_panic.ren, perceus: the same, exit 1, objects live at exit 1
  strs/api_floor_panic.ren, naive: the same, exit 1, objects live at exit 1
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/api_floor_panic.ren, release: the same, exit 1, objects live at exit 1
  strs/api_floor_panic.ren, tcc: the same, exit 1, objects live at exit 1
  strs/api_floor_panic.ren, ren run --release: the same
  strs/interp.ren, perceus: the same, exit 0, objects live at exit 0
  strs/interp.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 3 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/interp.ren, release: the same, exit 0, objects live at exit 0
  strs/interp.ren, tcc: the same, exit 0, objects live at exit 0
  strs/interp.ren, ren run --release: the same
  $ for f in append append_count append_report slices_kept slices_count; do native strs/$f.ren; done
  strs/append.ren, perceus: the same, exit 0, objects live at exit 0
  strs/append.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 10 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/append.ren, release: the same, exit 0, objects live at exit 0
  strs/append.ren, tcc: the same, exit 0, objects live at exit 0
  strs/append.ren, ren run --release: the same
  strs/append_count.ren, perceus: the same, exit 0, objects live at exit 0
  strs/append_count.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/append_count.ren, release: the same, exit 0, objects live at exit 0
  strs/append_count.ren, tcc: the same, exit 0, objects live at exit 0
  strs/append_count.ren, ren run --release: the same
  strs/append_report.ren, perceus: the same, exit 0, objects live at exit 0
  strs/append_report.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/append_report.ren, release: the same, exit 0, objects live at exit 0
  strs/append_report.ren, tcc: the same, exit 0, objects live at exit 0
  strs/append_report.ren, ren run --release: the same
  strs/slices_kept.ren, perceus: the same, exit 0, objects live at exit 0
  strs/slices_kept.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 13 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/slices_kept.ren, release: the same, exit 0, objects live at exit 0
  strs/slices_kept.ren, tcc: the same, exit 0, objects live at exit 0
  strs/slices_kept.ren, ren run --release: the same
  strs/slices_count.ren, perceus: the same, exit 0, objects live at exit 0
  strs/slices_count.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 3 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  strs/slices_count.ren, release: the same, exit 0, objects live at exit 0
  strs/slices_count.ren, tcc: the same, exit 0, objects live at exit 0
  strs/slices_count.ren, ren run --release: the same
  $ native strs/rest.ren
  strs/rest.ren: not native yet: error: `Str` has no method named `includes`

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
  fewer than 200 objects
  $ objects --release --stats append_count.ren
  fewer than 200 objects
  $ objects --release --stats slices_count.ren
  fewer than 200 objects
  $ objects --debug --stats slices_count.ren
  200 objects or more

The report (step 3): a debug build of append_report.ren says, once, at
a normal exit, that its first loop's `+=` copied a string something
else held on each pass after its first (which copied the literal), and
nothing of its second, which copied only a literal on its first. `REN_NOTES=0` silences it, and a release build
has no report.

  $ (cd strs && for b in debug release; do
  >    if ! REN_CC=cc ren build --$b append_report.ren -o ./report.bin > build.err 2>&1
  >    then echo "$b: not native yet: $(head -n 1 build.err)"
  >    else echo "$b:"; env -u REN_NOTES ./report.bin; echo "exit $?"; echo "$b, REN_NOTES=0:"; ./report.bin > /dev/null
  >    fi
  >  done; rm -f report.bin build.err)
  debug:
  101
  100
  101
  note: this `+=` copied its string on 99 passes, since something else held it
     ┌─ append_report.ren:13:5
  13 │     out += "x"
     │     ^^^^^^^^^^
     help: build the string once: join, or keep it unique
  exit 0
  debug, REN_NOTES=0:
  release:
  101
  100
  101
  exit 0
  release, REN_NOTES=0:

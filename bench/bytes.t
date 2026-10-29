The bytes stage's programs (compiler.md, "Bytes stage", "The tests"),
in bytes/: layer 3 of formats.md, reads and writes at an offset, the
cursor and `VarUInt`; and `Map` and `Set` natively, with `x.hash()`.
Each `.expected` holds what `ren run` prints, then how it exits, then
the first line it writes to stderr, if any. Until its step lands a
program isn't as specified; the step that lands it changes its line
here to say so.

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

Layer 3 lands in step 2. `Map` and `Set` already run in the
interpreter, so their programs are as specified there; `x.hash()` lands
in step 3.

  $ for f in reads reads_panic reads_negative reads_far u64_panic writes writes_panic writes_range varint varint_panic cursor; do spec bytes/$f.ren; done
  bytes/reads.ren: not yet
  bytes/reads_panic.ren: not yet
  bytes/reads_negative.ren: not yet
  bytes/reads_far.ren: not yet
  bytes/u64_panic.ren: not yet
  bytes/writes.ren: not yet
  bytes/writes_panic.ren: not yet
  bytes/writes_range.ren: not yet
  bytes/varint.ren: not yet
  bytes/varint_panic.ren: not yet
  bytes/cursor.ren: not yet
  $ for f in map set map_key hash; do spec bytes/$f.ren; done
  bytes/map.ren: as specified
  bytes/set.ren: as specified
  bytes/map_key.ren: as specified
  bytes/hash.ren: not yet

`x.hash()` has no seed, so two runs print the same values (step 3):

  $ (cd bytes && ren run hash_values.ren > one.out 2>&1; a=$?; ren run hash_values.ren > two.out 2>&1;
  >  if [ $a -eq 0 ] && cmp -s one.out two.out; then echo "the same on every run"; else echo "not yet"; fi; rm -f one.out two.out)
  not yet

Each program built natively prints what `ren run` prints, to stdout and
stderr, and exits as it does: debug, with Perceus's counting and the
naive one, and release, under AddressSanitizer and UBSan, with no
object alive at the end; release run by `ren run --release` too; and a
debug build compiled by tcc, as bench/build.t checks its programs. A
program the native build can't compile yet says so, with the first
line of what `ren build` said. Layer 3 lands natively in step 2, `Map`,
`Set` and `x.hash()` in step 3.

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
  $ for f in reads reads_panic reads_negative reads_far u64_panic writes writes_panic writes_range varint varint_panic cursor; do native bytes/$f.ren; done
  bytes/reads.ren: not native yet: error: `Bytes` has no method named `u8`
  bytes/reads_panic.ren: not native yet: error: `Bytes` has no method named `u32_le`
  bytes/reads_negative.ren: not native yet: error: `Bytes` has no method named `u16_be`
  bytes/reads_far.ren: not native yet: error: `Bytes` has no method named `u64_le`
  bytes/u64_panic.ren: not native yet: error: `Bytes` has no method named `i64_le`
  bytes/writes.ren: not native yet: error: `Bytes` has no member named `zeros`
  bytes/writes_panic.ren: not native yet: error: `Bytes` has no member named `zeros`
  bytes/writes_range.ren: not native yet: error: `Bytes` has no member named `zeros`
  bytes/varint.ren: not native yet: error: `Bytes` has no member named `varint_size`
  bytes/varint_panic.ren: not native yet: error: `Bytes` has no member named `zeros`
  bytes/cursor.ren: not native yet: error: there's no type named `ByteCursor`
  $ for f in map set map_key hash hash_values; do native bytes/$f.ren; done
  bytes/map.ren: not native yet: error: the associated value `Map.empty` of a generic type isn't in the native slice yet
  bytes/set.ren: not native yet: error: the associated value `Set.empty` of a generic type isn't in the native slice yet
  bytes/map_key.ren: not native yet: error: the associated value `Map.empty` of a generic type isn't in the native slice yet
  bytes/hash.ren: not native yet: error: `Int` has no method named `hash`
  bytes/hash_values.ren: not native yet: error: `Int` has no method named `hash`

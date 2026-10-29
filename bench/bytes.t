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

Step 1's proofs, which a native build doesn't check, and the reads and
steps they leave checked:

  $ for f in proofs proofs_ref proofs_step proofs_negative; do spec bytes/$f.ren; done
  bytes/proofs.ren: as specified
  bytes/proofs_ref.ren: as specified
  bytes/proofs_step.ren: as specified
  bytes/proofs_negative.ren: as specified

Layer 3 landed in step 2. `Map` and `Set` already ran in the
interpreter; `x.hash()` landed in step 3, and hash_values.expected pins
its values.

  $ for f in reads reads_panic reads_negative reads_far u64_panic writes writes_panic writes_range varint varint_panic cursor writes_loop writes_alias; do spec bytes/$f.ren; done
  bytes/reads.ren: as specified
  bytes/reads_panic.ren: as specified
  bytes/reads_negative.ren: as specified
  bytes/reads_far.ren: as specified
  bytes/u64_panic.ren: as specified
  bytes/writes.ren: as specified
  bytes/writes_panic.ren: as specified
  bytes/writes_range.ren: as specified
  bytes/varint.ren: as specified
  bytes/varint_panic.ren: as specified
  bytes/cursor.ren: as specified
  bytes/writes_loop.ren: as specified
  bytes/writes_alias.ren: as specified
  $ for f in map set map_key hash hash_values; do spec bytes/$f.ren; done
  bytes/map.ren: as specified
  bytes/set.ren: as specified
  bytes/map_key.ren: as specified
  bytes/hash.ren: as specified
  bytes/hash_values.ren: as specified

Added in step 3: maps and sets at their edges, grown and emptied while
a loop goes over them, of a generic function's keys, of sized and
struct keys and values, in a record and in a map; and a failed `assert`
of the prelude's, which a native build says as `ren run` does.

  $ for f in map_edges take_panic; do spec bytes/$f.ren; done
  bytes/map_edges.ren: as specified
  bytes/take_panic.ren: as specified

`x.hash()` has no seed, so two runs print the same values (step 3):

  $ (cd bytes && ren run hash_values.ren > one.out 2>&1; a=$?; ren run hash_values.ren > two.out 2>&1;
  >  if [ $a -eq 0 ] && cmp -s one.out two.out; then echo "the same on every run"; else echo "not yet"; fi; rm -f one.out two.out)
  the same on every run

Each program built natively prints what `ren run` prints, to stdout and
stderr, and exits as it does: debug, with Perceus's counting and the
naive one, and release, under AddressSanitizer and UBSan, with no
object alive at the end; release run by `ren run --release` too; and a
debug build compiled by tcc, as bench/build.t checks its programs. A
program the native build can't compile yet says so, with the first
line of what `ren build` said. Layer 3 landed natively in step 2, `Map`,
`Set` and `x.hash()` landed in step 3.

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
  $ for f in proofs proofs_ref proofs_step proofs_negative; do native bytes/$f.ren; done
  bytes/proofs.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/proofs.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 8 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/proofs.ren, release: the same, exit 0, objects live at exit 0
  bytes/proofs.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/proofs.ren, ren run --release: the same
  bytes/proofs_ref.ren, perceus: the same, exit 1, objects live at exit 2
  bytes/proofs_ref.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 3 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/proofs_ref.ren, release: the same, exit 1, objects live at exit 2
  bytes/proofs_ref.ren, tcc: the same, exit 1, objects live at exit 2
  bytes/proofs_ref.ren, ren run --release: the same
  bytes/proofs_step.ren, perceus: the same, exit 1, objects live at exit 1
  bytes/proofs_step.ren, naive: the same, exit 1, objects live at exit 1
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/proofs_step.ren, release: the same, exit 1, objects live at exit 1
  bytes/proofs_step.ren, tcc: the same, exit 1, objects live at exit 1
  bytes/proofs_step.ren, ren run --release: the same
  bytes/proofs_negative.ren, perceus: the same, exit 1, objects live at exit 1
  bytes/proofs_negative.ren, naive: the same, exit 1, objects live at exit 1
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/proofs_negative.ren, release: the same, exit 1, objects live at exit 1
  bytes/proofs_negative.ren, tcc: the same, exit 1, objects live at exit 1
  bytes/proofs_negative.ren, ren run --release: the same
  $ for f in reads reads_panic reads_negative reads_far u64_panic writes writes_panic writes_range varint varint_panic cursor writes_loop writes_alias; do native bytes/$f.ren; done
  bytes/reads.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/reads.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 3 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/reads.ren, release: the same, exit 0, objects live at exit 0
  bytes/reads.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/reads.ren, ren run --release: the same
  bytes/reads_panic.ren, perceus: the same, exit 1, objects live at exit 2
  bytes/reads_panic.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/reads_panic.ren, release: the same, exit 1, objects live at exit 2
  bytes/reads_panic.ren, tcc: the same, exit 1, objects live at exit 2
  bytes/reads_panic.ren, ren run --release: the same
  bytes/reads_negative.ren, perceus: the same, exit 1, objects live at exit 2
  bytes/reads_negative.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/reads_negative.ren, release: the same, exit 1, objects live at exit 2
  bytes/reads_negative.ren, tcc: the same, exit 1, objects live at exit 2
  bytes/reads_negative.ren, ren run --release: the same
  bytes/reads_far.ren, perceus: the same, exit 1, objects live at exit 2
  bytes/reads_far.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/reads_far.ren, release: the same, exit 1, objects live at exit 2
  bytes/reads_far.ren, tcc: the same, exit 1, objects live at exit 2
  bytes/reads_far.ren, ren run --release: the same
  bytes/u64_panic.ren, perceus: the same, exit 1, objects live at exit 1
  bytes/u64_panic.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/u64_panic.ren, release: the same, exit 1, objects live at exit 1
  bytes/u64_panic.ren, tcc: the same, exit 1, objects live at exit 1
  bytes/u64_panic.ren, ren run --release: the same
  bytes/writes.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/writes.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 4 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/writes.ren, release: the same, exit 0, objects live at exit 0
  bytes/writes.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/writes.ren, ren run --release: the same
  bytes/writes_panic.ren, perceus: the same, exit 1, objects live at exit 2
  bytes/writes_panic.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/writes_panic.ren, release: the same, exit 1, objects live at exit 2
  bytes/writes_panic.ren, tcc: the same, exit 1, objects live at exit 2
  bytes/writes_panic.ren, ren run --release: the same
  bytes/writes_range.ren, perceus: the same, exit 1, objects live at exit 2
  bytes/writes_range.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/writes_range.ren, release: the same, exit 1, objects live at exit 2
  bytes/writes_range.ren, tcc: the same, exit 1, objects live at exit 2
  bytes/writes_range.ren, ren run --release: the same
  bytes/varint.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/varint.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 15 copies, 2 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/varint.ren, release: the same, exit 0, objects live at exit 0
  bytes/varint.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/varint.ren, ren run --release: the same
  bytes/varint_panic.ren, perceus: the same, exit 1, objects live at exit 2
  bytes/varint_panic.ren, naive: the same, exit 1, objects live at exit 2
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/varint_panic.ren, release: the same, exit 1, objects live at exit 2
  bytes/varint_panic.ren, tcc: the same, exit 1, objects live at exit 2
  bytes/varint_panic.ren, ren run --release: the same
  bytes/cursor.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/cursor.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 30 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/cursor.ren, release: the same, exit 0, objects live at exit 0
  bytes/cursor.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/cursor.ren, ren run --release: the same
  bytes/writes_loop.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/writes_loop.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 3 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/writes_loop.ren, release: the same, exit 0, objects live at exit 0
  bytes/writes_loop.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/writes_loop.ren, ren run --release: the same
  bytes/writes_alias.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/writes_alias.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 8 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/writes_alias.ren, release: the same, exit 0, objects live at exit 0
  bytes/writes_alias.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/writes_alias.ren, ren run --release: the same
  $ for f in map set map_key hash hash_values; do native bytes/$f.ren; done
  bytes/map.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/map.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 38 copies, 5 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/map.ren, release: the same, exit 0, objects live at exit 0
  bytes/map.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/map.ren, ren run --release: the same
  bytes/set.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/set.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 21 copies, 2 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/set.ren, release: the same, exit 0, objects live at exit 0
  bytes/set.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/set.ren, ren run --release: the same
  bytes/map_key.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/map_key.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 7 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/map_key.ren, release: the same, exit 0, objects live at exit 0
  bytes/map_key.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/map_key.ren, ren run --release: the same
  bytes/hash.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/hash.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 3 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/hash.ren, release: the same, exit 0, objects live at exit 0
  bytes/hash.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/hash.ren, ren run --release: the same
  bytes/hash_values.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/hash_values.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 2 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/hash_values.ren, release: the same, exit 0, objects live at exit 0
  bytes/hash_values.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/hash_values.ren, ren run --release: the same
  $ for f in map_edges take_panic; do native bytes/$f.ren; done
  bytes/map_edges.ren, perceus: the same, exit 0, objects live at exit 0
  bytes/map_edges.ren, naive: the same, exit 0, objects live at exit 0
  ren specialized: 30 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/map_edges.ren, release: the same, exit 0, objects live at exit 0
  bytes/map_edges.ren, tcc: the same, exit 0, objects live at exit 0
  bytes/map_edges.ren, ren run --release: the same
  bytes/take_panic.ren, perceus: the same, exit 1, objects live at exit 7
  bytes/take_panic.ren, naive: the same, exit 1, objects live at exit 7
  ren specialized: 5 copies, 0 blocks lifted, 0 handlers known, 0 calls past the size budget
  bytes/take_panic.ren, release: the same, exit 1, objects live at exit 6
  bytes/take_panic.ren, tcc: the same, exit 1, objects live at exit 7
  bytes/take_panic.ren, ren run --release: the same

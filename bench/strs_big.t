The 4 GiB escape (compiler.md, "Bytes stage, part two", "The tests"):
strs/escape.ren makes `Bytes` of 4 GiB and a byte, whose length doesn't
fit in 32 bits, and slices it on both sides of the 32-bit edge. It
needs about 4 GiB natively and 8 GiB in `ren run`, so this file runs
only with REN_BIG_TESTS=1 (bench/dune), on a machine with 12 GB free,
and only `ren run`, a debug build and a release one, not under the
sanitizers, to keep to the memory it needs. It lands in step 4.

  $ export REN_NOTES=0
  $ (cd strs && { ren run escape.ren > spec.out 2> spec.err; echo "exit $?" >> spec.out; } &&
  >  head -n 1 spec.err >> spec.out &&
  >  if cmp -s spec.out escape.expected; then echo "escape.ren: as specified"; else echo "escape.ren: not yet"; fi
  >  rm -f spec.out spec.err)
  escape.ren: not yet
  $ (cd strs && for b in debug release; do
  >    if ! REN_CC=cc ren build --$b --stats escape.ren -o ./big.bin > build.err 2>&1
  >    then echo "escape.ren, $b: not native yet: $(head -n 1 build.err)"
  >    else
  >      { ./big.bin > big.out 2> big.err; echo "exit $?" >> big.out; } &&
  >      grep -v '^ren stats: ' big.err | head -n 1 >> big.out
  >      if cmp -s big.out escape.expected
  >      then echo "escape.ren, $b: as specified, $(grep -o 'objects live at exit [0-9]*' big.err)"
  >      else echo "escape.ren, $b: different"; diff big.out escape.expected
  >      fi
  >    fi
  >  done; rm -f big.bin big.out big.err build.err)
  escape.ren, debug: not native yet: error: `Bytes` has no `+`
  escape.ren, release: not native yet: error: `Bytes` has no `+`

#!/bin/bash
set -e
TB=/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/strings/track-b
V=$TB/verify
cd $V
CC="clang -O2 -std=gnu11 -Wall -Wno-unused-function -Wno-unused-result"
for r in A B B24 SSO G; do $CC -DREPR_$r -o bin/b1-$r c/b1.c; done
$CC -DREPR_SSO -DSSO_MEMCPY -o bin/b1-SSOmc c/b1.c
for r in A B SSO; do
  $CC -DREPR_$r -o bin/b2-$r-share c/b2.c
  $CC -DREPR_$r -DRET_STORE -o bin/b2-$r-store c/b2.c
  $CC -DREPR_$r -DRET_STORE -o bin/b1-$r-store c/b1.c
  for n in 16 64; do $CC -DREPR_$r -DRET_N=$n -o bin/b2-$r-n$n c/b2.c; done
done
for v in 0 1 2 3; do $CC -DV=$v -o bin/b3-$v c/b3.c; done
$CC -o bin/b5 c/b5.c
for f in b1-A b1-B b1-SSO b1-G b1-B24 b1-SSOmc b2-A-store b2-B-share b3-1 b3-3 b5; do
  cmp -s bin/$f $TB/bin/$f && echo "$f identical" || echo "$f DIFFERS"
done

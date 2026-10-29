#!/bin/sh
# Builds every C variant into bin/. clang -O2, as `ren build --release`.
set -e
cd "$(dirname "$0")"
mkdir -p bin
CC="clang -O2 -std=gnu11 -Wall -Wno-unused-function -Wno-unused-result"
for r in A B SSO G; do
  $CC -DREPR_$r -o bin/b1-$r c/b1.c
  $CC -DSTATS -DREPR_$r -o bin/b1s-$r c/b1.c
done
# B2: retention policies, layouts A, B and SSO (SSO is B that copies
# under 16 bytes, by layout)
for r in A B SSO; do
  $CC -DREPR_$r -o bin/b2-$r-share c/b2.c
  $CC -DREPR_$r -DSTATS -o bin/b2s-$r-share c/b2.c
  $CC -DREPR_$r -DRET_STORE -o bin/b2-$r-store c/b2.c
  $CC -DREPR_$r -DRET_STORE -o bin/b1-$r-store c/b1.c
  for n in 8 16 24 32 64; do
    $CC -DREPR_$r -DRET_N=$n -o bin/b2-$r-n$n c/b2.c
    $CC -DREPR_$r -DRET_N=$n -o bin/b1-$r-n$n c/b1.c
  done
done
# B3: building output
for v in 0 1 2 3; do $CC -DV=$v -o bin/b3-$v c/b3.c; done
$CC -o bin/b5 c/b5.c
# B4: keys
for r in A B SSO G; do
  $CC -DREPR_$r -DHASH_FX -o bin/b4-$r-fx c/b1.c
  $CC -DREPR_$r -DHASH_PREFIX -o bin/b4-$r-prefix c/b1.c
  $CC -DREPR_$r -DNO_HASH_CMP -o bin/b4-$r-nohashcmp c/b1.c
done
# the twins
(cd rust && cargo build --release --offline)
(cd go && go build -o ../bin/b1-go ./b1 && go build -o ../bin/b2-go ./b2 &&
  go build -o ../bin/b3-go ./b3 && go build -o ../bin/b5-go ./b5)
# B1 extras: Roc's 24-byte layout; SSO with its byte-copy inline path
# (what the first B1 session measured); every layout with atomic counts
$CC -DREPR_B24 -o bin/b1-B24 c/b1.c
$CC -DREPR_SSO -DSSO_MEMCPY -o bin/b1-SSOmc c/b1.c
for r in A B B24 SSO G; do $CC -DREPR_$r -DATOMIC_RC -o bin/b1-$r-at c/b1.c; done

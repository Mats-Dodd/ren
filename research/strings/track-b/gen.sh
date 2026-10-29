#!/bin/sh
# Generates every input into data/ (about 1 GB): deterministic.
set -e
cd "$(dirname "$0")"
mkdir -p bin
clang -O2 -o bin/gen c/gen.c
bin/gen data 64
mkdir -p data/utf8
for k in ascii latin cjk emoji mixed; do
  for sz in 64 1048576; do bin/b5 dump $k $sz data/utf8/$k-$sz.txt; done
done
bin/b5 dump cjk 67108864 data/utf8/cjk-big.txt

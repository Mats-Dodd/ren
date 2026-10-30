#!/bin/zsh
cd ${0:A:h}
for h in keys/*.hex; do n=$(basename $h .hex)
  clang -O1 -w -DSET=$n -DCAT_STR="\"$n\"" -DSETH="\"gen/$n.h\"" -DHEX="\"$h\"" fuzz.c -o bin/$n || { echo "$n: BUILD FAIL"; continue; }
  bin/$n ${1:-1000000}
done

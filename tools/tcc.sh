#!/bin/sh
# Fetches tinycc (tcc) at the commit Ren's debug builds were measured
# with, builds it, and installs it where `ren build` finds it
# (foundations.md, decision 13; research behind it: tcc's mob branch
# builds and runs on arm64 macOS, and passes bench/build.t).
#
#   tools/tcc.sh [prefix]
#
# tcc goes in <prefix> ($HOME/.local/share/ren/tcc if not given), and a
# link to it in $REN_TCC_BIN ($HOME/.local/bin if not set; set it empty
# for none), unless a tcc that isn't a link is there already. `ren build`
# finds tcc through $REN_TCC, or on PATH; without it, debug builds use
# cc -O0, which is slower.
#
# tcc is LGPL-2.1. It's a separate program Ren runs, never linked into
# the compiler, which the licence allows. Needs git, make and a C
# compiler.
set -eu

repo=https://repo.or.cz/tinycc.git
commit=e23dabed154a8495f3ac1ff3cc9d04fa1c207893 # mob, 2026-10-16

prefix=${1:-$HOME/.local/share/ren/tcc}
bin=${REN_TCC_BIN-$HOME/.local/bin}
src=${TMPDIR:-/tmp}/ren-tcc-src.$$

trap 'rm -rf "$src"' EXIT
git init -q "$src"
git -C "$src" fetch -q --depth 1 "$repo" "$commit" ||
  # a server that won't fetch a commit by its hash: the whole branch
  git -C "$src" fetch -q "$repo" mob
git -C "$src" checkout -q "$commit"

cd "$src"
./configure --prefix="$prefix" > configure.log
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" > make.log 2>&1 ||
  { tail -20 make.log; exit 1; }
make install > install.log 2>&1 || { tail -20 install.log; exit 1; }

tcc=$prefix/bin/tcc
"$tcc" -v
if [ -n "$bin" ]; then
  mkdir -p "$bin"
  if [ -e "$bin/tcc" ] && [ ! -L "$bin/tcc" ]; then
    echo "left $bin/tcc as it is: set REN_TCC=$tcc to use this one"
  else
    ln -sf "$tcc" "$bin/tcc"
    echo "linked $bin/tcc to $tcc"
  fi
else
  echo "set REN_TCC=$tcc, or put $prefix/bin on PATH"
fi

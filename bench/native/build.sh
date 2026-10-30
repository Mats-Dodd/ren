#!/bin/sh
# Builds every benchmark here, in Ren, Rust and Go: `sh build.sh [out]`.
# The folder defaults to ren-bench-native under $TMPDIR, outside the
# repository; REN_BENCH_OUT or the argument moves it. $REN is the
# compiler, the repository's own build if not set, and $REN_CC the C
# compiler `ren build` runs, cc if not set. measure.sh times what this
# builds (RESULTS.md).
#
# Each program lands in the folder as:
#
#   <name>-debug          ren build --debug
#   <name>-naive          ren build --release --rc naive
#   <name>-perceus        ren build --release, Perceus's counting
#   <name>-norestrict     ren build --release --no-restrict, for H5's three
#   <name>-<build>-stats  each of the first three with --stats
#   <name>-perceus.c      the C of the release build, from --emit-c
#   <name>-rust           rustc -C opt-level=3 -C codegen-units=1
#   <name>-go             go build
#
# Kernels, one function of a program run alone, land as <name>-<kernel>
# the same way, built from kernels/<name>-<kernel>/main.ren: the
# program's bench.ren with a `main` that calls the one function.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-${REN_BENCH_OUT:-${TMPDIR:-/tmp}/ren-bench-native}}
ren=${REN:-$here/../../_build/default/bin/main.exe}
case $ren in /*) ;; */*) ren=$(pwd)/$ren ;; esac
mkdir -p "$out"
out=$(cd "$out" && pwd)

# build <folder> <binary> <flags...>: `ren build main.ren`, from the
# folder, since a program's modules are found from its entry's
build() {
  dir=$1 bin=$2
  shift 2
  (cd "$dir" && "$ren" build main.ren -o "$bin" "$@")
}

# build_all <folder> <name>: the debug, naive and Perceus builds, each
# with and without --stats, and the release build's C
build_all() {
  build "$1" "$out/$2-debug" --debug
  build "$1" "$out/$2-naive" --release --rc naive
  build "$1" "$out/$2-perceus" --release
  build "$1" "$out/$2-debug-stats" --debug --stats
  build "$1" "$out/$2-naive-stats" --release --rc naive --stats
  build "$1" "$out/$2-perceus-stats" --release --stats
  (cd "$1" && "$ren" build main.ren --release --emit-c) >"$out/$2-perceus.c"
}

for dir in "$here"/*/; do
  name=$(basename "$dir")
  [ -f "$dir/bench.ren" ] || continue
  echo "== $name"
  build_all "$dir" "$name"
  case $name in
    inout | fannkuch | nbody)
      build "$dir" "$out/$name-norestrict" --release --no-restrict
      ;;
  esac
  # `interp` has no twins of its own: dispatch's are its (measure.sh)
  [ -d "$dir/rust" ] || continue
  rustc -C opt-level=3 -C codegen-units=1 -o "$out/$name-rust" "$dir/rust/main.rs"
  # one file, built outside any module, so no go.mod is needed
  (cd "$dir/go" && go build -o "$out/$name-go" main.go)
done

# kernel <program> <kernel> <code>: the program's bench.ren with <code>
# after it, which holds `main`, built as one module
kernel() {
  k=$out/kernels/$1-$2
  mkdir -p "$k"
  { cat "$here/$1/bench.ren"; printf '\n%s\n' "$3"; } >"$k/main.ren"
  # the modules bench.ren imports, beside it
  for m in "$here/$1"/*.ren; do
    case $(basename "$m") in bench.ren | main.ren | small.ren) ;; *) cp "$m" "$k/" ;; esac
  done
  build_all "$k" "$1-$2"
}

echo "== kernels"
# H1: each kernel of `blocks` alone, at main.ren's size, on the array
# and tree `run` builds
xs='fn xs() -> Array<Int> =
  var xs: Array<Int> = []
  for i in 0..1000
    &xs.push(i * 7 % 1000)
  xs
'
for v in blocks loop; do
  for k in map reduce each; do
    kernel blocks "${k}_$v" "$xs
fn main() uses Console = print(${k}_$v(xs(), 100_000))"
  done
  kernel blocks "fold_$v" "fn main() uses Console = print(fold_$v(build(0, 1000), 100_000))"
  kernel blocks "attempt_$v" "fn main() uses Console = print(attempt_$v(100_000))"
done
# H4: `map` over an array nothing else holds, each round's result the
# next round's input
kernel blocks map_unique "$xs
fn main() uses Console =
  var ys = xs()
  for round in 0..100_000
    ys = ys.map(fn(x) => (x * 3 + round) % 1000)
  print(ys[7])"
# a chain of three maps against the same fused by hand, both in place
for v in blocks loop; do
  kernel blocks "chain_$v" "$xs
fn main() uses Console = print(chain_$v(xs(), 100_000))"
done
# swap-out and tail recursion modulo cons: each of `nested`'s kernels
# alone, at main.ren's size
kernel nested grid "fn main() uses Console = print(grid(10_000))"
kernel nested map "fn main() uses Console = print(map(10_000))"
kernel nested list "fn main() uses Console = print(list(101, 1_000_000))"
# H2: each loop of `handlers` alone, at main.ren's size, and the debug
# build's evidence passing again at -O2, to tell it from -O0's cost
kernel handlers with "fn main() uses Console =
  print(with counter() in count_with_handler(1_000_000_000))"
kernel handlers function "fn main() uses Console = print(count_with_function(1_000_000_000))"
for k in with function; do
  REN_CFLAGS="$REN_CFLAGS -O2" build "$out/kernels/handlers-$k" "$out/handlers-$k-debug-O2" --debug
done
# decision 4's dispatch (research/dispatch.md): each of `dispatch`'s
# kernels alone, at main.ren's size; its Rust and Go twins run one
# kernel given its name (measure.sh). The shapesK kernels are the
# codecsK functions since the data stage's step 6, under their old names
# (RESULTS.md, "Dispatch")
dk() { kernel dispatch "$1" "fn main() uses Console = print($2)"; }
dk shapes2 "codecs2(65_536, 100)"
dk shapes4 "codecs4(65_536, 100)"
dk shapes8 "codecs8(65_536, 100)"
dk shapes32 "codecs32(65_536, 100)"
dk db "db(100, 104_857_600)"
dk router "router(65_536, 100)"
dk interp "interp(25_600)"
# decision 17's slices (research/slices.md): each of `slices`' parsers
# alone, at main.ren's size, with slices and with offsets; the twins run
# one given its name, `slices-rust 200000 20 logs_r`
# (not `k`: kernel() sets it)
for parser in logs json pages; do
  for v in "" _r; do
    kernel slices "$parser$v" "fn main() uses Console =
  let b = ${parser}_input(200_000)
  var x = 0
  for _ in 0..20
    x += $parser$v(b)
  print(b.len())
  print(x)"
  done
done
# a slice keeps its root alive: keys kept as slices, then as copies
kernel slices retain_slice "fn main() uses Console = print(retain(false))"
kernel slices retain_copy "fn main() uses Console = print(retain(true))"
echo "built in $out"

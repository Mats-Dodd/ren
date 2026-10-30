#!/bin/sh
# The bytes stage, part two's baseline (bench/native/RESULTS.md, "Bytes
# stage, part two: the baseline"): `sh build.sh <out>` builds, release,
# each workload of bench.ren alone at gen.c's size, at R rounds and at
# 0, whose difference is R rounds' work; the slices benchmark's parsers,
# with slices and with offsets (`_r`), at 20 rounds and at 0; the maps
# benchmark at 20 rounds and at 0; each of those Ren binaries again with
# the C compiled -DREN_RC_SHARED (ren_rt.h, the counting modes), as
# <name>.shared; and the twins: strs' Rust and Go, slices' and maps',
# and maps' Rust with FxHash (maps/rust/fx.rs). measure.py times them.
# $KERNELS, comma-separated, builds only those rows of `kernels`
# (`utf8_cjk,tok`), and nothing else.
set -e
here=$(cd "$(dirname "$0")" && pwd)
native=$here/..
ren=${REN:-$here/../../../_build/default/bin/main.exe}
case $ren in /*) ;; */*) ren=$(pwd)/$ren ;; esac
out=${1:?usage: build.sh <out>}
mkdir -p "$out"
out=$(cd "$out" && pwd)

# kernel <name> <dir> <main's body>: <dir>'s bench.ren and the modules
# beside it, with a main.ren that imports it, built release, plain and
# -DREN_RC_SHARED, and its C
kernel() {
  k=$out/k/$1
  mkdir -p "$k"
  for m in "$2"/*.ren; do
    case $(basename "$m") in main.ren | small.ren) ;; *) cp "$m" "$k/" ;; esac
  done
  printf 'import bench\n\nfn main() uses Console =\n  %s\n' "$3" >"$k/main.ren"
  (cd "$k" && "$ren" build main.ren --release -o "$out/$1" &&
    "$ren" build main.ren --release --emit-c >"$out/$1.c" &&
    REN_CFLAGS="$REN_CFLAGS -DREN_RC_SHARED" "$ren" build main.ren --release -o "$out/$1.shared")
}

# strs: each workload at R rounds and at 0, as `kernels` says: a name,
# the call (none for a size only the twins run), R, and the twins'
# workload and size (measure.py reads the same table)
while IFS="|" read -r name call r _; do
  [ -n "$call" ] || continue
  case ",${KERNELS:-$name}," in *",$name,"*) ;; *) continue ;; esac
  for rounds in "$r" 0; do
    kernel "$name-$rounds" "$here" "$(echo "$call" | sed "s/ROUNDS/$rounds/")"
  done
done <"$here/kernels"
[ -z "$KERNELS" ] || exit 0

# the slices benchmark's parsers, alone, as profile/build.sh builds the
# offset ones, at 200,000 for 20 rounds and for 0
for parser in logs logs_r json json_r pages pages_r; do
  case $parser in logs*) input=logs ;; json*) input=json ;; *) input=pages ;; esac
  for rounds in 20 0; do
    kernel "slices_$parser-$rounds" "$native/slices" "let b = bench.${input}_input(200_000)
  var x = 0
  for _ in 0..$rounds
    x += bench.$parser(b)
  print(b.len())
  print(x)"
  done
done
# the maps benchmark at 20 rounds and at 0
for rounds in 20 0; do
  kernel "maps-$rounds" "$native/maps" "bench.run(200_000, $rounds)"
done

rustc -C opt-level=3 -C codegen-units=1 -o "$out/strs-rust" "$here/rust/main.rs"
rustc -C opt-level=3 -C codegen-units=1 -o "$out/slices-rust" "$native/slices/rust/main.rs"
rustc -C opt-level=3 -C codegen-units=1 -o "$out/maps-rust" "$native/maps/rust/main.rs"
rustc -C opt-level=3 -C codegen-units=1 -o "$out/maps-rust-fx" "$native/maps/rust/fx.rs"
(cd "$here/go" && go build -o "$out/strs-go" main.go)
(cd "$native/slices/go" && go build -o "$out/slices-go" main.go)
(cd "$native/maps/go" && go build -o "$out/maps-go" main.go)
echo "built in $out"

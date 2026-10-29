#!/bin/sh
# The bytes stage's baseline (compiler.md, "Bytes stage", "The
# baseline"): `sh build.sh <out>` builds, release, each of the slices
# benchmark's offset kernels (`logs_r`, `json_r`, `pages_r`) at 20
# rounds and at 0, whose difference is 20 passes, with the C of each;
# bench/native/bytes; layer 3's kernel, bench/native/frames, at 20 passes
# and at 0; and the Rust and Go twins of each. measure.py
# times them, variants.py and push.py make the variants of the C that
# take one cost out, and prof.py says where a binary's time goes.
set -e
here=$(cd "$(dirname "$0")" && pwd)
native=$here/..
ren=${REN:-$here/../../../_build/default/bin/main.exe}
case $ren in /*) ;; */*) ren=$(pwd)/$ren ;; esac
out=${1:?usage: build.sh <out>}
mkdir -p "$out"
out=$(cd "$out" && pwd)
for parser in logs json pages; do
  for rounds in 20 0; do
    k=$out/k/${parser}_r-$rounds
    mkdir -p "$k"
    { cat "$native/slices/bench.ren"
      printf '\nfn main() uses Console =\n  let b = %s_input(200_000)\n  var x = 0\n  for _ in 0..%s\n    x += %s_r(b)\n  print(b.len())\n  print(x)\n' \
        "$parser" "$rounds" "$parser"; } >"$k/main.ren"
    cp "$native/slices/gen.ren" "$k/"
    (cd "$k" && "$ren" build main.ren --release -o "$out/${parser}_r-$rounds" &&
      "$ren" build main.ren --release --emit-c >"$out/${parser}_r-$rounds.c")
  done
done
# layer 3's kernel (step 2): frames at 20 passes and at 0
for rounds in 20 0; do
  k=$out/k/frames-$rounds
  mkdir -p "$k"
  cp "$native/frames/bench.ren" "$k/"
  printf 'import bench\n\nfn main() uses Console = bench.run(1_000_000, %s)\n' "$rounds" >"$k/main.ren"
  (cd "$k" && "$ren" build main.ren --release -o "$out/frames-$rounds" &&
    "$ren" build main.ren --release --emit-c >"$out/frames-$rounds.c")
done
(cd "$native/bytes" && "$ren" build main.ren --release -o "$out/bytes" &&
  "$ren" build main.ren --release --emit-c >"$out/bytes.c")
rustc -C opt-level=3 -C codegen-units=1 -o "$out/slices-rust" "$native/slices/rust/main.rs"
rustc -C opt-level=3 -C codegen-units=1 -o "$out/bytes-rust" "$native/bytes/rust/main.rs"
rustc -C opt-level=3 -C codegen-units=1 -o "$out/frames-rust" "$native/frames/rust/main.rs"
(cd "$native/slices/go" && go build -o "$out/slices-go" main.go)
(cd "$native/bytes/go" && go build -o "$out/bytes-go" main.go)
(cd "$native/frames/go" && go build -o "$out/frames-go" main.go)
echo "built in $out"

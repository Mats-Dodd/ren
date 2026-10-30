#!/bin/sh
# The patterns stage's keyword kernel (bench/native/RESULTS.md, "Patterns
# stage"): `sh build.sh <out>` builds, release, each set of bench.ren
# classified by the `==` chain (`<set>-chain-<R>`) and, when bench.ren has
# them, by the `match` (`<set>-match-<R>`), at R rounds of 65,536 queries
# and at 0, whose difference is R rounds' work; their C (`.c`), whose
# size the stage reports; and the twins, Rust and Go. measure.py times
# them. $SETS, comma-separated, builds only those sets.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ren=${REN:-$here/../../../_build/default/bin/main.exe}
case $ren in /*) ;; */*) ren=$(pwd)/$ren ;; esac
out=${1:?usage: build.sh <out>}
mkdir -p "$out"
out=$(cd "$out" && pwd)
R=${R:-200}
forms=chain
grep -q '_match(s: Str)' "$here/bench.ren" && forms="chain match"
for set in $(echo "${SETS:-renkw,jsreserved,methods,headers,json24,one}" | tr , ' '); do
  for form in $forms; do
    hashed=false
    [ "$form" = match ] && hashed=true
    for rounds in "$R" 0; do
      k=$out/k/$set-$form-$rounds
      mkdir -p "$k"
      cp "$here/bench.ren" "$k/"
      printf 'import bench\n\nfn main() uses Console = bench.run("%s", %s, 65536, %s)\n' \
        "$set" "$hashed" "$rounds" >"$k/main.ren"
      (cd "$k" && "$ren" build main.ren --release -o "$out/$set-$form-$rounds")
    done
    (cd "$out/k/$set-$form-$R" && "$ren" build main.ren --release --emit-c >"$out/$set-$form.c")
  done
done
rustc -C opt-level=3 -C codegen-units=1 -o "$out/keywords-rust" "$here/rust/main.rs"
(cd "$here/go" && go build -o "$out/keywords-go" main.go)
echo "built in $out"

#!/bin/sh
# Measures H1 to H7 (RESULTS.md) from what build.sh built:
#
#   sh measure.sh [bin] [results] [part...]
#
# [bin] is build.sh's folder, the same default; [results] defaults to
# ren-bench-results under $TMPDIR. The parts are `machine`, `stats`,
# `memory`, `time` and `compile`, all of them if none is named. Each
# timing is hyperfine's, after 3 runs to warm up, over $RUNS runs (10 if
# not set), exported as JSON to [results]/<name>.json; peak memory is
# /usr/bin/time -l's maximum resident set size, in memory.tsv; and each
# --stats build's counts are in stats.tsv. summarize.py prints the
# tables RESULTS.md holds from that folder.
set -e
here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-${REN_BENCH_OUT:-${TMPDIR:-/tmp}/ren-bench-native}}
res=${2:-${TMPDIR:-/tmp}/ren-bench-results}
[ $# -gt 0 ] && shift
[ $# -gt 0 ] && shift
parts=${*:-machine stats memory time compile}
ren=${REN:-$here/../../_build/default/bin/main.exe}
case $ren in /*) ;; */*) ren=$(pwd)/$ren ;; esac
runs=${RUNS:-10}
cc=${REN_CC:-cc}
command -v hyperfine >/dev/null || {
  echo "measure.sh needs hyperfine" >&2
  exit 1
}
mkdir -p "$res"
bin=$(cd "$bin" && pwd)
res=$(cd "$res" && pwd)

# vision.md's set, the Perceus set first
programs="rbtree deriv nqueens cfold binary-trees nbody fannkuch"
perceus_set="rbtree deriv nqueens cfold"
kernels="map reduce each fold attempt"

# hf <name> <hyperfine arguments...>: commands run through the shell
hf() {
  name=$1
  shift
  echo "== $name"
  hyperfine --shell=default --warmup 3 --runs "$runs" \
    --export-json "$res/$name.json" "$@" \
    >"$res/$name.txt"
  grep -E '^(Benchmark|  Time)' "$res/$name.txt"
}

# named <program> <build>...: hyperfine's -n and command for each build
named() {
  p=$1
  shift
  for b in "$@"; do
    printf -- '-n\n%s\n%s/%s-%s\n' "$b" "$bin" "$p" "$b"
  done
}

# runs hyperfine on the builds of one program, binaries run without a shell
hyper() {
  name=$1 p=$2
  shift 2
  echo "== $name"
  named "$p" "$@" | tr '\n' '\0' |
    xargs -0 hyperfine -N --warmup 3 --runs "$runs" \
      --export-json "$res/$name.json" >"$res/$name.txt"
  grep -E '^(Benchmark|  Time)' "$res/$name.txt"
}

for part in $parts; do
  case $part in
    machine)
      {
        echo "date: $(date -u +%Y-%m-%dT%H:%MZ)"
        echo "cpu: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
        echo "cores: $(sysctl -n hw.ncpu 2>/dev/null || nproc)"
        echo "memory: $(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824)) GiB"
        echo "os: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(uname -sr))"
        echo "cc: $cc, $($cc --version | head -1)"
        echo "rustc: $(rustc --version)"
        echo "go: $(go version)"
        echo "hyperfine: $(hyperfine --version)"
        echo "ren: $(cd "$here" && git rev-parse --short HEAD 2>/dev/null)$(cd "$here" && git diff --quiet HEAD -- ../../lib ../../bin 2>/dev/null || echo ', with uncommitted changes to the compiler')"
        echo "tcc: $(command -v tcc || echo 'not on PATH')"
      } | tee "$res/machine.txt"
      ;;

    stats)
      # one run of each --stats build: H1's allocations, H3's counts and
      # H4's allocations. The naive builds of nbody and inout copy their
      # arrays at each write and take minutes, so they're left out.
      : >"$res/stats.tsv"
      stat() {
        line=$("$bin/$1" 2>&1 >/dev/null | grep '^ren stats:')
        printf '%s\t%s\n' "$1" "$line" | tee -a "$res/stats.tsv"
      }
      for p in $programs; do
        stat "$p-perceus-stats"
        case $p in nbody) ;; *) stat "$p-naive-stats" ;; esac
      done
      for k in $kernels; do
        for v in blocks loop; do
          stat "blocks-${k}_$v-debug-stats"
          stat "blocks-${k}_$v-perceus-stats"
        done
      done
      stat blocks-map_unique-naive-stats
      stat blocks-map_unique-perceus-stats
      # swap-out and tail recursion modulo cons: copies and allocations
      for k in grid map list; do
        stat "nested-$k-debug-stats"
        stat "nested-$k-perceus-stats"
      done
      ;;

    memory)
      # peak resident memory, once each: H4 and H7
      : >"$res/memory.tsv"
      # BSD time's -l counts bytes, first on its line; GNU time's -v,
      # on Linux, kilobytes, last
      rss() {
        if [ "$(uname)" = Darwin ]; then
          kb=$(/usr/bin/time -l "$bin/$1" 2>&1 >/dev/null |
            awk '/maximum resident set size/ { print $1 }')
        else
          kb=$(/usr/bin/time -v "$bin/$1" 2>&1 >/dev/null |
            awk '/Maximum resident set size/ { print $NF * 1024 }')
        fi
        printf '%s\t%s\n' "$1" "$kb" | tee -a "$res/memory.tsv"
      }
      for p in $programs; do
        for b in perceus rust go; do rss "$p-$b"; done
      done
      for p in $perceus_set fannkuch; do rss "$p-naive"; done
      rss blocks-map_unique-naive
      rss blocks-map_unique-perceus
      ;;

    time)
      # H3 and H7: the Perceus set in both counting modes against Rust
      # and Go; the rest in Perceus's
      for p in $perceus_set; do hyper "$p" "$p" perceus naive rust go; done
      hyper binary-trees binary-trees perceus rust go
      # H5: restrict against not, and H7
      for p in nbody fannkuch inout; do
        hyper "$p" "$p" perceus norestrict rust go
      done
      # arrays of arrays and lists built by recursion, both builds
      hyper nested nested perceus debug rust go
      for k in grid map list; do hyper "nested-$k" "nested-$k" perceus debug; done
      # H1: each block kernel against its loop twin, release
      for k in $kernels; do
        hyper "h1-$k" blocks "${k}_blocks-perceus" "${k}_loop-perceus"
      done
      # H2: an operation of a known handler against a plain call, in the
      # release build, the debug build, and the debug build at -O2
      hyper h2 handlers with-perceus function-perceus with-debug \
        function-debug with-debug-O2 function-debug-O2
      # decision 4: each dispatch kernel, release, against Rust's dyn
      # and enum twins and Go's interface one, run with the kernel's name
      for k in shapes2 shapes4 shapes8 shapes32 db router interp; do
        hf "dispatch-$k" -n perceus "$bin/dispatch-$k-perceus" \
          -n rust-dyn "$bin/dispatch-rust 100 $k dyn" \
          -n rust-enum "$bin/dispatch-rust 100 $k enum" \
          -n go "$bin/dispatch-go 100 $k"
      done
      ;;

    compile)
      # H6: `ren build --debug` against `go build` on gen.py's programs,
      # clean, and after a one-line edit in a leaf module
      gen=$res/gen
      mkdir -p "$gen"
      # a cache holding only the standard library the programs import
      std=$gen/gocache-std
      if [ ! -d "$std" ]; then
        mkdir -p "$gen/std"
        printf 'module warm\n\ngo 1.21\n' >"$gen/std/go.mod"
        printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println(1) }\n' \
          >"$gen/std/main.go"
        (cd "$gen/std" && GOCACHE=$std go build -o warm .)
      fi
      cache=$gen/gocache
      : >"$res/lines.tsv"
      for n in 10000 100000 500000; do
        r=$gen/ren$n g=$gen/go$n
        [ -d "$r" ] || python3 -I "$here/gen/gen.py" ren $n "$r" >/dev/null
        [ -d "$g" ] || python3 -I "$here/gen/gen.py" go $n "$g" >/dev/null
        printf 'ren%s\t%s\ngo%s\t%s\n' \
          $n "$(cat "$r"/*.ren | wc -l | tr -d ' ')" \
          $n "$(cat "$g"/*.go "$g"/*/*.go | wc -l | tr -d ' ')" \
          >>"$res/lines.tsv"
        leaf_ren=$(ls "$r"/m[0-9]*.ren | sort | tail -1)
        leaf_go=$(ls -d "$g"/m[0-9]* | sort | tail -1)
        # Ren has no build cache yet: every build is a clean one
        # each command's --prepare in order: only the edit has one
        hf "h6-ren-$n" \
          -n total --prepare true "cd $r && $ren build --debug main.ren -o m" \
          -n front --prepare true \
          "cd $r && $ren build --debug --emit-c main.ren > main.c" \
          -n cc --prepare true \
          "cd $r && $cc -O0 -g -ffp-contract=off -o m main.c -lm -lpthread" \
          -n leaf-edit \
          --prepare "perl -0pi -e 's/(Small => )(\\d+)/\$1.(\$2+1)/e' $leaf_ren" \
          "cd $r && $ren build --debug main.ren -o m"
        hf "h6-go-$n" \
          -n clean --prepare "rm -rf $cache" \
          "cd $g && GOCACHE=$cache go build -o m ." \
          -n clean-std-cached --prepare "rm -rf $cache && cp -R $std $cache" \
          "cd $g && GOCACHE=$cache go build -o m ." \
          -n leaf-edit \
          --prepare "perl -0pi -e 's/(case Small:\\n\\t\\treturn )(\\d+)/\$1.(\$2+1)/e' $leaf_go/*.go" \
          "cd $g && GOCACHE=$cache go build -o m ."
      done
      ;;

    *)
      echo "measure.sh: no part $part" >&2
      exit 2
      ;;
  esac
done
echo "results in $res"

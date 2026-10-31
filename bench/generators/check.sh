#!/bin/sh
# The targets are fixed data, not inferred from the interpreter's output.
set -eu
cd "$(dirname "$0")"
export REN_NOTES=0
export ASAN_OPTIONS=detect_stack_use_after_return=0:detect_leaks=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

enabled() { grep -qx "$1" stages; }

capture() {
  set +e
  "$@" > "$work/out" 2> "$work/err"
  code=$?
  set -e
  cp "$work/out" "$work/result"
  echo "exit $code" >> "$work/result"
  head -n 1 "$work/err" >> "$work/result"
}

pending() {
  stage=$1
  name=$2
  # A disabled feature must still have precisely its recorded first error.
  # A crash, successful wrong result or different diagnostic is a failure.
  if [ "$code" -eq 0 ] || ! cmp -s "$work/result" "$name.pending"; then
    echo "$name: changed before $stage was enabled"
    cat "$work/result"
    exit 1
  fi
  echo "$name: until $stage (recorded rejection)"
}

program() {
  stage=$1
  name=$2
  capture ren run "$name.ren" -- "$work/lines.txt"
  if ! enabled "$stage"; then pending "$stage" "$name"; return; fi
  diff -u "$name.expected" "$work/result"
  cp "$work/out" "$work/interp.out"
  cp "$work/err" "$work/interp.err"
  cp "$work/result" "$work/interp.result"
  capture ren run --release "$name.ren" -- "$work/lines.txt"
  diff -u "$work/interp.result" "$work/result"
  diff -u "$work/interp.err" "$work/err"
  echo "$name: interpreter and ren run --release as specified"
}

native() {
  name=$1
  if ! enabled g4; then echo "$name: native until g4"; return; fi
  capture ren run "$name.ren" -- "$work/lines.txt"
  diff -u "$name.expected" "$work/result"
  cp "$work/result" "$work/interp.result"
  cp "$work/err" "$work/interp.err"
  for mode in perceus naive release tcc; do
    case "$mode" in
      perceus|naive)
        REN_CC=cc REN_CFLAGS='-fsanitize=address,undefined' ren build --debug --stats --rc "$mode" "$name.ren" -o "$work/native.bin" > "$work/build.out" 2> "$work/build.err" ;;
      release)
        REN_CC=cc REN_CFLAGS='-fsanitize=address,undefined' ren build --release --stats "$name.ren" -o "$work/native.bin" > "$work/build.out" 2> "$work/build.err" ;;
      tcc)
        # The default debug build uses tcc (REN_TCC or PATH), as build.t does.
        REN_CC="${REN_TCC:-tcc}" REN_CFLAGS='' ren build --stats "$name.ren" -o "$work/native.bin" > "$work/build.out" 2> "$work/build.err" ;;
    esac || { cat "$work/build.err" >&2; exit 1; }
    capture "$work/native.bin" "$work/lines.txt"
    # Keep every sanitizer diagnostic. Only known runtime stats and the
    # documented OCaml-stack ASan warning are removed before comparison.
    sed -e '/^ren stats: /d' \
        -e '/^==[0-9][0-9]*==WARNING: ASan is ignoring/d' \
        -e '/^False positive error reports may follow/d' \
        -e '\|^For details see https://github.com/google/sanitizers/issues/189|d' \
        "$work/err" > "$work/native.err"
    cp "$work/out" "$work/result"
    echo "exit $code" >> "$work/result"
    head -n 1 "$work/native.err" >> "$work/result"
    diff -u "$work/interp.result" "$work/result"
    diff -u "$work/interp.err" "$work/native.err"
    case "$name" in
      depth_push|depth_pull)
        grep -q 'objects live at exit [0-9]' "$work/err"
        echo "$name: $mode agrees (fatal depth panic)" ;;
      *)
        grep -q 'objects live at exit 0' "$work/err"
        echo "$name: $mode agrees, objects live at exit 0" ;;
    esac
  done
}

seeded() {
  stage=$1
  name=$2
  capture ren test "$name.ren" --seeds 1000
  if ! enabled "$stage"; then pending "$stage" "$name"; return; fi
  [ "$code" -eq 0 ]
  grep -q 'each under 1000 seeds' "$work/out"
  # Failed assertions and compiler errors produce nonzero status; don't
  # turn them into an informational "not yet" after the step is enabled.
  echo "$name: all assertions passed across 1000 seeds"
}

current_queues() {
  capture ren test queues.ren --seeds 1000
  [ "$code" -eq 0 ]
  grep -q 'each under 1000 seeds' "$work/out"
  echo 'queues: existing contracts pass across 1000 seeds'
  capture ren run close_sender.ren
  diff -u close_sender.expected "$work/result"
  echo 'close_sender: existing closed-send panic as specified'
}

case "$1" in
  interpreter)
    program g1 pure
    program g1 cursor_show
    program g1 lifetime
    program g1 part_two
    program g2 stages
    program g2 lifetime_push
    program g4 unique
    program g4 depth_push
    program g4 depth_pull
    program g5 fs
    program g5 transaction
    program g5 fs_push
    program g5 transaction_push
    ;;
  native)
    for name in pure cursor_show stages lifetime_push unique depth_push depth_pull; do native "$name"; done
    if enabled g5; then
      native fs_push
      native transaction_push
    else
      echo 'fs_push: native until g5'
      echo 'transaction_push: native until g5'
    fi
    if enabled g4; then
      set +e
      ren build --debug part_two.ren -o "$work/refused.bin" > "$work/out" 2> "$work/err"
      code=$?
      set -e
      [ "$code" -ne 0 ]
      grep -q 'runtime core' "$work/err"
      grep -q 'help:' "$work/err"
      echo 'part_two: native refusal names runtime core and gives help'
      for operation in eq hash ord; do
        case "$operation" in
          eq) phrase=equality ;;
          hash) phrase=hash ;;
          ord) phrase=order ;;
        esac
        for form in direct generic container; do
          name=cursor_${operation}_${form}
          set +e
          ren build --debug "$name.ren" -o "$work/refused.bin" > "$work/out" 2> "$work/err"
          code=$?
          set -e
          [ "$code" -ne 0 ]
          grep -q 'values.Cursor' "$work/err"
          grep -q "$phrase" "$work/err"
          grep -q 'help:' "$work/err"
          grep -q 'yielded data' "$work/err"
        done
      done
      echo 'cursor equality, hash and order: direct, generic and container refusals agree'
    else
      echo 'part_two: native refusal until g4'
      echo 'cursor operation refusals: native until g4'
    fi
    ;;
  sim)
    current_queues
    seeded g1 cancel_sim
    seeded g3 merge_sim
    seeded g3 expand_sim
    ;;
  replay)
    capture ren run --record "$work/run.journal" replay.ren
    if ! enabled g3; then pending g3 replay; exit 0; fi
    [ "$code" -eq 0 ]
    cp "$work/out" "$work/record.out"
    ren replay "$work/run.journal" > "$work/replay.out" 2> "$work/replay.err"
    diff -u "$work/record.out" "$work/replay.out"
    echo 'merge and expand: journal replays every value and cleanup'
    ;;
  *) echo 'expected interpreter, native, sim or replay' >&2; exit 2 ;;
esac

#!/bin/bash
# bt.sh <lang> <profile> <clean|incr>: one timed build (called under flock -x by measure_b.py)
set -e
cd /home/user/ren/experiments/native-lang
lang=$1; prof=$2; mode=$3; tag=$lang-$prof
if [ "$mode" = clean ]; then
  rm -rf "/home/user/ren/experiments/native-lang/build/$tag" "/home/user/ren/experiments/native-lang/bin/$tag"
  case $lang in
    rust) rm -rf "/home/user/ren/experiments/native-lang/rust/target/$prof" ;;
    zig) rm -rf /home/user/ren/experiments/native-lang/zig/.zig-cache ;;
  esac
else
  case $lang in
    c) touch c/core.c ;;
    rust) touch rust/core/src/sched.rs ;;
    zig) touch zig/src/core.zig ;;
  esac
fi
REN_FLOCKED=1 ./build.sh $lang $prof >/dev/null 2>&1
tail -1 build/build-times.txt | sed 's/^/metric: /'

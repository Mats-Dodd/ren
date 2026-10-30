#!/bin/bash
# ZIG wrapper: adds -target $XT to translate-c / build-lib / cc so zig/build.sh cross-builds unchanged
sub=$1; shift
case "$sub" in
  build-lib|translate-c|cc) exec /usr/local/bin/zig "$sub" -target "$XT" "$@" ;;
  *) exec /usr/local/bin/zig "$sub" "$@" ;;
esac

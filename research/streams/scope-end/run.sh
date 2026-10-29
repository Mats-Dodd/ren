#!/bin/sh
# runs every test here with the prototype worktree's interpreter
W=/Users/matthewdodd/Documents/code/ren/.claude/worktrees/wf_350e7dc3-1f2-2
cd "$(dirname "$0")"
for f in fall outer_break fails resume unstepped nested with_tx gen_fails temp_fails cancel cancel_mid_step panic; do
  echo "=== $f"; "$W/_build/default/bin/main.exe" run $f.ren 2>&1
done

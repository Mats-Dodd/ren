#!/usr/bin/env bash
# Shared local/CI checks; invoke inside devenv shell.
set -euo pipefail
cd "$(dirname "$0")/.."
dune build
dune runtest
make -C editors/tree-sitter-ren check
git diff --exit-code -- editors/tree-sitter-ren/src

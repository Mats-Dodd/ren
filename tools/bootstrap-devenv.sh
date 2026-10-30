#!/usr/bin/env bash
# Install the CLI from the same locked package collection as the environment.
set -euo pipefail
cd "$(dirname "$0")/.."
rev=$(python3 - <<'PYTHON'
import json
with open("devenv.lock") as f:
    nodes = json.load(f)["nodes"]
print(nodes[nodes["root"]["inputs"]["nixpkgs"]]["locked"]["rev"])
PYTHON
)
nix --extra-experimental-features 'nix-command flakes' build \
  --out-link .devenv-cli "github:NixOS/nixpkgs/$rev#devenv"
./.devenv-cli/bin/devenv version

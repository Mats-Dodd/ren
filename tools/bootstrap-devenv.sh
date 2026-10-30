#!/usr/bin/env bash
# Install the CLI from the same locked package collection as the environment.
set -euo pipefail
cd "$(dirname "$0")/.."
rev=$(nix --extra-experimental-features nix-command eval --raw --impure --expr '
  let nodes = (builtins.fromJSON (builtins.readFile ./devenv.lock)).nodes;
  in nodes.${nodes.root.inputs.nixpkgs}.locked.rev
')
nix --extra-experimental-features 'nix-command flakes' build \
  --out-link .devenv-cli "github:NixOS/nixpkgs/$rev#devenv"
./.devenv-cli/bin/devenv version

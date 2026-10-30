{ lib, stdenv, fetchurl, autoPatchelfHook, gzip }:
let
  releases = {
    x86_64-linux = {
      asset = "linux-x64";
      hash = "sha256-0BBC+Uuj1oJ93JeI4jX3XYNmQxvkK9+QreU02WDJi30=";
    };
    aarch64-darwin = {
      asset = "macos-arm64";
      hash = "sha256-RsuX2aLFLJTiLZp2wvERYVa4th+YNg4qnM4F/LGXzU0=";
    };
  };
  release = releases.${stdenv.hostPlatform.system};
in stdenv.mkDerivation rec {
  pname = "ren-tree-sitter-cli";
  version = "0.27.1";
  # The same upstream executable distributed by the npm package, with
  # a content hash and, on Linux, Nix's loader and runtime library paths.
  src = fetchurl {
    url = "https://github.com/tree-sitter/tree-sitter/releases/download/v${version}/tree-sitter-${release.asset}.gz";
    inherit (release) hash;
  };
  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;
  nativeBuildInputs = [ gzip ] ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];
  installPhase = ''
    mkdir -p "$out/bin"
    gzip -dc "$src" > "$out/bin/tree-sitter"
    chmod +x "$out/bin/tree-sitter"
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/tree-sitter" --version
  '';
}

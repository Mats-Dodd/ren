{ tinycc, fetchFromGitHub }:
# Last upstream stable (0.9.27) predates native arm64 macOS support.
# This is the same mob revision as tools/tcc.sh, pinned by content hash.
tinycc.overrideAttrs {
  version = "0.9.27-unstable-2026-10-16";
  src = fetchFromGitHub {
    owner = "TinyCC";
    repo = "tinycc";
    rev = "e23dabed154a8495f3ac1ff3cc9d04fa1c207893";
    hash = "sha256-sfCnhlA//knN0oU1Ld8PSFeKZhLm27ymB/o4/oaaCMI=";
  };
}

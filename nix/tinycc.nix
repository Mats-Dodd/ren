{ tinycc, fetchFromGitHub, lib, stdenv }:
# Last upstream stable (0.9.27) predates native arm64 macOS support.
# This is the same mob revision as tools/tcc.sh, pinned by content hash.
tinycc.overrideAttrs (old: {
  version = "0.9.27-unstable-2026-10-16";
  src = fetchFromGitHub {
    owner = "TinyCC";
    repo = "tinycc";
    rev = "e23dabed154a8495f3ac1ff3cc9d04fa1c207893";
    hash = "sha256-sfCnhlA//knN0oU1Ld8PSFeKZhLm27ymB/o4/oaaCMI=";
  };
  # Darwin strip adds a BSD archive index to TCC's GNU-format libtcc1.a,
  # leaving TCC unable to resolve runtime helpers such as __builtin_ctz.
  dontStrip = stdenv.hostPlatform.isDarwin;
  postFixup = (old.postFixup or "") + lib.optionalString
    (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      cat > builtin-smoke.c <<'C'
      int main(void) {
        volatile unsigned x = 8;
        volatile unsigned long long y = 1ULL << 40;
        return __builtin_ctz(x) != 3 || __builtin_ctzll(y) != 40;
      }
      C
      $out/bin/tcc builtin-smoke.c -o builtin-smoke
      ./builtin-smoke
    '';
})

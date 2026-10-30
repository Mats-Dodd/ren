{ pkgs, lib, config, inputs, ... }:
let
  ocaml = import ./nix/ocaml.nix { inherit pkgs; };
  tinycc = pkgs.callPackage ./nix/tinycc.nix { };
  tree-sitter = pkgs.callPackage ./nix/tree-sitter.nix { };

in {
  # Upstream v2.4.0's module version stamp still says 2.3.1.
  devenv.latestVersion = "2.4.0";
  # Ren intentionally compiles debug C at -O0; glibc fortification needs -O.
  hardeningDisable = [ "fortify" "fortify3" ];
  packages = [
    ocaml.ocaml ocaml.findlib ocaml.ppx_deriving ocaml.ppx_expect
    ocaml.ocaml-lsp pkgs.ocamlformat ocaml.dune_3
    pkgs.llvmPackages_23.clang (lib.getBin tinycc) tree-sitter
    pkgs.nodejs_latest pkgs.python315 pkgs.gnumake pkgs.git pkgs.perl pkgs.ps
  ] ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.llvmPackages_23.llvm ];

  # REN_CC would override TinyCC for debug builds too. Leave it unset;
  # the Clang wrapper supplies cc, including SDK/libc and sanitizer paths.
  # --clean deliberately drops personal shell state, including HOME.
  env.npm_config_cache = "${config.devenv.state}/npm";
  env.XDG_CACHE_HOME = "${config.devenv.state}/cache";
  env.XDG_CONFIG_HOME = "${config.devenv.state}/config";
  env.LC_ALL = if pkgs.stdenv.hostPlatform.isDarwin then "en_US.UTF-8" else "C.UTF-8";
  env.REN_TCC = "${lib.getBin tinycc}/bin/tcc";
  env.TREE_SITTER = "${tree-sitter}/bin/tree-sitter";

  scripts.ren-check.exec = ''
    exec bash "${config.devenv.root}/tools/check.sh" "$@"
  '';
  scripts.ren-toolchain.exec = ''
    for tool in ocamlc dune ocamlfind ocamllsp ocamlformat cc node python3; do
      command -v "$tool"
    done
    ocamlc -version
    dune --version
    ocamlfind query -format '%p %v' ppx_deriving ppx_expect
    ocamllsp --version
    ocamlformat --version
    cc --version
    "$REN_TCC" -v
    node --version
    python3 --version
    tree-sitter --version
  '';

  profiles.benchmarks.module = {
    env.GOCACHE = "${config.devenv.state}/go-build";
    env.GOPATH = "${config.devenv.state}/go";
    env.CARGO_HOME = "${config.devenv.state}/cargo";
    scripts.ren-check-bench.exec = ''
      exec bash "${config.devenv.root}/tools/check-benchmark-toolchain.sh"
    '';
    packages = [
      pkgs.go_1_27
      (inputs.rust-overlay.lib.mkRustBin { } pkgs).stable."1.99.1".minimal
    ];
  };

  enterTest = "ren-check";
}

{ pkgs, config, ... }:
let
  ocaml = import ./nix/ocaml.nix { inherit pkgs; };
  tinycc = pkgs.callPackage ./nix/tinycc.nix { };

in {
  packages = [
    ocaml.ocaml ocaml.findlib ocaml.ppx_deriving ocaml.ppx_expect
    ocaml.ocaml-lsp pkgs.ocamlformat ocaml.dune_3
    pkgs.llvmPackages_23.clang tinycc
    pkgs.nodejs_latest pkgs.python3 pkgs.gnumake pkgs.git
  ];

  # REN_CC would override TinyCC for debug builds too. Leave it unset;
  # the Clang wrapper supplies cc, including SDK/libc and sanitizer paths.
  env.REN_TCC = "${tinycc}/bin/tcc";

  scripts.ren-check.exec = ''
    exec bash "${config.devenv.root}/tools/check.sh" "$@"
  '';
  scripts.ren-toolchain.exec = ''
    ocamlc -version
    dune --version
    ocamlfind query -format '%p %v' ppx_deriving ppx_expect
    cc --version
    "$REN_TCC" -v
    node --version
    python3 --version
  '';

  profiles.benchmarks.module = {
    packages = [ pkgs.rustc pkgs.cargo pkgs.go ];
  };

  enterTest = "ren-check";
}

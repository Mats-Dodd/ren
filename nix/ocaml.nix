{ pkgs }:
let
  # Keep the compiler and every library in the same package scope.
  ocaml = pkgs.ocaml-ng.ocamlPackages_5_5.ocaml.overrideAttrs {
    version = "5.5.2";
    # This is an upstream stable release. Avoid running the compiler's entire
    # upstream testsuite during contributor setup; CI runs Ren's full suite.
    doCheck = false;
    src = pkgs.fetchurl {
      url = "https://caml.inria.fr/pub/distrib/ocaml-5.5/ocaml-5.5.2.tar.xz";
      hash = "sha256-VQPhuq2LYl2jXx/nHUdVgBT6NiU65fGiLMOhj6sEHg0=";
    };
  };
  dune = pkgs.dune_3.overrideAttrs {
    version = "3.24.2";
    src = pkgs.fetchurl {
      url = "https://github.com/ocaml/dune/releases/download/3.24.2/dune-3.24.2.tbz";
      hash = "sha256-RyeYaRsCFtr1OHCfD0cDs2F+8krQhmyQlgaLqrpNdio=";
    };
  };
  scope = pkgs.ocaml-ng.ocamlPackages_5_5.overrideScope (final: prev: {
    inherit ocaml;
    dune_3 = dune;
    merlin = (prev.merlin.override { version = "5.8-505"; }).overrideAttrs {
      version = "5.9";
      src = pkgs.fetchurl {
        url = "https://github.com/ocaml/merlin/releases/download/v5.9/merlin-5.9.tbz";
        hash = "sha256-3jld030kbj7DA+GvNf+EIWZfpPDwAF2VcyEksi40F6w=";
      };
    };
    jsonrpc = prev.jsonrpc.overrideAttrs {
      version = "1.28.0";
      src = pkgs.fetchurl {
        url = "https://github.com/ocaml/ocaml-lsp/releases/download/1.28.0/lsp-1.28.0.tbz";
        hash = "sha256-o/zbpiXeqsYzkns8gd/CYu9tKGyHMncMUY4tLyjvJR8=";
      };
    };
    ocaml-lsp = prev.ocaml-lsp.overrideAttrs (old: {
      buildInputs = old.buildInputs ++ [ final.fs-io ];
    });
    ppx_deriving = prev.ppx_deriving.overrideAttrs {
      version = "6.2.0";
      src = pkgs.fetchurl {
        url = "https://github.com/ocaml-ppx/ppx_deriving/releases/download/6.2.0/ppx_deriving-6.2.0.tbz";
        hash = "sha256-k/1I1axSuw0O2o1PtwN4CL5X2vxZgdtOZi65FscN+bE=";
      };
    };
  });
in scope

# Developing Ren

The supported development and CI targets are Apple Silicon macOS
(`aarch64-darwin`) and x86-64 Linux (`x86_64-linux`). Both use the toolchain
in `devenv.nix` and `devenv.lock`. Dune remains the build system.

## Setup

Install [Nix](https://devenv.sh/getting-started/) and Git. Clone this
repository, then run:

```sh
bash tools/bootstrap-devenv.sh
./.devenv-cli/bin/devenv shell --clean
ren-toolchain
ren-check
```

The bootstrap script installs the locked devenv CLI into `.devenv-cli`,
without changing your global Nix profile. The first shell builds/downloads
the pinned tools; later shells reuse the Nix store. CI also caches the
store separately for each architecture and toolchain revision. npm, Cargo,
and Go caches live under the ignored `.devenv` directory. No personal opam switch
or Homebrew compiler is needed. Run from a fresh checkout when switching
from an existing opam build, or run `dune clean` inside the new environment.

For a single command, including from an agent or CI:

```sh
./.devenv-cli/bin/devenv --no-tui shell --clean -- ren-check
```

Inside the shell the ordinary commands still work:

```sh
dune build
dune runtest
make -C editors/tree-sitter-ren check
dune exec ren -- run examples/fib.ren
```

`ren-check` builds the compiler, runs all Dune tests (including native
backend and sanitizer comparisons), runs grammar corpus/highlight and
parser differential checks, and verifies that regeneration matches the
committed parser. After intentionally updating the grammar or generator,
review and stage the generated files before running the consistency check.
CI additionally checks that no tracked files changed.

## Toolchain and native builds

The environment supplies OCaml 5.5.2, Dune 3.24.2, ppx_deriving 6.2.0,
ppx_expect 0.17.3, OCaml LSP 1.28.0, OCamlFormat 0.29.0, Node 26 LTS,
Python 3.15, and LLVM/Clang 23.1.3. The exact package revisions are locked.
As of 2026-10-30, Clang is one patch behind upstream 23.1.4: this is the
newest stable LLVM package in the locked nixpkgs collection, retaining
binary-cache support rather than requiring every contributor and CI runner
to compile LLVM. Advance it with nixpkgs when that package is available.
Tree-sitter CLI 0.27.1 is pinned separately by the npm lockfile; generation
explicitly targets ABI 14 for editor compatibility.

`cc` is the Nix Clang wrapper, with the platform's SDK/libc and sanitizer
libraries. `REN_TCC` points to the packaged TinyCC. TinyCC's old stable
release predates arm64 macOS support, so `nix/tinycc.nix` pins the upstream
mob commit also used by `tools/tcc.sh`.

Do not set `REN_CC` in your default shell: it overrides TinyCC for debug
builds as well as release builds. To deliberately test Clang debug builds:

```sh
REN_CC=cc dune exec ren -- build --debug examples/fib.ren -o /tmp/ren-fib
/tmp/ren-fib
```

The macOS debug-symbol step finds `dsymutil` on PATH; the environment
supplies the matching LLVM tool. Linux binaries carry their debug
information directly. The optional NEON
cross-test reports a skip if its Linux cross-compiler and QEMU are absent.
That skip is not a claim that cross-emulation was tested.

## Benchmarks

Rust 1.99.1 and Go 1.27.3 are optional tools:

```sh
./.devenv-cli/bin/devenv --profile benchmarks shell --clean
ren-check-bench
sh bench/native/build.sh
```

Record OS, hardware, compiler versions and flags with benchmark results.
A locked environment does not make timings interchangeable across machines.

## Updating

Update deliberately, review the resulting versions, and pass the same
checks on both CI platforms:

```sh
./.devenv-cli/bin/devenv update
bash tools/bootstrap-devenv.sh
./.devenv-cli/bin/devenv shell --clean -- ren-toolchain
./.devenv-cli/bin/devenv shell --clean -- ren-check
```

The devenv module input is pinned to a release in `devenv.yaml`; change it
when upgrading the CLI/module release. The CLI itself comes from the locked
nixpkgs input. `nix/ocaml.nix` contains stable-release overrides ahead of
nixpkgs; remove them when the package collection catches up. The compiler
package skips OCaml's own upstream tests during installation; `ren-check`
still runs the full Ren suite, native comparisons and sanitizers. Update source
hashes along with versions, and preserve a consistent OCaml package scope.

For a tree-sitter upgrade, update its exact npm version and lockfile,
regenerate at ABI 14, and review the generated changes. `npm ci` is used for
clean installs. Avoid changing formatting across the repository as part of
a toolchain update.

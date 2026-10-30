#!/usr/bin/env bash
# Check that the optional comparison compilers can link and run programs.
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rustc --version
cargo --version
go version
cat > "$work/main.rs" <<'RUST'
fn main() { println!("42"); }
RUST
cat > "$work/main.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println(42) }
GO
rustc "$work/main.rs" -o "$work/rust-smoke"
go build -o "$work/go-smoke" "$work/main.go"
test "$("$work/rust-smoke")" = 42
test "$("$work/go-smoke")" = 42
echo 'Rust and Go compile, link and run successfully'

# Native benchmarks

The programs the native slice is measured with ([vision.md](../../vision.md),
"Within 2× of Rust" and "Debug builds faster than Go";
[foundations.md](../../foundations.md), Staging, item 2). Each is written
three times: in Ren, the way the docs teach it, and in Rust and Go, the
way a good programmer in each writes it. The interpreter checks what
each computes. `ren build` compiles every one of them (native steps 2
and 3), and bench/build.t checks each debug binary prints what `ren
run` does, and that `blocks`' kernels allocate as much with blocks as
with loops. [RESULTS.md](RESULTS.md) holds what they measure, H1 to H7,
and how to measure them again.

## What's here

Each folder is one program:

| File | What it is |
|---|---|
| `bench.ren` | the program, a module with `pub fn run(n: Int)`, which prints a checksum through `Console` |
| `main.ren` | `run` at the benchmark's size |
| `small.ren` | `run` at a size the interpreter runs in a moment, which `native.t` checks |
| `rust/main.rs` | the Rust twin: std only, no `unsafe`, no SIMD, one thread |
| `go/main.go` | the Go twin, one goroutine |

The twins take the size as their first argument and default to
`main.ren`'s, and print exactly what the Ren prints.

| Program | Size in `main.ren` | Small | What it tests |
|---|---|---|---|
| `rbtree` | 4,200,000 keys (Koka's) | 1,000 | building a red-black tree by inserting into one nothing else holds: reuse in place |
| `deriv` | 10 derivatives (Koka's) | 5 | symbolic terms that share their parts: counting, not copying |
| `nqueens` | 13 (Koka's) | 8 | lists of solutions that share their tails: many small, short-lived cells |
| `cfold` | 2^20 leaves (Koka's) | 2^10 | passes that each build a new tree from the old: reuse in place |
| `binary-trees` | depth 21 | 6 | allocating and freeing small nodes |
| `nbody` | 50,000,000 steps | 1,000 | Floats in an array of records changed through `&` |
| `fannkuch` | 11 | 7 | small arrays of Ints changed in place, the case vision.md calls at risk |
| `blocks` | 100,000 rounds | 10 | **H1**: a block costs nothing once specialized |
| `handlers` | 1,000,000,000 calls | 1,000 | **H2**: a call to a known handler costs a function call |
| `inout` | 2,000,000 rounds | 10 | **H5**: an `&` parameter aliases nothing |
| `nested` | 10,000 rounds, lists of 1,000,000 | 20 rounds, lists of 2,000 | an array of arrays changed by index and mapped in place (swap-out), and lists built and mapped by recursion that takes no stack (tail recursion modulo cons) |
| `bytes` | 1,000,000 elements, 100 rounds | 1,000, 3 | an `Array<UInt8>` and an `Array<Int32>` changed in place, each store checked, and an FNV-1a hash with `*%` into a `UInt32`: sized storage |
| `vec` | arrays of 1,000, 1,000,000 rounds | 100, 10 | **decision 16**: loops by `for x in &xs`, `for i, x in &ys` and `zip`, each a kernel a vector unit could do (a dot product, a Float sum, scaling, axpy, an LCG with `*%`, a checked Int sum, a `UInt8` blend); which vectorize is RESULTS.md's "Follow-ups" |
| `dispatch` | 65,536 descriptions, 100 rounds | 1,000, 1 | **decision 4**: research/dispatch.md's kernels, calls on descriptions chosen at run time: 2, 4, 8 and 32 kinds of codec in an array (research/dispatch.md's shapes, which a program would write as an ADT), a `Db` of four handlers called in a loop, a router of 50 inline handlers, and an expression tree's `eval`, recursion through its own dependency; Rust is run `dyn` and enum, Go through an interface |
| `frames` | 1,000,000 records, 20 passes | 1,000, 2 | layer 3 of formats.md (compiler.md, "Bytes stage"): a stream of length-prefixed little-endian records, each a `u32` length, a `u8` kind, a `VarUInt` id, an `i64` time, an `i32` value and a short name, written with writes at an offset into `Bytes.zeros` and decoded through a cursor, a framing loop; the Rust reads a `&[u8]` through a cursor of its own with `from_le_bytes`, the Go a `[]byte` with `encoding/binary` and `binary.Uvarint` |
| `maps` | 200,000 accounts, 20 rounds | 1,000, 2 | `Map` natively (compiler.md, "Bytes stage", step 3): records with a name kept in a `Map<Int, Account>` and a `Map<Str, Int>`, each round built, looked up, a third removed and iterated in insertion order; the Rust keeps std's `HashMap` of each key to its entry's place in a `Vec` in insertion order (indexmap's shape, no crate), the Go a `map` the same way |
| `interp` | 25,600 evaluations, dispatch's `interp` at its size | 3 | **the data stage's milestone**: `dispatch`'s expression tree written ADT-first, `Expr` a sum type and `eval` a `match`; no twins of its own: dispatch's Rust, run `100 interp enum` (and `dyn`), is its, and build.sh builds none for it |
| `slices` | 200,000 log lines, 100,000 objects and 4,000 pages, each parsed 20 times | 1,000 lines, 500 objects and 20 pages, twice | **decision 17**: research/slices.md's three parsers, each with slices, `b[i..j]`, and with offsets, its twin in the same file: log lines split into fields read and dropped, a JSON-ish tokenizer whose tokens keep slices, and pages parsed into records that keep them; the Rust holds `&[u8]`s, the Go `[]byte`s. `retain` keeps 1,000 small slices of each of eight 8 MiB buffers, and then their `copy()`s, which build.sh's `retain` kernels run |

The first four are the Perceus set, ported from Koka's
`test/bench/koka/*.kk` with the same algorithms and outputs. The next
three are the Benchmarks Game's single-threaded algorithms with their
usual output. Together they're vision.md's "Within 2× of Rust" set, short
of its real program, which `examples/just` stands for until it's built
natively.

The micro-benchmarks each put the thing a hypothesis is about next to a
twin without it, in the same file, and print both checksums:

- **`blocks`** runs `map`, `reduce` and `each` over an `Array<Int>`, a
  recursive fold over a tree that takes a block, and a retry-like
  `attempt_n(n, body: fn() -> Int)` called a thousand times a round. Each
  has a twin written as a plain loop, and the block version is compared
  with its twin. The Rust passes closures as generic parameters, so rustc
  specializes them, as Ren's release build means to; Go calls its func
  values through a pointer.
- **`handlers`** calls `Counter.bump`, an operation of a handler with
  state, inside `with counter() in`, next to the same loop calling a
  plain function. The Rust is generic over a `Counter` trait, a direct
  call; the Go goes through an interface.
- **`inout`** is a kernel `step(inout a, inout b, c)` over arrays,
  where knowing `a` and `b` are different arrays lets the compiler keep
  values in registers and vectorize. Rust's `&mut` says the same; Go
  can't.

- **`nested`** writes each element of a grid, an `Array<Array<Int>>`,
  by its indices, maps the grid with `map` inside `map`, and builds and
  scales a list of a million cells by recursion, `Cons { head: i, tail:
  build(...) }`. The first two need a row moved out of the grid while
  it's changed (swap.ml), the third a loop that fills a hole (trmc.ml).
  The Rust writes `g[i][j]`, maps with `into_iter().map().collect()`, which
  reuses each Vec, and builds its list front to back through a `&mut`
  to the next link, as one too long to recurse over must be; the Go is
  the same with pointers, its `map` writing new slices.

- **`bytes`** keeps a million bytes as an `Array<UInt8>` and a million
  numbers as an `Array<Int32>`, smooths the first and mixes the second a
  round at a time in place, and hashes the bytes with FNV-1a at 32 bits,
  `h = h *% 16777619` into a `UInt32`. `wide.ren` is the same program
  with `Array<Int>`s, written as it had to be before sized types, with
  its `xor` a bit at a time: what RESULTS.md's before column runs. The
  Rust and Go keep `u8`s and `i32`s, compute in 64 bits as Ren does, and
  check each store fits, as Ren's do.

`bench.ren`'s `run` prints the checksums in a fixed order, so to time a
kernel alone, write an entry that calls the one you want: each is a plain
function in `bench.ren`.

## Building and measuring them

```sh
sh bench/native/build.sh            # into $TMPDIR/ren-bench-native
sh bench/native/build.sh out/dir    # or REN_BENCH_OUT=out/dir
sh bench/native/measure.sh out/dir results/dir
python3 -I bench/native/summarize.py results/dir
```

`build.sh` builds every Ren program `--debug`, `--release --rc naive`
and `--release`, each with and without `--stats`, and H5's three
`--no-restrict` too, with the release build's C next to them; each
kernel of `blocks` and `handlers` as a program of its own; and the
twins, each `rust/main.rs` with `rustc -C opt-level=3 -C
codegen-units=1` and each `go/main.go` with `go build`, to
`<program>-rust` and `<program>-go`, outside the repository.
`measure.sh` times them with hyperfine and takes peak memory and the
`--stats` counts, and `summarize.py` prints the tables in
[RESULTS.md](RESULTS.md). `ren run main.ren` in a folder runs the
interpreter at full size, which takes from minutes to most of an hour,
but not `cfold`'s: its recursion goes deeper than the interpreter's
limit of 100,000 calls.

## They agree

`native.t` runs every `small.ren` and checks its output, so `dune test`
catches a change in what any Ren program computes. That output is what
the Rust and Go print given the same size: each pair was compared on
2026-10-27, with rustc 1.99.1 and Go 1.27.3 on an Apple M4 Max, at the
small size against `ren run small.ren` and at the full size against each
other. Only `nbody` needed care: its Rust and Go do the arithmetic in the
same order as `bench.ren`, and the Go wraps each product in
`float64(...)`, which stops Go fusing a multiply and an add into one
instruction that rounds once. All three then agree to the bit, and print
the energy from the nearest whole number of billionths, as `%.9f` would.

## Sizes

Full sizes aim at Rust taking about 0.5 to 2 seconds. That machine's
times, Rust then Go:

| Program | Rust | Go |
|---|---|---|
| `rbtree` | 0.74 s | 0.38 s |
| `deriv` | 1.08 s | 0.79 s |
| `nqueens` | 0.61 s | 0.47 s |
| `cfold` | 0.40 s | 0.30 s |
| `binary-trees` | 7.9 s | 4.3 s |
| `nbody` | 1.01 s | 1.68 s |
| `fannkuch` | 1.58 s | 1.47 s |
| `blocks` | 0.88 s | 1.20 s |
| `handlers` | 0.83 s | 1.20 s |
| `inout` | 0.88 s | 1.57 s |
| `nested` | 2.62 s | 2.81 s |
| `bytes` | 0.43 s | 0.72 s |
| `frames` | 0.12 s | 0.28 s |
| `maps` | 0.74 s | 0.85 s |

Three miss the range on purpose. `frames` is timed a pass at a time, its 20 passes less none (profile/measure.py), as the slices kernels are. `cfold` keeps Koka's size, so it can be
compared with Koka's published numbers. `binary-trees` keeps the
Benchmarks Game's and Koka's depth 21: with a `Box` per node and the
system allocator, Rust needs 8 seconds, and Go's collector runs on other
cores (`GOMAXPROCS=1` makes it 9.7 s). RESULTS.md reports Go as it
runs by default, collector on other cores.

Some things the Ren backend has to do that these programs make plain:

- **Deep recursion.** `cfold`'s reassociated tree is a chain of 2^20
  nodes that `eval` and `append_add` recurse down. Koka grows its stack
  and Go's grows itself; the Rust runs the work on a thread with a 1 GiB
  stack.
- **Dropping long lists.** `nqueens` drops a list of 73,712 solutions;
  the Rust drops it a cell at a time, since recursing down the tail
  overflows the stack. Perceus's drop has to do the same.
- **Copying into an array without sharing it.** `fannkuch` copies
  `perm1` into `perm` an element at a time, so `perm` keeps its own
  buffer; `perm = perm1` would share it, and the next write would copy.

## Generated programs, for compile time

`gen/gen.py` writes the programs for "Debug builds faster than Go"
(**H6**): many small modules, each with a record, a sum type, and
functions that build, match, change through `&` and loop over them, in
the subset native steps 2 and 3 compile. Module *k* imports modules
2*k* + 1 and 2*k* + 2, a balanced tree under `main`, so siblings can be
built in parallel.

```sh
python3 -I bench/native/gen/gen.py ren 10000 out/ren10k   # then: ren run main.ren
python3 -I bench/native/gen/gen.py go 10000 out/go10k     # then: go build .
```

Each language gets the lines asked for, about 100 a module in Ren and
170 in Go, so they're the same shape and size, not the same program.
The 10k, 100k and 500k programs all type-check and run in the
interpreter (500k in about 4 seconds), and all build with `go build`.

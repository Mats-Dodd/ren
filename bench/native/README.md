# Native benchmarks

The programs the native slice is measured with ([vision.md](../../vision.md),
"Within 2× of Rust" and "Debug builds faster than Go";
[foundations.md](../../foundations.md), Staging, item 2). Each is written
three times: in Ren, the way the docs teach it, and in Rust and Go, the
way a good programmer in each writes it. The interpreter checks what
each computes. `ren build` (native step 2) compiles those in the
first-order subset, `binary-trees`, `cfold`, `deriv`, `fannkuch` and
`nbody`, and bench/build.t checks each binary prints what `ren run`
does; the rest need native step 3. The timings with hyperfine come in
step 6.

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

`bench.ren`'s `run` prints the checksums in a fixed order, so to time a
kernel alone, write an entry that calls the one you want: each is a plain
function in `bench.ren`.

## Building the twins

```sh
sh bench/native/build.sh            # into $TMPDIR/ren-bench-native
sh bench/native/build.sh out/dir    # or REN_BENCH_OUT=out/dir
```

It compiles each `rust/main.rs` with `rustc -C opt-level=3 -C
codegen-units=1` and each `go/main.go` with `go build`, to
`<program>-rust` and `<program>-go`, outside the repository. It
doesn't build the Ren yet: `ren build --release main.ren` in a folder
does, for the programs in the subset, and step 6 adds them here. `ren run main.ren` in a folder runs the
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

Two miss the range on purpose. `cfold` keeps Koka's size, so it can be
compared with Koka's published numbers. `binary-trees` keeps the
Benchmarks Game's and Koka's depth 21: with a `Box` per node and the
system allocator, Rust needs 8 seconds, and Go's collector runs on other
cores (`GOMAXPROCS=1` makes it 9.7 s). Step 6 should say which it
reports.

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

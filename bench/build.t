`ren build` compiles each program the native slice's subset
covers (compiler.md, "Native slice") to a debug binary, with its
statistics and under AddressSanitizer and UndefinedBehaviorSanitizer,
and each prints exactly what `ren run` prints, to stdout and to stderr,
and exits as it does. Each is built twice: with its counting placed
by Perceus, the default, and with the naive counting, `--rc naive`,
and the two print the same. The statistics say no object is still
alive when either ends. Mem Lint checks every program `ren build`
compiles, and its counting, path by path.

  $ export REN_CFLAGS='-fsanitize=address,undefined'
  $ same() {
  >   for rc in perceus naive; do
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    ren build --debug --stats --rc $rc "$f" -o ./native.bin &&
  >    { ./native.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    grep -v -e '^ren stats: ' -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >      -e '^False positive error reports may follow' \
  >      -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >      native.err > native.err2;
  >    if cmp -s native.out interp.out && cmp -s native.err2 interp.err &&
  >       cmp -s native.code interp.code
  >    then echo "$1, $rc: the same, $(cat native.code), $(grep -o 'objects live at exit [0-9]*' native.err)"
  >    else echo "$1, $rc: different"; diff native.out interp.out; diff native.err2 interp.err
  >    fi)
  >   done
  > }

The benchmarks of `bench`. `overflow` reaches the stack-overflow panic,
after which AddressSanitizer warns that it can't clean up a stack that
deep, which is left out.

  $ for f in fib deep loop overflow frames; do same $f.ren; done
  fib.ren, perceus: the same, exit 0, objects live at exit 0
  fib.ren, naive: the same, exit 0, objects live at exit 0
  deep.ren, perceus: the same, exit 0, objects live at exit 0
  deep.ren, naive: the same, exit 0, objects live at exit 0
  loop.ren, perceus: the same, exit 0, objects live at exit 0
  loop.ren, naive: the same, exit 0, objects live at exit 0
  overflow.ren, perceus: the same, exit 1, objects live at exit 0
  overflow.ren, naive: the same, exit 1, objects live at exit 0
  frames.ren, perceus: the same, exit 0, objects live at exit 0
  frames.ren, naive: the same, exit 0, objects live at exit 0

Every native benchmark, at its small size:

  $ for f in native/*/small.ren; do same $f; done
  native/binary-trees/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/binary-trees/small.ren, naive: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, naive: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, naive: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, naive: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, naive: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, naive: the same, exit 0, objects live at exit 0
  native/inout/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/inout/small.ren, naive: the same, exit 0, objects live at exit 0
  native/nbody/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/nbody/small.ren, naive: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, naive: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, naive: the same, exit 0, objects live at exit 0
  native/stack/small.ren, perceus: the same, exit 0, objects live at exit 0
  native/stack/small.ren, naive: the same, exit 0, objects live at exit 0

And the examples in the subset, the single files and two of the
folders:

  $ for f in ../examples/*.ren ../examples/shop/main.ren ../examples/two/main.ren; do same $f; done
  ../examples/blocks.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/blocks.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/fib.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/fib.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/infer.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/infer.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/plans.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/plans.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/values.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/values.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/shop/main.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/shop/main.ren, naive: the same, exit 0, objects live at exit 0
  ../examples/two/main.ren, perceus: the same, exit 0, objects live at exit 0
  ../examples/two/main.ren, naive: the same, exit 0, objects live at exit 0

H1, in the debug build: a block costs a call, never an allocation. Its
environment is on its writer's stack, so each kernel of
native/blocks/bench.ren written with a block allocates exactly as many
objects as its twin written as a loop; `block calls` counts the calls.

  $ cd native/blocks
  $ for k in map reduce each; do for v in blocks loop; do
  >   printf 'import bench\n\nfn main() uses Console =\n  var xs: Array<Int> = []\n  for i in 0..1000\n    &xs.push(i * 7 %% 1000)\n  print(bench.%s_%s(xs, 10))\n' $k $v > ${k}_$v.ren
  > done; done
  $ for v in blocks loop; do
  >   printf 'import bench\n\nfn main() uses Console = print(bench.fold_%s(bench.build(0, 1000), 10))\n' $v > fold_$v.ren
  >   printf 'import bench\n\nfn main() uses Console = print(bench.attempt_%s(10))\n' $v > attempt_$v.ren
  > done
  $ allocations() {
  >   ren build --debug --stats "$1.ren" -o ./h1.bin && ./h1.bin 2>&1 > /dev/null |
  >     grep -o 'allocations [0-9]*'
  > }
  $ for k in map reduce each fold attempt; do
  >   b=$(allocations ${k}_blocks); l=$(allocations ${k}_loop)
  >   if [ "$b" = "$l" ]; then echo "$k: $b, both"; else echo "$k: $b with blocks, $l with loops"; fi
  > done
  map: allocations 13, both
  reduce: allocations 3, both
  each: allocations 3, both
  fold: allocations 1002, both
  attempt: allocations 2, both
  $ cd ../..

H3, what Perceus saves over the naive counting, in the debug build.
Counting what it must: rbtree's counts again and drops strictly
fewer times than the naive build's.

  $ counts() {
  >   ren build --debug --stats --rc $2 "$1" -o ./h3.bin && ./h3.bin 2>&1 > /dev/null |
  >     sed -n 's/.*dups \([0-9]*\), drops \([0-9]*\).*/\1 \2/p' | { read d r; echo $((d + r)); }
  > }
  $ cd native/rbtree
  $ p=$(counts small.ren perceus); n=$(counts small.ren naive)
  $ if [ "$p" -lt "$n" ]; then echo "rbtree: fewer with Perceus"; else echo "rbtree: $p with Perceus, $n naive"; fi
  rbtree: fewer with Perceus
  $ cd ../..

Changing what's unique in place: fannkuch allocates its arrays once,
and nothing for each permutation, so it allocates as many objects for
7 as for 6; the naive build copies an array at each change. And
`map` over an array it builds fills it in place, so building one of
2000 elements allocates as many objects as one of 1000.

  $ allocations() {
  >   ren build --debug --stats --rc $2 "$1" -o ./h3.bin && ./h3.bin 2>&1 > /dev/null |
  >     grep -o 'allocations [0-9]*'
  > }
  $ cd native/fannkuch
  $ for n in 6 7; do printf 'import bench\n\nfn main() uses Console = bench.run(%d)\n' $n > run_$n.ren; done
  $ for rc in perceus naive; do
  >   a=$(allocations run_6.ren $rc); b=$(allocations run_7.ren $rc)
  >   if [ "$a" = "$b" ]; then echo "fannkuch, $rc: $a, both"; else echo "fannkuch, $rc: more for 7"; fi
  > done
  fannkuch, perceus: allocations 10, both
  fannkuch, naive: more for 7
  $ cd ../blocks
  $ for n in 1000 2000; do
  >   printf 'import bench\n\nfn main() uses Console =\n  var xs: Array<Int> = []\n  for i in 0..%d\n    &xs.push(i)\n  print(bench.map_blocks(xs, 10))\n' $n > map_$n.ren
  > done
  $ for rc in perceus naive; do
  >   a=$(allocations map_1000.ren $rc); b=$(allocations map_2000.ren $rc)
  >   if [ "$a" = "$b" ]; then echo "map, $rc: $a, both"; else echo "map, $rc: more for 2000"; fi
  > done
  map, perceus: allocations 13, both
  map, naive: more for 2000
  $ cd ../..

The release build (native step 5) compiles the program specialized
(specialize.ml): a copy of each function for the types, blocks and
known handlers each call gives it, which Core Lint checks and `ren run
--release` runs. Each program built `--release`, under the sanitizers,
prints what `ren run` prints, and ends with no object alive; so does
`ren run --release`.

  $ release() {
  >   (cd "$(dirname "$1")" && f=$(basename "$1") &&
  >    ren build --release --stats "$f" -o ./release.bin 2> release.made &&
  >    { ./release.bin > native.out 2> native.err; echo "exit $?" > native.code; } &&
  >    { ren run "$f" > interp.out 2> interp.err; echo "exit $?" > interp.code; } &&
  >    { ren run --release "$f" > spec.out 2> spec.err; echo "exit $?" > spec.code; } &&
  >    grep -v -e '^ren stats: ' -e '^==[0-9]*==WARNING: ASan is ignoring' \
  >      -e '^False positive error reports may follow' \
  >      -e '^For details see https://github.com/google/sanitizers/issues/189' \
  >      native.err > native.err2;
  >    if cmp -s native.out interp.out && cmp -s native.err2 interp.err &&
  >       cmp -s native.code interp.code && cmp -s spec.out interp.out &&
  >       cmp -s spec.err interp.err && cmp -s spec.code interp.code
  >    then echo "$1, release: the same, $(cat native.code), $(grep -o 'objects live at exit [0-9]*' native.err)"
  >    else echo "$1, release: different"; diff native.out interp.out; diff native.err2 interp.err; diff spec.out interp.out
  >    fi)
  > }
  $ for f in fib deep loop overflow frames; do release $f.ren; done
  fib.ren, release: the same, exit 0, objects live at exit 0
  deep.ren, release: the same, exit 0, objects live at exit 0
  loop.ren, release: the same, exit 0, objects live at exit 0
  overflow.ren, release: the same, exit 1, objects live at exit 0
  frames.ren, release: the same, exit 0, objects live at exit 0
  $ for f in native/*/small.ren; do release $f; done
  native/binary-trees/small.ren, release: the same, exit 0, objects live at exit 0
  native/blocks/small.ren, release: the same, exit 0, objects live at exit 0
  native/cfold/small.ren, release: the same, exit 0, objects live at exit 0
  native/deriv/small.ren, release: the same, exit 0, objects live at exit 0
  native/fannkuch/small.ren, release: the same, exit 0, objects live at exit 0
  native/handlers/small.ren, release: the same, exit 0, objects live at exit 0
  native/inout/small.ren, release: the same, exit 0, objects live at exit 0
  native/nbody/small.ren, release: the same, exit 0, objects live at exit 0
  native/nqueens/small.ren, release: the same, exit 0, objects live at exit 0
  native/rbtree/small.ren, release: the same, exit 0, objects live at exit 0
  native/stack/small.ren, release: the same, exit 0, objects live at exit 0
  $ for f in ../examples/*.ren ../examples/shop/main.ren ../examples/two/main.ren; do release $f; done
  ../examples/blocks.ren, release: the same, exit 0, objects live at exit 0
  ../examples/fib.ren, release: the same, exit 0, objects live at exit 0
  ../examples/infer.ren, release: the same, exit 0, objects live at exit 0
  ../examples/plans.ren, release: the same, exit 0, objects live at exit 0
  ../examples/values.ren, release: the same, exit 0, objects live at exit 0
  ../examples/shop/main.ren, release: the same, exit 0, objects live at exit 0
  ../examples/two/main.ren, release: the same, exit 0, objects live at exit 0

What it made, with `--stats`: blocks's five kernels each lift their
block, and handlers's `Counter` is known where it's installed.

  $ for d in blocks handlers; do (cd native/$d && sed 's/^ren specialized: //' release.made); done
  21 copies, 5 blocks lifted, 0 handlers known, 0 calls past the budget
  6 copies, 0 blocks lifted, 1 handlers known, 0 calls past the budget

H1, in the release build: the kernels written with a block make no
indirect call and build no block. The only functions that do are the
real `Console`'s, which isn't known, and `$start`'s, which installs it.

  $ cd native/blocks
  $ ren build --release --emit-c small.ren > release.c
  $ awk '/^static .*\) \{$/ { f = $0; sub(/\(.*/, "", f); sub(/.* /, "", f) }
  >      /\.code\(|\(\(ren_block\)\{/ { print f }' release.c | sort -u
  ren_bench_line_1
  ren_real_console_handler
  ren_small__start

And each kernel written with a block allocates exactly as many objects
as its twin written as a loop, as in the debug build:

  $ allocations() {
  >   ren build --release --stats "$1.ren" -o ./h1.bin 2> /dev/null && ./h1.bin 2>&1 > /dev/null |
  >     grep -o 'allocations [0-9]*'
  > }
  $ for k in map reduce each fold attempt; do
  >   b=$(allocations ${k}_blocks); l=$(allocations ${k}_loop)
  >   if [ "$b" = "$l" ]; then echo "$k: $b, both"; else echo "$k: $b with blocks, $l with loops"; fi
  > done
  map: allocations 13, both
  reduce: allocations 3, both
  each: allocations 3, both
  fold: allocations 1001, both
  attempt: allocations 2, both

Each `inout` parameter is a `restrict` pointer in the release build,
which `--no-restrict` leaves out:

  $ grep '^static.*restrict.*;$' release.c
  static int64_t ren_bench_attempt_n_1(const ren_ev* v1_ev, int64_t v2_n, int64_t* restrict v3_calls, int64_t v4_i);
  static int64_t ren_bench_attempt_blocks_1_1(const ren_ev* v1_ev, int64_t* restrict v2_calls, int64_t v3_i);
  static ren_unit ren_Array_each_1(const ren_ev* v1_ev, ren_obj* v2_self, int64_t* restrict v3_total, int64_t v4_k);
  static ren_unit ren_bench_each_blocks_1_1(const ren_ev* v1_ev, int64_t* restrict v2_total, int64_t v3_k, int64_t v4_x);
  $ ren build --release --no-restrict --emit-c small.ren | grep -c ' restrict v'
  0
  [1]
  $ cd ../..

H2: `Counter.bump`, called where its handler is known, is a direct call
of the operation, lifted, given the handler's state, a pointer into the
frame of the `with` that installed it. The two indirect calls left are
the real `Console`'s `write` and the body `$start` installs it for:

  $ cd native/handlers
  $ ren build --release --emit-c small.ren > release.c
  $ grep -n 'counter_bump(' release.c | sed 's/^[0-9]*://'
  static int64_t ren_bench_counter_bump(const ren_ev* v1_ev, int64_t* v2_total, int64_t v3_k);
      int64_t v15_result = ren_bench_counter_bump(v1_ev, v3_total, v14_arith);
  static int64_t ren_bench_counter_bump(const ren_ev* v1_ev, int64_t* v2_total, int64_t v3_k) {
  $ grep -c 'REN_STAT(block_calls)' release.c
  2
  $ cd ../..

A copied record or tuple of scalars (copied.ml) is a C struct in the
release build: passed by value, and kept in an array's elements. One
whose value would have to be a word, or a field of an object, stays
boxed: here `P` in the second program, which a handler's operation
not known takes and a block not lifted is given.

  $ cat > structs.ren <<'EOF'
  > type P = { x: Int, y: Int }
  > type V = { a: Float, b: Float, on: Bool }
  > type Q = { p: P, n: Int }
  > 
  > fn add(p: P, q: P) -> P = P { x: p.x + q.x, y: p.y + q.y }
  > fn swap(t: (Int, Int)) -> (Int, Int) =
  >   let (a, b) = t
  >   (b, a)
  > fn bump(inout p: P) =
  >   p.x += 1
  > fn each(xs: Array<P>, f: fn(P)) =
  >   for x in xs
  >     try f(x)
  > 
  > dep Acc =
  >   put: fn(p: P)
  >   total: fn() -> P
  > 
  > handler summing() for Acc =
  >   var t = P { x: 0, y: 0 }
  >   put(p) => t = add(t, p)
  >   total() => t
  > 
  > fn sum_two() -> Int uses Acc =
  >   Acc.put(P { x: 1, y: 2 })
  >   Acc.put(P { x: 3, y: 4 })
  >   Acc.total().y
  > 
  > fn main() uses Console =
  >   var ps: Array<P> = []
  >   for i in 0..5
  >     &ps.push(P { x: i, y: i * 2 })
  >   ps[2].y = 100
  >   var s = P { x: 0, y: 0 }
  >   for p in ps
  >     s = add(s, p)
  >   print(s.x)
  >   print(s.y)
  >   bump(&s)
  >   print(s.x)
  >   let (a, b) = swap((1, 2))
  >   print(a * 10 + b)
  >   var n = 0
  >   each(ps, fn(p) => n += p.y)
  >   print(n)
  >   let v = V { a: 1.5, b: 2.5, on: true }
  >   var w = v
  >   w.a = 3.0
  >   print(w.a + w.b)
  >   if w.on then print("on") else print("off")
  >   print(with summing() in sum_two())
  >   match (s.x, s.y)
  >     (11, _) => print("eleven")
  >     _ => print("other")
  >   var qs = ps
  >   qs[0].x = 42
  >   print(ps[0].x + qs[0].x)
  >   let r = [P { x: 5, y: 6 }, P { x: 7, y: 8 }]
  >   print(r[1].y)
  >   var big: Array<P> = []
  >   for i in 0..100
  >     &big.push(P { x: i, y: 0 })
  >   var k = 0
  >   for i in 0..100
  >     big[i].y = big[i].x * 2
  >     k += big[i].y
  >   print(k)
  >   let arr = [(1, 2), (3, 4)]
  >   var tot = 0
  >   for t in arr
  >     let (x, y) = t
  >     tot += x * y
  >   print(tot)
  >   print(ps.len())
  > EOF
  $ cat > boxed.ren <<'EOF'
  > type P = { x: Int, y: Int }
  > 
  > dep Log =
  >   put: fn(p: P) -> P
  > 
  > handler twice() for Log =
  >   put(p) => P { x: p.x * 2, y: p.y * 2 }
  > 
  > fn go(n: Int) -> Int uses Log =
  >   var s = 0
  >   for i in 0..n
  >     s += Log.put(P { x: i, y: 1 }).x
  >   s
  > 
  > fn pick(c: Bool) -> P = if c then P { x: 1, y: 2 } else P { x: 3, y: 4 }
  > 
  > fn main() uses Console =
  >   let h = twice()
  >   print(with h in go(4))
  >   let f = fn(p: P) => p.x + p.y
  >   print(f(pick(true)) + f(pick(false)))
  >   var g = P { x: 0, y: 0 }
  >   let ts = [(1, 2.5), (2, 3.5)]
  >   var sum = 0.0
  >   for t in ts
  >     let (i, x) = t
  >     sum += x * Float.of(i)
  >   print(sum)
  > EOF
  $ for f in structs boxed; do release $f.ren; ren build --release --emit-c $f.ren | grep 'typedef struct { ren_val'; done
  structs.ren, release: the same, exit 0, objects live at exit 0
  typedef struct { ren_val s[2]; } ren_struct_0;
  typedef struct { ren_val s[2]; } ren_struct_1;
  typedef struct { ren_val s[3]; } ren_struct_2;
  boxed.ren, release: the same, exit 0, objects live at exit 0
  typedef struct { ren_val s[2]; } ren_struct_0;

nbody's bodies are structs in the array, so a step allocates nothing,
where the debug build allocates a body for each change of one:

  $ cd native/nbody
  $ for mode in debug release; do
  >   ren build --$mode --stats small.ren -o ./nbody.bin 2> /dev/null && ./nbody.bin 2>&1 > /dev/null |
  >     grep -o 'allocations [0-9]*' | sed "s/^/$mode: /"
  > done
  debug: allocations 65020
  release: allocations 12
  $ cd ../..

A loop that changes an array it holds, and makes no other reference to
it, has the array made unique once, before it, and indexes its
elements directly inside (hoist.ml); a field of a struct in an array is
written in place. The loop is a function of its own, inlined, whose
buffers are `restrict` parameters. `kept` shares `a` when `scale` runs,
so `scale` copies it, once, and `kept` doesn't change; `main`'s own
loop passes `&p` to a call, so it isn't hoisted. An index out of bounds
in a hoisted loop panics as it would anywhere:

  $ cat > hoist.ren <<'EOF'
  > type B = { x: Float, v: Float }
  > 
  > fn scale(inout a: Array<Int>, k: Int) =
  >   for i in 0..a.len()
  >     a[i] = a[i] * k
  > 
  > fn mix(inout a: Array<Int>, inout b: Array<Int>, c: Array<Int>) =
  >   for i in 0..a.len()
  >     a[i] = a[i] + b[i] * c[i]
  >     b[i] = b[i] + a[i]
  > 
  > fn nudge(inout bs: Array<B>) =
  >   for i in 0..bs.len()
  >     bs[i].x += bs[i].v
  > 
  > fn shout(inout ss: Array<Str>) =
  >   for i in 0..ss.len()
  >     ss[i] = ss[i].concat("!")
  > 
  > fn poke(inout a: Array<Int>, i: Int) =
  >   a[i] = a[i] * 2
  > 
  > fn main() uses Console =
  >   var a = [1, 2, 3]
  >   let kept = a
  >   scale(&a, 10)
  >   print(kept[0] + kept[2])
  >   print(a[0] + a[2])
  >   var b = [4, 5, 6]
  >   mix(&a, &b, kept)
  >   print(a[1] + b[1])
  >   var bs = [B { x: 1.0, v: 0.5 }, B { x: 2.0, v: 0.25 }]
  >   let before = bs
  >   nudge(&bs)
  >   print(before[0].x + bs[0].x)
  >   var ss = ["a", "b"]
  >   let old = ss
  >   shout(&ss)
  >   Console.write(old[0].concat(ss[0]).concat(ss[1]))
  >   var p = [1, 2, 3]
  >   for i in 0..p.len()
  >     p[i] = p[i] + 1
  >     poke(&p, i)
  >   print(p[0] + p[1] + p[2])
  > EOF
  $ cat > bounds.ren <<'EOF'
  > fn fill(inout a: Array<Int>, n: Int) =
  >   for i in 0..n
  >     a[i] = i
  > 
  > fn main() uses Console =
  >   var a = [0, 0]
  >   fill(&a, 3)
  >   print(a[0])
  > EOF
  $ release hoist.ren && cat native.out
  hoist.ren, release: the same, exit 0, objects live at exit 0
  4
  40
  65
  2.5
  aa!b!
  18
  $ release bounds.ren && cat native.err | grep -v '^ren stats'
  bounds.ren, release: the same, exit 1, objects live at exit 2
  error: panic: index 2 is out of bounds for an array of length 2
    ┌─ bounds.ren:3:5
  3 │     a[i] = i
    │     ^^^^
  $ ren build --release --emit-c hoist.ren | grep '^static inline.*_loop_'
  static inline __attribute__((always_inline)) void ren_hoist_shout_1_loop_1(int64_t* v3_i, int64_t v6_stop, int64_t v27_len, ren_val* restrict v30_buf) {
  static inline __attribute__((always_inline)) void ren_hoist_nudge_1_loop_1(int64_t* v3_i, int64_t v6_stop, int64_t v34_len, ren_val* restrict v37_buf) {
  static inline __attribute__((always_inline)) void ren_hoist_mix_1_loop_1(int64_t* v5_i, int64_t v8_stop, int64_t v51_len, ren_val* restrict v54_buf, int64_t v56_len, ren_val* restrict v59_buf, int64_t v61_len, ren_val* restrict v63_buf) {
  static inline __attribute__((always_inline)) void ren_hoist_scale_1_loop_1(int64_t v3_k, int64_t* v4_i, int64_t v7_stop, int64_t v29_len, ren_val* restrict v32_buf) {
  $ ren build --release --no-restrict --emit-c hoist.ren | grep -c ' restrict v'
  0
  [1]

What the native slice doesn't have says so, at the code that needs it,
like the real `Clock`:

  $ cat > clock.ren <<'EOF'
  > fn main() uses Clock, Console =
  >   let t = Clock.now()
  >   print(t)
  > EOF
  $ ren build clock.ren
  error: the real `Clock` isn't in the native slice yet
    ┌─ clock.ren:1:4
  1 │ fn main() uses Clock, Console =
    │    ^^^^ `ren build` can't compile this yet
    help: run it with `ren run clock.ren`
  [1]
  $ cd ../..

A `var` walked down a list or a tree, by a `match` of it that assigns
it a field its pattern took out, or a constant: the field the variable
holds next is the one reference the old value gave up, counted once,
and a constant where the loop goes round holds none.

  $ cat > walks.ren <<'EOF'
  > type List = Nil | Cons(h: Int, t: List)
  > type T = Leaf | Node(l: T, r: T)
  > 
  > fn count(xs: List) -> Int =
  >   var n = 0
  >   var cur = xs
  >   while true
  >     match cur
  >       Nil => break
  >       Cons(_, t) =>
  >         n += 1
  >         cur = t
  >   n
  > 
  > fn count_go(xs: List) -> Int =
  >   var n = 0
  >   var cur = xs
  >   var go = true
  >   while go
  >     match cur
  >       Nil => go = false
  >       Cons(_, t) =>
  >         n += 1
  >         cur = t
  >   n
  > 
  > fn first(xs: List) -> Int =
  >   var n = 0
  >   var cur = xs
  >   while true
  >     match cur
  >       Nil => break
  >       Cons(h, _) =>
  >         n = h
  >         cur = Nil
  >   n
  > 
  > fn last(xs: List) -> Int =
  >   var cur = xs
  >   var out = 0
  >   for i in 0..100
  >     match cur
  >       Nil => out = out + 0
  >       Cons(h, t) =>
  >         out = h
  >         cur = t
  >   out
  > 
  > fn main() uses Console =
  >   let xs = Cons(1, Cons(2, Cons(3, Nil)))
  >   print(count(xs) + count_go(xs) * 10 + first(xs) * 100 + last(xs) * 1000)
  >   var t = Node(Node(Leaf, Leaf), Leaf)
  >   var n = 0
  >   var go = true
  >   while go
  >     match t
  >       Leaf => go = false
  >       Node(l, _) =>
  >         n += 1
  >         t = l
  >   print(n)
  > EOF
  $ same walks.ren; release walks.ren
  walks.ren, perceus: the same, exit 0, objects live at exit 0
  walks.ren, naive: the same, exit 0, objects live at exit 0
  walks.ren, release: the same, exit 0, objects live at exit 0

A call given a block the release build lifts, and one it doesn't, a
`let` of a block, that uses the same variable: the lifted one would be
given that variable when the call is made, and miss what the other
changes during it, so neither is lifted.

  $ cat > siblings.ren <<'EOF'
  > fn both(f: fn(), g: fn() -> Int) -> Int =
  >   try f()
  >   let a = try g()
  >   try f()
  >   a
  > 
  > fn main() uses Console =
  >   var n = 10
  >   let get = fn() => n
  >   print(both(fn() => n -= 1, get))
  >   let dec = fn() => n -= 1
  >   print(both(dec, fn() => n))
  >   print(n)
  > EOF
  $ release siblings.ren; ren run siblings.ren
  siblings.ren, release: the same, exit 0, objects live at exit 0
  9
  7
  6

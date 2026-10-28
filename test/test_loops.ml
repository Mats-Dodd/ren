(* Loops that don't index (foundations.md, decision 16): `for i, x in xs`
   and `for i, x in &xs`, which give each element's index too; `zip`, a
   cursor over several arrays, which a `for` goes over without making
   it; and the indices bounds.ml proves in bounds, which Core prints as
   `get-in` and `set-in` and a native build doesn't check, and the loops
   it makes twice, `if n <= b.len()` a copy that proves `b[i]` too. *)

open Helpers

(* ---- the index ---- *)

let%expect_test "for i, x gives each element with where it is" =
  run
    {|
fn main() uses Console =
  var xs = [10, 20, 30]
  var t = 0
  for i, x in xs
    t += i * x
  print(t)
  let ys = [1, 2, 3]
  for i, x in &xs
    x += ys[i] + i
  print(xs)
  for _, x in ["a", "b"]
    print(x)
  for i, (k, v) in Map.of([(1, "one"), (2, "two")])
    print((i, k, v))
  for i, x in Set.of([7, 8])
    print((i, x))
  for i, x in xs
    if i == 1 then break
    print(x)
|};
  [%expect
    {|
    80
    [11, 23, 35]
    a
    b
    (0, 1, "one")
    (1, 2, "two")
    (0, 7)
    (1, 8)
    11
    ()
    |}]

let%expect_test "the index is parsed before the element" =
  ast {|
fn f(xs) =
  for i, x in &xs
    x += i
|};
  [%expect
    {| (fn f (xs) (for i x (& xs) (+= x i))) |}]

let%expect_test "a range and a cursor have no index, which can't be changed" =
  check_error {|
fn main() =
  for i, x in 0..3
    print(x)
|};
  [%expect
    {|
    error: a range gives only its numbers, with no index beside them
      ┌─ test.ren:2:7
    2 │   for i, x in 0..3
      │       ^
      help: write `for x in ...`: the number is its own index
    |}];
  check_error {|
fn main() =
  for (a, b), x in [1]
    print(x)
|};
  [%expect
    {|
    error: the index before the `,` in a `for` is a name, or `_`
      ┌─ test.ren:2:7
    2 │   for (a, b), x in [1]
      │       ^^^^^^
      help: write `for i, (a, b) in ...`, the index first
    |}];
  check_error
    {|
fn main() uses Console =
  for i, (x, y) in [1].zip([2])
    print(x)
|};
  [%expect
    {|
    error: a `for` over a cursor has no index
      ┌─ test.ren:2:7
    2 │   for i, (x, y) in [1].zip([2])
      │       ^
      = an index is where an element is in an array, a map or a set, and a cursor gives each element without one
      help: count them with a `var i = 0`, and `i += 1` at the end of the body
    |}];
  check_error {|
fn main() =
  for i, x in [1, 2]
    i = 3
|};
  [%expect
    {|
    error: `i` is the loop's index, so it can't be changed
      ┌─ test.ren:3:5
    3 │     i = 3
      │     ^
      help: it says where the element is: keep a count you change in a `var` of its own
    |}]

(* ---- zip ---- *)

let%expect_test "zip goes over arrays together, as long as each has an element" =
  run
    {|
fn main() uses Console =
  let xs = [1.0, 2.0, 3.0]
  let ys = [4.0, 5.0]
  var dot = 0.0
  for (x, y) in xs.zip(ys)
    dot += x * y
  print(dot)
  for (x, y, z) in [1, 2, 3].zip(["a", "b", "c", "d"]).zip([true, false, true])
    print((x, y, z))
  for p in [1, 2].zip([3, 4])
    print(p)
  // a cursor that keeps its place: the second loop goes on from the first
  var z = [1, 2, 3].zip(["a", "b", "c"])
  for (x, _) in &z
    print(x)
    break
  for (_, s) in &z
    print(s)
  print(&z.next())
|};
  [%expect
    {|
    14.0
    (1, "a", true)
    (2, "b", false)
    (3, "c", true)
    (1, 3)
    (2, 4)
    1
    b
    c
    None
    ()
    |}]

(* ---- what's proved in bounds ---- *)

let%expect_test "a loop's count indexes the arrays it's bounded by without a check" =
  core
    {|
fn total(xs: Array<Int>) -> Int =
  var t = 0
  for x in xs
    t += x
  t

fn step(inout a: Array<Int>, b: Array<Int>) =
  for i in 0..a.len()
    a[i] = a[i] + b[i]

fn dot(xs: Array<Int>, ys: Array<Int>) -> Int =
  var t = 0
  for (x, y) in xs.zip(ys)
    t += x * y
  t

fn pairs(xs: Array<Int>) -> Int =
  var t = 0
  for i in 0..xs.len()
    for j in (i + 1)..xs.len()
      t += xs[i] * xs[j]
  t

fn main() = ()
|};
  [%expect
    {|
    (fn total (xs/1) ev/2
      (let t/3 0
        (seq
          (let $xs/4 xs/1
            (let $n/5 (length $xs/4)
              (let $i/6 0
                (while (< $i/6 $n/5)
                  (let x/7 (get-in $xs/4 $i/6)
                    (seq (= t/3 (+ t/3 x/7)) (= $i/6 (+ $i/6 1))))))))
          t/3)))
    (fn step (a/1 b/2) ev/3
      (let $i/4 0
        (let $stop/5 (call ev/3 Array.len a/1)
          (if (<= $stop/5 (length b/2))
            (while (< $i/4 $stop/5)
              (let i/6 $i/4
                (seq
                  (let $index/7 i/6
                    (let $v/8 (+ (get-in a/1 i/6) (get-in b/2 i/6))
                      (= a/1 (set-in a/1 $index/7 $v/8))))
                  (= $i/4 (+ $i/4 1)))))
            (while (< $i/4 $stop/5)
              (let i/9 $i/4
                (seq
                  (let $index/10 i/9
                    (let $v/11 (+ (get-in a/1 i/9) (get b/2 i/9))
                      (= a/1 (set-in a/1 $index/10 $v/11))))
                  (= $i/4 (+ $i/4 1)))))))))
    (fn dot (xs/1 ys/2) ev/3
      (let t/4 0
        (seq
          (let $xs/5 xs/1
            (let $xs/6 ys/2
              (let $len/7 (length $xs/5)
                (let $len/8 (length $xs/6)
                  (let $n/9 (if (< $len/7 $len/8) $len/7 $len/8)
                    (let $i/10 0
                      (while (< $i/10 $n/9)
                        (let x/11 (get-in $xs/5 $i/10)
                          (let y/12 (get-in $xs/6 $i/10)
                            (seq (let $v/13 (* x/11 y/12) (= t/4 (+ t/4 $v/13)))
                              (= $i/10 (+ $i/10 1))))))))))))
          t/4)))
    (fn pairs (xs/1) ev/2
      (let t/3 0
        (seq
          (let $i/4 0
            (let $stop/5 (call ev/2 Array.len xs/1)
              (while (< $i/4 $stop/5)
                (let i/6 $i/4
                  (seq
                    (let $i/7 (+ i/6 1)
                      (let $stop/8 (call ev/2 Array.len xs/1)
                        (while (< $i/7 $stop/8)
                          (let j/9 $i/7
                            (seq
                              (let $v/10 (* (get-in xs/1 i/6) (get-in xs/1 j/9))
                                (= t/3 (+ t/3 $v/10)))
                              (= $i/7 (+ $i/7 1)))))))
                    (= $i/4 (+ $i/4 1)))))))
          t/3)))
    (fn main () ev/1 ())
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "an index stays checked where the array can change, or the count isn't one" =
  core
    {|
fn grows(xs: Array<Int>) -> Int =
  var ys = xs
  var t = 0
  for i in 0..ys.len()
    &ys.push(1)
    t += ys[i]
  t

fn shrinks(xs: Array<Int>) -> Int =
  var ys = xs
  var t = 0
  for i in 0..ys.len()
    let f = fn() => ys = []
    f()
    t += ys[i]
  t

fn ahead(xs: Array<Int>) -> Int =
  var t = 0
  for i in 1..xs.len()
    t += xs[i + 1]
  t

fn below(xs: Array<Int>, lo: Int) -> Int =
  var t = 0
  for i in lo..xs.len()
    t += xs[i]
  t

fn main() = ()
|};
  [%expect
    {|
    (fn grows (xs/1) ev/2
      (let ys/3 xs/1
        (let t/4 0
          (seq
            (let $i/5 0
              (let $stop/6 (call ev/2 Array.len ys/3)
                (while (< $i/5 $stop/6)
                  (let i/7 $i/5
                    (seq
                      (seq (call ev/2 Array.push &ys/3 1)
                        (let $v/8 (get ys/3 i/7) (= t/4 (+ t/4 $v/8))))
                      (= $i/5 (+ $i/5 1)))))))
            t/4))))
    (fn shrinks (xs/1) ev/2
      (let ys/3 xs/1
        (let t/4 0
          (seq
            (let $i/5 0
              (let $stop/6 (call ev/2 Array.len ys/3)
                (while (< $i/5 $stop/6)
                  (let i/7 $i/5
                    (seq
                      (let f/8
                        (lambda () (captures ys/3 ev/2) ev/9 (extend ev/2)
                          (= ys/3 (array)))
                        (seq (call ev/2 f/8)
                          (let $v/10 (get ys/3 i/7) (= t/4 (+ t/4 $v/10)))))
                      (= $i/5 (+ $i/5 1)))))))
            t/4))))
    (fn ahead (xs/1) ev/2
      (let t/3 0
        (seq
          (let $i/4 1
            (let $stop/5 (call ev/2 Array.len xs/1)
              (while (< $i/4 $stop/5)
                (let i/6 $i/4
                  (seq (let $v/7 (get xs/1 (+ i/6 1)) (= t/3 (+ t/3 $v/7)))
                    (= $i/4 (+ $i/4 1)))))))
          t/3)))
    (fn below (xs/1 lo/2) ev/3
      (let t/4 0
        (seq
          (let $i/5 lo/2
            (let $stop/6 (call ev/3 Array.len xs/1)
              (while (< $i/5 $stop/6)
                (let i/7 $i/5
                  (seq (let $v/8 (get xs/1 i/7) (= t/4 (+ t/4 $v/8)))
                    (= $i/5 (+ $i/5 1)))))))
          t/4)))
    (fn main () ev/1 ())
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "an index behind the count, and a loop made twice for another array" =
  core
    {|
fn smooth(inout xs: Array<Int>) =
  for i in 1..xs.len()
    xs[i] = (xs[i] + xs[i - 1]) / 2

fn diff(xs: Array<Int>, ys: Array<Int>) -> Int =
  var t = 0
  for i in 2..xs.len()
    t += xs[i] - ys[i - 2]
  t

fn main() = ()
|};
  [%expect {|
    (fn smooth (xs/1) ev/2
      (let $i/3 1
        (let $stop/4 (call ev/2 Array.len xs/1)
          (while (< $i/3 $stop/4)
            (let i/5 $i/3
              (seq
                (let $index/6 i/5
                  (let $v/7 (/ (+ (get-in xs/1 i/5) (get-in xs/1 (- i/5 1))) 2)
                    (= xs/1 (set-in xs/1 $index/6 $v/7))))
                (= $i/3 (+ $i/3 1))))))))
    (fn diff (xs/1 ys/2) ev/3
      (let t/4 0
        (seq
          (let $i/5 2
            (let $stop/6 (call ev/3 Array.len xs/1)
              (if (<= $stop/6 (length ys/2))
                (while (< $i/5 $stop/6)
                  (let i/7 $i/5
                    (seq
                      (let $v/8 (- (get-in xs/1 i/7) (get-in ys/2 (- i/7 2)))
                        (= t/4 (+ t/4 $v/8)))
                      (= $i/5 (+ $i/5 1)))))
                (while (< $i/5 $stop/6)
                  (let i/9 $i/5
                    (seq
                      (let $v/10 (- (get-in xs/1 i/9) (get ys/2 (- i/9 2)))
                        (= t/4 (+ t/4 $v/10)))
                      (= $i/5 (+ $i/5 1))))))))
          t/4)))
    (fn main () ev/1 ())
    (fn $start () ev/1 (call ev/1 main))
    |}];
  run
    {|
fn diff(xs: Array<Int>, ys: Array<Int>) -> Int =
  var t = 0
  for i in 2..xs.len()
    t += xs[i] - ys[i - 2]
  t

fn main() uses Console =
  print(diff([1, 2, 3, 4], [10, 20, 30]))
  print(diff([1, 2, 3, 4], [10, 20]))
  print(diff([1, 2, 3, 4], [10]))
|};
  [%expect {|
    -23
    -23
    error: panic: index 1 is out of bounds for an array of length 1
      ┌─ test.ren:4:18
    4 │     t += xs[i] - ys[i - 2]
      │                  ^^^^^^^^^
    |}]

let%expect_test "an array a block changes is never trusted, and panics where ren run does" =
  run_error
    {|
fn main() uses Console =
  var ys = [1, 2, 3]
  var t = 0
  for i in 0..ys.len()
    let f = fn() => ys = [9]
    f()
    t += ys[i]
  print(t)
|};
  [%expect
    {|
    error: panic: index 1 is out of bounds for an array of length 1
      ┌─ test.ren:7:10
    7 │     t += ys[i]
      │          ^^^^^
    |}]

(* Core Lint proves each `get-in` again: one moved out of its loop, here
   every index marked in bounds, is a bug it catches. *)
let%expect_test "Core Lint rejects an index marked in bounds that isn't" =
  let open Ren.Core in
  let src =
    clean
      {|
fn get(xs: Array<Int>, i: Int) -> Int = xs[i]
fn main() = get([1], 0)
|}
  in
  let rec trusted (e : expr) =
    let e =
      match e.kind with
      | Prim (Get_index _, args) -> { e with kind = Prim (Get_index In_bounds, args) }
      | _ -> e
    in
    match e.kind with
    | Prim (p, args) -> { e with kind = Prim (p, List.map trusted args) }
    | _ -> e
  in
  report src (fun () ->
      let linked = Ren.Driver.linked ~file src in
      let entry = List.nth linked (List.length linked - 1) in
      let entry =
        {
          entry with
          fns = List.map (fun (f : fn_def) -> { f with body = trusted f.body }) entry.fns;
        }
      in
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked entry);
      print_endline "ok");
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `get`, at test.ren:1:41: an index marked in bounds that its loop doesn't keep so")
      = this is a bug in the Ren compiler, not in your program
    |}]

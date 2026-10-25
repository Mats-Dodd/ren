(* Lowering to Core (lower.ml), and Core Lint (core_lint.ml), which every
   test that runs a program or prints its types also runs. A local prints
   as its name and binder id; a temporary's name starts with `$`. *)

open Helpers

let%expect_test "assignments to places become updates of a variable" =
  core
    {|
type P = { x: Int, y: Int }
fn main() =
  var p = P { x: 1, y: 2 }
  p.x += 1
  var xs = [1, 2]
  xs[0] = 5
  var grid = [[1]]
  grid[0][0] = p.y
|};
  [%expect
    {|
    (fn main ()
      (let p/1 (record (x: 1) (y: 2))
        (seq (= p/1 (update p/1 x: (+ (. p/1 x) 1)))
          (let xs/2 (array 1 2)
            (seq (= xs/2 (set xs/2 0 5))
              (let grid/3 (array (array 1))
                (let $v/4 (. p/1 y)
                  (= grid/3 (set grid/3 0 (set (get grid/3 0) 0 $v/4))))))))))
    |}]

let%expect_test "a place passed with & goes through a temporary" =
  core
    {|
type P = { x: Int, y: Int }
fn swap(inout a: Int, inout b: Int) =
  let t = a
  a = b
  b = t
fn main() =
  var ps = [P { x: 1, y: 2 }]
  var n = 3
  swap(&ps[0].x, &n)
|};
  [%expect
    {|
    (fn swap (a/1 b/2) (let t/3 a/1 (seq (= a/1 b/2) (= b/2 t/3))))
    (fn main ()
      (let ps/1 (array (record (x: 1) (y: 2)))
        (let n/2 3
          (let $ref/3 (. (get ps/1 0) x)
            (let $ref/4 n/2
              (let $result/5 (call swap &$ref/3 &$ref/4)
                (seq (= ps/1 (set ps/1 0 (update (get ps/1 0) x: $ref/3)))
                  (seq (= n/2 $ref/4) $result/5))))))))
    |}]

let%expect_test "for loops become while loops; for & writes back" =
  core
    {|
fn main() =
  var xs = [1, 2]
  for x in &xs
    x *= 2
  for x in xs
    if x > 2 then print(x)
|};
  [%expect
    {|
    (fn main ()
      (let xs/1 (array 1 2)
        (seq
          (let $n/4 (length xs/1)
            (let $i/5 0
              (while (< $i/5 $n/4)
                (let x/2 (get xs/1 $i/5)
                  (seq (= x/2 (* x/2 2))
                    (seq (= xs/1 (set xs/1 $i/5 x/2)) (= $i/5 (+ $i/5 1))))))))
          (let $xs/8 xs/1
            (let $n/6 (length $xs/8)
              (let $i/7 0
                (while (< $i/7 $n/6)
                  (let x/3 (get $xs/8 $i/7)
                    (seq (if (> x/3 2) (call print x/3) ()) (= $i/7 (+ $i/7 1)))))))))))
    |}]

let%expect_test "a lambda lists what it captures" =
  core {|
fn main() =
  let n = 1
  let m = 2
  let f = fn(x) => x + n
  f(m)
|};
  [%expect
    {|
    (fn main ()
      (let n/1 1
        (let m/2 2
          (let f/4 (lambda (x/3) (captures n/1) (+ x/3 n/1)) (call f/4 m/2)))))
    |}]

let%expect_test "an index in a place is evaluated once, before the call" =
  core
    {|
type P = { x: Int, xs: Array<Int> }
fn bump(inout n: Int) = n += 1
fn main() =
  var ps = [P { x: 1, xs: [2] }]
  var i = 0
  bump(&ps[i].x)
  for y in &ps[i].xs
    y += 1
|};
  [%expect
    {|
    (fn bump (n/1) (= n/1 (+ n/1 1)))
    (fn main ()
      (let ps/1 (array (record (x: 1) (xs: (array 2))))
        (let i/2 0
          (seq
            (let $index/4 i/2
              (let $ref/5 (. (get ps/1 $index/4) x)
                (let $result/6 (call bump &$ref/5)
                  (seq
                    (= ps/1
                      (set ps/1 $index/4 (update (get ps/1 $index/4) x: $ref/5)))
                    $result/6))))
            (let $index/9 i/2
              (let $n/7 (length (. (get ps/1 $index/9) xs))
                (let $i/8 0
                  (while (< $i/8 $n/7)
                    (let y/3 (get (. (get ps/1 $index/9) xs) $i/8)
                      (seq (= y/3 (+ y/3 1))
                        (seq
                          (= ps/1
                            (set ps/1 $index/9
                              (update (get ps/1 $index/9) xs:
                                (set (. (get ps/1 $index/9) xs) $i/8 y/3))))
                          (= $i/8 (+ $i/8 1)))))))))))))
    |}]

(* lint catches a lowering mistake at the node it's in *)

let%expect_test "Core Lint reports a node of the wrong type" =
  let loc = Ren.Loc.point ~file 1 1 in
  let x : Ren.Core.var = { id = 1; name = "x"; ty = Ren.Ty.int } in
  let body =
    Ren.Core.mk
      (Let (x, Ren.Core.mk (Bool true) Ren.Ty.bool loc, Ren.Core.unit loc))
      Ren.Ty.unit loc
  in
  let main : Ren.Core.fn_def =
    {
      path = Ren.Path.make "test" "main";
      params = [];
      scheme =
        { ty = Fun ([], Ren.Ty.unit, Ren.Ty.closed, Ren.Ty.closed); names = [] };
      body;
      loc;
    }
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[]
            { home = "test"; types = []; fns = [ main ] }));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: the value of `x` has type `Bool`, but should have `Int`")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* every example lowers, and Core Lint is clean on it *)

let%expect_test "every example lints" =
  let dir = "../examples" in
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".ren")
  |> List.sort compare
  |> List.iter (fun f ->
      let path = Filename.concat dir f in
      let src = In_channel.with_open_bin path In_channel.input_all in
      report src (fun () ->
          ignore (Ren.Driver.core ~lint:true ~file:f src);
          print_endline (f ^ ": ok")));
  [%expect
    {|
    blocks.ren: ok
    fib.ren: ok
    infer.ren: ok
    plans.ren: ok
    values.ren: ok
    |}]

let%expect_test "a place's index is the one it had when the place was found" =
  run
    {|
type P = { xs: Array<Int> }
fn bump(inout n: Int, inout i: Int) =
  n += 10
  i += 1
fn main() =
  var ps = [P { xs: [1, 2] }, P { xs: [3] }]
  var i = 0
  for y in &ps[i].xs
    y += 1
    i = 1
  i = 0
  bump(&ps[i].xs[0], &i)
  print(i)
  ps
|};
  [%expect {|
    1
    [{ xs: [12, 3] }, { xs: [3] }]
    |}]

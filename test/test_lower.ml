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
    (fn main () ev/4
      (let p/1 (record (x: 1) (y: 2))
        (seq (= p/1 (update p/1 x: (+ (. p/1 x) 1)))
          (let xs/2 (array 1 2)
            (seq (= xs/2 (set xs/2 0 5))
              (let grid/3 (array (array 1))
                (let $v/5 (. p/1 y)
                  (= grid/3 (set grid/3 0 (set (get grid/3 0) 0 $v/5))))))))))
    (fn $start () ev/1 (call ev/1 main))
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
    (fn swap (a/1 b/2) ev/4 (let t/3 a/1 (seq (= a/1 b/2) (= b/2 t/3))))
    (fn main () ev/3
      (let ps/1 (array (record (x: 1) (y: 2)))
        (let n/2 3
          (let $ref/4 (. (get ps/1 0) x)
            (let $ref/5 n/2
              (let $result/6 (call ev/3 swap &$ref/4 &$ref/5)
                (seq (= ps/1 (set ps/1 0 (update (get ps/1 0) x: $ref/4)))
                  (seq (= n/2 $ref/5) $result/6))))))))
    (fn $start () ev/1 (call ev/1 main))
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
    (fn main () ev/4
      (let xs/1 (array 1 2)
        (seq
          (let $n/5 (length xs/1)
            (let $i/6 0
              (while (< $i/6 $n/5)
                (let x/2 (get xs/1 $i/6)
                  (seq (= x/2 (* x/2 2))
                    (seq (= xs/1 (set xs/1 $i/6 x/2)) (= $i/6 (+ $i/6 1))))))))
          (let $xs/9 xs/1
            (let $n/7 (length $xs/9)
              (let $i/8 0
                (while (< $i/8 $n/7)
                  (let x/3 (get $xs/9 $i/8)
                    (seq (if (> x/3 2) (call ev/4 print x/3) ())
                      (= $i/8 (+ $i/8 1)))))))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
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
    (fn main () ev/5
      (let n/1 1
        (let m/2 2
          (let f/4 (lambda (x/3) (captures n/1) ev/6 (+ x/3 n/1))
            (call ev/5 f/4 m/2)))))
    (fn $start () ev/1 (call ev/1 main))
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
    (fn bump (n/1) ev/2 (= n/1 (+ n/1 1)))
    (fn main () ev/4
      (let ps/1 (array (record (x: 1) (xs: (array 2))))
        (let i/2 0
          (seq
            (let $index/5 i/2
              (let $ref/6 (. (get ps/1 $index/5) x)
                (let $result/7 (call ev/4 bump &$ref/6)
                  (seq
                    (= ps/1
                      (set ps/1 $index/5 (update (get ps/1 $index/5) x: $ref/6)))
                    $result/7))))
            (let $index/10 i/2
              (let $n/8 (length (. (get ps/1 $index/10) xs))
                (let $i/9 0
                  (while (< $i/9 $n/8)
                    (let y/3 (get (. (get ps/1 $index/10) xs) $i/9)
                      (seq (= y/3 (+ y/3 1))
                        (seq
                          (= ps/1
                            (set ps/1 $index/10
                              (update (get ps/1 $index/10) xs:
                                (set (. (get ps/1 $index/10) xs) $i/9 y/3))))
                          (= $i/9 (+ $i/9 1)))))))))))))
    (fn $start () ev/1 (call ev/1 main))
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
      ev = Ren.Core.evidence 2;
      scheme =
        { ty = Fun ([], Ren.Ty.unit, Ren.Ty.closed, Ren.Ty.closed); names = [] };
      body;
      loc;
    }
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            { home = "test"; types = []; fns = [ main ]; values = [] }));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: the value of `x` has type `Bool`, but should have `Int`")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "Core Lint reports a fail of something that isn't an error" =
  let loc = Ren.Loc.point ~file 1 1 in
  let body =
    Ren.Core.mk (Fail (Ren.Core.mk (Int 1) Ren.Ty.int loc)) Ren.Ty.unit loc
  in
  let main : Ren.Core.fn_def =
    {
      path = Ren.Path.make "test" "main";
      params = [];
      ev = Ren.Core.evidence 2;
      scheme =
        { ty = Fun ([], Ren.Ty.unit, Ren.Ty.closed, Ren.Ty.closed); names = [] };
      body;
      loc;
    }
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            { home = "test"; types = []; fns = [ main ]; values = [] }));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: what `fail` fails with has type `Int`, which isn't an error set")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* An associated value, `T.a` and `T.b`, is a function of no parameters
   in Core, named only by a [Global_value] node, and made after every
   value it uses. *)
let values_program ~uses_b ~values =
  let loc = Ren.Loc.point ~file 1 1 in
  let path = Ren.Path.make "test" in
  let int_fn : Ren.Ty.ty = Fun ([], Ren.Ty.int, Ren.Ty.closed, Ren.Ty.closed) in
  let value name body : Ren.Core.fn_def =
    {
      path = path name;
      params = [];
      ev = Ren.Core.evidence 2;
      scheme = { ty = int_fn; names = [] };
      body;
      loc;
    }
  in
  let a = value "T.a" (Ren.Core.mk uses_b Ren.Ty.int loc) in
  let b = value "T.b" (Ren.Core.mk (Int 1) Ren.Ty.int loc) in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            {
              home = "test";
              types = [];
              fns = [ a; b ];
              values = List.map path values;
            }))

let%expect_test "Core Lint reports a value named as a function" =
  values_program
    ~uses_b:
      (Call
         ( Ren.Core.mk
             (Global (Ren.Path.make "test" "T.b"))
             (Fun ([], Ren.Ty.int, Ren.Ty.closed, Ren.Ty.closed))
             (Ren.Loc.point ~file 1 1),
           [],
           Ren.Core.evidence 2 ))
    ~values:[ "T.b"; "T.a" ];
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `T.a`, at test.ren:1:1: there's no function `T.b`")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "Core Lint reports values made out of order" =
  values_program
    ~uses_b:(Global_value (Ren.Path.make "test" "T.b"))
    ~values:[ "T.a"; "T.b" ];
  (* and is clean on them in order *)
  values_program
    ~uses_b:(Global_value (Ren.Path.make "test" "T.b"))
    ~values:[ "T.b"; "T.a" ];
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: the value `T.a` is made before `T.b`, which it uses")
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
      report_files
        [ (f, src) ]
        (fun () ->
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

let%expect_test "&& and || become ifs; not is a primitive" =
  core {|
fn main() =
  let a = 1 < 2
  let b = a && not a
  b || a
|};
  [%expect
    {|
    (fn main () ev/3
      (let a/1 (< 1 2) (let b/2 (if a/1 (not a/1) false) (if b/2 true a/1))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "fail raises a tag; attempt and a fail arm handle it" =
  core
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn keep(id: Int) -> Result<Int, ! NotFound(Int)> = attempt load(id)
fn handled(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound(_) => 0
fn passed(id: Int) -> Int =
  try match load(id)
    n => n
    fail NotFound(0) => 0
fn again(r: Result<Int, ! NotFound(Int)>) -> Int = try r
fn first(o: Option<Int>) -> Int = o orelse fail Empty
fn main() = ()
|};
  [%expect
    {|
    (fn load (id/1) ev/2 (if (== id/1 0) (fail (tag NotFound id/1)) id/1))
    (fn keep (id/1) ev/2
      (handle (call ev/2 load id/1) ($value/3 => (con Ok $value/3))
        (fail $error/4 => (con Err $error/4))))
    (fn handled (id/1) ev/3
      (handle (call ev/3 load id/1) ($value/4 => (match $value/4 (n/2 => n/2)))
        (fail $error/5 => (match $error/5 ((tag NotFound _) => 0)))))
    (fn passed (id/1) ev/3
      (handle (call ev/3 load id/1) ($value/4 => (match $value/4 (n/2 => n/2)))
        (fail $error/5 =>
          (match $error/5 ((tag NotFound 0) => 0) (_ => (fail $error/5))))))
    (fn again (r/1) ev/2
      (match r/1 ((Ok $value/3) => $value/3) ((Err $error/4) => (fail $error/4))))
    (fn first (o/1) ev/2
      (match o/1 ((Some $value/3) => $value/3) (None => (fail (tag Empty)))))
    (fn main () ev/1 ())
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "a call that can fail writes its & places back anyway" =
  core
    {|
fn add(inout xs: Array<Int>, x: Int) =
  &xs.push(x)
  if x < 0 then fail Negative
fn main() =
  var grid = [[1]]
  let _ = attempt add(&grid[0], 2)
  let _ = attempt each(&grid)
  ()
fn each(inout grid: Array<Array<Int>>) =
  for row in &grid
    try add(&row, -1)
|};
  [%expect
    {|
    (fn add (xs/1 x/2) ev/3
      (seq (call ev/3 Array.push &xs/1 x/2)
        (if (< x/2 0) (fail (tag Negative)) ())))
    (fn main () ev/4
      (let grid/1 (array (array 1))
        (let _/2
          (handle
            (let $ref/5 (get grid/1 0)
              (finally (call ev/4 add &$ref/5 2) (= grid/1 (set grid/1 0 $ref/5))))
            ($value/6 => (con Ok $value/6))
            (fail $error/7 => (con Err $error/7)))
          (let _/3
            (handle (call ev/4 each &grid/1) ($value/8 => (con Ok $value/8))
              (fail $error/9 => (con Err $error/9)))
            ()))))
    (fn each (grid/1) ev/3
      (let $n/4 (length grid/1)
        (let $i/5 0
          (while (< $i/5 $n/4)
            (let row/2 (get grid/1 $i/5)
              (seq
                (finally (call ev/3 add &row/2 (neg 1))
                  (= grid/1 (set grid/1 $i/5 row/2)))
                (= $i/5 (+ $i/5 1))))))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

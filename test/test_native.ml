(* The native slice's front: lowering Core to Mem IR (to_mem.ml) and Mem
   Lint (mem_lint.ml), which `ren build` runs on every program it
   compiles. bench/build.t compiles programs and runs them. *)

open Ren
open Helpers

(* Each function of a program's Mem IR that isn't `$start` or `main`,
   once Mem Lint has checked them all. *)
let mem src =
  let src = clean src in
  report src (fun () ->
      let p = Driver.mem ~lint:true ~file src in
      List.iter
        (fun (f : Mem.fn) ->
          if
            not
              (String.ends_with ~suffix:"_start" f.name
              || String.ends_with ~suffix:"_main" f.name)
          then print_endline (Mem.show_fn f))
        p.fns;
      print_endline "Mem Lint: ok")

let%expect_test "an Int function returns its value, overflow checked" =
  mem
    {|
fn fib(n: Int) -> Int =
  if n < 2 then n else fib(n - 1) + fib(n - 2)
fn main() -> Int = fib(10)
|};
  [%expect
    {|
    (fn ren_test_fib (n/1:Int) -> Int
      (do (let n/2:Int n/1) (let $cmp/3:Bool (< n/2 2)) (decl $if/4:Int)
        (if $cmp/3 (do (let n/5:Int n/1) (set $if/4 n/5))
          (do (let n/6:Int n/1) (let $arith/7:Int (- n/6 1))
            (let $result/8:Int (call ren_test_fib $arith/7))
            (let n/9:Int n/1)
            (let $arith/10:Int (- n/9 2))
            (let $result/11:Int (call ren_test_fib $arith/10))
            (let $arith/12:Int (+ $result/8 $result/11))
            (set $if/4 $arith/12)))
        (return $if/4)))
    Mem Lint: ok
    |}]

let%expect_test
    "counted values are dup'd at each use and dropped with their scope" =
  mem
    {|
type Tree =
  | Node(left: Tree, key: Int, right: Tree)
  | Leaf

fn size(t: Tree) -> Int =
  match t
    Node(l, _, r) => size(l) + 1 + size(r)
    Leaf => 0

fn main() -> Int = size(Node(Leaf, 1, Node(Leaf, 2, Leaf)))
|};
  [%expect
    {|
    (fn ren_test_size (t/1:Boxed) -> Int
      (do (decl $match/2:Int) (let t/3:Boxed t/1) (dup t/3) (decl l/4:Boxed)
        (decl r/5:Boxed)
        (joins
          (do (let $tag/6:Int (tag t/3))
            (switch $tag/6
              (#0
                (do (let $part/7:Boxed (field t/3 0))
                  (let $part/8:Boxed (field t/3 1))
                  (set l/4 $part/7)
                  (set r/5 $part/8)
                  (dup l/4)
                  (dup r/5)
                  (drop t/3)
                  jump L1
                  (panic "no arm of this `match` matched")))
              (#1
                (do (drop t/3) jump L2 (panic "no arm of this `match` matched")))
              (else (do (panic "no arm of this `match` matched")))))
          (L1:
            (do (let l/9:Boxed l/4) (dup l/9)
              (let $result/10:Int (call ren_test_size l/9))
              (let $arith/11:Int (+ $result/10 1))
              (let r/12:Boxed r/5)
              (dup r/12)
              (let $result/13:Int (call ren_test_size r/12))
              (let $arith/14:Int (+ $arith/11 $result/13))
              (set $match/2 $arith/14)
              (drop l/4)
              (drop r/5)))
          (L2: (do (set $match/2 0))))
        (drop t/1)
        (return $match/2)))
    Mem Lint: ok
    |}]

let%expect_test
    "a function that can fail returns a status, and a match catches it" =
  mem
    {|
fn check(n: Int) -> Int ! Neg(by: Int) | Big =
  if n < 0 then fail Neg(n) else if n > 10 then fail Big else n

fn main() -> Int =
  match check(-2)
    v => v
    fail Neg(k) => k
    fail Big => 0
|};
  [%expect
    {|
    (fn ren_test_check (n/1:Int) fails -> Int
      (do (let n/2:Int n/1) (let $cmp/3:Bool (< n/2 0)) (decl $if/4:Int)
        (if $cmp/3
          (do (let n/5:Int n/1) (let $new/6:Boxed (alloc #0 objs:0 n/5))
            (raise $new/6)
            (set $if/4 0))
          (do (let n/7:Int n/1) (let $cmp/8:Bool (> n/7 10)) (decl $if/9:Int)
            (if $cmp/8 (do (raise #1*) (set $if/9 0))
              (do (let n/10:Int n/1) (set $if/9 n/10)))
            (set $if/4 $if/9)))
        (return $if/4)))
    Mem Lint: ok
    |}]

(* ---- what Mem Lint catches ---- *)

let lint fns =
  let p : Mem.program =
    {
      fns;
      start = "f";
      start_result = Int;
      start_fails = false;
      prints = Shows_int;
      errors = [];
      strings = [];
      sites = [];
      overflow =
        { sid = 0; loc = Loc.point ~file:"x" 1 1; wrap = None; kind = Panics };
    }
  in
  match Mem_lint.program p with
  | () -> print_endline "ok"
  | exception Failure msg -> print_endline msg

let fn ?(fails = false) ?(result : Mem.layout = Int) body : Mem.fn =
  {
    name = "f";
    params = [];
    result;
    fails;
    body;
    loc = Loc.point ~file:"x" 1 1;
  }

let v id name layout : Mem.var = { id; name; layout }

let%expect_test "Mem Lint: a variable used before it's defined" =
  let x = v 1 "x" Int in
  lint [ fn [ Return (Var x); Let (x, Atom (Int 1L)) ] ];
  [%expect {| Mem Lint, in f: x/1 is used where it isn't defined |}]

let%expect_test "Mem Lint: a variable defined in a branch, used after it" =
  let x = v 1 "x" Int in
  lint [ fn [ If (Bool true, [ Let (x, Atom (Int 1L)) ], []); Return (Var x) ] ];
  [%expect {| Mem Lint, in f: x/1 is used where it isn't defined |}]

let%expect_test "Mem Lint: layouts that disagree" =
  let x = v 1 "x" Boxed in
  lint [ fn [ Let (x, Atom (Int 1L)); Return (Int 0L) ] ];
  [%expect {| Mem Lint, in f: x/1 is Int, but should be Boxed |}];
  let n = v 1 "n" Int in
  lint [ fn [ Let (n, Atom (Int 1L)); Dup (Var n); Return (Var n) ] ];
  [%expect {| Mem Lint, in f: what's counted n/1 is Int, but should be Boxed |}]

let%expect_test "Mem Lint: a raise from a function that can't fail" =
  lint [ fn [ Raise (Scalar_ctor 0, None) ] ];
  [%expect {| Mem Lint, in f: a raise in a function that can't fail |}]

let%expect_test "Mem Lint: a break outside its loop" =
  lint [ fn [ Loop (1, [ Break 1 ]); Break 1; Return (Int 0L) ] ];
  [%expect {| Mem Lint, in f: a break of L1 outside it |}]

let%expect_test "Mem Lint: counted fields after a scalar" =
  let o = v 1 "o" Boxed in
  lint
    [
      fn
        [
          Let (o, Alloc { tag = 0; fields = [ Int 1L; Lit 0 ]; nobjs = 1 });
          Return (Int 0L);
        ];
    ];
  [%expect
    {| Mem Lint, in f: an object whose 1 counted fields aren't the first |}]

(* ---- what isn't in the subset yet ---- *)

let%expect_test "a block isn't in the native slice yet" =
  mem
    {|
fn twice(f: fn(Int) -> Int, x: Int) -> Int = try f(try f(x))
fn main() -> Int = twice(fn(n) => n + 1, 1)
|};
  [%expect
    {|
    error: a block isn't in the native slice yet
      ┌─ test.ren:2:26
    2 │ fn main() -> Int = twice(fn(n) => n + 1, 1)
      │                          ^^^^^^^^^^^^^^ `ren build` can't compile this yet
      help: run it with `ren run test.ren`
    |}]

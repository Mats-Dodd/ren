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
    (fn ren_test_fib (ev/1:Ev n/2:Int) -> Int
      (do (let n/3:Int n/2) (let $cmp/4:Bool (< n/3 2)) (decl $if/5:Int)
        (if $cmp/4 (do (let n/6:Int n/2) (set $if/5 n/6))
          (do (let n/7:Int n/2) (let $arith/8:Int (- n/7 1))
            (let $result/9:Int (call ren_test_fib ev/1 $arith/8))
            (let n/10:Int n/2)
            (let $arith/11:Int (- n/10 2))
            (let $result/12:Int (call ren_test_fib ev/1 $arith/11))
            (let $arith/13:Int (+ $result/9 $result/12))
            (set $if/5 $arith/13)))
        (return $if/5)))
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
    (fn ren_test_size (ev/1:Ev t/2:Boxed) -> Int
      (do (decl $match/3:Int) (let t/4:Boxed t/2) (dup t/4) (decl l/5:Boxed)
        (decl r/6:Boxed)
        (joins
          (do (let $tag/7:Int (tag t/4))
            (switch $tag/7
              (#0
                (do (let $part/8:Boxed (field t/4 0))
                  (let $part/9:Boxed (field t/4 2))
                  (set l/5 $part/8)
                  (set r/6 $part/9)
                  (dup l/5)
                  (dup r/6)
                  (drop t/4)
                  jump L1
                  (panic "no arm of this `match` matched")))
              (#1
                (do (drop t/4) jump L2 (panic "no arm of this `match` matched")))
              (else (do (panic "no arm of this `match` matched")))))
          (L1:
            (do (let l/10:Boxed l/5) (dup l/10)
              (let $result/11:Int (call ren_test_size ev/1 l/10))
              (let $arith/12:Int (+ $result/11 1))
              (let r/13:Boxed r/6)
              (dup r/13)
              (let $result/14:Int (call ren_test_size ev/1 r/13))
              (let $arith/15:Int (+ $arith/12 $result/14))
              (set $match/3 $arith/15)
              (drop l/5)
              (drop r/6)))
          (L2: (do (set $match/3 0))))
        (drop t/2)
        (return $match/3)))
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
    (fn ren_test_check (ev/1:Ev n/2:Int) fails -> Int
      (do (let n/3:Int n/2) (let $cmp/4:Bool (< n/3 0)) (decl $if/5:Int)
        (if $cmp/4
          (do (let n/6:Int n/2) (let $new/7:Boxed (alloc #0 n/6 desc0))
            (raise $new/7)
            (set $if/5 0))
          (do (let n/8:Int n/2) (let $cmp/9:Bool (> n/8 10)) (decl $if/10:Int)
            (if $cmp/9 (do (raise #1*) (set $if/10 0))
              (do (let n/11:Int n/2) (set $if/10 n/11)))
            (set $if/5 $if/10)))
        (return $if/5)))
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
      start_desc = 0;
      descs = [ { dkind = D_int; dargs = []; dcounted = false } ];
      decls = [];
      tags = [];
      values = [];
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
  [%expect
    {| Mem Lint, in f: n/1 is Int, which isn't an object, but is counted |}]

let%expect_test "Mem Lint: a raise from a function that can't fail" =
  lint [ fn [ Raise (Scalar_ctor 0, None) ] ];
  [%expect {| Mem Lint, in f: a raise in a function that can't fail |}]

let%expect_test "Mem Lint: a break outside its loop" =
  lint [ fn [ Loop (1, [ Break 1 ]); Break 1; Return (Int 0L) ] ];
  [%expect {| Mem Lint, in f: a break of L1 outside it |}]

let%expect_test "Mem Lint: a type variable's word with no descriptor" =
  let o = v 1 "o" Boxed and w = v 2 "w" (Word 0) in
  lint
    [
      fn
        [
          Let (w, To_word (Int 1L));
          Let (o, Alloc { tag = 0; fields = [ Var w; Lit 0 ]; words = [] });
          Return (Int 0L);
        ];
    ];
  [%expect {| Mem Lint, in f: an object with 1 words given 0 descriptors |}]

let%expect_test "Mem Lint: a block stored in an object" =
  let o = v 1 "o" Boxed and b = v 2 "b" Block in
  lint
    [
      fn
        [
          Decl b;
          Let (o, Alloc { tag = 0; fields = [ Var b ]; words = [] });
          Return (Int 0L);
        ];
    ];
  [%expect {| Mem Lint, in f: Block stored in an object |}]

(* ---- what isn't in the subset yet ---- *)

let%expect_test "the world but the real `Console` isn't in the native slice" =
  mem {|
fn main() -> Unit uses Clock =
  let t = Clock.now()
  ()
|};
  [%expect
    {|
    error: the real `Clock` isn't in the native slice yet
      ┌─ test.ren:1:4
    1 │ fn main() -> Unit uses Clock =
      │    ^^^^ `ren build` can't compile this yet
      help: run it with `ren run test.ren`
    |}]

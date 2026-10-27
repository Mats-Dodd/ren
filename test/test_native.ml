(* The native slice's front: lowering Core to Mem IR (to_mem.ml) and Mem
   Lint (mem_lint.ml), which `ren build` runs on every program it
   compiles. bench/build.t compiles programs and runs them. *)

open Ren
open Helpers

(* Each function of a program's Mem IR that isn't `$start` or `main`,
   or only those named in [only], once Mem Lint has checked them all. Its
   counting is Perceus's, or the naive one with [~rc:Naive]; a release
   build's with [~release:true]. *)
let mem ?rc ?release ?only src =
  let src = clean src in
  report src (fun () ->
      let p = Driver.mem ~lint:true ?rc ?release ~file src in
      List.iter
        (fun (f : Mem.fn) ->
          let shown =
            match only with
            | Some names -> List.mem f.name names
            | None ->
                not
                  (String.ends_with ~suffix:"_start" f.name
                  || String.ends_with ~suffix:"_main" f.name)
          in
          if shown then print_endline (Mem.show_fn f))
        p.fns;
      print_endline "Mem Lint: ok")

(* The lines of the function [name]'s Mem IR that have any of [words] in
   them: what a long function shows about one thing. *)
let mem_lines ?release name words src =
  let src = clean src in
  report src (fun () ->
      let p = Driver.mem ~lint:true ?release ~file src in
      List.iter
        (fun (f : Mem.fn) ->
          if f.name = name then
            List.iter
              (fun line ->
                let has w =
                  let n = String.length w and m = String.length line in
                  let rec at i =
                    i + n <= m && (String.sub line i n = w || at (i + 1))
                  in
                  at 0
                in
                if List.exists has words then print_endline (String.trim line))
              (String.split_on_char '\n' (Mem.show_fn f)))
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
    "naively, counted values are dup'd at each use and dropped with their scope"
    =
  mem ~rc:Naive
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
                (do (let $part/8:Boxed (field t/4 0/3))
                  (let $part/9:Boxed (field t/4 2/3))
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
    "Perceus: a parameter only read is borrowed, and counted nowhere" =
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
    (fn ren_test_size (ev/1:Ev ^t/2:Boxed) -> Int
      (do (decl $match/3:Int) (let t/4:Boxed t/2)
        (joins
          (do (let $tag/7:Int (tag t/4))
            (switch $tag/7
              (#0
                (do (let $part/8:Boxed (field t/4 0/3))
                  (let $part/9:Boxed (field t/4 2/3))
                  (let l/5:Boxed $part/8)
                  (let r/6:Boxed $part/9)
                  (let l/10:Boxed l/5)
                  (let $result/11:Int (call ren_test_size ev/1 l/10))
                  (let $arith/12:Int (+ $result/11 1))
                  (let r/13:Boxed r/6)
                  (let $result/14:Int (call ren_test_size ev/1 r/13))
                  (let $arith/15:Int (+ $arith/12 $result/14))
                  (set $match/3 $arith/15)
                  jump L3))
              (#1 (do (set $match/3 0) jump L3))
              (else (do (panic "no arm of this `match` matched")))))
          (L3: (do)))
        (return $match/3)))
    Mem Lint: ok
    |}]

let rbtree_types =
  {|
type Color =
  | Red
  | Black

type Tree =
  | Node(color: Color, left: Tree, key: Int, value: Bool, right: Tree)
  | Leaf
|}

let%expect_test "Perceus: rbtree's lookup borrows the tree, and counts nothing"
    =
  mem ~only:[ "ren_test_lookup" ]
    (rbtree_types
   ^ {|
fn lookup(t: Tree, k: Int) -> Bool =
  match t
    Node(_, l, kx, v, r) =>
      if k < kx then lookup(l, k)
      else if k > kx then lookup(r, k)
      else v
    Leaf => false

fn main() -> Bool = lookup(Node(Black, Leaf, 1, true, Leaf), 1)
|}
    );
  [%expect
    {|
    (fn ren_test_lookup (ev/1:Ev ^t/2:Boxed k/3:Int) -> Bool
      (do (decl $match/4:Bool) (let t/5:Boxed t/2)
        (joins
          (do (let $tag/10:Int (tag t/5))
            (switch $tag/10
              (#0
                (do (let $part/11:Boxed (field t/5 1/5))
                  (let $part/12:Int (field t/5 2/5))
                  (let $part/13:Bool (field t/5 3/5))
                  (let $part/14:Boxed (field t/5 4/5))
                  (let l/6:Boxed $part/11)
                  (let kx/7:Int $part/12)
                  (let v/8:Bool $part/13)
                  (let r/9:Boxed $part/14)
                  (let k/15:Int k/3)
                  (let kx/16:Int kx/7)
                  (let $cmp/17:Bool (< k/15 kx/16))
                  (decl $if/18:Bool)
                  (if $cmp/17
                    (do (let l/19:Boxed l/6) (let k/20:Int k/3)
                      (let $result/21:Bool (call ren_test_lookup ev/1 l/19 k/20))
                      (set $if/18 $result/21))
                    (do (let k/22:Int k/3) (let kx/23:Int kx/7)
                      (let $cmp/24:Bool (> k/22 kx/23))
                      (decl $if/25:Bool)
                      (if $cmp/24
                        (do (let r/26:Boxed r/9) (let k/27:Int k/3)
                          (let $result/28:Bool
                            (call ren_test_lookup ev/1 r/26 k/27))
                          (set $if/25 $result/28))
                        (do (let v/29:Bool v/8) (set $if/25 v/29)))
                      (set $if/18 $if/25)))
                  (set $match/4 $if/18)
                  jump L3))
              (#1 (do (set $match/4 false) jump L3))
              (else (do (panic "no arm of this `match` matched")))))
          (L3: (do)))
        (return $match/4)))
    Mem Lint: ok
    |}]

let rbtree_balance_right =
  {|
fn balance_right(l: Tree, k: Int, v: Bool, r: Tree) -> Tree =
  match r
    Node(_, Node(Red, lx, kx, vx, rx), ky, vy, ry) =>
      Node(Red, Node(Black, l, k, v, lx), kx, vx, Node(Black, rx, ky, vy, ry))
    Node(_, lx, kx, vx, Node(Red, ly, ky, vy, ry)) =>
      Node(Red, Node(Black, l, k, v, lx), kx, vx, Node(Black, ly, ky, vy, ry))
    Node(_, lx, kx, vx, rx) => Node(Black, l, k, v, Node(Red, lx, kx, vx, rx))
    Leaf => Leaf
|}

let%expect_test
    "Perceus: rbtree's balance builds nodes in the node it took apart and the \
     one inside it, if they're unique, each where the most fields are \
     already in place" =
  mem_lines "ren_test_balance_right"
    [ "unique?"; "reset"; "(alloc"; "(at "; "free-token" ]
    (rbtree_types ^ rbtree_balance_right
   ^ {|
fn main() -> Bool =
  match balance_right(Leaf, 1, true, Node(Red, Leaf, 2, true, Leaf))
    Node(_, _, _, v, _) => v
    Leaf => false
|}
    );
  [%expect
    {|
    (let $unique/95:Bool (unique? r/5))
    (reset r/5 4=$part/30 1=$part/27))
    (let $unique/96:Bool (unique? $part/27))
    (reset $part/27 1=$part/34 4=$part/37))
    (let $new/61:Boxed (alloc #0 #1 l/57 k/58 v/59 lx/60))
    (alloc #0 #1 rx/64 ky/65 vy/66 ry/67
    (at $reuse/99 =2 =3 =4)))
    (alloc #0 #0 $new/61 kx/62 vx/63 $new/68
    (at $reuse/97 =2 =3)))
    (let $unique/93:Bool (unique? r/5))
    (reset r/5 1=$part/40 4=$part/43))
    (let $unique/94:Bool (unique? $part/43))
    (reset $part/43 1=$part/47 4=$part/50))
    (let $new/74:Boxed (alloc #0 #1 l/70 k/71 v/72 lx/73))
    (alloc #0 #1 ly/77 ky/78 vy/79 ry/80
    (at $reuse/101 =1 =2 =3 =4)))
    (alloc #0 #0 $new/74 kx/75 vx/76 $new/81
    (at $reuse/103 =2 =3)))
    (let $unique/92:Bool (unique? r/5))
    (do (let $token/106:Token (reset r/5 1=$part/53 4=$part/56))
    (alloc #0 #0 lx/86 kx/87 vx/88 rx/89
    (at $reuse/105 =1 =2 =3 =4)))
    (let $new/91:Boxed (alloc #0 #1 l/83 k/84 v/85 $new/90))
    Mem Lint: ok
    |}]

let%expect_test
    "Perceus, release: rbtree's `ins` has `balance_right` inlined where it \
     would free the token of the node it took apart, which a node is built \
     in instead" =
  mem_lines ~release:true "ren_test_ins_1"
    [ "inlined"; "call"; "free-token" ]
    (rbtree_types ^ rbtree_balance_right
   ^ {|
fn ins(t: Tree, k: Int, v: Bool) -> Tree =
  match t
    Node(Black, l, kx, vx, r) =>
      if k > kx then
        if is_red(r) then balance_right(l, kx, vx, ins(r, k, v))
        else Node(Black, l, kx, vx, ins(r, k, v))
      else Node(Black, l, k, v, r)
    Node(Red, l, kx, vx, r) =>
      if k > kx then Node(Red, l, kx, vx, ins(r, k, v))
      else Node(Red, l, k, v, r)
    Leaf => Node(Red, Leaf, k, v, Leaf)

fn is_red(t: Tree) -> Bool =
  match t
    Node(Red, _, _, _, _) => true
    _ => false

fn main() -> Bool =
  match ins(ins(Leaf, 1, true), 2, false)
    Node(_, _, _, v, _) => v
    Leaf => false
|}
    );
  [%expect
    {|
    (let $result/35:Bool (call ren_test_is_red_1 ev/1 r/34))
    (call ren_test_ins_1 ev/1 r/40 k/41 v/42))
    (decl $inlined/78:Boxed)
    (free-token $reuse/186)
    (free-token $reuse/186)
    (set $inlined/78 $match/79)
    (let $result/44:Boxed $inlined/78)
    (call ren_test_ins_1 ev/1 r/48 k/49 v/50))
    (call ren_test_ins_1 ev/1 r/65 k/66 v/67))
    (free-token $reuse/188)
    Mem Lint: ok
    |}]

let%expect_test
    "Perceus: the prelude's `map` pushes onto the array it builds in place" =
  mem ~only:[ "ren_Array_map_fresh" ]
    {|
fn main() -> Int =
  var xs: Array<Int> = []
  &xs.push(1)
  let ys = xs.map(fn(x) => x + 1)
  ys.len()
|};
  [%expect
    {|
    (fn ren_Array_map_fresh
      (^$ty0/1:Desc ^$ty1/2:Desc ev/3:Ev ^self/4:Boxed f/5:Block)
      fails -> Boxed
      (do (let self/6:Boxed self/4) (let $len/7:Int (array-len self/6))
        (let $ty1/8:Desc $ty1/2)
        (let $reserved/9:Boxed (array-reserve:Word1 $len/7 $ty1/8))
        (let out/10:Boxed $reserved/9)
        (let self/11:Boxed self/4)
        (let $xs/12:Boxed self/11)
        (let $xs/13:Boxed $xs/12)
        (let $len/14:Int (array-len $xs/13))
        (let $n/15:Int $len/14)
        (let $i/16:Int 0)
        (loop L1
          (do (let $i/17:Int $i/16) (let $n/18:Int $n/15)
            (let $cmp/19:Bool (< $i/17 $n/18))
            (if $cmp/19 (do) (do break L1))
            (let $xs/20:Boxed $xs/12)
            (let $i/21:Int $i/16)
            (let $elem/22:Word0 (array-get:Word0 $xs/20 $i/21))
            (let x/23:Word0 $elem/22)
            (let &out/24:&Boxed (addr out/10))
            (let f/25:Block f/5)
            (let x/26:Word0 x/23)
            (call-block $result/27:Word1 (f/25 ev/3 x/26)
              (error $error/28:Boxed (drop out/10) (raise $error/28)))
            (do (array-push-taking:Word1 &out/24 $result/27))
            (let $i/29:Int $i/16)
            (let $arith/30:Int (+ $i/29 1))
            (set $i/16 $arith/30)))
        (let out/31:Boxed out/10)
        (return out/31)))
    Mem Lint: ok
    |}]

let%expect_test
    "release: `map` over an array nothing else holds replaces each element \
     where it is, if it's unique; `Int` to `Str` makes a new array" =
  mem ~release:true ~only:[ "ren_Array_map_1"; "ren_Array_map_2" ]
    {|
fn main() -> Int =
  var xs: Array<Int> = []
  &xs.push(1)
  let ys = xs.map(fn(x) => x + 1)
  let zs = ys.map(fn(y) => show(y))
  zs.len()
|};
  [%expect {|
    (fn ren_Array_map_2 (ev/1:Ev self/2:Boxed) -> Boxed
      (do (let into/4:Enum #1) (decl $match/5:Boxed) (let into/6:Enum into/4)
        (joins
          (do (let $tag/7:Int (tag into/6))
            (switch $tag/7
              (#0
                (do (let self/8:Boxed self/2) (let out/9:Boxed self/8)
                  (let $i/10:Int 0)
                  (let out/11:Boxed out/9)
                  (let $len/12:Int (array-len out/11))
                  (let $stop/13:Int $len/12)
                  (let out/35:Boxed out/9)
                  (let $len/36:Int (array-len out/35))
                  (let out/37:Boxed out/9)
                  (let $buf/38:Ptr (array-data out/37))
                  (loop L3
                    (do (let $i/14:Int $i/10) (let $stop/15:Int $stop/13)
                      (let $cmp/16:Bool (< $i/14 $stop/15))
                      (if $cmp/16 (do) (do break L3))
                      (let $i/17:Int $i/10)
                      (let i/18:Int $i/17)
                      (let i/22:Int i/18)
                      (let $elem/23:Int (buf-get:Int $buf/38 $len/36 i/22))
                      (drop self/2)
                      (let $result/24:Boxed
                        (call ren_test_main_1_2 ev/1 $elem/23))
                      (drop $result/24)
                      (panic "an element cast to a type it isn't kept as")))
                  (let out/32:Boxed out/9)
                  (set $match/5 out/32)
                  jump L4))
              (#1
                (do (let self/33:Boxed self/2)
                  (let $result/34:Boxed (call ren_Array_map_fresh_2 ev/1 self/33))
                  (drop self/2)
                  (set $match/5 $result/34)
                  jump L4))
              (else (do (drop self/2) (panic "no arm of this `match` matched")))))
          (L4: (do)))
        (return $match/5)))
    (fn ren_Array_map_1 (ev/1:Ev self/2:Boxed) -> Boxed
      (do (let self/3:Boxed self/2) (let $unique/4:Bool (unique? self/3))
        (decl $into/5:Enum)
        (if $unique/4 (do (set $into/5 #0)) (do (set $into/5 #1)))
        (let into/6:Enum $into/5)
        (decl $match/7:Boxed)
        (let into/8:Enum into/6)
        (joins
          (do (let $tag/9:Int (tag into/8))
            (switch $tag/9
              (#0
                (do (let self/10:Boxed self/2) (let out/11:Boxed self/10)
                  (let $i/12:Int 0)
                  (let out/13:Boxed out/11)
                  (let $len/14:Int (array-len out/13))
                  (let $stop/15:Int $len/14)
                  (let out/37:Boxed out/11)
                  (let $len/38:Int (array-len out/37))
                  (let $own/39:Boxed (array-own out/37))
                  (set out/11 $own/39)
                  (let out/40:Boxed out/11)
                  (let $buf/41:Ptr (array-data out/40))
                  (loop L3
                    (do (let $i/16:Int $i/12) (let $stop/17:Int $stop/15)
                      (let $cmp/18:Bool (< $i/16 $stop/17))
                      (if $cmp/18 (do) (do break L3))
                      (let $i/19:Int $i/12)
                      (let i/20:Int $i/19)
                      (let i/21:Int i/20)
                      (let $index/22:Int i/21)
                      (let i/24:Int i/20)
                      (let $elem/25:Int (buf-get:Int $buf/41 $len/38 i/24))
                      (let $result/26:Int (call ren_test_main_1_1 ev/1 $elem/25))
                      (let $v/27:Int $result/26)
                      (let $index/29:Int $index/22)
                      (let $v/30:Int $v/27)
                      (do (buf-set:Int $buf/41 $len/38 $index/29 $v/30))
                      (let $i/32:Int $i/12)
                      (let $arith/33:Int (+ $i/32 1))
                      (set $i/12 $arith/33)))
                  (let out/34:Boxed out/11)
                  (set $match/7 out/34)
                  jump L4))
              (#1
                (do (let self/35:Boxed self/2)
                  (let $result/36:Boxed (call ren_Array_map_fresh_1 ev/1 self/35))
                  (drop self/2)
                  (set $match/7 $result/36)
                  jump L4))
              (else (do (drop self/2) (panic "no arm of this `match` matched")))))
          (L4: (do)))
        (return $match/7)))
    Mem Lint: ok
    |}]

let%expect_test
    "Perceus: fannkuch's flip swaps two elements of the array it's lent in \
     place" =
  mem ~only:[ "ren_test_flip" ]
    {|
fn flip(inout p: Array<Int>, k: Int) =
  var i = 0
  var j = k
  while i < j
    let t = p[i]
    p[i] = p[j]
    p[j] = t
    i += 1
    j -= 1

fn main() -> Int =
  var p: Array<Int> = []
  &p.push(1)
  &p.push(2)
  flip(&p, 1)
  p[0]
|};
  [%expect
    {|
    (fn ren_test_flip (ev/1:Ev p/2:&Boxed k/3:Int) -> Unit
      (do (let i/4:Int 0) (let k/5:Int k/3) (let j/6:Int k/5)
        (loop L1
          (do (let i/7:Int i/4) (let j/8:Int j/6) (let $cmp/9:Bool (< i/7 j/8))
            (if $cmp/9 (do) (do break L1))
            (let p/10:Boxed (load p/2))
            (let i/11:Int i/4)
            (let $elem/12:Int (array-get:Int p/10 i/11))
            (let t/13:Int $elem/12)
            (let i/14:Int i/4)
            (let $index/15:Int i/14)
            (let p/16:Boxed (load p/2))
            (let j/17:Int j/6)
            (let $elem/18:Int (array-get:Int p/16 j/17))
            (let $v/19:Int $elem/18)
            (let p/20:Boxed (load p/2))
            (let $index/21:Int $index/15)
            (let $v/22:Int $v/19)
            (let $set/23:Boxed (array-set-taking:Int p/20 $index/21 $v/22))
            (store p/2 $set/23)
            (let j/25:Int j/6)
            (let $index/26:Int j/25)
            (let p/27:Boxed (load p/2))
            (let $index/28:Int $index/26)
            (let t/29:Int t/13)
            (let $set/30:Boxed (array-set-taking:Int p/27 $index/28 t/29))
            (store p/2 $set/30)
            (let i/32:Int i/4)
            (let $arith/33:Int (+ i/32 1))
            (set i/4 $arith/33)
            (let j/34:Int j/6)
            (let $arith/35:Int (- j/34 1))
            (set j/6 $arith/35)))
        (return ())))
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
            (raise $new/7))
          (do (let n/8:Int n/2) (let $cmp/9:Bool (> n/8 10)) (decl $if/10:Int)
            (if $cmp/9 (do (raise #1*)) (do (let n/11:Int n/2) (set $if/10 n/11)))
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
      structs = [];
      overflow =
        { sid = 0; loc = Loc.point ~file:"x" 1 1; wrap = None; kind = Panics };
    }
  in
  match Mem_lint.program p with
  | () -> print_endline "ok"
  | exception Failure msg -> print_endline msg

let fn ?(fails = false) ?(result : Mem.layout = Int) ?(params = [])
    ?(modes = []) body : Mem.fn =
  {
    name = "f";
    params;
    modes;
    inout = [];
    stack = [];
    slot = None;
    words = [];
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
          Let
            ( o,
              Alloc
                { tag = 0; fields = [ Var w; Lit 0 ]; words = []; at = None } );
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
          Let (o, Alloc { tag = 0; fields = [ Var b ]; words = []; at = None });
          Return (Int 0L);
        ];
    ];
  [%expect {| Mem Lint, in f: Block stored in an object |}]

(* ---- what Mem Lint's check of the counting catches ---- *)

let alloc = Mem.Alloc { tag = 0; fields = [ Int 1L ]; words = []; at = None }

let%expect_test "Mem Lint: a reference never dropped" =
  let x = v 1 "x" Boxed in
  lint [ fn [ Let (x, alloc); Return (Int 0L) ] ];
  [%expect
    {| Mem Lint, in f: x/1 still holds a reference where the function ends |}]

let%expect_test "Mem Lint: a reference dropped twice" =
  let x = v 1 "x" Boxed in
  lint [ fn [ Let (x, alloc); Drop (Var x); Drop (Var x); Return (Int 0L) ] ];
  [%expect {| Mem Lint, in f: x/1 is dropped, but holds no reference here |}]

let%expect_test "Mem Lint: a borrowed parameter dropped" =
  let t = v 1 "t" Boxed in
  lint
    [ fn ~params:[ t ] ~modes:[ Borrowed ] [ Drop (Var t); Return (Int 0L) ] ];
  [%expect {| Mem Lint, in f: t/1 is dropped, but holds no reference here |}]

let%expect_test "Mem Lint: a value read after it's dropped" =
  let x = v 1 "x" Boxed and n = v 2 "n" Int in
  lint
    [
      fn
        [
          Let (x, alloc); Drop (Var x); Let (n, Tag_of (Var x)); Return (Var n);
        ];
    ];
  [%expect {| Mem Lint, in f: x/1 is read after it's dropped |}]

let%expect_test "Mem Lint: a reference dropped on one path only" =
  let x = v 1 "x" Boxed in
  lint
    [
      fn
        [
          Let (x, alloc); If (Bool true, [ Drop (Var x) ], []); Return (Int 0L);
        ];
    ];
  [%expect
    {| Mem Lint, in f: x/1 holds 0 and 1 references on different paths |}]

let%expect_test "Mem Lint: a reuse token never used" =
  let t = v 1 "t" Token in
  lint [ fn [ Decl t; Return (Int 0L) ] ];
  [%expect {| Mem Lint, in f: a reuse token is never used or freed |}]

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

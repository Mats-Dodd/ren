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
  | Node { left: Tree, key: Int, right: Tree }
  | Leaf

fn size(t: Tree) -> Int =
  match t
    Node { left: l, right: r, .. } => size(l) + 1 + size(r)
    Leaf => 0

fn main() -> Int =
  size(Node { left: Leaf, key: 1, right: Node { left: Leaf, key: 2, right: Leaf } })
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
  | Node { left: Tree, key: Int, right: Tree }
  | Leaf

fn size(t: Tree) -> Int =
  match t
    Node { left: l, right: r, .. } => size(l) + 1 + size(r)
    Leaf => 0

fn main() -> Int =
  size(Node { left: Leaf, key: 1, right: Node { left: Leaf, key: 2, right: Leaf } })
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
  | Node { color: Color, left: Tree, key: Int, value: Bool, right: Tree }
  | Leaf
|}

let%expect_test "Perceus: rbtree's lookup borrows the tree, and counts nothing"
    =
  mem ~only:[ "ren_test_lookup" ]
    (rbtree_types
   ^ {|
fn lookup(t: Tree, k: Int) -> Bool =
  match t
    Node { left: l, key: kx, value: v, right: r, .. } =>
      if k < kx then lookup(l, k)
      else if k > kx then lookup(r, k)
      else v
    Leaf => false

fn main() -> Bool = lookup(Node { color: Black, left: Leaf, key: 1, value: true, right: Leaf }, 1)
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
                (do (let $part/11:Boxed (field t/5 0/4))
                  (let $part/12:Int (field t/5 1/4))
                  (let $packed/13:Int (field t/5 3/4))
                  (let $part/14:Bool (unpack $packed/13@8:8))
                  (let $part/15:Boxed (field t/5 2/4))
                  (let l/6:Boxed $part/11)
                  (let kx/7:Int $part/12)
                  (let v/8:Bool $part/14)
                  (let r/9:Boxed $part/15)
                  (let k/16:Int k/3)
                  (let kx/17:Int kx/7)
                  (let $cmp/18:Bool (< k/16 kx/17))
                  (decl $if/19:Bool)
                  (if $cmp/18
                    (do (let l/20:Boxed l/6) (let k/21:Int k/3)
                      (let $result/22:Bool (call ren_test_lookup ev/1 l/20 k/21))
                      (set $if/19 $result/22))
                    (do (let k/23:Int k/3) (let kx/24:Int kx/7)
                      (let $cmp/25:Bool (> k/23 kx/24))
                      (decl $if/26:Bool)
                      (if $cmp/25
                        (do (let r/27:Boxed r/9) (let k/28:Int k/3)
                          (let $result/29:Bool
                            (call ren_test_lookup ev/1 r/27 k/28))
                          (set $if/26 $result/29))
                        (do (let v/30:Bool v/8) (set $if/26 v/30)))
                      (set $if/19 $if/26)))
                  (set $match/4 $if/19)
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
    Node {
      left: Node { color: Red, left: lx, key: kx, value: vx, right: rx },
      key: ky,
      value: vy,
      right: ry,
      ..
    } =>
      Node {
        color: Red,
        left: Node { color: Black, left: l, key: k, value: v, right: lx },
        key: kx,
        value: vx,
        right: Node { color: Black, left: rx, key: ky, value: vy, right: ry },
      }
    Node {
      left: lx,
      key: kx,
      value: vx,
      right: Node { color: Red, left: ly, key: ky, value: vy, right: ry },
      ..
    } =>
      Node {
        color: Red,
        left: Node { color: Black, left: l, key: k, value: v, right: lx },
        key: kx,
        value: vx,
        right: Node { color: Black, left: ly, key: ky, value: vy, right: ry },
      }
    Node { left: lx, key: kx, value: vx, right: rx, .. } =>
      Node {
        color: Black,
        left: l,
        key: k,
        value: v,
        right: Node { color: Red, left: lx, key: kx, value: vx, right: rx },
      }
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
  match balance_right(Leaf, 1, true, Node { color: Red, left: Leaf, key: 2, value: true, right: Leaf })
    Node { value: v, .. } => v
    Leaf => false
|}
    );
  [%expect
    {|
    (let $unique/110:Bool (unique? r/5))
    (reset r/5 2=$part/31 0=$part/27))
    (let $unique/111:Bool (unique? $part/27))
    (reset $part/27 0=$part/36 2=$part/40))
    (alloc #0 l/64 k/65 lx/67 $packed/68))
    (alloc #0 rx/72 ky/73 ry/75 $packed/76
    (at $reuse/114 =1 =2)))
    (alloc #0 $new/69 kx/70 $new/77 $packed/78
    (at $reuse/112 =1)))
    (let $unique/108:Bool (unique? r/5))
    (reset r/5 0=$part/43 2=$part/47))
    (let $unique/109:Bool (unique? $part/47))
    (reset $part/47 0=$part/52 2=$part/56))
    (alloc #0 l/80 k/81 lx/83 $packed/84))
    (alloc #0 ly/88 ky/89 ry/91 $packed/92
    (at $reuse/116 =0 =1 =2)))
    (alloc #0 $new/85 kx/86 $new/93 $packed/94
    (at $reuse/118 =1)))
    (let $unique/107:Bool (unique? r/5))
    (do (let $token/121:Token (reset r/5 0=$part/59 2=$part/63))
    (alloc #0 lx/99 kx/100 rx/102 $packed/103
    (at $reuse/120 =0 =1 =2)))
    (let $new/106:Boxed (alloc #0 l/96 k/97 $new/104 $packed/105))
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
    Node { color: Black, left: l, key: kx, value: vx, right: r } =>
      if k > kx then
        if is_red(r) then balance_right(l, kx, vx, ins(r, k, v))
        else Node { color: Black, left: l, key: kx, value: vx, right: ins(r, k, v) }
      else Node { color: Black, left: l, key: k, value: v, right: r }
    Node { color: Red, left: l, key: kx, value: vx, right: r } =>
      if k > kx then Node { color: Red, left: l, key: kx, value: vx, right: ins(r, k, v) }
      else Node { color: Red, left: l, key: k, value: v, right: r }
    Leaf => Node { color: Red, left: Leaf, key: k, value: v, right: Leaf }

fn is_red(t: Tree) -> Bool =
  match t
    Node { color: Red, .. } => true
    _ => false

fn main() -> Bool =
  match ins(ins(Leaf, 1, true), 2, false)
    Node { value: v, .. } => v
    Leaf => false
|}
    );
  [%expect
    {|
    (let $result/39:Bool (call ren_test_is_red_1 ev/1 r/38))
    (call ren_test_ins_1 ev/1 r/44 k/45 v/46))
    (decl $inlined/87:Boxed)
    (free-token $reuse/210)
    (free-token $reuse/210)
    (set $inlined/87 $match/88)
    (let $result/48:Boxed $inlined/87)
    (call ren_test_ins_1 ev/1 r/52 k/53 v/54))
    (call ren_test_ins_1 ev/1 r/71 k/72 v/73))
    (free-token $reuse/212)
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
      (do (let $here/29:Ptr (here-get)) (let self/6:Boxed self/4)
        (let $len/7:Int (array-len self/6))
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
            (do (here-put $here/29))
            (do (array-push-taking:Word1 &out/24 $result/27))
            (let $i/30:Int $i/16)
            (let $step/31:Int (count-step $i/30))
            (set $i/16 $step/31)))
        (let out/32:Boxed out/10)
        (return out/32)))
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
                      (let $step/33:Int (count-step $i/32))
                      (set $i/12 $step/33)))
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

let%expect_test
    "release: a tuple and an option of objects are structs, counted as the \
     strings in them; nothing's allocated" =
  mem ~release:true ~only:[ "ren_test_pick_1"; "ren_test_first_1" ]
    {|
fn pick(xs: Array<Str>, i: Int) -> (Str, Int) = (xs[i], i)
fn first(xs: Array<Str>) -> Option<Str> =
  if xs.len() == 0 then None else Some(xs[0])
fn main() -> Int =
  let xs = ["a", "bb"]
  let (s, k) = pick(xs, 1)
  match first(xs)
    Some(t) => s.len() + k + t.len()
    None => 0
|};
  [%expect {|
    (fn ren_test_first_1 (ev/1:Ev ^xs/2:Boxed) -> Struct1c
      (do (let xs/3:Boxed xs/2) (let $len/4:Int (array-len xs/3))
        (let $eq/5:Bool (== $len/4 0))
        (decl $if/6:Struct1c)
        (if $eq/5
          (do (let $struct/7:Struct1c (struct #niche1*)) (set $if/6 $struct/7))
          (do (let xs/8:Boxed xs/2) (let $elem/9:Boxed (array-get:Boxed xs/8 0))
            (let $struct/10:Struct1c (struct $elem/9))
            (set $if/6 $struct/10)))
        (return $if/6)))
    (fn ren_test_pick_1 (ev/1:Ev ^xs/2:Boxed i/3:Int) -> Struct0c
      (do (let xs/4:Boxed xs/2) (let i/5:Int i/3)
        (let $elem/6:Boxed (array-get:Boxed xs/4 i/5))
        (let i/7:Int i/3)
        (let $struct/8:Struct0c (struct $elem/6 i/7))
        (return $struct/8)))
    Mem Lint: ok
    |}]

(* ---- what Mem Lint catches ---- *)

let lint ?(structs = []) fns =
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
      structs;
      handlers = [];
      dep_infos = [];
      dsites = [];
      clones = [];
      overflow =
        { sid = 0; loc = Loc.point ~file:"x" 1 1; wrap = None; kind = Panics; made = None; notes = []; help = None };
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
    words = [];
    result;
    fails;
    body;
    loc = Loc.point ~file:"x" 1 1;
    lines = [];
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

(* `if c then None else p`, boxed: the constant stands for the reference
   the other path moves from the parameter it dropped here *)
let%expect_test "Mem Lint: a constructor without fields where paths meet" =
  let p = v 1 "p" Boxed and r = v 2 "r" Boxed in
  lint
    [
      fn ~params:[ v 9 "ev" Ev ] ~modes:[ Owned ] [ Return (Int 0L) ];
      {
        (fn ~result:Boxed ~params:[ p ] ~modes:[ Owned ]
        [
          Decl r;
          If
            ( Bool true,
              [ Drop (Var p); Set (r, Scalar_ctor 0) ],
              [ Set (r, Var p) ] );
          Return (Var r);
        ])
        with
        name = "g";
      };
    ];
  [%expect {| ok |}]

(* but it stands for one reference at most *)
let%expect_test "Mem Lint: a constant where paths meet, two references short" =
  let p = v 1 "p" Boxed and r = v 2 "r" Boxed in
  lint
    [
      fn ~params:[ v 9 "ev" Ev ] ~modes:[ Owned ] [ Return (Int 0L) ];
      {
        (fn ~result:Boxed ~params:[ p ] ~modes:[ Owned ]
        [
          Decl r;
          If
            ( Bool true,
              [ Drop (Var p); Set (r, Scalar_ctor 0) ],
              [ Dup (Var p); Set (r, Var p) ] );
          Drop (Var p);
          Return (Var r);
        ])
        with
        name = "g";
      };
    ];
  [%expect
    {| Mem Lint, in g: r/2 holds 0 and 2 references on different paths |}]

let%expect_test "Mem Lint: a reuse token never used" =
  let t = v 1 "t" Token in
  lint [ fn [ Decl t; Return (Int 0L) ] ];
  [%expect {| Mem Lint, in f: a reuse token is never used or freed |}]

(* ---- small values: a struct that holds an object ---- *)

let line : Mem.strukt = { sfields = [ Boxed; Int ]; skind = Product }

let%expect_test "Mem Lint: a struct's object never dropped" =
  let s = v 1 "s" (Struct (0, true)) and x = v 2 "x" Boxed in
  lint ~structs:[ line ]
    [ fn [ Let (x, alloc); Let (s, Make_struct [ Var x; Int 1L ]); Return (Int 0L) ] ];
  [%expect
    {| Mem Lint, in f: s/1 still holds a reference where the function ends |}]

let%expect_test "Mem Lint: a struct's object read after the struct's dropped" =
  let s = v 1 "s" (Struct (0, true))
  and x = v 2 "x" Boxed
  and y = v 3 "y" Boxed
  and n = v 4 "n" Int in
  lint ~structs:[ line ]
    [
      fn
        [
          Let (x, alloc);
          Let (s, Make_struct [ Var x; Int 1L ]);
          Let (y, Struct_get (Var s, 0));
          Drop (Var s);
          Let (n, Tag_of (Var y));
          Return (Var n);
        ];
    ];
  [%expect {| Mem Lint, in f: y/3 is read after it's dropped |}]

let%expect_test "Mem Lint: a struct's slot kept, the rest dropped" =
  let s = v 1 "s" (Struct (0, true))
  and x = v 2 "x" Boxed
  and y = v 3 "y" Boxed in
  (* `$start`'s one parameter, its evidence, so the whole program passes *)
  lint ~structs:[ line ]
    [
      fn ~params:[ v 9 "ev" Ev ]
        [
          Let (x, alloc);
          Let (s, Make_struct [ Var x; Int 1L ]);
          Let (y, Struct_get (Var s, 0));
          Free (Var s, [ (0, Var y) ]);
          Drop (Var y);
          Return (Int 0L);
        ];
    ];
  [%expect {| ok |}]

(* the data stage's second layout fix: an array keeps structs that hold
   objects inline, counted by the mask of their slots that do, which its
   header has a byte for *)
let%expect_test "Mem Lint: an array of structs that hold objects" =
  let s = v 1 "s" (Struct (0, true))
  and x = v 2 "x" Boxed
  and a = v 3 "a" Boxed in
  lint ~structs:[ line ]
    [
      fn ~params:[ v 9 "ev" Ev ]
        [
          Let (x, alloc);
          Let (s, Make_struct [ Var x; Int 1L ]);
          Let (a, Alloc_array { elem = Struct (0, true); elems = [ Var s ]; desc = None });
          Drop (Var a);
          Return (Int 0L);
        ];
    ];
  [%expect {| ok |}]

let%expect_test "Mem Lint: an array of structs of more slots than its mask has" =
  let wide : Mem.strukt =
    { sfields = Boxed :: List.init 8 (fun _ : Mem.layout -> Int); skind = Product }
  in
  let s = v 1 "s" (Struct (0, true))
  and x = v 2 "x" Boxed
  and a = v 3 "a" Boxed in
  lint ~structs:[ wide ]
    [
      fn
        [
          Let (x, alloc);
          Let (s, Make_struct (Var x :: List.init 8 (fun _ : Mem.atom -> Int 1L)));
          Let (a, Alloc_array { elem = Struct (0, true); elems = [ Var s ]; desc = None });
          Drop (Var a);
          Return (Int 0L);
        ];
    ];
  [%expect {| Mem Lint, in f: an array of Struct0c |}]

let%expect_test "Mem Lint: a field of an array's struct written as another layout" =
  let a = v 1 "a" Boxed and r = v 2 "r" Boxed in
  lint ~structs:[ line ]
    [
      fn ~params:[ a ] ~modes:[ Owned ]
        [
          Let (r, Runtime (Array_set_field_taking (0, 0, Int), [ Var a; Int 0L; Int 5L ], None));
          Drop (Var r);
          Return (Int 0L);
        ];
    ];
  [%expect {| Mem Lint, in f: slot 0 of struct 0 written as Int |}]

let%expect_test "Mem Lint: a struct counted that holds no object" =
  let s = v 1 "s" (Struct (0, false)) and x = v 2 "x" Boxed in
  lint ~structs:[ line ]
    [ fn [ Let (x, alloc); Let (s, Make_struct [ Var x; Int 1L ]); Return (Int 0L) ] ];
  [%expect {| Mem Lint, in f: Struct0 is counted as a struct with objects |}]

let%expect_test "Mem Lint: an element taken that isn't written back" =
  let a = v 1 "a" Boxed and x = v 2 "x" Boxed in
  lint
    [
      fn ~params:[ a ] ~modes:[ Owned ]
        [
          Let (x, Runtime (Array_take Boxed, [ Var a; Int 0L ], None));
          Drop (Var x);
          Drop (Var a);
          Return (Int 0L);
        ];
    ];
  [%expect
    {| Mem Lint, in f: x/2 is taken from an array that isn't written back as it must be |}]

let%expect_test "Mem Lint: a hole filled with a value it doesn't own" =
  let t = v 1 "t" Boxed and x = v 2 "x" Boxed and h = v 3 "h" Ptr in
  lint
    [
      fn ~params:[ t ] ~modes:[ Borrowed ] ~result:Boxed
        [
          Let (x, Mem.Alloc { tag = 0; fields = [ Scalar_ctor 0 ]; words = []; at = None });
          Let (h, Hole (Var x, 0));
          Fill (Var h, Var t);
          Return (Var x);
        ];
    ];
  [%expect {| Mem Lint, in f: t/1 is put in a hole, but holds no reference here |}]

let%expect_test
    "swap-out: a row of a grid is taken out to be changed, and written back" =
  mem_lines "ren_test_put" [ "array-take"; "array-set-taking" ]
    {|
fn put(g: Array<Array<Int>>, i: Int, j: Int) -> Array<Array<Int>> =
  var h = g
  h[i][j] = 7
  h
fn main() -> Int = put([[1, 2], [3]], 0, 1)[0][1]
|};
  [%expect {|
    (let $elem/16:Boxed (array-take:Boxed h/14 $index/15))
    (let $set/23:Boxed (array-set-taking:Int $elem/20 $index/21 $put/22))
    (let $set/24:Boxed (array-set-taking:Boxed h/18 $index/19 $set/23))
    Mem Lint: ok
    |}]

let%expect_test
    "tail recursion modulo cons: a list built by a loop that fills a hole" =
  mem ~only:[ "ren_test_build" ]
    {|
type List =
  | Cons { head: Int, tail: List }
  | Nil
fn build(i: Int, n: Int) -> List =
  if i == n then Nil else Cons { head: i, tail: build(i + 1, n) }
fn main() -> Int =
  match build(0, 3)
    Cons { head: h, .. } => h
    Nil => 0
|};
  [%expect {|
    (fn ren_test_build (ev/21:Ev i/22:Int n/23:Int) -> Boxed
      (do (decl ev/16:Ev) (decl i/17:Int) (decl n/18:Int) (decl root/15:Boxed)
        (decl hole/14:Ptr)
        (joins
          (do (let i/24:Int i/22) (let n/25:Int n/23)
            (let $eq/26:Bool (== i/24 n/25))
            (decl $if/27:Boxed)
            (if $eq/26 (do (set $if/27 #1*))
              (do (let i/28:Int i/22) (let i/29:Int i/22)
                (let $arith/30:Int (+ i/29 1))
                (let n/31:Int n/23)
                (let $new/32:Boxed (alloc #0 i/28 #0*))
                (let hole/33:Ptr (hole $new/32 1))
                (set root/15 $new/32)
                (set hole/14 hole/33)
                (set ev/16 ev/21)
                (set i/17 $arith/30)
                (set n/18 n/31)
                jump L2))
            (return $if/27))
          (L2:
            (do
              (loop L3
                (do
                  (joins
                    (do (let ev/1:Ev ev/16) (let i/2:Int i/17) (let n/3:Int n/18)
                      (let i/4:Int i/2)
                      (let n/5:Int n/3)
                      (let $eq/6:Bool (== i/4 n/5))
                      (decl $if/7:Boxed)
                      (if $eq/6 (do (set $if/7 #1*))
                        (do (let i/8:Int i/2) (let i/9:Int i/2)
                          (let $arith/10:Int (+ i/9 1))
                          (let n/11:Int n/3)
                          (let $new/13:Boxed (alloc #0 i/8 #0*))
                          (let hole/19:Ptr (hole $new/13 1))
                          (fill hole/14 $new/13)
                          (set hole/14 hole/19)
                          (set ev/16 ev/1)
                          (set i/17 $arith/10)
                          (set n/18 n/11)
                          jump L1))
                      (fill hole/14 $if/7)
                      (return root/15))
                    (L1: (do))))))))))
    Mem Lint: ok
    |}]

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

let%expect_test "`sim`, the tests' runtime and clock, isn't in the native slice" =
  (* stage 11a's step 5: the interpreter's, which `ren test` runs on *)
  mem {|
import sim

fn main() uses Console =
  with sim.scheduler(1) in print(1)
|};
  [%expect {|
    error: `sim` isn't in the native slice yet
      ┌─ test.ren:4:8
    4 │   with sim.scheduler(1) in print(1)
      │        ^^^^^^^^^^^^^^^^ `ren build` can't compile this yet
      help: run it with `ren run test.ren`
    |}]

let%expect_test "a `for` over a cursor kept in a field compiles" =
  (* lowering crashed on `for x in job.rest` (test_blocks.ml, "for over
     a cursor in a field"), so `ren build` did too *)
  mem ~only:[]
    {|
type Each = { xs: Array<Int>, i: Int }
  fn next(inout self) -> Option<Int> =
    if self.i < self.xs.len() then
      self.i += 1
      Some(self.xs[self.i - 1])
    else None
type Job = { name: Str, rest: Each }

fn main() uses Console =
  let job = Job { name: "a", rest: Each { xs: [1, 2, 3], i: 1 } }
  for x in job.rest
    print(x)
  var j = job
  for x in &j.rest
    print(x)
|};
  [%expect {| Mem Lint: ok |}]
